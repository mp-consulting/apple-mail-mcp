import Foundation
import MCP
import MailAutomation
import MailStore

// MARK: Verified changes

/// How long a move or trash waits for Mail's database to show what happened.
public struct ChangeVerification: Sendable {
    /// How long one message may take to leave its mailbox (and, for a move, arrive) before the change stops.
    public var timeout: TimeInterval
    public var interval: TimeInterval
    /// A pause before the mailbox is compared with how it was, so stray changes Mail makes late still show up.
    public var settle: TimeInterval
    /// After a message Mail never confirmed, a second look for strays this much later: Mail has removed the
    /// neighbour of such a message after its wait had ended.
    public var recheck: TimeInterval

    public init(timeout: TimeInterval = 10, interval: TimeInterval = 0.25, settle: TimeInterval = 1, recheck: TimeInterval = 5) {
        self.timeout = timeout
        self.interval = interval
        self.settle = settle
        self.recheck = recheck
    }
}

/// One source mailbox's share of a move or trash.
struct ChangeStep {
    var source: Mailbox
    /// Where the messages should land; nil when unknown (an account without a single Trash).
    var destination: Mailbox?
    var messages: [MessageSummary]
    /// A move only counts once the message shows up in `destination`.
    var mustArrive: Bool
}

/// A message that left a mailbox during a change although nobody asked for it.
struct Stray {
    var source: Mailbox
    var oldID: Int64
    var header: String?
    /// Where it is now, when it could be found (by Message-ID).
    var nowIn: Mailbox?
    var newID: Int64?
    /// Its id once put back in `source`.
    var restoredID: Int64?

    var json: JSON {
        .obj([
            ("old_id", .int(oldID)), ("header", header.map(JSON.string)), ("from", .string(source.path)),
            ("now_in", nowIn.map { .string($0.path) }), ("new_id", newID.map(JSON.int)), ("restored_id", restoredID.map(JSON.int)),
        ])
    }
}

/// What a move or trash really did, according to Mail's database rather than the Apple Event replies.
struct ChangeReport {
    var done: [Int64] = []
    var newIDs: [Int64: Int64] = [:]
    /// Requested, but not seen leaving the source mailbox before the wait ran out.
    var unverified: [Int64] = []
    /// Already gone from their mailbox when the change started.
    var gone: [Int64] = []
    /// Mail did not find them (or, found by id, they were not the message the store has there).
    /// With the mailbox each is in: Mail's index of it is out of step with the database.
    var missing: [(id: Int64, mailbox: Mailbox)] = []
    /// Left alone because something went wrong before them: not to be sent again blindly.
    var notAttempted: [Int64] = []
    /// Left alone because the call ran out of time: safe to send again.
    var resume: [Int64] = []
    /// Without a Message-ID of their own in their mailbox: Mail can only find them by id, which is done only for a
    /// call about one message.
    var oneByOne: [Int64] = []
    /// Mailboxes that changed more than the requested messages explain, by mailbox id.
    var evidence: [ChangeCheck.Collateral] = []
    var strayChangeID: String?
    var collateral: JSON?
    var error: (any Error)?

    var strays: [Stray] { evidence.flatMap(\.strays) }
    var straysRestored: Int { strays.filter { $0.restoredID != nil }.count }

    /// Every stray was named and put back, and the counts show nothing else.
    var straysAllRestored: Bool {
        !strays.isEmpty && strays.allSatisfy { $0.restoredID != nil }
            && evidence.allSatisfy { $0.drop && $0.actual - $0.expected <= $0.strays.count }
    }

    static let collateralWarning = """
        Mail changed more messages than requested. Stop all bulk changes and ask the user to check Trash and \
        the mailbox named in collateral_suspected (another device or a Mail rule can also cause this). \
        undo_change with stray_change_id puts back the strays listed there.
        """
    static let restoredWarning = """
        Mail also moved messages nobody asked for; they were put back (strays_restored). Stop bulk changes on this \
        mailbox for a few minutes and tell the user what happened.
        """
    static let unexpectedWarning = """
        The rows in collateral_suspected.unexpected reached that mailbox during the change and nothing explains them \
        (new mail and late copies of earlier changes are already left out): show them to the user.
        """
    static let unverifiedWarning = """
        Some messages had not left their mailbox when the wait ran out (Mail may be busy). Do not resend them; \
        search again later to see where they are.
        """
    static let resumeWarning = "The call stopped before its time ran out: send resume_ids in a new call."
    static let unseenWarning = """
        Mail's database lists the messages in mail_cannot_see, but Mail itself could not find them: its index of the \
        mailbox in rebuild_mailbox is out of step. Do not send them again; leave them out of further batches (search \
        marks them) and tell the user to select that mailbox in Mail and choose Mailbox › Rebuild.
        """
    static let oneByOneWarning = """
        Messages in retry_one_by_one have no Message-ID of their own in their mailbox, so Mail can only find them by \
        position: send each in a call of its own.
        """

