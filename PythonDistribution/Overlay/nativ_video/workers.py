"""One-job inference workers using pinned public application APIs.

Importing this module is light. Model imports occur only after the supervisor
validated a managed runtime, a complete checkpoint receipt and compute admission.
An isolated process is recreated for every job; no freed denoiser is reused.
"""
from __future__ import annotations
import contextlib
import hashlib
import json
import os
from pathlib import Path
import sys

RUNTIMES={'ltx_mlx':'ltx-mlx-0.18.0','wan_mlx':'wan-mlx-gen-0.38.0','minimax_h3_mlx':'h3-mlx-vlm-0.7.12'}


def _validate(request,kind):
    w,h,f,fps=(request[x] for x in ('width','height','frame_count','fps'))
    mod,remainder,alignment=(8,1,64) if kind=='ltx_mlx' else (4,1,32) if kind=='wan_mlx' else (17,5,32)
    if any(type(x) is not int for x in (w,h,f,fps)) or w<=0 or h<=0 or w%alignment or h%alignment or f<=0 or f%mod!=remainder or fps!=24:
        raise ValueError('Invalid frozen temporal or spatial profile')
    if kind=='minimax_h3_mlx' and not 5<=f/fps<=15: raise ValueError('H3 duration is outside the validated runtime window')
    expected='silent' if kind=='wan_mlx' else 'native_generated'
    if request['audio_mode']!=expected: raise ValueError('Invalid fixed audio mode')


def run_ltx(request,prepared,output,emit):
    _validate(request,'ltx_mlx')
    from ltx_pipelines_mlx import DistilledPipeline
    emit('stage',stage='loading')
    pipeline=DistilledPipeline(model_dir=prepared['model_path'],low_memory=True,low_ram_streaming=False)
    emit('dispatch'); emit('stage',stage='generating')
    kwargs=dict(prompt=request['prompt'],output_path=str(output),width=request['width'],height=request['height'],
                num_frames=request['frame_count'],frame_rate=request['fps'],seed=request['seed'])
    first=prepared.get('inputs',{}).get('first_frame')
    if first: kwargs['image']=first
    # Keep upstream libx264 encoding and model-mandated CRF18 I2V preprocessing.
    # No unsupported audio toggle, TeaCache, prompt enhancement or fake step log parsing.
    pipeline.generate_and_save(**kwargs)
    return dict(width=request['width'],height=request['height'],frame_count=request['frame_count'],fps=request['fps'],
                seed=request['seed'],audio_mode='native_generated',audio_sample_rate=48000,
                audio_channels=2,pipeline='DistilledPipeline',video_decoder='conv',i2v_preprocess_crf=18 if first else None)


def run_wan(request,prepared,output,emit):
    _validate(request,'wan_mlx')
    from mflux.models.wan.variants.wan2_2_ti2v import Wan2_2_TI2V
    emit('stage',stage='loading')
    model=Wan2_2_TI2V(model_path=prepared['model_path'],quantize=8,keep_text_encoder_resident=False,prompt_embed_disk_cache=False)
    def progress(event):
        phase=str(event.phase)
        value=min(1,max(0,event.step/event.total_steps)) if event.total_steps>0 and phase in ('denoise','denoising','generate') else None
        emit('stage',stage=phase,progress=value,step=event.step,total_steps=event.total_steps)
    emit('dispatch'); emit('stage',stage='generating')
    result=model.generate_video(seed=request['seed'],prompt=request['prompt'],num_inference_steps=request['steps'],
        width=request['width'],height=request['height'],num_frames=request['frame_count'],fps=request['fps'],
        flow_shift=request['flow_shift'],image_path=prepared.get('inputs',{}).get('first_frame'),
        canvas_policy='exact-resize',resize_mode='resize',progress_callback=progress,release_denoisers_before_decode=True)
    emit('stage',stage='encoding')
    result.save(output,export_json_metadata=False,validate_health=True)
    return dict(width=request['width'],height=request['height'],frame_count=request['frame_count'],fps=request['fps'],
                seed=request['seed'],steps=request['steps'],flow_shift=request['flow_shift'],audio_mode='silent')


