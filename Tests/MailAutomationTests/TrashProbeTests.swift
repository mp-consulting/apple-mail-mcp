import Foundation
import MailStore
import Testing

@testable import MailAutomation

/// Reproduces the 2026-10-20 incidents on real Mail: `delete message id <rowid>` sent back to back on an IMAP
/// mailbox removed the date-neighbour of some requested messages instead of the messages themselves, and `delete`
/// by Message-ID (0.6.1) still did. Each variant works on its own throwaway mailbox `MCP Probe <time> <variant>`,
/// filled with copies of messages from a mailbox the tester names, and trashes every second one:
///
/// - A: `delete message id`, back to back (the path before 0.6.1)
/// - B: `delete message id`, each waiting until the database shows the message gone
/// - C: `move message id … to` the account's Trash, back to back
/// - D: `delete (every message whose message id = …)`, back to back (the path of 0.6.1)
/// - E: `move (every message whose message id = …) to` the account's Trash, each waiting until the message shows up
///   there (the path from 0.6.2), while a second task moves 50 messages back and forth between two other probe
///   mailboxes of the account, so sync is busy as during the incident
///
/// `copiesLeftAfterRestore` checks the other thing seen that day: messages moved out of Trash left a copy behind
/// in Trash, or one came back there minutes later. It trashes and restores a probe mailbox the way the server does,
/// then counts rows per Message-ID in the probe mailbox and in Trash at +0, +1, +5 and +15 minutes.
///
/// Prints counts and timings only, never message content. At the end the copies in Trash go back to their probe
/// mailbox and the probe mailboxes are deleted (Mail must not delete messages already in Trash).
///
/// Opt in with APPLE_MAIL_MCP_LIVE_TRASH=1 (it changes mail), APPLE_MAIL_MCP_PROBE_ACCOUNT=<IMAP account id> and
/// APPLE_MAIL_MCP_PROBE_SOURCE=<mailbox path to copy from>. Optional: APPLE_MAIL_MCP_PROBE_COUNT (default 40),
/// APPLE_MAIL_MCP_PROBE_ROUNDS (default 1), APPLE_MAIL_MCP_PROBE_VARIANTS (e.g. "ACDE"), APPLE_MAIL_MCP_PROBE_GHOSTS=1
/// for `copiesLeftAfterRestore` (about 20 minutes), APPLE_MAIL_MCP_PROBE_LARGE=<path>[,<path>] to time a `whose`
/// lookup on big mailboxes (read only). Needs Full Disk Access for the test runner, to read Mail's database.
@Suite("Live trash probe", .serialized)
struct TrashProbeTests {
    static let environment = ProcessInfo.processInfo.environment
    static let enabled = environment["APPLE_MAIL_MCP_LIVE_TRASH"] == "1"
    static let ghosts = enabled && environment["APPLE_MAIL_MCP_PROBE_GHOSTS"] == "1"
    static let count = Int(environment["APPLE_MAIL_MCP_PROBE_COUNT"] ?? "") ?? 40
    /// Messages the load task of variant E moves back and forth.
    static let loadCount = 50

    enum Variant: String, CaseIterable {
        case a = "A", b = "B", c = "C", d = "D", e = "E"

        var label: String {
            switch self {
            case .a: "A delete by id, back to back"
            case .b: "B delete by id, paced"
            case .c: "C move by id to Trash"
            case .d: "D delete whose message id"
            case .e: "E move whose message id to Trash, paced, under load"
            }
        }
    }

    struct Result: CustomStringConvertible {
        var variant: Variant
        var rounds = 0
        var requested = 0
        var left = 0
        var stayed = 0
        var strays = 0
        /// Strays that are the next message in date order after a requested message that stayed.
        var neighbourStrays = 0
        var eventMs: [Double] = []
        var seconds: Double = 0
        /// Load moves made while the variant ran (E).
        var loadMoves = 0

        mutating func add(_ other: Result) {
            rounds += other.rounds
            requested += other.requested
            left += other.left
            stayed += other.stayed
            strays += other.strays
            neighbourStrays += other.neighbourStrays
            eventMs += other.eventMs
            seconds += other.seconds
            loadMoves += other.loadMoves
        }

