import base64
import importlib.util
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import tempfile
import unittest
import stat
import zipfile
from unittest.mock import patch
from types import SimpleNamespace

SCRIPT = Path(__file__).resolve().parents[1] / "fork_release.py"


class ForkReleaseTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("fork_release", SCRIPT)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.info = {
            "CFBundleIdentifier": "io.github.charafchnioune.nativ",
            "CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "1",
            "NativReleaseVersion": "1.0.0", "NativForkRepository": "CharafChnioune/nativ",
            "NativForkRevision": "a" * 40,
            "SUFeedURL": "https://github.com/CharafChnioune/nativ/releases/latest/download/appcast.xml",
            "NativPreviewFeedURL": "https://github.com/CharafChnioune/nativ/releases/download/preview/appcast.xml",
            "SUPublicEDKey": base64.b64encode(b"a" * 32).decode(),
            "SURequireSignedFeed": True, "SUVerifyUpdateBeforeExtraction": True,
            "NativGitHubAppClientID": "owner-client", "NativGitHubAppSlug": "owner-app",
        }

    def test_embedded_metadata_requires_exact_own_feeds_key_and_revision(self):
        self.module.validate_info(self.info, "a" * 40)
        for key, value in [
            ("CFBundleIdentifier", "dev.local.Nativ"),
            ("SUFeedURL", "https://github.com/Neywa-Labs/nativ/releases/latest/download/appcast.xml"),
            ("NativPreviewFeedURL", "https://github.com/Neywa-Labs/nativ/releases/download/preview/appcast.xml"),
            ("SUPublicEDKey", "A8x4wdNekd1aoWpU8bVdsNdOFzuua8nC1mfLCwGDSPk="),
            ("SUPublicEDKey", ""), ("CFBundleVersion", "1-translation"),
            ("SURequireSignedFeed", False), ("SUVerifyUpdateBeforeExtraction", False),
            ("NativForkRevision", "b" * 40), ("NativGitHubAppClientID", ""),
        ]:
            with self.assertRaises(ValueError, msg=key):
                self.module.validate_info({**self.info, key: value}, "a" * 40)

    def test_validation_run_is_exact_completed_main_combined_commit(self):
        run = {"head_sha": "a" * 40, "head_branch": "main", "event": "push", "status": "completed",
               "conclusion": "success", "path": ".github/workflows/translation-ci.yml"}
        self.module.validate_run(run, "a" * 40)
        for key, value in [("head_sha", "b" * 40), ("conclusion", "skipped"), ("status", "in_progress"),
                           ("path", ".github/workflows/other.yml"), ("head_branch", "upstream"), ("event", "pull_request")]:
            with self.assertRaises(ValueError, msg=key):
                self.module.validate_run({**run, key: value}, "a" * 40)

    def test_oauth_is_optional_but_partial_or_invalid_configuration_fails(self):
        self.module.validate_info({**self.info, "NativGitHubAppClientID": "", "NativGitHubAppSlug": ""}, "a" * 40)
        for client, slug in [("", "app"), ("client", ""), ("$(INHERITED)", "app"), ("client", "bad/slug")]:
            with self.assertRaisesRegex(ValueError, "OAuth"):
                self.module.validate_info({**self.info, "NativGitHubAppClientID": client,
                                           "NativGitHubAppSlug": slug}, "a" * 40)

    def test_tag_and_numeric_version_must_match_validated_fork_commit(self):
        self.module.validate_release_identity("v1.0.0", "a" * 40, "a" * 40, "a" * 40)
        with self.assertRaises(ValueError):
            self.module.validate_release_identity("v0.4.5", "b" * 40, "a" * 40, "a" * 40)
        with self.assertRaises(ValueError):
            self.module.validate_release_identity("v1.0.0-fork", "a" * 40, "a" * 40, "a" * 40)

    def test_real_bundle_requires_feature_and_helper_and_own_extension(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Nativ.app"
            (app / "Contents").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(self.info))
            with self.assertRaisesRegex(ValueError, "Translation"):
                self.module.validate_bundle(app, "a" * 40)

    def test_builds_and_public_versions_increase_independently_of_upstream(self):
        self.assertEqual(self.module.next_build("v1.1.0", [((1, 0, 0, True, 0), 900)], 800), 901)
        self.assertEqual(self.module.next_build("v1.0.0", [], 100), 100)
        with self.assertRaises(ValueError):
            self.module.next_build("v1.0.0", [((1, 0, 0, True, 0), 900)], 1000)

    def test_release_zip_rejects_symlink_escape_before_extracting(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "candidate.zip"
            def write(target):
                with zipfile.ZipFile(archive, "w") as zipped:
                    info = zipfile.ZipInfo("Nativ.app/Contents/Frameworks/Escape")
                    info.create_system = 3
                    info.external_attr = (stat.S_IFLNK | 0o777) << 16
                    zipped.writestr(info, target)
                    zipped.writestr("Nativ.app/Contents/Frameworks/Escape/publisher.py", "untrusted")
            for target in ["../../../../scripts", "/tmp/outside", "Escape"]:
                write(target)
                with self.assertRaisesRegex(ValueError, "archive"):
                    self.module.validate_archive(archive)

    def test_release_zip_preserves_internal_framework_links(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "candidate.zip"
            with zipfile.ZipFile(archive, "w") as zipped:
                zipped.writestr("Nativ.app/Contents/Frameworks/Test.framework/Versions/A/Test", "binary")
                for name, target in [("Versions/Current", "A"), ("Test", "Versions/Current/Test")]:
                    info = zipfile.ZipInfo("Nativ.app/Contents/Frameworks/Test.framework/" + name)
                    info.create_system = 3
                    info.external_attr = (stat.S_IFLNK | 0o777) << 16
                    zipped.writestr(info, target)
            self.module.validate_archive(archive)

    def test_manifest_runtime_and_host_identities_must_match(self):
        root = SCRIPT.parent.parent
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory)
            for path in ("Extensions/VoiceDictation", "Extensions/LiveTranslation", "Configuration"):
                shutil.copytree(root / path, fixture / path)
            self.module.validate_sources(fixture)
            for feature, extension_id, bundle in [
                ("VoiceDictation", "voice-dictation", "VoiceDictationExtension"),
                ("LiveTranslation", "translation", "LiveTranslationExtension"),
            ]:
                manifest = fixture / "Extensions" / feature / "Manifest.json"
                original = manifest.read_text()
                for key, value in [("id", "com.nativ." + extension_id),
                                   ("extensionPoint", "com.nativ.extension"),
                                   ("runtimeBundleIdentifier", "com.nativ." + bundle)]:
                    data = json.loads(original)
                    data[key] = value
                    manifest.write_text(json.dumps(data))
                    with self.assertRaisesRegex(ValueError, "[Ii]dentity|[Mm]anifest"):
                        self.module.validate_sources(fixture)
                    manifest.write_text(original)
                runtime = fixture / "Extensions" / feature / "Runtime" / (feature + "ExtensionRuntime.swift")
                original_runtime = runtime.read_text()
                runtime.write_text(original_runtime.replace(
                    'context.extensionID == "io.github.charafchnioune.nativ.' + extension_id + '"',
                    'context.extensionID == "com.nativ.' + extension_id + '"'))
                with self.assertRaisesRegex(ValueError, "[Ii]dentity|[Mm]anifest"):
                    self.module.validate_sources(fixture)
                runtime.write_text(original_runtime)



class GenerationReleaseResourceTests(unittest.TestCase):
    """Complete synthetic bundle fixtures; these are not releasable Mach-O apps."""
    def setUp(self):
        spec = importlib.util.spec_from_file_location("fork_release_resources", SCRIPT)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.app = Path(self.tmp.name) / "Nativ.app"
        self.runtime = self.app / "Contents/Frameworks/NativServerKit.framework/Resources/mlx-vlm-server"
        self.site = self.runtime / "python/lib/python3.12/site-packages"
        self.site.mkdir(parents=True)
        source = SCRIPT.parent.parent / "PythonDistribution"
        for name in ("nativ_generation", "nativ_music", "nativ_video"):
            shutil.copytree(source / "Overlay" / name, self.site / name,
                            ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
        for name in ("nativ_server.py", "nativ_translation_local.py", "nativ_cluster.py"):
            shutil.copy2(source / "Overlay" / name, self.site / name)
        for name in ("MusicRuntimes", "VideoRuntimes", "CodecRuntime", "Patches"):
            shutil.copytree(source / name, self.runtime / name,
                            ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
        for path in (self.runtime / "python/bin/python3", self.runtime / "bin/mlx-vlm-server",
                     self.runtime / "CodecRuntime/managed/bin/ffmpeg", self.runtime / "CodecRuntime/managed/bin/ffprobe"):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"synthetic executable fixture")
            path.chmod(0o755)
        digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
        self.receipt_path = self.runtime / "CodecRuntime/managed/receipt.json"
        manifest_path = self.runtime / "CodecRuntime/manifest.json"
        manifest = json.loads(manifest_path.read_text())
        files = {"bin/"+name: digest(self.runtime / "CodecRuntime/managed/bin" / name) for name in ("ffmpeg", "ffprobe")}
        self.receipt = dict(schema_version=1, id=manifest["id"], sources=manifest["sources"],
                            manifest_sha256=digest(manifest_path), builder_sha256=digest(source / "CodecRuntime/manage.py"),
                            qualification="codec_smoke_passed", files=files, build_files=dict(files))
        self.receipt_path.write_text(json.dumps(self.receipt))

    def test_complete_resources_are_required_without_executing_unsigned_artifact(self):
        with patch.object(self.module.subprocess, "run", side_effect=AssertionError("must not execute candidate")):
            self.module.validate_bundle_resources(self.app)
        shutil.rmtree(self.site / "nativ_generation")
        with self.assertRaisesRegex(ValueError, "generation resources"):
            self.module.validate_bundle_resources(self.app)

    def test_identity_only_bundle_cannot_reach_release(self):
        identity = ForkReleaseTests()
        identity.setUp()
        contents = self.app / "Contents"
        (contents / "Info.plist").write_bytes(plistlib.dumps(identity.info))
        for name in ("NativTranslationKit", "NativServerKit", "NativExtensionSDK"):
            resources = contents / "Frameworks" / (name + ".framework") / "Resources"
            resources.mkdir(parents=True, exist_ok=True)
            (resources / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": self.module.NAMESPACE + "." + name}))
        helper = contents / "Resources/LFMRealtime/bin/llama-server"
        helper.parent.mkdir(parents=True); helper.write_bytes(b"fixture")
        for name in ("VoiceDictationExtensionRuntime", "LiveTranslationExtensionRuntime"):
            extension = contents / "Extensions" / (name + ".appex") / "Contents"
            extension.mkdir(parents=True)
            (extension / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": self.module.NAMESPACE + "." + name,
                "EXAppExtensionAttributes": {"EXExtensionPointIdentifier": self.module.NAMESPACE + ".nativ-extension"}}))
        self.module.validate_bundle(self.app, "a" * 40)
        shutil.rmtree(self.runtime)
        with self.assertRaisesRegex(ValueError, "generation resource"):
            self.module.validate_bundle(self.app, "a" * 40)

    def test_deleted_provider_and_changed_runtime_resource_fail(self):
        provider = self.site / "nativ_music/providers/lyria.py"
        original = provider.read_bytes(); provider.unlink()
        with self.assertRaisesRegex(ValueError, "overlay differs"):
            self.module.validate_bundle_resources(self.app)
        provider.write_bytes(original)
        (self.runtime / "VideoRuntimes/manage.py").write_text("incomplete=True")
        with self.assertRaisesRegex(ValueError, "resources differ"):
            self.module.validate_bundle_resources(self.app)

    def test_codec_receipt_and_actual_hash_mandatory_without_local_dist(self):
        self.receipt_path.unlink()
        with self.assertRaisesRegex(ValueError, "generation resource"):
            self.module.validate_bundle_resources(self.app)
        self.receipt_path.write_text(json.dumps(self.receipt))
        (self.runtime / "CodecRuntime/managed/bin/ffmpeg").write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "hash mismatch"):
            self.module.validate_bundle_resources(self.app)

    def test_self_consistent_receipt_with_wrong_provenance_is_rejected(self):
        for key, value in (("manifest_sha256", "0"*64), ("builder_sha256", "0"*64),
                           ("sources", {}), ("qualification", "not_tested")):
            with self.subTest(key=key):
                self.receipt_path.write_text(json.dumps(dict(self.receipt, **{key: value})))
                with self.assertRaisesRegex(ValueError, "provenance"):
                    self.module.validate_bundle_resources(self.app)

    def test_interpreter_symlink_outside_app_is_rejected(self):
        interpreter = self.runtime / "python/bin/python3"
        interpreter.unlink(); interpreter.symlink_to(SCRIPT)
        with self.assertRaisesRegex(ValueError, "generation resource"):
            self.module.validate_bundle_resources(self.app)

    def test_opt_in_imports_are_isolated_and_strip_all_inherited_credentials(self):
        result = SimpleNamespace(returncode=0, stdout='{"packaged_generation_imports": "ok"}\n')
        with patch.dict(self.module.os.environ, {"NATIV_GENERATION_FIXTURE_API_KEY": "sentinel", "CERTIFICATE_PASSWORD": "sentinel"}), \
             patch.object(self.module.subprocess, "run", return_value=result) as run:
            self.module.validate_bundle_resources(self.app, verify_imports=True)
        args, kwargs = run.call_args
        self.assertEqual(args[0][1:3], ["-I", "-B"])
        self.assertEqual(set(kwargs["env"]), {"PATH", "HOME", "TMPDIR"})
        self.assertFalse(Path(kwargs["cwd"]).is_relative_to(SCRIPT.parent.parent))
        with patch.object(self.module.subprocess, "run", return_value=SimpleNamespace(returncode=1, stdout="")):
            with self.assertRaisesRegex(ValueError, "imports failed"):
                self.module.validate_bundle_resources(self.app, verify_imports=True)


if __name__ == "__main__":
    unittest.main()
