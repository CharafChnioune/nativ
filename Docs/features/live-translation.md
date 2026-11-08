# Live Translate (fork preview)

This feature belongs to `CharafChnioune/nativ`, an independent fork of Nativ. It is
an experimental, local turn/phrase interpreter. No language pair or main voice is
human-qualified yet. Do not treat a working transport as proof of translation accuracy.

## Build and run locally

Use Apple silicon, macOS 26+, Xcode with its Metal toolchain, CMake and XcodeGen.
The build prepares the pinned native helper and the separate Python runtime;
speech-model weights are downloaded only by explicit preparation.

Use a checkout of the reviewed commit outside Desktop/Documents, for example under
`~/Library/Developer/nativ-live-translation`. Build from that checkout with DerivedData
outside those protected folders too. Moving only an already-built `.app` is insufficient:
its debug library search paths can still point back into Desktop.

```sh
cd "$HOME/Library/Developer/nativ-live-translation"
make xcode-build XCODE_DERIVED_DATA="$HOME/Library/Developer/NativLiveTranslationDerivedData"
security find-identity -v -p codesigning
# Replace the placeholder with your existing Apple Development identity/hash.
CODE_SIGN_IDENTITY="<Apple Development identity or hash>" \
  ./scripts/sign_macos_debug.sh "$HOME/Library/Developer/NativLiveTranslationDerivedData/Build/Products/Debug/Nativ.app"
./scripts/open_macos_debug.sh "$HOME/Library/Developer/NativLiveTranslationDerivedData/Build/Products/Debug/Nativ.app"
```

This is the local signing/launch route that produced the visible native preview on the
reference Mac. It uses an existing unlocked Apple Development certificate; it creates no
certificate or distribution identity. The launcher verifies the isolated fork bundle and
only restarts that exact build. It does not replace the separately installed official Nativ.

An ad-hoc alternative exists as `make xcode-local-run`, but it did not reach a visible UI
on the reference Mac (AMFI -423), so it is not a verified substitute. The original Desktop
build also encountered privacy prompts and a launch stall through absolute debug paths;
a source snapshot and rebuilt product outside Desktop resolved that launch obstacle.
No macOS privacy settings were changed. Developer ID, notarization, Sparkle signing keys,
feeds and update publication remain separate, unconfigured distribution gates.

## Start a session

1. Enable **Translate** in Extensions, then open its sidebar page. Enabling/opening
   only installs the UI and shortcut: it does not start capture, load a model or download weights.
2. Choose a fixed source/target direction. Dutch → English is initially displayed;
   swap explicitly for the other direction. Automatic bilingual direction is unavailable
   until it passes a separate recording-based assessment.
3. Choose **LFM3-Omni direct** or **LFM3-Omni two passes**, precision and output mode.
   Press **Prepare LFM3-Omni** to explicitly download and verify the exact weights plus
   matching audio projector. Progress represents downloaded bytes; verification is not a fake percentage.
4. Read the measured limitations and explicitly choose the experimental route.
   Select input/output devices and the headphones option only when actually using headphones.
5. Press **Start**. Pause/Resume, Stop, Mute and Interrupt Speech are separate actions.
   The default global toggle is Control+Option+T and can be changed in the page.

The implementation shares one app-scoped session across windows and the compact overlay.
Its lifecycle handlers stop capture on sleep, lock, disable, removal and quit; waking requires
explicit Resume. Multi-window and sleep/lock behavior still need physical acceptance tests.
A route, language, model or device change requires Resume with a fresh context.
Changing the overlay or shortcut alone preserves the session.

The preferred evaluation order remains direct Omni → same Omni in two passes →
explicitly chosen alternative. Neither tested Omni mode passed NL/EN quality checks,
so there is no qualified automatic default. The same resident model serves both passes;
the realtime socket closes before `/tts` acquires the single runtime slot.

## Audio and privacy

Microphone and system audio are separate sources. System audio uses ScreenCaptureKit,
excludes Nativ's output and the microphone, and defaults to captions. Speech output
for system audio requires explicitly selected headphones. Virtual microphone routing
is outside this version.

Headphones allow ordered capture while a response generates/plays. At most one turn
is active and one waits; excess input is marked incomplete, not silently omitted.
Speaker mode pauses the microphone while translating/speaking to avoid feedback.
It is a half-duplex fallback, not acoustic echo cancellation or full-duplex interpreting.
Interrupt Speech invalidates old output and resets context; ordinary new speech does
not automatically interrupt the previous response.

Audio remains in memory. There is no automatic recording, conversation history,
clipboard insertion or export. Copy/Export saves only explicitly completed text on request.
The UI retains at most 200 turns. A complete retry segment expires after 30 seconds.
Provider errors and missed input are visible; repeat incomplete speech instead of assuming
that the transcript is continuous. Diagnostics contain timings/versions, not conversation content.

