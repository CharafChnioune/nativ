"""Owned one-job workers. Heavy imports happen only after the identity handshake.

The supervisor owns process groups, parent-death protection, cancellation and the
compute lease. Every engine is forced offline; installation is a separate action.
"""
from __future__ import annotations
import contextlib
import hashlib
import importlib.metadata
import importlib.util
import json
import math
import os
from pathlib import Path
import resource
import runpy
import secrets
import shutil
import sys
import traceback

ACE_MODEL_REVISION = '19671f406d603126926c1b7e2adc169acbcade22'
MINIMAX_MODEL_REVISION = 'd00a12c3c7f80eb66379dd02dd0f30ed0ce2d96e'
STABLE_MODEL_REVISION = '30cb2644da54bfa63275d1bc7f1fa67fc718680f'
RUNTIMES = {'acestep': 'acestep-1.5-ca1e85f', 'minimax_mlx': 'minimax-music3-mlx-0.6.4',
            'stable_audio_mlx': 'stable-audio-3-mlx-790793b'}


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''): value.update(chunk)
    return value.hexdigest()


def verify_receipt(directory, profile, revision):
    directory = Path(directory).resolve(strict=True)
    receipt = json.loads((directory / 'nativ-model.json').read_text())
    if receipt.get('profile') != profile or receipt.get('revision') != revision or not receipt.get('files'):
        raise ValueError('Model receipt does not match the pinned profile')
    for name, expected in receipt['files'].items():
        path = (directory / name).resolve(strict=True)
        if not path.is_relative_to(directory) or not path.is_file() or digest(path) != expected:
            raise ValueError('Model inventory integrity check failed')
    return directory


def ace_parameters(request):
    seed = request.get('seed', secrets.randbelow(2**31))
    params = dict(caption=request['prompt'], lyrics=request.get('lyrics', ''),
        instrumental=request['instrumental'], duration=request['duration_seconds'],
        seed=seed, inference_steps=8, shift=1.0, task_type='text2music',
        thinking=False, use_cot_metas=False, use_cot_caption=False, use_cot_language=False,
        bpm=request.get('bpm'), keyscale=request.get('key', ''),
        timesignature=str(request.get('time_signature', '')))
    config = dict(batch_size=1, allow_lm_batch=False, use_random_seed=False,
                  seeds=[seed], audio_format='wav')
    return params, config


def validate_minimax_results(results):
    if len(results) != 1: raise ValueError('MiniMax must return one completed result')
    result = results[0]
    audio = result.audio
    if result.sample_rate != 44100 or len(audio.shape) != 2 or audio.shape[1] != 2 or not audio.shape[0]:
        raise ValueError('MiniMax output must be 44.1 kHz stereo')
    # Conversion occurs in the worker only; parent never imports numpy/MLX.
    import numpy as np
    if not np.isfinite(np.asarray(audio)).all(): raise ValueError('MiniMax output contains non-finite samples')
    return audio, result.sample_rate


def stable_arguments(request, output):
    args = ['--prompt', request['prompt'], '--dit', 'sm-music', '--decoder', 'same-s',
        '--seconds', str(request['duration_seconds']), '--steps', '8', '--cfg', '1.0',
        '--dit-dtype', 'fp16', '--free-models', '--out', str(output)]
    if 'seed' in request: args += ['--seed', str(request['seed'])]
    return args


