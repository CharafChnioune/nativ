import Foundation

struct AudioSessionOwner: Hashable, Sendable {
    let id: UUID
    let name: String
    init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
}

enum AudioSessionResource: Hashable, Sendable { case microphone, systemAudio, playback }
struct AudioSessionLease: Hashable, Sendable {
    let id: UUID
    let owner: AudioSessionOwner
    let resources: Set<AudioSessionResource>
    let passive: Bool
}
struct AudioSessionConflict: LocalizedError {
    let ownerName: String
    var errorDescription: String? { "Audio is in use by \(ownerName). Stop that activity before starting another recording or playback." }
}

/// App-scoped foreground ownership. All mutation and passive-listener handoff run on MainActor.
/// A lease covers preparation/startup until the owner has awaited real device teardown.
@MainActor
final class AudioSessionCoordinator {
    static let shared = AudioSessionCoordinator()
    private var leases: [UUID: AudioSessionLease] = [:]
    private var mediaPauses: [UUID: @MainActor () async -> Void] = [:]
    private var mediaTeardowns: [UUID: Task<Void, Never>] = [:]
    private var passiveSuspend: (@MainActor () async -> Void)?
    private var passiveResume: (@MainActor () -> Void)?
    private var passiveIsSuspended = false
    private var passiveTeardown: Task<Void, Never>?
    private var passiveTeardownID: UUID?

    var hasForegroundActivity: Bool { leases.values.contains { !$0.passive } }

    func registerPassiveListener(suspend: @escaping @MainActor () async -> Void, resume: @escaping @MainActor () -> Void) {
        passiveSuspend = suspend
        passiveResume = resume
    }

    /// Media is interruptible; recording/translation leases retain their existing strict ownership.
    func acquireInterruptiblePlayback(owner: AudioSessionOwner, pause: @escaping @MainActor () async -> Void) async throws -> AudioSessionLease {
        let lease = try await acquire(owner: owner, resources: [.playback])
        mediaPauses[lease.id] = pause
        return lease
    }

    func acquire(owner: AudioSessionOwner, resources: Set<AudioSessionResource>, passive: Bool = false) async throws -> AudioSessionLease {
        try Task.checkCancellation()
        let lease = AudioSessionLease(id: UUID(), owner: owner, resources: resources, passive: passive)
        // Foreground resources conflict across owners, even mic vs speech playback, to prevent feedback.
        if let conflict = leases.values.first(where: {
            (passive || mediaPauses[$0.id] == nil) && (!$0.passive || passive) && ($0.owner != owner || !$0.resources.isDisjoint(with: resources))
        }) { throw AudioSessionConflict(ownerName: conflict.owner.name) }
        let passiveLeases = leases.values.filter(\.passive)
        if !passive, !passiveLeases.isEmpty, passiveSuspend == nil {
            throw AudioSessionConflict(ownerName: passiveLeases[0].owner.name)
        }
        // Reserve before suspending so reentrant foreground requests cannot both win.
        leases[lease.id] = lease
        if !passive {
            let interruptible = leases.values.filter { $0.id != lease.id && mediaPauses[$0.id] != nil }
            for old in interruptible {
                leases[old.id] = nil
                if let pause = mediaPauses.removeValue(forKey: old.id) {
                    mediaTeardowns[old.id] = Task { await pause() }
                }
            }
            let barriers = mediaTeardowns
            for (id, barrier) in barriers {
                await barrier.value
                mediaTeardowns[id] = nil
            }
        }
        if !passive, !passiveIsSuspended {
            passiveIsSuspended = true
            for old in passiveLeases { leases[old.id] = nil }
            if !passiveLeases.isEmpty {
                let suspend = passiveSuspend
                passiveTeardownID = UUID()
                passiveTeardown = Task { await suspend?() }
            }
        }
        // A reentrant acquisition for a disjoint resource by this same owner must
        // await the same physical teardown, not just observe the suspension flag.
        if !passive, let pending = passiveTeardown {
            let id = passiveTeardownID
            await pending.value
            if passiveTeardownID == id {
                passiveTeardown = nil; passiveTeardownID = nil
            }
        }
        do { try Task.checkCancellation() }
        catch { release(lease); throw error }
        return lease
    }

    func isActive(_ lease: AudioSessionLease) -> Bool { leases[lease.id] == lease }

    func release(_ lease: AudioSessionLease) {
        guard leases[lease.id] == lease else { return }
        leases[lease.id] = nil
        mediaPauses[lease.id] = nil
        if passiveIsSuspended, !leases.values.contains(where: { !$0.passive }) {
            passiveIsSuspended = false
            passiveResume?()
        }
    }
}
