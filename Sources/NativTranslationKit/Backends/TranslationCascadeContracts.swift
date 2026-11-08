import Foundation

/// Capabilities are separate per task. Language lists are documented support, not qualification.
public protocol TranslationSpeechRecognizer: Sendable {
    var supportedLanguages: Set<String> { get }
    func transcribe(pcm: Data, format: TranslationPCMFormat, language: String) async throws -> String
}
public protocol TranslationTextTranslator: Sendable {
    var supportedLanguages: Set<String> { get }
    func translate(text: String, sourceLanguage: String, targetLanguage: String) async throws -> String
}
public protocol TranslationSpeechRenderer: Sendable {
    var supportedLanguages: Set<String> { get }
    /// True only when the underlying model produces playable chunks before generating the whole phrase.
    var streamsAudio: Bool { get }
    func synthesize(text: String, language: String, budget: TranslationAudioTransportBudget) async throws -> AsyncThrowingStream<TranslationAudioChunk, Error>
}
