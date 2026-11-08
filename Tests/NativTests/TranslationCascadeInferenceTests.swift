import Darwin
import Foundation
import XCTest
#if canImport(TranslationHost)
@testable import TranslationHost
#endif
import NativTranslationKit

/// Real host adapters and owned processes. Opt-in synthetic technical proof only;
/// a skipped test is not a passing inference or a human voice qualification.
@MainActor
final class TranslationCascadeInferenceTests: XCTestCase {
    func testExplicitOwnedHostCascadeSyntheticInference() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["NATIV_CASCADE_HOST_INFERENCE"] == "1",
              let manifestPath = environment["NATIV_CASCADE_HOST_MANIFEST"], manifestPath.hasPrefix("/") else {
            throw XCTSkip("Real host cascade inference is opt-in. Supply NATIV_CASCADE_HOST_INFERENCE=1 and an absolute NATIV_CASCADE_HOST_MANIFEST; no inference was measured.")
        }
        let manifest = try JSONDecoder().decode(HostInferenceManifest.self, from: Data(contentsOf: URL(fileURLWithPath: manifestPath)))
        try manifest.validate()
        guard TranslationHardwareSnapshot.current().pressure == .normal else {
            throw TranslationFailure(code: .providerFailure, message: "Host inference requires normal memory pressure before loading selected models.")
        }
        let models = try await LocalModelDiscovery.scan(searchPaths: .init(primary: manifest.modelSearchPath))
        for pin in [manifest.recognition, manifest.translation] {
            let selected = try XCTUnwrap(models.first { $0.repoID == pin.modelID })
            let snapshot = try XCTUnwrap(selected.snapshotURL)
            XCTAssertEqual(snapshot.lastPathComponent, pin.revision)
            guard snapshot.lastPathComponent == pin.revision else { throw TranslationModelStoreError.integrityFailure }
            for artifact in pin.artifacts {
                let verified = try TranslationModelStore.verify(file: snapshot.appendingPathComponent(artifact.filename).resolvingSymlinksInPath(), artifact: artifact)
                XCTAssertTrue(verified)
                guard verified else {
                    throw TranslationModelStoreError.integrityFailure
                }
            }
        }
        for artifact in [manifest.omni.model, manifest.omni.projector] {
            guard try TranslationModelStore.verify(file: URL(fileURLWithPath: manifest.omni.directory).appendingPathComponent(artifact.filename).resolvingSymlinksInPath(), artifact: artifact) else {
                throw TranslationModelStoreError.integrityFailure
            }
        }

