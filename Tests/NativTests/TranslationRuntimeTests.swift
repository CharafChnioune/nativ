import Foundation
import XCTest

@testable import NativTranslationKit

final class TranslationRuntimeTests: XCTestCase, @unchecked Sendable {
  func testInheritedRuntimeSettingsCannotEnableAgentOrRemoteBinding() throws {
    let environment = TranslationRuntimeController.sanitizedEnvironment(
      [
        "PATH": "/usr/bin", "LLAMA_HOST": "0.0.0.0", "LLAMA_API_KEY": "inherited",
        "LLAMA_MCP_SERVERS": "bad", "HF_TOKEN": "private", "OPENAI_API_KEY": "private",
      ], bearerToken: "fresh")
    XCTAssertEqual(environment["PATH"], "/usr/bin")
    XCTAssertEqual(environment["LLAMA_API_KEY"], "fresh")
    XCTAssertNil(environment["LLAMA_HOST"])
    XCTAssertNil(environment["LLAMA_MCP_SERVERS"])
    XCTAssertNil(environment["HF_TOKEN"])
    XCTAssertNil(environment["OPENAI_API_KEY"])
  }
  func testReadinessAcceptsOnlyLoopbackListener() {
    XCTAssertEqual(
      TranslationRuntimeController.listenerPort(
        in: "server is listening on http://127.0.0.1:49153\n"), 49153)
    XCTAssertNil(TranslationRuntimeController.listenerPort(in: "http://0.0.0.0:49153"))
    XCTAssertNil(TranslationRuntimeController.listenerPort(in: "listening on http://127.0.0.1:49"))
    XCTAssertNil(TranslationRuntimeController.listenerPort(in: "listening on http://127.0.0.1:0"))
    XCTAssertNil(
      TranslationRuntimeController.listenerPort(in: "listening on http://127.0.0.1:70000"))
  }
  func testArgumentsKeepOneSlotAndDisableAgent() throws {
    let args = try TranslationRuntimeController.arguments(
      model: URL(fileURLWithPath: "/tmp/model name.gguf"),
      projector: URL(fileURLWithPath: "/tmp/projector.gguf"), contextSize: 4096)
    XCTAssertTrue(args.contains("/tmp/model name.gguf"))
    XCTAssertEqual(
      Array(args[args.firstIndex(of: "--host")!...].prefix(2)), ["--host", "127.0.0.1"])
    XCTAssertEqual(
      Array(args[args.firstIndex(of: "--parallel")!...].prefix(2)), ["--parallel", "1"])
    XCTAssertTrue(args.contains("--no-agent"))
    XCTAssertTrue(args.contains("--no-webui"))
    XCTAssertThrowsError(
      try TranslationRuntimeController.arguments(
        model: URL(fileURLWithPath: "/tmp/m"), projector: URL(fileURLWithPath: "/tmp/p"),
        contextSize: 0))
  }
  func testEarlyCrashFailsAndLeavesNoOwnedProcess() async throws {
    let controller = TranslationRuntimeController(readinessTimeout: 1)
    do {
      _ = try await controller.start(
        executable: URL(fileURLWithPath: "/usr/bin/false"),
        model: URL(fileURLWithPath: "/usr/bin/false"),
        projector: URL(fileURLWithPath: "/usr/bin/false"))
      XCTFail("Expected runtime failure")
    } catch {}
    let running = await controller.isRunning
    XCTAssertFalse(running)
    await controller.stop()
  }
}

