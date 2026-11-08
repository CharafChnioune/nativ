import Foundation

public protocol TranslationClock: Sendable {
  func sleep(for seconds: Double) async throws
}
public struct TranslationMonotonicClock: TranslationClock {
  public init() {}
  public func sleep(for seconds: Double) async throws {
    try await Task.sleep(for: .seconds(seconds))
  }
}

public struct TranslationSessionID: Hashable, Codable, Sendable {
  public let rawValue: UUID
  public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}
public struct TranslationTurnID: Hashable, Codable, Sendable {
  public let rawValue: UUID
  public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}
public struct TranslationGeneration: Hashable, Codable, Sendable {
  public let rawValue: UInt64
  public init(_ rawValue: UInt64 = 0) { self.rawValue = rawValue }
}
public struct TranslationLanguagePair: Hashable, Codable, Sendable {
  public let source: String
  public let target: String
  public init(source: String, target: String) {
    self.source = source
    self.target = target
  }
}
public enum TranslationDirectionMode: String, Codable, Sendable { case fixed, automatic }
public enum TranslationSource: String, Codable, Sendable { case microphone, systemAudio }
public enum TranslationOutputMode: String, Codable, Sendable { case captions, speechAndCaptions }
public enum TranslationProviderID: String, Codable, Sendable {
  case lfm3OmniDirect, lfm3OmniTwoPass, localCascade, appleSpeech
}
public struct TranslationBufferingPolicy: Equatable, Sendable {
  public var maximumSegmentSeconds: Double = 12
  public var retryRetentionSeconds: Double = 30
  public var eventCapacity: Int = 128
  public var contextTokenLimit: Int = 4096
  public var contextRolloverFraction: Double = 0.70
  public init() {}
  public func validate() throws {
    guard maximumSegmentSeconds > 0, maximumSegmentSeconds <= 12, retryRetentionSeconds >= 0,
      retryRetentionSeconds <= 30, eventCapacity >= 4, eventCapacity <= 1024,
      contextTokenLimit > 0,
      contextRolloverFraction > 0, contextRolloverFraction < 0.75
    else {
      throw TranslationFailure(
        code: .invalidConfiguration,
        message: "Buffer or context bounds exceed safety limits.")
    }
  }
}
public struct TranslationConfiguration: Equatable, Sendable {
  public var languagePair: TranslationLanguagePair
  public var directionMode: TranslationDirectionMode
  public var source: TranslationSource
  public var outputMode: TranslationOutputMode
  public var provider: TranslationProviderID
  public var allowExperimentalAutomaticDirection: Bool
  public var buffering: TranslationBufferingPolicy
  /// One duration budget shared by every output transport stage in this session.
  public var audioTransportBudget: TranslationAudioTransportBudget
  public init(
    languagePair: TranslationLanguagePair, directionMode: TranslationDirectionMode = .fixed,
    source: TranslationSource = .microphone, outputMode: TranslationOutputMode = .captions,
    provider: TranslationProviderID, buffering: TranslationBufferingPolicy = .init(),
    audioTransportBudget: TranslationAudioTransportBudget = .init(),
    allowExperimentalAutomaticDirection: Bool = false
  ) {
    self.languagePair = languagePair
    self.directionMode = directionMode
    self.source = source
    self.outputMode = outputMode
    self.provider = provider
    self.allowExperimentalAutomaticDirection = allowExperimentalAutomaticDirection
    self.buffering = buffering
    self.audioTransportBudget = audioTransportBudget
  }
}
public enum TranslationInterruptionBehavior: String, Sendable {
  case unsupported, cancellation, freshContextRequired
}
public struct TranslationCapabilities: Equatable, Sendable {
  public var inputLanguages: Set<String>
  public var outputLanguages: Set<String>
  public var qualifiedTranslationPairs: Set<TranslationLanguagePair>
  public var supportsTextOutput: Bool
  public var supportsAudioOutput: Bool
  public var sourceTranscriptAvailable: Bool
  public var inputStreaming: Bool
  public var outputStreaming: Bool
  public var interruptionBehavior: TranslationInterruptionBehavior
  public var automaticDirectionQualified: Bool
  public var automaticDirectionAvailable: Bool
  public var retainsConversationContext: Bool
  public var trueDuplex: Bool
  public var inputFormat: TranslationPCMFormat?
  public init(
    inputLanguages: Set<String> = [], outputLanguages: Set<String> = [],
    qualifiedTranslationPairs: Set<TranslationLanguagePair> = [],
    supportsTextOutput: Bool = true,
    supportsAudioOutput: Bool = false, sourceTranscriptAvailable: Bool = false,
    inputStreaming: Bool = false, outputStreaming: Bool = false,
    interruptionBehavior: TranslationInterruptionBehavior = .freshContextRequired,
    automaticDirectionQualified: Bool = false, trueDuplex: Bool = false,
    inputFormat: TranslationPCMFormat? = nil,
    automaticDirectionAvailable: Bool = false, retainsConversationContext: Bool = true
  ) {
    self.inputLanguages = inputLanguages
    self.outputLanguages = outputLanguages
    self.qualifiedTranslationPairs = qualifiedTranslationPairs
    self.supportsTextOutput = supportsTextOutput
    self.supportsAudioOutput = supportsAudioOutput
    self.sourceTranscriptAvailable = sourceTranscriptAvailable
    self.inputStreaming = inputStreaming
    self.outputStreaming = outputStreaming
    self.interruptionBehavior = interruptionBehavior
    self.automaticDirectionQualified = automaticDirectionQualified
    self.automaticDirectionAvailable = automaticDirectionAvailable
    self.retainsConversationContext = retainsConversationContext
    self.trueDuplex = trueDuplex
    self.inputFormat = inputFormat
  }
}
public enum TranslationPCMEncoding: String, Codable, Sendable {
  case signedInt16LittleEndian, float32LittleEndian
  public var bytesPerSample: Int { self == .signedInt16LittleEndian ? 2 : 4 }
}
public struct TranslationPCMFormat: Equatable, Codable, Sendable {
  public let sampleRate: Double
  public let channels: Int
  public let encoding: TranslationPCMEncoding
  public init(sampleRate: Double, channels: Int, encoding: TranslationPCMEncoding) {
    self.sampleRate = sampleRate
    self.channels = channels
    self.encoding = encoding
  }
  public func duration(byteCount: Int) throws -> Double {
    guard sampleRate.isFinite, sampleRate >= 8_000, sampleRate <= 192_000,
      (1...8).contains(channels), byteCount > 0,
      byteCount % (channels * encoding.bytesPerSample) == 0
    else {
      throw TranslationFailure(
        code: .invalidAudio, message: "Invalid PCM format or incomplete sample frame.")
    }
    return Double(byteCount) / (sampleRate * Double(channels * encoding.bytesPerSample))
  }
}
/// Data is an owned value. Host adapters must copy callback-borrowed samples before constructing this value.
public struct OwnedPCMFrame: Equatable, Sendable {
  public let bytes: Data
  public let format: TranslationPCMFormat
  public let captureTimestampNanoseconds: UInt64
  public let sequence: UInt64
  public let sourceID: String
  public let sessionID: TranslationSessionID
  public let turnID: TranslationTurnID
  public let generation: TranslationGeneration
  public init(
    bytes: Data, format: TranslationPCMFormat, captureTimestampNanoseconds: UInt64,
    sequence: UInt64, sourceID: String, sessionID: TranslationSessionID,
    turnID: TranslationTurnID,
    generation: TranslationGeneration
  ) {
    self.bytes = bytes
    self.format = format
    self.captureTimestampNanoseconds = captureTimestampNanoseconds
    self.sequence = sequence
    self.sourceID = sourceID
    self.sessionID = sessionID
    self.turnID = turnID
    self.generation = generation
  }
}
public enum TranslationTextStability: String, Sendable { case tentative, stableAppend, final }
public struct TranslationTextUpdate: Equatable, Sendable {
  public let text: String
  public let stability: TranslationTextStability
  /// tentative/final text replaces display text; stableAppend contains only the new irreversible suffix.
  public init(text: String, stability: TranslationTextStability) {
    self.text = text
    self.stability = stability
  }
}
/// Counts unique audio in flight, rather than independently bounding each queue by event count.
/// A reservation moves with a chunk through provider, core and host. Playback has its own budget.
public final class TranslationAudioTransportBudget: @unchecked Sendable, Equatable {
  public static let maximumSeconds = 2.0
  private let lock = NSLock()
  private var reservations: [UUID: Double] = [:]
  public init() {}
  public static func == (lhs: TranslationAudioTransportBudget, rhs: TranslationAudioTransportBudget)
    -> Bool
  { lhs === rhs }
  public var reservedSeconds: Double { lock.withLock { reservations.values.reduce(0, +) } }
  func reserve(seconds: Double) throws -> TranslationAudioDelivery {
    try reserveBatch(seconds: [seconds])[0]
  }
  func reserveBatch(seconds: [Double]) throws -> [TranslationAudioDelivery] {
    try lock.withLock {
      let total = seconds.reduce(0, +)
      guard !seconds.isEmpty, seconds.allSatisfy({ $0.isFinite && $0 > 0 }), total.isFinite,
        total <= Self.maximumSeconds,
        reservations.values.reduce(0, +) + total <= Self.maximumSeconds + 0.000001
      else {
        throw TranslationFailure(
          code: .consumerOverload,
          message:
            "Translation audio transport exceeded two seconds. This interval is incomplete; repeat it."
        )
      }
      return seconds.map { seconds in
        let id = UUID()
        reservations[id] = seconds
        return TranslationAudioDelivery(budget: self, id: id, seconds: seconds)
      }
    }
  }
  fileprivate func contains(_ id: UUID) -> Bool { lock.withLock { reservations[id] != nil } }
  fileprivate func release(_ id: UUID) {
    lock.withLock { _ = reservations.removeValue(forKey: id) }
  }
}

