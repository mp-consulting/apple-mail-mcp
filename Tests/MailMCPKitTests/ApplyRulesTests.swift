import Foundation
import MCP
import MailAutomation
import MailFixtures
@testable import MailStore
import Testing

@testable import MailMCPKit

@Suite("apply_rules")
final class ApplyRulesTests {
    let h: Harness
    init() throws {
        h = try Harness()
        let fixture = h.fixture
        let boxes = ["INBOX": fixture.inbox, "Archive": fixture.archive, "Deleted Messages": fixture.trash]
        h.automation.onMove = { ids, target in
            for id in ids { _ = try? fixture.store.moveMessage(id, to: boxes[target.path]!) }
        }
        h.automation.onTrash = { ids, _ in
            for id in ids { _ = try? fixture.store.moveMessage(id, to: fixture.trash) }
        }
        let icloud = fixture.icloud
        // Mail writes the account of a rule's mailbox as its user name, or its id.
        try fixture.store.writeMailData("SyncedRules.plist", plist: [
            [
                "RuleId": "R1", "RuleName": "Shop", "AllCriteriaMustBeSatisfied": false,
                "Criteria": [["Header": "From", "Expression": "SHOP.test", "Qualifier": "EndsWith"]],
                "ShouldTransferMessage": true, "MailboxURL": "imap://\(icloud)/Archive", "MarkRead": true,
            ],
            [
                "RuleId": "R2", "RuleName": "Digest", "AllCriteriaMustBeSatisfied": true,
                "Criteria": [["Header": "Body", "Expression": "top stories"]],
                "MarkFlagged": true, "FlagColor": 1, "Color": 0x9BC9FF, "StopEvaluatingRules": true, "NotifyUser": true,
            ],
            [
                "RuleId": "R3", "RuleName": "Big", "Criteria": [["Header": "Size", "Expression": "1000", "Qualifier": "IsGreaterThan"]],
                "MarkRead": true,
            ],
            [
                "RuleId": "R4", "RuleName": "Forward Alice", "Criteria": [["Header": "From", "Expression": "alice"]],
                "AutoResponseType": 1, "ForwardRecipients": ["books@example.test"],
            ],
            [
                "RuleId": "R5", "RuleName": "Off", "Criteria": [["Header": "AnyMessage"]], "Deletes": true,
            ],
        ])
        try fixture.store.writeMailData("RulesActiveState.plist", plist: ["R1": true, "R2": true, "R3": true, "R4": true, "R5": false])
    }
    deinit { h.remove() }

    func rule(_ json: [String: Any], _ name: String) -> [String: Any]? {
        (json["rules"] as? [[String: Any]])?.first { $0["name"] as? String == name }
    }

