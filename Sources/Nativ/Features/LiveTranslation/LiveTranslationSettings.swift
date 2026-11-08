import Combine
import Foundation
import NativTranslationKit

/// Only explicit preferences are durable. Audio and transcript content are not saved.
@MainActor
final class LiveTranslationSettings: ObservableObject {
    enum SpeechProvider: String, Codable, CaseIterable {
        case omni, chatterbox, localModel, apple
        var title: String {
            switch self {
            case .omni: "LFM3-Omni · local streaming"
            case .chatterbox: "Chatterbox · complete phrases"
            case .localModel: "Other local speech model · complete phrases"
            case .apple: "Apple system voice · optional"
            }
        }
    }
    struct Value: Codable, Equatable {
        var sourceLanguage = "nl"
        var targetLanguage = "en"
        var directionMode: TranslationDirectionMode = .fixed
        var automaticDirectionAccepted = false
        var cascadeMemoryStrategy: TranslationCascadeMemoryStrategy = .sequential
        var provider: TranslationProviderID = .lfm3OmniDirect
        var source: TranslationSource = .microphone
        var output: TranslationOutputMode = .speechAndCaptions
        var quantization = "Q8_0"
        var inputDeviceID = ""
        var outputDeviceID: UInt32 = 0
        var headphones = false
        var overlay = true
        var experimentalAccepted = false
        var shortcut: VoiceShortcut = .init(keyCode: 17, keyDisplay: "T", modifiers: [.control, .option])
        var recognitionModel = "mlx-community/whisper-large-v3-turbo"
        var translationModel = "mlx-community/gemma-4-e4b-it-4bit"
        var speechProvider: SpeechProvider = .omni
        var chatterboxModel = "mlx-community/chatterbox-multilingual-v3"
        var chatterboxReferencePath = ""
        var appleVoiceID = ""
        var speechModel = ""
        var speechVoice = ""
        var speechReferencePath = ""
        var speechReferenceText = ""

        init() {}
        private enum CodingKeys: String, CodingKey {
            case sourceLanguage, targetLanguage, directionMode, automaticDirectionAccepted, cascadeMemoryStrategy, provider, source, output, quantization, inputDeviceID, outputDeviceID, headphones, overlay, experimentalAccepted, shortcut, recognitionModel, translationModel, speechProvider, chatterboxModel, chatterboxReferencePath, appleVoiceID, speechModel, speechVoice, speechReferencePath, speechReferenceText
        }
        /// New preferences must not discard an existing user's explicit model or voice.
        init(from decoder: any Decoder) throws {
            self.init()
            let values = try decoder.container(keyedBy: CodingKeys.self)
            sourceLanguage = try values.decodeIfPresent(String.self, forKey: .sourceLanguage) ?? sourceLanguage
            targetLanguage = try values.decodeIfPresent(String.self, forKey: .targetLanguage) ?? targetLanguage
            directionMode = try values.decodeIfPresent(TranslationDirectionMode.self, forKey: .directionMode) ?? directionMode
            automaticDirectionAccepted = try values.decodeIfPresent(Bool.self, forKey: .automaticDirectionAccepted) ?? automaticDirectionAccepted
            cascadeMemoryStrategy = try values.decodeIfPresent(TranslationCascadeMemoryStrategy.self, forKey: .cascadeMemoryStrategy) ?? cascadeMemoryStrategy
            provider = try values.decodeIfPresent(TranslationProviderID.self, forKey: .provider) ?? provider
            source = try values.decodeIfPresent(TranslationSource.self, forKey: .source) ?? source
            output = try values.decodeIfPresent(TranslationOutputMode.self, forKey: .output) ?? output
            quantization = try values.decodeIfPresent(String.self, forKey: .quantization) ?? quantization
            inputDeviceID = try values.decodeIfPresent(String.self, forKey: .inputDeviceID) ?? inputDeviceID
            outputDeviceID = try values.decodeIfPresent(UInt32.self, forKey: .outputDeviceID) ?? outputDeviceID
            headphones = try values.decodeIfPresent(Bool.self, forKey: .headphones) ?? headphones
            overlay = try values.decodeIfPresent(Bool.self, forKey: .overlay) ?? overlay
            experimentalAccepted = try values.decodeIfPresent(Bool.self, forKey: .experimentalAccepted) ?? experimentalAccepted
            shortcut = try values.decodeIfPresent(VoiceShortcut.self, forKey: .shortcut) ?? shortcut
            recognitionModel = try values.decodeIfPresent(String.self, forKey: .recognitionModel) ?? recognitionModel
            translationModel = try values.decodeIfPresent(String.self, forKey: .translationModel) ?? translationModel
            speechProvider = try values.decodeIfPresent(SpeechProvider.self, forKey: .speechProvider) ?? speechProvider
            chatterboxModel = try values.decodeIfPresent(String.self, forKey: .chatterboxModel) ?? chatterboxModel
            chatterboxReferencePath = try values.decodeIfPresent(String.self, forKey: .chatterboxReferencePath) ?? chatterboxReferencePath
            appleVoiceID = try values.decodeIfPresent(String.self, forKey: .appleVoiceID) ?? appleVoiceID
            speechModel = try values.decodeIfPresent(String.self, forKey: .speechModel) ?? speechModel
            speechVoice = try values.decodeIfPresent(String.self, forKey: .speechVoice) ?? speechVoice
            speechReferencePath = try values.decodeIfPresent(String.self, forKey: .speechReferencePath) ?? speechReferencePath
            speechReferenceText = try values.decodeIfPresent(String.self, forKey: .speechReferenceText) ?? speechReferenceText
        }

        func requiresFreshSession(comparedTo other: Self) -> Bool {
            var sessionPreferences = self
            sessionPreferences.overlay = other.overlay
            sessionPreferences.shortcut = other.shortcut
            return sessionPreferences != other
        }
    }
    @Published var value: Value {
        didSet {
            if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.key) }
        }
    }
    private let defaults: UserDefaults
    private static let key = "io.github.charafchnioune.nativ.translation.preferences.v1"
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        value = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(Value.self, from: $0) } ?? Value()
    }
    var configuration: TranslationConfiguration {
        .init(languagePair: .init(source: value.sourceLanguage, target: value.targetLanguage),
              directionMode: value.directionMode, source: value.source, outputMode: value.output, provider: value.provider,
              allowExperimentalAutomaticDirection: value.automaticDirectionAccepted)
    }
}
