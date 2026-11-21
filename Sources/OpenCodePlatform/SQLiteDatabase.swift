#if !os(WASI)
import Foundation
#endif
#if canImport(SQLite3)
import SQLite3
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif os(Windows)
import WinSDK
#endif
import Synchronization

private func trimWhitespace(_ s: Substring) -> String {
    var start = s.startIndex
    var end = s.endIndex
    while start < end && s[start].isWhitespace {
        start = s.index(after: start)
    }
    while end > start {
        let prev = s.index(before: end)
        if s[prev].isWhitespace {
            end = prev
        } else {
            break
        }
    }
    return String(s[start..<end])
}

private func trimWhitespace(_ s: String) -> String {
    trimWhitespace(s[...])
}

private func trimQuotesAndSpace(_ s: String) -> String {
    var result = trimWhitespace(s)
    while result.first == "\"" || result.first == " " {
        result.removeFirst()
    }
    while result.last == "\"" || result.last == " " {
        result.removeLast()
    }
    return result
}

private func findASCII(_ needle: String, in haystack: String) -> Range<String.Index>? {
    guard !needle.isEmpty else { return nil }
    let hay = Array(haystack)
    let ndl = Array(needle)
    guard ndl.count <= hay.count else { return nil }
    for i in 0...(hay.count - ndl.count) {
        var match = true
        for j in 0..<ndl.count {
            if hay[i + j] != ndl[j] {
                match = false
                break
            }
        }
        if match {
            let start = haystack.index(haystack.startIndex, offsetBy: i)
            let end = haystack.index(start, offsetBy: ndl.count)
            return start..<end
        }
    }
    return nil
}

private func replaceAll(_ source: String, of target: String, with replacement: String) -> String {
    guard !target.isEmpty else { return source }
    var out = ""
    var rest = source[...]
    while let range = findASCII(target, in: String(rest)) {
        let distStart = String(rest).distance(from: String(rest).startIndex, to: range.lowerBound)
        let distEnd = String(rest).distance(from: String(rest).startIndex, to: range.upperBound)
        let idxStart = rest.index(rest.startIndex, offsetBy: distStart)
        let idxEnd = rest.index(rest.startIndex, offsetBy: distEnd)
        out.append(contentsOf: rest[..<idxStart])
        out.append(replacement)
        rest = rest[idxEnd...]
    }
    out.append(contentsOf: rest)
    return out
}

// MARK: - SQLite Value, Row, Error & Protocol

/// Typed value stored in or bound to a SQLite database column/parameter.
public enum SQLiteValue: Equatable, Hashable, Sendable, CustomStringConvertible {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob([UInt8])

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var int64Value: Int64? {
        switch self {
        case .integer(let value): return value
        case .real(let value): return Int64(value)
        case .text(let value): return Int64(value)
        default: return nil
        }
    }

    public var intValue: Int? {
        int64Value.map(Int.init)
    }

    public var boolValue: Bool? {
        switch self {
        case .integer(let value): return value != 0
        case .text(let value):
            let lower = value.lowercased()
            if lower == "true" || lower == "1" { return true }
            if lower == "false" || lower == "0" { return false }
            return nil
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .real(let value): return value
        case .integer(let value): return Double(value)
        case .text(let value): return Double(value)
        default: return nil
        }
    }

    public var stringValue: String? {
        switch self {
        case .text(let value): return value
        case .integer(let value): return String(value)
        case .real(let value): return String(value)
        default: return nil
        }
    }

    public var blobValue: [UInt8]? {
        switch self {
        case .blob(let bytes): return bytes
        case .text(let text): return Array(text.utf8)
        default: return nil
        }
    }

    public var description: String {
        switch self {
        case .null: return "NULL"
        case .integer(let v): return String(v)
        case .real(let v): return String(v)
        case .text(let v): return v
        case .blob(let b): return "BLOB(\(b.count) bytes)"
        }
    }
}

/// A single row returned by a SQLite query.
public struct SQLiteRow: Equatable, Hashable, Sendable {
    public let columns: [String]
    public let values: [SQLiteValue]

    public init(columns: [String], values: [SQLiteValue]) {
        self.columns = columns
        self.values = values
    }

    public var count: Int { values.count }

    public subscript(index: Int) -> SQLiteValue {
        values[index]
    }

    public subscript(column: String) -> SQLiteValue? {
        if let idx = columns.firstIndex(of: column) {
            return values[idx]
        }
        let lowered = column.lowercased()
        if let idx = columns.firstIndex(where: { $0.lowercased() == lowered }) {
            return values[idx]
        }
        return nil
    }

    public func int64(_ column: String) -> Int64? {
        self[column]?.int64Value
    }

    public func double(_ column: String) -> Double? {
        self[column]?.doubleValue
    }

    public func string(_ column: String) -> String? {
        self[column]?.stringValue
    }

    public func blob(_ column: String) -> [UInt8]? {
        self[column]?.blobValue
    }

    public func isNull(_ column: String) -> Bool {
        self[column]?.isNull ?? true
    }

    public var dictionary: [String: SQLiteValue] {
        var result: [String: SQLiteValue] = [:]
        result.reserveCapacity(columns.count)
        for (col, val) in zip(columns, values) {
            result[col] = val
        }
        return result
    }
}

/// Errors reported by SQLite database operations.
public enum SQLiteError: Error, Equatable, Sendable, CustomStringConvertible {
    case openFailed(path: String, code: Int32, message: String)
    case prepareFailed(sql: String, code: Int32, message: String)
    case bindFailed(index: Int32, code: Int32, message: String)
    case stepFailed(sql: String, code: Int32, message: String)
    case executionFailed(sql: String, code: Int32, message: String)
    case constraintViolation(code: Int32, message: String)
    case databaseClosed
    case invalidParameter(String)
    case migrationFailed(version: Int, name: String, message: String)
    case unsupportedSQL(String)

    public var description: String {
        switch self {
        case let .openFailed(path, code, message):
            return "SQLite open failed for '\(path)' (code \(code)): \(message)"
        case let .prepareFailed(sql, code, message):
            return "SQLite prepare failed (code \(code)): \(message) [SQL: \(sql)]"
        case let .bindFailed(index, code, message):
            return "SQLite bind failed at parameter \(index) (code \(code)): \(message)"
        case let .stepFailed(sql, code, message):
            return "SQLite step failed (code \(code)): \(message) [SQL: \(sql)]"
        case let .executionFailed(sql, code, message):
            return "SQLite execution failed (code \(code)): \(message) [SQL: \(sql)]"
        case let .constraintViolation(code, message):
            return "SQLite constraint violation (code \(code)): \(message)"
        case .databaseClosed:
            return "SQLite database is closed"
        case .invalidParameter(let detail):
            return "SQLite invalid parameter: \(detail)"
        case let .migrationFailed(version, name, message):
            return "SQLite migration v\(version) ('\(name)') failed: \(message)"
        case .unsupportedSQL(let sql):
            return "SQLite fallback does not support statement: \(sql)"
        }
    }
}

/// Configuration options applied when opening a SQLite database.
public struct SQLiteOpenOptions: Equatable, Sendable {
    public let journalMode: String
    public let foreignKeys: Bool
    public let busyTimeoutMs: Int32
    public let synchronous: String
    public let readOnly: Bool
    public let createIfMissing: Bool

    public init(
        journalMode: String = "WAL",
        foreignKeys: Bool = true,
        busyTimeoutMs: Int32 = 5_000,
        synchronous: String = "NORMAL",
        readOnly: Bool = false,
        createIfMissing: Bool = true
    ) {
        self.journalMode = journalMode
        self.foreignKeys = foreignKeys
        self.busyTimeoutMs = busyTimeoutMs
        self.synchronous = synchronous
        self.readOnly = readOnly
        self.createIfMissing = createIfMissing
    }
}

/// Schema migration step executed atomically by `SQLiteDatabase.migrate(_:)`.
public struct SQLiteMigration: Equatable, Sendable {
    public let version: Int
    public let name: String
    public let sql: String

    public init(version: Int, name: String, sql: String) {
        self.version = version
        self.name = name
        self.sql = sql
    }
}

/// Mutation summary returned by `SQLiteDatabase.execute(_:parameters:)`.
public struct SQLiteExecuteResult: Equatable, Sendable {
    public let rowsAffected: Int
    public let lastInsertRowID: Int64

    public init(rowsAffected: Int, lastInsertRowID: Int64) {
        self.rowsAffected = rowsAffected
        self.lastInsertRowID = lastInsertRowID
    }
}

/// Cross-platform SQLite database engine protocol.
public protocol SQLiteDatabase: Sendable {
    var path: String { get }

    @discardableResult
    func execute(_ sql: String, parameters: [SQLiteValue]) throws -> SQLiteExecuteResult
    func executeScript(_ sql: String) throws
    func query(_ sql: String, parameters: [SQLiteValue]) throws -> [SQLiteRow]
    func transaction<T>(_ body: () throws -> T) throws -> T
    func savepoint<T>(_ name: String, _ body: () throws -> T) throws -> T
    func close() throws
}

public extension SQLiteDatabase {
    @discardableResult
    func execute(_ sql: String) throws -> SQLiteExecuteResult {
        try execute(sql, parameters: [])
    }

    func query(_ sql: String) throws -> [SQLiteRow] {
        try query(sql, parameters: [])
    }

    func queryOne(_ sql: String, parameters: [SQLiteValue] = []) throws -> SQLiteRow? {
        try query(sql, parameters: parameters).first
    }

    func queryScalar(_ sql: String, parameters: [SQLiteValue] = []) throws -> SQLiteValue? {
        try query(sql, parameters: parameters).first?.values.first
    }

    /// Returns all migration versions currently recorded in `_opencode_migrations`.
    func appliedMigrations() throws -> [Int] {
        try ensureMigrationsTable()
        let rows = try query("SELECT version FROM _opencode_migrations ORDER BY version ASC")
        return rows.compactMap { $0.int64("version").map(Int.init) }
    }

