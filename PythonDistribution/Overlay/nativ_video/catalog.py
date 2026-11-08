"""Versioned, curated video profiles. Qualification is evidence, not code presence."""
from __future__ import annotations
from copy import deepcopy
import hashlib
import json

LTX_REVISION = '747b30ef10e92a011e85b2aa0f6c4ee86ced5218'
WAN_REVISION = '99fb94dd3eaa9dd1931cd3cd8eae1ae3e20f2ef3'
LTX_Q8_REVISION = '746ca9aacb697d2c739f544d68b584214dedcc75'
LTX_Q4_REVISION = 'e9a20add8c5937fcab635fb8e7a52926487a5776'
WAN_MODEL_REVISION = '6875952a110b6bdbcfc00d72b1d89a8e02ab0fc3'


def _profile(id, provider, model, runtime, defaults, capabilities, *, revision=None):
    title=('LTX 2.5 Distilled Q'+str(8 if 'q8' in id else 4)+' (Local)') if provider=='ltx_mlx' else 'Wan 2.2 TI2V-5B mixed Q8 (Local)' if provider=='wan_mlx' else 'MiniMax H3 (License gated)' if provider=='minimax_h3_mlx' else 'Runway Gen-4.5' if provider=='runway' else model.replace('ltx-','LTX ').replace('-',' ').title()+' (Cloud)'
    p = dict(id=id, modality='video', provider=provider,
             deployment='local' if runtime else 'hosted', display_name=title,
             model=model, model_revision=revision, runtime=runtime,
             qualification='unqualified', defaults=defaults, capabilities=capabilities)
    p['profile_revision'] = 'video-v1-' + hashlib.sha256(json.dumps(p,sort_keys=True,separators=(',',':')).encode()).hexdigest()[:24]
    return p


def profiles():
    """No downloads, filesystem discovery, credentials or heavy optional imports."""
    common = dict(operations=['text_to_video','image_to_video'],
                  input_formats=['image/png','image/jpeg','image/webp'],
                  max_input_bytes=25*1024*1024, max_input_pixels=40_000_000,
                  input_transform_version=1, output_containers=['mp4'],
                  output_codecs=['h264'], progress='stage', preview=False,
                  output_count=1, negative_prompt=False,retrieval_supported=False)
    result=[]
    for bits, revision in ((8,LTX_Q8_REVISION),(4,LTX_Q4_REVISION)):
        result.append(_profile(f'ltx-2.5-distilled-q{bits}-local','ltx_mlx',f'dgrauet/ltx-2.5-mlx-q{bits}',
            'ltx-mlx-0.18.0', dict(output_preset='draft-landscape',audio_mode='native_generated'),
            dict(common, input_roles=['first_frame'],audio_modes=['native_generated'],
                 audio_sample_rate=48000,audio_channels=2,frame_grid={'modulus':8,'remainder':1},
                 spatial_alignment=64,fps=[24],seed=True,cancellation='owned_process',
                 pipeline='DistilledPipeline', runtime_revision=LTX_REVISION,
                 presets={'draft-landscape':{'width':704,'height':448,'frame_count':97,'fps':24},
                          'draft-portrait':{'width':448,'height':704,'frame_count':97,'fps':24}},
                 gate='runtime_checkpoint_license_and_hardware_qualification'), revision=revision))
    result.append(_profile('wan2.2-ti2v-5b-q8-local','wan_mlx','AbstractFramework/wan2.2-ti2v-5b-diffusers-8bit',
        'wan-mlx-gen-0.38.0',dict(output_preset='wan-draft-landscape',audio_mode='silent'),
        dict(common,input_roles=['first_frame'],audio_modes=['silent'],audio_sample_rate=None,
             frame_grid={'modulus':4,'remainder':1},spatial_alignment=32,fps=[24],seed=True,
             cancellation='owned_process',runtime_revision=WAN_REVISION,
             quantization='mixed q8 transformer; text encoder and VAE retain source precision',
             presets={'wan-draft-landscape':{'width':832,'height':480,'frame_count':81,'fps':24,'steps':50,'flow_shift':3},
                      'wan-draft-portrait':{'width':480,'height':832,'frame_count':81,'fps':24,'steps':50,'flow_shift':3}},
             gate='runtime_checkpoint_and_hardware_qualification'),revision=WAN_MODEL_REVISION))
    result.append(_profile('minimax-h3-local','minimax_h3_mlx','MiniMaxAI/MiniMax-H3','h3-mlx-vlm-0.7.12',
        dict(output_preset='h3-draft-landscape',audio_mode='native_generated'),
        dict(common,input_roles=['first_frame','last_frame'],audio_modes=['native_generated'],
             audio_sample_rate=32000,audio_channels=2,frame_grid={'modulus':17,'remainder':5},
             spatial_alignment=32,fps=[24],seed=True,cancellation='owned_process',
             presets={'h3-draft-landscape':{'width':832,'height':480,'frame_count':124,'fps':24,'steps':30}},
             gate='separate_territorial_license_and_hardware_qualification',
             excluded_territories=['EU','UK','Republic of Korea','USA'],
             license_date='2026-08-02')))
    for version in ('2-5','2-3'):
        for tier in ('fast','pro'):
            model=f'ltx-{version}-{tier}'
            result.append(_profile(f'{model}-cloud','ltx_cloud',model,None,
                dict(output_preset='cloud-landscape',audio_mode='native_generated',duration=6),
                dict(common,retrieval_supported=True,input_roles=['first_frame','last_frame'],audio_modes=['silent','native_generated'],
                     max_input_bytes=15_000_000,fps=[24,25,48,50],seed=False,
                     cancellation='unconfirmed',poll_min_seconds=5,
                     presets={'cloud-landscape':{'width':1280,'height':720,'fps':24,'duration_options':list(range(6,21,2)) if tier=='fast' else [6,8,10]},
                              'cloud-portrait':{'width':720,'height':1280,'fps':24,'duration_options':list(range(6,21,2)) if tier=='fast' else [6,8,10]}},
                     duration_semantics='provider_seconds',gate='explicit_enabled_account_and_remote_consent',
                     source='https://docs.ltx.io/models/ltx-'+version,verified_at='2026-11-08',
                     pricing={'currency':'USD','basis':'generated_seconds','usd_per_second':(0.09 if tier=='fast' else 0.12) if version=='2-5' else (0.03 if tier=='fast' else 0.04),'resolution':'720p','verified_at':'2026-11-08','source':'https://docs.ltx.io/pricing'})))
    result.append(_profile('runway-gen4.5','runway','gen4.5',None,
        dict(output_preset='cloud-landscape',audio_mode='silent',duration=5),
        dict(common,retrieval_supported=True,input_roles=['first_frame'],audio_modes=['silent'],seed=True,fps=None,
             max_prompt_utf16_units=1000,poll_min_seconds=5,cancellation='provider_best_effort',
             duration_range=[2,10],duration_semantics='provider_seconds',
             presets={'cloud-landscape':{'width':1280,'height':720,'fps':None,'duration_options':list(range(2,11))},
                      'cloud-portrait':{'width':720,'height':1280,'fps':None,'duration_options':list(range(2,11))},
                      'cloud-square':{'width':960,'height':960,'fps':None,'operation':'image_to_video','duration_options':list(range(2,11))}},
             pricing={'credits_per_second':12,'usd_per_credit':0.01,'verified_at':'2026-11-08',
                      'source':'https://docs.dev.runwayml.com/guides/pricing/'},
             gate='explicit_enabled_account_and_remote_consent')))
    return deepcopy(result)
