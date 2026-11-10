"""Strict accepted parameters, separate from measured output metadata."""
from __future__ import annotations
import secrets
from collections.abc import Mapping
from nativ_generation.contracts import GenerationError, CancellationResult
from ..inputs import validate_transform

_COMMON = {'model','prompt','session_id','allow_remote','output_format','operation','output_preset',
           'audio_mode','seed','inputs','width','height','frame_count','fps','duration','steps','flow_shift',
           'audio_sample_rate','modality','contract_version','approximate_duration'}


def fail(field, message, code='unsupported_parameter'):
    raise GenerationError(code,message,field=field)


class BaseVideoProvider:
    def __init__(self, profile, services):
        self.profile, self.services = profile, services

    def normalize(self, request):
        if not isinstance(request, Mapping): fail('request','A JSON object is required.')
        for key in request:
            if key not in _COMMON: fail(key,'This control is not supported by the selected video profile.')
        p=self.profile; cap=p['capabilities']; local=p['deployment']=='local'
        if request.get('modality','video')!='video': fail('modality','This profile generates video.')
        if request.get('audio_sample_rate',cap.get('audio_sample_rate'))!=cap.get('audio_sample_rate'): fail('audio_sample_rate','The native audio sample rate is fixed by this profile.')
        if request.get('model',p['id']) != p['id']: fail('model','The selected profile does not match this request.')
        prompt=request.get('prompt','')
        if not isinstance(prompt,str) or not prompt.strip(): fail('prompt','Enter a nonempty video prompt.')
        try:prompt.encode('utf-8')
        except UnicodeError:fail('prompt','The prompt contains invalid Unicode.')
        if len(prompt)>5000: fail('prompt','The prompt exceeds 5,000 characters.')
        if not local and request.get('allow_remote') is not True: fail('allow_remote','Enable external execution explicitly for this request.','remote_consent_required')
        operation=request.get('operation','text_to_video')
        if operation not in cap['operations']: fail('operation','This operation is unavailable.')
        preset=request.get('output_preset',p['defaults']['output_preset'])
        if not isinstance(preset,str) or preset not in cap['presets']: fail('output_preset','Choose a preset offered by this profile.')
        effective=cap['presets'][preset]
        if effective.get('operation',operation)!=operation: fail('output_preset','This output preset requires image-to-video.')
        audio=request.get('audio_mode',p['defaults']['audio_mode'])
        if audio not in cap['audio_modes']: fail('audio_mode','This audio mode is unavailable for this profile.')
        if request.get('output_format','mp4') != 'mp4': fail('output_format','The initial video contract produces MP4.')
        if type(request.get('contract_version',1)) is not int or request.get('contract_version',1)!=1: fail('contract_version','Unsupported video contract version.')
        accepted=dict(model=p['id'],modality='video',contract_version=1,prompt=prompt,
                      operation=operation,output_preset=preset,audio_mode=audio,output_format='mp4',
                      allow_remote=not local,inputs=[],frame_count=None,fps=None,
                      audio_sample_rate=cap.get('audio_sample_rate'))
        if request.get('session_id') is not None: accepted['session_id']=request['session_id']
        for field in ('width','height','fps','frame_count','steps','flow_shift'):
            value=effective.get(field)
            if field in request and (request[field] != value or (value is not None and type(request[field]) is not type(value))):
                fail(field,'This value does not match the selected tested output-preset candidate.')
            if field in effective: accepted[field]=value
        if local:
            if 'duration' in request: fail('duration','Use the explicit frame count and FPS of the selected preset.')
            accepted['approximate_duration']=effective['frame_count']/effective['fps']
            if request.get('approximate_duration',accepted['approximate_duration'])!=accepted['approximate_duration']: fail('approximate_duration','The clip timing is fixed by its explicit frame count and FPS.')
        else:
            duration=request.get('duration',p['defaults']['duration'])
            if type(duration) is not int: fail('duration','Select an explicit integer clip duration.')
            accepted['duration']=duration
        seed=request.get('seed')
        if cap.get('seed'):
            if seed is None: seed=secrets.randbits(32)
            if type(seed) is not int or not 0<=seed<=4294967295: fail('seed','Seed must be an integer from 0 to 4294967295.')
            accepted['seed']=seed
        elif seed is not None: fail('seed','This provider does not expose a verified seed control.')
        refs=request.get('inputs',[])
        if not isinstance(refs,list) or len(refs)>len(cap['input_roles']): fail('inputs','Unsupported image-reference combination.')
        roles=set()
        for ref in refs:
            if not isinstance(ref,dict) or set(ref)-{'input_id','role','transform'}: fail('inputs','Reference images require an opaque input_id, role and transform.')
            role=ref.get('role'); iid=ref.get('input_id')
            if role not in cap['input_roles'] or role in roles: fail('inputs','This image role is unsupported or repeated.')
            if not isinstance(iid,str) or not iid or len(iid)>128 or any(x in iid for x in '/\\:'): fail('inputs','Use an uploaded opaque input_id.')
            roles.add(role)
            accepted['inputs'].append(dict(input_id=iid,role=role,transform=validate_transform(ref.get('transform'))))
        if operation=='text_to_video' and refs: fail('inputs','Text-to-video does not accept image references.')
        if operation=='image_to_video' and 'first_frame' not in roles: fail('inputs','Image-to-video requires a first-frame image.')
        return accepted

    def reconcile(self,job,context):
        raise GenerationError('interrupted','This local attempt cannot be regenerated during recovery.',status=409)

    def cancel(self,job,context):
        return CancellationResult(False,message='Cancellation requires the owned worker to exit.')

    def shutdown(self):
        pass
