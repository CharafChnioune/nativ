from pathlib import Path
import importlib.util
import math
import struct
import sys
import tempfile
from threading import Event
import unittest

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'PythonDistribution/Overlay'))
from nativ_generation.contracts import GenerationError,GenerationCancelled
FILE=ROOT/'PythonDistribution/Overlay/nativ_generation/audio_media.py'


def float_wav(path,invalid=False):
    samples=b''.join(struct.pack('<ff',value,value) for value in (float('nan') if invalid else .25*math.sin(2*math.pi*440*i/48000) for i in range(4800)))
    header=b'fmt '+struct.pack('<IHHIIHH',16,3,2,48000,48000*8,8,32)
    data=b'data'+struct.pack('<I',len(samples))+samples
    path.write_bytes(b'RIFF'+struct.pack('<I',4+len(header)+len(data))+b'WAVE'+header+data)


class GenerationAudioMediaTests(unittest.TestCase):
    def module(self):
        self.assertTrue(FILE.is_file(),'Canonical MP3/FLOAT audio needs the managed decoder')
        spec=importlib.util.spec_from_file_location('nativ_generation.audio_media_fixture',FILE);value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value
    def codecs(self):
        directory=ROOT/'dist/codec-runtime/bin'
        if not (directory/'ffmpeg').is_file():self.skipTest('Managed codec source build is the separate CI prerequisite')
        return {name:str(directory/name) for name in ('ffmpeg','ffprobe')}
    def test_missing_managed_decoder_is_actionable(self):
        module=self.module()
        with self.assertRaises(GenerationError) as error:module.probe_audio(Path('unused.mp3'),{})
        self.assertEqual(error.exception.code,'codec_unavailable')
    def test_real_mp3_decodes_without_soundfile_or_numpy(self):
        module=self.module();path=ROOT/'scripts/tests/fixtures/generation-audio/tone-440hz-stereo.mp3'
        result=module.probe_audio(path,self.codecs())
        self.assertEqual(result['sample_rate'],44100);self.assertEqual(result['channels'],2)
        self.assertGreaterEqual(result['frame_count'],44100);self.assertLess(result['duration_seconds'],1.1)
        self.assertTrue(0<len(result['waveform'])<=256);self.assertGreater(result['peak'],.1)
    def test_real_float_wav_counts_decoded_frames(self):
        module=self.module()
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'float.partial';float_wav(path)
            result=module.probe_audio(path,self.codecs())
            self.assertEqual(result['frame_count'],4800);self.assertEqual(result['duration_seconds'],.1)
            self.assertEqual(result['sample_rate'],48000);self.assertEqual(result['channels'],2)
    def test_nonfinite_and_cancelled_audio_are_rejected(self):
        module=self.module()
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'invalid.wav';float_wav(path,invalid=True)
            with self.assertRaises(GenerationError):module.probe_audio(path,self.codecs())
            event=Event();event.set()
            with self.assertRaises(GenerationCancelled):module.probe_audio(path,self.codecs(),event)
    def test_decoded_byte_limit_stops_real_decoder(self):
        module=self.module()
        from unittest.mock import patch
        path=ROOT/'scripts/tests/fixtures/generation-audio/tone-440hz-stereo.mp3'
        with patch.object(module,'MAX_DECODED_BYTES',1000),self.assertRaises(GenerationError) as error:
            module.probe_audio(path,self.codecs())
        self.assertEqual(error.exception.code,'audio_decode_limit')

    def test_stalled_decoder_timeout_reaps_owned_process(self):
        module=self.module()
        import time
        started=time.monotonic()
        with self.assertRaises(GenerationError) as error:
            module._stream([sys.executable,'-c','import time;time.sleep(3)'],Event(),lambda _:None,limit=1024,timeout=.01)
        self.assertEqual(error.exception.code,'audio_decode_timeout')
        self.assertLess(time.monotonic()-started,2)


if __name__=='__main__':unittest.main()
