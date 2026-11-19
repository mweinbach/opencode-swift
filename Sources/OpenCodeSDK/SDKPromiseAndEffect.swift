#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import OpenCodeClient
import OpenCodeCore
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeServer
import OpenCodeUtil

// MARK: - Promise SDK (`packages/sdk/src/promise.ts`)

/// Promise / async-await embedded OpenCode SDK composing `OpenCodeClient`, `OpenCodeCore`,
/// and the in-process embedded router (`packages/sdk/src/promise.ts`).
public enum PromiseSdk {
    /// Plugin list returned for a Session-selected instance (`packages/sdk/src/promise.ts#InstanceConfiguration`).
    // parity: sdk/src/promise.ts#InstanceConfiguration [status=implemented hash=7f3e9c4d7d3d]
    public struct InstanceConfiguration: Sendable {
        public let plugins: [PluginPromise.Plugin]

        public init(plugins: [PluginPromise.Plugin] = []) {
            self.plugins = plugins
        }
    }

    /// Session-selected instance selector and async factory (`packages/sdk/src/promise.ts#InstanceOptions`).
    // parity: sdk/src/promise.ts#InstanceOptions [status=implemented hash=dcff7de49f92]
    public struct InstanceOptions: Sendable {
        /// Select a sharing key within the Session's current Location. Must not initialize plugins.
        public let key: @Sendable (SessionSchema.Info) throws -> String
        /// Reconstruct configuration on a cache miss, including after a host restart.
        public let configure: @Sendable (String) async throws -> InstanceConfiguration

        public init(
            key: @escaping @Sendable (SessionSchema.Info) throws -> String,
            configure: @escaping @Sendable (String) async throws -> InstanceConfiguration
        ) {
            self.key = key
            self.configure = configure
        }
    }

    /// Options for creating a Promise-surface embedded OpenCode host (`packages/sdk/src/promise.ts#CreateOptions`).
    // parity: sdk/src/promise.ts#CreateOptions [status=implemented hash=432d07f432f2]
    public struct CreateOptions: Sendable {
        public var server: EmbeddedServerOptions
        public var log: SDKLogging.LogOptions?
        public var plugins: [PluginPromise.Plugin]?
        public var instances: InstanceOptions?

        public init(
            server: EmbeddedServerOptions = EmbeddedServerOptions(),
            log: SDKLogging.LogOptions? = nil,
            plugins: [PluginPromise.Plugin]? = nil,
            instances: InstanceOptions? = nil
        ) {
            self.server = server
            self.log = log
            self.plugins = plugins
            self.instances = instances
        }

        public init(
            app: EmbeddedServerOptions.AppOptions? = nil,
            cors: [String]? = nil,
            simulation: Bool? = nil,
            database: CoreDatabaseStore.Options? = nil,
            pty: CorePty.Persistent.Options? = nil,
            events: EmbeddedServerOptions.EventsOptions? = nil,
            models: CoreModel.ModelsDev.Options? = nil,
            fetch: LayerNodePlatform.Fetch? = nil,
            config: EmbeddedServerOptions.ConfigOptions? = nil,
            instructions: EmbeddedServerOptions.InstructionsOptions? = nil,
            windows: EmbeddedServerOptions.WindowsOptions? = nil,
            fs: EmbeddedServerOptions.FileSystemOptions? = nil,
            log: SDKLogging.LogOptions? = nil,
            plugins: [PluginPromise.Plugin]? = nil,
            instances: InstanceOptions? = nil
        ) {
            self.server = EmbeddedServerOptions(
                app: app,
                cors: cors,
                simulation: simulation,
                database: database,
                pty: pty,
                events: events,
                models: models,
                fetch: fetch,
                config: config,
                instructions: instructions,
                windows: windows,
                fs: fs
            )
            self.log = log
            self.plugins = plugins
            self.instances = instances
        }
    }

    /// Callable plugin surface supporting both dynamic `await opencode.plugin(myPlugin)` registration
    /// and standard `PluginClientAPI` methods (`list`, `gui`, `check`, `update`).
    public struct PluginSurface: Sendable {
        private let registerPlugin: @Sendable (PluginPromise.Plugin) async -> Void
        private let api: PluginClientAPI

