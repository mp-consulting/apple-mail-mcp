import Foundation
import MCP
import MailStore

extension MailToolbox {
    static func criterionJSON(_ c: MailCriterion) -> JSON {
        .obj([
            ("field", .string(c.field)),
            ("qualifier", c.field == "Compound" || c.value == nil ? nil : .string(c.qualifier)),
            ("value", c.value.map(JSON.string)),
            ("match", c.children.isEmpty ? nil : .string(c.allMustMatch ? "all" : "any")),
            ("criteria", c.children.isEmpty ? nil : .array(c.children.map(criterionJSON))),
        ])
    }

    static func smartMailboxJSON(_ box: SmartMailbox) -> JSON {
        .obj([
            ("name", .string(box.name)),
            ("match", box.criteria.isEmpty ? nil : .string(box.allMustMatch ? "all" : "any")),
            ("criteria", box.criteria.isEmpty ? nil : .array(box.criteria.map(criterionJSON))),
            ("children", box.children.isEmpty ? nil : .array(box.children.map(smartMailboxJSON))),
        ])
    }

    var mailSetup: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "mail_setup", "Rules, VIPs, smart mailboxes, signatures",
                """
                How Mail is set up, read from its settings files: rules (conditions and actions), VIP senders, smart \
                mailboxes (their conditions), and signatures (with their text when the file is on this Mac). Read-only: \
                change these in Mail › Settings.
                """,
                Schema.object([
                    "include": .object([
                        "type": "array", "items": ["type": "string", "enum": ["rules", "vips", "smart_mailboxes", "signatures"]],
                        "description": "Sections to return (default all)",
                    ])
                ]), kind: .read),
            kind: .read
        ) { arguments in
            let store = try self.store
            let sections = ["rules", "vips", "smart_mailboxes", "signatures"]
            var wanted = Set(try arguments.strings("include").map { $0.lowercased() })
            if let unknown = wanted.first(where: { !sections.contains($0) }) {
                throw ToolError("unknown section \(unknown); use \(sections.joined(separator: ", "))")
            }
            if wanted.isEmpty { wanted = Set(sections) }
            let rules = wanted.contains("rules") ? store.rules() : nil
            let vips = wanted.contains("vips") ? store.vips() : nil
            let smart = wanted.contains("smart_mailboxes") ? store.smartMailboxes() : nil
            let signatures = wanted.contains("signatures") ? store.signatures() : nil
            let json = JSON.obj([
                ("rules", rules.map { list in
                    .array(list.map { rule in
                        .obj([
                            ("name", .string(rule.name)),
                            ("enabled", rule.enabled.map(JSON.bool)),
                            ("match", .string(rule.allMustMatch ? "all" : "any")),
                            ("criteria", .array(rule.criteria.map(Self.criterionJSON))),
                            ("actions", .array(rule.actions.map(JSON.string))),
                        ])
                    })
                }),
                ("vips", vips.map { list in
                    .array(list.map { vip in
                        .obj([("name", vip.name.isEmpty ? nil : .string(vip.name)), ("addresses", .array(vip.addresses.map(JSON.string)))])
                    })
                }),
                ("smart_mailboxes", smart.map { .array($0.map(Self.smartMailboxJSON)) }),
                ("signatures", signatures.map { list in
                    .array(list.map { signature in
                        .obj([
                            ("name", .string(signature.name)),
                            ("rich", signature.isRich ? .bool(true) : nil),
                            ("text", signature.text.map { .string(Render.truncate($0, 2000)) }),
                        ])
                    })
                }),
            ])
            let counts = [("rules", rules?.count), ("VIPs", vips?.count), ("smart mailboxes", smart?.count), ("signatures", signatures?.count)]
                .compactMap { name, count in count.map { "\($0) \(name)" } }
            return ToolReply(json: json, summary: counts.joined(separator: ", "))
        }
    }
}
