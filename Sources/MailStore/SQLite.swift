import Foundation
import SQLite3

/// Errors raised by the SQLite layer.
public enum SQLiteError: Error, CustomStringConvertible, Sendable {
    case open(path: String, code: Int32, message: String)
    case prepare(sql: String, message: String)
    case step(message: String)
    case bind(message: String)

    public var description: String {
        switch self {
        case .open(let path, let code, let message): "cannot open \(path) (\(code)): \(message)"
        case .prepare(let sql, let message): "cannot prepare SQL (\(message)): \(sql.prefix(200))"
        case .step(let message): "SQLite step failed: \(message)"
        case .bind(let message): "SQLite bind failed: \(message)"
        }
    }
}

/// A value bound to a statement parameter.
public enum SQLValue: Sendable, Hashable {
    case int(Int64)
    case double(Double)
    case text(String)
    case null
}

extension SQLValue: ExpressibleByIntegerLiteral, ExpressibleByStringLiteral {
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(stringLiteral value: String) { self = .text(value) }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A thin, synchronous SQLite connection. Not thread-safe on its own: callers
/// serialize access (``EnvelopeIndex`` and ``BodyIndex`` hold a lock).
public final class SQLiteConnection {
    let handle: OpaquePointer
    public let path: String
    private var statementCache: [String: OpaquePointer] = [:]
    /// Statements stepping right now (a row callback may run another query); never finalized by eviction.
    private var activeStatements: Set<OpaquePointer> = []

    /// Opens a database. `readOnly` uses a `mode=ro` URI so SQLite never takes
    /// a write lock on Mail's live index, but still sees WAL-committed data.
    public init(path: String, readOnly: Bool, create: Bool = false) throws {
        self.path = path
        var db: OpaquePointer?
        let flags: Int32
        let target: String
        if readOnly {
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
            var components = URLComponents()
            components.scheme = "file"
            components.path = path
            components.queryItems = [URLQueryItem(name: "mode", value: "ro")]
            target = components.string ?? "file:\(path)?mode=ro"
        } else {
            flags = SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0) | SQLITE_OPEN_NOMUTEX
            target = path
        }
        let code = sqlite3_open_v2(target, &db, flags, nil)
        guard code == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let db { sqlite3_close_v2(db) }
            throw SQLiteError.open(path: path, code: code, message: message)
        }
        handle = db
        sqlite3_busy_timeout(db, 3000)
        if readOnly {
            // Read through a memory map and keep more pages: without these every query re-reads its pages with
            // pread(2). A mapping of the file is shared with the page cache, not a copy.
            sqlite3_exec(db, "PRAGMA mmap_size = 1073741824; PRAGMA cache_size = -32768", nil, nil, nil)
        }
    }

    deinit {
        for statement in statementCache.values { sqlite3_finalize(statement) }
        sqlite3_close_v2(handle)
    }

    public var lastErrorMessage: String { String(cString: sqlite3_errmsg(handle)) }

    public func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(error)
            throw SQLiteError.step(message: message)
        }
    }

    /// Runs `sql` with `bindings` and calls `row` for each result row.
    public func query(_ sql: String, _ bindings: [SQLValue] = [], row: (Row) throws -> Void) throws {
        let statement = try prepared(sql)
        let outermost = activeStatements.insert(statement).inserted
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            if outermost { activeStatements.remove(statement) }
        }
        try bind(bindings, to: statement)
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                try row(Row(statement: statement))
            } else if code == SQLITE_DONE {
                return
            } else {
                throw SQLiteError.step(message: lastErrorMessage)
            }
        }
    }

    /// Collects every row through `transform`.
    public func all<T>(_ sql: String, _ bindings: [SQLValue] = [], _ transform: (Row) throws -> T) throws -> [T] {
        var out: [T] = []
        try query(sql, bindings) { out.append(try transform($0)) }
        return out
    }

    /// Returns the first row through `transform`, or nil.
    public func first<T>(_ sql: String, _ bindings: [SQLValue] = [], _ transform: (Row) throws -> T) throws -> T? {
        var out: T?
        try query(sql, bindings) { row in
            if out == nil { out = try transform(row) }
        }
        return out
    }

    public func scalarInt(_ sql: String, _ bindings: [SQLValue] = []) throws -> Int64? {
        try first(sql, bindings) { $0.int(0) }
    }

    /// Runs a write statement.
    public func run(_ sql: String, _ bindings: [SQLValue] = []) throws {
        try query(sql, bindings) { _ in }
    }

    public var changes: Int { Int(sqlite3_changes(handle)) }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepared(_ sql: String) throws -> OpaquePointer {
        if let cached = statementCache[sql] { return cached }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw SQLiteError.prepare(sql: sql, message: lastErrorMessage)
        }
        // Keep the cache bounded: dynamic search SQL varies with the filter set.
        // Statements still stepping in an enclosing query stay; finalizing them would be a use-after-free.
        if statementCache.count > 256 {
            for (key, cached) in statementCache where !activeStatements.contains(cached) {
                sqlite3_finalize(cached)
                statementCache[key] = nil
            }
        }
        statementCache[sql] = statement
        return statement
    }

    private func bind(_ values: [SQLValue], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .int(let v): code = sqlite3_bind_int64(statement, index, v)
            case .double(let v): code = sqlite3_bind_double(statement, index, v)
            case .text(let v): code = sqlite3_bind_text(statement, index, v, -1, SQLITE_TRANSIENT)
            case .null: code = sqlite3_bind_null(statement, index)
            }
            if code != SQLITE_OK { throw SQLiteError.bind(message: lastErrorMessage) }
        }
    }

    /// One result row. Valid only inside the `query` callback.
    public struct Row {
        let statement: OpaquePointer

        public func isNull(_ column: Int32) -> Bool {
            sqlite3_column_type(statement, column) == SQLITE_NULL
        }

        public func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }

        public func optionalInt(_ column: Int32) -> Int64? { isNull(column) ? nil : int(column) }

        public func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }

        public func string(_ column: Int32) -> String {
            guard let text = sqlite3_column_text(statement, column) else { return "" }
            return String(cString: text)
        }

        public func optionalString(_ column: Int32) -> String? { isNull(column) ? nil : string(column) }

        /// The column's text as UTF-8 bytes, without making a String; valid only inside `body`.
        public func withBytes<T>(_ column: Int32, _ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
            let value = sqlite3_column_text(statement, column)
            return try body(UnsafeRawBufferPointer(start: value, count: Int(sqlite3_column_bytes(statement, column))))
        }
    }
}

extension SQLiteConnection {
    /// Column names of `table`, for schema-compatibility checks.
    public func columns(of table: String) throws -> Set<String> {
        Set(try all("SELECT name FROM pragma_table_info(?)", [.text(table)]) { $0.string(0) })
    }

    /// Escapes `%`, `_` and `\` for a `LIKE ... ESCAPE '\'` pattern.
    public static func likePattern(containing text: String) -> String {
        var escaped = ""
        for character in text {
            if character == "%" || character == "_" || character == "\\" { escaped.append("\\") }
            escaped.append(character)
        }
        return "%\(escaped)%"
    }
}
