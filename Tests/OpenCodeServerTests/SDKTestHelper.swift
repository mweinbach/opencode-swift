#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodeClient
import OpenCodeCore
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeSDK
import OpenCodeUtil

/// Helper utilities for `OpenCodeSDKTests`. Kept separate from `import Testing` to satisfy
/// the macOS Command Line Tools Swift Testing cross-import rule.
enum SDKTestHelper {
    /// Thread-safe append-only recorder for test assertions across concurrent tasks.
    final class Recorder<Value: Sendable>: Sendable {
        private let items = Mutex<[Value]>([])

        init() {}

        func append(_ value: Value) {
            items.withLock { $0.append(value) }
        }

        @discardableResult
        func appendAndCount(_ value: Value) -> Int {
            items.withLock { list in
                list.append(value)
                return list.count
            }
        }

        func snapshot() -> [Value] {
            items.withLock { $0 }
        }

        var count: Int {
            items.withLock { $0.count }
        }
    }

    /// Reusable one-shot async gate/signal for deterministic concurrency coordination in tests.
    final class AsyncGate<Value: Sendable>: Sendable {
        private struct State: Sendable {
            var value: Value? = nil
            var waiters: [CheckedContinuation<Value, Never>] = []
        }

        private let state = Mutex(State())

        init() {}

        func resolve(_ value: Value) {
            let waiters: [CheckedContinuation<Value, Never>] = state.withLock { s in
                if s.value != nil { return [] }
                s.value = value
                let list = s.waiters
                s.waiters.removeAll()
                return list
            }
            for waiter in waiters {
                waiter.resume(returning: value)
            }
        }

        func wait() async -> Value {
            if let existing = state.withLock({ $0.value }) {
                return existing
            }
            return await withCheckedContinuation { continuation in
                let resolved: Value? = state.withLock { s in
                    if let existing = s.value {
                        return existing
                    }
                    s.waiters.append(continuation)
                    return nil
                }
                if let resolved {
                    continuation.resume(returning: resolved)
                }
            }
        }
    }

    /// Creates a unique temporary directory path for SQLite / config persistence tests.
    static func makeTempDirectory(prefix: String) throws -> String {
        let base = FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("\(prefix)-\(OpenCodeUtil.uuid())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #if os(Windows)
        return dir.path.replacing("/", with: "\\")
        #else
        return dir.path
        #endif
    }

    static func makeSubdirectory(_ parent: String, name: String) throws -> String {
        let url = URL(fileURLWithPath: parent, isDirectory: true).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #if os(Windows)
        return url.path.replacing("/", with: "\\")
        #else
        return url.path
        #endif
    }

    static func removeDirectory(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    static func joinPath(_ dir: String, _ name: String) -> String {
        URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent(name).path
    }

    /// Real SQLite-backed `DurableObjectStorage` implementation matching Cloudflare Workers'
    /// `state.storage.sql` + `transactionSync` contract for Workerd SDK tests.
    final class InMemoryDurableObjectStorage: CoreDatabaseWorkerdSQLite.DurableObjectStorage, Sendable {
        private final class SqlBackend: CoreDatabaseWorkerdSQLite.SqlStorage, Sendable {
            let db: any SQLiteDatabase

            init(db: any SQLiteDatabase) {
                self.db = db
            }

            func exec(_ query: String, bindings: [SQLiteValue]) throws -> [SQLiteRow] {
                if bindings.isEmpty {
                    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                    if trimmed.contains(";") && !trimmed.hasPrefix("SELECT") {
                        try db.executeScript(query)
                        return []
                    }
                }
                return try db.query(query, parameters: bindings)
            }
        }

        private let backend: SqlBackend

        init() throws {
            let db = try SQLiteDatabaseFactory.open(path: ":memory:")
            self.backend = SqlBackend(db: db)
        }

        var sql: any CoreDatabaseWorkerdSQLite.SqlStorage {
            backend
        }

        func transactionSync<T>(_ closure: () throws -> T) throws -> T {
            try backend.db.transaction(closure)
        }

        func close() {
            try? backend.db.close()
        }
    }

    /// Fake workspace driver tracking `create`, `connect`, `suspendForIdle`, and `destroy` calls.
    final class RecordingWorkspaceDriver: CoreProject.Workspace.Driver.Interface, Sendable {
        struct Call: Equatable, Sendable {
            let operation: String
            let workspaceID: String
        }

        let calls = Recorder<Call>()

        init() {}

        func create(workspaceID: WorkspaceID) async throws -> CoreProject.Workspace.Driver.Binding {
            calls.append(Call(operation: "create", workspaceID: workspaceID.rawValue))
            return ["externalID": .string(workspaceID.rawValue)]
        }

        func connect(
            workspaceID: WorkspaceID,
            binding: CoreProject.Workspace.Driver.Binding,
            saveBinding: @escaping @Sendable (CoreProject.Workspace.Driver.Binding) async throws -> Void
        ) async throws -> CoreLocation.Environment.Driver {
            _ = (binding, saveBinding)
            calls.append(Call(operation: "connect", workspaceID: workspaceID.rawValue))
            return CoreLocation.Environment.Driver(
                spawner: CoreLocation.Environment.unavailableSpawner,
                overrides: CoreLocation.Environment.makeMemoryDriver()
            )
        }

        func suspendForIdle(
            workspaceID: WorkspaceID,
            binding: CoreProject.Workspace.Driver.Binding,
            saveBinding: @escaping @Sendable (CoreProject.Workspace.Driver.Binding) async throws -> Void
        ) async throws {
            _ = (binding, saveBinding)
            calls.append(Call(operation: "suspendForIdle", workspaceID: workspaceID.rawValue))
        }

        func destroy(workspaceID: WorkspaceID, binding: CoreProject.Workspace.Driver.Binding?) async throws {
            _ = binding
            calls.append(Call(operation: "destroy", workspaceID: workspaceID.rawValue))
        }
    }

    /// Simple test error for simulating failures in loggers, handlers, and instance configuration.
    struct TestFailure: Error, Equatable, Sendable, CustomStringConvertible {
        let message: String
        init(_ message: String) { self.message = message }
        var description: String { message }
    }

    /// Wait until a condition becomes true (polling briefly) within `maxAttempts`.
    static func waitUntil(
        maxAttempts: Int = 100,
        intervalNs: UInt64 = 10_000_000,
        _ predicate: @Sendable () async -> Bool
    ) async -> Bool {
        for _ in 0..<maxAttempts {
            if await predicate() {
                return true
            }
            try? await Task.sleep(nanoseconds: intervalNs)
        }
        return await predicate()
    }
}
