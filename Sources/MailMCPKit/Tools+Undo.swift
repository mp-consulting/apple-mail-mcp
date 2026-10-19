import Foundation
import MCP
import MailAutomation
import MailStore

/// One change to mail that `undo_change` can reverse. Holds Message-IDs and mailbox paths, never subjects or bodies
/// (a rule change holds the rule as it was, which the user's own Mail settings already hold).
public struct ChangeRecord: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable { case move, trash, update, rule }

    /// A change to a Mail rule, with what undoing it needs.
    public struct Rule: Codable, Sendable, Hashable {
        public enum Action: String, Codable, Sendable { case created, deleted, updated, enabled }
        public var action: Action
        /// The rule's name after the change.
        public var name: String
        /// The rule as it was before (deleted or updated); nil when the tools cannot make it again.
        public var before: RuleSpec?
        /// For `enabled`: whether it was on before.
        public var wasEnabled: Bool?
        /// Why `before` is missing: what the rule had that the tools cannot make.
        public var cannotUndo: String?
    }

    /// One message as it was before the change.
    public struct Item: Codable, Sendable, Hashable {
        /// `Message-ID` header (without brackets): the message's ROWID changes when it moves.
        public var messageID: String
        public var accountID: String
        /// Mailbox path before the change.
        public var from: String
        /// Mailbox path after a move or trash; nil when it went to an account's Trash without a single one.
        public var to: String?
        /// Previous read state, when the change touched it.
        public var read: Bool?
        /// Previous flag state, when the change touched flags.
        public var flagged: Bool?
        /// Previous flag colour index (FlagColor raw value), when it was flagged.
        public var flagColor: Int?

        public init(
            messageID: String, accountID: String, from: String, to: String? = nil, read: Bool? = nil, flagged: Bool? = nil,
            flagColor: Int? = nil
        ) {
            self.messageID = messageID
            self.accountID = accountID
            self.from = from
            self.to = to
            self.read = read
            self.flagged = flagged
            self.flagColor = flagColor
        }
    }

    public var id: String
    public var date: Date
    public var client: String?
    public var tool: String
    public var kind: Kind
    public var items: [Item]
    /// For `rule` changes.
    public var rule: Rule?
    /// Messages the change touched that had no Message-ID: they cannot be found again, so not undone.
    public var untracked: Int
    public var undone: Date?

    public init(
        id: String = ChangeRecord.newID(), date: Date = Date(), client: String?, tool: String, kind: Kind, items: [Item],
        rule: Rule? = nil, untracked: Int = 0, undone: Date? = nil
    ) {
        self.rule = rule
        self.id = id
        self.date = date
        self.client = client
        self.tool = tool
        self.kind = kind
        self.items = items
        self.untracked = untracked
        self.undone = undone
    }

    /// Short and easy to repeat back: `c-` and 8 hex digits.
    public static func newID() -> String {
        "c-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }
}

/// The last changes to mail, shared by all server processes. Owner-only, capped at `limit` records.
public final class ChangeJournal: @unchecked Sendable {
    public var url: URL { file.url }
    private let file: SharedJSONFile<[ChangeRecord]>
    private let limit: Int

    public init(url: URL = SharedPaths.changeJournal, limit: Int = 100) {
        file = SharedJSONFile(url: url, empty: [])
        self.limit = limit
    }

    /// Newest first.
    public func records() -> [ChangeRecord] { file.value.reversed() }

    public func record(_ record: ChangeRecord) {
        guard !record.items.isEmpty || record.rule != nil else { return }
        try? file.modify { records in
            records.append(record)
            if records.count > limit { records.removeFirst(records.count - limit) }
        }
    }

    public func markUndone(_ id: String, at date: Date = Date()) {
        try? file.modify { records in
            if let index = records.firstIndex(where: { $0.id == id }) { records[index].undone = date }
        }
    }
}

extension MailToolbox {
    var undoTools: [ToolDefinition] { [undoChange] }

    /// Records a move or trash once Mail's database confirmed it; returns the change id to quote for undo.
    @discardableResult
    func journalMove(_ kind: ChangeRecord.Kind, tool: String, steps: [ChangeStep], done: [Int64]) -> String? {
        let done = Set(done)
        var items: [ChangeRecord.Item] = []
        var untracked = 0
        for step in steps {
            for message in step.messages where done.contains(message.id) {
                guard let header = message.messageIDHeader else {
                    untracked += 1
                    continue
                }
                items.append(.init(messageID: header, accountID: step.source.accountID, from: step.source.path, to: step.destination?.path))
            }
        }
        return record(ChangeRecord(client: clientName, tool: tool, kind: kind, items: items, untracked: untracked))
    }

