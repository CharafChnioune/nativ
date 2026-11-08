import AVFoundation
import NativTranslationKit
import XCTest
#if canImport(NativAudioHarness)
@testable import NativAudioHarness
#endif

final class TranslationAudioTests: XCTestCase {
    func testDefaultOutputChangesNeverBecomeImplicitSpeakerFallback() {
        let system = TranslationOutputRouteState(requestedDeviceID: nil, initialDefaultID: 42, initialSampleRate: 48_000)
        XCTAssertFalse(system.changed(defaultID: 42, alive: true, sampleRate: 48_000))
        XCTAssertTrue(system.changed(defaultID: 99, alive: true, sampleRate: 48_000))
        XCTAssertTrue(system.changed(defaultID: 42, alive: false, sampleRate: 48_000))
        let selected = TranslationOutputRouteState(requestedDeviceID: 42, initialDefaultID: 42, initialSampleRate: 48_000)
        XCTAssertFalse(selected.changed(defaultID: 99, alive: true, sampleRate: 48_000), "An unrelated default change does not move an explicit output")
        XCTAssertTrue(selected.changed(defaultID: 99, alive: true, sampleRate: 44_100))
    }

    @MainActor
    func testOutputRouteFailureReleasesPlaybackAndStaleNotificationsCannotStopNextSession() async throws {
        let sessions = AudioSessionCoordinator()
        let monitor = FixtureTranslationRouteMonitor()
        let playback = TranslationAudioPlayback(routeMonitor: monitor, audioSessions: sessions)
        var failures = 0
        playback.onFailure = { _ in failures += 1 }
        try await playback.start()
        let stale = try XCTUnwrap(monitor.callback)
        stale(TranslationOutputRouteMonitor.changedError)
        XCTAssertEqual(failures, 1)
        XCTAssertFalse(sessions.hasForegroundActivity)
        XCTAssertFalse(playback.isPlaying)
        try await playback.start()
        stale(TranslationOutputRouteMonitor.changedError)
        XCTAssertEqual(failures, 1)
        XCTAssertTrue(sessions.hasForegroundActivity)
        monitor.callback?(TranslationOutputRouteMonitor.changedError)
        XCTAssertEqual(failures, 2)
        XCTAssertFalse(sessions.hasForegroundActivity)
        playback.stop()
    }

    func testCaptureCopiesReusedCallbackStorageBeforeReturning() throws {
        let bridge = try TranslationPCMBridge(format: .init(sampleRate: 16000, channels: 1, encoding: .signedInt16LittleEndian), context: .init())
        let buffer = try pcm(frames: 320, rate: 16000, channels: 1, amplitude: 0.25)
        bridge.submit(buffer)
        buffer.floatChannelData![0].update(repeating: -0.5, count: 320)
        let frame = try XCTUnwrap(bridge.take())
        XCTAssertEqual(frame.bytes.prefix(4), Data([0, 32, 0, 32]))
        XCTAssertEqual(frame.bytes.count, 640)
        bridge.didConsume(frame)
    }

    func testCaptureTransportReportsOverflowInsteadOfSilentlyDroppingSpeech() throws {
        let bridge = try TranslationPCMBridge(format: .init(sampleRate: 16000, channels: 1, encoding: .signedInt16LittleEndian), context: .init())
        let buffer = try pcm(frames: 320, rate: 16000, channels: 1, amplitude: 0.25)
        for _ in 0..<101 { bridge.submit(buffer) }
        XCTAssertThrowsError(try bridge.take()) { XCTAssertEqual(($0 as? TranslationFailure)?.code, .overload) }
    }

    func testCaptureResamplesDownmixesAndHandlesDeviceRateChange() throws {
        let bridge = try TranslationPCMBridge(format: .init(sampleRate: 16000, channels: 1, encoding: .signedInt16LittleEndian), context: .init())
        for rate in [44100.0, 48000.0] {
            bridge.submit(try pcm(frames: AVAudioFrameCount(rate / 10), rate: rate, channels: 2, amplitude: 0.25))
        }
        var bytes = 0
        while let frame = try bridge.take() {
            XCTAssertEqual(frame.format.sampleRate, 16000)
            XCTAssertEqual(frame.format.channels, 1)
            bytes += frame.bytes.count
            bridge.didConsume(frame)
        }
        XCTAssertGreaterThan(bytes, 5000)
        XCTAssertLessThanOrEqual(bytes, 6400)
    }

    func testRepeatedDeviceFormatChangesDrainTheOldResamplerInsteadOfLosingSpeech() throws {
        let bridge = try TranslationPCMBridge(format: .init(sampleRate: 16000, channels: 1, encoding: .signedInt16LittleEndian), context: .init())
        var bytes = 0
        for index in 0..<100 {
            let rate = index.isMultiple(of: 2) ? 44100.0 : 48000.0
            bridge.submit(try pcm(frames: AVAudioFrameCount(rate / 100), rate: rate, channels: 2, amplitude: 0.25))
            while let frame = try bridge.take() { bytes += frame.bytes.count; bridge.didConsume(frame) }
        }
        XCTAssertGreaterThan(bytes, 31000, "One second of speech may lose only the final undrained converter tail, not a tail per device change")
    }

