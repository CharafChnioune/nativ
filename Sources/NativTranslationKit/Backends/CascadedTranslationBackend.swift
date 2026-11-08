import Foundation

/// A local phrase cascade. Recognition and translation are complete-phrase operations;
/// only a renderer with measured chunk production advertises audio streaming.
public actor CascadedTranslationBackend: TranslationBackend {
    private let recognizer: any TranslationSpeechRecognizer
    private let translator: any TranslationTextTranslator
    private let speech: any TranslationSpeechRenderer
    private let contentGuard: TranslationContentGuard
    private let languageDetector: any TranslationLanguageDetector
    private let responseTimeout: Duration
    private let resources: (any TranslationCascadeResources)?
    private var configuration: TranslationConfiguration?
    private var sessionID: TranslationSessionID?
    private var generation = TranslationGeneration()
    private var incarnation = UUID()
    private var operationID = UUID()
    private var turnID: TranslationTurnID?
    private var pcm = Data()
    private var seconds: Double = 0
    private var previousFrame: OwnedPCMFrame?
    private var producer: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<TranslationEvent, Error>.Continuation?
    public static let inputFormat = TranslationPCMFormat(sampleRate: 16_000, channels: 1, encoding: .signedInt16LittleEndian)

    public init(recognizer: any TranslationSpeechRecognizer, translator: any TranslationTextTranslator,
                speech: any TranslationSpeechRenderer, responseTimeout: Duration = .seconds(90),
                resources: (any TranslationCascadeResources)? = nil, contentGuard: TranslationContentGuard = .init(),
                languageDetector: any TranslationLanguageDetector = TranslationAutomaticLanguageDetector()) {
        self.recognizer = recognizer; self.translator = translator; self.speech = speech
        self.responseTimeout = responseTimeout; self.resources = resources; self.contentGuard = contentGuard
        self.languageDetector = languageDetector
    }

    public func prepare(configuration: TranslationConfiguration) async throws -> TranslationCapabilities {
        let operation = UUID(); operationID = operation
        await stopCurrentSession()
        guard operationID == operation, !Task.isCancelled else { throw CancellationError() }
        try configuration.buffering.validate()
        guard configuration.provider == .localCascade,
              configuration.languagePair.source != configuration.languagePair.target else {
            throw failure(.invalidConfiguration, "Choose two different languages for the local cascade.")
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
        let automaticAvailable = recognizer.supportsAutomaticRecognition
            && recognizer.supportedLanguages.contains(pair.target)
            && (!spoken || speech.supportedLanguages.contains(pair.source))
        if configuration.directionMode == .automatic {
            guard configuration.allowExperimentalAutomaticDirection else {
                throw failure(.invalidConfiguration, "Automatic direction is unqualified. Explicitly accept its experimental limits or choose a fixed direction.")
            }
            guard automaticAvailable else {
                throw failure(.unsupportedLanguage, "Automatic direction requires unhinted recognition and compatible ASR, translation and speech for both directions. Choose different models or fixed direction explicitly.")
            }
        }
        self.configuration = configuration
        return .init(inputLanguages: recognizer.supportedLanguages.intersection(translator.supportedLanguages),
                     outputLanguages: spoken ? translator.supportedLanguages.intersection(speech.supportedLanguages) : translator.supportedLanguages,
                     qualifiedTranslationPairs: [], supportsTextOutput: true, supportsAudioOutput: spoken,
                     sourceTranscriptAvailable: true, inputStreaming: false, outputStreaming: spoken && speech.streamsAudio,
                     interruptionBehavior: .freshContextRequired, trueDuplex: false, inputFormat: Self.inputFormat,
                     automaticDirectionAvailable: automaticAvailable, retainsConversationContext: false)
    }

    public func start(sessionID: TranslationSessionID, generation: TranslationGeneration) async throws -> AsyncThrowingStream<TranslationEvent, Error> {
        guard configuration != nil else { throw failure(.invalidState, "Prepare the local cascade before starting.") }
        let operation = UUID(); operationID = operation
        await stopCurrentSession()
        guard operationID == operation, !Task.isCancelled else { throw CancellationError() }
        self.sessionID = sessionID; self.generation = generation
        let token = UUID(); incarnation = token
        do { try await resources?.begin(generation: token) }
        catch { if incarnation == token { await stop() }; throw error }
        guard incarnation == token, operationID == operation, !Task.isCancelled else {
            if incarnation == token { await stopCurrentSession() }
            throw CancellationError()
        }
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
        producer = Task { [weak self, recognizer, translator, speech, resources, contentGuard, languageDetector] in
            do {
                let source = try await Self.withStage(.recognition, resources: resources, generation: token) {
                    if configuration.directionMode == .automatic {
                        return try await recognizer.transcribeAutomatically(pcm: input, format: Self.inputFormat)
                    }
                    return try await recognizer.transcribe(pcm: input, format: Self.inputFormat, language: configuration.languagePair.source)
                }
                try Task.checkCancellation()
                guard let self else { return }
                try await self.emitText(source, source: true, token: token)
                let selectedPair: TranslationLanguagePair
                if configuration.directionMode == .automatic {
                    let candidates = Set([configuration.languagePair.source, configuration.languagePair.target])
                    let detection = languageDetector.detect(text: source, candidates: candidates)
                    let detectedCode = detection.language.map { TranslationAutomaticLanguageDetector.languageCode($0, candidates: candidates) }
                    let words = TranslationAutomaticLanguageDetector.words(source)
                    guard words.count >= 5, words.joined().count >= 24,
                          let language = detectedCode, candidates.contains(language),
                          detection.confidence.isFinite, (0.90...1).contains(detection.confidence) else {
                        throw TranslationFailure(code: .ambiguousDirection, message: "The source language is unclear, too short or mixed. Check the recognized text, choose the direction explicitly, and replay within 30 seconds. No translation or speech was produced.")
                    }
                    selectedPair = .init(source: language, target: language == configuration.languagePair.source ? configuration.languagePair.target : configuration.languagePair.source)
                    try await self.emit(.directionSelected(.init(pair: selectedPair, confidence: detection.confidence)), token: token)
                } else { selectedPair = configuration.languagePair }
                let target = try await Self.withStage(.translation, resources: resources, generation: token) {
                    try await translator.translate(text: source, sourceLanguage: selectedPair.source,
                                                   targetLanguage: selectedPair.target)
                }
                try Task.checkCancellation()
                try contentGuard.validate(source: source, translation: target, sourceLanguage: selectedPair.source, targetLanguage: selectedPair.target)
                try await self.emitText(target, source: false, token: token)
                try await self.emit(.metrics(.init(name: .firstCaptionMilliseconds, value: Self.milliseconds(since: started))), token: token)
                if configuration.outputMode == .speechAndCaptions {
                    try await Self.withStage(.speech, resources: resources, generation: token) {
                    let stream = try await speech.synthesize(text: target, language: selectedPair.target, budget: configuration.audioTransportBudget)
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
        operationID = UUID()
        await stopCurrentSession()
    }
    private func stopCurrentSession() async {
        let invalidated = incarnation
        incarnation = UUID()
        producer?.cancel(); producer = nil; watchdog?.cancel(); watchdog = nil
        continuation?.finish(); continuation = nil
        sessionID = nil; turnID = nil; pcm.removeAll(); seconds = 0; previousFrame = nil
        await resources?.invalidate(generation: invalidated)
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
    private func failed(_ error: Error, token: UUID) async {
        guard token == incarnation else { return }
        let error = (error as? TranslationFailure) ?? failure(.providerFailure, "A local cascade model failed. Check its installation and available memory, then retry.")
        incarnation = UUID(); continuation?.finish(throwing: error); continuation = nil
        producer?.cancel(); producer = nil; watchdog?.cancel(); watchdog = nil
        turnID = nil; pcm.removeAll(); previousFrame = nil; seconds = 0
        await resources?.invalidate(generation: token)
    }
    private func expired(token: UUID) async { await failed(failure(.providerFailure, "The local cascade exceeded its response time limit."), token: token) }
    private nonisolated static func withStage<T: Sendable>(
        _ stage: TranslationCascadeStage, resources: (any TranslationCascadeResources)?, generation: UUID,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let lease = try await resources?.acquire(stage, generation: generation)
        var released = false
        do {
            try Task.checkCancellation()
            let result = try await operation()
            if let lease { await resources?.release(lease); released = true }
            try Task.checkCancellation()
            return result
        } catch {
            if let lease, !released { await resources?.release(lease) }
            throw error
        }
    }
    private func failure(_ code: TranslationFailure.Code, _ message: String) -> TranslationFailure { .init(code: code, message: message) }
    private nonisolated static func milliseconds(since started: ContinuousClock.Instant) -> Double {
        let elapsed = started.duration(to: .now).components
        return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
    }
    deinit { producer?.cancel(); watchdog?.cancel(); continuation?.finish() }
}
