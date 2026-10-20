import Foundation

/// A full-text index over message bodies, used to answer `bodyText` queries.
public protocol BodySearchIndex: Sendable {
    /// ROWIDs whose indexed text matches `text`.
    func matchingIDs(for text: String, limit: Int) throws -> [Int64]
    /// Every message with ROWID ≤ this value has been indexed (or found without a body).
    func coveredThrough() throws -> Int64
}

public enum MailStoreError: Error, CustomStringConvertible, Sendable {
    case unsupportedSchema(missing: [String])
    case accountNotFound(String, available: [String])
    case mailboxNotFound(String, account: String?)
    case messageNotFound(Int64)
    case bodyNotDownloaded(Int64)
    case attachmentNotFound(String)

    public var description: String {
        switch self {
        case .unsupportedSchema(let missing):
            "Unsupported Mail database schema (missing \(missing.joined(separator: ", "))). This Mail version is not supported yet."
        case .accountNotFound(let name, let available):
            "No account matches \"\(name)\". Accounts: \(available.joined(separator: ", "))"
        case .mailboxNotFound(let name, let account):
            "No mailbox matches \"\(name)\"\(account.map { " in \($0)" } ?? ""). Use list_mailboxes to see the names."
        case .messageNotFound(let id): "No message with id \(id)."
        case .bodyNotDownloaded(let id):
            "Message \(id) has not been downloaded by Mail yet (no .emlx on disk). Open it in Mail or check for new mail, then retry."
        case .attachmentNotFound(let name): "No attachment matches \"\(name)\"."
        }
    }
}

/// Read-only access to Apple Mail's data: the `Envelope Index` SQLite database
/// for envelopes and the `.emlx` files for content. Never talks to Mail.app.
public final class MailStore: @unchecked Sendable {
    public let location: MailLocation
    public let files: MessageFileLocator
    private let db: SQLiteConnection
    private let lock = NSLock()

    private var cachedDataVersion: Int64 = -1
    private var cachedMailboxes: [Int64: Mailbox] = [:]
    private var sortedMailboxes: [Mailbox] = []
    private var cachedAccounts: [MailAccount] = []
    private var extraAddresses: [String: Set<String>] = [:]

    /// Subjects and addresses in memory for text filters (see `TextLookups`).
    private let textLookups = TextLookups()
    /// A second read-only connection for counts (see `countInBackground`); opened on first use.
    private let countLock = NSLock()
    /// Lists of matches with the fingerprint of their mailboxes (see `walkMatches`); guarded by `lock`, like `db`.
    private var keptMatches: [StatementKey: (fingerprint: String, ids: [Int64])] = [:]
    private var countDB: SQLiteConnection?
    private var countCache: [StatementKey: Int64] = [:]
    private var countCacheVersion: Int64 = -1

    /// Message files parsed recently, so reading a thread or a message again skips parsing MIME and HTML.
    private let parsedMessages = CappedCache<ParsedMessage>(capacity: 32 << 20, size: \.size)

    /// Folded text of messages body searches had to scan (mail the index has not reached, or no index), so the next
    /// search reads memory instead of reopening the same files.
    private let scannedText = CappedCache<[UInt8]>(capacity: 32 << 20, size: \.count)

    /// Serialises cache rebuilds; the fields below belong to it.
    private let refreshLock = NSLock()
    private struct ParsedMailboxURL {
        var url: MailboxURL
        var role: MailboxRole
    }
    private var parsedMailboxURLs: [String: ParsedMailboxURL] = [:]
    /// Hash of the mailbox table the cached mailboxes were built from (see `mailboxTableHash`).
    private var builtFromMailboxTable: Int?
    private var accountNames: [String: String] = [:]
    private var namedAccountIDs: Set<String>?
    private var detectedAddresses: [String: Set<String>] = [:]
    private var detectedSentSignature: [SentMailboxState]?
    private var detectedAt = Date.distantPast
    static let ownAddressMaxAge: TimeInterval = 300
    /// How many times own addresses were detected (tests check that unrelated writes skip it).
    private(set) var ownAddressDetections = 0
    /// How many times the mailbox list was built (tests check that writes elsewhere skip it).
    private(set) var mailboxReloads = 0

    private struct SentMailboxState: Equatable {
        var id: Int64
        var accountID: String
        var totalCount: Int
    }

    static let requiredColumns: [String: [String]] = [
        "messages": [
            "ROWID", "message_id", "global_message_id", "sender", "subject_prefix", "subject", "summary",
            "date_sent", "date_received", "mailbox", "read", "flagged", "deleted", "size", "conversation_id",
            "flags", "list_id_hash", "unsubscribe_type",
        ],
        "subjects": ["ROWID", "subject"],
        "addresses": ["ROWID", "address", "comment"],
        "mailboxes": ["ROWID", "url", "total_count", "unread_count", "source"],
        "recipients": ["message", "address", "type", "position"],
        "attachments": ["message", "attachment_id", "name"],
        "summaries": ["ROWID", "summary"],
        "labels": ["message_id", "mailbox_id"],
        "message_global_data": ["ROWID", "message_id_header"],
    ]

    public init(location: MailLocation) throws {
        self.location = location
        files = MessageFileLocator(root: location.root)
        db = try SQLiteConnection(path: location.envelopeIndex.path, readOnly: true)
        var missing: [String] = []
        for (table, columns) in Self.requiredColumns {
            let present = try db.columns(of: table)
            for column in columns where !present.contains(column) && !(column == "ROWID" && !present.isEmpty) {
                missing.append("\(table).\(column)")
            }
        }
        guard missing.isEmpty else { throw MailStoreError.unsupportedSchema(missing: missing.sorted()) }
        hasCategories = (try db.columns(of: "message_global_data")).contains("model_category")
    }

    /// macOS 15+ stores Mail's on-device category (Primary, Transactions, Updates, Promotions).
    let hasCategories: Bool

    /// Convenience: the current user's Mail store.
    public static func open() throws -> MailStore { try MailStore(location: MailLocation.discover()) }

    func withDB<T>(_ body: (SQLiteConnection) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(db)
    }

    // MARK: Change tracking

    /// Changes whenever Mail commits to the index (cheap; used to invalidate caches).
    public func dataVersion() throws -> Int64 {
        try withDB { try $0.scalarInt("PRAGMA data_version") ?? 0 }
    }

    public func maxMessageRowID() throws -> Int64 {
        try withDB { try $0.scalarInt("SELECT IFNULL(MAX(ROWID), 0) FROM messages") ?? 0 }
    }

    public func messageCount() throws -> Int {
        Int(try withDB { try $0.scalarInt("SELECT COUNT(*) FROM messages WHERE deleted = 0") ?? 0 })
    }

    // MARK: Accounts and mailboxes

