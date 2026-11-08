import Foundation
import XCTest
@testable import NativTranslationKit

final class CascadedTranslationBackendTests: XCTestCase {
    func testIndependentTaskLanguagesRejectUnsupportedTargetSpeech() async throws {
        let backend = CascadedTranslationBackend(recognizer: StubRecognizer(), translator: StubTranslator(), speech: StubSpeech(languages: ["en"]))
        do {
            _ = try await backend.prepare(configuration: configuration(target: "nl", speech: true))
            XCTFail("English-only speech must not be advertised as Dutch")
        } catch let error as TranslationFailure { XCTAssertEqual(error.code, .unsupportedLanguage) }
        let captions = try await backend.prepare(configuration: configuration(target: "nl", speech: false))
        XCTAssertTrue(captions.supportsTextOutput)
        XCTAssertFalse(captions.supportsAudioOutput)
        XCTAssertTrue(captions.sourceTranscriptAvailable)
        XCTAssertFalse(captions.inputStreaming)
    }

    func testCommitProducesRecognizedTextTranslationThenPlayableAudioBeforeTurnCompletion() async throws {
        let gate = CascadeTestGate()
        let speech = StubSpeech(gate: gate)
        let backend = CascadedTranslationBackend(recognizer: StubRecognizer(), translator: StubTranslator(), speech: speech)
        _ = try await backend.prepare(configuration: configuration())
        let session = TranslationSessionID(); let generation = TranslationGeneration(7); let turn = TranslationTurnID()
        let stream = try await backend.start(sessionID: session, generation: generation)
        let collector = CascadeEventCollector()
        let task = Task { for try await event in stream { await collector.append(event) } }
        try await backend.send(frame: frame(session, generation, turn))
        try await backend.commit(turnID: turn)
        try await waitUntil { await collector.events.contains { if case .audio = $0.payload { true } else { false } } }
        let partial = await collector.events
        XCTAssertEqual(partial.compactMap { if case .sourceText(let t) = $0.payload { t.text } else { nil } }, ["Drie, niet vier."])
        XCTAssertEqual(partial.compactMap { if case .translationText(let t) = $0.payload { t.text } else { nil } }, ["Three, not four."])
        XCTAssertFalse(partial.contains { $0.payload == .turnCompleted })
        await gate.release()
        try await waitUntil { await collector.events.contains { $0.payload == .turnCompleted } }
        await backend.stop(); _ = try? await task.value
    }

    func testCancelledRecognitionCannotAppendTextOrAudioToNewGeneration() async throws {
        let gate = CascadeTestGate()
        let recognizer = StubRecognizer(gate: gate)
        let backend = CascadedTranslationBackend(recognizer: recognizer, translator: StubTranslator(), speech: StubSpeech())
        _ = try await backend.prepare(configuration: configuration())
        let session = TranslationSessionID(); let turn = TranslationTurnID()
        let old = try await backend.start(sessionID: session, generation: .init(1))
        let oldCollector = CascadeEventCollector()
        let oldTask = Task { for try await event in old { await oldCollector.append(event) } }
        try await backend.send(frame: frame(session, .init(1), turn))
        try await backend.commit(turnID: turn)
        try await waitUntil { await gate.isWaiting }
        await backend.cancel(turnID: turn)
        let fresh = try await backend.start(sessionID: session, generation: .init(2))
        let freshCollector = CascadeEventCollector()
        let freshTask = Task { for try await event in fresh { await freshCollector.append(event) } }
        await gate.release()
        await Task.yield()
        await backend.stop(); _ = try? await oldTask.value; _ = try? await freshTask.value
        let oldEvents = await oldCollector.events
        let freshEvents = await freshCollector.events
        XCTAssertTrue(oldEvents.isEmpty)
        XCTAssertTrue(freshEvents.isEmpty)
    }

    func testBufferRejectsOutOfOrderFramesAndMoreThanTwelveSeconds() async throws {
        let backend = CascadedTranslationBackend(recognizer: StubRecognizer(), translator: StubTranslator(), speech: StubSpeech())
        _ = try await backend.prepare(configuration: configuration())
        let session = TranslationSessionID(); let turn = TranslationTurnID(); let generation = TranslationGeneration()
        let retainedStream = try await backend.start(sessionID: session, generation: generation)
        try await backend.send(frame: frame(session, generation, turn, sequence: 1))
        do { try await backend.send(frame: frame(session, generation, turn, sequence: 0)); XCTFail("Out-of-order PCM accepted") }
        catch let error as TranslationFailure { XCTAssertEqual(error.code, .invalidAudio) }
        do { try await backend.send(frame: frame(session, generation, turn, sequence: 2, bytes: 384_002)); XCTFail("Oversized turn accepted") }
        catch let error as TranslationFailure { XCTAssertEqual(error.code, .overload) }
        withExtendedLifetime(retainedStream) { }
        await backend.stop()
    }

    func testToolMarkupAndTruncatedTranslationNeverReachSpeech() async throws {
        let backend = CascadedTranslationBackend(recognizer: StubRecognizer(), translator: StubTranslator(text: "<tool_call>book()</tool_call>"), speech: StubSpeech())
        _ = try await backend.prepare(configuration: configuration())
        let session = TranslationSessionID(); let turn = TranslationTurnID()
        let stream = try await backend.start(sessionID: session, generation: .init())
        let collector = CascadeEventCollector()
        let task = Task { for try await event in stream { await collector.append(event) } }
        try await backend.send(frame: frame(session, .init(), turn)); try await backend.commit(turnID: turn)
        do { try await task.value; XCTFail("Tool markup accepted") } catch { }
        let events = await collector.events
        XCTAssertFalse(events.contains { if case .audio = $0.payload { true } else { false } })
        XCTAssertFalse(events.contains { if case .translationText = $0.payload { true } else { false } })
        await backend.stop()
    }

