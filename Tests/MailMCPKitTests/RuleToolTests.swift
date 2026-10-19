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
            let criteria = spec.conditions.map { ["CriterionUniqueId": UUID().uuidString, "Header": $0.field.rawValue, "Expression": $0.value] }
            Self.write(store, rules: [Self.saved("NEW", spec.name, criteria: criteria, move: archive)], active: ["NEW": true])
        }
        let json = try await h.json("create_rule", newsletters)
        #expect(json["created"] as? String == "Newsletters" && json["saved"] as? Bool == true && json["pending"] == nil)
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

        // Once Mail saves it, mail_setup stops reporting it.
        Self.write(store, rules: [Self.saved("NEW", "Newsletters", criteria: [["Header": "From"], ["Header": "Subject"]])], active: ["NEW": true])
        setup = try await h.json("mail_setup", ["include": ["rules"]])
        #expect(setup["pending_rules"] == nil)
    }

    @Test func reportsAChangeLostWhenMailRestarted() async throws {
        let json = try await h.json("create_rule", newsletters)
        #expect(json["pending"] as? String == "saving")
        h.toolbox.mailLaunchDate = { Date() }
        let setup = try await h.json("mail_setup", ["include": ["rules"]])
        #expect(((setup["pending_rules"] as? [[String: Any]])?.first?["status"] as? String)?.hasPrefix("lost") == true)
        #expect(h.toolbox.pendingRules.isEmpty)
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

    @Test func turnsARuleOnByMakingItAgain() async throws {
        let store = h.fixture.store
        let archive = "imap://\(h.fixture.icloud)/Archive"
        let criteria: [[String: Any]] = [["CriterionUniqueId": "c1", "Header": "From", "Expression": "news@letters.test"]]
        Self.write(store, rules: [Self.saved("OLD", "Newsletters", criteria: criteria, move: archive)], active: ["OLD": false])
        h.automation.onRuleChange = { call in
            guard case .setRuleEnabled(let name, let enabled, _) = call else { return }
            // Mail saves the copy under a new id, with new condition ids.
            Self.write(store, rules: [Self.saved("NEW", name, criteria: [["CriterionUniqueId": "c9", "Header": "From", "Expression": "news@letters.test"]], move: archive)],
                active: ["NEW": enabled])
        }
        let json = try await h.json("set_rule_enabled", ["name": "Newsletters", "enabled": true])
        #expect(json["enabled"] as? Bool == true && json["saved"] as? Bool == true && json["warning"] == nil)
        #expect(h.automation.calls.last == .setRuleEnabled("Newsletters", true, 1))

        let again = try await h.json("set_rule_enabled", ["name": "Newsletters", "enabled": true])
        #expect(again["unchanged"] as? Bool == true)
        #expect(h.automation.calls.count == 1)
    }

    @Test func warnsWhenTheCopyDiffers() async throws {
        let store = h.fixture.store
        Self.write(store, rules: [Self.saved("OLD", "Newsletters", criteria: [["Header": "From", "Expression": "a"]], move: "imap://\(h.fixture.icloud)/Archive")],
            active: ["OLD": true])
        h.automation.onRuleChange = { _ in
            Self.write(store, rules: [Self.saved("NEW", "Newsletters", criteria: [["Header": "From", "Expression": "a"]])], active: ["NEW": false])
        }
        let json = try await h.json("set_rule_enabled", ["name": "Newsletters", "enabled": false])
        #expect((json["warning"] as? String)?.contains("different conditions or actions") == true)
    }

    @Test func refusesRulesItCannotCopy() async throws {
        try h.fixture.store.writeMailData("SyncedRules.plist", plist: [
            Self.saved("R1", "Compound", criteria: [["Header": "Compound", "Criteria": [["Header": "From", "Expression": "a"]]]]),
            Self.saved("R2", "Twin", criteria: [["Header": "From", "Expression": "a"]]),
            Self.saved("R3", "Twin", criteria: [["Header": "From", "Expression": "b"]]),
        ])
        h.automation.mailRuleNames = ["Unsaved"]
        for (name, text) in [("Compound", "cannot copy"), ("Twin", "2 rules are named"), ("Unsaved", "has not saved"), ("Missing", "No rule named")] {
            let result = await h.call("set_rule_enabled", ["name": .string(name), "enabled": true])
            #expect(result.isError && result.text.contains(text), "\(name): \(result.text)")
        }
        #expect(h.automation.calls.isEmpty)
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
