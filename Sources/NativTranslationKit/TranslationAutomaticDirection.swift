import Foundation
import NaturalLanguage

public struct TranslationDirectionSelection: Equatable, Sendable {
    public let pair: TranslationLanguagePair
    /// Heuristic language confidence, never translation quality or qualification.
    public let confidence: Double
    public let qualified: Bool
    public init(pair: TranslationLanguagePair, confidence: Double, qualified: Bool = false) {
        self.pair = pair; self.confidence = confidence; self.qualified = qualified
    }
}
public struct TranslationLanguageDetection: Sendable {
    public let language: String?
    public let confidence: Double
    public init(language: String?, confidence: Double) { self.language = language; self.confidence = confidence }
}
public protocol TranslationLanguageDetector: Sendable {
    func detect(text: String, candidates: Set<String>) -> TranslationLanguageDetection
}

/// Conservative text-only direction hint after unhinted ASR. No voice identity,
/// acoustic language confidence or bilingual qualification is inferred here.
public struct TranslationAutomaticLanguageDetector: TranslationLanguageDetector {
    public typealias Hypotheses = @Sendable (String) -> [String: Double]
    private let hypotheses: Hypotheses
    public init(hypotheses: @escaping Hypotheses = Self.languageHypotheses) { self.hypotheses = hypotheses }
    public func detect(text: String, candidates: Set<String>) -> TranslationLanguageDetection {
        let words = Self.words(text)
        guard words.count >= 5, words.joined().count >= 24 else { return .init(language: nil, confidence: 0) }
        // Do not constrain recognition to the pair: a third language must not
        // be forced into one of the selected directions.
        let ranked = normalizedHypotheses(text, candidates: candidates).sorted { $0.value > $1.value }
        guard let best = ranked.first, candidates.contains(best.key), best.value >= 0.90,
              best.value - (ranked.dropFirst().first?.value ?? 0) >= 0.20 else {
            return .init(language: nil, confidence: ranked.first?.value ?? 0)
        }
        // Reject evidence of mixed speech. This is deliberately conservative;
        // failing to detect a mixture does not establish monolingual accuracy.
        if words.count >= 8 {
            for offset in stride(from: 0, through: words.count - 4, by: 2) {
                let window = words[offset..<offset + 4].joined(separator: " ")
                if let alternate = normalizedHypotheses(window, candidates: candidates).max(by: { $0.value < $1.value }),
                   alternate.value >= 0.95, alternate.key != best.key {
                    return .init(language: nil, confidence: best.value)
                }
            }
        }
        return .init(language: best.key, confidence: best.value)
    }
    public static func languageHypotheses(_ text: String) -> [String: Double] {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return Dictionary(uniqueKeysWithValues: recognizer.languageHypotheses(withMaximum: 3).map { ($0.key.rawValue, $0.value) })
    }
    static func languageCode(_ raw: String, candidates: Set<String>) -> String {
        let code = raw.lowercased().replacingOccurrences(of: "_", with: "-")
        if candidates.contains(code) { return code }
        let base = code.split(separator: "-").first.map(String.init) ?? code
        return candidates.contains(base) ? base : code
    }
    static func words(_ text: String) -> [String] {
        // NaturalLanguage segments scripts without spaces as well as Latin
        // text; character splitting would reject every Chinese sentence.
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = String(text[range])
            if word.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) { result.append(word) }
            return true
        }
        return result
    }
    private func normalizedHypotheses(_ text: String, candidates: Set<String>) -> [String: Double] {
        hypotheses(text).reduce(into: [:]) { result, item in
            guard item.value.isFinite, (0...1).contains(item.value) else { return }
            let code = Self.languageCode(item.key, candidates: candidates)
            // Regional/script aliases are correlated evidence. Summing would
            // invent confidence; retain only the strongest individual score.
            result[code] = max(result[code] ?? 0, item.value)
        }
    }
}
