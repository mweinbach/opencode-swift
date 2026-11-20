import Synchronization
import Testing
import OpenCodeCore
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

/// Swift Testing parity suite for the three remaining `core/src/config.ts` behaviors:
/// 1. WellKnown remote config loading, caching, lockdown, precedence, and periodic 10-minute refresh.
/// 2. `Credential.Event.Switched` subscription reloading config and emitting `config.updated` only on change.
/// 3. macOS MDM managed preferences loading via `plutil` with exact upstream precedence and `#if os(macOS)` guards.
@Suite("CoreConfig WellKnown refresh, Credential.Switched, and macOS MDM plutil parity")
struct ConfigRemainingBehaviorsTests {

    // MARK: - Test Doubles

    /// Deterministic virtual `Clock` allowing exact verification of 10-minute refresh and debounce timers
    /// as well as immediate cancellation observation on `close()`.
    private final class ManualClock: Clock, @unchecked Sendable {
        struct Instant: InstantProtocol, Hashable, Sendable {
            var offset: Duration

            static func < (lhs: Instant, rhs: Instant) -> Bool {
                lhs.offset < rhs.offset
            }

            func advanced(by duration: Duration) -> Instant {
                Instant(offset: offset + duration)
            }

            func duration(to other: Instant) -> Duration {
                other.offset - offset
            }
        }

        private struct Sleeper: Sendable {
            let id: UInt64
            let deadline: Instant
            let continuation: CheckedContinuation<Void, any Error>
        }

        private struct State: Sendable {
            var now = Instant(offset: .zero)
            var nextID: UInt64 = 1
            var sleepers: [Sleeper] = []
            var requestedDurations: [Duration] = []
            var cancelledCount: Int = 0
        }

        private let state = Mutex(State())

        var now: Instant {
            state.withLock { $0.now }
        }

        var minimumResolution: Duration { .nanoseconds(1) }

        var pendingSleeperCount: Int {
            state.withLock { $0.sleepers.count }
        }

        var requestedDurations: [Duration] {
            state.withLock { $0.requestedDurations }
        }

        var cancelledCount: Int {
            state.withLock { $0.cancelledCount }
        }

