import CryptoKit
import Foundation
import NativServerKit

actor GenerationMediaCache {
    static let shared = GenerationMediaCache()
    private let root: URL
    private var downloads: [String: Task<URL, Error>] = [:]
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent(NativBuildIdentity.applicationSupportDirectoryName).appendingPathComponent("Generated Media", isDirectory: true)
    }
    nonisolated static func key(_ string: String) -> String { SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined() }
    func cachedURL(for asset: GenerationAsset) -> URL? {
        let url = destination(asset)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
    func acquire(asset: GenerationAsset, client: NativGenerationClient) async throws -> URL {
        guard asset.storeID == client.connection.storeID else { throw GenerationJournalError.identityMismatch }
        let key = Self.key(asset.storeID + ":" + asset.assetID + ":" + asset.sha256)
        if let task = downloads[key] { return try await task.value }
        let destination = destination(asset)
        let task = Task {
            if FileManager.default.fileExists(atPath: destination.path), try Self.validate(destination, asset: asset) { return destination }
            let partial = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".partial")
            defer { try? FileManager.default.removeItem(at: partial) }
            _ = try await client.download(assetID: asset.assetID, to: partial)
            guard try Self.validate(partial, asset: asset) else {
                throw GenerationAPIError(code: "corrupt_media_cache", message: "The downloaded original did not match the server's content digest. Download it again.", retryable: true)
            }
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: partial, to: destination)
            return destination
        }
        downloads[key] = task
        defer { downloads[key] = nil }
        return try await task.value
    }
    private func destination(_ asset: GenerationAsset) -> URL {
        let ext = asset.modality == .video ? "mp4" : (asset.mimeType == "audio/mpeg" ? "mp3" : asset.mimeType == "audio/flac" ? "flac" : "wav")
        return root.appendingPathComponent(Self.key(asset.storeID), isDirectory: true)
            .appendingPathComponent(Self.key(asset.assetID + ":" + asset.sha256) + "." + ext)
    }
    private nonisolated static func validate(_ url: URL, asset: GenerationAsset) throws -> Bool {
        let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        guard Int64(size) == asset.byteSize, size > 0 else { return false }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var digest = SHA256()
        while let bytes = try file.read(upToCount: 1024 * 1024), !bytes.isEmpty { digest.update(data: bytes) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined() == asset.sha256.lowercased()
    }
}
