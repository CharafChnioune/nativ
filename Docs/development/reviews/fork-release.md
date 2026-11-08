# Independent review — fork sync, release and update isolation

Reviewer: review_fork_release. Scope: Task7 implementation, relevant root namespace/debug-launch changes, source specification sections8/9. No commits, pushes, settings changes, model loads, Xcode app builds, signing or publication were performed by this reviewer.

## Findings corrected

1. **P1 — Candidate bundle tree was not authenticated by the pre-push check.** Publisher compared the upstream patch and exact parents, but a different merge tree with those same parents could add unreviewed executable content. Added `validate_candidate_merge`: Git recomputes the normal merge as objects with `merge-tree --write-tree`; only the exact expected baseline metadata may differ. It never checks out candidate files. An actual Git fixture creates a forged two-parent commit with an extra workflow and proves rejection. Preparation and publication both use this check.
2. **P1 — Package evaluation inside the signing-secret environment.** `publish_fork_release.sh` invoked `xcodebuild -resolvePackageDependencies`, which evaluates Swift package manifests. Removed it. A separate workflow step without signing secrets downloads Sparkle2.9.4's official binary archive and verifies its published SHA256 before extraction. The signing step only uses the verified tool. Exact package source: https://github.com/sparkle-project/Sparkle/blob/2.9.4/Package.swift; SHA256 `cb6fdbdc8884f15d62a616e79face92b08322410fd2d425edc6596ccbf4ba3b0`. Reviewer actually downloaded, hashed, extracted and ran the tool's help, confirming its layout.
3. **P1 — ZIP symlink escape before credential setup.** Lexical `..` checks did not reject a symlink member pointing outside the extraction directory. `fork_release.py archive` now rejects unsafe paths, duplicate entries, special file types, absolute/external links and cycles, following chained links before `ditto`. Legitimate relative versioned-framework symlinks remain supported. Fixtures cover both refusal and preservation.
4. **P2 — Stable tag identity depended on a `v` prefix.** Stable release tags with another naming scheme were not recorded/rechecked. Reports now carry an explicit `release`/`main-sha` source kind. Every release tag is rechecked and recorded. Manual SHA publication rechecks ancestry against upstream main through GitHub before accepting the artifact.
5. **P2 — Concurrent branch creation could be advanced.** A branch appearing between `ls-remote` and push could be fast-forwarded despite the immutable-candidate policy. Push now uses an empty expected-ref lease, an atomic create-only operation. A real bare-remote fixture proves that even a fast-forward is refused and the concurrently created branch remains unchanged.
6. **P2 — Deterministic CI rejected the explicitly opt-in real-inference skip.** The exact tests `TranslationRuntimeTests.testExplicitLocalRuntimeIntegration` and `TranslationWhisperPreparationTests.testPinnedArtifactsPrepareWithoutChangingSourceSnapshot` may be reported as unrun qualification when no model probe/artifact directory was supplied. Neither can satisfy its class by itself; ordinary skipped/missing/failing lifecycle tests still fail the gate. Added required `TranslationLocalTransportTests` and `TranslationWhisperPreparationTests`, including individually required deterministic revision/cancellation tests. The CLI prints the unrun qualification explicitly.
7. **P2 — Bundle validator accepted one extension runtime.** Validation now requires both actual Audio and Live Translation `.appex` names as well as isolated identities/bindings. Actual local build names were inspected read-only.
8. **P2 — Source identity gate omitted manifest/runtime guard consistency.** Following root's namespace correction, added independent checks of both first-party manifest IDs, extension points, runtime bundle identifiers and runtime context guards. Mutation tests restore each old upstream value separately and confirm refusal.

## Verification after fixes

- `python3 -m unittest discover -s scripts/tests -v`: **107 tests passed**, exit 0, 10.700s. Log `build/validation/review-fork-python-all.log`.
- Sync fixtures: **13passed**, including forged tree, atomic creation, moved tags, stale bases, conflicts, no-op, privileged paths and gate failure modes. Log `review-sync-green.log`.
- Release fixtures: **8 passed**, including unsafe/internal ZIP symlinks and manifest/runtime identity isolation. Log `review-release-green.log`.
- Evidence fixtures: **3 passed**, ordinary skip/missing-test failure and explicit optional-inference/artifact reporting. Log `review-evidence-green.log`.
- Red regressions retained: `review-sync-red.log`, `review-release-red.log`, `review-tag-red.log`, `review-create-only-red.log`, `review-evidence-red.log`, `review-namespace-red.log`, `review-whisper-evidence-red.log`.
- `python3 scripts/fork_release.py sources`: pass.
- `actionlint`: pass; `shellcheck scripts/publish_fork_release.sh scripts/open_macos_debug.sh`: pass. Logs empty, commands exit0.
- Scoped `git diff --check`: pass.
- Downloaded Sparkle binary archive checksum matched the official pin; `bin/generate_appcast --help` succeeded. No signing keys used.

## Reviewed and retained behavior

- Read-only discovery and candidate code validation remain separate from protected publication/signing jobs; candidate trees are never executed with write credentials. No `pull_request_target` build was introduced.
- Imported workflow/local-action/tooling changes block before executable branch publication unless the exact patch is explicitly reviewed; Git hooks/global configuration are disabled.
- Exact current main/tag/candidate identities and successful always-run aggregate checks are required; missing/skipped/cancelled/stale validation cannot be inferred green. Initial merging remains manual and must retain ancestry.
- Own namespace, empty default Sparkle key and strict own feed URLs fail closed; upstream updater identities/archives are refused. Updater Swift behavior was not modified by this reviewer (implementation worker's12tests plus root combined tests remain applicable).
- Root's development launcher confines termination to the exact fork executable path and checks fork bundle identity; its explicit ad-hoc mode is development-only. Installed official Nativ is not terminated or migrated.

## Remaining gates

No remaining blocker identified in this reviewed scope after the fixes. Actual GitHub workflow execution, owner-protected environments/repository rules, App credentials, signing/notarization, published feed and older-fork→newer-fork installation remain unexecuted owner/external gates. The implementation worker's live discovery attempts received HTTP503; fixture success is not live discovery/publication evidence. Root still owns exact final-tree app tests, UI proof, About provenance and whole-feature review. Any later code changes need appropriate revalidation.

## Latere gecombineerde verificatie door de uitvoerder

De live read-only discovery slaagde op 8 november 2026 om 12:49:14 UTC: upstream stable `v0.4.5` op `9b876ef199adec3018e352b3a7c51864e7c5bb8a` was reeds geïntegreerd in forkbasis `5cb79ed65659414774745c1331cce08397d16055`; resultaat `noop`, zonder kandidaatpush. Dit vervangt de eerdere HTTP503-pogingen als laatste discoveryresultaat. De uitgebreide Python-suite telde daarna 123 tests: 122 geslaagd en één expliciete opt-in-runtimecheck overgeslagen (`python-delivery.log`). De eerder afzonderlijk uitgevoerde echte workercheck blijft apart bewijs. Finale native/CI-resultaten en distributiegates staan in de [acceptatiematrix](../live-translation-acceptance.md).
