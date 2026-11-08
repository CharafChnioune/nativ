import Foundation
import XCTest
@testable import NativTranslationKit

final class TranslationWaveCodecTests: XCTestCase {
    func testInMemoryPCM16RoundTripPreservesRateChannelsAndSamples() throws {
        let format = TranslationPCMFormat(sampleRate: 16_000, channels: 1, encoding: .signedInt16LittleEndian)
        let pcm = Data([0, 0, 255, 127, 0, 128])
        let wav = try TranslationWaveCodec.encode(pcm, format: format)
        let result = try TranslationWaveCodec.decode(wav)
        XCTAssertEqual(result.bytes, pcm)
        XCTAssertEqual(result.format, format)
        XCTAssertEqual(String(data: wav.prefix(4), encoding: .utf8), "RIFF")
    }
    func testTruncatedOrUnsupportedWaveCannotBePlayed() throws {
        let format = TranslationPCMFormat(sampleRate: 24_000, channels: 1, encoding: .signedInt16LittleEndian)
        var wav = try TranslationWaveCodec.encode(Data([1, 0, 2, 0]), format: format)
        XCTAssertThrowsError(try TranslationWaveCodec.decode(Data(wav.dropLast())))
        wav[20] = 7 // mu-law is not PCM16 or float32.
        XCTAssertThrowsError(try TranslationWaveCodec.decode(wav))
    }
    func testFloat32MetadataAndNonFiniteValuesAreValidated() throws {
        let format = TranslationPCMFormat(sampleRate: 48_000, channels: 2, encoding: .float32LittleEndian)
        let wav = try TranslationWaveCodec.encode(Data([0, 0, 0, 63, 0, 0, 0, 191]), format: format)
        XCTAssertEqual(try TranslationWaveCodec.decode(wav).format, format)
        var invalid = wav; invalid.replaceSubrange(44..<48, with: [0, 0, 128, 127])
        XCTAssertThrowsError(try TranslationWaveCodec.decode(invalid))
    }
}
