"""Typed documentation for the raw-Request generation API, preserving base OpenAPI.

This module declares the implemented wire contract. Catalogue imports are light;
OpenAPI generation never installs a runtime or creates a provider operation.
"""
from __future__ import annotations
from copy import deepcopy
import re

PREFIX='#/components/schemas/'
STATES=['queued','recovery_hold','preparing','running','finalizing','retrieval_pending','succeeded','cancel_requested','cancelled','interrupted','failed','submission_unknown']
MUTATIONS={'post','put','patch','delete'}


def ref(name):return {'$ref':PREFIX+name}
def obj(properties=None,required=(),*,closed=False,**extras):
    result={'type':'object','properties':properties or {},'additionalProperties':not closed,**extras}
    if required:result['required']=list(required)
    return result
def text(**extras):return {'type':'string',**extras}
def integer(**extras):return {'type':'integer',**extras}
def boolean(**extras):return {'type':'boolean',**extras}
def nullable(schema):return {'anyOf':[schema,{'type':'null'}]}
def array(schema,**extras):return {'type':'array','items':schema,**extras}
def number(**extras):return {'type':'number',**extras}
def page(item):return obj({'items':array(ref(item)),'next_cursor':nullable(text())},('items','next_cursor'))


def _profile_requests(schemas):
    from nativ_music.catalog import profiles as music_profiles
    from nativ_video.catalog import profiles as video_profiles
    for modality,profiles in (('music',music_profiles()),('video',video_profiles())):
        mapping={}
        for profile in profiles:
            cap=profile['capabilities'];defaults=profile['defaults'];local=profile['deployment']=='local'
            name='Nativ'+modality.title()+'Request_'+re.sub('[^A-Za-z0-9_]','_',profile['id'])
            properties={'model':text(const=profile['id']),'prompt':text(minLength=1,pattern=r'\S'),
                        'session_id':nullable(text(maxLength=128)),
                        'allow_remote':boolean(default=False) if local else boolean(const=True)}
            required=['model','prompt']+([] if local else ['allow_remote'])
            if modality=='music':
                provider=profile['provider']
                properties.update(prompt=text(minLength=1,pattern=r'\S',maxLength=512 if provider=='acestep' else 2000 if provider=='minimax_cloud' else 10000),
                    instrumental=boolean(default=defaults['instrumental']),
                    lyrics=text(maxLength=3500 if provider=='minimax_cloud' else 4096) if cap['lyrics'] else text(const=''),
                    title=text(description='Optional title hint; session titles use the sessions API.'),
                    output_format=text(enum=cap['output_formats'],default=defaults['output_format']))
                if not cap['vocals']:properties['instrumental']={'type':'boolean','const':True}
                if cap['duration']['semantics']!='prompt_only':
                    bounds=cap['duration'];properties['duration_seconds']=number(minimum=bounds['minimum'],maximum=bounds['maximum'],description='Duration semantics: '+bounds['semantics'])
                    if 'duration_seconds' in defaults:properties['duration_seconds']['default']=defaults['duration_seconds']
                if cap['seed']:properties['seed']=integer(minimum=0,maximum=4294967294 if provider=='stable_audio_cloud' else 2**63-1)
                for field in ('steps','shift'):
                    if field in defaults:properties[field]={'const':defaults[field]}
                if 'bpm' in cap['options']:properties['bpm']=integer(minimum=30,maximum=300)
                if 'key' in cap['options']:properties['key']=text(maxLength=32)
                if 'time_signature' in cap['options']:properties['time_signature']={'enum':[2,3,4,6,'2','3','4','6']}
                schema=obj(properties,required,closed=True)
                if cap.get('lyrics_required_for_vocals'):
                    schema['allOf']=[{'if':{'properties':{'instrumental':{'const':False}},'required':['instrumental']},'then':{'required':['lyrics'],'properties':{'lyrics':{'minLength':1,'pattern':r'\S'}}}}]
            else:
                properties.update(prompt=text(minLength=1,pattern=r'\S',maxLength=5000),operation=text(enum=cap['operations'],default='text_to_video'),
                    output_preset=text(enum=list(cap['presets']),default=defaults['output_preset']),
                    output_format=text(const='mp4',default='mp4'),audio_mode=text(enum=cap['audio_modes'],default=defaults['audio_mode']),
                    contract_version=integer(const=1,default=1),modality=text(const='video'),
                    audio_sample_rate={'const':cap.get('audio_sample_rate')},
                    inputs=array(obj({'input_id':text(minLength=1,maxLength=128,pattern=r'^[^/\\:]+$'),
                                      'role':text(enum=cap['input_roles']),'transform':nullable(ref('NativVideoInputTransform'))},('input_id','role'),closed=True),maxItems=len(cap['input_roles'])))
                properties['inputs']['allOf']=[{'contains':{'properties':{'role':{'const':role}},'required':['role']},'minContains':0,'maxContains':1} for role in cap['input_roles']]
                if cap.get('seed'):properties['seed']=nullable(integer(minimum=0,maximum=4294967295))
                preset_cases=[]
                for pid,preset in cap['presets'].items():
                    controls={field:{'const':value} for field,value in preset.items() if field in ('width','height','fps','frame_count','steps','flow_shift')}
                    if 'duration_options' in preset:controls['duration']={'type':'integer','enum':preset['duration_options']}
                    controls['output_preset']={'const':pid}
                    branch_required=[] if pid==defaults['output_preset'] else ['output_preset']
                    if 'operation' in preset:controls['operation']={'const':preset['operation']};branch_required.append('operation')
                    preset_cases.append(obj(controls,branch_required))
                    for field,value in preset.items():
                        if field in ('width','height','fps','frame_count','steps','flow_shift'):properties[field]={'type':'null'} if value is None else integer() if type(value) is int else number()
                properties.setdefault('frame_count',{'const':None})
                if local:properties['approximate_duration']=number(description='Derived frame_count/FPS; never an independent control.')
                else:
                    if profile['provider']=='runway':properties['duration']=integer(minimum=2,maximum=10,default=defaults['duration'])
                    else:properties['duration']=integer(enum=[6,8,10,12,14,16,18,20] if profile['model'].endswith('-fast') else [6,8,10],default=defaults['duration'])
                if profile['provider']=='runway':
                    properties['prompt']['maxLength']=1000
                    properties['prompt']['description']='At most 1,000 UTF-16 code units (a non-BMP character counts as two).'
                    properties['prompt']['x-max-utf16-code-units']=1000
                    properties['fps']={'const':None}
                schema=obj(properties,required,closed=True,allOf=[{'oneOf':preset_cases},{
                    'if':{'properties':{'operation':{'const':'image_to_video'}},'required':['operation']},
                    'then':{'required':['inputs'],'properties':{'inputs':{'minItems':1,'contains':{'properties':{'role':{'const':'first_frame'}},'required':['role']},'minContains':1,'maxContains':1}}},
                    'else':{'properties':{'inputs':{'maxItems':0}}}}])
            schema['description']='Validated against the immutable selected profile; readiness, license and explicit remote consent are additionally enforced at runtime.'
            schemas[name]=schema;mapping[profile['id']]=PREFIX+name
        schemas['Nativ'+modality.title()+'GenerationRequest']={'oneOf':[{'$ref':value} for value in mapping.values()],
            'discriminator':{'propertyName':'model','mapping':mapping}}