        let runtime = TranslationCascadeRuntime(executable: URL(fileURLWithPath: manifest.mlxExecutable), readinessTimeout: 60)
        let omni = TranslationRuntimeController(readinessTimeout: 60)
        let omniFiles = manifest.omni
        let startOmni: @Sendable () async throws -> LFMRuntimeEndpoint = {
            try await omni.start(executable: URL(fileURLWithPath: omniFiles.executable),
                model: URL(fileURLWithPath: omniFiles.directory).appendingPathComponent(omniFiles.model.filename),
                projector: URL(fileURLWithPath: omniFiles.directory).appendingPathComponent(omniFiles.projector.filename))
        }
        let managed = ManagedTranslationCascadeResources(runtime: runtime, strategy: manifest.strategy,
            prepareSpeech: { _ = try await startOmni() }, stopSpeech: { await omni.stop() })
        let resources = HostInferenceResources(managed: managed)
        let monitor = HostInferenceMonitor(runtime: runtime, omni: omni)
        try await monitor.start()
        var activeBackend: CascadedTranslationBackend?
        do {
            let configuration = VoiceTranscriptionConfiguration(modelSearchPath: manifest.modelSearchPath,
                additionalModelSearchPaths: [], selectedModelID: nil, languageModelID: nil, maxTokens: 512,
                serverBaseURL: URL(string: "http://127.0.0.1:1")!, serverAPIKey: nil, serverIsRunning: false)
            for fixture in manifest.fixtures {
                if let failure = await monitor.failure { throw failure }
                var settings = LiveTranslationSettings.Value()
                settings.provider = .localCascade; settings.output = .speechAndCaptions
                settings.sourceLanguage = fixture.source; settings.targetLanguage = fixture.target
                settings.recognitionModel = manifest.recognition.modelID
                settings.translationModel = manifest.translation.modelID
                settings.speechProvider = .omni; settings.experimentalAccepted = true
                settings.cascadeMemoryStrategy = manifest.strategy
                let backend = try await TranslationCascadeProviders.make(settings: settings, configuration: configuration,
                    runtime: runtime, resources: resources, omniEndpoint: startOmni)
                activeBackend = backend
                await monitor.observe(backend)
                if let failure = await monitor.failure { throw failure }
                let caps = try await backend.prepare(configuration: .init(languagePair: .init(source: fixture.source, target: fixture.target),
                    outputMode: .speechAndCaptions, provider: .localCascade))
                XCTAssertTrue(caps.sourceTranscriptAvailable)
                XCTAssertTrue(caps.qualifiedTranslationPairs.isEmpty)
                let pcm = try fixture.load()
                XCTAssertEqual(pcm.format, caps.inputFormat)
                let sessionID = TranslationSessionID(); let turnID = TranslationTurnID(); let generation = TranslationGeneration()
                let stream = try await backend.start(sessionID: sessionID, generation: generation)
                for offset in stride(from: 0, to: pcm.bytes.count, by: 640) {
                    try await backend.send(frame: .init(bytes: Data(pcm.bytes[offset..<min(offset + 640, pcm.bytes.count)]), format: pcm.format,
                        captureTimestampNanoseconds: UInt64(offset / 2) * 62_500, sequence: UInt64(offset / 640),
                        sourceID: "opt-in-synthetic-fixture", sessionID: sessionID, turnID: turnID, generation: generation))
                }
                let start = ContinuousClock.now
                try await backend.commit(turnID: turnID)
                var source = "", target = "", audioBytes = 0, completed = false
                var firstAudio: Duration?
                var phases: [String] = []
                for try await event in stream {
                    defer { event.acknowledgeAudioDelivery() }
                    switch event.payload {
                    case .sourceText(let text): source = text.text; if text.stability == .final { phases.append("source") }
                    case .translationText(let text): target = text.text; if text.stability == .final { phases.append("target") }
                    case .audio(let chunk):
                        XCTAssertTrue(chunk.committed)
                        if firstAudio == nil { firstAudio = start.duration(to: .now); phases.append("audio") }
                        audioBytes += chunk.bytes.count
                    case .turnCompleted: completed = true; phases.append("complete")
                    case .failure(let failure): throw failure
                    default: break
                    }
                    if completed { break }
                }
                if let failure = await monitor.failure { throw failure }
                if let failure = await resources.failure { throw failure }
                XCTAssertFalse(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                XCTAssertFalse(target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                XCTAssertGreaterThan(audioBytes, 0)
                XCTAssertTrue(completed)
                XCTAssertEqual(phases, ["source", "target", "audio", "complete"])
                print("Host cascade synthetic technical result pair=\(fixture.source)-\(fixture.target) ASR=\(manifest.recognition.modelID)@\(manifest.recognition.revision) LLM=\(manifest.translation.modelID)@\(manifest.translation.revision) speech=LFM3-Omni strategy=\(manifest.strategy.rawValue) receivedPCMBytes=\(audioBytes) commitToFirstReceivedPCM=\(String(describing: firstAudio)); not microphone/acoustic latency, meaning or voice qualification")
                await backend.stop(); activeBackend = nil
            }
            await monitor.stop(); await runtime.stop(); await omni.stop()
        } catch {
            await activeBackend?.stop()
            await monitor.stop(); await runtime.stop(); await omni.stop()
            throw error
        }
        let mlxRunning = await runtime.isRunning, omniRunning = await omni.isRunning
        XCTAssertFalse(mlxRunning); XCTAssertFalse(omniRunning)
    }
}

private struct HostInferenceManifest: Decodable, Sendable {
    struct Model: Decodable, Sendable { let modelID: String; let revision: String; let artifacts: [TranslationModelArtifact] }
    struct Omni: Decodable, Sendable { let executable: String; let directory: String; let model: TranslationModelArtifact; let projector: TranslationModelArtifact }
    struct Fixture: Decodable, Sendable {
        let source: String; let target: String; let directory: String; let artifact: TranslationModelArtifact; let synthetic: Bool
        func load() throws -> (bytes: Data, format: TranslationPCMFormat) {
            guard synthetic, artifact.size <= 2_000_000 else { throw TranslationModelStoreError.invalidManifest }
            let url = URL(fileURLWithPath: directory).appendingPathComponent(artifact.filename).resolvingSymlinksInPath()
            guard try TranslationModelStore.verify(file: url, artifact: artifact) else { throw TranslationModelStoreError.integrityFailure }
            let wave = try TranslationWaveCodec.decode(Data(contentsOf: url))
            guard wave.format == CascadedTranslationBackend.inputFormat, !wave.bytes.isEmpty,
                  try wave.format.duration(byteCount: wave.bytes.count) <= 12 else { throw TranslationModelStoreError.invalidManifest }
            return (wave.bytes, wave.format)
        }
    }
    let modelSearchPath: String
    let mlxExecutable: String
    let strategy: TranslationCascadeMemoryStrategy
    let recognition: Model
    let translation: Model
    let omni: Omni
    let fixtures: [Fixture]
    func validate() throws {
        guard [modelSearchPath, mlxExecutable, omni.executable, omni.directory].allSatisfy({ $0.hasPrefix("/") }),
              fixtures.count == 2, Set(fixtures.map { $0.source + "-" + $0.target }) == ["nl-en", "en-nl"],
              fixtures.allSatisfy({ $0.directory.hasPrefix("/") && $0.synthetic }) else { throw TranslationModelStoreError.invalidManifest }
        for pin in [recognition, translation] {
            guard pin.revision.count == 40, pin.revision.allSatisfy(\.isHexDigit),
                  !pin.artifacts.isEmpty, pin.artifacts.contains(where: { $0.filename.hasSuffix(".safetensors") }) else { throw TranslationModelStoreError.invalidManifest }
            for artifact in pin.artifacts { try artifact.validate() }
        }
        try omni.model.validate(); try omni.projector.validate()
    }
}

/// A real stage that exceeds one minute loses its owned runtime; no runaway
/// request is left waiting until the longer HTTP watchdog expires.
private actor HostInferenceResources: TranslationCascadeResources {
    let managed: ManagedTranslationCascadeResources
    private var deadline: Task<Void, Never>?
    private var deadlineID = UUID()
    private(set) var failure: TranslationFailure?
    init(managed: ManagedTranslationCascadeResources) { self.managed = managed }
    func begin(generation: UUID) async throws { failure = nil; try await managed.begin(generation: generation) }
    func acquire(_ stage: TranslationCascadeStage, generation: UUID) async throws -> TranslationCascadeLease {
        deadline?.cancel()
        let id = UUID(); deadlineID = id
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)); await self?.expired(stage: stage, generation: generation, id: id) } catch {}
        }
        do { return try await managed.acquire(stage, generation: generation) }
        catch { deadline?.cancel(); throw error }
    }
    func release(_ lease: TranslationCascadeLease) async { deadlineID = UUID(); deadline?.cancel(); deadline = nil; await managed.release(lease) }
    func invalidate(generation: UUID) async { deadlineID = UUID(); deadline?.cancel(); deadline = nil; await managed.invalidate(generation: generation) }
    private func expired(stage: TranslationCascadeStage, generation: UUID, id: UUID) async {
        guard deadlineID == id else { return }
        failure = .init(code: .providerFailure, message: "Real host cascade exceeded the 60-second \(stage.rawValue) stage limit.")
        await managed.invalidate(generation: generation)
    }
    deinit { deadline?.cancel() }
}

