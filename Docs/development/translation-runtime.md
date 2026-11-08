# Local LFM realtime runtime

The pinned runtime can stream real translated-text/audio events and TTS audio on
this Mac. **No Dutch/English provider is qualified as a default.** Synthetic
protocol probes exposed translation failures; they cannot substitute for a
competent bilingual review, conversational measurements or acoustic testing.
The native feature must expose experimental capability honestly and keep an
explicit provider choice. No cloud fallback is part of this runtime.

## Reproducible installation

The manifest is [`ThirdParty/LFMRealtime/runtime-manifest.json`](../../ThirdParty/LFMRealtime/runtime-manifest.json).
Builds and all large artifacts live under ignored `build/lfm-realtime/`.

```sh
python3 scripts/build_lfm_realtime_runtime.py --download-models
python3 scripts/build_lfm_realtime_runtime.py --verify-only
python3 -m unittest discover -s scripts/tests -p test_lfm_realtime_runtime.py
```

The helper is `build/lfm-realtime/runtime/bin/llama-server`. The build script
compiles llama.cpp v0.9.0 at `cd959bae99ff4bed22bef2604f45241c09bbb8c8` for
arm64/Metal, applies a hash-pinned native-Origin patch, embeds the Metal source,
uses static project libraries and rejects unbundled Homebrew/rpath libraries.
CMake and Xcode command-line tools are build prerequisites. This helper has no
Python inference dependency and does not replace the existing MLX server.

Models are official `LiquidAI/LFM3-Omni-2B-GGUF` revision
`d508b88f08a5b4286f2d2805a6a8d69a0ff44c72`:

| Artifact | Exact bytes | Use |
| --- | ---: | --- |
| LFM3-Omni-2B-Q8_0.gguf | 1,846,240,768 | 8-bit backbone |
| LFM3-Omni-2B-Q4_K_M.gguf | 1,099,630,080 | smaller backbone |
| mmproj-LFM3-Omni-2B-Q8_0.gguf | 506,842,528 | matching shared audio/vision projector/codec |

All three were downloaded and checked against upstream LFS SHA256/size metadata.
A backbone alone is an incomplete installation. The script verifies local files,
uses a `.partial` download and renames only after integrity success. These file
sizes are not runtime memory estimates. The model license and MIT runtime
license are retained verbatim, with hashes/provenance in the manifest. LFM1.0
has its own commercial-use and redistribution conditions.

The original Python requirements specified `mlx-vlm>=0.7.10`; the final build's
observed versions are pinned below. LFM's documented MLX floor and vendor language
lists alone do not qualify streaming or a Dutch voice. The helper is independent
of the Python inference runtime.

## Actual transport contract

Use `--reasoning off`, one resident model, `--host 127.0.0.1 --port 0`, and an
4096-token context in the native host and endurance harness (the initial spike
also exercised 8192). The OS chooses the
port, which the host reads from the owned child's listening line. Disable the
web UI and agent/tool surfaces; sanitize inherited `LLAMA_*` environment before
setting a fresh per-process secret. Pass credentials through the environment or
a private file, never command-line text or telemetry. Only terminate the exact
owned child. Bound readiness and response waits and remove key files on exit.

The additional pinned patch rejects any nonempty `Origin` before routing,
including WebSocket upgrades. Native clients send no Origin. Upstream CORS
configuration alone only omits permissive response headers; it does not reject a
WebSocket handshake. HTTP and WS still require the local bearer credential.

A `/v1/realtime` connection owns one model slot. Read formats from
`session.created`; the actual tested model announced input **16000 Hz PCM16 mono**
and output **24000 Hz PCM16 mono**, little-endian. Configure `session.type`,
interpreter `instructions`, `output_modalities:["text","audio"]`, `tools:[]`
and `tool_choice:"none"` before the first message/audio. Fixed direction appends
`Input is Dutch. Translate only to English.` or its inverse using validated names.
Audio goes through `input_audio_buffer.append`, then
`input_audio_buffer.commit` and `response.create`. Output uses
`response.output_text.delta`, `response.output_audio.delta` and `response.done`.
No source transcript is invented. The backend answers committed turns; this is
not full-duplex interpreting or server-owned automatic endpoint detection.

