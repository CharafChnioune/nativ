# Music runtime qualification

Status on 2026-11-10: **no local provider is release-qualified**. Local music is MLX-only. On an M3 Max (128 GB) both MLX profiles were installed from a relocated ad-hoc candidate and ran the 20-case corpus through the canonical API (MiniMax once, Stable twice: 30 real generations); see [M3 Max results](#m3-max-results). The human listening review is deliberately open, so nothing passes automatically, and these results do not cover 16 GB Macs. No paid or remote GPU generations were run. Vendor benchmark claims are not Nativ measurements. Base Chat/Images/translation dependencies were not changed by the Music workstream.

| Runtime | Exact source/package | Checkpoint revision | Qualification |
| --- | --- | --- | --- |
| ACE-Step 1.5 | `ca1e85fe9430179831e6bc6be790c332190a3866`, isolated Python 3.12; resolved dependency lock including Transformers 4.57.6 | `ACE-Step/Ace-Step1.5@19671f406d603126926c1b7e2adc169acbcade22`; optional `ACE-Step/acestep-5Hz-lm-0.6B@148d8ea0225bdab342ee1ae3a354275ccd60ca80` | Disabled: PyTorch on MPS with an MLX DiT, not in mlx-audio |
| MiniMax-Music3 MLX | mlx-audio 0.6.4; music implementation hashes match `ecd43b9f5af55982f4e1bd810d7b60cbc3dfae23`; MLX 0.32.4, Transformers 5.15.1 | `mlx-community/MiniMax-Music3-mxfp8@d00a12c3c7f80eb66379dd02dd0f30ed0ce2d96e` | Experimental; 10 real runs on M3 Max |
| Stable Small Music MLX | official `790793b89ddceea612be9ce42ff6830d18f6fa57`; isolated pure MLX | `stabilityai/stable-audio-3-small-music@8bdfb53c6b0fbc62113cd571fd37373efe15fa14`; optimized components `30cb2644da54bfa63275d1bc7f1fa67fc718680f` | Unqualified; 20 real runs on M3 Max |

Machine-readable manifests include model/source sizes and SHA-256, worker protocol 1, platform/architecture, lock digests, license identifiers, explicit sampling and an empty `qualified_hardware` list. Initial admission floors are conservative setup guards, not measured support claims. ACE/Stable dependency locks were resolved for Darwin arm64/Python 3.12. MiniMax and Stable have since been built, installed and run from a relocated ad-hoc candidate on the M3 Max; that is not release signing or audio-quality evidence. ACE's upstream dependency graph includes training/UI packages. The builder pins its setuptools/wheel bootstrap before locked non-isolated source builds. These builds need execution in a clean release builder.

ACE-Step is disabled in this build (owner decision: local music is MLX-only). Its runtime runs PyTorch on MPS with only an MLX DiT, and mlx-audio has no ACE-Step. The profile stays listed with that reason; runtime install/repair return 409 and `prepare_models` refuses it before any download. The adapter code is kept: ACE uses its native Python API, not its web UI or raw path-based HTTP endpoint. Its generic upstream preflight expects an unused 1.7B LM. The worker instead validates the three accepted components and uses a private symlinked checkpoint view plus model code from the pinned runtime, with mutable download/sync hooks disabled. Fixed seed uses both the seed and `use_random_seed=false`; caption/metadata rewrite and LM thinking are false. Verify this narrow adaptation with actual audio before qualification.

MiniMax calls the real `mlx_audio.music` model loader and generation iterator with only text, lyrics, duration, steps and seed. Instrumental maps to `[instrumental]`. Exactly one finite non-empty 44.1 kHz stereo result is required; no playable streaming claim is made. Package versions and music source hashes are checked before inference.

Stable executes the official MLX pipeline inside the owned worker with a pinned local-only component resolver. Only Small Music/T5Gemma/SAME-S decoder are needed for initial text generation; the editing-only encoder is not downloaded. CFG remains 1 for the selected post-trained profile; 8 steps, FP16 DiT/FP32 decoder and progressive model release remain explicit. Small is capped at 120 seconds regardless of longer vendor benchmark examples.

## Reproducible offline checks

```sh
python3 -m unittest discover -s scripts/tests -p 'test_music*.py' -v
python3 -m compileall -q PythonDistribution/Overlay/nativ_music PythonDistribution/MusicRuntimes
```

Tests cover strict capabilities and normalized recovery, exact manual lyrics, fixed ACE seed mode, MiniMax instrumental mapping/output contract, Stable control gating, official hosted request/response fixtures, uncertain POST failure with no retry, retained Stable operation IDs/reconciliation without POST, safe archive extraction, license/cancel download gates and receipt integrity. They do not certify acoustic quality or actual runtime installation.

## Stronger Mac / release builder checklist

- Build each isolated candidate from its exact lock and pinned source; verify imports from outside the checkout, no Homebrew PATH and no optional model/network access at startup.
- Verify signed/notarized nested interpreters, dylibs, worker modules and native codecs; test runtime relocation and upgrade from the actual app bundle.
- Prepare models after license acceptance; test low disk, truncated transfers, cancellation/resume, corruption, repair and missing/gated files. Record compressed+expanded free-space needs.
- Run at least 20 local generations across profiles with at least five per released provider. Include instrumental/vocals, English/Dutch manual lyrics if advertised, 30/60 second drafts, seed repetition and Stable's 120 second boundary.
- Record chip/RAM, OS, exact manifests, cold setup/start versus warm generation, stage latency, actual duration/rate/channels, peak unified memory/swap, thermal state, time to first playable output, quality/listening notes and complete/finite audio.
- Exercise queue/preparation/inference/finalization cancellation, helper death, server SIGKILL/immediate restart, sleep/wake, disk-full and output-device loss. Verify no worker/FD/waveform growth over 20 sequential jobs.
- Verify shared inference admission and memory unloading with Chat, image generation/editing, STT/TTS and active Live Translate; status/events/cancel/health must remain responsive.
- Verify API-created songs in two native windows and Artifacts, reconnect/relaunch/Resume, seek/export, references/trash/restore and upgrade preservation.
- Run a small real test per hosted/GPU adapter only with an eligible account and explicit paid-test budget. Verify actual returned codecs/rates and cancellation/uncertain billing semantics. Never store keys or signed URLs in evidence.

Publish measurements and quality failures alongside any qualification update. Keep untested profiles unqualified/experimental and avoid enabling long-duration or editing capabilities based solely on model names or CLI flags.

## Reproducible stronger-Mac runner

The 20-case corpus contains ten MiniMax MLX and ten Stable Small Music original cases, each with one same-seed repeat (`minimax-07-soul-repeat`, `stable-07-soul-repeat`); four MiniMax cases carry supplied English/Dutch lyrics. It grants no language/quality qualification by itself.

```sh
# Default: zero network calls and no models. Review the frozen corpus first.
python3 scripts/benchmarks/music/qualify.py --output build/validation/music-qa

# On the stronger Mac with explicitly prepared local profiles and a running
# canonical Nativ server. Supply only the Nativ bearer token through environment.
export NATIV_TOKEN='<your Nativ server token>'
python3 scripts/benchmarks/music/qualify.py --run-models \
  --base-url http://127.0.0.1:8181 --output build/validation/music-qa
```

Use the same output directory to restart observation. A single ledger owner freezes corpus, catalog revisions, server/store identity and idempotency keys before dispatch, with file+directory fsync. Existing job IDs are polled; a lost acceptance is resolved by the unique frozen request title/request match using GET listing. It never repeats a generation POST after durable dispatch intent. Recovery-held jobs receive Resume on the same identity. A changed store/profile, unresolved lookup or interrupted generation requires operator review; it never silently creates another job. A deliberately new qualification run uses a new output directory.

The runner rejects hosted/remote-GPU catalog deployments and sends `allow_remote=false`. `--profiles` can select a local subset for preliminary evidence, but the complete release matrix still requires at least 20 cases and at least five for each released provider. Downloads use bearer/store binding, byte limits and canonical SHA-256; original files remain available for listening. `report.json` includes exact runtime manifests, accepted jobs, real decoded metadata, submission/observed-stage times and the latest bounded client-observed status latency sample. RAM/swap snapshots are explicitly observations of the runner host/system, including other workloads; they are not per-model peak memory or server measurements when the server is elsewhere.

`quality-review.json` requires a named human to listen and assess complete audio, pitch, timing, style and lyrics. Cancellation/coexistence/signed-runtime/cleanup gates remain mandatory. The automated report always keeps `qualified=false` and never promotes a catalog entry. Only a separately reviewed human qualification record can do that. On the 16 GB development host only dry-run and mocked control-service tests ran; the M3 Max results below are real model runs.

The hosted Lyria 3.5 contract was rechecked against the current Gemini Interactions reference: `lyria-3.5` is an allowed model, `store` enables later retrieval, and GET `/v1beta/interactions/{id}` returns stored steps. The adapter explicitly stores interactions, discloses provider storage, and reconciles only through GET with the same API revision. Completed/pending/failed/wrong-ID fixtures cover this path; eligible-account live POST/GET remains unverified. Older Google Cloud Lyria stateless constraints are not assumed to govern this current Gemini 3.5 contract.

## M3 Max results

Real model runs, not qualification. Apple M3 Max (16 cores, 128 GiB, macOS 27.2); the headless server of a relocated ad-hoc candidate app on 127.0.0.1:8181 with its bearer key and `allow_remote=false`. The corpus runs on 2026-11-09 predate `29cbf1f4`, so workers had no MLX cache limit. Per-case numbers are in [`media/evidence/m3-music-qualification.json`](media/evidence/m3-music-qualification.json); installs, repairs, cancellation, scheduling and shared job flows in [`media/evidence/m3-runtime-lifecycle.json`](media/evidence/m3-runtime-lifecycle.json).

| | MiniMax-Music3 MXFP8 | Stable Small Music |
| --- | --- | --- |
| Runs | 10 cases once; all succeeded | 10 cases twice; all succeeded |
| Generation | 118–389 s per song, about 6× slower than real time | First job 3.86 s; warm 1.75 s per 30 s, 2.6 s per 60 s, 4.3 s per 120 s |
| Duration | Ceiling: instrumental 19.7–29.2 s; lyric cases reached the requested 30 s or 60 s | Exact 30/60/120 s |
| Output | WAV 44.1 kHz stereo 16-bit; peak −6.8 to −0.1 dBFS; no clipped samples | WAV 44.1 kHz stereo 16-bit; 3 of 10 cases clip (712, 364 and 50 samples) |
| Repeatability | Same-seed repeat byte-identical | Both runs byte-identical per case; same-seed repeat identical |
| Memory | MLX active peak 22.3–28.5 GB; process peak footprint 34–46 GB; worker max RSS 13.2 GB; no swap | Process peak footprint 2.3–2.8 GB; worker max RSS 1.0–1.4 GB; no swap, normal pressure |
| Install (download and runtime) | 257 s; generation root +15.0 GB | 52.5 s; generation root +2.2 GB |

- Every job is a fresh worker, so these times include model load. MiniMax load and inference share the `preparing` stage and mlx-audio prints no timings; Stable writes its own stage timings to `worker.log`.
- MiniMax's footprint exceeds its MLX active peak because of MLX's buffer cache, and `max_rss` underestimates it. The 4 GiB cache limit was not re-measured for music.
- Stable clipping comes from raw model output above full scale (peak up to 1.289 in its log), written as int16. Its script resets MLX's peak counter, so the worker cannot report an MLX peak.
- Three MiniMax cancellations during generation reached `cancelled` 0.06 s after the request (worker exit 0.08 s where measured) with no leftover worker. A second job waited 139.7 s in `queued` while the first ran; a concurrent runtime setup was refused with `compute_busy`.
- During music inference `/health` answered at p50 1.8 ms, p95 628 ms, max 1.37 s; music `server-state` and `generations` at p95 3.7 ms.
- Shared job flows on candidate `6f4ae0c3` with 10 s Stable clips: replaying the same Idempotency-Key returned the same job, and a changed body under it returned 409 `idempotency_conflict`; two clients saw the same terminal state and asset; a worker SIGKILL ended the job as `failed`/`worker_failed` within 0.11 s and the next job succeeded; 20 sequential jobs all succeeded in 38 s with server RSS +0.4 MB, open files 56 before and after and no worker left; while an external process held the Translate flock, a submitted job stayed `queued` without a worker and succeeded after the release (observed 1.99 s later).
- Each runtime keeps its own copy of `nativ_generation` and `nativ_music`. After an app update that changes them the profile shows "Repair this runtime: it holds worker code from another Nativ build.", a submit is refused with 409, and dispatch or recovery stops with `runtime_outdated`. Repair without download took 13.1 s (MiniMax) and 19.2 s (Stable) on `5288300c`; a `nativ_video`-only change left both music runtimes valid.
- The server's MemoryGuard, which stops a job on swap growth or critical memory pressure, parsed `sysctl`/`memory_pressure` output in the inherited locale until `b79f6803`. Under a decimal-comma locale such as `nl_NL.UTF-8` (`used = 619,69M`) it read nothing, so those stops were silently off whenever the server inherited such a locale from the app; it now runs both commands with `LC_ALL=C`.
- Deliberately open: the human listening review (`quality-review.json`; owner: not now). Not covered by these runs: MiniMax with the cache limit, contention with real Chat/Images/STT/TTS/Live Translate sessions, sleep/wake and 16 GB hardware. Both profiles stay experimental/unqualified.
