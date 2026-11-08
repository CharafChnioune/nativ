import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'PythonDistribution'/'Overlay'))
from nativ_video.providers.http import safe_url
from nativ_generation.contracts import GenerationError
import test_video_cloud as cloud
Response,Context=cloud.Response,cloud.Context

class VideoAdversarialTests(unittest.TestCase):
    provider=cloud.VideoCloudTests.provider
    job=cloud.VideoCloudTests.job
    # Reuse transport fixtures while adding consequential failure assertions.
    def test_no_private_redirect_or_output_location(self):
        for url in ('http://media.example/x','https://localhost/x','https://127.0.0.1/x','https://user:secret@media.example/x','https://media.example:8443/x'):
            with self.subTest(url=url),patch('socket.getaddrinfo',return_value=[(2,1,6,'',('127.0.0.1',443))]),self.assertRaises(GenerationError): safe_url(url)
    def test_known_success_recorded_before_failing_download(self):
        p,t=self.provider('runway-gen4.5',[Response(200,{'id':'task'}),Response(200,{'status':'SUCCEEDED','output':['https://media.example/clip']}),Response(403)])
        with tempfile.TemporaryDirectory() as td,patch('socket.getaddrinfo',return_value=[(2,1,6,'',('8.8.8.8',443))]):
            c=Context(Path(td))
            with self.assertRaises(GenerationError) as caught:p.run(self.job(p),c)
            self.assertEqual(caught.exception.code,'output_url_expired'); self.assertEqual(c.operations[-1]['state'],'SUCCEEDED')
            job=self.job(p);job['provider_operation']=c.operations[-1]
            self.assertTrue(p.cancel(job,c).provider_terminal)
            self.assertEqual(sum(m=='POST' for m,_,_ in t.calls),1)
    def test_retry_download_polls_existing_operation_never_creates(self):
        p,t=self.provider('runway-gen4.5',[Response(200,{'status':'SUCCEEDED','output':['https://media.example/refreshed']}),Response(content=b'original')])
        job=self.job(p);job['provider_operation']={'id':'task','endpoint_kind':'text_to_video','base_url':p.BASE_URL,'account_id':'account-one'}
        with tempfile.TemporaryDirectory() as td,patch('socket.getaddrinfo',return_value=[(2,1,6,'',('8.8.8.8',443))]):
            c=Context(Path(td));r=p.reconcile(job,c)
            self.assertEqual(r.path.read_bytes(),b'original');self.assertEqual(c.dispatches,0)
            self.assertTrue(all(m=='GET' for m,_,_ in t.calls));self.assertEqual(c.waits,[5])
    def test_same_account_key_rotation_is_permitted(self):
        p,t=self.provider('runway-gen4.5',[Response(200,{'status':'FAILED'})])
        p.services.credentials=lambda _: 'rotated-secret'
        job=self.job(p);job['provider_operation']={'id':'task','endpoint_kind':'text_to_video','base_url':p.BASE_URL,'account_id':'account-one'}
        with tempfile.TemporaryDirectory() as td:
            with self.assertRaises(GenerationError):p.reconcile(job,Context(Path(td)))
            self.assertEqual(t.calls[0][2]['headers']['Authorization'],'Bearer rotated-secret')
    def test_safety_rejection_is_definitive_and_never_falls_back(self):
        p,t=self.provider('ltx-2-5-fast-cloud',[Response(422,{'error':{'message':'private body'}})])
        with tempfile.TemporaryDirectory() as td:
            with self.assertRaises(GenerationError) as caught:p.run(self.job(p),Context(Path(td)))
            self.assertEqual(caught.exception.code,'provider_content_rejected');self.assertTrue(caught.exception.definitive)
            self.assertNotIn('private body',str(caught.exception));self.assertEqual(len(t.calls),1)
    def test_http_failure_poll_backoff_does_not_repeat_paid_post(self):
        p,t=self.provider('ltx-2-5-fast-cloud',[Response(202,{'id':'task'}),Response(503),Response(200,{'status':'processing'}),Response(200,{'status':'failed'})])
        with tempfile.TemporaryDirectory() as td:
            c=Context(Path(td))
            with self.assertRaises(GenerationError):p.run(self.job(p),c)
            self.assertEqual(c.waits,[5,10,5]);self.assertEqual(sum(m=='POST' for m,_,_ in t.calls),1)
    def test_cancel_rechecks_terminal_state_before_delete(self):
        p,t=self.provider('runway-gen4.5',[Response(200,{'status':'SUCCEEDED','output':['https://media.example/x']})])
        job=self.job(p);job['provider_operation']={'id':'task','endpoint_kind':'text_to_video','base_url':p.BASE_URL,'account_id':'account-one'}
        with tempfile.TemporaryDirectory() as td:
            self.assertTrue(p.cancel(job,Context(Path(td))).provider_terminal)
            self.assertEqual([x[0] for x in t.calls],['GET'])
