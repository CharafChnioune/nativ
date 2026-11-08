import base64
import io
import json
from pathlib import Path
import sys
import tempfile
from threading import Event
import unittest
import wave

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'PythonDistribution/Overlay'))
from nativ_generation.contracts import GenerationError, ProviderContext, ProviderServices
try:
    from nativ_music.catalog import profiles
    from nativ_music.providers import build_provider
except ImportError:
    profiles = build_provider = None


def wav_bytes(rate=44100):
    target = io.BytesIO()
    with wave.open(target, 'wb') as f:
        f.setnchannels(2); f.setsampwidth(2); f.setframerate(rate)
        f.writeframes(b'\0' * rate * 4)
    return target.getvalue()


class Response:
    def __init__(self, status=200, data=None, content=b'', headers=None):
        self.status_code = status; self._data = data; self.content = content
        self.headers = headers or {}
    def json(self): return self._data


class Transport:
    def __init__(self, responses): self.responses = iter(responses); self.calls = []
    def request(self, method, url, **kwargs):
        self.calls.append((method, url, kwargs))
        response = next(self.responses)
        if isinstance(response, Exception): raise response
        return response


class MusicProviderTests(unittest.TestCase):
    def provider(self, model, responses=(), config=None, worker=None):
        self.assertIsNotNone(profiles, 'Music provider catalog must be implemented')
        profile = next(x for x in profiles() if x['id'] == model)
        self.transport = Transport(responses)
        return build_provider(profile, ProviderServices(transport=self.transport, worker=worker,
            credentials=lambda _: 'fixture-key', configuration=config or {})), profile
    def context(self, directory):
        self.dispatched = []; self.operations = []; self.events = []
        return ProviderContext(output_dir=Path(directory), cancellation=Event(),
            emit=lambda *x: self.events.append(x), dispatch=lambda: self.dispatched.append(True),
            operation=self.operations.append)
    def job(self, provider, profile, **request):
        normalized = provider.normalize(dict(model=profile['id'], prompt='Warm acoustic guitar', **request))
        return dict(request=normalized, profile=profile, provider_operation=None)

    def test_provider_profiles_reject_ignored_controls_and_preserve_lyrics(self):
        provider, profile = self.provider('minimax-music3-mxfp8-local')
        lyrics = '[Verse]\n  Handwritten words  \n'
        accepted = provider.normalize(dict(model=profile['id'], prompt='song', lyrics=lyrics, instrumental=False))
        self.assertEqual(accepted['lyrics'], lyrics)
        for field in ('guidance_scale', 'reference_audio', 'negative_prompt'):
            with self.assertRaises(GenerationError) as failure:
                provider.normalize(dict(model=profile['id'], prompt='song', **{field: 1}))
            self.assertEqual(failure.exception.field, field)
        self.assertEqual(provider.normalize(dict(model=profile['id'], prompt='song', instrumental=True))['lyrics'], '[instrumental]')

    def test_normalized_profile_defaults_are_stable_for_recovery(self):
        for identifier in ('acestep-v15-turbo-local', 'minimax-music3-mxfp8-local', 'stable-audio-3-small-local'):
            provider, profile = self.provider(identifier)
            accepted = provider.normalize(dict(model=identifier, prompt='Piano', instrumental=True))
            self.assertEqual(provider.normalize(accepted), accepted)
            with self.assertRaises(GenerationError):
                provider.normalize(dict(model=identifier, prompt='Piano', steps=999))

    def test_minimax_cloud_hex_and_application_error(self):
        data = wav_bytes()
        response = dict(base_resp=dict(status_code=0), data=dict(status=2, audio=data.hex()), trace_id='trace-1')
        provider, profile = self.provider('minimax-music3-cloud', [Response(data=response)])
        job = self.job(provider, profile, instrumental=True, allow_remote=True, output_format='wav')
        with tempfile.TemporaryDirectory() as d:
            result = provider.run(job, self.context(d))
            self.assertEqual(result.path.read_bytes(), data)
        sent = self.transport.calls[0][2]['json']
        self.assertTrue(sent['is_instrumental']); self.assertFalse(sent['lyrics_optimizer'])
        self.assertNotIn('duration', sent); self.assertNotIn('seed', sent)
        self.assertEqual(self.operations[0]['id'], 'trace-1')
        provider, profile = self.provider('minimax-music3-cloud', [Response(data={'base_resp': {'status_code': 1004}})])
        with tempfile.TemporaryDirectory() as d, self.assertRaises(GenerationError):
            provider.run(self.job(provider, profile, instrumental=True, allow_remote=True), self.context(d))

    def test_lyria_steps_content_and_revision_no_hard_duration(self):
        encoded = base64.b64encode(b'ID3fixture-audio').decode()
        response = {'id': 'interaction-1', 'steps': [{'type': 'model_output', 'content': [
            {'type': 'text', 'text': '[Verse]\nGenerated lyrics'},
            {'type': 'audio', 'mime_type': 'audio/mpeg', 'data': encoded}]}]}
        provider, profile = self.provider('lyria-3.5-hosted', [Response(data=response)])
        with tempfile.TemporaryDirectory() as d:
            result = provider.run(self.job(provider, profile, instrumental=False, lyrics='Manual words', allow_remote=True), self.context(d))
            self.assertEqual(result.path.read_bytes(), b'ID3fixture-audio')
            self.assertEqual(result.metadata['generated_lyrics'], '[Verse]\nGenerated lyrics')
        sent = self.transport.calls[0][2]
        self.assertEqual(sent['headers']['Api-Revision'], '2026-05-20')
        self.assertIn('Manual words', sent['json']['input'])
        self.assertTrue(sent['json']['store'])
        with self.assertRaises(GenerationError): provider.normalize(dict(model=profile['id'], prompt='song', duration_seconds=30, allow_remote=True))

    def test_lyria_retrieves_stored_interaction_without_a_new_post(self):
        encoded = base64.b64encode(b'ID3retrieved-audio').decode()
        operation='v1_known-id'
        response = {'id':operation,'status':'completed','steps':[{'type':'model_output','content':[{'type':'audio','mime_type':'audio/mpeg','data':encoded}]}]}
        provider, profile = self.provider('lyria-3.5-hosted',[Response(data=response)])
        job=self.job(provider,profile,instrumental=True,allow_remote=True)
        job['provider_operation']={'id':operation,'endpoint_kind':'lyria_interaction'}
        with tempfile.TemporaryDirectory() as d:
            result=provider.reconcile(job,self.context(d));self.assertEqual(result.path.read_bytes(),b'ID3retrieved-audio')
        self.assertEqual(self.transport.calls[0][0],'GET')
        self.assertTrue(self.transport.calls[0][1].endswith('/interactions/'+operation))
        self.assertEqual(self.dispatched,[])
        self.assertTrue(profile['capabilities']['retrieval_supported'])

    def test_lyria_pending_get_waits_then_retrieves_same_identity(self):
        operation='v1_pending'
        audio=base64.b64encode(b'ID3ready').decode()
        provider, profile=self.provider('lyria-3.5-hosted',[
            Response(data={'id':operation,'status':'in_progress'}),
            Response(data={'id':operation,'status':'completed','steps':[{'type':'model_output','content':[{'type':'audio','mime_type':'audio/mpeg','data':audio}]}]})])
        job=self.job(provider,profile,instrumental=True,allow_remote=True);job['provider_operation']={'id':operation,'endpoint_kind':'lyria_interaction'}
        with tempfile.TemporaryDirectory() as d:
            context=self.context(d);waits=[];context.wait=waits.append
            provider.reconcile(job,context)
        self.assertEqual(waits,[5]);self.assertEqual([call[0] for call in self.transport.calls],['GET','GET'])
        self.assertEqual(self.dispatched,[])

    def test_lyria_failed_and_wrong_identity_get_do_not_generate_again(self):
        for body,code,definitive in [({'id':'v1_expected','status':'failed'},'provider_generation_failed',True),
                                     ({'id':'v1_wrong','status':'completed'},'provider_protocol',False)]:
            provider, profile=self.provider('lyria-3.5-hosted',[Response(data=body)])
            job=self.job(provider,profile,instrumental=True,allow_remote=True);job['provider_operation']={'id':'v1_expected','endpoint_kind':'lyria_interaction'}
            with tempfile.TemporaryDirectory() as d,self.assertRaises(GenerationError) as failure:provider.reconcile(job,self.context(d))
            self.assertEqual(failure.exception.code,code);self.assertEqual(failure.exception.definitive,definitive)
            self.assertEqual([call[0] for call in self.transport.calls],['GET']);self.assertEqual(self.dispatched,[])

    def test_failed_result_get_is_observation_uncertainty_not_execution_rejection(self):
        provider, profile = self.provider('stable-audio-3-cloud',[Response(403)])
        job=self.job(provider,profile,instrumental=True,allow_remote=True)
        job['provider_operation']={'id':'a'*64,'endpoint_kind':'stable_audio_result'}
        with tempfile.TemporaryDirectory() as d,self.assertRaises(GenerationError) as failure:
            provider.reconcile(job,self.context(d))
        self.assertFalse(failure.exception.definitive)

    def test_stability_persists_202_id_before_poll_and_reconciles_without_post(self):
        operation = 'a' * 64
        provider, profile = self.provider('stable-audio-3-cloud', [Response(202, {'id': operation}), Response(content=wav_bytes())])
        with tempfile.TemporaryDirectory() as d:
            result = provider.run(self.job(provider, profile, instrumental=True, allow_remote=True, output_format='wav'), self.context(d))
            self.assertTrue(result.path.is_file())
        self.assertEqual(self.operations[0]['id'], operation)
        self.assertEqual([x[0] for x in self.transport.calls], ['POST', 'GET'])
        self.assertNotIn('lyrics', self.transport.calls[0][2]['data'])
        provider, profile = self.provider('stable-audio-3-cloud', [Response(content=wav_bytes())])
        job = self.job(provider, profile, instrumental=True, allow_remote=True, output_format='wav')
        job['provider_operation'] = dict(id=operation, endpoint_kind='stable_audio_result')
        with tempfile.TemporaryDirectory() as d: provider.reconcile(job, self.context(d))
        self.assertEqual([x[0] for x in self.transport.calls], ['GET'])
        self.assertEqual(self.dispatched, [])

    def test_timeout_after_post_is_ambiguous_and_never_retried(self):
        provider, profile = self.provider('lyria-3.5-hosted', [TimeoutError('secret upstream diagnostic')])
        with tempfile.TemporaryDirectory() as d, self.assertRaises(GenerationError) as failure:
            provider.run(self.job(provider, profile, instrumental=True, allow_remote=True), self.context(d))
        self.assertFalse(failure.exception.definitive)
        self.assertNotIn('secret', failure.exception.message)
        self.assertEqual(len(self.transport.calls), 1)

    def test_remote_gpu_frame_ceiling_and_32khz_metadata(self):
        provider, profile = self.provider('minimax-music3-remote-gpu', [Response(content=wav_bytes(32000))],
            {'minimax-music3-remote-gpu': {'endpoint': 'https://music.example.test'}})
        with tempfile.TemporaryDirectory() as d:
            result = provider.run(self.job(provider, profile, instrumental=True, duration_seconds=30, seed=7, allow_remote=True), self.context(d))
            self.assertEqual(result.metadata['sample_rate'], 32000)
        request = self.transport.calls[0][2]['json']
        self.assertEqual(request['max_new_tokens'], 750)
        self.assertEqual(request['input'], '[instrumental]')
        self.assertFalse(request['stream'])

    def test_provider_audio_rejects_wrong_rate_and_truncated_mp3(self):
        provider, profile = self.provider('minimax-music3-remote-gpu', [Response(content=wav_bytes(44100))],
            {'minimax-music3-remote-gpu': {'endpoint': 'https://music.example.test'}})
        with tempfile.TemporaryDirectory() as d, self.assertRaises(GenerationError):
            provider.run(self.job(provider, profile, instrumental=True, allow_remote=True), self.context(d))
        provider, profile = self.provider('lyria-3.5-hosted')
        with tempfile.TemporaryDirectory() as d, self.assertRaises(GenerationError):
            provider.save(b'X', self.context(d), {'output_format': 'mp3'})

    def test_stable_small_rejects_vocals_and_overlong_duration(self):
        provider, profile = self.provider('stable-audio-3-small-local')
        for extra in ({'instrumental': False}, {'duration_seconds': 121}, {'lyrics': 'words'}, {'cfg_scale': 3}):
            with self.assertRaises(GenerationError): provider.normalize(dict(model=profile['id'], prompt='piano', **extra))


if __name__ == '__main__': unittest.main()
