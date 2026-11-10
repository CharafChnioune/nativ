import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'PythonDistribution'/'Overlay'))
from nativ_video.media import validate_probe, probe
from nativ_generation.contracts import GenerationError

class VideoMediaTests(unittest.TestCase):
    def metadata(self,audio=True):
        streams=[{'codec_type':'video','codec_name':'h264','width':704,'height':448,'nb_read_frames':'97','avg_frame_rate':'24/1','r_frame_rate':'24/1','duration':str(97/24),'pix_fmt':'yuv420p','sample_aspect_ratio':'1:1'}]
        if audio: streams.append({'codec_type':'audio','codec_name':'aac','sample_rate':'48000','channels':2,'duration':str(97/24)})
        return {'format':{'format_name':'mov,mp4,m4a,3gp,3g2,mj2','duration':str(97/24)},'streams':streams}
    def accepted(self): return {'width':704,'height':448,'frame_count':97,'fps':24,'audio_mode':'native_generated','audio_sample_rate':48000}
    def test_measured_values_and_audio_contract(self):
        m=validate_probe(self.metadata(),self.accepted())
        self.assertEqual(m['frame_count'],97); self.assertEqual(m['audio']['sample_rate'],48000)
        with self.assertRaises(GenerationError): validate_probe(self.metadata(False),self.accepted())
        data=self.metadata(); data['streams'][1]['sample_rate']='32000'
        with self.assertRaises(GenerationError): validate_probe(data,self.accepted())
    def test_wrong_frames_fps_duration_rotation_or_audio_alignment_fail(self):
        for field,value in [('nb_read_frames','96'),('avg_frame_rate','25/1'),('duration','3.0'),('sample_aspect_ratio','2:1')]:
            d=self.metadata(); d['streams'][0][field]=value
            with self.subTest(field=field), self.assertRaises(GenerationError): validate_probe(d,self.accepted())
        d=self.metadata(); d['streams'][0]['side_data_list']=[{'rotation':90}]
        with self.assertRaises(GenerationError): validate_probe(d,self.accepted())
        d=self.metadata(); d['streams'][1]['duration']='2.0'
        with self.assertRaises(GenerationError): validate_probe(d,self.accepted())
    def test_untrusted_extension_never_counts_as_valid(self):
        with tempfile.TemporaryDirectory() as td:
            path=Path(td)/'clip.mp4'; path.write_bytes(b'not a movie')
            with self.assertRaises(GenerationError): probe(path,self.accepted(),{})

    def test_one_frame_plus_priming_rejects_skew(self):
        d=self.metadata(); d['streams'][1]['duration']=str(97/24+0.08)
        with self.assertRaises(GenerationError): validate_probe(d,self.accepted())
        d=self.metadata(); d['streams'][1]['start_time']='0.08'
        with self.assertRaises(GenerationError): validate_probe(d,self.accepted())

    def test_probe_subprocess_cancellation_reaps_owned_process(self):
        import os
        import threading
        import time
        from nativ_video.media import _run
        from nativ_generation.contracts import GenerationCancelled
        with tempfile.TemporaryDirectory() as td:
            pidfile=Path(td)/'pid'
            source='import os,time;open('+repr(str(pidfile))+',"w").write(str(os.getpid()));time.sleep(30)'
            event=threading.Event();timer=threading.Timer(0.1,event.set);timer.start()
            started=time.monotonic()
            with self.assertRaises(GenerationCancelled): _run([sys.executable,'-c',source],cancellation=event)
            timer.join();self.assertLess(time.monotonic()-started,2)
            if pidfile.exists():
                with self.assertRaises(ProcessLookupError): os.kill(int(pidfile.read_text()),0)
