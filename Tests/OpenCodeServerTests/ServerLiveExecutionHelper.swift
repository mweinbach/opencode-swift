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

/// Routes remote instruction GET requests to a custom handler while delegating LLM API requests to
/// `LiveExecutionMockTransport` (no `import Testing` per macOS CLT cross-import rule).
final class LiveInstructionRoutingTransport: HTTPTransport, Sendable {
    private let llm: LiveExecutionMockTransport
    private let remoteHandler: @Sendable (HTTPRequest) async throws -> HTTPResponse
    private let remoteRequestsBox = Mutex<[HTTPRequest]>([])

    init(
        llm: LiveExecutionMockTransport,
        remoteHandler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse
    ) {
        self.llm = llm
        self.remoteHandler = remoteHandler
    }

    var recordedLLMRequests: [HTTPRequest] {
        llm.recordedRequests
    }

    var recordedRemoteRequests: [HTTPRequest] {
        remoteRequestsBox.withLock { $0 }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if request.method == "GET" && !request.url.contains("anthropic.com") && !request.url.contains("openai.com") {
            remoteRequestsBox.withLock { $0.append(request) }
            return try await remoteHandler(request)
        }
        return try await llm.send(request)
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
        try await llm.stream(request)
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
        rootDir: String = "/workspace",
        homeDir: String = "/tmp/opencode-live-test/home",
        configDir: String = "/tmp/opencode-live-test/config",
        project: Bool = false,
        claude: Bool = false,
        filewatcher: Bool? = nil,
        customWatcher: (any CoreFilesystem.Watcher.Interface)? = nil,
        configDebounce: Duration = CoreConfig.Service.defaultDebounce,
        instructionDebounce: Duration = CoreConfigPlugin.Instruction.Loader.defaultDebounce,
        instructionURLTimeout: Duration = CoreConfigPlugin.Instruction.Loader.defaultURLFetchTimeout,
        httpTransport: (any HTTPTransport)? = nil
    ) async throws -> LiveExecutionHarness {
        var files = initialFiles
        if files["\(rootDir)/.keep"] == nil {
            files["\(rootDir)/.keep"] = Array("ok".utf8)
        }
        let fs = InMemoryFileSystem(initialFiles: files)
        try await fs.makeDirectory(at: rootDir, recursive: true)
        try await fs.makeDirectory(at: configDir, recursive: true)
        try await fs.makeDirectory(at: "/tmp/opencode-live-test/data", recursive: true)
        try await fs.makeDirectory(at: "/tmp/opencode-live-test/log", recursive: true)
        try await fs.makeDirectory(at: homeDir, recursive: true)

        let globalOverrides = Global.Overrides(
            home: homeDir,
            data: "/tmp/opencode-live-test/data",
            cache: "/tmp/opencode-live-test/cache",
            config: configDir,
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
                directory: configDir,
                project: project,
                claude: claude,
                content: configContent
            ),
            instructions: ServerOptions.InstructionsOptions(claude: claude),
            fs: filewatcher.map { ServerOptions.FSOptions(filewatcher: $0) }
        )

