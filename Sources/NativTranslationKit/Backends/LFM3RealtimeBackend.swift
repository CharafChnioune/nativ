import Foundation

public protocol LFMSocketTransport: Sendable {
  func send(_ data: Data) async throws
  func receive() async throws -> Data
  func close() async
}
public typealias LFMSocketFactory = @Sendable (URLRequest) async throws -> any LFMSocketTransport

public actor LFMURLSessionSocket: LFMSocketTransport {
  private let session: URLSession
  private let task: URLSessionWebSocketTask
  public init(request: URLRequest) {
    let session = lfmURLSession()
    self.session = session
    task = session.webSocketTask(with: request)
    task.maximumMessageSize = 1_048_576
    task.resume()
  }
  public func send(_ data: Data) async throws {
    guard let string = String(data: data, encoding: .utf8) else {
      throw lfmFailure(.invalidEvent, "Invalid outbound event.")
    }
    let task = task
    try await withTaskCancellationHandler {
      try await task.send(.string(string))
    } onCancel: {
      task.cancel(with: .goingAway, reason: nil)
    }
  }
  public func receive() async throws -> Data {
    let task = task
    return try await withTaskCancellationHandler {
      switch try await task.receive() {
      case .data(let data): return data
      case .string(let string): return Data(string.utf8)
      @unknown default: throw lfmFailure(.invalidEvent, "Unknown websocket message type.")
      }
    } onCancel: {
      task.cancel(with: .goingAway, reason: nil)
    }
  }
  public func close() {
    task.cancel(with: .goingAway, reason: nil)
    session.invalidateAndCancel()
  }
}

