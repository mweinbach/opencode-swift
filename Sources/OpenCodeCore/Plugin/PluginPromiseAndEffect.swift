#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodeAI
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

// MARK: - Effect-Style Server Plugin SDK (`packages/plugin/src/effect/*`)

/// Swift 6.2 port of the Effect-style OpenCode server plugin SDK (`packages/plugin/src/effect/*`).
public enum PluginEffect {
    // MARK: - effect/registration.ts

    /// Handle returned by hook and transform registrations; calling `dispose()` unregisters early.
    // parity: plugin/src/effect/registration.ts#Registration [status=implemented hash=17e00d1d8f7b]
    public struct Registration: Sendable {
        public let dispose: @Sendable () async -> Void

        public init(dispose: @escaping @Sendable () async -> Void) {
            self.dispose = dispose
        }
    }

    /// Optional provider filter scoping a model hook to one provider ID.
    // parity: plugin/src/effect/registration.ts#ModelHookOptions [status=implemented hash=bf5af9ce9bbc]
    public struct ModelHookOptions: Equatable, Hashable, Sendable, Codable {
        public let providerID: String?

        public init(providerID: String? = nil) {
            self.providerID = providerID
        }
    }

    /// Hook registration function type for non-model-scoped domains.
    // parity: plugin/src/effect/registration.ts#Hooks [status=adapted hash=0d123cc1c68c]
    public typealias Hooks<Event: Sendable> = @Sendable (
        _ name: String,
        _ callback: @escaping @Sendable (Event) async throws -> Event
    ) async -> Registration

    /// Hook registration function type supporting optional `ModelHookOptions`.
    // parity: plugin/src/effect/registration.ts#ModelHooks [status=adapted hash=31ff21d04761]
    public typealias ModelHooks<Event: Sendable> = @Sendable (
        _ name: String,
        _ callback: @escaping @Sendable (Event) async throws -> Event,
        _ options: ModelHookOptions?
    ) async -> Registration

    /// Synchronous state transform registration returning a disposable `Registration`.
    // parity: plugin/src/effect/registration.ts#Transform [status=adapted hash=e7525a155704]
    public typealias Transform<Editor: Sendable> = @Sendable (
        _ callback: @escaping @Sendable (Editor) -> Void
    ) async -> Registration

    // MARK: - effect/agent.ts

    /// Mutable editor for the Location's agent registry during `agent.transform`.
    // parity: plugin/src/effect/agent.ts#AgentEditor [status=implemented hash=8dd1dd304cca]
    public struct AgentEditor: Sendable {
        public let list: @Sendable () -> [AgentSchema.Info]
        public let get: @Sendable (String) -> AgentSchema.Info?
        public let setDefault: @Sendable (String?) -> Void
        public let update: @Sendable (String, @Sendable (inout AgentSchema.Info) -> Void) -> Void
        public let remove: @Sendable (String) -> Void

        public init(
            list: @escaping @Sendable () -> [AgentSchema.Info],
            get: @escaping @Sendable (String) -> AgentSchema.Info?,
            setDefault: @escaping @Sendable (String?) -> Void,
            update: @escaping @Sendable (String, @Sendable (inout AgentSchema.Info) -> Void) -> Void,
            remove: @escaping @Sendable (String) -> Void
        ) {
            self.list = list
            self.get = get
            self.setDefault = setDefault
            self.update = update
            self.remove = remove
        }
    }

    /// Agent domain API available to server plugins.
    // parity: plugin/src/effect/agent.ts#AgentDomain [status=implemented hash=e79b4373d9c8]
    public struct AgentDomain: Sendable {
        public let list: @Sendable () async throws -> PluginSDK.LocatedResult<[AgentSchema.Info]>
        public let get: @Sendable (String) async throws -> PluginSDK.LocatedResult<AgentSchema.Info>
        public let transform: Transform<AgentEditor>
        public let reload: @Sendable () async -> Void

        public init(
            list: @escaping @Sendable () async throws -> PluginSDK.LocatedResult<[AgentSchema.Info]>,
            get: @escaping @Sendable (String) async throws -> PluginSDK.LocatedResult<AgentSchema.Info>,
            transform: @escaping Transform<AgentEditor>,
            reload: @escaping @Sendable () async -> Void
        ) {
            self.list = list
            self.get = get
            self.transform = transform
            self.reload = reload
        }
    }

    // MARK: - effect/aisdk.ts

    /// Hook payloads emitted when resolving provider SDK instances and language models.
    // parity: plugin/src/effect/aisdk.ts#AISDKHooks [status=adapted hash=6eda14735ca8]
    public enum AISDKHooks: Sendable {
        public struct SDKEvent: Sendable {
            public let model: ModelSchema.Info
            public let packageName: String
            public var options: [String: JSONValue]
            public var sdk: AnySendableValue?

            public init(
                model: ModelSchema.Info,
                packageName: String,
                options: [String: JSONValue] = [:],
                sdk: AnySendableValue? = nil
            ) {
                self.model = model
                self.packageName = packageName
                self.options = options
                self.sdk = sdk
            }
        }

        public struct LanguageEvent: Sendable {
            public let model: ModelSchema.Info
            public let sdk: AnySendableValue?
            public var options: [String: JSONValue]
            public var language: AnySendableValue?

            public init(
                model: ModelSchema.Info,
                sdk: AnySendableValue? = nil,
                options: [String: JSONValue] = [:],
                language: AnySendableValue? = nil
            ) {
                self.model = model
                self.sdk = sdk
                self.options = options
                self.language = language
            }
        }

        case sdk(SDKEvent)
        case language(LanguageEvent)

        public var hookName: String {
            switch self {
            case .sdk: return "sdk"
            case .language: return "language"
            }
        }

        public var providerID: String {
            switch self {
            case .sdk(let e): return e.model.providerID.rawValue
            case .language(let e): return e.model.providerID.rawValue
            }
        }
    }

    /// AI SDK hook domain exposed on plugin contexts.
    // parity: plugin/src/effect/aisdk.ts#AISDKDomain [status=implemented hash=54d540cdbb6e]
    public struct AISDKDomain: Sendable {
        public let hook: ModelHooks<AISDKHooks>

        public init(hook: @escaping ModelHooks<AISDKHooks>) {
            self.hook = hook
        }
    }

    // MARK: - effect/artifact.ts

    /// Input for creating an artifact through a custom artifact provider.
    // parity: plugin/src/effect/artifact.ts#ArtifactProviderCreateInput [status=implemented hash=65559080a522]
    public struct ArtifactProviderCreateInput: Equatable, Hashable, Sendable {
        public let id: ArtifactSchema.ID
        public let title: String
        public let entry: String
        public let files: [String: [UInt8]]
        public let sessionID: SessionID?

        public init(
            id: ArtifactSchema.ID,
            title: String,
            entry: String,
            files: [String: [UInt8]],
            sessionID: SessionID? = nil
        ) {
            self.id = id
            self.title = title
            self.entry = entry
            self.files = files
            self.sessionID = sessionID
        }
    }

    /// Input for updating an existing artifact through a custom artifact provider.
    // parity: plugin/src/effect/artifact.ts#ArtifactProviderUpdateInput [status=implemented hash=ec0bf093bea4]
    public struct ArtifactProviderUpdateInput: Equatable, Hashable, Sendable {
        public let title: String
        public let entry: String
        public let files: [String: [UInt8]]
        public let sessionID: SessionID?

        public init(
            title: String,
            entry: String,
            files: [String: [UInt8]],
            sessionID: SessionID? = nil
        ) {
            self.title = title
            self.entry = entry
            self.files = files
            self.sessionID = sessionID
        }
    }

    /// Result returned by artifact create/update operations.
    // parity: plugin/src/effect/artifact.ts#ArtifactProviderResult [status=implemented hash=8c670224a1c7]
    public struct ArtifactProviderResult: Equatable, Hashable, Sendable, Codable {
        public let url: String?

        public init(url: String? = nil) {
            self.url = url
        }
    }

    /// Effect-style artifact provider definition registered via `experimental.artifact.transform`.
    // parity: plugin/src/effect/artifact.ts#ArtifactProviderDefinition [status=implemented hash=589045b68059]
    public struct ArtifactProviderDefinition: Sendable {
        public let id: String
        public let name: String
        public let capabilities: [ArtifactSchema.Capability]
        public let prompt: String
        public let create: @Sendable (ArtifactProviderCreateInput) async throws -> ArtifactProviderResult
        public let read: @Sendable (ArtifactSchema.ID) async throws -> [String: [UInt8]]
        public let update: @Sendable (ArtifactSchema.ID, ArtifactProviderUpdateInput) async throws -> ArtifactProviderResult
        public let delete: @Sendable (ArtifactSchema.ID) async throws -> Void

        public init(
            id: String,
            name: String,
            capabilities: [ArtifactSchema.Capability],
            prompt: String,
            create: @escaping @Sendable (ArtifactProviderCreateInput) async throws -> ArtifactProviderResult,
            read: @escaping @Sendable (ArtifactSchema.ID) async throws -> [String: [UInt8]],
            update: @escaping @Sendable (ArtifactSchema.ID, ArtifactProviderUpdateInput) async throws -> ArtifactProviderResult,
            delete: @escaping @Sendable (ArtifactSchema.ID) async throws -> Void
        ) {
            self.id = id
            self.name = name
            self.capabilities = capabilities
            self.prompt = prompt
            self.create = create
            self.read = read
            self.update = update
            self.delete = delete
        }
    }

    /// Editor mutating registered artifact providers and default provider selection.
    // parity: plugin/src/effect/artifact.ts#ArtifactEditor [status=implemented hash=fd2597fa1491]
    public struct ArtifactEditor: Sendable {
        public let add: @Sendable (ArtifactProviderDefinition) -> Void
        public let remove: @Sendable (String) -> Void
        public let getDefault: @Sendable () -> String?
        public let setDefault: @Sendable (String?) -> Void

        public init(
            add: @escaping @Sendable (ArtifactProviderDefinition) -> Void,
            remove: @escaping @Sendable (String) -> Void,
            getDefault: @escaping @Sendable () -> String?,
            setDefault: @escaping @Sendable (String?) -> Void
        ) {
            self.add = add
            self.remove = remove
            self.getDefault = getDefault
            self.setDefault = setDefault
        }
    }

    /// Experimental artifact plugin domain.
    // parity: plugin/src/effect/artifact.ts#ExperimentalArtifactDomain [status=implemented hash=b2bd8f81e7b2]
    public struct ExperimentalArtifactDomain: Sendable {
        public let transform: Transform<ArtifactEditor>
        public let reload: @Sendable () async -> Void

        public init(
            transform: @escaping Transform<ArtifactEditor>,
            reload: @escaping @Sendable () async -> Void
        ) {
            self.transform = transform
            self.reload = reload
        }
    }

    // MARK: - effect/command.ts

    /// Input passed when invoking a slash command registered by a plugin.
    // parity: plugin/src/effect/command.ts#CommandInvocation [status=implemented hash=658c5cb3a490]
    public struct CommandInvocation: Equatable, Hashable, Sendable, Codable {
        public let sessionID: SessionID
        public let prompt: PromptInputSchema.Prompt
        public let delivery: SessionInboxSchema.Delivery

        public init(
            sessionID: SessionID,
            prompt: PromptInputSchema.Prompt,
            delivery: SessionInboxSchema.Delivery = .steer
        ) {
            self.sessionID = sessionID
            self.prompt = prompt
            self.delivery = delivery
        }
    }

    /// Slash command registration definition.
    // parity: plugin/src/effect/command.ts#CommandDefinition [status=implemented hash=9abbfccf9af4]
    public struct CommandDefinition: Sendable {
        public let name: String
        public let description: String?
        public let execute: @Sendable (CommandInvocation) async throws -> Void

        public init(
            name: String,
            description: String? = nil,
            execute: @escaping @Sendable (CommandInvocation) async throws -> Void
        ) {
            self.name = name
            self.description = description
            self.execute = execute
        }
    }

    /// Editor mutating registered slash commands.
    // parity: plugin/src/effect/command.ts#CommandEditor [status=implemented hash=a91f4d886f95]
    public struct CommandEditor: Sendable {
        public let add: @Sendable (CommandDefinition) -> Void

        public init(add: @escaping @Sendable (CommandDefinition) -> Void) {
            self.add = add
        }
    }

    /// Command domain API exposed to plugins.
    // parity: plugin/src/effect/command.ts#CommandDomain [status=implemented hash=b4aaace7aa71]
    public struct CommandDomain: Sendable {
        public let list: @Sendable () async throws -> PluginSDK.LocatedResult<[CommandSchema.Info]>
        public let transform: Transform<CommandEditor>
        public let reload: @Sendable () async -> Void

        public init(
            list: @escaping @Sendable () async throws -> PluginSDK.LocatedResult<[CommandSchema.Info]>,
            transform: @escaping Transform<CommandEditor>,
            reload: @escaping @Sendable () async -> Void
        ) {
            self.list = list
            self.transform = transform
            self.reload = reload
        }
    }

    // MARK: - effect/event.ts

    /// Event subscription domain delivering filtered public server & RPC events.
    // parity: plugin/src/effect/event.ts#EventDomain [status=adapted hash=dfa5c3c4281f]
    public struct EventDomain: Sendable {
        public let subscribe: @Sendable (_ types: [String]?) -> AsyncStream<PluginSDK.EventPayload>

        public init(subscribe: @escaping @Sendable (_ types: [String]?) -> AsyncStream<PluginSDK.EventPayload>) {
            self.subscribe = subscribe
        }
    }

    // MARK: - effect/integration.ts

    /// OAuth integration authentication method metadata.
    // parity: plugin/src/effect/integration.ts#IntegrationOAuthMethod [status=implemented hash=addb0ca8ba6b]
    public struct IntegrationOAuthMethod: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let label: String
        public let form: FormSchema.Fields?

