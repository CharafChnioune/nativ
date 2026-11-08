"""Bounded remote-provider observation, never an automatic submission retry."""
from __future__ import annotations
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import time
from .contracts import CancellationResult,GenerationError,ProviderResult
from .repository import encode
from .runtimes import child_environment,WorkerSupervisor,write_all

class RemoteExecutionProvider:
    def __init__(self,profile,services):self.profile=profile;self.services=services
    def run(self,job,context):return self._execute('run',job,context)
    def reconcile(self,job,context):return self._execute('reconcile',job,context)
    def cancel(self,job,context):return self._execute('cancel',job,context)
    def shutdown(self):pass
    def _execute(self,mode,job,context):
        from .memory import MemoryGuard
        memory=MemoryGuard() if mode!='cancel' else None
        read,write=os.pipe()
        env=child_environment(Path(sys.prefix))
        # Explicit trusted installed package directory; no caller-supplied PYTHONPATH.
        env['PYTHONPATH']=str(Path(__file__).resolve().parent.parent)
        command=[sys.executable,'-m','nativ_generation.worker_guardian','--parent-fd',str(read),'--module','nativ_generation.remote_worker']
        try:proc=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True,env=env,cwd=Path(__file__).resolve().parent.parent,pass_fds=(read,),bufsize=0)
        except BaseException:os.close(read);os.close(write);raise
        os.close(read);selector=selectors.DefaultSelector();selector.register(proc.stdout,selectors.EVENT_READ);os.set_blocking(proc.stdout.fileno(),False)
        start=time.monotonic();hello=False;buffer=bytearray();result=None;error=None;worker_exit=None
        def send(value):
            data=encode(value).encode()+b'\n'
            if len(data)>256*1024:raise GenerationError('provider_request_too_large','The helper request exceeds its bound.',status=413)
            write_all(proc.stdin,data,timeout=5,cancellation=None if mode=='cancel' else context.cancellation)
        try:
            while worker_exit is None:
                if mode!='cancel':context.check_cancelled()
                if memory:memory.check()
                elapsed=time.monotonic()-start
                if elapsed>(20 if mode=='cancel' else 4*60*60) or (not hello and elapsed>15):raise GenerationError('provider_observation_timeout','Provider observation stopped at its time limit. Retrieve an existing operation; do not repeat a paid submission.',definitive=False,status=504)
                if proc.poll() is not None and not selector.select(0):break
                for key,_ in selector.select(.05):
                    chunk=os.read(key.fd,65536)
                    if not chunk:selector.unregister(key.fileobj);continue
                    buffer.extend(chunk)
                    if len(buffer)>1024*1024:raise GenerationError('provider_protocol_limit','The provider helper returned an oversized event.',definitive=False,status=502)
                    while b'\n' in buffer:
                        line,_,rest=buffer.partition(b'\n');buffer=bytearray(rest)
                        try:event=json.loads(line)
                        except ValueError:raise GenerationError('provider_protocol_invalid','The provider helper returned an invalid event.',definitive=False,status=502) from None
                        kind=event.get('type')
                        if not hello:
                            if kind!='handshake' or event.get('protocol')!=1 or event.get('worker')!='nativ-remote':raise GenerationError('provider_identity_invalid','The provider helper did not identify itself.',status=502)
                            hello=True;send({'mode':mode,'job':job,'configuration':self.services.configuration.get(self.profile['id'],{}),'credential':self.services.credentials(self.profile['id']),'output_dir':str(context.output_dir),'inputs':context.inputs})
                        elif kind=='dispatch':
                            if mode!='run':raise GenerationError('illegal_redispatch','A recovery or cancellation helper attempted to generate again.',status=502)
                            context.begin_dispatch();send({'ack':True})
                        elif kind=='operation':
                            operation=event['operation'];context.record_operation(operation.pop('id'),operation.pop('endpoint_kind'),**operation);send({'ack':True})
                        elif kind=='progress':context.emit(event.get('stage','retrieving'),event.get('progress'),**({'provider_outcome':'completed'} if event.get('details',{}).get('provider_outcome')=='completed' else {}))
                        elif kind=='result':
                            if mode=='cancel' or result is not None:raise GenerationError('provider_protocol_invalid','Unexpected helper result.',definitive=False,status=502)
                            path=Path(event['path'])
                            if not path.is_absolute() or not path.resolve().is_relative_to(context.output_dir.resolve()):raise GenerationError('invalid_candidate','The helper returned an unowned output.',status=502)
                            result=ProviderResult(path,event.get('effective_parameters',{}),event.get('metadata',{}))
                        elif kind=='cancellation':result=CancellationResult(event.get('confirmed') is True,event.get('provider_terminal') is True,event.get('provider_outcome','unknown'),event.get('message'))
                        elif kind=='error':
                            data=event['error'];error=GenerationError(data['code'],data['message'],field=data.get('field'),retryable=data.get('retryable',False),status=event.get('status',502),definitive=event.get('definitive',False))
                        elif kind=='worker_exit':worker_exit=event.get('code')
                        else:raise GenerationError('provider_protocol_invalid','Unexpected provider event.',definitive=False,status=502)
            if error:raise error
            if worker_exit!=0 or result is None:raise GenerationError('provider_process_failed','Provider observation ended without a complete result.',definitive=False,status=502)
            return result
        finally:
            os.close(write)
            try:proc.wait(5)
            except subprocess.TimeoutExpired:WorkerSupervisor._stop(proc)
            selector.close();proc.stdin.close();proc.stdout.close()
