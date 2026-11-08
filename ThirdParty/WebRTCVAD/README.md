# Native WebRTC VAD

libfvad source subset pinned by runtime-manifest.json. No model, speech recognizer, network service or hidden ASR. Sources/headers are unchanged; retain LICENSE, PATENTS and AUTHORS.

Compile src/**/*.c as C11 with include/ and src/ header search paths, module name WebRTCVAD. The Swift wrapper uses 16 kHz mono PCM16, 20 ms windows, mode 2. Initial endpoint silence is 400 ms and must be tuned with bilingual acoustic measurements.