def run_h3(request,prepared,output,emit):
    if prepared.get('separate_license_approved') is not True:
        raise ValueError('H3 license eligibility must be established before loading')
    _validate(request,'minimax_h3_mlx')
    from mlx_vlm.generate import VideoGenerationRequest,load_video_generation_model,generate_video
    inputs=prepared.get('inputs',{})
    workflow='fl2va' if request['operation']=='image_to_video' else 't2va'
    emit('stage',stage='loading')
    model=load_video_generation_model(prepared['model_path'],workflow=workflow)
    def progress(stage,step,total_steps,num_frames):
        value=step/total_steps if total_steps>0 and stage in ('denoise','denoising') else None
        emit('stage',stage=stage,progress=value,step=step,total_steps=total_steps)
    req=VideoGenerationRequest(prompt=request['prompt'],seed=request['seed'],steps=request['steps'],
        width=request['width'],height=request['height'],num_frames=request['frame_count'],
        image=inputs.get('first_frame'),last_image=inputs.get('last_frame'),progress_callback=progress)
    emit('dispatch'); emit('stage',stage='generating')
    generate_video(model,req,output_path=output)
    return dict(width=request['width'],height=request['height'],frame_count=request['frame_count'],fps=24,
                seed=request['seed'],steps=request['steps'],audio_mode='native_generated',audio_sample_rate=32000,
                audio_channels=2,workflow=workflow)


def verify_prepared(prepared,request):
    """Validate the installer receipt and reject mutable downloads/escaped files."""
    root=Path(prepared['model_path']).resolve(strict=True)
    if not root.is_dir(): raise ValueError('Prepared local checkpoint directory is required')
    receipt=json.loads((root/'.nativ-video-receipt.json').read_text())
    if receipt.get('profile_id')!=request['model'] or receipt.get('model_revision')!=prepared.get('model_revision') or not receipt.get('components'):
        raise ValueError('Prepared model identity does not match the accepted profile')
    for component in receipt['components']:
        path=(root/component['path']).resolve(strict=True)
        if not path.is_relative_to(root) or not path.is_file() or path.stat().st_size!=component['size']:
            raise ValueError('Prepared model inventory is incomplete')
        # Full digest verification is performed by installation/repair and by
        # qualification. Stored mtime/size guards prevent a changed file being
        # mistaken for that validated immutable installation on dispatch.
        if path.stat().st_mtime_ns!=component.get('mtime_ns') or len(component.get('sha256',''))!=64:
            raise ValueError('A prepared checkpoint changed; repair before generation')
    codecs=prepared.get('codec_paths',{})
    ffmpeg=Path(codecs.get('ffmpeg','')); ffprobe=Path(codecs.get('ffprobe',''))
    if not ffmpeg.is_absolute() or not ffprobe.is_absolute() or not ffmpeg.is_file() or not ffprobe.is_file() or ffmpeg.parent!=ffprobe.parent:
        raise ValueError('Pinned managed encoders are required')
    os.environ['PATH']=str(ffmpeg.parent)+':/usr/bin:/bin'
    for role,path in prepared.get('inputs',{}).items():
        if role not in ('first_frame','last_frame') or not Path(path).is_file(): raise ValueError('Invalid prepared image reference')
    return root


def main():
    runtime=os.environ.get('NATIV_VIDEO_RUNTIME_ID')
    if '--runtime-id' in sys.argv: runtime=sys.argv[sys.argv.index('--runtime-id')+1]
    if runtime not in RUNTIMES.values(): raise ValueError('A known runtime identity is required')
    stream=sys.stdout
    def emit(kind,**details):
        stream.write(json.dumps(dict(type=kind,**details),allow_nan=False)+'\n'); stream.flush()
    emit('handshake',protocol=1,worker='nativ-video',runtime_id=runtime)
    line=sys.stdin.buffer.readline(128*1024+1)
    if not line or len(line)>128*1024: return 1
    try:
        envelope=json.loads(line)
        if envelope.get('protocol')!=1 or envelope.get('type')!='generate' or RUNTIMES.get(envelope.get('provider'))!=runtime: raise ValueError('Worker protocol mismatch')
        output_dir=Path(envelope['output_dir']).resolve(strict=True)
        if not output_dir.is_dir(): raise ValueError('A managed output directory is required')
        output=output_dir/'candidate.mp4'
        prepared=envelope.get('prepared',{}); request=envelope['request']
        verify_prepared(prepared,request)
        os.environ.update(HF_HUB_OFFLINE='1',TRANSFORMERS_OFFLINE='1',HF_DATASETS_OFFLINE='1',HF_HUB_DISABLE_TELEMETRY='1')
        with contextlib.redirect_stdout(sys.stderr):
            effective={'ltx_mlx':run_ltx,'wan_mlx':run_wan,'minimax_h3_mlx':run_h3}[envelope['provider']](request,prepared,output,emit)
        if not output.is_file() or output.is_symlink() or output.stat().st_size==0: raise ValueError('Runtime returned no output candidate')
        emit('result',path=str(output),effective_parameters=effective,metadata={'runtime_id':runtime,'requires_canonical_media_probe':True})
    except Exception:
        emit('error',code='video_worker_failed',message='The video runtime failed. Verify its pinned dependencies, checkpoint inventory and managed encoder.')
        return 1
    return 0

if __name__=='__main__': sys.exit(main())
