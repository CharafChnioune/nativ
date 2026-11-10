"""Durable common scheduler; adapters only execute, never own jobs or assets."""
from __future__ import annotations
import copy
import importlib
import json
import math
import os
from pathlib import Path
import re
import threading
from urllib.parse import urlsplit
from .assets import AssetStore
from .contracts import GenerationCancelled,GenerationError,ProviderContext,ProviderServices
from .repository import GenerationRepository,encode,fingerprint,TERMINAL
from .resources import ComputeAdmission

CONFIG_BOOLEANS={'enabled','experimental_enabled','license_accepted','allow_local_http','account_eligible','separate_license_approved'}
CONFIG_TEXT={'endpoint','account_id','region'}

def environment_credential(profile):
    return os.environ.get('NATIV_GENERATION_'+re.sub('[^A-Za-z0-9]','_',profile).upper()+'_API_KEY')

def catalog():
    from nativ_music.catalog import profiles as music
    from nativ_video.catalog import profiles as video
    return music()+video()

def build_provider(profile,services):
    return importlib.import_module('nativ_'+profile['modality']+'.providers').build_provider(profile,services)

def public_job(job):
    # Never expose local runtime paths, provider signed URLs or private account bindings.
    result={k:v for k,v in job.items() if k not in {'configuration_identity','provider_operation'}}
    result['provider_operation_known']=bool(job.get('provider_operation'))
    return result

def public_asset(asset): return {k:v for k,v in asset.items() if k!='relative_path'}

