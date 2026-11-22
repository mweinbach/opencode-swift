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

/// Non-Testing helpers for `Sync3FsShellEnvTests` (keeps Foundation out of the `import Testing` file per macOS CLT rules).
enum Sync3FsShellEnvHelper {
    private final class KeyBox: @unchecked Sendable {
        var keys: [String] = []
    }

    private struct KeyCapturingEncoder: Encoder {
        let box: KeyBox
        var codingPath: [any CodingKey] = []
        var userInfo: [CodingUserInfoKey: Any] = [:]

        func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
            KeyedEncodingContainer(Container<Key>(box: box, codingPath: codingPath, isRoot: codingPath.isEmpty))
        }

        func unkeyedContainer() -> any UnkeyedEncodingContainer {
            NoopUnkeyedContainer(codingPath: codingPath)
        }

        func singleValueContainer() -> any SingleValueEncodingContainer {
            NoopSingleValueContainer(codingPath: codingPath)
        }

        struct Container<Key: CodingKey>: KeyedEncodingContainerProtocol {
            let box: KeyBox
            var codingPath: [any CodingKey]
            let isRoot: Bool

            mutating func record(_ key: Key) {
                if isRoot { box.keys.append(key.stringValue) }
            }

            mutating func encodeNil(forKey key: Key) throws { record(key) }
            mutating func encode(_ value: Bool, forKey key: Key) throws { record(key) }
            mutating func encode(_ value: String, forKey key: Key) throws { record(key) }
            mutating func encode(_ value: Double, forKey key: Key) throws { record(key) }
            mutating func encode(_ value: Float, forKey key: Key) throws { record(key) }
            mutating func encode(_ value: Int, forKey key: Key) throws { record(key) }
            mutating func encode(_ value: Int8, forKey key: Key) throws { record(key) }
            mutating func encode(_ value: Int16, forKey key: Key) throws { record(key) }
            mutating func encode(_ value: Int32, forKey key: Key) throws { record(key) }
            mutating func encode(_ value: Int64, forKey key: Key) throws { record(key) }
            mutating func encode(_ value: UInt, forKey key: Key) throws { record(key) }
            mutating func encode(_ value: UInt8, forKey key: Key) throws { record(key) }
            mutating func encode(_ value: UInt16, forKey key: Key) throws { record(key) }
            mutating func encode(_ value: UInt32, forKey key: Key) throws { record(key) }
            mutating func encode(_ value: UInt64, forKey key: Key) throws { record(key) }
            mutating func encode<V: Encodable>(_ value: V, forKey key: Key) throws { record(key) }
            mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
                record(key)
                return KeyedEncodingContainer(Container<NestedKey>(box: box, codingPath: codingPath + [key], isRoot: false))
            }
            mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
                record(key)
                return NoopUnkeyedContainer(codingPath: codingPath + [key])
            }
            mutating func superEncoder() -> any Encoder {
                KeyCapturingEncoder(box: box, codingPath: codingPath)
            }
            mutating func superEncoder(forKey key: Key) -> any Encoder {
                record(key)
                return KeyCapturingEncoder(box: box, codingPath: codingPath + [key])
            }
        }

        struct NoopUnkeyedContainer: UnkeyedEncodingContainer {
            var codingPath: [any CodingKey]
            var count: Int = 0
            mutating func encodeNil() throws { count += 1 }
            mutating func encode<V: Encodable>(_ value: V) throws { count += 1 }
            mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
                KeyedEncodingContainer(Container<NestedKey>(box: KeyBox(), codingPath: codingPath, isRoot: false))
            }
            mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer { self }
            mutating func superEncoder() -> any Encoder { KeyCapturingEncoder(box: KeyBox(), codingPath: codingPath) }
        }

        struct NoopSingleValueContainer: SingleValueEncodingContainer {
            var codingPath: [any CodingKey]
            mutating func encodeNil() throws {}
            mutating func encode<V: Encodable>(_ value: V) throws {}
        }
    }

    /// Captures the exact top-level key emission order of a `Codable` value's `encode(to:)`, independent of
    /// `Foundation.JSONEncoder`'s internal dictionary hash randomization.
    static func encodedTopLevelKeys<T: Encodable>(_ value: T) throws -> [String] {
        let box = KeyBox()
        try value.encode(to: KeyCapturingEncoder(box: box))
        return box.keys
    }

    static func encodeJSONPreservingOrder<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeJSON<T: Decodable>(_ json: String, as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    static func makeLocation(
        directory: String,
        workspaceID: WorkspaceID? = nil,
        projectID: ProjectID = .global
    ) -> CoreLocation.Location.Service {
        let abs = SchemaPrimitive.AbsolutePath(rawValue: directory)
        return CoreLocation.Location.Service(
            info: LocationSchema.Info(
                directory: abs,
                workspaceID: workspaceID,
                project: LocationSchema.ProjectRef(id: projectID, directory: abs, canonical: abs)
            )
        )
    }

    /// Recording `CorePermission.Interface` that logs every `assert` call and optionally blocks one action.
    final class RecordingPermission: CorePermission.Interface, Sendable {
        private let assertions = Mutex<[CorePermission.AssertInput]>([])
        private let denyAction: String?

        init(denyAction: String? = nil) {
            self.denyAction = denyAction
        }

        var recorded: [CorePermission.AssertInput] {
            assertions.withLock { $0 }
        }

        func close() async {}

        func ask(_ input: CorePermission.AssertInput) async throws -> CorePermission.AskResult {
            assertions.withLock { $0.append(input) }
            return CorePermission.AskResult(id: CorePermission.ID.create(), effect: .allow)
        }

        func assert(_ input: CorePermission.AssertInput) async throws {
            assertions.withLock { $0.append(input) }
            if let denyAction, input.action == denyAction {
                throw CorePermission.BlockedError(rules: [], permission: input.action, resources: input.resources)
            }
        }

        func assertNotDenied(_ input: CorePermission.AssertInput) async throws {}
        func allows(_ input: CorePermission.AssertInput) async throws -> Bool { true }
        func reply(_ input: CorePermission.ReplyInput) async throws {}
        func get(_ id: CorePermission.ID) async -> CorePermission.Request? { nil }
        func forSession(_ sessionID: SessionID) async -> [CorePermission.Request] { [] }
        func list() async -> [CorePermission.Request] { [] }
        func nested(call: ToolSchema.CallID, parent: ToolSchema.CallID) -> CorePermission.NestedLease {
            CorePermission.NestedLease {}
        }
    }

    /// Wraps a `FileAccess.Interface` and places resolved targets into a specified `environment` (mirroring upstream
    /// `test/fixture/target-environment.ts`'s `elsewhere`).
    struct ElsewhereFileAccess: CoreFilesystem.FileAccess.Interface, Sendable {
        let inner: any CoreFilesystem.FileAccess.Interface
        let environment: any CoreLocation.Environment.Interface

        private func placed(_ target: CoreFilesystem.FileAccess.Target) -> CoreFilesystem.FileAccess.Target {
            CoreFilesystem.FileAccess.Target(
                absolute: target.absolute,
                resource: target.resource,
                externalDirectory: target.externalDirectory,
                environment: environment,
                machine: environment.id == CoreLocation.Environment.localID ? nil : environment.id
            )
        }

        func locate(_ path: String, base: CoreLocation.Environment.Place?) async throws -> CoreLocation.Environment.Place {
            try await inner.locate(path, base: base)
        }

        func resolve(_ input: CoreFilesystem.FileAccess.ResolveInput) async throws -> CoreFilesystem.FileAccess.Target {
            placed(try await inner.resolve(input))
        }

        func authorizeExternal(
            _ targets: [CoreFilesystem.FileAccess.Target],
            context: CoreFilesystem.FileAccess.Invocation,
            metadata: [String: JSONValue]?
        ) async throws {
            try await inner.authorizeExternal(targets, context: context, metadata: metadata)
        }

        func authorizeRead(
            _ file: String,
            context: CoreFilesystem.FileAccess.Invocation,
            options: CoreFilesystem.FileAccess.ReadOptions?
        ) async throws -> CoreFilesystem.FileAccess.Target {
            placed(try await inner.authorizeRead(file, context: context, options: options))
        }
    }

    /// Minimal `CoreShell.CommandProcess` stub for testing `CoreShell.Daemon` + `CommandHost` lifecycle.
    final class StubCommandProcess: CoreShell.CommandProcess, Sendable {
        struct State: Sendable {
            var stored: [ProcessDaemon.PipeMetadata] = []
            var signals: [CorePty.PersistentDaemon.Signal] = []
            var removed = false
            var waitContinuation: CheckedContinuation<CoreShell.CommandExit, any Error>?
            var pendingExit: Result<CoreShell.CommandExit, any Error>?
        }

        let info: CoreShell.CommandInfo
        private let state = Mutex(State())

        init(info: CoreShell.CommandInfo, immediateExit: Result<CoreShell.CommandExit, any Error>? = nil) {
            self.info = info
            if let immediateExit {
                self.state.withLock { $0.pendingExit = immediateExit }
            }
        }

        var storedMetadata: [ProcessDaemon.PipeMetadata] { state.withLock { $0.stored } }
        var sentSignals: [CorePty.PersistentDaemon.Signal] { state.withLock { $0.signals } }
        var wasRemoved: Bool { state.withLock { $0.removed } }

        func finish(_ result: Result<CoreShell.CommandExit, any Error>) {
            let cont = state.withLock { s -> CheckedContinuation<CoreShell.CommandExit, any Error>? in
                s.pendingExit = result
                defer { s.waitContinuation = nil }
                return s.waitContinuation
            }
            cont?.resume(with: result)
        }

        func store(_ metadata: ProcessDaemon.PipeMetadata) async throws {
            state.withLock { $0.stored.append(metadata) }
        }

        func wait() async throws -> CoreShell.CommandExit {
            try await withCheckedThrowingContinuation { cont in
                let ready: Result<CoreShell.CommandExit, any Error>? = state.withLock { s in
                    if let pending = s.pendingExit { return pending }
                    s.waitContinuation = cont
                    return nil
                }
                if let ready { cont.resume(with: ready) }
            }
        }

        func signal(_ signal: CorePty.PersistentDaemon.Signal) async throws {
            state.withLock { $0.signals.append(signal) }
        }

        func remove() async throws {
            state.withLock { $0.removed = true }
        }
    }

    /// In-memory `CoreShell.CommandHost` for testing `CoreShell.Daemon.at(_:)`.
    final class StubCommandHost: CoreShell.CommandHost, Sendable {
        let lost: String
        private let state: Mutex<(existing: [StubCommandProcess], created: [(CoreShell.CommandCreate, StubCommandProcess)])>

        init(lost: String = "host daemon lost", existing: [StubCommandProcess] = []) {
            self.lost = lost
            self.state = Mutex((existing, []))
        }

        var createdProcesses: [(CoreShell.CommandCreate, StubCommandProcess)] {
            state.withLock { $0.created }
        }

        func create(_ input: CoreShell.CommandCreate) async throws -> any CoreShell.CommandProcess {
            let proc = StubCommandProcess(
                info: CoreShell.CommandInfo(
                    pid: 4242,
                    cwd: input.cwd,
                    lifecycle: .running,
                    outputPath: input.outputPath,
                    outputLines: 0,
                    outputError: nil,
                    metadata: input.metadata,
                    startedAt: 1_700_000_000_000,
                    exitedAt: nil
                )
            )
            state.withLock { $0.created.append((input, proc)) }
            return proc
        }

        func list() async throws -> [any CoreShell.CommandProcess] {
            state.withLock { $0.existing }
        }
    }

    struct HostLostError: Error {}

    static func openSessionService(
        directory: String,
        permissions: SessionSchema.PermissionRuleset? = nil
    ) async throws -> (session: CoreSession.Service, sessionID: SessionID) {
        let dbService = try await CoreDatabaseStore.open()
        let bus = CoreBus.Service(db: dbService.db)
        CoreSessionProjector.register(bus: bus, db: dbService.db)
        let store = CoreSessionStore.Service(db: dbService.db)
        let inbox = CoreSessionInbox.Service(db: dbService.db, bus: bus)
        let session = CoreSession.Service(db: dbService.db, bus: bus, store: store, inbox: inbox)
        let info = try await session.create(CoreSession.CreateInput(
            location: OpenCodeLocation(directory: directory),
            permissions: permissions
        ))
        return (session, info.id)
    }

    static func makeToolContext(sessionID: SessionID, agent: String = "build") -> ToolSchema.Context {
        ToolSchema.Context(
            sessionID: sessionID,
            agent: AgentSchema.ID(rawValue: agent),
            messageID: "msg_sync3",
            id: ToolSchema.CallID(rawValue: "call_sync3"),
            progress: { _ in }
        )
    }
}
