import Foundation
import MailStore
import Testing

@testable import MailAutomation

/// Reproduces the 2026-10-20 incident on real Mail: `delete message id <rowid>` sent back to back on an IMAP
/// mailbox removed the date-neighbour of some requested messages instead of the messages themselves. Each variant
/// works on its own throwaway mailbox `MCP Probe <time> <variant>`, filled with copies of messages from a mailbox
/// the tester names, and trashes every second one:
///
/// - A: `delete message id`, back to back (the path before 0.6.1)
/// - B: `delete message id`, each waiting until the database shows the message gone
/// - C: `move message id … to` the account's Trash, back to back
/// - D: `delete (every message whose message id = …)`, back to back (the path from 0.6.1)
///
/// Prints counts and timings only, never message content. At the end the copies in Trash go back to their probe
/// mailbox and the probe mailboxes are deleted (Mail must not delete messages already in Trash).
///
/// Opt in with APPLE_MAIL_MCP_LIVE_TRASH=1 (it changes mail), APPLE_MAIL_MCP_PROBE_ACCOUNT=<IMAP account id> and
/// APPLE_MAIL_MCP_PROBE_SOURCE=<mailbox path to copy from>. Optional: APPLE_MAIL_MCP_PROBE_COUNT (default 40),
/// APPLE_MAIL_MCP_PROBE_VARIANTS (e.g. "AD"), APPLE_MAIL_MCP_PROBE_LARGE=<path>[,<path>] to time a `whose` lookup on
/// big mailboxes (read only). Needs Full Disk Access for the test runner, to read Mail's database.
@Suite("Live trash probe", .serialized)
struct TrashProbeTests {
    static let environment = ProcessInfo.processInfo.environment
    static let enabled = environment["APPLE_MAIL_MCP_LIVE_TRASH"] == "1"

    enum Variant: String, CaseIterable {
        case a = "A", b = "B", c = "C", d = "D"

        var label: String {
            switch self {
            case .a: "A delete by id, back to back"
            case .b: "B delete by id, paced"
            case .c: "C move by id to Trash"
            case .d: "D delete whose message id"
            }
        }
    }

    struct Result: CustomStringConvertible {
        var variant: Variant
        var requested = 0
        var left = 0
        var stayed = 0
        var strays = 0
        /// Strays that are the next message in date order after a requested message that stayed.
        var neighbourStrays = 0
        var eventMs: [Double] = []
        var seconds: Double = 0

        var description: String {
            let average = eventMs.isEmpty ? 0 : eventMs.reduce(0, +) / Double(eventMs.count)
            return "\(variant.label): requested \(requested), left \(left), stayed \(stayed), strays \(strays) "
                + "(\(neighbourStrays) date-neighbours of one that stayed), event avg \(Int(average)) ms max "
                + "\(Int(eventMs.max() ?? 0)) ms, \(String(format: "%.1f", seconds)) s"
        }
    }

