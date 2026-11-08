#!/usr/bin/env python3
"""Require executed Live Translate XCTest classes, not merely a green empty plan."""
import argparse
import json
import subprocess

REQUIRED = {"CascadedTranslationBackendTests", "TranslationContentGuardTests", "TranslationAutomaticDirectionTests", "TranslationModelStoreTests", "TranslationRuntimeTests", "AudioSessionCoordinatorTests",
            "TranslationAudioTests", "LiveTranslationIntegrationTests", "SoftwareUpdaterTests",
            "TranslationLocalTransportTests", "TranslationWhisperPreparationTests",
            "TranslationResourceAssessmentTests", "TranslationHostOperationGateTests",
            "TranslationDownloadReservationsTests", "TranslationCascadeRuntimeTests",
            "ManagedTranslationCascadeResourcesTests", "TranslationStageCatalogTests", "TranslationStockVoicePreparationTests"}
REQUIRED_CASES = {("TranslationWhisperPreparationTests", "testDifferentRevisionDoesNotCreatePreparedFiles"),
                  ("TranslationWhisperPreparationTests", "testAlreadyCancelledPreparationDoesNotTouchTheCache"),
                  ("ManagedTranslationCascadeResourcesTests", "testInvalidatedPendingBeginCannotResurrectAfterCleanup"),
                  ("ManagedTranslationCascadeResourcesTests", "testStaleReleaseAndInvalidationCannotUnloadNextGeneration"),
                  ("ManagedTranslationCascadeResourcesTests", "testInvalidationDuringSpeechAdmissionDrainsPreparerBeforeNextGeneration"),
                  ("TranslationStockVoicePreparationTests", "testAlreadyCancelledStockPreparationHasNoFilesystemOrNetworkEffects"),
                  ("TranslationStockVoicePreparationTests", "testInvalidReferenceNeverBecomesInstalledStockVoice"),
                  ("TranslationCascadeRuntimeTests", "testStopWaitsForBundledSupervisorToReapTermIgnoringChildBeforeRestart"),
                  ("TranslationCascadeRuntimeTests", "testReadinessWaitsForAnActualDelimiterAcrossPortFragments"),
                  ("TranslationStageCatalogTests", "testWhisperVocabularyDeterminesWhetherCantoneseExists"),
                  ("TranslationStageCatalogTests", "testWhisperHuggingFaceDimensionsFollowTheBundledLoaderPrecedence"),
                  ("TranslationStageCatalogTests", "testWhisperWithoutReviewedVocabularyDoesNotInventLanguageSupport")}
# Real model inference is a separate explicit qualification job. Its absence must
# be reported, and it cannot stand in for the deterministic runtime lifecycle tests.
OPTIONAL_QUALIFICATION = {("TranslationRuntimeTests", "testExplicitLocalRuntimeIntegration"),
                          ("TranslationWhisperPreparationTests", "testPinnedArtifactsPrepareWithoutChangingSourceSnapshot"),
                          ("TranslationStockVoicePreparationTests", "testPinnedStockArtifactsInstallIdempotentlyAndRequireTheirLicense"),
                          ("TranslationCascadeInferenceTests", "testExplicitOwnedHostCascadeSyntheticInference")}


def verify(summary, tree, unrun=None):
    if summary.get("totalTestCount", 0) <= 0 or summary.get("failedTests") != 0:
        raise ValueError("Native tests did not execute successfully")
    found = set()
    executed_cases = set()

    def visit(node, suite=None):
        if node.get("nodeType") == "Test Suite":
            suite = node.get("name", "").split(".")[-1]
        if node.get("nodeType") == "Test Case":
            name = node.get("name", "").removesuffix("()")
            if node.get("result") == "Skipped" and (suite, name) in OPTIONAL_QUALIFICATION:
                if unrun is not None:
                    unrun.append(suite + "." + name)
                return
            if suite in REQUIRED:
                if node.get("result") != "Passed":
                    raise ValueError("Required test was skipped or did not pass: " + node.get("name", ""))
                found.add(suite)
                executed_cases.add((suite, name))
        for child in node.get("children", []):
            visit(child, suite)

    for node in tree.get("testNodes", []):
        visit(node)
    if REQUIRED - found:
        raise ValueError("Missing executed test classes: " + ", ".join(sorted(REQUIRED - found)))
    if REQUIRED_CASES - executed_cases:
        raise ValueError("Missing executed deterministic tests: " + ", ".join(
            suite + "." + name for suite, name in sorted(REQUIRED_CASES - executed_cases)))
    return sorted(found)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("result_bundle")
    args = parser.parse_args()
    def read(kind):
        return json.loads(subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", kind,
                                                  "--path", args.result_bundle], text=True))
    unrun = []
    print("Executed required classes: " + ", ".join(verify(read("summary"), read("tests"), unrun)))
    if unrun:
        print("Unrun optional model qualification (not a passing measurement): " + ", ".join(unrun))
