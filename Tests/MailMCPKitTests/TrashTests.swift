import Foundation
import MCP
import MailAutomation
import MailFixtures
import MailStore
import Testing

@testable import MailMCPKit

/// After 0.6.1, `delete` by Message-ID still removed the neighbour of some messages: Cocoa scripting removes what a
/// delete resolves by index. Trashing is a move to the account's Trash, counted once the message shows up there.
@Suite("Trash by moving to Trash")
final class TrashTests {
    let h: Harness
    init() throws { h = try Harness() }
    deinit { h.remove() }

    var icloudInbox: MailboxTarget { MailboxTarget(accountID: h.fixture.icloud, path: "INBOX") }
    var icloudTrash: MailboxTarget { MailboxTarget(accountID: h.fixture.icloud, path: "Deleted Messages") }

    /// Mail carrying out every trash as asked.
    func trashWorks() {
        let fixture = h.fixture
        h.automation.onTrash = { ids, _ in for id in ids { _ = try? fixture.store.moveMessage(id, to: fixture.trash) } }
    }

    func deletes() -> [RecordingAutomation.Call] {
        h.automation.calls.filter { if case .delete = $0 { true } else { false } }
    }

    @Test func trashMovesToTrashMailbox() async throws {
        trashWorks()
        let receipt = h.id("receipt"), archived = h.id("archived")
        let json = try await h.json("trash_messages", ["ids": [.int(Int(receipt)), .int(Int(archived))]])
        #expect(json["trashed"] as? Int == 2)
        #expect(h.automation.calls == [
            .trash([receipt], icloudInbox, icloudTrash),
            .trash([archived], MailboxTarget(accountID: h.fixture.icloud, path: "Archive/2020"), icloudTrash),
        ])
        // Journalled with the Trash it went to, for undo_change.
        let record = try #require(h.toolbox.changes?.records().first { $0.id == json["change_id"] as? String })
        #expect(record.kind == .trash && Set(record.items.map(\.to)) == ["Deleted Messages"])
    }

    @Test func noDeleteEventForMessages() async throws {
        trashWorks()
        let json = try await h.json("trash_messages", ["ids": [.int(Int(h.id("receipt"))), .int(Int(h.id("kickoff"))), .int(Int(h.id("archived")))]])
        #expect(json["trashed"] as? Int == 3)
        #expect(deletes().isEmpty)
        #expect(h.automation.calls.contains { if case .trash = $0 { true } else { false } })
    }

    @Test func trashCountsOnlyArrived() async throws {
        // Mail takes the receipt out of the inbox, but it never shows up in Trash.
        let fixture = h.fixture
        let receipt = h.id("receipt"), digest = h.id("digest")
        h.automation.onTrash = { ids, _ in for id in ids { _ = try? fixture.store.moveMessage(id, to: fixture.archive) } }
        let json = try await h.json("trash_messages", ["ids": [.int(Int(receipt)), .int(Int(digest))]])
        #expect(json["trashed"] as? Int == 0)
        #expect(json["unverified"] as? [Int] == [Int(receipt)])
        #expect(json["not_attempted"] as? [Int] == [Int(digest)])
        #expect(h.automation.calls == [.trash([receipt], icloudInbox, icloudTrash)])
    }

    @Test func trashRefusesWithoutSingleTrash() async throws {
        let fixture = h.fixture
        // A second Trash, empty: Mail's is the one holding messages.
        let other = try fixture.store.addMailbox(accountID: fixture.icloud, path: "Trash")
        trashWorks()
        let first = try await h.json("trash_messages", ["ids": [.int(Int(h.id("receipt")))]])
        #expect(first["trashed"] as? Int == 1)
        #expect(h.automation.calls == [.trash([h.id("receipt")], icloudInbox, icloudTrash)])
        // Both hold messages: which one Mail uses is not clear, so nothing is sent.
        _ = try fixture.store.addMessage(FixtureMessage(
            subject: "Old", from: EmailAddress(address: "x@example.test"), to: [], date: Date(), mailbox: other, body: "x"))
        let refused = await h.call("trash_messages", ["ids": [.int(Int(h.id("digest")))]])
        #expect(refused.isError && refused.text.contains("several Trash mailboxes") && refused.text.contains("move_messages"))
        let dryRun = await h.call("trash_messages", ["ids": [.int(Int(h.id("digest")))], "dry_run": true])
        #expect(dryRun.isError)
        // An account without any Trash.
        let local = try fixture.store.addMailbox(accountID: fixture.local, path: "Projects", scheme: "local")
        let note = try fixture.store.addMessage(FixtureMessage(
            subject: "Note", from: EmailAddress(address: "x@example.test"), to: [], date: Date(), mailbox: local, body: "x"))
        let none = await h.call("trash_messages", ["ids": [.int(Int(note))]])
        #expect(none.isError && none.text.contains("has no Trash mailbox"))
        #expect(h.automation.calls.count == 1 && deletes().isEmpty)
    }

    @Test func gmailKeepsMailsDelete() async throws {
        let gmail = h.id("gmail")
        let fixture = h.fixture
        // Out of All Mail (where Gmail's Trash goes is not modelled here).
        h.automation.onTrash = { ids, _ in for id in ids { _ = try? fixture.store.moveMessage(id, to: fixture.gmailSent) } }
        let json = try await h.json("trash_messages", ["ids": [.int(Int(gmail))]])
        #expect(json["trashed"] as? Int == 1)
        #expect(h.automation.calls == [.delete([gmail], MailboxTarget(accountID: fixture.gmail, path: "[Gmail]/Tous les messages"))])
    }

    @Test func mailChangesReportTheServerVersion() async throws {
        trashWorks()
        let json = try await h.json("trash_messages", ["ids": [.int(Int(h.id("receipt")))]])
        #expect(json["server_version"] as? String == MailMCPVersion.build)
        // Reads stay as they were.
        #expect(try await h.json("list_accounts")["server_version"] == nil)
        let log = try #require(h.toolbox.activity)
        #expect(log.recent(limit: 5).allSatisfy { $0.version == MailMCPVersion.build })
    }
}

