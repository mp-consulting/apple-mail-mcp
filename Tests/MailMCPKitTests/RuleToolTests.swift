import Foundation
import MCP
import MailAutomation
import MailFixtures
import MailStore
import Testing

@testable import MailMCPKit

@Suite("Rule tools")
final class RuleToolTests {
    let h: Harness
    init() throws {
        h = try Harness()
        h.toolbox.ruleVerification = RuleVerification(local: 0.3, synced: 0.3, interval: 0.02)
        h.toolbox.mailLaunchDate = { Date.distantPast }
    }
    deinit { h.remove() }

    /// A rule as Mail writes it to `SyncedRules.plist`.
    static func saved(_ id: String, _ name: String, criteria: [[String: Any]], move: String? = nil) -> [String: Any] {
        var rule: [String: Any] = [
            "RuleId": id, "RuleName": name, "AllCriteriaMustBeSatisfied": true, "AutoResponseType": 0, "Criteria": criteria,
            "MarkRead": false, "MarkFlagged": false, "Deletes": false, "StopEvaluatingRules": false,
        ]
        if let move { rule["ShouldTransferMessage"] = true; rule["MailboxURL"] = move }
        return rule
    }

    /// `spec` in the keys Mail saves (`-[MFMessageRule dictionaryRepresentation]`).
    static func mailFormat(_ spec: RuleSpec, id: String, mailboxURL: (MailboxTarget) -> String) -> [String: Any] {
        var rule: [String: Any] = [
            "RuleId": id, "RuleName": spec.name, "AllCriteriaMustBeSatisfied": spec.allMustMatch, "MarkRead": spec.markRead,
            "Deletes": spec.delete, "StopEvaluatingRules": spec.stopEvaluating, "MarkFlagged": spec.flag != nil,
            "AutoResponseType": !spec.forwardTo.isEmpty ? 1 : spec.replyText != nil ? 2 : !spec.redirectTo.isEmpty ? 3 : 0,
            "Criteria": spec.conditions.map { condition -> [String: Any] in
                var criterion: [String: Any] = ["CriterionUniqueId": UUID().uuidString, "Header": condition.header ?? condition.field.savedName]
                if condition.field.takesValue { criterion["Expression"] = condition.value }
                if condition.qualifier != .contains { criterion["Qualifier"] = condition.qualifier.savedName }
                return criterion
            },
        ]
        if let flag = spec.flag { rule["FlagColor"] = flag.rawValue }
        if let target = spec.moveTo { rule["ShouldTransferMessage"] = true; rule["MailboxURL"] = mailboxURL(target) }
        if let target = spec.copyTo { rule["ShouldCopyMessage"] = true; rule["CopyToMailboxURL"] = mailboxURL(target) }
        if let color = spec.color { rule["Color"] = MailRuleActions.colorNames.first { $0.value == color.rawValue }!.key }
        if !spec.forwardTo.isEmpty { rule["ForwardRecipients"] = spec.forwardTo }
        if !spec.redirectTo.isEmpty { rule["RedirectRecipients"] = spec.redirectTo }
        if let reply = spec.replyText { rule["ResponseMessage"] = reply }
        return rule
    }

    /// Writes the rule files the way Mail saves them.
    static func write(_ store: FixtureMailStore, rules: [[String: Any]], active: [String: Bool]) {
        try? store.writeMailData("SyncedRules.plist", plist: rules)
        try? store.writeMailData("RulesActiveState.plist", plist: active)
    }

    let newsletters: [String: Value] = [
        "name": "Newsletters",
        "conditions": [["field": "from", "value": "news@letters.test"], ["field": "subject", "qualifier": "begins_with", "value": "Digest"]],
        "move_to": "Archive", "mark_read": true,
    ]

