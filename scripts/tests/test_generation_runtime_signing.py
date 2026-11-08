import hashlib
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from threading import Event
import unittest

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / 'PythonDistribution/Overlay/nativ_generation/runtime_signing.py'


def helper():
    spec = importlib.util.spec_from_file_location('runtime_signing_test', HELPER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class RuntimeSigningTests(unittest.TestCase):
    def test_source_prefix_and_external_symlink_are_rejected(self):
        module = helper()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); source = root / 'source'; stage = root / 'stage'
            (source / 'bin').mkdir(parents=True)
            (source / 'bin/python3').write_bytes(b'original')
            with self.assertRaises(ValueError):
                module.prepare_interpreter(source.parent, source, Event())
            (stage / 'python/bin').mkdir(parents=True)
            (stage / 'python/bin/python3').symlink_to(source / 'bin/python3')
            with self.assertRaises(ValueError):
                module.prepare_interpreter(stage, source, Event())
            self.assertEqual((source / 'bin/python3').read_bytes(), b'original')

    def test_hardlinked_source_and_cancel_are_rejected(self):
        module = helper()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); source = root / 'source'; stage = root / 'stage'
            (source / 'bin').mkdir(parents=True); (stage / 'python/bin').mkdir(parents=True)
            original = source / 'bin/python3'; original.write_bytes(b'original')
            os.link(original, stage / 'python/bin/python3')
            with self.assertRaises(ValueError):
                module.prepare_interpreter(stage, source, Event())
            cancel = Event(); cancel.set()
            with self.assertRaises(InterruptedError):
                module.prepare_interpreter(stage, source, cancel)

    def test_symlinked_staging_root_and_prefix_are_rejected(self):
        module = helper()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); source = root / 'source'; source.mkdir()
            real = root / 'real'; real.mkdir(); stage = root / 'stage'
            stage.symlink_to(real, target_is_directory=True)
            with self.assertRaises(ValueError):
                module.prepare_interpreter(stage, source, Event())
            stage.unlink(); stage.mkdir()
            (stage / 'python').symlink_to(source, target_is_directory=True)
            with self.assertRaises(ValueError):
                module.prepare_interpreter(stage, source, Event())

    @unittest.skipUnless(sys.platform == 'darwin', 'Requires macOS codesign; Linux cannot qualify library validation')
    def test_copied_hardened_executable_loses_runtime_flag_only_in_owned_copy(self):
        module = helper()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); source = root / 'source'; stage = root / 'stage'
            (source / 'bin').mkdir(parents=True)
            original = source / 'bin/python3'
            # Do not copy SIP/restricted file flags from the system executable.
            shutil.copyfile('/usr/bin/true', original)
            original.chmod(0o755)
            subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--options', 'runtime', '--timestamp=none', str(original)], check=True, capture_output=True)
            before = hashlib.sha256(original.read_bytes()).hexdigest()
            shutil.copytree(source, stage / 'python', symlinks=True)
            module.prepare_interpreter(stage, source, Event())
            details = subprocess.run(['/usr/bin/codesign', '-dvv', str(stage / 'python/bin/python3')], capture_output=True, text=True, check=True).stderr
            self.assertIn('Signature=adhoc', details)
            self.assertNotIn('(runtime)', details)
            self.assertEqual(hashlib.sha256(original.read_bytes()).hexdigest(), before)
            subprocess.run([str(stage / 'python/bin/python3')], check=True)


if __name__ == '__main__':
    unittest.main()
