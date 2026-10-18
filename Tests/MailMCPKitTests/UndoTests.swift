import Foundation
import MCP
import MailAutomation
import MailFixtures
import MailStore
import Testing

@testable import MailMCPKit

@Suite("Undo")
final class UndoTests {
    let h: Harness
    init() throws { h = try Harness() }
    deinit { h.remove() }

    var icloudInbox: MailboxTarget { MailboxTarget(accountID: h.fixture.icloud, path: "INBOX") }

    /// Moves and trashes land in the fixture like Mail records them: a new row in the target mailbox.
    func simulateMail() {
        let fixture = h.fixture
        let boxes = ["INBOX": fixture.inbox, "Archive": fixture.archive, "Deleted Messages": fixture.trash]
        h.automation.onMove = { ids, target in
            for id in ids { _ = try? fixture.store.moveMessage(id, to: boxes[target.path]!) }
        }
        h.automation.onTrash = { ids, _ in
            for id in ids { _ = try? fixture.store.moveMessage(id, to: fixture.trash) }
        }
    }

    @Test func undoesAMove() async throws {
        simulateMail()
        let kickoff = h.id("kickoff")
        let moved = try await h.json("move_messages", ["ids": [.int(Int(kickoff))], "to_mailbox": "archive"])
        let changeID = try #require(moved["change_id"] as? String)
        let newID = Int64((moved["new_ids"] as? [String: Int])?[String(kickoff)] ?? 0)

        let list = try await h.json("undo_change")
        let latest = (list["changes"] as? [[String: Any]])?.first
        #expect(latest?["change_id"] as? String == changeID)
        #expect(latest?["kind"] as? String == "move" && latest?["to"] as? [String] == ["Archive"])

        let dry = try await h.json("undo_change", ["action": "undo", "dry_run": true])
        #expect((dry["would_restore"] as? [[String: Any]])?.first?["ids"] as? [Int] == [Int(newID)])
        #expect(h.automation.calls.count == 1)

        let undone = try await h.json("undo_change", ["action": "undo"])
        #expect(undone["undone"] as? String == changeID && undone["restored"] as? Int == 1)
        let archive = MailboxTarget(accountID: h.fixture.icloud, path: "Archive")
        #expect(h.automation.calls.last == .move([newID], archive, icloudInbox))
        #expect(h.automation.unguardedChanges == 0)

        let again = await h.call("undo_change", ["action": "undo", "change_id": .string(changeID)])
        #expect(again.isError && again.text.contains("already undone"))
        #expect(await h.call("undo_change", ["action": "undo"]).text.contains("Nothing to undo"))
    }

    @Test func undoesATrash() async throws {
        simulateMail()
        let receipt = h.id("receipt")
        let trashed = try await h.json("trash_messages", ["ids": [.int(Int(receipt))]])
        #expect(trashed["trashed"] as? Int == 1 && trashed["change_id"] != nil)
        let undone = try await h.json("undo_change", ["action": "undo"])
        #expect(undone["restored"] as? Int == 1)
        guard case .move(let ids, let from, let to) = h.automation.calls.last else {
            Issue.record("expected a move out of Trash")
            return
        }
        #expect(ids.count == 1 && ids[0] != receipt)
        #expect(from.path == "Deleted Messages" && to == icloudInbox)
    }

    @Test func undoesFlagsAndReadState() async throws {
        let kickoff = h.id("kickoff"), invoice = h.id("invoice")
        // kickoff: unread, no flag. invoice: read, red flag.
        _ = try await h.json("update_messages", ["ids": [.int(Int(kickoff)), .int(Int(invoice))], "read": true, "flag_color": "green"])
        _ = try await h.json("undo_change", ["action": "undo"])
        let restores = h.automation.calls.dropFirst()
        #expect(restores.contains(.setState([kickoff], icloudInbox, false, false, nil)))
        #expect(restores.contains(.setState([invoice], icloudInbox, true, nil, .red)))
        #expect(restores.count == 2)
    }

    @Test func readOnlyStateChangeRestoresOnlyRead() async throws {
        _ = try await h.json("update_messages", ["ids": [.int(Int(h.id("invoice")))], "read": false])
        _ = try await h.json("undo_change", ["action": "undo"])
        #expect(h.automation.calls.last == .setState([h.id("invoice")], icloudInbox, true, nil, nil))
    }

