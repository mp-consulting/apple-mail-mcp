import Foundation
import MailStore

/// A message to put into a ``FixtureMailStore``.
public struct FixtureMessage: Sendable {
    public var subject: String
    public var from: EmailAddress
    public var to: [EmailAddress]
    public var cc: [EmailAddress] = []
    public var date: Date
    public var mailbox: Int64
    public var body: String
    public var html: String?
    public var attachments: [(name: String, mimeType: String, data: Data)] = []
    public var isRead = false
    public var flagColor: FlagColor?
    public var messageID: String?
    public var inReplyTo: String?
    public var conversationID: Int64?
    public var isList = false
    public var hasUnsubscribe = false
    public var category: MailCategory?
    /// Write a `.partial.emlx` with attachments stored in the Attachments folder.
    public var partial = false
    /// Do not write any file (body not downloaded yet).
    public var withoutFile = false
    public var labels: [Int64] = []
    public var deleted = false
    public var charset = "utf-8"
    /// Raw header lines added as they are, e.g. `Authentication-Results: …` or `List-Unsubscribe: …`.
    public var extraHeaders: [String] = []

    public init(
        subject: String, from: EmailAddress, to: [EmailAddress], date: Date, mailbox: Int64, body: String,
        html: String? = nil
    ) {
        self.subject = subject
        self.from = from
        self.to = to
        self.date = date
        self.mailbox = mailbox
        self.body = body
        self.html = html
    }
}

/// Builds a throwaway Mail data tree (`Envelope Index` + `.emlx` files +
/// `Accounts4.sqlite`) that mirrors the layout and schema of macOS Mail V10.
public final class FixtureMailStore: @unchecked Sendable {
    public let directory: URL
    public let root: URL
    public let accountsDatabase: URL
    public let storeUUID = "11111111-2222-3333-4444-555555555555"
    let db: SQLiteConnection
    let accounts: SQLiteConnection
    private var accountPK: Int64 = 0
    private var conversationCounter: Int64 = 1000

    public var location: MailLocation { MailLocation(root: root, accountsDatabase: accountsDatabase) }

