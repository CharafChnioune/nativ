"""Small worker/provider contracts shared by Music and Video.

Adapters execute on scheduler threads, never on the HTTP event loop. They may
produce candidates, but only the service validates and publishes an asset.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from threading import Event
from typing import Any, Callable, Mapping, Protocol


class GenerationError(Exception):
    def __init__(self, code: str, message: str, *, field: str | None = None,
                 retryable: bool = False, status: int = 400, definitive: bool = True):
        super().__init__(message)
        self.code, self.message, self.field = code, message, field
        self.retryable, self.status, self.definitive = retryable, status, definitive

    def public(self, job_id: str | None = None) -> dict[str, Any]:
        return {"code": self.code, "message": self.message, "field": self.field,
                "retryable": self.retryable, "job_id": job_id}


class GenerationCancelled(Exception):
    pass


@dataclass(frozen=True)
class ProviderResult:
    path: Path
    effective_parameters: Mapping[str, Any] = field(default_factory=dict)
    metadata: Mapping[str, Any] = field(default_factory=dict)
    provider_request_id: str | None = None


@dataclass(frozen=True)
class CancellationResult:
    confirmed: bool
    provider_terminal: bool = False
    provider_outcome: str = "unknown"
    message: str | None = None


@dataclass
class ProviderServices:
    """Injectable infrastructure; credentials are never part of catalog records."""
    worker: Any = None
    transport: Any = None
    credentials: Callable[[str], str | None] = lambda profile_id: None
    configuration: Mapping[str, Any] = field(default_factory=dict)
    sleep: Callable[[float], None] | None = None


class ProviderContext:
    def __init__(self, *, output_dir: Path, cancellation: Event,
                 emit: Callable[[str, float | None, Mapping[str, Any]], None],
                 dispatch: Callable[[], None],
                 operation: Callable[[Mapping[str, Any]], None],
                 inputs: Mapping[str, Mapping[str, Any]] | None = None):
        self.output_dir, self.cancellation = output_dir, cancellation
        self.inputs = dict(inputs or {})
        self._emit, self._dispatch, self._operation = emit, dispatch, operation

    def check_cancelled(self) -> None:
        if self.cancellation.is_set():
            raise GenerationCancelled()

    def emit(self, stage: str, progress: float | None = None, **details: Any) -> None:
        self.check_cancelled()
        self._emit(stage, progress, details)

    def begin_dispatch(self) -> None:
        """Call immediately before the actual generation call/remote POST."""
        self.check_cancelled()
        self._dispatch()

    def record_operation(self, operation_id: str, endpoint_kind: str,
                         **details: Any) -> None:
        # Persist accepted identity even when a cancellation arrived during POST.
        self._operation({"id": operation_id, "endpoint_kind": endpoint_kind, **details})

    def wait(self, seconds: float) -> None:
        if self.cancellation.wait(seconds):
            raise GenerationCancelled()

    def input_path(self, input_id: str, role: str | None = None) -> Path:
        item = self.inputs.get(input_id + ':' + role) if role else None
        item = item or self.inputs.get(input_id)
        if not item or not item.get("path"):
            raise GenerationError("input_unavailable", "The accepted reference image is unavailable.", field="inputs")
        return Path(item["path"])


class GenerationProvider(Protocol):
    def normalize(self, request: Mapping[str, Any]) -> dict[str, Any]: ...
    def run(self, job: Mapping[str, Any], context: ProviderContext) -> ProviderResult: ...
    def reconcile(self, job: Mapping[str, Any], context: ProviderContext) -> ProviderResult: ...
    def cancel(self, job: Mapping[str, Any], context: ProviderContext) -> CancellationResult: ...
    def shutdown(self) -> None: ...
