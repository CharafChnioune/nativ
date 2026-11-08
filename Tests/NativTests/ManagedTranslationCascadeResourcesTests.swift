import Foundation
import NativTranslationKit
import XCTest

final class ManagedTranslationCascadeResourcesTests: XCTestCase, @unchecked Sendable {
    func testSequentialReleasesEachOwnedModelBeforeAnotherStage() async throws {
        let calls = CascadeResourceCalls()
        let resources = Self.make(.sequential, calls: calls)
        let generation = UUID()
        try await resources.begin(generation: generation)
        for stage in [TranslationCascadeStage.recognition, .translation, .speech] {
            let lease = try await resources.acquire(stage, generation: generation)
            await resources.release(lease)
        }
        let recorded = await calls.values
        XCTAssertEqual(recorded, ["stop-speech", "unload-mlx", "stop-speech", "unload-mlx", "prepare-speech", "unload-mlx", "stop-speech"])
    }

    func testResidentRetainsModelsBetweenTurnsButInvalidationStopsOnlyOwnedProcesses() async throws {
        let calls = CascadeResourceCalls()
        let resources = Self.make(.resident, calls: calls)
        let generation = UUID()
        try await resources.begin(generation: generation)
        for stage in [TranslationCascadeStage.recognition, .translation, .speech] {
            let lease = try await resources.acquire(stage, generation: generation)
            await resources.release(lease)
        }
        let warm = await calls.values
        XCTAssertEqual(warm, ["prepare-speech"])
        await resources.invalidate(generation: generation)
        let stopped = await calls.values
        XCTAssertEqual(Set(stopped), ["prepare-speech", "stop-speech", "stop-mlx"])
    }

    func testStaleReleaseAndInvalidationCannotUnloadNextGeneration() async throws {
        let calls = CascadeResourceCalls()
        let resources = Self.make(.sequential, calls: calls)
        let old = UUID(), current = UUID()
        try await resources.begin(generation: old)
        let stale = try await resources.acquire(.recognition, generation: old)
        await resources.invalidate(generation: old)
        try await resources.begin(generation: current)
        let active = try await resources.acquire(.translation, generation: current)
        await calls.reset()
        await resources.release(stale)
        await resources.invalidate(generation: old)
        let ignored = await calls.values
        XCTAssertTrue(ignored.isEmpty)
        await resources.release(active)
        let released = await calls.values
        XCTAssertEqual(released, ["unload-mlx"])
    }

    func testCriticalPressureRejectsAdmissionBeforeLoadingEitherModel() async throws {
        let calls = CascadeResourceCalls()
        let resources = Self.make(.sequential, calls: calls, isCritical: { true })
        let generation = UUID()
        try await resources.begin(generation: generation)
        do { _ = try await resources.acquire(.speech, generation: generation); XCTFail("Critical pressure must block model load") }
        catch let error as TranslationFailure { XCTAssertEqual(error.code, .providerFailure) }
        let recorded = await calls.values
        XCTAssertTrue(recorded.isEmpty)
    }

    func testReleaseMustFinishBeforeNewGenerationCanAcquireModels() async throws {
        let calls = CascadeResourceCalls()
        let barrier = CascadeResourceBarrier()
        let resources = ManagedTranslationCascadeResources(
            strategy: .sequential, prepareSpeech: {}, stopSpeech: {},
            unloadModels: { await barrier.wait(); await calls.append("released") },
            stopRuntime: { await calls.append("stopped") })
        let old = UUID(), next = UUID()
        try await resources.begin(generation: old)
        let lease = try await resources.acquire(.translation, generation: old)
        let release = Task { await resources.release(lease) }
        await barrier.waitUntilEntered()
        let beginning = Task { try await resources.begin(generation: next); await calls.append("new-generation") }
        await Task.yield()
        let before = await calls.values
        XCTAssertFalse(before.contains("new-generation"))
        await barrier.open()
        await release.value
        try await beginning.value
        let after = await calls.values
        XCTAssertLessThan(try XCTUnwrap(after.firstIndex(of: "released")), try XCTUnwrap(after.firstIndex(of: "new-generation")))
    }