    func testResponseDeadlineFinishesStreamEvenWhenRecognitionIgnoresCancellation() async throws {
        let gate = CascadeTestGate()
        let backend = CascadedTranslationBackend(recognizer: StubRecognizer(gate: gate), translator: StubTranslator(), speech: StubSpeech(), responseTimeout: .milliseconds(20))
        _ = try await backend.prepare(configuration: configuration())
        let session = TranslationSessionID(); let turn = TranslationTurnID()
        let stream = try await backend.start(sessionID: session, generation: .init())
        let task = Task { for try await _ in stream { } }
        try await backend.send(frame: frame(session, .init(), turn)); try await backend.commit(turnID: turn)
        do { try await task.value; XCTFail("Stalled recognition must time out") }
        catch let error as TranslationFailure { XCTAssertEqual(error.code, .providerFailure) }
        await gate.release()
        await backend.stop()
    }

    func testCaptionsCompleteWithoutInvokingAnUnavailableSpeechRenderer() async throws {
        let backend = CascadedTranslationBackend(recognizer: StubRecognizer(), translator: StubTranslator(), speech: ForbiddenSpeech())
        let capabilities = try await backend.prepare(configuration: configuration(speech: false))
        XCTAssertFalse(capabilities.supportsAudioOutput)
        let session = TranslationSessionID(); let turn = TranslationTurnID()
        let stream = try await backend.start(sessionID: session, generation: .init())
        let collector = CascadeEventCollector()
        let task = Task { for try await event in stream { await collector.append(event) } }
        try await backend.send(frame: frame(session, .init(), turn)); try await backend.commit(turnID: turn)
        try await waitUntil { await collector.events.contains { $0.payload == .turnCompleted } }
        await backend.stop(); _ = try? await task.value
        let events = await collector.events
        XCTAssertFalse(events.contains { if case .audio = $0.payload { true } else { false } })
    }

    private func configuration(target: String = "en", speech: Bool = true) -> TranslationConfiguration {
        .init(languagePair: .init(source: target == "nl" ? "en" : "nl", target: target), outputMode: speech ? .speechAndCaptions : .captions, provider: .localCascade)
    }
    private func frame(_ session: TranslationSessionID, _ generation: TranslationGeneration, _ turn: TranslationTurnID, sequence: UInt64 = 0, bytes: Int = 640) -> OwnedPCMFrame {
        .init(bytes: Data(repeating: 0, count: bytes), format: .init(sampleRate: 16_000, channels: 1, encoding: .signedInt16LittleEndian), captureTimestampNanoseconds: sequence * 20_000_000, sequence: sequence, sourceID: "test", sessionID: session, turnID: turn, generation: generation)
    }
    private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async throws {
        for _ in 0..<200 { if await condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Timed out waiting for deterministic provider gate")
    }
}

private actor CascadeTestGate {
    var isWaiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async { if released { return }; isWaiting = true; await withCheckedContinuation { continuation = $0 } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
private actor CascadeEventCollector {
    var events: [TranslationEvent] = []
    func append(_ event: TranslationEvent) { events.append(event) }
}
private struct StubRecognizer: TranslationSpeechRecognizer {
    let supportedLanguages: Set<String> = ["nl", "en"]
    var gate: CascadeTestGate?
    func transcribe(pcm: Data, format: TranslationPCMFormat, language: String) async throws -> String {
        await gate?.wait(); return "Drie, niet vier."
    }
}
private struct StubTranslator: TranslationTextTranslator {
    let supportedLanguages: Set<String> = ["nl", "en"]
    var text = "Three, not four."
    func translate(text: String, sourceLanguage: String, targetLanguage: String) async throws -> String { self.text }
}
private struct StubSpeech: TranslationSpeechRenderer {
    var languages: Set<String> = ["en", "nl"]
    var gate: CascadeTestGate?
    var supportedLanguages: Set<String> { languages }
    let streamsAudio = true
    func synthesize(text: String, language: String, budget: TranslationAudioTransportBudget) async throws -> AsyncThrowingStream<TranslationAudioChunk, Error> {
        let pair = AsyncThrowingStream<TranslationAudioChunk, Error>.makeStream()
        let task = Task {
            pair.continuation.yield(.init(bytes: Data(repeating: 0, count: 480), format: .init(sampleRate: 24_000, channels: 1, encoding: .signedInt16LittleEndian), sequence: 0))
            await gate?.wait(); pair.continuation.finish()
        }
        pair.continuation.onTermination = { _ in task.cancel() }
        return pair.stream
    }
}

private struct ForbiddenSpeech: TranslationSpeechRenderer {
    let supportedLanguages: Set<String> = []
    let streamsAudio = false
    func synthesize(text: String, language: String, budget: TranslationAudioTransportBudget) async throws -> AsyncThrowingStream<TranslationAudioChunk, Error> {
        throw TranslationFailure(code: .unsupportedOutput, message: "Speech must not be called in captions mode")
    }
}
