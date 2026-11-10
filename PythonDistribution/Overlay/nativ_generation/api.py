"""Authenticated generation control and media delivery on Nativ's existing app."""
from __future__ import annotations
import asyncio
from contextlib import asynccontextmanager
import hmac
import json
import os
from pathlib import Path
import re
from .contracts import GenerationError
from .service import public_job,public_asset

MODALITIES={'music','video'}
JSON_LIMIT=128*1024
UPLOAD_LIMIT=25*1024*1024+64*1024

class GenerationBoundary:
    def __init__(self,app,api_key=None,origins=None):
        self.app=app;self.api_key=api_key
        self.origins=origins if origins is not None else [x.strip() for x in os.environ.get('NATIV_GENERATION_ALLOWED_ORIGINS','').split(',') if x.strip()]
    async def __call__(self,scope,receive,send):
        path=scope.get('path','')
        if scope['type']!='http' or not any(path.startswith('/v1/'+m+'/') for m in MODALITIES):return await self.app(scope,receive,send)
        from starlette.responses import JSONResponse
        headers={k.lower():v for k,v in scope['headers']};key=self.api_key if self.api_key is not None else os.environ.get('MLX_VLM_SERVER_API_KEY','')
        async def reject(code,message,status):
            await JSONResponse({'error':GenerationError(code,message).public()},status_code=status)(scope,receive,send)
        origin=headers.get(b'origin',b'').decode('latin1')
        if origin and origin not in self.origins:return await reject('origin_not_allowed','This browser origin is not allowed by the generation server.',403)
        if scope['method']=='OPTIONS' and origin:
            from starlette.responses import Response
            return await Response(status_code=204,headers={'Access-Control-Allow-Origin':origin,'Access-Control-Allow-Methods':'GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS','Access-Control-Allow-Headers':'Authorization, Content-Type, Idempotency-Key, X-Nativ-Store-ID, Last-Event-ID','Vary':'Origin'})(scope,receive,send)
        if not key:return await reject('authentication_required','Configure the Nativ server API key to enable generation APIs.',503)
        if not hmac.compare_digest(headers.get(b'authorization',b''),('Bearer '+key).encode()):return await reject('unauthorized','A valid bearer credential is required.',401)
        limit=UPLOAD_LIMIT if path=='/v1/video/inputs' and scope['method']=='POST' else JSON_LIMIT
        try:length=int(headers.get(b'content-length',b'0'))
        except ValueError:return await reject('invalid_content_length','Invalid content length.',400)
        if length<0 or length>limit:return await reject('request_too_large','The request exceeds this route’s byte limit.',413)
        received=0
        async def bounded_receive():
            nonlocal received
            message=await receive()
            if message['type']=='http.request':
                received+=len(message.get('body',b''))
                if received>limit:raise GenerationError('request_too_large','The request exceeds this route’s byte limit.',status=413)
            return message
        async def cors_send(message):
            if message['type']=='http.response.start' and origin:
                message['headers']=[(k,v) for k,v in message['headers'] if not k.lower().startswith(b'access-control-')]+[(b'access-control-allow-origin',origin.encode()),(b'vary',b'Origin')]
            await send(message)
        await self.app(scope,bounded_receive,cors_send)

async def body(request):
    data=await request.body()
    if not data:return {}
    try:
        value=json.loads(data,parse_constant=lambda _:(_ for _ in ()).throw(ValueError()))
        if not isinstance(value,dict):raise ValueError()
    except (ValueError,UnicodeError):raise GenerationError('invalid_json','Supply a JSON object with finite values.') from None
    return value

