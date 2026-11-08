from .base import MusicProvider, MAX_OUTPUT_BYTES, error


class MiniMaxCloudProvider(MusicProvider):
    def run(self, job, context):
        request = job['request']
        endpoint = self.endpoint('https://api.minimax.io')
        # Region is selected in private configuration, never by a generation request.
        if endpoint not in ('https://api.minimax.io', 'https://api.minimax.cn'):
            raise error('invalid_configuration', 'Choose the documented MiniMax global or China endpoint.', status=409)
        payload = dict(model=self.profile['model'], prompt=request['prompt'],
            is_instrumental=request['instrumental'], lyrics_optimizer=False,
            stream=False, output_format='hex', audio_setting=dict(sample_rate=44100,
                bitrate=256000, format=request['output_format']))
        if not request['instrumental']: payload['lyrics'] = request['lyrics']
        headers = {'Authorization': f'Bearer {self.credential()}'}
        context.begin_dispatch()
        response = self.request('POST', endpoint + '/v1/music_generation', json=payload, headers=headers)
        try:
            data = response.json()
            if 'status_code' not in data.get('base_resp', {}):
                raise error('provider_protocol', 'MiniMax returned no confirmed application outcome.', definitive=False, status=502)
            if data['base_resp']['status_code'] != 0:
                raise error('provider_rejected', 'MiniMax rejected this request. Verify account access and available credit.', status=502)
            operation = data.get('trace_id')
            if operation: context.record_operation(str(operation), 'minimax_cloud_trace')
            result = data['data']
            encoded = result['audio']
            if result['status'] != 2 or not isinstance(encoded, str) or len(encoded) > 2 * MAX_OUTPUT_BYTES:
                raise error('invalid_audio', 'MiniMax did not return one complete bounded audio result.', status=502)
            if operation: context.record_operation(str(operation), 'minimax_cloud_trace', provider_outcome='completed')
            context.emit('writing_audio', provider_outcome='completed')
            content = bytes.fromhex(encoded)
        except GenerationError: raise
        except (ValueError, KeyError, TypeError):
            raise error('provider_protocol', 'MiniMax returned an invalid music response.', definitive=False, status=502) from None
        return self.save(content, context, request, operation=operation)


from nativ_generation.contracts import GenerationError
