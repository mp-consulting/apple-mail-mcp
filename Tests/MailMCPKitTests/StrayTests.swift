import Foundation
import MCP
import MailAutomation
import MailStore
import Testing

@testable import MailMCPKit

/// The 2026-10-20 incident: bulk trashes on busy IMAP mailboxes removed the date-neighbour of a requested message
/// instead of the message itself, and calls ran past the client's timeout.
@Suite("Bulk changes on a busy mailbox")
final class StrayTests {
    let h: Harness
    init() throws { h = try Harness() }
    deinit { h.remove() }

    var icloudInbox: MailboxTarget { MailboxTarget(accountID: h.fixture.icloud, path: "INBOX") }
    var icloudTrash: MailboxTarget { MailboxTarget(accountID: h.fixture.icloud, path: "Deleted Messages") }

    static var keepStrays: Settings {
        var settings = Harness.sendingAllowed
        settings.restoreStrays = false
        return settings
    }

    /// Mail in "shift" mode: asked to trash a message, it trashes the next older one in the list instead.
    func shift(_ harness: Harness, _ neighbours: [Int64: Int64]) {
        let fixture = harness.fixture
        harness.automation.onTrash = { ids, _ in
            for id in ids { if let neighbour = neighbours[id] { _ = try? fixture.store.moveMessage(neighbour, to: fixture.trash) } }
        }
    }

    /// Mail carrying out moves as asked.
    func movesWork(_ harness: Harness) {
        let fixture = harness.fixture
        let boxes = ["INBOX": fixture.inbox, "Archive": fixture.archive, "Deleted Messages": fixture.trash]
        harness.automation.onMove = { ids, target in for id in ids { _ = try? fixture.store.moveMessage(id, to: boxes[target.path]!) } }
    }

    func trashHeaders(_ harness: Harness) throws -> [String] {
        try harness.toolbox.store.headerRows(mailboxID: harness.fixture.trash).values.sorted()
    }

    @Test func messagesAreAddressedByMessageID() async throws {
        let fixture = h.fixture
        h.automation.onTrash = { ids, _ in for id in ids { _ = try? fixture.store.moveMessage(id, to: fixture.trash) } }
        let json = try await h.json("trash_messages", ["ids": [.int(Int(h.id("kickoff"))), .int(Int(h.id("receipt")))]])
        #expect(json["trashed"] as? Int == 2)
        // One event per message, each by its Message-ID.
        #expect(h.automation.calls == [.trash([h.id("kickoff")], icloudInbox, icloudTrash), .trash([h.id("receipt")], icloudInbox, icloudTrash)])
        #expect(h.automation.refs.map(\.header) == ["kickoff@example.test", try h.toolbox.store.message(id: h.id("receipt")).messageIDHeader])
    }

    @Test func messagesWithoutAUniqueMessageIDGoOneByOne() async throws {
        let fixture = h.fixture
        let receipt = h.id("receipt"), digest = h.id("digest"), invoice = h.id("invoice")
        try fixture.store.setMessageIDHeader(receipt, to: nil)
        // Two rows in the inbox with the same Message-ID: `whose` would match both.
        try fixture.store.setMessageIDHeader(invoice, to: "kickoff@example.test")
        h.automation.onTrash = { ids, _ in for id in ids { _ = try? fixture.store.moveMessage(id, to: fixture.trash) } }
        let json = try await h.json("trash_messages", ["ids": [.int(Int(receipt)), .int(Int(digest)), .int(Int(invoice))]])
        #expect(json["trashed"] as? Int == 1)
        #expect(json["retry_one_by_one"] as? [Int] == [Int(receipt), Int(invoice)])
        #expect((json["warning"] as? String)?.contains("call of its own") == true)
        #expect(h.automation.calls == [.trash([digest], icloudInbox, icloudTrash)])
        // Alone in its call, it goes by id, with the subject and date Mail must show there.
        let alone = try await h.json("trash_messages", ["ids": [.int(Int(receipt))]])
        #expect(alone["trashed"] as? Int == 1)
        let ref = try #require(h.automation.refs.last)
        let subject = try h.toolbox.store.message(id: receipt).subject
        #expect(ref.id == receipt && ref.header == nil && ref.subject == subject)
    }