def install_routes(app,service_getter,*,api_key=None,origins=None):
    from fastapi import APIRouter,Request
    from fastapi.responses import JSONResponse,FileResponse,StreamingResponse
    # Request must be visible to postponed-annotation resolution in FastAPI.
    globals()['Request']=Request
    existing={route.path for route in app.routes if hasattr(route,'path')}
    if any(p.startswith(('/v1/music/','/v1/video/')) for p in existing):raise RuntimeError('Generation namespace already registered; resolve the upstream API collision before packaging.')
    app.add_middleware(GenerationBoundary,api_key=api_key,origins=origins)
    @app.exception_handler(GenerationError)
    async def generation_error(request,error):return JSONResponse({'error':error.public()},status_code=error.status)
    def service(request,mutation=False):
        s=service_getter()
        if s is None:raise GenerationError('server_starting','The generation library is starting.',retryable=True,status=503)
        if mutation:
            expected=request.headers.get('x-nativ-store-id')
            if not expected:raise GenerationError('store_precondition_required','Read info and supply X-Nativ-Store-ID before mutating this library.',field='X-Nativ-Store-ID',status=428)
            if expected!=s.repo.store_id:raise GenerationError('store_mismatch','The media library changed. Reconnect and review your pending intent.',field='X-Nativ-Store-ID',status=409)
        return s
    def modal_asset(s,modality,aid):
        value=s.repo.asset(aid)
        if value['modality']!=modality:raise GenerationError('asset_not_found','The asset was not found in this workspace.',status=404)
        return value
    def register(modality):
        router=APIRouter(prefix='/v1/'+modality,tags=['Nativ '+modality.title()])
        @router.get('/info')
        async def info(request:Request):
            s=service(request)
            return {'store_id':s.repo.store_id,'contract_version':1,'modality':modality,'limits':{'request_bytes':JSON_LIMIT,'output_bytes':1024**3 if modality=='music' else 2*1024**3,'input_bytes':25*1024**2,'input_pixels':40_000_000,'events_per_job':1000,'waiting_jobs':8,'waiting_video_jobs':4,'local_workers':1,'remote_reservations_per_modality':1}}
        @router.get('/models')
        async def models(request:Request):return service(request).models(modality)
        @router.get('/server-state')
        async def server_state(request:Request):return service(request).server_state()
        @router.post('/prepare-stop',status_code=202)
        async def prepare_stop(request:Request):return await asyncio.to_thread(service(request,True).prepare_stop)
        @router.get('/configuration')
        async def configuration(request:Request):return service(request).configuration(modality)
        @router.put('/configuration/{profile_id}')
        async def configure(profile_id:str,request:Request):
            s=service(request,True);s.profile(profile_id,modality);return s.configure(profile_id,await body(request))
        @router.get('/runtimes')
        async def runtimes(request:Request):
            s=service(request);return {'items':s.runtimes.status(modality) if s.runtimes else []}
        @router.post('/runtimes/{runtime_id}/{action}')
        async def runtime_action(runtime_id:str,action:str,request:Request):
            s=service(request,True)
            if s.runtimes is None:raise GenerationError('runtime_manager_unavailable','Repair the packaged runtime resources.',status=503)
            if action not in {'install','repair','remove','cancel-install'}:raise GenerationError('invalid_action','Unknown runtime action.',status=404)
            if not any(p['modality']==modality and p.get('runtime')==runtime_id for p in s.profiles.values()):raise GenerationError('runtime_not_found','The runtime does not belong to this workspace.',status=404)
            data=await body(request)
            return s.runtimes.action(runtime_id,action,data.get('profile_id'))
        @router.get('/sessions')
        async def sessions(request:Request,cursor:str|None=None,limit:int=50,include_hidden:bool=False):return service(request).repo.list_sessions(modality,cursor,limit,include_hidden)
        @router.post('/sessions',status_code=201)
        async def create_session(request:Request):
            s=service(request,True);data=await body(request)
            if set(data)-{'title'} or not isinstance(data.get('title','Untitled'),str) or len(data.get('title',''))>200:raise GenerationError('invalid_title','Use a title of at most 200 characters.',field='title')
            return s.repo.create_session(modality,data.get('title','Untitled'))
        @router.patch('/sessions/{session_id}')
        async def patch_session(session_id:str,request:Request):return service(request,True).repo.patch_session(modality,session_id,await body(request))
        @router.post('/generations',status_code=202)
        async def submit(request:Request):return public_job(service(request,True).submit(modality,await body(request),request.headers.get('idempotency-key')))
        @router.get('/generations')
        async def jobs(request:Request,cursor:str|None=None,limit:int=50,session_id:str|None=None):
            page=service(request).repo.list_jobs(modality,cursor,limit,session_id);page['items']=[public_job(j) for j in page['items']];return page
        @router.get('/generations/{job_id}')
        async def job(job_id:str,request:Request):return public_job(service(request).repo.get_job(job_id,modality))
        @router.get('/generations/{job_id}/events')
        async def events(job_id:str,request:Request):
            s=service(request);s.repo.get_job(job_id,modality)
            try:after=int(request.headers.get('last-event-id','0'));assert after>=0
            except (ValueError,AssertionError):raise GenerationError('invalid_event_cursor','Last-Event-ID must be a nonnegative event ID.') from None
            async def stream():
                nonlocal after
                idle=0
                while not await request.is_disconnected():
                    entries=s.repo.events(job_id,after)
                    for item in entries:
                        item['job']=public_job(item['job']);after=item['id']
                        yield ('id: '+str(after)+'\nevent: '+item['type']+'\ndata: '+json.dumps(item,separators=(',',':'),allow_nan=False)+'\n\n').encode()
                    if s.repo.get_job(job_id)['state'] in {'succeeded','cancelled','interrupted','failed'}:return
                    idle+=1
                    if idle%40==0:yield b': keepalive\n\n'
                    await asyncio.sleep(.25)
            return StreamingResponse(stream(),media_type='text/event-stream',headers={'Cache-Control':'no-store','X-Accel-Buffering':'no'})
        @router.post('/generations/{job_id}/cancel')
        async def cancel(job_id:str,request:Request):
            s=service(request,True);s.repo.get_job(job_id,modality);return public_job(s.cancel(job_id))
        @router.post('/generations/{job_id}/resume')
        async def resume(job_id:str,request:Request):
            s=service(request,True);s.repo.get_job(job_id,modality);return public_job(s.resume(job_id))
        @router.post('/generations/{job_id}/retry-download')
        async def retry_download(job_id:str,request:Request):
            s=service(request,True);s.repo.get_job(job_id,modality);return public_job(s.retry_download(job_id))
        @router.post('/generations/{job_id}/release-remote-reservation')
        async def release(job_id:str,request:Request):
            s=service(request,True);s.repo.get_job(job_id,modality);data=await body(request)
            return public_job(s.repo.release_reservation(job_id,data.get('acknowledge_possible_execution_and_charges')))
        @router.get('/assets/{asset_id}')
        async def asset(asset_id:str,request:Request):return public_asset(modal_asset(service(request),modality,asset_id))
        @router.get('/assets/{asset_id}/content')
        @router.head('/assets/{asset_id}/content',include_in_schema=False)
        async def content(asset_id:str,request:Request):
            s=service(request);modal_asset(s,modality,asset_id);path,value=s.assets.content(asset_id)
            return FileResponse(path,media_type=value['mime_type'],filename=value['filename'],content_disposition_type='inline',headers={'Cache-Control':'private, no-store','X-Content-Type-Options':'nosniff','X-Nativ-Store-ID':s.repo.store_id,'X-Content-SHA256':value['sha256']})
        @router.get('/assets/{asset_id}/usages')
        async def usages(asset_id:str,request:Request):
            s=service(request);modal_asset(s,modality,asset_id);return s.repo.usages(asset_id)
        @router.put('/assets/{asset_id}/references/{reference_id}')
        async def put_reference(asset_id:str,reference_id:str,request:Request):
            s=service(request,True);modal_asset(s,modality,asset_id);data=await body(request)
            if len(reference_id)>200 or not isinstance(data.get('owner'),dict) or len(json.dumps(data['owner']))>4096 or type(data.get('expected_revision')) is not int:raise GenerationError('invalid_reference','Provide a bounded owner record and integer expected_revision.')
            return s.repo.put_reference(asset_id,reference_id,data.get('phase'),data['expected_revision'],data['owner'])
        @router.delete('/assets/{asset_id}/references/{reference_id}')
        async def delete_reference(asset_id:str,reference_id:str,request:Request):
            s=service(request,True);modal_asset(s,modality,asset_id);data=await body(request)
            if type(data.get('expected_revision')) is not int:raise GenerationError('invalid_revision','Supply an integer expected_revision.')
            return s.repo.delete_reference(asset_id,reference_id,data['expected_revision'])
        @router.delete('/assets/{asset_id}')
        async def trash(asset_id:str,request:Request):
            s=service(request,True);modal_asset(s,modality,asset_id);return public_asset(s.assets.trash(asset_id))
        @router.post('/assets/{asset_id}/restore')
        async def restore(asset_id:str,request:Request):
            s=service(request,True);modal_asset(s,modality,asset_id);return public_asset(s.assets.restore(asset_id))
        if modality=='video':
            @router.post('/inputs',status_code=201)
            async def upload_input(request:Request):
                s=service(request,True)
                async with request.form(max_files=1,max_fields=0,max_part_size=25*1024**2) as form:
                    file=form.get('file')
                    if file is None or not hasattr(file,'file'):raise GenerationError('input_required','Upload one file field with a still reference image.')
                    return await asyncio.to_thread(s.assets.import_input,file.file,file.content_type)
            @router.get('/inputs/{input_id}')
            async def input_info(input_id:str,request:Request):return service(request).assets.input(input_id)
            @router.get('/inputs/{input_id}/content')
            @router.head('/inputs/{input_id}/content',include_in_schema=False)
            async def input_content(input_id:str,request:Request):
                path,metadata=service(request).assets.input_content(input_id)
                return FileResponse(path,media_type=metadata['mime'],headers={'Cache-Control':'private, no-store','X-Content-Type-Options':'nosniff'})
            @router.delete('/inputs/{input_id}')
            async def delete_input(input_id:str,request:Request):return service(request,True).assets.delete_input(input_id)
            @router.post('/inputs/{input_id}/transform')
            async def transform_input(input_id:str,request:Request):
                s=service(request,True);data=await body(request)
                if set(data)-{'width','height','transform'}:raise GenerationError('unsupported_parameter','Only width, height and transform are accepted.')
                return await asyncio.to_thread(s.assets.transform_input,input_id,data.get('width'),data.get('height'),data.get('transform'))
            @router.get('/inputs/{input_id}/derivatives/{derivative_id}/content')
            async def derivative_content(input_id:str,derivative_id:str,request:Request):
                s=service(request);path=s.assets.derivative_content(input_id,derivative_id)
                return FileResponse(path,media_type='image/png',headers={'Cache-Control':'private, no-store','X-Nativ-Store-ID':s.repo.store_id})
            @router.get('/assets/{asset_id}/poster')
            async def poster(asset_id:str,request:Request):
                s=service(request);modal_asset(s,modality,asset_id)
                path=await asyncio.to_thread(s.assets.poster,asset_id)
                return FileResponse(path,media_type='image/jpeg',headers={'Cache-Control':'private, no-store','X-Nativ-Store-ID':s.repo.store_id})
        app.include_router(router)
    for modality in sorted(MODALITIES):register(modality)
    from .openapi import install_openapi
    install_openapi(app)


