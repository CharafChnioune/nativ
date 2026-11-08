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

The fork's public Sparkle key is configured in `Configuration/Fork.xcconfig` by
`scripts/sparkle_setup.py`; its private key stays in the macOS Keychain account
`io.github.charafchnioune.nativ`, service `https://sparkle-project.org`.
`SoftwareUpdater` does not start until the actual app identifier, both fork feeds
and a valid non-upstream public key match. The UI explains incomplete configuration.
Both `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction` must also be true;
missing/disabled flags fail the app's configuration check and release validation.
The upstream key, feeds and archive
URLs are rejected. There is no inherited team/profile fallback. The upstream
provisioning file remains historical source material, but the signing script
requires an explicit owner profile for Developer ID signing.

Public fork versions start at `1.0.0`; positive numeric build numbers advance
independently, using the maximum of the UTC clock and all prior signed fork
builds. Upstream tag/SHA and fork source revision are separate Info.plist metadata.
Version suffixes outside the existing numeric/`rcN` grammar are not used.

## Owner setup before publication

The local Sparkle Keychain setup is separate from distribution credentials.
No repository rules, protected environments or publication were created by this
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
4. The public Sparkle key is read from the reviewed `Fork.xcconfig`. Optional
   repository variable `FORK_SPARKLE_PUBLIC_KEY` must exactly match it when set;
   a stale/different override fails the release build. GitHub login is optional:
   either leave both `FORK_GITHUB_APP_CLIENT_ID` and `FORK_GITHUB_APP_SLUG` empty,
   or configure both for the owner's actual OAuth App with device flow. A partial
   OAuth configuration fails validation; an absent one does not disable updates.
5. Set `FORK_APPLE_TEAM_ID` and protected release secrets
   `FORK_DEVELOPER_ID_APPLICATION_P12_BASE64`,
   `FORK_DEVELOPER_ID_APPLICATION_P12_PASSWORD`,
   `FORK_PROVISIONING_PROFILE_BASE64`, `FORK_SPARKLE_PRIVATE_KEY`,
   `FORK_APPLE_API_KEY_P8_BASE64`, `FORK_APPLE_API_KEY_ID`, and
   `FORK_APPLE_API_ISSUER_ID`.
   The local audit found an Apple Development identity, not a Developer ID
   Application identity. The owner must supply a valid Developer ID Application
   certificate with its private key, a matching fork provisioning profile covering
   the actual entitlements/identities, and an App Store Connect notarization API
   key with its real key/issuer IDs. None is replaced by the development identity.
   The Sparkle private key exists locally in Keychain; it has not been exported or
   installed as a GitHub secret. CI must receive that same key via the protected
   environment before publication can run. Secret setup is still an owner gate.
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

`sparkle_feed.py` authenticates any feed already signed by `generate_appcast`,
then applies RC display metadata to a temporary copy, signs the final XML and
verifies it before replacing the staging output. A failed signature or signing
operation leaves the original file intact. The preview publisher verifies every
source release feed before parsing/merging, signs and verifies the composed XML,
and only then creates/uploads/promotes the rolling feed. No further XML rewriting
occurs after signing. The post-publication check verifies downloaded fork feed
signatures as well as byte equality. CI passes its protected Sparkle secret only
to the official tools over stdin; helper diagnostics never expose the key.

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

Eenmalige lokale Sparkle-configuratie, vanaf de repositoryroot:

```sh
python3 scripts/sparkle_setup.py --prepare-tools --initialize
python3 scripts/sparkle_setup.py
python3 scripts/verify_sparkle_channel.py --output build/validation/sparkle-local-20261108
```

Het eerste commando downloadt alleen indien nodig de officiële Sparkle 2.9.4
tools. Het controleert de gepinde archiefhash én de daadwerkelijk uitgevoerde
binarybytes voordat het de Keychain benadert. Alleen de unieke fork-account kan
worden aangemaakt, alleen met `--initialize`, en uitsluitend wanneer zowel de
Keychain-account als de openbare configuratie leeg zijn. Het schrijft uitsluitend
de openbare sleutel naar `Fork.xcconfig`; de rest van het bestand blijft behouden.
Herhalen met dezelfde sleutel verandert niets. Een mismatch, vergrendelde
Keychain of al vastgelegde sleutel zonder bijbehorende private key blokkeert
de operatie. Er is geen export, import of automatische sleutelrotatie. Op een
andere Mac moet de eigenaar toegang tot de bestaande sleutel herstellen; een
nieuwe sleutel zou eerder uitgebrachte installaties hun vertrouwde updateketen
ontnemen.

De proef gebruikt dezelfde Keychain-account, ondertekent een klein testarchief
en een XML-feed met de echte `sign_update` tool, downloadt beide uitsluitend via
`127.0.0.1`, en verifieert de ontvangen bytes. Daarna moeten gewijzigde versies
van zowel archief als feed op een ongeldige signature worden afgewezen. Een nieuwe
outputmap bewaart de originele ondertekende artifacts en een `report.json`, zonder
private key. Dit is bewijs van ondertekening, transport en integriteit; het
testarchief is geen installeerbare app. Het vervangt geen oud-naar-nieuw
Sparkle-installatietest of notarized release. De productie-app behoudt uitsluitend
de eigen HTTPS GitHub-feed/archief-URL's; localhost wordt daar niet toegestaan.

