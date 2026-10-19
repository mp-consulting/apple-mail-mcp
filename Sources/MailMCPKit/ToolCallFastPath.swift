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
        // Cheap test first: most other lines are never parsed here.
        guard line.range(of: Data("tools/call".utf8)) != nil,
            let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
            object["jsonrpc"] as? String == "2.0", object["method"] as? String == "tools/call",
            let id = object["id"], id is String || id is NSNumber,
            let idJSON = try? JSONSerialization.data(withJSONObject: id, options: .fragmentsAllowed),
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

    /// The JSON-RPC reply for `call`, the result encoded as the SDK encodes it.
    static func reply(to call: Call, result: CallTool.Result) throws -> Data {
        var reply = Data(#"{"jsonrpc":"2.0","id":"#.utf8)
        reply.append(call.id)
        reply.append(Data(#","result":"#.utf8))
        reply.append(try JSONEncoder().encode(result))
        reply.append(UInt8(ascii: "}"))
        return reply
    }
}
