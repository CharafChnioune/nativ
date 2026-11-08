import Foundation

public struct TranslationTranscriptTurn: Equatable, Sendable {
    public let turnID: TranslationTurnID
    public let sourceText: String?
    public let translatedText: String
    public let incomplete: Bool
    public init(
        turnID: TranslationTurnID, sourceText: String?, translatedText: String, incomplete: Bool
    ) {
        self.turnID = turnID
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.incomplete = incomplete
    }
}
public struct TranslationTranscriptBuffer: Equatable, Sendable {
    public private(set) var turns: [TranslationTranscriptTurn] = []
    public private(set) var discardedTurnCount = 0
    public init() {}
    public mutating func append(_ turn: TranslationTranscriptTurn) {
        // Bound text as well as row count; providers may otherwise emit arbitrary strings.
        let bounded = TranslationTranscriptTurn(
            turnID: turn.turnID, sourceText: turn.sourceText.map { String($0.prefix(16_384)) },
            translatedText: String(turn.translatedText.prefix(16_384)), incomplete: turn.incomplete)
        turns.append(bounded)
        if turns.count > 200 {
            turns.removeFirst()
            discardedTurnCount += 1
        }
    }
}
public struct TranslationTextAccumulator: Sendable {
    public private(set) var text = ""
    public private(set) var committedText = ""
    public init() {}
    /// Returns only newly committed text suitable for speech, never tentative revisions.
    public mutating func apply(_ update: TranslationTextUpdate) throws -> String? {
        guard update.text.utf8.count <= 65_536 else {
            throw TranslationFailure(
                code: .invalidEvent, message: "Text update exceeds bounded segment size.")
        }
        switch update.stability {
        case .tentative:
            guard update.text.hasPrefix(committedText) else {
                throw TranslationFailure(
                    code: .invalidEvent,
                    message: "Tentative text revises an already committed prefix.")
            }
            text = update.text
            return nil
        case .stableAppend:
            guard committedText.utf8.count + update.text.utf8.count <= 65_536 else {
                throw TranslationFailure(
                    code: .invalidEvent, message: "Committed text exceeds bounded segment size.")
            }
            committedText += update.text
            text = committedText
            return update.text.isEmpty ? nil : update.text
        case .final:
            guard update.text.hasPrefix(committedText) else {
                throw TranslationFailure(
                    code: .invalidEvent, message: "Final text revises an already committed prefix.")
            }
            let suffix = String(update.text.dropFirst(committedText.count))
            text = update.text
            committedText = update.text
            return suffix.isEmpty ? nil : suffix
        }
    }
}
struct TranslationSegment: Sendable {
    let id: TranslationTurnID
    var frames: [OwnedPCMFrame] = []
    var duration = 0.0
    var committed = false
    var source = TranslationTextAccumulator()
    var target = TranslationTextAccumulator()
    var lastOutputSequence: UInt64?
    mutating func append(_ frame: OwnedPCMFrame, maximumSeconds: Double) throws {
        let seconds = try frame.format.duration(byteCount: frame.bytes.count)
        guard duration + seconds <= maximumSeconds + 0.000001, frames.count < 4096 else {
            throw TranslationFailure(
                code: .overload,
                message: "Speech exceeded the maximum segment; repeat the incomplete interval.")
        }
        if let last = frames.last {
            guard frame.sequence > last.sequence,
                frame.captureTimestampNanoseconds >= last.captureTimestampNanoseconds,
                frame.sourceID == last.sourceID, frame.format == last.format
            else {
                throw TranslationFailure(
                    code: .invalidAudio,
                    message: "PCM sequence, source, timestamp or format changed inside a turn.")
            }
        }
        frames.append(frame)
        duration += seconds
    }
}
