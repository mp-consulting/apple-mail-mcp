import Foundation

/// One value in an exported table.
enum Cell: Sendable, Equatable {
    case text(String)
    /// A decimal written as a number (e.g. "1234.56").
    case number(String)
    case bool(Bool)
    case empty
}

enum ExportFormat: String, CaseIterable, Sendable {
    case csv, json, xlsx
}

/// Writes rows of mail data as CSV, JSON or XLSX.
///
/// Every text value comes from whoever sent the mail, so the writers never produce formulas:
/// CSV text starting with `=`, `+`, `-`, `@`, tab or CR gets a leading `'` (the OWASP CSV-injection
/// guard), and XLSX cells are inline strings or plain numbers.
enum SpreadsheetWriter {
    static func data(format: ExportFormat, columns: [String], rows: [[Cell]]) -> Data {
        switch format {
        case .csv: csv(columns: columns, rows: rows)
        case .json: json(columns: columns, rows: rows)
        case .xlsx: xlsx(columns: columns, rows: rows)
        }
    }

    // MARK: CSV

    static func csv(columns: [String], rows: [[Cell]]) -> Data {
        // UTF-8 byte order mark: Excel otherwise reads accents as Latin-1.
        var out = "\u{FEFF}" + columns.map(csvField).joined(separator: ",") + "\r\n"
        for row in rows {
            out += row.map { cell -> String in
                switch cell {
                case .text(let text): csvField(neutralizeFormula(text))
                case .number(let number): number
                case .bool(let value): value ? "TRUE" : "FALSE"
                case .empty: ""
                }
            }.joined(separator: ",")
            out += "\r\n"
        }
        return Data(out.utf8)
    }

