import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from threading import Event
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'PythonDistribution'/'Overlay'))
from nativ_video.catalog import profiles
from nativ_video.providers import build_provider
from nativ_generation.contracts import GenerationError,ProviderServices,ProviderContext

class Response:
    def __init__(self,status=200,data=None,content=b'clip'):
        self.status_code=status; self._data=data or {}; self.content=json.dumps(data).encode() if data is not None else content; self.headers={'content-type':'application/json' if data is not None else 'video/mp4'}
    def json(self): return self._data
    def iter_bytes(self,chunk_size=65536): yield self.content
    def __enter__(self): return self
    def __exit__(self,*a): pass
class Transport:
    def __init__(self,responses): self.responses=list(responses); self.calls=[]
    def request(self,method,url,**kw):
        self.calls.append((method,url,kw)); r=self.responses.pop(0)
        if isinstance(r,Exception): raise r
        return r
    def stream(self,method,url,**kw): return self.request(method,url,**kw)
class Context(ProviderContext):
    def __init__(self,path,inputs=None):
        self.events=[]; self.operations=[]; self.dispatches=0; self.waits=[]
        super().__init__(output_dir=path,cancellation=Event(),emit=lambda *a:self.events.append(a),dispatch=self.mark,operation=self.operations.append,inputs=inputs)
    def mark(self): self.dispatches+=1
    def wait(self,seconds): self.waits.append(seconds); self.check_cancelled()

class VideoCloudTests(unittest.TestCase):
    def provider(self,name,responses,account='account-one'):
        p=next(p for p in profiles() if p['id']==name); t=Transport(responses)
        s=ProviderServices(transport=t,credentials=lambda _: 'test-secret',configuration={name:{'account_id':account,'poll_jitter_seconds':0}})
        return build_provider(p,s),t
    def job(self,p,**kw):
        raw=dict(prompt='boat',allow_remote=True); raw.update(kw); req=p.normalize(raw)
        return dict(job_id='job',attempt_id='attempt',request=req,profile=p.profile,provider_operation=None)
    @patch('socket.getaddrinfo',return_value=[(2,1,6,'',('8.8.8.8',443))])
    def test_ltx_v2_persisted_before_poll_and_no_secret_to_download(self,_):
        p,t=self.provider('ltx-2-5-fast-cloud',[Response(202,{'id':'op','created_at':'now'}),Response(200,{'status':'completed','result':{'video_url':'https://media.example/clip'}}),Response(content=b'raw-video')])
        with tempfile.TemporaryDirectory() as td:
            c=Context(Path(td)); r=p.run(self.job(p),c)
            self.assertEqual(r.path.read_bytes(),b'raw-video'); self.assertEqual(c.dispatches,1)
            self.assertEqual(c.operations[0]['endpoint_kind'],'text-to-video'); self.assertEqual(c.waits,[5])
            self.assertEqual(t.calls[0][1],'https://api.ltx.io/v2/text-to-video')
            self.assertEqual(t.calls[0][2]['json']['resolution'],'1280x720')
            self.assertNotIn('Authorization',t.calls[-1][2]['headers'])
    def test_ambiguous_post_is_never_retried(self):
        p,t=self.provider('runway-gen4.5',[TimeoutError('lost')])
        with tempfile.TemporaryDirectory() as td:
            c=Context(Path(td))
            with self.assertRaises(GenerationError) as caught: p.run(self.job(p),c)
            self.assertFalse(caught.exception.definitive); self.assertEqual(len(t.calls),1); self.assertEqual(c.dispatches,1)
    def test_ltx_upload_headers_unchanged_and_private_input(self):
        p,t=self.provider('ltx-2-5-fast-cloud',[Response(200,{'upload_url':'https://storage.example/upload','storage_uri':'ltx://private','required_headers':{'x-goog-if-generation-match':'0'}}),Response(200),Response(202,{'id':'op'}),Response(200,{'status':'failed','error':{'message':'private moderation detail'}})])
        with tempfile.TemporaryDirectory() as td:
            image=Path(td)/'input.png'; image.write_bytes(b'snapshot')
            c=Context(Path(td),{'image':{'path':str(image)}})
            with patch('socket.getaddrinfo',return_value=[(2,1,6,'',('8.8.8.8',443))]), self.assertRaises(GenerationError):
                p.run(self.job(p,operation='image_to_video',inputs=[{'input_id':'image','role':'first_frame'}]),c)
            self.assertEqual(t.calls[1][0],'PUT'); self.assertEqual(t.calls[1][2]['headers']['x-goog-if-generation-match'],'0')
            self.assertNotIn('Authorization',t.calls[1][2]['headers'])
            self.assertEqual(t.calls[2][2]['json']['image_uri'],'ltx://private')
    def test_runway_terminal_output_array_and_late_cancel_never_deletes(self):
        p,t=self.provider('runway-gen4.5',[Response(200,{'status':'SUCCEEDED','output':['https://media.example/clip']})])
        job=self.job(p); job['provider_operation']={'id':'task','endpoint_kind':'text_to_video','account_id':'account-one','base_url':'https://api.dev.runwayml.com','state':'SUCCEEDED'}
        with tempfile.TemporaryDirectory() as td:
            result=p.cancel(job,Context(Path(td)))
            self.assertTrue(result.provider_terminal); self.assertEqual(t.calls,[])
    def test_account_change_cannot_retarget_saved_operation(self):
        p,t=self.provider('runway-gen4.5',[],account='different')
        job=self.job(p); job['provider_operation']={'id':'task','endpoint_kind':'text_to_video','account_id':'account-one','base_url':'https://api.dev.runwayml.com'}
        with tempfile.TemporaryDirectory() as td:
            with self.assertRaises(GenerationError) as caught: p.reconcile(job,Context(Path(td)))
            self.assertEqual(caught.exception.code,'deployment_changed'); self.assertEqual(t.calls,[])
    def test_matrix_and_utf16_validation(self):
        p,_=self.provider('ltx-2-5-pro-cloud',[])
        with self.assertRaises(GenerationError): self.job(p,duration=20)
        p,_=self.provider('runway-gen4.5',[])
        with self.assertRaises(GenerationError): self.job(p,prompt='\U0001f600'*501)

    def test_generation_json_wire_bytes_are_bounded_before_buffering(self):
        class Oversize(Response):
            consumed=0
            def iter_bytes(self,chunk_size=65536):
                for _ in range(64):
                    self.consumed+=1;yield b'x'*65536
        response=Oversize(200)
        p,t=self.provider('runway-gen4.5',[response])
        with tempfile.TemporaryDirectory() as td:
            c=Context(Path(td))
            with self.assertRaises(GenerationError) as caught:p.run(self.job(p),c)
            self.assertFalse(caught.exception.definitive);self.assertEqual(len(t.calls),1)
            self.assertEqual(response.consumed,17);self.assertEqual(c.operations,[])
