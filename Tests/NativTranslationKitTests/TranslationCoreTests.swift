import Foundation
import Testing

@testable import NativTranslationKit

// The injected backend represents the external model boundary; all buffering,
// event validation, turn ordering and state transitions are the real core.
actor ControlledBackend: TranslationBackend {
  var continuation: AsyncThrowingStream<TranslationEvent, Error>.Continuation?
  var frames: [OwnedPCMFrame] = []
  var commits: [TranslationTurnID] = []
  var starts = 0
  var heldStop = false
  var stopGate: CheckedContinuation<Void, Never>?
  var stopped = false
  func prepare(configuration: TranslationConfiguration) async throws -> TranslationCapabilities {
    .init(
      inputLanguages: ["en", "nl"], outputLanguages: ["en", "nl"], supportsAudioOutput: true)
  }
  func start(sessionID: TranslationSessionID, generation: TranslationGeneration) async throws
    -> AsyncThrowingStream<TranslationEvent, Error>
  {
    starts += 1
    stopped = false
    let pair = AsyncThrowingStream<TranslationEvent, Error>.makeStream(
      bufferingPolicy: .bufferingOldest(64))
    continuation = pair.continuation
    return pair.stream
  }
  func send(frame: OwnedPCMFrame) async throws {
    guard !stopped else {
      throw TranslationFailure(code: .invalidState, message: "send on stopped backend")
    }
    frames.append(frame)
  }
  func commit(turnID: TranslationTurnID) async throws { commits.append(turnID) }
  func cancel(turnID: TranslationTurnID) async {}
  func stop() async {
    stopped = true
    continuation?.finish()
    continuation = nil
    if heldStop { await withCheckedContinuation { stopGate = $0 } }
  }
  func holdStop() { heldStop = true }
  func releaseStop() {
    heldStop = false
    stopGate?.resume()
    stopGate = nil
  }
  func isHoldingStop() -> Bool { stopGate != nil }
  func emit(_ event: TranslationEvent) { continuation?.yield(event) }
}

func configuration() -> TranslationConfiguration {
  .init(languagePair: .init(source: "en", target: "nl"), provider: .lfm3OmniDirect)
}
func frame(
  _ s: TranslationSessionSnapshot, turn: TranslationTurnID, sequence: UInt64 = 0, seconds: Int = 1
) -> OwnedPCMFrame {
  .init(
    bytes: Data(repeating: 0, count: 16_000 * 2 * seconds),
    format: .init(sampleRate: 16_000, channels: 1, encoding: .signedInt16LittleEndian),
    captureTimestampNanoseconds: sequence * 1_000_000_000, sequence: sequence, sourceID: "mic",
    sessionID: s.sessionID, turnID: turn, generation: s.generation)
}
func settle() async { for _ in 0..<100 { await Task.yield() } }

@Test func queuesOneWaitingTurnUntilCompletion() async throws {
  let backend = ControlledBackend()
  let core = TranslationSession(backend: backend)
  _ = try await core.prepare(configuration: configuration())
  let events = try await core.start()
  defer { withExtendedLifetime(events) {} }
  let s = await core.snapshot()
  let first = TranslationTurnID()
  let second = TranslationTurnID()
  try await core.accept(frame: frame(s, turn: first))
  try await core.commit(turnID: first)
  try await core.accept(frame: frame(s, turn: second, sequence: 1))
  try await core.commit(turnID: second)
  #expect(await backend.commits == [first])
  await backend.emit(
    .init(
      sessionID: s.sessionID, turnID: first, generation: s.generation, payload: .turnCompleted
    ))
  await settle()
  #expect(await backend.commits == [first, second])
  await core.stop()
}

@Test func overloadMarksIncompleteAndPausesWithoutSilentSpeechLoss() async throws {
  let backend = ControlledBackend()
  let core = TranslationSession(backend: backend)
  _ = try await core.prepare(configuration: configuration())
  let events = try await core.start()
  defer { withExtendedLifetime(events) {} }
  let s = await core.snapshot()
  let a = TranslationTurnID()
  let b = TranslationTurnID()
  let c = TranslationTurnID()
  try await core.accept(frame: frame(s, turn: a))
  try await core.commit(turnID: a)
  try await core.accept(frame: frame(s, turn: b, sequence: 1))
  try await core.commit(turnID: b)
  await #expect(throws: TranslationFailure.self) {
    try await core.accept(frame: frame(s, turn: c, sequence: 2))
  }
  let result = await core.snapshot()
  #expect(result.state == .paused)
  #expect(result.incompleteTurns.contains(c))
  let missed = result.incompleteIntervals.first { $0.turnID == c }
  #expect(missed?.sourceID == "mic")
  #expect(missed?.startCaptureTimestampNanoseconds == 2_000_000_000)
  #expect(missed?.endCaptureTimestampNanoseconds == 3_000_000_000)
  await core.stop()
}