        var description: String {
            let average = eventMs.isEmpty ? 0 : eventMs.reduce(0, +) / Double(eventMs.count)
            return "\(variant.label)\(rounds > 1 ? " (\(rounds) rounds)" : ""): requested \(requested), left \(left), "
                + "stayed \(stayed), strays \(strays) (\(neighbourStrays) date-neighbours of one that stayed), event avg "
                + "\(Int(average)) ms max \(Int(eventMs.max() ?? 0)) ms, \(String(format: "%.1f", seconds)) s"
                + (loadMoves > 0 ? ", \(loadMoves) load moves meanwhile" : "")
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

    /// The account, source mailbox and Trash a run works on, and the messages it may copy.
    final class Session: @unchecked Sendable {
        let store: MailStore
        let accountID: String
        let source: Mailbox
        let trash: Mailbox
        let automation = MailAutomation()
        let mail = MailEventSender(timeout: 60)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        /// Messages whose Message-ID only they carry in the source, newest first, handed out once each.
        private var unique: [Int64]

        init() throws {
            let accountID = try #require(TrashProbeTests.environment["APPLE_MAIL_MCP_PROBE_ACCOUNT"], "set APPLE_MAIL_MCP_PROBE_ACCOUNT")
            let sourcePath = try #require(TrashProbeTests.environment["APPLE_MAIL_MCP_PROBE_SOURCE"], "set APPLE_MAIL_MCP_PROBE_SOURCE")
            let store = try MailStore.open()
            let boxes = try store.mailboxes(accountID: accountID)
            self.store = store
            self.accountID = accountID
            source = try #require(boxes.first { $0.path == sourcePath }, "no mailbox \(sourcePath) in that account")
            // Some accounts have a second, empty Trash; Mail uses the main one (as the server does).
            trash = try #require(
                try boxes.filter { $0.role == .trash }.max { try store.liveCount(mailboxID: $0.id) < store.liveCount(mailboxID: $1.id) },
                "the account has no Trash")
            let rows = try store.headerRows(mailboxID: source.id)
            let counts = rows.values.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
            unique = rows.filter { !$0.value.isEmpty && counts[$0.value] == 1 }.keys.sorted(by: >)
            print("probe: copying from a mailbox of \(rows.count), \(unique.count) with a unique Message-ID")
        }

        func take(_ count: Int) throws -> [MessageSummary] {
            try #require(unique.count >= count, "the source has too few messages with a unique Message-ID left")
            defer { unique.removeFirst(count) }
            return try store.messages(ids: Array(unique.prefix(count)))
        }

        /// A new mailbox `MCP Probe <stamp> <name>` holding copies of `originals`, once Mail has settled.
        func makeProbe(_ name: String, copying originals: [MessageSummary]) async throws -> Probe {
            try TrashProbeTests.waitForMail()
            let target = MailboxTarget(accountID: accountID, path: "MCP Probe \(stamp) \(name)")
            try await automation.createMailbox(target)
            var created: Mailbox?
            _ = try TrashProbeTests.wait(60) {
                created = try store.mailboxes(accountID: accountID).first { $0.path == target.path }
                return created != nil
            }
            let mailbox = try #require(created, "Mail did not create \(target.path)")
            let probe = Probe(mailbox: mailbox, since: try store.maxMessageRowID(), headers: Set(originals.compactMap(\.messageIDHeader)))
            let copied = try await automation.copy(TrashProbeTests.refs(originals), from: MailboxTarget(source), to: target)
            let filled = try TrashProbeTests.wait(180) { try store.liveCount(mailboxID: mailbox.id) >= originals.count }
            print("probe: \(name): copied \(copied), \(try store.liveCount(mailboxID: mailbox.id)) in the probe mailbox")
            try #require(filled, "the copies did not all arrive")
            try TrashProbeTests.settle(store, mailbox)
            return probe
        }

        /// The copies in Trash go back to the probe mailbox, then the mailbox goes. A row in Trash counts as a copy only
        /// when it is newer than the probe, carries a Message-ID of the source, and the source still holds that message;
        /// one whose Message-ID is in Trash twice cannot be moved by Message-ID and stays.
        func cleanUp(_ probe: Probe) async {
            do {
                try TrashProbeTests.waitForMail()
                let stillInSource = Set(try store.headerRows(mailboxID: source.id).values.filter { !$0.isEmpty })
                let trashRows = try store.headerRows(mailboxID: trash.id)
                let trashCounts = trashRows.values.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
                let copies = trashRows.filter {
                    $0.key > probe.since && stillInSource.contains($0.value) && (probe.headers?.contains($0.value) ?? true)
                }
                let movable = try store.messages(ids: copies.filter { trashCounts[$0.value] == 1 }.map(\.key))
                _ = try await automation.move(TrashProbeTests.refs(movable), from: MailboxTarget(trash), to: MailboxTarget(probe.mailbox))
                let back = try TrashProbeTests.wait(120) { try store.present(ids: movable.map(\.id), mailboxID: trash.id).isEmpty }
                print("probe: \(probe.mailbox.path): \(movable.count) copies moved back from Trash\(back ? "" : " (not all yet)")")
                try TrashProbeTests.waitForMail()
                try mail.send("core", "delo", direct: MailSpec.mailbox(MailboxTarget(probe.mailbox)))
                print("probe: deleted \(probe.mailbox.path)")
                if copies.count > movable.count {
                    print("probe: \(copies.count - movable.count) probe copies stay in Trash (Message-ID there twice); delete them in Mail")
                }
            } catch {
                print("probe: could not clean up \(probe.mailbox.path): \(error); delete it in Mail")
            }
        }

        /// Probe mailboxes an earlier run left behind go first, so no Message-ID ends up in Trash twice.
        func cleanUpEarlierRuns() async throws {
            for box in try store.mailboxes(accountID: accountID) where box.path.hasPrefix("MCP Probe ") {
                let since = (try store.headerRows(mailboxID: box.id).keys.min() ?? Int64.max) - 1
                print("probe: cleaning up a probe mailbox an earlier run left")
                await cleanUp(Probe(mailbox: box, since: since, headers: nil))
            }
        }

        /// Moves the messages of `from` to `to` and back, one at a time by Message-ID, until `stop` is set; returns
        /// how many moves Mail took.
        func load(between from: Mailbox, and to: Mailbox, until stop: Flag) async -> Int {
            var moves = 0
            var (here, there) = (from, to)
            while !stop.isSet {
                guard let messages = try? store.messages(ids: Array(try store.headerRows(mailboxID: here.id).keys)) else { break }
                for ref in TrashProbeTests.refs(messages) where !stop.isSet {
                    moves += (try? await automation.move([ref], from: MailboxTarget(here), to: MailboxTarget(there))) ?? 0
                }
                (here, there) = (there, here)
            }
            return moves
        }
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    @Test(.enabled(if: enabled)) func neighbourRemoval() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)  // progress shows in a log file as it happens
        let rounds = max(1, Int(Self.environment["APPLE_MAIL_MCP_PROBE_ROUNDS"] ?? "") ?? 1)
        let variants = Self.environment["APPLE_MAIL_MCP_PROBE_VARIANTS"].map { $0.compactMap { Variant(rawValue: String($0).uppercased()) } }
            ?? Variant.allCases
        let session = try Session()
        let store = session.store
        let mail = session.mail
        try await session.cleanUpEarlierRuns()
        print("probe: \(Self.count) messages per variant, \(rounds) round(s)")

