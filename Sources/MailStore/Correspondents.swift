import Foundation

/// Someone the user exchanged mail with, from Mail's address table.
public struct Correspondent: Sendable, Hashable {
    public var address: String
    public var name: String?
    /// Messages from them.
    public var received: Int
    /// Messages from the user with them as a recipient.
    public var sent: Int
    public var lastMessage: Date?
}

extension MailStore {
    /// Addresses whose address or display name contains `text`, most-written-with first. The user's own
    /// addresses are left out.
    public func correspondents(matching text: String, limit: Int = 10) throws -> [Correspondent] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return [] }
        let pattern = "%" + trimmed.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
        let own = Self.jsonArray(try ownAddresses().sorted())
        let found = try withDB { db in
            try db.all(
                """
                WITH matches AS (
                    SELECT ROWID AS id, lower(address) AS addr, comment FROM addresses
                    WHERE (address LIKE ?1 ESCAPE '\\' OR comment LIKE ?1 ESCAPE '\\')
                    AND lower(address) NOT IN (SELECT value FROM json_each(?2))
                    LIMIT 500
                ),
                received AS (
                    SELECT x.addr, COUNT(*) AS n, MAX(m.date_received) AS last FROM matches x
                    JOIN messages m ON m.sender = x.id WHERE m.deleted = 0 GROUP BY x.addr
                ),
                sent AS (
                    SELECT x.addr, COUNT(DISTINCT m.ROWID) AS n, MAX(m.date_received) AS last FROM matches x
                    JOIN recipients r ON r.address = x.id JOIN messages m ON m.ROWID = r.message
                    JOIN addresses s ON s.ROWID = m.sender
                    WHERE m.deleted = 0 AND lower(s.address) IN (SELECT value FROM json_each(?2)) GROUP BY x.addr
                )
                SELECT x.addr, MAX(NULLIF(x.comment, '')), IFNULL(rc.n, 0), IFNULL(st.n, 0), MAX(IFNULL(rc.last, 0), IFNULL(st.last, 0))
                FROM matches x LEFT JOIN received rc ON rc.addr = x.addr LEFT JOIN sent st ON st.addr = x.addr
                GROUP BY x.addr HAVING IFNULL(rc.n, 0) + IFNULL(st.n, 0) > 0
                ORDER BY IFNULL(st.n, 0) * 3 + IFNULL(rc.n, 0) DESC, x.addr LIMIT ?3
                """, [.text(pattern), .text(own), .int(Int64(max(1, min(limit, 100))))]
            ) { row in
                let last = row.int(4)
                return Correspondent(
                    address: row.string(0), name: row.optionalString(1), received: Int(row.int(2)), sent: Int(row.int(3)),
                    lastMessage: last > 0 ? Date(timeIntervalSince1970: TimeInterval(last)) : nil)
            }
        }
        return found
    }
}