@Test func rejectsStaleAndOversizedInput() async throws {
  let core = TranslationSession(backend: ControlledBackend())
  _ = try await core.prepare(configuration: configuration())
  let events = try await core.start()
  defer { withExtendedLifetime(events) {} }
  let s = await core.snapshot()
  await #expect(throws: TranslationFailure.self) {
    try await core.accept(frame: frame(s, turn: .init(), seconds: 13))
  }
  await core.stop()
  await #expect(throws: TranslationFailure.self) {
    try await core.accept(frame: frame(s, turn: .init()))
  }
}

@Test func transcriptIsBoundedAndTentativeRevisionDoesNotCommitSpeech() async throws {
  var history = TranslationTranscriptBuffer()
  for _ in 0..<205 {
    history.append(
      .init(turnID: .init(), sourceText: nil, translatedText: "hello", incomplete: false))
  }
  #expect(history.turns.count == 200)
  #expect(history.discardedTurnCount == 5)
  var text = TranslationTextAccumulator()
  #expect(try text.apply(.init(text: "hel", stability: .tentative)) == nil)
  #expect(try text.apply(.init(text: "hello", stability: .stableAppend)) == "hello")
  #expect(try text.apply(.init(text: " world", stability: .stableAppend)) == " world")
  #expect(try text.apply(.init(text: "hello world", stability: .final)) == nil)
  #expect(text.text == "hello world")
}

@Test func tentativeWholeTextNeverDuplicatesCommittedPrefix() throws {
  var text = TranslationTextAccumulator()
  #expect(try text.apply(.init(text: "Hello", stability: .stableAppend)) == "Hello")
  #expect(try text.apply(.init(text: "Hello there", stability: .tentative)) == nil)
  #expect(text.text == "Hello there")
  #expect(try text.apply(.init(text: "Hello world", stability: .final)) == " world")
  #expect(throws: TranslationFailure.self) {
    try text.apply(.init(text: "Goodbye", stability: .final))
  }
}

@Test func automaticDirectionRequiresMeasuredQualification() async throws {
  let core = TranslationSession(backend: ControlledBackend())
  var config = configuration()
  config.directionMode = .automatic
  await #expect(throws: TranslationFailure.self) { try await core.prepare(configuration: config) }
  #expect(await core.snapshot().state == .failed)
}

@Test func interruptionKeepsWaitingTurnAndRejectsOldGenerationEvents() async throws {
  let backend = ControlledBackend()
  let session = TranslationSession(backend: backend)
  _ = try await session.prepare(configuration: configuration())
  let events = try await session.start()
  defer { withExtendedLifetime(events) {} }
  let before = await session.snapshot()
  let first = TranslationTurnID()
  let waiting = TranslationTurnID()
  try await session.accept(frame: frame(before, turn: first))
  try await session.commit(turnID: first)
  await session.setOutputPlaying(true)
  try await session.accept(frame: frame(before, turn: waiting, sequence: 1))
  try await session.commit(turnID: waiting)
  await session.interrupt()
  let after = await session.snapshot()
  #expect(after.generation != before.generation)
  #expect(after.activeTurnID == waiting)
  #expect(after.incompleteTurns.contains(first))
  #expect(!after.activity.playingOutput)
  #expect(await backend.commits == [first, waiting])
  await backend.emit(
    .init(
      sessionID: before.sessionID, turnID: waiting, generation: before.generation,
      payload: .translationText(.init(text: "STALE", stability: .final))))
  await backend.emit(
    .init(
      sessionID: after.sessionID, turnID: waiting, generation: after.generation,
      payload: .translationText(.init(text: "nieuw", stability: .final))))
  await backend.emit(
    .init(
      sessionID: after.sessionID, turnID: waiting, generation: after.generation,
      payload: .turnCompleted))
  await settle()
  #expect(await session.snapshot().transcript.turns.last?.translatedText == "nieuw")
  await session.stop()
}

