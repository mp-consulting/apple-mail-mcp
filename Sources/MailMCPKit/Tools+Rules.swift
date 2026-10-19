import Foundation
import MCP
import MailAutomation
import MailStore

/// How long a rule change waits for Mail to save it: the local rule files first, then the definitions in
/// `SyncedRules.plist`, which Mail writes only once it has its iCloud Drive copy.
public struct RuleVerification: Sendable {
    public var local: TimeInterval
    public var synced: TimeInterval
    public var interval: TimeInterval

    public init(local: TimeInterval = 20, synced: TimeInterval = 15, interval: TimeInterval = 0.25) {
        self.local = local
        self.synced = synced
        self.interval = interval
    }
}

/// A rule change Mail had not saved when its tool returned.
struct PendingRule: Sendable, Hashable {
    var name: String
    var enabled: Bool
    var conditions: Int
    var requested: Date
}

/// How far Mail got with saving a rule change.
enum RuleSave: String {
    /// The rule is in Mail's rule files as asked.
    case saved
    /// Mail saved locally; the definition waits for iCloud Drive. Quitting Mail now loses the change.
    case pendingICloud = "pending_icloud"
    /// Mail has the change but wrote nothing yet (its save can take a minute).
    case saving
}

extension MailToolbox {
    var ruleTools: [ToolDefinition] { [createRule, setRuleEnabled] }

    static let ruleNote = """
        Mail has the change but has not saved it yet: its save can take a minute, and the rule definitions also \
        wait for its iCloud Drive copy (usually seconds, rarely minutes). Keep Mail open until mail_setup no longer \
        lists it under pending_rules: quitting Mail before then loses it.
        """

