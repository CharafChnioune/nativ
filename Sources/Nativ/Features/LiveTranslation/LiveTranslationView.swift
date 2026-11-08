import AppKit
import AVFoundation
import NativTranslationKit
import SwiftUI
import UniformTypeIdentifiers

struct LiveTranslationView: View {
    @ObservedObject var coordinator: LiveTranslationCoordinator
    @ObservedObject private var preferences: LiveTranslationSettings
    @ObservedObject private var modelStore: TranslationModelStore
    @ObservedObject private var inputs = AudioInputDevicePreferences.shared
    let model: NativModel
    var titleLeadingInset: CGFloat = 0
    var openModels: () -> Void
    @State private var outputs: [TranslationOutputDevice] = []
    @State private var models: [LocalModel] = []
    @State private var stageDescriptors: [String: TranslationStageCatalog.Descriptor] = [:]
    @State private var isRecordingShortcut = false
    @State private var modelScanError: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(coordinator: LiveTranslationCoordinator, model: NativModel, titleLeadingInset: CGFloat = 0, openModels: @escaping () -> Void) {
        self.coordinator = coordinator; preferences = coordinator.settings; modelStore = coordinator.modelStore
        self.model = model; self.titleLeadingInset = titleLeadingInset; self.openModels = openModels
    }
    private var languages: [String] {
        var candidates = LFMLanguageSupport.documentedSpeechLanguages.union(LFMLanguageSupport.documentedTextLanguages)
        for descriptor in stageDescriptors.values { candidates.formUnion(descriptor.languages) }
        candidates.formUnion([preferences.value.sourceLanguage, preferences.value.targetLanguage])
        return candidates.sorted { languageName($0) < languageName($1) }
    }
    private func languageName(_ code: String) -> String { Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Translate").legacyTextStyle(.pageTitle)
                        Text("Private, local translation for spoken turns.").legacyTextStyle(.supporting).foregroundStyle(.secondary)
                    }
                    Spacer()
                    NativStatusBadge(text: "Experimental", tone: .warning, showsDot: true)
                }.padding(.leading, titleLeadingInset)
                sessionPanel
                directionPanel
                providerPanel
                resourcePanel
                audioPanel
                transcriptPanel
                DisclosureGroup("Capabilities and measured evidence") { evidencePanel.padding(.top, 12) }
                    .padding(18).nativPanelStyle()
                DisclosureGroup("Overlay and shortcut") { interactionPanel.padding(.top, 12) }
                    .padding(18).nativPanelStyle()
            }
            .padding(24).frame(maxWidth: 1060).frame(maxWidth: .infinity)
        }
        .task { await refreshDevicesAndModels() }
        .onChange(of: isRecordingShortcut) { _, capturing in
            coordinator.setShortcutCaptureActive(capturing)
            VoiceShortcutPreferences.shared.isCapturingShortcut = capturing
        }
        .onDisappear {
            if isRecordingShortcut {
                coordinator.setShortcutCaptureActive(false)
                VoiceShortcutPreferences.shared.isCapturingShortcut = false
            }
        }
        .sheet(isPresented: $isRecordingShortcut) {
            VStack(spacing: 18) {
                Text("Translation shortcut").legacyTextStyle(.sheetTitle)
                Text("Press a key with Control, Option, Shift or Command. Audio shortcuts remain separate.")
                    .legacyTextStyle(.supporting).frame(maxWidth: 360)
                TranslationShortcutRecorder { value in preferences.value.shortcut = value; isRecordingShortcut = false }
                    .frame(width: 320, height: 50)
                Button("Cancel") { isRecordingShortcut = false }.keyboardShortcut(.cancelAction)
            }.padding(24)
        }
    }
    private var sessionPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                if (coordinator.isListening || coordinator.isSpeaking) && !reduceMotion {
                    VoiceGradientOrb(level: coordinator.isSpeaking ? coordinator.outputLevel : coordinator.inputLevel, isRecording: true).frame(width: 46, height: 46).accessibilityHidden(true)
                } else {
                    Image(systemName: coordinator.isSpeaking ? "speaker.wave.2" : "waveform").font(.system(size: 25)).frame(width: 46, height: 46)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(coordinator.status).legacyTextStyle(.cardTitle)
                    Text(coordinator.providerTitle + " · " + (preferences.value.source == .microphone ? "Microphone" : "System audio"))
                        .legacyTextStyle(.metadata).foregroundStyle(.secondary)
                    Text(activeModelDescription).legacyTextStyle(.metadata).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                if coordinator.state == .preparing { ProgressView().controlSize(.small).accessibilityLabel(coordinator.status) }
            }
            HStack {
                if coordinator.state == .running {
                    Button("Pause", systemImage: "pause.fill") { coordinator.pause() }
                } else {
                    Button(coordinator.state == .paused ? "Resume" : "Start", systemImage: "play.fill", action: coordinator.start)
                        .buttonStyle(.borderedProminent).disabled(!coordinator.canStart)
                }
                Button("Stop", systemImage: "stop.fill", action: coordinator.stop)
                    .disabled(coordinator.state == .idle || coordinator.state == .stopped)
                Button(coordinator.isMuted ? "Unmute speech" : "Mute speech", systemImage: coordinator.isMuted ? "speaker.slash" : "speaker.wave.2", action: coordinator.toggleMute)
                Spacer()
                Button("Interrupt speech", action: coordinator.interruptSpeech).disabled(coordinator.state != .running)
            }
            HStack(spacing: 18) {
                Label(coordinator.isListening ? "Listening" : "Input paused", systemImage: "mic")
                Label(coordinator.isGenerating ? "Translating" : "No generation", systemImage: "cpu")
                Label(coordinator.isSpeaking ? "Speaking" : "Output quiet", systemImage: "speaker.wave.2")
            }.legacyTextStyle(.metadata).foregroundStyle(.secondary)
            if let error = coordinator.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
                Button("Open model settings", action: openModels).controlSize(.small)
            }
            if coordinator.canRetry {
                Button("Retry retained turn (expires after 30 seconds)", action: coordinator.retryLastTurn)
                    .disabled(coordinator.isGenerating)
            }
            if coordinator.canReplay {
                HStack {
                    Button("Retranslate last recording") { coordinator.replayLastTurn() }
                    Button("Swap direction and retranslate") { coordinator.replayLastTurn(swappingDirection: true) }
                }.disabled(coordinator.isGenerating)
                Text("One recording is kept in memory for up to 30 seconds. Stop or changing settings clears it.")
                    .legacyTextStyle(.metadata).foregroundStyle(.secondary)
            }
            if !coordinator.incompleteIntervals.isEmpty {
                Text("Incomplete input: \(coordinator.incompleteIntervals.count) interval(s). Repeat the affected speech; the transcript is not continuous.")
                    .legacyTextStyle(.supporting).foregroundStyle(.orange)
                ForEach(Array(coordinator.incompleteIntervals.suffix(4).enumerated()), id: \.offset) { _, interval in
                    if let start = interval.startCaptureTimestampNanoseconds, let end = interval.endCaptureTimestampNanoseconds {
                        Text("\(interval.sourceID ?? "Input"): \(Double(start) / 1e9, specifier: "%.2f")–\(Double(end) / 1e9, specifier: "%.2f") s (capture clock)")
                            .legacyTextStyle(.metadata)
                    }
                }
            }
        }.padding(20).nativPanelStyle(isHighlighted: coordinator.state == .running)
    }
    private var activeModelDescription: String {
        let value = preferences.value
        guard value.provider == .localCascade else { return "LFM3-Omni 2B · " + value.quantization + " · model voice" }
        let speech: String
        if value.output == .captions { speech = "Captions only" }
        else {
            switch value.speechProvider {
            case .omni: speech = "LFM3-Omni " + value.quantization
            case .chatterbox: speech = value.chatterboxModel
            case .localModel: speech = value.speechModel + (value.speechVoice.isEmpty ? "" : " · " + value.speechVoice)
            case .apple: speech = AVSpeechSynthesisVoice(identifier: value.appleVoiceID)?.name ?? "Choose a system voice"
            }
        }
        return value.recognitionModel + " → " + value.translationModel + " → " + speech
    }
    private var directionPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Language direction").legacyTextStyle(.sectionTitle)
            HStack {
                Picker("From", selection: $preferences.value.sourceLanguage) { ForEach(languages, id: \.self) { Text(languageName($0)).tag($0) } }
                Button {
                    let old = preferences.value.sourceLanguage
                    preferences.value.sourceLanguage = preferences.value.targetLanguage
                    preferences.value.targetLanguage = old
                } label: { Image(systemName: "arrow.left.arrow.right") }.help("Swap language direction").accessibilityLabel("Swap language direction")
                Picker("To", selection: $preferences.value.targetLanguage) { ForEach(languages, id: \.self) { Text(languageName($0)).tag($0) } }
            }
            if preferences.value.provider == .localCascade {
                Picker("Direction mode", selection: $preferences.value.directionMode) {
                    Text("Fixed direction").tag(TranslationDirectionMode.fixed)
                    Text("Automatic within this pair · experimental").tag(TranslationDirectionMode.automatic)
                }
                if preferences.value.directionMode == .automatic {
                    Toggle("I accept unqualified automatic direction for this pair", isOn: $preferences.value.automaticDirectionAccepted)
                    Text("Both languages must work in each selected model. Short, mixed or ambiguous input stops before speech; choose a direction and retranslate the retained recording. Detection scores are not translation-quality measurements.")
                        .legacyTextStyle(.metadata).foregroundStyle(.secondary)
                }
            } else {
                Text("LFM3-Omni uses the selected fixed direction. Automatic direction is available experimentally in the explicit local cascade.")
                    .legacyTextStyle(.supporting).foregroundStyle(.secondary)
            }
            if let pair = coordinator.detectedDirection {
                Text("Detected for this turn: " + languageName(pair.source) + " → " + languageName(pair.target) + " · experimental")
                    .legacyTextStyle(.metadata).foregroundStyle(.secondary)
            }
        }.padding(18).nativPanelStyle()
    }
    private var providerPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Local models").legacyTextStyle(.sectionTitle)
            Picker("Translation route", selection: $preferences.value.provider) {
                Text("LFM3-Omni · direct (experimental)").tag(TranslationProviderID.lfm3OmniDirect)
                Text("LFM3-Omni · same model, two passes (experimental)").tag(TranslationProviderID.lfm3OmniTwoPass)
                Text("Local cascade · choose each model").tag(TranslationProviderID.localCascade)
            }
            .onChange(of: preferences.value.provider) { _, provider in
                if provider != .localCascade { preferences.value.directionMode = .fixed }
            }
            if preferences.value.provider == .localCascade { cascadeControls }
            if preferences.value.provider != .localCascade || preferences.value.speechProvider == .omni {
                Picker("Omni precision", selection: $preferences.value.quantization) {
                    Text("Q8_0 · 2.35 GB including audio projector").tag("Q8_0")
                    Text("Q4_K_M · 1.61 GB including audio projector").tag("Q4_K_M")
                }
                HStack {
                    Button("Prepare LFM3-Omni", action: coordinator.prepareModels)
                        .disabled(coordinator.isPreparingModels || modelStore.isPreparing || coordinator.isPreparingRecognition || coordinator.isPreparingSpeech || coordinator.state == .running || coordinator.state == .preparing)
                    if coordinator.isPreparingModels { Button("Cancel preparation", action: coordinator.stop) }
                    Text(modelStore.message ?? "Official pinned model and matching Q8 audio projector.").legacyTextStyle(.metadata).foregroundStyle(.secondary)
                }
                if modelStore.totalBytes > 0 && modelStore.isPreparing {
                    ProgressView(value: Double(modelStore.completedBytes), total: Double(modelStore.totalBytes))
                    Text("\(ByteCountFormatter.string(fromByteCount: modelStore.completedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: modelStore.totalBytes, countStyle: .file))")
                        .legacyTextStyle(.metadataNumeric)
                }
            }
            Text("No route has passed interpreting and voice qualification. Q8 and Q4 trials changed a critical time and failed English → Dutch direction. Two passes did not reliably resolve this.")
                .legacyTextStyle(.supporting).foregroundStyle(.secondary)
            Toggle("I explicitly choose this experimental local route", isOn: $preferences.value.experimentalAccepted)
            Text("No automatic provider, cloud or Apple fallback. New languages need separate testing.")
                .legacyTextStyle(.metadata).foregroundStyle(.secondary)
        }.padding(18).nativPanelStyle()
    }
    private var cascadeControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            modelPicker("Recognition", selection: $preferences.value.recognitionModel, candidates: models.filter { $0.capabilities.contains(.speechToText) })
            stageEvidence(preferences.value.recognitionModel, role: .recognition)
            HStack {
                Button("Prepare Whisper tokenizer", action: coordinator.prepareRecognition)
                    .disabled(coordinator.isPreparingRecognition || coordinator.isPreparingModels || modelStore.isPreparing || coordinator.state == .running || coordinator.state == .preparing)
                if coordinator.isPreparingRecognition {
                    ProgressView().controlSize(.small)
                    Button("Cancel", action: coordinator.stop)
                }
            }
            modelPicker("Translation", selection: $preferences.value.translationModel, candidates: models.filter(\.isEligibleForLanguageModelPicker))
            stageEvidence(preferences.value.translationModel, role: .translation)
            Picker("Model memory", selection: $preferences.value.cascadeMemoryStrategy) {
                Text("Load each step separately · lower peak memory").tag(TranslationCascadeMemoryStrategy.sequential)
                Text("Keep models resident · more memory, faster reuse").tag(TranslationCascadeMemoryStrategy.resident)
            }
            Text("Sequential mode is the initial choice, including on 16 GB Macs. Resident mode is an explicit option for Macs with more free memory, including 128 GB. Neither mode changes your models; measured capacity depends on other workloads.")
                .legacyTextStyle(.metadata).foregroundStyle(.secondary)
            Picker("Speech", selection: $preferences.value.speechProvider) {
                ForEach(LiveTranslationSettings.SpeechProvider.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if preferences.value.speechProvider == .chatterbox {
                modelPicker("Chatterbox model", selection: $preferences.value.chatterboxModel, candidates: models.filter { $0.repoID.localizedCaseInsensitiveContains("chatterbox") })
                HStack {
                    Button("Choose voice recording…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.audio]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                        panel.message = "Choose a voice recording you have permission to use. It stays on this Mac."
                        if panel.runModal() == .OK, let url = panel.url { preferences.value.chatterboxReferencePath = url.path }
                    }
                    Text(preferences.value.chatterboxReferencePath.isEmpty ? "A permitted reference voice is required." : URL(fileURLWithPath: preferences.value.chatterboxReferencePath).lastPathComponent)
                        .legacyTextStyle(.metadata).lineLimit(1)
                }
                stockVoiceButton
                stageEvidence(preferences.value.chatterboxModel, role: .speech)
                Text("Playback starts after the complete phrase is generated. This is not streaming speech; long phrases may be refused.").legacyTextStyle(.metadata).foregroundStyle(.secondary)
            }
            if preferences.value.speechProvider == .localModel { localSpeechControls }
            if preferences.value.speechProvider == .chatterbox || preferences.value.speechProvider == .localModel {
                HStack {
                    Button("Prepare selected speech assets", action: coordinator.prepareSpeech)
                        .disabled(coordinator.isPreparingSpeech || coordinator.isPreparingRecognition || coordinator.isPreparingModels || modelStore.isPreparing || coordinator.state == .running || coordinator.state == .preparing)
                    if coordinator.isPreparingSpeech { ProgressView().controlSize(.small); Button("Cancel", action: coordinator.stop) }
                }
            }
            if preferences.value.speechProvider == .apple {
                Picker("System voice", selection: $preferences.value.appleVoiceID) {
                    Text("Choose an installed voice").tag("")
                    ForEach(AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(preferences.value.targetLanguage) }, id: \.identifier) {
                        Text("\($0.name) · \($0.language)").tag($0.identifier)
                    }
                }
                Text("Apple speech is an explicit optional renderer. Its language and voice depend on the installed system voices.").legacyTextStyle(.metadata)
            }
            HStack { Button("Manage models", action: openModels); Button("Refresh installed models") { Task { await refreshDevicesAndModels() } } }
            if let modelScanError { Text(modelScanError).foregroundStyle(.orange) }
            Text("Initial evaluation profile: Whisper large-v3-turbo → Gemma 4 E4B → LFM3-Omni. Combined memory and voice quality need qualification on each Mac and workload.")
                .legacyTextStyle(.supporting).foregroundStyle(.secondary)
        }
    }
    private var localSpeechControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            modelPicker("Local speech model", selection: $preferences.value.speechModel, candidates: models.filter { $0.capabilities.contains(.textToSpeech) })
            if let descriptor = stageDescriptors[descriptorKey(preferences.value.speechModel, .speech)] {
                if !descriptor.voices.isEmpty {
                    Picker("Voice", selection: $preferences.value.speechVoice) {
                        Text("Choose a model voice").tag("")
                        ForEach(descriptor.voices, id: \.self) { Text($0).tag($0) }
                    }
                }
                if descriptor.requiresReference {
                    HStack {
                        Button("Choose voice recording…") {
                            let panel = NSOpenPanel()
                            panel.allowedContentTypes = [.audio]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                            panel.message = "Choose a voice recording you have permission to use. It stays on this Mac."
                            if panel.runModal() == .OK, let url = panel.url { preferences.value.speechReferencePath = url.path }
                        }
                        Text(preferences.value.speechReferencePath.isEmpty ? "A permitted local voice reference is required." : URL(fileURLWithPath: preferences.value.speechReferencePath).lastPathComponent)
                            .legacyTextStyle(.metadata).lineLimit(1)
                    }
                }
                if descriptor.requiresReference { stockVoiceButton }
                if descriptor.requiresReferenceText {
                    TextField("Exact transcript of the voice recording", text: $preferences.value.speechReferenceText, axis: .vertical)
                        .lineLimit(2...4).textFieldStyle(.roundedBorder)
                }
            }
            stageEvidence(preferences.value.speechModel, role: .speech)
        }
    }
    private var stockVoiceButton: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Prepare and choose Thorsten stock voice (German, CC0)", action: coordinator.prepareStockVoice)
                .disabled(coordinator.isPreparingSpeech || coordinator.isPreparingRecognition || coordinator.isPreparingModels || modelStore.isPreparing || coordinator.state == .running || coordinator.state == .preparing)
            Text("An original recording released by its speaker for TTS. Downloads under 350 KB; pronunciation, expression and cross-language quality still need your assessment.")
                .legacyTextStyle(.metadata).foregroundStyle(.secondary)
        }
    }
    private func descriptorKey(_ id: String, _ role: TranslationStageCatalog.Role) -> String { role.rawValue + ":" + id }
    @ViewBuilder
    private func stageEvidence(_ id: String, role: TranslationStageCatalog.Role) -> some View {
        if let descriptor = stageDescriptors[descriptorKey(id, role)] {
            VStack(alignment: .leading, spacing: 4) {
                Text(descriptor.supportStatus == .unsupported ? "Adapter unavailable" : "Experimental · not qualified")
                    .legacyTextStyle(.metadata).foregroundStyle(descriptor.supportStatus == .unsupported ? .orange : .secondary)
                if !descriptor.languages.isEmpty {
                    Text((descriptor.languageEvidence == .documented ? "Documented languages: " : "Candidate languages: ") + descriptor.languages.sorted().map(languageName).joined(separator: ", "))
                        .legacyTextStyle(.metadata).foregroundStyle(.secondary)
                }
                ForEach(descriptor.notes, id: \.self) { Text($0).legacyTextStyle(.metadata).foregroundStyle(.secondary) }
                ForEach(descriptor.preparationIssues, id: \.self) { Text($0).legacyTextStyle(.metadata).foregroundStyle(.orange) }
                if role == .speech, !descriptor.languages.contains(preferences.value.targetLanguage) {
                    Text("This speech model does not support " + languageName(preferences.value.targetLanguage) + ". Choose another model or captions.")
                        .legacyTextStyle(.metadata).foregroundStyle(.orange)
                }
            }
        }
    }
    private var resourcePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("This Mac").legacyTextStyle(.sectionTitle)
                Spacer()
                Button("Refresh", action: coordinator.refreshResourceAssessment).controlSize(.small)
            }
            Text(coordinator.resourceAssessment.hardwareLabel).legacyTextStyle(.supporting)
            Text(coordinator.resourceAssessment.explanation).legacyTextStyle(.metadata).foregroundStyle(.secondary)
            if let bytes = coordinator.resourceAssessment.selectedWeightBytes {
                Text("Selected model files: " + ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
                     + ". Runtime allocations and other applications require additional memory.")
                    .legacyTextStyle(.metadata).foregroundStyle(.secondary)
            } else {
                Text("The combined model footprint has not been estimated. No model is changed automatically.")
                    .legacyTextStyle(.metadata).foregroundStyle(.secondary)
            }
        }.padding(18).nativPanelStyle()
    }
    private func modelPicker(_ title: String, selection: Binding<String>, candidates: [LocalModel]) -> some View {
        Picker(title, selection: selection) {
            if !candidates.contains(where: { $0.repoID == selection.wrappedValue }) {
                Text(selection.wrappedValue + " · not installed").tag(selection.wrappedValue)
            }
            ForEach(candidates) { Text($0.displayTitle).tag($0.repoID) }
        }
    }
    private var audioPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Audio route").legacyTextStyle(.sectionTitle)
            Picker("Source", selection: $preferences.value.source) {
                Text("Microphone").tag(TranslationSource.microphone)
                Text("System audio · separate stream").tag(TranslationSource.systemAudio)
            }.onChange(of: preferences.value.source) { _, source in
                if source == .systemAudio { preferences.value.output = .captions }
            }
            if preferences.value.source == .microphone {
                Picker("Input", selection: $preferences.value.inputDeviceID) {
                    Text("System default").tag("")
                    ForEach(inputs.recordingDevices.filter { !$0.id.isEmpty }) { Text($0.name).tag($0.id) }
                }
            } else {
                Text("Screen Recording permission is requested only at Start. Microphone and Nativ's own output are excluded.").legacyTextStyle(.supporting).foregroundStyle(.secondary)
            }
            Picker("Output", selection: $preferences.value.output) {
                Text("Captions").tag(TranslationOutputMode.captions)
                Text("Speech and captions").tag(TranslationOutputMode.speechAndCaptions)
            }
            if preferences.value.output == .speechAndCaptions {
                Picker("Playback device", selection: $preferences.value.outputDeviceID) {
                    Text("System default").tag(UInt32(0))
                    ForEach(outputs) { Text($0.name).tag($0.id) }
                }
                Toggle("I am using headphones for speech playback", isOn: $preferences.value.headphones)
                Text(preferences.value.headphones ? "Ordered turns continue while speech plays; overload stops with an incomplete-input notice." : "Speaker mode pauses the microphone during speech. System-audio speech requires headphones.")
                    .legacyTextStyle(.supporting).foregroundStyle(.secondary)
            }
            Button("Refresh audio devices") { outputs = TranslationOutputDevice.available(); inputs.refresh() }.controlSize(.small)
        }.padding(18).nativPanelStyle()
    }
    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Conversation").legacyTextStyle(.sectionTitle)
                Spacer()
                Button("Copy completed", action: coordinator.copyCompletedText).disabled(coordinator.turns.isEmpty)
                Button("Export…", action: coordinator.exportCompletedText).disabled(coordinator.turns.isEmpty)
                Button("Clear", action: coordinator.clearTranscript)
            }
            if coordinator.turns.isEmpty && coordinator.translatedText.isEmpty {
                Text("Completed turns appear here. Nothing is saved automatically.").foregroundStyle(.secondary)
            }
            if coordinator.discardedTranscriptTurnCount > 0 {
                Text("Only the latest 200 completed turns are retained. Earlier turns no longer available: \(coordinator.discardedTranscriptTurnCount).")
                    .legacyTextStyle(.metadata).foregroundStyle(.secondary)
            }
            ForEach(coordinator.turns, id: \.turnID) { turn in
                VStack(alignment: .leading, spacing: 5) {
                    if let source = turn.sourceText { Text(source).foregroundStyle(.secondary) }
                    Text(turn.translatedText)
                    if turn.incomplete { Text("Incomplete turn").foregroundStyle(.orange).legacyTextStyle(.metadata) }
                }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            if !coordinator.translatedText.isEmpty && !coordinator.currentTurnIsComplete {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Current turn · may be revised").legacyTextStyle(.metadata).foregroundStyle(.secondary)
                    if !coordinator.sourceText.isEmpty { Text(coordinator.sourceText).foregroundStyle(.secondary) }
                    Text(coordinator.translatedText).textSelection(.enabled)
                }
            }
        }.legacyTextStyle(.body).padding(18).nativPanelStyle()
    }
    private var evidencePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Documented ≠ technically tested ≠ qualified").legacyTextStyle(.cardTitle)
            Text("LFM3-Omni speech languages: " + LFMLanguageSupport.documentedSpeechLanguages.sorted().map(languageName).joined(separator: ", "))
            Text("Documented text languages: " + LFMLanguageSupport.documentedTextLanguages.sorted().map(languageName).joined(separator: ", "))
            Text("Dutch is in the speech list, but not the published text-language list. Dutch translation remains experimental. Unsupported speech targets are refused.")
            Divider()
            Text("Technically tested: Q8/Q4 loopback authentication, PCM16 realtime input/output, float32 TTS streaming, cancellation and fresh contexts. No bilingual pair or main voice is qualified.")
            Text("Human meaning, naturalness, prosody and emotional intent still need review. Warm/cold latency percentiles, a 30-minute endurance run and acoustic stop-to-silence are not measured.")
            if !coordinator.latestMetrics.isEmpty {
                Text("Current session diagnostics (not acoustic latency)").legacyTextStyle(.supportingEmphasized)
                ForEach(coordinator.latestMetrics.keys.sorted { $0.rawValue < $1.rawValue }, id: \.self) { key in
                    Text("\(key.rawValue): \(coordinator.latestMetrics[key] ?? 0, specifier: "%.1f")").monospacedDigit()
                }
            }
            Text("Live turn/phrase translation; no full-duplex claim. Original recordings are required to qualify each direction and voice.")
        }.legacyTextStyle(.supporting).foregroundStyle(.secondary).textSelection(.enabled)
    }
    private var interactionPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Show compact overlay during the session", isOn: $preferences.value.overlay)
            HStack { Text("Global toggle: " + preferences.value.shortcut.displayName); Button("Change…") { isRecordingShortcut = true } }
            if let message = coordinator.shortcutMessage { Text(message).foregroundStyle(.orange) }
            Text("All windows share this session. Sleep, lock and extension removal stop capture; resuming is always explicit.")
                .legacyTextStyle(.supporting).foregroundStyle(.secondary)
        }
    }
    private func refreshDevicesAndModels() async {
        outputs = TranslationOutputDevice.available(); inputs.refresh()
        do {
            models = try await LocalModelDiscovery.scan(searchPaths: .init(primary: model.settings.modelSearchPath,
                                                                          additional: model.settings.additionalModelSearchPaths))
            var descriptors: [String: TranslationStageCatalog.Descriptor] = [:]
            for installed in models {
                for role in [TranslationStageCatalog.Role.recognition, .translation, .speech] {
                    descriptors[descriptorKey(installed.repoID, role)] = TranslationStageCatalog.describe(model: installed, role: role)
                }
            }
            stageDescriptors = descriptors
            modelScanError = nil
        } catch { modelScanError = "Could not scan installed models. Check the model cache in Settings." }
    }
}

private struct TranslationShortcutRecorder: NSViewRepresentable {
    let onCapture: (VoiceShortcut) -> Void
    func makeNSView(context: Context) -> Recorder { let view = Recorder(); view.onCapture = onCapture; return view }
    func updateNSView(_ view: Recorder, context: Context) { view.onCapture = onCapture }
    final class Recorder: NSView {
        var onCapture: ((VoiceShortcut) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.makeFirstResponder(self) }
        override func keyDown(with event: NSEvent) {
            let modifiers = VoiceShortcutModifiers(eventFlags: event.modifierFlags)
            guard !modifiers.isEmpty, event.keyCode != 53 else { return }
            onCapture?(.init(keyCode: event.keyCode, keyDisplay: VoiceShortcut.keyDisplay(for: event), modifiers: modifiers))
        }
    }
}
