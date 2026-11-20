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
import OpenCodeServer
import OpenCodeUtil

/// Scriptable `HTTPTransport` for end-to-end video generation server/core tests
/// (kept free of `import Testing` per macOS CLT cross-import rule).
final class ServerVideoMockTransport: HTTPTransport, Sendable {
    typealias Handler = @Sendable (HTTPRequest, Int) async throws -> HTTPResponse

    private struct State: Sendable {
        var requests: [HTTPRequest] = []
    }

    private let state = Mutex(State())
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var requests: [HTTPRequest] {
        state.withLock { $0.requests }
    }

    func count(method: String? = nil, matching substring: String) -> Int {
        state.withLock { s in
            s.requests.filter { req in
                (method == nil || req.method == method) && req.url.contains(substring)
            }.count
        }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let idx = state.withLock { s -> Int in
            let current = s.requests.count
            s.requests.append(request)
            return current
        }
        return try await handler(request, idx)
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
        let resp = try await send(request)
        let body = resp.body
        let s = AsyncThrowingStream<[UInt8], Error> { cont in
            if !body.isEmpty { cont.yield(body) }
            cont.finish()
        }
        return HTTPStreamingResponse(head: resp.head, chunks: s)
    }
}

struct ServerVideoHarness: Sendable {
    let handle: ServerFetch.Handle
    let fileSystem: any OpenCodeFileSystem
    let transport: ServerVideoMockTransport
    let rootDir: String
    let dbPath: String

    var runtime: ServerAppRuntime { handle.runtime }

    func close() async {
        await handle.close()
    }
}

enum ServerVideoFixture {
    /// Minimal valid ISO-BMFF MP4 bytes (`ftypisom`) so `CoreBlobStore` sniffs `video/mp4`.
    static func sampleMP4Bytes(tag: UInt8 = 0x01) -> [UInt8] {
        [
            0x00, 0x00, 0x00, 0x18,
            0x66, 0x74, 0x79, 0x70, // "ftyp"
            0x69, 0x73, 0x6F, 0x6D, // "isom"
            0x00, 0x00, 0x02, 0x00,
            0x69, 0x73, 0x6F, 0x6D,
            0x6D, 0x70, 0x34, 0x31,
            0x00, 0x00, 0x00, 0x08,
            0x6D, 0x64, 0x61, 0x74, // "mdat"
            tag, 0xAA, 0xBB, 0xCC,
        ]
    }

