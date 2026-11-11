import Foundation
import ZIPFoundation

/// CSV and xlsx import/export for meeting action lists.
enum MeetingActionsSpreadsheet {
    static let header = ["Type", "Item", "Owner", "Due", "Status", "Remark", "Source"]

    static func rows(_ items: [MeetingItem], sourceTitle: (String) -> String?) -> [[String]] {
        [header] + items.map { item in
            [item.kind.rawValue, item.text, item.owner ?? "", item.due ?? "", item.status.rawValue, item.remark ?? "",
             item.sourceRecordID.flatMap(sourceTitle) ?? ""]
        }
    }

    // MARK: CSV

    static func csv(_ rows: [[String]]) -> String {
        rows.map { row in
            row.map { cell in
                // Transcript text must never run as a spreadsheet formula when the CSV is opened.
                let cell = cell.first.map { "=+-@\t\r".contains($0) } == true ? "'" + cell : cell
                return cell.contains(where: { ",\"\n\r".contains($0) }) ? "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : cell
            }.joined(separator: ",")
        }.joined(separator: "\r\n") + "\r\n"
    }

    /// RFC 4180 parser; also accepts ';' as separator (Dutch Excel exports).
    static func parseCSV(_ text: String) -> [[String]] {
        let firstLine = text.prefix { $0 != "\n" }
        let separator: Character = firstLine.filter { $0 == ";" }.count > firstLine.filter { $0 == "," }.count ? ";" : ","
        var rows: [[String]] = [], row: [String] = [], cell = "", quoted = false
        var iterator = Array(text.replacingOccurrences(of: "\r\n", with: "\n")).makeIterator()
        var pending: Character? = nil
        while let c = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { cell.append("\"") } else { quoted = false; pending = next }
                    } else { quoted = false }
                } else { cell.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == separator { row.append(cell); cell = "" }
            else if c == "\n" { row.append(cell); rows.append(row); row = []; cell = "" }
            else { cell.append(c) }
        }
        if !cell.isEmpty || !row.isEmpty { row.append(cell); rows.append(row) }
        return rows.filter { !$0.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
    }

    // MARK: Import

    /// Maps rows with a header (Dutch or English column names) to items. Unknown statuses become
    /// open and keep the original value in the remark.
    static func items(from rows: [[String]]) -> [MeetingItem] {
        guard let header = rows.first else { return [] }
        func column(_ names: [String]) -> Int? {
            header.firstIndex { cell in names.contains(cell.trimmingCharacters(in: .whitespaces).lowercased()) }
        }
        let text = column(["item", "actie", "action", "omschrijving", "description", "taak", "task", "besluit", "decision"])
        let owner = column(["owner", "eigenaar", "actiehouder", "verantwoordelijke", "wie", "who"])
        let due = column(["due", "deadline", "datum", "date", "wanneer", "when"])
        let status = column(["status"])
        let remark = column(["remark", "opmerking", "opmerkingen", "comment", "comments", "notes", "notitie"])
        let kind = column(["type", "soort", "kind"])
        guard let text else { return [] }
        return rows.dropFirst().compactMap { row in
            func cell(_ index: Int?) -> String? {
                guard let index, index < row.count else { return nil }
                var value = row[index].trimmingCharacters(in: .whitespacesAndNewlines)
                if value.hasPrefix("'"), let next = value.dropFirst().first, "=+-@".contains(next) { value.removeFirst() }
                return value.isEmpty ? nil : value
            }
            guard let itemText = cell(text) else { return nil }
            let rawStatus = cell(status)
            let parsedStatus = rawStatus.flatMap(Self.status)
            var itemRemark = cell(remark)
            if let rawStatus, parsedStatus == nil {
                itemRemark = [itemRemark, "Status: \(rawStatus)"].compactMap { $0 }.joined(separator: "\n")
            }
            let isDecision = cell(kind).map { ["decision", "besluit"].contains($0.lowercased()) } ?? false
            return MeetingItem(kind: isDecision ? .decision : .action, text: itemText, owner: cell(owner), due: cell(due),
                               status: parsedStatus ?? .open, remark: itemRemark)
        }
    }

    static func status(_ value: String) -> MeetingItem.Status? {
        switch value.lowercased().trimmingCharacters(in: .whitespaces) {
        case "open", "todo", "to do", "nieuw", "new", "niet gestart": .open
        case "in_progress", "in progress", "bezig", "lopend", "in behandeling", "doing": .inProgress
        case "done", "klaar", "gereed", "afgerond", "voltooid", "completed", "closed", "gesloten": .done
        case "dropped", "vervallen", "geannuleerd", "cancelled", "canceled", "n.v.t.": .dropped
        default: nil
        }
    }

    /// First worksheet of an xlsx, via the existing extractor (tab-separated cells, one row per line).
    static func xlsxRows(data: Data, filename: String) async throws -> [[String]] {
        let content = try await SpreadsheetDocumentTextExtractor().extract(data: data, filename: filename, mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
        guard let sheet = content.sections.first else { return [] }
        return sheet.text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.components(separatedBy: "\t") }
    }

    // MARK: xlsx export

    static func writeXLSX(_ rows: [[String]], to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let archive = try Archive(url: url, accessMode: .create)
        func add(_ path: String, _ xml: String) throws {
            let data = Data(xml.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        try add("[Content_Types].xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>
            """)
        try add("_rels/.rels", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
            """)
        try add("xl/workbook.xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Actions" sheetId="1" r:id="rId1"/></sheets></workbook>
            """)
        try add("xl/_rels/workbook.xml.rels", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>
            """)
        let sheetRows = rows.enumerated().map { r, row in
            "<row r=\"\(r + 1)\">" + row.enumerated().map { c, value in
                "<c r=\"\(columnName(c))\(r + 1)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(escape(value))</t></is></c>"
            }.joined() + "</row>"
        }.joined()
        try add("xl/worksheets/sheet1.xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\(sheetRows)</sheetData></worksheet>
            """)
    }

    static func columnName(_ index: Int) -> String {
        var index = index, name = ""
        repeat {
            name = String(UnicodeScalar(UInt8(65 + index % 26))) + name
            index = index / 26 - 1
        } while index >= 0
        return name
    }

    private static func escape(_ text: String) -> String {
        text.unicodeScalars.filter { $0 == "\t" || $0 == "\n" || $0 == "\r" || $0.value >= 0x20 }
            .map(String.init).joined()
            .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
