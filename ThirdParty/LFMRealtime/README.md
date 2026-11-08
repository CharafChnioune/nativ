# LFM realtime helper

`runtime-manifest.json` pins llama.cpp v0.9.0 at
`cd959bae99ff4bed22bef2604f45241c09bbb8c8`, the native-only browser-Origin
rejection patch, and official LiquidAI GGUF revision
`d508b88f08a5b4286f2d2805a6a8d69a0ff44c72`. Q8_0 and Q4_K_M both use the
same Q8_0 audio/vision projector. All three SHA256 hashes and exact sizes are
required. No binary or weights belong in git.

Build on Apple silicon with CMake, Xcode command-line tools and Metal support:

```sh
python3 scripts/build_lfm_realtime_runtime.py --download-models
python3 scripts/build_lfm_realtime_runtime.py --verify-only
```

Outputs: `build/lfm-realtime/runtime/bin/llama-server`, models under
`build/lfm-realtime/models/`, and helper hash/dependency evidence under
`build/lfm-realtime/runtime/build-evidence.json`. Compile concurrency defaults to
three, capped at four. Downloads are opt-in. The server is not started by this
build script. The static helper embeds Metal source and links only macOS system
libraries. Do not replace the app's existing MLX runtime.

`reject-browser-origins.patch` rejects every request with a nonempty Origin
before HTTP/WebSocket routing. Native clients send no Origin and authenticate
using an ephemeral local API key. Bind only to `127.0.0.1`, use port `0`, disable
web UI, agents and tools, strip inherited `LLAMA_*` settings, and own only the
exact child process. See [runtime and probe notes](../../Docs/development/translation-runtime.md).

The runtime is MIT licensed. The model is **LFM Open License v1.0**, with a
commercial-use revenue threshold and redistribution/attribution conditions;
it is not the runtime's MIT license. Exact upstream license texts are retained
in `licenses/`. Weights are downloaded separately, never shipped implicitly.
No additional NOTICE file was present in the pinned model repository listing.