    static func csvField(_ text: String) -> String {
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == ";" })
            || text.first?.isWhitespace == true || text.last?.isWhitespace == true
        else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Spreadsheet apps run text that starts like a formula; a leading `'` keeps it text.
    static func neutralizeFormula(_ text: String) -> String {
        guard let first = text.unicodeScalars.first, ["=", "+", "-", "@", "\t", "\r", "＝", "＋", "－", "＠"].contains(first) else {
            return text
        }
        return "'" + text
    }

    // MARK: JSON

    static func json(columns: [String], rows: [[Cell]]) -> Data {
        var out = "[\n"
        for (index, row) in rows.enumerated() {
            let object = JSON.obj(zip(columns, row).map { column, cell -> (String, JSON?) in
                switch cell {
                case .text(let text): (column, .string(text))
                case .number(let number): (column, Double(number).map(JSON.double) ?? .string(number))
                case .bool(let value): (column, .bool(value))
                case .empty: (column, nil)
                }
            })
            out += "  " + object.serialized() + (index < rows.count - 1 ? ",\n" : "\n")
        }
        out += "]\n"
        return Data(out.utf8)
    }

    // MARK: XLSX

    static func xlsx(columns: [String], rows: [[Cell]]) -> Data {
        var sheet = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
            """
        func row(_ index: Int, _ cells: [Cell]) {
            sheet += "<row r=\"\(index)\">"
            for (column, cell) in cells.enumerated() {
                let reference = columnName(column) + String(index)
                switch cell {
                case .text(let text):
                    sheet += "<c r=\"\(reference)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xmlText(text))</t></is></c>"
                case .number(let number) where Double(number) != nil:
                    sheet += "<c r=\"\(reference)\"><v>\(number)</v></c>"
                case .number(let number):
                    sheet += "<c r=\"\(reference)\" t=\"inlineStr\"><is><t>\(xmlText(number))</t></is></c>"
                case .bool(let value):
                    sheet += "<c r=\"\(reference)\" t=\"b\"><v>\(value ? 1 : 0)</v></c>"
                case .empty:
                    break
                }
            }
            sheet += "</row>"
        }
        row(1, columns.map(Cell.text))
        for (index, cells) in rows.enumerated() { row(index + 2, cells) }
        sheet += "</sheetData></worksheet>"

        let relationships = "http://schemas.openxmlformats.org/package/2006/relationships"
        let officeDocument = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let files: [(String, String)] = [
            (
                "[Content_Types].xml",
                """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
                <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
                <Default Extension="xml" ContentType="application/xml"/>\
                <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
                <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
                </Types>
                """
            ),
            (
                "_rels/.rels",
                """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Relationships xmlns="\(relationships)"><Relationship Id="rId1" \
                Type="\(officeDocument)/officeDocument" Target="xl/workbook.xml"/></Relationships>
                """
            ),
            (
                "xl/workbook.xml",
                """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="\(officeDocument)">\
                <sheets><sheet name="Messages" sheetId="1" r:id="rId1"/></sheets></workbook>
                """
            ),
            (
                "xl/_rels/workbook.xml.rels",
                """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Relationships xmlns="\(relationships)"><Relationship Id="rId1" \
                Type="\(officeDocument)/worksheet" Target="worksheets/sheet1.xml"/></Relationships>
                """
            ),
            ("xl/worksheets/sheet1.xml", sheet),
        ]
        return ZipArchive.stored(files.map { ($0.0, Data($0.1.utf8)) })
    }

    /// A, B, … Z, AA, AB, …
    static func columnName(_ index: Int) -> String {
        var n = index + 1
        var name = ""
        while n > 0 {
            let remainder = (n - 1) % 26
            name = String(UnicodeScalar(UInt8(65 + remainder))) + name
            n = (n - 1) / 26
        }
        return name
    }

    /// Escapes XML and drops characters XML 1.0 cannot carry; Excel's cell limit is 32,767 characters.
    static func xmlText(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars.prefix(32_767) {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            case let s where s.value < 0x20 || (0xFFFE...0xFFFF).contains(s.value): continue
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

/// A ZIP archive with stored (uncompressed) entries: enough for XLSX, with no dependency.
enum ZipArchive {
    static func stored(_ entries: [(name: String, data: Data)]) -> Data {
        var archive = Data()
        var directory = Data()
        // 1980-01-01 00:00 in DOS format: the date is not meaningful for an export.
        let time: UInt16 = 0
        let date: UInt16 = (0 << 9) | (1 << 5) | 1
        for (name, data) in entries {
            let nameData = Data(name.utf8)
            let crc = crc32(data)
            let offset = UInt32(archive.count)
            archive.append(le32(0x0403_4B50))
            archive.append(le16(20)); archive.append(le16(0x0800)); archive.append(le16(0))
            archive.append(le16(time)); archive.append(le16(date))
            archive.append(le32(crc)); archive.append(le32(UInt32(data.count))); archive.append(le32(UInt32(data.count)))
            archive.append(le16(UInt16(nameData.count))); archive.append(le16(0))
            archive.append(nameData)
            archive.append(data)

            directory.append(le32(0x0201_4B50))
            directory.append(le16(20)); directory.append(le16(20)); directory.append(le16(0x0800)); directory.append(le16(0))
            directory.append(le16(time)); directory.append(le16(date))
            directory.append(le32(crc)); directory.append(le32(UInt32(data.count))); directory.append(le32(UInt32(data.count)))
            directory.append(le16(UInt16(nameData.count))); directory.append(le16(0)); directory.append(le16(0))
            directory.append(le16(0)); directory.append(le16(0)); directory.append(le32(0))
            directory.append(le32(offset))
            directory.append(nameData)
        }
        let directoryOffset = UInt32(archive.count)
        archive.append(directory)
        archive.append(le32(0x0605_4B50))
        archive.append(le16(0)); archive.append(le16(0))
        archive.append(le16(UInt16(entries.count))); archive.append(le16(UInt16(entries.count)))
        archive.append(le32(UInt32(directory.count))); archive.append(le32(directoryOffset))
        archive.append(le16(0))
        return archive
    }

    static func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    static func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

    static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