        var probes: [Probe] = []
        var totals: [Variant: Result] = [:]
        for round in 1...rounds {
            for variant in variants {
                let name = "\(variant.rawValue)\(rounds > 1 ? "\(round)" : "")"
                do {
                    let probe = try await session.makeProbe(name, copying: try session.take(Self.count))
                    probes.append(probe)
                    let mailbox = probe.mailbox
                    let target = MailboxTarget(mailbox)
                    let headers = Set(try store.headerRows(mailboxID: mailbox.id).values)

                    // Variant E: sync kept busy by another task moving messages between two more probe mailboxes.
                    let stop = Flag()
                    var loadTask: Task<Int, Never>?
                    if variant == .e {
                        let loadA = try await session.makeProbe("\(name) load A", copying: try session.take(Self.loadCount))
                        let loadB = try await session.makeProbe("\(name) load B", copying: [])
                        probes += [loadA, loadB]
                        loadTask = Task { await session.load(between: loadA.mailbox, and: loadB.mailbox, until: stop) }
                    }

                    // Every second message in list order (newest first) is requested.
                    let listed = try store.messages(ids: Array(try store.headerRows(mailboxID: mailbox.id).keys)).sorted { $0.dateReceived > $1.dateReceived }
                    let requested = listed.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
                    var result = Result(variant: variant, rounds: 1, requested: requested.count)
                    let started = Date()
                    let trash = MailboxTarget(session.trash)
                    for message in requested {
                        let byID = MailSpec.message(message.id, in: target)
                        let byHeader = MailSpec.message(header: message.messageIDHeader!, in: target)
                        let trashedBefore = try store.messages(messageIDHeaders: [message.messageIDHeader!], mailboxIDs: [session.trash.id]).count
                        let sent = Date()
                        do {
                            switch variant {
                            case .a, .b: try mail.send(.delete, to: byID)
                            case .c: try mail.send(.trash(to: trash), to: byID)
                            case .d: try mail.send(.delete, to: byHeader)
                            case .e: try mail.send(.trash(to: trash), to: byHeader)
                            }
                        } catch {
                            print("probe: \(name): event failed: \(error)")
                        }
                        result.eventMs.append(Date().timeIntervalSince(sent) * 1000)
                        switch variant {
                        case .b: _ = try Self.wait(15) { try store.present(ids: [message.id], mailboxID: mailbox.id).isEmpty }
                        case .e:
                            _ = try Self.wait(15) {
                                try store.present(ids: [message.id], mailboxID: mailbox.id).isEmpty
                                    && store.messages(messageIDHeaders: [message.messageIDHeader!], mailboxIDs: [session.trash.id]).count > trashedBefore
                            }
                        default: break
                        }
                    }
                    try Self.settle(store, mailbox)
                    result.seconds = Date().timeIntervalSince(started)
                    stop.set()
                    result.loadMoves = await loadTask?.value ?? 0

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
                    totals[variant, default: Result(variant: variant)].add(result)
                } catch {
                    print("probe: \(name) stopped: \(error)")
                }
            }
        }
        if rounds > 1 {
            for variant in variants { if let total = totals[variant] { print("probe: total \(total)") } }
        }

