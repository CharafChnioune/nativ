import Combine
import Foundation
import NativTranslationKit

/// Only explicit preferences are durable. Audio and transcript content are not saved.
@MainActor
final class LiveTranslationSettings: ObservableObject {
    enum SpeechProvider: String, Codable, CaseIterable {
        case omni, chatterbox, apple
        var title: String {
            switch self {
            case .omni: "LFM3-Omni · local streaming"
            case .chatterbox: "Chatterbox · complete phrases"
            case .apple: "Apple system voice · optional"
            }
        }
    }
    struct Value: Codable, Equatable {
        var sourceLanguage = "nl"
        var targetLanguage = "en"
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
              directionMode: .fixed, source: value.source, outputMode: value.output, provider: value.provider)
    }
}