        public init(id: String, label: String, form: FormSchema.Fields? = nil) {
            self.id = id
            self.label = label
            self.form = form
        }
    }

    /// Command-based integration authentication method metadata.
    // parity: plugin/src/effect/integration.ts#IntegrationCommandMethod [status=implemented hash=2f3ad078b44b]
    public struct IntegrationCommandMethod: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let label: String
        public let command: [String]

        public init(id: String, label: String, command: [String]) {
            self.id = id
            self.label = label
            self.command = command
        }
    }

    /// API-key integration authentication method metadata.
    // parity: plugin/src/effect/integration.ts#IntegrationKeyMethod [status=implemented hash=602ff347cd3b]
    public struct IntegrationKeyMethod: Equatable, Hashable, Sendable, Codable {
        public let label: String?
        public let form: FormSchema.Fields?

        public init(label: String? = nil, form: FormSchema.Fields? = nil) {
            self.label = label
            self.form = form
        }
    }

    /// External integration authentication method metadata.
    // parity: plugin/src/effect/integration.ts#IntegrationExternalMethod [status=implemented hash=5b914b0862d8]
    public struct IntegrationExternalMethod: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let label: String
        public let form: FormSchema.Fields?

        public init(id: String, label: String, form: FormSchema.Fields? = nil) {
            self.id = id
            self.label = label
            self.form = form
        }
    }

    /// Environment-variable integration authentication method metadata.
    // parity: plugin/src/effect/integration.ts#IntegrationEnvMethod [status=implemented hash=745945249f5c]
    public struct IntegrationEnvMethod: Equatable, Hashable, Sendable, Codable {
        public let names: [String]

        public init(names: [String]) {
            self.names = names
        }
    }

    /// Tagged union of all plugin-declarable integration methods.
    // parity: plugin/src/effect/integration.ts#IntegrationMethod [status=implemented hash=026aeacd2bfd]
    public enum IntegrationMethod: Equatable, Hashable, Sendable, Codable {
        case oauth(IntegrationOAuthMethod)
        case command(IntegrationCommandMethod)
        case key(IntegrationKeyMethod)
        case external(IntegrationExternalMethod)
        case env(IntegrationEnvMethod)
    }

    /// OAuth authorization flow descriptor (automatic callback or manual code paste).
    // parity: plugin/src/effect/integration.ts#IntegrationOAuthAuthorization [status=implemented hash=7cfdd6571680]
    public enum IntegrationOAuthAuthorization: Sendable {
        case auto(
            url: String,
            instructions: String,
            expiresAt: Double?,
            callback: @Sendable () async throws -> CredentialSchema.OAuth,
            submit: (@Sendable (String) async throws -> Void)?
        )
        case code(
            url: String,
            instructions: String,
            expiresAt: Double?,
            callback: @Sendable (String) async throws -> CredentialSchema.OAuth
        )
    }

    /// OAuth method implementation registration.
    // parity: plugin/src/effect/integration.ts#IntegrationOAuthMethodRegistration [status=implemented hash=0dafba238ed2]
    public struct IntegrationOAuthMethodRegistration: Sendable {
        public let integrationID: String
        public let method: IntegrationOAuthMethod
        public let authorize: @Sendable (FormSchema.Answer) async throws -> IntegrationOAuthAuthorization
        public let refresh: (@Sendable (CredentialSchema.OAuth) async throws -> CredentialSchema.OAuth)?
        /// Signs the credential out remotely before it is removed. A failure is logged and the credential is still
        /// removed.
        public let revoke: (@Sendable (CredentialSchema.OAuth) async throws -> Void)?
        public let label: (@Sendable (CredentialSchema.OAuth) -> String?)?

        public init(
            integrationID: String,
            method: IntegrationOAuthMethod,
            authorize: @escaping @Sendable (FormSchema.Answer) async throws -> IntegrationOAuthAuthorization,
            refresh: (@Sendable (CredentialSchema.OAuth) async throws -> CredentialSchema.OAuth)? = nil,
            revoke: (@Sendable (CredentialSchema.OAuth) async throws -> Void)? = nil,
            label: (@Sendable (CredentialSchema.OAuth) -> String?)? = nil
        ) {
            self.integrationID = integrationID
            self.method = method
            self.authorize = authorize
            self.refresh = refresh
            self.revoke = revoke
            self.label = label
        }
    }

    /// Registration union for any integration authentication method.
    // parity: plugin/src/effect/integration.ts#IntegrationMethodRegistration [status=implemented hash=fdae739cd13c]
    public enum IntegrationMethodRegistration: Sendable {
        case oauth(IntegrationOAuthMethodRegistration)
        case command(integrationID: String, method: IntegrationCommandMethod)
        case key(integrationID: String, method: IntegrationKeyMethod)
        case external(integrationID: String, method: IntegrationExternalMethod)
        case env(integrationID: String, method: IntegrationEnvMethod)
    }

    /// Lightweight mutable integration reference manipulated in `IntegrationEditor`.
    public struct IntegrationRef: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// Editor mutating registered integrations and their authentication methods.
    // parity: plugin/src/effect/integration.ts#IntegrationEditor [status=implemented hash=1d65f670d66b]
    public struct IntegrationEditor: Sendable {
        public struct MethodEditor: Sendable {
            public let list: @Sendable (String) -> [IntegrationMethod]
            public let update: @Sendable (IntegrationMethodRegistration) -> Void
            public let remove: @Sendable (String, IntegrationMethod) -> Void

            public init(
                list: @escaping @Sendable (String) -> [IntegrationMethod],
                update: @escaping @Sendable (IntegrationMethodRegistration) -> Void,
                remove: @escaping @Sendable (String, IntegrationMethod) -> Void
            ) {
                self.list = list
                self.update = update
                self.remove = remove
            }
        }

        public let list: @Sendable () -> [IntegrationRef]
        public let get: @Sendable (String) -> IntegrationRef?
        public let update: @Sendable (String, @Sendable (inout IntegrationRef) -> Void) -> Void
        public let remove: @Sendable (String) -> Void
        public let method: MethodEditor

        public init(
            list: @escaping @Sendable () -> [IntegrationRef],
            get: @escaping @Sendable (String) -> IntegrationRef?,
            update: @escaping @Sendable (String, @Sendable (inout IntegrationRef) -> Void) -> Void,
            remove: @escaping @Sendable (String) -> Void,
            method: MethodEditor
        ) {
            self.list = list
            self.get = get
            self.update = update
            self.remove = remove
            self.method = method
        }
    }

    /// Integration domain exposed on plugin contexts.
    // parity: plugin/src/effect/integration.ts#IntegrationDomain [status=implemented hash=89986f4ccffa]
    public struct IntegrationDomain: Sendable {
        public struct ConnectionAPI: Sendable {
            public let active: @Sendable (String) async -> ConnectionSchema.Info?
            public let resolve: @Sendable (ConnectionSchema.Info) async throws -> CredentialSchema.Value?
            public let status: @Sendable (String, ConnectionSchema.Info, ConnectionSchema.Status?) async -> Void

            public init(
                active: @escaping @Sendable (String) async -> ConnectionSchema.Info?,
                resolve: @escaping @Sendable (ConnectionSchema.Info) async throws -> CredentialSchema.Value?,
                status: @escaping @Sendable (String, ConnectionSchema.Info, ConnectionSchema.Status?) async -> Void
            ) {
                self.active = active
                self.resolve = resolve
                self.status = status
            }
        }

        public let list: @Sendable () async throws -> PluginSDK.LocatedResult<[IntegrationSchema.Info]>
        public let get: @Sendable (String) async throws -> PluginSDK.LocatedResult<IntegrationSchema.Info>
        public let transform: Transform<IntegrationEditor>
        public let reload: @Sendable () async -> Void
        public let connection: ConnectionAPI

        public init(
            list: @escaping @Sendable () async throws -> PluginSDK.LocatedResult<[IntegrationSchema.Info]>,
            get: @escaping @Sendable (String) async throws -> PluginSDK.LocatedResult<IntegrationSchema.Info>,
            transform: @escaping Transform<IntegrationEditor>,
            reload: @escaping @Sendable () async -> Void,
            connection: ConnectionAPI
        ) {
            self.list = list
            self.get = get
            self.transform = transform
            self.reload = reload
            self.connection = connection
        }
    }

    // MARK: - effect/mcp.ts

    /// Editor mutating configured MCP server definitions.
    // parity: plugin/src/effect/mcp.ts#MCPEditor [status=implemented hash=d36b640d8126]
    public struct MCPEditor: Sendable {
        public let list: @Sendable () -> [(String, McpSchema.ServerConfig)]
        public let get: @Sendable (String) -> McpSchema.ServerConfig?
        public let set: @Sendable (String, McpSchema.ServerConfig) -> Void
        public let update: @Sendable (String, @Sendable (inout McpSchema.ServerConfig) -> Void) -> Void
        public let remove: @Sendable (String) -> Void

        public init(
            list: @escaping @Sendable () -> [(String, McpSchema.ServerConfig)],
            get: @escaping @Sendable (String) -> McpSchema.ServerConfig?,
            set: @escaping @Sendable (String, McpSchema.ServerConfig) -> Void,
            update: @escaping @Sendable (String, @Sendable (inout McpSchema.ServerConfig) -> Void) -> Void,
            remove: @escaping @Sendable (String) -> Void
        ) {
            self.list = list
            self.get = get
            self.set = set
            self.update = update
            self.remove = remove
        }
    }

    /// MCP server domain exposed on plugin contexts.
    // parity: plugin/src/effect/mcp.ts#MCPDomain [status=implemented hash=cd1b3563c86d]
    public struct MCPDomain: Sendable {
        public let list: @Sendable () async throws -> PluginSDK.LocatedResult<[McpSchema.Server]>
        public let transform: Transform<MCPEditor>
        public let reload: @Sendable () async -> Void

        public init(
            list: @escaping @Sendable () async throws -> PluginSDK.LocatedResult<[McpSchema.Server]>,
            transform: @escaping Transform<MCPEditor>,
            reload: @escaping @Sendable () async -> Void
        ) {
            self.list = list
            self.transform = transform
            self.reload = reload
        }
    }

    // MARK: - effect/provider.ts

    /// Provider metadata and immutable source model definitions, including inactive providers.
    // parity: plugin/src/effect/provider.ts#ProviderRecord [status=implemented hash=ec12041b21f4]
    public struct ProviderRecord: Equatable, Sendable {
        public let provider: ProviderSchema.Info
        public let models: [String: ModelSchema.Info]
        public let sourceConnection: ConnectionSchema.Info?

        public init(
            provider: ProviderSchema.Info,
            models: [String: ModelSchema.Info] = [:],
            sourceConnection: ConnectionSchema.Info? = nil
        ) {
            self.provider = provider
            self.models = models
            self.sourceConnection = sourceConnection
        }
    }

    /// Editor mutating providers and their source model definitions.
    // parity: plugin/src/effect/provider.ts#ProviderEditor [status=implemented hash=1893ba7e480e]
    public struct ProviderEditor: Sendable {
        public struct ModelsEditor: Sendable {
            public let set: @Sendable (String, [ModelSchema.Info]) -> Void
            public let update: @Sendable (String, String, @Sendable (inout ModelSchema.Info) -> Void) -> Void
            public let remove: @Sendable (String, String) -> Void

            public init(
                set: @escaping @Sendable (String, [ModelSchema.Info]) -> Void,
                update: @escaping @Sendable (String, String, @Sendable (inout ModelSchema.Info) -> Void) -> Void,
                remove: @escaping @Sendable (String, String) -> Void
            ) {
                self.set = set
                self.update = update
                self.remove = remove
            }
        }

        public let list: @Sendable () -> [ProviderRecord]
        public let get: @Sendable (String) -> ProviderRecord?
        public let add: @Sendable (ProviderSchema.Info, [ModelSchema.Info], ConnectionSchema.Info?) -> Void
        public let update: @Sendable (String, @Sendable (inout ProviderSchema.Info) -> Void) -> Void
        public let remove: @Sendable (String) -> Void
        public let models: ModelsEditor

        public init(
            list: @escaping @Sendable () -> [ProviderRecord],
            get: @escaping @Sendable (String) -> ProviderRecord?,
            add: @escaping @Sendable (ProviderSchema.Info, [ModelSchema.Info], ConnectionSchema.Info?) -> Void,
            update: @escaping @Sendable (String, @Sendable (inout ProviderSchema.Info) -> Void) -> Void,
            remove: @escaping @Sendable (String) -> Void,
            models: ModelsEditor
        ) {
            self.list = list
            self.get = get
            self.add = add
            self.update = update
            self.remove = remove
            self.models = models
        }
    }

    /// Provider domain exposed on plugin contexts.
    // parity: plugin/src/effect/provider.ts#ProviderDomain [status=implemented hash=e68148bf6d72]
    public struct ProviderDomain: Sendable {
        public let list: @Sendable () async throws -> PluginSDK.LocatedResult<[ProviderSchema.Info]>
        public let get: @Sendable (String) async throws -> PluginSDK.LocatedResult<ProviderSchema.Info>
        public let transform: Transform<ProviderEditor>
        public let reload: @Sendable () async -> Void

        public init(
            list: @escaping @Sendable () async throws -> PluginSDK.LocatedResult<[ProviderSchema.Info]>,
            get: @escaping @Sendable (String) async throws -> PluginSDK.LocatedResult<ProviderSchema.Info>,
            transform: @escaping Transform<ProviderEditor>,
            reload: @escaping @Sendable () async -> Void
        ) {
            self.list = list
            self.get = get
            self.transform = transform
            self.reload = reload
        }
    }

    // MARK: - effect/model.ts

    /// Editor mutating materialized model catalog entries and default model selection.
    // parity: plugin/src/effect/model.ts#ModelEditor [status=implemented hash=442412f08654]
    public struct ModelEditor: Sendable {
        public struct DefaultModelRef: Equatable, Hashable, Sendable, Codable {
            public let providerID: String
            public let modelID: String

            public init(providerID: String, modelID: String) {
                self.providerID = providerID
                self.modelID = modelID
            }
        }

        public let list: @Sendable (String?) -> [ModelSchema.Info]
        public let get: @Sendable (String, String) -> ModelSchema.Info?
        public let update: @Sendable (String, String, @Sendable (inout ModelSchema.Info) -> Void) -> Void
        public let remove: @Sendable (String, String) -> Void
        public let getDefault: @Sendable () -> DefaultModelRef?
        public let setDefault: @Sendable (String, String) -> Void
        public let listProviders: @Sendable () -> [ProviderRecord]
        public let getProvider: @Sendable (String) -> ProviderRecord?

        public init(
            list: @escaping @Sendable (String?) -> [ModelSchema.Info],
            get: @escaping @Sendable (String, String) -> ModelSchema.Info?,
            update: @escaping @Sendable (String, String, @Sendable (inout ModelSchema.Info) -> Void) -> Void,
            remove: @escaping @Sendable (String, String) -> Void,
            getDefault: @escaping @Sendable () -> DefaultModelRef?,
            setDefault: @escaping @Sendable (String, String) -> Void,
            listProviders: @escaping @Sendable () -> [ProviderRecord],
            getProvider: @escaping @Sendable (String) -> ProviderRecord?
        ) {
            self.list = list
            self.get = get
            self.update = update
            self.remove = remove
            self.getDefault = getDefault
            self.setDefault = setDefault
            self.listProviders = listProviders
            self.getProvider = getProvider
        }
    }

    /// Model catalog domain exposed on plugin contexts.
    // parity: plugin/src/effect/model.ts#ModelDomain [status=implemented hash=41cbad5d3cb8]
    public struct ModelDomain: Sendable {
        public let list: @Sendable ([String]?) async throws -> PluginSDK.LocatedResult<[ModelSchema.Info]>
        public let defaultModel: @Sendable () async throws -> PluginSDK.LocatedResult<ModelSchema.Ref?>
        public let transform: Transform<ModelEditor>
        public let reload: @Sendable () async -> Void

        public init(
            list: @escaping @Sendable ([String]?) async throws -> PluginSDK.LocatedResult<[ModelSchema.Info]>,
            defaultModel: @escaping @Sendable () async throws -> PluginSDK.LocatedResult<ModelSchema.Ref?>,
            transform: @escaping Transform<ModelEditor>,
            reload: @escaping @Sendable () async -> Void
        ) {
            self.list = list
            self.defaultModel = defaultModel
            self.transform = transform
            self.reload = reload
        }
    }

    // MARK: - effect/permission.ts

    /// Mutable permission evaluation hook event (`permission.evaluate`).
    // parity: plugin/src/effect/permission.ts#PermissionEvaluation [status=implemented hash=0d1119074505]
    public struct PermissionEvaluation: Equatable, Hashable, Sendable, Codable {
        public let sessionID: SessionID
        public let agent: AgentSchema.ID?
        public let action: String
        public let resources: [String]
        public let metadata: [String: JSONValue]?
        public let source: PermissionSchema.Source?
        public var effect: PermissionSchema.Effect
        public var message: String?

        public init(
            sessionID: SessionID,
            agent: AgentSchema.ID? = nil,
            action: String,
            resources: [String],
            metadata: [String: JSONValue]? = nil,
            source: PermissionSchema.Source? = nil,
            effect: PermissionSchema.Effect,
            message: String? = nil
        ) {
            self.sessionID = sessionID
            self.agent = agent
            self.action = action
            self.resources = resources
            self.metadata = metadata
            self.source = source
            self.effect = effect
            self.message = message
        }
    }

    /// Permission hook event union.
    // parity: plugin/src/effect/permission.ts#PermissionHooks [status=implemented hash=5d0c3de29127]
    public enum PermissionHooks: Equatable, Hashable, Sendable {
        case evaluate(PermissionEvaluation)

        public var hookName: String { "evaluate" }
    }

    /// Permission domain exposed on plugin contexts.
    // parity: plugin/src/effect/permission.ts#PermissionDomain [status=implemented hash=2d7553ca847f]
    public struct PermissionDomain: Sendable {
        public let list: @Sendable (SessionID) async throws -> [PermissionSchema.Request]
        public let get: @Sendable (SessionID, PermissionSchema.ID) async throws -> PermissionSchema.Request
        public let reply: @Sendable (SessionID, PermissionSchema.ID, PermissionSchema.Reply, String?) async throws -> Void
        public let hook: Hooks<PermissionEvaluation>
        public let assert: @Sendable (PluginContract.AssertInput) async throws(ToolSchema.ToolError) -> Void

        public init(
            list: @escaping @Sendable (SessionID) async throws -> [PermissionSchema.Request],
            get: @escaping @Sendable (SessionID, PermissionSchema.ID) async throws -> PermissionSchema.Request,
            reply: @escaping @Sendable (SessionID, PermissionSchema.ID, PermissionSchema.Reply, String?) async throws -> Void,
            hook: @escaping Hooks<PermissionEvaluation>,
            assert: @escaping @Sendable (PluginContract.AssertInput) async throws(ToolSchema.ToolError) -> Void
        ) {
            self.list = list
            self.get = get
            self.reply = reply
            self.hook = hook
            self.assert = assert
        }
    }

    // MARK: - effect/reference.ts

    /// Editor mutating configured workspace reference sources.
    // parity: plugin/src/effect/reference.ts#ReferenceEditor [status=implemented hash=267a1ae1b1ea]
    public struct ReferenceEditor: Sendable {
        public let add: @Sendable (String, ReferenceSchema.Source) -> Void
        public let remove: @Sendable (String) -> Void
        public let list: @Sendable () -> [(String, ReferenceSchema.Source)]
        public let get: @Sendable (String) -> ReferenceSchema.Source?

        public init(
            add: @escaping @Sendable (String, ReferenceSchema.Source) -> Void,
            remove: @escaping @Sendable (String) -> Void,
            list: @escaping @Sendable () -> [(String, ReferenceSchema.Source)],
            get: @escaping @Sendable (String) -> ReferenceSchema.Source?
        ) {
            self.add = add
            self.remove = remove
            self.list = list
            self.get = get
        }
    }

    /// Reference domain exposed on plugin contexts.
    // parity: plugin/src/effect/reference.ts#ReferenceDomain [status=implemented hash=6b41868acbe1]
    public struct ReferenceDomain: Sendable {
        public let list: @Sendable () async throws -> PluginSDK.LocatedResult<[ReferenceSchema.Info]>
        public let transform: Transform<ReferenceEditor>
        public let reload: @Sendable () async -> Void

        public init(
            list: @escaping @Sendable () async throws -> PluginSDK.LocatedResult<[ReferenceSchema.Info]>,
            transform: @escaping Transform<ReferenceEditor>,
            reload: @escaping @Sendable () async -> Void
        ) {
            self.list = list
            self.transform = transform
            self.reload = reload
        }
    }

    // MARK: - effect/rpc.ts

    /// Per-call context supplied to an Effect RPC method handler.
    // parity: plugin/src/effect/rpc.ts#RpcCallContext [status=implemented hash=fa9ba4edbd81]
    public struct RpcCallContext: Sendable {
        public let error: @Sendable (_ type: String, _ message: String, _ data: JSONValue?) -> RpcSchema.Failure<JSONValue>

        public init(
            error: @escaping @Sendable (_ type: String, _ message: String, _ data: JSONValue?) -> RpcSchema.Failure<JSONValue> = {
                type, message, data in
                RpcSchema.Failure<JSONValue>(type: type, message: message, data: data)
            }
        ) {
            self.error = error
        }
    }

    /// Map of RPC method names to async typed handlers.
    // parity: plugin/src/effect/rpc.ts#RpcHandlers [status=adapted hash=b27b1ae7140d]
    public typealias RpcHandlers = [String: @Sendable (JSONValue, RpcCallContext) async throws -> JSONValue]

    /// Registration returned after mounting an RPC namespace, carrying an event emitter and `dispose`.
    // parity: plugin/src/effect/rpc.ts#RpcRegistration [status=implemented hash=ee0524139971]
    public struct RpcRegistration: Sendable {
        public let dispose: @Sendable () async -> Void
        public let emit: @Sendable (_ event: String, _ data: JSONValue) async throws -> Void

        public init(
            dispose: @escaping @Sendable () async -> Void,
            emit: @escaping @Sendable (_ event: String, _ data: JSONValue) async throws -> Void
        ) {
            self.dispose = dispose
            self.emit = emit
        }
    }

    /// RPC domain allowing plugins both to call and to register typed RPC namespaces.
    // parity: plugin/src/effect/rpc.ts#RpcDomain [status=adapted hash=716fdeb601fd]
    public struct RpcDomain: Sendable {
        public let call: @Sendable (_ namespace: String, _ method: String, _ input: JSONValue) async throws -> JSONValue
        public let subscribe: @Sendable (_ namespace: String, _ event: String) -> AsyncStream<RpcSchema.EventPayload>
        public let register: @Sendable (RpcSchema.Definition, RpcHandlers) async throws -> RpcRegistration

        public init(
            call: @escaping @Sendable (_ namespace: String, _ method: String, _ input: JSONValue) async throws -> JSONValue,
            subscribe: @escaping @Sendable (_ namespace: String, _ event: String) -> AsyncStream<RpcSchema.EventPayload>,
            register: @escaping @Sendable (RpcSchema.Definition, RpcHandlers) async throws -> RpcRegistration
        ) {
            self.call = call
            self.subscribe = subscribe
            self.register = register
        }
    }

    // MARK: - effect/session.ts

    /// Mutable event fired when admitting a prompt to a session (`session.prompt`).
    // parity: plugin/src/effect/session.ts#SessionPrompt [status=implemented hash=e2095b67fec2]
    public struct SessionPrompt: Equatable, Hashable, Sendable, Codable {
        public let sessionID: SessionID
        public let messageID: SessionMessageSchema.ID
        public var prompt: PromptInputSchema.Prompt
        public var metadata: [String: JSONValue]?
        public var delivery: SessionInboxSchema.Delivery

        public init(
            sessionID: SessionID,
            messageID: SessionMessageSchema.ID,
            prompt: PromptInputSchema.Prompt,
            metadata: [String: JSONValue]? = nil,
            delivery: SessionInboxSchema.Delivery = .steer
        ) {
            self.sessionID = sessionID
            self.messageID = messageID
            self.prompt = prompt
            self.metadata = metadata
            self.delivery = delivery
        }
    }

    /// Mutable generation + provider request options attached to a session model request.
    // parity: plugin/src/effect/session.ts#SessionRequestOptions [status=implemented hash=be1293a3e9b1]
    public struct SessionRequestOptions: Equatable, Sendable, Codable {
        public var generation: AISchema.GenerationOptionsFields
        public var providerOptions: [String: JSONValue]

        public init(
            generation: AISchema.GenerationOptionsFields = AISchema.GenerationOptionsFields(),
            providerOptions: [String: JSONValue] = [:]
        ) {
            self.generation = generation
            self.providerOptions = providerOptions
        }
    }

    /// Model request message paired with read-only stored session message metadata.
    // parity: plugin/src/effect/session.ts#SessionRequestMessage [status=implemented hash=e2c105118de9]
    public struct SessionRequestMessage: Equatable, Sendable, Codable {
        public var message: AISchema.Message
        public let metadata: [String: JSONValue]?

        public init(message: AISchema.Message, metadata: [String: JSONValue]? = nil) {
            self.message = message
            self.metadata = metadata
        }
    }

    /// Base mutable session model request payload (`system`, `messages`, `options`).
    // parity: plugin/src/effect/session.ts#SessionRequest [status=implemented hash=3d2e16cf132a]
    public struct SessionRequest: Equatable, Sendable, Codable {
        public let sessionID: SessionID
        public let model: ModelSchema.Ref
        public var system: [AISchema.SystemPart]
        public var messages: [SessionRequestMessage]
        public var options: SessionRequestOptions

        public init(
            sessionID: SessionID,
            model: ModelSchema.Ref,
            system: [AISchema.SystemPart] = [],
            messages: [SessionRequestMessage] = [],
            options: SessionRequestOptions = SessionRequestOptions()
        ) {
            self.sessionID = sessionID
            self.model = model
            self.system = system
            self.messages = messages
            self.options = options
        }
    }

    /// Tool descriptor exposed inside `SessionContext.tools`.
    public struct SessionContextTool: Equatable, Hashable, Sendable, Codable {
        public var description: String
        public var input: [String: JSONValue]

        public init(description: String, input: [String: JSONValue] = [:]) {
            self.description = description
            self.input = input
        }
    }

    /// Mutable context hook payload (`session.context`) including active agent and tool map.
    // parity: plugin/src/effect/session.ts#SessionContext [status=implemented hash=cbe372bc8267]
    public struct SessionContext: Equatable, Sendable, Codable {
        public let sessionID: SessionID
        public let model: ModelSchema.Ref
        public let agent: AgentSchema.ID
        public var system: [AISchema.SystemPart]
        public var messages: [SessionRequestMessage]
        public var options: SessionRequestOptions
        public var tools: [String: SessionContextTool]

        public init(
            sessionID: SessionID,
            model: ModelSchema.Ref,
            agent: AgentSchema.ID,
            system: [AISchema.SystemPart] = [],
            messages: [SessionRequestMessage] = [],
            options: SessionRequestOptions = SessionRequestOptions(),
            tools: [String: SessionContextTool] = [:]
        ) {
            self.sessionID = sessionID
            self.model = model
            self.agent = agent
            self.system = system
            self.messages = messages
            self.options = options
            self.tools = tools
        }
    }

    /// Short-circuit compaction result a plugin may set on `SessionCompaction.result`.
    // parity: plugin/src/effect/session.ts#SessionCompactionResult [status=implemented hash=3c2953aa85af]
    public struct SessionCompactionResult: Equatable, Sendable, Codable {
        public var summary: String
        public var native: SessionMessageSchema.Native?
        public var metadata: [String: JSONValue]?
        public var tokens: TokenUsageSchema.Info?

        public init(
            summary: String,
            native: SessionMessageSchema.Native? = nil,
            metadata: [String: JSONValue]? = nil,
            tokens: TokenUsageSchema.Info? = nil
        ) {
            self.summary = summary
            self.native = native
            self.metadata = metadata
            self.tokens = tokens
        }
    }

    /// Mutable session compaction hook payload (`session.compaction`).
    // parity: plugin/src/effect/session.ts#SessionCompaction [status=implemented hash=48c1d1fa1877]
    public struct SessionCompaction: Equatable, Sendable, Codable {
        public var context: SessionContext
        public var result: SessionCompactionResult?

        public init(context: SessionContext, result: SessionCompactionResult? = nil) {
            self.context = context
            self.result = result
        }
    }

    /// Mutable session generate hook payload (`session.generate`).
    // parity: plugin/src/effect/session.ts#SessionGenerate [status=implemented hash=eb2545f09415]
    public typealias SessionGenerate = SessionContext

    /// Mutable session title hook payload (`session.title`).
    // parity: plugin/src/effect/session.ts#SessionTitle [status=implemented hash=47cfec6fb595]
    public struct SessionTitle: Equatable, Sendable, Codable {
        public var request: SessionRequest
        public var result: String?

        public init(request: SessionRequest, result: String? = nil) {
            self.request = request
            self.result = result
        }
    }

    /// Distinguishes primary agent-loop requests from auxiliary compaction, title, and generate requests.
    // parity: plugin/src/effect/session.ts#SessionRequestKind [status=implemented hash=9e36061af721]
    public enum SessionRequestKind: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case primary
        case compaction
        case title
        case generate
    }

    /// Mutable model resolution hook payload (`session.experimental.model.resolve`).
    // parity: plugin/src/effect/session.ts#SessionModelResolve [status=implemented hash=70c786767fe0]
    public struct SessionModelResolve: Equatable, Hashable, Sendable, Codable {
        public let sessionID: SessionID
        public let agent: AgentSchema.ID
        public let kind: SessionRequestKind
        public var model: ModelSchema.Ref

        public init(
            sessionID: SessionID,
            agent: AgentSchema.ID,
            kind: SessionRequestKind,
            model: ModelSchema.Ref
        ) {
            self.sessionID = sessionID
            self.agent = agent
            self.kind = kind
            self.model = model
        }
    }

    /// Mutable model request transport hook payload (`session.model.request`).
    // parity: plugin/src/effect/session.ts#SessionModelRequest [status=implemented hash=e84516419575]
    public struct SessionModelRequest: Equatable, Hashable, Sendable, Codable {
        public let sessionID: SessionID
        public let agent: AgentSchema.ID
        public let model: ModelSchema.Ref
        public let kind: SessionRequestKind
        public var baseURL: String?
        public var headers: [String: String]

        public init(
            sessionID: SessionID,
            agent: AgentSchema.ID,
            model: ModelSchema.Ref,
            kind: SessionRequestKind,
            baseURL: String? = nil,
            headers: [String: String] = [:]
        ) {
            self.sessionID = sessionID
            self.agent = agent
            self.model = model
            self.kind = kind
            self.baseURL = baseURL
            self.headers = headers
        }
    }

    /// Mutable HTTP request interception hook payload (`session.http.request`).
    // parity: plugin/src/effect/session.ts#SessionHttpRequest [status=implemented hash=d72fc56f258b]
    public struct SessionHttpRequest: Equatable, Sendable {
        public let sessionID: SessionID
        public let agent: AgentSchema.ID
        public let model: ModelSchema.Ref
        public let kind: SessionRequestKind
        public var request: HTTPRequest

        public init(
            sessionID: SessionID,
            agent: AgentSchema.ID,
            model: ModelSchema.Ref,
            kind: SessionRequestKind,
            request: HTTPRequest
        ) {
            self.sessionID = sessionID
            self.agent = agent
            self.model = model
            self.kind = kind
            self.request = request
        }
    }

    /// Mutable HTTP response interception hook payload (`session.http.response`).
    // parity: plugin/src/effect/session.ts#SessionHttpResponse [status=implemented hash=6b511b3a1e20]
    public struct SessionHttpResponse: Equatable, Sendable {
        public let sessionID: SessionID
        public let agent: AgentSchema.ID
        public let model: ModelSchema.Ref
        public let kind: SessionRequestKind
        public let request: HTTPRequest
        public var response: HTTPResponse

        public init(
            sessionID: SessionID,
            agent: AgentSchema.ID,
            model: ModelSchema.Ref,
            kind: SessionRequestKind,
            request: HTTPRequest,
            response: HTTPResponse
        ) {
            self.sessionID = sessionID
            self.agent = agent
            self.model = model
            self.kind = kind
            self.request = request
            self.response = response
        }
    }

    /// Mutable WebSocket handshake hook payload (`session.experimental.ws.handshake`).
    // parity: plugin/src/effect/session.ts#SessionWebSocketHandshake [status=implemented hash=a3b864304480]
    public struct SessionWebSocketHandshake: Equatable, Hashable, Sendable, Codable {
        public let sessionID: SessionID
        public let agent: AgentSchema.ID
        public let model: ModelSchema.Ref
        public let kind: SessionRequestKind
        public var url: String
        public var headers: [String: String]

        public init(
            sessionID: SessionID,
            agent: AgentSchema.ID,
            model: ModelSchema.Ref,
            kind: SessionRequestKind,
            url: String,
            headers: [String: String] = [:]
        ) {
            self.sessionID = sessionID
            self.agent = agent
            self.model = model
            self.kind = kind
            self.url = url
            self.headers = headers
        }
    }

    /// Mutable outbound WebSocket frame hook payload (`session.experimental.ws.send`).
    // parity: plugin/src/effect/session.ts#SessionWebSocketSend [status=implemented hash=afa0c035a8cc]
    public struct SessionWebSocketSend: Equatable, Hashable, Sendable, Codable {
        public let sessionID: SessionID
        public let agent: AgentSchema.ID
        public let model: ModelSchema.Ref
        public let kind: SessionRequestKind
        public var frame: String

        public init(
            sessionID: SessionID,
            agent: AgentSchema.ID,
            model: ModelSchema.Ref,
            kind: SessionRequestKind,
            frame: String
        ) {
            self.sessionID = sessionID
            self.agent = agent
            self.model = model
            self.kind = kind
            self.frame = frame
        }
    }

    /// Mutable inbound WebSocket frame hook payload (`session.experimental.ws.receive`).
    // parity: plugin/src/effect/session.ts#SessionWebSocketReceive [status=implemented hash=d501d9035bee]
    public struct SessionWebSocketReceive: Equatable, Hashable, Sendable, Codable {
        public let sessionID: SessionID
        public let agent: AgentSchema.ID
        public let model: ModelSchema.Ref
        public let kind: SessionRequestKind
        public var frame: String

        public init(
            sessionID: SessionID,
            agent: AgentSchema.ID,
            model: ModelSchema.Ref,
            kind: SessionRequestKind,
            frame: String
        ) {
            self.sessionID = sessionID
            self.agent = agent
            self.model = model
            self.kind = kind
            self.frame = frame
        }
    }

    /// Retry decision mutated by `session.retry` hooks.
    // parity: plugin/src/effect/session.ts#SessionRetryDecision [status=implemented hash=bc5bd788f6e0]
    public enum SessionRetryDecision: Equatable, Hashable, Sendable, Codable {
        case doNotRetry
        case retry(delayMs: Int)
    }

    /// Mutable retry hook payload (`session.retry`).
    // parity: plugin/src/effect/session.ts#SessionRetry [status=implemented hash=2220265f70c9]
    public struct SessionRetry: Equatable, Hashable, Sendable, Codable {
        public let sessionID: SessionID
        public let agent: AgentSchema.ID
        public let model: ModelSchema.Ref
        public let error: SessionErrorSchema.Error
        public let attempt: Int
        public var decision: SessionRetryDecision

        public init(
            sessionID: SessionID,
            agent: AgentSchema.ID,
            model: ModelSchema.Ref,
            error: SessionErrorSchema.Error,
            attempt: Int,
            decision: SessionRetryDecision
        ) {
            self.sessionID = sessionID
            self.agent = agent
            self.model = model
            self.error = error
            self.attempt = attempt
            self.decision = decision
        }
    }

    /// Background work item reported to `session.experimental.idle` hooks.
    // parity: plugin/src/effect/session.ts#SessionIdleBackground [status=implemented hash=e3d895140267]
    public enum SessionIdleBackground: Equatable, Hashable, Sendable, Codable {
        case codemode(sessionID: SessionID, jobID: String)
        case shell(sessionID: SessionID, shellID: String, command: String)
        case subagent(sessionID: SessionID, childSessionID: SessionID, agent: String, description: String)
        case image(sessionID: SessionID, path: String, model: String)
        case video(sessionID: SessionID, path: String)
    }

    /// Hook payload emitted just before a session transitions to idle (`session.experimental.idle`).
    // parity: plugin/src/effect/session.ts#SessionIdle [status=implemented hash=d6a7a8975c21]
    public struct SessionIdle: Equatable, Hashable, Sendable, Codable {
        public let sessionID: SessionID
        public let background: [SessionIdleBackground]

        public init(sessionID: SessionID, background: [SessionIdleBackground] = []) {
            self.sessionID = sessionID
            self.background = background
        }
    }

    /// Tagged union of all 15 session hook events.
    // parity: plugin/src/effect/session.ts#SessionHooks [status=implemented hash=2d5eeb1b8743]
    public enum SessionHooks: Sendable {
        case fork(sessionID: SessionID)
        case prompt(SessionPrompt)
        case context(SessionContext)
        case compaction(SessionCompaction)
        case generate(SessionGenerate)
        case title(SessionTitle)
        case experimentalModelResolve(SessionModelResolve)
        case modelRequest(SessionModelRequest)
        case httpRequest(SessionHttpRequest)
        case httpResponse(SessionHttpResponse)
        case experimentalWsHandshake(SessionWebSocketHandshake)
        case experimentalWsSend(SessionWebSocketSend)
        case experimentalWsReceive(SessionWebSocketReceive)
        case retry(SessionRetry)
        case experimentalIdle(SessionIdle)

        public var hookName: String {
            switch self {
            case .fork: return "fork"
            case .prompt: return "prompt"
            case .context: return "context"
            case .compaction: return "compaction"
            case .generate: return "generate"
            case .title: return "title"
            case .experimentalModelResolve: return "experimental.model.resolve"
            case .modelRequest: return "model.request"
            case .httpRequest: return "http.request"
            case .httpResponse: return "http.response"
            case .experimentalWsHandshake: return "experimental.ws.handshake"
            case .experimentalWsSend: return "experimental.ws.send"
            case .experimentalWsReceive: return "experimental.ws.receive"
            case .retry: return "retry"
            case .experimentalIdle: return "experimental.idle"
            }
        }

        public var providerID: String? {
            switch self {
            case .context(let e): return e.model.providerID.rawValue
            case .compaction(let e): return e.context.model.providerID.rawValue
            case .generate(let e): return e.model.providerID.rawValue
            case .title(let e): return e.request.model.providerID.rawValue
            case .experimentalModelResolve(let e): return e.model.providerID.rawValue
            case .modelRequest(let e): return e.model.providerID.rawValue
            case .httpRequest(let e): return e.model.providerID.rawValue
            case .httpResponse(let e): return e.model.providerID.rawValue
            case .experimentalWsHandshake(let e): return e.model.providerID.rawValue
            case .experimentalWsSend(let e): return e.model.providerID.rawValue
            case .experimentalWsReceive(let e): return e.model.providerID.rawValue
            case .retry(let e): return e.model.providerID.rawValue
            case .fork, .prompt, .experimentalIdle: return nil
            }
        }
    }

    /// Session domain exposed on plugin contexts.
    // parity: plugin/src/effect/session.ts#SessionDomain [status=adapted hash=e00e6aec6c48]
    public struct SessionDomain: Sendable {
        public let hook: ModelHooks<SessionHooks>
        public let list: @Sendable () async throws -> [SessionSchema.Info]
        public let get: @Sendable (SessionID) async throws -> SessionSchema.Info
        public let create: @Sendable (_ title: String?, _ agent: AgentSchema.ID?, _ model: ModelSchema.Ref?) async throws -> SessionSchema.Info
        public let update: @Sendable (SessionID, SessionSchema.PermissionRuleset?) async throws -> Void
        public let remove: @Sendable (SessionID) async throws -> Void
        public let prompt: @Sendable (SessionID, PromptInputSchema.Prompt, SessionInboxSchema.Delivery) async throws -> Void
        public let synthetic: @Sendable (SessionID, String, String?, [String: JSONValue]?, Bool) async throws -> Void
        public let compact: @Sendable (SessionID) async throws -> Void
        public let interrupt: @Sendable (SessionID, Bool?) async throws -> Bool

        public init(
            hook: @escaping ModelHooks<SessionHooks>,
            list: @escaping @Sendable () async throws -> [SessionSchema.Info] = { [] },
            get: @escaping @Sendable (SessionID) async throws -> SessionSchema.Info = { id in
                throw ToolSchema.ToolError(message: "Session not found: \(id.rawValue)")
            },
            create: @escaping @Sendable (_ title: String?, _ agent: AgentSchema.ID?, _ model: ModelSchema.Ref?) async throws -> SessionSchema.Info = {
                _, _, _ in
                throw ToolSchema.ToolError(message: "Session creation unavailable")
            },
            update: @escaping @Sendable (SessionID, SessionSchema.PermissionRuleset?) async throws -> Void = { _, _ in },
            remove: @escaping @Sendable (SessionID) async throws -> Void = { _ in },
            prompt: @escaping @Sendable (SessionID, PromptInputSchema.Prompt, SessionInboxSchema.Delivery) async throws -> Void = { _, _, _ in },
            synthetic: @escaping @Sendable (SessionID, String, String?, [String: JSONValue]?, Bool) async throws -> Void = { _, _, _, _, _ in },
            compact: @escaping @Sendable (SessionID) async throws -> Void = { _ in },
            interrupt: @escaping @Sendable (SessionID, Bool?) async throws -> Bool = { _, _ in false }
        ) {
            self.hook = hook
            self.list = list
            self.get = get
            self.create = create
            self.update = update
            self.remove = remove
            self.prompt = prompt
            self.synthetic = synthetic
            self.compact = compact
            self.interrupt = interrupt
        }
    }

    // MARK: - effect/shell.ts

    /// Mutable shell spawn pre-hook payload (`shell.create.before`).
    // parity: plugin/src/effect/shell.ts#ShellCreateBefore [status=implemented hash=9540448bdcc3]
    public struct ShellCreateBefore: Equatable, Hashable, Sendable, Codable {
        public var command: String
        public var cwd: String
        public var timeout: Int
        public var shell: String
        public var env: [String: String?]

        public init(
            command: String,
            cwd: String,
            timeout: Int,
            shell: String,
            env: [String: String?] = [:]
        ) {
            self.command = command
            self.cwd = cwd
            self.timeout = timeout
            self.shell = shell
            self.env = env
        }
    }

    /// Shell hook event union.
    // parity: plugin/src/effect/shell.ts#ShellHooks [status=implemented hash=4ac7278aaa5f]
    public enum ShellHooks: Equatable, Hashable, Sendable {
        case createBefore(ShellCreateBefore)

        public var hookName: String { "create.before" }
    }

    /// Shell hook domain exposed on plugin contexts.
    // parity: plugin/src/effect/shell.ts#ShellDomain [status=implemented hash=b32a6d26694f]
    public struct ShellDomain: Sendable {
        public let hook: Hooks<ShellCreateBefore>

        public init(hook: @escaping Hooks<ShellCreateBefore>) {
            self.hook = hook
        }
    }

    // MARK: - effect/skill.ts

    /// Editor mutating registered skills.
    // parity: plugin/src/effect/skill.ts#SkillEditor [status=implemented hash=bfdd51416103]
    public struct SkillEditor: Sendable {
        public let list: @Sendable () -> [SkillSchema.Info]
        public let get: @Sendable (String) -> SkillSchema.Info?
        public let add: @Sendable (SkillSchema.Info) -> Void
        public let update: @Sendable (String, @Sendable (inout SkillSchema.Info) -> Void) -> Void
        public let remove: @Sendable (String) -> Void

        public init(
            list: @escaping @Sendable () -> [SkillSchema.Info],
            get: @escaping @Sendable (String) -> SkillSchema.Info?,
            add: @escaping @Sendable (SkillSchema.Info) -> Void,
            update: @escaping @Sendable (String, @Sendable (inout SkillSchema.Info) -> Void) -> Void,
            remove: @escaping @Sendable (String) -> Void
        ) {
            self.list = list
            self.get = get
            self.add = add
            self.update = update
            self.remove = remove
        }
    }

    /// Skill domain exposed on plugin contexts.
    // parity: plugin/src/effect/skill.ts#SkillDomain [status=implemented hash=6189077bd530]
    public struct SkillDomain: Sendable {
        public let list: @Sendable () async throws -> PluginSDK.LocatedResult<[SkillSchema.Info]>
        public let transform: Transform<SkillEditor>
        public let reload: @Sendable () async -> Void

        public init(
            list: @escaping @Sendable () async throws -> PluginSDK.LocatedResult<[SkillSchema.Info]>,
            transform: @escaping Transform<SkillEditor>,
            reload: @escaping @Sendable () async -> Void
        ) {
            self.list = list
            self.transform = transform
            self.reload = reload
        }
    }

    // MARK: - effect/storage.ts

    /// Plugin-scoped durable key-value storage domain.
    // parity: plugin/src/effect/storage.ts#StorageDomain [status=implemented hash=a30b670d09ca]
    public struct StorageDomain: Sendable {
        public let get: @Sendable (String) async throws -> JSONValue?
        public let set: @Sendable (String, JSONValue) async throws -> Void
        public let remove: @Sendable (String) async throws -> Void
        public let scan: @Sendable (PluginContract.StorageScanOptions) async throws -> PluginContract.StorageScanResult

        public init(
            get: @escaping @Sendable (String) async throws -> JSONValue?,
            set: @escaping @Sendable (String, JSONValue) async throws -> Void,
            remove: @escaping @Sendable (String) async throws -> Void,
            scan: @escaping @Sendable (PluginContract.StorageScanOptions) async throws -> PluginContract.StorageScanResult
        ) {
            self.get = get
            self.set = set
            self.remove = remove
            self.scan = scan
        }
    }

    // MARK: - effect/tool.ts

    /// Dynamic type-erased tool entry registered in the tool catalog.
    public struct DynamicToolInfo: Sendable {
        public let id: String
        public var name: String
        public var input: ToolSchema.ValueSchema
        public var freeform: ToolSchema.Freeform?
        public var description: String
        public var execute: @Sendable (JSONValue, ToolSchema.Context) async throws(ToolSchema.ToolError) -> ToolSchema.Result<JSONValue>
        public var output: ToolSchema.ValueSchema?
        public var options: ToolSchema.Options?

        public init(
            id: String? = nil,
            name: String,
            input: ToolSchema.ValueSchema,
            freeform: ToolSchema.Freeform? = nil,
            description: String,
            execute: @escaping @Sendable (JSONValue, ToolSchema.Context) async throws(ToolSchema.ToolError) -> ToolSchema.Result<JSONValue>,
            output: ToolSchema.ValueSchema? = nil,
            options: ToolSchema.Options? = nil
        ) {
            if let id {
                self.id = id
            } else if let ns = options?.namespace, !ns.isEmpty {
                self.id = "\(ns)_\(name)"
            } else {
                self.id = name
            }
            self.name = name
            self.input = input
            self.freeform = freeform
            self.description = description
            self.execute = execute
            self.output = output
            self.options = options
        }
    }

    /// Editor mutating registered tools and tool namespaces. Upstream's `add` gained Code Mode input/output type
    /// parameters (`CMInput`, `CMOutput`); Swift tool entries carry type-erased value schemas, so the signature is
    /// unchanged.
    // parity: plugin/src/effect/tool.ts#ToolEditor [status=implemented hash=efe97482f163]
    public struct ToolEditor: Sendable {
        public let list: @Sendable () -> [DynamicToolInfo]
        public let get: @Sendable (String) -> DynamicToolInfo?
        public let namespace: @Sendable (ToolSchema.Namespace) -> Void
        public let add: @Sendable (DynamicToolInfo) -> Void
        public let update: @Sendable (String, @Sendable (inout DynamicToolInfo) -> Void) -> Void
        public let remove: @Sendable (String) -> Void

        public init(
            list: @escaping @Sendable () -> [DynamicToolInfo],
            get: @escaping @Sendable (String) -> DynamicToolInfo?,
            namespace: @escaping @Sendable (ToolSchema.Namespace) -> Void,
            add: @escaping @Sendable (DynamicToolInfo) -> Void,
            update: @escaping @Sendable (String, @Sendable (inout DynamicToolInfo) -> Void) -> Void,
            remove: @escaping @Sendable (String) -> Void
        ) {
            self.list = list
            self.get = get
            self.namespace = namespace
            self.add = add
            self.update = update
            self.remove = remove
        }
    }

    /// Tool execution before/after hook payloads. `info` is the registered tool the call resolved to (absent for an
    /// unknown tool), and `codemode` whether the call came from a Code Mode script. `info` takes no part in equality,
    /// hashing or coding: a tool's execute closure has no value identity.
    // parity: plugin/src/effect/tool.ts#ToolHooks [status=implemented hash=ca459dd46a73]
    public enum ToolHooks: Sendable {
        public struct ExecuteBefore: Equatable, Hashable, Sendable, Codable {
            public var tool: String
            public let info: DynamicToolInfo?
            public let codemode: Bool
            public let sessionID: SessionID
            public let agent: AgentSchema.ID
            public let messageID: SessionMessageSchema.ID
            public let id: ToolSchema.CallID
            public var input: JSONValue

            public init(
                tool: String,
                info: DynamicToolInfo? = nil,
                codemode: Bool = false,
                sessionID: SessionID,
                agent: AgentSchema.ID,
                messageID: SessionMessageSchema.ID,
                id: ToolSchema.CallID,
                input: JSONValue
            ) {
                self.tool = tool
                self.info = info
                self.codemode = codemode
                self.sessionID = sessionID
                self.agent = agent
                self.messageID = messageID
                self.id = id
                self.input = input
            }

            enum CodingKeys: String, CodingKey {
                case tool, codemode, sessionID, agent, messageID, id, input
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.tool = try container.decode(String.self, forKey: .tool)
                self.info = nil
                self.codemode = try container.decodeIfPresent(Bool.self, forKey: .codemode) ?? false
                self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
                self.agent = try container.decode(AgentSchema.ID.self, forKey: .agent)
                self.messageID = try container.decode(SessionMessageSchema.ID.self, forKey: .messageID)
                self.id = try container.decode(ToolSchema.CallID.self, forKey: .id)
                self.input = try container.decode(JSONValue.self, forKey: .input)
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(tool, forKey: .tool)
                try container.encode(codemode, forKey: .codemode)
                try container.encode(sessionID, forKey: .sessionID)
                try container.encode(agent, forKey: .agent)
                try container.encode(messageID, forKey: .messageID)
                try container.encode(id, forKey: .id)
                try container.encode(input, forKey: .input)
            }

            public static func == (lhs: Self, rhs: Self) -> Bool {
                lhs.tool == rhs.tool && lhs.codemode == rhs.codemode && lhs.sessionID == rhs.sessionID
                    && lhs.agent == rhs.agent && lhs.messageID == rhs.messageID && lhs.id == rhs.id && lhs.input == rhs.input
            }

            public func hash(into hasher: inout Hasher) {
                hasher.combine(tool)
                hasher.combine(codemode)
                hasher.combine(sessionID)
                hasher.combine(agent)
                hasher.combine(messageID)
                hasher.combine(id)
                hasher.combine(input)
            }
        }

        public enum AfterOutcome: Equatable, Hashable, Sendable, Codable {
            case completed(ToolSchema.Result<JSONValue>)
            case error(ToolSchema.ToolError)
        }

        public struct ExecuteAfter: Equatable, Hashable, Sendable, Codable {
            public let tool: String
            public let info: DynamicToolInfo?
            public let codemode: Bool
            public let sessionID: SessionID
            public let agent: AgentSchema.ID
            public let messageID: SessionMessageSchema.ID
            public let id: ToolSchema.CallID
            public let input: JSONValue
            public var outcome: AfterOutcome

            public init(
                tool: String,
                info: DynamicToolInfo? = nil,
                codemode: Bool = false,
                sessionID: SessionID,
                agent: AgentSchema.ID,
                messageID: SessionMessageSchema.ID,
                id: ToolSchema.CallID,
                input: JSONValue,
                outcome: AfterOutcome
            ) {
                self.tool = tool
                self.info = info
                self.codemode = codemode
                self.sessionID = sessionID
                self.agent = agent
                self.messageID = messageID
                self.id = id
                self.input = input
                self.outcome = outcome
            }

            enum CodingKeys: String, CodingKey {
                case tool, codemode, sessionID, agent, messageID, id, input, outcome
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.tool = try container.decode(String.self, forKey: .tool)
                self.info = nil
                self.codemode = try container.decodeIfPresent(Bool.self, forKey: .codemode) ?? false
                self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
                self.agent = try container.decode(AgentSchema.ID.self, forKey: .agent)
                self.messageID = try container.decode(SessionMessageSchema.ID.self, forKey: .messageID)
                self.id = try container.decode(ToolSchema.CallID.self, forKey: .id)
                self.input = try container.decode(JSONValue.self, forKey: .input)
                self.outcome = try container.decode(AfterOutcome.self, forKey: .outcome)
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(tool, forKey: .tool)
                try container.encode(codemode, forKey: .codemode)
                try container.encode(sessionID, forKey: .sessionID)
                try container.encode(agent, forKey: .agent)
                try container.encode(messageID, forKey: .messageID)
                try container.encode(id, forKey: .id)
                try container.encode(input, forKey: .input)
                try container.encode(outcome, forKey: .outcome)
            }

            public static func == (lhs: Self, rhs: Self) -> Bool {
                lhs.tool == rhs.tool && lhs.codemode == rhs.codemode && lhs.sessionID == rhs.sessionID
                    && lhs.agent == rhs.agent && lhs.messageID == rhs.messageID && lhs.id == rhs.id
                    && lhs.input == rhs.input && lhs.outcome == rhs.outcome
            }

            public func hash(into hasher: inout Hasher) {
                hasher.combine(tool)
                hasher.combine(codemode)
                hasher.combine(sessionID)
                hasher.combine(agent)
                hasher.combine(messageID)
                hasher.combine(id)
                hasher.combine(input)
                hasher.combine(outcome)
            }
        }

        case executeBefore(ExecuteBefore)
        case executeAfter(ExecuteAfter)

        public var hookName: String {
            switch self {
            case .executeBefore: return "execute.before"
            case .executeAfter: return "execute.after"
            }
        }
    }

    /// Failure policy for tool hooks: only `execute.before` may fail with a `ToolSchema.ToolError` to reject the call.
    // parity: plugin/src/effect/tool.ts#ToolFailures [status=implemented hash=b24e7210c7ed]
    public enum ToolFailures: Sendable {
        public typealias ExecuteBeforeFailure = ToolSchema.ToolError
        public typealias ExecuteAfterFailure = Never

        public static func mayFail(hookName: String) -> Bool {
            hookName == "execute.before"
        }
    }

    /// Tool domain exposed on plugin contexts.
    // parity: plugin/src/effect/tool.ts#ToolDomain [status=implemented hash=ebee6dcf15c7]
    public struct ToolDomain: Sendable {
        public let transform: Transform<ToolEditor>
        public let reload: @Sendable () async -> Void
        public let list: @Sendable () async -> [DynamicToolInfo]
        public let hook: Hooks<ToolHooks>

        public init(
            transform: @escaping Transform<ToolEditor>,
            reload: @escaping @Sendable () async -> Void,
            list: @escaping @Sendable () async -> [DynamicToolInfo],
            hook: @escaping Hooks<ToolHooks>
        ) {
            self.transform = transform
            self.reload = reload
            self.list = list
            self.hook = hook
        }
    }

    // MARK: - effect/vcs.ts

    /// Directory scope passed to VCS provider methods.
    // parity: plugin/src/effect/vcs.ts#VcsScope [status=implemented hash=93bdc32715da]
    public struct VcsScope: Equatable, Hashable, Sendable, Codable {
        public let directory: String
        public let worktree: String
        public let canonical: String
        public let store: String?

        public init(directory: String, worktree: String, canonical: String, store: String? = nil) {
            self.directory = directory
            self.worktree = worktree
            self.canonical = canonical
            self.store = store
        }
    }

    /// Input passed to a VCS provider's `branches` operation.
    // parity: plugin/src/effect/vcs.ts#VcsBranchesInput [status=implemented hash=f9ea98029058]
    public struct VcsBranchesInput: Equatable, Hashable, Sendable, Codable {
        public let scope: VcsScope
        public let search: String?
        public let limit: Int?

        public init(scope: VcsScope, search: String? = nil, limit: Int? = nil) {
            self.scope = scope
            self.search = search
            self.limit = limit
        }
    }

    /// Input passed to a VCS provider's `diff` operation (including optional `untracked` handling).
    // parity: plugin/src/effect/vcs.ts#VcsDiffInput [status=implemented hash=847068920726]
    public struct VcsDiffInput: Equatable, Hashable, Sendable, Codable {
        public let scope: VcsScope
        public let mode: VcsSchema.Mode
        public let base: String?
        public let context: Int
        public let maxOutputBytes: Int
        public let untracked: VcsSchema.Untracked?

        public init(
            scope: VcsScope,
            mode: VcsSchema.Mode,
            base: String? = nil,
            context: Int = 3,
            maxOutputBytes: Int = 1_048_576,
            untracked: VcsSchema.Untracked? = nil
        ) {
            self.scope = scope
            self.mode = mode
            self.base = base
            self.context = context
            self.maxOutputBytes = maxOutputBytes
            self.untracked = untracked
        }
    }

    /// Effect-style VCS provider definition.
    // parity: plugin/src/effect/vcs.ts#VcsDefinition [status=implemented hash=b50473050ef9]
    public struct VcsDefinition: Sendable {
        public let id: String
        public let name: String
        public let initRepo: (@Sendable (VcsScope) async throws -> Void)?
        public let info: @Sendable (VcsScope) async throws -> VcsSchema.Info
        public let base: (@Sendable (VcsScope) async throws -> VcsSchema.Base?)?
        public let branches: @Sendable (VcsBranchesInput) async throws -> VcsSchema.BranchList
        public let status: @Sendable (VcsScope) async throws -> [VcsSchema.FileStatus]
        public let diff: @Sendable (VcsDiffInput) async throws -> [FileDiffSchema.Info]

        public init(
            id: String,
            name: String,
            initRepo: (@Sendable (VcsScope) async throws -> Void)? = nil,
            info: @escaping @Sendable (VcsScope) async throws -> VcsSchema.Info,
            base: (@Sendable (VcsScope) async throws -> VcsSchema.Base?)? = nil,
            branches: @escaping @Sendable (VcsBranchesInput) async throws -> VcsSchema.BranchList,
            status: @escaping @Sendable (VcsScope) async throws -> [VcsSchema.FileStatus],
            diff: @escaping @Sendable (VcsDiffInput) async throws -> [FileDiffSchema.Info]
        ) {
            self.id = id
            self.name = name
            self.initRepo = initRepo
            self.info = info
            self.base = base
            self.branches = branches
            self.status = status
            self.diff = diff
        }
    }

    /// Editor mutating registered VCS providers and default selection.
    // parity: plugin/src/effect/vcs.ts#VcsEditor [status=implemented hash=e74cb80ca9e2]
    public struct VcsEditor: Sendable {
        public let add: @Sendable (VcsDefinition) -> Void
        public let getDefault: @Sendable () -> String?
        public let setDefault: @Sendable (String) -> Void

        public init(
            add: @escaping @Sendable (VcsDefinition) -> Void,
            getDefault: @escaping @Sendable () -> String?,
            setDefault: @escaping @Sendable (String) -> Void
        ) {
            self.add = add
            self.getDefault = getDefault
            self.setDefault = setDefault
        }
    }

    /// VCS domain exposed on plugin contexts.
    // parity: plugin/src/effect/vcs.ts#VcsDomain [status=implemented hash=abed07d1e1c7]
    public struct VcsDomain: Sendable {
        public let get: @Sendable () async throws -> PluginSDK.LocatedResult<VcsSchema.Info?>
        public let base: @Sendable () async throws -> PluginSDK.LocatedResult<VcsSchema.Base?>
        public let branches: @Sendable (_ search: String?, _ limit: Int?) async throws -> PluginSDK.LocatedResult<VcsSchema.BranchList>
        public let status: @Sendable () async throws -> PluginSDK.LocatedResult<[VcsSchema.FileStatus]>
        public let diff: @Sendable (_ mode: VcsSchema.Mode, _ base: String?, _ context: Int?) async throws -> PluginSDK.LocatedResult<[FileDiffSchema.Info]>
        public let transform: Transform<VcsEditor>
        public let reload: @Sendable () async -> Void

        public init(
            get: @escaping @Sendable () async throws -> PluginSDK.LocatedResult<VcsSchema.Info?>,
            base: @escaping @Sendable () async throws -> PluginSDK.LocatedResult<VcsSchema.Base?>,
            branches: @escaping @Sendable (_ search: String?, _ limit: Int?) async throws -> PluginSDK.LocatedResult<VcsSchema.BranchList>,
            status: @escaping @Sendable () async throws -> PluginSDK.LocatedResult<[VcsSchema.FileStatus]>,
            diff: @escaping @Sendable (_ mode: VcsSchema.Mode, _ base: String?, _ context: Int?) async throws -> PluginSDK.LocatedResult<[FileDiffSchema.Info]>,
            transform: @escaping Transform<VcsEditor>,
            reload: @escaping @Sendable () async -> Void
        ) {
            self.get = get
            self.base = base
            self.branches = branches
            self.status = status
            self.diff = diff
            self.transform = transform
            self.reload = reload
        }
    }

    // MARK: - effect/websearch.ts

    /// Selection value for the default web search provider (`string` provider ID or `false` disabled).
    public enum WebSearchDefaultSelection: Equatable, Hashable, Sendable, Codable {
        case provider(String)
        case disabled
    }

    /// Effect-style web search provider definition.
    // parity: plugin/src/effect/websearch.ts#WebSearchDefinition [status=implemented hash=432d8f5246bd]
    public struct WebSearchDefinition: Sendable {
        public let id: String
        public let name: String
        public let execute: @Sendable (WebSearchSchema.ProviderInput) async throws -> [WebSearchSchema.Result]

        public init(
            id: String,
            name: String,
            execute: @escaping @Sendable (WebSearchSchema.ProviderInput) async throws -> [WebSearchSchema.Result]
        ) {
            self.id = id
            self.name = name
            self.execute = execute
        }
    }

    /// Editor mutating registered web search providers and default selection.
    // parity: plugin/src/effect/websearch.ts#WebSearchEditor [status=implemented hash=d5762f3b9d7b]
    public struct WebSearchEditor: Sendable {
        public let add: @Sendable (WebSearchDefinition) -> Void
        public let getDefault: @Sendable () -> WebSearchDefaultSelection?
        public let setDefault: @Sendable (WebSearchDefaultSelection) -> Void

        public init(
            add: @escaping @Sendable (WebSearchDefinition) -> Void,
            getDefault: @escaping @Sendable () -> WebSearchDefaultSelection?,
            setDefault: @escaping @Sendable (WebSearchDefaultSelection) -> Void
        ) {
            self.add = add
            self.getDefault = getDefault
            self.setDefault = setDefault
        }
    }

    /// Web search domain exposed on plugin contexts.
    // parity: plugin/src/effect/websearch.ts#WebSearchDomain [status=implemented hash=c3a734d4c18d]
    public struct WebSearchDomain: Sendable {
        public let providers: @Sendable () async throws -> PluginSDK.LocatedResult<[WebSearchSchema.Provider]>
        public let query: @Sendable (WebSearchSchema.Input) async throws -> PluginSDK.LocatedResult<WebSearchSchema.Response>
        public let transform: Transform<WebSearchEditor>
        public let reload: @Sendable () async -> Void

        public init(
            providers: @escaping @Sendable () async throws -> PluginSDK.LocatedResult<[WebSearchSchema.Provider]>,
            query: @escaping @Sendable (WebSearchSchema.Input) async throws -> PluginSDK.LocatedResult<WebSearchSchema.Response>,
            transform: @escaping Transform<WebSearchEditor>,
            reload: @escaping @Sendable () async -> Void
        ) {
            self.providers = providers
            self.query = query
            self.transform = transform
            self.reload = reload
        }
    }

    // MARK: - effect/worktree.ts

    /// Effect-style worktree strategy definition.
    // parity: plugin/src/effect/worktree.ts#WorktreeDefinition [status=implemented hash=abf5838b9b8a]
    public struct WorktreeDefinition: Sendable {
        public let id: String
        public let create: @Sendable (PluginContract.WorktreeCreateInput) async throws -> PluginContract.WorktreeResult
        public let remove: @Sendable (PluginContract.WorktreeRemoveInput) async throws -> Void
        public let list: @Sendable (String) async throws -> [PluginContract.WorktreeEntry]

        public init(
            id: String,
            create: @escaping @Sendable (PluginContract.WorktreeCreateInput) async throws -> PluginContract.WorktreeResult,
            remove: @escaping @Sendable (PluginContract.WorktreeRemoveInput) async throws -> Void,
            list: @escaping @Sendable (String) async throws -> [PluginContract.WorktreeEntry]
        ) {
            self.id = id
            self.create = create
            self.remove = remove
            self.list = list
        }
    }

    /// Editor registering worktree strategies (later active registrations win as default).
    // parity: plugin/src/effect/worktree.ts#WorktreeEditor [status=implemented hash=670a2d65e661]
    public struct WorktreeEditor: Sendable {
        public let add: @Sendable (WorktreeDefinition) -> Void

        public init(add: @escaping @Sendable (WorktreeDefinition) -> Void) {
            self.add = add
        }
    }

    /// Worktree domain exposed on plugin contexts.
    // parity: plugin/src/effect/worktree.ts#WorktreeDomain [status=implemented hash=6e9a431ffc28]
    public struct WorktreeDomain: Sendable {
        public let list: @Sendable () async throws -> [WorktreeSchema.ListEntry]
        public let create: @Sendable (WorktreeSchema.CreateInput) async throws -> WorktreeSchema.Info
        public let remove: @Sendable (WorktreeSchema.RemoveInput) async throws -> Void
        public let refresh: @Sendable () async throws -> Void
        public let transform: Transform<WorktreeEditor>
        public let reload: @Sendable () async -> Void

        public init(
            list: @escaping @Sendable () async throws -> [WorktreeSchema.ListEntry],
            create: @escaping @Sendable (WorktreeSchema.CreateInput) async throws -> WorktreeSchema.Info,
            remove: @escaping @Sendable (WorktreeSchema.RemoveInput) async throws -> Void,
            refresh: @escaping @Sendable () async throws -> Void,
            transform: @escaping Transform<WorktreeEditor>,
            reload: @escaping @Sendable () async -> Void
        ) {
            self.list = list
            self.create = create
            self.remove = remove
            self.refresh = refresh
            self.transform = transform
            self.reload = reload
        }
    }

    // MARK: - effect/plugin.ts

    /// Complete host context provided to an Effect-style server plugin during activation.
    // parity: plugin/src/effect/plugin.ts#Context [status=implemented hash=5f06cd8f0964]
    public struct Context: Sendable {
        public struct Experimental: Sendable {
            public let artifact: ExperimentalArtifactDomain

            public init(artifact: ExperimentalArtifactDomain) {
                self.artifact = artifact
            }
        }

        public struct PluginInventoryAPI: Sendable {
            public let list: @Sendable () async -> PluginSDK.LocatedResult<[PluginSchema.Info]>

            public init(list: @escaping @Sendable () async -> PluginSDK.LocatedResult<[PluginSchema.Info]>) {
                self.list = list
            }
        }

        public struct CredentialAPI: Sendable {
            public let activate: @Sendable (CredentialSchema.ID) async throws -> Void

            public init(activate: @escaping @Sendable (CredentialSchema.ID) async throws -> Void) {
                self.activate = activate
            }
        }

        public let app: PluginContract.App
        public let location: LocationSchema.Info
        public let options: PluginContract.PluginOptions
        public let agent: AgentDomain
        public let aisdk: AISDKDomain
        public let command: CommandDomain
        public let credential: CredentialAPI
        public let event: EventDomain
        public let experimental: Experimental
        public let integration: IntegrationDomain
        public let mcp: MCPDomain
        public let model: ModelDomain
        public let permission: PermissionDomain
        public let plugin: PluginInventoryAPI
        public let provider: ProviderDomain
        public let reference: ReferenceDomain
        public let rpc: RpcDomain
        public let session: SessionDomain
        public let shell: ShellDomain
        public let skill: SkillDomain
        public let storage: StorageDomain
        public let tool: ToolDomain
        public let vcs: VcsDomain
        public let websearch: WebSearchDomain
        public let worktree: WorktreeDomain
        public let addFinalizer: @Sendable (@escaping @Sendable () async -> Void) -> Void

        public init(
            app: PluginContract.App,
            location: LocationSchema.Info,
            options: PluginContract.PluginOptions = [:],
            agent: AgentDomain,
            aisdk: AISDKDomain,
            command: CommandDomain,
            credential: CredentialAPI,
            event: EventDomain,
            experimental: Experimental,
            integration: IntegrationDomain,
            mcp: MCPDomain,
            model: ModelDomain,
            permission: PermissionDomain,
            plugin: PluginInventoryAPI,
            provider: ProviderDomain,
            reference: ReferenceDomain,
            rpc: RpcDomain,
            session: SessionDomain,
            shell: ShellDomain,
            skill: SkillDomain,
            storage: StorageDomain,
            tool: ToolDomain,
            vcs: VcsDomain,
            websearch: WebSearchDomain,
            worktree: WorktreeDomain,
            addFinalizer: @escaping @Sendable (@escaping @Sendable () async -> Void) -> Void = { _ in }
        ) {
            self.app = app
            self.location = location
            self.options = options
            self.agent = agent
            self.aisdk = aisdk
            self.command = command
            self.credential = credential
            self.event = event
            self.experimental = experimental
            self.integration = integration
            self.mcp = mcp
            self.model = model
            self.permission = permission
            self.plugin = plugin
            self.provider = provider
            self.reference = reference
            self.rpc = rpc
            self.session = session
            self.shell = shell
            self.skill = skill
            self.storage = storage
            self.tool = tool
            self.vcs = vcs
            self.websearch = websearch
            self.worktree = worktree
            self.addFinalizer = addFinalizer
        }

        /// Returns a copy of this context with different configuration `options`.
        public func withOptions(_ options: PluginContract.PluginOptions) -> Context {
            Context(
                app: app,
                location: location,
                options: options,
                agent: agent,
                aisdk: aisdk,
                command: command,
                credential: credential,
                event: event,
                experimental: experimental,
                integration: integration,
                mcp: mcp,
                model: model,
                permission: permission,
                plugin: plugin,
                provider: provider,
                reference: reference,
                rpc: rpc,
                session: session,
                shell: shell,
                skill: skill,
                storage: storage,
                tool: tool,
                vcs: vcs,
                websearch: websearch,
                worktree: worktree,
                addFinalizer: addFinalizer
            )
        }
    }

    /// Server plugin definition executed inside a scoped activation lifetime.
    // parity: plugin/src/effect/plugin.ts#Plugin [status=implemented hash=dd0c880e9721]
    public struct Plugin: Sendable {
        public let id: String
        public let effect: @Sendable (Context) async throws -> Void

        public init(id: String, effect: @escaping @Sendable (Context) async throws -> Void) {
            self.id = id
            self.effect = effect
        }
    }

    /// Identity helper defining an Effect-style server plugin.
    // parity: plugin/src/effect/plugin.ts#define [status=implemented hash=47ceb6af63bc]
    public static func define(_ plugin: Plugin) -> Plugin {
        plugin
    }
}

