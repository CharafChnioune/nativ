import Foundation

struct GenerationServiceReference: Codable, Equatable, Hashable, Sendable {
    let storeID: String
    let assetID: String
    let jobID: String
    let sessionID: String
    let modality: String
    var referenceID: String? = nil
    var filename: String? = nil
    var mimeType: String? = nil
    var byteSize: Int64? = nil
}

struct GenerationReferenceAction: Codable, Equatable, Identifiable, Sendable {
    enum Phase: String, Codable, Sendable { case reserve, awaitingLocalCommit, finalize, live, unlink }
    let id: String
    let reference: GenerationServiceReference
    let ownerID: String
    var phase: Phase
    var revision: Int
    var serverReferenceID: String? = nil
    var remoteID: String { serverReferenceID ?? id }
}

/// Reference reservation precedes the local save. A durable unlink supersedes every late finalize.
actor GenerationReferenceOutbox {
    static let shared = GenerationReferenceOutbox(url: GenerationPersistence.directory.appendingPathComponent("reference-outbox.json"))
    private let url: URL
    private var inFlightLocal: Set<String> = []
    private var entries: [GenerationReferenceAction]?
    init(url: URL) { self.url = url }
    func reserve(reference: GenerationServiceReference, ownerID: String, id: String = UUID().uuidString) throws -> GenerationReferenceAction {
        var actions = try read()
        if let old = actions.first(where: { $0.id == id }) { return old }
        let action = GenerationReferenceAction(id: id, reference: reference, ownerID: ownerID, phase: .reserve, revision: 0)
        actions.append(action)
        try save(actions)
        return action
    }
    func reserved(id: String, revision: Int, localCommitInProgress: Bool = true) throws { try update(id) { action in
        action.revision = max(action.revision, revision)
        guard action.phase == .reserve else { return }
        action.phase = .awaitingLocalCommit
        if localCommitInProgress { inFlightLocal.insert(id) }
    } }
    func localCommit(id: String) throws { inFlightLocal.remove(id); try update(id) { action in
        guard action.phase == .awaitingLocalCommit else { return }
        action.phase = .finalize
    } }
    func isCommitting(id: String) -> Bool { inFlightLocal.contains(id) }
    func unlink(id: String) throws { inFlightLocal.remove(id); try update(id) { action in action.phase = .unlink } }
    func acknowledge(id: String, phase: GenerationReferenceAction.Phase, revision: Int? = nil) throws {
        var actions = try read()
        // A finalize response racing an unlink updates its revision but never removes the unlink.
        if let revision, let index = actions.firstIndex(where: { $0.id == id }) {
            actions[index].revision = max(actions[index].revision, revision - (phase == .finalize && actions[index].phase == .finalize ? 1 : 0))
        }
        if phase == .finalize, let index = actions.firstIndex(where: { $0.id == id && $0.phase == .finalize }) {
            actions[index].phase = .live; actions[index].revision += 1
        }
        actions.removeAll { $0.id == id && $0.phase == phase && phase == .unlink }
        try save(actions)
    }
    func pending(storeID: String) throws -> [GenerationReferenceAction] { try read().filter { $0.reference.storeID == storeID && $0.phase != .live } }
    func all(storeID: String) throws -> [GenerationReferenceAction] { try read().filter { $0.reference.storeID == storeID } }
    func queueUnlink(reference: GenerationServiceReference, id: String, revision: Int) throws {
        var actions = try read()
        let operationID = "unlink:" + reference.storeID + ":" + reference.assetID + ":" + id
        if let index = actions.firstIndex(where: { $0.id == operationID }) { actions[index].phase = .unlink; actions[index].revision = revision }
        else { actions.append(.init(id: operationID, reference: reference, ownerID: reference.sessionID, phase: .unlink, revision: revision, serverReferenceID: id)) }
        try save(actions)
    }
    private func update(_ id: String, _ block: (inout GenerationReferenceAction) -> Void) throws {
        var actions = try read()
        guard let index = actions.firstIndex(where: { $0.id == id }) else { return }
        block(&actions[index]); try save(actions)
    }
    private func read() throws -> [GenerationReferenceAction] {
        if let entries { return entries }
        guard FileManager.default.fileExists(atPath: url.path) else { entries = []; return [] }
        let loaded = try JSONDecoder().decode([GenerationReferenceAction].self, from: Data(contentsOf: url))
        entries = loaded; return loaded
    }
    private func save(_ actions: [GenerationReferenceAction]) throws {
        try GenerationPersistence.write(actions, to: url); entries = actions
    }
}
