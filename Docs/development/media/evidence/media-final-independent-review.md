# Independent final media review — 2026-11-08

Scope: native Music/Video workspaces, immutable references, shared playback,
submission recovery, Chat/Artifacts bridges, API boundary/capability consistency.
No model downloads, inference, paid calls, Git mutations or Xcode runs.

## P1 — rejected submissions automatically replayed (repaired)

The former `GenerationLibraryObserver.submit` froze an intent before POST but
left every error pending. `reconcileIntents` replayed all nil-job intents at
reconnect and aborted at its first error. A known 429 queue rejection could
therefore become new paid work later, while a persistent validation error could
block recovery of other requests.

Repair spans `GenerationIntentJournal.swift`, `GenerationLibraryObserver.swift`,
`ChatGenerationTool.swift`, `NativGenerationTypes.swift` and
`NativGenerationClient.swift`:

- Preserve actual HTTP status independently of retryable.
- Persist an optional backward-compatible rejection reason for 4xx excluding
  ambiguous 408; reject explicit replay of that same intent.
- Preserve original keys for transport failures, missing/invalid replies and
  5xx; never retarget a request to another store.
- Continue recovery after each individual failure and retain a visible rejection
  notice on refresh/relaunch until a subsequent intentional request succeeds.
- Acknowledged accepted jobs cannot be overwritten by a late rejection.

Validation: Swift 6 typecheck passed for DTO/client and journal/outbox. Compiled
and executed a lightweight harness against the actual journal implementation:
`PASS: durable 429 rejection, per-intent recovery, timeout identity, relaunch`.
Five XCTest regressions were added to `GenerationPersistenceTests.swift`; final
Xcode compilation/execution remains owned by root. Plain CLI typecheck of those
tests lacked XCTest in its framework search path; no XCTest execution claimed.

## P2 — native ACE musical hints missing (repaired)

`GenerationComposer.advancedControls` offers duration and seed, while
`GenerationWorkspaceModel.request()` never emits BPM/key/time signature.
`nativ_music/catalog.py` advertises all three ACE options and
`nativ_music/providers/base.py:78-81` validates them. Music specification §3.1
explicitly requests native advanced controls for these supported hints.
Root authorized the narrow repair. The composer now exposes supported tempo,
key and meter hints with explicit generative-hint wording. Request construction
validates the provider's 30–300 integer BPM, 32-codepoint key and 2/3/4/6 meter
bounds, omits automatic/unsupported values, and clears hints on profile changes.
`MusicPresentationStateTests` includes a discovery-backed request regression for
valid hints, invalid values and switching to a provider without these controls.
Swift frontend parsing passed for the composer, model and test source; root owns
final app compilation and XCTest execution.

## Other observations and limitations

Reviewed remote-regeneration confirmation, bounded upload response handling,
canonical transform preview identity/digest checks, store scoping, shared
playback ownership and explicit qualification labels. No additional high-impact
blocker was established in these inspected paths. This is static and focused
deterministic validation, not a whole-repository security audit.

All actual model qualification, full runtime installation, generated-audio/video
quality, microphone/device integration and paid-provider account behavior still
require the separately documented stronger-Mac/external qualification gate.
