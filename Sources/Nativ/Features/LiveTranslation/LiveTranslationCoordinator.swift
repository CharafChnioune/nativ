import AppKit
import Combine
import Foundation
import NativTranslationKit
import UniformTypeIdentifiers

/// One owner per app, shared by extension pages and the compact overlay.
@MainActor
final class LiveTranslationCoordinator: ObservableObject {
    let settings: LiveTranslationSettings
    let modelStore: TranslationModelStore
    @Published private(set) var state: TranslationSessionState = .idle
    @Published private(set) var status = "Ready to prepare"
    @Published private(set) var errorMessage: String?
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var outputLevel: Float = 0
    @Published private(set) var isSpeaking = false
    @Published private(set) var isListening = false
    @Published private(set) var isGenerating = false
    @Published private(set) var isMuted = false
    @Published private(set) var sourceText = ""
    @Published private(set) var translatedText = ""
    @Published private(set) var turns: [TranslationTranscriptTurn] = []
    @Published private(set) var discardedTranscriptTurnCount = 0
    @Published private(set) var incompleteIntervals: [TranslationIncompleteInterval] = []
    @Published private(set) var latestMetrics: [TranslationMetric.Name: Double] = [:]
    @Published private(set) var capabilities: TranslationCapabilities?
    @Published private(set) var enabled = false
    @Published private(set) var shortcutMessage: String?
    @Published private(set) var canRetry = false
    @Published private(set) var canReplay = false
    @Published private(set) var detectedDirection: TranslationLanguagePair?
    @Published private(set) var isPreparingRecognition = false
    @Published private(set) var isPreparingModels = false
    @Published private(set) var isPreparingSpeech = false
    @Published private(set) var resourceAssessment = TranslationResourceAssessment(hardware: .current(), selectedWeightBytes: nil)

    var configurationProvider: (@MainActor () -> VoiceTranscriptionConfiguration?)?
    struct CascadeServices: Sendable {
        let runtime: TranslationCascadeRuntime
        let resources: any TranslationCascadeResources
        let omniEndpoint: @Sendable () async throws -> LFMRuntimeEndpoint
    }
    var cascadeBackendProvider: (@MainActor (LiveTranslationSettings.Value, CascadeServices) async throws -> any TranslationBackend)?
    var recognitionPreparationProvider: (@MainActor (LiveTranslationSettings.Value) async throws -> Void)?
    var speechPreparationProvider: (@MainActor (LiveTranslationSettings.Value) async throws -> String)?
    private let runtime = TranslationRuntimeController()
    private let cascadeRuntime = TranslationCascadeRuntime()
    private let capture = TranslationAudioCapture()
    private let systemCapture = TranslationSystemAudioCapture()
    private let playback = TranslationAudioPlayback()
    private var session: TranslationSession?
    private var segmenter: TranslationSpeechSegmenter?
    private var runID = UUID()
    private var inputEpoch = UUID()
    private var minimumOutputGeneration: TranslationGeneration?
    private let outputOperations = TranslationHostOperationGate()
    private let commandOperations = TranslationHostOperationGate()
    private let preparationOperations = TranslationHostOperationGate()
    private let inputOperations = TranslationHostOperationGate()
    private var inputSequence: UInt64 = 0
    private var operation: Task<Void, Never>?
    private var interruptionTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var teardown: Task<Void, Never>?
    private var sourceAccumulator = TranslationTextAccumulator()
    private var targetAccumulator = TranslationTextAccumulator()
    private var currentTextTurn: TranslationTurnID?
    private var observers: [NSObjectProtocol] = []
    private var distributedObserver: NSObjectProtocol?
    private var settingsObservation: AnyCancellable?
    private var observedSettings: LiveTranslationSettings.Value
    private var interrupting = false
    private var speakerPaused = false
    private var resumeCaptureTask: Task<Void, Never>?
    private var speakerCaptureTeardown: Task<Void, Never>?
    private var shortcutMonitor: TranslationShortcutMonitor?
    private var capturingShortcut = false
    private var overlay: LiveTranslationOverlay?
    private var memoryPressureMonitor: DispatchSourceMemoryPressure?

