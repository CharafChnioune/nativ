"""Canonical importer hook: actual decoded media is required before publication."""
from __future__ import annotations
import array
from fractions import Fraction
import hashlib
import json
import math
from pathlib import Path
import selectors
import os
import signal
import subprocess
import time
from nativ_generation.contracts import GenerationError,GenerationCancelled


def _error(message,code='invalid_video'):
    raise GenerationError(code,message,status=502)


def _number(value):
    try:
        n=float(value)
        if not math.isfinite(n) or n<=0: raise ValueError()
        return n
    except (ValueError,TypeError,OverflowError): _error('The video contains invalid or unknown timing metadata.')


def _rate(value):
    try:
        n=Fraction(value)
        if n<=0 or n>240: raise ValueError()
        return n
    except (ValueError,TypeError,ZeroDivisionError): _error('The video has an invalid frame rate.')


def validate_probe(data,accepted):
    streams=data.get('streams',[])
    videos=[s for s in streams if s.get('codec_type')=='video']
    audios=[s for s in streams if s.get('codec_type')=='audio']
    if len(videos)!=1 or len(audios)>1: _error('Expected one video stream and at most one audio stream.')
    v=videos[0]; fmt=data.get('format',{})
    if 'mp4' not in fmt.get('format_name','').split(','): _error('The candidate is not an MP4 container.')
    if v.get('codec_name')!='h264' or v.get('pix_fmt') not in ('yuv420p','yuvj420p'):
        _error('The candidate does not match the qualified SDR H.264 playback profile.')
    try:
        width=int(v['width']); height=int(v['height']); frames=int(v['nb_read_frames'])
        if width<=0 or height<=0 or width*height>40_000_000 or frames<=0 or frames>36000: raise ValueError()
    except (KeyError,TypeError,ValueError): _error('Actual decoded frame count and dimensions are required.')
    rotation=next((x.get('rotation',0) for x in v.get('side_data_list',[]) if 'rotation' in x),0)
    if rotation or v.get('tags',{}).get('rotate','0') not in ('0',0,None): _error('Unexpected display rotation in the generated video.')
    if v.get('sample_aspect_ratio','1:1') not in ('1:1','1/1','N/A'): _error('The generated video has non-square pixels.')
    if v.get('color_transfer') in ('smpte2084','arib-std-b67'): _error('HDR output is outside the qualified SDR profile.')
    fps=_rate(v.get('avg_frame_rate')); nominal=_rate(v.get('r_frame_rate',v.get('avg_frame_rate')))
    duration=_number(v.get('duration',fmt.get('duration')))
    container_duration=_number(fmt.get('duration',duration))
    frame_tolerance=1/float(fps)+0.000001
    try: priming=1024/int(audios[0]['sample_rate']) if audios else 0
    except (KeyError,ValueError,TypeError,ZeroDivisionError): _error('Invalid soundtrack sample-rate metadata.')
    tolerance=frame_tolerance+priming
    def start_time(stream):
        try:
            n=float(stream.get('start_time',0))
            if not math.isfinite(n):raise ValueError()
            return n
        except (ValueError,TypeError): _error('Invalid media stream start timestamp.')
    video_start=start_time(v)
    if abs(duration-frames/float(fps))>frame_tolerance: _error('Decoded frames and stream duration disagree.')
    if abs(container_duration-duration)>tolerance: _error('Container and video duration disagree.')
    for key,value in (('width',width),('height',height),('frame_count',frames)):
        expected=accepted.get(key)
        if expected is not None and value!=expected: _error('The output '+key+' differs from the accepted request.','output_constraint_mismatch')
    expected_fps=accepted.get('fps')
    if expected_fps is not None and abs(float(fps)-float(expected_fps))>0.0001:
        _error('The output frame rate differs from the accepted request.','output_constraint_mismatch')
    if accepted.get('duration') is not None and abs(duration-accepted['duration'])>tolerance:
        _error('The output duration differs from the accepted provider constraint.','output_constraint_mismatch')
    audio=None
    if audios:
        a=audios[0]
        try:
            sample_rate=int(a['sample_rate']); channels=int(a['channels'])
            if sample_rate<=0 or sample_rate>192000 or channels not in (1,2): raise ValueError()
        except (KeyError,ValueError,TypeError): _error('The soundtrack metadata is invalid.')
        audio_duration=_number(a.get('duration',fmt.get('duration')))
        if abs(start_time(a)-video_start)>tolerance: _error('The audio/video start timestamps do not align.')
        if abs(audio_duration-duration)>tolerance: _error('The soundtrack and video timelines do not align.')
        if accepted.get('audio_sample_rate') is not None and sample_rate!=accepted['audio_sample_rate']:
            _error('The soundtrack sample rate differs from the native provider contract.')
        if accepted.get('audio_mode')=='native_generated' and channels!=2: _error('Native generated audio must retain its stereo channels.')
        if a.get('codec_name')!='aac': _error('The soundtrack is not qualified AAC audio.')
        audio=dict(codec=a['codec_name'],sample_rate=sample_rate,channels=channels,duration=audio_duration)
    if accepted.get('audio_mode')=='native_generated' and not audio: _error('Native audio was requested but the output has no soundtrack.','missing_audio')
    if accepted.get('audio_mode')=='silent' and audio: _error('Silent output unexpectedly contains an audio stream.','unexpected_audio')
    return dict(container='mp4',codec=v['codec_name'],pixel_format=v['pix_fmt'],width=width,height=height,
                frame_count=frames,fps={'numerator':fps.numerator,'denominator':fps.denominator},
                nominal_fps={'numerator':nominal.numerator,'denominator':nominal.denominator},
                duration=duration,container_duration=container_duration,audio=audio,
                color={k:v.get(k) for k in ('color_space','color_transfer','color_primaries','color_range')},rotation=0,start_time=video_start,audio_video_tolerance_seconds=tolerance)


