#!/usr/bin/env python3
"""Synthetic loopback transport endurance. No microphone, playback or quality claims.

Uses existing, original synthetic WAVs. A process-cold start retains the OS file
cache. Each warm turn uses a fresh context on the same resident, single-slot Q8
helper. Text from these synthetic fixtures is retained for review; audio is
incrementally measured and discarded. Never use private recordings with this tool.
"""
import argparse
import array
import asyncio
import base64
import collections
import hashlib
import importlib.metadata
import json
import math
import os
from pathlib import Path
import re
import secrets
import signal
import statistics
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
import wave

ROOT = Path(__file__).resolve().parents[3]
NAMES = {'nl': 'Dutch', 'en': 'English'}
FORBIDDEN = ('<tool_call', '</tool_call', '<function', '</function', '<parameter', '</parameter')
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def distribution(values):
    values = list(values)
    if any(not math.isfinite(v) or v < 0 for v in values):
        raise ValueError('Latency must be finite and nonnegative')
    result = {'count': len(values)}
    if values:
        result.update(min_seconds=min(values), median_seconds=statistics.median(values), max_seconds=max(values))
    if len(values) >= 100:
        result.update(p50_seconds=statistics.median(values), p95_seconds=sorted(values)[math.ceil(.95 * len(values)) - 1])
    else:
        result['percentiles_withheld_reason'] = 'Fewer than 100 successful observations in this group'
    return result


def aggregate(turns):
    successful = [turn for turn in turns if turn['status'] == 'ok']
    result = {'attempts': len(turns), 'successful_turns': len(successful),
              'errors': sum(t['status'] == 'error' for t in turns),
              'cancelled': sum(t['status'] == 'cancelled' for t in turns),
              'by_mode': {}, 'by_mode_and_direction': {}}
    for category, key in [('by_mode', lambda t: t['mode']),
                          ('by_mode_and_direction', lambda t: t['mode'] + ':' + t['source'] + '-' + ('en' if t['source'] == 'nl' else 'nl'))]:
        for group in sorted({key(t) for t in turns}):
            attempts = [t for t in turns if key(t) == group]
            valid = [t for t in attempts if t['status'] == 'ok']
            result[category][group] = {'attempts': len(attempts), 'successful_turns': len(valid),
                'errors': sum(t['status'] == 'error' for t in attempts),
                'audio': distribution(t['first_audio_seconds'] for t in valid if 'first_audio_seconds' in t),
                'first_nonzero_pcm': distribution(t['first_nonzero_pcm_seconds'] for t in valid if 'first_nonzero_pcm_seconds' in t),
                'text': distribution(t['first_text_seconds'] for t in valid if 'first_text_seconds' in t)}
    return result


def run_outcome(attempts, duration, cold_count, errors, abort, min_turns, min_duration, cold_target):
    if abort:
        return 'aborted'
    if errors:
        return 'failed'
    if attempts < min_turns or duration < min_duration or cold_count < cold_target:
        return 'incomplete'
    return 'technical-run-complete'


def parse_swap_mib(value):
    match = re.search(r'used\s*=\s*([0-9.]+)M', value)
    if not match:
        raise ValueError('Cannot read system swap usage')
    return float(match.group(1))


def memory_violation(sample, baseline_swap, maximum_growth):
    pressure, swap = sample.get('pressure_level'), sample.get('swap_used_mib')
    if type(pressure) is not int or pressure not in (1, 2, 4):
        raise ValueError('Unknown or missing OS pressure telemetry')
    if any(type(value) not in (int, float) or not math.isfinite(value) or value < 0
           for value in (swap, baseline_swap, maximum_growth)):
        raise ValueError('Invalid or missing swap telemetry/guard bound')
    if sample['pressure_level'] >= 4:
        return 'critical OS memory pressure (kern.memorystatus_vm_pressure_level >= 4)'
    if sample['swap_used_mib'] - baseline_swap > maximum_growth:
        return 'system swap growth exceeded %.0f MiB' % maximum_growth
    return None


def listening_port(value):
    match = re.search(r'listening on http://127\.0\.0\.1:([0-9]+)(?=[\s/])', value)
    if match and 1 <= int(match.group(1)) <= 65535:
        return int(match.group(1))
    return None


