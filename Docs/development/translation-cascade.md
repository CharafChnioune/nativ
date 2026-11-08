# Local translation cascade

The alternative route has three independently selected components: recognition, text translation, and speech synthesis. It never replaces a selected model, switches to a cloud endpoint, or chooses Apple speech automatically. LFM3 direct and LFM3 two-pass remain the preferred routes. Every cascade profile is experimental; none is human-qualified.

## Implemented path

`CascadedTranslationBackend` is an injectable actor in `NativTranslationKit`. It accepts owned mono 16 kHz PCM16 input and seals one bounded utterance. Recognition produces a real source transcript; the translator receives a fresh interpreter request with empty tools and thinking disabled. A complete translation is committed before the selected renderer emits playable audio. Late recognition, translation or audio from an invalidated generation cannot update a later generation. An independent response deadline stops a provider that ignores cooperative cancellation.

The host reuses Nativ's authenticated MLX runtime through local audio/chat clients. It validates literal loopback endpoints, disables system proxies and persistent response/cookie caches, and rejects redirects to another origin. The installed-model inventory is checked before starting the runtime. Absolute snapshot paths prevent implicit selection of another model. Whisper uses `task=transcribe`; arbitrary-language translation is the Gemma stage. The translation adapter currently accepts Gemma 4 variants; selecting a different family produces an explicit error.

Chatterbox auxiliary loading uses the opt-in `nativ_local_only` request field. A request-scoped `ContextVar` wraps the actual synchronous MLX TTS worker; Hub snapshot/file downloads in that worker are forced to `local_files_only=True`. Other model-management requests retain their own behavior. A read-only capability preflight sends no speech and rejects older runtimes before they can ignore the field. Missing auxiliary assets produce a visible error, never an implicit download. The runtime builder packages and hashes the overlay so a stale cached runtime cannot satisfy the new build signature.

Captions-only skips speech provider preparation. Choosing spoken output validates the target language separately from recognition and text translation. The automatic language-direction mode is not qualified and is rejected by this cascade contract.

## Providers and claims

| Stage | Adapter | Current evidence and restriction |
| --- | --- | --- |
| Recognition | Local Whisper | Documented tokenizer language table; turbo used only for transcription. The pinned turbo source snapshot loaded successfully after verified processor preparation. No human accuracy qualification. |
| Translation | Local Gemma 4 | Candidate languages under the family multilingual claim; no individual language pair qualified. Under the measured background load, E4B and E2B model loading reached critical OS pressure. |
| Speech | LFM3 `/tts` | Actual FLOAT32 PCM stream, using response format metadata and the shared transport budget. Speech language list is distinct from the model's text language list. Technical NL/EN transport checks do not qualify voice fidelity. |
| Speech | Chatterbox | Actual complete WAV response from MLX Audio, with explicit `lang_code` and a permitted reference recording. This adapter does not provide model streaming. Maximum complete output phrase: 12 seconds, with a 16 MB WAV parsing guard; a longer result fails visibly and asks for a shorter phrase. |
| Speech | Apple | Extra manually selected, installed voice matching the target language. No implicit voice choice or fallback. PCM is routed through Nativ's shared playback path. No perceptual qualification. |

Chatterbox's full phrase result is a separate bounded batch buffer. The shared two-second budget bounds downstream audio transport; it does not claim the batch inference result itself occupies only two seconds. Chatterbox's documented languages in the inspected adapter are Arabic, Danish, German, Greek, English, Spanish, Finnish, French, Hebrew, Hindi, Italian, Japanese, Korean, Malay, Dutch, Norwegian, Polish, Portuguese, Russian, Swedish, Swahili, Turkish, and Chinese. None inherits Dutch–English qualification.

The default Chatterbox candidate is multilingual-v3, not the English turbo model. Offline prerequisites include tokenizer JSON, multilingual Cangjie data, the separate S3 tokenizer snapshot, and a readable reference under 20 MB. Missing prerequisites cause a visible preparation error. The batch adapter was compiled and contract-tested; real Chatterbox synthesis/listening is still an open gate.

## Preparation and model pins

Exact model/file pins are recorded in `ThirdParty/TranslationCascade/model-manifest.json`. The preferred cascade trial used Whisper turbo revision `a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb` and Gemma E4B 4-bit revision `475b9088d29754a3379866cf5aeb6b41acd313c2`. E2B 4-bit revision `238767527555cb75a05732a84dff5d6ba0dd6809` was an explicitly selected smaller experiment, never an automatic replacement.

The source Whisper snapshot lacks required processor files. The explicit preparation action downloads the nine pinned OpenAI processor files at `41f01f3fe87f28c78e2fbf8b568835947dd65ed9`; byte lengths and SHA-256 are verified before atomic installation. The source weight/configuration hashes and exact revision are verified too. A shared disk-space reservation covers the downloads. Cancellation removes temporary state; preparation preserves the original model snapshot. Opening the page or starting an unprepared cascade does not download these assets.