/// The surrounding machine influences swap. A guard trip is reported as a
/// stopped experiment, never as a measured model-only memory requirement.
private actor HostInferenceMonitor {
    let runtime: TranslationCascadeRuntime
    let omni: TranslationRuntimeController
    private var backend: (any TranslationBackend)?
    private var task: Task<Void, Never>?
    private(set) var failure: TranslationFailure?
    init(runtime: TranslationCascadeRuntime, omni: TranslationRuntimeController) { self.runtime = runtime; self.omni = omni }
    func observe(_ backend: any TranslationBackend) async { self.backend = backend; if failure != nil { await backend.stop() } }
    func start() throws {
        guard let initialSwap = Self.swapBytes(), TranslationHardwareSnapshot.current().pressure == .normal else {
            throw TranslationFailure(code: .providerFailure, message: "The inference harness cannot establish a normal memory-pressure and swap baseline; no models were loaded.")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(420))
        task = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(500))
                    guard let currentSwap = Self.swapBytes() else { await self?.abort(); return }
                    let pressure = TranslationHardwareSnapshot.current().pressure
                    let exceededSwap = currentSwap > initialSwap && currentSwap - initialSwap > 1_073_741_824
                    if pressure == .critical || pressure == .unknown || exceededSwap || ContinuousClock.now >= deadline {
                        await self?.abort(); return
                    }
                }
            } catch {}
        }
    }
    func stop() { task?.cancel(); task = nil; backend = nil }
    private func abort() async {
        failure = .init(code: .providerFailure, message: "Host inference stopped for unavailable memory telemetry, critical system pressure, more than 1 GiB global swap growth, or the 420-second experiment limit. This is not a model-only fit measurement.")
        await backend?.stop(); await runtime.stop(); await omni.stop()
    }
    private static func swapBytes() -> UInt64? {
        var value = xsw_usage(); var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &value, &size, nil, 0) == 0 else { return nil }
        return value.xsu_used
    }
    deinit { task?.cancel() }
}
