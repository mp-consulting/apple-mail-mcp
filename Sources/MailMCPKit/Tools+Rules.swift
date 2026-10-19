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

extension MailToolbox {
    var ruleTools: [ToolDefinition] { [createRule, setRuleEnabled, updateRule, deleteRule, applyRules] }

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
                ("pending"). Change it with update_rule, turn it off with set_rule_enabled, remove it with delete_rule, \
                and run it on mail already there with apply_rules.
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
            let pending = PendingRule(
                name: spec.name, expectation: .present(spec: spec, enabled: spec.enabled, conditions: spec.conditions.count), requested: Date())
            let save = try await self.waitForRule(pending, before: before)
            self.track(save, pending)
            let change = self.journalRule(.created, name: spec.name, before: nil)
            return ToolReply(
                json: .obj([("created", .string(spec.name)), ("enabled", .bool(spec.enabled))] + Self.saveFields(save) + [("change_id", change.map(JSON.string))]),
                summary: save.isSaved ? "created rule \(spec.name)" : "created rule \(spec.name) (\(save.pending == nil ? "saved differently" : "not saved yet"))")
        }
    }

    var setRuleEnabled: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "set_rule_enabled", "Turn Mail rule on or off",
                """
                Turn a Mail rule on or off, by name (see mail_setup). The rule keeps its conditions and actions. Turning \
                on a rule that forwards, redirects, auto-replies or deletes needs approval in the Apple Mail MCP menu \
                bar app.
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
            let rule = try await self.savedRule(name)
            if rule.enabled == enabled {
                return ToolReply(json: .obj([("rule", .string(name)), ("enabled", .bool(enabled)), ("unchanged", .bool(true))]), summary: "rule \(name) unchanged")
            }
            if enabled {
                try await self.authorizeRule(name, verb: "Turn on", summary: Self.describe(rule), sendsTo: rule.definition.forwardTo + rule.definition.redirectTo,
                    sendsMail: rule.definition.autoResponse != 0, risky: rule.definition.deletes)
            }
            let before = store.ruleFileDates()
            try await automation.exclusive { try await automation.setRuleEnabled(named: name, enabled: enabled) }
            var expected = self.spec(of: rule).spec
            expected?.enabled = enabled
            let pending = PendingRule(name: name, expectation: .present(spec: expected, enabled: enabled, conditions: rule.criteria.count), requested: Date())
            let save = try await self.waitForRule(pending, before: before)
            self.track(save, pending)
            let change = self.journalRule(.enabled, name: name, before: self.spec(of: rule).spec, wasEnabled: rule.enabled ?? !enabled)
            return ToolReply(
                json: .obj([("rule", .string(name)), ("enabled", .bool(enabled))] + Self.saveFields(save) + [("change_id", change.map(JSON.string))]),
                summary: "turned rule \(name) \(enabled ? "on" : "off")\(save.isSaved ? "" : " (not saved yet)")")
        }
    }

    var updateRule: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "update_rule", "Change Mail rule",
                """
                Change a Mail rule in place, by name: rename it, replace its conditions, or change its actions. Only \
                the parts given change. To remove an action pass "none" (move_to, copy_to, flag_color, color), false \
                (mark_read, delete), [] (forward_to, redirect_to) or "" (reply_text). Adding forwarding, redirection, \
                an auto-reply or deletion, or an every_message condition, needs approval in the menu bar app.
                """,
                Schema.object(
                    [
                        "name": Schema.string("Current rule name"),
                        "new_name": Schema.string("New name"),
                        "enabled": Schema.boolean("Turn it on or off"),
                        "conditions": Self.conditionsSchema("Replaces every condition"),
                        "match": Schema.string("all conditions or any", enum: ["all", "any"]),
                        "account": Schema.string("Account of move_to and copy_to (default: the only one with that mailbox)"),
                        "move_to": Schema.string("Move matching messages to this mailbox, or \"none\""),
                        "copy_to": Schema.string("Copy matching messages to this mailbox, or \"none\""),
                        "mark_read": Schema.boolean("Mark matching messages read"),
                        "flag_color": Schema.string("Flag matching messages, or \"none\"", enum: FlagColor.allCases.map(\.name) + ["none"]),
                        "color": Schema.string("Colour matching messages, or \"none\"", enum: RuleColor.allCases.map(\.rawValue) + ["none"]),
                        "delete": Schema.boolean("Move matching messages to Trash"),
                        "forward_to": Schema.strings("Forward to these addresses ([] to stop forwarding)"),
                        "redirect_to": Schema.strings("Redirect to these addresses ([] to stop)"),
                        "reply_text": Schema.string("Auto-reply text (\"\" to stop replying)"),
                        "stop_evaluating": Schema.boolean("Stop evaluating later rules for matching messages"),
                    ], required: ["name"]), kind: .mailChange, openWorld: true),
            kind: .mailChange
        ) { [automation] arguments in
            let store = try self.store
            try self.requireMailChanges()
            let name = try arguments.requiredString("name")
            let rule = try await self.savedRule(name)
            let update = try self.ruleUpdate(arguments)
            let newName = update.name ?? name
            if newName != name, try await automation.ruleNames().contains(newName) || store.rules().contains(where: { $0.name == newName }) {
                throw ToolError("A rule named \"\(newName)\" already exists")
            }
            let turningOnRisky = update.enabled == true && (rule.definition.autoResponse != 0 || rule.definition.deletes)
            let addsEveryMessage = update.conditions?.contains { $0.field == .everyMessage } ?? false
            if update.addsSending || update.delete == true || addsEveryMessage || turningOnRisky {
                var addresses: [String] = []
                if case .set(let list) = update.forwardTo { addresses += list }
                if case .set(let list) = update.redirectTo { addresses += list }
                try await self.authorizeRule(name, verb: "Change", summary: Self.describe(update, of: rule), sendsTo: addresses,
                    sendsMail: update.addsSending || (update.enabled == true && rule.definition.autoResponse != 0), risky: true)
            }
            let before = store.ruleFileDates()
            let (base, reason) = self.spec(of: rule)
            if let conditions = update.conditions, conditions.count < rule.criteria.count {
                // Scripting cannot remove a condition (Mail crashes), so the rule is made again.
                guard let base else {
                    throw ToolError("Removing conditions means making \"\(name)\" again, which cannot keep \(reason ?? "all of it"); change it in Mail › Settings › Rules")
                }
                let spec = Self.applying(update, to: base)
                try await automation.exclusive { try await automation.replaceRule(named: name, with: spec) }
            } else {
                try await automation.exclusive { try await automation.updateRule(named: name, update) }
            }
            let pending = PendingRule(
                name: newName,
                expectation: .present(
                    spec: base.map { Self.applying(update, to: $0) }, enabled: update.enabled ?? rule.enabled ?? false,
                    conditions: update.conditions?.count ?? rule.criteria.count),
                requested: Date())
            let save = try await self.waitForRule(pending, before: before)
            self.track(save, pending)
            if newName != name { self.pendingRules?.set(name, nil) }
            let change = self.journalRule(.updated, name: newName, before: base, reason: reason)
            return ToolReply(
                json: .obj(
                    [("rule", .string(newName)), ("renamed_from", newName == name ? nil : .string(name))] + Self.saveFields(save) + [
                        ("actions", save.isSaved ? store.rules().first { $0.name == newName }.map { .array($0.actions.map(JSON.string)) } : nil),
                        ("change_id", change.map(JSON.string)),
                    ]),
                summary: "changed rule \(newName)\(save.isSaved ? "" : " (not saved yet)")")
        }
    }

    var deleteRule: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "delete_rule", "Delete Mail rule",
                """
                Delete a Mail rule, by name. Always asks in the Apple Mail MCP menu bar app first; the reply describes \
                the deleted rule so it can be made again with create_rule. To keep it but stop it, use set_rule_enabled.
                """,
                Schema.object(["name": Schema.string("Rule name")], required: ["name"]), kind: .mailChange, destructive: true),
            kind: .mailChange
        ) { [automation] arguments in
            let store = try self.store
            try self.requireMailChanges()
            let name = try arguments.requiredString("name")
            let rule = try await self.savedRule(name)
            try await self.authorizeRule(name, verb: "Delete", summary: Self.describe(rule), sendsTo: [], sendsMail: false, risky: true)
            let before = store.ruleFileDates()
            try await automation.exclusive { try await automation.deleteRule(named: name) }
            let pending = PendingRule(name: name, expectation: .absent, requested: Date())
            let save = try await self.waitForRule(pending, before: before)
            self.track(save, pending)
            let (snapshot, reason) = self.spec(of: rule)
            let change = self.journalRule(.deleted, name: name, before: snapshot, reason: reason)
            return ToolReply(
                json: .obj([("deleted", .string(name))] + Self.saveFields(save) + [("was", Self.ruleJSON(rule)), ("change_id", change.map(JSON.string))]),
                summary: "deleted rule \(name)\(save.isSaved ? "" : " (not saved yet)")")
        }
    }

    // MARK: Helpers

    static func conditionsSchema(_ description: String) -> Value {
        .object([
            "type": "array", "minItems": 1, "description": .string(description),
            "items": Schema.object(
                [
                    "field": Schema.string("What to look at", enum: RuleField.allCases.map(\.rawValue)),
                    "qualifier": Schema.string("How to compare (default contains)", enum: RuleQualifier.allCases.map(\.rawValue)),
                    "value": Schema.string("Text to compare with (not for every_message, junk or the contacts fields)"),
                    "header": Schema.string("Header name, for field header (e.g. List-Id)"),
                ], required: ["field"]),
        ])
    }

    /// The one saved rule named `name`, or an error that says why there is none.
    func savedRule(_ name: String) async throws -> MailRule {
        let matching = try store.rules().filter { $0.name == name }
        if matching.count == 1 { return matching[0] }
        if matching.count > 1 { throw ToolError("\(matching.count) rules are named \"\(name)\"; rename one in Mail › Settings › Rules") }
        if try await automation.ruleNames().contains(name) {
            throw ToolError("Mail has not saved \"\(name)\" yet; try again once mail_setup lists it")
        }
        throw ToolError("No rule named \"\(name)\" (mail_setup lists them)")
    }

    func ruleConditions(_ arguments: Arguments) throws -> [RuleCondition]? {
        guard let raw = arguments.values["conditions"], raw != .null else { return nil }
        guard case .array(let items) = raw, !items.isEmpty else {
            throw ToolError("conditions must be a non-empty list of {field, qualifier, value}")
        }
        return try items.enumerated().map { index, item -> RuleCondition in
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
    }

    func ruleSpec(_ arguments: Arguments) throws -> RuleSpec {
        let name = try arguments.requiredString("name").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let conditions = try ruleConditions(arguments) else { throw ToolError("conditions is required: a list of {field, qualifier, value}") }
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

    func ruleUpdate(_ arguments: Arguments) throws -> RuleUpdate {
        var update = RuleUpdate()
        if let newName = try arguments.string("new_name")?.trimmingCharacters(in: .whitespacesAndNewlines) { update.name = newName }
        update.enabled = try arguments.bool("enabled")
        update.conditions = try ruleConditions(arguments)
        if let match = try arguments.string("match") {
            guard ["all", "any"].contains(match) else { throw ToolError("match must be all or any") }
            update.allMustMatch = match == "all"
        }
        func mailbox(_ key: String) throws -> RuleChange<MailboxTarget> {
            guard let text = try arguments.string(key) else { return .keep }
            return text.lowercased() == "none" ? .clear : .set(try ruleMailbox(arguments, key)!)
        }
        update.moveTo = try mailbox("move_to")
        update.copyTo = try mailbox("copy_to")
        update.markRead = try arguments.bool("mark_read")
        if let text = try arguments.string("flag_color") {
            if text.lowercased() == "none" { update.flag = .clear } else {
                guard let flag = FlagColor(name: text) else { throw ToolError("unknown flag_color \(text)") }
                update.flag = .set(flag)
            }
        }
        if let text = try arguments.string("color") {
            if text.lowercased() == "none" { update.color = .clear } else {
                guard let color = RuleColor(rawValue: text) else { throw ToolError("unknown color \(text)") }
                update.color = .set(color)
            }
        }
        update.delete = try arguments.bool("delete")
        for (key, path) in [("forward_to", \RuleUpdate.forwardTo), ("redirect_to", \RuleUpdate.redirectTo)] where arguments.has(key) {
            let addresses = try arguments.strings(key)
            try Self.validateAddresses(addresses, field: key)
            update[keyPath: path] = addresses.isEmpty ? .clear : .set(addresses)
        }
        if case .string(let text)? = arguments.values["reply_text"] {
            update.replyText = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .clear : .set(text)
        }
        update.stopEvaluating = try arguments.bool("stop_evaluating")
        if update.delete == true, case .set = update.moveTo { throw ToolError("Use delete or move_to, not both") }
        if update == RuleUpdate() { throw ToolError("Nothing to change: give new_name, enabled, conditions, match or an action") }
        return update
    }

    /// `base` with `update` applied: what the rule should be after an update.
    static func applying(_ update: RuleUpdate, to base: RuleSpec) -> RuleSpec {
        var spec = base
        if let name = update.name { spec.name = name }
        if let enabled = update.enabled { spec.enabled = enabled }
        if let match = update.allMustMatch { spec.allMustMatch = match }
        if let conditions = update.conditions { spec.conditions = conditions }
        if let markRead = update.markRead { spec.markRead = markRead }
        if let delete = update.delete { spec.delete = delete }
        if let stop = update.stopEvaluating { spec.stopEvaluating = stop }
        switch update.moveTo { case .keep: break; case .set(let box): spec.moveTo = box; case .clear: spec.moveTo = nil }
        switch update.copyTo { case .keep: break; case .set(let box): spec.copyTo = box; case .clear: spec.copyTo = nil }
        switch update.flag { case .keep: break; case .set(let flag): spec.flag = flag; case .clear: spec.flag = nil }
        switch update.color { case .keep: break; case .set(let color): spec.color = color; case .clear: spec.color = nil }
        switch update.forwardTo { case .keep: break; case .set(let list): spec.forwardTo = list; case .clear: spec.forwardTo = [] }
        switch update.redirectTo { case .keep: break; case .set(let list): spec.redirectTo = list; case .clear: spec.redirectTo = [] }
        switch update.replyText { case .keep: break; case .set(let text): spec.replyText = text; case .clear: spec.replyText = nil }
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
        let tool = ["Create": "create_rule", "Turn on": "set_rule_enabled", "Change": "update_rule", "Delete": "delete_rule", "Restore": "undo_change"][verb] ?? "rules"
        try await askUser(
            ApprovalRequest(
                id: UUID(), created: Date(), tool: tool, client: clientName, from: nil, to: sendsTo, cc: [], bcc: [],
                subject: "\(verb) rule \"\(name)\"", bodyPreview: summary, attachments: [], status: .pending, decided: nil, kind: .rule),
            what: "This rule", declined: "The user declined this rule change. Nothing was changed.", nothing: "Nothing was changed.")
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

    static func describe(_ update: RuleUpdate, of rule: MailRule) -> String {
        var lines = ["Now:", describe(rule), "Changes:"]
        if let name = update.name { lines.append("  • rename to \"\(name)\"") }
        if let enabled = update.enabled { lines.append("  • turn \(enabled ? "on" : "off")") }
        if let conditions = update.conditions {
            lines.append("  • conditions become: " + conditions.map { "\($0.field.rawValue) \($0.qualifier.rawValue) \"\($0.value)\"" }.joined(separator: "; "))
        }
        if case .set(let list) = update.forwardTo { lines.append("  • forward to \(list.joined(separator: ", "))") }
        if case .set(let list) = update.redirectTo { lines.append("  • redirect to \(list.joined(separator: ", "))") }
        if case .set(let text) = update.replyText { lines.append("  • reply: \(Render.truncate(text, 300))") }
        if update.delete == true { lines.append("  • delete matching messages") }
        return lines.joined(separator: "\n")
    }

    static func ruleJSON(_ rule: MailRule) -> JSON {
        .obj([
            ("name", .string(rule.name)), ("enabled", rule.enabled.map(JSON.bool)), ("match", .string(rule.allMustMatch ? "all" : "any")),
            ("criteria", .array(rule.criteria.map(criterionJSON))), ("actions", .array(rule.actions.map(JSON.string))),
        ])
    }

    static func describe(_ rule: MailRule) -> String {
        var lines = ["When \(rule.allMustMatch ? "all" : "any") of:"]
        lines += rule.criteria.map { "  • \($0.field) \($0.qualifier)\($0.value.map { " \"\($0)\"" } ?? "")" }
        lines.append("Then:")
        lines += rule.actions.map { "  • \($0)" }
        return lines.joined(separator: "\n")
    }
}
