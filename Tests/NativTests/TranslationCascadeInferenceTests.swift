import CryptoKit
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
    func testSyntheticAudioEvidenceRejectsNonFiniteAndSilentPCM() throws {
        let format = TranslationPCMFormat(sampleRate: 16_000, channels: 1, encoding: .float32LittleEndian)
        func bytes(_ values: [Float]) -> Data {
            var result = Data()
            for value in values {
                var bits = value.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { result.append(contentsOf: $0) }
            }
            return result
        }
        let signal = try HostInferenceAudioReport.analyze(bytes([-0.5, 0.5]), format: format)
        XCTAssertEqual(signal.sampleCount, 2)
        XCTAssertEqual(signal.peakAbsoluteAmplitude, 0.5)
        XCTAssertEqual(signal.rmsAmplitude, 0.5)
        XCTAssertThrowsError(try HostInferenceAudioReport.analyze(bytes([0, 0]), format: format))
        XCTAssertThrowsError(try HostInferenceAudioReport.analyze(bytes([.nan, 0.5]), format: format))
    }

    func testExplicitOwnedHostCascadeSyntheticInference() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["NATIV_CASCADE_HOST_INFERENCE"] == "1",
              let manifestPath = environment["NATIV_CASCADE_HOST_MANIFEST"], manifestPath.hasPrefix("/") else {
            throw XCTSkip("Real host cascade inference is opt-in. Supply NATIV_CASCADE_HOST_INFERENCE=1 and an absolute NATIV_CASCADE_HOST_MANIFEST; no inference was measured.")
        }
        let manifest = try JSONDecoder().decode(HostInferenceManifest.self, from: Data(contentsOf: URL(fileURLWithPath: manifestPath)))
        try manifest.validate()
        let reportDirectory = try HostInferenceReport.prepareDirectory(environment["NATIV_CASCADE_HOST_REPORT_DIRECTORY"])
        var report = HostInferenceReport(manifest: manifest)
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
                let turnStart = ContinuousClock.now
                let mlxWasRunning = await runtime.isRunning, omniWasRunning = await omni.isRunning
                XCTAssertFalse(mlxWasRunning); XCTAssertFalse(omniWasRunning)
                report.turns.append(.init(pair: fixture.source + "-" + fixture.target,
                    mlxWasRunningBeforeTurn: mlxWasRunning, omniWasRunningBeforeTurn: omniWasRunning))
                let reportIndex = report.turns.count - 1
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
                report.turns[reportIndex].seconds["factory_prepare_and_input"] = HostInferenceReport.seconds(turnStart.duration(to: .now))
                let start = ContinuousClock.now
                try await backend.commit(turnID: turnID)
                var source = "", target = "", audioBytes = 0, completed = false
                var firstAudio: Duration?
                var receivedAudio = Data()
                var receivedFormat: TranslationPCMFormat?
                var phases: [String] = []
                for try await event in stream {
                    defer { event.acknowledgeAudioDelivery() }
                    switch event.payload {
                    case .sourceText(let text):
                        source = text.text; report.turns[reportIndex].sourceText = text.text
                        if text.stability == .final { phases.append("source"); report.turns[reportIndex].seconds["commit_to_final_source"] = HostInferenceReport.seconds(start.duration(to: .now)) }
                    case .translationText(let text):
                        target = text.text; report.turns[reportIndex].targetText = text.text
                        if text.stability == .final { phases.append("target"); report.turns[reportIndex].seconds["commit_to_final_target"] = HostInferenceReport.seconds(start.duration(to: .now)) }
                    case .audio(let chunk):
                        XCTAssertTrue(chunk.committed)
                        if firstAudio == nil {
                            firstAudio = start.duration(to: .now); phases.append("audio")
                            report.turns[reportIndex].seconds["commit_to_first_received_pcm"] = HostInferenceReport.seconds(firstAudio!)
                        }
                        if let receivedFormat, receivedFormat != chunk.format {
                            throw TranslationFailure(code: .invalidAudio, message: "Synthetic report cannot concatenate changing PCM formats.")
                        }
                        guard receivedAudio.count + chunk.bytes.count <= 16_000_000 else {
                            throw TranslationFailure(code: .invalidAudio, message: "Synthetic report audio exceeded its 16 MB bound.")
                        }
                        receivedFormat = chunk.format; receivedAudio.append(chunk.bytes)
                        audioBytes += chunk.bytes.count
                    case .turnCompleted:
                        completed = true; phases.append("complete")
                        report.turns[reportIndex].completed = true
                        report.turns[reportIndex].seconds["commit_to_complete"] = HostInferenceReport.seconds(start.duration(to: .now))
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
                guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      completed, phases == ["source", "target", "audio", "complete"] else {
                    throw TranslationFailure(code: .invalidEvent, message: "The synthetic turn did not deliver complete ordered source, target and audio events.")
                }
                let format = try XCTUnwrap(receivedFormat)
                report.turns[reportIndex].audio = try HostInferenceAudioReport.analyze(receivedAudio, format: format)
                if let reportDirectory {
                    let name = fixture.source + "-" + fixture.target + ".wav"
                    try TranslationWaveCodec.encode(receivedAudio, format: format).write(to: reportDirectory.appendingPathComponent(name), options: .atomic)
                    report.turns[reportIndex].waveFile = name
                }
                print("Host cascade synthetic technical result pair=\(fixture.source)-\(fixture.target) ASR=\(manifest.recognition.modelID)@\(manifest.recognition.revision) LLM=\(manifest.translation.modelID)@\(manifest.translation.revision) speech=LFM3-Omni strategy=\(manifest.strategy.rawValue) receivedPCMBytes=\(audioBytes) commitToFirstReceivedPCM=\(String(describing: firstAudio)); not microphone/acoustic latency, meaning or voice qualification")
                let stopping = ContinuousClock.now
                await backend.stop(); activeBackend = nil
                report.turns[reportIndex].seconds["backend_stop"] = HostInferenceReport.seconds(stopping.duration(to: .now))
                report.turns[reportIndex].seconds["whole_turn_including_stop"] = HostInferenceReport.seconds(turnStart.duration(to: .now))
                report.turns[reportIndex].mlxRunningAfterStop = await runtime.isRunning
                report.turns[reportIndex].omniRunningAfterStop = await omni.isRunning
                XCTAssertFalse(report.turns[reportIndex].mlxRunningAfterStop == true)
                XCTAssertFalse(report.turns[reportIndex].omniRunningAfterStop == true)
                try report.write(to: reportDirectory)
            }
            await monitor.stop(); await runtime.stop(); await omni.stop()
            report.outcome = "completed"
            try report.write(to: reportDirectory)
        } catch {
            await activeBackend?.stop()
            await monitor.stop(); await runtime.stop(); await omni.stop()
            report.outcome = "failed"; report.failure = String(describing: error)
            try report.write(to: reportDirectory)
            throw error
        }
        let mlxRunning = await runtime.isRunning, omniRunning = await omni.isRunning
        XCTAssertFalse(mlxRunning); XCTAssertFalse(omniRunning)
    }
}