// MARK: - Promise-Style Server Plugin SDK (`packages/plugin/src/promise/*`)

/// Swift 6.2 port of the Promise/async-await OpenCode server plugin SDK (`packages/plugin/src/promise/*`).
public enum PluginPromise {
    // MARK: - promise/registration.ts

    /// Promise-style disposable registration handle.
    // parity: plugin/src/promise/registration.ts#Registration [status=implemented hash=d7f846266fe4]
    public typealias Registration = PluginEffect.Registration

    /// Optional provider filter scoping a model hook to one provider ID.
    // parity: plugin/src/promise/registration.ts#ModelHookOptions [status=implemented hash=bf5af9ce9bbc]
    public typealias ModelHookOptions = PluginEffect.ModelHookOptions

    /// Promise-style hook registration function type.
    // parity: plugin/src/promise/registration.ts#Hooks [status=adapted hash=74ba5f0775f2]
    public typealias Hooks<Event: Sendable> = PluginEffect.Hooks<Event>

    /// Promise-style model hook registration function type.
    // parity: plugin/src/promise/registration.ts#ModelHooks [status=adapted hash=69f6a5347a11]
    public typealias ModelHooks<Event: Sendable> = PluginEffect.ModelHooks<Event>

    /// Promise-style synchronous state transform registration.
    // parity: plugin/src/promise/registration.ts#Transform [status=adapted hash=e2e84be41c08]
    public typealias Transform<Editor: Sendable> = PluginEffect.Transform<Editor>