    func testInvalidatedPendingBeginCannotResurrectAfterCleanup() async throws {
        let barrier = CascadeResourceBarrier()
        let resources = ManagedTranslationCascadeResources(
            strategy: .sequential, prepareSpeech: {}, stopSpeech: {}, unloadModels: {},
            stopRuntime: { await barrier.wait() })
        let old = UUID(), pending = UUID()
        try await resources.begin(generation: old)
        let beginning = Task { try await resources.begin(generation: pending) }
        await barrier.waitUntilEntered()
        let stopping = Task { await resources.invalidate(generation: pending) }
        // The invalidation synchronously clears the pending begin before it awaits the same cleanup.
        for _ in 0..<1_000 {
            if await resources.pendingGeneration == nil { break }
            await Task.yield()
        }
        let stillPending = await resources.pendingGeneration
        XCTAssertNil(stillPending)
        await barrier.open()
        await stopping.value
        do { try await beginning.value; XCTFail("Stopped pending begin must not become active") }
        catch is CancellationError {}
        do { _ = try await resources.acquire(.recognition, generation: pending); XCTFail("Stopped generation must remain invalid") }
        catch is CancellationError {}
    }

    func testInvalidationDuringSpeechAdmissionDrainsPreparerBeforeNextGeneration() async throws {
        let calls = CascadeResourceCalls()
        let barrier = CascadeResourceBarrier()
        let resources = ManagedTranslationCascadeResources(
            strategy: .sequential,
            prepareSpeech: { await barrier.wait(); await calls.append("preparer-returned") },
            stopSpeech: { await calls.append("stop-speech") }, unloadModels: {},
            stopRuntime: { await calls.append("stop-mlx") })
        let old = UUID(), next = UUID()
        try await resources.begin(generation: old)
        let acquiring = Task { try await resources.acquire(.speech, generation: old) }
        await barrier.waitUntilEntered()
        let stopping = Task { await resources.invalidate(generation: old) }
        for _ in 0..<1_000 {
            if await calls.values.contains("stop-mlx") { break }
            await Task.yield()
        }
        let stoppedWorkers = await calls.values
        XCTAssertTrue(stoppedWorkers.contains("stop-mlx"))
        let beginning = Task { try await resources.begin(generation: next); await calls.append("new-generation") }
        for _ in 0..<1_000 {
            if await resources.pendingGeneration == next { break }
            await Task.yield()
        }
        let pending = await resources.pendingGeneration
        XCTAssertEqual(pending, next)
        let before = await calls.values
        XCTAssertFalse(before.contains("new-generation"))
        await barrier.open()
        do { _ = try await acquiring.value; XCTFail("Invalidated speech admission returned a lease") }
        catch is CancellationError {}
        await stopping.value
        try await beginning.value
        let after = await calls.values
        XCTAssertLessThan(try XCTUnwrap(after.firstIndex(of: "preparer-returned")),
                          try XCTUnwrap(after.firstIndex(of: "new-generation")))
        let admitted = try await resources.acquire(.recognition, generation: next)
        await resources.release(admitted)
        await resources.invalidate(generation: next)
    }

    private static func make(_ strategy: TranslationCascadeMemoryStrategy, calls: CascadeResourceCalls,
                             isCritical: @escaping @Sendable () -> Bool = { false }) -> ManagedTranslationCascadeResources {
        .init(strategy: strategy, prepareSpeech: { await calls.append("prepare-speech") },
              stopSpeech: { await calls.append("stop-speech") }, unloadModels: { await calls.append("unload-mlx") },
              stopRuntime: { await calls.append("stop-mlx") }, isCritical: isCritical)
    }
}

private actor CascadeResourceCalls {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
    func reset() { values = [] }
}

private actor CascadeResourceBarrier {
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        observer?.resume(); observer = nil
        await withCheckedContinuation { waiter = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { observer = $0 }
    }
    func open() { waiter?.resume(); waiter = nil }
}