Instructions cannot change after first input. `input_audio_buffer.clear` does
not undo prefilled audio; truncation is unavailable. On language change or
discard/interruption, cancel, invalidate the native generation, close the
socket, and open a fresh session on the still-resident model. Backend cancellation
completion is not a guarantee of immediate local silence: flush playback and
ignore all stale callbacks immediately. Restore only bounded committed text,
never discarded audio or unfinished generated content.

For same-model two-pass, request text only, wait for its final translation,
**close its WebSocket to release the single slot**, then call `/tts` with
`input`, target `lang`, `stream:true`, `response_format:"pcm"`. The actual content
type is `audio/pcm;rate=24000;encoding=float;bits=32`. This is FLOAT32 little-endian
mono, a different decoder from WS PCM16. Real chunks arrive before EOF. A
successful HTTP response to `lang:nl` does not prove Dutch pronunciation or that
spoken meaning matches the committed translation. No cloned reference voice is
introduced by this task.

## Technical evidence and unrun release gates

Commands, 60 original text fixtures and probe semantics are in
[`scripts/benchmarks/live_translation/README.md`](../../scripts/benchmarks/live_translation/README.md).
The technical matrix uses original synthetic Xander/Samantha `say` fixtures,
never personal audio, and never starts a microphone or playback. It stores
synthetic outputs under ignored build paths, explicitly labels them synthetic,
checks authentication/origins, and closes/reset slots between stages. Its
commit-to-network timings exclude endpointing, acoustic capture, playback
buffering and audible output. Concurrent baseline compilation creates resource
contention, so no performance qualification follows from these runs.

The report and compact checked-in evidence retain every technical failure.
Initial automatic-direction Q8 probes mistranslated a protected time, repeated
English instead of translating into Dutch, and generated tool-shaped text in
text-only mode despite no tools. Generated markup is untrusted text and is
never executed. Fixed-direction experiments are recorded separately; successful
streaming does not reverse any fidelity failure or qualify a provider.

Unrun gates: all 60 consenting human recordings and bilingual text/spoken review;
>=90% meaning-preserved on that set with zero protected number/negation errors;
automatic-direction/code-switch/noise qualification; >=100 warm turns and >=10
cold starts in the full native audio path; acoustic end-of-clause to first-audible and caption p50/p95; local
Stop-to-silence <=150 ms; 30-minute conversation/context rollover with no growing
queue/memory or duplicates; microphone/system-audio/headphone/AEC behavior;
source/output overlap and forced-boundary testing; and native packaging/signing.
No p95 is calculated from isolated probes. Cascade C is a separate provider
qualification task and is not silently substituted here. Apple speech is an
optional separately selected provider, never the default inferred from this
spike.

The separate [technical endurance report](technical-performance.md) records
process-cold starts and paced synthetic network turns. Those results do not
replace the full-app acoustic and human qualification gates above.

Primary sources: [Liquid llama.cpp deployment](https://docs.liquid.ai/deployment/on-device/llama-cpp),
[the pinned model](https://huggingface.co/LiquidAI/LFM3-Omni-2B-GGUF/tree/d508b88f08a5b4286f2d2805a6a8d69a0ff44c72),
[the pinned server protocol](https://github.com/ggml-org/llama.cpp/blob/cd959bae99ff4bed22bef2604f45241c09bbb8c8/tools/server/README.md).

## Python runtime measured alongside the helper

The existing MLX runtime remains separate. The pristine checkout's open-ended constraints
resolved to Python3.12.13, mlx-vlm0.7.12, mlx-audio0.6.4, mlx/Metal0.32.4 and
transformers5.15.1 on 2026-11-08. These directly observed versions are now exact requirements
in `PythonDistribution/Requirements/mlx-vlm-server-macos-arm64.txt`, along with the resolved
cryptography50.0.2, hf-xet1.8.0, huggingface_hub1.33.0 and starlette1.10.0. This prevents a
future package resolution from changing the measured adapters without review. These pins
are reproducibility candidates, not proof of a qualified interpreting profile. The separately
installed Nativ0.4.4 app used different package versions and was neither modified nor used
as the final build's runtime evidence.