    /// Runs all pending schema migrations in ascending `version` order, each inside an atomic transaction.
    /// Returns the versions newly applied in this call.
    @discardableResult
    func migrate(_ migrations: [SQLiteMigration]) throws -> [Int] {
        try ensureMigrationsTable()
        let alreadyApplied = Set(try appliedMigrations())
        let sorted = migrations.sorted { $0.version < $1.version }
        var appliedNow: [Int] = []

        for migration in sorted {
            if alreadyApplied.contains(migration.version) {
                continue
            }
            do {
                try transaction {
                    try executeScript(migration.sql)
                    _ = try execute(
                        "INSERT INTO _opencode_migrations (version, name, applied_at) VALUES (?, ?, ?)",
                        parameters: [
                            .integer(Int64(migration.version)),
                            .text(migration.name),
                            .integer(Flock.currentEpochMs()),
                        ]
                    )
                }
                appliedNow.append(migration.version)
            } catch {
                throw SQLiteError.migrationFailed(
                    version: migration.version,
                    name: migration.name,
                    message: String(describing: error)
                )
            }
        }
        return appliedNow
    }

    private func ensureMigrationsTable() throws {
        _ = try execute(
            """
            CREATE TABLE IF NOT EXISTS _opencode_migrations (
                version INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                applied_at INTEGER NOT NULL
            )
            """
        )
    }
}

/// Cross-platform factory returning `NativeSQLiteDatabase` where C SQLite3 is available
/// and `InMemorySQLiteFallback` on platforms without system SQLite3 (such as WASI).
public enum SQLiteDatabaseFactory {
    public static func open(
        path: String = ":memory:",
        options: SQLiteOpenOptions = SQLiteOpenOptions()
    ) throws -> any SQLiteDatabase {
        #if canImport(SQLite3)
        return try NativeSQLiteDatabase(path: path, options: options)
        #elseif canImport(Glibc) || canImport(Musl) || os(Windows)
        if SQLite3Runtime.isAvailable {
            return try NativeSQLiteDatabase(path: path, options: options)
        }
        return try InMemorySQLiteFallback(path: path, options: options)
        #else
        return try InMemorySQLiteFallback(path: path, options: options)
        #endif
    }
}

// MARK: - Cross-Platform Reentrant Lock

private final class ReentrantDatabaseLock: @unchecked Sendable {
    #if os(Windows)
    private let cs: UnsafeMutablePointer<CRITICAL_SECTION>

    init() {
        cs = UnsafeMutablePointer<CRITICAL_SECTION>.allocate(capacity: 1)
        cs.initialize(to: CRITICAL_SECTION())
        InitializeCriticalSection(cs)
    }

    deinit {
        DeleteCriticalSection(cs)
        cs.deinitialize(count: 1)
        cs.deallocate()
    }
    #elseif !os(WASI)
    private let lock = NSRecursiveLock()
    #endif

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        #if os(Windows)
        EnterCriticalSection(cs)
        defer { LeaveCriticalSection(cs) }
        #elseif !os(WASI)
        lock.lock()
        defer { lock.unlock() }
        #endif
        return try body()
    }
}

private func validateSavepointName(_ name: String) throws {
    guard !name.isEmpty,
          name.utf8.allSatisfy({ b in
              (b >= 0x30 && b <= 0x39)
                  || (b >= 0x41 && b <= 0x5A)
                  || (b >= 0x61 && b <= 0x7A)
                  || b == 0x5F
          }) else {
        throw SQLiteError.invalidParameter("Invalid savepoint name '\(name)'; expected [A-Za-z0-9_]+")
    }
}

// MARK: - Native C SQLite3 Engine

#if canImport(SQLite3) || canImport(Glibc) || canImport(Musl) || os(Windows)

#if !canImport(SQLite3)
private enum SQLite3Runtime {
    typealias DestructorFn = @convention(c) (UnsafeMutableRawPointer?) -> Void

    struct Symbols: Sendable {
        let openV2: @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<OpaquePointer?>?, Int32, UnsafePointer<CChar>?) -> Int32
        let closeV2: @convention(c) (OpaquePointer?) -> Int32
        let errmsg: @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
        let busyTimeout: @convention(c) (OpaquePointer?, Int32) -> Int32
        let prepareV2: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int32, UnsafeMutablePointer<OpaquePointer?>?, UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32
        let finalize: @convention(c) (OpaquePointer?) -> Int32
        let step: @convention(c) (OpaquePointer?) -> Int32
        let changes: @convention(c) (OpaquePointer?) -> Int32
        let lastInsertRowid: @convention(c) (OpaquePointer?) -> Int64
        let columnCount: @convention(c) (OpaquePointer?) -> Int32
        let columnName: @convention(c) (OpaquePointer?, Int32) -> UnsafePointer<CChar>?
        let columnType: @convention(c) (OpaquePointer?, Int32) -> Int32
        let columnInt64: @convention(c) (OpaquePointer?, Int32) -> Int64
        let columnDouble: @convention(c) (OpaquePointer?, Int32) -> Double
        let columnBytes: @convention(c) (OpaquePointer?, Int32) -> Int32
        let columnText: @convention(c) (OpaquePointer?, Int32) -> UnsafePointer<UInt8>?
        let columnBlob: @convention(c) (OpaquePointer?, Int32) -> UnsafeRawPointer?
        let bindParameterCount: @convention(c) (OpaquePointer?) -> Int32
        let bindNull: @convention(c) (OpaquePointer?, Int32) -> Int32
        let bindInt64: @convention(c) (OpaquePointer?, Int32, Int64) -> Int32
        let bindDouble: @convention(c) (OpaquePointer?, Int32, Double) -> Int32
        let bindText: @convention(c) (OpaquePointer?, Int32, UnsafePointer<CChar>?, Int32, DestructorFn?) -> Int32
        let bindBlob: @convention(c) (OpaquePointer?, Int32, UnsafeRawPointer?, Int32, DestructorFn?) -> Int32
        let bindZeroblob: @convention(c) (OpaquePointer?, Int32, Int32) -> Int32
    }

    static let SQLITE_OK: Int32 = 0
    static let SQLITE_CONSTRAINT: Int32 = 19
    static let SQLITE_ROW: Int32 = 100
    static let SQLITE_DONE: Int32 = 101
    static let SQLITE_OPEN_READONLY: Int32 = 0x0000_0001
    static let SQLITE_OPEN_READWRITE: Int32 = 0x0000_0002
    static let SQLITE_OPEN_CREATE: Int32 = 0x0000_0004
    static let SQLITE_OPEN_FULLMUTEX: Int32 = 0x0001_0000
    static let SQLITE_INTEGER: Int32 = 1
    static let SQLITE_FLOAT: Int32 = 2
    static let SQLITE_TEXT: Int32 = 3
    static let SQLITE_BLOB: Int32 = 4
    static let SQLITE_NULL: Int32 = 5

    static let transientDestructor: DestructorFn? = unsafeBitCast(Int(-1), to: DestructorFn?.self)
    static let symbols: Symbols? = loadSymbols()
    static var isAvailable: Bool { symbols != nil }

    private static func loadSymbols() -> Symbols? {
        #if canImport(Glibc) || canImport(Musl)
        let candidates = ["libsqlite3.so.0", "libsqlite3.so"]
        var handle: UnsafeMutableRawPointer?
        for name in candidates {
            if let loaded = dlopen(name, RTLD_LAZY | RTLD_LOCAL) {
                handle = loaded
                break
            }
        }
        guard let lib = handle else { return nil }
        func resolve<T>(_ name: String, as type: T.Type) -> T? {
            guard let ptr = dlsym(lib, name) else { return nil }
            return unsafeBitCast(ptr, to: type)
        }
        #elseif os(Windows)
        let candidates = ["sqlite3.dll", "winsqlite3.dll"]
        var module: HMODULE?
        for name in candidates {
            let wide = Array(name.utf16) + [0]
            if let loaded = wide.withUnsafeBufferPointer({ LoadLibraryW($0.baseAddress) }) {
                module = loaded
                break
            }
        }
        guard let lib = module else { return nil }
        func resolve<T>(_ name: String, as type: T.Type) -> T? {
            guard let ptr = GetProcAddress(lib, name) else { return nil }
            return unsafeBitCast(ptr, to: type)
        }
        #endif

        guard
            let openV2 = resolve("sqlite3_open_v2", as: (@convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<OpaquePointer?>?, Int32, UnsafePointer<CChar>?) -> Int32).self),
            let closeV2 = resolve("sqlite3_close_v2", as: (@convention(c) (OpaquePointer?) -> Int32).self),
            let errmsg = resolve("sqlite3_errmsg", as: (@convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?).self),
            let busyTimeout = resolve("sqlite3_busy_timeout", as: (@convention(c) (OpaquePointer?, Int32) -> Int32).self),
            let prepareV2 = resolve("sqlite3_prepare_v2", as: (@convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int32, UnsafeMutablePointer<OpaquePointer?>?, UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32).self),
            let finalize = resolve("sqlite3_finalize", as: (@convention(c) (OpaquePointer?) -> Int32).self),
            let step = resolve("sqlite3_step", as: (@convention(c) (OpaquePointer?) -> Int32).self),
            let changes = resolve("sqlite3_changes", as: (@convention(c) (OpaquePointer?) -> Int32).self),
            let lastInsertRowid = resolve("sqlite3_last_insert_rowid", as: (@convention(c) (OpaquePointer?) -> Int64).self),
            let columnCount = resolve("sqlite3_column_count", as: (@convention(c) (OpaquePointer?) -> Int32).self),
            let columnName = resolve("sqlite3_column_name", as: (@convention(c) (OpaquePointer?, Int32) -> UnsafePointer<CChar>?).self),
            let columnType = resolve("sqlite3_column_type", as: (@convention(c) (OpaquePointer?, Int32) -> Int32).self),
            let columnInt64 = resolve("sqlite3_column_int64", as: (@convention(c) (OpaquePointer?, Int32) -> Int64).self),
            let columnDouble = resolve("sqlite3_column_double", as: (@convention(c) (OpaquePointer?, Int32) -> Double).self),
            let columnBytes = resolve("sqlite3_column_bytes", as: (@convention(c) (OpaquePointer?, Int32) -> Int32).self),
            let columnText = resolve("sqlite3_column_text", as: (@convention(c) (OpaquePointer?, Int32) -> UnsafePointer<UInt8>?).self),
            let columnBlob = resolve("sqlite3_column_blob", as: (@convention(c) (OpaquePointer?, Int32) -> UnsafeRawPointer?).self),
            let bindParameterCount = resolve("sqlite3_bind_parameter_count", as: (@convention(c) (OpaquePointer?) -> Int32).self),
            let bindNull = resolve("sqlite3_bind_null", as: (@convention(c) (OpaquePointer?, Int32) -> Int32).self),
            let bindInt64 = resolve("sqlite3_bind_int64", as: (@convention(c) (OpaquePointer?, Int32, Int64) -> Int32).self),
            let bindDouble = resolve("sqlite3_bind_double", as: (@convention(c) (OpaquePointer?, Int32, Double) -> Int32).self),
            let bindText = resolve("sqlite3_bind_text", as: (@convention(c) (OpaquePointer?, Int32, UnsafePointer<CChar>?, Int32, DestructorFn?) -> Int32).self),
            let bindBlob = resolve("sqlite3_bind_blob", as: (@convention(c) (OpaquePointer?, Int32, UnsafeRawPointer?, Int32, DestructorFn?) -> Int32).self),
            let bindZeroblob = resolve("sqlite3_bind_zeroblob", as: (@convention(c) (OpaquePointer?, Int32, Int32) -> Int32).self)
        else {
            return nil
        }

        return Symbols(
            openV2: openV2,
            closeV2: closeV2,
            errmsg: errmsg,
            busyTimeout: busyTimeout,
            prepareV2: prepareV2,
            finalize: finalize,
            step: step,
            changes: changes,
            lastInsertRowid: lastInsertRowid,
            columnCount: columnCount,
            columnName: columnName,
            columnType: columnType,
            columnInt64: columnInt64,
            columnDouble: columnDouble,
            columnBytes: columnBytes,
            columnText: columnText,
            columnBlob: columnBlob,
            bindParameterCount: bindParameterCount,
            bindNull: bindNull,
            bindInt64: bindInt64,
            bindDouble: bindDouble,
            bindText: bindText,
            bindBlob: bindBlob,
            bindZeroblob: bindZeroblob
        )
    }
}
#else
private let sqliteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
#endif