    static func samplePNGBytes() -> [UInt8] {
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D]
    }

    static func base64(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
    }

    static func jsonResponse(
        _ value: JSONValue,
        statusCode: Int = 200,
        headers: [String: String] = [:]
    ) throws -> HTTPResponse {
        let data = try JSONEncoder().encode(value)
        var h = headers
        h["content-type"] = "application/json"
        return HTTPResponse(head: HTTPResponseHead(statusCode: statusCode, headers: h), body: Array(data))
    }

    static func bytesResponse(
        _ bytes: [UInt8],
        contentType: String = "video/mp4",
        statusCode: Int = 200
    ) -> HTTPResponse {
        HTTPResponse(head: HTTPResponseHead(statusCode: statusCode, headers: ["content-type": contentType]), body: bytes)
    }

    static func decodeJSON<T: Decodable>(_ type: T.Type, from bytes: [UInt8]) throws -> T {
        try JSONDecoder().decode(type, from: Data(bytes))
    }

    struct DataEnvelope<T: Decodable>: Decodable {
        let data: T
    }

    static func responseBytes(_ response: ServerHTTPResponse) async throws -> [UInt8] {
        switch response.body {
        case .empty:
            return []
        case .bytes(let b):
            return b
        case .stream(let stream):
            var out: [UInt8] = []
            for try await chunk in stream {
                out.append(contentsOf: chunk)
            }
            return out
        }
    }

    static func executeTool(
        loc: LocationServices,
        name: String,
        input: JSONValue,
        sessionID: SessionID
    ) async throws -> CoreTool.NormalizedResult {
        guard let tool = await loc.tool.list().first(where: { $0.name == name }) else {
            throw PlatformError.ioFailure("Tool not registered: \(name)")
        }
        let ctx = ToolSchema.Context(
            sessionID: sessionID,
            agent: AgentSchema.ID(rawValue: "build"),
            messageID: SessionMessageSchema.ID.create().rawValue,
            id: ToolSchema.CallID(rawValue: "call_\(OpenCodeUtil.uuid())"),
            progress: { _ in }
        )
        return try await CoreTool.Runtime.execute(tool, input: input, context: ctx)
    }

    static func sessionHasNotice(
        runtime: ServerAppRuntime,
        sessionID: SessionID,
        containing needle: String
    ) -> Bool {
        let inbox = (try? runtime.sessionInbox.list(sessionID)) ?? []
        for item in inbox {
            if case .synthetic(let syn) = item, syn.payload.text.contains(needle) {
                return true
            }
        }
        let msgs = (try? runtime.sessionStore.messages(CoreSessionStore.MessagesInput(sessionID: sessionID))) ?? []
        for msg in msgs {
            if case .synthetic(let syn) = msg, syn.text.contains(needle) {
                return true
            }
        }
        return false
    }

    static func decodeObject(_ bytes: [UInt8]) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: Data(bytes))
    }

    static func encodeJSON<T: Encodable>(_ value: T) throws -> [UInt8] {
        Array(try JSONEncoder().encode(value))
    }

    static func makeConfigJSON(
        videoGenerateFlag: Any = true,
        includeXAI: Bool = true,
        includeMiniMax: Bool = true
    ) throws -> String {
        var providers: [String: JSONValue] = [:]
        if includeXAI {
            providers["xai"] = .object([
                "name": .string("xAI"),
                "env": .array([.string("XAI_API_KEY")]),
                "models": .object([
                    "grok-imagine-video": .object([
                        "name": .string("Grok Imagine Video"),
                        "type": .string("video"),
                        "package": .string("@opencode/ai/providers/xai/videos"),
                    ]),
                ]),
            ])
        }
        if includeMiniMax {
            providers["minimax"] = .object([
                "name": .string("MiniMax"),
                "env": .array([.string("MINIMAX_API_KEY")]),
                "models": .object([
                    "MiniMax-H3": .object([
                        "name": .string("MiniMax H3"),
                        "type": .string("video"),
                        "package": .string("@opencode/ai/providers/minimax/videos"),
                    ]),
                    "MiniMax-Hailuo-02": .object([
                        "name": .string("MiniMax Hailuo 02"),
                        "type": .string("video"),
                        "package": .string("@opencode/ai/providers/minimax/videos"),
                    ]),
                ]),
            ])
        }
        let flagVal: JSONValue
        if let b = videoGenerateFlag as? Bool {
            flagVal = .bool(b)
        } else if let modelSelection = videoGenerateFlag as? String {
            flagVal = .object(["model": .string(modelSelection)])
        } else {
            flagVal = .bool(true)
        }
        let root: JSONValue = .object([
            "experimental": .object([
                "video_generate": flagVal,
            ]),
            "provider": .object(providers),
        ])
        let data = try JSONEncoder().encode(root)
        return String(decoding: data, as: UTF8.self)
    }

    static func makeHarness(
        configContent: String?,
        env: [String: String] = ["XAI_API_KEY": "xai-test-key", "MINIMAX_API_KEY": "mm-test-key"],
        fileSystem: InMemoryFileSystem? = nil,
        databaseClient: (any SQLiteDatabase)? = nil,
        workerdProfile: Bool = false,
        pollIntervalMs: UInt64 = 15,
        rootDir: String = "/workspace",
        onLocationBoot: ServerAppRuntime.LocationCustomizer? = nil,
        handler: @escaping ServerVideoMockTransport.Handler
    ) async throws -> ServerVideoHarness {
        let fs = fileSystem ?? InMemoryFileSystem(initialFiles: ["\(rootDir)/.keep": Array("ok".utf8)])
        try await fs.makeDirectory(at: rootDir, recursive: true)
        try await fs.makeDirectory(at: "/tmp/opencode-vid-test/config", recursive: true)
        try await fs.makeDirectory(at: "/tmp/opencode-vid-test/data", recursive: true)
        try await fs.makeDirectory(at: "/tmp/opencode-vid-test/cache", recursive: true)
        try await fs.makeDirectory(at: "/tmp/opencode-vid-test/log", recursive: true)
        try await fs.makeDirectory(at: "/tmp/opencode-vid-test/home", recursive: true)
        try await fs.makeDirectory(at: "/tmp/opencode-vid-test/tmp", recursive: true)

        let globalOverrides = Global.Overrides(
            home: "/tmp/opencode-vid-test/home",
            data: "/tmp/opencode-vid-test/data",
            cache: "/tmp/opencode-vid-test/cache",
            config: "/tmp/opencode-vid-test/config",
            state: "/tmp/opencode-vid-test/state",
            tmp: "/tmp/opencode-vid-test/tmp",
            bin: "/tmp/opencode-vid-test/bin",
            log: "/tmp/opencode-vid-test/log",
            repos: "/tmp/opencode-vid-test/repos"
        )

        let options = ServerOptions(
            app: ServerOptions.AppOptions(name: "opencode", version: "2.0.0-vid-test", channel: "prod"),
            events: ServerOptions.EventsOptions(persist: true),
            models: CoreModel.ModelsDev.Options(fetch: false),
            config: ServerOptions.ConfigOptions(
                directory: "/tmp/opencode-vid-test/config",
                project: false,
                claude: false,
                content: configContent
            )
        )

        let transport = ServerVideoMockTransport(handler: handler)
        let handle = try await ServerFetch.make(
            options: options,
            boot: ServerFetch.BootOptions(
                fileSystem: fs,
                httpTransport: transport,
                environment: DictionaryEnvironment(
                    variables: env,
                    homeDirectory: "/tmp/opencode-vid-test/home",
                    temporaryDirectory: "/tmp/opencode-vid-test/tmp"
                ),
                globalOverrides: globalOverrides,
                defaultDirectory: rootDir,
                databaseClient: databaseClient,
                workerdProfile: workerdProfile,
                videoGenerationPollIntervalMs: pollIntervalMs,
                onLocationBoot: onLocationBoot
            )
        )

        return ServerVideoHarness(
            handle: handle,
            fileSystem: fs,
            transport: transport,
            rootDir: rootDir,
            dbPath: ":memory:"
        )
    }

    static func request(
        _ handle: ServerFetch.Handle,
        method: HTTPMethod,
        path: String,
        body: [UInt8]? = nil,
        headers: [String: String] = [:]
    ) async -> ServerHTTPResponse {
        var h = headers
        if body != nil && h["content-type"] == nil {
            h["content-type"] = "application/json"
        }
        return await handle.fetch(ServerHTTPRequest(
            method: method.rawValue,
            url: "http://127.0.0.1:4096\(path)",
            headers: h,
            body: body ?? []
        ))
    }

    static func waitUntil(
        timeoutMs: Int = 5_000,
        stepMs: UInt64 = 20,
        _ condition: @Sendable () async throws -> Bool
    ) async throws -> Bool {
        let attempts = max(1, timeoutMs / Int(stepMs))
        for _ in 0..<attempts {
            if try await condition() { return true }
            try await Task.sleep(nanoseconds: stepMs * 1_000_000)
        }
        return try await condition()
    }

    /// Creates a shared temporary SQLite file path and returns a cleanup helper.
    static func makeTempSQLitePath() -> (path: String, cleanup: @Sendable () -> Void) {
        let base = FileManager.default.temporaryDirectory.path
        let path = "\(base)/opencode-video-test-\(OpenCodeUtil.uuid()).sqlite"
        return (path, {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: "\(path)-wal")
            try? FileManager.default.removeItem(atPath: "\(path)-shm")
        })
    }

    static func makeVideoModelInfo(providerID: String, modelID: String, package: String) -> ModelSchema.Info {
        ModelSchema.Info(
            id: ModelSchema.ID(rawValue: modelID),
            modelID: ModelSchema.ID(rawValue: modelID),
            providerID: ProviderSchema.ID(rawValue: providerID),
            type: .video,
            family: ModelSchema.Family(rawValue: "video"),
            name: modelID,
            package: package,
            capabilities: ModelSchema.Capabilities(
                tools: false,
                input: ["text", "image"],
                output: ["video"]
            ),
            variants: [],
            time: ModelSchema.Info.Time(released: 1_700_000_000_000),
            cost: [],
            status: .active,
            enabled: true,
            limit: ModelSchema.Info.Limit(context: 0, output: 0)
        )
    }
}
