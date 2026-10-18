import Foundation
import MCP
import MailAutomation
import MailStore

/// Messages moved out of the way until a date, then put back by the menu bar app.
public struct Snooze: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var created: Date
    public var until: Date
    public var client: String?
    public var accountID: String
    /// Where the messages wait (`Snoozed`).
    public var mailbox: String
    /// Where they go back to.
    public var returnTo: String
    /// `Message-ID` headers: the messages' ids change when they move.
    public var messageIDs: [String]
    public var lastError: String?
}

/// An approved email that the menu bar app sends at `sendAt`.
public struct ScheduledSend: Codable, Sendable, Hashable, Identifiable {
    /// Set for a reply: the message answered, found again by Message-ID when it is time.
    public struct Reply: Codable, Sendable, Hashable {
        public var messageID: String
        public var replyAll: Bool
    }

    public var id: String
    public var created: Date
    public var sendAt: Date
    public var client: String?
    public var tool: String
    public var from: String?
    public var to: [String]
    public var cc: [String]
    public var bcc: [String]
    public var subject: String
    public var body: String
    public var html: String?
    /// Copies of the files, in the app's private folder until the message is sent.
    public var attachments: [String]
    public var reply: Reply?
    public var attempts = 0
    public var lastError: String?
    /// When the last failed attempt started: an Apple Event can time out after Mail sent the message, so
    /// the next run looks in Sent from then on before trying again.
    public var lastAttempt: Date?
    /// Written by the server that queued it (see ``SigningKey``): an entry added to the file by anything else is not sent.
    public var signature: String?

    /// Everything that decides what goes out, and to whom; attempts and errors change, so they are not signed.
    var signedFields: [String] {
        [
            "scheduled-send", id, SigningKey.seconds(sendAt), tool, from ?? "", SigningKey.list(to), SigningKey.list(cc),
            SigningKey.list(bcc), subject, body, html ?? "", SigningKey.list(attachments), reply?.messageID ?? "",
            reply.map { $0.replyAll ? "all" : "sender" } ?? "",
        ]
    }
}

struct ScheduleState: Codable, Sendable {
    var snoozes: [Snooze] = []
    var sends: [ScheduledSend] = []
}

/// Snoozes and scheduled sends, shared by the servers (which add them) and the menu bar app (which runs them).
public final class ScheduleStore: @unchecked Sendable {
    let file: SharedJSONFile<ScheduleState>
    /// Attachments of scheduled sends wait here (owner-only).
    public let filesDirectory: URL
    let signing: SigningKeyProvider

    public init(
        url: URL = SharedPaths.schedule, filesDirectory: URL = SharedPaths.scheduledFiles, signing: SigningKeyProvider = SigningKeyProvider()
    ) {
        file = SharedJSONFile(url: url, empty: ScheduleState())
        self.filesDirectory = filesDirectory
        self.signing = signing
    }

    /// Queues a send, signed.
    func schedule(_ send: ScheduledSend) throws {
        var signed = send
        signed.signature = try signing.key().sign(send.signedFields)
        try add(signed)
    }

    /// Whether `send` was queued by a server of this bundle and not changed since.
    func isAuthentic(_ send: ScheduledSend) -> Bool {
        (try? signing.key())?.verify(send.signature, send.signedFields) == true
    }

    public var snoozes: [Snooze] { file.value.snoozes.sorted { $0.until < $1.until } }
    public var sends: [ScheduledSend] { file.value.sends.sorted { $0.sendAt < $1.sendAt } }

    func add(_ snooze: Snooze) throws { try file.modify { $0.snoozes.append(snooze) } }
    func add(_ send: ScheduledSend) throws { try file.modify { $0.sends.append(send) } }

    func updateSnooze(_ id: String, _ change: (inout Snooze?) -> Void) {
        try? file.modify { state in
            guard let index = state.snoozes.firstIndex(where: { $0.id == id }) else { return }
            var item: Snooze? = state.snoozes[index]
            change(&item)
            if let item { state.snoozes[index] = item } else { state.snoozes.remove(at: index) }
        }
    }

    /// Removes and returns the sends due by `now`, so no other process sends them too.
    /// None when the claim cannot be saved: another process would then send them too.
    func claimDueSends(now: Date, maxAttempts: Int) -> [ScheduledSend] {
        (try? file.modify { state in
            let due = state.sends.filter { $0.sendAt <= now && $0.attempts < maxAttempts }
            state.sends.removeAll { item in due.contains { $0.id == item.id } }
            return due
        }) ?? []
    }

