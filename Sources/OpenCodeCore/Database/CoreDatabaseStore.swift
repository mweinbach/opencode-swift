#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

/// Durable SQLite WAL store, runtime SQLite driver bindings, and typed query-builder surface
/// built directly over `OpenCodePlatform.SQLiteDatabase` / `NativeSQLiteDatabase`.
///
/// Ports `packages/core/src/database/{database,sqlite.bun,sqlite.node,sqlite.workerd}.ts`
/// and `packages/core/src/database/drizzle/**`.
public enum CoreDatabaseStore {
    // MARK: - database/database.ts

    // parity: core/src/database/database.ts#Interface [status=implemented hash=77d7a25482eb]
    public protocol Interface: Sendable {
        var db: any SQLiteDatabase { get }
        var driver: CoreDatabaseDrizzle.EffectSQLiteDatabase { get }
    }

    // parity: core/src/database/database.ts#Options [status=implemented hash=0b4f7ca620e8]
    public struct Options: Equatable, Hashable, Sendable, Codable {
        public let path: String?

        public init(path: String? = nil) {
            self.path = path
        }
    }

    // parity: core/src/database/database.ts#Service [status=implemented hash=27f0cdb9cace]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/storage/Database"
        public let db: any SQLiteDatabase
        public let driver: CoreDatabaseDrizzle.EffectSQLiteDatabase

        public init(db: any SQLiteDatabase) {
            self.db = db
            self.driver = CoreDatabaseDrizzle.makeWithDefaults(client: db)
        }
    }

    private final class LockBox: Sendable {
        let mutex = Mutex(())
    }

    private static let fileBootstrapLocks = Mutex<[String: LockBox]>([:])

    private static func withBootstrapLock<T>(for key: String, _ body: () throws -> T) rethrows -> T {
        let lock = fileBootstrapLocks.withLock { map -> LockBox in
            if let existing = map[key] { return existing }
            let created = LockBox()
            map[key] = created
            return created
        }
        return try lock.mutex.withLock { _ in try body() }
    }

    private static func restrictToOwner(
        filename: String,
        fileSystem: any OpenCodeFileSystem
    ) async {
        guard Platform.current != .windows else { return }
        if !(await fileSystem.exists(at: filename)) {
            try? await fileSystem.writeFile([], to: filename, createDirectories: true)
        }
        try? await fileSystem.chmod(at: filename, mode: 0o600)
        for sidecar in ["\(filename)-wal", "\(filename)-shm"] {
            if await fileSystem.exists(at: sidecar) {
                try? await fileSystem.chmod(at: sidecar, mode: 0o600)
            }
        }
    }

    private static func resolveFilePath(_ rawPath: String, dataDirectory: String?) -> String {
        if rawPath == ":memory:" { return rawPath }
        if CoreDatabaseSchema.storedAbsolutePath(rawPath) != nil { return rawPath }
        guard let dataDirectory, !dataDirectory.isEmpty else { return rawPath }
        return dataDirectory.hasSuffix("/") ? "\(dataDirectory)\(rawPath)" : "\(dataDirectory)/\(rawPath)"
    }

    /// Opens a real SQLite WAL database (`NativeSQLiteDatabase` on native platforms, `InMemorySQLiteFallback` on WASI),
    /// applies OpenCode tuning pragmas, and runs `CoreDatabaseMigration.apply`.
    public static func open(
        options: Options = Options(path: ":memory:"),
        dataDirectory: String? = nil,
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
        legacyCredentials: Bool? = nil
    ) async throws -> Service {
        let rawPath = options.path ?? ":memory:"
        let resolved = resolveFilePath(rawPath, dataDirectory: dataDirectory)
        let isFile = resolved != ":memory:"
        if isFile {
            await restrictToOwner(filename: resolved, fileSystem: fileSystem)
        }

        let openOpts = SQLiteOpenOptions(
            journalMode: "WAL",
            foreignKeys: true,
            busyTimeoutMs: 5_000,
            synchronous: "NORMAL"
        )
        let sqlite = try SQLiteDatabaseFactory.open(path: resolved, options: openOpts)
        return try bootstrap(
            client: sqlite,
            lockKey: isFile ? resolved : nil,
            dataDirectory: dataDirectory,
            fileSystem: fileSystem,
            legacyCredentials: legacyCredentials ?? isFile
        )
    }

    /// Applies tuning pragmas and schema bootstrap to an already-open `SQLiteDatabase`.
    public static func bootstrap(
        client: any SQLiteDatabase,
        lockKey: String? = nil,
        dataDirectory: String? = nil,
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
        legacyCredentials: Bool = false
    ) throws -> Service {
        let durableObject = CoreDatabaseDrizzle.managesTransactionsNatively(client)
        if CoreDatabaseBunSQLite.supportsTuningPragmas && !durableObject {
            if client.path != ":memory:" && !client.path.isEmpty {
                _ = try client.query("PRAGMA journal_mode = WAL")
            }
            _ = try client.execute("PRAGMA synchronous = NORMAL")
            _ = try client.execute("PRAGMA busy_timeout = 5000")
            _ = try client.execute("PRAGMA cache_size = -64000")
        }
        if CoreDatabaseBunSQLite.supportsForeignKeyToggle && !durableObject {
            _ = try client.execute("PRAGMA foreign_keys = ON")
        }

        let ctx = CoreDatabaseMigration.Context(
            dataDirectory: dataDirectory,
            fileSystem: fileSystem,
            supportsForeignKeyToggle: CoreDatabaseBunSQLite.supportsForeignKeyToggle,
            managesTransactionsNatively: durableObject
        )
        let runApply = {
            try CoreDatabaseMigration.apply(
                client,
                options: CoreDatabaseMigration.ApplyOptions(legacyCredentials: legacyCredentials),
                context: ctx
            )
        }
        if let lockKey {
            try withBootstrapLock(for: lockKey, runApply)
        } else {
            try runApply()
        }
        return Service(db: client)
    }

    // parity: core/src/database/database.ts#layer [status=adapted hash=95cbbd0b2c65]
    public static func layer(options: Options = Options(path: ":memory:")) -> LayerNode.ExecutableLayer {
        LayerNode.ExecutableLayer { deps, scope in
            let global = deps.get(Global.Service.serviceKey, as: Global.Service.self)?.paths
            let service = try await open(options: options, dataDirectory: global?.data)
            scope.addFinalizer {
                try? service.db.close()
            }
            return LayerNode.Output([Service.serviceKey: service])
        }
    }

    // parity: core/src/database/database.ts#layerFromClient [status=adapted hash=e04b97936b35]
    public static let layerFromClient: LayerNode.ExecutableLayer = LayerNode.ExecutableLayer { deps, _ in
        let global = deps.get(Global.Service.serviceKey, as: Global.Service.self)?.paths
        let client: any SQLiteDatabase
        if let injected = deps.get("@opencode/SqlClient", as: (any SQLiteDatabase).self) {
            client = injected
        } else {
            client = try SQLiteDatabaseFactory.open(path: ":memory:")
        }
        let service = try bootstrap(client: client, dataDirectory: global?.data, legacyCredentials: false)
        return LayerNode.Output([Service.serviceKey: service])
    }

    // parity: core/src/database/database.ts#configured [status=adapted hash=c572d049472e]
    public static func configured(options: Options = Options(path: ":memory:")) -> LayerNode.Provider {
        AppNode.makeGlobalNode(Service.serviceKey, layer(options: options), [Global.node])
    }

    // parity: core/src/database/database.ts#configuredClient [status=adapted hash=4d9fea453fe2]
    public static func configuredClient(_ client: any SQLiteDatabase) -> LayerNode.Provider {
        let impl = LayerNode.ExecutableLayer { deps, _ in
            let global = deps.get(Global.Service.serviceKey, as: Global.Service.self)?.paths
            let service = try bootstrap(client: client, dataDirectory: global?.data, legacyCredentials: false)
            return LayerNode.Output([Service.serviceKey: service])
        }
        return AppNode.makeGlobalNode(Service.serviceKey, impl, [Global.node])
    }

    // parity: core/src/database/database.ts#node [status=adapted hash=7084be28fe29]
    public static let node: LayerNode.Provider = configured(options: Options(path: ":memory:"))
}