    private func record(_ record: ChangeRecord) -> String? {
        guard let changes, !record.items.isEmpty || record.rule != nil else { return nil }
        changes.record(record)
        return record.id
    }

    /// Records a rule change; returns the change id to quote for undo.
    func journalRule(
        _ action: ChangeRecord.Rule.Action, name: String, before: RuleSpec?, wasEnabled: Bool? = nil, reason: String? = nil
    ) -> String? {
        let tool = ["created": "create_rule", "deleted": "delete_rule", "updated": "update_rule", "enabled": "set_rule_enabled"][action.rawValue]!
        let rule = ChangeRecord.Rule(
            action: action, name: name, before: before, wasEnabled: wasEnabled,
            cannotUndo: before == nil && action != .created && action != .enabled ? reason ?? "parts the tools cannot make" : nil)
        return record(ChangeRecord(client: clientName, tool: tool, kind: .rule, items: [], rule: rule))
    }

    /// Records the read and flag state that `update_messages` is about to change.
    @discardableResult
    func journalUpdate(_ groups: [(Mailbox, [MessageSummary])], read: Bool?, flags: Bool) -> String? {
        var items: [ChangeRecord.Item] = []
        var untracked = 0
        for (mailbox, messages) in groups {
            for message in messages {
                guard let header = message.messageIDHeader else {
                    untracked += 1
                    continue
                }
                items.append(.init(
                    messageID: header, accountID: mailbox.accountID, from: mailbox.path,
                    read: read == nil ? nil : message.isRead, flagged: flags ? message.isFlagged : nil,
                    flagColor: flags && message.isFlagged ? message.flagColor?.rawValue : nil))
            }
        }
        return record(ChangeRecord(client: clientName, tool: "update_messages", kind: .update, items: items, untracked: untracked))
    }

    static func changeJSON(_ record: ChangeRecord) -> JSON {
        if let rule = record.rule {
            return .obj([
                ("change_id", .string(record.id)), ("date", Render.date(record.date)), ("tool", .string(record.tool)),
                ("kind", .string("rule")), ("rule", .string(rule.name)), ("change", .string(rule.action.rawValue)),
                ("client", record.client.map { .string($0) }),
                ("cannot_undo", rule.cannotUndo.map { .string("the rule had \($0)") }),
                ("undone", record.undone.map(Render.date)),
            ])
        }
        let destinations = Set(record.items.compactMap(\.to)).sorted()
        let sources = Set(record.items.map(\.from)).sorted()
        return .obj([
            ("change_id", .string(record.id)),
            ("date", Render.date(record.date)),
            ("tool", .string(record.tool)),
            ("kind", .string(record.kind.rawValue)),
            ("messages", .int(Int64(record.items.count))),
            ("from", .array(sources.map { .string($0) })),
            ("to", destinations.isEmpty ? nil : .array(destinations.map { .string($0) })),
            ("client", record.client.map { .string($0) }),
            ("cannot_undo", record.untracked > 0 ? .int(Int64(record.untracked)) : nil),
            ("undone", record.undone.map(Render.date)),
        ])
    }

