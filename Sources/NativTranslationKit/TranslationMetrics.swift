import Foundation

/// No speech, transcript, prompts, source IDs, or other user content belongs in metrics.
public struct TranslationMetric: Equatable, Sendable {
    public enum Name: String, Sendable {
        case preparationMilliseconds, firstCaptionMilliseconds, firstAudioMilliseconds,
            cancellationMilliseconds, contextTokens, inputAudioSeconds, outputAudioSeconds
    }
    public let name: Name
    public let value: Double
    public init(name: Name, value: Double) {
        self.name = name
        self.value = value
    }
}