// MARK: - database/sqlite.bun.ts

public enum CoreDatabaseBunSQLite {
    // parity: core/src/database/sqlite.bun.ts#supportsTuningPragmas [status=adapted hash=85174bc76f71]
    public static let supportsTuningPragmas: Bool = true

    // parity: core/src/database/sqlite.bun.ts#supportsForeignKeyToggle [status=adapted hash=a476cbdad67a]
    public static let supportsForeignKeyToggle: Bool = true

    // parity: core/src/database/sqlite.bun.ts#sqliteLayer [status=adapted hash=3e2bd4ae8f2a]
    public static func sqliteLayer(filename: String) -> LayerNode.ExecutableLayer {
        LayerNode.ExecutableLayer { _, scope in
            let db = try SQLiteDatabaseFactory.open(path: filename)
            scope.addFinalizer { try? db.close() }
            return LayerNode.Output(["@opencode/SqlClient": db])
        }
    }

    // parity: core/src/database/sqlite.bun.ts#resultCode [status=adapted hash=8a78f107341a]
    public static func resultCode(_ cause: any Error) -> Int32? {
        CoreDatabaseStorageFailure.resultCode(from: cause)
    }
}

// MARK: - database/sqlite.node.ts

public enum CoreDatabaseNodeSQLite {
    // parity: core/src/database/sqlite.node.ts#supportsTuningPragmas [status=adapted hash=85174bc76f71]
    public static let supportsTuningPragmas: Bool = true

    // parity: core/src/database/sqlite.node.ts#supportsForeignKeyToggle [status=adapted hash=a476cbdad67a]
    public static let supportsForeignKeyToggle: Bool = true

    // parity: core/src/database/sqlite.node.ts#sqliteLayer [status=adapted hash=3e2bd4ae8f2a]
    public static func sqliteLayer(filename: String) -> LayerNode.ExecutableLayer {
        CoreDatabaseBunSQLite.sqliteLayer(filename: filename)
    }

    // parity: core/src/database/sqlite.node.ts#resultCode [status=adapted hash=a4757b5a69c6]
    public static func resultCode(_ cause: any Error) -> Int32? {
        CoreDatabaseStorageFailure.resultCode(from: cause)
    }
}

// MARK: - database/sqlite.workerd.ts

public enum CoreDatabaseWorkerdSQLite {
    // parity: core/src/database/sqlite.workerd.ts#supportsTuningPragmas [status=adapted hash=0d3363aaf580]
    public static let supportsTuningPragmas: Bool = false

    // parity: core/src/database/sqlite.workerd.ts#supportsForeignKeyToggle [status=adapted hash=d77a3a0df823]
    public static let supportsForeignKeyToggle: Bool = false

    // parity: core/src/database/sqlite.workerd.ts#SqlStorage [status=adapted hash=a3ebfcc2523e]
    public protocol SqlStorage: Sendable {
        func exec(_ query: String, bindings: [SQLiteValue]) throws -> [SQLiteRow]
    }

    // parity: core/src/database/sqlite.workerd.ts#DurableObjectStorage [status=adapted hash=9c7de7d5e825]
    public protocol DurableObjectStorage: Sendable {
        var sql: any SqlStorage { get }
        func transactionSync<T>(_ closure: () throws -> T) throws -> T
    }

    /// Bridges a `DurableObjectStorage` onto `SQLiteDatabase` with `transactionStatements == false`.
    public final class StorageClientAdapter: SQLiteDatabase, CoreDatabaseDrizzle.NativeTransactionSqlClient, Sendable {
        public let path: String = ":durable-object:"
        public let transactionStatements: Bool = false
        private let storage: any DurableObjectStorage

        public init(storage: any DurableObjectStorage) {
            self.storage = storage
        }

        @discardableResult
        public func execute(_ sql: String, parameters: [SQLiteValue]) throws -> SQLiteExecuteResult {
            _ = try storage.sql.exec(sql, bindings: parameters)
            return SQLiteExecuteResult(rowsAffected: 0, lastInsertRowID: 0)
        }

