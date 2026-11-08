import XCTest
@testable import NativTranslationKit

final class TranslationContentGuardTests: XCTestCase {
    private let guardrail = TranslationContentGuard(languageDetector: { _ in nil })

    func testDutchHalfHourUsesPreviousHourAndAccepts24HourNotation() throws {
        try guardrail.validate(source: "Kom om half vier.", translation: "Come at 15:30.", sourceLanguage: "nl", targetLanguage: "en")
        try guardrail.validate(source: "Kom om half acht.", translation: "Come at half past seven.", sourceLanguage: "nl", targetLanguage: "en")
        XCTAssertThrowsError(try guardrail.validate(source: "Kom om half vier.", translation: "Come at 16:30.", sourceLanguage: "nl", targetLanguage: "en"))
        XCTAssertThrowsError(try guardrail.validate(source: "Kom om half acht.", translation: "Come at half past eight.", sourceLanguage: "nl", targetLanguage: "en"))
    }

    func testCompleteClockContrastAcceptsContextualHoursButRejectsChangesOrOmissions() throws {
        let source = "De afspraak is om half vier, niet om vier uur."
        let correct = "The appointment is at half past three, not at four."
        try guardrail.validate(source: source, translation: correct, sourceLanguage: "nl", targetLanguage: "en")
        try guardrail.validate(source: correct, translation: "De afspraak is om half vier, niet om vier.", sourceLanguage: "en", targetLanguage: "nl")
        for incorrect in ["The appointment is at half past four, not at four.",
                          "The appointment is at half past three, not at five.",
                          "The appointment is at half past three, not later."] {
            XCTAssertThrowsError(try guardrail.validate(source: source, translation: incorrect, sourceLanguage: "nl", targetLanguage: "en")) { error in
                XCTAssertTrue((error as? TranslationFailure)?.message.contains("clock time") == true)
            }
        }
        try guardrail.validate(source: "Kom om zeven, niet om acht.", translation: "Come at seven, not at eight.", sourceLanguage: "nl", targetLanguage: "en")
        try guardrail.validate(source: "Kijk naar vier stoelen.", translation: "Look at four chairs.", sourceLanguage: "nl", targetLanguage: "en")
        XCTAssertThrowsError(try guardrail.validate(source: "Kijk naar vier stoelen.", translation: "Look at five chairs.", sourceLanguage: "nl", targetLanguage: "en"))
        try guardrail.validate(source: "Ik vraag om vier stoelen.", translation: "I ask for four chairs.", sourceLanguage: "nl", targetLanguage: "en")
    }

    func testDateCardinalsAndOrdinalsHaveTheSameValueInEitherDirection() throws {
        let source = "Ik kom op acht december terug."
        let target = "I will return on the eighth of December."
        try guardrail.validate(source: source, translation: target, sourceLanguage: "nl", targetLanguage: "en")
        try guardrail.validate(source: target, translation: source, sourceLanguage: "en", targetLanguage: "nl")
        try guardrail.validate(source: "De afspraak is op drieentwintig april.", translation: "The appointment is on the twenty-third of April.", sourceLanguage: "nl", targetLanguage: "en")
        XCTAssertThrowsError(try guardrail.validate(source: source, translation: "I will return on the ninth of December.", sourceLanguage: "nl", targetLanguage: "en"))
        try guardrail.validate(source: "In december duurt het een seconde.", translation: "In December it takes one second.", sourceLanguage: "nl", targetLanguage: "en")
    }

    func testQuarterHoursAndSpokenEnglishClockTime() throws {
        try guardrail.validate(source: "Kom om kwart voor zes.", translation: "Come at five forty-five.", sourceLanguage: "nl", targetLanguage: "en")
        try guardrail.validate(source: "Arrive at a quarter past two.", translation: "Kom om kwart over twee.", sourceLanguage: "en", targetLanguage: "nl")
        XCTAssertThrowsError(try guardrail.validate(source: "Come at 14:15.", translation: "Kom om kwart voor twee.", sourceLanguage: "en", targetLanguage: "nl"))
        try guardrail.validate(source: "Kom om 15:30.", translation: "Come at 3:30 PM.", sourceLanguage: "nl", targetLanguage: "en")
        XCTAssertThrowsError(try guardrail.validate(source: "Kom om 15:30.", translation: "Come at 3:30 AM.", sourceLanguage: "nl", targetLanguage: "en"))
    }