actor EventCollector {
  var events: [TranslationEvent] = []
  var failure: TranslationFailure?
  func record(_ event: TranslationEvent) { events.append(event) }
  func fail(_ error: Error) { failure = error as? TranslationFailure }
  func hasAudio() -> Bool {
    events.contains { if case .audio = $0.payload { true } else { false } }
  }
}

@Test func committedDirectAudioReachesHostBeforeTurnCompletion() async throws {
  let backend = ControlledBackend()
  let core = TranslationSession(backend: backend)
  var config = configuration()
  config.outputMode = .speechAndCaptions
  _ = try await core.prepare(configuration: config)
  let events = try await core.start()
  let collector = EventCollector()
  let reader = Task {
    do { for try await event in events { await collector.record(event) } } catch {
      await collector.fail(error)
    }
  }
  let s = await core.snapshot()
  let turn = TranslationTurnID()
  try await core.accept(frame: frame(s, turn: turn))
  try await core.commit(turnID: turn)
  await backend.emit(
    .init(
      sessionID: s.sessionID, turnID: turn, generation: s.generation,
      payload: .audio(
        .init(
          bytes: Data(repeating: 0, count: 320),
          format: .init(
            sampleRate: 16_000, channels: 1, encoding: .signedInt16LittleEndian),
          sequence: 0))))
  await settle()
  #expect(await collector.hasAudio())
  #expect(await core.snapshot().activeTurnID == turn)
  #expect(await core.snapshot().transcript.turns.isEmpty)
  await core.stop()
  await reader.value
}

@Test func contextRollsAtTurnBoundaryWithoutInvalidatingCommittedOutput() async throws {
  let backend = ControlledBackend()
  let core = TranslationSession(backend: backend)
  var config = configuration()
  config.buffering.contextTokenLimit = 100
  _ = try await core.prepare(configuration: config)
  let events = try await core.start()
  defer { withExtendedLifetime(events) {} }
  let s = await core.snapshot()
  let a = TranslationTurnID()
  let b = TranslationTurnID()
  try await core.accept(frame: frame(s, turn: a))
  try await core.commit(turnID: a)
  try await core.accept(frame: frame(s, turn: b, sequence: 1))
  try await core.commit(turnID: b)
  await backend.emit(
    .init(
      sessionID: s.sessionID, generation: s.generation,
      payload: .metrics(.init(name: .contextTokens, value: 70))))
  await settle()
  #expect(await backend.starts == 1)
  await backend.emit(
    .init(sessionID: s.sessionID, turnID: a, generation: s.generation, payload: .turnCompleted))
  await settle()
  #expect(await backend.starts == 2)
  #expect(await backend.frames.last?.turnID == b)
  #expect(await backend.frames.last?.generation == s.generation)
  #expect(await core.snapshot().activity.acceptingInput)
  await core.stop()
}

@Test func slowHostFailsExplicitlyAndReleasesRuntime() async throws {
  let backend = ControlledBackend()
  let core = TranslationSession(backend: backend)
  var config = configuration()
  config.buffering.eventCapacity = 4
  _ = try await core.prepare(configuration: config)
  let events = try await core.start()
  defer { withExtendedLifetime(events) {} }
  let s = await core.snapshot()
  let turn = TranslationTurnID()
  try await core.accept(frame: frame(s, turn: turn))
  try await core.commit(turnID: turn)
  for _ in 0..<8 {
    await backend.emit(
      .init(
        sessionID: s.sessionID, generation: s.generation,
        payload: .metrics(.init(name: .contextTokens, value: 1))))
  }
  await settle()
  let result = await core.snapshot()
  #expect(result.state == .failed)
  #expect(result.lastFailure?.code == .consumerOverload)
  #expect(result.incompleteTurns.contains(turn))
  await core.stop()
}

actor CancellationBackend: TranslationBackend {
  var preparing = false
  var didStop = false
  func prepare(configuration: TranslationConfiguration) async throws -> TranslationCapabilities {
    preparing = true
    try await Task.sleep(for: .seconds(60))
    return .init(inputLanguages: ["en"], outputLanguages: ["nl"])
  }
  func start(sessionID: TranslationSessionID, generation: TranslationGeneration) async throws
    -> AsyncThrowingStream<TranslationEvent, Error>
  { throw CancellationError() }
  func send(frame: OwnedPCMFrame) async throws {}
  func commit(turnID: TranslationTurnID) async throws {}
  func cancel(turnID: TranslationTurnID) async {}
  func stop() async { didStop = true }
}

