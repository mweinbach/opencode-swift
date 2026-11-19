import Foundation
import Synchronization
import OpenCodeCLIKit
import OpenCodeClient
import OpenCodeCore
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeTUI
import OpenCodeUtil

/// Mock HTTP transport for deterministic CLI tests (no real sockets required).
final class MockCLIHTTPTransport: HTTPTransport, Sendable {
    private let handler: @Sendable (HTTPRequest) async throws -> HTTPResponse
    private let streamHandler: (@Sendable (HTTPRequest) async throws -> HTTPStreamingResponse)?
    private let recordedRequests = Mutex<[HTTPRequest]>([])

    init(
        handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse,
        streamHandler: (@Sendable (HTTPRequest) async throws -> HTTPStreamingResponse)? = nil
    ) {
        self.handler = handler
        self.streamHandler = streamHandler
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        recordedRequests.withLock { $0.append(request) }
        return try await handler(request)
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
        recordedRequests.withLock { $0.append(request) }
        if let streamHandler {
            return try await streamHandler(request)
        }
        return HTTPStreamingResponse(
            head: HTTPResponseHead(statusCode: 200, headers: ["content-type": "text/event-stream"]),
            chunks: AsyncThrowingStream { continuation in
                continuation.finish()
            }
        )
    }

    var requests: [HTTPRequest] {
        recordedRequests.withLock { $0 }
    }
}

/// Mock process spawner for deterministic CLI command tests.
final class MockCLIProcessSpawner: ProcessSpawner, Sendable {
    private let handler: @Sendable (ProcessSpec) async throws -> ProcessOutput
    private let recorded = Mutex<[ProcessSpec]>([])

    init(handler: @escaping @Sendable (ProcessSpec) async throws -> ProcessOutput) {
        self.handler = handler
    }

    func run(_ spec: ProcessSpec) async throws -> ProcessOutput {
        recorded.withLock { $0.append(spec) }
        return try await handler(spec)
    }

    var specs: [ProcessSpec] {
        recorded.withLock { $0 }
    }
}

/// Mock service child launcher + signaler.
final class MockServiceChild: ServiceChildProcessHandle, Sendable {
    let pid: Int?
    let exitCode: Int32?
    let signalCode: String?

    init(pid: Int? = 4242, exitCode: Int32? = nil, signalCode: String? = nil) {
        self.pid = pid
        self.exitCode = exitCode
        self.signalCode = signalCode
    }

    func setHandlers(
        onStderr: @escaping @Sendable ([UInt8]) -> Void,
        onError: @escaping @Sendable (any Error & Sendable) -> Void,
        onClose: @escaping @Sendable () -> Void
    ) {
        _ = (onStderr, onError, onClose)
    }

    func releaseStderr() {}
}

struct MockServiceLauncher: ServiceProcessLauncher, Sendable {
    func spawn(command: String, args: [String], env: [String: String]) throws -> any ServiceChildProcessHandle {
        _ = (command, args, env)
        return MockServiceChild()
    }
}

final class MockServiceSignaler: ServiceProcessSignaler, Sendable {
    private let runningPIDs: Mutex<Set<Int>>
    private let sentSignals = Mutex<[(Int, String)]>([])

    init(running: Set<Int> = []) {
        self.runningPIDs = Mutex(running)
    }

    func sendSignal(pid: Int, signal: String) {
        sentSignals.withLock { $0.append((pid, signal)) }
        runningPIDs.withLock { _ = $0.remove(pid) }
    }

    func isRunning(pid: Int) -> Bool {
        runningPIDs.withLock { $0.contains(pid) }
    }

    var signals: [(Int, String)] {
        sentSignals.withLock { $0 }
    }
}

/// Mock prompt backend for deterministic interactive tests.
struct MockPromptBackend: CLIUI.Prompt.Backend, Sendable {
    let confirmResult: Bool?
    let textResult: String?
    let passwordResult: String?
    let selectResult: String?
    let multiselectResult: [String]?

