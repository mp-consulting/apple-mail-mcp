import Foundation
import MCP
import MailAutomation
import MailFixtures
import MailStore
import Testing

@testable import MailMCPKit

@Suite("Read tools")
final class ReadToolTests {
    let h: Harness
    init() throws { h = try Harness() }
    deinit { h.remove() }

    @Test func toolListIsCompleteAndAnnotated() {
        let tools = h.toolbox.listedDefinitions.map(\.tool)
        let names = Set(tools.map(\.name))
        #expect(names.isSuperset(of: [
            "list_accounts", "list_mailboxes", "inbox_overview", "search_messages", "get_message", "get_thread",
            "list_attachments", "save_attachment", "get_message_source", "export_messages", "mail_statistics",
            "top_senders", "awaiting_reply", "needs_response", "body_index", "move_messages", "update_messages",
            "trash_messages", "create_mailbox", "check_new_mail", "compose_email", "reply_to_message", "forward_message",
            "open_in_mail",
        ]))
        #expect(tools.count == names.count)
        #expect(tools.first { $0.name == "search_messages" }?.annotations.readOnlyHint == true)
        #expect(tools.first { $0.name == "trash_messages" }?.annotations.destructiveHint == true)
        for tool in tools {
            #expect(tool.description?.isEmpty == false)
            guard case .object(let schema) = tool.inputSchema else {
                Issue.record("\(tool.name) schema is not an object")
                continue
            }
            #expect(schema["type"] == "object")
        }
    }

    @Test func readOnlyLaunchHidesWriteTools() throws {
        let readOnly = try Harness(readOnly: true)
        defer { readOnly.remove() }
        let names = Set(readOnly.toolbox.listedDefinitions.map(\.tool.name))
        #expect(names.contains("search_messages") && names.contains("save_attachment"))
        #expect(!names.contains("move_messages") && !names.contains("compose_email"))
    }

    @Test func listAccounts() async throws {
        let json = try await h.json("list_accounts")
        let accounts = json["accounts"] as? [[String: Any]] ?? []
        #expect(accounts.compactMap { $0["name"] as? String } == ["Gmail", "iCloud", "On My Mac"])
        #expect(accounts[1]["inbox_unread"] as? Int == 4)
    }

    @Test func listMailboxesGroupsByAccount() async throws {
        let json = try await h.json("list_mailboxes", ["account": "icloud"])
        let boxes = json["iCloud"] as? [[String: Any]] ?? []
        #expect(boxes.compactMap { $0["path"] as? String }.contains("Archive/2020"))
        #expect(boxes.first { $0["path"] as? String == "INBOX" }?["role"] as? String == "inbox")
    }

    @Test func searchFiltersAndPagination() async throws {
        var json = try await h.json("search_messages", ["sender": "carol", "flag_color": "red"])
        #expect(subjects(json["messages"]) == ["Invoice 42"])
        json = try await h.json("search_messages", ["mailbox": "inbox", "account": "iCloud", "unread": true, "limit": 2])
        #expect(json["total"] as? Int == 4)
        #expect((json["messages"] as? [Any])?.count == 2)
        #expect(json["has_more"] as? Bool == true)
        json = try await h.json("search_messages", ["subject": "kickoff, invoice"])
        #expect(Set(subjects(json["messages"])) == ["Project kickoff", "Invoice 42"])
        json = try await h.json("search_messages", ["date_to": "2020-12-31"])
        #expect(subjects(json["messages"]) == ["Archived thing"])
        json = try await h.json("search_messages", ["category": "promotions"])
        #expect(subjects(json["messages"]) == ["Weekly digest"])
        let message = (try await h.json("search_messages", ["subject": "Invoice"])["messages"] as? [[String: Any]])?.first
        #expect(message?["flag"] as? String == "red")
        #expect(message?["category"] as? String == "transactions")
        #expect(message?["unread"] == nil)  // false values are omitted to save tokens
    }

    @Test func searchRejectsBadArguments() async {
        #expect(await h.call("search_messages", ["flag_color": "pink"]).isError)
        #expect(await h.call("search_messages", ["mailbox": "Nowhere"]).isError)
        #expect(await h.call("search_messages", ["account": "nobody"]).text.contains("Accounts:"))
        #expect(await h.call("search_messages", ["date_from": "last tuesday"]).isError)
        #expect(await h.call("no_such_tool").isError)
    }

    @Test func bodySearchUsesTheIndexOnceBuilt() async throws {
        var json = try await h.json("search_messages", ["body": "kubernetes"])
        #expect(json["body_search"] as? String == "scan")
        #expect(subjects(json["messages"]) == ["Project kickoff"])
        let status = try await h.json("body_index", ["action": "update"])
        #expect(status["indexed_messages"] as? Int == 12)
        #expect(status["not_yet_indexed"] as? Int == 0)
        json = try await h.json("search_messages", ["body": "kubernetes"])
        #expect(json["body_search"] as? String == "index")
        #expect(subjects(json["messages"]) == ["Project kickoff"])
    }

    @Test func getMessage() async throws {
        let json = try await h.json("get_message", ["id": .int(Int(h.id("kickoff")))])
        #expect(json["subject"] as? String == "Project kickoff")
        #expect((json["body"] as? String)?.contains("Kubernetes") == true)
        #expect((json["to"] as? [String]) == ["Me Myself <me@icloud.test>"])
        #expect((json["attachments"] as? [[String: Any]])?.first?["name"] as? String == "report.pdf")
        #expect(json["link"] as? String == "message://%3Ckickoff@example.test%3E")
        let short = try await h.json("get_message", ["id": .string(String(h.id("kickoff"))), "max_chars": 5])
        #expect(short["body"] as? String == "Hi,\nL…")
        #expect(short["body_truncated"] as? Bool == true)
        let pending = try await h.json("get_message", ["id": .int(Int(h.id("pending")))])
        #expect(pending["body_downloaded"] as? Bool == false)
        #expect(await h.call("get_message", ["id": 424242]).isError)
    }

    @Test func threadStripsQuotes() async throws {
        let json = try await h.json("get_thread", ["id": .int(Int(h.id("answer")))])
        let messages = json["messages"] as? [[String: Any]] ?? []
        #expect(messages.count == 2)
        #expect(messages[1]["body"] as? String == "Yes, signed copy attached soon.")
    }

    @Test func insights() async throws {
        let waiting = try await h.json("awaiting_reply")
        #expect(subjects(waiting["messages"]) == ["Quote request"])
        let needs = try await h.json("needs_response", ["include_read": false])
        #expect(Set(subjects(needs["messages"])) == ["Project kickoff", "Re: Contract question"])
        let stats = try await h.json("mail_statistics", ["days": 30])
        #expect(stats["received"] as? Int == 10)
        let senders = try await h.json("top_senders", ["by_domain": true])
        #expect((senders["senders"] as? [[String: Any]])?.first?["sender"] as? String == "example.test")
        let overview = try await h.json("inbox_overview", ["recent": 3])
        #expect(overview["unread_total"] as? Int == 5)  // 4 in iCloud + 1 Gmail label
        #expect((overview["recent_unread"] as? [Any])?.count == 3)
        #expect(overview["flagged_total"] as? Int == 2)
    }

    @Test func messageSource() async throws {
        let json = try await h.json("get_message_source", ["id": .int(Int(h.id("kickoff")))])
        let source = json["source"] as? String ?? ""
        #expect(source.contains("Message-ID: <kickoff@example.test>"))
        #expect(!source.contains("Content-Disposition"))  // headers only by default
    }

    @Test func activityIsLoggedWithoutBodies() async throws {
        _ = await h.call("get_message", ["id": .int(Int(h.id("kickoff")))])
        let entries = h.toolbox.activity?.recent() ?? []
        #expect(entries.first?.tool == "get_message")
        #expect(entries.first?.ok == true)
        #expect(entries.first?.summary.contains("Kubernetes") == false)
        // The menu bar app's "Show in Mail" uses this link.
        #expect(entries.first?.link == "message://%3Ckickoff@example.test%3E")
        _ = await h.call("search_messages", ["subject": "kickoff"])
        #expect(h.toolbox.activity?.recent().first?.link == nil)
    }
}