    /// The reply fields shared by move and trash, after each tool's own.
    func fields(notFound: [Int64]) -> [(String, JSON?)] {
        let list = { (ids: [Int64]) -> JSON? in ids.isEmpty ? nil : .array(ids.map { .int($0) }) }
        var warnings: [String] = []
        if collateral != nil {
            warnings.append(straysAllRestored ? Self.restoredWarning : Self.collateralWarning)
            if evidence.first?.newcomers.isEmpty == false { warnings.append(Self.unexpectedWarning) }
        } else if !unverified.isEmpty {
            warnings.append(Self.unverifiedWarning)
        }
        if !resume.isEmpty { warnings.append(Self.resumeWarning) }
        if !oneByOne.isEmpty { warnings.append(Self.oneByOneWarning) }
        if !missing.isEmpty { warnings.append(Self.unseenWarning) }
        let missingIDs = missing.map(\.id)
        let rebuild = Set(missing.map(\.mailbox.path)).sorted()
        return [
            ("unverified", list(unverified)),
            ("not_found", list(notFound + gone + missingIDs)),
            ("mail_cannot_see", list(missingIDs)),
            ("rebuild_mailbox", rebuild.isEmpty ? nil : .array(rebuild.map { .string($0) })),
            ("collateral_suspected", collateral),
            ("strays_restored", straysRestored > 0 ? .int(Int64(straysRestored)) : nil),
            ("stray_change_id", strayChangeID.map(JSON.string)),
            ("not_attempted", list(notAttempted)),
            ("resume_ids", list(resume)),
            ("retry_one_by_one", list(oneByOne)),
            ("error", error.map { .string("\($0)") }),
            ("warning", warnings.isEmpty ? nil : .string(warnings.joined(separator: " "))),
        ]
    }

    func summary(_ verb: String) -> String {
        var text = "\(verb) \(done.count)"
        if !unverified.isEmpty { text += ", \(unverified.count) unverified" }
        if !resume.isEmpty { text += ", \(resume.count) left for lack of time" }
        if straysRestored > 0 { text += ", \(straysRestored) strays put back" }
        return collateral == nil ? text : "stopped, unexpected changes in Mail: " + text
    }
}

/// Mail's database just before one step of a change, compared with what it shows afterwards.
struct ChangeCheck {
    struct Outcome {
        /// Requested messages that left the source mailbox.
        var left: [Int64] = []
        /// Old id → new id of requested messages that showed up in the destination.
        var arrived: [Int64: Int64] = [:]
        /// Left the source and, for a move, reached the destination.
        var done: Set<Int64> = []
        var complete = false
    }

    /// A mailbox count that moved more than the requested messages explain, and the messages that did it.
    struct Collateral {
        var mailbox: Mailbox
        var drop: Bool
        var expected: Int
        var actual: Int
        var strays: [Stray] = []
        /// For a gain: how much of it rows that are not collateral explain (see ``Newcomer``).
        var explained = 0
        /// For a gain: the new rows nothing explains.
        var newcomers: [Newcomer] = []
    }

    /// A row that reached the destination during the change without being one of the requested messages.
    struct Newcomer {
        enum Reason: String {
            /// Its Message-ID is one of the source's other messages: Mail took it (as a copy, or a move it has
            /// not finished removing from the source).
            case fromSource = "from_source"
            /// Nothing explains it.
            case unexplained
        }

        var message: MessageSummary
        var reason: Reason

        var json: JSON {
            .obj([
                ("id", .int(message.id)), ("header", message.messageIDHeader.map(JSON.string)),
                ("received", Render.date(message.dateReceived)), ("reason", .string(reason.rawValue)),
            ])
        }
    }

    /// New mail that a gain in the destination may hold without it being collateral: received this recently, it can
    /// be mail the user deleted on another device during the change.
    static let newMailAge: TimeInterval = 24 * 3600

    let store: MailStore
    /// The step, narrowed to the messages still in the source mailbox.
    let step: ChangeStep
    let gone: [Int64]
    /// Every message in the source before the change: row → Message-ID ("" without one).
    let snapshot: [Int64: String]
    /// How many messages in the source carry each Message-ID.
    let headerCounts: [String: Int]
    let destinationCount: Int?
    /// Destination rows that already carried one of the requested Message-IDs.
    let destinationRows: Set<Int64>
    let headerless: Set<Int64>
    /// The highest row before the change: a moved message comes back above it.
    let maxRowID: Int64
    /// The source is too big to find messages by Message-ID quickly (see ``MailToolbox/headerLookupLimit``).
    let byID: Bool
    /// Message-IDs this server moved or trashed into the destination's account lately (from the change journal): Mail
    /// can bring a late copy of one into the destination minutes after its own change, which is not collateral. Read
    /// only when the destination gained rows nobody asked for.
    let recentlyMoved: () -> Set<String>

