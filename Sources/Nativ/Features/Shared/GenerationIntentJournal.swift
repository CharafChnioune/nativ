import Foundation
import NativServerKit

/// Durable native intent, written before POST. Contains no credentials or provider URLs.
struct GenerationSubmissionIntent: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let storeID: String
    let connectionID: String
    let modality: String
    let idempotencyKey: String
    let request: Data
    let createdAt: Date
    var jobID: String?
    var rejection: String? = nil
}

enum GenerationJournalError: LocalizedError {
    case identityMismatch, corruptJournal, submissionRejected(String)
    var errorDescription: String? {
        switch self {
        case .identityMismatch: "This request belongs to a different server store. Reconnect to its original server to recover it."
        case .corruptJournal: "Saved generation requests could not be read. The journal has been preserved for recovery."
        case .submissionRejected(let reason): "This saved request was rejected: \(reason) Review the request and explicitly start a new generation. It will not be retried automatically."
        }
    }
}

/// One app-scoped writer. A failed write must prevent the associated network mutation.
actor GenerationIntentJournal {
    static let shared = GenerationIntentJournal(url: GenerationPersistence.directory.appendingPathComponent("submission-intents.json"))
    private let url: URL
    private var intents: [GenerationSubmissionIntent]?
    init(url: URL) { self.url = url }

    func freeze(id: String, storeID: String, connectionID: String, modality: String, request: Data) throws -> GenerationSubmissionIntent {
        var entries = try read()
        if let existing = entries.first(where: { $0.id == id }) {
            guard existing.storeID == storeID, existing.connectionID == connectionID,
                  existing.modality == modality, existing.request == request else { throw GenerationJournalError.identityMismatch }
            if let rejection = existing.rejection { throw GenerationJournalError.submissionRejected(rejection) }
            return existing
        }
        let intent = GenerationSubmissionIntent(id: id, storeID: storeID, connectionID: connectionID,
            modality: modality, idempotencyKey: UUID().uuidString, request: request, createdAt: Date())
        entries.append(intent)
        try write(entries)
        return intent
    }

    func acknowledge(id: String, storeID: String, jobID: String) throws {
        var entries = try read()
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].storeID == storeID else {
            throw GenerationJournalError.identityMismatch
        }
        entries[index].jobID = jobID
        entries[index].rejection = nil
        try write(entries)
    }

    func intent(id: String) throws -> GenerationSubmissionIntent? { try read().first { $0.id == id } }

    func recordFailure(id: String, storeID: String, error: Error) throws {
        // Timeout, missing/oversized responses and 5xx may follow acceptance. Keep
        // their original identity pending; never turn retryability into acceptance.
        guard let failure = error as? GenerationAPIError, failure.jobID == nil,
              let status = failure.httpStatus, (400..<500).contains(status), status != 408 else { return }
        var entries = try read()
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].storeID == storeID else { throw GenerationJournalError.identityMismatch }
        guard entries[index].jobID == nil else { return }
        entries[index].rejection = failure.message
        try write(entries)
    }

    func rejectionNotice(storeID: String, connectionID: String, modality: String) throws -> String? {
        let matching = try read().filter { $0.storeID == storeID && $0.connectionID == connectionID && $0.modality == modality }
        guard let rejected = matching.last(where: { $0.rejection != nil }),
              !matching.contains(where: { $0.jobID != nil && $0.createdAt > rejected.createdAt }),
              let reason = rejected.rejection else { return nil }
        return GenerationJournalError.submissionRejected(reason).localizedDescription
    }

    func reconcile(storeID: String, connectionID: String, modality: String,
                   perform: @Sendable (GenerationSubmissionIntent) async throws -> String) async throws {
        var firstError: Error?
        for intent in try pending(storeID: storeID, connectionID: connectionID, modality: modality) {
            try Task.checkCancellation()
            do {
                let jobID = try await perform(intent)
                try acknowledge(id: intent.id, storeID: storeID, jobID: jobID)
            } catch {
                do { try recordFailure(id: intent.id, storeID: storeID, error: error) }
                catch { if firstError == nil { firstError = error } }
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    func pending(storeID: String, connectionID: String, modality: String) throws -> [GenerationSubmissionIntent] {
        try read().filter { $0.storeID == storeID && $0.connectionID == connectionID && $0.modality == modality && $0.jobID == nil && $0.rejection == nil }
    }

    private func read() throws -> [GenerationSubmissionIntent] {
        if let intents { return intents }
        guard FileManager.default.fileExists(atPath: url.path) else { intents = []; return [] }
        guard let decoded = try? JSONDecoder().decode([GenerationSubmissionIntent].self, from: Data(contentsOf: url)) else {
            throw GenerationJournalError.corruptJournal
        }
        intents = decoded
        return decoded
    }
    private func write(_ entries: [GenerationSubmissionIntent]) throws {
        try GenerationPersistence.write(entries, to: url)
        intents = entries
    }
}

enum GenerationPersistence {
    static var directory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent(NativBuildIdentity.applicationSupportDirectoryName).appendingPathComponent("Generation Client", isDirectory: true)
    }
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
