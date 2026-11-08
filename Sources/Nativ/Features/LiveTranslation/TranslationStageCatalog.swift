import Foundation
import NativTranslationKit

/// The installed runtime's task inventory is necessary, but does not establish a
/// model's language support or translation quality. Keep those facts separate.
@MainActor
enum TranslationStageCatalog {
    enum Role: String, Sendable { case recognition, translation, speech }
    enum SupportStatus: String, Sendable { case experimental, unsupported }
    enum LanguageEvidence: String, Sendable { case documented, experimental }
    struct Descriptor: Equatable, Sendable {
        let modelID: String
        let family: String
        let displayName: String
        let role: Role
        var languages: Set<String> = []
        var languageEvidence: LanguageEvidence = .documented
        var voices: [String] = []
        var requiresReference = false
        var requiresReferenceText = false
        var supportStatus: SupportStatus = .experimental
        var preparationIssues: [String] = []
        var notes: [String] = []
        var languageArguments: [String: String] = [:]
        var suppliesLanguageHint = true
        // Current HTTP adapters return a complete phrase, even if the underlying
        // model has a separate streaming API. LFM3-Omni uses its own renderer.
        let streamsAudio = false
        var isSelectable: Bool { supportStatus != .unsupported }
        func requestLanguage(_ language: String) -> String? {
            suppliesLanguageHint ? (languageArguments[language] ?? language) : nil
        }
    }

