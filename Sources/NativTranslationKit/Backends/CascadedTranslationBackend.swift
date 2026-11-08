import Foundation

/// A local phrase cascade. Recognition and translation are complete-phrase operations;
/// only a renderer with measured chunk production advertises audio streaming.
public actor CascadedTranslationBackend: TranslationBackend {
    private let recognizer: any TranslationSpeechRecognizer
    private let translator: any TranslationTextTranslator
    private let speech: any TranslationSpeechRenderer
    private let responseTimeout: Duration
    private var configuration: TranslationConfiguration?
    private var sessionID: TranslationSessionID?
    private var generation = TranslationGeneration()
    private var incarnation = UUID()
    private var turnID: TranslationTurnID?
    private var pcm = Data()
    private var seconds: Double = 0
    private var previousFrame: OwnedPCMFrame?
    private var producer: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<TranslationEvent, Error>.Continuation?
    public static let inputFormat = TranslationPCMFormat(sampleRate: 16_000, channels: 1, encoding: .signedInt16LittleEndian)

    public init(recognizer: any TranslationSpeechRecognizer, translator: any TranslationTextTranslator,
                speech: any TranslationSpeechRenderer, responseTimeout: Duration = .seconds(90)) {
        self.recognizer = recognizer; self.translator = translator; self.speech = speech
        self.responseTimeout = responseTimeout
    }

    public func prepare(configuration: TranslationConfiguration) async throws -> TranslationCapabilities {
        await stop()
        try configuration.buffering.validate()
        guard configuration.provider == .localCascade, configuration.directionMode == .fixed,
              configuration.languagePair.source != configuration.languagePair.target else {
            throw failure(.invalidConfiguration, "Choose a fixed direction with two different languages for the local cascade.")
        }
        let pair = configuration.languagePair
        guard recognizer.supportedLanguages.contains(pair.source), translator.supportedLanguages.contains(pair.source),
              translator.supportedLanguages.contains(pair.target) else {
            throw failure(.unsupportedLanguage, "The selected recognition or translation model does not document this language. Choose a compatible model explicitly.")
        }
        let spoken = configuration.outputMode == .speechAndCaptions
        guard !spoken || speech.supportedLanguages.contains(pair.target) else {
            throw failure(.unsupportedLanguage, "The selected speech model or voice does not support the target language. Choose a compatible voice or captions.")
        }
        self.configuration = configuration
        return .init(inputLanguages: recognizer.supportedLanguages.intersection(translator.supportedLanguages),
                     outputLanguages: spoken ? translator.supportedLanguages.intersection(speech.supportedLanguages) : translator.supportedLanguages,
                     qualifiedTranslationPairs: [], supportsTextOutput: true, supportsAudioOutput: spoken,
                     sourceTranscriptAvailable: true, inputStreaming: false, outputStreaming: spoken && speech.streamsAudio,
                     interruptionBehavior: .freshContextRequired, trueDuplex: false, inputFormat: Self.inputFormat)
    }

    public func start(sessionID: TranslationSessionID, generation: TranslationGeneration) async throws -> AsyncThrowingStream<TranslationEvent, Error> {
        guard configuration != nil else { throw failure(.invalidState, "Prepare the local cascade before starting.") }
        await stop()
        self.sessionID = sessionID; self.generation = generation
        let token = UUID(); incarnation = token
        let pair = AsyncThrowingStream<TranslationEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        continuation = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.consumerEnded(token: token) }
        }
        return pair.stream
    }

    public func send(frame: OwnedPCMFrame) async throws {
        guard frame.sessionID == sessionID, frame.generation == generation, continuation != nil else {
            throw failure(.staleInput, "The audio belongs to an inactive translation session.")
        }
        guard producer == nil, turnID == nil || turnID == frame.turnID else {
            throw failure(.invalidState, "A cascade response is already active; retain only the bounded waiting turn.")
        }
        guard frame.format == Self.inputFormat else { throw failure(.invalidAudio, "The cascade expects mono 16 kHz PCM16.") }
        if let previousFrame {
            guard frame.sequence > previousFrame.sequence, frame.captureTimestampNanoseconds >= previousFrame.captureTimestampNanoseconds,
                  frame.sourceID == previousFrame.sourceID else { throw failure(.invalidAudio, "Input PCM order or source changed inside the turn.") }
        }
        let duration = try frame.format.duration(byteCount: frame.bytes.count)
        guard seconds + duration <= 12.000001 else { throw failure(.overload, "The cascade input exceeded twelve seconds. Repeat the incomplete interval.") }
        turnID = frame.turnID; pcm.append(frame.bytes); seconds += duration; previousFrame = frame
    }

    public func commit(turnID: TranslationTurnID) async throws {
        guard let configuration, self.turnID == turnID, !pcm.isEmpty, producer == nil, continuation != nil else {
            throw failure(.invalidState, "There is no complete input turn ready for translation.")
        }
        let token = incarnation; let input = pcm
        pcm.removeAll(keepingCapacity: false); previousFrame = nil
        let started = ContinuousClock.now
        producer = Task { [weak self, recognizer, translator, speech] in
            do {
                let source = try await recognizer.transcribe(pcm: input, format: Self.inputFormat, language: configuration.languagePair.source)
                try Task.checkCancellation()
                guard let self else { return }
                try await self.emitText(source, source: true, token: token)
                let target = try await translator.translate(text: source, sourceLanguage: configuration.languagePair.source,
                                                            targetLanguage: configuration.languagePair.target)
                try Task.checkCancellation()
                try await self.emitText(target, source: false, token: token)
                try await self.emit(.metrics(.init(name: .firstCaptionMilliseconds, value: Self.milliseconds(since: started))), token: token)
                if configuration.outputMode == .speechAndCaptions {
                    let stream = try await speech.synthesize(text: target, language: configuration.languagePair.target, budget: configuration.audioTransportBudget)
                    var previous: UInt64?
                    for try await chunk in stream {
                        try Task.checkCancellation()
                        guard chunk.committed, previous.map({ chunk.sequence > $0 }) ?? true,
                              try chunk.format.duration(byteCount: chunk.bytes.count) <= 5 else {
                            throw TranslationFailure(code: .invalidAudio, message: "The speech renderer emitted an invalid or uncommitted chunk.")
                        }
                        if previous == nil {
                            try await self.emit(.metrics(.init(name: .firstAudioMilliseconds, value: Self.milliseconds(since: started))), token: token)
                        }
                        previous = chunk.sequence
                        try await self.emit(.audio(try chunk.admitted(to: configuration.audioTransportBudget)), token: token)
                    }
                    guard previous != nil else { throw TranslationFailure(code: .incompleteTurn, message: "The speech model returned no playable audio.") }
                }
                try await self.complete(token: token)
            } catch is CancellationError { }
            catch { await self?.failed(error, token: token) }
        }
        watchdog = Task { [weak self, responseTimeout] in
            do { try await Task.sleep(for: responseTimeout); await self?.expired(token: token) } catch { }
        }
    }

    public func cancel(turnID: TranslationTurnID) async {
        guard self.turnID == turnID else { return }
        await stop()
    }
    public func stop() async {
        incarnation = UUID()
        producer?.cancel(); producer = nil; watchdog?.cancel(); watchdog = nil
        continuation?.finish(); continuation = nil
        sessionID = nil; turnID = nil; pcm.removeAll(); seconds = 0; previousFrame = nil
    }
    private func consumerEnded(token: UUID) async { if incarnation == token { await stop() } }
    private func emitText(_ text: String, source: Bool, token: UUID) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 32_768 else { throw failure(.incompleteTurn, "The local model returned empty or oversized text.") }
        // Spoken commands remain text. Reject tool encodings instead of executing them or speaking markup.
        var guardrail = LFMInterpreterTextGuard(); _ = try guardrail.append(text); _ = try guardrail.finish()
        try emit(source ? .sourceText(.init(text: text, stability: .final)) : .translationText(.init(text: text, stability: .final)), token: token)
    }
    private func emit(_ payload: TranslationEvent.Payload, token: UUID) throws {
        guard token == incarnation, let sessionID, let continuation, !Task.isCancelled else { throw CancellationError() }
        switch continuation.yield(.init(sessionID: sessionID, turnID: turnID, generation: generation, payload: payload)) {
        case .enqueued: break
        case .dropped: throw failure(.consumerOverload, "Translation output exceeded the bounded queue. Repeat the incomplete turn.")
        case .terminated: throw CancellationError()
        @unknown default: throw CancellationError()
        }
    }
    private func complete(token: UUID) throws {
        try emit(.turnCompleted, token: token)
        turnID = nil; seconds = 0; producer = nil; watchdog?.cancel(); watchdog = nil
    }
    private func failed(_ error: Error, token: UUID) {
        guard token == incarnation else { return }
        let error = (error as? TranslationFailure) ?? failure(.providerFailure, "A local cascade model failed. Check its installation and available memory, then retry.")
        incarnation = UUID(); continuation?.finish(throwing: error); continuation = nil
        producer?.cancel(); producer = nil; watchdog?.cancel(); watchdog = nil
        turnID = nil; pcm.removeAll(); previousFrame = nil; seconds = 0
    }
    private func expired(token: UUID) { failed(failure(.providerFailure, "The local cascade exceeded its response time limit."), token: token) }
    private func failure(_ code: TranslationFailure.Code, _ message: String) -> TranslationFailure { .init(code: code, message: message) }
    private nonisolated static func milliseconds(since started: ContinuousClock.Instant) -> Double {
        let elapsed = started.duration(to: .now).components
        return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
    }
    deinit { producer?.cancel(); watchdog?.cancel(); continuation?.finish() }
}
