#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

/// Canonical SQLite table metadata, column codecs, parameter batching, storage-failure
/// classification, and exact DDL bootstrap statements for all 23 OpenCode tables.
///
/// Ports `packages/core/src/database/{schema.sql,path,batch,storage-failure}.ts`,
/// `packages/core/src/event/sql.ts`, and `packages/core/src/session/sql.ts`.
public enum CoreDatabaseSchema {
    // MARK: - Table & Column Descriptors

    public struct TableDescriptor: Equatable, Hashable, Sendable {
        public let name: String
        public let columns: [String]

        public init(name: String, columns: [String]) {
            self.name = name
            self.columns = columns
        }
    }

    public struct ColumnCodec<Value: Sendable>: Sendable {
        public let dataType: String
        public let toDriver: @Sendable (Value) throws -> String
        public let fromDriver: @Sendable (String) throws -> Value

        public init(
            dataType: String = "text",
            toDriver: @escaping @Sendable (Value) throws -> String,
            fromDriver: @escaping @Sendable (String) throws -> Value
        ) {
            self.dataType = dataType
            self.toDriver = toDriver
            self.fromDriver = fromDriver
        }
    }

    public enum PathColumnError: Error, Equatable, Sendable, CustomStringConvertible {
        case notAbsolute(String)
        case invalidJSONArray(String)

        public var description: String {
            switch self {
            case .notAbsolute(let path): "Path is not absolute: \(path)"
            case .invalidJSONArray(let raw): "Invalid JSON path array: \(raw)"
            }
        }
    }

    // MARK: - database/schema.sql.ts

    /// Standard creation/update millisecond timestamp columns shared by persisted tables.
    // parity: core/src/database/schema.sql.ts#Timestamps [status=implemented hash=543a1649f3a2]
    public static let timestamps: [String] = ["time_created", "time_updated"]

    // MARK: - database/path.ts

    private static func storagePath(_ input: String, isWindows: Bool = Platform.current == .windows) -> String {
        guard isWindows else { return input }
        return input.replacing("\\", with: "/")
    }

    private static func isWindowsStoragePath(_ input: String) -> Bool {
        if input.hasPrefix("//") { return true }
        let bytes = Array(input.utf8)
        guard bytes.count >= 3 else { return false }
        let b0 = bytes[0]
        let isLetter = (b0 >= 0x41 && b0 <= 0x5A) || (b0 >= 0x61 && b0 <= 0x7A)
        return isLetter && bytes[1] == 0x3A && bytes[2] == 0x2F // `X:/`
    }

    private static func toPlatform(_ input: String, isWindows: Bool = Platform.current == .windows) -> String {
        guard isWindows && isWindowsStoragePath(input) else { return input }
        return input.replacing("/", with: "\\")
    }

    /// Validates and normalizes an absolute path for cross-OS SQLite storage.
    // parity: core/src/database/path.ts#storedAbsolutePath [status=implemented hash=1347078206e6]
    public static func storedAbsolutePath(_ input: String) -> String? {
        let result = storagePath(input)
        if result.hasPrefix("/") || isWindowsStoragePath(result) {
            return result
        }
        return nil
    }

    private static func requireAbsolute(_ input: String) throws(PathColumnError) -> String {
        guard let result = storedAbsolutePath(input) else {
            throw .notAbsolute(input)
        }
        return result
    }

    /// Column codec enforcing normalized absolute paths (`database/path.ts#absoluteColumn`).
    // parity: core/src/database/path.ts#absoluteColumn [status=implemented hash=6113eb88df68]
    public static let absoluteColumn = ColumnCodec<String>(
        dataType: "text",
        toDriver: { input in try requireAbsolute(input) },
        fromDriver: { input in toPlatform(try requireAbsolute(input)) }
    )

    /// Column codec preserving legacy empty directory values while validating real directories.
    // parity: core/src/database/path.ts#directoryColumn [status=implemented hash=f92b269d72e8]
    public static let directoryColumn = ColumnCodec<String>(
        dataType: "text",
        toDriver: { input in input.isEmpty ? input : try requireAbsolute(input) },
        fromDriver: { input in input.isEmpty ? input : toPlatform(try requireAbsolute(input)) }
    )

