# Music and Video implementation ledger

Authoritative specifications: `Nativ_Music_Generation_Codex_Prompt.txt` and
`Nativ_Video_Generation_Codex_Prompt.txt` at repository root, both read completely.
The owner approved implementation, feature pushes, normal PR merges and a narrow
build cleanup. Heavy model inference moves to a stronger Mac; no heavy weights or
paid generation on this M5/16 GiB development host. English product copy, Dutch
owner reporting. Existing Translate/LFM preference, manual Apple TTS, fork data,
Sparkle key/feeds and controlled upstream synchronization remain intact.

## Sequence and ownership

1. Merge reviewed Translate PR #1, retain evidence and clean only approved build
   products. **Merged** as `e22f7b9333a4ff7437bd81879454f050cbb3c6b9` after checking
   both exact-head required gates at `0e541dc3`; cleanup is separately recorded.
2. Root owns `nativ_generation`: durable SQLite jobs/assets/references, authenticated
   routers, shared worker/resource protocol, packaging and the Swift transport.
3. Music worker owns `nativ_music`, MusicRuntimes, music provider tests/docs.
4. Video worker owns `nativ_video`, VideoRuntimes, input/media validation and video
   provider tests/docs.
5. Native worker owns new workspaces, player, Chat/Artifacts/ControlPanel adapters.
   Shared-file edits are assigned explicitly; root integrates project/CI membership.
6. Run contract/native/packaging/upgrade regressions, independent scoped and final
   reviews. Prepare stronger-Mac qualification scripts without claiming execution.
7. Push reviewable commits, validate exact PR revision, then merge normally to main.
   Publishing a binary release remains outside authorization.

## Shared decisions and preflight rulings

| Tasks | Shared contract / ruling |
| --- | --- |
| Music + Video | One `nativ_generation` store/scheduler, thin modality facades. No duplicate DB/GC. |
| Core + native | Server owns originals/state; native uses store-scoped references, immutable connection snapshots, submission journal and reference outbox. |
| Core + providers | Synchronous isolated adapters run outside ASGI; typed context persists dispatch intent and operation identity before observations can advance. |
| Core + API | Required bearer and mutation store precondition; idempotency identity resolves against original accepted defaults/profile. |
| Video + native | Versioned orientation/crop/contain transform; canonical derivative and hash underpin preview and provider upload. |
| Workers + inference | Cross-process leases cover true inference/child lifetime, including embeddings and model management; control endpoints never wait for compute. |
| Native + audio | Extend existing audio coordinator with interruptible media; no separate capture owner or overlapping players. |
| Packaging + providers | Recursive overlay copy/hash/prune and isolated exact runtime locks; preserve base MLX stack. |
| CI + upstream | Extend one existing validation/sync/release system; preserve gate name and fail missing/skipped/stale mandatory checks. |
| Cleanup + evidence | Remove only explicit unused build paths; retain models, FinalReviewed app, CI archive/receipts and test media. |

Ruling: execute independent workers concurrently with disjoint ownership, as the
owner explicitly requires; this overrides the skill's default serial dispatch.
Ruling: use the existing checkout on a new feature branch, preserving untracked
specifications and all inherited commits; do not duplicate model/build caches in
additional worktrees. Only root changes Git state.
Ruling: no new extension target/XPC broker; both specs require native workspaces
following Images. Translate's extension boundary stays unchanged.
Ruling: shared lifecycle includes `retrieval_pending` for both modalities and
publication recovery before classifying local work interrupted.
Ruling: preserve the verified libx264 runtime path (also used by LTX I2V
preprocessing), package codecs separately with source/build/license records.

## Required implementation invariants

- One persistent store ID and startup scheduler lock. SQLite transactions reserve
  job/session/idempotency together. Retain key records for job lifetime and at least
  seven days after purge. Jobs/events/results are attempt-fenced.
- Native/Chat journal frozen requests and keys before POST. `X-Nativ-Store-ID` is
  required on mutations (428 missing, 409 mismatch). Switching endpoints or a
  replaced store cannot replay an old intent into a new store.
- Persist dispatch intent before remote submission. Unknown submissions are never
  automatically replayed. Immutable account/profile identity controls poll/cancel/
  retrieval; same-account credential rotation is permitted.
- One local exclusive media generation; one reserved remote operation per modality;
  eight queued jobs total, at most four video; one output, 128 KiB JSON, 1 GiB audio,
  2 GiB video, 25 MiB/40M-pixel still input, 1,000 coalesced retained events.
- Resume only undispatched recovery-held jobs. Retry Download never creates a new
  provider job. Cancel retains uncertain remote reservation until reconciled or
  explicitly released with acknowledgment. Known completed Runway jobs never DELETE.
- Python owns files/references/trash. Reference reserve/live/released revisions and
  tombstones prevent late finalize from resurrecting deleted references. Native
  attachment/unlink outbox survives crashes; uncertainty blocks destructive delete.
- Atomic validated publication with crash recovery; original bytes preserved.
  Missing/corrupt media or requested audio fails publication. Preview failure does
  not destroy a valid original. Validate actual frame grid/FPS/dimensions/timestamps.
- Local runtime processes are owned, identity-checked, environment-filtered and
  reaped before lease release; parent death cannot leave ungoverned inference.
- App launch/workspace visibility/listing does not load/download models. No autoplay,
  fabricated progress, silent provider switch, automatic lyrics rewrite or ASR of
  generated music. Real model support stays explicitly unqualified until measured.

## Verification and completion gates

