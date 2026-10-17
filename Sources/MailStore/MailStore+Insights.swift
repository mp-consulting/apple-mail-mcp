import Foundation

public struct SenderCount: Codable, Sendable, Hashable {
    public var key: String
    public var name: String?
    public var count: Int
    public var unread: Int
}

public struct MailStatistics: Codable, Sendable {
    public var from: Date
    public var to: Date
    public var received: Int
    public var unread: Int
    public var flagged: Int
    public var withAttachments: Int
    public var sentByMe: Int
    public var perDay: [String: Int]
    public var perWeekday: [String: Int]
    public var perHour: [Int: Int]
    public var topSenders: [SenderCount]
    public var topDomains: [SenderCount]
    public var categories: [String: Int]
}

extension MailStore {
    private func scopeQuery(accountID: String?, mailboxIDs: [Int64], days: Int?) -> MessageQuery {
        var query = MessageQuery()
        if let accountID { query.accountIDs = [accountID] }
        query.mailboxIDs = mailboxIDs
        if let days, days > 0 { query.dateFrom = Date().addingTimeInterval(-Double(days) * 86_400) }
        return query
    }

    /// Most frequent senders (or sender domains) in a scope, excluding the user's own addresses.
    public func topSenders(
        accountID: String? = nil, mailboxIDs: [Int64] = [], days: Int? = 30, byDomain: Bool = false, limit: Int = 10
    ) throws -> [SenderCount] {
        let own = try ownAddresses()
        let query = scopeQuery(accountID: accountID, mailboxIDs: mailboxIDs, days: days)
        let key = byDomain ? "lower(substr(a.address, instr(a.address, '@') + 1))" : "lower(a.address)"
        let (whereSQL, bindings) = whereClause(for: query, mailboxes: try lookupTables().0)
        let ownJSON = Self.jsonArray(own.sorted())
        return try withDB { db in
            try db.all(
                """
                SELECT \(key) AS k, MAX(a.comment), COUNT(*) AS n, SUM(m.read = 0)
                \(Self.summaryJoins) WHERE \(whereSQL) AND lower(a.address) NOT IN (SELECT value FROM json_each(?))
                GROUP BY k ORDER BY n DESC LIMIT ?
                """, bindings + [.text(ownJSON), .int(Int64(max(1, min(limit, 200))))]
            ) { row in
                let name = row.optionalString(1)
                return SenderCount(
                    key: row.string(0), name: byDomain || (name?.isEmpty ?? true) ? nil : name,
                    count: Int(row.int(2)), unread: Int(row.int(3)))
            }
        }
    }

    public func statistics(accountID: String? = nil, mailboxIDs: [Int64] = [], days: Int = 30) throws -> MailStatistics {
        let query = scopeQuery(accountID: accountID, mailboxIDs: mailboxIDs, days: days)
        let (whereSQL, bindings) = whereClause(for: query, mailboxes: try lookupTables().0)
        let own = try ownAddresses()
        let ownJSON = Self.jsonArray(own.sorted())
        let base = "\(Self.summaryJoins) WHERE \(whereSQL)"

        var received = 0, unread = 0, flagged = 0, attachments = 0, sent = 0
        var perDay: [String: Int] = [:]
        var perWeekday: [String: Int] = [:]
        var perHour: [Int: Int] = [:]
        var categories: [String: Int] = [:]
        let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        try withDB { db in
            try db.query(
                """
                SELECT COUNT(*), SUM(m.read = 0), SUM(m.flagged != 0),
                SUM(EXISTS(SELECT 1 FROM attachments t WHERE t.message = m.ROWID)),
                SUM(lower(a.address) IN (SELECT value FROM json_each(?))) \(base)
                """, [.text(ownJSON)] + bindings
            ) { row in
                received = Int(row.int(0))
                unread = Int(row.int(1))
                flagged = Int(row.int(2))
                attachments = Int(row.int(3))
                sent = Int(row.int(4))
            }
            try db.query(
                """
                SELECT date(m.date_received, 'unixepoch', 'localtime') AS d,
                CAST(strftime('%w', m.date_received, 'unixepoch', 'localtime') AS INTEGER),
                CAST(strftime('%H', m.date_received, 'unixepoch', 'localtime') AS INTEGER) \(base)
                """, bindings
            ) { row in
                perDay[row.string(0), default: 0] += 1
                perWeekday[weekdays[Int(row.int(1)) % 7], default: 0] += 1
                perHour[Int(row.int(2)), default: 0] += 1
            }
            if hasCategories {
                try db.query("SELECT IFNULL(g.model_category, 0), COUNT(*) \(base) GROUP BY 1", bindings) { row in
                    let name = MailCategory(rawValue: Int(row.int(0)))?.name ?? "other"
                    categories[name, default: 0] += Int(row.int(1))
                }
            }
        }
        return MailStatistics(
            from: query.dateFrom ?? .distantPast, to: Date(), received: received, unread: unread, flagged: flagged,
            withAttachments: attachments, sentByMe: sent, perDay: perDay, perWeekday: perWeekday, perHour: perHour,
            topSenders: try topSenders(accountID: accountID, mailboxIDs: mailboxIDs, days: days, limit: 10),
            topDomains: try topSenders(accountID: accountID, mailboxIDs: mailboxIDs, days: days, byDomain: true, limit: 10),
            categories: categories)
    }