    /// Reloads the mailboxes when Mail has committed since the last look. With Mail running that is nearly every
    /// call, so the costly parts are kept apart: own addresses (a GROUP BY over all Sent mail) are recomputed only
    /// when the Sent mailboxes or their counts change, or every few minutes; account names (Accounts4.sqlite) only
    /// when the set of accounts changes.
    private func refreshCachesIfNeeded() throws {
        let version = try dataVersion()
        if isCacheFresh(version) { return }
        // One rebuild at a time: a second caller waits, then finds the cache fresh.
        refreshLock.lock()
        defer { refreshLock.unlock() }
        if isCacheFresh(version) { return }
        // Mail commits for many reasons (flags, new mail elsewhere, its own bookkeeping); when no mailbox row
        // changed, the mailboxes and accounts stand as they are.
        if Date().timeIntervalSince(detectedAt) <= Self.ownAddressMaxAge, try mailboxTableHash() == builtFromMailboxTable {
            lock.withLock { cachedDataVersion = version }
            return
        }

        // With Mail running this runs on nearly every call, for new counts; a mailbox's URL (and so its name, path
        // and role) does not change, so each is parsed once.
        var mailboxes: [Int64: Mailbox] = [:]
        var schemes: [String: String] = [:]
        var table = Hasher()
        try withDB { db in
            try db.query(Self.mailboxRowsSQL) { row in
                Self.combine(row, into: &table)
                let url = row.string(1)
                let parsed: ParsedMailboxURL
                if let known = parsedMailboxURLs[url] {
                    parsed = known
                } else {
                    guard let fresh = MailboxURL(url) else { return }
                    parsed = ParsedMailboxURL(url: fresh, role: MailboxRoleDetector.role(for: fresh))
                    parsedMailboxURLs[url] = parsed
                }
                let id = row.int(0)
                mailboxes[id] = Mailbox(
                    id: id, url: url, accountID: parsed.url.accountID, path: parsed.url.path, name: parsed.url.name,
                    role: parsed.role, totalCount: Int(row.int(2)), unreadCount: Int(row.int(3)),
                    sourceMailboxID: row.optionalInt(4))
                schemes[parsed.url.accountID] = parsed.url.scheme
            }
        }
        let accountIDs = Set(schemes.keys)
        if accountIDs != namedAccountIDs {
            accountNames = AccountDirectory.names(for: accountIDs, accountsDatabase: location.accountsDatabase)
            namedAccountIDs = accountIDs
        }
        let sentSignature = mailboxes.values.filter { $0.role == .sent }
            .map { SentMailboxState(id: $0.id, accountID: $0.accountID, totalCount: $0.totalCount) }
            .sorted { $0.id < $1.id }
        if sentSignature != detectedSentSignature || Date().timeIntervalSince(detectedAt) > Self.ownAddressMaxAge {
            detectedAddresses = try detectOwnAddresses(mailboxes: mailboxes)
            detectedSentSignature = sentSignature
            detectedAt = Date()
            ownAddressDetections += 1
        }
        builtFromMailboxTable = table.finalize()
        mailboxReloads += 1

        // In listing order, sorted once per reload (lowercasing each path once, not in every comparison).
        let sorted = mailboxes.values.map { ($0.accountID, $0.path.lowercased(), $0) }
            .sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
        lock.lock()
        defer { lock.unlock() }
        // Addresses registered meanwhile (`registerOwnAddresses`) are read under the same lock, so none is lost.
        cachedAccounts = schemes.keys.sorted().map { id -> MailAccount in
            let addresses = detectedAddresses[id, default: []].union(extraAddresses[id, default: []])
            return MailAccount(id: id, name: accountNames[id] ?? id, kind: schemes[id] ?? "imap", emailAddresses: addresses.sorted())
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        cachedMailboxes = mailboxes
        sortedMailboxes = sorted
        cachedDataVersion = version
    }

    private static let mailboxRowsSQL = "SELECT ROWID, url, total_count, unread_count, source FROM mailboxes"

    private static func combine(_ row: SQLiteConnection.Row, into hasher: inout Hasher) {
        hasher.combine(row.int(0))
        row.withBytes(1) { hasher.combine(bytes: $0) }
        hasher.combine(row.int(2))
        hasher.combine(row.int(3))
        hasher.combine(row.optionalInt(4))
    }

    /// A hash of Mail's mailbox table (rows, URLs, counts), read without making strings: equal to
    /// `builtFromMailboxTable` when the cached mailboxes still match it.
    private func mailboxTableHash() throws -> Int {
        var table = Hasher()
        try withDB { db in try db.query(Self.mailboxRowsSQL) { Self.combine($0, into: &table) } }
        return table.finalize()
    }

    /// Mail's data version as of the last `refreshCachesIfNeeded` (callers refresh first, e.g. via `lookupTables`):
    /// one PRAGMA per call rather than one per cache. -1 when it is about to be read again.
    func seenDataVersion() -> Int64 {
        lock.withLock { cachedDataVersion }
    }

    private func isCacheFresh(_ version: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return version == cachedDataVersion && !cachedMailboxes.isEmpty
    }

    /// The sender addresses that dominate each account's Sent mailboxes.
    private func detectOwnAddresses(mailboxes: [Int64: Mailbox]) throws -> [String: Set<String>] {
        let sent = mailboxes.values.filter { $0.role == .sent }
        guard !sent.isEmpty else { return [:] }
        var result: [String: Set<String>] = [:]
        try withDB { db in
            for mailbox in sent {
                let membership = mailbox.sourceMailboxID == nil
                    ? "m.mailbox = ?"
                    : "m.ROWID IN (SELECT message_id FROM labels WHERE mailbox_id = ?)"
                var rows: [(String, Int64)] = []
                try db.query(
                    """
                    SELECT lower(a.address), COUNT(*) AS n FROM messages m JOIN addresses a ON a.ROWID = m.sender
                    WHERE \(membership) AND m.deleted = 0 GROUP BY lower(a.address) ORDER BY n DESC LIMIT 5
                    """, [.int(mailbox.id)]
                ) { rows.append(($0.string(0), $0.int(1))) }
                let total = rows.reduce(0) { $0 + $1.1 }
                for (address, count) in rows where count >= 2 && Double(count) >= Double(total) * 0.05 {
                    result[mailbox.accountID, default: []].insert(address)
                }
            }
        }
        return result
    }

    /// Adds addresses known from elsewhere (Mail's AppleScript `email addresses`, config).
    public func registerOwnAddresses(_ addresses: [String], accountID: String) {
        lock.lock()
        let added = Set(addresses.map { $0.lowercased() })
        extraAddresses[accountID, default: []].formUnion(added)
        if let index = cachedAccounts.firstIndex(where: { $0.id == accountID }) {
            cachedAccounts[index].emailAddresses = Set(cachedAccounts[index].emailAddresses).union(added).sorted()
        }
        lock.unlock()
    }

    public func accounts() throws -> [MailAccount] {
        try refreshCachesIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return cachedAccounts
    }

    /// Every address the user sends from, lowercased.
    public func ownAddresses() throws -> Set<String> {
        Set(try accounts().flatMap(\.emailAddresses).map { $0.lowercased() })
    }

    public func mailboxes(accountID: String? = nil) throws -> [Mailbox] {
        try refreshCachesIfNeeded()
        let all = lock.withLock { sortedMailboxes }
        return accountID == nil ? all : all.filter { $0.accountID == accountID }
    }

    public func mailbox(id: Int64) throws -> Mailbox? {
        try refreshCachesIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return cachedMailboxes[id]
    }

    /// Finds an account by name, UUID or one of its addresses (case-insensitive).
    public func resolveAccount(_ text: String) throws -> MailAccount {
        let accounts = try accounts()
        let needle = text.trimmingCharacters(in: .whitespaces)
        if let exact = accounts.first(where: {
            $0.id.caseInsensitiveCompare(needle) == .orderedSame || $0.name.caseInsensitiveCompare(needle) == .orderedSame
                || $0.emailAddresses.contains { $0.caseInsensitiveCompare(needle) == .orderedSame }
        }) {
            return exact
        }
        let partial = accounts.filter { $0.name.localizedCaseInsensitiveContains(needle) }
        if partial.count == 1 { return partial[0] }
        throw MailStoreError.accountNotFound(text, available: accounts.map(\.name))
    }

    /// Resolves a mailbox by path (`Archive/2020`), name (`INBOX`) or role
    /// (`sent`, `trash`, `junk`, `drafts`, `archive`, `inbox`), optionally within one account.
    public func resolveMailboxes(_ text: String, accountID: String? = nil) throws -> [Mailbox] {
        let candidates = try mailboxes(accountID: accountID)
        let needle = text.trimmingCharacters(in: .whitespaces).precomposedStringWithCanonicalMapping
        let lower = needle.lowercased()
        let byPath = candidates.filter { $0.path.lowercased() == lower }
        if !byPath.isEmpty { return byPath }
        if let role = MailboxRole(rawValue: lower.replacingOccurrences(of: " ", with: "_")) ?? roleAlias(lower) {
            let byRole = candidates.filter { $0.role == role }
            if !byRole.isEmpty { return byRole }
        }
        let byName = candidates.filter { $0.name.lowercased() == lower }
        if !byName.isEmpty { return byName }
        let accountName = try accountID.map { id in try accounts().first { $0.id == id }?.name ?? id }
        throw MailStoreError.mailboxNotFound(text, account: accountName)
    }

    private func roleAlias(_ text: String) -> MailboxRole? {
        switch text {
        case "sent messages", "sent items", "sent mail": .sent
        case "deleted messages", "deleted items", "bin": .trash
        case "spam": .junk
        case "all mail": .allMail
        default: nil
        }
    }

    // MARK: Messages

    private var summaryColumns: String {
        """
        m.ROWID, IFNULL(m.subject_prefix, '') || s.subject, a.address, a.comment, m.date_received, m.date_sent,
        m.mailbox, m.read, m.flagged, (m.flags >> 39) & 7, m.size, m.conversation_id, su.summary, g.message_id_header,
        EXISTS(SELECT 1 FROM attachments t WHERE t.message = m.ROWID), \(hasCategories ? "g.model_category" : "NULL")
        """
    }
    static let summaryJoins = """
        FROM messages m
        JOIN subjects s ON s.ROWID = m.subject
        LEFT JOIN addresses a ON a.ROWID = m.sender
        LEFT JOIN summaries su ON su.ROWID = m.summary
        LEFT JOIN message_global_data g ON g.ROWID = m.global_message_id
        """

    private func summary(from row: SQLiteConnection.Row, mailboxes: [Int64: Mailbox], accountNames: [String: String]) -> MessageSummary {
        let mailboxID = row.int(6)
        let mailbox = mailboxes[mailboxID]
        let accountID = mailbox?.accountID ?? ""
        var messageID = row.optionalString(13)
        if let id = messageID { messageID = id.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) }
        let preview = row.optionalString(12).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return MessageSummary(
            id: row.int(0),
            subject: row.string(1),
            sender: EmailAddress(address: row.string(2), name: row.optionalString(3)),
            dateReceived: Date(timeIntervalSince1970: TimeInterval(row.int(4))),
            dateSent: row.optionalInt(5).map { Date(timeIntervalSince1970: TimeInterval($0)) },
            mailboxID: mailboxID,
            mailboxPath: mailbox?.path ?? "",
            accountID: accountID,
            accountName: accountNames[accountID] ?? accountID,
            isRead: row.int(7) != 0,
            isFlagged: row.int(8) != 0,
            flagColor: row.int(8) != 0 ? row.optionalInt(9).flatMap { FlagColor(rawValue: Int($0)) } ?? .red : nil,
            size: Int(row.int(10)),
            conversationID: row.int(11),
            hasAttachments: row.int(14) != 0,
            preview: (preview?.isEmpty ?? true) ? nil : preview,
            messageIDHeader: (messageID?.isEmpty ?? true) ? nil : messageID,
            category: row.optionalInt(15).flatMap { MailCategory(rawValue: Int($0)) })
    }

