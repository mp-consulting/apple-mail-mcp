import Foundation

/// Incremental full-text index of message bodies (SQLite FTS5) that stores no text.
///
/// Mail's own body index lives in a private CoreSpotlight store, so we keep our own, one row per
/// message ROWID covering subject, sender and body. Mail's store is behind Full Disk Access and
/// this file is not, so it holds only keyed hashes (SipHash-2-4, key in the Keychain):
///
/// - each message is the set of its distinct word tokens and adjacent-pair (bigram) tokens, in
///   separate hash domains, with no positions (`detail = none`) and no content (`content = ''`);
/// - `vocab` maps hashed prefixes (3–20 characters) to the hashed words that start with them, so
///   prefix search expands to word tokens; quoted phrases match through their bigrams.
///
/// Mail's ROWIDs only grow, so "everything up to N" is a complete watermark;
/// messages whose body was not downloaded yet go to `pending` and are retried.
public final class BodyIndex: BodySearchIndex, @unchecked Sendable {
    public let url: URL
    private let db: SQLiteConnection
    private let lock = NSLock()
    private let keyProvider: @Sendable () throws -> BodyIndexKey
    private var cachedTokens: Tokens?
    /// A Keychain refusal is remembered, so a denied prompt is not shown again on every search.
    private var keyError: Error?
    /// Version 1 kept every word with its position: the text could be read back without a key.
    static let schemaVersion: Int64 = 2
    /// Version 1 adds the text of attached PDFs and text files; older indexes re-read their messages with attachments.
    static let attachmentsVersion: Int64 = 1

