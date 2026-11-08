"""One explicit MLX thread for complete Images operations.

Request reading/authentication stay on ASGI. The executor owns model load,
generation, encoding and MLX cleanup. Cancellation detaches the observer while
its compute lease remains held until actual execution and synchronization end.
"""
from __future__ import annotations
import asyncio
from concurrent.futures import ThreadPoolExecutor
import importlib
import os
from pathlib import Path
import threading
from nativ_generation.contracts import GenerationError
from nativ_generation.resources import ComputeAdmission

_executor=None
_admission=None
_stream=None
_mutex=threading.Lock()
_closed=False
_active_work=0


def _mlx():return importlib.import_module('mlx.core')


def configure_admission(admission):
    global _admission,_closed
    with _mutex:
        if _executor is not None and _admission is not admission:
            raise RuntimeError('Cannot change active image admission ownership')
        _admission=admission
        if _executor is None:_closed=False


def _infrastructure():
    global _executor,_admission
    with _mutex:
        if _closed:raise GenerationError('server_stopping','Image execution is shutting down.',status=503)
        if _admission is None:
            root=Path(os.environ.get('NATIV_GENERATION_ROOT','~/Library/Application Support/io.github.charafchnioune.nativ/Generations')).expanduser()
            _admission=ComputeAdmission(root.parent/'compute-admission.lock')
        if _executor is None:_executor=ThreadPoolExecutor(max_workers=1,thread_name_prefix='Nativ Images MLX')
        return _executor,_admission


def _invoke(function,args,lease=None):
    global _stream,_active_work
    mx=None
    try:
        mx=_mlx()
        if _stream is None:_stream=mx.new_stream(mx.default_device())
        with mx.stream(_stream):return function(*args)
    finally:
        # A returned request or cancelled awaiter is not proof GPU work stopped.
        try:
            if mx is not None and _stream is not None:mx.synchronize(_stream)
        finally:
            if lease is not None:
                lease.close()
                with _mutex:_active_work-=1


async def run_image(function,*args):
    global _active_work
    executor,admission=_infrastructure()
    lease=admission.try_acquire('images')
    if lease is None:raise GenerationError('inference_busy','Local inference is busy. Wait for it to finish before generating or editing an image.',status=409,retryable=True)
    with _mutex:_active_work+=1
    try:future=executor.submit(_invoke,function,args,lease)
    except BaseException:
        lease.close()
        with _mutex:_active_work-=1
        raise
    observed=asyncio.wrap_future(future)
    # Consume an eventual detached failure without altering the caller's result.
    observed.add_done_callback(lambda item:item.exception() if not item.cancelled() else None)
    return await asyncio.shield(observed)


def has_active_work():
    with _mutex:return _active_work>0


def unload_idle_images():
    """Core scheduler calls this synchronously while already owning its lease.

    No second lease is acquired. The queue cannot have an admitted image running
    while the scheduler owns the process-wide exclusive lease.
    """
    executor,_=_infrastructure()
    def unload():
        app=importlib.import_module('mlx_vlm.server.app')
        for kind in ('image_generation','image_edit'):app._unload_model_cache_group(kind)
    executor.submit(_invoke,unload,()).result()


async def drain():
    with _mutex:executor=_executor
    if executor is not None:await asyncio.shield(asyncio.wrap_future(executor.submit(lambda:None)))


async def shutdown():
    global _executor,_stream,_closed
    with _mutex:_closed=True;executor=_executor
    if executor is None:return
    await drain()
    executor.shutdown(wait=False)
    with _mutex:_executor=None;_stream=None