Sparkle-documentatie:
[sleutelbeheer](https://sparkle-project.org/documentation/),
[appcast- en archiefondertekening](https://sparkle-project.org/documentation/publishing/).
De productie-app vereist nu ook de feedsignature: `SURequireSignedFeed=true`,
samen met het door Sparkle vereiste `SUVerifyUpdateBeforeExtraction=true`.
De proef controleert aanvullend de echte RC-postprocessor en de samengestelde
preview-feed, inclusief afwijzing na sabotage van beide. Zie
[Sparkle-configuratie](https://sparkle-project.org/documentation/customization/).

Op 8 november 2026 is de eigen Keychain-sleutel werkelijk aangemaakt en de
openbare sleutel vastgelegd:
`YAX1zGfcsvfAec12FrJ0y+q0tsiqe6F65Y2Fvs36AR8=`.
De eerste vijfchecks-proef staat lokaal onder
`build/validation/sparkle-local-20261108c/`. De uitgebreide proef slaagde met alle
acht checks onder `build/validation/sparkle-publisher-20261108/`:
archiefsignature, feedsignature, loopbackdownload, weigering gewijzigd archief,
weigering gewijzigde feed, ondertekende RC-postprocessing, ondertekende preview
en weigering van gewijzigde publisher-/preview-feed. Het
[vastgelegde meetrapport](sparkle-signature-evidence.json) bevat tijdstip, toolpin,
openbare sleutel en artifacthashes. Er is geen private key geëxporteerd en geen
release gepubliceerd. Een echte oude-naar-nieuwe appinstallatie, notarization en
publiek bereikbare updatefeeds zijn hiermee niet aangetoond.

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

## Executed development validation

The final Make/Xcode build succeeded with app source revision
`e1cf3640ef066cf3bd7e1f149701c6294bf5a0f9`. The complete native suite ran
1,802 logical cases: 1,794 passed, eight explicit optional model/integration
checks skipped, zero failures. The 1,799 passed invocations include dynamic
parameter variants and are not a separate total. All eleven required classes
passed the result-bundle verifier. SwiftPM's 53 tests overlap the native framework
target. Local Python: 123 discovered, 122 passed, one explicit optional check skipped.
See [machine-readable evidence](validation-results.json) for counts and skipped names.

The original Desktop checkout encountered a TCC test-startup prompt and absolute
debug-library paths that stalled app launch. The source snapshot and DerivedData
under `~/Library/Developer/NativLiveTranslationValidation/20261108-1352` resolved
those obstacles without changing macOS privacy settings. Only owned runners were
stopped. The native run exposed baseline CoreAI reflection, PDF assertion and
WebKit recovery problems; those were reproduced, corrected and passed in the
full suite. The [audit and reviews](live-translation-acceptance.md) retain the evidence.
One trailing blank line was removed after that suite's compilation; the exact final
Whisper source was rebuilt and its two deterministic tests passed again, with the
optional artifact test explicitly skipped. All 649 final compiled inputs match
the canonical repository.

The final owned preview passed Apple Development deep/strict signature verification
and visibly opened outside Desktop. [Bundle evidence](development-bundle-evidence.json)
checks the actual app, three framework identities, both extension bindings and
bundled arm64 helper. [UI observations](live-translation-ui.md) include accessible
extension labels and shared idle language direction across two windows. The initial
ad-hoc attempt was not a successful UI launch; use the verified
[local build/signing route](../features/live-translation.md).

The review is [draft PR #1](https://github.com/CharafChnioune/nativ/pull/1), branch
`codex/live-translation`. GitHub checks validate each exact review HEAD; consult the
PR for current run links. Git commits are unsigned, so no GitHub Verified status is
claimed. Evidence/documentation commits after the app revision do not change its
production code. Main, upstream and releases were not modified.

This is a development PR. Active audio concurrency, physical devices, overlay/notch,
VoiceOver, sleep/lock, human voice/meaning acceptance and actual 128 GB hardware
remain qualification gates. The first endurance run was guard-aborted; a second
cohort was not started because its independent baseline remained under warning
pressure. See [measurements](technical-performance.md). Apple Development signing
is not Developer ID signing, notarization, publication or a working Sparkle update.
The owner/distribution setup above remains required.


Native CI-artifacts gebruiken de bron-SHA én `github.run_attempt` in hun naam. Daardoor blijven uitkomsten van herhaalde runs ondubbelzinnig aan hun poging gekoppeld. Er wordt geen `overwrite` gebruikt: een eerdere mislukte poging blijft bewijs. Dit is een verbetering van bewijstoewijzing, geen claim dat GitHub dubbele artifactnamen bij reruns altijd afwijst.
