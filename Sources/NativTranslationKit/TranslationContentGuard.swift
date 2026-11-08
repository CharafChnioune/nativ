import Foundation
import NaturalLanguage

public struct TranslationLanguageHypothesis: Sendable {
  public let language: String
  public let confidence: Double
  public init(language: String, confidence: Double) { self.language = language; self.confidence = confidence }
}

/// Conservative rejection of obvious errors, never correction or semantic certification.
/// Source-aware numeric/time/negation heuristics currently cover Dutch–English only.
/// The recognizer's confidence is a language hint, not a measure of translation quality.
public struct TranslationContentGuard: Sendable {
  public typealias LanguageDetector = @Sendable (String) -> TranslationLanguageHypothesis?
  private let languageDetector: LanguageDetector
  public init(languageDetector: @escaping LanguageDetector = Self.detectLanguage) {
    self.languageDetector = languageDetector
  }

  public func validateOutput(_ translation: String, targetLanguage: String) throws {
    let words = Self.tokens(translation)
    let letters = translation.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
    guard words.count >= 5, letters >= 24, let hypothesis = languageDetector(translation),
      hypothesis.confidence.isFinite else { return }
    let detected = Self.base(hypothesis.language), target = Self.base(targetLanguage)
    // The lower threshold is backed only by the NL/EN draft-corpus experiment:
    // 54 eligible source-as-wrong-target texts caught, no rejected draft references.
    // These OS scores are heuristic hints, not calibrated probabilities or qualification.
    let threshold = Set([detected, target]) == Set(["nl", "en"]) ? 0.90 : 0.98
    guard hypothesis.confidence >= threshold, detected != target else { return }
    throw Self.failure("The model appears to have used a different target language. This turn was stopped; retry or explicitly choose another model.")
  }

  public func validate(source: String, translation: String, sourceLanguage: String, targetLanguage: String) throws {
    try validateOutput(translation, targetLanguage: targetLanguage)
    let sourceLanguage = Self.base(sourceLanguage), targetLanguage = Self.base(targetLanguage)
    guard Set([sourceLanguage, targetLanguage]) == Set(["nl", "en"]) else { return }
    let source = Self.normalized(source), target = Self.normalized(translation)
    let sourceTime = Self.clockTimes(source, language: sourceLanguage)
    let targetTime = Self.clockTimes(target, language: targetLanguage)
    // A missing/unrecognized time is not compared: alternative valid verbalizations exist.
    // When both forms are recognized, preserve the time without inventing AM/PM.
    if !sourceTime.times.isEmpty, !targetTime.times.isEmpty,
      (sourceTime.times.count != targetTime.times.count || !zip(sourceTime.times.sorted(), targetTime.times.sorted()).allSatisfy({ $0.matches($1) })) {
      throw Self.failure("The translated clock time differs from the recognized source. This turn was stopped; repeat the time clearly or choose another model.")
    }
    if sourceTime.times.count == targetTime.times.count,
      let sourceNumbers = Self.numbers(sourceTime.remainder, language: sourceLanguage),
      let targetNumbers = Self.numbers(targetTime.remainder, language: targetLanguage),
      sourceNumbers.sorted() != targetNumbers.sorted() {
      throw Self.failure("The translated numbers differ from the recognized source. This turn was stopped; repeat the numbers clearly or choose another model.")
    }
    if let sourceNegative = Self.negation(source, language: sourceLanguage),
      let targetNegative = Self.negation(target, language: targetLanguage), sourceNegative != targetNegative {
      throw Self.failure("The translation may have changed a negation. This turn was stopped; repeat the statement or choose another model.")
    }
  }

  public static func detectLanguage(_ text: String) -> TranslationLanguageHypothesis? {
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first else { return nil }
    return .init(language: language.rawValue, confidence: confidence)
  }