Deterministic coverage includes duplicate/racing submissions; wrong/replaced store;
crash before/after remote acceptance; stale attempt events; queue overflow; restart/
cancel/publication races; unknown reservation release; immutable uploads/transforms;
corrupt/truncated/oversized media; reference outbox/tombstones; secure ranged content;
SSE reconnect/pruning; all route auth; server/process death; API/native admission;
image generation/edit control responsiveness; media/capture interruption; two
windows/relaunch; backward-compatible Chat/Artifacts; package modification/removal;
fork updater/upgrade preservation. New test classes must execute in real CI.

Real generation is a separate stronger-Mac gate: >=20 music outputs, >=5 per
released local provider; >=4 video clips per released local provider and every
advertised operation/audio mode. Record exact hardware/model/runtime/preset,
cold/warm stages, memory/swap/thermals, quality and cleanup. Fixture success never
counts as real-model qualification. Paid tests require a separate explicit budget.

## Progress

- [x] Full spec/repository/runtime audit and independent plan review.
- [x] Translate PR merged with exact expected head and normal merge ancestry.
- [x] Authorized cleanup and evidence preservation: 19,287,298,048 observed free bytes (17.963 GiB); protected app hashes unchanged.
- [x] Shared durable core/API and Swift transport.
- [x] Music adapters and managed runtimes.
- [x] Video adapters, immutable inputs and managed runtimes.
- [x] Native workspaces, Chat/Artifacts and playback.
- [x] Shared admission, image responsiveness and packaged runtime implementation.
- [x] Tests, independent reviews, documentation and stronger-Mac qualification kit implemented; full final run follows.
- [ ] Exact-head CI, reviewed feature PR merge and final cleanup/report.

### Integration checkpoint (2026-11-08)

Current branch `codex/music-video-generation`, base merge `e22f7b9333a4ff7437bd81879454f050cbb3c6b9`. No Music/Video commits or push yet. Root core implements SQLite repository, journaled assets, service/scheduler, strict authenticated API, runtime management, owned local worker guardian, and isolated cancellable remote-provider RPC (durable dispatch/operation ACKs). Private Translate helper skips canonical generation store. Swift transport compiles in Swift 6 and bounds downloads/events; native workstream compiled full app and ran 15 focused tests. Initial full Python regression:259 run,0fail,1existingoptional skip; more review regressions added afterward. Real media-only FFmpeg tests passed; no model inference or paid calls.

Still integrating/reviewing: unified compute host/Translate hooks, managed audio decoder, stop/restart preflight, complete native test membership, full packaged app/native regressions, UI snapshots and stronger-Mac kit, exact CI gate and fork release integration. Independent review caught/fixed validation-before-copy race, inactive remote cancel, provider permission revocation, terminal identity fencing, and ambiguous5xx reservation release. New remote process tests prove one POST and bounded cancellation using a local HTTP fixture; they are not model tests. Keep all profiles explicitly unqualified.

### Review checkpoint

Provider code and manifests are committed separately from the common scheduler and native integration. The root specification and vendor license bytes are preserved exactly, including their original whitespace. Independent reviewers reproduced and repaired helper-CWD credential injection, uncertain paid-POST reservation release, missing compressed/FLOAT audio decoding, constructor lock leaks, a stop/submit admission race, and unbounded native upload responses. Runtime handshake and installation cleanup checks remain in final integration. The complete app built at the earlier checkpoint; final source-frozen build/native/Python tests and exact-head GitHub checks are still required.

### Source freeze

All implementation workstreams are frozen after independent review. Final repairs cover bounded native upload replies, durable rejection of definitively refused requests, per-intent recovery isolation, ACE musical hints, installer-parent death cleanup and true compute-lease retention. Local-only qualification drivers remain deliberate opt-in. The lightweight full Python checkpoint executed 323 tests with one existing MLX-only integration skip; additional process/native review regressions are included in the final run. The final build, packaged-import proof, full Xcode test result and required CI gate are authoritative for delivery. No model output or paid provider has been qualified.

### Final lifecycle and packaging repairs

The first complete native run reported four failures; these were repaired rather
than waived. A retained parent Process stdin duplicated the Translate compute
lease, and a background Combine callback inferred MainActor isolation in the
Artifacts index. Both now have regressions. The video marker fixture now uses
actual bundled raw encoders and frame-accurate AVFoundation seeking; the pending
start cancellation test waits for observed milestones instead of fixed yields.

A final real C-extension probe found that the signed source Python could not load
newly installed native wheels with a different signing identity. Music and Video
builders now locally sign only their confined private interpreter copy before
pip; source app bytes remain unchanged. The compact before/after receipt is in
`evidence/runtime-signing-probe.json`. This verifies interpreter compatibility,
not a complete model-runtime installation or inference. An independent reviewer
checked the containment and signing change. Final exact-revision results and the
merge receipt are recorded in PR #2; heavy hardware and release gates remain open.

### M3 / 128 GB handoff (2026-11-09)

The owner moved remaining qualification and repairs to the stronger Mac. Read
[`prompt.md`](../../../prompt.md) at repository root before continuing. Product
HEAD c24781b73e64aec7a853b8f44ea0fe2465f1b5e6 builds on CI Xcode 26.6; its push gate
passed, but the PR native run failed two TranslationCoreTests assertions. Exact
run IDs, assertions and artifact IDs are recorded in `evidence/m3-handoff-ci.json`.
PR #2 is therefore still open and unmerged; no validation requirement was waived.
The seven reviewed build directories and separately inventoried test caches were
removed. `evidence/m3-handoff-cleanup.json` records observed free-space changes and
preservation scope. Source, models, user data, active FinalReviewed, one signed
media candidate and full local test evidence remain. No model qualification or
release publication is implied by this handoff.
