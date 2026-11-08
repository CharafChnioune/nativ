import Foundation
import NativServerKit
import XCTest

final class GenerationPersistenceTests: XCTestCase {
    private func location() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("journal.json") }
    func testLostAcknowledgmentReusesSavedKeyAcrossRelaunchAndRejectsReplacedStore() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let request = Data(#"{"model":"configured","prompt":"original"}"#.utf8)
        let first = try await GenerationIntentJournal(url: url).freeze(id: "tool-call", storeID: "store-a", connectionID: "https://server", modality: "music", request: request)
        let relaunched = GenerationIntentJournal(url: url)
        let recovered = try await relaunched.freeze(id: "tool-call", storeID: "store-a", connectionID: "https://server", modality: "music", request: request)
        XCTAssertEqual(first.idempotencyKey, recovered.idempotencyKey)
        do {
            _ = try await relaunched.freeze(id: "tool-call", storeID: "store-b", connectionID: "https://server", modality: "music", request: request)
            XCTFail("A replaced server store cannot receive an old intent")
        } catch GenerationJournalError.identityMismatch {}
        try await relaunched.acknowledge(id: "tool-call", storeID: "store-a", jobID: "one-job")
        let pending = try await relaunched.pending(storeID: "store-a", connectionID: "https://server", modality: "music")
        XCTAssertTrue(pending.isEmpty)
    }
    func testCorruptJournalDoesNotInventFreshIntent() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: url)
        do {
            _ = try await GenerationIntentJournal(url: url).freeze(id: "original", storeID: "a", connectionID: "b", modality: "video", request: Data())
            XCTFail("Corruption must fail closed before submission")
        } catch GenerationJournalError.corruptJournal {}
        XCTAssertEqual(try Data(contentsOf: url), Data("invalid".utf8))
    }
    func testDefinitiveRejectionSurvivesRelaunchAndDoesNotBlockOtherPendingIntent() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = GenerationIntentJournal(url: url)
        let request = Data(#"{"model":"configured","prompt":"original"}"#.utf8)
        for id in ["queue-rejected", "invalid", "uncertain"] {
            _ = try await journal.freeze(id: id, storeID: "store", connectionID: "server", modality: "music", request: request)
        }
        try await journal.recordFailure(id: "queue-rejected", storeID: "store", error: GenerationAPIError(code: "queue_full", message: "Queue full", retryable: true, httpStatus: 429))
        try await journal.recordFailure(id: "invalid", storeID: "store", error: GenerationAPIError(code: "invalid_request", message: "Invalid request", httpStatus: 422))
        let relaunched = GenerationIntentJournal(url: url)
        let pending = try await relaunched.pending(storeID: "store", connectionID: "server", modality: "music")
        XCTAssertEqual(pending.map(\.id), ["uncertain"])
        do {
            _ = try await relaunched.freeze(id: "queue-rejected", storeID: "store", connectionID: "server", modality: "music", request: request)
            XCTFail("An explicit rejection must require a newly authorized intent")
        } catch GenerationJournalError.submissionRejected {}
        do {
            _ = try await relaunched.freeze(id: "queue-rejected", storeID: "replacement", connectionID: "server", modality: "music", request: request)
            XCTFail("Rejected intents must still remain bound to their original store")
        } catch GenerationJournalError.identityMismatch {}
    }
    func testAmbiguousFailuresKeepOriginalIdentityForRecovery() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = GenerationIntentJournal(url: url)
        let request = Data("{}".utf8)
        let errors: [Error] = [URLError(.timedOut), GenerationAPIError(code: "http_error", message: "Timeout", httpStatus: 408), GenerationAPIError(code: "http_error", message: "Unavailable", httpStatus: 503), GenerationAPIError(code: "response_too_large", message: "Invalid response")]
        var originalKeys: [String: String] = [:]
        for (index, error) in errors.enumerated() {
            let id = String(index)
            let intent = try await journal.freeze(id: id, storeID: "store", connectionID: "server", modality: "video", request: request)
            originalKeys[id] = intent.idempotencyKey
            try await journal.recordFailure(id: id, storeID: "store", error: error)
        }
        let recovered = try await GenerationIntentJournal(url: url).pending(storeID: "store", connectionID: "server", modality: "video")
        XCTAssertEqual(recovered.count, errors.count)
        for intent in recovered { XCTAssertEqual(intent.idempotencyKey, originalKeys[intent.id]) }
    }
    func testRecoveryContinuesPastRejectedIntentAndKeepsRejectionVisible() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = GenerationIntentJournal(url: url)
        // The rejected request is newer, so recovering an older acknowledgment
        // cannot silently dismiss the user's outstanding rejection notice.
        for id in ["recoverable", "rejected"] {
            _ = try await journal.freeze(id: id, storeID: "store", connectionID: "server", modality: "music", request: Data("{}".utf8))
        }
        do {
            try await journal.reconcile(storeID: "store", connectionID: "server", modality: "music") { intent in
                if intent.id == "rejected" { throw GenerationAPIError(code: "invalid_request", message: "Unsupported duration", httpStatus: 422) }
                return "recovered-job"
            }
            XCTFail("Recovery must report the rejected request")
        } catch let error as GenerationAPIError { XCTAssertEqual(error.httpStatus, 422) }
        let recovered = try await journal.intent(id: "recoverable")
        XCTAssertEqual(recovered?.jobID, "recovered-job")
        let relaunched = GenerationIntentJournal(url: url)
        let pending = try await relaunched.pending(storeID: "store", connectionID: "server", modality: "music")
        XCTAssertTrue(pending.isEmpty)
        let notice = try await relaunched.rejectionNotice(storeID: "store", connectionID: "server", modality: "music")
        XCTAssertTrue(notice?.contains("Unsupported duration") == true)
        XCTAssertTrue(notice?.contains("explicitly start a new generation") == true)
    }
    func testOneRecoveryRejectionDoesNotSkipLaterUnknownSubmission() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = GenerationIntentJournal(url: url)
        for id in ["rejected", "recoverable"] {
            _ = try await journal.freeze(id: id, storeID: "store", connectionID: "server", modality: "video", request: Data("{}".utf8))
        }
        do {
            try await journal.reconcile(storeID: "store", connectionID: "server", modality: "video") { intent in
                if intent.id == "rejected" { throw GenerationAPIError(code: "queue_full", message: "Queue full", retryable: true, httpStatus: 429) }
                return "existing-job"
            }
            XCTFail("Expected the first request's error")
        } catch let error as GenerationAPIError { XCTAssertEqual(error.code, "queue_full") }
        let recovered = try await journal.intent(id: "recoverable")
        XCTAssertEqual(recovered?.jobID, "existing-job")
    }
    func testLegacyJournalAndAcceptedJobRemainRecoverable() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"[{"id":"legacy","storeID":"store","connectionID":"server","modality":"music","idempotencyKey":"saved-key","request":"e30=","createdAt":0}]"#.utf8).write(to: url)
        let journal = GenerationIntentJournal(url: url)
        let pending = try await journal.pending(storeID: "store", connectionID: "server", modality: "music")
        XCTAssertEqual(pending.first?.idempotencyKey, "saved-key")
        try await journal.acknowledge(id: "legacy", storeID: "store", jobID: "accepted")
        try await journal.recordFailure(id: "legacy", storeID: "store", error: GenerationAPIError(code: "idempotency_conflict", message: "Late failure", httpStatus: 409))
        let accepted = try await journal.freeze(id: "legacy", storeID: "store", connectionID: "server", modality: "music", request: Data("{}".utf8))
        XCTAssertEqual(accepted.jobID, "accepted")
    }
    func testUnlinkRacingReserveKeepsReceiptRevisionWithoutResurrectingAttachment() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let outbox = GenerationReferenceOutbox(url: url)
        let reference = GenerationServiceReference(storeID: "a", assetID: "asset", jobID: "job", sessionID: "session", modality: "video")
        _ = try await outbox.reserve(reference: reference, ownerID: "chat", id: "reference")
        try await outbox.unlink(id: "reference")
        try await outbox.reserved(id: "reference", revision: 1)
        let actions = try await outbox.pending(storeID: "a")
        XCTAssertEqual(actions.first?.phase, .unlink)
        XCTAssertEqual(actions.first?.revision, 1)
        let committing = await outbox.isCommitting(id: "reference")
        XCTAssertFalse(committing)
    }
    func testConcurrentSessionUnlinksAreNamespacedByStoreAndAsset() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let outbox = GenerationReferenceOutbox(url: url)
        for asset in ["first", "second"] {
            let reference = GenerationServiceReference(storeID: "store", assetID: asset, jobID: asset, sessionID: "shared-session", modality: "music")
            try await outbox.queueUnlink(reference: reference, id: "session:shared-session", revision: 1)
        }
        let pending = try await outbox.pending(storeID: "store")
        XCTAssertEqual(pending.count, 2)
        XCTAssertEqual(Set(pending.map { $0.reference.assetID }), ["first", "second"])
    }
    func testUnlinkSurvivesRestartAndLateFinalizeAcknowledgment() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let reference = GenerationServiceReference(storeID: "a", assetID: "asset", jobID: "job", sessionID: "session", modality: "video")
        let outbox = GenerationReferenceOutbox(url: url)
        _ = try await outbox.reserve(reference: reference, ownerID: "chat", id: "reference")
        try await outbox.reserved(id: "reference", revision: 1)
        try await outbox.localCommit(id: "reference")
        try await outbox.unlink(id: "reference")
        try await outbox.acknowledge(id: "reference", phase: .finalize)
        let recovered = try await GenerationReferenceOutbox(url: url).pending(storeID: "a")
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered.first?.phase, .unlink)
        try await outbox.localCommit(id: "reference")
        let pending = try await outbox.pending(storeID: "a")
        XCTAssertEqual(pending.first?.phase, .unlink)
        try await outbox.acknowledge(id: "reference", phase: .unlink)
        let remaining = try await outbox.pending(storeID: "a")
        XCTAssertTrue(remaining.isEmpty)
    }
}