    // MARK: - promise/agent.ts

    // parity: plugin/src/promise/agent.ts#AgentEditor [status=implemented hash=8dd1dd304cca]
    public typealias AgentEditor = PluginEffect.AgentEditor

    // parity: plugin/src/promise/agent.ts#AgentDomain [status=implemented hash=7978cbc1a189]
    public typealias AgentDomain = PluginEffect.AgentDomain

    // MARK: - promise/aisdk.ts

    // parity: plugin/src/promise/aisdk.ts#AISDKHooks [status=adapted hash=6eda14735ca8]
    public typealias AISDKHooks = PluginEffect.AISDKHooks

    // parity: plugin/src/promise/aisdk.ts#AISDKDomain [status=implemented hash=54d540cdbb6e]
    public typealias AISDKDomain = PluginEffect.AISDKDomain

    // MARK: - promise/artifact.ts

    // parity: plugin/src/promise/artifact.ts#ArtifactProviderCreateInput [status=implemented hash=65559080a522]
    public typealias ArtifactProviderCreateInput = PluginEffect.ArtifactProviderCreateInput

    // parity: plugin/src/promise/artifact.ts#ArtifactProviderUpdateInput [status=implemented hash=ec0bf093bea4]
    public typealias ArtifactProviderUpdateInput = PluginEffect.ArtifactProviderUpdateInput

