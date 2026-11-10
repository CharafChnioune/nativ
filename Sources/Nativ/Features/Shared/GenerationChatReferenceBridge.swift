import Combine
import Foundation
import NativServerKit

/// Repairs attachment and unlink directions after restart. Active conversations are never overwritten.
@MainActor
final class GenerationChatReferenceBridge {
    private let store: ChatSessionStore
    private let activity: InferenceActivityCoordinator
    private let changes: PersistedDataChangeHub
    private let origin = UUID()
    private var changeSubscription: AnyCancellable?
    private var chatRevision = 0
    private var observedRevisions: [String: Int] = [:]
    private var observedAssets: [String: Set<String>] = [:]
    private let outbox: GenerationReferenceOutbox
    init(store: ChatSessionStore = .init(), activity: InferenceActivityCoordinator, changes: PersistedDataChangeHub, outbox: GenerationReferenceOutbox = .shared) {
        self.store = store; self.activity = activity; self.changes = changes; self.outbox = outbox
        changeSubscription = changes.changes.sink { [weak self] _ in self?.chatRevision += 1 }
    }
    func reconcile(library: GenerationLibraryObserver) async throws {
        guard let connection = library.connection, let storeID = library.storeID else { return }
        let identity = storeID + ":" + library.modality.rawValue
        let actions = try await outbox.all(storeID: storeID).filter { $0.reference.modality == library.modality.rawValue }
        let assets = Set(library.jobs.compactMap(\.assetID))
        guard !assets.isEmpty || !actions.isEmpty else { return }
        guard actions.contains(where: { $0.phase != .live }) || observedRevisions[identity] != chatRevision || observedAssets[identity] != assets else { return }
        defer { observedRevisions[identity] = chatRevision; observedAssets[identity] = assets }
        let client = NativGenerationClient(modality: library.modality, connection: connection)
        var sessions = store.loadSessions()
        var savedIDs = Set(sessions.flatMap(\.messages).flatMap { $0.generationAssets + $0.imageAttachments.compactMap(\.serviceReference) }.compactMap(\.referenceID))
        for sessionIndex in sessions.indices {
            guard !activity.isActive(.chat(sessions[sessionIndex].id)) else { continue }
            for message in Array(sessions[sessionIndex].messages) {
                guard ChatGenerationToolRegistry.modality(for: message.toolName) == library.modality,
                      let reference = GenerationChatJobReference.parse(message.content), reference.storeID == storeID,
                      let job = library.jobs.first(where: { $0.jobID == reference.jobID }),
                      let assetID = job.assetID, library.assets[assetID]?.trashed == false else { continue }
                let prefix = "chat:" + sessions[sessionIndex].id.uuidString + ":" + message.id.uuidString
                if savedIDs.contains(where: { $0.hasPrefix(prefix) }) { continue }
                let pending = try await outbox.all(storeID: storeID).first { $0.id.hasPrefix(prefix) && [.reserve, .awaitingLocalCommit, .finalize].contains($0.phase) }
                let id = pending?.id ?? prefix + ":" + UUID().uuidString
                if savedIDs.contains(id) { continue }
                let asset = library.assets[assetID]
                let service = GenerationServiceReference(storeID: storeID, assetID: assetID, jobID: job.jobID, sessionID: job.sessionID, modality: library.modality.rawValue, referenceID: id, filename: asset?.filename, mimeType: asset?.mimeType, byteSize: asset?.byteSize)
                let action = try await outbox.reserve(reference: service, ownerID: sessions[sessionIndex].id.uuidString, id: id)
                if action.phase == .unlink { continue }
                let owner: [String: GenerationJSONValue] = ["workspace": .string("chat"), "session_id": .string(sessions[sessionIndex].id.uuidString)]
                let reserved = try await client.putReference(assetID: assetID, referenceID: id, phase: "reserve", expectedRevision: action.revision, owner: owner)
                try await outbox.reserved(id: id, revision: Int(reserved["revision"]?.numberValue ?? 1))
                // Recheck after the await: a user may have deleted/edited the chat meanwhile.
                guard !activity.isActive(.chat(sessions[sessionIndex].id)), var latest = store.loadSessions().first(where: { $0.id == sessions[sessionIndex].id }),
                      let index = latest.messages.firstIndex(where: { $0.id == message.id && GenerationChatJobReference.parse($0.content) == reference }) else {
                    try await outbox.unlink(id: id); continue
                }
                latest.messages[index].generationAssets.append(service)
                guard store.saveSession(latest) else { throw GenerationAPIError(code: "chat_save_failed", message: "The chat media attachment could not be saved. Its reservation remains protected.", retryable: true) }
                sessions[sessionIndex] = latest; savedIDs.insert(id)
                try await outbox.localCommit(id: id)
                changes.send(.chatSession(latest.id), originWindowID: origin)
            }
        }
        // Local commit evidence settles reservations. Removed attachments queue a durable unlink.
        for action in try await outbox.all(storeID: storeID) where action.reference.modality == library.modality.rawValue && action.id.hasPrefix("chat:") {
            if savedIDs.contains(action.id), action.phase == .awaitingLocalCommit { try await outbox.localCommit(id: action.id) }
            else if !savedIDs.contains(action.id), (action.phase == .live || action.phase == .awaitingLocalCommit), !(await outbox.isCommitting(id: action.id)) { try await outbox.unlink(id: action.id) }
        }
    }
}