    /// Column codec normalizing relative storage paths to forward slashes on Windows.
    // parity: core/src/database/path.ts#pathColumn [status=implemented hash=132df29ef1dd]
    public static let pathColumn = ColumnCodec<String>(
        dataType: "text",
        toDriver: { input in storagePath(input) },
        fromDriver: { input in storagePath(input) }
    )

    /// Column codec encoding/decoding JSON arrays of absolute paths.
    // parity: core/src/database/path.ts#absoluteArrayColumn [status=implemented hash=bf783b2280ea]
    public static let absoluteArrayColumn = ColumnCodec<[String]>(
        dataType: "text",
        toDriver: { inputs in
            let normalized = try inputs.map { try requireAbsolute($0) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let data = try encoder.encode(normalized)
            return String(decoding: data, as: UTF8.self)
        },
        fromDriver: { raw in
            guard let data = raw.data(using: .utf8),
                  let items = try? JSONDecoder().decode([String].self, from: data)
            else {
                throw PathColumnError.invalidJSONArray(raw)
            }
            return try items.map { toPlatform(try requireAbsolute($0)) }
        }
    )

    // MARK: - database/batch.ts

    /// Maximum bound SQL parameters per statement (matching Durable Object SQLite's 100-parameter ceiling).
    // parity: core/src/database/batch.ts#MaxBoundParameters [status=implemented hash=ae4cca021a60]
    public static let maxBoundParameters: Int = 100

    /// Splits `items` into batches binding at most `maxBoundParameters` parameters (`perItem` per item + `fixed`).
    // parity: core/src/database/batch.ts#batches [status=implemented hash=2d5f2d0ac780]
    public static func batches<T>(_ items: [T], perItem: Int, fixed: Int = 0) -> [[T]] {
        guard !items.isEmpty else { return [] }
        let safePerItem = max(1, perItem)
        let size = max(1, (maxBoundParameters - fixed) / safePerItem)
        var result: [[T]] = []
        result.reserveCapacity((items.count + size - 1) / size)
        var offset = 0
        while offset < items.count {
            let end = min(items.count, offset + size)
            result.append(Array(items[offset..<end]))
            offset = end
        }
        return result
    }

    /// Splits `rows` into multi-row insert batches for `table` (one bound parameter per column).
    // parity: core/src/database/batch.ts#insertBatches [status=implemented hash=82da20d89c4e]
    public static func insertBatches<T>(_ table: TableDescriptor, rows: [T], fixed: Int = 0) -> [[T]] {
        batches(rows, perItem: table.columns.count, fixed: fixed)
    }

    // MARK: - event/sql.ts

    // parity: core/src/event/sql.ts#EventSequenceTable [status=implemented hash=f0ef54cdf52f]
    public static let eventSequenceTable = TableDescriptor(
        name: "event_sequence",
        columns: ["aggregate_id", "seq", "owner_id"]
    )

    // parity: core/src/event/sql.ts#EventTable [status=implemented hash=37c112ad95db]
    public static let eventTable = TableDescriptor(
        name: "event",
        columns: ["id", "aggregate_id", "seq", "created", "type", "data"]
    )

    // MARK: - session/sql.ts

    // parity: core/src/session/sql.ts#SessionPartData [status=implemented hash=b9d2327f8f54]
    public typealias SessionPartData = SessionMessageSchema.AssistantContentEncoded

    // parity: core/src/session/sql.ts#SessionTable [status=implemented hash=75113160ba3e]
    public static let sessionTable = TableDescriptor(
        name: "session_v2",
        columns: [
            "id", "project_id", "workspace_id", "parent_id", "fork_session_id", "fork_boundary",
            "slug", "directory", "path", "title", "version", "share_url",
            "summary_additions", "summary_deletions", "summary_files", "summary_diffs", "metadata",
            "cost", "tokens_input", "tokens_output", "tokens_reasoning", "tokens_cache_read", "tokens_cache_write",
            "revert", "permission", "agent", "model",
            "time_created", "time_updated", "time_busy", "time_idle", "time_viewed",
            "idle_outcome", "time_compacting", "time_archived", "time_suspended", "resume_attempts",
        ]
    )

    // parity: core/src/session/sql.ts#SessionMessageTable [status=implemented hash=347654f7d6f1]
    public static let sessionMessageTable = TableDescriptor(
        name: "session_message",
        columns: ["id", "session_id", "type", "seq", "time_created", "time_updated", "data"]
    )

    // parity: core/src/session/sql.ts#SessionPartTable [status=implemented hash=302f1ad22faa]
    public static let sessionPartTable = TableDescriptor(
        name: "session_part",
        columns: ["message_id", "session_id", "ordinal", "type", "call_id", "time_created", "time_updated", "data"]
    )

    // parity: core/src/session/sql.ts#SessionInboxTable [status=implemented hash=eabdf9818737]
    public static let sessionInboxTable = TableDescriptor(
        name: "session_inbox",
        columns: ["id", "session_id", "type", "payload", "delivery", "enqueued_seq", "time_created"]
    )

    // parity: core/src/session/sql.ts#InstructionEntryTable [status=implemented hash=c1363f689532]
    public static let instructionEntryTable = TableDescriptor(
        name: "instruction_entry",
        columns: ["session_id", "key", "value", "removed", "time_created", "time_updated"]
    )

    // parity: core/src/session/sql.ts#InstructionBlobTable [status=implemented hash=12b01f6ac2f3]
    public static let instructionBlobTable = TableDescriptor(
        name: "instruction_blob",
        columns: ["hash", "value"]
    )

    // parity: core/src/session/sql.ts#InstructionStateTable [status=implemented hash=8edf04c4911d]
    public static let instructionStateTable = TableDescriptor(
        name: "instruction_state",
        columns: ["session_id", "epoch_start", "through_seq", "initial_values", "current_values"]
    )

    // parity: core/src/session/sql.ts#BlobTable [status=implemented hash=f187d6eda24e]
    public static let blobTable = TableDescriptor(
        name: "blob",
        columns: ["hash", "mime", "bytes", "width", "height", "data", "time_created"]
    )

    // parity: core/src/session/sql.ts#BlobRefTable [status=implemented hash=349c746f5b19]
    public static let blobRefTable = TableDescriptor(
        name: "blob_ref",
        columns: ["session_id", "message_id", "hash", "seq"]
    )

    // MARK: - Complete 23-Table Inventory & Canonical DDL (schema.gen.ts)

    /// All 23 canonical SQLite tables created by `schema.gen.ts`.
    public static let allTableNames: [String] = [
        "account_state",
        "account",
        "control_account",
        "automation",
        "credential",
        "event_sequence",
        "event",
        "job",
        "kv",
        "permission",
        "project_directory",
        "project",
        "blob_ref",
        "blob",
        "instruction_blob",
        "instruction_entry",
        "instruction_state",
        "session_inbox",
        "session_message",
        "session_part",
        "session_v2",
        "workspace",
        "worktree",
    ]

    /// All 22 canonical indexes created by `schema.gen.ts`.
    public static let allIndexNames: [String] = [
        "automation_project_idx",
        "automation_session_idx",
        "automation_active_idx",
        "event_aggregate_seq_idx",
        "event_aggregate_type_seq_idx",
        "job_session_idx",
        "job_child_session_idx",
        "job_id_idx",
        "permission_project_action_resource_idx",
        "blob_ref_hash_idx",
        "blob_ref_session_seq_idx",
        "session_inbox_session_delivery_seq_idx",
        "session_inbox_session_enqueued_seq_idx",
        "session_message_session_seq_idx",
        "session_message_session_type_seq_idx",
        "session_message_session_time_created_id_idx",
        "session_message_time_created_idx",
        "session_part_session_message_idx",
        "session_v2_project_idx",
        "session_v2_workspace_idx",
        "session_v2_parent_idx",
        "session_v2_time_suspended_idx",
    ]

    /// Canonical DDL statements matching `packages/core/src/database/schema.gen.ts` verbatim.
    public static let bootstrapStatements: [String] = [
        """
        CREATE TABLE `account_state` (
          `id` integer PRIMARY KEY,
          `active_account_id` text,
          `active_org_id` text,
          CONSTRAINT `fk_account_state_active_account_id_account_id_fk` FOREIGN KEY (`active_account_id`) REFERENCES `account`(`id`) ON DELETE SET NULL
        );
        """,
        """
        CREATE TABLE `account` (
          `id` text PRIMARY KEY,
          `email` text NOT NULL,
          `url` text NOT NULL,
          `access_token` text NOT NULL,
          `refresh_token` text NOT NULL,
          `token_expiry` integer,
          `time_created` integer NOT NULL,
          `time_updated` integer NOT NULL
        );
        """,
        """
        CREATE TABLE `control_account` (
          `email` text NOT NULL,
          `url` text NOT NULL,
          `access_token` text NOT NULL,
          `refresh_token` text NOT NULL,
          `token_expiry` integer,
          `active` integer NOT NULL,
          `time_created` integer NOT NULL,
          `time_updated` integer NOT NULL,
          CONSTRAINT `control_account_pk` PRIMARY KEY(`email`, `url`)
        );
        """,
        """
        CREATE TABLE `automation` (
          `id` text PRIMARY KEY,
          `project_id` text NOT NULL,
          `session_id` text,
          `directory` text NOT NULL,
          `name` text NOT NULL,
          `trigger` text NOT NULL,
          `tz` text NOT NULL,
          `action` text NOT NULL,
          `status` text DEFAULT 'active' NOT NULL,
          `next_due_at` integer,
          `expires_at` integer,
          `run_count` integer DEFAULT 0 NOT NULL,
          `failures` integer DEFAULT 0 NOT NULL,
          `last_run_at` integer,
          `last_message_id` text,
          `last_outcome` text,
          `last_output` text,
          `retry_at` integer,
          `state` text,
          `event_position` text,
          `time_created` integer NOT NULL,
          `time_updated` integer NOT NULL
        );
        """,
        """
        CREATE TABLE `credential` (
          `id` text PRIMARY KEY,
          `integration_id` text,
          `label` text NOT NULL,
          `value` text NOT NULL,
          `connector_id` text,
          `method_id` text,
          `active` integer,
          `time_created` integer NOT NULL,
          `time_updated` integer NOT NULL
        );
        """,
        """
        CREATE TABLE `event_sequence` (
          `aggregate_id` text PRIMARY KEY,
          `seq` integer NOT NULL,
          `owner_id` text
        );
        """,
        """
        CREATE TABLE `event` (
          `id` text PRIMARY KEY,
          `aggregate_id` text NOT NULL,
          `seq` integer NOT NULL,
          `created` integer DEFAULT 0 NOT NULL,
          `type` text NOT NULL,
          `data` text NOT NULL,
          CONSTRAINT `fk_event_aggregate_id_event_sequence_aggregate_id_fk` FOREIGN KEY (`aggregate_id`) REFERENCES `event_sequence`(`aggregate_id`) ON DELETE CASCADE
        );
        """,
        """
        CREATE TABLE `job` (
          `notification_id` text PRIMARY KEY,
          `id` text NOT NULL,
          `session_id` text NOT NULL,
          `child_session_id` text,
          `kind` text NOT NULL,
          `title` text,
          `status` text NOT NULL,
          `output` text,
          `error` text,
          `recovery` text NOT NULL,
          `time_created` integer NOT NULL,
          `time_updated` integer NOT NULL
        );
        """,
        """
        CREATE TABLE `kv` (
          `key` text PRIMARY KEY,
          `value` text NOT NULL,
          `time_created` integer NOT NULL,
          `time_updated` integer NOT NULL
        );
        """,
        """
        CREATE TABLE `machine` (
          `id` text PRIMARY KEY,
          `key` text,
          `time_created` integer NOT NULL
        );
        """,
        """
        CREATE TABLE `permission` (
          `id` text PRIMARY KEY,
          `project_id` text NOT NULL,
          `action` text NOT NULL,
          `resource` text NOT NULL,
          `time_created` integer NOT NULL,
          `time_updated` integer NOT NULL,
          CONSTRAINT `fk_permission_project_id_project_id_fk` FOREIGN KEY (`project_id`) REFERENCES `project`(`id`) ON DELETE CASCADE
        );
        """,
        """
        CREATE TABLE `project_directory` (
          `project_id` text NOT NULL,
          `directory` text NOT NULL,
          `type` text,
          `strategy` text,
          `time_created` integer NOT NULL,
          CONSTRAINT `project_directory_pk` PRIMARY KEY(`project_id`, `directory`),
          CONSTRAINT `fk_project_directory_project_id_project_id_fk` FOREIGN KEY (`project_id`) REFERENCES `project`(`id`) ON DELETE CASCADE
        );
        """,
        """
        CREATE TABLE `project` (
          `id` text PRIMARY KEY,
          `worktree` text NOT NULL,
          `vcs` text,
          `name` text,
          `icon_url` text,
          `icon_url_override` text,
          `icon_color` text,
          `time_created` integer NOT NULL,
          `time_updated` integer NOT NULL,
          `time_initialized` integer,
          `time_active` integer DEFAULT 0 NOT NULL,
          `time_archived` integer,
          `sandboxes` text NOT NULL,
          `commands` text
        );
        """,
        """
        CREATE TABLE `blob_ref` (
          `session_id` text NOT NULL,
          `message_id` text NOT NULL,
          `hash` text NOT NULL,
          `seq` integer NOT NULL,
          CONSTRAINT `blob_ref_pk` PRIMARY KEY(`session_id`, `message_id`, `hash`),
          CONSTRAINT `fk_blob_ref_session_id_session_v2_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session_v2`(`id`) ON DELETE CASCADE,
          CONSTRAINT `fk_blob_ref_hash_blob_hash_fk` FOREIGN KEY (`hash`) REFERENCES `blob`(`hash`) ON DELETE CASCADE
        );
        """,
        """
        CREATE TABLE `blob` (
          `hash` text PRIMARY KEY,
          `mime` text NOT NULL,
          `bytes` integer NOT NULL,
          `width` integer,
          `height` integer,
          `data` blob NOT NULL,
          `time_created` integer NOT NULL
        );
        """,
        """
        CREATE TABLE `instruction_blob` (
          `hash` text PRIMARY KEY,
          `value` text
        );
        """,
        """
        CREATE TABLE `instruction_entry` (
          `session_id` text NOT NULL,
          `key` text NOT NULL,
          `value` text,
          `removed` integer DEFAULT 0 NOT NULL,
          `time_created` integer NOT NULL,
          `time_updated` integer NOT NULL,
          CONSTRAINT `instruction_entry_pk` PRIMARY KEY(`session_id`, `key`),
          CONSTRAINT `fk_instruction_entry_session_id_session_v2_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session_v2`(`id`) ON DELETE CASCADE
        );
        """,
        """
        CREATE TABLE `instruction_state` (
          `session_id` text PRIMARY KEY,
          `epoch_start` integer NOT NULL,
          `through_seq` integer NOT NULL,
          `initial_values` text NOT NULL,
          `current_values` text NOT NULL,
          CONSTRAINT `fk_instruction_state_session_id_session_v2_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session_v2`(`id`) ON DELETE CASCADE
        );
        """,
        """
        CREATE TABLE `session_inbox` (
          `id` text PRIMARY KEY,
          `session_id` text NOT NULL,
          `type` text NOT NULL,
          `payload` text NOT NULL,
          `delivery` text NOT NULL,
          `enqueued_seq` integer NOT NULL,
          `time_created` integer NOT NULL,
          CONSTRAINT `fk_session_inbox_session_id_session_v2_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session_v2`(`id`) ON DELETE CASCADE
        );
        """,
        """
        CREATE TABLE `session_message` (
          `id` text PRIMARY KEY,
          `session_id` text NOT NULL,
          `type` text NOT NULL,
          `seq` integer NOT NULL,
          `time_created` integer NOT NULL,
          `time_updated` integer NOT NULL,
          `data` text NOT NULL,
          CONSTRAINT `fk_session_message_session_id_session_v2_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session_v2`(`id`) ON DELETE CASCADE
        );
        """,
        """
        CREATE TABLE `session_part` (
          `message_id` text NOT NULL,
          `session_id` text NOT NULL,
          `ordinal` integer NOT NULL,
          `type` text NOT NULL,
          `call_id` text,
          `time_created` integer NOT NULL,
          `time_updated` integer NOT NULL,
          `data` text NOT NULL,
          CONSTRAINT `session_part_pk` PRIMARY KEY(`message_id`, `ordinal`),
          CONSTRAINT `fk_session_part_message_id_session_message_id_fk` FOREIGN KEY (`message_id`) REFERENCES `session_message`(`id`) ON DELETE CASCADE,
          CONSTRAINT `fk_session_part_session_id_session_v2_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session_v2`(`id`) ON DELETE CASCADE
        );
        """,
        """
        CREATE TABLE `session_v2` (
          `id` text PRIMARY KEY,
          `project_id` text NOT NULL,
          `workspace_id` text,
          `parent_id` text,
          `fork_session_id` text,
          `fork_boundary` text,
          `slug` text NOT NULL,
          `directory` text NOT NULL,
          `path` text,
          `title` text,
          `version` text NOT NULL,
          `share_url` text,
          `summary_additions` integer,
          `summary_deletions` integer,
          `summary_files` integer,
          `summary_diffs` text,
          `metadata` text,
          `cost` real DEFAULT 0 NOT NULL,
          `tokens_input` integer DEFAULT 0 NOT NULL,
          `tokens_output` integer DEFAULT 0 NOT NULL,
          `tokens_reasoning` integer DEFAULT 0 NOT NULL,
          `tokens_cache_read` integer DEFAULT 0 NOT NULL,
          `tokens_cache_write` integer DEFAULT 0 NOT NULL,
          `revert` text,
          `permission` text,
          `agent` text,
          `model` text,
          `time_created` integer NOT NULL,
          `time_updated` integer NOT NULL,
          `time_busy` integer,
          `time_idle` integer,
          `time_viewed` integer,
          `idle_outcome` text,
          `time_compacting` integer,
          `time_archived` integer,
          `time_suspended` integer,
          `resume_attempts` integer DEFAULT 0 NOT NULL,
          CONSTRAINT `fk_session_v2_project_id_project_id_fk` FOREIGN KEY (`project_id`) REFERENCES `project`(`id`) ON DELETE CASCADE
        );
        """,
        """
        CREATE TABLE `workspace` (
          `id` text PRIMARY KEY,
          `provider` text NOT NULL,
          `binding` text,
          `created_at` integer NOT NULL,
          `last_used_at` integer NOT NULL
        );
        """,
        """
        CREATE TABLE `worktree` (
          `project_id` text NOT NULL,
          `directory` text NOT NULL,
          `strategy` text,
          `time_created` integer NOT NULL,
          CONSTRAINT `worktree_pk` PRIMARY KEY(`project_id`, `directory`),
          CONSTRAINT `fk_worktree_project_id_project_id_fk` FOREIGN KEY (`project_id`) REFERENCES `project`(`id`) ON DELETE CASCADE
        );
        """,
        "CREATE INDEX `automation_project_idx` ON `automation` (`project_id`);",
        "CREATE INDEX `automation_session_idx` ON `automation` (`session_id`);",
        "CREATE INDEX `automation_active_idx` ON `automation` (`next_due_at`) WHERE \"automation\".\"status\" = 'active';",
        "CREATE UNIQUE INDEX `event_aggregate_seq_idx` ON `event` (`aggregate_id`,`seq`);",
        "CREATE INDEX `event_aggregate_type_seq_idx` ON `event` (`aggregate_id`,`type`,`seq`);",
        "CREATE INDEX `job_session_idx` ON `job` (`session_id`);",
        "CREATE INDEX `job_child_session_idx` ON `job` (`child_session_id`);",
        "CREATE INDEX `job_id_idx` ON `job` (`id`);",
        "CREATE UNIQUE INDEX `machine_key_idx` ON `machine` (`key`);",
        "CREATE UNIQUE INDEX `permission_project_action_resource_idx` ON `permission` (`project_id`,`action`,`resource`);",
        "CREATE INDEX `blob_ref_hash_idx` ON `blob_ref` (`hash`);",
        "CREATE INDEX `blob_ref_session_seq_idx` ON `blob_ref` (`session_id`,`seq`);",
        "CREATE INDEX `session_inbox_session_delivery_seq_idx` ON `session_inbox` (`session_id`,`delivery`,`enqueued_seq`);",
        "CREATE UNIQUE INDEX `session_inbox_session_enqueued_seq_idx` ON `session_inbox` (`session_id`,`enqueued_seq`);",
        "CREATE UNIQUE INDEX `session_message_session_seq_idx` ON `session_message` (`session_id`,`seq`);",
        "CREATE INDEX `session_message_session_type_seq_idx` ON `session_message` (`session_id`,`type`,`seq`);",
        "CREATE INDEX `session_message_session_time_created_id_idx` ON `session_message` (`session_id`,`time_created`,`id`);",
        "CREATE INDEX `session_message_time_created_idx` ON `session_message` (`time_created`);",
        "CREATE INDEX `session_part_session_message_idx` ON `session_part` (`session_id`,`message_id`,`ordinal`);",
        "CREATE INDEX `session_v2_project_idx` ON `session_v2` (`project_id`);",
        "CREATE INDEX `session_v2_workspace_idx` ON `session_v2` (`workspace_id`);",
        "CREATE INDEX `session_v2_parent_idx` ON `session_v2` (`parent_id`);",
        "CREATE INDEX `session_v2_time_suspended_idx` ON `session_v2` (`time_suspended`) WHERE \"session_v2\".\"time_suspended\" is not null;",
    ]

    /// Fresh-database schema bootstrap migration executing all canonical DDL statements (`core/src/database/schema.gen.ts#default`).
    // parity: core/src/database/schema.gen.ts#default [status=implemented hash=3b0df281f363]
    public static let schemaBootstrap = CoreDatabaseMigration.Migration(id: "schema.gen") { tx, _ in
        for statement in bootstrapStatements {
            _ = try tx.execute(statement)
        }
    }
}

// MARK: - database/storage-failure.ts

/// Human-readable storage failure classification for SQLite primary/extended result codes.
public enum CoreDatabaseStorageFailure {
    private static let failureMessages: [Int32: String] = [
        5: "Storage is in use by another process",   // SQLITE_BUSY
        6: "Storage is in use by another process",   // SQLITE_LOCKED
        8: "Storage is read-only",                   // SQLITE_READONLY
        10: "Storage couldn't be read or written",   // SQLITE_IOERR
        11: "Storage is damaged",                    // SQLITE_CORRUPT
        13: "Storage is full",                       // SQLITE_FULL
        14: "Storage couldn't be opened",            // SQLITE_CANTOPEN
        26: "Storage is damaged",                    // SQLITE_NOTADB
    ]