    // parity: plugin/src/promise/artifact.ts#ArtifactProviderResult [status=implemented hash=8c670224a1c7]
    public typealias ArtifactProviderResult = PluginEffect.ArtifactProviderResult

    /// Signal context passed to Promise-style provider callbacks.
    public struct SignalContext: Sendable {
        public let signal: AbortSignal

        public init(signal: AbortSignal = AbortController().signal) {
            self.signal = signal
        }
    }

    /// Promise-style artifact provider definition carrying an `AbortSignal` per operation.
    // parity: plugin/src/promise/artifact.ts#ArtifactProviderDefinition [status=implemented hash=35b39774c491]
    public struct ArtifactProviderDefinition: Sendable {
        public let id: String
        public let name: String
        public let capabilities: [ArtifactSchema.Capability]
        public let prompt: String
        public let create: @Sendable (ArtifactProviderCreateInput, SignalContext) async throws -> ArtifactProviderResult
        public let read: @Sendable (ArtifactSchema.ID, SignalContext) async throws -> [String: [UInt8]]
        public let update: @Sendable (ArtifactSchema.ID, ArtifactProviderUpdateInput, SignalContext) async throws -> ArtifactProviderResult
        public let delete: @Sendable (ArtifactSchema.ID, SignalContext) async throws -> Void