    init(
        confirmResult: Bool? = true,
        textResult: String? = "value",
        passwordResult: String? = "secret-key",
        selectResult: String? = nil,
        multiselectResult: [String]? = nil
    ) {
        self.confirmResult = confirmResult
        self.textResult = textResult
        self.passwordResult = passwordResult
        self.selectResult = selectResult
        self.multiselectResult = multiselectResult
    }

    func confirm(message: String, initialValue: Bool) async throws -> Bool {
        _ = (message, initialValue)
        guard let confirmResult else { throw CLIUI.Prompt.CancelledError() }
        return confirmResult
    }

    func text(message: String, placeholder: String?, initialValue: String?, validate: (@Sendable (String) -> String?)?) async throws -> String {
        _ = (message, placeholder, initialValue)
        guard let textResult else { throw CLIUI.Prompt.CancelledError() }
        if let err = validate?(textResult) { throw CLIError(err) }
        return textResult
    }

    func password(message: String, validate: (@Sendable (String) -> String?)?) async throws -> String {
        _ = message
        guard let passwordResult else { throw CLIUI.Prompt.CancelledError() }
        if let err = validate?(passwordResult) { throw CLIError(err) }
        return passwordResult
    }

    func select(message: String, options: [CLIUI.Prompt.SelectOption], initialValue: String?) async throws -> String {
        _ = (message, initialValue)
        if let selectResult { return selectResult }
        if let first = options.first { return first.value }
        throw CLIUI.Prompt.CancelledError()
    }

    func multiselect(message: String, options: [CLIUI.Prompt.SelectOption], initialValues: [String]?, required: Bool) async throws -> [String] {
        _ = (message, options, initialValues, required)
        if let multiselectResult { return multiselectResult }
        throw CLIUI.Prompt.CancelledError()
    }
}

/// Mock remote tunnel backend.
struct MockRemoteTunnelBackend: CLIServices.RemoteTunnel.Backend, Sendable {
    let storedHost: String?
    let ensuredHost: String

    init(storedHost: String? = "tunnel.opencode.dev", ensuredHost: String = "tunnel.opencode.dev") {
        self.storedHost = storedHost
        self.ensuredHost = ensuredHost
    }

    func getTunnelHostname() async throws -> String? { storedHost }
    func ensureTunnel() async throws -> String { ensuredHost }
    func connect(route: String, target: String) async throws -> CLIServices.RemoteTunnel.Connection {
        _ = (route, target)
        return CLIServices.RemoteTunnel.Connection(hostname: ensuredHost)
    }
    func loadStoredHostname() async -> String? { storedHost }
}

/// Mock remote consent prompt for `CLICommands.Pair.remoteConsent`.
struct MockConsentPrompt: CLICommands.Pair.RemoteConsentPrompt, Sendable {
    let isInteractive: Bool
    let confirmAnswer: Bool?

    init(isInteractive: Bool, confirmAnswer: Bool?) {
        self.isInteractive = isInteractive
        self.confirmAnswer = confirmAnswer
    }

    func interactive() -> Bool { isInteractive }
    func confirm() async throws -> Bool? { confirmAnswer }
}

