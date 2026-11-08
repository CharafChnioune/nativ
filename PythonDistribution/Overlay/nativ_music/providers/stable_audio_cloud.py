import re
from .base import MusicProvider, error


class StableAudioCloudProvider(MusicProvider):
    def run(self, job, context):
        request = job['request']
        headers = {'Authorization': f'Bearer {self.credential()}', 'Accept': 'audio/*'}
        fields = dict(model='stable-audio-3', prompt=request['prompt'] + '\nInstrumental music, no vocals.',
            duration=str(request['duration_seconds']), output_format=request['output_format'])
        if 'seed' in request: fields['seed'] = str(request['seed'])
        context.begin_dispatch()
        response = self.request('POST', 'https://api.stability.ai/v2beta/audio/stable-audio/text-to-audio',
            headers=headers, data=fields, files={'none': ('', b'')})
        try:
            operation = response.json()['id']
            if response.status_code != 202 or not isinstance(operation, str) or not re.fullmatch('[a-fA-F0-9]{64}', operation): raise ValueError()
        except (ValueError, KeyError, TypeError):
            raise error('provider_protocol', 'Stability did not return a valid accepted operation ID.', definitive=False, status=502) from None
        context.record_operation(operation, 'stable_audio_result')
        return self.poll(operation, request, context)

    def poll(self, operation, request, context):
        if not isinstance(operation, str) or not re.fullmatch('[a-fA-F0-9]{64}', operation):
            raise error('invalid_operation', 'Invalid persisted Stability operation.', status=409)
        headers = {'Authorization': f'Bearer {self.credential()}', 'Accept': 'audio/*'}
        for attempt in range(360):
            context.check_cancelled()
            response = self.request('GET', 'https://api.stability.ai/v2beta/audio/results/' + operation, headers=headers)
            if response.status_code == 200:
                return self.save(response.content, context, request,
                    metadata={'effective_seed': response.headers.get('seed')}, operation=operation)
            context.emit('generating', provider_request_id=operation)
            context.wait(min(10 + attempt, 30))
        raise error('provider_timeout', 'The provider operation is still unresolved; reconcile the existing operation later.', definitive=False, status=504)

    def reconcile(self, job, context):
        operation = job.get('provider_operation') or {}
        if operation.get('endpoint_kind') != 'stable_audio_result':
            return super().reconcile(job, context)
        return self.poll(operation['id'], job['request'], context)
