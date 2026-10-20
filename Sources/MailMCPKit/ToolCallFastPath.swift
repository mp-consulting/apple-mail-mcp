import Foundation
import MCP

/// `tools/call` answered straight from the stdio transport, for the most common request there is. The SDK's generic
/// path decodes every request into its `Value` type, running a data-URL regular expression over every string, and
/// was a third of a simple call's time. Here the line is parsed once with `JSONSerialization`, the tool runs exactly
/// as the SDK's handler would run it (`MailToolbox.call`), and the result is encoded with the SDK's own `Codable`.
/// Anything else, or a call this cannot read the way the SDK would, goes to the SDK unchanged.
enum ToolCallFastPath {
    struct Call: Sendable {
        /// The request id as JSON, echoed in the reply.
        var id: Data
        var name: String
        var arguments: [String: Value]?
    }

    /// The tool call in a JSON-RPC line; nil for anything else.
    static func call(in line: Data) -> Call? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
            object["jsonrpc"] as? String == "2.0", object["method"] as? String == "tools/call",
            let idJSON = idJSON(object["id"]),
            let params = object["params"] as? [String: Any], let name = params["name"] as? String
        else { return nil }
        guard let raw = params["arguments"], !(raw is NSNull) else { return Call(id: idJSON, name: name, arguments: nil) }
        guard let dictionary = raw as? [String: Any] else { return nil }
        var arguments: [String: Value] = [:]
        for (key, item) in dictionary {
            guard let value = value(item) else { return nil }
            arguments[key] = value
        }
        return Call(id: idJSON, name: name, arguments: arguments)
    }

    /// A request id (a string or a number) as JSON, the way replies and cancellations name it.
    private static func idJSON(_ id: Any?) -> Data? {
        guard let id, id is String || id is NSNumber else { return nil }
        return try? JSONSerialization.data(withJSONObject: id, options: .fragmentsAllowed)
    }

    /// Foundation's `JSONEncoder` (any Swift client) writes the slash escaped.
    private static let cancelledMethods = [Data("notifications/cancelled".utf8), Data(#"notifications\/cancelled"#.utf8)]

    /// The request id (as JSON, like ``Call/id``) of a `notifications/cancelled` line; nil for anything else.
    static func cancelledRequest(in line: Data) -> Data? {
        // Every line that is not a tool call comes here: parse only the rare one that can be a cancellation.
        guard cancelledMethods.contains(where: { line.range(of: $0) != nil }),
            let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
            object["method"] as? String == "notifications/cancelled",
            let params = object["params"] as? [String: Any]
        else { return nil }
        return idJSON(params["requestId"])
    }

    /// The SDK's `Value` for a parsed JSON value; nil where the SDK might decode it differently (a data URL).
    static func value(_ item: Any) -> Value? {
        switch item {
        case is NSNull:
            return .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return CFNumberIsFloatType(number) ? .double(number.doubleValue) : .int(number.intValue)
        case let text as String:
            return text.hasPrefix("data:") ? nil : .string(text)
        case let list as [Any]:
            var values: [Value] = []
            for element in list {
                guard let value = value(element) else { return nil }
                values.append(value)
            }
            return .array(values)
        case let dictionary as [String: Any]:
            var values: [String: Value] = [:]
            for (key, element) in dictionary {
                guard let value = value(element) else { return nil }
                values[key] = value
            }
            return .object(values)
        default:
            return nil
        }
    }

    /// The JSON-RPC reply for `call`, the result encoded as the SDK encodes it. Text results, which is what the
    /// tools return, go through `JSON`: `JSONEncoder` took longer over a 10 KB reply than the tool that made it.
    static func reply(to call: Call, result: CallTool.Result) throws -> Data {
        var reply = Data(#"{"jsonrpc":"2.0","id":"#.utf8)
        reply.append(call.id)
        reply.append(Data(#","result":"#.utf8))
        let texts = result.content.compactMap { content -> JSON? in
            guard case .text(let text, nil, nil) = content else { return nil }
            return .obj([("type", .string("text")), ("text", .string(text))])
        }
        if texts.count == result.content.count, result.structuredContent == nil, result._meta == nil {
            reply.append(contentsOf: JSON.obj([("content", .array(texts)), ("isError", result.isError.map(JSON.bool))]).compactUTF8())
        } else {
            reply.append(try JSONEncoder().encode(result))
        }
        reply.append(UInt8(ascii: "}"))
        return reply
    }
}
