import Foundation

private final class GenerationNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { nil }
}

/// A file-backed upload still needs a bounded response; async upload(for:) collects
/// an arbitrarily large reply before returning. This delegate cancels at the cap.
private final class GenerationBoundedUpload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let limit = 16 * 1_024 * 1_024
    private var task: URLSessionUploadTask?
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var data = Data()
    private var response: URLResponse?
    private var failure: Error?
    private var cancelled = false

    func run(session: URLSession, request: URLRequest, file: URL) async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.uploadTask(with: request, fromFile: file)
                task.delegate = self
                let start = lock.withLock {
                    guard !cancelled else { return false }
                    self.task = task; self.continuation = continuation
                    return true
                }
                if start { task.resume() }
                else { task.cancel(); continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let task = self.lock.withLock { self.cancelled = true; return self.task }
            task?.cancel()
        }
    }
    private func oversized() -> GenerationAPIError {
        .init(code: "response_too_large", message: "The server response exceeds the control-plane limit.")
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let allowed = lock.withLock {
            self.response = response
            guard response.expectedContentLength <= Int64(limit) else { failure = oversized(); return false }
            return true
        }
        completionHandler(allowed ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        let allowed = lock.withLock {
            guard failure == nil, chunk.count <= limit - data.count else { failure = oversized(); return false }
            data.append(chunk); return true
        }
        if !allowed { dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { nil }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result = lock.withLock { () -> (CheckedContinuation<(Data, URLResponse), Error>?, Data, URLResponse?, Error?) in
            let continuation = self.continuation; self.continuation = nil; self.task = nil
            return (continuation, data, response, cancelled ? CancellationError() : (failure ?? error))
        }
        guard let continuation = result.0 else { return }
        if let error = result.3 { continuation.resume(throwing: error) }
        else if let response = result.2 { continuation.resume(returning: (result.1, response)) }
        else { continuation.resume(throwing: GenerationAPIError(code: "invalid_response", message: "The generation server returned an invalid response.")) }
    }
}

/// Control-plane calls never wait for model inference. Media downloads use files.
public class NativGenerationClient: @unchecked Sendable {
    public let modality: GenerationModality
    public let connection: GenerationConnection
    private let session: URLSession
    private let redirectPolicy = GenerationNoRedirect()

    public init(modality: GenerationModality, connection: GenerationConnection, session: URLSession? = nil) {
        self.modality = modality; self.connection = connection
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 600
            configuration.httpShouldSetCookies = false
            self.session = URLSession(configuration: configuration)
        }
    }

    public func info() async throws -> GenerationInfo {
        let value: GenerationInfo = try await call("info")
        guard value.contractVersion == 1 else { throw fail("unsupported_contract", "This server uses an unsupported generation API version.") }
        if let expected = connection.storeID, value.storeID != expected { throw fail("store_mismatch", "The server's media library has changed. Reconnect before creating a new request.") }
        return value
    }
    public func models() async throws -> [GenerationProfile] { let p: GenerationPage<GenerationProfile> = try await call("models"); return p.items }
    public func configuration() async throws -> [String: GenerationJSONValue] { try await call("configuration") }
    public func serverState() async throws -> [String: GenerationJSONValue] { try await call("server-state") }
    public func prepareStop() async throws -> [String: GenerationJSONValue] { try await call("prepare-stop", method: "POST", body: [:]) }
    public func runtimes() async throws -> [String: GenerationJSONValue] { try await call("runtimes") }
    @discardableResult public func updateConfiguration(profileID: String, values: [String: GenerationJSONValue]) async throws -> [String: GenerationJSONValue] {
        try await call("configuration/\(try identifier(profileID))", method: "PUT", body: values)
    }
    @discardableResult public func runtimeAction(id: String, action: String, profileID: String? = nil) async throws -> [String: GenerationJSONValue] {
        guard ["install", "repair", "cancel-install", "remove"].contains(action) else { throw fail("unsupported_action", "Unknown runtime action.") }
        return try await call("runtimes/\(try identifier(id))/\(action)", method: "POST", body: profileID.map { ["profile_id": .string($0)] } ?? [:])
    }
    public func sessions(cursor: String? = nil) async throws -> GenerationPage<GenerationSession> { try await call("sessions", query: cursorQuery(cursor)) }
    public func createSession(title: String) async throws -> GenerationSession { try await call("sessions", method: "POST", body: ["title": .string(title)]) }
    public func updateSession(id: String, title: String? = nil, hidden: Bool? = nil) async throws -> GenerationSession {
        var body: [String: GenerationJSONValue] = [:]
        if let title { body["title"] = .string(title) }; if let hidden { body["hidden"] = .bool(hidden) }
        return try await call("sessions/\(try identifier(id))", method: "PATCH", body: body)
    }
    public func jobs(cursor: String? = nil, sessionID: String? = nil) async throws -> GenerationPage<GenerationJob> {
        var query = cursorQuery(cursor); if let sessionID { query.append(.init(name: "session_id", value: sessionID)) }
        return try await call("generations", query: query)
    }
    public func job(id: String) async throws -> GenerationJob { try await call("generations/\(try identifier(id))") }
    public func submit(_ request: [String: GenerationJSONValue], idempotencyKey: String) async throws -> GenerationJob {
        guard !idempotencyKey.isEmpty else { throw fail("missing_idempotency_key", "A saved request identity is required.") }
        return try await call("generations", method: "POST", body: request, headers: ["Idempotency-Key": idempotencyKey])
    }
    public func cancel(jobID: String) async throws -> GenerationJob { try await mutation(jobID, "cancel") }
    public func resume(jobID: String) async throws -> GenerationJob { try await mutation(jobID, "resume") }
    public func retryDownload(jobID: String) async throws -> GenerationJob { try await mutation(jobID, "retry-download") }
    public func releaseRemoteReservation(jobID: String, acknowledgePossibleExecutionAndCharges: Bool) async throws -> GenerationJob {
        try await call("generations/\(try identifier(jobID))/release-remote-reservation", method: "POST", body: ["acknowledge_possible_execution_and_charges": .bool(acknowledgePossibleExecutionAndCharges)])
    }
    public func asset(id: String) async throws -> GenerationAsset { try await call("assets/\(try identifier(id))") }
    public func usages(assetID: String) async throws -> [String: GenerationJSONValue] { try await call("assets/\(try identifier(assetID))/usages") }
    public func putReference(assetID: String, referenceID: String, phase: String, expectedRevision: Int, owner: [String: GenerationJSONValue]) async throws -> [String: GenerationJSONValue] {
        try await call("assets/\(try identifier(assetID))/references/\(try identifier(referenceID))", method: "PUT", body: ["phase": .string(phase), "expected_revision": .number(Double(expectedRevision)), "owner": .object(owner)])
    }
    public func deleteReference(assetID: String, referenceID: String, expectedRevision: Int) async throws -> [String: GenerationJSONValue] {
        try await call("assets/\(try identifier(assetID))/references/\(try identifier(referenceID))", method: "DELETE", body: ["expected_revision": .number(Double(expectedRevision))])
    }
    public func trash(assetID: String) async throws -> GenerationAsset { try await call("assets/\(try identifier(assetID))", method: "DELETE", body: [:]) }
    public func restore(assetID: String) async throws -> GenerationAsset { try await call("assets/\(try identifier(assetID))/restore", method: "POST", body: [:]) }

    public func download(assetID: String, to destination: URL, poster: Bool = false) async throws -> URL {
        let request = try makeRequest("assets/\(try identifier(assetID))/\(poster ? "poster" : "content")")
        return try await download(request: request, to: destination, limit: poster ? 4 * 1_024 * 1_024 : (modality == .music ? 1_073_741_824 : 2_147_483_648))
    }
    public func prepareInput(inputID: String, width: Int, height: Int, transform: [String: GenerationJSONValue]) async throws -> [String: GenerationJSONValue] {
        try await call("inputs/\(try identifier(inputID))/transform", method: "POST", body: ["width": .number(Double(width)), "height": .number(Double(height)), "transform": .object(transform)])
    }
    public func downloadInputDerivative(inputID: String, derivativeID: String, to destination: URL) async throws -> URL {
        let request = try makeRequest("inputs/\(try identifier(inputID))/derivatives/\(try identifier(derivativeID))/content")
        return try await download(request: request, to: destination, limit: 32 * 1_024 * 1_024)
    }
    private func download(request: URLRequest, to destination: URL, limit: Int) async throws -> URL {
        let (bytes, response) = try await session.bytes(for: request, delegate: redirectPolicy)
        try check(response, body: nil)
        guard response.expectedContentLength <= Int64(limit) else { throw fail("invalid_download", "The media exceeds its declared size limit.") }
        if let expected = connection.storeID {
            guard (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Nativ-Store-ID") == expected else { throw fail("store_mismatch", "The download belongs to a different media library.") }
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".partial")
        FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            var buffer = Data(); buffer.reserveCapacity(64 * 1_024)
            var count = 0
            for try await byte in bytes {
                try Task.checkCancellation()
                count += 1
                guard count <= limit else { throw fail("invalid_download", "The media exceeded its download limit.") }
                buffer.append(byte)
                if buffer.count == 64 * 1_024 { try handle.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
            }
            guard count > 0 else { throw fail("invalid_download", "The downloaded media is empty.") }
            if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
            try handle.synchronize(); try handle.close()
        } catch { try? handle.close(); throw error }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: destination) }
        return destination
    }

    public func uploadInput(file: URL) async throws -> [String: GenerationJSONValue] {
        guard modality == .video else { throw fail("unsupported_operation", "Reference uploads are available in Video.") }
        let size = (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        guard size > 0, size <= 25 * 1_024 * 1_024 else { throw fail("invalid_input_size", "A reference image must be between one byte and 25 MiB.") }
        let boundary = UUID().uuidString
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = try FileHandle(forWritingTo: temporary)
        let input = try FileHandle(forReadingFrom: file)
        do {
            try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"reference\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
            var copied = 0
            while let chunk = try input.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                try Task.checkCancellation(); copied += chunk.count
                guard copied <= 25 * 1_024 * 1_024 else { throw fail("invalid_input_size", "The reference grew beyond its upload limit.") }
                try output.write(contentsOf: chunk)
            }
            guard copied == size else { throw fail("input_changed", "The reference changed while preparing its upload.") }
            try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
            try input.close(); try output.close()
        } catch { try? input.close(); try? output.close(); throw error }
        var request = try makeRequest("inputs", method: "POST")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await GenerationBoundedUpload().run(session: session, request: request, file: temporary)
        try check(response, body: data)
        return try JSONDecoder().decode([String: GenerationJSONValue].self, from: data)
    }

    public func events(jobID: String, lastEventID: Int? = nil) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            let task = Task {
                do {
                    var request = try makeRequest("generations/\(try identifier(jobID))/events")
                    request.timeoutInterval = 3_600
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    if let lastEventID { request.setValue(String(lastEventID), forHTTPHeaderField: "Last-Event-ID") }
                    let (bytes, response) = try await session.bytes(for: request, delegate: redirectPolicy)
                    try check(response, body: nil)
                    var lineBytes = Data()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        guard lineBytes.count < 1_048_576 else { throw fail("invalid_event", "The server sent an oversized progress event.") }
                        if byte != 10 { lineBytes.append(byte); continue }
                        guard let line = String(data: lineBytes, encoding: .utf8) else { throw fail("invalid_event", "The server sent invalid progress text.") }
                        lineBytes.removeAll(keepingCapacity: true)
                        if line.hasPrefix("data:") {
                            let data = Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
                            let event = try JSONDecoder().decode(GenerationEvent.self, from: data)
                            guard connection.storeID == nil || event.job.storeID == connection.storeID else { throw fail("store_mismatch", "The event belongs to another media library.") }
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func mutation(_ id: String, _ action: String) async throws -> GenerationJob { try await call("generations/\(try identifier(id))/\(action)", method: "POST", body: [:]) }
    private func cursorQuery(_ cursor: String?) -> [URLQueryItem] { cursor.map { [.init(name: "cursor", value: $0)] } ?? [] }
    private func identifier(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 200, value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_:.")).contains($0) }), value != ".", value != ".." else { throw fail("invalid_identifier", "The media identifier is invalid.") }
        return value
    }
    private func fail(_ code: String, _ message: String) -> GenerationAPIError { .init(code: code, message: message) }
    private func allowedHTTPHost(_ host: String) -> Bool {
        if ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) { return true }
        guard connection.allowPrivateHTTP else { return false }
        let pieces = host.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4, pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return false }
        let numbers = pieces.compactMap { UInt8($0) }
        guard numbers.count == 4 else { return false }
        return numbers[0] == 10 || (numbers[0] == 172 && (16...31).contains(numbers[1])) || (numbers[0] == 192 && numbers[1] == 168)
    }
    private func makeRequest(_ path: String, method: String = "GET", query: [URLQueryItem] = []) throws -> URLRequest {
        guard !connection.apiKey.isEmpty else { throw fail("authentication_required", "Configure the Nativ server API key before using generation.") }
        guard let base = URLComponents(url: connection.baseURL, resolvingAgainstBaseURL: false),
              base.user == nil, base.password == nil, base.query == nil, base.fragment == nil,
              base.scheme == "https" || (base.scheme == "http" && allowedHTTPHost(base.host ?? "")) else {
            throw fail("invalid_server", "Use HTTPS for a remote generation server, or a loopback HTTP address.")
        }
        var url = URLComponents(url: connection.baseURL.appendingPathComponent("v1/\(modality.rawValue)/\(path)"), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { url.queryItems = query }
        var request = URLRequest(url: url.url!); request.httpMethod = method
        request.setValue("Bearer \(connection.apiKey)", forHTTPHeaderField: "Authorization")
        if let storeID = connection.storeID { request.setValue(storeID, forHTTPHeaderField: "X-Nativ-Store-ID") }
        if method != "GET", connection.storeID == nil { throw fail("store_required", "Connect to the media library before making changes.") }
        return request
    }
    private func call<T: Decodable>(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: [String: GenerationJSONValue]? = nil, headers: [String: String] = [:]) async throws -> T {
        var request = try makeRequest(path, method: method, query: query)
        if let body { request.httpBody = try JSONEncoder().encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (bytes, response) = try await session.bytes(for: request, delegate: redirectPolicy)
        guard response.expectedContentLength <= 16 * 1_024 * 1_024 else { throw fail("response_too_large", "The server response exceeds the control-plane limit.") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 16 * 1_024 * 1_024 else { throw fail("response_too_large", "The server response exceeds the control-plane limit.") }
            data.append(byte)
        }
        try check(response, body: data)
        return try JSONDecoder().decode(T.self, from: data)
    }
    private func check(_ response: URLResponse, body: Data?) throws {
        guard let http = response as? HTTPURLResponse else { throw fail("invalid_response", "The generation server returned an invalid response.") }
        guard http.url?.scheme == connection.baseURL.scheme, http.url?.host == connection.baseURL.host,
              http.url?.port == connection.baseURL.port else { throw fail("server_identity_changed", "The response changed server identity.") }
        guard (200..<300).contains(http.statusCode) else {
            struct Envelope: Decodable { let error: GenerationAPIError }
            if let body, let envelope = try? JSONDecoder().decode(Envelope.self, from: body) {
                let error = envelope.error
                throw GenerationAPIError(code: error.code, message: error.message, field: error.field, retryable: error.retryable, jobID: error.jobID, httpStatus: http.statusCode)
            }
            throw GenerationAPIError(code: "http_error", message: "The generation request failed (HTTP \(http.statusCode)).", retryable: http.statusCode >= 500, httpStatus: http.statusCode)
        }
    }
}

public final class NativMusicClient: NativGenerationClient, @unchecked Sendable {
    public init(connection: GenerationConnection, session: URLSession? = nil) { super.init(modality: .music, connection: connection, session: session) }
}
public final class NativVideoClient: NativGenerationClient, @unchecked Sendable {
    public init(connection: GenerationConnection, session: URLSession? = nil) { super.init(modality: .video, connection: connection, session: session) }
}