    static func describe(model: LocalModel, role: Role) -> Descriptor {
        let metadata = model.snapshotURL.flatMap { try? Data(contentsOf: $0.appendingPathComponent("config.json")) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let eligible: Bool
        switch role {
        case .recognition: eligible = model.capabilities.contains(.speechToText)
        case .translation: eligible = model.isEligibleForLanguageModelPicker
        case .speech: eligible = model.capabilities.contains(.textToSpeech)
        }
        return describe(modelID: model.repoID, configuration: metadata, role: role,
                        taskAvailable: eligible, snapshot: model.snapshotURL)
    }

    /// Also used by fixture tests: no model loading, downloads, or runtime start.
    static func describe(modelID: String, configuration: [String: Any], role: Role,
                         taskAvailable: Bool, snapshot: URL? = nil) -> Descriptor {
        let family = (configuration["model_type"] as? String ?? "unknown").lowercased()
        var result = Descriptor(modelID: modelID, family: family, displayName: modelID, role: role)
        guard taskAvailable else {
            result.supportStatus = .unsupported
            result.notes = ["The bundled runtime does not expose this model for the selected task."]
            return result
        }
        switch role {
        case .translation:
            // The task inventory already excludes embedding, reranking and
            // drafter-only models. An instruction model can be selected
            // independently of ASR/TTS; its selected language pair stays untested.
            result.languageEvidence = .experimental
            result.notes = ["Local text-generation adapter. Language-pair quality is untested; an instruction-tuned model is required. No pair inherits another model's qualification."]
            if family == "lfm3" {
                result.languages = LFMLanguageSupport.documentedTextLanguages
                result.notes.append("LFM text support does not imply LFM audio or speech support.")
            }
        case .recognition:
            switch family {
            case "whisper":
                result.languages = (configuration["n_vocab"] as? Int ?? 0) >= 51_865 ? whisperLanguages : ["en"]
                result.notes = ["Complete-phrase transcription. Whisper's English translation task is never used for arbitrary target languages."]
            case "qwen3_asr":
                let names = configuration["support_languages"] as? [String] ?? []
                result.languageArguments = languageMap(names)
                result.languages = Set(result.languageArguments.keys).intersection(qwenASRLanguages)
                if result.languages.isEmpty { result.preparationIssues.append("Qwen3-ASR must declare support_languages in its complete configuration.") }
                result.notes = ["Documented ASR languages intersected with this snapshot's language configuration. Translation and speech are separate models."]
            case "parakeet", "nemo":
                // v2 is English-only; do not promote every Parakeet checkpoint
                // to the multilingual v3 capability merely from its loader.
                let name = modelID.lowercased().split(separator: "/").last.map(String.init) ?? ""
                if name == "parakeet-tdt-0.6b-v3" || name.hasPrefix("parakeet-tdt-0.6b-v3-") {
                    result.languages = parakeetV3Languages
                } else if name == "parakeet-tdt-0.6b-v2" || name.hasPrefix("parakeet-tdt-0.6b-v2-") {
                    result.languages = ["en"]
                } else {
                    result.supportStatus = .unsupported
                    result.notes = ["This Parakeet variant has no reviewed language profile. Choose an explicit v2 or v3 checkpoint."]
                }
                result.suppliesLanguageHint = false
                result.notes.append("Parakeet transcribes its detected language; it does not accept a forced source-language hint. Direction remains explicitly selected in Translate.")
            default:
                result.supportStatus = .unsupported
                result.notes = ["The runtime has an ASR loader, but Translate has no reviewed language and request adapter for this family yet."]
            }
        case .speech:
            switch family {
            case "chatterbox":
                let multilingual = configuration["multilingual"] as? Bool == true
                result.languages = multilingual ? chatterboxLanguages : ["en"]
                result.requiresReference = true
                result.notes = ["Complete-phrase audio. Requires a permitted local voice reference and prepared S3TokenizerV2 assets.",
                    "S3TokenizerV2's conversion does not declare a license; its distribution provenance still needs review before a bundled release."]
                if multilingual { result.notes.append("Multilingual Chatterbox has 23 documented languages; this is not a per-language quality qualification.") }
            case "qwen3_tts", "qwen3":
                let kind = configuration["tts_model_type"] as? String ?? ""
                guard kind == "custom_voice" || kind == "base" else {
                    result.supportStatus = .unsupported
                    result.notes = ["Choose Qwen3-TTS CustomVoice or Base. VoiceDesign needs a separate instruction adapter and is not substituted automatically."]
                    return result
                }
                let talker = configuration["talker_config"] as? [String: Any] ?? [:]
                result.languageArguments = languageMap(Array((talker["codec_language_id"] as? [String: Any] ?? [:]).keys))
                result.languages = Set(result.languageArguments.keys).intersection(qwenTTSLanguages)
                result.voices = Array((talker["spk_id"] as? [String: Any] ?? [:]).keys).sorted()
                result.requiresReference = kind == "base"
                result.requiresReferenceText = kind == "base"
                if kind == "custom_voice" && result.voices.isEmpty { result.preparationIssues.append("CustomVoice requires the model's preset speaker table.") }
                if result.languages.isEmpty { result.preparationIssues.append("Qwen3-TTS requires codec_language_id in its talker configuration.") }
                result.notes = ["Complete-phrase HTTP adapter; no streaming claim. Ten documented languages, excluding Dutch. Base requires both a permitted reference and its accurate transcript."]
            case "kokoro":
                // The current pinned Python distribution excludes Misaki and
                // its language-specific G2P data. Do not advertise a route that
                // would fail or fetch those assets after capture begins.
                result.supportStatus = .unsupported
                result.preparationIssues.append("This bundled runtime does not include prepared Kokoro Misaki/eSpeak language assets. Use a supported local TTS model; installing model weights alone is insufficient.")
                result.languages = kokoroLanguages
                result.languageArguments = ["en": "a", "es": "e", "fr": "f", "hi": "h", "it": "i", "pt": "p", "ja": "j", "zh": "z"]
                if let snapshot {
                    result.voices = (try? FileManager.default.contentsOfDirectory(at: snapshot.appendingPathComponent("voices"), includingPropertiesForKeys: nil))?
                        .filter { $0.pathExtension == "safetensors" }.map { $0.deletingPathExtension().lastPathComponent }.sorted() ?? []
                }
                if result.voices.isEmpty { result.preparationIssues.append("Install local voices/*.safetensors with this Kokoro snapshot. A voice is never downloaded at session start.") }
                result.notes = ["Complete-phrase audio. Eight language codes (US/UK English share en); Dutch is unsupported. Language-specific Misaki and eSpeak assets must be prepared locally."]
            default:
                result.supportStatus = .unsupported
                result.notes = ["The runtime has a speech loader, but Translate has no reviewed language, voice and offline-asset adapter for this family yet."]
            }
        }
        return result
    }

    static func voiceSupports(language: String, voice: String, descriptor: Descriptor) -> Bool {
        guard descriptor.voices.contains(voice) else { return false }
        guard descriptor.family == "kokoro" else { return true }
        let prefixes = language == "en" ? Set(["a", "b"]) : Set([descriptor.languageArguments[language] ?? ""])
        return voice.first.map { prefixes.contains(String($0)) } ?? false
    }

    private static func languageMap(_ names: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for name in names {
            let lowered = name.lowercased()
            if let code = languageNames[lowered] { result[code] = name }
            else if Set(languageNames.values).contains(lowered) { result[lowered] = name }
        }
        return result
    }
    static let whisperLanguages = Set("en zh de es ru ko fr ja pt tr pl ca nl ar sv it id hi fi vi he uk el ms cs ro da hu ta no th ur hr bg lt la mi ml cy sk te fa lv bn sr az sl kn et mk br eu is hy ne mn bs kk sq sw gl mr pa si km sn yo so af oc ka be tg sd gu am yi lo uz fo ht ps tk nn mt sa lb my bo tl mg as tt haw ln ha ba jw su yue".split(separator: " ").map(String.init))
    static let chatterboxLanguages = Set("ar da de el en es fi fr he hi it ja ko ms nl no pl pt ru sv sw tr zh".split(separator: " ").map(String.init))
    static let qwenASRLanguages = Set("zh en yue ar de fr es pt id it ko ru th vi ja tr hi ms nl sv da fi pl cs fil fa el hu mk ro".split(separator: " ").map(String.init))
    static let parakeetV3Languages = Set("bg hr cs da nl en et fi fr de el hu it lv lt mt pl pt ro sk sl es sv ru uk".split(separator: " ").map(String.init))
    static let qwenTTSLanguages = Set("zh en ja ko de fr ru pt es it".split(separator: " ").map(String.init))
    static let kokoroLanguages = Set("en es fr hi it pt ja zh".split(separator: " ").map(String.init))
    private static let languageNames = ["chinese": "zh", "english": "en", "cantonese": "yue", "arabic": "ar", "german": "de", "french": "fr", "spanish": "es", "portuguese": "pt", "indonesian": "id", "italian": "it", "korean": "ko", "russian": "ru", "thai": "th", "vietnamese": "vi", "japanese": "ja", "turkish": "tr", "hindi": "hi", "malay": "ms", "dutch": "nl", "swedish": "sv", "danish": "da", "finnish": "fi", "polish": "pl", "czech": "cs", "filipino": "fil", "persian": "fa", "greek": "el", "hungarian": "hu", "macedonian": "mk", "romanian": "ro"]
}
