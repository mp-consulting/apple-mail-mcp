import Foundation
import MailStore
import Testing

@testable import MailAutomation

/// Reproduces the 2026-10-20 incidents on real Mail: `delete message id <rowid>` sent back to back on an IMAP
/// mailbox removed the date-neighbour of some requested messages instead of the messages themselves, and `delete`
/// by Message-ID (0.6.1) still did. Each variant works in its own probe mailbox `MCP Probe <variant>`, filled with
/// copies of messages from a mailbox the tester names, and trashes every second one:
///
/// - A: `delete message id`, back to back (the path before 0.6.1)
/// - B: `delete message id`, each waiting until the database shows the message gone
/// - C: `move message id … to` the account's Trash, back to back
/// - D: `delete (every message whose message id = …)`, back to back (the path of 0.6.1)
/// - E: `move (every message whose message id = …) to` the account's Trash, each waiting until the message shows up
///   there (the path from 0.6.2), while a second task moves 50 messages back and forth between `MCP Probe E load A`
///   and `… load B`, so sync is busy as during the incident
///
/// `copiesLeftAfterRestore` checks the other thing seen that day: messages moved out of Trash left a copy behind
/// in Trash, or one came back there minutes later. It trashes and restores `MCP Probe ghosts` the way the server
/// does, then counts rows per Message-ID in it and in Trash at +0, +1, +5 and +15 minutes.
///
/// Mail cannot delete a mailbox through scripting (-10000), and a new one can take minutes to reach its database, so
/// the probe mailboxes are made once and kept: a run first moves anything left in them to Trash, and ends by moving
/// its copies there too. Only copies ever go to Trash (safe to empty); the source is only read. Events that set
/// things up are tried again when Mail does not answer in time. Prints counts and timings only, never content.
///
/// Opt in with APPLE_MAIL_MCP_LIVE_TRASH=1 (it changes mail), APPLE_MAIL_MCP_PROBE_ACCOUNT=<IMAP account id> and
/// APPLE_MAIL_MCP_PROBE_SOURCE=<mailbox path to copy from>. Optional: APPLE_MAIL_MCP_PROBE_COUNT (default 40),
/// APPLE_MAIL_MCP_PROBE_ROUNDS (default 1), APPLE_MAIL_MCP_PROBE_VARIANTS (e.g. "ACDE"), APPLE_MAIL_MCP_PROBE_GHOSTS=1
/// for `copiesLeftAfterRestore` (about 20 minutes), APPLE_MAIL_MCP_PROBE_LARGE=<path>[,<path>] to time a `whose`
/// lookup on big mailboxes (read only), APPLE_MAIL_MCP_PROBE_LOG (default ~/Library/Logs/AppleMailMCP/probes.log, where
/// every line lands as it happens). Needs Full Disk Access for the test runner, to read Mail's database.
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

    /// Where the probes' lines go as they happen: `swift test` holds a test's output until it exits, so a long run
    /// showed nothing for hours and a restart lost it all. Counts and timings only, like everything the probes print.
    static let logURL = URL(filePath: environment["APPLE_MAIL_MCP_PROBE_LOG"]
        ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/AppleMailMCP/probes.log").path)
    private static let logLock = NSLock()

    /// Prints `line` and appends it, timestamped, to ``logURL`` at once.
    static func log(_ line: String) {
        print(line)
        logLock.withLock {
            try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let stamped = Data("\(ISO8601DateFormatter().string(from: Date())) \(line)\n".utf8)
            if let handle = try? FileHandle(forWritingTo: logURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: stamped)
                try? handle.close()
            } else {
                try? stamped.write(to: logURL)
            }
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

    /// Runs an event that sets things up, again (up to 3 times) when Mail did not answer in time, once it answers.
    /// Only for events that can be repeated safely (a move by Message-ID, making a mailbox that is checked first);
    /// not for a copy, nor for the events a variant measures: one that timed out may still have acted.
    static func retrying<T>(_ body: () async throws -> T) async throws -> T {
        for attempt in 1... {
            do {
                return try await body()
            } catch let error as AppleEventError where error.number == -1712 && attempt < 3 {
                TrashProbeTests.log("probe: Mail did not answer in time, trying again")
                try waitForMail()
            }
        }
        fatalError("unreachable")
    }

    /// The account, source mailbox and Trash a run works on, and the messages it may copy.
    final class Session: @unchecked Sendable {
        let store: MailStore
        let accountID: String
        let source: Mailbox
        let trash: Mailbox
        let automation = MailAutomation()
        let mail = MailEventSender(timeout: 60)
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
            try #require(!source.path.hasPrefix("MCP Probe"), "the source must not be a probe mailbox")
            // Some accounts have a second, empty Trash; Mail uses the main one (as the server does).
            trash = try #require(
                try boxes.filter { $0.role == .trash }.max { try store.liveCount(mailboxID: $0.id) < store.liveCount(mailboxID: $1.id) },
                "the account has no Trash")
            let rows = try store.headerRows(mailboxID: source.id)
            let counts = rows.values.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
            unique = rows.filter { !$0.value.isEmpty && counts[$0.value] == 1 }.keys.sorted(by: >)
            TrashProbeTests.log("probe: copying from a mailbox of \(rows.count), \(unique.count) with a unique Message-ID")
        }

        func take(_ count: Int) throws -> [MessageSummary] {
            try #require(unique.count >= count, "the source has too few messages with a unique Message-ID left")
            defer { unique.removeFirst(count) }
            return try store.messages(ids: Array(unique.prefix(count)))
        }

        /// The probe mailbox `MCP Probe <name>`: the one an earlier run made, else a new one (Mail can take minutes to
        /// list it in its database).
        func mailbox(_ name: String) async throws -> Mailbox {
            let target = MailboxTarget(accountID: accountID, path: "MCP Probe \(name)")
            if let existing = try store.mailboxes(accountID: accountID).first(where: { $0.path == target.path }) { return existing }
            try TrashProbeTests.waitForMail()
            // Made by an earlier run but not in the database yet: do not ask Mail for a second one.
            if (try? mail.get(MailSpec.property("pnam", of: MailSpec.mailbox(target)))) == nil {
                try await TrashProbeTests.retrying { try await automation.createMailbox(target) }
            }
            var created: Mailbox?
            _ = try TrashProbeTests.wait(300) {
                created = try store.mailboxes(accountID: accountID).first { $0.path == target.path }
                return created != nil
            }
            return try #require(created, "\(target.path) did not reach Mail's database in 5 minutes")
        }

        /// How Mail is told which message in `mailbox`: by Message-ID when no other message there carries it.
        func refs(_ messages: [MessageSummary], in mailbox: Mailbox) throws -> [MessageRef] {
            let counts = try store.headerRows(mailboxID: mailbox.id).values.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
            return messages.map {
                MessageRef(id: $0.id, header: $0.messageIDHeader.flatMap { counts[$0] == 1 ? $0 : nil }, subject: $0.subject, dateReceived: $0.dateReceived)
            }
        }

        /// Moves everything in a probe mailbox to Trash (copies only: a probe mailbox holds nothing else).
        func empty(_ mailbox: Mailbox) async {
            do {
                try #require(mailbox.path.hasPrefix("MCP Probe "), "not a probe mailbox")
                let messages = try store.messages(ids: Array(try store.headerRows(mailboxID: mailbox.id).keys))
                guard !messages.isEmpty else { return }
                try TrashProbeTests.waitForMail()
                for ref in try refs(messages, in: mailbox) {
                    _ = try await TrashProbeTests.retrying { try await automation.trash([ref], in: MailboxTarget(mailbox), to: MailboxTarget(trash)) }
                }
                let emptied = try TrashProbeTests.wait(180) { try store.liveCount(mailboxID: mailbox.id) == 0 }
                TrashProbeTests.log("probe: \(mailbox.path): \(messages.count) copies moved to Trash\(emptied ? "" : " (not all yet)")")
            } catch {
                TrashProbeTests.log("probe: could not empty \(mailbox.path): \(error)")
            }
        }

        /// Every probe mailbox emptied, so a run starts clean.
        func emptyProbeMailboxes() async throws {
            for box in try store.mailboxes(accountID: accountID) where box.path.hasPrefix("MCP Probe ") { await empty(box) }
        }

        /// `mailbox`, emptied, then holding copies of `originals`, once Mail has settled.
        func fill(_ mailbox: Mailbox, with originals: [MessageSummary]) async throws {
            await empty(mailbox)
            try TrashProbeTests.waitForMail()
            // By id: a copy removes nothing from the source, so no index can shift, and finding a message by its
            // Message-ID costs about 2.5 ms per message in the mailbox (some 20 s in a big archive). A copy that timed
            // out may still have been made: it is sent again only when it did not arrive.
            var copied = 0
            for original in originals {
                for attempt in 1...3 {
                    do {
                        try mail.send(.copy(to: MailboxTarget(mailbox)), to: MailSpec.message(original.id, in: MailboxTarget(source)))
                        copied += 1
                        break
                    } catch let error as AppleEventError where error.number == -1712 && attempt < 3 {
                        TrashProbeTests.log("probe: Mail did not answer in time, checking before trying again")
                        try TrashProbeTests.waitForMail()
                        let arrived = try original.messageIDHeader.map { header in
                            try TrashProbeTests.wait(30) { try !store.messages(messageIDHeaders: [header], mailboxIDs: [mailbox.id]).isEmpty }
                        } ?? false
                        if arrived { copied += 1; break }
                    }
                }
            }
            let filled = try TrashProbeTests.wait(180) { try store.liveCount(mailboxID: mailbox.id) >= originals.count }
            TrashProbeTests.log("probe: \(mailbox.path): copied \(copied), \(try store.liveCount(mailboxID: mailbox.id)) there")
            try #require(filled, "the copies did not all arrive")
            try TrashProbeTests.settle(store, mailbox)
        }

        /// Moves the messages of `from` to `to` and back, one at a time by Message-ID, until `stop` is set; returns
        /// how many moves Mail took.
        func load(between from: Mailbox, and to: Mailbox, until stop: Flag) async -> Int {
            var moves = 0
            var (here, there) = (from, to)
            while !stop.isSet {
                guard let messages = try? store.messages(ids: Array(try store.headerRows(mailboxID: here.id).keys)),
                    let refs = try? refs(messages, in: here)
                else { break }
                for ref in refs where !stop.isSet {
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
        Self.log("probe: ---- \(#function), logging to \(Self.logURL.path)")
        let rounds = max(1, Int(Self.environment["APPLE_MAIL_MCP_PROBE_ROUNDS"] ?? "") ?? 1)
        let variants = Self.environment["APPLE_MAIL_MCP_PROBE_VARIANTS"].map { $0.compactMap { Variant(rawValue: String($0).uppercased()) } }
            ?? Variant.allCases
        let session = try Session()
        let store = session.store
        let mail = session.mail
        try await session.emptyProbeMailboxes()
        TrashProbeTests.log("probe: \(Self.count) messages per variant, \(rounds) round(s)")

        var used: [Mailbox] = []
        var totals: [Variant: Result] = [:]
        for round in 1...rounds {
            for variant in variants {
                let name = "\(variant.rawValue)\(rounds > 1 ? "\(round)" : "")"
                do {
                    let mailbox = try await session.mailbox(variant.rawValue)
                    if !used.contains(mailbox) { used.append(mailbox) }
                    try await session.fill(mailbox, with: try session.take(Self.count))
                    let target = MailboxTarget(mailbox)
                    let headers = Set(try store.headerRows(mailboxID: mailbox.id).values)

                    // Variant E: sync kept busy by another task moving messages between two more probe mailboxes.
                    let stop = Flag()
                    var loadTask: Task<Int, Never>?
                    if variant == .e {
                        let loadA = try await session.mailbox("E load A"), loadB = try await session.mailbox("E load B")
                        for box in [loadA, loadB] where !used.contains(box) { used.append(box) }
                        await session.empty(loadB)
                        try await session.fill(loadA, with: try session.take(Self.loadCount))
                        loadTask = Task { await session.load(between: loadA, and: loadB, until: stop) }
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
                            TrashProbeTests.log("probe: \(name): event failed: \(error)")
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
                    TrashProbeTests.log("probe: \(result)")
                    totals[variant, default: Result(variant: variant)].add(result)
                } catch {
                    TrashProbeTests.log("probe: \(name) stopped: \(error)")
                }
            }
        }
        if rounds > 1 {
            for variant in variants { if let total = totals[variant] { TrashProbeTests.log("probe: total \(total)") } }
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
                    TrashProbeTests.log("probe: whose lookup in a mailbox of \(try store.liveCount(mailboxID: mailbox.id)): \(Int(Date().timeIntervalSince(sent) * 1000)) ms")
                } catch {
                    TrashProbeTests.log("probe: whose lookup failed: \(error)")
                }
            }
        }

        for mailbox in used { await session.empty(mailbox) }
    }

    @Test(.enabled(if: ghosts)) func copiesLeftAfterRestore() async throws {
        Self.log("probe: ---- \(#function), logging to \(Self.logURL.path)")
        let session = try Session()
        let store = session.store
        try await session.emptyProbeMailboxes()
        let mailbox = try await session.mailbox("ghosts")
        let originals = try session.take(Self.count)
        try await session.fill(mailbox, with: originals)
        let headers = Set(originals.compactMap(\.messageIDHeader))

        /// Rows per probe Message-ID in the probe mailbox and in Trash.
        func census(_ label: String) throws {
            let here = try store.messages(messageIDHeaders: Array(headers), mailboxIDs: [mailbox.id])
            let inTrash = try store.messages(messageIDHeaders: Array(headers), mailboxIDs: [session.trash.id])
            let twice = Dictionary(grouping: here, by: { $0.messageIDHeader ?? "" }).values.filter { $0.count > 1 }.count
            TrashProbeTests.log("probe: ghosts \(label): \(here.count) rows in the probe mailbox (\(twice) Message-IDs twice), \(inTrash.count) in Trash")
        }

        // To Trash and back, one message at a time by Message-ID, as the server does.
        for message in try store.messages(ids: Array(try store.headerRows(mailboxID: mailbox.id).keys)) {
            _ = try await Self.retrying {
                try await session.automation.trash(try session.refs([message], in: mailbox), in: MailboxTarget(mailbox), to: MailboxTarget(session.trash))
            }
            _ = try Self.wait(15) { try store.present(ids: [message.id], mailboxID: mailbox.id).isEmpty }
        }
        try Self.settle(store, session.trash)
        try census("after trashing")
        let trashed = try store.messages(messageIDHeaders: Array(headers), mailboxIDs: [session.trash.id])
        for message in trashed {
            _ = try await Self.retrying {
                try await session.automation.move(try session.refs([message], in: session.trash), from: MailboxTarget(session.trash), to: MailboxTarget(mailbox))
            }
            _ = try Self.wait(15) { try store.present(ids: [message.id], mailboxID: session.trash.id).isEmpty }
        }
        let restored = Date()
        for minute in [0, 1, 5, 15] {
            let due = restored.addingTimeInterval(TimeInterval(minute * 60))
            if due > Date() { try await Task.sleep(for: .seconds(due.timeIntervalSinceNow)) }
            try census("+\(minute) min after the restore")
        }
        await session.empty(mailbox)
    }

    /// Fills `MCP Probe big` with APPLE_MAIL_MCP_PROBE_BIG copies (more than the server's `headerLookupLimit`) and
    /// leaves them, so the server's own tools can be run on a big mailbox, e.g. `apple-mail-mcp call trash_messages`
    /// on some of its ids. The next probe run empties it into Trash like the other probe mailboxes.
    @Test(.enabled(if: enabled && environment["APPLE_MAIL_MCP_PROBE_BIG"] != nil)) func fillBigMailbox() async throws {
        Self.log("probe: ---- \(#function), logging to \(Self.logURL.path)")
        let count = try #require(Int(Self.environment["APPLE_MAIL_MCP_PROBE_BIG"] ?? ""), "APPLE_MAIL_MCP_PROBE_BIG must be a number")
        let session = try Session()
        let mailbox = try await session.mailbox("big")
        try await session.fill(mailbox, with: try session.take(count))
        Self.log("probe: big: \(try session.store.liveCount(mailboxID: mailbox.id)) copies in \(mailbox.path) (id \(mailbox.id))")
    }

    /// Waits until Mail answers a cheap request again: after a burst of removals it can block for minutes.
    static func waitForMail(timeout: TimeInterval = 300) throws {
        let mail = MailEventSender(timeout: 20)
        let started = Date()
        while true {
            do {
                _ = try mail.get(MailSpec.property("pnam", of: MailSpec.every("mact", of: nil)))
                let waited = Date().timeIntervalSince(started)
                if waited > 2 { TrashProbeTests.log("probe: Mail answered again after \(Int(waited)) s") }
                return
            } catch let error as AppleEventError where error.number == -1712 && Date().timeIntervalSince(started) < timeout {
                TrashProbeTests.log("probe: waiting for Mail to answer…")
            }
        }
    }
}
