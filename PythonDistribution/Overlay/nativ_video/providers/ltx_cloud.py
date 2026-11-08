"""Official asynchronous LTX V2 generation; V1 remains upload-only."""
from pathlib import Path
from nativ_generation.contracts import CancellationResult,GenerationError
from .base import fail
from .http import CloudVideoProvider,safe_url

class LTXCloudProvider(CloudVideoProvider):
    BASE_URL='https://api.ltx.io'
    ENDPOINTS=('text-to-video','image-to-video')
    SUCCESS={'completed'}; FAILURE={'failed'}; CANCELLED={'cancelled'}
    PENDING={'pending','processing'}

    def normalize(self,request):
        a=super().normalize(request)
        # Curated resolution candidates currently expose 720p, 24fps only.
        duration=a['duration']
        allowed=self.profile['capabilities']['presets'][a['output_preset']]['duration_options']
        if duration not in allowed: fail('duration','This duration is unavailable for the model, resolution and frame-rate combination.')
        return a

    def _upload(self,path,headers):
        if path.stat().st_size>15_000_000:
            raise GenerationError('provider_input_too_large','LTX generation images must be at most 15 MB.',field='inputs')
        info=self._request('POST','/v1/upload',headers)
        url=info.get('upload_url'); uri=info.get('storage_uri'); required=info.get('required_headers')
        if not isinstance(uri,str) or not uri.startswith('ltx://') or not isinstance(required,dict) or any(not isinstance(k,str) or not isinstance(v,str) for k,v in required.items()):
            raise GenerationError('provider_upload_invalid','The provider returned an invalid upload contract.',status=502)
        safe_url(url)
        if any(k.lower() in ('authorization','proxy-authorization','host','cookie') for k in required):
            raise GenerationError('provider_upload_invalid','The provider requested an unsafe storage header.',status=502)
        storage_headers={'Content-Type':'image/png',**required}
        try:
            with path.open('rb') as content:
                response=self.client.request('PUT',url,headers=storage_headers,content=content,timeout=120,follow_redirects=False)
            if response.status_code not in (200,201,204): raise ValueError()
        except Exception:
            raise GenerationError('provider_upload_failed','The immutable reference could not be uploaded.',retryable=True,status=502) from None
        return uri

    def run(self,job,context):
        if job.get('provider_operation'): return self.reconcile(job,context)
        base,account,headers=self._identity(job); a=job['request']
        body=dict(prompt=a['prompt'],model=self.profile['model'],duration=a['duration'],
                  resolution=f"{a['width']}x{a['height']}",fps=a['fps'],generate_audio=a['audio_mode']=='native_generated')
        endpoint='image-to-video' if a['operation']=='image_to_video' else 'text-to-video'
        for ref in a.get('inputs',[]):
            context.check_cancelled()
            body['image_uri' if ref['role']=='first_frame' else 'last_frame_uri']=self._upload(context.input_path(ref['input_id'],ref['role']),headers)
        context.begin_dispatch()
        data=self._request('POST','/v2/'+endpoint,headers,body=body,expected=(202,),ambiguous=True)
        oid=data.get('id')
        if not isinstance(oid,str) or not oid or '/' in oid:
            raise GenerationError('submission_unknown','LTX accepted the request without a valid operation identity.',status=502,definitive=False)
        operation=dict(id=oid,endpoint_kind=endpoint,base_url=base,account_id=account)
        context.record_operation(oid,endpoint,base_url=base,account_id=account)
        return self._poll(operation,headers,context)

    def _status_path(self,op): return '/v2/'+op['endpoint_kind']+'/'+op['id']
    def _state(self,data): return data.get('status')
    def _output(self,data):
        url=data.get('result',{}).get('video_url')
        if not isinstance(url,str): raise GenerationError('provider_output_missing','LTX completed without a retrievable video.',status=502,retryable=True)
        return url
    def cancel(self,job,context):
        self._identity(job)
        return CancellationResult(False,message='LTX V2 has no verified cancellation endpoint. Provider work and charges may continue.')
