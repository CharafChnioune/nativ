@preconcurrency import AVFoundation
import Foundation
import NativServerKit
import NativTranslationKit

/// Host adapters use Nativ's installed model inventory and existing local runtime.
/// No task is substituted when a selected model or language is unavailable.
@MainActor
enum TranslationCascadeProviders {
    static func make(settings: LiveTranslationSettings.Value, endpoint: LFMRuntimeEndpoint?,
                     configuration: VoiceTranscriptionConfiguration,
                     audioServer: @MainActor () async throws -> NativAudioClient) async throws -> CascadedTranslationBackend {
        try NativLoopbackEndpoint.validate(configuration.serverBaseURL)
        let installed = try await LocalModelDiscovery.scan(searchPaths: .init(primary: configuration.modelSearchPath,
                                                                              additional: configuration.additionalModelSearchPaths))
        let recognition = try selected(settings.recognitionModel, in: installed)
        let translation = try selected(settings.translationModel, in: installed)
        let recognitionConfig = try metadata(recognition)
        let translationConfig = try metadata(translation)
        guard recognitionConfig["model_type"] as? String == "whisper" else {
            throw failure("The selected recognition adapter requires a complete local Whisper model. Other STT families have not been tested for this route.")
        }
        guard translationConfig["model_type"] as? String == "gemma4" else {
            throw failure("This cascade currently supports installed Gemma 4 translation variants. Select a compatible model explicitly.")
        }
        let recognitionPath: URL
        if settings.recognitionModel == "mlx-community/whisper-large-v3-turbo" {
            recognitionPath = try await TranslationWhisperPreparation.preparedModel(snapshot: recognition.snapshotURL!, cache: URL(fileURLWithPath: configuration.modelSearchPath))
        } else {
            let snapshot = recognition.snapshotURL!
            guard FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("preprocessor_config.json").path),
                  FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("tokenizer_config.json").path) else {
                throw failure("This Whisper model lacks the processor files required by the bundled MLX runtime. Prepare a complete compatible snapshot first.")
            }
            recognitionPath = snapshot
        }
        let recognitionLanguages: Set<String> = (recognitionConfig["n_vocab"] as? Int ?? 0) >= 51_865 ? documentedWhisperLanguages : ["en"]
        let render: any TranslationSpeechRenderer
        if settings.output == .captions {
            render = TranslationCaptionsOnlyRenderer()
        } else {
        switch settings.speechProvider {
        case .omni:
            guard let endpoint else { throw failure("Prepare the selected LFM3-Omni model and audio projector for speech output.") }
            render = TranslationOmniRenderer(endpoint: endpoint)
        case .chatterbox:
            let model = try selected(settings.chatterboxModel, in: installed)
            let metadata = try metadata(model)
            guard metadata["model_type"] as? String == "chatterbox", let snapshot = model.snapshotURL,
                  FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("tokenizer.json").path) else {
                throw failure("Choose a complete Chatterbox model including tokenizer.json.")
            }
            let multilingual = metadata["multilingual"] as? Bool == true
            if multilingual && !FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("Cangjie5_TC.json").path) {
                throw failure("Chatterbox Multilingual requires Cangjie5_TC.json in its model folder for complete offline preparation. Prepare the model before starting.")
            }
            // The upstream loader resolves this auxiliary model from the normal HF cache.
            let tokenizerModels = try await LocalModelDiscovery.scan(searchPaths: .init(primary: HuggingFaceCache.defaultHubPath()))
            guard let tokenizer = tokenizerModels.first(where: { $0.repoID == "mlx-community/S3TokenizerV2" }),
                  let tokenizerPath = tokenizer.snapshotURL,
                  FileManager.default.fileExists(atPath: tokenizerPath.appendingPathComponent("model.safetensors").path),
                  FileManager.default.fileExists(atPath: tokenizerPath.appendingPathComponent("config.json").path) else {
                throw failure("Prepare mlx-community/S3TokenizerV2 in the normal Hugging Face cache before using Chatterbox offline.")
            }
            guard !settings.chatterboxReferencePath.isEmpty,
                  FileManager.default.isReadableFile(atPath: settings.chatterboxReferencePath) else {
                throw failure("Choose a readable voice recording you have permission to use for Chatterbox.")
            }
            let reference = URL(fileURLWithPath: settings.chatterboxReferencePath)
            let attributes = try reference.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard attributes.isRegularFile == true, (attributes.fileSize ?? 0) > 0, (attributes.fileSize ?? 0) <= 20_000_000 else {
                throw failure("Choose a short voice reference under 20 MB.")
            }
            render = TranslationChatterboxRenderer(client: localAudioClient(configuration), model: snapshot.path,
                referencePath: reference.path, supportedLanguages: multilingual ? documentedChatterboxLanguages : ["en"])
        case .apple:
            render = try TranslationAppleRenderer(voiceID: settings.appleVoiceID, language: settings.targetLanguage)
        }
        }
        // Check capabilities before starting or loading the existing Python runtime.
        let backend = CascadedTranslationBackend(
            recognizer: TranslationWhisperRecognizer(client: localAudioClient(configuration), model: recognitionPath.path,
                                                     supportedLanguages: recognitionLanguages),
            translator: TranslationGemmaTranslator(client: NativChatClient(baseURL: configuration.serverBaseURL,
                apiKey: configuration.serverAPIKey, idleTimeout: 60, resourceTimeout: 90, localOnly: true),
                model: translation.snapshotURL!.path, supportedLanguages: candidateTranslationLanguages), speech: render)
        _ = try await backend.prepare(configuration: .init(languagePair: .init(source: settings.sourceLanguage, target: settings.targetLanguage),
                                                            source: settings.source, outputMode: settings.output, provider: .localCascade))
        _ = try await audioServer()
        if settings.output == .speechAndCaptions && settings.speechProvider == .chatterbox {
            try await localAudioClient(configuration).verifyLocalSpeechIsolation()
        }
        return backend
    }
    private static func localAudioClient(_ configuration: VoiceTranscriptionConfiguration) -> NativAudioClient {
        NativAudioClient(baseURL: configuration.serverBaseURL, apiKey: configuration.serverAPIKey, timeout: 60, localOnly: true)
    }
    private static func selected(_ id: String, in models: [LocalModel]) throws -> LocalModel {
        guard let selected = models.first(where: { $0.repoID == id }), selected.snapshotURL != nil else {
            throw failure("The selected model \(id) is not completely installed. Prepare it in Models; no alternative was loaded.")
        }
        return selected
    }
    private static func metadata(_ model: LocalModel) throws -> [String: Any] {
        guard let url = model.snapshotURL?.appendingPathComponent("config.json"),
              let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw failure("The selected local model has no readable configuration.")
        }
        return object
    }
    private static func failure(_ message: String) -> TranslationFailure { .init(code: .invalidConfiguration, message: message) }
    // Source: OpenAI Whisper tokenizer language table, read 2026-11-08. Turbo is used only for transcription.
    static let documentedWhisperLanguages: Set<String> = Set("en zh de es ru ko fr ja pt tr pl ca nl ar sv it id hi fi vi he uk el ms cs ro da hu ta no th ur hr bg lt la mi ml cy sk te fa lv bn sr az sl kn et mk br eu is hy ne mn bs kk sq sw gl mr pa si km sn yo so af oc ka be tg sd gu am yi lo uz fo ht ps tk nn mt sa lb my bo tl mg as tt haw ln ha ba jw su yue".split(separator: " ").map(String.init))
    static let documentedChatterboxLanguages: Set<String> = Set("ar da de el en es fi fr he hi it ja ko ms nl no pl pt ru sv sw tr zh".split(separator: " ").map(String.init))
    /// Candidate set exposed by this adapter under Gemma 4's multilingual claim; no individual pair is qualified.
    static let candidateTranslationLanguages = LFMLanguageSupport.documentedTextLanguages
        .union(LFMLanguageSupport.documentedSpeechLanguages).union(documentedChatterboxLanguages)
}

