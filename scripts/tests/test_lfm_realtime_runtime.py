"""Integrity and benchmark boundary regressions; no model load."""
import importlib.util
import pathlib
import tempfile
import unittest
from unittest.mock import AsyncMock, patch
from contextlib import redirect_stdout, redirect_stderr
import io
import json
from types import SimpleNamespace

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
    def test_production_guard_rejection_is_failed_probe_and_never_calls_tts(self):
        probe = load('probe_guard_rejection', 'scripts/benchmarks/live_translation/probe.py')
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / 'result.json'
            arguments = ['probe', '--key-file', '/unused/key', '--mode', 'two-pass', '--source-language', 'en',
                         '--contract', '/unused/contract', '--retain-content', '--output', str(output)]
            with patch('sys.argv', arguments), patch.object(probe, 'websocket_probe', AsyncMock(return_value={'text': 'wrong target'})), \
                 patch.object(probe, 'output_guard', return_value={'accepted': False, 'qualified': False}), \
                 patch.object(probe, 'tts_probe') as speech, redirect_stdout(io.StringIO()):
                with self.assertRaises(SystemExit) as stopped:
                    probe.main()
                self.assertEqual(stopped.exception.code, 1)
                speech.assert_not_called()
            report = json.loads(output.read_text())
            self.assertEqual(report['failure'], 'TranslationOutputRejected')
            self.assertIn('unrun', report['two_pass_tts'])

    def test_fixed_two_pass_speech_uses_actual_translation_target(self):
        probe = load('probe_fixed_target', 'scripts/benchmarks/live_translation/probe.py')
        with tempfile.TemporaryDirectory() as directory:
            arguments = ['probe', '--key-file', '/unused/key', '--mode', 'two-pass', '--source-language', 'en',
                         '--retain-content', '--output', str(pathlib.Path(directory) / 'result.json')]
            with patch('sys.argv', arguments), patch.object(probe, 'websocket_probe', AsyncMock(return_value={'text': 'Nederlandse tekst'})), \
                 patch.object(probe, 'tts_probe', return_value={'audio_bytes': 4}) as speech, redirect_stdout(io.StringIO()):
                probe.main()
            self.assertEqual(speech.call_args.args[0].lang, 'nl')

    def test_conflicting_two_pass_speech_target_is_rejected_before_transport(self):
        probe = load('probe_conflicting_target', 'scripts/benchmarks/live_translation/probe.py')
        with tempfile.TemporaryDirectory() as directory:
            arguments = ['probe', '--key-file', '/unused/key', '--mode', 'two-pass', '--source-language', 'en', '--lang', 'en',
                         '--retain-content', '--output', str(pathlib.Path(directory) / 'result.json')]
            with patch('sys.argv', arguments), patch.object(probe, 'websocket_probe', AsyncMock(return_value={} )) as transport, redirect_stderr(io.StringIO()), redirect_stdout(io.StringIO()):
                with self.assertRaises(SystemExit) as stopped:
                    probe.main()
                self.assertEqual(stopped.exception.code, 2)
                transport.assert_not_called()

    def test_production_guard_requires_explicit_boolean_result(self):
        probe = load('probe_invalid_guard', 'scripts/benchmarks/live_translation/probe.py')
        args = SimpleNamespace(contract=pathlib.Path('/unused/driver'), source_language='en')
        for response in ['{}', '{"accepted": "true", "qualified": false}', '{"accepted": true, "qualified": true}']:
            with patch.object(probe.subprocess, 'check_output', return_value=response):
                with self.assertRaisesRegex(ValueError, 'guard'):
                    probe.output_guard(args, 'text')

    def test_managed_probe_rejects_unknown_pressure_telemetry(self):
        probe = load('managed_probe_unknown_pressure', 'scripts/benchmarks/live_translation/managed_cascade_probe.py')
        for value in ['0', '3', '999']:
            with patch.object(probe.subprocess, 'check_output', return_value=value):
                with self.assertRaisesRegex(ValueError, 'pressure'):
                    probe.pressure()

    def test_final_telemetry_failure_preserves_failed_report_and_process_receipt(self):
        probe = load('managed_probe_final_telemetry', 'scripts/benchmarks/live_translation/managed_cascade_probe.py')
        report = {'status': 'completed', 'owned_processes_stopped': True, 'turns': [{'source': 'nl'}]}
        with patch.object(probe, 'pressure', side_effect=ValueError('unavailable')), patch.object(probe, 'swap', return_value=12.0):
            probe.final_telemetry(report)
        self.assertEqual(report['status'], 'failed')
        self.assertIsNone(report['final_pressure'])
        self.assertEqual(report['final_swap_mib'], 12.0)
        self.assertTrue(report['owned_processes_stopped'])
        self.assertEqual(report['turns'], [{'source': 'nl'}])
        self.assertEqual(report['telemetry_errors'][0]['field'], 'final_pressure')

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
