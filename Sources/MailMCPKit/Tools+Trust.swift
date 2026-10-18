import Foundation
import MCP
import MailStore

extension MailToolbox {
    var trustTools: [ToolDefinition] { [checkAuthenticity, findContact] }

    /// Domains the user corresponds with over the last year, for spotting look-alikes.
    func knownDomains() throws -> Set<String> {
        let store = try self.store
        var domains = Set(try store.topSenders(days: 365, byDomain: true, limit: 200).map(\.key))
        for address in try store.ownAddresses() { domains.insert(EmailAddress(address: address).domain) }
        domains.remove("")
        return domains
    }

    var checkAuthenticity: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "check_authenticity", "Check sender authenticity",
                """
                Whether messages really come from who they claim: SPF, DKIM and DMARC results, alignment with the \
                From domain, display names hiding another address, look-alike domains of people you write with, \
                Reply-To going elsewhere, first contact, and links whose text shows another site than they open. \
                verdict is pass, caution or fail; use it before trusting a link, an invoice or a payment request.
                """,
                Schema.object(["ids": Schema.ids("Message ids (up to 50)")], required: ["ids"]), kind: .read),
            kind: .read
        ) { arguments in
            let store = try self.store
            let ids = try arguments.ids("ids")
            guard !ids.isEmpty, ids.count <= 50 else { throw ToolError("ids must contain 1 to 50 message ids") }
            let known = try self.knownDomains()
            var items: [JSON] = []
            var failed = 0
            for id in ids {
                let detail: MessageDetail
                do { detail = try store.detail(id: id) } catch {
                    items.append(.obj([("id", .int(id)), ("error", .string("\(error)"))]))
                    continue
                }
                let sender = detail.summary.sender
                let report = Authenticity.check(
                    headers: detail.headers, from: sender, replyTo: detail.replyTo, html: detail.htmlBody, knownDomains: known,
                    priorMessagesFromSender: try? store.messageCount(fromAddress: sender.address, excluding: id))
                if report.verdict == .fail { failed += 1 }
                items.append(.obj([
                    ("id", .int(id)),
                    ("from", .string(sender.formatted)),
                    ("subject", .string(detail.summary.subject)),
                    ("verdict", .string(report.verdict.rawValue)),
                    ("spf", report.spf.map(JSON.string)),
                    ("dkim", report.dkim.map(JSON.string)),
                    ("dmarc", report.dmarc.map(JSON.string)),
                    ("signed_by", report.signedBy.isEmpty ? nil : .array(report.signedBy.map(JSON.string))),
                    ("aligned", report.aligned.map(JSON.bool)),
                    ("findings", report.findings.isEmpty ? nil : .array(report.findings.map { finding in
                        .obj([("code", .string(finding.code)), ("severity", .string(finding.severity.rawValue)), ("detail", .string(finding.detail))])
                    })),
                    ("note", detail.bodyAvailable ? nil : .string("Mail has not downloaded this message yet: headers and links could not be checked.")),
                ]))
            }
            return ToolReply(
                json: .obj([("messages", .array(items))]),
                summary: "\(items.count) checked, \(failed) failed", messageID: ids.count == 1 ? ids[0] : nil)
        }
    }

    var findContact: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "find_contact", "Find a contact",
                """
                Email addresses for a person or company: cards from Contacts (when this app may read them) and \
                the people you exchanged mail with, most-written-with first, with message counts. Use it to turn \
                "write to Anna" into an address before composing.
                """,
                Schema.object(
                    [
                        "query": Schema.string("Name, company or part of an address"),
                        "limit": Schema.integer("Results per source (default 10)", minimum: 1, maximum: 50),
                    ], required: ["query"]), kind: .read),
            kind: .read
        ) { arguments in
            let store = try self.store
            let query = try arguments.requiredString("query")
            guard query.trimmingCharacters(in: .whitespaces).count >= 2 else { throw ToolError("query needs at least 2 characters") }
            let limit = try arguments.int("limit", default: 10, in: 1...200)
            let history = try store.correspondents(matching: query, limit: limit)
            let lookup = await self.contacts.search(query, limit: limit)
            var cards: [JSON] = []
            var note: String?
            switch lookup {
            case .found(let found):
                cards = found.map { card in
                    .obj([
                        ("name", .string(card.name)),
                        ("organization", card.organization.map(JSON.string)),
                        ("emails", .array(card.emails.map { email in
                            .obj([("address", .string(email.address)), ("label", email.label.map(JSON.string))])
                        })),
                    ])
                }
            case .unavailable(let reason):
                note = reason
            }
            let people: [JSON] = history.map { person in
                .obj([
                    ("address", .string(person.address)),
                    ("name", person.name.map(JSON.string)),
                    ("received", person.received > 0 ? .int(Int64(person.received)) : nil),
                    ("sent", person.sent > 0 ? .int(Int64(person.sent)) : nil),
                    ("last_message", person.lastMessage.map(Render.date)),
                ])
            }
            return ToolReply(
                json: .obj([
                    ("contacts", cards.isEmpty ? nil : .array(cards)),
                    ("correspondents", .array(people)),
                    ("note", note.map(JSON.string)),
                ]),
                summary: "\(cards.count) contacts, \(people.count) correspondents")
        }
    }
}