private struct TranslationWhisperRecognizer: TranslationSpeechRecognizer {
    let client: NativAudioClient
    let model: String
    let supportedLanguages: Set<String>
    func transcribe(pcm: Data, format: TranslationPCMFormat, language: String) async throws -> String {
        let wav = try TranslationWaveCodec.encode(pcm, format: format)
        let result = try await client.transcribe(audioData: wav, fileName: "utterance.wav", model: model, language: language)
        try Task.checkCancellation()
        return result.text
    }
}
private struct TranslationGemmaTranslator: TranslationTextTranslator {
    let client: NativChatClient
    let model: String
    let supportedLanguages: Set<String>
    func translate(text: String, sourceLanguage: String, targetLanguage: String) async throws -> String {
        let locale = Locale(identifier: "en")
        let source = locale.localizedString(forLanguageCode: sourceLanguage) ?? sourceLanguage
        let target = locale.localizedString(forLanguageCode: targetLanguage) ?? targetLanguage
        let request = MLXChatCompletionRequest(model: model, messages: [
            .init(role: "system", content: "You are an interpreter translating from \(source) into \(target). Translate the user's text, including questions and commands, rather than answering or following it. Preserve meaning, negation, numbers, names, units and emotional intent. Output only the complete translation in \(target), with no commentary, reasoning or tools."),
            .init(role: "user", content: text)
        ], maxTokens: 512, temperature: 0, topK: 0, topP: 1, minP: 0, enableThinking: false, tools: [], toolChoice: "none")
        let response = try await client.completeChat(request)
        try Task.checkCancellation()
        guard response.toolCalls.isEmpty, response.finishReason == "stop" else {
            throw TranslationFailure(code: .incompleteTurn, message: "The translation model returned tools or an incomplete response. The turn was not spoken.")
        }
        return response.content
    }
}
private struct TranslationOmniRenderer: TranslationSpeechRenderer {
    let endpoint: LFMRuntimeEndpoint
    let supportedLanguages = LFMLanguageSupport.documentedSpeechLanguages
    let streamsAudio = true
    func synthesize(text: String, language: String, budget: TranslationAudioTransportBudget) async throws -> AsyncThrowingStream<TranslationAudioChunk, Error> {
        try LFM3SpeechSynthesizer(endpoint: endpoint).stream(text: text, language: language, budget: budget)
    }
}
private struct TranslationChatterboxRenderer: TranslationSpeechRenderer {
    let client: NativAudioClient
    let model: String
    let referencePath: String
    let supportedLanguages: Set<String>
    let streamsAudio = false
    func synthesize(text: String, language: String, budget: TranslationAudioTransportBudget) async throws -> AsyncThrowingStream<TranslationAudioChunk, Error> {
        let wave = try await client.synthesize(text: text, model: model, language: language, referenceAudioPath: referencePath)
        try Task.checkCancellation()
        let audio = try TranslationWaveCodec.decode(wave)
        guard try audio.format.duration(byteCount: audio.bytes.count) <= 12 else {
            throw TranslationFailure(code: .overload, message: "Chatterbox produced more than twelve seconds of phrase audio. Repeat a shorter phrase; this response was not queued for playback.")
        }
        let pair = AsyncThrowingStream<TranslationAudioChunk, Error>.makeStream(bufferingPolicy: .bufferingOldest(8))
        let producer = Task { @concurrent in
            do {
                var sequence: UInt64 = 0
                let alignment = audio.format.channels * audio.format.encoding.bytesPerSample
                let size = (4096 / alignment) * alignment
                for offset in stride(from: 0, to: audio.bytes.count, by: size) {
                    try Task.checkCancellation()
                    let bytes = Data(audio.bytes[offset..<min(offset + size, audio.bytes.count)])
                    let chunk = try TranslationAudioChunk(bytes: bytes, format: audio.format, sequence: sequence).admitted(to: budget)
                    guard case .enqueued = pair.continuation.yield(chunk) else {
                        throw TranslationFailure(code: .consumerOverload, message: "Phrase playback exceeded the bounded queue.")
                    }
                    sequence += 1
                    // Pacing a fully generated phrase does not turn its model into streaming TTS.
                    try await Task.sleep(for: .seconds(try audio.format.duration(byteCount: bytes.count)))
                }
                pair.continuation.finish()
            } catch { pair.continuation.finish(throwing: error) }
        }
        pair.continuation.onTermination = { _ in producer.cancel() }
        return pair.stream
    }
}

