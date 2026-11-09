#!/usr/bin/env python3
"""Build and locate Nativ's source-pinned standalone codec programs.

FFmpeg/libx264 run as separate executables. Corresponding source archives,
configuration, toolchain identity and license texts accompany the binaries.
No inference weights, runtime pip install or Homebrew library lookup is used.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import shutil
import subprocess
import sys
import tarfile
from threading import Event
import time
import urllib.request

ROOT=Path(__file__).resolve().parent
MANIFEST=ROOT/'manifest.json'
ID='ffmpeg-9.0.2-x264-b3560'


def digest(path):
    result=hashlib.sha256()
    with Path(path).open('rb') as source:
        for chunk in iter(lambda:source.read(1024*1024),b''):result.update(chunk)
    return result.hexdigest()


def extract(archive,destination):
    destination=Path(destination);destination.mkdir(parents=True,exist_ok=True)
    with tarfile.open(archive) as source:
        members=source.getmembers()
        for member in members:
            path=PurePosixPath(member.name)
            if path.is_absolute() or '..' in path.parts or not (member.isdir() or member.isfile()) or member.size>1024**3:
                raise ValueError('Unsafe codec source archive member')
        for member in members:
            parts=PurePosixPath(member.name).parts[1:]
            if not parts:continue
            target=destination.joinpath(*parts)
            if not target.resolve().is_relative_to(destination.resolve()):raise ValueError('Codec source escaped root')
            if member.isdir():target.mkdir(parents=True,exist_ok=True)
            else:
                target.parent.mkdir(parents=True,exist_ok=True)
                with source.extractfile(member) as stream,target.open('wb') as output:shutil.copyfileobj(stream,output)
                target.chmod(member.mode & 0o777)


def fetch(source,cache,cancel,emit):
    target=cache/source['filename'];cache.mkdir(parents=True,exist_ok=True)
    if target.is_file() and target.stat().st_size==source['bytes'] and digest(target)==source['sha256']:return target
    partial=target.with_suffix(target.suffix+'.partial')
    if partial.is_symlink() or target.is_symlink():raise ValueError('Unsafe codec cache target')
    count=0
    with urllib.request.urlopen(source['url'],timeout=30) as response,partial.open('wb') as output:
        while True:
            if cancel.is_set():raise InterruptedError('Codec build cancelled')
            chunk=response.read(1024*1024)
            if not chunk:break
            count+=len(chunk)
            if count>source['bytes']:raise ValueError('Codec source exceeded pinned size')
            output.write(chunk);emit('downloading',count/source['bytes'])
    if count!=source['bytes'] or digest(partial)!=source['sha256']:raise ValueError('Codec source integrity check failed')
    partial.replace(target);return target


def run(command,cwd,env,cancel,log):
    with log.open('ab') as output:
        output.write(('\nCOMMAND '+json.dumps(command)+'\n').encode());output.flush()
        process=subprocess.Popen(command,cwd=cwd,env=env,stdout=output,stderr=subprocess.STDOUT,start_new_session=True)
        while process.poll() is None:
            if cancel.wait(.2):
                import signal
                os.killpg(process.pid,signal.SIGTERM)
                try:process.wait(5)
                except subprocess.TimeoutExpired:os.killpg(process.pid,signal.SIGKILL);process.wait()
                raise InterruptedError('Codec build cancelled')
        if process.returncode:raise RuntimeError('Codec build command failed; inspect '+str(log))


def _pkg_config(prefix,target):
    # The build has one permitted external codec. No host pkg-config/Cellar
    # discovery is needed, and static flags cannot pick unrelated libraries.
    import shlex
    script='''#!/usr/bin/python3
import sys
args=sys.argv[1:]
if '--version' in args:print('1.0.0');sys.exit(0)
if not any('x264' in value for value in args):sys.exit(1)
if '--cflags' in args:print(CFLAGS)
if '--libs' in args:print(LIBS)
if '--modversion' in args:print('0.165.3222')
'''.replace('CFLAGS',repr('-I'+shlex.quote(str(prefix/'include')))).replace('LIBS',repr('-L'+shlex.quote(str(prefix/'lib'))+' -lx264 -lpthread'))
    target.write_text(script);target.chmod(0o755)


def codec_paths(resources):
    """Return only the hash-receipted packaged programs. Never search PATH."""
    resources=Path(resources).resolve()
    managed=resources/'CodecRuntime/managed'
    if managed.is_symlink() or (resources/'CodecRuntime').is_symlink() or not managed.is_dir() or not managed.resolve().is_relative_to(resources):raise ValueError('Managed codec runtime is not installed')
    receipt_path=managed/'receipt.json'
    if not receipt_path.is_file() or receipt_path.is_symlink():raise ValueError('Managed codec receipt is missing')
    receipt=json.loads(receipt_path.read_text())
    if receipt.get('id')!=ID:raise ValueError('Managed codec identity mismatch')
    result={}
    for name in ('ffmpeg','ffprobe'):
        relative='bin/'+name;path=managed/relative
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(managed.resolve()):raise ValueError('Unsafe managed codec program')
        if digest(path)!=receipt.get('files',{}).get(relative):raise ValueError('Managed codec integrity mismatch')
        result[name]=str(path.resolve())
    return result


def refresh_signed_receipt(resources):
    """Called only by the trusted build phase after successful nested signing.

    The eventual app/framework resource seal authenticates this updated receipt.
    Original build hashes remain available for exact source/build provenance.
    """
    managed=Path(resources)/'CodecRuntime/managed'
    if not managed.is_dir():return
    receipt_path=managed/'receipt.json';receipt=json.loads(receipt_path.read_text())
    if receipt.get('id')!=ID:raise ValueError('Refusing to restamp an unrelated codec')
    receipt.setdefault('build_files',dict(receipt['files']))
    for name in ('ffmpeg','ffprobe'):
        path=managed/'bin'/name
        if path.is_symlink() or not path.is_file():raise ValueError('Unsafe signed codec binary')
        receipt['files']['bin/'+name]=digest(path)
    receipt['post_signing_receipt']=True
    partial=receipt_path.with_suffix('.json.partial')
    partial.write_text(json.dumps(receipt,indent=2)+'\n');partial.replace(receipt_path)


def smoke(destination):
    """A small real raw-RGB + PCM -> H.264/AAC -> decoded media check."""
    import array,math,struct,tempfile,wave
    destination=Path(destination).resolve();ffmpeg=destination/'bin/ffmpeg';ffprobe=destination/'bin/ffprobe'
    env={'PATH':'/usr/bin:/bin','HOME':os.environ.get('HOME','/tmp')}
    def execute(command,data=None):
        return subprocess.check_output(command,input=data,stderr=subprocess.PIPE,env=env,timeout=60)
    with tempfile.TemporaryDirectory(prefix='nativ-codec-smoke-') as directory:
        root=Path(directory);raw=root/'frames.rgb';audio=root/'tone.wav';output=root/'smoke.mp4'
        with raw.open('wb') as stream:
            for frame in range(24):
                stream.write(bytes(value for y in range(64) for x in range(96) for value in ((x*255//95+frame*7)%256,y*255//63,frame*255//23)))
        with wave.open(str(audio),'wb') as stream:
            stream.setnchannels(2);stream.setsampwidth(2);stream.setframerate(44100)
            stream.writeframes(b''.join(struct.pack('<hh',sample,sample) for sample in (int(16000*math.sin(2*math.pi*440*i/44100)) for i in range(44100))))
        execute([str(ffmpeg),'-v','error','-f','rawvideo','-pixel_format','rgb24','-video_size','96x64','-framerate','24','-i','-','-i',str(audio),'-t','1','-c:v','libx264','-pix_fmt','yuv420p','-c:a','aac','-ac','2','-ar','44100','-movflags','+faststart','-y',str(output)],data=raw.read_bytes())
        data=json.loads(execute([str(ffprobe),'-v','error','-count_frames','-show_streams','-show_format','-of','json',str(output)]))
        video=next(item for item in data['streams'] if item['codec_type']=='video')
        soundtrack=next(item for item in data['streams'] if item['codec_type']=='audio')
        if video['codec_name']!='h264' or video['pix_fmt']!='yuv420p' or int(video['nb_read_frames'])!=24 or video['avg_frame_rate']!='24/1' or soundtrack['codec_name']!='aac' or int(soundtrack['sample_rate'])!=44100 or int(soundtrack['channels'])!=2:
            raise ValueError('Managed codec failed its H.264/AAC media contract')
        decoded=execute([str(ffmpeg),'-v','error','-xerror','-i',str(output),'-map','0:v:0','-vf',r'select=eq(n\,0)+eq(n\,11)+eq(n\,23)','-fps_mode','passthrough','-f','framemd5','-'])
        if len([line for line in decoded.splitlines() if line and not line.startswith(b'#')])!=3:raise ValueError('Managed codec could not decode representative frames')
        decoded_audio=execute([str(ffmpeg),'-v','error','-xerror','-i',str(output),'-map','0:a:0','-vn','-acodec','pcm_f32le','-f','f32le','-'])
        values=array.array('f');values.frombytes(decoded_audio)
        if not values or any(not math.isfinite(value) for value in values) or sum(value*value for value in values)/len(values)<=1e-12:raise ValueError('Managed codec soundtrack decode failed')
        result=dict(frame_count=24,width=96,height=64,fps=24,duration_seconds=1.0,audio_sample_rate=44100,audio_channels=2,audio_finite=True,decoded_audio_samples=len(values),representative_frames=[0,11,23])
    receipt_path=destination/'receipt.json'
    if receipt_path.is_file():
        receipt=json.loads(receipt_path.read_text());receipt.update(qualification='codec_smoke_passed',media_smoke=result)
        receipt_path.write_text(json.dumps(receipt,indent=2)+'\n')
    return result


def build(destination,cache,work,cancel,emit,jobs=4):
    if platform.system()!='Darwin' or platform.machine() not in ('arm64','aarch64'):raise ValueError('Codec build requires an Apple Silicon Mac')
    destination=Path(destination).resolve();cache=Path(cache).resolve();work=Path(work).resolve()
    manifest=json.loads(MANIFEST.read_text())
    if destination.exists():raise ValueError('Build codec into a new managed destination')
    if work.exists():raise ValueError('Build codec in a new private work directory')
    work.mkdir(parents=True);stage=work/'stage';stage.mkdir();prefix=work/'x264-prefix'
    log=work/'build.log'
    archives={}
    for name,source in manifest['sources'].items():
        archives[name]=fetch(source,cache,cancel,emit);extract(archives[name],work/name)
    compiler=subprocess.check_output(['/usr/bin/xcrun','--find','clang'],text=True).strip()
    sdk=subprocess.check_output(['/usr/bin/xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()
    env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','HOME':os.environ.get('HOME','/tmp'),
         'CC':compiler,'CXX':compiler+'++','SDKROOT':sdk,'MACOSX_DEPLOYMENT_TARGET':'26.0',
         'CFLAGS':'-arch arm64 -mmacosx-version-min=26.0','LDFLAGS':'-arch arm64 -mmacosx-version-min=26.0'}
    xargs=['./configure','--prefix='+str(prefix),'--enable-static','--disable-cli',
        '--disable-opencl','--disable-lsmash','--disable-swscale','--disable-ffms','--bit-depth=8','--chroma-format=420']
    emit('building_x264',None);run(xargs,work/'x264',env,cancel,log)
    run(['/usr/bin/make','-j'+str(max(1,min(jobs,8)))],work/'x264',env,cancel,log)
    run(['/usr/bin/make','install-lib-static'],work/'x264',env,cancel,log)
    pkgconfig=work/'nativ-pkg-config';_pkg_config(prefix,pkgconfig)
    args=['./configure','--prefix='+str(stage),'--cc='+compiler,'--arch=arm64','--target-os=darwin',
        '--disable-shared','--enable-static','--disable-autodetect','--disable-network','--disable-everything',
        '--disable-doc','--disable-debug','--disable-ffplay','--disable-iconv','--enable-gpl','--enable-libx264',
        '--pkg-config='+str(pkgconfig),'--pkg-config-flags=--static',
        '--extra-cflags=-arch arm64 -mmacosx-version-min=26.0 -I'+str(prefix/'include'),
        '--extra-ldflags=-arch arm64 -mmacosx-version-min=26.0 -L'+str(prefix/'lib'),
        '--enable-ffmpeg','--enable-ffprobe','--enable-avcodec','--enable-avformat','--enable-avfilter',
        '--enable-swscale','--enable-swresample','--enable-zlib','--enable-protocol=file,pipe,data,fd',
        '--enable-encoder=libx264,aac,rawvideo,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,png,mjpeg,flac',
        '--enable-decoder=h264,aac,mp3float,rawvideo,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le,png,mjpeg,flac',
        '--enable-parser=h264,aac,mpegaudio,png,flac',
        '--enable-demuxer=mov,wav,mp3,flac,image2,rawvideo,pcm_s16le,pcm_f32le',
        '--enable-muxer=mp4,mov,wav,flac,null,framemd5,rawvideo,pcm_s16le,pcm_f32le',
        '--enable-filter=scale,format,fps,setsar,setpts,select,aresample,anull,null,trim,atrim,apad,pad,crop,testsrc2,sine,anullsrc,color',
        '--enable-indev=lavfi','--enable-bsf=aac_adtstoasc,h264_mp4toannexb']
    emit('building_ffmpeg',None);run(args,work/'ffmpeg',env,cancel,log)
    run(['/usr/bin/make','-j'+str(max(1,min(jobs,8)))],work/'ffmpeg',env,cancel,log)
    (stage/'bin').mkdir(exist_ok=True)
    for program in ('ffmpeg','ffprobe'):shutil.copy2(work/'ffmpeg'/program,stage/'bin'/program)
    licenses=stage/'licenses';licenses.mkdir()
    shutil.copy2(work/'x264/COPYING',licenses/'x264-GPL-2.0.txt')
    for name in ('COPYING.GPLv2','COPYING.LGPLv2.1','LICENSE.md'):
        path=work/'ffmpeg'/name
        if path.is_file():shutil.copy2(path,licenses/('FFmpeg-'+name))
    (licenses/'NOTICE').write_text('FFmpeg 9.0.2 with static libx264 b35605ace3ddf7c1a5d67a2eb553f034aef41d55.\nThis executable build is GPL-2.0-or-later. Corresponding unmodified source archives, configuration and toolchain record accompany this runtime.\nFFmpeg and x264 are separate programs/libraries with their respective copyright notices.\n')
    sources=stage/'sources';sources.mkdir()
    for path in archives.values():shutil.copy2(path,sources/path.name)
    shutil.copy2(work/'ffmpeg/ffbuild/config.log',sources/'ffmpeg-config.log')
    shutil.copy2(work/'x264/config.log',sources/'x264-config.log')
    shutil.copy2(Path(__file__),sources/'nativ-codec-build.py')
    shutil.copy2(MANIFEST,sources/'nativ-codec-manifest.json')
    shutil.copy2(pkgconfig,sources/'nativ-pkg-config')
    record=dict(id=ID,schema_version=1,builder_sha256=digest(Path(__file__)),manifest_sha256=digest(MANIFEST),sources=manifest['sources'],
        configure=dict(ffmpeg=args,x264=xargs),toolchain=subprocess.check_output([compiler,'--version'],text=True),
        sdk=sdk,files={f'bin/{name}':digest(stage/'bin'/name) for name in ('ffmpeg','ffprobe')},
        license='GPL-2.0-or-later',qualification='built_pending_media_smoke')
    for name in ('ffmpeg','ffprobe'):
        output=subprocess.check_output(['/usr/bin/otool','-L',str(stage/'bin'/name)],text=True)
        paths=[line.strip().split(' (',1)[0] for line in output.splitlines()[1:] if line.strip()]
        if any(not p.startswith(('/usr/lib/','/System/Library/')) for p in paths):raise ValueError('Codec links an external runtime library')
        record.setdefault('linked_libraries',{})[name]=paths
    (stage/'receipt.json').write_text(json.dumps(record,indent=2)+'\n')
    destination.parent.mkdir(parents=True,exist_ok=True);stage.replace(destination)
    smoke(destination)
    emit('built',1.0);return destination


def main():
    parser=argparse.ArgumentParser();parser.add_argument('action',choices=('build','paths','smoke'))
    parser.add_argument('--output',type=Path,default=ROOT.parents[1]/'dist/codec-runtime')
    parser.add_argument('--cache',type=Path,default=ROOT.parents[1]/'build/codec-runtime')
    parser.add_argument('--work',type=Path,default=ROOT.parents[1]/'build/codec-runtime/work')
    parser.add_argument('--resources',type=Path);parser.add_argument('--jobs',type=int,default=4)
    args=parser.parse_args()
    if args.action=='paths':print(json.dumps(codec_paths(args.resources)));return
    if args.action=='smoke':print(json.dumps(smoke(args.output)));return
    import signal
    cancel=Event();signal.signal(signal.SIGTERM,lambda *_:cancel.set());signal.signal(signal.SIGINT,lambda *_:cancel.set())
    build(args.output,args.cache,args.work,cancel,lambda stage,progress:print(json.dumps(dict(stage=stage,progress=progress)),flush=True),args.jobs)


if __name__=='__main__':main()
