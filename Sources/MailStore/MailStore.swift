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
    private var cachedAccounts: [MailAccount] = []
    private var extraAddresses: [String: Set<String>] = [:]

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

    private func refreshCachesIfNeeded() throws {
        let version = try dataVersion()
        lock.lock()
        let fresh = version == cachedDataVersion && !cachedMailboxes.isEmpty
        lock.unlock()
        if fresh { return }

        var mailboxes: [Int64: Mailbox] = [:]
        try withDB { db in
            try db.query("SELECT ROWID, url, total_count, unread_count, source FROM mailboxes") { row in
                let url = row.string(1)
                guard let parsed = MailboxURL(url) else { return }
                let id = row.int(0)
                mailboxes[id] = Mailbox(
                    id: id, url: url, accountID: parsed.accountID, path: parsed.path, name: parsed.name,
                    role: MailboxRoleDetector.role(for: parsed),
                    totalCount: Int(row.int(2)), unreadCount: Int(row.int(3)),
                    sourceMailboxID: row.optionalInt(4))
            }
        }
        var schemes: [String: String] = [:]
        for mailbox in mailboxes.values {
            if let scheme = MailboxURL(mailbox.url)?.scheme { schemes[mailbox.accountID] = scheme }
        }
        let names = AccountDirectory.names(for: Set(schemes.keys), accountsDatabase: location.accountsDatabase)
        let detected = try detectOwnAddresses(mailboxes: mailboxes)
        lock.lock()
        let extras = extraAddresses
        lock.unlock()
        let accounts = schemes.keys.sorted().map { id in
            let addresses = detected[id, default: []].union(extras[id, default: []])
            return MailAccount(id: id, name: names[id] ?? id, kind: schemes[id] ?? "imap", emailAddresses: addresses.sorted())
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        lock.lock()
        cachedMailboxes = mailboxes
        cachedAccounts = accounts
        cachedDataVersion = version
        lock.unlock()
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
        extraAddresses[accountID, default: []].formUnion(addresses.map { $0.lowercased() })
        cachedDataVersion = -1
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
        lock.lock()
        let all = Array(cachedMailboxes.values)
        lock.unlock()
        return all
            .filter { accountID == nil || $0.accountID == accountID }
            .sorted { ($0.accountID, $0.path.lowercased()) < ($1.accountID, $1.path.lowercased()) }
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
        let json = "[" + ids.map(String.init).joined(separator: ",") + "]"
        let found = try withDB { db in
            try db.all(
                "SELECT \(summaryColumns) \(Self.summaryJoins) WHERE m.ROWID IN (SELECT value FROM json_each(?))",
                [.text(json)]
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
        let mailboxJSON = "[" + mailboxIDs.map(String.init).joined(separator: ",") + "]"
        return try withDB { db in
            try db.all(
                """
                SELECT \(summaryColumns) \(Self.summaryJoins)
                WHERE m.deleted = 0 AND g.message_id_header IN (SELECT value FROM json_each(?))
                AND (m.mailbox IN (SELECT value FROM json_each(?))
                     OR m.ROWID IN (SELECT message_id FROM labels WHERE mailbox_id IN (SELECT value FROM json_each(?))))
                """, [.text(headerJSON), .text(mailboxJSON), .text(mailboxJSON)]
            ) { summary(from: $0, mailboxes: mailboxes, accountNames: names) }
        }
    }

    public func message(id: Int64) throws -> MessageSummary {
        guard let found = try messages(ids: [id]).first else { throw MailStoreError.messageNotFound(id) }
        return found
    }

    /// Builds the WHERE clause shared by search and counting.
    func whereClause(for query: MessageQuery, mailboxes: [Int64: Mailbox]) -> (String, [SQLValue]) {
        var clauses = ["m.deleted = 0"]
        var bindings: [SQLValue] = []

        if !query.ids.isEmpty {
            clauses.append("m.ROWID IN (SELECT value FROM json_each(?))")
            bindings.append(.text("[" + query.ids.map(String.init).joined(separator: ",") + "]"))
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
                clauses.append("m.mailbox IN (\(allowed.map { String($0.id) }.joined(separator: ",")))")
                if allowed.isEmpty { clauses.append("0") }
            }
        }
        // Text filters match the small lookup tables first, then use the messages indexes
        // (subject, sender, recipients_address) instead of joining every message.
        let subjectsLike = "SELECT ROWID FROM subjects WHERE subject LIKE ? ESCAPE '\\'"
        let addressesLike = "SELECT ROWID FROM addresses WHERE address LIKE ? ESCAPE '\\' OR comment LIKE ? ESCAPE '\\'"
        if let text = query.text?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
            let pattern = SQLiteConnection.likePattern(containing: text)
            clauses.append(
                """
                (m.subject IN (\(subjectsLike)) OR m.sender IN (\(addressesLike)) \
                OR m.summary IN (SELECT ROWID FROM summaries WHERE summary LIKE ? ESCAPE '\\'))
                """)
            bindings += Array(repeating: .text(pattern), count: 4)
        }
        let terms = query.subjectTerms.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !terms.isEmpty {
            let likes = terms.map { _ in "subject LIKE ? ESCAPE '\\'" }.joined(separator: " OR ")
            clauses.append("m.subject IN (SELECT ROWID FROM subjects WHERE \(likes))")
            bindings += terms.map { .text(SQLiteConnection.likePattern(containing: $0)) }
        }
        if let sender = query.sender?.trimmingCharacters(in: .whitespaces), !sender.isEmpty {
            clauses.append("m.sender IN (\(addressesLike))")
            let pattern = SQLiteConnection.likePattern(containing: sender)
            bindings += [.text(pattern), .text(pattern)]
        }
        if let recipient = query.recipient?.trimmingCharacters(in: .whitespaces), !recipient.isEmpty {
            clauses.append("m.ROWID IN (SELECT message FROM recipients WHERE address IN (\(addressesLike)))")
            let pattern = SQLiteConnection.likePattern(containing: recipient)
            bindings += [.text(pattern), .text(pattern)]
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
        return (clauses.joined(separator: " AND "), bindings)
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
    public func search(_ query: MessageQuery, bodyIndex: (any BodySearchIndex)? = nil) throws -> SearchPage {
        let (mailboxes, names) = try lookupTables()
        var (whereSQL, bindings) = whereClause(for: query, mailboxes: mailboxes)
        let direction = query.sortAscending ? "ASC" : "DESC"
        let order = "ORDER BY m.date_received \(direction), m.ROWID \(direction)"
        let limit = max(1, min(query.limit, 500))
        let offset = max(0, query.offset)

        guard let bodyText = query.bodyText?.trimmingCharacters(in: .whitespaces), !bodyText.isEmpty else {
            let rows = try withDB { db in
                try db.all(
                    "SELECT \(summaryColumns) \(Self.summaryJoins) WHERE \(whereSQL) \(order) LIMIT ? OFFSET ?",
                    bindings + [.int(Int64(limit)), .int(Int64(offset))]
                ) { summary(from: $0, mailboxes: mailboxes, accountNames: names) }
            }
            let total = try withDB { db in
                try db.scalarInt("SELECT COUNT(*) \(Self.minimalJoins(for: whereSQL)) WHERE \(whereSQL)", bindings) ?? 0
            }
            return SearchPage(
                messages: rows, total: Int(total), offset: offset, limit: limit,
                hasMore: offset + rows.count < Int(total), bodySearchMode: nil, scanLimited: false, scannedMessages: 0)
        }

        // Body search: indexed matches, plus a scan of whatever the index has not covered yet.
        var mode = "scan"
        var covered: Int64 = 0
        if let bodyIndex {
            covered = try bodyIndex.coveredThrough()
            let matches = try bodyIndex.matchingIDs(for: bodyText, limit: 200_000)
            mode = "index"
            whereSQL += " AND (m.ROWID IN (SELECT value FROM json_each(?)) OR m.ROWID > ?)"
            bindings.append(.text("[" + matches.map(String.init).joined(separator: ",") + "]"))
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
        let wanted = offset + limit
        let chunkSize = 64
        while cursor < candidates.count {
            // Indexed candidates are already matches; collect a run of them cheaply.
            let (id, _) = candidates[cursor]
            if bodyIndex != nil && id <= covered {
                matchedIDs.append(id)
                cursor += 1
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
            // Without an index, stop once the page is full: the total is then unknown.
            if bodyIndex == nil, matchedIDs.count >= wanted + 1 { break }
        }
        let complete = cursor >= candidates.count && !scanLimited
        let pageIDs = Array(matchedIDs.dropFirst(offset).prefix(limit))
        return SearchPage(
            messages: try messages(ids: pageIDs), total: complete ? matchedIDs.count : nil, offset: offset, limit: limit,
            hasMore: matchedIDs.count > offset + pageIDs.count || !complete, bodySearchMode: mode,
            scanLimited: scanLimited, scannedMessages: scanned)
    }

    /// Checks a batch of messages for `pattern` across all cores.
    private func scanChunk(_ chunk: [(Int64, Int64)], pattern: TextFold.Pattern, mailboxes: [Int64: Mailbox]) -> [Bool] {
        let results = BoolSlots(count: chunk.count)
        DispatchQueue.concurrentPerform(iterations: chunk.count) { index in
            let (id, mailboxID) = chunk[index]
            guard let mailbox = mailboxes[mailboxID], let url = MailboxURL(mailbox.url),
                  let file = files.emlxURL(rowID: id, mailbox: url),
                  let emlx = try? EmlxFile(url: file)
            else { return }
            let text = MessageContent.searchableText(MIME.parse(emlx.message), maxCharacters: .max)
            results.set(index, pattern.matches(text))
        }
        return results.values
    }

    // MARK: Content

    /// Locates the `.emlx` for a message (in its own mailbox).
    public func emlxURL(for summary: MessageSummary) throws -> URL? {
        guard let mailbox = try mailbox(id: summary.mailboxID), let url = MailboxURL(mailbox.url) else { return nil }
        return files.emlxURL(rowID: summary.id, mailbox: url)
    }

    /// Raw RFC 822 source of a message.
    public func rawSource(id: Int64) throws -> Data {
        let summary = try message(id: id)
        guard let url = try emlxURL(for: summary) else { throw MailStoreError.bodyNotDownloaded(id) }
        return try EmlxFile(url: url).message
    }

    /// Envelope plus parsed body, recipients and attachment list.
    public func detail(id: Int64) throws -> MessageDetail {
        let summary = try message(id: id)
        let (to, cc) = try recipients(of: id)
        guard let url = try emlxURL(for: summary) else {
            return MessageDetail(
                summary: summary, to: to, cc: cc, replyTo: [], headers: [], textBody: nil, htmlBody: nil,
                attachments: try attachmentNamesFromIndex(id), bodyAvailable: false)
        }
        let emlx = try EmlxFile(url: url)
        let root = MIME.parse(emlx.message)
        let bodies = MessageContent.bodies(root)
        let mailboxURL = try mailbox(id: summary.mailboxID).flatMap { MailboxURL($0.url) }
        let attachments = root.leaves.filter(\.isAttachment).map { part in
            let onDisk = part.hasInlineData
                || (mailboxURL.flatMap { files.attachmentFile(rowID: id, mailbox: $0, partID: part.partID) } != nil)
            let size = part.appleContentLength ?? (part.hasInlineData ? part.decodedBody().count : nil)
            return AttachmentInfo(
                partID: part.partID, filename: part.filename ?? "part-\(part.partID)", mimeType: part.contentType,
                size: size, isDownloaded: onDisk)
        }
        let headerTo = MIME.parseAddressList(root.headers["To"])
        let headerCc = MIME.parseAddressList(root.headers["Cc"])
        return MessageDetail(
            summary: summary,
            to: headerTo.isEmpty ? to : headerTo,
            cc: headerCc.isEmpty ? cc : headerCc,
            replyTo: MIME.parseAddressList(root.headers["Reply-To"]),
            headers: root.headers.fields.map { ($0.name, MIME.decodeEncodedWords($0.value)) },
            textBody: bodies.text, htmlBody: bodies.html, attachments: attachments, bodyAvailable: true)
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
        var to: [EmailAddress] = []
        var cc: [EmailAddress] = []
        try withDB { db in
            try db.query(
                """
                SELECT r.type, a.address, a.comment FROM recipients r JOIN addresses a ON a.ROWID = r.address
                WHERE r.message = ? ORDER BY r.type, r.position
                """, [.int(id)]
            ) { row in
                let address = EmailAddress(address: row.string(1), name: row.optionalString(2))
                if row.int(0) == 0 { to.append(address) } else if row.int(0) == 1 { cc.append(address) }
            }
        }
        return (to, cc)
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
        let page = try search(query)
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
