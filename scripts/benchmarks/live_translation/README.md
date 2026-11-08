# Live translation technical and qualification probes

These scripts never activate a microphone and never play generated speech.
`fixture-manifest.json` contains 60 original source texts, 30 Dutch and 30
English, with draft reference translations and empty recording/reviewer fields.
A competent bilingual reviewer must approve references and meaning, protected
numbers/negations and generated speech separately. Noise tags require an actual
noise recording variant. Synthetic `say` output is excluded from human fidelity,
automatic-direction and acoustic qualification.

Prepare the helper/models and the small probe-only environment:

```sh
python3 scripts/build_lfm_realtime_runtime.py --download-models
python3 -m venv build/lfm-realtime/venv
build/lfm-realtime/venv/bin/python -m pip install -r scripts/benchmarks/live_translation/requirements.txt
build/lfm-realtime/venv/bin/python scripts/benchmarks/live_translation/run_matrix.py --quantization Q8_0 --output build/lfm-realtime/probes/q8-fixed
build/lfm-realtime/venv/bin/python scripts/benchmarks/live_translation/run_matrix.py --quantization Q4_K_M --output build/lfm-realtime/probes/q4-fixed
```

Run matrix commands serially on a 16 GB machine. Each starts one owned helper,
one resident model, one slot, a 4096-token context, an OS-assigned loopback port
and a fresh key file with mode 0600. It strips inherited `LLAMA_*` configuration,
waits at most 120 seconds for readiness, bounds responses, authenticates HTTP and
WebSocket access, checks browser Origin rejection, and terminates its exact child
in `finally`. It does not manage unrelated server processes. Synthetic content
is retained explicitly by this technical matrix under ignored `build/` only.
No model inference uses remote services. Downloading models does require network.

For a user-created recording, explicitly invoke the single probe (no recording
step is automated). Supply PCM16 mono WAV at the rate negotiated by the helper;
the tested LFM pin announces 16000 Hz input, 24000 Hz output. Unsupported formats
and turns over 12 seconds are rejected. Leave `--retain-content` absent to retain
only event types, counts, rates, errors and timings. Completion diagnostics drop generated content unless retention is explicit.
The matrix intentionally uses synthetic content and enables retention.

```sh
build/lfm-realtime/venv/bin/python scripts/benchmarks/live_translation/probe.py \
  --url http://127.0.0.1:PORT --key-file PRIVATE_KEY_FILE \
  --wav USER_CREATED_WAV --source-language nl --mode direct \
  --output build/lfm-realtime/probes/manual.json
```

Modes: `direct` (interleaved text/PCM16), `text`, `two-pass` (close WS before
streaming `/tts` on the same slot), `tts` (float32 PCM), `cancel` and `reset`.
The two-pass command needs explicit `--retain-content` to carry generated text
between passes; the normal native app should keep that text in memory. A new
WebSocket is used for each prompt/direction. This technical probe uses completed
fixture PCM chunks without pacing; timings are commit-to-network events and
exclude endpoint detection, capture resampling, jitter buffering, audible output
and local silence after cancellation. They are not end-to-end conversation
latency. A small sample never yields p95; aggregate p50/p95 only after at least
100 warm observations. Ten separately measured cold starts and a 30-minute
continuous-context/acoustic test remain independent qualification gates.

Failures are evidence. Tool-shaped generated text is never executed. A server
accepting `lang:nl` is not proof of understandable Dutch speech. Do not select an
unqualified provider as default from this matrix.

## Production prompt and guard contract

New managed-cascade measurements call the actual Swift implementation, rather than
copying its instructions into Python. Build this small driver after the Kit tests:

```sh
swift test --jobs 2
swiftc -I .build/out/Products/Debug -L .build/out/Products/Debug \
  -lNativTranslationKit -framework NaturalLanguage \
  scripts/benchmarks/live_translation/translation_contract.swift \
  -o build/translation-contract
python3 scripts/benchmarks/live_translation/managed_cascade_probe.py \
  --contract build/translation-contract --output build/translation-cascade/managed-recheck
```