        public func executeScript(_ sql: String) throws {
            _ = try storage.sql.exec(sql, bindings: [])
        }

        public func query(_ sql: String, parameters: [SQLiteValue]) throws -> [SQLiteRow] {
            try storage.sql.exec(sql, bindings: parameters)
        }

        public func transaction<T>(_ body: () throws -> T) throws -> T {
            try storage.transactionSync(body)
        }

        public func savepoint<T>(_ name: String, _ body: () throws -> T) throws -> T {
            _ = name
            return try body()
        }

        public func close() throws {}
    }

    // parity: core/src/database/sqlite.workerd.ts#sqliteLayer [status=adapted hash=e523f8a0f321]
    public static func sqliteLayer(storage: any DurableObjectStorage) -> LayerNode.ExecutableLayer {
        LayerNode.ExecutableLayer { _, _ in
            let adapter: any SQLiteDatabase = StorageClientAdapter(storage: storage)
            return LayerNode.Output(["@opencode/SqlClient": adapter])
        }
    }

    // parity: core/src/database/sqlite.workerd.ts#resultCode [status=adapted hash=60b4ee337cbb]
    public static func resultCode(_ cause: any Error) -> Int32? {
        _ = cause
        return nil
    }
}

// MARK: - database/drizzle/** (Native Swift Query-Builder & Session Adapter)

/// Native Swift query-builder, prepared statement, and transaction adapter over `OpenCodePlatform.SQLiteDatabase`.
/// Adapts `packages/core/src/database/drizzle/**` without JavaScript Effect/Drizzle runtime dependencies.
public enum CoreDatabaseDrizzle {
    // MARK: drizzle/internal/drizzle-utils.ts

    public struct SelectedField: Equatable, Sendable {
        public let path: [String]
        public let column: String
        public let table: String?

        public init(path: [String], column: String, table: String? = nil) {
            self.path = path
            self.column = column
            self.table = table
        }
    }

    // parity: core/src/database/drizzle/internal/drizzle-utils.ts#getTableColumnsRuntime [status=adapted hash=3d11d0b2bbe2]
    public static func getTableColumnsRuntime(_ table: CoreDatabaseSchema.TableDescriptor) -> [String] {
        table.columns
    }

    // parity: core/src/database/drizzle/internal/drizzle-utils.ts#getViewSelectedFieldsRuntime [status=adapted hash=ebbcbf3dfb06]
    public static func getViewSelectedFieldsRuntime(name: String, columns: [String]) -> (name: String, selectedFields: [String]) {
        (name: name, selectedFields: columns)
    }

    // parity: core/src/database/drizzle/internal/drizzle-utils.ts#jitCompatCheck [status=adapted hash=12e7e0b9afde]
    public static func jitCompatCheck(_ isEnabled: Bool?) -> Bool {
        // Swift compiles ahead-of-time; dynamic JS JIT evaluation is never used.
        _ = isEnabled
        return false
    }

    // parity: core/src/database/drizzle/internal/drizzle-utils.ts#orderSelectedFields [status=adapted hash=4dd87afe151a]
    public static func orderSelectedFields(
        _ fields: [String: String],
        pathPrefix: [String] = []
    ) -> [SelectedField] {
        fields.keys.sorted().map { key in
            SelectedField(path: pathPrefix + [key], column: fields[key]!)
        }
    }

    // parity: core/src/database/drizzle/internal/drizzle-utils.ts#resolveNullableObjectPaths [status=adapted hash=4223af3dc039]
    public static func resolveNullableObjectPaths(
        columns: [SelectedField],
        joinsNotNullableMap: [String: Bool]?
    ) -> [String]? {
        guard let joinsNotNullableMap else { return nil }
        var tableOf: [String: String?] = [:]
        var conflicted: Set<String> = []
        for col in columns where col.path.count > 1 {
            guard let key = col.path.first, let tableName = col.table else { continue }
            if conflicted.contains(key) { continue }
            if let existing = tableOf[key] {
                if existing != tableName { conflicted.insert(key) }
            } else {
                tableOf[key] = tableName
            }
        }
        return tableOf.compactMap { key, tableName in
            guard !conflicted.contains(key), let tableName, joinsNotNullableMap[tableName] != true else { return nil }
            return key
        }.sorted()
    }

    // parity: core/src/database/drizzle/internal/drizzle-utils.ts#mapUpdateSet [status=adapted hash=874e4e3d32f2]
    public static func mapUpdateSet(
        _ table: CoreDatabaseSchema.TableDescriptor,
        values: [String: SQLiteValue]
    ) throws -> [(column: String, value: SQLiteValue)] {
        let validCols = Set(table.columns)
        let filtered = values.filter { validCols.contains($0.key) }.sorted { $0.key < $1.key }
        guard !filtered.isEmpty else {
            throw SQLiteError.invalidParameter("No values to set on table \(table.name)")
        }
        return filtered.map { ($0.key, $0.value) }
    }

    // parity: core/src/database/drizzle/internal/drizzle-utils.ts#mapResultRow [status=adapted hash=6f700d99f4c7]
    public static func mapResultRow(
        columns: [SelectedField],
        row: SQLiteRow
    ) -> [String: SQLiteValue] {
        var result: [String: SQLiteValue] = [:]
        for (idx, field) in columns.enumerated() {
            let value: SQLiteValue
            if let named = row[field.column] {
                value = named
            } else if idx < row.count {
                value = row[idx]
            } else {
                value = .null
            }
            if let key = field.path.last {
                result[key] = value
            }
        }
        return result
    }

    // parity: core/src/database/drizzle/internal/drizzle-utils.ts#getTableLikeName [status=adapted hash=61a53bb6e031]
    public static func getTableLikeName(_ table: CoreDatabaseSchema.TableDescriptor) -> String {
        table.name
    }

    // MARK: drizzle/effect-sqlite/session.ts