@Test func stopCancelsPreparationAndReleasesBeforeReturning() async throws {
  let backend = CancellationBackend()
  let core = TranslationSession(backend: backend)
  let preparation = Task { try await core.prepare(configuration: configuration()) }
  for _ in 0..<10_000 {
    if await backend.preparing { break }
    await Task.yield()
  }
  #expect(await backend.preparing)
  await core.stop()
  await #expect(throws: CancellationError.self) { try await preparation.value }
  #expect(await backend.didStop)
  #expect(await core.snapshot().state == .stopped)
}

@Test func cancellingHostConsumerAfterContextResetStopsSession() async throws {
  let backend = ControlledBackend()
  let core = TranslationSession(backend: backend)
  _ = try await core.prepare(configuration: configuration())
  let stream = try await core.start()
  let reader = Task { do { for try await _ in stream {} } catch {} }
  await core.interrupt()
  reader.cancel()
  await reader.value
  await settle()
  #expect(await core.snapshot().state == .stopped)
  await core.stop()
}

actor StartingBackend: TranslationBackend {
  var starting = false
  var didStop = false
  func prepare(configuration: TranslationConfiguration) async throws -> TranslationCapabilities {
    .init(inputLanguages: ["en"], outputLanguages: ["nl"])
  }
  func start(sessionID: TranslationSessionID, generation: TranslationGeneration) async throws
    -> AsyncThrowingStream<TranslationEvent, Error>
  {
    starting = true
    try await Task.sleep(for: .seconds(60))
    throw CancellationError()
  }
  func send(frame: OwnedPCMFrame) async throws {}
  func commit(turnID: TranslationTurnID) async throws {}
  func cancel(turnID: TranslationTurnID) async {}
  func stop() async { didStop = true }
}

@Test func stopCancelsPendingStartInsteadOfWaitingForRuntimeTimeout() async throws {
  let backend = StartingBackend()
  let core = TranslationSession(backend: backend)
  _ = try await core.prepare(configuration: configuration())
  let start = Task { try await core.start() }
  for _ in 0..<10_000 {
    if await backend.starting { break }
    await Task.yield()
  }
  let stop = Task { await core.stop() }
  await settle()
  #expect(await backend.didStop)
  start.cancel()  // Ensure a failing implementation cannot leave the test blocked.
  await stop.value
  await #expect(throws: CancellationError.self) { try await start.value }
  #expect(await core.snapshot().state == .stopped)
}

@Test func stoppingCommittedResponseRetainsIncompleteTextWithoutAudio() async throws {
  let backend = ControlledBackend()
  let core = TranslationSession(backend: backend)
  _ = try await core.prepare(configuration: configuration())
  let events = try await core.start()
  defer { withExtendedLifetime(events) {} }
  let s = await core.snapshot()
  let turn = TranslationTurnID()
  try await core.accept(frame: frame(s, turn: turn))
  try await core.commit(turnID: turn)
  await backend.emit(
    .init(
      sessionID: s.sessionID, turnID: turn, generation: s.generation,
      payload: .translationText(.init(text: "spoken prefix", stability: .stableAppend))))
  await settle()
  await core.stop()
  let result = await core.snapshot()
  #expect(result.incompleteTurns.contains(turn))
  #expect(result.transcript.turns.last?.incomplete == true)
  #expect(result.transcript.turns.last?.translatedText == "spoken prefix")
}

@Test func twelveSecondContinuationWaitsEvenDuringPlayback() async throws {
  let backend = ControlledBackend()
  let core = TranslationSession(backend: backend)
  _ = try await core.prepare(configuration: configuration())
  let events = try await core.start()
  defer { withExtendedLifetime(events) {} }
  let s = await core.snapshot()
  let first = TranslationTurnID()
  let second = TranslationTurnID()
  try await core.accept(frame: frame(s, turn: first, seconds: 12))
  try await core.commit(turnID: first)
  await core.setOutputPlaying(true)
  try await core.accept(frame: frame(s, turn: second, sequence: 1, seconds: 12))
  try await core.commit(turnID: second)
  #expect(await core.snapshot().activeTurnID == first)
  #expect(await core.snapshot().waitingTurnID == second)
  #expect(await core.snapshot().activity.acceptingInput)
  #expect(await backend.commits == [first])
  await core.stop()
}

