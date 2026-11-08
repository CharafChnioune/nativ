import Darwin
import XCTest
@testable import Nativ

final class GenerationComputeLeaseTests: XCTestCase {
    func testSharedNativeOwnersAndInheritedDescriptorRetainExclusion() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("compute.lock")
        let first = try GenerationComputeLease.acquire(at: url)
        let second = try GenerationComputeLease.acquire(at: url)
        let inherited = try first.inheritedFileHandle()
        let outsider = Darwin.open(url.path, O_RDWR)
        defer { Darwin.close(outsider) }
        XCTAssertNotEqual(generationFlock(outsider, LOCK_EX | LOCK_NB), 0)
        first.close(); second.close()
        XCTAssertNotEqual(generationFlock(outsider, LOCK_EX | LOCK_NB), 0)
        try inherited.close()
        XCTAssertEqual(generationFlock(outsider, LOCK_EX | LOCK_NB), 0)
        _ = generationFlock(outsider, LOCK_UN)
    }
    func testOwnedProcessStdinRetainsLeaseUntilExit() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("compute.lock")
        let lease = try GenerationComputeLease.acquire(at: url)
        let inherited = try lease.inheritedFileHandle()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["0.2"]
        child.standardInput = inherited
        try child.run()
        try inherited.close(); lease.close()
        let outsider = Darwin.open(url.path, O_RDWR)
        defer { Darwin.close(outsider) }
        XCTAssertNotEqual(generationFlock(outsider, LOCK_EX | LOCK_NB), 0)
        child.waitUntilExit()
        XCTAssertEqual(generationFlock(outsider, LOCK_EX | LOCK_NB), 0)
        _ = generationFlock(outsider, LOCK_UN)
    }

}
