import CryptoKit
import Foundation
import NativServerKit

struct GenerationPreparedReference: Equatable, Sendable {
    let storeID: String
    let inputID: String
    let derivativeID: String
    let sha256: String
    let byteSize: Int64
    let role: String
    let signature: String
    let transform: [String: GenerationJSONValue]
    let previewURL: URL

    var requestValue: GenerationJSONValue {
        .object(["input_id": .string(inputID), "role": .string(role), "transform": .object(transform)])
    }

    @concurrent static func verify(url: URL, sha256: String, byteSize: Int64) async throws -> Bool {
        guard byteSize > 0, byteSize <= 160 * 1024 * 1024,
              Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) == byteSize else { return false }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
            try Task.checkCancellation(); hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == sha256.lowercased()
    }
}
