import AppKit
import Foundation
import NativServerKit

enum ChatGenerationToolRegistry {
    static let music = "generate_music"
    static let video = "generate_video"
    static func modality(for name: String?) -> GenerationModality? { name == music ? .music : name == video ? .video : nil }
    static func definitions() -> [MLXChatToolDefinition] {
        GenerationModality.allCases.filter { GenerationToolAvailability.shared.contains($0) }.map { modality in
            var properties: [String: MLXJSONValue] = ["prompt": .object(["type": .string("string"), "description": .string("The user's detailed description. Model, deployment and presets are selected explicitly by the user in Nativ.")])]
            if modality == .music {
                properties["lyrics"] = .object(["type": .string("string"), "description": .string("Manual lyrics, preserved exactly. Do not invent lyrics unless the user requested writing them.")])
                properties["instrumental"] = .object(["type": .string("boolean")])
            }
            return MLXChatToolDefinition(function: MLXChatFunctionDefinition(name: modality == .music ? music : video,
                description: "Submit one \(modality.rawValue) generation and immediately return its durable job reference. Completion is observed in the result card; do not repeatedly submit to check progress.",
                parameters: .object(["type": .string("object"), "additionalProperties": .bool(false), "properties": .object(properties), "required": .array([.string("prompt")])])))
        }
    }
}

struct ChatGenerationToolArguments: Decodable {
    let prompt: String
    let lyrics: String?
    let instrumental: Bool?
    static func decode(_ call: MLXChatToolCall, modality: GenerationModality) throws -> Self {
        guard let raw = call.function?.arguments, let data = raw.data(using: .utf8), data.count <= 128 * 1024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: modality == .music ? ["prompt", "lyrics", "instrumental"] : ["prompt"]) else {
            throw GenerationAPIError(code: "invalid_arguments", message: "Generation arguments may contain only supported description and lyric fields.")
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard !value.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GenerationAPIError(code: "prompt_required", message: "A generation description is required.") }
        return value
    }
}

@MainActor
struct ChatGenerationToolExecutor {
    func execute(call: MLXChatToolCall, connection: GenerationConnection?, connectionIdentity: String?, intentID: String?) async throws -> String {
        guard let modality = ChatGenerationToolRegistry.modality(for: call.function?.name), let connection, let intentID else {
            throw GenerationAPIError(code: "configuration_required", message: "Connect to a configured generation server first.")
        }
        let identity = connectionIdentity ?? connection.baseURL.absoluteString
        let arguments = try ChatGenerationToolArguments.decode(call, modality: modality)
        let discovery = NativGenerationClient(modality: modality, connection: connection)
        let info = try await discovery.info()
        let bound = connection.bound(to: info.storeID)
        let client = NativGenerationClient(modality: modality, connection: bound)
        let existingIntent = try await GenerationIntentJournal.shared.intent(id: intentID)
        let request: [String: GenerationJSONValue]
        if let existing = existingIntent {
            guard existing.storeID == info.storeID, existing.connectionID == identity else { throw GenerationJournalError.identityMismatch }
            request = try JSONDecoder().decode([String: GenerationJSONValue].self, from: existing.request)
        } else {
            let profiles = try await client.models().filter { $0.readiness == "ready" }
            guard !profiles.isEmpty else { throw GenerationAPIError(code: "model_unavailable", message: "Set up a compatible model in the \(modality.rawValue.capitalized) workspace first.") }
            let chosen = try choose(profiles, modality: modality)
            var values = chosen.defaults
            // Provider defaults are normalized by the server; never carry an unrelated profile's controls.
            values["model"] = .string(chosen.id); values["prompt"] = .string(arguments.prompt)
            values["allow_remote"] = .bool(chosen.deployment != "local")
            if modality == .music {
                let instrumental = chosen.capabilities["vocals"]?.boolValue == false ? true : arguments.instrumental ?? true
                values["instrumental"] = .bool(instrumental)
                if !instrumental, let lyrics = arguments.lyrics { values["lyrics"] = .string(lyrics) }
            } else { values["operation"] = .string("text_to_video") }
            request = values
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let intent = try await GenerationIntentJournal.shared.freeze(id: intentID, storeID: info.storeID, connectionID: identity, modality: modality.rawValue, request: encoder.encode(request))
        let job: GenerationJob
        if let id = intent.jobID { job = try await client.job(id: id) }
        else {
            do { job = try await client.submit(request, idempotencyKey: intent.idempotencyKey) }
            catch {
                try await GenerationIntentJournal.shared.recordFailure(id: intent.id, storeID: info.storeID, error: error)
                throw error
            }
        }
        try await GenerationIntentJournal.shared.acknowledge(id: intent.id, storeID: info.storeID, jobID: job.jobID)
        let reference = GenerationChatJobReference(storeID: info.storeID, jobID: job.jobID, sessionID: job.sessionID, modality: modality)
        return String(decoding: try encoder.encode(reference), as: UTF8.self)
    }
    private func choose(_ profiles: [GenerationProfile], modality: GenerationModality) throws -> GenerationProfile {
        let alert = NSAlert(); alert.messageText = "Choose a \(modality.rawValue) model"
        alert.informativeText = "The selected model receives this request. Remote providers may charge your configured account. This starts one generation; its result appears in the saved job card."
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 440, height: 28))
        picker.addItems(withTitles: profiles.map { "\($0.displayName) · \($0.deploymentLabel)" })
        alert.accessoryView = picker; alert.addButton(withTitle: "Generate with Selected Provider"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { throw CancellationError() }
        return profiles[picker.indexOfSelectedItem]
    }
}