    /// Messages the user sent in the last `days` that have no later reply from
    /// someone else in the same conversation. Only the latest sent message of
    /// each conversation is returned.
    public func awaitingReply(days: Int = 14, minimumAgeHours: Int = 24, accountID: String? = nil, limit: Int = 25) throws -> [MessageSummary] {
        let own = try ownAddresses()
        guard !own.isEmpty else { return [] }
        let ownJSON = Self.jsonArray(own.sorted())
        var query = scopeQuery(accountID: accountID, mailboxIDs: [], days: days)
        query.dateTo = Date().addingTimeInterval(-Double(minimumAgeHours) * 3600)
        let (whereSQL, bindings) = whereClause(for: query, mailboxes: try lookupTables().0)
        let ids = try withDB { db in
            try db.all(
                """
                SELECT m.ROWID \(Self.summaryJoins)
                WHERE \(whereSQL) AND lower(a.address) IN (SELECT value FROM json_each(:own))
                AND NOT EXISTS (
                    SELECT 1 FROM messages r JOIN addresses ra ON ra.ROWID = r.sender
                    WHERE r.conversation_id = m.conversation_id AND r.deleted = 0 AND r.date_received > m.date_received
                    AND lower(ra.address) NOT IN (SELECT value FROM json_each(:own)))
                AND NOT EXISTS (
                    SELECT 1 FROM messages later JOIN addresses la ON la.ROWID = later.sender
                    WHERE later.conversation_id = m.conversation_id AND later.deleted = 0
                    AND later.date_received > m.date_received AND lower(la.address) IN (SELECT value FROM json_each(:own)))
                AND EXISTS (
                    SELECT 1 FROM recipients rc JOIN addresses rca ON rca.ROWID = rc.address
                    WHERE rc.message = m.ROWID AND lower(rca.address) NOT IN (SELECT value FROM json_each(:own)))
                ORDER BY m.date_received DESC
                """, bindings + [.text(ownJSON)]
            ) { $0.int(0) }
        }
        return Array(deduplicatedByConversation(try messages(ids: ids)).prefix(limit))
    }

    /// Recent messages from other people that the user has not answered:
    /// the conversation's latest message is not from the user, the user is a
    /// direct (To) recipient, and it is not a list, newsletter, promotion or update.
    public func needsResponse(days: Int = 7, accountID: String? = nil, includeRead: Bool = true, limit: Int = 25) throws -> [MessageSummary] {
        let own = try ownAddresses()
        let ownJSON = Self.jsonArray(own.sorted())
        var query = scopeQuery(accountID: accountID, mailboxIDs: [], days: days)
        let inboxes = try mailboxes(accountID: accountID).filter { $0.role == .inbox }.map(\.id)
        query.mailboxIDs = inboxes
        if !includeRead { query.isRead = false }
        if hasCategories { query.categories = [.primary] }
        let (whereSQL, bindings) = whereClause(for: query, mailboxes: try lookupTables().0)
        let directClause = own.isEmpty
            ? ""
            : """
            AND EXISTS (SELECT 1 FROM recipients rc JOIN addresses rca ON rca.ROWID = rc.address
                WHERE rc.message = m.ROWID AND rc.type = 0 AND lower(rca.address) IN (SELECT value FROM json_each(:own)))
            """
        let ids = try withDB { db in
            try db.all(
                """
                SELECT m.ROWID \(Self.summaryJoins)
                WHERE \(whereSQL) AND lower(a.address) NOT IN (SELECT value FROM json_each(:own))
                AND IFNULL(m.list_id_hash, 0) = 0 AND IFNULL(m.unsubscribe_type, 0) = 0
                AND lower(a.address) NOT GLOB '*no-reply*' AND lower(a.address) NOT GLOB '*noreply*'
                AND lower(a.address) NOT GLOB '*do-not-reply*' AND lower(a.address) NOT GLOB '*notifications@*'
                \(directClause)
                AND NOT EXISTS (
                    SELECT 1 FROM messages r WHERE r.conversation_id = m.conversation_id AND r.deleted = 0
                    AND r.date_received > m.date_received)
                ORDER BY m.date_received DESC
                """, bindings + [.text(ownJSON)]
            ) { $0.int(0) }
        }
        return Array(deduplicatedByConversation(try messages(ids: ids)).prefix(limit))
    }

    private func deduplicatedByConversation(_ messages: [MessageSummary]) -> [MessageSummary] {
        var seen = Set<Int64>()
        return messages.filter { seen.insert($0.conversationID).inserted }
    }

    static func jsonArray(_ values: [String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: values)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
