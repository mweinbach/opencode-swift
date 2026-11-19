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

/// Streaming mock `HTTPTransport` recording every outbound provider request and yielding
/// scripted chunked SSE responses (no `import Testing` per macOS CLT cross-import rule).
final class LiveExecutionMockTransport: HTTPTransport, Sendable {
    struct ScriptedResponse: Sendable {
        let statusCode: Int
        let headers: [String: String]
        let chunks: [[UInt8]]

        init(statusCode: Int = 200, headers: [String: String] = ["content-type": "text/event-stream"], chunks: [[UInt8]]) {
            self.statusCode = statusCode
            self.headers = headers
            self.chunks = chunks
        }

        static func sseStrings(_ frames: [String], statusCode: Int = 200) -> ScriptedResponse {
            ScriptedResponse(
                statusCode: statusCode,
                headers: ["content-type": "text/event-stream"],
                chunks: frames.map { Array($0.utf8) }
            )
        }
    }

    private struct State: Sendable {
        var requests: [HTTPRequest] = []
        var queue: [ScriptedResponse] = []
    }

    private let state: Mutex<State>

    init(responses: [ScriptedResponse] = []) {
        self.state = Mutex(State(requests: [], queue: responses))
    }

    var recordedRequests: [HTTPRequest] {
        state.withLock { $0.requests }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let resp = try nextResponse(for: request)
        var body: [UInt8] = []
        for c in resp.chunks { body.append(contentsOf: c) }
        return HTTPResponse(
            head: HTTPResponseHead(statusCode: resp.statusCode, headers: resp.headers),
            body: body
        )
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
        let resp = try nextResponse(for: request)
        let chunks = resp.chunks
        let stream = AsyncThrowingStream<[UInt8], Error> { continuation in
            let task = Task {
                for chunk in chunks {
                    continuation.yield(chunk)
                    await Task.yield()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return HTTPStreamingResponse(
            head: HTTPResponseHead(statusCode: resp.statusCode, headers: resp.headers),
            chunks: stream
        )
    }

    private func nextResponse(for request: HTTPRequest) throws -> ScriptedResponse {
        try state.withLock { s in
            s.requests.append(request)
            guard !s.queue.isEmpty else {
                throw PlatformError.ioFailure("LiveExecutionMockTransport: unexpected HTTP request to \(request.url)")
            }
            return s.queue.removeFirst()
        }
    }
}

struct LiveExecutionHarness: Sendable {
    let handle: ServerFetch.Handle
    let client: OpenCodeClient
    let fileSystem: any OpenCodeFileSystem
    let mockTransport: LiveExecutionMockTransport
    let rootDir: String

    var runtime: ServerAppRuntime { handle.runtime }

    func close() async {
        await handle.close()
    }
}

enum LiveExecutionFixture {
    static func makeHarness(
        env: [String: String] = [:],
        configContent: String? = nil,
        initialFiles: [String: [UInt8]] = [:],
        responses: [LiveExecutionMockTransport.ScriptedResponse] = [],
        rootDir: String = "/workspace"
    ) async throws -> LiveExecutionHarness {
        var files = initialFiles
        if files["\(rootDir)/.keep"] == nil {
            files["\(rootDir)/.keep"] = Array("ok".utf8)
        }
        let fs = InMemoryFileSystem(initialFiles: files)
        try await fs.makeDirectory(at: rootDir, recursive: true)
        try await fs.makeDirectory(at: "/tmp/opencode-live-test/config", recursive: true)
        try await fs.makeDirectory(at: "/tmp/opencode-live-test/data", recursive: true)
        try await fs.makeDirectory(at: "/tmp/opencode-live-test/log", recursive: true)
        try await fs.makeDirectory(at: "/tmp/opencode-live-test/home", recursive: true)

        let globalOverrides = Global.Overrides(
            home: "/tmp/opencode-live-test/home",
            data: "/tmp/opencode-live-test/data",
            cache: "/tmp/opencode-live-test/cache",
            config: "/tmp/opencode-live-test/config",
            state: "/tmp/opencode-live-test/state",
            tmp: "/tmp/opencode-live-test/tmp",
            bin: "/tmp/opencode-live-test/bin",
            log: "/tmp/opencode-live-test/log",
            repos: "/tmp/opencode-live-test/repos"
        )

        let options = ServerOptions(
            app: ServerOptions.AppOptions(name: "opencode", version: "2.0.0-live-test", channel: "local"),
            events: ServerOptions.EventsOptions(persist: true),
            config: ServerOptions.ConfigOptions(
                directory: "/tmp/opencode-live-test/config",
                project: false,
                claude: false,
                content: configContent
            )
        )

        let mockTransport = LiveExecutionMockTransport(responses: responses)
        let handle = try await ServerFetch.make(
            options: options,
            boot: ServerFetch.BootOptions(
                fileSystem: fs,
                httpTransport: mockTransport,
                environment: DictionaryEnvironment(
                    variables: env,
                    homeDirectory: "/tmp/opencode-live-test/home",
                    temporaryDirectory: "/tmp/opencode-live-test/tmp"
                ),
                globalOverrides: globalOverrides,
                defaultDirectory: rootDir
            )
        )

        let client = OpenCodeClient(options: ClientOptions(
            baseUrl: "http://127.0.0.1:4096",
            transport: handle.transport
        ))
        return LiveExecutionHarness(
            handle: handle,
            client: client,
            fileSystem: fs,
            mockTransport: mockTransport,
            rootDir: rootDir
        )
    }

    static func utf8(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    static func bytes(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }

    static func decodeJSON(_ bytes: [UInt8]) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: Data(bytes))
    }

    /// Creates a real temporary Git repository on disk on branch `branchName`, commits a file,
    /// adds a modified file, and returns its absolute path + cleanup closure.
    static func makeTemporaryGitRepo(branchName: String) async throws -> (directory: String, cleanup: @Sendable () async -> Void) {
        let baseTmp = FileManager.default.temporaryDirectory.path
        let repoDir = "\(baseTmp)/opencode-vcs-test-\(OpenCodeUtil.uuid())"
        try await LocalFileSystem.shared.makeDirectory(at: repoDir, recursive: true)

        let spawner = CrossSpawnSpawner.HostProcessSpawner.shared
        let gitExe = CoreSubsystems.Util.GitExecutable.gitExecutable()

        @Sendable
        func git(_ args: [String]) async throws {
            let out = try await spawner.run(ProcessSpec(
                executable: gitExe,
                arguments: args,
                workingDirectory: repoDir,
                environment: [
                    "GIT_AUTHOR_NAME": "OpenCode Test",
                    "GIT_AUTHOR_EMAIL": "test@opencode.local",
                    "GIT_COMMITTER_NAME": "OpenCode Test",
                    "GIT_COMMITTER_EMAIL": "test@opencode.local",
                ]
            ))
            guard out.exitCode == 0 else {
                let err = String(decoding: out.stderr, as: UTF8.self)
                throw PlatformError.ioFailure("git \(args.joined(separator: " ")) failed: \(err)")
            }
        }

        try await git(["init", "-b", branchName])
        try await LocalFileSystem.shared.writeFile(
            Array("hello git\n".utf8),
            to: "\(repoDir)/README.md",
            createDirectories: true
        )
        try await git(["add", "README.md"])
        try await git(["commit", "-m", "initial commit"])
        // Create an uncommitted modification and an untracked file to test `GET /api/vcs/status`.
        try await LocalFileSystem.shared.writeFile(
            Array("hello git\nsecond line\n".utf8),
            to: "\(repoDir)/README.md",
            createDirectories: false
        )
        try await LocalFileSystem.shared.writeFile(
            Array("untracked\n".utf8),
            to: "\(repoDir)/extra.txt",
            createDirectories: false
        )

        let cleanup: @Sendable () async -> Void = {
            try? await LocalFileSystem.shared.remove(at: repoDir)
        }
        return (repoDir, cleanup)
    }

    static func makeRealDiskHarness(directory: String) async throws -> LiveExecutionHarness {
        let baseTmp = FileManager.default.temporaryDirectory.path
        let stateRoot = "\(baseTmp)/opencode-disk-state-\(OpenCodeUtil.uuid())"
        try await LocalFileSystem.shared.makeDirectory(at: "\(stateRoot)/config", recursive: true)
        try await LocalFileSystem.shared.makeDirectory(at: "\(stateRoot)/data", recursive: true)
        try await LocalFileSystem.shared.makeDirectory(at: "\(stateRoot)/log", recursive: true)
        try await LocalFileSystem.shared.makeDirectory(at: "\(stateRoot)/home", recursive: true)

        let globalOverrides = Global.Overrides(
            home: "\(stateRoot)/home",
            data: "\(stateRoot)/data",
            cache: "\(stateRoot)/cache",
            config: "\(stateRoot)/config",
            state: "\(stateRoot)/state",
            tmp: "\(stateRoot)/tmp",
            bin: "\(stateRoot)/bin",
            log: "\(stateRoot)/log",
            repos: "\(stateRoot)/repos"
        )

        let options = ServerOptions(
            app: ServerOptions.AppOptions(name: "opencode", version: "2.0.0-vcs-test", channel: "local"),
            events: ServerOptions.EventsOptions(persist: true),
            config: ServerOptions.ConfigOptions(
                directory: "\(stateRoot)/config",
                project: false,
                claude: false
            )
        )

        let mockTransport = LiveExecutionMockTransport()
        let handle = try await ServerFetch.make(
            options: options,
            boot: ServerFetch.BootOptions(
                fileSystem: LocalFileSystem.shared,
                httpTransport: mockTransport,
                environment: DictionaryEnvironment(
                    variables: [:],
                    homeDirectory: "\(stateRoot)/home",
                    temporaryDirectory: "\(stateRoot)/tmp"
                ),
                globalOverrides: globalOverrides,
                defaultDirectory: directory
            )
        )
        let client = OpenCodeClient(options: ClientOptions(
            baseUrl: "http://127.0.0.1:4096",
            transport: handle.transport
        ))
        return LiveExecutionHarness(
            handle: handle,
            client: client,
            fileSystem: LocalFileSystem.shared,
            mockTransport: mockTransport,
            rootDir: directory
        )
    }

    /// Collects live `CoreBus` event types into a thread-safe recorder until disposed.
    final class EventRecorder: Sendable {
        private final class Storage: Sendable {
            let events = Mutex<[CoreBus.AnyEvent]>([])
        }

        private let storage = Storage()
        private let unsubscribe: @Sendable () -> Void

        init(bus: CoreBus.Service) {
            let store = storage
            self.unsubscribe = bus.listen { env in
                store.events.withLock { $0.append(env) }
            }
        }

        func snapshot() -> [CoreBus.AnyEvent] {
            storage.events.withLock { $0 }
        }

        func types() -> [String] {
            storage.events.withLock { $0.map(\.type) }
        }

        func stop() {
            unsubscribe()
        }
    }

    /// Helper for collecting SSE frames from `/api/event` asynchronously in a background task.
    final class SSECollector: Sendable {
        private let typesBox = Mutex<[String]>([])
        private let connectedGate = Mutex<CheckedContinuation<Void, Never>?>(nil)
        private let isConnected = Mutex(false)

        init() {}

        func record(_ eventType: String) {
            typesBox.withLock { $0.append(eventType) }
            if eventType == "server.connected" {
                let cont: CheckedContinuation<Void, Never>? = connectedGate.withLock { c in
                    isConnected.withLock { $0 = true }
                    let current = c
                    c = nil
                    return current
                }
                cont?.resume()
            }
        }

        func waitForConnected() async {
            if isConnected.withLock({ $0 }) { return }
            await withCheckedContinuation { cont in
                let already = isConnected.withLock { $0 }
                if already {
                    cont.resume()
                } else {
                    connectedGate.withLock { $0 = cont }
                }
            }
        }

        func waitUntil(contains eventType: String, timeoutMs: Int = 5_000) async -> Bool {
            let deadline = Flock.currentEpochMs() + Int64(timeoutMs)
            while Flock.currentEpochMs() < deadline {
                if typesBox.withLock({ $0.contains(eventType) }) {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return typesBox.withLock { $0.contains(eventType) }
        }

        func snapshot() -> [String] {
            typesBox.withLock { $0 }
        }
    }

    static func anthropicToolCallStepSSE(
        thinking: String,
        toolCallID: String,
        toolName: String,
        inputChunks: [String]
    ) -> LiveExecutionMockTransport.ScriptedResponse {
        var frames: [String] = []
        frames.append("event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude-sonnet-4-6\",\"usage\":{\"input_tokens\":120,\"output_tokens\":0}}}\n\n")
        frames.append("event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}\n\n")
        frames.append("event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\(jsonString(thinking))}}\n\n")
        frames.append("event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n")
        frames.append("event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\(jsonString(toolCallID)),\"name\":\(jsonString(toolName)),\"input\":{}}}\n\n")
        for chunk in inputChunks {
            frames.append("event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\(jsonString(chunk))}}\n\n")
        }
        frames.append("event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n")
        frames.append("event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":45}}\n\n")
        frames.append("event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n")
        return .sseStrings(frames)
    }

    static func anthropicTextStepSSE(chunks: [String]) -> LiveExecutionMockTransport.ScriptedResponse {
        var frames: [String] = []
        frames.append("event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_2\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude-sonnet-4-6\",\"usage\":{\"input_tokens\":210,\"output_tokens\":0}}}\n\n")
        frames.append("event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n")
        for chunk in chunks {
            frames.append("event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\(jsonString(chunk))}}\n\n")
        }
        frames.append("event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n")
        frames.append("event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":32}}\n\n")
        frames.append("event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n")
        return .sseStrings(frames)
    }

    static func openAIResponsesTextSSE(chunks: [String]) -> LiveExecutionMockTransport.ScriptedResponse {
        var frames: [String] = []
        let fullText = chunks.joined()
        frames.append("data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\",\"status\":\"in_progress\"}}\n\n")
        frames.append("data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"msg_oai_1\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[]}}\n\n")
        for chunk in chunks {
            frames.append("data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_oai_1\",\"output_index\":0,\"content_index\":0,\"delta\":\(jsonString(chunk))}\n\n")
        }
        frames.append("data: {\"type\":\"response.output_text.done\",\"item_id\":\"msg_oai_1\",\"output_index\":0,\"content_index\":0,\"text\":\(jsonString(fullText))}\n\n")
        frames.append("data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"id\":\"msg_oai_1\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\(jsonString(fullText))}]}}\n\n")
        frames.append("data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\",\"usage\":{\"input_tokens\":50,\"output_tokens\":18,\"total_tokens\":68}}}\n\n")
        return .sseStrings(frames)
    }

    static func geminiTextSSE(chunks: [String]) -> LiveExecutionMockTransport.ScriptedResponse {
        var frames: [String] = []
        for (idx, chunk) in chunks.enumerated() {
            let isLast = idx == chunks.count - 1
            let finishPart = isLast
                ? ",\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":40,\"candidatesTokenCount\":14,\"totalTokenCount\":54}}"
                : "}]}"
            frames.append("data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\(jsonString(chunk))}]} \(finishPart)\n\n")
        }
        return .sseStrings(frames)
    }

    static func openAIChatTextSSE(chunks: [String]) -> LiveExecutionMockTransport.ScriptedResponse {
        var frames: [String] = []
        for chunk in chunks {
            frames.append("data: {\"id\":\"chatcmpl_1\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\(jsonString(chunk))},\"finish_reason\":null}]}\n\n")
        }
        frames.append("data: {\"id\":\"chatcmpl_1\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":30,\"completion_tokens\":12,\"total_tokens\":42}}\n\n")
        frames.append("data: [DONE]\n\n")
        return .sseStrings(frames)
    }

    private static func jsonString(_ text: String) -> String {
        let data = (try? JSONEncoder().encode(text)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
