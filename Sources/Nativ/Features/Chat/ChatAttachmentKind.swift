import Foundation
import UniformTypeIdentifiers

enum ChatAttachmentKind: Equatable, Sendable {
    case image
    case generatedMedia
    case document(ChatDocumentFormat)
    case unsupported

    var documentFormat: ChatDocumentFormat? {
        guard case .document(let format) = self else { return nil }
        return format
    }
}

/// Original files stay in the media store; only these IDs and metadata go to the model.
enum ChatWorkAttachments {
    static let maximumFiles = 20
    static let maximumBytes = 64 * 1024 * 1024

    static func available(in messages: [ChatTranscriptMessage]) -> [ChatImageAttachment] {
        var seen = Set<UUID>()
        return messages.flatMap { $0.imageAttachments + $0.generationAssets.map(ChatImageAttachment.init(serviceReference:)) }.filter {
            $0.chatAttachmentKind != .unsupported && seen.insert($0.id).inserted
        }
    }

    static func resolve(_ ids: [UUID]?, in messages: [ChatTranscriptMessage]) throws -> [ChatImageAttachment] {
        guard let ids, !ids.isEmpty, ids.count <= maximumFiles, Set(ids).count == ids.count else {
            throw ChatWorkError.invalid("upload requires 1–20 distinct attachment_ids from this chat's attachments list.")
        }
        let available = available(in: messages)
        return try ids.map { id in
            guard let attachment = available.first(where: { $0.id == id }) else {
                throw ChatWorkError.invalid("An attachment is no longer available in this chat. Call attachments again.")
            }
            return attachment
        }
    }

    static func listJSON(in messages: [ChatTranscriptMessage]) throws -> String {
        let entries = available(in: messages).map { attachment in
            ["attachment_id": attachment.id.uuidString,
             "filename": attachment.filename, "mime_type": attachment.mimeType]
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys]), as: UTF8.self)
    }

    struct File: Sendable {
        let id: UUID
        let filename: String
        let mimeType: String
        let data: Data
    }

    @concurrent
    static func load(_ attachments: [ChatImageAttachment]) async throws -> [File] {
        var remaining = maximumBytes
        var files: [File] = []
        for attachment in attachments {
            try Task.checkCancellation()
            if let reference = attachment.serviceReference {
                guard let count = reference.byteSize, count <= Int64(remaining) else { throw ChatWorkError.invalid("Generated media uploads require known size below the 64 MiB work-upload limit.") }
                let url = try await GenerationMediaAccess.file(for: reference)
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard data.count <= Int64(remaining) else { throw ChatWorkError.invalid("Upload supports up to 64 MiB per action.") }
                remaining -= data.count
                files.append(File(id: attachment.id, filename: ChatAttachmentPreviewFile.safeFilename(attachment.filename), mimeType: attachment.mimeType, data: data))
                continue
            }
            // Bound disk reads before allocating the JavaScript bridge's base64 copy.
            let byteCount = try attachment.assetFileURL?.resourceValues(forKeys: [.fileSizeKey]).fileSize
                ?? (attachment.base64Data.utf8.count / 4 * 3)
            guard byteCount <= remaining else {
                throw ChatWorkError.invalid("Upload supports up to 64 MiB per action. Upload fewer or smaller files.")
            }
            guard let data = attachment.imageData else {
                throw ChatWorkError.invalid("The original file “\(attachment.filename)” could not be read. Attach it again.")
            }
            guard data.count <= Int64(remaining) else {
                throw ChatWorkError.invalid("Upload supports up to 64 MiB per action.")
            }
            remaining -= data.count
            files.append(File(id: attachment.id, filename: ChatAttachmentPreviewFile.safeFilename(attachment.filename),
                        mimeType: attachment.mimeType, data: data))
        }
        return files
    }
}

struct ChatAttachmentPreviewFile: Sendable {
    let url: URL
    let directoryURL: URL

    @concurrent
    static func create(
        for attachment: ChatImageAttachment,
        in temporaryDirectory: URL = .temporaryDirectory
    ) async throws -> Self {
        if let reference = attachment.serviceReference {
            let source = try await GenerationMediaAccess.file(for: reference)
            let directory = temporaryDirectory.appendingPathComponent("Nativ Media Preview").appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let copy = directory.appendingPathComponent(safeFilename(attachment.filename))
            try FileManager.default.copyItem(at: source, to: copy)
            return Self(url: copy, directoryURL: directory)
        }
        guard let data = Data(base64Encoded: attachment.base64Data) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        try Task.checkCancellation()

        let directoryURL = temporaryDirectory
            .appending(path: "io.github.charafchnioune.nativ.ChatPreviews", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let url = directoryURL.appending(
            path: safeFilename(attachment.filename),
            directoryHint: .notDirectory
        )

        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            try Task.checkCancellation()
            return Self(url: url, directoryURL: directoryURL)
        } catch {
            try? FileManager.default.removeItem(at: directoryURL)
            throw error
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    static func safeFilename(_ filename: String) -> String {
        let filename = (filename as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return filename.isEmpty || filename == "." || filename == ".."
            ? "Attachment"
            : filename
    }
}

extension ChatImageAttachment {
    var fileExtension: String {
        filename.pathExtension
    }

    var chatAttachmentKind: ChatAttachmentKind {
        if serviceReference != nil { return .generatedMedia }
        let normalizedMIMEType = mimeType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if !normalizedMIMEType.isEmpty,
           normalizedMIMEType != "application/octet-stream" {
            return Self.kind(
                for: UTType(mimeType: normalizedMIMEType),
                fileExtension: filename.pathExtension
            )
        }

        return Self.kind(
            for: UTType(filenameExtension: filename.pathExtension),
            fileExtension: filename.pathExtension
        )
    }

    private static func kind(for type: UTType?, fileExtension: String) -> ChatAttachmentKind {
        if type?.conforms(to: .image) == true {
            return .image
        }
        if type?.conforms(to: .pdf) == true {
            return .document(.pdf)
        }
        if type?.conforms(to: .commaSeparatedText) == true {
            return .document(.csv)
        }
        if type?.conforms(to: .rtf) == true {
            return .document(.richText)
        }
        // A notebook is JSON, so it conforms to .text wherever .ipynb is registered. The
        // extension is the only thing that separates it from an ordinary JSON file, and
        // plain text extraction would keep its base64 image outputs.
        if ChatDocumentFormat.forFileExtension(fileExtension) == .notebook {
            return .document(.notebook)
        }
        if type?.conforms(to: .text) == true || type?.conforms(to: .sourceCode) == true {
            return .document(.plainText)
        }

        if let format = ChatDocumentFormat.forFileExtension(fileExtension) {
            return .document(format)
        }

        switch fileExtension {
        case "txt", "md", "markdown", "json", "jsonl", "xml", "html", "htm",
             "css", "js", "jsx", "ts", "tsx", "swift", "py", "rb", "rs", "go",
             "java", "kt", "kts", "c", "h", "cc", "cpp", "cxx", "hpp", "m", "mm",
             "sh", "bash", "zsh", "fish", "sql", "yaml", "yml", "toml", "ini", "cfg",
             "conf", "env", "log":
            return .document(.plainText)
        default:
            return .unsupported
        }
    }
}

private extension String {
    var pathExtension: String {
        (self as NSString).pathExtension.lowercased()
    }
}