    /// Polls `condition` every 0.25 s for up to `timeout` seconds.
    static func wait(_ timeout: TimeInterval, _ condition: () throws -> Bool) rethrows -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return try condition()
    }

    /// Waits until a mailbox's row count has not changed for `quiet` seconds (at most `timeout`).
    static func settle(_ store: MailStore, _ mailbox: Mailbox, quiet: TimeInterval = 10, timeout: TimeInterval = 90) throws {
        var last = try store.liveCount(mailboxID: mailbox.id)
        var since = Date()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, Date().timeIntervalSince(since) < quiet {
            Thread.sleep(forTimeInterval: 0.5)
            let now = try store.liveCount(mailboxID: mailbox.id)
            if now != last { (last, since) = (now, Date()) }
        }
    }

    static func refs(_ messages: [MessageSummary]) -> [MessageRef] {
        messages.map { MessageRef(id: $0.id, header: $0.messageIDHeader, subject: $0.subject, dateReceived: $0.dateReceived) }
    }

    /// A probe mailbox, and how to tell its copies in Trash: rows newer than `since` carrying one of `headers`
    /// (nil: any Message-ID of the source).
    struct Probe {
        var mailbox: Mailbox
        var since: Int64
        var headers: Set<String>?
    }

    @Test(.enabled(if: enabled)) func neighbourRemoval() async throws {
        let accountID = try #require(Self.environment["APPLE_MAIL_MCP_PROBE_ACCOUNT"], "set APPLE_MAIL_MCP_PROBE_ACCOUNT")
        let sourcePath = try #require(Self.environment["APPLE_MAIL_MCP_PROBE_SOURCE"], "set APPLE_MAIL_MCP_PROBE_SOURCE")
        let count = Int(Self.environment["APPLE_MAIL_MCP_PROBE_COUNT"] ?? "") ?? 40
        let variants = Self.environment["APPLE_MAIL_MCP_PROBE_VARIANTS"].map { $0.compactMap { Variant(rawValue: String($0).uppercased()) } }
            ?? Variant.allCases
        let store = try MailStore.open()
        let boxes = try store.mailboxes(accountID: accountID)
        let source = try #require(boxes.first { $0.path == sourcePath }, "no mailbox \(sourcePath) in that account")
        // Some accounts have a second, empty Trash; deletes go to the main one.
        let trash = try #require(
            try boxes.filter { $0.role == .trash }.max { try store.liveCount(mailboxID: $0.id) < store.liveCount(mailboxID: $1.id) },
            "the account has no Trash")
        let automation = MailAutomation()
        let mail = MailEventSender(timeout: 60)

        /// The copies in Trash go back to the probe mailbox, then the mailbox goes. A row in Trash counts as a copy only
        /// when it is newer than the probe, carries a Message-ID of the source, and the source still holds that message;
        /// one whose Message-ID is in Trash twice cannot be moved by Message-ID and stays.
        func cleanUp(_ probe: Probe) async {
            do {
                try Self.waitForMail()
                let stillInSource = Set(try store.headerRows(mailboxID: source.id).values.filter { !$0.isEmpty })
                let trashRows = try store.headerRows(mailboxID: trash.id)
                let trashCounts = trashRows.values.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
                let copies = trashRows.filter {
                    $0.key > probe.since && stillInSource.contains($0.value) && (probe.headers?.contains($0.value) ?? true)
                }
                let movable = try store.messages(ids: copies.filter { trashCounts[$0.value] == 1 }.map(\.key))
                _ = try await automation.move(Self.refs(movable), from: MailboxTarget(trash), to: MailboxTarget(probe.mailbox))
                let back = try Self.wait(120) { try store.present(ids: movable.map(\.id), mailboxID: trash.id).isEmpty }
                print("probe: \(probe.mailbox.path): \(movable.count) copies moved back from Trash\(back ? "" : " (not all yet)")")
                try Self.waitForMail()
                try mail.send("core", "delo", direct: MailSpec.mailbox(MailboxTarget(probe.mailbox)))
                print("probe: deleted \(probe.mailbox.path)")
                if copies.count > movable.count {
                    print("probe: \(copies.count - movable.count) probe copies stay in Trash (Message-ID there twice); delete them in Mail")
                }
            } catch {
                print("probe: could not clean up \(probe.mailbox.path): \(error); delete it in Mail")
            }
        }

        // Probe mailboxes an earlier run left behind go first, so no Message-ID ends up in Trash twice.
        for box in boxes where box.path.hasPrefix("MCP Probe ") {
            let since = (try store.headerRows(mailboxID: box.id).keys.min() ?? Int64.max) - 1
            print("probe: cleaning up a probe mailbox an earlier run left")
            await cleanUp(Probe(mailbox: box, since: since, headers: nil))
        }

        // Messages whose Message-ID only they carry in the source, newest first; each variant copies its own slice.
        let rows = try store.headerRows(mailboxID: source.id)
        let counts = rows.values.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        let unique = rows.filter { !$0.value.isEmpty && counts[$0.value] == 1 }.keys.sorted(by: >)
        try #require(unique.count >= count * variants.count, "the source has only \(unique.count) messages with a unique Message-ID")
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        print("probe: \(count) messages per variant, copied from a mailbox of \(rows.count)")

        var probes: [Probe] = []
        for (index, variant) in variants.enumerated() {
            do {
                let originals = try store.messages(ids: Array(unique.dropFirst(index * count).prefix(count)))
                try Self.waitForMail()
                // A mailbox of its own, filled with copies.
                let target = MailboxTarget(accountID: accountID, path: "MCP Probe \(stamp) \(variant.rawValue)")
                try await automation.createMailbox(target)
                var created: Mailbox?
                _ = try Self.wait(60) {
                    created = try store.mailboxes(accountID: accountID).first { $0.path == target.path }
                    return created != nil
                }
                let mailbox = try #require(created, "Mail did not create \(target.path)")
                let maxRowID = try store.maxMessageRowID()
                probes.append(Probe(mailbox: mailbox, since: maxRowID, headers: Set(originals.compactMap(\.messageIDHeader))))
                let copied = try await automation.copy(Self.refs(originals), from: MailboxTarget(source), to: target)
                let filled = try Self.wait(180) { try store.liveCount(mailboxID: mailbox.id) >= count }
                print("probe: \(variant.rawValue): copied \(copied), \(try store.liveCount(mailboxID: mailbox.id)) in the probe mailbox")
                try #require(filled, "the copies did not all arrive")
                try Self.settle(store, mailbox)
                let headers = Set(try store.headerRows(mailboxID: mailbox.id).values)

                // Every second message in list order (newest first) is requested.
                let listed = try store.messages(ids: Array(try store.headerRows(mailboxID: mailbox.id).keys)).sorted { $0.dateReceived > $1.dateReceived }
                let requested = listed.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
                var result = Result(variant: variant, requested: requested.count)
                let started = Date()
                for message in requested {
                    let byID = MailSpec.message(message.id, in: target)
                    let sent = Date()
                    do {
                        switch variant {
                        case .a, .b: try mail.send("core", "delo", direct: byID)
                        case .c: try mail.send("core", "move", direct: byID, ["insh": MailSpec.mailbox(MailboxTarget(trash))])
                        case .d: try mail.send("core", "delo", direct: MailSpec.message(header: message.messageIDHeader!, in: target))
                        }
                    } catch {
                        print("probe: \(variant.rawValue): event failed: \(error)")
                    }
                    result.eventMs.append(Date().timeIntervalSince(sent) * 1000)
                    if variant == .b {
                        _ = try Self.wait(15) { try store.present(ids: [message.id], mailboxID: mailbox.id).isEmpty }
                    }
                }
                try Self.settle(store, mailbox)
                result.seconds = Date().timeIntervalSince(started)

                let now = Set(try store.headerRows(mailboxID: mailbox.id).values)
                let wanted = Set(requested.compactMap(\.messageIDHeader))
                result.left = wanted.subtracting(now).count
                result.stayed = wanted.intersection(now).count
                let strays = headers.subtracting(wanted).subtracting(now)
                result.strays = strays.count
                for (index, message) in listed.enumerated() where index + 1 < listed.count {
                    guard let header = message.messageIDHeader, wanted.contains(header), now.contains(header),
                        let next = listed[index + 1].messageIDHeader, strays.contains(next)
                    else { continue }
                    result.neighbourStrays += 1
                }
                print("probe: \(result)")
            } catch {
                print("probe: \(variant.rawValue) stopped: \(error)")
            }
        }

        if let large = Self.environment["APPLE_MAIL_MCP_PROBE_LARGE"] {
            for path in large.split(separator: ",").map(String.init) {
                guard let mailbox = boxes.first(where: { $0.path == path }),
                    let header = try store.headerRows(mailboxID: mailbox.id).values.first(where: { !$0.isEmpty })
                else { continue }
                do {
                    try Self.waitForMail()
                    let sent = Date()
                    _ = try mail.get(MailSpec.property("ID  ", of: MailSpec.message(header: header, in: MailboxTarget(mailbox))))
                    print("probe: whose lookup in a mailbox of \(try store.liveCount(mailboxID: mailbox.id)): \(Int(Date().timeIntervalSince(sent) * 1000)) ms")
                } catch {
                    print("probe: whose lookup failed: \(error)")
                }
            }
        }

        for probe in probes { await cleanUp(probe) }
    }

    /// Waits until Mail answers a cheap request again: after a burst of removals it can block for minutes.
    static func waitForMail(timeout: TimeInterval = 300) throws {
        let mail = MailEventSender(timeout: 20)
        let started = Date()
        while true {
            do {
                _ = try mail.get(MailSpec.property("pnam", of: MailSpec.every("mact", of: nil)))
                let waited = Date().timeIntervalSince(started)
                if waited > 2 { print("probe: Mail answered again after \(Int(waited)) s") }
                return
            } catch let error as AppleEventError where error.number == -1712 && Date().timeIntervalSince(started) < timeout {
                print("probe: waiting for Mail to answer…")
            }
        }
    }
}
