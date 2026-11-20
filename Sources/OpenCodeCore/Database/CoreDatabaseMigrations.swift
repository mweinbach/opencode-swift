#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

/// Durable SQLite schema bootstrap, incremental migration runner, legacy `auth.json` credential importer,
/// and V1-to-V2 session migration engine.
///
/// Ports `packages/core/src/database/{migration,migration.gen,v1-migration.bun,v1-migration.noop}.ts`
/// and `packages/core/src/database/migration/20260805200742_import_legacy_credentials.ts`.
public enum CoreDatabaseMigration {
    public enum MigrationError: Error, Equatable, Sendable, CustomStringConvertible {
        case nonEmptyWithoutSessionTable(tables: [String])
        case unmatchedLegacyMigrationTimestamp(Int64)
        case migrationExecutionFailed(id: String, message: String)

        public var description: String {
            switch self {
            case .nonEmptyWithoutSessionTable(let tables):
                "Database is not empty and has no session table (found: \(tables.joined(separator: ", ")))"
            case .unmatchedLegacyMigrationTimestamp(let ts):
                "Legacy migration timestamp \(ts) does not match any known migration"
            case .migrationExecutionFailed(let id, let message):
                "Database migration '\(id)' failed: \(message)"
            }
        }
    }

    public struct Context: Sendable {
        public let dataDirectory: String?
        public let fileSystem: any OpenCodeFileSystem
        public let supportsForeignKeyToggle: Bool
        public let managesTransactionsNatively: Bool

        public init(
            dataDirectory: String? = nil,
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
            supportsForeignKeyToggle: Bool = true,
            managesTransactionsNatively: Bool = false
        ) {
            self.dataDirectory = dataDirectory
            self.fileSystem = fileSystem
            self.supportsForeignKeyToggle = supportsForeignKeyToggle
            self.managesTransactionsNatively = managesTransactionsNatively
        }
    }

    /// One schema or data migration step (`database/migration.ts#Migration`).
    // parity: core/src/database/migration.ts#Migration [status=implemented hash=8f88b179074e]
    public struct Migration: Sendable {
        public let id: String
        public let foreignKeys: Bool
        public let up: @Sendable (any SQLiteDatabase, Context) throws -> Void

        public init(
            id: String,
            foreignKeys: Bool = true,
            up: @escaping @Sendable (any SQLiteDatabase, Context) throws -> Void
        ) {
            self.id = id
            self.foreignKeys = foreignKeys
            self.up = up
        }
    }

    /// Ordered registry of all 62 canonical schema/data migrations matching `migration.gen.ts`.
    // parity: core/src/database/migration.gen.ts#migrations [status=implemented hash=d830116bb1d6]
    public static let migrations: [Migration] = Migrations.all

    public struct ApplyOptions: Equatable, Sendable {
        public let legacyCredentials: Bool

        public init(legacyCredentials: Bool = true) {
            self.legacyCredentials = legacyCredentials
        }
    }

    /// Bootstraps a fresh database with the full 23-table schema (plus migration journal) or applies pending
    /// incremental migrations to an existing OpenCode database.
    // parity: core/src/database/migration.ts#apply [status=implemented hash=52186addbec4]
    public static func apply(
        _ db: any SQLiteDatabase,
        options: ApplyOptions = ApplyOptions(),
        context: Context = Context()
    ) throws {
        // OpenCode owns the unprefixed table namespace; embedders may own underscore-prefixed tables.
        let rows = try db.query(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND substr(name, 1, 1) <> '_'"
        )
        let tables = rows.compactMap { $0.string("name") }
        if tables.contains("session") || tables.contains("session_v2") {
            try applyOnly(db, input: migrations, context: context)
            return
        }
        if !tables.isEmpty {
            throw MigrationError.nonEmptyWithoutSessionTable(tables: tables)
        }

        try db.transaction {
            try CoreDatabaseSchema.schemaBootstrap.up(db, context)
            if options.legacyCredentials, let dir = context.dataDirectory {
                try importLegacyCredentialsSync(tx: db, filepath: "\(dir)/auth.json")
            }
            _ = try db.execute(
                "CREATE TABLE `migration` (`id` TEXT PRIMARY KEY, `time_completed` INTEGER NOT NULL)"
            )
            let now = Flock.currentEpochMs()
            for migration in migrations {
                _ = try db.execute(
                    "INSERT INTO `migration` (`id`, `time_completed`) VALUES (?, ?)",
                    parameters: [.text(migration.id), .integer(now)]
                )
            }
        }
    }

    /// Applies any pending migrations from `input`, seeding the `migration` journal from legacy
    /// `__drizzle_migrations` if present.
    // parity: core/src/database/migration.ts#applyOnly [status=implemented hash=6531f51059fc]
    public static func applyOnly(
        _ db: any SQLiteDatabase,
        input: [Migration],
        context: Context = Context()
    ) throws {
        _ = try db.execute(
            "CREATE TABLE IF NOT EXISTS `migration` (`id` TEXT PRIMARY KEY, `time_completed` INTEGER NOT NULL)"
        )
        var completed = Set(
            try db.query("SELECT `id` FROM `migration`").compactMap { $0.string("id") }
        )

        if completed.isEmpty {
            let hasDrizzle = try db.queryOne(
                "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
                parameters: [.text("__drizzle_migrations")]
            ) != nil
            if hasDrizzle {
                let cols = try db.query("SELECT name FROM pragma_table_info('__drizzle_migrations')")
                let hasNameColumn = cols.contains { $0.string("name") == "name" }
                let now = Flock.currentEpochMs()

                if hasNameColumn {
                    _ = try db.execute(
                        """
                        INSERT OR IGNORE INTO `migration` (`id`, `time_completed`)
                        SELECT name, ? FROM `__drizzle_migrations` WHERE name IS NOT NULL
                        """,
                        parameters: [.integer(now)]
                    )
                } else {
                    let entries = try db.query(
                        """
                        SELECT created_at, strftime('%Y%m%d%H%M%S', created_at / 1000, 'unixepoch') AS prefix
                        FROM `__drizzle_migrations`
                        WHERE created_at IS NOT NULL
                        """
                    )
                    for entry in entries {
                        guard let createdAt = entry.int64("created_at"),
                              let prefix = entry.string("prefix")
                        else { continue }
                        guard let matched = input.first(where: { $0.id.hasPrefix("\(prefix)_") }) else {
                            throw MigrationError.unmatchedLegacyMigrationTimestamp(createdAt)
                        }
                        _ = try db.execute(
                            "INSERT OR IGNORE INTO `migration` (`id`, `time_completed`) VALUES (?, ?)",
                            parameters: [.text(matched.id), .integer(now)]
                        )
                    }
                }

                completed = Set(
                    try db.query("SELECT `id` FROM `migration`").compactMap { $0.string("id") }
                )
            }
        }

        for migration in input {
            if completed.contains(migration.id) { continue }
            let runStep: () throws -> Void = {
                try db.transaction {
                    try migration.up(db, context)
                    _ = try db.execute(
                        "INSERT INTO `migration` (`id`, `time_completed`) VALUES (?, ?)",
                        parameters: [.text(migration.id), .integer(Flock.currentEpochMs())]
                    )
                }
            }
            do {
                if migration.foreignKeys {
                    try runStep()
                } else {
                    let toggleForeignKeys = context.supportsForeignKeyToggle && !context.managesTransactionsNatively
                    if toggleForeignKeys {
                        _ = try db.execute("PRAGMA foreign_keys = OFF")
                    } else {
                        _ = try db.execute("PRAGMA defer_foreign_keys = ON")
                    }
                    defer {
                        if toggleForeignKeys {
                            _ = try? db.execute("PRAGMA foreign_keys = ON")
                        }
                    }
                    try runStep()
                }
            } catch {
                throw MigrationError.migrationExecutionFailed(id: migration.id, message: String(describing: error))
            }
        }
    }