    func testNumbersArePreservedAcrossWordsAndLocaleFormatting() throws {
        try guardrail.validate(source: "Er zijn 23 stoelen en 1.250,50 euro.", translation: "There are twenty-three chairs and 1,250.50 euros.", sourceLanguage: "nl", targetLanguage: "en")
        try guardrail.validate(source: "Drie, niet vier.", translation: "Three, not four.", sourceLanguage: "nl", targetLanguage: "en")
        XCTAssertThrowsError(try guardrail.validate(source: "Betaal 27 euro.", translation: "Pay 72 euros.", sourceLanguage: "nl", targetLanguage: "en"))
        XCTAssertThrowsError(try guardrail.validate(source: "Koop drie stoelen.", translation: "Buy chairs.", sourceLanguage: "nl", targetLanguage: "en"))
        XCTAssertThrowsError(try guardrail.validate(source: "Het is -5 graden.", translation: "It is 5 degrees.", sourceLanguage: "nl", targetLanguage: "en"))
        XCTAssertThrowsError(try guardrail.validate(source: "Ik werk vier uur.", translation: "I work five hours.", sourceLanguage: "nl", targetLanguage: "en"))
    }

    func testNegationCannotDisappearOrBeAdded() throws {
        XCTAssertThrowsError(try guardrail.validate(source: "Do not open the door.", translation: "Open de deur.", sourceLanguage: "en", targetLanguage: "nl"))
        XCTAssertThrowsError(try guardrail.validate(source: "Open de deur.", translation: "Do not open the door.", sourceLanguage: "nl", targetLanguage: "en"))
        try guardrail.validate(source: "Ik kan niet komen.", translation: "I can't come.", sourceLanguage: "nl", targetLanguage: "en")
        try guardrail.validate(source: "Ik kan niet komen.", translation: "I cannot come.", sourceLanguage: "nl", targetLanguage: "en")
        try guardrail.validate(source: "Dat is niet mogelijk.", translation: "That is impossible.", sourceLanguage: "nl", targetLanguage: "en")
        try guardrail.validate(source: "Nee.", translation: "No.", sourceLanguage: "nl", targetLanguage: "en")
        XCTAssertThrowsError(try guardrail.validate(source: "No.", translation: "Ja.", sourceLanguage: "en", targetLanguage: "nl"))
    }

    func testAmbiguousArticlesAndIdiomsDoNotBecomeSemanticClaims() throws {
        try guardrail.validate(source: "Een man koopt een boek.", translation: "A man buys a book.", sourceLanguage: "nl", targetLanguage: "en")
        try guardrail.validate(source: "Niet alleen Anna gaat mee.", translation: "Anna is also joining us.", sourceLanguage: "nl", targetLanguage: "en")
        try guardrail.validate(source: "Geen probleem.", translation: "You're welcome.", sourceLanguage: "nl", targetLanguage: "en")
        try guardrail.validate(source: "Ik wil een halve taart.", translation: "I want half a cake.", sourceLanguage: "nl", targetLanguage: "en")
        try guardrail.validate(source: "Kom op 2026-11-08.", translation: "Come on November 8, 2026.", sourceLanguage: "nl", targetLanguage: "en")
        try guardrail.validate(source: "Do not forget the keys.", translation: "Denk aan de sleutels.", sourceLanguage: "en", targetLanguage: "nl")
        try guardrail.validate(source: "Gebruik versie 1.2.3.", translation: "Use version 1.2.3.", sourceLanguage: "nl", targetLanguage: "en")
    }

    func testOnlyLongConfidentWrongLanguageOutputIsBlocked() throws {
        let confident = TranslationContentGuard(languageDetector: { _ in .init(language: "en", confidence: 0.99) })
        XCTAssertThrowsError(try confident.validateOutput("Please keep the door closed today.", targetLanguage: "nl"))
        try confident.validateOutput("New York", targetLanguage: "nl")
        let uncertain = TranslationContentGuard(languageDetector: { _ in .init(language: "en", confidence: 0.60) })
        try uncertain.validateOutput("Dit is een lange zin met een leenwoord.", targetLanguage: "nl")
    }

    func testGuardsNeverRewriteOrIncludeSensitiveTextInFailures() {
        do {
            try guardrail.validate(source: "Mijn code is 9274.", translation: "My code is 9275.", sourceLanguage: "nl", targetLanguage: "en")
            XCTFail("The changed code must fail")
        } catch let error as TranslationFailure {
            XCTAssertEqual(error.code, .unsupportedOutput)
            XCTAssertFalse(error.message.contains("9274"))
            XCTAssertFalse(error.message.contains("9275"))
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testInterpreterInstructionsRequireTranslationAndGeneralClockRules() {
        let prompt = TranslationInterpreterPrompt.instructions(sourceLanguage: "nl", targetLanguage: "en", spokenOutput: false)
        XCTAssertTrue(prompt.contains("Dutch"))
        XCTAssertTrue(prompt.contains("English"))
        XCTAssertTrue(prompt.contains("previous hour"))
        XCTAssertTrue(prompt.contains("Do not answer"))
        XCTAssertFalse(prompt.contains("15:30"), "Do not memorize the benchmark fixture")
    }
}
