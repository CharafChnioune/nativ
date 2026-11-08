import Foundation
import XCTest
@testable import NativTranslationKit

final class TranslationAutomaticDirectionTests: XCTestCase {
    func testLanguageVariantsNormalizeWithoutSummingCorrelatedConfidence() {
        let text = "This sufficiently long fixture isolates the injected classifier."
        let chinese = TranslationAutomaticLanguageDetector(hypotheses: { _ in ["zh-Hans": 0.99, "zh-Hant": 0.3] })
        let accepted = chinese.detect(text: text, candidates: ["en", "zh"])
        XCTAssertEqual(accepted.language, "zh")
        XCTAssertEqual(accepted.confidence, 0.99)
        let uncertain = TranslationAutomaticLanguageDetector(hypotheses: { _ in ["zh-Hans": 0.55, "zh-Hant": 0.45] })
        XCTAssertNil(uncertain.detect(text: text, candidates: ["en", "zh"]).language)
        let unrelated = TranslationAutomaticLanguageDetector(hypotheses: { _ in ["fr-CA": 0.99] })
        XCTAssertNil(unrelated.detect(text: text, candidates: ["en", "zh"]).language)
        let cantonese = TranslationAutomaticLanguageDetector(hypotheses: { _ in ["yue": 0.99] })
        XCTAssertNil(cantonese.detect(text: text, candidates: ["en", "zh"]).language)
    }
    func testLanguageHeuristicsAbstainForShortMixedThirdLanguageAndWeakEvidence() {
        let confident = TranslationAutomaticLanguageDetector(hypotheses: { _ in ["en": 0.99] })
        XCTAssertNil(confident.detect(text: "Yes", candidates: ["en", "nl"]).language)
        let third = TranslationAutomaticLanguageDetector(hypotheses: { _ in ["fr": 0.99] })
        XCTAssertNil(third.detect(text: "Please bring the original document tomorrow morning.", candidates: ["en", "nl"]).language)
        let weak = TranslationAutomaticLanguageDetector(hypotheses: { _ in ["en": 0.65, "nl": 0.35] })
        XCTAssertNil(weak.detect(text: "Please bring the original document tomorrow morning.", candidates: ["en", "nl"]).language)
        let mixed = TranslationAutomaticLanguageDetector(hypotheses: { text in
            text == "morgen voor vijf uur" ? ["nl": 0.99] : ["en": 0.99]
        })
        XCTAssertNil(mixed.detect(text: "Please bring original documents morgen voor vijf uur", candidates: ["en", "nl"]).language)
        XCTAssertEqual(confident.detect(text: "Please bring the original document tomorrow morning.", candidates: ["en", "nl"]).language, "en")
    }
    func testAutomaticDirectionRequiresSeparateExplicitExperimentalConsent() async throws {
        let backend = makeBackend()
        var config = automaticConfiguration()
        config.allowExperimentalAutomaticDirection = false
        do { _ = try await backend.prepare(configuration: config); XCTFail("Unqualified automatic direction needs explicit consent") }
        catch let failure as TranslationFailure { XCTAssertEqual(failure.code, .invalidConfiguration) }
        config.allowExperimentalAutomaticDirection = true
        let capabilities = try await backend.prepare(configuration: config)
        XCTAssertTrue(capabilities.automaticDirectionAvailable)
        XCTAssertFalse(capabilities.automaticDirectionQualified)
        XCTAssertFalse(capabilities.retainsConversationContext)
    }

    func testAutomaticDirectionValidatesBothPossibleSpeechTargetsBeforeStart() async throws {
        let backend = makeBackend(speech: AutomaticSpeech(languages: ["en"]))
        do { _ = try await backend.prepare(configuration: automaticConfiguration()); XCTFail("Automatic direction cannot speak an unsupported reverse target") }
        catch let failure as TranslationFailure { XCTAssertEqual(failure.code, .unsupportedLanguage) }
    }

