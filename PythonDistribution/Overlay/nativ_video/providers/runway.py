"""Runway Gen-4.5 official 2024-11-06 API contract."""
import base64
import time
from nativ_generation.contracts import CancellationResult,GenerationError
from .base import fail
from .http import CloudVideoProvider

class RunwayVideoProvider(CloudVideoProvider):
    BASE_URL='https://api.dev.runwayml.com'
    ENDPOINTS=('text_to_video','image_to_video')
    SUCCESS={'SUCCEEDED'}; FAILURE={'FAILED'}; CANCELLED={'CANCELLED'}
    PENDING={'PENDING','THROTTLED','RUNNING'}

    def normalize(self,request):
        a=super().normalize(request)
        try: length=len(a['prompt'].encode('utf-16-le'))//2
        except UnicodeError: fail('prompt','The prompt contains invalid Unicode.')
        if not 1<=length<=1000: fail('prompt','Runway prompts must be 1–1000 UTF-16 code units.')
        if not 2<=a['duration']<=10: fail('duration','Gen-4.5 duration must be an integer from 2 to 10 seconds.')
        a['frame_count']=None; a['fps']=None
        return a

    def _version(self,headers): headers['X-Runway-Version']='2024-11-06'

    def run(self,job,context):
        if job.get('provider_operation'): return self.reconcile(job,context)
        base,account,headers=self._identity(job); self._version(headers); a=job['request']
        body=dict(model='gen4.5',promptText=a['prompt'],ratio=f"{a['width']}:{a['height']}",duration=a['duration'],outputFormat='mp4')
        if 'seed' in a: body['seed']=a['seed']
        endpoint='image_to_video' if a['operation']=='image_to_video' else 'text_to_video'
        if endpoint=='image_to_video':
            ref=a['inputs'][0]; path=context.input_path(ref['input_id'],ref['role'])
            # Data URI has a 5 MiB JSON-string bound, including its base64 overhead.
            if path.stat().st_size>3_932_100:
                raise GenerationError('provider_input_too_large','This private Runway data-URI image exceeds the 5 MiB encoded-URI limit.',field='inputs')
            uri='data:image/png;base64,'+base64.b64encode(path.read_bytes()).decode('ascii')
            if len(uri)>5*1024*1024: raise GenerationError('provider_input_too_large','The private encoded reference exceeds Runway limits.',field='inputs')
            body['promptImage']=[{'uri':uri,'position':'first'}]
        context.begin_dispatch()
        data=self._request('POST','/v1/'+endpoint,headers,body=body,expected=(200,),ambiguous=True)
        oid=data.get('id')
        if not isinstance(oid,str) or not oid or '/' in oid:
            raise GenerationError('submission_unknown','Runway accepted the request without a valid task identity.',status=502,definitive=False)
        operation=dict(id=oid,endpoint_kind=endpoint,base_url=base,account_id=account)
        context.record_operation(oid,endpoint,base_url=base,account_id=account)
        return self._poll(operation,headers,context)

    def _status_path(self,op): return '/v1/tasks/'+op['id']
    def _state(self,data): return data.get('status')
    def _output(self,data):
        outputs=data.get('output')
        if not isinstance(outputs,list) or len(outputs)!=1 or not isinstance(outputs[0],str):
            raise GenerationError('provider_output_missing','Runway completed without one retrievable video.',retryable=True,status=502)
        return outputs[0]

    def cancel(self,job,context):
        _,_,headers=self._identity(job); self._version(headers)
        op=job.get('provider_operation')
        if not op: return CancellationResult(False,message='No provider acceptance identity is known; possible provider work remains unresolved.')
        known=op.get('state') or op.get('provider_outcome')
        if known in self.SUCCESS|self.FAILURE|self.CANCELLED or job.get('state')=='succeeded':
            return CancellationResult(False,True,'completed' if known=='SUCCEEDED' or job.get('state')=='succeeded' else known.lower(),
                'A known terminal Runway task is never deleted by Cancel.')
        with self._lock:
            # Respect the polling floor even when cancellation follows a recent status GET.
            previous=op.get('last_polled_at')
            if isinstance(previous,(int,float)):
                delay=max(0,min(5,5-(time.time()-previous)))
                if delay:(self.services.sleep or time.sleep)(delay)
            # Recheck immediately before DELETE; the provider can still finish in between.
            data=self._request('GET',self._status_path(op),headers)
            state=self._state(data)
            if state in self.SUCCESS|self.FAILURE|self.CANCELLED:
                return CancellationResult(False,True,state.lower(),'Runway is already terminal; retrieval is preserved.')
            if state not in self.PENDING: return CancellationResult(False,message='The Runway state could not be confirmed.')
            self._request('DELETE',self._status_path(op),headers,expected=(204,404))
            # 204 does not establish compute stop, refund, or even win a completion race.
            return CancellationResult(False,message='Runway accepted a cancellation/deletion request. Completion, physical stop and refund remain unconfirmed; the task can finish between status and cancellation.')
