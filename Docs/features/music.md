# Music generation

Music uses the same durable generation service for native workspaces, Chat and API clients. The server owns jobs and original audio. A submitted job continues when a window closes or changes workspace, while that server remains running. Playback is explicit; completion never autoplays.

The provider catalog distinguishes the checkpoint, runtime, execution location and qualification. Installing a runtime or listing a model does not qualify its audio quality or memory use. Local music runs on MLX only: MiniMax MLX is experimental, Stable Small is unqualified and ACE-Step is disabled. Both MLX profiles generated real songs on an M3 Max (128 GB); without the human listening review that qualifies neither them nor smaller Macs. See [runtime qualification](../development/music-runtime-qualification.md).

| Profile | Execution | Supported controls | Original output |
| --- | --- | --- | --- |
| ACE-Step 1.5 Turbo | Disabled in this build: its runtime runs PyTorch on MPS (only the DiT on MLX) and mlx-audio has no ACE-Step. Listed with that reason; install/repair are refused | — | — |
| MiniMax-Music3 MLX MXFP8 | Separate owned process using the pinned music-capable base environment | Supplied lyrics or explicit `[instrumental]`, 1–60 second ceiling, seed; fixed 30 steps | WAV, 44.1 kHz stereo |
| Stable Audio 3 Small Music | Isolated official pure MLX process | Instrumental descriptions, 1–120 seconds, seed; fixed post-trained 8-step profile/CFG 1; progressive model release | WAV, 44.1 kHz stereo |
| MiniMax-Music3 Remote GPU | Explicit configured SGLang-Omni service | Lyrics/description, seed, 1–30 second acoustic-frame ceiling | WAV, 32 kHz stereo |
| MiniMax Music 3 cloud | Explicit eligible existing paid account | Description, manual lyrics or native instrumental option; no hard duration/seed controls | MP3/WAV, 44.1 kHz stereo |
| Lyria 3.5 | Explicit Google hosted account | Description and supplied lyrics; duration/instrumental intent in prompt; no hard duration/seed controls | MP3, 44.1 kHz stereo |
| Stable Audio 3.0 cloud | Explicit Stability hosted account | Instrumental prompt intent, 1–380 second target, seed | MP3/WAV, 44.1 kHz stereo |

Durations, musical structure and lyric adherence remain generative. A requested ceiling is not a promise of an exact length. Small Music has no verified lyric-conditioned singing contract. No profile exposes reference audio, editing, continuation or stems.

## Preparation

The native setup flow calls managed runtime installation and model preparation. It must show licenses, download sizes, available space and qualification before enabling a profile. Models are never fetched by opening Music, importing the API or launching a worker.

Pinned inventories total approximately 13.87 GB for MiniMax MXFP8 and 1.705 GB for Stable Small Music; with their runtimes the installs took 15.0 GB and 2.2 GB on the M3 Max. These are download sizes, not peak memory claims: the measured peak process footprint there was 34–46 GB for MiniMax and 2.3–2.8 GB for Stable, before workers capped MLX's buffer cache at 4 GiB (`29cbf1f4`); MiniMax has not been re-measured since. Downloads verify SHA-256 and keep resumable partial files; cancellation does not erase existing songs.

The builder integration is under `PythonDistribution/MusicRuntimes/manage.py`. Release engineers can explicitly prepare a candidate with the app's standalone Python prefix:

```sh
python3 PythonDistribution/MusicRuntimes/manage.py build \
  --runtime stable-audio-3-mlx-790793b --python-prefix /path/to/bundled/python \
  --destination /path/to/new/runtime --accept-licenses
python3 PythonDistribution/MusicRuntimes/manage.py models \
  --runtime stable-audio-3-mlx-790793b --destination /path/to/new/checkpoints \
  --accept-licenses
```

These are reproducible builder commands, not a requirement to install Homebrew, uv or a terminal server on an end user's Mac. A release builder still needs to execute isolated dependency installation, bundled imports, relocation, nested signing/notarization and real audio qualification. The installer never updates the base Nativ interpreter. Missing/gated files leave the profile unready.