@Suite("File tools")
final class FileToolTests {
    let h: Harness
    init() throws { h = try Harness() }
    deinit { h.remove() }

    @Test func savesStrippedAttachmentFromMailsAttachmentsFolder() async throws {
        let folder = h.support.appending(path: "out").path
        let json = try await h.json("save_attachment", ["id": .int(Int(h.id("kickoff"))), "directory": .string(folder)])
        let saved = (json["saved"] as? [[String: Any]])?.first?["path"] as? String
        #expect(saved == folder + "/report.pdf")
        #expect(try Data(contentsOf: URL(filePath: folder + "/report.pdf")) == Data("%PDF-1.4 fake report".utf8))
        // A second save does not overwrite.
        let again = try await h.json("save_attachment", ["id": .int(Int(h.id("kickoff"))), "directory": .string(folder)])
        #expect((again["saved"] as? [[String: Any]])?.first?["path"] as? String == folder + "/report 2.pdf")
    }

    @Test func refusesProtectedDestinations() async {
        let result = await h.call("save_attachment", ["id": .int(Int(h.id("kickoff"))), "directory": "~/Library/LaunchAgents"])
        #expect(result.isError)
        #expect(result.text.contains("protected"))
    }

    @Test func exportsEmlAndMarkdown() async throws {
        let folder = h.support.appending(path: "export").path
        let ids: [Value] = [.int(Int(h.id("kickoff"))), .int(Int(h.id("invoice"))), 999_999]
        let json = try await h.json("export_messages", ["ids": .array(ids), "directory": .string(folder)])
        let written = json["written"] as? [String] ?? []
        #expect(written.count == 2)
        #expect((json["failed"] as? [Any])?.count == 1)
        #expect(try String(contentsOfFile: written[0], encoding: .utf8).contains("Message-ID:"))
        let md = try await h.json("export_messages", ["ids": .array([ids[1]]), "directory": .string(folder), "format": "markdown"])
        let text = try String(contentsOfFile: (md["written"] as? [String])?.first ?? "", encoding: .utf8)
        #expect(text.hasPrefix("# Invoice 42"))
        #expect(text.contains("Invoice #42 & receipt"))
    }
}

