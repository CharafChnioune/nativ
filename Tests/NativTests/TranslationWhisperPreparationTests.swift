import Foundation
import XCTest
#if canImport(TranslationHost)
@testable import TranslationHost
#endif
import NativTranslationKit

final class TranslationWhisperPreparationTests: XCTestCase {
    func testDifferentRevisionDoesNotCreatePreparedFiles() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            _ = try await TranslationWhisperPreparation.prepare(snapshot: cache.appendingPathComponent("main"), cache: cache)
            XCTFail("Mutable revisions must not be prepared as a pinned model")
        } catch let error as TranslationFailure { XCTAssertEqual(error.code, .invalidConfiguration) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }
    func testAlreadyCancelledPreparationDoesNotTouchTheCache() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let gate = PreparationTestGate()
        let task = Task {
            await gate.wait()
            return try await TranslationWhisperPreparation.prepare(snapshot: cache.appendingPathComponent(TranslationWhisperPreparation.modelRevision), cache: cache)
        }
        task.cancel(); await gate.release()
        do { _ = try await task.value; XCTFail("Cancelled preparation returned a model") }
        catch is CancellationError { }
        catch { XCTFail("Expected immediate cancellation, received \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }
    func testPinnedArtifactsPrepareWithoutChangingSourceSnapshot() async throws {
        guard let sourcePath = ProcessInfo.processInfo.environment["NATIV_CASCADE_WHISPER_SOURCE"],
              let cachePath = ProcessInfo.processInfo.environment["NATIV_CASCADE_ASSET_CACHE"] else {
            throw XCTSkip("Opt-in real artifact smoke requires a downloaded pinned Whisper snapshot and a scratch cache path.")
        }
        let source = URL(fileURLWithPath: sourcePath); let cache = URL(fileURLWithPath: cachePath)
        let before = try FileManager.default.contentsOfDirectory(atPath: source.path).sorted()
        let prepared = try await TranslationWhisperPreparation.prepare(snapshot: source, cache: cache)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: source.path).sorted(), before)
        let verified = try await TranslationWhisperPreparation.preparedModel(snapshot: source, cache: cache)
        XCTAssertEqual(prepared, verified)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.appendingPathComponent("tokenizer.json").path))
        XCTAssertEqual(prepared.appendingPathComponent("weights.safetensors").resolvingSymlinksInPath(), source.appendingPathComponent("weights.safetensors").resolvingSymlinksInPath())
    }
}
private actor PreparationTestGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { if !released { await withCheckedContinuation { continuation = $0 } } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
