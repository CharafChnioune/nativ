"""Integrity and benchmark boundary regressions; no model load."""
import importlib.util
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

class RuntimeIntegrityTests(unittest.TestCase):
    def test_rejects_corrupt_artifact(self):
        runtime = load('runtime', 'scripts/build_lfm_realtime_runtime.py')
        with tempfile.TemporaryDirectory() as tmp:
            file = pathlib.Path(tmp) / 'model.gguf'
            file.write_bytes(b'corrupt')
            with self.assertRaisesRegex(ValueError, 'integrity'):
                runtime.verify_artifact(file, {'size': 7, 'sha256': '0' * 64})

    def test_manifest_contains_complete_pinned_pair(self):
        runtime = load('runtime', 'scripts/build_lfm_realtime_runtime.py')
        manifest = runtime.read_manifest()
        self.assertEqual(40, len(manifest['runtime']['commit']))
        artifacts = manifest['model']['artifacts']
        self.assertEqual({'Q8_0', 'Q4_K_M', 'projector'}, set(artifacts))
        self.assertEqual(64, len(artifacts['projector']['sha256']))

class FixtureTests(unittest.TestCase):
    def test_sixty_original_turns_require_real_recording_and_review(self):
        import json
        data = json.loads((ROOT / 'scripts/benchmarks/live_translation/fixture-manifest.json').read_text())
        turns = data['turns']
        self.assertEqual(60, len(turns))
        self.assertEqual(60, len({turn['id'] for turn in turns}))
        self.assertEqual(30, sum(t['sourceLanguage'] == 'nl' for t in turns))
        self.assertTrue(all(t['recording'] is None and t['review'] is None for t in turns))

class ProbeBoundaryTests(unittest.TestCase):
    def test_diagnostics_drop_generated_content_unless_explicitly_retained(self):
        probe = load('probe', 'scripts/benchmarks/live_translation/probe.py')
        event = {'type':'response.done','response':{'id':'r1','status':'completed','output':[{'text':'private speech'}],'usage':{'output_tokens':2}}}
        safe = probe.done_diagnostics(event, False)
        self.assertNotIn('private speech', str(safe))
        self.assertEqual('completed', safe['response']['status'])
        self.assertEqual(event, probe.done_diagnostics(event, True))

    def test_pcm_validation_rejects_nan_and_preserves_real_signal(self):
        import struct
        probe = load('probe', 'scripts/benchmarks/live_translation/probe.py')
        signal = probe.signal_summary(struct.pack('<hhh', 0, 16384, -16384), 'pcm16')
        self.assertEqual(3, signal['sample_count'])
        self.assertEqual(0.5, signal['peak'])
        with self.assertRaisesRegex(ValueError, 'finite'):
            probe.signal_summary(struct.pack('<f', float('nan')), 'float32')

    def test_negotiates_wire_rates(self):
        probe = load('probe', 'scripts/benchmarks/live_translation/probe.py')
        session = {'audio': {'input': {'format': {'type': 'audio/pcm', 'rate': 16000}}, 'output': {'format': {'type': 'audio/pcm', 'rate': 24000}}}}
        self.assertEqual((16000, 24000), probe.session_rates(session))
        with self.assertRaises(ValueError):
            probe.session_rates({})

    def test_never_reports_latency_percentiles_from_single_probe(self):
        probe = load('probe', 'scripts/benchmarks/live_translation/probe.py')
        result = probe.latency_summary([1.5])
        self.assertEqual(1, result['count'])
        self.assertNotIn('p95', result)
        self.assertIn('p95', probe.latency_summary(list(range(100))))

if __name__ == '__main__':
    unittest.main()
