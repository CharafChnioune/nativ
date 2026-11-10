import Foundation
import NativServerKit

@MainActor
enum GenerationMediaAccess {
    static weak var hub: GenerationChatLibraryHub?
    static func file(for reference: GenerationServiceReference) async throws -> URL {
        guard let modality = GenerationModality(rawValue: reference.modality), let library = hub?.library(modality), library.storeID == reference.storeID,
              let asset = library.assets[reference.assetID] else { throw GenerationAPIError(code: "original_server_required", message: "Reconnect to this attachment's original Nativ server to retrieve it.") }
        return try await library.mediaURL(asset: asset)
    }
    static func reserve(_ attachment: ChatImageAttachment, chatID: UUID) async throws -> ChatImageAttachment {
        guard var reference = attachment.serviceReference, let modality = GenerationModality(rawValue: reference.modality), let library = hub?.library(modality), library.storeID == reference.storeID, let connection = library.connection else {
            throw GenerationAPIError(code: "original_server_required", message: "Reconnect to this attachment's original Nativ server before attaching it.")
        }
        let id = "chat:" + chatID.uuidString + ":attachment:" + UUID().uuidString
        reference.referenceID = id
        _ = try await GenerationReferenceOutbox.shared.reserve(reference: reference, ownerID: chatID.uuidString, id: id)
        let result = try await NativGenerationClient(modality: modality, connection: connection).putReference(assetID: reference.assetID, referenceID: id, phase: "reserve", expectedRevision: 0, owner: ["workspace": .string("chat"), "session_id": .string(chatID.uuidString)])
        try await GenerationReferenceOutbox.shared.reserved(id: id, revision: Int(result["revision"]?.numberValue ?? 1))
        var prepared = attachment; prepared.serviceReference = reference
        return prepared
    }
}