/// Real C SQLite3 database engine with WAL mode, foreign keys, busy timeout,
/// prepared statement bindings (null/int64/double/text/blob), nested transactions,
/// savepoints, and schema migration execution.
public final class NativeSQLiteDatabase: SQLiteDatabase, @unchecked Sendable {
    public let path: String
    public let options: SQLiteOpenOptions

    private let lock = ReentrantDatabaseLock()
    private var db: OpaquePointer?
    private var transactionDepth: Int = 0
    #if !canImport(SQLite3)
    private let api: SQLite3Runtime.Symbols
    #endif

    public init(path: String = ":memory:", options: SQLiteOpenOptions = SQLiteOpenOptions()) throws {
        self.path = path
        self.options = options

        #if canImport(SQLite3)
        var flags: Int32 = SQLITE_OPEN_FULLMUTEX
        if options.readOnly {
            flags |= SQLITE_OPEN_READONLY
        } else {
            flags |= SQLITE_OPEN_READWRITE
            if options.createIfMissing {
                flags |= SQLITE_OPEN_CREATE
            }
        }

        var rawHandle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &rawHandle, flags, nil)
        guard rc == SQLITE_OK, let handle = rawHandle else {
            let message = rawHandle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 failed"
            if let rawHandle {
                sqlite3_close_v2(rawHandle)
            }
            throw SQLiteError.openFailed(path: path, code: rc, message: message)
        }
        #else
        guard let api = SQLite3Runtime.symbols else {
            throw SQLiteError.openFailed(path: path, code: -1, message: "Native SQLite3 shared library not available")
        }
        self.api = api

        var flags: Int32 = SQLite3Runtime.SQLITE_OPEN_FULLMUTEX
        if options.readOnly {
            flags |= SQLite3Runtime.SQLITE_OPEN_READONLY
        } else {
            flags |= SQLite3Runtime.SQLITE_OPEN_READWRITE
            if options.createIfMissing {
                flags |= SQLite3Runtime.SQLITE_OPEN_CREATE
            }
        }

        var rawHandle: OpaquePointer?
        let rc = path.withCString { cPath in
            api.openV2(cPath, &rawHandle, flags, nil)
        }
        guard rc == SQLite3Runtime.SQLITE_OK, let handle = rawHandle else {
            let message = rawHandle.flatMap { api.errmsg($0).map { String(cString: $0) } } ?? "sqlite3_open_v2 failed"
            if let rawHandle {
                _ = api.closeV2(rawHandle)
            }
            throw SQLiteError.openFailed(path: path, code: rc, message: message)
        }
        #endif

        self.db = handle