    public init(directory: URL? = nil) throws {
        let base = directory ?? FileManager.default.temporaryDirectory.appending(path: "mail-fixture-\(UUID().uuidString)")
        self.directory = base
        root = base.appending(path: "Mail/V10")
        try FileManager.default.createDirectory(at: root.appending(path: "MailData"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: base.appending(path: "Accounts"), withIntermediateDirectories: true)
        accountsDatabase = base.appending(path: "Accounts/Accounts4.sqlite")
        db = try SQLiteConnection(path: root.appending(path: "MailData/Envelope Index").path, readOnly: false, create: true)
        accounts = try SQLiteConnection(path: accountsDatabase.path, readOnly: false, create: true)
        try db.execute("PRAGMA journal_mode = WAL")
        try db.execute(Self.schema)
        try db.run("INSERT INTO properties (key, value) VALUES ('UUID', ?)", [.text(storeUUID)])
        try accounts.execute(
            """
            CREATE TABLE ZACCOUNT (Z_PK INTEGER PRIMARY KEY, ZIDENTIFIER VARCHAR, ZACCOUNTDESCRIPTION VARCHAR,
                ZPARENTACCOUNT INTEGER, ZUSERNAME VARCHAR);
            """)
    }

    public func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The subset of Mail's schema the server reads, with the same names and types.
    static let schema = """
        CREATE TABLE properties (ROWID INTEGER PRIMARY KEY, key, value, UNIQUE (key));
        CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, subject TEXT COLLATE RTRIM NOT NULL, UNIQUE(subject));
        CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, address TEXT COLLATE NOCASE NOT NULL,
            comment TEXT COLLATE BINARY NOT NULL, UNIQUE(address, comment));
        CREATE TABLE summaries (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, summary TEXT COLLATE RTRIM NOT NULL, UNIQUE(summary));
        CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, url TEXT COLLATE BINARY NOT NULL,
            total_count INTEGER NOT NULL DEFAULT 0, unread_count INTEGER NOT NULL DEFAULT 0,
            deleted_count INTEGER NOT NULL DEFAULT 0, unseen_count INTEGER NOT NULL DEFAULT 0,
            unread_count_adjusted_for_duplicates INTEGER NOT NULL DEFAULT 0, change_identifier TEXT,
            source INTEGER, alleged_change_identifier TEXT, UNIQUE(url));
        CREATE TABLE message_global_data (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, message_id INTEGER,
            model_category INTEGER, message_id_header TEXT COLLATE BINARY, UNIQUE(message_id));
        CREATE TABLE messages (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, message_id INTEGER NOT NULL DEFAULT 0,
            global_message_id INTEGER NOT NULL, remote_id INTEGER, document_id TEXT, sender INTEGER,
            subject_prefix TEXT, subject INTEGER NOT NULL, summary INTEGER, date_sent INTEGER, date_received INTEGER,
            mailbox INTEGER NOT NULL, remote_mailbox INTEGER, flags INTEGER NOT NULL DEFAULT 0,
            read INTEGER NOT NULL DEFAULT 0, flagged INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0,
            size INTEGER NOT NULL DEFAULT 0, conversation_id INTEGER NOT NULL DEFAULT 0, date_last_viewed INTEGER,
            list_id_hash INTEGER, searchable_message INTEGER, color TEXT, type INTEGER, fuzzy_ancestor INTEGER,
            automated_conversation INTEGER DEFAULT 0, root_status INTEGER DEFAULT -1, unsubscribe_type INTEGER,
            brand_indicator INTEGER, display_date INTEGER, flag_color INTEGER, is_urgent INTEGER NOT NULL DEFAULT 0);
        CREATE INDEX messages_mailbox_date_received_index ON messages(mailbox, date_received);
        CREATE INDEX messages_deleted_date_received_index ON messages(deleted, date_received);
        CREATE INDEX messages_conversation_id_index ON messages(conversation_id);
        CREATE INDEX messages_sender_index ON messages(sender);
        CREATE TABLE recipients (ROWID INTEGER PRIMARY KEY, message INTEGER NOT NULL, address INTEGER NOT NULL,
            type INTEGER, position INTEGER, UNIQUE(message, type, position));
        CREATE INDEX recipients_message_index ON recipients(message);
        CREATE TABLE attachments (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, message INTEGER NOT NULL,
            attachment_id TEXT, name TEXT, UNIQUE(message, attachment_id));
        CREATE TABLE labels (message_id INTEGER, mailbox_id INTEGER, PRIMARY KEY(message_id, mailbox_id)) WITHOUT ROWID;
        """

    // MARK: Accounts and mailboxes

    /// Registers an account in the Accounts database. `parentName` mimics iCloud's child mail account.
    public func addAccount(id: String, description: String?, parentName: String? = nil, username: String? = nil) throws {
        var parentPK: SQLValue = .null
        if let parentName {
            accountPK += 1
            try accounts.run(
                "INSERT INTO ZACCOUNT (Z_PK, ZIDENTIFIER, ZACCOUNTDESCRIPTION) VALUES (?, ?, ?)",
                [.int(accountPK), .text(UUID().uuidString), .text(parentName)])
            parentPK = .int(accountPK)
        }
        accountPK += 1
        try accounts.run(
            "INSERT INTO ZACCOUNT (Z_PK, ZIDENTIFIER, ZACCOUNTDESCRIPTION, ZPARENTACCOUNT, ZUSERNAME) VALUES (?, ?, ?, ?, ?)",
            [.int(accountPK), .text(id), description.map(SQLValue.text) ?? .null, parentPK, username.map(SQLValue.text) ?? .null])
    }

    /// Adds a mailbox; `path` components are percent-encoded like Mail does (decomposed Unicode).
    @discardableResult
    public func addMailbox(accountID: String, path: String, scheme: String = "imap", source: Int64? = nil) throws -> Int64 {
        try db.run(
            "INSERT INTO mailboxes (url, source) VALUES (?, ?)",
            [.text(Self.mailboxURL(scheme: scheme, accountID: accountID, path: path)), source.map(SQLValue.int) ?? .null])
        let id = try db.scalarInt("SELECT last_insert_rowid()") ?? 0
        let directory = root.appending(path: ([accountID] + path.split(separator: "/").map { $0 + ".mbox" }).joined(separator: "/"))
            .appending(path: storeUUID).appending(path: "Data")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return id
    }

    /// Points a mailbox row at a new path, keeping its ROWID and counts.
    public func renameMailbox(_ id: Int64, to path: String) throws {
        let (url, _) = try mailboxInfo(id)
        try db.run(
            "UPDATE mailboxes SET url = ? WHERE ROWID = ?",
            [.text(Self.mailboxURL(scheme: url.scheme, accountID: url.accountID, path: path)), .int(id)])
    }

    /// A mailbox URL as Mail writes it: each path component percent-encoded, decomposed.
    private static func mailboxURL(scheme: String, accountID: String, path: String) -> String {
        let encoded = path.decomposedStringWithCanonicalMapping.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? String($0)
        }.joined(separator: "/")
        return "\(scheme)://\(accountID)/\(encoded)"
    }

