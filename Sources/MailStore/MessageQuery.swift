import Foundation

/// Filters for ``MailStore/search(_:bodyIndex:)``. Every field is optional; an
/// empty query lists the most recent messages outside Trash and Junk.
public struct MessageQuery: Sendable, Hashable {
    /// Free text matched against subject, sender and Mail's preview snippet.
    public var text: String?
    /// More free-text alternatives: a message matches when `text` or any of these matches.
    public var textTerms: [String] = []
    /// Leave out messages whose subject contains any of these.
    public var excludeSubjectTerms: [String] = []
    /// Leave out messages whose sender address or name contains any of these.
    public var excludeSenders: [String] = []
    /// Leave out messages from exactly these addresses (case-insensitive).
    public var excludeSenderAddresses: [String] = []
    /// Received mail only, sent mail only, or both.
    public var direction: MessageDirection = .any
    /// Leave out replies (`Re:`, `AW:`, `SV:`… subjects).
    public var excludeReplies = false
    /// Any of these must appear in the subject.
    public var subjectTerms: [String] = []
    /// Substring of the sender address or display name.
    public var sender: String?
    /// Substring of any To/Cc/Bcc address or display name.
    public var recipient: String?
    /// Words that must appear in the body (full-text index, else a bounded file scan).
    public var bodyText: String?
    public var accountIDs: [String] = []
    /// Explicit mailbox ROWIDs; empty means every mailbox (minus Trash/Junk unless included).
    public var mailboxIDs: [Int64] = []
    public var includeTrashAndJunk = false
    public var dateFrom: Date?
    public var dateTo: Date?
    public var isRead: Bool?
    public var isFlagged: Bool?
    public var flagColor: FlagColor?
    public var hasAttachments: Bool?
    public var conversationID: Int64?
    /// Mail's on-device categories to include (ignored on Mail versions without categories).
    public var categories: [MailCategory] = []
    public var ids: [Int64] = []
    public var sortAscending = false
    public var limit = 25
    public var offset = 0
    /// Cap on `.emlx` files read when body text is not covered by the index.
    public var bodyScanBudget = 3000

    public init() {}
}

/// Which way a message went, judged by mailbox role and the user's own addresses.
public enum MessageDirection: String, Sendable, Hashable, CaseIterable {
    /// Everything.
    case any
    /// Not in Sent, Drafts or Outbox, and not from one of the user's addresses.
    case received
    /// In Sent, or from one of the user's addresses (never Drafts or Outbox).
    case sent
}

/// Every match of a query, without paging (for exports and grouping).
public struct MatchResult: Sendable {
    /// Matching ROWIDs in the query's sort order.
    public var ids: [Int64]
    /// False when a body scan hit its budget or the cap stopped the list early.
    public var complete: Bool
    public var bodySearchMode: String?
    public var scannedMessages: Int
}

/// Message counts per sender, sender domain or month.
public struct GroupCount: Sendable, Hashable {
    public var key: String
    /// Display name, for sender groups.
    public var name: String?
    public var count: Int
    public var unread: Int
}

public enum GroupKey: String, Sendable, CaseIterable {
    case sender, domain, month
}

public struct SearchPage: Sendable {
    public var messages: [MessageSummary]
    /// Number of matches across all pages; nil when a body scan stopped early.
    public var total: Int?
    public var offset: Int
    public var limit: Int
    public var hasMore: Bool
    /// How body text was matched: `index`, `scan`, `index+scan`, or nil when not requested.
    public var bodySearchMode: String?
    /// True when the body scan hit its budget before checking every candidate.
    public var scanLimited: Bool
    public var scannedMessages: Int
}