    var sourceCount: Int { snapshot.count }

    init(_ step: ChangeStep, store: MailStore, headerLookupLimit: Int, recentlyMoved: @escaping () -> Set<String> = { [] }) throws {
        self.store = store
        self.recentlyMoved = recentlyMoved
        maxRowID = try store.maxMessageRowID()
        let snapshot = try store.headerRows(mailboxID: step.source.id)
        self.snapshot = snapshot
        byID = snapshot.count > headerLookupLimit
        headerCounts = snapshot.values.reduce(into: [:]) { counts, header in
            if !header.isEmpty { counts[header, default: 0] += 1 }
        }
        destinationCount = try step.destination.map { try store.liveCount(mailboxID: $0.id) }
        var narrowed = step
        narrowed.messages = step.messages.filter { snapshot[$0.id] != nil }
        self.step = narrowed
        gone = step.messages.map(\.id).filter { snapshot[$0] == nil }
        headerless = Set(narrowed.messages.filter { $0.messageIDHeader == nil }.map(\.id))
        destinationRows = Set(try step.destination.map { try Self.rows(narrowed.messages, in: $0, store: store).values.flatMap { $0 } } ?? [])
    }

    /// Rows in `mailbox` carrying the Message-ID of one of `messages`, by Message-ID.
    static func rows(_ messages: [MessageSummary], in mailbox: Mailbox, store: MailStore) throws -> [String: [Int64]] {
        let found = try store.messages(messageIDHeaders: messages.compactMap(\.messageIDHeader), mailboxIDs: [mailbox.id])
        return found.reduce(into: [:]) { rows, message in
            if let header = message.messageIDHeader { rows[header, default: []].append(message.id) }
        }
    }

    /// How Mail is told which message: by its Message-ID when no other message in the source carries it. Without
    /// one, by id (checked against its subject and date), and only when the call is about this message `alone`. In a
    /// source too big for Message-ID lookups, every message goes by id, checked the same way, batch or not.
    func ref(_ message: MessageSummary, alone: Bool) -> MessageRef? {
        let ref = MessageRef(message, carriers: headerCounts, byID: byID)
        return ref.header != nil || alone || byID ? ref : nil
    }

    /// Where `messages` (all of the step's by default) stand now. The step's messages were sent by unique
    /// Message-ID, or by id once Mail confirmed the subject and date, so one message's outcome does not depend on the
    /// others.
    func outcome(of messages: [MessageSummary]? = nil) throws -> Outcome {
        let messages = messages ?? step.messages
        var outcome = Outcome()
        let stillThere = try store.present(ids: messages.map(\.id), mailboxID: step.source.id)
        // Mail can put a message back under a new ROWID: per Message-ID, count only as many as the source lost.
        let now = try Self.rows(messages, in: step.source, store: store)
        var lost = [String: Int]()
        for header in Set(messages.compactMap(\.messageIDHeader)) {
            lost[header] = (headerCounts[header] ?? 0) - (now[header]?.count ?? 0)
        }
        for message in messages where !stillThere.contains(message.id) {
            if let header = message.messageIDHeader {
                guard lost[header, default: 0] > 0 else { continue }
                lost[header, default: 0] -= 1
            }
            outcome.left.append(message.id)
        }
        if let destination = step.destination {
            let newest = try Self.rows(messages, in: destination, store: store)
                .compactMapValues { $0.filter { !destinationRows.contains($0) }.max() }
            for message in messages {
                if let header = message.messageIDHeader, let new = newest[header] { outcome.arrived[message.id] = new }
            }
        }
        // A message without a Message-ID cannot be found again: leaving the source has to do.
        outcome.done = Set(outcome.left.filter { !step.mustArrive || outcome.arrived[$0] != nil || headerless.contains($0) })
        outcome.complete = outcome.done.count == messages.count
        return outcome
    }

    /// Waits for `message` to show as done in Mail's database: looks at once, then again soon, then every `interval`,
    /// until `timeout` passes or the task is cancelled. Reads only that message's rows.
    func waitUntilDone(_ message: MessageSummary, timeout: TimeInterval, interval: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var pause = min(0.025, interval)
        while try !outcome(of: [message]).done.contains(message.id) {
            guard Date() < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(for: .seconds(pause))
            pause = min(pause * 2, interval)
        }
        return true
    }