        do {
            #if canImport(SQLite3)
            sqlite3_busy_timeout(handle, options.busyTimeoutMs)
            #else
            _ = api.busyTimeout(handle, options.busyTimeoutMs)
            #endif
            _ = try execute("PRAGMA foreign_keys = \(options.foreignKeys ? "ON" : "OFF")")
            if !options.readOnly {
                if path != ":memory:" && !path.isEmpty {
                    _ = try query("PRAGMA journal_mode = \(options.journalMode)")
                }
                _ = try execute("PRAGMA synchronous = \(options.synchronous)")
            }
        } catch {
            #if canImport(SQLite3)
            sqlite3_close_v2(handle)
            #else
            _ = api.closeV2(handle)
            #endif
            self.db = nil
            throw error
        }
    }

    deinit {
        if let handle = db {
            #if canImport(SQLite3)
            sqlite3_close_v2(handle)
            #else
            _ = api.closeV2(handle)
            #endif
            db = nil
        }
    }

    public func close() throws {
        try lock.withLock {
            guard let handle = db else { return }
            #if canImport(SQLite3)
            let rc = sqlite3_close_v2(handle)
            let ok = SQLITE_OK
            #else
            let rc = api.closeV2(handle)
            let ok = SQLite3Runtime.SQLITE_OK
            #endif
            db = nil
            if rc != ok {
                throw SQLiteError.executionFailed(
                    sql: "CLOSE",
                    code: rc,
                    message: "sqlite3_close_v2 returned \(rc)"
                )
            }
        }
    }

    /// Queries the active SQLite journal mode (for example `"wal"` or `"memory"`).
    public func currentJournalMode() throws -> String {
        try queryScalar("PRAGMA journal_mode")?.stringValue ?? ""
    }

    @discardableResult
    public func execute(_ sql: String, parameters: [SQLiteValue]) throws -> SQLiteExecuteResult {
        try lock.withLock {
            let handle = try requireOpenHandle()
            let stmt = try prepare(handle: handle, sql: sql)
            defer { finalizeStatement(stmt) }
            try bind(parameters: parameters, to: stmt, handle: handle)

            #if canImport(SQLite3)
            let doneCode = SQLITE_DONE
            let rowCode = SQLITE_ROW
            #else
            let doneCode = SQLite3Runtime.SQLITE_DONE
            let rowCode = SQLite3Runtime.SQLITE_ROW
            #endif

            while true {
                let rc = stepStatement(stmt)
                if rc == doneCode {
                    break
                } else if rc == rowCode {
                    continue
                } else {
                    throw mapStepError(code: rc, sql: sql, handle: handle)
                }
            }
            #if canImport(SQLite3)
            return SQLiteExecuteResult(
                rowsAffected: Int(sqlite3_changes(handle)),
                lastInsertRowID: sqlite3_last_insert_rowid(handle)
            )
            #else
            return SQLiteExecuteResult(
                rowsAffected: Int(api.changes(handle)),
                lastInsertRowID: api.lastInsertRowid(handle)
            )
            #endif
        }
    }

    public func executeScript(_ sql: String) throws {
        try lock.withLock {
            let handle = try requireOpenHandle()
            let utf8 = Array(sql.utf8)
            var offset = 0
            #if canImport(SQLite3)
            let okCode = SQLITE_OK
            let doneCode = SQLITE_DONE
            let rowCode = SQLITE_ROW
            #else
            let okCode = SQLite3Runtime.SQLITE_OK
            let doneCode = SQLite3Runtime.SQLITE_DONE
            let rowCode = SQLite3Runtime.SQLITE_ROW
            #endif
            try utf8.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                while offset < utf8.count {
                    var stmt: OpaquePointer?
                    var tail: UnsafePointer<CChar>?
                    let remaining = Int32(utf8.count - offset)
                    let startPtr = UnsafeRawPointer(base.advanced(by: offset)).assumingMemoryBound(to: CChar.self)
                    #if canImport(SQLite3)
                    let prepRC = sqlite3_prepare_v2(handle, startPtr, remaining, &stmt, &tail)
                    #else
                    let prepRC = api.prepareV2(handle, startPtr, remaining, &stmt, &tail)
                    #endif
                    if prepRC != okCode {
                        let msg = lastErrorMessage(handle)
                        throw SQLiteError.prepareFailed(sql: sql, code: prepRC, message: msg)
                    }
                    if let stmt {
                        defer { finalizeStatement(stmt) }
                        while true {
                            let stepRC = stepStatement(stmt)
                            if stepRC == doneCode {
                                break
                            } else if stepRC == rowCode {
                                continue
                            } else {
                                throw mapStepError(code: stepRC, sql: sql, handle: handle)
                            }
                        }
                    }
                    if let tail {
                        let tailRaw = UnsafeRawPointer(tail)
                        let baseRaw = UnsafeRawPointer(base)
                        let nextOffset = baseRaw.distance(to: tailRaw)
                        if nextOffset <= offset {
                            break
                        }
                        offset = nextOffset
                    } else {
                        break
                    }
                }
            }
        }
    }

    public func query(_ sql: String, parameters: [SQLiteValue]) throws -> [SQLiteRow] {
        try lock.withLock {
            let handle = try requireOpenHandle()
            let stmt = try prepare(handle: handle, sql: sql)
            defer { finalizeStatement(stmt) }
            try bind(parameters: parameters, to: stmt, handle: handle)

            #if canImport(SQLite3)
            let columnCount = Int(sqlite3_column_count(stmt))
            let rowCode = SQLITE_ROW
            let doneCode = SQLITE_DONE
            #else
            let columnCount = Int(api.columnCount(stmt))
            let rowCode = SQLite3Runtime.SQLITE_ROW
            let doneCode = SQLite3Runtime.SQLITE_DONE
            #endif
            var columns: [String] = []
            columns.reserveCapacity(columnCount)
            for idx in 0..<columnCount {
                #if canImport(SQLite3)
                let cName = sqlite3_column_name(stmt, Int32(idx))
                #else
                let cName = api.columnName(stmt, Int32(idx))
                #endif
                if let cName {
                    columns.append(String(cString: cName))
                } else {
                    columns.append("col\(idx)")
                }
            }

            var rows: [SQLiteRow] = []
            while true {
                let rc = stepStatement(stmt)
                if rc == rowCode {
                    var values: [SQLiteValue] = []
                    values.reserveCapacity(columnCount)
                    for idx in 0..<columnCount {
                        values.append(readColumn(stmt: stmt, index: Int32(idx)))
                    }
                    rows.append(SQLiteRow(columns: columns, values: values))
                } else if rc == doneCode {
                    break
                } else {
                    throw mapStepError(code: rc, sql: sql, handle: handle)
                }
            }
            return rows
        }
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock {
            _ = try requireOpenHandle()
            let depth = transactionDepth
            if depth == 0 {
                _ = try execute(options.readOnly ? "BEGIN" : "BEGIN IMMEDIATE")
            } else {
                _ = try execute("SAVEPOINT _opencode_tx_\(depth)")
            }
            transactionDepth += 1
            do {
                let result = try body()
                transactionDepth -= 1
                if depth == 0 {
                    _ = try execute("COMMIT")
                } else {
                    _ = try execute("RELEASE SAVEPOINT _opencode_tx_\(depth)")
                }
                return result
            } catch {
                transactionDepth -= 1
                if depth == 0 {
                    _ = try? execute("ROLLBACK")
                } else {
                    _ = try? execute("ROLLBACK TO SAVEPOINT _opencode_tx_\(depth)")
                    _ = try? execute("RELEASE SAVEPOINT _opencode_tx_\(depth)")
                }
                throw error
            }
        }
    }

    public func savepoint<T>(_ name: String, _ body: () throws -> T) throws -> T {
        try validateSavepointName(name)
        return try lock.withLock {
            _ = try requireOpenHandle()
            _ = try execute("SAVEPOINT \"\(name)\"")
            do {
                let result = try body()
                _ = try execute("RELEASE SAVEPOINT \"\(name)\"")
                return result
            } catch {
                _ = try? execute("ROLLBACK TO SAVEPOINT \"\(name)\"")
                _ = try? execute("RELEASE SAVEPOINT \"\(name)\"")
                throw error
            }
        }
    }

    private func requireOpenHandle() throws -> OpaquePointer {
        guard let handle = db else {
            throw SQLiteError.databaseClosed
        }
        return handle
    }

    private func finalizeStatement(_ stmt: OpaquePointer) {
        #if canImport(SQLite3)
        sqlite3_finalize(stmt)
        #else
        _ = api.finalize(stmt)
        #endif
    }

    private func stepStatement(_ stmt: OpaquePointer) -> Int32 {
        #if canImport(SQLite3)
        sqlite3_step(stmt)
        #else
        api.step(stmt)
        #endif
    }

    private func prepare(handle: OpaquePointer, sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        #if canImport(SQLite3)
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        let okCode = SQLITE_OK
        #else
        let rc = sql.withCString { cSql in
            api.prepareV2(handle, cSql, -1, &stmt, nil)
        }
        let okCode = SQLite3Runtime.SQLITE_OK
        #endif
        guard rc == okCode, let prepared = stmt else {
            throw SQLiteError.prepareFailed(sql: sql, code: rc, message: lastErrorMessage(handle))
        }
        return prepared
    }

    private func bind(parameters: [SQLiteValue], to stmt: OpaquePointer, handle: OpaquePointer) throws {
        #if canImport(SQLite3)
        let expected = Int(sqlite3_bind_parameter_count(stmt))
        let okCode = SQLITE_OK
        #else
        let expected = Int(api.bindParameterCount(stmt))
        let okCode = SQLite3Runtime.SQLITE_OK
        #endif
        guard parameters.count == expected else {
            throw SQLiteError.invalidParameter(
                "Expected \(expected) SQL parameter(s), got \(parameters.count)"
            )
        }
        for (offset, value) in parameters.enumerated() {
            let idx = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .null:
                #if canImport(SQLite3)
                rc = sqlite3_bind_null(stmt, idx)
                #else
                rc = api.bindNull(stmt, idx)
                #endif
            case .integer(let v):
                #if canImport(SQLite3)
                rc = sqlite3_bind_int64(stmt, idx, v)
                #else
                rc = api.bindInt64(stmt, idx, v)
                #endif
            case .real(let v):
                #if canImport(SQLite3)
                rc = sqlite3_bind_double(stmt, idx, v)
                #else
                rc = api.bindDouble(stmt, idx, v)
                #endif
            case .text(let s):
                let utf8 = Array(s.utf8)
                if utf8.isEmpty {
                    #if canImport(SQLite3)
                    rc = sqlite3_bind_text(stmt, idx, "", 0, sqliteTransientDestructor)
                    #else
                    var nul: CChar = 0
                    rc = withUnsafePointer(to: &nul) { ptr in
                        api.bindText(stmt, idx, ptr, 0, SQLite3Runtime.transientDestructor)
                    }
                    #endif
                } else {
                    rc = utf8.withUnsafeBufferPointer { buf in
                        let ptr = UnsafeRawPointer(buf.baseAddress!).assumingMemoryBound(to: CChar.self)
                        #if canImport(SQLite3)
                        return sqlite3_bind_text(stmt, idx, ptr, Int32(buf.count), sqliteTransientDestructor)
                        #else
                        return api.bindText(stmt, idx, ptr, Int32(buf.count), SQLite3Runtime.transientDestructor)
                        #endif
                    }
                }
            case .blob(let bytes):
                if bytes.isEmpty {
                    #if canImport(SQLite3)
                    rc = sqlite3_bind_zeroblob(stmt, idx, 0)
                    #else
                    rc = api.bindZeroblob(stmt, idx, 0)
                    #endif
                } else {
                    rc = bytes.withUnsafeBytes { buf in
                        #if canImport(SQLite3)
                        return sqlite3_bind_blob(stmt, idx, buf.baseAddress, Int32(bytes.count), sqliteTransientDestructor)
                        #else
                        return api.bindBlob(stmt, idx, buf.baseAddress, Int32(bytes.count), SQLite3Runtime.transientDestructor)
                        #endif
                    }
                }
            }
            if rc != okCode {
                throw SQLiteError.bindFailed(index: idx, code: rc, message: lastErrorMessage(handle))
            }
        }
    }

    private func readColumn(stmt: OpaquePointer, index: Int32) -> SQLiteValue {
        #if canImport(SQLite3)
        let colType = sqlite3_column_type(stmt, index)
        let nullType = SQLITE_NULL
        let intType = SQLITE_INTEGER
        let floatType = SQLITE_FLOAT
        let textType = SQLITE_TEXT
        let blobType = SQLITE_BLOB
        #else
        let colType = api.columnType(stmt, index)
        let nullType = SQLite3Runtime.SQLITE_NULL
        let intType = SQLite3Runtime.SQLITE_INTEGER
        let floatType = SQLite3Runtime.SQLITE_FLOAT
        let textType = SQLite3Runtime.SQLITE_TEXT
        let blobType = SQLite3Runtime.SQLITE_BLOB
        #endif
        switch colType {
        case nullType:
            return .null
        case intType:
            #if canImport(SQLite3)
            return .integer(sqlite3_column_int64(stmt, index))
            #else
            return .integer(api.columnInt64(stmt, index))
            #endif
        case floatType:
            #if canImport(SQLite3)
            return .real(sqlite3_column_double(stmt, index))
            #else
            return .real(api.columnDouble(stmt, index))
            #endif
        case textType:
            #if canImport(SQLite3)
            let byteCount = Int(sqlite3_column_bytes(stmt, index))
            let raw = sqlite3_column_text(stmt, index)
            #else
            let byteCount = Int(api.columnBytes(stmt, index))
            let raw = api.columnText(stmt, index)
            #endif
            guard byteCount > 0, let raw else {
                return .text("")
            }
            let bytes = Array(UnsafeBufferPointer(start: raw, count: byteCount))
            return .text(String(decoding: bytes, as: UTF8.self))
        case blobType:
            #if canImport(SQLite3)
            let byteCount = Int(sqlite3_column_bytes(stmt, index))
            let raw = sqlite3_column_blob(stmt, index)
            #else
            let byteCount = Int(api.columnBytes(stmt, index))
            let raw = api.columnBlob(stmt, index)
            #endif
            guard byteCount > 0, let raw else {
                return .blob([])
            }
            let ptr = raw.assumingMemoryBound(to: UInt8.self)
            return .blob(Array(UnsafeBufferPointer(start: ptr, count: byteCount)))
        default:
            return .null
        }
    }

    private func mapStepError(code: Int32, sql: String, handle: OpaquePointer) -> SQLiteError {
        let message = lastErrorMessage(handle)
        #if canImport(SQLite3)
        let constraintCode = SQLITE_CONSTRAINT
        #else
        let constraintCode = SQLite3Runtime.SQLITE_CONSTRAINT
        #endif
        if code == constraintCode || (code & 0xFF) == constraintCode {
            return .constraintViolation(code: code, message: message)
        }
        return .stepFailed(sql: sql, code: code, message: message)
    }

    private func lastErrorMessage(_ handle: OpaquePointer) -> String {
        #if canImport(SQLite3)
        return sqlite3_errmsg(handle).map { String(cString: $0) } ?? "SQLite error"
        #else
        return api.errmsg(handle).map { String(cString: $0) } ?? "SQLite error"
        #endif
    }
}
#endif

