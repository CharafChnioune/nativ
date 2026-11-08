import AVFoundation
import Foundation
import NativTranslationKit
import WebRTCVAD

protocol TranslationVoiceActivityDetecting: AnyObject, Sendable {
    /// Exactly 320 mono PCM16 samples at 16 kHz (20 ms).
    func isSpeech(_ samples: [Int16]) throws -> Bool
    func reset()
}

/// The C instance is accessed exclusively under lock, including reset and destruction.
final class WebRTCTranslationVoiceActivityDetector: TranslationVoiceActivityDetecting, @unchecked Sendable {
    private let lock = NSLock()
    private let instance: OpaquePointer
    init() throws {
        guard let instance = fvad_new() else { throw TranslationFailure(code: .invalidState, message: "Could not allocate the local voice detector.") }
        self.instance = instance
        fvad_set_sample_rate(instance, 16000)
        fvad_set_mode(instance, 2)
    }
    deinit { fvad_free(instance) }
    func isSpeech(_ samples: [Int16]) throws -> Bool {
        try lock.withLock {
            guard samples.count == 320 else { throw TranslationFailure(code: .invalidAudio, message: "Voice detection requires 20 ms of 16 kHz mono PCM.") }
            let result = samples.withUnsafeBufferPointer { fvad_process(instance, $0.baseAddress, $0.count) }
            guard result >= 0 else { throw TranslationFailure(code: .invalidAudio, message: "The voice detector rejected an audio window.") }
            return result == 1
        }
    }
    func reset() { lock.withLock { fvad_reset(instance); fvad_set_sample_rate(instance, 16000); fvad_set_mode(instance, 2) } }
}

enum TranslationSegmentationEvent: Sendable {
    case audio(OwnedPCMFrame)
    case commit(turnID: TranslationTurnID, continuation: Bool)
}

/// Detects endpoints without cancelling generation/playback. Streams one turn at a time
/// to the core, which owns its bounded waiting/retry policy. At most 200 ms of onset
/// pre-roll is retained here; no PCM is retained after emission apart from that pre-roll.
actor TranslationSpeechSegmenter {
    private let detector: any TranslationVoiceActivityDetecting
    private let endpointSilence: Double
    private var vadBridge: TranslationPCMBridge?
    private var vadSamples: [Int16] = []
    private var lastDecision = false
    private var turn: TranslationTurnID?
    private var turnSeconds: Double = 0
    private var silenceSeconds: Double = 0
    private var preRoll: [OwnedPCMFrame] = []
    private var preRollSeconds: Double = 0
    private var sequence: UInt64 = 0

    init(detector: any TranslationVoiceActivityDetecting, endpointSilence: Double = 0.4) {
        self.detector = detector
        self.endpointSilence = min(0.6, max(0.25, endpointSilence))
    }

    func reset() {
        detector.reset(); vadBridge?.finish(); vadBridge = nil; vadSamples.removeAll(); lastDecision = false
        turn = nil; turnSeconds = 0; silenceSeconds = 0; preRoll.removeAll(); preRollSeconds = 0; sequence = 0
    }

    func consume(_ frame: OwnedPCMFrame) throws -> [TranslationSegmentationEvent] {
        _ = try frame.format.duration(byteCount: frame.bytes.count)
        guard frame.format.channels == 1 else { throw TranslationFailure(code: .invalidAudio, message: "The segmenter requires mono capture.") }
        let sampleBytes = frame.format.encoding.bytesPerSample
        let windowBytes = max(sampleBytes, Int((frame.format.sampleRate * 0.02).rounded()) * sampleBytes)
        var events: [TranslationSegmentationEvent] = []
        for start in stride(from: 0, to: frame.bytes.count, by: windowBytes) {
            let end = min(start + windowBytes, frame.bytes.count)
            let timestamp = frame.captureTimestampNanoseconds + UInt64(Double(start / sampleBytes) / frame.format.sampleRate * 1_000_000_000)
            let piece = OwnedPCMFrame(bytes: frame.bytes.subdata(in: start..<end), format: frame.format,
                                      captureTimestampNanoseconds: timestamp, sequence: frame.sequence,
                                      sourceID: frame.sourceID, sessionID: frame.sessionID,
                                      turnID: frame.turnID, generation: frame.generation)
            let speech = try detect(piece)
            let duration = try piece.format.duration(byteCount: piece.bytes.count)
            if turn == nil {
                guard speech else { rememberPreRoll(piece, seconds: duration); continue }
                turn = .init(); turnSeconds = 0; silenceSeconds = 0
                for previous in preRoll { emit(previous, into: &events) }
                preRoll.removeAll(); preRollSeconds = 0
            }
            emit(piece, into: &events)
            silenceSeconds = speech ? 0 : silenceSeconds + duration
            if turnSeconds >= 12 - 0.000001 {
                if let turn { events.append(.commit(turnID: turn, continuation: true)) }
                self.turn = nil; turnSeconds = 0; silenceSeconds = 0
            } else if silenceSeconds >= endpointSilence - 0.000001 {
                if let turn { events.append(.commit(turnID: turn, continuation: false)) }
                self.turn = nil; turnSeconds = 0; silenceSeconds = 0
            }
        }
        return events
    }

    private func emit(_ frame: OwnedPCMFrame, into events: inout [TranslationSegmentationEvent]) {
        guard let turn else { return }
        events.append(.audio(OwnedPCMFrame(bytes: frame.bytes, format: frame.format,
                                          captureTimestampNanoseconds: frame.captureTimestampNanoseconds,
                                          sequence: sequence, sourceID: frame.sourceID, sessionID: frame.sessionID,
                                          turnID: turn, generation: frame.generation)))
        sequence &+= 1
        turnSeconds += (try? frame.format.duration(byteCount: frame.bytes.count)) ?? 0
    }
    private func rememberPreRoll(_ frame: OwnedPCMFrame, seconds: Double) {
        preRoll.append(frame); preRollSeconds += seconds
        while preRollSeconds > 0.200001, !preRoll.isEmpty {
            let removed = preRoll.removeFirst()
            preRollSeconds -= (try? removed.format.duration(byteCount: removed.bytes.count)) ?? 0
        }
    }
    private func detect(_ frame: OwnedPCMFrame) throws -> Bool {
        if vadBridge == nil {
            vadBridge = try TranslationPCMBridge(format: .init(sampleRate: 16000, channels: 1, encoding: .signedInt16LittleEndian), context: .init())
        }
        guard let bridge = vadBridge else { return false }
        bridge.submit(try TranslationAudioPlayback.decode(.init(bytes: frame.bytes, format: frame.format, sequence: frame.sequence)))
        while let converted = try bridge.take() {
            converted.bytes.withUnsafeBytes { raw in
                for offset in stride(from: 0, to: raw.count, by: 2) { vadSamples.append(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self))) }
            }
            bridge.didConsume(converted)
        }
        var anySpeech = false
        var processed = false
        while vadSamples.count >= 320 {
            lastDecision = try detector.isSpeech(Array(vadSamples.prefix(320)))
            vadSamples.removeFirst(320); processed = true; anySpeech = anySpeech || lastDecision
        }
        return processed ? anySpeech : lastDecision
    }
}
