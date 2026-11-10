import importlib.util
import json
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch
OVERLAY=Path(__file__).resolve().parents[2]/'PythonDistribution'/'Overlay'
sys.path.insert(0,str(OVERLAY))
from nativ_video import workers

def mlx_video(model,**attributes):
    names=('mlx_video','mlx_video.models','mlx_video.models.'+model)
    return {**{name:types.ModuleType(name) for name in names},'mlx_video.models.'+model+'.generate':types.SimpleNamespace(**attributes)}

class VideoWorkerTests(unittest.TestCase):
    def test_ltx_runs_distilled_with_native_audio_and_local_text_encoder(self):
        calls=[]
        def generate_video(**kw): calls.append(kw); Path(kw['output_path']).write_bytes(b'candidate')
        mods=mlx_video('ltx_2',PipelineType=types.SimpleNamespace(DISTILLED='distilled'),generate_video=generate_video)
        with tempfile.TemporaryDirectory() as td,patch.dict(sys.modules,mods):
            image=Path(td)/'image.png'; image.write_bytes(b'image')
            req={'prompt':'boat','width':704,'height':448,'frame_count':97,'fps':24,'seed':42,'audio_mode':'native_generated','operation':'image_to_video'}
            meta=workers.run_ltx(req,{'model_path':td,'inputs':{'first_frame':str(image)}},Path(td)/'candidate.mp4',lambda *a,**k:None)
        kw=calls[0]
        self.assertEqual((kw['model_repo'],kw['text_encoder_repo'],kw['pipeline'],kw['audio']),(td,None,'distilled',True))
        self.assertEqual((kw['image'],kw['width'],kw['height'],kw['num_frames'],kw['fps'],kw['seed']),(str(image),704,448,97,24,42))
        self.assertEqual(meta['audio_sample_rate'],48000)
        # The upstream mux used -shortest, which dropped trailing video frames when the audio ended first.
        with patch.object(workers.subprocess,'run',return_value=types.SimpleNamespace(returncode=0)) as run:
            self.assertTrue(mods['mlx_video.models.ltx_2.generate'].mux_video_audio('v.mp4','a.wav','o.mp4'))
        self.assertEqual(run.call_args.args[0],['ffmpeg','-v','error','-y','-i','v.mp4','-i','a.wav','-c:v','copy','-c:a','aac','o.mp4'])
    def test_wan_maps_steps_and_shift_and_serves_only_umt5_from_pinned_folder(self):
        calls=[];tokenizers=[]
        class AutoTokenizer:
            @classmethod
            def from_pretrained(cls,name,**kw): tokenizers.append(name)
        transformers=types.SimpleNamespace(AutoTokenizer=AutoTokenizer)
        def generate_video(**kw):
            transformers.AutoTokenizer.from_pretrained('google/umt5-xxl'); transformers.AutoTokenizer.from_pretrained('other/model')
            calls.append(kw); Path(kw['output_path']).write_bytes(b'video')
        with tempfile.TemporaryDirectory() as td,patch.dict(sys.modules,{'transformers':transformers,**mlx_video('wan_2',generate_video=generate_video)}):
            r=workers.run_wan(dict(prompt='boat',seed=42,width=832,height=480,frame_count=81,fps=24,steps=50,flow_shift=3,operation='text_to_video',audio_mode='silent'),{'model_path':td},Path(td)/'candidate.mp4',lambda *a,**kw:None)
        self.assertEqual(tokenizers,[str(Path(td)/'tokenizer'),'other/model'])
        self.assertEqual((calls[0]['num_frames'],calls[0]['steps'],calls[0]['shift'],calls[0]['seed'],calls[0]['image']),(81,50,3,42,None))
        self.assertEqual(r['audio_mode'],'silent')
    def test_library_stdout_never_reaches_protocol_channel(self):
        code=f'''import os,subprocess,sys
sys.path.insert(0,{str(OVERLAY)!r})
from nativ_video import workers
workers.verify_prepared=lambda prepared,request:None
def run(request,prepared,output,emit):
    print('library print'); os.write(1,b'native write\\n'); subprocess.run(['/bin/echo','child process'])
    output.write_bytes(b'candidate'); return {{}}
workers.run_ltx=run
sys.exit(workers.main())'''
        with tempfile.TemporaryDirectory() as td:
            envelope=json.dumps({'protocol':1,'type':'generate','provider':'ltx_mlx','output_dir':td,'request':{},'prepared':{}})
            done=subprocess.run([sys.executable,'-c',code,'--runtime-id',workers.RUNTIMES['ltx_mlx']],input=envelope+'\n',capture_output=True,text=True,timeout=60)
        events=[json.loads(line) for line in done.stdout.splitlines()]
        self.assertEqual([e['type'] for e in events],['handshake','result'],done.stderr)
        self.assertIn('child process',done.stderr)
        # The worker loads MLX itself (to bound its cache) only when MLX is installed; otherwise no peak is reported.
        peak=events[1]['metadata']['mlx_peak_memory_bytes']
        self.assertEqual(peak is None,importlib.util.find_spec('mlx') is None); self.assertGreater(events[1]['metadata']['max_rss_bytes'],0)
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