    public static func defaultURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/apple-mail-mcp/body-index.sqlite")
    }

    /// Opens (creating if needed) the index at `url`. The key is only fetched when a search or an
    /// update needs it, so reading ``status()`` never touches the Keychain.
    public init(url: URL = BodyIndex.defaultURL(), key: @escaping @Sendable () throws -> BodyIndexKey = BodyIndexKey.fromKeychain)
        throws
    {
        self.url = url
        keyProvider = key
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // An older index holds readable text: delete the file rather than its rows, so none of it
        // stays behind in free pages or the WAL.
        if FileManager.default.fileExists(atPath: url.path), (Self.storedSchemaVersion(at: url) ?? 0) < Self.schemaVersion {
            Self.removeFiles(at: url)
        }
        db = try SQLiteConnection(path: url.path, readOnly: false, create: true)
        try db.execute("PRAGMA journal_mode = WAL")
        try db.execute("PRAGMA synchronous = NORMAL")
        try db.execute(
            """
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value);
            CREATE TABLE IF NOT EXISTS docs (rowid INTEGER PRIMARY KEY);
            CREATE TABLE IF NOT EXISTS pending (rowid INTEGER PRIMARY KEY, attempts INTEGER NOT NULL, last_attempt INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS vocab (prefix INTEGER NOT NULL, word INTEGER NOT NULL, PRIMARY KEY (prefix, word)) WITHOUT ROWID;
            CREATE VIRTUAL TABLE IF NOT EXISTS body_fts USING fts5(
                tokens, content = '', contentless_delete = 1, detail = none, tokenize = 'ascii');
            """)
        if try metaInt("schema_version") == nil {
            try setMeta("schema_version", Self.schemaVersion)
            try setMeta("attachments_version", Self.attachmentsVersion)
        }
        Self.protect(url)
    }

    /// Opens the default index only if it already exists (servers never create it implicitly).
    public static func openIfPresent(
        url: URL = BodyIndex.defaultURL(), key: @escaping @Sendable () throws -> BodyIndexKey = BodyIndexKey.fromKeychain
    ) -> BodyIndex? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? BodyIndex(url: url, key: key)
    }

    private static func storedSchemaVersion(at url: URL) -> Int64? {
        guard let db = try? SQLiteConnection(path: url.path, readOnly: false) else { return nil }
        return (try? db.first("SELECT value FROM meta WHERE key = 'schema_version'") { $0.optionalInt(0) }) ?? nil
    }

    private static func removeFiles(at url: URL) {
        for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }

    /// Owner-only permissions, and no copies in backups (the index is rebuilt in about a minute).
    private static func protect(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: url.path + suffix) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path + suffix)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = url
        try? target.setResourceValues(values)
    }

    private func withDB<T>(_ body: (SQLiteConnection) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(db)
    }

    private func metaInt(_ key: String) throws -> Int64? {
        try withDB { try $0.first("SELECT value FROM meta WHERE key = ?", [.text(key)]) { $0.optionalInt(0) } ?? nil }
    }

    private func setMeta(_ key: String, _ value: Int64) throws {
        try withDB { try $0.run("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", [.text(key), .int(value)]) }
    }

    /// The hasher for the current key. An index built with another key (the Keychain item was
    /// deleted or reset) cannot answer anything, so it is cleared and rebuilt.
    private func tokens() throws -> Tokens {
        let (cached, failed) = lock.withLock { (cachedTokens, keyError) }
        if let cached { return cached }
        if let failed { throw failed }
        let key: BodyIndexKey
        do { key = try keyProvider() } catch {
            lock.withLock { keyError = error }
            throw error
        }
        let tokens = Tokens(key: key)
        let check = Int64(bitPattern: tokens.check)
        let stored = try metaInt("key_check")
        if stored != check {
            if stored != nil { try reset() }
            try setMeta("key_check", check)
        }
        lock.withLock { cachedTokens = tokens }
        return tokens
    }

    /// Whether the key is available, so searches can use the index (otherwise they scan).
    public var isUnlocked: Bool { (try? tokens()) != nil }

    // MARK: Tokens

    /// Keyed hashes for words, bigrams and prefixes, each in its own domain so that, without the
    /// key, a bigram token cannot be linked to the word tokens it was made from.
    struct Tokens: Sendable {
        static let minPrefix = 3
        static let maxPrefix = 20
        let hasher: SipHash24

        init(key: BodyIndexKey) { hasher = SipHash24(key: key.bytes) }

        private func hash(_ domain: UInt8, _ text: String) -> UInt64 { hasher.hash([domain] + Array(text.utf8)) }

        var check: UInt64 { hash(0, "apple-mail-mcp body index") }
        func word(_ word: String) -> UInt64 { hash(1, word) }
        func bigram(_ first: String, _ second: String) -> UInt64 { hash(2, first + " " + second) }
        func prefix(_ prefix: some StringProtocol) -> UInt64 { hash(3, String(prefix)) }

        /// Prefixes a word is found under (none for words shorter than `minPrefix`).
        func prefixes(of word: String) -> [UInt64] {
            let length = word.count
            guard length >= Self.minPrefix else { return [] }
            return (Self.minPrefix...min(length, Self.maxPrefix)).map { prefix(word.prefix($0)) }
        }

        static func text(_ token: UInt64) -> String {
            let hex = String(token, radix: 16)
            return String(repeating: "0", count: 16 - hex.count) + hex
        }
    }

    /// Words as the index sees them: case and diacritics folded, split on anything that is not a
    /// letter or a digit (as FTS5's unicode61 tokenizer does).
    static func words(in text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    // MARK: Query

    public func coveredThrough() throws -> Int64 {
        _ = try tokens()  // a key change resets the watermark too
        return try metaInt("covered_through") ?? 0
    }

    enum QueryTerm: Equatable {
        /// Any word starting with this (at least `minPrefix` characters).
        case prefix(String)
        /// This word exactly.
        case word(String)
        /// These words next to each other, in this order.
        case phrase([String])
    }

    /// Turns free text into terms that must all match: every word as a prefix (shorter ones
    /// exactly); "quoted phrases" and joined words like `me@icloud.test` as phrases.
    static func queryTerms(for text: String) -> [QueryTerm] {
        var terms: [QueryTerm] = []
        func add(_ words: [String], quoted: Bool) {
            switch words.count {
            case 0: break
            case 1 where quoted || words[0].count < Tokens.minPrefix: terms.append(.word(words[0]))
            case 1: terms.append(.prefix(words[0]))
            default: terms.append(.phrase(words))
            }
        }
        func addLoose(_ text: Substring) {
            for piece in pieces(text) { add(words(in: piece), quoted: false) }
        }
        var remaining = Substring(text)
        while let open = remaining.firstIndex(of: "\"") {
            addLoose(remaining[..<open])
            let afterOpen = remaining[remaining.index(after: open)...]
            if let close = afterOpen.firstIndex(of: "\"") {
                add(words(in: String(afterOpen[..<close])), quoted: true)
                remaining = afterOpen[afterOpen.index(after: close)...]
            } else {
                remaining = afterOpen
            }
        }
        addLoose(remaining)
        return terms
    }

    /// Whitespace and punctuation separate terms; `@ . - _` join the words of one term.
    private static func pieces(_ text: Substring) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "@" && $0 != "." && $0 != "-" && $0 != "_" })
            .map(String.init)
    }

    public func matchingIDs(for text: String, limit: Int) throws -> [Int64] {
        let terms = Self.queryTerms(for: text)
        guard !terms.isEmpty else { return [] }
        let tokens = try tokens()
        // Each group is a set of alternatives; a message must contain one token of every group.
        var groups: [[UInt64]] = []
        for term in terms {
            switch term {
            case .word(let word):
                groups.append([tokens.word(word)])
            case .phrase(let words):
                groups += zip(words, words.dropFirst()).map { [tokens.bigram($0, $1)] }
            case .prefix(let prefix):
                let key = Int64(bitPattern: tokens.prefix(prefix.prefix(Tokens.maxPrefix)))
                let expanded = try withDB { db in
                    try db.all("SELECT word FROM vocab WHERE prefix = ?", [.int(key)]) { UInt64(bitPattern: $0.int(0)) }
                }
                guard !expanded.isEmpty else { return [] }
                groups.append(expanded)
            }
        }
        return try withDB { db in
            var matches: Set<Int64>?
            // Smallest groups first: the intersection shrinks fastest.
            for group in groups.sorted(by: { $0.count < $1.count }) {
                var ids = Set<Int64>()
                for start in stride(from: 0, to: group.count, by: 500) {
                    let query = group[start..<min(start + 500, group.count)]
                        .map { "\"\(Tokens.text($0))\"" }.joined(separator: " OR ")
                    try db.query("SELECT rowid FROM body_fts WHERE body_fts MATCH ?", [.text(query)]) { ids.insert($0.int(0)) }
                }
                matches = matches.map { $0.intersection(ids) } ?? ids
                if matches?.isEmpty ?? true { return [] }
            }
            return Array((matches ?? []).sorted().prefix(limit))
        }
    }

    // MARK: Status

    public struct Status: Codable, Sendable {
        public var indexedMessages: Int
        public var pendingMessages: Int
        public var coveredThrough: Int64
        public var lastUpdate: Date?
        public var sizeBytes: Int64
    }

    public func status() throws -> Status {
        let (indexed, pending) = try withDB { db in
            (
                Int(try db.scalarInt("SELECT COUNT(*) FROM docs") ?? 0),
                Int(try db.scalarInt("SELECT COUNT(*) FROM pending WHERE attempts > 0") ?? 0)
            )
        }
        let last = try metaInt("last_update").map { Date(timeIntervalSince1970: TimeInterval($0)) }
        var size: Int64 = 0
        for suffix in ["", "-wal", "-shm"] {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path + suffix)
            size += (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
        return Status(
            indexedMessages: indexed, pendingMessages: pending, coveredThrough: try metaInt("covered_through") ?? 0,
            lastUpdate: last, sizeBytes: size)
    }

    // MARK: Update

    public struct UpdateResult: Sendable {
        public var indexed: Int
        public var pendingAdded: Int
        public var pruned: Int
        public var remaining: Int
        public var duration: TimeInterval
    }

    /// Indexes messages newer than the watermark (and retries pending ones)
    /// until done or `timeBudget` runs out. Safe to call repeatedly.
    @discardableResult
    public func update(
        from store: MailStore, batchSize: Int = 2000, timeBudget: TimeInterval = .infinity,
        retryAfter: TimeInterval = 600, progress: (@Sendable (Int, Int) -> Void)? = nil
    ) throws -> UpdateResult {
        let started = Date()
        let tokens = try tokens()
        var indexed = 0
        var pendingAdded = 0
        let latest = try store.maxMessageRowID()
        var covered = try coveredThrough()
        let totalNew = try store.countMessages(after: covered)
        if try metaInt("attachments_version") ?? 0 < Self.attachmentsVersion { try queueAttachmentBackfill(from: store) }
        // Words already in `vocab` need no prefix rows; loaded once per update.
        var knownWords = Set(try withDB { db in try db.all("SELECT DISTINCT word FROM vocab") { $0.int(0) } })

        // Retry bodies that were not downloaded last time (at most once per `retryAfter`).
        let retry = try withDB { db in
            try db.all(
                "SELECT rowid FROM pending WHERE attempts < 30 AND last_attempt < ? LIMIT ?",
                [.int(Int64(Date().timeIntervalSince1970 - retryAfter) + (retryAfter == 0 ? 1 : 0)), .int(Int64(batchSize))]
            ) { $0.int(0) }
        }
        if !retry.isEmpty {
            let candidates = try store.indexCandidates(ids: retry)
            let (docs, missing) = Self.extract(candidates, store: store, tokens: tokens)
            try write(docs: docs, missing: missing, watermark: nil, tokens: tokens, knownWords: &knownWords)
            indexed += docs.count
        }

        while covered < latest, Date().timeIntervalSince(started) < timeBudget {
            let candidates = try store.indexCandidates(after: covered, limit: batchSize)
            guard let last = candidates.last?.id else {
                covered = latest
                try setMeta("covered_through", covered)
                break
            }
            let (docs, missing) = Self.extract(candidates, store: store, tokens: tokens)
            try write(docs: docs, missing: missing, watermark: last, tokens: tokens, knownWords: &knownWords)
            covered = last
            indexed += docs.count
            pendingAdded += missing.count
            progress?(indexed, totalNew)
        }
        try setMeta("last_update", Int64(Date().timeIntervalSince1970))
        Self.protect(url)
        let remaining = try store.countMessages(after: covered)
        return UpdateResult(
            indexed: indexed, pendingAdded: pendingAdded, pruned: 0, remaining: remaining,
            duration: Date().timeIntervalSince(started))
    }

    /// Re-reads indexed messages that have attachments, so their attachments' text gets indexed. They wait in
    /// `pending` with no failed attempt (not counted as waiting for download) and go `batchSize` per update.
    func queueAttachmentBackfill(from store: MailStore) throws {
        let ids = try store.messageIDsWithAttachments()
        try withDB { db in
            try db.transaction {
                for id in ids {
                    try db.run(
                        "INSERT OR IGNORE INTO pending (rowid, attempts, last_attempt) SELECT ?, 0, 0 WHERE EXISTS (SELECT 1 FROM docs WHERE rowid = ?)",
                        [.int(id), .int(id)])
                }
                try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('attachments_version', ?)", [.int(Self.attachmentsVersion)])
            }
        }
    }

    /// Removes index entries for messages Mail no longer has.
    @discardableResult
    public func prune(against store: MailStore) throws -> Int {
        let live = Set(try store.liveMessageIDs())
        let indexed = try withDB { db in try db.all("SELECT rowid FROM docs") { $0.int(0) } }
        let stale = indexed.filter { !live.contains($0) }
        guard !stale.isEmpty else { return 0 }
        try withDB { db in
            try db.transaction {
                for id in stale {
                    try db.run("DELETE FROM body_fts WHERE rowid = ?", [.int(id)])
                    try db.run("DELETE FROM docs WHERE rowid = ?", [.int(id)])
                    try db.run("DELETE FROM pending WHERE rowid = ?", [.int(id)])
                }
            }
        }
        return stale.count
    }

    /// Drops everything; the next update re-indexes from scratch.
    public func reset() throws {
        try withDB { db in
            try db.execute(
                """
                DELETE FROM body_fts; DELETE FROM docs; DELETE FROM pending; DELETE FROM vocab;
                DELETE FROM meta WHERE key NOT IN ('schema_version', 'key_check');
                """)
        }
    }

    struct Document {
        var id: Int64
        /// Distinct word and bigram tokens.
        var tokens: [UInt64]
        /// Distinct words with their tokens, for `vocab`. Plain text only in memory.
        var words: [(token: UInt64, word: String)]
    }

    /// Hashes one message's fields into a document. Bigrams never span two fields.
    static func document(id: Int64, fields: [String], tokens: Tokens) -> Document {
        var all = Set<UInt64>()
        var words: [String: UInt64] = [:]
        for field in fields {
            let fieldWords = Self.words(in: field)
            for word in fieldWords where words[word] == nil {
                let token = tokens.word(word)
                words[word] = token
                all.insert(token)
            }
            for (first, second) in zip(fieldWords, fieldWords.dropFirst()) { all.insert(tokens.bigram(first, second)) }
        }
        return Document(id: id, tokens: Array(all), words: words.map { ($0.value, $0.key) })
    }

    /// Reads, parses and hashes `.emlx` files in parallel.
    static func extract(_ candidates: [IndexCandidate], store: MailStore, tokens: Tokens) -> ([Document], [Int64]) {
        let results = Slots<Document>(count: candidates.count)
        defer { results.deallocate() }
        DispatchQueue.concurrentPerform(iterations: candidates.count) { index in
            let candidate = candidates[index]
            guard let mailbox = candidate.mailboxURL,
                  let file = store.files.emlxURL(rowID: candidate.id, mailbox: mailbox),
                  let emlx = try? EmlxFile(url: file)
            else { return }
            results[index] = autoreleasepool {
                let root = MIME.parse(emlx.message)
                let body = MessageContent.searchableText(root)
                let attached = store.attachmentText(root, rowID: candidate.id, mailbox: mailbox)
                return document(id: candidate.id, fields: [candidate.subject, candidate.sender, body] + attached, tokens: tokens)
            }
        }
        var docs: [Document] = []
        var missing: [Int64] = []
        for (index, candidate) in candidates.enumerated() {
            if let doc = results[index] { docs.append(doc) } else { missing.append(candidate.id) }
        }
        return (docs, missing)
    }

    private func write(
        docs: [Document], missing: [Int64], watermark: Int64?, tokens: Tokens, knownWords: inout Set<Int64>
    ) throws {
        let now = Int64(Date().timeIntervalSince1970)
        var vocab: [(prefix: Int64, word: Int64)] = []
        for doc in docs {
            for (token, word) in doc.words where knownWords.insert(Int64(bitPattern: token)).inserted {
                vocab += tokens.prefixes(of: word).map { (Int64(bitPattern: $0), Int64(bitPattern: token)) }
            }
        }
        try withDB { db in
            try db.transaction {
                for doc in docs {
                    try db.run("DELETE FROM body_fts WHERE rowid = ?", [.int(doc.id)])
                    try db.run(
                        "INSERT INTO body_fts (rowid, tokens) VALUES (?, ?)",
                        [.int(doc.id), .text(doc.tokens.map(Tokens.text).joined(separator: " "))])
                    try db.run("INSERT OR IGNORE INTO docs (rowid) VALUES (?)", [.int(doc.id)])
                    try db.run("DELETE FROM pending WHERE rowid = ?", [.int(doc.id)])
                }
                for row in vocab {
                    try db.run("INSERT OR IGNORE INTO vocab (prefix, word) VALUES (?, ?)", [.int(row.prefix), .int(row.word)])
                }
                for id in missing {
                    try db.run(
                        """
                        INSERT INTO pending (rowid, attempts, last_attempt) VALUES (?, 1, ?)
                        ON CONFLICT(rowid) DO UPDATE SET attempts = attempts + 1, last_attempt = excluded.last_attempt
                        """, [.int(id), .int(now)])
                }
                if let watermark {
                    try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('covered_through', ?)", [.int(watermark)])
                }
            }
        }
    }
}

