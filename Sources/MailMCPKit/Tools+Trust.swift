import Foundation
import MCP
import MailStore

extension MailToolbox {
    var trustTools: [ToolDefinition] { [checkAuthenticity] }

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
}