    func testSelectedDirectionUsesUnhintedRecognitionAndRoutesEachStage() async throws {
        let recognition = AutomaticRecognition()
        let translation = AutomaticTranslation()
        let speech = AutomaticSpeech()
        let backend = makeBackend(recognition: recognition, translation: translation, speech: speech)
        _ = try await backend.prepare(configuration: automaticConfiguration())
        let id = TranslationSessionID(); let turn = TranslationTurnID()
        let stream = try await backend.start(sessionID: id, generation: .init())
        let collected = AutoEvents()
        let reader = Task { do { for try await event in stream { await collected.add(event) } } catch {} }
        try await backend.send(frame: audio(id, turn)); try await backend.commit(turnID: turn)
        try await waitUntil { await collected.events.contains { $0.payload == .turnCompleted } }
        let automaticCalls = await recognition.automaticCalls
        XCTAssertEqual(automaticCalls, 1)
        let fixedCalls = await recognition.fixedCalls
        XCTAssertEqual(fixedCalls, 0)
        let pairs = await translation.pairs
        XCTAssertEqual(pairs, [.init(source: "en", target: "nl")])
        let spokenLanguages = await speech.requestedLanguages
        XCTAssertEqual(spokenLanguages, ["nl"])
        let directions = await collected.events.compactMap { event -> TranslationDirectionSelection? in
            if case .directionSelected(let value) = event.payload { return value }; return nil
        }
        XCTAssertEqual(directions.first?.pair, .init(source: "en", target: "nl"))
        XCTAssertEqual(directions.first?.qualified, false)
        await backend.stop(); await reader.value
    }

    func testAmbiguousRecognitionPreservesSourceAndAllowsExplicitCorrectedReplayWithoutSpeech() async throws {
        let recognition = AutomaticRecognition()
        let translation = AutomaticTranslation()
        let speech = AutomaticSpeech()
        let backend = makeBackend(recognition: recognition, translation: translation, speech: speech,
                                  detector: FixedDirectionDetector(language: nil, confidence: 0.5))
        let core = TranslationSession(backend: backend)
        _ = try await core.prepare(configuration: automaticConfiguration())
        let events = try await core.start()
        let collected = AutoEvents()
        let reader = Task { do { for try await event in events { await collected.add(event) } } catch {} }
        let snapshot = await core.snapshot(); let turn = TranslationTurnID()
        try await core.accept(frame: audio(snapshot.sessionID, turn)); try await core.commit(turnID: turn)
        try await waitUntil { await core.snapshot().lastFailure?.code == .ambiguousDirection }
        let failed = await core.snapshot()
        XCTAssertTrue(failed.canRetry)
        XCTAssertTrue(failed.canReplay)
        XCTAssertEqual(failed.transcript.turns.last?.sourceText, "Please bring the original document tomorrow morning.")
        let translatedPairs = await translation.pairs
        XCTAssertTrue(translatedPairs.isEmpty)
        let spokenLanguages = await speech.requestedLanguages
        XCTAssertTrue(spokenLanguages.isEmpty)
        _ = try await core.replayLastTurn(languagePair: .init(source: "en", target: "nl"))
        try await waitUntil { await speech.requestedLanguages == ["nl"] }
        let fixedCalls = await recognition.fixedCalls
        XCTAssertEqual(fixedCalls, 1)
        await core.stop(); await reader.value
    }

    func testConsecutiveStatelessCascadeTurnsDoNotResetResidentResources() async throws {
        let resources = AutoResources()
        let backend = CascadedTranslationBackend(recognizer: AutomaticRecognition(), translator: AutomaticTranslation(),
            speech: AutomaticSpeech(), resources: resources, languageDetector: FixedDirectionDetector(language: "en", confidence: 0.99))
        let core = TranslationSession(backend: backend)
        _ = try await core.prepare(configuration: automaticConfiguration())
        let stream = try await core.start()
        defer { withExtendedLifetime(stream) {} }
        let initial = await core.snapshot()
        for index in 0..<2 {
            let turn = TranslationTurnID()
            try await core.accept(frame: audio(initial.sessionID, turn, sequence: UInt64(index)))
            try await core.commit(turnID: turn)
            try await waitUntil { await core.snapshot().transcript.turns.count == index + 1 }
        }
        let begins = await resources.begins
        XCTAssertEqual(begins, 1)
        let invalidationsBeforeStop = await resources.activeInvalidations
        XCTAssertEqual(invalidationsBeforeStop, 0)
        await core.stop()
        let invalidationsAfterStop = await resources.activeInvalidations
        XCTAssertEqual(invalidationsAfterStop, 1)
    }

