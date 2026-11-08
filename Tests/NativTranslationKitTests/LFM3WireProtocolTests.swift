import Foundation
import XCTest

@testable import NativTranslationKit

final class LFM3WireProtocolTests: XCTestCase {
  func testNegotiationRequiresReceivedPCMMetadata() throws {
    let event = try LFMWireMessage.decode(
      Data(
        #"{"type":"session.created","session":{"audio":{"input":{"format":{"type":"audio/pcm","rate":16000}},"output":{"format":{"type":"audio/pcm","rate":24000}}}}}"#
          .utf8))
    let formats = try event.negotiatedFormats()
    XCTAssertEqual(formats.input.sampleRate, 16000)
    XCTAssertEqual(formats.output.sampleRate, 24000)
    XCTAssertEqual(formats.output.encoding, .signedInt16LittleEndian)
    XCTAssertThrowsError(
      try LFMWireMessage.decode(Data(#"{"type":"session.created","session":{}}"#.utf8))
        .negotiatedFormats())
  }
  func testPCM16RejectsOddOrMalformedChunks() throws {
    XCTAssertEqual(try LFMWireMessage.pcm16("AQACAA=="), Data([1, 0, 2, 0]))
    XCTAssertThrowsError(try LFMWireMessage.pcm16("AQ=="))
    XCTAssertThrowsError(try LFMWireMessage.pcm16("not base64"))
  }
  func testFloatPCMDecoderPreservesFragmentedSamplesAndRejectsIncompleteEnd() throws {
    var decoder = try LFMSpeechPCMDecoder(
      contentType: "audio/pcm;rate=24000;encoding=float;bits=32")
    XCTAssertEqual(try decoder.append(Data([0, 0, 0])), Data())
    XCTAssertEqual(
      try decoder.append(Data([63, 0, 0, 0, 191])), Data([0, 0, 0, 63, 0, 0, 0, 191]))
    try decoder.finish()
    _ = try decoder.append(Data([0]))
    XCTAssertThrowsError(try decoder.finish())
    XCTAssertThrowsError(try LFMSpeechPCMDecoder(contentType: "audio/pcm;rate=24000"))
  }
  func testFloatDecoderRejectsNonFiniteAudio() throws {
    var decoder = try LFMSpeechPCMDecoder(
      contentType: "audio/pcm; rate=24000; encoding=float; bits=32")
    XCTAssertThrowsError(try decoder.append(Data([0, 0, 128, 127])))
  }
  func testSplitToolMarkupNeverBecomesCommittedText() throws {
    var guardrail = LFMInterpreterTextGuard()
    XCTAssertEqual(try guardrail.append("Hello <to"), "Hello ")
    XCTAssertThrowsError(try guardrail.append("ol_call><function=book>"))
    var unfinished = LFMInterpreterTextGuard()
    XCTAssertEqual(try unfinished.append("<fun"), "")
    XCTAssertThrowsError(try unfinished.finish())
  }
  func testOrdinarySplitTextRemainsAppendOnly() throws {
    var guardrail = LFMInterpreterTextGuard()
    XCTAssertEqual(try guardrail.append("Three seats, "), "Three seats, ")
    XCTAssertEqual(try guardrail.append("not four."), "not four.")
    XCTAssertEqual(try guardrail.finish(), "Three seats, not four.")
  }
  func testEndpointRefusesNonLoopbackAndCredentialInURL() throws {
    XCTAssertThrowsError(
      try LFMRuntimeEndpoint(baseURL: URL(string: "https://example.com")!, bearerToken: "secret"))
    XCTAssertThrowsError(
      try LFMRuntimeEndpoint(
        baseURL: URL(string: "http://user@127.0.0.1:42")!, bearerToken: "secret"))
    XCTAssertNoThrow(
      try LFMRuntimeEndpoint(baseURL: URL(string: "http://127.0.0.1:42")!, bearerToken: "secret"))
  }
}