// MARK: - Portable In-Memory SQLite Fallback (WASI & SQLite3-free targets)

/// Pure-Swift in-memory SQLite engine fallback for WASI and targets without system C SQLite3.
/// Supports PRAGMA, CREATE/DROP TABLE, parameterized INSERT/SELECT/UPDATE/DELETE,
/// primary/foreign key enforcement, transactions, savepoints, and schema migrations.
public final class InMemorySQLiteFallback: SQLiteDatabase, @unchecked Sendable {
    private struct ColumnSchema: Sendable {
        let name: String
        let isPrimaryKey: Bool
        let isNotNull: Bool
        let isUnique: Bool
        let referencesTable: String?
        let referencesColumn: String?
    }

    private struct TableData: Sendable {
        var name: String
        var columns: [ColumnSchema]
        var rows: [[SQLiteValue]]
        var nextRowID: Int64
    }

    private struct Snapshot: Sendable {
        var tables: [String: TableData]
        var pragmas: [String: String]
        var lastInsertRowID: Int64
    }

    public let path: String
    public let options: SQLiteOpenOptions

    private let lock = ReentrantDatabaseLock()
    private var closed = false
    private var tables: [String: TableData] = [:]
    private var pragmas: [String: String] = [:]
    private var lastInsertRowID: Int64 = 0
    private var savepointStack: [(name: String, snapshot: Snapshot)] = []

    public init(path: String = ":memory:", options: SQLiteOpenOptions = SQLiteOpenOptions()) throws {
        self.path = path
        self.options = options
        self.pragmas["journal_mode"] = path == ":memory:" ? "memory" : options.journalMode.lowercased()
        self.pragmas["foreign_keys"] = options.foreignKeys ? "1" : "0"
        self.pragmas["busy_timeout"] = String(options.busyTimeoutMs)
        self.pragmas["synchronous"] = options.synchronous.lowercased()
    }

    public func close() throws {
        lock.withLock {
            closed = true
            tables.removeAll()
            savepointStack.removeAll()
        }
    }

    @discardableResult
    public func execute(_ sql: String, parameters: [SQLiteValue]) throws -> SQLiteExecuteResult {
        try lock.withLock {
            guard !closed else { throw SQLiteError.databaseClosed }
            let (_, result) = try runSingleStatement(sql, parameters: parameters)
            return result
        }
    }

    public func executeScript(_ sql: String) throws {
        try lock.withLock {
            guard !closed else { throw SQLiteError.databaseClosed }
            for statement in splitStatements(sql) {
                let trimmed = trimWhitespace(stripLeadingComments(statement))
                if trimmed.isEmpty { continue }
                _ = try runSingleStatement(trimmed, parameters: [])
            }
        }
    }

    public func query(_ sql: String, parameters: [SQLiteValue]) throws -> [SQLiteRow] {
        try lock.withLock {
            guard !closed else { throw SQLiteError.databaseClosed }
            let (rows, _) = try runSingleStatement(sql, parameters: parameters)
            return rows
        }
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock {
            guard !closed else { throw SQLiteError.databaseClosed }
            let snap = captureSnapshot()
            savepointStack.append(("_tx", snap))
            do {
                let value = try body()
                _ = savepointStack.popLast()
                return value
            } catch {
                if let saved = savepointStack.popLast() {
                    restoreSnapshot(saved.snapshot)
                }
                throw error
            }
        }
    }

    public func savepoint<T>(_ name: String, _ body: () throws -> T) throws -> T {
        try validateSavepointName(name)
        return try lock.withLock {
            guard !closed else { throw SQLiteError.databaseClosed }
            let snap = captureSnapshot()
            savepointStack.append((name, snap))
            do {
                let value = try body()
                if let idx = savepointStack.lastIndex(where: { $0.name == name }) {
                    savepointStack.removeSubrange(idx...)
                }
                return value
            } catch {
                if let idx = savepointStack.lastIndex(where: { $0.name == name }) {
                    restoreSnapshot(savepointStack[idx].snapshot)
                    savepointStack.removeSubrange(idx...)
                }
                throw error
            }
        }
    }

    private func captureSnapshot() -> Snapshot {
        Snapshot(tables: tables, pragmas: pragmas, lastInsertRowID: lastInsertRowID)
    }

    private func restoreSnapshot(_ snapshot: Snapshot) {
        self.tables = snapshot.tables
        self.pragmas = snapshot.pragmas
        self.lastInsertRowID = snapshot.lastInsertRowID
    }

    private func runSingleStatement(
        _ rawSQL: String,
        parameters: [SQLiteValue]
    ) throws -> ([SQLiteRow], SQLiteExecuteResult) {
        var sql = trimWhitespace(stripLeadingComments(rawSQL))
        while sql.hasSuffix(";") {
            sql.removeLast()
            sql = trimWhitespace(sql)
        }
        if sql.isEmpty {
            return ([], SQLiteExecuteResult(rowsAffected: 0, lastInsertRowID: lastInsertRowID))
        }

        let upper = sql.uppercased()
        if upper.hasPrefix("PRAGMA ") {
            return try handlePragma(sql)
        }
        if upper.hasPrefix("BEGIN") {
            savepointStack.append(("_sql_tx", captureSnapshot()))
            return ([], SQLiteExecuteResult(rowsAffected: 0, lastInsertRowID: lastInsertRowID))
        }
        if upper == "COMMIT" || upper == "END" || upper == "COMMIT TRANSACTION" {
            _ = savepointStack.popLast()
            return ([], SQLiteExecuteResult(rowsAffected: 0, lastInsertRowID: lastInsertRowID))
        }
        if upper.hasPrefix("ROLLBACK TO") {
            let spName = sql.split(whereSeparator: \.isWhitespace).last.map { trimQuotesAndSpace(String($0)) } ?? ""
            if let idx = savepointStack.lastIndex(where: { $0.name == spName }) {
                restoreSnapshot(savepointStack[idx].snapshot)
            }
            return ([], SQLiteExecuteResult(rowsAffected: 0, lastInsertRowID: lastInsertRowID))
        }
        if upper == "ROLLBACK" || upper == "ROLLBACK TRANSACTION" {
            if let saved = savepointStack.popLast() {
                restoreSnapshot(saved.snapshot)
            }
            return ([], SQLiteExecuteResult(rowsAffected: 0, lastInsertRowID: lastInsertRowID))
        }
        if upper.hasPrefix("SAVEPOINT ") {
            let spName = trimQuotesAndSpace(String(sql.dropFirst("SAVEPOINT ".count)))
            savepointStack.append((spName, captureSnapshot()))
            return ([], SQLiteExecuteResult(rowsAffected: 0, lastInsertRowID: lastInsertRowID))
        }
        if upper.hasPrefix("RELEASE ") {
            let spName = sql.split(whereSeparator: \.isWhitespace).last.map { trimQuotesAndSpace(String($0)) } ?? ""
            if let idx = savepointStack.lastIndex(where: { $0.name == spName }) {
                savepointStack.removeSubrange(idx...)
            }
            return ([], SQLiteExecuteResult(rowsAffected: 0, lastInsertRowID: lastInsertRowID))
        }
        if upper.hasPrefix("CREATE TABLE") {
            try handleCreateTable(sql)
            return ([], SQLiteExecuteResult(rowsAffected: 0, lastInsertRowID: lastInsertRowID))
        }
        if upper.hasPrefix("CREATE INDEX") || upper.hasPrefix("CREATE UNIQUE INDEX") {
            return ([], SQLiteExecuteResult(rowsAffected: 0, lastInsertRowID: lastInsertRowID))
        }
        if upper.hasPrefix("DROP TABLE") {
            try handleDropTable(sql)
            return ([], SQLiteExecuteResult(rowsAffected: 0, lastInsertRowID: lastInsertRowID))
        }
        if upper.hasPrefix("INSERT ") {
            let result = try handleInsert(sql, parameters: parameters)
            return ([], result)
        }
        if upper.hasPrefix("SELECT ") {
            let rows = try handleSelect(sql, parameters: parameters)
            return (rows, SQLiteExecuteResult(rowsAffected: 0, lastInsertRowID: lastInsertRowID))
        }
        if upper.hasPrefix("UPDATE ") {
            let result = try handleUpdate(sql, parameters: parameters)
            return ([], result)
        }
        if upper.hasPrefix("DELETE ") {
            let result = try handleDelete(sql, parameters: parameters)
            return ([], result)
        }
        throw SQLiteError.unsupportedSQL(sql)
    }