        if let large = Self.environment["APPLE_MAIL_MCP_PROBE_LARGE"] {
            let boxes = try store.mailboxes(accountID: session.accountID)
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

        for probe in probes { await session.cleanUp(probe) }
    }

    @Test(.enabled(if: ghosts)) func copiesLeftAfterRestore() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)  // progress shows in a log file as it happens
        let session = try Session()
        let store = session.store
        try await session.cleanUpEarlierRuns()
        let probe = try await session.makeProbe("ghosts", copying: try session.take(Self.count))
        let mailbox = probe.mailbox
        let headers = try #require(probe.headers)

        /// Rows per probe Message-ID in the probe mailbox and in Trash.
        func census(_ label: String) throws {
            let here = try store.messages(messageIDHeaders: Array(headers), mailboxIDs: [mailbox.id])
            let inTrash = try store.messages(messageIDHeaders: Array(headers), mailboxIDs: [session.trash.id])
            let twice = Dictionary(grouping: here, by: { $0.messageIDHeader ?? "" }).values.filter { $0.count > 1 }.count
            print("probe: ghosts \(label): \(here.count) rows in the probe mailbox (\(twice) Message-IDs twice), \(inTrash.count) in Trash")
        }

        // To Trash and back, one message at a time by Message-ID, as the server does.
        for message in try store.messages(ids: Array(try store.headerRows(mailboxID: mailbox.id).keys)) {
            _ = try await session.automation.trash(Self.refs([message]), in: MailboxTarget(mailbox), to: MailboxTarget(session.trash))
            _ = try Self.wait(15) { try store.present(ids: [message.id], mailboxID: mailbox.id).isEmpty }
        }
        try Self.settle(store, session.trash)
        try census("after trashing")
        let trashed = try store.messages(messageIDHeaders: Array(headers), mailboxIDs: [session.trash.id])
        for message in trashed {
            _ = try await session.automation.move(Self.refs([message]), from: MailboxTarget(session.trash), to: MailboxTarget(mailbox))
            _ = try Self.wait(15) { try store.present(ids: [message.id], mailboxID: session.trash.id).isEmpty }
        }
        let restored = Date()
        for minute in [0, 1, 5, 15] {
            let due = restored.addingTimeInterval(TimeInterval(minute * 60))
            if due > Date() { try await Task.sleep(for: .seconds(due.timeIntervalSinceNow)) }
            try census("+\(minute) min after the restore")
        }
        await session.cleanUp(probe)
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
