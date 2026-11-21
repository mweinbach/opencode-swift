#if canImport(Foundation)
import Foundation
#elseif canImport(FoundationEssentials)
import FoundationEssentials
#endif
import Synchronization
import OpenCodeAI
import OpenCodeCore
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

/// Foundation-backed helpers for `CoreSync2Tests` (kept separate from `import Testing` per macOS CLT rule).
enum CoreSync2Helpers {
    static func makeTempDirectory(prefix: String = "opencode-sync2") throws -> String {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.path
    }

    static func removeItem(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    static func writeText(_ text: String, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    static func encodeToJSONString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    static func parseURL(_ raw: String) -> URL? {
        URL(string: raw)
    }

    static func makeGlobalPaths(root: String) -> Global.Interface {
        Global.Interface(
            home: "\(root)/home",
            data: "\(root)/data",
            bin: "\(root)/bin",
            log: "\(root)/log",
            cache: "\(root)/cache",
            config: "\(root)/global",
            state: "\(root)/state"
        )
    }

    static func openSearchDB() async throws -> any SQLiteDatabase {
        let store = try await CoreDatabaseStore.open(
            options: CoreDatabaseStore.Options(path: ":memory:"),
            legacyCredentials: false
        )
        _ = try store.db.execute("PRAGMA foreign_keys = OFF", parameters: [])
        return store.db
    }

    static func seedSession(
        db: any SQLiteDatabase,
        id: SessionID,
        projectID: ProjectID,
        directory: String,
        title: String,
        parentID: SessionID? = nil,
        created: Int64 = 1_700_000_000_000,
        updated: Int64 = 1_700_000_000_000
    ) throws {
        _ = try db.execute(
            """
            INSERT INTO `session_v2` (`id`, `project_id`, `parent_id`, `slug`, `directory`, `title`, `version`, `time_created`, `time_updated`)
            VALUES (?, ?, ?, ?, ?, ?, '1', ?, ?)
            """,
            parameters: [
                .text(id.rawValue),
                .text(projectID.rawValue),
                parentID.map { .text($0.rawValue) } ?? .null,
                .text("slug-\(id.rawValue)"),
                .text(directory),
                .text(title),
                .integer(created),
                .integer(updated),
            ]
        )
    }

    static func seedMessage(
        db: any SQLiteDatabase,
        sessionID: SessionID,
        seq: Int64,
        message: SessionMessageSchema.Info,
        created: Int64
    ) throws {
        guard case .object(var dict) = try CoreBusJSON.encodeToJSONValue(message) else { return }
        dict.removeValue(forKey: "id")
        dict.removeValue(forKey: "type")

        var parts: [SessionMessageSchema.AssistantContent] = []
        if case .assistant(let a) = message, !a.content.isEmpty {
            parts = a.content
            dict["content"] = .array([])
        }

        let jsonStr = try CoreBusJSON.encodeJSONValue(.object(dict))
        _ = try db.execute(
            """
            INSERT INTO `session_message` (`id`, `session_id`, `type`, `seq`, `time_created`, `time_updated`, `data`)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            parameters: [
                .text(message.id.rawValue),
                .text(sessionID.rawValue),
                .text(message.messageType.rawValue),
                .integer(seq),
                .integer(created),
                .integer(created),
                .text(jsonStr),
            ]
        )
        for (ordinal, part) in parts.enumerated() {
            let pDict = try CoreSessionHistory.encodePart(part)
            let pJSON = try CoreBusJSON.encodeJSONValue(.object(pDict))
            let callID: SQLiteValue = if case .tool(let t) = part { .text(t.id) } else { .null }
            _ = try db.execute(
                """
                INSERT INTO `session_part` (`message_id`, `session_id`, `ordinal`, `type`, `call_id`, `time_created`, `time_updated`, `data`)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                parameters: [
                    .text(message.id.rawValue),
                    .text(sessionID.rawValue),
                    .integer(Int64(ordinal)),
                    .text(part.typeTag),
                    callID,
                    .integer(created),
                    .integer(created),
                    .text(pJSON),
                ]
            )
        }
    }

    static func buildSearchIndex(db: any SQLiteDatabase) throws {
        _ = try SessionSearchIndex.ensure(db)
        var guardCount = 0
        while guardCount < 100 {
            let res = try SessionSearchIndex.buildChunk(db)
            if res.done { break }
            guardCount += 1
        }
    }

    static func makeJSONResponse(status: Int = 200, headers: [String: String] = [:], body: JSONValue) throws -> HTTPResponse {
        let data = try JSONEncoder().encode(body)
        var merged = headers
        merged["content-type"] = merged["content-type"] ?? "application/json"
        return HTTPResponse(
            head: HTTPResponseHead(statusCode: status, headers: merged),
            body: Array(data)
        )
    }

    static func makeTextResponse(status: Int, headers: [String: String] = [:], body: String = "") -> HTTPResponse {
        HTTPResponse(
            head: HTTPResponseHead(statusCode: status, headers: headers),
            body: Array(body.utf8)
        )
    }

    static func decodeRPCRequest(from body: [UInt8]?) throws -> CoreMCP.JSONRPCMessage {
        try JSONDecoder().decode(CoreMCP.JSONRPCMessage.self, from: Data(body ?? []))
    }
}

final class Sync2MockHTTPTransport: HTTPTransport, Sendable {
    private let handler: @Sendable (HTTPRequest) async throws -> HTTPResponse
    private let recorded = Mutex<[HTTPRequest]>([])

