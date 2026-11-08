import CryptoKit
import Foundation
import NativTranslationKit

/// Explicitly prepared, attributed stock conditioning. It never selects a TTS provider or starts inference.
enum TranslationStockVoicePreparation {
    struct Prepared: Sendable {
        let referenceURL: URL
        let displayName: String
        let sourceLanguage: String
        let transcript: String
    }
    static let repository = "thorstenMueller/Thorsten-Voice"
    static let revision = "29d0c153c55d8ffaa0ebf8ed1ecc879bff9fdf27"
    static let displayName = "Thorsten · German recording · CC0"
    static let transcript = "Europa und Asien zusammengenommen wird auch als Eurasien bezeichnet. Eure Schoko-Bonbons sind sagenhaft lecker!"
    static let sourceFiles: [(path: String, artifact: TranslationModelArtifact)] = [
        ("docs/samples/sample03-gt.wav", .init(filename: "sample03-gt.wav", size: 217858,
            sha256: "1892697190fe190f41037a1c5ac4e02b60d6f4a490408ab3b1b88a490b3b6750")),
        ("docs/samples/sample01-gt.wav", .init(filename: "sample01-gt.wav", size: 113782,
            sha256: "09fb12ff218399a4e4eab6c592eb36bbe4743db9ce5249742129bc3add734ca1")),
        ("LICENSE", .init(filename: "LICENSE-CC0.txt", size: 6555,
            sha256: "36ffd9dc085d529a7e60e1276d73ae5a030b020313e6c5408593a6ae2af39673"))
    ]
    static let output = TranslationModelArtifact(filename: "thorsten-stock-de.wav", size: 330792,
        sha256: "38cad5dc655d2749fab0a785c11848c0d72607c4bce07bec6fcbfaa3dab19f59")

    static func location(cache: URL) -> URL {
        cache.appendingPathComponent("nativ-translation/cascade/stock-voices/thorsten/" + revision, isDirectory: true)
    }

    @concurrent static func prepared(cache: URL) async throws -> Prepared {
        try Task.checkCancellation()
        let directory = location(cache: cache)
        for artifact in sourceFiles.map(\.artifact) + [output] {
            guard try TranslationModelStore.verify(file: directory.appendingPathComponent(artifact.filename), artifact: artifact) else {
                throw TranslationFailure(code: .invalidConfiguration,
                    message: "Prepare the Thorsten stock reference explicitly before selecting it. An audio or license artifact is missing or failed verification.")
            }
        }
        return .init(referenceURL: directory.appendingPathComponent(output.filename), displayName: displayName,
                     sourceLanguage: "de", transcript: transcript)
    }

    /// The injectable fetcher receives a hard byte limit; default fetch never accumulates an oversized response.
    @concurrent static func prepare(
        cache: URL,
        fetch: @escaping @Sendable (URL, Int64) async throws -> Data = download
    ) async throws -> Prepared {
        try Task.checkCancellation()
        if let existing = try? await prepared(cache: cache) { return existing }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let directory = location(cache: cache)
        let artifacts = sourceFiles.map(\.artifact) + [output]
        let reservation = try TranslationDownloadReservations(
            totalBytes: artifacts.reduce(0) { $0 + $1.size }, largestArtifactBytes: artifacts.map(\.size).max() ?? 0,
            cachePath: cache.path, temporaryPath: cache.path,
            reserve: { try HuggingFaceDownloadCapacity.shared.reserve($0, bytes: $1, atPath: $2) },
            release: { HuggingFaceDownloadCapacity.shared.release($0) })
        defer { reservation.release() }
        var files: [String: Data] = [:]
        for source in sourceFiles {
            try Task.checkCancellation()
            let url = URL(string: "https://raw.githubusercontent.com/\(repository)/\(revision)/\(source.path)")!
            let data = try await fetch(url, source.artifact.size)
            try verify(data, artifact: source.artifact)
            files[source.artifact.filename] = data
        }
        var pcm = Data()
        let format = TranslationPCMFormat(sampleRate: 22050, channels: 1, encoding: .signedInt16LittleEndian)
        for source in sourceFiles where source.path.hasSuffix(".wav") {
            let decoded = try TranslationWaveCodec.decode(files[source.artifact.filename]!)
            guard decoded.format == format else { throw TranslationModelStoreError.integrityFailure }
            pcm.append(decoded.bytes)
        }
        let reference = try TranslationWaveCodec.encode(pcm, format: format)
        try verify(reference, artifact: output)
        files[output.filename] = reference
        try Task.checkCancellation()
        let parent = directory.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".\(UUID().uuidString).partial", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        for (name, data) in files {
            try Task.checkCancellation()
            try data.write(to: staging.appendingPathComponent(name), options: .atomic)
        }
        let notice = """
        Thorsten stock conditioning reference — German source audio, CC0-1.0.
        Recorded and released by Thorsten Müller / Thorsten-Voice.
        Source: https://github.com/\(repository)/tree/\(revision)
        Original recordings: docs/samples/sample03-gt.wav then docs/samples/sample01-gt.wav.
        Modification: concatenated their original PCM samples, with a new standard WAV header; no resynthesis.
        Source language: German. Cross-language accent, naturalness and voice quality are unqualified.
        This prepares conditioning only. It does not select Chatterbox, replace LFM3, or imply endorsement.
        License: see LICENSE-CC0.txt. Provenance: docs/audio_compare.md in the pinned source repository.
        """
        try Data(notice.utf8).write(to: staging.appendingPathComponent("NOTICE.txt"), options: .atomic)
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: directory.path) {
            _ = try FileManager.default.replaceItemAt(directory, withItemAt: staging)
        } else { try FileManager.default.moveItem(at: staging, to: directory) }
        return try await prepared(cache: cache)
    }

    private static func verify(_ data: Data, artifact: TranslationModelArtifact) throws {
        guard Int64(data.count) == artifact.size,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == artifact.sha256 else {
            throw TranslationModelStoreError.integrityFailure
        }
    }

    @concurrent private static func download(_ url: URL, _ limit: Int64) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw TranslationModelStoreError.downloadFailed }
        var data = Data()
        data.reserveCapacity(Int(limit))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard Int64(data.count) < limit else { throw TranslationModelStoreError.integrityFailure }
            data.append(byte)
        }
        return data
    }
}
