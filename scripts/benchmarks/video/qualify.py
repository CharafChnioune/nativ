#!/usr/bin/env python3
"""Deliberate local-only qualification through Nativ's actual durable API.

No --run-models: print requirements/corpus only. Never installs models, enables a
provider, accepts a model license, sends cloud work or regenerates on timeout.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import threading
import time
from urllib.parse import urlsplit
from urllib.request import Request,HTTPRedirectHandler,build_opener
import uuid


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self,*args):
        raise ValueError('Canonical server redirects are refused; review the selected server URL.')


def urlopen(request,timeout):
    return build_opener(NoRedirect()).open(request,timeout=timeout)


def corpus(profile):
    wan=profile.startswith('wan')
    for index,(operation,portrait,seed) in enumerate((('text_to_video',False,42),('text_to_video',True,123),('image_to_video',False,123),('image_to_video',True,42))):
        yield dict(model=profile,operation=operation,prompt='A small wooden toy boat drifts left to right on a calm blue pond; the camera moves slowly forward.',
                   output_preset=('wan-draft-' if wan else 'draft-')+('portrait' if portrait else 'landscape'),
                   audio_mode='silent' if wan else 'native_generated',seed=seed,allow_remote=False)


def host():
    d={'platform':platform.platform(),'machine':platform.machine(),'python':platform.python_version()}
    for name,cmd in [('chip',['/usr/sbin/sysctl','-n','machdep.cpu.brand_string']),('memory_bytes',['/usr/sbin/sysctl','-n','hw.memsize']),('swap',['/usr/sbin/sysctl','vm.swapusage'])]:
        try:d[name]=subprocess.check_output(cmd,text=True,timeout=5).strip()
        except (OSError,subprocess.SubprocessError):d[name]=None
    return d


def durable_json(path,value):
    temporary=path.with_name(path.name+'.'+uuid.uuid4().hex+'.partial')
    temporary.write_text(json.dumps(value,indent=2)+'\n');os.chmod(temporary,0o600)
    with temporary.open('rb') as stream:os.fsync(stream.fileno())
    os.replace(temporary,path)
    descriptor=os.open(path.parent,os.O_RDONLY)
    try:os.fsync(descriptor)
    finally:os.close(descriptor)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile',choices=('ltx-2.3-distilled-local','wan2.2-ti2v-5b-q8-local'),default='ltx-2.3-distilled-local')
    parser.add_argument('--server',default='http://127.0.0.1:8181');parser.add_argument('--key-env',default='NATIV_KEY')
    parser.add_argument('--output',type=Path,default=Path('build/validation/video-qualification'))
    parser.add_argument('--run-models',action='store_true');parser.add_argument('--timeout',type=int,default=14400)
    args=parser.parse_args(); cases=list(corpus(args.profile))
    if not args.run_models:
        print(json.dumps({'action':'dry_run','requirements':'prepared runtime, accepted license, explicit experimental server profile, sufficient Apple Silicon headroom','corpus':cases},indent=2));return 0
    u=urlsplit(args.server)
    if u.username or u.password or u.query or u.fragment or not u.hostname or (u.scheme!='https' and not(u.scheme=='http' and u.hostname in ('127.0.0.1','localhost','::1'))):
        parser.error('Use HTTPS or an explicit loopback HTTP canonical server')
    key=os.environ.get(args.key_env)
    if not key:parser.error('Set the configured Nativ key privately in the selected environment variable')
    args.output.mkdir(parents=True,exist_ok=True)
    canonical_store=None
    def call(method,path,body=None,headers=None,raw=None):
        data=json.dumps(body).encode() if body is not None else raw
        h={'Authorization':'Bearer '+key,**(headers or {})}
        if method not in ('GET','HEAD'):
            if canonical_store is None:raise ValueError('Read the canonical store before any mutation')
            h['X-Nativ-Store-ID']=canonical_store
        if body is not None:h['Content-Type']='application/json'
        request=Request(args.server.rstrip('/')+path,data=data,headers=h,method=method)
        with urlopen(request,timeout=30) as response:
            result=response.read(2*1024*1024+1)
            if len(result)>2*1024*1024:raise ValueError('Metadata exceeds limit')
            value=json.loads(result)
            if canonical_store is not None and isinstance(value,dict) and value.get('store_id',canonical_store)!=canonical_store:
                raise ValueError('The canonical store changed during observation; preserve the saved intent and reconnect')
            return value
    info=call('GET','/v1/video/info');canonical_store=info['store_id']
    report={'kind':'real_local_model_qualification','started_at':time.time(),'client_host_before':host(),'hardware_measurement_scope':'client_only','canonical_server':args.server.rstrip('/'),'canonical_server_is_loopback':u.hostname in ('127.0.0.1','localhost','::1'),'model_execution_location':'canonical_server','store_id':info['store_id'],'profile':args.profile,'cases':[],
            'limitations':['One owned worker per job: repeated jobs still load the model.','Client host hardware is not remote canonical-server hardware.','Client timings exclude native playback/UI/acoustic latency.','Motion/reference/audio quality requires explicit human review.'],'human_review_complete':False,'qualified':False}
    reportfile=args.output/'report.json'
    if reportfile.exists():
        previous=json.loads(reportfile.read_text())
        if previous.get('store_id')!=canonical_store or previous.get('profile')!=args.profile or previous.get('canonical_server',args.server.rstrip('/'))!=args.server.rstrip('/'):
            raise ValueError('Existing evidence belongs to another canonical store/server/profile')
        report['cases']=previous.get('cases',[])
        report['client_host_before']=previous.get('client_host_before',report['client_host_before'])
        report['resumed_at']=time.time()
    # Synthetic original; no private image is sent even to the canonical server.
    from PIL import Image,ImageDraw
    image=args.output/'synthetic-first-frame.png'
    im=Image.new('RGB',(832,480),'#2B647F');draw=ImageDraw.Draw(im);draw.ellipse((250,250,550,350),fill='#E7CB8B');draw.polygon([(300,250),(470,250),(430,310),(340,310)],fill='#7C492B');im.save(image)
    boundary='nativ-'+uuid.uuid4().hex
    raw=(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="synthetic.png"\r\nContent-Type: image/png\r\n\r\n'.encode()+image.read_bytes()+f'\r\n--{boundary}--\r\n'.encode())
    receiptfile=args.output/'input-receipt.json';source_sha=hashlib.sha256(image.read_bytes()).hexdigest()
    if receiptfile.exists():
        receipt=json.loads(receiptfile.read_text())
        if receipt.get('store_id')!=canonical_store or receipt.get('source_sha256')!=source_sha:
            raise ValueError('The saved input belongs to a different store or source; use a new evidence directory')
        upload=call('GET','/v1/video/inputs/'+receipt['input_id'])
        if upload.get('sha256')!=source_sha:raise ValueError('The saved immutable input no longer matches its receipt')
    else:
        upload=call('POST','/v1/video/inputs',headers={'Content-Type':'multipart/form-data; boundary='+boundary},raw=raw)
        durable_json(receiptfile,{'store_id':canonical_store,'input_id':upload['input_id'],'source_sha256':source_sha})
    for index,case in enumerate(cases):
        if case['operation']=='image_to_video':case['inputs']=[{'input_id':upload['input_id'],'role':'first_frame','transform':{'version':1,'fit_policy':'contain','background':'#000000','crop':None}}]
        intentfile=args.output/f'intent-{index}.json'
        if intentfile.exists():
            intent=json.loads(intentfile.read_text())
            if intent['store_id']!=canonical_store or intent.get('server',args.server.rstrip('/'))!=args.server.rstrip('/') or intent['request']!=case:raise ValueError('The saved intent belongs to a different store/request; use a new evidence directory')
        else:
            intent={'store_id':canonical_store,'server':args.server.rstrip('/'),'request':case,'idempotency_key':str(uuid.uuid4())};durable_json(intentfile,intent)
        started=time.monotonic();job=call('POST','/v1/video/generations',case,{'Idempotency-Key':intent['idempotency_key']})
        record={'case_index':index,'request':case,'job_id':job['job_id'],'submit_seconds':time.monotonic()-started,'samples':[],'human_motion_review':None,'human_reference_review':None,'human_audio_review':None}
        while job['state'] not in ('succeeded','failed','cancelled','interrupted','submission_unknown','recovery_hold','retrieval_pending'):
            if time.monotonic()-started>args.timeout:raise TimeoutError('Existing job timed out; inspect/reconnect using the saved intent, never regenerate automatically')
            time.sleep(0.5)
            check=time.monotonic();job=call('GET','/v1/video/generations/'+job['job_id'])
            record['samples'].append({'elapsed':time.monotonic()-started,'status_seconds':time.monotonic()-check,'state':job['state'],'stage':job.get('stage'),'progress':job.get('progress')})
        record.update(state=job['state'],wall_seconds=time.monotonic()-started,job=job)
        if job['state']=='succeeded':record['asset']=call('GET','/v1/video/assets/'+job['asset_id'])
        prior=next((item for item in report['cases'] if item.get('case_index')==index and item.get('job_id')==job['job_id'] and item.get('state')=='succeeded'),None)
        report['cases']=[item for item in report['cases'] if item.get('case_index')!=index]+[prior or record]
        report['cases'].sort(key=lambda item:item['case_index']);report['client_host_after']=host()
        durable_json(reportfile,report)
        if job['state']!='succeeded':raise RuntimeError('Qualification stopped in '+job['state']+'; inspect the same job and use explicit Resume/Retry Download if eligible. No additional intent was submitted.')
    print('Four canonical-server jobs report succeeded. Review report.json, execution-host measurements and every original before creating a qualification record.');return 0

if __name__=='__main__':raise SystemExit(main())
