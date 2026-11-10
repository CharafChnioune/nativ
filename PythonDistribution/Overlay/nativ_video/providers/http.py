"""Bounded cloud transport; paid creates are single-shot, signed URLs stay private."""
from __future__ import annotations
import ipaddress
import json
import os
from pathlib import Path
import socket
import random
import threading
import time
from urllib.parse import urlparse,quote
from nativ_generation.contracts import GenerationError,GenerationCancelled,ProviderResult
from .base import BaseVideoProvider

MAX_OUTPUT_BYTES=2*1024*1024*1024


def safe_url(url):
    if not isinstance(url,str) or len(url)>16384:
        raise GenerationError('provider_url_invalid','The provider returned an invalid media location.',status=502)
    p=urlparse(url)
    if p.scheme!='https' or not p.hostname or p.username or p.password or p.port not in (None,443) or p.fragment:
        raise GenerationError('provider_url_invalid','The provider returned an unsafe media location.',status=502)
    try:
        addresses=socket.getaddrinfo(p.hostname,443,type=socket.SOCK_STREAM)
        if not addresses or any(not ipaddress.ip_address(a[4][0]).is_global for a in addresses): raise ValueError()
    except (OSError,ValueError):
        raise GenerationError('provider_url_invalid','The provider media host cannot be safely resolved.',status=502)
    return url


