import Foundation

public struct LFMSpeechTransportChunk: Sendable {
  public let bytes: Data
  var delivery: TranslationAudioDelivery?
  public init(bytes: Data) {
    self.bytes = bytes
    self.delivery = nil
  }
  func admitted(format: TranslationPCMFormat, budget: TranslationAudioTransportBudget) throws
    -> Self
  {
    var copy = self
    copy.delivery = try budget.reserve(seconds: format.duration(byteCount: bytes.count))
    return copy
  }
}

public struct LFMSpeechHTTPResponse: Sendable {
  public let statusCode: Int
  public let contentType: String
  public let body: AsyncThrowingStream<LFMSpeechTransportChunk, Error>
  public init(
    statusCode: Int, contentType: String, body: AsyncThrowingStream<LFMSpeechTransportChunk, Error>
  ) {
    self.statusCode = statusCode
    self.contentType = contentType
    self.body = body
  }
}
public protocol LFMSpeechTransport: Sendable {
  func stream(_ request: URLRequest, budget: TranslationAudioTransportBudget) async throws
    -> LFMSpeechHTTPResponse
}

/// No redirects, caches, cookies or environment-derived credentials for the owned loopback server.
final class LFMLocalSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
func lfmURLSession() -> URLSession {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.urlCache = nil
  configuration.httpCookieStorage = nil
  configuration.urlCredentialStorage = nil
  configuration.connectionProxyDictionary = [:]
  configuration.timeoutIntervalForRequest = 60
  configuration.timeoutIntervalForResource = 60
  return URLSession(
    configuration: configuration, delegate: LFMLocalSessionDelegate(), delegateQueue: nil)
}

public struct LFMURLSessionSpeechTransport: LFMSpeechTransport {
  public init() {}
  public func stream(_ request: URLRequest, budget: TranslationAudioTransportBudget) async throws
    -> LFMSpeechHTTPResponse
  {
    let session = lfmURLSession()
    do {
      let (bytes, response) = try await session.bytes(for: request)
      guard let response = response as? HTTPURLResponse else {
        session.invalidateAndCancel()
        throw lfmFailure(.providerFailure, "The speech helper returned a non-HTTP response.")
      }
      let pair = AsyncThrowingStream<LFMSpeechTransportChunk, Error>.makeStream(
        bufferingPolicy: .bufferingOldest(16))
      guard response.statusCode == 200 else {
        session.invalidateAndCancel()
        pair.continuation.finish()
        return .init(statusCode: response.statusCode, contentType: "", body: pair.stream)
      }
      let format = try LFMSpeechPCMDecoder(
        contentType: response.value(forHTTPHeaderField: "Content-Type") ?? ""
      ).format
      let producer = Task { @concurrent in
        defer { session.invalidateAndCancel() }
        do {
          var chunk = Data()
          chunk.reserveCapacity(4096)
          for try await byte in bytes {
            try Task.checkCancellation()
            chunk.append(byte)
            if chunk.count == 4096 {
              if case .enqueued = pair.continuation.yield(
                try LFMSpeechTransportChunk(bytes: chunk).admitted(format: format, budget: budget))
              {
              } else {
                throw lfmFailure(.consumerOverload, "The TTS transport consumer fell behind.")
              }
              chunk = Data()
              chunk.reserveCapacity(4096)
            }
          }
          if !chunk.isEmpty {
            if case .enqueued = pair.continuation.yield(
              try LFMSpeechTransportChunk(bytes: chunk).admitted(format: format, budget: budget))
            {
            } else {
              throw lfmFailure(.consumerOverload, "The TTS transport consumer fell behind.")
            }
          }
          pair.continuation.finish()
        } catch { pair.continuation.finish(throwing: error) }
      }
      pair.continuation.onTermination = { @Sendable _ in
        producer.cancel()
        session.invalidateAndCancel()
      }
      return .init(
        statusCode: response.statusCode,
        contentType: response.value(forHTTPHeaderField: "Content-Type") ?? "", body: pair.stream)
    } catch {
      session.invalidateAndCancel()
      throw error
    }
  }
}

/// Reusable same-model speech pass. The caller must release the single realtime slot before invoking it.
public struct LFM3SpeechSynthesizer: Sendable {
  private let endpoint: LFMRuntimeEndpoint
  private let transport: any LFMSpeechTransport
  public init(
    endpoint: LFMRuntimeEndpoint, transport: any LFMSpeechTransport = LFMURLSessionSpeechTransport()
  ) {
    self.endpoint = endpoint
    self.transport = transport
  }
  public func stream(
    text: String, language: String, budget: TranslationAudioTransportBudget = .init()
  ) throws -> AsyncThrowingStream<
    TranslationAudioChunk, Error
  > {
    guard LFMLanguageSupport.documentedSpeechLanguages.contains(language) else {
      throw lfmFailure(
        .unsupportedLanguage, "LFM3 does not document speech output for this language.")
    }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 32_768
    else {
      throw lfmFailure(
        .invalidConfiguration, "Speech requires nonempty committed text within its size limit.")
    }
    var guardrail = LFMInterpreterTextGuard()
    _ = try guardrail.append(text)
    _ = try guardrail.finish()
    var request = try endpoint.request(path: "/tts")
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try lfmJSON([
      "input": text, "lang": language, "stream": true, "response_format": "pcm", "n_predict": 512,
    ])
    let immutableRequest = request
    let pair = AsyncThrowingStream<TranslationAudioChunk, Error>.makeStream(
      bufferingPolicy: .bufferingOldest(16))
    let producer = Task { @concurrent in
      do {
        try await lfmWithTimeout(seconds: 60) {
          let response = try await transport.stream(immutableRequest, budget: budget)
          guard response.statusCode == 200 else {
            throw lfmFailure(
              .providerFailure, "The local TTS request failed (HTTP \(response.statusCode)).")
          }
          var decoder = try LFMSpeechPCMDecoder(contentType: response.contentType)
          var sequence: UInt64 = 0
          for try await received in response.body {
            try Task.checkCancellation()
            let pcm = try decoder.append(received.bytes)
            if pcm.isEmpty { continue }
            // Bound chunks as well as the stream queue; never buffer a whole synthesized phrase.
            for offset in stride(from: 0, to: pcm.count, by: 4096) {
              let chunk = try TranslationAudioChunk(
                bytes: Data(pcm[offset..<min(offset + 4096, pcm.count)]), format: decoder.format,
                sequence: sequence
              ).adopting(received.delivery).admitted(to: budget)
              sequence += 1
              if case .enqueued = pair.continuation.yield(chunk) {
              } else {
                throw lfmFailure(
                  .consumerOverload, "Speech playback fell behind. This turn is incomplete.")
              }
            }
          }
          try decoder.finish()
          guard sequence > 0 else {
            throw lfmFailure(.incompleteTurn, "The TTS response contained no audio.")
          }
        }
        pair.continuation.finish()
      } catch { pair.continuation.finish(throwing: error) }
    }
    pair.continuation.onTermination = { @Sendable _ in producer.cancel() }
    return pair.stream
  }
}
