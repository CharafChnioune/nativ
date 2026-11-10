import asyncio
import contextlib
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'PythonDistribution/Overlay'))
from nativ_generation.resources import ComputeAdmission


def module(name,file):
    spec=importlib.util.spec_from_file_location(name,file);value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value


class ImageExecutionPatchTests(unittest.IsolatedAsyncioTestCase):
    def helper(self):
        file=ROOT/'PythonDistribution/Patches/image_execution.py'
        self.assertTrue(file.is_file(),'Images need a dedicated MLX execution owner')
        return module('image_execution_fixture',file)

    async def test_controls_remain_responsive_and_cancel_keeps_worker_lease(self):
        helper=self.helper()
        with tempfile.TemporaryDirectory() as directory:
            admission=ComputeAdmission(Path(directory)/'compute.lock');helper.configure_admission(admission)
            started=threading.Event();release=threading.Event();observations=[]
            class MLX:
                def default_device(self):return 'gpu'
                def new_stream(self,device):return 'owned-stream'
                @contextlib.contextmanager
                def stream(self,stream):observations.append(('stream',threading.get_ident()));yield
                def synchronize(self,stream):observations.append(('sync',threading.get_ident()))
            def slow():started.set();release.wait(5);return 'image-response'
            with patch.object(helper,'_mlx',return_value=MLX()):
                task=asyncio.create_task(helper.run_image(slow))
                deadline=time.monotonic()+2
                while not started.is_set() and time.monotonic()<deadline:await asyncio.sleep(.005)
                self.assertTrue(started.is_set())
                self.assertTrue(helper.has_active_work())
                tick=time.monotonic();await asyncio.sleep(.01);self.assertLess(time.monotonic()-tick,.2)
                task.cancel()
                with self.assertRaises(asyncio.CancelledError):await task
                self.assertIsNone(admission.try_acquire('conflicting-generation'))
                release.set();await helper.drain()
                self.assertFalse(helper.has_active_work())
                lease=admission.try_acquire('after-worker');self.assertIsNotNone(lease);lease.close()
                self.assertEqual(observations[0][1],observations[-1][1]);self.assertNotEqual(observations[0][1],threading.get_ident())
            await helper.shutdown()

    async def test_host_wrapped_model_load_inside_an_image_reuses_its_lease(self):
        # mlx-vlm's image handlers load models through the host-wrapped get_cached_model on the image thread.
        helper=self.helper()
        from nativ_generation import host_admission
        from nativ_generation.contracts import GenerationError
        with tempfile.TemporaryDirectory() as directory:
            admission=ComputeAdmission(Path(directory)/'compute.lock');helper.configure_admission(admission)
            load=host_admission._sync_wrapper(lambda:'model',host_admission.HostAdmission(admission))
            class MLX:
                def default_device(self):return 'gpu'
                def new_stream(self,device):return 'owned-stream'
                @contextlib.contextmanager
                def stream(self,stream):yield
                def synchronize(self,stream):pass
            with patch.object(helper,'_mlx',return_value=MLX()):self.assertEqual(await helper.run_image(load),'model')
            music=admission.try_acquire('music')
            try:
                with self.assertRaises(GenerationError):load()  # the bypass stays on the image thread
            finally:music.close();await helper.shutdown()

    async def test_conflicting_images_reject_without_queueing_or_loading(self):
        helper=self.helper()
        with tempfile.TemporaryDirectory() as directory:
            admission=ComputeAdmission(Path(directory)/'compute.lock');helper.configure_admission(admission)
            lease=admission.try_acquire('music');called=[]
            try:
                with self.assertRaises(Exception) as error:await helper.run_image(lambda:called.append(True))
                self.assertEqual(getattr(error.exception,'status',None),409);self.assertEqual(called,[])
            finally:lease.close();await helper.shutdown()

    async def test_preloaded_image_cache_unloads_on_owner_thread_before_first_request(self):
        helper=self.helper();calls=[]
        from types import SimpleNamespace
        @contextlib.contextmanager
        def stream(_):yield
        mlx=SimpleNamespace(default_device=lambda:'gpu',new_stream=lambda _:'owned',stream=stream,synchronize=lambda _:None)
        app=SimpleNamespace(_unload_model_cache_group=lambda kind:calls.append((kind,threading.get_ident())))
        with tempfile.TemporaryDirectory() as directory:
            admission=ComputeAdmission(Path(directory)/'lock');helper.configure_admission(admission)
            # Mirrors the scheduler: an exclusive lease already surrounds unload.
            lease=admission.try_acquire('local-generation')
            with patch.object(helper,'_mlx',return_value=mlx),patch.object(helper.importlib,'import_module',return_value=app):
                helper.unload_idle_images()
            lease.close()
            self.assertEqual([item[0] for item in calls],['image_generation','image_edit'])
            self.assertTrue(all(item[1]!=threading.get_ident() for item in calls))
            await helper.shutdown()

    def test_hash_guard_patch_is_idempotent_and_rejects_unknown_source(self):
        script=ROOT/'PythonDistribution/Patches/apply_patch.py'
        self.assertTrue(script.is_file(),'Image packaging patch must have immutable source guards')
        applier=module('image_patch_fixture',script)
        source=''
        for name in ('images_generations_endpoint','images_edits_endpoint'):
            source+=f'async def {name}(request):\n    body = await request.json()\n    try:\n        return generate_image(body)\n    except Exception:\n        clear_cache()\n        raise\n\n'
        transformed=applier.transform(source)
        self.assertIn('return await run_image(',transformed)
        self.assertEqual(transformed.count('def _nativ_execute_'),2)
        self.assertNotIn('asyncio.to_thread',transformed)
        compile(transformed,'fixture','exec')
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);file=root/'mlx_vlm/server/openai.py';file.parent.mkdir(parents=True);file.write_text(source)
            manifest=root/'manifest.json';manifest.write_text(json.dumps(dict(path='mlx_vlm/server/openai.py',source_sha256=hashlib.sha256(source.encode()).hexdigest(),patched_sha256=hashlib.sha256(transformed.encode()).hexdigest())))
            with patch.object(applier,'MANIFEST',manifest):
                applier.apply(root);applier.apply(root)
                file.write_text(file.read_text()+'# unknown edit\n')
                with self.assertRaises(ValueError):applier.apply(root)


if __name__=='__main__':unittest.main()
