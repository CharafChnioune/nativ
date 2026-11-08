import io,json,struct,sys,tempfile,threading,time,unittest,wave
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'PythonDistribution/Overlay'))
from nativ_generation.contracts import ProviderContext,ProviderServices,GenerationCancelled
from nativ_generation.remote_process import RemoteExecutionProvider
from nativ_music.catalog import profiles
from nativ_music.providers import build_provider
try:import httpx;AVAILABLE=True
except ImportError:AVAILABLE=False

@unittest.skipUnless(AVAILABLE,'Requires isolated HTTP client dependencies')
class RemoteProcessTests(unittest.TestCase):
    def test_durable_dispatch_ack_precedes_real_http_and_result_is_owned(self):
        self.run_case(cancel=False)
    def test_cancel_terminates_blocked_remote_observation_without_second_post(self):
        self.run_case(cancel=True)
    def run_case(self,cancel):
        dispatched=threading.Event();received=threading.Event();release=threading.Event();posts=[];violations=[]
        raw=io.BytesIO()
        with wave.open(raw,'wb') as f:f.setparams((2,2,32000,0,'NONE',''));f.writeframes(struct.pack('<200h',*range(200)))
        audio=raw.getvalue()
        class Handler(BaseHTTPRequestHandler):
            def log_message(self,*args):pass
            def do_POST(self):
                if not dispatched.is_set():violations.append('POST before durable ACK')
                posts.append(self.path);self.rfile.read(int(self.headers.get('Content-Length',0)));received.set()
                if cancel:release.wait(8)
                try:
                    self.send_response(200);self.send_header('Content-Length',str(len(audio)));self.send_header('X-Request-ID','accepted-operation');self.end_headers();self.wfile.write(audio)
                except (BrokenPipeError,ConnectionResetError):pass
        server=ThreadingHTTPServer(('127.0.0.1',0),Handler);server.daemon_threads=True
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        with tempfile.TemporaryDirectory() as temp:
            profile=next(p for p in profiles() if p['id']=='minimax-music3-remote-gpu')
            configuration={profile['id']:{'endpoint':'http://127.0.0.1:'+str(server.server_port),'allow_local_http':True,'account_id':'fixture'}}
            services=ProviderServices(configuration=configuration,credentials=lambda p:'fixture-key')
            request=build_provider(profile,services).normalize({'model':profile['id'],'prompt':'test','instrumental':True,'duration_seconds':1,'allow_remote':True})
            job={'job_id':'fixture','attempt_id':'attempt','profile':profile,'request':request,'provider_operation':None,'state':'preparing'}
            cancellation=threading.Event();operations=[];result=[];errors=[];progress=[]
            context=ProviderContext(output_dir=Path(temp),cancellation=cancellation,emit=lambda *a:progress.append(a),dispatch=dispatched.set,operation=operations.append)
            provider=RemoteExecutionProvider(profile,services)
            def execute():
                try:result.append(provider.run(job,context))
                except BaseException as error:errors.append(error)
            task=threading.Thread(target=execute);task.start()
            try:
                self.assertTrue(received.wait(10),'Helper never reached the local fixture server')
                if cancel:
                    start=time.monotonic();cancellation.set();task.join(5)
                    self.assertFalse(task.is_alive());self.assertLess(time.monotonic()-start,5);self.assertIsInstance(errors[0],GenerationCancelled)
                else:
                    task.join(10);self.assertFalse(task.is_alive());self.assertEqual(errors,[])
                    self.assertEqual(result[0].path.read_bytes(),audio);self.assertEqual(operations[0]['id'],'accepted-operation')
                    self.assertTrue(any(p[2].get('provider_outcome')=='completed' for p in progress))
                self.assertEqual(posts,['/v1/audio/speech']);self.assertEqual(violations,[])
            finally:release.set();cancellation.set();task.join(10);server.shutdown();server.server_close();thread.join()