        public init(
            register: @escaping @Sendable (PluginPromise.Plugin) async -> Void,
            api: PluginClientAPI
        ) {
            self.registerPlugin = register
            self.api = api
        }

        /// Dynamically registers a Promise-style plugin onto the live embedded host.
        public func callAsFunction(_ plugin: PluginPromise.Plugin) async {
            await registerPlugin(plugin)
        }

        public func list(
            _ input: PluginListInput? = nil,
            options: RequestOptions? = nil
        ) async throws -> PluginListOutput {
            try await api.list(input, options: options)
        }

        public func gui(
            _ input: PluginGuiInput,
            options: RequestOptions? = nil
        ) async throws -> PluginGuiOutput {
            try await api.gui(input, options: options)
        }

        public func check(
            _ input: PluginCheckInput? = nil,
            options: RequestOptions? = nil
        ) async throws -> PluginCheckOutput {
            try await api.check(input, options: options)
        }

        public func update(
            _ input: PluginUpdateInput,
            options: RequestOptions? = nil
        ) async throws {
            try await api.update(input, options: options)
        }
    }

    /// Composed Promise-surface embedded OpenCode host interface (`packages/sdk/src/promise.ts#Interface`).
    // parity: sdk/src/promise.ts#Interface [status=adapted hash=a118dfc3d9ca]
    public struct Interface: Sendable {
        public let client: OpenCodeClient
        public let host: EmbeddedHost.Interface

        // Re-exposed OpenCodeClient groups matching `Omit<OpenCodeClient, "plugin">`
        public var raw: GeneratedOpenCodeClient { client.raw }
        public var server: ServerClientAPI { client.server }
        public var location: LocationClientAPI { client.location }
        public var agent: AgentClientAPI { client.agent }
        public var session: SessionClientAPI { client.session }
        public var experimental: ExperimentalClientAPI { client.experimental }
        public var message: MessageClientAPI { client.message }
        public var model: ModelClientAPI { client.model }
        public var provider: ProviderClientAPI { client.provider }
        public var integration: IntegrationClientAPI { client.integration }
        public var mcp: McpClientAPI { client.mcp }
        public var credential: CredentialClientAPI { client.credential }
        public var project: ProjectClientAPI { client.project }
        public var form: FormClientAPI { client.form }
        public var permission: PermissionClientAPI { client.permission }
        public var file: FileClientAPI { client.file }
        public var command: CommandClientAPI { client.command }
        public var skill: SkillClientAPI { client.skill }
        public var rpc: OpenCodeRpcAPI { client.rpc }
        public var event: SharedEventsHub<OpenCodeEvent> { client.event }
        public var pty: PtyClientAPI { client.pty }
        public var shell: ShellClientAPI { client.shell }
        public var reference: ReferenceClientAPI { client.reference }
        public var worktree: WorktreeClientAPI { client.worktree }
        public var vcs: VcsClientAPI { client.vcs }
        public var debug: DebugClientAPI { client.debug }
        public var websearch: WebsearchClientAPI { client.websearch }
        public var config: ConfigClientAPI { client.config }
        public var generate: DeprecatedGenerateClientAPI { client.generate }
        public var voice: ExperimentalVoiceClientAPI { client.voice }
        public var migration: ExperimentalMigrationClientAPI { client.migration }
        public var usage: ExperimentalUsageClientAPI { client.usage }

        // SDK ergonomic aliases & lifecycle
        public var sessions: SessionClientAPI { client.session }
        public var events: SharedEventsHub<OpenCodeEvent> { client.event }
        public let plugin: PluginSurface
        public let close: @Sendable () async -> Void

        internal init(client: OpenCodeClient, host: EmbeddedHost.Interface) {
            self.client = client
            self.host = host
            self.plugin = PluginSurface(
                register: { promisePlugin in
                    host.plugins.register(PluginPromise.fromPromise(promisePlugin))
                },
                api: client.plugin
            )
            self.close = host.close
        }

