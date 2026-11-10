#!/usr/bin/env python3
"""Explicit local-model qualification evidence; default is a network-free dry run.

Restart the same output directory to observe the same jobs. Durable dispatch
intent is never replayed: a lost acceptance is looked up by its frozen unique
request title; an unresolved match requires operator recovery, not another POST.
"""
from __future__ import annotations
import argparse
import hashlib
import fcntl
import json
import os
from pathlib import Path
import platform
import re
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

ROOT=Path(__file__).resolve().parents[3]
CORPUS=Path(__file__).with_name('corpus.json')
TERMINAL={'succeeded','failed','cancelled','interrupted'}


def fingerprint(value):return hashlib.sha256(json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()).hexdigest()


def digest_file(path):
    digest=hashlib.sha256()
    with Path(path).open('rb') as source:
        for chunk in iter(lambda:source.read(65536),b''):digest.update(chunk)
    return digest.hexdigest()


def atomic(path,value):
    path.parent.mkdir(parents=True,exist_ok=True)
    temporary=path.with_name(path.name+'.partial')
    with temporary.open('w') as stream:
        os.chmod(temporary,0o600);json.dump(value,stream,indent=2,ensure_ascii=False,allow_nan=False);stream.write('\n');stream.flush();os.fsync(stream.fileno())
    temporary.replace(path)
    descriptor=os.open(path.parent,os.O_RDONLY)
    try:os.fsync(descriptor)
    finally:os.close(descriptor)


def load_corpus(path):
    value=json.loads(Path(path).read_text());cases=value['cases']
    if value.get('schema_version')!=1 or len(cases)<20:raise ValueError('Qualification corpus requires at least twenty original cases.')
    ids=set();counts={}
    for case in cases:
        if not re.fullmatch('[a-z0-9-]{1,100}',case['id']) or case['id'] in ids:raise ValueError('Corpus case identities must be unique safe names.')
        ids.add(case['id']);request=case['request'];model=request['model'];counts[model]=counts.get(model,0)+1
        if request.get('allow_remote') is not False:raise ValueError('Music qualification corpus must explicitly forbid provider-remote execution.')
    if any(count<5 for count in counts.values()):raise ValueError('Each selected local profile needs at least five corpus cases.')
    return cases


def observed_system():
    result={'scope':'runner_host_system_observation_not_per_model','observed_at':time.time(),'machine':platform.machine(),'macos':platform.mac_ver()[0]}
    if platform.system()=='Darwin':
        for key,command in {'physical_memory_bytes':['/usr/sbin/sysctl','-n','hw.memsize'],
                            'swap_observed':['/usr/sbin/sysctl','-n','vm.swapusage'],
                            'vm_observed':['/usr/bin/vm_stat']}.items():
            try:result[key]=subprocess.check_output(command,text=True,stderr=subprocess.DEVNULL,timeout=5,env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin'}).strip()
            except (OSError,subprocess.SubprocessError):result[key]=None
    return result


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*args):raise ValueError('Canonical server redirects are refused; review the selected server URL.')