extension TranslationRuntimeTests {
  /// Opt-in technical integration, not a voice-quality or end-to-end latency benchmark.
  func testExplicitLocalRuntimeIntegration() async throws {
    guard let path = ProcessInfo.processInfo.environment["NATIV_LFM_TEST_ROOT"] else {
      throw XCTSkip(
        "Set NATIV_LFM_TEST_ROOT to the verified runtime/model probe directory to run real inference."
      )
    }
    let root = URL(fileURLWithPath: path)
    let controller = TranslationRuntimeController()
    do {
      let endpoint = try await controller.start(
        executable: root.appendingPathComponent("runtime/bin/llama-server"),
        model: root.appendingPathComponent("models/LFM3-Omni-2B-Q8_0.gguf"),
        projector: root.appendingPathComponent("models/mmproj-LFM3-Omni-2B-Q8_0.gguf"))
      let again = try await controller.start(
        executable: root.appendingPathComponent("runtime/bin/llama-server"),
        model: root.appendingPathComponent("models/LFM3-Omni-2B-Q8_0.gguf"),
        projector: root.appendingPathComponent("models/mmproj-LFM3-Omni-2B-Q8_0.gguf"))
      XCTAssertEqual(endpoint.baseURL, again.baseURL)
      let bytes = try Self.fixturePCM(
        root.appendingPathComponent("probes/q8-fixed/synthetic-nl.wav"))
      for mode in [LFM3RealtimeBackend.Mode.direct, .twoPass] {
        let backend = LFM3RealtimeBackend(endpoint: endpoint, mode: mode)
        let caps = try await backend.prepare(
          configuration: .init(
            languagePair: .init(source: "nl", target: "en"), outputMode: .speechAndCaptions,
            provider: mode == .direct ? .lfm3OmniDirect : .lfm3OmniTwoPass))
        XCTAssertEqual(caps.inputFormat?.sampleRate, 16000)
        XCTAssertTrue(caps.qualifiedTranslationPairs.isEmpty)
        let sid = TranslationSessionID()
        let turn = TranslationTurnID()
        let generation = TranslationGeneration(1)
        let stream = try await backend.start(sessionID: sid, generation: generation)
        for offset in stride(from: 0, to: bytes.count, by: 3200) {
          try await backend.send(
            frame: .init(
              bytes: Data(bytes[offset..<min(offset + 3200, bytes.count)]),
              format: caps.inputFormat!, captureTimestampNanoseconds: 0,
              sequence: UInt64(offset / 3200), sourceID: "original-synthetic-fixture",
              sessionID: sid, turnID: turn, generation: generation))
        }
        let begin = ContinuousClock.now
        try await backend.commit(turnID: turn)
        var audioBytes = 0
        var completed = false
        var firstAudio: Duration?
        for try await event in stream {
          switch event.payload {
          case .audio(let chunk):
            if firstAudio == nil { firstAudio = begin.duration(to: .now) }
            XCTAssertTrue(chunk.committed)
            XCTAssertEqual(
              chunk.format.encoding,
              mode == .direct ? .signedInt16LittleEndian : .float32LittleEndian)
            XCTAssertEqual(chunk.format.sampleRate, 24000)
            audioBytes += chunk.bytes.count
          case .turnCompleted: completed = true
          default: break
          }
          if completed { break }
        }
        XCTAssertTrue(completed)
        XCTAssertGreaterThan(audioBytes, 0)
        print(
          "LFM Swift technical integration mode=\(mode) receivedAudioBytes=\(audioBytes) commitToFirstReceivedAudio=\(String(describing: firstAudio)); not acoustic latency or quality qualification"
        )
        await backend.stop()
        let warm = await controller.isRunning
        XCTAssertTrue(warm)
      }
      await controller.stop()
      let stopped = await controller.isRunning
      XCTAssertFalse(stopped)
    } catch {
      await controller.stop()
      throw error
    }
  }
  private static func fixturePCM(_ url: URL) throws -> Data {
    let data = try Data(contentsOf: url)
    guard data.count >= 12, String(decoding: data.prefix(4), as: UTF8.self) == "RIFF" else {
      throw NSError(domain: "Fixture", code: 1)
    }
    var cursor = 12
    var valid = false
    while cursor + 8 <= data.count {
      let name = String(decoding: data[cursor..<cursor + 4], as: UTF8.self)
      let count = Int(
        data.withUnsafeBytes {
          UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: cursor + 4, as: UInt32.self))
        })
      let start = cursor + 8
      guard count <= data.count - start else { break }
      if name == "fmt ", count >= 16 {
        valid = data[start] == 1 && data[start + 2] == 1 && data[start + 14] == 16
        let rate = data.withUnsafeBytes {
          UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: start + 4, as: UInt32.self))
        }
        valid = valid && rate == 16000
      }
      if name == "data", valid { return Data(data[start..<start + count]) }
      cursor = start + count + count % 2
    }
    throw NSError(domain: "Fixture", code: 2)
  }
}

extension TranslationRuntimeTests {
  func testReadinessTimeoutStopsOnlyOwnedChild() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = directory.appendingPathComponent("helper")
    try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: fixture)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
    let unrelated = Process()
    unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
    unrelated.arguments = ["30"]
    try unrelated.run()
    defer { if unrelated.isRunning { unrelated.terminate() } }
    let controller = TranslationRuntimeController(readinessTimeout: 0.1)
    do {
      _ = try await controller.start(executable: fixture, model: fixture, projector: fixture)
      XCTFail("Expected readiness timeout")
    } catch TranslationRuntimeController.RuntimeError.readinessTimeout {}
    let running = await controller.isRunning
    XCTAssertFalse(running)
    XCTAssertTrue(unrelated.isRunning, "Cleanup must not kill other processes")
  }
  func testStopDuringReadinessInvalidatesPendingStart() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = directory.appendingPathComponent("helper")
    try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: fixture)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
    let controller = TranslationRuntimeController(readinessTimeout: 2)
    let pending = Task {
      try await controller.start(executable: fixture, model: fixture, projector: fixture)
    }
    for _ in 0..<100 where await !controller.isRunning {
      try await Task.sleep(for: .milliseconds(2))
    }
    await controller.stop()
    do {
      _ = try await pending.value
      XCTFail("Stopped launch returned an endpoint")
    } catch {}
    let running = await controller.isRunning
    XCTAssertFalse(running)
  }
}
