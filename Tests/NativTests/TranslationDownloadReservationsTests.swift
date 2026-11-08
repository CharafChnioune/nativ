import Foundation
import XCTest

final class TranslationDownloadReservationsTests: XCTestCase {
    func testSameVolumeMustFitFinalFilesAndTemporaryCopyAtOnce() throws {
        let capacity = HuggingFaceDownloadCapacity { _ in .init(volume: 1, freeBytes: 20) }
        XCTAssertThrowsError(try reservations(capacity, total: 15, largest: 10))
        // Rejected preparation must release the first successful reservation.
        let next = UUID()
        XCTAssertNoThrow(try capacity.reserve(next, bytes: 20, atPath: "/cache"))
        capacity.release(next)
    }

    func testExternalCacheCannotBypassFullSystemTemporaryVolume() throws {
        let capacity = HuggingFaceDownloadCapacity { path in
            path == "/cache" ? .init(volume: 2, freeBytes: 15) : .init(volume: 1, freeBytes: 9)
        }
        XCTAssertThrowsError(try reservations(capacity, total: 15, largest: 10))
        let next = UUID()
        XCTAssertNoThrow(try capacity.reserve(next, bytes: 15, atPath: "/cache"))
        capacity.release(next)
    }

    func testBothVolumesStayReservedUntilPreparationReleasesThem() throws {
        let capacity = HuggingFaceDownloadCapacity { path in
            path == "/cache" ? .init(volume: 2, freeBytes: 15) : .init(volume: 1, freeBytes: 10)
        }
        let active = try reservations(capacity, total: 15, largest: 10)
        XCTAssertThrowsError(try capacity.reserve(UUID(), bytes: 1, atPath: "/cache"))
        XCTAssertThrowsError(try capacity.reserve(UUID(), bytes: 1, atPath: "/temporary"))
        active.release()
        let destination = UUID(), temporary = UUID()
        XCTAssertNoThrow(try capacity.reserve(destination, bytes: 15, atPath: "/cache"))
        XCTAssertNoThrow(try capacity.reserve(temporary, bytes: 10, atPath: "/temporary"))
        capacity.release(destination); capacity.release(temporary)
    }

    private func reservations(_ capacity: HuggingFaceDownloadCapacity, total: Int64, largest: Int64) throws -> TranslationDownloadReservations {
        try .init(totalBytes: total, largestArtifactBytes: largest, cachePath: "/cache", temporaryPath: "/temporary",
                  reserve: { try capacity.reserve($0, bytes: $1, atPath: $2) }, release: { capacity.release($0) })
    }
}