/// JSON & test fixture construction helpers (kept out of files importing `Testing`).
enum CLITestFixtures {
    static func makeContext(
        env: [String: String] = [:],
        files: [String: String] = [:],
        cwd: String = "/workspace/project",
        home: String = "/home/tester",
        tmp: String = "/tmp/test",
        stdinText: String = "",
        isStdinTTY: Bool = false,
        isStdoutTTY: Bool = false,
        columns: Int = 80,
        rows: Int = 24,
        version: String = "2.1.0",
        channel: String = "latest",
        platformOS: PlatformOS = .macOS,
        transport: (any HTTPTransport)? = nil,
        spawner: (any ProcessSpawner)? = nil,
        signaler: (any ServiceProcessSignaler)? = nil,
        serverStarter: CLIServices.ServerProcess.Starter? = nil,
        remoteTunnelBackend: (any CLIServices.RemoteTunnel.Backend)? = nil,
        promptBackend: (any CLIUI.Prompt.Backend)? = nil,
        acpRunner: (@Sendable (CLIContext, Bool) async throws -> Int32)? = nil,
        rawArguments: [String] = []
    ) -> (context: CLIContext, output: CLIBufferedOutput, fs: InMemoryFileSystem) {
        let output = CLIBufferedOutput()
        let io = CLIIO.buffered(
            output: output,
            stdinText: stdinText,
            isStdinTTY: isStdinTTY,
            isStdoutTTY: isStdoutTTY,
            columns: columns,
            rows: rows
        )
        let initialBytes = files.mapValues { Array($0.utf8) }
        let fs = InMemoryFileSystem(initialFiles: initialBytes)
        let environment = DictionaryEnvironment(variables: env, homeDirectory: home, temporaryDirectory: tmp)
        let defaultTransport = transport ?? MockCLIHTTPTransport { req in
            HTTPResponse(
                head: HTTPResponseHead(statusCode: 404, headers: ["content-type": "application/json"]),
                body: Array("{\"error\":\"unhandled \(req.method) \(req.url)\"}".utf8)
            )
        }
        let defaultSpawner = spawner ?? MockCLIProcessSpawner { _ in
            ProcessOutput(exitCode: 0, stdout: [], stderr: [])
        }
        let ctx = CLIContext(
            io: io,
            environment: environment,
            fileSystem: fs,
            transport: defaultTransport,
            spawner: defaultSpawner,
            launcher: MockServiceLauncher(),
            signaler: signaler ?? MockServiceSignaler(),
            cwd: cwd,
            executablePath: "/usr/local/bin/opencode",
            rawArguments: rawArguments,
            version: version,
            channel: channel,
            platformOS: platformOS,
            serverStarter: serverStarter,
            remoteTunnelBackend: remoteTunnelBackend,
            promptBackend: promptBackend,
            acpRunner: acpRunner
        )
        return (ctx, output, fs)
    }

    static func jsonResponse(_ statusCode: Int = 200, json: String, headers: [String: String] = [:]) -> HTTPResponse {
        var hdrs = headers
        hdrs["content-type"] = "application/json"
        return HTTPResponse(
            head: HTTPResponseHead(statusCode: statusCode, headers: hdrs),
            body: Array(json.utf8)
        )
    }