class HTTP:
    def __init__(self,base_url,token):
        parsed=urllib.parse.urlsplit(base_url)
        if parsed.username or parsed.password or parsed.query or parsed.fragment or not parsed.hostname or (parsed.scheme!='https' and not(parsed.scheme=='http' and parsed.hostname in ('localhost','127.0.0.1','::1'))):
            raise ValueError('Use an HTTPS canonical Nativ server or an explicit loopback HTTP URL.')
        if not token:raise ValueError('Set the Nativ token environment variable before --run-models.')
        self.base=base_url.rstrip('/')+'/v1/music/';self.token=token;self.opener=urllib.request.build_opener(NoRedirect())
    def _open(self,method,path,body=None,headers=None):
        values={'Authorization':'Bearer '+self.token,**(headers or {})};data=None
        if body is not None:values['Content-Type']='application/json';data=json.dumps(body,allow_nan=False).encode()
        request=urllib.request.Request(self.base+path,data=data,headers=values,method=method)
        try:return self.opener.open(request,timeout=30)
        except urllib.error.HTTPError as error:raise ValueError('Nativ returned HTTP '+str(error.code)+'. No generation submission will be repeated.') from None
        except (urllib.error.URLError,TimeoutError,OSError):raise ValueError('The Nativ connection ended without a confirmed response. Reuse this ledger for observation only.') from None
    def request(self,method,path,*,body=None,headers=None):
        with self._open(method,path,body,headers) as response:
            raw=response.read(16*1024*1024+1)
        if len(raw)>16*1024*1024:raise ValueError('Canonical control response exceeded its byte limit.')
        try:return json.loads(raw,parse_constant=lambda _:(_ for _ in ()).throw(ValueError()))
        except (ValueError,UnicodeError):raise ValueError('The canonical server returned invalid control JSON.') from None
    def download(self,path,destination,*,headers,expected_sha256):
        temporary=destination.with_name(destination.name+'.partial');digest=hashlib.sha256();count=0
        try:
            with self._open('GET',path,headers=headers) as response:
                if response.headers.get('X-Nativ-Store-ID')!=headers['X-Nativ-Store-ID']:raise ValueError('The download belongs to another canonical store.')
                if int(response.headers.get('Content-Length','-1'))>1024**3:raise ValueError('Audio download exceeds its byte limit.')
                with temporary.open('wb') as output:
                    os.chmod(temporary,0o600)
                    while True:
                        block=response.read(65536)
                        if not block:break
                        count+=len(block)
                        if count>1024**3:raise ValueError('Audio download exceeded its byte limit.')
                        output.write(block);digest.update(block)
                    output.flush();os.fsync(output.fileno())
            if not count or digest.hexdigest()!=expected_sha256:raise ValueError('Downloaded original did not match its canonical content digest.')
            temporary.replace(destination)
        finally:temporary.unlink(missing_ok=True)


