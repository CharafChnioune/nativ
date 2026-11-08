import AVFoundation
import Foundation
import NativTranslationKit

struct TranslationCaptureContext: Sendable {
    let sessionID: TranslationSessionID
    let turnID: TranslationTurnID
    let generation: TranslationGeneration
    let sourceID: String
    init(sessionID: TranslationSessionID = .init(), turnID: TranslationTurnID = .init(), generation: TranslationGeneration = .init(), sourceID: String = "microphone") {
        self.sessionID = sessionID; self.turnID = turnID; self.generation = generation; self.sourceID = sourceID
    }
}

/// All converter, queue and failure state is protected by lock. A borrowed AV buffer never
/// escapes submit; only copied Data crosses to the single async consumer. In-flight frames
/// continue counting against the two-second transport bound until didConsume.
final class TranslationPCMBridge: @unchecked Sendable {
    let signals: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private let format: TranslationPCMFormat
    private let targetFormat: AVAudioFormat
    private let context: TranslationCaptureContext
    private let meter: RealtimeAudioMeter?
    private var converter: AVAudioConverter?
    private var pendingBuffer: AVAudioPCMBuffer?
    private var frames: [OwnedPCMFrame] = []
    private var retainedSeconds: Double = 0
    private var sequence: UInt64 = 0
    private var failure: Error?
    private var closed = false

    init(format: TranslationPCMFormat, context: TranslationCaptureContext, meter: RealtimeAudioMeter? = nil) throws {
        _ = try format.duration(byteCount: format.encoding.bytesPerSample)
        guard format.channels == 1, let target = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1) else {
            throw TranslationFailure(code: .invalidAudio, message: "Capture requires a negotiated mono PCM format.")
        }
        self.format = format; targetFormat = target; self.context = context; self.meter = meter
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        signals = pair.stream; signal = pair.continuation
    }

    func submit(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard !closed, failure == nil, buffer.frameLength > 0 else { return }
            do {
                if buffer.format == targetFormat {
                    try drainConverter()
                    converter = nil
                    try copyAndQueue(buffer)
                } else {
                    if converter?.inputFormat != buffer.format {
                        try drainConverter()
                        converter = AVAudioConverter(from: buffer.format, to: targetFormat)
                        converter?.downmix = true
                    }
                    guard let converter, let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4096) else {
                        throw TranslationFailure(code: .invalidAudio, message: "Could not convert the microphone format.")
                    }
                    pendingBuffer = buffer
                    defer { pendingBuffer = nil }
                    while true {
                        output.frameLength = 0
                        var error: NSError?
                        let status = converter.convert(to: output, error: &error) { [self] _, status in
                            if let buffer = pendingBuffer {
                                pendingBuffer = nil; status.pointee = .haveData; return buffer
                            }
                            status.pointee = .noDataNow; return nil
                        }
                        if status == .error { throw error ?? VoiceAudioRecorderError.couldNotConvert as NSError }
                        if output.frameLength > 0 { try copyAndQueue(output) }
                        if status != .haveData { break }
                    }
                }
            } catch {
                failure = error
                frames.removeAll(keepingCapacity: false)
                retainedSeconds = 0
            }
            signal.yield(())
        }
    }

    private func drainConverter() throws {
        guard let converter, let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4096) else { return }
        while true {
            output.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, status in
                status.pointee = .endOfStream
                return nil
            }
            if status == .error { throw error ?? VoiceAudioRecorderError.couldNotConvert as NSError }
            if output.frameLength > 0 { try copyAndQueue(output) }
            if status != .haveData { break }
        }
    }

    private func copyAndQueue(_ pcm: AVAudioPCMBuffer) throws {
        guard let samples = pcm.floatChannelData?[0] else { throw VoiceAudioRecorderError.couldNotConvert }
        let count = Int(pcm.frameLength)
        let duration = Double(count) / format.sampleRate
        guard retainedSeconds + duration <= 2.0000001 else {
            throw TranslationFailure(code: .overload, message: "Audio input exceeded the two-second transport limit. This turn is incomplete; pause and repeat it.")
        }
        var bytes = Data(capacity: count * format.encoding.bytesPerSample)
        var squared: Float = 0
        for index in 0..<count {
            let raw = samples[index * pcm.stride]
            let sample = raw.isFinite ? max(-1, min(1, raw)) : 0
            squared += sample * sample
            switch format.encoding {
            case .signedInt16LittleEndian:
                var value = Int16(max(-32768, min(32767, (sample * 32768).rounded()))).littleEndian
                withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) }
            case .float32LittleEndian:
                var value = sample.bitPattern.littleEndian
                withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) }
            }
        }
        meter?.submit(level: min(1, sqrt(squared / Float(count)) * 4), elapsed: 0)
        frames.append(OwnedPCMFrame(bytes: bytes, format: format, captureTimestampNanoseconds: DispatchTime.now().uptimeNanoseconds,
                                   sequence: sequence, sourceID: context.sourceID, sessionID: context.sessionID,
                                   turnID: context.turnID, generation: context.generation))
        sequence &+= 1; retainedSeconds += duration
    }

    func take() throws -> OwnedPCMFrame? {
        try lock.withLock {
            if let failure { throw failure }
            guard !closed, !frames.isEmpty else { return nil }
            return frames.removeFirst()
        }
    }
    func didConsume(_ frame: OwnedPCMFrame) {
        lock.withLock { retainedSeconds = max(0, retainedSeconds - ((try? frame.format.duration(byteCount: frame.bytes.count)) ?? 0)) }
    }
    func finish() {
        lock.withLock { closed = true; frames.removeAll(); retainedSeconds = 0; pendingBuffer = nil; converter = nil }
        signal.finish()
    }
}