@Suite("Mail-changing tools")
final class ChangeToolTests {
    let h: Harness
    init() throws { h = try Harness() }
    deinit { h.remove() }

    var icloudInbox: MailboxTarget { MailboxTarget(accountID: h.fixture.icloud, path: "INBOX") }

    @Test func moveGroupsBySourceAndReturnsNewIDs() async throws {
        let kickoff = h.id("kickoff")
        let fixture = h.fixture
        // Simulate Mail re-inserting the moved message in Archive under a new ROWID.
        h.automation.onMove = { ids, _ in
            for id in ids { _ = try? fixture.store.moveMessage(id, to: fixture.archive) }
        }
        let json = try await h.json("move_messages", ["ids": [.int(Int(kickoff)), 999_999], "to_mailbox": "archive"])
        #expect(json["not_found"] as? [Int] == [999_999])
        #expect(json["moved"] as? Int == 1)
        #expect(json["unverified"] == nil && json["collateral_suspected"] == nil && json["warning"] == nil)
        #expect(h.automation.calls.first == .move([kickoff], icloudInbox, MailboxTarget(accountID: h.fixture.icloud, path: "Archive")))
        #expect(h.automation.unguardedChanges == 0)
        let newIDs = json["new_ids"] as? [String: Int]
        #expect(newIDs?[String(kickoff)] != nil && newIDs?[String(kickoff)] != Int(kickoff))
    }