        /// Swift equivalent of `Symbol.asyncDispose`: releases router resources, Location services,
        /// background tasks, and scoped plugin registrations.
        public func asyncDispose() async {
            await close()
        }

        /// Scoped lifecycle helper mirroring JavaScript's `await using opencode = await OpenCode.create()`.
        public func withClose<T: Sendable>(_ body: (Interface) async throws -> T) async throws -> T {
            do {
                let result = try await body(self)
                await close()
                return result
            } catch {
                await close()
                throw error
            }
        }
    }

    /// Boots an in-process Promise-surface OpenCode host over `http://opencode.local` using `OwnedFetch`.
    // parity: sdk/src/promise.ts#create [status=implemented hash=29c99c9dae0b]
    public static func create(
        _ options: CreateOptions = CreateOptions(),
        embed: EmbeddedHost.EmbedOptions = EmbeddedHost.EmbedOptions()
    ) async throws -> Interface {
        let adaptedPlugins: [PluginEffect.Plugin]? = options.plugins.flatMap { list in
            list.isEmpty ? nil : list.map(PluginPromise.fromPromise)
        }
        let adaptedInstances: SdkInstances.Options? = options.instances.map { inst in
            SdkInstances.Options(
                key: { session in try inst.key(session) },
                configure: { key, _, _ in
                    let configuration = try await inst.configure(key)
                    return SdkInstances.Configuration(
                        plugins: configuration.plugins.map(PluginPromise.fromPromise)
                    )
                }
            )
        }
        let host = try await EmbeddedHost.create(
            EmbeddedHost.CreateOptions(
                server: options.server,
                log: options.log,
                plugins: adaptedPlugins,
                instances: adaptedInstances
            ),
            embed: embed
        )
        let client = OpenCode.make(
            ClientOptions(baseUrl: "http://opencode.local", transport: host.fetch)
        )
        return Interface(client: client, host: host)
    }
}

// MARK: - Top-Level `OpenCode` SDK Facade (`packages/sdk/src/opencode.ts`)

public extension OpenCode {
    typealias LogEntry = SDKLogging.LogEntry
    typealias LogLevel = SDKLogging.LogLevel
    typealias LogOptions = SDKLogging.LogOptions
    typealias LogWriter = SDKLogging.LogWriter

    // parity: sdk/src/opencode.ts#CreateOptions [status=implemented hash=1b8d73853bad]
    typealias CreateOptions = PromiseSdk.CreateOptions

    // parity: sdk/src/opencode.ts#InstanceOptions [status=implemented hash=f694c4bf284e]
    typealias InstanceOptions = PromiseSdk.InstanceOptions

    // parity: sdk/src/opencode.ts#InstanceConfiguration [status=implemented hash=22cf200a3d24]
    typealias InstanceConfiguration = PromiseSdk.InstanceConfiguration

    // parity: sdk/src/opencode.ts#Interface [status=implemented hash=8d1b784015db]
    typealias Interface = PromiseSdk.Interface

    /// Boots an in-process OpenCode SDK host (`packages/sdk/src/opencode.ts#create`).
    // parity: sdk/src/opencode.ts#create [status=implemented hash=12ad69602834]
    static func create(
        _ options: CreateOptions = CreateOptions(),
        embed: EmbeddedHost.EmbedOptions = EmbeddedHost.EmbedOptions()
    ) async throws -> Interface {
        try await PromiseSdk.create(options, embed: embed)
    }
}

/// Convenience top-level factory mirroring `createOpencode` / `OpenCode.create`.
public func createOpencode(
    _ options: PromiseSdk.CreateOptions = PromiseSdk.CreateOptions(),
    embed: EmbeddedHost.EmbedOptions = EmbeddedHost.EmbedOptions()
) async throws -> PromiseSdk.Interface {
    try await PromiseSdk.create(options, embed: embed)
}

// MARK: - Promise Workerd SDK (`packages/sdk/src/workerd.ts`)

/// Cloudflare Durable Object / Workerd Promise SDK entrypoint (`packages/sdk/src/workerd.ts`).
public enum OpenCodeWorkerd {
    // parity: sdk/src/workerd.ts#Configuration [status=implemented hash=14cff54f859a]
    public typealias Configuration = WorkerdProfile.Configuration