    func lookupTables() throws -> ([Int64: Mailbox], [String: String]) {
        try refreshCachesIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return (cachedMailboxes, Dictionary(uniqueKeysWithValues: cachedAccounts.map { ($0.id, $0.name) }))
    }

    public func messages(ids: [Int64]) throws -> [MessageSummary] {
        guard !ids.isEmpty else { return [] }
        let (mailboxes, names) = try lookupTables()
        return try messages(ids: ids, mailboxes: mailboxes, accountNames: names)
    }

    private func messages(ids: [Int64], mailboxes: [Int64: Mailbox], accountNames names: [String: String]) throws -> [MessageSummary] {
        guard !ids.isEmpty else { return [] }
        let json = MailStore.idArray(ids)
        let found = try withDB { db in
            try db.all(
                "SELECT \(summaryColumns) \(Self.summaryJoins) WHERE m.ROWID IN (SELECT value FROM json_each(?))",
                [json]
            ) { summary(from: $0, mailboxes: mailboxes, accountNames: names) }
        }
        let byID = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { byID[$0] }
    }

    /// Messages in `mailboxIDs` whose `Message-ID` header is one of `headers`
    /// (used to find a message's new ROWID after Mail moved it).
    public func messages(messageIDHeaders headers: [String], mailboxIDs: [Int64]) throws -> [MessageSummary] {
        guard !headers.isEmpty, !mailboxIDs.isEmpty else { return [] }
        let (mailboxes, names) = try lookupTables()
        let variants = headers.flatMap { [$0, "<\($0)>"] }
        let headerJSON = Self.jsonArray(variants)
        let mailboxJSON = MailStore.idArray(mailboxIDs)
        return try withDB { db in
            try db.all(
                """
                SELECT \(summaryColumns) \(Self.summaryJoins)
                WHERE m.deleted = 0 AND g.message_id_header IN (SELECT value FROM json_each(?))
                AND (m.mailbox IN (SELECT value FROM json_each(?))
                     OR m.ROWID IN (SELECT message_id FROM labels WHERE mailbox_id IN (SELECT value FROM json_each(?))))
                """, [.text(headerJSON), mailboxJSON, mailboxJSON]
            ) { summary(from: $0, mailboxes: mailboxes, accountNames: names) }
        }
    }

    /// Messages in a mailbox now, counted from the rows (Mail updates `mailboxes.total_count` later).
    public func liveCount(mailboxID: Int64) throws -> Int {
        Int(
            try withDB { db in
                try db.scalarInt(
                    """
                    SELECT COUNT(*) FROM messages m WHERE m.deleted = 0
                    AND (m.mailbox = ? OR m.ROWID IN (SELECT message_id FROM labels WHERE mailbox_id = ?))
                    """, [.int(mailboxID), .int(mailboxID)]) ?? 0
            })
    }

    /// The subset of `ids` still in the mailbox (not deleted, directly or through a label).
    public func present(ids: [Int64], mailboxID: Int64) throws -> Set<Int64> {
        guard !ids.isEmpty else { return [] }
        let json = MailStore.idArray(ids)
        return Set(
            try withDB { db in
                try db.all(
                    """
                    SELECT m.ROWID FROM messages m WHERE m.ROWID IN (SELECT value FROM json_each(?)) AND m.deleted = 0
                    AND (m.mailbox = ? OR m.ROWID IN (SELECT message_id FROM labels WHERE mailbox_id = ?))
                    """, [json, .int(mailboxID), .int(mailboxID)]
                ) { $0.int(0) }
            })
    }

    public func message(id: Int64) throws -> MessageSummary {
        guard let found = try messages(ids: [id]).first else { throw MailStoreError.messageNotFound(id) }
        return found
    }

    /// The WHERE clause for a search's page (`sql`) and for counting its matches (`countSQL`), built in one pass:
    /// they share their bindings and the in-memory text lookups, and differ only in planner hints.
    ///
    /// For the count: walking the (deleted, date_received) index only pays off for a short page in date order; a
    /// count is cheaper through the text filter's own index (sender, recipients) or a plain table scan, so `+`
    /// takes that index and the default mailbox list out of the planner's choice.
    struct WhereClause {
        var sql: String
        var countSQL: String
        var bindings: [SQLValue]
    }

    /// Mailboxes holding up to this many messages are walked, testing each row, rather than reached through a
    /// text filter's index (see `whereClauses`).
    static let walkScopeLimit = 20_000

    /// How many messages the query's mailboxes hold; nil when it is not limited to mailboxes.
    static func scopeSize(of query: MessageQuery, mailboxes: [Int64: Mailbox]) -> Int? {
        query.mailboxIDs.isEmpty ? nil : query.mailboxIDs.reduce(0) { $0 + (mailboxes[$1]?.totalCount ?? 0) }
    }

    /// The page's clause alone, or the count's (see `whereClauses`).
    func whereClause(for query: MessageQuery, mailboxes: [Int64: Mailbox], forCount: Bool = false) -> (String, [SQLValue]) {
        let clause = whereClauses(for: query, mailboxes: mailboxes)
        return (forCount ? clause.countSQL : clause.sql, clause.bindings)
    }

