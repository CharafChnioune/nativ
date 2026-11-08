#!/usr/bin/env python3
"""Prepare immutable upstream merges without running code from the candidate tree.

Discovery has read-only credentials. Publication runs this trusted main-branch file
in a different job; it rechecks base, parents and privileged diff before pushing.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

FORK = "CharafChnioune/nativ"
UPSTREAM = "Neywa-Labs/nativ"
BASELINE = "Configuration/UpstreamBaseline.json"
SHA = re.compile(r"[0-9a-f]{40}\Z")
REQUIRED_JOBS = {"python", "swift", "macos"}
PROTECTED_PREFIXES = (".github/", "scripts/", "PythonDistribution/", "Configuration/",
                      "ThirdParty/", "Sources/NativTranslationKit/",
                      "Sources/Nativ/Features/LiveTranslation/", "Sources/Nativ/Features/VoiceCapture/")


def git(repo, *args, check=True, env=None):
    clean = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    clean.update({"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
                  "GIT_TERMINAL_PROMPT": "0", "GIT_AUTHOR_NAME": "Nativ upstream sync",
                  "GIT_AUTHOR_EMAIL": "nativ-sync@users.noreply.github.com",
                  "GIT_COMMITTER_NAME": "Nativ upstream sync",
                  "GIT_COMMITTER_EMAIL": "nativ-sync@users.noreply.github.com"})
    if env:
        clean.update(env)
    return subprocess.run(["git", "-c", "core.hooksPath=" + os.devnull,
                           "-c", "core.fsmonitor=false", "-c", "commit.gpgSign=false",
                           "-c", "protocol.file.allow=always", "-C", str(repo), *args],
                          check=check, capture_output=True, text=True, env=clean)


def needs_workflow_review(path):
    # Conservatively includes every build script: transitive shell/Python imports
    # cannot be safely inferred from YAML alone. A false positive requires review.
    if path.startswith((".github/", "scripts/", "PythonDistribution/")):
        return True
    if path.endswith((".sh", ".py", ".js", ".mjs", ".cjs", ".rb", ".pl", "/action.yml", "/action.yaml")):
        return True
    # Unknown tooling locations (including local Actions outside .github and
    # their binary/container entrypoints) are blocked, rather than guessed safe.
    return not path.startswith(("Sources/", "Tests/", "Docs/", "website/"))


def validate_tag_identity(tag, sha, registry):
    if not SHA.fullmatch(sha):
        raise ValueError("Invalid upstream commit SHA")
    if tag in registry and registry[tag] != sha:
        raise ValueError("Upstream tag moved or was reused; explicit provenance review required")


def validate_gate(results, expected_head, expected_base, actual_head, actual_base):
    if not SHA.fullmatch(expected_head) or not SHA.fullmatch(expected_base):
        raise ValueError("Missing exact validation identities")
    if (expected_head, expected_base) != (actual_head, actual_base):
        raise ValueError("Validation is stale: candidate or base changed")
    if any(results.get(name) != "success" for name in REQUIRED_JOBS):
        raise ValueError("Every required build/test job must actually run and succeed")


def validate_existing_candidate(work, existing, expected, base, upstream):
    parents = git(work, "show", "-s", "--format=%P", existing).stdout.split()
    if parents != [base, upstream] or git(work, "diff", "--quiet", expected, existing, check=False).returncode:
        raise ValueError("Existing candidate contains different or human edits; never force-update")
    return existing


def push_candidate(work, remote, head, branch, environment):
    # An empty expected value makes this an atomic create-only operation. A
    # branch appearing after ls-remote must never be advanced, even fast-forward.
    git(work, "push", "--force-with-lease=refs/heads/" + branch + ":", remote,
        head + ":refs/heads/" + branch, env=environment)


def read_baseline(repo, ref):
    value = git(repo, "show", ref + ":" + BASELINE, check=False)
    return json.loads(value.stdout) if value.returncode == 0 else {"tag_identities": {}}


def candidate_metadata(repo, base, upstream, label, source_kind="release"):
    metadata = read_baseline(repo, base)
    metadata.update({"upstream_repository": UPSTREAM, "integrated_sha": upstream,
                     "previous_fork_base": base, "source_label": label})
    if source_kind == "release":
        validate_tag_identity(label, upstream, metadata.setdefault("tag_identities", {}))
        metadata["tag_identities"][label] = upstream
    return metadata


def validate_candidate_merge(repo, head, base, upstream, label, source_kind="release"):
    """Recompute the merge as Git objects; never check out or execute candidate files."""
    if git(repo, "show", "-s", "--format=%P", head).stdout.split() != [base, upstream]:
        raise ValueError("Candidate must retain the exact fork/upstream merge parents")
    merged = git(repo, "merge-tree", "--write-tree", base, upstream)
    tree = merged.stdout.splitlines()[0]
    if not SHA.fullmatch(tree):
        raise ValueError("Cannot verify the candidate merge tree")
    changed = [p for p in git(repo, "diff", "--no-renames", "--name-only", "-z", tree, head).stdout.split("\0") if p]
    if set(changed) - {BASELINE}:
        raise ValueError("Candidate tree contains changes outside the recomputed upstream merge")
    mode = git(repo, "ls-tree", head, "--", BASELINE).stdout.split()
    if not mode or mode[0] != "100644":
        raise ValueError("Candidate baseline metadata must be a regular file")
    if read_baseline(repo, head) != candidate_metadata(repo, base, upstream, label, source_kind):
        raise ValueError("Candidate tree has unexpected integration metadata")


def prepare_candidate(source, base_sha, upstream_sha, label, output, reviewed_patch_sha256="", source_kind="release"):
    if not SHA.fullmatch(base_sha) or not SHA.fullmatch(upstream_sha):
        raise ValueError("An immutable base and upstream SHA are required")
    if source_kind not in {"release", "main-sha"}:
        raise ValueError("Unknown upstream source kind")
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    report = {"schema": 1, "repository": FORK, "upstream_repository": UPSTREAM,
              "base_sha": base_sha, "upstream_sha": upstream_sha, "label": label, "source_kind": source_kind,
              "manual_merge_required": True}
    with tempfile.TemporaryDirectory(prefix="nativ-sync-") as temporary:
        work = Path(temporary) / "work"
        git(Path(temporary), "clone", "--no-checkout", "--no-hardlinks", str(source), str(work))
        # SHA fetch also brings commits not reachable through the source's local branches.
        git(work, "fetch", "--no-tags", str(source), base_sha, upstream_sha)
        if git(work, "merge-base", "--is-ancestor", upstream_sha, base_sha, check=False).returncode == 0:
            report["status"] = "noop"
        else:
            safe_label = re.sub(r"[^A-Za-z0-9._-]", "-", label)[:48]
            branch = f"sync/upstream-{safe_label}-{upstream_sha[:12]}-{base_sha[:12]}"
            report["branch"] = branch
            patch = git(work, "diff", "--binary", "--no-ext-diff", "--no-textconv", base_sha + "..." + upstream_sha).stdout
            (output / "candidate.patch").write_text(patch)
            report["patch_sha256"] = hashlib.sha256(patch.encode()).hexdigest()
            paths = git(work, "diff", "--no-renames", "--name-only", "-z", base_sha + "..." + upstream_sha).stdout.rstrip("\0").split("\0")
            report["changed_paths"] = paths
            report["workflow_review_paths"] = [p for p in paths if needs_workflow_review(p)]
            report["protected_paths"] = [p for p in paths if p.startswith(PROTECTED_PREFIXES)]
            if report["workflow_review_paths"] and reviewed_patch_sha256 != report["patch_sha256"]:
                report["status"] = "workflow-review-required"
            else:
                git(work, "checkout", "-b", branch, base_sha)
                merged = git(work, "merge", "--no-ff", "--no-commit", upstream_sha, check=False)
                if merged.returncode != 0:
                    report["status"] = "conflict"
                    report["conflicts"] = [p for p in git(work, "diff", "--name-only", "-z", "--diff-filter=U").stdout.split("\0") if p]
                    if not report["conflicts"]:
                        raise ValueError("Merge failed without merge conflicts: " + merged.stderr[-1500:])
                    git(work, "merge", "--abort")
                else:
                    metadata = candidate_metadata(work, base_sha, upstream_sha, label, source_kind)
                    # This becomes integrated metadata only when the candidate is accepted.
                    path = work / BASELINE
                    if path.is_symlink() or path.parent.is_symlink():
                        raise ValueError("Imported baseline metadata may not redirect filesystem writes")
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text(json.dumps(metadata, indent=2) + "\n")
                    git(work, "add", BASELINE)
                    git(work, "commit", "-m", f"Merge upstream {label} ({upstream_sha[:12]}) into fork {base_sha[:12]}")
                    report.update(status="ready", head_sha=git(work, "rev-parse", "HEAD").stdout.strip(),
                                  parents=git(work, "show", "-s", "--format=%P", "HEAD").stdout.split())
                    validate_candidate_merge(work, report["head_sha"], base_sha, upstream_sha, label, source_kind)
                    git(work, "bundle", "create", str((output / "candidate.bundle").resolve()), branch)
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


class GitHub:
    def __init__(self, token=""):
        self.token = token

    def request(self, path, method="GET", payload=None):
        headers = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"}
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        data = json.dumps(payload).encode() if payload is not None else None
        request = urllib.request.Request("https://api.github.com/" + path, data=data, headers=headers, method=method)
        with urllib.request.urlopen(request, timeout=30) as response:
            body = response.read()
        return json.loads(body) if body else None

    def commit(self, repository, ref):
        value = self.request(f"repos/{repository}/commits/{urllib.parse.quote(ref, safe='')}")["sha"]
        if not SHA.fullmatch(value):
            raise ValueError("GitHub did not resolve an exact commit")
        return value


def discover(args, api):
    base = api.commit(FORK, "main")
    if args.upstream_sha:
        if not SHA.fullmatch(args.upstream_sha):
            raise ValueError("Manual selection requires a full upstream SHA")
        upstream = api.commit(UPSTREAM, args.upstream_sha)
        label = "sha-" + upstream[:12]
    else:
        release = api.request(f"repos/{UPSTREAM}/releases/latest")
        if release["draft"] or release["prerelease"]:
            raise ValueError("Discovery requires a stable published release")
        label = release["tag_name"]
        upstream = api.commit(UPSTREAM, label)
    with tempfile.TemporaryDirectory(prefix="nativ-discovery-") as temporary:
        work = Path(temporary) / "source"
        git(Path(temporary), "clone", "--no-checkout", "--no-tags", f"https://github.com/{FORK}.git", str(work))
        git(work, "fetch", "--no-tags", f"https://github.com/{UPSTREAM}.git", upstream)
        if not args.upstream_sha:
            # Separate namespace: never import upstream release tags as fork tags.
            ref = "refs/upstream-tags/" + label
            git(work, "fetch", "--no-tags", f"https://github.com/{UPSTREAM}.git", f"refs/tags/{label}:{ref}")
            if git(work, "rev-parse", ref + "^{commit}").stdout.strip() != upstream:
                raise ValueError("Upstream tag changed during discovery")
            validate_tag_identity(label, upstream, read_baseline(work, base).get("tag_identities", {}))
        elif git(work, "merge-base", "--is-ancestor", upstream, api.commit(UPSTREAM, "main"), check=False).returncode != 0:
            git(work, "fetch", "--no-tags", f"https://github.com/{UPSTREAM}.git", "main")
            if git(work, "merge-base", "--is-ancestor", upstream, "FETCH_HEAD", check=False).returncode != 0:
                raise ValueError("Selected SHA is not in upstream main history")
        return prepare_candidate(work, base, upstream, label, args.output, args.reviewed_patch_sha256,
                                 source_kind="main-sha" if args.upstream_sha else "release")


def publish(args, api):
    directory = Path(args.input)
    report = json.loads((directory / "report.json").read_text())
    if report.get("status") != "ready" or report.get("repository") != FORK:
        raise ValueError("Only a reviewed, mergeable fork candidate can be published")
    base, upstream, head = (report[k] for k in ("base_sha", "upstream_sha", "head_sha"))
    if not all(SHA.fullmatch(s) for s in (base, upstream, head)):
        raise ValueError("Invalid candidate identities")
    if api.commit(FORK, "main") != base:
        raise ValueError("Stale fork base; discover a fresh candidate")
    source_kind = report.get("source_kind")
    if source_kind == "release":
        if api.commit(UPSTREAM, report["label"]) != upstream:
            raise ValueError("Upstream tag moved after discovery; review required")
    elif source_kind == "main-sha":
        ancestry = api.request(f"repos/{UPSTREAM}/compare/{upstream}...main")
        if (report["label"] != "sha-" + upstream[:12]
                or ancestry.get("merge_base_commit", {}).get("sha") != upstream
                or ancestry.get("status") not in {"ahead", "identical"}):
            raise ValueError("Selected SHA is not in upstream main history")
    else:
        raise ValueError("Candidate does not identify its upstream source kind")
    branch = report["branch"]
    if not re.fullmatch(r"sync/upstream-[A-Za-z0-9._-]+", branch):
        raise ValueError("Invalid immutable candidate branch")
    if not branch.endswith("-" + upstream[:12] + "-" + base[:12]):
        raise ValueError("Candidate branch does not identify the exact upstream and fork base")
    with tempfile.TemporaryDirectory(prefix="nativ-publish-") as temporary:
        work = Path(temporary)
        git(work, "init")
        git(work, "bundle", "verify", str((directory / "candidate.bundle").resolve()))
        git(work, "fetch", "--no-tags", str((directory / "candidate.bundle").resolve()), branch)
        if git(work, "rev-parse", "FETCH_HEAD").stdout.strip() != head:
            raise ValueError("Candidate bundle identity mismatch")
        validate_candidate_merge(work, head, base, upstream, report["label"], source_kind)
        patch = git(work, "diff", "--binary", "--no-ext-diff", "--no-textconv", base + "..." + upstream).stdout
        digest = hashlib.sha256(patch.encode()).hexdigest()
        paths = git(work, "diff", "--no-renames", "--name-only", "-z", base + "..." + upstream).stdout.rstrip("\0").split("\0")
        if digest != report["patch_sha256"]:
            raise ValueError("Imported patch changed after review")
        if any(needs_workflow_review(p) for p in paths) and digest != args.reviewed_patch_sha256:
            raise ValueError("Explicit workflow review required before candidate push")
        remote = f"https://github.com/{FORK}.git"
        existing = git(work, "ls-remote", remote, "refs/heads/" + branch).stdout.split()
        if existing and existing[0] != head:
            # Repeated preparation produces a different commit timestamp. Preserve the
            # first immutable branch if it has the exact parents and resulting tree.
            git(work, "fetch", "--no-tags", remote, existing[0])
            head = validate_existing_candidate(work, existing[0], head, base, upstream)
        if not existing:
            credential = base64.b64encode(("x-access-token:" + api.token).encode()).decode()
            push_candidate(work, remote, head, branch, {
                "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "http.https://github.com/.extraheader",
                "GIT_CONFIG_VALUE_0": "AUTHORIZATION: basic " + credential})
    prs = api.request(f"repos/{FORK}/pulls?state=open&head={urllib.parse.quote(FORK.split('/')[0] + ':' + branch)}&base=main")
    if not prs:
        body = (f"Upstream: `{UPSTREAM}` / `{report['label']}` / `{upstream}`\n\n"
                f"Fork base: `{base}`\n\nCombined merge: `{head}`\n\n"
                "Normal merge preserves both histories. Review the protected integration paths and all required checks. "
                "Use a merge commit only; no squash/rebase or automatic merge. If main changes, create a new candidate.\n\n"
                "Changed integration paths:\n" + "\n".join("- `" + p + "`" for p in report["changed_paths"]) +
                "\n\nGITHUB_TOKEN mode: approve the PR workflow runs in the merge box. Push-triggered workflows do not run recursively. "
                "GitHub App mode starts normal PR validation. No checks are inferred from other commits.")
        prs = [api.request(f"repos/{FORK}/pulls", "POST", {"title": "Review upstream " + report["label"],
                           "head": branch, "base": "main", "body": body, "draft": True})]
    return {**report, "head_sha": head, "pull_request": prs[0]["html_url"], "status": "published"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    discovery = sub.add_parser("discover")
    discovery.add_argument("--upstream-sha", default="")
    discovery.add_argument("--output", type=Path, required=True)
    publication = sub.add_parser("publish")
    publication.add_argument("--input", type=Path, required=True)
    for child in (discovery, publication):
        child.add_argument("--reviewed-patch-sha256", default="")
    gate = sub.add_parser("gate")
    gate.add_argument("--results", required=True)
    gate.add_argument("--head", required=True)
    gate.add_argument("--base", required=True)
    gate.add_argument("--pr", default="")
    args = parser.parse_args()
    api = GitHub(os.environ.get("GH_TOKEN", ""))
    if args.command == "gate":
        current_head, current_base = args.head, api.commit(FORK, "main")
        if args.pr:
            pr = api.request(f"repos/{FORK}/pulls/{int(args.pr)}")
            if pr["base"]["ref"] != "main" or pr["base"]["sha"] != current_base:
                raise ValueError("Pull request base is stale or does not target fork main")
            current_head = pr["head"]["sha"]
        validate_gate(json.loads(args.results), args.head, args.base, current_head, current_base)
        return
    try:
        result = discover(args, api) if args.command == "discover" else publish(args, api)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        # Failed discovery still produces a retained, non-secret report when Issues
        # are disabled. Never change integrated metadata or report a green no-op.
        if args.command == "discover":
            args.output.mkdir(parents=True, exist_ok=True)
            (args.output / "report.json").write_text(json.dumps({
                "schema": 1, "status": "error", "repository": FORK,
                "checked_at": datetime.now(timezone.utc).isoformat(),
                "error": str(error)[:2000],
            }, indent=2) + "\n")
        raise
    result["checked_at"] = datetime.now(timezone.utc).isoformat()
    if args.command == "discover":
        (args.output / "report.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as handle:
            handle.write("### Upstream discovery\n\n```json\n" + json.dumps(result, indent=2) + "\n```\n")
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as handle:
            handle.write("status=" + result["status"] + "\n")


if __name__ == "__main__":
    main()