The `.build/out` location above is the Xcode-backed SwiftPM layout used on the
reference Mac; use your SwiftPM products directory if different. The report records
the driver hash and actual prompt. A production content-guard rejection stops
before TTS and is a failed turn, never a corrected or qualified translation. The
original stored evidence predates this contract-driver option and retains its
original instructions and result. Run model probes serially, without Xcode builds.

For an updated Omni comparison with the same production prompt and the completed
text language check used before two-pass TTS, pass `--contract build/translation-contract`
to `run_matrix.py`. Direct-mode guard results are evaluated after the received
output in this Python probe; they cannot undo audio already emitted. This differs
from the native incremental guard and must not be advertised as native latency.
The default legacy mode remains available to reproduce earlier prompt behavior;
each matrix uses a new output directory and never replaces prior evidence.

Use `--fixtures EXISTING_FIXTURE_DIRECTORY` for a Q8/Q4 comparison on the exact
same `synthetic-nl.wav` and `synthetic-en.wav` recordings. The matrix copies those
WAV bytes before helper startup, validates PCM16 mono/16 kHz and the 12-second
limit, and records each original path and SHA-256. This option never invokes
`say`; omitting it retains legacy synthetic fixture creation. For example:

```sh
build/lfm-realtime/venv/bin/python scripts/benchmarks/live_translation/run_matrix.py \
  --quantization Q8_0 --fixtures build/lfm-realtime/probes/q8-fixed \
  --contract build/translation-contract --output build/lfm-realtime/probes/q8-production
build/lfm-realtime/venv/bin/python scripts/benchmarks/live_translation/run_matrix.py \
  --quantization Q4_K_M --fixtures build/lfm-realtime/probes/q8-fixed \
  --contract build/translation-contract --output build/lfm-realtime/probes/q4-production
```

The matrix requires normal measured OS memory pressure before starting a helper.
It shares `endurance.Guard`, samples real pressure/swap/owned-helper RSS, and
defaults to a maximum global swap increase of 1024 MiB. Critical pressure,
excessive swap growth or missing telemetry stops only its own child. Final
evidence retains resource samples, telemetry gaps and cleanup results. Probe,
output-guard and nested TTS failures produce a failed summary and nonzero exit;
successful transport remains explicitly unqualified.

## Endurance with the production contract

Pass the same `--contract` option to `endurance.py` to measure the production
instructions and output-language check. Build the driver against the exact Kit
revision under test before starting model work. If using the native validation
framework rather than SwiftPM products, link to its matching products directory:

```sh
translation_products=/absolute/path/to/validated/Build/Products/Debug
swiftc -F "$translation_products" -framework NativTranslationKit -framework NaturalLanguage \
  -Xlinker -rpath -Xlinker "$translation_products" \
  scripts/benchmarks/live_translation/translation_contract.swift \
  -o build/translation-contract
build/lfm-realtime/venv/bin/python scripts/benchmarks/live_translation/endurance.py \
  --contract build/translation-contract \
  --output build/lfm-realtime/probes/endurance-production \
  --duration 1800 --min-turns 100 --cold-starts 10 \
  --concurrent-activity "No concurrent app builds or model probes"
```

This is an explicit model run using existing synthetic fixtures, not part of the
light Python regression suite. Run it serially and describe actual concurrent
activity in the required argument. The driver is checked before helper startup;
its hash and actual instructions are recorded, and a changed driver aborts the
affected turn. Omitting `--contract` deliberately retains the legacy instructions
and labels output validation as unrun.

For two-pass turns the socket closes and the output guard runs before `/tts`;
rejected output never starts TTS. Direct-mode validation happens after received
audio and preserves that evidence, since it cannot undo emitted speech.
`first_text_seconds` measures an unvalidated network delta;
`validated_text_seconds` follows the guard. Two-pass audio timing includes the
external guard-process time. Neither mode measures capture, audible onset,
meaning, voice quality or native app latency.

Missing or invalid pressure/swap telemetry aborts the experiment. Final evidence
retains completed turns, telemetry gaps and the owned-helper shutdown receipt,
even if the last resource sample fails. A later valid sample cannot erase an
earlier monitoring gap or turn an aborted run into a completed one.