    func whereClauses(for query: MessageQuery, mailboxes: [Int64: Mailbox]) -> WhereClause {
        // With a mailbox, conversation or id scope, `+` keeps SQLite off the (deleted, date_received)
        // index, which otherwise wins and walks every message instead of the scope's own index.
        let scoped = !query.mailboxIDs.isEmpty || query.picksMessages
        // A few mailboxes (an inbox) hold fewer messages than a busy sender or subject has across the account: walk
        // the mailbox's own index and test each row, rather than gather that sender's every message and sort them.
        // `+` keeps SQLite (and the statistics Mail keeps for it) off the sender and subject indexes then.
        let walk = (Self.scopeSize(of: query, mailboxes: mailboxes) ?? .max) <= Self.walkScopeLimit ? "+" : ""
        // A date range is what (deleted, date_received) is for: keep it available to the count then.
        let countHint = query.dateFrom == nil && query.dateTo == nil
        var clauses: [String] = []
        var bindings: [SQLValue] = []
        // The two clauses that differ between page and count; the rest are shared.
        let deletedClause = (page: scoped ? "+m.deleted = 0" : "m.deleted = 0", count: scoped || countHint ? "+m.deleted = 0" : "m.deleted = 0")
        var mailboxClause: (page: String, count: String)?

        if !query.ids.isEmpty {
            clauses.append("m.ROWID IN (SELECT value FROM json_each(?))")
            bindings.append(Self.idArray(query.ids))
        }
        if !query.mailboxIDs.isEmpty {
            let selected = query.mailboxIDs.compactMap { mailboxes[$0] }
            let plain = selected.filter { $0.sourceMailboxID == nil }.map(\.id)
            let labels = selected.filter { $0.sourceMailboxID != nil }.map(\.id)
            var parts: [String] = []
            if !plain.isEmpty {
                parts.append("m.mailbox IN (\(plain.map(String.init).joined(separator: ",")))")
            }
            if !labels.isEmpty {
                parts.append(
                    "m.ROWID IN (SELECT message_id FROM labels WHERE mailbox_id IN (\(labels.map(String.init).joined(separator: ","))))")
            }
            clauses.append(parts.isEmpty ? "0" : "(" + parts.joined(separator: " OR ") + ")")
        } else {
            var allowed = mailboxes.values.filter { $0.sourceMailboxID == nil }
            if !query.accountIDs.isEmpty { allowed = allowed.filter { query.accountIDs.contains($0.accountID) } }
            if !query.includeTrashAndJunk { allowed = allowed.filter { $0.role != .trash && $0.role != .junk } }
            if !query.accountIDs.isEmpty || !query.includeTrashAndJunk {
                let list = allowed.map { String($0.id) }.joined(separator: ",")
                mailboxClause = ("m.mailbox IN (\(list))", "\(countHint ? "+" : "")m.mailbox IN (\(list))")
                if allowed.isEmpty { clauses.append("0") }
            }
        }
        // Text filters match the small lookup tables first, then use the messages indexes (subject, sender,
        // recipients_address) instead of joining every message. The tables are searched in memory when possible
        // (loaded on first use), and the matching ROWIDs go in as a list; else SQLite's LIKE does it.
        var loadedLookups: (subjects: TextLookupTable, addresses: TextLookupTable, generation: Int)??
        func lookups() -> (subjects: TextLookupTable, addresses: TextLookupTable, generation: Int)? {
            if loadedLookups == nil { loadedLookups = .some(currentTextLookups()) }
            return loadedLookups!
        }
        /// `SELECT …` of the subject or address ROWIDs matching any of `terms`, and its bindings.
        func matching(_ table: LookupTableName, _ terms: [String]) -> (sql: String, bindings: [SQLValue]) {
            if let loaded = lookups(),
                let ids = textLookups.matches("\(table)\u{0}" + terms.joined(separator: "\u{0}"), generation: loaded.generation, compute: {
                    let rows = table == .subjects ? loaded.subjects : loaded.addresses
                    return Self.union(terms.map { rows.ids(containing: $0) })
                })
            {
                return ("SELECT value FROM json_each(?)", [Self.idArray(ids)])
            }
            let patterns = terms.map { SQLValue.text(SQLiteConnection.likePattern(containing: $0)) }
            switch table {
            case .subjects:
                return ("SELECT ROWID FROM subjects WHERE \(Self.repeated("subject LIKE ? ESCAPE '\\'", terms.count))", patterns)
            case .addresses:
                return (
                    "SELECT ROWID FROM addresses WHERE \(Self.repeated("address LIKE ? ESCAPE '\\' OR comment LIKE ? ESCAPE '\\'", terms.count))",
                    patterns.flatMap { [$0, $0] })
            }
        }
        let textTerms = MessageQuery.cleaned(([query.text].compactMap { $0 }) + query.textTerms)
        if !textTerms.isEmpty {
            // Any term in the subject, the sender or Mail's preview snippet.
            let subjects = matching(.subjects, textTerms)
            let senders = matching(.addresses, textTerms)
            clauses.append(
                """
                (m.subject IN (\(subjects.sql)) OR m.sender IN (\(senders.sql)) \
                OR m.summary IN (SELECT ROWID FROM summaries WHERE \(Self.repeated("summary LIKE ? ESCAPE '\\'", textTerms.count))))
                """)
            bindings += subjects.bindings + senders.bindings + textTerms.map { .text(SQLiteConnection.likePattern(containing: $0)) }
        }
        let excludedSubjects = MessageQuery.cleaned(query.excludeSubjectTerms)
        if !excludedSubjects.isEmpty {
            let subjects = matching(.subjects, excludedSubjects)
            clauses.append("m.subject NOT IN (\(subjects.sql))")
            bindings += subjects.bindings
        }
        let excludedSenders = MessageQuery.cleaned(query.excludeSenders)
        if !excludedSenders.isEmpty {
            // IFNULL: a message without a sender row is not excluded (NOT IN NULL would drop it).
            let senders = matching(.addresses, excludedSenders)
            clauses.append("IFNULL(m.sender, 0) NOT IN (\(senders.sql))")
            bindings += senders.bindings
        }
        var excludedAddresses = Set(MessageQuery.cleaned(query.excludeSenderAddresses).map { $0.lowercased() })
        switch query.direction {
        case .any: break
        case .received:
            if let membership = Self.membership(roles: [.sent, .drafts, .outbox], mailboxes: mailboxes) {
                clauses.append("NOT \(membership)")
            }
            excludedAddresses.formUnion(cachedOwnAddresses())
        case .sent:
            let own = cachedOwnAddresses()
            var sent: [String] = []
            if let membership = Self.membership(roles: [.sent], mailboxes: mailboxes) { sent.append(membership) }
            if !own.isEmpty {
                sent.append("IFNULL(m.sender, 0) IN (SELECT ROWID FROM addresses WHERE lower(address) IN (SELECT value FROM json_each(?)))")
                bindings.append(.text(Self.jsonArray(own.sorted())))
            }
            clauses.append(sent.isEmpty ? "0" : "(" + sent.joined(separator: " OR ") + ")")
            if let unsent = Self.membership(roles: [.drafts, .outbox], mailboxes: mailboxes) { clauses.append("NOT \(unsent)") }
        }
        if !excludedAddresses.isEmpty {
            clauses.append(
                "IFNULL(m.sender, 0) NOT IN (SELECT ROWID FROM addresses WHERE lower(address) IN (SELECT value FROM json_each(?)))")
            bindings.append(.text(Self.jsonArray(excludedAddresses.sorted())))
        }
        if query.excludeReplies {
            // Mail moves "Re: " into subject_prefix; older rows may keep it in the subject itself.
            let prefixes = Self.replyPrefixes
            let prefixGlobs = prefixes.map { "lower(ltrim(IFNULL(m.subject_prefix, ''))) GLOB '\($0):*'" }.joined(separator: " OR ")
            if let table = lookups(),
                let ids = textLookups.matches("replies", generation: table.generation, compute: {
                    Self.union(prefixes.map { table.subjects.ids(startingWith: "\($0):") })
                })
            {
                clauses.append("NOT (\(prefixGlobs)) AND m.subject NOT IN (SELECT value FROM json_each(?))")
                bindings.append(Self.idArray(ids))
            } else {
                let subjectLikes = prefixes.map { "subject LIKE '\($0):%'" }.joined(separator: " OR ")
                clauses.append("NOT (\(prefixGlobs)) AND m.subject NOT IN (SELECT ROWID FROM subjects WHERE \(subjectLikes))")
            }
        }
        let subjectTerms = MessageQuery.cleaned(query.subjectTerms)
        if !subjectTerms.isEmpty {
            let subjects = matching(.subjects, subjectTerms)
            clauses.append("\(walk)m.subject IN (\(subjects.sql))")
            bindings += subjects.bindings
        }
        if !MessageQuery.blank(query.sender) {
            let senders = matching(.addresses, MessageQuery.cleaned([query.sender ?? ""]))
            clauses.append("\(walk)m.sender IN (\(senders.sql))")
            bindings += senders.bindings
        }
        if !MessageQuery.blank(query.recipient) {
            let addresses = matching(.addresses, MessageQuery.cleaned([query.recipient ?? ""]))
            clauses.append("m.ROWID IN (SELECT message FROM recipients WHERE address IN (\(addresses.sql)))")
            bindings += addresses.bindings
        }
        if let from = query.dateFrom {
            clauses.append("m.date_received >= ?")
            bindings.append(.int(Int64(from.timeIntervalSince1970)))
        }
        if let to = query.dateTo {
            clauses.append("m.date_received <= ?")
            bindings.append(.int(Int64(to.timeIntervalSince1970)))
        }
        if let isRead = query.isRead { clauses.append(isRead ? "m.read != 0" : "m.read = 0") }
        if let color = query.flagColor {
            // Mail keeps the flag colour in bits 39-41 of `flags` (red = 0 … gray = 6);
            // the `flag_color` column does not track it.
            clauses.append("m.ROWID IN (SELECT ROWID FROM messages WHERE flagged = 1) AND ((m.flags >> 39) & 7) = ?")
            bindings.append(.int(Int64(color.rawValue)))
        } else if let isFlagged = query.isFlagged {
            // The flagged set is small: go through messages_flagged_index rather than the date index.
            clauses.append(isFlagged ? "m.ROWID IN (SELECT ROWID FROM messages WHERE flagged = 1)" : "m.flagged = 0")
        }
        if let hasAttachments = query.hasAttachments {
            clauses.append((hasAttachments ? "" : "NOT ") + "EXISTS (SELECT 1 FROM attachments t WHERE t.message = m.ROWID)")
        }
        if !query.categories.isEmpty, hasCategories {
            let values = query.categories.map { String($0.rawValue) }.joined(separator: ",")
            // Unclassified messages count as Primary, as in Mail's own Primary view.
            clauses.append("IFNULL(g.model_category, 0) IN (\(values))")
        }
        if let conversation = query.conversationID {
            clauses.append("m.conversation_id = ?")
            bindings.append(.int(conversation))
        }
        // The page's and the count's own clauses go first, where they always were.
        func joined(_ deleted: String, _ mailbox: String?) -> String {
            ([deleted] + (mailbox.map { [$0] } ?? []) + clauses).joined(separator: " AND ")
        }
        return WhereClause(
            sql: joined(deletedClause.page, mailboxClause?.page), countSQL: joined(deletedClause.count, mailboxClause?.count),
            bindings: bindings)
    }

