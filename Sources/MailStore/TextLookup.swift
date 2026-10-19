import Foundation

/// One of Mail's text lookup tables (subjects, addresses) held in memory, for `LIKE '%term%'` without a table scan
/// in SQLite: 8 ms for 56,000 subjects, paid once for the page and again for the count. Rows sit in one buffer,
/// each after a 0 byte, so a single `memmem` pass finds every match. Matching is SQLite's LIKE: ASCII letters
/// fold, every other byte must match as is. A value: a search keeps its snapshot while another call appends.
struct TextLookupTable {
    private var ids: [Int64] = []
    private var starts: [Int] = []  // where each row's text begins in `text`
    private var text: [UInt8] = []
    private(set) var maxID: Int64 = 0
    var rowCount: Int { ids.count }

    /// Separates the columns of one row (an address and its display name), so no term matches across them.
    static let columnSeparator: UInt8 = 1

    mutating func append(id: Int64, columns: [String]) {
        text.append(0)
        starts.append(text.count)
        for (index, column) in columns.enumerated() {
            if index > 0 { text.append(Self.columnSeparator) }
            text.append(contentsOf: column.utf8.map(Self.fold))
        }
        ids.append(id)
        maxID = max(maxID, id)
    }

    /// Rows with `term` anywhere, like `LIKE '%term%'`; nil when the term holds a byte used as a separator.
    func ids(containing term: String) -> [Int64]? {
        let needle = term.utf8.map(Self.fold)
        if needle.contains(0) || needle.contains(Self.columnSeparator) { return nil }
        if needle.isEmpty { return ids }
        return find(needle)
    }

    /// Rows whose (first) column starts with `prefix`, like `LIKE 'prefix%'`.
    func ids(startingWith prefix: String) -> [Int64]? {
        let folded = prefix.utf8.map(Self.fold)
        if folded.contains(0) || folded.contains(Self.columnSeparator) { return nil }
        return find([0] + folded)
    }

    private func find(_ needle: [UInt8]) -> [Int64] {
        var found: [Int64] = []
        text.withUnsafeBytes { haystack in
            needle.withUnsafeBytes { pattern in
                guard let base = haystack.baseAddress, let patternBase = pattern.baseAddress else { return }
                var offset = 0
                while offset < haystack.count,
                    let hit = memmem(base + offset, haystack.count - offset, patternBase, pattern.count)
                {
                    let position = base.distance(to: hit)
                    // The row holding `position`: the last start at or before it (a leading 0 belongs to the next row).
                    let row = rowIndex(containing: needle.first == 0 ? position + 1 : position)
                    found.append(ids[row])
                    offset = row + 1 < starts.count ? starts[row + 1] - 1 : haystack.count
                }
            }
        }
        return found
    }

    private func rowIndex(containing position: Int) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= position { low = middle } else { high = middle - 1 }
        }
        return low
    }

    private static func fold(_ byte: UInt8) -> UInt8 {
        byte >= 65 && byte <= 90 ? byte + 32 : byte
    }
}

/// Mail's subjects and addresses in memory, kept up to date by ROWID: both tables grow at the end, and rows Mail
/// clears out are noticed by comparing row counts every minute (the tables are then read again in full).
final class TextLookups: @unchecked Sendable {
    private let lock = NSLock()
    private var subjects = TextLookupTable()
    private var addresses = TextLookupTable()
    private var checkedVersion: Int64 = -1
    private var verifiedAt = Date.distantPast
    /// Bumped whenever the tables change; recent matches are only valid for the generation that found them.
    private var generation = 0
    private var recent: [String: [Int64]] = [:]

    static let verifyInterval: TimeInterval = 60

    /// The tables as of `dataVersion`. `rows` runs a query returning ROWID and that many text columns; `counts` the row counts.
    func current(
        dataVersion: Int64, rows: Rows, counts: () throws -> (subjects: Int, addresses: Int)
    ) throws -> (subjects: TextLookupTable, addresses: TextLookupTable, generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        if dataVersion < 0 || dataVersion != checkedVersion {  // -1: not known yet, so look
            try catchUp(rows)
            if Date().timeIntervalSince(verifiedAt) > Self.verifyInterval {
                let actual = try counts()
                if actual.subjects != subjects.rowCount || actual.addresses != addresses.rowCount {
                    subjects = TextLookupTable()
                    addresses = TextLookupTable()
                    try catchUp(rows)
                }
                verifiedAt = Date()
            }
            checkedVersion = dataVersion
        }
        return (subjects, addresses, generation)
    }

    /// Matches for `key` found earlier in this generation (a search builds its clause twice: page and count),
    /// else `compute`d and kept.
    func matches(_ key: String, generation: Int, compute: () -> [Int64]?) -> [Int64]? {
        lock.lock()
        if generation == self.generation, let known = recent[key] {
            lock.unlock()
            return known
        }
        lock.unlock()
        let found = compute()
        lock.lock()
        defer { lock.unlock() }
        if let found, generation == self.generation {
            if recent.count >= 64 { recent.removeAll() }
            recent[key] = found
        }
        return found
    }

    /// Runs a query, handing each row (ROWID and that many text columns) to the closure as it is read.
    typealias Rows = (_ sql: String, _ columns: Int32, _ row: (Int64, [String]) -> Void) throws -> Void

    private func catchUp(_ rows: Rows) throws {
        let before = (subjects.rowCount, addresses.rowCount)
        defer {
            if (subjects.rowCount, addresses.rowCount) != before {
                generation += 1
                recent.removeAll()
            }
        }
        try rows("SELECT ROWID, IFNULL(subject, '') FROM subjects WHERE ROWID > \(subjects.maxID) ORDER BY ROWID", 1) {
            subjects.append(id: $0, columns: $1)
        }
        try rows(
            "SELECT ROWID, IFNULL(address, ''), IFNULL(comment, '') FROM addresses WHERE ROWID > \(addresses.maxID) ORDER BY ROWID", 2
        ) { addresses.append(id: $0, columns: $1) }
    }
}
