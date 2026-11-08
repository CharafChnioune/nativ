import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import NativTranslationKit

@MainActor
protocol TranslationOutputRouteWatching: AnyObject {
    func start(deviceID: AudioDeviceID?, onChange: @escaping @MainActor (Error) -> Void) throws
    func stop()
}

/// A system-default route is pinned for this session: unplugging headphones never silently selects speakers.
struct TranslationOutputRouteState: Equatable {
    let requestedDeviceID: AudioDeviceID?
    let initialDefaultID: AudioDeviceID
    let initialSampleRate: Double
    var resolvedDeviceID: AudioDeviceID { requestedDeviceID ?? initialDefaultID }
    func changed(defaultID: AudioDeviceID, alive: Bool, sampleRate: Double) -> Bool {
        !alive || !sampleRate.isFinite || sampleRate != initialSampleRate
            || (requestedDeviceID == nil && defaultID != initialDefaultID)
    }
}

@MainActor
final class TranslationOutputRouteMonitor: TranslationOutputRouteWatching {
    private struct Observation {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let callback: AudioObjectPropertyListenerBlock
    }
    private var observations: [Observation] = []
    private var state: TranslationOutputRouteState?
    private var epoch = UUID()
    private var onChange: (@MainActor (Error) -> Void)?
    static var changedError: TranslationFailure {
        .init(code: .invalidAudio, message: "Audio output changed or disconnected. Check the playback device and headphones, then Resume.")
    }
    func start(deviceID: AudioDeviceID?, onChange: @escaping @MainActor (Error) -> Void) throws {
        stop()
        let initialDefault: UInt32 = try Self.read(object: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice)
        let resolved = deviceID ?? initialDefault
        let alive: UInt32 = try Self.read(object: resolved, selector: kAudioDevicePropertyDeviceIsAlive)
        let rate: Double = try Self.read(object: resolved, selector: kAudioDevicePropertyNominalSampleRate)
        guard resolved != 0, alive != 0, rate.isFinite, rate > 0 else { throw Self.changedError }
        state = .init(requestedDeviceID: deviceID, initialDefaultID: initialDefault, initialSampleRate: rate)
        self.onChange = onChange
        let epoch = epoch
        let callback: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.validate(epoch: epoch) }
        }
        do {
            for (object, selector) in [(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice),
                                       (resolved, kAudioDevicePropertyDeviceIsAlive), (resolved, kAudioDevicePropertyNominalSampleRate)] {
                var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                let result = AudioObjectAddPropertyListenerBlock(object, &address, nil, callback)
                guard result == noErr else { throw Self.changedError }
                observations.append(.init(object: object, address: address, callback: callback))
            }
            validate(epoch: epoch)
        } catch { stop(); throw error }
    }
    private func validate(epoch: UUID) {
        guard self.epoch == epoch, let state else { return }
        let defaultID: UInt32? = try? Self.read(object: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice)
        let alive: UInt32? = try? Self.read(object: state.resolvedDeviceID, selector: kAudioDevicePropertyDeviceIsAlive)
        let rate: Double? = try? Self.read(object: state.resolvedDeviceID, selector: kAudioDevicePropertyNominalSampleRate)
        if state.changed(defaultID: defaultID ?? 0, alive: alive == 1, sampleRate: rate ?? 0) {
            let onChange = onChange
            stop()
            onChange?(Self.changedError)
        }
    }
    func stop() {
        epoch = UUID(); state = nil; onChange = nil
        for var observation in observations {
            AudioObjectRemovePropertyListenerBlock(observation.object, &observation.address, nil, observation.callback)
        }
        observations.removeAll()
    }
    isolated deinit { stop() }
    private static func read<T>(object: AudioObjectID, selector: AudioObjectPropertySelector) throws -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr,
              size == MemoryLayout<T>.size else { throw changedError }
        return pointer.load(as: T.self)
    }
}

