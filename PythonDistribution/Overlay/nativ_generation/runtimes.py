"""Explicit isolated setup and owned one-job process supervision."""
from __future__ import annotations
import importlib.util
import json
import os
import re
from pathlib import Path,PurePosixPath
import selectors
import shutil
import signal
import subprocess
import sys
import threading
import time
import uuid
from .contracts import GenerationCancelled,GenerationError,ProviderResult
from .assets import digest_file,sync_directory
from .repository import encode,fingerprint


def resource_root():
    # Packaged layout has these siblings of the standalone Python prefix.
    choices=[Path(sys.prefix).parent,Path(__file__).resolve().parents[2]]
    for path in choices:
        if (path/'MusicRuntimes').is_dir() and (path/'VideoRuntimes').is_dir():return path
    return choices[0]

def child_environment(prefix,*,codec_paths=None):
    # No provider API keys, dynamic linker overrides or user site-packages.
    env={k:v for k,v in os.environ.items() if k in ('HOME','TMPDIR','USER','LOGNAME','LANG')}
    env.update(PATH='/usr/bin:/bin:/usr/sbin:/sbin',PYTHONNOUSERSITE='1',PYTHONSAFEPATH='1',PYTHONDONTWRITEBYTECODE='1',HF_HUB_OFFLINE='1',TRANSFORMERS_OFFLINE='1',TOKENIZERS_PARALLELISM='false')
    # Developer venvs reference their base stdlib through pyvenv.cfg; forcing
    # PYTHONHOME to that venv hides encodings. Standalone app prefixes own it.
    if not (Path(prefix)/'pyvenv.cfg').is_file():env['PYTHONHOME']=str(prefix)
    if codec_paths:
        env['PATH']=str(Path(codec_paths['ffmpeg']).parent)+':'+env['PATH'];env['IMAGEIO_FFMPEG_EXE']=codec_paths['ffmpeg']
    return env


def write_all(stream,data,*,timeout=30,cancellation=None):
    """Write one complete bounded protocol frame, with backpressure/cancel bounds."""
    view=memoryview(data);offset=0;deadline=time.monotonic()+timeout;selector=None;descriptor=None;blocking=None
    try:
        try:descriptor=stream.fileno()
        except (AttributeError,OSError):pass
        if descriptor is not None:
            blocking=os.get_blocking(descriptor);os.set_blocking(descriptor,False)
            selector=selectors.DefaultSelector();selector.register(descriptor,selectors.EVENT_WRITE)
        while offset<len(view):
            if cancellation is not None and cancellation.is_set():raise GenerationCancelled()
            remaining=deadline-time.monotonic()
            if remaining<=0:raise GenerationError('worker_write_timeout','The owned helper did not accept its bounded request.',status=504,definitive=False)
            if selector is not None and not selector.select(min(.05,remaining)):continue
            try:written=os.write(descriptor,view[offset:]) if descriptor is not None else stream.write(view[offset:])
            except BlockingIOError:continue
            if written is None:continue
            if written<=0:raise GenerationError('worker_pipe_closed','The owned helper closed its request pipe.',status=502,definitive=False)
            offset+=written
    finally:
        if selector is not None:selector.close()
        if descriptor is not None and blocking is not None:
            try:os.set_blocking(descriptor,blocking)
            except OSError:pass


def read_handshake(process,*,timeout=30,cancellation=None):
    """A partial JSON line cannot turn a readiness probe into a blocking read."""
    selector=selectors.DefaultSelector();selector.register(process.stdout,selectors.EVENT_READ)
    os.set_blocking(process.stdout.fileno(),False);buffer=bytearray();deadline=time.monotonic()+timeout
    try:
        while True:
            if cancellation is not None and cancellation.is_set():raise GenerationCancelled()
            remaining=deadline-time.monotonic()
            if remaining<=0:raise GenerationError('worker_handshake_timeout','The isolated worker did not finish its identity handshake.',status=503)
            for key,_ in selector.select(min(.05,remaining)):
                chunk=os.read(key.fd,65536)
                if not chunk:raise GenerationError('worker_identity_mismatch','The isolated worker closed before identifying itself.',status=503)
                buffer.extend(chunk)
                if len(buffer)>65536:raise GenerationError('worker_protocol_limit','The isolated worker emitted an oversized handshake.',status=503)
                if b'\n' in buffer:
                    try:return json.loads(buffer.split(b'\n',1)[0])
                    except (ValueError,UnicodeError):raise GenerationError('worker_identity_mismatch','The isolated worker returned an invalid identity handshake.',status=503) from None
    finally:selector.close()

