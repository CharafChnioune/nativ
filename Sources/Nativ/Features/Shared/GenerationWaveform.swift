import AVFoundation
import SwiftUI

/// Computes a bounded real waveform on a detached task; never synthesizes playback data.
enum GenerationWaveform {
    @concurrent static func peaks(url: URL, count: Int = 160) async throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard file.length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { return [] }
        var result = Array(repeating: Float(0), count: count)
        var offset: Int64 = 0
        while offset < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(8192, file.length - offset)))
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            for frame in 0..<Int(buffer.frameLength) {
                let bin = min(count - 1, Int((offset + Int64(frame)) * Int64(count) / file.length))
                for channel in 0..<Int(format.channelCount) {
                    let value = abs(channels[channel][frame])
                    if value.isFinite { result[bin] = max(result[bin], min(value, 1)) }
                }
            }
            offset += Int64(buffer.frameLength)
        }
        return result
    }
}

struct GenerationWaveformView: View {
    let peaks: [Float]
    let fraction: Double
    var body: some View {
        Canvas { context, size in
            guard !peaks.isEmpty else { return }
            let step = size.width / Double(peaks.count)
            for (index, peak) in peaks.enumerated() {
                let height = max(1, size.height * Double(peak))
                let rect = CGRect(x: Double(index) * step, y: (size.height - height) / 2, width: max(1, step - 1), height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(Double(index) / Double(peaks.count) <= fraction ? .accentColor : .secondary.opacity(0.35)))
            }
        }
        .frame(height: 52)
        .accessibilityLabel("Audio waveform")
    }
}

actor GenerationWaveformCache {
    static let shared = GenerationWaveformCache()
    private var values: [URL: [Float]] = [:]
    private var pending: [URL: Task<[Float], Error>] = [:]
    private var order: [URL] = []
    func peaks(for url: URL) async throws -> [Float] {
        if let value = values[url] { return value }
        if let task = pending[url] { return try await task.value }
        let task = Task { try await GenerationWaveform.peaks(url: url) }
        pending[url] = task
        defer { pending[url] = nil }
        let result = try await task.value
        values[url] = result; order.append(url)
        while order.count > 32 { values[order.removeFirst()] = nil }
        return result
    }
}
