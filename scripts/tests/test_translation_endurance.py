"""Aggregation and guard regressions for the synthetic transport soak; no inference."""
import importlib.util
import math
from pathlib import Path
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('endurance', ROOT / 'scripts/benchmarks/live_translation/endurance.py')
ENDURANCE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ENDURANCE)


class EnduranceAggregationTests(unittest.TestCase):
    def test_nearest_rank_percentiles_require_one_hundred_valid_observations(self):
        result = ENDURANCE.distribution(list(range(1, 101)))
        self.assertEqual(100, result['count'])
        self.assertEqual(50.5, result['p50_seconds'])
        self.assertEqual(95, result['p95_seconds'])
        self.assertNotIn('p95_seconds', ENDURANCE.distribution([.8]))
        for bad in (float('nan'), float('inf'), -1):
            with self.assertRaises(ValueError):
                ENDURANCE.distribution([bad])

    def test_errors_and_cancellations_cannot_improve_success_latency(self):
        turns = [dict(mode='direct', source='nl', status='ok', first_audio_seconds=2, first_text_seconds=1),
                 dict(mode='direct', source='nl', status='error', first_audio_seconds=.1),
                 dict(mode='direct', source='nl', status='cancelled', first_audio_seconds=.2),
                 dict(mode='two-pass', source='en', status='ok', first_audio_seconds=5, first_text_seconds=3)]
        result = ENDURANCE.aggregate(turns)
        self.assertEqual(4, result['attempts'])
        self.assertEqual(2, result['successful_turns'])
        self.assertEqual(1, result['errors'])
        self.assertEqual(1, result['cancelled'])
        self.assertEqual(2, result['by_mode']['direct']['audio']['median_seconds'])
        self.assertEqual(5, result['by_mode']['two-pass']['audio']['median_seconds'])
        self.assertNotIn('audio', result)  # Never pool distinct modes.

    def test_incomplete_or_failed_run_is_never_pass(self):
        self.assertEqual('incomplete', ENDURANCE.run_outcome(99, 1800, 10, 0, None, 100, 1800, 10))
        self.assertEqual('incomplete', ENDURANCE.run_outcome(100, 1799, 10, 0, None, 100, 1800, 10))
        self.assertEqual('failed', ENDURANCE.run_outcome(100, 1800, 10, 1, None, 100, 1800, 10))
        self.assertEqual('aborted', ENDURANCE.run_outcome(100, 1800, 10, 0, 'critical pressure', 100, 1800, 10))
        self.assertEqual('technical-run-complete', ENDURANCE.run_outcome(100, 1800, 10, 0, None, 100, 1800, 10))


class EnduranceGuardTests(unittest.TestCase):
    def test_guard_then_finally_signals_owned_helper_only_once(self):
        class Process:
            stderr = None
            returncode = None
            signals = 0
            def poll(self): return self.returncode
            def terminate(self): self.signals += 1
            def wait(self, timeout): self.returncode = 0
        sample = {'pressure_level':1, 'swap_used_mib':0, 'helper_rss_bytes':0}
        with mock.patch.object(ENDURANCE, 'system_sample', return_value=sample):
            guard = ENDURANCE.Guard(Path('/unused'), 2048)
        helper = ENDURANCE.Helper(None, guard)
        process = Process(); unrelated = Process()
        helper.process = guard.process = process
        guard.request_termination(process)
        guard.request_termination(process)
        guard.request_termination(unrelated)
        helper.close()
        self.assertEqual(1, process.signals)
        self.assertEqual(0, unrelated.signals)
        self.assertEqual(0, process.returncode)

    def test_system_swap_and_pressure_are_not_free_percentage(self):
        self.assertEqual(18454.75, ENDURANCE.parse_swap_mib('total = 19456.00M  used = 18454.75M  free = 1001.25M (encrypted)'))
        self.assertIsNone(ENDURANCE.memory_violation({'pressure_level':1,'swap_used_mib':18454.75}, 18454.75, 2048))
        self.assertIn('critical', ENDURANCE.memory_violation({'pressure_level':4,'swap_used_mib':18454.75}, 18454.75, 2048))
        self.assertIn('swap', ENDURANCE.memory_violation({'pressure_level':1,'swap_used_mib':20503}, 18454.75, 2048))
        with self.assertRaises(ValueError):
            ENDURANCE.parse_swap_mib('unknown')

    def test_system_commands_run_in_the_c_locale(self):
        # Under LANG=nl_NL sysctl prints "used = 619,69M", which parse_swap_mib cannot read.
        from unittest.mock import patch
        with patch.object(ENDURANCE.subprocess, 'check_output', return_value='x\n') as run:
            ENDURANCE.command(['sysctl', '-n', 'vm.swapusage'])
        self.assertEqual('C', run.call_args.kwargs['env']['LC_ALL'])

    def test_partial_port_is_not_accepted_before_delimiter(self):
        self.assertIsNone(ENDURANCE.listening_port('listening on http://127.0.0.1:4'))
        self.assertEqual(41234, ENDURANCE.listening_port('listening on http://127.0.0.1:41234\n'))
        self.assertIsNone(ENDURANCE.listening_port('listening on http://0.0.0.0:41234\n'))
        self.assertIsNone(ENDURANCE.listening_port('listening on http://127.0.0.1:99999\n'))

    def test_float_pcm_split_samples_are_buffered_and_nonfinite_rejected(self):
        import struct
        meter = ENDURANCE.PCMMeter('float32', 24000)
        raw = struct.pack('<fff', 0, .5, -.5)
        meter.add(raw[:3]); meter.add(raw[3:])
        signal = meter.finish()
        self.assertEqual(3, signal['sample_count'])
        self.assertEqual(.5, signal['peak'])
        self.assertAlmostEqual(math.sqrt(.5 / 3), signal['rms'])
        with self.assertRaisesRegex(ValueError, 'finite'):
            meter.add(struct.pack('<f', float('nan')))
        partial = ENDURANCE.PCMMeter('float32', 24000); partial.add(b'\x00')
        with self.assertRaisesRegex(ValueError, 'unaligned'):
            partial.finish()

    def test_pcm_arrival_does_not_imply_non_silent_samples(self):
        import struct
        meter = ENDURANCE.PCMMeter('pcm16', 24000)
        self.assertEqual(0, meter.add(b'\x00' * 2880))
        self.assertEqual(.5, meter.add(struct.pack('<h', 16384)))


if __name__ == '__main__':
    unittest.main()
