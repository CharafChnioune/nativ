import Foundation

public struct TranslationProviderDescriptor: Sendable {
  public let id: TranslationProviderID
  public let displayName: String
  public let documentedInputLanguages: Set<String>
  public let documentedOutputLanguages: Set<String>
  /// General speech-language claims do not independently establish ASR support.
  public let documentedSpeechLanguages: Set<String>
  public let documentedTextLanguages: Set<String>
  public let documentedRecognitionLanguages: Set<String>
  public let technicallyVerifiedTransportLanguages: Set<String>
  /// Languages whose semantic or voice quality has actually passed qualification.
  public let technicallyVerifiedLanguages: Set<String>
  public let qualifiedPairs: Set<TranslationLanguagePair>
  public let requiresExplicitSelection: Bool
  public let limitation: String
  public var qualified: Bool { !qualifiedPairs.isEmpty }
}
public enum TranslationProviderCatalog {
  /// Evaluation order only. No entry is a qualified or automatically selected default.
  public static let qualificationOrder: [TranslationProviderID] = [
    .lfm3OmniDirect, .lfm3OmniTwoPass,
  ]
  public static let providers: [TranslationProviderDescriptor] = [
    .init(
      id: .lfm3OmniDirect, displayName: "LFM3-Omni direct (experimental)",
      documentedInputLanguages: LFMLanguageSupport.documentedSpeechLanguages,
      documentedOutputLanguages: LFMLanguageSupport.documentedSpeechLanguages,
      documentedSpeechLanguages: LFMLanguageSupport.documentedSpeechLanguages,
      documentedTextLanguages: LFMLanguageSupport.documentedTextLanguages,
      documentedRecognitionLanguages: [], technicallyVerifiedTransportLanguages: ["en", "nl"],
      technicallyVerifiedLanguages: [], qualifiedPairs: [], requiresExplicitSelection: true,
      limitation:
        "Experimental: Q8/Q4 probes streamed real audio but mistranslated a protected time and repeated English instead of Dutch. Speech languages and text languages differ; Dutch is absent from the documented text-language list. No language pair or voice is qualified."
    ),
    .init(
      id: .lfm3OmniTwoPass, displayName: "LFM3-Omni two-pass (experimental)",
      documentedInputLanguages: LFMLanguageSupport.documentedSpeechLanguages,
      documentedOutputLanguages: LFMLanguageSupport.documentedSpeechLanguages,
      documentedSpeechLanguages: LFMLanguageSupport.documentedSpeechLanguages,
      documentedTextLanguages: LFMLanguageSupport.documentedTextLanguages,
      documentedRecognitionLanguages: [], technicallyVerifiedTransportLanguages: ["en", "nl"],
      technicallyVerifiedLanguages: [], qualifiedPairs: [], requiresExplicitSelection: true,
      limitation:
        "Experimental: same-model text then streaming speech works technically after releasing the single socket slot. The tested text pass still failed EN→NL and Q4 changed a protected time. Voice naturalness, target-language fidelity and end-to-end latency remain unqualified."
    ),
    .init(
      id: .localCascade, displayName: "Local cascade (explicit selection)",
      documentedInputLanguages: [], documentedOutputLanguages: [],
      documentedSpeechLanguages: [], documentedTextLanguages: [],
      documentedRecognitionLanguages: [], technicallyVerifiedTransportLanguages: [],
      technicallyVerifiedLanguages: [],
      qualifiedPairs: [], requiresExplicitSelection: true,
      limitation:
        "Select installed STT, translation and target-language TTS models independently; the complete pipeline must be qualified."
    ),
    .init(
      id: .appleSpeech, displayName: "Apple speech (explicit option)",
      documentedInputLanguages: [],
      documentedOutputLanguages: [], documentedSpeechLanguages: [], documentedTextLanguages: [],
      documentedRecognitionLanguages: [], technicallyVerifiedTransportLanguages: [],
      technicallyVerifiedLanguages: [], qualifiedPairs: [],
      requiresExplicitSelection: true,
      limitation:
        "Optional explicit speech renderer only; never an automatic fallback or a translation model."
    ),
  ]
  public static func descriptor(for id: TranslationProviderID) -> TranslationProviderDescriptor? {
    providers.first { $0.id == id }
  }
  public static var qualifiedDefault: TranslationProviderID? { nil }
}