    /// Mail's lookup tables that text filters match first.
    enum LookupTableName: CustomStringConvertible {
        case subjects, addresses
        var description: String { self == .subjects ? "s" : "a" }
    }

    /// The in-memory subjects and addresses, caught up with Mail; nil when they cannot be read (SQL then).
    /// Outside `withDB`, like `whereClause`.
    func currentTextLookups() -> (subjects: TextLookupTable, addresses: TextLookupTable, generation: Int)? {
        try? textLookups.current(
            dataVersion: seenDataVersion(),
            rows: { sql, columns, add in
                try withDB { db in try db.query(sql) { row in add(row.int(0), (1...columns).map { row.string($0) }) } }
            },
            counts: {
                try withDB { db in
                    (Int(try db.scalarInt("SELECT COUNT(*) FROM subjects") ?? 0), Int(try db.scalarInt("SELECT COUNT(*) FROM addresses") ?? 0))
                }
            })
    }

    /// Union of per-term matches; nil when any term could not be matched in memory.
    static func union(_ matches: [[Int64]?]) -> [Int64]? {
        var all = Set<Int64>()
        for match in matches {
            guard let match else { return nil }
            all.formUnion(match)
        }
        return all.sorted()
    }

    static func idArray(_ ids: [Int64]) -> SQLValue { .text("[" + ids.map(String.init).joined(separator: ",") + "]") }

    /// Reply prefixes in the languages Mail users commonly see (constants, safe to inline in SQL).
    static let replyPrefixes = ["re", "aw", "sv", "vs", "antw", "rif", "r", "res", "odp", "atb"]

    static func repeated(_ condition: String, _ count: Int) -> String {
        Array(repeating: "(\(condition))", count: count).joined(separator: " OR ")
    }

    /// Messages in any mailbox with one of `roles`, directly or through a label; nil when there is none.
    static func membership(roles: Set<MailboxRole>, mailboxes: [Int64: Mailbox]) -> String? {
        let matching = mailboxes.values.filter { roles.contains($0.role) }
        let plain = matching.filter { $0.sourceMailboxID == nil }.map { String($0.id) }.sorted()
        let labels = matching.filter { $0.sourceMailboxID != nil }.map { String($0.id) }.sorted()
        var parts: [String] = []
        if !plain.isEmpty { parts.append("m.mailbox IN (\(plain.joined(separator: ",")))") }
        if !labels.isEmpty {
            parts.append("m.ROWID IN (SELECT message_id FROM labels WHERE mailbox_id IN (\(labels.joined(separator: ","))))")
        }
        return parts.isEmpty ? nil : "(" + parts.joined(separator: " OR ") + ")"
    }

