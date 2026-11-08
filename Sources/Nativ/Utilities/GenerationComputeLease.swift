import Darwin
import Foundation

@_silgen_name("flock")
func generationFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

/// A real host-wide flock, shared with canonical API inference and owned workers.
/// Closing an inherited descriptor in a surviving child retains the OS lock until
/// that child exits; an app crash cannot silently admit overlapping GPU work.
final class GenerationComputeLease: @unchecked Sendable {
    enum Failure: LocalizedError {
        case busy, unavailable, preparationFailed
        var errorDescription: String? {
            switch self {
            case .busy: "Local compute is in use. Wait for generation or explicitly stop it before starting Translate."
            case .unavailable: "The shared compute lock could not be opened. Check the application data directory."
            case .preparationFailed: "The active server could not release its idle models. Stop its active work, then retry Translate."
            }
        }
    }
    private final class Entry {
        let descriptor: Int32
        let nonce: String
        var references = 1
        init(_ descriptor: Int32, nonce: String) { self.descriptor = descriptor; self.nonce = nonce }
    }
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var entries: [String: Entry] = [:]
    }
    private static let registry = Registry()
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/io.github.charafchnioune.nativ/compute-admission.lock")
    }
    private let path: String
    let nonce: String
    private let closeLock = NSLock()
    private var closed = false
    private init(path: String, nonce: String) { self.path = path; self.nonce = nonce }

    static func acquire(at url: URL = defaultURL) throws -> GenerationComputeLease {
        let path = url.standardizedFileURL.path
        let registry = Self.registry
        registry.lock.lock(); defer { registry.lock.unlock() }
        if let entry = registry.entries[path] {
            entry.references += 1
            return GenerationComputeLease(path: path, nonce: entry.nonce)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = Darwin.open(path, O_RDWR | O_CREAT | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw Failure.unavailable }
        guard generationFlock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor); throw Failure.busy
        }
        let nonce = UUID().uuidString
        let value: [String: Any] = ["owner": "native-translation", "pid": ProcessInfo.processInfo.processIdentifier, "nonce": nonce]
        let data = try JSONSerialization.data(withJSONObject: value)
        _ = Darwin.ftruncate(descriptor, 0)
        _ = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        _ = Darwin.fsync(descriptor)
        registry.entries[path] = Entry(descriptor, nonce: nonce)
        return GenerationComputeLease(path: path, nonce: nonce)
    }

    /// Use as an owned helper's stdin; Foundation dup2 preserves the actual lock.
    func inheritedFileHandle() throws -> FileHandle {
        Self.registry.lock.lock(); defer { Self.registry.lock.unlock() }
        guard let entry = Self.registry.entries[path], entry.nonce == nonce else { throw Failure.unavailable }
        let duplicate = Darwin.dup(entry.descriptor)
        guard duplicate >= 0 else { throw Failure.unavailable }
        return FileHandle(fileDescriptor: duplicate, closeOnDealloc: true)
    }

    func close() {
        closeLock.lock(); defer { closeLock.unlock() }
        guard !closed else { return }; closed = true
        Self.registry.lock.lock(); defer { Self.registry.lock.unlock() }
        guard let entry = Self.registry.entries[path], entry.nonce == nonce else { return }
        entry.references -= 1
        if entry.references == 0 {
            // Do not LOCK_UN: an owned child may still hold the same open description.
            // Closing only our descriptor preserves exclusion until all child FDs exit.
            Darwin.close(entry.descriptor)
            Self.registry.entries.removeValue(forKey: path)
        }
    }
    deinit { close() }

    func prepareServerMemory(_ configuration: VoiceTranscriptionConfiguration?) async throws {
        guard let configuration, configuration.serverIsRunning,
              ["127.0.0.1", "localhost", "::1"].contains(configuration.serverBaseURL.host ?? "") else { return }
        let preparationHold = try Self.acquire(at: URL(fileURLWithPath: path))
        defer { preparationHold.close() }
        var request = URLRequest(url: configuration.serverBaseURL.appendingPathComponent("v1/generation/prepare-compute"))
        request.httpMethod = "POST"; request.timeoutInterval = 30
        if let key = configuration.serverAPIKey { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        request.setValue(nonce, forHTTPHeaderField: "X-Nativ-Compute-Lease")
        let settings = URLSessionConfiguration.ephemeral
        settings.connectionProxyDictionary = [:]; settings.httpShouldSetCookies = false
        let session = URLSession(configuration: settings, delegate: GenerationComputeNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        // A cancelled Start/Stop observer must not release admission while the
        // server is still finishing its explicitly requested idle-cache cleanup.
        let operation = Task.detached {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode
        }
        let status = try await operation.value
        try Task.checkCancellation()
        guard status == 200 else { throw Failure.preparationFailed }
    }
}

private final class GenerationComputeNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { nil }
}