def install(app):
    """Retain the existing server lifespan and bind one app-wide canonical store."""
    if os.environ.get('NATIV_PRIVATE_TRANSLATION_RUNTIME')=='1':return
    from .service import GenerationService
    from .runtimes import RuntimeManager,WorkerSupervisor
    from .resources import ComputeAdmission
    original=app.router.lifespan_context
    @asynccontextmanager
    async def lifespan(application):
        async with original(application):
            root=Path(os.environ.get('NATIV_GENERATION_ROOT','~/Library/Application Support/io.github.charafchnioune.nativ/Generations')).expanduser()
            lease_path=Path(os.environ.get('NATIV_COMPUTE_LEASE_PATH','~/Library/Application Support/io.github.charafchnioune.nativ/compute-admission.lock')).expanduser()
            admission=ComputeAdmission(lease_path)
            try:import nativ_image_execution
            except ImportError:nativ_image_execution=None
            if nativ_image_execution:nativ_image_execution.configure_admission(admission)
            from .host_admission import configure_admission
            configure_admission(admission)
            service=None;manager=None
            application.state.nativ_generation_error=None
            try:
                manager=RuntimeManager(root/'runtimes')
                service=GenerationService(root,runtimes=manager,worker=WorkerSupervisor(manager),admission=admission,autostart=False)
                manager.bind(service);service.start()
            except Exception as error:
                # A locked, newer or damaged generation store must not take down
                # the pre-existing Chat, Images, speech or health routes.
                if service:await asyncio.to_thread(service.close)
                elif manager:await asyncio.to_thread(manager.close)
                service=None
                application.state.nativ_generation_error=error if isinstance(error,GenerationError) else GenerationError('generation_storage_unavailable','The generation library could not be opened. Check its storage and repair the app; existing data has been preserved.',status=503)
            application.state.nativ_generations=service
            try:yield
            finally:
                if service:await asyncio.to_thread(service.close)
                application.state.nativ_generations=None
                if nativ_image_execution:await nativ_image_execution.shutdown()
    app.router.lifespan_context=lifespan
    def current_service():
        error=getattr(app.state,'nativ_generation_error',None)
        if error:raise error
        return getattr(app.state,'nativ_generations',None)
    install_routes(app,current_service)
