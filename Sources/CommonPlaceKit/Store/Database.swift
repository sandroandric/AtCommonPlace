import Foundation
import SQLite3

/// A thin, synchronous SQLite connection: prepared statements with bound
/// values, rows as dictionaries, transactions.  One connection per store,
/// used from one actor, so it needs no locking of its own.
public final class Database {
    public enum Value: Equatable {
        case null
        case int(Int64)
        case double(Double)
        case text(String)
        case blob(Data)
    }

    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public let sql: String
        public var description: String { "SQLite: \(message) — \(sql.prefix(120))" }
    }

    public typealias Row = [String: Value]

    private var handle: OpaquePointer?
    public let path: String

    /// Open (creating it) the database at `path`; ":memory:" for a
    /// throwaway one.  WAL, foreign keys on, a 5 s busy timeout.
    public init(path: String) throws {
        self.path = path
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(handle)
            throw Failure(message: message, sql: "open \(path)")
        }
        sqlite3_busy_timeout(handle, 5_000)
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA synchronous = NORMAL")
    }

    deinit {
        sqlite3_close(handle)
    }

    /// Run one or more statements without results (DDL, pragmas).
    public func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "error"
            sqlite3_free(error)
            throw Failure(message: message, sql: sql)
        }
    }

    /// Run one statement with `values` bound to its `?`s.
    @discardableResult
    public func run(_ sql: String, _ values: [Value] = []) throws -> Int {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw failure(sql) }
        return Int(sqlite3_changes(handle))
    }

    /// The rows of one query.
    public func query(_ sql: String, _ values: [Value] = []) throws -> [Row] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var rows: [Row] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw failure(sql) }
            var row: Row = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                row[name] = Self.value(statement, column)
            }
            rows.append(row)
        }
        return rows
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    /// `body` in one immediate transaction: all of it or none.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public var userVersion: Int {
        let row = (try? query("PRAGMA user_version"))?.first
        return Int(row?["user_version"]?.int ?? 0)
    }

    public func setUserVersion(_ version: Int) throws {
        try execute("PRAGMA user_version = \(version)")
    }

    // MARK: - Internals

    private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw failure(sql)
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .null: sqlite3_bind_null(statement, index)
            case .int(let v): sqlite3_bind_int64(statement, index, v)
            case .double(let v): sqlite3_bind_double(statement, index, v)
            case .text(let v): sqlite3_bind_text(statement, index, v, -1, transient)
            case .blob(let v):
                _ = v.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(v.count), transient)
                }
            }
        }
        return statement
    }

    private func failure(_ sql: String) -> Failure {
        Failure(message: String(cString: sqlite3_errmsg(handle)), sql: sql)
    }

    private static func value(_ statement: OpaquePointer?, _ column: Int32) -> Value {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER: return .int(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT: return .double(sqlite3_column_double(statement, column))
        case SQLITE_TEXT: return .text(String(cString: sqlite3_column_text(statement, column)))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return .blob(Data()) }
            return .blob(Data(bytes: bytes, count: count))
        default: return .null
        }
    }
}

public extension Database.Value {
    var int: Int64? { if case .int(let v) = self { return v }; return nil }
    var double: Double? {
        switch self {
        case .double(let v): return v
        case .int(let v): return Double(v)
        default: return nil
        }
    }
    var text: String? { if case .text(let v) = self { return v }; return nil }
    var blob: Data? { if case .blob(let v) = self { return v }; return nil }
}

public extension Optional where Wrapped == String {
    /// A text column's value, `.null` for nil.
    var sqlValue: Database.Value { map { .text($0) } ?? .null }
}
