import AppKit
import Foundation
import MCP
import MailAutomation
import MailStore

extension MailToolbox {
    var composeTools: [ToolDefinition] { [composeEmail, replyToMessage, forwardMessage, openInMail] }

    static let modeSchema = Schema.string(
        "draft (default): save to Drafts · open: leave a compose window for the user · send: deliver now",
        enum: DeliveryMode.allCases.map(\.rawValue))

    func validatedAttachments(_ arguments: Arguments) throws -> [String] {
        let guardian = pathGuard
        return try arguments.strings("attachments").map { try guardian.checkAttachment($0) }
    }

    func validatedSender(_ arguments: Arguments) throws -> String? {
        guard let from = try arguments.string("from") else { return nil }
        let own = try store.ownAddresses()
        let address = MIME.parseAddressList(from).first?.address.lowercased() ?? from.lowercased()
        if !own.isEmpty, !own.contains(address) {
            throw ToolError("from must be one of your addresses: \(own.sorted().joined(separator: ", "))")
        }
        return from
    }

    /// Replying to or forwarding an unsent draft can hang Mail; it is not something Mail's UI allows either.
    static func refuseDrafts(_ mailbox: Mailbox, id: Int64) throws {
        if mailbox.role == .drafts || mailbox.role == .outbox {
            throw ToolError("Message \(id) is an unsent draft. Open it in Mail (open_in_mail) or compose a new message instead.")
        }
    }

