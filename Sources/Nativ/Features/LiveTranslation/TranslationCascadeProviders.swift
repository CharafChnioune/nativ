@preconcurrency import AVFoundation
import Foundation
import NativServerKit
import NativTranslationKit

/// Host adapters use Nativ's installed model inventory and existing local runtime.
/// No task is substituted when a selected model or language is unavailable.
@MainActor
enum TranslationCascadeProviders {
    static func make(settings: LiveTranslationSettings.Value, configuration: VoiceTranscriptionConfiguration,
                     runtime: TranslationCascadeRuntime,
                     resources: (any TranslationCascadeResources)? = nil,
                     omniEndpoint: @escaping @Sendable () async throws -> LFMRuntimeEndpoint) async throws -> CascadedTranslationBackend {
        let installed = try await LocalModelDiscovery.scan(searchPaths: .init(primary: configuration.modelSearchPath,
                                                                              additional: configuration.additionalModelSearchPaths))
        let recognition = try selected(settings.recognitionModel, in: installed)
        let translation = try selected(settings.translationModel, in: installed)
        let recognitionConfig = try metadata(recognition)
        let recognitionDescriptor = TranslationStageCatalog.describe(model: recognition, role: .recognition)
        let translationDescriptor = TranslationStageCatalog.describe(model: translation, role: .translation)
        try validate(recognitionDescriptor)
        try validate(translationDescriptor)
        guard recognitionDescriptor.languages.contains(settings.sourceLanguage) else {
            throw failure("The selected recognition model does not document the source language. Select a compatible ASR model explicitly.")
        }
        guard settings.experimentalAccepted else { throw failure("Review and accept the experimental language-pair status before using this independently selected cascade.") }
        let translationLanguages = translationDescriptor.languages.isEmpty
            ? Set([settings.sourceLanguage, settings.targetLanguage]) : translationDescriptor.languages
        guard translationLanguages.contains(settings.sourceLanguage), translationLanguages.contains(settings.targetLanguage) else {
            throw failure("The selected translation model does not document this language pair.")
        }
        let recognitionPath: URL
        if settings.recognitionModel == "mlx-community/whisper-large-v3-turbo" {
            recognitionPath = try await TranslationWhisperPreparation.preparedModel(snapshot: recognition.snapshotURL!, cache: URL(fileURLWithPath: (configuration.modelSearchPath as NSString).expandingTildeInPath))
        } else if recognitionDescriptor.family == "whisper" || recognitionDescriptor.family == "qwen3_asr" {
            let snapshot = recognition.snapshotURL!
            guard FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("preprocessor_config.json").path),
                  FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("tokenizer_config.json").path) else {
                throw failure("This recognition model lacks the processor files required by the bundled MLX runtime. Prepare a complete compatible snapshot first.")
            }
            recognitionPath = snapshot
        } else { recognitionPath = recognition.snapshotURL! }
        _ = recognitionConfig // Reading the complete local config is a precondition even for a catalog profile.
        let render: any TranslationSpeechRenderer
        if settings.output == .captions {
            render = TranslationCaptionsOnlyRenderer()
        } else {
        switch settings.speechProvider {
        case .omni:
            render = TranslationOmniRenderer(endpoint: omniEndpoint)
        case .chatterbox:
            let model = try selected(settings.chatterboxModel, in: installed)
            guard try metadata(model)["model_type"] as? String == "chatterbox" else { throw failure("Select a Chatterbox model, or choose Local TTS for a different family.") }
            render = try await localRenderer(model: model, language: settings.targetLanguage, voice: "",
                referencePath: settings.chatterboxReferencePath, referenceText: "", cache: URL(fileURLWithPath: (configuration.modelSearchPath as NSString).expandingTildeInPath), runtime: runtime)
        case .localModel:
            render = try await localRenderer(model: selected(settings.speechModel, in: installed), language: settings.targetLanguage,
                voice: settings.speechVoice, referencePath: settings.speechReferencePath, referenceText: settings.speechReferenceText,
                cache: URL(fileURLWithPath: (configuration.modelSearchPath as NSString).expandingTildeInPath), runtime: runtime)
        case .apple:
            render = try TranslationAppleRenderer(voiceID: settings.appleVoiceID, language: settings.targetLanguage)
        }
        }
        // Clients are bound only to Translate's owned child, never the user's chat server.
        let backend = CascadedTranslationBackend(
            recognizer: TranslationLocalRecognizer(runtime: runtime, model: recognitionPath.path,
                supportedLanguages: recognitionDescriptor.languages, languageArguments: recognitionDescriptor.languageArguments,
                suppliesLanguageHint: recognitionDescriptor.suppliesLanguageHint),
            translator: TranslationLocalTextTranslator(runtime: runtime,
                model: translation.snapshotURL!.path, supportedLanguages: translationLanguages), speech: render, resources: resources)
        _ = try await backend.prepare(configuration: .init(languagePair: .init(source: settings.sourceLanguage, target: settings.targetLanguage),
            directionMode: settings.directionMode, source: settings.source, outputMode: settings.output, provider: .localCascade,
            allowExperimentalAutomaticDirection: settings.automaticDirectionAccepted))
        if settings.output == .speechAndCaptions && (settings.speechProvider == .chatterbox || settings.speechProvider == .localModel) {
            let endpoint = try await runtime.start()
            let audio = NativAudioClient(baseURL: endpoint.baseURL, apiKey: endpoint.apiKey, timeout: 90, localOnly: true)
            try await audio.verifyLocalSpeechIsolation(requiresPinnedAssets: settings.speechProvider == .chatterbox ||
                (try? selected(settings.speechModel, in: installed)).map { TranslationStageCatalog.describe(model: $0, role: .speech).family == "chatterbox" } == true)
        }
        return backend
    }
    private static func validate(_ descriptor: TranslationStageCatalog.Descriptor) throws {
        guard descriptor.isSelectable else { throw failure(descriptor.notes.joined(separator: " ") + " " + descriptor.preparationIssues.joined(separator: " ")) }
        guard descriptor.preparationIssues.isEmpty else { throw failure(descriptor.preparationIssues.joined(separator: " ")) }
    }
    private static func localRenderer(model: LocalModel, language: String, voice: String, referencePath: String, referenceText: String,
                                      cache: URL, runtime: TranslationCascadeRuntime) async throws -> any TranslationSpeechRenderer {
        let descriptor = TranslationStageCatalog.describe(model: model, role: .speech)
        try validate(descriptor)
        guard descriptor.languages.contains(language) else { throw failure("The selected speech model does not support the target language. Choose a compatible TTS model or captions explicitly.") }
        guard let snapshot = model.snapshotURL else { throw failure("Install the complete selected speech model first.") }
        var modelPath = snapshot
        var tokenizerPath: String?
        if descriptor.family == "chatterbox" {
            guard FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("tokenizer.json").path) else { throw failure("Install Chatterbox's tokenizer.json before preparing speech assets.") }
            let prepared = try await TranslationSpeechPreparation.preparedChatterbox(snapshot: snapshot, cache: cache,
                multilingual: try metadata(model)["multilingual"] as? Bool == true)
            modelPath = prepared.model; tokenizerPath = prepared.tokenizer.path
        } else if descriptor.family == "qwen3_tts" || descriptor.family == "qwen3" {
            try verifyQwenSpeechAssets(snapshot: snapshot)
        }
        if !descriptor.voices.isEmpty {
            guard TranslationStageCatalog.voiceSupports(language: language, voice: voice, descriptor: descriptor) else {
                throw failure("Choose an explicit preset voice compatible with the selected speech model and target language.")
            }
        }
        if descriptor.requiresReference { try verifyReference(referencePath) }
        if descriptor.requiresReferenceText && (referenceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || referenceText.utf8.count > 8_192) {
            throw failure("Enter the accurate transcript of the selected Qwen3-TTS Base reference (at most 8 KB).")
        }
        return TranslationLocalPhraseRenderer(runtime: runtime, model: modelPath.path,
            referencePath: descriptor.requiresReference ? referencePath : nil,
            referenceText: descriptor.requiresReferenceText ? referenceText : nil,
            voice: descriptor.voices.isEmpty ? nil : voice, speechTokenizerPath: tokenizerPath,
            supportedLanguages: descriptor.languages, languageArguments: descriptor.languageArguments)
    }
    private static func verifyReference(_ path: String) throws {
        guard !path.isEmpty, path.hasPrefix("/"), FileManager.default.isReadableFile(atPath: path) else {
            throw failure("Choose a readable local voice recording you have permission to use.")
        }
        let attributes = try URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard attributes.isRegularFile == true, (attributes.fileSize ?? 0) > 0, (attributes.fileSize ?? 0) <= 20_000_000 else {
            throw failure("Choose a short voice reference under 20 MB.")
        }
    }
    private static func verifyQwenSpeechAssets(snapshot: URL) throws {
        let tokenizer = snapshot.appendingPathComponent("speech_tokenizer")
        let weights = (try? FileManager.default.contentsOfDirectory(at: tokenizer, includingPropertiesForKeys: nil))?.contains { $0.pathExtension == "safetensors" } == true
        guard weights, ["config.json"].allSatisfy({ FileManager.default.fileExists(atPath: tokenizer.appendingPathComponent($0).path) }),
              ["tokenizer.json", "tokenizer_config.json"].allSatisfy({ FileManager.default.fileExists(atPath: snapshot.appendingPathComponent($0).path) }) else {
            throw failure("Prepare the complete Qwen3-TTS snapshot including text tokenizer files and speech_tokenizer/config.json plus its safetensors weights in Models.")
        }
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
    static let documentedWhisperLanguages = TranslationStageCatalog.whisperLanguages
    static let documentedChatterboxLanguages = TranslationStageCatalog.chatterboxLanguages
    /// Candidate set exposed by this adapter under Gemma 4's multilingual claim; no individual pair is qualified.
    static let candidateTranslationLanguages = LFMLanguageSupport.documentedTextLanguages
        .union(LFMLanguageSupport.documentedSpeechLanguages).union(documentedChatterboxLanguages)
}

