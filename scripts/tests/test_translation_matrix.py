"""Matrix fixture identity, failure aggregation and owned resource guards; no models."""
from contextlib import redirect_stdout
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import wave

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('translation_matrix', ROOT / 'scripts/benchmarks/live_translation/run_matrix.py')
MATRIX = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MATRIX)


def make_wav(path, frames=160):
    with wave.open(str(path), 'wb') as audio:
        audio.setnchannels(1); audio.setsampwidth(2); audio.setframerate(16000)
        audio.writeframes(b'\1\0' * frames)


def memory_sample(level=1):
    return {'pressure_level': level, 'swap_used_mib': 10.0, 'helper_rss_bytes': 0}


class OwnedProcess:
    pid = 12345
    def __init__(self): self.returncode = None; self.terminations = 0; self.kills = 0
    def poll(self): return self.returncode
    def terminate(self): self.terminations += 1
    def wait(self, timeout=None): self.returncode = 0; return 0
    def kill(self): self.kills += 1; self.returncode = -9


class TranslationMatrixTests(unittest.TestCase):
    def fixtures(self, root):
        root.mkdir()
        for source in ('nl', 'en'): make_wav(root / f'synthetic-{source}.wav')

    def test_reused_fixtures_are_identical_hashed_and_do_not_invoke_say(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); source = root/'source'; output = root/'out'; output.mkdir(); self.fixtures(source)
            with patch.object(MATRIX.subprocess, 'run') as command:
                prepared = MATRIX.prepare_fixtures(output, source)
            command.assert_not_called()
            for language in ('nl', 'en'):
                original = source/f'synthetic-{language}.wav'; copied = output/original.name
                self.assertEqual(original.read_bytes(), copied.read_bytes())
                self.assertEqual(hashlib.sha256(original.read_bytes()).hexdigest(), prepared[language]['sha256'])
                self.assertEqual(str(original.resolve()), prepared[language]['original_path'])
                self.assertEqual('reused-existing', prepared[language]['origin'])
            (source/'synthetic-en.wav').write_bytes(b'changed after snapshot')
            self.assertGreater((output/'synthetic-en.wav').stat().st_size, 100)

    def test_invalid_or_oversized_fixture_fails_before_probe(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); source = root/'source'; output = root/'out'; output.mkdir(); self.fixtures(source)
            make_wav(source/'synthetic-nl.wav', frames=13*16000)
            with self.assertRaisesRegex(ValueError, '12 second'):
                MATRIX.prepare_fixtures(output, source)

    def test_legacy_fixture_generation_remains_explicit_and_hashed(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            def generate(argv, **kwargs):
                if argv[0] == 'afconvert': make_wav(Path(argv[-1]))
            with patch.object(MATRIX.subprocess, 'run', side_effect=generate) as command:
                prepared = MATRIX.prepare_fixtures(output)
            self.assertEqual(['say', 'afconvert', 'say', 'afconvert'], [call.args[0][0] for call in command.call_args_list])
            self.assertTrue(all(value['origin'] == 'legacy-say-generated' for value in prepared.values()))

    def test_nested_probe_errors_and_guard_rejections_are_failures(self):
        for result in ({'failure': 'transport'}, {'errors': ['http error']},
                       {'tts': {'errors': [{'http_status': 500}]}},
                       {'output_guard': {'accepted': False, 'qualified': False}},
                       {'mode': 'direct', 'audio_bytes': 0},
                       {'response_done': {'response': {'status': 'incomplete'}}}):
            with self.subTest(result=result): self.assertTrue(MATRIX.probe_failed(result))
        self.assertFalse(MATRIX.probe_failed({'errors': [], 'output_guard': {'accepted': True, 'qualified': False}}))
        self.assertFalse(MATRIX.probe_failed({'mode': 'cancel', 'response_done': {'response': {'status': 'cancelled'}}}))

    def run_main(self, root, telemetry, outcome=None):
        fixtures = root/'fixtures'; self.fixtures(fixtures); output = root/'report'; child = OwnedProcess()
        arguments = ['matrix', '--fixtures', str(fixtures), '--output', str(output)]
        def run_probes(args, report, process, keyfile, guard, begin):
            if outcome: outcome(report, process, guard)
            else: report['probes'].append({'mode': 'direct', 'audio_bytes': 2, 'errors': []})
        with patch('sys.argv', arguments), patch.object(MATRIX.endurance, 'system_sample', side_effect=telemetry), \
             patch.object(MATRIX.endurance.threading.Thread, 'start'), patch.object(MATRIX.subprocess, 'run'), \
             patch.object(MATRIX.subprocess, 'Popen', return_value=child) as launched, \
             patch.object(MATRIX, 'run_probes', side_effect=run_probes), redirect_stdout(io.StringIO()):
            status = MATRIX.main()
        return status, json.loads((output/'summary.json').read_text()), child, launched.call_count, output

    def test_non_normal_baseline_prevents_helper_and_records_failure(self):
        for level in (2, 4, 0):
            with self.subTest(level=level), tempfile.TemporaryDirectory() as directory:
                status, report, child, launches, output = self.run_main(Path(directory), [memory_sample(level), memory_sample(level)])
                self.assertEqual(1, status); self.assertEqual('failed', report['status'])
                self.assertEqual(0, launches); self.assertEqual(0, child.terminations)
                self.assertFalse((output/'.probe-key').exists())
                self.assertFalse(report['qualified'])

    def test_missing_baseline_telemetry_prevents_helper(self):
        with tempfile.TemporaryDirectory() as directory:
            status, report, _, launches, _ = self.run_main(Path(directory), [ValueError('missing'), memory_sample()])
        self.assertEqual(1, status); self.assertEqual(0, launches)
        self.assertTrue(report['telemetry_errors']); self.assertIsNone(report['memory_summary']['baseline_swap_mib'])

    def test_nested_failure_sets_nonzero_exit_and_preserves_own_process_receipt(self):
        def outcome(report, child, guard):
            report['probes'].append({'tts': {'errors': ['failed']}})
            guard.request_termination(child)
        with tempfile.TemporaryDirectory() as directory:
            status, report, child, launches, output = self.run_main(Path(directory), [memory_sample(), memory_sample()], outcome)
        self.assertEqual(1, status); self.assertEqual(1, launches)
        self.assertEqual(1, child.terminations, 'monitor/finally share idempotent termination ownership')
        self.assertEqual(1, report['failed_probe_count']); self.assertTrue(report['owned_child_stopped'])
        self.assertEqual(1024, report['max_swap_growth_mib']); self.assertEqual(2, report['memory_summary']['samples'])

    def test_final_telemetry_gap_keeps_probe_results_and_fails_run(self):
        with tempfile.TemporaryDirectory() as directory:
            status, report, child, _, _ = self.run_main(Path(directory), [memory_sample(), ValueError('final missing')])
        self.assertEqual(1, status); self.assertEqual(1, len(report['probes']))
        self.assertIsNone(report['final_memory']); self.assertTrue(report['owned_child_stopped'])
        self.assertEqual('final', report['telemetry_errors'][0]['phase'])

    def test_actual_guard_swap_growth_terminates_only_the_owned_child_once(self):
        def outcome(report, child, guard):
            report['probes'].append({'mode': 'direct', 'audio_bytes': 2})
            with patch.object(guard.done, 'wait', return_value=False):
                guard._sample()
        growing = {**memory_sample(), 'swap_used_mib': 1100.0}
        with tempfile.TemporaryDirectory() as directory:
            status, report, child, _, _ = self.run_main(Path(directory), [memory_sample(), growing, memory_sample()], outcome)
        self.assertEqual(1, status); self.assertIn('swap', report['memory_abort'])
        self.assertEqual(1090.0, report['memory_summary']['peak_swap_growth_mib'])
        self.assertEqual(1, child.terminations); self.assertTrue(report['owned_child_stopped'])

    def test_success_stays_explicitly_unqualified_and_cleans_key(self):
        with tempfile.TemporaryDirectory() as directory:
            status, report, child, _, output = self.run_main(Path(directory), [memory_sample(), memory_sample()])
            self.assertFalse((output/'.probe-key').exists())
        self.assertEqual(0, status); self.assertEqual('completed-technical-only-unqualified', report['status'])
        self.assertFalse(report['qualified']); self.assertEqual(0, report['failed_probe_count']); self.assertEqual(1, child.terminations)


if __name__ == '__main__': unittest.main()
