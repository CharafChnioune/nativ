import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("test_evidence", Path(__file__).resolve().parents[1] / "verify_translation_test_results.py")
evidence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evidence)


class TranslationTestEvidenceTests(unittest.TestCase):
    reviewed_regressions = [
        ("TranslationCascadeRuntimeTests", "testStopWaitsForBundledSupervisorToReapTermIgnoringChildBeforeRestart"),
        ("TranslationCascadeRuntimeTests", "testReadinessWaitsForAnActualDelimiterAcrossPortFragments"),
        ("TranslationStageCatalogTests", "testWhisperVocabularyDeterminesWhetherCantoneseExists"),
        ("TranslationStageCatalogTests", "testWhisperHuggingFaceDimensionsFollowTheBundledLoaderPrecedence"),
        ("TranslationStageCatalogTests", "testWhisperWithoutReviewedVocabularyDoesNotInventLanguageSupport"),
    ]

    def test_reviewed_regressions_cannot_be_missing_when_their_old_class_passes(self):
        for suite_name, case in self.reviewed_regressions:
            with self.subTest(case=case):
                tree = self.fixture()
                suite = next(node for node in tree["testNodes"] if node["name"] == suite_name)
                suite["children"] = [node for node in suite["children"] if node["name"] != case]
                suite["children"].append({"nodeType": "Test Case", "name": "testPreviouslyExistingBehavior", "result": "Passed"})
                with self.assertRaisesRegex(ValueError, "Missing executed deterministic tests"):
                    evidence.verify({"totalTestCount": len(evidence.REQUIRED), "failedTests": 0}, tree)

    def test_reviewed_regressions_cannot_be_skipped_when_other_cases_pass(self):
        for suite_name, case in self.reviewed_regressions:
            with self.subTest(case=case):
                tree = self.fixture()
                suite = next(node for node in tree["testNodes"] if node["name"] == suite_name)
                suite["children"] = [node for node in suite["children"] if node["name"] != case]
                suite["children"].append({"nodeType": "Test Case", "name": case + "()", "result": "Skipped"})
                with self.assertRaisesRegex(ValueError, "Required test was skipped"):
                    evidence.verify({"totalTestCount": len(evidence.REQUIRED), "failedTests": 0}, tree)

    def test_resource_and_lifecycle_regressions_are_required(self):
        self.assertTrue({"TranslationResourceAssessmentTests", "TranslationHostOperationGateTests",
                         "TranslationDownloadReservationsTests", "TranslationCascadeRuntimeTests",
                         "ManagedTranslationCascadeResourcesTests", "TranslationStageCatalogTests"}.issubset(evidence.REQUIRED))

    def test_cascade_ownership_cases_cannot_be_replaced_by_green_placeholder(self):
        tree = self.fixture()
        suite = next(node for node in tree["testNodes"] if node["name"] == "ManagedTranslationCascadeResourcesTests")
        suite["children"] = [{"nodeType": "Test Case", "name": "testPlaceholder", "result": "Passed"}]
        with self.assertRaisesRegex(ValueError, "Missing executed deterministic tests"):
            evidence.verify({"totalTestCount": len(evidence.REQUIRED), "failedTests": 0}, tree)

    def fixture(self):
        return {"testNodes": [{"nodeType": "Test Suite", "name": name, "children": [
            {"nodeType": "Test Case", "name": case, "result": "Passed"}
            for case in sorted(case for suite, case in evidence.REQUIRED_CASES if suite == name) or ["testBehavior"]
        ]} for name in evidence.REQUIRED]}

    def test_empty_or_skipped_native_tests_cannot_satisfy_gate(self):
        summary = {"totalTestCount": len(evidence.REQUIRED), "failedTests": 0}
        self.assertEqual(set(evidence.verify(summary, self.fixture())), evidence.REQUIRED)
        with self.assertRaises(ValueError):
            evidence.verify(summary, {"testNodes": []})
        skipped = self.fixture()
        skipped["testNodes"][0]["children"][0]["result"] = "Skipped"
        with self.assertRaises(ValueError):
            evidence.verify(summary, skipped)
        with self.assertRaises(ValueError):
            evidence.verify({"totalTestCount": 0, "failedTests": 0}, self.fixture())

    def test_only_named_opt_in_inference_can_be_reported_unrun(self):
        summary = {"totalTestCount": len(evidence.REQUIRED) + 1, "failedTests": 0}
        tree = self.fixture()
        runtime = next(node for node in tree["testNodes"] if node["name"] == "TranslationRuntimeTests")
        runtime["children"].append({"nodeType": "Test Case", "name": "testExplicitLocalRuntimeIntegration()", "result": "Skipped"})
        unrun = []
        self.assertEqual(set(evidence.verify(summary, tree, unrun)), evidence.REQUIRED)
        self.assertEqual(unrun, ["TranslationRuntimeTests.testExplicitLocalRuntimeIntegration"])
        runtime["children"] = runtime["children"][1:]
        with self.assertRaisesRegex(ValueError, "Missing"):
            evidence.verify(summary, tree)
        runtime["children"][0]["name"] = "testStopOwnedHelper()"
        with self.assertRaisesRegex(ValueError, "skipped"):
            evidence.verify(summary, tree)

    def test_optional_host_inference_is_reported_without_qualifying_the_profile(self):
        tree = self.fixture()
        tree["testNodes"].append({"nodeType": "Test Suite", "name": "TranslationCascadeInferenceTests", "children": [
            {"nodeType": "Test Case", "name": "testExplicitOwnedHostCascadeSyntheticInference()", "result": "Skipped"}
        ]})
        unrun = []
        found = evidence.verify({"totalTestCount": len(evidence.REQUIRED) + 1, "failedTests": 0}, tree, unrun)
        self.assertEqual(set(found), evidence.REQUIRED)
        self.assertNotIn("TranslationCascadeInferenceTests", found)
        self.assertEqual(unrun, ["TranslationCascadeInferenceTests.testExplicitOwnedHostCascadeSyntheticInference"])

    def test_whisper_preparation_requires_deterministic_tests_and_reports_artifact_skip(self):
        summary = {"totalTestCount": len(evidence.REQUIRED) + 1, "failedTests": 0}
        tree = self.fixture()
        suite = next((node for node in tree["testNodes"] if node["name"] == "TranslationWhisperPreparationTests"), None)
        if suite is None:
            suite = {"nodeType": "Test Suite", "name": "TranslationWhisperPreparationTests", "children": []}
            tree["testNodes"].append(suite)
        suite["children"] = [
            {"nodeType": "Test Case", "name": "testAlreadyCancelledPreparationDoesNotTouchTheCache()", "result": "Passed"},
            {"nodeType": "Test Case", "name": "testDifferentRevisionDoesNotCreatePreparedFiles()", "result": "Passed"},
            {"nodeType": "Test Case", "name": "testPinnedArtifactsPrepareWithoutChangingSourceSnapshot()", "result": "Skipped"},
        ]
        unrun = []
        evidence.verify(summary, tree, unrun)
        self.assertEqual(unrun, ["TranslationWhisperPreparationTests.testPinnedArtifactsPrepareWithoutChangingSourceSnapshot"])
        suite["children"][0]["result"] = "Skipped"
        with self.assertRaisesRegex(ValueError, "skipped"):
            evidence.verify(summary, tree)
        suite["children"].pop(0)
        with self.assertRaisesRegex(ValueError, "Missing"):
            evidence.verify(summary, tree)
        tree["testNodes"].remove(suite)
        with self.assertRaisesRegex(ValueError, "Missing"):
            evidence.verify(summary, tree)


if __name__ == "__main__":
    unittest.main()
