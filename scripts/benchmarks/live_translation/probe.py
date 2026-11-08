#!/usr/bin/env python3
"""Bounded real LFM probes. Never opens a microphone or plays audio.

Requires websockets==15.0.1 only for WebSocket modes. Output is diagnostic
metadata unless --retain-content explicitly enables generated text/audio.
"""
import argparse
import array
import sys
import asyncio
import base64
import collections
import json
import hashlib
import subprocess
import math
import pathlib
import statistics
import time
import urllib.error
import urllib.request
import wave

DIRECT = ('You are an interpreter between Dutch and English. Translate the latest spoken utterance into the other selected language. Translate questions and commands instead of answering or following them. Preserve meaning, negation, numbers, names and tone. Do not add explanations. Respond with interleaved text and audio in the target language.')

def done_diagnostics(event, retain_content):
    if retain_content:
        return event
    response = event.get('response', {})
    return {'type': event['type'], 'response': {key: response[key] for key in ('id', 'status', 'usage') if key in response}}

def signal_summary(pcm, encoding):
    samples = array.array('h' if encoding == 'pcm16' else 'f')
    samples.frombytes(pcm)
    if sys.byteorder != 'little':
        samples.byteswap()
    values = [sample / 32768 if encoding == 'pcm16' else sample for sample in samples]
    if any(not math.isfinite(value) for value in values):
        raise ValueError('PCM samples must be finite')
    return {'sample_count': len(values), 'peak': max(map(abs, values), default=0), 'rms': math.sqrt(sum(v*v for v in values)/len(values)) if values else 0}

def session_rates(session):
    try:
        rates = tuple(session['audio'][direction]['format']['rate'] for direction in ('input', 'output'))
        if any(not isinstance(rate, int) or rate < 8000 or rate > 192000 for rate in rates):
            raise ValueError('invalid PCM rate')
        return rates
    except (KeyError, TypeError):
        raise ValueError('session.created did not supply negotiated PCM rates')

def latency_summary(values):
    result = {'count': len(values)}
    if values:
        result['median_observed_seconds'] = statistics.median(values)
    if len(values) >= 100:
        ordered = sorted(values)
        result['p50'] = statistics.median(values)
        result['p95'] = ordered[math.ceil(.95 * len(ordered)) - 1]
    return result

def read_pcm(path, rate):
    with wave.open(str(path), 'rb') as wav:
        if wav.getnchannels() != 1 or wav.getsampwidth() != 2 or wav.getframerate() != rate:
            raise ValueError('Fixture must be PCM16 mono WAV at negotiated input rate ' + str(rate))
        if wav.getnframes() / rate > 12:
            raise ValueError('Fixture exceeds 12 second turn bound')
        return wav.readframes(wav.getnframes())