    // MARK: - migration/20260805200742_import_legacy_credentials.ts

    private static let wellKnownSourcesKey = "wellknown:sources"

    private static func oauthMethodID(for integrationID: String) -> String {
        if integrationID == "openai" { return "chatgpt-browser" }
        if integrationID == "github-copilot" || integrationID == "opencode" || integrationID == "xai" {
            return "device"
        }
        return "oauth"
    }

    /// Imports legacy `auth.json` credentials into `credential` and `kv` (`wellknown:sources`) tables.
    // parity: core/src/database/migration/20260805200742_import_legacy_credentials.ts#importLegacyCredentials [status=implemented hash=009d8fe63c54]
    public static func importLegacyCredentials(
        tx: any SQLiteDatabase,
        filepath: String,
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared
    ) async throws {
        guard let bytes = try? await fileSystem.readFile(at: filepath) else {
            return
        }
        try importLegacyCredentialsBytes(tx: tx, bytes: bytes)
    }

    internal static func importLegacyCredentialsSync(tx: any SQLiteDatabase, filepath: String) throws {
        #if !os(WASI)
        guard let data = FileManager.default.contents(atPath: filepath) else {
            return
        }
        try importLegacyCredentialsBytes(tx: tx, bytes: Array(data))
        #endif
    }

