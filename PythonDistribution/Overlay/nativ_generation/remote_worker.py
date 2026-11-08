"""Cancellable cloud I/O process. Dispatch and acceptance wait for durable host ACKs."""
import contextlib
import dataclasses
import json
from pathlib import Path
import sys
import threading
from .contracts import GenerationError,ProviderContext,ProviderServices

PROTOCOL=1

def main():
    output=sys.stdout
    def emit(kind,**values):output.write(json.dumps({'type':kind,**values},separators=(',',':'))+'\n');output.flush()
    def ack(kind,**values):
        emit(kind,**values)
        line=sys.stdin.buffer.readline(1025)
        if line!=b'{"ack":true}\n':raise RuntimeError('Lost durable acknowledgment')
    emit('handshake',protocol=PROTOCOL,worker='nativ-remote')
    raw=sys.stdin.buffer.readline(256*1024+1)
    if not raw or len(raw)>256*1024:return 2
    provider=None
    try:
        envelope=json.loads(raw);job=envelope['job'];mode=envelope['mode'];pid=job['profile']['id']
        if mode not in ('run','reconcile','cancel'):raise ValueError()
        try:import truststore
        except ImportError:pass
        else:truststore.inject_into_ssl()
        from .service import build_provider
        services=ProviderServices(configuration={pid:envelope['configuration']},credentials=lambda requested:envelope['credential'] if requested==pid else None)
        provider=build_provider(job['profile'],services)
        context=ProviderContext(output_dir=Path(envelope['output_dir']),cancellation=threading.Event(),
            emit=lambda stage,progress,details:emit('progress',stage=stage,progress=progress,details={'provider_outcome':'completed'} if details.get('provider_outcome')=='completed' else {}),
            dispatch=lambda:ack('dispatch'),operation=lambda value:ack('operation',operation=value),inputs=envelope.get('inputs',{}))
        with contextlib.redirect_stdout(sys.stderr):result=getattr(provider,mode)(job,context)
        if mode=='cancel':emit('cancellation',**dataclasses.asdict(result))
        else:emit('result',path=str(result.path),effective_parameters=dict(result.effective_parameters),metadata=dict(result.metadata))
        return 0
    except GenerationError as error:
        emit('error',error=error.public(),definitive=error.definitive,status=error.status);return 1
    except BaseException:
        emit('error',error=GenerationError('provider_process_failed','The provider helper stopped without a confirmed outcome.',definitive=False,status=502).public(),definitive=False,status=502);return 1
    finally:
        if provider:
            try:provider.shutdown()
            except Exception:pass

if __name__=='__main__':raise SystemExit(main())
