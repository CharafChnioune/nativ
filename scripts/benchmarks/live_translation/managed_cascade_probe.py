#!/usr/bin/env python3
"""Bounded owned-process HTTP cascade probe with sequential model release.

Use verified pinned snapshots and original synthetic fixtures. This runs the actual
Nativ server overlay, including its 64 MiB text-model evaluation batches; it never
attaches to a user server, downloads models, records a microphone, or plays audio.
Output is technical transport evidence, not human fidelity or latency qualification.
"""
import argparse, array, hashlib, json, math, os, re, secrets, shutil, subprocess, threading, time, urllib.request, urllib.error, wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PYTHON = ROOT/'build/NativDevelopmentDerivedData/Build/Products/Debug/NativServerKit.framework/Resources/mlx-vlm-server/python/bin/python3'
WHISPER = ROOT/'build/translation-cascade/whisper-prepared/a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb'
GEMMA = ROOT/'build/translation-cascade/hf-cache/models--mlx-community--gemma-4-e4b-it-4bit/snapshots/475b9088d29754a3379866cf5aeb6b41acd313c2'
FIXTURES = ROOT/'build/lfm-realtime/probes/q8-fixed'

def pressure():
    value=int(subprocess.check_output(['sysctl','-n','kern.memorystatus_vm_pressure_level'],text=True))
    if value not in (1,2,4):raise ValueError('unknown system memory pressure')
    return value
def swap():
    match=re.search(r'used = ([0-9.]+)M',subprocess.check_output(['sysctl','-n','vm.swapusage'],text=True,env=dict(os.environ,LC_ALL='C')))  # no locale decimal comma
    if match is None:raise ValueError('unavailable system swap telemetry')
    return float(match.group(1))
def final_telemetry(report):
    for name,reader in [('final_pressure',pressure),('final_swap_mib',swap)]:
        try:report[name]=reader()
        except Exception as error:
            report[name]=None
            report.setdefault('telemetry_errors',[]).append({'field':name,'error':type(error).__name__})
            report['status']='failed'
            report.setdefault('error','final resource telemetry unavailable; experiment is not complete')
def rss(pid):
    try:return int(subprocess.check_output(['ps','-o','rss=','-p',str(pid)],text=True).strip())*1024
    except (ValueError,subprocess.CalledProcessError):return 0
def stop(p):
    if p.poll() is not None:return
    p.terminate()
    try:p.wait(timeout=3)
    except subprocess.TimeoutExpired:p.kill();p.wait(timeout=3)
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*args,**kw):raise RuntimeError('redirect refused')
OPENER=urllib.request.build_opener(urllib.request.ProxyHandler({}),NoRedirect())
def request(port,key,path,body=None,content_type='application/json'):
    if isinstance(body,dict):body=json.dumps(body).encode()
    req=urllib.request.Request(f'http://127.0.0.1:{port}{path}',data=body,headers={'Authorization':'Bearer '+key,'Content-Type':content_type})
    return OPENER.open(req,timeout=120)
