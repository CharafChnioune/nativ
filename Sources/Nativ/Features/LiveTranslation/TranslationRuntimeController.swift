import Darwin
import Foundation
import NativTranslationKit
import Security

/// Owns only the child it launched. A backend/socket reset does not unload this model process.
actor TranslationRuntimeController {
  enum RuntimeError: LocalizedError, Sendable {
    case missingHelper, missingArtifact, invalidContext, launchFailed, readinessTimeout, exited,
      randomness
    var errorDescription: String? {
      switch self {
      case .missingHelper:
        "The bundled LFM3 speech helper is missing or not executable. Rebuild the runtime."
      case .missingArtifact:
        "The selected model or projector is missing. Prepare and verify the model first."
      case .invalidContext: "The speech helper context size is outside its configured bounds."
      case .launchFailed: "The local speech helper could not start."
      case .readinessTimeout: "The local speech helper did not become ready in time."
      case .exited: "The local speech helper stopped unexpectedly. Restart the translation session."
      case .randomness: "A private credential for the local speech helper could not be created."
      }
    }
  }
  private struct Configuration: Equatable, Sendable {
    let executable: URL, model: URL, projector: URL
    let contextSize: Int
  }
  private var process: Process?
    private var computeLease: GenerationComputeLease?
  private var outputPipe: Pipe?
  private var listenerBuffer = ""
  private var listener: Int?
  private var configuration: Configuration?
  private var endpoint: LFMRuntimeEndpoint?
  private var launchID = UUID()
  private var startRequestID = UUID()
  private var preparation: Task<LFMRuntimeEndpoint, Error>?
  private var shutdown: Task<Void, Never>?
  private let readinessTimeout: Double

  init(readinessTimeout: Double = 180) {
    self.readinessTimeout = max(0.1, min(readinessTimeout, 180))
  }

  deinit {
    preparation?.cancel()
    outputPipe?.fileHandleForReading.readabilityHandler = nil
    if process?.isRunning == true { process?.terminate() }
  }

  var isRunning: Bool { process?.isRunning == true }

  static func bundledExecutable(in bundle: Bundle = .main) throws -> URL {
    guard let resources = bundle.resourceURL else { throw RuntimeError.missingHelper }
    let url = resources.appendingPathComponent("LFMRealtime/bin/llama-server")
    guard FileManager.default.isExecutableFile(atPath: url.path) else {
      throw RuntimeError.missingHelper
    }
    return url
  }

  func start(executable: URL, model: URL, projector: URL, contextSize: Int = 4096) async throws
    -> LFMRuntimeEndpoint
  {
    let desired = Configuration(
      executable: executable.standardizedFileURL, model: model.standardizedFileURL,
      projector: projector.standardizedFileURL, contextSize: contextSize)
    if configuration == desired {
      if let endpoint, process?.isRunning == true { return endpoint }
      if let preparation { return try await preparation.value }
    }
    let requestID = UUID()
    startRequestID = requestID
    await stopOwnedProcess()
    try Task.checkCancellation()
    guard startRequestID == requestID else { throw CancellationError() }
    let id = UUID()
    launchID = id
    configuration = desired
    let task = Task { try await self.launch(desired, id: id) }
    preparation = task
    do {
      let result = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
        Task { await self.cancelLaunch(id) }
      }
      guard launchID == id else { throw CancellationError() }
      preparation = nil
      endpoint = result
      return result
    } catch {
      if launchID == id { await stop() }
      throw error
    }
  }

  func stop() async {
    startRequestID = UUID()
    await stopOwnedProcess()
  }

  private func stopOwnedProcess() async {
    launchID = UUID()  // callers waiting for an older launch cannot publish its endpoint
    preparation?.cancel()
    preparation = nil
    endpoint = nil
    configuration = nil
    listener = nil
    listenerBuffer = ""
    if let shutdown {
      await shutdown.value
      return
    }
    guard let owned = process else { computeLease?.close(); computeLease = nil; return }
    let ownedLease = computeLease; computeLease = nil
    process = nil
    let pipe = outputPipe
    outputPipe = nil
    pipe?.fileHandleForReading.readabilityHandler = nil
    owned.terminationHandler = nil
    // Foundation's Process identity, not a name or arbitrary port, determines cleanup.
    let cleanup = Task { @concurrent in
      if owned.isRunning { owned.terminate() }
      let deadline = ContinuousClock.now.advanced(by: .seconds(2))
      while owned.isRunning && ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(25))
      }
      if owned.isRunning { _ = Darwin.kill(owned.processIdentifier, SIGKILL) }
      while owned.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
      try? pipe?.fileHandleForReading.close()
      try? pipe?.fileHandleForWriting.close()
    }
    shutdown = cleanup
    await cleanup.value
    shutdown = nil
    ownedLease?.close()
  }

  private func cancelLaunch(_ id: UUID) async { if launchID == id { await stop() } }

  private func launch(_ desired: Configuration, id: UUID) async throws -> LFMRuntimeEndpoint {
    guard FileManager.default.isExecutableFile(atPath: desired.executable.path) else {
      throw RuntimeError.missingHelper
    }
    for url in [desired.model, desired.projector] {
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values?.isRegularFile == true, values?.isSymbolicLink != true,
        FileManager.default.isReadableFile(atPath: url.path)
      else { throw RuntimeError.missingArtifact }
    }
    let args = try Self.arguments(
      model: desired.model, projector: desired.projector, contextSize: desired.contextSize)
    var random = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
      throw RuntimeError.randomness
    }
    let key = Data(random).base64EncodedString()
    try Task.checkCancellation()
    guard launchID == id else { throw CancellationError() }
    let child = Process()
    let pipe = Pipe()
    child.executableURL = desired.executable
    child.arguments = args
    child.environment = Self.sanitizedEnvironment(
      ProcessInfo.processInfo.environment, bearerToken: key)
    let acquired = try GenerationComputeLease.acquire()
    computeLease = acquired
    child.standardOutput = FileHandle.nullDevice
    child.standardError = pipe
    pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      if !data.isEmpty {
        Task { await self?.consumeOutput(data, id: id) }
      } else {
        handle.readabilityHandler = nil
      }
    }
    child.terminationHandler = { [weak self] _ in Task { await self?.didExit(id: id) } }
    process = child
    outputPipe = pipe
    do { try acquired.runOwnedProcess(child) } catch { throw RuntimeError.launchFailed }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(readinessTimeout))
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    while clock.now < deadline {
      try Task.checkCancellation()
      guard launchID == id else { throw CancellationError() }
      guard child.isRunning else { throw RuntimeError.exited }
      if let listener {
        let endpoint = try LFMRuntimeEndpoint(
          baseURL: URL(string: "http://127.0.0.1:\(listener)")!, bearerToken: key)
        var request = try endpoint.request(path: "/health")
        request.timeoutInterval = 2
        do {
          let (_, response) = try await session.data(for: request)
          guard launchID == id, child.isRunning else { throw CancellationError() }
          if let response = response as? HTTPURLResponse, response.statusCode == 200 {
            return endpoint
          }
        } catch is CancellationError { throw CancellationError() } catch
        { /* readiness is retried only within the bounded launch deadline */  }
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw RuntimeError.readinessTimeout
  }

  private func consumeOutput(_ data: Data, id: UUID) {
    guard launchID == id, listener == nil else { return }
    // Diagnostic output is not logged or persisted; keep only a bounded readiness suffix.
    listenerBuffer += String(decoding: data.suffix(8192), as: UTF8.self)
    listenerBuffer = String(listenerBuffer.suffix(8192))
    if let port = Self.listenerPort(in: listenerBuffer) {
      listener = port
      listenerBuffer = ""
      // After discovery, drain without queueing diagnostic content onto the actor.
      outputPipe?.fileHandleForReading.readabilityHandler = { handle in
        if handle.availableData.isEmpty { handle.readabilityHandler = nil }
      }
    }
  }
  private func didExit(id: UUID) {
    guard launchID == id else { return }
    endpoint = nil
  }

  static func sanitizedEnvironment(_ inherited: [String: String], bearerToken: String) -> [String:
    String]
  {
    let allowed: Set<String> = ["PATH", "HOME", "TMPDIR", "USER", "LOGNAME", "LANG", "LC_ALL"]
    var clean = inherited.filter { allowed.contains($0.key) }
    clean["LLAMA_API_KEY"] = bearerToken
    return clean
  }
  static func arguments(model: URL, projector: URL, contextSize: Int) throws -> [String] {
    guard (1024...8192).contains(contextSize) else { throw RuntimeError.invalidContext }
    return [
      "--model", model.path, "--mmproj", projector.path, "--host", "127.0.0.1", "--port", "0",
      "--parallel", "1", "--ctx-size", String(contextSize), "--reasoning", "off", "--no-webui",
      "--no-agent", "--cors-origins", "localhost", "--no-cors-credentials",
    ]
  }
  static func listenerPort(in text: String) -> Int? {
    guard let range = text.range(of: "listening on http://127.0.0.1:", options: .backwards) else {
      return nil
    }
    let suffix = text[range.upperBound...]
    let digits = suffix.prefix(while: { $0.isASCII && $0.isNumber })
    // A pipe callback may end halfway through the decimal port. Wait for its delimiter.
    guard let delimiter = suffix.dropFirst(digits.count).first,
      delimiter.isWhitespace || delimiter == "/",
      let port = Int(digits), (1...65535).contains(port)
    else { return nil }
    return port
  }
}