    @Test func dryRunShowsWhatEachRuleWouldDo() async throws {
        let json = try await h.json("apply_rules", ["mailbox": "inbox", "account": "iCloud"])
        #expect(json["dry_run"] as? Bool == true)
        // The enabled rules, in Mail's order; the disabled one is not applied.
        #expect((json["rules"] as? [[String: Any]])?.map { $0["name"] as? String } == ["Shop", "Digest"])
        let shop = try #require(rule(json, "Shop"))
        #expect(shop["matched"] as? Int == 2)
        #expect(Set((shop["examples"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? Int }) == [Int(h.id("invoice")), Int(h.id("receipt"))])
        #expect(rule(json, "Digest")?["matched"] as? Int == 1)
        let skipped = (json["skipped_rules"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        #expect(Set(skipped) == ["Big", "Forward Alice"])
        // Its body is not downloaded, so the body rule cannot decide.
        #expect(((json["not_evaluated"] as? [String: Any])?["ids"] as? [Int])?.contains(Int(h.id("pending"))) == true)
        #expect(json["ignored"] as? [String] == ["notifications"])
        let plan = try #require(json["plan"] as? [String: Any])
        #expect(plan["mark_read"] as? Int == 1)  // the invoice is already read
        #expect((plan["move"] as? [[String: Any]])?.first?["count"] as? Int == 2)
        #expect((plan["flag"] as? [[String: Any]])?.first?["color"] as? String == "orange")
        #expect((plan["colour"] as? [[String: Any]])?.first?["color"] as? String == "blue")
        #expect(h.automation.calls.isEmpty)
    }

    @Test func appliesThroughTheUsualTools() async throws {
        let json = try await h.json("apply_rules", ["mailbox": "inbox", "account": "iCloud", "dry_run": false])
        #expect(json["dry_run"] == nil && (json["done"] as? [Any])?.isEmpty == false)
        let inbox = MailboxTarget(accountID: h.fixture.icloud, path: "INBOX")
        let archive = MailboxTarget(accountID: h.fixture.icloud, path: "Archive")
        let calls = h.automation.calls
        #expect(calls.contains(.setState([h.id("receipt")], inbox, true, nil, nil)))
        #expect(calls.contains(.setState([h.id("digest")], inbox, nil, nil, .orange)))
        #expect(calls.contains(.setColor([h.id("digest")], inbox, .blue)))
        #expect(calls.contains { if case .move(let ids, inbox, archive) = $0 { Set(ids) == [h.id("invoice"), h.id("receipt")] } else { false } })
        #expect(!calls.contains { if case .trash = $0 { true } else { false } })
        #expect(h.automation.unguardedChanges == 0)
        // The moves went through move_messages: undo_change knows them.
        let changes = try await h.json("undo_change", ["action": "list"])
        #expect((changes["changes"] as? [Any])?.isEmpty == false)
    }

    @Test func namedRulesRunEvenWhenOff() async throws {
        let json = try await h.json("apply_rules", ["rules": ["Off"], "ids": [.int(Int(h.id("kickoff")))]])
        #expect(rule(json, "Off")?["matched"] as? Int == 1)
        #expect((json["plan"] as? [String: Any])?["trash"] as? Int == 1)
        #expect(await h.call("apply_rules", ["rules": ["Nope"], "mailbox": "inbox"]).isError)
        #expect(await h.call("apply_rules", ["rules": ["Shop"]]).isError)  // no mailbox or ids
    }

    @Test func leavesSentAndTrashAlone() async throws {
        let json = try await h.json("apply_rules", ["rules": ["Off"], "ids": [.int(Int(h.id("quote"))), .int(Int(h.id("spam")))]])
        #expect(json["messages"] as? Int == 0 && (json["left_out"] as? String)?.hasPrefix("2 ") == true)
    }

    @Test func matchesLikeMail() {
        let alice = EmailAddress(address: "alice@example.test", name: "Alice Martin")
        func criterion(_ qualifier: String, _ value: String) -> MailCriterion {
            MailCriterion(field: "From", qualifier: qualifier, value: value, children: [], allMustMatch: false)
        }
        // The address or the display name, ignoring case.
        #expect(RuleEvaluator.compare(addresses: [alice], criterion("Contains", "MARTIN")) == .match)
        #expect(RuleEvaluator.compare(addresses: [alice], criterion("BeginsWith", "alice@")) == .match)
        #expect(RuleEvaluator.compare(addresses: [alice], criterion("EndsWith", "example.test")) == .match)
        #expect(RuleEvaluator.compare(addresses: [alice], criterion("IsEqualTo", "alice martin")) == .match)
        #expect(RuleEvaluator.compare(addresses: [alice], criterion("IsEqualTo", "alice")) == .noMatch)
        #expect(RuleEvaluator.compare(addresses: [alice], criterion("DoesNotContain", "bob")) == .match)
        #expect(RuleEvaluator.compare(addresses: [alice], criterion("DoesNotContain", "alice")) == .noMatch)
        let unsupported = MailRule(
            id: "x", name: "x", enabled: true, allMustMatch: true,
            criteria: [MailCriterion(field: "PriorityIsHigh", qualifier: "Contains", value: nil, children: [], allMustMatch: false)], actions: [])
        #expect(RuleEvaluator.unsupported(unsupported)?.contains("PriorityIsHigh") == true)
    }
}