    @Test func trashNamesStrays() async throws {
        let h = try Harness(settings: Self.keepStrays)
        defer { h.remove() }
        let receipt = h.id("receipt"), digest = h.id("digest"), invoice = h.id("invoice")
        shift(h, [receipt: digest])
        let json = try await h.json("trash_messages", ["ids": [.int(Int(receipt)), .int(Int(invoice))]])
        #expect(json["trashed"] as? Int == 0)
        #expect(json["unverified"] as? [Int] == [Int(receipt)])
        #expect(json["not_attempted"] as? [Int] == [Int(invoice)])
        let collateral = try #require(json["collateral_suspected"] as? [String: Any])
        let strays = try #require(collateral["strays"] as? [[String: Any]])
        #expect(strays.count == 1)
        #expect(strays[0]["old_id"] as? Int == Int(digest))
        #expect(strays[0]["header"] as? String == (try h.toolbox.store.message(id: digest)).messageIDHeader)
        #expect(strays[0]["from"] as? String == "INBOX" && strays[0]["now_in"] as? String == "Deleted Messages")
        #expect((strays[0]["new_id"] as? Int).map(Int64.init) ?? 0 > digest)
        #expect(json["strays_restored"] == nil)
        // The stray is journalled on its own, ready for undo_change.
        let changeID = try #require(json["stray_change_id"] as? String)
        let record = try #require(h.toolbox.changes?.records().first { $0.id == changeID })
        #expect(record.stray == true && record.kind == .move && record.undone == nil)
        #expect(record.items.map(\.from) == ["INBOX"] && record.items.map(\.to) == ["Deleted Messages"])
    }

    @Test func straysAreRestored() async throws {
        let receipt = h.id("receipt"), digest = h.id("digest")
        let digestHeader = try #require(try h.toolbox.store.message(id: digest).messageIDHeader)
        shift(h, [receipt: digest])
        movesWork(h)
        let json = try await h.json("trash_messages", ["ids": [.int(Int(receipt))]])
        #expect(json["strays_restored"] as? Int == 1)
        let stray = try #require(((json["collateral_suspected"] as? [String: Any])?["strays"] as? [[String: Any]])?.first)
        let back = try #require((stray["restored_id"] as? Int).map(Int64.init))
        let restored = try h.toolbox.store.message(id: back)
        #expect(restored.mailboxPath == "INBOX" && restored.messageIDHeader == digestHeader)
        #expect(!(try trashHeaders(h)).contains(digestHeader))
        #expect((json["warning"] as? String)?.contains("they were put back") == true)
        // The restore went by Message-ID, out of Trash.
        #expect(h.automation.refs.last?.header == digestHeader)
        // Journalled, and already undone.
        let record = h.toolbox.changes?.records().first { $0.id == json["stray_change_id"] as? String }
        #expect(record?.stray == true && record?.undone != nil)
    }

    @Test func strayChangeIsUndoable() async throws {
        let h = try Harness(settings: Self.keepStrays)
        defer { h.remove() }
        let receipt = h.id("receipt"), digest = h.id("digest")
        let digestHeader = try #require(try h.toolbox.store.message(id: digest).messageIDHeader)
        shift(h, [receipt: digest])
        let json = try await h.json("trash_messages", ["ids": [.int(Int(receipt))]])
        let changeID = try #require(json["stray_change_id"] as? String)
        #expect(try trashHeaders(h).contains(digestHeader))
        movesWork(h)
        // Out of Trash, so the paused inbox does not stand in the way.
        let undo = try await h.json("undo_change", ["action": "undo", "change_id": .string(changeID)])
        #expect(undo["restored"] as? Int == 1)
        #expect(!(try trashHeaders(h)).contains(digestHeader))
        #expect(h.toolbox.changes?.records().first { $0.id == changeID }?.undone != nil)
    }

