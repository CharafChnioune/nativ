# Music runtime qualification

Status on 2026-11-08: implementation and offline contract validation; **no local provider is release-qualified**. No music weights, paid generations or remote GPU generations were run on the available 16 GB Mac. Vendor benchmark claims are not Nativ measurements. Base Chat/Images/translation dependencies were not changed by the Music workstream.

| Runtime | Exact source/package | Checkpoint revision | Qualification |
| --- | --- | --- | --- |
| ACE-Step 1.5 | `ca1e85fe9430179831e6bc6be790c332190a3866`, isolated Python 3.12; resolved dependency lock including Transformers 4.57.6 | `ACE-Step/Ace-Step1.5@19671f406d603126926c1b7e2adc169acbcade22`; optional `ACE-Step/acestep-5Hz-lm-0.6B@148d8ea0225bdab342ee1ae3a354275ccd60ca80` | Unqualified; initial thinking/LM disabled |
| MiniMax-Music3 MLX | mlx-audio 0.6.4; music implementation hashes match `ecd43b9f5af55982f4e1bd810d7b60cbc3dfae23`; MLX 0.32.4, Transformers 5.15.1 | `mlx-community/MiniMax-Music3-mxfp8@d00a12c3c7f80eb66379dd02dd0f30ed0ce2d96e` | Experimental |
| Stable Small Music MLX | official `790793b89ddceea612be9ce42ff6830d18f6fa57`; isolated pure MLX | `stabilityai/stable-audio-3-small-music@8bdfb53c6b0fbc62113cd571fd37373efe15fa14`; optimized components `30cb2644da54bfa63275d1bc7f1fa67fc718680f` | Unqualified |

Machine-readable manifests include model/source sizes and SHA-256, worker protocol 1, platform/architecture, lock digests, license identifiers, explicit sampling and an empty `qualified_hardware` list. Initial admission floors are conservative setup guards, not measured support claims. ACE/Stable dependency locks were resolved for Darwin arm64/Python 3.12; this proves dependency resolution, not installation, native ABI, signing or generated audio quality. ACE's upstream dependency graph includes training/UI packages. The builder pins its setuptools/wheel bootstrap before locked non-isolated source builds. These builds need execution in a clean release builder.

ACE uses its native Python API, not its web UI or raw path-based HTTP endpoint. Its generic upstream preflight expects an unused 1.7B LM. The worker instead validates the three accepted components and uses a private symlinked checkpoint view plus model code from the pinned runtime, with mutable download/sync hooks disabled. Fixed seed uses both the seed and `use_random_seed=false`; caption/metadata rewrite and LM thinking are false. Verify this narrow adaptation with actual audio before qualification.

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

The original 20-case corpus contains eight ACE, six MiniMax MLX and six Stable Small Music cases, including supplied English/Dutch lyrics where vocal generation is under evaluation. It grants no language/quality qualification by itself.

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

`quality-review.json` requires a named human to listen and assess complete audio, pitch, timing, style and lyrics. Cancellation/coexistence/signed-runtime/cleanup gates remain mandatory. The automated report always keeps `qualified=false` and never promotes a catalog entry. Only a separately reviewed human qualification record can do that. No `--run-models` invocation was executed on the 16 GB development host; only dry-run and mocked control-service tests ran.

The hosted Lyria 3.5 contract was rechecked against the current Gemini Interactions reference: `lyria-3.5` is an allowed model, `store` enables later retrieval, and GET `/v1beta/interactions/{id}` returns stored steps. The adapter explicitly stores interactions, discloses provider storage, and reconciles only through GET with the same API revision. Completed/pending/failed/wrong-ID fixtures cover this path; eligible-account live POST/GET remains unverified. Older Google Cloud Lyria stateless constraints are not assumed to govern this current Gemini 3.5 contract.
