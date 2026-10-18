import AppKit
import Foundation
import MCP
import MailAutomation
import MailStore

extension MailToolbox {
    var fileTools: [ToolDefinition] { [saveAttachment, exportMessages] }
    var changeTools: [ToolDefinition] { [moveMessages, updateMessages, trashMessages, createMailbox, checkNewMail] }

    // MARK: Files

    static func safeFilename(_ name: String, fallback: String) -> String {
        var cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        cleaned = String(cleaned.unicodeScalars.filter { $0.value >= 0x20 })
        if cleaned.isEmpty { cleaned = fallback }
        return String(cleaned.prefix(180))
    }

    /// A path in `directory` for `name` that does not overwrite anything (unless asked).
    static func destination(in directory: String, name: String, overwrite: Bool) -> String {
        let base = (directory as NSString).appendingPathComponent(name)
        guard !overwrite, FileManager.default.fileExists(atPath: base) else { return base }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for n in 2...999 {
            let candidate = (directory as NSString).appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return base
    }

    var saveAttachment: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "save_attachment", "Save attachments",
                "Save one or all attachments of a message to a folder (default ~/Downloads). Never overwrites unless asked.",
                Schema.object(
                    [
                        "id": Schema.integer("Message id"),
                        "attachment": Schema.string("Part id or file name; omit to save every attachment"),
                        "directory": Schema.string("Destination folder (default ~/Downloads)"),
                        "overwrite": Schema.boolean("Replace existing files with the same name (default false)"),
                    ], required: ["id"]), kind: .fileWrite, idempotent: true),
            kind: .fileWrite
        ) { arguments in
            let store = try self.store
            guard let id = try arguments.ids("id").first else { throw ToolError("id is required") }
            let directory = try self.pathGuard.checkWrite(try arguments.string("directory") ?? "~/Downloads")
            let overwrite = try arguments.bool("overwrite") ?? false
            let detail = try store.detail(id: id)
            let wanted = try arguments.string("attachment")
            let targets = wanted.map { [$0] } ?? detail.attachments.map(\.partID)
            guard !targets.isEmpty else { throw ToolError("Message \(id) has no attachments") }
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            var saved: [JSON] = []
            for target in targets {
                let (info, data) = try store.attachmentData(messageID: id, attachment: target)
                let name = Self.safeFilename(info.filename, fallback: "attachment-\(info.partID)")
                let path = Self.destination(in: directory, name: name, overwrite: overwrite)
                _ = try self.pathGuard.checkWrite(path)
                try data.write(to: URL(filePath: path), options: .atomic)
                saved.append(.obj([("path", .string(path)), ("bytes", .int(Int64(data.count)))]))
            }
            return ToolReply(json: .obj([("saved", .array(saved))]), summary: "saved \(saved.count) attachment(s)", messageID: id)
        }
    }

    var exportMessages: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "export_messages", "Export messages",
                "Write messages to files: .eml (original source, opens in any mail app) or Markdown (readable text).",
                Schema.object(
                    [
                        "ids": Schema.ids("Message ids (up to 200)"),
                        "directory": Schema.string("Destination folder"),
                        "format": Schema.string("eml (default) or markdown", enum: ["eml", "markdown"]),
                    ], required: ["ids", "directory"]), kind: .fileWrite, idempotent: true),
            kind: .fileWrite
        ) { arguments in
            let store = try self.store
            let ids = try arguments.ids("ids")
            guard !ids.isEmpty, ids.count <= 200 else { throw ToolError("ids must contain 1 to 200 message ids") }
            let directory = try self.pathGuard.checkWrite(try arguments.requiredString("directory"))
            let markdown = try arguments.string("format") == "markdown"
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let day = DateFormatter()
            day.dateFormat = "yyyy-MM-dd"
            var written: [JSON] = []
            var failed: [JSON] = []
            for id in ids {
                do {
                    let summary = try store.message(id: id)
                    let stem = Self.safeFilename("\(day.string(from: summary.dateReceived)) \(summary.subject.prefix(80)) [\(id)]", fallback: "message-\(id)")
                    let path = Self.destination(in: directory, name: stem + (markdown ? ".md" : ".eml"), overwrite: false)
                    if markdown {
                        let detail = try store.detail(id: id)
                        var text = "# \(summary.subject)\n\n"
                        text += "- **From:** \(summary.sender.formatted)\n"
                        if !detail.to.isEmpty { text += "- **To:** \(detail.to.map(\.formatted).joined(separator: ", "))\n" }
                        if !detail.cc.isEmpty { text += "- **Cc:** \(detail.cc.map(\.formatted).joined(separator: ", "))\n" }
                        text += "- **Date:** \(Render.dateFormatter.string(from: summary.dateReceived))\n"
                        if !detail.attachments.isEmpty { text += "- **Attachments:** \(detail.attachments.map(\.filename).joined(separator: ", "))\n" }
                        text += "\n" + (detail.textBody ?? summary.preview ?? "") + "\n"
                        try Data(text.utf8).write(to: URL(filePath: path), options: .atomic)
                    } else {
                        try store.rawSource(id: id).write(to: URL(filePath: path), options: .atomic)
                    }
                    written.append(.string(path))
                } catch {
                    failed.append(.obj([("id", .int(id)), ("error", .string("\(error)"))]))
                }
            }
            return ToolReply(
                json: .obj([("written", .array(written)), ("failed", failed.isEmpty ? nil : .array(failed))]),
                summary: "exported \(written.count)")
        }
    }

    // MARK: Mail changes

    /// Waits briefly for Mail to record moved messages, returning old id → new id.
    func newIDs(after moving: [MessageSummary], into mailbox: Mailbox) async -> [Int64: Int64] {
        let headers = moving.compactMap(\.messageIDHeader)
        guard !headers.isEmpty else { return [:] }
        var result: [Int64: Int64] = [:]
        for _ in 0..<20 {
            let found = (try? store.messages(messageIDHeaders: headers, mailboxIDs: [mailbox.id])) ?? []
            let byHeader = Dictionary(found.map { ($0.messageIDHeader ?? "", $0.id) }, uniquingKeysWith: { max($0, $1) })
            for message in moving {
                if let header = message.messageIDHeader, let newID = byHeader[header] { result[message.id] = newID }
            }
            if result.count == headers.count { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return result
    }

    var moveMessages: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "move_messages", "Move messages",
                """
                Move messages to another mailbox (e.g. archive them). Returns the messages' new ids, since Mail \
                assigns new ids on move. Use dry_run to preview.
                """,
                Schema.object(
                    [
                        "ids": Schema.ids("Message ids"),
                        "to_mailbox": Schema.string("Destination mailbox path or role (archive, inbox, junk, …)"),
                        "to_account": Schema.string("Destination account (default: each message's own account)"),
                        "dry_run": Schema.boolean("Only report what would move (default false)"),
                    ], required: ["ids", "to_mailbox"]), kind: .mailChange),
            kind: .mailChange
        ) { [automation] arguments in
            let store = try self.store
            try self.requireMailChanges()
            let ids = try arguments.ids("ids")
            try self.checkBatch(ids)
            let destinationName = try arguments.requiredString("to_mailbox")
            let forcedAccount = try self.resolveAccountID(arguments, key: "to_account")
            let dryRun = try arguments.bool("dry_run") ?? false
            let (groups, missing) = try self.locate(ids)
            var plan: [(source: Mailbox, target: Mailbox, messages: [MessageSummary])] = []
            for (source, messages) in groups {
                let accountID = forcedAccount ?? source.accountID
                let candidates = try store.resolveMailboxes(destinationName, accountID: accountID)
                let target = candidates.count == 1 ? candidates[0] : candidates.first { !$0.path.contains("/") }
                guard let target else {
                    throw ToolError("\"\(destinationName)\" matches several mailboxes: \(candidates.map(\.path).joined(separator: ", ")). Use the full path.")
                }
                let moving = messages.filter { $0.mailboxID != target.id }
                if !moving.isEmpty { plan.append((source, target, moving)) }
            }
            if dryRun {
                let json = JSON.obj([
                    ("dry_run", .bool(true)),
                    ("would_move", .array(plan.map { step in
                        .obj([
                            ("from", .string(step.source.path)), ("to", .string(step.target.path)),
                            ("ids", .array(step.messages.map { .int($0.id) })),
                        ])
                    })),
                    ("not_found", missing.isEmpty ? nil : .array(missing.map { .int($0) })),
                ])
                return ToolReply(json: json, summary: "dry run: \(plan.reduce(0) { $0 + $1.messages.count }) to move")
            }
            var moved = 0
            var mapping: [(String, JSON)] = []
            for step in plan {
                moved += try await automation.move(
                    ids: step.messages.map(\.id), from: MailboxTarget(step.source), to: MailboxTarget(step.target))
                for (old, new) in await self.newIDs(after: step.messages, into: step.target).sorted(by: { $0.key < $1.key }) {
                    mapping.append((String(old), .int(new)))
                }
            }
            let destination = plan.first?.target.path ?? destinationName
            let json = JSON.obj([
                ("moved", .int(Int64(moved))),
                ("to", .string(destination)),
                ("new_ids", mapping.isEmpty ? nil : .object(mapping)),
                ("not_found", missing.isEmpty ? nil : .array(missing.map { .int($0) })),
            ])
            let firstNew: Int64? = mapping.first.flatMap { if case .int(let id) = $0.1 { id } else { nil } }
            return ToolReply(json: json, summary: "moved \(moved) to \(destination)", messageID: firstNew)
        }
    }

    var updateMessages: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "update_messages", "Mark or flag messages",
                "Mark messages read or unread, flag or unflag them, or set a flag colour.",
                Schema.object(
                    [
                        "ids": Schema.ids("Message ids"),
                        "read": Schema.boolean("true = mark read, false = mark unread"),
                        "flagged": Schema.boolean("true = flag, false = remove the flag"),
                        "flag_color": Schema.string("Flag with this colour", enum: FlagColor.allCases.map(\.name)),
                    ], required: ["ids"]), kind: .mailChange, idempotent: true),
            kind: .mailChange
        ) { [automation] arguments in
            try self.requireMailChanges()
            let ids = try arguments.ids("ids")
            try self.checkBatch(ids)
            let read = try arguments.bool("read")
            let flagged = try arguments.bool("flagged")
            let color = try arguments.string("flag_color").map { name -> FlagColor in
                guard let flag = FlagColor(name: name) else { throw ToolError("unknown flag_color \(name)") }
                return flag
            }
            guard read != nil || flagged != nil || color != nil else { throw ToolError("Give at least one of read, flagged or flag_color") }
            let (groups, missing) = try self.locate(ids)
            var updated = 0
            for (mailbox, messages) in groups {
                updated += try await automation.setState(
                    ids: messages.map(\.id), in: MailboxTarget(mailbox), read: read, flagged: flagged, flagColor: color)
            }
            var changes: [String] = []
            if let read { changes.append(read ? "read" : "unread") }
            if let color { changes.append("flagged \(color.name)") } else if let flagged { changes.append(flagged ? "flagged" : "unflagged") }
            return ToolReply(
                json: .obj([("updated", .int(Int64(updated))), ("not_found", missing.isEmpty ? nil : .array(missing.map { .int($0) }))]),
                summary: "\(changes.joined(separator: ", ")) \(updated)", messageID: ids.count == 1 ? ids[0] : nil)
        }
    }

    var trashMessages: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "trash_messages", "Move to Trash",
                "Move messages to their account's Trash (recoverable). Messages already in Trash or Junk are left alone.",
                Schema.object(
                    [
                        "ids": Schema.ids("Message ids"),
                        "dry_run": Schema.boolean("Only report what would be trashed (default false)"),
                    ], required: ["ids"]), kind: .mailChange, destructive: true),
            kind: .mailChange
        ) { [automation] arguments in
            try self.requireMailChanges()
            let ids = try arguments.ids("ids")
            try self.checkBatch(ids)
            let dryRun = try arguments.bool("dry_run") ?? false
            let (groups, missing) = try self.locate(ids)
            // Deleting inside Trash means permanent deletion, which can crash Mail; never do it.
            let skipped = groups.filter { $0.0.role == .trash || $0.0.role == .junk }.flatMap { $0.1.map(\.id) }
            let eligible = groups.filter { $0.0.role != .trash && $0.0.role != .junk }
            if dryRun {
                return ToolReply(
                    json: .obj([
                        ("dry_run", .bool(true)),
                        ("would_trash", .array(eligible.flatMap { $0.1 }.map { Render.message($0, preview: false) })),
                        ("skipped_already_in_trash_or_junk", skipped.isEmpty ? nil : .array(skipped.map { .int($0) })),
                        ("not_found", missing.isEmpty ? nil : .array(missing.map { .int($0) })),
                    ]), summary: "dry run")
            }
            var trashed = 0
            for (mailbox, messages) in eligible {
                trashed += try await automation.trash(ids: messages.map(\.id), in: MailboxTarget(mailbox))
            }
            return ToolReply(
                json: .obj([
                    ("trashed", .int(Int64(trashed))),
                    ("skipped_already_in_trash_or_junk", skipped.isEmpty ? nil : .array(skipped.map { .int($0) })),
                    ("not_found", missing.isEmpty ? nil : .array(missing.map { .int($0) })),
                ]), summary: "trashed \(trashed)")
        }
    }

    var createMailbox: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "create_mailbox", "Create mailbox",
                "Create a mailbox (folder); use a/b paths for nesting. Omit account for an \"On My Mac\" mailbox.",
                Schema.object(
                    [
                        "path": Schema.string("Mailbox path, e.g. Projects/Alpha"),
                        "account": Schema.string("Account name, id or address (omit for On My Mac)"),
                    ], required: ["path"]), kind: .mailChange),
            kind: .mailChange
        ) { [automation] arguments in
            let store = try self.store
            try self.requireMailChanges()
            let path = try arguments.requiredString("path").trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            let accountID = try self.resolveAccountID(arguments)
            let local = try store.accounts().first { $0.kind == "local" }
            let ownerID = accountID ?? local?.id
            if let ownerID, try store.mailboxes(accountID: ownerID).contains(where: { $0.path.caseInsensitiveCompare(path) == .orderedSame }) {
                throw ToolError("Mailbox \(path) already exists")
            }
            let isLocal = accountID == nil || accountID == local?.id
            try await automation.createMailbox(MailboxTarget(accountID: isLocal ? "" : accountID!, path: path))
            return ToolReply(json: .obj([("created", .string(path))]), summary: "created \(path)")
        }
    }

    var checkNewMail: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "check_new_mail", "Check for new mail", "Ask Mail to fetch new messages now (all accounts, or one).",
                Schema.object(["account": Schema.string("Account name, id or address")]), kind: .mailChange,
                idempotent: true, openWorld: true),
            kind: .mailChange
        ) { [automation] arguments in
            let accountID = try self.resolveAccountID(arguments)
            try await automation.checkForNewMail(accountID: accountID)
            return ToolReply(json: .obj([("checking", .bool(true))]), summary: "checked mail")
        }
    }
}