  private static func failure(_ message: String) -> TranslationFailure { .init(code: .unsupportedOutput, message: message) }
  private static func base(_ language: String) -> String { language.lowercased().split(separator: "-").first.map(String.init) ?? language }
  private static func normalized(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
      .replacingOccurrences(of: "’", with: "'")
  }
  private static func tokens(_ text: String) -> [String] {
    text.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
  }
  private static let english = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
  private static let dutch = ["nul", "een", "twee", "drie", "vier", "vijf", "zes", "zeven", "acht", "negen", "tien", "elf", "twaalf", "dertien", "veertien", "vijftien", "zestien", "zeventien", "achttien", "negentien"]
  private static func numberWords(_ language: String, includingDateOrdinals: Bool = false) -> [String: Int] {
    let units = language == "nl" ? dutch : english
    let tens = language == "nl" ? ["twintig", "dertig", "veertig", "vijftig", "zestig", "zeventig", "tachtig", "negentig"] : ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
    var result = Dictionary(uniqueKeysWithValues: units.enumerated().map { ($0.element, $0.offset) })
    // Dates commonly switch from Dutch cardinals to English ordinals (acht → eighth).
    // Keep their numeric value without rewriting the source or translation.
    let ordinals = language == "nl"
      ? ["nulde", "eerste", "tweede", "derde", "vierde", "vijfde", "zesde", "zevende", "achtste", "negende", "tiende", "elfde", "twaalfde", "dertiende", "veertiende", "vijftiende", "zestiende", "zeventiende", "achttiende", "negentiende"]
      : ["zeroth", "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth", "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth", "eighteenth", "nineteenth"]
    if includingDateOrdinals { for (value, name) in ordinals.enumerated() { result[name] = value } }
    let ordinalTens = language == "nl" ? tens.map { $0 + "ste" }
      : ["twentieth", "thirtieth", "fortieth", "fiftieth", "sixtieth", "seventieth", "eightieth", "ninetieth"]
    for (index, name) in tens.enumerated() {
      let value = (index + 2) * 10
      result[name] = value
      if includingDateOrdinals { result[ordinalTens[index]] = value }
      if language == "nl" { for unit in 1...9 {
        result[units[unit] + "en" + name] = value + unit
        if includingDateOrdinals { result[units[unit] + "en" + name + "ste"] = value + unit }
      } }
    }
    return result
  }

  private struct ClockTime: Comparable {
    let minutes: Int
    let knownPeriod: Bool
    static func < (lhs: Self, rhs: Self) -> Bool {
      if lhs.minutes % 720 != rhs.minutes % 720 { return lhs.minutes % 720 < rhs.minutes % 720 }
      return lhs.minutes < rhs.minutes
    }
    func matches(_ other: Self) -> Bool {
      minutes % 720 == other.minutes % 720 && (!(knownPeriod && other.knownPeriod) || minutes == other.minutes)
    }
  }