@Test func retryExpiresAndStopErasesIt() async throws {
  let backend = ControlledBackend()
  let core = TranslationSession(backend: backend)
  var config = configuration()
  config.buffering.retryRetentionSeconds = 0
  _ = try await core.prepare(configuration: config)
  let events = try await core.start()
  defer { withExtendedLifetime(events) {} }
  let s = await core.snapshot()
  let turn = TranslationTurnID()
  try await core.accept(frame: frame(s, turn: turn))
  try await core.commit(turnID: turn)
  await backend.emit(
    .init(
      sessionID: s.sessionID, turnID: turn, generation: s.generation, payload: .turnCompleted)
  )
  await settle()
  await #expect(throws: TranslationFailure.self) { try await core.retryLastTurn() }
  await core.stop()
  await #expect(throws: TranslationFailure.self) { try await core.retryLastTurn() }
}

actor SendingBackend: TranslationBackend {
  var sending = false
  var sendContinuation: CheckedContinuation<Void, Error>?
  var didStop = false
  var continuation: AsyncThrowingStream<TranslationEvent, Error>.Continuation?
  func prepare(configuration: TranslationConfiguration) async throws -> TranslationCapabilities {
    .init(inputLanguages: ["en"], outputLanguages: ["nl"])
  }
  func start(sessionID: TranslationSessionID, generation: TranslationGeneration) async throws
    -> AsyncThrowingStream<TranslationEvent, Error>
  {
    let pair = AsyncThrowingStream<TranslationEvent, Error>.makeStream(
      bufferingPolicy: .bufferingOldest(4))
    continuation = pair.continuation
    return pair.stream
  }
  func send(frame: OwnedPCMFrame) async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        sendContinuation = $0
        sending = true
      }
    } onCancel: {
      Task { await self.releaseSend() }
    }
  }
  func releaseSend() {
    sendContinuation?.resume(throwing: CancellationError())
    sendContinuation = nil
  }
  func commit(turnID: TranslationTurnID) async throws {}
  func cancel(turnID: TranslationTurnID) async {}
  func stop() async {
    didStop = true
    continuation?.finish()
    continuation = nil
  }
}

@Test func stopCancelsOutstandingSendBeforeReleaseBarrier() async throws {
  let backend = SendingBackend()
  let core = TranslationSession(backend: backend)
  _ = try await core.prepare(configuration: configuration())
  let events = try await core.start()
  defer { withExtendedLifetime(events) {} }
  let s = await core.snapshot()
  let turn = TranslationTurnID()
  let sending = Task { try await core.accept(frame: frame(s, turn: turn)) }
  for _ in 0..<10_000 {
    if await backend.sending { break }
    await Task.yield()
  }
  let stopping = Task { await core.stop() }
  await settle()
  #expect(await backend.didStop)
  // Release a broken implementation without leaving a minute-long test.
  await backend.releaseSend()
  await stopping.value
  await #expect(throws: CancellationError.self) { try await sending.value }
}

@Test func tentativeTwoPassTextCannotTriggerSpeech() async throws {
  let backend = ControlledBackend()
  let core = TranslationSession(backend: backend)
  var config = configuration()
  config.provider = .lfm3OmniTwoPass
  config.outputMode = .speechAndCaptions
  _ = try await core.prepare(configuration: config)
  let stream = try await core.start()
  let collector = EventCollector()
  let reader = Task {
    do { for try await event in stream { await collector.record(event) } } catch {}
  }
  let s = await core.snapshot()
  let turn = TranslationTurnID()
  try await core.accept(frame: frame(s, turn: turn))
  try await core.commit(turnID: turn)
  await backend.emit(
    .init(
      sessionID: s.sessionID, turnID: turn, generation: s.generation,
      payload: .translationText(.init(text: "tentative", stability: .tentative))))
  await backend.emit(
    .init(
      sessionID: s.sessionID, turnID: turn, generation: s.generation,
      payload: .audio(
        .init(
          bytes: Data(repeating: 0, count: 320),
          format: .init(
            sampleRate: 16_000, channels: 1, encoding: .signedInt16LittleEndian),
          sequence: 0))))
  await settle()
  #expect(!(await collector.hasAudio()))
  #expect(await core.snapshot().lastFailure?.code == .invalidEvent)
  await core.stop()
  await reader.value
}