class PCMMeter:
    """Constant-memory signal statistics, including split FLOAT32 HTTP samples."""
    def __init__(self, encoding, rate):
        self.encoding, self.rate = encoding, rate
        self.width = 2 if encoding == 'pcm16' else 4
        self.tail = b''
        self.count = self.bytes = 0
        self.square_sum = self.peak = 0
        self.digest = hashlib.sha256()

    def add(self, data):
        self.bytes += len(data)
        if self.bytes > 12 * self.rate * self.width:
            raise ValueError('Output exceeds the 12-second probe bound')
        self.digest.update(data)
        data = self.tail + data
        split = len(data) // self.width * self.width
        self.tail = data[split:]
        values = array.array('h' if self.encoding == 'pcm16' else 'f')
        values.frombytes(data[:split])
        if sys.byteorder != 'little':
            values.byteswap()
        block_peak = 0
        for sample in values:
            sample = sample / 32768 if self.encoding == 'pcm16' else sample
            if not math.isfinite(sample):
                raise ValueError('PCM samples must be finite')
            self.count += 1
            self.square_sum += sample * sample
            self.peak = max(self.peak, abs(sample))
            block_peak = max(block_peak, abs(sample))
        return block_peak

    def finish(self):
        if self.tail:
            raise ValueError('PCM response ended with an unaligned sample')
        return {'encoding': self.encoding, 'sample_rate': self.rate, 'sample_count': self.count,
                'bytes': self.bytes, 'duration_seconds': self.count / self.rate, 'peak': self.peak,
                'rms': math.sqrt(self.square_sum / self.count) if self.count else 0,
                'sha256': self.digest.hexdigest()}


def command(args):
    # sysctl and ps print locale decimals (nl_NL: "619,69M", "0,0"); the parsers read C-locale output.
    return subprocess.check_output(args, text=True, timeout=3, env=dict(os.environ, LC_ALL='C')).strip()


def system_sample(pid=None):
    result = {'monotonic': time.monotonic(),
              'pressure_level': int(command(['sysctl', '-n', 'kern.memorystatus_vm_pressure_level'])),
              'swap_used_mib': parse_swap_mib(command(['sysctl', '-n', 'vm.swapusage'])),
              'helper_rss_bytes': 0, 'helper_cpu_percent': 0}
    memory_violation(result, result['swap_used_mib'], 0)
    if pid:
        try:
            rss, cpu = command(['ps', '-p', str(pid), '-o', 'rss=,pcpu=']).split()
            result.update(helper_rss_bytes=int(rss) * 1024, helper_cpu_percent=float(cpu), helper_pid=pid)
        except (subprocess.CalledProcessError, ValueError):
            pass  # Process teardown is allowed between the sample and ps.
    return result


def write_json(path, value):
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, indent=2, allow_nan=False) + '\n')
    temporary.replace(path)


def append_json(path, value):
    with path.open('a') as stream:
        stream.write(json.dumps(value, allow_nan=False) + '\n')