    private func handlePragma(_ sql: String) throws -> ([SQLiteRow], SQLiteExecuteResult) {
        let rest = trimWhitespace(sql.dropFirst("PRAGMA ".count))
        if let eq = rest.firstIndex(of: "=") {
            let key = trimWhitespace(rest[..<eq]).lowercased()
            var val = trimWhitespace(rest[rest.index(after: eq)...])
            if val.uppercased() == "ON" { val = "1" }
            if val.uppercased() == "OFF" { val = "0" }
            if key == "journal_mode" { val = val.lowercased() }
            pragmas[key] = val
            let row = SQLiteRow(columns: [key], values: [.text(val)])
            return ([row], SQLiteExecuteResult(rowsAffected: 0, lastInsertRowID: lastInsertRowID))
        } else {
            let key = rest.lowercased()
            let val = pragmas[key] ?? ""
            let value: SQLiteValue = Int64(val).map { .integer($0) } ?? .text(val)
            let row = SQLiteRow(columns: [key], values: [value])
            return ([row], SQLiteExecuteResult(rowsAffected: 0, lastInsertRowID: lastInsertRowID))
        }
    }

    private func handleCreateTable(_ sql: String) throws {
        guard let openParen = sql.firstIndex(of: "("),
              let closeParen = sql.lastIndex(of: ")"),
              openParen < closeParen else {
            throw SQLiteError.prepareFailed(sql: sql, code: 1, message: "Malformed CREATE TABLE")
        }
        let header = trimWhitespace(sql[..<openParen])
        let headerTokens = header.split(whereSeparator: \.isWhitespace).map(String.init)
        let ifNotExists = findASCII("IF NOT EXISTS", in: header.uppercased()) != nil
        guard let rawTableName = headerTokens.last else {
            throw SQLiteError.prepareFailed(sql: sql, code: 1, message: "Missing table name")
        }
        let tableName = unquoteIdentifier(rawTableName)
        let key = tableName.lowercased()
        if tables[key] != nil {
            if ifNotExists { return }
            throw SQLiteError.executionFailed(sql: sql, code: 1, message: "table \(tableName) already exists")
        }

        let body = String(sql[sql.index(after: openParen)..<closeParen])
        let defs = splitTopLevelComma(body)
        var columns: [ColumnSchema] = []
        var tableForeignKeys: [(col: String, refTable: String, refCol: String)] = []

        for rawDef in defs {
            let def = trimWhitespace(rawDef)
            if def.isEmpty { continue }
            let upperDef = def.uppercased()
            if upperDef.hasPrefix("FOREIGN KEY") {
                if let fk = parseTableForeignKey(def) {
                    tableForeignKeys.append(fk)
                }
                continue
            }
            if upperDef.hasPrefix("PRIMARY KEY") || upperDef.hasPrefix("UNIQUE") || upperDef.hasPrefix("CHECK") || upperDef.hasPrefix("CONSTRAINT") {
                continue
            }
            let parts = def.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let first = parts.first else { continue }
            let colName = unquoteIdentifier(first)
            let isPK = findASCII("PRIMARY KEY", in: upperDef) != nil
            let isNotNull = findASCII("NOT NULL", in: upperDef) != nil
            let isUnique = findASCII("UNIQUE", in: upperDef) != nil
            var refTable: String?
            var refCol: String?
            if let refRange = findASCII("REFERENCES ", in: upperDef) {
                let offset = upperDef.distance(from: upperDef.startIndex, to: refRange.upperBound)
                let start = def.index(def.startIndex, offsetBy: offset)
                let afterRef = trimWhitespace(def[start...])
                if let lp = afterRef.firstIndex(of: "("), let rp = afterRef.firstIndex(of: ")"), lp < rp {
                    refTable = unquoteIdentifier(trimWhitespace(afterRef[..<lp]))
                    refCol = unquoteIdentifier(trimWhitespace(afterRef[afterRef.index(after: lp)..<rp]))
                }
            }
            columns.append(ColumnSchema(
                name: colName,
                isPrimaryKey: isPK,
                isNotNull: isNotNull,
                isUnique: isUnique,
                referencesTable: refTable,
                referencesColumn: refCol
            ))
        }

        for fk in tableForeignKeys {
            if let idx = columns.firstIndex(where: { $0.name.lowercased() == fk.col.lowercased() }) {
                let existing = columns[idx]
                columns[idx] = ColumnSchema(
                    name: existing.name,
                    isPrimaryKey: existing.isPrimaryKey,
                    isNotNull: existing.isNotNull,
                    isUnique: existing.isUnique,
                    referencesTable: fk.refTable,
                    referencesColumn: fk.refCol
                )
            }
        }

        tables[key] = TableData(name: tableName, columns: columns, rows: [], nextRowID: 1)
    }

    private func parseTableForeignKey(_ def: String) -> (col: String, refTable: String, refCol: String)? {
        let upper = def.uppercased()
        guard let fkRange = findASCII("FOREIGN KEY", in: upper),
              let refRange = findASCII("REFERENCES ", in: upper) else { return nil }
        let fkEndOffset = upper.distance(from: upper.startIndex, to: fkRange.upperBound)
        let refStartOffset = upper.distance(from: upper.startIndex, to: refRange.lowerBound)
        let refEndOffset = upper.distance(from: upper.startIndex, to: refRange.upperBound)
        let fkEnd = def.index(def.startIndex, offsetBy: fkEndOffset)
        let refStart = def.index(def.startIndex, offsetBy: refStartOffset)
        let refEnd = def.index(def.startIndex, offsetBy: refEndOffset)
        let colSection = String(def[fkEnd..<refStart])
        guard let lp1 = colSection.firstIndex(of: "("), let rp1 = colSection.firstIndex(of: ")"), lp1 < rp1 else { return nil }
        let col = unquoteIdentifier(trimWhitespace(colSection[colSection.index(after: lp1)..<rp1]))
        let refSection = trimWhitespace(def[refEnd...])
        guard let lp2 = refSection.firstIndex(of: "("), let rp2 = refSection.firstIndex(of: ")"), lp2 < rp2 else { return nil }
        let refTable = unquoteIdentifier(trimWhitespace(refSection[..<lp2]))
        let refCol = unquoteIdentifier(trimWhitespace(refSection[refSection.index(after: lp2)..<rp2]))
        return (col, refTable, refCol)
    }

    private func handleDropTable(_ sql: String) throws {
        let ifExists = findASCII("IF EXISTS", in: sql.uppercased()) != nil
        guard let last = sql.split(whereSeparator: \.isWhitespace).last else { return }
        let name = unquoteIdentifier(String(last))
        let key = name.lowercased()
        if tables.removeValue(forKey: key) == nil && !ifExists {
            throw SQLiteError.executionFailed(sql: sql, code: 1, message: "no such table: \(name)")
        }
    }

    private func handleInsert(_ sql: String, parameters: [SQLiteValue]) throws -> SQLiteExecuteResult {
        let upper = sql.uppercased()
        let orReplace = findASCII("OR REPLACE", in: upper) != nil
        let orIgnore = findASCII("OR IGNORE", in: upper) != nil

        guard let intoRange = findASCII("INTO ", in: upper),
              let valuesRange = findASCII("VALUES", in: upper) else {
            throw SQLiteError.prepareFailed(sql: sql, code: 1, message: "Malformed INSERT")
        }

        let intoEnd = sql.index(sql.startIndex, offsetBy: upper.distance(from: upper.startIndex, to: intoRange.upperBound))
        let valStart = sql.index(sql.startIndex, offsetBy: upper.distance(from: upper.startIndex, to: valuesRange.lowerBound))
        let valEnd = sql.index(sql.startIndex, offsetBy: upper.distance(from: upper.startIndex, to: valuesRange.upperBound))

        let targetPart = trimWhitespace(sql[intoEnd..<valStart])
        let tableName: String
        let specifiedColumns: [String]?
        if let lp = targetPart.firstIndex(of: "("), let rp = targetPart.lastIndex(of: ")"), lp < rp {
            tableName = unquoteIdentifier(trimWhitespace(targetPart[..<lp]))
            let colsStr = String(targetPart[targetPart.index(after: lp)..<rp])
            specifiedColumns = splitTopLevelComma(colsStr).map { unquoteIdentifier(trimWhitespace($0)) }
        } else {
            tableName = unquoteIdentifier(targetPart)
            specifiedColumns = nil
        }

        let key = tableName.lowercased()
        guard var table = tables[key] else {
            throw SQLiteError.executionFailed(sql: sql, code: 1, message: "no such table: \(tableName)")
        }

        let valuesPart = trimWhitespace(sql[valEnd...])
        let tupleStrings = splitValueTuples(valuesPart)
        var paramIdx = 0
        var inserted = 0
        let fkEnabled = pragmas["foreign_keys"] == "1"

        for tuple in tupleStrings {
            let exprs = splitTopLevelComma(tuple)
            let rawValues = try exprs.map { try evaluateExpression($0, parameters: parameters, paramIndex: &paramIdx, row: nil, columns: []) }
            var fullRow = [SQLiteValue](repeating: .null, count: table.columns.count)
            if let specifiedColumns {
                guard specifiedColumns.count == rawValues.count else {
                    throw SQLiteError.invalidParameter("Column count does not match value count")
                }
                for (colName, val) in zip(specifiedColumns, rawValues) {
                    guard let colIdx = table.columns.firstIndex(where: { $0.name.lowercased() == colName.lowercased() }) else {
                        throw SQLiteError.executionFailed(sql: sql, code: 1, message: "no such column: \(colName)")
                    }
                    fullRow[colIdx] = val
                }
            } else {
                guard rawValues.count == table.columns.count else {
                    throw SQLiteError.invalidParameter("Value count does not match table column count")
                }
                fullRow = rawValues
            }

            // Assign rowid for null INTEGER PRIMARY KEY
            let rowID = table.nextRowID
            for (idx, col) in table.columns.enumerated() where col.isPrimaryKey && fullRow[idx].isNull {
                fullRow[idx] = .integer(rowID)
            }

            // Check NOT NULL constraints
            for (idx, col) in table.columns.enumerated() where col.isNotNull && fullRow[idx].isNull {
                throw SQLiteError.constraintViolation(code: 19, message: "NOT NULL constraint failed: \(table.name).\(col.name)")
            }

            // Check foreign keys
            if fkEnabled {
                for (idx, col) in table.columns.enumerated() {
                    if let refTable = col.referencesTable, let refCol = col.referencesColumn, !fullRow[idx].isNull {
                        guard let parent = tables[refTable.lowercased()],
                              let parentColIdx = parent.columns.firstIndex(where: { $0.name.lowercased() == refCol.lowercased() }),
                              parent.rows.contains(where: { $0[parentColIdx] == fullRow[idx] }) else {
                            throw SQLiteError.constraintViolation(code: 19, message: "FOREIGN KEY constraint failed")
                        }
                    }
                }
            }

            // Check PK / UNIQUE collisions
            var conflictIndex: Int?
            for (colIdx, col) in table.columns.enumerated() where col.isPrimaryKey || col.isUnique {
                let candidate = fullRow[colIdx]
                if candidate.isNull { continue }
                if let existingIdx = table.rows.firstIndex(where: { $0[colIdx] == candidate }) {
                    conflictIndex = existingIdx
                    break
                }
            }

            if let conflictIndex {
                if orIgnore {
                    continue
                } else if orReplace {
                    table.rows[conflictIndex] = fullRow
                    inserted += 1
                    lastInsertRowID = rowID
                    table.nextRowID += 1
                } else {
                    throw SQLiteError.constraintViolation(code: 19, message: "UNIQUE/PRIMARY KEY constraint failed on \(table.name)")
                }
            } else {
                table.rows.append(fullRow)
                inserted += 1
                lastInsertRowID = rowID
                table.nextRowID += 1
            }
        }

        tables[key] = table
        return SQLiteExecuteResult(rowsAffected: inserted, lastInsertRowID: lastInsertRowID)
    }