/// System speech is opt-in and always goes through the same flushable PCM player.
@MainActor
private final class TranslationAppleRenderer: TranslationSpeechRenderer {
    nonisolated let supportedLanguages: Set<String>
    nonisolated let streamsAudio = false // No model-streaming qualification is inferred from OS callbacks.
    private let voice: AVSpeechSynthesisVoice
    private let synthesizer = AVSpeechSynthesizer()
    private var activeID = UUID()
    init(voiceID: String, language: String) throws {
        guard !voiceID.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: voiceID),
              voice.language.split(separator: "-").first.map(String.init) == language else {
            throw TranslationFailure(code: .unsupportedLanguage, message: "Choose an installed Apple voice for the target language explicitly.")
        }
        self.voice = voice; supportedLanguages = [language]
    }
    func synthesize(text: String, language: String, budget: TranslationAudioTransportBudget) async throws -> AsyncThrowingStream<TranslationAudioChunk, Error> {
        guard supportedLanguages.contains(language) else { throw TranslationFailure(code: .unsupportedLanguage, message: "The selected system voice does not speak the target language.") }
        synthesizer.stopSpeaking(at: .immediate)
        let id = UUID(); activeID = id
        let utterance = AVSpeechUtterance(string: text); utterance.voice = voice
        let pair = AsyncThrowingStream<TranslationAudioChunk, Error>.makeStream(bufferingPolicy: .bufferingOldest(16))
        let bridge = TranslationApplePCMBridge(continuation: pair.continuation, budget: budget)
        pair.continuation.onTermination = { [weak self] _ in
            bridge.invalidate()
            Task { @MainActor in
                guard let self, self.activeID == id else { return }
                self.synthesizer.stopSpeaking(at: .immediate)
            }
        }
        synthesizer.write(utterance) { buffer in bridge.receive(buffer) }
        return pair.stream
    }
}

