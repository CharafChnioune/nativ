"""Receipt signing order/provenance checks; all signing is temporary ad-hoc."""
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sign_generation_resources import prepare, refresh
from fork_release import validate_bundle_resources
import test_fork_release as fixtures


class CodecSigningReceiptTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.GenerationReleaseResourceTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.app = self.fixture.app
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'io.github.charafchnioune.nativ'}))
        self.codec = self.fixture.runtime / 'CodecRuntime/managed/bin/ffmpeg'

    def update_initial_hash(self):
        record = json.loads(self.fixture.receipt_path.read_text())
        value = hashlib.sha256(self.codec.read_bytes()).hexdigest()
        record['files']['bin/ffmpeg'] = value
        record['build_files']['bin/ffmpeg'] = value
        self.fixture.receipt_path.write_text(json.dumps(record))

    def test_pre_sign_integrity_and_receipt_snapshot_cannot_be_bypassed(self):
        snapshot = prepare(self.app)
        self.codec.write_bytes(b'corrupt before signing')
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            prepare(self.app)
        self.fixture.receipt_path.write_text('{}')
        with self.assertRaisesRegex(ValueError, 'changed after pre-sign'):
            refresh(self.app, snapshot)

    @unittest.skipUnless(sys.platform == 'darwin' and shutil.which('cc'), 'requires macOS ad-hoc signing')
    def test_actual_tiny_macho_resigning_refreshes_hash_without_rewriting_build_provenance(self):
        source = Path(self.fixture.tmp.name) / 'tiny.c'
        source.write_text('int main(void) { return 0; }\n')
        subprocess.run(['cc', str(source), '-o', str(self.codec)], check=True, capture_output=True)
        self.update_initial_hash()
        original_build_files = json.loads(self.fixture.receipt_path.read_text())['build_files']
        for identifier in ('signing.fixture.first', 'signing.fixture.second'):
            snapshot = prepare(self.app)
            before = hashlib.sha256(self.codec.read_bytes()).hexdigest()
            subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none',
                            '--identifier', identifier, str(self.codec)], check=True, capture_output=True)
            self.assertNotEqual(before, hashlib.sha256(self.codec.read_bytes()).hexdigest())
            with self.assertRaisesRegex(ValueError, 'hash mismatch'):
                validate_bundle_resources(self.app)
            refresh(self.app, snapshot)
            validate_bundle_resources(self.app)
            receipt = json.loads(self.fixture.receipt_path.read_text())
            self.assertEqual(receipt['build_files'], original_build_files)
            self.assertTrue(receipt['post_signing_receipt'])
            self.assertEqual(receipt['files']['bin/ffmpeg'], hashlib.sha256(self.codec.read_bytes()).hexdigest())

    def test_local_signer_refreshes_before_any_bundle_seal(self):
        self.codec.write_bytes(b'\xcf\xfa\xed\xfe' + b'synthetic Mach-O')
        self.update_initial_hash()
        main = self.app / 'Contents/MacOS/Nativ'
        main.parent.mkdir(); main.write_bytes(b'\xcf\xfa\xed\xfe' + b'synthetic main')
        spec = importlib.util.spec_from_file_location('local_signing_fixture', Path(__file__).resolve().parents[1] / 'sign_macos_local.py')
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        seals = []
        def sign_or_verify(args, **kwargs):
            if '--sign' not in args:
                return
            target = Path(args[-1])
            if target.is_file():
                target.write_bytes(target.read_bytes() + b'updated signature')
            else:
                validate_bundle_resources(self.app)
                seals.append(target)
        with patch.object(module.subprocess, 'run', side_effect=sign_or_verify):
            module.sign(self.app)
        self.assertIn(self.app.resolve(), seals)
        self.assertTrue(json.loads(self.fixture.receipt_path.read_text())['post_signing_receipt'])

    def test_release_refresh_is_between_native_signatures_and_bundle_seals(self):
        root = Path(__file__).resolve().parents[1]
        script = (root / 'sign_macos_release.sh').read_text()
        before = script.index('sign_generation_resources.py" prepare')
        native = script.index('for native_file in "${native_files[@]}"; do', before)
        refresh_position = script.index('sign_generation_resources.py" refresh', native)
        seal = script.index('for code_bundle in "${code_bundles[@]}"; do', refresh_position)
        self.assertLess(before, native); self.assertLess(native, refresh_position); self.assertLess(refresh_position, seal)
        publisher = (root / 'publish_fork_release.sh').read_text()
        signing = publisher.index('scripts/sign_macos_release.sh')
        post_check = publisher.index('python3 scripts/fork_release.py bundle', signing)
        self.assertLess(post_check, publisher.index('scripts/package_macos_dmg.sh'))
        self.assertNotIn('--verify-imports', publisher)


if __name__ == '__main__':
    unittest.main()