        public init(
            id: String,
            name: String,
            capabilities: [ArtifactSchema.Capability],
            prompt: String,
            create: @escaping @Sendable (ArtifactProviderCreateInput, SignalContext) async throws -> ArtifactProviderResult,
            read: @escaping @Sendable (ArtifactSchema.ID, SignalContext) async throws -> [String: [UInt8]],
            update: @escaping @Sendable (ArtifactSchema.ID, ArtifactProviderUpdateInput, SignalContext) async throws -> ArtifactProviderResult,
            delete: @escaping @Sendable (ArtifactSchema.ID, SignalContext) async throws -> Void
        ) {
            self.id = id
            self.name = name
            self.capabilities = capabilities
            self.prompt = prompt
            self.create = create
            self.read = read
            self.update = update
            self.delete = delete
        }
    }

    // parity: plugin/src/promise/artifact.ts#ArtifactEditor [status=implemented hash=fd2597fa1491]
    public struct ArtifactEditor: Sendable {
        public let add: @Sendable (ArtifactProviderDefinition) -> Void
        public let remove: @Sendable (String) -> Void
        public let getDefault: @Sendable () -> String?
        public let setDefault: @Sendable (String?) -> Void

        public init(
            add: @escaping @Sendable (ArtifactProviderDefinition) -> Void,
            remove: @escaping @Sendable (String) -> Void,
            getDefault: @escaping @Sendable () -> String?,
            setDefault: @escaping @Sendable (String?) -> Void
        ) {
            self.add = add
            self.remove = remove
            self.getDefault = getDefault
            self.setDefault = setDefault
        }
    }

    // parity: plugin/src/promise/artifact.ts#ExperimentalArtifactDomain [status=implemented hash=a2f723b94764]
    public struct ExperimentalArtifactDomain: Sendable {
        public let transform: Transform<ArtifactEditor>
        public let reload: @Sendable () async -> Void

        public init(
            transform: @escaping Transform<ArtifactEditor>,
            reload: @escaping @Sendable () async -> Void
        ) {
            self.transform = transform
            self.reload = reload
        }
    }

    // MARK: - promise/command.ts

    // parity: plugin/src/promise/command.ts#CommandInvocation [status=implemented hash=658c5cb3a490]
    public typealias CommandInvocation = PluginEffect.CommandInvocation

    // parity: plugin/src/promise/command.ts#CommandDefinition [status=implemented hash=21b70c81bbf4]
    public typealias CommandDefinition = PluginEffect.CommandDefinition

    // parity: plugin/src/promise/command.ts#CommandEditor [status=implemented hash=a91f4d886f95]
    public typealias CommandEditor = PluginEffect.CommandEditor

    // parity: plugin/src/promise/command.ts#CommandDomain [status=implemented hash=8c13be2e8789]
    public typealias CommandDomain = PluginEffect.CommandDomain

    // MARK: - promise/event.ts

    // parity: plugin/src/promise/event.ts#EventDomain [status=adapted hash=e180a3f3898b]
    public struct EventDomain: Sendable {
        public let subscribe: @Sendable (_ types: [String]?, _ signal: AbortSignal?) -> AsyncStream<PluginSDK.EventPayload>

        public init(
            subscribe: @escaping @Sendable (_ types: [String]?, _ signal: AbortSignal?) -> AsyncStream<PluginSDK.EventPayload>
        ) {
            self.subscribe = subscribe
        }
    }

    // MARK: - promise/integration.ts

    // parity: plugin/src/promise/integration.ts#IntegrationOAuthMethod [status=implemented hash=addb0ca8ba6b]
    public typealias IntegrationOAuthMethod = PluginEffect.IntegrationOAuthMethod

    // parity: plugin/src/promise/integration.ts#IntegrationCommandMethod [status=implemented hash=2f3ad078b44b]
    public typealias IntegrationCommandMethod = PluginEffect.IntegrationCommandMethod

    // parity: plugin/src/promise/integration.ts#IntegrationKeyMethod [status=implemented hash=602ff347cd3b]
    public typealias IntegrationKeyMethod = PluginEffect.IntegrationKeyMethod

    // parity: plugin/src/promise/integration.ts#IntegrationExternalMethod [status=implemented hash=5b914b0862d8]
    public typealias IntegrationExternalMethod = PluginEffect.IntegrationExternalMethod

    // parity: plugin/src/promise/integration.ts#IntegrationEnvMethod [status=implemented hash=745945249f5c]
    public typealias IntegrationEnvMethod = PluginEffect.IntegrationEnvMethod

    // parity: plugin/src/promise/integration.ts#IntegrationMethod [status=implemented hash=026aeacd2bfd]
    public typealias IntegrationMethod = PluginEffect.IntegrationMethod

    // parity: plugin/src/promise/integration.ts#IntegrationOAuthAuthorization [status=implemented hash=cfc12bf835c1]
    public typealias IntegrationOAuthAuthorization = PluginEffect.IntegrationOAuthAuthorization

    /// Shared with the Effect SDK: `revoke` rejections are logged and the credential is still removed.
    // parity: plugin/src/promise/integration.ts#IntegrationOAuthMethodRegistration [status=implemented hash=470cabb82c73]
    public typealias IntegrationOAuthMethodRegistration = PluginEffect.IntegrationOAuthMethodRegistration

    // parity: plugin/src/promise/integration.ts#IntegrationMethodRegistration [status=implemented hash=5d8217176ec7]
    public typealias IntegrationMethodRegistration = PluginEffect.IntegrationMethodRegistration

    // parity: plugin/src/promise/integration.ts#IntegrationEditor [status=implemented hash=1d65f670d66b]
    public typealias IntegrationEditor = PluginEffect.IntegrationEditor

    // parity: plugin/src/promise/integration.ts#IntegrationDomain [status=implemented hash=aa467287f7ba]
    public typealias IntegrationDomain = PluginEffect.IntegrationDomain

    // MARK: - promise/mcp.ts

    // parity: plugin/src/promise/mcp.ts#MCPEditor [status=implemented hash=d36b640d8126]
    public typealias MCPEditor = PluginEffect.MCPEditor

    // parity: plugin/src/promise/mcp.ts#MCPDomain [status=implemented hash=537ba9d850e7]
    public typealias MCPDomain = PluginEffect.MCPDomain

    // MARK: - promise/provider.ts

    // parity: plugin/src/promise/provider.ts#ProviderRecord [status=implemented hash=ec12041b21f4]
    public typealias ProviderRecord = PluginEffect.ProviderRecord

    // parity: plugin/src/promise/provider.ts#ProviderEditor [status=implemented hash=1893ba7e480e]
    public typealias ProviderEditor = PluginEffect.ProviderEditor

    // parity: plugin/src/promise/provider.ts#ProviderDomain [status=implemented hash=a5f89a05b7a3]
    public typealias ProviderDomain = PluginEffect.ProviderDomain

    // MARK: - promise/model.ts

    // parity: plugin/src/promise/model.ts#ModelEditor [status=implemented hash=442412f08654]
    public typealias ModelEditor = PluginEffect.ModelEditor

    // parity: plugin/src/promise/model.ts#ModelDomain [status=implemented hash=6b372bbb08e6]
    public typealias ModelDomain = PluginEffect.ModelDomain

    // MARK: - promise/permission.ts

    // parity: plugin/src/promise/permission.ts#PermissionEvaluation [status=implemented hash=0d1119074505]
    public typealias PermissionEvaluation = PluginEffect.PermissionEvaluation

    // parity: plugin/src/promise/permission.ts#PermissionHooks [status=implemented hash=5d0c3de29127]
    public typealias PermissionHooks = PluginEffect.PermissionHooks

    // parity: plugin/src/promise/permission.ts#PermissionDomain [status=implemented hash=11c2ee146f02]
    public typealias PermissionDomain = PluginEffect.PermissionDomain

    // MARK: - promise/reference.ts

    // parity: plugin/src/promise/reference.ts#ReferenceEditor [status=implemented hash=267a1ae1b1ea]
    public typealias ReferenceEditor = PluginEffect.ReferenceEditor

    // parity: plugin/src/promise/reference.ts#ReferenceDomain [status=implemented hash=d276be841c5e]
    public typealias ReferenceDomain = PluginEffect.ReferenceDomain

    // MARK: - promise/rpc.ts

    /// Per-call context supplied to a Promise RPC method handler, including cancellation `signal`.
    // parity: plugin/src/promise/rpc.ts#RpcCallContext [status=implemented hash=9e961d16b161]
    public struct RpcCallContext: Sendable {
        public let signal: AbortSignal
        public let error: @Sendable (_ type: String, _ message: String, _ data: JSONValue?) -> RpcSchema.Failure<JSONValue>

        public init(
            signal: AbortSignal = AbortController().signal,
            error: @escaping @Sendable (_ type: String, _ message: String, _ data: JSONValue?) -> RpcSchema.Failure<JSONValue> = {
                type, message, data in
                RpcSchema.Failure<JSONValue>(type: type, message: message, data: data)
            }
        ) {
            self.signal = signal
            self.error = error
        }
    }

    /// Map of RPC method names to Promise-style async handlers.
    // parity: plugin/src/promise/rpc.ts#RpcHandlers [status=adapted hash=378d798cf116]
    public typealias RpcHandlers = [String: @Sendable (JSONValue, RpcCallContext) async throws -> JSONValue]

    // parity: plugin/src/promise/rpc.ts#RpcRegistration [status=implemented hash=a6d4d2784502]
    public typealias RpcRegistration = PluginEffect.RpcRegistration

    // parity: plugin/src/promise/rpc.ts#RpcDomain [status=adapted hash=7d54879486b9]
    public struct RpcDomain: Sendable {
        public let call: @Sendable (_ namespace: String, _ method: String, _ input: JSONValue, _ signal: AbortSignal?) async throws -> JSONValue
        public let subscribe: @Sendable (_ namespace: String, _ event: String, _ signal: AbortSignal?) -> AsyncStream<RpcSchema.EventPayload>
        public let register: @Sendable (RpcSchema.PortableDefinition, RpcHandlers) async throws -> RpcRegistration

        public init(
            call: @escaping @Sendable (_ namespace: String, _ method: String, _ input: JSONValue, _ signal: AbortSignal?) async throws -> JSONValue,
            subscribe: @escaping @Sendable (_ namespace: String, _ event: String, _ signal: AbortSignal?) -> AsyncStream<RpcSchema.EventPayload>,
            register: @escaping @Sendable (RpcSchema.PortableDefinition, RpcHandlers) async throws -> RpcRegistration
        ) {
            self.call = call
            self.subscribe = subscribe
            self.register = register
        }
    }

    // MARK: - promise/session.ts

    // parity: plugin/src/promise/session.ts#SessionPrompt [status=implemented hash=e2095b67fec2]
    public typealias SessionPrompt = PluginEffect.SessionPrompt

    // parity: plugin/src/promise/session.ts#SessionRequestOptions [status=implemented hash=be1293a3e9b1]
    public typealias SessionRequestOptions = PluginEffect.SessionRequestOptions

    // parity: plugin/src/promise/session.ts#SessionRequestMessage [status=implemented hash=e2c105118de9]
    public typealias SessionRequestMessage = PluginEffect.SessionRequestMessage

    // parity: plugin/src/promise/session.ts#SessionRequest [status=implemented hash=3d2e16cf132a]
    public typealias SessionRequest = PluginEffect.SessionRequest

    // parity: plugin/src/promise/session.ts#SessionContext [status=implemented hash=cbe372bc8267]
    public typealias SessionContext = PluginEffect.SessionContext

    // parity: plugin/src/promise/session.ts#SessionCompactionResult [status=implemented hash=3c2953aa85af]
    public typealias SessionCompactionResult = PluginEffect.SessionCompactionResult

    // parity: plugin/src/promise/session.ts#SessionCompaction [status=implemented hash=48c1d1fa1877]
    public typealias SessionCompaction = PluginEffect.SessionCompaction

    // parity: plugin/src/promise/session.ts#SessionGenerate [status=implemented hash=eb2545f09415]
    public typealias SessionGenerate = PluginEffect.SessionGenerate

    // parity: plugin/src/promise/session.ts#SessionTitle [status=implemented hash=47cfec6fb595]
    public typealias SessionTitle = PluginEffect.SessionTitle

    // parity: plugin/src/promise/session.ts#SessionRequestKind [status=implemented hash=9e36061af721]
    public typealias SessionRequestKind = PluginEffect.SessionRequestKind

    // parity: plugin/src/promise/session.ts#SessionModelResolve [status=implemented hash=70c786767fe0]
    public typealias SessionModelResolve = PluginEffect.SessionModelResolve

    // parity: plugin/src/promise/session.ts#SessionModelRequest [status=implemented hash=e84516419575]
    public typealias SessionModelRequest = PluginEffect.SessionModelRequest

    // parity: plugin/src/promise/session.ts#SessionHttpRequest [status=implemented hash=d72fc56f258b]
    public typealias SessionHttpRequest = PluginEffect.SessionHttpRequest

    // parity: plugin/src/promise/session.ts#SessionHttpResponse [status=implemented hash=6b511b3a1e20]
    public typealias SessionHttpResponse = PluginEffect.SessionHttpResponse

    // parity: plugin/src/promise/session.ts#SessionWebSocketHandshake [status=implemented hash=a3b864304480]
    public typealias SessionWebSocketHandshake = PluginEffect.SessionWebSocketHandshake

    // parity: plugin/src/promise/session.ts#SessionWebSocketSend [status=implemented hash=afa0c035a8cc]
    public typealias SessionWebSocketSend = PluginEffect.SessionWebSocketSend