    // parity: sdk/src/workerd.ts#CreateOptions [status=implemented hash=680a10c9f2f8]
    public struct CreateOptions: Sendable {
        public var storage: any CoreDatabaseWorkerdSQLite.DurableObjectStorage
        public var app: EmbeddedServerOptions.AppOptions?
        public var config: Configuration?
        public var models: CoreModel.ModelsDev.Options?
        public var fetch: LayerNodePlatform.Fetch?
        public var routerFactory: EmbeddedHost.RouterFactory?
        public var log: SDKLogging.LogOptions?
        public var plugins: [PluginPromise.Plugin]?
        public var instances: PromiseSdk.InstanceOptions?

        public init(
            storage: any CoreDatabaseWorkerdSQLite.DurableObjectStorage,
            app: EmbeddedServerOptions.AppOptions? = nil,
            config: Configuration? = nil,
            models: CoreModel.ModelsDev.Options? = nil,
            fetch: LayerNodePlatform.Fetch? = nil,
            routerFactory: EmbeddedHost.RouterFactory? = nil,
            log: SDKLogging.LogOptions? = nil,
            plugins: [PluginPromise.Plugin]? = nil,
            instances: PromiseSdk.InstanceOptions? = nil
        ) {
            self.storage = storage
            self.app = app
            self.config = config
            self.models = models
            self.fetch = fetch
            self.routerFactory = routerFactory
            self.log = log
            self.plugins = plugins
            self.instances = instances
        }
    }

    // parity: sdk/src/workerd.ts#Interface [status=implemented hash=8d1b784015db]
    public typealias Interface = PromiseSdk.Interface

    /// Boots the embedded OpenCode SDK on the workerd runtime profile over injected `DurableObjectStorage`.
    // parity: sdk/src/workerd.ts#create [status=implemented hash=eef7fed6e49c]
    public static func create(_ options: CreateOptions) async throws -> Interface {
        let profile = try WorkerdProfile.make(
            WorkerdProfile.Options(
                storage: options.storage,
                app: options.app,
                config: options.config,
                models: options.models,
                fetch: options.fetch,
                routerFactory: options.routerFactory
            )
        )
        return try await PromiseSdk.create(
            PromiseSdk.CreateOptions(
                server: profile.options,
                log: options.log,
                plugins: options.plugins,
                instances: options.instances
            ),
            embed: EmbeddedHost.EmbedOptions(
                overrides: profile.replacements,
                durableObjectStorage: profile.storage,
                routerFactory: options.routerFactory
            )
        )
    }
}

// MARK: - Effect SDK (`packages/sdk/src/effect/opencode.ts`)

/// Effect-native embedded OpenCode SDK composing `EffectClient.OpenCodeClient` with direct
/// in-process `CoreSession`, `CoreWorkspace`, and `CorePlugin.SdkPlugins` bindings
/// (`packages/sdk/src/effect/opencode.ts`).
public enum OpenCodeEffect {
    public typealias LogEntry = SDKLogging.LogEntry
    public typealias LogLevel = SDKLogging.LogLevel
    public typealias LogOptions = SDKLogging.LogOptions
    public typealias LogWriter = SDKLogging.LogWriter

    // parity: sdk/src/effect/opencode.ts#CreateOptions [status=implemented hash=12b8af33cb4e]
    public typealias CreateOptions = EmbeddedHost.CreateOptions

    // parity: sdk/src/effect/opencode.ts#EmbedOptions [status=implemented hash=6321e1356b1d]
    public typealias EmbedOptions = EmbeddedHost.EmbedOptions

    // parity: sdk/src/effect/opencode.ts#InstanceOptions [status=implemented hash=0aad1c870242]
    public typealias InstanceOptions = SdkInstances.Options

    // parity: sdk/src/effect/opencode.ts#InstanceConfiguration [status=implemented hash=d9b3b2a65dff]
    public typealias InstanceConfiguration = SdkInstances.Configuration