@MainActor
final class TranslationPlaybackQueue {
    var onPlayingChanged: (@MainActor (Bool) -> Void)?
    private var pending: [UUID: Double] = [:]
    var pendingSeconds: Double { pending.values.reduce(0, +) }
    func reserve(seconds: Double) throws -> UUID {
        guard seconds.isFinite, seconds > 0, pendingSeconds + seconds <= 5.0000001 else {
            throw TranslationFailure(code: .overload, message: "Speech playback exceeded five seconds. Interrupt speech and repeat the incomplete turn.")
        }
        let wasEmpty = pending.isEmpty
        let id = UUID(); pending[id] = seconds
        if wasEmpty { onPlayingChanged?(true) }
        return id
    }
    func complete(_ id: UUID) {
        guard pending.removeValue(forKey: id) != nil else { return }
        if pending.isEmpty { onPlayingChanged?(false) }
    }
    func flush() {
        guard !pending.isEmpty else { return }
        pending.removeAll(); onPlayingChanged?(false)
    }
}

@MainActor
final class TranslationAudioPlayback {
    var onPlayingChanged: (@MainActor (Bool) -> Void)?
    var onFailure: (@MainActor (Error) -> Void)?
    var isPlaying: Bool { queue.pendingSeconds > 0 }
    var onMeterUpdate: (@MainActor @Sendable (Float) -> Void)?
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let queue = TranslationPlaybackQueue()
    private var format: TranslationPCMFormat?
    private var lease: AudioSessionLease?
    private var requestID = UUID()
    private var outputDeviceID: AudioDeviceID?
    private let meter = RealtimeAudioMeter(profile: .inputMonitor)
    private var meterTask: Task<Void, Never>?
    private var levels: [UUID: Float] = [:]
    private let routeMonitor: any TranslationOutputRouteWatching
    private let audioSessions: AudioSessionCoordinator
    private var engineObserver: NSObjectProtocol?
    private var engineObservationID = UUID()

