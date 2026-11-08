import Foundation

/// In-memory interchange with phrase-only local audio endpoints; never writes speech to disk.
public enum TranslationWaveCodec {
    public struct Audio: Sendable { public let bytes: Data; public let format: TranslationPCMFormat }
    public static func encode(_ pcm: Data, format: TranslationPCMFormat) throws -> Data {
        _ = try format.duration(byteCount: pcm.count)
        guard pcm.count <= 16_000_000, format.sampleRate.rounded() == format.sampleRate else { throw invalid() }
        var output = Data("RIFF".utf8)
        append(UInt32(36 + pcm.count), to: &output)
        output.append(Data("WAVEfmt ".utf8)); append(UInt32(16), to: &output)
        append(UInt16(format.encoding == .signedInt16LittleEndian ? 1 : 3), to: &output)
        append(UInt16(format.channels), to: &output); append(UInt32(format.sampleRate), to: &output)
        let alignment = format.channels * format.encoding.bytesPerSample
        append(UInt32(Int(format.sampleRate) * alignment), to: &output); append(UInt16(alignment), to: &output)
        append(UInt16(format.encoding.bytesPerSample * 8), to: &output)
        output.append(Data("data".utf8)); append(UInt32(pcm.count), to: &output); output.append(pcm)
        return output
    }
    public static func decode(_ wave: Data) throws -> Audio {
        guard wave.count >= 44, wave.count <= 16_000_000,
              tag(wave, 0) == "RIFF", tag(wave, 8) == "WAVE",
              Int(try uint32(wave, 4)) + 8 == wave.count else { throw invalid() }
        var offset = 12
        var format: TranslationPCMFormat?
        var samples: Data?
        while offset + 8 <= wave.count {
            let name = tag(wave, offset); let count = Int(try uint32(wave, offset + 4))
            let start = offset + 8
            guard count <= wave.count - start else { throw invalid() }
            if name == "fmt " {
                guard count >= 16, format == nil else { throw invalid() }
                let encoding = try uint16(wave, start)
                let bits = try uint16(wave, start + 14)
                let pcmEncoding: TranslationPCMEncoding
                switch (encoding, bits) {
                case (1, 16): pcmEncoding = .signedInt16LittleEndian
                case (3, 32): pcmEncoding = .float32LittleEndian
                default: throw invalid()
                }
                let channels = Int(try uint16(wave, start + 2)); let rate = Int(try uint32(wave, start + 4))
                guard Int(try uint16(wave, start + 12)) == channels * pcmEncoding.bytesPerSample,
                      Int(try uint32(wave, start + 8)) == rate * channels * pcmEncoding.bytesPerSample else { throw invalid() }
                format = .init(sampleRate: Double(rate), channels: channels, encoding: pcmEncoding)
            } else if name == "data" {
                guard samples == nil else { throw invalid() }
                samples = Data(wave[start..<start + count])
            }
            offset = start + count + count % 2
        }
        guard offset == wave.count, let format, let samples,
              try format.duration(byteCount: samples.count) <= 60 else { throw invalid() }
        if format.encoding == .float32LittleEndian {
            for offset in stride(from: 0, to: samples.count, by: 4) {
                guard Float(bitPattern: try uint32(samples, offset)).isFinite else { throw invalid() }
            }
        }
        return .init(bytes: samples, format: format)
    }
    private static func tag(_ data: Data, _ offset: Int) -> String { String(decoding: data[offset..<offset + 4], as: UTF8.self) }
    private static func uint16(_ data: Data, _ offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { throw invalid() }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }
    private static func uint32(_ data: Data, _ offset: Int) throws -> UInt32 {
        UInt32(try uint16(data, offset)) | UInt32(try uint16(data, offset + 2)) << 16
    }
    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    private static func invalid() -> TranslationFailure { .init(code: .invalidAudio, message: "The local speech response is not a complete supported PCM WAV file.") }
}
