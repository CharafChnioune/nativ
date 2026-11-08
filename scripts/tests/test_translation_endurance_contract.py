"""Endurance contract and telemetry regressions; no helper/model or device access."""
import asyncio
import base64
from contextlib import redirect_stdout
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import struct
import sys
import tempfile
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import AsyncMock, patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('endurance_contract', ROOT / 'scripts/benchmarks/live_translation/endurance.py')
ENDURANCE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ENDURANCE)


def sample():
    return {'pressure_level': 1, 'swap_used_mib': 10.0, 'helper_rss_bytes': 0}


class Socket:
    def __init__(self, audio):
        self.closed = False
        self.sent = []
        self.events = [
            {'type': 'session.created', 'session': {'audio': {'input': {'format': {'type': 'audio/pcm', 'rate': 16000}}, 'output': {'format': {'type': 'audio/pcm', 'rate': 24000}}}}},
            {'type': 'session.updated'},
            {'type': 'response.output_text.delta', 'delta': 'A translation.'},
        ]
        if audio:
            self.events.append({'type': 'response.output_audio.delta', 'delta': base64.b64encode(struct.pack('<h', 16384)).decode()})
        self.events.append({'type': 'response.done', 'response': {'status': 'completed'}})

    async def __aenter__(self): return self
    async def __aexit__(self, *_): self.closed = True
    async def recv(self): return json.dumps(self.events.pop(0))
    async def send(self, value): self.sent.append(json.loads(value))


class EnduranceContractTests(unittest.TestCase):
    def run_turn(self, directory, mode, accepted=True, contract=True):
        driver = Path(directory) / 'contract'
        driver.write_bytes(b'production-contract-fixture')
        socket = Socket(audio=mode == 'direct')
        helper = SimpleNamespace(url='http://127.0.0.1:1234', key='test', guard=SimpleNamespace(check=lambda: None))
        args = SimpleNamespace(fixtures_pcm={'nl': b''}, turn_timeout=1, contract=driver if contract else None)
        client = ModuleType('websockets.asyncio.client')
        client.connect = lambda *_, **__: socket
        calls = []
        def driver_call(argv, **kwargs):
            calls.append(argv[1:])
            if argv[1] == 'prompt': return json.dumps({'speech': 'production speech instructions', 'text': 'production text instructions'})
            self.assertTrue(socket.closed, 'Output guard must run after socket teardown')
            self.assertEqual({'translation': 'A translation.'}, json.loads(kwargs['input']))
            return json.dumps({'accepted': accepted, 'qualified': False})
        def speech(_, text, language, commit, timeout, result):
            self.assertTrue(socket.closed)
            result.update(audio={'sample_count': 1}, first_audio_seconds=.1, done_seconds=.2)
        with patch.dict(sys.modules, {'websockets.asyncio.client': client}), \
             patch.object(ENDURANCE.subprocess, 'check_output', side_effect=driver_call), \
             patch.object(ENDURANCE, 'tts', side_effect=speech) as tts:
            result = asyncio.run(ENDURANCE.turn(helper, args, 'nl', mode))
        return result, socket, calls, tts.call_count, driver

    def test_rejected_two_pass_target_never_starts_tts_and_uses_production_text_prompt(self):
        with tempfile.TemporaryDirectory() as directory:
            result, socket, calls, speech_count, driver = self.run_turn(directory, 'two-pass', accepted=False)
            self.assertEqual('error', result['status'])
            self.assertEqual(0, speech_count)
            self.assertEqual([['prompt', 'nl', 'en'], ['validate-output', 'nl', 'en']], calls)
            self.assertEqual('production text instructions', socket.sent[0]['session']['instructions'])
            self.assertEqual(hashlib.sha256(driver.read_bytes()).hexdigest(), result['contract_sha256'])
            self.assertFalse(result['output_guard']['accepted'])
            self.assertEqual('before-two-pass-tts', result['output_guard_phase'])
            self.assertFalse(result['tts_started'])

    def test_accepted_two_pass_output_is_validated_before_speech(self):
        with tempfile.TemporaryDirectory() as directory:
            result, _, calls, speech_count, _ = self.run_turn(directory, 'two-pass')
        self.assertEqual('ok', result['status'])
        self.assertEqual(1, speech_count)
        self.assertEqual('validate-output', calls[-1][0])
        self.assertGreaterEqual(result['output_guard_seconds'], 0)
        self.assertTrue(result['tts_started'])

    def test_direct_rejection_keeps_received_pcm_evidence_and_labels_posthoc_limit(self):
        with tempfile.TemporaryDirectory() as directory:
            result, socket, _, speech_count, _ = self.run_turn(directory, 'direct', accepted=False)
        self.assertEqual('error', result['status'])
        self.assertEqual(0, speech_count)
        self.assertEqual('production speech instructions', socket.sent[0]['session']['instructions'])
        self.assertEqual(1, result['audio']['sample_count'])
        self.assertEqual('after-direct-audio-received', result['output_guard_phase'])
        self.assertIn('cannot undo', result['output_guard_limit'])
        self.assertIn('first_audio_seconds', result)

    def test_legacy_default_remains_available_without_driver_invocation(self):
        with tempfile.TemporaryDirectory() as directory:
            result, socket, calls, speech_count, _ = self.run_turn(directory, 'two-pass', contract=False)
        self.assertEqual('ok', result['status'])
        self.assertEqual([], calls)
        self.assertEqual(1, speech_count)
        self.assertEqual(ENDURANCE.interpreter_prompt('nl', 'two-pass'), socket.sent[0]['session']['instructions'])
        self.assertIn('unrun', result['output_guard'])

    def test_malformed_or_qualification_claiming_guard_is_rejected(self):
        for payload in ({}, {'accepted': 'true', 'qualified': False}, {'accepted': True, 'qualified': True}):
            with self.subTest(payload=payload), patch.object(ENDURANCE.subprocess, 'check_output', return_value=json.dumps(payload)):
                with self.assertRaisesRegex(ValueError, 'guard'):
                    ENDURANCE.output_guard(Path('/unused'), 'nl', 'Text')


