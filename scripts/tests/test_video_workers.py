import importlib
import json
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'PythonDistribution'/'Overlay'))
from nativ_video import workers

class VideoWorkerTests(unittest.TestCase):
    def test_ltx_calls_public_pipeline_with_exact_grid_and_image(self):
        calls=[]
        class Pipeline:
            def __init__(self,**kw): calls.append(('init',kw))
            def generate_and_save(self,**kw): calls.append(('generate',kw)); Path(kw['output_path']).write_bytes(b'candidate')
        with tempfile.TemporaryDirectory() as td:
            root=Path(td); output=root/'candidate.mp4'; image=root/'image.png'; image.write_bytes(b'image')
            req={'prompt':'boat','width':704,'height':448,'frame_count':97,'fps':24,'seed':42,'audio_mode':'native_generated','operation':'image_to_video'}
            with patch.dict(sys.modules,{'ltx_pipelines_mlx':types.SimpleNamespace(DistilledPipeline=Pipeline)}):
                meta=workers.run_ltx(req,{'model_path':td,'inputs':{'first_frame':str(image)}},output,lambda *a,**k:None)
            self.assertEqual(calls[1][1]['image'],str(image)); self.assertEqual(calls[1][1]['num_frames'],97)
            self.assertEqual(calls[1][1]['frame_rate'],24); self.assertEqual(meta['audio_sample_rate'],48000)
            self.assertNotIn('generate_audio',calls[1][1])
    def test_wan_actual_progress_and_save_contract(self):
        calls=[]; events=[]
        class Result:
            def save(self,path,**kw): calls.append(('save',kw)); Path(path).write_bytes(b'video')
        class Model:
            def __init__(self,**kw): calls.append(('init',kw))
            def generate_video(self,**kw):
                calls.append(('generate',kw)); kw['progress_callback'](types.SimpleNamespace(phase='denoise',step=4,total_steps=50)); return Result()
        mods={'mflux':types.ModuleType('mflux'),'mflux.models':types.ModuleType('mflux.models'),'mflux.models.wan':types.ModuleType('mflux.models.wan'),'mflux.models.wan.variants':types.ModuleType('mflux.models.wan.variants'),'mflux.models.wan.variants.wan2_2_ti2v':types.SimpleNamespace(Wan2_2_TI2V=Model)}
        with tempfile.TemporaryDirectory() as td,patch.dict(sys.modules,mods):
            r=workers.run_wan(dict(prompt='boat',seed=42,width=832,height=480,frame_count=81,fps=24,steps=50,flow_shift=3,operation='text_to_video',audio_mode='silent'),{'model_path':td},Path(td)/'candidate.mp4',lambda *a,**kw:events.append((a,kw)))
            self.assertEqual(calls[1][1]['num_frames'],81); self.assertEqual(calls[1][1]['flow_shift'],3); self.assertEqual(calls[1][1]['canvas_policy'],'exact-resize')
            self.assertIsNone(calls[1][1].get('last_image_path')); self.assertEqual(events[-2][1]['progress'],0.08)
            self.assertEqual(r['audio_mode'],'silent')
    def test_h3_public_api_keeps_joint_audio_and_uses_fl2va(self):
        calls=[]
        def load(model,**kw): calls.append(('load',model,kw)); return object()
        class Request:
            def __init__(self,**kw): self.__dict__.update(kw); calls.append(('request',kw))
        def gen(model,req,**kw): calls.append(('generate',kw)); Path(kw['output_path']).write_bytes(b'candidate')
        mods={'mlx_vlm':types.ModuleType('mlx_vlm'),'mlx_vlm.generate':types.SimpleNamespace(VideoGenerationRequest=Request,load_video_generation_model=load,generate_video=gen)}
        with tempfile.TemporaryDirectory() as td,patch.dict(sys.modules,mods):
            req=dict(prompt='boat',seed=42,width=832,height=480,frame_count=124,fps=24,steps=30,operation='image_to_video',audio_mode='native_generated')
            workers.run_h3(req,{'model_path':td,'inputs':{'first_frame':'first.png','last_frame':'last.png'},'separate_license_approved':True},Path(td)/'candidate.mp4',lambda *a,**kw:None)
            self.assertEqual(calls[0][2]['workflow'],'fl2va'); self.assertEqual(calls[1][1]['last_image'],'last.png')
            self.assertNotIn('generate_audio',calls[1][1])
            with self.assertRaises(ValueError): workers.run_h3(req,{'model_path':td},Path(td)/'x',lambda *a,**kw:None)