def multipart(model,lang,wav):
    boundary=secrets.token_hex(20);body=bytearray()
    for name,value in [('model',str(model)),('language',lang),('task','transcribe'),('response_format','json')]:
        body.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
    body.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="utterance.wav"\r\nContent-Type: audio/wav\r\n\r\n'.encode());body.extend(wav.read_bytes());body.extend(f'\r\n--{boundary}--\r\n'.encode())
    return bytes(body),'multipart/form-data; boundary='+boundary

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--output',type=Path,required=True);parser.add_argument('--recognition-only',action='store_true');parser.add_argument('--contract',type=Path,default=ROOT/'build/translation-contract');parser.add_argument('--gemma',type=Path,default=GEMMA);parser.add_argument('--python',type=Path,default=PYTHON);parser.add_argument('--whisper',type=Path,default=WHISPER);parser.add_argument('--fixtures',type=Path,default=FIXTURES);parser.add_argument('--max-swap-growth-mib',type=float,default=1024);args=parser.parse_args()
    if args.whisper.name != WHISPER.name or args.gemma.name != GEMMA.name:
        parser.error('This profile requires the exact pinned Whisper turbo and Gemma E4B snapshot revisions')
    if not args.python.is_file() or not args.whisper.is_dir() or not args.gemma.is_dir():
        parser.error('Use the built Nativ Python runtime and already verified local snapshots')
    if not args.recognition_only and not args.contract.is_file():
        parser.error('Build the production TranslationKit contract driver first; see README')
    if not 0 < args.max_swap_growth_mib <= 2048:
        parser.error('The development-machine probe requires a positive swap-growth guard no larger than 2048 MiB')
    out=args.output.resolve();out.mkdir(parents=True,exist_ok=False)
    overlays=out/'overlay';overlays.mkdir()
    for filename in ['nativ_server.py','nativ_translation_local.py']:shutil.copyfile(ROOT/'PythonDistribution/Overlay'/filename,overlays/filename)
    report={'status':'incomplete','qualified':False,'strategy':'sequential-managed-http','initial_pressure':pressure(),'initial_swap_mib':swap(),'peak_rss_bytes':0,'peak_swap_growth_mib':0,'maximum_pressure':1,'turns':[],'events':[],'overlay_sha256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in overlays.iterdir()}}
    report['contract_sha256'] = hashlib.sha256(args.contract.read_bytes()).hexdigest() if args.contract.is_file() else None
    report.update(whisper_revision=WHISPER.name, gemma_revision=GEMMA.name,
                  max_swap_growth_mib=args.max_swap_growth_mib,
                  limitations=['Only synthetic technical turns; no listener or acoustic latency measurement.',
                               'Global swap cannot be attributed to this process alone. RSS does not include all unified-memory allocations.',
                               'Prepared model artifacts must be verified using the pinned manifests before this probe.'])
    owned=[];failure=[];done=threading.Event();started=time.monotonic()
    def event(name,**data):
        entry={'event':name,'seconds':time.monotonic()-started,**data};report['events'].append(entry);print(json.dumps(entry),flush=True)
        (out/'report.json').write_text(json.dumps(report,indent=2))
    def monitor():
        while not done.wait(.5):
            try:
                level=pressure();growth=swap()-report['initial_swap_mib'];memory=sum(rss(p.pid) for p in owned if p.poll() is None)
            except Exception:
                failure.append('resource monitor became unavailable; fail closed')
                for p in list(owned):stop(p)
                return
            report['maximum_pressure']=max(report['maximum_pressure'],level);report['peak_swap_growth_mib']=max(report['peak_swap_growth_mib'],growth);report['peak_rss_bytes']=max(report['peak_rss_bytes'],memory)
            reason=None
            if level>=4:reason='actual OS critical pressure'
            if growth>args.max_swap_growth_mib:reason='bounded swap-growth guard'
            if time.monotonic()-started>480:reason='bounded total duration'
            if reason:
                failure.append(reason)
                for p in list(owned):stop(p)
                return
    def launch(command,env,name,pattern):
        log=out/(name+'.log');stream=log.open('w');p=subprocess.Popen(command,env=env,stdout=stream,stderr=subprocess.STDOUT);owned.append(p);event(name+'_spawned',pid=p.pid)
        until=time.monotonic()+120
        while time.monotonic()<until:
            if failure:raise RuntimeError(failure[0])
            if p.poll() is not None:raise RuntimeError(name+' exited: '+log.read_text()[-2000:])
            found=re.search(pattern,log.read_text())
            if found:return p,int(found.group(1))
            time.sleep(.1)
        raise RuntimeError(name+' readiness deadline')
    try:
        if report['initial_pressure']>=4:raise RuntimeError('critical baseline; no model load')
        threading.Thread(target=monitor,daemon=True).start()
        key=secrets.token_hex(32)
        env={k:v for k,v in os.environ.items() if k in ['PATH','HOME','TMPDIR','USER','LOGNAME','LANG','LC_ALL']}
        env.update({'PYTHONPATH':str(overlays),'PYTHONNOUSERSITE':'1','PYTHONUNBUFFERED':'1','MLX_VLM_SERVER_API_KEY':key,'HF_HUB_OFFLINE':'1','TRANSFORMERS_OFFLINE':'1','HF_HUB_DISABLE_TELEMETRY':'1','MLX_PLATFORM_ANALYTICS_DB_PATH':':memory:','APC_ENABLED':'0','APC_DISK_ENABLED':'0','MLX_VLM_VISION_CACHE_SIZE':'0'})
        server,port=launch([str(args.python.resolve()),'-m','nativ_server','--host','127.0.0.1','--port','0'],env,'managed',r'Uvicorn running on http://127\.0\.0\.1:(\d+)')
        event('managed_ready',port=port)
        manifest=json.loads((ROOT/'ThirdParty/LFMRealtime/runtime-manifest.json').read_text());artifacts=manifest['model']['artifacts'];lfmbuild=ROOT/'build/lfm-realtime'
        report.update(omni_revision=manifest['model']['revision'], helper_commit=manifest['runtime']['commit'], omni_quantization='Q8_0')
        for source,target,source_name,target_name in [('nl','en','Dutch','English'),('en','nl','English','Dutch')]:
            turnstart=time.monotonic();data,ct=multipart(args.whisper.resolve(),source,args.fixtures.resolve()/('synthetic-'+source+'.wav'))
            event('recognition_started',source=source)
            with request(port,key,'/v1/audio/transcriptions',data,ct) as response:transcription=json.load(response)
            source_text=transcription['text'];event('recognition_completed',source=source,transcript=source_text)
            with request(port,key,'/unload',{}) as response:unloaded=json.load(response)
            event('recognition_released',result=unloaded)
            if args.recognition_only:continue
            sttend=time.monotonic()
            prompt=json.loads(subprocess.check_output([str(args.contract),'prompt',source,target],text=True,timeout=10))['text']
            report.setdefault('instructions', {})[source+'-'+target]=prompt
            event('translation_started',model=str(args.gemma))
            payload={'model':str(args.gemma),'messages':[{'role':'system','content':prompt},{'role':'user','content':source_text}],'max_tokens':512,'temperature':0,'top_k':0,'top_p':1,'min_p':0,'enable_thinking':False,'tools':[],'tool_choice':'none','stream':False}
            with request(port,key,'/v1/chat/completions',payload) as response:translation=json.load(response)
            choice=translation['choices'][0];target_text=choice['message']['content']
            if choice.get('finish_reason')!='stop' or choice['message'].get('tool_calls'):raise RuntimeError('incomplete/tool translation rejected')
            textend=time.monotonic();event('translation_completed',translation=target_text,response=translation)
            with request(port,key,'/unload',{}) as response:unloaded=json.load(response)
            event('translation_released',result=unloaded)
            guard_result=json.loads(subprocess.check_output([str(args.contract),'validate',source,target],input=json.dumps({'source':source_text,'translation':target_text}),text=True,timeout=10))
            event('content_guard',**guard_result)
            if not guard_result['accepted']:
                report['turns'].append({'source':source,'target':target,'transcript':source_text,'translation':target_text,'guard':guard_result,'speech_started':False})
                raise RuntimeError('production content guard rejected translation before speech')
            helper_env=env.copy();helper_env['LLAMA_API_KEY']=key
            command=[str(lfmbuild/'runtime/bin/llama-server'),'-m',str(lfmbuild/'models'/artifacts['Q8_0']['filename']),'--mmproj',str(lfmbuild/'models'/artifacts['projector']['filename']),'--host','127.0.0.1','--port','0','--parallel','1','--ctx-size','4096','--threads','4','--batch-size','512','--ubatch-size','128','--gpu-layers','99','--reasoning','off','--no-agent','--no-webui','--cors-origins','localhost','--no-cors-credentials']
            helper,tts_port=launch(command,helper_env,'omni-'+source,r'listening on http://127\.0\.0\.1:(\d+)')
            first=None;pcm=bytearray();ttsstart=time.monotonic()
            with request(tts_port,key,'/tts',{'input':target_text,'lang':target,'stream':True,'response_format':'pcm','n_predict':512}) as response:
                headers=dict(response.headers)
                content_type=response.headers.get('Content-Type','')
                fields=[value.strip().lower() for value in content_type.split(';')]
                rate=re.search(r'(?:^|;)\s*rate=(\d+)(?:;|$)',content_type)
                if fields[0]!='audio/pcm' or 'encoding=float' not in fields or 'bits=32' not in fields or not rate:
                    raise RuntimeError('speech response did not provide FLOAT32 PCM rate metadata')
                sample_rate=int(rate.group(1))
                if not 8000<=sample_rate<=96000:raise RuntimeError('invalid speech sample rate')
                while True:
                    chunk=response.read(4096)
                    if not chunk:break
                    if first is None:first=time.monotonic()
                    pcm.extend(chunk)
                    if len(pcm)>16*1024*1024:raise RuntimeError('bounded speech response exceeded')
            if not pcm or len(pcm)%4:raise RuntimeError('no complete FLOAT32 samples')
            (out/('speech-'+target+'.float32')).write_bytes(pcm)
            samples=array.array('f',pcm)
            if not all(math.isfinite(value) for value in samples):raise RuntimeError('nonfinite speech samples')
            pcm16=array.array('h',(max(-32768,min(32767,round(v*32767))) for v in samples))
            with wave.open(str(out/('speech-'+target+'.wav')),'wb') as w:w.setnchannels(1);w.setsampwidth(2);w.setframerate(sample_rate);w.writeframes(pcm16.tobytes())
            stop(helper);event('speech_released',source=source)
            report['turns'].append({'source':source,'target':target,'transcript':source_text,'translation':target_text,'stt_and_release_seconds':sttend-turnstart,'translation_seconds':textend-sttend,'first_audio_after_turn_seconds':first-turnstart,'first_tts_pcm_seconds':first-ttsstart,'pcm_bytes':len(pcm),'headers':headers,'total_seconds':time.monotonic()-turnstart})
            event('turn_completed',source=source)
        report['status']='completed'
    except Exception as error:
        report['status']='failed';report['error']=failure[0] if failure else str(error);event('failed',error=report['error'])
    finally:
        done.set()
        for p in owned:stop(p)
        report['seconds']=time.monotonic()-started;report['owned_processes_stopped']=all(p.poll() is not None for p in owned)
        final_telemetry(report)
        (out/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps({'status':report['status'],'output':str(out)}),flush=True)

    return 0 if report['status'] == 'completed' else 1

if __name__=='__main__':raise SystemExit(main())
