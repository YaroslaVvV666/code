import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLValue {
    case text(String)
    case integer(Int)
    case real(Double)
    case blob(Data)
    case null

    var string: String? { if case .text(let s) = self { return s }; return nil }
    var data: Data? { if case .blob(let d) = self { return d }; return nil }
    var int: Int? {
        switch self {
        case .integer(let n): return n
        case .real(let d):    return Int(d)
        default:              return nil
        }
    }
    var double: Double? {
        switch self {
        case .real(let d):    return d
        case .integer(let n): return Double(n)
        default:              return nil
        }
    }
}

/// Тонкая потокобезопасная обёртка над SQLite.
/// Одно соединение на всё приложение; каждый вызов под блокировкой.
final class SQLiteDB: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()

    init(path: String) {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
            print("SQLite: не удалось открыть базу")
        }
        exec("PRAGMA foreign_keys = ON;")
        exec("PRAGMA journal_mode = WAL;")
        exec("PRAGMA secure_delete = ON;")      // удалённые данные затираются нулями
    }

    deinit { sqlite3_close(db) }

    @discardableResult
    func exec(_ sql: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    /// INSERT / UPDATE / DELETE. false — например, при нарушении UNIQUE
    @discardableResult
    func run(_ sql: String, _ params: [SQLValue] = []) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    func query(_ sql: String, _ params: [SQLValue] = []) -> [[SQLValue]] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params)

        var rows: [[SQLValue]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let count = sqlite3_column_count(stmt)
            var row: [SQLValue] = []
            for c in 0..<count { row.append(value(stmt, c)) }
            rows.append(row)
        }
        return rows
    }

    /// Всё внутри блока выполняется как одна транзакция (вернули false — откат)
    @discardableResult
    func transaction(_ body: () -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        exec("BEGIN")
        let ok = body()
        exec(ok ? "COMMIT" : "ROLLBACK")
        return ok
    }

    private func bind(_ stmt: OpaquePointer?, _ params: [SQLValue]) {
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .text(let s):    sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case .integer(let n): sqlite3_bind_int64(stmt, idx, Int64(n))
            case .real(let d):    sqlite3_bind_double(stmt, idx, d)
            case .blob(let d):
                d.withUnsafeBytes { raw in
                    _ = sqlite3_bind_blob(stmt, idx, raw.baseAddress, Int32(d.count), SQLITE_TRANSIENT)
                }
            case .null:           sqlite3_bind_null(stmt, idx)
            }
        }
    }

    private func value(_ stmt: OpaquePointer?, _ c: Int32) -> SQLValue {
        switch sqlite3_column_type(stmt, c) {
        case SQLITE_INTEGER:
            return .integer(Int(sqlite3_column_int64(stmt, c)))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(stmt, c))
        case SQLITE_TEXT:
            if let p = sqlite3_column_text(stmt, c) { return .text(String(cString: p)) }
            return .null
        case SQLITE_BLOB:
            let n = Int(sqlite3_column_bytes(stmt, c))
            if n > 0, let p = sqlite3_column_blob(stmt, c) { return .blob(Data(bytes: p, count: n)) }
            return .blob(Data())
        default:
            return .null
        }
    }
}