def run_minimax(request, prepared, output, emit):
    for package, required in [('mlx-audio', '0.6.4'), ('mlx', '0.32.4'), ('transformers', '5.15.1')]:
        if importlib.metadata.version(package) != required: raise ValueError('MiniMax runtime lock mismatch')
    model_path = verify_receipt(prepared['model_path'], 'minimax-music3-mxfp8-local', MINIMAX_MODEL_REVISION)
    import mlx_audio
    package_root = Path(mlx_audio.__file__).parent
    for relative, expected in {'music/models/minimax_music3/minimax_music3.py': '303fc5d11c1c32c66478e6fbf713d32011ac5823993bf4edc5edae18c0acc23c', 'music/utils.py': '8ddb78f59dbaf9b9bbf2fb47d62b8c22d50fec6be1502a4954b2640f2b7dd48e'}.items():
        if digest(package_root / relative) != expected: raise ValueError('MiniMax music implementation source mismatch')
    from mlx_audio.music.utils import load_model
    from mlx_audio.audio_io import write
    emit('stage', stage='preparing')
    model = load_model(str(model_path))
    seed = request.get('seed', secrets.randbelow(2**31))
    emit('dispatch'); emit('stage', stage='generating')
    results = list(model.generate(text=request['prompt'], lyrics=request['lyrics'],
        duration=request['duration_seconds'], steps=30, seed=seed))
    audio, rate = validate_minimax_results(results)
    emit('stage', stage='writing_audio')
    write(output, audio, rate)
    return dict(seed=seed, steps=30, duration_semantics='ceiling', sample_rate=rate, channels=2)


def run_ace(request, prepared, output, emit):
    if sys.version_info[:2] != (3, 12): raise ValueError('ACE-Step requires the isolated Python 3.12 runtime')
    checkpoint = verify_receipt(prepared['checkpoints_dir'], 'acestep-v15-turbo-local', ACE_MODEL_REVISION)
    os.environ['ACESTEP_CHECKPOINTS_DIR'] = str(checkpoint)
    os.environ['ACESTEP_DISABLE_TQDM'] = '1'
    for component in ('acestep-v15-turbo', 'vae', 'Qwen3-Embedding-0.6B'):
        if not (checkpoint / component).is_dir(): raise ValueError('ACE-Step checkpoint is incomplete')
    from acestep.handler import AceStepHandler
    from acestep.inference import GenerationParams, GenerationConfig, generate_music
    from acestep.llm_inference import LLMHandler
    emit('stage', stage='preparing')
    # Upstream's generic preflight insists on its bundled 1.7B LM even when
    # thinking=False. This wrapper validates exactly the accepted components.
    private = output.parent / 'ace-checkpoints'
    private.mkdir()
    for component in ('acestep-v15-turbo', 'vae', 'Qwen3-Embedding-0.6B'):
        destination = private / component
        destination.mkdir()
        for source_file in (checkpoint / component).iterdir():
            if source_file.is_file(): (destination / source_file.name).symlink_to(source_file)
    import acestep
    for source_file in (Path(acestep.__file__).parent / 'models/turbo').glob('*.py'):
        target = private / 'acestep-v15-turbo' / source_file.name
        if target.is_symlink() or target.exists(): target.unlink()
        shutil.copyfile(source_file, target)
    os.environ['ACESTEP_CHECKPOINTS_DIR'] = str(private)
    handler = AceStepHandler()
    handler._ensure_models_present = lambda **kwargs: None
    handler._sync_model_code_if_needed = lambda *args: None
    _, success = handler.initialize_service(project_root=str(private.parent),
        config_path='acestep-v15-turbo', device='mps', use_flash_attention=False,
        compile_model=False, offload_to_cpu=True, use_mlx_dit=True)
    if not success: raise ValueError('ACE-Step model preparation failed')
    params, config = ace_parameters(request)
    emit('dispatch'); emit('stage', stage='generating')
    result = generate_music(handler, LLMHandler(), GenerationParams(**params),
        GenerationConfig(**config), save_dir=str(output.parent))
    if not result.success or len(result.audios) != 1: raise ValueError('ACE-Step did not return one completed result')
    path = Path(result.audios[0]['path']).resolve(strict=True)
    if not path.is_relative_to(output.parent.resolve()) or path.suffix.lower() != '.wav': raise ValueError('ACE-Step output escaped the private job directory')
    if path != output: shutil.copyfile(path, output)
    return dict(seed=params['seed'], steps=8, shift=1.0, thinking=False, sample_rate=48000, channels=2)