@MainActor
final class TranslationAudioCapture {
    var onMeterUpdate: (@MainActor @Sendable (Float) -> Void)?
    private let makeInput: @MainActor (AudioSessionOwner) -> AudioInputCaptureSession
    private var input: AudioInputCaptureSession?
    private var bridge: TranslationPCMBridge?
    private var consumer: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?
    private var requestID = UUID()

    isolated deinit {
        bridge?.finish(); consumer?.cancel(); meterTask?.cancel(); input?.stop()
    }

    init(makeInput: @escaping @MainActor (AudioSessionOwner) -> AudioInputCaptureSession = { AudioInputCaptureSession(owner: $0) }) { self.makeInput = makeInput }

    func start(deviceUniqueID: String?, format: TranslationPCMFormat, sessionID: TranslationSessionID, generation: TranslationGeneration,
               sourceID: String = "microphone", onPCM: @escaping @Sendable (OwnedPCMFrame) async throws -> Void,
               onFailure: @escaping @MainActor @Sendable (Error) -> Void) async throws {
        await stopAndWait()
        let id = UUID(); requestID = id
        let meter = RealtimeAudioMeter(profile: .inputMonitor)
        let bridge = try TranslationPCMBridge(format: format, context: .init(sessionID: sessionID, generation: generation, sourceID: sourceID), meter: meter)
        let input = makeInput(.init(id: sessionID.rawValue, name: "Live Translation"))
        self.input = input; self.bridge = bridge
        consumer = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                for await _ in bridge.signals {
                    while let frame = try bridge.take() {
                        try Task.checkCancellation()
                        try await onPCM(frame)
                        bridge.didConsume(frame)
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await self?.fail(error, id: id, onFailure: onFailure)
            }
        }
        do {
            guard await NativSystemPermissionController.requestMicrophone() else {
                throw TranslationFailure(code: .invalidState, message: "Allow microphone access in System Settings.")
            }
            guard requestID == id, !Task.isCancelled else { throw CancellationError() }
            try await input.start(deviceUniqueID: deviceUniqueID, tap: { buffer, _ in bridge.submit(buffer) }) { [weak self] error in
                self?.fail(error, id: id, onFailure: onFailure)
            }
            guard requestID == id, !Task.isCancelled else { throw CancellationError() }
            meterTask = Task { [weak self] in
                await RealtimeAudioMeterPublisher.run(meter: meter) { [weak self] snapshot in
                    guard self?.requestID == id else { return }
                    self?.onMeterUpdate?(snapshot.level)
                }
            }
        } catch {
            if requestID == id { await stopAndWait() }
            throw error
        }
    }

    private func fail(_ error: Error, id: UUID, onFailure: @MainActor @Sendable (Error) -> Void) {
        guard requestID == id else { return }
        stop()
        onFailure(error)
    }
    func stop() {
        requestID = UUID(); bridge?.finish(); bridge = nil
        consumer?.cancel(); meterTask?.cancel(); meterTask = nil
        input?.stop(); onMeterUpdate?(0)
    }
    func stopAndWait() async {
        stop()
        let input = input; self.input = nil
        let consumer = consumer; self.consumer = nil
        await input?.stopAndWait()
        await consumer?.value
    }
}
