#!/usr/bin/env python3
"""Run bounded technical probes serially against one owned model process.

Reuse explicitly supplied synthetic WAVs, or create legacy original fixtures with
macOS say. Never records or plays audio. Requires already verified local models.
"""
import argparse
import asyncio
import hashlib
import importlib.util
import io
import json
import math
import os
import pathlib
import secrets
import re
import subprocess
import time
import urllib.error
import urllib.request
import wave
from types import SimpleNamespace

ROOT = pathlib.Path(__file__).resolve().parents[3]
def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, pathlib.Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module
probe = load('lfm_probe', 'probe.py')
endurance = load('matrix_endurance_guard', 'endurance.py')
FIXTURES = [('nl','Xander','De afspraak is om half vier, niet om vier uur.','en'),
            ('en','Samantha','Please book two seats for Friday, not for Thursday.','nl')]


def prepare_fixtures(output, existing=None):
    """Snapshot the same bounded bytes for every mode and retain their origin/hash."""
    result = {}
    for source, voice, text, _ in FIXTURES:
        wav = output / ('synthetic-' + source + '.wav')
        original = (existing / wav.name).resolve() if existing else wav
        if existing is None:
            aiff = output / ('synthetic-' + source + '.aiff')
            subprocess.run(['say', '-v', voice, '-o', str(aiff), text], check=True, timeout=20)
            subprocess.run(['afconvert', '-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', str(aiff), str(wav)], check=True, timeout=20)
        with original.open('rb') as stream:
            data = stream.read(1024 * 1024 + 1)
        if len(data) > 1024 * 1024:
            raise ValueError('Fixture exceeds the bounded 1 MiB WAV size')
        with wave.open(io.BytesIO(data), 'rb') as audio:
            if audio.getnchannels() != 1 or audio.getsampwidth() != 2 or audio.getframerate() != 16000:
                raise ValueError('Fixture must be PCM16 mono WAV at 16000 Hz')
            frames = audio.getnframes()
            if not 0 < frames <= 12 * 16000:
                raise ValueError('Fixture must contain audio within the 12 second turn bound')
            if len(audio.readframes(frames)) != frames * 2:
                raise ValueError('Fixture PCM is truncated')
        if existing is not None:
            wav.write_bytes(data)
        result[source] = {'origin': 'reused-existing' if existing else 'legacy-say-generated',
                          'original_path': str(original), 'snapshot_path': str(wav),
                          'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data),
                          'sample_rate': 16000, 'frames': frames, 'seconds': frames / 16000}
    return result


def probe_failed(result):
    if not isinstance(result, dict):
        return False
    if result.get('failure') or result.get('errors') or result.get('output_guard', {}).get('accepted') is False:
        return True
    status = result.get('response_done', {}).get('response', {}).get('status')
    if status is not None and status != 'completed' and not (result.get('mode') == 'cancel' and status == 'cancelled'):
        return True
    if result.get('mode') in ('direct', 'tts') and result.get('audio_bytes') == 0:
        return True
    return any(probe_failed(value) for value in result.values() if isinstance(value, dict))


