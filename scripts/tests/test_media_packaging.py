import importlib
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS=Path(__file__).resolve().parents[2]/'PythonDistribution/Scripts'
sys.path.insert(0,str(SCRIPTS)); builder=importlib.import_module('build_mlx_vlm_server');sys.path.pop(0)


class MediaPackagingTests(unittest.TestCase):
    def test_recursive_digest_ignores_bytecode_and_tracks_change_removal(self):
        self.assertTrue(hasattr(builder,'tree_fingerprint'),'Recursive package fingerprints are required')
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'nested').mkdir();(root/'nested/module.py').write_text('value=1')
            before=builder.tree_fingerprint(root)
            (root/'__pycache__').mkdir();(root/'__pycache__/ignored.pyc').write_bytes(b'x')
            self.assertEqual(before,builder.tree_fingerprint(root))
            (root/'nested/module.py').write_text('value=2');self.assertNotEqual(before,builder.tree_fingerprint(root))
            (root/'nested/module.py').unlink();self.assertNotEqual(before,builder.tree_fingerprint(root))

    def test_package_copy_prunes_removed_files_and_imports_outside_source(self):
        self.assertTrue(hasattr(builder,'OVERLAY_PACKAGES'),'Media package membership must be explicit')
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);site=root/'site';site.mkdir()
            with patch.object(builder,'site_packages_dir',return_value=site):builder.install_overlay(root)
            for name in ('nativ_generation','nativ_music','nativ_video'):
                self.assertTrue((site/name/'__init__.py').is_file())
            stale=site/'nativ_music/stale.py';stale.write_text('removed=True')
            with patch.object(builder,'site_packages_dir',return_value=site):builder.install_overlay(root)
            self.assertFalse(stale.exists());self.assertFalse(list((site/'nativ_music').rglob('*.pyc')))
            self.assertTrue((root/'MusicRuntimes/manage.py').is_file())
            self.assertTrue((root/'VideoRuntimes/manage.py').is_file())
            import subprocess,os
            code='import nativ_music.catalog,nativ_video.catalog,nativ_generation.contracts;print(len(nativ_music.catalog.profiles()))'
            env=dict(os.environ,PYTHONPATH=str(site));result=subprocess.run([sys.executable,'-S','-c',code],cwd=directory,env=env,capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
    def test_verification_detects_packaged_deletion_and_allows_managed_codec(self):
        self.assertTrue(hasattr(builder,'verify_packaged_resources'),'Packaged imports alone do not prove complete membership')
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);site=root/'site';site.mkdir()
            with patch.object(builder,'site_packages_dir',return_value=site):
                builder.install_overlay(root)
                builder.verify_packaged_resources(root)
                (site/'nativ_music/providers/lyria.py').unlink()
                with self.assertRaises(SystemExit):builder.verify_packaged_resources(root)


if __name__=='__main__':unittest.main()