def components():
    ident=text(minLength=1,maxLength=200);epoch=number(description='Unix epoch seconds.')
    error=obj({'code':text(),'message':text(),'field':nullable(text()),'retryable':boolean(),'job_id':nullable(text())},('code','message','field','retryable','job_id'))
    schemas={'NativGenerationError':error,'NativGenerationErrorEnvelope':obj({'error':ref('NativGenerationError')},('error',)),
      'NativGenerationInfo':obj({'store_id':ident,'contract_version':integer(const=1),'modality':text(enum=['music','video']),
          'limits':obj({field:integer(minimum=0) for field in ('request_bytes','output_bytes','input_bytes','input_pixels','events_per_job','waiting_jobs','waiting_video_jobs','local_workers','remote_reservations_per_modality')})},('store_id','contract_version','modality','limits')),
      'NativGenerationProfile':obj({'id':ident,'modality':text(enum=['music','video']),'provider':text(),'deployment':text(enum=['local','remote_gpu','hosted']),
          'profile_revision':text(),'display_name':text(),'model':text(),'model_revision':nullable(text()),'runtime':nullable(text()),
          'qualification':text(enum=['unqualified','experimental','qualified']),'capabilities':obj(),'defaults':obj(),
          'readiness':text(enum=['ready','unavailable']),'unavailable_reason':nullable(text())},('id','modality','provider','deployment','profile_revision','display_name','model','runtime','qualification','capabilities','defaults','readiness','unavailable_reason')),
      'NativGenerationSession':obj({'id':ident,'store_id':ident,'modality':text(enum=['music','video']),'title':text(maxLength=200),'hidden':boolean(),'created_at':epoch,'updated_at':epoch},('id','store_id','modality','title','hidden','created_at','updated_at')),
      'NativGenerationJob':obj({'job_id':ident,'store_id':ident,'session_id':ident,'attempt_id':nullable(ident),'modality':text(enum=['music','video']),
          'state':text(enum=STATES),'stage':text(),'progress':nullable(number(minimum=0,maximum=1)),
          'created_at':epoch,'updated_at':epoch,'request':ref('NativGenerationAcceptedRequest'),
          'submitted_request':obj(),'profile':ref('NativGenerationProfileSnapshot'),'effective_parameters':nullable(obj()),'asset_id':nullable(ident),
          'error':nullable(ref('NativGenerationError')),'provider_outcome':text(),'provider_operation_known':boolean(),
          'dispatch_intent':boolean(),'remote_reservation':text(),'cancel_requested':boolean(),'local_observation':text(),'revision':integer(minimum=1),
          'input_derivatives':array(obj())},('job_id','store_id','session_id','attempt_id','modality','state','stage','progress','request','profile','created_at','updated_at')),
      'NativGenerationAsset':obj({'asset_id':ident,'store_id':ident,'job_id':ident,'modality':text(enum=['music','video']),
          'filename':text(),'mime_type':text(),'byte_size':integer(minimum=1),'sha256':text(pattern='^[0-9a-f]{64}$'),
          'created_at':epoch,'trashed':boolean(),'revision':integer(minimum=1),'metadata':obj(description='Independently measured media and safe provenance, distinct from provider-reported values.')},('asset_id','store_id','job_id','modality','filename','mime_type','byte_size','sha256','created_at','trashed','revision','metadata')),
      'NativGenerationReference':obj({'asset_id':ident,'id':ident,'state':text(enum=['reserved','live','released']),'revision':integer(minimum=1),'owner':obj(),'updated_at':epoch},('asset_id','id','state','revision','owner')),
      'NativGenerationReferencePut':obj({'phase':text(enum=['reserve','finalize']),'expected_revision':integer(minimum=0),'owner':obj(**{'x-max-json-bytes':4096})},('phase','expected_revision','owner')),
      'NativGenerationReferenceDelete':obj({'expected_revision':integer(minimum=0)},('expected_revision',)),
      'NativGenerationSessionCreate':obj({'title':text(maxLength=200,default='Untitled')},closed=True),
      'NativGenerationSessionPatch':obj({'title':text(maxLength=200),'hidden':boolean()},closed=True),
      'NativGenerationReservationRelease':obj({'acknowledge_possible_execution_and_charges':boolean(const=True)},('acknowledge_possible_execution_and_charges',)),
      'NativGenerationConfigurationPatch':obj({**{name:boolean() for name in ('enabled','experimental_enabled','license_accepted','allow_local_http','account_eligible','separate_license_approved')},**{name:text(maxLength=2000) for name in ('endpoint','account_id')},'region':text(enum=['global','china'])},closed=True),
      'NativGenerationConfigurationProfile':obj({'enabled':boolean(),'experimental_enabled':boolean(),'license_accepted':boolean(),'endpoint':text(),'account_id':text(),'runtime':nullable(text()),'readiness':text(),'unavailable_reason':nullable(text())}),
      'NativGenerationConfiguration':obj({'profiles':{'type':'object','additionalProperties':ref('NativGenerationConfigurationProfile')}},('profiles',)),
      'NativGenerationRuntime':obj({'id':ident,'profile_id':ident,'status':text(),'stage':nullable(text()),'progress':nullable(number()),'error':nullable(obj()),'qualification':text(),'required_model_bytes':integer(minimum=0),'licenses':array(obj()),'codec_ready':boolean()},('id','profile_id','status','qualification','required_model_bytes','licenses','codec_ready')),
      'NativGenerationRuntimeList':obj({'items':array(ref('NativGenerationRuntime'))},('items',)),
      'NativGenerationRuntimeAction':obj({'profile_id':text(maxLength=200)}),
      'NativGenerationRuntimeActionResult':obj({'profile_id':ident,'status':text(),'models_preserved':boolean()},('profile_id','status')),
      'NativGenerationServerState':obj({**{name:integer(minimum=0) for name in ('pending_count','active_count','queued_count','remote_reserved_count','setup_count')},'stopping':boolean(),'ready_to_stop':boolean()},('pending_count','active_count','queued_count','remote_reserved_count','setup_count','stopping','ready_to_stop')),
      'NativGenerationEvent':obj({'id':integer(minimum=1),'type':text(),'job':ref('NativGenerationJob')},('id','type','job')),
      'NativVideoCrop':obj({name:number(**({'minimum':0} if name in ('x','y') else {'exclusiveMinimum':0}),maximum=1) for name in ('x','y','width','height')},('x','y','width','height'),closed=True,description='Orientation-corrected normalized top-left coordinates. width/height must be positive; x+width and y+height must be <=1.'),
      'NativVideoInputTransform':obj({'version':integer(const=1,default=1),'fit_policy':text(enum=['crop','contain'],default='contain'),
          'crop':nullable(ref('NativVideoCrop')),'background':text(pattern='^#[0-9a-fA-F]{6}$',default='#000000')},closed=True,
          description='EXIF orientation, sRGB, explicit crop, aspect fit, alpha/background flattening; crop is legal only with fit_policy=crop.'),
      'NativVideoInput':obj({'input_id':ident,'store_id':ident,'revision':integer(minimum=1),'created_at':epoch,'mime':text(enum=['image/png','image/jpeg','image/webp']),
          'sha256':text(pattern='^[0-9a-f]{64}$'),'byte_size':integer(minimum=1,maximum=25*1024**2),'width':integer(minimum=1),'height':integer(minimum=1),'orientation':integer(),'oriented_width':integer(),'oriented_height':integer(),'transform_version':integer(const=1)},('input_id','store_id','revision','created_at','mime','sha256','byte_size','width','height')),
      'NativVideoInputDeleted':obj({'input_id':ident,'deleted':boolean(const=True)},('input_id','deleted')),
      'NativVideoTransformRequest':obj({'width':integer(minimum=1,maximum=4096),'height':integer(minimum=1,maximum=4096),'transform':nullable(ref('NativVideoInputTransform'))},('width','height'),closed=True,description='width*height <=8,294,400; at most 32 prepared previews per input.'),
      'NativVideoDerivative':obj({'input_id':ident,'store_id':ident,'derivative_id':text(pattern='^[0-9a-f]{64}$'),'original_sha256':text(),'sha256':text(),'byte_size':integer(minimum=1),'mime':text(const='image/png'),'width':integer(),'height':integer(),'transform':ref('NativVideoInputTransform'),'color_space':text(),'metadata_stripped':boolean()},('input_id','store_id','derivative_id','original_sha256','sha256','byte_size','mime','width','height','transform'))}
    snapshot=deepcopy(schemas['NativGenerationProfile'])
    snapshot['required']=[key for key in snapshot['required'] if key not in ('readiness','unavailable_reason')]
    schemas['NativGenerationProfileSnapshot']=snapshot
    schemas['NativGenerationProfilePage']=page('NativGenerationProfile')
    schemas['NativGenerationSessionPage']=page('NativGenerationSession')
    schemas['NativGenerationJobPage']=page('NativGenerationJob')
    schemas['NativGenerationAcceptedRequest']=obj({'model':text(),'prompt':text(),'session_id':nullable(text()),'operation':text(),'instrumental':boolean(),'lyrics':text(),'output_format':text(),'allow_remote':boolean(),'seed':integer(minimum=0),'duration_seconds':number(),'duration':integer(),'output_preset':text(),'width':integer(minimum=1),'height':integer(minimum=1),'frame_count':nullable(integer(minimum=1)),'fps':nullable(number(exclusiveMinimum=0)),'audio_mode':text(enum=['silent','native_generated']),'audio_sample_rate':nullable(integer(minimum=1)),'inputs':array(obj())},('model','prompt'),description='Frozen accepted fields; unknown provider-determined fields remain null. Effective and measured output are recorded separately.')
    schemas['NativGenerationUsages']=obj({'items':array(ref('NativGenerationReference'))},('items',))
    schemas['NativVideoInputTransform']['allOf']=[{'if':{'properties':{'fit_policy':{'const':'crop'}},'required':['fit_policy']},'else':{'properties':{'crop':{'type':'null'}}}}]
    _profile_requests(schemas)
    return schemas


