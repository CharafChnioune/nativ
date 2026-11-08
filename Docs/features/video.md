# Video generation

Video is a native client of the same canonical generation service as Music.
The server owns one SQLite store (`Generations/jobs.sqlite`), store identity,
scheduler, immutable inputs, originals, usage reservations and trash state.
`nativ_video` supplies video-specific normalization, provider adapters, reference
transforms and decoded-media validation. It does not own another scheduler or DB.
Closing a workspace or disconnecting an API client does not cancel accepted work.
The embedded server belongs to the app process; an independent daemon is not
promised. A separately operated canonical Nativ server has its own lifetime.

## Current qualification

No local video profile is qualified on this Mac. Installed code or a passing
contract fixture does not establish that a model fits memory or makes good
motion. Local profiles remain unavailable until complete setup, license review
and explicit experimental opt-in; a supported default requires recorded hardware
qualification. No model is downloaded on workspace opening or catalogue requests.
External execution requires both an enabled named account and
`allow_remote: true` for that individual job. There is no fallback.

| Profile | Runtime/checkpoint | Initial candidate | Audio |
| --- | --- | --- | --- |
| `ltx-2.5-distilled-q8-local` | ltx-2-mlx 0.18.0, source `747b30ef10e92a011e85b2aa0f6c4ee86ced5218`; Q8 `746ca9aacb697d2c739f544d68b584214dedcc75` | 704×448 / 448×704, 97 frames, 24 FPS | Native stereo 48 kHz |
| `ltx-2.5-distilled-q4-local` | Same source; Q4 `e9a20add8c5937fcab635fb8e7a52926487a5776` | Separately unqualified Q4 profile | Native stereo 48 kHz |
| `wan2.2-ti2v-5b-q8-local` | mlx-gen 0.38.0 `99fb94dd3eaa9dd1931cd3cd8eae1ae3e20f2ef3`; conversion `6875952a110b6bdbcfc00d72b1d89a8e02ab0fc3` | 832×480 / 480×832, 81 frames, 24 FPS, 50 steps, shift 3 | Silent |
| `minimax-h3-local` | Public mlx-vlm 0.7.12, source `7230940302cbe602054650f18a2f77db945bc57a` | Fixture-only advanced adapter, 124 frames / 24 FPS | Joint stereo 32 kHz |
| `ltx-2-5-fast-cloud`, `ltx-2-5-pro-cloud` | Official LTX V2, with separate 2.3 profiles | Curated 720p landscape/portrait, 24 FPS, explicit supported durations | Native or silent |
| `runway-gen4.5` | Official Runway API version `2024-11-06` | 1280:720 or 720:1280; I2V square also offered; 2–10 seconds | Silent; FPS/frame count provider-determined |

The Wan conversion contains mixed quantization: its text encoder and VAE are not
made 8-bit by the profile name. Checkpoint bytes are not peak memory requirements.
LTX DistilledPipeline uses a two-stage 64-pixel spatial grid and `8n+1` temporal
grid. Its 97/24 candidate is approximately 4.042 seconds, not exactly four seconds.
Wan uses `4n+1`; H3 uses `17n+5`. Requests outside curated combinations are rejected,
never rounded. H3 T2VA and FL2VA use separate loaded workflows; fresh workers avoid
reusing a model after workflow/step changes. Ref2VA is outside this release.

H3's 2026-08-02 community license excludes the EU, UK, Republic of Korea and USA
from its default territorial grant. In excluded territories, a separate license
is required. The fixture-tested adapter does not grant weight access or rights;
its manifest deliberately has no executable checkpoint inventory.

## Installation, repair and data flow

The app's setup flow calls the managed preparation APIs in
`PythonDistribution/VideoRuntimes/manage.py`. Runtime dependencies are exact,
hashed, arm64/Python 3.12 locks isolated from the chat/image environment. Builders
use a standalone bundled Python prefix. Runtime archives and nested interpreters,
MLX dylibs and managed encoders still require release signing/qualification.
There is no user Homebrew, uv, pip-upgrade or externally started UI requirement.

LTX model access is gated. Public metadata exposes exact byte sizes but masks LFS
hashes. Setup must first resolve the immutable allowlist using an HF account that
has accepted all component terms; missing or masked hashes fail closed. The
resolver never fetches large weights. Only explicit setup downloads the listed
components, checks free space, resumes bounded partial files and verifies SHA256.
The selected Distilled pack excludes the dev transformer, distilled LoRA,
AV/diffusion VAE and temporal upscaler. It includes the default conv VAE, Gemma4
conditioner, connector, audio VAE/vocoder and spatial upscaler. Q4 is independent.

The managed codec dependency is FFmpeg 9.0.2 with the pinned x264 build, including
source/notices. LTX I2V retains the upstream CRF18/libx264 preprocessing and raw
runtime save behavior. No soundtrack resampling is used to conceal timing errors.
Cloud MP4 bytes are imported unchanged; the canonical importer verifies actual
frames, FPS, dimensions, SDR/color/rotation/aspect, sample rate/channels, decoded
first/middle/last frames, finite nonempty requested audio and timeline alignment.
A provider response or file extension alone cannot publish success.

Inputs are still PNG/JPEG/WebP, at most 25 MiB and 40 million decoded pixels, with
smaller provider limits applied before dispatch. Preserve original bytes privately.
Transform v1 applies EXIF orientation, ICC-to-sRGB conversion, normalized top-left
crop, aspect-preserving crop/contain and explicit alpha/background flattening.
Prepared RGB PNG has metadata removed and its own digest. Accepted jobs pin their
input IDs/recipes: replacing a draft file or deleting an Images original cannot
change that job. A pinned input cannot be deleted.

LTX uploads private derivatives using `/v1/upload`, forwards required signed PUT
headers unchanged and never sends provider bearer credentials to storage hosts.
Runway uses a private PNG data URI bounded by its 5 MiB encoded-URI limit. No public
image host is created. Provider keys remain private configuration, never manifests.

Cloud create is single-shot after a durable dispatch intent. Ambiguous acceptance
becomes `submission_unknown`; reconnect/restart never repeats the paid POST.
Polling waits at least five seconds, with bounded failure backoff. Retry Download
polls the saved operation and refreshes its existing output, never generates again.
Account/endpoint identity is immutable; same-account key rotation is allowed.
LTX cancellation remains unconfirmed. Runway cancellation rechecks state and never
DELETEs a known terminal task; completion can still race the final DELETE, so
physical stop/refund are never promised. Unresolved work retains its reservation.

See [the API](../api/video.md) and [qualification procedure](../development/video-runtime-qualification.md).