    private func handleSelect(_ sql: String, parameters: [SQLiteValue]) throws -> [SQLiteRow] {
        var paramIdx = 0

        guard let fromRange = findTopLevelKeyword("FROM", in: sql) else {
            let selectPart = trimWhitespace(sql.dropFirst("SELECT ".count))
            let exprs = splitTopLevelComma(selectPart)
            var cols: [String] = []
            var vals: [SQLiteValue] = []
            for expr in exprs {
                let trimmed = trimWhitespace(expr)
                cols.append(trimmed)
                vals.append(try evaluateExpression(trimmed, parameters: parameters, paramIndex: &paramIdx, row: nil, columns: []))
            }
            return [SQLiteRow(columns: cols, values: vals)]
        }

        let selectList = trimWhitespace(sql[sql.index(sql.startIndex, offsetBy: 6)..<fromRange.lowerBound])
        let afterFrom = trimWhitespace(sql[fromRange.upperBound...])

        let whereRange = findTopLevelKeyword("WHERE", in: afterFrom)
        let orderRange = findTopLevelKeyword("ORDER BY", in: afterFrom)
        let limitRange = findTopLevelKeyword("LIMIT", in: afterFrom)

        let tableEnd = whereRange?.lowerBound ?? orderRange?.lowerBound ?? limitRange?.lowerBound ?? afterFrom.endIndex
        let tableName = unquoteIdentifier(trimWhitespace(afterFrom[..<tableEnd]))
        guard let table = tables[tableName.lowercased()] else {
            throw SQLiteError.executionFailed(sql: sql, code: 1, message: "no such table: \(tableName)")
        }

        let whereClause: String? = whereRange.map { range in
            let end = orderRange?.lowerBound ?? limitRange?.lowerBound ?? afterFrom.endIndex
            return trimWhitespace(afterFrom[range.upperBound..<end])
        }
        let orderClause: String? = orderRange.map { range in
            let end = limitRange?.lowerBound ?? afterFrom.endIndex
            return trimWhitespace(afterFrom[range.upperBound..<end])
        }
        let limitClause: String? = limitRange.map { range in
            trimWhitespace(afterFrom[range.upperBound...])
        }

        let colNames = table.columns.map(\.name)
        var matchedRows: [[SQLiteValue]] = []
        if let whereClause {
            let predicates = try parseWhereClause(whereClause, parameters: parameters, paramIndex: &paramIdx)
            for row in table.rows {
                if evaluatePredicates(predicates, row: row, columns: colNames) {
                    matchedRows.append(row)
                }
            }
        } else {
            matchedRows = table.rows
        }

        if let orderClause {
            let parts = orderClause.split(whereSeparator: \.isWhitespace).map(String.init)
            if let colPart = parts.first {
                let orderCol = unquoteIdentifier(colPart)
                let desc = parts.count > 1 && parts[1].uppercased() == "DESC"
                if let colIdx = colNames.firstIndex(where: { $0.lowercased() == orderCol.lowercased() }) {
                    matchedRows.sort { lhs, rhs in
                        let cmp = compareValues(lhs[colIdx], rhs[colIdx])
                        return desc ? cmp > 0 : cmp < 0
                    }
                }
            }
        }

        if let limitClause, let limit = Int(limitClause) {
            matchedRows = Array(matchedRows.prefix(max(0, limit)))
        }

        if selectList.uppercased() == "COUNT(*)" {
            return [SQLiteRow(columns: ["COUNT(*)"], values: [.integer(Int64(matchedRows.count))])]
        }

        if selectList == "*" {
            return matchedRows.map { SQLiteRow(columns: colNames, values: $0) }
        }

        let requestedCols = splitTopLevelComma(selectList).map { item -> (expr: String, alias: String) in
            let trimmed = trimWhitespace(item)
            let upTrimmed = trimmed.uppercased()
            if let asRange = findASCII(" AS ", in: upTrimmed) {
                let startOff = upTrimmed.distance(from: upTrimmed.startIndex, to: asRange.lowerBound)
                let endOff = upTrimmed.distance(from: upTrimmed.startIndex, to: asRange.upperBound)
                let expr = trimWhitespace(trimmed[..<trimmed.index(trimmed.startIndex, offsetBy: startOff)])
                let alias = unquoteIdentifier(trimWhitespace(trimmed[trimmed.index(trimmed.startIndex, offsetBy: endOff)...]))
                return (expr, alias)
            }
            let clean = unquoteIdentifier(trimmed)
            return (clean, clean)
        }

        var resultRows: [SQLiteRow] = []
        for row in matchedRows {
            var outCols: [String] = []
            var outVals: [SQLiteValue] = []
            for req in requestedCols {
                outCols.append(req.alias)
                if let colIdx = colNames.firstIndex(where: { $0.lowercased() == req.expr.lowercased() }) {
                    outVals.append(row[colIdx])
                } else {
                    var unusedIdx = paramIdx
                    outVals.append(try evaluateExpression(req.expr, parameters: parameters, paramIndex: &unusedIdx, row: row, columns: colNames))
                }
            }
            resultRows.append(SQLiteRow(columns: outCols, values: outVals))
        }
        return resultRows
    }

    private func handleUpdate(_ sql: String, parameters: [SQLiteValue]) throws -> SQLiteExecuteResult {
        guard let setRange = findTopLevelKeyword("SET", in: sql) else {
            throw SQLiteError.prepareFailed(sql: sql, code: 1, message: "Malformed UPDATE")
        }
        let tableName = unquoteIdentifier(trimWhitespace(sql[sql.index(sql.startIndex, offsetBy: 6)..<setRange.lowerBound]))
        let key = tableName.lowercased()
        guard var table = tables[key] else {
            throw SQLiteError.executionFailed(sql: sql, code: 1, message: "no such table: \(tableName)")
        }

        let afterSet = trimWhitespace(sql[setRange.upperBound...])
        let whereRange = findTopLevelKeyword("WHERE", in: afterSet)
        let setClause = trimWhitespace(afterSet[..<(whereRange?.lowerBound ?? afterSet.endIndex)])
        let whereClause = whereRange.map { trimWhitespace(afterSet[$0.upperBound...]) }

        var paramIdx = 0
        let assignments = try splitTopLevelComma(setClause).map { pair -> (colIdx: Int, value: SQLiteValue) in
            guard let eq = pair.firstIndex(of: "=") else {
                throw SQLiteError.prepareFailed(sql: sql, code: 1, message: "Malformed SET assignment")
            }
            let colName = unquoteIdentifier(trimWhitespace(pair[..<eq]))
            let valExpr = trimWhitespace(pair[pair.index(after: eq)...])
            guard let colIdx = table.columns.firstIndex(where: { $0.name.lowercased() == colName.lowercased() }) else {
                throw SQLiteError.executionFailed(sql: sql, code: 1, message: "no such column: \(colName)")
            }
            let value = try evaluateExpression(valExpr, parameters: parameters, paramIndex: &paramIdx, row: nil, columns: [])
            return (colIdx, value)
        }

        let colNames = table.columns.map(\.name)
        let predicates = try whereClause.map { try parseWhereClause($0, parameters: parameters, paramIndex: &paramIdx) } ?? []

        var affected = 0
        for rowIdx in table.rows.indices {
            if predicates.isEmpty || evaluatePredicates(predicates, row: table.rows[rowIdx], columns: colNames) {
                for (colIdx, value) in assignments {
                    table.rows[rowIdx][colIdx] = value
                }
                affected += 1
            }
        }
        tables[key] = table
        return SQLiteExecuteResult(rowsAffected: affected, lastInsertRowID: lastInsertRowID)
    }