    /// The final outcome, and the evidence when a mailbox changed more than it explains. Counts are read before
    /// the outcome, so changes landing in between can only excuse, never accuse.
    func verdict() throws -> (Outcome, Collateral?) {
        let sourceNow = try store.liveCount(mailboxID: step.source.id)
        let destinationNow = try step.destination.map { try store.liveCount(mailboxID: $0.id) }
        let outcome = try outcome()
        let strays = try self.strays()
        // New mail only raises the source count, so a bigger drop than the messages that left means strays.
        let drop = sourceCount - sourceNow
        if drop > outcome.left.count || !strays.isEmpty {
            return (outcome, Collateral(mailbox: step.source, drop: true, expected: outcome.left.count, actual: drop, strays: strays))
        }
        if let destination = step.destination, let before = destinationCount, let after = destinationNow {
            let expected = outcome.arrived.count + outcome.left.filter(headerless.contains).count
            let gain = after - before
            if gain > expected {
                // Only rows shown not to be collateral excuse part of the gain; the rest of it still stops the change.
                let (explained, suspects) = try newcomers(in: destination, outcome: outcome)
                if gain - explained > expected {
                    return (outcome, Collateral(
                        mailbox: destination, drop: false, expected: expected, actual: gain, explained: explained, newcomers: suspects))
                }
            }
        }
        return (outcome, nil)
    }

    /// The destination's rows above the pre-change maximum that are not the requested messages' arrivals, sorted into
    /// the ones that are not collateral (counted) and the rest. Not collateral: another copy of a requested message, a
    /// late copy of one this server moved lately (``recentlyMoved``), or mail received in the last ``newMailAge``
    /// (deleted on another device meanwhile). Collateral: one of the source's other messages, or anything else.
    func newcomers(in destination: Mailbox, outcome: Outcome, now: Date = Date()) throws -> (explained: Int, suspects: [Newcomer]) {
        let arrived = Set(outcome.arrived.values)
        let requested = Set(step.messages.compactMap(\.messageIDHeader))
        // Headerless requested messages are in the expected gain already; their rows cannot be told apart.
        var headerlessLeft = outcome.left.filter(headerless.contains).count
        var moved: Set<String>?
        var explained = 0
        var suspects: [Newcomer] = []
        for row in try store.messages(mailboxID: destination.id, above: maxRowID) where !arrived.contains(row.id) {
            let reason: Newcomer.Reason?
            if let header = row.messageIDHeader {
                if requested.contains(header) {
                    reason = nil
                } else if headerCounts[header] != nil {
                    reason = .fromSource
                } else if now.timeIntervalSince(row.dateReceived) < Self.newMailAge {
                    reason = nil
                } else {
                    if moved == nil { moved = recentlyMoved() }
                    reason = moved!.contains(header) ? nil : .unexplained
                }
            } else if headerlessLeft > 0 {
                headerlessLeft -= 1
                continue
            } else {
                reason = .unexplained
            }
            if let reason { suspects.append(Newcomer(message: row, reason: reason)) } else { explained += 1 }
        }
        return (explained, suspects)
    }

    /// The messages that left the source although nobody asked for them, and where they went.
    func strays() throws -> [Stray] {
        let now = try store.headerRows(mailboxID: step.source.id)
        let requested = Set(step.messages.map(\.id))
        var after: [String: Int] = [:]
        for header in now.values where !header.isEmpty { after[header, default: 0] += 1 }
        // Rows each Message-ID lost that the requested messages do not account for (a message Mail put back under
        // a new row lost none).
        var unexplained = headerCounts.reduce(into: [String: Int]()) { $0[$1.key] = $1.value - (after[$1.key] ?? 0) }
        for message in step.messages where now[message.id] == nil {
            if let header = message.messageIDHeader { unexplained[header, default: 0] -= 1 }
        }
        var found: [Stray] = []
        for (id, header) in snapshot.sorted(by: { $0.key < $1.key }) where now[id] == nil && !requested.contains(id) {
            if header.isEmpty {
                found.append(Stray(source: step.source, oldID: id))
            } else if unexplained[header, default: 0] > 0 {
                unexplained[header]! -= 1
                found.append(Stray(source: step.source, oldID: id, header: header))
            }
        }
        guard !found.isEmpty else { return [] }
        // Where they went: rows with their Message-ID elsewhere in the account, new since the change began (or the
        // same row, for a Gmail label).
        let boxes = try store.mailboxes(accountID: step.source.accountID).filter { $0.id != step.source.id }
        let oldIDs = Set(found.map(\.oldID))
        var landed = Dictionary(grouping: try store.messages(messageIDHeaders: found.compactMap(\.header), mailboxIDs: boxes.map(\.id))
            .filter { $0.id > maxRowID || oldIDs.contains($0.id) }, by: { $0.messageIDHeader ?? "" })
            .mapValues { $0.sorted { $0.id < $1.id } }
        for index in found.indices {
            guard let header = found[index].header, let row = landed[header]?.first else { continue }
            landed[header]?.removeFirst()
            found[index].newID = row.id
            found[index].nowIn = boxes.first { $0.id == row.mailboxID }
        }
        return found
    }
}

