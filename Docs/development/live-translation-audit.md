# Live Translation integration audit

Audit date: 2026-11-08. Source baseline: `5cb79ed65659414774745c1331cce08397d16055`
in `CharafChnioune/nativ`; implementation branch: `codex/live-translation`.
This records source facts and intended seams, not a claim that translation works.
Build and runtime-spike results must be recorded separately against their exact candidate.

## Instructions and source coverage

The repository tree and checkout contain no `AGENTS.md`, `CLAUDE.md`,
`CONTRIBUTING.md` or `.cursorrules`; no ancestor `AGENTS.md` was found.
The contributor-reminder workflow requests Verified commits. Keep inherited history,
use available real signing credentials, and never fabricate signature verification.
`Docs/extending/extensions.md` requires privileged services in the host, additive SDK
changes, a new schema for breaking manifests, and negotiated/new surfaces for breaking XPC.
Use English product copy and existing native components.

The section-2 source inventory in the implementation specification was read at this
baseline: documentation; AppDelegate; extension host, SDK, manifest/runtime and plist;
control-panel routing/dependencies; all listed VoiceCapture, chat-speech and shared
files; model discovery/support/registry; requirements, Python overlay, capability
generator and both runtime builders; project/Makefile/configuration; updater/version;
four listed workflows; four release scripts; all listed Swift/Python test files.
The remaining portions of large files initially inspected selectively were read in
the local checkout. Extra reads included control-panel ownership tests.
This is a targeted integration audit, not a review of every other repository file,
third-party dependency, installed model or operating-system implementation.

## Verified host and framework boundaries

| Source | Current fact | Intended integration |
| --- | --- | --- |
| `Sources/Nativ/AppDelegate.swift:12,117,148` | One app-owned Audio extension/manager; closing the last window does not quit; termination shuts down extensions. | Own one LiveTranslation adapter/coordinator and one shared audio arbiter here; window/page creation must not create sessions. |
| `Features/Extensions/NativExtensionPlatform.swift:316,328,480` | Pages and commands dispatch to registered `builtIns`; lifecycle activates/deactivates adapters. | Register a separate first-party Translate adapter. Reuse generic `ControlPanelDetail.extensionPage` routing. |
| `Features/Extensions/VoiceDictationExtension.swift` | Adapter owns its coordinator and recording library. Activation starts shortcut/listener services. | Follow ownership/lifecycle pattern; translation activation only registers UI/actions. Start explicitly owns model preparation and audio. |
| `NativExtensionSDK/NativExtensionMessaging.swift`, `NativExtensionHostBroker.swift` | Existing XPC supports complete-audio transcription, model discovery, insertion/storage; shortcut/overlay broker operations return unsupported. | Keep native capture/playback/process control host-owned. Do not claim an external manifest/runtime supplies these services. No large new streaming XPC framework in v1. |
| `Features/ControlPanel/ControlPanelDependencies.swift` | Shared dependencies span windows; chat/image/artifact presentation is window-owned. | Share arbiter/services; adapter returns views over the same presentation coordinator. |
| `Features/Shared/InferenceActivityCoordinator.swift` | Tracks chat/image resource operations, not audio ownership. | Add the specified `AudioSessionCoordinator`; do not treat inference busy-state as a microphone lock. |
| `NativServerKit/NativAudioClient.swift:128`, `Features/Chat/ChatResponseSpeech.swift` | Synthesis requests WAV with `stream=false`, awaits complete Data and plays it with `AVAudioPlayer`. | Add independent bounded streaming PCM playback/transport. Preserve existing chat behavior apart from audio-ownership integration. |

Paths beginning `Features/` above are relative to `Sources/Nativ/`.
The new `NativTranslationKit` must receive public Sendable value/protocol boundaries,
not import app-internal types, SwiftUI models, device objects or borrowed audio buffers.
Session/turn UUIDs, monotonic generation, source identity, timestamp/timebase, sequence,
PCM encoding/rate/channels/interleaving/frame count, text stability and structured
incomplete/error events must be explicit. Audio-chunk commitment and whole-turn
completion are separate. Lifecycle state must not suppress concurrent input/output activity.

