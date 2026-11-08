import Foundation
import XCTest

@testable import NativTranslationKit

private actor ScriptedLFMSocket: LFMSocketTransport {
  private var messages: [Data]
  private var waiter: CheckedContinuation<Data, Error>?
  private(set) var sent: [Data] = []
  private(set) var closed = false
  init() {
    messages = [
      Data(
        #"{"type":"session.created","session":{"audio":{"input":{"format":{"type":"audio/pcm","rate":16000}},"output":{"format":{"type":"audio/pcm","rate":24000}}}}}"#
          .utf8), Data(#"{"type":"session.updated"}"#.utf8),
    ]
  }
  func send(_ data: Data) { sent.append(data) }
  func receive() async throws -> Data {
    if !messages.isEmpty { return messages.removeFirst() }
    if closed { throw CancellationError() }
    return try await withCheckedThrowingContinuation { waiter = $0 }
  }
  func push(_ json: String) {
    let data = Data(json.utf8)
    if let waiter {
      self.waiter = nil
      waiter.resume(returning: data)
    } else {
      messages.append(data)
    }
  }
  func close() {
    closed = true
    waiter?.resume(throwing: CancellationError())
    waiter = nil
  }
}
private actor CapturedLFMEvents {
  var events: [TranslationEvent] = []
  var failure: Error?
  func consume(_ stream: AsyncThrowingStream<TranslationEvent, Error>) async {
    do { for try await event in stream { events.append(event) } } catch { failure = error }
  }
}
final class LFM3BackendTests: XCTestCase, @unchecked Sendable {
  private let sid = TranslationSessionID()
  private let generation = TranslationGeneration(3)
  private let turn = TranslationTurnID()
  private func frame() -> OwnedPCMFrame {
    .init(
      bytes: Data(repeating: 0, count: 640),
      format: .init(sampleRate: 16000, channels: 1, encoding: .signedInt16LittleEndian),
      captureTimestampNanoseconds: 0, sequence: 0, sourceID: "test", sessionID: sid, turnID: turn,
      generation: generation)
  }
  private func setup(_ socket: ScriptedLFMSocket, mode: LFM3RealtimeBackend.Mode = .direct)
    async throws -> LFM3RealtimeBackend
  {
    let endpoint = try LFMRuntimeEndpoint(
      baseURL: URL(string: "http://127.0.0.1:54321")!, bearerToken: "test")
    let backend = LFM3RealtimeBackend(
      endpoint: endpoint, mode: mode, socketFactory: { _ in socket })
    let capabilities = try await backend.prepare(
      configuration: .init(
        languagePair: .init(source: "nl", target: "en"), outputMode: .speechAndCaptions,
        provider: mode == .direct ? .lfm3OmniDirect : .lfm3OmniTwoPass))
    XCTAssertTrue(capabilities.qualifiedTranslationPairs.isEmpty)
    XCTAssertFalse(capabilities.sourceTranscriptAvailable)
    return backend
  }
  func testCommittedAudioArrivesBeforeResponseCompletion() async throws {
    let socket = ScriptedLFMSocket()
    let events = CapturedLFMEvents()
    let backend = try await setup(socket)
    let stream = try await backend.start(sessionID: sid, generation: generation)
    let consumer = Task { await events.consume(stream) }
    try await backend.send(frame: frame())
    try await backend.commit(turnID: turn)
    await socket.push(#"{"type":"response.created","response":{"id":"r","status":"in_progress"}}"#)
    await socket.push(
      #"{"type":"response.output_text.delta","response_id":"r","delta":"Three, not four."}"#)
    await socket.push(
      #"{"type":"response.output_audio.delta","response_id":"r","delta":"AQACAA=="}"#)
    try await Task.sleep(for: .milliseconds(30))
    let before = await events.events
    XCTAssertTrue(
      before.contains {
        if case .audio = $0.payload { return true }
        return false
      })
    XCTAssertFalse(before.contains { $0.payload == .turnCompleted })
    await socket.push(
      #"{"type":"response.done","response":{"id":"r","status":"completed","usage":{"output_tokens":12}}}"#
    )
    try await Task.sleep(for: .milliseconds(30))
    let after = await events.events
    XCTAssertEqual(after.last?.payload, .turnCompleted)
    XCTAssertEqual(after.last?.generation, generation)
    XCTAssertFalse(
      after.contains {
        if case .metrics(let metric) = $0.payload { return metric.name == .contextTokens }
        return false
      })
    await backend.stop()
    await consumer.value
  }
  func testCancelInvalidatesSocketBeforeLateOutput() async throws {
    let socket = ScriptedLFMSocket()
    let events = CapturedLFMEvents()
    let backend = try await setup(socket)
    let stream = try await backend.start(sessionID: sid, generation: generation)
    let consumer = Task { await events.consume(stream) }
    try await backend.send(frame: frame())
    try await backend.commit(turnID: turn)
    await backend.cancel(turnID: turn)
    await socket.push(#"{"type":"response.created","response":{"id":"r","status":"in_progress"}}"#)
    await socket.push(
      #"{"type":"response.output_audio.delta","response_id":"r","delta":"AQACAA=="}"#)
    await consumer.value
    let captured = await events.events
    XCTAssertTrue(captured.isEmpty)
    let closed = await socket.closed
    XCTAssertTrue(closed)
  }
  func testWireToolCallFailsTurnWithoutExecutingAnything() async throws {
    let socket = ScriptedLFMSocket()
    let events = CapturedLFMEvents()
    let backend = try await setup(socket)
    let stream = try await backend.start(sessionID: sid, generation: generation)
    let consumer = Task { await events.consume(stream) }
    try await backend.send(frame: frame())
    try await backend.commit(turnID: turn)
    await socket.push(#"{"type":"response.created","response":{"id":"r","status":"in_progress"}}"#)
    await socket.push(
      #"{"type":"response.output_item.added","response_id":"r","item":{"type":"function_call"}}"#)
    await consumer.value
    let error = await events.failure as? TranslationFailure
    XCTAssertEqual(error?.code, .invalidEvent)
    let closed = await socketIsClosed(socket)
    XCTAssertTrue(closed)
  }
  private func socketIsClosed(_ socket: ScriptedLFMSocket) async -> Bool { await socket.closed }
}

private actor LFMSpeechFixtureTransport: LFMSpeechTransport {
  let socket: ScriptedLFMSocket?
  let pair = AsyncThrowingStream<LFMSpeechTransportChunk, Error>.makeStream(
    bufferingPolicy: .bufferingOldest(16))
  private(set) var closedBeforeSpeech = false
  private(set) var called = false
  init(socket: ScriptedLFMSocket? = nil) { self.socket = socket }
  func stream(_ request: URLRequest, budget: TranslationAudioTransportBudget) async throws
    -> LFMSpeechHTTPResponse
  {
    closedBeforeSpeech = await socket?.closed ?? true
    called = true
    return .init(
      statusCode: 200, contentType: "audio/pcm;rate=24000;encoding=float;bits=32", body: pair.stream
    )
  }
  func push(_ bytes: Data) { pair.continuation.yield(.init(bytes: bytes)) }
  func finish() { pair.continuation.finish() }
}
extension LFM3BackendTests {
  func testTwoPassWrongLanguageFailsBeforeFinalTextAndSpeech() async throws {
    let socket = ScriptedLFMSocket()
    let events = CapturedLFMEvents()
    let transport = LFMSpeechFixtureTransport(socket: socket)
    let backend = LFM3RealtimeBackend(
      endpoint: try .init(baseURL: URL(string: "http://127.0.0.1:54321")!, bearerToken: "test"),
      mode: .twoPass, socketFactory: { _ in socket }, speechTransport: transport,
      contentGuard: .init(languageDetector: { _ in .init(language: "en", confidence: 0.99) }))
    _ = try await backend.prepare(configuration: .init(
      languagePair: .init(source: "en", target: "nl"), outputMode: .speechAndCaptions,
      provider: .lfm3OmniTwoPass))
    let stream = try await backend.start(sessionID: sid, generation: generation)
    let consumer = Task { await events.consume(stream) }
    try await backend.send(frame: frame())
    try await backend.commit(turnID: turn)
    await socket.push(#"{"type":"response.created","response":{"id":"r","status":"in_progress"}}"#)
    await socket.push(#"{"type":"response.output_text.delta","response_id":"r","delta":"Please keep the door closed today."}"#)
    await consumer.value
    let error = await events.failure as? TranslationFailure
    let called = await transport.called
    let captured = await events.events
    XCTAssertEqual(error?.code, .unsupportedOutput)
    XCTAssertFalse(called)
    XCTAssertFalse(captured.contains {
      if case .audio = $0.payload { return true }
      if case .translationText(let text) = $0.payload { return text.stability == .final }
      return $0.payload == .turnCompleted
    })
    let sent = await socket.sent
    let update = try XCTUnwrap(sent.first)
    let instructions = try XCTUnwrap((JSONSerialization.jsonObject(with: update) as? [String: Any])?["session"] as? [String: Any])["instructions"] as? String
    XCTAssertTrue(instructions?.contains("previous hour") == true)
    await backend.stop()
  }

  func testTwoPassClosesRealtimeSlotBeforeStreamingFloatSpeech() async throws {
    let socket = ScriptedLFMSocket()
    let events = CapturedLFMEvents()
    let transport = LFMSpeechFixtureTransport(socket: socket)
    let backend = LFM3RealtimeBackend(
      endpoint: try .init(baseURL: URL(string: "http://127.0.0.1:54321")!, bearerToken: "test"),
      mode: .twoPass, socketFactory: { _ in socket }, speechTransport: transport)
    _ = try await backend.prepare(
      configuration: .init(
        languagePair: .init(source: "en", target: "nl"), outputMode: .speechAndCaptions,
        provider: .lfm3OmniTwoPass))
    let stream = try await backend.start(sessionID: sid, generation: generation)
    let consumer = Task { await events.consume(stream) }
    try await backend.send(frame: frame())
    try await backend.commit(turnID: turn)
    await socket.push(#"{"type":"response.created","response":{"id":"r","status":"in_progress"}}"#)
    await socket.push(
      #"{"type":"response.output_text.delta","response_id":"r","delta":"Drie stoelen."}"#)
    await socket.push(#"{"type":"response.done","response":{"id":"r","status":"completed"}}"#)
    for _ in 0..<100 where await !transport.called { try await Task.sleep(for: .milliseconds(2)) }
    let released = await transport.closedBeforeSpeech
    XCTAssertTrue(released)
    await transport.push(Data([0, 0, 0]))
    await transport.push(Data([63]))
    try await Task.sleep(for: .milliseconds(20))
    let partial = await events.events
    let textUpdates = partial.compactMap { event -> TranslationTextUpdate? in
      if case .translationText(let text) = event.payload { return text }
      return nil
    }
    XCTAssertEqual(textUpdates.map(\.stability), [.tentative, .final])
    let chunk = partial.compactMap { event -> TranslationAudioChunk? in
      if case .audio(let chunk) = event.payload { return chunk }
      return nil
    }.first
    XCTAssertEqual(chunk?.format.encoding, .float32LittleEndian)
    XCTAssertEqual(chunk?.bytes, Data([0, 0, 0, 63]))
    XCTAssertFalse(partial.contains { $0.payload == .turnCompleted })
    await transport.finish()
    try await Task.sleep(for: .milliseconds(20))
    let complete = await events.events
    XCTAssertEqual(complete.last?.payload, .turnCompleted)
    await backend.stop()
    await consumer.value
  }
  func testUnsupportedSpeechLanguageIsRejectedBeforeTransport() throws {
    let synthesizer = LFM3SpeechSynthesizer(
      endpoint: try .init(baseURL: URL(string: "http://127.0.0.1:54321")!, bearerToken: "test"))
    XCTAssertThrowsError(try synthesizer.stream(text: "Hello", language: "hi"))
    XCTAssertThrowsError(try synthesizer.stream(text: "<tool_call>", language: "en"))
  }
  func testResponseWatchdogClosesSocketAndFailsIncompleteTurn() async throws {
    let socket = ScriptedLFMSocket()
    let events = CapturedLFMEvents()
    var timeouts = LFM3RealtimeBackend.Timeouts()
    timeouts.response = 0.02
    let backend = LFM3RealtimeBackend(
      endpoint: try .init(baseURL: URL(string: "http://127.0.0.1:54321")!, bearerToken: "test"),
      socketFactory: { _ in socket }, timeouts: timeouts)
    _ = try await backend.prepare(
      configuration: .init(
        languagePair: .init(source: "nl", target: "en"), provider: .lfm3OmniDirect))
    let consumer = Task {
      await events.consume(try await backend.start(sessionID: sid, generation: generation))
    }
    try await Task.sleep(for: .milliseconds(5))
    try await backend.send(frame: frame())
    try await backend.commit(turnID: turn)
    try await consumer.value
    let failure = await events.failure as? TranslationFailure
    XCTAssertEqual(failure?.code, .providerFailure)
    let closed = await socket.closed
    XCTAssertTrue(closed)
  }
}

extension LFM3BackendTests {
  func testReleasingBackendClosesIdleSocket() async throws {
    let socket = ScriptedLFMSocket()
    var backend: LFM3RealtimeBackend? = try await setup(socket)
    let stream = try await backend!.start(sessionID: sid, generation: generation)
    backend = nil
    try await Task.sleep(for: .milliseconds(30))
    let closed = await socket.closed
    XCTAssertTrue(closed, "Dropping a backend must not leave the helper slot occupied")
    _ = stream
    await socket.close()
  }
}
