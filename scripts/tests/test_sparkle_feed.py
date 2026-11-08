import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import sparkle_feed
from test_macos_release import feed, REPOSITORY


class SparkleFeedTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / "appcast.xml"
        self.path.write_bytes(feed())
        self.tool = Path(self.temporary.name) / "sign_update"
        self.tool.write_text("#!/bin/sh\nexit 0\n")
        self.tool.chmod(0o755)

    def test_unsigned_feed_is_rejected_before_tool_or_key_access(self):
        with patch.object(sparkle_feed, "signature_operation") as operation:
            with self.assertRaisesRegex(ValueError, "Unsigned"):
                sparkle_feed.verify_feed(self.path)
            operation.assert_not_called()

    def test_ci_secret_uses_stdin_and_is_not_exposed_in_errors(self):
        secret = "fixture-private-value-not-a-real-key"
        with patch.dict(os.environ, {"SPARKLE_PRIVATE_KEY": secret}), patch.object(sparkle_feed.subprocess, "run") as run:
            run.return_value = subprocess.CompletedProcess([], 1, secret, secret)
            with self.assertRaises(ValueError) as error:
                sparkle_feed.signature_operation(self.path, tool=self.tool)
            self.assertNotIn(secret, str(error.exception))
            self.assertNotIn(secret, " ".join(run.call_args.args[0]))
            self.assertEqual(run.call_args.kwargs["input"], secret + "\n")
            self.assertIn("--ed-key-file", run.call_args.args[0])

    def test_tampered_signed_input_never_changes_original_or_reaches_signer(self):
        original = feed() + b"<!-- sparkle-signatures:tampered -->"
        self.path.write_bytes(original)
        with patch.object(sparkle_feed, "verify_feed", side_effect=ValueError("bad signature")), patch.object(sparkle_feed, "sign_feed") as sign:
            with self.assertRaisesRegex(ValueError, "bad signature"):
                sparkle_feed.finalize_signed_appcast(self.path, "v0.4.0rc1", REPOSITORY)
            sign.assert_not_called()
        self.assertEqual(self.path.read_bytes(), original)

    def test_final_signing_failure_keeps_original_feed(self):
        original = self.path.read_bytes()
        with patch.object(sparkle_feed, "sign_feed", side_effect=ValueError("signing failed")):
            with self.assertRaises(ValueError):
                sparkle_feed.finalize_signed_appcast(self.path, "v0.4.0rc1", REPOSITORY)
        self.assertEqual(self.path.read_bytes(), original)

    def test_sign_feed_always_verifies_the_actual_result(self):
        operations = []
        with patch.object(sparkle_feed, "signature_operation", side_effect=lambda path, **kwargs: operations.append(("sign", Path(path).read_bytes()))), patch.object(sparkle_feed, "verify_feed", side_effect=lambda path, **kwargs: operations.append(("verify", Path(path).read_bytes()))):
            sparkle_feed.sign_feed(self.path)
        self.assertEqual(operations, [("sign", feed()), ("verify", feed())])


if __name__ == "__main__":
    unittest.main()
