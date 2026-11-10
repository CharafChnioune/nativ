# Provider integration contract v1

Implementation branch: `codex/music-video-generation`, based on merge `e22f7b93`.
Root owns shared `nativ_generation`; feature workers may now edit their own paths.

## Package surface (both nativ_music and nativ_video)

`catalog.py: profiles() -> list[dict]` returns curated lightweight records.
`providers/__init__.py: build_provider(profile: dict, services: ProviderServices)`
returns an implementation of `GenerationProvider`. No heavy imports at package
import time. A missing runtime never prevents discovery/control API startup.

Profile fields: `id`, `modality` (`music`/`video`), `provider` (adapter ID),
`deployment` (`local`/`remote_gpu`/`hosted`), `profile_revision` (immutable contract
revision), `display_name`, `model` (checkpoint/model ID), `runtime` (manifest ID or
null), `qualification` (`unqualified`/`experimental`/`qualified`), `capabilities`
(typed JSON-safe task-specific limits), `defaults` (explicit provider defaults).
No credential/path/signed URL in a public profile. Readiness/enablement is computed
by the core using configuration/runtime/license status, not hardcoded ready.

Use the dataclasses/errors/context in `nativ_generation.contracts`; request/job
records otherwise use JSON-safe dictionaries. `normalize(request)` rejects unknown
or unsupported controls, applies only the selected profile defaults, preserves
manual prompt/lyrics and returns a JSON-safe accepted request. Common fields are
model, prompt, session_id, allow_remote, output_format and modality-specific fields.
Do not import model code while normalizing. Caller validates common fields too.

`job` includes `job_id`, `attempt_id`, `store_id`, `session_id`, `modality`,
`request` (accepted immutable parameters), `profile` (immutable public snapshot),
`provider_operation` (null or persisted ID/endpoint/account identity). Never use
changed global defaults to reinterpret a stored accepted request.

## Durable execution

`run(job, context)` executes in a dedicated scheduler thread. Before **actual**
local generation or a remote generation POST call `context.begin_dispatch()`.
After remote acceptance call `context.record_operation(id, endpoint_kind)` before
polling. Context persists even if cancellation arrived during POST. Polling and
download retries are safe only for the same operation; `reconcile` never creates
one. `context.wait(seconds)` is cancellation-aware; provider polling >=5 s where
required. `emit(stage, progress=None, **details)` is genuine stage-scoped progress,
not success. Results include a candidate path, measured/effective parameters and
safe metadata, never a public success state. Write only to `context.output_dir`.

`GenerationError(... definitive=False)` identifies an ambiguous submission;
transport exceptions are conservatively unknown when durable dispatch exists but
no operation ID was recorded. Definitive validated rejection may be failed.
`GenerationCancelled` is a local observation event, not proof remote work stopped.
`CancellationResult` explicitly distinguishes confirmation and terminal outcome.
Known completed Runway operations never DELETE; serialize locally and disclose
the remaining provider-side race. No replay on HTTP timeout/restart.

Credentials come only from `services.credentials(profile['id'])`; private named
profile settings from `services.configuration`. Use injectable bounded transport.
Workers receive no unrelated cloud secrets. `services.worker.run(runtime_id,
payload, context) -> ProviderResult` owns the actual child lifecycle; worker payload
contains adapter operation/request and trusted prepared paths, not public arbitrary
paths. Local workers implement line-delimited JSON on stdin/stdout: handshake,
stage/progress/operation, result/error. Root supplies supervisor/lease wrapper.

## Video-owned hooks

`nativ_video.inputs` provides safe original import and deterministic transform
functions. Core pins originals/recipe and calls materialization before dispatch;
the context's input map gives the derivative `path`, SHA256 and metadata keyed by
input_id. `context.input_path(id)` is the only provider input-path source.
`nativ_video.media.probe(path, accepted, codec_paths)` validates real output and
returns JSON-safe metadata (root canonical importer calls it). No original moves
or DB changes in feature modules. Freeze transform v1: orientation first, sRGB,
normalized top-left crop, explicit contain/alpha background, no stretch. Shared
golden fixtures and canonical derivative preview prove Swift/provider parity.

## Testing and reporting

Provider contract tests must run without weights/network/credentials. Test actual
request mapping and meaningful failures, not just constants. Runtime execution and
installation are real implementations, separately labelled unqualified pending
stronger-Mac inference. No heavy model downloads or paid calls on this host.
Only root changes shared files, project membership, Git commits/branches or CI.
Full worker reports go to ignored `build/validation/*-implementation-report.md`.
