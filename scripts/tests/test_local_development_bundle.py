import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('sign_local', ROOT / 'scripts/sign_macos_local.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class LocalDevelopmentBundleTests(unittest.TestCase):
    def test_official_bundle_cannot_be_resigned_by_fork_development_route(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / 'Nativ.app'
            (app / 'Contents/MacOS').mkdir(parents=True)
            (app / 'Contents/MacOS/Nativ').write_bytes(b'placeholder')
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'dev.local.Nativ'}))
            with patch.object(module.subprocess, 'run') as codesign:
                with self.assertRaisesRegex(ValueError, 'fork bundle identity'):
                    module.sign(app)
                codesign.assert_not_called()

    def test_modified_helper_cannot_reuse_cached_build_evidence(self):
        import hashlib
        import json
        spec = importlib.util.spec_from_file_location('install_lfm', ROOT / 'scripts/install_lfm_realtime_runtime.py')
        install = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(install)
        with tempfile.TemporaryDirectory() as temporary:
            runtime = Path(temporary)
            (runtime / 'bin').mkdir()
            helper = runtime / 'bin/llama-server'
            helper.write_bytes(b'original helper')
            manifest = {'runtime': {'commit': 'a' * 40, 'patches': []}}
            (runtime / 'runtime-manifest.json').write_text(json.dumps(manifest))
            (runtime / 'build-evidence.json').write_text(json.dumps({'runtimeCommit': 'a' * 40, 'patches': [], 'sha256': hashlib.sha256(helper.read_bytes()).hexdigest()}))
            self.assertTrue(install.valid_runtime(runtime, manifest))
            helper.write_bytes(b'changed helper')
            self.assertFalse(install.valid_runtime(runtime, manifest))
