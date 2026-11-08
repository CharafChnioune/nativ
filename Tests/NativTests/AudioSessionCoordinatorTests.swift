import XCTest
#if canImport(NativAudioHarness)
@testable import NativAudioHarness
#endif

@MainActor
final class AudioSessionCoordinatorTests: XCTestCase {
    func testForegroundCannotBypassAnotherRecordingAndStaleReleaseCannotUnlockIt() async throws {
        let coordinator = AudioSessionCoordinator()
        let first = try await coordinator.acquire(owner: .init(name: "Dictation"), resources: [.microphone])
        do {
            _ = try await coordinator.acquire(owner: .init(name: "Translation"), resources: [.microphone, .playback])
            XCTFail("Conflicting recording was granted")
        } catch is AudioSessionConflict {}
        coordinator.release(first)
        let next = try await coordinator.acquire(owner: .init(name: "Translation"), resources: [.microphone, .playback])
        coordinator.release(first)
        XCTAssertTrue(coordinator.isActive(next))
        coordinator.release(next)
    }

    func testPassiveTeardownFinishesBeforeForegroundGrantAndCancellationReleasesReservation() async throws {
        let coordinator = AudioSessionCoordinator()
        var teardown: CheckedContinuation<Void, Never>?
        var restored = 0
        coordinator.registerPassiveListener(suspend: {
            await withCheckedContinuation { teardown = $0 }
        }, resume: { restored += 1 })
        let passive = try await coordinator.acquire(owner: .init(name: "Wake word"), resources: [.microphone], passive: true)
        let acquisition = Task { try await coordinator.acquire(owner: .init(name: "Translation"), resources: [.microphone, .playback]) }
        while teardown == nil { await Task.yield() }
        XCTAssertFalse(coordinator.isActive(passive))
        do {
            _ = try await coordinator.acquire(owner: .init(name: "Input test"), resources: [.microphone])
            XCTFail("A pending handoff must reserve resources")
        } catch is AudioSessionConflict {}
        acquisition.cancel()
        teardown?.resume()
        do { _ = try await acquisition.value; XCTFail("Cancelled acquisition granted") } catch is CancellationError {}
        XCTAssertEqual(restored, 1)
        let next = try await coordinator.acquire(owner: .init(name: "Input test"), resources: [.microphone])
        coordinator.release(passive)
        XCTAssertTrue(coordinator.isActive(next))
        coordinator.release(next)
    }

    func testSameTranslationOwnerCanCaptureAndPlayButCannotOpenSecondMic() async throws {
        let coordinator = AudioSessionCoordinator()
        let owner = AudioSessionOwner(name: "Translation")
        let capture = try await coordinator.acquire(owner: owner, resources: [.microphone])
        let output = try await coordinator.acquire(owner: owner, resources: [.playback])
        do { _ = try await coordinator.acquire(owner: owner, resources: [.microphone]); XCTFail() } catch is AudioSessionConflict {}
        coordinator.release(output)
        XCTAssertTrue(coordinator.isActive(capture))
        coordinator.release(capture)
    }

    func testSameOwnerSecondResourceAlsoWaitsForPassiveCaptureTeardown() async throws {
        let coordinator = AudioSessionCoordinator()
        var teardown: CheckedContinuation<Void, Never>?
        coordinator.registerPassiveListener(suspend: {
            await withCheckedContinuation { teardown = $0 }
        }, resume: {})
        _ = try await coordinator.acquire(owner: .init(name: "Wake word"), resources: [.microphone], passive: true)
        let owner = AudioSessionOwner(name: "Translation")
        let capture = Task { try await coordinator.acquire(owner: owner, resources: [.microphone]) }
        for _ in 0..<10_000 { if teardown != nil { break }; await Task.yield() }
        XCTAssertNotNil(teardown)
        var grantedPlayback = false
        let playback = Task {
            let lease = try await coordinator.acquire(owner: owner, resources: [.playback])
            grantedPlayback = true
            return lease
        }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertFalse(grantedPlayback, "A disjoint lease must still await the same device teardown barrier")
        teardown?.resume()
        let first = try await capture.value
        let second = try await playback.value
        XCTAssertTrue(grantedPlayback)
        coordinator.release(first); coordinator.release(second)
    }
}
