import Foundation
import MailStore
import Testing

@testable import MailAutomation

/// Whether Gmail can trash by `move` to `[Gmail]/Trash` like the other accounts, or must keep Mail's `delete`
/// (see `docs/plans/2026-10-trash-via-move.md`, change 3). Copies of existing messages cannot be used on Gmail: a copy
/// is another label on the same message, so trashing it would trash the original. The probe makes its own messages
/// instead, as drafts it saves (nothing is sent), adds each to INBOX and to a probe label so it carries several
/// labels, then trashes half by `move` to Trash and half by `delete`, from the mailbox the server would use (the row
/// INBOX shows), by Message-ID, one at a time. It then counts, per mailbox of the account, the probe messages still
/// there, at once and a minute later, and any other message that left. Another message that reaches Trash stops the
/// run and goes straight back (to INBOX, or All Mail).
///
/// The drafts end in Trash; delete them there in Mail (Gmail also purges Trash after 30 days). Prints counts only.
///
/// Opt in with APPLE_MAIL_MCP_LIVE_TRASH=1 and APPLE_MAIL_MCP_PROBE_GMAIL=<Gmail account id>. Optional:
/// APPLE_MAIL_MCP_PROBE_COUNT (default 20, half per way), APPLE_MAIL_MCP_PROBE_ADDRESS (the drafts' sender). The account must hold no other mail, unless
/// APPLE_MAIL_MCP_PROBE_GMAIL_NONEMPTY=1 (a `delete` has removed the neighbour of the message it was meant for).
@Suite("Live Gmail trash probe", .serialized)
struct GmailTrashProbeTests {
    static let environment = ProcessInfo.processInfo.environment
    static let enabled = environment["APPLE_MAIL_MCP_LIVE_TRASH"] == "1" && environment["APPLE_MAIL_MCP_PROBE_GMAIL"] != nil