    /// Session surface on `OpenCodeEffect.Interface`: `create`, `get`, and `move` execute directly
    /// against `CoreSession` / `CoreSessionMove` without HTTP round-trips, while all remaining
    /// endpoints dispatch over the host-bound `OwnedFetch` transport.
    public struct SessionsSurface: Sendable {
        private let clientAPI: SessionClientAPI
        private let coreSessions: CoreSession.Service
        private let coreMove: CoreSessionMove.Service

        public var revert: SessionRevertClientAPI { clientAPI.revert }
        public var inbox: SessionInboxClientAPI { clientAPI.inbox }
        public var message: SessionMessageClientAPI { clientAPI.message }
        public var form: SessionFormClientAPI { clientAPI.form }

        internal init(
            clientAPI: SessionClientAPI,
            coreSessions: CoreSession.Service,
            coreMove: CoreSessionMove.Service
        ) {
            self.clientAPI = clientAPI
            self.coreSessions = coreSessions
            self.coreMove = coreMove
        }

        // Direct Core bindings (matching `effect/opencode.ts:56-58`)
        public func create(_ input: CoreSession.CreateInput = CoreSession.CreateInput()) async throws -> SessionSchema.Info {
            try await coreSessions.create(input)
        }

        public func get(sessionID: SessionID) throws -> SessionSchema.Info {
            try coreSessions.get(sessionID)
        }

        public func move(_ input: CoreSessionMove.MoveInput) async throws {
            try await coreMove.move(input)
        }

        // HTTP/SSE endpoints over the host's isolated in-process transport
        public func list(_ input: SessionListInput? = nil, options: RequestOptions? = nil) async throws -> SessionListOutput {
            try await clientAPI.list(input, options: options)
        }

        public func active(options: RequestOptions? = nil) async throws -> SessionActiveOutput {
            try await clientAPI.active(options: options)
        }

        public func remove(_ input: SessionRemoveInput, options: RequestOptions? = nil) async throws {
            try await clientAPI.remove(input, options: options)
        }

        public func fork(_ input: SessionForkInput, options: RequestOptions? = nil) async throws -> SessionForkOutput {
            try await clientAPI.fork(input, options: options)
        }

        public func switchAgent(_ input: SessionSwitchAgentInput, options: RequestOptions? = nil) async throws {
            try await clientAPI.switchAgent(input, options: options)
        }

        public func switchModel(_ input: SessionSwitchModelInput, options: RequestOptions? = nil) async throws {
            try await clientAPI.switchModel(input, options: options)
        }

        public func update(_ input: SessionUpdateInput, options: RequestOptions? = nil) async throws {
            try await clientAPI.update(input, options: options)
        }

        public func prompt(_ input: SessionPromptInput, options: RequestOptions? = nil) async throws -> SessionPromptOutput {
            try await clientAPI.prompt(input, options: options)
        }

        public func command(_ input: SessionCommandInput, options: RequestOptions? = nil) async throws {
            try await clientAPI.command(input, options: options)
        }

        public func synthetic(_ input: SessionSyntheticInput, options: RequestOptions? = nil) async throws -> SessionSyntheticOutput {
            try await clientAPI.synthetic(input, options: options)
        }

        public func shell(_ input: SessionShellInput, options: RequestOptions? = nil) async throws {
            try await clientAPI.shell(input, options: options)
        }

        public func compact(_ input: SessionCompactInput, options: RequestOptions? = nil) async throws -> SessionCompactOutput {
            try await clientAPI.compact(input, options: options)
        }

        public func context(_ input: SessionContextInput, options: RequestOptions? = nil) async throws -> SessionContextOutput {
            try await clientAPI.context(input, options: options)
        }

        public func diff(_ input: SessionDiffInput, options: RequestOptions? = nil) async throws -> SessionDiffOutput {
            try await clientAPI.diff(input, options: options)
        }

        public func generate(_ input: SessionGenerateInput, options: RequestOptions? = nil) async throws -> SessionGenerateOutput {
            try await clientAPI.generate(input, options: options)
        }

        public func interrupt(_ input: SessionInterruptInput, options: RequestOptions? = nil) async throws -> SessionInterruptOutput {
            try await clientAPI.interrupt(input, options: options)
        }

