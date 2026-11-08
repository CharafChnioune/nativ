import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'PythonDistribution' / 'Overlay'))
from nativ_video.catalog import profiles
from nativ_video.providers import build_provider
from nativ_generation.contracts import GenerationError, ProviderServices

class VideoCatalogTests(unittest.TestCase):
    def provider(self, name):
        return build_provider(next(p for p in profiles() if p['id'] == name), ProviderServices())

    def test_local_grid_and_no_hidden_rounding(self):
        p = self.provider('ltx-2.5-distilled-q8-local')
        a = p.normalize({'model':'ltx-2.5-distilled-q8-local','prompt':'boat','operation':'text_to_video','output_preset':'draft-landscape','audio_mode':'native_generated'})
        self.assertEqual((a['width'],a['height'],a['frame_count'],a['fps']), (704,448,97,24))
        self.assertEqual(a['audio_sample_rate'],48000)
        for patch in ({'frame_count':98}, {'height':480}, {'negative_prompt':'x'}, {'seed':True}, {'inputs':[{'input_id':'x','role':'first_frame'}]}):
            with self.subTest(patch=patch), self.assertRaises(GenerationError): p.normalize(dict(a, **patch))

    def test_wan_rejects_last_frame_and_native_audio(self):
        p = self.provider('wan2.2-ti2v-5b-q8-local')
        base = {'model':p.profile['id'],'prompt':'boat','operation':'image_to_video','audio_mode':'silent','inputs':[{'input_id':'image','role':'first_frame'}]}
        a = p.normalize(base)
        self.assertEqual((a['width'],a['height'],a['frame_count'],a['flow_shift']),(832,480,81,3))
        with self.assertRaises(GenerationError): p.normalize(dict(base,audio_mode='native_generated'))
        with self.assertRaises(GenerationError): p.normalize(dict(base,inputs=base['inputs']+[{'input_id':'last','role':'last_frame'}]))

    def test_cloud_opt_in_and_unknown_provider_timing(self):
        p = self.provider('runway-gen4.5')
        with self.assertRaises(GenerationError): p.normalize({'prompt':'boat'})
        a = p.normalize({'prompt':'boat','allow_remote':True,'audio_mode':'silent'})
        self.assertIsNone(a['frame_count']); self.assertIsNone(a['fps'])
        with self.assertRaises(GenerationError): p.normalize({'prompt':'\U0001f600'*501,'allow_remote':True})
        with self.assertRaises(GenerationError): p.normalize({'prompt':'boat','allow_remote':True,'fps':24})

    def test_no_catalog_profile_claims_hardware_qualification(self):
        self.assertTrue(all(p['qualification'] != 'qualified' for p in profiles()))
        self.assertFalse(any('api_key' in str(p).lower() for p in profiles()))
