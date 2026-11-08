import Foundation
import NativTranslationKit
import XCTest

final class TranslationStockVoicePreparationTests: XCTestCase, @unchecked Sendable {
    func testReadOnlyVerificationDoesNotPrepareOrDownloadAReference() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do { _ = try await TranslationStockVoicePreparation.prepared(cache: cache); XCTFail("Unprepared reference accepted") }
        catch let failure as TranslationFailure { XCTAssertEqual(failure.code, .invalidConfiguration) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }

    func testAlreadyCancelledStockPreparationHasNoFilesystemOrNetworkEffects() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let gate = StockPreparationGate()
        let task = Task {
            await gate.wait()
            return try await TranslationStockVoicePreparation.prepare(cache: cache, fetch: { _, _ in
                XCTFail("Cancelled preparation attempted a download")
                return Data()
            })
        }
        task.cancel()
        await gate.open()
        do { _ = try await task.value; XCTFail("Cancelled preparation succeeded") }
        catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }

    func testInvalidReferenceNeverBecomesInstalledStockVoice() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        do {
            _ = try await TranslationStockVoicePreparation.prepare(cache: cache, fetch: { _, _ in Data("wrong recording".utf8) })
            XCTFail("Unverified reference became a stock voice")
        } catch TranslationModelStoreError.integrityFailure {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: TranslationStockVoicePreparation.location(cache: cache).path))
    }

    func testPinnedStockArtifactsInstallIdempotentlyAndRequireTheirLicense() async throws {
        guard let source = ProcessInfo.processInfo.environment["NATIV_STOCK_VOICE_FIXTURES"] else {
            throw XCTSkip("Set NATIV_STOCK_VOICE_FIXTURES to the separately downloaded pinned CC0 clips and LICENSE for the artifact test. No models are loaded.")
        }
        let fixtures = URL(fileURLWithPath: source)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let fetch: @Sendable (URL, Int64) async throws -> Data = { url, _ in
            try Data(contentsOf: fixtures.appendingPathComponent(url.lastPathComponent))
        }
        let prepared = try await TranslationStockVoicePreparation.prepare(cache: cache, fetch: fetch)
        XCTAssertEqual(prepared.sourceLanguage, "de")
        XCTAssertTrue(prepared.displayName.contains("CC0"))
        let wave = try TranslationWaveCodec.decode(Data(contentsOf: prepared.referenceURL))
        XCTAssertEqual(wave.format.sampleRate, 22050)
        XCTAssertEqual(try wave.format.duration(byteCount: wave.bytes.count), 7.499954648526077, accuracy: 0.000001)
        let same = try await TranslationStockVoicePreparation.prepare(cache: cache, fetch: { _, _ in
            XCTFail("Complete verified stock reference must be reused offline")
            return Data()
        })
        XCTAssertEqual(prepared.referenceURL, same.referenceURL)
        let license = prepared.referenceURL.deletingLastPathComponent().appendingPathComponent("LICENSE-CC0.txt")
        try Data("corrupt".utf8).write(to: license)
        do { _ = try await TranslationStockVoicePreparation.prepared(cache: cache); XCTFail("Missing provenance license was ignored") }
        catch let failure as TranslationFailure { XCTAssertEqual(failure.code, .invalidConfiguration) }
        let repaired = try await TranslationStockVoicePreparation.prepare(cache: cache, fetch: fetch)
        XCTAssertEqual(repaired.referenceURL, prepared.referenceURL)
    }
}

private actor StockPreparationGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { if !opened { await withCheckedContinuation { continuation = $0 } } }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}
