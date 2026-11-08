# Fork maintenance and releases

This is `CharafChnioune/nativ`, based on `Neywa-Labs/nativ`. The product and scheme
remain `Nativ`; its app identity is `io.github.charafchnioune.nativ`. It is not an
official upstream distribution. The initial source baseline is
`5cb79ed65659414774745c1331cce08397d16055`; upstream stable `v0.4.5`
(`9b876ef199adec3018e352b3a7c51864e7c5bb8a`) is already an ancestor. Discovering
that release must do nothing, rather than replace the fork with the older tag.

The live read-only discovery completed successfully on 2026-11-08 at
12:49:14 UTC. `build/validation/upstream-live-final/report.json` records
`status: noop` for the exact fork base above and stable `v0.4.5` at the exact
upstream SHA above. No candidate, PR or release was created. This later success
supersedes the two earlier HTTP503 discovery attempts; it does not establish
that a live candidate publication or merge has been exercised.

## Source synchronization

`upstream-sync.yml` checks for the latest stable upstream release daily at 06:43
UTC. `workflow_dispatch` also accepts a full upstream-main SHA. Schedules are
best effort and may be disabled by GitHub after inactivity. The workflow run,
summary and retained `upstream-review-<run-id>` artifact are the record of the
last check. This works with Issues disabled. A conflict or blocked workflow
change is a visible report and patch, never an invented resolution.

`scripts/sync_upstream.py` resolves exact identities through GitHub, fetches full
history into temporary repositories, and imports upstream tags only under
`refs/upstream-tags/`. It does not execute candidate scripts, hooks, filters or
local Actions. An already integrated source creates no commit, branch, tag, PR
or release. A candidate name includes both the upstream SHA and current fork
base SHA. It has a normal merge commit with those two exact parents. Main is
never reset/rebased; accepted synchronization must use a merge commit.

Before any candidate can be pushed, the imported diff is checked for workflows,
local Actions, build scripts, Python distribution scripts, Makefile, project and
package configuration, submodules and attributes. This deliberately errs toward
review for transitive script dependencies. When those paths change, discovery
retains `candidate.patch` and its SHA256 but produces no executable branch
bundle. Review the exact patch, then dispatch with `reviewed_patch_sha256` and
approve the protected `fork-sync` environment. The publisher rechecks the digest,
base, upstream tag, merge parents and resulting tree before pushing.

Publication is a separate job that checks out the trusted workflow commit. It
never checks out or builds the imported candidate tree with write credentials.
Existing candidates are reused only for the same base/source and tree; branches
containing human edits are never force-updated. A changed main creates a fresh
candidate. `Configuration/UpstreamBaseline.json` changes inside a successful
candidate, and advances the product baseline only when that candidate is merged.
Moved or reused recorded tag identities are rejected.

All candidates remain draft PRs for manual review. No workflow merges them. The
`Required validation gate` must succeed, and source history must be preserved.
Protected paths also include signing/configuration, runtime dependencies,
translation contracts/capabilities and host audio. Do not enable automatic merge
for these paths merely because Git reports no conflicts.

## Validation and token behavior

`translation-ci.yml` builds/tests the exact candidate commit, checks that it
contains the current main base, runs all Python tests, all TranslationKit SwiftPM
tests, the native app build and all configured XCTest classes. The aggregate gate
runs with `always()` and rejects missing, skipped, cancelled, failed or stale
jobs. Native test results must actually contain successful test cases in:

- `TranslationModelStoreTests`
- `TranslationRuntimeTests`
- `TranslationAudioTests`
- `AudioSessionCoordinatorTests`
- `LiveTranslationIntegrationTests`
- `SoftwareUpdaterTests`
- `TranslationLocalTransportTests`
- `TranslationWhisperPreparationTests`
- `TranslationResourceAssessmentTests`
- `TranslationHostOperationGateTests`
- `TranslationDownloadReservationsTests`

The result bundle is retained. A green unrelated run or an empty test plan is
insufficient. Main changes require a new candidate and new validation. Repository
rules must require an up-to-date base and review; the workflow cannot prevent an
owner bypass if the repository permits one.