    @Test(.enabled(if: enabled)) func moveToTrashMatchesDelete() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)  // progress shows in a log file as it happens
        let accountID = try #require(Self.environment["APPLE_MAIL_MCP_PROBE_GMAIL"])
        let count = max(2, Int(Self.environment["APPLE_MAIL_MCP_PROBE_COUNT"] ?? "") ?? 20)
        let store = try MailStore.open()
        let automation = MailAutomation()
        let mail = MailEventSender(timeout: 60)
        let account = try #require(try store.accounts().first { $0.id == accountID }, "no account \(accountID)")
        // An account without mail yet has no address in the store: its name usually is one.
        let address = try #require(
            Self.environment["APPLE_MAIL_MCP_PROBE_ADDRESS"] ?? account.emailAddresses.first ?? (account.name.contains("@") ? account.name : nil),
            "no address for the account: set APPLE_MAIL_MCP_PROBE_ADDRESS")
        var boxes = try store.mailboxes(accountID: accountID)
        try #require(boxes.contains { $0.sourceMailboxID != nil }, "not a Gmail account (no label mailboxes)")
        let trash = try #require(boxes.first { $0.role == .trash && $0.sourceMailboxID == nil }, "no Trash")
        let inbox = try #require(boxes.first { $0.role == .inbox }, "no INBOX")
        let drafts = try #require(boxes.first { $0.role == .drafts && $0.sourceMailboxID == nil }, "no Drafts with rows")
        let allMail = try #require(boxes.first { $0.role == .allMail }, "no All Mail")
        let others = try store.liveCount(mailboxID: allMail.id)
        try #require(
            others == 0 || Self.environment["APPLE_MAIL_MCP_PROBE_GMAIL_NONEMPTY"] == "1",
            "All Mail holds \(others) messages: set APPLE_MAIL_MCP_PROBE_GMAIL_NONEMPTY=1 to probe anyway")
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        print("probe: gmail: \(count) drafts, account holding \(others) other messages")

        /// Retries an event Mail did not answer in time (it can block for a while when it syncs), once it answers again.
        func retrying<T>(_ body: () async throws -> T) async throws -> T {
            for attempt in 1... {
                do {
                    return try await body()
                } catch let error as AppleEventError where error.number == -1712 && attempt < 3 {
                    print("probe: gmail: Mail did not answer in time, trying again")
                    try TrashProbeTests.waitForMail()
                }
            }
            fatalError("unreachable")
        }

        /// Moves every probe message (subject "MCP Probe …") outside Trash to Trash: what earlier runs left, or what this
        /// one made before it failed.
        func trashProbeMessages() async {
            do {
                try TrashProbeTests.waitForMail()
                var count = 0
                for box in try store.mailboxes(accountID: accountID) where box.sourceMailboxID == nil && box.id != trash.id {
                    let rows = try store.messages(ids: Array(try store.headerRows(mailboxID: box.id).keys))
                        .filter { $0.mailboxID == box.id && $0.subject.hasPrefix("MCP Probe ") && $0.messageIDHeader != nil }
                    guard !rows.isEmpty else { continue }
                    count += try await retrying {
                        try await automation.trash(TrashProbeTests.refs(rows), in: MailboxTarget(box), to: MailboxTarget(trash))
                    }
                }
                if count > 0 { print("probe: gmail: moved \(count) probe messages to Trash") }
            } catch {
                print("probe: gmail: could not move the probe messages to Trash: \(error); delete them in Mail")
            }
        }
        await trashProbeMessages()

        do {
            // A probe label: an empty one an earlier run left, else a new one (Mail can take minutes to list it while it
            // syncs a new account).
            try TrashProbeTests.waitForMail()
            var created = try boxes.first { try $0.path.hasPrefix("MCP Probe ") && $0.sourceMailboxID != nil && store.liveCount(mailboxID: $0.id) == 0 }
            let labelTarget = MailboxTarget(accountID: accountID, path: created?.path ?? "MCP Probe \(stamp)")
            if created == nil {
                try await automation.createMailbox(labelTarget)
                _ = try TrashProbeTests.wait(300) {
                    created = try store.mailboxes(accountID: accountID).first { $0.path == labelTarget.path }
                    return created != nil
                }
            }
            let label = try #require(
                created, "the probe label never reached Mail's database: is the account online in Mail (signed in, no warning sign)?")

            // Drafts, saved one by one: each compose object is closed once its draft row is in the database, wherever
            // Mail files it (its Drafts mailbox, or All Mail with a Drafts label).
            let homes = boxes.filter { $0.sourceMailboxID == nil }
            var headers: [String] = []
            var draftRows: [String: MessageSummary] = [:]
            for index in 1...count {
                let subject = "MCP Probe \(stamp) #\(index)"
                let started = try store.maxMessageRowID()
                let handle = try await retrying {
                    try await automation.compose(
                        OutgoingMessage(from: address, to: [address], subject: subject, body: "Apple Mail MCP probe draft. Safe to delete."),
                        mode: .draft)
                }
                var row: MessageSummary?
                _ = try TrashProbeTests.wait(180) {
                    let ids = try homes.flatMap { try store.headerRows(mailboxID: $0.id).keys.filter { $0 > started } }
                    row = try store.messages(ids: ids).first { $0.subject == subject && $0.messageIDHeader != nil }
                    return row != nil
                }
                if let handle { try? await automation.closeCompose(handle) }
                let saved = try #require(row, "draft \(index) did not show up")
                headers.append(saved.messageIDHeader!)
                draftRows[saved.messageIDHeader!] = saved
            }
            if let first = draftRows.values.first, first.mailboxID != drafts.id {
                print("probe: gmail: drafts are filed in \(boxes.first { $0.id == first.mailboxID }?.path ?? "another mailbox")")
            }
            print("probe: gmail: \(headers.count) drafts saved")

            /// Rows of each Message-ID in `mailbox`, directly or through a label.
            func present(_ mailbox: Mailbox) throws -> [String: Int] {
                try store.headerRows(mailboxID: mailbox.id).values.reduce(into: [:]) { $0[$1, default: 0] += 1 }
            }

            // Several labels each: INBOX and the probe label.
            for header in headers {
                let draft = draftRows[header]!
                let home = MailboxTarget(boxes.first { $0.id == draft.mailboxID } ?? drafts)
                let ref = MessageRef(id: draft.id, header: header, subject: draft.subject, dateReceived: draft.dateReceived)
                _ = try await retrying { try await automation.copy([ref], from: home, to: MailboxTarget(inbox)) }
                _ = try await retrying { try await automation.copy([ref], from: home, to: labelTarget) }
            }
            let labelled = try TrashProbeTests.wait(300) {
                let (inInbox, inLabel) = (try present(inbox), try present(label))
                return headers.allSatisfy { inInbox[$0] != nil && inLabel[$0] != nil }
            }
            try TrashProbeTests.settle(store, inbox)
            boxes = try store.mailboxes(accountID: accountID)
            let moved = Set(headers.prefix(count / 2)), deleted = Set(headers.dropFirst(count / 2))

            /// Per mailbox, how many of the moved and deleted probe messages it shows, and how many other messages left it.
            let before = try Dictionary(uniqueKeysWithValues: boxes.map { ($0.id, try present($0)) })
            func census(_ when: String) throws {
                print("probe: gmail: \(when)")
                for box in boxes {
                    let now = try present(box)
                    let m = moved.filter { now[$0] != nil }.count, d = deleted.filter { now[$0] != nil }.count
                    let lost = (before[box.id] ?? [:]).filter { !moved.contains($0.key) && !deleted.contains($0.key) && now[$0.key] == nil }.count
                    guard m + d + lost > 0 else { continue }
                    print("probe:   \(box.path)\(box.sourceMailboxID != nil ? " (label)" : ""): move \(m)/\(moved.count), delete \(d)/\(deleted.count)"
                        + (lost > 0 ? ", \(lost) other messages left" : ""))
                }
            }
            try census("labelled\(labelled ? "" : " (not all labels showed up)")")

            /// Other messages that reached Trash since the drafts were labelled go straight back: to INBOX when they were
            /// there, else to All Mail. Returns how many were found.
            let probeHeaders = moved.union(deleted)
            var putBack = 0
            func putBackStrays() async throws -> Int {
                let strays = try present(trash).keys.filter { !probeHeaders.contains($0) && before[trash.id]?[$0] == nil }
                for header in strays {
                    let home = before[inbox.id]?[header] != nil ? inbox : allMail
                    let rows = try store.messages(messageIDHeaders: [header], mailboxIDs: [trash.id]).filter { $0.mailboxID == trash.id }
                    _ = try? await retrying { try await automation.move(TrashProbeTests.refs(rows), from: MailboxTarget(trash), to: MailboxTarget(home)) }
                    let back = try TrashProbeTests.wait(30) { try present(home)[header] != nil }
                    if back { putBack += 1 }
                    print("probe: gmail: a message nobody asked for went to Trash; put back in \(home.path): \(back ? "yes" : "NOT YET, check Trash")")
                }
                return strays.count
            }

            // From the mailbox holding the row INBOX shows, as `trash_messages` would. The first stray stops the run.
            var eventMs: [String: [Double]] = ["move": [], "delete": []]
            var stopped = false
            for header in headers where !stopped {
                guard let row = try store.messages(messageIDHeaders: [header], mailboxIDs: [inbox.id]).first,
                    let source = boxes.first(where: { $0.id == row.mailboxID })
                else {
                    print("probe: gmail: a draft is not in INBOX, skipped")
                    continue
                }
                let ref = MessageRef(id: row.id, header: header, subject: row.subject, dateReceived: row.dateReceived)
                let way = moved.contains(header) ? "move" : "delete"
                let sent = Date()
                do {
                    _ = try await retrying {
                        way == "move"
                            ? try await automation.trash([ref], in: MailboxTarget(source), to: MailboxTarget(trash))
                            : try await automation.delete([ref], in: MailboxTarget(source))
                    }
                } catch {
                    print("probe: gmail: \(way) failed: \(error)")
                }
                eventMs[way]!.append(Date().timeIntervalSince(sent) * 1000)
                _ = try TrashProbeTests.wait(15) { try present(inbox)[header] == nil }
                if try await putBackStrays() > 0 {
                    stopped = true
                    print("probe: gmail: stopped after a stray (\(way))")
                }
            }
            for (way, times) in eventMs.sorted(by: { $0.key > $1.key }) where !times.isEmpty {
                print("probe: gmail: \(way): event avg \(Int(times.reduce(0, +) / Double(times.count))) ms, max \(Int(times.max()!)) ms")
            }
            try TrashProbeTests.settle(store, trash)
            try census("after trashing")
            try await Task.sleep(for: .seconds(60))
            // Strays have landed late before.
            if try await putBackStrays() > 0 { print("probe: gmail: late stray found") }
            try census("a minute later")
            print("probe: gmail: \(putBack) strays put back\(stopped ? ", run stopped early" : "")")

            // Probe messages still outside Trash go there (by `move`, never a delete in Trash); then the label goes.
            await trashProbeMessages()
            try mail.send("core", "delo", direct: MailSpec.mailbox(labelTarget))
            print("probe: gmail: deleted the probe label; the drafts are in \(trash.path): delete them there in Mail")
        } catch {
            print("probe: gmail: stopped: \(error)")
            await trashProbeMessages()
            throw error
        }
    }
}
