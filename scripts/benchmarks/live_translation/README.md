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
one resident model, one slot, an 8192-token context, an OS-assigned loopback port
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