class Runner:
    def __init__(self,*,base_url,output,cases,transport,poll_seconds=1,max_wait=7200):
        self.base_url=base_url.rstrip('/');self.output=Path(output);self.cases=cases;self.api=transport;self.poll=poll_seconds;self.max_wait=max_wait
        self.output.mkdir(parents=True,exist_ok=True,mode=0o700);self.path=self.output/'state.json'
        self._lock_file=(self.output/'.qualification.lock').open('a+b')
        try:fcntl.flock(self._lock_file,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except OSError:
            self._lock_file.close();raise ValueError('Another qualification runner owns this output ledger.') from None
        try:
            if self.path.is_file():
                self.state=json.loads(self.path.read_text())
                if self.state['base_url']!=self.base_url or self.state['corpus_sha256']!=fingerprint(cases):raise ValueError('This ledger belongs to another canonical server or frozen corpus; do not retarget its intents.')
            else:self.state=dict(schema_version=1,run_id=str(uuid.uuid4()),base_url=self.base_url,corpus_sha256=fingerprint(cases),store_id=None,profiles={},cases={},created_at=time.time())
            self.latencies=self.state.setdefault('latest_status_latencies_seconds',[])
        except BaseException:self.close();raise
    def close(self):
        if not self._lock_file.closed:
            fcntl.flock(self._lock_file,fcntl.LOCK_UN);self._lock_file.close()
    def save(self):atomic(self.path,self.state)
    def request(self,method,path,body=None,headers=None):
        started=time.perf_counter()
        try:return self.api.request(method,path,body=body,headers={'X-Nativ-Store-ID':self.state['store_id'],**(headers or {})} if self.state['store_id'] else headers)
        finally:
            if path.startswith('generations/') and method=='GET':
                self.latencies.append(time.perf_counter()-started)
                del self.latencies[:-512]
    def bind(self):
        info=self.request('GET','info')
        if info.get('contract_version')!=1:raise ValueError('Unsupported canonical generation API contract.')
        if self.state['store_id'] and self.state['store_id']!=info['store_id']:raise ValueError('The canonical store changed. Existing intents cannot move to the replacement library.')
        self.state['store_id']=info['store_id']
        catalog={item['id']:item for item in self.request('GET','models')['items']}
        for model in {case['request']['model'] for case in self.cases}:
            profile=catalog.get(model)
            if not profile or profile.get('deployment')!='local':raise ValueError('Qualification refuses hosted/remote-GPU or unadvertised profiles.')
            if profile.get('readiness')!='ready':raise ValueError('Prepare and explicitly enable the selected unqualified local profile first.')
            previous=self.state['profiles'].get(model)
            if previous and previous.get('profile_revision')!=profile.get('profile_revision'):raise ValueError('A selected profile changed revision. Observe old jobs separately; do not retarget this qualification run.')
            self.state['profiles'][model]=profile
        self.save()
    def recovered_job(self,intent):
        cursor=None;matches=[];seen=0
        while True:
            path='generations'+('?' + urllib.parse.urlencode({'cursor':cursor}) if cursor else '')
            page=self.request('GET',path)
            for job in page['items']:
                seen+=1;accepted=job.get('request',{})
                if accepted.get('title')==intent['request']['title'] and all(accepted.get(key)==value for key,value in intent['request'].items()):matches.append(job)
            cursor=page.get('next_cursor')
            if not cursor or seen>=10000:break
        if len(matches)!=1:raise ValueError('A dispatched intent has no unique observable job. Preserve the ledger and resolve it manually; it will not be submitted again.')
        return matches[0]
    def observe(self,intent):
        started=time.monotonic();job=None
        if intent.get('job_id'):job=self.request('GET','generations/'+intent['job_id'])
        elif intent.get('dispatch_started'):job=self.recovered_job(intent)
        else:
            intent['dispatch_started']=True;intent['submission_started_at']=time.time();self.save()
            job=self.request('POST','generations',intent['request'],{'Idempotency-Key':intent['idempotency_key']})
            intent['acknowledged_at']=time.time()
        if job.get('store_id')!=self.state['store_id']:raise ValueError('The observed job belongs to another canonical store.')
        if not re.fullmatch('[A-Za-z0-9_-]{1,128}',job['job_id']):raise ValueError('The canonical server returned an unsafe job identity.')
        intent['job_id']=job['job_id'];self.save()
        while True:
            if job.get('store_id')!=self.state['store_id']:raise ValueError('The observed job changed store identity.')
            intent['job']=job;intent['last_observed_at']=time.time()
            intent.setdefault('state_first_observed_at',{}).setdefault(job['state'],time.time())
            intent.setdefault('stage_first_observed_at',{}).setdefault(job.get('stage',job['state']),time.time())
            intent['timing_scope']='client observed stages including queue, network and any restart downtime; not isolated model execution'
            self.save()
            if job['state'] in TERMINAL:return job
            if job['state']=='submission_unknown':raise ValueError('Unexpected unresolved execution; this local-only qualification run will not replay it.')
            if job['state']=='recovery_hold':
                job=self.request('POST','generations/'+job['job_id']+'/resume',{})
                intent['resume_requested_at']=time.time();self.save();continue
            if time.monotonic()-started>self.max_wait:raise ValueError('Observation reached its time bound. The server job may continue; restart this ledger to observe it without submission.')
            time.sleep(self.poll);job=self.request('GET','generations/'+job['job_id'])
    def original(self,job,intent,case_id):
        aid=job.get('asset_id')
        if not isinstance(aid,str) or not re.fullmatch('[A-Za-z0-9_-]{1,128}',aid):raise ValueError('A successful job has no safe asset identity.')
        asset=self.request('GET','assets/'+aid)
        if asset.get('store_id')!=self.state['store_id']:raise ValueError('The original belongs to a different store.')
        suffix=Path(asset['filename']).suffix.lower()
        if suffix not in ('.wav','.mp3','.flac'):raise ValueError('The actual original uses an unsupported audio format.')
        media=self.output/'media';media.mkdir(exist_ok=True);destination=media/(case_id+'-'+aid+suffix)
        if not destination.is_file() or digest_file(destination)!=asset['sha256']:
            self.api.download('assets/'+aid+'/content',destination,headers={'X-Nativ-Store-ID':self.state['store_id']},expected_sha256=asset['sha256'])
        intent['asset']=asset;intent['original_file']=str(destination.relative_to(self.output));self.save()
    def execute(self):
        try:
            self.bind()
            for case in self.cases:
                intent=self.state['cases'].get(case['id'])
                if intent is None:
                    request=dict(case['request'],title='Nativ QA '+self.state['run_id']+' '+case['id'])
                    intent=dict(idempotency_key=str(uuid.uuid4()),request=request,dispatch_started=False,observed_system_before=observed_system())
                    self.state['cases'][case['id']]=intent;self.save()
                job=self.observe(intent)
                if job['state']=='succeeded':self.original(job,intent,case['id'])
                intent['observed_system_after']=observed_system();self.save()
            return self.report()
        finally:
            try:
                if self.state.get('store_id'):self.report()
            finally:self.close()
    def report(self):
        latencies=sorted(self.latencies);pins={}
        for file in (ROOT/'PythonDistribution/MusicRuntimes').glob('*.json'):
            value=json.loads(file.read_text())
            if value.get('profile_id') in self.state['profiles']:pins[value['profile_id']]=value
        result=dict(run_models=True,qualified=False,qualification_status='human_review_required',run_id=self.state['run_id'],store_id=self.state['store_id'],
            canonical_server=self.base_url,corpus_sha256=self.state['corpus_sha256'],profiles=self.state['profiles'],runtime_manifests=pins,cases=self.state['cases'],
            status_latency_seconds=dict(scope='latest_at_most_512_client_observations_including_network',count=len(latencies),median=statistics.median(latencies) if latencies else None,p95=latencies[min(len(latencies)-1,int(.95*len(latencies)))] if latencies else None),
            human_review_required=['Listen to every retained original','Review complete audio, pitch/timing, style and exact English/Dutch lyrics where used','Measure actual model peak memory separately from system snapshots','Complete cancellation, coexistence, responsiveness, repeated-job cleanup and signed-runtime acceptance','Manually review and sign qualification against these exact pins; the runner never promotes the catalog'])
        atomic(self.output/'report.json',result)
        review=self.output/'quality-review.json'
        if not review.exists():atomic(review,dict(run_id=self.state['run_id'],qualified=False,reviewer=None,cases={case['id']:dict(approved=False,notes='',focus=case.get('review_focus',[])) for case in self.cases}))
        return result


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--run-models',action='store_true');parser.add_argument('--corpus',type=Path,default=CORPUS)
    parser.add_argument('--output',type=Path,default=ROOT/'build/validation/music-qualification');parser.add_argument('--base-url',default='http://127.0.0.1:8181')
    parser.add_argument('--token-env',default='NATIV_TOKEN');parser.add_argument('--profiles',nargs='+');parser.add_argument('--poll-seconds',type=float,default=1);parser.add_argument('--max-wait',type=float,default=7200)
    args=parser.parse_args(argv);cases=load_corpus(args.corpus)
    if args.profiles:
        available={case['request']['model'] for case in cases}
        if set(args.profiles)-available:raise ValueError('Select profiles present in the frozen corpus.')
        cases=[case for case in cases if case['request']['model'] in args.profiles]
    if not args.run_models:
        result=dict(run_models=False,qualified=False,network_requests=0,cases=cases,case_count=len(cases),corpus_sha256=fingerprint(cases),message='Dry run only. --run-models explicitly authorizes these local-profile jobs on the verified canonical server; human review remains mandatory.')
        atomic(args.output/'dry-run.json',result);print(json.dumps({key:value for key,value in result.items() if key!='cases'},indent=2));return result
    if not 0<=args.poll_seconds<=60 or args.max_wait<=0:raise ValueError('Choose bounded polling and a positive observation limit.')
    runner=Runner(base_url=args.base_url,output=args.output,cases=cases,transport=HTTP(args.base_url,os.environ.get(args.token_env,'')),poll_seconds=args.poll_seconds,max_wait=args.max_wait)
    result=runner.execute();print(json.dumps(dict(run_id=result['run_id'],qualified=result['qualified'],case_count=len(result['cases']),report=str(args.output/'report.json')),indent=2));return result


if __name__=='__main__':
    try:main()
    except (ValueError,OSError,KeyboardInterrupt) as error:
        print('Qualification stopped: '+('Interrupted; preserve this ledger for observation.' if isinstance(error,KeyboardInterrupt) else str(error)),file=sys.stderr);raise SystemExit(1)