/// Mailboxes where a move or trash just went wrong (a message Mail never confirmed, or messages nobody asked for):
/// further moves and trashes there wait until Mail has settled. A file shared by every server process, since the
/// next batch comes as a new tool call, maybe through another one.
public final class ChangeBreaker: @unchecked Sendable {
    public struct Entry: Codable, Sendable, Hashable {
        public var mailboxID: Int64
        public var accountID: String
        public var mailbox: String
        public var tripped: Date
        /// Requested messages still in the mailbox when their wait ran out.
        public var pending: [Int64]
        /// Messages in the mailbox at that moment.
        public var count: Int
        /// Mail changed messages nobody asked for.
        public var collateral: Bool
    }

    /// The longest a mailbox stays closed.
    public var hold: TimeInterval = 120
    /// How long the mailbox must keep its messages before the pending ones count as staying where they are.
    public var quiet: TimeInterval = 15
    private let file: SharedJSONFile<[Entry]>

    public static let fileName = "breaker.json"

    public init(url: URL = SharedPaths.changeBreaker) {
        file = SharedJSONFile(url: url, empty: [])
    }

    public var entries: [Entry] { file.value }

    func trip(_ entry: Entry) {
        try? file.modify { entries in
            entries.removeAll { $0.mailboxID == entry.mailboxID }
            entries.append(entry)
        }
    }

    private func clear(_ mailboxID: Int64) {
        try? file.modify { $0.removeAll { $0.mailboxID == mailboxID } }
    }

    /// Why changes to `mailbox` must wait, or nil. An entry is removed once it settled (the pending messages left,
    /// or stayed put for `quiet` seconds, and nothing else went missing) or after `hold`.
    func refusal(for mailbox: Mailbox, store: MailStore, now: Date = Date()) throws -> String? {
        guard let entry = file.value.first(where: { $0.mailboxID == mailbox.id }) else { return nil }
        let age = now.timeIntervalSince(entry.tripped)
        guard age < hold else {
            clear(entry.mailboxID)
            return nil
        }
        let left = entry.pending.count - (try store.present(ids: entry.pending, mailboxID: mailbox.id).count)
        let expected = entry.count - left
        let live = try store.liveCount(mailboxID: mailbox.id)
        let until = "until \(Render.isoDate(entry.tripped.addingTimeInterval(hold))) at the latest"
        if live < expected {
            return """
                \(expected - live) more messages left \(mailbox.path) after the last change there, and nobody asked for \
                that. Moves and trashes in this mailbox are paused \(until): ask the user to check Trash first.
                """
        }
        if age >= quiet || (left == entry.pending.count && !entry.collateral) {
            clear(entry.mailboxID)
            return nil
        }
        let what = entry.collateral ? "Mail changed messages nobody asked for" : "\(entry.pending.count - left) messages are not confirmed"
        return """
            The last change to \(mailbox.path) has not settled in Mail yet (\(what)). Moves and trashes in this mailbox \
            are paused \(until); search again in a minute to see where the messages are.
            """
    }
}

/// Messages Mail's database lists but Mail itself could not find when asked to move or trash them: its index of the
/// mailbox is out of step (Mailbox › Rebuild fixes it). Kept so searches can mark them and callers stop sending them
/// again in every batch. Shared by every server process; entries go after `keep`, or once a change finds the message.
public final class UnseenMessages: @unchecked Sendable {
    /// A message by ROWID, which Mail changes when the message moves (or the mailbox is rebuilt).
    public struct Entry: Codable, Sendable, Hashable {
        public var id: Int64
        public var seen: Date
    }

    public static let fileName = "unseen.json"
    /// How long an entry stays.
    public var keep: TimeInterval = 7 * 24 * 3600
    /// The most entries kept (the newest).
    public var limit = 500
    private let file: SharedJSONFile<[Entry]>

    /// Messages Mail could not find in one mailbox, still there (by the store) and recorded lately.
    public struct MailboxCount: Sendable, Hashable, CustomStringConvertible {
        public var mailbox: String
        public var account: String
        public var count: Int

        /// "3 in Archive/2020 (iCloud)".
        public var description: String { "\(count) in \(mailbox) (\(account))" }
    }

    /// What the user does about them, for one mailbox or `several`.
    public static func advice(several: Bool) -> String {
        "Select \(several ? "each" : "it") in Mail and choose Mailbox › Rebuild."
    }

    public init(url: URL = SharedPaths.unseenMessages) {
        file = SharedJSONFile(url: url, empty: [])
    }

    public var entries: [Entry] { file.value }