private struct TranslationLocalRecognizer: TranslationSpeechRecognizer {
    let runtime: TranslationCascadeRuntime
    let model: String
    let supportedLanguages: Set<String>
    let languageArguments: [String: String]
    let suppliesLanguageHint: Bool
    let supportsAutomaticRecognition = true
    func transcribe(pcm: Data, format: TranslationPCMFormat, language: String) async throws -> String {
        try await recognize(pcm: pcm, format: format, language: suppliesLanguageHint ? (languageArguments[language] ?? language) : nil)
    }
    func transcribeAutomatically(pcm: Data, format: TranslationPCMFormat) async throws -> String {
        try await recognize(pcm: pcm, format: format, language: nil)
    }
    private func recognize(pcm: Data, format: TranslationPCMFormat, language: String?) async throws -> String {
        let wav = try TranslationWaveCodec.encode(pcm, format: format)
        let endpoint = try await runtime.start()
        let client = NativAudioClient(baseURL: endpoint.baseURL, apiKey: endpoint.apiKey, timeout: 90, localOnly: true)
        let result = try await client.transcribe(audioData: wav, fileName: "utterance.wav", model: model,
            language: language)
        try Task.checkCancellation()
        return result.text
    }
}
private struct TranslationLocalTextTranslator: TranslationTextTranslator {
    let runtime: TranslationCascadeRuntime
    let model: String
    let supportedLanguages: Set<String>
    func translate(text: String, sourceLanguage: String, targetLanguage: String) async throws -> String {
        let endpoint = try await runtime.start()
        let client = NativChatClient(baseURL: endpoint.baseURL, apiKey: endpoint.apiKey, idleTimeout: 60, resourceTimeout: 90, localOnly: true)
        let request = MLXChatCompletionRequest(model: model, messages: [
            .init(role: "system", content: TranslationInterpreterPrompt.instructions(sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)),
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
    let endpoint: @Sendable () async throws -> LFMRuntimeEndpoint
    let supportedLanguages = LFMLanguageSupport.documentedSpeechLanguages
    let streamsAudio = true
    func synthesize(text: String, language: String, budget: TranslationAudioTransportBudget) async throws -> AsyncThrowingStream<TranslationAudioChunk, Error> {
        let resolved = try await endpoint()
        return try LFM3SpeechSynthesizer(endpoint: resolved).stream(text: text, language: language, budget: budget)
    }
}
private struct TranslationLocalPhraseRenderer: TranslationSpeechRenderer {
    let runtime: TranslationCascadeRuntime
    let model: String
    let referencePath: String?
    let referenceText: String?
    let voice: String?
    let speechTokenizerPath: String?
    let supportedLanguages: Set<String>
    let languageArguments: [String: String]
    let streamsAudio = false
    func synthesize(text: String, language: String, budget: TranslationAudioTransportBudget) async throws -> AsyncThrowingStream<TranslationAudioChunk, Error> {
        let endpoint = try await runtime.start()
        let client = NativAudioClient(baseURL: endpoint.baseURL, apiKey: endpoint.apiKey, timeout: 90, localOnly: true)
        let wave = try await client.synthesize(text: text, model: model, language: languageArguments[language] ?? language,
            referenceAudioPath: referencePath, voice: voice, referenceText: referenceText, speechTokenizerPath: speechTokenizerPath)
        try Task.checkCancellation()
        let audio = try TranslationWaveCodec.decode(wave)
        guard try audio.format.duration(byteCount: audio.bytes.count) <= 12 else {
            throw TranslationFailure(code: .overload, message: "The local speech model produced more than twelve seconds of phrase audio. Repeat a shorter phrase; this response was not queued for playback.")
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
    static func prepareSpeech(settings: LiveTranslationSettings.Value, configuration: VoiceTranscriptionConfiguration) async throws -> String {
        guard settings.speechProvider == .chatterbox || settings.speechProvider == .localModel else {
            throw failure("Choose a local speech model to prepare its assets. LFM3-Omni has its own Prepare model action.")
        }
        let models = try await LocalModelDiscovery.scan(searchPaths: .init(primary: configuration.modelSearchPath, additional: configuration.additionalModelSearchPaths))
        let model = try selected(settings.speechProvider == .chatterbox ? settings.chatterboxModel : settings.speechModel, in: models)
        let descriptor = TranslationStageCatalog.describe(model: model, role: .speech)
        try validate(descriptor)
        guard let snapshot = model.snapshotURL else { throw failure("Install the complete selected local speech model in Models first.") }
        switch descriptor.family {
        case "chatterbox":
            guard FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("tokenizer.json").path) else {
                throw failure("Install Chatterbox's complete text tokenizer before preparing auxiliary speech assets.")
            }
            _ = try await TranslationSpeechPreparation.prepareChatterbox(snapshot: snapshot,
                cache: URL(fileURLWithPath: (configuration.modelSearchPath as NSString).expandingTildeInPath), multilingual: try metadata(model)["multilingual"] as? Bool == true)
            return "Pinned Chatterbox tokenizer and character-map assets verified. Choose a permitted local reference before Start."
        case "qwen3_tts", "qwen3":
            try verifyQwenSpeechAssets(snapshot: snapshot)
            return "Qwen3-TTS text and speech tokenizer files are present. Select a preset voice or a Base reference with transcript before Start; quality remains unqualified."
        default:
            throw failure("This speech family has no complete offline preparation adapter in the bundled runtime.")
        }
    }
    static func prepareRecognition(settings: LiveTranslationSettings.Value, configuration: VoiceTranscriptionConfiguration) async throws -> String {
        guard settings.recognitionModel == "mlx-community/whisper-large-v3-turbo" else {
            throw TranslationFailure(code: .invalidConfiguration, message: "Tokenizer preparation currently targets the pinned Whisper large-v3-turbo model. Other selected models must already include their own complete processor files.")
        }
        let models = try await LocalModelDiscovery.scan(searchPaths: .init(primary: configuration.modelSearchPath, additional: configuration.additionalModelSearchPaths))
        guard let snapshot = models.first(where: { $0.repoID == settings.recognitionModel })?.snapshotURL else {
            throw TranslationFailure(code: .invalidConfiguration, message: "Install Whisper large-v3-turbo in Models first. This action downloads only its tokenizer files.")
        }
        _ = try await TranslationWhisperPreparation.prepare(snapshot: snapshot, cache: URL(fileURLWithPath: (configuration.modelSearchPath as NSString).expandingTildeInPath))
        return "Whisper model and pinned tokenizer files verified."
    }
}
