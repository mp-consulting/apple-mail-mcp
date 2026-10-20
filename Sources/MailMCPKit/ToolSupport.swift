import Foundation
import MCP
import MailStore

/// A bad or missing tool argument; reported back to the model verbatim.
public struct ToolError: Error, CustomStringConvertible, Sendable {
    public var description: String
    public init(_ description: String) { self.description = description }
}

/// Typed access to tool arguments, tolerant of the shapes models send
/// (numbers as strings, lists as comma-separated strings).
public struct Arguments: Sendable {
    public var values: [String: Value]

    public init(_ values: [String: Value]?) { self.values = values ?? [:] }

    public func has(_ key: String) -> Bool {
        if let value = values[key], value != .null { return true }
        return false
    }

    public func string(_ key: String) throws -> String? {
        switch values[key] {
        case nil, .null: return nil
        case .string(let s):
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return String(b)
        default: throw ToolError("\(key) must be a string")
        }
    }

    public func requiredString(_ key: String) throws -> String {
        guard let value = try string(key) else { throw ToolError("\(key) is required") }
        return value
    }

    public func int(_ key: String) throws -> Int? {
        switch values[key] {
        case nil, .null: return nil
        case .int(let i): return i
        case .double(let d):
            guard let i = Int(exactly: d) else { throw ToolError("\(key) must be an integer") }
            return i
        case .string(let s):
            guard let i = Int(s.trimmingCharacters(in: .whitespaces)) else { throw ToolError("\(key) must be an integer") }
            return i
        default: throw ToolError("\(key) must be an integer")
        }
    }

    /// An integer clamped to `range` (models send 0, negatives and huge counts); `fallback` when absent.
    public func int(_ key: String, default fallback: Int, in range: ClosedRange<Int>) throws -> Int {
        min(range.upperBound, max(range.lowerBound, try int(key) ?? fallback))
    }

    public func bool(_ key: String) throws -> Bool? {
        switch values[key] {
        case nil, .null: return nil
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .string(let s):
            switch s.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: throw ToolError("\(key) must be true or false")
            }
        default: throw ToolError("\(key) must be true or false")
        }
    }

    /// A list of strings; accepts an array or a comma/semicolon-separated string.
    public func strings(_ key: String) throws -> [String] {
        switch values[key] {
        case nil, .null: return []
        case .array(let items): return try items.map { item -> String in
            guard let s = item.stringValue ?? item.intValue.map(String.init) else { throw ToolError("\(key) must contain strings") }
            return s.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        case .string(let s):
            return s.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        default: throw ToolError("\(key) must be a list of strings")
        }
    }

    /// Message ids: an array of integers (or numeric strings), or a single id.
    public func ids(_ key: String) throws -> [Int64] {
        let raw: [Value]
        switch values[key] {
        case nil, .null: return []
        case .array(let items): raw = items
        case .int, .double: raw = [values[key]!]
        case .string(let s): raw = s.split(whereSeparator: { $0 == "," || $0 == " " }).map { .string(String($0)) }
        default: throw ToolError("\(key) must be a list of message ids")
        }
        var out: [Int64] = []
        for value in raw {
            switch value {
            case .int(let i): out.append(Int64(i))
            case .double(let d):
                guard let i = Int64(exactly: d) else { throw ToolError("invalid message id \(d)") }
                out.append(i)
            case .string(let s):
                guard let i = Int64(s.trimmingCharacters(in: .whitespaces)) else { throw ToolError("invalid message id \"\(s)\"") }
                out.append(i)
            default: throw ToolError("\(key) must contain integers")
            }
        }
        var seen = Set<Int64>()
        return out.filter { seen.insert($0).inserted }
    }

    /// Exactly one message id: a list would otherwise act on its first id alone, silently.
    public func id(_ key: String) throws -> Int64 {
        let ids = try ids(key)
        guard let id = ids.first else { throw ToolError("\(key) is required") }
        guard ids.count == 1 else { throw ToolError("\(key) takes one message id, not \(ids.count)") }
        return id
    }

    /// `YYYY-MM-DD` (start or end of that local day) or a full ISO 8601 timestamp.
    public func date(_ key: String, endOfDay: Bool = false) throws -> Date? {
        guard let text = try string(key)?.trimmingCharacters(in: .whitespaces) else { return nil }
        if text.count == 10 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            if let day = formatter.date(from: text) {
                return endOfDay ? day.addingTimeInterval(86_399) : day
            }
        }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        throw ToolError("\(key) must be YYYY-MM-DD or an ISO 8601 date")
    }
}

