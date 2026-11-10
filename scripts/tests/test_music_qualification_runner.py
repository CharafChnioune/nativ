from pathlib import Path
import hashlib
import importlib.util
import json
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
SCRIPT=ROOT/'scripts/benchmarks/music/qualify.py'


class MusicQualificationRunnerTests(unittest.TestCase):
    def module(self):
        self.assertTrue(SCRIPT.is_file(),'Music needs an executable qualification runner')
        spec=importlib.util.spec_from_file_location('music_qualification',SCRIPT);value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value
    def test_default_plan_is_dry_local_and_has_twenty_original_cases(self):
        module=self.module();cases=module.load_corpus(SCRIPT.with_name('corpus.json'))
        self.assertGreaterEqual(len(cases),20)
        counts={}
        for case in cases:
            counts[case['request']['model']]=counts.get(case['request']['model'],0)+1
            self.assertIs(case['request']['allow_remote'],False)
        self.assertTrue(all(count>=5 for count in counts.values()))
        with tempfile.TemporaryDirectory() as directory:
            import contextlib,io
            with contextlib.redirect_stdout(io.StringIO()):result=module.main(['--output',directory])
            self.assertFalse(result['run_models']);self.assertFalse(result['qualified'])
            self.assertFalse((Path(directory)/'state.json').exists())
    def test_intent_store_headers_and_restart_reuse_same_job_without_post(self):
        module=self.module();case=module.load_corpus(SCRIPT.with_name('corpus.json'))[0]
        class API:
            def __init__(self):self.store='store-a';self.posts=0;self.calls=[];self.job=None
            def request(self,method,path,*,body=None,headers=None):
                self.calls.append((method,path,dict(headers or {})))
                if path=='info':return dict(store_id=self.store,contract_version=1)
                if path=='models':return dict(items=[dict(id=case['request']['model'],deployment='local',profile_revision='pin-1',readiness='ready')])
                if method=='POST' and path=='generations':
                    self.posts+=1;self.job=dict(job_id='job-1',store_id=self.store,state='succeeded',request=body,asset_id='asset-1');return self.job
                if path=='generations/job-1':return self.job
                if method=='GET' and path=='generations':return dict(items=[self.job],next_cursor=None)
                if method=='POST' and path=='generations/job-1/resume':self.job['state']='succeeded';return self.job
                if path=='assets/asset-1':return dict(asset_id='asset-1',store_id=self.store,filename='original.wav',sha256=hashlib.sha256(b'fixture').hexdigest(),metadata={'duration_seconds':30},byte_size=7)
                raise AssertionError((method,path))
            def download(self,path,destination,*,headers,expected_sha256):destination.write_bytes(b'fixture')
        api=API()
        with tempfile.TemporaryDirectory() as directory:
            runner=module.Runner(base_url='http://127.0.0.1:8080',output=Path(directory),cases=[case],transport=api,poll_seconds=0)
            report=runner.execute();self.assertEqual(api.posts,1);self.assertFalse(report['qualified'])
            post=next(call for call in api.calls if call[:2]==('POST','generations'))
            self.assertEqual(post[2]['X-Nativ-Store-ID'],'store-a');self.assertTrue(post[2]['Idempotency-Key'])
            saved=json.loads((Path(directory)/'state.json').read_text());key=saved['cases'][case['id']]['idempotency_key']
            module.Runner(base_url='http://127.0.0.1:8080',output=Path(directory),cases=[case],transport=api,poll_seconds=0).execute()
            self.assertEqual(api.posts,1)
            self.assertEqual(json.loads((Path(directory)/'state.json').read_text())['cases'][case['id']]['idempotency_key'],key)
            saved=json.loads((Path(directory)/'state.json').read_text());saved['cases'][case['id']].pop('job_id');module.atomic(Path(directory)/'state.json',saved)
            module.Runner(base_url='http://127.0.0.1:8080',output=Path(directory),cases=[case],transport=api,poll_seconds=0).execute()
            self.assertEqual(api.posts,1,'Lost acceptance recovery must GET the frozen title instead of resubmitting')
            api.job['state']='recovery_hold'
            module.Runner(base_url='http://127.0.0.1:8080',output=Path(directory),cases=[case],transport=api,poll_seconds=0).execute()
            self.assertEqual(api.posts,1)
            resume=next(call for call in api.calls if call[:2]==('POST','generations/job-1/resume'))
            self.assertEqual(resume[2]['X-Nativ-Store-ID'],'store-a')
            api.store='store-b'
            with self.assertRaises(ValueError):module.Runner(base_url='http://127.0.0.1:8080',output=Path(directory),cases=[case],transport=api,poll_seconds=0).execute()
            self.assertEqual(api.posts,1)
    def test_same_output_directory_has_one_qualification_owner(self):
        module=self.module();case=module.load_corpus(SCRIPT.with_name('corpus.json'))[0]
        with tempfile.TemporaryDirectory() as directory:
            runner=module.Runner(base_url='http://127.0.0.1:8080',output=Path(directory),cases=[case],transport=None)
            try:
                with self.assertRaises(ValueError):module.Runner(base_url='http://127.0.0.1:8080',output=Path(directory),cases=[case],transport=None)
            finally:
                if hasattr(runner,'close'):runner.close()

    def test_http_auth_store_and_idempotency_headers_are_sent_together(self):
        module=self.module();http=module.HTTP('http://127.0.0.1:8080','fixture-only-key')
        class Response:
            def __enter__(self):return self
            def __exit__(self,*args):pass
            def read(self,_):return b'{}'
        class Opener:
            def open(self,request,timeout):self.request=request;return Response()
        opener=Opener();http.opener=opener
        http.request('POST','generations',body={'allow_remote':False},headers={'X-Nativ-Store-ID':'store-a','Idempotency-Key':'intent-a'})
        self.assertEqual(opener.request.get_header('Authorization'),'Bearer fixture-only-key')
        self.assertEqual(opener.request.get_header('X-nativ-store-id'),'store-a')
        self.assertEqual(opener.request.get_header('Idempotency-key'),'intent-a')


if __name__=='__main__':unittest.main()
