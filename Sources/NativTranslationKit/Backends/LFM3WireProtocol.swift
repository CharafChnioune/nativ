import Foundation

/// A credential for one owned, local helper. It is intentionally neither Codable nor printable.
public struct LFMRuntimeEndpoint: Sendable {
  public let baseURL: URL
  private let bearerToken: String
  public init(baseURL: URL, bearerToken: String) throws {
    guard baseURL.scheme == "http", baseURL.host == "127.0.0.1",
      let port = baseURL.port, (1...65535).contains(port),
      baseURL.user == nil, baseURL.password == nil, baseURL.query == nil,
      baseURL.fragment == nil, ["", "/"].contains(baseURL.path),
      !bearerToken.isEmpty, !bearerToken.contains(where: { $0.isNewline })
    else {
      throw lfmFailure(
        .invalidConfiguration, "The speech helper must use an authenticated loopback endpoint.")
    }
    self.baseURL = baseURL
    self.bearerToken = bearerToken
  }
  public func request(path: String, websocket: Bool = false) throws -> URLRequest {
    guard path.hasPrefix("/"), !path.contains(".."), !path.contains("?") else {
      throw lfmFailure(.invalidConfiguration, "Invalid helper route.")
    }
    var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
    components.path = path
    if websocket { components.scheme = "ws" }
    var request = URLRequest(url: components.url!)
    request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 60
    return request
  }
}

/// These are documentation claims, not measurements or interpreting qualification.
/// Source: https://huggingface.co/LiquidAI/LFM3-Omni-2B (model details).
public enum LFMLanguageSupport {
  public static let documentedTextLanguages: Set<String> = [
    "en", "ar", "zh", "fr", "de", "it", "ja", "ko", "pt", "es", "vi", "th", "id", "hi", "ru", "pl",
  ]
  public static let documentedSpeechLanguages: Set<String> = [
    "ar", "da", "de", "el", "en", "fi", "fr", "he", "it", "ja", "ko", "nl", "pl", "pt", "es", "sv",
    "tr", "zh",
  ]
  public static let languageNames: [String: String] = [
    "en": "English", "ar": "Arabic", "zh": "Chinese", "fr": "French", "de": "German",
    "it": "Italian", "ja": "Japanese", "ko": "Korean", "pt": "Portuguese", "es": "Spanish",
    "vi": "Vietnamese", "th": "Thai", "id": "Indonesian", "hi": "Hindi", "ru": "Russian",
    "pl": "Polish", "da": "Danish", "el": "Greek", "fi": "Finnish", "he": "Hebrew", "nl": "Dutch",
    "sv": "Swedish", "tr": "Turkish",
  ]
}

func lfmFailure(_ code: TranslationFailure.Code, _ message: String) -> TranslationFailure {
  TranslationFailure(code: code, message: message)
}

struct LFMWireMessage: Decodable, Sendable {
  struct PCM: Decodable, Sendable {
    let type: String
    let rate: Double
  }
  struct AudioDirection: Decodable, Sendable { let format: PCM }
  struct Audio: Decodable, Sendable {
    let input: AudioDirection
    let output: AudioDirection
  }
  struct Session: Decodable, Sendable { let audio: Audio? }
  struct Item: Decodable, Sendable { let type: String }
  struct Response: Decodable, Sendable {
    let id: String
    let status: String?
    let output: [Item]?
  }
  let type: String
  let session: Session?
  let response: Response?
  let responseID: String?
  let delta: String?
  let text: String?
  let item: Item?
  enum CodingKeys: String, CodingKey {
    case type, session, response, delta, text, item
    case responseID = "response_id"
  }
  static func decode(_ data: Data) throws -> Self {
    guard data.count <= 1_048_576 else {
      throw lfmFailure(.overload, "The helper sent an oversized event.")
    }
    do { return try JSONDecoder().decode(Self.self, from: data) } catch {
      throw lfmFailure(.invalidEvent, "The helper sent malformed event data.")
    }
  }
  func negotiatedFormats() throws -> (input: TranslationPCMFormat, output: TranslationPCMFormat) {
    guard let audio = session?.audio,
      audio.input.format.type == "audio/pcm", audio.output.format.type == "audio/pcm"
    else { throw lfmFailure(.invalidAudio, "The helper did not supply PCM format metadata.") }
    let input = TranslationPCMFormat(
      sampleRate: audio.input.format.rate, channels: 1, encoding: .signedInt16LittleEndian)
    let output = TranslationPCMFormat(
      sampleRate: audio.output.format.rate, channels: 1, encoding: .signedInt16LittleEndian)
    _ = try input.duration(byteCount: 2)
    _ = try output.duration(byteCount: 2)
    return (input, output)
  }
  static func pcm16(_ value: String) throws -> Data {
    guard value.utf8.count <= 700_000, let data = Data(base64Encoded: value),
      !data.isEmpty, data.count <= 524_288, data.count.isMultiple(of: 2)
    else { throw lfmFailure(.invalidAudio, "The helper sent invalid PCM16 audio.") }
    return data
  }
  func rejectToolOutput() throws {
    if type.contains("function_call") || item?.type == "function_call"
      || response?.output?.contains(where: { $0.type == "function_call" }) == true
    {
      throw lfmFailure(
        .invalidEvent, "The interpreter produced a tool request. This turn is incomplete.")
    }
  }
}