    /// A short summary of `mailboxes` ("Mail can't see 3 messages"), and where they are and what to do; nil when
    /// there are none.
    public static func line(for mailboxes: [MailboxCount]) -> (title: String, detail: String)? {
        guard !mailboxes.isEmpty else { return nil }
        let total = mailboxes.reduce(0) { $0 + $1.count }
        // A mailbox name two accounts share is told apart by its account.
        let shared = Set(Dictionary(grouping: mailboxes, by: \.mailbox).filter { $0.value.count > 1 }.keys)
        let names = mailboxes.prefix(3).map { shared.contains($0.mailbox) ? "\($0.mailbox) (\($0.account))" : $0.mailbox }
            .joined(separator: ", ") + (mailboxes.count > 3 ? "…" : "")
        return (
            "Mail can't see \(total == 1 ? "1 message" : "\(total) messages")",
            "In \(names). " + advice(several: mailboxes.count > 1))
    }

    /// Per mailbox, most first: the recorded messages still in their mailbox. Rows gone since (moved, or given
    /// new ids by a rebuild) drop out, so a rebuilt mailbox leaves the list without anyone clearing it.
    public func mailboxes(in store: MailStore, now: Date = Date()) throws -> [MailboxCount] {
        let ids = file.value.filter { now.timeIntervalSince($0.seen) < keep }.map(\.id)
        guard !ids.isEmpty else { return [] }
        var counts: [MailboxCount] = []
        for (mailboxID, messages) in Dictionary(grouping: try store.messages(ids: ids), by: \.mailboxID) {
            let present = try store.present(ids: messages.map(\.id), mailboxID: mailboxID).count
            guard present > 0, let first = messages.first else { continue }
            counts.append(MailboxCount(mailbox: first.mailboxPath, account: first.accountName, count: present))
        }
        return counts.sorted { ($0.count, $1.mailbox) > ($1.count, $0.mailbox) }
    }

    /// Records `add` as not found by Mail just now and forgets `remove` (found after all), in one write.
    public func update(add: [Int64], remove: [Int64], now: Date = Date()) {
        let drop = Set(add + remove)
        // Most changes find every message: no write unless there is something to add or to forget.
        guard !add.isEmpty || file.value.contains(where: { drop.contains($0.id) }) else { return }
        try? file.modify { entries in
            entries.removeAll { drop.contains($0.id) || now.timeIntervalSince($0.seen) >= keep }
            entries += add.sorted().map { Entry(id: $0, seen: now) }
            if entries.count > limit { entries.removeFirst(entries.count - limit) }
        }
    }

    /// Forgets every entry: the user rebuilt the mailboxes, or does not want to hear about them. A change that misses
    /// messages again records them again.
    public func clear() {
        guard !file.value.isEmpty else { return }
        try? file.modify { $0.removeAll() }
    }

    /// Those of `messages` Mail could not find lately.
    func unseen(among messages: [MessageSummary], now: Date = Date()) -> [MessageSummary] {
        let known = Set(file.value.filter { now.timeIntervalSince($0.seen) < keep }.map(\.id))
        return known.isEmpty ? [] : messages.filter { known.contains($0.id) }
    }
}

extension MailToolbox {
    /// The time a call started, for its time budget (set by `call`).
    @TaskLocal static var callStart: Date?

    /// How Mail is told which message (see ``MessageRef``): by Message-ID when no other message in the mailbox
    /// carries it and the mailbox is small enough (``headerLookupLimit``), else by id, checked against the subject
    /// and date.
    func messageRefs(_ messages: [MessageSummary], in mailbox: Mailbox) throws -> [MessageRef] {
        let store = try self.store
        let byID = try store.liveCount(mailboxID: mailbox.id) > headerLookupLimit
        let carriers = byID ? [:] : try ChangeCheck.rows(messages, in: mailbox, store: store).mapValues(\.count)
        return messages.map { MessageRef($0, carriers: carriers, byID: byID) }
    }

    /// Refuses when a change to one of `mailboxes` went wrong moments ago (see ``ChangeBreaker``).
    func checkBreaker(_ mailboxes: [Mailbox]) throws {
        guard let breaker else { return }
        let store = try self.store
        for mailbox in mailboxes {
            if let reason = try breaker.refusal(for: mailbox, store: store) { throw ToolError(reason) }
        }
    }