  private static func clockTimes(_ text: String, language: String) -> (times: [ClockTime], remainder: String) {
    var text = text.replacingOccurrences(of: #"(?<=\p{L})-(?=\p{L})"#, with: " ", options: .regularExpression)
    var times: [ClockTime] = []
    let words = numberWords(language)
    let hourNames = (language == "nl" ? dutch : english)[1...12].joined(separator: "|")
    let hour = "(\\d{1,2}|" + hourNames + ")"
    func value(_ string: String) -> Int? {
      guard let value = Int(string) ?? words[string], (0...23).contains(value) else { return nil }
      return value
    }
    func extract(_ pattern: String, digital: Bool = false, convert: ([String]) -> Int?) {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
      let original = text as NSString
      let matches = regex.matches(in: text, range: NSRange(location: 0, length: original.length))
      let mutable = NSMutableString(string: text)
      for match in matches.reversed() {
        let captures = (1..<match.numberOfRanges).map {
          match.range(at: $0).location == NSNotFound ? "" : original.substring(with: match.range(at: $0))
        }
        if let time = convert(captures) {
          let period = digital && (Int(captures[0])! >= 13 || !(captures.last?.isEmpty ?? true))
          times.append(.init(minutes: (time + 1440) % 1440, knownPeriod: period))
          mutable.replaceCharacters(in: match.range, with: " ")
        }
      }
      text = mutable as String
    }
    extract("\\b([01]?\\d|2[0-3]):([0-5]\\d)(?:\\s*(am|pm))?\\b", digital: true) { captures in
      var hour = Int(captures[0])!
      if captures[2] == "am" { hour %= 12 }
      if captures[2] == "pm" { hour = hour % 12 + 12 }
      return hour * 60 + Int(captures[1])!
    }
    if language == "nl" {
      extract("\\bhalf\\s+" + hour + "\\b") { value($0[0]).map { ($0 - 1) * 60 + 30 } }
      extract("\\bkwart\\s+(voor|over)\\s+" + hour + "\\b") { captures in value(captures[1]).map { $0 * 60 + (captures[0] == "voor" ? -15 : 15) } }
      // 'Vier uur' alone can be a duration. Only treat it as a clock with a time cue.
      extract("\\b(?:om|het is)\\s+" + hour + "\\s+uur\\b") { value($0[0]).map { $0 * 60 } }
      extract("\\bom\\s+" + hour + "\\b(?=\\s*(?:[.,;!?]|$|(?:precies|vandaag|morgen|vanmiddag|vanavond|en|of|maar|niet)\\b))") {
        value($0[0]).map { $0 * 60 }
      }
    } else {
      extract("\\bhalf\\s+past\\s+" + hour + "\\b") { value($0[0]).map { $0 * 60 + 30 } }
      extract("\\b(?:a\\s+)?quarter\\s+(to|past)\\s+" + hour + "\\b") { captures in value(captures[1]).map { $0 * 60 + (captures[0] == "to" ? -15 : 15) } }
      extract("\\b" + hour + "\\s+o'clock\\b") { value($0[0]).map { $0 * 60 } }
      let minute = "(ten|fifteen|(?:twenty|thirty|forty|fifty)(?: (?:one|two|three|four|five|six|seven|eight|nine))?)"
      extract("\\b" + hour + "\\s+" + minute + "\\b") { captures in
        guard let hour = value(captures[0]) else { return nil }
        let minutes = captures[1].split(separator: " ").compactMap { words[String($0)] }.reduce(0, +)
        return hour * 60 + minutes
      }
      // 'At four' is a clock when followed by a boundary/time modifier, but
      // 'look at four chairs' must remain a quantity rather than a clock.
      extract("\\bat\\s+" + hour + "\\b(?=\\s*(?:[.,;!?]|$|(?:am|pm|sharp|today|tomorrow|tonight|and|or|but|not)\\b))") {
        value($0[0]).map { $0 * 60 }
      }
    }
    return (times, text)
  }

  private static func numbers(_ text: String, language: String) -> [String]? {
    let tokens = Self.tokens(text)
    // Fractions, spoken decimals and large scale words need a richer parser; do not
    // reject valid paraphrases by pretending these forms have been understood.
    let uncertain: Set<String> = ["half", "halve", "quarter", "kwart", "point", "punt", "komma", "million", "miljoen", "billion", "miljard", "thousand", "duizend", "hundred", "honderd"]
    guard uncertain.isDisjoint(with: tokens) else { return nil }
    // Dates can move month names and numeric components across locales.
    if text.range(of: #"\b\d{1,4}[-/]\d{1,2}[-/]\d{1,4}\b"#, options: .regularExpression) != nil { return nil }
    let months: Set<String> = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december", "januari", "februari", "maart", "mei", "juni", "juli", "augustus", "oktober"]
    let words = numberWords(language, includingDateOrdinals: !months.isDisjoint(with: tokens))
    let regex = try! NSRegularExpression(pattern: #"[-+]?\d+(?:[.,]\d+)*|[\p{L}]+"#)
    let source = text as NSString
    let parts = regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map { source.substring(with: $0.range) }
    var result: [String] = []; var index = 0
    while index < parts.count {
      let token = parts[index]
      // A duration's singular 'second' is not the ordinal day, even in a dated sentence.
      if token == "second", index > 0,
        words[parts[index - 1]] != nil || ["a", "per", "each"].contains(parts[index - 1]) {
        index += 1
        continue
      }
      if var value = words[token] {
        if language == "en", value >= 20, value.isMultiple(of: 10), index + 1 < parts.count,
          let unit = words[parts[index + 1]], (1...9).contains(unit) { value += unit; index += 1 }
        // A lone one/een is frequently a pronoun or article, not a count.
        if value != 1 { result.append(String(value)) }
      } else if token.first?.isNumber == true || token.first == "-" || token.first == "+" {
        let syntax = language == "nl" ? #"^[+-]?(?:\d+|\d{1,3}(?:\.\d{3})+)(?:,\d+)?$"# : #"^[+-]?(?:\d+|\d{1,3}(?:,\d{3})+)(?:\.\d+)?$"#
        guard token.range(of: syntax, options: .regularExpression) != nil else { return nil }
        let canonical = language == "nl" ? token.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".") : token.replacingOccurrences(of: ",", with: "")
        guard let decimal = Decimal(string: canonical, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        if decimal != 1 { result.append(NSDecimalNumber(decimal: decimal).stringValue) }
      }
      index += 1
    }
    return result
  }

  private static func negation(_ text: String, language: String) -> Bool? {
    let idioms = ["not only", "niet alleen", "no problem", "geen probleem", "no doubt", "zonder twijfel", "do not forget", "don't forget", "vergeet niet", "niet vergeten", "not impossible", "niet onmogelijk", "not incorrect", "niet onjuist"]
    if idioms.contains(where: text.contains) { return nil }
    let words = Set(tokens(text))
    let negatives: Set<String> = language == "nl"
      ? ["nee", "niet", "geen", "nooit", "niemand", "niets", "nergens", "zonder", "onmogelijk", "onjuist", "verboden", "onbeschikbaar", "vermijd"]
      : ["not", "no", "none", "never", "nobody", "nothing", "nowhere", "neither", "without", "cannot", "impossible", "incorrect", "forbidden", "unavailable", "unable", "avoid"]
    return !negatives.isDisjoint(with: words) || (language == "en" && text.contains("n't"))
  }
}
