#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodeAI
import OpenCodeCore
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

/// Foundation-backed fixtures for `RealToolsAndPtyTests.swift` (kept separate from `import Testing`
/// per the macOS Command Line Tools cross-import overlay rule).
enum RealToolsAndPtyHelper {
    static func makeTempDirectory(prefix: String = "opencode-real-tools") throws -> String {
        #if os(WASI)
        return "/tmp/\(prefix)-\(uuid())"
        #else
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(uuid())", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.path
        #endif
    }

    static func removeTempDirectory(_ path: String) {
        #if !os(WASI)
        try? FileManager.default.removeItem(atPath: path)
        #endif
    }

    static func realPath(_ path: String) -> String {
        #if os(WASI)
        return path
        #else
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        #endif
    }

    static func makeGlobalPaths(root: String) -> Global.Interface {
        Global.Interface(
            home: "\(root)/home",
            data: "\(root)/data",
            cache: "\(root)/cache",
            config: "\(root)/config",
            state: "\(root)/state",
            tmp: "\(root)/tmp",
            bin: "\(root)/cache/bin",
            log: "\(root)/data/log",
            repos: "\(root)/data/repos"
        )
    }

    static func samplePNGBytes() -> [UInt8] {
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D]
    }

    static func samplePNGBase64() -> String {
        Data(samplePNGBytes()).base64EncodedString()
    }

    static func isURLSessionTransport(_ transport: (any HTTPTransport)?) -> Bool {
        transport is URLSessionHTTPTransport
    }

    static func isNativeBackend(_ backend: ProcessDaemon.BackendMode) -> Bool {
        if case .native = backend { return true }
        return false
    }

    /// Builds a deterministic HTTPTransport that speaks real MCP JSON-RPC 2.0 Streamable HTTP
    /// (`initialize`, `notifications/initialized`, `tools/list`, `prompts/list`,
    /// `resources/list`, `resources/templates/list`, `resources/read`).
    static func makeStreamableMCPServerTransport(
        serverTitle: String = "Docs MCP",
        resources: [CoreMCP.Client.Resource],
        templates: [CoreMCP.Client.ResourceTemplate],
        readHandler: @escaping @Sendable (String) -> [JSONValue]
    ) -> MockHTTPTransport {
        MockHTTPTransport(fallbackHandler: { request in
            guard let body = request.body, !body.isEmpty else {
                return HTTPResponse(head: HTTPResponseHead(statusCode: 202, headers: [:]), body: [])
            }
            let message = try JSONDecoder().decode(CoreMCP.JSONRPCMessage.self, from: Data(body))
            switch message {
            case .notification:
                return HTTPResponse(head: HTTPResponseHead(statusCode: 202, headers: [:]), body: [])
            case .request(let rpc):
                let result: JSONValue
                switch rpc.method {
                case "initialize":
                    result = .object([
                        "protocolVersion": .string(CoreMCP.Client.latestProtocolVersion),
                        "capabilities": .object(["resources": .object([:])]),
                        "serverInfo": .object(["name": .string("docs"), "title": .string(serverTitle)]),
                    ])
                case "tools/list":
                    result = .object(["tools": .array([])])
                case "prompts/list":
                    result = .object(["prompts": .array([])])
                case "resources/list":
                    let encoded = (try? JSONEncoder().encode(resources))
                        .flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? .array([])
                    result = .object(["resources": encoded])
                case "resources/templates/list":
                    let encoded = (try? JSONEncoder().encode(templates))
                        .flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? .array([])
                    result = .object(["resourceTemplates": encoded])
                case "resources/read":
                    var uri = ""
                    if case .object(let params) = rpc.params, case .string(let u) = params["uri"] {
                        uri = u
                    }
                    result = .object(["contents": .array(readHandler(uri))])
                default:
                    result = .object([:])
                }
                let responseObj = CoreMCP.JSONRPCMessage.response(CoreMCP.JSONRPCResponse(id: rpc.id, result: result))
                let respBytes = Array(try JSONEncoder().encode(responseObj))
                return HTTPResponse(
                    head: HTTPResponseHead(
                        statusCode: 200,
                        headers: [
                            "content-type": "application/json",
                            "mcp-session-id": "mcp-sess-test-1",
                        ]
                    ),
                    body: respBytes
                )
            case .response:
                return HTTPResponse(head: HTTPResponseHead(statusCode: 202, headers: [:]), body: [])
            }
        })
    }

    /// Minimal `CoreMCP.Client.Events` provider for verifying `list_mcp_events` push filtering.
    final class StubMCPEvents: CoreMCP.Client.Events, Sendable {
        private let eventTypes: [CoreMCP.Client.EventType]

        init(eventTypes: [CoreMCP.Client.EventType]) {
            self.eventTypes = eventTypes
        }

        func list() async throws -> [CoreMCP.Client.EventType] {
            eventTypes
        }

        func check(name: String, arguments: [String: JSONValue]?) async throws {
            _ = arguments
            guard let match = eventTypes.first(where: { $0.name == name }), match.delivery.contains("push") else {
                throw CoreMCP.Client.EventStreamRejectedError(
                    server: "stub",
                    code: -32023,
                    message: "No push event type \(name) on MCP server stub"
                )
            }
        }

        func stream(
            name: String,
            arguments: [String: JSONValue]?,
            cursor: String?,
            maxAgeMs: Int?
        ) async throws -> AsyncThrowingStream<CoreMCP.Client.EventMessage, any Error> {
            _ = (name, arguments, cursor, maxAgeMs)
            return AsyncThrowingStream { $0.finish() }
        }
    }

    /// Decorator around a real `CoreMCP.Registry.Service` that supplies event descriptors for named servers.
    final class EventfulMCPRegistry: CoreMCP.Registry.Interface, Sendable {
        private let base: CoreMCP.Registry.Service
        private let eventProviders: [String: any CoreMCP.Client.Events]

        init(base: CoreMCP.Registry.Service, eventProviders: [String: any CoreMCP.Client.Events]) {
            self.base = base
            self.eventProviders = eventProviders
        }

        @discardableResult
        func transform(_ update: @escaping @Sendable (CoreMCP.Registry.Editor) throws -> Void) async throws -> CoreState.Registration {
            try await base.transform(update)
        }

        func reload() async { await base.reload() }
        func servers() async -> [CoreMCP.Registry.ServerInfo] { await base.servers() }
        func add(server: String, config: McpSchema.ServerConfig) async { await base.add(server: server, config: config) }
        func connect(server: String) async throws { try await base.connect(server: server) }
        func disconnect(server: String) async throws { try await base.disconnect(server: server) }
        func remove(server: String) async throws { try await base.remove(server: server) }
        func attach(name: String, transport: any CoreMCP.Transport) async throws { try await base.attach(name: name, transport: transport) }
        func tools() async -> [CoreMCP.Registry.Tool] { await base.tools() }
        func awaitStartup() async { await base.awaitStartup() }
        func callTool(server: String, name: String, args: [String: JSONValue]?, sessionID: SessionID?) async throws -> CoreMCP.Registry.ToolResult {
            try await base.callTool(server: server, name: name, args: args, sessionID: sessionID)
        }
        func instructions() async -> [CoreMCP.Registry.ServerInstructions] { await base.instructions() }
        func prompts() async -> [CoreMCP.Registry.Prompt] { await base.prompts() }
        func prompt(server: String, name: String, args: [String: String]?) async throws -> CoreMCP.Registry.PromptResult? {
            try await base.prompt(server: server, name: name, args: args)
        }
        func resourceCatalog() async -> CoreMCP.Registry.ResourceCatalog { await base.resourceCatalog() }
        func resources(server: String) async throws -> CoreMCP.Registry.ResourceCatalog { try await base.resources(server: server) }
        func readResource(server: String, uri: String) async throws -> CoreMCP.Registry.ResourceContent? {
            try await base.readResource(server: server, uri: uri)
        }
        func events(server: String) async throws -> (any CoreMCP.Client.Events)? {
            if let provider = eventProviders[server] { return provider }
            return try await base.events(server: server)
        }
        func follow(
            server: String,
            name: String,
            arguments: [String: JSONValue]?,
            position: CoreMCP.Registry.EventPosition?
        ) async throws -> AsyncThrowingStream<CoreMCP.Registry.EventUpdate, Swift.Error> {
            if let provider = eventProviders[server] {
                return CoreMCP.Registry.followEvents(
                    server: CoreMCP.Registry.ServerName(rawValue: server),
                    name: name,
                    arguments: arguments,
                    position: position
                ) { provider }
            }
            return try await base.follow(server: server, name: name, arguments: arguments, position: position)
        }
        func subscribe(server: String, name: String, arguments: [String: JSONValue]?, cursor: String?) async throws -> CoreMCP.Registry.Subscription {
            try await base.subscribe(server: server, name: name, arguments: arguments, cursor: cursor)
        }
        func unsubscribe(id: String) async { await base.unsubscribe(id: id) }
        func subscriptions() async -> [CoreMCP.Registry.Subscription] { await base.subscriptions() }
    }

    /// Recording `CoreIntegration.Generate.Interface` for testing `experimental_image_generate`.
    final class RecordingGenerateService: CoreIntegration.Generate.Interface, Sendable {
        private let requestsBox = Mutex<[GenerateSchema.ImageRequest]>([])
        private let imageBytes: [UInt8]
        private let mime: String

        init(imageBytes: [UInt8] = RealToolsAndPtyHelper.samplePNGBytes(), mime: String = "image/png") {
            self.imageBytes = imageBytes
            self.mime = mime
        }

        func recordedImageRequests() -> [GenerateSchema.ImageRequest] {
            requestsBox.withLock { $0 }
        }

        func text(_ input: CoreIntegration.Generate.TextInput) async throws -> String {
            "generated:\(input.prompt)"
        }

        func image(_ input: GenerateSchema.ImageRequest) async throws -> GenerateSchema.ImageResult {
            requestsBox.withLock { $0.append(input) }
            return GenerateSchema.ImageResult(images: [
                GenerateSchema.ImageOutput(
                    data: Data(imageBytes).base64EncodedString(),
                    mime: mime,
                    name: "out.png"
                ),
            ])
        }

        func decisions(_ input: GenerateSchema.DecisionRequest) async throws -> GenerateSchema.DecisionResult {
            throw CoreIntegration.Generate.UnavailableError(message: "decisions unused in test")
        }

        func videoStart(_ input: CoreIntegration.Generate.VideoInput) async throws -> String {
            throw CoreIntegration.Generate.UnavailableError(message: "video unused in test")
        }

        func videoStatus(model: ModelSchema.Ref, id: String) async throws -> AIVideo.VideoStatus {
            throw CoreIntegration.Generate.UnavailableError(message: "video unused in test")
        }

        func videoResult(model: ModelSchema.Ref, id: String) async throws -> [CoreIntegration.Generate.VideoFile] {
            throw CoreIntegration.Generate.UnavailableError(message: "video unused in test")
        }

        func videoCancel(model: ModelSchema.Ref, id: String) async throws {
            throw CoreIntegration.Generate.UnavailableError(message: "video unused in test")
        }
    }

    /// Helper to insert a project row in SQLite for `CoreWorktree.Service` tests.
    static func registerProject(
        db: any SQLiteDatabase,
        projectID: ProjectID,
        worktreePath: String
    ) throws {
        let now = Flock.currentEpochMs()
        _ = try db.execute(
            """
            INSERT INTO project (id, worktree, time_created, time_updated, sandboxes)
            VALUES (?, ?, ?, ?, '[]')
            ON CONFLICT (id) DO UPDATE SET worktree = excluded.worktree
            """,
            parameters: [.text(projectID.rawValue), .text(worktreePath), .integer(now), .integer(now)]
        )
    }

    /// Helper to insert a persisted assistant message with snapshot metadata into SQLite
    /// so `CoreSessionRevert.stage` and `CoreSessionDiff.turn` can be tested end-to-end.
    static func insertSessionMessagesForRevert(
        db: any SQLiteDatabase,
        sessionID: SessionID,
        userMessageID: SessionMessageSchema.ID,
        assistantMessageID: SessionMessageSchema.ID,
        startSnapshot: String,
        endSnapshot: String,
        files: [String]
    ) throws {
        let now = Flock.currentEpochMs()
        let userJSON = "{\"text\":\"edit files\"}"
        _ = try db.execute(
            """
            INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data)
            VALUES (?, ?, 'user', 1, ?, ?, ?)
            """,
            parameters: [
                .text(userMessageID.rawValue),
                .text(sessionID.rawValue),
                .integer(now),
                .integer(now),
                .text(userJSON),
            ]
        )

        let assistant = SessionMessageSchema.Assistant(
            id: assistantMessageID,
            agent: "build",
            model: SessionSchema.ModelRef(id: "gpt-5", providerID: "openai"),
            content: [.text(SessionMessageSchema.AssistantText(text: "Done"))],
            snapshot: SessionMessageSchema.Assistant.Snapshot(
                start: startSnapshot,
                end: endSnapshot,
                files: files
            ),
            finish: .stop,
            cost: 0,
            time: SessionMessageSchema.Assistant.Time(created: now, completed: now)
        )
        let encoded = try JSONEncoder().encode(assistant)
        let jsonVal = try JSONDecoder().decode(JSONValue.self, from: encoded)
        guard case .object(var dict) = jsonVal else { return }
        dict.removeValue(forKey: "id")
        dict.removeValue(forKey: "type")
        let strippedData = try JSONEncoder().encode(JSONValue.object(dict))
        let assistantJSON = String(decoding: strippedData, as: UTF8.self)
        _ = try db.execute(
            """
            INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data)
            VALUES (?, ?, 'assistant', 2, ?, ?, ?)
            """,
            parameters: [
                .text(assistantMessageID.rawValue),
                .text(sessionID.rawValue),
                .integer(now + 1),
                .integer(now + 1),
                .text(assistantJSON),
            ]
        )
    }
}