@Test func stableTwoPassTextAllowsStreamingSpeechBeforeCompletion() async throws {
  let backend = ControlledBackend()
  let core = TranslationSession(backend: backend)
  var config = configuration()
  config.provider = .lfm3OmniTwoPass
  config.outputMode = .speechAndCaptions
  _ = try await core.prepare(configuration: config)
  let stream = try await core.start()
  let collector = EventCollector()
  let reader = Task {
    do { for try await event in stream { await collector.record(event) } } catch {}
  }
  let s = await core.snapshot()
  let turn = TranslationTurnID()
  try await core.accept(frame: frame(s, turn: turn))
  try await core.commit(turnID: turn)
  await backend.emit(
    .init(
      sessionID: s.sessionID, turnID: turn, generation: s.generation,
      payload: .translationText(.init(text: "stable clause", stability: .stableAppend))))
  await backend.emit(
    .init(
      sessionID: s.sessionID, turnID: turn, generation: s.generation,
      payload: .audio(
        .init(
          bytes: Data(repeating: 0, count: 320),
          format: .init(
            sampleRate: 16_000, channels: 1, encoding: .signedInt16LittleEndian),
          sequence: 0))))
  await settle()
  #expect(await collector.hasAudio())
  #expect(await core.snapshot().activeTurnID == turn)
  await core.stop()
  await reader.value
}

@Test func newSpeechDuringContextReleaseWaitsForFreshStart() async throws {
  let backend = ControlledBackend()
  let core = TranslationSession(backend: backend)
  _ = try await core.prepare(configuration: configuration())
  let stream = try await core.start()
  defer { withExtendedLifetime(stream) {} }
  let firstState = await core.snapshot()
  let first = TranslationTurnID()
  let next = TranslationTurnID()
  try await core.accept(frame: frame(firstState, turn: first))
  try await core.commit(turnID: first)
  await backend.holdStop()
  await backend.emit(
    .init(
      sessionID: firstState.sessionID, turnID: first, generation: firstState.generation,
      payload: .turnCompleted))
  for _ in 0..<10_000 {
    if await backend.isHoldingStop() { break }
    await Task.yield()
  }
  let resettingState = await core.snapshot()
  let sending = Task {
    try await core.accept(frame: frame(resettingState, turn: next, sequence: 1))
  }
  await settle()
  #expect(await core.snapshot().waitingTurnID == next)
  await backend.releaseStop()
  do { try await sending.value } catch {
    Issue.record("New speech was lost during context release: \(error)")
  }
  await settle()
  #expect(await backend.frames.last?.turnID == next)
  #expect(await core.snapshot().lastFailure == nil)
  await core.stop()
}

@Test func releasingSessionStopsItsProducer() async throws {
  let backend = ControlledBackend()
  var core: TranslationSession? = TranslationSession(backend: backend)
  _ = try await core!.prepare(configuration: configuration())
  let stream = try await core!.start()
  defer { withExtendedLifetime(stream) {} }
  weak let reference = core
  core = nil
  await settle()
  #expect(reference == nil)
  #expect(await backend.stopped)
}

@Test func queuedAudioUsesDurationBudgetRatherThanEventCount() async throws {
  let backend = ControlledBackend()
  let core = TranslationSession(backend: backend)
  var config = configuration()
  config.outputMode = .speechAndCaptions
  _ = try await core.prepare(configuration: config)
  let stream = try await core.start()
  defer { withExtendedLifetime(stream) {} }
  let state = await core.snapshot()
  let turn = TranslationTurnID()
  try await core.accept(frame: frame(state, turn: turn))
  try await core.commit(turnID: turn)
  for sequence in 0..<3 {
    await backend.emit(
      .init(
        sessionID: state.sessionID, turnID: turn, generation: state.generation,
        payload: .audio(
          .init(
            bytes: Data(repeating: 0, count: 32_000),
            format: .init(sampleRate: 16000, channels: 1, encoding: .signedInt16LittleEndian),
            sequence: UInt64(sequence)))))
  }
  await settle()
  #expect(await core.snapshot().lastFailure?.code == .consumerOverload)
  #expect(await core.snapshot().state == .paused)
  await core.stop()
}