The manifest's `extensionPoint: com.nativ.extension` is not its ExtensionFoundation
binding. Actual host definition is `nativ-extension`; VoiceDictation runtime binds to
`dev.local.Nativ`, and `AudioExtension-Info.plist` uses
`dev.local.Nativ.nativ-extension`. Parameterize existing and new bindings consistently
with the fork app/runtime/framework identities. The current runtime validates activation
context and otherwise performs no substantive command work; document host ownership.

Documentation drift: voice/extension docs say Audio is enabled by default, whereas
the current manifest, fallback and manifest tests specify `enabledByDefault:false`.
Voice docs also describe a different default record shortcut/double-tap; current
code/tests specify `Fn+Control` and clean single-tap toggling. Preserve tested behavior.

## Audio ownership and the awaitable teardown seam

`AudioInputCaptureSession` in `AudioInputLevelMonitor.swift:160` is a MainActor lifecycle
wrapper over an actor-owned AVCaptureSession driver. Generation guards and serialized
operations apply to that instance. `stop()` immediately disables delivery but schedules
the driver's actual asynchronous stop; a different capture instance can otherwise start
before that teardown completes. Global leases must wait for the latter.

Proposed narrow additive seam: `AudioInputCaptureSession.stopAndWait() async` invalidates
generation and disables delivery synchronously, snapshots/enqueues the terminal operation
for the exact capture being stopped, then awaits that captured task. Preserve the current
nonawaiting `stop()` API for existing callers. Never await a mutable "latest operation"
after suspension or let completion of an old teardown stop a new capture. Expose matching
awaitable cleanup through recorder/monitor adapters that own these sessions.

`AudioSessionCoordinator` should reserve resources before asynchronous permission/start,
return unique owner/resource/lease IDs, reject conflicting foreground owners with a
reason, and suspend passive wake word through an awaited handoff. Invalidate the owner
before cancelling its tasks; grant replacement ownership only after real teardown.
Release is idempotent and ID-checked, so stale release/failure callbacks cannot release
a newer lease. Hold the recording lease only through capture teardown, not long-running
transcription, summary generation or disk export. Translation's own microphone and
playback are one explicitly compatible owner; unrelated speech playback conflicts.
Capture cues may be associated with their recording owner's policy.

Exact existing start/play/resume entrypoints requiring integration:

| File under `Sources/Nativ/Features/` | Entry/cleanup paths |
| --- | --- |
| `VoiceCapture/VoiceCaptureCoordinator.swift` | `beginCapture():235`; wake-word `onConfirmed` callback in init; `endCapture():302`, `cancelCapture():338`, `stop():147`, interruption. Manual start currently ignores `isOtherAudioBusy`; that flag primarily gates wake word. |
| `VoiceCapture/VoiceWakeWordMonitor.swift` | `configure`, `restart():84`, `listen():115`, `startInput():160`; `finishCaptureBeforeRestart():223`, `stopSession():275`, failure/retry. Suspend configuration before teardown so callbacks cannot rearm it. |
| `VoiceCapture/AudioInputLevelMonitor.swift` | `start():25`, `restart():63`, `stop():70` and failure: the input-test monitor is also a microphone owner. |
| `VoiceCapture/VoiceAudioRecorder.swift` | `start`, `stop`, `discard`, failure: use injectable capture lifecycle and expose awaitable terminal cleanup without altering saved-recording behavior. |
| `VoiceCapture/AudioCaptureLibrary.swift` | Recording `start(_:automaticallySummarize:includeSystemAudio:):397`, meeting suggestion callback, restart/discard, `finishRecording():506`, sleep/interruption and `shutdown():899`. |
| `VoiceCapture/AudioCaptureLibrary.swift` | Playback `startPlayback():799`; **also** `togglePlayback():723` resume, `seekPlayback():741` (calls play), `toggleExcerptPlayback():755` (calls play). Pause/stop/completion/error/shutdown must release the right output lease; resume reacquires it. |
| `VoiceCapture/SystemAudioMeetingRecorder.swift` | `start(outputURL:microphoneDeviceID:)`, injectable `start(stream:outputURL:)`; async stop/cancel and startup/delegate failure. This recorder owns both microphone and system capture. |
| `Chat/ChatResponseSpeech.swift` | `toggle():81` includes fresh synthesis and cache-hit playback; validate/acquire output permission immediately before either play path. `stop():173`, completion, preparation/playback error and stale request suppression release it. Do not hold a device lease merely while downloading a voice. |

