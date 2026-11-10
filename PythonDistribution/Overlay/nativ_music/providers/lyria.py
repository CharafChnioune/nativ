import base64
import binascii
from urllib.parse import quote
from .base import MusicProvider, MAX_OUTPUT_BYTES, error


class LyriaProvider(MusicProvider):
    endpoint='https://generativelanguage.googleapis.com/v1beta/interactions'
    def headers(self):return {'x-goog-api-key':self.credential(),'Api-Revision':'2026-05-20'}

    def run(self,job,context):
        request=job['request'];description=request['prompt']
        if request['instrumental']:description+='\nInstrumental only, no vocals.'
        elif request.get('lyrics'):description+='\nUse these supplied lyrics exactly:\n'+request['lyrics']
        # The current Interactions schema supports storing lyria-3.5 interactions
        # for GET retrieval. The catalog discloses provider storage explicitly.
        payload=dict(model='lyria-3.5',input=description,store=True)
        headers=self.headers();context.begin_dispatch()
        body=self.json(self.request('POST',self.endpoint,json=payload,headers=headers))
        result=self.parse(body,request,context)
        if result is not None:return result
        operation=body.get('id')
        if not operation:raise error('provider_protocol','Lyria returned pending work without a retrievable interaction ID.',definitive=False,status=502)
        return self.retrieve(operation,request,context)

    @staticmethod
    def json(response):
        try:
            body=response.json()
            if not isinstance(body,dict):raise ValueError()
            return body
        except (TypeError,ValueError):raise error('provider_protocol','Lyria returned invalid interaction JSON.',definitive=False,status=502) from None

    def parse(self,body,request,context):
        operation=body.get('id');status=body.get('status')
        if operation is not None and (not isinstance(operation,str) or not 0<len(operation)<=1024):
            raise error('provider_protocol','Lyria returned an invalid interaction identity.',definitive=False,status=502)
        outcome={'completed':'completed','failed':'failed','cancelled':'cancelled','in_progress':'running','running':'running','pending':'pending'}.get(status,'unknown')
        if operation:context.record_operation(operation,'lyria_interaction',provider_outcome=outcome)
        if status in ('failed','cancelled'):
            raise error('provider_generation_failed' if status=='failed' else 'provider_cancelled','The stored Lyria interaction is terminal without completed audio.',status=502)
        if status in ('in_progress','running','pending'):return None
        try:
            audio=[];lyrics=[]
            for step in body['steps']:
                if step.get('type')!='model_output':continue
                for content in step.get('content',[]):
                    if content.get('type')=='text':lyrics.append(content.get('text',''))
                    elif content.get('type')=='audio':
                        if content.get('mime_type') not in ('audio/mpeg','audio/mp3'):raise ValueError()
                        encoded=content['data']
                        if not isinstance(encoded,str) or len(encoded)>4*(MAX_OUTPUT_BYTES//3+1):raise ValueError()
                        audio.append(base64.b64decode(encoded,validate=True))
            if len(audio)!=1:raise ValueError()
        except (KeyError,ValueError,TypeError,binascii.Error):
            raise error('provider_protocol','Lyria did not return a single complete MP3 in model-output steps.',definitive=False,status=502) from None
        if operation:context.record_operation(operation,'lyria_interaction',provider_outcome='completed')
        context.emit('writing_audio',provider_outcome='completed')
        return self.save(audio[0],context,request,metadata={'generated_lyrics':'\n'.join(lyrics),'provider_outcome':'completed'},operation=operation)

    def retrieve(self,operation,request,context):
        if not isinstance(operation,str) or not 0<len(operation)<=1024:
            raise error('invalid_operation','Invalid stored Lyria interaction identity.',status=409)
        for _ in range(360):
            context.check_cancelled()
            body=self.json(self.request('GET',self.endpoint+'/'+quote(operation,safe=''),headers=self.headers()))
            if body.get('id')!=operation:raise error('provider_protocol','Lyria returned a different interaction identity.',definitive=False,status=502)
            result=self.parse(body,request,context)
            if result is not None:return result
            context.emit('generating',provider_request_id=operation);context.wait(5)
        raise error('provider_timeout','The stored Lyria interaction remains unresolved. Retrieve the same operation later.',definitive=False,status=504)

    def reconcile(self,job,context):
        operation=job.get('provider_operation') or {}
        if operation.get('endpoint_kind')!='lyria_interaction':return super().reconcile(job,context)
        return self.retrieve(operation['id'],job['request'],context)