    func removeSend(_ id: String) throws -> ScheduledSend? {
        try file.modify { state in
            guard let index = state.sends.firstIndex(where: { $0.id == id }) else { return nil }
            return state.sends.remove(at: index)
        }
    }

    /// Copies `paths` into a private folder for `id`, so the files are still there when it is time.
    func keepFiles(_ paths: [String], for id: String) throws -> [String] {
        guard !paths.isEmpty else { return [] }
        let folder = filesDirectory.appending(path: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: filesDirectory.path)
        var kept: [String] = []
        for path in paths {
            var target = folder.appending(path: (path as NSString).lastPathComponent)
            if FileManager.default.fileExists(atPath: target.path) {
                target = folder.appending(path: "\(kept.count + 1)-\((path as NSString).lastPathComponent)")
            }
            try FileManager.default.copyItem(at: URL(filePath: path), to: target)
            kept.append(target.path)
        }
        return kept
    }

    func discardFiles(for id: String) {
        try? FileManager.default.removeItem(at: filesDirectory.appending(path: id))
    }
}

/// What one pass of ``MailToolbox/runDueSchedules(now:)`` did.
public struct ScheduleRunReport: Sendable, Equatable {
    public var returned = 0
    public var sent: [String] = []
    public var failed: [String] = []
}

extension MailToolbox {
    var scheduleTools: [ToolDefinition] { [snoozeMessages, listScheduled, cancelScheduled] }

    static let maxSendAttempts = 5