    // parity: core/src/database/drizzle/effect-sqlite/session.ts#EffectSQLiteQueryEffectHKT [status=adapted hash=d08e7ba27ff7]
    public protocol EffectSQLiteQueryEffectHKT: Sendable {
        associatedtype ResultType: Sendable
    }

    // parity: core/src/database/drizzle/effect-sqlite/session.ts#NativeTransactionSqlClient [status=adapted hash=32c0bae6feb4]
    public protocol NativeTransactionSqlClient: SQLiteDatabase {
        var transactionStatements: Bool { get }
    }

    // parity: core/src/database/drizzle/effect-sqlite/session.ts#managesTransactionsNatively [status=adapted hash=caa720e7f9e6]
    public static func managesTransactionsNatively(_ client: any SQLiteDatabase) -> Bool {
        (client as? any NativeTransactionSqlClient)?.transactionStatements == false
    }

    // parity: core/src/database/drizzle/effect-sqlite/session.ts#EffectSQLiteRunResult [status=adapted hash=c27a1ec692c1]
    public typealias EffectSQLiteRunResult = SQLiteExecuteResult

    // parity: core/src/database/drizzle/effect-sqlite/session.ts#EffectSQLiteSessionOptions [status=adapted hash=ff195e932e5c]
    public struct EffectSQLiteSessionOptions: Equatable, Sendable {
        public let useJitMappers: Bool

        public init(useJitMappers: Bool = false) {
            self.useJitMappers = useJitMappers
        }
    }

    // MARK: drizzle/sqlite-core/effect/session.ts

    // parity: core/src/database/drizzle/sqlite-core/effect/session.ts#SQLiteEffectPreparedQuery [status=adapted hash=fe8902d9272a]
    public final class SQLiteEffectPreparedQuery: Sendable {
        public let sql: String
        public let parameters: [SQLiteValue]
        private let client: any SQLiteDatabase

        public init(client: any SQLiteDatabase, sql: String, parameters: [SQLiteValue] = []) {
            self.client = client
            self.sql = sql
            self.parameters = parameters
        }

        @discardableResult
        public func run() throws -> EffectSQLiteRunResult {
            try client.execute(sql, parameters: parameters)
        }

        public func all() throws -> [SQLiteRow] {
            try client.query(sql, parameters: parameters)
        }

        public func get() throws -> SQLiteRow? {
            try client.queryOne(sql, parameters: parameters)
        }

        public func values() throws -> [[SQLiteValue]] {
            try client.query(sql, parameters: parameters).map(\.values)
        }
    }

    // parity: core/src/database/drizzle/sqlite-core/effect/session.ts#SQLiteEffectSession [status=adapted hash=9afa05eba622]
    open class SQLiteEffectSession: @unchecked Sendable {
        public let client: any SQLiteDatabase

        public init(client: any SQLiteDatabase) {
            self.client = client
        }

        public func prepareQuery(_ sql: String, parameters: [SQLiteValue] = []) -> SQLiteEffectPreparedQuery {
            SQLiteEffectPreparedQuery(client: client, sql: sql, parameters: parameters)
        }

        @discardableResult
        public func run(_ sql: String, parameters: [SQLiteValue] = []) throws -> EffectSQLiteRunResult {
            try prepareQuery(sql, parameters: parameters).run()
        }

        public func all(_ sql: String, parameters: [SQLiteValue] = []) throws -> [SQLiteRow] {
            try prepareQuery(sql, parameters: parameters).all()
        }

        public func get(_ sql: String, parameters: [SQLiteValue] = []) throws -> SQLiteRow? {
            try prepareQuery(sql, parameters: parameters).get()
        }

        public func values(_ sql: String, parameters: [SQLiteValue] = []) throws -> [[SQLiteValue]] {
            try prepareQuery(sql, parameters: parameters).values()
        }

        public func count(_ sql: String, parameters: [SQLiteValue] = []) throws -> Int {
            Int(try client.queryScalar(sql, parameters: parameters)?.int64Value ?? 0)
        }

        open func transaction<T>(_ body: (SQLiteEffectTransaction) throws -> T) throws -> T {
            try client.transaction {
                try body(SQLiteEffectTransaction(session: self))
            }
        }
    }

    // parity: core/src/database/drizzle/sqlite-core/effect/session.ts#SQLiteEffectTransaction [status=adapted hash=bf14b05ec1da]
    open class SQLiteEffectTransaction: SQLiteEffectDatabase, @unchecked Sendable {
        public override init(session: SQLiteEffectSession) {
            super.init(session: session)
        }
    }

    // parity: core/src/database/drizzle/effect-sqlite/session.ts#EffectSQLiteSession [status=adapted hash=6e0235039fba]
    public final class EffectSQLiteSession: SQLiteEffectSession, @unchecked Sendable {
        public let options: EffectSQLiteSessionOptions

        public init(client: any SQLiteDatabase, options: EffectSQLiteSessionOptions = EffectSQLiteSessionOptions()) {
            self.options = options
            super.init(client: client)
        }

        public func effectTransaction<T>(_ body: (EffectSQLiteTransaction) throws -> T) throws -> T {
            try client.transaction {
                try body(EffectSQLiteTransaction(session: self))
            }
        }
    }

    // parity: core/src/database/drizzle/effect-sqlite/session.ts#EffectSQLiteTransaction [status=adapted hash=9173c2649165]
    public final class EffectSQLiteTransaction: SQLiteEffectTransaction, @unchecked Sendable {
        public init(session: EffectSQLiteSession) {
            super.init(session: session)
        }
    }

    // MARK: drizzle/sqlite-core/effect/raw.ts

    // parity: core/src/database/drizzle/sqlite-core/effect/raw.ts#SQLiteEffectRaw [status=adapted hash=6e48b0af827d]
    public protocol SQLiteEffectRaw: Sendable {
        associatedtype ResultType: Sendable
        func execute() throws -> ResultType
    }

    public struct RawQuery<ResultType: Sendable>: SQLiteEffectRaw {
        private let runBlock: @Sendable () throws -> ResultType

        public init(_ run: @escaping @Sendable () throws -> ResultType) {
            self.runBlock = run
        }

