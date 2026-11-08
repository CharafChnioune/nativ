import Darwin
import Foundation
import NativServerKit
import XCTest

final class TranslationCascadeRuntimeTests: XCTestCase, @unchecked Sendable {
    func testOwnedRuntimeCannotInheritPreloadedModelsCloudCredentialsOrRemoteBind() {
        let environment = TranslationCascadeRuntime.sanitizedEnvironment([
            "PATH": "/usr/bin", "HOME": "/Users/example", "MLX_VLM_SERVER_API_KEY": "old",
            "MLX_VLM_PRELOAD_MODEL": "chat-model", "HF_TOKEN": "secret", "OPENAI_API_KEY": "secret",
            "PYTHONPATH": "/tmp/injected", "HF_HUB_OFFLINE": "0", "APC_ENABLED": "1",
            "APC_DISK_ENABLED": "1", "MLX_PLATFORM_ANALYTICS_DB_PATH": "/tmp/persistent.sqlite",
            "HTTPS_PROXY": "http://example.com", "MTL_DEBUG_LAYER": "1",
        ], bearerToken: "fresh-private-key")
        XCTAssertEqual(environment["MLX_VLM_SERVER_API_KEY"], "fresh-private-key")
        XCTAssertEqual(environment["HF_HUB_OFFLINE"], "1")
        XCTAssertEqual(environment["TRANSFORMERS_OFFLINE"], "1")
        XCTAssertEqual(environment["APC_ENABLED"], "0")
        XCTAssertEqual(environment["APC_DISK_ENABLED"], "0")
        XCTAssertEqual(environment["MLX_PLATFORM_ANALYTICS_DB_PATH"], ":memory:")
        XCTAssertEqual(environment["HOME"], "/Users/example")
        for key in ["HF_TOKEN", "OPENAI_API_KEY", "PYTHONPATH", "MLX_VLM_PRELOAD_MODEL", "HTTPS_PROXY", "MTL_DEBUG_LAYER"] {
            XCTAssertNil(environment[key])
        }
        XCTAssertEqual(TranslationCascadeRuntime.arguments, ["--host", "127.0.0.1", "--port", "0"])
    }

    func testReadinessRequiresActualUvicornLoopbackListenerAndCompletePort() {
        XCTAssertEqual(TranslationCascadeRuntime.listenerPort(in: "INFO: Uvicorn running on http://127.0.0.1:49152 (Press CTRL+C to quit)\n"), 49152)
        XCTAssertNil(TranslationCascadeRuntime.listenerPort(in: "Uvicorn running on http://0.0.0.0:49152\n"))
        XCTAssertNil(TranslationCascadeRuntime.listenerPort(in: "Uvicorn running on http://127.0.0.1:70000\n"))
        XCTAssertNil(TranslationCascadeRuntime.listenerPort(in: "Uvicorn running on http://127.0.0.1:80\n"))
        XCTAssertNil(TranslationCascadeRuntime.listenerPort(in: "Uvicorn running on http://127.0.0.1:49152unexpected\n"))
        XCTAssertNil(TranslationCascadeRuntime.listenerPort(in: "another server on http://127.0.0.1:49152\n"))
    }

    func testReadinessWaitsForAnActualDelimiterAcrossPortFragments() {
        let prefix = "INFO: Uvicorn running on http://127.0.0.1:"
        XCTAssertNil(TranslationCascadeRuntime.listenerPort(in: prefix + "4915"))
        XCTAssertNil(TranslationCascadeRuntime.listenerPort(in: prefix + "49152"))
        XCTAssertEqual(TranslationCascadeRuntime.listenerPort(in: prefix + "49152 "), 49152)
        XCTAssertEqual(TranslationCascadeRuntime.listenerPort(in: prefix + "49152\n"), 49152)
    }