    @Test func journalHoldsNoSubjects() async throws {
        simulateMail()
        _ = try await h.json("move_messages", ["ids": [.int(Int(h.id("invoice")))], "to_mailbox": "archive"])
        let text = try String(contentsOf: h.support.appending(path: "changes.json"), encoding: .utf8)
        #expect(!text.contains("Invoice 42") && !text.contains("carol"))
        let mode = try FileManager.default.attributesOfItem(atPath: h.support.appending(path: "changes.json").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func journalKeepsTheLatestRecords() throws {
        let journal = ChangeJournal(url: h.support.appending(path: "capped.json"), limit: 3)
        for n in 0..<5 {
            journal.record(ChangeRecord(
                id: "c-\(n)", client: nil, tool: "move_messages", kind: .move,
                items: [.init(messageID: "m\(n)@x", accountID: "a", from: "INBOX", to: "Archive")]))
        }
        #expect(journal.records().map(\.id) == ["c-4", "c-3", "c-2"])
    }
}

@Suite("Authenticity tool")
final class AuthenticityToolTests {
    let h: Harness
    init() throws { h = try Harness() }
    deinit { h.remove() }

    @Test func checksFixtureMessages() async throws {
        var forged = FixtureMessage(
            subject: "Verify your account", from: EmailAddress(address: "security@alice-martin.test", name: "alice@example.test"),
            to: [StandardFixture.me], date: Date(), mailbox: h.fixture.inbox, body: "",
            html: #"<a href="https://evil.test/login">https://example.test/account</a>"#)
        forged.extraHeaders = ["Authentication-Results: mx.icloud.test; spf=fail smtp.mailfrom=evil.test; dkim=none; dmarc=fail header.from=alice-martin.test"]
        let id = try h.fixture.store.addMessage(forged)
        let json = try await h.json("check_authenticity", ["ids": [.int(Int(id)), .int(Int(h.id("kickoff"))), .int(Int(h.id("pending")))]])
        let messages = json["messages"] as? [[String: Any]] ?? []
        #expect(messages.count == 3)
        #expect(messages[0]["verdict"] as? String == "fail" && messages[0]["dmarc"] as? String == "fail")
        let codes = (messages[0]["findings"] as? [[String: Any]] ?? []).compactMap { $0["code"] as? String }
        #expect(codes.contains("display_name_spoof") && codes.contains("link_mismatch") && codes.contains("first_contact"))
        // Alice has written before; the fixture records no authentication.
        let kickoffCodes = (messages[1]["findings"] as? [[String: Any]] ?? []).compactMap { $0["code"] as? String }
        #expect(kickoffCodes == ["no_authentication"])
        #expect(messages[2]["note"] as? String != nil)
        #expect(await h.call("check_authenticity", ["ids": []]).isError)
    }
}

@Suite("Contacts")
final class ContactToolTests {
    let h: Harness
    init() throws { h = try Harness() }
    deinit { h.remove() }

    @Test func findsContactsAndCorrespondents() async throws {
        let json = try await h.json("find_contact", ["query": "alice"])
        let cards = json["contacts"] as? [[String: Any]] ?? []
        #expect(cards.first?["name"] as? String == "Alice Martin")
        let people = json["correspondents"] as? [[String: Any]] ?? []
        #expect(people.first?["address"] as? String == "alice@example.test")
        #expect(people.first?["received"] as? Int == 2 && people.first?["sent"] as? Int == 1)
        #expect(people.first?["name"] as? String == "Alice Martin")
    }

    @Test func searchesNamesAndSkipsOwnAddresses() async throws {
        var json = try await h.json("find_contact", ["query": "Billing"])
        #expect((json["correspondents"] as? [[String: Any]])?.compactMap { $0["address"] as? String } == ["carol@shop.test"])
        json = try await h.json("find_contact", ["query": "icloud.test"])
        #expect((json["correspondents"] as? [[String: Any]])?.isEmpty == true)
        #expect(await h.call("find_contact", ["query": "a"]).isError)
    }

    @Test func explainsWhenContactsAreUnavailable() async throws {
        struct Denied: ContactsProviding {
            func search(_ text: String, limit: Int) async -> ContactsLookup { .unavailable("no access") }
        }
        let toolbox = MailToolbox(
            store: try h.fixture.openStore(), automation: h.automation, activity: nil, changes: nil, contacts: Denied())
        let result = await toolbox.call("find_contact", arguments: ["query": "dan"])
        let text = result.content.compactMap { if case .text(let text, _, _) = $0 { text } else { nil } }.joined()
        #expect(text.contains("no access") && text.contains("dan@example.test"))
    }
}

@Suite("Extract fields tool")
final class ExtractFieldsToolTests {
    let h: Harness
    init() throws { h = try Harness() }
    deinit { h.remove() }

    @Test func findsFieldsAndInvites() async throws {
        var shipping = FixtureMessage(
            subject: "Your order has shipped", from: EmailAddress(address: "ship@shop.test"), to: [StandardFixture.me],
            date: Date(), mailbox: h.fixture.inbox, body: "Track your UPS parcel: 1Z999AA10123456784\nOrder number: A12345")
        let shipped = try h.fixture.store.addMessage(shipping)
        shipping.subject = "Invitation: Roadmap review"
        shipping.body = "You are invited."
        shipping.attachments = [("invite.ics", "text/calendar", Data("BEGIN:VCALENDAR\nMETHOD:REQUEST\nBEGIN:VEVENT\nSUMMARY:Roadmap review\nDTSTART:20261020T120000Z\nEND:VEVENT\nEND:VCALENDAR\n".utf8))]
        let invite = try h.fixture.store.addMessage(shipping)
        let json = try await h.json(
            "extract_fields", ["ids": [.int(Int(shipped)), .int(Int(invite)), .int(Int(h.id("kickoff")))]])
        #expect(json["searched"] as? Int == 3 && json["with_fields"] as? Int == 2)
        let messages = json["messages"] as? [[String: Any]] ?? []
        let first = messages.first { ($0["id"] as? NSNumber)?.int64Value == shipped }?["fields"] as? [[String: Any]] ?? []
        #expect(first.contains { $0["kind"] as? String == "tracking" && $0["carrier"] as? String == "UPS" })
        #expect(first.contains { $0["kind"] as? String == "booking" && $0["value"] as? String == "A12345" })
        let event = (messages.first { ($0["id"] as? NSNumber)?.int64Value == invite }?["fields"] as? [[String: Any]])?
            .first { $0["kind"] as? String == "event" }
        #expect(event?["value"] as? String == "Roadmap review" && event?["method"] as? String == "REQUEST")
        let onlyCodes = try await h.json("extract_fields", ["ids": [.int(Int(shipped))], "kinds": ["code"]])
        #expect(onlyCodes["with_fields"] as? Int == 0)
        #expect(await h.call("extract_fields", ["kinds": ["parcels"]]).isError)
    }
}

@Suite("Mail setup tool")
final class MailSetupToolTests {
    let h: Harness
    init() throws { h = try Harness() }
    deinit { h.remove() }

    @Test func readsRulesVIPsSmartMailboxesAndSignatures() async throws {
        let store = h.fixture.store
        let icloud = h.fixture.icloud
        try store.writeMailData("SyncedRules.plist", plist: [[
            "RuleId": "R1", "RuleName": "Newsletters", "AllCriteriaMustBeSatisfied": false, "AutoResponseType": 0,
            "Criteria": [["CriterionUniqueId": "c1", "Header": "From", "Expression": "news@letters.test"],
                         ["CriterionUniqueId": "c2", "Header": "Subject", "Expression": "digest", "Qualifier": "BeginsWith"]],
            "MailboxURL": "imap://\(icloud)/Archive", "CopyToMailboxURL": "imap://\(icloud)/Archive",
            "ShouldTransferMessage": true, "ShouldCopyMessage": false, "MarkRead": true, "MarkFlagged": false,
            "Deletes": false, "StopEvaluatingRules": true, "TimeStamp": 1,
        ]])
        try store.writeMailData("VIPs.plist", plist: ["ABCDEF01-0000-0000-0000-000000000001": ["Name": "Alice", "EmailAddresses": ["alice@example.test"]]])
        try store.writeMailData("SyncedSmartMailboxes.plist", plist: [[
            "MailboxID": "S1", "MailboxName": "Unread work", "MailboxAllCriteriaMustBeSatisfied": true, "MailboxChildren": [],
            "MailboxCriteria": [["CriterionUniqueId": "x", "Header": "NotInTrashMailbox", "Name": "x"],
                                ["CriterionUniqueId": "y", "Header": "From", "Expression": "example.test"]],
        ]])
        try store.writeMailData("Signatures/AllSignatures.plist", plist: [["SignatureUniqueId": "SIG1", "SignatureName": "Work", "SignatureIsRich": true]])
        try store.writeMailData(
            "Signatures/SIG1.mailsignature",
            data: Data("Content-Type: text/html;\n\tcharset=utf-8\nMime-Version: 1.0\n\n<div>Me Myself<br>MP Consulting</div>".utf8))

        let json = try await h.json("mail_setup")
        let rule = (json["rules"] as? [[String: Any]])?.first
        #expect(rule?["name"] as? String == "Newsletters" && rule?["match"] as? String == "any")
        #expect(rule?["actions"] as? [String] == ["move to Archive (iCloud)", "mark as read", "stop evaluating rules"])
        #expect(rule?["enabled"] == nil)
        let criteria = rule?["criteria"] as? [[String: Any]]
        #expect(criteria?[1]["qualifier"] as? String == "BeginsWith" && criteria?[0]["value"] as? String == "news@letters.test")
        #expect((json["vips"] as? [[String: Any]])?.first?["addresses"] as? [String] == ["alice@example.test"])
        #expect((json["smart_mailboxes"] as? [[String: Any]])?.first?["name"] as? String == "Unread work")
        let signature = (json["signatures"] as? [[String: Any]])?.first
        #expect(signature?["name"] as? String == "Work" && (signature?["text"] as? String)?.contains("MP Consulting") == true)

        let onlyVIPs = try await h.json("mail_setup", ["include": ["vips"]])
        #expect(onlyVIPs["rules"] == nil && onlyVIPs["vips"] != nil)
        #expect(await h.call("mail_setup", ["include": ["filters"]]).isError)
    }

    @Test func emptyWhenMailHasNoSettingsFiles() async throws {
        let json = try await h.json("mail_setup")
        #expect((json["rules"] as? [Any])?.isEmpty == true && (json["vips"] as? [Any])?.isEmpty == true)
    }
}

@Suite("Draft tools")
final class DraftToolTests {
    let h: Harness
    init() throws { h = try Harness() }
    deinit { h.remove() }

    func addDraft(_ subject: String, reply: Bool = false) throws -> Int64 {
        var draft = FixtureMessage(
            subject: subject, from: StandardFixture.me, to: [StandardFixture.bob], date: Date(), mailbox: h.fixture.drafts,
            body: "Draft text for Bob")
        draft.cc = [StandardFixture.dan]
        draft.isRead = true
        if reply { draft.inReplyTo = "kickoff@example.test" }
        draft.attachments = [("plan.txt", "text/plain", Data("plan".utf8))]
        return try h.fixture.store.addMessage(draft)
    }

    @Test func listsDraftsWithRecipients() async throws {
        let id = try addDraft("Proposal")
        let json = try await h.json("list_drafts")
        let first = (json["drafts"] as? [[String: Any]])?.first
        #expect((first?["id"] as? NSNumber)?.int64Value == id)
        #expect(first?["to"] as? [String] == ["Bob <bob@example.test>"] && first?["cc"] as? [String] == ["Dan <dan@example.test>"])
    }

    @Test func sendsADraftAndTrashesIt() async throws {
        let id = try addDraft("Proposal")
        let fixture = h.fixture
        h.automation.onTrash = { ids, _ in for id in ids { _ = try? fixture.store.moveMessage(id, to: fixture.trash) } }
        let json = try await h.json("send_draft", ["id": .int(Int(id))])
        #expect(json["result"] as? String == "sent" && json["draft_removed"] as? Bool == true)
        guard case .compose(let message, let mode) = h.automation.calls.first else {
            Issue.record("expected a compose")
            return
        }
        #expect(mode == .send && message.to == ["bob@example.test"] && message.cc == ["dan@example.test"])
        #expect(message.subject == "Proposal" && message.body.contains("Draft text for Bob") && message.attachments.count == 1)
        #expect(h.automation.calls.last == .trash([id], MailboxTarget(accountID: h.fixture.icloud, path: "Drafts")))
    }

    @Test func refusesRepliesAndNonDrafts() async throws {
        let reply = try addDraft("Re: Project kickoff", reply: true)
        let refused = await h.call("send_draft", ["id": .int(Int(reply))])
        #expect(refused.isError && refused.text.contains("open_in_mail"))
        #expect(await h.call("send_draft", ["id": .int(Int(h.id("kickoff")))]).text.contains("not in a Drafts mailbox"))
        #expect(h.automation.calls.isEmpty)
    }

    @Test func neverPolicyBlocksSendingDrafts() async throws {
        var settings = Settings()
        settings.sendPolicy = .never
        let locked = try Harness(settings: settings)
        defer { locked.remove() }
        var draft = FixtureMessage(
            subject: "Hold", from: StandardFixture.me, to: [StandardFixture.bob], date: Date(), mailbox: locked.fixture.drafts, body: "x")
        draft.isRead = true
        let id = try locked.fixture.store.addMessage(draft)
        #expect(await locked.call("send_draft", ["id": .int(Int(id))]).text.contains("Sending is turned off"))
        #expect(locked.automation.calls.isEmpty)
    }
}