        public func execute() throws -> ResultType {
            try runBlock()
        }
    }

    // MARK: drizzle/sqlite-core/effect/count.ts

    // parity: core/src/database/drizzle/sqlite-core/effect/count.ts#SQLiteEffectCountBuilder [status=adapted hash=e34c8bc043a5]
    public protocol SQLiteEffectCountBuilder: Sendable {
        func execute() throws -> Int
    }

    public struct CountBuilder: SQLiteEffectCountBuilder {
        private let session: SQLiteEffectSession
        private let table: CoreDatabaseSchema.TableDescriptor
        private let whereClause: String?
        private let parameters: [SQLiteValue]

        public init(
            session: SQLiteEffectSession,
            table: CoreDatabaseSchema.TableDescriptor,
            whereClause: String? = nil,
            parameters: [SQLiteValue] = []
        ) {
            self.session = session
            self.table = table
            self.whereClause = whereClause
            self.parameters = parameters
        }

        public func execute() throws -> Int {
            let suffix = whereClause.map { " WHERE \($0)" } ?? ""
            return try session.count("SELECT count(*) FROM `\(table.name)`\(suffix)", parameters: parameters)
        }
    }

    // MARK: drizzle/sqlite-core/effect/select.ts

    // parity: core/src/database/drizzle/sqlite-core/effect/select.ts#SQLiteEffectSelectHKT [status=adapted hash=e2839970a9f4]
    public protocol SQLiteEffectSelectHKT: Sendable {
        associatedtype RowType: Sendable
    }

    // parity: core/src/database/drizzle/sqlite-core/effect/select.ts#SQLiteEffectSelectBase [status=adapted hash=317630770b3e]
    public protocol SQLiteEffectSelectBase: Sendable {
        func all() throws -> [SQLiteRow]
        func get() throws -> SQLiteRow?
    }

    // parity: core/src/database/drizzle/sqlite-core/effect/select.ts#SQLiteEffectSelectPrepare [status=adapted hash=265f69ad32be]
    public typealias SQLiteEffectSelectPrepare = SQLiteEffectPreparedQuery

    // parity: core/src/database/drizzle/sqlite-core/effect/select.ts#AnySQLiteEffectSelect [status=adapted hash=52bb6eb106db]
    public typealias AnySQLiteEffectSelect = any SQLiteEffectSelectBase

    // parity: core/src/database/drizzle/sqlite-core/effect/select.ts#SQLiteEffectSelectBuilder [status=adapted hash=e98680df5745]
    public final class SQLiteEffectSelectBuilder: SQLiteEffectSelectBase, @unchecked Sendable {
        private let session: SQLiteEffectSession
        private let columns: [String]
        private let distinct: Bool
        private var tableName: String?
        private var whereClause: String?
        private var orderByClause: String?
        private var limitCount: Int?
        private var parameters: [SQLiteValue] = []

        public init(session: SQLiteEffectSession, columns: [String] = ["*"], distinct: Bool = false) {
            self.session = session
            self.columns = columns
            self.distinct = distinct
        }

        public func from(_ table: CoreDatabaseSchema.TableDescriptor) -> Self {
            self.tableName = table.name
            return self
        }

        public func `where`(_ clause: String, parameters: [SQLiteValue] = []) -> Self {
            self.whereClause = clause
            self.parameters = parameters
            return self
        }

        public func orderBy(_ clause: String) -> Self {
            self.orderByClause = clause
            return self
        }

        public func limit(_ count: Int) -> Self {
            self.limitCount = count
            return self
        }

        public func prepare() -> SQLiteEffectSelectPrepare {
            let distinctSQL = distinct ? "DISTINCT " : ""
            let colsSQL = columns.joined(separator: ", ")
            var sql = "SELECT \(distinctSQL)\(colsSQL) FROM `\(tableName ?? "")`"
            if let whereClause { sql += " WHERE \(whereClause)" }
            if let orderByClause { sql += " ORDER BY \(orderByClause)" }
            if let limitCount { sql += " LIMIT \(limitCount)" }
            return session.prepareQuery(sql, parameters: parameters)
        }

        public func all() throws -> [SQLiteRow] { try prepare().all() }
        public func get() throws -> SQLiteRow? { try prepare().get() }
    }

    // MARK: drizzle/sqlite-core/effect/insert.ts

    // parity: core/src/database/drizzle/sqlite-core/effect/insert.ts#SQLiteEffectInsertBase [status=adapted hash=cae2b79243a2]
    public protocol SQLiteEffectInsertBase: Sendable {
        @discardableResult
        func run() throws -> EffectSQLiteRunResult
        func returning() throws -> [SQLiteRow]
    }

    // parity: core/src/database/drizzle/sqlite-core/effect/insert.ts#SQLiteEffectInsertOnConflictDoUpdateConfig [status=adapted hash=700517ad0ed3]
    public struct SQLiteEffectInsertOnConflictDoUpdateConfig: Equatable, Sendable {
        public let target: [String]
        public let setClause: String

        public init(target: [String], setClause: String) {
            self.target = target
            self.setClause = setClause
        }
    }