    /// The user's addresses as last loaded (callers refresh the caches first, e.g. via `lookupTables`).
    func cachedOwnAddresses() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(cachedAccounts.flatMap(\.emailAddresses).map { $0.lowercased() })
    }

    /// The joins a WHERE clause needs, so COUNT and id-only queries skip the rest.
    static func minimalJoins(for whereSQL: String) -> String {
        var joins = "FROM messages m"
        if whereSQL.contains("s.subject") { joins += " JOIN subjects s ON s.ROWID = m.subject" }
        if whereSQL.contains("a.address") || whereSQL.contains("a.comment") {
            joins += " LEFT JOIN addresses a ON a.ROWID = m.sender"
        }
        if whereSQL.contains("su.summary") { joins += " LEFT JOIN summaries su ON su.ROWID = m.summary" }
        if whereSQL.contains("g.") { joins += " LEFT JOIN message_global_data g ON g.ROWID = m.global_message_id" }
        return joins
    }

    /// Searches envelopes in SQLite; body text goes through `bodyIndex` when
    /// given, with a bounded, parallel `.emlx` scan for anything the index has not covered yet.
    /// `needsTotal` false (a thread): no count of the matches beyond the page, and `total` is then nil.
    public func search(_ query: MessageQuery, bodyIndex: (any BodySearchIndex)? = nil, needsTotal: Bool = true) throws -> SearchPage {
        let (mailboxes, names) = try lookupTables()
        let clause = whereClauses(for: query, mailboxes: mailboxes)
        let (whereSQL, bindings) = (clause.sql, clause.bindings)
        let scopeSize = Self.scopeSize(of: query, mailboxes: mailboxes)
        let direction = query.sortAscending ? "ASC" : "DESC"
        let order = "ORDER BY m.date_received \(direction), m.ROWID \(direction)"
        let limit = max(1, min(query.limit, 500))
        let offset = max(0, query.offset)

        guard let bodyText = query.bodyText?.trimmingCharacters(in: .whitespaces), !bodyText.isEmpty else {
            // A filter in a few mailboxes (a sender in the inbox): counting reads every row of those mailboxes anyway,
            // so one walk returns all the matches, the page is a slice of them and the total is their number. A
            // separate page query and count would read the same rows twice, on two connections, and Mail's writes
            // make each re-read its pages.
            if needsTotal, (scopeSize ?? .max) <= Self.walkScopeLimit, indexOnlyCountStatement(query, mailboxes: mailboxes) == nil {
                let allIDs = try walkMatches(query, mailboxes: mailboxes, whereSQL: whereSQL, bindings: bindings, order: order)
                let pageIDs = Array(allIDs.dropFirst(offset).prefix(limit))
                return SearchPage(
                    messages: try messages(ids: pageIDs, mailboxes: mailboxes, accountNames: names), total: allIDs.count,
                    offset: offset, limit: limit, hasMore: offset + pageIDs.count < allIDs.count, bodySearchMode: nil,
                    scanLimited: false, scannedMessages: 0)
            }
            // The total, on the second connection meanwhile; a short page gives it anyway (then unused).
            let pendingTotal = needsTotal ? countInBackground(countStatement(query, mailboxes: mailboxes, clause: clause)) : nil
            // Page ids first, then envelopes for just those: when the scope spans several mailboxes
            // SQLite sorts every matching row, and sorting bare ids is far cheaper than full envelopes.
            let pageIDs = try withDB { db in
                try db.all(
                    "SELECT m.ROWID \(Self.minimalJoins(for: whereSQL)) WHERE \(whereSQL) \(order) LIMIT ? OFFSET ?",
                    bindings + [.int(Int64(limit)), .int(Int64(offset))]
                ) { $0.int(0) }
            }
            let rows = try messages(ids: pageIDs, mailboxes: mailboxes, accountNames: names)
            // A short page that started inside the results already gives the total.
            let short = !pageIDs.isEmpty && pageIDs.count < limit || offset == 0 && pageIDs.isEmpty
            let total = short ? Int64(offset + pageIDs.count) : try pendingTotal?.wait()
            return SearchPage(
                messages: rows, total: total.map(Int.init), offset: offset, limit: limit,
                hasMore: total.map { offset + pageIDs.count < Int($0) } ?? (pageIDs.count == limit), bodySearchMode: nil,
                scanLimited: false, scannedMessages: 0)
        }

        if let bodyIndex,
            let page = try indexedBodyPage(
                bodyText, whereSQL: whereSQL, bindings: bindings, order: order, limit: limit, offset: offset,
                mailboxes: mailboxes, accountNames: names, bodyIndex: bodyIndex, scopeSize: scopeSize)
        {
            return page
        }
        // Body search: indexed matches, plus a scan of whatever the index has not covered yet.
        // Without an index, stop once the page is full: the total is then unknown.
        let found = try bodyMatches(
            bodyText, query: query, whereSQL: whereSQL, bindings: bindings, order: order, mailboxes: mailboxes,
            bodyIndex: bodyIndex, stopAfter: bodyIndex == nil ? offset + limit + 1 : nil)
        let matchedIDs = found.ids
        let pageIDs = Array(matchedIDs.dropFirst(offset).prefix(limit))
        return SearchPage(
            messages: try messages(ids: pageIDs, mailboxes: mailboxes, accountNames: names),
            total: found.complete ? matchedIDs.count : nil, offset: offset, limit: limit,
            hasMore: matchedIDs.count > offset + pageIDs.count || !found.complete, bodySearchMode: found.mode,
            scanLimited: found.scanLimited, scannedMessages: found.scanned)
    }

    /// A body search the index fully covers (no message in scope arrived after it was last updated): the page and
    /// its total straight from SQL, instead of loading and sorting every match. nil when part of the scope is
    /// not indexed yet; `bodyMatches` then scans that part.
    private func indexedBodyPage(
        _ bodyText: String, whereSQL: String, bindings: [SQLValue], order: String, limit: Int, offset: Int,
        mailboxes: [Int64: Mailbox], accountNames names: [String: String], bodyIndex: any BodySearchIndex, scopeSize: Int?
    ) throws -> SearchPage? {
        let covered = try bodyIndex.coveredThrough()
        let joins = Self.minimalJoins(for: whereSQL)
        let unindexed = try withDB { db in
            try db.scalarInt("SELECT EXISTS(SELECT 1 \(joins) WHERE \(whereSQL) AND m.ROWID > ?)", bindings + [.int(covered)])
        }
        guard unindexed == 0 else { return nil }
        let matches = try bodyIndex.matchingIDs(for: bodyText, limit: 200_000)
        // Few messages in scope (one mailbox) against many matches: walk the scope and check each against the
        // matches (`+` keeps SQLite from looking up every match by ROWID instead).
        let walkScope = scopeSize.map { $0 < matches.count } ?? false
        let scoped = whereSQL + " AND \(walkScope ? "+" : "")m.ROWID IN (SELECT value FROM json_each(?))"
        let scopedBindings = bindings + [Self.idArray(matches)]
        let pageIDs = matches.isEmpty ? [] : try withDB { db in
            try db.all(
                "SELECT m.ROWID \(joins) WHERE \(scoped) \(order) LIMIT ? OFFSET ?",
                scopedBindings + [.int(Int64(limit)), .int(Int64(offset))]) { $0.int(0) }
        }
        let total = matches.isEmpty || !pageIDs.isEmpty && pageIDs.count < limit || offset == 0 && pageIDs.isEmpty
            ? offset + pageIDs.count
            : Int(try withDB { db in try db.scalarInt("SELECT COUNT(*) \(joins) WHERE \(scoped)", scopedBindings) ?? 0 })
        return SearchPage(
            messages: try messages(ids: pageIDs, mailboxes: mailboxes, accountNames: names), total: total, offset: offset,
            limit: limit, hasMore: offset + pageIDs.count < total, bodySearchMode: "index", scanLimited: false, scannedMessages: 0)
    }

    /// Every match of a filtered search in a few mailboxes, in order. The list is kept while those mailboxes hold
    /// the same messages: a filter on what Mail never changes in place (which mailbox, sender, subject, recipients,
    /// date; a moved message gets a new ROWID) gives the same matches then, whatever else Mail wrote (read and flag
    /// state, mostly). The mailboxes' fingerprint, count and sum of ROWIDs of their rows and of their deleted rows,
    /// comes from indexes alone. Filters on state that does change in place, and labels, always walk.
    private func walkMatches(
        _ query: MessageQuery, mailboxes: [Int64: Mailbox], whereSQL: String, bindings: [SQLValue], order: String
    ) throws -> [Int64] {
        let walk = "SELECT m.ROWID \(Self.minimalJoins(for: whereSQL)) WHERE \(whereSQL) \(order)"
        let selected = query.mailboxIDs.compactMap { mailboxes[$0] }
        let keepable = !query.filtersOnChangingState && !query.picksMessages
            && !selected.isEmpty && selected.allSatisfy { $0.sourceMailboxID == nil }
        guard keepable else { return try withDB { db in try db.all(walk, bindings) { $0.int(0) } } }
        let list = selected.map { String($0.id) }.joined(separator: ",")
        let key = StatementKey(sql: walk, bindings: bindings)
        return try withDB { db in
            let fingerprint = try db.all(
                """
                SELECT (SELECT COUNT(*) || ':' || TOTAL(ROWID) FROM messages WHERE mailbox IN (\(list))) || '/'
                || (SELECT COUNT(*) || ':' || TOTAL(ROWID) FROM messages WHERE (deleted > 0 OR deleted < 0) AND +mailbox IN (\(list)))
                """) { $0.string(0) }.first ?? ""
            if let kept = keptMatches[key], kept.fingerprint == fingerprint { return kept.ids }
            let ids = try db.all(walk, bindings) { $0.int(0) }
            if keptMatches.count >= 32 { keptMatches.removeAll() }
            keptMatches[key] = (fingerprint, ids)
            return ids
        }
    }

    /// The statement counting the matches of `query`, whose clauses are `clause`.
    private func countStatement(_ query: MessageQuery, mailboxes: [Int64: Mailbox], clause: WhereClause) -> (String, [SQLValue]) {
        if let fast = indexOnlyCountStatement(query, mailboxes: mailboxes) { return fast }
        return ("SELECT COUNT(*) \(Self.minimalJoins(for: clause.countSQL)) WHERE \(clause.countSQL)", clause.bindings)
    }

    /// Runs `sql` on a second read-only connection, so a count can go on while the page is read on the first.
    /// Mail's index is in WAL mode: the two readers do not block each other.
    /// Totals are also kept until Mail next writes to its index (`PRAGMA data_version`): the next page of the
    /// same search, or the same question again, needs no count.
    private func countInBackground(_ statement: (sql: String, bindings: [SQLValue])) -> PendingCount {
        let (sql, bindings) = statement
        let pending = PendingCount()
        let version = seenDataVersion()
        let key = StatementKey(sql: sql, bindings: bindings)
        if version >= 0, let known = countLock.withLock({ countCacheVersion == version ? countCache[key] : nil }) {
            pending.finish(.success(known))
            return pending
        }
        DispatchQueue.global(qos: .userInitiated).async {
            pending.finish(Result {
                try self.countLock.withLock {
                    if self.countDB == nil {
                        self.countDB = try SQLiteConnection(path: self.location.envelopeIndex.path, readOnly: true)
                    }
                    let total = try self.countDB!.scalarInt(sql, bindings) ?? 0
                    if version >= 0 {
                        if self.countCacheVersion != version || self.countCache.count >= 64 { self.countCache.removeAll() }
                        self.countCacheVersion = version
                        self.countCache[key] = total
                    }
                    return total
                }
            })
        }
        return pending
    }

    /// The count of a query that only picks whole mailboxes and a date range (a mailbox listing, an overview),
    /// from the indexes alone; nil for any other query. `deleted = 0` is not in the (mailbox, date_received)
    /// index, so filtering on it reads every row; instead count the index, then take off the few rows Mail has
    /// marked deleted, found through (deleted, date_received). Same number, no table reads.
    /// (Tests check it against the full query; searches use `indexOnlyCountStatement`.)
    func indexOnlyCount(_ query: MessageQuery, mailboxes: [Int64: Mailbox]) throws -> Int64? {
        guard let (sql, bindings) = indexOnlyCountStatement(query, mailboxes: mailboxes) else { return nil }
        return try withDB { try $0.scalarInt(sql, bindings) ?? 0 }
    }

    /// The statement behind `indexOnlyCount`; nil when the query is not one it can count.
    func indexOnlyCountStatement(_ query: MessageQuery, mailboxes: [Int64: Mailbox]) -> (String, [SQLValue])? {
        guard !query.filtersOnChangingState, !query.filtersOnFixedContent, !query.picksMessages else { return nil }

        var mailboxIDs: [Int64]?  // nil: every mailbox
        if !query.mailboxIDs.isEmpty {
            let selected = query.mailboxIDs.compactMap { mailboxes[$0] }
            if selected.contains(where: { $0.sourceMailboxID != nil }) { return nil }  // labels: rows in `labels`
            mailboxIDs = selected.map(\.id)
        } else if !query.accountIDs.isEmpty || !query.includeTrashAndJunk {
            var allowed = mailboxes.values.filter { $0.sourceMailboxID == nil }
            if !query.accountIDs.isEmpty { allowed = allowed.filter { query.accountIDs.contains($0.accountID) } }
            if !query.includeTrashAndJunk { allowed = allowed.filter { $0.role != .trash && $0.role != .junk } }
            mailboxIDs = allowed.map(\.id)
        }
        if mailboxIDs?.isEmpty == true { return ("SELECT 0", []) }

        var dates = ""
        var dateBindings: [SQLValue] = []
        if let from = query.dateFrom {
            dates += " AND date_received >= ?"
            dateBindings.append(.int(Int64(from.timeIntervalSince1970)))
        }
        if let to = query.dateTo {
            dates += " AND date_received <= ?"
            dateBindings.append(.int(Int64(to.timeIntervalSince1970)))
        }
        guard let mailboxIDs else { return ("SELECT COUNT(*) FROM messages WHERE deleted = 0\(dates)", dateBindings) }
        let list = mailboxIDs.map(String.init).joined(separator: ",")
        return (
            """
            SELECT (SELECT COUNT(*) FROM messages WHERE mailbox IN (\(list))\(dates))
            - (SELECT COUNT(*) FROM messages WHERE (deleted > 0 OR deleted < 0) AND +mailbox IN (\(list))\(dates))
            """, dateBindings + dateBindings)
    }

    /// Every message matching `query`, in its sort order, up to `cap` (exports, grouping). Body text is
    /// matched like `search` does; without a complete index the scan stops at `query.bodyScanBudget`.
    public func allMatchingIDs(_ query: MessageQuery, bodyIndex: (any BodySearchIndex)? = nil, cap: Int = 200_000) throws -> MatchResult {
        let (mailboxes, _) = try lookupTables()
        let (whereSQL, bindings) = whereClause(for: query, mailboxes: mailboxes)
        let direction = query.sortAscending ? "ASC" : "DESC"
        let order = "ORDER BY m.date_received \(direction), m.ROWID \(direction)"
        guard let bodyText = query.bodyText?.trimmingCharacters(in: .whitespaces), !bodyText.isEmpty else {
            let ids = try withDB { db in
                try db.all(
                    "SELECT m.ROWID \(Self.minimalJoins(for: whereSQL)) WHERE \(whereSQL) \(order) LIMIT ?",
                    bindings + [.int(Int64(cap) + 1)]) { $0.int(0) }
            }
            return MatchResult(ids: Array(ids.prefix(cap)), complete: ids.count <= cap, bodySearchMode: nil, scannedMessages: 0)
        }
        let found = try bodyMatches(
            bodyText, query: query, whereSQL: whereSQL, bindings: bindings, order: order, mailboxes: mailboxes,
            bodyIndex: bodyIndex, stopAfter: cap + 1)
        return MatchResult(
            ids: Array(found.ids.prefix(cap)), complete: found.complete && found.ids.count <= cap,
            bodySearchMode: found.mode, scannedMessages: found.scanned)
    }

    private struct BodyMatches {
        var ids: [Int64]
        var scanned: Int
        var scanLimited: Bool
        var complete: Bool
        var mode: String
    }

    /// Candidates from SQL, kept when the body index lists them or a parallel `.emlx` scan finds the text.
    /// Stops early once `stopAfter` matches are known (the result is then incomplete).
    private func bodyMatches(
        _ bodyText: String, query: MessageQuery, whereSQL baseWhere: String, bindings baseBindings: [SQLValue], order: String,
        mailboxes: [Int64: Mailbox], bodyIndex: (any BodySearchIndex)?, stopAfter: Int?
    ) throws -> BodyMatches {
        var whereSQL = baseWhere
        var bindings = baseBindings
        var mode = "scan"
        var covered: Int64 = 0
        if let bodyIndex {
            covered = try bodyIndex.coveredThrough()
            let matches = try bodyIndex.matchingIDs(for: bodyText, limit: 200_000)
            mode = "index"
            // One list (the matches, then everything newer than the index) rather than `IN … OR ROWID > ?`,
            // which no index serves: SQLite looks up just those rows instead of walking the whole scope.
            whereSQL += " AND m.ROWID IN (SELECT value FROM json_each(?) UNION ALL SELECT ROWID FROM messages WHERE ROWID > ?)"
            bindings.append(Self.idArray(matches))
            bindings.append(.int(covered))
        }
        let candidates = try withDB { db in
            try db.all(
                "SELECT m.ROWID, m.mailbox \(Self.minimalJoins(for: whereSQL)) WHERE \(whereSQL) \(order)", bindings
            ) { ($0.int(0), $0.int(1)) }
        }

        let pattern = TextFold.Pattern(bodyText)
        var matchedIDs: [Int64] = []
        var scanned = 0
        var scanLimited = false
        var cursor = 0
        let chunkSize = 64
        while cursor < candidates.count {
            // Indexed candidates are already matches; collect a run of them cheaply.
            let (id, _) = candidates[cursor]
            if bodyIndex != nil && id <= covered {
                matchedIDs.append(id)
                cursor += 1
                if let stopAfter, matchedIDs.count >= stopAfter { break }
                continue
            }
            // Gather a chunk of unindexed candidates and scan them in parallel.
            var chunk: [(Int64, Int64)] = []
            var next = cursor
            while next < candidates.count, chunk.count < chunkSize {
                let candidate = candidates[next]
                if bodyIndex != nil && candidate.0 <= covered { break }
                chunk.append(candidate)
                next += 1
            }
            if scanned + chunk.count > query.bodyScanBudget {
                chunk = Array(chunk.prefix(max(0, query.bodyScanBudget - scanned)))
                scanLimited = true
            }
            if !chunk.isEmpty {
                let hits = scanChunk(chunk, pattern: pattern, mailboxes: mailboxes)
                for (index, hit) in hits.enumerated() where hit { matchedIDs.append(chunk[index].0) }
                scanned += chunk.count
                if bodyIndex != nil { mode = "index+scan" }
            }
            if scanLimited { break }
            cursor = next
            if let stopAfter, matchedIDs.count >= stopAfter { break }
        }
        return BodyMatches(
            ids: matchedIDs, scanned: scanned, scanLimited: scanLimited,
            complete: cursor >= candidates.count && !scanLimited, mode: mode)
    }

    /// Attachment names per message, from Mail's index (no message files read).
    public func attachmentNames(ids: [Int64]) throws -> [Int64: [String]] {
        guard !ids.isEmpty else { return [:] }
        let json = MailStore.idArray(ids)
        var names: [Int64: [String]] = [:]
        try withDB { db in
            try db.query(
                "SELECT message, name FROM attachments WHERE message IN (SELECT value FROM json_each(?)) ORDER BY message, ROWID",
                [json]
            ) { row in
                let name = row.string(1)
                if !name.isEmpty { names[row.int(0), default: []].append(name) }
            }
        }
        return names
    }

    /// Counts of matching messages per sender, sender domain or month, largest first (months newest first).
    public func groupCounts(
        _ query: MessageQuery, by key: GroupKey, bodyIndex: (any BodySearchIndex)? = nil, limit: Int = 50
    ) throws -> [GroupCount] {
        var scoped = query
        if let bodyText = query.bodyText, !bodyText.trimmingCharacters(in: .whitespaces).isEmpty {
            // Body matches come from the index or a scan, not SQL: group the matched ids instead.
            scoped = MessageQuery()
            scoped.ids = try allMatchingIDs(query, bodyIndex: bodyIndex).ids
            scoped.includeTrashAndJunk = true
            if scoped.ids.isEmpty { return [] }
        }
        let (mailboxes, _) = try lookupTables()
        let (whereSQL, bindings) = whereClause(for: scoped, mailboxes: mailboxes)
        let expression: String
        let ordering: String
        switch key {
        case .sender:
            expression = "lower(IFNULL(a.address, ''))"
            ordering = "n DESC, k"
        case .domain:
            expression = "lower(substr(IFNULL(a.address, ''), instr(IFNULL(a.address, ''), '@') + 1))"
            ordering = "n DESC, k"
        case .month:
            expression = "strftime('%Y-%m', m.date_received, 'unixepoch', 'localtime')"
            ordering = "k DESC"
        }
        return try withDB { db in
            try db.all(
                """
                SELECT \(expression) AS k, MAX(a.comment), COUNT(*) AS n, SUM(m.read = 0)
                \(Self.summaryJoins) WHERE \(whereSQL) GROUP BY k ORDER BY \(ordering) LIMIT ?
                """, bindings + [.int(Int64(max(1, min(limit, 1000))))]
            ) { row in
                let name = row.optionalString(1)
                return GroupCount(
                    key: row.string(0), name: key == .sender && !(name?.isEmpty ?? true) ? name : nil,
                    count: Int(row.int(2)), unread: Int(row.int(3)))
            }
        }
    }

    /// Checks a batch of messages for `pattern` across all cores.
    private func scanChunk(_ chunk: [(Int64, Int64)], pattern: TextFold.Pattern, mailboxes: [Int64: Mailbox]) -> [Bool] {
        let results = BoolSlots(count: chunk.count)
        DispatchQueue.concurrentPerform(iterations: chunk.count) { index in
            let (id, mailboxID) = chunk[index]
            guard let mailbox = mailboxes[mailboxID], let url = MailboxURL(mailbox.url),
                  let file = files.emlxURL(rowID: id, mailbox: url),
                  let folded = scannedText.value(path: file.path, load: {
                      (try? EmlxFile(url: file)).map { TextFold.fold(MessageContent.searchableText(MIME.parse($0.message), maxCharacters: .max)) }
                  })
            else { return }
            results.set(index, pattern.matches(folded: folded))
        }
        return results.values
    }

    // MARK: Content

    /// Locates the `.emlx` for a message (in its own mailbox).
    public func emlxURL(for summary: MessageSummary) throws -> URL? {
        try messageFile(for: summary)?.file
    }

    /// The message's mailbox and `.emlx`, if downloaded. The mailbox comes from the table already loaded when it is
    /// there, so a thread read in parallel does not queue on the lock.
    private func messageFile(for summary: MessageSummary) throws -> (mailbox: MailboxURL, file: URL)? {
        guard let mailbox = try lock.withLock({ cachedMailboxes[summary.mailboxID] }) ?? mailbox(id: summary.mailboxID),
            let url = MailboxURL(mailbox.url), let file = files.emlxURL(rowID: summary.id, mailbox: url)
        else { return nil }
        return (url, file)
    }

    /// Raw RFC 822 source of a message.
    public func rawSource(id: Int64) throws -> Data {
        let summary = try message(id: id)
        guard let url = try emlxURL(for: summary) else { throw MailStoreError.bodyNotDownloaded(id) }
        return try EmlxFile(url: url).message
    }

    /// Envelope plus parsed body, recipients and attachment list.
    public func detail(id: Int64) throws -> MessageDetail {
        try detail(of: message(id: id))
    }

    /// `detail` for an envelope already in hand (a thread's messages, with their recipients fetched together).
    public func detail(
        of summary: MessageSummary, recipients known: (to: [EmailAddress], cc: [EmailAddress])? = nil
    ) throws -> MessageDetail {
        let id = summary.id
        let (to, cc) = try known ?? recipients(of: id)
        guard let (mailboxURL, url) = try messageFile(for: summary) else {
            return MessageDetail(
                summary: summary, to: to, cc: cc, replyTo: [], headers: [], textBody: nil, htmlBody: nil,
                attachments: try attachmentNamesFromIndex(id), bodyAvailable: false)
        }
        let content = try parsedMessages.value(path: url.path) { try ParsedMessage(emlx: EmlxFile(url: url)) }
        // Whether an attachment is on disk can change (Mail downloads it later): checked each time.
        let attachments = content.attachments.map { part in
            AttachmentInfo(
                partID: part.partID, filename: part.filename, mimeType: part.mimeType, size: part.size,
                isDownloaded: part.inline || files.attachmentFile(rowID: id, mailbox: mailboxURL, partID: part.partID) != nil)
        }
        return MessageDetail(
            summary: summary,
            to: content.to.isEmpty ? to : content.to,
            cc: content.cc.isEmpty ? cc : content.cc,
            replyTo: content.replyTo, headers: content.headers,
            textBody: content.text, htmlBody: content.html, attachments: attachments, bodyAvailable: true,
            textBodyWithoutQuotes: content.textWithoutQuotes)
    }

    private func attachmentNamesFromIndex(_ id: Int64) throws -> [AttachmentInfo] {
        try withDB { db in
            try db.all("SELECT attachment_id, name FROM attachments WHERE message = ? ORDER BY ROWID", [.int(id)]) {
                AttachmentInfo(
                    partID: $0.string(0), filename: $0.string(1), mimeType: "application/octet-stream", size: nil,
                    isDownloaded: false)
            }
        }
    }

    /// To and Cc recipients from the index (type 0 = To, 1 = Cc, 2 = Bcc).
    public func recipients(of id: Int64) throws -> (to: [EmailAddress], cc: [EmailAddress]) {
        try recipients(of: [id])[id] ?? ([], [])
    }

    /// `recipients(of:)` for several messages in one query (a thread, before its bodies are read in parallel).
    public func recipients(of ids: [Int64]) throws -> [Int64: (to: [EmailAddress], cc: [EmailAddress])] {
        var found: [Int64: (to: [EmailAddress], cc: [EmailAddress])] = [:]
        for id in ids { found[id] = ([], []) }
        try withDB { db in
            try db.query(
                """
                SELECT r.message, r.type, a.address, a.comment FROM recipients r JOIN addresses a ON a.ROWID = r.address
                WHERE r.message IN (SELECT value FROM json_each(?)) ORDER BY r.message, r.type, r.position
                """, [Self.idArray(ids)]
            ) { row in
                let address = EmailAddress(address: row.string(2), name: row.optionalString(3))
                if row.int(1) == 0 { found[row.int(0)]?.to.append(address) } else if row.int(1) == 1 { found[row.int(0)]?.cc.append(address) }
            }
        }
        return found
    }

    /// Bytes of one attachment, by part ID or filename.
    public func attachmentData(messageID: Int64, attachment: String) throws -> (info: AttachmentInfo, data: Data) {
        let detail = try detail(id: messageID)
        guard let info = detail.attachments.first(where: { $0.partID == attachment })
            ?? detail.attachments.first(where: { $0.filename == attachment })
            ?? detail.attachments.first(where: { $0.filename.localizedCaseInsensitiveContains(attachment) })
        else { throw MailStoreError.attachmentNotFound(attachment) }
        guard let url = try emlxURL(for: detail.summary) else { throw MailStoreError.bodyNotDownloaded(messageID) }
        let root = MIME.parse(try EmlxFile(url: url).message)
        if let part = root.leaves.first(where: { $0.partID == info.partID }), part.hasInlineData {
            return (info, part.decodedBody())
        }
        if let mailbox = try mailbox(id: detail.summary.mailboxID), let mailboxURL = MailboxURL(mailbox.url),
           let file = files.attachmentFile(rowID: messageID, mailbox: mailboxURL, partID: info.partID)
        {
            return (info, try Data(contentsOf: file))
        }
        throw MailStoreError.bodyNotDownloaded(messageID)
    }

    // MARK: Threads

    /// Every message in the conversation of `id`, oldest first, de-duplicated
    /// across mailboxes (the same message in Inbox and Archive appears once).
    public func thread(of id: Int64, limit: Int = 100) throws -> [MessageSummary] {
        let anchor = try message(id: id)
        var query = MessageQuery()
        query.conversationID = anchor.conversationID
        query.includeTrashAndJunk = true
        query.sortAscending = true
        query.limit = 500
        let page = try search(query, needsTotal: false)
        var seen = Set<String>()
        var out: [MessageSummary] = []
        for message in page.messages {
            let key = message.messageIDHeader ?? "rowid:\(message.id)"
            if seen.insert(key).inserted { out.append(message) }
        }
        return Array(out.suffix(limit))
    }
}

