import Foundation
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
