# Video runtime qualification

Status on 2026-11-09: **no local profile is hardware-qualified**. Network-free
fixtures cover API mapping, parameter validation, immutable image transforms,
worker public calls, media constraints, failure/retrieval/account recovery and
setup integrity gates. On an M3 Max (128 GB) both mlx-video profiles were
installed and repaired from a relocated candidate app; the first real Wan clip
exposed the VAE-decode memory problem described below. LTX-2.3 and Wan rerun
results are pending (TODO below); motion quality, signed nested code and paid
cloud access remain unproven.

## Reproducible inputs and pins

The three manifests in `PythonDistribution/VideoRuntimes/`
(`ltx-2.3-distilled-local.json`, `wan2.2-ti2v-5b-q8-local.json`,
`minimax-h3-local.json`) record exact source/model revisions, component sizes,
dependency lock hashes, worker protocol and license gates. Every local runtime
uses a separate arm64 Python 3.12 prefix. `locks/*.txt` are fully version/hash
locked resolution candidates generated with uv for macOS 14+; uv is a developer
build tool, never an installed-app dependency.

LTX-2.3 and Wan2.2 share runtime `mlx-video-87db56a`: Blaizzy/mlx-video
`87db56a51758fefb748a359b90a5283bb8ba4837`, source archive SHA256
`174adddb7797125438adbf1996f5c344cfbc6187ac0b49d58615e302302a7a45`
(22,144,111 bytes). Only its `mlx_video` package is copied into the runtime; PyPI
"mlx-video" is unrelated. `locks/mlx-video-macos-arm64.txt` (SHA256
`8a5f220082a2a5e48a0c522cd9857a3f68e61cbbbfd6c3064eb3b8ecc97e1d98`) is the exact
non-dev closure of its upstream `uv.lock` for darwin arm64/CPython 3.12 (MLX
0.31.1, mlx-vlm 0.4.0, Transformers 5.3.0). It is compiled with
`MACOSX_DEPLOYMENT_TARGET=14.0` because MLX wheels need macOS 14, and every pin
also resolves wheels-only (`--no-build`). H3 keeps its own
`locks/h3-macos-arm64.txt` for mlx-vlm 0.7.12.

LTX-2.3 and Wan2.2 have no gated component; their setup needs no Hugging Face
account. Every file is pinned by repository, revision, byte size and SHA256:

| Profile | Components | Bytes |
| --- | --- | --- |
| `ltx-2.3-distilled-local` | `prince-canuma/LTX-2.3-distilled@65b104b9387fb173d8e4b92fc5effc47625baf2a` (18-shard transformer, text projections, x2 spatial upscaler, video VAE encoder/decoder, audio VAE decoder, vocoder) plus `mlx-community/gemma-3-12b-it-bf16@b8b9b412cb795bd6115fdce8c9a0ef0d1664db3a` under `text_encoder/` | 73,525,357,557 |
| `wan2.2-ti2v-5b-q8-local` | `Anes1032/Wan2.2-TI2V-5B-mlx-q8@9624723c94ddf509832555c45e223a035baa7d1c` (Q8 transformer, group 64; UMT5 encoder bf16; VAE fp32) plus the `google/umt5-xxl@66cb9e7e85526fe440a945569e42c72fb6cbc0ad` tokenizer under `tokenizer/` | 19,601,659,733 |

mlx-video hardcodes the hub id `google/umt5-xxl`; the offline worker serves it
from the pinned copy. Fully pinned inventories skip hub resolution, and a file or
resolved digest that disagrees with its pin fails setup. The gated dgrauet
LTX-2.5 Q8/Q4 profiles were removed because mlx-video main has no LTX-2.5 (only
the open PR #52). H3 is a real public-API adapter tested only with fixtures; its
empty checkpoint allowlist and separate-license gate prevent an accidental
restricted download.

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
Offline flags and an empty private `HF_HOME` prevent an upstream loader from a
mutable implicit download or an unpinned cached model. Every job uses a fresh
process, so model and H3 workflow/step caches cannot contaminate the next job.
Stdout carries only the protocol; library output, tracebacks and mlx-video's own
stage timings are appended to the private attempt `worker.log`. Completion is only
a candidate; the canonical importer must probe it before a durable success event.

## Wan VAE decode and the MLX cache limit

The first real Wan2.2 clip on the M3 Max (832×480, 81 frames, 50 steps) ran all
diffusion steps at a stable 8.9 GB footprint (about 19 s per step, 16 minutes).
mlx-video's tiled VAE decode then grew the worker to 99 GB, and the MemoryGuard
stopped it on `system_swap_growth`. A decode-only probe on the installed VAE with
the real 832×480×81 latent shape (not a generation):

| Decode setting | MLX active | Process footprint | Decode time |
| --- | --- | --- | --- |
| auto tiling, no cache limit | 36.7 GB | 105.2 GB | 66 s |
| auto tiling, `mx.set_cache_limit(4 GiB)` | 40.7 GB | 37.7 GB | 75 s |
| aggressive tiling, 4 GiB limit | 8.6 GB | 11.6 GB | 140 s |
| spatial-only tiling | 46.2 GB | not recorded | not recorded |
| temporal-only tiling | 57.0 GB | not recorded | not recorded |

Freed Metal buffers stay in MLX's cache, so the footprint far exceeded active
memory. Since `29cbf1f4` the video workers and the MLX music workers call
`mx.set_cache_limit(4 << 30)` when MLX is available; tiling and output are
unchanged, decode time +14%. Workers report `mlx_peak_memory_bytes` and
`max_rss_bytes` in result metadata; neither is the process footprint.

## M3 Max results — TODO

TODO: LTX-2.3 clips and the Wan2.2 rerun with the 4 GiB cache limit. No result is
recorded here yet.

## Stronger Mac acceptance procedure

Use a documented Apple Silicon Mac with sufficient headroom; no RAM floor is
claimed from parameter count, checkpoint bytes or CUDA figures. Record chip, RAM,
macOS, display/player version, source/lock/model hashes, pipeline/quantization and
encoder/signing identity. Perform setup/load separately from inference/decode/save.
The initial profiles are one-shot workers, so repeated jobs still incur model load;
do not label their timing as a warm resident pipeline. LTX and Wan report a single
`generating` stage; take load/denoise/decode timings from `worker.log`.

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

- [mlx-video pinned source](https://github.com/Blaizzy/mlx-video/tree/87db56a51758fefb748a359b90a5283bb8ba4837) for LTX-2.3 and Wan2.2; [LTX-2.3 weights license](https://github.com/Lightricks/LTX-2/blob/4f521619ae0029e8fbb64d555030c2b121a33b4f/LICENSE-2)
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