    /// Result codes after which SQLite may have automatically rolled back the active transaction:
    /// SQLITE_BUSY (5), SQLITE_NOMEM (7), SQLITE_INTERRUPT (9), SQLITE_IOERR (10), SQLITE_FULL (13).
    private static let autoRollbackCodes: Set<Int32> = [5, 7, 9, 10, 13]

    /// Extracts the SQLite result code from a `SQLiteError`, if present.
    public static func resultCode(from error: any Error) -> Int32? {
        guard let sqliteError = error as? SQLiteError else { return nil }
        switch sqliteError {
        case .openFailed(_, let code, _),
             .prepareFailed(_, let code, _),
             .bindFailed(_, let code, _),
             .stepFailed(_, let code, _),
             .executionFailed(_, let code, _),
             .constraintViolation(let code, _):
            return code
        case .databaseClosed, .invalidParameter, .migrationFailed, .unsupportedSQL:
            return nil
        }
    }

    /// Returns the user-facing storage failure message for an arbitrary error, if it is a storage failure.
    // parity: core/src/database/storage-failure.ts#message [status=implemented hash=4d3eaac4d435]
    public static func message(_ error: any Error) -> String? {
        if let sqliteError = error as? SQLiteError {
            return fromSqlError(sqliteError)
        }
        return nil
    }

    /// Returns the user-facing storage failure message for a `SQLiteError`, masking extended result codes to the low byte.
    // parity: core/src/database/storage-failure.ts#fromSqlError [status=implemented hash=d7f906db5edb]
    public static func fromSqlError(_ error: SQLiteError) -> String? {
        guard let code = resultCode(from: error) else { return nil }
        return failureMessages[code & 0xFF]
    }

    /// Returns whether SQLite may have automatically rolled back the active transaction after `error`.
    // parity: core/src/database/storage-failure.ts#rolledBack [status=implemented hash=55a8ad4cd040]
    public static func rolledBack(_ error: any Error) -> Bool {
        guard let code = resultCode(from: error) else { return false }
        return autoRollbackCodes.contains(code & 0xFF)
    }
}