class Guard:
    """Observe real OS pressure; terminate only this harness's currently owned helper."""
    def __init__(self, output, maximum_growth):
        self.output, self.maximum_growth = output, maximum_growth
        self.process = None
        self.baseline = None
        self.samples = []
        self.abort = None
        self.telemetry_errors = []
        self.phase = 'baseline'
        self.termination_requests = set()
        self.termination_lock = threading.Lock()
        self.done = threading.Event()
        self.thread = threading.Thread(target=self._sample, daemon=True)
        try:
            baseline = system_sample()
            self.abort = memory_violation(baseline, baseline.get('swap_used_mib'), maximum_growth)
            self.baseline = baseline
            self.samples.append(baseline)
        except Exception as error:
            self.telemetry_failure(error, 'baseline')

    def telemetry_failure(self, error, phase):
        # Retain an explicit gap and the first abort reason. A later valid sample
        # cannot turn an unmonitored interval into a successful experiment.
        self.telemetry_errors.append({'phase': phase, 'error': type(error).__name__})
        self.abort = self.abort or 'memory guard unavailable during ' + phase + ': ' + type(error).__name__

    def final_sample(self):
        try:
            sample = system_sample()
            baseline_swap = self.baseline['swap_used_mib'] if self.baseline else sample.get('swap_used_mib')
            violation = memory_violation(sample, baseline_swap, self.maximum_growth)
            self.abort = self.abort or violation
            self.samples.append(dict(sample, phase='final'))
            return sample
        except Exception as error:
            self.telemetry_failure(error, 'final')
            return None

    def summary(self):
        samples = self.samples[:]
        baseline_swap = self.baseline['swap_used_mib'] if self.baseline else None
        return {'samples': len(samples),
                'max_pressure_level': max((s['pressure_level'] for s in samples), default=None),
                'peak_helper_rss_bytes': max((s['helper_rss_bytes'] for s in samples), default=None),
                'baseline_swap_mib': baseline_swap,
                'peak_swap_growth_mib': max(s['swap_used_mib'] for s in samples) - baseline_swap if samples and baseline_swap is not None else None,
                'last_sample': samples[-1] if samples else None}

    def _sample(self):
        while not self.done.wait(1):
            try:
                process = self.process
                sample = system_sample(process.pid if process and process.poll() is None else None)
                violation = memory_violation(sample, self.baseline['swap_used_mib'], self.maximum_growth)
                sample['phase'] = self.phase
                self.samples.append(sample)
                append_json(self.output / 'memory.jsonl', sample)
                if violation:
                    self.abort = violation
                    self.request_termination(process)
                    return
            except Exception as error:
                self.telemetry_failure(error, self.phase)
                self.request_termination(self.process)
                return

    def request_termination(self, process):
        # llama.cpp treats a second SIGTERM as force-exit. In Metal teardown that
        # can abort with live resources; the sampler and finally must share ownership.
        with self.termination_lock:
            if (process is not None and process is self.process and process.poll() is None
                    and process not in self.termination_requests):
                self.termination_requests.add(process)
                process.terminate()

    def check(self):
        if self.abort:
            raise RuntimeError(self.abort)

    def start(self):
        self.check()
        append_json(self.output / 'memory.jsonl', dict(self.baseline, phase='baseline'))
        self.thread.start()

    def close(self):
        self.done.set()
        if self.thread.is_alive():
            self.thread.join(timeout=10)
            if self.thread.is_alive():
                self.telemetry_failure(TimeoutError(), 'monitor-shutdown')