    private func handleDelete(_ sql: String, parameters: [SQLiteValue]) throws -> SQLiteExecuteResult {
        guard let fromRange = findTopLevelKeyword("FROM", in: sql) else {
            throw SQLiteError.prepareFailed(sql: sql, code: 1, message: "Malformed DELETE")
        }
        let afterFrom = trimWhitespace(sql[fromRange.upperBound...])
        let whereRange = findTopLevelKeyword("WHERE", in: afterFrom)
        let tableName = unquoteIdentifier(trimWhitespace(afterFrom[..<(whereRange?.lowerBound ?? afterFrom.endIndex)]))
        let key = tableName.lowercased()
        guard var table = tables[key] else {
            throw SQLiteError.executionFailed(sql: sql, code: 1, message: "no such table: \(tableName)")
        }

        let colNames = table.columns.map(\.name)
        var paramIdx = 0
        let predicates = try whereRange.map {
            try parseWhereClause(trimWhitespace(afterFrom[$0.upperBound...]), parameters: parameters, paramIndex: &paramIdx)
        } ?? []

        let beforeCount = table.rows.count
        if predicates.isEmpty {
            table.rows.removeAll()
        } else {
            table.rows.removeAll { evaluatePredicates(predicates, row: $0, columns: colNames) }
        }
        let deleted = beforeCount - table.rows.count
        tables[key] = table
        return SQLiteExecuteResult(rowsAffected: deleted, lastInsertRowID: lastInsertRowID)
    }

    private struct Predicate {
        let column: String
        let op: String
        let value: SQLiteValue
    }

    private func parseWhereClause(
        _ clause: String,
        parameters: [SQLiteValue],
        paramIndex: inout Int
    ) throws -> [Predicate] {
        var predicates: [Predicate] = []
        let parts = splitTopLevelAND(clause)
        for part in parts {
            let trimmed = trimWhitespace(part)
            if trimmed.isEmpty { continue }
            let upper = trimmed.uppercased()
            if upper.hasSuffix(" IS NULL") {
                let col = unquoteIdentifier(trimWhitespace(trimmed.dropLast(" IS NULL".count)))
                predicates.append(Predicate(column: col, op: "IS NULL", value: .null))
                continue
            }
            if upper.hasSuffix(" IS NOT NULL") {
                let col = unquoteIdentifier(trimWhitespace(trimmed.dropLast(" IS NOT NULL".count)))
                predicates.append(Predicate(column: col, op: "IS NOT NULL", value: .null))
                continue
            }
            let ops = ["!=", "<>", ">=", "<=", "=", ">", "<"]
            var matched = false
            for op in ops {
                if let range = findASCII(op, in: trimmed) {
                    let col = unquoteIdentifier(trimWhitespace(trimmed[..<range.lowerBound]))
                    let rhs = trimWhitespace(trimmed[range.upperBound...])
                    let val = try evaluateExpression(rhs, parameters: parameters, paramIndex: &paramIndex, row: nil, columns: [])
                    predicates.append(Predicate(column: col, op: op, value: val))
                    matched = true
                    break
                }
            }
            if !matched {
                throw SQLiteError.unsupportedSQL("WHERE \(trimmed)")
            }
        }
        return predicates
    }

    private func evaluatePredicates(_ predicates: [Predicate], row: [SQLiteValue], columns: [String]) -> Bool {
        for pred in predicates {
            guard let colIdx = columns.firstIndex(where: { $0.lowercased() == pred.column.lowercased() }) else {
                return false
            }
            let cell = row[colIdx]
            switch pred.op {
            case "IS NULL":
                if !cell.isNull { return false }
            case "IS NOT NULL":
                if cell.isNull { return false }
            case "=":
                if cell != pred.value { return false }
            case "!=", "<>":
                if cell == pred.value { return false }
            case ">":
                if compareValues(cell, pred.value) <= 0 { return false }
            case ">=":
                if compareValues(cell, pred.value) < 0 { return false }
            case "<":
                if compareValues(cell, pred.value) >= 0 { return false }
            case "<=":
                if compareValues(cell, pred.value) > 0 { return false }
            default:
                return false
            }
        }
        return true
    }

    private func evaluateExpression(
        _ rawExpr: String,
        parameters: [SQLiteValue],
        paramIndex: inout Int,
        row: [SQLiteValue]?,
        columns: [String]
    ) throws -> SQLiteValue {
        let expr = trimWhitespace(rawExpr)
        if expr == "?" {
            guard paramIndex < parameters.count else {
                throw SQLiteError.invalidParameter("Missing parameter at index \(paramIndex + 1)")
            }
            let val = parameters[paramIndex]
            paramIndex += 1
            return val
        }
        if expr.uppercased() == "NULL" {
            return .null
        }
        if expr.hasPrefix("'"), expr.hasSuffix("'"), expr.count >= 2 {
            let inner = replaceAll(String(expr.dropFirst().dropLast()), of: "''", with: "'")
            return .text(inner)
        }
        if let intVal = Int64(expr) {
            return .integer(intVal)
        }
        if let dblVal = Double(expr) {
            return .real(dblVal)
        }
        if let row, let colIdx = columns.firstIndex(where: { $0.lowercased() == unquoteIdentifier(expr).lowercased() }) {
            return row[colIdx]
        }
        throw SQLiteError.invalidParameter("Unsupported SQL expression '\(expr)'")
    }

    private func compareValues(_ lhs: SQLiteValue, _ rhs: SQLiteValue) -> Int {
        switch (lhs, rhs) {
        case (.null, .null): return 0
        case (.null, _): return -1
        case (_, .null): return 1
        case let (.integer(a), .integer(b)): return a < b ? -1 : (a > b ? 1 : 0)
        case let (.real(a), .real(b)): return a < b ? -1 : (a > b ? 1 : 0)
        case let (.integer(a), .real(b)): return Double(a) < b ? -1 : (Double(a) > b ? 1 : 0)
        case let (.real(a), .integer(b)): return a < Double(b) ? -1 : (a > Double(b) ? 1 : 0)
        case let (.text(a), .text(b)): return a < b ? -1 : (a > b ? 1 : 0)
        case let (.blob(a), .blob(b)): return a.lexicographicallyPrecedes(b) ? -1 : (a == b ? 0 : 1)
        default:
            return lhs.description < rhs.description ? -1 : (lhs.description > rhs.description ? 1 : 0)
        }
    }

    private func unquoteIdentifier(_ raw: String) -> String {
        var s = trimWhitespace(raw)
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("`") && s.hasSuffix("`")) || (s.hasPrefix("[") && s.hasSuffix("]")) {
            s = String(s.dropFirst().dropLast())
        }
        return s
    }

    private func stripLeadingComments(_ sql: String) -> String {
        var text = sql
        while true {
            text = trimWhitespace(text)
            if text.hasPrefix("--") {
                if let nl = text.firstIndex(of: "\n") {
                    text = String(text[text.index(after: nl)...])
                } else {
                    return ""
                }
            } else {
                return text
            }
        }
    }

    private func splitStatements(_ sql: String) -> [String] {
        var statements: [String] = []
        var current = ""
        var inSingleQuote = false
        for ch in sql {
            if ch == "'" {
                inSingleQuote.toggle()
                current.append(ch)
            } else if ch == ";" && !inSingleQuote {
                statements.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !trimWhitespace(current).isEmpty {
            statements.append(current)
        }
        return statements
    }

    private func splitTopLevelComma(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var depth = 0
        var inSingleQuote = false
        for ch in text {
            if ch == "'" {
                inSingleQuote.toggle()
                current.append(ch)
            } else if !inSingleQuote && ch == "(" {
                depth += 1
                current.append(ch)
            } else if !inSingleQuote && ch == ")" {
                depth = max(0, depth - 1)
                current.append(ch)
            } else if !inSingleQuote && depth == 0 && ch == "," {
                result.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !trimWhitespace(current).isEmpty {
            result.append(current)
        }
        return result
    }

    private func splitValueTuples(_ text: String) -> [String] {
        var tuples: [String] = []
        var current = ""
        var depth = 0
        var inSingleQuote = false
        for ch in text {
            if ch == "'" {
                inSingleQuote.toggle()
                if depth > 0 { current.append(ch) }
            } else if !inSingleQuote && ch == "(" {
                if depth > 0 { current.append(ch) }
                depth += 1
            } else if !inSingleQuote && ch == ")" {
                depth -= 1
                if depth == 0 {
                    tuples.append(current)
                    current = ""
                } else {
                    current.append(ch)
                }
            } else if depth > 0 {
                current.append(ch)
            }
        }
        return tuples
    }

    private func splitTopLevelAND(_ text: String) -> [String] {
        var parts: [String] = []
        var remaining = text
        while let range = findTopLevelKeyword("AND", in: remaining) {
            parts.append(String(remaining[..<range.lowerBound]))
            remaining = String(remaining[range.upperBound...])
        }
        parts.append(remaining)
        return parts
    }

    private func findTopLevelKeyword(_ keyword: String, in text: String) -> Range<String.Index>? {
        let chars = Array(text)
        let kwChars = Array(keyword.uppercased())
        var depth = 0
        var inSingleQuote = false
        var i = 0
        while i + kwChars.count <= chars.count {
            let ch = chars[i]
            if ch == "'" {
                inSingleQuote.toggle()
                i += 1
                continue
            }
            if !inSingleQuote {
                if ch == "(" { depth += 1 }
                else if ch == ")" { depth = max(0, depth - 1) }
                else if depth == 0 {
                    let prevOK = i == 0 || chars[i - 1].isWhitespace || chars[i - 1] == ")"
                    let nextIdx = i + kwChars.count
                    let nextOK = nextIdx == chars.count || chars[nextIdx].isWhitespace || chars[nextIdx] == "("
                    if prevOK && nextOK {
                        var matches = true
                        for j in 0..<kwChars.count {
                            if chars[i + j].uppercased() != String(kwChars[j]) {
                                matches = false
                                break
                            }
                        }
                        if matches {
                            let start = text.index(text.startIndex, offsetBy: i)
                            let end = text.index(start, offsetBy: kwChars.count)
                            return start..<end
                        }
                    }
                }
            }
            i += 1
        }
        return nil
    }
}