    func testStopWaitsForBundledSupervisorToReapTermIgnoringChildBeforeRestart() async throws {
        let fixture = try CascadeSupervisorFixture()
        let runtime = TranslationCascadeRuntime(executable: fixture.executable, readinessTimeout: 60)
        let firstStart = Task { try await runtime.start() }
        var nextStart: Task<TranslationCascadeRuntime.Endpoint, Error>?
        // This watchdog is outside the runtime actor. Even a broken shutdown
        // barrier cannot leave the test's TERM-ignoring fixture alive indefinitely.
        let watchdog = Task.detached {
            do {
                try await Task.sleep(for: .seconds(15))
                fixture.markWatchdogFired()
                fixture.forceCleanup()
            } catch {}
        }
        defer {
            firstStart.cancel(); nextStart?.cancel(); watchdog.cancel()
            fixture.forceCleanup()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        var testError: Error?
        do {
            let first = try await fixture.waitForRecords(1)[0]
            XCTAssertTrue(CascadeSupervisorFixture.isAlive(first.child))
            XCTAssertTrue(CascadeSupervisorFixture.isAlive(first.supervisor))
            let state = CascadeStopObservation()
            let stopping = Task {
                await runtime.stop()
                let childAlive = CascadeSupervisorFixture.isAlive(first.child)
                let supervisorAlive = CascadeSupervisorFixture.isAlive(first.supervisor)
                await state.didReturn()
                return (childAlive, supervisorAlive)
            }
            // stop clears its Process reference synchronously before awaiting
            // cleanup, so a new start now must wait behind the shutdown barrier.
            try await CascadeSupervisorFixture.waitUntil("stop admission") { !(await runtime.isRunning) }
            nextStart = Task { try await runtime.start() }
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertTrue(CascadeSupervisorFixture.isAlive(first.child))
            XCTAssertEqual(fixture.records().count, 1, "A replacement must wait while the previous child is alive")
            let returnedEarly = await state.returned
            XCTAssertFalse(returnedEarly)
            let (childAliveAtReturn, supervisorAliveAtReturn) = await stopping.value
            XCTAssertFalse(childAliveAtReturn, "stop returned while the supervisor's Python child was still alive")
            XCTAssertFalse(supervisorAliveAtReturn, "stop returned before its supervisor exited")
            let second = try await fixture.waitForRecords(2)[1]
            XCTAssertNotEqual(first.child, second.child)
            XCTAssertFalse(second.previousChildAlive, "New admission overlapped the previous Python child")
            XCTAssertFalse(second.previousSupervisorAlive, "New admission overlapped the previous supervisor")
        } catch { testError = error }

        firstStart.cancel(); nextStart?.cancel()
        // Kill only children recorded by this private fixture. Let the owned C
        // supervisor reap them before awaiting the runtime cleanup, including RED runs.
        fixture.killChildren()
        await runtime.stop()
        _ = await firstStart.result
        if let nextStart { _ = await nextStart.result }
        try await CascadeSupervisorFixture.waitUntil("fixture cleanup") {
            fixture.records().allSatisfy { !CascadeSupervisorFixture.isAlive($0.child) && !CascadeSupervisorFixture.isAlive($0.supervisor) }
        }
        XCTAssertFalse(fixture.watchdogFired, "External fixture watchdog had to break a stuck lifecycle")
        if let testError { throw testError }
    }

    func testEarlyExitDoesNotLeaveAnOwnedRuntime() async throws {
        let runtime = TranslationCascadeRuntime(executable: URL(fileURLWithPath: "/usr/bin/false"), readinessTimeout: 1)
        do { _ = try await runtime.start(); XCTFail("The false executable cannot start a runtime") }
        catch {}
        let running = await runtime.isRunning
        XCTAssertFalse(running)
        await runtime.stop()
        try await runtime.unloadModels()
    }
}

private actor CascadeStopObservation {
    private(set) var returned = false
    func didReturn() { returned = true }
}

private final class CascadeSupervisorFixture: @unchecked Sendable {
    struct Record: Sendable {
        let child: pid_t
        let supervisor: pid_t
        let previousChildAlive: Bool
        let previousSupervisorAlive: Bool
    }
    enum Failure: Error { case timeout(String) }
    let directory: URL
    let executable: URL
    private let marker: URL
    private let lock = NSLock()
    private var fired = false
    var watchdogFired: Bool { lock.withLock { fired } }
    func markWatchdogFired() { lock.withLock { fired = true } }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("nativ-owned-supervisor-" + UUID().uuidString, isDirectory: true)
        executable = directory.appendingPathComponent("bin/mlx-vlm-server")
        marker = directory.appendingPathComponent("owned-pids.txt")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let python = directory.appendingPathComponent("python/bin/python3")
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        // This is the shipped C supervisor, not a replacement implementation.
        try FileManager.default.copyItem(at: Nativ.executableURL(), to: executable)
        let quotedMarker = "'" + marker.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = """
        #!/bin/sh
        trap '' TERM
        previous_child_alive=0
        previous_supervisor_alive=0
        if [ -f \(quotedMarker) ]; then
            IFS=' ' read -r previous_child previous_supervisor old_child_state old_supervisor_state < \(quotedMarker)
            if kill -0 "$previous_child" 2>/dev/null; then previous_child_alive=1; fi
            if kill -0 "$previous_supervisor" 2>/dev/null; then previous_supervisor_alive=1; fi
        fi
        printf '%s %s %s %s\\n' "$$" "$PPID" "$previous_child_alive" "$previous_supervisor_alive" >> \(quotedMarker)
        exec /bin/sleep 60
        """
        try Data(script.utf8).write(to: python)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: python.path)
    }
    func records() -> [Record] {
        guard let text = try? String(contentsOf: marker, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ")
            guard fields.count == 4, let child = pid_t(fields[0]), let supervisor = pid_t(fields[1]),
                  child > 1, supervisor > 1, child != getpid(), supervisor != getpid() else { return nil }
            return .init(child: child, supervisor: supervisor, previousChildAlive: fields[2] == "1", previousSupervisorAlive: fields[3] == "1")
        }
    }
    func waitForRecords(_ count: Int) async throws -> [Record] {
        try await Self.waitUntil("fixture launch \(count)") { self.records().count >= count }
        return records()
    }
    static func waitUntil(_ label: String, predicate: @escaping @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure.timeout(label)
    }
    static func isAlive(_ pid: pid_t) -> Bool { Darwin.kill(pid, 0) == 0 || errno == EPERM }
    func killChildren() { for record in records() where Self.isAlive(record.child) { _ = Darwin.kill(record.child, SIGKILL) } }
    func forceCleanup() {
        killChildren()
        for record in records() where Self.isAlive(record.supervisor) { _ = Darwin.kill(record.supervisor, SIGKILL) }
    }
}
