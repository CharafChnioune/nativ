import Combine
import CryptoKit
import Foundation

struct TranslationModelArtifact: Codable, Equatable, Sendable {
    let filename: String
    let size: Int64
    let sha256: String

    func validate() throws {
        guard !filename.isEmpty, filename == URL(fileURLWithPath: filename).lastPathComponent,
              !filename.contains(".."), !filename.contains("\\"), size > 0,
              sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit }) else {
            throw TranslationModelStoreError.invalidManifest
        }
    }
}

struct TranslationModelInstallation: Sendable {
    let modelURL: URL
    let projectorURL: URL
}

struct TranslationModelManifest: Decodable, Sendable {
    struct Model: Decodable, Sendable {
        let repository: String
        let revision: String
        let artifacts: [String: TranslationModelArtifact]

        func validate() throws {
            guard repository.split(separator: "/").count == 2,
                  repository.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "/-_.".contains($0)) }),
                  !repository.contains(".."), revision.count == 40,
                  revision.allSatisfy({ $0.isHexDigit }), artifacts["projector"] != nil else {
                throw TranslationModelStoreError.invalidManifest
            }
            for artifact in artifacts.values { try artifact.validate() }
        }

        func installation(in cache: URL, quantization: String) throws -> TranslationModelInstallation {
            try validate()
            guard quantization != "projector", let model = artifacts[quantization],
                  let projector = artifacts["projector"], model.filename != projector.filename else {
                throw TranslationModelStoreError.invalidManifest
            }
            let directory = cache.appendingPathComponent("nativ-translation", isDirectory: true)
                .appendingPathComponent(repository.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
                .appendingPathComponent(revision, isDirectory: true)
            return .init(modelURL: directory.appendingPathComponent(model.filename),
                         projectorURL: directory.appendingPathComponent(projector.filename))
        }
    }
    let model: Model
}

enum TranslationModelStoreError: LocalizedError {
    case invalidManifest, missingManifest, downloadFailed, integrityFailure, missingInstallation

    var errorDescription: String? {
        switch self {
        case .invalidManifest: "The translation model manifest is invalid. Rebuild or update this fork."
        case .missingManifest: "The bundled translation model manifest is missing. Rebuild this fork."
        case .downloadFailed: "The model download failed. Check the connection and retry."
        case .integrityFailure: "Model verification failed. The incomplete download was removed; retry preparation."
        case .missingInstallation: "Prepare the selected model and its matching audio projector first."
        }
    }
}

/// The destination and URLSession temporary download may live on different volumes.
/// The shared capacity service combines reservations when they are on the same volume.
struct TranslationDownloadReservations: Sendable {
    private let destination = UUID()
    private let temporary = UUID()
    private let onRelease: @Sendable (UUID) -> Void

    init(totalBytes: Int64, largestArtifactBytes: Int64, cachePath: String, temporaryPath: String,
         reserve: @Sendable (UUID, Int64, String) throws -> Void, release: @escaping @Sendable (UUID) -> Void) throws {
        onRelease = release
        try reserve(destination, totalBytes, cachePath)
        do {
            try reserve(temporary, largestArtifactBytes, temporaryPath)
        } catch {
            release(destination)
            throw error
        }
    }

    func release() { onRelease(temporary); onRelease(destination) }
}

/// Uses the same cache volume and admission-control service as normal Nativ downloads.
/// The dedicated directory keeps optional GGUF artifacts out of MLX loader discovery.
@MainActor
final class TranslationModelStore: ObservableObject {
    @Published private(set) var completedBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var isPreparing = false
    @Published private(set) var isInstalled = false
    @Published private(set) var message: String?

    private var task: Task<TranslationModelInstallation, Error>?
    private var preparationID = UUID()
    private let reserve: @Sendable (UUID, Int64, String) throws -> Void
    private let release: @Sendable (UUID) -> Void

    init(reserve: @escaping @Sendable (UUID, Int64, String) throws -> Void,
         release: @escaping @Sendable (UUID) -> Void) {
        self.reserve = reserve
        self.release = release
    }

    static func bundledManifest(bundle: Bundle = .main) throws -> TranslationModelManifest {
        guard let url = bundle.resourceURL?.appendingPathComponent("LFMRealtime/runtime-manifest.json"),
              FileManager.default.fileExists(atPath: url.path) else { throw TranslationModelStoreError.missingManifest }
        let manifest = try JSONDecoder().decode(TranslationModelManifest.self, from: Data(contentsOf: url))
        try manifest.model.validate()
        return manifest
    }