    @Test func moveCountsOnlyMessagesThatArrived() async throws {
        // Mail answers OK for both, but only the invoice really moves.
        let fixture = h.fixture
        let invoice = h.id("invoice"), digest = h.id("digest")
        h.automation.onMove = { _, _ in _ = try? fixture.store.moveMessage(invoice, to: fixture.archive) }
        let json = try await h.json("move_messages", ["ids": [.int(Int(invoice)), .int(Int(digest))], "to_mailbox": "archive"])
        #expect(json["moved"] as? Int == 1)
        #expect(json["unverified"] as? [Int] == [Int(digest)])
        #expect((json["new_ids"] as? [String: Int])?.keys.sorted() == [String(invoice)])
        #expect(json["warning"] as? String != nil && json["collateral_suspected"] == nil)
    }

    @Test func moveStopsWhenTheDestinationGainsStrays() async throws {
        let fixture = h.fixture
        let kickoff = h.id("kickoff"), archived = h.id("archived")
        h.automation.onMove = { ids, _ in
            for id in ids { _ = try? fixture.store.moveMessage(id, to: fixture.archive) }
            _ = try? fixture.store.moveMessage(archived, to: fixture.archive)
        }
        let json = try await h.json("move_messages", ["ids": [.int(Int(kickoff))], "to_mailbox": "archive"])
        #expect(json["moved"] as? Int == 1)
        let collateral = json["collateral_suspected"] as? [String: Any]
        #expect(collateral?["mailbox"] as? String == "Archive")
        #expect(collateral?["expected_gain"] as? Int == 1 && collateral?["actual_gain"] as? Int == 2)
    }

    @Test func moveDryRunAndAmbiguity() async throws {
        let dry = try await h.json("move_messages", ["ids": [.int(Int(h.id("invoice")))], "to_mailbox": "Archive/2020", "dry_run": true])
        #expect(dry["dry_run"] as? Bool == true)
        #expect(h.automation.calls.isEmpty)
        let unknown = await h.call("move_messages", ["ids": [.int(Int(h.id("invoice")))], "to_mailbox": "Nowhere"])
        #expect(unknown.isError)
        // A destination missing in one account fails the whole call before anything moves.
        let partial = await h.call("move_messages", ["ids": [.int(Int(h.id("invoice"))), .int(Int(h.id("gmail")))], "to_mailbox": "archive"])
        #expect(partial.isError && partial.text.contains("in Gmail"))
        #expect(h.automation.calls.isEmpty)
    }

    @Test func updateMessages() async throws {
        let json = try await h.json("update_messages", ["ids": [.int(Int(h.id("kickoff")))], "read": true, "flag_color": "green"])
        #expect(json["updated"] as? Int == 1)
        #expect(h.automation.calls == [.setState([h.id("kickoff")], icloudInbox, true, nil, .green)])
        #expect(await h.call("update_messages", ["ids": [1]]).isError)  // nothing to change
    }

    @Test func trashSkipsTrashAndJunk() async throws {
        let fixture = h.fixture
        h.automation.onTrash = { ids, _ in
            for id in ids { _ = try? fixture.store.moveMessage(id, to: fixture.trash) }
        }
        let json = try await h.json("trash_messages", ["ids": [.int(Int(h.id("receipt"))), .int(Int(h.id("spam"))), .int(Int(h.id("junk")))]])
        #expect(json["trashed"] as? Int == 1)
        #expect((json["skipped_already_in_trash_or_junk"] as? [Int])?.count == 2)
        #expect(json["unverified"] == nil && json["collateral_suspected"] == nil && json["warning"] == nil)
        #expect(h.automation.calls == [.trash([h.id("receipt")], icloudInbox)])
        #expect(h.automation.unguardedChanges == 0)
    }

    @Test func trashCountsOnlyMessagesThatLeft() async throws {
        // Mail answers OK for all three, but only the receipt leaves the inbox.
        let fixture = h.fixture
        let receipt = h.id("receipt"), digest = h.id("digest"), invoice = h.id("invoice")
        h.automation.onTrash = { _, _ in _ = try? fixture.store.moveMessage(receipt, to: fixture.trash) }
        let json = try await h.json("trash_messages", ["ids": [.int(Int(receipt)), .int(Int(digest)), .int(Int(invoice))]])
        #expect(json["trashed"] as? Int == 1)
        #expect(json["unverified"] as? [Int] == [Int(digest), Int(invoice)])
        #expect(json["collateral_suspected"] == nil)
        #expect((json["warning"] as? String)?.contains("Do not resend") == true)
    }