    var undoChange: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "undo_change", "Undo a change",
                """
                List recent moves, trashes, flag changes and rule changes (action "list"), or put one back (action \
                "undo", the latest by default): moved and trashed messages return to their mailbox, read and flag \
                states are restored, a created rule is deleted, a deleted or changed rule comes back as it was, and a \
                rule turned on or off is switched back. Messages are found again by Message-ID. Use dry_run to preview.
                """,
                Schema.object([
                    "action": Schema.string("list (default) or undo", enum: ["list", "undo"]),
                    "change_id": Schema.string("Change to undo (from list or a change's reply); default the latest not yet undone"),
                    "limit": Schema.integer("With list: how many changes (default 10)", minimum: 1, maximum: 100),
                    "dry_run": Schema.boolean("Only report what would be restored (default false)"),
                ]), kind: .mailChange),
            kind: .mailChange
        ) { arguments in
            let records = self.changes?.records() ?? []
            if (try arguments.string("action") ?? "list") == "list" {
                let limit = try arguments.int("limit", default: 10, in: 1...200)
                return ToolReply(
                    json: .obj([("changes", .array(records.prefix(limit).map(Self.changeJSON)))]),
                    summary: "\(min(limit, records.count)) changes")
            }
            try self.requireMailChanges()
            let wanted = try arguments.string("change_id")
            guard let record = wanted.map({ id in records.first { $0.id == id } }) ?? records.first(where: { $0.undone == nil }) else {
                throw ToolError(wanted.map { "No change \($0) in the journal." } ?? "Nothing to undo.")
            }
            if let undone = record.undone {
                throw ToolError("Change \(record.id) was already undone on \(Render.dateFormatter.string(from: undone)).")
            }
            return try await self.undo(record, dryRun: try arguments.bool("dry_run") ?? false)
        }
    }

    private func undo(_ record: ChangeRecord, dryRun: Bool) async throws -> ToolReply {
        let store = try self.store
        let boxes = try store.mailboxes()
        func mailbox(_ path: String?, accountID: String) -> Mailbox? {
            guard let path else { return nil }
            return boxes.first { $0.accountID == accountID && $0.path == path }
        }
        switch record.kind {
        case .rule:
            guard let change = record.rule else { throw ToolError("Change \(record.id) has no rule recorded.") }
            return try await undoRule(record.id, change, dryRun: dryRun)
        case .move, .trash:
            // Where each message is now (its destination), and where it goes back to.
            var steps: [ChangeStep] = []
            var missing: [String] = []
            let groups = Dictionary(grouping: record.items) { [$0.accountID, $0.from, $0.to ?? ""] }
            for (_, items) in groups.sorted(by: { $0.key.joined() < $1.key.joined() }) {
                let first = items[0]
                guard let original = mailbox(first.from, accountID: first.accountID) else {
                    throw ToolError("Mailbox \(first.from) no longer exists; nothing was restored.")
                }
                let current = mailbox(first.to, accountID: first.accountID).map { [$0] }
                    ?? boxes.filter { $0.accountID == first.accountID && $0.role == .trash }
                let found = try store.messages(messageIDHeaders: items.map(\.messageID), mailboxIDs: current.map(\.id))
                let byHeader = Dictionary(found.compactMap { m in m.messageIDHeader.map { ($0, m) } }, uniquingKeysWith: { a, _ in a })
                missing += items.map(\.messageID).filter { byHeader[$0] == nil }
                for (sourceID, messages) in Dictionary(grouping: byHeader.values, by: \.mailboxID) {
                    guard let source = boxes.first(where: { $0.id == sourceID }), source.id != original.id else { continue }
                    steps.append(ChangeStep(source: source, destination: original, messages: messages, mustArrive: true))
                }
            }
            if dryRun {
                return ToolReply(
                    json: .obj([
                        ("dry_run", .bool(true)), ("change_id", .string(record.id)),
                        ("would_restore", .array(steps.map { step in
                            .obj([
                                ("from", .string(step.source.path)), ("to", .string(step.destination!.path)),
                                ("ids", .array(step.messages.map { .int($0.id) })),
                            ])
                        })),
                        ("not_found", missing.isEmpty ? nil : .int(Int64(missing.count))),
                    ]), summary: "dry run: \(steps.reduce(0) { $0 + $1.messages.count }) to restore")
            }
            guard !steps.isEmpty else {
                throw ToolError("None of the \(record.items.count) messages of \(record.id) are where that change left them (moved again or deleted).")
            }
            let report = try await applyVerified(steps) { step in
                _ = try await self.automation.move(
                    ids: step.messages.map(\.id), from: MailboxTarget(step.source), to: MailboxTarget(step.destination!))
            }
            if !report.done.isEmpty { changes?.markUndone(record.id) }
            let mapping = report.newIDs.sorted { $0.key < $1.key }
            let json = JSON.obj(
                [
                    ("undone", .string(record.id)),
                    ("restored", .int(Int64(report.done.count))),
                    ("new_ids", mapping.isEmpty ? nil : .object(mapping.map { (String($0.key), .int($0.value)) })),
                    ("not_in_place", missing.isEmpty ? nil : .int(Int64(missing.count))),
                ] + report.fields(notFound: []))
            return ToolReply(json: json, summary: report.summary("restored"), messageID: mapping.first?.value)

        case .update:
            var plan: [(Mailbox, [MessageSummary], ChangeRecord.Item)] = []
            var missing = 0
            // Messages sharing the same previous state go back in one call.
            let groups = Dictionary(grouping: record.items) { item in
                [item.accountID, item.from, "\(item.read.map { $0 ? 1 : 0 } ?? -1)", "\(item.flagged.map { $0 ? 1 : 0 } ?? -1)", "\(item.flagColor ?? -1)"]
            }
            for (_, items) in groups.sorted(by: { $0.key.joined() < $1.key.joined() }) {
                let first = items[0]
                guard let box = mailbox(first.from, accountID: first.accountID) else {
                    missing += items.count
                    continue
                }
                let found = try store.messages(messageIDHeaders: items.map(\.messageID), mailboxIDs: [box.id])
                missing += items.count - Set(found.compactMap(\.messageIDHeader)).count
                if !found.isEmpty { plan.append((box, found, first)) }
            }
            if dryRun {
                return ToolReply(
                    json: .obj([
                        ("dry_run", .bool(true)), ("change_id", .string(record.id)),
                        ("would_restore", .int(Int64(plan.reduce(0) { $0 + $1.1.count }))),
                        ("not_found", missing > 0 ? .int(Int64(missing)) : nil),
                    ]), summary: "dry run")
            }
            guard !plan.isEmpty else { throw ToolError("None of the messages of \(record.id) are in their mailbox any more.") }
            var restored = 0
            for (box, messages, previous) in plan {
                let color = previous.flagged == true ? previous.flagColor.flatMap(FlagColor.init(rawValue:)) : nil
                restored += try await automation.setState(
                    ids: messages.map(\.id), in: MailboxTarget(box), read: previous.read,
                    flagged: color == nil ? previous.flagged : nil, flagColor: color)
            }
            changes?.markUndone(record.id)
            return ToolReply(
                json: .obj([
                    ("undone", .string(record.id)), ("restored", .int(Int64(restored))),
                    ("not_found", missing > 0 ? .int(Int64(missing)) : nil),
                ]), summary: "restored \(restored)")
        }
    }

    private func undoRule(_ id: String, _ change: ChangeRecord.Rule, dryRun: Bool) async throws -> ToolReply {
        let store = try self.store
        if let reason = change.cannotUndo { throw ToolError("Change \(id) cannot be undone: the rule had \(reason), which the tools cannot make again.") }
        let current = store.rules().filter { $0.name == change.name }
        let what: String
        switch change.action {
        case .created: what = "delete the rule \"\(change.name)\""
        case .deleted: what = "make the rule \"\(change.name)\" again"
        case .updated: what = "put the rule \"\(change.name)\" back as it was\(change.before.map { $0.name == change.name ? "" : " (named \"\($0.name)\")" } ?? "")"
        case .enabled: what = "turn the rule \"\(change.name)\" \(change.wasEnabled == true ? "on" : "off") again"
        }
        if dryRun { return ToolReply(json: .obj([("dry_run", .bool(true)), ("change_id", .string(id)), ("would", .string(what))]), summary: "dry run: \(what)") }
        try requireMailChanges()
        if change.action == .deleted {
            guard current.isEmpty else { throw ToolError("A rule named \"\(change.name)\" exists again; nothing was changed.") }
        } else if current.count != 1 {
            throw ToolError(current.isEmpty ? "No rule named \"\(change.name)\" any more; nothing was changed." : "\(current.count) rules are named \"\(change.name)\"")
        }
        let restoring = change.before
        if let restoring, change.action != .enabled {
            try await authorizeRule(restoring.name, verb: "Restore", summary: Self.describe(restoring), sendsTo: restoring.forwardTo + restoring.redirectTo,
                sendsMail: restoring.sendsMail, risky: restoring.delete || restoring.conditions.contains { $0.field == .everyMessage })
        }
        let before = store.ruleFileDates()
        let pending: PendingRule
        switch change.action {
        case .created:
            try await automation.exclusive { try await automation.deleteRule(named: change.name) }
            pending = PendingRule(name: change.name, expectation: .absent, requested: Date())
        case .deleted, .updated:
            guard let restoring else { throw ToolError("Change \(id) did not record the rule as it was.") }
            if change.action == .deleted {
                try await automation.exclusive { try await automation.createRule(restoring) }
            } else {
                try await automation.exclusive { try await automation.replaceRule(named: change.name, with: restoring) }
            }
            pending = PendingRule(
                name: restoring.name, expectation: .present(spec: restoring, enabled: restoring.enabled, conditions: restoring.conditions.count),
                requested: Date())
        case .enabled:
            let enabled = change.wasEnabled ?? false
            let rule = current[0]
            if enabled, rule.definition.autoResponse != 0 || rule.definition.deletes {
                try await authorizeRule(change.name, verb: "Turn on", summary: Self.describe(rule), sendsTo: rule.definition.forwardTo + rule.definition.redirectTo,
                    sendsMail: rule.definition.autoResponse != 0, risky: true)
            }
            try await automation.exclusive { try await automation.setRuleEnabled(named: change.name, enabled: enabled) }
            var expected = spec(of: rule).spec
            expected?.enabled = enabled
            pending = PendingRule(name: change.name, expectation: .present(spec: expected, enabled: enabled, conditions: rule.criteria.count), requested: Date())
        }
        let save = try await waitForRule(pending, before: before)
        track(save, pending)
        changes?.markUndone(id)
        return ToolReply(json: .obj([("undone", .string(id)), ("did", .string(what))] + Self.saveFields(save)), summary: "undid \(id): \(what)")
    }
}