        public func background(_ input: SessionBackgroundInput, options: RequestOptions? = nil) async throws {
            try await clientAPI.background(input, options: options)
        }

        public func environment(_ input: SessionEnvironmentInput, options: RequestOptions? = nil) async throws {
            try await clientAPI.environment(input, options: options)
        }

        public func view(_ input: SessionViewInput, options: RequestOptions? = nil) async throws {
            try await clientAPI.view(input, options: options)
        }
    }

    /// Direct Core workspace facade exposed on `OpenCodeEffect.Interface` (`effect/opencode.ts:61-65`).
    public struct WorkspaceSurface: Sendable {
        private let service: CoreProject.Workspace.Service

        internal init(service: CoreProject.Workspace.Service) {
            self.service = service
        }

        public func create(id: WorkspaceID? = nil, provider: String) async throws -> WorkspaceID {
            try await service.create(id: id, provider: provider)
        }

        public func provision(workspaceID: WorkspaceID) async throws -> CoreProject.Workspace.Info {
            try await service.provision(workspaceID)
        }

        public func destroy(workspaceID: WorkspaceID) async throws -> WorkspaceSchema.DestroyResult {
            try await service.destroy(workspaceID)
        }
    }

    /// Callable plugin surface supporting both Effect plugin registration and `PluginClientAPI` queries.
    public struct PluginSurface: Sendable {
        private let registerPlugin: @Sendable (PluginEffect.Plugin) -> Void
        private let api: PluginClientAPI

        internal init(
            register: @escaping @Sendable (PluginEffect.Plugin) -> Void,
            api: PluginClientAPI
        ) {
            self.registerPlugin = register
            self.api = api
        }

        public func callAsFunction(_ plugin: PluginEffect.Plugin) {
            registerPlugin(plugin)
        }

        public func list(
            _ input: PluginListInput? = nil,
            options: RequestOptions? = nil
        ) async throws -> PluginListOutput {
            try await api.list(input, options: options)
        }

        public func gui(
            _ input: PluginGuiInput,
            options: RequestOptions? = nil
        ) async throws -> PluginGuiOutput {
            try await api.gui(input, options: options)
        }

        public func check(
            _ input: PluginCheckInput? = nil,
            options: RequestOptions? = nil
        ) async throws -> PluginCheckOutput {
            try await api.check(input, options: options)
        }

        public func update(
            _ input: PluginUpdateInput,
            options: RequestOptions? = nil
        ) async throws {
            try await api.update(input, options: options)
        }
    }

    /// Composed Effect-native SDK host interface (`packages/sdk/src/effect/opencode.ts#Interface`).
    // parity: sdk/src/effect/opencode.ts#Interface [status=adapted hash=4d7c9aea86cd]
    public struct Interface: Sendable {
        public let client: EffectClient.OpenCodeClient
        public let host: EmbeddedHost.Interface
        public let sessions: SessionsSurface
        public let events: EffectClient.EffectEventAPI
        public let workspace: WorkspaceSurface
        public let plugin: PluginSurface

        public var raw: EffectClient.GeneratedClient { client.raw }
        public var server: ServerClientAPI { client.server }
        public var location: LocationClientAPI { client.location }
        public var agent: AgentClientAPI { client.agent }
        public var session: SessionClientAPI { client.session }
        public var experimental: ExperimentalClientAPI { client.experimental }
        public var message: MessageClientAPI { client.message }
        public var model: ModelClientAPI { client.model }
        public var provider: ProviderClientAPI { client.provider }
        public var integration: IntegrationClientAPI { client.integration }
        public var mcp: McpClientAPI { client.mcp }
        public var credential: CredentialClientAPI { client.credential }
        public var project: ProjectClientAPI { client.project }
        public var form: FormClientAPI { client.form }
        public var permission: PermissionClientAPI { client.permission }
        public var file: FileClientAPI { client.file }
        public var command: CommandClientAPI { client.command }
        public var skill: SkillClientAPI { client.skill }
        public var rpc: EffectClient.EffectRpcSurface { client.rpc }
        public var event: EffectClient.EffectEventAPI { client.event }
        public var pty: PtyClientAPI { client.pty }
        public var shell: ShellClientAPI { client.shell }
        public var reference: ReferenceClientAPI { client.reference }
        public var worktree: WorktreeClientAPI { client.worktree }
        public var vcs: VcsClientAPI { client.vcs }
        public var debug: DebugClientAPI { client.debug }
        public var websearch: WebsearchClientAPI { client.websearch }
        public var config: ConfigClientAPI { client.config }
        public var generate: DeprecatedGenerateClientAPI { client.generate }
        public var voice: ExperimentalVoiceClientAPI { client.voice }
        public var migration: ExperimentalMigrationClientAPI { client.migration }
        public var usage: ExperimentalUsageClientAPI { client.usage }