    @Test func trashStopsWhenMailTakesMoreThanAsked() async throws {
        // The 2026-10-18 incident: Mail also moved a message nobody asked for into Trash.
        let fixture = h.fixture
        let receipt = h.id("receipt"), kickoff = h.id("kickoff"), archived = h.id("archived")
        h.automation.onTrash = { ids, _ in
            for id in ids { _ = try? fixture.store.moveMessage(id, to: fixture.trash) }
            _ = try? fixture.store.moveMessage(kickoff, to: fixture.trash)
        }
        let json = try await h.json("trash_messages", ["ids": [.int(Int(receipt)), .int(Int(archived))]])
        #expect(json["trashed"] as? Int == 1)
        let collateral = json["collateral_suspected"] as? [String: Any]
        #expect(collateral?["mailbox"] as? String == "INBOX")
        #expect(collateral?["expected_drop"] as? Int == 1 && collateral?["actual_drop"] as? Int == 2)
        // The second mailbox (Archive/2020) is not touched.
        #expect(json["not_attempted"] as? [Int] == [Int(archived)])
        #expect(h.automation.calls == [.trash([receipt], icloudInbox)])
        #expect((json["warning"] as? String)?.contains("Stop all bulk changes") == true)
    }

    @Test func trashReportsMessagesAlreadyGone() async throws {
        // Another client moved the receipt before this call reached Mail: not counted, not sent.
        let fixture = h.fixture
        let receipt = h.id("receipt")
        try fixture.store.moveMessage(receipt, to: fixture.archive)
        let json = try await h.json("trash_messages", ["ids": [.int(Int(receipt))]])
        #expect(json["trashed"] as? Int == 0)
        #expect(json["not_found"] as? [Int] == [Int(receipt)])
        #expect(h.automation.calls.isEmpty)
    }

    @Test func batchLimit() async throws {
        var settings = Settings()
        settings.maxBatchSize = 2
        let limited = try Harness(settings: settings)
        defer { limited.remove() }
        let result = await limited.call("update_messages", ["ids": [1, 2, 3], "read": true])
        #expect(result.isError && result.text.contains("limit per call is 2"))
    }

    @Test func mailChangesCanBeTurnedOff() async throws {
        var settings = Settings()
        settings.allowMailChanges = false
        let locked = try Harness(settings: settings)
        defer { locked.remove() }
        #expect(await locked.call("trash_messages", ["ids": [.int(Int(locked.id("receipt")))]]).isError)
        #expect(locked.automation.calls.isEmpty)
    }

    @Test func createMailbox() async throws {
        _ = try await h.json("create_mailbox", ["path": "Projects/Alpha", "account": "iCloud"])
        _ = try await h.json("create_mailbox", ["path": "Local stuff"])
        #expect(h.automation.calls == [
            .createMailbox(MailboxTarget(accountID: h.fixture.icloud, path: "Projects/Alpha")),
            .createMailbox(MailboxTarget(accountID: "", path: "Local stuff")),
        ])
        #expect(await h.call("create_mailbox", ["path": "Archive", "account": "iCloud"]).isError)
    }
}

@Suite("Compose tools and send policy")
final class ComposeToolTests {
    @Test func composeDefaultsToDraft() async throws {
        let h = try Harness()
        defer { h.remove() }
        _ = try await h.json("compose_email", ["to": "a@x.test, b@x.test", "subject": "Hi", "body": "Hello"])
        #expect(h.automation.calls == [.compose(OutgoingMessage(to: ["a@x.test", "b@x.test"], subject: "Hi", body: "Hello"), .draft)])
    }

