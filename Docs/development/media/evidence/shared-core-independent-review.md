# Independent shared-core review and follow-up repairs

Review performed on the in-progress root implementation, read-only in root-owned files. Scope: nativ_generation API/service/repository/assets/runtimes, remote process/worker/guardian, NativGenerationClient/Types and their ownership/recovery callers. File snapshots are recorded in shared-core-review-fingerprints.json; root continued fixing concurrently, so this is not an immutable whole-branch security certification.

## Findings sent early and verified follow-up

1. **P1 — untrusted current working directory could replace credential-bearing worker code.** `python -m nativ_generation.worker_guardian` inherited CWD, which precedes the explicitly trusted PYTHONPATH. An actual temporary malicious CWD package emitted the expected handshake and received a dummy provider credential from the parent. No real credential/network/paid provider was used. Root added trusted cwd and safe-path environment for remote/local workers. New test_generation_process_trust.py runs real helpers with malicious CWD packages and confirms no attacker marker/credential; configuration fails safely before network. Local handshake is also protected. Two tests pass with ResourceWarning treated as error.

2. **P1 — ambiguous HTTP 5xx could falsely release a paid reservation.** A real service fixture with durable remote dispatch plus `provider_rejected, definitive=False` became failed/released because the terminal-code list overrode ambiguity. Root fixed definitive handling and later made post-dispatch protocol failures conservatively unknown unless the adapter explicitly observed terminal execution. test_generation_service.py: ambiguous provider503 and unknown-paid cases pass. Music GET errors now remain observation uncertainty, even HTTP403/404; an inability to retrieve is not execution rejection.

3. **P1 — canonical MP3/FLOAT output could not publish in the actual base decoder environment.** Base requirements have no SoundFile while assets fallback accepted only PCM16 WAV. Root assigned new audio_media.py to this worker; it probes with managed FFprobe and streams full F32 decode through managed FFmpeg, without SoundFile/numpy. Probe/diagnostic/decoded/time limits, finite checks, bounded real waveform peaks and decoded-frame duration are implemented. Root wired it into assets when codecs are available. Six tests pass, including original synthetic MP3 and FLOAT WAV, nonfinite/cancel, decoded-byte limit and stalled-process reap. MP3 fixture source is one second PCM; actual decoded original is46,080frames,44.1kHzstereo,1.044897959seconds including codec padding. No output duration is inferred from its request.

4. **P1 integration — packaged runtime setup looked for a checkout-only Overlay directory.** Music and Video manage.py used ROOT.parent/Overlay, absent from the app's resource layout. Music now resolves modules from the checkout or the trusted standalone prefix's site-packages. Video owner was informed and fixed its counterpart. A new real RuntimeManager simulation has packaged resources without Overlay,7-byte hash-verified model fixture, tiny interpreter prefix and actual worker handshake: background install activates and ready/prepared paths work, no network/models/pip. Music installation suite4passes; initial setup fixture observed RED before repair.

5. **P2 — cached poster symlink escaped the store.** Original content was confined, but poster fast-path returned any existing is_file target, including a symlink outside the library. Threat explicitly requires local store tampering/restore, not a remote-only write primitive. Root now confines cached poster lookup. test_generation_assets.py includes a sentinel-outside-root symlink regression; six asset tests pass.

6. **P2 — native SSE queue was unbounded for a slow consumer.** AsyncThrowingStream used default buffering. Root now uses bufferingNewest(32), retaining bounded latest state. Swift integration/testing remains root's gate.

7. **P2 — Swift numeric DTO lost accepted64-bit seed precision.** All JSON numbers used Double;9007199254740993 could re-encode as9007199254740992. Root added Int64 integer decoding/encoding before Double and a native seed test. No Swift files were edited by this worker; actual native build/test is root's gate.

8. **P2 — accepted profile revision was not revalidated across an app upgrade.** Enablement/account/endpoint checks did not compare accepted profile revision to current catalog. Root added profile/provider/model/runtime identity comparison before dispatch. Its persistent held-intent revision-change test passes; reads and safe retrieval remain separate.

9. **Recovery capability gap — a trace ID was treated as a retrievable operation.** Root added retrieval_supported gates. Music now advertises true only for Stable Audio cloud and current stored Lyria3.5 interactions. MiniMax GPU/cloud IDs remain trace provenance, not invented GET handles. Synchronously complete Music results carry safe completed outcome metadata; known MiniMax completed status is emitted before import. Root persists completion before canonical import. Early outcome detail forwarding through remote process is root's final integration responsibility.

## Lyria contract follow-up

Current primary Gemini API references were fetched read-only to build/validation/{interactions,music,lyria}-primary-doc.md. The current model enum explicitly includes lyria-3.5; `store` stores request/response for later retrieval; GET /v1beta/interactions/{id} returns the stored Interaction and steps. The current3.5music guide does not state legacy Google Cloud stateless-only restrictions. The adapter now explicitly sets store=true, keeps Api-Revision2026-05-20, GET-only reconciles the same stored ID, polls pending status at5seconds, rejects wrong returned identity and recognizes explicit failed/cancelled outcomes. Catalog revision is2 and provider_storage describes retention under the configured Google account without zero-retention claims. Fixtures cover completed/pending/failed/wrongID/GET-rejection. Live account POST/GET has not been executed and remains unqualified.

