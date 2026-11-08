import AVFoundation
import Foundation
import NativTranslationKit
import XCTest

@MainActor
final class LiveTranslationIntegrationTests: XCTestCase {
    func testNativeOwnedCaptureAndEndpointingProduceACompletedCoreTurn() async throws {
        let format = TranslationPCMFormat(sampleRate: 16000, channels: 1, encoding: .signedInt16LittleEndian)
        let backend = IntegrationTranslationBackend()
        let session = TranslationSession(backend: backend)
        _ = try await session.prepare(configuration: .init(languagePair: .init(source: "nl", target: "en"), provider: .lfm3OmniDirect))
        let stream = try await session.start()
        let consumer = Task { for try await _ in stream { } }
        let snapshot = await session.snapshot()
        let bridge = try TranslationPCMBridge(format: format, context: .init(sessionID: snapshot.sessionID, generation: snapshot.generation))
        let segmenter = TranslationSpeechSegmenter(detector: IntegrationVoiceDetector())
        let audioFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let borrowed = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: 320))
        borrowed.frameLength = 320
        for _ in 0..<21 {
            borrowed.floatChannelData![0].update(repeating: 0.25, count: 320)
            bridge.submit(borrowed)
            borrowed.floatChannelData![0].update(repeating: -0.5, count: 320)
            let owned = try XCTUnwrap(bridge.take())
            XCTAssertEqual(owned.bytes.prefix(2), Data([0, 32]))
            for event in try await segmenter.consume(owned) {
                switch event {
                case .audio(let frame): try await session.accept(frame: frame)
                case .commit(let turnID, _): try await session.commit(turnID: turnID)
                }
            }
            bridge.didConsume(owned)
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while await session.snapshot().transcript.turns.isEmpty, clock.now < deadline { await Task.yield() }
        let completed = await session.snapshot()
        XCTAssertEqual(completed.transcript.turns.count, 1)
        XCTAssertEqual(completed.transcript.turns.first?.translatedText, "The appointment is at half past three.")
        XCTAssertNil(completed.transcript.turns.first?.sourceText, "A provider without source transcription must not manufacture it")
        let frameCount = await backend.receivedFrames
        XCTAssertEqual(frameCount, 21)
        await session.stop()
        _ = try await consumer.value
    }

    func testPreferencesRequireExplicitExperimentalAndAppleSelection() throws {
        let suite = "nativ.translation.integration." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = LiveTranslationSettings(defaults: defaults)
        XCTAssertFalse(settings.value.experimentalAccepted)
        XCTAssertEqual(settings.value.provider, .lfm3OmniDirect)
        XCTAssertEqual(settings.value.speechProvider, .omni)
        XCTAssertEqual(settings.value.source, .microphone)
        XCTAssertEqual(settings.value.output, .speechAndCaptions)
        settings.value.provider = .localCascade
        settings.value.speechProvider = .apple
        settings.value.appleVoiceID = "explicit-test-voice"
        let reloaded = LiveTranslationSettings(defaults: defaults)
        XCTAssertEqual(reloaded.value.speechProvider, .apple)
        XCTAssertEqual(reloaded.value.appleVoiceID, "explicit-test-voice")
        XCTAssertFalse(reloaded.value.experimentalAccepted)
        XCTAssertEqual(defaults.persistentDomain(forName: suite)?.count, 1, "Only explicit preferences should persist")
    }

    func testExistingPreferencesMigrateWithoutLosingExplicitSelections() throws {
        let data = Data(#"{"sourceLanguage":"fr","targetLanguage":"de","speechProvider":"apple","appleVoiceID":"chosen","headphones":true,"experimentalAccepted":true}"#.utf8)
        let value = try JSONDecoder().decode(LiveTranslationSettings.Value.self, from: data)
        XCTAssertEqual(value.sourceLanguage, "fr")
        XCTAssertEqual(value.targetLanguage, "de")
        XCTAssertEqual(value.speechProvider, .apple)
        XCTAssertEqual(value.appleVoiceID, "chosen")
        XCTAssertTrue(value.headphones)
        XCTAssertTrue(value.experimentalAccepted)
        XCTAssertEqual(value.speechModel, "")
        XCTAssertEqual(value.speechReferenceText, "")
        XCTAssertEqual(value.directionMode, .fixed)
        XCTAssertEqual(try JSONDecoder().decode(LiveTranslationSettings.Value.self, from: JSONEncoder().encode(value)), value)
    }

    func testDirectionAndVoiceChangesInvalidateRetainedTurnButPresentationDoesNot() {
        let initial = LiveTranslationSettings.Value()
        var changed = initial
        changed.overlay.toggle()
        XCTAssertFalse(changed.requiresFreshSession(comparedTo: initial))
        changed.sourceLanguage = "de"
        XCTAssertTrue(changed.requiresFreshSession(comparedTo: initial))
        changed = initial
        changed.speechProvider = .apple
        XCTAssertTrue(changed.requiresFreshSession(comparedTo: initial))
        changed = initial
        changed.outputDeviceID = 123
        XCTAssertTrue(changed.requiresFreshSession(comparedTo: initial))
    }
}

private final class IntegrationVoiceDetector: TranslationVoiceActivityDetecting, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func isSpeech(_ samples: [Int16]) throws -> Bool { lock.withLock { calls += 1; return calls == 1 } }
    func reset() { lock.withLock { calls = 0 } }
}
private actor IntegrationTranslationBackend: TranslationBackend {
    private var continuation: AsyncThrowingStream<TranslationEvent, Error>.Continuation?
    private var sessionID = TranslationSessionID()
    private var generation = TranslationGeneration()
    private(set) var receivedFrames = 0
    func prepare(configuration: TranslationConfiguration) async throws -> TranslationCapabilities {
        .init(inputLanguages: ["nl"], outputLanguages: ["en"], supportsAudioOutput: true,
              inputFormat: .init(sampleRate: 16000, channels: 1, encoding: .signedInt16LittleEndian))
    }
    func start(sessionID: TranslationSessionID, generation: TranslationGeneration) async throws -> AsyncThrowingStream<TranslationEvent, Error> {
        self.sessionID = sessionID; self.generation = generation
        let pair = AsyncThrowingStream<TranslationEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(8))
        continuation = pair.continuation
        return pair.stream
    }
    func send(frame: OwnedPCMFrame) async throws { receivedFrames += 1 }
    func commit(turnID: TranslationTurnID) async throws {
        continuation?.yield(.init(sessionID: sessionID, turnID: turnID, generation: generation,
                                  payload: .translationText(.init(text: "The appointment is at half past three.", stability: .final))))
        continuation?.yield(.init(sessionID: sessionID, turnID: turnID, generation: generation, payload: .turnCompleted))
    }
    func cancel(turnID: TranslationTurnID) async { }
    func stop() async { continuation?.finish(); continuation = nil }
}
