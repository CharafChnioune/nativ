from .base import MusicProvider


class MiniMaxMusic3RemoteProvider(MusicProvider):
    def run(self, job, context):
        request = job['request']
        endpoint = self.endpoint()
        credential = self.services.credentials(self.profile['id'])
        headers = {'Authorization': f'Bearer {credential}'} if credential else {}
        payload = dict(model='MiniMaxAI/MiniMax-Music3', input=request['lyrics'],
            instructions=request['prompt'], seed=request.get('seed', 0),
            max_new_tokens=int(request['duration_seconds'] * 25), response_format='wav', stream=False)
        context.begin_dispatch()
        response = self.request('POST', endpoint + '/v1/audio/speech', json=payload, headers=headers)
        operation = response.headers.get('x-request-id')
        if operation: context.record_operation(operation, 'minimax_gpu_request', provider_outcome='completed')
        context.emit('writing_audio', provider_outcome='completed')
        return self.save(response.content, context, request, operation=operation)

    def health(self):
        """Read-only compatibility probe; never generates music."""
        endpoint = self.endpoint()
        credential = self.services.credentials(self.profile['id'])
        headers = {'Authorization': f'Bearer {credential}'} if credential else {}
        self.request('GET', endpoint + '/health', headers=headers)
        data = self.request('GET', endpoint + '/v1/models', headers=headers).json()
        return any(item.get('id') == 'MiniMaxAI/MiniMax-Music3' for item in data.get('data', []))