class RuntimeManager:
    def __init__(self,root,*,resources=None,python_prefix=None):
        self.root=Path(root).resolve();self.root.mkdir(parents=True,exist_ok=True,mode=0o700)
        self.resources=Path(resources) if resources else resource_root();self.python_prefix=Path(python_prefix or sys.prefix)
        self.manifests={};self.manifest_errors=[];self.service=None;self._lock=threading.RLock();self._tasks={};self._states={}
        blocked=set()
        for modality,folder in (('music','MusicRuntimes'),('video','VideoRuntimes')):
            for file in sorted((self.resources/folder).glob('*.json')):
                value={}
                try:
                    if file.is_symlink():raise ValueError()
                    with file.open('rb') as stream:raw=stream.read(1024*1024+1)
                    if len(raw)>1024*1024:raise ValueError()
                    value=json.loads(raw)
                    self._validate_manifest(value,file.parent,modality)
                    pid=value['profile_id']
                    if pid in blocked or pid in self.manifests:
                        self.manifests.pop(pid,None);blocked.add(pid);raise ValueError()
                    self.manifests[pid]={'manifest':value,'modality':modality,'folder':folder}
                except Exception:
                    identifier=value.get('id',file.stem) if isinstance(value,dict) else file.stem
                    pid=value.get('profile_id') if isinstance(value,dict) else None
                    safe=lambda text:isinstance(text,str) and re.fullmatch(r'[A-Za-z0-9_.-]{1,200}',text) and text not in ('.','..')
                    self.manifest_errors.append({'id':identifier if safe(identifier) else 'invalid-manifest','profile_id':pid if safe(pid) else None,'modality':modality,
                        'status':'unavailable','stage':'manifest_invalid','error':{'code':'runtime_manifest_unavailable','message':'The pinned runtime manifest is missing, invalid or ambiguous. Repair the application package.'},
                        'qualification':'unqualified','required_model_bytes':0,'components':[],'licenses':[],'codec_ready':False})
        self.codec_paths=self._codecs()
    @staticmethod
    def _validate_manifest(value,folder,modality):
        safe=lambda text:isinstance(text,str) and re.fullmatch(r'[A-Za-z0-9_.-]{1,200}',text) and text not in ('.','..')
        sha=lambda text:isinstance(text,str) and re.fullmatch('[0-9a-f]{64}',text)
        relative=lambda text:isinstance(text,str) and text and not PurePosixPath(text).is_absolute() and '..' not in PurePosixPath(text).parts and text not in ('.','..')
        if not isinstance(value,dict) or value.get('schema_version')!=1 or not all(safe(value.get(key)) for key in ('id','profile_id','provider')):raise ValueError()
        if value.get('qualification') not in ('unqualified','experimental','qualified'):raise ValueError()
        worker=value['worker']
        if worker.get('module')!='nativ_'+modality+'.workers' or worker.get('protocol',1)!=1 or not isinstance(worker.get('args',[]),list) or any(not isinstance(arg,str) or len(arg)>1024 for arg in worker.get('args',[])):raise ValueError()
        lock=value['lock']
        if not relative(lock.get('path')) or not sha(lock.get('sha256')):raise ValueError()
        path=folder/lock['path']
        if path.is_symlink() or not path.resolve().is_relative_to(folder.resolve()) or digest_file(path)!=lock['sha256']:raise ValueError()
        models=value['models'];files=models['files']
        if not isinstance(files,list) or len(files)>10000:raise ValueError()
        revision=models.get('revision')
        if not (isinstance(revision,str) and re.fullmatch('[0-9a-f]{40}',revision)) and not (revision is None and models.get('gated') and not models.get('integrity_resolved')):raise ValueError()
        names=set()
        for item in files:
            if not isinstance(item,dict) or not relative(item.get('path')) or item['path'] in names or type(item.get('bytes')) is not int or not 0<=item['bytes']<=1024**4:raise ValueError()
            if not sha(item.get('sha256')) and not (item.get('sha256') is None and models.get('gated') and not models.get('integrity_resolved')):raise ValueError()
            names.add(item['path'])
    def _safe(self,path):
        path=Path(path)
        if not path.is_absolute() or path.resolve()!=path or not path.is_relative_to(self.root):raise GenerationError('runtime_ownership_invalid','The runtime contains an unowned or unsafe filesystem path.',status=409)
        return path
    def _profile_dir(self,pid):
        if not isinstance(pid,str) or not re.fullmatch(r'[A-Za-z0-9_.-]{1,200}',pid) or pid in ('.','..'):raise GenerationError('invalid_profile','Invalid managed runtime profile.',status=409)
        return self._safe(self.root/'profiles'/pid)
    def _owned_runtime(self,pid,path,manifest_sha256=None):
        try:
            path=self._safe(path)
            if path.parent!=self._profile_dir(pid) or not re.fullmatch('runtime-[0-9a-f]{32}',path.name) or not path.is_dir():return False
            marker_path=path/'.nativ-owned-runtime.json';receipt_path=path/'nativ-runtime.json'
            if marker_path.is_symlink() or receipt_path.is_symlink():return False
            marker=json.loads(marker_path.read_text());receipt=json.loads(receipt_path.read_text())
            return marker.get('schema_version')==1 and marker.get('profile_id')==pid and marker.get('folder')==path.name and marker.get('runtime_id')==receipt.get('id') and (manifest_sha256 is None or marker.get('manifest_sha256')==manifest_sha256)
        except (OSError,ValueError,TypeError,AttributeError,GenerationError):return False
    def _retire_owned(self,pid,keep=None):
        # Caller holds service._lock and has proved this profile is inactive.
        directory=self._profile_dir(pid)
        for candidate in directory.glob('runtime-*'):
            if candidate!=keep and self._owned_runtime(pid,candidate):shutil.rmtree(candidate)
    def _codecs(self):
        root=self.resources/'CodecRuntime/managed'
        try:
            receipt=json.loads((root/'receipt.json').read_text())
            paths={name:str(root/'bin'/name) for name in ('ffmpeg','ffprobe')}
            # Codec receipt shape is owned by the packaging module. Verify using it.
            module_path=self.resources/'CodecRuntime/manage.py'
            if module_path.exists():
                module=self._module(module_path,'nativ_codec_manager')
                if hasattr(module,'codec_paths'):return module.codec_paths(self.resources)
                elif hasattr(module,'verify'):module.verify(root)
                else:return {}
            else:return {}
            return paths
        except Exception:return {}
    @staticmethod
    def _module(path,name):
        spec=importlib.util.spec_from_file_location(name,path);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
    def bind(self,service):self.service=service;service.assets.codec_paths=self.codec_paths
    def _installation(self,pid):
        try:
            path=self._profile_dir(pid)/'installation.json'
            if path.is_symlink():return None
            value=json.loads(path.read_text());record=self.manifests.get(pid)
            if not isinstance(value,dict) or not record or value.get('manifest_sha256')!=fingerprint(record['manifest']):return None
            if not self._owned_runtime(pid,value.get('runtime_path',''),value['manifest_sha256']):return None
            model=self._safe(Path(value.get('model_path','')))
            if model.parent!=self._safe(self.root/'models'/pid) or not model.is_dir():return None
            return value
        except (OSError,ValueError,TypeError,GenerationError):return None
    def ready(self,pid):
        value=self._installation(pid)
        if not value:return False
        runtime=Path(value['runtime_path']);model=Path(value['model_path'])
        return (runtime/'python/bin/python3').is_file() and (runtime/'nativ-runtime.json').is_file() and (model/'nativ-model.json').is_file() and (self.manifests[pid]['modality']!='video' or bool(self.codec_paths))
    def prepared(self,pid):
        if not self.ready(pid):raise GenerationError('runtime_not_ready','Install or repair the complete isolated runtime and model before generation.',status=409)
        value=self._installation(pid);m=self.manifests[pid]['manifest'];model=value['model_path']
        return {'model_path':model,'checkpoints_dir':model,'source_path':str(Path(value['runtime_path'])/'source'),'codec_paths':self.codec_paths,'profile_id':pid,'model_revision':m['models']['revision']}
    def status(self,modality):
        items=[]
        with self._lock:
            for pid,entry in self.manifests.items():
                if entry['modality']!=modality:continue
                m=entry['manifest'];state=self._states.get(pid,{})
                components=[{k:item.get(k) for k in ('path','bytes','sha256','revision')} for item in m['models']['files']]
                items.append({'id':m['id'],'profile_id':pid,'status':'ready' if self.ready(pid) else state.get('status','not_installed'),'stage':state.get('stage'), 'progress':state.get('progress'),'error':state.get('error'),'qualification':m['qualification'],'required_model_bytes':sum(x['bytes'] for x in m['models']['files']),'licenses':m.get('licenses',[]),'codec_ready':bool(self.codec_paths),'components':components})
        known={item['profile_id'] for item in items}
        for entry in self.manifest_errors:
            if entry['modality']==modality and entry['profile_id'] not in known:items.append(dict(entry))
        for pid,profile in getattr(self.service,'profiles',{}).items():
            if profile.get('modality')==modality and profile.get('deployment')=='local' and pid not in self.manifests and pid not in known:
                items.append({'id':profile.get('runtime'),'profile_id':pid,'status':'unavailable','stage':'manifest_missing','error':{'code':'runtime_manifest_unavailable','message':'Repair this application’s pinned runtime resources.'},'qualification':'unqualified','required_model_bytes':0,'licenses':[],'components':[],'codec_ready':bool(self.codec_paths)})
        return items
    def action(self,runtime_id,action,profile_id=None):
        matching=[pid for pid,e in self.manifests.items() if e['manifest']['id']==runtime_id and (profile_id is None or pid==profile_id)]
        if not matching:raise GenerationError('runtime_manifest_unavailable','Repair the application’s pinned runtime manifest before using this profile.',status=409)
        if len(matching)!=1:raise GenerationError('profile_required','Choose the exact model profile for this runtime action.',field='profile_id',status=409)
        pid=matching[0]
        with self._lock:
            active=self._tasks.get(pid)
            if action=='cancel-install':
                if active:active['cancel'].set()
                return {'profile_id':pid,'status':'cancelling' if active else 'idle'}
            if active:raise GenerationError('installation_active','Wait until the active installation has stopped.',status=409)
            if self.service is None:raise GenerationError('server_starting','Runtime setup is not ready.',status=503)
            with self.service._lock:
                if any(self.service.repo.get_job(j)['profile']['id']==pid for j in self.service._active):raise GenerationError('runtime_in_use','Stop the active generation before changing this runtime.',status=409)
            if action=='remove':
                with self.service._lock:
                    if any(self.service.repo.get_job(j)['profile']['id']==pid for j in self.service._active):raise GenerationError('runtime_in_use','Stop the active generation before removing this runtime.',status=409)
                    directory=self._profile_dir(pid);activation=directory/'installation.json'
                    # Deactivate first; only individually marked owned interpreter
                    # folders are retired. Model/cache paths are never candidates.
                    activation.unlink(missing_ok=True)
                    self._retire_owned(pid)
                self._states[pid]={'status':'not_installed'};return {'profile_id':pid,'status':'removed','models_preserved':True}
            if action not in {'install','repair'}:raise GenerationError('invalid_action','Unknown runtime action.')
            cfg=self.service._config(pid)
            if not cfg.get('license_accepted') or not cfg.get('experimental_enabled'):raise GenerationError('license_acceptance_required','Review model licenses and opt in to this unqualified profile before installation.',status=409)
            if self.manifests[pid]['manifest']['provider']=='minimax_h3_mlx' and not cfg.get('separate_license_approved'):raise GenerationError('license_restricted','Separate eligibility approval is required before preparing this model.',status=409)
            if self.manifests[pid]['modality']=='video' and not self.codec_paths:raise GenerationError('codec_unavailable','This app is missing its verified FFmpeg encoder. Repair the application package.',status=409)
            cancel=threading.Event();thread=threading.Thread(target=self._install,args=(pid,cancel),name='Nativ runtime setup',daemon=True)
            self._tasks[pid]={'cancel':cancel,'thread':thread};self._states[pid]={'status':'installing','stage':'preparing','progress':None};thread.start()
            return {'profile_id':pid,'status':'installing'}
    def _install(self,pid,cancel):
        entry=self.manifests[pid];manifest=entry['manifest'];lease=None
        def emit(stage,progress):
            with self._lock:self._states[pid]={'status':'installing','stage':stage,'progress':progress}
        try:
            lease=self.service.admission.try_acquire('runtime-install:'+pid)
            if lease is None:raise GenerationError('compute_busy','Stop the active inference or Live Translate before installing a runtime.',status=409)
            folder=self.resources/entry['folder'];manager=self._module(folder/'manage.py','nativ_'+entry['modality']+'_setup')
            token=os.environ.get('HF_TOKEN')
            actual=manager.resolve_model_inventory(manifest,token=token) if hasattr(manager,'resolve_model_inventory') else manifest
            model=self._safe(self.root/'models'/pid/fingerprint(manifest['models'])[:20])
            manager.prepare_models(actual,model,cancel,emit,accepted_licenses=True,token=token)
            directory=self._profile_dir(pid);directory.mkdir(parents=True,exist_ok=True,mode=0o700)
            runtime=directory/('runtime-'+uuid.uuid4().hex)
            manager.build_runtime(actual,runtime,self.python_prefix,cancel,emit)
            marker=runtime/'.nativ-owned-runtime.json';marker.write_text(encode({'schema_version':1,'profile_id':pid,'runtime_id':manifest['id'],'folder':runtime.name,'manifest_sha256':fingerprint(manifest)}));os.chmod(marker,0o600)
            with marker.open('rb') as stream:os.fsync(stream.fileno())
            sync_directory(runtime)
            if cancel.is_set():raise InterruptedError()
            # Prove standalone worker protocol before activation, without loading weights.
            WorkerSupervisor.handshake(runtime/'python',manifest,cancellation=cancel)
            value={'manifest_sha256':fingerprint(manifest),'runtime_path':str(runtime),'model_path':str(model),'qualification':'unqualified'}
            with self.service._lock:
                if any(self.service.repo.get_job(j)['profile']['id']==pid for j in self.service._active):raise GenerationError('runtime_in_use','The previous runtime started a generation during setup. Retry repair after it stops.',status=409)
                partial=directory/'installation.partial';partial.write_text(encode(value));os.chmod(partial,0o600)
                with partial.open('rb') as f:os.fsync(f.fileno())
                os.replace(partial,directory/'installation.json');sync_directory(directory)
                self._retire_owned(pid,keep=runtime)
            with self._lock:self._states[pid]={'status':'ready','stage':'installed','progress':1.0}
        except BaseException as error:
            with self._lock:self._states[pid]={'status':'cancelled' if cancel.is_set() else 'failed','stage':'stopped','progress':None,'error':error.public() if isinstance(error,GenerationError) else {'code':'runtime_setup_failed','message':'Runtime preparation did not complete. Verify license access, available disk space and the pinned dependency installation; Repair can resume verified model downloads.'}}
        finally:
            if lease:lease.close()
            with self._lock:self._tasks.pop(pid,None)
    def close(self):
        with self._lock:tasks=list(self._tasks.values())
        for task in tasks:task['cancel'].set()
        for task in tasks:task['thread'].join()

