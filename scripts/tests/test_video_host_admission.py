import asyncio
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'PythonDistribution'/'Overlay'))
from nativ_generation.resources import ComputeAdmission
from nativ_generation.host_admission import HostAdmission,HostAdmissionMiddleware,scoped_to_thread

class HostAdmissionTests(unittest.IsolatedAsyncioTestCase):
    async def test_disconnect_does_not_release_background_thread(self):
        with tempfile.TemporaryDirectory() as td:
            admission=ComputeAdmission(Path(td)/'compute.lock');host=HostAdmission(admission);entered=threading.Event();finish=threading.Event()
            async def app(scope,receive,send):
                await scoped_to_thread(host,lambda:(entered.set(),finish.wait(2)))
            wrapped=HostAdmissionMiddleware(app,host)
            task=asyncio.create_task(wrapped({'type':'http','method':'POST','path':'/v1/embeddings'},None,None))
            await asyncio.to_thread(entered.wait,1);task.cancel()
            with self.assertRaises(asyncio.CancelledError):await task
            self.assertIsNone(admission.try_acquire('video'))
            finish.set()
            for _ in range(50):
                if host.active==0:break
                await asyncio.sleep(.01)
            lease=admission.try_acquire('video');self.assertIsNotNone(lease);lease.close()
    async def test_busy_host_request_is_rejected_before_work(self):
        with tempfile.TemporaryDirectory() as td:
            admission=ComputeAdmission(Path(td)/'compute.lock');exclusive=admission.try_acquire('video');called=[];sent=[]
            async def app(*args):called.append(True)
            async def send(item):sent.append(item)
            await HostAdmissionMiddleware(app,HostAdmission(admission))({'type':'http','method':'POST','path':'/v1/chat/completions'},None,send)
            self.assertFalse(called);self.assertEqual(sent[0]['status'],409);exclusive.close()
    async def test_image_and_control_routes_do_not_double_acquire(self):
        with tempfile.TemporaryDirectory() as td:
            admission=ComputeAdmission(Path(td)/'compute.lock');exclusive=admission.try_acquire('video');called=[]
            async def app(*args):called.append(True)
            wrapped=HostAdmissionMiddleware(app,HostAdmission(admission))
            for method,path in [('POST','/v1/images/generations'),('GET','/v1/video/generations/job'),('POST','/v1/video/generations/job/cancel')]:
                await wrapped({'type':'http','method':method,'path':path},None,None)
            self.assertEqual(len(called),3);exclusive.close()
