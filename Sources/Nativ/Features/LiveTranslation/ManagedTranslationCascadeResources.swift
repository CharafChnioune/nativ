import Foundation
import NativTranslationKit

/// This is an explicit scheduling choice; it never changes a selected model or precision.
enum TranslationCascadeMemoryStrategy: String, Codable, CaseIterable, Sendable {
    case sequential
    case resident
}

/// Serializes model ownership across turns, including cancellation and reentrant session starts.
actor ManagedTranslationCascadeResources: TranslationCascadeResources {
    private let strategy: TranslationCascadeMemoryStrategy
    private let prepareSpeech: @Sendable () async throws -> Void
    private let stopSpeech: @Sendable () async -> Void
    private let unloadModels: @Sendable () async throws -> Void
    private let stopRuntime: @Sendable () async -> Void
    private let isCritical: @Sendable () -> Bool
    private var generation: UUID?
    private var pendingBegin: (id: UUID, generation: UUID)?
    private var lease: TranslationCascadeLease?
    private var admission: Task<Void, Error>?
    private var releaseOperation: Task<Void, Never>?
    private var cleanup: (id: UUID, task: Task<Void, Never>)?

    var pendingGeneration: UUID? { pendingBegin?.generation }

    init(runtime: TranslationCascadeRuntime, strategy: TranslationCascadeMemoryStrategy,
         prepareSpeech: @escaping @Sendable () async throws -> Void = {},
         stopSpeech: @escaping @Sendable () async -> Void = {}) {
        self.strategy = strategy
        self.prepareSpeech = prepareSpeech
        self.stopSpeech = stopSpeech
        unloadModels = { try await runtime.unloadModels() }
        stopRuntime = { await runtime.stop() }
        isCritical = { TranslationHardwareSnapshot.current().pressure == .critical }
    }

    /// Injectable ownership actions let tests prove cancellation without allocating model weights.
    init(strategy: TranslationCascadeMemoryStrategy,
         prepareSpeech: @escaping @Sendable () async throws -> Void,
         stopSpeech: @escaping @Sendable () async -> Void,
         unloadModels: @escaping @Sendable () async throws -> Void,
         stopRuntime: @escaping @Sendable () async -> Void,
         isCritical: @escaping @Sendable () -> Bool = { false }) {
        self.strategy = strategy
        self.prepareSpeech = prepareSpeech
        self.stopSpeech = stopSpeech
        self.unloadModels = unloadModels
        self.stopRuntime = stopRuntime
        self.isCritical = isCritical
    }

    func begin(generation next: UUID) async throws {
        try Task.checkCancellation()
        let request = UUID()
        pendingBegin = (request, next)
        do {
            if let previous = generation, previous != next { await invalidate(generation: previous) }
            if let cleanup { await cleanup.task.value }
            try Task.checkCancellation()
            // Stop may arrive before this generation becomes active. It must cancel its pending begin too.
            guard pendingBegin?.id == request else { throw CancellationError() }
            generation = next
            pendingBegin = nil
        } catch {
            if pendingBegin?.id == request { pendingBegin = nil }
            throw error
        }
    }

    func acquire(_ stage: TranslationCascadeStage, generation expected: UUID) async throws -> TranslationCascadeLease {
        try Task.checkCancellation()
        guard generation == expected else { throw CancellationError() }
        guard lease == nil else {
            throw TranslationFailure(code: .invalidState, message: "A previous cascade stage has not released its model yet.")
        }
        guard !isCritical() else {
            throw TranslationFailure(code: .providerFailure, message: "macOS reports critical memory pressure. Free other model workloads, then Resume.")
        }
        let admitted = TranslationCascadeLease(generation: expected, stage: stage)
        lease = admitted
        let task = Task { [strategy, prepareSpeech, stopSpeech] in
            if stage == .speech { try await prepareSpeech() }
            else if strategy == .sequential { await stopSpeech() }
            try Task.checkCancellation()
        }
        admission = task
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
                Task { await self.invalidate(generation: expected) }
            }
            guard generation == expected, lease == admitted else { throw CancellationError() }
            admission = nil
            return admitted
        } catch {
            if generation == expected { await invalidate(generation: expected) }
            throw error
        }
    }

    func release(_ released: TranslationCascadeLease) async {
        guard generation == released.generation, lease == released else { return }
        if let releaseOperation { await releaseOperation.value; return }
        guard strategy == .sequential else { lease = nil; return }
        let task = Task { [unloadModels, stopRuntime, stopSpeech] in
            // If release cannot be confirmed, a process teardown guarantees the next model is isolated.
            do { try await unloadModels() } catch { await stopRuntime() }
            if released.stage == .speech { await stopSpeech() }
        }
        releaseOperation = task
        await task.value
        guard generation == released.generation, lease == released else { return }
        releaseOperation = nil
        lease = nil
    }

    func invalidate(generation invalidated: UUID) async {
        let cancelledBegin = pendingBegin?.generation == invalidated
        if cancelledBegin { pendingBegin = nil }
        guard generation == invalidated else {
            if cancelledBegin, let cleanup { await cleanup.task.value }
            return
        }
        generation = nil
        lease = nil
        admission?.cancel()
        let pendingAdmission = admission
        admission = nil
        let pendingRelease = releaseOperation
        releaseOperation = nil
        let id = UUID()
        let task = Task { [stopRuntime, stopSpeech] in
            // Cancellation closes the owned workers immediately; then drain earlier ownership actions.
            async let mlx: Void = stopRuntime()
            async let speech: Void = stopSpeech()
            _ = try? await pendingAdmission?.value
            await pendingRelease?.value
            await mlx
            await speech
        }
        cleanup = (id, task)
        await task.value
        if cleanup?.id == id { cleanup = nil }
    }
}