/// HTTP /tts uses float32, unlike the realtime socket's PCM16. Retain at most one partial sample.
struct LFMSpeechPCMDecoder {
  let format: TranslationPCMFormat
  private var pending = Data()
  private var received = 0
  init(contentType: String) throws {
    let parts = contentType.lowercased().split(separator: ";").map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    var values: [String: String] = [:]
    for part in parts.dropFirst() {
      let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
      guard pair.count == 2, values[pair[0]] == nil else {
        throw lfmFailure(.invalidAudio, "Ambiguous TTS audio metadata.")
      }
      values[pair[0]] = pair[1]
    }
    guard parts.first == "audio/pcm", values["encoding"] == "float", values["bits"] == "32",
      let rate = values["rate"].flatMap(Double.init),
      values["channels"] == nil || values["channels"] == "1"
    else {
      throw lfmFailure(
        .invalidAudio, "The TTS response did not identify float32 mono PCM and its sample rate.")
    }
    format = TranslationPCMFormat(sampleRate: rate, channels: 1, encoding: .float32LittleEndian)
    _ = try format.duration(byteCount: 4)
  }
  mutating func append(_ data: Data) throws -> Data {
    received += data.count
    guard received <= 8 * 1024 * 1024, data.count <= 1_048_576 else {
      throw lfmFailure(.overload, "TTS audio exceeded its bounded response budget.")
    }
    pending.append(data)
    let count = pending.count / 4 * 4
    let output = Data(pending.prefix(count))
    pending = Data(pending.dropFirst(count))
    for offset in stride(from: 0, to: output.count, by: 4) {
      let bits = output.withUnsafeBytes {
        $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
      }
      guard Float(bitPattern: UInt32(littleEndian: bits)).isFinite else {
        throw lfmFailure(.invalidAudio, "TTS audio contains a non-finite sample.")
      }
    }
    return output
  }
  func finish() throws {
    guard pending.isEmpty else {
      throw lfmFailure(.invalidAudio, "TTS ended in an incomplete float32 sample.")
    }
  }
}

/// Preserve append-only text, while withholding split prefixes of disallowed tool markup.
struct LFMInterpreterTextGuard {
  private var pending = ""
  private(set) var text = ""
  private static let markers = [
    "<tool_call", "</tool_call", "<function", "</function", "<parameter", "</parameter",
  ]
  mutating func append(_ delta: String) throws -> String {
    guard text.utf8.count + pending.utf8.count + delta.utf8.count <= 32_768 else {
      throw lfmFailure(.overload, "The interpreter exceeded its text budget.")
    }
    pending += delta
    let lower = pending.lowercased()
    guard !Self.markers.contains(where: lower.contains) else {
      throw lfmFailure(
        .invalidEvent, "The interpreter produced tool markup. This turn is incomplete.")
    }
    var held = 0
    for marker in Self.markers {
      for length in 1..<marker.count where lower.hasSuffix(marker.prefix(length)) {
        held = max(held, length)
      }
    }
    let safe = String(pending.dropLast(held))
    pending = String(pending.suffix(held))
    text += safe
    return safe
  }
  var hasIncompleteMarkup: Bool { !pending.isEmpty }
  mutating func finish() throws -> String {
    guard pending.isEmpty else {
      throw lfmFailure(.invalidEvent, "The interpreter ended with incomplete markup.")
    }
    return text
  }
}

func lfmJSON(_ value: [String: Any]) throws -> Data {
  try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}

func lfmWithTimeout<T: Sendable>(
  seconds: Double, operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(for: .seconds(seconds))
      throw lfmFailure(.providerFailure, "The local speech helper timed out.")
    }
    defer { group.cancelAll() }
    guard let result = try await group.next() else { throw CancellationError() }
    return result
  }
}