def _run(command,*,limit=1024*1024,timeout=120,cancellation=None):
    """Bound subprocess output while reading; capture_output alone is unbounded."""
    if cancellation is not None and cancellation.is_set():raise GenerationCancelled()
    environment={k:v for k,v in os.environ.items() if k in ('HOME','TMPDIR','LANG')}
    environment['PATH']='/usr/bin:/bin'
    proc=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,stdin=subprocess.DEVNULL,start_new_session=True,env=environment)
    sel=selectors.DefaultSelector(); sel.register(proc.stdout,selectors.EVENT_READ,'out'); sel.register(proc.stderr,selectors.EVENT_READ,'err')
    outputs={'out':bytearray(),'err':bytearray()}; started=time.monotonic()
    try:
        while sel.get_map():
            if cancellation is not None and cancellation.is_set():raise GenerationCancelled()
            if time.monotonic()-started>timeout: _error('Media validation exceeded its time limit.','media_probe_timeout')
            for key,_ in sel.select(0.2):
                chunk=key.fileobj.read1(65536)
                if not chunk: sel.unregister(key.fileobj); continue
                target=outputs[key.data]; target.extend(chunk)
                if len(target)>(limit if key.data=='out' else 128*1024): _error('Media validation exceeded its bounded output limit.')
        if proc.wait(timeout=5)!=0: _error('The candidate could not be decoded by the managed media runtime.')
        return bytes(outputs['out'])
    finally:
        sel.close()
        if proc.poll() is None:
            try:os.killpg(proc.pid,signal.SIGTERM)
            except ProcessLookupError:pass
            try:proc.wait(timeout=1)
            except subprocess.TimeoutExpired:
                try:os.killpg(proc.pid,signal.SIGKILL)
                except ProcessLookupError:pass
                proc.wait(timeout=5)
        proc.stdout.close(); proc.stderr.close()


def probe(path,accepted,codec_paths,*,cancellation=None):
    """Probe/decode bounded media with explicit managed codec paths, never PATH."""
    path=Path(path)
    if path.is_symlink() or not path.is_file() or not 0<path.stat().st_size<=2*1024**3: _error('The output candidate is missing, unsafe or empty.')
    ffmpeg=Path(codec_paths.get('ffmpeg','')); ffprobe=Path(codec_paths.get('ffprobe',''))
    if not ffmpeg.is_absolute() or not ffprobe.is_absolute() or not ffmpeg.is_file() or not ffprobe.is_file():
        _error('The managed FFmpeg/FFprobe runtime is unavailable. Repair the video runtime.','codec_unavailable')
    raw=_run([str(ffprobe),'-v','error','-count_frames','-show_streams','-show_format','-of','json',str(path)],cancellation=cancellation)
    try: data=json.loads(raw)
    except (ValueError,UnicodeError): _error('The media probe returned invalid metadata.')
    measured=validate_probe(data,accepted)
    last=measured['frame_count']-1; mid=last//2
    select=f'select=eq(n\\,0)+eq(n\\,{mid})+eq(n\\,{last})'
    decoded=_run([str(ffmpeg),'-v','error','-xerror','-i',str(path),'-map','0:v:0','-vf',select,'-fps_mode','passthrough','-f','framemd5','-'],cancellation=cancellation)
    lines=[line for line in decoded.splitlines() if line and not line.startswith(b'#')]
    if len(lines)!=len({0,mid,last}): _error('Representative first, middle and last frames could not all be decoded.')
    measured['decoded_frame_samples']=[0,mid,last]
    if measured['audio']:
        audio=_run([str(ffmpeg),'-v','error','-xerror','-i',str(path),'-map','0:a:0','-vn','-acodec','pcm_f32le','-f','f32le','-'],limit=64*1024*1024,cancellation=cancellation)
        if not audio or len(audio)%4: _error('The soundtrack could not be decoded.','invalid_audio')
        samples=array.array('f'); samples.frombytes(audio)
        if any(not math.isfinite(n) for n in samples): _error('The soundtrack contains nonfinite samples.','invalid_audio')
        energy=sum(float(n)*n for n in samples)/len(samples)
        if energy<=1e-12 and accepted.get('audio_mode')=='native_generated': _error('The requested native soundtrack is empty or silent.','invalid_audio')
        actual_duration=len(samples)/(measured['audio']['channels']*measured['audio']['sample_rate'])
        if abs(actual_duration-measured['duration'])>measured['audio_video_tolerance_seconds']:
            _error('Decoded soundtrack length does not match the video timeline.','invalid_audio')
        measured['audio'].update(decoded_samples=len(samples),finite=True,rms=math.sqrt(energy))
    digest=hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda:f.read(1024*1024),b''): digest.update(chunk)
    measured.update(sha256=digest.hexdigest(),byte_size=path.stat().st_size,validated=True)
    return measured
