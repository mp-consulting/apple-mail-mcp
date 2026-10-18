import Foundation
import MCP
import MailAutomation
import MailStore

extension MailToolbox {
    var draftTools: [ToolDefinition] { [sendDraft, unsubscribe] }

    func draftMailboxes() throws -> [Mailbox] { try store.mailboxes().filter { $0.role == .drafts } }

    var listDrafts: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "list_drafts", "List drafts",
                "Unsent drafts in every account (or one), newest first, with their recipients.",
                Schema.object([
                    "account": Schema.string("Account name, id or address"),
                    "limit": Schema.integer("Maximum results (default 20)", minimum: 1, maximum: 200),
                ]), kind: .read),
            kind: .read
        ) { arguments in
            let store = try self.store
            let accountID = try self.resolveAccountID(arguments)
            var query = MessageQuery()
            query.mailboxIDs = try self.draftMailboxes().filter { accountID == nil || $0.accountID == accountID }.map(\.id)
            query.limit = try arguments.int("limit", default: 20, in: 1...200)
            guard !query.mailboxIDs.isEmpty else {
                return ToolReply(json: .obj([("drafts", .array([]))]), summary: "no Drafts mailbox")
            }
            let page = try store.search(query)
            let items: [JSON] = try page.messages.map { m in
                let (to, cc) = try store.recipients(of: m.id)
                return .obj([
                    ("id", .int(m.id)), ("date", Render.date(m.dateReceived)), ("subject", .string(m.subject)),
                    ("to", Render.addresses(to)), ("cc", Render.addresses(cc)), ("account", .string(m.accountName)),
                    ("attachments", m.hasAttachments ? .bool(true) : nil),
                    ("preview", m.preview.map { .string(Render.truncate(Render.cleanPreview($0), 200)) }),
                ])
            }
            return ToolReply(
                json: .obj([("total", page.total.map { .int(Int64($0)) }), ("drafts", .array(items))]),
                summary: "\(page.total ?? items.count) drafts")
        }
    }

    var sendDraft: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "send_draft", "Send a draft",
                """
                Send an unsent draft as it is: its recipients, subject, text or formatting, and attachments go out \
                in a new message (send policy applies), then the draft moves to Trash. Drafts that are replies \
                are refused, since a new message would lose the thread: open those in Mail with open_in_mail.
                """,
                Schema.object(["id": Schema.integer("Draft id (from list_drafts)")], required: ["id"]),
                kind: .compose, destructive: true, openWorld: true),
            kind: .compose
        ) { [automation] arguments in
            let store = try self.store
            guard let id = try arguments.ids("id").first else { throw ToolError("id is required") }
            let draft = try store.detail(id: id)
            guard let mailbox = try store.mailbox(id: draft.summary.mailboxID), mailbox.role == .drafts else {
                throw ToolError("Message \(id) is not in a Drafts mailbox.")
            }
            guard draft.bodyAvailable else { throw MailStoreError.bodyNotDownloaded(id) }
            func header(_ name: String) -> String? {
                draft.headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
            }
            if header("In-Reply-To") != nil || header("References") != nil {
                throw ToolError("Draft \(id) is a reply; sending it as a new message would break the thread. Open it in Mail (open_in_mail) and send it there.")
            }
            let to = draft.to.map(\.address), cc = draft.cc.map(\.address)
            let bcc = MIME.parseAddressList(header("Bcc")).map(\.address)
            guard !(to + cc + bcc).isEmpty else { throw ToolError("Draft \(id) has no recipients.") }
            let own = try store.ownAddresses()
            let from = own.contains(draft.summary.sender.address.lowercased()) ? draft.summary.sender.formatted : nil
            let body = draft.textBody ?? ""
            let files = try self.extractAttachments(of: id, draft.attachments.filter(\.isDownloaded))
            let missing = draft.attachments.count - files.count
            guard missing == 0 else {
                throw ToolError("\(missing) attachment(s) of draft \(id) are not on this Mac yet; open the draft in Mail instead.")
            }
            try await self.authorizeSend(
                tool: "send_draft", from: from, to: to, cc: cc, bcc: bcc, subject: draft.summary.subject, body: body, attachments: files)
            _ = try await automation.compose(
                OutgoingMessage(
                    from: from, to: to, cc: cc, bcc: bcc, subject: draft.summary.subject, body: body, html: draft.htmlBody,
                    attachments: files),
                mode: .send)
            // The message went out; the draft goes to Trash like Mail does after sending it.
            let trash = try store.mailboxes(accountID: mailbox.accountID).filter { $0.role == .trash }
            let report = try? await self.applyVerified([
                ChangeStep(source: mailbox, destination: trash.count == 1 ? trash[0] : nil, messages: [draft.summary], mustArrive: false)
            ]) { step in
                _ = try await automation.trash(ids: step.messages.map(\.id), in: MailboxTarget(step.source))
            }
            let removed = report?.done.contains(id) ?? false
            return ToolReply(
                json: .obj([
                    ("result", .string("sent")), ("to", .array(to.map(JSON.string))), ("subject", .string(draft.summary.subject)),
                    ("attachments", files.isEmpty ? nil : .int(Int64(files.count))),
                    ("draft_removed", .bool(removed)),
                    ("note", removed ? nil : .string("The draft is still in Drafts; delete it in Mail so it is not sent twice.")),
                ]),
                summary: "sent draft: \(Render.truncate(draft.summary.subject, 60))")
        }
    }
}