    @Test func createsARuleAndConfirmsMailSavedIt() async throws {
        let store = h.fixture.store
        let archive = "imap://\(h.fixture.icloud)/Archive"
        h.automation.onRuleChange = { call in
            guard case .createRule(let spec) = call else { return }
            Self.write(store, rules: [Self.mailFormat(spec, id: "NEW") { _ in archive }], active: ["NEW": true])
        }
        let json = try await h.json("create_rule", newsletters)
        #expect(json["created"] as? String == "Newsletters" && json["saved"] as? Bool == true && json["pending"] == nil)
        #expect(json["differences"] == nil && json["warning"] == nil)
        #expect((json["change_id"] as? String)?.hasPrefix("c-") == true)
        guard case .createRule(let spec)? = h.automation.calls.last else { Issue.record("no createRule call"); return }
        #expect(spec.moveTo == MailboxTarget(accountID: h.fixture.icloud, path: "Archive"))
        #expect(spec.conditions == [
            RuleCondition(field: .from, value: "news@letters.test"), RuleCondition(field: .subject, qualifier: .beginsWith, value: "Digest"),
        ])
        #expect(spec.enabled && spec.allMustMatch && spec.markRead && !spec.sendsMail)
        #expect(h.automation.unguardedChanges == 0)
        let setup = try await h.json("mail_setup", ["include": ["rules"]])
        #expect(setup["pending_rules"] == nil)
    }

    @Test func reportsARuleMailHasNotSavedYet() async throws {
        let store = h.fixture.store
        // Mail writes its local files, but the definitions wait for iCloud Drive.
        h.automation.onRuleChange = { _ in try? store.writeMailData("RulesActiveState.plist", plist: ["NEW": true]) }
        let json = try await h.json("create_rule", newsletters)
        #expect(json["saved"] as? Bool == false && json["pending"] as? String == "pending_icloud")
        #expect((json["note"] as? String)?.contains("Keep Mail open") == true)

        var setup = try await h.json("mail_setup", ["include": ["rules"]])
        let pending = (setup["pending_rules"] as? [[String: Any]])?.first
        #expect(pending?["name"] as? String == "Newsletters" && pending?["status"] as? String == "not saved yet")

        // Pending changes are kept on disk: another server process (or the next session) still reports it.
        let other = PendingRuleStore(url: h.support.appending(path: "pending-rules.json"))
        #expect(other.all.map(\.name) == ["Newsletters"])

        // Once Mail saves it, mail_setup stops reporting it.
        guard case .createRule(let spec)? = h.automation.calls.last else { Issue.record("no createRule call"); return }
        let archive = "imap://\(h.fixture.icloud)/Archive"
        Self.write(store, rules: [Self.mailFormat(spec, id: "NEW") { _ in archive }], active: ["NEW": true])
        setup = try await h.json("mail_setup", ["include": ["rules"]])
        #expect(setup["pending_rules"] == nil)
        #expect(other.all.isEmpty)
    }

    @Test func saysWhenMailSavedSomethingElse() async throws {
        let store = h.fixture.store
        h.automation.onRuleChange = { call in
            guard case .createRule(var spec) = call else { return }
            spec.markRead = false
            spec.conditions[0].value = "other@letters.test"
            Self.write(store, rules: [Self.mailFormat(spec, id: "NEW") { _ in "imap://AAAAAAAA-0000-0000-0000-000000000001/Archive" }], active: ["NEW": true])
        }
        let json = try await h.json("create_rule", newsletters)
        let differences = json["differences"] as? [String] ?? []
        #expect(json["warning"] != nil && differences.count == 2)
        #expect(differences.contains { $0.hasPrefix("mark_read: asked true, saved false") })
        #expect(differences.contains { $0.hasPrefix("conditions:") && $0.contains("other@letters.test") })
    }

    @Test func reportsAChangeLostWhenMailRestarted() async throws {
        let json = try await h.json("create_rule", newsletters)
        #expect(json["pending"] as? String == "saving")
        h.toolbox.mailLaunchDate = { Date() }
        let setup = try await h.json("mail_setup", ["include": ["rules"]])
        #expect(((setup["pending_rules"] as? [[String: Any]])?.first?["status"] as? String)?.hasPrefix("lost") == true)
        #expect(h.toolbox.pendingRules?.all.isEmpty == true)
    }

    @Test func refusesBadOrDuplicateRules() async throws {
        try h.fixture.store.writeMailData("SyncedRules.plist", plist: [Self.saved("R1", "Existing", criteria: [["Header": "From", "Expression": "a"]])])
        h.automation.mailRuleNames = ["Only in memory"]
        func refused(_ arguments: [String: Value], _ text: String) async {
            let result = await h.call("create_rule", arguments)
            #expect(result.isError && result.text.contains(text), "\(arguments): \(result.text)")
        }
        var arguments = newsletters
        arguments["name"] = "Existing"
        await refused(arguments, "already exists")
        arguments["name"] = "Only in memory"
        await refused(arguments, "already exists")
        await refused(["name": "X", "conditions": [["field": "from", "value": "a"]]], "needs an action")
        await refused(["name": "X", "conditions": [["field": "from"]], "mark_read": true], "value is required")
        await refused(["name": "X", "conditions": [["field": "sender", "value": "a"]], "mark_read": true], "unknown sender")
        await refused(["name": "X", "conditions": [["field": "header", "value": "a"]], "mark_read": true], "header is required")
        await refused(["name": "X", "conditions": [["field": "junk"]], "move_to": "INBOX"], "set account")
        await refused(["name": "X", "conditions": [["field": "junk"]], "move_to": "Nowhere"], "No mailbox matches")
        await refused(["name": "X", "conditions": [["field": "junk"]], "delete": true, "move_to": "Junk"], "not both")
        await refused(["name": "X", "conditions": [["field": "junk"]], "forward_to": ["nobody"]], "not an email address")
        #expect(h.automation.calls.isEmpty)
    }

    @Test func rulesThatSendOrDeleteNeedApproval() async throws {
        let forward: [String: Value] = [
            "name": "Forward invoices", "conditions": [["field": "subject", "value": "Invoice"]], "forward_to": ["books@example.test"],
        ]
        let refused = await h.call("create_rule", forward)
        #expect(refused.isError && refused.text.contains("menu bar app"))
        let everything = await h.call("create_rule", ["name": "All", "conditions": [["field": "every_message"]], "mark_read": true])
        #expect(everything.isError && everything.text.contains("menu bar app"))
        #expect(h.automation.calls.isEmpty)

        h.approvals.beat()
        let approvals = h.approvals
        let agent = Task { () -> ApprovalRequest? in
            for _ in 0..<200 {
                if let request = approvals.pending().first {
                    try approvals.decide(request.id, approve: true)
                    return request
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            return nil
        }
        _ = try await h.json("create_rule", forward)
        let request = try #require(try await agent.value)
        #expect(request.action == .rule && request.to == ["books@example.test"] && request.subject == "Create rule \"Forward invoices\"")
        #expect(request.bodyPreview.contains("subject contains \"Invoice\"") && request.bodyPreview.contains("forward to books@example.test"))
        guard case .createRule(let spec)? = h.automation.calls.last else { Issue.record("no createRule call"); return }
        #expect(spec.forwardTo == ["books@example.test"] && spec.sendsMail)
    }

    @Test func forwardingRulesFollowTheSendPolicy() async throws {
        var settings = Harness.sendingAllowed
        settings.sendPolicy = .never
        let strict = try Harness(settings: settings)
        defer { strict.remove() }
        let result = await strict.call(
            "create_rule", ["name": "Fwd", "conditions": [["field": "from", "value": "a@b.test"]], "redirect_to": ["c@d.test"]])
        #expect(result.isError && result.text.contains("send policy"))
    }

    @Test func turnsARuleOnInPlace() async throws {
        let store = h.fixture.store
        let archive = "imap://\(h.fixture.icloud)/Archive"
        // A compound condition: kept as it is, since the rule is not copied.
        @Sendable func compound() -> [[String: Any]] { [["Header": "Compound", "Criteria": [["Header": "From", "Expression": "news@letters.test"]]]] }
        Self.write(store, rules: [Self.saved("R1", "Newsletters", criteria: compound(), move: archive)], active: ["R1": false])
        h.automation.onRuleChange = { call in
            guard case .setRuleEnabled(_, let enabled) = call else { return }
            Self.write(store, rules: [Self.saved("R1", "Newsletters", criteria: compound(), move: archive)], active: ["R1": enabled])
        }
        let json = try await h.json("set_rule_enabled", ["name": "Newsletters", "enabled": true])
        #expect(json["enabled"] as? Bool == true && json["saved"] as? Bool == true && json["warning"] == nil)
        #expect(h.automation.calls.last == .setRuleEnabled("Newsletters", true))

        let again = try await h.json("set_rule_enabled", ["name": "Newsletters", "enabled": true])
        #expect(again["unchanged"] as? Bool == true)
        #expect(h.automation.calls.count == 1)
    }

    @Test func refusesMissingOrAmbiguousRules() async throws {
        try h.fixture.store.writeMailData("SyncedRules.plist", plist: [
            Self.saved("R2", "Twin", criteria: [["Header": "From", "Expression": "a"]]),
            Self.saved("R3", "Twin", criteria: [["Header": "From", "Expression": "b"]]),
        ])
        h.automation.mailRuleNames = ["Unsaved"]
        for tool in ["set_rule_enabled", "update_rule", "delete_rule"] {
            for (name, text) in [("Twin", "2 rules are named"), ("Unsaved", "has not saved"), ("Missing", "No rule named")] {
                let result = await h.call(tool, ["name": .string(name), "enabled": true])
                #expect(result.isError && result.text.contains(text), "\(tool) \(name): \(result.text)")
            }
        }
        #expect(h.automation.calls.isEmpty)
    }

    /// Approves the next request in the menu bar app's place, returning it.
    func approveNext() -> Task<ApprovalRequest?, Error> {
        h.approvals.beat()
        let approvals = h.approvals
        return Task {
            for _ in 0..<200 {
                if let request = approvals.pending().first {
                    try approvals.decide(request.id, approve: true)
                    return request
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            return nil
        }
    }

    @Test func deletesARuleAfterApproval() async throws {
        let store = h.fixture.store
        Self.write(store, rules: [Self.saved("R1", "Old rule", criteria: [["Header": "From", "Expression": "a@b.test"]])], active: ["R1": true])
        h.automation.onRuleChange = { call in
            guard case .deleteRule = call else { return }
            Self.write(store, rules: [], active: [:])
        }
        let refused = await h.call("delete_rule", ["name": "Old rule"])
        #expect(refused.isError && refused.text.contains("menu bar app"))

        let agent = approveNext()
        let json = try await h.json("delete_rule", ["name": "Old rule"])
        let request = try #require(try await agent.value)
        #expect(request.action == .rule && request.subject == "Delete rule \"Old rule\"" && request.bodyPreview.contains("a@b.test"))
        #expect(json["deleted"] as? String == "Old rule" && json["saved"] as? Bool == true)
        #expect(((json["was"] as? [String: Any])?["criteria"] as? [[String: Any]])?.first?["value"] as? String == "a@b.test")
        #expect(h.automation.calls == [.deleteRule("Old rule")])
    }

    @Test func updatesARuleInPlace() async throws {
        let store = h.fixture.store
        Self.write(store, rules: [Self.saved("R1", "Shop", criteria: [["Header": "From", "Expression": "shop.test"]])], active: ["R1": true])
        h.automation.onRuleChange = { call in
            guard case .updateRule(_, let update) = call else { return }
            var rule = Self.saved("R1", update.name ?? "Shop", criteria: (update.conditions ?? []).map { ["Header": $0.field == .subject ? "Subject" : "From", "Expression": $0.value] })
            rule["MarkFlagged"] = true
            rule["FlagColor"] = 1
            Self.write(store, rules: [rule], active: ["R1": true])
        }
        let json = try await h.json("update_rule", [
            "name": "Shop", "new_name": "Shop receipts", "conditions": [["field": "subject", "value": "receipt"]], "flag_color": "orange",
            "move_to": "none",
        ])
        #expect(json["rule"] as? String == "Shop receipts" && json["renamed_from"] as? String == "Shop" && json["saved"] as? Bool == true)
        #expect((json["actions"] as? [String])?.contains("flag orange") == true)
        guard case .updateRule("Shop", let update)? = h.automation.calls.last else { Issue.record("no updateRule call"); return }
        #expect(update.name == "Shop receipts" && update.conditions == [RuleCondition(field: .subject, value: "receipt")])
        #expect(update.flag == .set(.orange) && update.moveTo == .clear && update.forwardTo == .keep && update.markRead == nil)

        let nothing = await h.call("update_rule", ["name": "Shop receipts"])
        #expect(nothing.isError && nothing.text.contains("Nothing to change"))
        h.automation.mailRuleNames = ["Taken"]
        let taken = await h.call("update_rule", ["name": "Shop receipts", "new_name": "Taken"])
        #expect(taken.isError && taken.text.contains("already exists"))
        // Adding forwarding asks first.
        let forward = await h.call("update_rule", ["name": "Shop receipts", "forward_to": ["books@example.test"]])
        #expect(forward.isError && forward.text.contains("menu bar app"))
    }

    @Test func remakesARuleToDropConditions() async throws {
        let store = h.fixture.store
        var rule = Self.saved("R1", "Two", criteria: [["Header": "From", "Expression": "a"], ["Header": "Subject", "Expression": "b"]],
            move: "imap://\(h.fixture.icloud)/Archive")
        rule["MarkFlagged"] = true
        rule["FlagColor"] = 2
        Self.write(store, rules: [rule], active: ["R1": true])
        h.automation.onRuleChange = { call in
            guard case .replaceRule(_, let spec) = call else { return }
            Self.write(store, rules: [Self.saved("R9", spec.name, criteria: [["Header": "From", "Expression": "a"]])], active: ["R9": spec.enabled])
        }
        let json = try await h.json("update_rule", ["name": "Two", "conditions": [["field": "from", "value": "a"]]])
        #expect(json["saved"] as? Bool == true)
        guard case .replaceRule("Two", let spec)? = h.automation.calls.last else { Issue.record("no replaceRule call"); return }
        // Everything else is kept: the move, the flag, on.
        #expect(spec.conditions == [RuleCondition(field: .from, value: "a")] && spec.enabled && spec.flag == .yellow)
        #expect(spec.moveTo == MailboxTarget(accountID: h.fixture.icloud, path: "Archive"))

        // A rule with a notification cannot be made again.
        var noisy = Self.saved("R2", "Noisy", criteria: [["Header": "From", "Expression": "a"], ["Header": "From", "Expression": "b"]])
        noisy["NotifyUser"] = true
        Self.write(store, rules: [noisy], active: ["R2": true])
        let refused = await h.call("update_rule", ["name": "Noisy", "conditions": [["field": "from", "value": "a"]]])
        #expect(refused.isError && refused.text.contains("Mail › Settings"))
    }

    @Test func undoesRuleChanges() async throws {
        let store = h.fixture.store
        let archive = "imap://\(h.fixture.icloud)/Archive"
        let shop = RuleSpec(
            name: "Shop", enabled: true, conditions: [RuleCondition(field: .from, qualifier: .endsWith, value: "shop.test")],
            moveTo: MailboxTarget(accountID: h.fixture.icloud, path: "Archive"), markRead: true)
        Self.write(store, rules: [Self.mailFormat(shop, id: "R1") { _ in archive }], active: ["R1": true])
        // Mail as the fake: every rule call leaves the files as Mail would.
        h.automation.onRuleChange = { call in
            switch call {
            case .setRuleEnabled(_, let enabled): Self.write(store, rules: [Self.mailFormat(shop, id: "R1") { _ in archive }], active: ["R1": enabled])
            case .deleteRule: Self.write(store, rules: [], active: [:])
            case .createRule(let spec), .replaceRule(_, let spec):
                Self.write(store, rules: [Self.mailFormat(spec, id: "R2") { _ in archive }], active: ["R2": spec.enabled])
            default: break
            }
        }
        // Off, then undo: on again.
        let off = try await h.json("set_rule_enabled", ["name": "Shop", "enabled": false])
        let offID = try #require(off["change_id"] as? String)
        let undoneOff = try await h.json("undo_change", ["action": "undo", "change_id": .string(offID)])
        #expect(undoneOff["saved"] as? Bool == true && h.automation.calls.last == .setRuleEnabled("Shop", true))

        // Deleted, then undo: made again as it was.
        let agent = approveNext()
        let deleted = try await h.json("delete_rule", ["name": "Shop"])
        _ = try await agent.value
        let deletedID = try #require(deleted["change_id"] as? String)
        let listed = try await h.json("undo_change", ["action": "list"])
        #expect((listed["changes"] as? [[String: Any]])?.first?["change"] as? String == "deleted")
        let undoneDelete = try await h.json("undo_change", ["action": "undo", "change_id": .string(deletedID)])
        #expect(undoneDelete["saved"] as? Bool == true && undoneDelete["differences"] == nil)
        #expect(h.automation.calls.last == .createRule(shop))

        // Created, then undo: deleted.
        Self.write(store, rules: [], active: [:])
        let created = try await h.json("create_rule", newsletters)
        let createdID = try #require(created["change_id"] as? String)
        _ = try await h.json("undo_change", ["action": "undo", "change_id": .string(createdID)])
        #expect(h.automation.calls.last == .deleteRule("Newsletters"))
        // Undone once only.
        #expect(await h.call("undo_change", ["action": "undo", "change_id": .string(createdID)]).isError)
    }

    @Test func rulesThatCannotBeMadeAgainAreNotUndoable() async throws {
        var noisy = Self.saved("R1", "Noisy", criteria: [["Header": "From", "Expression": "a"]])
        noisy["NotifyUser"] = true
        let store = h.fixture.store
        Self.write(store, rules: [noisy], active: ["R1": true])
        h.automation.onRuleChange = { _ in Self.write(store, rules: [], active: [:]) }
        let agent = approveNext()
        let deleted = try await h.json("delete_rule", ["name": "Noisy"])
        _ = try await agent.value
        let listed = try await h.json("undo_change", ["action": "list"])
        #expect(((listed["changes"] as? [[String: Any]])?.first?["cannot_undo"] as? String)?.contains("notification") == true)
        let undo = await h.call("undo_change", ["action": "undo", "change_id": .string(deleted["change_id"] as? String ?? "")])
        #expect(undo.isError && undo.text.contains("cannot be undone"))
    }

    @Test func respectsTheMailChangesSwitch() async throws {
        var settings = Harness.sendingAllowed
        settings.allowMailChanges = false
        let locked = try Harness(settings: settings)
        defer { locked.remove() }
        #expect(await locked.call("create_rule", newsletters).isError)
        #expect(await locked.call("set_rule_enabled", ["name": "Newsletters", "enabled": true]).isError)
    }
}
