"""Curated immutable music contracts. Readiness is computed by the host."""
from copy import deepcopy

ACE_REV = 'ca1e85fe9430179831e6bc6be790c332190a3866'
MINIMAX_REV = 'ecd43b9f5af55982f4e1bd810d7b60cbc3dfae23'
STABLE_REV = '790793b89ddceea612be9ce42ff6830d18f6fa57'


def _profile(identifier, provider, deployment, name, model, runtime, *, duration=None,
             seed=False, vocals=True, lyrics=True, formats=('wav',), rate=44100,
             qualification='unqualified', defaults=None, attribution=None, options=()):
    return dict(id=identifier, modality='music', provider=provider, deployment=deployment,
        profile_revision=f'{provider}:{2 if provider == "lyria" else 1}:{runtime or "2026-11-08"}', display_name=name,
        model=model, runtime=runtime, qualification=qualification,
        capabilities=dict(operations=['text_to_music'], vocals=vocals, instrumental=True,
            lyrics=lyrics, lyrics_required_for_vocals=lyrics and provider != 'lyria',
            instrumental_semantics='prompt_hint' if provider in ('lyria', 'stable_audio_cloud', 'stable_audio_mlx') else 'lyric_instruction' if provider in ('minimax_mlx', 'minimax_remote') else 'native',
            duration=duration or {'semantics': 'prompt_only', 'minimum': None, 'maximum': None},
            seed=seed, output_formats=list(formats), sample_rates=[rate], channels=[2],
            reference_input=False, preview_audio=False, progress='stage',
            retrieval_supported=provider in ('stable_audio_cloud','lyria'),
            provider_storage='Requests and generated interactions are stored by the configured Google account for retrieval; provider retention terms apply.' if provider=='lyria' else None,
            cancellation='owned_process' if deployment == 'local' else 'observation_only',
            options=list(options), attribution=attribution),
        defaults=dict(instrumental=True, output_format=formats[0], **(defaults or {})))


def profiles():
    """No network, filesystem probing, optional imports or model loads."""
    return deepcopy([
        _profile('acestep-v15-turbo-local', 'acestep', 'local', 'ACE-Step 1.5 Turbo',
            'ACE-Step/Ace-Step1.5', 'acestep-1.5-ca1e85f',
            duration={'semantics': 'target', 'minimum': 10, 'maximum': 60}, seed=True, rate=48000,
            defaults={'duration_seconds': 30, 'steps': 8, 'shift': 1.0}, options=('bpm', 'key', 'time_signature')),
        _profile('minimax-music3-mxfp8-local', 'minimax_mlx', 'local', 'MiniMax-Music3 · MLX MXFP8',
            'mlx-community/MiniMax-Music3-mxfp8', 'minimax-music3-mlx-0.6.4',
            duration={'semantics': 'ceiling', 'minimum': 1, 'maximum': 60}, seed=True,
            qualification='experimental', defaults={'duration_seconds': 30, 'steps': 30},
            attribution='MiniMax-Music3'),
        _profile('stable-audio-3-small-local', 'stable_audio_mlx', 'local', 'Stable Audio 3 Small Music',
            'stabilityai/stable-audio-3-small-music', 'stable-audio-3-mlx-790793b', vocals=False, lyrics=False,
            duration={'semantics': 'exact', 'minimum': 1, 'maximum': 120}, seed=True,
            defaults={'duration_seconds': 30, 'steps': 8}, attribution='Powered by Stability AI'),
        _profile('minimax-music3-remote-gpu', 'minimax_remote', 'remote_gpu', 'MiniMax-Music3 · Remote GPU',
            'MiniMaxAI/MiniMax-Music3', None, seed=True, rate=32000,
            duration={'semantics': 'ceiling', 'minimum': 1, 'maximum': 30},
            qualification='experimental', defaults={'duration_seconds': 30}, attribution='MiniMax-Music3'),
        _profile('minimax-music3-cloud', 'minimax_cloud', 'hosted', 'MiniMax Music 3 · Existing eligible accounts',
            'music-3.0', None, formats=('mp3', 'wav'), attribution='MiniMax-Music3'),
        _profile('lyria-3.5-hosted', 'lyria', 'hosted', 'Google Lyria 3.5', 'lyria-3.5', None, formats=('mp3',)),
        _profile('stable-audio-3-cloud', 'stable_audio_cloud', 'hosted', 'Stable Audio 3.0 · Hosted',
            'stable-audio-3', None, seed=True, vocals=False, lyrics=False, formats=('mp3', 'wav'),
            duration={'semantics': 'target', 'minimum': 1, 'maximum': 380}, defaults={'duration_seconds': 30},
            attribution='Powered by Stability AI'),
    ])
