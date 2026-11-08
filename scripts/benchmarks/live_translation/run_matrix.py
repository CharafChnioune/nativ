#!/usr/bin/env python3
"""Run synthetic technical probes serially against one owned model process.

Creates only original synthetic audio via macOS say, never records/plays audio.
Requires an already built helper and SHA-verified model installation.
"""
import argparse
import asyncio
import importlib.util
import json
import os
import pathlib
import secrets
import re
import subprocess
import threading
import time
import urllib.error
import urllib.request
from types import SimpleNamespace

ROOT = pathlib.Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('lfm_probe', pathlib.Path(__file__).with_name('probe.py'))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--quantization', choices=['Q8_0','Q4_K_M'], default='Q8_0')
    parser.add_argument('--build-root', type=pathlib.Path, default=ROOT/'build/lfm-realtime')
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--helper', type=pathlib.Path)
    parser.add_argument('--timeout', type=float, default=90)
    args = parser.parse_args()
    build = args.build_root.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    subprocess.run(['python3',str(ROOT/'scripts/build_lfm_realtime_runtime.py'),'--build-root',str(build),'--verify-only','--quantizations',args.quantization],check=True)
    helper = args.helper or build/'runtime/bin/llama-server'
    manifest = json.loads((ROOT/'ThirdParty/LFMRealtime/runtime-manifest.json').read_text())
    model = build/'models'/manifest['model']['artifacts'][args.quantization]['filename']
    projector = build/'models'/manifest['model']['artifacts']['projector']['filename']
    keyfile = output/'.probe-key'
    fd = os.open(str(keyfile), os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(fd,'w') as stream:
        stream.write(secrets.token_hex(32))
    # The helper asks the OS for a port; parse only this owned child's log.
    command = [str(helper),'-m',str(model),'--mmproj',str(projector),'--host','127.0.0.1','--port','0','--parallel','1','--ctx-size','8192','--threads','4','--batch-size','512','--ubatch-size','128','--gpu-layers','99','--reasoning','off','--api-key-file',str(keyfile),'--cors-origins','localhost','--no-cors-credentials','--no-agent','--no-webui']
    report = {'quantization': args.quantization, 'status':'synthetic-technical-only-unqualified', 'command':command,'probes':[], 'peak_sampled_rss_bytes':0,'memory_note':'Helper process RSS sampled every 0.5 seconds; excludes a full system/Metal memory footprint assessment.', 'contention':'Root baseline app build may run concurrently; no performance qualification.'}
    log = (output/'server.log').open('w')
    environment = {key:value for key,value in os.environ.items() if not key.startswith('LLAMA_')}
    child = subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT,env=environment)
    stop = threading.Event()
    def memory():
        while not stop.wait(.5):
            value = subprocess.run(['ps','-p',str(child.pid),'-o','rss='],capture_output=True,text=True).stdout.strip()
            if value.isdigit():
                report['peak_sampled_rss_bytes'] = max(report['peak_sampled_rss_bytes'],int(value)*1024)
    sampler = threading.Thread(target=memory,daemon=True)
    sampler.start()
    begin = time.monotonic()
    try:
        while time.monotonic()-begin < 120:
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
        for source,voice,text,target in [('nl','Xander','De afspraak is om half vier, niet om vier uur.','en'),('en','Samantha','Please book two seats for Friday, not for Thursday.','nl')]:
            aiff=output/('synthetic-'+source+'.aiff'); wav=output/('synthetic-'+source+'.wav')
            subprocess.run(['say','-v',voice,'-o',str(aiff),text],check=True,timeout=20)
            subprocess.run(['afconvert','-f','WAVE','-d','LEI16@16000','-c','1',str(aiff),str(wav)],check=True,timeout=20)
            for mode in ['direct','two-pass']:
                path=output/(source+'-'+mode+'.json')
                options=SimpleNamespace(url=url,key_file=keyfile,wav=wav,timeout=args.timeout,output=path,retain_content=True,lang=target,text=text,source_language=source)
                try:
                    result=asyncio.run(probe.websocket_probe(options,text_only=mode=='two-pass'))
                    if mode=='two-pass' and result.get('text'):
                        # Socket closed and its slot released before starting /tts.
                        result['tts']=probe.tts_probe(options,result['text'])
                except Exception as error:
                    result=getattr(options,'_partial',{})
                    result.update(failure=type(error).__name__,message=str(error))
                path.write_text(json.dumps(result,indent=2,ensure_ascii=False)+'\n')
                report['probes'].append({'source':source,'mode':mode,'path':path.name,**{k:v for k,v in result.items() if k in ('failure','errors','first_text_seconds','first_audio_seconds','done_seconds','audio_bytes','text','tts')}})
                (output/'summary.json').write_text(json.dumps(report,indent=2,ensure_ascii=False)+'\n')
        for language,text in [('nl','De afspraak is om half vier, niet om vier uur.'),('en','Please book two seats for Friday, not for Thursday.')]:
            options=SimpleNamespace(url=url,key_file=keyfile,timeout=args.timeout,output=output/('tts-'+language+'.json'),retain_content=True,lang=language,text=text)
            result=probe.tts_probe(options)
            options.output.write_text(json.dumps(result,indent=2)+'\n')
            report['probes'].append({'mode':'tts','language':language,**result})
        options=SimpleNamespace(url=url,key_file=keyfile,wav=output/'synthetic-en.wav',timeout=args.timeout,output=output/'cancel.json',retain_content=True,lang='nl')
        try:
            result=asyncio.run(probe.websocket_probe(options,cancel=True))
            options.output.write_text(json.dumps(result,indent=2)+'\n')
            report['cancel']=result
        except Exception as error:
            report['cancel']={'failure':type(error).__name__,'message':str(error)}
        report['fresh_session_after_cancel']=asyncio.run(probe.websocket_probe(options,reset=True))
        print('Matrix completed:',output,flush=True)
    except Exception as error:
        report['failure']={'type':type(error).__name__,'message':str(error)}
        print('Matrix failure:',report['failure'],flush=True)
    finally:
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                child.kill(); child.wait(timeout=5)
        stop.set(); sampler.join(timeout=2); log.close()
        report['owned_child_exit_code']=child.returncode
        keyfile.unlink(missing_ok=True)
        (output/'summary.json').write_text(json.dumps(report,indent=2,ensure_ascii=False)+'\n')
    if 'failure' in report:
        raise SystemExit(1)

if __name__=='__main__':
    main()