@Suite("Server versions")
struct ServerVersionTests {
    @Test func olderVersionsCompareNumerically() {
        #expect(MailMCPVersion.isOlder("0.6.1+abc", than: "0.6.2"))
        #expect(MailMCPVersion.isOlder("0.6.9", than: "0.6.10"))
        #expect(MailMCPVersion.isOlder(nil, than: "0.6.2"))
        #expect(!MailMCPVersion.isOlder("0.6.2+abc.mcpb", than: "0.6.2"))
        #expect(!MailMCPVersion.isOlder("0.7.0+dev", than: "0.6.2"))
        #expect(MailMCPVersion.build.hasPrefix(MailMCPVersion.current + "+"))
    }

    @Test func clientsOnAnOlderServerAreNamed() {
        let now = Date()
        func entry(_ client: String, _ version: String?, minutesAgo: Double) -> ActivityEntry {
            ActivityEntry(
                date: now.addingTimeInterval(-minutesAgo * 60), pid: 1, client: client, tool: "search_messages", ok: true, milliseconds: 1,
                summary: "", isWrite: false, version: version)
        }
        let entries = [
            entry("Claude", "0.6.0", minutesAgo: 90), entry("Claude", nil, minutesAgo: 10),
            entry("Claude Code", "0.6.1+abc", minutesAgo: 120), entry("Claude Code", "0.6.2+abc", minutesAgo: 5),
            entry("Cursor", "0.6.1", minutesAgo: 200),
        ]
        let older = ActivityEntry.clientsOnOlderServer(in: entries, current: "0.6.2", now: now)
        #expect(older.map(\.client) == ["Claude"] && older.first?.version == nil)
        let checks = Doctor.clientChecks(entries, current: "0.6.2", now: now)
        #expect(checks.map(\.name) == ["Clients", "Older server"])
        #expect(checks.last?.detail.contains("Claude ran a version before 0.6.2") == true)
        #expect(checks.first?.detail.contains("Claude Code: 0.6.2+abc") == true)
        #expect(checks.first?.detail.contains("Claude: before 0.6.2") == true)
    }

    @Test func doctorCountsCopiesLeftInTrash() throws {
        let fixture = try StandardFixture.make()
        defer { fixture.store.remove() }
        let store = try fixture.openStore()
        #expect(try Doctor.trashCopies(store).isEmpty)
        // A message moved out of Trash whose old row came back.
        _ = try fixture.store.addMessage({
            var ghost = FixtureMessage(
                subject: "Project kickoff", from: EmailAddress(address: "alice@example.test"), to: [], date: Date(), mailbox: fixture.trash,
                body: "x")
            ghost.messageID = "kickoff@example.test"
            return ghost
        }())
        let copies = try Doctor.trashCopies(try fixture.openStore())
        #expect(copies.count == 1 && copies.first?.count == 1)
    }
}