class WorkerSupervisor:
    def __init__(self,manager):self.manager=manager
    @staticmethod
    def _stop(process):
        if process.poll() is not None:return
        try:os.killpg(process.pid,signal.SIGTERM)
        except ProcessLookupError:pass
        try:process.wait(5)
        except subprocess.TimeoutExpired:
            try:os.killpg(process.pid,signal.SIGKILL)
            except ProcessLookupError:pass
            process.wait()
    @staticmethod
    def handshake(prefix,manifest,*,timeout=30,cancellation=None):
        command=[str(prefix/'bin/python3'),'-m',manifest['worker']['module'],*manifest['worker'].get('args',[])]
        process=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,env=child_environment(prefix),cwd=prefix,start_new_session=True,bufsize=0)
        try:
            event=read_handshake(process,timeout=timeout,cancellation=cancellation)
            if not isinstance(event,dict) or event.get('type')!='handshake' or event.get('protocol')!=1 or event.get('runtime_id')!=manifest['id']:
                raise GenerationError('worker_identity_mismatch','The isolated worker identity did not match its runtime.',status=503)
        finally:
            WorkerSupervisor._stop(process);process.stdin.close();process.stdout.close()
    def run(self,runtime_id,payload,context):
        pid=payload['profile']['id'];entry=self.manager.manifests.get(pid)
        if entry is None or entry['manifest']['id']!=runtime_id:raise GenerationError('runtime_identity_mismatch','The selected worker does not match this profile.',status=409)
        manifest=entry['manifest'];installation=self.manager._installation(pid)
        if not installation or not self.manager.ready(pid):raise GenerationError('runtime_not_ready','Repair the selected worker before generation.',status=409)
        return self.execute(Path(installation['runtime_path'])/'python',manifest,payload,context,self.manager.codec_paths)
    @staticmethod
    def execute(prefix,manifest,payload,context,codecs=None):
        from .memory import MemoryGuard
        memory=MemoryGuard()
        parent_read,parent_write=os.pipe()
        lease_fd=getattr(context,'compute_lease_fd',None)
        inherited=(parent_read,) if lease_fd is None else (parent_read,lease_fd)
        command=[str(prefix/'bin/python3'),'-m','nativ_generation.worker_guardian','--parent-fd',str(parent_read),'--module',manifest['worker']['module'],'--',*manifest['worker'].get('args',[])]
        try:process=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,env=child_environment(prefix,codec_paths=codecs),cwd=prefix,start_new_session=True,bufsize=0,pass_fds=inherited)
        except BaseException:os.close(parent_read);os.close(parent_write);raise
        os.close(parent_read)
        selector=selectors.DefaultSelector();selector.register(process.stdout,selectors.EVENT_READ);os.set_blocking(process.stdout.fileno(),False)
        start=time.monotonic();buffer=bytearray();hello=False;result=None;result_at=None;worker_exit=None
        try:
            while True:
                context.check_cancelled();elapsed=time.monotonic()-start
                memory.check()
                if (not hello and elapsed>30) or elapsed>manifest.get('execution_ceiling_seconds',14400) or (result_at and time.monotonic()-result_at>5):raise GenerationError('worker_timeout','The owned worker exceeded its bounded execution time.',status=504)
                # A result is accepted only after its writer and encoder exit.
                if process.poll() is not None and not selector.select(0):break
                for key,_ in selector.select(.05):
                    chunk=os.read(key.fd,65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        if process.poll() is not None:break
                        continue
                    buffer.extend(chunk)
                    if len(buffer)>1024*1024:raise GenerationError('worker_protocol_limit','The worker emitted an oversized event.',status=502)
                    while b'\n' in buffer:
                        raw,_,remainder=buffer.partition(b'\n');buffer=bytearray(remainder)
                        try:event=json.loads(raw)
                        except ValueError:raise GenerationError('worker_protocol_invalid','The worker emitted an invalid protocol event.',status=502) from None
                        kind=event.get('type')
                        if not hello:
                            if kind!='handshake' or event.get('protocol')!=1 or event.get('runtime_id')!=manifest['id']:raise GenerationError('worker_identity_mismatch','The isolated worker identity did not match.',status=502)
                            context.begin_dispatch();hello=True
                            request={'protocol':1,'type':'generate',**payload,'output_dir':str(context.output_dir)}
                            encoded=encode(request).encode()+b'\n'
                            if len(encoded)>128*1024:raise GenerationError('worker_request_limit','The accepted worker request is too large.',status=413)
                            write_all(process.stdin,encoded,cancellation=context.cancellation);process.stdin.close()
                        elif kind in {'stage','progress'}:context.emit(event.get('stage','generating'),event.get('progress'))
                        elif kind=='dispatch':pass # durable intent preceded stdin dispatch
                        elif kind=='result':
                            if result is not None:raise GenerationError('worker_duplicate_result','The worker returned multiple results.',status=502)
                            path=Path(event.get('path',''))
                            if not path.is_absolute() or not path.resolve().is_relative_to(context.output_dir.resolve()):raise GenerationError('invalid_candidate','The worker returned a path outside its attempt.',status=502)
                            result=ProviderResult(path,event.get('effective_parameters',{}),event.get('metadata',{}));result_at=time.monotonic()
                        elif kind=='error':raise GenerationError('worker_failed','The isolated runtime failed. Verify the installed dependencies and pinned checkpoint inventory.',status=502)
                        elif kind=='worker_exit':worker_exit=event.get('code')
                        else:raise GenerationError('worker_protocol_invalid','Unexpected worker event.',status=502)
                limit=2*1024**3 if payload['profile']['modality']=='video' else 1024**3
                if sum(p.stat().st_size for p in context.output_dir.rglob('*') if p.is_file() and not p.is_symlink())>limit+128*1024**2:raise GenerationError('output_too_large','The worker output exceeded the attempt disk limit.',status=502)
                if worker_exit is not None:break
            if worker_exit!=0 or result is None or buffer.strip():raise GenerationError('worker_failed','The worker exited without a complete result.',status=502)
            return result
        finally:
            os.close(parent_write)
            try:process.wait(5)
            except subprocess.TimeoutExpired:WorkerSupervisor._stop(process)
            selector.close()
            if not process.stdin.closed:process.stdin.close()
            process.stdout.close()