class GenerationService:
    def __init__(self,root,*,profiles=None,provider_factory=build_provider,worker=None,runtimes=None,transport=None,credentials=environment_credential,admission=None,autostart=True):
        self.repo=GenerationRepository(Path(root))
        try:
            self.profiles={p['id']:p for p in (catalog() if profiles is None else profiles)}
            self.factory=provider_factory;self.worker=worker;self.runtimes=runtimes;self.transport=transport;self.credentials=credentials
            self.admission=admission or ComputeAdmission(Path(root).parent/'compute-admission.lock')
            self.assets=AssetStore(self.repo,codec_paths=getattr(runtimes,'codec_paths',None))
            self.assets.recover();self.repo.recover()
            self._lock=threading.RLock();self._wake=threading.Event();self._stopping=threading.Event();self._active={};self._reconcile=set();self._scheduler=None;self._closed=False
            # Known accepted remote work may be safely looked up once after restart.
            with self.repo.lock:
                for row in self.repo.connection.execute("SELECT id FROM jobs WHERE state='retrieval_pending'"):
                    self._reconcile.add(row[0])
            if autostart:self.start()
        except BaseException:
            # Recovery/setup errors must not pin a library through a retained
            # startup traceback while unrelated server features keep running.
            try:
                scheduler=getattr(self,'_scheduler',None)
                if scheduler is not None and scheduler.is_alive(): self.close()
                else: self.repo.close()
            except Exception: pass
            raise

    def start(self):
        with self._lock:
            if self._scheduler is not None:return
            self._scheduler=threading.Thread(target=self._loop,name='Nativ generations',daemon=True);self._scheduler.start()
    def _config(self,pid):
        with self.repo.lock:
            row=self.repo.connection.execute('SELECT value FROM meta WHERE key=?',('profile:'+pid,)).fetchone()
        return json.loads(row[0]) if row else {}
    def configuration(self,modality):
        return {'profiles':{pid:dict(self._config(pid),runtime=p.get('runtime'),**self.readiness(p)) for pid,p in self.profiles.items() if p['modality']==modality}}
    def configure(self,pid,values):
        self.profile(pid)
        if not isinstance(values,dict):raise GenerationError('invalid_configuration','Supply a configuration object.')
        for key,value in values.items():
            if key in CONFIG_BOOLEANS and type(value) is bool:continue
            if key in CONFIG_TEXT and isinstance(value,str) and len(value)<=2000:continue
            raise GenerationError('invalid_configuration','Unsupported configuration value. Secrets and file paths are not accepted here.',field=key)
        with self.repo.transaction():
            config=self._config(pid);config.update(values)
            provider=self.profile(pid)['provider']
            if config.get('endpoint')=='':config.pop('endpoint',None)
            if config.get('endpoint'):config['endpoint']=config['endpoint'].rstrip('/')
            fixed={'lyria':'https://generativelanguage.googleapis.com','stable_audio_cloud':'https://api.stability.ai',
                   'runway':'https://api.dev.runwayml.com','ltx_cloud':'https://api.ltx.io'}
            if provider in fixed and config.get('endpoint',fixed[provider])!=fixed[provider]:
                raise GenerationError('unsupported_endpoint','This hosted profile uses its documented fixed endpoint.',field='endpoint')
            if provider=='minimax_cloud':
                if 'region' in values and 'endpoint' not in values:
                    config['endpoint']='https://api.minimax.cn' if values['region']=='china' else 'https://api.minimax.io'
                endpoint=config.get('endpoint','https://api.minimax.io')
                if endpoint not in {'https://api.minimax.io','https://api.minimax.cn'}:raise GenerationError('unsupported_endpoint','Choose the documented MiniMax global or China endpoint.',field='endpoint')
                region='china' if endpoint.endswith('.cn') else 'global'
                if 'region' in values and values['region']!=region:raise GenerationError('region_mismatch','The selected account region and endpoint differ.',field='region')
                config['region']=region
            elif 'region' in values:raise GenerationError('unsupported_configuration','This profile has no selectable account region.',field='region')
            if config.get('endpoint'):
                url=urlsplit(config['endpoint']);local=url.hostname in {'localhost','127.0.0.1','::1'}
                if url.username or url.password or url.query or url.fragment or not url.hostname or (url.scheme!='https' and not(url.scheme=='http' and local and config.get('allow_local_http'))):
                    raise GenerationError('invalid_endpoint','Use HTTPS, or explicitly enabled loopback HTTP.',field='endpoint')
            if config.get('region','global') not in {'global','china'}:raise GenerationError('invalid_region','Choose global or china.',field='region')
            self.repo.connection.execute('INSERT OR REPLACE INTO meta VALUES(?,?)',('profile:'+pid,encode(config)))
        self._wake.set();return dict(config,runtime=self.profile(pid).get('runtime'),**self.readiness(self.profile(pid)))
    def profile(self,pid,modality=None):
        p=self.profiles.get(pid)
        if p is None or (modality and p['modality']!=modality):raise GenerationError('model_not_found','Choose an advertised generation profile.',field='model',status=404)
        return p
    def readiness(self,p):
        cfg=self._config(p['id']);reason=None
        if p['provider']=='acestep':reason='ACE-Step is disabled in this build: its runtime runs PyTorch on MPS instead of MLX.'
        elif not cfg.get('enabled'):reason='Enable this provider explicitly in generation settings.'
        elif p.get('qualification')!='qualified' and not cfg.get('experimental_enabled'):reason='This profile has not passed real-model qualification. Explicit experimental opt-in is required.'
        elif self.factory is build_provider and p['modality']=='music' and not self.assets.codec_paths:reason='Repair the application’s managed audio decoder before submitting music, including paid requests.'
        elif p['deployment']=='local':
            if not cfg.get('license_accepted'):reason='Review and accept the model license before installing or executing it.'
            elif p['provider']=='minimax_h3_mlx' and (not cfg.get('separate_license_approved') or self.runtimes is None or not self.runtimes.manifests.get(p['id'],{}).get('manifest',{}).get('qualified_hardware')):reason='MiniMax H3 execution is blocked until separate license eligibility and reviewed hardware qualification are established.'
            elif p.get('runtime') and (self.runtimes is None or not self.runtimes.ready(p['id'])):reason='Install or repair the isolated runtime and its pinned model components.'
            elif p.get('runtime') and self.runtimes.outdated(p['id']):reason='Repair this runtime: it holds worker code from another Nativ build.'
            elif p['provider']=='minimax_h3_mlx' and not cfg.get('separate_license_approved'):reason='This model requires separate license and geographic eligibility approval.'
        elif p['provider']=='minimax_remote' and not cfg.get('endpoint'):reason='Configure the explicit MiniMax GPU server endpoint.'
        elif not cfg.get('account_id'):reason='Configure a stable provider account identity for recovery.'
        elif not self.credentials(p['id']):reason='Add the provider credential to Keychain, then restart the local server.'
        elif p['provider']=='minimax_cloud' and not cfg.get('account_eligible'):reason='This endpoint requires an existing eligible MiniMax account.'
        return {'readiness':'ready' if reason is None else 'unavailable','unavailable_reason':reason}
    def models(self,modality):return {'items':[dict(p,**self.readiness(p)) for p in self.profiles.values() if p['modality']==modality],'next_cursor':None}
    def _services(self,p,identity=None):
        cfg=copy.deepcopy(identity or self._config(p['id']))
        if p['deployment']=='local' and self.runtimes:
            frozen=cfg.get('_runtime_manifest_sha256')
            current=fingerprint(self.runtimes.manifests[p['id']]['manifest'])
            if frozen is not None and frozen!=current:raise GenerationError('runtime_revision_changed','The accepted runtime revision changed. Restore it or create a new explicit generation.',status=409)
            cfg.update(self.runtimes.prepared(p['id']))
        return ProviderServices(worker=self.worker,transport=self.transport,credentials=self.credentials,configuration={p['id']:cfg})
    def submit(self,modality,request,key):
        if self._stopping.is_set():raise GenerationError('server_stopping','The server is stopping. Reconnect before retrying the saved request.',status=503)
        if not isinstance(request,dict):raise GenerationError('invalid_request','A JSON object is required.')
        if not isinstance(key,str) or not key.strip() or len(key)>200:raise GenerationError('missing_idempotency_key','Supply an Idempotency-Key.',field='Idempotency-Key')
        if not isinstance(request.get('model'),str):raise GenerationError('model_required','Choose a model profile.',field='model')
        if request.get('session_id') is not None and (not isinstance(request['session_id'],str) or len(request['session_id'])>128):raise GenerationError('invalid_session','Use a session ID from this store.',field='session_id')
        # Serialize initial acceptance to freeze randomized/default fields once per identity.
        with self._lock:
            if self._stopping.is_set():raise GenerationError('server_stopping','The server is stopping. Reconnect before retrying the saved request.',status=503)
            old=self.repo.idempotent_job(modality,key)
            if old:
                accepted=copy.deepcopy(old['request'])
                if request['model']!=accepted['model']:raise GenerationError('idempotency_conflict','This identity belongs to a different selected profile.',status=409)
                normal=dict(request)
                if normal.get('seed') is None and 'seed' in accepted:normal['seed']=accepted['seed']
                services=ProviderServices(configuration={old['profile']['id']:old['configuration_identity'] or {}})
                provider=self.factory(old['profile'],services)
                if fingerprint(provider.normalize(normal))!=fingerprint(accepted):raise GenerationError('idempotency_conflict','This identity already belongs to another normalized request.',status=409)
                return old
            profile=copy.deepcopy(self.profile(request['model'],modality));ready=self.readiness(profile)
            if ready['readiness']!='ready':raise GenerationError('provider_unavailable',ready['unavailable_reason'],field='model',status=409)
            cfg=self._config(profile['id'])
            if profile['deployment']=='local' and self.runtimes:cfg['_runtime_manifest_sha256']=fingerprint(self.runtimes.manifests[profile['id']]['manifest'])
            provider=self.factory(profile,self._services(profile,cfg))
            accepted=provider.normalize(request)
            for item in accepted.get('inputs',[]):self.assets.input(item['input_id'])
            job=self.repo.submit(modality,accepted,profile,key,input_records=accepted.get('inputs',[]),configuration_identity=cfg)
            with self.repo.transaction():
                job['submitted_request']=copy.deepcopy(request);self.repo._save(job,'accepted_request')
            self._wake.set();return job
    def cancel(self,jid):
        job=self.repo.cancel(jid)
        with self._lock:
            active=self._active.get(jid)
            if active:active['cancel'].set()
            elif job['state']=='cancel_requested':
                cancel=threading.Event()
                thread=threading.Thread(target=self._cancel_inactive,args=(job,cancel),name='Nativ cancellation',daemon=True)
                self._active[jid]={'thread':thread,'cancel':cancel,'lane':'cancel:'+jid};thread.start()
            self._reconcile.discard(jid)
        self._wake.set();return job
    def _cancel_inactive(self,job,cancel):
        provider=None;confirmation=None
        try:
            old=job['configuration_identity'];current=self._config(job['profile']['id'])
            if any(old.get(k)!=current.get(k) for k in ('account_id','endpoint','region')):raise GenerationError('provider_identity_changed','Restore the original account before contacting this provider operation.',status=409)
            provider=self._execution_provider(job)
            context=ProviderContext(output_dir=self.assets.attempt_dir(job),cancellation=cancel,emit=lambda *a:None,dispatch=lambda:None,operation=lambda op:self.repo.record_operation(job['job_id'],job['attempt_id'],op))
            confirmation=provider.cancel(job,context)
        except Exception:pass
        finally:
            confirmed=not job['dispatch_intent'] or bool(confirmation and (confirmation.confirmed or confirmation.provider_terminal))
            self.repo.finish_cancel(job['job_id'],job['attempt_id'],confirmed=confirmed,outcome=confirmation.provider_outcome if confirmation else 'unknown')
            if provider:
                try:provider.shutdown()
                except Exception:pass
            with self._lock:self._active.pop(job['job_id'],None)
            self._wake.set()
    def resume(self,jid):
        value=self.repo.resume(jid);self._wake.set();return value
    def retry_download(self,jid):
        job=self.repo.get_job(jid)
        if job['state']=='succeeded':return job
        if job['state'] not in {'retrieval_pending','submission_unknown'} or not job['provider_operation'] or not job['profile'].get('capabilities',{}).get('retrieval_supported') or job['cancel_requested']:
            raise GenerationError('not_retrievable','Only an existing accepted provider operation can be downloaded again.',status=409)
        with self._lock:self._reconcile.add(jid)
        self._wake.set();return job
    def _loop(self):
        while not self._stopping.is_set():
            self._wake.wait(.15);self._wake.clear()
            with self._lock:
                candidates=[(j,False) for j in self.repo.queued_jobs()]+[(self.repo.get_job(j),True) for j in self._reconcile]
                for job,reconcile in candidates:
                    if reconcile and (job['state'] not in {'retrieval_pending','submission_unknown'} or job['cancel_requested']):
                        self._reconcile.discard(job['job_id']);continue
                    if job['job_id'] in self._active:continue
                    local=job['profile']['deployment']=='local';lane='local' if local else job['modality']
                    if any(a['lane']==lane for a in self._active.values()):continue
                    lease=self.admission.try_acquire('generation:'+job['job_id']) if local else None
                    if local and lease is None:continue
                    try:
                        if not reconcile:job=self.repo.begin_attempt(job['job_id'])
                    except GenerationError:
                        if lease:lease.close()
                        continue
                    self._reconcile.discard(job['job_id']);cancel=threading.Event()
                    thread=threading.Thread(target=self._execute,args=(job,cancel,lease,reconcile),name='Nativ '+lane,daemon=True)
                    self._active[job['job_id']]={'thread':thread,'cancel':cancel,'lane':lane};thread.start()
    def _execute(self,job,cancel,lease,reconcile):
        jid,attempt=job['job_id'],job['attempt_id'];provider=None
        def progress(stage,value,details):
            if not isinstance(stage,str) or len(stage)>100:return
            if value is not None and (type(value) not in (int,float) or not math.isfinite(value) or not 0<=value<=1):return
            updates={'stage':stage,'progress':value}
            # This is an observation of completed remote execution, independent
            # of successful download/decoding. Never persist arbitrary provider
            # details, URLs or credentials in public events.
            if job['profile']['deployment']!='local' and details.get('provider_outcome')=='completed':
                updates.update(provider_outcome='completed',remote_reservation='released')
            self.repo.update_attempt(jid,attempt,**updates)
        context=ProviderContext(output_dir=self.assets.attempt_dir(job),cancellation=cancel,emit=progress,
            dispatch=lambda:self._dispatch(job),operation=lambda op:self.repo.record_operation(jid,attempt,op))
        context.compute_lease_fd=lease.file.fileno() if lease else None
        try:
            if not reconcile:
                readiness=self.readiness(job['profile'])
                if readiness['readiness']!='ready':raise GenerationError('provider_unavailable',readiness['unavailable_reason'],status=409)
            if lease:
                try:from nativ_image_execution import unload_idle_images
                except ImportError:pass
                else:unload_idle_images()
                from .host_admission import unload_idle_host_models
                unload_idle_host_models()
            if job['profile']['deployment']!='local':
                old=job['configuration_identity'];current=self._config(job['profile']['id'])
                if any(old.get(k)!=current.get(k) for k in ('account_id','endpoint','region')):raise GenerationError('provider_identity_changed','Restore the original provider account and endpoint to retrieve this generation.',status=409,definitive=False)
            provider=self._execution_provider(job)
            if job['modality']=='video':
                context.inputs=self.assets.prepare_inputs(job)
                job['inputs_provenance']={key:{k:v for k,v in value.items() if k!='path'} for key,value in context.inputs.items()}
                if not self.repo.update_attempt(jid,attempt,inputs_provenance=job['inputs_provenance']):raise GenerationCancelled()
            result=provider.reconcile(job,context) if reconcile else provider.run(job,context)
            if job['profile']['deployment']!='local':self.repo.update_attempt(jid,attempt,provider_outcome='completed',remote_reservation='released')
            context.check_cancelled();self.assets.publish(job,result,cancel)
        except (GenerationCancelled,GenerationError) as error:
            latest=self.repo.get_job(jid)
            if cancel.is_set() or latest['cancel_requested'] or isinstance(error,GenerationCancelled):
                confirmation=None
                if provider and latest['profile']['deployment']!='local' and latest['dispatch_intent']:
                    try:confirmation=provider.cancel(latest,context)
                    except Exception:pass
                confirmed=latest['profile']['deployment']=='local' or not latest['dispatch_intent'] or bool(confirmation and (confirmation.confirmed or confirmation.provider_terminal))
                self.repo.finish_cancel(jid,attempt,confirmed=confirmed,outcome=confirmation.provider_outcome if confirmation else ('cancelled' if confirmed else 'unknown'))
            else:self._failure(latest,error)
        except BaseException:
            self._failure(self.repo.get_job(jid),GenerationError('provider_failed','The provider stopped unexpectedly. Inspect the runtime installation or retry retrieval of an existing operation.',status=502,definitive=False))
        finally:
            if provider:
                try:provider.shutdown()
                except Exception:pass
            if lease:lease.close()
            with self._lock:self._active.pop(jid,None)
            self._wake.set()
    def _dispatch(self,job):
        with self.repo.lock:
            current_profile=self.profile(job['profile']['id'])
            if any(current_profile.get(k)!=job['profile'].get(k) for k in ('profile_revision','provider','model','runtime','model_revision')):
                raise GenerationError('profile_changed','The accepted provider profile changed after an app update. Review the new profile and create a new explicit generation.',status=409)
            readiness=self.readiness(job['profile'])
            if readiness['readiness']!='ready':raise GenerationError('provider_unavailable',readiness['unavailable_reason'],status=409)
            current=self._config(job['profile']['id']);old=job['configuration_identity']
            if any(old.get(k)!=current.get(k) for k in ('account_id','endpoint','region')):raise GenerationError('provider_identity_changed','The provider connection changed before dispatch. Submit a new explicit request.',status=409)
            self.repo.dispatch(job['job_id'],job['attempt_id'])
    def _execution_provider(self,job):
        services=self._services(job['profile'],job['configuration_identity'])
        if job['profile']['deployment']!='local' and self.factory is build_provider and self.transport is None:
            from .remote_process import RemoteExecutionProvider
            return RemoteExecutionProvider(job['profile'],services)
        return self.factory(job['profile'],services)
    def _failure(self,job,error):
        if job['state'] in TERMINAL:return
        remote=job['profile']['deployment']!='local'
        state='failed';reservation='released'
        terminal_codes={'provider_generation_failed','provider_cancelled','output_expired','provider_content_rejected','provider_rejected'}
        terminal_observed=error.definitive and error.code in terminal_codes
        if remote and job['dispatch_intent'] and not terminal_observed:
            retrievable=bool(job['provider_operation']) and job['profile'].get('capabilities',{}).get('retrieval_supported',False)
            completed=job['provider_outcome'] in {'completed','succeeded','failed','cancelled'}
            state='retrieval_pending' if retrievable else ('failed' if completed else 'submission_unknown')
            reservation='released' if completed else job['remote_reservation']
        self.repo.update_attempt(job['job_id'],job['attempt_id'],state=state,stage=state,error=error.public(job['job_id']),remote_reservation=reservation)
    def server_state(self):
        with self._lock:
            active=len(self._active);queued=len(self.repo.queued_jobs())
            with self.repo.lock:
                reserved=sum(json.loads(r[0])['remote_reservation']=='reserved' for r in self.repo.connection.execute('SELECT data FROM jobs'))
            setups=len(self.runtimes._tasks) if self.runtimes else 0
            return {'pending_count':active+queued+setups,'active_count':active,'queued_count':queued,'remote_reserved_count':reserved,'setup_count':setups,'stopping':self._stopping.is_set(),'ready_to_stop':active==0 and setups==0}
    def prepare_stop(self):
        # Serialize the stop fence and queued snapshot with acceptance. A submit
        # already normalizing either commits before this fence and is held, or
        # observes stopping and is rejected; none can appear after the snapshot.
        with self._lock:
            self._stopping.set();self._wake.set()
            for job in self.repo.queued_jobs():self.repo.update_attempt(job['job_id'],None,state='recovery_hold',stage='recovery_hold')
        if self._scheduler:self._scheduler.join()
        # An iteration that was already awake may finish admitting an existing
        # reconciliation before it exits; include it in cancellation as well.
        with self._lock:active=list(self._active.items())
        for jid,entry in active:
            self.repo.cancel(jid);entry['cancel'].set()
        if self.runtimes:
            with self.runtimes._lock:
                for task in self.runtimes._tasks.values():task['cancel'].set()
        return self.server_state()
    def close(self):
        if self._closed:return
        self.prepare_stop()
        with self._lock:active=list(self._active.items())
        # Never release compute capacity or the storage lock while workers still run.
        for _,entry in active:entry['thread'].join()
        if self.runtimes:self.runtimes.close()
        self.repo.recover();self.repo.close();self._closed=True
