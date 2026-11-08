import base64
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import hashlib
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import sparkle_setup
from configure_fork_release import configuration


PUBLIC = base64.b64encode(bytes(range(32))).decode()
OTHER = base64.b64encode(bytes(range(1, 33))).decode()


class SparkleSetupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.config = Path(self.temporary.name) / "Fork.xcconfig"
        self.config.write_text("// retained\nNATIV_SPARKLE_PUBLIC_KEY =\nOTHER = value\n")
        self.calls = []

    def runner(self, keys, status=44):
        outputs = iter(keys)
        def run(arguments, **kwargs):
            self.calls.append(arguments)
            if arguments[0] == "/usr/bin/security":
                return subprocess.CompletedProcess(arguments, status, "", "")
            if arguments[-1] == "-p":
                key = next(outputs)
                return subprocess.CompletedProcess(arguments, 0 if key else 1, key or "", "")
            return subprocess.CompletedProcess(arguments, 0, "public setup message", "")
        return run

    def test_missing_key_requires_explicit_initialization(self):
        original = self.config.read_bytes()
        with self.assertRaisesRegex(ValueError, "initialize"):
            sparkle_setup.configure(self.config, Path("generate_keys"), False, self.runner([None]))
        self.assertEqual(self.config.read_bytes(), original)
        self.assertEqual(len(self.calls), 1)

    def test_initialize_stores_only_public_key_and_preserves_config(self):
        result = sparkle_setup.configure(self.config, Path("generate_keys"), True, self.runner([None, PUBLIC]))
        self.assertTrue(result["created"])
        self.assertEqual(self.config.read_text(), f"// retained\nNATIV_SPARKLE_PUBLIC_KEY = {PUBLIC}\nOTHER = value\n")
        self.assertEqual(self.calls[2], ["generate_keys", "--account", sparkle_setup.ACCOUNT])
        self.assertFalse(any(flag in call for call in self.calls for flag in ("-x", "-f", "-w", "-g")))

    def test_second_run_is_read_only_and_never_rotates(self):
        sparkle_setup.configure(self.config, Path("generate_keys"), False, self.runner([PUBLIC]))
        timestamp = self.config.stat().st_mtime_ns
        self.calls.clear()
        result = sparkle_setup.configure(self.config, Path("generate_keys"), True, self.runner([PUBLIC]))
        self.assertFalse(result["created"])
        self.assertFalse(result["changed"])
        self.assertEqual(self.config.stat().st_mtime_ns, timestamp)
        self.assertEqual(len(self.calls), 1)

    def test_existing_public_key_without_private_key_never_generates_replacement(self):
        self.config.write_text(f"NATIV_SPARKLE_PUBLIC_KEY = {PUBLIC}\n")
        with self.assertRaisesRegex(ValueError, "restore"):
            sparkle_setup.configure(self.config, Path("generate_keys"), True, self.runner([None]))
        self.assertEqual(len(self.calls), 1)

    def test_keychain_denial_is_not_interpreted_as_missing_key(self):
        with self.assertRaisesRegex(ValueError, "Keychain"):
            sparkle_setup.configure(self.config, Path("generate_keys"), True, self.runner([None], status=36))
        self.assertEqual(len(self.calls), 2)

    def test_mismatched_key_fails_without_mutation(self):
        self.config.write_text(f"NATIV_SPARKLE_PUBLIC_KEY = {OTHER}\n")
        original = self.config.read_bytes()
        with self.assertRaisesRegex(ValueError, "match"):
            sparkle_setup.configure(self.config, Path("generate_keys"), True, self.runner([PUBLIC]))
        self.assertEqual(self.config.read_bytes(), original)

    def test_public_key_parser_rejects_duplicate_or_upstream_keys(self):
        for content in ["", "NATIV_SPARKLE_PUBLIC_KEY =\nNATIV_SPARKLE_PUBLIC_KEY =\n",
                        "NATIV_SPARKLE_PUBLIC_KEY = A8x4wdNekd1aoWpU8bVdsNdOFzuua8nC1mfLCwGDSPk=\n"]:
            self.config.write_text(content)
            with self.assertRaises(ValueError):
                sparkle_setup.read_public_key(self.config)

    def test_ci_uses_checked_in_public_key_and_optional_oauth(self):
        self.config.write_text(f"NATIV_SPARKLE_PUBLIC_KEY = {PUBLIC}\n")
        result = configuration("a" * 40, "v1.0.0", {}, self.config)
        self.assertIn(f"NATIV_SPARKLE_PUBLIC_KEY = {PUBLIC}", result)
        self.assertIn("NATIV_GITHUB_APP_CLIENT_ID = \n", result)
        with self.assertRaisesRegex(ValueError, "match"):
            configuration("a" * 40, "v1.0.0", {"FORK_SPARKLE_PUBLIC_KEY": OTHER}, self.config)

    def test_tool_verification_rejects_modified_binary_and_archive(self):
        root = Path(self.temporary.name)
        archive, tools = root / "tools.zip", root / "bin"
        with zipfile.ZipFile(archive, "w") as package:
            for name in ("generate_keys", "sign_update"):
                package.writestr("bin/" + name, b"verified binary")
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        with patch.object(sparkle_setup, "ARCHIVE_SHA256", digest):
            sparkle_setup.verified_tools(archive, tools, prepare=True)
            (tools / "sign_update").write_bytes(b"modified binary")
            with self.assertRaisesRegex(ValueError, "tool"):
                sparkle_setup.verified_tools(archive, tools, prepare=True)
            archive.write_bytes(archive.read_bytes() + b"modified archive")
            with self.assertRaisesRegex(ValueError, "checksum"):
                sparkle_setup.verified_tools(archive, tools, prepare=True)


if __name__ == "__main__":
    unittest.main()