def run_probes(args, report, child, keyfile, guard, begin):
    output = args.output
    while time.monotonic()-begin < 120:
        guard.check()
        if child.poll() is not None:
            raise RuntimeError('Owned helper exited before readiness: '+str(child.returncode))
        match = re.search(r'listening on (http://127\.0\.0\.1:[0-9]+)', (output/'server.log').read_text(errors='replace'))
        if not match:
            time.sleep(.25)
            continue
        url = match.group(1)
        request = urllib.request.Request(url+'/props',headers={'Authorization':'Bearer '+keyfile.read_text()})
        try:
            with urllib.request.urlopen(request,timeout=1) as response:
                report['props'] = json.load(response)
            break
        except (urllib.error.URLError,TimeoutError):
            time.sleep(.25)
    else:
        raise TimeoutError('120-second helper readiness deadline')
    report['cold_readiness_seconds'] = time.monotonic()-begin
    # Verify unauthenticated HTTP cannot access the inference surface.
    try:
        urllib.request.urlopen(url+'/props',timeout=2)
        report['unauthenticated_props_status'] = 200
    except urllib.error.HTTPError as error:
        report['unauthenticated_props_status'] = error.code
    # WS upgrade authorization and Origin rejection are independently exercised.
    async def security():
        from websockets.asyncio.client import connect
        outcomes = {}
        uri = url.replace('http://','ws://')+'/v1/realtime'
        cases = [('no_auth',None,None),('foreign_origin',{'Authorization':'Bearer '+keyfile.read_text()},'https://untrusted.example'),('localhost_origin',{'Authorization':'Bearer '+keyfile.read_text()},'http://localhost')]
        for name,headers,origin in cases:
            try:
                async with connect(uri,additional_headers=headers,origin=origin,open_timeout=5,close_timeout=2) as ws:
                    outcomes[name] = 'unexpected_connection_accepted'
            except Exception as error:
                response = getattr(error,'response',None)
                outcomes[name] = getattr(response,'status_code',type(error).__name__)
        return outcomes
    report['websocket_security'] = asyncio.run(security())
    try:
        request=urllib.request.Request(url+'/props',headers={'Authorization':'Bearer '+keyfile.read_text(),'Origin':'https://untrusted.example'})
        urllib.request.urlopen(request,timeout=2)
        report['http_foreign_origin_status']=200
    except urllib.error.HTTPError as error:
        report['http_foreign_origin_status']=error.code
    report['security_passed'] = report['websocket_security'] == {'no_auth':401,'foreign_origin':403,'localhost_origin':403} and report['http_foreign_origin_status'] == 403 and report['unauthenticated_props_status'] == 401
    if not report['security_passed']:
        raise RuntimeError('Helper HTTP/WebSocket authentication or browser Origin rejection failed')
    for source,voice,text,target in FIXTURES:
        wav=output/('synthetic-'+source+'.wav')
        for mode in ['direct','two-pass']:
            guard.phase=source+'-'+mode; guard.check()
            path=output/(source+'-'+mode+'.json')
            options=SimpleNamespace(url=url,key_file=keyfile,wav=wav,timeout=args.timeout,output=path,retain_content=True,lang=target,text=text,source_language=source,contract=args.contract)
            try:
                result=asyncio.run(probe.websocket_probe(options,text_only=mode=='two-pass'))
                if not result.get('text', '').strip():
                    raise ValueError('Translation returned no text')
                if result.get('text'):
                    result['output_guard']=probe.output_guard(options,result['text'])
                if mode=='two-pass' and result.get('text'):
                    # Socket is closed; the production output guard runs before same-slot /tts.
                    result['tts']=(probe.tts_probe(options,result['text']) if result['output_guard'].get('accepted',True)
                                   else {'unrun':'production output guard rejected target language'})
                if result.get('output_guard',{}).get('accepted') is False:
                    result['failure']='TranslationOutputRejected'
                    result['message']='Production output guard rejected this turn; direct-mode audio may already have been received.'
            except Exception as error:
                result=getattr(options,'_partial',{})
                result.update(failure=type(error).__name__,message=str(error))
            path.write_text(json.dumps(result,indent=2,ensure_ascii=False)+'\n')
            report['probes'].append({'source':source,'mode':mode,'path':path.name,**{k:v for k,v in result.items() if k in ('failure','errors','first_text_seconds','first_audio_seconds','done_seconds','audio_bytes','text','tts','output_guard','response_done')}})
            (output/'summary.json').write_text(json.dumps(report,indent=2,ensure_ascii=False)+'\n')
            guard.check()
    for language,text in [('nl','De afspraak is om half vier, niet om vier uur.'),('en','Please book two seats for Friday, not for Thursday.')]:
        guard.phase='tts-'+language; guard.check()
        options=SimpleNamespace(url=url,key_file=keyfile,timeout=args.timeout,output=output/('tts-'+language+'.json'),retain_content=True,lang=language,text=text)
        result=probe.tts_probe(options)
        options.output.write_text(json.dumps(result,indent=2)+'\n')
        report['probes'].append({'mode':'tts','language':language,**result})
    guard.phase='cancel'; guard.check()
    options=SimpleNamespace(url=url,key_file=keyfile,wav=output/'synthetic-en.wav',timeout=args.timeout,output=output/'cancel.json',retain_content=True,lang='nl',source_language='en',contract=args.contract)
    try:
        result=asyncio.run(probe.websocket_probe(options,cancel=True))
        options.output.write_text(json.dumps(result,indent=2)+'\n')
        report['cancel']=result
    except Exception as error:
        report['cancel']={'failure':type(error).__name__,'message':str(error)}
    guard.phase='fresh-session'; guard.check()
    report['fresh_session_after_cancel']=asyncio.run(probe.websocket_probe(options,reset=True))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--quantization', choices=['Q8_0','Q4_K_M'], default='Q8_0')
    parser.add_argument('--build-root', type=pathlib.Path, default=ROOT/'build/lfm-realtime')
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--fixtures', type=pathlib.Path, help='Reuse synthetic-nl.wav and synthetic-en.wav without invoking say')
    parser.add_argument('--contract', type=pathlib.Path, help='Compiled production prompt/guard driver; legacy prompts if omitted')
    parser.add_argument('--helper', type=pathlib.Path)
    parser.add_argument('--timeout', type=float, default=90)
    parser.add_argument('--max-swap-growth-mib', type=float, default=1024)
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or not 1 <= args.timeout <= 180:
        parser.error('Timeout must be finite and between 1 and 180 seconds')
    if not math.isfinite(args.max_swap_growth_mib) or not 0 < args.max_swap_growth_mib <= 2048:
        parser.error('Swap-growth guard must be positive and no greater than 2048 MiB')
    args.output = args.output.resolve(); output = args.output; build = args.build_root.resolve()
    output.mkdir(parents=True, exist_ok=False)
    report = {'quantization': args.quantization, 'status': 'incomplete', 'qualified': False,
              'probes': [], 'max_swap_growth_mib': args.max_swap_growth_mib,
              'memory_note': 'Real OS pressure, global swap and owned helper RSS sampled by endurance.Guard; RSS excludes a complete system/Metal footprint and global swap cannot be attributed solely to this process.',
              'contention': 'Serial owned helper; caller must isolate other workloads. No acoustic or human qualification.'}
    guard = endurance.Guard(output, args.max_swap_growth_mib)
    child = None; log = None; keyfile = output/'.probe-key'
    try:
        guard.check()
        if guard.baseline['pressure_level'] != 1:
            guard.abort = 'Normal OS memory-pressure baseline required before helper/model startup'
            guard.check()
        guard.start(); guard.phase = 'artifact-verification'
        subprocess.run(['python3', str(ROOT/'scripts/build_lfm_realtime_runtime.py'), '--build-root', str(build), '--verify-only', '--quantizations', args.quantization], check=True)
        guard.check()
        if args.contract:
            args.contract = args.contract.resolve()
            if not args.contract.is_file() or not os.access(args.contract, os.X_OK):
                raise ValueError('Contract must be an executable production driver')
            report['contract_sha256'] = endurance.sha256(args.contract)
            for source, _, _, _ in FIXTURES:
                for mode in ('direct', 'two-pass'):
                    endurance.production_prompt(args.contract, source, mode)
        guard.phase = 'fixture-preparation'
        report['fixtures'] = prepare_fixtures(output, args.fixtures)
        guard.check()
        manifest = json.loads((ROOT/'ThirdParty/LFMRealtime/runtime-manifest.json').read_text())
        helper = args.helper or build/'runtime/bin/llama-server'
        model = build/'models'/manifest['model']['artifacts'][args.quantization]['filename']
        projector = build/'models'/manifest['model']['artifacts']['projector']['filename']
        fd = os.open(str(keyfile), os.O_WRONLY|os.O_CREAT|os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as stream: stream.write(secrets.token_hex(32))
        command = [str(helper),'-m',str(model),'--mmproj',str(projector),'--host','127.0.0.1','--port','0','--parallel','1','--ctx-size','4096','--threads','4','--batch-size','512','--ubatch-size','128','--gpu-layers','99','--reasoning','off','--api-key-file',str(keyfile),'--cors-origins','localhost','--no-cors-credentials','--no-agent','--no-webui']
        report['command'] = command
        report['model_revision'] = manifest['model']['revision']; report['runtime_commit'] = manifest['runtime']['commit']
        log = (output/'server.log').open('w')
        environment = {key:value for key,value in os.environ.items() if not key.startswith('LLAMA_')}
        guard.phase = 'helper-startup'; guard.check()
        begin = time.monotonic()
        child = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, env=environment)
        guard.process = child
        guard.check()
        run_probes(args, report, child, keyfile, guard, begin)
        guard.check()
    except Exception as error:
        report['failure'] = {'type': type(error).__name__, 'message': str(error)}
    finally:
        if child is not None:
            try:
                guard.request_termination(child)
                try: child.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    child.kill(); child.wait(timeout=5)
            except Exception as error:
                report['cleanup_failure'] = {'type': type(error).__name__, 'message': str(error)}
            report['owned_child_exit_code'] = child.returncode
        report['owned_child_stopped'] = child is None or child.poll() is not None
        if report['owned_child_stopped']: guard.process = None
        guard.close()
        report['final_memory'] = guard.final_sample()
        report['memory_summary'] = guard.summary()
        report['peak_sampled_rss_bytes'] = report['memory_summary']['peak_helper_rss_bytes']
        report['telemetry_errors'] = guard.telemetry_errors[:]
        report['memory_abort'] = guard.abort
        if log is not None: log.close()
        keyfile.unlink(missing_ok=True)
        results = report['probes'] + [report.get('cancel', {}), report.get('fresh_session_after_cancel', {})]
        report['failed_probe_count'] = sum(probe_failed(result) for result in results)
        failed = bool(report.get('failure') or report.get('cleanup_failure') or guard.abort or report['failed_probe_count'] or not report['owned_child_stopped'])
        report['status'] = 'failed' if failed else 'completed-technical-only-unqualified'
        (output/'summary.json').write_text(json.dumps(report, indent=2, ensure_ascii=False)+'\n')
        print(json.dumps({'status': report['status'], 'failed_probe_count': report['failed_probe_count'], 'output': str(output)}), flush=True)
    return 1 if failed else 0


if __name__ == '__main__': raise SystemExit(main())