@Test func failureEventUsesTheInvalidatedCurrentGeneration() async throws {
  let backend = ControlledBackend()
  let core = TranslationSession(backend: backend)
  _ = try await core.prepare(configuration: configuration())
  let stream = try await core.start()
  let state = await core.snapshot()
  let turn = TranslationTurnID()
  try await core.accept(frame: frame(state, turn: turn))
  try await core.commit(turnID: turn)
  await backend.emit(
    .init(
      sessionID: state.sessionID, turnID: turn, generation: state.generation,
      payload: .failure(.init(code: .providerFailure, message: "fixture failure"))))
  await settle()
  let current = await core.snapshot()
  var foundFailure = false
  for try await event in stream {
    if case .failure = event.payload {
      foundFailure = true
      #expect(event.generation == current.generation)
      break
    }
  }
  #expect(foundFailure)
  await core.stop()
}

@Test func oneAudioAdmissionMovesAcrossProviderCoreAndHostWithoutDoubleCounting() async throws {
  let budget = TranslationAudioTransportBudget()
  let backend = ControlledBackend()
  let core = TranslationSession(backend: backend)
  var config = configuration()
  config.outputMode = .speechAndCaptions
  config.audioTransportBudget = budget
  _ = try await core.prepare(configuration: config)
  let stream = try await core.start()
  let snapshot = await core.snapshot()
  let turn = TranslationTurnID()
  try await core.accept(frame: frame(snapshot, turn: turn))
  try await core.commit(turnID: turn)
  let chunk = try TranslationAudioChunk(
    bytes: Data(repeating: 0, count: 48_000),
    format: .init(sampleRate: 16000, channels: 1, encoding: .signedInt16LittleEndian), sequence: 0
  )
  .admitted(to: budget)
  let forwarded = try chunk.admitted(to: budget)
  #expect(budget.reservedSeconds == 1.5)
  await backend.emit(
    .init(
      sessionID: snapshot.sessionID, turnID: turn, generation: snapshot.generation,
      payload: .audio(forwarded)))
  await settle()
  #expect(budget.reservedSeconds == 1.5)
  for try await event in stream {
    if case .audio = event.payload {
      event.acknowledgeAudioDelivery()
      event.acknowledgeAudioDelivery()  // release must be idempotent across copied values
      break
    }
  }
  #expect(budget.reservedSeconds == 0)
  await core.stop()
}

@Test func oldQueuedAudioStillCountsAfterContextRollover() async throws {
  let budget = TranslationAudioTransportBudget()
  let backend = ControlledBackend()
  let core = TranslationSession(backend: backend)
  var config = configuration()
  config.outputMode = .speechAndCaptions
  config.audioTransportBudget = budget
  _ = try await core.prepare(configuration: config)
  let stream = try await core.start()
  defer { withExtendedLifetime(stream) {} }
  let snapshot = await core.snapshot()
  let first = TranslationTurnID()
  try await core.accept(frame: frame(snapshot, turn: first))
  try await core.commit(turnID: first)
  await backend.emit(
    .init(
      sessionID: snapshot.sessionID, turnID: first, generation: snapshot.generation,
      payload: .audio(
        .init(
          bytes: Data(repeating: 0, count: 57_600),
          format: .init(sampleRate: 16000, channels: 1, encoding: .signedInt16LittleEndian),
          sequence: 0))))
  await backend.emit(
    .init(
      sessionID: snapshot.sessionID, turnID: first, generation: snapshot.generation,
      payload: .turnCompleted))
  await settle()
  #expect(budget.reservedSeconds == 1.8)
  let next = await core.snapshot()
  let second = TranslationTurnID()
  try await core.accept(frame: frame(next, turn: second, sequence: 1))
  try await core.commit(turnID: second)
  await backend.emit(
    .init(
      sessionID: next.sessionID, turnID: second, generation: next.generation,
      payload: .audio(
        .init(
          bytes: Data(repeating: 0, count: 12_800),
          format: .init(sampleRate: 16000, channels: 1, encoding: .signedInt16LittleEndian),
          sequence: 0))))
  await settle()
  #expect(await core.snapshot().lastFailure?.code == .consumerOverload)
  #expect(budget.reservedSeconds <= 2)
  await core.stop()
}