    @MainActor
    func testPlaybackQueueBoundsAndStaleCompletionAfterFlush() throws {
        let queue = TranslationPlaybackQueue()
        var changes: [Bool] = []
        queue.onPlayingChanged = { changes.append($0) }
        let first = try queue.reserve(seconds: 4)
        XCTAssertThrowsError(try queue.reserve(seconds: 2))
        queue.flush()
        let next = try queue.reserve(seconds: 3)
        queue.complete(first)
        XCTAssertEqual(queue.pendingSeconds, 3)
        queue.complete(next)
        XCTAssertEqual(queue.pendingSeconds, 0)
        XCTAssertEqual(changes, [true, false, true, false])
    }

    func testRealWebRTCVADRejectsInvalidWindowAndDoesNotTreatSilenceAsSpeech() throws {
        let detector = try WebRTCTranslationVoiceActivityDetector()
        XCTAssertFalse(try detector.isSpeech(Array(repeating: 0, count: 320)))
        XCTAssertThrowsError(try detector.isSpeech([0]))
    }

    func testSpeechSegmentationCommitsOnSilenceAndForcedBoundaryNeverCancelsNextSpeech() async throws {
        let segmenter = TranslationSpeechSegmenter(detector: DeterministicTranslationVAD())
        let format = TranslationPCMFormat(sampleRate: 16000, channels: 1, encoding: .signedInt16LittleEndian)
        let session = TranslationSessionID()
        var commits: [TranslationTurnID] = []
        var audioTurns = Set<TranslationTurnID>()
        var continuations: [Bool] = []
        for index in 0..<620 {
            let speech = index < 600
            let data = Data(repeating: speech ? 1 : 0, count: 640)
            let frame = OwnedPCMFrame(bytes: data, format: format, captureTimestampNanoseconds: UInt64(index) * 20_000_000,
                                      sequence: UInt64(index), sourceID: "microphone", sessionID: session,
                                      turnID: .init(), generation: .init())
            for event in try await segmenter.consume(frame) {
                switch event {
                case .audio(let audio): audioTurns.insert(audio.turnID)
                case .commit(let id, let continuation): commits.append(id); continuations.append(continuation)
                }
            }
        }
        XCTAssertEqual(continuations.first, true)
        XCTAssertEqual(commits.count, 1, "Silence after a forced complete turn is not an extra empty turn")
        XCTAssertEqual(audioTurns.count, 1)
    }

    @MainActor
    func testStopAndWaitDoesNotReleaseMicUntilDriverTeardownCompletes() async throws {
        let coordinator = AudioSessionCoordinator()
        let driver = SuspendedTranslationCaptureDriver()
        let session = AudioInputCaptureSession(audioSessions: coordinator, makeCapture: { driver })
        try await session.start(deviceUniqueID: nil, tap: { _, _ in }) { _ in XCTFail() }
        var teardownReturned = false
        let stopping = Task { await session.stopAndWait(); teardownReturned = true }
        while driver.stopping == nil { await Task.yield() }
        XCTAssertFalse(teardownReturned)
        do { _ = try await coordinator.acquire(owner: .init(name: "Second recorder"), resources: [.microphone]); XCTFail() } catch is AudioSessionConflict {}
        driver.stopping?.resume(); driver.stopping = nil
        await stopping.value
        let next = try await coordinator.acquire(owner: .init(name: "Second recorder"), resources: [.microphone])
        XCTAssertTrue(teardownReturned)
        coordinator.release(next)
    }

    private func pcm(frames: AVAudioFrameCount, rate: Double, channels: AVAudioChannelCount, amplitude: Float) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<Int(channels) { buffer.floatChannelData![channel].update(repeating: amplitude, count: Int(frames)) }
        return buffer
    }
}

@MainActor
private final class FixtureTranslationRouteMonitor: TranslationOutputRouteWatching {
    var callback: (@MainActor (Error) -> Void)?
    func start(deviceID: UInt32?, onChange: @escaping @MainActor (Error) -> Void) throws { callback = onChange }
    func stop() { callback = nil }
}

private final class DeterministicTranslationVAD: TranslationVoiceActivityDetecting {
    func isSpeech(_ samples: [Int16]) throws -> Bool { samples.contains { $0 != 0 } }
    func reset() {}
}

@MainActor
private final class SuspendedTranslationCaptureDriver: AudioInputCaptureDriving {
    var stopping: CheckedContinuation<Void, Never>?
    func start(deviceUniqueID: String?, delivery: AudioInputCaptureDelivery, onFailure: @escaping @Sendable (Error) -> Void) async throws {}
    func select(deviceUniqueID: String?) async throws {}
    func stop() async { await withCheckedContinuation { stopping = $0 } }
}
