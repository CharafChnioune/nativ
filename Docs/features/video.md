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

No local video profile is qualified. Installed code or a passing
contract fixture does not establish that a model fits memory or makes good
motion. Local profiles remain unavailable until complete setup, license review
and explicit experimental opt-in; a supported default requires recorded hardware
qualification. No model is downloaded on workspace opening or catalogue requests.
External execution requires both an enabled named account and
`allow_remote: true` for that individual job. There is no fallback.

| Profile | Runtime/checkpoint | Initial candidate | Audio |
| --- | --- | --- | --- |
| `ltx-2.3-distilled-local` | mlx-video `87db56a51758fefb748a359b90a5283bb8ba4837`; `prince-canuma/LTX-2.3-distilled` `65b104b9387fb173d8e4b92fc5effc47625baf2a` with `mlx-community/gemma-3-12b-it-bf16` text encoder `b8b9b412cb795bd6115fdce8c9a0ef0d1664db3a` | 704×448 / 448×704, 97 frames, 24 FPS, distilled pipeline | Native stereo 48 kHz |
| `wan2.2-ti2v-5b-q8-local` | Same mlx-video pin; `Anes1032/Wan2.2-TI2V-5B-mlx-q8` `9624723c94ddf509832555c45e223a035baa7d1c` with `google/umt5-xxl` tokenizer `66cb9e7e85526fe440a945569e42c72fb6cbc0ad` | 832×480 / 480×832, 81 frames, 24 FPS, 50 steps, shift 3 | Silent |
| `minimax-h3-local` | Public mlx-vlm 0.7.12, source `7230940302cbe602054650f18a2f77db945bc57a` | Fixture-only advanced adapter, 124 frames / 24 FPS | Joint stereo 32 kHz |
| `ltx-2-5-fast-cloud`, `ltx-2-5-pro-cloud` | Official LTX V2, with separate 2.3 profiles | Curated 720p landscape/portrait, 24 FPS, explicit supported durations | Native or silent |
| `runway-gen4.5` | Official Runway API version `2024-11-06` | 1280:720 or 720:1280; I2V square also offered; 2–10 seconds | Silent; FPS/frame count provider-determined |

Wan's Q8 covers only its transformer (group 64); the UMT5 text encoder stays bf16
and the VAE fp32. Checkpoint bytes are not peak memory requirements. Video and MLX
music workers cap MLX's buffer cache at 4 GiB: without it, Wan's tiled VAE decode
reached a 105 GB footprint in a decode-only probe on an M3 Max (see the
qualification document).
The distilled LTX pipeline uses a 64-pixel spatial grid and an `8n+1` temporal
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
use a standalone bundled Python prefix. LTX-2.3 and Wan2.2 share one MLX runtime
pin, Blaizzy/mlx-video `87db56a`, copied from its hash-pinned source archive and
installed from its upstream-tested lock (MLX 0.31.1, mlx-vlm 0.4.0, Transformers
5.3.0); each profile gets its own runtime folder. Runtime archives and nested
interpreters, MLX dylibs and managed encoders still require release
signing/qualification.
There is no user Homebrew, uv, pip-upgrade or externally started UI requirement.

LTX-2.3 and Wan2.2 have no gated component, so their setup needs no Hugging Face
account. Every LTX-2.3, Gemma 3, Wan2.2 and UMT5 tokenizer file is pinned by
repository, revision, byte size and SHA256: about 73.5 GB for LTX-2.3 (including
the Gemma 3 12B text encoder) and 19.6 GB for Wan2.2. Only explicit setup
downloads the listed components, checks free space, resumes bounded partial files
and verifies SHA256; a file that does not match its pin fails setup. Workers run
offline with an empty private `HF_HOME`, so library fallbacks cannot load
unpinned cached models. The gated LTX-2.5 Q8/Q4 profiles were removed: mlx-video
main has no LTX-2.5 pipeline.

The managed codec dependency is FFmpeg 9.0.2 with the pinned x264 build, including
source/notices. The worker environment puts that binary first on `PATH` and in
`IMAGEIO_FFMPEG_EXE`, so mlx-video's encoding and LTX audio muxing never use a user
ffmpeg. No soundtrack resampling is used to conceal timing errors.
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