class EnduranceTelemetryTests(unittest.TestCase):
    def test_unknown_or_missing_pressure_and_invalid_swap_fail_closed(self):
        for value in (0, 3, 999, None, True):
            with self.subTest(pressure=value):
                with self.assertRaisesRegex(ValueError, 'telemetry'):
                    ENDURANCE.memory_violation({'pressure_level': value, 'swap_used_mib': 10}, 10, 2048)
        for value in (None, -1, float('nan'), float('inf'), True):
            with self.subTest(swap=value):
                with self.assertRaisesRegex(ValueError, 'telemetry'):
                    ENDURANCE.memory_violation({'pressure_level': 1, 'swap_used_mib': value}, 10, 2048)

    def test_baseline_telemetry_failure_preserves_final_json_without_launch(self):
        self.assert_preserved_main_report(initial_failure=True)

    def test_final_telemetry_gap_preserves_turns_and_owned_process_receipt(self):
        self.assert_preserved_main_report(initial_failure=False)

    def test_optional_contract_digest_and_protocol_are_retained_in_failed_run(self):
        self.assert_preserved_main_report(initial_failure=True, use_contract=True)

    def test_valid_final_sample_does_not_erase_initial_telemetry_gap(self):
        with patch.object(ENDURANCE, 'system_sample', side_effect=[ValueError('missing baseline'), sample()]):
            guard = ENDURANCE.Guard(Path('/unused'), 2048)
            final = guard.final_sample()
        self.assertEqual(1, final['pressure_level'])
        self.assertIsNone(guard.baseline)
        self.assertIsNone(guard.summary()['baseline_swap_mib'])
        self.assertIn('baseline', guard.abort)
        self.assertEqual('baseline', guard.telemetry_errors[0]['phase'])

    def assert_preserved_main_report(self, initial_failure, use_contract=False):
        class Helper:
            command = ['unused']; ready_seconds = .01
            def __init__(self, args, guard):
                self.process = SimpleNamespace(returncode=None, poll=lambda: self.process.returncode)
                self.guard = guard
                guard.process = self.process
            def start(self): pass
            def close(self):
                self.process.returncode = 0
                self.guard.process = None
                return .01
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'evidence'
            argv = ['endurance', '--output', str(output), '--duration', '0', '--min-turns', '1', '--cold-starts', '0', '--cancel-turns', '0', '--concurrent-activity', 'unit fixture']
            if use_contract:
                driver = Path(directory) / 'contract'
                driver.write_bytes(b'fixture driver')
                driver.chmod(0o700)
                argv += ['--contract', str(driver)]
            telemetry = ValueError('missing') if initial_failure else [sample(), ValueError('final unavailable')]
            completed = {'mode': 'direct', 'source': 'nl', 'status': 'ok', 'text': 'Synthetic result retained.'}
            with patch.object(sys, 'argv', argv), patch.object(ENDURANCE, 'fixture', return_value=b'\0\0'), \
                 patch.object(ENDURANCE, 'integrity', return_value={}), patch.object(ENDURANCE, 'sha256', return_value='a'*64), \
                 patch.object(ENDURANCE, 'command', return_value='1'), patch.object(ENDURANCE.importlib.metadata, 'version', return_value='test'), \
                 patch.object(ENDURANCE, 'system_sample', side_effect=telemetry), \
                 patch.object(ENDURANCE, 'turn', AsyncMock(return_value=completed)), \
                 patch.object(ENDURANCE.subprocess, 'check_output', return_value=json.dumps({'text': 'Text prompt', 'speech': 'Speech prompt'})), \
                 patch.object(ENDURANCE.threading.Thread, 'start'), patch.object(ENDURANCE, 'Helper', wraps=Helper) as helper, \
                 patch.object(ENDURANCE.signal, 'signal'), redirect_stdout(io.StringIO()):
                status = ENDURANCE.main()
            report = json.loads((output / 'summary.json').read_text())
            self.assertEqual(1, status)
            self.assertEqual('aborted', report['status'])
            self.assertTrue(report['telemetry_errors'])
            self.assertIsNone(report['final_memory'])
            if initial_failure:
                self.assertEqual([], report['turns'])
                helper.assert_not_called()
                self.assertEqual(0, report['memory_summary']['samples'])
            else:
                self.assertEqual([completed], report['turns'])
                self.assertEqual(0, report['owned_helper_exit_code'])
                self.assertEqual(1, report['memory_summary']['samples'])
                self.assertTrue(report['owned_helper_stopped'])
            if use_contract:
                self.assertEqual('a'*64, report['identity']['contract_sha256'])
                self.assertEqual('production-contract', report['protocol']['prompt_source'])
                self.assertIn('cannot undo', report['protocol']['output_validation'])
                self.assertIn('network receipt', report['protocol']['timing_semantics'])


if __name__ == '__main__':
    unittest.main()