    init(settings: LiveTranslationSettings = .init()) {
        self.settings = settings
        observedSettings = settings.value
        modelStore = TranslationModelStore(
            reserve: { try HuggingFaceDownloadCapacity.shared.reserve($0, bytes: $1, atPath: $2) },
            release: { HuggingFaceDownloadCapacity.shared.release($0) })
        capture.onMeterUpdate = { [weak self] in self?.inputLevel = $0 }
        systemCapture.onMeterUpdate = { [weak self] in self?.inputLevel = $0 }
        playback.onMeterUpdate = { [weak self] in self?.outputLevel = $0 }
        playback.onFailure = { [weak self] error in
            guard let self else { return }
            self.fail(error, id: self.runID)
        }
        playback.onPlayingChanged = { [weak self] playing in
            guard let self else { return }
            self.isSpeaking = playing
            if let session = self.session { Task { await session.setOutputPlaying(playing) } }
            if !playing { self.scheduleSpeakerResume() }
        }
        settingsObservation = settings.$value.dropFirst().removeDuplicates().sink { [weak self] value in
            // @Published emits before storage changes. Defer UI application until it contains the new value.
            Task { @MainActor [weak self] in
                guard let self, self.settings.value == value else { return }
                let requiresReset = value.requiresFreshSession(comparedTo: self.observedSettings)
                self.observedSettings = value
                if requiresReset, [.running, .preparing, .paused].contains(self.state) || self.isPreparingModels || self.modelStore.isPreparing || self.isPreparingRecognition || self.isPreparingSpeech {
                    self.end(state: .paused, message: "Settings changed. Resume to start a fresh context.", unload: false)
                }
                self.installShortcut()
                self.refreshResourceAssessment()
                self.updateOverlay()
            }
        }
    }

    var canStart: Bool { enabled && settings.value.experimentalAccepted && (settings.value.directionMode != .automatic || settings.value.automaticDirectionAccepted) && !isPreparingModels && !modelStore.isPreparing && !isPreparingRecognition && !isPreparingSpeech && state != .preparing && state != .running }
    var providerTitle: String {
        switch settings.value.provider {
        case .lfm3OmniDirect: "LFM3-Omni · direct"
        case .lfm3OmniTwoPass: "LFM3-Omni · two passes"
        case .localCascade: "Local cascade"
        case .appleSpeech: "Apple speech"
        }
    }
    var spokenOutputRequested: Bool {
        settings.value.output == .speechAndCaptions && (settings.value.source != .systemAudio || settings.value.headphones)
    }