        let mockTransport = LiveExecutionMockTransport(responses: responses)
        let handle = try await ServerFetch.make(
            options: options,
            boot: ServerFetch.BootOptions(
                fileSystem: fs,
                httpTransport: httpTransport ?? mockTransport,
                environment: DictionaryEnvironment(
                    variables: env,
                    homeDirectory: homeDir,
                    temporaryDirectory: "/tmp/opencode-live-test/tmp"
                ),
                globalOverrides: globalOverrides,
                defaultDirectory: rootDir,
                customWatcher: customWatcher,
                configDebounce: configDebounce,
                instructionDebounce: instructionDebounce,
                instructionURLTimeout: instructionURLTimeout
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

    /// Real on-disk harness backed by `LocalFileSystem.shared` and `NativeFileWatcher` for end-to-end
    /// instruction watching tests.
    struct RealDiskInstructionHarness: Sendable {
        let harness: LiveExecutionHarness
        let rootTempDir: String
        let configDir: String
        let homeDir: String
        let projectDir: String
        let locationDir: String
        let cleanup: @Sendable () async -> Void
    }

    static func makeRealDiskInstructionHarness(
        env: [String: String] = ["ANTHROPIC_API_KEY": "sk-ant-live-secret"],
        configContent: String? = nil,
        responses: [LiveExecutionMockTransport.ScriptedResponse] = [],
        configDebounce: Duration = CoreConfig.Service.defaultDebounce,
        instructionDebounce: Duration = CoreConfigPlugin.Instruction.Loader.defaultDebounce
    ) async throws -> RealDiskInstructionHarness {
        let baseTmp = FileManager.default.temporaryDirectory.path
        let rawRoot = "\(baseTmp)/opencode-instr-disk-\(OpenCodeUtil.uuid())"
        try await LocalFileSystem.shared.makeDirectory(at: rawRoot, recursive: true)
        let rootTempDir = (try? await LocalFileSystem.shared.realPath(at: rawRoot)) ?? rawRoot

        let configDir = "\(rootTempDir)/config"
        let homeDir = "\(rootTempDir)/home"
        let projectDir = "\(homeDir)/code/repo"
        let locationDir = "\(projectDir)/packages/core"

        for dir in [
            configDir,
            "\(rootTempDir)/data",
            "\(rootTempDir)/cache",
            "\(rootTempDir)/state",
            "\(rootTempDir)/tmp",
            "\(rootTempDir)/bin",
            "\(rootTempDir)/log",
            "\(rootTempDir)/repos",
            "\(projectDir)/.git",
            locationDir,
        ] {
            try await LocalFileSystem.shared.makeDirectory(at: dir, recursive: true)
        }
        try await LocalFileSystem.shared.writeFile(
            Array("ref: refs/heads/main\n".utf8),
            to: "\(projectDir)/.git/HEAD",
            createDirectories: true
        )

        let globalOverrides = Global.Overrides(
            home: homeDir,
            data: "\(rootTempDir)/data",
            cache: "\(rootTempDir)/cache",
            config: configDir,
            state: "\(rootTempDir)/state",
            tmp: "\(rootTempDir)/tmp",
            bin: "\(rootTempDir)/bin",
            log: "\(rootTempDir)/log",
            repos: "\(rootTempDir)/repos"
        )

        let options = ServerOptions(
            app: ServerOptions.AppOptions(name: "opencode", version: "2.0.0-disk-instr-test", channel: "local"),
            events: ServerOptions.EventsOptions(persist: true),
            models: CoreModel.ModelsDev.Options(fetch: false),
            config: ServerOptions.ConfigOptions(
                directory: configDir,
                project: true,
                claude: true,
                content: configContent
            ),
            instructions: ServerOptions.InstructionsOptions(claude: true)
        )

        let mockTransport = LiveExecutionMockTransport(responses: responses)
        let handle = try await ServerFetch.make(
            options: options,
            boot: ServerFetch.BootOptions(
                fileSystem: LocalFileSystem.shared,
                httpTransport: mockTransport,
                environment: DictionaryEnvironment(
                    variables: env,
                    homeDirectory: homeDir,
                    temporaryDirectory: "\(rootTempDir)/tmp"
                ),
                globalOverrides: globalOverrides,
                defaultDirectory: locationDir,
                configDebounce: configDebounce,
                instructionDebounce: instructionDebounce
            )
        )

        let client = OpenCodeClient(options: ClientOptions(
            baseUrl: "http://127.0.0.1:4096",
            transport: handle.transport
        ))
        let harness = LiveExecutionHarness(
            handle: handle,
            client: client,
            fileSystem: LocalFileSystem.shared,
            mockTransport: mockTransport,
            rootDir: locationDir
        )
        let cleanup: @Sendable () async -> Void = {
            await harness.close()
            try? await LocalFileSystem.shared.remove(at: rootTempDir)
        }
        return RealDiskInstructionHarness(
            harness: harness,
            rootTempDir: rootTempDir,
            configDir: configDir,
            homeDir: homeDir,
            projectDir: projectDir,
            locationDir: locationDir,
            cleanup: cleanup
        )
    }

    /// Subscribes to `instruction-discovery.updated` BEFORE invoking `action`, then waits up to `timeoutMs`
    /// for the watcher-driven reload event. Returns `true` if received before timeout.
    @discardableResult
    static func triggerAndWaitForInstructionUpdate(
        bus: CoreBus.Service,
        location: OpenCodeLocation? = nil,
        timeoutMs: Int = 3_000,
        action: @Sendable () async throws -> Void
    ) async throws -> Bool {
        let stream = bus.subscribe(types: [CoreInstruction.Discovery.Event.updated.type], location: location)
        let seen = Mutex(false)
        let listener = Task {
            for await _ in stream {
                seen.withLock { $0 = true }
                break
            }
        }
        defer { listener.cancel() }
        await Task.yield()
        try await action()
        let deadline = Flock.currentEpochMs() + Int64(timeoutMs)
        while Flock.currentEpochMs() < deadline {
            if seen.withLock({ $0 }) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return seen.withLock { $0 }
    }

    /// Subscribes to `filesystem.changed` BEFORE invoking `action`, then waits for an event matching `file`.
    static func triggerAndWaitForFileChanged(
        bus: CoreBus.Service,
        location: OpenCodeLocation? = nil,
        file: String,
        timeoutMs: Int = 3_000,
        action: @Sendable () async throws -> Void
    ) async throws -> FileSystemSchema.Event.ChangedPayload? {
        let stream = bus.subscribe(types: [FileSystemSchema.Event.changed.type], location: location)
        let matched = Mutex<FileSystemSchema.Event.ChangedPayload?>(nil)
        let listener = Task {
            for await env in stream {
                guard case .object(let obj) = env.data,
                      case .string(let path) = obj["file"],
                      case .string(let kindStr) = obj["event"],
                      let kind = FileSystemSchema.Event.ChangeKind(rawValue: kindStr),
                      path == file
                else { continue }
                matched.withLock { $0 = FileSystemSchema.Event.ChangedPayload(file: path, event: kind) }
                break
            }
        }
        defer { listener.cancel() }
        await Task.yield()
        try await action()
        let deadline = Flock.currentEpochMs() + Int64(timeoutMs)
        while Flock.currentEpochMs() < deadline {
            if let hit = matched.withLock({ $0 }) { return hit }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return matched.withLock { $0 }
    }

    /// Subscribes to `config.updated` BEFORE invoking `action`, waits up to `timeoutMs` for the first event,
    /// and optionally collects any extra events during `settleMs` to verify debouncing/coalescing.
    static func triggerAndCollectConfigUpdates(
        bus: CoreBus.Service,
        location: OpenCodeLocation? = nil,
        timeoutMs: Int = 3_000,
        settleMs: Int = 150,
        action: @Sendable () async throws -> Void
    ) async throws -> [CoreBus.AnyEvent] {
        let stream = bus.subscribe(types: [ConfigSchema.Event.updated.type], location: location)
        let events = Mutex<[CoreBus.AnyEvent]>([])
        let listener = Task {
            for await env in stream {
                events.withLock { $0.append(env) }
            }
        }
        defer { listener.cancel() }
        await Task.yield()
        try await action()
        let deadline = Flock.currentEpochMs() + Int64(timeoutMs)
        while Flock.currentEpochMs() < deadline {
            if !events.withLock({ $0.isEmpty }) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        if settleMs > 0 {
            try? await Task.sleep(for: .milliseconds(settleMs))
        }
        return events.withLock { $0 }
    }

    /// Subscribes to `vcs.branch.updated` BEFORE invoking `action`, and waits for the first branch update
    /// payload (or returns `nil` on timeout).
    static func triggerAndWaitForBranchUpdate(
        bus: CoreBus.Service,
        location: OpenCodeLocation? = nil,
        timeoutMs: Int = 3_000,
        action: @Sendable () async throws -> Void
    ) async throws -> VcsEventSchema.BranchUpdatedData? {
        let stream = bus.subscribe(types: [VcsEventSchema.BranchUpdated.type], location: location)
        let received = Mutex<VcsEventSchema.BranchUpdatedData?>(nil)
        let listener = Task {
            for await env in stream {
                if case .object(let obj) = env.data {
                    let branch: String?
                    if case .string(let b) = obj["branch"] {
                        branch = b
                    } else {
                        branch = nil
                    }
                    received.withLock { $0 = VcsEventSchema.BranchUpdatedData(branch: branch) }
                    break
                }
            }
        }
        defer { listener.cancel() }
        await Task.yield()
        try await action()
        let deadline = Flock.currentEpochMs() + Int64(timeoutMs)
        while Flock.currentEpochMs() < deadline {
            if let hit = received.withLock({ $0 }) { return hit }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return received.withLock { $0 }
    }

    /// Runs a real `git` command in `directory` using the host spawner.
    static func runGit(in directory: String, args: [String]) async throws {
        let spawner = CrossSpawnSpawner.HostProcessSpawner.shared
        let gitExe = CoreSubsystems.Util.GitExecutable.gitExecutable()
        var gitEnv = ProcessInfo.processInfo.environment
        gitEnv["GIT_AUTHOR_NAME"] = "OpenCode Test"
        gitEnv["GIT_AUTHOR_EMAIL"] = "test@opencode.local"
        gitEnv["GIT_COMMITTER_NAME"] = "OpenCode Test"
        gitEnv["GIT_COMMITTER_EMAIL"] = "test@opencode.local"
        let out = try await spawner.run(ProcessSpec(
            executable: gitExe,
            arguments: args,
            workingDirectory: directory,
            environment: gitEnv
        ))
        guard out.exitCode == 0 else {
            let err = String(decoding: out.stderr, as: UTF8.self)
            throw PlatformError.ioFailure("git \(args.joined(separator: " ")) failed: \(err)")
        }
    }

    /// Creates a real on-disk Git repository (with an initial commit on `branchName`) plus a live server
    /// harness backed by `LocalFileSystem.shared` and `NativeFileWatcher` for end-to-end config + VCS tests.
    static func makeRealDiskGitConfigHarness(
        branchName: String = "main",
        env: [String: String] = ["ANTHROPIC_API_KEY": "sk-ant-live-secret"],
        responses: [LiveExecutionMockTransport.ScriptedResponse] = [],
        configDebounce: Duration = .milliseconds(50),
        instructionDebounce: Duration = .milliseconds(50)
    ) async throws -> RealDiskInstructionHarness {
        let baseTmp = FileManager.default.temporaryDirectory.path
        let rawRoot = "\(baseTmp)/opencode-cfg-vcs-disk-\(OpenCodeUtil.uuid())"
        try await LocalFileSystem.shared.makeDirectory(at: rawRoot, recursive: true)
        let rootTempDir = (try? await LocalFileSystem.shared.realPath(at: rawRoot)) ?? rawRoot

        let configDir = "\(rootTempDir)/config"
        let homeDir = "\(rootTempDir)/home"
        let projectDir = "\(homeDir)/repo"
        let locationDir = projectDir

        for dir in [
            configDir,
            "\(rootTempDir)/data",
            "\(rootTempDir)/cache",
            "\(rootTempDir)/state",
            "\(rootTempDir)/tmp",
            "\(rootTempDir)/bin",
            "\(rootTempDir)/log",
            "\(rootTempDir)/repos",
            projectDir,
        ] {
            try await LocalFileSystem.shared.makeDirectory(at: dir, recursive: true)
        }

        try await runGit(in: projectDir, args: ["init", "-b", branchName])
        try await LocalFileSystem.shared.writeFile(
            Array("hello repo\n".utf8),
            to: "\(projectDir)/README.md",
            createDirectories: true
        )
        try await runGit(in: projectDir, args: ["add", "README.md"])
        try await runGit(in: projectDir, args: ["commit", "-m", "initial commit"])

        let globalOverrides = Global.Overrides(
            home: homeDir,
            data: "\(rootTempDir)/data",
            cache: "\(rootTempDir)/cache",
            config: configDir,
            state: "\(rootTempDir)/state",
            tmp: "\(rootTempDir)/tmp",
            bin: "\(rootTempDir)/bin",
            log: "\(rootTempDir)/log",
            repos: "\(rootTempDir)/repos"
        )

        let options = ServerOptions(
            app: ServerOptions.AppOptions(name: "opencode", version: "2.0.0-disk-cfg-vcs-test", channel: "local"),
            events: ServerOptions.EventsOptions(persist: true),
            models: CoreModel.ModelsDev.Options(fetch: false),
            config: ServerOptions.ConfigOptions(
                directory: configDir,
                project: true,
                claude: true
            ),
            instructions: ServerOptions.InstructionsOptions(claude: true)
        )

        let mockTransport = LiveExecutionMockTransport(responses: responses)
        let handle = try await ServerFetch.make(
            options: options,
            boot: ServerFetch.BootOptions(
                fileSystem: LocalFileSystem.shared,
                httpTransport: mockTransport,
                environment: DictionaryEnvironment(
                    variables: env,
                    homeDirectory: homeDir,
                    temporaryDirectory: "\(rootTempDir)/tmp"
                ),
                globalOverrides: globalOverrides,
                defaultDirectory: locationDir,
                configDebounce: configDebounce,
                instructionDebounce: instructionDebounce
            )
        )

        let client = OpenCodeClient(options: ClientOptions(
            baseUrl: "http://127.0.0.1:4096",
            transport: handle.transport
        ))
        let harness = LiveExecutionHarness(
            handle: handle,
            client: client,
            fileSystem: LocalFileSystem.shared,
            mockTransport: mockTransport,
            rootDir: locationDir
        )
        let cleanup: @Sendable () async -> Void = {
            await harness.close()
            try? await LocalFileSystem.shared.remove(at: rootTempDir)
        }
        return RealDiskInstructionHarness(
            harness: harness,
            rootTempDir: rootTempDir,
            configDir: configDir,
            homeDir: homeDir,
            projectDir: projectDir,
            locationDir: locationDir,
            cleanup: cleanup
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
