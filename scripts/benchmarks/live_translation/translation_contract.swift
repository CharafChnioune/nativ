import Foundation
import NativTranslationKit

// A small driver for the actual production prompt and guard. Synthetic probe
// text travels on stdin; no model is loaded and no transcript is logged here.
let arguments = CommandLine.arguments
do {
    guard arguments.count == 4 else { throw NSError(domain: "Usage: translation-contract prompt|validate source target", code: 1) }
    let action = arguments[1], source = arguments[2], target = arguments[3]
    let result: [String: Any]
    switch action {
    case "prompt":
        result = ["text": TranslationInterpreterPrompt.instructions(sourceLanguage: source, targetLanguage: target),
                  "speech": TranslationInterpreterPrompt.instructions(sourceLanguage: source, targetLanguage: target, spokenOutput: true)]
    case "validate", "validate-output":
        var input = Data()
        while input.count <= 100_000 {
            guard let chunk = try FileHandle.standardInput.read(upToCount: min(8_192, 100_001 - input.count)), !chunk.isEmpty else { break }
            input.append(chunk)
        }
        guard input.count <= 100_000,
              let value = try JSONSerialization.jsonObject(with: input) as? [String: String],
              let translated = value["translation"], action == "validate-output" || value["source"] != nil else {
            throw NSError(domain: "Invalid bounded validation input", code: 2)
        }
        do {
            if action == "validate-output" {
                try TranslationContentGuard().validateOutput(translated, targetLanguage: target)
            } else {
                try TranslationContentGuard().validate(source: value["source"]!, translation: translated, sourceLanguage: source, targetLanguage: target)
            }
            result = ["accepted": true, "qualified": false]
        } catch let failure as TranslationFailure {
            result = ["accepted": false, "qualified": false, "code": failure.code.rawValue, "reason": failure.message]
        }
    default: throw NSError(domain: "Unknown contract operation", code: 3)
    }
    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
} catch {
    FileHandle.standardError.write(Data("Translation contract driver failed.\n".utf8))
    exit(1)
}
