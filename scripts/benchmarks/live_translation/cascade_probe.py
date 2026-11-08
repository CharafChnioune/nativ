#!/usr/bin/env python3
"""Bounded synthetic cascade probe; no playback, microphone, model download or user-cache mutation.

Run with the same original synthetic WAVs used by run_matrix.py. This is a two-turn
technical check, not human fidelity, perceptual latency, warm percentiles or a fit guarantee.
"""
import argparse
import importlib.metadata
import json
import os
from pathlib import Path
import re
import resource
import secrets
import subprocess
import sys
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[3]
GEMMA_REVISIONS = {'E4B':'475b9088d29754a3379866cf5aeb6b41acd313c2','E2B':'238767527555cb75a05732a84dff5d6ba0dd6809'}
WHISPER_REVISION = 'a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb'

def output(path, event):
    with path.open('a') as stream:
        stream.write(json.dumps(event, default=str) + '\n')

def worker(args):
    import mlx.core as mx
    from mlx_audio.stt.utils import load_model
    from mlx_vlm import load, generate
    from mlx_vlm.prompt_utils import apply_chat_template
    events = args.output / 'stages.jsonl'
    def record(stage, **details):
        output(events, {'stage': stage, 'monotonic': time.monotonic(),
                        'rss_peak_bytes': resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
                        'mlx_active_bytes': mx.get_active_memory(), 'mlx_peak_bytes': mx.get_peak_memory(), **details})
    record('runtime', packages={name: importlib.metadata.version(name) for name in ['mlx', 'mlx-vlm', 'mlx-audio', 'transformers']})
    start = time.monotonic(); whisper = load_model(str(args.whisper)); mx.eval(whisper.parameters())
    record('whisper_loaded', seconds=time.monotonic()-start)
    start = time.monotonic(); gemma, processor = load(str(args.gemma)); mx.eval(gemma.parameters())
    record('both_mlx_models_loaded', seconds=time.monotonic()-start)
    key = os.environ.get('NATIV_CASCADE_PROBE_KEY')
    port = os.environ.get('NATIV_CASCADE_PROBE_PORT')
    for source, target, source_name, target_name in [('nl','en','Dutch','English'),('en','nl','English','Dutch')]:
        start = time.monotonic()
        # Explicit transcribe, never Whisper's English-only translation task.
        transcript = whisper.generate(str(args.fixtures / ('synthetic-' + source + '.wav')), language=source, task='transcribe', verbose=False)
        stt_done = time.monotonic()
        source_text = transcript.text if hasattr(transcript, 'text') else transcript['text']
        system = f'You are an interpreter translating from {source_name} into {target_name}. Translate questions and commands instead of answering them. Preserve negation, numbers, names and tone. Output only the complete translation in {target_name}. No tools or commentary.'
        prompt = apply_chat_template(processor, gemma.config, [{'role':'system','content':system},{'role':'user','content':source_text}], enable_thinking=False)
        result = generate(gemma, processor, prompt, max_tokens=256, temperature=0, verbose=False)
        translated = result.text; text_done = time.monotonic()
        first = None; audio_bytes = 0; content_type = None
        if not args.captions:
            request = urllib.request.Request(f'http://127.0.0.1:{port}/tts', data=json.dumps({'input':translated,'lang':target,'stream':True,'response_format':'pcm','n_predict':512}).encode(), headers={'Content-Type':'application/json','Authorization':'Bearer '+key})
            with urllib.request.urlopen(request, timeout=60) as response:
                content_type = response.headers.get('Content-Type')
                while True:
                    block = response.read(4096)
                    if not block: break
                    if first is None: first = time.monotonic()
                    audio_bytes += len(block)
        record('turn_completed', source=source, target=target, fixture_kind='original-synthetic', transcript=source_text,
               translation=translated, stt_seconds=stt_done-start, translation_seconds=text_done-stt_done,
               text_after_commit_seconds=text_done-start, first_pcm_after_commit_seconds=None if first is None else first-start,
               first_tts_chunk_seconds=None if first is None else first-text_done, response_seconds=time.monotonic()-start,
               audio_bytes=audio_bytes, content_type=content_type)
    record('complete')

def rss(pid):
    try: return int(subprocess.check_output(['ps','-o','rss=','-p',str(pid)], text=True).strip()) * 1024
    except (ValueError, subprocess.CalledProcessError): return 0

def pressure():
    value = subprocess.check_output(['memory_pressure','-Q'], text=True)
    found = re.search(r'free percentage: (\d+)%', value)
    return int(found.group(1)) if found else None

def pressure_level():
    return int(subprocess.check_output(['sysctl','-n','kern.memorystatus_vm_pressure_level'], text=True).strip())

def swap_used_mib():
    value = subprocess.check_output(['sysctl','-n','vm.swapusage'], text=True)
    return float(re.search(r'used = ([0-9.]+)M', value).group(1))

