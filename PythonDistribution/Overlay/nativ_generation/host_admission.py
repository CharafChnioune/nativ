"""Actual base-worker lifetimes share generation's cross-process admission.

The host may batch existing inference requests together. A generation/native
Translate lease excludes the whole host group. HTTP disconnect only releases
observation; worker and shielded thread claims persist until actual MLX work ends.
"""
from __future__ import annotations
import asyncio
import contextvars
import functools
import fcntl
import importlib
import json
import os
from pathlib import Path
import threading
from .contracts import GenerationError
from .resources import ComputeAdmission

_request_host=contextvars.ContextVar('nativ_host_admission',default=None)
_original_to_thread=asyncio.to_thread
_MANAGER=None

class HostClaim:
    def __init__(self,owner):self.owner=owner;self.closed=False
    def close(self):
        with self.owner.lock:
            if not self.closed:self.closed=True;self.owner.release()
    def __enter__(self):return self
    def __exit__(self,*args):self.close()

class HostAdmission:
    def __init__(self,admission,*,borrowed_fd=None):
        self.admission=admission;self.borrowed_fd=borrowed_fd;self.lock=threading.RLock();self.active=0;self.lease=None
    def acquire(self):
        with self.lock:
            if self.active==0 and self.borrowed_fd is None:
                self.lease=self.admission.try_acquire('host-inference')
                if self.lease is None:raise GenerationError('compute_busy','Another local generation or Live Translate owns compute. Wait or explicitly stop it.',status=409,retryable=True)
            self.active+=1
        return HostClaim(self)
    def release(self):
        with self.lock:
            self.active-=1
            if self.active==0 and self.lease:self.lease.close();self.lease=None
    def idle(self):
        with self.lock:return self.active==0

async def scoped_to_thread(host,func,*args,**kwargs):
    """Shield executor scheduling, retaining its claim even if the awaiter leaves."""
    claim=host.acquire();context=contextvars.copy_context()
    def run():
        try:return func(*args,**kwargs)
        finally:claim.close()
    try:future=asyncio.get_running_loop().run_in_executor(None,context.run,run)
    except BaseException:claim.close();raise
    try:return await asyncio.shield(future)
    except asyncio.CancelledError:
        def drain(done):
            try:done.exception()
            except BaseException:pass
        future.add_done_callback(drain);raise

class HostAdmissionMiddleware:
    def __init__(self,app,host):self.app=app;self.host=host
    @staticmethod
    def heavy(scope):
        path=scope.get('path','')
        if path.startswith(('/v1/music/','/v1/video/','/images','/v1/images','/routines/','/v1/routines/')) or path=='/v1/generation/prepare-compute':return False
        return scope['type']=='websocket' or (scope['type']=='http' and scope.get('method') in ('POST','PUT','PATCH','DELETE'))
    async def __call__(self,scope,receive,send):
        if scope['type'] not in ('http','websocket') or not self.heavy(scope):return await self.app(scope,receive,send)
        try:claim=self.host.acquire()
        except GenerationError as error:
            if scope['type']=='websocket':return await send({'type':'websocket.close','code':1013,'reason':error.message})
            data=json.dumps({'error':error.public()}).encode()
            await send({'type':'http.response.start','status':409,'headers':[(b'content-type',b'application/json'),(b'retry-after',b'1'),(b'content-length',str(len(data)).encode())]})
            return await send({'type':'http.response.body','body':data})
        token=_request_host.set(self.host)
        try:return await self.app(scope,receive,send)
        finally:_request_host.reset(token);claim.close()

def _synchronize():
    try:
        import mlx.core as mx
        mx.synchronize()
    except ImportError:pass

def _sync_wrapper(original,host):
    @functools.wraps(original)
    def wrapped(*args,**kwargs):
        with host.acquire():
            try:return original(*args,**kwargs)
            finally:_synchronize()
    return wrapped

def unload_idle_host_models():
    """Caller owns the exclusive cross-process lease; never unload live host work."""
    if _MANAGER is None:return
    with _MANAGER.lock:
        if _MANAGER.active:raise GenerationError('compute_busy','Host inference still owns its model; wait for completion.',status=409)
        app=importlib.import_module('mlx_vlm.server.app')
        app.unload_model_sync()
        _synchronize()

def configure_admission(admission):
    if _MANAGER is not None:
        with _MANAGER.lock:
            if _MANAGER.active:raise RuntimeError('Cannot replace admission during active host work')
            _MANAGER.admission=admission