    @Test func callBudgetStopsEarly() async throws {
        var settings = Harness.sendingAllowed
        settings.callBudget = 1
        let h = try Harness(settings: settings)
        defer { h.remove() }
        let fixture = h.fixture
        // Mail takes a second per message: the second one would not fit in the budget.
        h.automation.onTrash = { ids, _ in
            Thread.sleep(forTimeInterval: 1)
            for id in ids { _ = try? fixture.store.moveMessage(id, to: fixture.trash) }
        }
        let receipt = h.id("receipt"), digest = h.id("digest")
        let json = try await h.json("trash_messages", ["ids": [.int(Int(receipt)), .int(Int(digest))]])
        #expect(json["trashed"] as? Int == 1)
        #expect(json["resume_ids"] as? [Int] == [Int(digest)])
        #expect(json["not_attempted"] == nil && json["collateral_suspected"] == nil)
        #expect((json["warning"] as? String)?.contains("resume_ids") == true)
        // Running out of time is not a problem with the mailbox: the next call goes ahead.
        let next = try await h.json("trash_messages", ["ids": [.int(Int(digest))]])
        #expect(next["trashed"] as? Int == 1)
    }

    @Test func cancellationStopsLoop() async throws {
        let fixture = h.fixture
        h.automation.onTrash = { ids, _ in
            for id in ids { _ = try? fixture.store.moveMessage(id, to: fixture.trash) }
            // The client gives up while Mail handles the first message.
            withUnsafeCurrentTask { $0?.cancel() }
        }
        let receipt = h.id("receipt"), digest = h.id("digest"), invoice = h.id("invoice")
        let harness = h
        let result = await Task { await harness.call("trash_messages", ["ids": [.int(Int(receipt)), .int(Int(digest)), .int(Int(invoice))]]) }.value
        let json = try JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any] ?? [:]
        #expect(json["trashed"] as? Int == 1)
        #expect(json["not_attempted"] as? [Int] == [Int(digest), Int(invoice)])
        #expect(h.automation.calls == [.trash([receipt], icloudInbox, icloudTrash)])
        // What was done is journalled even so.
        #expect(json["change_id"] as? String != nil)
    }

    @Test func breakerBlocksNextBatch() async throws {
        // Mail never acts on the digest.
        let digest = h.id("digest"), receipt = h.id("receipt"), invoice = h.id("invoice")
        let first = try await h.json("trash_messages", ["ids": [.int(Int(digest))]])
        #expect(first["unverified"] as? [Int] == [Int(digest)])
        let fixture = h.fixture
        h.automation.onTrash = { ids, _ in for id in ids { _ = try? fixture.store.moveMessage(id, to: fixture.trash) } }
        let trash = await h.call("trash_messages", ["ids": [.int(Int(receipt))]])
        #expect(trash.isError && trash.text.contains("has not settled"))
        let move = await h.call("move_messages", ["ids": [.int(Int(invoice))], "to_mailbox": "archive"])
        #expect(move.isError && move.text.contains("INBOX"))
        #expect(h.automation.calls == [.trash([digest], icloudInbox, icloudTrash)])
        // Other mailboxes are not affected.
        let archived = try await h.json("trash_messages", ["ids": [.int(Int(h.id("archived")))]])
        #expect(archived["trashed"] as? Int == 1)
    }

    @Test func breakerClearsWhenSettled() async throws {
        let digest = h.id("digest"), receipt = h.id("receipt"), kickoff = h.id("kickoff")
        _ = try await h.json("trash_messages", ["ids": [.int(Int(digest))]])
        let fixture = h.fixture
        // Mail did trash the digest after all, and something else too: nobody asked for that.
        try fixture.store.moveMessage(digest, to: fixture.trash)
        try fixture.store.moveMessage(kickoff, to: fixture.trash)
        let late = await h.call("trash_messages", ["ids": [.int(Int(receipt))]])
        #expect(late.isError && late.text.contains("1 more messages left INBOX"))
        // The user put it back: settled.
        try fixture.store.moveMessage(try #require(try h.toolbox.store.messages(messageIDHeaders: ["kickoff@example.test"], mailboxIDs: [fixture.trash]).first).id, to: fixture.inbox)
        h.automation.onTrash = { ids, _ in for id in ids { _ = try? fixture.store.moveMessage(id, to: fixture.trash) } }
        let next = try await h.json("trash_messages", ["ids": [.int(Int(receipt))]])
        #expect(next["trashed"] as? Int == 1)
        #expect(h.toolbox.breaker?.entries.isEmpty == true)
    }

    @Test func breakerLetsGoOfMessagesThatStayPut() async throws {
        let digest = h.id("digest"), receipt = h.id("receipt")
        _ = try await h.json("trash_messages", ["ids": [.int(Int(digest))]])
        #expect(await h.call("trash_messages", ["ids": [.int(Int(receipt))]]).isError)
        // The digest is still there, and the mailbox stayed as it was for the quiet period.
        h.toolbox.breaker?.quiet = 0
        let fixture = h.fixture
        h.automation.onTrash = { ids, _ in for id in ids { _ = try? fixture.store.moveMessage(id, to: fixture.trash) } }
        let next = try await h.json("trash_messages", ["ids": [.int(Int(receipt))]])
        #expect(next["trashed"] as? Int == 1)
    }

    @Test func activityShowsCallsWhileTheyRun() async throws {
        let log = try #require(h.toolbox.activity)
        let fixture = h.fixture
        h.automation.onTrash = { ids, _ in
            // Mid-call: the call is in the log already.
            log.flush()
            #expect(log.recent(limit: 5).first?.running == true)
            for id in ids { _ = try? fixture.store.moveMessage(id, to: fixture.trash) }
        }
        _ = try await h.json("trash_messages", ["ids": [.int(Int(h.id("receipt")))]])
        let entries = log.recent(limit: 5)
        #expect(entries.count == 1)
        #expect(entries.first?.running == nil && entries.first?.tool == "trash_messages" && entries.first?.ok == true)
        #expect(log.stuck(olderThan: 0).isEmpty)
    }
}