/// One socket, one in-flight utterance. A new socket resets context without unloading the helper.
public actor LFM3RealtimeBackend: TranslationBackend {
  public enum Mode: Sendable { case direct, twoPass }
  public struct Timeouts: Sendable {
    public var handshake: Double = 20
    public var response: Double = 60
    public var send: Double = 2
    public init() {}
  }
  private let endpoint: LFMRuntimeEndpoint
  private let mode: Mode
  private let socketFactory: LFMSocketFactory
  private let synthesizer: LFM3SpeechSynthesizer
  private let timeouts: Timeouts
  private let contentGuard: TranslationContentGuard
  private var configuration: TranslationConfiguration?
  private var socket: (any LFMSocketTransport)?
  private var inputFormat: TranslationPCMFormat?
  private var outputFormat: TranslationPCMFormat?
  private var incarnation = UUID()
  private var sessionID: TranslationSessionID?
  private var generation = TranslationGeneration()
  private var turnID: TranslationTurnID?
  private var responseID: String?
  private var committed = false
  private var inputDuration: Double = 0
  private var audioBytes = 0
  private var sequence: UInt64 = 0
  private var textGuard = LFMInterpreterTextGuard()
  private var continuation: AsyncThrowingStream<TranslationEvent, Error>.Continuation?
  private var reader: Task<Void, Never>?
  private var watchdog: Task<Void, Never>?

  deinit {
    reader?.cancel()
    watchdog?.cancel()
    continuation?.finish()
    if let socket { Task { await socket.close() } }
  }

  public init(
    endpoint: LFMRuntimeEndpoint, mode: Mode = .direct,
    socketFactory: @escaping LFMSocketFactory = { LFMURLSessionSocket(request: $0) },
    speechTransport: any LFMSpeechTransport = LFMURLSessionSpeechTransport(),
    timeouts: Timeouts = .init(), contentGuard: TranslationContentGuard = .init()
  ) {
    self.endpoint = endpoint
    self.mode = mode
    self.socketFactory = socketFactory
    self.synthesizer = LFM3SpeechSynthesizer(endpoint: endpoint, transport: speechTransport)
    self.timeouts = timeouts
    self.contentGuard = contentGuard
  }
  public func prepare(configuration: TranslationConfiguration) async throws
    -> TranslationCapabilities
  {
    await stop()
    try configuration.buffering.validate()
    guard timeouts.handshake.isFinite, timeouts.handshake > 0, timeouts.handshake <= 20,
      timeouts.response.isFinite, timeouts.response > 0, timeouts.response <= 60,
      timeouts.send.isFinite, timeouts.send > 0, timeouts.send <= 2
    else {
      throw lfmFailure(.invalidConfiguration, "The helper timeouts exceed their bounded limits.")
    }
    guard configuration.directionMode == .fixed else {
      throw lfmFailure(
        .unsupportedLanguage, "Automatic direction has not been qualified for LFM3 interpreting.")
    }
    guard configuration.provider == (mode == .direct ? .lfm3OmniDirect : .lfm3OmniTwoPass),
      configuration.languagePair.source != configuration.languagePair.target
    else {
      throw lfmFailure(
        .invalidConfiguration, "Select the matching Omni mode and two different languages.")
    }
    let inputs = LFMLanguageSupport.documentedSpeechLanguages
    let outputs =
      configuration.outputMode == .speechAndCaptions
      ? inputs : inputs.union(LFMLanguageSupport.documentedTextLanguages)
    guard inputs.contains(configuration.languagePair.source),
      outputs.contains(configuration.languagePair.target)
    else {
      throw lfmFailure(
        .unsupportedLanguage,
        "This language is not documented for the selected LFM3 input or output task.")
    }
    self.configuration = configuration
    try await connect()
    return .init(
      inputLanguages: inputs, outputLanguages: outputs, qualifiedTranslationPairs: [],
      supportsAudioOutput: true, sourceTranscriptAvailable: false, inputStreaming: true,
      outputStreaming: true, interruptionBehavior: .freshContextRequired, inputFormat: inputFormat)
  }
  public func start(sessionID: TranslationSessionID, generation: TranslationGeneration) async throws
    -> AsyncThrowingStream<TranslationEvent, Error>
  {
    guard let configuration, continuation == nil else {
      throw lfmFailure(.invalidState, "Prepare the interpreter before starting it.")
    }
    if socket == nil { try await connect() }
    try Task.checkCancellation()
    self.sessionID = sessionID
    self.generation = generation
    turnID = nil
    responseID = nil
    committed = false
    inputDuration = 0
    audioBytes = 0
    sequence = 0
    textGuard = LFMInterpreterTextGuard()
    let token = incarnation
    // Each audio event holds at most 100 ms; this queue can therefore hold at most 2 s of audio.
    let pair = AsyncThrowingStream<TranslationEvent, Error>.makeStream(
      bufferingPolicy: .bufferingOldest(min(20, configuration.buffering.eventCapacity)))
    continuation = pair.continuation
    pair.continuation.onTermination = { @Sendable [weak self] _ in
      Task { await self?.terminate(token: token) }
    }
    guard let socket else { throw CancellationError() }
    reader = Task { [weak self] in
      do {
        while !Task.isCancelled {
          let data = try await socket.receive()
          guard let self else { return }
          if try await self.receive(data, token: token) { return }
        }
      } catch { await self?.fail(error, token: token) }
    }
    return pair.stream
  }
  public func send(frame: OwnedPCMFrame) async throws {
    guard let socket, continuation != nil, !committed,
      frame.sessionID == sessionID, frame.generation == generation,
      turnID == nil || turnID == frame.turnID, frame.format == inputFormat
    else { throw lfmFailure(.staleInput, "Audio does not belong to the active interpreter input.") }
    let duration = try frame.format.duration(byteCount: frame.bytes.count)
    guard duration <= 2, inputDuration + duration <= 12.001 else {
      throw lfmFailure(.overload, "The interpreter input exceeded its bounded segment budget.")
    }
    turnID = frame.turnID
    inputDuration += duration
    let token = incarnation
    let data = try lfmJSON([
      "type": "input_audio_buffer.append", "audio": frame.bytes.base64EncodedString(),
    ])
    do { try await lfmWithTimeout(seconds: timeouts.send) { try await socket.send(data) } } catch {
      await fail(error, token: token)
      throw error
    }
    guard token == incarnation else { throw CancellationError() }
  }
  public func commit(turnID: TranslationTurnID) async throws {
    guard let socket, self.turnID == turnID, !committed, inputDuration > 0 else {
      throw lfmFailure(.invalidState, "There is no matching audio segment to commit.")
    }
    committed = true
    let token = incarnation
    let deadline = timeouts.response
    watchdog = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(deadline))
        await self?.fail(
          lfmFailure(.providerFailure, "The interpreter response timed out."), token: token)
      } catch {}
    }
    do {
      let commit = try lfmJSON(["type": "input_audio_buffer.commit"])
      let create = try lfmJSON(["type": "response.create"])
      try await lfmWithTimeout(seconds: timeouts.send) {
        try await socket.send(commit)
        try await socket.send(create)
      }
      guard token == incarnation else { throw CancellationError() }
    } catch {
      await fail(error, token: token)
      throw error
    }
  }
  public func cancel(turnID: TranslationTurnID) async {
    guard self.turnID == turnID else { return }
    await stop()
  }
  public func stop() async {
    incarnation = UUID()  // invalidate before any await or socket shutdown
    reader?.cancel()
    reader = nil
    watchdog?.cancel()
    watchdog = nil
    let old = socket
    socket = nil
    continuation?.finish()
    continuation = nil
    turnID = nil
    responseID = nil
    committed = false
    sessionID = nil
    await old?.close()
  }
  private func terminate(token: UUID) async { if token == incarnation { await stop() } }
  private func connect() async throws {
    guard let configuration else {
      throw lfmFailure(.invalidState, "Missing interpreter configuration.")
    }
    let token = incarnation
    let request = try endpoint.request(path: "/v1/realtime", websocket: true)
    let factory = socketFactory
    let connection = try await lfmWithTimeout(seconds: timeouts.handshake) {
      try await factory(request)
    }
    guard token == incarnation else {
      await connection.close()
      throw CancellationError()
    }
    socket = connection
    do {
      let createdData = try await lfmWithTimeout(seconds: timeouts.handshake) {
        try await connection.receive()
      }
      guard token == incarnation else { throw CancellationError() }
      let created = try LFMWireMessage.decode(createdData)
      guard created.type == "session.created" else {
        throw lfmFailure(.providerFailure, "The helper could not create an interpreting session.")
      }
      let formats = try created.negotiatedFormats()
      let speech = mode == .direct && configuration.outputMode == .speechAndCaptions
      let prompt = TranslationInterpreterPrompt.instructions(
        sourceLanguage: configuration.languagePair.source,
        targetLanguage: configuration.languagePair.target, spokenOutput: speech)
      let update = try lfmJSON([
        "type": "session.update",
        "session": [
          "type": "realtime", "instructions": prompt,
          "output_modalities": speech ? ["text", "audio"] : ["text"], "tools": [],
          "tool_choice": "none", "max_output_tokens": 512,
        ],
      ])
      try await lfmWithTimeout(seconds: timeouts.handshake) { try await connection.send(update) }
      let updatedData = try await lfmWithTimeout(seconds: timeouts.handshake) {
        try await connection.receive()
      }
      guard token == incarnation else { throw CancellationError() }
      guard try LFMWireMessage.decode(updatedData).type == "session.updated" else {
        throw lfmFailure(
          .providerFailure, "The helper rejected the fixed interpreter configuration.")
      }
      inputFormat = formats.input
      outputFormat = formats.output
    } catch {
      if token == incarnation { socket = nil }
      await connection.close()
      throw error
    }
  }
  /// true ends this socket reader, while leaving the public event stream alive for core rollover.
  private func receive(_ data: Data, token: UUID) async throws -> Bool {
    guard token == incarnation else { return true }
    let event = try LFMWireMessage.decode(data)
    try event.rejectToolOutput()
    if event.type == "error" {
      throw lfmFailure(
        .providerFailure,
        "The local interpreter rejected the turn. Reset the session and try again.")
    }
    if event.type == "response.created" {
      guard committed, responseID == nil, let id = event.response?.id, !id.isEmpty else {
        throw lfmFailure(.invalidEvent, "Unexpected interpreter response ordering.")
      }
      responseID = id
    } else if event.type.hasPrefix("response.") {
      guard committed, let responseID, (event.responseID ?? event.response?.id) == responseID else {
        throw lfmFailure(.invalidEvent, "The helper response belongs to a different turn.")
      }
    }
    switch event.type {
    case "response.output_text.delta":
      guard let delta = event.delta else {
        throw lfmFailure(.invalidEvent, "Missing interpreter text delta.")
      }
      let safe = try textGuard.append(delta)
      if !safe.isEmpty, let configuration {
        try contentGuard.validateOutput(textGuard.text, targetLanguage: configuration.languagePair.target)
        // Two-pass text is tentative until the complete target-language check, before /tts.
        try emit(.translationText(.init(text: mode == .twoPass ? textGuard.text : safe,
                                      stability: mode == .twoPass ? .tentative : .stableAppend)))
      }
    case "response.output_text.done":
      if let text = event.text, text != textGuard.text {
        throw lfmFailure(.invalidEvent, "The helper revised already committed text.")
      }
    case "response.output_audio.delta":
      guard mode == .direct, configuration?.outputMode == .speechAndCaptions,
        !textGuard.hasIncompleteMarkup, let format = outputFormat, let delta = event.delta
      else {
        throw lfmFailure(.invalidEvent, "Unexpected or uncommitted interpreter audio.")
      }
      // Reject oversized wire batches before PCM allocation. JSON/base64 framing is separately size-bounded.
      guard let budget = configuration?.audioTransportBudget,
        Double(delta.utf8.count / 4 * 3) / (format.sampleRate * 2)
          <= TranslationAudioTransportBudget.maximumSeconds + 0.001
      else {
        throw lfmFailure(
          .consumerOverload, "A realtime audio batch exceeded the two-second transport limit.")
      }
      let pcm = try LFMWireMessage.pcm16(delta)
      audioBytes += pcm.count
      guard audioBytes <= 8 * 1024 * 1024 else {
        throw lfmFailure(.overload, "Interpreter audio exceeded its response budget.")
      }
      // Server chunks may be large; fit bounded playback/transport queues without reinterpreting PCM.
      let size = max(2, Int(format.sampleRate / 10) * 2)
      let offsets = Array(stride(from: 0, to: pcm.count, by: size))
      let admissions = try budget.reserveBatch(
        seconds: offsets.map {
          try format.duration(byteCount: min(size, pcm.count - $0))
        })
      for (index, offset) in offsets.enumerated() {
        let bytes = Data(pcm[offset..<min(offset + size, pcm.count)])
        try emit(
          .audio(
            try TranslationAudioChunk(bytes: bytes, format: format, sequence: sequence).adopting(
              admissions[index])))
        sequence += 1
      }
    case "response.done":
      guard event.response?.status == "completed" else {
        throw lfmFailure(.incompleteTurn, "The interpreter did not complete this turn.")
      }
      let text = try textGuard.finish()
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw lfmFailure(.incompleteTurn, "The interpreter returned no translation text.")
      }
      if let configuration {
        // Neither Omni mode supplies a source transcript. No source/target semantic check
        // is claimed here; direct speech may already have streamed before this check.
        try contentGuard.validateOutput(text, targetLanguage: configuration.languagePair.target)
      }
      try emit(.translationText(.init(text: text, stability: .final)))
      let old = socket
      socket = nil
      await old?.close()  // single slot must be released before same-model /tts
      guard token == incarnation else { return true }
      if mode == .twoPass, configuration?.outputMode == .speechAndCaptions, let configuration {
        let audio = try synthesizer.stream(
          text: text, language: configuration.languagePair.target,
          budget: configuration.audioTransportBudget)
        for try await chunk in audio {
          guard token == incarnation, !Task.isCancelled else { return true }
          try emit(.audio(chunk))
        }
      } else if configuration?.outputMode == .speechAndCaptions, audioBytes == 0 {
        throw lfmFailure(.incompleteTurn, "The interpreter completed without speech audio.")
      }
      guard token == incarnation else { return true }
      watchdog?.cancel()
      watchdog = nil
      try emit(.turnCompleted)
      return true
    default: break  // acknowledgements and content boundaries carry no user-visible data
    }
    return false
  }
  private func emit(_ payload: TranslationEvent.Payload) throws {
    guard let sessionID, let continuation, let configuration else { throw CancellationError() }
    let payload: TranslationEvent.Payload =
      if case .audio(let chunk) = payload {
        .audio(try chunk.admitted(to: configuration.audioTransportBudget))
      } else { payload }
    if case .enqueued = continuation.yield(
      .init(sessionID: sessionID, turnID: turnID, generation: generation, payload: payload))
    {
    } else {
      throw lfmFailure(
        .consumerOverload, "The interpreter consumer fell behind. This turn is incomplete.")
    }
  }
  private func fail(_ error: Error, token: UUID) async {
    guard token == incarnation else { return }
    let sink = continuation
    continuation = nil
    sink?.finish(
      throwing: error is CancellationError
        ? CancellationError()
        : (error as? TranslationFailure
          ?? lfmFailure(
            .providerFailure, "The local speech connection failed. Restart the session.")))
    await stop()
  }
}
