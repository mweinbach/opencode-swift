#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeUtil

/// Internal non-shadowed bridge for top-level `DebugHeapDumpOutput` inside `EffectClient.API`.
public typealias ClientDebugHeapDumpOutput = DebugHeapDumpOutput

/// Effect-layer client surface mirroring `packages/client/src/effect/*`.
/// Provides structured async/await service bindings, typed RPC with schema decoding,
/// multiplexed event streaming, and local service discovery (including `incumbent`).
public enum EffectClient {

    // MARK: - Effect ClientError (packages/client/src/effect/generated/client-error.ts)

    /// Tagged client error wrapping transport or streaming failures from the Effect client layer.
    // parity: client/src/effect/generated/client-error.ts#ClientError [status=implemented hash=449676285212]
    public struct ClientError: Error, Sendable, CustomStringConvertible {
        public static let tag = "ClientError"
        public let cause: any Error & Sendable

        public init(cause: any Error & Sendable) {
            self.cause = cause
        }

        public var description: String {
            "ClientError: \(cause)"
        }
    }

    // MARK: - Effect RPC Client (packages/client/src/effect/rpc.ts)

    /// Events interface on an Effect RPC client decoding `rpc.<id>.<name>` events via `RpcRuntime.event`.
    public struct RpcEvents: Sendable {
        private let definition: RpcSchema.Definition
        private let subscribeAll: @Sendable () -> AsyncThrowingStream<OpenCodeEvent, any Error>

        public init(
            definition: RpcSchema.Definition,
            subscribeAll: @escaping @Sendable () -> AsyncThrowingStream<OpenCodeEvent, any Error>
        ) {
            self.definition = definition
            self.subscribeAll = subscribeAll
        }