private struct HostInferenceReport: Encodable {
    let manifest: HostInferenceManifest
    let created = Date()
    let timingScope = "Each turn starts after the previous backend.stop completed and asserts both owned processes stopped. OS filesystem/model caches are uncontrolled. Timings are not microphone/acoustic latency or a warm/cold qualification."
    var outcome = "running"
    var failure: String?
    var turns: [HostInferenceTurnReport] = []

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
    static func prepareDirectory(_ path: String?) throws -> URL? {
        guard let path else { return nil }
        guard path.hasPrefix("/"), !FileManager.default.fileExists(atPath: path) else {
            throw TranslationFailure(code: .invalidConfiguration, message: "Synthetic evidence requires a new absolute report directory; existing files are never replaced.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory
    }
    func write(to directory: URL?) throws {
        guard let directory else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: directory.appendingPathComponent("report.json"), options: .atomic)
    }
}

private struct HostInferenceTurnReport: Encodable {
    let pair: String
    let mlxWasRunningBeforeTurn: Bool
    let omniWasRunningBeforeTurn: Bool
    var sourceText = ""
    var targetText = ""
    var completed = false
    var seconds: [String: Double] = [:]
    var audio: HostInferenceAudioReport?
    var waveFile: String?
    var mlxRunningAfterStop: Bool?
    var omniRunningAfterStop: Bool?
}

private struct HostInferenceAudioReport: Encodable {
    let format: TranslationPCMFormat
    let bytes: Int
    let sampleCount: Int
    let durationSeconds: Double
    let peakAbsoluteAmplitude: Double
    let rmsAmplitude: Double
    let nonzeroSamples: Int
    let allSamplesFinite: Bool
    let pcmSHA256: String

    static func analyze(_ data: Data, format: TranslationPCMFormat) throws -> Self {
        let duration = try format.duration(byteCount: data.count)
        var peak = 0.0, squared = 0.0, nonzero = 0
        let count = data.count / format.encoding.bytesPerSample
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for offset in stride(from: 0, to: raw.count, by: format.encoding.bytesPerSample) {
                let sample: Double
                switch format.encoding {
                case .float32LittleEndian:
                    sample = Double(Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))))
                case .signedInt16LittleEndian:
                    sample = Double(Int16(bitPattern: UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self)))) / 32_768
                }
                guard sample.isFinite else { throw TranslationFailure(code: .invalidAudio, message: "Received synthetic PCM contains nonfinite samples.") }
                peak = max(peak, abs(sample)); squared += sample * sample
                if sample != 0 { nonzero += 1 }
            }
        }
        guard nonzero > 0, peak > 0, squared > 0 else {
            throw TranslationFailure(code: .invalidAudio, message: "Received synthetic PCM is silent.")
        }
        return .init(format: format, bytes: data.count, sampleCount: count, durationSeconds: duration,
            peakAbsoluteAmplitude: peak, rmsAmplitude: sqrt(squared / Double(count)), nonzeroSamples: nonzero,
            allSamplesFinite: true, pcmSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
}

private struct HostInferenceManifest: Codable, Sendable {
    struct Model: Codable, Sendable { let modelID: String; let revision: String; let artifacts: [TranslationModelArtifact] }
    struct Omni: Codable, Sendable { let executable: String; let directory: String; let model: TranslationModelArtifact; let projector: TranslationModelArtifact }
    struct Fixture: Codable, Sendable {
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
