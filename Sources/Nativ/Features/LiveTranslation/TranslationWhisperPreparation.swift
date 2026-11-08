import CryptoKit
import Darwin
import Foundation
import NativTranslationKit

/// The official MLX turbo conversion omits the HF processor required by mlx-audio.
/// Prepare a versioned composite using verified OpenAI tokenizer files; never alter a source snapshot.
enum TranslationWhisperPreparation {
    static let modelRevision = "a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb"
    static let processorRevision = "41f01f3fe87f28c78e2fbf8b568835947dd65ed9"
    static let weight = TranslationModelArtifact(filename: "weights.safetensors", size: 1_613_977_612, sha256: "951ed3fc1203e6a62467abb2144a96ce7eafca8fa77e3704fdb8635ff3e7f8a6")
    static let config = TranslationModelArtifact(filename: "config.json", size: 268, sha256: "b34fc29e4e11e0a25e812775dd67f4dd16fc2c8eb43d28ae25ff7d660ecb6379")
    static let artifacts: [TranslationModelArtifact] = [
        .init(filename: "preprocessor_config.json", size: 340, sha256: "7ccc62c6f2765af1f3b46c00c9b5894426835a05021c8b9c01eecb6dfb542711"),
        .init(filename: "tokenizer_config.json", size: 282843, sha256: "844b642c73a91359722f47b35705f7174686df33d252695d8572cf9ac03a6389"),
        .init(filename: "tokenizer.json", size: 2710337, sha256: "297b13372ac43916285644fb9687add3cc62ee2a1adb60da3dc25cc94c1871fd"),
        .init(filename: "vocab.json", size: 1036558, sha256: "e2aa043ef015641d363d8288e7c241c85e36a5c761fb303598e0710233344387"),
        .init(filename: "merges.txt", size: 493869, sha256: "2df2990a395e35e8dfbc7511e08c12d56018d8d04691e0133e5d63b21e154dc6"),
        .init(filename: "normalizer.json", size: 52666, sha256: "bf1c507dc8724ca9cf9903640dacfb69dae2f00edee4f21ceba106a7392f26dd"),
        .init(filename: "added_tokens.json", size: 34648, sha256: "3c51f66c4c21f9e126970078f11ae77a78c74aee8df606ee9daba86e467108e0"),
        .init(filename: "special_tokens_map.json", size: 2186, sha256: "baea4ea09372eb4fca86b4e4346139fd73cb807d5087e9de0948e971739c3e74"),
        .init(filename: "generation_config.json", size: 3772, sha256: "cce11bfe3aaa6ae9e072ea2637caaec8795e68d9b67e655a5af16ee509681a4c"),    ]
    static func location(cache: URL) -> URL {
        cache.appendingPathComponent("nativ-translation/cascade/whisper/" + modelRevision + "-" + processorRevision, isDirectory: true)
    }
    @concurrent static func preparedModel(snapshot: URL, cache: URL) async throws -> URL {
        try Task.checkCancellation()
        guard snapshot.lastPathComponent == modelRevision else { throw failure("The selected Whisper snapshot differs from the tested revision. Prepare the pinned model explicitly.") }
        let directory = location(cache: cache)
        let weightURL = snapshot.appendingPathComponent(weight.filename).resolvingSymlinksInPath()
        guard try TranslationModelStore.verify(file: weightURL, artifact: weight),
              try TranslationModelStore.verify(file: directory.appendingPathComponent(config.filename), artifact: config) else {
            throw failure("Prepare the pinned Whisper model and tokenizer before starting the cascade.")
        }
        for artifact in artifacts {
            guard try TranslationModelStore.verify(file: directory.appendingPathComponent(artifact.filename), artifact: artifact) else {
                throw failure("Whisper tokenizer preparation is incomplete. Use Prepare Whisper tokenizer; no input has been captured.")
            }
        }
        guard directory.appendingPathComponent(weight.filename).resolvingSymlinksInPath() == weightURL else {
            throw failure("The prepared Whisper weight binding changed. Prepare the tokenizer again.")
        }
        return directory
    }
    @concurrent static func prepare(snapshot: URL, cache: URL) async throws -> URL {
        try Task.checkCancellation()
        guard snapshot.lastPathComponent == modelRevision else { throw failure("Install the pinned Whisper turbo revision before preparing its tokenizer.") }
        let weightURL = snapshot.appendingPathComponent(weight.filename).resolvingSymlinksInPath()
        let configURL = snapshot.appendingPathComponent(config.filename).resolvingSymlinksInPath()
        guard try TranslationModelStore.verify(file: weightURL, artifact: weight),
              try TranslationModelStore.verify(file: configURL, artifact: config) else {
            throw failure("The selected Whisper weights or configuration failed integrity verification. Prepare the complete pinned model first.")
        }
        let directory = location(cache: cache)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let missing = try artifacts.filter { try !TranslationModelStore.verify(file: directory.appendingPathComponent($0.filename), artifact: $0) }
        let reservation = UUID()
        try HuggingFaceDownloadCapacity.shared.reserve(reservation, bytes: 2 * missing.reduce(0) { $0 + $1.size }, atPath: directory.path)
        defer { HuggingFaceDownloadCapacity.shared.release(reservation) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for artifact in missing {
            try Task.checkCancellation()
            let url = URL(string: "https://huggingface.co/openai/whisper-large-v3-turbo/resolve/" + processorRevision + "/" + artifact.filename)!
            let (bytes, response) = try await session.bytes(from: url)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw failure("Whisper tokenizer download failed. Check the connection and retry.") }
            var data = Data(); data.reserveCapacity(Int(artifact.size))
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < artifact.size else { throw failure("Whisper tokenizer download exceeded its pinned size.") }
                data.append(byte)
            }
            guard data.count == artifact.size,
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == artifact.sha256 else {
                throw failure("Whisper tokenizer integrity verification failed. The invalid file was not installed.")
            }
            try data.write(to: directory.appendingPathComponent(artifact.filename), options: .atomic)
        }
        try Task.checkCancellation()
        try Data(contentsOf: configURL).write(to: directory.appendingPathComponent(config.filename), options: .atomic)
        let staged = directory.appendingPathComponent(UUID().uuidString + ".partial")
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.createSymbolicLink(at: staged, withDestinationURL: weightURL)
        let destination = directory.appendingPathComponent(weight.filename)
        guard staged.path.withCString({ source in destination.path.withCString { Darwin.rename(source, $0) } }) == 0 else {
            throw failure("Could not install the prepared Whisper weight binding.")
        }
        return try await preparedModel(snapshot: snapshot, cache: cache)
    }
    private static func failure(_ message: String) -> TranslationFailure { .init(code: .invalidConfiguration, message: message) }
}

