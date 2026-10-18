import Foundation
import MCP
import MailStore

extension MailToolbox {
    var extractFields: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "extract_fields", "Extract codes, tracking and bookings",
                """
                Values to act on, read from message bodies: parcel tracking numbers with the carrier, verification \
                codes, booking and order references, flight numbers with the route, and calendar invitations \
                (title, start, end, location, organizer, from .ics parts). Pass ids, or the search_messages filters \
                (newest matches first). Only messages where something was found are listed.
                """,
                Schema.object(
                    Self.filterSchema.merging([
                        "ids": Schema.ids("Message ids (up to 200); omit to use the filters"),
                        "kinds": .object([
                            "type": "array", "items": ["type": "string", "enum": .array(ExtractedField.Kind.allCases.map { .string($0.rawValue) })],
                            "description": "What to look for (default all): tracking, code, booking, flight, event",
                        ]),
                        "limit": Schema.integer("With filters: how many matches (default 30, max 200)", minimum: 1, maximum: 200),
                    ]) { a, _ in a }), kind: .read),
            kind: .read
        ) { arguments in
            let store = try self.store
            let kinds = try Set(arguments.strings("kinds").map { name -> ExtractedField.Kind in
                guard let kind = ExtractedField.Kind(rawValue: name.lowercased()) else {
                    throw ToolError("unknown kind \(name); use \(ExtractedField.Kind.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                return kind
            })
            var ids = try arguments.ids("ids")
            if ids.isEmpty {
                var query = try self.messageQuery(arguments)
                query.limit = min(200, max(1, try arguments.int("limit") ?? 30))
                ids = try store.search(query, bodyIndex: self.searchIndex(for: query).index).messages.map(\.id)
            }
            guard ids.count <= 200 else { throw ToolError("ids must contain at most 200 message ids") }
            let messages = try store.messages(ids: ids)
            let found = try store.extractedFields(for: messages, kinds: kinds.isEmpty ? Set(ExtractedField.Kind.allCases) : kinds)
            let items: [JSON] = messages.compactMap { m in
                guard let fields = found[m.id], !fields.isEmpty else { return nil }
                return .obj([
                    ("id", .int(m.id)),
                    ("date", Render.date(m.dateReceived)),
                    ("from", .string(m.sender.formatted)),
                    ("subject", .string(m.subject)),
                    ("fields", .array(fields.map { field in
                        .obj([("kind", .string(field.kind.rawValue)), ("value", .string(field.value))]
                            + field.details.sorted { $0.key < $1.key }.map { ($0.key, .string($0.value)) })
                    })),
                    ("link", m.mailLink.map(JSON.string)),
                ])
            }
            return ToolReply(
                json: .obj([("searched", .int(Int64(messages.count))), ("with_fields", .int(Int64(items.count))), ("messages", .array(items))]),
                summary: "fields in \(items.count) of \(messages.count)", messageID: ids.count == 1 ? ids[0] : nil)
        }
    }
}