    // parity: core/src/database/drizzle/sqlite-core/effect/insert.ts#SQLiteEffectInsertWithout [status=adapted hash=e43bbf5b2312]
    public typealias SQLiteEffectInsertWithout = SQLiteEffectInsertBuilder
    // parity: core/src/database/drizzle/sqlite-core/effect/insert.ts#SQLiteEffectInsertReturning [status=adapted hash=7cf21d5ad970]
    public typealias SQLiteEffectInsertReturning = SQLiteEffectInsertBuilder
    // parity: core/src/database/drizzle/sqlite-core/effect/insert.ts#SQLiteEffectInsertReturningAll [status=adapted hash=2eee90a65b08]
    public typealias SQLiteEffectInsertReturningAll = SQLiteEffectInsertBuilder
    // parity: core/src/database/drizzle/sqlite-core/effect/insert.ts#SQLiteEffectInsertDynamic [status=adapted hash=d00e949e1b2a]
    public typealias SQLiteEffectInsertDynamic = SQLiteEffectInsertBuilder
    // parity: core/src/database/drizzle/sqlite-core/effect/insert.ts#SQLiteEffectInsertExecute [status=adapted hash=ad34a4cb6dc7]
    public typealias SQLiteEffectInsertExecute = EffectSQLiteRunResult
    // parity: core/src/database/drizzle/sqlite-core/effect/insert.ts#SQLiteEffectInsertPrepare [status=adapted hash=5965d69279a9]
    public typealias SQLiteEffectInsertPrepare = SQLiteEffectPreparedQuery
    // parity: core/src/database/drizzle/sqlite-core/effect/insert.ts#SQLiteEffectInsert [status=adapted hash=7bb875d3fc0a]
    public typealias SQLiteEffectInsert = SQLiteEffectInsertBuilder
    // parity: core/src/database/drizzle/sqlite-core/effect/insert.ts#AnySQLiteEffectInsert [status=adapted hash=c54768d3ce42]
    public typealias AnySQLiteEffectInsert = any SQLiteEffectInsertBase

    // parity: core/src/database/drizzle/sqlite-core/effect/insert.ts#SQLiteEffectInsertBuilder [status=adapted hash=4507878919ce]
    public final class SQLiteEffectInsertBuilder: SQLiteEffectInsertBase, @unchecked Sendable {
        private let session: SQLiteEffectSession
        private let table: CoreDatabaseSchema.TableDescriptor
        private var columns: [String] = []
        private var valuesList: [[SQLiteValue]] = []
        private var conflictClause: String?

        public init(session: SQLiteEffectSession, table: CoreDatabaseSchema.TableDescriptor) {
            self.session = session
            self.table = table
        }

        public func values(_ row: [String: SQLiteValue]) -> Self {
            let cols = row.keys.sorted()
            self.columns = cols
            self.valuesList = [cols.map { row[$0]! }]
            return self
        }

        public func onConflictDoNothing() -> Self {
            self.conflictClause = "ON CONFLICT DO NOTHING"
            return self
        }

        public func onConflictDoUpdate(_ config: SQLiteEffectInsertOnConflictDoUpdateConfig) -> Self {
            let targets = config.target.map { "`\($0)`" }.joined(separator: ", ")
            self.conflictClause = "ON CONFLICT (\(targets)) DO UPDATE SET \(config.setClause)"
            return self
        }

        private func buildSQL(returning: Bool) -> (String, [SQLiteValue]) {
            let colsSQL = columns.map { "`\($0)`" }.joined(separator: ", ")
            let tuple = "(" + Array(repeating: "?", count: columns.count).joined(separator: ", ") + ")"
            let tuples = Array(repeating: tuple, count: valuesList.count).joined(separator: ", ")
            var sql = "INSERT INTO `\(table.name)` (\(colsSQL)) VALUES \(tuples)"
            if let conflictClause { sql += " \(conflictClause)" }
            if returning { sql += " RETURNING *" }
            return (sql, valuesList.flatMap { $0 })
        }

        @discardableResult
        public func run() throws -> EffectSQLiteRunResult {
            let (sql, params) = buildSQL(returning: false)
            return try session.run(sql, parameters: params)
        }

        public func returning() throws -> [SQLiteRow] {
            let (sql, params) = buildSQL(returning: true)
            return try session.all(sql, parameters: params)
        }
    }

    // MARK: drizzle/sqlite-core/effect/update.ts

    // parity: core/src/database/drizzle/sqlite-core/effect/update.ts#SQLiteEffectUpdateBase [status=adapted hash=500c7cc706d4]
    public protocol SQLiteEffectUpdateBase: Sendable {
        @discardableResult
        func run() throws -> EffectSQLiteRunResult
        func returning() throws -> [SQLiteRow]
    }

    // parity: core/src/database/drizzle/sqlite-core/effect/update.ts#SQLiteEffectUpdateWithout [status=adapted hash=04e9731e331e]
    public typealias SQLiteEffectUpdateWithout = SQLiteEffectUpdateBuilder
    // parity: core/src/database/drizzle/sqlite-core/effect/update.ts#SQLiteEffectUpdateWithJoins [status=adapted hash=eceb1fcd2a84]
    public typealias SQLiteEffectUpdateWithJoins = SQLiteEffectUpdateBuilder
    // parity: core/src/database/drizzle/sqlite-core/effect/update.ts#SQLiteEffectUpdateReturningAll [status=adapted hash=72df9787b86b]
    public typealias SQLiteEffectUpdateReturningAll = SQLiteEffectUpdateBuilder
    // parity: core/src/database/drizzle/sqlite-core/effect/update.ts#SQLiteEffectUpdateReturning [status=adapted hash=c79ec9ef30c5]
    public typealias SQLiteEffectUpdateReturning = SQLiteEffectUpdateBuilder
    // parity: core/src/database/drizzle/sqlite-core/effect/update.ts#SQLiteEffectUpdateExecute [status=adapted hash=8747d38f2f98]
    public typealias SQLiteEffectUpdateExecute = EffectSQLiteRunResult
    // parity: core/src/database/drizzle/sqlite-core/effect/update.ts#SQLiteEffectUpdatePrepare [status=adapted hash=8c40abc59646]
    public typealias SQLiteEffectUpdatePrepare = SQLiteEffectPreparedQuery
    // parity: core/src/database/drizzle/sqlite-core/effect/update.ts#SQLiteEffectUpdateDynamic [status=adapted hash=ce84ac61d154]
    public typealias SQLiteEffectUpdateDynamic = SQLiteEffectUpdateBuilder
    // parity: core/src/database/drizzle/sqlite-core/effect/update.ts#SQLiteEffectUpdate [status=adapted hash=66ef3bd32b17]
    public typealias SQLiteEffectUpdate = SQLiteEffectUpdateBuilder
    // parity: core/src/database/drizzle/sqlite-core/effect/update.ts#AnySQLiteEffectUpdate [status=adapted hash=92f07c334d47]
    public typealias AnySQLiteEffectUpdate = any SQLiteEffectUpdateBase
    // parity: core/src/database/drizzle/sqlite-core/effect/update.ts#SQLiteEffectUpdateJoinFn [status=adapted hash=46d5e013593b]
    public typealias SQLiteEffectUpdateJoinFn = @Sendable (String) -> SQLiteEffectUpdateBuilder