def run_stable(request, prepared, output, emit):
    source = Path(prepared['source_path']).resolve(strict=True)
    model_root = verify_receipt(prepared['model_path'], 'stable-audio-3-small-local', STABLE_MODEL_REVISION)
    script = source / 'optimized/mlx/scripts/sa3_mlx.py'
    if not script.is_file(): raise ValueError('Pinned Stable Audio MLX source is missing')
    sys.path.insert(0, str(script.parent))
    # Replace upstream's mutable auto-downloader before importing the pipeline.
    import weights
    def local_only(name, verbose=True):
        relative = weights.FLAT_MANIFEST.get(name)
        if not relative: raise ValueError('Unexpected Stable Audio model component')
        path = model_root / relative
        if not path.is_file(): raise ValueError('Prepared Stable Audio component is missing')
        return path
    weights.ensure_local = local_only
    weights.is_present = lambda name: name in weights.FLAT_MANIFEST and (model_root / weights.FLAT_MANIFEST[name]).is_file()
    # Upstream preflight includes the editing-only encoder: omit it for text-to-music.
    weights.DIT_BUNDLES['sm-music'] = [x for x in weights.DIT_BUNDLES['sm-music'] if 'encoder' not in x[0]]
    sys.argv = [str(script)] + stable_arguments(request, output)
    emit('dispatch'); emit('stage', stage='generating')
    runpy.run_path(str(script), run_name='__main__')
    return dict(steps=8, cfg_scale=1.0, free_models=True, sample_rate=44100, channels=2,
                **({'seed': request['seed']} if 'seed' in request else {}))


def main():
    # Only the supervisor-created stdin is accepted; no listening socket or UI.
    runtime = os.environ.get('NATIV_MUSIC_RUNTIME_ID')
    if '--runtime-id' in sys.argv:
        runtime = sys.argv[sys.argv.index('--runtime-id') + 1]
    if runtime not in RUNTIMES.values(): raise ValueError('A known runtime identity is required')
    stream = sys.stdout
    def emit(kind, **details):
        stream.write(json.dumps(dict(type=kind, **details), allow_nan=False) + '\n'); stream.flush()
    emit('handshake', protocol=1, worker='nativ-music', runtime_id=runtime)
    line = sys.stdin.buffer.readline(128 * 1024 + 1)
    if not line or len(line) > 128 * 1024: raise ValueError('Invalid bounded worker request')
    envelope = json.loads(line)
    provider = envelope['provider']
    if RUNTIMES.get(provider) != runtime: raise ValueError('Runtime/provider identity mismatch')
    if envelope.get('protocol') != 1 or envelope.get('type') != 'generate': raise ValueError('Worker protocol mismatch')
    output_dir = Path(envelope['output_dir']).resolve(strict=True)
    output = output_dir / 'candidate.wav'
    os.environ.update(HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1', HF_DATASETS_OFFLINE='1')
    try:
        if provider != 'acestep' and importlib.util.find_spec('mlx'):  # bound MLX's buffer cache (see nativ_video.workers)
            importlib.import_module('mlx.core').set_cache_limit(4 << 30)
        with contextlib.redirect_stdout(sys.stderr):
            effective = dict(acestep=run_ace, minimax_mlx=run_minimax, stable_audio_mlx=run_stable)[provider](
                envelope['request'], envelope.get('prepared', {}), output, emit)
        if not output.is_file(): raise ValueError('Worker returned no audio')
        mx = sys.modules.get('mlx.core')  # measured, never imported just for metrics
        emit('result', path=str(output), effective_parameters=effective,
             metadata={'runtime_id': runtime, 'sample_rate': effective['sample_rate'], 'channels': 2,
                       'mlx_peak_memory_bytes': mx.get_peak_memory() if mx else None,
                       'max_rss_bytes': resource.getrusage(resource.RUSAGE_SELF).ru_maxrss})
    except Exception:
        # Provider stack traces may contain prompt/filesystem details. Only safe codes cross the pipe;
        # the traceback goes to stderr, i.e. the private attempt worker.log.
        traceback.print_exc()
        emit('error', code='music_worker_failed', message='The music worker failed. Verify its pinned runtime and complete prepared model inventory.')
        return 1
    return 0


if __name__ == '__main__': sys.exit(main())