    /// Removes a mailbox row, as Mail does when the server refuses a mailbox it just created.
    public func removeMailbox(_ id: Int64) throws {
        try db.run("DELETE FROM mailboxes WHERE ROWID = ?", [.int(id)])
    }

    private func mailboxInfo(_ id: Int64) throws -> (url: MailboxURL, isLabel: Bool) {
        guard let (url, source) = try db.first("SELECT url, source FROM mailboxes WHERE ROWID = ?", [.int(id)], { ($0.string(0), $0.optionalInt(1)) }),
              let parsed = MailboxURL(url)
        else { throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "no mailbox \(id)"]) }
        return (parsed, source != nil)
    }

    private func intern(_ table: String, _ column: String, _ value: String) throws -> Int64 {
        if let id = try db.scalarInt("SELECT ROWID FROM \(table) WHERE \(column) = ?", [.text(value)]) { return id }
        try db.run("INSERT INTO \(table) (\(column)) VALUES (?)", [.text(value)])
        return try db.scalarInt("SELECT last_insert_rowid()") ?? 0
    }

    private func address(_ address: EmailAddress) throws -> Int64 {
        if let id = try db.scalarInt(
            "SELECT ROWID FROM addresses WHERE address = ? AND comment = ?", [.text(address.address), .text(address.name ?? "")])
        {
            return id
        }
        try db.run("INSERT INTO addresses (address, comment) VALUES (?, ?)", [.text(address.address), .text(address.name ?? "")])
        return try db.scalarInt("SELECT last_insert_rowid()") ?? 0
    }

    /// Recomputes mailbox total/unread counts, as Mail's triggers would.
    public func refreshCounts() throws {
        try db.execute(
            """
            UPDATE mailboxes SET
              total_count = (SELECT COUNT(*) FROM messages m WHERE m.deleted = 0 AND (m.mailbox = mailboxes.ROWID
                OR m.ROWID IN (SELECT message_id FROM labels WHERE mailbox_id = mailboxes.ROWID))),
              unread_count = (SELECT COUNT(*) FROM messages m WHERE m.deleted = 0 AND m.read = 0 AND (m.mailbox = mailboxes.ROWID
                OR m.ROWID IN (SELECT message_id FROM labels WHERE mailbox_id = mailboxes.ROWID)));
            """)
    }

    /// Writes a settings file into `MailData` (rules, VIPs, smart mailboxes, signatures), as Mail does.
    public func writeMailData(_ name: String, plist: Any) throws {
        let url = root.appending(path: "MailData").appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: url)
    }

    public func writeMailData(_ name: String, data: Data) throws {
        let url = root.appending(path: "MailData").appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    // MARK: Messages

    @discardableResult
    public func addMessage(_ message: FixtureMessage) throws -> Int64 {
        let messageID = message.messageID ?? "\(UUID().uuidString)@fixture.test"
        let subject = message.subject
        var prefix = ""
        var bare = subject
        for candidate in ["Re: ", "RE: ", "Fwd: ", "Fw: "] where bare.hasPrefix(candidate) {
            prefix = candidate
            bare = String(bare.dropFirst(candidate.count))
        }
        let subjectID = try intern("subjects", "subject", bare)
        let summaryText = String(message.body.replacingOccurrences(of: "\n", with: " ").prefix(150))
        let summaryID = summaryText.isEmpty ? nil : try intern("summaries", "summary", summaryText)
        let senderID = try address(message.from)
        let hash = Int64(truncatingIfNeeded: messageID.hashValue & 0x7FFF_FFFF_FFFF)
        // Copies of one message (e.g. after a move) share a global row, as in Mail.
        try db.run(
            "INSERT OR IGNORE INTO message_global_data (message_id, model_category, message_id_header) VALUES (?, ?, ?)",
            [.int(hash), message.category.map { .int(Int64($0.rawValue)) } ?? .null, .text("<\(messageID)>")])
        let globalID = try db.scalarInt("SELECT ROWID FROM message_global_data WHERE message_id = ?", [.int(hash)]) ?? 0
        let conversation: Int64
        if let id = message.conversationID {
            conversation = id
        } else {
            conversationCounter += 1
            conversation = conversationCounter
        }
        var flags: Int64 = message.isRead ? 1 : 0
        if let color = message.flagColor { flags |= 1 << 4 | Int64(color.rawValue) << 39 } else { flags |= 6 << 39 }
        let date = Int64(message.date.timeIntervalSince1970)
        try db.run(
            """
            INSERT INTO messages (message_id, global_message_id, sender, subject_prefix, subject, summary, date_sent,
                date_received, mailbox, flags, read, flagged, deleted, size, conversation_id, list_id_hash,
                unsubscribe_type, flag_color)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .int(hash), .int(globalID), .int(senderID), prefix.isEmpty ? .null : .text(prefix), .int(subjectID),
                summaryID.map(SQLValue.int) ?? .null, .int(date), .int(date), .int(message.mailbox), .int(flags),
                .int(message.isRead ? 1 : 0), .int(message.flagColor == nil ? 0 : 1), .int(message.deleted ? 1 : 0),
                .int(Int64(message.body.utf8.count)), .int(conversation), .int(message.isList ? 987_654 : 0),
                .int(message.hasUnsubscribe ? 6 : 0), .int(message.flagColor == nil ? 0 : 1),
            ])
        let rowID = try db.scalarInt("SELECT last_insert_rowid()") ?? 0
        for (position, recipient) in message.to.enumerated() {
            try db.run("INSERT INTO recipients (message, address, type, position) VALUES (?, ?, 0, ?)", [.int(rowID), .int(try address(recipient)), .int(Int64(position))])
        }
        for (position, recipient) in message.cc.enumerated() {
            try db.run("INSERT INTO recipients (message, address, type, position) VALUES (?, ?, 1, ?)", [.int(rowID), .int(try address(recipient)), .int(Int64(position))])
        }
        for label in message.labels {
            try db.run("INSERT INTO labels (message_id, mailbox_id) VALUES (?, ?)", [.int(rowID), .int(label)])
        }
        let (rfc822, partIDs) = Self.rfc822(message, messageID: messageID, stripAttachments: message.partial)
        for (index, attachment) in message.attachments.enumerated() {
            try db.run(
                "INSERT INTO attachments (message, attachment_id, name) VALUES (?, ?, ?)",
                [.int(rowID), .text(partIDs[index]), .text(attachment.name)])
        }
        if !message.withoutFile {
            try writeFiles(rowID: rowID, mailbox: message.mailbox, rfc822: rfc822, message: message, partIDs: partIDs)
        }
        return rowID
    }

    /// Moves a message the way Mail records it: a new row (new ROWID, same global data) in `mailbox`,
    /// and the old row marked deleted. Recipients and files stay with the old row.
    @discardableResult
    public func moveMessage(_ rowID: Int64, to mailbox: Int64) throws -> Int64 {
        let columns = """
            message_id, global_message_id, sender, subject_prefix, subject, summary, date_sent, date_received, flags,
            read, flagged, size, conversation_id, list_id_hash, unsubscribe_type, flag_color
            """
        try db.run("INSERT INTO messages (\(columns), mailbox) SELECT \(columns), ? FROM messages WHERE ROWID = ?", [.int(mailbox), .int(rowID)])
        let newID = try db.scalarInt("SELECT last_insert_rowid()") ?? 0
        try db.run("UPDATE messages SET deleted = 1 WHERE ROWID = ?", [.int(rowID)])
        return newID
    }

    /// Writes (or rewrites) the `.emlx` for an existing message, e.g. once it has "downloaded".
    public func writeEmlx(rowID: Int64, mailbox: Int64, message: FixtureMessage) throws {
        let (rfc822, partIDs) = Self.rfc822(message, messageID: message.messageID ?? "late-\(rowID)@fixture.test", stripAttachments: message.partial)
        try writeFiles(rowID: rowID, mailbox: mailbox, rfc822: rfc822, message: message, partIDs: partIDs)
    }

    private func writeFiles(rowID: Int64, mailbox: Int64, rfc822: Data, message: FixtureMessage, partIDs: [String]) throws {
        let (url, _) = try mailboxInfo(mailbox)
        let data = root.appending(path: url.relativeDirectory).appending(path: storeUUID)
            .appending(path: MessageFileLocator.dataSubpath(forRowID: rowID))
        let messages = data.appending(path: "Messages")
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
        var file = Data("\(rfc822.count)\n".utf8)
        file.append(rfc822)
        file.append(Data(Self.plist.utf8))
        let name = message.partial ? "\(rowID).partial.emlx" : "\(rowID).emlx"
        try file.write(to: messages.appending(path: name))
        if message.partial {
            for (index, attachment) in message.attachments.enumerated() {
                let folder = data.appending(path: "Attachments/\(rowID)/\(partIDs[index])")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try attachment.data.write(to: folder.appending(path: attachment.name))
            }
        }
    }

    static let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>flags</key><integer>8590195713</integer></dict></plist>
        """

    static func formatAddress(_ address: EmailAddress) -> String {
        guard let name = address.name else { return address.address }
        let needsQuotes = name.contains(",") || name.contains("\"")
        return needsQuotes ? "\"\(name.replacingOccurrences(of: "\"", with: "\\\""))\" <\(address.address)>" : "\(name) <\(address.address)>"
    }

    /// Builds RFC 822 bytes; returns the IMAP part ids of the attachments.
    static func rfc822(_ message: FixtureMessage, messageID: String, stripAttachments: Bool) -> (Data, [String]) {
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        var headers = [
            "From: \(formatAddress(message.from))",
            "To: \(message.to.map(formatAddress).joined(separator: ", "))",
            "Subject: =?utf-8?B?\(Data(message.subject.utf8).base64EncodedString())?=",
            "Date: \(date.string(from: message.date))",
            "Message-ID: <\(messageID)>",
            "MIME-Version: 1.0",
        ]
        if !message.cc.isEmpty { headers.append("Cc: \(message.cc.map(formatAddress).joined(separator: ", "))") }
        if let reply = message.inReplyTo { headers.append("In-Reply-To: <\(reply)>") }
        if message.isList { headers.append("List-Id: <news.fixture.test>") }
        headers += message.extraHeaders

        func textPart(_ text: String, type: String) -> String {
            let encoding = message.charset.lowercased() == "utf-8" ? String.Encoding.utf8 : MIME.stringEncoding(forCharset: message.charset) ?? .utf8
            let bytes = text.data(using: encoding) ?? Data(text.utf8)
            return "Content-Type: \(type); charset=\(message.charset)\r\nContent-Transfer-Encoding: base64\r\n\r\n"
                + bytes.base64EncodedString(options: .lineLength76Characters) + "\r\n"
        }

        var bodyPart: String
        if let html = message.html {
            let boundary = "alt-\(UUID().uuidString)"
            bodyPart = "Content-Type: multipart/alternative; boundary=\"\(boundary)\"\r\n\r\n"
            if !message.body.isEmpty { bodyPart += "--\(boundary)\r\n" + textPart(message.body, type: "text/plain") }
            bodyPart += "--\(boundary)\r\n" + textPart(html, type: "text/html") + "--\(boundary)--\r\n"
        } else {
            bodyPart = textPart(message.body, type: "text/plain")
        }

        var partIDs: [String] = []
        let text: String
        if message.attachments.isEmpty {
            text = headers.joined(separator: "\r\n") + "\r\n" + bodyPart
        } else {
            let boundary = "mixed-\(UUID().uuidString)"
            headers.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
            var body = "--\(boundary)\r\n" + bodyPart
            for (index, attachment) in message.attachments.enumerated() {
                partIDs.append("\(index + 2)")
                body += "--\(boundary)\r\nContent-Type: \(attachment.mimeType); name=\"\(attachment.name)\"\r\n"
                body += "Content-Disposition: attachment; filename=\"\(attachment.name)\"\r\n"
                if stripAttachments {
                    body += "X-Apple-Content-Length: \(attachment.data.count)\r\nContent-Transfer-Encoding: base64\r\n\r\n\r\n"
                } else {
                    body += "Content-Transfer-Encoding: base64\r\n\r\n" + attachment.data.base64EncodedString(options: .lineLength76Characters) + "\r\n"
                }
            }
            body += "--\(boundary)--\r\n"
            text = headers.joined(separator: "\r\n") + "\r\n\r\n" + body
        }
        // Single-part messages carry their own Content-Type header inside `bodyPart`.
        return (Data(text.utf8), partIDs)
    }
}
