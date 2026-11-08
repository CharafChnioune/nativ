import Foundation
import XCTest

@MainActor
final class TranslationHostOperationGateTests: XCTestCase {
    func testMuteWhileSpeakerTeardownIsSuspendedRejectsOldAudio() async throws {
        let gate = TranslationHostOperationGate()
        let suspension = HostTestSuspension()
        let ticket = gate.current
        var enqueued = false
        let delivery = Task {
            try await gate.perform(token: ticket) { await suspension.wait() }
            enqueued = true
        }
        await suspension.awaitEntry()
        gate.invalidate() // synchronous Mute/Stop invalidation
        suspension.resume()
        do { try await delivery.value; XCTFail("Muted audio reached playback") }
        catch is CancellationError { }
        XCTAssertFalse(enqueued)
    }

    func testOlderInterruptCannotResumeCaptureAfterASecondInterrupt() async throws {
        let gate = TranslationHostOperationGate()
        let suspension = HostTestSuspension()
        let first = gate.invalidate()
        var captureStarts = 0
        let oldCommand = Task {
            try await gate.perform(token: first) { await suspension.wait() }
            captureStarts += 1
        }
        await suspension.awaitEntry()
        let second = gate.invalidate()
        try await gate.perform(token: second) { captureStarts += 1 }
        suspension.resume()
        do { try await oldCommand.value; XCTFail("Superseded interrupt resumed capture") }
        catch is CancellationError { }
        XCTAssertEqual(captureStarts, 1)
    }

    func testPreparationCleanupDoesNotClearANewerPreparation() async throws {
        let gate = TranslationHostOperationGate()
        let suspension = HostTestSuspension()
        let first = gate.invalidate()
        var preparing = true
        let oldPreparation = Task {
            defer { if gate.isCurrent(first) { preparing = false } }
            try await gate.perform(token: first) { await suspension.wait() }
        }
        await suspension.awaitEntry()
        gate.invalidate()
        preparing = true
        suspension.resume()
        do { try await oldPreparation.value; XCTFail("Superseded preparation accepted") }
        catch is CancellationError { }
        XCTAssertTrue(preparing)
    }

    func testSupersededOperationDoesNotReportALateFailureToTheNewOwner() async throws {
        enum LateFailure: Error { case unavailable }
        let gate = TranslationHostOperationGate()
        let suspension = HostTestSuspension()
        let token = gate.current
        let operation = Task {
            try await gate.perform(token: token) {
                await suspension.wait()
                throw LateFailure.unavailable
            }
        }
        await suspension.awaitEntry()
        gate.invalidate()
        suspension.resume()
        do { try await operation.value; XCTFail("The old operation succeeded") }
        catch is CancellationError { }
        catch { XCTFail("The new owner received the old operation's failure: \(error)") }
    }
}

@MainActor
private final class HostTestSuspension {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered = false
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func awaitEntry() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !entered, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(entered, "The tested operation did not reach its real suspension")
    }
    func resume() { continuation?.resume(); continuation = nil }
}