    private static func importLegacyCredentialsBytes(tx: any SQLiteDatabase, bytes: [UInt8]) throws {
        guard let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(bytes)),
              case .object(let root) = parsed
        else {
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var origins: [String] = []

        for (rawID, rawValue) in root.sorted(by: { $0.key < $1.key }) {
            guard case .object(let entry) = rawValue,
                  case .string(let type) = entry["type"]
            else { continue }

            var integrationID = rawID
            while integrationID.hasSuffix("/") {
                integrationID.removeLast()
            }
            if integrationID.isEmpty { continue }

            let credentialJSON: String
            let label: String
            switch type {
            case "api":
                guard case .string(let key) = entry["key"] else { continue }
                var metadata: [String: JSONValue]? = nil
                if case .object(let metaObj) = entry["metadata"] {
                    var strMeta: [String: JSONValue] = [:]
                    var valid = true
                    for (k, v) in metaObj {
                        if case .string = v {
                            strMeta[k] = v
                        } else {
                            valid = false
                            break
                        }
                    }
                    if !valid { continue }
                    metadata = strMeta
                }
                let cred = CredentialSchema.Key(key: key, metadata: metadata)
                credentialJSON = String(decoding: try encoder.encode(cred), as: UTF8.self)
                label = "API key"

            case "wellknown":
                guard case .string = entry["key"],
                      case .string(let token) = entry["token"]
                else { continue }
                origins.append(integrationID)
                let cred = CredentialSchema.Key(key: token)
                credentialJSON = String(decoding: try encoder.encode(cred), as: UTF8.self)
                label = "API key"

            case "oauth":
                guard case .string(let refresh) = entry["refresh"],
                      case .string(let access) = entry["access"]
                else { continue }
                let expiresInt: Int
                switch entry["expires"] {
                case .int(let v) where v >= 0: expiresInt = Int(v)
                case .double(let d) where d >= 0 && d.rounded() == d: expiresInt = Int(d)
                default: continue
                }
                guard let nonNegExpires = SchemaPrimitive.NonNegativeInt(rawValue: expiresInt) else { continue }
                var meta: [String: JSONValue] = [:]
                if case .string(let acc) = entry["accountId"], !acc.isEmpty {
                    meta["accountID"] = .string(acc)
                }
                if case .string(let ent) = entry["enterpriseUrl"], !ent.isEmpty {
                    meta["enterpriseUrl"] = .string(ent)
                }
                let cred = CredentialSchema.OAuth(
                    methodID: IntegrationMethodID(rawValue: oauthMethodID(for: integrationID)),
                    refresh: refresh,
                    access: access,
                    expires: nonNegExpires,
                    metadata: meta.isEmpty ? nil : meta
                )
                credentialJSON = String(decoding: try encoder.encode(cred), as: UTF8.self)
                label = "OAuth"

            default:
                continue
            }

            let exists = try tx.queryOne(
                "SELECT `id` FROM `credential` WHERE `integration_id` = ?",
                parameters: [.text(integrationID)]
            ) != nil
            if exists { continue }

            let now = Flock.currentEpochMs()
            _ = try tx.execute(
                """
                INSERT INTO `credential` (`id`, `integration_id`, `label`, `value`, `time_created`, `time_updated`)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                parameters: [
                    .text(CredentialSchema.ID.create().rawValue),
                    .text(integrationID),
                    .text(label),
                    .text(credentialJSON),
                    .integer(now),
                    .integer(now),
                ]
            )
        }

        if origins.isEmpty { return }
        var current: [String] = []
        if let row = try tx.queryOne(
            "SELECT `value` FROM `kv` WHERE `key` = ?",
            parameters: [.text(wellKnownSourcesKey)]
        ),
           let raw = row.string("value"),
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data)
        {
            current = decoded
        }
        var seen = Set<String>()
        var merged: [String] = []
        for item in current + origins {
            if seen.insert(item).inserted {
                merged.append(item)
            }
        }
        let mergedJSON = String(decoding: try encoder.encode(merged), as: UTF8.self)
        let now = Flock.currentEpochMs()
        _ = try tx.execute(
            """
            INSERT INTO `kv` (`key`, `value`, `time_created`, `time_updated`)
            VALUES (?, ?, ?, ?)
            ON CONFLICT (`key`) DO UPDATE SET `value` = excluded.`value`, `time_updated` = excluded.`time_updated`
            """,
            parameters: [
                .text(wellKnownSourcesKey),
                .text(mergedJSON),
                .integer(now),
                .integer(now),
            ]
        )
    }
}

// MARK: - database/v1-migration.bun.ts

/// Durable V1-to-V2 SQLite session/message/part migration engine (`database/v1-migration.bun.ts`).
public enum CoreDatabaseV1Migration {
    public struct Progress: Equatable, Hashable, Sendable, Codable {
        public let label: String
        public let numerator: Int?
        public let denominator: Int?

        public init(label: String, numerator: Int? = nil, denominator: Int? = nil) {
            self.label = label
            self.numerator = numerator
            self.denominator = denominator
        }
    }

    // parity: core/src/database/v1-migration.bun.ts#SourceMessage [status=implemented hash=33776c0f6fb7]
    public struct SourceMessage: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let sessionID: String
        public let timeCreated: Int64
        public let timeUpdated: Int64
        public let data: String

        public init(id: String, sessionID: String, timeCreated: Int64, timeUpdated: Int64, data: String) {
            self.id = id
            self.sessionID = sessionID
            self.timeCreated = timeCreated
            self.timeUpdated = timeUpdated
            self.data = data
        }
    }

    // parity: core/src/database/v1-migration.bun.ts#SourcePart [status=implemented hash=313682b59ef3]
    public struct SourcePart: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let messageID: String
        public let sessionID: String
        public let timeCreated: Int64
        public let timeUpdated: Int64
        public let data: String

        public init(
            id: String,
            messageID: String,
            sessionID: String,
            timeCreated: Int64,
            timeUpdated: Int64,
            data: String
        ) {
            self.id = id
            self.messageID = messageID
            self.sessionID = sessionID
            self.timeCreated = timeCreated
            self.timeUpdated = timeUpdated
            self.data = data
        }
    }

    public struct SessionRowInput: Equatable, Hashable, Sendable {
        public let id: String
        public let agent: String?
        public let model: SessionSchema.ModelRef?

        public init(id: String, agent: String? = nil, model: SessionSchema.ModelRef? = nil) {
            self.id = id
            self.agent = agent
            self.model = model
        }
    }

    // parity: core/src/database/v1-migration.bun.ts#TransformInput [status=implemented hash=dbc7afb27a4f]
    public struct TransformInput: Equatable, Hashable, Sendable {
        public let session: SessionRowInput
        public let messages: [SourceMessage]
        public let parts: [SourcePart]

        public init(session: SessionRowInput, messages: [SourceMessage], parts: [SourcePart]) {
            self.session = session
            self.messages = messages
            self.parts = parts
        }
    }

    // parity: core/src/database/v1-migration.bun.ts#Warning [status=implemented hash=802077995ae6]
    public struct Warning: Equatable, Hashable, Sendable, Codable {
        public let reason: String
        public let sessionID: String
        public let messageID: String?
        public let partID: String?
        public let observedType: String?

        public init(
            reason: String,
            sessionID: String,
            messageID: String? = nil,
            partID: String? = nil,
            observedType: String? = nil
        ) {
            self.reason = reason
            self.sessionID = sessionID
            self.messageID = messageID
            self.partID = partID
            self.observedType = observedType
        }
    }

    public struct TransformedMessageRow: Equatable, Hashable, Sendable {
        public let id: String
        public let sessionID: String
        public let type: SessionMessageSchema.MessageType
        public let seq: Int
        public let timeCreated: Int64
        public let timeUpdated: Int64
        public let data: [String: JSONValue]

        public init(
            id: String,
            sessionID: String,
            type: SessionMessageSchema.MessageType,
            seq: Int,
            timeCreated: Int64,
            timeUpdated: Int64,
            data: [String: JSONValue]
        ) {
            self.id = id
            self.sessionID = sessionID
            self.type = type
            self.seq = seq
            self.timeCreated = timeCreated
            self.timeUpdated = timeUpdated
            self.data = data
        }
    }

    public struct TransformedSessionUpdate: Equatable, Hashable, Sendable {
        public let agent: String?
        public let model: SessionSchema.ModelRef?
        public let cost: Double
        public let tokensInput: Double
        public let tokensOutput: Double
        public let tokensReasoning: Double
        public let tokensCacheRead: Double
        public let tokensCacheWrite: Double

        public init(
            agent: String?,
            model: SessionSchema.ModelRef?,
            cost: Double,
            tokensInput: Double,
            tokensOutput: Double,
            tokensReasoning: Double,
            tokensCacheRead: Double,
            tokensCacheWrite: Double
        ) {
            self.agent = agent
            self.model = model
            self.cost = cost
            self.tokensInput = tokensInput
            self.tokensOutput = tokensOutput
            self.tokensReasoning = tokensReasoning
            self.tokensCacheRead = tokensCacheRead
            self.tokensCacheWrite = tokensCacheWrite
        }
    }

    // parity: core/src/database/v1-migration.bun.ts#TransformResult [status=implemented hash=2ed1fdefecab]
    public struct TransformResult: Equatable, Hashable, Sendable {
        public let messages: [TransformedMessageRow]
        public let session: TransformedSessionUpdate
        public let watermark: Int
        public let warnings: [Warning]

        public init(
            messages: [TransformedMessageRow],
            session: TransformedSessionUpdate,
            watermark: Int,
            warnings: [Warning]
        ) {
            self.messages = messages
            self.session = session
            self.watermark = watermark
            self.warnings = warnings
        }
    }

    // parity: core/src/database/v1-migration.bun.ts#Status [status=implemented hash=f1d987226b03]
    public enum Status: Equatable, Hashable, Sendable {
        case required
        case completed
        case running(progress: Progress)
        case error(String)
    }

    public struct RunResult: Equatable, Hashable, Sendable {
        public let status: String

        public init(status: String = "completed") {
            self.status = status
        }
    }

    private enum RuntimeState: Sendable {
        case idle
        case running(Progress)
        case error(String)
    }

    private static let runtimeState = Mutex<RuntimeState>(.idle)
    private static let migrationStateKey = "migration.v1-v2"
    private static let renamedTools: [String: String] = [
        "bash": "shell",
        "task": "subagent",
        "apply_patch": "patch",
    ]
    private static let pathTools: [String] = ["read", "edit", "write"]
    private static let removedTools: [String] = ["todowrite"]

    /// Transforms a V1 session's `message` and `part` rows into canonical V2 `session_message` rows,
    /// aggregated session usage/selection metadata, sequence watermark, and skipped-row warnings.
    // parity: core/src/database/v1-migration.bun.ts#transformSession [status=implemented hash=6328df9a7fc1]
    public static func transformSession(_ input: TransformInput) -> TransformResult {
        var warnings: [Warning] = []
        let decoder = JSONDecoder()

        struct DecodedMessage {
            let row: SourceMessage
            let dict: [String: JSONValue]
            let role: String
        }
        struct DecodedPart {
            let row: SourcePart
            let dict: [String: JSONValue]
            let type: String
        }

        var decodedMessages: [DecodedMessage] = []
        for row in input.messages {
            guard let data = row.data.data(using: .utf8),
                  let parsed = try? decoder.decode(JSONValue.self, from: data),
                  case .object(let dict) = parsed,
                  case .string(let role) = dict["role"],
                  role == "user" || role == "assistant"
            else {
                warnings.append(Warning(reason: "invalid-message", sessionID: input.session.id, messageID: row.id))
                continue
            }
            decodedMessages.append(DecodedMessage(row: row, dict: dict, role: role))
        }
        decodedMessages.sort { lhs, rhs in
            if lhs.row.timeCreated != rhs.row.timeCreated {
                return lhs.row.timeCreated < rhs.row.timeCreated
            }
            return lhs.row.id < rhs.row.id
        }

        let allMessageIDs = Set(input.messages.map(\.id))
        var decodedParts: [DecodedPart] = []
        for row in input.parts {
            let parsedObj: [String: JSONValue]? = {
                guard let data = row.data.data(using: .utf8),
                      let val = try? decoder.decode(JSONValue.self, from: data),
                      case .object(let dict) = val
                else { return nil }
                return dict
            }()
            let observedType: String? = parsedObj.flatMap { dict in
                if case .string(let s) = dict["type"] { return s }
                return nil
            }
            if !allMessageIDs.contains(row.messageID) {
                warnings.append(Warning(
                    reason: "orphan-part",
                    sessionID: input.session.id,
                    messageID: row.messageID,
                    partID: row.id,
                    observedType: observedType
                ))
                continue
            }
            guard let dict = parsedObj, let type = observedType else {
                warnings.append(Warning(
                    reason: "invalid-part",
                    sessionID: input.session.id,
                    messageID: row.messageID,
                    partID: row.id,
                    observedType: observedType
                ))
                continue
            }
            decodedParts.append(DecodedPart(row: row, dict: dict, type: type))
        }
        decodedParts.sort { $0.row.id < $1.row.id }

        var byMessage: [String: [DecodedPart]] = [:]
        for part in decodedParts {
            byMessage[part.row.messageID, default: []].append(part)
        }

        var paired = Set<String>()
        var usedIDs = Set(decodedMessages.map(\.row.id))
        var projected: [TransformedMessageRow] = []

        func makeRow(
            source: SourceMessage,
            id: String,
            type: SessionMessageSchema.MessageType,
            data: [String: JSONValue],
            timeUpdated: Int64? = nil
        ) -> TransformedMessageRow {
            TransformedMessageRow(
                id: id,
                sessionID: source.sessionID,
                type: type,
                seq: 0,
                timeCreated: source.timeCreated,
                timeUpdated: timeUpdated ?? source.timeUpdated,
                data: data
            )
        }

        for (msgIndex, item) in decodedMessages.enumerated() {
            if paired.contains(item.row.id) { continue }
            let owned = byMessage[item.row.id] ?? []

            if item.role == "user" {
                if let compaction = owned.first(where: { $0.type == "compaction" }) {
                    guard let summary = decodedMessages.first(where: { cand in
                        cand.role == "assistant"
                            && stringValue(cand.dict["parentID"]) == item.row.id
                            && boolValue(cand.dict["summary"]) == true
                    }) else { continue }
                    paired.insert(summary.row.id)
                    let completedTime = objectValue(summary.dict["time"]).flatMap { numberValue($0["completed"]) }
                    if summary.dict["error"] != nil || completedTime == nil { continue }

                    let summaryText = (byMessage[summary.row.id] ?? [])
                        .compactMap { part -> String? in
                            guard part.type == "text", let text = stringValue(part.dict["text"]), !text.isEmpty else {
                                return nil
                            }
                            return text
                        }
                        .joined(separator: "\n\n")

                    var recent = ""
                    if let tailStartID = stringValue(compaction.dict["tail_start_id"]),
                       let tailIdx = decodedMessages.firstIndex(where: { $0.row.id == tailStartID }),
                       tailIdx < msgIndex
                    {
                        let tailSlice = Array(decodedMessages[tailIdx..<msgIndex])
                        recent = tailSlice.flatMap { entry -> [String] in
                            let entryParts = byMessage[entry.row.id] ?? []
                            if entry.role == "user" {
                                let txt = entryParts.compactMap { p -> String? in
                                    guard p.type == "text", boolValue(p.dict["ignored"]) != true else { return nil }
                                    return stringValue(p.dict["text"])
                                }.joined(separator: "\n\n")
                                return ["[User]: \(txt)"]
                            }
                            return entryParts.compactMap { p -> String? in
                                if p.type == "text", let t = stringValue(p.dict["text"]) {
                                    return "[Assistant]: \(t)"
                                }
                                if p.type == "reasoning", let t = stringValue(p.dict["text"]), !t.isEmpty {
                                    return "[Assistant reasoning]: \(t)"
                                }
                                return nil
                            }
                        }.joined(separator: "\n\n")
                    }

                    let reason = boolValue(compaction.dict["auto"]) == true ? "auto" : "manual"
                    var data: [String: JSONValue] = [
                        "status": .string("completed"),
                        "reason": .string(reason),
                        "summary": .string(summaryText),
                        "time": .object(["created": .int(item.row.timeCreated)]),
                    ]
                    if !recent.isEmpty {
                        data["metadata"] = .object(["recent": .string(recent)])
                    }
                    projected.append(makeRow(
                        source: item.row,
                        id: item.row.id,
                        type: .compaction,
                        data: data,
                        timeUpdated: max(item.row.timeUpdated, summary.row.timeUpdated)
                    ))
                    continue
                }

                let subtasks = owned.filter { $0.type == "subtask" }
                let visible = owned.filter { $0.type == "text" && boolValue($0.dict["ignored"]) != true }
                let files = owned.filter { $0.type == "file" }
                let agents = owned.filter { $0.type == "agent" }
                if !subtasks.isEmpty && visible.isEmpty && files.isEmpty && agents.isEmpty { continue }

                let ordinary = visible.filter { boolValue($0.dict["synthetic"]) != true }
                let synthetic = visible.filter { boolValue($0.dict["synthetic"]) == true }
                let attachments = files.compactMap { migrateFilePart($0.dict) }
                let unavailable = files.compactMap { part -> String? in
                    let url = stringValue(part.dict["url"]) ?? ""
                    return url.hasPrefix("data:") ? nil : unavailableFileText(part.dict)
                }

                let text = owned.compactMap { part -> String? in
                    if part.type == "text" && boolValue(part.dict["ignored"]) != true && boolValue(part.dict["synthetic"]) != true {
                        return stringValue(part.dict["text"])
                    }
                    if part.type == "file" {
                        let url = stringValue(part.dict["url"]) ?? ""
                        if !url.hasPrefix("data:") { return unavailableFileText(part.dict) }
                    }
                    return nil
                }.joined(separator: "\n\n")

                let agentAttachments: [JSONValue] = agents.compactMap { part in
                    guard let name = stringValue(part.dict["name"]) else { return nil }
                    var obj: [String: JSONValue] = ["name": .string(name)]
                    if let source = objectValue(part.dict["source"]),
                       let val = stringValue(source["value"]),
                       let start = source["start"],
                       let end = source["end"]
                    {
                        obj["mention"] = .object(["text": .string(val), "start": start, "end": end])
                    }
                    return .object(obj)
                }

                if ordinary.isEmpty && unavailable.isEmpty && !synthetic.isEmpty && attachments.isEmpty && agentAttachments.isEmpty {
                    let synthText = synthetic.compactMap { stringValue($0.dict["text"]) }.joined(separator: "\n\n")
                    projected.append(makeRow(
                        source: item.row,
                        id: item.row.id,
                        type: .synthetic,
                        data: [
                            "text": .string(synthText),
                            "time": .object(["created": .int(item.row.timeCreated)]),
                        ]
                    ))
                    continue
                }

                var userData: [String: JSONValue] = [
                    "text": .string(text),
                    "time": .object(["created": .int(item.row.timeCreated)]),
                ]
                if !attachments.isEmpty { userData["files"] = .array(attachments) }
                if !agentAttachments.isEmpty { userData["agents"] = .array(agentAttachments) }
                projected.append(makeRow(source: item.row, id: item.row.id, type: .user, data: userData))

                if !synthetic.isEmpty {
                    let synthID = deterministicSyntheticID(source: item.row.id, used: &usedIDs)
                    let synthText = synthetic.compactMap { stringValue($0.dict["text"]) }.joined(separator: "\n\n")
                    projected.append(makeRow(
                        source: item.row,
                        id: synthID,
                        type: .synthetic,
                        data: [
                            "text": .string(synthText),
                            "time": .object(["created": .int(item.row.timeCreated)]),
                        ]
                    ))
                }
                continue
            }

            // Assistant message
            if let parentID = stringValue(item.dict["parentID"]),
               let parentParts = byMessage[parentID],
               parentParts.contains(where: { $0.type == "subtask" }),
               owned.contains(where: { $0.type == "tool" && stringValue($0.dict["tool"]) == "task" })
            {
                continue
            }

            let content: [JSONValue] = owned.compactMap { part in
                switch part.type {
                case "text":
                    guard let text = stringValue(part.dict["text"]) else { return nil }
                    var obj: [String: JSONValue] = ["type": .string("text"), "text": .string(text)]
                    if let meta = part.dict["metadata"] { obj["native"] = meta }
                    return .object(obj)
                case "reasoning":
                    guard let text = stringValue(part.dict["text"]) else { return nil }
                    var timeObj: [String: JSONValue] = [:]
                    if let t = objectValue(part.dict["time"]) {
                        if let start = t["start"] { timeObj["created"] = start }
                        if let end = t["end"] { timeObj["completed"] = end }
                    }
                    var obj: [String: JSONValue] = [
                        "type": .string("reasoning"),
                        "text": .string(text),
                        "time": .object(timeObj),
                    ]
                    if let meta = part.dict["metadata"] { obj["native"] = meta }
                    return .object(obj)
                case "tool":
                    return migrateToolPart(part.dict, fallbackTime: item.row.timeCreated)
                default:
                    return nil
                }
            }

            let startSnap = owned.first(where: { $0.type == "step-start" && stringValue($0.dict["snapshot"]) != nil })
                .flatMap { stringValue($0.dict["snapshot"]) }
                ?? owned.first(where: { $0.type == "snapshot" }).flatMap { stringValue($0.dict["snapshot"]) }
                ?? owned.first(where: { $0.type == "patch" }).flatMap { stringValue($0.dict["hash"]) }
            let endSnap = owned.last(where: { $0.type == "step-finish" && stringValue($0.dict["snapshot"]) != nil })
                .flatMap { stringValue($0.dict["snapshot"]) }
            var snapshotFilesSet = Set<String>()
            var snapshotFiles: [JSONValue] = []
            for p in owned where p.type == "patch" {
                if case .array(let arr) = p.dict["files"] {
                    for f in arr {
                        if case .string(let s) = f, snapshotFilesSet.insert(s).inserted {
                            snapshotFiles.append(.string(s))
                        }
                    }
                }
            }

            let tokensObj = objectValue(item.dict["tokens"]) ?? [:]
            let cacheObj = objectValue(tokensObj["cache"]) ?? [:]
            let costVal = numberValue(item.dict["cost"]) ?? 0
            let completedTime = objectValue(item.dict["time"]).flatMap { numberValue($0["completed"]) }
            var timeObj: [String: JSONValue] = ["created": .int(item.row.timeCreated)]
            if completedTime != nil {
                timeObj["completed"] = .int(item.row.timeUpdated)
            }

            var assistantData: [String: JSONValue] = [
                "agent": .string(stringValue(item.dict["agent"]) ?? "build"),
                "model": .object([
                    "providerID": .string(stringValue(item.dict["providerID"]) ?? ""),
                    "id": .string(stringValue(item.dict["modelID"]) ?? ""),
                    "variant": .string(stringValue(item.dict["variant"]) ?? "default"),
                ]),
                "content": .array(content),
                "cost": .double(costVal),
                "tokens": .object([
                    "input": .double(numberValue(tokensObj["input"]) ?? 0),
                    "output": .double(numberValue(tokensObj["output"]) ?? 0),
                    "reasoning": .double(numberValue(tokensObj["reasoning"]) ?? 0),
                    "cache": .object([
                        "read": .double(numberValue(cacheObj["read"]) ?? 0),
                        "write": .double(numberValue(cacheObj["write"]) ?? 0),
                    ]),
                ]),
                "time": .object(timeObj),
            ]
            if startSnap != nil || endSnap != nil || !snapshotFiles.isEmpty {
                var snapObj: [String: JSONValue] = [:]
                if let startSnap { snapObj["start"] = .string(startSnap) }
                if let endSnap { snapObj["end"] = .string(endSnap) }
                if !snapshotFiles.isEmpty { snapObj["files"] = .array(snapshotFiles) }
                assistantData["snapshot"] = .object(snapObj)
            }
            if let finish = normalizeFinish(stringValue(item.dict["finish"])) {
                assistantData["finish"] = .string(finish)
            }
            if let errObj = objectValue(item.dict["error"]) {
                assistantData["error"] = migrateAssistantError(errObj)
            }

            projected.append(makeRow(source: item.row, id: item.row.id, type: .assistant, data: assistantData))
        }

        // Assign sequential `seq`
        var sequenced: [TransformedMessageRow] = projected.enumerated().map { idx, row in
            TransformedMessageRow(
                id: row.id,
                sessionID: row.sessionID,
                type: row.type,
                seq: idx,
                timeCreated: row.timeCreated,
                timeUpdated: row.timeUpdated,
                data: row.data
            )
        }

        if let last = sequenced.last, let notice = legacyToolNotice(sequenced) {
            let noticeID = deterministicSyntheticID(source: last.id, used: &usedIDs)
            sequenced.append(TransformedMessageRow(
                id: noticeID,
                sessionID: last.sessionID,
                type: .system,
                seq: sequenced.count,
                timeCreated: last.timeCreated,
                timeUpdated: last.timeUpdated,
                data: [
                    "text": .string(notice),
                    "time": .object(["created": .int(last.timeCreated)]),
                ]
            ))
        }

        // Aggregate session usage and latest user agent/model
        var totalCost = 0.0
        var totalInput = 0.0
        var totalOutput = 0.0
        var totalReasoning = 0.0
        var totalCacheRead = 0.0
        var totalCacheWrite = 0.0
        for item in decodedMessages where item.role == "assistant" {
            totalCost += numberValue(item.dict["cost"]) ?? 0
            let tok = objectValue(item.dict["tokens"]) ?? [:]
            let cache = objectValue(tok["cache"]) ?? [:]
            totalInput += numberValue(tok["input"]) ?? 0
            totalOutput += numberValue(tok["output"]) ?? 0
            totalReasoning += numberValue(tok["reasoning"]) ?? 0
            totalCacheRead += numberValue(cache["read"]) ?? 0
            totalCacheWrite += numberValue(cache["write"]) ?? 0
        }

        let latestUser = decodedMessages.last { item in
            guard item.role == "user" else { return false }
            let owned = byMessage[item.row.id] ?? []
            if owned.contains(where: { $0.type == "compaction" }) { return false }
            return !owned.contains(where: { $0.type == "subtask" }) || !owned.allSatisfy({ $0.type == "subtask" })
        }

        let resolvedAgent = input.session.agent ?? latestUser.flatMap { stringValue($0.dict["agent"]) }
        let resolvedModel: SessionSchema.ModelRef? = input.session.model ?? latestUser.flatMap { user in
            guard let modelObj = objectValue(user.dict["model"]),
                  let modelID = stringValue(modelObj["modelID"]),
                  let providerID = stringValue(modelObj["providerID"])
            else { return nil }
            return SessionSchema.ModelRef(
                id: modelID,
                providerID: providerID,
                variant: stringValue(modelObj["variant"]) ?? "default"
            )
        }

        return TransformResult(
            messages: sequenced,
            session: TransformedSessionUpdate(
                agent: resolvedAgent,
                model: resolvedModel,
                cost: totalCost,
                tokensInput: totalInput,
                tokensOutput: totalOutput,
                tokensReasoning: totalReasoning,
                tokensCacheRead: totalCacheRead,
                tokensCacheWrite: totalCacheWrite
            ),
            watermark: sequenced.count - 1,
            warnings: warnings
        )
    }

    /// Returns whether V1-to-V2 migration is required, running, errored, or completed.
    // parity: core/src/database/v1-migration.bun.ts#status [status=implemented hash=2bf03e0ca2d2]
    public static func status(db: any SQLiteDatabase) throws -> Status {
        guard try hasLegacySessions(db) else { return .completed }
        let state = runtimeState.withLock { $0 }
        switch state {
        case .running(let progress):
            return .running(progress: progress)
        case .error(let message):
            return .error(message)
        case .idle:
            if let phase = try readMigrationPhase(db), phase == "completed" {
                return .completed
            }
            return .required
        }
    }

    /// Layer provider executing V1 migration on startup (`database/v1-migration.bun.ts#layer`).
    // parity: core/src/database/v1-migration.bun.ts#layer [status=adapted hash=95173caf2d00]
    public static let layer: LayerNode.ExecutableLayer = LayerNode.ExecutableLayer { deps, _ in
        if let db = deps.get(CoreDatabaseStore.Service.serviceKey, as: CoreDatabaseStore.Service.self)?.db {
            _ = try await run(db: db)
        }
        return LayerNode.Output()
    }

    /// Runs the durable V1-to-V2 session migration on `db`.
    // parity: core/src/database/v1-migration.bun.ts#run [status=implemented hash=e504fe69eea8]
    @discardableResult
    public static func run(db: any SQLiteDatabase, globalRoot: String = "/") async throws -> RunResult {
        if let phase = try readMigrationPhase(db), phase == "completed" {
            return RunResult(status: "completed")
        }
        guard try hasLegacySessions(db) else {
            return RunResult(status: "completed")
        }

        runtimeState.withLock { $0 = .running(Progress(label: "Clearing old events")) }
        do {
            let now = Flock.currentEpochMs()
            _ = try db.execute(
                """
                INSERT OR IGNORE INTO `project` (`id`, `worktree`, `time_created`, `time_updated`, `time_active`, `sandboxes`)
                VALUES (?, ?, ?, ?, ?, '[]')
                """,
                parameters: [
                    .text(ProjectID.global.rawValue),
                    .text(globalRoot),
                    .integer(now),
                    .integer(now),
                    .integer(now),
                ]
            )

            let existingPhase = try readMigrationPhase(db)
            if existingPhase == nil {
                try db.transaction {
                    _ = try db.execute("DELETE FROM `event`")
                    _ = try db.execute(
                        "INSERT OR REPLACE INTO `kv` (`key`, `value`, `time_created`, `time_updated`) VALUES (?, ?, ?, ?)",
                        parameters: [
                            .text(migrationStateKey),
                            .text("{\"phase\":\"sessions\"}"),
                            .integer(now),
                            .integer(now),
                        ]
                    )
                }
            }

            let legacySessions = try db.query(
                "SELECT id, project_id, workspace_id, parent_id, slug, directory, path, title, version, time_created, time_updated, agent, model FROM `session` ORDER BY id DESC"
            )
            let total = legacySessions.count
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]

            for (idx, row) in legacySessions.enumerated() {
                guard let id = row.string("id"),
                      let slug = row.string("slug"),
                      let directory = row.string("directory"),
                      let version = row.string("version"),
                      let timeCreated = row.int64("time_created"),
                      let timeUpdated = row.int64("time_updated")
                else { continue }

                let rawProjectID = row.string("project_id") ?? ProjectID.global.rawValue
                let projectExists = try db.queryOne(
                    "SELECT id FROM `project` WHERE id = ?",
                    parameters: [.text(rawProjectID)]
                ) != nil
                let projectID = projectExists ? rawProjectID : ProjectID.global.rawValue
                let normalizedDir = (directory.isEmpty || CoreDatabaseSchema.storedAbsolutePath(directory) != nil)
                    ? directory
                    : globalRoot

                let srcMessages = try db.query(
                    "SELECT id, session_id, time_created, time_updated, data FROM `message` WHERE session_id = ?",
                    parameters: [.text(id)]
                ).compactMap { r -> SourceMessage? in
                    guard let mid = r.string("id"),
                          let sid = r.string("session_id"),
                          let tc = r.int64("time_created"),
                          let tu = r.int64("time_updated"),
                          let d = r.string("data")
                    else { return nil }
                    return SourceMessage(id: mid, sessionID: sid, timeCreated: tc, timeUpdated: tu, data: d)
                }
                let srcParts = try db.query(
                    "SELECT id, message_id, session_id, time_created, time_updated, data FROM `part` WHERE session_id = ?",
                    parameters: [.text(id)]
                ).compactMap { r -> SourcePart? in
                    guard let pid = r.string("id"),
                          let mid = r.string("message_id"),
                          let sid = r.string("session_id"),
                          let tc = r.int64("time_created"),
                          let tu = r.int64("time_updated"),
                          let d = r.string("data")
                    else { return nil }
                    return SourcePart(id: pid, messageID: mid, sessionID: sid, timeCreated: tc, timeUpdated: tu, data: d)
                }

                let existingModel: SessionSchema.ModelRef? = row.string("model")
                    .flatMap { $0.data(using: .utf8) }
                    .flatMap { try? JSONDecoder().decode(SessionSchema.ModelRef.self, from: $0) }
                let transformed = transformSession(TransformInput(
                    session: SessionRowInput(id: id, agent: row.string("agent"), model: existingModel),
                    messages: srcMessages,
                    parts: srcParts
                ))

                try db.transaction {
                    let modelJSON: SQLiteValue = try transformed.session.model.map {
                        .text(String(decoding: try encoder.encode($0), as: UTF8.self))
                    } ?? .null
                    _ = try db.execute(
                        """
                        INSERT OR IGNORE INTO `session_v2` (
                          id, project_id, workspace_id, parent_id, slug, directory, path, title, version,
                          cost, tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write,
                          agent, model, time_created, time_updated
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        parameters: [
                            .text(id),
                            .text(projectID),
                            row.string("workspace_id").map(SQLiteValue.text) ?? .null,
                            row.string("parent_id").map(SQLiteValue.text) ?? .null,
                            .text(slug),
                            .text(normalizedDir),
                            row.string("path").map(SQLiteValue.text) ?? .null,
                            row.string("title").map(SQLiteValue.text) ?? .null,
                            .text(version),
                            .real(transformed.session.cost),
                            .integer(Int64(transformed.session.tokensInput)),
                            .integer(Int64(transformed.session.tokensOutput)),
                            .integer(Int64(transformed.session.tokensReasoning)),
                            .integer(Int64(transformed.session.tokensCacheRead)),
                            .integer(Int64(transformed.session.tokensCacheWrite)),
                            transformed.session.agent.map(SQLiteValue.text) ?? .null,
                            modelJSON,
                            .integer(timeCreated),
                            .integer(timeUpdated),
                        ]
                    )
                    _ = try db.execute("DELETE FROM `session_message` WHERE session_id = ?", parameters: [.text(id)])
                    for message in transformed.messages {
                        let json = String(decoding: try encoder.encode(JSONValue.object(message.data)), as: UTF8.self)
                        _ = try db.execute(
                            """
                            INSERT INTO `session_message` (id, session_id, type, seq, time_created, time_updated, data)
                            VALUES (?, ?, ?, ?, ?, ?, ?)
                            """,
                            parameters: [
                                .text(message.id),
                                .text(message.sessionID),
                                .text(message.type.rawValue),
                                .integer(Int64(message.seq)),
                                .integer(message.timeCreated),
                                .integer(message.timeUpdated),
                                .text(json),
                            ]
                        )
                    }
                    _ = try db.execute(
                        """
                        INSERT INTO `event_sequence` (aggregate_id, seq, owner_id)
                        VALUES (?, ?, NULL)
                        ON CONFLICT (aggregate_id) DO UPDATE SET seq = excluded.seq, owner_id = NULL
                        """,
                        parameters: [.text(id), .integer(Int64(transformed.watermark))]
                    )
                }

                runtimeState.withLock {
                    $0 = .running(Progress(label: "Migrating sessions", numerator: idx + 1, denominator: total))
                }
            }

            let doneNow = Flock.currentEpochMs()
            _ = try db.execute(
                """
                INSERT INTO `kv` (`key`, `value`, `time_created`, `time_updated`)
                VALUES (?, ?, ?, ?)
                ON CONFLICT (`key`) DO UPDATE SET `value` = excluded.`value`, `time_updated` = excluded.`time_updated`
                """,
                parameters: [
                    .text(migrationStateKey),
                    .text("{\"phase\":\"completed\"}"),
                    .integer(doneNow),
                    .integer(doneNow),
                ]
            )
            runtimeState.withLock { $0 = .idle }
            return RunResult(status: "completed")
        } catch {
            runtimeState.withLock { $0 = .error(String(describing: error)) }
            throw error
        }
    }

    private static func hasLegacySessions(_ db: any SQLiteDatabase) throws -> Bool {
        try db.queryOne(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'session'"
        ) != nil
    }

    private static func readMigrationPhase(_ db: any SQLiteDatabase) throws -> String? {
        guard let row = try db.queryOne(
            "SELECT `value` FROM `kv` WHERE `key` = ?",
            parameters: [.text(migrationStateKey)]
        ),
              let raw = row.string("value"),
              let data = raw.data(using: .utf8),
              let val = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let obj) = val,
              case .string(let phase) = obj["phase"]
        else { return nil }
        return phase
    }

    // MARK: - Transformation Helpers

    private static func stringValue(_ v: JSONValue?) -> String? {
        if case .string(let s) = v { return s }
        return nil
    }

    private static func boolValue(_ v: JSONValue?) -> Bool? {
        if case .bool(let b) = v { return b }
        return nil
    }

    private static func numberValue(_ v: JSONValue?) -> Double? {
        switch v {
        case .int(let i): Double(i)
        case .double(let d): d
        default: nil
        }
    }

    private static func objectValue(_ v: JSONValue?) -> [String: JSONValue]? {
        if case .object(let o) = v { return o }
        return nil
    }

    private static func normalizeFinish(_ finish: String?) -> String? {
        guard let finish, !finish.isEmpty else { return nil }
        let known: Set<String> = ["stop", "length", "tool-calls", "content-filter", "error", "unknown"]
        return known.contains(finish) ? finish : "unknown"
    }

    private static func migrateAssistantError(_ error: [String: JSONValue]) -> JSONValue {
        let name = stringValue(error["name"]) ?? "UnknownError"
        let dataObj = objectValue(error["data"]) ?? [:]
        let message: String = stringValue(dataObj["message"]) ?? (
            name == "MessageOutputLengthError" ? "The model exceeded its output limit" : name
        )
        let type: String = switch name {
        case "ProviderAuthError": "provider.auth"
        case "ContentFilterError": "provider.content-filter"
        case "ContextOverflowError": "provider.invalid-request"
        case "StructuredOutputError", "MessageOutputLengthError": "provider.invalid-output"
        case "MessageAbortedError": "aborted"
        case "APIError": "provider.error"
        default: "unknown"
        }
        return .object(["type": .string(type), "message": .string(message)])
    }

    private static func migrateToolPart(_ part: [String: JSONValue], fallbackTime: Int64) -> JSONValue? {
        guard let callID = stringValue(part["callID"]),
              let toolName = stringValue(part["tool"]),
              let stateObj = objectValue(part["state"]),
              let status = stringValue(stateObj["status"])
        else { return nil }

        let inputVal = stateObj["input"] ?? .object([:])
        var base: [String: JSONValue] = [
            "type": .string("tool"),
            "id": .string(callID),
            "name": .string(toolName),
        ]
        if let meta = part["metadata"] { base["native"] = meta }

        if status == "completed" {
            let timeObj = objectValue(stateObj["time"]) ?? [:]
            var content: [JSONValue] = []
            if timeObj["compacted"] != nil {
                content = [.object(["type": .string("text"), "text": .string("[Old tool result content cleared]")])]
            } else {
                content.append(.object(["type": .string("text"), "text": .string(stringValue(stateObj["output"]) ?? "")]))
                if case .array(let atts) = stateObj["attachments"] {
                    for att in atts {
                        guard case .object(let f) = att,
                              let url = stringValue(f["url"]),
                              let mime = stringValue(f["mime"])
                        else { continue }
                        var fObj: [String: JSONValue] = [
                            "type": .string("file"),
                            "uri": .string(url),
                            "mime": .string(mime),
                        ]
                        if let name = stringValue(f["filename"]) { fObj["name"] = .string(name) }
                        content.append(.object(fObj))
                    }
                }
            }
            var st: [String: JSONValue] = [
                "status": .string("completed"),
                "input": inputVal,
                "content": .array(content),
            ]
            if let meta = stateObj["metadata"] { st["metadata"] = meta }
            base["state"] = .object(st)
            base["time"] = .object([
                "created": timeObj["start"] ?? .int(fallbackTime),
                "completed": timeObj["end"] ?? .int(fallbackTime),
            ])
            return .object(base)
        }

        if status == "error" {
            let timeObj = objectValue(stateObj["time"]) ?? [:]
            let errMsg = stringValue(stateObj["error"]) ?? "Tool execution failed"
            var st: [String: JSONValue] = [
                "status": .string("error"),
                "input": inputVal,
                "error": .object(["type": .string("tool.execution"), "message": .string(errMsg)]),
            ]
            if let metaObj = objectValue(stateObj["metadata"]) {
                if let out = stringValue(metaObj["output"]) {
                    st["content"] = .array([.object(["type": .string("text"), "text": .string(out)])])
                }
                st["metadata"] = .object(metaObj)
            }
            base["state"] = .object(st)
            base["time"] = .object([
                "created": timeObj["start"] ?? .int(fallbackTime),
                "completed": timeObj["end"] ?? .int(fallbackTime),
            ])
            return .object(base)
        }

        var st: [String: JSONValue] = [
            "status": .string("error"),
            "input": inputVal,
            "error": .object([
                "type": .string("tool.interrupted"),
                "message": .string("Tool execution was interrupted before V2 migration"),
            ]),
        ]
        if status == "running", let meta = stateObj["metadata"] {
            st["metadata"] = meta
        }
        let createdTime = status == "running"
            ? (objectValue(stateObj["time"])?["start"] ?? .int(fallbackTime))
            : .int(fallbackTime)
        base["state"] = .object(st)
        base["time"] = .object(["created": createdTime])
        return .object(base)
    }

    private static func migrateFilePart(_ part: [String: JSONValue]) -> JSONValue? {
        guard let url = stringValue(part["url"]),
              url.hasPrefix("data:"),
              let comma = url.firstIndex(of: ","),
              let mime = stringValue(part["mime"])
        else { return nil }
        let header = String(url[..<comma])
        let payload = String(url[url.index(after: comma)...])
        let base64Data: String
        if header.hasSuffix(";base64") {
            let bytes = (try? base64ToBytes(payload)) ?? []
            base64Data = bytesToBase64(bytes)
        } else {
            let decoded = payload.removingPercentEncoding ?? payload
            base64Data = bytesToBase64(Array(decoded.utf8))
        }

        var sourceObj: [String: JSONValue] = ["type": .string("inline")]
        if let src = objectValue(part["source"]),
           stringValue(src["type"]) == "resource",
           let uri = stringValue(src["uri"])
        {
            sourceObj = ["type": .string("uri"), "uri": .string(uri)]
        }

        var obj: [String: JSONValue] = [
            "data": .string(base64Data),
            "mime": .string(mime),
            "source": .object(sourceObj),
        ]
        if let filename = stringValue(part["filename"]) { obj["name"] = .string(filename) }
        if let src = objectValue(part["source"]),
           let textObj = objectValue(src["text"]),
           let val = stringValue(textObj["value"]),
           let start = textObj["start"],
           let end = textObj["end"]
        {
            obj["mention"] = .object(["text": .string(val), "start": start, "end": end])
        }
        return .object(obj)
    }

    private static func unavailableFileText(_ part: [String: JSONValue]) -> String {
        let mime = stringValue(part["mime"]) ?? "application/octet-stream"
        let label = stringValue(part["filename"])
            ?? objectValue(part["source"]).flatMap {
                stringValue($0["type"]) == "resource" ? stringValue($0["uri"]) : nil
            }
            ?? (stringValue(part["url"]) ?? "")
        return "[Attachment unavailable after migration: \(label) (\(mime))]"
    }

    private static func legacyToolNotice(_ messages: [TransformedMessageRow]) -> String? {
        let startIdx = messages.lastIndex(where: { $0.type == .compaction }) ?? -1
        var called = Set<String>()
        if startIdx + 1 < messages.count {
            for message in messages[(startIdx + 1)...] where message.type == .assistant {
                if case .array(let content) = message.data["content"] {
                    for part in content {
                        if case .object(let obj) = part,
                           stringValue(obj["type"]) == "tool",
                           let name = stringValue(obj["name"])
                        {
                            called.insert(name)
                        }
                    }
                }
            }
        }

        func formatList(_ names: [String]) -> String {
            names.map { "`\($0)`" }.joined(separator: ", ")
        }

        let renamedOrder = ["bash", "task", "apply_patch"].filter { called.contains($0) }
        let paths = pathTools.filter { called.contains($0) }
        let removed = removedTools.filter { called.contains($0) }
        var parts: [String] = []

        if renamedOrder.count == 1, let first = renamedOrder.first, let target = renamedTools[first] {
            parts.append("The `\(first)` tool is now `\(target)` and must be called by that name.")
        } else if renamedOrder.count > 1 {
            let mappings = renamedOrder.compactMap { name in
                renamedTools[name].map { "`\(name)` is now `\($0)`" }
            }.joined(separator: "; ")
            parts.append("The following tools were renamed and must be called by their new names: \(mappings).")
        }
        if called.contains("task") {
            parts.append("The `subagent` tool takes `agent` instead of `subagent_type` and `sessionID` instead of `task_id`.")
        }
        if paths.count == 1, let first = paths.first {
            parts.append("The `\(first)` tool now takes `path` instead of `filePath`.")
        } else if paths.count > 1 {
            parts.append("The following tools now take `path` instead of `filePath`: \(formatList(paths)).")
        }
        if called.contains("skill") {
            parts.append("The `skill` tool now takes `id` instead of `name`.")
        }
        if removed.count == 1, let first = removed.first {
            parts.append("The `\(first)` tool is no longer available by default. Only call it if it is in your tool list.")
        } else if removed.count > 1 {
            parts.append("The following tools are no longer available by default. Only call them if they are in your tool list: \(formatList(removed)).")
        }

        if parts.isEmpty { return nil }
        return (["The available tools have changed."] + parts).joined(separator: "\n\n")
    }

    private static let base62Alphabet: [UInt8] = Array(
        "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8
    )

    private static func deterministicSyntheticID(source: String, used: inout Set<String>) -> String {
        let prefix = String(source.prefix(16))
        var salt = 0
        while true {
            let input = salt == 0 ? "v1-synthetic:\(source)" : "v1-synthetic:\(source):\(salt)"
            let hex = Hash.sha256(input)
            var bytes = hexToBytes(hex)
            var suffixBytes: [UInt8] = []
            suffixBytes.reserveCapacity(14)
            while suffixBytes.count < 14 {
                let rem = divideBigEndianBytes(&bytes, by: 62)
                suffixBytes.append(base62Alphabet[rem])
            }
            suffixBytes.reverse()
            let candidate = prefix + String(decoding: suffixBytes, as: UTF8.self)
            if used.insert(candidate).inserted {
                return candidate
            }
            salt += 1
        }
    }

    private static func hexToBytes(_ hex: String) -> [UInt8] {
        let chars = Array(hex.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i + 1 < chars.count {
            let hi = hexVal(chars[i])
            let lo = hexVal(chars[i + 1])
            out.append((hi << 4) | lo)
            i += 2
        }
        return out
    }

    private static func hexVal(_ b: UInt8) -> UInt8 {
        if b >= 0x30 && b <= 0x39 { return b - 0x30 }
        if b >= 0x61 && b <= 0x66 { return b - 0x61 + 10 }
        if b >= 0x41 && b <= 0x46 { return b - 0x41 + 10 }
        return 0
    }

    private static func divideBigEndianBytes(_ bytes: inout [UInt8], by divisor: Int) -> Int {
        var remainder = 0
        for idx in bytes.indices {
            let current = remainder * 256 + Int(bytes[idx])
            bytes[idx] = UInt8(current / divisor)
            remainder = current % divisor
        }
        return remainder
    }
}

// MARK: - database/v1-migration.noop.ts

/// No-op V1 migration surface for non-legacy runtimes (`database/v1-migration.noop.ts`).
public enum CoreDatabaseV1MigrationNoop {
    // parity: core/src/database/v1-migration.noop.ts#Status [status=adapted hash=802d5158f5ae]
    public struct Status: Equatable, Hashable, Sendable {
        public let status: String

        public init() {
            self.status = "completed"
        }
    }

    // parity: core/src/database/v1-migration.noop.ts#layer [status=adapted hash=b79f4917c805]
    public static let layer: LayerNode.ExecutableLayer = .empty

    // parity: core/src/database/v1-migration.noop.ts#status [status=adapted hash=b0e7665909f8]
    public static func status() -> Status {
        Status()
    }

    // parity: core/src/database/v1-migration.noop.ts#run [status=adapted hash=844f61eeddb4]
    public static func run() -> Status {
        Status()
    }
}