/// Fixed-size result slots written from `concurrentPerform`; each iteration owns one index.
private struct Slots<T>: @unchecked Sendable {
    let buffer: UnsafeMutableBufferPointer<T?>

    init(count: Int) {
        buffer = .allocate(capacity: count)
        buffer.initialize(repeating: nil)
    }

    subscript(index: Int) -> T? {
        get { buffer[index] }
        nonmutating set { buffer[index] = newValue }
    }

    func deallocate() {
        _ = buffer.deinitialize()
        buffer.deallocate()
    }
}

/// What the indexer needs to know about a message, read in one query.
public struct IndexCandidate: Sendable {
    public var id: Int64
    public var mailboxURL: MailboxURL?
    public var subject: String
    public var sender: String
}

extension MailStore {
    public func countMessages(after rowID: Int64) throws -> Int {
        Int(try withDB { try $0.scalarInt("SELECT COUNT(*) FROM messages WHERE ROWID > ? AND deleted = 0", [.int(rowID)]) ?? 0 })
    }

    func messageIDsWithAttachments() throws -> [Int64] {
        try withDB { try $0.all("SELECT DISTINCT a.message FROM attachments a JOIN messages m ON m.ROWID = a.message WHERE m.deleted = 0") { $0.int(0) } }
    }

    /// Text of attached PDFs (first pages) and text files, one string per attachment, for the body index.
    func attachmentText(_ root: MIMEPart, rowID: Int64, mailbox: MailboxURL, maxCharacters: Int = 40_000) -> [String] {
        var texts: [String] = []
        var budget = maxCharacters
        for part in root.leaves where part.isAttachment && budget > 0 {
            let type = part.contentType
            let name = part.filename?.lowercased() ?? ""
            var text: String?
            if Self.isPDF(part) {
                text = attachmentBytes(part, rowID: rowID, mailbox: mailbox, limit: 15 * 1_048_576).flatMap { Self.pdfText($0, maxPages: 5) }
            } else if ["text/plain", "text/csv", "text/markdown"].contains(type) || [".txt", ".csv", ".md"].contains(where: name.hasSuffix) {
                text = attachmentBytes(part, rowID: rowID, mailbox: mailbox, limit: 1_048_576)
                    .map { MIME.decodeText($0, charset: part.parameters["charset"]) }
            }
            guard let text, !text.isEmpty else { continue }
            texts.append(String(text.prefix(budget)))
            budget -= text.count
        }
        return texts
    }

