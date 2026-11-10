# Media runtime packaging and image control responsiveness

The base runtime builder recursively packages `nativ_generation`, `nativ_music` and `nativ_video` under standalone Python's site-packages. It copies Music/Video runtime managers, exact locks, manifests and license resources beside the Python prefix. Fingerprints include relative filenames and SHA-256; edits and removals invalidate reuse. Copying replaces each managed package tree, so removed source files cannot survive an upgrade. Bytecode/cache directories are excluded. Verification compares actual packaged membership/content and imports lightweight catalog/contracts from the isolated packaged interpreter.

## Managed codecs

Build the pinned codec candidate before a full application/release build:

```sh
python3 PythonDistribution/CodecRuntime/manage.py build --jobs 4
python3 PythonDistribution/CodecRuntime/manage.py smoke --output dist/codec-runtime
NATIV_REQUIRE_MANAGED_CODECS=YES make xcode-build
```

The base builder also accepts `--require-codecs`. Missing prepared codecs then fail clearly. A normal source-only build may package setup metadata while leaving video unavailable; an installed app must never fall back to a Homebrew encoder. Build setup belongs in CI/release preparation, not application launch.

`CodecRuntime/manifest.json` pins FFmpeg 9.0.2 release source and x264 commit `b35605ace3ddf7c1a5d67a2eb553f034aef41d55`, with exact source sizes/SHA-256. The builder uses Xcode's clang, static FFmpeg/libx264 and a fixed one-library pkg-config shim. It disables automatic dependency discovery/network protocols. FFmpeg/FFprobe link only system libraries/frameworks. No Homebrew runtime library is required. The selected profile encodes H.264/yuv420p and AAC and decodes/probes generated MP4 and supported audio inputs; it does not advertise an MP3 encoder.

The managed candidate is `dist/codec-runtime`. The bundle layout is:

```text
mlx-vlm-server/
  python/
  MusicRuntimes/                 # manager, pins, locks, notices
  VideoRuntimes/
  Patches/                      # reviewed source guard and image helper
  CodecRuntime/
    manage.py
    manifest.json
    managed/
      bin/ffmpeg
      bin/ffprobe
      receipt.json
      licenses/
      sources/                  # exact archives, build script, config logs
```

`CodecRuntime/manage.py:codec_paths(resources_root)` verifies this exact managed location, runtime ID and binary SHA-256 and returns absolute `ffmpeg`/`ffprobe` paths. It never searches PATH. The common service passes those paths to workers and media validators; workers may prepend only that managed bin directory to their filtered PATH for upstream code that launches `ffmpeg` by name.

The source build runs a real small RGB/PCM → H.264/AAC → decoded frames/audio smoke check before reporting success. On the development M5/macOS 26.6, FFmpeg 9.0.2 and x264 compiled, a 24-frame 96×64 24 fps MP4 with stereo 44.1 kHz AAC encoded and decoded, representative frames 0/11/23 validated, and 88,200 decoded audio samples were finite. The Video workstream separately validated a 97-frame 704×448 timestamp/audio marker fixture. These are codec fixtures, not generative-model qualification. FFmpeg 9 removed `-vsync`; validators use `-fps_mode passthrough`.

The GPL-enabled codec executable build has separate licensing from Nativ. It includes original FFmpeg/x264 source archives, license texts, NOTICE, build/configuration script, compiler/SDK identity and system-linked-library inventory. Binary releases must retain this corresponding-source material and notices. No inference weights are bundled here.

Nested signing mutates Mach-O bytes. The framework resource build phase refreshes codec hashes only after successful embedded signing, preserving original `build_files` provenance. The final app/framework resource signature authenticates the refreshed receipt. Packaged verification compares immutable source/build material, original build hashes and current binary hashes. A real ad-hoc signed-copy/strict-verify/restamp/locator smoke passed; owner-signed notarized distribution remains a release gate.

## Narrow image execution patch

The selected `mlx-vlm==0.7.12` wheel has synchronous model loading, generation/editing and output encoding inside async image routes. `Patches/manifest.json` guards its exact `mlx_vlm/server/openai.py` SHA-256 and the resulting patched digest. An unexpected wheel/source layout fails packaging and requires a new source review. The patch is idempotent for its known output; it does not maintain a general dependency fork.

The packaging transformation preserves both original routes, request parsing, authentication, DTOs, metrics, responses and error behavior. It lifts each complete blocking try/load/generate/encode/error-cleanup block into a synchronous helper and awaits a dedicated serial executor. An ASGI Request never crosses threads and an async handler is never passed to `to_thread`.

The installed module is `nativ_image_execution`. It owns one explicit MLX stream on one thread. A cross-process exclusive compute lease is acquired before submission and held through real execution and `mx.synchronize`, including after client cancellation. A conflicting image request returns retryable HTTP 409 before loading weights. Music info/status/events/cancel do not acquire this lease and stay responsive.

Root service integration calls `configure_admission(service.admission)` before scheduler start and excludes image routes/aliases from a competing global lease wrapper. Before a local media worker loads weights, `unload_idle_images()` runs the supported upstream image-cache unload functions on that same MLX owner thread while the scheduler already owns the exclusive lease. Native Translate's verified compute-preparation flow uses the same hook. `has_active_work()` reflects actual execution, surviving observer cancellation; `shutdown()`/`drain()` keep lifecycle cleanup ordered.

Deterministic tests prove responsiveness with slow execution, busy admission, unchanged attempt lease after cancelled observation, eventual lease release and preloaded-image cache unloading before the first image request. The patch was generated/compiled against the actual pinned wheel and packaged with all feature modules. Real Apple Silicon image generation/editing, model/cache replacement, sustained concurrent health latency and shutdown under MLX remain explicitly unqualified without model execution. Do not treat the deterministic worker fixture as that hardware evidence.

Primary references: [FFmpeg 9.0.2 sources](https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz), [x264 source pin](https://code.videolan.org/videolan/x264/-/tree/b35605ace3ddf7c1a5d67a2eb553f034aef41d55), [FFmpeg licensing](https://ffmpeg.org/legal.html), [MLX-VLM wheel metadata](https://pypi.org/project/mlx-vlm/0.7.12/).
