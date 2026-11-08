import Foundation
import XCTest
#if canImport(TranslationHost)
@testable import TranslationHost
#endif

@MainActor
final class TranslationStageCatalogTests: XCTestCase {
    func testRecognitionAndSpeechLanguageClaimsAreIndependent() {
        let asr = TranslationStageCatalog.describe(modelID: "fixture/qwen-asr", configuration: ["model_type": "qwen3_asr", "support_languages": ["Dutch", "English", "German"]], role: .recognition, taskAvailable: true)
        let speech = TranslationStageCatalog.describe(modelID: "fixture/qwen-speech", configuration: qwenSpeech(), role: .speech, taskAvailable: true)
        XCTAssertTrue(asr.languages.contains("nl"))
        XCTAssertEqual(asr.requestLanguage("nl"), "Dutch")
        XCTAssertFalse(speech.languages.contains("nl"))
        XCTAssertTrue(speech.languages.contains("en"))
        XCTAssertEqual(speech.requestLanguage("en"), "english")
        XCTAssertFalse(speech.streamsAudio)
    }
    func testParakeetVersionDoesNotPromoteEnglishCheckpointToMultilingual() {
        let v2 = TranslationStageCatalog.describe(modelID: "mlx-community/parakeet-tdt-0.6b-v2", configuration: ["model_type": "parakeet"], role: .recognition, taskAvailable: true)
        let v3 = TranslationStageCatalog.describe(modelID: "mlx-community/parakeet-tdt-0.6b-v3", configuration: ["model_type": "parakeet"], role: .recognition, taskAvailable: true)
        let other = TranslationStageCatalog.describe(modelID: "fixture/parakeet-finetune", configuration: ["model_type": "parakeet"], role: .recognition, taskAvailable: true)
        XCTAssertEqual(v2.languages, ["en"])
        XCTAssertTrue(v3.languages.contains("nl"))
        XCTAssertEqual(v3.languages.count, 25)
        XCTAssertNil(v3.requestLanguage("nl"))
        XCTAssertFalse(other.isSelectable)
    }
    func testDifferentLocalLLMFamiliesRemainExperimentalAndIndependentlySelectable() {
        for family in ["gemma4", "qwen3", "qwen3_5", "lfm2", "llama", "mistral"] {
            let model = TranslationStageCatalog.describe(modelID: "fixture/\(family)-instruct", configuration: ["model_type": family], role: .translation, taskAvailable: true)
            XCTAssertTrue(model.isSelectable, family)
            XCTAssertEqual(model.languageEvidence, .experimental)
            XCTAssertTrue(model.languages.isEmpty, "A loader must not fabricate a documented language list.")
        }
        let embedder = TranslationStageCatalog.describe(modelID: "fixture/embedder", configuration: ["model_type": "qwen3"], role: .translation, taskAvailable: false)
        XCTAssertFalse(embedder.isSelectable)
    }
    func testQwenBaseAndCustomVoiceHaveDifferentReferenceRequirements() {
        let custom = TranslationStageCatalog.describe(modelID: "fixture/custom", configuration: qwenSpeech(), role: .speech, taskAvailable: true)
        XCTAssertEqual(custom.voices, ["ryan", "vivian"])
        XCTAssertFalse(custom.requiresReference)
        XCTAssertTrue(TranslationStageCatalog.voiceSupports(language: "en", voice: "ryan", descriptor: custom))
        XCTAssertFalse(TranslationStageCatalog.voiceSupports(language: "en", voice: "invented", descriptor: custom))
        let base = TranslationStageCatalog.describe(modelID: "fixture/base", configuration: qwenSpeech(kind: "base"), role: .speech, taskAvailable: true)
        XCTAssertTrue(base.requiresReference)
        XCTAssertTrue(base.requiresReferenceText)
        let design = TranslationStageCatalog.describe(modelID: "fixture/design", configuration: qwenSpeech(kind: "voice_design"), role: .speech, taskAvailable: true)
        XCTAssertFalse(design.isSelectable)
    }
    func testKokoroIsNotAdvertisedWhenBundledG2PAssetsAreMissing() {
        let model = TranslationStageCatalog.describe(modelID: "fixture/kokoro", configuration: ["model_type": "kokoro"], role: .speech, taskAvailable: true)
        XCTAssertFalse(model.languages.contains("nl"))
        XCTAssertFalse(model.isSelectable)
        XCTAssertTrue(model.preparationIssues.contains { $0.contains("Misaki") })
    }
    func testWhisperAndChatterboxVariantsKeepTheirActualLanguageLimits() {
        let english = TranslationStageCatalog.describe(modelID: "fixture/whisper.en", configuration: ["model_type": "whisper", "n_vocab": 51864], role: .recognition, taskAvailable: true)
        let multilingual = TranslationStageCatalog.describe(modelID: "fixture/whisper", configuration: ["model_type": "whisper", "n_vocab": 51865], role: .recognition, taskAvailable: true)
        XCTAssertEqual(english.languages, ["en"])
        XCTAssertTrue(multilingual.languages.contains("nl"))
        let regular = TranslationStageCatalog.describe(modelID: "fixture/chatterbox", configuration: ["model_type": "chatterbox"], role: .speech, taskAvailable: true)
        let multi = TranslationStageCatalog.describe(modelID: "fixture/chatterbox-multi", configuration: ["model_type": "chatterbox", "multilingual": true], role: .speech, taskAvailable: true)
        XCTAssertEqual(regular.languages, ["en"])
        XCTAssertTrue(multi.languages.contains("nl"))
        XCTAssertTrue(multi.requiresReference)
        XCTAssertFalse(multi.streamsAudio)
    }
    func testWhisperVocabularyDeterminesWhetherCantoneseExists() {
        for (vocabulary, count, hasCantonese) in [(51864, 1, false), (51865, 99, false), (51866, 100, true)] {
            let model = TranslationStageCatalog.describe(modelID: "fixture/whisper", configuration: ["model_type": "whisper", "n_vocab": vocabulary], role: .recognition, taskAvailable: true)
            XCTAssertTrue(model.isSelectable)
            XCTAssertEqual(model.languages.count, count, "Vocabulary \(vocabulary)")
            XCTAssertEqual(model.languages.contains("yue"), hasCantonese)
            XCTAssertEqual(model.languages.contains("nl"), vocabulary > 51864)
        }
    }
    func testWhisperHuggingFaceDimensionsFollowTheBundledLoaderPrecedence() {
        for marker in ["d_model", "encoder_layers"] {
            for vocabulary in [51864, 51865, 51866] {
                let native = TranslationStageCatalog.describe(modelID: "fixture/native", configuration: ["model_type": "whisper", "n_vocab": vocabulary], role: .recognition, taskAvailable: true)
                // The loader switches to HF dimensions when either marker is present.
                // An unrelated native n_vocab must not override vocab_size then.
                let hf = TranslationStageCatalog.describe(modelID: "fixture/hf", configuration: ["model_type": "whisper", marker: 32, "vocab_size": vocabulary, "n_vocab": 51864], role: .recognition, taskAvailable: true)
                XCTAssertEqual(hf.languages, native.languages)
                XCTAssertEqual(hf.isSelectable, native.isSelectable)
            }
        }
        let native = TranslationStageCatalog.describe(modelID: "fixture/native", configuration: ["model_type": "whisper", "n_vocab": 51865, "vocab_size": 51866], role: .recognition, taskAvailable: true)
        XCTAssertFalse(native.languages.contains("yue"), "Without an HF dimension marker the native vocabulary applies.")
    }
    func testWhisperWithoutReviewedVocabularyDoesNotInventLanguageSupport() {
        let configurations: [[String: Any]] = [
            ["model_type": "whisper"],
            ["model_type": "whisper", "n_vocab": "51866"],
            ["model_type": "whisper", "n_vocab": -1],
            ["model_type": "whisper", "n_vocab": 60000],
            ["model_type": "whisper", "d_model": 1280],
            ["model_type": "whisper", "encoder_layers": 32, "vocab_size": "51866"],
        ]
        for configuration in configurations {
            let model = TranslationStageCatalog.describe(modelID: "fixture/incomplete", configuration: configuration, role: .recognition, taskAvailable: true)
            XCTAssertFalse(model.isSelectable)
            XCTAssertTrue(model.languages.isEmpty)
            XCTAssertFalse(model.preparationIssues.isEmpty)
        }
    }
    func testWrongTaskAndUnknownAudioFamilyDoNotBecomeGenericAdapters() {
        let wrong = TranslationStageCatalog.describe(modelID: "fixture/model", configuration: ["model_type": "whisper"], role: .speech, taskAvailable: false)
        let unknown = TranslationStageCatalog.describe(modelID: "fixture/new-audio", configuration: ["model_type": "unreviewed"], role: .speech, taskAvailable: true)
        XCTAssertFalse(wrong.isSelectable)
        XCTAssertFalse(unknown.isSelectable)
    }
    func testSpeechAuxiliaryArtifactsHaveImmutableRevisionAndIntegrityPins() throws {
        XCTAssertEqual(TranslationSpeechPreparation.tokenizerRevision.count, 40)
        XCTAssertEqual(TranslationSpeechPreparation.characterMapRevision.count, 40)
        for artifact in TranslationSpeechPreparation.tokenizerArtifacts + [TranslationSpeechPreparation.characterMap] {
            XCTAssertNoThrow(try artifact.validate())
        }
        XCTAssertEqual(TranslationSpeechPreparation.tokenizerArtifacts.first { $0.filename == "model.safetensors" }?.size, 494_868_984)
    }
    func testMissingPreparedSpeechAssetsFailWithoutWritingOrDownloading() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        do {
            _ = try await TranslationSpeechPreparation.preparedChatterbox(snapshot: cache.appendingPathComponent("selected"), cache: cache, multilingual: true)
            XCTFail("Absent speech assets must not be prepared implicitly at Start")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        }
    }
    private func qwenSpeech(kind: String = "custom_voice") -> [String: Any] {
        ["model_type": "qwen3_tts", "tts_model_type": kind, "talker_config": ["codec_language_id": ["english": 2050, "chinese": 2055], "spk_id": kind == "custom_voice" ? ["ryan": 1, "vivian": 2] : [:]]]
    }
}
