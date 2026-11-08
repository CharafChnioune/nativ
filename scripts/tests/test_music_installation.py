from pathlib import Path
import importlib.util
import io
import json
import sys
import tarfile
import tempfile
from threading import Event
import unittest

FILE = Path(__file__).resolve().parents[2] / 'PythonDistribution/MusicRuntimes/manage.py'


class MusicInstallationTests(unittest.TestCase):
    def module(self):
        self.assertTrue(FILE.is_file(), 'Managed music installation must exist')
        spec = importlib.util.spec_from_file_location('music_manage', FILE)
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        return module

    def test_archive_rejects_traversal_and_symlinks(self):
        manager = self.module()
        for name, symbolic in (('../escape', False), ('source/link', True)):
            with tempfile.TemporaryDirectory() as directory:
                archive = Path(directory)/'archive.tar.gz'
                with tarfile.open(archive, 'w:gz') as tar:
                    member = tarfile.TarInfo(name)
                    if symbolic: member.type=tarfile.SYMTYPE; member.linkname='/etc/passwd'
                    else: member.size=1
                    tar.addfile(member, None if symbolic else io.BytesIO(b'x'))
                with self.assertRaises(ValueError): manager.extract_source(archive, Path(directory)/'out')

    def test_model_prepare_reuses_verified_files_and_commits_receipt(self):
        manager = self.module()
        import hashlib
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); (root/'model').write_bytes(b'fixture')
            item=dict(path='model', bytes=7, sha256=hashlib.sha256(b'fixture').hexdigest(), repo='a/b', revision='a'*40, remote_path='model')
            manifest=dict(profile_id='profile', provider='acestep', models=dict(revision='a'*40, files=[item]))
            manager.prepare_models(manifest, root, Event(), lambda *args: None, accepted_licenses=True)
            receipt=json.loads((root/'nativ-model.json').read_text())
            self.assertEqual(receipt['files']['model'], item['sha256'])

    def test_unaccepted_terms_and_precancel_prevent_download(self):
        manager=self.module()
        manifest=dict(profile_id='profile', provider='stable_audio_mlx', models=dict(revision='a'*40, files=[]))
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError): manager.prepare_models(manifest, Path(directory), Event(), print, accepted_licenses=False)
            event=Event();event.set()
            with self.assertRaises(InterruptedError): manager.prepare_models(manifest, Path(directory), event, print, accepted_licenses=True)
    def test_malformed_manifests_are_isolated_from_runtime_discovery(self):
        overlay=FILE.parents[1]/'Overlay';sys.path.insert(0,str(overlay))
        from nativ_generation.runtimes import RuntimeManager
        for content in ('not json','[]',json.dumps({'schema_version':1,'profile_id':'profile'}),json.dumps({'schema_version':1,'id':'runtime','profile_id':'profile','provider':'fixture','qualification':'experimental','worker':[]})):
            with self.subTest(content=content),tempfile.TemporaryDirectory() as directory:
                root=Path(directory);resources=root/'resources';(resources/'MusicRuntimes').mkdir(parents=True)
                (resources/'MusicRuntimes/bad.json').write_text(content)
                runtime=RuntimeManager(root/'state',resources=resources)
                self.assertFalse(runtime.ready('profile'))
                self.assertTrue(runtime.status('music'))
                self.assertEqual(runtime.status('music')[0]['status'],'unavailable')
                runtime.close()

    def test_packaged_runtime_manager_installs_tiny_prepared_fixture(self):
        manager_module = self.module()
        import hashlib, shutil, threading, time
        from types import SimpleNamespace
        overlay=FILE.parents[1]/'Overlay'
        sys.path.insert(0,str(overlay))
        from nativ_generation.runtimes import RuntimeManager
        from nativ_generation.resources import ComputeAdmission
        from nativ_generation.repository import fingerprint
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);resources=root/'resources';folder=resources/'MusicRuntimes';folder.mkdir(parents=True)
            shutil.copy2(FILE,folder/'manage.py');shutil.copytree(FILE.parent/'licenses',folder/'licenses')
            prefix=resources/'python';site=prefix/'lib/python3.12/site-packages';site.mkdir(parents=True)
            for name in ('nativ_music','nativ_generation'):shutil.copytree(overlay/name,site/name,ignore=shutil.ignore_patterns('__pycache__'))
            (prefix/'bin').mkdir()
            # Tiny standalone-prefix protocol fixture; host Python is used only
            # for the real handshake, never inference or dependency installation.
            launcher=prefix/'bin/python3'
            launcher.write_text('#!/bin/sh\nif [ "$1" = "-c" ]; then echo 3.12; exit 0; fi\nTASK_PREFIX="$(cd "$(dirname "$0")/.." && pwd)"\nunset PYTHONHOME\nexport PYTHONPATH="$TASK_PREFIX/lib/python3.12/site-packages"\nexec '+sys.executable+' "$@"\n')
            launcher.chmod(0o755)
            pid='minimax-music3-mxfp8-local'
            manifest=dict(schema_version=1,id='minimax-music3-mlx-0.6.4',profile_id=pid,provider='minimax_mlx',qualification='experimental',
                lock={'path':'locks/fixture.txt','sha256':hashlib.sha256(b'fixture lock').hexdigest()},source=None,worker=dict(module='nativ_music.workers',args=['--runtime-id','minimax-music3-mlx-0.6.4']),
                models=dict(revision='a'*40,files=[dict(path='weight',bytes=7,sha256=hashlib.sha256(b'fixture').hexdigest(),repo='fixture/model',revision='a'*40,remote_path='weight')]))
            (folder/'locks').mkdir();(folder/'locks/fixture.txt').write_bytes(b'fixture lock')
            (folder/'fixture.json').write_text(json.dumps(manifest))
            (resources/'VideoRuntimes').mkdir()
            runtime=RuntimeManager(root/'state',resources=resources,python_prefix=prefix)
            model=runtime.root/'models'/pid/fingerprint(manifest['models'])[:20];model.mkdir(parents=True);(model/'weight').write_bytes(b'fixture')
            service=SimpleNamespace(admission=ComputeAdmission(root/'compute.lock'),_lock=threading.RLock(),_active={},assets=SimpleNamespace(),
                _config=lambda _:dict(enabled=True,license_accepted=True,experimental_enabled=True))
            runtime.bind(service)
            runtime.action(manifest['id'],'install',pid)
            deadline=time.monotonic()+10
            while runtime._tasks and time.monotonic()<deadline:time.sleep(.01)
            self.assertEqual(runtime.status('music')[0]['status'],'ready',runtime.status('music'))
            self.assertTrue(runtime.ready(pid))
            self.assertTrue(Path(runtime.prepared(pid)['model_path']).is_relative_to((root/'state').resolve()))
            first=Path(runtime._installation(pid)['runtime_path'])
            runtime.action(manifest['id'],'repair',pid)
            deadline=time.monotonic()+10
            while runtime._tasks and time.monotonic()<deadline:time.sleep(.01)
            self.assertTrue(runtime.ready(pid),runtime.status('music'))
            self.assertFalse(first.exists(),'Repair must retire the verified inactive old runtime')
            self.assertEqual((model/'weight').read_bytes(),b'fixture')
            service._active={'active':{}}
            service.repo=SimpleNamespace(get_job=lambda _:dict(profile={'id':pid}))
            from nativ_generation.contracts import GenerationError
            with self.assertRaises(GenerationError):runtime.action(manifest['id'],'remove',pid)
            self.assertTrue(runtime.ready(pid))
            service._active={}
            runtime.action(manifest['id'],'remove',pid)
            self.assertFalse(runtime.ready(pid));self.assertEqual((model/'weight').read_bytes(),b'fixture')
            # A forged/stale activation must never reinterpret a model/cache as
            # a disposable interpreter, even if it is inside the runtime root.
            activation=runtime.root/'profiles'/pid/'installation.json'
            activation.write_text(json.dumps(dict(manifest_sha256=fingerprint(manifest),runtime_path=str(model),model_path=str(model))))
            runtime.action(manifest['id'],'remove',pid)
            self.assertEqual((model/'weight').read_bytes(),b'fixture')
            runtime.close()


if __name__ == '__main__': unittest.main()
