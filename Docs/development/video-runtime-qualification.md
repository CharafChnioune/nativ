# Video runtime qualification

Status on 2026-11-08: **no local profile is hardware-qualified**. Network-free
fixtures cover API mapping, parameter validation, immutable image transforms,
worker public calls, media constraints, failure/retrieval/account recovery and
setup integrity gates. They do not prove actual MLX model output, memory fit,
AVFoundation playback, motion quality, signed nested code or paid cloud access.

## Reproducible inputs and pins

The four manifests in `PythonDistribution/VideoRuntimes/` record exact source/model
revisions, selected component sizes, dependency lock hashes, worker protocol and
license gates. Every local runtime uses a separate arm64 Python 3.12 prefix.
`locks/*.txt` are fully version/hash locked resolution candidates generated with
uv for macOS 14+; uv is a developer build tool, never an installed-app dependency.
Only inference dependencies are selected. LTX source-only packages are copied
from the hash-pinned 0.18.0 archive, excluding training extras.

The published mlx-gen 0.38.0 wheel SHA256 is
`bfb5a50420b3ea29388510ea5eed9657c648162180d2a7f4860e98d53770619a`.
All **745** Python files in its `mflux`/`mlxgen` packages were byte-compared to
`99fb94dd3eaa9dd1931cd3cd8eae1ae3e20f2ef3`, with zero differences/unmatched files.
This permits the 1.6 MB wheel instead of downloading the repository's 1.075 GB
archive of documentation pictures. No checkpoint or paid request was used.

LTX gated public metadata currently masks LFS digests and unauthenticated resolve
returns 401 GatedRepo. Its manifests intentionally contain unresolved hashes and
cannot download until `resolve_model_inventory` succeeds with authorized access
to every exact component. Q8/Q4 are independent licenses/inventories/qualification.
H3 is a real public-API adapter tested only with fixtures; its empty checkpoint
allowlist and separate-license gate prevent an accidental restricted download.

## Setup/repair API

`manage.prepare_models(manifest, destination, cancel_event, emit,
accepted_licenses=True, token=None)` performs bounded resume/download and complete
SHA256 verification, then atomically writes both a common model receipt and a
video-specific inventory receipt. A false/missing license acceptance, unresolved
hash, path escape, insufficient disk or cancellation stops setup. Existing valid
components are reused; only managed partials are touched.

`manage.build_runtime(manifest, destination, standalone_python_prefix,
cancel_event, emit)` builds a new candidate prefix without changing the base
Nativ environment. The builder verifies source/lock hashes, installs exact
requirements, copies inference code/overlay packages and writes an unqualified
receipt. The release pipeline must verify imports outside the checkout, nested
codesigning, managed FFmpeg 9.0.2/x264 execution and archive rollback before
shipping a ready runtime. Never use a user's Homebrew encoder.

The worker is `python -m nativ_video.workers --runtime-id ID`. It announces
`{type: handshake, protocol: 1, worker: nativ-video, runtime_id: ID}` before reading
one bounded JSON envelope. Only prepared model and derivative paths enter it.
Offline flags prevent an upstream loader from doing a mutable implicit download.
Every job uses a fresh process; Wan freed denoisers and H3 workflow/step caches
cannot contaminate the next job. Completion is only a candidate; the canonical
importer must probe it before a durable success event.

## Stronger Mac acceptance procedure

Use a documented Apple Silicon Mac with sufficient headroom; no RAM floor is
claimed from parameter count, checkpoint bytes or CUDA figures. Record chip, RAM,
macOS, display/player version, source/lock/model hashes, pipeline/quantization and
encoder/signing identity. Perform setup/load separately from inference/decode/save.
The initial profiles are one-shot workers, so repeated jobs still incur model load;
do not label their timing as a warm resident pipeline.

The local-only API harness is
`python3 scripts/benchmarks/video/qualify.py --help`. Its default prints the
corpus/requirements and never submits work. `--run-models` is deliberate local
execution, uses the actual canonical API/admission boundary and writes evidence
under a selected output directory. It never enables cloud or downloads weights.
Choose a fully prepared profile that the server has explicitly enabled for
experimental qualification. Keep chat/Images/voice/translation contention tests
separate and record actual latency percentiles, not requested targets.

