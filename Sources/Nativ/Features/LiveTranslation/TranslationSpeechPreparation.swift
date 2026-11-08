import CryptoKit
import Foundation
import NativTranslationKit

/// Explicit asset preparation; session startup only verifies existing artifacts.
/// Nothing changes the user's Hugging Face main refs or selected model snapshot.
enum TranslationSpeechPreparation {
    static let tokenizerRepository = "mlx-community/S3TokenizerV2"
    static let tokenizerRevision = "e0c9886f0e1c35ae85b1f27277416fb19fc72bec"
    static let tokenizerArtifacts: [TranslationModelArtifact] = [
        .init(filename: "config.json", size: 126, sha256: "8591fcc0eaae8c2bbfc69cf9d439933ecdf2d58cb9be63d00ce88736c4f2aa9d"),
        .init(filename: "model.safetensors", size: 494868984, sha256: "928726bc1f206a613d36b8f49e297eae9c5593a21bf9b92ddfe2c23f85eb92cc"),
        .init(filename: "README.md", size: 459, sha256: "7114249e13d3487e1b3d7f5f91fefdce746679342dca7afc8e52b1617b66bea5")
    ]
    static let characterMapRevision = "03565773edd72e949572557597af8063bb49a18a"
    static let characterMap = TranslationModelArtifact(filename: "Cangjie5_TC.json", size: 1920163,
        sha256: "7073fd9de919443ae88e0bd2449917a65fe54898a4413ed1edcc4b67f28bce8c")

    static func tokenizerLocation(cache: URL) -> URL {
        cache.appendingPathComponent("nativ-translation/cascade/s3-tokenizer/" + tokenizerRevision, isDirectory: true)
    }
    static func compositeLocation(snapshot: URL, cache: URL) -> URL {
        let key = SHA256.hash(data: Data(snapshot.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return cache.appendingPathComponent("nativ-translation/cascade/chatterbox/" + key, isDirectory: true)
    }

    @concurrent static func preparedChatterbox(snapshot: URL, cache: URL, multilingual: Bool) async throws -> (model: URL, tokenizer: URL) {
        try Task.checkCancellation()
        let tokenizer = tokenizerLocation(cache: cache)
        for artifact in tokenizerArtifacts {
            guard try TranslationModelStore.verify(file: tokenizer.appendingPathComponent(artifact.filename), artifact: artifact) else {
                throw failure("Prepare Chatterbox speech assets first. Its pinned S3TokenizerV2 is missing or failed verification.")
            }
        }
        let composite = compositeLocation(snapshot: snapshot, cache: cache)
        guard composite.appendingPathComponent("config.json").resolvingSymlinksInPath() == snapshot.appendingPathComponent("config.json").resolvingSymlinksInPath(),
              FileManager.default.fileExists(atPath: composite.appendingPathComponent("tokenizer.json").path) else {
            throw failure("Prepare the selected Chatterbox snapshot's speech assets before starting.")
        }
        if multilingual {
            guard try TranslationModelStore.verify(file: composite.appendingPathComponent(characterMap.filename), artifact: characterMap) else {
                throw failure("The pinned Chatterbox multilingual character map is not prepared.")
            }
        }
        return (composite, tokenizer)
    }

    @concurrent static func prepareChatterbox(snapshot: URL, cache: URL, multilingual: Bool) async throws -> (model: URL, tokenizer: URL) {
        try Task.checkCancellation()
        let tokenizer = tokenizerLocation(cache: cache)
        try FileManager.default.createDirectory(at: tokenizer, withIntermediateDirectories: true)
        // Reuse complete pinned files from the normal HF cache without modifying
        // that cache. Verification follows symlinks only after resolving them.
        let hub = URL(fileURLWithPath: (HuggingFaceCache.defaultHubPath() as NSString).expandingTildeInPath)
        let cached = hub.appendingPathComponent("models--mlx-community--S3TokenizerV2/snapshots/" + tokenizerRevision)
        for artifact in tokenizerArtifacts {
            let destination = tokenizer.appendingPathComponent(artifact.filename)
            if try TranslationModelStore.verify(file: destination, artifact: artifact) { continue }
            let source = cached.appendingPathComponent(artifact.filename).resolvingSymlinksInPath()
            if try TranslationModelStore.verify(file: source, artifact: artifact) {
                try await installCopy(source: source, destination: destination, artifact: artifact)
            }
        }
        try await downloadMissing(repository: tokenizerRepository, revision: tokenizerRevision, artifacts: tokenizerArtifacts, directory: tokenizer)
        let composite = compositeLocation(snapshot: snapshot, cache: cache)
        try FileManager.default.createDirectory(at: composite, withIntermediateDirectories: true)
        for source in try FileManager.default.contentsOfDirectory(at: snapshot, includingPropertiesForKeys: nil) {
            try Task.checkCancellation()
            if source.lastPathComponent == characterMap.filename { continue }
            let destination = composite.appendingPathComponent(source.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                guard destination.resolvingSymlinksInPath() == source.resolvingSymlinksInPath() else {
                    throw failure("The prepared Chatterbox model binding changed. Remove this prepared composite and prepare it again.")
                }
            } else { try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source.resolvingSymlinksInPath()) }
        }
        if multilingual {
            try await downloadMissing(repository: "mlx-community/chatterbox-multilingual-v3", revision: characterMapRevision,
                                      artifacts: [characterMap], directory: composite)
        }
        return try await preparedChatterbox(snapshot: snapshot, cache: cache, multilingual: multilingual)
    }

    @concurrent private static func downloadMissing(repository: String, revision: String, artifacts: [TranslationModelArtifact], directory: URL) async throws {
        let missing = try artifacts.filter { try !TranslationModelStore.verify(file: directory.appendingPathComponent($0.filename), artifact: $0) }
        guard !missing.isEmpty else { return }
        let reservations = try TranslationDownloadReservations(totalBytes: missing.reduce(0) { $0 + $1.size },
            largestArtifactBytes: missing.map(\.size).max() ?? 0, cachePath: directory.path,
            temporaryPath: FileManager.default.temporaryDirectory.path,
            reserve: { try HuggingFaceDownloadCapacity.shared.reserve($0, bytes: $1, atPath: $2) },
            release: { HuggingFaceDownloadCapacity.shared.release($0) })
        defer { reservations.release() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 7_200
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for artifact in missing {
            try Task.checkCancellation()
            let url = URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(artifact.filename)")!
            let (temporary, response) = try await session.download(from: url)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw TranslationModelStoreError.downloadFailed }
            guard try TranslationModelStore.verify(file: temporary, artifact: artifact) else { throw TranslationModelStoreError.integrityFailure }
            try await installCopy(source: temporary, destination: directory.appendingPathComponent(artifact.filename), artifact: artifact, reserve: false)
        }
    }

    @concurrent private static func installCopy(source: URL, destination: URL, artifact: TranslationModelArtifact, reserve: Bool = true) async throws {
        try Task.checkCancellation()
        let reservation = UUID()
        if reserve { try HuggingFaceDownloadCapacity.shared.reserve(reservation, bytes: artifact.size, atPath: destination.deletingLastPathComponent().path) }
        defer { if reserve { HuggingFaceDownloadCapacity.shared.release(reservation) } }
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.copyItem(at: source, to: staged)
        guard try TranslationModelStore.verify(file: staged, artifact: artifact) else { throw TranslationModelStoreError.integrityFailure }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } else { try FileManager.default.moveItem(at: staged, to: destination) }
    }
    private static func failure(_ message: String) -> TranslationFailure { .init(code: .invalidConfiguration, message: message) }
}