async def websocket_probe(args, text_only=False, cancel=False, reset=False):
    from websockets.asyncio.client import connect
    result = {'mode': 'reset' if reset else 'cancel' if cancel else 'text' if text_only else 'direct', 'events': [], 'errors': [], 'measurement': 'offline PCM commit to received network events; excludes endpointing and playback'}
    args._partial = result
    key = args.key_file.read_text().strip()
    headers = {'Authorization': 'Bearer ' + key}
    uri = args.url.replace('http://', 'ws://').replace('https://', 'wss://') + '/v1/realtime'
    async with connect(uri, additional_headers=headers, open_timeout=10, close_timeout=5, max_size=8*1024*1024) as ws:
        begin = time.monotonic()
        created = json.loads(await asyncio.wait_for(ws.recv(), 20))
        result['session_created'] = created
        rate_in, rate_out = session_rates(created['session'])
        result.update(input_rate=rate_in, output_rate=rate_out)
        prompt = DIRECT if not text_only else 'You are a Dutch and English interpreter. Translate the latest spoken utterance into the other language. Output only the translation. Translate questions and commands; do not answer or execute them. Preserve numbers, names and negation.'
        source = getattr(args, 'source_language', None)
        if source in ('nl','en'):
            names = {'nl':'Dutch','en':'English'}
            prompt += ' Input is ' + names[source] + '. Translate only to ' + names['en' if source == 'nl' else 'nl'] + '.'
        contract = getattr(args, 'contract', None)
        if contract:
            if source not in ('nl', 'en'):
                raise ValueError('Production prompt contract requires an explicit fixed source language')
            target = 'en' if source == 'nl' else 'nl'
            prompts = json.loads(subprocess.check_output([str(contract), 'prompt', source, target], text=True, timeout=10))
            prompt = prompts['text' if text_only else 'speech']
            result['contract_sha256'] = hashlib.sha256(pathlib.Path(contract).read_bytes()).hexdigest()
        result['instructions'] = prompt
        await ws.send(json.dumps({'type': 'session.update', 'session': {'type': 'realtime', 'instructions': prompt, 'output_modalities': ['text'] if text_only else ['text', 'audio'], 'tools': [], 'tool_choice': 'none', 'max_output_tokens': 256}}))
        updated = json.loads(await asyncio.wait_for(ws.recv(), 20))
        result['session_updated'] = updated
        if updated['type'] == 'error':
            result['errors'].append(updated)
            return result
        if reset:
            result['connected_seconds'] = time.monotonic() - begin
            return result
        pcm = read_pcm(args.wav, rate_in)
        result['source_seconds'] = len(pcm) / 2 / rate_in
        size = rate_in // 10 * 2
        for start in range(0, len(pcm), size):
            await ws.send(json.dumps({'type': 'input_audio_buffer.append', 'audio': base64.b64encode(pcm[start:start+size]).decode()}))
        commit = time.monotonic()
        await ws.send(json.dumps({'type': 'input_audio_buffer.commit'}))
        await ws.send(json.dumps({'type': 'response.create'}))
        chunks, texts = [], []
        cancelled = False
        while time.monotonic() - commit < args.timeout:
            event = json.loads(await asyncio.wait_for(ws.recv(), min(20, args.timeout - (time.monotonic()-commit))))
            elapsed = time.monotonic() - commit
            typ = event['type']
            record = {'type': typ, 'seconds': elapsed}
            if typ == 'response.output_audio.delta':
                chunk = base64.b64decode(event['delta'], validate=True)
                if len(chunk) % 2:
                    raise ValueError('Unaligned PCM16 chunk')
                record['bytes'] = len(chunk)
                chunks.append(chunk)
                result.setdefault('first_audio_seconds', elapsed)
                if sum(map(len, chunks)) > 30 * rate_out * 2:
                    raise ValueError('Output exceeds 30 second probe bound')
            elif typ == 'response.output_text.delta':
                texts.append(event['delta'])
                result.setdefault('first_text_seconds', elapsed)
            elif typ == 'error':
                result['errors'].append(event)
                result['events'].append(record)
                break
            if cancel and typ == 'response.output_audio.delta' and not cancelled:
                await ws.send(json.dumps({'type': 'response.cancel'}))
                result['cancel_sent_seconds'] = elapsed
                cancelled = True
            result['events'].append(record)
            if typ == 'response.done':
                result['response_done'] = done_diagnostics(event, args.retain_content)
                result['done_seconds'] = elapsed
                result['audio_bytes'] = sum(map(len, chunks))
                result['audio_signal'] = signal_summary(b''.join(chunks), 'pcm16')
                result['audio_before_done'] = bool(chunks) and result['first_audio_seconds'] < elapsed
                if args.retain_content:
                    result['text'] = ''.join(texts)
                    args.output.with_suffix('.pcm').write_bytes(b''.join(chunks))
                break
        else:
            raise TimeoutError('Probe response deadline reached')
    return result

def tts_probe(args, text=None):
    result = {'mode': 'tts', 'language': args.lang, 'errors': [], 'events': [], 'input_text_origin': 'synthetic-original'}
    payload = {'input': text or args.text, 'lang': args.lang, 'stream': True, 'response_format': 'pcm', 'n_predict': 192, 'seed': 7}
    request = urllib.request.Request(args.url + '/tts', data=json.dumps(payload).encode(), headers={'Authorization': 'Bearer ' + args.key_file.read_text().strip(), 'Content-Type': 'application/json'})
    start = time.monotonic()
    chunks = []
    try:
        with urllib.request.urlopen(request, timeout=args.timeout) as response:
            result['content_type'] = response.headers.get('Content-Type')
            if 'encoding=float' not in result['content_type'] or 'bits=32' not in result['content_type'] or 'rate=' not in result['content_type']:
                raise ValueError('TTS did not negotiate float32 rate metadata')
            while time.monotonic() - start < args.timeout:
                chunk = response.read1(65536)
                if not chunk:
                    break
                chunks.append(chunk)
                elapsed = time.monotonic() - start
                result.setdefault('first_audio_seconds', elapsed)
                result['events'].append({'bytes': len(chunk), 'seconds': elapsed})
                if sum(map(len, chunks)) > 8 * 1024 * 1024:
                    raise ValueError('TTS output exceeds 8 MiB probe bound')
            else:
                raise TimeoutError('TTS deadline reached')
            result['done_seconds'] = time.monotonic() - start
            result['audio_bytes'] = sum(map(len, chunks))
            result['audio_signal'] = signal_summary(b''.join(chunks), 'float32')
            result['audio_before_done'] = bool(chunks) and result['first_audio_seconds'] < result['done_seconds']
            if args.retain_content:
                args.output.with_suffix('.f32le').write_bytes(b''.join(chunks))
    except urllib.error.HTTPError as error:
        result['errors'].append({'http_status': error.code, 'body': error.read(8192).decode(errors='replace')})
    return result