    public func liveMessageIDs() throws -> [Int64] {
        try withDB { try $0.all("SELECT ROWID FROM messages WHERE deleted = 0") { $0.int(0) } }
    }

    private static let candidateSQL = """
        SELECT m.ROWID, mb.url, IFNULL(m.subject_prefix, '') || s.subject, IFNULL(a.comment, '') || ' ' || IFNULL(a.address, '')
        FROM messages m JOIN subjects s ON s.ROWID = m.subject
        JOIN mailboxes mb ON mb.ROWID = m.mailbox
        LEFT JOIN addresses a ON a.ROWID = m.sender
        """

    public func indexCandidates(after rowID: Int64, limit: Int) throws -> [IndexCandidate] {
        try withDB { db in
            try db.all(
                "\(Self.candidateSQL) WHERE m.ROWID > ? AND m.deleted = 0 ORDER BY m.ROWID LIMIT ?",
                [.int(rowID), .int(Int64(limit))], Self.candidate)
        }
    }

    public func indexCandidates(ids: [Int64]) throws -> [IndexCandidate] {
        let json = "[" + ids.map(String.init).joined(separator: ",") + "]"
        return try withDB { db in
            try db.all(
                "\(Self.candidateSQL) WHERE m.ROWID IN (SELECT value FROM json_each(?)) AND m.deleted = 0",
                [.text(json)], Self.candidate)
        }
    }

    private static func candidate(_ row: SQLiteConnection.Row) -> IndexCandidate {
        IndexCandidate(
            id: row.int(0), mailboxURL: MailboxURL(row.string(1)), subject: row.string(2),
            sender: row.string(3).trimmingCharacters(in: .whitespaces))
    }
}