    @Test func composeValidation() async throws {
        let h = try Harness()
        defer { h.remove() }
        #expect(await h.call("compose_email", ["to": "not-an-address", "subject": "x", "body": "y"]).isError)
        #expect(await h.call("compose_email", ["to": "a@x.test", "subject": "x", "body": "y", "mode": "yolo"]).isError)
        #expect(await h.call("compose_email", ["to": "a@x.test", "subject": "x", "body": "y", "from": "stranger@x.test"]).isError)
        #expect(await h.call("compose_email", ["to": "a@x.test", "subject": "x", "body": "y", "attachments": ["~/.ssh/id_ed25519"]]).isError)
        #expect(h.automation.calls.isEmpty)
    }

    @Test func replyQuotesTheOriginal() async throws {
        let h = try Harness()
        defer { h.remove() }
        _ = try await h.json("reply_to_message", ["id": .int(Int(h.id("kickoff"))), "body": "Sounds good."])
        guard case .reply(let id, let mailbox, let body, let all, let mode) = h.automation.calls.first else {
            Issue.record("no reply recorded")
            return
        }
        #expect(id == h.id("kickoff"))
        #expect(mailbox.path == "INBOX")
        #expect(!all && mode == .draft)
        #expect(body.hasPrefix("Sounds good.\n\nOn "))
        #expect(body.contains("Alice Martin <alice@example.test> wrote:\n> Hi,\n> Let's discuss the Kubernetes"))
    }

    @Test func sendPolicyNeverRefusesSending() async throws {
        var settings = Settings()
        settings.sendPolicy = .never
        let h = try Harness(settings: settings)
        defer { h.remove() }
        let result = await h.call("compose_email", ["to": "a@x.test", "subject": "x", "body": "y", "mode": "send"])
        #expect(result.isError && result.text.contains("never"))
        _ = try await h.json("compose_email", ["to": "a@x.test", "subject": "x", "body": "y", "mode": "open"])
        #expect(h.automation.calls.count == 1)
    }

    @Test func confirmPolicyNeedsTheMenuBarApp() async throws {
        var settings = Settings()
        settings.sendPolicy = .confirm
        let h = try Harness(settings: settings)
        defer { h.remove() }
        let result = await h.call("forward_message", ["id": .int(Int(h.id("kickoff"))), "to": "a@x.test", "mode": "send"])
        #expect(result.isError && result.text.contains("menu bar app"))
        #expect(h.automation.calls.isEmpty)
    }

