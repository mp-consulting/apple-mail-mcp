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
        case .double(let d) where d.rounded() == d: return Int(d)
        case .string(let s):
            guard let i = Int(s.trimmingCharacters(in: .whitespaces)) else { throw ToolError("\(key) must be an integer") }
            return i
        default: throw ToolError("\(key) must be an integer")
        }
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
            case .double(let d) where d.rounded() == d: out.append(Int64(d))
            case .string(let s):
                guard let i = Int64(s.trimmingCharacters(in: .whitespaces)) else { throw ToolError("invalid message id \"\(s)\"") }
                out.append(i)
            default: throw ToolError("\(key) must contain integers")
            }
        }
        var seen = Set<Int64>()
        return out.filter { seen.insert($0).inserted }
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
        var out = ""
        write(into: &out, pretty: pretty, indent: 0)
        return out
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

    static func date(_ date: Date) -> JSON { .string(dateFormatter.string(from: date)) }

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
            ("preview", preview ? m.preview.map { .string(truncate(cleanPreview($0), 200)) } : nil),
            ("link", link ? m.mailLink.map { .string($0) } : nil),
        ])
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