/// Lock-protected result flags written from `concurrentPerform`.
final class BoolSlots: @unchecked Sendable {
    private var storage: [Bool]
    private let lock = NSLock()

    init(count: Int) { storage = Array(repeating: false, count: count) }

    func set(_ index: Int, _ value: Bool) {
        lock.lock()
        storage[index] = value
        lock.unlock()
    }

    var values: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// A count running on another thread; `wait` blocks until it is done.
final class PendingCount: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private var result: Result<Int64, Error>?

    func finish(_ result: Result<Int64, Error>) {
        self.result = result
        done.signal()
    }

    func wait() throws -> Int64 {
        done.wait()
        done.signal()  // later waits return at once
        return try result!.get()
    }
}

/// What `detail` takes from a message file: everything but the envelope and whether attachments are on disk.
struct ParsedMessage: Sendable {
    struct Part: Sendable {
        var partID: String
        var filename: String
        var mimeType: String
        var size: Int?
        var inline: Bool
    }

    var to: [EmailAddress]
    var cc: [EmailAddress]
    var replyTo: [EmailAddress]
    var headers: [(name: String, value: String)]
    var text: String?
    var textWithoutQuotes: String?
    var html: String?
    var attachments: [Part]

    init(emlx: EmlxFile) {
        let root = MIME.parse(emlx.message)
        let bodies = MessageContent.bodies(root)
        to = MIME.parseAddressList(root.headers["To"])
        cc = MIME.parseAddressList(root.headers["Cc"])
        replyTo = MIME.parseAddressList(root.headers["Reply-To"])
        headers = root.headers.fields.map { ($0.name, MIME.decodeEncodedWords($0.value)) }
        text = bodies.text
        textWithoutQuotes = bodies.text.map(MessageContent.stripQuotedReply)
        html = bodies.html
        attachments = root.leaves.filter(\.isAttachment).map { part in
            Part(
                partID: part.partID, filename: part.filename ?? "part-\(part.partID)", mimeType: part.contentType,
                size: part.appleContentLength ?? (part.hasInlineData ? part.decodedSize : nil), inline: part.hasInlineData)
        }
    }

    var size: Int {
        [text, textWithoutQuotes, html].reduce(0) { $0 + ($1?.utf8.count ?? 0) } + headers.reduce(0) { $0 + $1.value.utf8.count }
    }
}


/// A statement and its bindings, as a cache key.
struct StatementKey: Hashable {
    var sql: String
    var bindings: [SQLValue]
}