    /// Applies `steps` one source mailbox at a time and one message at a time, holding the automation lock for the
    /// whole call. After each message it waits for Mail's database to show it gone (and arrived): Apple Events can
    /// report success for messages that never moved, and Mail has removed the neighbour of the message it was asked
    /// for. The first message that does not show up stops the call; so do an automation error, messages that left
    /// although nobody asked (they are named, put back when `restoreStrays` is on, and journalled), and the call's
    /// time budget. `send` returns whether Mail found the message.
    func applyVerified(_ steps: [ChangeStep], tool: String, send: (ChangeStep, MessageRef) async throws -> Bool) async throws -> ChangeReport {
        let store = try self.store
        try checkBreaker(steps.map(\.source))
        let timing = verification
        let current = settings.current
        let started = Self.callStart ?? Date()
        let perMessage = automation.messageEventTimeout + timing.timeout
        let alone = steps.reduce(0) { $0 + $1.messages.count } == 1
        let lookupBudget = headerLookupBudget
        enum Stop { case problem, budget }

        var (report, troubled) = try await automation.exclusive { () async throws -> (ChangeReport, [(ChangeCheck, [Int64])]) in
            var report = ChangeReport()
            var stop: Stop?
            var troubled: [(check: ChangeCheck, unverified: [Int64])] = []
            // Messages Mail has read for `whose message id` lookups so far in this call.
            var lookupWork = 0
            // Message-IDs earlier steps of this call moved, by account: not in the journal until the call ends.
            var movedThisCall: [String: Set<String>] = [:]
            func skip(_ id: Int64) {
                if stop == .budget { report.resume.append(id) } else { report.notAttempted.append(id) }
            }
            for step in steps {
                guard stop == nil else {
                    step.messages.forEach { skip($0.id) }
                    continue
                }
                let check = try ChangeCheck(
                    step, store: store, headerLookupLimit: headerLookupLimit,
                    recentlyMoved: { [weak self, earlier = step.destination.flatMap { movedThisCall[$0.accountID] } ?? []] in
                        earlier.union(step.destination.map { self?.recentlyMovedHeaders(accountID: $0.accountID) ?? [] } ?? [])
                    })
                report.gone += check.gone
                guard !check.step.messages.isEmpty else { continue }
                var sent: [Int64] = []
                for message in check.step.messages {
                    if stop == nil, current.callBudget > 0, Date().timeIntervalSince(started) + perMessage > current.callBudget { stop = .budget }
                    if stop == nil, Task.isCancelled {
                        report.error = CancellationError()
                        stop = .problem
                    }
                    guard stop == nil else {
                        skip(message.id)
                        continue
                    }
                    guard let ref = check.ref(message, alone: alone) else {
                        report.oneByOne.append(message.id)
                        continue
                    }
                    // A lookup by Message-ID makes Mail read the whole source mailbox: past the budget, the rest
                    // waits for a new call rather than piling up behind a busy Mail until an event times out.
                    if ref.header != nil {
                        if lookupWork > 0, lookupBudget > 0, lookupWork + check.sourceCount > lookupBudget {
                            stop = .budget
                            skip(message.id)
                            continue
                        }
                        lookupWork += check.sourceCount
                    }
                    var found = true
                    let sendStarted = Date()
                    do {
                        found = try await send(check.step, ref)
                    } catch {
                        report.error = error
                        stop = .problem
                    }
                    // Mail took half its event timeout for one message: it is falling behind, so stop after this one.
                    if stop == nil, automation.messageEventTimeout > 0,
                        Date().timeIntervalSince(sendStarted) > automation.messageEventTimeout / 2 {
                        stop = .budget
                    }
                    guard found else {
                        report.missing.append((message.id, check.step.source))
                        continue
                    }
                    sent.append(message.id)
                    // After an error (a timeout, say) Mail may still have acted: look once, without waiting.
                    let waitStarted = Date()
                    let confirmed = try await check.waitUntilDone(message, timeout: report.error == nil ? timing.timeout : 0, interval: timing.interval)
                    AutomationMetrics.current?.addVerify(Date().timeIntervalSince(waitStarted))
                    // Not sending the next message into a backlog: a move Mail has not carried out widens the gap
                    // between the mailbox it resolves against and the one it removes from.
                    if !confirmed { stop = .problem }
                }
                guard !sent.isEmpty else { continue }
                try? await Task.sleep(for: .seconds(timing.settle))
                let (outcome, collateral) = try check.verdict()
                for message in check.step.messages where outcome.done.contains(message.id) {
                    if let header = message.messageIDHeader { movedThisCall[check.step.source.accountID, default: []].insert(header) }
                }
                let unverified = sent.filter { !outcome.done.contains($0) }
                report.done += sent.filter { outcome.done.contains($0) }
                report.unverified += unverified
                for id in outcome.done { if let new = outcome.arrived[id] { report.newIDs[id] = new } }
                if let collateral {
                    report.evidence.append(collateral)
                    stop = .problem
                }
                if collateral != nil || !unverified.isEmpty { troubled.append((check, unverified)) }
            }
            // Strays have left after the requested message's wait ended: look again once Mail had time.
            if !troubled.isEmpty, timing.recheck > 0 {
                try? await Task.sleep(for: .seconds(timing.recheck))
                for (check, _) in troubled {
                    guard let late = try check.verdict().1, late.drop else { continue }
                    report.evidence.removeAll { $0.mailbox.id == late.mailbox.id && $0.drop }
                    report.evidence.append(late)
                }
            }
            if current.restoreStrays { try await restore(&report.evidence) }
            return (report, troubled.map { ($0.check, $0.unverified) })
        }

        if let unseen {
            unseen.update(add: report.missing.map(\.id), remove: report.done)
        }
        let accounts = (try? store.accounts()) ?? []
        if let first = report.evidence.first {
            let strays = report.strays
            report.collateral = .obj([
                ("mailbox", .string(first.mailbox.path)),
                ("account", accounts.first { $0.id == first.mailbox.accountID }.map { .string($0.name) }),
                (first.drop ? "expected_drop" : "expected_gain", .int(Int64(first.expected))),
                (first.drop ? "actual_drop" : "actual_gain", .int(Int64(first.actual))),
                ("explained_gain", first.explained > 0 ? .int(Int64(first.explained)) : nil),
                ("unexpected", first.newcomers.isEmpty ? nil : .array(first.newcomers.map(\.json))),
                ("strays", strays.isEmpty ? nil : .array(strays.map(\.json))),
            ])
            report.strayChangeID = journalStrays(strays, tool: tool)
        }
        for (check, unverified) in troubled {
            breaker?.trip(ChangeBreaker.Entry(
                mailboxID: check.step.source.id, accountID: check.step.source.accountID, mailbox: check.step.source.path,
                tripped: Date(), pending: unverified, count: (try? store.liveCount(mailboxID: check.step.source.id)) ?? check.sourceCount,
                collateral: report.evidence.contains { $0.mailbox.id == check.step.source.id || $0.mailbox.id == check.step.destination?.id }))
        }
        if let error = report.error, report.done.isEmpty, report.collateral == nil { throw error }
        return report
    }