class CloudVideoProvider(BaseVideoProvider):
    BASE_URL=''
    POLL_SECONDS=5

    def __init__(self,profile,services):
        super().__init__(profile,services)
        self._client=services.transport
        self._owned_client=False
        self._lock=threading.RLock()
        self._last_poll={}

    @property
    def client(self):
        if self._client is None:
            import httpx
            self._client=httpx.Client(follow_redirects=False,timeout=30)
            self._owned_client=True
        return self._client

    def _identity(self,job=None):
        cfg=self.services.configuration.get(self.profile['id'],{})
        base=cfg.get('endpoint',cfg.get('base_url',self.BASE_URL)).rstrip('/')
        account=cfg.get('account_id')
        if base!=self.BASE_URL or not isinstance(account,str) or not account:
            raise GenerationError('provider_configuration','Configure an enabled provider account with its stable account identity.',status=409)
        operation=(job or {}).get('provider_operation')
        if operation:
            if operation.get('base_url')!=base or operation.get('account_id')!=account:
                raise GenerationError('deployment_changed','This operation belongs to another provider endpoint or account. Restore its original account configuration.',status=409)
            if operation.get('endpoint_kind') not in self.ENDPOINTS:
                raise GenerationError('provider_operation_invalid','The saved provider endpoint is unsupported.',status=409)
            oid=operation.get('id')
            if not isinstance(oid,str) or not oid or len(oid)>256 or '/' in oid or '\\' in oid:
                raise GenerationError('provider_operation_invalid','The saved provider operation identity is invalid.',status=409)
        key=self.services.credentials(self.profile['id'])
        if not key: raise GenerationError('credentials_required','Configure credentials for this enabled provider account.',status=409)
        return base,account,dict(Authorization='Bearer '+key)

    def _request(self,method,path,headers,*,body=None,expected=(200,),ambiguous=False):
        kwargs={'headers':headers,'timeout':30,'follow_redirects':False}
        if body is not None:kwargs['json']=body
        def invalid():
            return GenerationError('submission_unknown' if ambiguous else 'provider_response_invalid',
                'The provider returned an invalid bounded response.',status=502,definitive=not ambiguous)
        def status(response):
            code_status=response.status_code
            if code_status not in expected:
                definitive=not ambiguous or (400<=code_status<500 and code_status not in (408,499))
                code='provider_rejected' if definitive else 'submission_unknown'
                if code_status in (401,403):code='provider_authentication'
                elif code_status==402:code='provider_insufficient_credits'
                elif code_status in (404,410):code='output_expired'
                elif code_status==422:code='provider_content_rejected'
                elif code_status==429:code='provider_capacity'
                raise GenerationError(code,'The provider rejected the request.' if definitive else 'The provider submission outcome is unknown; it must not be resubmitted.',
                    status=502,retryable=not ambiguous and code_status in (429,500,502,503,504),definitive=definitive)
            return code_status
        try:
            if hasattr(self.client,'stream'):
                # Bound wire bytes before allocation. Never download a private
                # error body merely to classify its HTTP status.
                with self.client.stream(method,self.BASE_URL+path,**kwargs) as response:
                    code_status=status(response)
                    if code_status in (204,404):return {}
                    length=response.headers.get('content-length')
                    if length is not None and (not str(length).isdigit() or int(length)>1024*1024):raise invalid()
                    raw=bytearray()
                    for chunk in response.iter_bytes(chunk_size=65536):
                        if len(raw)+len(chunk)>1024*1024:raise invalid()
                        raw.extend(chunk)
                    try:data=json.loads(raw,parse_constant=lambda _:(_ for _ in ()).throw(ValueError()))
                    except (ValueError,UnicodeError):raise invalid() from None
            else:
                # Compatibility for injected, already-buffered fixture transports.
                # The production HTTPX client always takes the bounded stream path.
                response=self.client.request(method,self.BASE_URL+path,**kwargs)
                if status(response) in (204,404):return {}
                raw=getattr(response,'content',None)
                if raw is not None and len(raw)>1024*1024:raise invalid()
                try:data=response.json()
                except Exception:raise invalid() from None
            if not isinstance(data,dict) or len(json.dumps(data,allow_nan=False).encode())>128*1024:raise invalid()
            return data
        except GenerationError:raise
        except (ValueError,TypeError,UnicodeError):raise invalid() from None
        except Exception:
            raise GenerationError('submission_unknown' if ambiguous else 'provider_unavailable',
                'The provider connection ended before its outcome was confirmed.',status=502,
                retryable=not ambiguous,definitive=not ambiguous) from None

    def _download(self,url,context):
        safe_url(url)
        context.output_dir.mkdir(parents=True,exist_ok=True)
        dest=context.output_dir/'provider-original.mp4'; partial=context.output_dir/'provider-original.partial'
        count=0; start=time.monotonic()
        try:
            with self.client.stream('GET',url,headers={},timeout=60,follow_redirects=False) as response:
                if response.status_code not in (200,):
                    if response.status_code in (401,403,404,410):
                        raise GenerationError('output_url_expired','The output link has expired. Retry Download refreshes the same operation.',retryable=True,status=502)
                    raise GenerationError('download_failed','The provider output could not be downloaded.',retryable=True,status=502)
                raw_length=response.headers.get('content-length')
                if raw_length is not None and (not raw_length.isdigit() or int(raw_length)>MAX_OUTPUT_BYTES):
                    raise GenerationError('output_too_large','The output exceeds the bounded download limit.',status=502)
                with partial.open('wb') as out:
                    os.chmod(partial,0o600)
                    for chunk in response.iter_bytes(chunk_size=1024*1024):
                        context.check_cancelled(); count+=len(chunk)
                        if count>MAX_OUTPUT_BYTES or time.monotonic()-start>1800:
                            raise GenerationError('download_limit','The output exceeded its byte or time limit.',retryable=True,status=502)
                        out.write(chunk)
                    out.flush(); os.fsync(out.fileno())
            if not count: raise GenerationError('download_empty','The provider returned an empty output.',retryable=True,status=502)
            os.replace(partial,dest)
            return dest
        except (GenerationError,GenerationCancelled): raise
        except Exception:
            raise GenerationError('download_failed','The output download was interrupted; retry this existing result.',retryable=True,status=502) from None
        finally: partial.unlink(missing_ok=True)

    def _poll(self,operation,headers,context):
        failures=0
        while True:
            # Includes first retrieval/restart: no rapid poll burst after recovery.
            cfg=self.services.configuration.get(self.profile['id'],{})
            jitter=random.uniform(0,max(0,min(1,cfg.get('poll_jitter_seconds',0.35))))
            context.wait(min(60,self.POLL_SECONDS*(2**min(failures,3)))+jitter)
            try:
                with self._lock:
                    data=self._request('GET',self._status_path(operation),headers)
                failures=0
            except GenerationError as e:
                if not e.retryable or failures>=4: raise
                failures+=1; continue
            state=self._state(data)
            context.record_operation(operation['id'],operation['endpoint_kind'],**{k:v for k,v in operation.items() if k not in ('id','endpoint_kind','state','provider_outcome','last_polled_at')},state=state,last_polled_at=time.time(),provider_outcome='completed' if state in self.SUCCESS else 'pending' if state in self.PENDING else 'failed' if state in self.FAILURE else 'cancelled' if state in self.CANCELLED else 'unknown')
            if state in self.SUCCESS:
                context.emit('retrieving',provider_outcome='completed')
                path=self._download(self._output(data),context)
                return ProviderResult(path,effective_parameters={},metadata={'provider_outcome':'completed','provider_endpoint_kind':operation['endpoint_kind']},provider_request_id=operation['id'])
            if state in self.FAILURE:
                raise GenerationError('provider_generation_failed','The provider reported a terminal generation failure.',status=502)
            if state in self.CANCELLED:
                raise GenerationError('provider_cancelled','The provider reports this operation was cancelled.',status=409)
            if state not in self.PENDING:
                raise GenerationError('provider_response_invalid','The provider returned an unsupported job state.',status=502)
            context.emit('provider_'+state.lower(),provider_outcome='pending')

    def reconcile(self,job,context):
        _,_,headers=self._identity(job)
        self._version(headers)
        operation=job.get('provider_operation')
        if not operation: raise GenerationError('submission_unknown','No confirmed provider operation is available; never repeat this create.',status=409,definitive=False)
        return self._poll(operation,headers,context)

    def _version(self,headers): pass

    def shutdown(self):
        if self._owned_client and self._client is not None: self._client.close()