def _json_response(name,description='Successful response.'):
    return {'description':description,'content':{'application/json':{'schema':ref(name)}}}

def _header(name,*,required=False,description='',schema=None):
    return {'name':name,'in':'header','required':required,'description':description,'schema':schema or text()}

def _binary(operation,modality,*,mime=None,head=False):
    mimes=([mime] if isinstance(mime,str) else mime) if mime else ['video/mp4'] if modality=='video' else ['audio/wav','audio/mpeg','audio/flac','audio/mp4','audio/ogg']
    headers={'Content-Length':{'schema':integer(minimum=0)},'Content-Type':{'schema':text()},'ETag':{'schema':text()},'Accept-Ranges':{'schema':text(enum=['bytes'])},'X-Nativ-Store-ID':{'schema':text()}}
    response={'description':'Authenticated immutable content. HEAD has the same headers and no body.','headers':headers}
    if not head:response['content']={kind:{'schema':text(format='binary')} for kind in mimes}
    operation['responses']['200']=response
    operation['responses']['206']={**deepcopy(response),'description':'Requested byte range.','headers':{**headers,'Content-Range':{'schema':text()}}}
    operation['responses']['416']={'description':'Unsatisfiable byte range.','headers':{'Content-Range':{'schema':text()}},'content':{'text/plain':{'schema':text()}}}
    operation.setdefault('parameters',[]).extend([_header('Range',description='Single or supported multipart byte ranges, e.g. bytes=0-1023.'),_header('If-Range',description='ETag or modification-date validator for a range request.')])


