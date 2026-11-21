#if canImport(Foundation)
import Foundation
#elseif canImport(FoundationEssentials)
import FoundationEssentials
#endif
import Synchronization
import OpenCodeCore
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

/// Non-Testing fixtures for `EnvironmentFilesystemParityTests` (keeps Foundation out of the `import Testing` file).
enum EnvironmentFilesystemHelper {
    /// A machine registry over in-memory environments.
    struct StubMachines: Machines.Interface {
        let environments: [CoreLocation.Environment.ID: any CoreLocation.Environment.Interface]
        let homes: [CoreLocation.Environment.ID: String]

        func add(_ name: String) async throws -> String { name }
        @discardableResult
        func remove(_ id: String) async throws -> Bool { false }
        func list() async -> [Machines.Info] {
            environments.keys.sorted().map { Machines.Info(id: $0.rawValue, online: homes[$0] != nil, paired: true) }
        }

        func get(_ id: String) async throws -> any CoreLocation.Environment.Interface {
            guard let environment = environments[CoreLocation.Environment.ID.make(id)] else { throw Machines.NotFound(machine: id) }
            return environment
        }

        func home(_ id: String) async throws -> String {
            guard let home = homes[CoreLocation.Environment.ID.make(id)] else { throw Machines.NotFound(machine: id) }
            return home
        }

        func connect(_ id: String, _ connection: MachineDriver.Connection) async throws {}
        func invite(_ id: String, options: Machines.InviteOptions) async throws -> String { "" }
        func join(secret: [UInt8], key: [UInt8]) async throws -> String { throw Machines.InvalidJoin() }
        func identify(_ key: [UInt8]) async throws -> String { throw Machines.UnknownKey() }
    }

    /// Records every spec it runs and answers with a fixed output, or fails with `failure`.
    final class RecordingSpawner: ProcessSpawner, Sendable {
        private let specs = Mutex<[ProcessSpec]>([])
        let output: ProcessOutput
        let failure: String?

        init(output: ProcessOutput = ProcessOutput(exitCode: 0, stdout: Array("remote\n".utf8), stderr: []), failure: String? = nil) {
            self.output = output
            self.failure = failure
        }

        struct Failure: Swift.Error, CustomStringConvertible {
            let description: String
        }

        func run(_ spec: ProcessSpec) async throws -> ProcessOutput {
            specs.withLock { $0.append(spec) }
            if let failure { throw Failure(description: failure) }
            return output
        }

        var recorded: [ProcessSpec] { specs.withLock { $0 } }
    }

    static func memoryEnvironment(
        _ id: CoreLocation.Environment.ID,
        files: [String: String] = [:],
        spawner: any ProcessSpawner = CoreLocation.Environment.unavailableSpawner
    ) async throws -> any CoreLocation.Environment.Interface {
        let driver = CoreLocation.Environment.makeMemoryDriver()
        for (path, text) in files {
            if let slash = path.lastIndex(of: "/"), slash != path.startIndex {
                try await driver.mkdir(String(path[..<slash]))
            }
            try await driver.write(path, bytes: Array(text.utf8))
        }
        return CoreLocation.Environment.Service(id: id, files: driver, spawner: spawner)
    }

    static func encodeID(_ id: CoreLocation.Environment.ID) throws -> String {
        String(decoding: try JSONEncoder().encode(id), as: UTF8.self)
    }

    static func decodeID(_ json: String) throws -> CoreLocation.Environment.ID {
        try JSONDecoder().decode(CoreLocation.Environment.ID.self, from: Data(json.utf8))
    }

    static func roundTripTarget(_ target: CoreFilesystem.FileAccess.Target) throws -> (json: String, decoded: CoreFilesystem.FileAccess.Target) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(target)
        return (String(decoding: data, as: UTF8.self), try JSONDecoder().decode(CoreFilesystem.FileAccess.Target.self, from: data))
    }

    // MARK: Session search fixtures

    static func openDatabase() async throws -> any SQLiteDatabase {
        let service = try await CoreDatabaseStore.open()
        _ = try service.db.execute("PRAGMA foreign_keys = OFF", parameters: [])
        return service.db
    }

    static func insertSession(_ db: any SQLiteDatabase, id: String, title: String?) throws {
        _ = try db.execute(
            """
            INSERT INTO session_v2 (id, project_id, slug, directory, title, version, time_created, time_updated)
            VALUES (?, 'prj_test', ?, '/repo', ?, '1', 1, 1)
            """,
            parameters: [.text(id), .text(id), title.map { .text($0) } ?? .null]
        )
    }

    static func hasColumn(_ db: any SQLiteDatabase, table: String, column: String) throws -> Bool {
        try db.query("PRAGMA table_info(\(table))", parameters: []).contains { $0.string("name") == column }
    }

    static func insertMessage(_ db: any SQLiteDatabase, id: String, session: String, type: String, data: [String: Any]) throws {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]), as: UTF8.self)
        if try hasColumn(db, table: "session_message", column: "seq") {
            _ = try db.execute(
                """
                INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data)
                VALUES (?, ?, ?, (SELECT coalesce(max(seq), 0) + 1 FROM session_message WHERE session_id = ?), 1, 1, ?)
                """,
                parameters: [.text(id), .text(session), .text(type), .text(session), .text(json)]
            )
        } else {
            _ = try db.execute(
                "INSERT INTO session_message (id, session_id, type, time_created, time_updated, data) VALUES (?, ?, ?, 1, 1, ?)",
                parameters: [.text(id), .text(session), .text(type), .text(json)]
            )
        }
    }

    static func updateMessage(_ db: any SQLiteDatabase, id: String, data: [String: Any]) throws {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]), as: UTF8.self)
        _ = try db.execute("UPDATE session_message SET data = ? WHERE id = ?", parameters: [.text(json), .text(id)])
    }

    /// Source ids of indexed rows matching an FTS5 query.
    static func search(_ db: any SQLiteDatabase, _ query: String) throws -> [String] {
        try db.query(
            """
            SELECT document.source_id AS source FROM session_search
            JOIN session_search_document AS document ON document.id = session_search.rowid
            WHERE session_search MATCH ? ORDER BY document.source_id
            """,
            parameters: [.text(query)]
        ).compactMap { $0.string("source") }
    }

    static func writeRawState(_ db: any SQLiteDatabase, json: String) throws {
        _ = try db.execute(
            "INSERT INTO kv (key, value, time_created, time_updated) VALUES ('session.search', ?, 1, 1) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
            parameters: [.text(json)]
        )
    }
}