    // parity: core/src/database/drizzle/sqlite-core/effect/update.ts#SQLiteEffectUpdateBuilder [status=adapted hash=c06df5e6ae1a]
    public final class SQLiteEffectUpdateBuilder: SQLiteEffectUpdateBase, @unchecked Sendable {
        private let session: SQLiteEffectSession
        private let table: CoreDatabaseSchema.TableDescriptor
        private var setPairs: [(column: String, value: SQLiteValue)] = []
        private var whereClause: String?
        private var whereParams: [SQLiteValue] = []

        public init(session: SQLiteEffectSession, table: CoreDatabaseSchema.TableDescriptor) {
            self.session = session
            self.table = table
        }

        public func set(_ values: [String: SQLiteValue]) throws -> Self {
            self.setPairs = try mapUpdateSet(table, values: values)
            return self
        }

        public func `where`(_ clause: String, parameters: [SQLiteValue] = []) -> Self {
            self.whereClause = clause
            self.whereParams = parameters
            return self
        }

        private func buildSQL(returning: Bool) -> (String, [SQLiteValue]) {
            let assignments = setPairs.map { "`\($0.column)` = ?" }.joined(separator: ", ")
            var sql = "UPDATE `\(table.name)` SET \(assignments)"
            if let whereClause { sql += " WHERE \(whereClause)" }
            if returning { sql += " RETURNING *" }
            return (sql, setPairs.map(\.value) + whereParams)
        }

        @discardableResult
        public func run() throws -> EffectSQLiteRunResult {
            let (sql, params) = buildSQL(returning: false)
            return try session.run(sql, parameters: params)
        }

        public func returning() throws -> [SQLiteRow] {
            let (sql, params) = buildSQL(returning: true)
            return try session.all(sql, parameters: params)
        }
    }

    // MARK: drizzle/sqlite-core/effect/delete.ts

    // parity: core/src/database/drizzle/sqlite-core/effect/delete.ts#SQLiteEffectDeleteBase [status=adapted hash=726e7d44e3f0]
    public protocol SQLiteEffectDeleteBase: Sendable {
        @discardableResult
        func run() throws -> EffectSQLiteRunResult
        func returning() throws -> [SQLiteRow]
    }

    public final class DeleteBuilder: SQLiteEffectDeleteBase, @unchecked Sendable {
        private let session: SQLiteEffectSession
        private let table: CoreDatabaseSchema.TableDescriptor
        private var whereClause: String?
        private var whereParams: [SQLiteValue] = []

        public init(session: SQLiteEffectSession, table: CoreDatabaseSchema.TableDescriptor) {
            self.session = session
            self.table = table
        }

        public func `where`(_ clause: String, parameters: [SQLiteValue] = []) -> Self {
            self.whereClause = clause
            self.whereParams = parameters
            return self
        }

        private func buildSQL(returning: Bool) -> (String, [SQLiteValue]) {
            var sql = "DELETE FROM `\(table.name)`"
            if let whereClause { sql += " WHERE \(whereClause)" }
            if returning { sql += " RETURNING *" }
            return (sql, whereParams)
        }

        @discardableResult
        public func run() throws -> EffectSQLiteRunResult {
            let (sql, params) = buildSQL(returning: false)
            return try session.run(sql, parameters: params)
        }

        public func returning() throws -> [SQLiteRow] {
            let (sql, params) = buildSQL(returning: true)
            return try session.all(sql, parameters: params)
        }
    }

    // parity: core/src/database/drizzle/sqlite-core/effect/delete.ts#SQLiteEffectDeleteWithout [status=adapted hash=cecc3bb3cf6a]
    public typealias SQLiteEffectDeleteWithout = DeleteBuilder
    // parity: core/src/database/drizzle/sqlite-core/effect/delete.ts#SQLiteEffectDeleteReturningAll [status=adapted hash=11edeed78806]
    public typealias SQLiteEffectDeleteReturningAll = DeleteBuilder
    // parity: core/src/database/drizzle/sqlite-core/effect/delete.ts#SQLiteEffectDeleteReturning [status=adapted hash=0c3532e45992]
    public typealias SQLiteEffectDeleteReturning = DeleteBuilder
    // parity: core/src/database/drizzle/sqlite-core/effect/delete.ts#SQLiteEffectDeleteExecute [status=adapted hash=cb3eeb30153f]
    public typealias SQLiteEffectDeleteExecute = EffectSQLiteRunResult
    // parity: core/src/database/drizzle/sqlite-core/effect/delete.ts#SQLiteEffectDeletePrepare [status=adapted hash=4b5262f9350e]
    public typealias SQLiteEffectDeletePrepare = SQLiteEffectPreparedQuery
    // parity: core/src/database/drizzle/sqlite-core/effect/delete.ts#SQLiteEffectDeleteDynamic [status=adapted hash=dc7841313cac]
    public typealias SQLiteEffectDeleteDynamic = DeleteBuilder
    // parity: core/src/database/drizzle/sqlite-core/effect/delete.ts#SQLiteEffectDelete [status=adapted hash=8cd5ea9bb255]
    public typealias SQLiteEffectDelete = DeleteBuilder
    // parity: core/src/database/drizzle/sqlite-core/effect/delete.ts#AnySQLiteEffectDelete [status=adapted hash=8a1c18ec634b]
    public typealias AnySQLiteEffectDelete = any SQLiteEffectDeleteBase

    // MARK: drizzle/sqlite-core/effect/query.ts

    // parity: core/src/database/drizzle/sqlite-core/effect/query.ts#SQLiteEffectRelationalQuery [status=adapted hash=c2b5de6f150c]
    public protocol SQLiteEffectRelationalQuery: Sendable {
        func execute() throws -> [SQLiteRow]
    }

