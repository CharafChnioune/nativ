import hashlib
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from threading import Event
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('video_runtime_manage',ROOT/'PythonDistribution/VideoRuntimes/manage.py')
manage=importlib.util.module_from_spec(spec)
# A missing manager is a consequential setup failure, not a skipped fixture.
spec.loader.exec_module(manage)

class VideoRuntimeTests(unittest.TestCase):
    def test_gated_or_unresolved_hash_never_starts_download(self):
        manifest={'profile_id':'ltx-test','models':{'revision':'a'*40,'files':[{'path':'weights','remote_path':'weights','repo':'private/model','revision':'a'*40,'bytes':5,'sha256':None}]}}
        with tempfile.TemporaryDirectory() as td,patch.object(manage,'download') as download:
            with self.assertRaises(ValueError): manage.prepare_models(manifest,td,Event(),lambda *a:None,accepted_licenses=True)
            download.assert_not_called()
    def test_partial_prepare_cancel_and_license_gate(self):
        with tempfile.TemporaryDirectory() as td:
            manifest={'profile_id':'test','models':{'revision':'a'*40,'files':[]}}
            with self.assertRaises(ValueError): manage.prepare_models(manifest,td,Event(),lambda *a:None)
            cancel=Event();cancel.set()
            with self.assertRaises(InterruptedError): manage.prepare_models(manifest,td,cancel,lambda *a:None,accepted_licenses=True)
    def test_manifest_paths_and_profile_integrity(self):
        data=b'component'; sha=hashlib.sha256(data).hexdigest()
        manifest={'profile_id':'test','models':{'revision':'a'*40,'files':[{'path':'../escape','remote_path':'weights','repo':'repo/name','revision':'a'*40,'bytes':len(data),'sha256':sha}]}}
        with tempfile.TemporaryDirectory() as td,patch.object(manage,'download') as download:
            with self.assertRaises(ValueError): manage.prepare_models(manifest,td,Event(),lambda *a:None,accepted_licenses=True)
            download.assert_not_called()
    def test_runtime_manifests_have_hashed_locks_and_no_qualified_claim(self):
        paths=list((ROOT/'PythonDistribution/VideoRuntimes').glob('*.json'))
        self.assertGreaterEqual(len(paths),3)
        for path in paths:
            m=json.loads(path.read_text()); lock=path.parent/m['lock']['path']
            self.assertEqual(hashlib.sha256(lock.read_bytes()).hexdigest(),m['lock']['sha256'])
            self.assertEqual(m['qualification'],'unqualified')
            self.assertTrue(all(isinstance(f['sha256'],str) and len(f['sha256'])==64 for f in m['models']['files']))

    def test_packaged_prefix_resolves_workers_without_checkout_overlay(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td);resources=root/'resources'/'VideoRuntimes';resources.mkdir(parents=True)
            prefix=root/'python';site=prefix/'lib/python3.12/site-packages'
            for package in ('nativ_video','nativ_generation'):(site/package).mkdir(parents=True)
            with patch.object(manage,'ROOT',resources):self.assertEqual(manage.overlay_source(prefix),site)
