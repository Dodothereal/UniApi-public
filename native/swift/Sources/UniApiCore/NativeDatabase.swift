import Foundation
import CSQLite

public final class NativeDatabase: @unchecked Sendable {
    private var connection: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let readOnly: Bool
    public init(url: URL? = nil, readOnly: Bool = false) throws {
        self.readOnly = readOnly
        let name = url?.path ?? ":memory:"
        if let url, !readOnly { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(name, &connection, flags, nil) == SQLITE_OK else { let error = failure(); sqlite3_close(connection); connection = nil; throw error }
        sqlite3_busy_timeout(connection, 5000)
        if !readOnly {
            try executeScript("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; CREATE TABLE IF NOT EXISTS schema_migrations(name TEXT PRIMARY KEY, applied_at INTEGER NOT NULL);")
        }
    }
    deinit { sqlite3_close(connection) }
    private func failure() -> NativeFailure { NativeFailure(connection.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite unavailable") }
    private func prepare(_ sql: String, _ parameters: [JSONValue]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let s = statement else { throw failure() }
        guard sqlite3_bind_parameter_count(s) == Int32(parameters.count) else { sqlite3_finalize(s); throw NativeFailure("SQL parameter count mismatch") }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .null: status = sqlite3_bind_null(s, index)
            case .bool(let v): status = sqlite3_bind_int(s, index, v ? 1 : 0)
            case .number(let v): status = sqlite3_bind_double(s, index, v)
            case .string(let v): status = v.withCString { sqlite3_bind_text(s, index, $0, -1, transient) }
            default: let text = String(decoding: try value.encoded(), as: UTF8.self); status = text.withCString { sqlite3_bind_text(s, index, $0, -1, transient) }
            }
            if status != SQLITE_OK { sqlite3_finalize(s); throw failure() }
        }
        return s
    }
    public func query(_ sql: String, _ parameters: [JSONValue] = []) throws -> [JSONObject] {
        var rows: [JSONObject] = []
        try forEachRow(sql, parameters) { rows.append($0) }
        return rows
    }
    /// Consume large result sets without retaining an intermediate dictionary
    /// for every row. The callback owns ordinary values and may throw safely.
    public func forEachRow(_ sql: String, _ parameters: [JSONValue] = [], _ consume: (JSONObject) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        let s = try prepare(sql, parameters); defer { sqlite3_finalize(s) }
        let columns = (0..<sqlite3_column_count(s)).map { String(cString: sqlite3_column_name(s, $0)) }
        while true {
            let status = sqlite3_step(s)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw failure() }
            var row: JSONObject = [:]
            for i in 0..<sqlite3_column_count(s) {
                let name = columns[Int(i)]
                row[name] = columnValue(s, i)
            }
            try consume(row)
        }
    }
    /// Deliver the positional header once, including for empty results, before
    /// stepping. Duplicate names remain separate columns. Callbacks run under
    /// the same lock as forEachRow and may throw; neither callback may suspend.
    /// Values are owned Swift values. Retaining a row uses ordinary array COW.
    internal func forEachValueRow(
        _ sql: String,
        _ parameters: [JSONValue] = [],
        columns onHeader: ([String]) throws -> Void,
        consumeValues: ([JSONValue]) throws -> Void
    ) throws {
        lock.lock(); defer { lock.unlock() }
        let s = try prepare(sql, parameters); defer { sqlite3_finalize(s) }
        let count = sqlite3_column_count(s)
        let columns = (0..<count).map { String(cString: sqlite3_column_name(s, $0)) }
        try onHeader(columns)
        var values = [JSONValue](repeating: .null, count: Int(count))
        while true {
            let status = sqlite3_step(s)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw failure() }
            for i in 0..<count { values[Int(i)] = columnValue(s, i) }
            try consumeValues(values)
        }
    }
    // Keep both row APIs on the established conversions, including INTEGER's
    // Double rounding, CString text truncation and a nil BLOB pointer as null.
    @inline(__always) private func columnValue(_ statement: OpaquePointer, _ column: Int32) -> JSONValue {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER: return .number(Double(sqlite3_column_int64(statement, column)))
        case SQLITE_FLOAT: return .number(sqlite3_column_double(statement, column))
        case SQLITE_TEXT: return .string(String(cString: sqlite3_column_text(statement, column)))
        case SQLITE_BLOB:
            if let b = sqlite3_column_blob(statement, column) { return .string(Data(bytes: b, count: Int(sqlite3_column_bytes(statement, column))).base64EncodedString()) } else { return .null }
        default: return .null
        }
    }
    @discardableResult public func execute(_ sql: String, _ parameters: [JSONValue] = []) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        guard !readOnly else { throw NativeFailure("Database is read-only") }
        let s = try prepare(sql, parameters); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw failure() }
        return Int64(sqlite3_changes(connection))
    }
    public func executeScript(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard !readOnly else { throw NativeFailure("Database is read-only") }
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try executeScript("BEGIN IMMEDIATE")
        do { let value = try body(); try executeScript("COMMIT"); return value }
        catch { try? executeScript("ROLLBACK"); throw error }
    }
    public func migrate(_ name: String, sql: String) throws {
        if readOnly { return }
        try transaction {
            if !(try query("SELECT name FROM schema_migrations WHERE name=?", [.string(name)])).isEmpty { return }
            try executeScript(sql)
            try execute("INSERT INTO schema_migrations(name,applied_at) VALUES (?,?)", [.string(name), .number(Date().timeIntervalSince1970 * 1000)])
        }
    }
}
