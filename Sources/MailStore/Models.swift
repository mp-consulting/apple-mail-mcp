import Foundation

/// A Mail account as seen on disk.
public struct MailAccount: Codable, Sendable, Hashable {
    /// Account UUID; also the account's AppleScript `id` and its folder name in `~/Library/Mail/V10`.
    public var id: String
    public var name: String
    /// `imap`, `local`, `ews`, `pop`, …: the scheme of the account's mailbox URLs.
    public var kind: String
    /// Addresses the account sends from, when known.
    public var emailAddresses: [String]

    public init(id: String, name: String, kind: String, emailAddresses: [String] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.emailAddresses = emailAddresses
    }
}

/// Well-known mailbox roles, detected from mailbox names in several languages.
public enum MailboxRole: String, Codable, Sendable, CaseIterable {
    case inbox, sent, drafts, trash, junk, archive, outbox, allMail = "all_mail", other
}

public struct Mailbox: Codable, Sendable, Hashable {
    public var id: Int64
    public var url: String
    public var accountID: String
    /// Decoded path below the account, e.g. `Archive/2020` or `[Gmail]/Sent Mail`.
    public var path: String
    public var name: String
    public var role: MailboxRole
    public var totalCount: Int
    public var unreadCount: Int
    /// Non-nil for label-style mailboxes (Gmail): messages live in `source` and are tagged via `labels`.
    public var sourceMailboxID: Int64?

    public init(
        id: Int64, url: String, accountID: String, path: String, name: String, role: MailboxRole,
        totalCount: Int, unreadCount: Int, sourceMailboxID: Int64?
    ) {
        self.id = id
        self.url = url
        self.accountID = accountID
        self.path = path
        self.name = name
        self.role = role
        self.totalCount = totalCount
        self.unreadCount = unreadCount
        self.sourceMailboxID = sourceMailboxID
    }
}

public struct EmailAddress: Codable, Sendable, Hashable {
    public var address: String
    public var name: String?

    public init(address: String, name: String? = nil) {
        self.address = address
        self.name = (name?.isEmpty ?? true) ? nil : name
    }

    /// `Name <address>` or just the address.
    public var formatted: String {
        guard let name else { return address }
        return "\(name) <\(address)>"
    }

    public var domain: String {
        guard let at = address.lastIndex(of: "@") else { return "" }
        return String(address[address.index(after: at)...]).lowercased()
    }
}

/// Apple Mail's seven scriptable flag colours, indexed as Mail stores them.
public enum FlagColor: Int, Codable, Sendable, CaseIterable {
    case red = 0, orange, yellow, green, blue, purple, gray

    public var name: String { String(describing: self) }

    public init?(name: String) {
        let normalized = name.lowercased() == "grey" ? "gray" : name.lowercased()
        guard let match = FlagColor.allCases.first(where: { $0.name == normalized }) else { return nil }
        self = match
    }
}

/// Mail's on-device categories, as stored in `message_global_data.model_category`.
public enum MailCategory: Int, Codable, Sendable, CaseIterable {
    case primary = 0, transactions, updates, promotions

    public var name: String { String(describing: self) }

    public init?(name: String) {
        guard let match = MailCategory.allCases.first(where: { $0.name == name.lowercased() }) else { return nil }
        self = match
    }
}

/// Envelope data for one message, read from the Envelope Index without touching Mail.
public struct MessageSummary: Codable, Sendable, Hashable {
    /// Mail's ROWID. Identical to the AppleScript `id` of the message.
    public var id: Int64
    public var subject: String
    public var sender: EmailAddress
    public var dateReceived: Date
    public var dateSent: Date?
    public var mailboxID: Int64
    public var mailboxPath: String
    public var accountID: String
    public var accountName: String
    public var isRead: Bool
    public var isFlagged: Bool
    public var flagColor: FlagColor?
    public var size: Int
    public var conversationID: Int64
    public var hasAttachments: Bool
    /// Mail's own snippet of the body, when it has computed one.
    public var preview: String?
    /// RFC 822 `Message-ID` header without angle brackets, when Mail recorded it.
    public var messageIDHeader: String?
    /// Mail's on-device category (macOS 15+), when it has classified the message.
    public var category: MailCategory?

    /// `message://` link that opens the message in Mail.
    public var mailLink: String? {
        guard let messageIDHeader, !messageIDHeader.isEmpty else { return nil }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "<>/?#%")
        let encoded = messageIDHeader.addingPercentEncoding(withAllowedCharacters: allowed) ?? messageIDHeader
        return "message://%3C\(encoded)%3E"
    }
}

/// A fully parsed message: envelope plus content from the `.emlx` file.
public struct MessageDetail: Sendable {
    public var summary: MessageSummary
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var replyTo: [EmailAddress]
    public var headers: [(name: String, value: String)]
    public var textBody: String?
    public var htmlBody: String?
    public var attachments: [AttachmentInfo]
    /// False when Mail has not downloaded the body yet (no `.emlx` on disk).
    public var bodyAvailable: Bool
}

public struct AttachmentInfo: Codable, Sendable, Hashable {
    /// IMAP-style MIME part number, e.g. `2` or `1.3`. Stable handle for saving.
    public var partID: String
    public var filename: String
    public var mimeType: String
    /// Decoded size in bytes when known.
    public var size: Int?
    /// True when the bytes are on disk (inline in the `.emlx` or in Mail's Attachments folder).
    public var isDownloaded: Bool
}
