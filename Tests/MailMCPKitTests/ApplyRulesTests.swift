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
        let moved = calls.flatMap { call -> [Int64] in if case .move(let ids, inbox, archive) = call { ids } else { [] } }
        #expect(Set(moved) == [h.id("invoice"), h.id("receipt")])
        #expect(!calls.contains { if case .trash = $0 { true } else { false } })
        #expect(h.automation.unguardedChanges == 0)
        // The moves went through move_messages: undo_change knows them.
        let changes = try await h.json("undo_change", ["action": "list"])
        #expect((changes["changes"] as? [Any])?.isEmpty == false)
    }

    @Test func waitsWhileAMailboxIsPaused() async throws {
        // A trash in the inbox just left a message Mail never confirmed.
        let digest = h.id("digest")
        let live = try h.toolbox.store.liveCount(mailboxID: h.fixture.inbox)
        h.toolbox.breaker?.trip(ChangeBreaker.Entry(
            mailboxID: h.fixture.inbox, accountID: h.fixture.icloud, mailbox: "INBOX", tripped: Date(), pending: [digest], count: live,
            collateral: false))
        let result = await h.call("apply_rules", ["mailbox": "inbox", "account": "iCloud", "dry_run": false])
        #expect(result.isError && result.text.contains("has not settled"))
        // Nothing at all happened, not even the marks and flags that come first.
        #expect(h.automation.calls.isEmpty)
    }

    @Test func asksOnceForTheWholeRun() async throws {
        var settings = Harness.sendingAllowed
        settings.approveChangesAbove = 1
        let strict = try Harness(settings: settings)
        defer { strict.remove() }
        let fixture = strict.fixture
        let boxes = ["INBOX": fixture.inbox, "Archive": fixture.archive]
        strict.automation.onMove = { ids, target in for id in ids { _ = try? fixture.store.moveMessage(id, to: boxes[target.path]!) } }
        try fixture.store.writeMailData("SyncedRules.plist", plist: [[
            "RuleId": "R1", "RuleName": "Shop", "Criteria": [["Header": "From", "Expression": "shop.test", "Qualifier": "EndsWith"]],
            "ShouldTransferMessage": true, "MailboxURL": "imap://\(fixture.icloud)/Archive", "MarkRead": true,
        ]])
        try fixture.store.writeMailData("RulesActiveState.plist", plist: ["R1": true])

        let refused = await strict.call("apply_rules", ["mailbox": "inbox", "account": "iCloud", "dry_run": false])
        #expect(refused.isError && refused.text.contains("menu bar app") && strict.automation.calls.isEmpty)

        strict.approvals.beat()
        let approvals = strict.approvals
        let agent = Task { () -> [ApprovalRequest] in
            var seen: [ApprovalRequest] = []
            for _ in 0..<150 {
                for request in approvals.pending() where !seen.contains(where: { $0.id == request.id }) {
                    try approvals.decide(request.id, approve: true)
                    seen.append(request)
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            return seen
        }
        let json = try await strict.json("apply_rules", ["mailbox": "inbox", "account": "iCloud", "dry_run": false])
        let requests = try await agent.value
        #expect(requests.count == 1)
        #expect(requests.first?.subject == "Apply rule \"Shop\" to 2 messages" && requests.first?.bodyPreview.contains("Shop: 2") == true)
        #expect((json["done"] as? [Any])?.isEmpty == false)
        #expect(strict.automation.calls.contains { if case .move = $0 { true } else { false } })
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