Private named profile configuration supplies `model_path` for MiniMax and `model_path` plus `source_path` for Stable. Prepared directories carry a pinned `nativ-model.json` receipt. Workers verify every recorded component before loading. The host supplies worker interpreter paths; ordinary generation requests cannot choose paths or endpoints.

Each runtime keeps its own copy of the app's `nativ_generation` and `nativ_music` packages. After an app update that changes them, an installed profile shows as unavailable ("Repair this runtime: it holds worker code from another Nativ build."), a submit is refused with 409, and dispatch or recovery stops with `runtime_outdated`. Repair rebuilds the runtime without downloading models (13.1 s for MiniMax and 19.2 s for Stable on an M3 Max). A video-only update left the music runtimes valid.

Remote GPU configuration supplies an HTTPS `endpoint` pointing to the service root. Loopback HTTP requires explicit `allow_local_http=true`. A read-only health probe verifies `/health` and that `/v1/models` advertises `MiniMaxAI/MiniMax-Music3`. Cloud MiniMax supports the documented `https://api.minimax.io` and `https://api.minimax.cn` regions; credentials must match the selected region. New paid Music/Lyrics access closed on August 20, 2026; the adapter is for eligible existing accounts. Nativ does not enroll accounts or buy credit.

Vendor keys are private server configuration from the app's credential infrastructure, never generation fields. Hosted generation requires both an enabled configured profile and `allow_remote=true`. There is no paid fallback. Anyone holding the configured Nativ server key can use its enabled paid capabilities.

## Cancellation and recovery

Local cancellation is confirmed only after the owned worker/process group stops. Remote services in this catalog have no documented cancel operation; cancelling observation may leave generation and billing active. Uncertain POST outcomes are not retried. Known Stable Audio cloud operation IDs and stored Lyria interaction IDs can be retrieved again without creating a new generation. Lyria 3.5 explicitly requests `store=true` for this recovery path: the configured Google account stores the request and generated interaction under its provider retention terms. Nativ makes no zero-retention claim. A deliberate new request is required to try an unresolved non-queryable provider again.

Original bytes and measured media metadata are retained independently of waveform/export failures. An MP3 exported as WAV remains a conversion of the MP3 original. Exporting does not regenerate or upload a song. Reference, trash and restore operations use the canonical API.

## Attribution and coexistence

MiniMax-Music3 uses the MiniMax Community License. Stable models use Stability Community terms and T5Gemma/Gemma terms; their runtime code has separate MIT licensing. Pinned license texts and a distribution notice are in `PythonDistribution/MusicRuntimes/licenses`. The catalog exposes the required MiniMax-Music3 and Powered by Stability AI labels.

Local inference admission is shared with Chat, Images, STT/TTS and Live Translate. Queued songs do not load weights. Remote generation does not claim the Mac's inference lease. Music playback participates in microphone/audio coordination. Live Translate's LFM preference and manual Apple fallback remain separate from Music.

Primary contracts: [ACE-Step source](https://github.com/ace-step/ACE-Step-1.5/tree/ca1e85fe9430179831e6bc6be790c332190a3866), [MiniMax MLX source](https://github.com/Neywa-Labs/mlx-audio/tree/ecd43b9f5af55982f4e1bd810d7b60cbc3dfae23/mlx_audio/music), [Stable MLX source](https://github.com/Stability-AI/stable-audio-3/tree/790793b89ddceea612be9ce42ff6830d18f6fa57/optimized/mlx), [MiniMax cloud](https://platform.minimax.io/docs/api-reference/music-generation), [MiniMax GPU](https://platform.minimax.io/docs/guides/local-deploy-music-3), [Lyria](https://ai.google.dev/gemini-api/docs/music-generation), [Stable cloud](https://docs.stability.ai/api-reference/stable-audio/text-to-audio).
