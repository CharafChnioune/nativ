import CryptoKit
import Foundation
import NativServerKit

/// Rebuildable metadata projection. No canonical path or original is owned by MediaAssetStore.
enum GenerationArtifactProjection {
    static func stableID(storeID: String, assetID: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data((storeID + ":" + assetID).utf8)).prefix(16))
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    static func artifacts(jobs: [GenerationJob], assets: [String: GenerationAsset]) -> [Artifact] {
        jobs.compactMap { job in
            guard let id = job.assetID, let asset = assets[id], !asset.trashed, asset.storeID == job.storeID else { return nil }
            let identifier = stableID(storeID: job.storeID, assetID: id)
            let session = UUID(uuidString: job.sessionID) ?? stableID(storeID: job.storeID, assetID: job.sessionID)
            let message = UUID(uuidString: job.jobID) ?? identifier
            return Artifact(id: identifier, kind: job.modality == .music ? .audio : .video, source: .generated,
                sessionID: session, messageID: message, filename: asset.filename, mimeType: asset.mimeType,
                relativePath: "", byteSize: Int(clamping: asset.byteSize), createdAt: Date(timeIntervalSince1970: asset.createdAt),
                prompt: job.request["prompt"]?.stringValue, sessionTitle: job.request["prompt"]?.stringValue ?? "Generation",
                generation: ArtifactGeneration(prompt: job.request["prompt"]?.stringValue, modelID: job.request["model"]?.stringValue,
                    seed: job.effectiveParameters?["seed"]?.integerValue.map(Int.init), width: asset.metadata["width"]?.numberValue.map(Int.init), height: asset.metadata["height"]?.numberValue.map(Int.init)),
                usages: [ArtifactUsage(workspace: job.modality == .music ? .musicGeneration : .videoGeneration, sessionID: session, messageID: message, attachmentID: identifier, isGenerationOutput: true)],
                serviceReference: GenerationServiceReference(storeID: job.storeID, assetID: id, jobID: job.jobID, sessionID: job.sessionID, modality: job.modality.rawValue), mediaText: [job.request["lyrics"]?.stringValue, asset.metadata["provider_reported"]?.objectValue?["generated_lyrics"]?.stringValue].compactMap { $0 }.joined(separator: "\n"))
        }
    }
}