    init(handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse) {
        self.handler = handler
    }

    var requests: [HTTPRequest] { recorded.withLock { $0 } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        recorded.withLock { $0.append(request) }
        return try await handler(request)
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
        let response = try await send(request)
        let bytes = response.body
        let stream = AsyncThrowingStream<[UInt8], Swift.Error> { continuation in
            if !bytes.isEmpty { continuation.yield(bytes) }
            continuation.finish()
        }
        return HTTPStreamingResponse(head: response.head, chunks: stream)
    }
}

final class Sync2RecordingPermission: CorePermission.Interface, Sendable {
    private let recordedBox = Mutex<[CorePermission.AssertInput]>([])
    let shouldDecline: Bool

    init(shouldDecline: Bool = false) {
        self.shouldDecline = shouldDecline
    }

    var recorded: [CorePermission.AssertInput] {
        recordedBox.withLock { $0 }
    }

    func close() async {}

    func ask(_ input: CorePermission.AssertInput) async throws -> CorePermission.AskResult {
        recordedBox.withLock { $0.append(input) }
        if shouldDecline {
            throw CorePermission.DeclinedError(id: PermissionSchema.ID.create(), message: "denied by test")
        }
        return .once
    }

    func assert(_ input: CorePermission.AssertInput) async throws {
        recordedBox.withLock { $0.append(input) }
        if shouldDecline {
            throw CorePermission.DeclinedError(id: PermissionSchema.ID.create(), message: "denied by test")
        }
    }

    func assertNotDenied(_ input: CorePermission.AssertInput) async throws {
        recordedBox.withLock { $0.append(input) }
        if shouldDecline {
            throw CorePermission.DeclinedError(id: PermissionSchema.ID.create(), message: "denied by test")
        }
    }

    func allows(_ input: CorePermission.AssertInput) async throws -> Bool {
        _ = input
        return !shouldDecline
    }

    func reply(_ input: CorePermission.ReplyInput) async throws { _ = input }
    func get(_ id: CorePermission.ID) async -> CorePermission.Request? { _ = id; return nil }
    func forSession(_ sessionID: SessionID) async -> [CorePermission.Request] { _ = sessionID; return [] }
    func list() async -> [CorePermission.Request] { [] }
    func nested(call: ToolSchema.CallID, parent: ToolSchema.CallID) -> CorePermission.NestedLease {
        _ = (call, parent)
        return CorePermission.NestedLease(release: {})
    }
}

final class Sync2StubMachines: Machines.Interface, Sendable {
    let items: [Machines.Info]

    init(items: [Machines.Info]) {
        self.items = items
    }

    func add(_ name: String) async throws -> String { name }
    func remove(_ id: String) async throws { _ = id }
    func list() async -> [Machines.Info] { items }
    func get(_ id: String) async throws -> any CoreLocation.Environment.Interface {
        throw Machines.NotFound(machine: id)
    }
    func home(_ id: String) async throws -> String {
        throw Machines.NotFound(machine: id)
    }
    func connect(_ connection: MachineDriver.Connection) async throws { _ = connection }
    func invite(_ id: String, options: Machines.InviteOptions) async throws -> String {
        _ = (id, options)
        return "join"
    }
    func join(secret: [UInt8], key: [UInt8]) async throws -> String {
        _ = (secret, key)
        return "gpu"
    }
    func identify(_ key: [UInt8]) async throws -> String {
        _ = key
        throw Machines.UnknownKey()
    }
}