    static func newScheduleID(_ prefix: String) -> String {
        prefix + "-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }

    /// `YYYY-MM-DD` means 8:00 that morning; otherwise an ISO 8601 time. Must be in the future, within a year.
    func scheduleDate(_ arguments: Arguments, key: String) throws -> Date? {
        guard let text = try arguments.string(key)?.trimmingCharacters(in: .whitespaces) else { return nil }
        guard var date = try arguments.date(key) else { return nil }
        if text.count == 10 { date.addTimeInterval(8 * 3600) }
        guard date > Date().addingTimeInterval(30) else { throw ToolError("\(key) must be in the future") }
        guard date < Date().addingTimeInterval(366 * 86_400) else { throw ToolError("\(key) must be within a year") }
        return date
    }

    /// Scheduled sends and snoozes are carried out by the menu bar app: refuse when it is not there to do it.
    func requireScheduler(_ what: String) throws {
        guard approvals.isAgentRunning() else {
            throw ToolError("\(what) needs the Apple Mail MCP menu bar app, which does it at the time; it is not running. Start it first.")
        }
    }

    /// Approves (send policy) and queues a message to be sent at `sendAt`.
    func scheduleSend(
        tool: String, sendAt: Date, from: String?, to: [String], cc: [String], bcc: [String], subject: String, body: String,
        html: String?, attachments: [String], reply: ScheduledSend.Reply? = nil, originalLink: String? = nil
    ) async throws -> ToolReply {
        guard let schedule else { throw ToolError("Scheduled sending is not available in this server.") }
        try requireScheduler("Sending later")
        try await authorizeSend(
            tool: tool, from: from, to: to, cc: cc, bcc: bcc, subject: subject, body: body, attachments: attachments,
            originalLink: originalLink, sendAt: sendAt)
        let id = Self.newScheduleID("s")
        let files = try schedule.keepFiles(attachments, for: id)
        try schedule.schedule(ScheduledSend(
            id: id, created: Date(), sendAt: Date(timeIntervalSince1970: sendAt.timeIntervalSince1970.rounded(.down)), client: clientName, tool: tool, from: from, to: to, cc: cc, bcc: bcc,
            subject: subject, body: body, html: html, attachments: files, reply: reply))
        return ToolReply(
            json: .obj([
                ("result", .string("scheduled")), ("schedule_id", .string(id)), ("send_at", Render.date(sendAt)),
                ("to", .array(to.map(JSON.string))), ("subject", .string(subject)),
            ]),
            summary: "scheduled \(Render.truncate(subject, 50)) for \(Render.dateFormatter.string(from: sendAt))")
    }

    // MARK: Tools

    var snoozeMessages: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "snooze_messages", "Snooze messages",
                """
                Move messages out of the way until a date: they wait in a "Snoozed" mailbox of their account and \
                the menu bar app puts them back where they were (marked unread) when the time comes. \
                Cancel or bring them back early with cancel_scheduled.
                """,
                Schema.object(
                    [
                        "ids": Schema.ids("Message ids"),
                        "until": Schema.string("When they come back: YYYY-MM-DD (8:00 that morning) or an ISO 8601 time"),
                        "mailbox": Schema.string("Mailbox to wait in (default Snoozed; created when missing)"),
                    ], required: ["ids", "until"]), kind: .mailChange),
            kind: .mailChange
        ) { [automation] arguments in
            guard let schedule = self.schedule else { throw ToolError("Snoozing is not available in this server.") }
            try self.requireMailChanges()
            let ids = try arguments.ids("ids")
            try self.checkBatch(ids)
            guard let until = try self.scheduleDate(arguments, key: "until") else { throw ToolError("until is required") }
            try self.requireScheduler("Snoozing")
            let waitIn = try arguments.string("mailbox") ?? "Snoozed"
            let (groups, missing) = try self.locate(ids)
            var steps: [ChangeStep] = []
            var untracked: [Int64] = []
            for (source, messages) in groups {
                guard source.path.caseInsensitiveCompare(waitIn) != .orderedSame else { continue }
                let tracked = messages.filter { $0.messageIDHeader != nil }
                untracked += messages.filter { $0.messageIDHeader == nil }.map(\.id)
                guard !tracked.isEmpty else { continue }
                let target = try await self.ensureMailbox(waitIn, accountID: source.accountID)
                steps.append(ChangeStep(source: source, destination: target, messages: tracked, mustArrive: true))
            }
            guard !steps.isEmpty else { throw ToolError("Nothing to snooze (messages not found, already snoozed, or without a Message-ID).") }
            try await self.authorizeChange(
                tool: "snooze_messages", summary: "Snooze \(steps.reduce(0) { $0 + $1.messages.count }) messages",
                messages: steps.flatMap(\.messages))
            let report = try await self.applyVerified(steps) { step in
                _ = try await automation.move(ids: step.messages.map(\.id), from: MailboxTarget(step.source), to: MailboxTarget(step.destination!))
            }
            // Unverified moves may still land: they are recorded too, so nothing stays snoozed with nothing to
            // bring it back (a message that never left is simply let go when the snooze ends).
            let attempted = Set(report.done + report.unverified)
            var snoozeIDs: [String] = []
            for step in steps {
                let headers = step.messages.filter { attempted.contains($0.id) }.compactMap(\.messageIDHeader)
                guard !headers.isEmpty else { continue }
                let id = Self.newScheduleID("z")
                try schedule.add(Snooze(
                    id: id, created: Date(), until: until, client: self.clientName, accountID: step.source.accountID,
                    mailbox: step.destination!.path, returnTo: step.source.path, messageIDs: headers))
                snoozeIDs.append(id)
            }
            let mapping = report.newIDs.sorted { $0.key < $1.key }
            return ToolReply(
                json: .obj(
                    [
                        ("snoozed", .int(Int64(report.done.count))), ("until", Render.date(until)),
                        ("schedule_ids", .array(snoozeIDs.map(JSON.string))),
                        ("new_ids", mapping.isEmpty ? nil : .object(mapping.map { (String($0.key), .int($0.value)) })),
                        ("not_snoozable", untracked.isEmpty ? nil : .array(untracked.map { .int($0) })),
                    ] + report.fields(notFound: missing)),
                summary: report.summary("snoozed") + " until \(Render.dateFormatter.string(from: until))")
        }
    }

    /// The mailbox at `path` in the account, created through Mail when missing (waits for it to appear).
    func ensureMailbox(_ path: String, accountID: String) async throws -> Mailbox {
        let store = try self.store
        func find() throws -> Mailbox? {
            try store.mailboxes(accountID: accountID).first { $0.path.caseInsensitiveCompare(path) == .orderedSame }
        }
        if let existing = try find() { return existing }
        try await automation.createMailbox(MailboxTarget(accountID: accountID, path: path))
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 250_000_000)
            guard try find() != nil else { continue }
            // Mail can show a new mailbox and drop it again when the server does not accept it (seen with
            // iCloud): only use it once it is still there a moment later.
            try await Task.sleep(nanoseconds: UInt64(mailboxSettle * 1_000_000_000))
            if let kept = try find() { return kept }
            break
        }
        throw ToolError(
            "Mail did not keep a new mailbox \(path) (iCloud can refuse it). Pass mailbox with a folder that already exists, e.g. an archive folder, or create one in Mail and check that it stays.")
    }

    var listScheduled: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "list_scheduled", "Snoozed and scheduled mail",
                "Snoozed messages and emails scheduled to send later, soonest first, with their schedule ids.",
                Schema.object([:]), kind: .read),
            kind: .read
        ) { _ in
            let snoozes = self.schedule?.snoozes ?? []
            let sends = self.schedule?.sends ?? []
            let accounts = Dictionary(uniqueKeysWithValues: ((try? self.store.accounts()) ?? []).map { ($0.id, $0.name) })
            let json = JSON.obj([
                ("snoozed", .array(snoozes.map { item in
                    .obj([
                        ("schedule_id", .string(item.id)), ("until", Render.date(item.until)), ("messages", .int(Int64(item.messageIDs.count))),
                        ("account", accounts[item.accountID].map(JSON.string)), ("returns_to", .string(item.returnTo)),
                        ("error", item.lastError.map(JSON.string)),
                    ])
                })),
                ("scheduled_sends", .array(sends.map { item in
                    .obj([
                        ("schedule_id", .string(item.id)), ("send_at", Render.date(item.sendAt)), ("subject", .string(item.subject)),
                        ("to", .array(item.to.map(JSON.string))), ("reply", item.reply == nil ? nil : .bool(true)),
                        ("attachments", item.attachments.isEmpty ? nil : .int(Int64(item.attachments.count))),
                        ("failed_attempts", item.attempts > 0 ? .int(Int64(item.attempts)) : nil), ("error", item.lastError.map(JSON.string)),
                    ])
                })),
            ])
            return ToolReply(json: json, summary: "\(snoozes.count) snoozed, \(sends.count) scheduled")
        }
    }

    var cancelScheduled: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "cancel_scheduled", "Cancel a snooze or scheduled send",
                """
                Cancel a scheduled send (nothing is sent), or end a snooze now: its messages go back to their \
                mailbox right away. Ids come from list_scheduled.
                """,
                Schema.object(["schedule_id": Schema.string("From list_scheduled")], required: ["schedule_id"]), kind: .mailChange),
            kind: .mailChange
        ) { arguments in
            guard let schedule = self.schedule else { throw ToolError("Nothing is scheduled in this server.") }
            let id = try arguments.requiredString("schedule_id")
            if let send = try schedule.removeSend(id) {
                schedule.discardFiles(for: id)
                return ToolReply(
                    json: .obj([("cancelled", .string(id)), ("subject", .string(send.subject))]),
                    summary: "cancelled send \(Render.truncate(send.subject, 50))")
            }
            guard let snooze = schedule.snoozes.first(where: { $0.id == id }) else { throw ToolError("No snooze or scheduled send \(id).") }
            try self.requireMailChanges()
            let returned = try await self.wake(snooze)
            return ToolReply(json: .obj([("woken", .string(id)), ("returned", .int(Int64(returned)))]), summary: "returned \(returned)")
        }
    }

    // MARK: Running

    /// Puts back due snoozes and sends due emails. The menu bar app calls this every half minute.
    public func runDueSchedules(now: Date = Date()) async -> ScheduleRunReport {
        var report = ScheduleRunReport()
        guard let schedule else { return report }
        for snooze in schedule.snoozes where snooze.until <= now {
            if let returned = try? await wake(snooze) { report.returned += returned }
        }
        for send in schedule.claimDueSends(now: now, maxAttempts: Self.maxSendAttempts) {
            guard schedule.isAuthentic(send) else {
                // Not queued by this app (or edited since): kept in the list with the reason, never sent.
                var refused = send
                refused.attempts = Self.maxSendAttempts
                refused.lastError = "Not sent: this entry was not scheduled by Apple Mail MCP, or was changed since."
                try? schedule.add(refused)
                report.failed.append(send.subject)
                continue
            }
            if let last = send.lastAttempt, alreadySent(send, since: last) {
                schedule.discardFiles(for: send.id)
                report.sent.append(send.subject)
                activity?.append(ActivityEntry(
                    date: Date(), pid: ProcessInfo.processInfo.processIdentifier, client: send.client, tool: "scheduled send", ok: true,
                    milliseconds: 0, summary: "sent \(Render.truncate(send.subject, 60)) (found in Sent after an error)", isWrite: true))
                continue
            }
            let attempt = Date()
            do {
                try await deliver(send)
                schedule.discardFiles(for: send.id)
                report.sent.append(send.subject)
                activity?.append(ActivityEntry(
                    date: Date(), pid: ProcessInfo.processInfo.processIdentifier, client: send.client, tool: "scheduled send", ok: true,
                    milliseconds: 0, summary: "sent \(Render.truncate(send.subject, 60))", isWrite: true))
            } catch {
                var retry = send
                retry.attempts += 1
                retry.lastError = "\(error)"
                retry.lastAttempt = attempt
                try? schedule.add(retry)
                report.failed.append(send.subject)
            }
        }
        return report
    }

    /// Moves a snooze's messages back; returns how many. Messages the user already moved elsewhere are let go.
    @discardableResult
    func wake(_ snooze: Snooze) async throws -> Int {
        guard let schedule else { return 0 }
        let store = try self.store
        let boxes = try store.mailboxes(accountID: snooze.accountID)
        guard let waiting = boxes.first(where: { $0.path == snooze.mailbox }),
              let home = boxes.first(where: { $0.path == snooze.returnTo })
        else {
            schedule.updateSnooze(snooze.id) { $0 = nil }
            return 0
        }
        let found = try store.messages(messageIDHeaders: snooze.messageIDs, mailboxIDs: [waiting.id])
        guard !found.isEmpty else {
            schedule.updateSnooze(snooze.id) { $0 = nil }
            return 0
        }
        do {
            let report = try await applyVerified([ChangeStep(source: waiting, destination: home, messages: found, mustArrive: true)]) { step in
                _ = try await self.automation.move(ids: step.messages.map(\.id), from: MailboxTarget(waiting), to: MailboxTarget(home))
            }
            let back = Array(report.newIDs.values)
            if !back.isEmpty { _ = try? await automation.setState(ids: back, in: MailboxTarget(home), read: false, flagged: nil, flagColor: nil) }
            let returned = Set(found.filter { report.done.contains($0.id) }.compactMap(\.messageIDHeader))
            schedule.updateSnooze(snooze.id) { item in
                item?.messageIDs.removeAll { returned.contains($0) }
                item?.lastError = report.unverified.isEmpty ? nil : "\(report.unverified.count) not moved back yet"
                if item?.messageIDs.isEmpty ?? true { item = nil }
            }
            activity?.append(ActivityEntry(
                date: Date(), pid: ProcessInfo.processInfo.processIdentifier, client: snooze.client, tool: "snooze", ok: true,
                milliseconds: 0, summary: "returned \(report.done.count) to \(home.path)", isWrite: true))
            return report.done.count
        } catch {
            schedule.updateSnooze(snooze.id) { $0?.lastError = "\(error)" }
            throw error
        }
    }

    /// Whether `send` reached Sent (or the Outbox) since `since`: same subject (a reply's carries "Re:") and,
    /// for a new message, the same first recipient.
    func alreadySent(_ send: ScheduledSend, since: Date) -> Bool {
        guard let store = try? self.store, let boxes = try? store.mailboxes() else { return false }
        var query = MessageQuery()
        query.mailboxIDs = boxes.filter { $0.role == .sent || $0.role == .outbox }.map(\.id)
        guard !query.mailboxIDs.isEmpty else { return false }
        query.dateFrom = since.addingTimeInterval(-120)
        query.recipient = send.reply == nil ? send.to.first : nil
        query.limit = 100
        guard let page = try? store.search(query) else { return false }
        let subject = Self.baseSubject(send.subject)
        return page.messages.contains { Self.baseSubject($0.subject) == subject }
    }

    /// The subject without reply and forward prefixes, case and spacing.
    static func baseSubject(_ subject: String) -> String {
        var text = subject.trimmingCharacters(in: .whitespaces).lowercased()
        while let colon = text.firstIndex(of: ":"), text.distance(from: text.startIndex, to: colon) <= 4,
              ["re", "fw", "fwd", "aw", "tr", "wg", "sv", "vs"].contains(text[..<colon].trimmingCharacters(in: .whitespaces))
        {
            text = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func deliver(_ send: ScheduledSend) async throws {
        guard settings.current.sendPolicy != .never else { throw ToolError("Sending is turned off (send policy \"never\").") }
        guard let reply = send.reply else {
            _ = try await automation.compose(
                OutgoingMessage(
                    from: send.from, to: send.to, cc: send.cc, bcc: send.bcc, subject: send.subject, body: send.body, html: send.html,
                    attachments: send.attachments),
                mode: .send)
            return
        }
        let store = try self.store
        let boxes = try store.mailboxes()
        let candidates = try store.messages(messageIDHeaders: [reply.messageID], mailboxIDs: boxes.map(\.id))
        guard let original = candidates.first(where: { m in boxes.first { $0.id == m.mailboxID }.map { $0.role != .drafts && $0.role != .outbox } ?? false }),
              let mailbox = boxes.first(where: { $0.id == original.mailboxID })
        else { throw ToolError("The message to reply to is no longer in Mail.") }
        _ = try await automation.reply(
            to: original.id, in: MailboxTarget(mailbox), body: send.body, html: send.html, replyAll: reply.replyAll, cc: send.cc,
            bcc: send.bcc, attachments: send.attachments, mode: .send)
    }
}
