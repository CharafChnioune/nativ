import CryptoKit
import Foundation
import XCTest

final class TranslationModelStoreTests: XCTestCase {
    func testIncompleteOrCorruptArtifactIsNeverInstalled() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let expected = Data("complete model".utf8)
        let artifact = TranslationModelArtifact(
            filename: "model.gguf", size: Int64(expected.count),
            sha256: SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined()
        )
        let file = directory.appendingPathComponent(artifact.filename)
        XCTAssertFalse(try TranslationModelStore.verify(file: file, artifact: artifact))
        try Data("incomplete".utf8).write(to: file)
        XCTAssertFalse(try TranslationModelStore.verify(file: file, artifact: artifact))
        try Data(repeating: 0, count: expected.count).write(to: file)
        XCTAssertFalse(try TranslationModelStore.verify(file: file, artifact: artifact))
        try expected.write(to: file)
        XCTAssertTrue(try TranslationModelStore.verify(file: file, artifact: artifact))
    }

    func testArtifactManifestRejectsPathTraversalAndMissingProjector() throws {
        let invalid = TranslationModelArtifact(filename: "../outside.gguf", size: 1, sha256: String(repeating: "a", count: 64))
        XCTAssertThrowsError(try invalid.validate())
        let valid = TranslationModelArtifact(filename: "model.gguf", size: 1, sha256: String(repeating: "a", count: 64))
        XCTAssertNoThrow(try valid.validate())
        XCTAssertThrowsError(try TranslationModelManifest.Model(repository: "LiquidAI/model", revision: "main", artifacts: ["Q8_0": valid]).validate())
    }

    func testInstallLocationIsRevisionBoundAndContainsBothFiles() throws {
        let artifact = TranslationModelArtifact(filename: "model.gguf", size: 1, sha256: String(repeating: "a", count: 64))
        let projector = TranslationModelArtifact(filename: "projector.gguf", size: 2, sha256: String(repeating: "b", count: 64))
        let model = TranslationModelManifest.Model(repository: "LiquidAI/model", revision: String(repeating: "c", count: 40), artifacts: ["Q8_0": artifact, "projector": projector])
        try model.validate()
        let installation = try model.installation(in: URL(fileURLWithPath: "/cache"), quantization: "Q8_0")
        XCTAssertNotEqual(installation.modelURL, installation.projectorURL)
        XCTAssertTrue(installation.modelURL.path.contains(model.revision))
        XCTAssertThrowsError(try model.installation(in: URL(fileURLWithPath: "/cache"), quantization: "unknown"))
    }
}