An actual preparation test downloaded and verified the files, reopened the prepared model, and checked the source snapshot remained unchanged. The optional test requires `NATIV_CASCADE_WHISPER_SOURCE` and `NATIV_CASCADE_ASSET_CACHE`; without them it explicitly skips the artifact-download integration check.

## Measurements on 8 November 2026

Hardware: Apple M5, 16 GiB unified memory. Built Python runtime: Python 3.12.13, MLX 0.32.4, MLX-VLM 0.7.12, MLX-Audio 0.6.4, Transformers 5.15.1. These are the built runtime versions, not the older installed application's versions.

The probe used the same two original synthetic NL/EN WAV fixtures as the Omni technical comparison. It used offline model loading, captured no microphone, and played no audio. Results are in `scripts/benchmarks/live_translation/cascade-evidence.json`.

| Trial | Observed result |
| --- | --- |
| Whisper + E4B + Omni Q8 | Aborted after 15.63 s by an early free-memory-percentage guard. That guard does not establish actual memory pressure or a hardware fit limit. |
| Whisper + E4B captions, early guard | Aborted after 5.94 s by the same inconclusive guard. |
| Whisper + E4B captions, corrected OS-pressure guard | OS pressure 1 → 4 during Gemma loading; stopped after 3.78 s. Initial system swap 18,559.94 MiB; observed increase 786.12 MiB. |
| Whisper + E2B captions, corrected OS-pressure guard | OS pressure 1 → 4 during Gemma loading; stopped after 3.18 s. Initial system swap 18,447.25 MiB; observed increase 480.31 MiB. |

Whisper loaded; neither corrected trial reached both loaded models. No cascade turn completed, so there are no measured cascade translation-quality, caption-latency, speech-latency, p50/p95, or endurance results. All probe-owned processes were stopped. The high pre-existing swap and other application load prevent a universal claim that this profile cannot fit a 16 GB Mac. The failed safe-load trials do prevent qualification under the measured conditions. The heavier E2B + Omni Q4 trial was not started after the E2B caption load failed.

The current guard checks actual `kern.memorystatus_vm_pressure_level`, stops on critical pressure, stops after more than 2 GiB additional swap, limits sampled combined RSS to 10.5 GiB, and bounds runtime. Free percentage is diagnostic only. RSS and MLX allocator statistics are separate observations; neither alone accounts for total unified memory.

These probes called `mlx_vlm.load` directly. Nativ's managed-server overlay also batches text-model tensor evaluation in 64 MiB groups. The probe did not exercise that server loading path, which may change peak loading pressure; therefore these results are not a completed host-server fit test.

The 10.5 GiB RSS limit belongs to this 16 GiB development-machine probe and is configurable through `--max-rss-gib`; it is not a product eligibility rule. The application supports resource assessment on both 16 GB and 128 GB Macs. It has no blanket 16 GB cascade prohibition, and these measurements are not presented as 128 GB results. Smaller models or Q4 require an explicit user selection.

## Reproduction and tests

Use the built Nativ Python interpreter and verified snapshots, not an unrelated environment. Example, with fixture and model paths prepared under `build/`:

```sh
python3 scripts/benchmarks/live_translation/cascade_probe.py \
  --python build/NativDevelopmentDerivedData/Build/Products/Debug/NativServerKit.framework/Resources/mlx-vlm-server/python/bin/python3 \
  --gemma build/translation-cascade/hf-cache/models--mlx-community--gemma-4-e4b-it-4bit/snapshots/475b9088d29754a3379866cf5aeb6b41acd313c2 \
  --whisper build/translation-cascade/whisper-prepared/a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb \
  --fixtures build/lfm-realtime/probes/q8-fixed \
  --output build/translation-cascade/recheck --captions --timeout 180
```

Do not overlap this with Xcode builds or other benchmark model loads. Each run needs a fresh output directory. Removing `--captions` runs the real Omni speech stage. `--variant E2B --omni-quantization Q4_K_M` explicitly selects the smaller experiment and requires the matching pinned Gemma snapshot.

Deterministic coverage includes source/target capability separation, ordered stage delivery, late cancellation, response deadline despite an uncooperative recognizer, PCM ordering/12-second input bound, tool-markup rejection before speech, captions without TTS, WAV format/truncation/nonfinite validation, request language/task/reference fields, loopback/redirect/proxy restrictions, and Whisper preparation integrity/cancellation.

Offline-policy tests cover missing assets, scope reset on failure, unrelated-thread isolation, and old-runtime rejection before speech input is sent. With `NATIV_CASCADE_RUNTIME_CHECK=1` and the built Python interpreter, the real MLX request model and synchronous TTS worker plus the FastAPI capability route were tested without loading weights. The integration test confirms the opt-in survives request parsing and is enforced at the model-load call; it does not claim a successful Chatterbox voice render.

Human qualification remains separate: original tester-recorded sentences in both directions, spoken-output meaning/numbers/negation, naturalness/prosody/emotional intent, user acceptance of the main voice, 100 warm measurements, ten cold starts, 30-minute endurance, and audio-device/system-audio behavior. No adapter metadata substitutes for these gates.