The preferred sync credential is a GitHub App installed only on this fork, with
Contents and Pull requests write permissions. Keep the private key in the
protected `fork-sync` environment. Imported workflow changes may additionally
need the App's Workflows permission; do not broaden the token to other repos.
`FORK_SYNC_APP_ID` and `FORK_SYNC_APP_PRIVATE_KEY` select this mode.

Without that App, the workflow uses `GITHUB_TOKEN` and explicitly reports the
approval step. As verified on 2026-11-08, pushes using `GITHUB_TOKEN` do not trigger
new push workflows. PR `opened`, `synchronize` and `reopened` events produce
approval-required runs; a person with write access must choose **Approve
workflows to run** in the PR. `workflow_dispatch`/`repository_dispatch` do start
runs. The sync job does not wait indefinitely for checks that cannot start and
does not invent a successful status. See [GitHub's token event documentation](https://docs.github.com/en/actions/concepts/security/github_token).

Inherited Pages deployment/statistics writes and upstream release publication
are owner-guarded. The fork does not publish the upstream website. The inherited
Dev Build is also upstream-only; the fork uses the complete validation workflow.
All Actions are pinned to resolved commit SHAs and validation checkouts do not
retain credentials. The contributor-reminder workflow is API-only and does not
execute PR code in its `pull_request_target` job.

## Isolated binary identity

`Configuration/Signing.xcconfig` includes `Fork.xcconfig`, then optional ignored
`Signing.local.xcconfig`. App/framework/extension identities share the fork
namespace. The real `@AppExtensionPoint.Bind` host literals and embedded
`EXExtensionPointIdentifier` use the same identity; `fork_release.py sources`
checks them. The macro needs a compile-time literal, so changing the namespace
requires an intentional coordinated source/configuration change.

Application Support, keychain services, routine/launch locks and server defaults
are separate. The default local server port is 8181. No upstream data is migrated
or deleted. Existing shared model caches remain model artifacts, not conversation
history; Translate settings stay in this fork's preferences.

Both update feeds are explicit configuration values:

- Stable: `https://github.com/CharafChnioune/nativ/releases/latest/download/appcast.xml`
- Preview: `https://github.com/CharafChnioune/nativ/releases/download/preview/appcast.xml`

The checked-in Sparkle key is empty. `SoftwareUpdater` does not start until the
actual app identifier, both fork feeds and a valid non-upstream public key match.
The UI explains that updates are unavailable. The upstream key, feeds and archive
URLs are rejected. There is no inherited team/profile fallback. The upstream
provisioning file remains historical source material, but the signing script
requires an explicit owner profile for Developer ID signing.

Public fork versions start at `1.0.0`; positive numeric build numbers advance
independently, using the maximum of the UTC clock and all prior signed fork
builds. Upstream tag/SHA and fork source revision are separate Info.plist metadata.
Version suffixes outside the existing numeric/`rcN` grammar are not used.

## Owner setup before publication

No credentials, repository rules or protected environments were created by this
implementation. The inspected fork had Issues disabled, no visible rulesets and
no published releases. Configure these concrete gates before enabling writes:

1. Protect `main`: require PR review, dismiss stale approvals, require the
   `Required validation gate` from `Live Translate validation`, require the branch
   to be up to date, and disallow force pushes/deletions and routine admin bypass.
   Permit merge commits; do not squash/rebase upstream sync PRs.
2. Create `fork-sync` and `fork-release` environments restricted to `main`, with
   required reviewers. Keep signing/sync secrets in those environments, never as
   unrestricted repository secrets available to arbitrary same-repository branches.
3. Optionally install the fork-only sync App and configure `FORK_SYNC_APP_ID`
   (variable) / `FORK_SYNC_APP_PRIVATE_KEY` (secret). Otherwise explicitly approve
   token-created PR validation runs.
4. Set public repository variables `FORK_SPARKLE_PUBLIC_KEY`,
   `FORK_GITHUB_APP_CLIENT_ID`, `FORK_GITHUB_APP_SLUG`; use the owner's actual OAuth
   App with device flow. The public Sparkle key must belong to this fork.
5. Set `FORK_APPLE_TEAM_ID` and protected release secrets
   `FORK_DEVELOPER_ID_APPLICATION_P12_BASE64`,
   `FORK_DEVELOPER_ID_APPLICATION_P12_PASSWORD`,
   `FORK_PROVISIONING_PROFILE_BASE64`, `FORK_SPARKLE_PRIVATE_KEY`,
   `FORK_APPLE_API_KEY_P8_BASE64`, `FORK_APPLE_API_KEY_ID`, and
   `FORK_APPLE_API_ISSUER_ID`.
6. After review/merge and exact-main validation, create an immutable numeric fork
   tag at that combined SHA. Dispatch **Publish fork macOS release** from `main`
   with the exact `commit` and `tag`; approve the protected environment.

`fork-release.yml` is the only fork publisher. Its unsigned build job has no
signing or write secrets. It explicitly embeds the public Sparkle override and
fork revision, then validates the actual app/embedded framework/extension/helper
contents. The signing job downloads that same run's artifact, revalidates
tag/main/check identities, and signs nested code without executing it. It then
packages, notarizes and publishes immutable assets. Preview refresh is explicitly
chained, since a `GITHUB_TOKEN` release event does not launch a second workflow.
Local appcast generation requires `NATIV_GITHUB_REPOSITORY=CharafChnioune/nativ`;
there is no upstream fallback.

Publication re-derives the normal merge tree with `git merge-tree --write-tree`
(Git 2.38 or later), allowing only the exact deterministic integration metadata
in addition. A bundle with correct parents but injected content is rejected.
Candidate branch creation uses an empty expected-ref lease; even a fast-forward
is refused if the branch appeared after discovery. Stable release tag identities
are retained and rechecked regardless of their naming prefix.

Before extracting a release ZIP, the publisher rejects traversal paths, special
file types, external symlinks and symlink cycles; internal versioned-framework
links are supported. It requires both Audio and Translate extension runtimes.
Source validation also requires each first-party manifest ID, host extension point,
runtime bundle identifier and runtime context guard to use the same fork identity.
The signing workflow prepares Sparkle's official 2.9.4 binary archive in a
separate step before signing credentials enter the environment, verifying SHA256
`cb6fdbdc8884f15d62a616e79face92b08322410fd2d425edc6596ccbf4ba3b0`
from the [official package manifest](https://github.com/sparkle-project/Sparkle/blob/2.9.4/Package.swift).
The privileged publisher never evaluates Swift package manifests or builds code.

The native-test gate requires the local-only transport regressions as well as the
session/audio/model/updater and Whisper preparation classes. Only the explicitly
named real-runtime integration and pinned-Whisper-artifact tests may be skipped
without failing deterministic CI; each is printed as **unrun qualification**.
Neither can satisfy its class alone. Both deterministic Whisper revision and
cancellation tests are required individually; missing or skipped cases fail.

Without these resources only local development builds are deliverable. Signed
notarization, real feed publication and an actual older-fork→newer-fork Sparkle
installation preserving Translate settings remain open acceptance gates. Unit
tests of identity rejection do not constitute that installation test.

## Local verification

```sh
python3 -m unittest discover -s scripts/tests -v
python3 scripts/fork_release.py sources
actionlint
shellcheck scripts/publish_fork_release.sh scripts/generate_macos_appcast.sh scripts/sign_macos_release.sh
python3 scripts/sync_upstream.py discover --output build/upstream-review
```

Discovery is read-only remotely. Do not invoke `publish` or the release publisher
as a test against production. Git fixtures cover conflicts, no-op mutation
protection, changed bases, existing human edits, moved tags and pre-push workflow
blocking. Release fixtures cover exact validated commits, skipped checks, numeric
ordering and rejection of upstream update identities.

The local app build completed successfully; the full native test gate is separate.
The first `xcodebuild test` attempt from the Desktop checkout stopped before a
case ran because macOS requested Desktop-folder access for Xcode/xctest. The
sample and TCC event are retained in `build/validation/native-test-startup-sample.txt`
and `native-test-tcc.log`. Only the owned runner was stopped; privacy settings
were not changed. That interruption was neither a test pass nor an assertion failure.

A source snapshot outside Desktop under
`~/Library/Developer/NativLiveTranslationValidation/20261108-1352` allowed real
native validation. `build/validation/native-snapshot-files.json` records source
paths and hashes; XcodeGen regenerated the missing test-action scheme. Actual
XCTest discovery then exposed the baseline CoreAI/Parakeet metadata crash on
macOS 26.6. The narrow fix preserves CoreAI's availability boundary and all tests.
A subsequent full run in `native-tests-regressions.log` completed with failures
in a stale PDF-excerpt assertion, WebKit's blank replacement-page navigation and
chat recovery, and wake-word fixtures. Those regressions are now corrected: `native-tests-validated.log` completed
with exit 0 and `TEST SUCCEEDED`. The result bundle is
`~/Library/Developer/NativLiveTranslationValidation/20261108-1352/build/TranslationTests-validated.xcresult`.
It contains **1802 logical cases: 1794 passed, eight explicit skips, zero failed**.
The 1799 passing invocations include dynamic parameter variants; do not report
those as extra test cases. `native-evidence-validated.log` confirms all eleven
required classes actually passed. The portable [validation results](validation-results.json)
name all eight unrun optional integration/model cases and record the log hash.

The functional app code is commit `e1cf3640ef066cf3bd7e1f149701c6294bf5a0f9`;
`fb3ec9163caaa34cbd680788dcb820d400d93283` adds benchmark evidence. The final
source snapshot manifest is `native-snapshot-final-files.json`. After the full
run compiled, only one extra EOF blank line was removed from
`TranslationWhisperPreparation.swift`. Its targeted exact-file test then passed:
two passed, one explicit artifact skip, zero failures (`native-whisper-final.log`).
The final Make build also succeeded (`development-build-verified-revision.log`);
the built Info.plist contains `io.github.charafchnioune.nativ` and
`NativForkRevision=e1cf3640ef066cf3bd7e1f149701c6294bf5a0f9`. No functional app
change followed the successful suite. Final preview signing and the draft-PR
URL remain pending in the [acceptance matrix](live-translation-acceptance.md). The
[development bundle evidence](development-bundle-evidence.json) confirms 649
compiled inputs match the canonical repository, the app/three-framework/two-appex
identities and bindings, the bundled arm64 helper, and updates disabled because
the own Sparkle key is empty. This is not distribution qualification.

The native dark Translate page was actually observed in an owned preview under
Library/Developer signed with an existing valid Apple Development identity via
`sign_macos_debug.sh`. Its direct/cascade selectors and inactive behavior are
recorded in the [UI inspection](live-translation-ui.md). The initial ad-hoc
preview did not reach a visible interface (AMFI -423); a started process was not
UI evidence. A later product retained absolute Desktop debug library paths and
stalled at launch. Rebuilding from the source snapshot outside Desktop resolved
that obstacle. See the [local build instructions](../features/live-translation.md)
for the checked signing/launch route; relocating only the app is insufficient.
The launcher remains restricted to the owned fork identity.

These observations do not qualify overlay/notch behavior, multiple windows,
sleep/lock, real audio, voice quality or a 128 GB Mac. The screenshots precede
the latest baseline fixes and the final generic extension accessibility-label
change. Apple Development signing is not Developer ID signing, notarization,
publication or proof of a working Sparkle update. Those credentials and release
gates remain open. The intended review deliverable is a development PR; the
verified bundle revision is recorded; final preview signing and the PR URL remain
pending in the acceptance matrix.
The second real endurance cohort remains pending; the first guard-aborted
run is retained. Its abnormal teardown was traced to guard plus cleanup
sending two SIGTERMs; the benchmark-only idempotent termination fix and
its test are documented in [technical performance](technical-performance.md).

The most recent complete Python run is `build/validation/python-delivery.log`:
123 discovered tests, 122 passed and one explicitly opt-in runtime check skipped.
That skip is unexecuted runtime qualification, not a successful test of a loaded
speech model. The native-result gate remains independent of this Python result.