Model/tokenizer preparation needs network access. Inference uses authenticated local
loopback services. The translation adapters reject off-device endpoints and redirects.
No automatic cloud or Apple fallback is configured.

## Other local models and voices

The cascade independently selects recognition, translation and speech. The initial
profile is Whisper large-v3-turbo → Gemma 4 E4B → LFM3-Omni TTS. Prepare MLX model
weights in Models and use **Prepare Whisper tokenizer** for the pinned processor files
missing from the official MLX conversion. Preparation does not change the source snapshot.

The E4B load trials hit critical macOS memory pressure on the reference 16 GB Mac
under its existing background workload before translation completed. This is a measurement
on that machine, not a universal memory-size ban. Nativ reads the actual Mac's memory and
current pressure, whether it has 16 GB, 128 GB or another capacity. Weight-size planning
reserves 20% as a heuristic and cannot predict activation peaks or other apps' needs.
Critical pressure pauses work; different precision/components remain explicit experimental
choices. No model is replaced silently and a 16 GB result does not qualify a 128 GB setup.

Chatterbox is optional and generates a complete phrase before playback. It is not a
streaming provider. Its multilingual model, tokenizer and a permitted reference recording
must be available locally. A bounded batch result is distinct from the streaming transport
budget; long phrases can be refused. Target language support is checked for the chosen model. A stock reference voice and
integrated preparation of every auxiliary asset are not provided yet; missing local
prerequisites produce a visible error.

Apple system voices are an explicitly selected extra speech renderer within the cascade.
They are never the preferred translation route or an automatic fallback. Installed voice
languages and voices vary by Mac; an explicit matching voice is required.

## Evidence and limits

LFM3 speech and text language lists differ: Dutch is documented for speech, but is absent
from the published text list. Recognition, text translation and target speech are tracked
separately. Documented availability does not establish tested or qualified interpreting.

The Q8/Q4 synthetic probes showed a critical 3:30 → 4:30 error and English output when
Dutch was requested. Two passes did not reliably resolve direction/meaning. These are
failed quality observations, not a qualified fallback recommendation.

There are no claimed acoustic p50/p95 values, 100-warm-turn qualification or 30-minute
endurance pass. The technical loopback run reached 38 warm turns and ten separate
process-cold starts, with the OS file cache retained. It aborted after 413 seconds when
a system-swap-growth guard fired under concurrent workload; this is not a completed
endurance or cold-user-start qualification. No complete real cascade turn was demonstrated. The 60 original fixture texts in
[`scripts/benchmarks/live_translation`](../../scripts/benchmarks/live_translation/README.md)
are ready for new recordings by the owner/tester. Each direction needs at least 30 rated
turns, meaning and actual spoken-output review, critical number/negation checks, naturalness,
prosody and emotional intent ratings, and owner acceptance of the main voice.

The actual native dark page was opened without capture or preparation. It showed LFM3
direct/Q8 with experimental consent unchecked; the cascade exposed independent component
menus, Chatterbox's full-phrase/reference requirement and an explicit Apple voice choice.
Selecting system audio defaulted to captions without requesting permission or starting capture.
The LFM3 direct choice was restored afterward.

![Native Translate page, idle with experimental consent unchecked](../development/images/translate-native-dark.png)

![Independent cascade choices and Chatterbox limitations](../development/images/translate-cascade-dark.png)

The [UI inspection](../development/live-translation-ui.md) records the scenarios and
limitations. These images verify the idle page only and precede the final baseline fixes
and extension accessibility-label change. Overlay/notch placement, multi-window identity,
light appearance, VoiceOver, sleep/lock, real audio devices and an actual 128 GB Mac remain
unqualified. The full native suite after the baseline/fixture corrections passed: 1802 logical
cases, 1794 passed, eight explicit optional integration/model skips and zero failures.
The [validation results](../development/validation-results.json) list the skips;
no skipped model test counts as voice or language qualification. The final Make
build and targeted test after a single EOF whitespace cleanup also passed (two
Whisper tests passed, one explicit artifact skip). The embedded app revision is
`e1cf3640ef066cf3bd7e1f149701c6294bf5a0f9`; the
[development bundle evidence](../development/development-bundle-evidence.json)
records verified compile-input identity and isolated embedded components. Final preview signing, the second
endurance cohort and development PR remain pending in the
[acceptance matrix](../development/live-translation-acceptance.md).

See [runtime evidence](../development/translation-runtime.md),
[repository audit](../development/live-translation-audit.md) and
[fork maintenance](../development/fork-maintenance.md). Performance targets remain targets until measured, not promises about the present preview.