    // parity: plugin/src/promise/session.ts#SessionWebSocketReceive [status=implemented hash=d501d9035bee]
    public typealias SessionWebSocketReceive = PluginEffect.SessionWebSocketReceive

    // parity: plugin/src/promise/session.ts#SessionRetryDecision [status=implemented hash=bc5bd788f6e0]
    public typealias SessionRetryDecision = PluginEffect.SessionRetryDecision

    // parity: plugin/src/promise/session.ts#SessionRetry [status=implemented hash=2220265f70c9]
    public typealias SessionRetry = PluginEffect.SessionRetry

    // parity: plugin/src/promise/session.ts#SessionIdleBackground [status=implemented hash=e3d895140267]
    public typealias SessionIdleBackground = PluginEffect.SessionIdleBackground

    // parity: plugin/src/promise/session.ts#SessionIdle [status=implemented hash=d6a7a8975c21]
    public typealias SessionIdle = PluginEffect.SessionIdle

    // parity: plugin/src/promise/session.ts#SessionHooks [status=implemented hash=2d5eeb1b8743]
    public typealias SessionHooks = PluginEffect.SessionHooks

    // parity: plugin/src/promise/session.ts#SessionDomain [status=adapted hash=edce4276ccfd]
    public typealias SessionDomain = PluginEffect.SessionDomain

    // MARK: - promise/shell.ts

    // parity: plugin/src/promise/shell.ts#ShellCreateBefore [status=implemented hash=9540448bdcc3]
    public typealias ShellCreateBefore = PluginEffect.ShellCreateBefore

    // parity: plugin/src/promise/shell.ts#ShellHooks [status=implemented hash=4ac7278aaa5f]
    public typealias ShellHooks = PluginEffect.ShellHooks

    // parity: plugin/src/promise/shell.ts#ShellDomain [status=implemented hash=b32a6d26694f]
    public typealias ShellDomain = PluginEffect.ShellDomain

    // MARK: - promise/skill.ts

    // parity: plugin/src/promise/skill.ts#SkillEditor [status=implemented hash=bfdd51416103]
    public typealias SkillEditor = PluginEffect.SkillEditor

    // parity: plugin/src/promise/skill.ts#SkillDomain [status=implemented hash=f7c47b08401c]
    public typealias SkillDomain = PluginEffect.SkillDomain

    // MARK: - promise/storage.ts

    // parity: plugin/src/promise/storage.ts#StorageDomain [status=implemented hash=bcae73300601]
    public typealias StorageDomain = PluginEffect.StorageDomain

    // MARK: - promise/tool.ts

    /// Execution context for a Promise-style tool using cooperative `AbortSignal`.
    // parity: plugin/src/promise/tool.ts#ToolContext [status=implemented hash=d3607c527455]
    public struct ToolContext: Sendable {
        public let sessionID: SessionID
        public let agent: AgentSchema.ID
        public let messageID: String
        public let id: ToolSchema.CallID
        public let signal: AbortSignal
        public let progress: @Sendable (ToolSchema.Metadata) async -> Void

        public init(
            sessionID: SessionID,
            agent: AgentSchema.ID,
            messageID: String,
            id: ToolSchema.CallID,
            signal: AbortSignal = AbortController().signal,
            progress: @escaping @Sendable (ToolSchema.Metadata) async -> Void
        ) {
            self.sessionID = sessionID
            self.agent = agent
            self.messageID = messageID
            self.id = id
            self.signal = signal
            self.progress = progress
        }
    }

    /// Promise-style tool definition. Upstream's `Info` gained Code Mode input/output type parameters (`CMInput`,
    /// `CMOutput`): `execute` takes either input shape and returns either output. Swift entries carry type-erased JSON
    /// values and `options.codemode` carries the Code Mode schemas (`ToolSchema.CodeModeOptions`), so the shape holds.
    // parity: plugin/src/promise/tool.ts#Info [status=implemented hash=e836e24677b6]
    public struct Info: Sendable {
        public let id: String
        public var name: String
        public var input: ToolSchema.ValueSchema
        public var freeform: ToolSchema.Freeform?
        public var description: String
        public var execute: @Sendable (JSONValue, ToolContext) async throws -> ToolSchema.Result<JSONValue>
        public var output: ToolSchema.ValueSchema?
        public var options: ToolSchema.Options?

        public init(
            id: String? = nil,
            name: String,
            input: ToolSchema.ValueSchema,
            freeform: ToolSchema.Freeform? = nil,
            description: String,
            execute: @escaping @Sendable (JSONValue, ToolContext) async throws -> ToolSchema.Result<JSONValue>,
            output: ToolSchema.ValueSchema? = nil,
            options: ToolSchema.Options? = nil
        ) {
            if let id {
                self.id = id
            } else if let ns = options?.namespace, !ns.isEmpty {
                self.id = "\(ns)_\(name)"
            } else {
                self.id = name
            }
            self.name = name
            self.input = input
            self.freeform = freeform
            self.description = description
            self.execute = execute
            self.output = output
            self.options = options
        }
    }

    /// Promise-style tool registry editor. Upstream's `add` gained Code Mode input/output type parameters; Swift tool
    /// entries carry type-erased value schemas, so the signature is unchanged.
    // parity: plugin/src/promise/tool.ts#ToolEditor [status=implemented hash=ef6028976806]
    public struct ToolEditor: Sendable {
        public let list: @Sendable () -> [Info]
        public let get: @Sendable (String) -> Info?
        public let namespace: @Sendable (ToolSchema.Namespace) -> Void
        public let add: @Sendable (Info) -> Void
        public let update: @Sendable (String, @Sendable (inout Info) -> Void) -> Void
        public let remove: @Sendable (String) -> Void

        public init(
            list: @escaping @Sendable () -> [Info],
            get: @escaping @Sendable (String) -> Info?,
            namespace: @escaping @Sendable (ToolSchema.Namespace) -> Void,
            add: @escaping @Sendable (Info) -> Void,
            update: @escaping @Sendable (String, @Sendable (inout Info) -> Void) -> Void,
            remove: @escaping @Sendable (String) -> Void
        ) {
            self.list = list
            self.get = get
            self.namespace = namespace
            self.add = add
            self.update = update
            self.remove = remove
        }
    }

    /// Promise-style tool execution hook payloads: as the Effect SDK's, with `info` as a Promise-style tool.
    // parity: plugin/src/promise/tool.ts#ToolHooks [status=implemented hash=2e36cfa2b9e8]
    public enum ToolHooks: Sendable {
        public struct ExecuteBefore: Sendable {
            public var tool: String
            public let info: Info?
            public let codemode: Bool
            public let sessionID: SessionID
            public let agent: AgentSchema.ID
            public let messageID: SessionMessageSchema.ID
            public let id: ToolSchema.CallID
            public var input: JSONValue

            public init(
                tool: String,
                info: Info? = nil,
                codemode: Bool = false,
                sessionID: SessionID,
                agent: AgentSchema.ID,
                messageID: SessionMessageSchema.ID,
                id: ToolSchema.CallID,
                input: JSONValue
            ) {
                self.tool = tool
                self.info = info
                self.codemode = codemode
                self.sessionID = sessionID
                self.agent = agent
                self.messageID = messageID
                self.id = id
                self.input = input
            }
        }

        public struct ExecuteAfter: Sendable {
            public let tool: String
            public let info: Info?
            public let codemode: Bool
            public let sessionID: SessionID
            public let agent: AgentSchema.ID
            public let messageID: SessionMessageSchema.ID
            public let id: ToolSchema.CallID
            public let input: JSONValue
            public var outcome: PluginEffect.ToolHooks.AfterOutcome

            public init(
                tool: String,
                info: Info? = nil,
                codemode: Bool = false,
                sessionID: SessionID,
                agent: AgentSchema.ID,
                messageID: SessionMessageSchema.ID,
                id: ToolSchema.CallID,
                input: JSONValue,
                outcome: PluginEffect.ToolHooks.AfterOutcome
            ) {
                self.tool = tool
                self.info = info
                self.codemode = codemode
                self.sessionID = sessionID
                self.agent = agent
                self.messageID = messageID
                self.id = id
                self.input = input
                self.outcome = outcome
            }
        }

        case executeBefore(ExecuteBefore)
        case executeAfter(ExecuteAfter)

        public var hookName: String {
            switch self {
            case .executeBefore: return "execute.before"
            case .executeAfter: return "execute.after"
            }
        }
    }

    /// Promise-style tool domain exposed on plugin contexts.
    // parity: plugin/src/promise/tool.ts#ToolDomain [status=implemented hash=f8089d9ec451]
    public struct ToolDomain: Sendable {
        public let transform: Transform<ToolEditor>
        public let reload: @Sendable () async -> Void
        public let list: @Sendable () async -> [Info]
        public let hook: Hooks<ToolHooks>

        public init(
            transform: @escaping Transform<ToolEditor>,
            reload: @escaping @Sendable () async -> Void,
            list: @escaping @Sendable () async -> [Info],
            hook: @escaping Hooks<ToolHooks>
        ) {
            self.transform = transform
            self.reload = reload
            self.list = list
            self.hook = hook
        }
    }

    // MARK: - promise/vcs.ts

    // parity: plugin/src/promise/vcs.ts#VcsScope [status=implemented hash=93bdc32715da]
    public typealias VcsScope = PluginEffect.VcsScope

    // parity: plugin/src/promise/vcs.ts#VcsBranchesInput [status=implemented hash=f9ea98029058]
    public typealias VcsBranchesInput = PluginEffect.VcsBranchesInput

    /// Promise-style VCS diff input (without Effect-internal `untracked` option).
    // parity: plugin/src/promise/vcs.ts#VcsDiffInput [status=implemented hash=4e493b7b4f78]
    public struct VcsDiffInput: Equatable, Hashable, Sendable, Codable {
        public let scope: VcsScope
        public let mode: VcsSchema.Mode
        public let base: String?
        public let context: Int
        public let maxOutputBytes: Int

        public init(
            scope: VcsScope,
            mode: VcsSchema.Mode,
            base: String? = nil,
            context: Int = 3,
            maxOutputBytes: Int = 1_048_576
        ) {
            self.scope = scope
            self.mode = mode
            self.base = base
            self.context = context
            self.maxOutputBytes = maxOutputBytes
        }
    }

    /// Promise-style VCS provider definition carrying an `AbortSignal`.
    // parity: plugin/src/promise/vcs.ts#VcsDefinition [status=implemented hash=db24d8277f9e]
    public struct VcsDefinition: Sendable {
        public let id: String
        public let name: String
        public let initRepo: (@Sendable (VcsScope, SignalContext) async throws -> Void)?
        public let info: @Sendable (VcsScope, SignalContext) async throws -> VcsSchema.Info
        public let base: (@Sendable (VcsScope, SignalContext) async throws -> VcsSchema.Base?)?
        public let branches: @Sendable (VcsBranchesInput, SignalContext) async throws -> VcsSchema.BranchList
        public let status: @Sendable (VcsScope, SignalContext) async throws -> [VcsSchema.FileStatus]
        public let diff: @Sendable (VcsDiffInput, SignalContext) async throws -> [FileDiffSchema.Info]

        public init(
            id: String,
            name: String,
            initRepo: (@Sendable (VcsScope, SignalContext) async throws -> Void)? = nil,
            info: @escaping @Sendable (VcsScope, SignalContext) async throws -> VcsSchema.Info,
            base: (@Sendable (VcsScope, SignalContext) async throws -> VcsSchema.Base?)? = nil,
            branches: @escaping @Sendable (VcsBranchesInput, SignalContext) async throws -> VcsSchema.BranchList,
            status: @escaping @Sendable (VcsScope, SignalContext) async throws -> [VcsSchema.FileStatus],
            diff: @escaping @Sendable (VcsDiffInput, SignalContext) async throws -> [FileDiffSchema.Info]
        ) {
            self.id = id
            self.name = name
            self.initRepo = initRepo
            self.info = info
            self.base = base
            self.branches = branches
            self.status = status
            self.diff = diff
        }
    }

    // parity: plugin/src/promise/vcs.ts#VcsEditor [status=implemented hash=e74cb80ca9e2]
    public struct VcsEditor: Sendable {
        public let add: @Sendable (VcsDefinition) -> Void
        public let getDefault: @Sendable () -> String?
        public let setDefault: @Sendable (String) -> Void

        public init(
            add: @escaping @Sendable (VcsDefinition) -> Void,
            getDefault: @escaping @Sendable () -> String?,
            setDefault: @escaping @Sendable (String) -> Void
        ) {
            self.add = add
            self.getDefault = getDefault
            self.setDefault = setDefault
        }
    }

    // parity: plugin/src/promise/vcs.ts#VcsDomain [status=implemented hash=763d36cca4dc]
    public struct VcsDomain: Sendable {
        public let get: @Sendable () async throws -> PluginSDK.LocatedResult<VcsSchema.Info?>
        public let base: @Sendable () async throws -> PluginSDK.LocatedResult<VcsSchema.Base?>
        public let branches: @Sendable (_ search: String?, _ limit: Int?) async throws -> PluginSDK.LocatedResult<VcsSchema.BranchList>
        public let status: @Sendable () async throws -> PluginSDK.LocatedResult<[VcsSchema.FileStatus]>
        public let diff: @Sendable (_ mode: VcsSchema.Mode, _ base: String?, _ context: Int?) async throws -> PluginSDK.LocatedResult<[FileDiffSchema.Info]>
        public let transform: Transform<VcsEditor>
        public let reload: @Sendable () async -> Void

        public init(
            get: @escaping @Sendable () async throws -> PluginSDK.LocatedResult<VcsSchema.Info?>,
            base: @escaping @Sendable () async throws -> PluginSDK.LocatedResult<VcsSchema.Base?>,
            branches: @escaping @Sendable (_ search: String?, _ limit: Int?) async throws -> PluginSDK.LocatedResult<VcsSchema.BranchList>,
            status: @escaping @Sendable () async throws -> PluginSDK.LocatedResult<[VcsSchema.FileStatus]>,
            diff: @escaping @Sendable (_ mode: VcsSchema.Mode, _ base: String?, _ context: Int?) async throws -> PluginSDK.LocatedResult<[FileDiffSchema.Info]>,
            transform: @escaping Transform<VcsEditor>,
            reload: @escaping @Sendable () async -> Void
        ) {
            self.get = get
            self.base = base
            self.branches = branches
            self.status = status
            self.diff = diff
            self.transform = transform
            self.reload = reload
        }
    }

    // MARK: - promise/websearch.ts

    // parity: plugin/src/promise/websearch.ts#WebSearchDefinition [status=implemented hash=6fc62cf0fbf4]
    public struct WebSearchDefinition: Sendable {
        public let id: String
        public let name: String
        public let execute: @Sendable (WebSearchSchema.ProviderInput, SignalContext) async throws -> [WebSearchSchema.Result]

        public init(
            id: String,
            name: String,
            execute: @escaping @Sendable (WebSearchSchema.ProviderInput, SignalContext) async throws -> [WebSearchSchema.Result]
        ) {
            self.id = id
            self.name = name
            self.execute = execute
        }
    }

    // parity: plugin/src/promise/websearch.ts#WebSearchEditor [status=implemented hash=d5762f3b9d7b]
    public struct WebSearchEditor: Sendable {
        public let add: @Sendable (WebSearchDefinition) -> Void
        public let getDefault: @Sendable () -> PluginEffect.WebSearchDefaultSelection?
        public let setDefault: @Sendable (PluginEffect.WebSearchDefaultSelection) -> Void

        public init(
            add: @escaping @Sendable (WebSearchDefinition) -> Void,
            getDefault: @escaping @Sendable () -> PluginEffect.WebSearchDefaultSelection?,
            setDefault: @escaping @Sendable (PluginEffect.WebSearchDefaultSelection) -> Void
        ) {
            self.add = add
            self.getDefault = getDefault
            self.setDefault = setDefault
        }
    }

    // parity: plugin/src/promise/websearch.ts#WebSearchDomain [status=implemented hash=d841d8b22596]
    public struct WebSearchDomain: Sendable {
        public let providers: @Sendable () async throws -> PluginSDK.LocatedResult<[WebSearchSchema.Provider]>
        public let query: @Sendable (WebSearchSchema.Input) async throws -> PluginSDK.LocatedResult<WebSearchSchema.Response>
        public let transform: Transform<WebSearchEditor>
        public let reload: @Sendable () async -> Void

        public init(
            providers: @escaping @Sendable () async throws -> PluginSDK.LocatedResult<[WebSearchSchema.Provider]>,
            query: @escaping @Sendable (WebSearchSchema.Input) async throws -> PluginSDK.LocatedResult<WebSearchSchema.Response>,
            transform: @escaping Transform<WebSearchEditor>,
            reload: @escaping @Sendable () async -> Void
        ) {
            self.providers = providers
            self.query = query
            self.transform = transform
            self.reload = reload
        }
    }

    // MARK: - promise/worktree.ts

    // parity: plugin/src/promise/worktree.ts#WorktreeDefinition [status=implemented hash=11f98274052b]
    public struct WorktreeDefinition: Sendable {
        public let id: String
        public let create: @Sendable (PluginContract.WorktreeCreateInput, SignalContext) async throws -> PluginContract.WorktreeResult
        public let remove: @Sendable (PluginContract.WorktreeRemoveInput, SignalContext) async throws -> Void
        public let list: @Sendable (String, SignalContext) async throws -> [PluginContract.WorktreeEntry]