    init(routeMonitor: any TranslationOutputRouteWatching = TranslationOutputRouteMonitor(),
         audioSessions: AudioSessionCoordinator = .shared) {
        self.routeMonitor = routeMonitor; self.audioSessions = audioSessions
        engine.attach(player)
        queue.onPlayingChanged = { [weak self] in self?.onPlayingChanged?($0) }
        let meter = meter
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            meter.submit(level: Self.level(buffer), elapsed: 0)
        }
    }

    isolated deinit {
        routeMonitor.stop()
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        meterTask?.cancel(); player.stop(); engine.stop()
        if let lease { audioSessions.release(lease) }
    }

    func start(outputDeviceID: AudioDeviceID? = nil, sessionID: TranslationSessionID? = nil) async throws {
        stop()
        let id = requestID
        let owner = AudioSessionOwner(id: sessionID?.rawValue ?? UUID(), name: "Live Translation")
        let lease = try await audioSessions.acquire(owner: owner, resources: [.playback])
        guard requestID == id, !Task.isCancelled else { audioSessions.release(lease); throw CancellationError() }
        self.lease = lease; self.outputDeviceID = outputDeviceID
        do {
            try routeMonitor.start(deviceID: outputDeviceID) { [weak self] error in self?.routeFailed(error, requestID: id) }
            guard requestID == id else { throw CancellationError() }
        } catch { stop(); throw error }
        meter.submit(level: 0, elapsed: 0)
        let meter = meter
        meterTask = Task { [weak self] in
            await RealtimeAudioMeterPublisher.run(meter: meter) { [weak self] snapshot in
                guard self?.requestID == id else { return }; self?.onMeterUpdate?(snapshot.level)
            }
        }
    }

    func enqueue(_ chunk: TranslationAudioChunk) async throws {
        try Task.checkCancellation()
        guard chunk.committed else { throw TranslationFailure(code: .invalidEvent, message: "Tentative speech must not play.") }
        guard let lease, audioSessions.isActive(lease) else {
            throw TranslationFailure(code: .invalidState, message: "Speech output is not active.")
        }
        let seconds = try chunk.format.duration(byteCount: chunk.bytes.count)
        let token = try queue.reserve(seconds: seconds)
        let playbackID = requestID
        do {
            let pcm = try await Self.decodeForPlayback(chunk)
            guard requestID == playbackID, !Task.isCancelled else { throw CancellationError() }
            if format != chunk.format {
                guard queue.pendingSeconds <= seconds + 0.000001 else { throw TranslationFailure(code: .invalidAudio, message: "Speech output changed format before its previous audio finished.") }
                removeEngineObserver()
                player.stop(); engine.stop()
                engine.disconnectNodeOutput(player)
                engine.connect(player, to: engine.mainMixerNode, format: pcm.format)
                if let outputDeviceID, let unit = engine.outputNode.audioUnit {
                    var device = outputDeviceID
                    let result = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
                    guard result == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
                }
                try engine.start()
                format = chunk.format
                observeEngine(requestID: playbackID)
            }
            let id = requestID
            let level = Self.level(pcm)
            levels[token] = level
            player.scheduleBuffer(pcm, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.requestID == id else { return }
                    self.queue.complete(token); self.levels[token] = nil
                    if self.levels.isEmpty { self.meter.submit(level: 0, elapsed: 0) }
                }
            }
            player.play()
        } catch { queue.complete(token); levels[token] = nil; throw error }
    }

    func stop() {
        requestID = UUID(); meterTask?.cancel(); meterTask = nil
        routeMonitor.stop(); removeEngineObserver()
        player.stop(); engine.stop(); queue.flush(); levels.removeAll(); format = nil
        if let lease { audioSessions.release(lease) }
        lease = nil; onMeterUpdate?(0)
    }

    private func routeFailed(_ error: Error, requestID: UUID) {
        guard self.requestID == requestID, lease != nil else { return }
        stop() // Flush synchronously before reporting the route change.
        onFailure?(error)
    }
    private func removeEngineObserver() {
        engineObservationID = UUID()
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = nil
    }
    private func observeEngine(requestID: UUID) {
        let observationID = engineObservationID
        engineObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.engineObservationID == observationID,
                      self.requestID == requestID, !self.engine.isRunning else { return }
                self.routeFailed(TranslationOutputRouteMonitor.changedError, requestID: requestID)
            }
        }
    }

    @concurrent
    private static func decodeForPlayback(_ chunk: TranslationAudioChunk) async throws -> sending AVAudioPCMBuffer {
        try decode(chunk)
    }

    nonisolated static func decode(_ chunk: TranslationAudioChunk) throws -> AVAudioPCMBuffer {
        _ = try chunk.format.duration(byteCount: chunk.bytes.count)
        let channels = chunk.format.channels
        let count = chunk.bytes.count / (channels * chunk.format.encoding.bytesPerSample)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: chunk.format.sampleRate, channels: AVAudioChannelCount(channels)),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
            throw TranslationFailure(code: .invalidAudio, message: "Invalid speech output format.")
        }
        buffer.frameLength = AVAudioFrameCount(count)
        chunk.bytes.withUnsafeBytes { raw in
            for frame in 0..<count { for channel in 0..<channels {
                let offset = (frame * channels + channel) * chunk.format.encoding.bytesPerSample
                let value: Float
                switch chunk.format.encoding {
                case .signedInt16LittleEndian: value = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self))) / 32768
                case .float32LittleEndian: value = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
                }
                buffer.floatChannelData![channel][frame] = value.isFinite ? max(-1, min(1, value)) : 0
            } }
        }
        return buffer
    }
    private nonisolated static func level(_ buffer: AVAudioPCMBuffer) -> Float {
        guard buffer.frameLength > 0, buffer.format.channelCount > 0, buffer.floatChannelData != nil else { return 0 }
        var sum: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) { for frame in 0..<Int(buffer.frameLength) {
            let value = buffer.floatChannelData![channel][frame]; sum += value * value
        } }
        return min(1, sqrt(sum / Float(Int(buffer.frameLength) * Int(buffer.format.channelCount))) * 4)
    }
}
