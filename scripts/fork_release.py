#!/usr/bin/env python3
"""Fail-closed validation of this fork's source identity and built distribution."""
from __future__ import annotations

import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import posixpath
import re
import stat
import subprocess
import sys
import tempfile
import zipfile
from datetime import datetime, timezone

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sync_upstream import FORK, GitHub, SHA
from macos_release import GitHub as ReleaseGitHub, release_items, version_info

NAMESPACE = "io.github.charafchnioune.nativ"
UPSTREAM_KEY = "A8x4wdNekd1aoWpU8bVdsNdOFzuua8nC1mfLCwGDSPk="
STABLE = f"https://github.com/{FORK}/releases/latest/download/appcast.xml"
PREVIEW = f"https://github.com/{FORK}/releases/download/preview/appcast.xml"


def validate_archive(archive_path):
    """Reject writes outside the extracted app, including symlink-chain escapes."""
    links, paths = {}, []
    with zipfile.ZipFile(archive_path) as archive:
        seen = set()
        for entry in archive.infolist():
            name = entry.filename.rstrip("/")
            path = PurePosixPath(name)
            if (not name or name in seen or path.is_absolute() or ".." in path.parts
                    or path.parts[0] not in {"Nativ.app", "__MACOSX"}
                    or posixpath.normpath(name) != name or "\\" in name or "\0" in name):
                raise ValueError("Unsafe release archive path")
            seen.add(name)
            paths.append(name)
            kind = stat.S_IFMT(entry.external_attr >> 16)
            if kind not in {0, stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK}:
                raise ValueError("Unsafe release archive member type")
            if kind == stat.S_IFLNK:
                if path.parts[0] != "Nativ.app" or entry.file_size > 4096:
                    raise ValueError("Unsafe release archive symlink")
                target = archive.read(entry).decode("utf-8", errors="strict")
                if not target or target.startswith("/") or "\\" in target or "\0" in target:
                    raise ValueError("Unsafe release archive symlink target")
                links[name] = target

    def resolve(name, visited=()):
        parts = PurePosixPath(name).parts
        for count in range(1, len(parts) + 1):
            prefix = "/".join(parts[:count])
            if prefix in links:
                if prefix in visited:
                    raise ValueError("Cyclic release archive symlink")
                target = posixpath.normpath(posixpath.join(posixpath.dirname(prefix), links[prefix], *parts[count:]))
                if target != "Nativ.app" and not target.startswith("Nativ.app/"):
                    raise ValueError("Release archive symlink escapes the app")
                return resolve(target, visited + (prefix,))
        return name

    for name in paths:
        resolve(name)


def next_build(tag, records, clock):
    key = version_info(tag)[3]
    if any(record[0] >= key for record in records):
        raise ValueError("Every fork release version must advance independently of upstream")
    return max([clock - 1] + [record[1] for record in records]) + 1