        internal init(client: EffectClient.OpenCodeClient, host: EmbeddedHost.Interface) {
            self.client = client
            self.host = host
            self.sessions = SessionsSurface(
                clientAPI: client.session,
                coreSessions: host.sessions,
                coreMove: host.sessionMove
            )
            self.events = client.event
            self.workspace = WorkspaceSurface(service: host.workspace)
            self.plugin = PluginSurface(
                register: { effectPlugin in
                    host.plugins.register(effectPlugin)
                },
                api: client.plugin
            )
        }
    }

    /// Service tag identifying `OpenCodeEffect.Interface` in a `LayerNode.Output` service graph
    /// (`@opencode/sdk/OpenCode`).
    // parity: sdk/src/effect/opencode.ts#Service [status=adapted hash=482d168e9bd0]
    public enum Service {
        public static let serviceKey = "@opencode/sdk/OpenCode"
    }

    /// Acquires an Effect-native embedded OpenCode SDK bound to `scope`: closing `scope` automatically
    /// calls `host.close()` (`Effect.acquireRelease` semantics). The client permanently binds the host's
    /// in-process `OwnedFetch` transport, isolating it from any ambient transport in the caller's environment.
    // parity: sdk/src/effect/opencode.ts#create [status=adapted hash=6147dc6a1feb]
    public static func create(
        _ options: CreateOptions = CreateOptions(),
        embed: EmbedOptions = EmbedOptions(),
        scope: LayerNode.ResourceScope
    ) async throws -> Interface {
        let host = try await EmbeddedHost.create(options, embed: embed)
        scope.addFinalizer {
            await host.close()
        }
        // Permanently bind host.fetch so ambient caller transports never intercept SDK requests.
        let client = EffectClient.OpenCode.make(
            ClientOptions(baseUrl: "http://opencode.local", transport: host.fetch)
        )
        return Interface(client: client, host: host)
    }

    /// Convenience scoped helper acquiring `OpenCodeEffect.Interface`, running `body`, and always closing the scope.
    public static func withScoped<T: Sendable>(
        _ options: CreateOptions = CreateOptions(),
        embed: EmbedOptions = EmbedOptions(),
        _ body: (Interface) async throws -> T
    ) async throws -> T {
        let scope = LayerNode.ResourceScope()
        do {
            let sdk = try await create(options, embed: embed, scope: scope)
            let result = try await body(sdk)
            await scope.close()
            return result
        } catch {
            await scope.close()
            throw error
        }
    }

    /// Builds a `LayerNode.ExecutableLayer` providing `OpenCodeEffect.Interface` under `Service.serviceKey`,
    /// forwarding upstream `deps` into `options.services` for `SdkInstances.provide`.
    // parity: sdk/src/effect/opencode.ts#layer [status=adapted hash=bb54dcf55ee4]
    public static func layer(
        _ options: CreateOptions = CreateOptions(),
        embed: EmbedOptions = EmbedOptions()
    ) -> LayerNode.ExecutableLayer {
        LayerNode.ExecutableLayer { deps, scope in
            var mergedOptions = options
            mergedOptions.services = deps.merging(options.services)
            let sdk = try await create(mergedOptions, embed: embed, scope: scope)
            return LayerNode.Output([Service.serviceKey: sdk])
        }
    }
}

// MARK: - Effect Workerd SDK (`packages/sdk/src/effect/workerd.ts`)