    @Test func confirmPolicyWaitsForApproval() async throws {
        var settings = Settings()
        settings.sendPolicy = .confirm
        settings.approvalTimeout = 10
        let h = try Harness(settings: settings)
        defer { h.remove() }
        h.approvals.beat()
        let approvals = h.approvals
        // Play the menu bar app: approve the first request, deny the second.
        let agent = Task {
            var decided = 0
            while decided < 2 {
                for request in approvals.pending() {
                    try approvals.decide(request.id, approve: decided == 0)
                    decided += 1
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        _ = try await h.json("compose_email", ["to": "a@x.test", "subject": "Approved", "body": "y", "mode": "send"])
        let denied = await h.call("compose_email", ["to": "a@x.test", "subject": "Denied", "body": "y", "mode": "send"])
        try await agent.value
        #expect(denied.isError && denied.text.contains("declined"))
        #expect(h.automation.calls == [.compose(OutgoingMessage(to: ["a@x.test"], subject: "Approved", body: "y"), .send)])
        #expect(approvals.pending().isEmpty)
    }

    @Test func replyApprovalLinksToTheOriginal() async throws {
        var settings = Settings()
        settings.sendPolicy = .confirm
        settings.approvalTimeout = 10
        let h = try Harness(settings: settings)
        defer { h.remove() }
        h.approvals.beat()
        let approvals = h.approvals
        let agent = Task { () -> String? in
            while true {
                if let request = approvals.pending().first {
                    try approvals.decide(request.id, approve: false)
                    return request.originalLink
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        _ = await h.call("reply_to_message", ["id": .int(Int(h.id("kickoff"))), "body": "ok", "mode": "send"])
        #expect(try await agent.value == "message://%3Ckickoff@example.test%3E")
    }

    @Test func forwardComposesWithOriginalAndAttachments() async throws {
        let h = try Harness()
        defer { h.remove() }
        let json = try await h.json("forward_message", ["id": .int(Int(h.id("kickoff"))), "to": ["acct@x.test"], "body": "FYI"])
        #expect(json["attachments"] as? Int == 1)
        guard case .compose(let message, let mode) = h.automation.calls.first else {
            Issue.record("no compose recorded")
            return
        }
        #expect(mode == .draft)
        #expect(message.subject == "Fwd: Project kickoff")
        #expect(message.body.hasPrefix("FYI\n\n---------- Forwarded message ----------\nFrom: Alice Martin <alice@example.test>"))
        #expect(message.body.contains("Let's discuss the Kubernetes cluster"))
        #expect(message.attachments.count == 1)
        #expect(try Data(contentsOf: URL(filePath: message.attachments[0])) == Data("%PDF-1.4 fake report".utf8))
    }

    @Test func draftsCannotBeRepliedOrForwarded() async throws {
        let h = try Harness()
        defer { h.remove() }
        let draft = try h.fixture.store.addMessage(
            FixtureMessage(subject: "Unsent", from: StandardFixture.me, to: [StandardFixture.bob], date: Date(), mailbox: h.fixture.drafts, body: "wip"))
        #expect(await h.call("reply_to_message", ["id": .int(Int(draft)), "body": "x"]).text.contains("unsent draft"))
        #expect(await h.call("forward_message", ["id": .int(Int(draft)), "to": "a@x.test"]).isError)
        #expect(h.automation.calls.isEmpty)
    }
}

@Suite("HTML email")
struct HTMLEmailTests {
    @Test @MainActor func htmlBecomesRichText() throws {
        let rtf = try RichText.rtf(fromHTML: "<p>Hello <b>bold</b> <a href=\"https://example.com\">link</a></p>")
        let text = String(decoding: rtf, as: UTF8.self)
        #expect(text.hasPrefix("{\\rtf"))
        #expect(text.contains("\\b"))  // bold run
        #expect(text.contains("HYPERLINK") && text.contains("https://example.com"))
    }

    @Test func composeWithHTML() async throws {
        let h = try Harness()
        defer { h.remove() }
        _ = try await h.json("compose_email", ["to": "a@x.test", "subject": "Hi", "html": "<p>Hello <b>you</b></p>"])
        guard case .compose(let message, _) = h.automation.calls.first else {
            Issue.record("no compose recorded")
            return
        }
        #expect(message.html == "<p>Hello <b>you</b></p>")
        #expect(message.body == "Hello you")  // plain-text fallback derived from the HTML
        #expect(await h.call("compose_email", ["to": "a@x.test", "subject": "Hi"]).isError)  // needs body or html
    }

    @Test func replyQuotesTheOriginalAsHTML() async throws {
        let h = try Harness()
        defer { h.remove() }
        _ = try await h.json("reply_to_message", ["id": .int(Int(h.id("invoice"))), "html": "<p>Paid, <b>thanks</b>.</p>"])
        let html = try #require(h.automation.lastReplyHTML)
        #expect(html.hasPrefix("<p>Paid, <b>thanks</b>.</p>"))
        #expect(html.contains("<blockquote type=\"cite\">"))
        #expect(html.contains("Invoice <b>#42</b>"))  // the original's own HTML, not flattened
        #expect(!html.contains("<head>"))
        #expect(html.contains("Carol, Billing &lt;carol@shop.test&gt; wrote:"))
    }

    @Test func forwardKeepsTheOriginalHTML() async throws {
        let h = try Harness()
        defer { h.remove() }
        _ = try await h.json("forward_message", ["id": .int(Int(h.id("invoice"))), "to": "acct@x.test", "html": "<p>FYI</p>"])
        guard case .compose(let message, _) = h.automation.calls.first else {
            Issue.record("no compose recorded")
            return
        }
        #expect(message.html?.hasPrefix("<p>FYI</p>") == true)
        #expect(message.html?.contains("Forwarded message") == true)
        #expect(message.html?.contains("<li>Item one</li>") == true)
    }
}