`AudioInputSampleReceiver` reuses AVAudioPCMBuffer storage. `TranslationAudioCapture`
must synchronously copy callback samples to owned bounded storage before handoff;
no `Task` may retain the callback buffer. `VoiceWakeWordAudioBridge` demonstrates
synchronous conversion and Array ownership, but its `bufferingNewest(8)` drop policy
must not be reused as silent translation data loss. Format changes must reset/reconfigure
conversion while preserving source/sequence/incomplete-turn accounting.

SystemAudioMeetingRecorder excludes Bundle.main's application and current-process audio,
but captures mic plus system, writes AAC tracks to MOV and mixes a complete WAV offline.
Reuse permission/filter conventions in a new memory-only system-source adapter; do not
reuse its disk/mixing pipeline or erase source identity. It needs its own generation guards,
own-output exclusion and explicit overload intervals.

Sleep/display-sleep/login-session inactivity must invalidate translation, flush playback,
stop producers and release leases; wake leaves an explicit Resume state. Existing
`AudioCaptureSleepMonitor` intentionally saves recordings and offers an onWake callback;
that recording policy must not become automatic translation restart or transcript retention.

## UI, model preparation and dependency facts

`VoiceCaptureOverlay.swift` contains nonactivating NSPanel placement/Spaces/fullscreen
behavior plus internal `VoiceLiveWaveform`, `VoiceGradientOrb` and notch shapes.
Extract/adapt only small shared panel/visual primitives, leaving dictation defaults intact.
Reference sizes are 210x58, 140x52, 226x52 and 72x258 points; activation ~0.28 s,
completion ~0.38 s, panel removal after 420 ms. Visual timelines use 30/60 Hz;
`RealtimeAudioMeterPublisher` publishes at 15 Hz. Full orb state initializer is fileprivate
and coupled to dictation state. New overlay needs independent translation state, true
input/output meters, stable sizing, keyboard/VoiceOver and reduced-motion/transparency
behavior. Shared Nativ typography/panel/status primitives already exist.

`LocalModelDiscovery` recognizes MLX safetensors/config layouts, checks shard completeness,
selects `refs/main` or newest snapshot, and labels capability metadata. Its audio flag
does not qualify target voices, arbitrary language pairs, realtime PCM or duplex.
Generic memory-fit reserves are coarse and provide no complete omni/cascade peak-memory
guarantee. GGUF/projector/codec readiness needs its own pinned complete-artifact contract;
do not treat an MLX row or lone GGUF as prepared translation installation.

Baseline source requirements are `mlx-vlm>=0.7.10`, `mlx-audio>=0.6.2`,
`mlx/metal>=0.32.0`, `transformers>=5.14.0`; these are not resolved runtime pins.
The Python builder defaults to CPython 3.12.13 / PBS 20260508 arm64 Darwin.
Framework-resource build may automatically select sibling mlx-vlm/mlx-audio main checkouts.
Its stamp includes local source head/status and requirements/overlay/generator hashes;
`--reuse-only` fails missing/stale stamps. Capture actual generated `model-capabilities.json`,
installed package versions and source revisions after the baseline resource build.
The capability generator records loader families and package versions, not language quality.
The Python overlay adds metrics/settings/model loading over MLX; it is not a realtime
audio translation transport and persists analytics under the Nativ namespace by default.

