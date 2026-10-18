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
        // Control characters, and format characters such as U+202E RIGHT-TO-LEFT OVERRIDE that make
        // "invoice\u{202E}fdp.app" display as "invoiceppa.pdf".
        cleaned = String(String.UnicodeScalarView(cleaned.unicodeScalars.filter {
            $0.value >= 0x20 && $0.value != 0x7F && $0.properties.generalCategory != .format
        }))
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if cleaned.isEmpty { cleaned = fallback }
        return String(cleaned.prefix(180))
    }

    /// Marks a saved attachment the way Mail does, so Gatekeeper checks it before it can run.
    /// Without this an emailed app or `.command` script saved here would open unchecked.
    static func quarantine(_ path: String) {
        var url = URL(filePath: path)
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeEmailAttachment as String,
            kLSQuarantineAgentNameKey as String: "Apple Mail MCP",
        ]
        try? url.setResourceValues(values)
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
                Self.quarantine(path)
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

    /// Applies `steps` one source mailbox at a time, holding the automation lock for the whole call, and
    /// checks each against Mail's database: Apple Events can report success for messages that never moved,
    /// and Mail has moved messages nobody asked for. Stops at the first stray change or automation error.
    func applyVerified(_ steps: [ChangeStep], send: (ChangeStep) async throws -> Void) async throws -> ChangeReport {
        let store = try self.store
        let timing = verification
        let report = try await automation.exclusive { () async throws -> ChangeReport in
            var report = ChangeReport()
            for step in steps {
                guard report.collateral == nil, report.error == nil else {
                    report.notAttempted += step.messages.map(\.id)
                    continue
                }
                let check = try ChangeCheck(step, store: store)
                report.gone += check.gone
                guard !check.step.messages.isEmpty else { continue }
                do {
                    try await send(check.step)
                } catch {
                    report.error = error
                }
                // After an error (a timeout, say) Mail may still have acted: look once, without waiting.
                let deadline = Date().addingTimeInterval(report.error == nil ? timing.timeout : 0)
                while try !check.outcome().complete, Date() < deadline {
                    try await Task.sleep(nanoseconds: UInt64(timing.interval * 1_000_000_000))
                }
                try await Task.sleep(nanoseconds: UInt64(timing.settle * 1_000_000_000))
                let (outcome, collateral) = try check.verdict()
                report.done += check.step.messages.map(\.id).filter { outcome.done.contains($0) }
                report.unverified += check.step.messages.map(\.id).filter { !outcome.done.contains($0) }
                for id in outcome.done { if let new = outcome.arrived[id] { report.newIDs[id] = new } }
                report.collateral = collateral.map { evidence in
                    let account = (try? store.accounts())?.first { $0.id == evidence.mailbox.accountID }?.name
                    return .obj([
                        ("mailbox", .string(evidence.mailbox.path)), ("account", account.map(JSON.string)),
                        (evidence.drop ? "expected_drop" : "expected_gain", .int(Int64(evidence.expected))),
                        (evidence.drop ? "actual_drop" : "actual_gain", .int(Int64(evidence.actual))),
                    ])
                }
            }
            return report
        }
        if let error = report.error, report.done.isEmpty, report.collateral == nil { throw error }
        return report
    }

    var moveMessages: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "move_messages", "Move messages",
                """
                Move messages to another mailbox (e.g. archive them). Returns the messages' new ids, since Mail \
                assigns new ids on move. Use dry_run to preview. "moved" counts only messages Mail's database shows \
                in the destination; stop if the reply has "unverified" or "collateral_suspected".
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
            let steps = plan.map { ChangeStep(source: $0.source, destination: $0.target, messages: $0.messages, mustArrive: true) }
            let report = try await self.applyVerified(steps) { step in
                guard let target = step.destination else { return }
                _ = try await automation.move(ids: step.messages.map(\.id), from: MailboxTarget(step.source), to: MailboxTarget(target))
            }
            let mapping = report.newIDs.sorted { $0.key < $1.key }
            let destination = plan.first?.target.path ?? destinationName
            let json = JSON.obj(
                [
                    ("moved", .int(Int64(report.done.count))),
                    ("to", .string(destination)),
                    ("new_ids", mapping.isEmpty ? nil : .object(mapping.map { (String($0.key), .int($0.value)) })),
                ] + report.fields(notFound: missing))
            return ToolReply(json: json, summary: report.summary("moved") + " to \(destination)", messageID: mapping.first?.value)
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
                """
                Move messages to their account's Trash (recoverable). Messages already in Trash or Junk are left alone. \
                "trashed" counts only messages Mail's database shows gone from their mailbox; stop if the reply has \
                "unverified" or "collateral_suspected".
                """,
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
            let store = try self.store
            let steps = try eligible.map { mailbox, messages in
                let trash = try store.mailboxes(accountID: mailbox.accountID).filter { $0.role == .trash }
                return ChangeStep(source: mailbox, destination: trash.count == 1 ? trash[0] : nil, messages: messages, mustArrive: false)
            }
            let report = try await self.applyVerified(steps) { step in
                _ = try await automation.trash(ids: step.messages.map(\.id), in: MailboxTarget(step.source))
            }
            return ToolReply(
                json: .obj(
                    [
                        ("trashed", .int(Int64(report.done.count))),
                        ("skipped_already_in_trash_or_junk", skipped.isEmpty ? nil : .array(skipped.map { .int($0) })),
                    ] + report.fields(notFound: missing)),
                summary: report.summary("trashed"))
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

// MARK: Verified changes

/// How long a move or trash waits for Mail's database to show what happened.
public struct ChangeVerification: Sendable {
    public var timeout: TimeInterval
    public var interval: TimeInterval
    /// A pause before the mailbox counts are compared, so stray changes Mail makes late still show up.
    public var settle: TimeInterval

    public init(timeout: TimeInterval = 25, interval: TimeInterval = 0.25, settle: TimeInterval = 1) {
        self.timeout = timeout
        self.interval = interval
        self.settle = settle
    }
}

/// One source mailbox's share of a move or trash.
struct ChangeStep {
    var source: Mailbox
    /// Where the messages should land; nil when unknown (an account without a single Trash).
    var destination: Mailbox?
    var messages: [MessageSummary]
    /// A move only counts once the message shows up in `destination`.
    var mustArrive: Bool
}

/// What a move or trash really did, according to Mail's database rather than the Apple Event replies.
struct ChangeReport {
    var done: [Int64] = []
    var newIDs: [Int64: Int64] = [:]
    /// Requested, but not seen leaving the source mailbox before the wait ran out.
    var unverified: [Int64] = []
    /// Already gone from their mailbox when the change started.
    var gone: [Int64] = []
    /// Left alone because an earlier mailbox went wrong.
    var notAttempted: [Int64] = []
    var collateral: JSON?
    var error: (any Error)?

    static let collateralWarning = """
        Mail changed more messages than requested. Stop all bulk changes and ask the user to check Trash and \
        the mailbox named in collateral_suspected (another device or a Mail rule can also cause this).
        """
    static let unverifiedWarning = """
        Some messages had not left their mailbox when the wait ran out (Mail may be busy). Do not resend them; \
        search again later to see where they are.
        """

    /// The reply fields shared by move and trash, after each tool's own.
    func fields(notFound: [Int64]) -> [(String, JSON?)] {
        let list = { (ids: [Int64]) -> JSON? in ids.isEmpty ? nil : .array(ids.map { .int($0) }) }
        let warning = collateral != nil ? Self.collateralWarning : unverified.isEmpty ? nil : Self.unverifiedWarning
        return [
            ("unverified", list(unverified)),
            ("not_found", list(notFound + gone)),
            ("collateral_suspected", collateral),
            ("not_attempted", list(notAttempted)),
            ("error", error.map { .string("\($0)") }),
            ("warning", warning.map(JSON.string)),
        ]
    }

    func summary(_ verb: String) -> String {
        var text = "\(verb) \(done.count)"
        if !unverified.isEmpty { text += ", \(unverified.count) unverified" }
        return collateral == nil ? text : "stopped, unexpected changes in Mail: " + text
    }
}

/// Mail's database just before one step of a change, compared with what it shows afterwards.
struct ChangeCheck {
    struct Outcome {
        /// Requested messages that left the source mailbox.
        var left: [Int64] = []
        /// Old id → new id of requested messages that showed up in the destination.
        var arrived: [Int64: Int64] = [:]
        /// Left the source and, for a move, reached the destination.
        var done: Set<Int64> = []
        var complete = false
    }

    /// A mailbox count that moved more than the requested messages explain.
    struct Collateral {
        var mailbox: Mailbox
        var drop: Bool
        var expected: Int
        var actual: Int
    }

    let store: MailStore
    /// The step, narrowed to the messages still in the source mailbox.
    let step: ChangeStep
    let gone: [Int64]
    let sourceCount: Int
    let destinationCount: Int?
    /// Source rows per Message-ID, and destination rows that already carried one of them.
    let sourceRows: [String: Int]
    let destinationRows: Set<Int64>
    let headerless: Set<Int64>

    init(_ step: ChangeStep, store: MailStore) throws {
        self.store = store
        sourceCount = try store.liveCount(mailboxID: step.source.id)
        destinationCount = try step.destination.map { try store.liveCount(mailboxID: $0.id) }
        let present = try store.present(ids: step.messages.map(\.id), mailboxID: step.source.id)
        var narrowed = step
        narrowed.messages = step.messages.filter { present.contains($0.id) }
        self.step = narrowed
        gone = step.messages.map(\.id).filter { !present.contains($0) }
        headerless = Set(narrowed.messages.filter { $0.messageIDHeader == nil }.map(\.id))
        sourceRows = try Self.rows(narrowed.messages, in: step.source, store: store).mapValues(\.count)
        destinationRows = Set(try step.destination.map { try Self.rows(narrowed.messages, in: $0, store: store).values.flatMap { $0 } } ?? [])
    }

    /// Rows in `mailbox` carrying the Message-ID of one of `messages`, by Message-ID.
    static func rows(_ messages: [MessageSummary], in mailbox: Mailbox, store: MailStore) throws -> [String: [Int64]] {
        let found = try store.messages(messageIDHeaders: messages.compactMap(\.messageIDHeader), mailboxIDs: [mailbox.id])
        return found.reduce(into: [:]) { rows, message in
            if let header = message.messageIDHeader { rows[header, default: []].append(message.id) }
        }
    }

    func outcome() throws -> Outcome {
        var outcome = Outcome()
        let stillThere = try store.present(ids: step.messages.map(\.id), mailboxID: step.source.id)
        // Mail can put a message back under a new ROWID: per Message-ID, count only as many as the source lost.
        let now = try Self.rows(step.messages, in: step.source, store: store)
        var lost = sourceRows.reduce(into: [String: Int]()) { $0[$1.key] = $1.value - (now[$1.key]?.count ?? 0) }
        for message in step.messages where !stillThere.contains(message.id) {
            if let header = message.messageIDHeader {
                guard lost[header, default: 0] > 0 else { continue }
                lost[header, default: 0] -= 1
            }
            outcome.left.append(message.id)
        }
        if let destination = step.destination {
            let newest = try Self.rows(step.messages, in: destination, store: store)
                .compactMapValues { $0.filter { !destinationRows.contains($0) }.max() }
            for message in step.messages {
                if let header = message.messageIDHeader, let new = newest[header] { outcome.arrived[message.id] = new }
            }
        }
        // A message without a Message-ID cannot be found again: leaving the source has to do.
        outcome.done = Set(outcome.left.filter { !step.mustArrive || outcome.arrived[$0] != nil || headerless.contains($0) })
        outcome.complete = outcome.done.count == step.messages.count
        return outcome
    }

    /// The final outcome, and the evidence when a mailbox count moved more than it explains. Counts are
    /// read before the outcome, so changes landing in between can only excuse, never accuse.
    func verdict() throws -> (Outcome, Collateral?) {
        let sourceNow = try store.liveCount(mailboxID: step.source.id)
        let destinationNow = try step.destination.map { try store.liveCount(mailboxID: $0.id) }
        let outcome = try outcome()
        // New mail only raises the source count, so a bigger drop than the messages that left means strays.
        let drop = sourceCount - sourceNow
        if drop > outcome.left.count {
            return (outcome, Collateral(mailbox: step.source, drop: true, expected: outcome.left.count, actual: drop))
        }
        if let destination = step.destination, let before = destinationCount, let after = destinationNow {
            let expected = outcome.arrived.count + outcome.left.filter(headerless.contains).count
            if after - before > expected {
                return (outcome, Collateral(mailbox: destination, drop: false, expected: expected, actual: after - before))
            }
        }
        return (outcome, nil)
    }
}
