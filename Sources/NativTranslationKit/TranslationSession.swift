import Foundation

/// One session owns one backend. Every provider operation is chained through a
/// release barrier: an older prepare/stop can never tear down a newer start.
public actor TranslationSession {
  public let sessionID = TranslationSessionID()
  private let backend: any TranslationBackend
  private let clock: any TranslationClock
  private var generation = TranslationGeneration()
  private var state: TranslationSessionState = .idle
  private var activity = TranslationActivity()
  private var configuration: TranslationConfiguration?
  private var capabilities: TranslationCapabilities?
  private var active: TranslationSegment?
  private var waiting: TranslationSegment?
  private var retry: TranslationSegment?
  private var retryExpiry: Task<Void, Never>?
  private var incomplete: Set<TranslationTurnID> = []
  private var incompleteIntervals: [TranslationIncompleteInterval] = []
  private var history = TranslationTranscriptBuffer()
  private var lastFailure: TranslationFailure?
  private var contextTokens = 0.0
  private var consumer: Task<Void, Never>?
  private var consumerID: UUID?
  private var preparation: Task<TranslationCapabilities, Error>?
  private var cancelOperation: (@Sendable () -> Void)?
  private var hostStreamID: UUID?
  private var contextUsageKnown = false
  private var resettingContext = false
  private var tail: Task<Void, Never>?
  private var cancellableOperations: [UUID: @Sendable () -> Void] = [:]
  private var continuation: AsyncThrowingStream<TranslationEvent, Error>.Continuation?
  private var lastInput: (source: String, sequence: UInt64, timestamp: UInt64)?

  public init(
    backend: any TranslationBackend, clock: any TranslationClock = TranslationMonotonicClock()
  ) {
    self.backend = backend
    self.clock = clock
  }

  deinit {
    retryExpiry?.cancel()
    consumer?.cancel()
    preparation?.cancel()
    cancelOperation?()
    for cancel in cancellableOperations.values { cancel() }
    continuation?.finish()
    let backend = backend
    let releaseBarrier = tail
    Task {
      if let releaseBarrier { await releaseBarrier.value }
      await backend.stop()
    }
  }

  private func enqueue<T: Sendable>(
    cancellable: Bool = true, _ operation: @escaping @Sendable () async throws -> T
  ) -> Task<T, Error> {
    let predecessor = tail
    let task = Task {
      if let predecessor { await predecessor.value }
      try Task.checkCancellation()
      return try await operation()
    }
    let id = UUID()
    if cancellable { cancellableOperations[id] = { task.cancel() } }
    tail = Task { [weak self] in
      _ = await task.result
      await self?.operationFinished(id)
    }
    return task
  }
  private func operationFinished(_ id: UUID) { cancellableOperations.removeValue(forKey: id) }
  public func snapshot() -> TranslationSessionSnapshot {
    .init(
      sessionID: sessionID, generation: generation, state: state, activity: activity,
      activeTurnID: active?.id, waitingTurnID: waiting?.id, incompleteTurns: incomplete,
      incompleteIntervals: incompleteIntervals,
      transcript: history, lastFailure: lastFailure,
      canRetry: retry != nil && active == nil && !resettingContext
        && (state == .running || state == .paused))
  }
  public func prepare(configuration: TranslationConfiguration) async throws
    -> TranslationCapabilities
  {
    try configuration.buffering.validate()
    guard [.idle, .stopped, .failed].contains(state) else { throw invalidState() }
    state = .preparing
    self.configuration = configuration
    lastFailure = nil
    let epoch = generation
    let backend = backend
    let task = enqueue { try await backend.prepare(configuration: configuration) }
    preparation = task
    cancelOperation = { task.cancel() }
    do {
      let result = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
      guard generation == epoch, state == .preparing, !Task.isCancelled else {
        throw CancellationError()
      }
      guard result.inputLanguages.contains(configuration.languagePair.source),
        result.outputLanguages.contains(configuration.languagePair.target)
      else {
        throw TranslationFailure(
          code: .unsupportedLanguage,
          message: "The selected runtime does not support this language direction.")
      }
      guard configuration.outputMode != .speechAndCaptions || result.supportsAudioOutput
      else {
        throw TranslationFailure(
          code: .unsupportedOutput,
          message: "This runtime does not provide speech output.")
      }
      guard configuration.directionMode != .automatic || result.automaticDirectionQualified
      else {
        throw TranslationFailure(
          code: .invalidConfiguration,
          message:
            "Automatic direction requires measured bilingual qualification; choose a fixed direction."
        )
      }
      self.capabilities = result
      preparation = nil
      cancelOperation = nil
      state = .ready
      return result
    } catch {
      if generation == epoch {
        preparation = nil
        cancelOperation = nil
        state = .failed
        let cleanup = enqueue(cancellable: false) { await backend.stop() }
        _ = await cleanup.result
      }
      throw error
    }
  }
  public func start() async throws -> AsyncThrowingStream<TranslationEvent, Error> {
    guard state == .ready, let configuration else { throw invalidState() }
    state = .preparing
    let epoch = generation
    let backend = backend
    let sessionID = sessionID
    let task = enqueue { try await backend.start(sessionID: sessionID, generation: epoch) }
    cancelOperation = { task.cancel() }
    do {
      let stream = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
      guard generation == epoch, state == .preparing, !Task.isCancelled else {
        throw CancellationError()
      }
      let pair = AsyncThrowingStream<TranslationEvent, Error>.makeStream(
        bufferingPolicy: .bufferingOldest(configuration.buffering.eventCapacity))
      continuation = pair.continuation
      cancelOperation = nil
      let streamID = UUID()
      hostStreamID = streamID
      pair.continuation.onTermination = { [weak self] _ in
        Task { await self?.hostTerminated(streamID: streamID) }
      }
      state = .running
      activity.acceptingInput = true
      consume(stream, epoch: epoch)
      publishState()
      return pair.stream
    } catch {
      if generation == epoch {
        state = .failed
        let cleanup = enqueue(cancellable: false) { await backend.stop() }
        _ = await cleanup.result
      }
      throw error
    }
  }
  private func consume(
    _ stream: AsyncThrowingStream<TranslationEvent, Error>, epoch: TranslationGeneration
  ) {
    let streamID = UUID()
    consumerID = streamID
    consumer = Task { [weak self] in
      do {
        for try await event in stream {
          guard !Task.isCancelled else { return }
          await self?.receive(event, epoch: epoch, streamID: streamID)
        }
        guard !Task.isCancelled else { return }
        await self?.providerStreamEnded(
          epoch: epoch, streamID: streamID,
          failure: .init(
            code: .unexpectedStreamEnd,
            message: "Translation runtime disconnected; repeat the incomplete turn."))
      } catch {
        guard !Task.isCancelled else { return }
        await self?.providerStreamEnded(
          epoch: epoch, streamID: streamID,
          failure: .init(
            code: .providerFailure,
            message: "Translation runtime failed; repeat the incomplete turn."))
      }
    }
  }
  public func accept(frame: OwnedPCMFrame) async throws {
    guard frame.sessionID == sessionID, frame.generation == generation else {
      throw TranslationFailure(
        code: .staleInput, message: "Audio belongs to a stopped session generation.")
    }
    guard state == .running, activity.acceptingInput, let configuration else {
      throw invalidState()
    }
    guard frame.sourceID.utf8.count <= 256 else {
      throw TranslationFailure(code: .invalidAudio, message: "Invalid audio source identity.")
    }
    if let format = capabilities?.inputFormat, frame.format != format {
      throw TranslationFailure(
        code: .invalidAudio,
        message: "Audio format does not match the negotiated runtime format.")
    }
    if let lastInput {
      guard lastInput.source == frame.sourceID, frame.sequence > lastInput.sequence,
        frame.captureTimestampNanoseconds >= lastInput.timestamp
      else {
        throw TranslationFailure(
          code: .invalidAudio, message: "Audio source sequence is stale or mixed.")
      }
    }
    var target: TranslationSegment
    let isActive: Bool
    if history.turns.contains(where: { $0.turnID == frame.turnID })
      || incomplete.contains(frame.turnID)
    {
      throw TranslationFailure(
        code: .staleInput,
        message: "This source turn has already completed or was discarded.")
    }
    if resettingContext {
      if let pending = waiting, pending.id == frame.turnID {
        target = pending
      } else if waiting == nil {
        target = .init(id: frame.turnID)
      } else {
        await failInterval(frame.turnID, failure: overload(), lostFrame: frame)
        throw overload()
      }
      isActive = false
    } else if let current = active, current.id == frame.turnID {
      target = current
      isActive = true
    } else if let pending = waiting, pending.id == frame.turnID {
      target = pending
      isActive = false
    } else if active == nil {
      target = .init(id: frame.turnID)
      isActive = true
    } else if waiting == nil, active?.committed == true {
      target = .init(id: frame.turnID)
      isActive = false
    } else {
      await failInterval(frame.turnID, failure: overload(), lostFrame: frame)
      throw overload()
    }
    guard !target.committed else {
      throw TranslationFailure(
        code: .invalidAudio, message: "Audio arrived after the turn boundary was committed."
      )
    }
    do {
      try target.append(frame, maximumSeconds: configuration.buffering.maximumSegmentSeconds)
    } catch let error as TranslationFailure {
      await failInterval(frame.turnID, failure: error, lostFrame: frame)
      throw error
    }
    lastInput = (frame.sourceID, frame.sequence, frame.captureTimestampNanoseconds)
    if isActive {
      active = target
      let epoch = generation
      let backend = backend
      let task = enqueue { try await backend.send(frame: frame) }
      do {
        try await withTaskCancellationHandler {
          try await task.value
        } onCancel: {
          task.cancel()
        }
        guard generation == epoch else { throw CancellationError() }
      } catch {
        if generation == epoch {
          await failInterval(frame.turnID, failure: providerFailure())
        }
        throw error
      }
    } else {
      waiting = target
    }
  }
  public func commit(turnID: TranslationTurnID) async throws {
    guard state == .running || state == .paused else { throw invalidState() }
    if waiting?.id == turnID {
      guard waiting?.committed == false else { throw invalidState() }
      waiting?.committed = true
      return
    }
    guard active?.id == turnID, active?.committed == false else { throw invalidState() }
    active?.committed = true
    activity.generating = true
    let epoch = generation
    publishState()
    guard generation == epoch else { throw lastFailure ?? invalidState() }
    let backend = backend
    let task = enqueue { try await backend.commit(turnID: turnID) }
    do {
      try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
      guard generation == epoch else { throw CancellationError() }
    } catch {
      if generation == epoch { await failInterval(turnID, failure: providerFailure()) }
      throw error
    }
  }
  public func pause() {
    guard state == .running else { return }
    state = .paused
    activity.acceptingInput = false
    publishState()
  }
  public func resume() {
    guard state == .paused, lastFailure == nil else { return }
    state = .running
    activity.acceptingInput = true
    publishState()
  }
  /// Playback is host-owned and orthogonal to accepting input and inference.
  public func setOutputPlaying(_ playing: Bool) {
    activity.playingOutput = playing
    publishState()
  }
  public func stop() async {
    if let id = active?.id { markIncomplete(id) }
    if let id = waiting?.id { markIncomplete(id) }
    invalidate()
    state = .stopping
    activity = .init()
    clearAudio()
    resettingContext = false
    active = nil
    waiting = nil
    lastInput = nil
    hostStreamID = nil
    continuation?.finish()
    continuation = nil
    let epoch = generation
    let backend = backend
    _ = await enqueue(cancellable: false) { await backend.stop() }.result
    if generation == epoch { state = .stopped }
  }
  /// Explicit speech interruption: invalidate callbacks, discard the current response,
  /// reset provider context, then preserve and process the single waiting source turn.
  public func interrupt() async {
    guard state == .running || state == .paused else { return }
    let pending = waiting
    if let active { markIncomplete(active.id) }
    let previousID = active?.id
    let backend = backend
    invalidate()
    clearAudio()
    resettingContext = false
    active = nil
    waiting = nil
    lastInput = nil
    state = .paused
    activity = .init()
    publishState()
    let epoch = generation
    _ = await enqueue(cancellable: false) {
      if let previousID { await backend.cancel(turnID: previousID) }
      await backend.stop()
    }.result
    guard generation == epoch else { return }
    do {
      try await restart(epoch: epoch)
      try await promote(pending, epoch: epoch)
    } catch {
      if generation == epoch { await streamEnded(epoch: epoch, failure: providerFailure()) }
    }
  }
  public func retryLastTurn() async throws {
    guard state == .running || state == .paused, !resettingContext, active == nil, let retry else {
      throw invalidState()
    }
    self.retry = nil
    retryExpiry?.cancel()
    retryExpiry = nil
    var replacement = TranslationSegment(id: .init())
    replacement.frames = retry.frames.map { retag($0, turn: replacement.id) }
    replacement.duration = retry.duration
    replacement.committed = true
    if state == .paused {
      let epoch = generation
      resettingContext = true
      do {
        try await restart(epoch: epoch)
        guard epoch == generation else { throw CancellationError() }
        resettingContext = false
      } catch {
        if epoch == generation {
          resettingContext = false
          await streamEnded(epoch: epoch, failure: providerFailure())
        }
        throw error
      }
    }
    try await promote(replacement, epoch: generation)
  }
  private func restart(epoch: TranslationGeneration) async throws {
    let backend = backend
    let sessionID = sessionID
    let stream = try await enqueue {
      try await backend.start(sessionID: sessionID, generation: epoch)
    }.value
    guard generation == epoch else { throw CancellationError() }
    contextTokens = 0
    contextUsageKnown = false
    lastFailure = nil
    state = .running
    activity.acceptingInput = true
    consume(stream, epoch: epoch)
    publishState()
  }
  private func retag(_ frame: OwnedPCMFrame, turn: TranslationTurnID) -> OwnedPCMFrame {
    .init(
      bytes: frame.bytes, format: frame.format,
      captureTimestampNanoseconds: frame.captureTimestampNanoseconds,
      sequence: frame.sequence,
      sourceID: frame.sourceID, sessionID: sessionID, turnID: turn, generation: generation)
  }
  private func promote(_ segment: TranslationSegment?, epoch: TranslationGeneration) async throws {
    guard var segment, generation == epoch else { return }
    segment.frames = segment.frames.map { retag($0, turn: segment.id) }
    active = segment
    waiting = nil
    activity.generating = segment.committed
    let backend = backend
    let frames = segment.frames
    let id = segment.id
    let committed = segment.committed
    try await enqueue {
      for frame in frames {
        try Task.checkCancellation()
        try await backend.send(frame: frame)
      }
      if committed { try await backend.commit(turnID: id) }
    }.value
    guard generation == epoch else { throw CancellationError() }
    publishState()
  }
  private func receive(_ event: TranslationEvent, epoch: TranslationGeneration, streamID: UUID)
    async
  {
    guard consumerID == streamID, epoch == generation, event.generation == generation,
      event.sessionID == sessionID,
      state == .running || state == .paused
    else { return }
    do {
      if let turnID = event.turnID, active?.id != turnID { return }
      switch event.payload {
      case .metrics(let metric):
        guard metric.value.isFinite, metric.value >= 0 else {
          throw TranslationFailure(
            code: .invalidEvent, message: "Invalid runtime metric.")
        }
        if metric.name == .contextTokens {
          contextTokens = max(contextTokens, metric.value)
          contextUsageKnown = true
        }
        emit(event)
      case .failure(let failure): await failInterval(event.turnID, failure: failure)
      // Session state belongs to the core, never to provider callbacks.
      case .state, .contextRolledOver: break
      default:
        guard let id = event.turnID, active?.id == id else { return }
        switch event.payload {
        case .sourceText(let update):
          guard capabilities?.sourceTranscriptAvailable == true else {
            throw TranslationFailure(
              code: .invalidEvent,
              message: "Provider emitted an undeclared source transcript.")
          }
          _ = try active?.source.apply(update)
          emit(event)
        case .translationText(let update):
          _ = try active?.target.apply(update)
          emit(event)
        case .audio(let chunk):
          guard chunk.committed, capabilities?.supportsAudioOutput == true,
            configuration?.outputMode == .speechAndCaptions
          else {
            throw TranslationFailure(
              code: .invalidEvent,
              message: "Provider emitted uncommitted or unsupported speech.")
          }
          if configuration?.provider != .lfm3OmniDirect,
            active?.target.committedText.isEmpty != false
          {
            throw TranslationFailure(
              code: .invalidEvent,
              message:
                "Speech synthesis requires an explicit stable clause or final translated segment."
            )
          }
          let duration = try chunk.format.duration(byteCount: chunk.bytes.count)
          guard duration <= 5,
            active?.lastOutputSequence.map({ chunk.sequence > $0 }) ?? true
          else {
            throw TranslationFailure(
              code: .invalidEvent,
              message: "Duplicate, unordered or oversized speech chunk.")
          }
          guard let budget = configuration?.audioTransportBudget else { throw invalidState() }
          let admitted = try chunk.admitted(to: budget)
          active?.lastOutputSequence = chunk.sequence
          emit(
            .init(
              sessionID: event.sessionID, turnID: event.turnID,
              generation: event.generation, payload: .audio(admitted)))
        case .turnCompleted:
          guard let completed = active, completed.committed else {
            throw TranslationFailure(
              code: .invalidEvent,
              message: "Runtime completed an uncommitted source turn.")
          }
          history.append(
            .init(
              turnID: id,
              sourceText: capabilities?.sourceTranscriptAvailable == true
                ? completed.source.text : nil,
              translatedText: completed.target.text,
              incomplete: false))
          retainRetry(completed)
          active = nil
          activity.generating = false
          emit(event)
          let pending = waiting
          waiting = nil
          if let configuration,
            !contextUsageKnown
              || contextTokens >= Double(configuration.buffering.contextTokenLimit)
                * configuration.buffering.contextRolloverFraction
          {
            waiting = pending
            resettingContext = true
            cancelConsumer()
            publishState()
            let fresh = generation
            let backend = backend
            _ = await enqueue(cancellable: false) { await backend.stop() }.result
            guard generation == fresh else { return }
            let wasPaused = state == .paused
            do {
              try await restart(epoch: fresh)
              if wasPaused {
                state = .paused
                activity.acceptingInput = false
              }
              emit(
                .init(
                  sessionID: sessionID, generation: generation,
                  payload: .contextRolledOver))
              let next = waiting
              resettingContext = false
              try await promote(next, epoch: fresh)
            } catch {
              if generation == fresh {
                await streamEnded(epoch: fresh, failure: providerFailure())
              }
              return
            }
          } else {
            contextUsageKnown = false
            try await promote(pending, epoch: epoch)
          }
          publishState()
        default: break
        }
      }
    } catch {
      if generation == epoch {
        await failInterval(
          event.turnID, failure: (error as? TranslationFailure) ?? providerFailure())
      }
    }
  }
  private func retainRetry(_ segment: TranslationSegment) {
    retryExpiry?.cancel()
    retry = segment
    let seconds = configuration?.buffering.retryRetentionSeconds ?? 0
    let id = segment.id
    let clock = clock
    retryExpiry = Task { [weak self] in
      do {
        try await clock.sleep(for: seconds)
        await self?.expireRetry(id)
      } catch {}
    }
  }
  private func expireRetry(_ id: TranslationTurnID) {
    if retry?.id == id {
      retry = nil
      retryExpiry = nil
      publishState()
    }
  }
  private func markIncomplete(_ id: TranslationTurnID, lostFrame: OwnedPCMFrame? = nil) {
    let segment = active?.id == id ? active : (waiting?.id == id ? waiting : nil)
    let first = segment?.frames.first ?? lostFrame
    let last = lostFrame ?? segment?.frames.last
    let end: UInt64? = last.map { frame in
      let duration = (try? frame.format.duration(byteCount: frame.bytes.count)) ?? 0
      let nanoseconds = UInt64(min(duration * 1_000_000_000, Double(UInt64.max / 2)))
      let sum = frame.captureTimestampNanoseconds.addingReportingOverflow(nanoseconds)
      return sum.overflow ? UInt64.max : sum.partialValue
    }
    if !incomplete.contains(id) {
      incompleteIntervals.append(
        .init(
          turnID: id, sourceID: first?.sourceID,
          startCaptureTimestampNanoseconds: first?.captureTimestampNanoseconds,
          endCaptureTimestampNanoseconds: end))
      if incompleteIntervals.count > 200 { incompleteIntervals.removeFirst() }
      incomplete = Set(incompleteIntervals.map(\.turnID))
      if let segment {
        history.append(
          .init(
            turnID: id,
            sourceText: capabilities?.sourceTranscriptAvailable == true
              ? segment.source.text : nil, translatedText: segment.target.text,
            incomplete: true))
      }
    }
  }
  private func failInterval(
    _ id: TranslationTurnID?, failure: TranslationFailure, lostFrame: OwnedPCMFrame? = nil
  ) async {
    if let id { markIncomplete(id, lostFrame: lostFrame) }
    if let id = active?.id { if !incomplete.contains(id) { markIncomplete(id) } }
    if let id = waiting?.id { markIncomplete(id) }
    // Retain only a complete source segment for an explicit retry. Partial input must be repeated.
    let failedInput = failure.recoverable && active?.committed == true ? active : nil
    invalidate()
    clearAudio()
    if let failedInput { retainRetry(failedInput) }
    resettingContext = false
    active = nil
    waiting = nil
    lastInput = nil
    lastFailure = failure
    state = .paused
    activity = .init()
    emit(
      .init(sessionID: sessionID, turnID: id, generation: generation, payload: .failure(failure)))
    publishState()
    let backend = backend
    _ = await enqueue(cancellable: false) { await backend.stop() }.result
  }
  private func providerStreamEnded(
    epoch: TranslationGeneration, streamID: UUID, failure: TranslationFailure
  ) async {
    guard consumerID == streamID else { return }
    await streamEnded(epoch: epoch, failure: failure)
  }
  private func streamEnded(epoch: TranslationGeneration, failure: TranslationFailure) async {
    guard generation == epoch else { return }
    await failInterval(active?.id, failure: failure)
  }
  private func hostTerminated(streamID: UUID) async {
    guard hostStreamID == streamID else { return }
    await stop()
  }
  private func cancelConsumer() {
    consumerID = nil
    consumer?.cancel()
    consumer = nil
  }
  private func invalidate() {
    generation = .init(generation.rawValue &+ 1)
    cancelConsumer()
    preparation?.cancel()
    preparation = nil
    cancelOperation?()
    cancelOperation = nil
    for cancel in cancellableOperations.values { cancel() }
    cancellableOperations.removeAll()
  }
  private func clearAudio() {
    retryExpiry?.cancel()
    retryExpiry = nil
    retry = nil
  }
  private func publishState() {
    emit(.init(sessionID: sessionID, generation: generation, payload: .state(state, activity)))
  }
  private func emit(_ event: TranslationEvent) {
    guard let continuation else { return }
    if case .dropped = continuation.yield(event) {
      let failure = TranslationFailure(
        code: .consumerOverload,
        message:
          "The translation consumer fell behind; output was stopped and the interval is incomplete."
      )
      if let id = active?.id { markIncomplete(id) }
      if let id = waiting?.id { markIncomplete(id) }
      invalidate()
      clearAudio()
      active = nil
      waiting = nil
      activity = .init()
      state = .failed
      lastFailure = failure
      self.continuation = nil
      hostStreamID = nil
      continuation.finish(throwing: failure)
      let backend = backend
      _ = enqueue(cancellable: false) { await backend.stop() }
    }
  }
  private func invalidState() -> TranslationFailure {
    .init(code: .invalidState, message: "Translation is not ready for this operation.")
  }
  private func overload() -> TranslationFailure {
    .init(
      code: .overload,
      message:
        "Translation capacity was exceeded. This interval is incomplete; stop and repeat it."
    )
  }
  private func providerFailure() -> TranslationFailure {
    .init(
      code: .providerFailure,
      message: "The local translation runtime failed. Repeat the incomplete turn.")
  }
}