    func prepare(manifest: TranslationModelManifest, cache: URL, quantization: String,
                 download: Bool) async throws -> TranslationModelInstallation {
        cancel()
        let id = UUID()
        preparationID = id
        isPreparing = true
        isInstalled = false
        message = "Verifying model artifacts…"
        completedBytes = 0
        totalBytes = 0
        let reserve = reserve
        let release = release
        let reportProgress: @Sendable (Int64, Int64) -> Void = { [weak self] received, total in
            guard let self else { return }
            Task { @MainActor in
                guard self.preparationID == id else { return }
                self.completedBytes = received
                self.totalBytes = total
                self.message = "Preparing model…"
            }
        }
        let operation = Task { @concurrent in
            try await Self.install(manifest: manifest, cache: cache, quantization: quantization,
                                   download: download, reserve: reserve, release: release,
                                   progress: reportProgress)
        }
        task = operation
        do {
            let result = try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: { operation.cancel() }
            guard preparationID == id else { throw CancellationError() }
            try Task.checkCancellation()
            isInstalled = true
            isPreparing = false
            message = "Model artifacts verified"
            task = nil
            return result
        } catch {
            if preparationID == id {
                isPreparing = false
                message = error is CancellationError ? "Preparation cancelled" : error.localizedDescription
                task = nil
            }
            throw error
        }
    }

    func cancel() {
        preparationID = UUID()
        task?.cancel()
        task = nil
        isPreparing = false
    }

    nonisolated static func verify(file: URL, artifact: TranslationModelArtifact) throws -> Bool {
        try artifact.validate()
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        var freshURL = file
        freshURL.removeAllCachedResourceValues()
        let values = try freshURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              Int64(values.fileSize ?? -1) == artifact.size else { return false }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined() == artifact.sha256.lowercased()
    }

    @concurrent private static func install(
        manifest: TranslationModelManifest, cache: URL, quantization: String, download: Bool,
        reserve: @Sendable (UUID, Int64, String) throws -> Void, release: @escaping @Sendable (UUID) -> Void,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> TranslationModelInstallation {
        let installation = try manifest.model.installation(in: cache, quantization: quantization)
        let files = [(installation.modelURL, manifest.model.artifacts[quantization]!),
                     (installation.projectorURL, manifest.model.artifacts["projector"]!)]
        var missing: [(URL, TranslationModelArtifact)] = []
        for pair in files where try !verify(file: pair.0, artifact: pair.1) { missing.append(pair) }
        guard !missing.isEmpty else { return installation }
        guard download else { throw TranslationModelStoreError.missingInstallation }
        let directory = installation.modelURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let total = missing.reduce(Int64(0)) { $0 + $1.1.size }
        let reservations = try TranslationDownloadReservations(
            totalBytes: total, largestArtifactBytes: missing.map { $0.1.size }.max() ?? 0,
            cachePath: directory.path, temporaryPath: FileManager.default.temporaryDirectory.path,
            reserve: reserve, release: release)
        defer { reservations.release() }
        var completed: Int64 = 0
        for (destination, artifact) in missing {
            try Task.checkCancellation()
            let base = completed
            let delegate = TranslationDownloadProgress { progress(min(base + $0, total), total) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 7_200
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let url = URL(string: "https://huggingface.co/\(manifest.model.repository)/resolve/\(manifest.model.revision)/\(artifact.filename)")!
            let (temporary, response) = try await session.download(from: url)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw TranslationModelStoreError.downloadFailed
            }
            guard try verify(file: temporary, artifact: artifact) else { throw TranslationModelStoreError.integrityFailure }
            try Task.checkCancellation()
            // Stage on the destination volume before the atomic rename, including
            // when the model cache is on an external drive.
            let staged = directory.appendingPathComponent(".\(UUID().uuidString).partial")
            defer { try? FileManager.default.removeItem(at: staged) }
            try FileManager.default.copyItem(at: temporary, to: staged)
            try Task.checkCancellation()
            guard try verify(file: staged, artifact: artifact) else { throw TranslationModelStoreError.integrityFailure }
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
            } else {
                try FileManager.default.moveItem(at: staged, to: destination)
            }
            completed += artifact.size
            progress(completed, total)
        }
        return installation
    }
}

/// Immutable callback; URLSession owns serialization of its delegate calls.
private final class TranslationDownloadProgress: NSObject, URLSessionDownloadDelegate, Sendable {
    private let progress: @Sendable (Int64) -> Void
    init(progress: @escaping @Sendable (Int64) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) { progress(totalBytesWritten) }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