        func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
            _ = tolerance
            if Task.isCancelled {
                state.withLock { $0.cancelledCount += 1 }
                throw CancellationError()
            }
            let sleeperID = state.withLock { s -> UInt64 in
                let id = s.nextID
                s.nextID &+= 1
                s.requestedDurations.append(deadline.offset - s.now.offset)
                return id
            }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    enum Action {
                        case wait
                        case immediateSuccess
                        case immediateCancel
                    }
                    let action: Action = state.withLock { s in
                        if Task.isCancelled {
                            s.cancelledCount += 1
                            return .immediateCancel
                        }
                        if deadline <= s.now {
                            return .immediateSuccess
                        }
                        s.sleepers.append(Sleeper(id: sleeperID, deadline: deadline, continuation: continuation))
                        return .wait
                    }
                    switch action {
                    case .wait:
                        break
                    case .immediateSuccess:
                        continuation.resume()
                    case .immediateCancel:
                        continuation.resume(throwing: CancellationError())
                    }
                }
            } onCancel: { [weak self] in
                guard let self else { return }
                let cancelled: CheckedContinuation<Void, any Error>? = self.state.withLock { s in
                    guard let idx = s.sleepers.firstIndex(where: { $0.id == sleeperID }) else { return nil }
                    let removed = s.sleepers.remove(at: idx)
                    s.cancelledCount += 1
                    return removed.continuation
                }
                cancelled?.resume(throwing: CancellationError())
            }
        }

        func advance(by duration: Duration) {
            let ready: [CheckedContinuation<Void, any Error>] = state.withLock { s in
                s.now = s.now.advanced(by: duration)
                var fired: [CheckedContinuation<Void, any Error>] = []
                var remaining: [Sleeper] = []
                for sleeper in s.sleepers {
                    if sleeper.deadline <= s.now {
                        fired.append(sleeper.continuation)
                    } else {
                        remaining.append(sleeper)
                    }
                }
                s.sleepers = remaining
                return fired
            }
            for cont in ready {
                cont.resume()
            }
        }
    }

    private final class MockHTTPTransport: HTTPTransport, Sendable {
        private let handler: @Sendable (HTTPRequest) async throws -> HTTPResponse
        private let recorded = Mutex<[HTTPRequest]>([])

        init(_ handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse) {
            self.handler = handler
        }

        var requests: [HTTPRequest] {
            recorded.withLock { $0 }
        }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            recorded.withLock { $0.append(request) }
            return try await handler(request)
        }

        func stream(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
            let response = try await send(request)
            let stream = AsyncThrowingStream<[UInt8], Error> { cont in
                cont.yield(response.body)
                cont.finish()
            }
            return HTTPStreamingResponse(head: response.head, chunks: stream)
        }
    }

    private final class FakeProcessSpawner: ProcessSpawner, Sendable {
        private let handler: @Sendable (ProcessSpec) async throws -> ProcessOutput
        private let recorded = Mutex<[ProcessSpec]>([])

        init(_ handler: @escaping @Sendable (ProcessSpec) async throws -> ProcessOutput) {
            self.handler = handler
        }

        var specs: [ProcessSpec] {
            recorded.withLock { $0 }
        }

        func run(_ spec: ProcessSpec) async throws -> ProcessOutput {
            recorded.withLock { $0.append(spec) }
            return try await handler(spec)
        }
    }

    // MARK: - Helpers

    private func makeGlobal(root: String) -> Global.Interface {
        Global.make(Global.Overrides(
            home: "\(root)/home",
            data: "\(root)/data",
            cache: "\(root)/cache",
            config: "\(root)/global",
            state: "\(root)/state",
            tmp: "\(root)/tmp",
            bin: "\(root)/bin",
            log: "\(root)/log",
            repos: "\(root)/repos"
        ))
    }

    private func makeBus() throws -> CoreBus.Service {
        let db = try SQLiteDatabaseFactory.open(path: ":memory:")
        return CoreBus.Service(db: db)
    }

    private func jsonResponse(_ body: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(
            head: HTTPResponseHead(statusCode: status, headers: ["content-type": "application/json"]),
            body: Array(body.utf8)
        )
    }

    private func waitUntil(
        timeoutMs: Int = 2_500,
        _ condition: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Flock.currentEpochMs() + Int64(timeoutMs)
        while Flock.currentEpochMs() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    // MARK: - 1. WellKnown Fetch, Precedence, Lockdown & 10-Minute Periodic Refresh

    @Test("WellKnown merges at upstream precedence, enforces integration.use lockdown, and refreshes every 10 minutes via injected clock")
    func wellKnownPrecedenceAndTenMinuteRefresh() async throws {
        let root = "/wk-refresh"
        let globalDir = "\(root)/global"
        let projectDir = "\(root)/home/repo"
        let origin = "https://acme.example"
        let integrationID = IntegrationID(rawValue: origin)

        let fs = InMemoryFileSystem(initialFiles: [
            "\(globalDir)/opencode.json": Array("""
            {
              "providers": { "shared": { "name": "global" } },
              "policies": [{ "action": "tool.use", "resource": "shell:wk*", "effect": "allow" }]
            }
            """.utf8),
            "\(projectDir)/opencode.json": Array("""
            {
              "providers": { "shared": { "name": "project" } }
            }
            """.utf8),
        ])
        try await fs.makeDirectory(at: "\(root)/home", recursive: true)
        try await fs.makeDirectory(at: projectDir, recursive: true)

        struct ServerState: Sendable {
            var remoteURLPath: String = "/config/{env:ACME_TOKEN}"
            var remoteProviderName: String = "wellknown-remote-v1"
            var remoteUsername: String = "{env:ACME_TOKEN}-user"
        }
        let serverState = Mutex(ServerState())

        let transport = MockHTTPTransport { req in
            let s = serverState.withLock { $0 }
            if req.url == "\(origin)/.well-known/opencode" {
                let manifest = """
                {
                  "auth": { "command": ["acme", "login"], "env": "ACME_TOKEN" },
                  "config": {
                    "providers": { "shared": { "name": "wellknown-embedded" } },
                    "policies": [{ "action": "tool.use", "resource": "shell:wk*", "effect": "deny" }]
                  },
                  "remote_config": {
                    "url": "\(origin)\(s.remoteURLPath)",
                    "headers": { "authorization": "Bearer {env:ACME_TOKEN}" }
                  }
                }
                """
                return HTTPResponse(
                    head: HTTPResponseHead(statusCode: 200, headers: ["content-type": "application/json"]),
                    body: Array(manifest.utf8)
                )
            }
            if req.url == "\(origin)/config/secret-token" && req.headers["authorization"] == "Bearer secret-token" {
                let body = """
                {
                  "config": {
                    "username": "\(s.remoteUsername)",
                    "providers": { "shared": { "name": "\(s.remoteProviderName)" } }
                  }
                }
                """
                return HTTPResponse(
                    head: HTTPResponseHead(statusCode: 200, headers: ["content-type": "application/json"]),
                    body: Array(body.utf8)
                )
            }
            if req.url == "\(origin)/config-v3/secret-token" && req.headers["authorization"] == "Bearer secret-token" {
                let body = """
                {
                  "config": {
                    "username": "v3-user",
                    "providers": { "shared": { "name": "wellknown-remote-v3" } }
                  }
                }
                """
                return HTTPResponse(
                    head: HTTPResponseHead(statusCode: 200, headers: ["content-type": "application/json"]),
                    body: Array(body.utf8)
                )
            }
            return HTTPResponse(head: HTTPResponseHead(statusCode: 404), body: Array("Not Found".utf8))
        }

        let bus = try makeBus()
        let kv = try CoreKV.Service.inMemory()
        let credentials = try CoreProvider.Credential.Service.inMemory(bus: bus)
        let wellKnown = CoreIntegration.WellKnown.Service(transport: transport, kv: kv, bus: bus)

        // Register with trailing slash to verify URL normalization.
        _ = try await wellKnown.add(origin: "\(origin)/")
        _ = try await credentials.create(
            integrationID: integrationID,
            value: .key(CredentialSchema.Key(key: "secret-token")),
            label: "Acme"
        )

        let clock = ManualClock()
        let route = OpenCodeLocation(directory: projectDir)
        let updatedCount = Mutex(0)
        let updatedStream = bus.subscribe(types: [ConfigSchema.Event.updated.type], location: route)
        let updatedTask = Task {
            for await _ in updatedStream {
                updatedCount.withLock { $0 += 1 }
            }
        }
        defer { updatedTask.cancel() }

        let config = await CoreConfig.Service(
            directory: projectDir,
            options: CoreConfig.Options(project: true, global: true, system: .disabled, claude: false),
            globalPaths: makeGlobal(root: root),
            fileSystem: fs,
            environment: DictionaryEnvironment(variables: [:], homeDirectory: "\(root)/home", temporaryDirectory: "\(root)/tmp"),
            bus: bus,
            location: route,
            credentials: credentials,
            wellKnown: wellKnown,
            clock: clock
        )
        defer { Task { await config.close() } }

        // Wait for the periodic 10-minute timer to park on ManualClock.
        #expect(await waitUntil { clock.pendingSleeperCount == 1 })
        #expect(clock.requestedDurations == [.seconds(600)])

        // Verify initial entries include WellKnown docs (embedded + remote) BEFORE global & project,
        // with `{env:ACME_TOKEN}` substituted in both remote URL/headers and config body.
        @Sendable func sharedProviderNames(_ entries: [CoreConfigEntry]) -> [String] {
            entries.compactMap { $0.info?.providers?["shared"]?.name }
        }
        let initialEntries = await config.entries()
        #expect(sharedProviderNames(initialEntries) == [
            "wellknown-embedded",
            "wellknown-remote-v1",
            "global",
            "project",
        ])
        #expect(CoreConfig.latest(initialEntries, \.username) == "secret-token-user")
        // WellKnown policy outranks global policy (earliest-loaded wins in CoreManagedPolicy).
        let initialPolicyStmts = CoreManagedPolicy.statements(initialEntries)
        #expect(CoreManagedPolicy.decision(initialPolicyStmts, action: .toolUse, resource: "shell:wk-cmd") == .deny)

        // Add an integration document (e.g. Console): it must layer BEFORE WellKnown!
        let consoleDoc = CoreConfigIntegration.make(CoreConfigIntegration.MakeInput(
            integrationID: IntegrationID(rawValue: "opencode"),
            connection: .env(ConnectionSchema.EnvInfo(name: "OPENCODE_API_KEY")),
            info: CoreConfigIntegration.Remote(
                providers: ["shared": ConfigProviderSchema.Info(name: "console")]
            )
        ))
        await config.integration(IntegrationID(rawValue: "opencode"), document: consoleDoc)
        #expect(sharedProviderNames(await config.entries()) == [
            "console",
            "wellknown-embedded",
            "wellknown-remote-v1",
            "global",
            "project",
        ])
        #expect(await waitUntil { updatedCount.withLock { $0 } == 1 })

        // 1. Update remote config payload on server; advancing 599s (9m59s) must NOT refresh yet.
        serverState.withLock { $0.remoteProviderName = "wellknown-remote-v2" }
        let reloadsBeforeTick = config.reloadCount
        clock.advance(by: .seconds(599))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(config.reloadCount == reloadsBeforeTick)
        #expect(sharedProviderNames(await config.entries()).contains("wellknown-remote-v1"))

        // 2. Advancing the final 1s hits 10 minutes (600s): manifest unchanged (`refresh()` returns false),
        // so timer explicitly calls `reload()`, picks up `wellknown-remote-v2`, and emits 1 `config.updated`.
        clock.advance(by: .seconds(1))
        #expect(await waitUntil {
            sharedProviderNames(await config.entries()).contains("wellknown-remote-v2")
        })
        #expect(await waitUntil { updatedCount.withLock { $0 } == 2 })
        #expect(await waitUntil { clock.pendingSleeperCount == 1 })

        // 3. Now change the manifest itself (`remote_config.url` -> `/config-v3/{env:ACME_TOKEN}`).
        // Advancing 10 more minutes triggers `wellKnown.refresh()` -> returns true -> emits `WellKnown.Event.updated`
        // -> triggers reload ONCE (no duplicate reload) -> updates to v3 and emits 1 `config.updated`.
        serverState.withLock { $0.remoteURLPath = "/config-v3/{env:ACME_TOKEN}" }
        let reloadsBeforeManifestChange = config.reloadCount
        clock.advance(by: .seconds(600))
        #expect(await waitUntil {
            sharedProviderNames(await config.entries()).contains("wellknown-remote-v3")
        })
        #expect(await waitUntil { updatedCount.withLock { $0 } == 3 })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(config.reloadCount == reloadsBeforeManifestChange + 1)
        #expect(CoreConfig.latest(await config.entries(), \.username) == "v3-user")
        #expect(await waitUntil { clock.pendingSleeperCount == 1 })

        // 4. Advancing another 10 minutes with NO effective change reloads once and emits ZERO `config.updated`.
        let reloadsBeforeNoOp = config.reloadCount
        clock.advance(by: .seconds(600))
        #expect(await waitUntil { config.reloadCount == reloadsBeforeNoOp + 1 })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(updatedCount.withLock { $0 } == 3)
    }

    @Test("ManagedPolicy integration.use lockdown strips denied WellKnown and integration settings while preserving their policies")
    func managedPolicyLockdownWithholdsDeniedSettingsKeepsPolicies() async throws {
        let root = "/wk-lockdown"
        let systemDir = "\(root)/system"
        let globalDir = "\(root)/global"
        let projectDir = "\(root)/home/repo"
        let origin = "https://denied.acme.test"
        let wellKnownID = IntegrationID(rawValue: origin)
        let consoleID = IntegrationID(rawValue: "opencode")

        let fs = InMemoryFileSystem(initialFiles: [
            "\(systemDir)/opencode.json": Array("""
            {
              "policies": [
                { "action": "integration.use", "resource": "*", "effect": "deny" },
                { "action": "integration.use", "resource": "opencode#org_allowed", "effect": "allow" }
              ]
            }
            """.utf8),
        ])
        try await fs.makeDirectory(at: globalDir, recursive: true)
        try await fs.makeDirectory(at: projectDir, recursive: true)

        let transport = MockHTTPTransport { req in
            if req.url == "\(origin)/.well-known/opencode" {
                return HTTPResponse(
                    head: HTTPResponseHead(statusCode: 200),
                    body: Array("""
                    {
                      "auth": { "command": ["login"], "env": "TOKEN" },
                      "config": {
                        "mcp": { "servers": { "wiki": { "type": "remote", "url": "https://wiki.acme.test/mcp" } } },
                        "policies": [{ "action": "tool.use", "resource": "shell:rm*", "effect": "deny" }]
                      }
                    }
                    """.utf8)
                )
            }
            return HTTPResponse(head: HTTPResponseHead(statusCode: 404), body: [])
        }

        let bus = try makeBus()
        let kv = try CoreKV.Service.inMemory()
        let credentials = try CoreProvider.Credential.Service.inMemory(bus: bus)
        let wellKnown = CoreIntegration.WellKnown.Service(transport: transport, kv: kv, bus: bus)

        _ = try await wellKnown.add(origin: origin)
        _ = try await credentials.create(
            integrationID: wellKnownID,
            value: .key(CredentialSchema.Key(key: "wk-secret")),
            label: "WK"
        )
        let personalCred = try await credentials.create(
            integrationID: consoleID,
            value: .key(CredentialSchema.Key(key: "c-personal", metadata: ["orgID": .string("org_personal")])),
            label: "Personal"
        )
        let allowedCred = try await credentials.create(
            integrationID: consoleID,
            value: .key(CredentialSchema.Key(key: "c-allowed", metadata: ["orgID": .string("org_allowed")])),
            label: "Allowed",
            activate: false
        )

        let config = await CoreConfig.Service(
            directory: projectDir,
            options: CoreConfig.Options(project: true, global: true, system: .custom(systemDir), claude: false),
            globalPaths: makeGlobal(root: root),
            fileSystem: fs,
            bus: bus,
            credentials: credentials,
            wellKnown: wellKnown
        )
        defer { Task { await config.close() } }

        func makeConsoleDoc(credID: CredentialSchema.ID, org: String) -> CoreConfigIntegration.Document {
            CoreConfigIntegration.make(CoreConfigIntegration.MakeInput(
                integrationID: consoleID,
                connection: .credential(ConnectionSchema.CredentialInfo(id: credID, label: "Console", method: .key)),
                organization: org,
                info: CoreConfigIntegration.Remote(
                    mcp: ConfigMCPSchema.Info(servers: [
                        "docs": .remote(McpSchema.RemoteConfig(url: "https://docs.acme.test/mcp")),
                    ]),
                    policies: [ConfigPolicySchema.Info(action: .mcpUse, resource: "github", effect: .deny)]
                )
            ))
        }

        // Denied console account + denied well-known origin: both lose MCP servers, both KEEP policies.
        await config.integration(consoleID, document: makeConsoleDoc(credID: personalCred.id, org: "org_personal"))
        var entries = await config.entries()
        let deniedDocs = entries.filter { entry in
            switch entry {
            case .integration, .wellKnown: return true
            default: return false
            }
        }
        #expect(deniedDocs.count == 2)
        #expect(deniedDocs.allSatisfy { ($0.info?.mcp?.servers ?? [:]).isEmpty })
        #expect(deniedDocs.allSatisfy { ($0.info?.policies?.count ?? 0) == 1 })

        // Switching to allowed console account restores console's MCP servers while denied well-known stays stripped.
        await config.integration(consoleID, document: makeConsoleDoc(credID: allowedCred.id, org: "org_allowed"))
        entries = await config.entries()
        let consoleEntry = entries.first { if case .integration = $0 { return true } else { return false } }
        let wkEntry = entries.first { if case .wellKnown = $0 { return true } else { return false } }
        #expect(Array((consoleEntry?.info?.mcp?.servers ?? [:]).keys) == ["docs"])
        #expect(consoleEntry?.info?.policies?.count == 1)
        let wkServers = wkEntry?.info?.mcp?.servers ?? [:]
        #expect(wkServers.isEmpty)
        #expect(wkEntry?.info?.policies?.count == 1)
    }

    // MARK: - 2. Failed Refresh Retains Last Good Value & Logout Clears Cache

    @Test("Failed WellKnown manifest and remote-config refreshes keep the last good value across refreshes and restarts, while logout clears it")
    func failedRefreshKeepsLastGoodValueAndLogoutClears() async throws {
        let root = "/wk-cache"
        let globalDir = "\(root)/global"
        let projectDir = "\(root)/home/repo"
        let origin = "https://resilient.acme.test"
        let integrationID = IntegrationID(rawValue: origin)

        let fs = InMemoryFileSystem()
        try await fs.makeDirectory(at: globalDir, recursive: true)
        try await fs.makeDirectory(at: projectDir, recursive: true)

        struct FaultState: Sendable {
            var manifestStatus: Int = 200
            var remoteStatus: Int = 200
            var remoteRequests: Int = 0
        }
        let fault = Mutex(FaultState())

        let transport = MockHTTPTransport { req in
            if req.url == "\(origin)/.well-known/opencode" {
                let status = fault.withLock { $0.manifestStatus }
                if status != 200 {
                    return HTTPResponse(head: HTTPResponseHead(statusCode: status), body: Array("Unavailable".utf8))
                }
                return HTTPResponse(
                    head: HTTPResponseHead(statusCode: 200),
                    body: Array("""
                    {
                      "auth": { "command": ["login"], "env": "TOKEN" },
                      "remote_config": {
                        "url": "\(origin)/config",
                        "headers": { "authorization": "Bearer {env:TOKEN}" }
                      }
                    }
                    """.utf8)
                )
            }
            if req.url == "\(origin)/config" {
                let status = fault.withLock { s -> Int in
                    s.remoteRequests += 1
                    return s.remoteStatus
                }
                if status != 200 {
                    return HTTPResponse(head: HTTPResponseHead(statusCode: status), body: Array("Unavailable".utf8))
                }
                return HTTPResponse(
                    head: HTTPResponseHead(statusCode: 200),
                    body: Array("""
                    {
                      "config": {
                        "username": "cached-remote-user",
                        "enabled_providers": ["remote"],
                        "provider": { "remote": { "npm": "@ai-sdk/openai-compatible", "models": { "chat": {} } } }
                      }
                    }
                    """.utf8)
                )
            }
            return HTTPResponse(head: HTTPResponseHead(statusCode: 404), body: [])
        }

        let kv = try CoreKV.Service.inMemory()
        let bus = try makeBus()
        let credentials = try CoreProvider.Credential.Service.inMemory(bus: bus)
        let wellKnown = CoreIntegration.WellKnown.Service(transport: transport, kv: kv, bus: bus)

        _ = try await wellKnown.add(origin: origin)
        let initialCred = try await credentials.create(
            integrationID: integrationID,
            value: .key(CredentialSchema.Key(key: "tok-1")),
            label: "Primary"
        )

        let clock = ManualClock()
        let route = OpenCodeLocation(directory: projectDir)
        let updatedCount = Mutex(0)
        let updatedStream = bus.subscribe(types: [ConfigSchema.Event.updated.type], location: route)
        let updatedTask = Task {
            for await _ in updatedStream {
                updatedCount.withLock { $0 += 1 }
            }
        }
        defer { updatedTask.cancel() }

        let config = await CoreConfig.Service(
            directory: projectDir,
            options: CoreConfig.Options(project: true, global: true, system: .disabled, claude: false),
            globalPaths: makeGlobal(root: root),
            fileSystem: fs,
            bus: bus,
            location: route,
            credentials: credentials,
            wellKnown: wellKnown,
            clock: clock
        )
        defer { Task { await config.close() } }

        #expect(await waitUntil { clock.pendingSleeperCount == 1 })
        #expect(CoreConfig.latest(await config.entries(), \.username) == "cached-remote-user")
        #expect(CoreConfig.latest(await config.entries(), \.providers)?["remote"] != nil)

        // 1. Remote config returns 503 during 10-minute refresh -> last good value stays intact, 0 `config.updated`.
        fault.withLock { $0.remoteStatus = 503 }
        let reqsBeforeRemoteFail = fault.withLock { $0.remoteRequests }
        let reloadsBeforeRemoteFail = config.reloadCount
        clock.advance(by: .seconds(600))
        #expect(await waitUntil { config.reloadCount == reloadsBeforeRemoteFail + 1 })
        #expect(fault.withLock { $0.remoteRequests } > reqsBeforeRemoteFail)
        #expect(CoreConfig.latest(await config.entries(), \.username) == "cached-remote-user")
        #expect(CoreConfig.latest(await config.entries(), \.providers)?["remote"] != nil)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(updatedCount.withLock { $0 } == 0)

        // 2. BOTH manifest and remote config return 503 during next 10-minute refresh -> KV manifest & config
        // caches preserve the last good value and emit 0 `config.updated`.
        fault.withLock { $0.manifestStatus = 503 }
        #expect(await waitUntil { clock.pendingSleeperCount == 1 })
        let reloadsBeforeBothFail = config.reloadCount
        clock.advance(by: .seconds(600))
        #expect(await waitUntil { config.reloadCount == reloadsBeforeBothFail + 1 })
        #expect(CoreConfig.latest(await config.entries(), \.username) == "cached-remote-user")
        #expect(wellKnown.snapshot().count == 1)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(updatedCount.withLock { $0 } == 0)

        // 3. Cold restart sharing the same KV store while BOTH endpoints are 503 still loads the last good value!
        let coldWellKnown = CoreIntegration.WellKnown.Service(transport: transport, kv: kv, bus: bus)
        let coldConfig = await CoreConfig.Service(
            directory: projectDir,
            options: CoreConfig.Options(project: true, global: true, system: .disabled, claude: false),
            globalPaths: makeGlobal(root: root),
            fileSystem: fs,
            bus: bus,
            location: route,
            credentials: credentials,
            wellKnown: coldWellKnown,
            clock: ManualClock()
        )
        defer { Task { await coldConfig.close() } }
        #expect(CoreConfig.latest(await coldConfig.entries(), \.username) == "cached-remote-user")
        #expect((try await coldWellKnown.entries()).count == 1)

        // 4. Logging out (`credentials.remove`) emits `Credential.Event.Switched`, clears cached remote config,
        // removes the remote settings, and emits `config.updated`.
        try await credentials.remove(initialCred.id)
        #expect(await waitUntil {
            CoreConfig.latest(await config.entries(), \.username) == nil
        })
        #expect(await waitUntil { updatedCount.withLock { $0 } >= 1 })

        // Re-logging in while remote is still 503 stays empty (cache was cleared on logout).
        let countAfterLogout = updatedCount.withLock { $0 }
        let reloadsBeforeReloginFail = config.reloadCount
        _ = try await credentials.create(
            integrationID: integrationID,
            value: .key(CredentialSchema.Key(key: "tok-2")),
            label: "Relogin"
        )
        #expect(await waitUntil { config.reloadCount > reloadsBeforeReloginFail })
        #expect(CoreConfig.latest(await config.entries(), \.username) == nil)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(updatedCount.withLock { $0 } == countAfterLogout)
    }

    // MARK: - 3. Credential.Event.Switched Reloads & Emits `config.updated` Only On Change

    @Test("Credential.Event.Switched reloads matching WellKnown source and emits config.updated only when effective entries change")
    func credentialSwitchedReloadsAndDeduplicatesEvents() async throws {
        let root = "/cred-switch"
        let globalDir = "\(root)/global"
        let projectDir = "\(root)/home/repo"
        let origin = "https://switch.acme.test"
        let wellKnownID = IntegrationID(rawValue: origin)
        let unrelatedID = IntegrationID(rawValue: "unrelated-provider")

        let fs = InMemoryFileSystem(initialFiles: [
            "\(globalDir)/opencode.json": Array("{\"shell\":\"/bin/global\"}".utf8),
            "\(projectDir)/opencode.json": Array("{\"shell\":\"/bin/project\"}".utf8),
        ])
        try await fs.makeDirectory(at: "\(root)/home", recursive: true)
        try await fs.makeDirectory(at: projectDir, recursive: true)

        let transport = MockHTTPTransport { req in
            if req.url == "\(origin)/.well-known/opencode" {
                return HTTPResponse(
                    head: HTTPResponseHead(statusCode: 200),
                    body: Array("""
                    {
                      "auth": { "command": ["login"], "env": "TOKEN" },
                      "remote_config": {
                        "url": "\(origin)/config",
                        "headers": { "authorization": "Bearer {env:TOKEN}" }
                      }
                    }
                    """.utf8)
                )
            }
            if req.url == "\(origin)/config" {
                switch req.headers["authorization"] {
                case "Bearer expired-token":
                    return HTTPResponse(head: HTTPResponseHead(statusCode: 401), body: Array("Unauthorized".utf8))
                case "Bearer tok-a", "Bearer tok-a-dup":
                    return HTTPResponse(
                        head: HTTPResponseHead(statusCode: 200),
                        body: Array("{\"config\":{\"username\":\"team-alpha\"}}".utf8)
                    )
                case "Bearer tok-b":
                    return HTTPResponse(
                        head: HTTPResponseHead(statusCode: 200),
                        body: Array("{\"config\":{\"username\":\"team-beta\"}}".utf8)
                    )
                default:
                    return HTTPResponse(head: HTTPResponseHead(statusCode: 403), body: [])
                }
            }
            return HTTPResponse(head: HTTPResponseHead(statusCode: 404), body: [])
        }

        let bus = try makeBus()
        let kv = try CoreKV.Service.inMemory()
        let credentials = try CoreProvider.Credential.Service.inMemory(bus: bus)
        let wellKnown = CoreIntegration.WellKnown.Service(transport: transport, kv: kv, bus: bus)

        _ = try await wellKnown.add(origin: origin)
        _ = try await credentials.create(
            integrationID: wellKnownID,
            value: .key(CredentialSchema.Key(key: "expired-token")),
            label: "Expired"
        )

        let route = OpenCodeLocation(directory: projectDir)
        let updatedCount = Mutex(0)
        let updatedStream = bus.subscribe(types: [ConfigSchema.Event.updated.type], location: route)
        let updatedTask = Task {
            for await _ in updatedStream {
                updatedCount.withLock { $0 += 1 }
            }
        }
        defer { updatedTask.cancel() }

        let config = await CoreConfig.Service(
            directory: projectDir,
            options: CoreConfig.Options(project: true, global: true, system: .disabled, claude: false),
            globalPaths: makeGlobal(root: root),
            fileSystem: fs,
            bus: bus,
            location: route,
            credentials: credentials,
            wellKnown: wellKnown,
            clock: ManualClock()
        )
        defer { Task { await config.close() } }

        // Initial load tolerated 401 from expired credential; project/global loaded cleanly.
        #expect(CoreConfig.latest(await config.entries(), \.shell) == "/bin/project")
        #expect(CoreConfig.latest(await config.entries(), \.username) == nil)

        // 1. Switching credential for an UNRELATED integration must NOT reload or emit `config.updated`.
        let reloadsBeforeUnrelated = config.reloadCount
        _ = try await credentials.create(
            integrationID: unrelatedID,
            value: .key(CredentialSchema.Key(key: "ignored")),
            label: "Unrelated"
        )
        try? await Task.sleep(for: .milliseconds(40))
        #expect(config.reloadCount == reloadsBeforeUnrelated)
        #expect(updatedCount.withLock { $0 } == 0)

        // 2. Creating & activating `tok-a` reloads WellKnown config (`team-alpha`) and emits 1 `config.updated`.
        let credA = try await credentials.create(
            integrationID: wellKnownID,
            value: .key(CredentialSchema.Key(key: "tok-a")),
            label: "Alpha"
        )
        #expect(await waitUntil {
            CoreConfig.latest(await config.entries(), \.username) == "team-alpha"
        })
        #expect(await waitUntil { updatedCount.withLock { $0 } == 1 })

        // 3. Switching to `tok-a-dup` (identical effective remote config) reloads, but emits ZERO `config.updated`!
        let reloadsBeforeNoOp = config.reloadCount
        _ = try await credentials.create(
            integrationID: wellKnownID,
            value: .key(CredentialSchema.Key(key: "tok-a-dup")),
            label: "Alpha Dup"
        )
        #expect(await waitUntil { config.reloadCount == reloadsBeforeNoOp + 1 })
        try? await Task.sleep(for: .milliseconds(40))
        #expect(updatedCount.withLock { $0 } == 1)

        // 4. Switching to `tok-b` changes effective config (`team-beta`) and emits 1 more `config.updated`.
        _ = try await credentials.create(
            integrationID: wellKnownID,
            value: .key(CredentialSchema.Key(key: "tok-b")),
            label: "Beta"
        )
        #expect(await waitUntil {
            CoreConfig.latest(await config.entries(), \.username) == "team-beta"
        })
        #expect(await waitUntil { updatedCount.withLock { $0 } == 2 })

        // 5. Activating `credA` again via `credentials.activate` switches back to `team-alpha` and emits `config.updated`.
        try await credentials.activate(credA.id)
        #expect(await waitUntil {
            CoreConfig.latest(await config.entries(), \.username) == "team-alpha"
        })
        #expect(await waitUntil { updatedCount.withLock { $0 } == 3 })
    }

    // MARK: - 4. macOS MDM Managed Preferences via `plutil` (Cross-Platform Fake Spawner)

    @Test("MDM managed preferences plist loads via plutil with exact upstream precedence, metadata stripping, variable substitution, and fallback")
    func mdmManagedPreferencesPrecedenceWithFakeSpawner() async throws {
        let root = "/mdm-test"
        let systemDir = "/Library/Application Support/opencode"
        let globalDir = "\(root)/global"
        let projectDir = "\(root)/home/repo"
        let userPlist = "/Library/Managed Preferences/alice/ai.opencode.managed.plist"
        let machinePlist = "/Library/Managed Preferences/ai.opencode.managed.plist"

        let fs = InMemoryFileSystem(initialFiles: [
            userPlist: Array("bplist00-placeholder".utf8),
            machinePlist: Array("bplist00-machine".utf8),
            "\(systemDir)/opencode.json": Array("""
            {
              "shell": "/bin/system",
              "username": "system-user",
              "policies": [
                { "action": "tool.use", "resource": "shell:sys-override*", "effect": "allow" },
                { "action": "tool.use", "resource": "shell:sys-only*", "effect": "deny" }
              ]
            }
            """.utf8),
            "\(globalDir)/opencode.json": Array("""
            {
              "shell": "/bin/global",
              "timezone": "UTC",
              "policies": [
                { "action": "tool.use", "resource": "shell:sys-override*", "effect": "allow" },
                { "action": "tool.use", "resource": "shell:sys-only*", "effect": "allow" }
              ]
            }
            """.utf8),
            "\(projectDir)/opencode.json": Array("""
            {
              "shell": "/bin/project",
              "timezone": "America/New_York"
            }
            """.utf8),
            "\(root)/home/mdm-tz.txt": Array("Europe/Berlin\n".utf8),
        ])
        try await fs.makeDirectory(at: "\(root)/home", recursive: true)
        try await fs.makeDirectory(at: projectDir, recursive: true)

        let spawner = FakeProcessSpawner { spec in
            guard spec.executable == "plutil" else {
                return ProcessOutput(exitCode: 1, stdout: [], stderr: Array("unexpected command".utf8))
            }
            let target = spec.arguments.last ?? ""
            if target == userPlist {
                let json = """
                {
                  "PayloadDisplayName": "OpenCode Managed",
                  "PayloadIdentifier": "ai.opencode.managed",
                  "PayloadType": "ai.opencode.managed",
                  "PayloadUUID": "00000000-0000-0000-0000-000000000000",
                  "PayloadVersion": 1,
                  "_manualProfile": true,
                  "shell": "{env:MDM_SHELL}",
                  "timezone": "{file:~/mdm-tz.txt}",
                  "share": "disabled",
                  "policies": [
                    { "action": "tool.use", "resource": "shell:sys-override*", "effect": "deny" }
                  ]
                }
                """
                return ProcessOutput(exitCode: 0, stdout: Array(json.utf8), stderr: [])
            }
            if target == machinePlist {
                let json = """
                {
                  "PayloadIdentifier": "ai.opencode.managed",
                  "shell": "/bin/machine-mdm"
                }
                """
                return ProcessOutput(exitCode: 0, stdout: Array(json.utf8), stderr: [])
            }
            return ProcessOutput(exitCode: 1, stdout: [], stderr: Array("missing".utf8))
        }

        let env = DictionaryEnvironment(
            variables: ["USER": "alice", "MDM_SHELL": "/bin/mdm-zsh"],
            homeDirectory: "\(root)/home",
            temporaryDirectory: "\(root)/tmp"
        )
        let config = await CoreConfig.Service(
            directory: projectDir,
            options: CoreConfig.Options(
                project: true,
                global: true,
                system: .enabled,
                claude: false,
                content: "{\"shell\":\"/bin/content\"}"
            ),
            globalPaths: makeGlobal(root: root),
            fileSystem: fs,
            environment: env,
            platform: .macOS,
            processes: AppProcess.Service(spawner: spawner)
        )
        defer { Task { await config.close() } }

        // 1. Verify exact `plutil -convert json -o - <userPlist>` invocation (user-specific plist wins over machine-wide).
        #expect(spawner.specs.count == 1)
        #expect(spawner.specs[0].executable == "plutil")
        #expect(spawner.specs[0].arguments == ["-convert", "json", "-o", "-", userPlist])
        #expect(spawner.specs[0].stdin == [])

        let entries = await config.entries()

        // 2. Settings precedence: MDM > system > content > project > global.
        #expect(CoreConfig.latest(entries, \.shell) == "/bin/mdm-zsh")
        #expect(CoreConfig.latest(entries, \.timezone) == "Europe/Berlin")
        #expect(CoreConfig.latest(entries, \.share) == .disabled)
        // System directory still supplies keys not overridden by MDM.
        #expect(CoreConfig.latest(entries, \.username) == "system-user")

        let shellSequence = entries.compactMap { $0.info?.shell }
        #expect(shellSequence == ["/bin/global", "/bin/project", "/bin/content", "/bin/system", "/bin/mdm-zsh"])

        // 3. Policy precedence: MDM policy > system directory policy > global/project policies.
        let policyStmts = CoreManagedPolicy.statements(entries)
        #expect(CoreManagedPolicy.decision(policyStmts, action: .toolUse, resource: "shell:sys-override-cmd") == .deny)
        #expect(CoreManagedPolicy.decision(policyStmts, action: .toolUse, resource: "shell:sys-only-cmd") == .deny)

        // 4. Managed settings entries are tagged `.managed` with `policies == nil`, while managed policies sit first.
        guard case .managed(let firstManagedPolicy) = entries.first else {
            Issue.record("Expected MDM managed policy document at index 0")
            return
        }
        #expect(firstManagedPolicy.path?.rawValue == userPlist)
        #expect(firstManagedPolicy.info.shell == nil)
        guard case .managed(let lastManagedSettings) = entries.last else {
            Issue.record("Expected MDM managed settings document at last index")
            return
        }
        #expect(lastManagedSettings.path?.rawValue == userPlist)
        #expect(lastManagedSettings.info.policies == nil)

        // 5. Removing user-specific plist falls back to machine-wide `/Library/Managed Preferences/ai.opencode.managed.plist`.
        try await fs.remove(at: userPlist)
        await config.reload()
        #expect(CoreConfig.latest(await config.entries(), \.shell) == "/bin/machine-mdm")
        #expect(spawner.specs.last?.arguments == ["-convert", "json", "-o", "-", machinePlist])

        // 6. Custom system directory or disabled system skips host MDM preferences (matching upstream discovery).
        let customSpawner = FakeProcessSpawner { _ in
            ProcessOutput(exitCode: 0, stdout: Array("{\"shell\":\"/bin/should-not-run\"}".utf8), stderr: [])
        }
        let customSystemConfig = await CoreConfig.Service(
            directory: projectDir,
            options: CoreConfig.Options(project: true, global: true, system: .custom("\(root)/custom-sys"), claude: false),
            globalPaths: makeGlobal(root: root),
            fileSystem: fs,
            environment: env,
            platform: .macOS,
            processes: AppProcess.Service(spawner: customSpawner)
        )
        defer { Task { await customSystemConfig.close() } }
        #expect(customSpawner.specs.isEmpty)

        // 7. Non-macOS platform never runs `plutil` and keeps a clean no-op.
        let linuxConfig = await CoreConfig.Service(
            directory: projectDir,
            options: CoreConfig.Options(project: true, global: true, system: .enabled, claude: false),
            globalPaths: makeGlobal(root: root),
            fileSystem: fs,
            environment: env,
            platform: .linux,
            processes: AppProcess.Service(spawner: customSpawner)
        )
        defer { Task { await linuxConfig.close() } }
        #expect(customSpawner.specs.isEmpty)

        // 8. Failing `plutil` (non-zero exit) degrades gracefully without throwing or dropping other config layers.
        let failingSpawner = FakeProcessSpawner { _ in
            ProcessOutput(exitCode: 1, stdout: [], stderr: Array("corrupt plist".utf8))
        }
        let failSafeConfig = await CoreConfig.Service(
            directory: projectDir,
            options: CoreConfig.Options(project: true, global: true, system: .enabled, claude: false),
            globalPaths: makeGlobal(root: root),
            fileSystem: fs,
            environment: env,
            platform: .macOS,
            processes: AppProcess.Service(spawner: failingSpawner)
        )
        defer { Task { await failSafeConfig.close() } }
        #expect(failingSpawner.specs.count == 1)
        #expect(CoreConfig.latest(await failSafeConfig.entries(), \.shell) == "/bin/system")
    }

    // MARK: - 5. macOS-Guarded Live `plutil` Test

    #if os(macOS)
    @Test("Live macOS plutil parses a real binary MDM plist through CrossSpawnSpawner.HostProcessSpawner")
    func macOSLivePlutilBinaryPlistConversion() async throws {
        let tmpDir = "\(SystemEnvironment.shared.temporaryDirectory)/opencode-mdm-plutil-\(Flock.currentEpochMs())-\(OpenCodeUtil.uuid())"
        let xmlPlistPath = "\(tmpDir)/ai.opencode.managed.plist"
        defer {
            Task { try? await LocalFileSystem.shared.remove(at: tmpDir) }
        }

        let xmlPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>PayloadDisplayName</key>
          <string>OpenCode MDM Profile</string>
          <key>PayloadIdentifier</key>
          <string>ai.opencode.managed</string>
          <key>PayloadType</key>
          <string>ai.opencode.managed</string>
          <key>PayloadUUID</key>
          <string>11111111-2222-3333-4444-555555555555</string>
          <key>PayloadVersion</key>
          <integer>1</integer>
          <key>_manualProfile</key>
          <true/>
          <key>shell</key>
          <string>/bin/real-plutil-zsh</string>
          <key>share</key>
          <string>disabled</string>
          <key>policies</key>
          <array>
            <dict>
              <key>action</key>
              <string>tool.use</string>
              <key>resource</key>
              <string>shell:sudo*</string>
              <key>effect</key>
              <string>deny</string>
            </dict>
          </array>
        </dict>
        </plist>
        """
        try await LocalFileSystem.shared.writeFile(Array(xmlPlist.utf8), to: xmlPlistPath, createDirectories: true)

        // Convert the XML plist on disk to Apple binary1 format using real `plutil` so we test binary plist decoding too.
        let convertRes = try await CrossSpawnSpawner.HostProcessSpawner.shared.run(
            ProcessSpec(executable: "plutil", arguments: ["-convert", "binary1", xmlPlistPath])
        )
        #expect(convertRes.exitCode == 0)

        let root = "/live-mdm-mac"
        let projectDir = "\(root)/home/repo"
        let virtualManagedPlist = "/Library/Managed Preferences/alice/ai.opencode.managed.plist"
        let fs = InMemoryFileSystem(initialFiles: [
            virtualManagedPlist: Array("redirected-to-real-binary-plist".utf8),
            "\(projectDir)/opencode.json": Array("""
            {
              "shell": "/bin/project",
              "policies": [{ "action": "tool.use", "resource": "shell:sudo*", "effect": "allow" }]
            }
            """.utf8),
        ])
        try await fs.makeDirectory(at: "\(root)/global", recursive: true)
        try await fs.makeDirectory(at: projectDir, recursive: true)

        // Verify the exact arguments CoreConfig passes, redirect only the root-owned path to our temp binary plist,
        // and execute REAL macOS `/usr/bin/plutil` via `CrossSpawnSpawner.HostProcessSpawner.shared`.
        let seenSpecs = Mutex<[ProcessSpec]>([])
        let liveRedirectSpawner = FakeProcessSpawner { spec in
            seenSpecs.withLock { $0.append(spec) }
            let redirectedArgs = spec.arguments.map { $0 == virtualManagedPlist ? xmlPlistPath : $0 }
            let liveSpec = ProcessSpec(
                executable: spec.executable,
                arguments: redirectedArgs,
                workingDirectory: spec.workingDirectory,
                environment: spec.environment,
                stdin: spec.stdin
            )
            return try await CrossSpawnSpawner.HostProcessSpawner.shared.run(liveSpec)
        }

        let config = await CoreConfig.Service(
            directory: projectDir,
            options: CoreConfig.Options(project: true, global: true, system: .enabled, claude: false),
            globalPaths: makeGlobal(root: root),
            fileSystem: fs,
            environment: DictionaryEnvironment(variables: ["USER": "alice"], homeDirectory: "\(root)/home", temporaryDirectory: "\(root)/tmp"),
            platform: .macOS,
            processes: AppProcess.Service(spawner: liveRedirectSpawner)
        )
        defer { Task { await config.close() } }

        let specs = seenSpecs.withLock { $0 }
        #expect(specs.count == 1)
        #expect(specs[0].executable == "plutil")
        #expect(specs[0].arguments == ["-convert", "json", "-o", "-", virtualManagedPlist])

        let entries = await config.entries()
        #expect(CoreConfig.latest(entries, \.shell) == "/bin/real-plutil-zsh")
        #expect(CoreConfig.latest(entries, \.share) == .disabled)
        let stmts = CoreManagedPolicy.statements(entries)
        #expect(CoreManagedPolicy.decision(stmts, action: .toolUse, resource: "shell:sudo rm") == .deny)
    }
    #endif

    // MARK: - 6. Close Cancels Timers & Bus Subscriptions

    @Test("close() cancels both the periodic 10-minute WellKnown refresh timer, pending debounce timer, and bus subscriptions")
    func closeCancelsAllTimersAndSubscriptions() async throws {
        let root = "/close-timers"
        let globalDir = "\(root)/global"
        let projectDir = "\(root)/home/repo"
        let projectFile = "\(projectDir)/opencode.json"
        let origin = "https://close.acme.test"
        let wellKnownID = IntegrationID(rawValue: origin)

        let fs = InMemoryFileSystem(initialFiles: [
            projectFile: Array("{\"shell\":\"/bin/initial\"}".utf8),
        ])
        try await fs.makeDirectory(at: globalDir, recursive: true)
        try await fs.makeDirectory(at: projectDir, recursive: true)

        let transport = MockHTTPTransport { req in
            if req.url == "\(origin)/.well-known/opencode" {
                return HTTPResponse(
                    head: HTTPResponseHead(statusCode: 200),
                    body: Array("""
                    {
                      "auth": { "command": ["login"], "env": "TOKEN" },
                      "config": { "username": "from-wk" }
                    }
                    """.utf8)
                )
            }
            return HTTPResponse(head: HTTPResponseHead(statusCode: 404), body: [])
        }

        let bus = try makeBus()
        let kv = try CoreKV.Service.inMemory()
        let credentials = try CoreProvider.Credential.Service.inMemory(bus: bus)
        let wellKnown = CoreIntegration.WellKnown.Service(transport: transport, kv: kv, bus: bus)
        _ = try await wellKnown.add(origin: origin)
        _ = try await credentials.create(
            integrationID: wellKnownID,
            value: .key(CredentialSchema.Key(key: "tok-1")),
            label: "Primary"
        )

        let clock = ManualClock()
        let watcher = CoreFilesystem.Watcher.Service(
            enabled: true,
            native: CoreFilesystem.Watcher.inMemoryNative(fileSystem: fs)
        )
        defer { Task { await watcher.close() } }

        let config = await CoreConfig.Service(
            directory: projectDir,
            options: CoreConfig.Options(project: true, global: true, system: .disabled, claude: false),
            globalPaths: makeGlobal(root: root),
            fileSystem: fs,
            watcher: watcher,
            bus: bus,
            credentials: credentials,
            wellKnown: wellKnown,
            debounce: .milliseconds(100),
            clock: clock
        )

        #expect(config.isWellKnownRefreshTimerActive)
        // Wait for the 10-minute WellKnown refresh timer AND initial readiness debounce timer to park in ManualClock.
        #expect(await waitUntil { clock.pendingSleeperCount >= 1 })
        // Trigger a config edit so a debounce sleeper is definitely parked alongside the 10-minute timer.
        try await fs.writeFile(Array("{\"shell\":\"/bin/pending\"}".utf8), to: projectFile, createDirectories: false)
        #expect(await waitUntil { clock.pendingSleeperCount >= 2 })

        let requestsBeforeClose = transport.requests.count
        let reloadsBeforeClose = config.reloadCount

        // Close must cancel all timers, watches, and bus subscriptions immediately.
        await config.close()
        #expect(!config.isWellKnownRefreshTimerActive)
        #expect(config.activeWatchCount == 0)
        #expect(config.activeBackgroundTaskCount == 0)
        #expect(await waitUntil { clock.pendingSleeperCount == 0 })
        #expect(clock.cancelledCount >= 2)

        // Advancing virtual time by 60 minutes after close must perform ZERO refreshes or reloads.
        clock.advance(by: .seconds(3600))
        // Triggering credential switch and well-known updates after close must perform ZERO reloads.
        _ = try await credentials.create(
            integrationID: wellKnownID,
            value: .key(CredentialSchema.Key(key: "tok-2")),
            label: "PostClose"
        )
        try? await Task.sleep(for: .milliseconds(40))
        #expect(transport.requests.count == requestsBeforeClose)
        #expect(config.reloadCount == reloadsBeforeClose)
    }

    // MARK: - 7. CoreConfig.configured Layer Graph Wiring

    @Test("CoreConfig.configured layer graph resolves credentials, wellKnown, bus, and cleans up on scope close")
    func coreConfigConfiguredLayerWiring() async throws {
        let root = "/layer-cfg"
        let globalDir = "\(root)/global"
        let projectDir = "\(root)/home/repo"
        let origin = "https://layer.acme.test"
        let wellKnownID = IntegrationID(rawValue: origin)

        let fs = InMemoryFileSystem()
        try await fs.makeDirectory(at: globalDir, recursive: true)
        try await fs.makeDirectory(at: projectDir, recursive: true)

        let transport = MockHTTPTransport { req in
            if req.url == "\(origin)/.well-known/opencode" {
                return HTTPResponse(
                    head: HTTPResponseHead(statusCode: 200),
                    body: Array("""
                    {
                      "auth": { "command": ["login"], "env": "TOKEN" },
                      "config": { "username": "layer-wk-user" }
                    }
                    """.utf8)
                )
            }
            return HTTPResponse(head: HTTPResponseHead(statusCode: 404), body: [])
        }

        let bus = try makeBus()
        let kv = try CoreKV.Service.inMemory()
        let credentials = try CoreProvider.Credential.Service.inMemory(bus: bus)
        let wellKnown = CoreIntegration.WellKnown.Service(transport: transport, kv: kv, bus: bus)
        _ = try await wellKnown.add(origin: origin)
        _ = try await credentials.create(
            integrationID: wellKnownID,
            value: .key(CredentialSchema.Key(key: "layer-tok")),
            label: "Layer"
        )

        let locInfo = LocationSchema.Info(
            directory: SchemaPrimitive.AbsolutePath(rawValue: projectDir),
            project: LocationSchema.ProjectRef(
                id: ProjectID.global,
                directory: SchemaPrimitive.AbsolutePath(rawValue: projectDir),
                canonical: SchemaPrimitive.AbsolutePath(rawValue: projectDir)
            )
        )
        let scope = LayerNode.ResourceScope()
        let plan = try LayerNode.compile(
            LayerNode.group([
                CoreConfig.configured(CoreConfig.Options(project: true, global: true, system: .disabled, claude: false)),
            ]),
            options: LayerNode.CompileOptions(replacements: [
                FSUtil.node.replace(with: LayerNode.ExecutableLayer { _, _ in
                    LayerNode.Output([FSUtil.Service.serviceKey: FSUtil.Service(fileSystem: fs)])
                }),
                Global.node.replace(with: LayerNode.ExecutableLayer { _, _ in
                    LayerNode.Output([Global.Service.serviceKey: Global.Service(makeGlobal(root: root))])
                }),
                CoreLocation.Location.node.replace(with: LayerNode.ExecutableLayer { _, _ in
                    LayerNode.Output([CoreLocation.Location.Service.serviceKey: CoreLocation.Location.Service(info: locInfo)])
                }),
                CoreFilesystem.Watcher.node.replace(with: LayerNode.ExecutableLayer { _, _ in
                    LayerNode.Output([CoreFilesystem.Watcher.Service.serviceKey: CoreFilesystem.Watcher.Service(enabled: false) as any CoreFilesystem.Watcher.Interface])
                }),
                CoreBus.node.replace(with: LayerNode.ExecutableLayer { _, _ in
                    LayerNode.Output([CoreBus.Service.serviceKey: bus as any CoreBus.Interface])
                }),
                CoreProvider.Credential.node.replace(with: LayerNode.ExecutableLayer { _, _ in
                    LayerNode.Output([CoreProvider.Credential.Service.serviceKey: credentials as any CoreProvider.Credential.Interface])
                }),
                CoreIntegration.WellKnown.node.replace(with: LayerNode.ExecutableLayer { _, _ in
                    LayerNode.Output([CoreIntegration.WellKnown.Service.serviceKey: wellKnown as any CoreIntegration.WellKnown.Interface])
                }),
            ])
        )
        let compiled = try await plan.build(scope: scope)

        let config = try #require(compiled.get(CoreConfig.Service.serviceKey, as: (any CoreConfig.Interface).self))
        #expect(CoreConfig.latest(await config.entries(), \.username) == "layer-wk-user")

        await scope.close()
        if let concrete = config as? CoreConfig.Service {
            #expect(!concrete.isWellKnownRefreshTimerActive)
            #expect(concrete.activeBackgroundTaskCount == 0)
        }
    }
}