    /// Message-IDs this server moved or trashed in `accountID` in the last ``ChangeCheck/newMailAge``: Mail can bring
    /// a late copy of one into Trash minutes later. Strays are left out: their copies are no one's request.
    func recentlyMovedHeaders(accountID: String, now: Date = Date()) -> Set<String> {
        let cutoff = now.addingTimeInterval(-ChangeCheck.newMailAge)
        var headers: Set<String> = []
        for record in changes?.records() ?? [] where record.date > cutoff && record.stray != true
            && (record.kind == .trash || record.kind == .move) {
            for item in record.items where item.accountID == accountID { headers.insert(item.messageID) }
        }
        return headers
    }

    /// Moves strays back where they were, found by Message-ID and checked the same way; sets their `restoredID`.
    private func restore(_ evidence: inout [ChangeCheck.Collateral]) async throws {
        let store = try self.store
        let timing = verification
        var restored: [Int64: Int64] = [:]
        let strays = evidence.flatMap(\.strays).filter { $0.header != nil && $0.newID != nil && $0.nowIn != nil }
        for (_, group) in Dictionary(grouping: strays, by: { [$0.nowIn!.id, $0.source.id] }) {
            let home = group[0].source, now = group[0].nowIn!
            let messages = try store.messages(ids: group.compactMap(\.newID))
            let check = try ChangeCheck(
                ChangeStep(source: now, destination: home, messages: messages, mustArrive: true), store: store, headerLookupLimit: headerLookupLimit)
            for message in check.step.messages {
                guard !Task.isCancelled, let ref = check.ref(message, alone: false) else { continue }
                guard (try? await automation.move([ref], from: MailboxTarget(now), to: MailboxTarget(home))) ?? 0 > 0 else { continue }
                _ = try await check.waitUntilDone(message, timeout: timing.timeout, interval: timing.interval)
            }
            let outcome = try check.outcome()
            for id in outcome.done { if let back = outcome.arrived[id] { restored[id] = back } }
        }
        for index in evidence.indices {
            for stray in evidence[index].strays.indices {
                if let new = evidence[index].strays[stray].newID, let back = restored[new] { evidence[index].strays[stray].restoredID = back }
            }
        }
    }
}

extension MessageRef {
    /// How Mail is told which message: by its Message-ID when `carriers` (rows per Message-ID in its mailbox) says
    /// no other message there carries it, else by id, checked against its subject and date. `byID`: always by id,
    /// for a mailbox too big to look up by Message-ID quickly.
    init(_ message: MessageSummary, carriers: [String: Int], byID: Bool = false) {
        self.init(
            id: message.id, header: byID ? nil : message.messageIDHeader.flatMap { carriers[$0] == 1 ? $0 : nil },
            subject: message.subject, dateReceived: message.dateReceived)
    }
}
