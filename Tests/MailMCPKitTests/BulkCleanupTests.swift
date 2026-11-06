import Foundation
import MCP
import MailAutomation
import MailFixtures
import MailStore
import Testing

@testable import MailMCPKit

/// What a 35,000-message cleanup of Archive year folders ran into (macOS 27.2, Mail 16.0, 0.7.1): Trash gaining rows
/// the batch did not explain, ids Mail cannot find, and slow `whose message id` lookups in mid-size mailboxes.
@Suite("Bulk cleanups")
final class BulkCleanupTests {
    let h: Harness
    init() throws { h = try Harness() }
    deinit { h.remove() }

    /// A row Mail puts in Trash that nobody asked this call for.
    func arrival(header: String, received: Date) -> @Sendable () -> Void {
        let fixture = h.fixture
        return {
            var message = FixtureMessage(
                subject: "Arrival", from: EmailAddress(address: "news@bulk.test"), to: [StandardFixture.me], date: received,
                mailbox: fixture.trash, body: "")
            message.messageID = header
            _ = try? fixture.store.addMessage(message)
        }
    }

    func header(_ name: String) throws -> String { try #require(try h.toolbox.store.message(id: h.id(name)).messageIDHeader) }

    @Test func lateCopyOfAnEarlierTrashIsNotCollateral() async throws {
        h.trashWorks()
        let receiptHeader = try header("receipt")
        _ = try await h.json("trash_messages", ["ids": [.int(Int(h.id("receipt")))]])
        // Minutes later, during the next batch, Mail brings back a copy of the receipt into Trash.
        h.trashWorks(then: arrival(header: receiptHeader, received: h.fixture.now.addingTimeInterval(-10 * 86_400)))
        let json = try await h.json("trash_messages", ["ids": [.int(Int(h.id("digest")))]])
        #expect(json["trashed"] as? Int == 1)
        #expect(json["collateral_suspected"] == nil && json["warning"] == nil)
    }

    @Test func newMailDeletedOnAnotherDeviceIsNotCollateral() async throws {
        h.trashWorks(then: arrival(header: "fresh@bulk.test", received: Date().addingTimeInterval(-300)))
        let json = try await h.json("trash_messages", ["ids": [.int(Int(h.id("digest"))), .int(Int(h.id("receipt")))]])
        #expect(json["trashed"] as? Int == 2)
        #expect(json["collateral_suspected"] == nil)
    }

    @Test func anotherSourceMessageInTrashIsCollateral() async throws {
        // Mail copies the invoice into Trash (it stays in the inbox): recent or not, it came from the source.
        let invoiceHeader = try header("invoice")
        h.trashWorks(then: arrival(header: invoiceHeader, received: Date()))
        let json = try await h.json("trash_messages", ["ids": [.int(Int(h.id("digest")))]])
        // Counted as asked, but the call stops and the inbox is paused.
        #expect(json["trashed"] as? Int == 1)
        #expect((json["warning"] as? String)?.contains("Stop all bulk changes") == true)
        #expect((json["warning"] as? String)?.contains("collateral_suspected.unexpected") == true)
        let collateral = try #require(json["collateral_suspected"] as? [String: Any])
        #expect(collateral["mailbox"] as? String == "Deleted Messages")
        #expect(collateral["expected_gain"] as? Int == 1 && collateral["actual_gain"] as? Int == 2)
        #expect(collateral["explained_gain"] == nil)
        let unexpected = try #require(collateral["unexpected"] as? [[String: Any]])
        #expect(unexpected.count == 1)
        #expect(unexpected[0]["header"] as? String == invoiceHeader && unexpected[0]["reason"] as? String == "from_source")
    }

    @Test func oldUnknownMailInTrashIsCollateral() async throws {
        h.trashWorks(then: arrival(header: "old@bulk.test", received: h.fixture.now.addingTimeInterval(-400 * 86_400)))
        let json = try await h.json("trash_messages", ["ids": [.int(Int(h.id("digest")))]])
        let collateral = try #require(json["collateral_suspected"] as? [String: Any])
        let unexpected = try #require(collateral["unexpected"] as? [[String: Any]])
        #expect(unexpected.map { $0["reason"] as? String } == ["unexplained"])
        #expect(unexpected[0]["header"] as? String == "old@bulk.test")
    }

    @Test func explainedRowsDoNotHideCollateral() async throws {
        // New mail and a stray copy at once: the new mail is explained, the copy still stops the call.
        let invoiceHeader = try header("invoice")
        let fresh = arrival(header: "fresh@bulk.test", received: Date()), copy = arrival(header: invoiceHeader, received: Date())
        h.trashWorks(then: { fresh(); copy() })
        let json = try await h.json("trash_messages", ["ids": [.int(Int(h.id("digest")))]])
        let collateral = try #require(json["collateral_suspected"] as? [String: Any])
        #expect(collateral["actual_gain"] as? Int == 3 && collateral["explained_gain"] as? Int == 1)
        #expect((collateral["unexpected"] as? [[String: Any]])?.map { $0["header"] as? String } == [invoiceHeader])
    }

    @Test func lateCopyFromAnEarlierStepOfTheCallIsNotCollateral() async throws {
        // One call over two mailboxes: while the inbox step runs, Mail brings back a copy of the archived message.
        let archivedHeader = try header("archived")
        let fixture = h.fixture
        let copy = arrival(header: archivedHeader, received: h.fixture.now.addingTimeInterval(-2_000 * 86_400))
        h.automation.onTrash = { ids, mailbox in
            for id in ids { _ = try? fixture.store.moveMessage(id, to: fixture.trash) }
            if mailbox.path == "INBOX" { copy() }
        }
        let json = try await h.json("trash_messages", ["ids": [.int(Int(h.id("archived"))), .int(Int(h.id("digest")))]])
        #expect(json["trashed"] as? Int == 2)
        #expect(json["collateral_suspected"] == nil)
    }

    @Test func headerlessRowsBeyondTheRequestedOnesAreCollateral() async throws {
        let receipt = h.id("receipt")
        try h.fixture.store.setMessageIDHeader(receipt, to: nil)
        let fixture = h.fixture
        // Alone in its call, the receipt goes by id; Mail also drops an old message without a Message-ID in Trash.
        h.trashWorks(then: {
            var message = FixtureMessage(
                subject: "Nameless", from: EmailAddress(address: "x@bulk.test"), to: [StandardFixture.me],
                date: fixture.now.addingTimeInterval(-400 * 86_400), mailbox: fixture.trash, body: "")
            message.messageID = "nameless@bulk.test"
            if let row = try? fixture.store.addMessage(message) { try? fixture.store.setMessageIDHeader(row, to: nil) }
        })
        let json = try await h.json("trash_messages", ["ids": [.int(Int(receipt))]])
        #expect(json["trashed"] as? Int == 1)
        let unexpected = try #require((json["collateral_suspected"] as? [String: Any])?["unexpected"] as? [[String: Any]])
        #expect(unexpected.count == 1 && unexpected[0]["header"] == nil && unexpected[0]["reason"] as? String == "unexplained")
    }

    @Test func moveFlagsSourceMessagesCopiedToTheDestination() async throws {
        let fixture = h.fixture
        let invoiceHeader = try header("invoice")
        h.automation.onMove = { ids, _ in
            for id in ids { _ = try? fixture.store.moveMessage(id, to: fixture.archive) }
            var copy = FixtureMessage(
                subject: "Invoice 42", from: EmailAddress(address: "carol@example.test"), to: [StandardFixture.me],
                date: Date(), mailbox: fixture.archive, body: "")
            copy.messageID = invoiceHeader
            _ = try? fixture.store.addMessage(copy)
        }
        let json = try await h.json("move_messages", ["ids": [.int(Int(h.id("digest")))], "to_mailbox": "Archive"])
        let collateral = try #require(json["collateral_suspected"] as? [String: Any])
        #expect(collateral["mailbox"] as? String == "Archive")
        #expect((collateral["unexpected"] as? [[String: Any]])?.map { $0["reason"] as? String } == ["from_source"])
    }

    @Test func aSlowMessageEndsTheCall() async throws {
        let fixture = h.fixture
        h.automation.eventTimeout = 0.2
        // Mail takes more than half its event timeout for the first message: it is falling behind.
        h.automation.onTrash = { ids, _ in
            Thread.sleep(forTimeInterval: 0.15)
            for id in ids { _ = try? fixture.store.moveMessage(id, to: fixture.trash) }
        }
        let digest = h.id("digest"), receipt = h.id("receipt")
        let json = try await h.json("trash_messages", ["ids": [.int(Int(digest)), .int(Int(receipt))]])
        #expect(json["trashed"] as? Int == 1)
        #expect(json["resume_ids"] as? [Int] == [Int(receipt)])
        #expect(json["collateral_suspected"] == nil && json["not_attempted"] == nil)
    }

    @Test func messagesMailCannotSeeAreMarked() async throws {
        let receipt = h.id("receipt"), digest = h.id("digest")
        h.trashWorks()
        h.automation.unfound = [receipt]
        let json = try await h.json("trash_messages", ["ids": [.int(Int(receipt)), .int(Int(digest))]])
        #expect(json["trashed"] as? Int == 1)
        #expect(json["not_found"] as? [Int] == [Int(receipt)])
        #expect(json["mail_cannot_see"] as? [Int] == [Int(receipt)])
        #expect(json["rebuild_mailbox"] as? [String] == ["INBOX"])
        #expect((json["warning"] as? String)?.contains("Mailbox › Rebuild") == true)
        // Searches mark it until Mail finds it.
        let search = try await h.json("search_messages", ["mailbox": "INBOX", "limit": 50])
        #expect(search["mail_cannot_see"] as? [Int] == [Int(receipt)])
        #expect((search["notes"] as? [String])?.contains { $0.contains("Rebuild") } == true)
        // Rebuilt: Mail finds it, and the mark goes.
        h.automation.unfound = []
        let again = try await h.json("trash_messages", ["ids": [.int(Int(receipt))]])
        #expect(again["trashed"] as? Int == 1 && again["mail_cannot_see"] == nil)
        #expect(h.toolbox.unseen?.entries.isEmpty == true)
    }

    @Test func menuBarLineNamesTheMailboxToRebuild() async throws {
        let receipt = h.id("receipt"), digest = h.id("digest"), archived = h.id("archived")
        h.trashWorks()
        h.automation.unfound = [receipt, digest, archived]
        _ = try await h.json("trash_messages", ["ids": [.int(Int(receipt)), .int(Int(digest)), .int(Int(archived))]])
        let unseen = try #require(h.toolbox.unseen)
        let mailboxes = try unseen.mailboxes(in: h.toolbox.store)
        #expect(mailboxes.map(\.mailbox) == ["INBOX", "Archive/2020"] && mailboxes.map(\.count) == [2, 1])
        let line = try #require(UnseenMessages.line(for: mailboxes))
        #expect(line.title == "Mail can't see 3 messages")
        #expect(line.detail == "In INBOX, Archive/2020. Select each in Mail and choose Mailbox › Rebuild.")
        let one = try #require(UnseenMessages.line(for: [mailboxes[1]]))
        #expect(one.title == "Mail can't see 1 message" && one.detail.hasPrefix("In Archive/2020. Select it"))
        #expect(UnseenMessages.line(for: []) == nil)
        let check = try #require(Doctor.unseenCheck(mailboxes))
        #expect(check.state == .warning && check.detail.hasPrefix("2 in INBOX (iCloud), 1 in Archive/2020 (iCloud)"))
        #expect(Doctor.unseenCheck([]) == nil)
        // Rebuilt: Mail gives the inbox messages new rows, and the inbox leaves the list without anyone clearing it.
        for id in [receipt, digest] { try h.fixture.store.moveMessage(id, to: h.fixture.inbox) }
        #expect(try unseen.mailboxes(in: h.toolbox.store).map(\.mailbox) == ["Archive/2020"])
        // Two accounts with the same mailbox name are told apart.
        let twins = [
            UnseenMessages.MailboxCount(mailbox: "Archive", account: "iCloud", count: 2),
            UnseenMessages.MailboxCount(mailbox: "Archive", account: "Gmail", count: 1),
        ]
        #expect(UnseenMessages.line(for: twins)?.detail.hasPrefix("In Archive (iCloud), Archive (Gmail). Select each") == true)
        // And entries go once they are old.
        #expect(try unseen.mailboxes(in: h.toolbox.store, now: Date().addingTimeInterval(8 * 86_400)).isEmpty)
        // Dismissed from the menu bar app: gone until a change misses messages again.
        unseen.clear()
        #expect(try unseen.mailboxes(in: h.toolbox.store).isEmpty)
    }

    @Test func headerLookupsStopAtTheCallsBudget() async throws {
        h.trashWorks()
        let inboxCount = try h.toolbox.store.liveCount(mailboxID: h.fixture.inbox)
        // Room for two lookups in the inbox as it is; the inbox only shrinks while the call runs.
        h.toolbox.headerLookupBudget = inboxCount * 2
        let kickoff = h.id("kickoff"), digest = h.id("digest"), receipt = h.id("receipt")
        let json = try await h.json("trash_messages", ["ids": [.int(Int(kickoff)), .int(Int(digest)), .int(Int(receipt))]])
        #expect(json["trashed"] as? Int == 2)
        #expect(json["resume_ids"] as? [Int] == [Int(receipt)])
        #expect(json["not_attempted"] == nil && json["collateral_suspected"] == nil)
        #expect((json["warning"] as? String)?.contains("resume_ids") == true)
        // The next call goes ahead.
        let next = try await h.json("trash_messages", ["ids": [.int(Int(receipt))]])
        #expect(next["trashed"] as? Int == 1)
    }

    @Test func lookupsByIDAreNotBudgeted() async throws {
        h.trashWorks()
        h.toolbox.headerLookupBudget = 1
        h.toolbox.headerLookupLimit = 1
        let json = try await h.json("trash_messages", ["ids": [.int(Int(h.id("kickoff"))), .int(Int(h.id("digest")))]])
        #expect(json["trashed"] as? Int == 2 && json["resume_ids"] == nil)
    }
}
