import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

public enum SQLiteError: Error, Equatable {
    case open(String)
    case prepare(String)
    case step(String)
    case constraint(String)
    case schemaNewerThanApp(found: Int, supported: Int)
}

public enum SQLValue: Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
}

public struct Row {
    public let values: [String: SQLValue]
    public func int(_ column: String) -> Int64? {
        if case .int(let v) = values[column] { return v }
        return nil
    }
    public func text(_ column: String) -> String? {
        if case .text(let v) = values[column] { return v }
        return nil
    }
}

/// Thin wrapper over one SQLite connection. Prepared statements only; no string-built SQL with user data.
public final class SQLiteDatabase {
    private let handle: OpaquePointer
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let opened = db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            sqlite3_close(db)
            throw SQLiteError.open(message)
        }
        handle = opened
        try execute("PRAGMA foreign_keys = ON;")
        try execute("PRAGMA journal_mode = WAL;")
    }

    deinit { sqlite3_close(handle) }

    private var lastError: String { String(cString: sqlite3_errmsg(handle)) }

    /// Runs one or more statements without parameters (schema, pragmas).
    public func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError.step(lastError)
        }
    }

    /// Runs one statement; returns the number of changed rows.
    @discardableResult
    public func run(_ sql: String, _ params: [SQLValue] = []) throws -> Int {
        _ = try query(sql, params)
        return Int(sqlite3_changes(handle))
    }

    public func query(_ sql: String, _ params: [SQLValue] = []) throws -> [Row] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let statement = stmt else {
            throw SQLiteError.prepare(lastError)
        }
        defer { sqlite3_finalize(statement) }

        for (offset, value) in params.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .null: rc = sqlite3_bind_null(statement, index)
            case .int(let v): rc = sqlite3_bind_int64(statement, index, v)
            case .double(let v): rc = sqlite3_bind_double(statement, index, v)
            case .text(let v): rc = sqlite3_bind_text(statement, index, v, -1, Self.transient)
            }
            guard rc == SQLITE_OK else { throw SQLiteError.prepare(lastError) }
        }

        var rows: [Row] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                if rc & 0xff == SQLITE_CONSTRAINT { throw SQLiteError.constraint(lastError) }
                throw SQLiteError.step(lastError)
            }
            var values: [String: SQLValue] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = sqlite3_column_name(statement, column).map { String(cString: $0) } ?? "\(column)"
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: values[name] = .int(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: values[name] = .double(sqlite3_column_double(statement, column))
                case SQLITE_TEXT:
                    if let text = sqlite3_column_text(statement, column) {
                        values[name] = .text(String(cString: text))
                    }
                default: values[name] = .null
                }
            }
            rows.append(Row(values: values))
        }
        return rows
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func userVersion() throws -> Int {
        Int(try query("PRAGMA user_version;").first?.int("user_version") ?? 0)
    }
}