    /// After a draft save: waits for the draft to land in Mail's database, then closes the
    /// compose object. Returns the draft's message id, or nil if Mail is still saving.
    /// `after` is the highest ROWID before composing: Mail's ROWIDs only grow, so only a newer
    /// row can be this draft (an older one could be a previous attempt that finished late).
    func settleDraft(_ handle: ComposeHandle?, subject: String, after: Int64) async -> Int64? {
        guard let handle else { return nil }
        let drafts = ((try? store.mailboxes()) ?? []).filter { $0.role == .drafts }.map(\.id)
        var query = MessageQuery()
        query.mailboxIDs = drafts
        query.limit = 20
        var found: Int64?
        for _ in 0..<50 where !drafts.isEmpty {
            if let page = try? store.search(query),
               let match = page.messages.first(where: { $0.id > after && $0.subject == subject })
            {
                found = match.id
                break
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        if found != nil { try? await automation.closeCompose(handle) }
        return found
    }

    func draftResult(_ mode: DeliveryMode, draftID: Int64?) -> [(String, JSON?)] {
        guard mode == .draft else { return [("result", .string(describe(mode)))] }
        if let draftID { return [("result", .string(describe(mode))), ("draft_id", .int(draftID))] }
        return [("result", .string("saving to Drafts; Mail has not finished yet, so its compose window stays open"))]
    }

    func describe(_ mode: DeliveryMode) -> String {
        switch mode {
        case .draft: "saved to Drafts"
        case .open: "opened in Mail for review"
        case .send: "sent"
        }
    }

    var composeEmail: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "compose_email", "Compose email",
                "Write a new email as plain text. Saved as a draft unless mode says otherwise.",
                Schema.object(
                    [
                        "to": Schema.strings("Recipient addresses"),
                        "cc": Schema.strings("Cc addresses"),
                        "bcc": Schema.strings("Bcc addresses"),
                        "subject": Schema.string("Subject"),
                        "body": Schema.string("Plain-text body"),
                        "from": Schema.string("Send from this address (one of yours; default: Mail's default)"),
                        "attachments": Schema.strings("Absolute paths of files to attach"),
                        "mode": Self.modeSchema,
                    ], required: ["to", "subject", "body"]), kind: .compose, openWorld: true),
            kind: .compose
        ) { [automation] arguments in
            let to = try arguments.strings("to")
            let cc = try arguments.strings("cc")
            let bcc = try arguments.strings("bcc")
            guard !to.isEmpty || !cc.isEmpty || !bcc.isEmpty else { throw ToolError("to is required") }
            try Self.validateAddresses(to, field: "to")
            try Self.validateAddresses(cc, field: "cc")
            try Self.validateAddresses(bcc, field: "bcc")
            let subject = try arguments.string("subject") ?? ""
            let body = try arguments.string("body") ?? ""
            let mode = try Self.mode(arguments)
            let from = try self.validatedSender(arguments)
            let attachments = try self.validatedAttachments(arguments)
            if mode == .send {
                try await self.authorizeSend(
                    tool: "compose_email", from: from, to: to, cc: cc, bcc: bcc, subject: subject, body: body,
                    attachments: attachments)
            }
            let started = (try? self.store.maxMessageRowID()) ?? .max
            let handle = try await automation.compose(
                OutgoingMessage(from: from, to: to, cc: cc, bcc: bcc, subject: subject, body: body, attachments: attachments),
                mode: mode)
            let draftID = mode == .draft ? await self.settleDraft(handle, subject: subject, after: started) : nil
            return ToolReply(
                json: .obj(self.draftResult(mode, draftID: draftID) + [("to", .array(to.map { .string($0) })), ("subject", .string(subject))]),
                summary: "\(mode.rawValue): \(Render.truncate(subject, 60))")
        }
    }

    /// The reply body with a plain-text quote of the original below it.
    static func quotedReply(body: String, original: MessageDetail) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let attribution = "On \(formatter.string(from: original.summary.dateReceived)), \(original.summary.sender.formatted) wrote:"
        let originalText = Render.truncate(original.textBody ?? original.summary.preview ?? "", 20_000)
        let quoted = originalText.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? ">" : "> \($0)" }.joined(separator: "\n")
        return body + "\n\n" + attribution + "\n" + quoted + "\n"
    }

    var replyToMessage: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "reply_to_message", "Reply",
                """
                Reply (or reply all) to a message. Mail keeps the threading headers; the body is plain text with \
                the original quoted below it. Saved as a draft unless mode says otherwise.
                """,
                Schema.object(
                    [
                        "id": Schema.integer("Message id to reply to"),
                        "body": Schema.string("Your reply (plain text)"),
                        "reply_all": Schema.boolean("Reply to all recipients (default false)"),
                        "cc": Schema.strings("Additional Cc addresses"),
                        "bcc": Schema.strings("Bcc addresses"),
                        "attachments": Schema.strings("Absolute paths of files to attach"),
                        "quote_original": Schema.boolean("Quote the original message below the reply (default true)"),
                        "mode": Self.modeSchema,
                    ], required: ["id", "body"]), kind: .compose, openWorld: true),
            kind: .compose
        ) { [store, automation] arguments in
            guard let id = try arguments.ids("id").first else { throw ToolError("id is required") }
            let body = try arguments.requiredString("body")
            let replyAll = try arguments.bool("reply_all") ?? false
            let cc = try arguments.strings("cc")
            let bcc = try arguments.strings("bcc")
            try Self.validateAddresses(cc, field: "cc")
            try Self.validateAddresses(bcc, field: "bcc")
            let mode = try Self.mode(arguments)
            let attachments = try self.validatedAttachments(arguments)
            let original = try store.detail(id: id)
            guard let mailbox = try store.mailbox(id: original.summary.mailboxID) else { throw ToolError("Mailbox of message \(id) not found") }
            try Self.refuseDrafts(mailbox, id: id)
            let fullBody = try arguments.bool("quote_original") ?? true ? Self.quotedReply(body: body, original: original) : body
            let subject = original.summary.subject.lowercased().hasPrefix("re:") ? original.summary.subject : "Re: " + original.summary.subject
            if mode == .send {
                let own = try store.ownAddresses()
                var recipients = [(original.replyTo.first ?? original.summary.sender).address]
                if replyAll {
                    recipients += (original.to + original.cc).map(\.address).filter { !own.contains($0.lowercased()) }
                }
                var seen = Set<String>()
                recipients = recipients.filter { seen.insert($0.lowercased()).inserted }
                try await self.authorizeSend(
                    tool: "reply_to_message", from: nil, to: recipients,
                    cc: cc, bcc: bcc, subject: subject, body: body, attachments: attachments)
            }
            let started = (try? self.store.maxMessageRowID()) ?? .max
            let handle = try await automation.reply(
                to: id, in: MailboxTarget(mailbox), body: fullBody, replyAll: replyAll, cc: cc, bcc: bcc,
                attachments: attachments, mode: mode)
            let draftID = mode == .draft ? await self.settleDraft(handle, subject: subject, after: started) : nil
            return ToolReply(
                json: .obj(self.draftResult(mode, draftID: draftID) + [("in_reply_to", .int(id)), ("subject", .string(subject))]),
                summary: "reply \(mode.rawValue): \(Render.truncate(subject, 60))")
        }
    }

    /// Text of a forwarded message: the note, a header block and the original body.
    static func forwardedBody(note: String, original: MessageDetail) -> String {
        let s = original.summary
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        var lines = [note.isEmpty ? "" : note + "\n", "---------- Forwarded message ----------", "From: \(s.sender.formatted)"]
        lines.append("Date: \(formatter.string(from: s.dateReceived))")
        lines.append("Subject: \(s.subject)")
        if !original.to.isEmpty { lines.append("To: \(original.to.map(\.formatted).joined(separator: ", "))") }
        if !original.cc.isEmpty { lines.append("Cc: \(original.cc.map(\.formatted).joined(separator: ", "))") }
        lines.append("")
        lines.append(original.textBody ?? s.preview ?? "")
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
    }

    /// Writes the original's attachments to a private cache folder so Mail can attach them.
    func extractAttachments(of id: Int64, _ attachments: [AttachmentInfo]) throws -> [String] {
        guard !attachments.isEmpty else { return [] }
        let cache = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/apple-mail-mcp/forward")
        // Mail copies attachments when it saves or sends; folders from earlier forwards can go.
        if let old = try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for folder in old where ((try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date())
                < Date().addingTimeInterval(-86_400)
            {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        let folder = cache.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var paths: [String] = []
        for attachment in attachments {
            let (info, data) = try store.attachmentData(messageID: id, attachment: attachment.partID)
            var name = Self.safeFilename(info.filename, fallback: "attachment-\(info.partID)")
            if paths.contains(where: { ($0 as NSString).lastPathComponent == name }) { name = "\(info.partID)-\(name)" }
            let url = folder.appending(path: name)
            try data.write(to: url)
            paths.append(url.path)
        }
        return paths
    }

    var forwardMessage: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "forward_message", "Forward",
                """
                Forward a message with its attachments and an optional note above it. The original is included \
                as text below a "Forwarded message" header. Saved as a draft unless mode says otherwise.
                """,
                Schema.object(
                    [
                        "id": Schema.integer("Message id to forward"),
                        "to": Schema.strings("Recipient addresses"),
                        "cc": Schema.strings("Cc addresses"),
                        "bcc": Schema.strings("Bcc addresses"),
                        "body": Schema.string("Note to put above the forwarded message"),
                        "include_attachments": Schema.boolean("Attach the original's attachments (default true)"),
                        "mode": Self.modeSchema,
                    ], required: ["id", "to"]), kind: .compose, openWorld: true),
            kind: .compose
        ) { [store, automation] arguments in
            guard let id = try arguments.ids("id").first else { throw ToolError("id is required") }
            let to = try arguments.strings("to")
            let cc = try arguments.strings("cc")
            let bcc = try arguments.strings("bcc")
            guard !to.isEmpty else { throw ToolError("to is required") }
            try Self.validateAddresses(to, field: "to")
            try Self.validateAddresses(cc, field: "cc")
            try Self.validateAddresses(bcc, field: "bcc")
            let note = try arguments.string("body") ?? ""
            let mode = try Self.mode(arguments)
            let original = try store.detail(id: id)
            guard let mailbox = try store.mailbox(id: original.summary.mailboxID) else { throw ToolError("Mailbox of message \(id) not found") }
            try Self.refuseDrafts(mailbox, id: id)
            guard original.bodyAvailable else { throw MailStoreError.bodyNotDownloaded(id) }
            let subject = original.summary.subject.lowercased().hasPrefix("fwd:") ? original.summary.subject : "Fwd: " + original.summary.subject
            let includeAttachments = try arguments.bool("include_attachments") ?? true
            let downloaded = original.attachments.filter(\.isDownloaded)
            let files = includeAttachments ? try self.extractAttachments(of: id, downloaded) : []
            let body = Self.forwardedBody(note: note, original: original)
            if mode == .send {
                try await self.authorizeSend(
                    tool: "forward_message", from: nil, to: to, cc: cc, bcc: bcc, subject: subject, body: body, attachments: files)
            }
            let started = (try? self.store.maxMessageRowID()) ?? .max
            let handle = try await automation.compose(
                OutgoingMessage(to: to, cc: cc, bcc: bcc, subject: subject, body: body, attachments: files), mode: mode)
            let draftID = mode == .draft ? await self.settleDraft(handle, subject: subject, after: started) : nil
            let skipped = includeAttachments ? original.attachments.count - downloaded.count : 0
            return ToolReply(
                json: .obj(self.draftResult(mode, draftID: draftID) + [
                    ("forwarded", .int(id)), ("to", .array(to.map { .string($0) })),
                    ("attachments", files.isEmpty ? nil : .int(Int64(files.count))),
                    ("attachments_not_downloaded", skipped > 0 ? .int(Int64(skipped)) : nil),
                ]),
                summary: "forward \(mode.rawValue): \(Render.truncate(subject, 60))")
        }
    }

    var openInMail: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "open_in_mail", "Show in Mail", "Open a message in Mail so the user can see it.",
                Schema.object(["id": Schema.integer("Message id")], required: ["id"]), kind: .compose, idempotent: true),
            kind: .compose
        ) { [store, automation] arguments in
            guard let id = try arguments.ids("id").first else { throw ToolError("id is required") }
            let message = try store.message(id: id)
            // A message:// link needs no Apple Events or automation permission.
            if let link = message.mailLink, let url = URL(string: link) {
                let opened = await MainActor.run { NSWorkspace.shared.open(url) }
                if opened { return ToolReply(json: .obj([("opened", .int(id))]), summary: "opened \(id)") }
            }
            guard let mailbox = try store.mailbox(id: message.mailboxID) else { throw ToolError("Mailbox of message \(id) not found") }
            try await automation.open(id, in: MailboxTarget(mailbox))
            return ToolReply(json: .obj([("opened", .int(id))]), summary: "opened \(id)")
        }
    }
}