    // parity: core/src/database/drizzle/sqlite-core/effect/query.ts#SQLiteEffectRelationalQueryBuilder [status=adapted hash=40e26170a4ee]
    public final class SQLiteEffectRelationalQueryBuilder: SQLiteEffectRelationalQuery, Sendable {
        private let session: SQLiteEffectSession
        public let table: CoreDatabaseSchema.TableDescriptor

        public init(session: SQLiteEffectSession, table: CoreDatabaseSchema.TableDescriptor) {
            self.session = session
            self.table = table
        }

        public func findMany(whereClause: String? = nil, parameters: [SQLiteValue] = [], limit: Int? = nil) throws -> [SQLiteRow] {
            let builder = SQLiteEffectSelectBuilder(session: session).from(table)
            if let whereClause { _ = builder.where(whereClause, parameters: parameters) }
            if let limit { _ = builder.limit(limit) }
            return try builder.all()
        }

        public func findFirst(whereClause: String? = nil, parameters: [SQLiteValue] = []) throws -> SQLiteRow? {
            try findMany(whereClause: whereClause, parameters: parameters, limit: 1).first
        }

        public func execute() throws -> [SQLiteRow] {
            try findMany()
        }
    }

    // MARK: drizzle/sqlite-core/effect/db.ts

    // parity: core/src/database/drizzle/sqlite-core/effect/db.ts#SQLiteEffectDatabase [status=adapted hash=5b56c111346c]
    open class SQLiteEffectDatabase: @unchecked Sendable {
        public let session: SQLiteEffectSession
        public var client: any SQLiteDatabase { session.client }

        public init(session: SQLiteEffectSession) {
            self.session = session
        }

        public func select(_ columns: [String] = ["*"]) -> SQLiteEffectSelectBuilder {
            SQLiteEffectSelectBuilder(session: session, columns: columns)
        }

        public func selectDistinct(_ columns: [String] = ["*"]) -> SQLiteEffectSelectBuilder {
            SQLiteEffectSelectBuilder(session: session, columns: columns, distinct: true)
        }

        public func insert(into table: CoreDatabaseSchema.TableDescriptor) -> SQLiteEffectInsertBuilder {
            SQLiteEffectInsertBuilder(session: session, table: table)
        }

        public func update(_ table: CoreDatabaseSchema.TableDescriptor) -> SQLiteEffectUpdateBuilder {
            SQLiteEffectUpdateBuilder(session: session, table: table)
        }

        public func delete(from table: CoreDatabaseSchema.TableDescriptor) -> DeleteBuilder {
            DeleteBuilder(session: session, table: table)
        }

        public func count(
            _ table: CoreDatabaseSchema.TableDescriptor,
            whereClause: String? = nil,
            parameters: [SQLiteValue] = []
        ) -> CountBuilder {
            CountBuilder(session: session, table: table, whereClause: whereClause, parameters: parameters)
        }

        @discardableResult
        public func run(_ sql: String, parameters: [SQLiteValue] = []) throws -> EffectSQLiteRunResult {
            try session.run(sql, parameters: parameters)
        }

        public func all(_ sql: String, parameters: [SQLiteValue] = []) throws -> [SQLiteRow] {
            try session.all(sql, parameters: parameters)
        }

        public func get(_ sql: String, parameters: [SQLiteValue] = []) throws -> SQLiteRow? {
            try session.get(sql, parameters: parameters)
        }

        public func values(_ sql: String, parameters: [SQLiteValue] = []) throws -> [[SQLiteValue]] {
            try session.values(sql, parameters: parameters)
        }

        public func transaction<T>(_ body: (SQLiteEffectTransaction) throws -> T) throws -> T {
            try session.transaction(body)
        }
    }

    // parity: core/src/database/drizzle/sqlite-core/effect/db.ts#AnySQLiteEffectDatabase [status=adapted hash=66b526502733]
    public typealias AnySQLiteEffectDatabase = SQLiteEffectDatabase

    // parity: core/src/database/drizzle/sqlite-core/effect/db.ts#AnySQLiteEffectSelectBase [status=adapted hash=826d71587a8c]
    public typealias AnySQLiteEffectSelectBase = any SQLiteEffectSelectBase

    // MARK: drizzle/effect-sqlite/driver.ts

    // parity: core/src/database/drizzle/effect-sqlite/driver.ts#EffectSQLiteDatabase [status=adapted hash=61d3f2f90074]
    public final class EffectSQLiteDatabase: SQLiteEffectDatabase, @unchecked Sendable {
        public let effectSession: EffectSQLiteSession

        public init(session: EffectSQLiteSession) {
            self.effectSession = session
            super.init(session: session)
        }
    }

    // parity: core/src/database/drizzle/effect-sqlite/driver.ts#EffectDrizzleSQLiteConfig [status=adapted hash=c4cf4d3de6eb]
    public struct EffectDrizzleSQLiteConfig: Equatable, Sendable {
        public let jit: Bool?

        public init(jit: Bool? = nil) {
            self.jit = jit
        }
    }

    // parity: core/src/database/drizzle/effect-sqlite/driver.ts#DefaultServices [status=adapted hash=c30c9d0a3b27]
    public static let defaultServices: LayerNode.ExecutableLayer = .empty

    // parity: core/src/database/drizzle/effect-sqlite/driver.ts#make [status=adapted hash=4007601f9e0d]
    public static func make(
        client: any SQLiteDatabase,
        config: EffectDrizzleSQLiteConfig = EffectDrizzleSQLiteConfig()
    ) -> EffectSQLiteDatabase {
        let session = EffectSQLiteSession(
            client: client,
            options: EffectSQLiteSessionOptions(useJitMappers: jitCompatCheck(config.jit))
        )
        return EffectSQLiteDatabase(session: session)
    }

    // parity: core/src/database/drizzle/effect-sqlite/driver.ts#makeWithDefaults [status=adapted hash=80df579b7dcb]
    public static func makeWithDefaults(
        client: any SQLiteDatabase,
        config: EffectDrizzleSQLiteConfig = EffectDrizzleSQLiteConfig()
    ) -> EffectSQLiteDatabase {
        make(client: client, config: config)
    }
}
