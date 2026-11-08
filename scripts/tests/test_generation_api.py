import sys,tempfile,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'PythonDistribution/Overlay'))
try:
    from fastapi import FastAPI
    from fastapi.testclient import TestClient
    AVAILABLE=True
except ImportError:AVAILABLE=False
from nativ_generation.service import GenerationService
from nativ_generation.api import install_routes
from test_generation_service import Fixture

@unittest.skipUnless(AVAILABLE,'Requires the packaged FastAPI/httpx runtime')
class GenerationAPITests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();p={'id':'fixture','deployment':'local','modality':'music','provider':'fixture','defaults':{},'qualification':'experimental','runtime':None}
        self.s=GenerationService(Path(self.tmp.name),profiles=[p],provider_factory=lambda *a:Fixture(),autostart=False)
        self.s.configure('fixture',{'enabled':True,'experimental_enabled':True,'license_accepted':True})
        app=FastAPI();install_routes(app,lambda:self.s,api_key='test-key')
        self.c=TestClient(app);self.h={'Authorization':'Bearer test-key','X-Nativ-Store-ID':self.s.repo.store_id,'Idempotency-Key':'one'}
    def tearDown(self):self.c.close();self.s.close();self.tmp.cleanup()
    def test_auth_and_store_preconditions(self):
        self.assertEqual(self.c.get('/v1/music/info').status_code,401)
        for headers,status in (({'Authorization':'Bearer test-key'},428),({**self.h,'X-Nativ-Store-ID':'wrong'},409)):
            self.assertEqual(self.c.post('/v1/music/sessions',headers=headers,json={}).status_code,status)
        self.assertEqual(self.c.get('/v1/music/info',headers=self.h).json()['store_id'],self.s.repo.store_id)
    def test_locked_generation_store_does_not_disable_existing_server(self):
        from unittest.mock import patch
        from nativ_generation.api import install
        app=FastAPI()
        @app.get('/health')
        async def health():return {'status':'ok'}
        with patch.dict('os.environ',{'NATIV_GENERATION_ROOT':self.tmp.name,'MLX_VLM_SERVER_API_KEY':'test-key','NATIV_PRIVATE_TRANSLATION_RUNTIME':'0','NATIV_COMPUTE_LEASE_PATH':self.tmp.name+'/compute.lock'}):
            install(app)
            with TestClient(app) as client:
                self.assertEqual(client.get('/health').status_code,200)
                response=client.get('/v1/music/info',headers=self.h)
                self.assertEqual(response.status_code,503,response.text)
                self.assertEqual(response.json()['error']['code'],'store_in_use')
        self.assertEqual(self.c.get('/v1/music/info',headers=self.h).status_code,200)
    def test_duplicate_contract_no_private_data_and_namespaces(self):
        body={'model':'fixture','prompt':'same'}
        first=self.c.post('/v1/music/generations',headers=self.h,json=body)
        self.assertEqual(first.status_code,202,first.text)
        second=self.c.post('/v1/music/generations',headers=self.h,json=body)
        self.assertEqual(first.json()['job_id'],second.json()['job_id']);self.assertNotIn('configuration_identity',first.json())
        self.assertEqual(self.c.get('/v1/video/generations/'+first.json()['job_id'],headers=self.h).status_code,404)
        self.assertEqual(self.c.post('/v1/music/generations',headers=self.h,json={**body,'prompt':'changed'}).status_code,409)
    def test_bounds_and_browser_origin(self):
        self.assertEqual(self.c.post('/v1/music/generations',headers=self.h,content=b'x'*(128*1024+1)).status_code,413)
        self.assertEqual(self.c.get('/v1/music/info',headers={**self.h,'Origin':'https://untrusted.example'}).status_code,403)
        self.assertEqual(self.c.post('/v1/music/sessions',headers=self.h,content='{"title":NaN}').status_code,400)
    def test_every_spec_route_is_registered_and_openapi_generated(self):
        paths=self.c.get('/openapi.json').json()['paths']
        for m in ('music','video'):
            for path in ('info','models','sessions','sessions/{session_id}','generations','generations/{job_id}','generations/{job_id}/events','generations/{job_id}/cancel','generations/{job_id}/resume','generations/{job_id}/retry-download','generations/{job_id}/release-remote-reservation','assets/{asset_id}','assets/{asset_id}/content','assets/{asset_id}/usages','assets/{asset_id}/references/{reference_id}','assets/{asset_id}/restore'):
                self.assertIn('/v1/'+m+'/'+path,paths)
        for path in ('inputs','inputs/{input_id}','inputs/{input_id}/content','assets/{asset_id}/poster'):self.assertIn('/v1/video/'+path,paths)
    def test_real_file_range_head_and_authenticated_sse(self):
        import time
        j=self.s.submit('music',{'model':'fixture','prompt':'file'},'file');self.s.start()
        for _ in range(300):
            j=self.s.repo.get_job(j['job_id'])
            if j['state']=='succeeded':break
            time.sleep(.01)
        self.assertEqual(j['state'],'succeeded')
        path='/v1/music/assets/'+j['asset_id']+'/content'
        head=self.c.head(path,headers=self.h);self.assertEqual(head.status_code,200);self.assertEqual(head.content,b'')
        partial=self.c.get(path,headers={**self.h,'Range':'bytes=0-3'});self.assertEqual(partial.status_code,206);self.assertEqual(partial.content,b'RIFF')
        self.assertEqual(self.c.get(path,headers={**self.h,'Range':'bytes=999999-'}).status_code,416)
        events=self.c.get('/v1/music/generations/'+j['job_id']+'/events',headers=self.h)
        self.assertEqual(events.status_code,200);self.assertIn('event: state',events.text);self.assertNotIn('configuration_identity',events.text)
    def test_upload_detects_declared_mime_mismatch_and_never_exposes_paths(self):
        import io
        from PIL import Image
        encoded=io.BytesIO();Image.new('RGB',(8,8),'red').save(encoded,format='PNG')
        bad=self.c.post('/v1/video/inputs',headers=self.h,files={'file':('ref.jpg',encoded.getvalue(),'image/jpeg')})
        self.assertEqual(bad.status_code,400,bad.text)
        good=self.c.post('/v1/video/inputs',headers=self.h,files={'file':('ref.png',encoded.getvalue(),'image/png')})
        self.assertEqual(good.status_code,201,good.text);self.assertNotIn('path',good.json());self.assertEqual(good.json()['mime'],'image/png')
    def test_canonical_preview_matches_shared_native_fixture_and_submission_derivative(self):
        import json
        fixture=Path(__file__).resolve().parents[2]/'Tests/Fixtures/GenerationInputTransform'
        manifest=json.loads((fixture/'manifest.json').read_text())
        uploaded=self.c.post('/v1/video/inputs',headers=self.h,files={'file':('original.png',(fixture/'original.png').read_bytes(),'image/png')}).json()
        response=self.c.post('/v1/video/inputs/'+uploaded['input_id']+'/transform',headers=self.h,json={'width':64,'height':32,'transform':manifest['transform']})
        self.assertEqual(response.status_code,200,response.text);preview=response.json();self.assertEqual(preview['sha256'],manifest['sha256'])
        content=self.c.get('/v1/video/inputs/'+uploaded['input_id']+'/derivatives/'+preview['derivative_id']+'/content',headers=self.h)
        self.assertEqual(content.content,(fixture/'canonical.png').read_bytes())
        job={'job_id':'fixture','attempt_id':'attempt','request':{'width':64,'height':32,'inputs':[{'input_id':uploaded['input_id'],'role':'first_frame','transform':manifest['transform']}]}}
        prepared=self.s.assets.prepare_inputs(job)
        self.assertEqual(prepared[uploaded['input_id']+':first_frame']['sha256'],manifest['sha256'])