/// An ordered JSON value: keys keep insertion order so ids and subjects come first.
public indirect enum JSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([(String, JSON)])

    public static func == (lhs: JSON, rhs: JSON) -> Bool { lhs.serialized() == rhs.serialized() }

    public static func obj(_ pairs: [(String, JSON?)]) -> JSON {
        .object(pairs.compactMap { key, value in value.map { (key, $0) } })
    }

    public func serialized(pretty: Bool = false) -> String {
        if pretty { return reference(pretty: true) }
        // Tool output: UTF-8 bytes into one buffer, and strings that need no escaping copied whole. Appending scalar
        // by scalar to a String made writing a page of results take longer than finding them.
        return String(decoding: compactUTF8(), as: UTF8.self)
    }

    /// Compact output as UTF-8 bytes (see `serialized`).
    func compactUTF8() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(4096)
        writeCompact(into: &out)
        return out
    }

    /// The straightforward writer: pretty output, and what `serialized()` must equal (tests).
    func reference(pretty: Bool) -> String {
        var out = ""
        write(into: &out, pretty: pretty, indent: 0)
        return out
    }

    private func writeCompact(into out: inout [UInt8]) {
        switch self {
        case .null: out.append(contentsOf: "null".utf8)
        case .bool(let b): out.append(contentsOf: (b ? "true" : "false").utf8)
        case .int(let i): out.append(contentsOf: String(i).utf8)
        case .double(let d): out.append(contentsOf: (d.isFinite ? String(d) : "null").utf8)
        case .string(let s): JSON.escape(s, into: &out)
        case .array(let items):
            out.append(UInt8(ascii: "["))
            for (index, item) in items.enumerated() {
                if index > 0 { out.append(UInt8(ascii: ",")) }
                item.writeCompact(into: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let pairs):
            out.append(UInt8(ascii: "{"))
            for (index, (key, value)) in pairs.enumerated() {
                if index > 0 { out.append(UInt8(ascii: ",")) }
                JSON.escape(key, into: &out)
                out.append(UInt8(ascii: ":"))
                value.writeCompact(into: &out)
            }
            out.append(UInt8(ascii: "}"))
        }
    }

    private static func escape(_ text: String, into out: inout [UInt8]) {
        out.append(UInt8(ascii: "\""))
        var text = text
        text.withUTF8 { bytes in
            var start = 0
            for index in 0..<bytes.count {
                let byte = bytes[index]
                guard byte < 0x20 || byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "\\") else { continue }
                out.append(contentsOf: bytes[start..<index])
                switch byte {
                case UInt8(ascii: "\""): out.append(contentsOf: #"\""#.utf8)
                case UInt8(ascii: "\\"): out.append(contentsOf: #"\\"#.utf8)
                case 0x0A: out.append(contentsOf: #"\n"#.utf8)
                case 0x0D: out.append(contentsOf: #"\r"#.utf8)
                case 0x09: out.append(contentsOf: #"\t"#.utf8)
                default:
                    let hex = Array("0123456789abcdef".utf8)
                    out.append(contentsOf: #"\u00"#.utf8)
                    out.append(hex[Int(byte >> 4)])
                    out.append(hex[Int(byte & 0xF)])
                }
                start = index + 1
            }
            out.append(contentsOf: bytes[start...])
        }
        out.append(UInt8(ascii: "\""))
    }

    private func write(into out: inout String, pretty: Bool, indent: Int) {
        let newline = pretty ? "\n" : ""
        let pad = pretty ? String(repeating: "  ", count: indent + 1) : ""
        let closePad = pretty ? String(repeating: "  ", count: indent) : ""
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .double(let d): out += d.isFinite ? String(d) : "null"
        case .string(let s): JSON.escape(s, into: &out)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "[" + newline
            for (index, item) in items.enumerated() {
                out += pad
                item.write(into: &out, pretty: pretty, indent: indent + 1)
                if index < items.count - 1 { out += "," }
                out += newline
            }
            out += closePad + "]"
        case .object(let pairs):
            if pairs.isEmpty { out += "{}"; return }
            out += "{" + newline
            for (index, (key, value)) in pairs.enumerated() {
                out += pad
                JSON.escape(key, into: &out)
                out += pretty ? ": " : ":"
                value.write(into: &out, pretty: pretty, indent: indent + 1)
                if index < pairs.count - 1 { out += "," }
                out += newline
            }
            out += closePad + "}"
        }
    }

    private static func escape(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let c where c.value < 0x20:
                out += String(format: "\\u%04x", c.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }
}

/// Shared formatting of mail objects for tool output.
enum Render {
    // ISO8601DateFormatter is thread-safe for formatting.
    nonisolated(unsafe) static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(_ date: Date) -> JSON { .string(isoDate(date)) }

    /// `dateFormatter.string(from:)`, without the formatter: local time to the nearest second, then `Z` or `±hh:mm`.
    static func isoDate(_ date: Date) -> String {
        var time = time_t(date.timeIntervalSince1970.rounded())  // to the nearest second, as the formatter does
        var parts = tm()
        localtime_r(&time, &parts)
        var out: [UInt8] = []
        out.reserveCapacity(25)
        func digits(_ value: Int, _ count: Int) {
            var value = value
            var place = 1
            for _ in 1..<count { place *= 10 }
            while place > 0 {
                out.append(UInt8(ascii: "0") + UInt8(value / place % 10))
                value %= place
                place /= 10
            }
        }
        digits(Int(parts.tm_year) + 1900, 4)
        out.append(UInt8(ascii: "-"))
        digits(Int(parts.tm_mon) + 1, 2)
        out.append(UInt8(ascii: "-"))
        digits(Int(parts.tm_mday), 2)
        out.append(UInt8(ascii: "T"))
        digits(Int(parts.tm_hour), 2)
        out.append(UInt8(ascii: ":"))
        digits(Int(parts.tm_min), 2)
        out.append(UInt8(ascii: ":"))
        digits(Int(parts.tm_sec), 2)
        let offset = parts.tm_gmtoff
        if offset == 0 {
            out.append(UInt8(ascii: "Z"))
        } else {
            out.append(UInt8(ascii: offset < 0 ? "-" : "+"))
            digits(abs(offset) / 3600, 2)
            out.append(UInt8(ascii: ":"))
            digits(abs(offset) % 3600 / 60, 2)
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func truncate(_ text: String, _ limit: Int) -> String {
        guard limit > 0, text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }

    static func message(_ m: MessageSummary, preview: Bool = true, link: Bool = false) -> JSON {
        .obj([
            ("id", .int(m.id)),
            ("date", date(m.dateReceived)),
            ("from", .string(m.sender.formatted)),
            ("subject", .string(m.subject)),
            ("account", .string(m.accountName)),
            ("mailbox", .string(m.mailboxPath)),
            ("unread", m.isRead ? nil : .bool(true)),
            ("flag", m.flagColor.map { .string($0.name) }),
            ("attachments", m.hasAttachments ? .bool(true) : nil),
            ("category", m.category.flatMap { $0 == .primary ? nil : .string($0.name) }),
            ("preview", preview ? m.preview.map { .string(shortPreview($0, 200)) } : nil),
            ("link", link ? m.mailLink.map { .string($0) } : nil),
        ])
    }

    /// `truncate(cleanPreview(text), limit)` in one pass over the text, stopping once it has more than enough (Mail
    /// keeps snippets of a few KB, every search shows 200 characters). ASCII needs no Unicode lookups: none of it is
    /// an invisible format character. Should the window clean down to `limit` characters or fewer, the whole text
    /// is cleaned the slow way instead.
    static func shortPreview(_ text: String, _ limit: Int) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(limit + 8)
        var space = false
        var afterSpace = false  // the last scalar read was whitespace
        var written = 0  // scalars in `out`
        var ascii = true
        var complete = true
        for scalar in text.unicodeScalars {
            let isSpace: Bool
            if scalar.isASCII {
                isSpace = scalar.value == 32 || (9...13).contains(scalar.value)
            } else {
                if scalar.properties.generalCategory == .format || scalar == "\u{034F}" || scalar == "\u{00AD}" { continue }
                // A mark joins the character before it: after whitespace it is part of that whitespace.
                isSpace = scalar.properties.isWhitespace || afterSpace && scalar.properties.isGraphemeExtend
            }
            afterSpace = isSpace
            if isSpace {
                space = written > 0
                continue
            }
            if space {
                out.append(UInt8(ascii: " "))
                written += 1
                space = false
            }
            if scalar.isASCII {
                out.append(UInt8(scalar.value))
            } else {
                ascii = false
                UTF8.encode(scalar) { out.append($0) }
            }
            written += 1
            // ASCII so far: one scalar is one character, so `limit` + 1 of them settle the result (the last
            // one, being ASCII, cannot be joined to the one before it).
            if ascii && written > limit {
                return String(decoding: out.prefix(limit), as: UTF8.self) + "…"
            }
            if written > limit * 4 + 64 {
                complete = false
                break
            }
        }
        let cleaned = String(decoding: out, as: UTF8.self)
        if !complete && cleaned.count <= limit { return truncate(cleanPreview(text), limit) }
        return truncate(cleaned, limit)
    }

    /// Mail's snippet on one line, without the invisible padding some senders add (Stripe, newsletters):
    /// zero-width and other format characters, and runs of spaces.
    static func cleanPreview(_ text: String) -> String {
        let visible = String(String.UnicodeScalarView(text.unicodeScalars.filter {
            $0.properties.generalCategory != .format && $0 != "\u{034F}" && $0 != "\u{00AD}"
        }))
        return visible.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func addresses(_ list: [EmailAddress]) -> JSON? {
        list.isEmpty ? nil : .array(list.map { .string($0.formatted) })
    }
}

/// JSON Schema helpers for tool definitions.
enum Schema {
    static func object(_ properties: [String: Value], required: [String] = []) -> Value {
        var schema: [String: Value] = ["type": "object", "properties": .object(properties), "additionalProperties": false]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return .object(schema)
    }

    static func string(_ description: String, enum values: [String]? = nil) -> Value {
        var schema: [String: Value] = ["type": "string", "description": .string(description)]
        if let values { schema["enum"] = .array(values.map { .string($0) }) }
        return .object(schema)
    }

    static func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil) -> Value {
        var schema: [String: Value] = ["type": "integer", "description": .string(description)]
        if let minimum { schema["minimum"] = .int(minimum) }
        if let maximum { schema["maximum"] = .int(maximum) }
        return .object(schema)
    }

    static func boolean(_ description: String) -> Value {
        .object(["type": "boolean", "description": .string(description)])
    }

    static func strings(_ description: String) -> Value {
        .object(["type": "array", "items": ["type": "string"], "description": .string(description)])
    }

    static func ids(_ description: String) -> Value {
        .object(["type": "array", "items": ["type": "integer"], "minItems": 1, "description": .string(description)])
    }
}
