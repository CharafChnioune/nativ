import Foundation

public enum GenerationModality: String, Codable, Sendable, CaseIterable {
    case music, video
}

public enum GenerationJSONValue: Codable, Equatable, Sendable {
    case string(String), integer(Int64), number(Double), bool(Bool), object([String: Self]), array([Self]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: Self].self) { self = .object(v) }
        else { self = .array(try c.decode([Self].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    public var numberValue: Double? {
        switch self { case .number(let v): return v; case .integer(let v): return Double(v); default: return nil }
    }
    public var integerValue: Int64? {
        switch self { case .integer(let v): return v; case .number(let v): return Int64(exactly: v); default: return nil }
    }
    public var boolValue: Bool? { if case .bool(let v) = self { return v }; return nil }
    public var objectValue: [String: Self]? { if case .object(let v) = self { return v }; return nil }
    public var arrayValue: [Self]? { if case .array(let v) = self { return v }; return nil }
}

/// An immutable active connection; deliberately not Codable because it holds a credential.
public struct GenerationConnection: Sendable, Equatable {
    public let baseURL: URL
    public let apiKey: String
    public let storeID: String?
    public let allowPrivateHTTP: Bool
    public init(baseURL: URL, apiKey: String, storeID: String? = nil, allowPrivateHTTP: Bool = false) {
        self.baseURL = baseURL; self.apiKey = apiKey; self.storeID = storeID; self.allowPrivateHTTP = allowPrivateHTTP
    }
    public func bound(to storeID: String) -> Self { .init(baseURL: baseURL, apiKey: apiKey, storeID: storeID, allowPrivateHTTP: allowPrivateHTTP) }
}

public struct GenerationInfo: Codable, Sendable {
    public let storeID: String
    public let contractVersion: Int
    public let modality: GenerationModality
    public let limits: [String: GenerationJSONValue]
    enum CodingKeys: String, CodingKey { case storeID = "store_id", contractVersion = "contract_version", modality, limits }
}

public struct GenerationProfile: Codable, Identifiable, Sendable {
    public let id: String
    public let modality: GenerationModality
    public let provider: String
    public let deployment: String
    public let profileRevision: String
    public let displayName: String
    public let model: String
    public let qualification: String
    public var runtime: String?
    public var readiness: String?
    public var unavailableReason: String?
    public let capabilities: [String: GenerationJSONValue]
    public let defaults: [String: GenerationJSONValue]
    public var attribution: String?
    enum CodingKeys: String, CodingKey {
        case id, modality, provider, deployment, model, qualification, runtime, readiness, capabilities, defaults, attribution
        case profileRevision = "profile_revision", displayName = "display_name", unavailableReason = "unavailable_reason"
    }
}

public struct GenerationSession: Codable, Identifiable, Sendable {
    public let id: String
    public let storeID: String
    public let modality: GenerationModality
    public let title: String
    public let hidden: Bool
    public let createdAt: Double
    public let updatedAt: Double
    enum CodingKeys: String, CodingKey { case id, modality, title, hidden, storeID = "store_id", createdAt = "created_at", updatedAt = "updated_at" }
}

public enum GenerationJobState: String, Codable, Sendable {
    case queued, preparing, running, finalizing, succeeded, cancelled, interrupted, failed
    case recoveryHold = "recovery_hold", retrievalPending = "retrieval_pending"
    case cancelRequested = "cancel_requested", submissionUnknown = "submission_unknown"
    public var isTerminal: Bool { [.succeeded, .cancelled, .interrupted, .failed].contains(self) }
}

public struct GenerationAPIError: Error, Codable, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public let field: String?
    public let retryable: Bool
    public let jobID: String?
    /// HTTP disposition is transport metadata; retryable alone does not say whether a POST was accepted.
    public let httpStatus: Int?
    public var errorDescription: String? { message }
    public init(code: String, message: String, field: String? = nil, retryable: Bool = false, jobID: String? = nil, httpStatus: Int? = nil) {
        self.code = code; self.message = message; self.field = field; self.retryable = retryable; self.jobID = jobID; self.httpStatus = httpStatus
    }
    enum CodingKeys: String, CodingKey { case code, message, field, retryable, jobID = "job_id", httpStatus = "http_status" }
}

public struct GenerationJob: Codable, Identifiable, Sendable {
    public var id: String { jobID }
    public let jobID: String
    public let storeID: String
    public let sessionID: String
    public let attemptID: String?
    public let modality: GenerationModality
    public let state: GenerationJobState
    public let stage: String
    public let progress: Double?
    public let createdAt: Double
    public let updatedAt: Double
    public let request: [String: GenerationJSONValue]
    public let submittedRequest: [String: GenerationJSONValue]?
    public let profile: [String: GenerationJSONValue]
    public let effectiveParameters: [String: GenerationJSONValue]?
    public let assetID: String?
    public let error: GenerationAPIError?
    public let providerOutcome: String?
    public let remoteReservation: String?
    public let revision: Int
    enum CodingKeys: String, CodingKey {
        case modality, state, stage, progress, request, profile, error, revision
        case submittedRequest = "submitted_request"
        case jobID = "job_id", storeID = "store_id", sessionID = "session_id", attemptID = "attempt_id"
        case createdAt = "created_at", updatedAt = "updated_at", assetID = "asset_id"
        case effectiveParameters = "effective_parameters", providerOutcome = "provider_outcome", remoteReservation = "remote_reservation"
    }
}

public struct GenerationAsset: Codable, Identifiable, Sendable {
    public var id: String { assetID }
    public let assetID: String
    public let storeID: String
    public let jobID: String
    public let modality: GenerationModality
    public let filename: String
    public let mimeType: String
    public let byteSize: Int64
    public let sha256: String
    public let createdAt: Double
    public let trashed: Bool
    public let metadata: [String: GenerationJSONValue]
    public let revision: Int
    enum CodingKeys: String, CodingKey {
        case modality, filename, sha256, trashed, metadata, revision
        case assetID = "asset_id", storeID = "store_id", jobID = "job_id", mimeType = "mime_type", byteSize = "byte_size", createdAt = "created_at"
    }
}

public struct GenerationAssetReference: Codable, Hashable, Sendable {
    public let storeID: String
    public let assetID: String
    public let jobID: String
    public let sessionID: String
    public let modality: GenerationModality
    public let referenceID: String
    public init(storeID: String, assetID: String, jobID: String, sessionID: String, modality: GenerationModality, referenceID: String) {
        self.storeID = storeID; self.assetID = assetID; self.jobID = jobID; self.sessionID = sessionID; self.modality = modality; self.referenceID = referenceID
    }
}

public struct GenerationPage<Item: Codable & Sendable>: Codable, Sendable {
    public let items: [Item]
    public let nextCursor: String?
    enum CodingKeys: String, CodingKey { case items, nextCursor = "next_cursor" }
}

public struct GenerationEvent: Codable, Sendable {
    public let id: Int
    public let type: String
    public let job: GenerationJob
}