        public func subscribe(_ name: String) -> AsyncThrowingStream<RpcDecodedEvent, any Error> {
            let targetType = RpcRuntime.eventType(definition: definition, name: name)
            guard let schema = definition.events[name] else {
                return AsyncThrowingStream { continuation in
                    continuation.finish(throwing: ServiceLifecycleError("Unknown RPC event: \(targetType)"))
                }
            }
            let def = definition
            let source = subscribeAll
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        for try await event in source() {
                            if Task.isCancelled { break }
                            guard event.type == targetType else { continue }
                            let decoded = try RpcRuntime.event(
                                definition: def,
                                name: name,
                                schema: schema,
                                event: event
                            )
                            continuation.yield(decoded)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in
                    task.cancel()
                }
            }
        }
    }

    /// Bound Effect-style RPC client for one `RpcSchema.Definition`.
    // parity: client/src/effect/rpc.ts#RpcClient [status=implemented hash=58e25d241b82]
    public struct RpcClient: Sendable {
        public let definition: RpcSchema.Definition
        public let events: RpcEvents
        private let invoker: @Sendable (String, JSONValue?, RpcCallOptions?) async throws -> JSONValue

        public init(
            definition: RpcSchema.Definition,
            events: RpcEvents,
            invoker: @escaping @Sendable (String, JSONValue?, RpcCallOptions?) async throws -> JSONValue
        ) {
            self.definition = definition
            self.events = events
            self.invoker = invoker
        }

        public func call(
            _ method: String,
            input: JSONValue? = nil,
            options: RpcCallOptions? = nil
        ) async throws -> JSONValue {
            try await invoker(method, input, options)
        }
    }

    /// Callable factory producing an `EffectClient.RpcClient` for a given `RpcSchema.Definition`.
    // parity: client/src/effect/rpc.ts#RpcApi [status=implemented hash=9266b3e88242]
    public struct RpcApi: Sendable {
        private let build: @Sendable (RpcSchema.Definition) -> RpcClient

        public init(_ build: @escaping @Sendable (RpcSchema.Definition) -> RpcClient) {
            self.build = build
        }

        public func callAsFunction(_ definition: RpcSchema.Definition) -> RpcClient {
            build(definition)
        }
    }

    /// Runtime helpers for `EffectClient.RpcApi` mirroring `packages/client/src/effect/rpc.ts`.
    public enum RpcClientRuntime {
        /// Suspends until `signal` aborts (returns immediately if already aborted).
        // parity: client/src/effect/rpc.ts#aborted [status=implemented hash=28f1c7f17da3]
        public static func aborted(_ signal: AbortSignal) async {
            if signal.isAborted { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumed = AtomicResumeGuard()
                let cleanup = signal.onAbort {
                    if resumed.claim() {
                        continuation.resume()
                    }
                }
                if signal.isAborted {
                    cleanup()
                    if resumed.claim() {
                        continuation.resume()
                    }
                }
            }
        }

        /// Builds an `EffectClient.RpcApi` using `RpcRuntime.read`, `RpcRuntime.readError`,
        /// `RpcRuntime.event`, and cooperative `AbortSignal` interruption.
        // parity: client/src/effect/rpc.ts#make [status=implemented hash=538282acde5f]
        public static func make(
            call: @escaping @Sendable (RpcCallInput, RpcCallOptions?) async throws -> RpcCallOutput,
            subscribe: @escaping @Sendable () -> AsyncThrowingStream<OpenCodeEvent, any Error>
        ) -> RpcApi {
            RpcApi { definition in
                let events = RpcEvents(definition: definition, subscribeAll: subscribe)
                return RpcClient(definition: definition, events: events) { methodName, input, options in
                    guard let method = definition.methods[methodName] else {
                        throw RpcMethodErrorPayload(
                            type: "rpc.method_not_found",
                            message: "Unknown RPC method: \(definition.id).\(methodName)"
                        )
                    }
                    let executeCall: @Sendable () async throws -> JSONValue = {
                        do {
                            let response = try await call(
                                RpcCallInput(
                                    rpcID: definition.id,
                                    method: methodName,
                                    location: options?.location,
                                    input: input
                                ),
                                options
                            )
                            return try RpcRuntime.read(schema: method.output, value: response.output)
                        } catch {
                            throw RpcRuntime.readError(method: method, error: error)
                        }
                    }

                    guard let signal = options?.signal else {
                        return try await executeCall()
                    }
                    if signal.isAborted {
                        throw CancellationError()
                    }
                    return try await withThrowingTaskGroup(of: JSONValue.self) { group in
                        group.addTask {
                            try await executeCall()
                        }
                        group.addTask {
                            await aborted(signal)
                            throw CancellationError()
                        }
                        guard let value = try await group.next() else {
                            throw CancellationError()
                        }
                        group.cancelAll()
                        return value
                    }
                }
            }
        }
    }

    // MARK: - Effect Generated & Composed Clients (packages/client/src/effect/{generated/client,client,index}.ts)

    /// Event subscription API on `EffectClient.OpenCodeClient` matching `effect/client.ts`.
    public struct EffectEventAPI: Sendable {
        private let shared: SharedEventsHub<OpenCodeEvent>

        public init(shared: SharedEventsHub<OpenCodeEvent>) {
            self.shared = shared
        }

        public func subscribe(_ input: EventSubscribeInput? = nil) -> AsyncThrowingStream<OpenCodeEvent, any Error> {
            let source = shared.subscribe(SubscribeOptions(types: input?.types))
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        for try await event in source {
                            if Task.isCancelled { break }
                            continuation.yield(event)
                        }
                        continuation.finish()
                    } catch let err as ClientError {
                        continuation.finish(throwing: err)
                    } catch {
                        continuation.finish(throwing: ClientError(cause: error))
                    }
                }
                continuation.onTermination = { _ in
                    task.cancel()
                }
            }
        }
    }

    /// Composed `rpc` namespace supporting both raw `rpc.call(...)` and typed `rpc(definition)`.
    public struct EffectRpcSurface: Sendable {
        private let raw: RpcClientAPI
        private let builder: RpcApi

        public init(raw: RpcClientAPI, builder: RpcApi) {
            self.raw = raw
            self.builder = builder
        }

        public func call(_ input: RpcCallInput, options: RequestOptions? = nil) async throws -> RpcCallOutput {
            try await raw.call(input, options: options)
        }

        public func callAsFunction(_ definition: RpcSchema.Definition) -> RpcClient {
            builder(definition)
        }
    }

    /// Raw generated Effect client backed by `OpenCodeProtocol.ClientApi` and `OpenCodePlatform.HTTPTransport`.
    public struct GeneratedClient: Sendable {
        public static let omittedEndpoints: Set<String> = OpenCodeProtocol.effectOmitEndpoints

        public let raw: GeneratedOpenCodeClient
        public let server: ServerClientAPI
        public let location: LocationClientAPI
        public let agent: AgentClientAPI
        public let plugin: PluginClientAPI
        public let session: SessionClientAPI
        public let experimental: ExperimentalClientAPI
        public let message: MessageClientAPI
        public let model: ModelClientAPI
        public let provider: ProviderClientAPI
        public let integration: IntegrationClientAPI
        public let mcp: McpClientAPI
        public let credential: CredentialClientAPI
        public let project: ProjectClientAPI
        public let form: FormClientAPI
        public let permission: PermissionClientAPI
        public let file: FileClientAPI
        public let command: CommandClientAPI
        public let skill: SkillClientAPI
        public let rpc: RpcClientAPI
        public let event: EventClientAPI
        public let pty: PtyClientAPI
        public let shell: ShellClientAPI
        public let reference: ReferenceClientAPI
        public let worktree: WorktreeClientAPI
        public let vcs: VcsClientAPI
        public let debug: DebugClientAPI
        public let websearch: WebsearchClientAPI
        public let config: ConfigClientAPI
        public let generate: DeprecatedGenerateClientAPI
        public let voice: ExperimentalVoiceClientAPI
        public let migration: ExperimentalMigrationClientAPI
        public let usage: ExperimentalUsageClientAPI

        public init(options: ClientOptions) {
            let raw = GeneratedOpenCodeClient(options: options)
            self.raw = raw
            self.server = raw.server
            self.location = raw.location
            self.agent = raw.agent
            self.plugin = raw.plugin
            self.session = raw.session
            self.experimental = raw.experimental
            self.message = raw.message
            self.model = raw.model
            self.provider = raw.provider
            self.integration = raw.integration
            self.mcp = raw.mcp
            self.credential = raw.credential
            self.project = raw.project
            self.form = raw.form
            self.permission = raw.permission
            self.file = raw.file
            self.command = raw.command
            self.skill = raw.skill
            self.rpc = raw.rpc
            self.event = raw.event
            self.pty = raw.pty
            self.shell = raw.shell
            self.reference = raw.reference
            self.worktree = raw.worktree
            self.vcs = raw.vcs
            self.debug = raw.debug
            self.websearch = raw.websearch
            self.config = raw.config
            self.generate = raw.generate
            self.voice = raw.voice
            self.migration = raw.migration
            self.usage = raw.usage
        }
    }

    public enum Generated {
        /// Builds the raw generated Effect-layer HTTP/SSE client matching `effect/generated/client.ts#make`.
        // parity: client/src/effect/generated/client.ts#make [status=adapted hash=77f777457b3c]
        public static func make(_ options: ClientOptions) -> GeneratedClient {
            GeneratedClient(options: options)
        }
    }

    /// Composed Effect-layer OpenCode client with shared event multiplexing and typed Effect RPC.
    // parity: client/src/effect/index.ts#OpenCodeClient [status=implemented hash=a0a2ba37b35a]
    public struct OpenCodeClient: Sendable {
        public let raw: GeneratedClient
        public let server: ServerClientAPI
        public let location: LocationClientAPI
        public let agent: AgentClientAPI
        public let plugin: PluginClientAPI
        public let session: SessionClientAPI
        public let experimental: ExperimentalClientAPI
        public let message: MessageClientAPI
        public let model: ModelClientAPI
        public let provider: ProviderClientAPI
        public let integration: IntegrationClientAPI
        public let mcp: McpClientAPI
        public let credential: CredentialClientAPI
        public let project: ProjectClientAPI
        public let form: FormClientAPI
        public let permission: PermissionClientAPI
        public let file: FileClientAPI
        public let command: CommandClientAPI
        public let skill: SkillClientAPI
        public let rpc: EffectRpcSurface
        public let event: EffectEventAPI
        public let pty: PtyClientAPI
        public let shell: ShellClientAPI
        public let reference: ReferenceClientAPI
        public let worktree: WorktreeClientAPI
        public let vcs: VcsClientAPI
        public let debug: DebugClientAPI
        public let websearch: WebsearchClientAPI
        public let config: ConfigClientAPI
        public let generate: DeprecatedGenerateClientAPI
        public let voice: ExperimentalVoiceClientAPI
        public let migration: ExperimentalMigrationClientAPI
        public let usage: ExperimentalUsageClientAPI

        public init(options: ClientOptions) {
            let raw = Generated.make(options)
            let shared = SharedEvents.make { signal, onActivity in
                raw.event.subscribe(nil, options: RequestOptions(signal: signal, onActivity: onActivity))
            }
            let eventApi = EffectEventAPI(shared: shared)
            let rpcBuilder = RpcClientRuntime.make(
                call: { input, callOptions in
                    try await raw.rpc.call(
                        input,
                        options: RequestOptions(signal: callOptions?.signal, headers: callOptions?.headers)
                    )
                },
                subscribe: {
                    eventApi.subscribe(nil)
                }
            )
            self.raw = raw
            self.server = raw.server
            self.location = raw.location
            self.agent = raw.agent
            self.plugin = raw.plugin
            self.session = raw.session
            self.experimental = raw.experimental
            self.message = raw.message
            self.model = raw.model
            self.provider = raw.provider
            self.integration = raw.integration
            self.mcp = raw.mcp
            self.credential = raw.credential
            self.project = raw.project
            self.form = raw.form
            self.permission = raw.permission
            self.file = raw.file
            self.command = raw.command
            self.skill = raw.skill
            self.rpc = EffectRpcSurface(raw: raw.rpc, builder: rpcBuilder)
            self.event = eventApi
            self.pty = raw.pty
            self.shell = raw.shell
            self.reference = raw.reference
            self.worktree = raw.worktree
            self.vcs = raw.vcs
            self.debug = raw.debug
            self.websearch = raw.websearch
            self.config = raw.config
            self.generate = raw.generate
            self.voice = raw.voice
            self.migration = raw.migration
            self.usage = raw.usage
        }
    }

    public enum OpenCode {
        /// Creates an `EffectClient.OpenCodeClient` matching `packages/client/src/effect/client.ts#make`.
        // parity: client/src/effect/client.ts#make [status=adapted hash=ca04470d19e6]
        public static func make(_ options: ClientOptions) -> OpenCodeClient {
            OpenCodeClient(options: options)
        }
    }

    // MARK: - Effect Service Lifecycle (packages/client/src/effect/service.ts)

    /// Result returned by `EffectClient.Service.incumbent`.
    public struct IncumbentResult: Equatable, Hashable, Sendable {
        public let endpoint: ServiceEndpoint
        public let state: LocalServiceState

        public init(endpoint: ServiceEndpoint, state: LocalServiceState) {
            self.endpoint = endpoint
            self.state = state
        }
    }

    /// Effect-style local service discovery and lifecycle operations mirroring `packages/client/src/effect/service.ts`.
    public enum Service {
        /// Local service registration record (`pid > 0`).
        // parity: client/src/effect/service.ts#Info [status=implemented hash=a64c8fb3a1eb]
        public typealias Info = ServiceInfo

        /// Create HTTP authentication headers for a service endpoint (re-exported from `service-probe.ts`).
        // parity: client/src/effect/service.ts#headers [status=implemented hash=74ec8bd923db]
        public static func headers(for endpoint: ServiceEndpoint) -> [String: String]? {
            serviceProbeHeaders(for: endpoint)
        }

        /// Discover a healthy, compatible local service without starting one.
        // parity: client/src/effect/service.ts#discover [status=implemented hash=f895b29d90fa]
        public static func discover(
            options: ServiceDiscoverOptions = ServiceDiscoverOptions(),
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
            transport: any HTTPTransport,
            environment: any EnvironmentProviding = SystemEnvironment.shared
        ) async -> ServiceEndpoint? {
            await PromiseService.discover(
                options: options,
                fileSystem: fileSystem,
                transport: transport,
                environment: environment
            )
        }

        /// Recognize an authenticated compatible service bound to an expected URL, including while it starts or fails.
        // parity: client/src/effect/service.ts#incumbent [status=implemented hash=e773f07a053b]
        public static func incumbent(
            url: String,
            options: ServiceDiscoverOptions = ServiceDiscoverOptions(),
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
            transport: any HTTPTransport,
            environment: any EnvironmentProviding = SystemEnvironment.shared
        ) async -> IncumbentResult? {
            let resolvedFile = options.file ?? fallback(environment: environment)
            guard let info = await PromiseService.readInfo(file: resolvedFile, fileSystem: fileSystem) else {
                return nil
            }
            let overrideInfo = ServiceInfo(
                id: info.id,
                version: info.version,
                url: url,
                pid: info.pid,
                password: info.password
            )
            let probed = await probeResult(overrideInfo, transport: transport)
            guard let found = probed.service, found.compatible else { return nil }
            guard matchesVersion(found.version, options: options) else { return nil }
            return IncumbentResult(endpoint: found.endpoint, state: found.state)
        }

        /// Ensure a healthy, compatible local service is running.
        // parity: client/src/effect/service.ts#ensure [status=implemented hash=420cf6a53579]
        public static func ensure(
            options: ServiceEnsureOptions = ServiceEnsureOptions(),
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
            transport: any HTTPTransport,
            launcher: any ServiceProcessLauncher,
            signaler: any ServiceProcessSignaler,
            environment: any EnvironmentProviding = SystemEnvironment.shared,
            now: @escaping @Sendable () -> Int64 = { ClientClock.nowEpochMs() }
        ) async throws -> ServiceEndpoint {
            try await PromiseService.ensure(
                options: options,
                fileSystem: fileSystem,
                transport: transport,
                launcher: launcher,
                signaler: signaler,
                environment: environment,
                now: now
            )
        }

        /// Stop the registered local service.
        // parity: client/src/effect/service.ts#stop [status=implemented hash=aa7d39dc91e7]
        public static func stop(
            options: ServiceStopOptions = ServiceStopOptions(),
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
            transport: any HTTPTransport,
            signaler: any ServiceProcessSignaler,
            environment: any EnvironmentProviding = SystemEnvironment.shared,
            now: @escaping @Sendable () -> Int64 = { ClientClock.nowEpochMs() }
        ) async throws {
            try await PromiseService.stop(
                options: options,
                fileSystem: fileSystem,
                transport: transport,
                signaler: signaler,
                environment: environment,
                now: now
            )
        }

        /// Grouped Effect service namespace matching `export const Service = { discover, incumbent, ensure, stop, headers, Info }`.
        // parity: client/src/effect/service.ts#Service [status=implemented hash=aa61aa3ee3e5]
        public static let Service = EffectClient.Service.self
    }

    // MARK: - Effect API Type Surface (packages/client/src/effect/{api.ts, api/api.ts} — 597 symbols)

    public enum API {
        // parity: client/src/effect/api.ts#WebSearchApi [status=implemented hash=eb1775995994]
        public typealias WebSearchApi = WebsearchApi

        // parity: client/src/effect/api/api.ts#ServerInfoOutput [status=implemented hash=fe5613d8bda4]
        public typealias ServerInfoOutput = OpenCodeProtocol.ServerInfo
        // parity: client/src/effect/api/api.ts#ServerInfoOperation [status=implemented hash=ab2c26397553]
        public typealias ServerInfoOperation = @Sendable () async throws -> ServerInfoOutput
        // parity: client/src/effect/api/api.ts#ServerPairOutput [status=implemented hash=03911723367e]
        public typealias ServerPairOutput = OpenCodeProtocol.PairingCode
        // parity: client/src/effect/api/api.ts#ServerPairOperation [status=implemented hash=5d5e134f7441]
        public typealias ServerPairOperation = @Sendable () async throws -> ServerPairOutput
        // parity: client/src/effect/api/api.ts#ServerConnectInput [status=implemented hash=35b353992fd9]
        public typealias ServerConnectInput = PromiseInputTypes.ServerConnectInput
        // parity: client/src/effect/api/api.ts#ServerConnectOutput [status=implemented hash=2aa562453b1f]
        public typealias ServerConnectOutput = OpenCodeProtocol.PairingSession
        // parity: client/src/effect/api/api.ts#ServerConnectOperation [status=implemented hash=b50fb8df3761]
        public typealias ServerConnectOperation = @Sendable (ServerConnectInput) async throws -> ServerConnectOutput
        // parity: client/src/effect/api/api.ts#ServerApi [status=implemented hash=41cc36859c8d]
        public typealias ServerApi = ServerClientAPI
        // parity: client/src/effect/api/api.ts#LocationGetInput [status=implemented hash=fa1d60fb917a]
        public typealias LocationGetInput = PromiseInputTypes.LocationGetInput
        // parity: client/src/effect/api/api.ts#LocationGetOutput [status=implemented hash=01c908080cb5]
        public typealias LocationGetOutput = LocationSchema.PublicInfo
        // parity: client/src/effect/api/api.ts#LocationGetOperation [status=implemented hash=b342e5f05dc0]
        public typealias LocationGetOperation = @Sendable (LocationGetInput?) async throws -> LocationGetOutput
        // parity: client/src/effect/api/api.ts#LocationReloadOutput [status=implemented hash=eac2db1bde1e]
        public typealias LocationReloadOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#LocationReloadOperation [status=implemented hash=af3f6c8f7dfb]
        public typealias LocationReloadOperation = @Sendable () async throws -> LocationReloadOutput
        // parity: client/src/effect/api/api.ts#LocationApi [status=implemented hash=bad01f4e239d]
        public typealias LocationApi = LocationClientAPI
        // parity: client/src/effect/api/api.ts#AgentListInput [status=implemented hash=96f8ed742110]
        public typealias AgentListInput = PromiseInputTypes.AgentListInput
        // parity: client/src/effect/api/api.ts#AgentListOutput [status=implemented hash=a49474bbb909]
        public typealias AgentListOutput = LocationSchema.ResponseEnvelope<[AgentSchema.Info]>
        // parity: client/src/effect/api/api.ts#AgentListOperation [status=implemented hash=b86c1ea7f75e]
        public typealias AgentListOperation = @Sendable (AgentListInput?) async throws -> AgentListOutput
        // parity: client/src/effect/api/api.ts#AgentGetInput [status=implemented hash=4624fb046d6f]
        public typealias AgentGetInput = PromiseInputTypes.AgentGetInput
        // parity: client/src/effect/api/api.ts#AgentGetOutput [status=implemented hash=ed084c073c5f]
        public typealias AgentGetOutput = LocationSchema.ResponseEnvelope<AgentSchema.Info>
        // parity: client/src/effect/api/api.ts#AgentGetOperation [status=implemented hash=77a72d1c2f0b]
        public typealias AgentGetOperation = @Sendable (AgentGetInput) async throws -> AgentGetOutput
        // parity: client/src/effect/api/api.ts#AgentApi [status=implemented hash=80b02bb69dbc]
        public typealias AgentApi = AgentClientAPI
        // parity: client/src/effect/api/api.ts#PluginListInput [status=implemented hash=2051bfeaadc8]
        public typealias PluginListInput = PromiseInputTypes.PluginListInput
        // parity: client/src/effect/api/api.ts#PluginListOutput [status=implemented hash=1668112fd9e7]
        public typealias PluginListOutput = LocationSchema.ResponseEnvelope<[PluginSchema.Info]>
        // parity: client/src/effect/api/api.ts#PluginListOperation [status=implemented hash=3729c167d843]
        public typealias PluginListOperation = @Sendable (PluginListInput?) async throws -> PluginListOutput
        // parity: client/src/effect/api/api.ts#PluginGuiInput [status=implemented hash=8918fd03bbaf]
        public typealias PluginGuiInput = PromiseInputTypes.PluginGuiInput
        // parity: client/src/effect/api/api.ts#PluginGuiOutput [status=implemented hash=1b24c23475b3]
        public typealias PluginGuiOutput = LocationSchema.ResponseEnvelope<PluginSchema.GuiBundle>
        // parity: client/src/effect/api/api.ts#PluginGuiOperation [status=implemented hash=fb7ec0f24abd]
        public typealias PluginGuiOperation = @Sendable (PluginGuiInput) async throws -> PluginGuiOutput
        // parity: client/src/effect/api/api.ts#PluginCheckInput [status=implemented hash=ce5a193c652a]
        public typealias PluginCheckInput = PromiseInputTypes.PluginCheckInput
        // parity: client/src/effect/api/api.ts#PluginCheckOutput [status=implemented hash=c3acb12ae19d]
        public typealias PluginCheckOutput = LocationSchema.ResponseEnvelope<[PluginSchema.Info]>
        // parity: client/src/effect/api/api.ts#PluginCheckOperation [status=implemented hash=37eb1857bfb7]
        public typealias PluginCheckOperation = @Sendable (PluginCheckInput?) async throws -> PluginCheckOutput
        // parity: client/src/effect/api/api.ts#PluginUpdateInput [status=implemented hash=324ec545abcc]
        public typealias PluginUpdateInput = PromiseInputTypes.PluginUpdateInput
        // parity: client/src/effect/api/api.ts#PluginUpdateOutput [status=implemented hash=6f940937aee3]
        public typealias PluginUpdateOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#PluginUpdateOperation [status=implemented hash=59b05bb451f3]
        public typealias PluginUpdateOperation = @Sendable (PluginUpdateInput) async throws -> PluginUpdateOutput
        // parity: client/src/effect/api/api.ts#PluginApi [status=implemented hash=b9fc79f43230]
        public typealias PluginApi = PluginClientAPI
        // parity: client/src/effect/api/api.ts#SessionListInput [status=implemented hash=271b2e2631f8]
        public typealias SessionListInput = PromiseInputTypes.SessionListInput
        // parity: client/src/effect/api/api.ts#SessionListOutput [status=implemented hash=114082d7c63e]
        public typealias SessionListOutput = SessionsResponse
        // parity: client/src/effect/api/api.ts#SessionListOperation [status=implemented hash=8eccd61703d6]
        public typealias SessionListOperation = @Sendable (SessionListInput?) async throws -> SessionListOutput
        // parity: client/src/effect/api/api.ts#SessionCreateInput [status=implemented hash=08c231bad164]
        public typealias SessionCreateInput = PromiseInputTypes.SessionCreateInput
        // parity: client/src/effect/api/api.ts#SessionCreateOutput [status=implemented hash=341d8c243100]
        public typealias SessionCreateOutput = SessionSchema.Info
        // parity: client/src/effect/api/api.ts#SessionCreateOperation [status=implemented hash=925f3203925b]
        public typealias SessionCreateOperation = @Sendable (SessionCreateInput?) async throws -> SessionCreateOutput
        // parity: client/src/effect/api/api.ts#SessionActiveOutput [status=implemented hash=4e920d9778d7]
        public typealias SessionActiveOutput = [String: SessionActiveInfo]
        // parity: client/src/effect/api/api.ts#SessionActiveOperation [status=implemented hash=83f279af33cd]
        public typealias SessionActiveOperation = @Sendable () async throws -> SessionActiveOutput
        // parity: client/src/effect/api/api.ts#SessionGetInput [status=implemented hash=de4aecec059b]
        public typealias SessionGetInput = PromiseInputTypes.SessionGetInput
        // parity: client/src/effect/api/api.ts#SessionGetOutput [status=implemented hash=ed495f924a20]
        public typealias SessionGetOutput = SessionSchema.Info
        // parity: client/src/effect/api/api.ts#SessionGetOperation [status=implemented hash=0869ec8d42cc]
        public typealias SessionGetOperation = @Sendable (SessionGetInput) async throws -> SessionGetOutput
        // parity: client/src/effect/api/api.ts#SessionRemoveInput [status=implemented hash=1a34134570d3]
        public typealias SessionRemoveInput = PromiseInputTypes.SessionRemoveInput
        // parity: client/src/effect/api/api.ts#SessionRemoveOutput [status=implemented hash=8038c7096a55]
        public typealias SessionRemoveOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#SessionRemoveOperation [status=implemented hash=b243155786ac]
        public typealias SessionRemoveOperation = @Sendable (SessionRemoveInput) async throws -> SessionRemoveOutput
        // parity: client/src/effect/api/api.ts#SessionForkInput [status=implemented hash=f97aaa071fbc]
        public typealias SessionForkInput = PromiseInputTypes.SessionForkInput
        // parity: client/src/effect/api/api.ts#SessionForkOutput [status=implemented hash=c22c81332906]
        public typealias SessionForkOutput = SessionSchema.Info
        // parity: client/src/effect/api/api.ts#SessionForkOperation [status=implemented hash=c9d2ac5707f6]
        public typealias SessionForkOperation = @Sendable (SessionForkInput) async throws -> SessionForkOutput
        // parity: client/src/effect/api/api.ts#SessionSwitchAgentInput [status=implemented hash=2c7beeb97d72]
        public typealias SessionSwitchAgentInput = PromiseInputTypes.SessionSwitchAgentInput
        // parity: client/src/effect/api/api.ts#SessionSwitchAgentOutput [status=implemented hash=b21348f24be3]
        public typealias SessionSwitchAgentOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#SessionSwitchAgentOperation [status=implemented hash=d778f88eaf55]
        public typealias SessionSwitchAgentOperation = @Sendable (SessionSwitchAgentInput) async throws -> SessionSwitchAgentOutput
        // parity: client/src/effect/api/api.ts#SessionSwitchModelInput [status=implemented hash=0e15422d1144]
        public typealias SessionSwitchModelInput = PromiseInputTypes.SessionSwitchModelInput
        // parity: client/src/effect/api/api.ts#SessionSwitchModelOutput [status=implemented hash=f73e822e676a]
        public typealias SessionSwitchModelOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#SessionSwitchModelOperation [status=implemented hash=7f454e1ba547]
        public typealias SessionSwitchModelOperation = @Sendable (SessionSwitchModelInput) async throws -> SessionSwitchModelOutput
        // parity: client/src/effect/api/api.ts#SessionUpdateInput [status=implemented hash=89b23c3a7694]
        public typealias SessionUpdateInput = PromiseInputTypes.SessionUpdateInput
        // parity: client/src/effect/api/api.ts#SessionUpdateOutput [status=implemented hash=8e7a21586d2f]
        public typealias SessionUpdateOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#SessionUpdateOperation [status=implemented hash=363d1a62bbff]
        public typealias SessionUpdateOperation = @Sendable (SessionUpdateInput) async throws -> SessionUpdateOutput
        // parity: client/src/effect/api/api.ts#SessionMoveInput [status=implemented hash=22085fc6f381]
        public typealias SessionMoveInput = PromiseInputTypes.SessionMoveInput
        // parity: client/src/effect/api/api.ts#SessionMoveOutput [status=implemented hash=3e397844fd81]
        public typealias SessionMoveOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#SessionMoveOperation [status=implemented hash=1fff8a62efef]
        public typealias SessionMoveOperation = @Sendable (SessionMoveInput) async throws -> SessionMoveOutput
        // parity: client/src/effect/api/api.ts#SessionPromptInput [status=implemented hash=6bde88567995]
        public typealias SessionPromptInput = PromiseInputTypes.SessionPromptInput
        // parity: client/src/effect/api/api.ts#SessionPromptOutput [status=implemented hash=8ed0b447233f]
        public typealias SessionPromptOutput = SessionInboxSchema.User
        // parity: client/src/effect/api/api.ts#SessionPromptOperation [status=implemented hash=fdadeab39e47]
        public typealias SessionPromptOperation = @Sendable (SessionPromptInput) async throws -> SessionPromptOutput
        // parity: client/src/effect/api/api.ts#SessionCommandInput [status=implemented hash=0419ee8e84ab]
        public typealias SessionCommandInput = PromiseInputTypes.SessionCommandInput
        // parity: client/src/effect/api/api.ts#SessionCommandOutput [status=implemented hash=b64a45dfdb63]
        public typealias SessionCommandOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#SessionCommandOperation [status=implemented hash=6f173d16a6d1]
        public typealias SessionCommandOperation = @Sendable (SessionCommandInput) async throws -> SessionCommandOutput
        // parity: client/src/effect/api/api.ts#SessionSyntheticInput [status=implemented hash=4465f27a10a8]
        public typealias SessionSyntheticInput = PromiseInputTypes.SessionSyntheticInput
        // parity: client/src/effect/api/api.ts#SessionSyntheticOutput [status=implemented hash=2d84f00a2107]
        public typealias SessionSyntheticOutput = SessionInboxSchema.Synthetic
        // parity: client/src/effect/api/api.ts#SessionSyntheticOperation [status=implemented hash=0c25122e47e2]
        public typealias SessionSyntheticOperation = @Sendable (SessionSyntheticInput) async throws -> SessionSyntheticOutput
        // parity: client/src/effect/api/api.ts#SessionShellInput [status=implemented hash=4e5230202545]
        public typealias SessionShellInput = PromiseInputTypes.SessionShellInput
        // parity: client/src/effect/api/api.ts#SessionShellOutput [status=implemented hash=59b22dc80787]
        public typealias SessionShellOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#SessionShellOperation [status=implemented hash=f656fbb2e3c8]
        public typealias SessionShellOperation = @Sendable (SessionShellInput) async throws -> SessionShellOutput
        // parity: client/src/effect/api/api.ts#SessionCompactInput [status=implemented hash=b8021b459bf6]
        public typealias SessionCompactInput = PromiseInputTypes.SessionCompactInput
        // parity: client/src/effect/api/api.ts#SessionCompactOutput [status=implemented hash=e199fa1b50cf]
        public typealias SessionCompactOutput = SessionInboxSchema.Compaction
        // parity: client/src/effect/api/api.ts#SessionCompactOperation [status=implemented hash=742f61901ca4]
        public typealias SessionCompactOperation = @Sendable (SessionCompactInput) async throws -> SessionCompactOutput
        // parity: client/src/effect/api/api.ts#SessionRevertStageInput [status=implemented hash=c0bdfd4dc0ee]
        public typealias SessionRevertStageInput = PromiseInputTypes.SessionRevertStageInput
        // parity: client/src/effect/api/api.ts#SessionRevertStageOutput [status=implemented hash=3e0e61d7a86b]
        public typealias SessionRevertStageOutput = SessionRevertSchema.Revert
        // parity: client/src/effect/api/api.ts#SessionRevertStageOperation [status=implemented hash=334179aea026]
        public typealias SessionRevertStageOperation = @Sendable (SessionRevertStageInput) async throws -> SessionRevertStageOutput
        // parity: client/src/effect/api/api.ts#SessionRevertClearInput [status=implemented hash=0e5ee5adefc9]
        public typealias SessionRevertClearInput = PromiseInputTypes.SessionRevertClearInput
        // parity: client/src/effect/api/api.ts#SessionRevertClearOutput [status=implemented hash=4bfe23826bc6]
        public typealias SessionRevertClearOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#SessionRevertClearOperation [status=implemented hash=9f7244527aec]
        public typealias SessionRevertClearOperation = @Sendable (SessionRevertClearInput) async throws -> SessionRevertClearOutput
        // parity: client/src/effect/api/api.ts#SessionRevertCommitInput [status=implemented hash=109acec01e6a]
        public typealias SessionRevertCommitInput = PromiseInputTypes.SessionRevertCommitInput
        // parity: client/src/effect/api/api.ts#SessionRevertCommitOutput [status=implemented hash=e586e6dc58aa]
        public typealias SessionRevertCommitOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#SessionRevertCommitOperation [status=implemented hash=efc11671bf9a]
        public typealias SessionRevertCommitOperation = @Sendable (SessionRevertCommitInput) async throws -> SessionRevertCommitOutput
        // parity: client/src/effect/api/api.ts#SessionContextInput [status=implemented hash=46ffd32701f4]
        public typealias SessionContextInput = PromiseInputTypes.SessionContextInput
        // parity: client/src/effect/api/api.ts#SessionContextOutput [status=implemented hash=bd07d24d91d9]
        public typealias SessionContextOutput = [SessionMessageSchema.Info]
        // parity: client/src/effect/api/api.ts#SessionContextOperation [status=implemented hash=6576ca97c37d]
        public typealias SessionContextOperation = @Sendable (SessionContextInput) async throws -> SessionContextOutput
        // parity: client/src/effect/api/api.ts#SessionDiffInput [status=implemented hash=2d26cb276cf5]
        public typealias SessionDiffInput = PromiseInputTypes.SessionDiffInput
        // parity: client/src/effect/api/api.ts#SessionDiffOutput [status=implemented hash=064b6b90aa70]
        public typealias SessionDiffOutput = [FileDiffSchema.Info]
        // parity: client/src/effect/api/api.ts#SessionDiffOperation [status=implemented hash=98eccf7ff14b]
        public typealias SessionDiffOperation = @Sendable (SessionDiffInput) async throws -> SessionDiffOutput
        // parity: client/src/effect/api/api.ts#SessionInboxListInput [status=implemented hash=784e55ce5afa]
        public typealias SessionInboxListInput = PromiseInputTypes.SessionInboxListInput
        // parity: client/src/effect/api/api.ts#SessionInboxListOutput [status=implemented hash=ddbd14a6c911]
        public typealias SessionInboxListOutput = [SessionInboxSchema.Info]
        // parity: client/src/effect/api/api.ts#SessionInboxListOperation [status=implemented hash=752696218e7c]
        public typealias SessionInboxListOperation = @Sendable (SessionInboxListInput) async throws -> SessionInboxListOutput
        // parity: client/src/effect/api/api.ts#SessionInboxCancelInput [status=implemented hash=9446c07b0b19]
        public typealias SessionInboxCancelInput = PromiseInputTypes.SessionInboxCancelInput
        // parity: client/src/effect/api/api.ts#SessionInboxCancelOutput [status=implemented hash=8af65ea26464]
        public typealias SessionInboxCancelOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#SessionInboxCancelOperation [status=implemented hash=bd4158864f8c]
        public typealias SessionInboxCancelOperation = @Sendable (SessionInboxCancelInput) async throws -> SessionInboxCancelOutput
        // parity: client/src/effect/api/api.ts#SessionInboxUpdateInput [status=implemented hash=68fd2d301be5]
        public typealias SessionInboxUpdateInput = PromiseInputTypes.SessionInboxUpdateInput
        // parity: client/src/effect/api/api.ts#SessionInboxUpdateOutput [status=implemented hash=fca13c4e81b8]
        public typealias SessionInboxUpdateOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#SessionInboxUpdateOperation [status=implemented hash=c2a8031016d2]
        public typealias SessionInboxUpdateOperation = @Sendable (SessionInboxUpdateInput) async throws -> SessionInboxUpdateOutput
        // parity: client/src/effect/api/api.ts#SessionGenerateInput [status=implemented hash=9d10a05088da]
        public typealias SessionGenerateInput = PromiseInputTypes.SessionGenerateInput
        // parity: client/src/effect/api/api.ts#SessionGenerateOutput [status=implemented hash=b078dc9fb98e]
        public typealias SessionGenerateOutput = SessionGenerateData
        // parity: client/src/effect/api/api.ts#SessionGenerateOperation [status=implemented hash=f919ad155ed2]
        public typealias SessionGenerateOperation = @Sendable (SessionGenerateInput) async throws -> SessionGenerateOutput
        // parity: client/src/effect/api/api.ts#SessionInterruptInput [status=implemented hash=a77d37bbf661]
        public typealias SessionInterruptInput = PromiseInputTypes.SessionInterruptInput
        // parity: client/src/effect/api/api.ts#SessionInterruptOutput [status=implemented hash=735605078731]
        public typealias SessionInterruptOutput = SessionInterruptResponse
        // parity: client/src/effect/api/api.ts#SessionInterruptOperation [status=implemented hash=889e4e73cbfb]
        public typealias SessionInterruptOperation = @Sendable (SessionInterruptInput) async throws -> SessionInterruptOutput
        // parity: client/src/effect/api/api.ts#SessionBackgroundInput [status=implemented hash=5941e3cfa239]
        public typealias SessionBackgroundInput = PromiseInputTypes.SessionBackgroundInput
        // parity: client/src/effect/api/api.ts#SessionBackgroundOutput [status=implemented hash=6878a2fc8282]
        public typealias SessionBackgroundOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#SessionBackgroundOperation [status=implemented hash=781bc80d4d77]
        public typealias SessionBackgroundOperation = @Sendable (SessionBackgroundInput) async throws -> SessionBackgroundOutput
        // parity: client/src/effect/api/api.ts#SessionMessageGetInput [status=implemented hash=9a52b3fa9cb8]
        public typealias SessionMessageGetInput = PromiseInputTypes.SessionMessageGetInput
        // parity: client/src/effect/api/api.ts#SessionMessageGetOutput [status=implemented hash=96d2c78df737]
        public typealias SessionMessageGetOutput = SessionMessageSchema.Info
        // parity: client/src/effect/api/api.ts#SessionMessageGetOperation [status=implemented hash=94eb375b8097]
        public typealias SessionMessageGetOperation = @Sendable (SessionMessageGetInput) async throws -> SessionMessageGetOutput
        // parity: client/src/effect/api/api.ts#SessionFormListInput [status=implemented hash=e2664af3ece0]
        public typealias SessionFormListInput = PromiseInputTypes.SessionFormListInput
        // parity: client/src/effect/api/api.ts#SessionFormListOutput [status=implemented hash=a54c87ee680f]
        public typealias SessionFormListOutput = [FormSchema.Info]
        // parity: client/src/effect/api/api.ts#SessionFormListOperation [status=implemented hash=9d2c9fb8ab7a]
        public typealias SessionFormListOperation = @Sendable (SessionFormListInput) async throws -> SessionFormListOutput
        // parity: client/src/effect/api/api.ts#SessionFormCreateInput [status=implemented hash=e5b73d7f3ce5]
        public typealias SessionFormCreateInput = PromiseInputTypes.SessionFormCreateInput
        // parity: client/src/effect/api/api.ts#SessionFormCreateOutput [status=implemented hash=26445d8eaf87]
        public typealias SessionFormCreateOutput = FormSchema.Info
        // parity: client/src/effect/api/api.ts#SessionFormCreateOperation [status=implemented hash=383fb256bd7b]
        public typealias SessionFormCreateOperation = @Sendable (SessionFormCreateInput) async throws -> SessionFormCreateOutput
        // parity: client/src/effect/api/api.ts#SessionFormGetInput [status=implemented hash=7bf1e63acc16]
        public typealias SessionFormGetInput = PromiseInputTypes.SessionFormGetInput
        // parity: client/src/effect/api/api.ts#SessionFormGetOutput [status=implemented hash=406b9857f9c8]
        public typealias SessionFormGetOutput = FormSchema.Detail
        // parity: client/src/effect/api/api.ts#SessionFormGetOperation [status=implemented hash=cc0703c03e30]
        public typealias SessionFormGetOperation = @Sendable (SessionFormGetInput) async throws -> SessionFormGetOutput
        // parity: client/src/effect/api/api.ts#SessionFormReplyInput [status=implemented hash=99addfd0c3a6]
        public typealias SessionFormReplyInput = PromiseInputTypes.SessionFormReplyInput
        // parity: client/src/effect/api/api.ts#SessionFormReplyOutput [status=implemented hash=aeecdb5453da]
        public typealias SessionFormReplyOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#SessionFormReplyOperation [status=implemented hash=192d771baa83]
        public typealias SessionFormReplyOperation = @Sendable (SessionFormReplyInput) async throws -> SessionFormReplyOutput
        // parity: client/src/effect/api/api.ts#SessionFormCancelInput [status=implemented hash=ade56164aa97]
        public typealias SessionFormCancelInput = PromiseInputTypes.SessionFormCancelInput
        // parity: client/src/effect/api/api.ts#SessionFormCancelOutput [status=implemented hash=8e73ab8e4a8d]
        public typealias SessionFormCancelOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#SessionFormCancelOperation [status=implemented hash=58fb6bc79727]
        public typealias SessionFormCancelOperation = @Sendable (SessionFormCancelInput) async throws -> SessionFormCancelOutput
        // parity: client/src/effect/api/api.ts#SessionEnvironmentInput [status=implemented hash=9f5cacb340ee]
        public typealias SessionEnvironmentInput = PromiseInputTypes.SessionEnvironmentInput
        // parity: client/src/effect/api/api.ts#SessionEnvironmentOutput [status=implemented hash=b79c043837ca]
        public typealias SessionEnvironmentOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#SessionEnvironmentOperation [status=implemented hash=86e73ce4ab8b]
        public typealias SessionEnvironmentOperation = @Sendable (SessionEnvironmentInput) async throws -> SessionEnvironmentOutput
        // parity: client/src/effect/api/api.ts#SessionViewInput [status=implemented hash=c210dc3c98e4]
        public typealias SessionViewInput = PromiseInputTypes.SessionViewInput
        // parity: client/src/effect/api/api.ts#SessionViewOutput [status=implemented hash=5f0a83819bc8]
        public typealias SessionViewOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#SessionViewOperation [status=implemented hash=e40a98088358]
        public typealias SessionViewOperation = @Sendable (SessionViewInput) async throws -> SessionViewOutput
        // parity: client/src/effect/api/api.ts#SessionApi [status=implemented hash=21e70344add4]
        public typealias SessionApi = SessionClientAPI
        // parity: client/src/effect/api/api.ts#ExperimentalSessionStatsInput [status=implemented hash=c156fd37ca82]
        public typealias ExperimentalSessionStatsInput = PromiseInputTypes.ExperimentalSessionStatsInput
        // parity: client/src/effect/api/api.ts#ExperimentalSessionStatsOutput [status=implemented hash=18494f311aca]
        public typealias ExperimentalSessionStatsOutput = SessionStatsSchema.Info
        // parity: client/src/effect/api/api.ts#ExperimentalSessionStatsOperation [status=implemented hash=38a1adb34496]
        public typealias ExperimentalSessionStatsOperation = @Sendable (ExperimentalSessionStatsInput?) async throws -> ExperimentalSessionStatsOutput
        // parity: client/src/effect/api/api.ts#ExperimentalSessionImportInput [status=implemented hash=ce5e20ca8675]
        public typealias ExperimentalSessionImportInput = PromiseInputTypes.ExperimentalSessionImportInput
        // parity: client/src/effect/api/api.ts#ExperimentalSessionImportOutput [status=implemented hash=7dcc4c027b3f]
        public typealias ExperimentalSessionImportOutput = SessionSchema.Info
        // parity: client/src/effect/api/api.ts#ExperimentalSessionImportOperation [status=implemented hash=7d319c3246b9]
        public typealias ExperimentalSessionImportOperation = @Sendable (ExperimentalSessionImportInput) async throws -> ExperimentalSessionImportOutput
        // parity: client/src/effect/api/api.ts#ExperimentalSessionExportInput [status=implemented hash=33ebed132a7d]
        public typealias ExperimentalSessionExportInput = PromiseInputTypes.ExperimentalSessionExportInput
        // parity: client/src/effect/api/api.ts#ExperimentalSessionExportOutput [status=implemented hash=823f7f64d3ac]
        public typealias ExperimentalSessionExportOutput = SessionTransferSchema.Data
        // parity: client/src/effect/api/api.ts#ExperimentalSessionExportOperation [status=implemented hash=2448b4738afc]
        public typealias ExperimentalSessionExportOperation = @Sendable (ExperimentalSessionExportInput) async throws -> ExperimentalSessionExportOutput
        // parity: client/src/effect/api/api.ts#ExperimentalSessionSkillInput [status=implemented hash=7c7820b8e099]
        public typealias ExperimentalSessionSkillInput = PromiseInputTypes.ExperimentalSessionSkillInput
        // parity: client/src/effect/api/api.ts#ExperimentalSessionSkillOutput [status=implemented hash=78154ad9c13f]
        public typealias ExperimentalSessionSkillOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#ExperimentalSessionSkillOperation [status=implemented hash=fb232284c34c]
        public typealias ExperimentalSessionSkillOperation = @Sendable (ExperimentalSessionSkillInput) async throws -> ExperimentalSessionSkillOutput
        // parity: client/src/effect/api/api.ts#ExperimentalSessionWaitInput [status=implemented hash=06c27f97b084]
        public typealias ExperimentalSessionWaitInput = PromiseInputTypes.ExperimentalSessionWaitInput
        // parity: client/src/effect/api/api.ts#ExperimentalSessionWaitOutput [status=implemented hash=4ca37a946fe7]
        public typealias ExperimentalSessionWaitOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#ExperimentalSessionWaitOperation [status=implemented hash=275b65b1d397]
        public typealias ExperimentalSessionWaitOperation = @Sendable (ExperimentalSessionWaitInput) async throws -> ExperimentalSessionWaitOutput
        // parity: client/src/effect/api/api.ts#ExperimentalSessionInstructionsEntryListInput [status=implemented hash=466e6af94c7e]
        public typealias ExperimentalSessionInstructionsEntryListInput = PromiseInputTypes.ExperimentalSessionInstructionsEntryListInput
        // parity: client/src/effect/api/api.ts#ExperimentalSessionInstructionsEntryListOutput [status=implemented hash=9763484909ec]
        public typealias ExperimentalSessionInstructionsEntryListOutput = [InstructionEntrySchema.Info]
        // parity: client/src/effect/api/api.ts#ExperimentalSessionInstructionsEntryListOperation [status=implemented hash=9e7284082371]
        public typealias ExperimentalSessionInstructionsEntryListOperation = @Sendable (ExperimentalSessionInstructionsEntryListInput) async throws -> ExperimentalSessionInstructionsEntryListOutput
        // parity: client/src/effect/api/api.ts#ExperimentalSessionInstructionsEntryPutInput [status=implemented hash=e54f4fecdcff]
        public typealias ExperimentalSessionInstructionsEntryPutInput = PromiseInputTypes.ExperimentalSessionInstructionsEntryPutInput
        // parity: client/src/effect/api/api.ts#ExperimentalSessionInstructionsEntryPutOutput [status=implemented hash=954343fc987a]
        public typealias ExperimentalSessionInstructionsEntryPutOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#ExperimentalSessionInstructionsEntryPutOperation [status=implemented hash=5e8f1da9e633]
        public typealias ExperimentalSessionInstructionsEntryPutOperation = @Sendable (ExperimentalSessionInstructionsEntryPutInput) async throws -> ExperimentalSessionInstructionsEntryPutOutput
        // parity: client/src/effect/api/api.ts#ExperimentalSessionInstructionsEntryRemoveInput [status=implemented hash=a1890fe0a972]
        public typealias ExperimentalSessionInstructionsEntryRemoveInput = PromiseInputTypes.ExperimentalSessionInstructionsEntryRemoveInput
        // parity: client/src/effect/api/api.ts#ExperimentalSessionInstructionsEntryRemoveOutput [status=implemented hash=7f2912f05045]
        public typealias ExperimentalSessionInstructionsEntryRemoveOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#ExperimentalSessionInstructionsEntryRemoveOperation [status=implemented hash=01a8624d758e]
        public typealias ExperimentalSessionInstructionsEntryRemoveOperation = @Sendable (ExperimentalSessionInstructionsEntryRemoveInput) async throws -> ExperimentalSessionInstructionsEntryRemoveOutput
        // parity: client/src/effect/api/api.ts#ExperimentalSessionLogInput [status=implemented hash=d564dbfa1cfa]
        public typealias ExperimentalSessionLogInput = PromiseInputTypes.ExperimentalSessionLogInput
        // parity: client/src/effect/api/api.ts#ExperimentalSessionLogOutput [status=implemented hash=020de82295e0]
        public typealias ExperimentalSessionLogOutput = SessionLogItem
        // parity: client/src/effect/api/api.ts#ExperimentalSessionLogOperation [status=implemented hash=c6e366ba2cc8]
        public typealias ExperimentalSessionLogOperation = @Sendable (ExperimentalSessionLogInput) -> AsyncThrowingStream<ExperimentalSessionLogOutput, any Error>
        // parity: client/src/effect/api/api.ts#ExperimentalSessionApi [status=implemented hash=e2b08baaf50c]
        public typealias ExperimentalSessionApi = ExperimentalSessionClientAPI
        // parity: client/src/effect/api/api.ts#MessageListInput [status=implemented hash=5c73d7c96cb7]
        public typealias MessageListInput = PromiseInputTypes.MessageListInput
        // parity: client/src/effect/api/api.ts#MessageListOutput [status=implemented hash=c9def998df6c]
        public typealias MessageListOutput = SessionMessagesResponse
        // parity: client/src/effect/api/api.ts#MessageListOperation [status=implemented hash=428f7a87823e]
        public typealias MessageListOperation = @Sendable (MessageListInput) async throws -> MessageListOutput
        // parity: client/src/effect/api/api.ts#MessageApi [status=implemented hash=0811ca9bc2e3]
        public typealias MessageApi = MessageClientAPI
        // parity: client/src/effect/api/api.ts#ModelListInput [status=implemented hash=cefa0c1a61ad]
        public typealias ModelListInput = PromiseInputTypes.ModelListInput
        // parity: client/src/effect/api/api.ts#ModelListOutput [status=implemented hash=76e69ffb0b5f]
        public typealias ModelListOutput = LocationSchema.ResponseEnvelope<[ModelSchema.Info]>
        // parity: client/src/effect/api/api.ts#ModelListOperation [status=implemented hash=e4e0868fe219]
        public typealias ModelListOperation = @Sendable (ModelListInput?) async throws -> ModelListOutput
        // parity: client/src/effect/api/api.ts#ModelDefaultInput [status=implemented hash=c19a788319a6]
        public typealias ModelDefaultInput = PromiseInputTypes.ModelDefaultInput
        // parity: client/src/effect/api/api.ts#ModelDefaultOutput [status=implemented hash=a77b736bce4e]
        public typealias ModelDefaultOutput = LocationSchema.ResponseEnvelope<ModelSchema.Info?>
        // parity: client/src/effect/api/api.ts#ModelDefaultOperation [status=implemented hash=9b96dd0e2ed8]
        public typealias ModelDefaultOperation = @Sendable (ModelDefaultInput?) async throws -> ModelDefaultOutput
        // parity: client/src/effect/api/api.ts#ModelApi [status=implemented hash=31e880f51878]
        public typealias ModelApi = ModelClientAPI
        // parity: client/src/effect/api/api.ts#ExperimentalGenerateTextInput [status=implemented hash=f86f43071914]
        public typealias ExperimentalGenerateTextInput = PromiseInputTypes.ExperimentalGenerateTextInput
        // parity: client/src/effect/api/api.ts#ExperimentalGenerateTextOutput [status=implemented hash=4678bf697e9c]
        public typealias ExperimentalGenerateTextOutput = GenerateTextData
        // parity: client/src/effect/api/api.ts#ExperimentalGenerateTextOperation [status=implemented hash=6ab78de953df]
        public typealias ExperimentalGenerateTextOperation = @Sendable (ExperimentalGenerateTextInput) async throws -> ExperimentalGenerateTextOutput
        // parity: client/src/effect/api/api.ts#ExperimentalGenerateImageInput [status=implemented hash=552ca7912fc8]
        public typealias ExperimentalGenerateImageInput = PromiseInputTypes.ExperimentalGenerateImageInput
        // parity: client/src/effect/api/api.ts#ExperimentalGenerateImageOutput [status=implemented hash=66255045d04d]
        public typealias ExperimentalGenerateImageOutput = GenerateSchema.ImageResult
        // parity: client/src/effect/api/api.ts#ExperimentalGenerateImageOperation [status=implemented hash=fab5f915332b]
        public typealias ExperimentalGenerateImageOperation = @Sendable (ExperimentalGenerateImageInput) async throws -> ExperimentalGenerateImageOutput
        // parity: client/src/effect/api/api.ts#ExperimentalGenerateVideoCreateInput [status=implemented hash=6fd0c52aad07]
        public typealias ExperimentalGenerateVideoCreateInput = PromiseInputTypes.ExperimentalGenerateVideoCreateInput
        // parity: client/src/effect/api/api.ts#ExperimentalGenerateVideoCreateOutput [status=implemented hash=92c094cda349]
        public typealias ExperimentalGenerateVideoCreateOutput = GenerateSchema.VideoRunning
        // parity: client/src/effect/api/api.ts#ExperimentalGenerateVideoCreateOperation [status=implemented hash=0106da4a19d0]
        public typealias ExperimentalGenerateVideoCreateOperation = @Sendable (ExperimentalGenerateVideoCreateInput) async throws -> ExperimentalGenerateVideoCreateOutput
        // parity: client/src/effect/api/api.ts#ExperimentalGenerateVideoGetInput [status=implemented hash=776d0d4c8ac8]
        public typealias ExperimentalGenerateVideoGetInput = PromiseInputTypes.ExperimentalGenerateVideoGetInput
        // parity: client/src/effect/api/api.ts#ExperimentalGenerateVideoGetOutput [status=implemented hash=a9d18181dfe9]
        public typealias ExperimentalGenerateVideoGetOutput = GenerateSchema.VideoJob
        // parity: client/src/effect/api/api.ts#ExperimentalGenerateVideoGetOperation [status=implemented hash=1489fd67613f]
        public typealias ExperimentalGenerateVideoGetOperation = @Sendable (ExperimentalGenerateVideoGetInput) async throws -> ExperimentalGenerateVideoGetOutput
        // parity: client/src/effect/api/api.ts#ExperimentalGenerateDecisionsInput [status=implemented hash=45d6114ac4c3]
        public typealias ExperimentalGenerateDecisionsInput = PromiseInputTypes.ExperimentalGenerateDecisionsInput
        // parity: client/src/effect/api/api.ts#ExperimentalGenerateDecisionsOutput [status=implemented hash=4547f97e36e2]
        public typealias ExperimentalGenerateDecisionsOutput = GenerateSchema.DecisionResult
        // parity: client/src/effect/api/api.ts#ExperimentalGenerateDecisionsOperation [status=implemented hash=2bcdf8ddbb82]
        public typealias ExperimentalGenerateDecisionsOperation = @Sendable (ExperimentalGenerateDecisionsInput) async throws -> ExperimentalGenerateDecisionsOutput
        // parity: client/src/effect/api/api.ts#ExperimentalGenerateApi [status=implemented hash=3dcd822261c8]
        public typealias ExperimentalGenerateApi = ExperimentalGenerateClientAPI
        // parity: client/src/effect/api/api.ts#ExperimentalVoiceModelsOutput [status=implemented hash=17c2e3e0a0ff]
        public typealias ExperimentalVoiceModelsOutput = VoiceModelsData
        // parity: client/src/effect/api/api.ts#ExperimentalVoiceModelsOperation [status=implemented hash=8d57cba745cf]
        public typealias ExperimentalVoiceModelsOperation = @Sendable () async throws -> ExperimentalVoiceModelsOutput
        // parity: client/src/effect/api/api.ts#ExperimentalVoiceSessionInput [status=implemented hash=77c7d19d28d9]
        public typealias ExperimentalVoiceSessionInput = PromiseInputTypes.ExperimentalVoiceSessionInput
        // parity: client/src/effect/api/api.ts#ExperimentalVoiceSessionOutput [status=implemented hash=995833ee5d97]
        public typealias ExperimentalVoiceSessionOutput = VoiceSessionData
        // parity: client/src/effect/api/api.ts#ExperimentalVoiceSessionOperation [status=implemented hash=02b3d3ca6567]
        public typealias ExperimentalVoiceSessionOperation = @Sendable (ExperimentalVoiceSessionInput) async throws -> ExperimentalVoiceSessionOutput
        // parity: client/src/effect/api/api.ts#ExperimentalVoiceApi [status=implemented hash=300d01a09334]
        public typealias ExperimentalVoiceApi = ExperimentalVoiceClientAPI
        // parity: client/src/effect/api/api.ts#ProviderListInput [status=implemented hash=9faa774bd9c6]
        public typealias ProviderListInput = PromiseInputTypes.ProviderListInput
        // parity: client/src/effect/api/api.ts#ProviderListOutput [status=implemented hash=ef286a20a101]
        public typealias ProviderListOutput = LocationSchema.ResponseEnvelope<[ProviderSchema.Info]>
        // parity: client/src/effect/api/api.ts#ProviderListOperation [status=implemented hash=86e61b2e97c9]
        public typealias ProviderListOperation = @Sendable (ProviderListInput?) async throws -> ProviderListOutput
        // parity: client/src/effect/api/api.ts#ProviderGetInput [status=implemented hash=3e71dee311c5]
        public typealias ProviderGetInput = PromiseInputTypes.ProviderGetInput
        // parity: client/src/effect/api/api.ts#ProviderGetOutput [status=implemented hash=f875fecf3d21]
        public typealias ProviderGetOutput = LocationSchema.ResponseEnvelope<ProviderSchema.Info>
        // parity: client/src/effect/api/api.ts#ProviderGetOperation [status=implemented hash=f39a6944d364]
        public typealias ProviderGetOperation = @Sendable (ProviderGetInput) async throws -> ProviderGetOutput
        // parity: client/src/effect/api/api.ts#ProviderApi [status=implemented hash=5ff74205ace9]
        public typealias ProviderApi = ProviderClientAPI
        // parity: client/src/effect/api/api.ts#IntegrationListInput [status=implemented hash=a138f3e2f704]
        public typealias IntegrationListInput = PromiseInputTypes.IntegrationListInput
        // parity: client/src/effect/api/api.ts#IntegrationListOutput [status=implemented hash=80d99f62f9b3]
        public typealias IntegrationListOutput = LocationSchema.ResponseEnvelope<[IntegrationSchema.Info]>
        // parity: client/src/effect/api/api.ts#IntegrationListOperation [status=implemented hash=5b782a69fbbc]
        public typealias IntegrationListOperation = @Sendable (IntegrationListInput?) async throws -> IntegrationListOutput
        // parity: client/src/effect/api/api.ts#IntegrationGetInput [status=implemented hash=a114da287f40]
        public typealias IntegrationGetInput = PromiseInputTypes.IntegrationGetInput
        // parity: client/src/effect/api/api.ts#IntegrationGetOutput [status=implemented hash=355eec4213d0]
        public typealias IntegrationGetOutput = LocationSchema.ResponseEnvelope<IntegrationSchema.Info>
        // parity: client/src/effect/api/api.ts#IntegrationGetOperation [status=implemented hash=890bf6eaa054]
        public typealias IntegrationGetOperation = @Sendable (IntegrationGetInput) async throws -> IntegrationGetOutput
        // parity: client/src/effect/api/api.ts#IntegrationConnectKeyInput [status=implemented hash=146275ffe54b]
        public typealias IntegrationConnectKeyInput = PromiseInputTypes.IntegrationConnectKeyInput
        // parity: client/src/effect/api/api.ts#IntegrationConnectKeyOutput [status=implemented hash=77c286d598c7]
        public typealias IntegrationConnectKeyOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#IntegrationConnectKeyOperation [status=implemented hash=d68971482e18]
        public typealias IntegrationConnectKeyOperation = @Sendable (IntegrationConnectKeyInput) async throws -> IntegrationConnectKeyOutput
        // parity: client/src/effect/api/api.ts#IntegrationConnectExternalInput [status=implemented hash=0d2e2f87de9e]
        public typealias IntegrationConnectExternalInput = PromiseInputTypes.IntegrationConnectExternalInput
        // parity: client/src/effect/api/api.ts#IntegrationConnectExternalOutput [status=implemented hash=dc50893ea51b]
        public typealias IntegrationConnectExternalOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#IntegrationConnectExternalOperation [status=implemented hash=e151dccfbf85]
        public typealias IntegrationConnectExternalOperation = @Sendable (IntegrationConnectExternalInput) async throws -> IntegrationConnectExternalOutput
        // parity: client/src/effect/api/api.ts#IntegrationOauthConnectInput [status=implemented hash=b6f4b70c22fb]
        public typealias IntegrationOauthConnectInput = PromiseInputTypes.IntegrationOauthConnectInput
        // parity: client/src/effect/api/api.ts#IntegrationOauthConnectOutput [status=implemented hash=f86edf0dc27e]
        public typealias IntegrationOauthConnectOutput = LocationSchema.ResponseEnvelope<IntegrationSchema.Attempt>
        // parity: client/src/effect/api/api.ts#IntegrationOauthConnectOperation [status=implemented hash=2c54df71a701]
        public typealias IntegrationOauthConnectOperation = @Sendable (IntegrationOauthConnectInput) async throws -> IntegrationOauthConnectOutput
        // parity: client/src/effect/api/api.ts#IntegrationOauthStatusInput [status=implemented hash=15a25aa618f2]
        public typealias IntegrationOauthStatusInput = PromiseInputTypes.IntegrationOauthStatusInput
        // parity: client/src/effect/api/api.ts#IntegrationOauthStatusOutput [status=implemented hash=0f52166e1fc9]
        public typealias IntegrationOauthStatusOutput = LocationSchema.ResponseEnvelope<IntegrationSchema.AttemptStatus>
        // parity: client/src/effect/api/api.ts#IntegrationOauthStatusOperation [status=implemented hash=7df973cf8ddf]
        public typealias IntegrationOauthStatusOperation = @Sendable (IntegrationOauthStatusInput) async throws -> IntegrationOauthStatusOutput
        // parity: client/src/effect/api/api.ts#IntegrationOauthCompleteInput [status=implemented hash=c531100d71c1]
        public typealias IntegrationOauthCompleteInput = PromiseInputTypes.IntegrationOauthCompleteInput
        // parity: client/src/effect/api/api.ts#IntegrationOauthCompleteOutput [status=implemented hash=99245919a1bc]
        public typealias IntegrationOauthCompleteOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#IntegrationOauthCompleteOperation [status=implemented hash=b7e4c723c12e]
        public typealias IntegrationOauthCompleteOperation = @Sendable (IntegrationOauthCompleteInput) async throws -> IntegrationOauthCompleteOutput
        // parity: client/src/effect/api/api.ts#IntegrationOauthCancelInput [status=implemented hash=5afcaf510d82]
        public typealias IntegrationOauthCancelInput = PromiseInputTypes.IntegrationOauthCancelInput
        // parity: client/src/effect/api/api.ts#IntegrationOauthCancelOutput [status=implemented hash=c6dd621ffe93]
        public typealias IntegrationOauthCancelOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#IntegrationOauthCancelOperation [status=implemented hash=3d116b19dcee]
        public typealias IntegrationOauthCancelOperation = @Sendable (IntegrationOauthCancelInput) async throws -> IntegrationOauthCancelOutput
        // parity: client/src/effect/api/api.ts#IntegrationCommandConnectInput [status=implemented hash=bab8a0cda145]
        public typealias IntegrationCommandConnectInput = PromiseInputTypes.IntegrationCommandConnectInput
        // parity: client/src/effect/api/api.ts#IntegrationCommandConnectOutput [status=implemented hash=e132c1621acf]
        public typealias IntegrationCommandConnectOutput = LocationSchema.ResponseEnvelope<IntegrationSchema.CommandAttempt>
        // parity: client/src/effect/api/api.ts#IntegrationCommandConnectOperation [status=implemented hash=aa3bb2d8c740]
        public typealias IntegrationCommandConnectOperation = @Sendable (IntegrationCommandConnectInput) async throws -> IntegrationCommandConnectOutput
        // parity: client/src/effect/api/api.ts#IntegrationCommandStatusInput [status=implemented hash=1c02018372d4]
        public typealias IntegrationCommandStatusInput = PromiseInputTypes.IntegrationCommandStatusInput
        // parity: client/src/effect/api/api.ts#IntegrationCommandStatusOutput [status=implemented hash=4f1322b0cfe3]
        public typealias IntegrationCommandStatusOutput = LocationSchema.ResponseEnvelope<IntegrationSchema.CommandAttemptStatus>
        // parity: client/src/effect/api/api.ts#IntegrationCommandStatusOperation [status=implemented hash=889888eff553]
        public typealias IntegrationCommandStatusOperation = @Sendable (IntegrationCommandStatusInput) async throws -> IntegrationCommandStatusOutput
        // parity: client/src/effect/api/api.ts#IntegrationCommandCancelInput [status=implemented hash=eb3587184b98]
        public typealias IntegrationCommandCancelInput = PromiseInputTypes.IntegrationCommandCancelInput
        // parity: client/src/effect/api/api.ts#IntegrationCommandCancelOutput [status=implemented hash=2d1fc9ce7d1e]
        public typealias IntegrationCommandCancelOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#IntegrationCommandCancelOperation [status=implemented hash=fe8dfce9ec54]
        public typealias IntegrationCommandCancelOperation = @Sendable (IntegrationCommandCancelInput) async throws -> IntegrationCommandCancelOutput
        // parity: client/src/effect/api/api.ts#IntegrationApi [status=implemented hash=5c1d71eefba4]
        public typealias IntegrationApi = IntegrationClientAPI
        // parity: client/src/effect/api/api.ts#ExperimentalIntegrationWellknownAddInput [status=implemented hash=dc32fd926001]
        public typealias ExperimentalIntegrationWellknownAddInput = PromiseInputTypes.ExperimentalIntegrationWellknownAddInput
        // parity: client/src/effect/api/api.ts#ExperimentalIntegrationWellknownAddOutput [status=implemented hash=6f9be466c897]
        public typealias ExperimentalIntegrationWellknownAddOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#ExperimentalIntegrationWellknownAddOperation [status=implemented hash=edf0f594c239]
        public typealias ExperimentalIntegrationWellknownAddOperation = @Sendable (ExperimentalIntegrationWellknownAddInput) async throws -> ExperimentalIntegrationWellknownAddOutput
        // parity: client/src/effect/api/api.ts#ExperimentalIntegrationApi [status=implemented hash=66fa06809f3d]
        public typealias ExperimentalIntegrationApi = ExperimentalIntegrationClientAPI
        // parity: client/src/effect/api/api.ts#McpListInput [status=implemented hash=096c6117fb8b]
        public typealias McpListInput = PromiseInputTypes.McpListInput
        // parity: client/src/effect/api/api.ts#McpListOutput [status=implemented hash=1b40fa6c19c8]
        public typealias McpListOutput = LocationSchema.ResponseEnvelope<[McpSchema.Server]>
        // parity: client/src/effect/api/api.ts#McpListOperation [status=implemented hash=75a11c4f09fc]
        public typealias McpListOperation = @Sendable (McpListInput?) async throws -> McpListOutput
        // parity: client/src/effect/api/api.ts#McpResourceCatalogInput [status=implemented hash=7f0524d5cd18]
        public typealias McpResourceCatalogInput = PromiseInputTypes.McpResourceCatalogInput
        // parity: client/src/effect/api/api.ts#McpResourceCatalogOutput [status=implemented hash=b1221a643fd5]
        public typealias McpResourceCatalogOutput = LocationSchema.ResponseEnvelope<McpSchema.ResourceCatalog>
        // parity: client/src/effect/api/api.ts#McpResourceCatalogOperation [status=implemented hash=247ad705c834]
        public typealias McpResourceCatalogOperation = @Sendable (McpResourceCatalogInput?) async throws -> McpResourceCatalogOutput
        // parity: client/src/effect/api/api.ts#McpApi [status=implemented hash=89c4021959d1]
        public typealias McpApi = McpClientAPI
        // parity: client/src/effect/api/api.ts#ExperimentalMcpAddInput [status=implemented hash=6a6df6ca706b]
        public typealias ExperimentalMcpAddInput = PromiseInputTypes.ExperimentalMcpAddInput
        // parity: client/src/effect/api/api.ts#ExperimentalMcpAddOutput [status=implemented hash=4428b0cb8a44]
        public typealias ExperimentalMcpAddOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#ExperimentalMcpAddOperation [status=implemented hash=7f55732eb34d]
        public typealias ExperimentalMcpAddOperation = @Sendable (ExperimentalMcpAddInput) async throws -> ExperimentalMcpAddOutput
        // parity: client/src/effect/api/api.ts#ExperimentalMcpRemoveInput [status=implemented hash=22acbbeb1eb7]
        public typealias ExperimentalMcpRemoveInput = PromiseInputTypes.ExperimentalMcpRemoveInput
        // parity: client/src/effect/api/api.ts#ExperimentalMcpRemoveOutput [status=implemented hash=04f374c35d74]
        public typealias ExperimentalMcpRemoveOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#ExperimentalMcpRemoveOperation [status=implemented hash=6798c31e1dbe]
        public typealias ExperimentalMcpRemoveOperation = @Sendable (ExperimentalMcpRemoveInput) async throws -> ExperimentalMcpRemoveOutput
        // parity: client/src/effect/api/api.ts#ExperimentalMcpConnectInput [status=implemented hash=18f23564f36d]
        public typealias ExperimentalMcpConnectInput = PromiseInputTypes.ExperimentalMcpConnectInput
        // parity: client/src/effect/api/api.ts#ExperimentalMcpConnectOutput [status=implemented hash=606cc95e3f78]
        public typealias ExperimentalMcpConnectOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#ExperimentalMcpConnectOperation [status=implemented hash=b12260728f0b]
        public typealias ExperimentalMcpConnectOperation = @Sendable (ExperimentalMcpConnectInput) async throws -> ExperimentalMcpConnectOutput
        // parity: client/src/effect/api/api.ts#ExperimentalMcpDisconnectInput [status=implemented hash=f919b831ab20]
        public typealias ExperimentalMcpDisconnectInput = PromiseInputTypes.ExperimentalMcpDisconnectInput
        // parity: client/src/effect/api/api.ts#ExperimentalMcpDisconnectOutput [status=implemented hash=004f983716b2]
        public typealias ExperimentalMcpDisconnectOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#ExperimentalMcpDisconnectOperation [status=implemented hash=09faaa75ffcf]
        public typealias ExperimentalMcpDisconnectOperation = @Sendable (ExperimentalMcpDisconnectInput) async throws -> ExperimentalMcpDisconnectOutput
        // parity: client/src/effect/api/api.ts#ExperimentalMcpClientTokenInput [status=implemented hash=c24dcd025edb]
        public typealias ExperimentalMcpClientTokenInput = PromiseInputTypes.ExperimentalMcpClientTokenInput
        // parity: client/src/effect/api/api.ts#ExperimentalMcpClientTokenOutput [status=implemented hash=df2bc0107b30]
        public typealias ExperimentalMcpClientTokenOutput = LocationSchema.ResponseEnvelope<PtyTicketSchema.ConnectToken>
        // parity: client/src/effect/api/api.ts#ExperimentalMcpClientTokenOperation [status=implemented hash=585ca039989b]
        public typealias ExperimentalMcpClientTokenOperation = @Sendable (ExperimentalMcpClientTokenInput) async throws -> ExperimentalMcpClientTokenOutput
        // parity: client/src/effect/api/api.ts#ExperimentalMcpApi [status=implemented hash=753d1eaccc75]
        public typealias ExperimentalMcpApi = ExperimentalMcpClientAPI
        // parity: client/src/effect/api/api.ts#CredentialListOutput [status=implemented hash=505b8e9a0951]
        public typealias CredentialListOutput = [CredentialSchema.Entry]
        // parity: client/src/effect/api/api.ts#CredentialListOperation [status=implemented hash=7f95d106c7ce]
        public typealias CredentialListOperation = @Sendable () async throws -> CredentialListOutput
        // parity: client/src/effect/api/api.ts#CredentialCreateInput [status=implemented hash=a63244fb0cae]
        public typealias CredentialCreateInput = PromiseInputTypes.CredentialCreateInput
        // parity: client/src/effect/api/api.ts#CredentialCreateOutput [status=implemented hash=f7d4c73b1bd0]
        public typealias CredentialCreateOutput = CredentialSchema.Entry
        // parity: client/src/effect/api/api.ts#CredentialCreateOperation [status=implemented hash=a2f9c470d0a8]
        public typealias CredentialCreateOperation = @Sendable (CredentialCreateInput) async throws -> CredentialCreateOutput
        // parity: client/src/effect/api/api.ts#CredentialUpdateInput [status=implemented hash=ad9e70625c7e]
        public typealias CredentialUpdateInput = PromiseInputTypes.CredentialUpdateInput
        // parity: client/src/effect/api/api.ts#CredentialUpdateOutput [status=implemented hash=17fc4f325ba3]
        public typealias CredentialUpdateOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#CredentialUpdateOperation [status=implemented hash=fa9ae05f2af6]
        public typealias CredentialUpdateOperation = @Sendable (CredentialUpdateInput) async throws -> CredentialUpdateOutput
        // parity: client/src/effect/api/api.ts#CredentialActivateInput [status=implemented hash=0a5a5f6b25a1]
        public typealias CredentialActivateInput = PromiseInputTypes.CredentialActivateInput
        // parity: client/src/effect/api/api.ts#CredentialActivateOutput [status=implemented hash=10915d5132db]
        public typealias CredentialActivateOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#CredentialActivateOperation [status=implemented hash=90624ddc0ca9]
        public typealias CredentialActivateOperation = @Sendable (CredentialActivateInput) async throws -> CredentialActivateOutput
        // parity: client/src/effect/api/api.ts#CredentialRemoveInput [status=implemented hash=c3d91c04d7da]
        public typealias CredentialRemoveInput = PromiseInputTypes.CredentialRemoveInput
        // parity: client/src/effect/api/api.ts#CredentialRemoveOutput [status=implemented hash=2ad933097940]
        public typealias CredentialRemoveOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#CredentialRemoveOperation [status=implemented hash=e13316d6e86f]
        public typealias CredentialRemoveOperation = @Sendable (CredentialRemoveInput) async throws -> CredentialRemoveOutput
        // parity: client/src/effect/api/api.ts#CredentialApi [status=implemented hash=bb44ec9bb844]
        public typealias CredentialApi = CredentialClientAPI
        // parity: client/src/effect/api/api.ts#ProjectListInput [status=implemented hash=169b7fe8bcd2]
        public typealias ProjectListInput = PromiseInputTypes.ProjectListInput
        // parity: client/src/effect/api/api.ts#ProjectListOutput [status=implemented hash=d268eb7d7384]
        public typealias ProjectListOutput = [ProjectSchema.Info]
        // parity: client/src/effect/api/api.ts#ProjectListOperation [status=implemented hash=b51a5a901648]
        public typealias ProjectListOperation = @Sendable (ProjectListInput?) async throws -> ProjectListOutput
        // parity: client/src/effect/api/api.ts#ProjectUpdateInput [status=implemented hash=5cd12495b838]
        public typealias ProjectUpdateInput = PromiseInputTypes.ProjectUpdateInput
        // parity: client/src/effect/api/api.ts#ProjectUpdateOutput [status=implemented hash=f3a9fc8e9cfd]
        public typealias ProjectUpdateOutput = ProjectSchema.Info
        // parity: client/src/effect/api/api.ts#ProjectUpdateOperation [status=implemented hash=a37cc7dc3cc4]
        public typealias ProjectUpdateOperation = @Sendable (ProjectUpdateInput) async throws -> ProjectUpdateOutput
        // parity: client/src/effect/api/api.ts#ProjectApi [status=implemented hash=3ad2e0fdb580]
        public typealias ProjectApi = ProjectClientAPI
        // parity: client/src/effect/api/api.ts#FormListInput [status=implemented hash=448f28879b4b]
        public typealias FormListInput = PromiseInputTypes.FormListInput
        // parity: client/src/effect/api/api.ts#FormListOutput [status=implemented hash=73b7997e8794]
        public typealias FormListOutput = LocationSchema.ResponseEnvelope<[FormSchema.Info]>
        // parity: client/src/effect/api/api.ts#FormListOperation [status=implemented hash=3a59c27dfa07]
        public typealias FormListOperation = @Sendable (FormListInput?) async throws -> FormListOutput
        // parity: client/src/effect/api/api.ts#FormApi [status=implemented hash=d9e82430da14]
        public typealias FormApi = FormClientAPI
        // parity: client/src/effect/api/api.ts#PermissionRequestListInput [status=implemented hash=6f33d848462e]
        public typealias PermissionRequestListInput = PromiseInputTypes.PermissionRequestListInput
        // parity: client/src/effect/api/api.ts#PermissionRequestListOutput [status=implemented hash=9e708a5edb68]
        public typealias PermissionRequestListOutput = LocationSchema.ResponseEnvelope<[PermissionSchema.Request]>
        // parity: client/src/effect/api/api.ts#PermissionRequestListOperation [status=implemented hash=1f45f558386d]
        public typealias PermissionRequestListOperation = @Sendable (PermissionRequestListInput?) async throws -> PermissionRequestListOutput
        // parity: client/src/effect/api/api.ts#PermissionSavedListInput [status=implemented hash=c4f8d404e454]
        public typealias PermissionSavedListInput = PromiseInputTypes.PermissionSavedListInput
        // parity: client/src/effect/api/api.ts#PermissionSavedListOutput [status=implemented hash=15bb49e72060]
        public typealias PermissionSavedListOutput = [PermissionSavedSchema.Info]
        // parity: client/src/effect/api/api.ts#PermissionSavedListOperation [status=implemented hash=743696d2f2c3]
        public typealias PermissionSavedListOperation = @Sendable (PermissionSavedListInput?) async throws -> PermissionSavedListOutput
        // parity: client/src/effect/api/api.ts#PermissionSavedUpdateInput [status=implemented hash=84d4f7f2638c]
        public typealias PermissionSavedUpdateInput = PromiseInputTypes.PermissionSavedUpdateInput
        // parity: client/src/effect/api/api.ts#PermissionSavedUpdateOutput [status=implemented hash=82a983017914]
        public typealias PermissionSavedUpdateOutput = PermissionSavedSchema.Info
        // parity: client/src/effect/api/api.ts#PermissionSavedUpdateOperation [status=implemented hash=77c270df00c0]
        public typealias PermissionSavedUpdateOperation = @Sendable (PermissionSavedUpdateInput) async throws -> PermissionSavedUpdateOutput
        // parity: client/src/effect/api/api.ts#PermissionSavedRemoveInput [status=implemented hash=1ba441ddeec9]
        public typealias PermissionSavedRemoveInput = PromiseInputTypes.PermissionSavedRemoveInput
        // parity: client/src/effect/api/api.ts#PermissionSavedRemoveOutput [status=implemented hash=9b7a3c824f8a]
        public typealias PermissionSavedRemoveOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#PermissionSavedRemoveOperation [status=implemented hash=96e3b8637a41]
        public typealias PermissionSavedRemoveOperation = @Sendable (PermissionSavedRemoveInput) async throws -> PermissionSavedRemoveOutput
        // parity: client/src/effect/api/api.ts#PermissionCreateInput [status=implemented hash=94b0131ba357]
        public typealias PermissionCreateInput = PromiseInputTypes.PermissionCreateInput
        // parity: client/src/effect/api/api.ts#PermissionCreateOutput [status=implemented hash=8874c2d6ddad]
        public typealias PermissionCreateOutput = PermissionCreateData
        // parity: client/src/effect/api/api.ts#PermissionCreateOperation [status=implemented hash=f9c227ef78ce]
        public typealias PermissionCreateOperation = @Sendable (PermissionCreateInput) async throws -> PermissionCreateOutput
        // parity: client/src/effect/api/api.ts#PermissionListInput [status=implemented hash=5a4544dec64c]
        public typealias PermissionListInput = PromiseInputTypes.PermissionListInput
        // parity: client/src/effect/api/api.ts#PermissionListOutput [status=implemented hash=aa3fef9ee375]
        public typealias PermissionListOutput = [PermissionSchema.Request]
        // parity: client/src/effect/api/api.ts#PermissionListOperation [status=implemented hash=3eede30e6844]
        public typealias PermissionListOperation = @Sendable (PermissionListInput) async throws -> PermissionListOutput
        // parity: client/src/effect/api/api.ts#PermissionGetInput [status=implemented hash=2fc478bd3351]
        public typealias PermissionGetInput = PromiseInputTypes.PermissionGetInput
        // parity: client/src/effect/api/api.ts#PermissionGetOutput [status=implemented hash=cb1a02307465]
        public typealias PermissionGetOutput = PermissionSchema.Request
        // parity: client/src/effect/api/api.ts#PermissionGetOperation [status=implemented hash=8fe8b35b1bc8]
        public typealias PermissionGetOperation = @Sendable (PermissionGetInput) async throws -> PermissionGetOutput
        // parity: client/src/effect/api/api.ts#PermissionReplyInput [status=implemented hash=057ede78e954]
        public typealias PermissionReplyInput = PromiseInputTypes.PermissionReplyInput
        // parity: client/src/effect/api/api.ts#PermissionReplyOutput [status=implemented hash=1679a38c440e]
        public typealias PermissionReplyOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#PermissionReplyOperation [status=implemented hash=c2a526b3e4b9]
        public typealias PermissionReplyOperation = @Sendable (PermissionReplyInput) async throws -> PermissionReplyOutput
        // parity: client/src/effect/api/api.ts#PermissionApi [status=implemented hash=235d378913a3]
        public typealias PermissionApi = PermissionClientAPI
        // parity: client/src/effect/api/api.ts#FileListInput [status=implemented hash=9f486a3441c8]
        public typealias FileListInput = PromiseInputTypes.FileListInput
        // parity: client/src/effect/api/api.ts#FileListOutput [status=implemented hash=e20ea065cc74]
        public typealias FileListOutput = LocationSchema.ResponseEnvelope<[FileSystemSchema.Entry]>
        // parity: client/src/effect/api/api.ts#FileListOperation [status=implemented hash=ec2317f2c270]
        public typealias FileListOperation = @Sendable (FileListInput?) async throws -> FileListOutput
        // parity: client/src/effect/api/api.ts#FileFindInput [status=implemented hash=d4053d112a0f]
        public typealias FileFindInput = PromiseInputTypes.FileFindInput
        // parity: client/src/effect/api/api.ts#FileFindOutput [status=implemented hash=9a95a95f393c]
        public typealias FileFindOutput = LocationSchema.ResponseEnvelope<[FileSystemSchema.Entry]>
        // parity: client/src/effect/api/api.ts#FileFindOperation [status=implemented hash=dffb3900172f]
        public typealias FileFindOperation = @Sendable (FileFindInput) async throws -> FileFindOutput
        // parity: client/src/effect/api/api.ts#FileApi [status=implemented hash=d9a8f5638b7a]
        public typealias FileApi = FileClientAPI
        // parity: client/src/effect/api/api.ts#ExperimentalFileWatchInput [status=implemented hash=13a4ff8867ff]
        public typealias ExperimentalFileWatchInput = PromiseInputTypes.ExperimentalFileWatchInput
        // parity: client/src/effect/api/api.ts#ExperimentalFileWatchOutput [status=implemented hash=49ad0fa5515b]
        public typealias ExperimentalFileWatchOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#ExperimentalFileWatchOperation [status=implemented hash=d1f9d242fd45]
        public typealias ExperimentalFileWatchOperation = @Sendable (ExperimentalFileWatchInput) async throws -> ExperimentalFileWatchOutput
        // parity: client/src/effect/api/api.ts#ExperimentalFileUnwatchInput [status=implemented hash=777e548dc45b]
        public typealias ExperimentalFileUnwatchInput = PromiseInputTypes.ExperimentalFileUnwatchInput
        // parity: client/src/effect/api/api.ts#ExperimentalFileUnwatchOutput [status=implemented hash=7cd54268a93a]
        public typealias ExperimentalFileUnwatchOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#ExperimentalFileUnwatchOperation [status=implemented hash=b667c7c413b1]
        public typealias ExperimentalFileUnwatchOperation = @Sendable (ExperimentalFileUnwatchInput) async throws -> ExperimentalFileUnwatchOutput
        // parity: client/src/effect/api/api.ts#ExperimentalFileApi [status=implemented hash=96472805fd88]
        public typealias ExperimentalFileApi = ExperimentalFileClientAPI
        // parity: client/src/effect/api/api.ts#CommandListInput [status=implemented hash=e101d76ebe5a]
        public typealias CommandListInput = PromiseInputTypes.CommandListInput
        // parity: client/src/effect/api/api.ts#CommandListOutput [status=implemented hash=a60db89abff7]
        public typealias CommandListOutput = LocationSchema.ResponseEnvelope<[CommandSchema.Info]>
        // parity: client/src/effect/api/api.ts#CommandListOperation [status=implemented hash=cbaf70216e7d]
        public typealias CommandListOperation = @Sendable (CommandListInput?) async throws -> CommandListOutput
        // parity: client/src/effect/api/api.ts#CommandApi [status=implemented hash=d2589b4cb397]
        public typealias CommandApi = CommandClientAPI
        // parity: client/src/effect/api/api.ts#SkillListInput [status=implemented hash=61d6874f1036]
        public typealias SkillListInput = PromiseInputTypes.SkillListInput
        // parity: client/src/effect/api/api.ts#SkillListOutput [status=implemented hash=7e7a6bfdd5a8]
        public typealias SkillListOutput = LocationSchema.ResponseEnvelope<[SkillSchema.Info]>
        // parity: client/src/effect/api/api.ts#SkillListOperation [status=implemented hash=1cad2ce6bb4c]
        public typealias SkillListOperation = @Sendable (SkillListInput?) async throws -> SkillListOutput
        // parity: client/src/effect/api/api.ts#SkillApi [status=implemented hash=69e94d42863e]
        public typealias SkillApi = SkillClientAPI
        // parity: client/src/effect/api/api.ts#RpcCallInput [status=implemented hash=d68746e5191d]
        public typealias RpcCallInput = PromiseInputTypes.RpcCallInput
        // parity: client/src/effect/api/api.ts#RpcCallOutput [status=implemented hash=8403e164b7d3]
        public typealias RpcCallOutput = OpenCodeProtocol.RpcOutput
        // parity: client/src/effect/api/api.ts#RpcCallOperation [status=implemented hash=ef2a264bde91]
        public typealias RpcCallOperation = @Sendable (RpcCallInput) async throws -> RpcCallOutput
        // parity: client/src/effect/api/api.ts#RpcApi [status=implemented hash=2e00db4cf5b2]
        public typealias RpcApi = RpcClientAPI
        /// `types` takes any server event type, including `experimental.job.updated`.
        // parity: client/src/effect/api/api.ts#EventSubscribeInput [status=implemented hash=e916039a2006]
        public typealias EventSubscribeInput = PromiseInputTypes.EventSubscribeInput
        // parity: client/src/effect/api/api.ts#EventSubscribeOutput [status=implemented hash=1018d0124b49]
        public typealias EventSubscribeOutput = OpenCodeProtocol.OpenCodeEvent
        // parity: client/src/effect/api/api.ts#EventSubscribeOperation [status=implemented hash=94022a2530a5]
        public typealias EventSubscribeOperation = @Sendable (EventSubscribeInput?) -> AsyncThrowingStream<EventSubscribeOutput, any Error>
        // parity: client/src/effect/api/api.ts#EventApi [status=implemented hash=f8d1b1ad5bf1]
        public typealias EventApi = EffectEventAPI
        // parity: client/src/effect/api/api.ts#PtyListInput [status=implemented hash=dfc8d63403b9]
        public typealias PtyListInput = PromiseInputTypes.PtyListInput
        // parity: client/src/effect/api/api.ts#PtyListOutput [status=implemented hash=369a5a976bf9]
        public typealias PtyListOutput = LocationSchema.ResponseEnvelope<[PtySchema.Info]>
        // parity: client/src/effect/api/api.ts#PtyListOperation [status=implemented hash=8d62612164db]
        public typealias PtyListOperation = @Sendable (PtyListInput?) async throws -> PtyListOutput
        // parity: client/src/effect/api/api.ts#PtyCreateInput [status=implemented hash=90e2c1eac2b2]
        public typealias PtyCreateInput = PromiseInputTypes.PtyCreateInput
        // parity: client/src/effect/api/api.ts#PtyCreateOutput [status=implemented hash=57deca1ecb2f]
        public typealias PtyCreateOutput = LocationSchema.ResponseEnvelope<PtySchema.Info>
        // parity: client/src/effect/api/api.ts#PtyCreateOperation [status=implemented hash=cbf2e0b512d2]
        public typealias PtyCreateOperation = @Sendable (PtyCreateInput?) async throws -> PtyCreateOutput
        // parity: client/src/effect/api/api.ts#PtyGetInput [status=implemented hash=a3e4e74fb812]
        public typealias PtyGetInput = PromiseInputTypes.PtyGetInput
        // parity: client/src/effect/api/api.ts#PtyGetOutput [status=implemented hash=9f7d8486f771]
        public typealias PtyGetOutput = LocationSchema.ResponseEnvelope<PtySchema.Info>
        // parity: client/src/effect/api/api.ts#PtyGetOperation [status=implemented hash=26ecce6229d8]
        public typealias PtyGetOperation = @Sendable (PtyGetInput) async throws -> PtyGetOutput
        // parity: client/src/effect/api/api.ts#PtyUpdateInput [status=implemented hash=cc91f80a4a94]
        public typealias PtyUpdateInput = PromiseInputTypes.PtyUpdateInput
        // parity: client/src/effect/api/api.ts#PtyUpdateOutput [status=implemented hash=ee94e606aef3]
        public typealias PtyUpdateOutput = LocationSchema.ResponseEnvelope<PtySchema.Info>
        // parity: client/src/effect/api/api.ts#PtyUpdateOperation [status=implemented hash=fdb9821686fe]
        public typealias PtyUpdateOperation = @Sendable (PtyUpdateInput) async throws -> PtyUpdateOutput
        // parity: client/src/effect/api/api.ts#PtyRemoveInput [status=implemented hash=61f2e03ba685]
        public typealias PtyRemoveInput = PromiseInputTypes.PtyRemoveInput
        // parity: client/src/effect/api/api.ts#PtyRemoveOutput [status=implemented hash=f1f92da4a1a0]
        public typealias PtyRemoveOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#PtyRemoveOperation [status=implemented hash=9f2f520da368]
        public typealias PtyRemoveOperation = @Sendable (PtyRemoveInput) async throws -> PtyRemoveOutput
        // parity: client/src/effect/api/api.ts#PtyConnectTokenInput [status=implemented hash=afcd52112763]
        public typealias PtyConnectTokenInput = PromiseInputTypes.PtyConnectTokenInput
        // parity: client/src/effect/api/api.ts#PtyConnectTokenOutput [status=implemented hash=7095411a249a]
        public typealias PtyConnectTokenOutput = LocationSchema.ResponseEnvelope<PtyTicketSchema.ConnectToken>
        // parity: client/src/effect/api/api.ts#PtyConnectTokenOperation [status=implemented hash=d2039c819b02]
        public typealias PtyConnectTokenOperation = @Sendable (PtyConnectTokenInput) async throws -> PtyConnectTokenOutput
        // parity: client/src/effect/api/api.ts#PtyApi [status=implemented hash=328f7e9335f3]
        public typealias PtyApi = PtyClientAPI
        // parity: client/src/effect/api/api.ts#ExperimentalPersistentPtyReadInput [status=implemented hash=f965509c66c5]
        public typealias ExperimentalPersistentPtyReadInput = PromiseInputTypes.ExperimentalPersistentPtyReadInput
        // parity: client/src/effect/api/api.ts#ExperimentalPersistentPtyReadOutput [status=implemented hash=c62413155ff5]
        public typealias ExperimentalPersistentPtyReadOutput = PersistentPtySchema.ReadResult?
        // parity: client/src/effect/api/api.ts#ExperimentalPersistentPtyReadOperation [status=implemented hash=e3389ce02cb9]
        public typealias ExperimentalPersistentPtyReadOperation = @Sendable (ExperimentalPersistentPtyReadInput) async throws -> ExperimentalPersistentPtyReadOutput
        // parity: client/src/effect/api/api.ts#ExperimentalPersistentPtyListInput [status=implemented hash=7ffb52455452]
        public typealias ExperimentalPersistentPtyListInput = PromiseInputTypes.ExperimentalPersistentPtyListInput
        // parity: client/src/effect/api/api.ts#ExperimentalPersistentPtyListOutput [status=implemented hash=0148adb163db]
        public typealias ExperimentalPersistentPtyListOutput = [PersistentPtySchema.Info]
        // parity: client/src/effect/api/api.ts#ExperimentalPersistentPtyListOperation [status=implemented hash=9bd6728a2a8b]
        public typealias ExperimentalPersistentPtyListOperation = @Sendable (ExperimentalPersistentPtyListInput) async throws -> ExperimentalPersistentPtyListOutput
        // parity: client/src/effect/api/api.ts#ExperimentalPersistentPtyCreateInput [status=implemented hash=67af9f189001]
        public typealias ExperimentalPersistentPtyCreateInput = PromiseInputTypes.ExperimentalPersistentPtyCreateInput
        // parity: client/src/effect/api/api.ts#ExperimentalPersistentPtyCreateOutput [status=implemented hash=682aafe8a777]
        public typealias ExperimentalPersistentPtyCreateOutput = PersistentPtySchema.Info
        // parity: client/src/effect/api/api.ts#ExperimentalPersistentPtyCreateOperation [status=implemented hash=6a59f2ba21e5]
        public typealias ExperimentalPersistentPtyCreateOperation = @Sendable (ExperimentalPersistentPtyCreateInput) async throws -> ExperimentalPersistentPtyCreateOutput
        // parity: client/src/effect/api/api.ts#ExperimentalPersistentPtyShutdownOutput [status=implemented hash=1ed23324ee74]
        public typealias ExperimentalPersistentPtyShutdownOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#ExperimentalPersistentPtyShutdownOperation [status=implemented hash=2b1f8fc3867b]
        public typealias ExperimentalPersistentPtyShutdownOperation = @Sendable () async throws -> ExperimentalPersistentPtyShutdownOutput
        // parity: client/src/effect/api/api.ts#ExperimentalPersistentPtyHandoffOutput [status=implemented hash=d83820ac17f1]
        public typealias ExperimentalPersistentPtyHandoffOutput = PersistentPtyHandoffResponse
        // parity: client/src/effect/api/api.ts#ExperimentalPersistentPtyHandoffOperation [status=implemented hash=2189920d7e3c]
        public typealias ExperimentalPersistentPtyHandoffOperation = @Sendable () async throws -> ExperimentalPersistentPtyHandoffOutput
        // parity: client/src/effect/api/api.ts#ExperimentalPersistentPtyGetInput [status=implemented hash=1caa2ae1a80a]
        public typealias ExperimentalPersistentPtyGetInput = PromiseInputTypes.ExperimentalPersistentPtyGetInput
        // parity: client/src/effect/api/api.ts#ExperimentalPersistentPtyGetOutput [status=implemented hash=13c63df1010e]
        public typealias ExperimentalPersistentPtyGetOutput = PersistentPtySchema.Info
        // parity: client/src/effect/api/api.ts#ExperimentalPersistentPtyGetOperation [status=implemented hash=e99992febbd9]
        public typealias ExperimentalPersistentPtyGetOperation = @Sendable (ExperimentalPersistentPtyGetInput) async throws -> ExperimentalPersistentPtyGetOutput
        // parity: client/src/effect/api/api.ts#ExperimentalPersistentPtyUpdateInput [status=implemented hash=5eb308ec93a5]
        public typealias ExperimentalPersistentPtyUpdateInput = PromiseInputTypes.ExperimentalPersistentPtyUpdateInput
        // parity: client/src/effect/api/api.ts#ExperimentalPersistentPtyUpdateOutput [status=implemented hash=4a8ebeba2cf6]
        public typealias ExperimentalPersistentPtyUpdateOutput = PersistentPtySchema.Info
        // parity: client/src/effect/api/api.ts#ExperimentalPersistentPtyUpdateOperation [status=implemented hash=1ccaed15bb2b]
        public typealias ExperimentalPersistentPtyUpdateOperation = @Sendable (ExperimentalPersistentPtyUpdateInput) async throws -> ExperimentalPersistentPtyUpdateOutput
        // parity: client/src/effect/api/api.ts#ExperimentalPersistentPtySnapshotInput [status=implemented hash=d764e5c7ca5d]
        public typealias ExperimentalPersistentPtySnapshotInput = PromiseInputTypes.ExperimentalPersistentPtySnapshotInput
        // parity: client/src/effect/api/api.ts#ExperimentalPersistentPtySnapshotOutput [status=implemented hash=eddd3bc37217]
        public typealias ExperimentalPersistentPtySnapshotOutput = PersistentPtySchema.Snapshot
        // parity: client/src/effect/api/api.ts#ExperimentalPersistentPtySnapshotOperation [status=implemented hash=a87911215d24]
        public typealias ExperimentalPersistentPtySnapshotOperation = @Sendable (ExperimentalPersistentPtySnapshotInput) async throws -> ExperimentalPersistentPtySnapshotOutput
        // parity: client/src/effect/api/api.ts#ExperimentalPersistentPtyRemoveInput [status=implemented hash=6579d1094aeb]
        public typealias ExperimentalPersistentPtyRemoveInput = PromiseInputTypes.ExperimentalPersistentPtyRemoveInput
        // parity: client/src/effect/api/api.ts#ExperimentalPersistentPtyRemoveOutput [status=implemented hash=99f675ad905c]
        public typealias ExperimentalPersistentPtyRemoveOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#ExperimentalPersistentPtyRemoveOperation [status=implemented hash=22418f57235e]
        public typealias ExperimentalPersistentPtyRemoveOperation = @Sendable (ExperimentalPersistentPtyRemoveInput) async throws -> ExperimentalPersistentPtyRemoveOutput
        // parity: client/src/effect/api/api.ts#ExperimentalPersistentPtyConnectTokenInput [status=implemented hash=db876810e013]
        public typealias ExperimentalPersistentPtyConnectTokenInput = PromiseInputTypes.ExperimentalPersistentPtyConnectTokenInput
        // parity: client/src/effect/api/api.ts#ExperimentalPersistentPtyConnectTokenOutput [status=implemented hash=650fc8fc3943]
        public typealias ExperimentalPersistentPtyConnectTokenOutput = PtyTicketSchema.ConnectToken
        // parity: client/src/effect/api/api.ts#ExperimentalPersistentPtyConnectTokenOperation [status=implemented hash=c0430271c630]
        public typealias ExperimentalPersistentPtyConnectTokenOperation = @Sendable (ExperimentalPersistentPtyConnectTokenInput) async throws -> ExperimentalPersistentPtyConnectTokenOutput
        // parity: client/src/effect/api/api.ts#ExperimentalAutomationCreateInput [status=implemented hash=f201db232093]
        public typealias ExperimentalAutomationCreateInput = PromiseInputTypes.ExperimentalAutomationCreateInput
        // parity: client/src/effect/api/api.ts#ExperimentalAutomationCreateOutput [status=implemented hash=5f37599cde6d]
        public typealias ExperimentalAutomationCreateOutput = AutomationSchema.Info
        // parity: client/src/effect/api/api.ts#ExperimentalAutomationCreateOperation [status=implemented hash=7335d50049d3]
        public typealias ExperimentalAutomationCreateOperation = @Sendable (ExperimentalAutomationCreateInput) async throws -> ExperimentalAutomationCreateOutput
        // parity: client/src/effect/api/api.ts#ExperimentalAutomationListInput [status=implemented hash=92be48df5d20]
        public typealias ExperimentalAutomationListInput = PromiseInputTypes.ExperimentalAutomationListInput
        // parity: client/src/effect/api/api.ts#ExperimentalAutomationListOutput [status=implemented hash=10837dd2288a]
        public typealias ExperimentalAutomationListOutput = [AutomationSchema.Info]
        // parity: client/src/effect/api/api.ts#ExperimentalAutomationListOperation [status=implemented hash=09a92b6e9373]
        public typealias ExperimentalAutomationListOperation = @Sendable (ExperimentalAutomationListInput?) async throws -> ExperimentalAutomationListOutput
        // parity: client/src/effect/api/api.ts#ExperimentalAutomationGetInput [status=implemented hash=097fa1e8f728]
        public typealias ExperimentalAutomationGetInput = PromiseInputTypes.ExperimentalAutomationGetInput
        // parity: client/src/effect/api/api.ts#ExperimentalAutomationGetOutput [status=implemented hash=73c752afca05]
        public typealias ExperimentalAutomationGetOutput = AutomationSchema.Info
        // parity: client/src/effect/api/api.ts#ExperimentalAutomationGetOperation [status=implemented hash=27699c41dafd]
        public typealias ExperimentalAutomationGetOperation = @Sendable (ExperimentalAutomationGetInput) async throws -> ExperimentalAutomationGetOutput
        // parity: client/src/effect/api/api.ts#ExperimentalAutomationPauseInput [status=implemented hash=0ea646026019]
        public typealias ExperimentalAutomationPauseInput = PromiseInputTypes.ExperimentalAutomationPauseInput
        // parity: client/src/effect/api/api.ts#ExperimentalAutomationPauseOutput [status=implemented hash=fcfbf6c03b44]
        public typealias ExperimentalAutomationPauseOutput = AutomationSchema.Info
        // parity: client/src/effect/api/api.ts#ExperimentalAutomationPauseOperation [status=implemented hash=10fe88045fa4]
        public typealias ExperimentalAutomationPauseOperation = @Sendable (ExperimentalAutomationPauseInput) async throws -> ExperimentalAutomationPauseOutput
        // parity: client/src/effect/api/api.ts#ExperimentalAutomationResumeInput [status=implemented hash=14e39f804d35]
        public typealias ExperimentalAutomationResumeInput = PromiseInputTypes.ExperimentalAutomationResumeInput
        // parity: client/src/effect/api/api.ts#ExperimentalAutomationResumeOutput [status=implemented hash=94e4d84c7e74]
        public typealias ExperimentalAutomationResumeOutput = AutomationSchema.Info
        // parity: client/src/effect/api/api.ts#ExperimentalAutomationResumeOperation [status=implemented hash=8c04365bd081]
        public typealias ExperimentalAutomationResumeOperation = @Sendable (ExperimentalAutomationResumeInput) async throws -> ExperimentalAutomationResumeOutput
        // parity: client/src/effect/api/api.ts#ExperimentalAutomationDeleteInput [status=implemented hash=623c39eaef9e]
        public typealias ExperimentalAutomationDeleteInput = PromiseInputTypes.ExperimentalAutomationDeleteInput
        // parity: client/src/effect/api/api.ts#ExperimentalAutomationDeleteOutput [status=implemented hash=38103a7850e7]
        public typealias ExperimentalAutomationDeleteOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#ExperimentalAutomationDeleteOperation [status=implemented hash=46a6452f554e]
        public typealias ExperimentalAutomationDeleteOperation = @Sendable (ExperimentalAutomationDeleteInput) async throws -> ExperimentalAutomationDeleteOutput
        // parity: client/src/effect/api/api.ts#ExperimentalArtifactsProvidersInput [status=implemented hash=0f30e7b1a235]
        public typealias ExperimentalArtifactsProvidersInput = PromiseInputTypes.ExperimentalArtifactsProvidersInput
        // parity: client/src/effect/api/api.ts#ExperimentalArtifactsProvidersOutput [status=implemented hash=1e3b6bfede6f]
        public typealias ExperimentalArtifactsProvidersOutput = LocationSchema.ResponseEnvelope<[ArtifactSchema.Provider]>
        // parity: client/src/effect/api/api.ts#ExperimentalArtifactsProvidersOperation [status=implemented hash=9f4ad2c5ae33]
        public typealias ExperimentalArtifactsProvidersOperation = @Sendable (ExperimentalArtifactsProvidersInput?) async throws -> ExperimentalArtifactsProvidersOutput
        // parity: client/src/effect/api/api.ts#ExperimentalArtifactsListInput [status=implemented hash=0c5996deda96]
        public typealias ExperimentalArtifactsListInput = PromiseInputTypes.ExperimentalArtifactsListInput
        // parity: client/src/effect/api/api.ts#ExperimentalArtifactsListOutput [status=implemented hash=b03d5c390726]
        public typealias ExperimentalArtifactsListOutput = LocationSchema.ResponseEnvelope<[ArtifactSchema.Info]>
        // parity: client/src/effect/api/api.ts#ExperimentalArtifactsListOperation [status=implemented hash=ff41487c41ba]
        public typealias ExperimentalArtifactsListOperation = @Sendable (ExperimentalArtifactsListInput?) async throws -> ExperimentalArtifactsListOutput
        // parity: client/src/effect/api/api.ts#ExperimentalArtifactsCreateInput [status=implemented hash=0f5dc4522183]
        public typealias ExperimentalArtifactsCreateInput = PromiseInputTypes.ExperimentalArtifactsCreateInput
        // parity: client/src/effect/api/api.ts#ExperimentalArtifactsCreateOutput [status=implemented hash=a8a9d5234768]
        public typealias ExperimentalArtifactsCreateOutput = LocationSchema.ResponseEnvelope<ArtifactSchema.Info>
        // parity: client/src/effect/api/api.ts#ExperimentalArtifactsCreateOperation [status=implemented hash=eee78e7ade93]
        public typealias ExperimentalArtifactsCreateOperation = @Sendable (ExperimentalArtifactsCreateInput) async throws -> ExperimentalArtifactsCreateOutput
        // parity: client/src/effect/api/api.ts#ExperimentalArtifactsGetInput [status=implemented hash=408cbf95bb88]
        public typealias ExperimentalArtifactsGetInput = PromiseInputTypes.ExperimentalArtifactsGetInput
        // parity: client/src/effect/api/api.ts#ExperimentalArtifactsGetOutput [status=implemented hash=9374cd42b843]
        public typealias ExperimentalArtifactsGetOutput = LocationSchema.ResponseEnvelope<ArtifactSchema.Content>
        // parity: client/src/effect/api/api.ts#ExperimentalArtifactsGetOperation [status=implemented hash=11761a05ca56]
        public typealias ExperimentalArtifactsGetOperation = @Sendable (ExperimentalArtifactsGetInput) async throws -> ExperimentalArtifactsGetOutput
        // parity: client/src/effect/api/api.ts#ExperimentalArtifactsUpdateInput [status=implemented hash=d24b4161b196]
        public typealias ExperimentalArtifactsUpdateInput = PromiseInputTypes.ExperimentalArtifactsUpdateInput
        // parity: client/src/effect/api/api.ts#ExperimentalArtifactsUpdateOutput [status=implemented hash=ac7c991538ef]
        public typealias ExperimentalArtifactsUpdateOutput = LocationSchema.ResponseEnvelope<ArtifactSchema.Info>
        // parity: client/src/effect/api/api.ts#ExperimentalArtifactsUpdateOperation [status=implemented hash=e97df89219e0]
        public typealias ExperimentalArtifactsUpdateOperation = @Sendable (ExperimentalArtifactsUpdateInput) async throws -> ExperimentalArtifactsUpdateOutput
        // parity: client/src/effect/api/api.ts#ExperimentalArtifactsDeleteInput [status=implemented hash=c814f81c7744]
        public typealias ExperimentalArtifactsDeleteInput = PromiseInputTypes.ExperimentalArtifactsDeleteInput
        // parity: client/src/effect/api/api.ts#ExperimentalArtifactsDeleteOutput [status=implemented hash=ea2d2a926f2a]
        public typealias ExperimentalArtifactsDeleteOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#ExperimentalArtifactsDeleteOperation [status=implemented hash=16c5699769d9]
        public typealias ExperimentalArtifactsDeleteOperation = @Sendable (ExperimentalArtifactsDeleteInput) async throws -> ExperimentalArtifactsDeleteOutput
        // parity: client/src/effect/api/api.ts#ExperimentalJobListInput [status=implemented hash=b5149ce0b521]
        public typealias ExperimentalJobListInput = PromiseInputTypes.ExperimentalJobListInput
        // parity: client/src/effect/api/api.ts#ExperimentalJobListOutput [status=implemented hash=27d29c1977d2]
        public typealias ExperimentalJobListOutput = [JobSchema.Info]
        // parity: client/src/effect/api/api.ts#ExperimentalJobListOperation [status=implemented hash=dafb3609e811]
        public typealias ExperimentalJobListOperation = @Sendable (ExperimentalJobListInput?) async throws -> ExperimentalJobListOutput
        // parity: client/src/effect/api/api.ts#ExperimentalJobCancelInput [status=implemented hash=0cfccab209ce]
        public typealias ExperimentalJobCancelInput = PromiseInputTypes.ExperimentalJobCancelInput
        // parity: client/src/effect/api/api.ts#ExperimentalJobCancelOutput [status=implemented hash=3ca7b13e8938]
        public typealias ExperimentalJobCancelOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#ExperimentalJobCancelOperation [status=implemented hash=219488dbb8af]
        public typealias ExperimentalJobCancelOperation = @Sendable (ExperimentalJobCancelInput) async throws -> Void
        /// `job` offers `list` and `cancel`.
        // parity: client/src/effect/api/api.ts#ExperimentalApi [status=implemented hash=e85ab6ec7928]
        public typealias ExperimentalApi = ExperimentalClientAPI
        // parity: client/src/effect/api/api.ts#ShellListInput [status=implemented hash=0f4202e34c0b]
        public typealias ShellListInput = PromiseInputTypes.ShellListInput
        // parity: client/src/effect/api/api.ts#ShellListOutput [status=implemented hash=2206a0ea75ce]
        public typealias ShellListOutput = LocationSchema.ResponseEnvelope<[ShellSchema.Info]>
        // parity: client/src/effect/api/api.ts#ShellListOperation [status=implemented hash=0e711e3add1a]
        public typealias ShellListOperation = @Sendable (ShellListInput?) async throws -> ShellListOutput
        // parity: client/src/effect/api/api.ts#ShellCreateInput [status=implemented hash=ad4ad2623e95]
        public typealias ShellCreateInput = PromiseInputTypes.ShellCreateInput
        // parity: client/src/effect/api/api.ts#ShellCreateOutput [status=implemented hash=7330e9a907fd]
        public typealias ShellCreateOutput = LocationSchema.ResponseEnvelope<ShellSchema.Info>
        // parity: client/src/effect/api/api.ts#ShellCreateOperation [status=implemented hash=67aba724fea7]
        public typealias ShellCreateOperation = @Sendable (ShellCreateInput) async throws -> ShellCreateOutput
        // parity: client/src/effect/api/api.ts#ShellGetInput [status=implemented hash=964cdbac7cdb]
        public typealias ShellGetInput = PromiseInputTypes.ShellGetInput
        // parity: client/src/effect/api/api.ts#ShellGetOutput [status=implemented hash=aa7d3a68d27a]
        public typealias ShellGetOutput = LocationSchema.ResponseEnvelope<ShellSchema.Info>
        // parity: client/src/effect/api/api.ts#ShellGetOperation [status=implemented hash=c240de115403]
        public typealias ShellGetOperation = @Sendable (ShellGetInput) async throws -> ShellGetOutput
        // parity: client/src/effect/api/api.ts#ShellOutputInput [status=implemented hash=8f3a97df0447]
        public typealias ShellOutputInput = PromiseInputTypes.ShellOutputInput
        // parity: client/src/effect/api/api.ts#ShellOutputOutput [status=implemented hash=2d19379eb468]
        public typealias ShellOutputOutput = LocationSchema.ResponseEnvelope<ShellSchema.Output>
        // parity: client/src/effect/api/api.ts#ShellOutputOperation [status=implemented hash=f06d865be242]
        public typealias ShellOutputOperation = @Sendable (ShellOutputInput) async throws -> ShellOutputOutput
        // parity: client/src/effect/api/api.ts#ShellRemoveInput [status=implemented hash=a2932f9a7605]
        public typealias ShellRemoveInput = PromiseInputTypes.ShellRemoveInput
        // parity: client/src/effect/api/api.ts#ShellRemoveOutput [status=implemented hash=1053fd9901a5]
        public typealias ShellRemoveOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#ShellRemoveOperation [status=implemented hash=514b423c0829]
        public typealias ShellRemoveOperation = @Sendable (ShellRemoveInput) async throws -> ShellRemoveOutput
        // parity: client/src/effect/api/api.ts#ShellApi [status=implemented hash=d6ef15cea4db]
        public typealias ShellApi = ShellClientAPI
        // parity: client/src/effect/api/api.ts#ReferenceListInput [status=implemented hash=b2964bce60eb]
        public typealias ReferenceListInput = PromiseInputTypes.ReferenceListInput
        // parity: client/src/effect/api/api.ts#ReferenceListOutput [status=implemented hash=d33985d65a22]
        public typealias ReferenceListOutput = LocationSchema.ResponseEnvelope<[ReferenceSchema.Info]>
        // parity: client/src/effect/api/api.ts#ReferenceListOperation [status=implemented hash=94b857df3cb1]
        public typealias ReferenceListOperation = @Sendable (ReferenceListInput?) async throws -> ReferenceListOutput
        // parity: client/src/effect/api/api.ts#ReferenceApi [status=implemented hash=5422f763ba0f]
        public typealias ReferenceApi = ReferenceClientAPI
        // parity: client/src/effect/api/api.ts#WorktreeListInput [status=implemented hash=7a24bfecb909]
        public typealias WorktreeListInput = PromiseInputTypes.WorktreeListInput
        // parity: client/src/effect/api/api.ts#WorktreeListOutput [status=implemented hash=1b6995126199]
        public typealias WorktreeListOutput = WorktreeSchema.List
        // parity: client/src/effect/api/api.ts#WorktreeListOperation [status=implemented hash=647060d6bb36]
        public typealias WorktreeListOperation = @Sendable (WorktreeListInput) async throws -> WorktreeListOutput
        // parity: client/src/effect/api/api.ts#WorktreeCreateInput [status=implemented hash=54238b6c3367]
        public typealias WorktreeCreateInput = PromiseInputTypes.WorktreeCreateInput
        // parity: client/src/effect/api/api.ts#WorktreeCreateOutput [status=implemented hash=75a55b7f7cb5]
        public typealias WorktreeCreateOutput = WorktreeSchema.Info
        // parity: client/src/effect/api/api.ts#WorktreeCreateOperation [status=implemented hash=49d7374b7752]
        public typealias WorktreeCreateOperation = @Sendable (WorktreeCreateInput) async throws -> WorktreeCreateOutput
        // parity: client/src/effect/api/api.ts#WorktreeRemoveInput [status=implemented hash=a2a0b5af3d4b]
        public typealias WorktreeRemoveInput = PromiseInputTypes.WorktreeRemoveInput
        // parity: client/src/effect/api/api.ts#WorktreeRemoveOutput [status=implemented hash=966327baf5eb]
        public typealias WorktreeRemoveOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#WorktreeRemoveOperation [status=implemented hash=3be25efbf705]
        public typealias WorktreeRemoveOperation = @Sendable (WorktreeRemoveInput) async throws -> WorktreeRemoveOutput
        // parity: client/src/effect/api/api.ts#WorktreeRefreshInput [status=implemented hash=d5e108c39135]
        public typealias WorktreeRefreshInput = PromiseInputTypes.WorktreeRefreshInput
        // parity: client/src/effect/api/api.ts#WorktreeRefreshOutput [status=implemented hash=6e99b77c3972]
        public typealias WorktreeRefreshOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#WorktreeRefreshOperation [status=implemented hash=f81f2bc5f915]
        public typealias WorktreeRefreshOperation = @Sendable (WorktreeRefreshInput) async throws -> WorktreeRefreshOutput
        // parity: client/src/effect/api/api.ts#WorktreeApi [status=implemented hash=982f30ee2f9a]
        public typealias WorktreeApi = WorktreeClientAPI
        // parity: client/src/effect/api/api.ts#VcsInitInput [status=implemented hash=2a678477d0a6]
        public typealias VcsInitInput = PromiseInputTypes.VcsInitInput
        // parity: client/src/effect/api/api.ts#VcsInitOutput [status=implemented hash=118154a31976]
        public typealias VcsInitOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#VcsInitOperation [status=implemented hash=d86920a56271]
        public typealias VcsInitOperation = @Sendable (VcsInitInput?) async throws -> VcsInitOutput
        // parity: client/src/effect/api/api.ts#VcsGetInput [status=implemented hash=e23e1431598d]
        public typealias VcsGetInput = PromiseInputTypes.VcsGetInput
        // parity: client/src/effect/api/api.ts#VcsGetOutput [status=implemented hash=1bc9bdf07f01]
        public typealias VcsGetOutput = LocationSchema.ResponseEnvelope<VcsSchema.Info>
        // parity: client/src/effect/api/api.ts#VcsGetOperation [status=implemented hash=5f0bbb490fda]
        public typealias VcsGetOperation = @Sendable (VcsGetInput?) async throws -> VcsGetOutput
        // parity: client/src/effect/api/api.ts#VcsBaseInput [status=implemented hash=0b75e825dc65]
        public typealias VcsBaseInput = PromiseInputTypes.VcsBaseInput
        // parity: client/src/effect/api/api.ts#VcsBaseOutput [status=implemented hash=465bf70d5415]
        public typealias VcsBaseOutput = LocationSchema.ResponseEnvelope<VcsSchema.Base?>
        // parity: client/src/effect/api/api.ts#VcsBaseOperation [status=implemented hash=f9f400415599]
        public typealias VcsBaseOperation = @Sendable (VcsBaseInput?) async throws -> VcsBaseOutput
        // parity: client/src/effect/api/api.ts#VcsStatusInput [status=implemented hash=b62c51f637d2]
        public typealias VcsStatusInput = PromiseInputTypes.VcsStatusInput
        // parity: client/src/effect/api/api.ts#VcsStatusOutput [status=implemented hash=a462133aaad5]
        public typealias VcsStatusOutput = LocationSchema.ResponseEnvelope<[VcsSchema.FileStatus]>
        // parity: client/src/effect/api/api.ts#VcsStatusOperation [status=implemented hash=1d6503d8e383]
        public typealias VcsStatusOperation = @Sendable (VcsStatusInput?) async throws -> VcsStatusOutput
        // parity: client/src/effect/api/api.ts#VcsBranchListInput [status=implemented hash=e804c8db0000]
        public typealias VcsBranchListInput = PromiseInputTypes.VcsBranchListInput
        // parity: client/src/effect/api/api.ts#VcsBranchListOutput [status=implemented hash=62cde663882d]
        public typealias VcsBranchListOutput = LocationSchema.ResponseEnvelope<VcsSchema.BranchList>
        // parity: client/src/effect/api/api.ts#VcsBranchListOperation [status=implemented hash=b58ace500048]
        public typealias VcsBranchListOperation = @Sendable (VcsBranchListInput?) async throws -> VcsBranchListOutput
        // parity: client/src/effect/api/api.ts#VcsDiffInput [status=implemented hash=6bd2dfc6ec70]
        public typealias VcsDiffInput = PromiseInputTypes.VcsDiffInput
        // parity: client/src/effect/api/api.ts#VcsDiffOutput [status=implemented hash=b8f95d2f3b2a]
        public typealias VcsDiffOutput = LocationSchema.ResponseEnvelope<[FileDiffSchema.Info]>
        // parity: client/src/effect/api/api.ts#VcsDiffOperation [status=implemented hash=2bee3be464c6]
        public typealias VcsDiffOperation = @Sendable (VcsDiffInput) async throws -> VcsDiffOutput
        // parity: client/src/effect/api/api.ts#VcsApi [status=implemented hash=3ae8bd217a09]
        public typealias VcsApi = VcsClientAPI
        // parity: client/src/effect/api/api.ts#DebugHeapDumpInput [status=implemented hash=efb23e8eb793]
        public typealias DebugHeapDumpInput = PromiseInputTypes.DebugHeapDumpInput
        // parity: client/src/effect/api/api.ts#DebugHeapDumpOutput [status=implemented hash=67fc0068aab1]
        public typealias DebugHeapDumpOutput = ClientDebugHeapDumpOutput
        // parity: client/src/effect/api/api.ts#DebugHeapDumpOperation [status=implemented hash=773f341eb3c2]
        public typealias DebugHeapDumpOperation = @Sendable (DebugHeapDumpInput?) async throws -> DebugHeapDumpOutput
        // parity: client/src/effect/api/api.ts#DebugLocationListOutput [status=implemented hash=6a42e1a1fd88]
        public typealias DebugLocationListOutput = [LocationSchema.PublicRef]
        // parity: client/src/effect/api/api.ts#DebugLocationListOperation [status=implemented hash=019cc5174766]
        public typealias DebugLocationListOperation = @Sendable () async throws -> DebugLocationListOutput
        // parity: client/src/effect/api/api.ts#DebugLocationEvictInput [status=implemented hash=c134d2b85a31]
        public typealias DebugLocationEvictInput = PromiseInputTypes.DebugLocationEvictInput
        // parity: client/src/effect/api/api.ts#DebugLocationEvictOutput [status=implemented hash=430ec551a4b9]
        public typealias DebugLocationEvictOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#DebugLocationEvictOperation [status=implemented hash=04aeda3e2a2f]
        public typealias DebugLocationEvictOperation = @Sendable (DebugLocationEvictInput?) async throws -> DebugLocationEvictOutput
        // parity: client/src/effect/api/api.ts#DebugApi [status=implemented hash=b13ded4a6bc3]
        public typealias DebugApi = DebugClientAPI
        // parity: client/src/effect/api/api.ts#ExperimentalMigrationV1StatusOutput [status=implemented hash=6d4b08bf1671]
        public typealias ExperimentalMigrationV1StatusOutput = OpenCodeProtocol.V1MigrationStatus
        // parity: client/src/effect/api/api.ts#ExperimentalMigrationV1StatusOperation [status=implemented hash=9836a9992e5f]
        public typealias ExperimentalMigrationV1StatusOperation = @Sendable () async throws -> ExperimentalMigrationV1StatusOutput
        // parity: client/src/effect/api/api.ts#ExperimentalMigrationApi [status=implemented hash=cac5ea1965d6]
        public typealias ExperimentalMigrationApi = ExperimentalMigrationClientAPI
        // parity: client/src/effect/api/api.ts#WebsearchProvidersInput [status=implemented hash=62e5bec09693]
        public typealias WebsearchProvidersInput = PromiseInputTypes.WebsearchProvidersInput
        // parity: client/src/effect/api/api.ts#WebsearchProvidersOutput [status=implemented hash=03fac8dce032]
        public typealias WebsearchProvidersOutput = LocationSchema.ResponseEnvelope<[WebSearchSchema.Provider]>
        // parity: client/src/effect/api/api.ts#WebsearchProvidersOperation [status=implemented hash=77e44aba291e]
        public typealias WebsearchProvidersOperation = @Sendable (WebsearchProvidersInput?) async throws -> WebsearchProvidersOutput
        // parity: client/src/effect/api/api.ts#WebsearchQueryInput [status=implemented hash=7270233db88e]
        public typealias WebsearchQueryInput = PromiseInputTypes.WebsearchQueryInput
        // parity: client/src/effect/api/api.ts#WebsearchQueryOutput [status=implemented hash=e65b306a8923]
        public typealias WebsearchQueryOutput = LocationSchema.ResponseEnvelope<WebSearchSchema.Response>
        // parity: client/src/effect/api/api.ts#WebsearchQueryOperation [status=implemented hash=9ce56df788a7]
        public typealias WebsearchQueryOperation = @Sendable (WebsearchQueryInput) async throws -> WebsearchQueryOutput
        // parity: client/src/effect/api/api.ts#WebsearchApi [status=implemented hash=4100bef6d4f5]
        public typealias WebsearchApi = WebsearchClientAPI
        // parity: client/src/effect/api/api.ts#ExperimentalUsageLimitsInput [status=implemented hash=8afd0d3bd2e3]
        public typealias ExperimentalUsageLimitsInput = PromiseInputTypes.ExperimentalUsageLimitsInput
        // parity: client/src/effect/api/api.ts#ExperimentalUsageLimitsOutput [status=implemented hash=50e5bd72bada]
        public typealias ExperimentalUsageLimitsOutput = LocationSchema.ResponseEnvelope<UsageLimitsSchema.Info?>
        // parity: client/src/effect/api/api.ts#ExperimentalUsageLimitsOperation [status=implemented hash=a9ceb82024c3]
        public typealias ExperimentalUsageLimitsOperation = @Sendable (ExperimentalUsageLimitsInput?) async throws -> ExperimentalUsageLimitsOutput
        // parity: client/src/effect/api/api.ts#ExperimentalUsageApi [status=implemented hash=3da4dbe801b6]
        public typealias ExperimentalUsageApi = ExperimentalUsageClientAPI
        // parity: client/src/effect/api/api.ts#ConfigGetInput [status=implemented hash=fc3e1ce3aa09]
        public typealias ConfigGetInput = PromiseInputTypes.ConfigGetInput
        // parity: client/src/effect/api/api.ts#ConfigGetOutput [status=implemented hash=cce9eef81434]
        public typealias ConfigGetOutput = [ConfigSchema.Entry]
        // parity: client/src/effect/api/api.ts#ConfigGetOperation [status=implemented hash=4fed076fbe89]
        public typealias ConfigGetOperation = @Sendable (ConfigGetInput?) async throws -> ConfigGetOutput
        // parity: client/src/effect/api/api.ts#ConfigShellsOutput [status=implemented hash=c5341ff0f4b4]
        public typealias ConfigShellsOutput = [ConfigShellSchema.Option]
        // parity: client/src/effect/api/api.ts#ConfigShellsOperation [status=implemented hash=ef392e02cbe5]
        public typealias ConfigShellsOperation = @Sendable () async throws -> ConfigShellsOutput
        // parity: client/src/effect/api/api.ts#ConfigApi [status=implemented hash=ce0d3cdcacaa]
        public typealias ConfigApi = ConfigClientAPI
        // parity: client/src/effect/api/api.ts#ExperimentalConfigUpdateInput [status=implemented hash=f76c1585597c]
        public typealias ExperimentalConfigUpdateInput = PromiseInputTypes.ExperimentalConfigUpdateInput
        // parity: client/src/effect/api/api.ts#ExperimentalConfigUpdateOutput [status=implemented hash=69978ae170aa]
        public typealias ExperimentalConfigUpdateOutput = ClientEmptyResponse
        // parity: client/src/effect/api/api.ts#ExperimentalConfigUpdateOperation [status=implemented hash=5610c4f678a4]
        public typealias ExperimentalConfigUpdateOperation = @Sendable (ExperimentalConfigUpdateInput) async throws -> ExperimentalConfigUpdateOutput
        // parity: client/src/effect/api/api.ts#ExperimentalConfigApi [status=implemented hash=2fcba69a585a]
        public typealias ExperimentalConfigApi = ExperimentalConfigClientAPI
        // parity: client/src/effect/api/api.ts#SessionStatsInput [status=implemented hash=ca109da1d0f1]
        public typealias SessionStatsInput = ExperimentalSessionStatsInput
        // parity: client/src/effect/api/api.ts#SessionStatsOutput [status=implemented hash=d9add1c87473]
        public typealias SessionStatsOutput = ExperimentalSessionStatsOutput
        // parity: client/src/effect/api/api.ts#SessionStatsOperation [status=implemented hash=b01603e9854b]
        public typealias SessionStatsOperation = ExperimentalSessionStatsOperation
        // parity: client/src/effect/api/api.ts#SessionImportInput [status=implemented hash=bfa36f7d9cdb]
        public typealias SessionImportInput = ExperimentalSessionImportInput
        // parity: client/src/effect/api/api.ts#SessionImportOutput [status=implemented hash=73fe60d36bba]
        public typealias SessionImportOutput = ExperimentalSessionImportOutput
        // parity: client/src/effect/api/api.ts#SessionImportOperation [status=implemented hash=dd662bbd1bb9]
        public typealias SessionImportOperation = ExperimentalSessionImportOperation
        // parity: client/src/effect/api/api.ts#SessionExportInput [status=implemented hash=62b5aa8da161]
        public typealias SessionExportInput = ExperimentalSessionExportInput
        // parity: client/src/effect/api/api.ts#SessionExportOutput [status=implemented hash=581bfa49f395]
        public typealias SessionExportOutput = ExperimentalSessionExportOutput
        // parity: client/src/effect/api/api.ts#SessionExportOperation [status=implemented hash=df075d789990]
        public typealias SessionExportOperation = ExperimentalSessionExportOperation
        // parity: client/src/effect/api/api.ts#SessionSkillInput [status=implemented hash=3c6c5dccfd60]
        public typealias SessionSkillInput = ExperimentalSessionSkillInput
        // parity: client/src/effect/api/api.ts#SessionSkillOutput [status=implemented hash=109b36cf99bc]
        public typealias SessionSkillOutput = ExperimentalSessionSkillOutput
        // parity: client/src/effect/api/api.ts#SessionSkillOperation [status=implemented hash=a2df27a99599]
        public typealias SessionSkillOperation = ExperimentalSessionSkillOperation
        // parity: client/src/effect/api/api.ts#SessionWaitInput [status=implemented hash=a84b4df3a46a]
        public typealias SessionWaitInput = ExperimentalSessionWaitInput
        // parity: client/src/effect/api/api.ts#SessionWaitOutput [status=implemented hash=3012cd2a68c1]
        public typealias SessionWaitOutput = ExperimentalSessionWaitOutput
        // parity: client/src/effect/api/api.ts#SessionWaitOperation [status=implemented hash=59ca92da5169]
        public typealias SessionWaitOperation = ExperimentalSessionWaitOperation
        // parity: client/src/effect/api/api.ts#SessionInstructionsEntryListInput [status=implemented hash=456a71115197]
        public typealias SessionInstructionsEntryListInput = ExperimentalSessionInstructionsEntryListInput
        // parity: client/src/effect/api/api.ts#SessionInstructionsEntryListOutput [status=implemented hash=8b4ec764ec8d]
        public typealias SessionInstructionsEntryListOutput = ExperimentalSessionInstructionsEntryListOutput
        // parity: client/src/effect/api/api.ts#SessionInstructionsEntryListOperation [status=implemented hash=e83a76ac06d0]
        public typealias SessionInstructionsEntryListOperation = ExperimentalSessionInstructionsEntryListOperation
        // parity: client/src/effect/api/api.ts#SessionInstructionsEntryPutInput [status=implemented hash=df593fb00c6f]
        public typealias SessionInstructionsEntryPutInput = ExperimentalSessionInstructionsEntryPutInput
        // parity: client/src/effect/api/api.ts#SessionInstructionsEntryPutOutput [status=implemented hash=c113ec309111]
        public typealias SessionInstructionsEntryPutOutput = ExperimentalSessionInstructionsEntryPutOutput
        // parity: client/src/effect/api/api.ts#SessionInstructionsEntryPutOperation [status=implemented hash=e9ec34f048ad]
        public typealias SessionInstructionsEntryPutOperation = ExperimentalSessionInstructionsEntryPutOperation
        // parity: client/src/effect/api/api.ts#SessionInstructionsEntryRemoveInput [status=implemented hash=e888c2ce0afb]
        public typealias SessionInstructionsEntryRemoveInput = ExperimentalSessionInstructionsEntryRemoveInput
        // parity: client/src/effect/api/api.ts#SessionInstructionsEntryRemoveOutput [status=implemented hash=4d3f1cdf36a8]
        public typealias SessionInstructionsEntryRemoveOutput = ExperimentalSessionInstructionsEntryRemoveOutput
        // parity: client/src/effect/api/api.ts#SessionInstructionsEntryRemoveOperation [status=implemented hash=02cacac725c8]
        public typealias SessionInstructionsEntryRemoveOperation = ExperimentalSessionInstructionsEntryRemoveOperation
        // parity: client/src/effect/api/api.ts#SessionLogInput [status=implemented hash=9d5c6bdab31d]
        public typealias SessionLogInput = ExperimentalSessionLogInput
        // parity: client/src/effect/api/api.ts#SessionLogOutput [status=implemented hash=23e7ac761662]
        public typealias SessionLogOutput = ExperimentalSessionLogOutput
        // parity: client/src/effect/api/api.ts#SessionLogOperation [status=implemented hash=c36c7b4c8178]
        public typealias SessionLogOperation = ExperimentalSessionLogOperation
        // parity: client/src/effect/api/api.ts#GenerateTextInput [status=implemented hash=37482ee578b6]
        public typealias GenerateTextInput = ExperimentalGenerateTextInput
        // parity: client/src/effect/api/api.ts#GenerateTextOutput [status=implemented hash=5bca7198e6cf]
        public typealias GenerateTextOutput = ExperimentalGenerateTextOutput
        // parity: client/src/effect/api/api.ts#GenerateTextOperation [status=implemented hash=cd143f5eced6]
        public typealias GenerateTextOperation = ExperimentalGenerateTextOperation
        // parity: client/src/effect/api/api.ts#GenerateImageInput [status=implemented hash=98114963a2c4]
        public typealias GenerateImageInput = ExperimentalGenerateImageInput
        // parity: client/src/effect/api/api.ts#GenerateImageOutput [status=implemented hash=f3902e2a6652]
        public typealias GenerateImageOutput = ExperimentalGenerateImageOutput
        // parity: client/src/effect/api/api.ts#GenerateImageOperation [status=implemented hash=4069a70f3cbb]
        public typealias GenerateImageOperation = ExperimentalGenerateImageOperation
        // parity: client/src/effect/api/api.ts#GenerateDecisionsInput [status=implemented hash=97e22369b832]
        public typealias GenerateDecisionsInput = ExperimentalGenerateDecisionsInput
        // parity: client/src/effect/api/api.ts#GenerateDecisionsOutput [status=implemented hash=b6ada0a6ebee]
        public typealias GenerateDecisionsOutput = ExperimentalGenerateDecisionsOutput
        // parity: client/src/effect/api/api.ts#GenerateDecisionsOperation [status=implemented hash=00de74e582c9]
        public typealias GenerateDecisionsOperation = ExperimentalGenerateDecisionsOperation
        // parity: client/src/effect/api/api.ts#VoiceModelsOutput [status=implemented hash=bf14a42fcc9b]
        public typealias VoiceModelsOutput = ExperimentalVoiceModelsOutput
        // parity: client/src/effect/api/api.ts#VoiceModelsOperation [status=implemented hash=d43fc704063d]
        public typealias VoiceModelsOperation = ExperimentalVoiceModelsOperation
        // parity: client/src/effect/api/api.ts#VoiceSessionInput [status=implemented hash=90a301331405]
        public typealias VoiceSessionInput = ExperimentalVoiceSessionInput
        // parity: client/src/effect/api/api.ts#VoiceSessionOutput [status=implemented hash=5aeaaa02d555]
        public typealias VoiceSessionOutput = ExperimentalVoiceSessionOutput
        // parity: client/src/effect/api/api.ts#VoiceSessionOperation [status=implemented hash=2049eb9b12fa]
        public typealias VoiceSessionOperation = ExperimentalVoiceSessionOperation
        // parity: client/src/effect/api/api.ts#IntegrationWellknownAddInput [status=implemented hash=bd0d1f3b7ff1]
        public typealias IntegrationWellknownAddInput = ExperimentalIntegrationWellknownAddInput
        // parity: client/src/effect/api/api.ts#IntegrationWellknownAddOutput [status=implemented hash=71fb0d519592]
        public typealias IntegrationWellknownAddOutput = ExperimentalIntegrationWellknownAddOutput
        // parity: client/src/effect/api/api.ts#IntegrationWellknownAddOperation [status=implemented hash=e3454d51d47e]
        public typealias IntegrationWellknownAddOperation = ExperimentalIntegrationWellknownAddOperation
        // parity: client/src/effect/api/api.ts#McpAddInput [status=implemented hash=65d020477b21]
        public typealias McpAddInput = ExperimentalMcpAddInput
        // parity: client/src/effect/api/api.ts#McpAddOutput [status=implemented hash=5313048d621e]
        public typealias McpAddOutput = ExperimentalMcpAddOutput
        // parity: client/src/effect/api/api.ts#McpAddOperation [status=implemented hash=5f96f1a15bf2]
        public typealias McpAddOperation = ExperimentalMcpAddOperation
        // parity: client/src/effect/api/api.ts#McpRemoveInput [status=implemented hash=60e08ac489eb]
        public typealias McpRemoveInput = ExperimentalMcpRemoveInput
        // parity: client/src/effect/api/api.ts#McpRemoveOutput [status=implemented hash=59e51c51ef99]
        public typealias McpRemoveOutput = ExperimentalMcpRemoveOutput
        // parity: client/src/effect/api/api.ts#McpRemoveOperation [status=implemented hash=42552c84b8e9]
        public typealias McpRemoveOperation = ExperimentalMcpRemoveOperation
        // parity: client/src/effect/api/api.ts#McpConnectInput [status=implemented hash=a786fa4ec762]
        public typealias McpConnectInput = ExperimentalMcpConnectInput
        // parity: client/src/effect/api/api.ts#McpConnectOutput [status=implemented hash=11efda9e9c7c]
        public typealias McpConnectOutput = ExperimentalMcpConnectOutput
        // parity: client/src/effect/api/api.ts#McpConnectOperation [status=implemented hash=7f1868639486]
        public typealias McpConnectOperation = ExperimentalMcpConnectOperation
        // parity: client/src/effect/api/api.ts#McpDisconnectInput [status=implemented hash=33b8b49139ed]
        public typealias McpDisconnectInput = ExperimentalMcpDisconnectInput
        // parity: client/src/effect/api/api.ts#McpDisconnectOutput [status=implemented hash=0001b08238ff]
        public typealias McpDisconnectOutput = ExperimentalMcpDisconnectOutput
        // parity: client/src/effect/api/api.ts#McpDisconnectOperation [status=implemented hash=657f160b1f07]
        public typealias McpDisconnectOperation = ExperimentalMcpDisconnectOperation
        // parity: client/src/effect/api/api.ts#McpClientTokenInput [status=implemented hash=72c03eb2193e]
        public typealias McpClientTokenInput = ExperimentalMcpClientTokenInput
        // parity: client/src/effect/api/api.ts#McpClientTokenOutput [status=implemented hash=600dc060da80]
        public typealias McpClientTokenOutput = ExperimentalMcpClientTokenOutput
        // parity: client/src/effect/api/api.ts#McpClientTokenOperation [status=implemented hash=e8f2e9a42e7c]
        public typealias McpClientTokenOperation = ExperimentalMcpClientTokenOperation
        // parity: client/src/effect/api/api.ts#FileWatchInput [status=implemented hash=4f5e177feea0]
        public typealias FileWatchInput = ExperimentalFileWatchInput
        // parity: client/src/effect/api/api.ts#FileWatchOutput [status=implemented hash=31be68d703e6]
        public typealias FileWatchOutput = ExperimentalFileWatchOutput
        // parity: client/src/effect/api/api.ts#FileWatchOperation [status=implemented hash=24883cfd783b]
        public typealias FileWatchOperation = ExperimentalFileWatchOperation
        // parity: client/src/effect/api/api.ts#FileUnwatchInput [status=implemented hash=7c3e8ca6528b]
        public typealias FileUnwatchInput = ExperimentalFileUnwatchInput
        // parity: client/src/effect/api/api.ts#FileUnwatchOutput [status=implemented hash=67fb6949c0ed]
        public typealias FileUnwatchOutput = ExperimentalFileUnwatchOutput
        // parity: client/src/effect/api/api.ts#FileUnwatchOperation [status=implemented hash=bc489c2cd6d5]
        public typealias FileUnwatchOperation = ExperimentalFileUnwatchOperation
        // parity: client/src/effect/api/api.ts#MigrationV1StatusOutput [status=implemented hash=2fabfaab8ff4]
        public typealias MigrationV1StatusOutput = ExperimentalMigrationV1StatusOutput
        // parity: client/src/effect/api/api.ts#MigrationV1StatusOperation [status=implemented hash=4ee5b6072a3c]
        public typealias MigrationV1StatusOperation = ExperimentalMigrationV1StatusOperation
        // parity: client/src/effect/api/api.ts#UsageLimitsInput [status=implemented hash=a041dbc41a16]
        public typealias UsageLimitsInput = ExperimentalUsageLimitsInput
        // parity: client/src/effect/api/api.ts#UsageLimitsOutput [status=implemented hash=714f6eaba7ba]
        public typealias UsageLimitsOutput = ExperimentalUsageLimitsOutput
        // parity: client/src/effect/api/api.ts#UsageLimitsOperation [status=implemented hash=593ff3f7b175]
        public typealias UsageLimitsOperation = ExperimentalUsageLimitsOperation
        // parity: client/src/effect/api/api.ts#ConfigUpdateInput [status=implemented hash=85fd8eb4cf7f]
        public typealias ConfigUpdateInput = ExperimentalConfigUpdateInput
        // parity: client/src/effect/api/api.ts#ConfigUpdateOutput [status=implemented hash=9c8780161fc5]
        public typealias ConfigUpdateOutput = ExperimentalConfigUpdateOutput
        // parity: client/src/effect/api/api.ts#ConfigUpdateOperation [status=implemented hash=af568ad49d3f]
        public typealias ConfigUpdateOperation = ExperimentalConfigUpdateOperation
        // parity: client/src/effect/api/api.ts#GenerateApi [status=implemented hash=b3715b52223d]
        public typealias GenerateApi = DeprecatedGenerateClientAPI
        // parity: client/src/effect/api/api.ts#VoiceApi [status=implemented hash=9d50364d4110]
        public typealias VoiceApi = ExperimentalVoiceClientAPI
        // parity: client/src/effect/api/api.ts#MigrationApi [status=implemented hash=3a33f49a3a24]
        public typealias MigrationApi = ExperimentalMigrationClientAPI
        // parity: client/src/effect/api/api.ts#UsageApi [status=implemented hash=106c4b9266b1]
        public typealias UsageApi = ExperimentalUsageClientAPI
        // parity: client/src/effect/api/api.ts#AppApi [status=implemented hash=35dd6e55cff4]
        public typealias AppApi = EffectClient.OpenCodeClient
    }
}

private final class AtomicResumeGuard: Sendable {
    private let resumed = Mutex(false)

    func claim() -> Bool {
        resumed.withLock { done in
            if done { return false }
            done = true
            return true
        }
    }
}
