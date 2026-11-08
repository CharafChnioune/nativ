"""Canonical music decoding through the source-pinned managed media programs.

No SoundFile/numpy dependency is required in the base Nativ environment. Decode
all samples with bounded buffers; retain original compressed bytes independently.
"""
from __future__ import annotations
import array
import json
import math
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
from threading import Event
import time
from .contracts import GenerationCancelled,GenerationError

MAX_ORIGINAL_BYTES=1024**3
MAX_DECODED_BYTES=1024**3
MAX_PROBE_BYTES=1024*1024
DECODE_TIMEOUT_SECONDS=120


def failure(code='invalid_media',message='The audio could not be completely decoded by the managed media runtime.'):
    return GenerationError(code,message,status=502)


def check(cancel):
    if cancel is not None and cancel.is_set():raise GenerationCancelled()


def _stream(command,cancel,consume,*,limit,timeout=DECODE_TIMEOUT_SECONDS):
    check(cancel)
    # Exact absolute programs are supplied by the verified runtime manager. No
    # user's PATH, vendor key or dynamic-library override enters this decoder.
    environment={key:value for key,value in os.environ.items() if key in ('HOME','TMPDIR','LANG')}
    environment['PATH']='/usr/bin:/bin:/usr/sbin:/sbin'
    process=subprocess.Popen(command,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
        start_new_session=True,env=environment,bufsize=0)
    selector=selectors.DefaultSelector()
    selector.register(process.stdout,selectors.EVENT_READ,'out');selector.register(process.stderr,selectors.EVENT_READ,'err')
    os.set_blocking(process.stdout.fileno(),False);os.set_blocking(process.stderr.fileno(),False)
    counts={'out':0,'err':0};started=time.monotonic()
    try:
        while selector.get_map():
            check(cancel)
            if time.monotonic()-started>timeout:raise failure('audio_decode_timeout','Audio validation exceeded its bounded execution time.')
            for key,_ in selector.select(.1):
                block=os.read(key.fd,65536)
                if not block:selector.unregister(key.fileobj);continue
                counts[key.data]+=len(block)
                if counts[key.data]>(limit if key.data=='out' else 128*1024):
                    raise failure('audio_decode_limit','Audio validation exceeded its decoded-data or diagnostic limit.')
                if key.data=='out':consume(block)
        if process.wait(timeout=5)!=0:raise failure()
        check(cancel)
        return counts['out']
    finally:
        selector.close()
        if process.poll() is None:
            try:os.killpg(process.pid,signal.SIGTERM)
            except ProcessLookupError:pass
            except PermissionError:
                # This managed program does not spawn child processes. Some
                # macOS hosts restrict group signalling but permit owned-PID stop.
                try:process.terminate()
                except ProcessLookupError:pass
            try:process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                try:os.killpg(process.pid,signal.SIGKILL)
                except ProcessLookupError:pass
                except PermissionError:
                    try:process.kill()
                    except ProcessLookupError:pass
                process.wait(timeout=5)
        process.stdout.close();process.stderr.close()


def probe_audio(path,codec_paths,cancellation=None):
    """Return measured rate/channels/frames/duration and <=256 real peak bins."""
    codec_paths=codec_paths or {}
    programs={name:Path(codec_paths.get(name,'')) for name in ('ffmpeg','ffprobe')}
    if any(not program.is_absolute() or program.is_symlink() or not program.is_file() for program in programs.values()):
        raise GenerationError('codec_unavailable','Repair the managed FFmpeg/FFprobe runtime before importing encoded music.',status=503)
    check(cancellation)
    path=Path(path)
    if path.is_symlink() or not path.is_file() or not 0<path.stat().st_size<=MAX_ORIGINAL_BYTES:raise failure()
    raw=bytearray()
    _stream([str(programs['ffprobe']),'-v','error','-show_streams','-show_format','-of','json',str(path)],
        cancellation,raw.extend,limit=MAX_PROBE_BYTES)
    try:
        metadata=json.loads(raw)
        streams=metadata['streams'];audio=[item for item in streams if item.get('codec_type')=='audio']
        if len(audio)!=1 or any(item.get('codec_type') not in ('audio',) for item in streams):raise ValueError()
        rate=int(audio[0]['sample_rate']);channels=int(audio[0]['channels'])
        if not 8000<=rate<=192000 or channels not in (1,2):raise ValueError()
        container=metadata['format']['format_name'];codec=audio[0]['codec_name']
        if container not in ('wav','mp3','flac','ogg','mov,mp4,m4a,3gp,3g2,mj2'):raise ValueError()
    except (ValueError,TypeError,KeyError,OverflowError):raise failure() from None
    peaks=[];window_samples=2048*channels;window_count=0;window_peak=0.0;maximum=0.0;sample_count=0;carry=b''
    def consume(block):
        nonlocal carry,window_samples,window_count,window_peak,maximum,sample_count
        block=carry+block;aligned=len(block)-len(block)%4;carry=block[aligned:]
        samples=array.array('f');samples.frombytes(block[:aligned])
        if sys.byteorder!='little':samples.byteswap()
        for value in samples:
            if not math.isfinite(value):raise failure('nonfinite_audio','The provider returned audio containing non-finite samples.')
            absolute=abs(value);maximum=max(maximum,absolute);window_peak=max(window_peak,absolute)
            sample_count+=1;window_count+=1
            if window_count==window_samples:
                peaks.append(window_peak);window_count=0;window_peak=0.0
                if len(peaks)==512:
                    peaks[:]=[max(peaks[index:index+2]) for index in range(0,len(peaks),2)]
                    window_samples*=2
    _stream([str(programs['ffmpeg']),'-nostdin','-v','error','-xerror','-i',str(path),'-map','0:a:0','-vn',
        '-acodec','pcm_f32le','-f','f32le','-'],cancellation,consume,limit=MAX_DECODED_BYTES)
    if carry or sample_count%channels or not sample_count or maximum==0:raise failure()
    if window_count:peaks.append(window_peak)
    while len(peaks)>256:peaks[:]=[max(peaks[index:index+2]) for index in range(0,len(peaks),2)]
    frames=sample_count//channels
    return dict(sample_rate=rate,channels=channels,frame_count=frames,duration_seconds=frames/rate,
                waveform=peaks,peak=maximum,codec=codec,container=container)
