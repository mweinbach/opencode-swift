/// Portable AI provider definitions, endpoint/auth/header builders, and typed model factories
/// (Part A: `alibaba` through `google-vertex*` — 32 upstream provider modules, 266 symbols).
///
/// Strictly PORTABLE tier: zero OS imports, all HTTP via `OpenCodePlatform.HTTPTransport`
/// and environment lookups via `OpenCodePlatform.EnvironmentProviding`.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

public enum AIProviders {

    // MARK: Shared Provider Runtime Foundation

    public struct ProviderConfigurationError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public let provider: String
        public let message: String

        public init(provider: String, message: String) {
            self.provider = provider
            self.message = message
        }

        public var description: String {
            "[\(provider)] \(message)"
        }
    }

    public enum APIKeyOption: Equatable, Hashable, Sendable {
        case inherited
        case disabled
        case explicit(String)
    }

    public struct ProviderConfig: Sendable {
        public var apiKey: APIKeyOption
        public var authToken: String?
        public var auth: AIProtocolUtils.AuthStrategy?
        public var baseURL: String?
        public var headers: [String: String]?
        public var queryParams: [String: String]?
        public var body: [String: JSONValue]?
        public var providerOptions: [String: JSONValue]?
        public var region: String?
        public var workspaceID: String?
        public var resourceName: String?
        public var apiVersion: String?
        public var useDeploymentBasedUrls: Bool?
        public var accountId: String?
        public var gatewayId: String?
        public var gatewayApiKey: String?
        public var project: String?
        public var location: String?
        public var accessToken: String?
        public var organization: String?
        public var credentials: AIProtocolUtils.BedrockAuth.Credentials?
        public var profile: String?
        public var bedrockAuthMode: AIProtocolUtils.BedrockAuth.ResolveAuthOptions.Mode?
        public var providerOverride: String?

        public init(
            apiKey: APIKeyOption = .inherited,
            authToken: String? = nil,
            auth: AIProtocolUtils.AuthStrategy? = nil,
            baseURL: String? = nil,
            headers: [String: String]? = nil,
            queryParams: [String: String]? = nil,
            body: [String: JSONValue]? = nil,
            providerOptions: [String: JSONValue]? = nil,
            region: String? = nil,
            workspaceID: String? = nil,
            resourceName: String? = nil,
            apiVersion: String? = nil,
            useDeploymentBasedUrls: Bool? = nil,
            accountId: String? = nil,
            gatewayId: String? = nil,
            gatewayApiKey: String? = nil,
            project: String? = nil,
            location: String? = nil,
            accessToken: String? = nil,
            organization: String? = nil,
            credentials: AIProtocolUtils.BedrockAuth.Credentials? = nil,
            profile: String? = nil,
            bedrockAuthMode: AIProtocolUtils.BedrockAuth.ResolveAuthOptions.Mode? = nil,
            providerOverride: String? = nil
        ) {
            self.apiKey = apiKey; self.authToken = authToken; self.auth = auth
            self.baseURL = baseURL; self.headers = headers; self.queryParams = queryParams
            self.body = body; self.providerOptions = providerOptions
            self.region = region; self.workspaceID = workspaceID
            self.resourceName = resourceName; self.apiVersion = apiVersion
            self.useDeploymentBasedUrls = useDeploymentBasedUrls
            self.accountId = accountId; self.gatewayId = gatewayId; self.gatewayApiKey = gatewayApiKey
            self.project = project; self.location = location; self.accessToken = accessToken
            self.organization = organization; self.credentials = credentials
            self.profile = profile; self.bedrockAuthMode = bedrockAuthMode
            self.providerOverride = providerOverride
        }

        /// Builds a `ProviderConfig` from untyped catalog/user settings dictionaries.
        public static func from(
            settings: [String: JSONValue],
            headers: [String: String]? = nil,
            body: [String: JSONValue]? = nil
        ) -> ProviderConfig {
            let knownKeys: Set<String> = [
                "apiKey", "authToken", "auth", "baseURL", "headers", "queryParams", "body",
                "providerOptions", "region", "workspaceID", "resourceName", "apiVersion",
                "useDeploymentBasedUrls", "accountId", "gatewayId", "gatewayApiKey",
                "project", "location", "accessToken", "organization", "credentials",
                "profile", "bedrockAuthMode", "provider",
            ]

            let apiKey: APIKeyOption = {
                switch settings["apiKey"] {
                case .string(let k) where !k.isEmpty:
                    return .explicit(k)
                case .bool(false):
                    return .disabled
                default:
                    return .inherited
                }
            }()
            let authToken = AIProtocolUtils.JSONCodec.stringValue(settings["authToken"])
            let baseURL = AIProtocolUtils.JSONCodec.stringValue(settings["baseURL"])
            var mergedHeaders: [String: String] = [:]
            if let rawHeaders = AIProtocolUtils.JSONCodec.objectValue(settings["headers"]) {
                for (k, v) in rawHeaders {
                    if case .string(let s) = v { mergedHeaders[k] = s }
                }
            }
            if let headers {
                for (k, v) in headers { mergedHeaders[k] = v }
            }
            var queryParams: [String: String]? = nil
            if let rawQuery = AIProtocolUtils.JSONCodec.objectValue(settings["queryParams"]) {
                var parsed: [String: String] = [:]
                for (k, v) in rawQuery {
                    if case .string(let s) = v { parsed[k] = s }
                }
                if !parsed.isEmpty { queryParams = parsed }
            }
            let mergedBody = AIProtocolUtils.JSONCodec.mergeObjects(
                AIProtocolUtils.JSONCodec.objectValue(settings["body"]),
                body
            )
            var providerOptions = AIProtocolUtils.JSONCodec.objectValue(settings["providerOptions"]) ?? [:]
            for (k, v) in settings where !knownKeys.contains(k) {
                providerOptions[k] = v
            }
            let region = AIProtocolUtils.JSONCodec.stringValue(settings["region"])
            let credentials: AIProtocolUtils.BedrockAuth.Credentials? = {
                guard let obj = AIProtocolUtils.JSONCodec.objectValue(settings["credentials"]),
                      let ak = AIProtocolUtils.JSONCodec.stringValue(obj["accessKeyId"]),
                      let sk = AIProtocolUtils.JSONCodec.stringValue(obj["secretAccessKey"])
                else { return nil }
                return AIProtocolUtils.BedrockAuth.Credentials(
                    region: AIProtocolUtils.JSONCodec.stringValue(obj["region"]) ?? region ?? "us-east-1",
                    accessKeyId: ak,
                    secretAccessKey: sk,
                    sessionToken: AIProtocolUtils.JSONCodec.stringValue(obj["sessionToken"])
                )
            }()
            let bedrockAuthMode: AIProtocolUtils.BedrockAuth.ResolveAuthOptions.Mode? = {
                if let explicit = AIProtocolUtils.JSONCodec.stringValue(settings["bedrockAuthMode"]),
                   let mode = AIProtocolUtils.BedrockAuth.ResolveAuthOptions.Mode(rawValue: explicit) {
                    return mode
                }
                if AIProtocolUtils.JSONCodec.stringValue(settings["auth"]) == "sigv4" {
                    return .sigv4
                }
                return nil
            }()

            return ProviderConfig(
                apiKey: apiKey,
                authToken: authToken,
                auth: nil,
                baseURL: baseURL,
                headers: mergedHeaders.isEmpty ? nil : mergedHeaders,
                queryParams: queryParams,
                body: mergedBody.isEmpty ? nil : mergedBody,
                providerOptions: providerOptions.isEmpty ? nil : providerOptions,
                region: region,
                workspaceID: AIProtocolUtils.JSONCodec.stringValue(settings["workspaceID"]),
                resourceName: AIProtocolUtils.JSONCodec.stringValue(settings["resourceName"]),
                apiVersion: AIProtocolUtils.JSONCodec.stringValue(settings["apiVersion"]),
                useDeploymentBasedUrls: AIProtocolUtils.JSONCodec.boolValue(settings["useDeploymentBasedUrls"]),
                accountId: AIProtocolUtils.JSONCodec.stringValue(settings["accountId"]),
                gatewayId: AIProtocolUtils.JSONCodec.stringValue(settings["gatewayId"]),
                gatewayApiKey: AIProtocolUtils.JSONCodec.stringValue(settings["gatewayApiKey"]),
                project: AIProtocolUtils.JSONCodec.stringValue(settings["project"]),
                location: AIProtocolUtils.JSONCodec.stringValue(settings["location"]),
                accessToken: AIProtocolUtils.JSONCodec.stringValue(settings["accessToken"]),
                organization: AIProtocolUtils.JSONCodec.stringValue(settings["organization"]),
                credentials: credentials,
                profile: AIProtocolUtils.JSONCodec.stringValue(settings["profile"]),
                bedrockAuthMode: bedrockAuthMode,
                providerOverride: AIProtocolUtils.JSONCodec.stringValue(settings["provider"])
            )
        }
    }

    public struct ConfiguredModel: Sendable {
        public let descriptor: AIProtocolUtils.ModelDescriptor
        public let route: AIProtocols.ChatRouteSpec

        public init(descriptor: AIProtocolUtils.ModelDescriptor, route: AIProtocols.ChatRouteSpec) {
            self.descriptor = descriptor
            self.route = route
        }

        public func prepareRequest(
            messages: [AIProtocolUtils.Message],
            system: [AIProtocolUtils.TextPart] = [],
            tools: [AIProtocolUtils.ToolEntry] = [],
            maxTokens: Int? = nil,
            temperature: Double? = nil,
            providerOptions: [String: JSONValue]? = nil,
            timestampEpochSeconds: Int64? = nil,
            clock: @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
        ) throws -> HTTPRequest {
            let req = AIProtocolUtils.LLMRequest(
                model: descriptor,
                system: system,
                messages: messages,
                tools: tools,
                maxTokens: maxTokens,
                temperature: temperature,
                providerOptions: providerOptions
            )
            return try route.prepareHTTPRequest(
                for: req,
                timestampEpochSeconds: timestampEpochSeconds,
                clock: clock
            )
        }

        /// Executes a live streaming request for this configured model, yielding incremental `LLMEvent`s as chunks arrive.
        public func streamEvents(
            messages: [AIProtocolUtils.Message],
            system: [AIProtocolUtils.TextPart] = [],
            tools: [AIProtocolUtils.ToolEntry] = [],
            maxTokens: Int? = nil,
            temperature: Double? = nil,
            providerOptions: [String: JSONValue]? = nil,
            transport: any HTTPTransport,
            timestampEpochSeconds: Int64? = nil,
            clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
        ) -> AsyncThrowingStream<AIProtocolUtils.LLMEvent, Error> {
            let req = AIProtocolUtils.LLMRequest(
                model: descriptor,
                system: system,
                messages: messages,
                tools: tools,
                maxTokens: maxTokens,
                temperature: temperature,
                providerOptions: providerOptions
            )
            return route.streamEvents(
                req,
                transport: transport,
                timestampEpochSeconds: timestampEpochSeconds,
                clock: clock
            )
        }

        /// Bridges this configured provider model directly into a runnable `AISchema.LanguageModel`.
        public func asLanguageModel(
            transport: (any HTTPTransport)? = nil,
            options: AISchema.RequestOptions? = nil,
            capabilities: AISchema.Capabilities? = nil,
            compatibility: AISchema.LanguageModelCompatibility? = nil,
            clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
        ) -> AISchema.LanguageModel {
            let anyRoute = route.asAnyRoute(
                defaultCompatibility: descriptor.compatibility,
                defaultCapabilities: descriptor.capabilities,
                options: options,
                transport: transport,
                clock: clock
            )
            return AISchema.LanguageModel.make(AISchema.LanguageModel.Input(
                id: descriptor.id,
                provider: descriptor.provider,
                route: anyRoute,
                options: options,
                capabilities: capabilities,
                compatibility: compatibility
            ))
        }
    }

    public struct ConfiguredMediaModel: Equatable, Hashable, Sendable {
        public let handle: AIProtocols.MediaModelHandle
        public let headers: [String: String]

        public init(handle: AIProtocols.MediaModelHandle, headers: [String: String] = [:]) {
            self.handle = handle
            self.headers = headers
        }
    }

    public struct ConfiguredProvider: Sendable {
        public let id: String
        public let baseURL: String?
        public let auth: AIProtocolUtils.AuthStrategy
        public let headers: [String: String]
        public let routes: [AIProtocols.ChatRouteSpec]
        public let defaultRoute: AIProtocols.ChatRouteSpec?
        public let defaultProviderOptions: [String: JSONValue]
        public let defaultCompatibility: AIProtocolUtils.ModelCompatibility?
        public let defaultCapabilities: AIProtocolUtils.ModelCapabilities?

        public init(
            id: String,
            baseURL: String?,
            auth: AIProtocolUtils.AuthStrategy,
            headers: [String: String] = [:],
            routes: [AIProtocols.ChatRouteSpec] = [],
            defaultRoute: AIProtocols.ChatRouteSpec? = nil,
            defaultProviderOptions: [String: JSONValue] = [:],
            defaultCompatibility: AIProtocolUtils.ModelCompatibility? = nil,
            defaultCapabilities: AIProtocolUtils.ModelCapabilities? = nil
        ) {
            self.id = id
            self.baseURL = baseURL
            self.auth = auth
            self.headers = headers
            self.routes = routes
            self.defaultRoute = defaultRoute ?? routes.first
            self.defaultProviderOptions = defaultProviderOptions
            self.defaultCompatibility = defaultCompatibility
            self.defaultCapabilities = defaultCapabilities
        }

        public func model(
            _ modelID: String,
            route overrideRoute: AIProtocols.ChatRouteSpec? = nil,
            compatibility: AIProtocolUtils.ModelCompatibility? = nil,
            capabilities: AIProtocolUtils.ModelCapabilities? = nil,
            providerOptions: [String: JSONValue]? = nil
        ) -> ConfiguredModel {
            let baseRoute = overrideRoute ?? defaultRoute ?? AIProtocols.OpenAIChat.route
            let mergedOptions = AIProtocolUtils.JSONCodec.mergeObjects(defaultProviderOptions, providerOptions)
            let configured = baseRoute.with(
                provider: id,
                baseURL: baseURL,
                headers: headers,
                providerOptions: mergedOptions,
                auth: auth
            )
            let desc = AIProtocolUtils.ModelDescriptor(
                id: modelID,
                provider: id,
                routeID: configured.id,
                providerMetadataKey: configured.providerMetadataKey,
                baseURL: configured.defaultBaseURL,
                sanitizer: configured.`protocol`.sanitizer,
                compatibility: compatibility ?? defaultCompatibility,
                capabilities: capabilities ?? defaultCapabilities
            )
            return ConfiguredModel(descriptor: desc, route: configured)
        }
    }

    public static func resolveBearerAuth(
        config: ProviderConfig,
        envVars: [String],
        environment: any EnvironmentProviding = SystemEnvironment.shared
    ) -> AIProtocolUtils.AuthStrategy {
        if let explicit = config.auth { return explicit }
        switch config.apiKey {
        case .disabled:
            return .none
        case .explicit(let key):
            return .bearer(key)
        case .inherited:
            for env in envVars {
                if let value = environment.variable(env), !value.isEmpty {
                    return .bearer(value)
                }
            }
            return .none
        }
    }

    public static func resolveHeaderAuth(
        config: ProviderConfig,
        envVars: [String],
        headerName: String,
        environment: any EnvironmentProviding = SystemEnvironment.shared
    ) -> AIProtocolUtils.AuthStrategy {
        if let explicit = config.auth { return explicit }
        if let token = config.authToken { return .bearer(token) }
        switch config.apiKey {
        case .disabled:
            return .none
        case .explicit(let key):
            return .header(name: headerName, value: key)
        case .inherited:
            for env in envVars {
                if let value = environment.variable(env), !value.isEmpty {
                    return .header(name: headerName, value: value)
                }
            }
            return .none
        }
    }

    static func trimBaseURL(_ url: String) -> String {
        var s = url.trimmingASCIIWhitespace()
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Resolves AWS Bedrock authentication (bearer token or SigV4) using `.sigV4` when credentials
    /// are available so request signing honors the real wall-clock timestamp (or explicit test override).
    public static func resolveBedrockAuth(
        config: ProviderConfig,
        region: String,
        service: String = "bedrock",
        name: String = "Bedrock Converse",
        environment: any EnvironmentProviding = SystemEnvironment.shared
    ) -> AIProtocolUtils.AuthStrategy {
        if let explicit = config.auth { return explicit }
        let explicitKey: String? = {
            if case .explicit(let k) = config.apiKey { return k }
            return nil
        }()
        let apiKey = config.bedrockAuthMode == .sigv4
            ? nil
            : (explicitKey ?? environment.variable("AWS_BEARER_TOKEN_BEDROCK"))
        if let apiKey, !apiKey.isEmpty {
            return .bearer(apiKey)
        }
        if let creds = config.credentials {
            let scoped = AIProtocolUtils.BedrockAuth.Credentials(
                region: region,
                accessKeyId: creds.accessKeyId,
                secretAccessKey: creds.secretAccessKey,
                sessionToken: creds.sessionToken
            )
            return .sigV4(scoped, service: service, name: name)
        }
        if let accessKey = environment.variable("AWS_ACCESS_KEY_ID"), !accessKey.isEmpty,
           let secretKey = environment.variable("AWS_SECRET_ACCESS_KEY"), !secretKey.isEmpty {
            let envCreds = AIProtocolUtils.BedrockAuth.Credentials(
                region: region,
                accessKeyId: accessKey,
                secretAccessKey: secretKey,
                sessionToken: environment.variable("AWS_SESSION_TOKEN")
            )
            return .sigV4(envCreds, service: service, name: name)
        }
        let chain = AIProtocolUtils.BedrockAuth.defaultChain(
            .init(region: region, profile: config.profile),
            environment: environment
        )
        return .custom { request in
            let creds: AIProtocolUtils.BedrockAuth.Credentials
            switch chain {
            case .staticCredentials(let c): creds = c
            case .resolver(let fn): creds = try fn()
            }
            var headers = request.headers
            headers["content-type"] = "application/json"
            let signed = try AIProtocolUtils.BedrockAuth.signRequest(
                method: request.method,
                url: request.url,
                body: request.body ?? [],
                headers: headers,
                credentials: creds,
                service: service,
                name: name,
                timestampEpochSeconds: Int64(Date().timeIntervalSince1970)
            )
            return HTTPRequest(method: request.method, url: request.url, headers: signed, body: request.body)
        }
    }

    // MARK: - 1. Alibaba (alibaba.ts, alibaba/messages.ts, alibaba/responses.ts — 11 symbols)

    public enum Alibaba {
        // parity: ai/src/providers/alibaba.ts#id [status=implemented hash=509ef6f188cf]
        public static let id = "alibaba"

        // parity: ai/src/providers/alibaba.ts#Region [status=implemented hash=beeeb7237ad9]
        public typealias Region = String

        // parity: ai/src/providers/alibaba.ts#ChatOptionsInput [status=implemented hash=def16f0184a6]
        public typealias ChatOptionsInput = AIProtocols.AlibabaChat.OptionsInput

        // parity: ai/src/providers/alibaba.ts#MessagesOptionsInput [status=implemented hash=daff0d5eca04]
        public typealias MessagesOptionsInput = AIProtocols.AlibabaMessages.OptionsInput

        // parity: ai/src/providers/alibaba.ts#ResponsesOptionsInput [status=implemented hash=0d0819611bdf]
        public typealias ResponsesOptionsInput = AIProtocols.AlibabaResponses.OptionsInput

        // parity: ai/src/providers/alibaba.ts#Config [status=implemented hash=3c44b0cb5c7a]
        public typealias Config = ProviderConfig

        // parity: ai/src/providers/alibaba.ts#Settings [status=implemented hash=6ed7cb0120bf]
        public typealias Settings = ProviderConfig

        public static let regionHosts: [String: String] = [
            "ap-southeast-1": "dashscope-intl.aliyuncs.com",
            "cn-beijing": "dashscope.aliyuncs.com",
            "cn-hongkong": "cn-hongkong.dashscope.aliyuncs.com",
            "us-east-1": "dashscope-us.aliyuncs.com",
        ]

        public static let chatRoute = AIProtocols.ChatRouteSpec(
            id: "alibaba-chat", provider: id, providerMetadataKey: "alibaba",
            protocol: AIProtocols.AlibabaChat.`protocol`, path: "/chat/completions"
        )
        public static let messagesRoute = AIProtocols.ChatRouteSpec(
            id: "alibaba-messages", provider: id, providerMetadataKey: "alibaba",
            protocol: AIProtocols.AlibabaMessages.`protocol`, path: "/messages",
            defaultHeaders: ["anthropic-version": "2023-06-01"]
        )
        public static let responsesRoute = AIProtocols.ChatRouteSpec(
            id: "alibaba-responses", provider: id, providerMetadataKey: "alibaba",
            protocol: AIProtocols.AlibabaResponses.`protocol`, path: "/responses"
        )

        // parity: ai/src/providers/alibaba.ts#routes [status=implemented hash=7ee10d607c52]
        public static let routes: [AIProtocols.ChatRouteSpec] = [chatRoute, messagesRoute, responsesRoute]

        private static func resolveHost(_ input: Config) throws(ProviderConfigurationError) -> String? {
            let host: String?
            if let region = input.region {
                host = input.workspaceID.map { "\($0).\(region).maas.aliyuncs.com" } ?? regionHosts[region]
            } else {
                host = nil
            }
            if input.baseURL == nil {
                guard let region = input.region else {
                    throw ProviderConfigurationError(provider: id, message: "Alibaba requires region or baseURL")
                }
                guard host != nil else {
                    throw ProviderConfigurationError(provider: id, message: "Alibaba region \(region) requires workspaceID or baseURL")
                }
            }
            return host
        }

        // parity: ai/src/providers/alibaba.ts#configure [status=implemented hash=1bd585326b25]
        public static func configure(
            _ input: Config = Config(region: "ap-southeast-1"),
            environment: any EnvironmentProviding = SystemEnvironment.shared
        ) throws(ProviderConfigurationError) -> ConfiguredProvider {
            let host = try resolveHost(input)
            let resolvedBase = input.baseURL ?? "https://\(host!)/compatible-mode/v1"
            let auth = resolveBearerAuth(config: input, envVars: ["DASHSCOPE_API_KEY", "ALIBABA_API_KEY"], environment: environment)
            return ConfiguredProvider(
                id: id,
                baseURL: resolvedBase,
                auth: auth,
                headers: input.headers ?? [:],
                routes: routes,
                defaultRoute: chatRoute,
                defaultProviderOptions: input.providerOptions ?? [:],
                defaultCompatibility: AIProtocols.AlibabaChat.compatibility,
                defaultCapabilities: AIProtocols.AlibabaChat.capabilities
            )
        }

        // parity: ai/src/providers/alibaba.ts#provider [status=implemented hash=2a83695cb527]
        public static let provider = (id: id, routes: routes)

        // parity: ai/src/providers/alibaba.ts#model [status=implemented hash=c50d7a0bdd31]
        public static func model(
            _ modelID: String,
            settings: Settings = Settings(region: "ap-southeast-1"),
            environment: any EnvironmentProviding = SystemEnvironment.shared
        ) throws(ProviderConfigurationError) -> ConfiguredModel {
            try configure(settings, environment: environment).model(
                modelID,
                route: chatRoute,
                compatibility: AIProtocols.AlibabaChat.compatibility,
                capabilities: AIProtocols.AlibabaChat.capabilities
            )
        }

        // parity: ai/src/providers/alibaba.ts#messagesModel [status=implemented hash=114a9e9a9f26]
        public static func messagesModel(
            _ modelID: String,
            settings: Settings = Settings(region: "ap-southeast-1"),
            environment: any EnvironmentProviding = SystemEnvironment.shared
        ) throws(ProviderConfigurationError) -> ConfiguredModel {
            let host = try resolveHost(settings)
            var adjusted = settings
            adjusted.baseURL = settings.baseURL ?? "https://\(host!)/apps/anthropic/v1"
            return try configure(adjusted, environment: environment).model(
                modelID,
                route: messagesRoute,
                compatibility: .init(requireSignature: false)
            )
        }

        // parity: ai/src/providers/alibaba.ts#responsesModel [status=implemented hash=98e6de3d3c0a]
        public static func responsesModel(
            _ modelID: String,
            settings: Settings = Settings(region: "ap-southeast-1"),
            environment: any EnvironmentProviding = SystemEnvironment.shared
        ) throws(ProviderConfigurationError) -> ConfiguredModel {
            try configure(settings, environment: environment).model(modelID, route: responsesRoute)
        }

        // parity: ai/src/providers/alibaba.ts#chat [status=implemented hash=84c2da6223da]
        public static func chat(
            _ modelID: String,
            settings: Settings = Settings(region: "ap-southeast-1"),
            environment: any EnvironmentProviding = SystemEnvironment.shared
        ) throws(ProviderConfigurationError) -> ConfiguredModel {
            try model(modelID, settings: settings, environment: environment)
        }

        // parity: ai/src/providers/alibaba.ts#messages [status=implemented hash=c38213249e6c]
        public static func messages(
            _ modelID: String,
            settings: Settings = Settings(region: "ap-southeast-1"),
            environment: any EnvironmentProviding = SystemEnvironment.shared
        ) throws(ProviderConfigurationError) -> ConfiguredModel {
            try messagesModel(modelID, settings: settings, environment: environment)
        }

        // parity: ai/src/providers/alibaba.ts#responses [status=implemented hash=804ee5dbd404]
        public static func responses(
            _ modelID: String,
            settings: Settings = Settings(region: "ap-southeast-1"),
            environment: any EnvironmentProviding = SystemEnvironment.shared
        ) throws(ProviderConfigurationError) -> ConfiguredModel {
            try responsesModel(modelID, settings: settings, environment: environment)
        }

        // parity: ai/src/providers/alibaba.ts#imageModel [status=implemented hash=fb07b785259e]
        public static func imageModel(
            _ modelID: String,
            settings: Settings = Settings(region: "ap-southeast-1")
        ) throws(ProviderConfigurationError) -> AIProtocols.MediaModelHandle {
            let host = try resolveHost(settings)
            let mediaBase = settings.baseURL ?? "https://\(host!)/api/v1"
            return AIProtocols.AlibabaImages.model(.init(
                id: modelID,
                provider: id,
                baseURL: mediaBase,
                providerOptions: settings.providerOptions
            ))
        }

        // parity: ai/src/providers/alibaba.ts#embeddingModel [status=implemented hash=92058c6a5ffe]
        public static func embeddingModel(
            _ modelID: String,
            settings: Settings = Settings(region: "ap-southeast-1")
        ) throws(ProviderConfigurationError) -> AIProtocols.MediaModelHandle {
            let host = try resolveHost(settings)
            let embeddingBase = settings.baseURL ?? "https://\(host!)/compatible-mode/v1"
            return AIProtocols.MediaModelHandle(
                id: modelID,
                provider: id,
                protocolID: "openai-embeddings",
                baseURL: embeddingBase,
                path: AIProtocols.OpenAIEmbeddings.PATH,
                mode: .inline,
                providerOptions: settings.providerOptions
            )
        }

        private static func hostedTool(_ type: String, description: String) -> AIProtocolUtils.ToolDefinition {
            AIProtocolUtils.ToolDefinition(
                name: type,
                description: description,
                inputSchema: ["type": .string("object"), "properties": .object([:])],
                native: ["alibaba": .object(["type": .string(type)])]
            )
        }

        // parity: ai/src/providers/alibaba.ts#webSearch [status=implemented hash=cbe947429f2a]
        public static func webSearch() -> AIProtocolUtils.ToolDefinition {
            hostedTool("web_search", description: "Search the web with Alibaba's hosted search tool.")
        }

        // parity: ai/src/providers/alibaba.ts#webExtractor [status=implemented hash=fcac96311b71]
        public static func webExtractor() -> AIProtocolUtils.ToolDefinition {
            hostedTool("web_extractor", description: "Extract web page content with Alibaba's hosted tool.")
        }

        // parity: ai/src/providers/alibaba.ts#codeInterpreter [status=implemented hash=a413e284ceba]
        public static func codeInterpreter() -> AIProtocolUtils.ToolDefinition {
            hostedTool("code_interpreter", description: "Execute code with Alibaba's hosted interpreter.")
        }

        public enum Messages {
            // parity: ai/src/providers/alibaba/messages.ts#Settings [status=implemented hash=c3cf287eecae]
            public typealias Settings = ProviderConfig
        }

        public enum Responses {
            // parity: ai/src/providers/alibaba/responses.ts#Settings [status=implemented hash=79507f8c8c19]
            public typealias Settings = ProviderConfig
        }
    }

    // MARK: - 2. AmazonBedrockMantle (amazon-bedrock-mantle.ts — 16 symbols)

    public enum AmazonBedrockMantle {
        // parity: ai/src/providers/amazon-bedrock-mantle.ts#id [status=implemented hash=28dde2eee95a]
        public static let id = "amazon-bedrock"

        // parity: ai/src/providers/amazon-bedrock-mantle.ts#OpenAIOptionsInput [status=implemented hash=4f13a6caa8e4]
        public typealias OpenAIOptionsInput = [String: JSONValue]

        // parity: ai/src/providers/amazon-bedrock-mantle.ts#MessagesOptionsInput [status=implemented hash=4d84496d50a6]
        public typealias MessagesOptionsInput = AIProtocols.AnthropicMessages.ProviderOptionsInput

        // parity: ai/src/providers/amazon-bedrock-mantle.ts#Config [status=implemented hash=37235b1a477c]
        public typealias Config = ProviderConfig

        // parity: ai/src/providers/amazon-bedrock-mantle.ts#Settings [status=implemented hash=3821d15c39aa]
        public typealias Settings = ProviderConfig

        // parity: ai/src/providers/amazon-bedrock-mantle.ts#MessagesSettings [status=implemented hash=06cef1418d17]
        public typealias MessagesSettings = ProviderConfig

        public static let responsesRoute = AIProtocols.ChatRouteSpec(
            id: "bedrock-mantle-responses", provider: id, providerMetadataKey: "mantle",
            protocol: AIProtocols.OpenResponses.`protocol`, path: AIProtocols.OpenResponses.PATH,
            defaultProviderOptions: ["store": .bool(false), "include": .array([.string("reasoning.encrypted_content")])]
        )
        public static let chatRoute = AIProtocols.OpenAIChat.route.with(id: "bedrock-mantle-chat", provider: id, providerMetadataKey: "mantle")
        public static let messagesRoute = AIProtocols.ChatRouteSpec(
            id: "bedrock-mantle-messages", provider: id, providerMetadataKey: "mantle",
            protocol: AIProtocols.AnthropicMessages.`protocol`, path: AIProtocols.AnthropicMessages.PATH,
            defaultHeaders: ["anthropic-version": "2023-06-01"]
        )

        // parity: ai/src/providers/amazon-bedrock-mantle.ts#routes [status=implemented hash=507b1ad0c8b2]
        public static let routes: [AIProtocols.ChatRouteSpec] = [responsesRoute, chatRoute, messagesRoute]

        // parity: ai/src/providers/amazon-bedrock-mantle.ts#configure [status=implemented hash=6ef9eff864c2]
        public static func configure(
            _ input: Config = Config(),
            environment: any EnvironmentProviding = SystemEnvironment.shared
        ) -> ConfiguredProvider {
            let region = AIProtocolUtils.BedrockAuth.resolveRegion(
                region: input.region,
                credentialsRegion: input.credentials?.region,
                environment: environment
            )
            let auth = AIProviders.resolveBedrockAuth(
                config: input,
                region: region,
                service: "bedrock-mantle",
                name: "Bedrock Mantle",
                environment: environment
            )
            return ConfiguredProvider(
                id: id,
                baseURL: input.baseURL ?? "https://bedrock-mantle.\(region).api.aws/v1",
                auth: auth,
                headers: input.headers ?? [:],
                routes: routes,
                defaultRoute: responsesRoute,
                defaultProviderOptions: input.providerOptions ?? [:]
            )
        }

        // parity: ai/src/providers/amazon-bedrock-mantle.ts#provider [status=implemented hash=370740ab87b4]
        public static let provider = configure()

        // parity: ai/src/providers/amazon-bedrock-mantle.ts#chat [status=implemented hash=c527949cbec3]
        public static func chat(_ modelID: String) -> ConfiguredModel { provider.model(modelID, route: chatRoute) }

        // parity: ai/src/providers/amazon-bedrock-mantle.ts#messages [status=implemented hash=bfa381d2428b]
        public static func messages(_ modelID: String) -> ConfiguredModel { provider.model(modelID, route: messagesRoute) }

        // parity: ai/src/providers/amazon-bedrock-mantle.ts#responses [status=implemented hash=8ec09f32a8ac]
        public static func responses(_ modelID: String) -> ConfiguredModel { provider.model(modelID, route: responsesRoute) }

        // parity: ai/src/providers/amazon-bedrock-mantle.ts#chatModel [status=implemented hash=7e1da7b6d302]
        public static func chatModel(_ modelID: String, settings: Settings = Settings()) -> ConfiguredModel {
            configure(settings).model(modelID, route: chatRoute)
        }

        // parity: ai/src/providers/amazon-bedrock-mantle.ts#messagesModel [status=implemented hash=8d6730bfdf2f]
        public static func messagesModel(_ modelID: String, settings: MessagesSettings = MessagesSettings()) -> ConfiguredModel {
            let region = AIProtocolUtils.BedrockAuth.resolveRegion(region: settings.region, credentialsRegion: settings.credentials?.region)
            var adjusted = settings
            if adjusted.baseURL == nil { adjusted.baseURL = "https://bedrock-mantle.\(region).api.aws/anthropic/v1" }
            return configure(adjusted).model(modelID, route: messagesRoute)
        }

        // parity: ai/src/providers/amazon-bedrock-mantle.ts#responsesModel [status=implemented hash=68d3e13b4af5]
        public static func responsesModel(_ modelID: String, settings: Settings = Settings()) -> ConfiguredModel {
            configure(settings).model(modelID, route: responsesRoute)
        }

        // parity: ai/src/providers/amazon-bedrock-mantle.ts#model [status=implemented hash=30e89e3428b9]
        public static func model(_ modelID: String, settings: Settings = Settings()) -> ConfiguredModel {
            responsesModel(modelID, settings: settings)
        }
    }

    // MARK: - 3. AmazonBedrock (amazon-bedrock.ts — 7 symbols)

    public enum AmazonBedrock {
        // parity: ai/src/providers/amazon-bedrock.ts#id [status=implemented hash=28dde2eee95a]
        public static let id = "amazon-bedrock"

        // parity: ai/src/providers/amazon-bedrock.ts#Config [status=implemented hash=35f88ed9c5be]
        public typealias Config = ProviderConfig

        // parity: ai/src/providers/amazon-bedrock.ts#Settings [status=implemented hash=3ff13b8816f3]
        public typealias Settings = ProviderConfig

        // parity: ai/src/providers/amazon-bedrock.ts#routes [status=implemented hash=d27b3f0c8e43]
        public static let routes: [AIProtocols.ChatRouteSpec] = [AIProtocols.BedrockConverse.route]

        // parity: ai/src/providers/amazon-bedrock.ts#configure [status=implemented hash=6ef9eff864c2]
        public static func configure(
            _ input: Config = Config(),
            environment: any EnvironmentProviding = SystemEnvironment.shared
        ) -> ConfiguredProvider {
            let region = AIProtocolUtils.BedrockAuth.resolveRegion(
                region: input.region,
                credentialsRegion: input.credentials?.region,
                environment: environment
            )
            let auth = AIProviders.resolveBedrockAuth(
                config: input,
                region: region,
                service: "bedrock",
                name: "Bedrock Converse",
                environment: environment
            )
            let configured = AIProtocols.BedrockConverse.route.with(
                provider: id,
                providerMetadataKey: "bedrock",
                baseURL: input.baseURL ?? "https://bedrock-runtime.\(region).amazonaws.com",
                headers: input.headers,
                providerOptions: input.providerOptions,
                auth: auth
            )
            return ConfiguredProvider(
                id: id,
                baseURL: configured.defaultBaseURL,
                auth: auth,
                headers: input.headers ?? [:],
                routes: [configured],
                defaultRoute: configured,
                defaultProviderOptions: input.providerOptions ?? [:]
            )
        }

        // parity: ai/src/providers/amazon-bedrock.ts#provider [status=implemented hash=370740ab87b4]
        public static let provider = configure()

        // parity: ai/src/providers/amazon-bedrock.ts#model [status=implemented hash=919ce2139f56]
        public static func model(_ modelID: String, settings: Settings = Settings()) -> ConfiguredModel {
            configure(settings).model(modelID)
        }
    }

    // MARK: - 4. AnthropicCompatible (anthropic-compatible.ts — 10 symbols)

    public enum AnthropicCompatible {
        // parity: ai/src/providers/anthropic-compatible.ts#AnthropicOptionsInput [status=implemented hash=2f120bdfee9d]
        public typealias AnthropicOptionsInput = AIProtocols.AnthropicMessages.OptionsInput
        // parity: ai/src/providers/anthropic-compatible.ts#AnthropicProviderOptionsInput [status=implemented hash=44d671cc6dd1]
        public typealias AnthropicProviderOptionsInput = AIProtocols.AnthropicMessages.ProviderOptionsInput
        // parity: ai/src/providers/anthropic-compatible.ts#AnthropicThinkingInput [status=implemented hash=f283bf4aedd3]
        public typealias AnthropicThinkingInput = AIProtocols.AnthropicMessages.ThinkingInput

        // parity: ai/src/providers/anthropic-compatible.ts#id [status=implemented hash=fe3b83015336]
        public static let id = "anthropic-compatible"

        // parity: ai/src/providers/anthropic-compatible.ts#Config [status=implemented hash=5c6ad8a553e7]
        public typealias Config = ProviderConfig

        // parity: ai/src/providers/anthropic-compatible.ts#Settings [status=implemented hash=bf062774b60e]
        public typealias Settings = ProviderConfig

        public static let compatibleRoute = AIProtocols.AnthropicMessages.route.with(id: "anthropic-compatible-messages", provider: id)

        // parity: ai/src/providers/anthropic-compatible.ts#routes [status=implemented hash=9b9e1daf0b50]
        public static let routes: [AIProtocols.ChatRouteSpec] = [compatibleRoute]

        // parity: ai/src/providers/anthropic-compatible.ts#configure [status=implemented hash=bd6d8d0a897c]
        public static func configure(_ input: Config) throws(ProviderConfigurationError) -> ConfiguredProvider {
            let prov = input.providerOverride ?? id
            guard let baseURL = input.baseURL, !baseURL.isEmpty else {
                throw ProviderConfigurationError(provider: prov, message: "Anthropic-compatible providers require a baseURL")
            }
            let auth = resolveHeaderAuth(config: input, envVars: [], headerName: "x-api-key")
            let baseRoute = prov == "anthropic" ? AIProtocols.AnthropicMessages.route : compatibleRoute
            return ConfiguredProvider(
                id: prov,
                baseURL: baseURL,
                auth: auth,
                headers: input.headers ?? [:],
                routes: [baseRoute],
                defaultRoute: baseRoute,
                defaultProviderOptions: input.providerOptions ?? [:]
            )
        }

        // parity: ai/src/providers/anthropic-compatible.ts#provider [status=implemented hash=ce1b6df0aba2]
        public static let provider = (id: id, routes: routes)

        // parity: ai/src/providers/anthropic-compatible.ts#model [status=implemented hash=02417383ef9b]
        public static func model(_ modelID: String, settings: Settings) throws(ProviderConfigurationError) -> ConfiguredModel {
            if case .explicit = settings.apiKey, settings.authToken != nil {
                throw ProviderConfigurationError(provider: settings.providerOverride ?? id, message: "Anthropic-compatible apiKey cannot be combined with authToken")
            }
            return try configure(settings).model(modelID)
        }
    }

    // MARK: - 5. Anthropic (anthropic.ts — 10 symbols)

    public enum Anthropic {
        // parity: ai/src/providers/anthropic.ts#AnthropicOptionsInput [status=implemented hash=2f120bdfee9d]
        public typealias AnthropicOptionsInput = AIProtocols.AnthropicMessages.OptionsInput
        // parity: ai/src/providers/anthropic.ts#AnthropicProviderOptionsInput [status=implemented hash=44d671cc6dd1]
        public typealias AnthropicProviderOptionsInput = AIProtocols.AnthropicMessages.ProviderOptionsInput
        // parity: ai/src/providers/anthropic.ts#AnthropicThinkingInput [status=implemented hash=f283bf4aedd3]
        public typealias AnthropicThinkingInput = AIProtocols.AnthropicMessages.ThinkingInput

        // parity: ai/src/providers/anthropic.ts#id [status=implemented hash=5ea75c3203e4]
        public static let id = "anthropic"

        // parity: ai/src/providers/anthropic.ts#routes [status=implemented hash=3fb8f92d68fb]
        public static let routes: [AIProtocols.ChatRouteSpec] = [AIProtocols.AnthropicMessages.route]

        // parity: ai/src/providers/anthropic.ts#Config [status=implemented hash=8b893ca53346]
        public typealias Config = ProviderConfig

        // parity: ai/src/providers/anthropic.ts#Settings [status=implemented hash=bf062774b60e]
        public typealias Settings = ProviderConfig

        // parity: ai/src/providers/anthropic.ts#configure [status=implemented hash=6ef9eff864c2]
        public static func configure(
            _ input: Config = Config(),
            environment: any EnvironmentProviding = SystemEnvironment.shared
        ) -> ConfiguredProvider {
            let auth = resolveHeaderAuth(config: input, envVars: ["ANTHROPIC_API_KEY"], headerName: "x-api-key", environment: environment)
            return ConfiguredProvider(
                id: id,
                baseURL: input.baseURL ?? AIProtocols.AnthropicMessages.DEFAULT_BASE_URL,
                auth: auth,
                headers: input.headers ?? [:],
                routes: routes,
                defaultRoute: AIProtocols.AnthropicMessages.route,
                defaultProviderOptions: input.providerOptions ?? [:]
            )
        }

        // parity: ai/src/providers/anthropic.ts#provider [status=implemented hash=370740ab87b4]
        public static let provider = configure()

        // parity: ai/src/providers/anthropic.ts#model [status=implemented hash=c3e391a97a9c]
        public static func model(_ modelID: String, settings: Settings = Settings()) throws(ProviderConfigurationError) -> ConfiguredModel {
            if case .explicit = settings.apiKey, settings.authToken != nil {
                throw ProviderConfigurationError(provider: id, message: "Anthropic apiKey cannot be combined with authToken")
            }
            return configure(settings).model(modelID)
        }
    }

    // MARK: - 6. AssemblyAI (assemblyai.ts — 5 symbols)

    public enum AssemblyAI {
        // parity: ai/src/providers/assemblyai.ts#id [status=implemented hash=84ff7f787c75]
        public static let id = "assemblyai"
        // parity: ai/src/providers/assemblyai.ts#Config [status=implemented hash=d330416f1570]
        public typealias Config = ProviderConfig

        // parity: ai/src/providers/assemblyai.ts#configure [status=implemented hash=6ef9eff864c2]
        public static func configure(
            _ input: Config = Config(),
            environment: any EnvironmentProviding = SystemEnvironment.shared
        ) -> ConfiguredProvider {
            let auth = resolveHeaderAuth(config: input, envVars: ["ASSEMBLYAI_API_KEY"], headerName: "authorization", environment: environment)
            return ConfiguredProvider(id: id, baseURL: input.baseURL ?? AIProtocols.AssemblyAITranscription.DEFAULT_BASE_URL, auth: auth, headers: input.headers ?? [:])
        }

        // parity: ai/src/providers/assemblyai.ts#provider [status=implemented hash=370740ab87b4]
        public static let provider = configure()

        // parity: ai/src/providers/assemblyai.ts#transcription [status=implemented hash=287f8a2250f5]
        public static func transcription(_ modelID: String, config: Config = Config()) -> AIProtocols.MediaModelHandle {
            AIProtocols.AssemblyAITranscription.model(.init(id: modelID, provider: id, baseURL: config.baseURL))
        }
    }

    // MARK: - 7. Azure (azure.ts — 15 symbols)

    public enum Azure {
        // parity: ai/src/providers/azure.ts#id [status=implemented hash=2fa14d6a415a]
        public static let id = "azure"

        // parity: ai/src/providers/azure.ts#Config [status=implemented hash=8394379060a6]
        public typealias Config = ProviderConfig

        // parity: ai/src/providers/azure.ts#Settings [status=implemented hash=ef510df962b9]
        public typealias Settings = ProviderConfig

        // parity: ai/src/providers/azure.ts#MessagesSettings [status=implemented hash=06cef1418d17]
        public typealias MessagesSettings = ProviderConfig

        public static let responsesRoute = AIProtocols.OpenAIResponses.route.with(id: "azure-openai-responses", provider: id)
        public static let chatRoute = AIProtocols.OpenAIChat.route.with(id: "azure-openai-chat", provider: id)
        public static let messagesRoute = AIProtocols.AnthropicMessages.route.with(id: "azure-anthropic-messages", provider: id)

        // parity: ai/src/providers/azure.ts#routes [status=implemented hash=507b1ad0c8b2]
        public static let routes: [AIProtocols.ChatRouteSpec] = [responsesRoute, chatRoute, messagesRoute]

        public static func resolveEndpoint(input: Config, modelID: String) throws(ProviderConfigurationError) -> (baseURL: String, query: [String: String]) {
            let rawBase: String
            if let b = input.baseURL {
                rawBase = trimBaseURL(b)
            } else if let resource = input.resourceName {
                rawBase = "https://\(resource.trimmingASCIIWhitespace()).openai.azure.com/openai"
            } else {
                throw ProviderConfigurationError(provider: id, message: "Azure requires resourceName or baseURL")
            }
            var query = input.queryParams ?? [:]
            if input.useDeploymentBasedUrls == true {
                query["api-version"] = input.apiVersion ?? "v1"
                return ("\(rawBase)/deployments/\(modelID)", query)
            }
            if input.baseURL != nil && !rawBase.contains(".openai.azure.com") {
                return (rawBase, query)
            }
            query["api-version"] = input.apiVersion ?? "v1"
            return ("\(rawBase)/v1", query)
        }

        // parity: ai/src/providers/azure.ts#configure [status=implemented hash=22ba18f4df65]
        public static func configure(
            _ input: Config,
            environment: any EnvironmentProviding = SystemEnvironment.shared
        ) -> ConfiguredProvider {
            let keyAuth = resolveHeaderAuth(config: input, envVars: ["AZURE_OPENAI_API_KEY"], headerName: "api-key", environment: environment)
            let auth: AIProtocolUtils.AuthStrategy = input.auth ?? .sequence([.remove("authorization"), keyAuth])
            let base = input.baseURL ?? input.resourceName.map { "https://\($0.trimmingASCIIWhitespace()).openai.azure.com/openai/v1" }
            return ConfiguredProvider(
                id: id,
                baseURL: base,
                auth: auth,
                headers: input.headers ?? [:],
                routes: routes,
                defaultRoute: responsesRoute,
                defaultProviderOptions: input.providerOptions ?? [:]
            )
        }

        // parity: ai/src/providers/azure.ts#provider [status=implemented hash=ce1b6df0aba2]
        public static let provider = (id: id, routes: routes)

        // parity: ai/src/providers/azure.ts#responsesModel [status=implemented hash=cfab73c14f1e]
        public static func responsesModel(_ modelID: String, settings: Settings) throws(ProviderConfigurationError) -> ConfiguredModel {
            let ep = try resolveEndpoint(input: settings, modelID: modelID)
            var adjusted = settings
            adjusted.baseURL = ep.baseURL
            return configure(adjusted).model(modelID, route: responsesRoute)
        }

        // parity: ai/src/providers/azure.ts#chatModel [status=implemented hash=fa477414f442]
        public static func chatModel(_ modelID: String, settings: Settings) throws(ProviderConfigurationError) -> ConfiguredModel {
            let ep = try resolveEndpoint(input: settings, modelID: modelID)
            var adjusted = settings
            adjusted.baseURL = ep.baseURL
            return configure(adjusted).model(modelID, route: chatRoute, capabilities: .init(promptCacheKey: true))
        }

        // parity: ai/src/providers/azure.ts#messagesModel [status=implemented hash=d8470506603d]
        public static func messagesModel(_ modelID: String, settings: MessagesSettings) throws(ProviderConfigurationError) -> ConfiguredModel {
            let base: String
            if let b = settings.baseURL { base = trimBaseURL(b) }
            else if let r = settings.resourceName { base = "https://\(r.trimmingASCIIWhitespace()).services.ai.azure.com/anthropic/v1" }
            else { throw ProviderConfigurationError(provider: id, message: "Azure requires resourceName or baseURL") }
            var adjusted = settings
            adjusted.baseURL = base
            let keyAuth = resolveHeaderAuth(config: settings, envVars: ["AZURE_OPENAI_API_KEY"], headerName: "x-api-key")
            adjusted.auth = settings.auth ?? .sequence([.remove("authorization"), keyAuth])
            return configure(adjusted).model(modelID, route: messagesRoute)
        }

        // parity: ai/src/providers/azure.ts#imageModel [status=implemented hash=8435b8056403]
        public static func imageModel(_ modelID: String, settings: Settings) throws(ProviderConfigurationError) -> AIProtocols.MediaModelHandle {
            let ep = try resolveEndpoint(input: settings, modelID: modelID)
            return AIProtocols.OpenAIImages.model(.init(id: modelID, provider: id, baseURL: ep.baseURL, providerOptions: settings.providerOptions))
        }

        // parity: ai/src/providers/azure.ts#embeddingModel [status=implemented hash=653fe90141a8]
        public static func embeddingModel(_ modelID: String, settings: Settings) throws(ProviderConfigurationError) -> AIProtocols.MediaModelHandle {
            let ep = try resolveEndpoint(input: settings, modelID: modelID)
            return AIProtocols.MediaModelHandle(id: modelID, provider: id, protocolID: "openai-embeddings", baseURL: ep.baseURL, path: AIProtocols.OpenAIEmbeddings.PATH, mode: .inline, providerOptions: settings.providerOptions)
        }

        // parity: ai/src/providers/azure.ts#model [status=implemented hash=30e89e3428b9]
        public static func model(_ modelID: String, settings: Settings) throws(ProviderConfigurationError) -> ConfiguredModel {
            try responsesModel(modelID, settings: settings)
        }

        // parity: ai/src/providers/azure.ts#responses [status=implemented hash=804ee5dbd404]
        public static func responses(_ modelID: String, settings: Settings) throws(ProviderConfigurationError) -> ConfiguredModel {
            try responsesModel(modelID, settings: settings)
        }

        // parity: ai/src/providers/azure.ts#chat [status=implemented hash=7b39724a655f]
        public static func chat(_ modelID: String, settings: Settings) throws(ProviderConfigurationError) -> ConfiguredModel {
            try chatModel(modelID, settings: settings)
        }
    }

    // MARK: - 8. Baseten (baseten.ts — 11 symbols)

    public enum Baseten {
        public static let defaultBaseURL = "https://inference.baseten.co/v1"

        // parity: ai/src/providers/baseten.ts#id [status=implemented hash=a73bc827246c]
        public static let id = "baseten"
        // parity: ai/src/providers/baseten.ts#Config [status=implemented hash=3f41ed19d775]
        public typealias Config = ProviderConfig
        // parity: ai/src/providers/baseten.ts#BasetenDecisionOptions [status=implemented hash=23a82cb022fd]
        public struct BasetenDecisionOptions: Equatable, Hashable, Sendable {
            public var extra: [String: JSONValue]
            public init(extra: [String: JSONValue] = [:]) { self.extra = extra }
        }
        // parity: ai/src/providers/baseten.ts#Settings [status=implemented hash=8b7d78d33938]
        public typealias Settings = ProviderConfig
        // parity: ai/src/providers/baseten.ts#route [status=implemented hash=7e0261fe9836]
        public static let route = AIProtocols.OpenAIChat.route.with(id: id, provider: id, providerMetadataKey: id, baseURL: defaultBaseURL)
        // parity: ai/src/providers/baseten.ts#routes [status=implemented hash=d8efbd745746]
        public static let routes: [AIProtocols.ChatRouteSpec] = [route]
        // parity: ai/src/providers/baseten.ts#configure [status=implemented hash=6ef9eff864c2]
        public static func configure(_ input: Config = Config(), environment: any EnvironmentProviding = SystemEnvironment.shared) -> ConfiguredProvider {
            ConfiguredProvider(id: id, baseURL: input.baseURL ?? defaultBaseURL, auth: resolveBearerAuth(config: input, envVars: ["BASETEN_API_KEY"], environment: environment), headers: input.headers ?? [:], routes: routes, defaultRoute: route, defaultProviderOptions: input.providerOptions ?? [:])
        }
        // parity: ai/src/providers/baseten.ts#provider [status=implemented hash=370740ab87b4]
        public static let provider = configure()
        // parity: ai/src/providers/baseten.ts#decision [status=implemented hash=e92859a494dc]
        public static func decision(_ modelID: String, providerOptions: [String: JSONValue]? = nil) -> AIProtocols.MediaModelHandle {
            AIProtocols.MediaModelHandle(id: modelID, provider: id, protocolID: "system-one", baseURL: defaultBaseURL, path: AIProtocols.SystemOneProtocol.DEFAULT_PATH, mode: .inline, providerOptions: providerOptions)
        }
        // parity: ai/src/providers/baseten.ts#model [status=implemented hash=5cfdd0ca1b72]
        public static func model(_ modelID: String, settings: Settings = Settings()) -> ConfiguredModel {
            configure(settings).model(modelID)
        }
        // parity: ai/src/providers/baseten.ts#decisionModel [status=implemented hash=7432f6ac602f]
        public static func decisionModel(_ modelID: String, settings: Settings = Settings()) -> AIProtocols.MediaModelHandle {
            AIProtocols.MediaModelHandle(id: modelID, provider: id, protocolID: "system-one", baseURL: settings.baseURL ?? defaultBaseURL, path: AIProtocols.SystemOneProtocol.DEFAULT_PATH, mode: .inline, providerOptions: settings.providerOptions)
        }
    }

    // MARK: - 9. BytePlus (byteplus.ts — 7 symbols)

    public enum BytePlus {
        // parity: ai/src/providers/byteplus.ts#id [status=implemented hash=341163ed5f53]
        public static let id = "byteplus"
        // parity: ai/src/providers/byteplus.ts#Config [status=implemented hash=e2282dcfffaf]
        public typealias Config = ProviderConfig
        // parity: ai/src/providers/byteplus.ts#Settings [status=implemented hash=5dc534ea0f5c]
        public typealias Settings = ProviderConfig
        // parity: ai/src/providers/byteplus.ts#configure [status=implemented hash=6ef9eff864c2]
        public static func configure(_ input: Config = Config(), environment: any EnvironmentProviding = SystemEnvironment.shared) -> ConfiguredProvider {
            ConfiguredProvider(id: id, baseURL: input.baseURL ?? AIProtocols.SeedanceVideo.BYTEPLUS_BASE_URL, auth: resolveBearerAuth(config: input, envVars: ["BYTEPLUS_API_KEY"], environment: environment), headers: input.headers ?? [:])
        }
        // parity: ai/src/providers/byteplus.ts#provider [status=implemented hash=370740ab87b4]
        public static let provider = configure()
        // parity: ai/src/providers/byteplus.ts#videoModel [status=implemented hash=a5eb00d79b4d]
        public static func videoModel(_ modelID: String, settings: Settings = Settings()) -> AIProtocols.MediaModelHandle {
            AIProtocols.SeedanceVideo.model(.init(id: modelID, provider: id, baseURL: settings.baseURL, providerOptions: settings.providerOptions), provider: .byteplus)
        }
        // parity: ai/src/providers/byteplus.ts#video [status=implemented hash=04f893e14126]
        public static func video(_ modelID: String) -> AIProtocols.MediaModelHandle {
            videoModel(modelID)
        }
    }

    // MARK: - 10. Cartesia (cartesia.ts — 5 symbols)

    public enum Cartesia {
        // parity: ai/src/providers/cartesia.ts#id [status=implemented hash=157657196bcb]
        public static let id = "cartesia"
        // parity: ai/src/providers/cartesia.ts#Config [status=implemented hash=e2282dcfffaf]
        public typealias Config = ProviderConfig
        // parity: ai/src/providers/cartesia.ts#configure [status=implemented hash=6ef9eff864c2]
        public static func configure(_ input: Config = Config(), environment: any EnvironmentProviding = SystemEnvironment.shared) -> ConfiguredProvider {
            ConfiguredProvider(id: id, baseURL: input.baseURL ?? AIProtocols.CartesiaSpeech.DEFAULT_BASE_URL, auth: resolveBearerAuth(config: input, envVars: ["CARTESIA_API_KEY"], environment: environment), headers: ["Cartesia-Version": AIProtocols.CartesiaSpeech.API_VERSION])
        }
        // parity: ai/src/providers/cartesia.ts#provider [status=implemented hash=370740ab87b4]
        public static let provider = configure()
        // parity: ai/src/providers/cartesia.ts#speech [status=implemented hash=5cc6042ca4db]
        public static func speech(_ modelID: String, config: Config = Config()) -> AIProtocols.MediaModelHandle {
            AIProtocols.CartesiaSpeech.model(.init(id: modelID, provider: id, baseURL: config.baseURL, providerOptions: config.providerOptions))
        }
    }

    // MARK: - 11. Cerebras (cerebras.ts — 8 symbols)

    public enum Cerebras {
        public static let defaultBaseURL = "https://api.cerebras.ai/v1"
        // parity: ai/src/providers/cerebras.ts#id [status=implemented hash=aa0c41295242]
        public static let id = "cerebras"
        // parity: ai/src/providers/cerebras.ts#Config [status=implemented hash=3f41ed19d775]
        public typealias Config = ProviderConfig
        // parity: ai/src/providers/cerebras.ts#Settings [status=implemented hash=8b7d78d33938]
        public typealias Settings = ProviderConfig
        // parity: ai/src/providers/cerebras.ts#route [status=implemented hash=3fd188b1c9e5]
        public static let route = AIProtocols.OpenAIChat.route.with(id: id, provider: id, providerMetadataKey: id, baseURL: defaultBaseURL)
        // parity: ai/src/providers/cerebras.ts#routes [status=implemented hash=d8efbd745746]
        public static let routes: [AIProtocols.ChatRouteSpec] = [route]
        // parity: ai/src/providers/cerebras.ts#configure [status=implemented hash=6ef9eff864c2]
        public static func configure(_ input: Config = Config(), environment: any EnvironmentProviding = SystemEnvironment.shared) -> ConfiguredProvider {
            ConfiguredProvider(id: id, baseURL: input.baseURL ?? defaultBaseURL, auth: resolveBearerAuth(config: input, envVars: ["CEREBRAS_API_KEY"], environment: environment), headers: input.headers ?? [:], routes: routes, defaultRoute: route, defaultProviderOptions: input.providerOptions ?? [:])
        }
        // parity: ai/src/providers/cerebras.ts#provider [status=implemented hash=370740ab87b4]
        public static let provider = configure()
        // parity: ai/src/providers/cerebras.ts#model [status=implemented hash=5cfdd0ca1b72]
        public static func model(_ modelID: String, settings: Settings = Settings()) -> ConfiguredModel {
            configure(settings).model(modelID)
        }
    }

    // MARK: - 12. CloudflareShared, CloudflareAIGateway & CloudflareWorkersAI (27 symbols)

    public enum CloudflareShared {
        // parity: ai/src/providers/cloudflare-shared.ts#requireAccountId [status=implemented hash=4601c2875e37]
        public static func requireAccountId(_ input: ProviderConfig, provider: String, name: String) throws(ProviderConfigurationError) -> String {
            guard let id = input.accountId, !id.isEmpty else {
                throw ProviderConfigurationError(provider: provider, message: "\(name).configure requires accountId unless baseURL is supplied")
            }
            return id
        }

        // parity: ai/src/providers/cloudflare-shared.ts#baseURL [status=implemented hash=d805d5e6769d]
        public static func baseURL(_ input: ProviderConfig, provider: String, name: String) throws(ProviderConfigurationError) -> String {
            if let b = input.baseURL, !b.isEmpty { return b }
            let account = try requireAccountId(input, provider: provider, name: name)
            return "https://api.cloudflare.com/client/v4/accounts/\(AIProtocolUtils.JSONCodec.percentEncodePathComponent(account))/ai/v1"
        }

        // parity: ai/src/providers/cloudflare-shared.ts#runBaseURL [status=implemented hash=5c814cd22d0c]
        public static func runBaseURL(_ input: ProviderConfig, provider: String, name: String) throws(ProviderConfigurationError) -> String {
            let url = trimBaseURL(try baseURL(input, provider: provider, name: name))
            guard url.hasSuffix("/ai/v1") else {
                throw ProviderConfigurationError(provider: provider, message: "\(name) needs accountId or a baseURL ending in /ai/v1 to derive the Run API base")
            }
            return String(url.dropLast(3)) + "/run"
        }
    }

    public enum CloudflareAIGateway {
        // parity: ai/src/providers/cloudflare-ai-gateway.ts#id [status=implemented hash=3dfa358d5008]
        public static let id = "cloudflare-ai-gateway"
        // parity: ai/src/providers/cloudflare-ai-gateway.ts#authEnvVars [status=implemented hash=e34eaba9edd2]
        public static let authEnvVars: [String] = ["CLOUDFLARE_API_TOKEN", "CF_AIG_TOKEN"]
        // parity: ai/src/providers/cloudflare-ai-gateway.ts#Config [status=implemented hash=0c86f95404d6]
        public typealias Config = ProviderConfig
        // parity: ai/src/providers/cloudflare-ai-gateway.ts#Settings [status=implemented hash=58a7406a5ad6]
        public typealias Settings = ProviderConfig

        // parity: ai/src/providers/cloudflare-ai-gateway.ts#baseURL [status=implemented hash=4f55841093d1]
        public static func baseURL(_ input: Config) throws(ProviderConfigurationError) -> String {
            try CloudflareShared.baseURL(input, provider: id, name: "CloudflareAIGateway")
        }

        // parity: ai/src/providers/cloudflare-ai-gateway.ts#runBaseURL [status=implemented hash=c7f97740be25]
        public static func runBaseURL(_ input: Config) throws(ProviderConfigurationError) -> String {
            try CloudflareShared.runBaseURL(input, provider: id, name: "CloudflareAIGateway")
        }

        // parity: ai/src/providers/cloudflare-ai-gateway.ts#responsesRoute [status=implemented hash=4eb05b6066e6]
        public static let responsesRoute = AIProtocols.OpenAIResponses.route.with(id: "cloudflare-ai-gateway-responses", provider: id)
        // parity: ai/src/providers/cloudflare-ai-gateway.ts#messagesRoute [status=implemented hash=9371bdb189ea]
        public static let messagesRoute = AIProtocols.AnthropicMessages.route.with(id: "cloudflare-ai-gateway-messages", provider: id)
        // parity: ai/src/providers/cloudflare-ai-gateway.ts#route [status=implemented hash=68f71e5a3e1c]
        public static let route = AIProtocols.OpenAIChat.route.with(id: "cloudflare-ai-gateway-chat", provider: id)
        // parity: ai/src/providers/cloudflare-ai-gateway.ts#routes [status=implemented hash=29169c79c1b7]
        public static let routes: [AIProtocols.ChatRouteSpec] = [responsesRoute, messagesRoute, route]

        private static func resolvedGatewayId(_ input: Config) -> String {
            let trimmed = input.gatewayId?.trimmingASCIIWhitespace() ?? ""
            return trimmed.isEmpty ? "default" : trimmed
        }

        private static func gatewayHeaders(_ input: Config) -> [String: String] {
            var hdrs: [String: String] = [:]
            if let opts = input.providerOptions {
                if let metadata = opts["metadata"] {
                    hdrs["cf-aig-metadata"] = AIProtocolUtils.JSONCodec.encode(metadata)
                }
                if let ttl = opts["cacheTtl"] {
                    if case .int(let n) = ttl { hdrs["cf-aig-cache-ttl"] = String(n) }
                    else if case .double(let d) = ttl { hdrs["cf-aig-cache-ttl"] = String(d) }
                }
                if case .string(let key) = opts["cacheKey"] { hdrs["cf-aig-cache-key"] = key }
                if case .bool(let skip) = opts["skipCache"] { hdrs["cf-aig-skip-cache"] = String(skip) }
                if case .bool(let log) = opts["collectLog"] { hdrs["cf-aig-collect-log"] = String(log) }
            }
            for (k, v) in input.headers ?? [:] { hdrs[k] = v }
            return hdrs
        }

        private static func passthroughURL(_ input: Config, providerSegment: String) throws(ProviderConfigurationError) -> String {
            let account = try CloudflareShared.requireAccountId(input, provider: id, name: "CloudflareAIGateway")
            let encAccount = AIProtocolUtils.JSONCodec.percentEncodePathComponent(account)
            let encGateway = AIProtocolUtils.JSONCodec.percentEncodePathComponent(resolvedGatewayId(input))
            return "https://gateway.ai.cloudflare.com/v1/\(encAccount)/\(encGateway)/\(providerSegment)"
        }

        private static func passthroughAuth(
            _ input: Config,
            environment: any EnvironmentProviding
        ) -> AIProtocolUtils.AuthStrategy {
            if let custom = input.auth { return custom }
            var adjusted = input
            if let gwKey = input.gatewayApiKey { adjusted.apiKey = .explicit(gwKey) }
            let bearer = resolveBearerAuth(config: adjusted, envVars: authEnvVars, environment: environment)
            if case .bearer(let token) = bearer {
                return .header(name: "cf-aig-authorization", value: "Bearer \(token)")
            }
            return bearer
        }

        // parity: ai/src/providers/cloudflare-ai-gateway.ts#configure [status=implemented hash=c7ab99d1770a]
        public static func configure(
            _ input: Config,
            environment: any EnvironmentProviding = SystemEnvironment.shared
        ) throws(ProviderConfigurationError) -> ConfiguredProvider {
            let resolvedBase = try baseURL(input)
            var adjusted = input
            if let gwKey = input.gatewayApiKey { adjusted.apiKey = .explicit(gwKey) }
            let auth = resolveBearerAuth(config: adjusted, envVars: authEnvVars, environment: environment)
            var hdrs = gatewayHeaders(input)
            hdrs["cf-aig-gateway-id"] = resolvedGatewayId(input)
            return ConfiguredProvider(id: id, baseURL: resolvedBase, auth: auth, headers: hdrs, routes: routes, defaultRoute: route, defaultProviderOptions: input.providerOptions ?? [:])
        }

        // parity: ai/src/providers/cloudflare-ai-gateway.ts#provider [status=implemented hash=2a83695cb527]
        public static let provider = (id: id, routes: routes)

        // parity: ai/src/providers/cloudflare-ai-gateway.ts#chat [status=implemented hash=bfac22307c8f]
        public static func chat(
            _ modelID: String,
            settings: Settings,
            environment: any EnvironmentProviding = SystemEnvironment.shared
        ) throws(ProviderConfigurationError) -> ConfiguredModel {
            let normalized = modelID.hasPrefix("workers-ai/") ? String(modelID.dropFirst("workers-ai/".count)) : modelID
            return try configure(settings, environment: environment).model(normalized, route: route)
        }

        // parity: ai/src/providers/cloudflare-ai-gateway.ts#responses [status=implemented hash=78d92cc5bbfe]
        public static func responses(
            _ modelID: String,
            settings: Settings,
            environment: any EnvironmentProviding = SystemEnvironment.shared
        ) throws(ProviderConfigurationError) -> ConfiguredModel {
            let native = settings.baseURL == nil || settings.baseURL?.isEmpty == true
            if native {
                let targetBase = try passthroughURL(settings, providerSegment: "openai")
                let auth = passthroughAuth(settings, environment: environment)
                let configured = ConfiguredProvider(
                    id: id,
                    baseURL: targetBase,
                    auth: auth,
                    headers: gatewayHeaders(settings),
                    routes: routes,
                    defaultRoute: responsesRoute,
                    defaultProviderOptions: settings.providerOptions ?? [:]
                )
                let normalized = modelID.hasPrefix("openai/") ? String(modelID.dropFirst("openai/".count)) : modelID
                return configured.model(normalized, route: responsesRoute)
            }
            return try configure(settings, environment: environment).model(modelID, route: responsesRoute)
        }

        // parity: ai/src/providers/cloudflare-ai-gateway.ts#messages [status=implemented hash=db1f90e187d2]
        public static func messages(
            _ modelID: String,
            settings: Settings,
            environment: any EnvironmentProviding = SystemEnvironment.shared
        ) throws(ProviderConfigurationError) -> ConfiguredModel {
            let native = settings.baseURL == nil || settings.baseURL?.isEmpty == true
            if native {
                let targetBase = try passthroughURL(settings, providerSegment: "anthropic/v1")
                let auth = passthroughAuth(settings, environment: environment)
                let configured = ConfiguredProvider(
                    id: id,
                    baseURL: targetBase,
                    auth: auth,
                    headers: gatewayHeaders(settings),
                    routes: routes,
                    defaultRoute: messagesRoute,
                    defaultProviderOptions: settings.providerOptions ?? [:]
                )
                let stripped = modelID.hasPrefix("anthropic/") ? String(modelID.dropFirst("anthropic/".count)) : modelID
                let normalized = stripped.replacing(".", with: "-")
                return configured.model(normalized, route: messagesRoute)
            }
            return try configure(settings, environment: environment).model(modelID, route: messagesRoute)
        }

        // parity: ai/src/providers/cloudflare-ai-gateway.ts#model [status=implemented hash=61635358c550]
        public static func model(
            _ modelID: String,
            settings: Settings,
            environment: any EnvironmentProviding = SystemEnvironment.shared
        ) throws(ProviderConfigurationError) -> ConfiguredModel {
            if modelID.hasPrefix("openai/") {
                return try responses(modelID, settings: settings, environment: environment)
            }
            if modelID.hasPrefix("anthropic/") {
                return try messages(modelID, settings: settings, environment: environment)
            }
            return try chat(modelID, settings: settings, environment: environment)
        }

        // parity: ai/src/providers/cloudflare-ai-gateway.ts#decisionModel [status=implemented hash=88cf044213fb]
        public static func decisionModel(
            _ modelID: String,
            settings: Settings
        ) throws(ProviderConfigurationError) -> AIProtocols.MediaModelHandle {
            let runBase = try runBaseURL(settings)
            return AIProtocols.MediaModelHandle(
                id: modelID,
                provider: id,
                protocolID: "cloudflare-run-decisions",
                baseURL: runBase,
                path: "/\(modelID)",
                mode: .inline,
                providerOptions: settings.providerOptions
            )
        }
    }

    public enum CloudflareWorkersAI {
        // parity: ai/src/providers/cloudflare-workers-ai.ts#id [status=implemented hash=031f0f21999f]
        public static let id = "cloudflare-workers-ai"
        // parity: ai/src/providers/cloudflare-workers-ai.ts#authEnvVars [status=implemented hash=9e9ff2a2386c]
        public static let authEnvVars: [String] = ["CLOUDFLARE_API_KEY", "CLOUDFLARE_WORKERS_AI_TOKEN", "CLOUDFLARE_API_TOKEN"]
        // parity: ai/src/providers/cloudflare-workers-ai.ts#Config [status=implemented hash=810ae700b4ff]
        public typealias Config = ProviderConfig
        // parity: ai/src/providers/cloudflare-workers-ai.ts#Settings [status=implemented hash=2e91def0fbe5]
        public typealias Settings = ProviderConfig

        // parity: ai/src/providers/cloudflare-workers-ai.ts#baseURL [status=implemented hash=046a0a47ee39]
        public static func baseURL(_ input: Config) throws(ProviderConfigurationError) -> String {
            try CloudflareShared.baseURL(input, provider: id, name: "CloudflareWorkersAI")
        }

        // parity: ai/src/providers/cloudflare-workers-ai.ts#runBaseURL [status=implemented hash=bfededaea0e0]
        public static func runBaseURL(_ input: Config) throws(ProviderConfigurationError) -> String {
            try CloudflareShared.runBaseURL(input, provider: id, name: "CloudflareWorkersAI")
        }

        // parity: ai/src/providers/cloudflare-workers-ai.ts#route [status=implemented hash=6e132f9da641]
        public static let route = AIProtocols.OpenAIChat.route.with(id: id, provider: id, providerMetadataKey: id)
        // parity: ai/src/providers/cloudflare-workers-ai.ts#routes [status=implemented hash=d8efbd745746]
        public static let routes: [AIProtocols.ChatRouteSpec] = [route]

        // parity: ai/src/providers/cloudflare-workers-ai.ts#configure [status=implemented hash=da29efcd50f4]
        public static func configure(
            _ input: Config,
            environment: any EnvironmentProviding = SystemEnvironment.shared
        ) throws(ProviderConfigurationError) -> ConfiguredProvider {
            let resolvedBase = try baseURL(input)
            let auth = resolveBearerAuth(config: input, envVars: authEnvVars, environment: environment)
            return ConfiguredProvider(id: id, baseURL: resolvedBase, auth: auth, headers: input.headers ?? [:], routes: routes, defaultRoute: route, defaultProviderOptions: input.providerOptions ?? [:])
        }

        // parity: ai/src/providers/cloudflare-workers-ai.ts#provider [status=implemented hash=2a83695cb527]
        public static let provider = (id: id, routes: routes)

        // parity: ai/src/providers/cloudflare-workers-ai.ts#model [status=implemented hash=61635358c550]
        public static func model(_ modelID: String, settings: Settings) throws(ProviderConfigurationError) -> ConfiguredModel {
            try configure(settings).model(modelID)
        }

        // parity: ai/src/providers/cloudflare-workers-ai.ts#imageModel [status=implemented hash=8435b8056403]
        public static func imageModel(_ modelID: String, settings: Settings) throws(ProviderConfigurationError) -> AIProtocols.MediaModelHandle {
            let runBase = try runBaseURL(settings)
            return AIProtocols.CloudflareWorkersAIImages.model(.init(id: modelID, provider: id, baseURL: runBase, providerOptions: settings.providerOptions))
        }

        // parity: ai/src/providers/cloudflare-workers-ai.ts#decisionModel [status=implemented hash=88cf044213fb]
        public static func decisionModel(_ modelID: String, settings: Settings) throws(ProviderConfigurationError) -> AIProtocols.MediaModelHandle {
            let runBase = try runBaseURL(settings)
            return AIProtocols.MediaModelHandle(id: modelID, provider: id, protocolID: "cloudflare-run-decisions", baseURL: runBase, path: "/\(modelID)", mode: .inline, providerOptions: settings.providerOptions)
        }
    }

    // MARK: - 13. Cohere (cohere.ts, cohere/chat.ts — 16 symbols)

    public enum Cohere {
        public static let compatibilityBaseURL = "https://api.cohere.ai/compatibility/v1"

        // parity: ai/src/providers/cohere.ts#id [status=implemented hash=0f45d1e64e6e]
        public static let id = "cohere"
        // parity: ai/src/providers/cohere.ts#ChatOptionsInput [status=implemented hash=d17b94dbfc5e]
        public struct ChatOptionsInput: Equatable, Hashable, Sendable {
            public var reasoningEffort: String?
            public init(reasoningEffort: String? = nil) { self.reasoningEffort = reasoningEffort }
        }
        // parity: ai/src/providers/cohere.ts#ProviderOptions [status=implemented hash=a3f12d1963ac]
        public typealias ProviderOptions = [String: JSONValue]
        // parity: ai/src/providers/cohere.ts#Config [status=implemented hash=f162f7402734]
        public typealias Config = ProviderConfig
        // parity: ai/src/providers/cohere.ts#Settings [status=implemented hash=e24315381288]
        public typealias Settings = ProviderConfig
        // parity: ai/src/providers/cohere.ts#route [status=implemented hash=5a4fa66efd34]
        public static let route = AIProtocols.CohereChat.route
        // parity: ai/src/providers/cohere.ts#chatRoute [status=implemented hash=ea9ff0f3c813]
        public static let chatRoute = AIProtocols.OpenAIChat.route.with(id: "cohere-chat-completions", provider: id, providerMetadataKey: "cohere", baseURL: compatibilityBaseURL)
        // parity: ai/src/providers/cohere.ts#routes [status=implemented hash=da5c558abc5d]
        public static let routes: [AIProtocols.ChatRouteSpec] = [route, chatRoute]
        // parity: ai/src/providers/cohere.ts#configure [status=implemented hash=6ef9eff864c2]
        public static func configure(_ input: Config = Config(), environment: any EnvironmentProviding = SystemEnvironment.shared) -> ConfiguredProvider {
            ConfiguredProvider(id: id, baseURL: input.baseURL ?? AIProtocols.CohereChat.DEFAULT_BASE_URL, auth: resolveBearerAuth(config: input, envVars: ["COHERE_API_KEY"], environment: environment), headers: input.headers ?? [:], routes: routes, defaultRoute: route, defaultProviderOptions: input.providerOptions ?? [:])
        }
        // parity: ai/src/providers/cohere.ts#provider [status=implemented hash=370740ab87b4]
        public static let provider = configure()
        // parity: ai/src/providers/cohere.ts#chat [status=implemented hash=c527949cbec3]
        public static func chat(_ modelID: String) -> ConfiguredModel {
            provider.model(modelID, route: chatRoute, compatibility: .init(reasoningField: "reasoning_content", maxTokensField: "max_tokens"), capabilities: .init(strictTools: false))
        }
        // parity: ai/src/providers/cohere.ts#embedding [status=implemented hash=8c37d296d564]
        public static func embedding(_ modelID: String, providerOptions: [String: JSONValue]? = nil) -> AIProtocols.MediaModelHandle {
            AIProtocols.MediaModelHandle(id: modelID, provider: id, protocolID: "openai-embeddings", baseURL: compatibilityBaseURL, path: AIProtocols.OpenAIEmbeddings.PATH, mode: .inline, providerOptions: providerOptions)
        }
        // parity: ai/src/providers/cohere.ts#model [status=implemented hash=df4eca365387]
        public static func model(_ modelID: String, settings: Settings = Settings()) -> ConfiguredModel {
            configure(settings).model(modelID)
        }
        // parity: ai/src/providers/cohere.ts#embeddingModel [status=implemented hash=0057624cf86b]
        public static func embeddingModel(_ modelID: String, settings: Settings = Settings()) -> AIProtocols.MediaModelHandle {
            AIProtocols.MediaModelHandle(id: modelID, provider: id, protocolID: "openai-embeddings", baseURL: settings.baseURL ?? compatibilityBaseURL, path: AIProtocols.OpenAIEmbeddings.PATH, mode: .inline, providerOptions: settings.providerOptions)
        }

        public enum Chat {
            // parity: ai/src/providers/cohere/chat.ts#Settings [status=implemented hash=740c75cc7a77]
            public typealias Settings = ProviderConfig
            // parity: ai/src/providers/cohere/chat.ts#model [status=implemented hash=35457503cfeb]
            public static func model(_ modelID: String, settings: Settings = Settings()) -> ConfiguredModel {
                var adjusted = settings
                if adjusted.baseURL == nil { adjusted.baseURL = compatibilityBaseURL }
                return configure(adjusted).model(modelID, route: chatRoute)
            }
        }
    }

    // MARK: - 14. Deepgram, DeepInfra, DeepSeek, DigitalOcean (42 symbols)

    public enum Deepgram {
        // parity: ai/src/providers/deepgram.ts#id [status=implemented hash=9a97e147dc49]
        public static let id = "deepgram"
        // parity: ai/src/providers/deepgram.ts#Config [status=implemented hash=e2282dcfffaf]
        public typealias Config = ProviderConfig
        // parity: ai/src/providers/deepgram.ts#configure [status=implemented hash=6ef9eff864c2]
        public static func configure(_ input: Config = Config(), environment: any EnvironmentProviding = SystemEnvironment.shared) -> ConfiguredProvider {
            let explicitKey: String? = { if case .explicit(let k) = input.apiKey { return k }; return environment.variable("DEEPGRAM_API_KEY") }()
            let auth: AIProtocolUtils.AuthStrategy = input.auth ?? (explicitKey.map { .header(name: "authorization", value: "Token \($0)") } ?? .none)
            return ConfiguredProvider(id: id, baseURL: input.baseURL ?? AIProtocols.DeepgramSpeech.DEFAULT_BASE_URL, auth: auth, headers: input.headers ?? [:])
        }
        // parity: ai/src/providers/deepgram.ts#provider [status=implemented hash=370740ab87b4]
        public static let provider = configure()
        // parity: ai/src/providers/deepgram.ts#speech [status=implemented hash=5cc6042ca4db]
        public static func speech(_ modelID: String, config: Config = Config()) -> AIProtocols.MediaModelHandle {
            AIProtocols.DeepgramSpeech.model(.init(id: modelID, provider: id, baseURL: config.baseURL, providerOptions: config.providerOptions))
        }
        // parity: ai/src/providers/deepgram.ts#transcription [status=implemented hash=287f8a2250f5]
        public static func transcription(_ modelID: String, config: Config = Config()) -> AIProtocols.MediaModelHandle {
            AIProtocols.DeepgramTranscription.model(.init(id: modelID, provider: id, baseURL: config.baseURL, providerOptions: config.providerOptions))
        }
    }

    public enum DeepInfra {
        public static let defaultBaseURL = "https://api.deepinfra.com/v1/openai"
        // parity: ai/src/providers/deepinfra.ts#id [status=implemented hash=f7acfc0cd744]
        public static let id = "deepinfra"
        // parity: ai/src/providers/deepinfra.ts#Config [status=implemented hash=3f41ed19d775]
        public typealias Config = ProviderConfig
        // parity: ai/src/providers/deepinfra.ts#Settings [status=implemented hash=8b7d78d33938]
        public typealias Settings = ProviderConfig
        // parity: ai/src/providers/deepinfra.ts#route [status=implemented hash=5efa7f95947f]
        public static let route = AIProtocols.OpenAIChat.route.with(id: id, provider: id, providerMetadataKey: id, baseURL: defaultBaseURL)
        // parity: ai/src/providers/deepinfra.ts#routes [status=implemented hash=d8efbd745746]
        public static let routes: [AIProtocols.ChatRouteSpec] = [route]
        // parity: ai/src/providers/deepinfra.ts#configure [status=implemented hash=6ef9eff864c2]
        public static func configure(_ input: Config = Config(), environment: any EnvironmentProviding = SystemEnvironment.shared) -> ConfiguredProvider {
            ConfiguredProvider(id: id, baseURL: input.baseURL ?? defaultBaseURL, auth: resolveBearerAuth(config: input, envVars: ["DEEPINFRA_API_KEY"], environment: environment), headers: input.headers ?? [:], routes: routes, defaultRoute: route, defaultProviderOptions: input.providerOptions ?? [:])
        }
        // parity: ai/src/providers/deepinfra.ts#provider [status=implemented hash=370740ab87b4]
        public static let provider = configure()
        // parity: ai/src/providers/deepinfra.ts#model [status=implemented hash=5cfdd0ca1b72]
        public static func model(_ modelID: String, settings: Settings = Settings()) -> ConfiguredModel { configure(settings).model(modelID) }
        // parity: ai/src/providers/deepinfra.ts#embeddingModel [status=implemented hash=c6d9ffa465c5]
        public static func embeddingModel(_ modelID: String, settings: Settings = Settings()) -> AIProtocols.MediaModelHandle {
            AIProtocols.MediaModelHandle(id: modelID, provider: id, protocolID: "openai-embeddings", baseURL: settings.baseURL ?? defaultBaseURL, path: AIProtocols.OpenAIEmbeddings.PATH, mode: .inline, providerOptions: settings.providerOptions)
        }
    }

    public enum DeepSeek {
        public static let defaultBaseURL = "https://api.deepseek.com/v1"
        // parity: ai/src/providers/deepseek.ts#id [status=implemented hash=80be16970cce]
        public static let id = "deepseek"
        // parity: ai/src/providers/deepseek.ts#Config [status=implemented hash=3f41ed19d775]
        public typealias Config = ProviderConfig
        // parity: ai/src/providers/deepseek.ts#Settings [status=implemented hash=8b7d78d33938]
        public typealias Settings = ProviderConfig
        // parity: ai/src/providers/deepseek.ts#route [status=implemented hash=a68789a71e80]
        public static let route = AIProtocols.OpenAIChat.route.with(id: id, provider: id, providerMetadataKey: id, baseURL: defaultBaseURL)
        // parity: ai/src/providers/deepseek.ts#routes [status=implemented hash=d8efbd745746]
        public static let routes: [AIProtocols.ChatRouteSpec] = [route]
        // parity: ai/src/providers/deepseek.ts#configure [status=implemented hash=6ef9eff864c2]
        public static func configure(_ input: Config = Config(), environment: any EnvironmentProviding = SystemEnvironment.shared) -> ConfiguredProvider {
            ConfiguredProvider(id: id, baseURL: input.baseURL ?? defaultBaseURL, auth: resolveBearerAuth(config: input, envVars: ["DEEPSEEK_API_KEY"], environment: environment), headers: input.headers ?? [:], routes: routes, defaultRoute: route, defaultProviderOptions: input.providerOptions ?? [:])
        }
        // parity: ai/src/providers/deepseek.ts#provider [status=implemented hash=370740ab87b4]
        public static let provider = configure()
        // parity: ai/src/providers/deepseek.ts#model [status=implemented hash=5cfdd0ca1b72]
        public static func model(_ modelID: String, settings: Settings = Settings()) -> ConfiguredModel { configure(settings).model(modelID) }
    }

    public enum DigitalOcean {
        public static let defaultBaseURL = "https://inference.do-ai.run/v1"
        // parity: ai/src/providers/digitalocean.ts#id [status=implemented hash=359e45b14427]
        public static let id = "digitalocean"
        // parity: ai/src/providers/digitalocean.ts#Config [status=implemented hash=1a8c3071025d]
        public typealias Config = ProviderConfig
        // parity: ai/src/providers/digitalocean.ts#Settings [status=implemented hash=3922c3292ddf]
        public typealias Settings = ProviderConfig
        // parity: ai/src/providers/digitalocean.ts#protocol [status=implemented hash=5f4b825458c9]
        public static let `protocol` = AIProtocols.ChatProtocolSpec(
            id: "digitalocean-chat", framing: .sseWithDone,
            buildBody: { req throws(AIProtocolUtils.ProtocolError) in try AIProtocols.OpenAIChat.fromRequest(req, useCacheControl: true) },
            parseStream: AIProtocols.OpenAIChat.parseSSEStream,
            makeStreamDecoder: { AIProtocols.OpenAIChat.StreamDecoder(request: $0) }
        )
        // parity: ai/src/providers/digitalocean.ts#route [status=implemented hash=e1d637b751cf]
        public static let route = AIProtocols.ChatRouteSpec(id: id, provider: id, providerMetadataKey: id, protocol: `protocol`, defaultBaseURL: defaultBaseURL, path: "/chat/completions")
        public static let responsesRoute = AIProtocols.ChatRouteSpec(id: "digitalocean-responses", provider: id, providerMetadataKey: id, protocol: AIProtocols.OpenResponses.`protocol`, defaultBaseURL: defaultBaseURL, path: "/responses", defaultProviderOptions: ["store": .bool(false), "include": .array([.string("reasoning.encrypted_content")])])
        // parity: ai/src/providers/digitalocean.ts#routes [status=implemented hash=8fdb0460cbc8]
        public static let routes: [AIProtocols.ChatRouteSpec] = [route, responsesRoute]
        // parity: ai/src/providers/digitalocean.ts#configure [status=implemented hash=6ef9eff864c2]
        public static func configure(_ input: Config = Config(), environment: any EnvironmentProviding = SystemEnvironment.shared) -> ConfiguredProvider {
            ConfiguredProvider(id: id, baseURL: input.baseURL ?? defaultBaseURL, auth: resolveBearerAuth(config: input, envVars: ["DIGITALOCEAN_ACCESS_TOKEN", "DIGITALOCEAN_API_KEY", "DO_INFERENCE_API_KEY"], environment: environment), headers: input.headers ?? [:], routes: routes, defaultRoute: route, defaultProviderOptions: input.providerOptions ?? [:], defaultCapabilities: .init(promptCacheKey: true))
        }
        // parity: ai/src/providers/digitalocean.ts#provider [status=implemented hash=370740ab87b4]
        public static let provider = configure()
        // parity: ai/src/providers/digitalocean.ts#decision [status=implemented hash=e92859a494dc]
        public static func decision(_ modelID: String, providerOptions: [String: JSONValue]? = nil) -> AIProtocols.MediaModelHandle {
            AIProtocols.MediaModelHandle(id: modelID, provider: id, protocolID: "system-one", baseURL: defaultBaseURL, path: AIProtocols.SystemOneProtocol.DEFAULT_PATH, mode: .inline, providerOptions: providerOptions)
        }
        // parity: ai/src/providers/digitalocean.ts#embedding [status=implemented hash=8c37d296d564]
        public static func embedding(_ modelID: String, providerOptions: [String: JSONValue]? = nil) -> AIProtocols.MediaModelHandle {
            AIProtocols.MediaModelHandle(id: modelID, provider: id, protocolID: "openai-embeddings", baseURL: defaultBaseURL, path: AIProtocols.OpenAIEmbeddings.PATH, mode: .inline, providerOptions: providerOptions)
        }
        // parity: ai/src/providers/digitalocean.ts#image [status=implemented hash=25839c138732]
        public static func image(_ modelID: String, providerOptions: [String: JSONValue]? = nil) -> AIProtocols.MediaModelHandle {
            AIProtocols.OpenAIImages.model(.init(id: modelID, provider: id, baseURL: defaultBaseURL, providerOptions: providerOptions))
        }
        // parity: ai/src/providers/digitalocean.ts#chat [status=implemented hash=c527949cbec3]
        public static func chat(_ modelID: String) -> ConfiguredModel { provider.model(modelID, route: route) }
        // parity: ai/src/providers/digitalocean.ts#responses [status=implemented hash=8ec09f32a8ac]
        public static func responses(_ modelID: String) -> ConfiguredModel { provider.model(modelID, route: responsesRoute) }
        // parity: ai/src/providers/digitalocean.ts#model [status=implemented hash=61635358c550]
        public static func model(_ modelID: String, settings: Settings = Settings()) -> ConfiguredModel { configure(settings).model(modelID, route: route) }
        // parity: ai/src/providers/digitalocean.ts#responsesModel [status=implemented hash=cfab73c14f1e]
        public static func responsesModel(_ modelID: String, settings: Settings = Settings()) -> ConfiguredModel { configure(settings).model(modelID, route: responsesRoute) }
        // parity: ai/src/providers/digitalocean.ts#imageModel [status=implemented hash=2f7c46a66434]
        public static func imageModel(_ modelID: String, settings: Settings = Settings()) -> AIProtocols.MediaModelHandle {
            AIProtocols.OpenAIImages.model(.init(id: modelID, provider: id, baseURL: settings.baseURL ?? defaultBaseURL, providerOptions: settings.providerOptions))
        }
        // parity: ai/src/providers/digitalocean.ts#decisionModel [status=implemented hash=0d3ba148cd1b]
        public static func decisionModel(_ modelID: String, settings: Settings = Settings()) -> AIProtocols.MediaModelHandle {
            AIProtocols.MediaModelHandle(id: modelID, provider: id, protocolID: "system-one", baseURL: settings.baseURL ?? defaultBaseURL, path: AIProtocols.SystemOneProtocol.DEFAULT_PATH, mode: .inline, providerOptions: settings.providerOptions)
        }
        // parity: ai/src/providers/digitalocean.ts#embeddingModel [status=implemented hash=351167581585]
        public static func embeddingModel(_ modelID: String, settings: Settings = Settings()) -> AIProtocols.MediaModelHandle {
            AIProtocols.MediaModelHandle(id: modelID, provider: id, protocolID: "openai-embeddings", baseURL: settings.baseURL ?? defaultBaseURL, path: AIProtocols.OpenAIEmbeddings.PATH, mode: .inline, providerOptions: settings.providerOptions)
        }

        public enum Responses {
            // parity: ai/src/providers/digitalocean/responses.ts#Settings [status=implemented hash=c49de2cc6dca]
            public typealias Settings = ProviderConfig
        }
    }

    // MARK: - 15. ElevenLabs & Fireworks (15 symbols)

    public enum ElevenLabs {
        // parity: ai/src/providers/elevenlabs.ts#id [status=implemented hash=91acb1311676]
        public static let id = "elevenlabs"
        // parity: ai/src/providers/elevenlabs.ts#Config [status=implemented hash=e2282dcfffaf]
        public typealias Config = ProviderConfig
        // parity: ai/src/providers/elevenlabs.ts#configure [status=implemented hash=6ef9eff864c2]
        public static func configure(_ input: Config = Config(), environment: any EnvironmentProviding = SystemEnvironment.shared) -> ConfiguredProvider {
            ConfiguredProvider(id: id, baseURL: input.baseURL ?? AIProtocols.ElevenLabsSpeech.DEFAULT_BASE_URL, auth: resolveHeaderAuth(config: input, envVars: ["ELEVENLABS_API_KEY"], headerName: "xi-api-key", environment: environment), headers: input.headers ?? [:])
        }
        // parity: ai/src/providers/elevenlabs.ts#provider [status=implemented hash=370740ab87b4]
        public static let provider = configure()
        // parity: ai/src/providers/elevenlabs.ts#speech [status=implemented hash=5cc6042ca4db]
        public static func speech(_ modelID: String, config: Config = Config()) -> AIProtocols.MediaModelHandle {
            AIProtocols.ElevenLabsSpeech.model(.init(id: modelID, provider: id, baseURL: config.baseURL, providerOptions: config.providerOptions))
        }
        // parity: ai/src/providers/elevenlabs.ts#transcription [status=implemented hash=287f8a2250f5]
        public static func transcription(_ modelID: String, config: Config = Config()) -> AIProtocols.MediaModelHandle {
            AIProtocols.ElevenLabsTranscription.model(.init(id: modelID, provider: id, baseURL: config.baseURL, providerOptions: config.providerOptions))
        }
    }

    public enum Fireworks {
        public static let defaultBaseURL = "https://api.fireworks.ai/inference/v1"
        // parity: ai/src/providers/fireworks.ts#id [status=implemented hash=4638003374f2]
        public static let id = "fireworks"
        // parity: ai/src/providers/fireworks.ts#Config [status=implemented hash=3f41ed19d775]
        public typealias Config = ProviderConfig
        // parity: ai/src/providers/fireworks.ts#Settings [status=implemented hash=8b7d78d33938]
        public typealias Settings = ProviderConfig
        // parity: ai/src/providers/fireworks.ts#route [status=implemented hash=d1cf434d86f0]
        public static let route = AIProtocols.OpenAIChat.route.with(id: id, provider: id, providerMetadataKey: id, baseURL: defaultBaseURL)
        // parity: ai/src/providers/fireworks.ts#routes [status=implemented hash=d8efbd745746]
        public static let routes: [AIProtocols.ChatRouteSpec] = [route]
        // parity: ai/src/providers/fireworks.ts#configure [status=implemented hash=6ef9eff864c2]
        public static func configure(_ input: Config = Config(), environment: any EnvironmentProviding = SystemEnvironment.shared) -> ConfiguredProvider {
            ConfiguredProvider(id: id, baseURL: input.baseURL ?? defaultBaseURL, auth: resolveBearerAuth(config: input, envVars: ["FIREWORKS_API_KEY"], environment: environment), headers: input.headers ?? [:], routes: routes, defaultRoute: route, defaultProviderOptions: input.providerOptions ?? [:])
        }
        // parity: ai/src/providers/fireworks.ts#provider [status=implemented hash=370740ab87b4]
        public static let provider = configure()
        // parity: ai/src/providers/fireworks.ts#model [status=implemented hash=5cfdd0ca1b72]
        public static func model(_ modelID: String, settings: Settings = Settings()) -> ConfiguredModel { configure(settings).model(modelID) }
        // parity: ai/src/providers/fireworks.ts#embeddingModel [status=implemented hash=c6d9ffa465c5]
        public static func embeddingModel(_ modelID: String, settings: Settings = Settings()) -> AIProtocols.MediaModelHandle {
            AIProtocols.MediaModelHandle(id: modelID, provider: id, protocolID: "openai-embeddings", baseURL: settings.baseURL ?? defaultBaseURL, path: AIProtocols.OpenAIEmbeddings.PATH, mode: .inline, providerOptions: settings.providerOptions)
        }
    }

    // MARK: - 16. GoogleVertexShared (google-vertex-shared.ts — 11 symbols)

    public enum GoogleVertexShared {
        public static let providerID = "google-vertex"
        public static let cloudPlatformScope = "https://www.googleapis.com/auth/cloud-platform"

        public struct ADCClientDescriptor: Equatable, Hashable, Sendable {
            public let project: String?
            public let scope: String
            public init(project: String? = nil, scope: String = GoogleVertexShared.cloudPlatformScope) {
                self.project = project; self.scope = scope
            }
        }

        // parity: ai/src/providers/google-vertex-shared.ts#loadADCClient [status=adapted hash=71bcb4d3a66c]
        public static func loadADCClient(project: String? = nil) -> ADCClientDescriptor {
            ADCClientDescriptor(project: project, scope: cloudPlatformScope)
        }

        // parity: ai/src/providers/google-vertex-shared.ts#OAuthOptions [status=implemented hash=02dbee15b47b]
        public typealias OAuthOptions = ProviderConfig

        // parity: ai/src/providers/google-vertex-shared.ts#ApiKeyOptions [status=implemented hash=c7bed71fa23e]
        public typealias ApiKeyOptions = ProviderConfig

        // parity: ai/src/providers/google-vertex-shared.ts#project [status=implemented hash=24f1020dc0a8]
        public static func project(_ value: String? = nil, environment: any EnvironmentProviding = SystemEnvironment.shared) -> String? {
            value
                ?? environment.variable("GOOGLE_VERTEX_PROJECT")
                ?? environment.variable("GOOGLE_CLOUD_PROJECT")
                ?? environment.variable("GCP_PROJECT")
                ?? environment.variable("GCLOUD_PROJECT")
        }

        // parity: ai/src/providers/google-vertex-shared.ts#location [status=implemented hash=a852f58db4bf]
        public static func location(_ value: String? = nil, environment: any EnvironmentProviding = SystemEnvironment.shared) -> String {
            value
                ?? environment.variable("GOOGLE_VERTEX_LOCATION")
                ?? environment.variable("GOOGLE_CLOUD_LOCATION")
                ?? environment.variable("VERTEX_LOCATION")
                ?? "global"
        }

        // parity: ai/src/providers/google-vertex-shared.ts#host [status=implemented hash=e6a987445bf4]
        public static func host(_ location: String) -> String {
            if location == "global" { return "aiplatform.googleapis.com" }
            if location == "eu" || location == "us" { return "aiplatform.\(location).rep.googleapis.com" }
            return "\(location)-aiplatform.googleapis.com"
        }

        // parity: ai/src/providers/google-vertex-shared.ts#requireProject [status=implemented hash=4a1b231396fb]
        public static func requireProject(_ value: String?) throws(ProviderConfigurationError) -> String {
            guard let value, !value.isEmpty else {
                throw ProviderConfigurationError(provider: providerID, message: "Google Vertex requires a project when baseURL is not configured")
            }
            return value
        }

        // parity: ai/src/providers/google-vertex-shared.ts#apiKey [status=implemented hash=98a20d5cbc71]
        public static func apiKey(
            _ input: ApiKeyOptions,
            environment: any EnvironmentProviding = SystemEnvironment.shared
        ) throws(ProviderConfigurationError) -> String? {
            if case .explicit = input.apiKey, (input.accessToken != nil || input.auth != nil) {
                throw ProviderConfigurationError(provider: providerID, message: "Google Vertex apiKey cannot be combined with accessToken or auth")
            }
            if input.accessToken != nil || input.auth != nil { return nil }
            if case .explicit(let k) = input.apiKey { return k }
            if case .disabled = input.apiKey { return nil }
            if input.project != nil || input.location != nil { return nil }
            return environment.variable("GOOGLE_VERTEX_API_KEY")
        }

        // parity: ai/src/providers/google-vertex-shared.ts#oauth [status=implemented hash=46356a8a3ae0]
        public static func oauth(_ input: OAuthOptions, project: String? = nil) throws(ProviderConfigurationError) -> AIProtocolUtils.AuthStrategy {
            if input.accessToken != nil && input.auth != nil {
                throw ProviderConfigurationError(provider: providerID, message: "Google Vertex accessToken cannot be combined with auth")
            }
            if let auth = input.auth { return auth }
            if let token = input.accessToken { return .bearer(token) }
            _ = loadADCClient(project: project)
            return .none
        }

        // parity: ai/src/providers/google-vertex-shared.ts#oauthRoute [status=implemented hash=3a1a8031c3c3]
        public static func oauthRoute(
            _ route: AIProtocols.ChatRouteSpec,
            label: String,
            input: OAuthOptions,
            environment: any EnvironmentProviding = SystemEnvironment.shared,
            url: (String, String) -> String
        ) throws(ProviderConfigurationError) -> AIProtocols.ChatRouteSpec {
            if case .explicit = input.apiKey {
                throw ProviderConfigurationError(provider: providerID, message: "Google Vertex \(label) does not support API keys")
            }
            let loc = location(input.location, environment: environment)
            let proj = project(input.project, environment: environment)
            let resolvedBase: String
            if let explicit = input.baseURL {
                resolvedBase = explicit
            } else {
                resolvedBase = url(try requireProject(proj), loc)
            }
            let auth = try oauth(input, project: proj)
            return route.with(baseURL: resolvedBase, headers: input.headers, providerOptions: input.providerOptions, auth: auth)
        }

        // parity: ai/src/providers/google-vertex-shared.ts#oauthSettings [status=implemented hash=6793bff7e15e]
        public static func oauthSettings(label: String, input: ProviderConfig) throws(ProviderConfigurationError) -> ProviderConfig {
            if case .explicit = input.apiKey {
                throw ProviderConfigurationError(provider: providerID, message: "Google Vertex \(label) does not support API keys")
            }
            return input
        }
    }

    // MARK: - 17. GoogleVertex* Providers (49 symbols)

    public enum GoogleVertexChat {
        // parity: ai/src/providers/google-vertex-chat.ts#id [status=implemented hash=d3a46760c761]
        public static let id = "google-vertex"
        // parity: ai/src/providers/google-vertex-chat.ts#Config [status=implemented hash=8ad10171cc9c]
        public typealias Config = ProviderConfig
        // parity: ai/src/providers/google-vertex-chat.ts#Settings [status=implemented hash=b71b0371b10d]
        public typealias Settings = ProviderConfig
        public static let baseRoute = AIProtocols.OpenAIChat.route.with(id: "google-vertex-chat", provider: id, providerMetadataKey: "vertex")
        // parity: ai/src/providers/google-vertex-chat.ts#routes [status=implemented hash=d8efbd745746]
        public static let routes: [AIProtocols.ChatRouteSpec] = [baseRoute]
        // parity: ai/src/providers/google-vertex-chat.ts#configure [status=implemented hash=6ef9eff864c2]
        public static func configure(_ input: Config, environment: any EnvironmentProviding = SystemEnvironment.shared) throws(ProviderConfigurationError) -> ConfiguredProvider {
            let r = try GoogleVertexShared.oauthRoute(baseRoute, label: "Chat", input: input, environment: environment) { proj, loc in
                "https://\(GoogleVertexShared.host(loc))/v1/projects/\(proj)/locations/\(loc)/endpoints/openapi"
            }
            return ConfiguredProvider(id: id, baseURL: r.defaultBaseURL, auth: r.auth, headers: r.defaultHeaders, routes: [r], defaultRoute: r, defaultProviderOptions: r.defaultProviderOptions)
        }
        // parity: ai/src/providers/google-vertex-chat.ts#provider [status=implemented hash=ce1b6df0aba2]
        public static let provider = (id: id, routes: routes)
        // parity: ai/src/providers/google-vertex-chat.ts#model [status=implemented hash=007b17b1024f]
        public static func model(_ modelID: String, settings: Settings) throws(ProviderConfigurationError) -> ConfiguredModel {
            try configure(GoogleVertexShared.oauthSettings(label: "Chat", input: settings)).model(modelID)
        }
    }

    public enum GoogleVertexInteractions {
        // parity: ai/src/providers/google-vertex-interactions.ts#GoogleInteractionsOptionsInput [status=implemented hash=82744cb45cea]
        public typealias GoogleInteractionsOptionsInput = AIProtocols.GoogleInteractions.OptionsInput
        // parity: ai/src/providers/google-vertex-interactions.ts#id [status=implemented hash=d3a46760c761]
        public static let id = "google-vertex"
        // parity: ai/src/providers/google-vertex-interactions.ts#Config [status=implemented hash=33efcd262af0]
        public typealias Config = ProviderConfig
        // parity: ai/src/providers/google-vertex-interactions.ts#Settings [status=implemented hash=2eec63a61d0e]
        public typealias Settings = ProviderConfig
        public static let baseRoute = AIProtocols.GoogleInteractions.route.with(id: "google-vertex-interactions", provider: id, providerMetadataKey: "vertex")
        // parity: ai/src/providers/google-vertex-interactions.ts#routes [status=implemented hash=d8efbd745746]
        public static let routes: [AIProtocols.ChatRouteSpec] = [baseRoute]
        // parity: ai/src/providers/google-vertex-interactions.ts#configure [status=implemented hash=6ef9eff864c2]
        public static func configure(_ input: Config, environment: any EnvironmentProviding = SystemEnvironment.shared) throws(ProviderConfigurationError) -> ConfiguredProvider {
            let loc = GoogleVertexShared.location(input.location, environment: environment)
            let proj = GoogleVertexShared.project(input.project, environment: environment)
            let key = try GoogleVertexShared.apiKey(input, environment: environment)
            let resolvedBase: String
            if let explicit = input.baseURL {
                resolvedBase = explicit
            } else {
                let requiredProj = try GoogleVertexShared.requireProject(proj)
                resolvedBase = "https://\(GoogleVertexShared.host(loc))/v1beta1/projects/\(requiredProj)/locations/\(loc)"
            }
            let auth: AIProtocolUtils.AuthStrategy
            if let key {
                auth = .header(name: "x-goog-api-key", value: key)
            } else {
                auth = try GoogleVertexShared.oauth(input, project: proj)
            }
            return ConfiguredProvider(id: id, baseURL: resolvedBase, auth: auth, headers: input.headers ?? [:], routes: routes, defaultRoute: baseRoute, defaultProviderOptions: input.providerOptions ?? [:])
        }
        // parity: ai/src/providers/google-vertex-interactions.ts#provider [status=implemented hash=ce1b6df0aba2]
        public static let provider = (id: id, routes: routes)
        // parity: ai/src/providers/google-vertex-interactions.ts#model [status=implemented hash=d592028f4245]
        public static func model(_ modelID: String, settings: Settings) throws(ProviderConfigurationError) -> ConfiguredModel {
            try configure(settings).model(modelID)
        }
    }

    public enum GoogleVertexMessages {
        // parity: ai/src/providers/google-vertex-messages.ts#AnthropicOptionsInput [status=implemented hash=2f120bdfee9d]
        public typealias AnthropicOptionsInput = AIProtocols.AnthropicMessages.OptionsInput
        // parity: ai/src/providers/google-vertex-messages.ts#AnthropicProviderOptionsInput [status=implemented hash=44d671cc6dd1]
        public typealias AnthropicProviderOptionsInput = AIProtocols.AnthropicMessages.ProviderOptionsInput
        // parity: ai/src/providers/google-vertex-messages.ts#AnthropicThinkingInput [status=implemented hash=f283bf4aedd3]
        public typealias AnthropicThinkingInput = AIProtocols.AnthropicMessages.ThinkingInput
        // parity: ai/src/providers/google-vertex-messages.ts#id [status=implemented hash=d3a46760c761]
        public static let id = "google-vertex"
        // parity: ai/src/providers/google-vertex-messages.ts#Config [status=implemented hash=72a444454910]
        public typealias Config = ProviderConfig
        // parity: ai/src/providers/google-vertex-messages.ts#Settings [status=implemented hash=4d55eae20c18]
        public typealias Settings = ProviderConfig
        public static let baseRoute = AIProtocols.ChatRouteSpec(
            id: "google-vertex-messages", provider: id, providerMetadataKey: "vertex",
            protocol: AIProtocols.AnthropicMessages.`protocol`,
            pathBuilder: { req, _ in "/models/\(req.model.id):streamRawPredict" },
            defaultHeaders: ["anthropic-version": "vertex-2023-10-16"]
        )
        // parity: ai/src/providers/google-vertex-messages.ts#routes [status=implemented hash=d8efbd745746]
        public static let routes: [AIProtocols.ChatRouteSpec] = [baseRoute]
        // parity: ai/src/providers/google-vertex-messages.ts#configure [status=implemented hash=6ef9eff864c2]
        public static func configure(_ input: Config, environment: any EnvironmentProviding = SystemEnvironment.shared) throws(ProviderConfigurationError) -> ConfiguredProvider {
            let r = try GoogleVertexShared.oauthRoute(baseRoute, label: "Messages", input: input, environment: environment) { proj, loc in
                "https://\(GoogleVertexShared.host(loc))/v1/projects/\(proj)/locations/\(loc)/publishers/anthropic"
            }
            return ConfiguredProvider(id: id, baseURL: r.defaultBaseURL, auth: r.auth, headers: r.defaultHeaders, routes: [r], defaultRoute: r, defaultProviderOptions: r.defaultProviderOptions)
        }
        // parity: ai/src/providers/google-vertex-messages.ts#provider [status=implemented hash=ce1b6df0aba2]
        public static let provider = (id: id, routes: routes)
        // parity: ai/src/providers/google-vertex-messages.ts#model [status=implemented hash=65dadc988ed3]
        public static func model(_ modelID: String, settings: Settings) throws(ProviderConfigurationError) -> ConfiguredModel {
            try configure(GoogleVertexShared.oauthSettings(label: "Messages", input: settings)).model(modelID)
        }
    }

    public enum GoogleVertexMistral {
        // parity: ai/src/providers/google-vertex-mistral.ts#id [status=implemented hash=d3a46760c761]
        public static let id = "google-vertex"
        // parity: ai/src/providers/google-vertex-mistral.ts#Config [status=implemented hash=a7bfa7b07c4e]
        public typealias Config = ProviderConfig
        // parity: ai/src/providers/google-vertex-mistral.ts#Settings [status=implemented hash=cc76c8cd00fb]
        public typealias Settings = ProviderConfig
        public static let baseRoute = AIProtocols.ChatRouteSpec(
            id: "google-vertex-mistral", provider: id, providerMetadataKey: "vertex",
            protocol: AIProtocols.MistralChat.`protocol`,
            pathBuilder: { req, _ in "/models/\(req.model.id):streamRawPredict" }
        )
        // parity: ai/src/providers/google-vertex-mistral.ts#routes [status=implemented hash=d8efbd745746]
        public static let routes: [AIProtocols.ChatRouteSpec] = [baseRoute]
        // parity: ai/src/providers/google-vertex-mistral.ts#configure [status=implemented hash=6ef9eff864c2]
        public static func configure(_ input: Config, environment: any EnvironmentProviding = SystemEnvironment.shared) throws(ProviderConfigurationError) -> ConfiguredProvider {
            let r = try GoogleVertexShared.oauthRoute(baseRoute, label: "Mistral", input: input, environment: environment) { proj, loc in
                "https://\(GoogleVertexShared.host(loc))/v1/projects/\(proj)/locations/\(loc)/publishers/mistralai"
            }
            return ConfiguredProvider(id: id, baseURL: r.defaultBaseURL, auth: r.auth, headers: r.defaultHeaders, routes: [r], defaultRoute: r, defaultProviderOptions: r.defaultProviderOptions)
        }
        // parity: ai/src/providers/google-vertex-mistral.ts#provider [status=implemented hash=ce1b6df0aba2]
        public static let provider = (id: id, routes: routes)
        // parity: ai/src/providers/google-vertex-mistral.ts#model [status=implemented hash=9a843ebbbba7]
        public static func model(_ modelID: String, settings: Settings) throws(ProviderConfigurationError) -> ConfiguredModel {
            try configure(GoogleVertexShared.oauthSettings(label: "Mistral", input: settings)).model(modelID)
        }
    }

    public enum GoogleVertexResponses {
        // parity: ai/src/providers/google-vertex-responses.ts#id [status=implemented hash=d3a46760c761]
        public static let id = "google-vertex"
        // parity: ai/src/providers/google-vertex-responses.ts#Config [status=implemented hash=09b83eda61e0]
        public typealias Config = ProviderConfig
        // parity: ai/src/providers/google-vertex-responses.ts#Settings [status=implemented hash=3439ffee012a]
        public typealias Settings = ProviderConfig
        public static let baseRoute = AIProtocols.OpenResponses.`protocol`
        public static let chatRoute = AIProtocols.ChatRouteSpec(
            id: "google-vertex-responses", provider: id, providerMetadataKey: "vertex",
            protocol: baseRoute, path: AIProtocols.OpenResponses.PATH,
            defaultProviderOptions: ["store": .bool(false), "include": .array([.string("reasoning.encrypted_content")])]
        )
        // parity: ai/src/providers/google-vertex-responses.ts#routes [status=implemented hash=d8efbd745746]
        public static let routes: [AIProtocols.ChatRouteSpec] = [chatRoute]
        // parity: ai/src/providers/google-vertex-responses.ts#configure [status=implemented hash=6ef9eff864c2]
        public static func configure(_ input: Config, environment: any EnvironmentProviding = SystemEnvironment.shared) throws(ProviderConfigurationError) -> ConfiguredProvider {
            let r = try GoogleVertexShared.oauthRoute(chatRoute, label: "Responses", input: input, environment: environment) { proj, loc in
                "https://\(GoogleVertexShared.host(loc))/v1/projects/\(proj)/locations/\(loc)/endpoints/openapi"
            }
            return ConfiguredProvider(id: id, baseURL: r.defaultBaseURL, auth: r.auth, headers: r.defaultHeaders, routes: [r], defaultRoute: r, defaultProviderOptions: r.defaultProviderOptions)
        }
        // parity: ai/src/providers/google-vertex-responses.ts#provider [status=implemented hash=ce1b6df0aba2]
        public static let provider = (id: id, routes: routes)
        // parity: ai/src/providers/google-vertex-responses.ts#model [status=implemented hash=3aedd1e5039e]
        public static func model(_ modelID: String, settings: Settings) throws(ProviderConfigurationError) -> ConfiguredModel {
            try configure(GoogleVertexShared.oauthSettings(label: "Responses", input: settings)).model(modelID)
        }
    }

    public enum GoogleVertex {
        // parity: ai/src/providers/google-vertex.ts#GeminiOptionsInput [status=implemented hash=3ef369ca1fd5]
        public struct GeminiOptionsInput: Equatable, Hashable, Sendable {
            public var base: AIProtocols.Gemini.OptionsInput
            public var labels: [String: String]?
            public init(base: AIProtocols.Gemini.OptionsInput = .init(), labels: [String: String]? = nil) {
                self.base = base; self.labels = labels
            }
        }
        // parity: ai/src/providers/google-vertex.ts#GeminiProviderOptionsInput [status=implemented hash=b09f8bb3b66e]
        public typealias GeminiProviderOptionsInput = GeminiOptionsInput
        // parity: ai/src/providers/google-vertex.ts#id [status=implemented hash=d3a46760c761]
        public static let id = "google-vertex"
        // parity: ai/src/providers/google-vertex.ts#Config [status=implemented hash=db719439f004]
        public typealias Config = ProviderConfig
        // parity: ai/src/providers/google-vertex.ts#Settings [status=implemented hash=5bb27d1801cc]
        public typealias Settings = ProviderConfig

        public static let vertexGeminiRoute = AIProtocols.ChatRouteSpec(
            id: "google-vertex-gemini", provider: id, providerMetadataKey: "vertex",
            protocol: AIProtocols.Gemini.`protocol`,
            pathBuilder: { req, _ in
                let m = req.model.id
                return "/\(m.hasPrefix("endpoints/") ? m : "models/\(m)"):streamGenerateContent?alt=sse"
            }
        )
        // parity: ai/src/providers/google-vertex.ts#routes [status=implemented hash=d8efbd745746]
        public static let routes: [AIProtocols.ChatRouteSpec] = [vertexGeminiRoute]

        // parity: ai/src/providers/google-vertex.ts#configure [status=implemented hash=6ef9eff864c2]
        public static func configure(_ input: Config = Config(), environment: any EnvironmentProviding = SystemEnvironment.shared) throws(ProviderConfigurationError) -> ConfiguredProvider {
            let key = try GoogleVertexShared.apiKey(input, environment: environment)
            let base: String
            let auth: AIProtocolUtils.AuthStrategy
            if let key {
                base = input.baseURL ?? "https://aiplatform.googleapis.com/v1/publishers/google"
                auth = .header(name: "x-goog-api-key", value: key)
            } else {
                let loc = GoogleVertexShared.location(input.location, environment: environment)
                let proj = GoogleVertexShared.project(input.project, environment: environment)
                if let explicit = input.baseURL {
                    base = explicit
                } else {
                    let requiredProj = try GoogleVertexShared.requireProject(proj)
                    base = "https://\(GoogleVertexShared.host(loc))/v1/projects/\(requiredProj)/locations/\(loc)/publishers/google"
                }
                auth = try GoogleVertexShared.oauth(input, project: proj)
            }
            return ConfiguredProvider(id: id, baseURL: base, auth: auth, headers: input.headers ?? [:], routes: routes, defaultRoute: vertexGeminiRoute, defaultProviderOptions: input.providerOptions ?? [:])
        }

        // parity: ai/src/providers/google-vertex.ts#provider [status=implemented hash=ce1b6df0aba2]
        public static let provider = (id: id, routes: routes)

        // parity: ai/src/providers/google-vertex.ts#model [status=implemented hash=3a995cf9de1b]
        public static func model(_ modelID: String, settings: Settings = Settings()) throws(ProviderConfigurationError) -> ConfiguredModel {
            try configure(settings).model(modelID)
        }

        // parity: ai/src/providers/google-vertex.ts#imageModel [status=implemented hash=2f7c46a66434]
        public static func imageModel(_ modelID: String, settings: Settings = Settings()) throws(ProviderConfigurationError) -> AIProtocols.MediaModelHandle {
            let prov = try configure(settings)
            return AIProtocols.GoogleImages.model(.init(id: modelID, provider: id, baseURL: prov.baseURL, providerOptions: settings.providerOptions))
        }

        // parity: ai/src/providers/google-vertex.ts#embeddingModel [status=implemented hash=351167581585]
        public static func embeddingModel(_ modelID: String, settings: Settings = Settings()) throws(ProviderConfigurationError) -> AIProtocols.MediaModelHandle {
            let prov = try configure(settings)
            let usesEmbedContent = modelID.lowercased().hasPrefix("gemini-embedding-2")
            return AIProtocols.MediaModelHandle(
                id: modelID,
                provider: id,
                protocolID: usesEmbedContent ? "google-vertex-embed-content" : "google-vertex-predict-embeddings",
                baseURL: prov.baseURL,
                path: usesEmbedContent ? "/models/\(modelID):embedContent" : "/\(modelID.hasPrefix("endpoints/") ? modelID : "models/\(modelID)"):predict",
                mode: .inline,
                providerOptions: settings.providerOptions
            )
        }
    }
}
