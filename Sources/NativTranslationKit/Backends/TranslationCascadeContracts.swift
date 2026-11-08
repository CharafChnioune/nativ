import Foundation

public enum TranslationCascadeStage: String, Sendable, Equatable {
    case recognition, translation, speech
}

/// A resource release is scoped to both its generation and acquisition, so a late
/// cancelled producer cannot unload a newer turn's models.
public struct TranslationCascadeLease: Sendable, Equatable {
    public let id: UUID
    public let generation: UUID
    public let stage: TranslationCascadeStage
    public init(id: UUID = UUID(), generation: UUID, stage: TranslationCascadeStage) {
        self.id = id; self.generation = generation; self.stage = stage
    }
}

public protocol TranslationCascadeResources: Sendable {
    func begin(generation: UUID) async throws
    func acquire(_ stage: TranslationCascadeStage, generation: UUID) async throws -> TranslationCascadeLease
    func release(_ lease: TranslationCascadeLease) async
    func invalidate(generation: UUID) async
}

/// Capabilities are separate per task. Language lists are documented support, not qualification.
public protocol TranslationSpeechRecognizer: Sendable {
    var supportedLanguages: Set<String> { get }
    var supportsAutomaticRecognition: Bool { get }
    func transcribe(pcm: Data, format: TranslationPCMFormat, language: String) async throws -> String
    func transcribeAutomatically(pcm: Data, format: TranslationPCMFormat) async throws -> String
}
public extension TranslationSpeechRecognizer {
    var supportsAutomaticRecognition: Bool { false }
    func transcribeAutomatically(pcm: Data, format: TranslationPCMFormat) async throws -> String {
        throw TranslationFailure(code: .unsupportedLanguage, message: "This recognition adapter requires an explicit source language.")
    }
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