@Suite("Calls that never finish")
struct UnfinishedCallTests {
    @Test func startedLineIsReplacedAndStuckOnesAreFound() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "activity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ActivityLog(url: directory.appending(path: "activity.jsonl"))
        let done = UUID(), hung = UUID()
        let old = Date().addingTimeInterval(-300)
        log.append(ActivityEntry(id: hung, date: old, pid: 1, client: "c", tool: "search_messages", ok: true, milliseconds: 0, summary: "running", isWrite: false, running: true))
        log.append(ActivityEntry(id: done, date: old, pid: 1, client: "c", tool: "trash_messages", ok: true, milliseconds: 0, summary: "running", isWrite: true, running: true))
        log.append(ActivityEntry(id: done, date: old, pid: 1, client: "c", tool: "trash_messages", ok: true, milliseconds: 2_000, summary: "trashed 3", isWrite: true))
        let recent = log.recent(limit: 10)
        #expect(recent.map(\.id) == [done, hung])
        #expect(recent.first?.summary == "trashed 3")
        #expect(log.stuck().map(\.id) == [hung])
        #expect(log.stuck(olderThan: 600).isEmpty)
    }

    @Test func cancelledNotificationsNameTheirRequest() throws {
        let call = try #require(ToolCallFastPath.call(in: Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"x"}}"#.utf8)))
        let cancel = Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7,"reason":"timeout"}}"#.utf8)
        #expect(ToolCallFastPath.cancelledRequest(in: cancel) == call.id)
        #expect(ToolCallFastPath.cancelledRequest(in: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)) == nil)
    }

    @Test func runningCallsCancelTheirTask() async throws {
        let running = RunningCalls()
        let id = Data("7".utf8)
        let finished = Counter()
        running.start(id) {
            Task {
                while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
                await finished.mark()
            }
        }
        running.cancel(id)
        for _ in 0..<200 where await finished.count == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(await finished.count == 1)
    }

    actor Counter {
        var count = 0
        func mark() { count += 1 }
    }
}
