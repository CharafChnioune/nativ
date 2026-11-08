import Combine
import Foundation
import NativServerKit

/// App-scoped projection. The canonical service remains the only owner of jobs and originals.
@MainActor
final class GenerationLibraryObserver: ObservableObject {
    let modality: GenerationModality
    @Published private(set) var jobs: [GenerationJob] = []
    @Published private(set) var sessions: [GenerationSession] = []
    @Published private(set) var profiles: [GenerationProfile] = []
    @Published private(set) var assets: [String: GenerationAsset] = [:]
    @Published private(set) var storeID: String?
    @Published private(set) var connection: GenerationConnection?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isConnected = false
    private var activeProfileID: String?
    private var observation: Task<Void, Never>?
    private var epoch = UUID()
    private var refreshing = false
    var chatReferences: GenerationChatReferenceBridge?
    typealias ClientFactory = @Sendable (GenerationModality, GenerationConnection) -> NativGenerationClient
    private let makeClient: ClientFactory
    private let journal: GenerationIntentJournal
    private let outbox: GenerationReferenceOutbox
    private var client: NativGenerationClient? { connection.map { makeClient(modality, $0) } }
    init(modality: GenerationModality, journal: GenerationIntentJournal = .shared, outbox: GenerationReferenceOutbox = .shared, makeClient: @escaping ClientFactory = { NativGenerationClient(modality: $0, connection: $1) }) {
        self.makeClient = makeClient
        self.modality = modality; self.journal = journal; self.outbox = outbox
    }
    var connectionID: String? { connection.map { (activeProfileID.map { $0 + ":" } ?? "") + $0.baseURL.absoluteString } }
    func connect(_ newConnection: GenerationConnection?, profileID: String? = nil) {
        if newConnection == nil, let profileID, profileID == activeProfileID, connection != nil {
            observation?.cancel(); epoch = UUID(); isConnected = false
            GenerationToolAvailability.shared.set(modality, ready: false)
            errorMessage = "Server is stopped. Cached originals remain available."
            return
        }
        if let connection, let newConnection, activeProfileID == profileID, isConnected, connection.baseURL == newConnection.baseURL, connection.apiKey == newConnection.apiKey { return }
        if connection == nil, newConnection == nil { return }
        observation?.cancel(); epoch = UUID()
        GenerationToolAvailability.shared.set(modality, ready: false)
        activeProfileID = profileID; isConnected = false
        connection = newConnection; storeID = nil; jobs = []; sessions = []; profiles = []; assets = [:]; errorMessage = nil
        guard let newConnection else { return }
        if let cachedIdentityURL, let data = try? Data(contentsOf: cachedIdentityURL), let cached = try? JSONDecoder().decode(String.self, from: data) {
            storeID = cached; connection = newConnection.bound(to: cached); loadSnapshot()
        }
        let token = epoch
        observation = Task { [weak self] in
            guard let self else { return }
            do {
                let info = try await waitForServer(connection: newConnection, epoch: token)
                guard epoch == token else { return }
                if storeID != info.storeID { jobs = []; sessions = []; assets = [:] }
                storeID = info.storeID; connection = newConnection.bound(to: info.storeID); isConnected = true
                if let cachedIdentityURL { try? GenerationPersistence.write(info.storeID, to: cachedIdentityURL) }
                loadSnapshot()
                do { try await reconcileIntents() } catch { errorMessage = error.localizedDescription }
                while !Task.isCancelled, epoch == token {
                    await refresh()
                    try await Task.sleep(for: .seconds(1))
                }
            } catch is CancellationError {} catch { if epoch == token { errorMessage = error.localizedDescription } }
        }
    }
    private func waitForServer(connection: GenerationConnection, epoch token: UUID) async throws -> GenerationInfo {
        while !Task.isCancelled, epoch == token {
            do { return try await makeClient(modality, connection).info() }
            catch let error as GenerationAPIError where !error.retryable { throw error }
            catch {
                guard epoch == token else { throw CancellationError() }
                errorMessage = error.localizedDescription
                try await Task.sleep(for: .seconds(2))
            }
        }
        throw CancellationError()
    }
    func reconnect() {
        guard let connection else { return }
        let unbound = GenerationConnection(baseURL: connection.baseURL, apiKey: connection.apiKey, allowPrivateHTTP: connection.allowPrivateHTTP)
        let profile = activeProfileID
        connect(nil); connect(unbound, profileID: profile)
    }
    func refresh() async {
        guard !refreshing, let client, let storeID else { return }
        refreshing = true; isRefreshing = true
        let token = epoch
        defer { refreshing = false; isRefreshing = false }
        do {
            _ = try await client.info()
            async let catalog = client.models()
            var listed: [GenerationJob] = [], cursor: String?
            repeat {
                let page = try await client.jobs(cursor: cursor); listed += page.items; cursor = page.nextCursor
            } while cursor != nil && listed.count < 10_000
            var history: [GenerationSession] = []; cursor = nil
            repeat {
                let page = try await client.sessions(cursor: cursor); history += page.items; cursor = page.nextCursor
            } while cursor != nil && history.count < 10_000
            let models = try await catalog
            guard epoch == token, connection?.storeID == storeID else { return }
            isConnected = true
            jobs = listed.filter { $0.storeID == storeID }; sessions = history.filter { $0.storeID == storeID }; profiles = models
            GenerationToolAvailability.shared.set(modality, ready: models.contains { $0.readiness == "ready" })
            var observedAssets: [String: GenerationAsset] = [:]
            for job in jobs {
                guard let id = job.assetID else { continue }
                if let asset = try? await client.asset(id: id), epoch == token, asset.storeID == storeID { observedAssets[id] = asset }
                else if let cached = assets[id] { observedAssets[id] = cached }
            }
            guard epoch == token else { return }
            assets = observedAssets
            errorMessage = try await journal.rejectionNotice(storeID: storeID, connectionID: connectionID ?? "", modality: modality.rawValue)
            do { try await chatReferences?.reconcile(library: self); try await reconcileReferences() }
            catch { errorMessage = error.localizedDescription }
            guard epoch == token else { return }
            saveSnapshot()
        } catch { if epoch == token { isConnected = false; GenerationToolAvailability.shared.set(modality, ready: false); errorMessage = error.localizedDescription } }
    }
    func submit(_ request: [String: GenerationJSONValue], intentID: String) async throws -> GenerationJob {
        guard isConnected, let client, let storeID, let connectionID else { throw GenerationAPIError(code: "not_connected", message: "Start the server and connect to its media library first.") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let intent = try await journal.freeze(id: intentID, storeID: storeID, connectionID: connectionID, modality: modality.rawValue, request: encoder.encode(request))
        if let id = intent.jobID { return try await client.job(id: id) }
        let job: GenerationJob
        do { job = try await client.submit(request, idempotencyKey: intent.idempotencyKey) }
        catch {
            try await journal.recordFailure(id: intent.id, storeID: storeID, error: error)
            throw error
        }
        guard job.storeID == storeID else { throw GenerationJournalError.identityMismatch }
        try await journal.acknowledge(id: intent.id, storeID: storeID, jobID: job.jobID)
        await refresh(); return job
    }
    func mutate(job: GenerationJob, action: String) async throws {
        guard let client, job.storeID == storeID else { throw GenerationJournalError.identityMismatch }
        switch action {
        case "cancel": _ = try await client.cancel(jobID: job.jobID)
        case "resume": _ = try await client.resume(jobID: job.jobID)
        case "retry-download": _ = try await client.retryDownload(jobID: job.jobID)
        case "release": _ = try await client.releaseRemoteReservation(jobID: job.jobID, acknowledgePossibleExecutionAndCharges: true)
        default: return
        }
        await refresh()
    }
    func mediaURL(asset: GenerationAsset) async throws -> URL {
        guard let client, asset.storeID == storeID else { throw GenerationJournalError.identityMismatch }
        return try await GenerationMediaCache.shared.acquire(asset: asset, client: client)
    }
    func updateSession(_ id: String, title: String? = nil, hidden: Bool? = nil) async throws {
        guard let client else { throw GenerationJournalError.identityMismatch }
        _ = try await client.updateSession(id: id, title: title, hidden: hidden); await refresh()
    }
    func trash(asset: GenerationAsset) async throws {
        guard let client, asset.storeID == storeID else { throw GenerationJournalError.identityMismatch }
        assets[asset.assetID] = try await client.trash(assetID: asset.assetID); saveSnapshot()
    }
    func removeSessionUsageAndTrash(job: GenerationJob) async throws {
        guard let client, job.storeID == storeID, let assetID = job.assetID else { throw GenerationJournalError.identityMismatch }
        let usages = try await client.usages(assetID: assetID)
        let id = "session:" + job.sessionID
        if let usage = usages["items"]?.arrayValue?.compactMap(\.objectValue).first(where: { $0["id"]?.stringValue == id }), let revision = usage["revision"]?.numberValue {
            let reference = GenerationServiceReference(storeID: job.storeID, assetID: assetID, jobID: job.jobID, sessionID: job.sessionID, modality: modality.rawValue)
            try await outbox.queueUnlink(reference: reference, id: id, revision: Int(revision))
            try await reconcileReferences()
        }
        assets[assetID] = try await client.trash(assetID: assetID)
        saveSnapshot()
    }
    func restore(asset: GenerationAsset) async throws {
        guard let client, asset.storeID == storeID else { throw GenerationJournalError.identityMismatch }
        assets[asset.assetID] = try await client.restore(assetID: asset.assetID); saveSnapshot()
    }
    private func reconcileIntents() async throws {
        guard let client, let storeID, let connectionID else { return }
        try await journal.reconcile(storeID: storeID, connectionID: connectionID, modality: modality.rawValue) { intent in
            let request = try JSONDecoder().decode([String: GenerationJSONValue].self, from: intent.request)
            let job = try await client.submit(request, idempotencyKey: intent.idempotencyKey)
            guard job.storeID == storeID else { throw GenerationJournalError.identityMismatch }
            return job.jobID
        }
    }
    func reconcileReferences() async throws {
        guard let client, let storeID else { return }
        for action in try await outbox.pending(storeID: storeID) where action.reference.modality == modality.rawValue {
            switch action.phase {
            case .reserve:
                let result = try await client.putReference(assetID: action.reference.assetID, referenceID: action.remoteID, phase: "reserve", expectedRevision: action.revision, owner: ["workspace": .string("chat"), "session_id": .string(action.ownerID)])
                try await outbox.reserved(id: action.id, revision: Int(result["revision"]?.numberValue ?? 1), localCommitInProgress: false)
            case .finalize:
                let result = try await client.putReference(assetID: action.reference.assetID, referenceID: action.remoteID, phase: "finalize", expectedRevision: action.revision, owner: ["workspace": .string("chat"), "session_id": .string(action.ownerID)])
                try await outbox.acknowledge(id: action.id, phase: .finalize, revision: result["revision"]?.numberValue.map(Int.init))
            case .unlink:
                _ = try await client.deleteReference(assetID: action.reference.assetID, referenceID: action.remoteID, expectedRevision: action.revision)
                try await outbox.acknowledge(id: action.id, phase: .unlink)
            case .awaitingLocalCommit, .live: break
            }
        }
    }
    private struct Snapshot: Codable { let jobs: [GenerationJob]; let sessions: [GenerationSession]; let assets: [String: GenerationAsset] }
    private var cachedIdentityURL: URL? { connectionID.map { GenerationPersistence.directory.appendingPathComponent("connection-" + GenerationMediaCache.key($0) + ".json") } }
    private var snapshotURL: URL? { storeID.map { GenerationPersistence.directory.appendingPathComponent(GenerationMediaCache.key($0) + "-" + modality.rawValue + ".json") } }
    private func saveSnapshot() {
        guard let snapshotURL else { return }
        try? GenerationPersistence.write(Snapshot(jobs: jobs, sessions: sessions, assets: assets), to: snapshotURL)
    }
    private func loadSnapshot() {
        guard let snapshotURL, let data = try? Data(contentsOf: snapshotURL), let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        jobs = snapshot.jobs.filter { $0.storeID == storeID }; sessions = snapshot.sessions.filter { $0.storeID == storeID }; assets = snapshot.assets.filter { $0.value.storeID == storeID }
    }
}