    private func makeBackend(recognition: AutomaticRecognition = .init(), translation: AutomaticTranslation = .init(),
                             speech: AutomaticSpeech = .init(), detector: FixedDirectionDetector = .init(language: "en", confidence: 0.99)) -> CascadedTranslationBackend {
        .init(recognizer: recognition, translator: translation, speech: speech, languageDetector: detector)
    }
    private func automaticConfiguration() -> TranslationConfiguration {
        .init(languagePair: .init(source: "nl", target: "en"), directionMode: .automatic,
              outputMode: .speechAndCaptions, provider: .localCascade, allowExperimentalAutomaticDirection: true)
    }
    private func audio(_ id: TranslationSessionID, _ turn: TranslationTurnID, sequence: UInt64 = 0) -> OwnedPCMFrame {
        .init(bytes: Data(repeating: 0, count: 640), format: CascadedTranslationBackend.inputFormat,
              captureTimestampNanoseconds: sequence * 20_000_000, sequence: sequence, sourceID: "fixture",
              sessionID: id, turnID: turn, generation: .init())
    }
    private func waitUntil(_ predicate: @Sendable () async -> Bool) async throws {
        for _ in 0..<1000 { if await predicate() { return }; try await Task.sleep(for: .milliseconds(2)) }
        XCTFail("Timed out waiting for automatic direction result")
    }
}

private struct FixedDirectionDetector: TranslationLanguageDetector {
    let language: String?
    let confidence: Double
    func detect(text: String, candidates: Set<String>) -> TranslationLanguageDetection { .init(language: language, confidence: confidence) }
}
private actor AutomaticRecognition: TranslationSpeechRecognizer {
    nonisolated let supportedLanguages: Set<String> = ["nl", "en"]
    nonisolated let supportsAutomaticRecognition = true
    var automaticCalls = 0
    var fixedCalls = 0
    func transcribe(pcm: Data, format: TranslationPCMFormat, language: String) async throws -> String {
        fixedCalls += 1; return "Please bring the original document tomorrow morning."
    }
    func transcribeAutomatically(pcm: Data, format: TranslationPCMFormat) async throws -> String {
        automaticCalls += 1; return "Please bring the original document tomorrow morning."
    }
}
private actor AutomaticTranslation: TranslationTextTranslator {
    nonisolated let supportedLanguages: Set<String> = ["nl", "en"]
    var pairs: [TranslationLanguagePair] = []
    func translate(text: String, sourceLanguage: String, targetLanguage: String) async throws -> String {
        pairs.append(.init(source: sourceLanguage, target: targetLanguage)); return "Breng het originele document morgenochtend alstublieft mee."
    }
}
private actor AutomaticSpeech: TranslationSpeechRenderer {
    nonisolated let supportedLanguages: Set<String>
    nonisolated let streamsAudio = false
    var requestedLanguages: [String] = []
    init(languages: Set<String> = ["nl", "en"]) { supportedLanguages = languages }
    func synthesize(text: String, language: String, budget: TranslationAudioTransportBudget) async throws -> AsyncThrowingStream<TranslationAudioChunk, Error> {
        requestedLanguages.append(language)
        let pair = AsyncThrowingStream<TranslationAudioChunk, Error>.makeStream()
        pair.continuation.yield(.init(bytes: Data(repeating: 0, count: 320), format: CascadedTranslationBackend.inputFormat, sequence: 0))
        pair.continuation.finish()
        return pair.stream
    }
}
private actor AutoEvents {
    var events: [TranslationEvent] = []
    func add(_ event: TranslationEvent) { events.append(event) }
}
private actor AutoResources: TranslationCascadeResources {
    var begins = 0
    var activeInvalidations = 0
    var current: UUID?
    func begin(generation: UUID) async throws { begins += 1; current = generation }
    func acquire(_ stage: TranslationCascadeStage, generation: UUID) async throws -> TranslationCascadeLease { .init(generation: generation, stage: stage) }
    func release(_ lease: TranslationCascadeLease) async {}
    func invalidate(generation: UUID) async { if current == generation { activeInvalidations += 1; current = nil } }
}
