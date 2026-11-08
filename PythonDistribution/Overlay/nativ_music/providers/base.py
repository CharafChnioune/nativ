"""Strict normalization and bounded transport shared only by music adapters."""
from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Mapping
from urllib.parse import urlsplit
import wave

from nativ_generation.contracts import (CancellationResult, GenerationError, ProviderResult)

MAX_OUTPUT_BYTES = 1024 * 1024 * 1024


def error(code, message, field=None, **kwargs):
    return GenerationError(code, message, field=field, **kwargs)


class BufferedResponse:
    def __init__(self, status_code, content, headers):
        self.status_code, self.content, self.headers = status_code, content, headers
    def json(self): return json.loads(self.content)


class MusicProvider:
    def __init__(self, profile, services):
        self.profile, self.services = profile, services
        self.config = dict(services.configuration.get(profile['id'], {}))

    def normalize(self, request: Mapping):
        cap = self.profile['capabilities']
        allowed = {'model', 'prompt', 'lyrics', 'instrumental', 'session_id', 'allow_remote', 'output_format', 'title'}
        if cap['seed']: allowed.add('seed')
        if cap['duration']['semantics'] != 'prompt_only': allowed.add('duration_seconds')
        allowed.update(cap['options'])
        pinned = {key: value for key, value in self.profile['defaults'].items() if key in ('steps', 'shift')}
        allowed.update(pinned)
        for field, value in pinned.items():
            if field in request and request[field] != value:
                raise error('unsupported_control', 'This sampling setting is fixed by the selected profile.', field)
        # Sampling is deliberately pinned until a separate profile is qualified.
        for field in request:
            if field not in allowed:
                raise error('unsupported_control', 'This profile does not support this control.', field)
        out = dict(self.profile['defaults']); out.update(request)
        out['model'] = self.profile['id']
        if 'allow_remote' in out and not isinstance(out['allow_remote'], bool):
            raise error('invalid_control', 'Allow remote must be a boolean.', 'allow_remote')
        out.setdefault('allow_remote', False)
        prompt = out.get('prompt')
        if not isinstance(prompt, str) or not prompt.strip():
            raise error('invalid_prompt', 'A music description is required.', 'prompt')
        limit = 512 if self.profile['provider'] == 'acestep' else 2000 if self.profile['provider'] == 'minimax_cloud' else 10000
        if len(prompt) > limit: raise error('text_too_long', f'The description is limited to {limit} characters.', 'prompt')
        if not isinstance(out['instrumental'], bool): raise error('invalid_control', 'Instrumental must be a boolean.', 'instrumental')
        if self.profile['deployment'] != 'local' and out.get('allow_remote') is not True:
            raise error('remote_not_allowed', 'Explicit remote execution is required.', 'allow_remote')
        if out['output_format'] not in cap['output_formats']:
            raise error('unsupported_format', 'This profile does not support this output format.', 'output_format')
        lyrics = out.get('lyrics', '')
        if not isinstance(lyrics, str): raise error('invalid_lyrics', 'Lyrics must be text.', 'lyrics')
        if not cap['lyrics'] and lyrics: raise error('unsupported_control', 'This profile has no lyric-conditioned singing contract.', 'lyrics')
        if not cap['vocals'] and not out['instrumental']: raise error('unsupported_control', 'This profile supports instrumental generation only.', 'instrumental')
        if len(lyrics) > (3500 if self.profile['provider'] == 'minimax_cloud' else 4096):
            raise error('text_too_long', 'The lyrics exceed this profile limit.', 'lyrics')
        if not out['instrumental'] and cap['lyrics_required_for_vocals'] and not lyrics.strip():
            raise error('lyrics_required', 'Enter lyrics for vocal generation.', 'lyrics')
        if out['instrumental']:
            out['lyrics'] = '[instrumental]' if self.profile['provider'] in ('minimax_mlx', 'minimax_remote') else ''
        elif cap['lyrics']: out['lyrics'] = lyrics
        if 'duration_seconds' in out:
            value = out['duration_seconds']; bounds = cap['duration']
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or not bounds['minimum'] <= value <= bounds['maximum']:
                raise error('invalid_duration', 'Duration is outside this profile’s supported range.', 'duration_seconds')
        if 'seed' in out and (isinstance(out['seed'], bool) or not isinstance(out['seed'], int) or not 0 <= out['seed'] <= (4294967294 if self.profile['provider'] == 'stable_audio_cloud' else 2**63 - 1)):
            raise error('invalid_seed', 'Seed is outside this profile’s supported range.', 'seed')
        if 'bpm' in out and (isinstance(out['bpm'], bool) or not isinstance(out['bpm'], int) or not 30 <= out['bpm'] <= 300):
            raise error('invalid_control', 'BPM must be between 30 and 300.', 'bpm')
        if 'key' in out and (not isinstance(out['key'], str) or len(out['key']) > 32): raise error('invalid_control', 'Invalid musical key hint.', 'key')
        if 'time_signature' in out and str(out['time_signature']) not in ('2', '3', '4', '6'): raise error('invalid_control', 'Choose 2, 3, 4 or 6.', 'time_signature')
        return out

    def cancel(self, job, context):
        return CancellationResult(confirmed=False, message='Observation stopped. The remote provider may continue and bill.' if self.profile['deployment'] != 'local' else 'The owned worker must exit before cancellation is confirmed.')

    def reconcile(self, job, context):
        raise error('reconciliation_unavailable', 'This provider has no documented operation lookup; do not resubmit this job.', definitive=False, status=409)

    def shutdown(self): pass

    def credential(self):
        value = self.services.credentials(self.profile['id'])
        if not value: raise error('configuration_required', 'Configure a provider credential before generation.', status=409)
        return value

    def endpoint(self, default=None):
        endpoint = self.config.get('endpoint', default)
        if not isinstance(endpoint, str): raise error('configuration_required', 'Configure the provider endpoint.', status=409)
        parsed = urlsplit(endpoint)
        if parsed.username or parsed.password or parsed.query or parsed.fragment or not parsed.hostname:
            raise error('invalid_configuration', 'The configured provider endpoint is invalid.', status=409)
        local = parsed.hostname in ('localhost', '127.0.0.1', '::1')
        if parsed.scheme != 'https' and not (parsed.scheme == 'http' and local and self.config.get('allow_local_http') is True):
            raise error('invalid_configuration', 'Provider endpoints require HTTPS; loopback development HTTP must be explicitly enabled.', status=409)
        return endpoint.rstrip('/')

    def request(self, method, url, **kwargs):
        transport = self.services.transport
        owned = transport is None
        if owned:
            import httpx
            transport = httpx.Client(follow_redirects=False, timeout=1800)
        try:
            if hasattr(transport, 'stream'):
                # Bound wire bytes while receiving, before a complete response can
                # allocate unbounded memory. JSON hex needs twice the audio budget.
                with transport.stream(method, url, timeout=1800, follow_redirects=False, **kwargs) as incoming:
                    limit = 2 * MAX_OUTPUT_BYTES + 65536
                    length = incoming.headers.get('content-length')
                    if length and int(length) > limit:
                        raise error('output_too_large', 'The provider response exceeds the import limit.', status=502)
                    body = bytearray()
                    for chunk in incoming.iter_bytes():
                        if len(body) + len(chunk) > limit:
                            raise error('output_too_large', 'The provider response exceeds the import limit.', status=502)
                        body.extend(chunk)
                    response = BufferedResponse(incoming.status_code, bytes(body), dict(incoming.headers))
            else:
                response = transport.request(method, url, timeout=1800, follow_redirects=False, **kwargs)
        except GenerationError: raise
        except Exception:
            raise error('provider_connection_lost', 'The provider connection ended without a confirmed outcome.', definitive=False, retryable=False, status=502) from None
        finally:
            if owned: transport.close()
        if response.status_code >= 400:
            # No raw provider body/trace/URL enters persisted diagnostics.
            raise error('provider_rejected', f'The provider returned HTTP {response.status_code}.', definitive=method == 'POST' and response.status_code < 500, status=502)
        if response.status_code not in (200, 201, 202):
            raise error('provider_protocol', 'The provider returned an unexpected response.', definitive=False, status=502)
        return response

    def save(self, content, context, request, *, metadata=None, operation=None):
        context.check_cancelled()
        if not content or len(content) > MAX_OUTPUT_BYTES:
            raise error('invalid_audio', 'The returned audio is empty or exceeds the output limit.', status=502)
        fmt = request['output_format']
        if fmt == 'wav' and not (content[:4] == b'RIFF' and content[8:12] == b'WAVE'):
            raise error('invalid_audio', 'The provider did not return the requested WAV audio.', status=502)
        if fmt == 'mp3' and not (content[:3] == b'ID3' or (len(content) >= 2 and content[0] == 0xff and content[1] & 0xe0 == 0xe0)):
            raise error('invalid_audio', 'The provider did not return recognizable MP3 audio.', status=502)
        path = context.output_dir / f'candidate.{fmt}'
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        measured = dict(metadata or {})
        if self.profile['deployment'] != 'local': measured.setdefault('provider_outcome', 'completed')
        if fmt == 'wav':
            try:
                with wave.open(str(path), 'rb') as audio:
                    measured.update(sample_rate=audio.getframerate(), channels=audio.getnchannels(), duration_seconds=audio.getnframes()/audio.getframerate())
            except (wave.Error, EOFError): raise error('invalid_audio', 'The provider returned damaged WAV audio.', status=502) from None
            if measured['sample_rate'] not in self.profile['capabilities']['sample_rates'] or measured['channels'] != 2 or measured['duration_seconds'] <= 0:
                raise error('invalid_audio', 'The provider returned audio outside its declared rate/channel contract.', status=502)
        return ProviderResult(path, dict(request), measured, operation)