Preferred qualification remains Omni direct, then same-weight two-pass; a failing pair
must require explicit selection of a qualified alternative. Cascade stages are independently
selected and qualified per task/language; an Omni `/tts` stage still needs explicit helper
slot/session ownership. Chatterbox phrase-batch behavior must remain visible. Apple TTS is
only an explicit optional extra, never the default or silent fallback. Initial WebRTC VAD
candidate (16 kHz, 20 ms, mode 2, 400 ms endpoint silence) is tuning input, not measured
capability. Preserve the specification's unchanged audio/context/transcript bounds.

## Build, tests and release isolation gates

XcodeGen `project.yml` is authoritative: add/embed the kit and extension runtime, add
kit tests to the Nativ scheme, and explicitly add host sources/dependencies needed by
`NativTests`. That test target compiles selected app sources and does not currently compile
the extension manager, dictation coordinator, capture library or overlay. An integration
test cannot assume those app internals are already importable. CI's class-based
`-only-testing` list omits multiple classes in the mandatory files; source inclusion is
not proof tests execute. Add the actual translation/arbiter and affected audio class names,
and retain result bundles/executed names. Existing real speaker-endpoint test skips without
`NATIV_AUDIO_TEST_SERVER` and `NATIV_AUDIO_TEST_PCM`; report skips as unexecuted gates.

Existing tests supply useful startup-cancel, stale-error, device/format, non-main callback,
SCStream-interruption, playback-cache/cancel and release-publication fixtures. Add behavioral
tests for reused-buffer ownership, awaitable cross-owner teardown, lease acquisition cancel,
stale releases, output before whole-response completion, tentative-text silence, bounded
queue overload, continuous speech/pending turns and generation/context resets.

Fork isolation is not currently implemented: stable plist feed and preview updater feed
point upstream; Signing.xcconfig contains upstream defaults/key; Developer ID signing may
load the checked-in upstream profile. Release tooling hardcodes Nativ.app/archive filenames,
numeric/rc public versions and an upstream appcast repository fallback. Existing release
workflow does not write a fork Sparkle-public-key override. Preserve internal product names
initially; fail closed until fork feeds/key/identities are valid. Pages workflow currently
writes snapshots to main and deploys on schedule without an owner guard. Guard inherited
Pages/release behavior before enabling fork automation; sign/publish only an exact validated
fork commit after owner setup and required review.

No build, tests, microphone/system capture, speaker feedback, device routing, signed archive,
model inference or benchmark was executed by this audit worker. The coordinating worker owns
baseline build/test evidence; the runtime spike owns real protocol/artifact probes. Pending
qualification includes original bilingual fixtures (at least 30 rated turns per direction),
at least 100 warm turns/10 cold starts, spoken-versus-committed-text fidelity, measured p50/p95,
Stop-to-silence, headphone/speaker fallback, offline preparation and 30-minute soak/context
rollover. Unrun or failed gates must remain explicit; source support alone qualifies none.

## Executed baseline

Immutable source `5cb79ed65659414774745c1331cce08397d16055` was archived under
`build/baseline-source` and built with Xcode27.2/Swift6.4.2, `-jobs 3`,
`CODE_SIGNING_ALLOWED=NO`. The final build succeeded (`build/validation/baseline-pristine-final.log`).
XcodeGen2.46.0 and the missing MetalToolchain27B47 were installed. Earlier attempts failed
on the missing Metal toolchain and HTTP504 while fetching the preexisting Python and GitHub
MCP distributions; these are recorded setup/network failures, not Live Translate regressions.
The initial unmodified Python test suite passed all74tests. A build of the mutable checkout
was interrupted and is not baseline evidence.