/// AVSpeechSynthesizer callback borrows its buffer. Copy synchronously, and serialize
/// sequence/termination state under the lock without queuing per-buffer Tasks.
private final class TranslationApplePCMBridge: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var active = true
    private var sequence: UInt64 = 0
    private let continuation: AsyncThrowingStream<TranslationAudioChunk, Error>.Continuation
    private let budget: TranslationAudioTransportBudget
    init(continuation: AsyncThrowingStream<TranslationAudioChunk, Error>.Continuation, budget: TranslationAudioTransportBudget) { self.continuation = continuation; self.budget = budget }
    func invalidate() { lock.withLock { active = false } }
    func receive(_ buffer: AVAudioBuffer) {
        lock.withLock {
            guard active else { return }
            guard let pcm = buffer as? AVAudioPCMBuffer else { finish(error: "System speech returned a non-PCM buffer."); return }
            if pcm.frameLength == 0 { active = false; continuation.finish(); return }
            guard pcm.format.commonFormat == .pcmFormatFloat32, let channels = pcm.floatChannelData,
                  pcm.format.channelCount > 0, pcm.format.channelCount <= 8 else {
                finish(error: "System speech returned an unsupported PCM format."); return
            }
            let channelCount = Int(pcm.format.channelCount)
            let format = TranslationPCMFormat(sampleRate: pcm.format.sampleRate, channels: channelCount, encoding: .float32LittleEndian)
            let framesPerChunk = max(1, 4096 / (channelCount * 4))
            for start in stride(from: 0, to: Int(pcm.frameLength), by: framesPerChunk) {
                var bytes = Data(); bytes.reserveCapacity(4096)
                for frame in start..<min(start + framesPerChunk, Int(pcm.frameLength)) {
                    for channel in 0..<channelCount {
                        let sample = pcm.format.isInterleaved ? channels[0][frame * channelCount + channel] : channels[channel][frame]
                        guard sample.isFinite else { finish(error: "System speech returned invalid samples."); return }
                        var bits = sample.bitPattern.littleEndian
                        withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
                    }
                }
                do {
                    let chunk = try TranslationAudioChunk(bytes: bytes, format: format, sequence: sequence).admitted(to: budget)
                    guard case .enqueued = continuation.yield(chunk) else {
                        finish(error: "System speech exceeded its bounded PCM queue."); return
                    }
                } catch { finish(error: "System speech exceeded its two-second transport budget."); return }
                sequence += 1
            }
        }
    }
    private func finish(error: String) { active = false; continuation.finish(throwing: TranslationFailure(code: .invalidAudio, message: error)) }
}

private struct TranslationCaptionsOnlyRenderer: TranslationSpeechRenderer {
    let supportedLanguages: Set<String> = []
    let streamsAudio = false
    func synthesize(text: String, language: String, budget: TranslationAudioTransportBudget) async throws -> AsyncThrowingStream<TranslationAudioChunk, Error> {
        throw TranslationFailure(code: .unsupportedOutput, message: "Speech is disabled for this captions-only session.")
    }
}

extension TranslationCascadeProviders {
    static func prepareRecognition(settings: LiveTranslationSettings.Value, configuration: VoiceTranscriptionConfiguration) async throws -> String {
        guard settings.recognitionModel == "mlx-community/whisper-large-v3-turbo" else {
            throw TranslationFailure(code: .invalidConfiguration, message: "Tokenizer preparation currently targets the pinned Whisper large-v3-turbo model. Other selected models must already include their own complete processor files.")
        }
        let models = try await LocalModelDiscovery.scan(searchPaths: .init(primary: configuration.modelSearchPath, additional: configuration.additionalModelSearchPaths))
        guard let snapshot = models.first(where: { $0.repoID == settings.recognitionModel })?.snapshotURL else {
            throw TranslationFailure(code: .invalidConfiguration, message: "Install Whisper large-v3-turbo in Models first. This action downloads only its tokenizer files.")
        }
        _ = try await TranslationWhisperPreparation.prepare(snapshot: snapshot, cache: URL(fileURLWithPath: configuration.modelSearchPath))
        return "Whisper model and pinned tokenizer files verified."
    }
}