        public init(
            id: String,
            create: @escaping @Sendable (PluginContract.WorktreeCreateInput, SignalContext) async throws -> PluginContract.WorktreeResult,
            remove: @escaping @Sendable (PluginContract.WorktreeRemoveInput, SignalContext) async throws -> Void,
            list: @escaping @Sendable (String, SignalContext) async throws -> [PluginContract.WorktreeEntry]
        ) {
            self.id = id
            self.create = create
            self.remove = remove
            self.list = list
        }
    }

    // parity: plugin/src/promise/worktree.ts#WorktreeEditor [status=implemented hash=670a2d65e661]
    public struct WorktreeEditor: Sendable {
        public let add: @Sendable (WorktreeDefinition) -> Void

        public init(add: @escaping @Sendable (WorktreeDefinition) -> Void) {
            self.add = add
        }
    }

    // parity: plugin/src/promise/worktree.ts#WorktreeDomain [status=implemented hash=d792f272169e]
    public struct WorktreeDomain: Sendable {
        public let list: @Sendable () async throws -> [WorktreeSchema.ListEntry]
        public let create: @Sendable (WorktreeSchema.CreateInput) async throws -> WorktreeSchema.Info
        public let remove: @Sendable (WorktreeSchema.RemoveInput) async throws -> Void
        public let refresh: @Sendable () async throws -> Void
        public let transform: Transform<WorktreeEditor>
        public let reload: @Sendable () async -> Void

        public init(
            list: @escaping @Sendable () async throws -> [WorktreeSchema.ListEntry],
            create: @escaping @Sendable (WorktreeSchema.CreateInput) async throws -> WorktreeSchema.Info,
            remove: @escaping @Sendable (WorktreeSchema.RemoveInput) async throws -> Void,
            refresh: @escaping @Sendable () async throws -> Void,
            transform: @escaping Transform<WorktreeEditor>,
            reload: @escaping @Sendable () async -> Void
        ) {
            self.list = list
            self.create = create
            self.remove = remove
            self.refresh = refresh
            self.transform = transform
            self.reload = reload
        }
    }

    // MARK: - promise/plugin.ts

    /// Complete host context provided to a Promise-style server plugin during `setup`.
    // parity: plugin/src/promise/plugin.ts#Context [status=implemented hash=abc74478a7b3]
    public struct Context: Sendable {
        public struct Experimental: Sendable {
            public let artifact: ExperimentalArtifactDomain

            public init(artifact: ExperimentalArtifactDomain) {
                self.artifact = artifact
            }
        }

        public let app: PluginContract.App
        public let location: LocationSchema.Info
        public let options: PluginContract.PluginOptions
        public let agent: AgentDomain
        public let aisdk: AISDKDomain
        public let command: CommandDomain
        public let credential: PluginEffect.Context.CredentialAPI
        public let event: EventDomain
        public let experimental: Experimental
        public let integration: IntegrationDomain
        public let mcp: MCPDomain
        public let model: ModelDomain
        public let permission: PermissionDomain
        public let plugin: PluginEffect.Context.PluginInventoryAPI
        public let provider: ProviderDomain
        public let reference: ReferenceDomain
        public let rpc: RpcDomain
        public let session: SessionDomain
        public let shell: ShellDomain
        public let skill: SkillDomain
        public let storage: StorageDomain
        public let tool: ToolDomain
        public let vcs: VcsDomain
        public let websearch: WebSearchDomain
        public let worktree: WorktreeDomain

        public init(
            app: PluginContract.App,
            location: LocationSchema.Info,
            options: PluginContract.PluginOptions = [:],
            agent: AgentDomain,
            aisdk: AISDKDomain,
            command: CommandDomain,
            credential: PluginEffect.Context.CredentialAPI,
            event: EventDomain,
            experimental: Experimental,
            integration: IntegrationDomain,
            mcp: MCPDomain,
            model: ModelDomain,
            permission: PermissionDomain,
            plugin: PluginEffect.Context.PluginInventoryAPI,
            provider: ProviderDomain,
            reference: ReferenceDomain,
            rpc: RpcDomain,
            session: SessionDomain,
            shell: ShellDomain,
            skill: SkillDomain,
            storage: StorageDomain,
            tool: ToolDomain,
            vcs: VcsDomain,
            websearch: WebSearchDomain,
            worktree: WorktreeDomain
        ) {
            self.app = app
            self.location = location
            self.options = options
            self.agent = agent
            self.aisdk = aisdk
            self.command = command
            self.credential = credential
            self.event = event
            self.experimental = experimental
            self.integration = integration
            self.mcp = mcp
            self.model = model
            self.permission = permission
            self.plugin = plugin
            self.provider = provider
            self.reference = reference
            self.rpc = rpc
            self.session = session
            self.shell = shell
            self.skill = skill
            self.storage = storage
            self.tool = tool
            self.vcs = vcs
            self.websearch = websearch
            self.worktree = worktree
        }
    }

    /// Optional async cleanup closure returned by a Promise plugin's `setup`.
    // parity: plugin/src/promise/plugin.ts#Cleanup [status=implemented hash=ebf6dc2dbce3]
    public typealias Cleanup = @Sendable () async -> Void

    /// Promise-style server plugin definition.
    // parity: plugin/src/promise/plugin.ts#Plugin [status=implemented hash=e20bacd8e15f]
    public struct Plugin: Sendable {
        public let id: String
        public let setup: @Sendable (Context) async throws -> Cleanup?

        public init(id: String, setup: @escaping @Sendable (Context) async throws -> Cleanup?) {
            self.id = id
            self.setup = setup
        }
    }

    /// Identity helper defining a Promise-style server plugin.
    // parity: plugin/src/promise/plugin.ts#define [status=implemented hash=9e2184add220]
    public static func define(_ plugin: Plugin) -> Plugin {
        plugin
    }

    // MARK: - promise/adapter.ts

    /// Adapts a Promise-style plugin into an Effect-style plugin so the core plugin host runs both uniformly.
    /// Every hook/transform registration attaches to the plugin scope, and returned `Cleanup` runs on scope disposal.
    /// Tool hooks see the resolved tool as a Promise-style `Info`; only `execute.before` may reject a call (a
    /// rejection fails that call alone) and only its `tool` and `input` write back, while `execute.after` writes back
    /// a result or error only when the callback keeps the outcome's kind.
    // parity: plugin/src/promise/adapter.ts#fromPromise [status=adapted hash=fa0fc8232d31]
    public static func fromPromise(_ plugin: Plugin) -> PluginEffect.Plugin {
        let effectBody: @Sendable (PluginEffect.Context) async throws -> Void = { host in
            let promiseContext = makePromiseContext(from: host)
            if let cleanup = try await plugin.setup(promiseContext) {
                host.addFinalizer(cleanup)
            }
        }
        return PluginEffect.define(PluginEffect.Plugin(id: plugin.id, effect: effectBody))
    }

    private static func makePromiseContext(from host: PluginEffect.Context) -> Context {
        let eventDomain = EventDomain(subscribe: { types, signal in
            let upstream = host.event.subscribe(types)
            guard let signal else { return upstream }
            return AsyncStream<PluginSDK.EventPayload> { continuation in
                let task = Task {
                    for await item in upstream {
                        if signal.isAborted { break }
                        continuation.yield(item)
                    }
                    continuation.finish()
                }
                _ = signal.onAbort {
                    task.cancel()
                    continuation.finish()
                }
                continuation.onTermination = { _ in
                    task.cancel()
                }
            }
        })

        let artifactDomain = ExperimentalArtifactDomain(
            transform: { callback in
                await host.experimental.artifact.transform { editor in
                    callback(
                        ArtifactEditor(
                            add: { definition in
                                editor.add(
                                    PluginEffect.ArtifactProviderDefinition(
                                        id: definition.id,
                                        name: definition.name,
                                        capabilities: definition.capabilities,
                                        prompt: definition.prompt,
                                        create: { input in try await definition.create(input, SignalContext()) },
                                        read: { id in try await definition.read(id, SignalContext()) },
                                        update: { id, input in try await definition.update(id, input, SignalContext()) },
                                        delete: { id in try await definition.delete(id, SignalContext()) }
                                    )
                                )
                            },
                            remove: editor.remove,
                            getDefault: editor.getDefault,
                            setDefault: editor.setDefault
                        )
                    )
                }
            },
            reload: host.experimental.artifact.reload
        )

        let rpcDomain = RpcDomain(
            call: { namespace, method, input, _ in
                try await host.rpc.call(namespace, method, input)
            },
            subscribe: { namespace, event, signal in
                let upstream = host.rpc.subscribe(namespace, event)
                guard let signal else { return upstream }
                return AsyncStream<RpcSchema.EventPayload> { continuation in
                    let task = Task {
                        for await item in upstream {
                            if signal.isAborted { break }
                            continuation.yield(item)
                        }
                        continuation.finish()
                    }
                    _ = signal.onAbort {
                        task.cancel()
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in
                        task.cancel()
                    }
                }
            },
            register: { definition, handlers in
                var adaptedHandlers: PluginEffect.RpcHandlers = [:]
                for (name, handler) in handlers {
                    adaptedHandlers[name] = { input, hostContext in
                        let promiseCtx = RpcCallContext(
                            signal: AbortController().signal,
                            error: hostContext.error
                        )
                        return try await handler(input, promiseCtx)
                    }
                }
                let effectDef = RpcSchema.Definition(
                    id: definition.id,
                    methods: definition.methods.mapValues { portable in
                        RpcSchema.Method(
                            input: portable.input,
                            output: portable.output,
                            errors: portable.errors
                        )
                    },
                    events: definition.events
                )
                return try await host.rpc.register(effectDef, adaptedHandlers)
            }
        )

        @Sendable
        func toPromiseTool(_ tool: PluginEffect.DynamicToolInfo) -> Info {
            Info(
                id: tool.id,
                name: tool.name,
                input: tool.input,
                freeform: tool.freeform,
                description: tool.description,
                execute: { input, ctx in
                    let effectCtx = ToolSchema.Context(
                        sessionID: ctx.sessionID,
                        agent: ctx.agent,
                        messageID: ctx.messageID,
                        id: ctx.id,
                        progress: ctx.progress,
                        cancel: nil
                    )
                    return try await tool.execute(input, effectCtx)
                },
                output: tool.output,
                options: tool.options
            )
        }

        @Sendable
        func toEffectTool(_ tool: Info) -> PluginEffect.DynamicToolInfo {
            PluginEffect.DynamicToolInfo(
                id: tool.id,
                name: tool.name,
                input: tool.input,
                freeform: tool.freeform,
                description: tool.description,
                execute: { input, effectCtx throws(ToolSchema.ToolError) in
                    let controller = AbortController()
                    let promiseCtx = ToolContext(
                        sessionID: effectCtx.sessionID,
                        agent: effectCtx.agent,
                        messageID: effectCtx.messageID,
                        id: effectCtx.id,
                        signal: controller.signal,
                        progress: effectCtx.progress
                    )
                    do {
                        return try await tool.execute(input, promiseCtx)
                    } catch let toolErr as ToolSchema.ToolError {
                        throw toolErr
                    } catch {
                        throw ToolSchema.ToolError(message: String(describing: error))
                    }
                },
                output: tool.output,
                options: tool.options
            )
        }

        let toolDomain = ToolDomain(
            transform: { callback in
                await host.tool.transform { editor in
                    callback(
                        ToolEditor(
                            list: { editor.list().map(toPromiseTool) },
                            get: { id in editor.get(id).map(toPromiseTool) },
                            namespace: editor.namespace,
                            add: { tool in editor.add(toEffectTool(tool)) },
                            update: { id, mutate in
                                editor.update(id) { effectTool in
                                    var copy = toPromiseTool(effectTool)
                                    mutate(&copy)
                                    effectTool = toEffectTool(copy)
                                }
                            },
                            remove: editor.remove
                        )
                    )
                }
            },
            reload: host.tool.reload,
            list: { await host.tool.list().map(toPromiseTool) },
            hook: { name, callback in
                await host.tool.hook(name) { event in
                    switch event {
                    case .executeBefore(var before):
                        let adapted = ToolHooks.ExecuteBefore(
                            tool: before.tool,
                            info: before.info.map(toPromiseTool),
                            codemode: before.codemode,
                            sessionID: before.sessionID,
                            agent: before.agent,
                            messageID: before.messageID,
                            id: before.id,
                            input: before.input
                        )
                        let result: ToolHooks
                        do {
                            result = try await callback(.executeBefore(adapted))
                        } catch let toolError as ToolSchema.ToolError {
                            throw toolError
                        } catch {
                            throw ToolSchema.ToolError(message: String(describing: error))
                        }
                        if case .executeBefore(let updated) = result {
                            before.tool = updated.tool
                            before.input = updated.input
                        }
                        return .executeBefore(before)
                    case .executeAfter(var after):
                        let adapted = ToolHooks.ExecuteAfter(
                            tool: after.tool,
                            info: after.info.map(toPromiseTool),
                            codemode: after.codemode,
                            sessionID: after.sessionID,
                            agent: after.agent,
                            messageID: after.messageID,
                            id: after.id,
                            input: after.input,
                            outcome: after.outcome
                        )
                        guard case .executeAfter(let updated)? = try? await callback(.executeAfter(adapted)) else {
                            return event
                        }
                        switch (after.outcome, updated.outcome) {
                        case (.completed, .completed), (.error, .error):
                            after.outcome = updated.outcome
                        default:
                            break
                        }
                        return .executeAfter(after)
                    }
                }
            }
        )

        let vcsDomain = VcsDomain(
            get: host.vcs.get,
            base: host.vcs.base,
            branches: host.vcs.branches,
            status: host.vcs.status,
            diff: host.vcs.diff,
            transform: { callback in
                await host.vcs.transform { editor in
                    callback(
                        VcsEditor(
                            add: { definition in
                                editor.add(adaptVcsDefinition(definition))
                            },
                            getDefault: editor.getDefault,
                            setDefault: editor.setDefault
                        )
                    )
                }
            },
            reload: host.vcs.reload
        )

        let websearchDomain = WebSearchDomain(
            providers: host.websearch.providers,
            query: host.websearch.query,
            transform: { callback in
                await host.websearch.transform { editor in
                    callback(
                        WebSearchEditor(
                            add: { definition in
                                editor.add(
                                    PluginEffect.WebSearchDefinition(
                                        id: definition.id,
                                        name: definition.name,
                                        execute: { input in try await definition.execute(input, SignalContext()) }
                                    )
                                )
                            },
                            getDefault: editor.getDefault,
                            setDefault: editor.setDefault
                        )
                    )
                }
            },
            reload: host.websearch.reload
        )

        let worktreeDomain = WorktreeDomain(
            list: host.worktree.list,
            create: host.worktree.create,
            remove: host.worktree.remove,
            refresh: host.worktree.refresh,
            transform: { callback in
                await host.worktree.transform { editor in
                    callback(
                        WorktreeEditor(
                            add: { definition in
                                editor.add(
                                    PluginEffect.WorktreeDefinition(
                                        id: definition.id,
                                        create: { input in try await definition.create(input, SignalContext()) },
                                        remove: { input in try await definition.remove(input, SignalContext()) },
                                        list: { dir in try await definition.list(dir, SignalContext()) }
                                    )
                                )
                            }
                        )
                    )
                }
            },
            reload: host.worktree.reload
        )

        return Context(
            app: host.app,
            location: host.location,
            options: host.options,
            agent: host.agent,
            aisdk: host.aisdk,
            command: host.command,
            credential: host.credential,
            event: eventDomain,
            experimental: Context.Experimental(artifact: artifactDomain),
            integration: host.integration,
            mcp: host.mcp,
            model: host.model,
            permission: host.permission,
            plugin: host.plugin,
            provider: host.provider,
            reference: host.reference,
            rpc: rpcDomain,
            session: host.session,
            shell: host.shell,
            skill: host.skill,
            storage: host.storage,
            tool: toolDomain,
            vcs: vcsDomain,
            websearch: websearchDomain,
            worktree: worktreeDomain
        )
    }

    private static func adaptVcsDefinition(_ definition: VcsDefinition) -> PluginEffect.VcsDefinition {
        let initClosure: (@Sendable (PluginEffect.VcsScope) async throws -> Void)?
        if let initFn = definition.initRepo {
            initClosure = { scope in try await initFn(scope, SignalContext()) }
        } else {
            initClosure = nil
        }
        let baseClosure: (@Sendable (PluginEffect.VcsScope) async throws -> VcsSchema.Base?)?
        if let baseFn = definition.base {
            baseClosure = { scope in try await baseFn(scope, SignalContext()) }
        } else {
            baseClosure = nil
        }
        return PluginEffect.VcsDefinition(
            id: definition.id,
            name: definition.name,
            initRepo: initClosure,
            info: { scope in try await definition.info(scope, SignalContext()) },
            base: baseClosure,
            branches: { input in try await definition.branches(input, SignalContext()) },
            status: { scope in try await definition.status(scope, SignalContext()) },
            diff: { input in
                try await definition.diff(
                    VcsDiffInput(
                        scope: input.scope,
                        mode: input.mode,
                        base: input.base,
                        context: input.context,
                        maxOutputBytes: input.maxOutputBytes
                    ),
                    SignalContext()
                )
            }
        )
    }
}