## Stronger-Mac qualification kit

Added scripts/benchmarks/music/qualify.py and original corpus.json with20cases:8ACE,6MiniMaxMLX,6StableSmall; English/Dutch manual lyrics are evaluation cases, not advertised quality. Default actual dry-run emitted0network requests and qualified=false. --run-models is explicit and rejects hosted/remote-GPU catalog profiles. Corpus/profile revisions/base URL/store/keys are durably frozen before submission, with a single ledger owner and fsynced file+directory writes. Restarts poll the same job, resolve lost acceptance by unique frozen title/request GET lookup, and Resume held identity without a generation re-POST. Missing/ambiguous matches stop for operator recovery. Downloads are authenticated/store-bound/hash-checked/byte-bounded. Reports keep exact model/runtime pins, job/asset metadata, observed stage times and bounded latest status latencies. RAM/swap are labelled runner-host/system observations, not per-model peaks or remote-server metrics. Human quality, cancellation/coexistence/cleanup/signed-runtime review is mandatory; the tool never promotes catalog qualification.

Four mocked runner tests pass: original corpus/dryrun, actual bearer+store+idempotency headers, durable restart/lost-ACK lookup/resume without new generation, wrong-store rejection, single output owner. No --run-models was executed on this16GBhost.

## Verification run by this worker

- Music provider/worker/installation/runner suite:26passed, `python3 -W error::ResourceWarning -m unittest discover -s scripts/tests -p 'test_music*.py' -v`.
- Managed audio suite:6passed, same command pattern test_generation_audio_media.py. Real compiled FFmpeg decoded generated MP3 and FLOAT fixtures; no SoundFile/numpy loaded.
- Process trust suite:2passed, test_generation_process_trust.py with actual spawned helpers and dummy credential only.
- Root-owned service suite:10passed, test_generation_service.py, including503ambiguity, profilechange and no paid replay.
- Root-owned asset suite:6passed, test_generation_assets.py, including poster symlink and crash publication.
- Earlier packaging/codec/image/resource suites are documented in packaging-codec-image-report.md; root still owns full combined native/package/CI execution.

No other reportable path/auth/credential leak was demonstrated in reviewed routes. Mutations are store-preconditioned, public operation/configuration filtering is present, candidate paths/immutable inputs are checked, downloads use canonical metadata and native cache SHA verification, and parent-pipe guardian ownership is explicit. These observations are scoped to code inspected, not a claim that hardware/native/paid integrations are release-qualified.

## Remaining explicit limits

No real Music/Video model inference or real image generate/edit occurred. No paid/cloud/GPU calls or weights downloaded. Full packaged-base runtime startup outside checkout, native compilation/UI and owner signing/notarization remain root/stronger-Mac gates. Runtime dependency/native ABI execution is still unqualified. The Lyria stored-interaction contract is primary-document/fixture verified, not account verified. Exact model quality, model peak memory, cancellation responsiveness under actual GPU work and20-generation cleanup require the supplied strong-Mac kit plus manual review.

## Final assigned runtime lifecycle hardening

Root explicitly transferred runtimes.py ownership for this follow-up. Changes are now frozen:

- Readiness handshake uses nonblocking bounded JSON-line reads with an overall deadline and cancellation. A partial `{"type":` followed by a sleeping real child stops at the requested deadline instead of blocking readline. Invalid/oversized/EOF handshakes fail safely and reap the owned process.
- `write_all` loops over partial writes with nonblocking pipe backpressure, timeout and cancellation. Both local dispatch stdin and the small remote_process send hook use it. No remote outcome forwarding code was modified.
- Manifest discovery isolates malformed JSON/nested schema/unsupported identity/invalid or missing lock data into unavailable profile diagnostics. It never loads model code. Duplicate profile manifests are ambiguous/unavailable. All seven curated manifests currently validate. The MiniMax base dependency lock is now copied into MusicRuntimes/locks, so its manifest does not reference an unbundled parent Requirements directory.
- New interpreter candidates receive an ownership marker bound to exact profile, runtime, directory and accepted manifest. Repair atomically activates a verified candidate and retires only prior marked inactive interpreter folders under the same profile. Remove deactivates first and only retires marked runtime-UUID directories. It never treats model/cache paths or unmarked legacy directories as disposable. Active-profile checks and cleanup occur under the service lock; a generation starting during repair prevents unsafe activation/retirement. Tiny actual install/repair/remove fixture proves old owned runtime cleanup, active removal rejection and retained weights, including a forged cache-as-runtime activation.
- Developer venv children omit PYTHONHOME when pyvenv.cfg is present; standalone app prefixes retain it. A real venv child initially failed stdlib encodings lookup, then passed after this fix. No base environment was modified.
- Stronger-Mac Music runner and its API documentation now default to the actual8181port.

Final targeted runs: Music suite27passed; generation process/worker trust suite7passed; installation subset5passed, all with ResourceWarning treated as error. compileall passed. No app build, Git change, heavy weights or paid calls were made during this hardening task.
