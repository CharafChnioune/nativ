import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import urllib.error

SCRIPT = Path(__file__).resolve().parents[1] / "sync_upstream.py"


class UpstreamSyncTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "source"
        self.repo.mkdir()
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.base = self.commit("Sources/base.swift", "base")
        spec = importlib.util.spec_from_file_location("sync_upstream", SCRIPT)
        self.module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = self.module
        spec.loader.exec_module(self.module)

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.repo), *args], stderr=subprocess.DEVNULL, text=True).strip()

    def commit(self, path, content):
        file = self.repo / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(content)
        self.git("add", path)
        self.git("commit", "-m", path)
        return self.git("rev-parse", "HEAD")

    def candidate(self, upstream, **options):
        out = self.root / ("out-" + str(len(list(self.root.glob("out-*")))))
        return self.module.prepare_candidate(self.repo, self.git("rev-parse", "main"), upstream, "v1.0.1", out, **options)

    def test_noop_does_not_create_refs_or_change_worktree(self):
        before = self.git("show-ref")
        result = self.candidate(self.base)
        self.assertEqual(result["status"], "noop")
        self.assertEqual(self.git("show-ref"), before)
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertFalse((self.root / "out-0/candidate.bundle").exists())

    def test_normal_merge_retains_both_parents_and_current_base_identity(self):
        self.git("checkout", "-b", "upstream", self.base)
        upstream = self.commit("Sources/upstream.swift", "upstream")
        self.git("checkout", "main")
        fork = self.commit("Sources/fork.swift", "fork")
        result = self.candidate(upstream)
        self.assertEqual(result["status"], "ready")
        self.assertIn(fork[:12], result["branch"])
        self.assertIn(upstream[:12], result["branch"])
        self.assertEqual(result["parents"], [fork, upstream])
        self.assertEqual(self.git("rev-parse", "main"), fork)
        newer = self.commit("Sources/fork-2.swift", "new base")
        other = self.candidate(upstream)
        self.assertNotEqual(other["branch"], result["branch"])
        self.assertEqual(other["base_sha"], newer)

    def test_conflicts_leave_main_unchanged_and_produce_patch(self):
        self.git("checkout", "-b", "upstream", self.base)
        upstream = self.commit("Sources/base.swift", "upstream edit")
        self.git("checkout", "main")
        fork = self.commit("Sources/base.swift", "fork edit")
        result = self.candidate(upstream)
        self.assertEqual(result["status"], "conflict")
        self.assertEqual(result["conflicts"], ["Sources/base.swift"])
        self.assertEqual(self.git("rev-parse", "main"), fork)
        self.assertFalse((self.repo / ".git/MERGE_HEAD").exists())
        self.assertTrue((self.root / "out-0/candidate.patch").stat().st_size)

    def test_privileged_import_blocks_bundle_before_any_push(self):
        self.git("checkout", "-b", "upstream", self.base)
        upstream = self.commit(".github/actions/local/action.yml", "runs: {using: composite}")
        self.git("checkout", "main")
        result = self.candidate(upstream)
        self.assertEqual(result["status"], "workflow-review-required")
        self.assertFalse((self.root / "out-0/candidate.bundle").exists())
        reviewed = self.candidate(upstream, reviewed_patch_sha256=result["patch_sha256"])
        self.assertEqual(reviewed["status"], "ready")
        wrong = self.candidate(upstream, reviewed_patch_sha256="f" * 64)
        self.assertEqual(wrong["status"], "workflow-review-required")

    def test_invoked_scripts_are_conservatively_protected(self):
        for path in ["scripts/build.sh", "PythonDistribution/Scripts/build.py", "Makefile", "project.yml", ".github/workflows/test.yml", "custom-action/dist/index.js", "local-action/Dockerfile", "Tools/release-helper"]:
            self.assertTrue(self.module.needs_workflow_review(path), path)
        self.assertFalse(self.module.needs_workflow_review("Sources/Nativ/Foo.swift"))

    def test_quoted_git_paths_cannot_bypass_workflow_review(self):
        self.git("checkout", "-b", "upstream", self.base)
        upstream = self.commit(".github/actions/réview\n/action.yml", "runs: {using: composite}")
        self.git("checkout", "main")
        result = self.candidate(upstream)
        self.assertEqual(result["status"], "workflow-review-required")
        self.assertFalse((self.root / "out-0/candidate.bundle").exists())

    def test_moved_tag_is_rejected_without_updating_registry(self):
        recorded = {"v0.4.5": self.base}
        with self.assertRaisesRegex(ValueError, "moved"):
            self.module.validate_tag_identity("v0.4.5", "a" * 40, recorded)
        self.assertEqual(recorded["v0.4.5"], self.base)

    def test_every_stable_release_tag_is_recorded_not_only_v_prefixed_tags(self):
        metadata = self.module.candidate_metadata(self.repo, self.base, "a" * 40, "stable-2026.11")
        self.assertEqual(metadata["tag_identities"]["stable-2026.11"], "a" * 40)

    def test_gate_rejects_missing_skipped_cancelled_failed_and_stale_checks(self):
        good = {"python": "success", "swift": "success", "macos": "success"}
        self.module.validate_gate(good, "a" * 40, "b" * 40, "a" * 40, "b" * 40)
        for status in ["skipped", "cancelled", "failure", "", None]:
            with self.assertRaises(ValueError):
                self.module.validate_gate({**good, "swift": status}, "a" * 40, "b" * 40, "a" * 40, "b" * 40)
        with self.assertRaises(ValueError):
            self.module.validate_gate({"python": "success"}, "a" * 40, "b" * 40, "a" * 40, "b" * 40)
        with self.assertRaisesRegex(ValueError, "stale"):
            self.module.validate_gate(good, "a" * 40, "b" * 40, "a" * 40, "c" * 40)

    def test_existing_immutable_candidate_is_reused_but_human_edits_are_not_overwritten(self):
        self.git("checkout", "-b", "upstream", self.base)
        upstream = self.commit("Sources/upstream.swift", "new")
        self.git("checkout", "main")
        fork = self.commit("Sources/fork.swift", "fork")
        result = self.candidate(upstream)
        self.git("fetch", str(self.root / "out-0/candidate.bundle"), result["branch"])
        head = self.git("rev-parse", "FETCH_HEAD")
        self.assertEqual(self.module.validate_existing_candidate(self.repo, head, head, fork, upstream), head)
        self.git("checkout", "-b", "human-review", head)
        changed = self.commit("Sources/review.swift", "preserve this edit")
        with self.assertRaisesRegex(ValueError, "human"):
            self.module.validate_existing_candidate(self.repo, changed, head, fork, upstream)
        self.assertEqual(self.git("rev-parse", "human-review"), changed)

    def test_api_failure_retains_report_without_claiming_success(self):
        output = self.root / "api-failure"
        failure = urllib.error.HTTPError("https://api.github.com/", 503, "Unavailable", {}, None)
        with patch.object(sys, "argv", ["sync_upstream.py", "discover", "--output", str(output)]), \
                patch.object(self.module.GitHub, "commit", side_effect=failure):
            with self.assertRaises(urllib.error.HTTPError):
                self.module.main()
        report = json.loads((output / "report.json").read_text())
        self.assertEqual(report["status"], "error")
        self.assertIn("503", report["error"])
        self.assertFalse((output / "candidate.bundle").exists())

    def test_candidate_bundle_cannot_add_unreviewed_tree_changes_with_valid_parents(self):
        self.git("checkout", "-b", "upstream", self.base)
        upstream = self.commit("Sources/upstream.swift", "new")
        self.git("checkout", "main")
        base = self.commit("Sources/fork.swift", "fork")
        result = self.candidate(upstream)
        self.git("fetch", str(self.root / "out-0/candidate.bundle"), result["branch"])
        head = self.git("rev-parse", "FETCH_HEAD")
        self.module.validate_candidate_merge(self.repo, head, base, upstream, result["label"])
        self.git("checkout", "-b", "forged", head)
        self.commit(".github/workflows/injected.yml", "name: unreviewed executable workflow")
        tree = self.git("rev-parse", "HEAD^{tree}")
        forged = self.git("commit-tree", tree, "-p", base, "-p", upstream, "-m", "forged candidate")
        self.assertEqual(self.git("show", "-s", "--format=%P", forged), base + " " + upstream)
        with self.assertRaisesRegex(ValueError, "tree"):
            self.module.validate_candidate_merge(self.repo, forged, base, upstream, result["label"])

    def test_publish_ref_creation_cannot_advance_a_branch_created_during_race(self):
        remote = self.root / "remote.git"
        subprocess.run(["git", "init", "--bare", str(remote)], check=True, capture_output=True)
        branch = "sync/upstream-race"
        self.git("push", str(remote), self.base + ":refs/heads/" + branch)
        candidate = self.commit("Sources/candidate.swift", "candidate")
        with self.assertRaises(subprocess.CalledProcessError):
            self.module.push_candidate(self.repo, str(remote), candidate, branch, {})
        self.assertEqual(self.git("ls-remote", str(remote), "refs/heads/" + branch).split()[0], self.base)


if __name__ == "__main__":
    unittest.main()