def install(base):
    global _MANAGER
    if _MANAGER is not None:return _MANAGER
    path=Path(os.environ.get('NATIV_COMPUTE_LEASE_PATH','~/Library/Application Support/io.github.charafchnioune.nativ/compute-admission.lock')).expanduser()
    admission=ComputeAdmission(path)
    borrowed=None
    if os.environ.get('NATIV_PRIVATE_TRANSLATION_RUNTIME')=='1' and os.environ.get('NATIV_INHERITED_COMPUTE_FD')=='0':
        # Native Process dup2s its actual lease description to stdin, not a guessed PID/path.
        try:
            actual=os.fstat(0);expected=os.stat(admission.path)
            if (actual.st_dev,actual.st_ino)!=(expected.st_dev,expected.st_ino):raise ValueError()
            # Reassert the inherited open-description lock; an arbitrary stdin
            # file with the same inode cannot bypass an existing exclusive owner.
            fcntl.flock(0,fcntl.LOCK_EX|fcntl.LOCK_NB)
            borrowed=0
        except (OSError,ValueError):raise RuntimeError('Private Translate requires its inherited compute lease') from None
    if str(base.__version__)!='0.7.12':raise RuntimeError('Host compute hooks require qualification for this mlx-vlm version')
    host=HostAdmission(admission,borrowed_fd=borrowed);_MANAGER=host
    base.app.add_middleware(HostAdmissionMiddleware,host=host)
    async def protected_to_thread(func,*args,**kwargs):
        current=_request_host.get()
        if current is None:return await _original_to_thread(func,*args,**kwargs)
        return await scoped_to_thread(current,func,*args,**kwargs)
    asyncio.to_thread=protected_to_thread
    generation=importlib.import_module('mlx_vlm.server.generation')
    cls=generation.ResponseGenerator
    cls._initialize_model=_sync_wrapper(cls._initialize_model,host)
    original_collect=cls._collect_pending_requests
    def collect(self,*args,**kwargs):
        if not kwargs.get('active',False):
            existing=getattr(self,'_nativ_compute_claim',None)
            if existing:_synchronize();existing.close();self._nativ_compute_claim=None
        if kwargs.get('active',False) and getattr(self,'_nativ_compute_claim',None) is None:
            self._nativ_compute_claim=host.acquire()
        pending,stop=original_collect(self,*args,**kwargs)
        if pending and getattr(self,'_nativ_compute_claim',None) is None:
            try:self._nativ_compute_claim=host.acquire()
            except GenerationError as error:
                for request in pending:
                    request.rqueue.put(error);request.rqueue.put(None)
                return [],stop
        return pending,stop
    cls._collect_pending_requests=collect
    original_schedule=cls._schedule_continuations
    def schedule(self,*args,**kwargs):
        suspended=args[1] if len(args)>1 else kwargs.get('suspended',{})
        if not suspended:return original_schedule(self,*args,**kwargs)
        try:claim=host.acquire()
        except GenerationError:return None  # paused internal continuations wait behind exclusive work
        try:
            result=original_schedule(self,*args,**kwargs)
            groups=args[0] if args else kwargs.get('groups',{})
            if any(active for _,active in groups.values()) and getattr(self,'_nativ_compute_claim',None) is None:
                self._nativ_compute_claim=host.acquire()
            return result
        finally:claim.close()
    cls._schedule_continuations=schedule
    original_run=cls._run
    def run(self):
        try:return original_run(self)
        finally:
            claim=getattr(self,'_nativ_compute_claim',None)
            if claim:_synchronize();claim.close();self._nativ_compute_claim=None
    cls._run=run
    for module_name,names in [('audio',('_run_tts_request','_run_stt_request')),('audio_realtime',('run_request',)),('audio_speakers',('run_request',)),('audio_diarized',('run_request',))]:
        module=importlib.import_module('mlx_vlm.server.'+module_name)
        for name in names:
            if not hasattr(module,name):raise RuntimeError('Pinned host inference contract changed: '+module_name+'.'+name)
            setattr(module,name,_sync_wrapper(getattr(module,name),host))
    meshes=importlib.import_module('mlx_vlm.server.meshes')
    mesh_class=getattr(meshes,'MeshJobManager',None) or getattr(meshes,'MeshJobStore',None)
    if mesh_class is None:
        mesh_class=next((value for value in vars(meshes).values() if isinstance(value,type) and hasattr(value,'submit') and hasattr(value,'_run') and hasattr(value,'retrieve')),None)
    if mesh_class is None:raise RuntimeError('Pinned mesh worker contract changed')
    mesh_class._run=_sync_wrapper(mesh_class._run,host)
    app=importlib.import_module('mlx_vlm.server.app')
    original_cached=app.get_cached_model
    app.get_cached_model=_sync_wrapper(original_cached,host)
    base.get_cached_model=app.get_cached_model
    from fastapi import Request,HTTPException
    globals()['Request']=Request
    @base.app.post('/v1/generation/prepare-compute',include_in_schema=False)
    async def prepare_compute(request:Request):
        require=getattr(base,'_require_management_api_key',None)
        if require is None:raise HTTPException(503,'Compute preparation authentication is unavailable')
        require(request)
        try:
            binding=json.loads(admission.path.read_text())
            if binding.get('owner')!='native-translation' or binding.get('nonce')!=request.headers.get('x-nativ-compute-lease'):raise ValueError()
            check=admission.try_acquire('compute-proof-check')
            if check is not None:check.close();raise ValueError()
        except (OSError,ValueError):raise HTTPException(409,'Acquire the native compute lease before preparing idle models') from None
        images=None
        try:
            images=importlib.import_module('nativ_image_execution')
            if images.has_active_work():raise HTTPException(409,'Image inference is still active')
        except ImportError:pass
        await _original_to_thread(unload_idle_host_models)
        try:
            if images is not None:await _original_to_thread(images.unload_idle_images)
        except ImportError:pass
        return {'status':'idle_models_released'}
    return host