    func activate() {
        guard !enabled else { return }
        enabled = true
        refreshResourceAssessment()
        let monitor = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        monitor.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.enabled else { return }
                self.refreshResourceAssessment()
                if self.memoryPressureMonitor?.data.contains(.critical) == true || !self.resourceAssessment.canAttemptLoad {
                    self.pause(reason: "Paused for critical memory pressure. Free model workloads or choose a lighter profile, then Resume.", unload: true)
                }
            }
        }
        memoryPressureMonitor = monitor
        monitor.resume()
        let center = NSWorkspace.shared.notificationCenter
        observers = [center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pause(reason: "Paused for sleep. Resume when ready.", unload: true) }
        }]
        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.pause(reason: "Paused while locked. Resume when ready.", unload: true) }
            }
        installShortcut()
    }

    func deactivate() {
        enabled = false
        memoryPressureMonitor?.cancel(); memoryPressureMonitor = nil
        stop()
        shortcutMonitor?.stop(); shortcutMonitor = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        if let distributedObserver { DistributedNotificationCenter.default().removeObserver(distributedObserver) }
        distributedObserver = nil
        overlay?.hide(); overlay = nil
    }

    func shutdownForTermination() async {
        deactivate()
        await teardown?.value
    }

    func prepareModels() {
        guard enabled, state != .running, state != .preparing, !isPreparingModels, !modelStore.isPreparing, !isPreparingRecognition, !isPreparingSpeech else { return }
        errorMessage = nil
        operation?.cancel()
        let token = preparationOperations.invalidate()
        let values = settings.value
        isPreparingModels = true
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if self.preparationOperations.isCurrent(token) { self.isPreparingModels = false } }
            do {
                try self.preparationOperations.check(token)
                let manifest = try TranslationModelStore.bundledManifest()
                _ = try await self.modelStore.prepare(manifest: manifest, cache: self.cacheURL,
                                                     quantization: values.quantization, download: true)
                try self.preparationOperations.check(token)
                self.status = "Model verified. Press Start when ready."
            } catch is CancellationError { }
            catch { if self.preparationOperations.isCurrent(token) { self.errorMessage = self.describe(error) } }
        }
    }

    func prepareRecognition() {
        guard enabled, state != .running, state != .preparing, !isPreparingRecognition, !isPreparingModels, !isPreparingSpeech, !modelStore.isPreparing,
              let prepare = recognitionPreparationProvider else { return }
        operation?.cancel(); errorMessage = nil; isPreparingRecognition = true
        let token = preparationOperations.invalidate()
        let values = settings.value
        status = "Preparing the pinned Whisper tokenizer…"
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if self.preparationOperations.isCurrent(token) { self.isPreparingRecognition = false } }
            do {
                try await self.preparationOperations.perform(token: token) { try await prepare(values) }
                self.status = "Whisper tokenizer verified. Model weights are managed in Models."
            } catch is CancellationError { }
            catch { if self.preparationOperations.isCurrent(token) { self.errorMessage = self.describe(error) } }
        }
    }

    func prepareSpeech() {
        guard enabled, state != .running, state != .preparing, !isPreparingSpeech, !isPreparingRecognition,
              !isPreparingModels, !modelStore.isPreparing, let prepare = speechPreparationProvider else { return }
        operation?.cancel(); errorMessage = nil; isPreparingSpeech = true
        let token = preparationOperations.invalidate()
        let values = settings.value
        status = "Preparing the selected local speech assets…"
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if self.preparationOperations.isCurrent(token) { self.isPreparingSpeech = false } }
            do {
                let message = try await self.preparationOperations.perform(token: token) { try await prepare(values) }
                self.status = message
            } catch is CancellationError { }
            catch { if self.preparationOperations.isCurrent(token) { self.errorMessage = self.describe(error) } }
        }
    }

    func prepareStockVoice() {
        guard enabled, state != .running, state != .preparing, !isPreparingSpeech, !isPreparingRecognition,
              !isPreparingModels, !modelStore.isPreparing,
              settings.value.speechProvider == .chatterbox || settings.value.speechProvider == .localModel else { return }
        operation?.cancel(); errorMessage = nil; isPreparingSpeech = true
        let token = preparationOperations.invalidate()
        let values = settings.value
        let cache = cacheURL
        status = "Preparing the CC0 Thorsten reference…"
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if self.preparationOperations.isCurrent(token) { self.isPreparingSpeech = false } }
            do {
                let prepared = try await self.preparationOperations.perform(token: token) {
                    try await TranslationStockVoicePreparation.prepare(cache: cache)
                }
                var updated = self.settings.value
                if values.speechProvider == .chatterbox { updated.chatterboxReferencePath = prepared.referenceURL.path }
                else {
                    updated.speechReferencePath = prepared.referenceURL.path
                    updated.speechReferenceText = prepared.transcript
                }
                self.settings.value = updated
                self.status = "Thorsten reference prepared (German, CC0). Cross-language voice quality is unqualified."
            } catch is CancellationError { }
            catch { if self.preparationOperations.isCurrent(token) { self.errorMessage = self.describe(error) } }
        }
    }

    private func prepareOmniRuntime(values: LiveTranslationSettings.Value, id: UUID) async throws -> LFMRuntimeEndpoint {
        try check(id)
        let manifest = try TranslationModelStore.bundledManifest()
        let installation = try await modelStore.prepare(manifest: manifest, cache: cacheURL,
                                                         quantization: values.quantization, download: false)
        try check(id)
        status = "Loading LFM3-Omni…"
        let endpoint = try await runtime.start(executable: TranslationRuntimeController.bundledExecutable(),
            model: installation.modelURL, projector: installation.projectorURL, contextSize: 4096)
        try check(id)
        return endpoint
    }

    func start() {
        guard canStart else { return }
        refreshResourceAssessment()
        guard resourceAssessment.canAttemptLoad else {
            end(state: .paused, message: resourceAssessment.explanation, unload: true)
            return
        }
        operation?.cancel()
        interruptionTask?.cancel(); interruptionTask = nil
        resumeCaptureTask?.cancel(); resumeCaptureTask = nil
        commandOperations.invalidate(); preparationOperations.invalidate(); outputOperations.invalidate(); inputOperations.invalidate()
        eventTask?.cancel(); eventTask = nil
        let previousSession = session; session = nil
        canRetry = false; canReplay = false
        let id = UUID(); runID = id
        minimumOutputGeneration = nil; detectedDirection = nil
        state = .preparing; status = "Verifying model artifacts…"; errorMessage = nil
        interrupting = false; speakerPaused = false
        latestMetrics = [:]; capabilities = nil; sourceText = ""; translatedText = ""
        sourceAccumulator = .init(); targetAccumulator = .init(); currentTextTurn = nil
        updateOverlay()
        operation = Task { [weak self] in
            guard let self else { return }
            await self.teardown?.value
            await previousSession?.stop()
            do {
                try self.check(id)
                let values = self.settings.value
                let configuration = self.settings.configuration
                guard values.sourceLanguage != values.targetLanguage else {
                    throw TranslationFailure(code: .unsupportedLanguage, message: "Choose two different languages.")
                }
                guard values.source != .systemAudio || values.output == .captions || values.headphones else {
                    throw TranslationFailure(code: .unsupportedOutput, message: "System audio speech requires the explicit headphones option. Captions remain available.")
                }
                let backend: any TranslationBackend
                if values.provider == .localCascade {
                    // Start prepares only the chosen route. Omni is loaded lazily at the speech stage.
                    await self.runtime.stop()
                    guard let factory = self.cascadeBackendProvider else {
                        throw TranslationFailure(code: .invalidConfiguration, message: "The local cascade is not configured.")
                    }
                    let omni: @Sendable () async throws -> LFMRuntimeEndpoint = { [weak self] in
                        guard let self else { throw CancellationError() }
                        return try await self.prepareOmniRuntime(values: values, id: id)
                    }
                    let resources = ManagedTranslationCascadeResources(runtime: self.cascadeRuntime,
                        strategy: values.cascadeMemoryStrategy,
                        prepareSpeech: {
                            if values.output == .speechAndCaptions && values.speechProvider == .omni { _ = try await omni() }
                        }, stopSpeech: { [runtime = self.runtime] in await runtime.stop() })
                    backend = try await factory(values, .init(runtime: self.cascadeRuntime, resources: resources, omniEndpoint: omni))
                } else {
                    await self.cascadeRuntime.stop()
                    let endpoint = try await self.prepareOmniRuntime(values: values, id: id)
                    backend = LFM3RealtimeBackend(endpoint: endpoint, mode: values.provider == .lfm3OmniTwoPass ? .twoPass : .direct)
                }
                // The cascade factory can suspend while Stop/Disable changes the app owner.
                guard self.runID == id, self.enabled, !Task.isCancelled else {
                    await backend.stop()
                    throw CancellationError()
                }
                let session = TranslationSession(backend: backend)
                self.session = session
                self.inputSequence = 0
                let capabilities = try await session.prepare(configuration: configuration)
                try self.check(id)
                self.capabilities = capabilities
                self.segmenter = TranslationSpeechSegmenter(detector: try WebRTCTranslationVoiceActivityDetector())
                let events = try await session.start()
                try self.check(id)
                try await self.startPlaybackIfRequested(session: session, id: id)
                try self.check(id)
                self.state = .running
                self.eventTask = Task { [weak self] in
                    do {
                        for try await event in events {
                            guard let self, self.runID == id, !Task.isCancelled else { break }
                            try await self.receive(event, session: session, id: id)
                        }
                    } catch is CancellationError { }
                    catch { self?.fail(error, id: id) }
                }
                try await self.startCapture(id: id)
                try self.check(id)
                self.status = "Listening · experimental"
                self.updateOverlay()
            } catch is CancellationError { }
            catch { self.fail(error, id: id) }
        }
    }

    func pause(reason: String = "Paused. Resume when ready.", unload: Bool = false) {
        guard state == .running || state == .preparing || state == .paused || isPreparingModels || modelStore.isPreparing || isPreparingRecognition || isPreparingSpeech else { return }
        end(state: .paused, message: reason, unload: unload)
    }
    func stop() { end(state: .stopped, message: "Stopped", unload: true) }
    func toggle() { state == .running || state == .preparing ? pause() : start() }
    func setShortcutCaptureActive(_ active: Bool) {
        capturingShortcut = active
        installShortcut()
    }

    private func end(state next: TranslationSessionState, message: String, unload: Bool) {
        runID = UUID(); inputEpoch = UUID(); interrupting = true
        outputOperations.invalidate(); commandOperations.invalidate(); preparationOperations.invalidate(); inputOperations.invalidate()
        operation?.cancel(); operation = nil
        interruptionTask?.cancel(); interruptionTask = nil
        eventTask?.cancel(); eventTask = nil
        resumeCaptureTask?.cancel(); resumeCaptureTask = nil
        modelStore.cancel()
        isPreparingRecognition = false; isPreparingModels = false; isPreparingSpeech = false
        playback.stop() // Silence is synchronous, before any awaited teardown.
        isListening = false; isSpeaking = false; isGenerating = false
        canRetry = false; canReplay = false
        state = next; status = message
        let old = session; session = nil; segmenter = nil
        let previous = teardown
        teardown = Task { [capture, systemCapture, runtime, cascadeRuntime] in
            await previous?.value
            await capture.stopAndWait()
            await systemCapture.stopAndWait()
            await old?.stop()
            if unload { await runtime.stop(); await cascadeRuntime.stop() }
        }
        updateOverlay()
    }

    func interruptSpeech() {
        guard state == .running, let session else { return }
        interrupting = true; inputEpoch = UUID(); outputOperations.invalidate(); inputOperations.invalidate()
        let token = commandOperations.invalidate()
        interruptionTask?.cancel()
        resumeCaptureTask?.cancel(); resumeCaptureTask = nil
        playback.stop(); sourceText = ""; translatedText = ""
        sourceAccumulator = .init(); targetAccumulator = .init(); currentTextTurn = nil
        let id = runID
        interruptionTask = Task {
            do {
                try await commandOperations.perform(token: token) { await capture.stopAndWait() }
                try await commandOperations.perform(token: token) { await systemCapture.stopAndWait() }
                try await commandOperations.perform(token: token) { await segmenter?.reset() }
                try await commandOperations.perform(token: token) { await session.interrupt() }
                try check(id)
                guard state == .running else { return }
                try await commandOperations.perform(token: token) { try await startPlaybackIfRequested(session: session, id: id) }
                interrupting = false; speakerPaused = false
                try await commandOperations.perform(token: token) { try await startCapture(id: id) }
                status = "Interrupted. Listening for the next turn."
            } catch is CancellationError { }
            catch { if commandOperations.isCurrent(token) { fail(error, id: id) } }
        }
    }

    func toggleMute() {
        let token = outputOperations.invalidate()
        isMuted.toggle()
        if isMuted { playback.stop() }
        else if state == .running, spokenOutputRequested, let session {
            let id = runID
            Task {
                do {
                    try await startPlaybackIfRequested(session: session, id: id, outputToken: token)
                } catch is CancellationError { }
                catch { fail(error, id: id) }
            }
        }
    }

    func retryLastTurn() {
        guard canRetry, let session, state == .paused || state == .running else { return }
        let token = commandOperations.invalidate()
        interruptionTask?.cancel(); interruptionTask = nil
        resumeCaptureTask?.cancel(); resumeCaptureTask = nil
        inputEpoch = UUID(); inputOperations.invalidate()
        canRetry = false; errorMessage = nil; interrupting = false
        let id = runID
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.commandOperations.perform(token: token) { await self.capture.stopAndWait() }
                try await self.commandOperations.perform(token: token) { await self.systemCapture.stopAndWait() }
                try await self.commandOperations.perform(token: token) { await self.segmenter?.reset() }
                try self.check(id)
                try await self.commandOperations.perform(token: token) { try await self.startPlaybackIfRequested(session: session, id: id) }
                self.state = .running; self.isGenerating = true
                self.status = "Retrying the retained turn…"
                try await self.commandOperations.perform(token: token) { try await session.retryLastTurn() }
                try self.check(id)
                if self.settings.value.source == .microphone && !self.settings.value.headphones && self.spokenOutputRequested && !self.isMuted {
                    self.beginSpeakerPause()
                } else {
                    self.speakerPaused = false
                    try await self.commandOperations.perform(token: token) { try await self.startCapture(id: id) }
                }
            } catch is CancellationError { }
            catch { if self.commandOperations.isCurrent(token) { self.fail(error, id: id) } }
        }
    }

    func replayLastTurn(swappingDirection: Bool = false) {
        guard canReplay, let session, state == .running || state == .paused, !isGenerating else { return }
        let token = commandOperations.invalidate()
        interruptionTask?.cancel(); interruptionTask = nil
        resumeCaptureTask?.cancel(); resumeCaptureTask = nil
        inputEpoch = UUID(); inputOperations.invalidate(); outputOperations.invalidate()
        playback.stop(); interrupting = true; canReplay = false; canRetry = false
        errorMessage = nil; isListening = false
        var corrected = settings.value
        if let detectedDirection {
            corrected.sourceLanguage = detectedDirection.source; corrected.targetLanguage = detectedDirection.target
        }
        if swappingDirection {
            (corrected.sourceLanguage, corrected.targetLanguage) = (corrected.targetLanguage, corrected.sourceLanguage)
        }
        corrected.directionMode = .fixed
        // This explicit command owns the reset, avoiding the generic preference observer's stop.
        observedSettings = corrected
        settings.value = corrected
        let pair = TranslationLanguagePair(source: corrected.sourceLanguage, target: corrected.targetLanguage)
        let id = runID
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.commandOperations.perform(token: token) { await self.capture.stopAndWait() }
                try await self.commandOperations.perform(token: token) { await self.systemCapture.stopAndWait() }
                try await self.commandOperations.perform(token: token) { await self.segmenter?.reset() }
                try self.check(id)
                let previous = await session.snapshot()
                try self.commandOperations.check(token)
                self.minimumOutputGeneration = .init(previous.generation.rawValue &+ 1)
                self.detectedDirection = nil
                self.sourceText = ""; self.translatedText = ""; self.currentTextTurn = nil
                self.sourceAccumulator = .init(); self.targetAccumulator = .init()
                try await self.commandOperations.perform(token: token) { try await self.startPlaybackIfRequested(session: session, id: id) }
                self.interrupting = false; self.state = .running; self.isGenerating = true
                self.status = "Retranslating the retained recording in a fresh context…"
                _ = try await self.commandOperations.perform(token: token) { try await session.replayLastTurn(languagePair: pair) }
                try self.check(id)
                if self.settings.value.source == .microphone && !self.settings.value.headphones && self.spokenOutputRequested && !self.isMuted {
                    self.speakerPaused = false; self.beginSpeakerPause()
                } else {
                    self.speakerPaused = false
                    try await self.commandOperations.perform(token: token) { try await self.startCapture(id: id) }
                }
            } catch is CancellationError { }
            catch { if self.commandOperations.isCurrent(token) { self.fail(error, id: id) } }
        }
    }

    var currentTurnIsComplete: Bool { currentTextTurn.map { id in turns.contains { $0.turnID == id } } ?? false }
    func clearTranscript() {
        turns.removeAll(); discardedTranscriptTurnCount = 0
        sourceText = ""; translatedText = ""; incompleteIntervals = []
    }
    var completedText: String { turns.map { [$0.sourceText, $0.translatedText].compactMap { $0 }.joined(separator: "\n") }.joined(separator: "\n\n") }
    func copyCompletedText() {
        guard !completedText.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(completedText, forType: .string)
    }
    func exportCompletedText() {
        guard !completedText.isEmpty else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = "Translation.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try completedText.write(to: url, atomically: true, encoding: .utf8) }
        catch { errorMessage = "Could not export the completed transcript: \(error.localizedDescription)" }
    }

    private var cacheURL: URL {
        URL(fileURLWithPath: configurationProvider?()?.modelSearchPath ?? NativSettings.defaultModelSearchPath, isDirectory: true)
    }
    func refreshResourceAssessment() {
        var weightBytes: UInt64?
        // A partial cascade total would misrepresent the combined footprint. Its resident peak still needs measurement.
        if settings.value.provider != .localCascade, let manifest = try? TranslationModelStore.bundledManifest(),
           let model = manifest.model.artifacts[settings.value.quantization], let projector = manifest.model.artifacts["projector"] {
            weightBytes = UInt64(model.size) + UInt64(projector.size)
        }
        resourceAssessment = .init(hardware: .current(), selectedWeightBytes: weightBytes)
    }
    private func check(_ id: UUID) throws { guard runID == id, enabled, !Task.isCancelled else { throw CancellationError() } }
    private func describe(_ error: Error) -> String { (error as? TranslationFailure)?.message ?? error.localizedDescription }
    private func fail(_ error: Error, id: UUID) {
        guard runID == id else { return }
        let message = describe(error)
        end(state: .failed, message: "Translation stopped. Resolve the error and start again.", unload: true)
        errorMessage = message
    }
    private func startPlaybackIfRequested(session: TranslationSession, id: UUID,
                                          outputToken: TranslationHostOperationGate.Token? = nil) async throws {
        let token = outputToken ?? outputOperations.current
        guard spokenOutputRequested, !isMuted else { return }
        do {
            let snapshot = try await outputOperations.perform(token: token) { await session.snapshot() }
            try check(id)
            guard spokenOutputRequested, !isMuted else { return }
            try await outputOperations.perform(token: token) {
                try await playback.start(outputDeviceID: settings.value.outputDeviceID == 0 ? nil : settings.value.outputDeviceID,
                                         sessionID: snapshot.sessionID)
            }
        } catch is CancellationError {
            // A newer mute owns playback; the session may continue producing captions.
            if outputOperations.isCurrent(token) { throw CancellationError() }
        }
    }
    private func startCapture(id: UUID) async throws {
        let token = inputOperations.invalidate()
        try await inputOperations.perform(token: token) { await speakerCaptureTeardown?.value }
        try check(id)
        guard state == .running, !interrupting, !speakerPaused else { throw CancellationError() }
        guard let session, let format = capabilities?.inputFormat else {
            throw TranslationFailure(code: .invalidAudio, message: "The provider did not negotiate an input audio format.")
        }
        let snapshot = try await inputOperations.perform(token: token) { await session.snapshot() }
        try check(id)
        let inputEpoch = UUID(); self.inputEpoch = inputEpoch
        let onPCM: @Sendable (OwnedPCMFrame) async throws -> Void = { [weak self] frame in
            try await self?.consume(frame, id: id, inputEpoch: inputEpoch)
        }
        let onFailure: @MainActor @Sendable (Error) -> Void = { [weak self] error in self?.fail(error, id: id) }
        if settings.value.source == .microphone {
            try await capture.start(deviceUniqueID: settings.value.inputDeviceID.isEmpty ? nil : settings.value.inputDeviceID,
                                    format: format, sessionID: snapshot.sessionID, generation: snapshot.generation,
                                    onPCM: onPCM, onFailure: onFailure)
        } else {
            try await systemCapture.start(format: format, sessionID: snapshot.sessionID, generation: snapshot.generation,
                                          onPCM: onPCM, onFailure: onFailure)
        }
        try inputOperations.check(token)
        try check(id); isListening = true
    }
    private func consume(_ frame: OwnedPCMFrame, id: UUID, inputEpoch: UUID) async throws {
        guard runID == id, self.inputEpoch == inputEpoch, state == .running, !interrupting, !speakerPaused, let session, let segmenter else { return }
        let events = try await segmenter.consume(frame)
        do {
            for event in events {
                guard runID == id, self.inputEpoch == inputEpoch, state == .running, !interrupting, !speakerPaused else { return }
                switch event {
                case .audio(let audio):
                    let snapshot = await session.snapshot()
                    guard snapshot.state == .running, runID == id, self.inputEpoch == inputEpoch,
                          state == .running, !interrupting, !speakerPaused else { return }
                    let sequence = inputSequence; inputSequence &+= 1
                    try await session.accept(frame: .init(bytes: audio.bytes, format: audio.format,
                        captureTimestampNanoseconds: audio.captureTimestampNanoseconds, sequence: sequence,
                        sourceID: audio.sourceID, sessionID: snapshot.sessionID, turnID: audio.turnID, generation: snapshot.generation))
                case .commit(let turnID, _):
                    try await session.commit(turnID: turnID)
                    if runID == id, spokenOutputRequested, !isMuted,
                       settings.value.source == .microphone, !settings.value.headphones {
                        beginSpeakerPause()
                    }
                }
            }
        } catch {
            let snapshot = await session.snapshot()
            if snapshot.state == .paused, snapshot.lastFailure != nil {
                // The core event stream owns the recovery UI and retained retry segment.
                return
            }
            throw error
        }
    }

    private func acceptsOutput(generation: TranslationGeneration) -> Bool {
        minimumOutputGeneration.map { generation.rawValue >= $0.rawValue } ?? true
    }

    private func receive(_ event: TranslationEvent, session: TranslationSession, id: UUID) async throws {
        defer { event.acknowledgeAudioDelivery() }
        let outputToken = outputOperations.current
        let snapshot = await session.snapshot()
        guard runID == id, !interrupting, acceptsOutput(generation: event.generation), event.sessionID == snapshot.sessionID, event.generation == snapshot.generation else { return }
        incompleteIntervals = snapshot.incompleteIntervals
        canRetry = snapshot.canRetry
        canReplay = snapshot.canReplay
        if let turnID = event.turnID, currentTextTurn != turnID {
            currentTextTurn = turnID; sourceAccumulator = .init(); targetAccumulator = .init(); detectedDirection = nil
            sourceText = ""; translatedText = ""
        }
        switch event.payload {
        case .sourceText(let text):
            _ = try sourceAccumulator.apply(text); sourceText = sourceAccumulator.text
        case .translationText(let text):
            _ = try targetAccumulator.apply(text); translatedText = targetAccumulator.text
        case .audio(let chunk):
            guard !isMuted, spokenOutputRequested, chunk.committed else { return }
            do {
                try outputOperations.check(outputToken)
                if settings.value.source == .microphone && !settings.value.headphones {
                    beginSpeakerPause()
                    try await outputOperations.perform(token: outputToken) { await speakerCaptureTeardown?.value }
                }
                try check(id)
                let current = try await outputOperations.perform(token: outputToken) { await session.snapshot() }
                guard !isMuted, !interrupting, acceptsOutput(generation: event.generation), current.state == .running,
                      event.generation == current.generation else { return }
                try await outputOperations.perform(token: outputToken) { try await playback.enqueue(chunk) }
            } catch is CancellationError {
                // Muting or interrupting may cancel an in-flight conversion. Keep consuming captions.
                guard !outputOperations.isCurrent(outputToken) || runID != id || Task.isCancelled else { throw CancellationError() }
            }
        case .turnCompleted:
            // Keep only completed text in memory. Provider source text stays absent when unavailable.
            if let turnID = event.turnID, let turn = snapshot.transcript.turns.first(where: { $0.turnID == turnID }),
               !turns.contains(where: { $0.turnID == turnID }) {
                turns.append(turn)
                if turns.count > 200 {
                    let discarded = turns.count - 200
                    turns.removeFirst(discarded)
                    discardedTranscriptTurnCount += discarded
                }
            }
            isGenerating = snapshot.activity.generating
            scheduleSpeakerResume()
        case .state:
            isGenerating = snapshot.activity.generating
            if snapshot.state == .paused {
                state = .paused; isListening = false; inputEpoch = UUID(); inputOperations.invalidate()
                resumeCaptureTask?.cancel(); resumeCaptureTask = nil
                status = "Input paused. Retry the retained turn or resume a fresh session."
                await capture.stopAndWait(); await systemCapture.stopAndWait()
            } else if snapshot.state == .running {
                state = .running
                if !speakerPaused { status = isGenerating ? "Translating · experimental" : "Listening · experimental" }
            }
        case .metrics(let metric): latestMetrics[metric.name] = metric.value
        case .failure(let failure):
            if failure.recoverable {
                state = .paused; inputEpoch = UUID(); outputOperations.invalidate(); inputOperations.invalidate()
                resumeCaptureTask?.cancel(); resumeCaptureTask = nil
                isListening = false; isGenerating = false
                playback.stop()
                errorMessage = failure.message
                status = "Incomplete input. Retry within 30 seconds or repeat after Resume."
                await capture.stopAndWait(); await systemCapture.stopAndWait()
            } else { throw failure }
        case .directionSelected(let selection): detectedDirection = selection.pair
        case .contextRolledOver: break
        }
    }
    private func beginSpeakerPause() {
        resumeCaptureTask?.cancel(); resumeCaptureTask = nil
        guard !speakerPaused else { return }
        speakerPaused = true; isListening = false; inputEpoch = UUID(); inputOperations.invalidate()
        status = "Translating / speaking · microphone paused (speaker mode)"
        let segmenter = segmenter
        // Do not await from the capture consumer itself; teardown drains that consumer.
        speakerCaptureTeardown = Task { [capture] in
            await capture.stopAndWait()
            await segmenter?.reset()
        }
    }
    private func scheduleSpeakerResume() {
        guard speakerPaused, !isSpeaking, !isGenerating, !interrupting, state == .running else { return }
        resumeCaptureTask?.cancel()
        let id = runID
        resumeCaptureTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
                guard let self, self.runID == id, self.state == .running, self.speakerPaused,
                      !self.interrupting, !self.isSpeaking, !self.isGenerating else { return }
                self.speakerPaused = false
                try await self.startCapture(id: id)
                self.status = "Listening · experimental"
            } catch is CancellationError { }
            catch { self?.fail(error, id: id) }
        }
    }
    private func installShortcut() {
        shortcutMonitor?.stop(); shortcutMonitor = nil
        guard enabled, !capturingShortcut else { return }
        do {
            let monitor = TranslationShortcutMonitor()
            try monitor.start(shortcut: settings.value.shortcut) { [weak self] in self?.toggle() }
            shortcutMonitor = monitor; shortcutMessage = nil
        } catch { shortcutMessage = error.localizedDescription }
    }
    private func updateOverlay() {
        guard enabled, settings.value.overlay, [.preparing, .running, .paused, .failed].contains(state) else { overlay?.hide(); return }
        if overlay == nil { overlay = LiveTranslationOverlay(coordinator: self) }
        overlay?.show()
    }
}
