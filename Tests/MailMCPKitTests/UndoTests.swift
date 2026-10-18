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