    static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeJSON<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(text.utf8))
    }

    static func sampleStats(empty: Bool = false) -> SessionStatsSchema.Info {
        if empty {
            return SessionStatsSchema.Info(
                range: SessionStatsSchema.Info.TimeRange(from: 1_735_689_600_000, to: 1_736_294_400_000),
                sessions: 0,
                subagents: 0,
                prompts: 0,
                steps: 0,
                tokens: SessionSchema.TokenUsage(input: 0, output: 0, reasoning: 0, cache: .init(read: 0, write: 0)),
                cost: 0,
                tools: .summary(totals: SessionStatsSchema.ToolTotals(calls: 0, succeeded: 0, failed: 0, unfinished: 0)),
                activeDays: 0,
                streak: 0,
                activity: [],
                models: []
            )
        }
        return SessionStatsSchema.Info(
            range: SessionStatsSchema.Info.TimeRange(from: 1_735_689_600_000, to: 1_736_294_400_000),
            sessions: 12,
            subagents: 3,
            prompts: 45,
            steps: 128,
            tokens: SessionSchema.TokenUsage(
                input: 150_000,
                output: 42_000,
                reasoning: 8_000,
                cache: .init(read: 300_000, write: 10_000)
            ),
            cost: 1.45,
            tools: .detail(
                totals: SessionStatsSchema.ToolTotals(calls: 50, succeeded: 48, failed: 2, unfinished: 0),
                usage: [
                    SessionStatsSchema.ToolUsage(name: "bash", calls: 30, succeeded: 29, failed: 1, unfinished: 0, durationP50: 420),
                    SessionStatsSchema.ToolUsage(name: "read", calls: 20, succeeded: 19, failed: 1, unfinished: 0, durationP50: 1500),
                ]
            ),
            activeDays: 5,
            streak: 3,
            activity: [
                SessionStatsSchema.Activity(date: "2025-01-02", steps: 40),
                SessionStatsSchema.Activity(date: "2025-01-03", steps: 88),
            ],
            models: [
                SessionStatsSchema.ModelUsage(
                    model: SessionSchema.ModelRef(id: "claude-sonnet-4", providerID: "anthropic", variant: "high"),
                    steps: 128,
                    tokens: SessionSchema.TokenUsage(input: 150_000, output: 42_000, reasoning: 8_000, cache: .init(read: 300_000, write: 10_000)),
                    cost: 1.45
                ),
            ]
        )
    }

    static func sampleIntegrations() -> [IntegrationSchema.Info] {
        return [
            IntegrationSchema.Info(
                id: IntegrationID(rawValue: "openai"),
                name: "OpenAI",
                metadata: nil,
                methods: [
                    .key(IntegrationSchema.KeyMethod(label: "API Key")),
                    .oauth(IntegrationSchema.OAuthMethod(id: IntegrationMethodID(rawValue: "chatgpt"), label: "ChatGPT Plus")),
                    .env(IntegrationSchema.EnvMethod(names: ["OPENAI_API_KEY"])),
                ],
                connections: [
                    .credential(ConnectionSchema.CredentialInfo(id: CredentialSchema.ID(rawValue: "crd_1"), label: "Personal", method: .key)),
                    .credential(ConnectionSchema.CredentialInfo(id: CredentialSchema.ID(rawValue: "crd_2"), label: "Work", method: .oauth)),
                ]
            ),
            IntegrationSchema.Info(
                id: IntegrationID(rawValue: "opencode-go"),
                name: "OpenCode Go",
                metadata: nil,
                methods: [
                    .oauth(IntegrationSchema.OAuthMethod(id: IntegrationMethodID(rawValue: "oauth"), label: "Sign in")),
                ],
                connections: []
            ),
            IntegrationSchema.Info(
                id: IntegrationID(rawValue: "mcp-linear"),
                name: "Linear MCP",
                metadata: ["source": .string("mcp")],
                methods: [
                    .oauth(IntegrationSchema.OAuthMethod(id: IntegrationMethodID(rawValue: "oauth"), label: "OAuth")),
                ],
                connections: []
            ),
            IntegrationSchema.Info(
                id: IntegrationID(rawValue: "custom-service"),
                name: "Custom Service",
                metadata: nil,
                methods: [
                    .env(IntegrationSchema.EnvMethod(names: ["CUSTOM_TOKEN"])),
                ],
                connections: [
                    .env(ConnectionSchema.EnvInfo(name: "CUSTOM_TOKEN")),
                ]
            ),
        ]
    }

    static func sampleModelsEnvelopeJSON() -> String {
        let envelope = LocationSchema.ResponseEnvelope(
            location: LocationSchema.PublicRef(directory: SchemaPrimitive.AbsolutePath(rawValue: "/workspace/project")),
            data: [
                ModelSchema.Info.default(providerID: ProviderSchema.ID(rawValue: "openai"), id: ModelSchema.ID(rawValue: "gpt-5")),
                ModelSchema.Info.default(providerID: ProviderSchema.ID(rawValue: "anthropic"), id: ModelSchema.ID(rawValue: "claude-sonnet-4")),
            ]
        )
        return (try? encodeJSON(envelope)) ?? "{}"
    }

    static func sampleSessionInfoJSON(id: String = "ses_test0001", title: String = "Demo session") -> String {
        let info = SessionSchema.Info(
            id: SessionID(rawValue: id)!,
            projectID: ProjectID(rawValue: "prj_test0001"),
            cost: 0.0,
            tokens: SessionSchema.TokenUsage(input: 0, output: 0, reasoning: 0, cache: .init(read: 0, write: 0)),
            time: SessionSchema.Info.Time(created: 1_735_689_600_000, updated: 1_735_689_700_000),
            title: title,
            location: SessionSchema.LocationRef(directory: "/workspace/project")
        )
        return (try? encodeJSON(info)) ?? "{}"
    }
}
