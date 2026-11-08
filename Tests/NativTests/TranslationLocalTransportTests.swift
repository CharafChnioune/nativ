import Foundation
import XCTest
@testable import NativServerKit

final class TranslationLocalTransportTests: XCTestCase {
    func testLocalTransportBypassesSystemProxiesAndPersistentCache() {
        let configuration = URLSessionConfiguration.default
        configuration.connectionProxyDictionary = ["HTTPEnable": 1, "HTTPProxy": "proxy.example", "HTTPPort": 8080]
        NativLoopbackEndpoint.configure(configuration)
        XCTAssertEqual(configuration.connectionProxyDictionary?.count, 0)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }
    func testTranscriptionLanguageIsExplicitAndNeverWhisperTranslateTask() throws {
        let client = NativAudioClient(baseURL: URL(string: "http://127.0.0.1:8181")!, localOnly: true)
        let request = client.makeURLRequest(audioData: Data([0, 0]), fileName: "utterance.wav", model: "local/whisper", language: "nl", boundary: "test")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nnl\r\n"))
        XCTAssertTrue(body.contains("name=\"task\"\r\n\r\ntranscribe\r\n"))
        XCTAssertFalse(body.contains("\r\ntranslate\r\n"))
    }
    func testPhraseSpeechPassesRealLangCodeWithoutPretendingToStream() throws {
        let client = NativAudioClient(baseURL: URL(string: "http://127.0.0.1:8181")!, localOnly: true)
        let request = try client.makeSpeechURLRequest(text: "Drie, niet vier.", model: "local/chatterbox", language: "nl", referenceAudioPath: "/permitted/voice.wav")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["lang_code"] as? String, "nl")
        XCTAssertEqual(body["ref_audio"] as? String, "/permitted/voice.wav")
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual(body["nativ_local_only"] as? Bool, true)
    }
    func testAutomaticRecognitionOmitsLanguageHintAndStillRequestsTranscription() throws {
        let client = NativAudioClient(baseURL: URL(string: "http://127.0.0.1:8181")!, localOnly: true)
        let request = client.makeURLRequest(audioData: Data([0, 0]), fileName: "utterance.wav", model: "/models/qwen-asr", language: nil, boundary: "test")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertFalse(body.contains("name=\"language\""))
        XCTAssertTrue(body.contains("name=\"task\"\r\n\r\ntranscribe\r\n"))
        XCTAssertFalse(body.contains("\r\nauto\r\n"))
    }
    func testOnlyLiteralLoopbackEndpointsAreAllowed() throws {
        for url in ["http://127.0.0.1:8181", "http://[::1]:8181", "http://localhost:8181"] {
            XCTAssertNoThrow(try NativLoopbackEndpoint.validate(URL(string: url)!))
        }
        for url in ["https://example.com", "http://127.0.0.1.evil.test", "http://user:pass@127.0.0.1", "http://192.168.1.1", "file:///tmp/a"] {
            XCTAssertThrowsError(try NativLoopbackEndpoint.validate(URL(string: url)!))
        }
        XCTAssertFalse(NativLoopbackEndpoint.allowsRedirect(from: URL(string: "http://127.0.0.1:8181/a")!, to: URL(string: "http://127.0.0.1:8182/a")!))
        XCTAssertFalse(NativLoopbackEndpoint.allowsRedirect(from: URL(string: "http://127.0.0.1:8181/a")!, to: URL(string: "https://example.com")!))
    }
    func testIndependentSpeechVoiceAndReferenceAreSentWithoutDefaults() throws {
        let client = NativAudioClient(baseURL: URL(string: "http://127.0.0.1:8181")!, localOnly: true)
        let preset = try client.makeSpeechURLRequest(text: "Three, not four.", model: "/models/qwen-custom", language: "english", voice: "ryan")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(preset.httpBody)) as? [String: Any])
        XCTAssertEqual(body["voice"] as? String, "ryan")
        XCTAssertEqual(body["lang_code"] as? String, "english")
        XCTAssertNil(body["ref_audio"])
        XCTAssertNil(body["ref_text"])
        XCTAssertEqual(body["stream"] as? Bool, false)
        let reference = try client.makeSpeechURLRequest(text: "Three, not four.", model: "/models/qwen-base", language: "english",
            referenceAudioPath: "/permitted/voice.wav", referenceText: "My original reference sentence.")
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(reference.httpBody)) as? [String: Any])
        XCTAssertEqual(base["ref_text"] as? String, "My original reference sentence.")
        XCTAssertNil(base["voice"])
    }
    @MainActor
    func testOldRuntimeIsRejectedBeforeSpeechIsSent() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranslationUnavailableRuntime.self]
        let client = NativAudioClient(baseURL: URL(string: "http://127.0.0.1:8181")!, sessionConfiguration: configuration, localOnly: true)
        do {
            _ = try await client.synthesize(text: "Private input", model: "/prepared/model", language: "nl")
            XCTFail("An older runtime must not receive speech input")
        } catch NativAudioSpeechError.localSpeechIsolationUnavailable {
            // Only the GET preflight can produce this expected failure.
        } catch { XCTFail("Unexpected error: \(error)") }
    }
}

private final class TranslationUnavailableRuntime: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.httpMethod == "GET", request.url?.path == "/nativ/translation-capabilities", request.httpBody == nil else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("missing".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
