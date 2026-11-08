import Darwin
import Foundation
import NativServerKit
import NativTranslationKit
import Security

/// A private, lazy MLX server for Translate. It never attaches to or unloads the user's chat server.
actor TranslationCascadeRuntime {
    /// A credential for this owned child only. Do not log or persist it.
    struct Endpoint: Sendable {
        let baseURL: URL
        let apiKey: String
    }

    private var process: Process?
    private var computeLease: GenerationComputeLease?
    private var output: Pipe?
    private var buffer = ""
    private var port: Int?
    private var endpoint: Endpoint?
    private var launchID = UUID()
    private var startRequestID = UUID()
    private var preparation: Task<Endpoint, Error>?
    private var shutdown: Task<Void, Never>?
    private let executable: URL?
    private let readinessTimeout: TimeInterval

    init(executable: URL? = nil, readinessTimeout: TimeInterval = 60) {
        self.executable = executable
        self.readinessTimeout = max(0.1, min(readinessTimeout, 120))
    }

    deinit {
        preparation?.cancel()
        output?.fileHandleForReading.readabilityHandler = nil
        if process?.isRunning == true { process?.terminate() }
    }

    var isRunning: Bool { process?.isRunning == true }

    func start() async throws -> Endpoint {
        if let endpoint, process?.isRunning == true { return endpoint }
        if let preparation { return try await preparation.value }
        let requestID = UUID()
        startRequestID = requestID
        if let shutdown { await shutdown.value }
        try Task.checkCancellation()
        guard startRequestID == requestID else { throw CancellationError() }
        // Another caller may have started a replacement while shutdown was awaited.
        if let endpoint, process?.isRunning == true { return endpoint }
        if let preparation { return try await preparation.value }
        if let process, !process.isRunning {
            // A crashed child may leave a drained readiness pipe; never accumulate it across retries.
            output?.fileHandleForReading.readabilityHandler = nil
            try? output?.fileHandleForReading.close()
            try? output?.fileHandleForWriting.close()
            output = nil
            self.process = nil
            endpoint = nil
            port = nil
            buffer = ""
        }
        guard TranslationHardwareSnapshot.current().pressure != .critical else {
            throw failure("macOS reports critical memory pressure. Free other model workloads, then Resume.")
        }
        let id = UUID()
        launchID = id
        let task = Task { try await self.launch(id: id) }
        preparation = task
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
                Task { await self.cancelLaunch(id) }
            }
            guard launchID == id else { throw CancellationError() }
            preparation = nil
            endpoint = result
            return result
        } catch {
            if launchID == id { await stop() }
            throw error
        }
    }

    /// Must finish before admitting another stage. /unload joins the runtime's inference workers.
    func unloadModels() async throws {
        try Task.checkCancellation()
        guard let endpoint, process?.isRunning == true else { return }
        let id = launchID
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("unload"))
        request.httpMethod = "POST"
        request.setValue("Bearer " + endpoint.apiKey, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let session = Self.session()
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard id == launchID, process?.isRunning == true else { throw CancellationError() }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = body["status"] as? String,
                  ["success", "no_model_loaded"].contains(status) else {
                throw failure("The private cascade runtime could not release its model. Resume to restart it.")
            }
        } catch {
            // An uncertain unload may leave a GPU worker active. Terminate only our own process.
            if id == launchID { await stop() }
            throw error
        }
    }

    func stop() async {
        startRequestID = UUID()
        launchID = UUID()
        preparation?.cancel()
        preparation = nil
        endpoint = nil
        port = nil
        buffer = ""
        if let shutdown { await shutdown.value; return }
        guard let owned = process else { computeLease?.close(); computeLease = nil; return }
    let ownedLease = computeLease; computeLease = nil
        process = nil
        let pipe = output
        output = nil
        pipe?.fileHandleForReading.readabilityHandler = nil
        owned.terminationHandler = nil
        let cleanup = Task { @concurrent in
            // The bundled supervisor owns child escalation and reaping. Killing
            // it on a competing host deadline could orphan its Python child.
            // Keep admission blocked until that supervisor has finished cleanup.
            if owned.isRunning { owned.terminate() }
            while owned.isRunning {
                try? await Task.sleep(for: .milliseconds(25))
            }
            try? pipe?.fileHandleForReading.close()
            try? pipe?.fileHandleForWriting.close()
        }
        shutdown = cleanup
        await cleanup.value
        shutdown = nil
    ownedLease?.close()
    }

    private func cancelLaunch(_ id: UUID) async {
        if launchID == id { await stop() }
    }

    private func launch(id: UUID) async throws -> Endpoint {
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
            throw failure("A private credential for the cascade runtime could not be created.")
        }
        let key = Data(random).base64EncodedString()
        let child = Process()
        child.executableURL = try executable ?? Nativ.executableURL()
        child.arguments = Self.arguments
        child.environment = Self.sanitizedEnvironment(ProcessInfo.processInfo.environment, bearerToken: key)
        let acquired = try GenerationComputeLease.acquire()
    computeLease = acquired
    child.standardInput = try acquired.inheritedFileHandle()
        let pipe = Pipe()
        child.standardOutput = pipe
        child.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            else { Task { await self?.consumeOutput(data, id: id) } }
        }
        try Task.checkCancellation()
        guard id == launchID else { throw CancellationError() }
        process = child
        output = pipe
        do { try child.run() }
        catch { throw failure("The bundled private cascade runtime could not start. Rebuild the app runtime.") }
        let session = Self.session()
        defer { session.invalidateAndCancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(readinessTimeout))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard id == launchID else { throw CancellationError() }
            guard child.isRunning else { throw failure("The private cascade runtime stopped unexpectedly. Resume to restart it.") }
            guard TranslationHardwareSnapshot.current().pressure != .critical else {
                throw failure("macOS reported critical memory pressure while starting the cascade runtime.")
            }
            if let port {
                let endpoint = Endpoint(baseURL: URL(string: "http://127.0.0.1:\(port)")!, apiKey: key)
                var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("nativ/translation-capabilities"))
                request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
                request.timeoutInterval = 2
                do {
                    let (data, response) = try await session.data(for: request)
                    guard launchID == id, child.isRunning else { throw CancellationError() }
                    if (response as? HTTPURLResponse)?.statusCode == 200,
                       let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       body["local_speech_assets_policy"] as? Int == 1 {
                        return endpoint
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { /* Retry only inside the readiness deadline. */ }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw failure("The private cascade runtime did not become ready in time. Resume to retry.")
    }

    private func consumeOutput(_ data: Data, id: UUID) {
        guard id == launchID, port == nil else { return }
        buffer += String(decoding: data.suffix(8192), as: UTF8.self)
        buffer = String(buffer.suffix(8192))
        if let found = Self.listenerPort(in: buffer) {
            port = found
            buffer = ""
            // Do not retain model logs, transcriptions or generated text.
            output?.fileHandleForReading.readabilityHandler = { handle in
                if handle.availableData.isEmpty { handle.readabilityHandler = nil }
            }
        }
    }

    static let arguments = ["--host", "127.0.0.1", "--port", "0"]

    static func sanitizedEnvironment(_ inherited: [String: String], bearerToken: String) -> [String: String] {
        let allowed: Set<String> = ["PATH", "HOME", "TMPDIR", "USER", "LOGNAME", "LANG", "LC_ALL"]
        var environment = inherited.filter { allowed.contains($0.key) }
        // ffmpeg is used by prepared local audio models; no inherited model, preload or cloud configuration.
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        environment["MLX_VLM_SERVER_API_KEY"] = bearerToken
        environment["NATIV_PRIVATE_TRANSLATION_RUNTIME"] = "1"
        environment["NATIV_INHERITED_COMPUTE_FD"] = "0"
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        environment["APC_ENABLED"] = "0"
        environment["APC_DISK_ENABLED"] = "0"
        environment["MLX_VLM_VISION_CACHE_SIZE"] = "0"
        environment["MLX_PLATFORM_ANALYTICS_DB_PATH"] = ":memory:"
        return environment
    }

    static func listenerPort(in output: String) -> Int? {
        let pattern = #"Uvicorn running on http://127\.0\.0\.1:([0-9]{1,5})\s"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output),
              let port = Int(output[range]), (1024...65535).contains(port) else { return nil }
        return port
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration, delegate: TranslationCascadeNoRedirect(), delegateQueue: nil)
    }

    private func failure(_ message: String) -> TranslationFailure {
        .init(code: .providerFailure, message: message)
    }
}

private final class TranslationCascadeNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
