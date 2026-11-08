import base64
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import tempfile
import unittest
import stat
import zipfile

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


if __name__ == "__main__":
    unittest.main()