final class TranslationAudioDelivery: @unchecked Sendable, Equatable {
  let budget: TranslationAudioTransportBudget
  let id: UUID
  let seconds: Double
  init(budget: TranslationAudioTransportBudget, id: UUID, seconds: Double) {
    self.budget = budget
    self.id = id
    self.seconds = seconds
  }
  static func == (lhs: TranslationAudioDelivery, rhs: TranslationAudioDelivery) -> Bool {
    lhs === rhs
  }
  func acknowledge() { budget.release(id) }
  deinit { acknowledge() }
}

public struct TranslationAudioChunk: Equatable, Sendable {
  public let bytes: Data
  public let format: TranslationPCMFormat
  public let sequence: UInt64
  public let committed: Bool
  var delivery: TranslationAudioDelivery?
  public init(bytes: Data, format: TranslationPCMFormat, sequence: UInt64, committed: Bool = true) {
    self.bytes = bytes
    self.format = format
    self.sequence = sequence
    self.committed = committed
    self.delivery = nil
  }
  /// Providers call this before buffering. The core repeats it defensively without double counting.
  public func admitted(to budget: TranslationAudioTransportBudget) throws -> Self {
    if let delivery {
      guard delivery.budget === budget, budget.contains(delivery.id) else {
        throw TranslationFailure(
          code: .invalidEvent,
          message: "Audio belongs to another transport or has already been consumed.")
      }
      return self
    }
    var copy = self
    copy.delivery = try budget.reserve(seconds: format.duration(byteCount: bytes.count))
    return copy
  }
  /// Call only once PCM has entered the separately bounded playback queue, or has been discarded.
  public func acknowledgeDelivery() { delivery?.acknowledge() }
  func adopting(_ admission: TranslationAudioDelivery?) throws -> Self {
    guard let admission else { return self }
    let seconds = try format.duration(byteCount: bytes.count)
    guard seconds <= admission.seconds + 0.000001 else {
      throw TranslationFailure(
        code: .invalidAudio, message: "Decoded audio exceeds its transport reservation.")
    }
    var copy = self
    copy.delivery = admission
    return copy
  }
}
public enum TranslationSessionState: String, Sendable {
  case idle, preparing, ready, running, paused, stopping, stopped, failed
}
public struct TranslationActivity: Equatable, Sendable {
  public var acceptingInput: Bool
  public var generating: Bool
  public var playingOutput: Bool
  public init(acceptingInput: Bool = false, generating: Bool = false, playingOutput: Bool = false) {
    self.acceptingInput = acceptingInput
    self.generating = generating
    self.playingOutput = playingOutput
  }
}
public struct TranslationFailure: Error, Equatable, Sendable {
  public enum Code: String, Sendable {
    case invalidConfiguration, invalidState, invalidAudio, staleInput, overload, incompleteTurn,
      providerFailure, unsupportedLanguage, unsupportedOutput, consumerOverload,
      unexpectedStreamEnd, invalidEvent, ambiguousDirection
  }
  public let code: Code
  public let message: String
  public let recoverable: Bool
  public init(code: Code, message: String, recoverable: Bool = true) {
    self.code = code
    self.message = message
    self.recoverable = recoverable
  }
}
public struct TranslationEvent: Equatable, Sendable {
  public enum Payload: Equatable, Sendable {
    case sourceText(TranslationTextUpdate)
    case translationText(TranslationTextUpdate)
    case audio(TranslationAudioChunk)
    case turnCompleted
    case state(TranslationSessionState, TranslationActivity)
    case metrics(TranslationMetric)
    case failure(TranslationFailure)
    case contextRolledOver
    case directionSelected(TranslationDirectionSelection)
  }
  public let sessionID: TranslationSessionID
  public let turnID: TranslationTurnID?
  public let generation: TranslationGeneration
  public let payload: Payload
  /// Hosts must acknowledge even stale-generation or muted audio after discarding it.
  public func acknowledgeAudioDelivery() {
    if case .audio(let chunk) = payload { chunk.acknowledgeDelivery() }
  }
  public init(
    sessionID: TranslationSessionID, turnID: TranslationTurnID? = nil,
    generation: TranslationGeneration, payload: Payload
  ) {
    self.sessionID = sessionID
    self.turnID = turnID
    self.generation = generation
    self.payload = payload
  }
}
/// A monotonic capture interval that could not be translated completely. No PCM is retained here.
public struct TranslationIncompleteInterval: Equatable, Sendable {
  public let turnID: TranslationTurnID
  public let sourceID: String?
  public let startCaptureTimestampNanoseconds: UInt64?
  public let endCaptureTimestampNanoseconds: UInt64?
}
public struct TranslationSessionSnapshot: Sendable {
  public let sessionID: TranslationSessionID
  public let generation: TranslationGeneration
  public let state: TranslationSessionState
  public let activity: TranslationActivity
  public let activeTurnID: TranslationTurnID?
  public let waitingTurnID: TranslationTurnID?
  public let incompleteTurns: Set<TranslationTurnID>
  public let incompleteIntervals: [TranslationIncompleteInterval]
  public let transcript: TranslationTranscriptBuffer
  public let lastFailure: TranslationFailure?
  public let canRetry: Bool
  public let canReplay: Bool
}