def release_build_number(tag):
    github = ReleaseGitHub(FORK)
    records = release_items(github, github.releases())
    clock = int(datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S"))
    return next_build(tag, records, clock)


def validate_info(info, sha):
    expected = {"CFBundleIdentifier": NAMESPACE, "NativForkRepository": FORK,
                "SUFeedURL": STABLE, "NativPreviewFeedURL": PREVIEW, "NativForkRevision": sha}
    for key, value in expected.items():
        if info.get(key) != value:
            raise ValueError(f"Fork archive {key} does not match its validated identity")
    key = info.get("SUPublicEDKey", "")
    try:
        valid_key = key != UPSTREAM_KEY and len(base64.b64decode(key, validate=True)) == 32
    except (ValueError, TypeError):
        valid_key = False
    if not valid_key:
        raise ValueError("The fork's own Sparkle public key is required")
    if info.get("SURequireSignedFeed") is not True or info.get("SUVerifyUpdateBeforeExtraction") is not True:
        raise ValueError("Fork updates require signed feeds and archive verification before extraction")
    if not re.fullmatch(r"[1-9][0-9]*", info.get("CFBundleVersion", "")):
        raise ValueError("Fork build number must be a positive integer")
    if not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", info.get("CFBundleShortVersionString", "")):
        raise ValueError("Fork marketing version must be numeric")
    client, slug = (info.get(key, "") for key in ("NativGitHubAppClientID", "NativGitHubAppSlug"))
    if bool(client) != bool(slug):
        raise ValueError("Optional GitHub OAuth configuration requires both client ID and app slug")
    if client and (not re.fullmatch(r"[A-Za-z0-9_.-]+", client)
                   or not re.fullmatch(r"[A-Za-z0-9-]+", slug)):
        raise ValueError("Invalid GitHub OAuth public configuration")


def validate_run(run, sha):
    expected = {"head_sha": sha, "head_branch": "main", "event": "push", "status": "completed",
                "conclusion": "success", "path": ".github/workflows/translation-ci.yml"}
    if any(run.get(key) != value for key, value in expected.items()):
        raise ValueError("Release requires the completed validation of this exact combined main commit")


def validate_release_identity(tag, tag_sha, validated_sha, main_sha):
    if not re.fullmatch(r"v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:rc[1-9][0-9]*)?", tag):
        raise ValueError("Release tag must use the independent numeric fork version")
    if not SHA.fullmatch(validated_sha) or tag_sha != validated_sha or main_sha != validated_sha:
        raise ValueError("Release tag/main do not resolve to the exact validated combined commit")


def validate_bundle_resources(app, *, verify_imports=False):
    """Validate trusted source membership without executing candidate artifact code.

    Imports are opt-in for the unsigned build job. The signing job inherits secrets
    and must only perform the static checks, even for an apparently valid artifact.
    """
    app = Path(app).resolve(strict=True)
    source = Path(__file__).resolve().parents[1] / "PythonDistribution"
    script = source / "Scripts/build_mlx_vlm_server.py"
    sys.path.insert(0, str(script.parent))
    try:
        spec = importlib.util.spec_from_file_location("release_resource_builder", script)
        builder = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = builder
        spec.loader.exec_module(builder)
    finally:
        sys.path.pop(0)
    runtime = app / "Contents/Frameworks/NativServerKit.framework/Resources/mlx-vlm-server"

    def inside(path, *, executable=False):
        try:
            resolved = path.resolve(strict=True)
            if not resolved.is_relative_to(app) or not resolved.is_file():
                raise ValueError("path escapes app or is not a file")
            if executable and not os.access(resolved, os.X_OK):
                raise ValueError("not executable")
            return resolved
        except (OSError, ValueError) as error:
            raise ValueError(f"Invalid bundled generation resource: {path.name}") from error

    try:
        python = inside(runtime / "python/bin/python3", executable=True)
        inside(runtime / "bin/mlx-vlm-server", executable=True)
        site = builder.site_packages_dir(runtime)
        for path in (site, runtime):
            if not path.resolve().is_relative_to(app):
                raise ValueError("Generation package directory escapes app")
        for source_tree in builder.OVERLAY_PACKAGES:
            if builder.tree_fingerprint(site / source_tree.name) != builder.tree_fingerprint(source_tree):
                raise ValueError(f"Packaged overlay differs: {source_tree.name}")
        for source_tree in builder.RUNTIME_RESOURCES:
            actual = builder.tree_fingerprint(runtime / source_tree.name)
            if source_tree.name == "CodecRuntime":
                actual = {key: value for key, value in actual.items() if not key.startswith("managed/")}
            if actual != builder.tree_fingerprint(source_tree):
                raise ValueError(f"Packaged runtime resources differ: {source_tree.name}")
        # The managed codec is mandatory even on publishers without dist/codec-runtime.
        managed = runtime / "CodecRuntime/managed"
        manifest_path = inside(runtime / "CodecRuntime/manifest.json")
        manifest = json.loads(manifest_path.read_text())
        receipt = json.loads(inside(managed / "receipt.json").read_text())
        digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
        if (receipt.get("schema_version") != 1 or receipt.get("id") != manifest["id"]
                or receipt.get("manifest_sha256") != digest(manifest_path)
                or receipt.get("sources") != manifest["sources"]
                or receipt.get("builder_sha256") != digest(source / "CodecRuntime/manage.py")
                or receipt.get("qualification") != "codec_smoke_passed"):
            raise ValueError("Managed codec provenance or media qualification is invalid")
        for name in ("ffmpeg", "ffprobe"):
            relative = "bin/" + name
            binary = inside(managed / relative, executable=True)
            if digest(binary) != receipt.get("files", {}).get(relative):
                raise ValueError("Managed codec hash mismatch")
            if not re.fullmatch(r"[0-9a-f]{64}", receipt.get("build_files", receipt["files"]).get(relative, "")):
                raise ValueError("Managed codec build provenance is missing")
        # Check source files omitted by the package-tree verifier as well.
        for name in ("nativ_server.py", "nativ_translation_local.py", "nativ_cluster.py"):
            if digest(inside(site / name)) != digest(source / "Overlay" / name):
                raise ValueError("Packaged server overlay differs from validated source")
    except (SystemExit, OSError, KeyError, TypeError, ValueError) as error:
        raise ValueError(f"Invalid bundled generation resources: {error}") from error
    if verify_imports:
        code = """import json,pathlib,sys
import nativ_generation,nativ_music.catalog,nativ_video.catalog
root=pathlib.Path(sys.argv[1]).resolve()
modules=(nativ_generation,nativ_music.catalog,nativ_video.catalog)
assert all(pathlib.Path(m.__file__).resolve().is_relative_to(root) for m in modules)
assert nativ_music.catalog.profiles() and nativ_video.catalog.profiles()
print(json.dumps({'packaged_generation_imports':'ok'}))
"""
        with tempfile.TemporaryDirectory(prefix="nativ-release-imports-") as directory:
            # No PYTHONPATH, user site, repository cwd, signing or provider secrets.
            env = {"PATH": "/usr/bin:/bin", "HOME": directory, "TMPDIR": directory}
            try:
                result = subprocess.run([str(python), "-I", "-B", "-c", code, str(runtime.resolve())],
                                        cwd=directory, env=env, capture_output=True, text=True, timeout=45)
                if result.returncode or result.stdout.strip() != '{"packaged_generation_imports": "ok"}':
                    raise ValueError("Packaged generation imports failed outside source checkout")
            except (OSError, subprocess.TimeoutExpired) as error:
                raise ValueError("Packaged generation imports did not complete") from error


def validate_bundle(app, sha, *, verify_imports=False):
    app = Path(app)
    with (app / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    validate_info(info, sha)
    framework = app / "Contents/Frameworks/NativTranslationKit.framework"
    if not framework.exists():
        raise ValueError("Archive is missing NativTranslationKit")
    helper = app / "Contents/Resources/LFMRealtime/bin/llama-server"
    if not helper.is_file() or helper.is_symlink():
        raise ValueError("Archive is missing its managed LFM3 helper")
    bundles = list((app / "Contents/Extensions").glob("*.appex"))
    if not bundles:
        bundles = list((app / "Contents/PlugIns").glob("*.appex"))
    if not bundles:
        raise ValueError("Archive is missing its embedded extension runtime")
    for extension in bundles:
        with (extension / "Contents/Info.plist").open("rb") as handle:
            metadata = plistlib.load(handle)
        if not metadata.get("CFBundleIdentifier", "").startswith(NAMESPACE + "."):
            raise ValueError("Embedded extension uses an upstream bundle identity")
        if metadata.get("EXAppExtensionAttributes", {}).get("EXExtensionPointIdentifier") != NAMESPACE + ".nativ-extension":
            raise ValueError("Embedded extension is bound to another app")
    required_extensions = {"VoiceDictationExtensionRuntime.appex", "LiveTranslationExtensionRuntime.appex"}
    if not required_extensions.issubset({bundle.name for bundle in bundles}):
        raise ValueError("Archive must contain both Audio and Live Translation extension runtimes")
    for name in ("NativTranslationKit", "NativServerKit", "NativExtensionSDK"):
        root = app / ("Contents/Frameworks/" + name + ".framework")
        with (root / "Resources/Info.plist").open("rb") as handle:
            metadata = plistlib.load(handle)
        if metadata.get("CFBundleIdentifier") != NAMESPACE + "." + name:
            raise ValueError("Embedded framework uses an upstream bundle identity")
    validate_bundle_resources(app, verify_imports=verify_imports)
    return info


def validate_sources(root):
    root = Path(root)
    for feature, extension_id, bundle in [
        ("VoiceDictation", "voice-dictation", "VoiceDictationExtension"),
        ("LiveTranslation", "translation", "LiveTranslationExtension"),
    ]:
        folder = root / "Extensions" / feature
        manifest = json.loads((folder / "Manifest.json").read_text())
        expected = {"id": NAMESPACE + "." + extension_id,
                    "extensionPoint": NAMESPACE + ".nativ-extension",
                    "runtimeBundleIdentifier": NAMESPACE + "." + bundle}
        if any(manifest.get(key) != value for key, value in expected.items()):
            raise ValueError(f"{feature} manifest identity must match its fork host and runtime")
        runtime = (folder / "Runtime" / (feature + "ExtensionRuntime.swift")).read_text()
        if f'context.extensionID == "{expected["id"]}"' not in runtime:
            raise ValueError(f"{feature} runtime identity must match its manifest")
    runtime = (root / "Extensions/VoiceDictation/Runtime/VoiceDictationExtensionRuntime.swift").read_text()
    if f'host: "{NAMESPACE}"' not in runtime or 'name: "nativ-extension"' not in runtime:
        raise ValueError("Actual ExtensionFoundation binding must match the fork namespace")
    with (root / "Configuration/AudioExtension-Info.plist").open("rb") as handle:
        extension = plistlib.load(handle)
    if extension["EXAppExtensionAttributes"]["EXExtensionPointIdentifier"] != "$(NATIV_BUNDLE_IDENTIFIER).nativ-extension":
        raise ValueError("Embedded extension point must expand the same fork host identity")
    config = (root / "Configuration/Fork.xcconfig").read_text()
    if "NATIV_BUNDLE_IDENTIFIER = " + NAMESPACE not in config:
        raise ValueError("Fork namespace is not configured")
    runtime = (root / "Extensions/LiveTranslation/Runtime/LiveTranslationExtensionRuntime.swift").read_text()
    if f'host: "{NAMESPACE}"' not in runtime or 'name: "nativ-extension"' not in runtime:
        raise ValueError("Live Translation runtime must bind to this fork")
    with (root / "Configuration/LiveTranslationExtension-Info.plist").open("rb") as handle:
        translation = plistlib.load(handle)
    if translation["EXAppExtensionAttributes"]["EXExtensionPointIdentifier"] not in {
        "$(NATIV_BUNDLE_IDENTIFIER).nativ-extension", NAMESPACE + ".nativ-extension"
    }:
        raise ValueError("Live Translation extension point differs from the fork host")


def preflight(api, sha, tag):
    validate_release_identity(tag, api.commit(FORK, tag), sha, api.commit(FORK, "main"))
    runs = api.request(f"repos/{FORK}/actions/workflows/translation-ci.yml/runs?head_sha={sha}&event=push&per_page=100")["workflow_runs"]
    candidates = sorted((run for run in runs if run["head_sha"] == sha), key=lambda run: run["id"], reverse=True)
    if not candidates:
        raise ValueError("No validation run for this exact release commit")
    validate_run(candidates[0], sha)
    jobs = api.request(f"repos/{FORK}/actions/runs/{candidates[0]['id']}/jobs?filter=latest&per_page=100")["jobs"]
    required = {"Python regressions", "Translation contracts", "Native app and regressions", "Required validation gate"}
    successful = {job["name"] for job in jobs if job["status"] == "completed" and job["conclusion"] == "success"}
    if not required.issubset(successful):
        raise ValueError("Release validation is missing successful required jobs")
    return candidates[0]["id"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    source = sub.add_parser("sources")
    source.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    bundle = sub.add_parser("bundle")
    bundle.add_argument("app", type=Path)
    bundle.add_argument("--sha", required=True)
    bundle.add_argument("--verify-imports", action="store_true", help="Execute lightweight bundled imports in the unsigned build job only")
    archive = sub.add_parser("archive")
    archive.add_argument("path", type=Path)
    check = sub.add_parser("preflight")
    check.add_argument("--sha", required=True)
    check.add_argument("--tag", required=True)
    args = parser.parse_args()
    if args.command == "sources":
        validate_sources(args.root)
    elif args.command == "bundle":
        validate_bundle(args.app, args.sha, verify_imports=args.verify_imports)
    elif args.command == "archive":
        validate_archive(args.path)
    else:
        run = preflight(GitHub(os.environ.get("GH_TOKEN", "")), args.sha, args.tag)
        print(json.dumps({"validated_run": run, "sha": args.sha, "tag": args.tag}))


if __name__ == "__main__":
    main()