def install_openapi(app):
    """Wrap the existing app generator once; never replace its base endpoints."""
    if getattr(app,'_nativ_generation_openapi_installed',False):return
    original=app.openapi
    app._nativ_generation_openapi_installed=True
    app.openapi_schema=None
    def generate():
        if app.openapi_schema and app.openapi_schema.get('x-nativ-generation-contract')==1:return app.openapi_schema
        document=deepcopy(original());schemas=document.setdefault('components',{}).setdefault('schemas',{})
        for name,value in components().items():
            if name in schemas and schemas[name]!=value:raise RuntimeError('Conflicting generation OpenAPI component: '+name)
            schemas[name]=value
        schemes=document['components'].setdefault('securitySchemes',{})
        scheme={'type':'http','scheme':'bearer','description':'Existing Nativ server bearer credential; never use query-string authentication.'}
        if 'NativGenerationBearer' in schemes and schemes['NativGenerationBearer']!=scheme:raise RuntimeError('Conflicting generation security scheme')
        schemes['NativGenerationBearer']=scheme
        for path,item in list(document['paths'].items()):
            match=re.match(r'^/v1/(music|video)/(.*)$',path)
            if not match:continue
            modality,suffix=match.groups()
            # Explicit HEAD routes exist in api.py but FastAPI hides them by default.
            if suffix=='assets/{asset_id}/content' or suffix=='inputs/{input_id}/content':
                item.setdefault('head',deepcopy(item['get']));item['head']['operationId']='head_'+modality+'_'+suffix.replace('/','_').replace('{','').replace('}','')
            for method,operation in item.items():
                if method not in {'get','head'}|MUTATIONS:continue
                operation['security']=[{'NativGenerationBearer':[]}]
                parameters=operation.setdefault('parameters',[])
                if method in MUTATIONS:parameters.append(_header('X-Nativ-Store-ID',required=True,description='Exact store_id read from this canonical server info endpoint. Missing=428; changed=409.'))
                if method=='post' and suffix=='generations':parameters.append(_header('Idempotency-Key',required=True,description='Durably saved key for this exact user intent and frozen request. Missing=400; conflict=409.',schema=text(minLength=1,maxLength=200)))
                responses=operation.setdefault('responses',{})
                for status in ('400','401','403','404','409','410','413','429','500','502','503'):
                    responses.setdefault(status,_json_response('NativGenerationErrorEnvelope','Safe structured generation error.'))
                if method in MUTATIONS:responses['428']=_json_response('NativGenerationErrorEnvelope','Missing X-Nativ-Store-ID precondition.')
                request_name=None;response_name=None
                if suffix=='info':response_name='NativGenerationInfo'
                elif suffix=='models':response_name='NativGenerationProfilePage'
                elif suffix=='server-state' or suffix=='prepare-stop':response_name='NativGenerationServerState'
                elif suffix=='configuration':response_name='NativGenerationConfiguration'
                elif suffix.startswith('configuration/'):
                    request_name='NativGenerationConfigurationPatch';response_name='NativGenerationConfigurationProfile'
                elif suffix=='runtimes':response_name='NativGenerationRuntimeList'
                elif suffix.startswith('runtimes/'):
                    request_name='NativGenerationRuntimeAction';response_name='NativGenerationRuntimeActionResult'
                    for parameter in parameters:
                        if parameter.get('name')=='action':parameter['schema']=text(enum=['install','repair','remove','cancel-install'])
                elif suffix=='sessions':
                    response_name='NativGenerationSessionPage' if method=='get' else 'NativGenerationSession'
                    if method=='post':request_name='NativGenerationSessionCreate'
                elif suffix.startswith('sessions/'):
                    response_name='NativGenerationSession';request_name='NativGenerationSessionPatch'
                elif suffix=='generations':
                    response_name='NativGenerationJobPage' if method=='get' else 'NativGenerationJob'
                    if method=='post':request_name='Nativ'+modality.title()+'GenerationRequest'
                elif suffix.endswith('/events'):
                    parameters.append(_header('Last-Event-ID',description='Nonnegative ordered event ID; pruned cursors return a current-state snapshot.',schema=integer(minimum=0,default=0)))
                    responses['200']={'description':'SSE id/event/data records containing NativGenerationEvent JSON; : keepalive comments. Disconnect never cancels work.','content':{'text/event-stream':{'schema':text(),'x-event-schema':ref('NativGenerationEvent')}},'headers':{'Cache-Control':{'schema':text(const='no-store')}}}
                elif suffix.startswith('generations/'):
                    response_name='NativGenerationJob'
                    if suffix.endswith('/release-remote-reservation'):request_name='NativGenerationReservationRelease'
                elif '/references/' in suffix:
                    response_name='NativGenerationReference';request_name='NativGenerationReferencePut' if method=='put' else 'NativGenerationReferenceDelete'
                elif suffix.endswith('/usages'):response_name='NativGenerationUsages'
                elif suffix.startswith('assets/') and suffix.endswith('/content'):_binary(operation,modality,head=method=='head')
                elif suffix.endswith('/poster'):_binary(operation,modality,mime='image/jpeg')
                elif suffix.startswith('assets/'):response_name='NativGenerationAsset'
                elif suffix=='inputs' and method=='post':
                    operation['requestBody']={'required':True,'description':'One file only; <=25 MiB encoded, <=40M decoded pixels; actual still PNG/JPEG/WebP. Multipart envelope <=25 MiB+64 KiB.',
                        'content':{'multipart/form-data':{'schema':obj({'file':text(format='binary')},('file',),closed=True),'encoding':{'file':{'contentType':'image/png, image/jpeg, image/webp'}}}}}
                    response_name='NativVideoInput'
                elif suffix.startswith('inputs/'):
                    if suffix.endswith('/content'):_binary(operation,modality,mime='image/png' if '/derivatives/' in suffix else ['image/png','image/jpeg','image/webp'],head=method=='head')
                    elif suffix.endswith('/transform'):request_name='NativVideoTransformRequest';response_name='NativVideoDerivative'
                    else:response_name='NativVideoInputDeleted' if method=='delete' else 'NativVideoInput'
                if request_name:operation['requestBody']={'required':request_name not in {'NativGenerationConfigurationPatch','NativGenerationRuntimeAction','NativGenerationSessionCreate','NativGenerationSessionPatch'},'description':'JSON object <=128 KiB. Unsupported generation controls are rejected, never silently dropped.','content':{'application/json':{'schema':ref(request_name)}}}
                if response_name:
                    status='202' if suffix in ('generations','prepare-stop') and method=='post' else '201' if suffix in ('sessions','inputs') and method=='post' else '200'
                    responses[status]=_json_response(response_name)
        document['x-nativ-generation-contract']=1
        app.openapi_schema=document
        return document
    app.openapi=generate