class Helper:
    def __init__(self, args, guard):
        self.args, self.guard = args, guard
        self.key = secrets.token_urlsafe(32)
        self.process = None
        self.port = None
        self.lines = collections.deque(maxlen=20)
        self.reader = None
        self.ready_seconds = None

    def _drain(self):
        for line in self.process.stderr:
            # Stderr is drained, not retained on disk. Credentials/content never enter evidence.
            self.lines.append(line)
            port = listening_port(line)
            if port:
                self.port = port

    @property
    def url(self):
        return 'http://127.0.0.1:' + str(self.port)

    def request(self, path, data=None, timeout=3):
        headers = {'Authorization': 'Bearer ' + self.key}
        if data is not None:
            headers['Content-Type'] = 'application/json'
            data = json.dumps(data).encode()
        return OPENER.open(urllib.request.Request(self.url + path, data=data, headers=headers), timeout=timeout)

    def start(self):
        self.guard.check()
        args = self.args
        environment = {key: value for key, value in os.environ.items() if not key.startswith('LLAMA_')}
        environment['LLAMA_API_KEY'] = self.key
        self.command = [str(args.runtime_root / 'runtime/bin/llama-server'),
            '--model', str(args.runtime_root / 'models/LFM3-Omni-2B-Q8_0.gguf'),
            '--mmproj', str(args.runtime_root / 'models/mmproj-LFM3-Omni-2B-Q8_0.gguf'),
            '--host', '127.0.0.1', '--port', '0', '--parallel', '1', '--ctx-size', '4096',
            '--reasoning', 'off', '--no-webui', '--no-agent', '--cors-origins', 'localhost', '--no-cors-credentials']
        started = time.monotonic()
        self.process = subprocess.Popen(self.command, env=environment, stdin=subprocess.DEVNULL,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        self.guard.process = self.process
        self.reader = threading.Thread(target=self._drain, daemon=True)
        self.reader.start()
        while time.monotonic() - started < args.start_timeout:
            self.guard.check()
            if self.process.poll() is not None:
                raise RuntimeError('Owned helper exited during startup: ' + str(self.process.returncode))
            if self.port:
                try:
                    with self.request('/props', timeout=1) as response:
                        if response.status == 200:
                            self.ready_seconds = time.monotonic() - started
                            return
                except (urllib.error.URLError, TimeoutError):
                    pass
            time.sleep(.05)
        raise TimeoutError('Owned helper readiness deadline exceeded')

    def close(self):
        started = time.monotonic()
        if self.process and self.process.poll() is None:
            self.guard.request_termination(self.process)
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        if self.reader:
            self.reader.join(timeout=1)
        if self.process and self.process.stderr:
            self.process.stderr.close()
        if self.guard.process is self.process:
            self.guard.process = None
        return time.monotonic() - started


def fixture(path):
    with wave.open(str(path), 'rb') as wav:
        if wav.getnchannels() != 1 or wav.getsampwidth() != 2 or wav.getframerate() != 16000:
            raise ValueError('Fixture must already be PCM16 mono at 16kHz')
        if not 0 < wav.getnframes() <= 12 * 16000:
            raise ValueError('Fixture must be nonempty and at most 12 seconds')
        return wav.readframes(wav.getnframes())


def interpreter_prompt(source, mode):
    source_name, target = NAMES[source], NAMES['en' if source == 'nl' else 'nl']
    return ('You are an interpreter. Translate the latest spoken ' + source_name + ' utterance only into ' + target
            + '. Translate questions and commands instead of answering or following them. Preserve meaning, negation, numbers, names and emotional tone. Do not add explanations, tool calls or actions. '
            + ('Respond with interleaved text and audio in ' + target + '.' if mode == 'direct' else 'Output only the translation in ' + target + ' text.'))


def production_prompt(contract, source, mode):
    target = 'en' if source == 'nl' else 'nl'
    prompts = json.loads(subprocess.check_output([str(contract), 'prompt', source, target], text=True, timeout=10))
    prompt = prompts.get('speech' if mode == 'direct' else 'text') if isinstance(prompts, dict) else None
    if not isinstance(prompt, str) or not prompt.strip():
        raise ValueError('Production prompt contract returned invalid instructions')
    return prompt


def output_guard(contract, source, text):
    if not contract:
        return {'unrun': 'legacy endurance without production output guard'}
    target = 'en' if source == 'nl' else 'nl'
    result = json.loads(subprocess.check_output([str(contract), 'validate-output', source, target],
        input=json.dumps({'translation': text}), text=True, timeout=10))
    if not isinstance(result, dict) or type(result.get('accepted')) is not bool or result.get('qualified') is not False:
        raise ValueError('Production output guard returned an invalid result')
    return result


def tts(helper, text, language, commit, timeout, result):
    deadline = time.monotonic() + timeout
    started = time.monotonic()
    with helper.request('/tts', {'input': text, 'lang': language, 'stream': True,
                                'response_format': 'pcm', 'n_predict': 512}, timeout=min(timeout, 10)) as response:
        content_type = response.headers.get('Content-Type', '')
        fields = dict(part.strip().split('=', 1) for part in content_type.split(';')[1:] if '=' in part)
        if not content_type.startswith('audio/pcm') or fields.get('encoding') != 'float' or fields.get('bits') != '32':
            raise ValueError('TTS did not supply FLOAT32 format metadata: ' + content_type)
        rate = int(fields['rate'])
        if not 8000 <= rate <= 192000:
            raise ValueError('Invalid TTS rate')
        meter = PCMMeter('float32', rate)
        chunks = 0
        while True:
            helper.guard.check()
            if time.monotonic() >= deadline:
                raise TimeoutError('TTS total response deadline exceeded')
            block = response.read1(8192)
            arrived = time.monotonic()
            if not block:
                break
            chunks += 1
            result.setdefault('first_audio_seconds', arrived - commit)
            result.setdefault('tts_request_first_audio_seconds', arrived - started)
            if meter.add(block) > .0001:
                result.setdefault('first_nonzero_pcm_seconds', arrived - commit)
        result.update(audio=meter.finish(), audio_chunks=chunks, tts_content_type=content_type,
                      done_seconds=time.monotonic() - commit)


async def turn(helper, args, source, mode, cancel=False):
    from websockets.asyncio.client import connect
    result = {'mode': mode, 'source': source, 'target': 'en' if source == 'nl' else 'nl',
              'status': 'error', 'fresh_context': True, 'counts': {}, 'text': '', 'tts_started': False}
    counts = collections.Counter()
    meter = None
    commit = None
    try:
        contract = getattr(args, 'contract', None)
        if contract:
            result['contract_sha256'] = sha256(contract)
            if result['contract_sha256'] != getattr(args, 'contract_sha256', result['contract_sha256']):
                raise ValueError('Production contract changed after run preflight')
            instructions = production_prompt(contract, source, mode)
        else:
            instructions = interpreter_prompt(source, mode)
        result['instructions'] = instructions
        uri = helper.url.replace('http://', 'ws://') + '/v1/realtime'
        async with connect(uri, additional_headers={'Authorization': 'Bearer ' + helper.key},
                           open_timeout=10, close_timeout=2, max_size=1024 * 1024, max_queue=1) as ws:
            created = json.loads(await asyncio.wait_for(ws.recv(), 15))
            if created['type'] != 'session.created':
                raise ValueError('Expected session.created')
            audio = created['session']['audio']
            input_format, output_format = audio['input']['format'], audio['output']['format']
            if input_format['type'] != 'audio/pcm' or input_format['rate'] != 16000 or output_format['type'] != 'audio/pcm':
                raise ValueError('Unexpected negotiated PCM metadata')
            output_rate = output_format['rate']
            if not isinstance(output_rate, int) or not 8000 <= output_rate <= 192000:
                raise ValueError('Invalid output rate')
            result.update(input_format=input_format, output_format=output_format)
            meter = PCMMeter('pcm16', output_rate)
            await ws.send(json.dumps({'type': 'session.update', 'session': {'type': 'realtime',
                'instructions': instructions, 'output_modalities': ['text', 'audio'] if mode == 'direct' else ['text'],
                'tools': [], 'tool_choice': 'none', 'max_output_tokens': 512}}))
            updated = json.loads(await asyncio.wait_for(ws.recv(), 15))
            if updated['type'] != 'session.updated':
                raise ValueError('Expected session.updated')
            pcm = args.fixtures_pcm[source]
            started = time.monotonic()
            late = 0
            # 20ms real-time input. Final commit follows the last frame's duration.
            for offset in range(0, len(pcm), 640):
                helper.guard.check()
                target = started + offset / 32000
                await asyncio.sleep(max(0, target - time.monotonic()))
                late = max(late, time.monotonic() - target)
                await ws.send(json.dumps({'type': 'input_audio_buffer.append',
                                         'audio': base64.b64encode(pcm[offset:offset+640]).decode()}))
            await asyncio.sleep(max(0, started + len(pcm) / 32000 - time.monotonic()))
            commit = time.monotonic()
            result.update(source_seconds=len(pcm)/32000, input_elapsed_seconds=commit-started,
                          max_input_send_lateness_seconds=late, commit_monotonic=commit)
            await ws.send(json.dumps({'type': 'input_audio_buffer.commit'}))
            await ws.send(json.dumps({'type': 'response.create'}))
            while True:
                helper.guard.check()
                remaining = args.turn_timeout - (time.monotonic() - commit)
                if remaining <= 0:
                    raise TimeoutError('Realtime response deadline exceeded')
                event = json.loads(await asyncio.wait_for(ws.recv(), min(10, remaining)))
                arrived = time.monotonic()
                kind = event['type']
                counts[kind] += 1
                if 'function_call' in kind or event.get('item', {}).get('type') in ('function_call', 'tool_call'):
                    raise ValueError('Rejected tool request')
                if kind == 'error':
                    raise RuntimeError('Helper error event: ' + json.dumps(event.get('error', {}))[:500])
                if kind == 'response.output_text.delta':
                    result.setdefault('first_text_seconds', arrived - commit)
                    result['text'] += event['delta']
                    if any(marker in result['text'].lower() for marker in FORBIDDEN):
                        raise ValueError('Rejected tool markup in translation')
                    if len(result['text']) > 32768:
                        raise ValueError('Translation text exceeded probe bound')
                if kind == 'response.output_audio.delta':
                    block = base64.b64decode(event['delta'], validate=True)
                    if len(block) % 2:
                        raise ValueError('Unaligned PCM16 realtime chunk')
                    if block:
                        result.setdefault('first_audio_seconds', arrived - commit)
                        if meter.add(block) > .0001:
                            result.setdefault('first_nonzero_pcm_seconds', arrived - commit)
                        if cancel:
                            stop = time.monotonic()
                            await ws.send(json.dumps({'type': 'response.cancel'}))
                            await ws.close()
                            result.update(status='cancelled', cancel_to_socket_closed_seconds=time.monotonic()-stop,
                                          cancellation_measurement='Local cancel send to WebSocket closure; not acoustic stop or model completion')
                            break
                if kind == 'response.done':
                    result['response_status'] = event.get('response', {}).get('status')
                    if result['response_status'] not in (None, 'completed'):
                        raise ValueError('Response was not completed: ' + str(result['response_status']))
                    result['text_response_done_seconds'] = arrived - commit
                    result['done_seconds'] = arrived - commit
                    break
        result['socket_closed_seconds'] = None if commit is None else time.monotonic() - commit
        if result['status'] == 'cancelled':
            result['audio'] = meter.finish()
            result['output_guard'] = {'unrun': 'Cancellation trial has no completed translation'}
            return result
        if not result['text'].strip():
            raise ValueError('Response contained no translation text')
        if mode == 'direct':
            # Preserve actual received audio even if the later output check fails.
            result['audio'] = meter.finish()
            result['audio_chunks'] = counts['response.output_audio.delta']
        result['output_guard_phase'] = 'before-two-pass-tts' if mode == 'two-pass' else 'after-direct-audio-received'
        result['output_guard_limit'] = ('No source transcript: output-language validation does not establish meaning, numbers or negation. '
            + ('Direct validation is post-hoc and cannot undo already received audio.' if mode == 'direct'
               else 'Two-pass validation precedes /tts; it does not qualify the voice or translation.'))
        guard_started = time.monotonic()
        if contract and sha256(contract) != result['contract_sha256']:
            raise ValueError('Production contract changed during the turn')
        result['output_guard'] = output_guard(contract, source, result['text'])
        result['output_guard_seconds'] = time.monotonic() - guard_started
        if result['output_guard'].get('accepted') is False:
            raise ValueError('Production output guard rejected translation')
        if contract:
            result['validated_text_seconds'] = time.monotonic() - commit
        if mode == 'two-pass':
            # Single slot: never open /tts before the realtime socket has closed.
            result['tts_started'] = True
            await asyncio.to_thread(tts, helper, result['text'], result['target'], commit, args.turn_timeout, result)
        if not result['audio']['sample_count']:
            raise ValueError('Response contained no audio')
        result['audio_before_response_completion'] = result['first_audio_seconds'] < result['done_seconds']
        result['status'] = 'ok'
    except Exception as error:
        result['error'] = {'type': type(error).__name__, 'message': str(error)[:700]}
    finally:
        result['counts'] = dict(counts)
    return result


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def integrity(args):
    manifest = json.loads((ROOT / 'ThirdParty/LFMRealtime/runtime-manifest.json').read_text())
    evidence = json.loads((args.runtime_root / 'runtime/build-evidence.json').read_text())
    actual_helper = sha256(args.runtime_root / 'runtime/bin/llama-server')
    if evidence['sha256'] != actual_helper or evidence['runtimeCommit'] != manifest['runtime']['commit']:
        raise ValueError('Helper identity differs from build evidence / pinned runtime')
    for key in ('Q8_0', 'projector'):
        expected = manifest['model']['artifacts'][key]
        path = args.runtime_root / 'models' / expected['filename']
        if path.stat().st_size != expected['size'] or sha256(path) != expected['sha256']:
            raise ValueError('Pinned artifact integrity mismatch: ' + expected['filename'])
    return {'runtime': manifest['runtime'], 'model': manifest['model'], 'helper_sha256': actual_helper,
            'harness_sha256': sha256(Path(__file__)), 'runtime_build_evidence_sha256': sha256(args.runtime_root / 'runtime/build-evidence.json')}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime-root', type=Path, default=ROOT / 'build/lfm-realtime')
    parser.add_argument('--fixtures', type=Path, default=ROOT / 'build/lfm-realtime/probes/q8-fixed')
    parser.add_argument('--contract', type=Path, help='Compiled production prompt/output-guard driver; omitted preserves the legacy protocol')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--duration', type=float, default=1800)
    parser.add_argument('--min-turns', type=int, default=100)
    parser.add_argument('--cold-starts', type=int, default=10)
    parser.add_argument('--cancel-turns', type=int, default=5)
    parser.add_argument('--turn-timeout', type=float, default=60)
    parser.add_argument('--start-timeout', type=float, default=120)
    parser.add_argument('--max-swap-growth-mib', type=float, default=2048)
    parser.add_argument('--concurrent-activity', required=True)
    args = parser.parse_args()
    if (not all(math.isfinite(value) for value in (args.duration, args.turn_timeout, args.start_timeout, args.max_swap_growth_mib))
            or min(args.duration, args.min_turns, args.cold_starts, args.cancel_turns) < 0
            or min(args.turn_timeout, args.start_timeout, args.max_swap_growth_mib) <= 0):
        parser.error('Counts/duration must be nonnegative and timeouts positive')
    if args.contract:
        args.contract = args.contract.resolve()
        if not args.contract.is_file() or not os.access(args.contract, os.X_OK):
            parser.error('--contract must identify an executable production driver')
        args.contract_sha256 = sha256(args.contract)
        # Invalid driver/prompt must be discovered before any helper/model launch.
        for source in NAMES:
            for mode in ('direct', 'two-pass'):
                production_prompt(args.contract, source, mode)
    args.output.mkdir(parents=True, exist_ok=False)
    args.fixtures_pcm = {source: fixture(args.fixtures / ('synthetic-' + source + '.wav')) for source in NAMES}
    identity = integrity(args)
    if args.contract:
        identity['contract_sha256'] = args.contract_sha256
    guard = Guard(args.output, args.max_swap_growth_mib)
    run = {'schema_version': 1, 'run_id': str(uuid.uuid4()), 'started_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        'measurement': 'Synthetic fixture end-input commit to received loopback text/PCM; excludes capture, VAD endpointing, playback, acoustic output and human interpretation quality',
        'qualified': False, 'cold_start_definition': 'New helper process and model load; OS file cache retained',
        'hardware': {'model': command(['sysctl', '-n', 'hw.model']), 'chip': command(['sysctl', '-n', 'machdep.cpu.brand_string']),
                     'ram_bytes': int(command(['sysctl', '-n', 'hw.memsize'])), 'macos': command(['sw_vers', '-productVersion']),
                     'macos_build': command(['sw_vers', '-buildVersion'])},
        'software': {'python': sys.version, 'websockets': importlib.metadata.version('websockets'),
                     'git_head_at_start': command(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'])},
        'identity': identity, 'concurrent_activity': args.concurrent_activity,
        'protocol': {'input_pacing': '20ms chunks at real-time rate', 'input_format': 'PCM16 LE mono 16000Hz',
                     'context': 'fresh WebSocket per turn, same resident single-slot helper', 'ctx_size':4096,
                     'tools': [], 'reasoning':'off', 'max_output_tokens':512, 'tts_n_predict':512,
                     'outputs': 'PCM16 realtime; FLOAT32 /tts using actual received format metadata',
                     'prompt_source': 'production-contract' if args.contract else 'legacy-endurance',
                     'output_validation': 'Production validate-output before two-pass /tts; direct post-hoc after received audio, cannot undo audio; no source transcript or semantic guarantee' if args.contract else 'Legacy protocol without production output guard',
                     'timing_semantics': 'first_text_seconds is an unvalidated network delta; validated_text_seconds follows the contract check; first_audio_seconds is network receipt from input commit, includes contract-process time for two-pass but not direct post-hoc validation; no acoustic measurement',
                     'first_nonzero_pcm_threshold': 'First received block with any normalized PCM sample >0.0001 in absolute value; still not acoustic onset',
                     'audio_retained':False, 'no_microphone_or_playback':True, 'network':'authenticated 127.0.0.1 only, no proxies'},
        'fixtures': {source: {'path': str(args.fixtures / ('synthetic-' + source + '.wav')),
                             'sha256': sha256(args.fixtures / ('synthetic-' + source + '.wav')),
                             'seconds':len(pcm)/32000, 'kind':'Existing original synthetic fixture; macOS Xander/Samantha source voice, not output TTS'}
                     for source, pcm in args.fixtures_pcm.items()},
        'targets': {'duration_seconds':args.duration, 'warm_turns':args.min_turns, 'process_cold_starts':args.cold_starts},
        'guard': {'baseline':guard.baseline, 'critical_pressure_level':4, 'maximum_swap_growth_mib':args.max_swap_growth_mib,
                  'rss_limitation':'Process RSS excludes some Metal/unified-memory accounting; not a hardware-fit guarantee'},
        'cold_starts': [], 'turns': [], 'cancellations': [], 'abort':None, 'warm_duration_seconds':0}
    helper = None
    warm_started = None
    def snapshot():
        run['aggregate'] = aggregate(run['turns'])
        run['memory_summary'] = guard.summary()
        run['telemetry_errors'] = guard.telemetry_errors[:]
        run['abort'] = guard.abort or run['abort']
        run['status'] = run_outcome(len(run['turns']), run['warm_duration_seconds'], len(run['cold_starts']),
            run['aggregate']['errors'] + sum(c['status'] == 'error' for c in run['cancellations']),
            run['abort'], args.min_turns, args.duration, args.cold_starts)
        write_json(args.output / 'summary.json', run)
    def interrupted(signum, frame):
        raise KeyboardInterrupt('Signal ' + str(signum))
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        guard.start()
        snapshot()
        for index in range(args.cold_starts):
            guard.phase = 'cold-start-' + str(index+1)
            helper = Helper(args, guard)
            try:
                helper.start()
                observation = {'index':index+1, 'ready_seconds':helper.ready_seconds, 'memory':system_sample(helper.process.pid)}
            finally:
                closed = helper.close()
            observation['process_shutdown_seconds'] = closed
            run['cold_starts'].append(observation)
            append_json(args.output / 'cold-starts.jsonl', observation)
            helper = None
            snapshot()
            print(json.dumps({'phase':'cold', 'count':len(run['cold_starts']), 'ready_seconds':observation['ready_seconds']}), flush=True)
        guard.phase = 'warm-start'
        helper = Helper(args, guard)
        helper.start()
        run['warm_helper_ready_seconds'] = helper.ready_seconds
        run['helper_arguments'] = helper.command
        warm_started = time.monotonic()
        guard.phase = 'warm-turns'
        while time.monotonic() - warm_started < args.duration or len(run['turns']) < args.min_turns:
            guard.check()
            if time.monotonic() - warm_started > args.duration + max(300, args.min_turns * 15):
                raise TimeoutError('Soak extension deadline exceeded')
            index = len(run['turns'])
            source, mode = [('nl','direct'), ('en','direct'), ('nl','two-pass'), ('en','two-pass')][index % 4]
            result = asyncio.run(turn(helper, args, source, mode))
            result.update(index=index+1, warm_elapsed_seconds=time.monotonic()-warm_started)
            run['turns'].append(result)
            run['warm_duration_seconds'] = time.monotonic()-warm_started
            append_json(args.output / 'turns.jsonl', result)
            snapshot()
            print(json.dumps({'phase':'warm', 'turn':index+1, 'mode':mode, 'source':source, 'status':result['status'],
                              'elapsed_seconds':round(run['warm_duration_seconds'], 1),
                              'first_audio_seconds':result.get('first_audio_seconds'),
                              'errors':run['aggregate']['errors'], 'memory':run['memory_summary']['last_sample']}), flush=True)
            if helper.process.poll() is not None:
                raise RuntimeError('Owned helper exited during warm run')
        # Stop active output without playing it. These trials are excluded from warm successes.
        guard.phase = 'cancel-network-only'
        for index in range(args.cancel_turns):
            guard.check()
            result = asyncio.run(turn(helper, args, 'nl', 'direct', cancel=True))
            result['index'] = index+1
            run['cancellations'].append(result)
            snapshot()
    except BaseException as error:
        run['abort'] = guard.abort or (type(error).__name__ + ': ' + str(error))
    finally:
        if warm_started is not None and not run['cancellations']:
            run['warm_duration_seconds'] = time.monotonic()-warm_started
        if helper:
            run['final_process_shutdown_seconds'] = helper.close()
            run['owned_helper_exit_code'] = helper.process.returncode if helper.process else None
        guard.close()
        run['owned_helper_stopped'] = not helper or not helper.process or helper.process.poll() is not None
        run['final_memory'] = guard.final_sample()
        run['ended_utc'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
        snapshot()
        print(json.dumps({'final_status':run['status'], 'abort':run['abort'], 'warm_turns':len(run['turns']),
                          'warm_duration_seconds':run['warm_duration_seconds'], 'errors':run['aggregate']['errors']}), flush=True)
    return 0 if run['status'] == 'technical-run-complete' else 1


if __name__ == '__main__':
    sys.exit(main())