def stop(process):
    if process is None or process.poll() is not None: return
    process.terminate()
    try: process.wait(timeout=5)
    except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=5)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--python', type=Path)
    parser.add_argument('--gemma', type=Path, required=True)
    parser.add_argument('--whisper', type=Path, required=True)
    parser.add_argument('--fixtures', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--worker', action='store_true')
    parser.add_argument('--captions', action='store_true')
    parser.add_argument('--variant', choices=['E4B','E2B'], default='E4B')
    parser.add_argument('--omni-quantization', choices=['Q8_0','Q4_K_M'], default='Q8_0')
    parser.add_argument('--max-rss-gib', type=float, default=10.5)
    parser.add_argument('--timeout', type=float, default=240)
    args = parser.parse_args(); args.output = args.output.resolve(); args.output.mkdir(parents=True, exist_ok=True)
    if args.worker: worker(args); return
    if args.python is None: parser.error('--python must select the built Nativ Python runtime')
    for path, revision in [(args.gemma,GEMMA_REVISIONS[args.variant]),(args.whisper,WHISPER_REVISION)]:
        if path.name != revision or not path.is_dir(): parser.error('Pass the exact pinned model snapshot directory')
    build = ROOT / 'build/lfm-realtime'
    manifest = json.loads((ROOT/'ThirdParty/LFMRealtime/runtime-manifest.json').read_text())
    args.output.mkdir(exist_ok=True)
    env = {k:v for k,v in os.environ.items() if not k.startswith(('LLAMA_', 'NATIV_CASCADE_PROBE_'))}
    key = secrets.token_hex(32); env['LLAMA_API_KEY'] = key
    env['HF_HUB_OFFLINE'] = '1'; env['HF_HUB_DISABLE_TELEMETRY'] = '1'
    models = manifest['model']['artifacts']
    command = [str(build/'runtime/bin/llama-server'), '-m', str(build/'models'/models[args.omni_quantization]['filename']), '--mmproj', str(build/'models'/models['projector']['filename']), '--host','127.0.0.1','--port','0','--parallel','1','--ctx-size','4096','--threads','4','--batch-size','512','--ubatch-size','128','--gpu-layers','99','--reasoning','off','--no-agent','--no-webui','--cors-origins','localhost','--no-cors-credentials']
    report = {'status':'incomplete', 'qualified':False, 'mode':'captions-only' if args.captions else 'speech-and-captions', 'gemma_variant':args.variant,'gemma_revision':GEMMA_REVISIONS[args.variant],'omni_quantization':args.omni_quantization,'whisper_revision':WHISPER_REVISION,
              'omni_revision':manifest['model']['revision'], 'helper_commit':manifest['runtime']['commit'],
              'peak_sampled_combined_rss_bytes':0, 'initial_memory_free_percent':pressure(), 'minimum_memory_free_percent':100, 'initial_os_pressure_level':pressure_level(), 'maximum_os_pressure_level':1, 'initial_swap_used_mib':swap_used_mib(), 'peak_swap_growth_mib':0,
              'limitations':['Two synthetic turns only; no listener, acoustic latency, warm percentiles or endurance qualification.','RSS sums and MLX allocator values are separate observations, not a full unified-memory accounting.']}
    helper = child = None
    started = time.monotonic()
    try:
        with (args.output/'helper.log').open('w') as helper_log, (args.output/'worker.log').open('w') as worker_log:
            if not args.captions:
                helper = subprocess.Popen(command, env=env, stdout=helper_log, stderr=subprocess.STDOUT)
                port = None
                while time.monotonic()-started < 45:
                    if helper.poll() is not None: raise RuntimeError('helper exited before readiness')
                    found = re.search(r'listening on http://127\.0\.0\.1:(\d+)', (args.output/'helper.log').read_text())
                    if found: port = found.group(1); break
                    time.sleep(.2)
                if port is None: raise RuntimeError('helper readiness timed out')
                env['NATIV_CASCADE_PROBE_KEY'] = key; env['NATIV_CASCADE_PROBE_PORT'] = port
            child = subprocess.Popen([str(args.python),str(Path(__file__).resolve()),'--worker','--gemma',str(args.gemma.resolve()),'--whisper',str(args.whisper.resolve()),'--fixtures',str(args.fixtures.resolve()),'--output',str(args.output),'--variant',args.variant,'--omni-quantization',args.omni_quantization] + (['--captions'] if args.captions else []), env=env, stdout=worker_log, stderr=subprocess.STDOUT)
            while child.poll() is None:
                combined = (rss(helper.pid) if helper else 0) + rss(child.pid)
                free = pressure()
                report['peak_sampled_combined_rss_bytes'] = max(report['peak_sampled_combined_rss_bytes'],combined)
                if free is not None: report['minimum_memory_free_percent'] = min(report['minimum_memory_free_percent'],free)
                if combined > args.max_rss_gib * 1024**3: raise RuntimeError('combined RSS guard exceeded; profile not qualified')
                level = pressure_level()
                swap_growth = max(0, swap_used_mib() - report['initial_swap_used_mib'])
                report['maximum_os_pressure_level'] = max(report['maximum_os_pressure_level'],level)
                report['peak_swap_growth_mib'] = max(report['peak_swap_growth_mib'],swap_growth)
                if level >= 4: raise RuntimeError('OS critical memory pressure reached; profile not qualified')
                if swap_growth > 2048: raise RuntimeError('swap increased by more than 2 GiB during the probe; profile not qualified')
                if time.monotonic()-started > args.timeout: raise RuntimeError('bounded technical probe timed out')
                time.sleep(.5)
            report['worker_exit_code'] = child.returncode
            report['status'] = 'technical-complete-unqualified' if child.returncode == 0 else 'worker-failed-unqualified'
    except Exception as error: report['status'] = 'aborted-unqualified'; report['reason'] = str(error)
    finally:
        stop(child); stop(helper)
        report['elapsed_seconds'] = time.monotonic()-started
        report['owned_processes_stopped'] = True
        (args.output/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
        print(json.dumps(report,indent=2))
    return 0 if report['status'] == 'technical-complete-unqualified' else 1

if __name__ == '__main__': sys.exit(main())