@Test func completeFailedInputCanBeRetriedOnceWithFreshContext() async throws {
  let backend = ControlledBackend()
  let core = TranslationSession(backend: backend)
  _ = try await core.prepare(configuration: configuration())
  let stream = try await core.start()
  defer { withExtendedLifetime(stream) {} }
  let before = await core.snapshot()
  let original = TranslationTurnID()
  try await core.accept(frame: frame(before, turn: original))
  try await core.commit(turnID: original)
  await backend.emit(
    .init(
      sessionID: before.sessionID, turnID: original, generation: before.generation,
      payload: .failure(.init(code: .providerFailure, message: "fixture"))))
  await settle()
  let failed = await core.snapshot()
  #expect(failed.state == .paused)
  #expect(failed.canRetry)
  try await core.retryLastTurn()
  let retried = await core.snapshot()
  #expect(retried.state == .running)
  #expect(retried.activeTurnID != original)
  #expect(!retried.canRetry)
  #expect(await backend.starts == 2)
  let sent = await backend.frames
  #expect(sent.count == 2)
  #expect(sent[0].bytes == sent[1].bytes)
  #expect(sent[1].generation == retried.generation)
  #expect(sent[0].generation != sent[1].generation)
  await core.stop()
}

private actor ControlledTranslationClock: TranslationClock {
  private var waiter: CheckedContinuation<Void, Error>?
  private(set) var requestedSeconds: Double?
  var isWaiting: Bool { waiter != nil }
  func sleep(for seconds: Double) async throws {
    requestedSeconds = seconds
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { waiter = $0 }
    } onCancel: {
      Task { await self.cancel() }
    }
  }
  func advance() {
    waiter?.resume()
    waiter = nil
  }
  func cancel() {
    waiter?.resume(throwing: CancellationError())
    waiter = nil
  }
}

@Test func retryExpiryUsesInjectedClockAndPublishesAvailability() async throws {
  let clock = ControlledTranslationClock()
  let backend = ControlledBackend()
  let core = TranslationSession(backend: backend, clock: clock)
  _ = try await core.prepare(configuration: configuration())
  let stream = try await core.start()
  defer { withExtendedLifetime(stream) {} }
  let snapshot = await core.snapshot()
  let turn = TranslationTurnID()
  try await core.accept(frame: frame(snapshot, turn: turn))
  try await core.commit(turnID: turn)
  await backend.emit(
    .init(
      sessionID: snapshot.sessionID, turnID: turn, generation: snapshot.generation,
      payload: .failure(.init(code: .providerFailure, message: "fixture"))))
  for _ in 0..<10_000 {
    if await clock.isWaiting { break }
    await Task.yield()
  }
  #expect(await core.snapshot().canRetry)
  #expect(await clock.requestedSeconds == 30)
  await clock.advance()
  await settle()
  #expect(!(await core.snapshot().canRetry))
  await #expect(throws: TranslationFailure.self) { try await core.retryLastTurn() }
  await core.stop()
}

@Test func transportBatchAdmissionIsAtomicAndConsumedChunksCannotReenter() throws {
  let budget = TranslationAudioTransportBudget()
  let oneSecond = try TranslationAudioChunk(
    bytes: Data(repeating: 0, count: 32_000),
    format: .init(sampleRate: 16000, channels: 1, encoding: .signedInt16LittleEndian), sequence: 0
  ).admitted(to: budget)
  #expect(throws: TranslationFailure.self) { _ = try budget.reserveBatch(seconds: [0.6, 0.6]) }
  #expect(budget.reservedSeconds == 1)
  oneSecond.acknowledgeDelivery()
  #expect(budget.reservedSeconds == 0)
  #expect(throws: TranslationFailure.self) { _ = try oneSecond.admitted(to: budget) }
}

@Test func droppedAudioValuesReleaseTransportReservationWithoutHostLeak() throws {
  let budget = TranslationAudioTransportBudget()
  do {
    let chunk = try TranslationAudioChunk(
      bytes: Data(repeating: 0, count: 32_000),
      format: .init(sampleRate: 16000, channels: 1, encoding: .signedInt16LittleEndian), sequence: 0
    ).admitted(to: budget)
    withExtendedLifetime(chunk) { #expect(budget.reservedSeconds == 1) }
  }
  #expect(budget.reservedSeconds == 0)
}
