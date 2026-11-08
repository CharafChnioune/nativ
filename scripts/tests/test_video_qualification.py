import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
try:
    import PIL
    AVAILABLE=True
except ImportError:AVAILABLE=False
spec=importlib.util.spec_from_file_location('video_qualify',Path(__file__).resolve().parents[1]/'benchmarks/video/qualify.py')
qualify=importlib.util.module_from_spec(spec);spec.loader.exec_module(qualify)

class Reply:
    def __init__(self,data):self.content=json.dumps(data).encode()
    def read(self,size):return self.content[:size]
    def __enter__(self):return self
    def __exit__(self,*args):pass

@unittest.skipUnless(AVAILABLE,'Requires the pinned Pillow fixture decoder')
class VideoQualificationTests(unittest.TestCase):
    def test_canonical_redirect_cannot_forward_bearer_credentials(self):
        with self.assertRaisesRegex(ValueError,'redirects are refused'):
            qualify.NoRedirect().redirect_request(None,None,302,'Found',{},'https://another.example')
    def test_fake_server_restart_reuses_input_and_intent_and_store_headers(self):
        uploads=[];jobs={};requests=[];input_sha=None
        def send(request,timeout):
            nonlocal input_sha
            method=request.get_method();path=request.full_url.split('/v1/video/')[-1];requests.append((method,path))
            headers={k.lower():v for k,v in request.headers.items()}
            if method!='GET':self.assertEqual(headers.get('x-nativ-store-id'),'store-one')
            if path=='info':return Reply({'store_id':'store-one'})
            if path=='inputs' and method=='POST':
                import hashlib
                raw=request.data.split(b'\r\n\r\n',1)[1].rsplit(b'\r\n--',1)[0];input_sha=hashlib.sha256(raw).hexdigest();uploads.append(raw)
                return Reply({'input_id':'stable-input','sha256':input_sha})
            if path=='inputs/stable-input':return Reply({'input_id':'stable-input','sha256':input_sha})
            if path=='generations' and method=='POST':
                key=headers['idempotency-key'];body=json.loads(request.data)
                if key in jobs:self.assertEqual(jobs[key]['request'],body)
                else:jobs[key]={'job_id':'job-'+str(len(jobs)),'asset_id':'asset','state':'succeeded','request':body}
                return Reply(jobs[key])
            if path=='assets/asset':return Reply({'asset_id':'asset'})
            raise AssertionError((method,path))
        with tempfile.TemporaryDirectory() as td,patch.object(qualify,'urlopen',side_effect=send),patch.dict(os.environ,{'NATIV_KEY':'fixture'}),patch.object(qualify,'host',return_value={'label':'client'}),patch('builtins.print'):
            argv=['qualify','--run-models','--server','https://canonical.example','--output',td]
            with patch.object(sys,'argv',argv):self.assertEqual(qualify.main(),0)
            with patch.object(sys,'argv',argv):self.assertEqual(qualify.main(),0)
            self.assertEqual(len(uploads),1);self.assertEqual(len(jobs),4)
            report=json.loads((Path(td)/'report.json').read_text())
            self.assertEqual(len(report['cases']),4);self.assertFalse(report['canonical_server_is_loopback'])
            self.assertEqual(report['hardware_measurement_scope'],'client_only')
            self.assertEqual(report['model_execution_location'],'canonical_server')

    def test_retrieval_pending_is_reported_without_automatic_retry(self):
        calls=[]
        def send(request,timeout):
            path=request.full_url.split('/v1/video/')[-1];calls.append(path)
            if path=='info':return Reply({'store_id':'store'})
            if path=='inputs':return Reply({'input_id':'input'})
            if path=='generations':return Reply({'job_id':'known-operation','state':'retrieval_pending'})
            raise AssertionError('No automatic retrieval retry or extra generation is allowed')
        with tempfile.TemporaryDirectory() as td,patch.object(qualify,'urlopen',side_effect=send),patch.dict(os.environ,{'NATIV_KEY':'fixture'}),patch.object(qualify,'host',return_value={}):
            with patch.object(sys,'argv',['qualify','--run-models','--output',td]),self.assertRaisesRegex(RuntimeError,'retrieval_pending'):
                qualify.main()
            self.assertEqual(calls,['info','inputs','generations'])
            report=json.loads((Path(td)/'report.json').read_text())
            self.assertEqual(report['cases'][0]['state'],'retrieval_pending');self.assertFalse(report['qualified'])
