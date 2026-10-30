import Foundation

/// Header fields of a MIME entity, unfolded, in original order.
public struct MIMEHeaders: Sendable {
    public var fields: [(name: String, value: String)]

    public init(fields: [(name: String, value: String)] = []) { self.fields = fields }

    /// Raw (undecoded) value of the first field named `name`, case-insensitive.
    public subscript(_ name: String) -> String? {
        fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public func all(_ name: String) -> [String] {
        fields.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    /// First field named `name` with RFC 2047 encoded-words decoded.
    public func decoded(_ name: String) -> String? { self[name].map(MIME.decodeEncodedWords) }
}

/// A parsed MIME entity. Leaf parts keep their still-encoded body bytes;
/// decoding happens on demand so listing attachments stays cheap.
public struct MIMEPart: Sendable {
    public var headers: MIMEHeaders
    /// IMAP section number (`1`, `2.1`, …), matching Mail's Attachments folder names.
    public var partID: String
    /// Lowercased `type/subtype`. Defaults to `text/plain`.
    public var contentType: String
    public var parameters: [String: String]
    public var children: [MIMEPart]
    /// Transfer-encoded body for leaf parts; empty for multiparts.
    public var rawBody: Data

    public var isMultipart: Bool { contentType.hasPrefix("multipart/") }

    public var transferEncoding: String {
        (headers["Content-Transfer-Encoding"] ?? "7bit").trimmingCharacters(in: .whitespaces).lowercased()
    }

    public var disposition: (type: String, parameters: [String: String])? {
        guard let value = headers["Content-Disposition"] else { return nil }
        let (type, parameters) = MIME.parseParameterizedValue(value)
        return (type.lowercased(), parameters)
    }

    public var filename: String? {
        if let name = disposition?.parameters["filename"], !name.isEmpty { return name }
        if let name = parameters["name"], !name.isEmpty { return name }
        return nil
    }

    /// Parts a mail client shows as attachments: explicit `attachment` disposition,
    /// or a named non-text part (inline images with a filename count too).
    public var isAttachment: Bool {
        guard !isMultipart else { return false }
        if disposition?.type == "attachment" { return true }
        if filename != nil, !contentType.hasPrefix("text/plain"), !contentType.hasPrefix("text/html") { return true }
        return false
    }

    /// Body with the transfer encoding removed.
    public func decodedBody() -> Data {
        switch transferEncoding {
        case "base64": return MIME.decodeBase64(rawBody)
        case "quoted-printable": return MIME.decodeQuotedPrintable(rawBody)
        default: return rawBody
        }
    }

    /// Decoded size without decoding: base64 is 3 bytes per 4 characters, less padding. Reading a message
    /// lists attachment sizes, and decoding a 25 MB attachment for that alone is wasted work.
    public var decodedSize: Int {
        switch transferEncoding {
        case "base64":
            var characters = 0
            var padding = 0
            for byte in rawBody {
                switch byte {
                case 0x0D, 0x0A, 0x20, 0x09: continue
                case UInt8(ascii: "="): padding += 1
                default: characters += 1
                }
            }
            return max(0, (characters + padding) / 4 * 3 - min(padding, 2))
        case "quoted-printable": return decodedBody().count
        default: return rawBody.count
        }
    }

    /// Body decoded to text using the part's charset.
    public func text() -> String {
        MIME.decodeText(decodedBody(), charset: parameters["charset"])
    }

    /// All leaf parts, depth first.
    public var leaves: [MIMEPart] {
        isMultipart ? children.flatMap(\.leaves) : [self]
    }

    /// True when the part's bytes are inside the message (not stripped into Mail's Attachments folder).
    public var hasInlineData: Bool {
        rawBody.contains { $0 != 0x0D && $0 != 0x0A && $0 != 0x20 && $0 != 0x09 }
    }

    /// Size Mail recorded for an attachment stripped from a `.partial.emlx`.
    public var appleContentLength: Int? {
        headers["X-Apple-Content-Length"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }
}

public enum MIME {
    // MARK: Parsing

    /// Parses an RFC 822 message.
    public static func parse(_ data: Data) -> MIMEPart {
        let bytes = [UInt8](data)
        return parseEntity(bytes[...], partID: "1", isTopLevel: true, depth: 0)
    }

    /// Real mail nests a few levels (mixed → alternative → related); a hostile message nests thousands to
    /// exhaust the stack and rescan the body at every level. Deeper parts are kept as opaque data.
    static let maxDepth = 16
    static let maxPartsPerMultipart = 500

    private static func parseEntity(_ bytes: ArraySlice<UInt8>, partID: String, isTopLevel: Bool, depth: Int) -> MIMEPart {
        let (headerBytes, body) = splitHeaders(bytes)
        let headers = parseHeaders(headerBytes)
        var contentType = "text/plain"
        var parameters: [String: String] = [:]
        if let value = headers["Content-Type"] {
            let parsed = parseParameterizedValue(value)
            let type = parsed.value.trimmingCharacters(in: .whitespaces).lowercased()
            if type.contains("/") { contentType = type }
            parameters = parsed.parameters
        }
        var part = MIMEPart(
            headers: headers, partID: partID, contentType: contentType, parameters: parameters,
            children: [], rawBody: Data())
        if contentType.hasPrefix("multipart/"), let boundary = parameters["boundary"], !boundary.isEmpty, depth < maxDepth {
            let pieces = splitMultipart(body, boundary: boundary).prefix(maxPartsPerMultipart)
            // IMAP numbering: children of the top-level multipart are 1, 2, …;
            // children of a nested multipart at section N are N.1, N.2, ….
            part.children = pieces.enumerated().map { index, piece in
                let childID = isTopLevel ? "\(index + 1)" : "\(partID).\(index + 1)"
                return parseEntity(piece, partID: childID, isTopLevel: false, depth: depth + 1)
            }
        } else {
            part.rawBody = Data(body)
        }
        return part
    }

    /// Splits at the first empty line (CRLF or LF).
    static func splitHeaders(_ bytes: ArraySlice<UInt8>) -> (ArraySlice<UInt8>, ArraySlice<UInt8>) {
        var i = bytes.startIndex
        // A body with no headers starts with an empty line.
        if i < bytes.endIndex, bytes[i] == 0x0A { return (bytes[i..<i], bytes[(i + 1)...]) }
        if i + 1 < bytes.endIndex, bytes[i] == 0x0D, bytes[i + 1] == 0x0A { return (bytes[i..<i], bytes[(i + 2)...]) }
        while i < bytes.endIndex {
            if bytes[i] == 0x0A {
                let next = i + 1
                if next < bytes.endIndex, bytes[next] == 0x0A {
                    return (bytes[bytes.startIndex..<i], bytes[(next + 1)...])
                }
                if next + 1 < bytes.endIndex, bytes[next] == 0x0D, bytes[next + 1] == 0x0A {
                    return (bytes[bytes.startIndex..<i], bytes[(next + 2)...])
                }
            }
            i += 1
        }
        return (bytes, bytes[bytes.endIndex...])
    }

    static func parseHeaders(_ bytes: ArraySlice<UInt8>) -> MIMEHeaders {
        var fields: [(String, String)] = []
        var lineStart = bytes.startIndex
        var name: ArraySlice<UInt8>?
        var value: [UInt8] = []

        func flush() {
            guard let current = name else { return }
            let field = decodeHeaderBytes(current[...]).trimmingCharacters(in: .whitespaces)
            let text = decodeHeaderBytes(value[...]).trimmingCharacters(in: .whitespaces)
            fields.append((field, text))
            name = nil
            value.removeAll(keepingCapacity: true)
        }

        while lineStart < bytes.endIndex {
            var lineEnd = lineStart
            while lineEnd < bytes.endIndex, bytes[lineEnd] != 0x0A { lineEnd += 1 }
            var contentEnd = lineEnd
            if contentEnd > lineStart, bytes[contentEnd - 1] == 0x0D { contentEnd -= 1 }
            let line = bytes[lineStart..<contentEnd]
            if let first = line.first, first == 0x20 || first == 0x09 {
                // Folded continuation of the previous field.
                if name != nil {
                    var start = line.startIndex
                    while start < line.endIndex, line[start] == 0x20 || line[start] == 0x09 { start += 1 }
                    value.append(0x20)
                    value += line[start...]
                }
            } else {
                flush()
                if let colon = line.firstIndex(of: 0x3A) {
                    name = line[line.startIndex..<colon]
                    value += line[(colon + 1)...]
                }
            }
            lineStart = lineEnd + 1
        }
        flush()
        return MIMEHeaders(fields: fields)
    }

    private static func decodeHeaderBytes(_ bytes: ArraySlice<UInt8>) -> String {
        // Raw 8-bit headers are usually UTF-8; Latin-1 decodes any byte sequence.
        String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) ?? ""
    }

    /// Splits a multipart body on `--boundary` delimiter lines, dropping preamble and epilogue.
    static func splitMultipart(_ body: ArraySlice<UInt8>, boundary: String) -> [ArraySlice<UInt8>] {
        let delimiter = Array("--\(boundary)".utf8)
        var parts: [ArraySlice<UInt8>] = []
        var partStart: Int?
        var lineStart = body.startIndex
        while lineStart < body.endIndex {
            var lineEnd = lineStart
            while lineEnd < body.endIndex, body[lineEnd] != 0x0A { lineEnd += 1 }
            let after = lineStart + delimiter.count
            if lineEnd - lineStart >= delimiter.count,
               body[lineStart..<after].elementsEqual(delimiter),
               after == lineEnd || [0x0D, 0x20, 0x09, 0x2D].contains(body[after])
            {
                let isClose = after + 1 < lineEnd && body[after] == 0x2D && body[after + 1] == 0x2D
                if let start = partStart {
                    // The CRLF before the delimiter belongs to the delimiter.
                    var end = lineStart
                    if end > start, body[end - 1] == 0x0A { end -= 1 }
                    if end > start, body[end - 1] == 0x0D { end -= 1 }
                    parts.append(body[start..<max(start, end)])
                }
                if isClose { return parts }
                partStart = lineEnd < body.endIndex ? lineEnd + 1 : body.endIndex
            }
            lineStart = lineEnd + 1
        }
        // Unterminated multipart: keep what we have.
        if let start = partStart, start < body.endIndex { parts.append(body[start...]) }
        return parts
    }

    // MARK: Parameters (RFC 2045 + RFC 2231)

    /// Splits `type/subtype; a=b; c="d"` into the value and lowercased parameter names.
    public static func parseParameterizedValue(_ value: String) -> (value: String, parameters: [String: String]) {
        let segments = splitOutsideQuotes(value, separator: ";")
        guard let first = segments.first else { return ("", [:]) }
        var simple: [String: String] = [:]
        var extended: [String: [(index: Int, encoded: Bool, value: String)]] = [:]
        for segment in segments.dropFirst() {
            guard let eq = segment.firstIndex(of: "=") else { continue }
            var name = segment[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var raw = segment[segment.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 {
                raw = String(raw.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
            }
            // RFC 2231: name*=charset'lang'value, name*0=..., name*1*=...
            if let star = name.firstIndex(of: "*") {
                let base = String(name[..<star])
                let suffix = name[name.index(after: star)...]
                let encoded = suffix.hasSuffix("*") || suffix.isEmpty
                let indexText = suffix.hasSuffix("*") ? suffix.dropLast() : suffix
                let index = Int(indexText) ?? 0
                extended[base, default: []].append((index, encoded, raw))
                name = base
                continue
            }
            simple[name] = decodeEncodedWords(raw)
        }
        for (name, pieces) in extended {
            var charset = "utf-8"
            var combined = Data()
            for (offset, piece) in pieces.sorted(by: { $0.index < $1.index }).enumerated() {
                var text = piece.value
                if piece.encoded {
                    if offset == 0 {
                        let quoteParts = text.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                        if quoteParts.count == 3 {
                            if !quoteParts[0].isEmpty { charset = String(quoteParts[0]) }
                            text = String(quoteParts[2])
                        }
                    }
                    combined.append(percentDecode(text))
                } else {
                    combined.append(contentsOf: Array(text.utf8))
                }
            }
            simple[name] = decodeText(combined, charset: charset)
        }
        return (first.trimmingCharacters(in: .whitespaces), simple)
    }

    private static func splitOutsideQuotes(_ text: String, separator: Character) -> [String] {
        var out: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for character in text {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\" && inQuotes {
                current.append(character)
                escaped = true
                continue
            }
            if character == "\"" { inQuotes.toggle() }
            if character == separator && !inQuotes {
                out.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        out.append(current)
        return out
    }

    private static func percentDecode(_ text: String) -> Data {
        var out = Data()
        let bytes = Array(text.utf8)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x25, i + 2 < bytes.count, let byte = hexByte(bytes[i + 1], bytes[i + 2]) {
                out.append(byte)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return out
    }

    // MARK: Transfer encodings

    public static func decodeBase64(_ data: Data) -> Data {
        if let decoded = Data(base64Encoded: data, options: .ignoreUnknownCharacters) { return decoded }
        // Tolerate missing padding.
        var filtered = data.filter { byte in
            (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39)
                || byte == 0x2B || byte == 0x2F
        }
        while filtered.count % 4 != 0 { filtered.append(0x3D) }
        return Data(base64Encoded: filtered) ?? Data()
    }

    public static func decodeQuotedPrintable(_ data: Data) -> Data {
        data.withUnsafeBytes { raw -> Data in
            let bytes = raw.bindMemory(to: UInt8.self)
            let n = bytes.count
            var out = [UInt8]()
            out.reserveCapacity(n)
            var i = 0
            while i < n {
                let byte = bytes[i]
                if byte == 0x3D {
                    // Soft line break: "=\r\n" or "=\n" (trailing whitespace before the break is allowed).
                    var j = i + 1
                    while j < n, bytes[j] == 0x20 || bytes[j] == 0x09 { j += 1 }
                    if j < n, bytes[j] == 0x0A { i = j + 1; continue }
                    if j + 1 < n, bytes[j] == 0x0D, bytes[j + 1] == 0x0A { i = j + 2; continue }
                    if i + 2 < n, let decoded = hexByte(bytes[i + 1], bytes[i + 2]) {
                        out.append(decoded)
                        i += 3
                        continue
                    }
                }
                out.append(byte)
                i += 1
            }
            return Data(out)
        }
    }

    private static func hexByte(_ high: UInt8, _ low: UInt8) -> UInt8? {
        func value(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: c - 0x30
            case 0x41...0x46: c - 0x41 + 10
            case 0x61...0x66: c - 0x61 + 10
            default: nil
            }
        }
        guard let h = value(high), let l = value(low) else { return nil }
        return h << 4 | l
    }

    // MARK: Charsets

    public static func stringEncoding(forCharset charset: String) -> String.Encoding? {
        let name = charset.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\""))).lowercased()
        switch name {
        case "utf-8", "utf8": return .utf8
        case "us-ascii", "ascii": return .utf8  // ASCII is a UTF-8 subset; tolerate stray 8-bit bytes below.
        case "iso-8859-1", "latin1", "latin-1": return .isoLatin1
        case "windows-1252", "cp1252": return .windowsCP1252
        default:
            #if canImport(Darwin)
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            guard cf != kCFStringEncodingInvalidId else { return nil }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
            #else
            // No CoreFoundation charset table on Linux: the common ones Foundation decodes there.
            switch name {
            case "utf-16": return .utf16
            case "iso-8859-2", "latin2": return .isoLatin2
            case "windows-1250", "cp1250": return .windowsCP1250
            case "windows-1251", "cp1251": return .windowsCP1251
            case "shift_jis", "shift-jis", "sjis": return .shiftJIS
            case "euc-jp": return .japaneseEUC
            case "iso-2022-jp": return .iso2022JP
            default: return nil
            }
            #endif
        }
    }

    /// Decodes bytes in `charset`, falling back to UTF-8, then Windows-1252.
    public static func decodeText(_ data: Data, charset: String?) -> String {
        if let charset, let encoding = stringEncoding(forCharset: charset), let text = String(data: data, encoding: encoding) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .windowsCP1252) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: RFC 2047

    /// Decodes `=?charset?B?…?=` / `=?charset?Q?…?=` words. Whitespace between
    /// adjacent encoded words is dropped, as the RFC requires.
    public static func decodeEncodedWords(_ text: String) -> String {
        guard text.contains("=?") else { return text }
        var result = ""
        var remaining = Substring(text)
        var lastWasEncoded = false
        var pendingWhitespace = ""
        while let start = firstRange(of: "=", "?", in: remaining) {
            let before = remaining[..<start.lowerBound]
            let afterStart = remaining[start.upperBound...]
            guard let word = parseEncodedWord(afterStart) else {
                result += pendingWhitespace + before + "=?"
                pendingWhitespace = ""
                remaining = afterStart
                lastWasEncoded = false
                continue
            }
            if lastWasEncoded && before.allSatisfy(\.isWhitespace) {
                // Drop whitespace between two encoded words.
            } else {
                result += pendingWhitespace + before
            }
            pendingWhitespace = ""
            result += word.decoded
            remaining = word.rest
            lastWasEncoded = true
        }
        result += pendingWhitespace + remaining
        return result
    }

    /// The first `a` immediately followed by `b`. Linear and Foundation-free: `Substring.range(of:)` bridges
    /// the whole remaining text on every call, which made long headers quadratic.
    private static func firstRange(of a: Character, _ b: Character, in text: Substring) -> Range<Substring.Index>? {
        var from = text.startIndex
        while let found = text[from...].firstIndex(of: a) {
            let next = text.index(after: found)
            if next < text.endIndex, text[next] == b { return found..<text.index(after: next) }
            from = next
        }
        return nil
    }

    private static func parseEncodedWord(_ text: Substring) -> (decoded: String, rest: Substring)? {
        // charset?encoding?payload?=. Each search is bounded: an unterminated "=?" must not scan the rest of a
        // long header, once per "=?" (RFC 2047 caps an encoded word at 75 characters; mailers exceed it a little).
        guard let q1 = text.prefix(80).firstIndex(of: "?") else { return nil }
        let charsetPart = text[..<q1]
        let afterCharset = text[text.index(after: q1)...]
        guard let q2 = afterCharset.prefix(3).firstIndex(of: "?") else { return nil }
        let encoding = afterCharset[..<q2].uppercased()
        let afterEncoding = afterCharset[afterCharset.index(after: q2)...]
        // An encoded word holds no whitespace, so the search for its end stops at the first space.
        let word = afterEncoding.prefix(2000).prefix { !$0.isWhitespace }
        guard let end = firstRange(of: "?", "=", in: word) else { return nil }
        let payload = afterEncoding[..<end.lowerBound]
        guard !charsetPart.isEmpty, !charsetPart.contains(where: \.isWhitespace), !payload.contains(" ") else { return nil }
        // RFC 2231 language suffix: charset*lang.
        let charset = charsetPart.split(separator: "*").first.map(String.init) ?? String(charsetPart)
        let data: Data
        switch encoding {
        case "B": data = decodeBase64(Data(payload.utf8))
        case "Q":
            let underscored = payload.replacingOccurrences(of: "_", with: " ")
            data = decodeQuotedPrintable(Data(underscored.utf8))
        default: return nil
        }
        return (decodeText(data, charset: charset), afterEncoding[end.upperBound...])
    }

    // MARK: Addresses

    /// Parses an address-list header (`"Doe, Jane" <jane@x.com>, bob@y.com`).
    public static func parseAddressList(_ value: String?) -> [EmailAddress] {
        guard let value, !value.isEmpty else { return [] }
        var out: [EmailAddress] = []
        for entry in splitAddresses(value) {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let open = trimmed.lastIndex(of: "<"), let close = trimmed.lastIndex(of: ">"), open < close {
                let address = trimmed[trimmed.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
                var name = trimmed[..<open].trimmingCharacters(in: .whitespaces)
                if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 { name = String(name.dropFirst().dropLast()) }
                name = name.replacingOccurrences(of: "\\\"", with: "\"")
                out.append(EmailAddress(address: address, name: decodeEncodedWords(name)))
            } else {
                // bare address, possibly with a trailing (comment)
                var address = trimmed
                var name: String?
                if let paren = trimmed.firstIndex(of: "("), let closeParen = trimmed.lastIndex(of: ")"), paren < closeParen {
                    name = String(trimmed[trimmed.index(after: paren)..<closeParen])
                    address = trimmed[..<paren].trimmingCharacters(in: .whitespaces)
                }
                guard address.contains("@") else { continue }
                out.append(EmailAddress(address: address, name: name.map(decodeEncodedWords)))
            }
        }
        return out
    }

    private static func splitAddresses(_ value: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var angleDepth = 0
        var parenDepth = 0
        var previous: Character?
        for character in value {
            switch character {
            case "\"" where previous != "\\": inQuotes.toggle()
            case "<" where !inQuotes: angleDepth += 1
            case ">" where !inQuotes: angleDepth = max(0, angleDepth - 1)
            case "(" where !inQuotes: parenDepth += 1
            case ")" where !inQuotes: parenDepth = max(0, parenDepth - 1)
            default: break
            }
            if (character == "," || character == ";") && !inQuotes && angleDepth == 0 && parenDepth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
            previous = character
        }
        parts.append(current)
        return parts
    }
}