/// Cloudflare Durable Object / Workerd Effect-native SDK entrypoint (`packages/sdk/src/effect/workerd.ts`).
public enum OpenCodeEffectWorkerd {
    // parity: sdk/src/effect/workerd.ts#Configuration [status=implemented hash=14cff54f859a]
    public typealias Configuration = WorkerdProfile.Configuration

    // parity: sdk/src/effect/workerd.ts#CreateOptions [status=implemented hash=c9fb32399cf5]
    public struct CreateOptions: Sendable {
        public var storage: any CoreDatabaseWorkerdSQLite.DurableObjectStorage
        public var app: EmbeddedServerOptions.AppOptions?
        public var config: Configuration?
        public var models: CoreModel.ModelsDev.Options?
        public var fetch: LayerNodePlatform.Fetch?
        public var routerFactory: EmbeddedHost.RouterFactory?
        public var log: SDKLogging.LogOptions?
        public var plugins: [PluginEffect.Plugin]?
        public var workspaceProviders: [String: any CoreProject.Workspace.Driver.Interface]?
        public var instances: SdkInstances.Options?
        public var services: LayerNode.Output

        public init(
            storage: any CoreDatabaseWorkerdSQLite.DurableObjectStorage,
            app: EmbeddedServerOptions.AppOptions? = nil,
            config: Configuration? = nil,
            models: CoreModel.ModelsDev.Options? = nil,
            fetch: LayerNodePlatform.Fetch? = nil,
            routerFactory: EmbeddedHost.RouterFactory? = nil,
            log: SDKLogging.LogOptions? = nil,
            plugins: [PluginEffect.Plugin]? = nil,
            workspaceProviders: [String: any CoreProject.Workspace.Driver.Interface]? = nil,
            instances: SdkInstances.Options? = nil,
            services: LayerNode.Output = LayerNode.Output()
        ) {
            self.storage = storage
            self.app = app
            self.config = config
            self.models = models
            self.fetch = fetch
            self.routerFactory = routerFactory
            self.log = log
            self.plugins = plugins
            self.workspaceProviders = workspaceProviders
            self.instances = instances
            self.services = services
        }
    }

    // parity: sdk/src/effect/workerd.ts#Interface [status=implemented hash=b131913b2226]
    public typealias Interface = OpenCodeEffect.Interface

    // parity: sdk/src/effect/workerd.ts#Requirements [status=adapted hash=2358e88a98c6]
    public typealias Requirements = LayerNode.ResourceScope

    /// Acquires an Effect-native OpenCode SDK host on the workerd runtime profile bound to `scope`.
    // parity: sdk/src/effect/workerd.ts#create [status=adapted hash=bd71bdd2b2ed]
    public static func create(
        _ options: CreateOptions,
        scope: Requirements
    ) async throws -> Interface {
        let profile = try WorkerdProfile.make(
            WorkerdProfile.Options(
                storage: options.storage,
                app: options.app,
                config: options.config,
                models: options.models,
                fetch: options.fetch,
                routerFactory: options.routerFactory
            )
        )
        return try await OpenCodeEffect.create(
            OpenCodeEffect.CreateOptions(
                server: profile.options,
                log: options.log,
                plugins: options.plugins,
                workspaceProviders: options.workspaceProviders,
                instances: options.instances,
                services: options.services
            ),
            embed: OpenCodeEffect.EmbedOptions(
                overrides: profile.replacements,
                durableObjectStorage: profile.storage,
                routerFactory: options.routerFactory
            ),
            scope: scope
        )
    }

    /// Builds a `LayerNode.ExecutableLayer` providing the workerd `OpenCodeEffect.Interface`
    /// under `OpenCodeEffect.Service.serviceKey`.
    // parity: sdk/src/effect/workerd.ts#layer [status=adapted hash=b527f64f5252]
    public static func layer(_ options: CreateOptions) -> LayerNode.ExecutableLayer {
        LayerNode.ExecutableLayer { deps, scope in
            var mergedOptions = options
            mergedOptions.services = deps.merging(options.services)
            let sdk = try await create(mergedOptions, scope: scope)
            return LayerNode.Output([OpenCodeEffect.Service.serviceKey: sdk])
        }
    }
}