For each released local provider, complete at least four clips: T2V and first-frame
I2V, landscape and portrait, seeds 42/123. Use native LTX sound and silent Wan.
H3 needs a separate eligible license plus full partition/component qualification.
Manually review motion, subject/reference fidelity, black/corrupt/repeating frames,
speech/soundtrack correctness and temporal drift. Record first playable time,
load/generation/decode/encode/import stages, peak MLX allocation plus process RSS,
swap/pressure and repeated-run behavior. OS sampled RSS is not peak GPU memory.

Run the independent timestamp/marker fixture helper with the **managed** FFmpeg
binary, then validate with `nativ_video.media.probe` and AVFoundation. Check exact
frame count/FPS, first/middle/last decoded images, duration, stereo/sample rate,
AAC alignment, color/rotation, seek and export. Test missing/nonfinite/silent
requested audio, truncation, disk full, cancelled encoding and failed poster/cache.
A valid original must survive a thumbnail or export failure.

Additional release gates: worker cancellation at loading/denoise/decode/encode;
SIGKILL parent, immediate restart and no compute overlap; sleep/wake/pressure;
server health/status/cancel response during real Images generation/editing; no
players/observers after multi-window browsing; authenticated remote playback;
light/dark/narrow/portrait/reduced-motion screenshots; signing/notices/source
availability for the GPL x264/FFmpeg distribution. These remain unrun until actual
host/runtime evidence exists. Cloud live acceptance requires an existing eligible
account and separate explicit paid-test authorization/budget.

## Primary contracts verified

- [LTX pinned public pipeline](https://github.com/dgrauet/ltx-2-mlx/tree/747b30ef10e92a011e85b2aa0f6c4ee86ced5218)
- [Wan pinned application source](https://github.com/lpalbou/mlx-gen/tree/99fb94dd3eaa9dd1931cd3cd8eae1ae3e20f2ef3)
- [mlx-vlm H3 0.7.12](https://github.com/Blaizzy/mlx-vlm/tree/7230940302cbe602054650f18a2f77db945bc57a/mlx_vlm/models/minimax_h3)
- [LTX V2 lifecycle](https://docs.ltx.io/async-jobs), [LTX matrix](https://docs.ltx.io/models/ltx-2-5), [LTX uploads](https://docs.ltx.io/api-documentation/api-reference/upload/create-upload)
- [Runway versioned schema](https://docs.dev.runwayml.com/openapi.json), [outputs](https://docs.dev.runwayml.com/assets/outputs/), [pricing](https://docs.dev.runwayml.com/guides/pricing/)

## Shared compute admission implemented

The canonical server and native Translate use the same fork-scoped BSD flock at
`~/Library/Application Support/io.github.charafchnioune.nativ/compute-admission.lock`,
independent of the media data-root override. A separate
`NATIV_COMPUTE_LEASE_PATH` exists only for explicit standalone/test configuration.
Native children receive the actual locked descriptor as stdin, so app death cannot
release admission while a helper survives. The private cascade borrows that
inherited descriptor and does not open a second canonical generation store.

Host inference uses both HTTP/WebSocket admission and actual pinned 0.7.12 worker
hooks: continuous-batching load/active iterations, audio queue work, 3D executor
work and scoped thread-executor calls. A disconnected request does not release
capacity while its executor function continues. Images use their separate
qualified serial owner thread on the same admission lock. Idle-model purging
requires a verified native lease nonce plus existing server authentication, or a
scheduler that already holds the exclusive lease; live host/image work is never
unloaded. Paused Translate retains admission while its owned helper remains
resident; Stop releases it only after actual helper exit.

Evidence available: native Swift 6 compiled inherited-descriptor smoke; actual
packaged mlx-vlm 0.7.12 hook installation without model loading; network-free
background-thread disconnect/exclusion tests. Full native model contention,
acoustic cancellation, sleep/pressure and real model SIGKILL qualification remain
separate hardware gates.

The managed FFmpeg 9.0.2 build encoded and validated the independent timestamp/
stereo-marker fixture: 704×448, 97 frames, exact 24/1 FPS, 4.041667 seconds,
48 kHz stereo AAC, 388,000 finite decoded samples. First/middle/last frame samples
0/48/96 decoded successfully. This tests media plumbing, not generative quality.
The representative decode uses FFmpeg 9's `-fps_mode passthrough`; the removed
`-vsync` option is not used. A/V start/duration tolerance is explicitly one video
frame plus at most 1,024 AAC priming samples at the observed sample rate.
