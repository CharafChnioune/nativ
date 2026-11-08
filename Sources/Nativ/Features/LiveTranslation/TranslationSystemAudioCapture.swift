@preconcurrency import AVFoundation
import Foundation
import NativTranslationKit
import ScreenCaptureKit

/// SCStream calls consume on its serial sampleQueue. Lock serializes replacement/stop
/// with that callback; the receiver copies CMSampleBuffer PCM before returning.
private final class TranslationSystemSampleSink: @unchecked Sendable {
    let sampleQueue = DispatchQueue(label: "io.github.charafchnioune.nativ.translation.system-audio")
    private let lock = NSLock()
    private var receiver: AudioInputSampleReceiver?
    private var delivery: AudioInputCaptureDelivery?
    func configure(bridge: TranslationPCMBridge, onFailure: @escaping @Sendable (Error) -> Void) {
        lock.withLock {
            let delivery = AudioInputCaptureDelivery(tap: { buffer, _ in bridge.submit(buffer) })
            self.delivery = delivery
            receiver = AudioInputSampleReceiver(delivery: delivery, onFailure: onFailure)
        }
    }
    func consume(_ sample: CMSampleBuffer) { lock.withLock { receiver?.consume(sample) } }
    func stop() { lock.withLock { delivery?.stop(); receiver = nil; delivery = nil } }
}

@MainActor
final class TranslationSystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onMeterUpdate: (@MainActor @Sendable (Float) -> Void)?
    private nonisolated let sink = TranslationSystemSampleSink()
    private var stream: SCStream?
    private var startup: Task<Void, Error>?
    private var bridge: TranslationPCMBridge?
    private var consumer: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?
    private var lease: AudioSessionLease?
    private var requestID = UUID()
    private var failureHandler: (@MainActor @Sendable (Error) -> Void)?
    private var teardown: Task<Void, Never>?

    isolated deinit {
        sink.stop(); bridge?.finish(); consumer?.cancel(); meterTask?.cancel()
        let stream = stream; let startup = startup; let lease = lease
        Task { @MainActor in
            _ = await startup?.result
            try? await stream?.stopCapture()
            if let lease { AudioSessionCoordinator.shared.release(lease) }
        }
    }

    func start(format: TranslationPCMFormat, sessionID: TranslationSessionID, generation: TranslationGeneration,
               onPCM: @escaping @Sendable (OwnedPCMFrame) async throws -> Void,
               onFailure: @escaping @MainActor @Sendable (Error) -> Void) async throws {
        await stopAndWait()
        let id = UUID(); requestID = id; failureHandler = onFailure
        let lease = try await AudioSessionCoordinator.shared.acquire(owner: .init(id: sessionID.rawValue, name: "Live Translation"), resources: [.systemAudio])
        guard requestID == id, !Task.isCancelled else { AudioSessionCoordinator.shared.release(lease); throw CancellationError() }
        self.lease = lease
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard requestID == id, !Task.isCancelled else { throw CancellationError() }
            guard let display = content.displays.first else { throw SystemAudioMeetingRecorderError.noDisplayAvailable }
            let ownApplications = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.captureMicrophone = false
            configuration.excludesCurrentProcessAudio = true
            let meter = RealtimeAudioMeter(profile: .inputMonitor)
            let bridge = try TranslationPCMBridge(format: format, context: .init(sessionID: sessionID, generation: generation, sourceID: "systemAudio"), meter: meter)
            self.bridge = bridge
            sink.configure(bridge: bridge) { [weak self] error in
                Task { @MainActor in self?.fail(error, id: id) }
            }
            consumer = Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    for await _ in bridge.signals {
                        while let frame = try bridge.take() {
                            try Task.checkCancellation(); try await onPCM(frame); bridge.didConsume(frame)
                        }
                    }
                } catch { guard !Task.isCancelled else { return }; await self?.fail(error, id: id) }
            }
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            self.stream = stream
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sink.sampleQueue)
            let startup = Task { try await stream.startCapture() }
            self.startup = startup
            try await startup.value
            guard requestID == id, !Task.isCancelled else { throw CancellationError() }
            meterTask = Task { [weak self] in
                await RealtimeAudioMeterPublisher.run(meter: meter) { [weak self] snapshot in
                    guard self?.requestID == id else { return }; self?.onMeterUpdate?(snapshot.level)
                }
            }
        } catch {
            if requestID == id { await stopAndWait() }
            throw error
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio, sampleBuffer.isValid, sampleBuffer.dataReadiness == .ready else { return }
        sink.consume(sampleBuffer)
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let identity = ObjectIdentifier(stream)
        Task { @MainActor [weak self] in
            guard let self, let active = self.stream, ObjectIdentifier(active) == identity else { return }
            self.fail(error, id: self.requestID)
        }
    }
    private func fail(_ error: Error, id: UUID) {
        guard requestID == id else { return }
        let handler = failureHandler
        stop()
        handler?(error)
    }
    func stop() {
        requestID = UUID(); failureHandler = nil
        sink.stop(); bridge?.finish(); bridge = nil
        consumer?.cancel(); let consumer = consumer; self.consumer = nil
        meterTask?.cancel(); meterTask = nil; onMeterUpdate?(0)
        let stream = stream; self.stream = nil
        let startup = startup; self.startup = nil
        let lease = lease; self.lease = nil
        let previous = teardown
        teardown = Task {
            await previous?.value
            _ = await startup?.result
            if let stream {
                try? await stream.stopCapture()
                try? stream.removeStreamOutput(self, type: .audio)
            }
            await consumer?.value
            if let lease { AudioSessionCoordinator.shared.release(lease) }
        }
    }
    func stopAndWait() async { stop(); let terminal = teardown; await terminal?.value }
}