    var createRule: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "create_rule", "Create Mail rule",
                """
                Create a Mail rule (Mail › Settings › Rules) that acts on new mail as it arrives, not on mail already \
                there: use search_messages and move_messages for that. Needs at least one condition and one action. \
                Rules that forward, redirect, auto-reply or delete, or that match every message, need approval in \
                the Apple Mail MCP menu bar app. Reports whether Mail saved the rule ("saved") or still has to \
                ("pending"). To remove a rule, turn it off with set_rule_enabled or delete it in Mail › Settings.
                """,
                Schema.object(
                    [
                        "name": Schema.string("Rule name (must not exist yet)"),
                        "conditions": .object([
                            "type": "array", "minItems": 1,
                            "description": "What a message must match",
                            "items": Schema.object(
                                [
                                    "field": Schema.string("What to look at", enum: RuleField.allCases.map(\.rawValue)),
                                    "qualifier": Schema.string("How to compare (default contains)", enum: RuleQualifier.allCases.map(\.rawValue)),
                                    "value": Schema.string("Text to compare with (not for every_message, junk or the contacts fields)"),
                                    "header": Schema.string("Header name, for field header (e.g. List-Id)"),
                                ], required: ["field"]),
                        ]),
                        "match": Schema.string("all conditions (default) or any", enum: ["all", "any"]),
                        "enabled": Schema.boolean("Turn the rule on (default true)"),
                        "account": Schema.string("Account of move_to and copy_to (default: the only one with that mailbox)"),
                        "move_to": Schema.string("Move matching messages to this mailbox (path or role)"),
                        "copy_to": Schema.string("Copy matching messages to this mailbox"),
                        "mark_read": Schema.boolean("Mark matching messages read"),
                        "flag_color": Schema.string("Flag matching messages", enum: FlagColor.allCases.map(\.name)),
                        "color": Schema.string("Colour matching messages in the list", enum: RuleColor.allCases.map(\.rawValue)),
                        "delete": Schema.boolean("Move matching messages to Trash (needs approval)"),
                        "forward_to": Schema.strings("Forward matching messages to these addresses (needs approval)"),
                        "redirect_to": Schema.strings("Redirect matching messages to these addresses (needs approval)"),
                        "reply_text": Schema.string("Reply to matching messages with this text (needs approval)"),
                        "stop_evaluating": Schema.boolean("Stop evaluating later rules for matching messages"),
                    ], required: ["name", "conditions"]), kind: .mailChange, openWorld: true),
            kind: .mailChange
        ) { [automation] arguments in
            let store = try self.store
            try self.requireMailChanges()
            let spec = try self.ruleSpec(arguments)
            let saved = store.rules()
            let inMail = try await automation.ruleNames()
            if saved.contains(where: { $0.name == spec.name }) || inMail.contains(spec.name) {
                throw ToolError("A rule named \"\(spec.name)\" already exists; pick another name, or use set_rule_enabled")
            }
            try await self.authorizeRule(spec.name, verb: "Create", summary: Self.describe(spec), sendsTo: spec.forwardTo + spec.redirectTo,
                sendsMail: spec.sendsMail, risky: spec.delete || spec.conditions.contains { $0.field == .everyMessage })
            let before = store.ruleFileDates()
            try await automation.exclusive { try await automation.createRule(spec) }
            let save = try await self.waitForRule(spec.name, before: before) { rule in
                rule.enabled == spec.enabled && rule.criteria.count == spec.conditions.count
            }
            self.track(save, PendingRule(name: spec.name, enabled: spec.enabled, conditions: spec.conditions.count, requested: Date()))
            return ToolReply(
                json: .obj([
                    ("created", .string(spec.name)), ("enabled", .bool(spec.enabled)), ("saved", .bool(save == .saved)),
                    ("pending", save == .saved ? nil : .string(save.rawValue)), ("note", save == .saved ? nil : .string(Self.ruleNote)),
                ]),
                summary: save == .saved ? "created rule \(spec.name)" : "created rule \(spec.name) (not saved yet)")
        }
    }

    var setRuleEnabled: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "set_rule_enabled", "Turn Mail rule on or off",
                """
                Turn a Mail rule on or off, by name (see mail_setup). Mail does not save a plain on/off change made by \
                another app, so the rule is made again with the same conditions and actions; rules scripting cannot \
                copy exactly are refused (change those in Mail › Settings). Turning on a rule that forwards, redirects, \
                auto-replies or deletes needs approval in the Apple Mail MCP menu bar app.
                """,
                Schema.object(
                    ["name": Schema.string("Rule name"), "enabled": Schema.boolean("true to turn it on, false to turn it off")],
                    required: ["name", "enabled"]), kind: .mailChange, idempotent: true),
            kind: .mailChange
        ) { [automation] arguments in
            let store = try self.store
            try self.requireMailChanges()
            let name = try arguments.requiredString("name")
            guard let enabled = try arguments.bool("enabled") else { throw ToolError("enabled is required") }
            let matching = store.rules().filter { $0.name == name }
            guard matching.count == 1, let rule = matching.first else {
                if matching.count > 1 { throw ToolError("\(matching.count) rules are named \"\(name)\"; rename one in Mail › Settings › Rules") }
                if try await automation.ruleNames().contains(name) {
                    throw ToolError("Mail has not saved \"\(name)\" yet; try again once mail_setup lists it")
                }
                throw ToolError("No rule named \"\(name)\" (mail_setup lists them)")
            }
            if rule.enabled == enabled {
                return ToolReply(json: .obj([("rule", .string(name)), ("enabled", .bool(enabled)), ("unchanged", .bool(true))]), summary: "rule \(name) unchanged")
            }
            if rule.actions.contains("notify") || rule.criteria.contains(where: { $0.field == "Compound" || !$0.children.isEmpty }) {
                throw ToolError("\"\(name)\" uses conditions or actions scripting cannot copy; turn it \(enabled ? "on" : "off") in Mail › Settings › Rules")
            }
            if enabled {
                let sendsMail = rule.actions.contains { $0.hasPrefix("reply, forward or redirect") }
                try await self.authorizeRule(name, verb: "Turn on", summary: Self.describe(rule), sendsTo: [], sendsMail: sendsMail,
                    risky: rule.actions.contains("delete"))
            }
            let before = store.ruleFileDates()
            try await automation.exclusive {
                try await automation.setRuleEnabled(named: name, enabled: enabled, expectedConditions: rule.criteria.count)
            }
            var changed: MailRule?
            let save = try await self.waitForRule(name, before: before) { copy in
                guard copy.enabled == enabled else { return false }
                if !Self.sameRule(copy, rule) { changed = copy }
                return true
            }
            self.track(save, PendingRule(name: name, enabled: enabled, conditions: rule.criteria.count, requested: Date()))
            return ToolReply(
                json: .obj([
                    ("rule", .string(name)), ("enabled", .bool(enabled)), ("saved", .bool(save == .saved)),
                    ("pending", save == .saved ? nil : .string(save.rawValue)), ("note", save == .saved ? nil : .string(Self.ruleNote)),
                    ("warning", changed.map { _ in .string("Mail saved the rule with different conditions or actions than before; check it in Mail › Settings › Rules") }),
                ]),
                summary: "turned rule \(name) \(enabled ? "on" : "off")\(save == .saved ? "" : " (not saved yet)")")
        }
    }

    // MARK: Helpers

    func ruleSpec(_ arguments: Arguments) throws -> RuleSpec {
        let name = try arguments.requiredString("name").trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .array(let items)? = arguments.values["conditions"], !items.isEmpty else {
            throw ToolError("conditions is required: a list of {field, qualifier, value}")
        }
        let conditions = try items.enumerated().map { index, item -> RuleCondition in
            guard case .object(let fields) = item else { throw ToolError("conditions[\(index)] must be an object") }
            let condition = Arguments(fields)
            let fieldName = try condition.requiredString("field")
            guard let field = RuleField(rawValue: fieldName) else {
                throw ToolError("conditions[\(index)].field: unknown \(fieldName); use \(RuleField.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            let qualifierName = try condition.string("qualifier") ?? "contains"
            guard let qualifier = RuleQualifier(rawValue: qualifierName) else {
                throw ToolError("conditions[\(index)].qualifier: unknown \(qualifierName); use \(RuleQualifier.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            let value = try condition.string("value") ?? ""
            if field.takesValue, value.isEmpty { throw ToolError("conditions[\(index)].value is required for \(fieldName)") }
            let header = try condition.string("header")
            if field == .header, header == nil { throw ToolError("conditions[\(index)].header is required for field header") }
            return RuleCondition(field: field, qualifier: qualifier, value: field.takesValue ? value : "", header: field == .header ? header : nil)
        }
        let match = try arguments.string("match") ?? "all"
        guard ["all", "any"].contains(match) else { throw ToolError("match must be all or any") }
        let flag = try arguments.string("flag_color").map { text -> FlagColor in
            guard let flag = FlagColor(name: text) else { throw ToolError("unknown flag_color \(text)") }
            return flag
        }
        let color = try arguments.string("color").map { text -> RuleColor in
            guard let color = RuleColor(rawValue: text) else { throw ToolError("unknown color \(text)") }
            return color
        }
        let forward = try arguments.strings("forward_to")
        let redirect = try arguments.strings("redirect_to")
        try Self.validateAddresses(forward, field: "forward_to")
        try Self.validateAddresses(redirect, field: "redirect_to")
        let spec = RuleSpec(
            name: name, enabled: try arguments.bool("enabled") ?? true, allMustMatch: match == "all", conditions: conditions,
            moveTo: try ruleMailbox(arguments, "move_to"), copyTo: try ruleMailbox(arguments, "copy_to"),
            markRead: try arguments.bool("mark_read") ?? false, flag: flag, color: color, delete: try arguments.bool("delete") ?? false,
            forwardTo: forward, redirectTo: redirect, replyText: try arguments.string("reply_text"),
            stopEvaluating: try arguments.bool("stop_evaluating") ?? false)
        let acts = spec.moveTo != nil || spec.copyTo != nil || spec.markRead || spec.flag != nil || spec.color != nil || spec.delete || spec.sendsMail
        guard acts else {
            throw ToolError("The rule needs an action: move_to, copy_to, mark_read, flag_color, color, delete, forward_to, redirect_to or reply_text")
        }
        if spec.delete, spec.moveTo != nil { throw ToolError("Use delete or move_to, not both") }
        return spec
    }

    private func ruleMailbox(_ arguments: Arguments, _ key: String) throws -> MailboxTarget? {
        guard let name = try arguments.string(key) else { return nil }
        let accountID = try resolveAccountID(arguments)
        let candidates = try store.resolveMailboxes(name, accountID: accountID)
        let accounts = Set(candidates.map(\.accountID))
        guard let target = candidates.count == 1 ? candidates[0] : (accounts.count == 1 ? candidates.first { !$0.path.contains("/") } : nil) else {
            throw ToolError(
                "\(key): \"\(name)\" matches several mailboxes: \(candidates.map(\.path).joined(separator: ", "))\(accounts.count > 1 ? "; set account" : ". Use the full path.")")
        }
        return MailboxTarget(target)
    }

    /// Asks in the menu bar app before a rule that sends mail out, deletes it, or matches every message.
    func authorizeRule(_ name: String, verb: String, summary: String, sendsTo: [String], sendsMail: Bool, risky: Bool) async throws {
        guard sendsMail || risky else { return }
        if sendsMail, settings.current.sendPolicy == .never {
            throw ToolError("Sending is turned off (send policy \"never\"), so rules that forward, redirect or reply are too")
        }
        try await askUser(
            ApprovalRequest(
                id: UUID(), created: Date(), tool: verb == "Create" ? "create_rule" : "set_rule_enabled", client: clientName, from: nil,
                to: sendsTo, cc: [], bcc: [], subject: "\(verb) rule \"\(name)\"", bodyPreview: summary, attachments: [], status: .pending,
                decided: nil, kind: .rule),
            what: "This rule", declined: "The user declined this rule. Nothing was changed.", nothing: "Nothing was changed.")
    }

    /// Waits for `name` to show in Mail's rule files as `matches` wants it.
    func waitForRule(_ name: String, before: [String: Date], matches: (MailRule) -> Bool) async throws -> RuleSave {
        let store = try self.store
        let started = Date()
        var wroteLocally = false
        while true {
            let rules = store.rules().filter { $0.name == name }
            if rules.count == 1, matches(rules[0]) { return .saved }
            let dates = store.ruleFileDates()
            wroteLocally = wroteLocally || MailStore.ruleFiles.contains { dates[$0] != before[$0] }
            let waited = Date().timeIntervalSince(started)
            if waited >= ruleVerification.local + (wroteLocally ? ruleVerification.synced : 0) {
                return wroteLocally ? .pendingICloud : .saving
            }
            try await Task.sleep(nanoseconds: UInt64(ruleVerification.interval * 1_000_000_000))
        }
    }

    func track(_ save: RuleSave, _ rule: PendingRule) {
        var pending = pendingRules.filter { $0.name != rule.name }
        if save != .saved { pending.append(rule) }
        pendingRules = pending
    }

    /// Pending rule changes, checked against Mail's files: saved ones are dropped, the rest reported.
    func pendingRuleStatus(_ rules: [MailRule]) -> [JSON] {
        let launched = mailLaunchDate()
        var still: [PendingRule] = []
        var report: [JSON] = []
        for entry in pendingRules {
            let saved = rules.filter { $0.name == entry.name }
            if saved.count == 1, saved[0].enabled == entry.enabled, saved[0].criteria.count == entry.conditions { continue }
            let lost = launched.map { $0 > entry.requested } ?? true
            if !lost { still.append(entry) }
            report.append(.obj([
                ("name", .string(entry.name)), ("enabled", .bool(entry.enabled)),
                ("status", .string(lost ? "lost: Mail quit before saving it" : "not saved yet")),
            ]))
        }
        pendingRules = still
        return report
    }

    static func sameRule(_ a: MailRule, _ b: MailRule) -> Bool {
        a.name == b.name && a.allMustMatch == b.allMustMatch && a.criteria == b.criteria && a.actions == b.actions
    }

    static func describe(_ spec: RuleSpec) -> String {
        var lines = ["When \(spec.allMustMatch ? "all" : "any") of:"]
        for condition in spec.conditions {
            let subject = condition.field == .header ? "header \(condition.header ?? "")" : condition.field.rawValue.replacingOccurrences(of: "_", with: " ")
            lines.append("  • \(subject)\(condition.field.takesValue ? " \(condition.qualifier.rawValue.replacingOccurrences(of: "_", with: " ")) \"\(condition.value)\"" : "")")
        }
        lines.append("Then:")
        if let target = spec.moveTo { lines.append("  • move to \(target.path)") }
        if let target = spec.copyTo { lines.append("  • copy to \(target.path)") }
        if spec.markRead { lines.append("  • mark as read") }
        if let flag = spec.flag { lines.append("  • flag \(flag.name)") }
        if let color = spec.color { lines.append("  • colour \(color.rawValue)") }
        if spec.delete { lines.append("  • delete (move to Trash)") }
        if !spec.forwardTo.isEmpty { lines.append("  • forward to \(spec.forwardTo.joined(separator: ", "))") }
        if !spec.redirectTo.isEmpty { lines.append("  • redirect to \(spec.redirectTo.joined(separator: ", "))") }
        if let reply = spec.replyText { lines.append("  • reply: \(Render.truncate(reply, 300))") }
        if spec.stopEvaluating { lines.append("  • stop evaluating rules") }
        return lines.joined(separator: "\n")
    }

    static func describe(_ rule: MailRule) -> String {
        var lines = ["When \(rule.allMustMatch ? "all" : "any") of:"]
        lines += rule.criteria.map { "  • \($0.field) \($0.qualifier)\($0.value.map { " \"\($0)\"" } ?? "")" }
        lines.append("Then:")
        lines += rule.actions.map { "  • \($0)" }
        return lines.joined(separator: "\n")
    }
}