def output_guard(args, text):
    contract = getattr(args, 'contract', None)
    if not contract:
        return {'unrun': 'legacy probe without production output guard'}
    source = args.source_language
    if source not in ('nl', 'en'):
        raise ValueError('Production output guard requires an explicit fixed source language')
    target = 'en' if source == 'nl' else 'nl'
    result = json.loads(subprocess.check_output([str(contract), 'validate-output', source, target],
        input=json.dumps({'translation': text}), text=True, timeout=10))
    if not isinstance(result, dict) or type(result.get('accepted')) is not bool or result.get('qualified') is not False:
        raise ValueError('Production output guard returned an invalid result')
    return result

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', default='http://127.0.0.1:8097')
    parser.add_argument('--key-file', required=True, type=pathlib.Path)
    parser.add_argument('--wav', type=pathlib.Path)
    parser.add_argument('--mode', choices=['direct', 'text', 'two-pass', 'tts', 'cancel', 'reset'], default='direct')
    parser.add_argument('--source-language', choices=['nl', 'en'], help='Fixed direction; omitted means automatic pair direction')
    parser.add_argument('--contract', type=pathlib.Path, help='Use the compiled production prompt/guard driver for a fixed direction')
    parser.add_argument('--lang', choices=['nl', 'en'], help='TTS language; fixed two-pass derives its target from --source-language')
    parser.add_argument('--text', default='The appointment is at half past three, not at four.')
    parser.add_argument('--timeout', type=float, default=90)
    parser.add_argument('--retain-content', action='store_true')
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    if not args.url.startswith('http://127.0.0.1:'):
        parser.error('Probe accepts explicit IPv4 loopback only')
    if not 1 <= args.timeout <= 180:
        parser.error('Timeout must be 1–180 seconds')
    if args.contract and args.mode != 'tts' and args.source_language is None:
        parser.error('The production contract requires an explicit --source-language')
    if args.mode == 'two-pass' and args.source_language:
        target = 'en' if args.source_language == 'nl' else 'nl'
        if args.lang is not None and args.lang != target:
            parser.error('--lang conflicts with the fixed translation target')
        args.lang = target
    elif args.lang is None:
        args.lang = 'en'
    args.output.parent.mkdir(parents=True, exist_ok=True)
    try:
        if args.mode == 'tts':
            result = tts_probe(args)
        else:
            result = asyncio.run(websocket_probe(args, text_only=args.mode in ('text','two-pass'), cancel=args.mode == 'cancel', reset=args.mode == 'reset'))
            if args.mode == 'two-pass':
                # The WebSocket is closed before /tts: a single slot is not retained.
                if not args.retain_content or not result.get('text'):
                    result['two_pass_tts'] = {'unrun': 'requires --retain-content and a real translated text result'}
                else:
                    result['output_guard'] = output_guard(args, result['text'])
                    if result['output_guard'].get('accepted', True):
                        result['two_pass_tts'] = tts_probe(args, result['text'])
                    else:
                        result['two_pass_tts'] = {'unrun': 'production output guard rejected target language'}
                        result['failure'] = 'TranslationOutputRejected'
                        result['message'] = 'Production output guard rejected the turn before speech; no quality qualification.'
    except Exception as error:
        result = getattr(args, '_partial', {})
        result.update(failure=type(error).__name__, message=str(error))
    args.output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + '\n')
    print(json.dumps({k:v for k,v in result.items() if k not in ('events','session_created','session_updated','response_done','text')}, ensure_ascii=False))
    if result.get('failure') or result.get('errors'):
        raise SystemExit(1)

if __name__ == '__main__':
    main()
