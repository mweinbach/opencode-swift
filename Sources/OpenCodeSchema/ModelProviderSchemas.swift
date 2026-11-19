/// Pure Swift 6.2 model, provider, agent, credential, connection, and generation schemas.
/// Ports `packages/schema/src/{model-compatibility,model,provider,agent,credential,credential-legacy,connection,generate}.ts`.
/// 100% pure Swift standard library (zero OS imports, zero Foundation imports).

// MARK: - src/model-compatibility.ts

public enum ModelCompatibilitySchema {
    /// Open-ended reasoning field name (`reasoning`, `reasoning_content`, `reasoning_text`, or custom string).
    // parity: schema/src/model-compatibility.ts#ReasoningField [status=implemented hash=838dae69b58d]
    public struct ReasoningField: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public static let reasoning = ReasoningField(rawValue: "reasoning")
        public static let reasoningContent = ReasoningField(rawValue: "reasoning_content")
        public static let reasoningText = ReasoningField(rawValue: "reasoning_text")

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public var description: String { rawValue }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.rawValue = try container.decode(String.self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    // parity: schema/src/model-compatibility.ts#MaxTokensField [status=implemented hash=ba672e40bdd1]
    public enum MaxTokensField: String, Equatable, Hashable, Sendable, Codable {
        case maxCompletionTokens = "max_completion_tokens"
        case maxTokens = "max_tokens"
    }

    // parity: schema/src/model-compatibility.ts#MediaInput [status=implemented hash=0162e8008d56]
    public enum MediaInput: String, Equatable, Hashable, Sendable, Codable {
        case assets
        case state
        case root
    }

    // parity: schema/src/model-compatibility.ts#CacheFormat [status=implemented hash=217fe26e1403]
    public enum CacheFormat: String, Equatable, Hashable, Sendable, Codable {
        case anthropic
        case alibaba
    }

    // parity: schema/src/model-compatibility.ts#Compatibility [status=implemented hash=7ed9c66aae33]
    public struct Compatibility: Equatable, Hashable, Sendable, Codable {
        public let reasoningField: ReasoningField?
        public let requireReasoning: Bool?
        public let maxTokensField: MaxTokensField?
        public let requireFinishReason: Bool?
        public let requireAssistantAfterTool: Bool?
        public let supportsPromptCacheKey: Bool?
        public let streamUsage: Bool?
        public let cacheFormat: CacheFormat?
        public let supportsThinkingBlockBinding: Bool?
        public let supportsEffortUpdates: Bool?
        public let mediaInput: MediaInput?

        public init(
            reasoningField: ReasoningField? = nil,
            requireReasoning: Bool? = nil,
            maxTokensField: MaxTokensField? = nil,
            requireFinishReason: Bool? = nil,
            requireAssistantAfterTool: Bool? = nil,
            supportsPromptCacheKey: Bool? = nil,
            streamUsage: Bool? = nil,
            cacheFormat: CacheFormat? = nil,
            supportsThinkingBlockBinding: Bool? = nil,
            supportsEffortUpdates: Bool? = nil,
            mediaInput: MediaInput? = nil
        ) {
            self.reasoningField = reasoningField
            self.requireReasoning = requireReasoning
            self.maxTokensField = maxTokensField
            self.requireFinishReason = requireFinishReason
            self.requireAssistantAfterTool = requireAssistantAfterTool
            self.supportsPromptCacheKey = supportsPromptCacheKey
            self.streamUsage = streamUsage
            self.cacheFormat = cacheFormat
            self.supportsThinkingBlockBinding = supportsThinkingBlockBinding
            self.supportsEffortUpdates = supportsEffortUpdates
            self.mediaInput = mediaInput
        }
    }

    /// Provider-level compatibility defaults inherited by its models (excludes model-version-only flags).
    // parity: schema/src/model-compatibility.ts#ProviderCompatibility [status=implemented hash=eaa522021ab6]
    public struct ProviderCompatibility: Equatable, Hashable, Sendable, Codable {
        public let reasoningField: ReasoningField?
        public let requireReasoning: Bool?
        public let maxTokensField: MaxTokensField?
        public let requireFinishReason: Bool?
        public let requireAssistantAfterTool: Bool?
        public let supportsPromptCacheKey: Bool?
        public let streamUsage: Bool?
        public let cacheFormat: CacheFormat?
        public let mediaInput: MediaInput?

        public init(
            reasoningField: ReasoningField? = nil,
            requireReasoning: Bool? = nil,
            maxTokensField: MaxTokensField? = nil,
            requireFinishReason: Bool? = nil,
            requireAssistantAfterTool: Bool? = nil,
            supportsPromptCacheKey: Bool? = nil,
            streamUsage: Bool? = nil,
            cacheFormat: CacheFormat? = nil,
            mediaInput: MediaInput? = nil
        ) {
            self.reasoningField = reasoningField
            self.requireReasoning = requireReasoning
            self.maxTokensField = maxTokensField
            self.requireFinishReason = requireFinishReason
            self.requireAssistantAfterTool = requireAssistantAfterTool
            self.supportsPromptCacheKey = supportsPromptCacheKey
            self.streamUsage = streamUsage
            self.cacheFormat = cacheFormat
            self.mediaInput = mediaInput
        }
    }

    /// Resolves effective model compatibility by overlaying model overrides onto provider defaults.
    public static func resolve(
        model: Compatibility?,
        provider: ProviderCompatibility?
    ) -> Compatibility {
        Compatibility(
            reasoningField: model?.reasoningField ?? provider?.reasoningField,
            requireReasoning: model?.requireReasoning ?? provider?.requireReasoning,
            maxTokensField: model?.maxTokensField ?? provider?.maxTokensField,
            requireFinishReason: model?.requireFinishReason ?? provider?.requireFinishReason,
            requireAssistantAfterTool: model?.requireAssistantAfterTool ?? provider?.requireAssistantAfterTool,
            supportsPromptCacheKey: model?.supportsPromptCacheKey ?? provider?.supportsPromptCacheKey,
            streamUsage: model?.streamUsage ?? provider?.streamUsage,
            cacheFormat: model?.cacheFormat ?? provider?.cacheFormat,
            supportsThinkingBlockBinding: model?.supportsThinkingBlockBinding,
            supportsEffortUpdates: model?.supportsEffortUpdates,
            mediaInput: model?.mediaInput ?? provider?.mediaInput
        )
    }
}

// MARK: - src/provider.ts

public enum ProviderSchema {
    // parity: schema/src/provider.ts#ID [status=implemented hash=65f097b352c0]
    public struct ID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public static let opencode = ID(rawValue: "opencode")
        public static let anthropic = ID(rawValue: "anthropic")
        public static let openai = ID(rawValue: "openai")
        public static let google = ID(rawValue: "google")
        public static let googleVertex = ID(rawValue: "google-vertex")
        public static let githubCopilot = ID(rawValue: "github-copilot")
        public static let claudeAgent = ID(rawValue: "claude-agent")
        public static let amazonBedrock = ID(rawValue: "amazon-bedrock")
        public static let azure = ID(rawValue: "azure")
        public static let openrouter = ID(rawValue: "openrouter")
        public static let mistral = ID(rawValue: "mistral")
        public static let gitlab = ID(rawValue: "gitlab")

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public var description: String { rawValue }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.rawValue = try container.decode(String.self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    // parity: schema/src/provider.ts#Event [status=implemented hash=e7550d251b3a]
    public enum Event {
        public static let updated = SchemaPrimitive.EventDescriptor.ephemeral(type: "provider.updated")
        public static let definitions: [SchemaPrimitive.EventDescriptor] = [updated]
    }

    // parity: schema/src/provider.ts#Package [status=implemented hash=688f9a003e14]
    public typealias Package = String

    // parity: schema/src/provider.ts#Activation [status=implemented hash=ca00b571bcd7]
    public enum Activation: String, Equatable, Hashable, Sendable, Codable {
        case auto
        case enabled
        case disabled
    }

    // parity: schema/src/provider.ts#Compaction [status=implemented hash=4a259649e3da]
    public enum Compaction: Equatable, Hashable, Sendable, Codable {
        case summary
        case native

        enum CodingKeys: String, CodingKey {
            case type
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "summary":
                self = .summary
            case "native":
                self = .native
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown Provider.Compaction type '\(type)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .summary:
                try container.encode("summary", forKey: .type)
            case .native:
                try container.encode("native", forKey: .type)
            }
        }
    }

    // parity: schema/src/provider.ts#Transport [status=implemented hash=6c5f0c9249f6]
    public enum Transport: String, Equatable, Hashable, Sendable, Codable {
        case http
        case websocket
    }

    /// Prompt-cache lifetime matching `^\d+(ms|s|m|h|d)$`.
    // parity: schema/src/provider.ts#CacheTTL [status=implemented hash=b691d05dc8e0]
    public struct CacheTTL: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public init?(rawValue: String) {
            guard SchemaPrimitive.isCacheTTL(rawValue) else { return nil }
            self.rawValue = rawValue
        }

        public init(validating value: String) throws(SchemaPrimitive.ValidationError) {
            guard SchemaPrimitive.isCacheTTL(value) else {
                throw .invalidFormat(expected: "^\\d+(ms|s|m|h|d)$", actual: value)
            }
            self.rawValue = value
        }

        public var description: String { rawValue }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard SchemaPrimitive.isCacheTTL(value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid CacheTTL '\(value)'"
                )
            }
            self.rawValue = value
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    public struct CacheWarmingConfig: Equatable, Hashable, Sendable, Codable {
        public let interval: String?
        public let duration: String?

        public init(interval: String? = nil, duration: String? = nil) {
            self.interval = interval
            self.duration = duration
        }
    }

    // parity: schema/src/provider.ts#CacheWarming [status=implemented hash=d84c2e8e2902]
    public enum CacheWarming: Equatable, Hashable, Sendable, Codable {
        case enabled(Bool)
        case configured(CacheWarmingConfig)

        public init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let flag = try? single.decode(Bool.self) {
                self = .enabled(flag)
            } else {
                self = .configured(try single.decode(CacheWarmingConfig.self))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var single = encoder.singleValueContainer()
            switch self {
            case .enabled(let flag):
                try single.encode(flag)
            case .configured(let cfg):
                try single.encode(cfg)
            }
        }
    }

    // parity: schema/src/provider.ts#Cache [status=implemented hash=1f97b3b0aa77]
    public struct Cache: Equatable, Hashable, Sendable, Codable {
        public let ttl: CacheTTL?
        public let warming: CacheWarming?

        public init(ttl: CacheTTL? = nil, warming: CacheWarming? = nil) {
            self.ttl = ttl
            self.warming = warming
        }
    }

    // parity: schema/src/provider.ts#Encoding [status=implemented hash=d87b33b9340a]
    public enum Encoding: String, Equatable, Hashable, Sendable, Codable {
        case zstd
        case gzip
        case none
    }

    public enum TimeoutOption: Equatable, Hashable, Sendable, Codable {
        case milliseconds(Double)
        case disabled

        public init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let flag = try? single.decode(Bool.self) {
                guard flag == false else {
                    throw DecodingError.dataCorruptedError(
                        in: single,
                        debugDescription: "Expected finite number or false for timeout, got true"
                    )
                }
                self = .disabled
                return
            }
            let ms = try single.decode(Double.self)
            guard ms.isFinite else {
                throw DecodingError.dataCorruptedError(
                    in: single,
                    debugDescription: "Expected finite timeout milliseconds"
                )
            }
            self = .milliseconds(ms)
        }

        public func encode(to encoder: Encoder) throws {
            var single = encoder.singleValueContainer()
            switch self {
            case .milliseconds(let ms):
                try single.encode(ms)
            case .disabled:
                try single.encode(false)
            }
        }
    }

    // parity: schema/src/provider.ts#Tls [status=implemented hash=aa8faca91581]
    public struct Tls: Equatable, Hashable, Sendable, Codable {
        public let cert: String
        public let key: String
        public let passphrase: String?

        public init(cert: String, key: String, passphrase: String? = nil) {
            self.cert = cert
            self.key = key
            self.passphrase = passphrase
        }
    }

    /// Flat `StructWithRest` provider settings preserving typed OpenCode keys alongside arbitrary provider options.
    // parity: schema/src/provider.ts#Settings [status=implemented hash=0d5d152897e0]
    public struct Settings: Equatable, Hashable, Sendable, Codable {
        public let timeout: TimeoutOption?
        public let headerTimeout: TimeoutOption?
        public let chunkTimeout: TimeoutOption?
        public let compaction: Compaction?
        public let cache: Cache?
        public let transport: Transport?
        public let encoding: Encoding?
        public let tls: Tls?
        public let extra: [String: JSONValue]

        public init(
            timeout: TimeoutOption? = nil,
            headerTimeout: TimeoutOption? = nil,
            chunkTimeout: TimeoutOption? = nil,
            compaction: Compaction? = nil,
            cache: Cache? = nil,
            transport: Transport? = nil,
            encoding: Encoding? = nil,
            tls: Tls? = nil,
            extra: [String: JSONValue] = [:]
        ) {
            self.timeout = timeout
            self.headerTimeout = headerTimeout
            self.chunkTimeout = chunkTimeout
            self.compaction = compaction
            self.cache = cache
            self.transport = transport
            self.encoding = encoding
            self.tls = tls
            self.extra = extra
        }

        private static let knownKeys: Set<String> = [
            "timeout", "headerTimeout", "chunkTimeout", "compaction", "cache", "transport", "encoding", "tls",
        ]

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: SchemaPrimitive.AnyCodingKey.self)
            self.timeout = try container.decodeIfPresent(TimeoutOption.self, forKey: .init("timeout"))
            self.headerTimeout = try container.decodeIfPresent(TimeoutOption.self, forKey: .init("headerTimeout"))
            self.chunkTimeout = try container.decodeIfPresent(TimeoutOption.self, forKey: .init("chunkTimeout"))
            self.compaction = try container.decodeIfPresent(Compaction.self, forKey: .init("compaction"))
            self.cache = try container.decodeIfPresent(Cache.self, forKey: .init("cache"))
            self.transport = try container.decodeIfPresent(Transport.self, forKey: .init("transport"))
            self.encoding = try container.decodeIfPresent(Encoding.self, forKey: .init("encoding"))
            self.tls = try container.decodeIfPresent(Tls.self, forKey: .init("tls"))

            var rest: [String: JSONValue] = [:]
            for key in container.allKeys where !Self.knownKeys.contains(key.stringValue) {
                rest[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
            }
            self.extra = rest
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: SchemaPrimitive.AnyCodingKey.self)
            for (k, v) in extra where !Self.knownKeys.contains(k) {
                try container.encode(v, forKey: .init(k))
            }
            try container.encodeIfPresent(timeout, forKey: .init("timeout"))
            try container.encodeIfPresent(headerTimeout, forKey: .init("headerTimeout"))
            try container.encodeIfPresent(chunkTimeout, forKey: .init("chunkTimeout"))
            try container.encodeIfPresent(compaction, forKey: .init("compaction"))
            try container.encodeIfPresent(cache, forKey: .init("cache"))
            try container.encodeIfPresent(transport, forKey: .init("transport"))
            try container.encodeIfPresent(encoding, forKey: .init("encoding"))
            try container.encodeIfPresent(tls, forKey: .init("tls"))
        }
    }

    // parity: schema/src/provider.ts#Overlays [status=implemented hash=db64f4e4f920]
    public struct Overlays: Equatable, Hashable, Sendable, Codable {
        public let settings: Settings?
        public let headers: [String: String]?
        public let body: [String: JSONValue]?

        public init(
            settings: Settings? = nil,
            headers: [String: String]? = nil,
            body: [String: JSONValue]? = nil
        ) {
            self.settings = settings
            self.headers = headers
            self.body = body
        }
    }

    // parity: schema/src/provider.ts#Request [status=implemented hash=ada63d9bac23]
    public struct Request: Equatable, Hashable, Sendable, Codable {
        public let settings: Settings
        public let headers: [String: String]
        public let body: [String: JSONValue]

        public init(
            settings: Settings = Settings(),
            headers: [String: String] = [:],
            body: [String: JSONValue] = [:]
        ) {
            self.settings = settings
            self.headers = headers
            self.body = body
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.settings = try container.decodeIfPresent(Settings.self, forKey: .settings) ?? Settings()
            self.headers = try container.decode([String: String].self, forKey: .headers)
            self.body = try container.decode([String: JSONValue].self, forKey: .body)
        }

        enum CodingKeys: String, CodingKey {
            case settings
            case headers
            case body
        }
    }

    // parity: schema/src/provider.ts#Info [status=implemented hash=1821aa3b7f74]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public let id: ID
        public let canonical: ID?
        public let integrationID: IntegrationID?
        public let name: String
        public let activation: Activation
        public let package: Package
        public let compatibility: ModelCompatibilitySchema.ProviderCompatibility?
        public let settings: Settings?
        public let headers: [String: String]?
        public let body: [String: JSONValue]?

        public init(
            id: ID,
            canonical: ID? = nil,
            integrationID: IntegrationID? = nil,
            name: String,
            activation: Activation,
            package: Package,
            compatibility: ModelCompatibilitySchema.ProviderCompatibility? = nil,
            settings: Settings? = nil,
            headers: [String: String]? = nil,
            body: [String: JSONValue]? = nil
        ) {
            self.id = id
            self.canonical = canonical
            self.integrationID = integrationID
            self.name = name
            self.activation = activation
            self.package = package
            self.compatibility = compatibility
            self.settings = settings
            self.headers = headers
            self.body = body
        }

        public static func empty(_ id: ID) -> Info {
            Info(id: id, name: id.rawValue, activation: .auto, package: "")
        }
    }
}

// MARK: - src/model.ts

public enum ModelSchema {
    // parity: schema/src/model.ts#ID [status=implemented hash=35fd1ec9fea4]
    public struct ID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public var description: String { rawValue }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.rawValue = try container.decode(String.self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    // parity: schema/src/model.ts#Event [status=implemented hash=e7550d251b3a]
    public enum Event {
        public static let updated = SchemaPrimitive.EventDescriptor.ephemeral(type: "model.updated")
        public static let definitions: [SchemaPrimitive.EventDescriptor] = [updated]
    }

    // parity: schema/src/model.ts#VariantID [status=implemented hash=caed5e988111]
    public struct VariantID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public var description: String { rawValue }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.rawValue = try container.decode(String.self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    // parity: schema/src/model.ts#Ref [status=implemented hash=86d4a4329620]
    public struct Ref: Equatable, Hashable, Sendable, Codable {
        public let id: ID
        public let providerID: ProviderSchema.ID
        public let variant: VariantID?

        public init(id: ID, providerID: ProviderSchema.ID, variant: VariantID? = nil) {
            self.id = id
            self.providerID = providerID
            self.variant = variant
        }

        /// Parses `"providerID/modelID"` or `"providerID/modelID#variant"`, supporting slashes inside `modelID`.
        public static func parse(_ input: String) throws(SchemaPrimitive.ValidationError) -> Ref {
            guard let providerEnd = input.firstIndex(of: "/"), providerEnd > input.startIndex else {
                throw .invalidFormat(expected: "providerID/modelID[#variant]", actual: input)
            }
            let providerStr = String(input[..<providerEnd])
            let afterSlash = input.index(after: providerEnd)
            let rest = input[afterSlash...]
            let idStr: String
            let variantStr: String?
            if let hashIdx = rest.firstIndex(of: "#") {
                idStr = String(rest[..<hashIdx])
                variantStr = String(rest[rest.index(after: hashIdx)...])
            } else {
                idStr = String(rest)
                variantStr = nil
            }
            if idStr.isEmpty || providerStr.contains("#") {
                throw .invalidFormat(expected: "providerID/modelID[#variant]", actual: input)
            }
            if let v = variantStr, v.isEmpty || v.contains("#") {
                throw .invalidFormat(expected: "providerID/modelID[#variant]", actual: input)
            }
            return Ref(
                id: ID(rawValue: idStr),
                providerID: ProviderSchema.ID(rawValue: providerStr),
                variant: variantStr.map(VariantID.init(rawValue:))
            )
        }
    }

    // parity: schema/src/model.ts#Family [status=implemented hash=f91815729a56]
    public struct Family: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public var description: String { rawValue }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.rawValue = try container.decode(String.self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    /// Open-ended model output category (`chat`, `decision`, `image`, `video`, or custom string).
    // parity: schema/src/model.ts#Type [status=implemented hash=1cd078de09d9]
    public struct ModelType: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public static let chat = ModelType(rawValue: "chat")
        public static let decision = ModelType(rawValue: "decision")
        public static let image = ModelType(rawValue: "image")
        public static let video = ModelType(rawValue: "video")

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public var description: String { rawValue }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.rawValue = try container.decode(String.self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    /// Flat `StructWithRest` model settings (`compaction`, `cache`, `encoding`, plus arbitrary provider keys).
    // parity: schema/src/model.ts#Settings [status=implemented hash=2915897d5438]
    public struct Settings: Equatable, Hashable, Sendable, Codable {
        public let compaction: ProviderSchema.Compaction?
        public let cache: ProviderSchema.Cache?
        public let encoding: ProviderSchema.Encoding?
        public let extra: [String: JSONValue]

        public init(
            compaction: ProviderSchema.Compaction? = nil,
            cache: ProviderSchema.Cache? = nil,
            encoding: ProviderSchema.Encoding? = nil,
            extra: [String: JSONValue] = [:]
        ) {
            self.compaction = compaction
            self.cache = cache
            self.encoding = encoding
            self.extra = extra
        }

        private static let knownKeys: Set<String> = ["compaction", "cache", "encoding"]

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: SchemaPrimitive.AnyCodingKey.self)
            self.compaction = try container.decodeIfPresent(ProviderSchema.Compaction.self, forKey: .init("compaction"))
            self.cache = try container.decodeIfPresent(ProviderSchema.Cache.self, forKey: .init("cache"))
            self.encoding = try container.decodeIfPresent(ProviderSchema.Encoding.self, forKey: .init("encoding"))
            var rest: [String: JSONValue] = [:]
            for key in container.allKeys where !Self.knownKeys.contains(key.stringValue) {
                rest[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
            }
            self.extra = rest
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: SchemaPrimitive.AnyCodingKey.self)
            for (k, v) in extra where !Self.knownKeys.contains(k) {
                try container.encode(v, forKey: .init(k))
            }
            try container.encodeIfPresent(compaction, forKey: .init("compaction"))
            try container.encodeIfPresent(cache, forKey: .init("cache"))
            try container.encodeIfPresent(encoding, forKey: .init("encoding"))
        }
    }

    /// Variant-level settings omitting `cache` (prompt cache belongs to the model).
    public struct VariantSettings: Equatable, Hashable, Sendable, Codable {
        public let compaction: ProviderSchema.Compaction?
        public let encoding: ProviderSchema.Encoding?
        public let extra: [String: JSONValue]

        public init(
            compaction: ProviderSchema.Compaction? = nil,
            encoding: ProviderSchema.Encoding? = nil,
            extra: [String: JSONValue] = [:]
        ) {
            self.compaction = compaction
            self.encoding = encoding
            self.extra = extra
        }

        private static let knownKeys: Set<String> = ["compaction", "encoding"]

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: SchemaPrimitive.AnyCodingKey.self)
            self.compaction = try container.decodeIfPresent(ProviderSchema.Compaction.self, forKey: .init("compaction"))
            self.encoding = try container.decodeIfPresent(ProviderSchema.Encoding.self, forKey: .init("encoding"))
            var rest: [String: JSONValue] = [:]
            for key in container.allKeys where !Self.knownKeys.contains(key.stringValue) {
                rest[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
            }
            self.extra = rest
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: SchemaPrimitive.AnyCodingKey.self)
            for (k, v) in extra where !Self.knownKeys.contains(k) {
                try container.encode(v, forKey: .init(k))
            }
            try container.encodeIfPresent(compaction, forKey: .init("compaction"))
            try container.encodeIfPresent(encoding, forKey: .init("encoding"))
        }
    }

    // parity: schema/src/model.ts#Overlays [status=implemented hash=db64f4e4f920]
    public struct Overlays: Equatable, Hashable, Sendable, Codable {
        public let settings: Settings?
        public let headers: [String: String]?
        public let body: [String: JSONValue]?

        public init(
            settings: Settings? = nil,
            headers: [String: String]? = nil,
            body: [String: JSONValue]? = nil
        ) {
            self.settings = settings
            self.headers = headers
            self.body = body
        }
    }

    // parity: schema/src/model.ts#Capabilities [status=implemented hash=550c7c73ea44]
    public struct Capabilities: Equatable, Hashable, Sendable, Codable {
        public let tools: Bool
        public let freeform: [ToolSchema.FreeformFormat]?
        public let input: [String]
        public let output: [String]
        public let temperature: Bool?

        public init(
            tools: Bool,
            freeform: [ToolSchema.FreeformFormat]? = nil,
            input: [String],
            output: [String],
            temperature: Bool? = nil
        ) {
            self.tools = tools
            self.freeform = freeform
            self.input = input
            self.output = output
            self.temperature = temperature
        }

        public static func `default`() -> Capabilities {
            Capabilities(tools: true, input: ["text", "image"], output: ["text"])
        }
    }

    // parity: schema/src/model.ts#Cost [status=implemented hash=8d5f00dad861]
    public struct Cost: Equatable, Hashable, Sendable, Codable {
        public struct Tier: Equatable, Hashable, Sendable, Codable {
            public let size: Int

            public init(size: Int) {
                self.size = size
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try SchemaPrimitive.decodeRequiredLiteral("context", from: container, forKey: .type)
                self.size = try container.decode(Int.self, forKey: .size)
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("context", forKey: .type)
                try container.encode(size, forKey: .size)
            }

            enum CodingKeys: String, CodingKey {
                case type
                case size
            }
        }

        public struct Cache: Equatable, Hashable, Sendable, Codable {
            public let read: MoneySchema.USDPerMillionTokens
            public let write: MoneySchema.USDPerMillionTokens

            public init(read: MoneySchema.USDPerMillionTokens, write: MoneySchema.USDPerMillionTokens) {
                self.read = read
                self.write = write
            }
        }

        public let tier: Tier?
        public let input: MoneySchema.USDPerMillionTokens
        public let output: MoneySchema.USDPerMillionTokens
        public let cache: Cache

        public init(
            tier: Tier? = nil,
            input: MoneySchema.USDPerMillionTokens,
            output: MoneySchema.USDPerMillionTokens,
            cache: Cache
        ) {
            self.tier = tier
            self.input = input
            self.output = output
            self.cache = cache
        }
    }

    // parity: schema/src/model.ts#Variant [status=implemented hash=9db15ebe651b]
    public struct Variant: Equatable, Hashable, Sendable, Codable {
        public let id: VariantID
        public let settings: VariantSettings?
        public let headers: [String: String]?
        public let body: [String: JSONValue]?

        public init(
            id: VariantID,
            settings: VariantSettings? = nil,
            headers: [String: String]? = nil,
            body: [String: JSONValue]? = nil
        ) {
            self.id = id
            self.settings = settings
            self.headers = headers
            self.body = body
        }
    }

    // parity: schema/src/model.ts#Info [status=implemented hash=1821aa3b7f74]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public struct Time: Equatable, Hashable, Sendable, Codable {
            public let released: Double

            public init(released: Double) {
                self.released = released
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.released = try SchemaPrimitive.decodeFinite(from: container, forKey: .released)
            }

            enum CodingKeys: String, CodingKey {
                case released
            }
        }

        public enum Status: String, Equatable, Hashable, Sendable, Codable {
            case alpha
            case beta
            case deprecated
            case active
        }

        public struct Limit: Equatable, Hashable, Sendable, Codable {
            public let context: Int
            public let input: Int?
            public let output: Int

            public init(context: Int, input: Int? = nil, output: Int) {
                self.context = context
                self.input = input
                self.output = output
            }
        }

        public let id: ID
        public let modelID: ID
        public let providerID: ProviderSchema.ID
        public let canonical: ProviderSchema.ID?
        public let type: ModelType?
        public let family: Family?
        public let name: String
        public let compatibility: ModelCompatibilitySchema.Compatibility?
        public let package: ProviderSchema.Package?
        public let settings: Settings?
        public let headers: [String: String]?
        public let body: [String: JSONValue]?
        public let capabilities: Capabilities
        public let variants: [Variant]
        public let time: Time
        public let cost: [Cost]
        public let status: Status
        public let enabled: Bool
        public let limit: Limit

        public init(
            id: ID,
            modelID: ID,
            providerID: ProviderSchema.ID,
            canonical: ProviderSchema.ID? = nil,
            type: ModelType? = nil,
            family: Family? = nil,
            name: String,
            compatibility: ModelCompatibilitySchema.Compatibility? = nil,
            package: ProviderSchema.Package? = nil,
            settings: Settings? = nil,
            headers: [String: String]? = nil,
            body: [String: JSONValue]? = nil,
            capabilities: Capabilities,
            variants: [Variant],
            time: Time,
            cost: [Cost],
            status: Status,
            enabled: Bool,
            limit: Limit
        ) {
            self.id = id
            self.modelID = modelID
            self.providerID = providerID
            self.canonical = canonical
            self.type = type
            self.family = family
            self.name = name
            self.compatibility = compatibility
            self.package = package
            self.settings = settings
            self.headers = headers
            self.body = body
            self.capabilities = capabilities
            self.variants = variants
            self.time = time
            self.cost = cost
            self.status = status
            self.enabled = enabled
            self.limit = limit
        }

        public static func `default`(providerID: ProviderSchema.ID, id: ID) -> Info {
            Info(
                id: id,
                modelID: id,
                providerID: providerID,
                name: id.rawValue,
                capabilities: Capabilities.default(),
                variants: [],
                time: Time(released: 0),
                cost: [],
                status: .active,
                enabled: true,
                limit: Limit(context: 200_000, output: 32_000)
            )
        }
    }
}

// MARK: - src/agent.ts

public enum AgentSchema {
    // parity: schema/src/agent.ts#ID [status=implemented hash=586ebc76dd62]
    public struct ID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public var description: String { rawValue }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.rawValue = try container.decode(String.self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    // parity: schema/src/agent.ts#Name [status=implemented hash=0ebcae9a21c9]
    public struct Name: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public var description: String { rawValue }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.rawValue = try container.decode(String.self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    // parity: schema/src/agent.ts#Color [status=implemented hash=01480d28c0da]
    public struct Color: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public var description: String { rawValue }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.rawValue = try container.decode(String.self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    // parity: schema/src/agent.ts#Info [status=implemented hash=1821aa3b7f74]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public enum Mode: String, Equatable, Hashable, Sendable, Codable {
            case subagent
            case primary
            case all
        }

        public let id: ID
        public let name: Name
        public let model: ModelSchema.Ref?
        public let request: ProviderSchema.Request
        public let system: String?
        public let description: String?
        public let mode: Mode
        public let hidden: Bool
        public let color: Color?
        public let steps: SchemaPrimitive.PositiveInt?
        public let permissions: PermissionSchema.Ruleset

        public init(
            id: ID,
            name: Name,
            model: ModelSchema.Ref? = nil,
            request: ProviderSchema.Request,
            system: String? = nil,
            description: String? = nil,
            mode: Mode,
            hidden: Bool,
            color: Color? = nil,
            steps: SchemaPrimitive.PositiveInt? = nil,
            permissions: PermissionSchema.Ruleset
        ) {
            self.id = id
            self.name = name
            self.model = model
            self.request = request
            self.system = system
            self.description = description
            self.mode = mode
            self.hidden = hidden
            self.color = color
            self.steps = steps
            self.permissions = permissions
        }

        public static func `default`(_ id: ID) -> Info {
            Info(
                id: id,
                name: Name(rawValue: id.rawValue),
                request: ProviderSchema.Request(),
                mode: .primary,
                hidden: false,
                permissions: [
                    PermissionSchema.Rule(action: "*", resource: "*", effect: .allow),
                    PermissionSchema.Rule(action: "read", resource: "*.env", effect: .ask),
                    PermissionSchema.Rule(action: "read", resource: "*.env.*", effect: .ask),
                    PermissionSchema.Rule(action: "read", resource: "*.env.example", effect: .allow),
                ]
            )
        }
    }

    // parity: schema/src/agent.ts#Event [status=implemented hash=880cfa5454d1]
    public enum Event {
        public static let updated = SchemaPrimitive.EventDescriptor.ephemeral(type: "agent.updated")
        public static let definitions: [SchemaPrimitive.EventDescriptor] = [updated]
    }
}

// MARK: - src/credential.ts

public enum CredentialSchema {
    // parity: schema/src/credential.ts#ID [status=implemented hash=5587a2f58a02]
    public struct ID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static func create() -> ID {
            ID(rawValue: "cred_" + Identifier.ascending())
        }

        public var description: String { rawValue }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.rawValue = try container.decode(String.self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    // parity: schema/src/credential.ts#Event [status=implemented hash=6d8202e6bc7c]
    public enum Event {
        public struct UpdatedPayload: Equatable, Hashable, Sendable, Codable {
            public let integrationID: IntegrationID
            public let credentialID: ID

            public init(integrationID: IntegrationID, credentialID: ID) {
                self.integrationID = integrationID
                self.credentialID = credentialID
            }
        }

        public struct SwitchedPayload: Equatable, Hashable, Sendable, Codable {
            public let integrationID: IntegrationID
            public let credentialID: ID?

            public init(integrationID: IntegrationID, credentialID: ID?) {
                self.integrationID = integrationID
                self.credentialID = credentialID
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.integrationID = try container.decode(IntegrationID.self, forKey: .integrationID)
                self.credentialID = try container.decode(ID?.self, forKey: .credentialID)
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(integrationID, forKey: .integrationID)
                try container.encode(credentialID, forKey: .credentialID)
            }

            enum CodingKeys: String, CodingKey {
                case integrationID
                case credentialID
            }
        }

        public static let updated = SchemaPrimitive.EventDescriptor.ephemeral(type: "credential.updated")
        public static let switched = SchemaPrimitive.EventDescriptor.ephemeral(type: "credential.switched")
        public static let definitions: [SchemaPrimitive.EventDescriptor] = [updated, switched]
    }

    // parity: schema/src/credential.ts#OAuth [status=implemented hash=7fdd3f5944f2]
    public struct OAuth: Equatable, Hashable, Sendable, Codable {
        public let methodID: IntegrationMethodID
        public let refresh: String
        public let access: String
        public let expires: SchemaPrimitive.NonNegativeInt
        public let metadata: [String: JSONValue]?

        public init(
            methodID: IntegrationMethodID,
            refresh: String,
            access: String,
            expires: SchemaPrimitive.NonNegativeInt,
            metadata: [String: JSONValue]? = nil
        ) {
            self.methodID = methodID
            self.refresh = refresh
            self.access = access
            self.expires = expires
            self.metadata = metadata
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("oauth", from: container, forKey: .type)
            self.methodID = try container.decode(IntegrationMethodID.self, forKey: .methodID)
            self.refresh = try container.decode(String.self, forKey: .refresh)
            self.access = try container.decode(String.self, forKey: .access)
            self.expires = try container.decode(SchemaPrimitive.NonNegativeInt.self, forKey: .expires)
            self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("oauth", forKey: .type)
            try container.encode(methodID, forKey: .methodID)
            try container.encode(refresh, forKey: .refresh)
            try container.encode(access, forKey: .access)
            try container.encode(expires, forKey: .expires)
            try container.encodeIfPresent(metadata, forKey: .metadata)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case methodID
            case refresh
            case access
            case expires
            case metadata
        }
    }

    // parity: schema/src/credential.ts#Key [status=implemented hash=6432fd29f1f6]
    public struct Key: Equatable, Hashable, Sendable, Codable {
        public let key: String
        public let metadata: [String: JSONValue]?

        public init(key: String, metadata: [String: JSONValue]? = nil) {
            self.key = key
            self.metadata = metadata
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("key", from: container, forKey: .type)
            self.key = try container.decode(String.self, forKey: .key)
            self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("key", forKey: .type)
            try container.encode(key, forKey: .key)
            try container.encodeIfPresent(metadata, forKey: .metadata)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case key
            case metadata
        }
    }

    // parity: schema/src/credential.ts#External [status=implemented hash=9c17c4aac5dd]
    public struct External: Equatable, Hashable, Sendable, Codable {
        public let methodID: IntegrationMethodID
        public let metadata: [String: JSONValue]?

        public init(methodID: IntegrationMethodID, metadata: [String: JSONValue]? = nil) {
            self.methodID = methodID
            self.metadata = metadata
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("external", from: container, forKey: .type)
            self.methodID = try container.decode(IntegrationMethodID.self, forKey: .methodID)
            self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("external", forKey: .type)
            try container.encode(methodID, forKey: .methodID)
            try container.encodeIfPresent(metadata, forKey: .metadata)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case methodID
            case metadata
        }
    }

    // parity: schema/src/credential.ts#Value [status=implemented hash=861758562e1c]
    public enum Value: Equatable, Hashable, Sendable, Codable {
        case oauth(OAuth)
        case key(Key)
        case external(External)

        enum TagKeys: String, CodingKey {
            case type
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: TagKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "oauth":
                self = .oauth(try OAuth(from: decoder))
            case "key":
                self = .key(try Key(from: decoder))
            case "external":
                self = .external(try External(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown Credential.Value type '\(type)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .oauth(let v):
                try v.encode(to: encoder)
            case .key(let v):
                try v.encode(to: encoder)
            case .external(let v):
                try v.encode(to: encoder)
            }
        }
    }

    // parity: schema/src/credential.ts#Entry [status=implemented hash=10006e92b25e]
    public struct Entry: Equatable, Hashable, Sendable, Codable {
        public let id: ID
        public let integrationID: IntegrationID
        public let label: String
        public let active: Bool
        public let value: Value

        public init(id: ID, integrationID: IntegrationID, label: String, active: Bool, value: Value) {
            self.id = id
            self.integrationID = integrationID
            self.label = label
            self.active = active
            self.value = value
        }
    }

    // parity: schema/src/credential.ts#CreateInput [status=implemented hash=d8768400ea9e]
    public struct CreateInput: Equatable, Hashable, Sendable, Codable {
        public let id: ID?
        public let integrationID: IntegrationID
        public let label: String?
        public let value: Value
        public let activate: Bool?

        public init(
            id: ID? = nil,
            integrationID: IntegrationID,
            label: String? = nil,
            value: Value,
            activate: Bool? = nil
        ) {
            self.id = id
            self.integrationID = integrationID
            self.label = label
            self.value = value
            self.activate = activate
        }
    }
}

// MARK: - src/credential-legacy.ts

public enum CredentialLegacySchema {
    /// Decodes a stored or exported credential value (pre-v2.1 `configuration` or current `metadata`)
    /// into the canonical `CredentialSchema.Value`, giving `configuration` answers precedence over `metadata`.
    // parity: schema/src/credential-legacy.ts#Value [status=implemented hash=66f63dd26b15]
    public struct Value: Equatable, Hashable, Sendable, Codable {
        public let credential: CredentialSchema.Value

        public init(credential: CredentialSchema.Value) {
            self.credential = credential
        }

        enum TagKeys: String, CodingKey {
            case type
            case key
            case metadata
            case configuration
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: TagKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "oauth":
                self.credential = .oauth(try CredentialSchema.OAuth(from: decoder))
            case "external":
                self.credential = .external(try CredentialSchema.External(from: decoder))
            case "key":
                let key = try container.decode(String.self, forKey: .key)
                let metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
                let configuration = try container.decodeIfPresent(FormSchema.Answer.self, forKey: .configuration)
                if let configuration {
                    var merged = metadata ?? [:]
                    for (k, formValue) in configuration {
                        merged[k] = formValue.asJSONValue
                    }
                    self.credential = .key(CredentialSchema.Key(key: key, metadata: merged))
                } else {
                    self.credential = .key(CredentialSchema.Key(key: key, metadata: metadata))
                }
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown CredentialLegacy.Value type '\(type)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            try credential.encode(to: encoder)
        }
    }

    /// Decodes an `auth export` entry of either pre-v2.1 or current shape into canonical `CredentialSchema.Entry`.
    // parity: schema/src/credential-legacy.ts#Entry [status=implemented hash=dee8da343bfb]
    public struct Entry: Equatable, Hashable, Sendable, Codable {
        public let entry: CredentialSchema.Entry

        public init(entry: CredentialSchema.Entry) {
            self.entry = entry
        }

        enum CodingKeys: String, CodingKey {
            case id
            case integrationID
            case label
            case active
            case value
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let id = try container.decode(CredentialSchema.ID.self, forKey: .id)
            let integrationID = try container.decode(IntegrationID.self, forKey: .integrationID)
            let label = try container.decode(String.self, forKey: .label)
            let active = try container.decode(Bool.self, forKey: .active)
            let legacyValue = try container.decode(Value.self, forKey: .value)
            self.entry = CredentialSchema.Entry(
                id: id,
                integrationID: integrationID,
                label: label,
                active: active,
                value: legacyValue.credential
            )
        }

        public func encode(to encoder: Encoder) throws {
            try entry.encode(to: encoder)
        }
    }
}

// MARK: - src/connection.ts

public enum ConnectionSchema {
    // parity: schema/src/connection.ts#Status [status=implemented hash=28a7c8fcb2ad]
    public struct Status: Equatable, Hashable, Sendable, Codable {
        public enum Kind: String, Equatable, Hashable, Sendable, Codable {
            case needsAuth = "needs_auth"
        }

        public let status: Kind
        public let message: String
        public let url: String?

        public init(status: Kind = .needsAuth, message: String, url: String? = nil) {
            self.status = status
            self.message = message
            self.url = url
        }
    }

    // parity: schema/src/connection.ts#CredentialInfo [status=implemented hash=77a2f2567979]
    public struct CredentialInfo: Equatable, Hashable, Sendable, Codable {
        public enum Method: String, Equatable, Hashable, Sendable, Codable {
            case key
            case oauth
            case external
        }

        public let id: CredentialSchema.ID
        public let label: String
        public let method: Method
        public let status: Status?

        public init(id: CredentialSchema.ID, label: String, method: Method, status: Status? = nil) {
            self.id = id
            self.label = label
            self.method = method
            self.status = status
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("credential", from: container, forKey: .type)
            self.id = try container.decode(CredentialSchema.ID.self, forKey: .id)
            self.label = try container.decode(String.self, forKey: .label)
            self.method = try container.decode(Method.self, forKey: .method)
            self.status = try container.decodeIfPresent(Status.self, forKey: .status)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("credential", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(label, forKey: .label)
            try container.encode(method, forKey: .method)
            try container.encodeIfPresent(status, forKey: .status)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case id
            case label
            case method
            case status
        }
    }

    // parity: schema/src/connection.ts#EnvInfo [status=implemented hash=3151a82d6d39]
    public struct EnvInfo: Equatable, Hashable, Sendable, Codable {
        public let name: String
        public let status: Status?

        public init(name: String, status: Status? = nil) {
            self.name = name
            self.status = status
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("env", from: container, forKey: .type)
            self.name = try container.decode(String.self, forKey: .name)
            self.status = try container.decodeIfPresent(Status.self, forKey: .status)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("env", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encodeIfPresent(status, forKey: .status)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case name
            case status
        }
    }

    // parity: schema/src/connection.ts#Info [status=implemented hash=8d2278d6ccdc]
    public enum Info: Equatable, Hashable, Sendable, Codable {
        case credential(CredentialInfo)
        case env(EnvInfo)

        enum TagKeys: String, CodingKey {
            case type
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: TagKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "credential":
                self = .credential(try CredentialInfo(from: decoder))
            case "env":
                self = .env(try EnvInfo(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown Connection.Info type '\(type)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .credential(let c):
                try c.encode(to: encoder)
            case .env(let e):
                try e.encode(to: encoder)
            }
        }
    }
}

// MARK: - src/generate.ts

public enum GenerateSchema {
    // MARK: Shared

    // parity: schema/src/generate.ts#File [status=implemented hash=cfd8b4d06974]
    public struct File: Equatable, Hashable, Sendable, Codable {
        public let data: String
        public let mime: String
        public let name: String?

        public init(data: String, mime: String, name: String? = nil) {
            self.data = data
            self.mime = mime
            self.name = name
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let data = try container.decode(String.self, forKey: .data)
            guard SchemaPrimitive.isValidBase64(data) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .data,
                    in: container,
                    debugDescription: "Expected valid base64 string for Generate.File.data"
                )
            }
            self.data = data
            self.mime = try container.decode(String.self, forKey: .mime)
            self.name = try container.decodeIfPresent(String.self, forKey: .name)
        }

        enum CodingKeys: String, CodingKey {
            case data
            case mime
            case name
        }
    }

    // parity: schema/src/generate.ts#ImageFile [status=implemented hash=598c38383baf]
    public struct ImageFile: Equatable, Hashable, Sendable, Codable {
        public let data: String
        public let mime: String
        public let name: String?

        public init(data: String, mime: String, name: String? = nil) {
            self.data = data
            self.mime = mime
            self.name = name
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let data = try container.decode(String.self, forKey: .data)
            guard SchemaPrimitive.isValidBase64(data) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .data,
                    in: container,
                    debugDescription: "Expected valid base64 string for Generate.ImageFile.data"
                )
            }
            let mime = try container.decode(String.self, forKey: .mime)
            guard SchemaPrimitive.isImageMime(mime) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .mime,
                    in: container,
                    debugDescription: "Expected image/* mime type, got '\(mime)'"
                )
            }
            self.data = data
            self.mime = mime
            self.name = try container.decodeIfPresent(String.self, forKey: .name)
        }

        enum CodingKeys: String, CodingKey {
            case data
            case mime
            case name
        }
    }

    // parity: schema/src/generate.ts#Usage [status=implemented hash=cc9ccb6e172c]
    public struct Usage: Equatable, Hashable, Sendable, Codable {
        public let input: Double?
        public let output: Double?

        public init(input: Double? = nil, output: Double? = nil) {
            self.input = input
            self.output = output
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.input = try SchemaPrimitive.decodeFiniteIfPresent(from: container, forKey: .input)
            self.output = try SchemaPrimitive.decodeFiniteIfPresent(from: container, forKey: .output)
        }

        enum CodingKeys: String, CodingKey {
            case input
            case output
        }
    }

    // parity: schema/src/generate.ts#Native [status=implemented hash=5efa7cec66f5]
    public typealias Native = [String: JSONValue]

    // MARK: Image

    /// Aspect ratio matching `^\d+(?:\.\d+)?:\d+(?:\.\d+)?$`.
    // parity: schema/src/generate.ts#ImageAspect [status=implemented hash=c263ebe406c0]
    public struct ImageAspect: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public init?(rawValue: String) {
            guard SchemaPrimitive.isAspectRatio(rawValue) else { return nil }
            self.rawValue = rawValue
        }

        public init(validating value: String) throws(SchemaPrimitive.ValidationError) {
            guard SchemaPrimitive.isAspectRatio(value) else {
                throw .invalidFormat(expected: "^\\d+(?:\\.\\d+)?:\\d+(?:\\.\\d+)?$", actual: value)
            }
            self.rawValue = value
        }

        public var description: String { rawValue }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard SchemaPrimitive.isAspectRatio(value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ImageAspect '\(value)'"
                )
            }
            self.rawValue = value
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    /// Open-ended image resolution tier (`1K`, `2K`, `4K`, or custom string).
    // parity: schema/src/generate.ts#ImageResolution [status=implemented hash=16b8d8c837b8]
    public struct ImageResolution: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public static let tier1K = ImageResolution(rawValue: "1K")
        public static let tier2K = ImageResolution(rawValue: "2K")
        public static let tier4K = ImageResolution(rawValue: "4K")

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public var description: String { rawValue }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.rawValue = try container.decode(String.self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    // parity: schema/src/generate.ts#ImageRequest [status=implemented hash=07593d6ab60a]
    public struct ImageRequest: Equatable, Hashable, Sendable, Codable {
        public let model: ModelSchema.Ref
        public let prompt: String
        public let images: [File]?
        public let n: SchemaPrimitive.PositiveInt?
        public let aspect: ImageAspect?
        public let resolution: ImageResolution?

        public init(
            model: ModelSchema.Ref,
            prompt: String,
            images: [File]? = nil,
            n: SchemaPrimitive.PositiveInt? = nil,
            aspect: ImageAspect? = nil,
            resolution: ImageResolution? = nil
        ) {
            self.model = model
            self.prompt = prompt
            self.images = images
            self.n = n
            self.aspect = aspect
            self.resolution = resolution
        }
    }

    // parity: schema/src/generate.ts#ImageOutput [status=implemented hash=5154527f1db7]
    public struct ImageOutput: Equatable, Hashable, Sendable, Codable {
        public let data: String
        public let mime: String
        public let name: String?

        public init(data: String, mime: String, name: String? = nil) {
            self.data = data
            self.mime = mime
            self.name = name
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("image", from: container, forKey: .type)
            let data = try container.decode(String.self, forKey: .data)
            guard SchemaPrimitive.isValidBase64(data) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .data,
                    in: container,
                    debugDescription: "Expected valid base64 string for ImageOutput.data"
                )
            }
            self.data = data
            self.mime = try container.decode(String.self, forKey: .mime)
            self.name = try container.decodeIfPresent(String.self, forKey: .name)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("image", forKey: .type)
            try container.encode(data, forKey: .data)
            try container.encode(mime, forKey: .mime)
            try container.encodeIfPresent(name, forKey: .name)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case data
            case mime
            case name
        }
    }

    // parity: schema/src/generate.ts#ImageResult [status=implemented hash=1a71cb6ac6a4]
    public struct ImageResult: Equatable, Hashable, Sendable, Codable {
        public let images: [ImageOutput]
        public let cost: MoneySchema.USD?
        public let tokens: Usage?
        public let native: Native?

        public init(
            images: [ImageOutput],
            cost: MoneySchema.USD? = nil,
            tokens: Usage? = nil,
            native: Native? = nil
        ) {
            self.images = images
            self.cost = cost
            self.tokens = tokens
            self.native = native
        }
    }

    // MARK: Video

    /// Strict video job identifier matching `^video_[0-9a-f]{12}[0-9A-Za-z]{14}$`.
    // parity: schema/src/generate.ts#VideoID [status=implemented hash=44f8d7b6c360]
    public struct VideoID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public init?(rawValue: String) {
            guard SchemaPrimitive.isStrictPrefixedIdentifier(rawValue, prefix: "video_") else { return nil }
            self.rawValue = rawValue
        }

        public init(validating value: String) throws(SchemaPrimitive.ValidationError) {
            guard SchemaPrimitive.isStrictPrefixedIdentifier(value, prefix: "video_") else {
                throw .invalidFormat(expected: "^video_[0-9a-f]{12}[0-9A-Za-z]{14}$", actual: value)
            }
            self.rawValue = value
        }

        private init(unchecked value: String) {
            self.rawValue = value
        }

        public static func create() -> VideoID {
            VideoID(unchecked: "video_" + Identifier.descending())
        }

        public var description: String { rawValue }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard SchemaPrimitive.isStrictPrefixedIdentifier(value, prefix: "video_") else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid Generate.VideoID '\(value)'"
                )
            }
            self.rawValue = value
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    // parity: schema/src/generate.ts#VideoAspect [status=implemented hash=17121c040ca8]
    public enum VideoAspect: Equatable, Hashable, Sendable, Codable {
        case ratio(ImageAspect)
        case auto

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if value == "auto" {
                self = .auto
            } else if let ratio = ImageAspect(rawValue: value) {
                self = .ratio(ratio)
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid VideoAspect '\(value)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .ratio(let aspect):
                try container.encode(aspect)
            case .auto:
                try container.encode("auto")
            }
        }
    }

    /// Open-ended video resolution tier (`480p`, `720p`, `1080p`, `4k`, or custom string).
    // parity: schema/src/generate.ts#VideoResolution [status=implemented hash=b98530fbc7d8]
    public struct VideoResolution: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public static let p480 = VideoResolution(rawValue: "480p")
        public static let p720 = VideoResolution(rawValue: "720p")
        public static let p1080 = VideoResolution(rawValue: "1080p")
        public static let k4 = VideoResolution(rawValue: "4k")

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public var description: String { rawValue }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.rawValue = try container.decode(String.self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    // parity: schema/src/generate.ts#VideoRequest [status=implemented hash=4edb683665ad]
    public struct VideoRequest: Equatable, Hashable, Sendable, Codable {
        public let model: ModelSchema.Ref
        public let prompt: String
        public let start: ImageFile?
        public let end: ImageFile?
        public let references: [File]?
        public let duration: SchemaPrimitive.PositiveInt?
        public let aspect: VideoAspect?
        public let resolution: VideoResolution?
        public let sound: Bool?

        public init(
            model: ModelSchema.Ref,
            prompt: String,
            start: ImageFile? = nil,
            end: ImageFile? = nil,
            references: [File]? = nil,
            duration: SchemaPrimitive.PositiveInt? = nil,
            aspect: VideoAspect? = nil,
            resolution: VideoResolution? = nil,
            sound: Bool? = nil
        ) {
            self.model = model
            self.prompt = prompt
            self.start = start
            self.end = end
            self.references = references
            self.duration = duration
            self.aspect = aspect
            self.resolution = resolution
            self.sound = sound
        }
    }

    // parity: schema/src/generate.ts#VideoErrorReason [status=implemented hash=f4c57e1d93e1]
    public enum VideoErrorReason: String, Equatable, Hashable, Sendable, Codable {
        case failed
        case cancelled
        case expired
        case unknown
    }

    // parity: schema/src/generate.ts#VideoRunning [status=implemented hash=ba40b3c9a6d2]
    public struct VideoRunning: Equatable, Hashable, Sendable, Codable {
        public let id: VideoID

        public init(id: VideoID) {
            self.id = id
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(VideoID.self, forKey: .id)
            try SchemaPrimitive.decodeRequiredLiteral("running", from: container, forKey: .status)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode("running", forKey: .status)
        }

        enum CodingKeys: String, CodingKey {
            case id
            case status
        }
    }

    // parity: schema/src/generate.ts#VideoCompleted [status=implemented hash=6b5ce1c22a1c]
    public struct VideoCompleted: Equatable, Hashable, Sendable, Codable {
        public let id: VideoID
        public let blobs: [BlobStoreSchema.Info]

        public init(id: VideoID, blobs: [BlobStoreSchema.Info]) {
            self.id = id
            self.blobs = blobs
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(VideoID.self, forKey: .id)
            try SchemaPrimitive.decodeRequiredLiteral("completed", from: container, forKey: .status)
            self.blobs = try container.decode([BlobStoreSchema.Info].self, forKey: .blobs)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode("completed", forKey: .status)
            try container.encode(blobs, forKey: .blobs)
        }

        enum CodingKeys: String, CodingKey {
            case id
            case status
            case blobs
        }
    }

    // parity: schema/src/generate.ts#VideoError [status=implemented hash=cbb82f2e37c4]
    public struct VideoError: Equatable, Hashable, Sendable, Codable {
        public let id: VideoID
        public let error: String
        public let reason: VideoErrorReason

        public init(id: VideoID, error: String, reason: VideoErrorReason) {
            self.id = id
            self.error = error
            self.reason = reason
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(VideoID.self, forKey: .id)
            try SchemaPrimitive.decodeRequiredLiteral("error", from: container, forKey: .status)
            self.error = try container.decode(String.self, forKey: .error)
            self.reason = try container.decode(VideoErrorReason.self, forKey: .reason)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode("error", forKey: .status)
            try container.encode(error, forKey: .error)
            try container.encode(reason, forKey: .reason)
        }

        enum CodingKeys: String, CodingKey {
            case id
            case status
            case error
            case reason
        }
    }

    // parity: schema/src/generate.ts#VideoJob [status=implemented hash=e8ca14f85d5e]
    public enum VideoJob: Equatable, Hashable, Sendable, Codable {
        case running(VideoRunning)
        case completed(VideoCompleted)
        case error(VideoError)

        enum TagKeys: String, CodingKey {
            case status
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: TagKeys.self)
            let status = try container.decode(String.self, forKey: .status)
            switch status {
            case "running":
                self = .running(try VideoRunning(from: decoder))
            case "completed":
                self = .completed(try VideoCompleted(from: decoder))
            case "error":
                self = .error(try VideoError(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .status,
                    in: container,
                    debugDescription: "Unknown Generate.VideoJob status '\(status)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .running(let v):
                try v.encode(to: encoder)
            case .completed(let v):
                try v.encode(to: encoder)
            case .error(let v):
                try v.encode(to: encoder)
            }
        }
    }

    // MARK: Decisions

    // parity: schema/src/generate.ts#DecisionTextPart [status=implemented hash=3f3e6ab2789e]
    public struct DecisionTextPart: Equatable, Hashable, Sendable, Codable {
        public let text: String

        public init(text: String) {
            self.text = text
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("text", from: container, forKey: .type)
            self.text = try container.decode(String.self, forKey: .text)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case text
        }
    }

    // parity: schema/src/generate.ts#DecisionJsonPart [status=implemented hash=40ca2ff15118]
    public struct DecisionJsonPart: Equatable, Hashable, Sendable, Codable {
        public let value: JSONValue

        public init(value: JSONValue) {
            self.value = value
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("json", from: container, forKey: .type)
            self.value = try container.decode(JSONValue.self, forKey: .value)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("json", forKey: .type)
            try container.encode(value, forKey: .value)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case value
        }
    }

    // parity: schema/src/generate.ts#DecisionFilePart [status=implemented hash=6c969de40311]
    public struct DecisionFilePart: Equatable, Hashable, Sendable, Codable {
        public let data: String
        public let mime: String
        public let name: String?

        public init(data: String, mime: String, name: String? = nil) {
            self.data = data
            self.mime = mime
            self.name = name
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("file", from: container, forKey: .type)
            let data = try container.decode(String.self, forKey: .data)
            guard SchemaPrimitive.isValidBase64(data) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .data,
                    in: container,
                    debugDescription: "Expected valid base64 string for DecisionFilePart.data"
                )
            }
            self.data = data
            self.mime = try container.decode(String.self, forKey: .mime)
            self.name = try container.decodeIfPresent(String.self, forKey: .name)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("file", forKey: .type)
            try container.encode(data, forKey: .data)
            try container.encode(mime, forKey: .mime)
            try container.encodeIfPresent(name, forKey: .name)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case data
            case mime
            case name
        }
    }

    // parity: schema/src/generate.ts#DecisionPart [status=implemented hash=4b1387295ac6]
    public enum DecisionPart: Equatable, Hashable, Sendable, Codable {
        case text(DecisionTextPart)
        case json(DecisionJsonPart)
        case file(DecisionFilePart)

        enum TagKeys: String, CodingKey {
            case type
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: TagKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "text":
                self = .text(try DecisionTextPart(from: decoder))
            case "json":
                self = .json(try DecisionJsonPart(from: decoder))
            case "file":
                self = .file(try DecisionFilePart(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown Generate.DecisionPart type '\(type)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .text(let v):
                try v.encode(to: encoder)
            case .json(let v):
                try v.encode(to: encoder)
            case .file(let v):
                try v.encode(to: encoder)
            }
        }
    }

    /// Typed choice value where `true` (`.bool(true)`) and `"true"` (`.string("true")`) are distinct.
    // parity: schema/src/generate.ts#ChoiceValue [status=implemented hash=c035676a1d0f]
    public enum ChoiceValue: Equatable, Hashable, Sendable, Codable {
        case string(String)
        case bool(Bool)

        public init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let b = try? single.decode(Bool.self) {
                self = .bool(b)
            } else if let s = try? single.decode(String.self) {
                self = .string(s)
            } else {
                throw DecodingError.dataCorruptedError(
                    in: single,
                    debugDescription: "Expected String or Bool for Generate.ChoiceValue"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var single = encoder.singleValueContainer()
            switch self {
            case .string(let s):
                try single.encode(s)
            case .bool(let b):
                try single.encode(b)
            }
        }
    }

    // parity: schema/src/generate.ts#PredicateQuestion [status=implemented hash=54aa9ab28952]
    public struct PredicateQuestion: Equatable, Hashable, Sendable, Codable {
        public struct Criteria: Equatable, Hashable, Sendable, Codable {
            public let whenTrue: String?
            public let whenFalse: String?

            public init(whenTrue: String? = nil, whenFalse: String? = nil) {
                self.whenTrue = whenTrue
                self.whenFalse = whenFalse
            }

            enum CodingKeys: String, CodingKey {
                case whenTrue = "true"
                case whenFalse = "false"
            }
        }

        public let name: String
        public let instructions: String
        public let criteria: Criteria?

        public init(name: String, instructions: String, criteria: Criteria? = nil) {
            self.name = name
            self.instructions = instructions
            self.criteria = criteria
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("predicate", from: container, forKey: .type)
            self.name = try container.decode(String.self, forKey: .name)
            self.instructions = try container.decode(String.self, forKey: .instructions)
            self.criteria = try container.decodeIfPresent(Criteria.self, forKey: .criteria)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("predicate", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(instructions, forKey: .instructions)
            try container.encodeIfPresent(criteria, forKey: .criteria)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case name
            case instructions
            case criteria
        }
    }

    // parity: schema/src/generate.ts#ChoiceQuestion [status=implemented hash=5b84f7a73fda]
    public struct ChoiceQuestion: Equatable, Hashable, Sendable, Codable {
        public struct ChoiceOption: Equatable, Hashable, Sendable, Codable {
            public let value: ChoiceValue
            public let description: String?

            public init(value: ChoiceValue, description: String? = nil) {
                self.value = value
                self.description = description
            }
        }

        public let name: String
        public let instructions: String
        public let choices: [ChoiceOption]

        public init(name: String, instructions: String, choices: [ChoiceOption]) {
            self.name = name
            self.instructions = instructions
            self.choices = choices
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("choice", from: container, forKey: .type)
            self.name = try container.decode(String.self, forKey: .name)
            self.instructions = try container.decode(String.self, forKey: .instructions)
            let choices = try container.decode([ChoiceOption].self, forKey: .choices)
            guard !choices.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .choices,
                    in: container,
                    debugDescription: "ChoiceQuestion.choices must contain at least 1 option"
                )
            }
            self.choices = choices
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("choice", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(instructions, forKey: .instructions)
            try container.encode(choices, forKey: .choices)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case name
            case instructions
            case choices
        }
    }

    // parity: schema/src/generate.ts#ScoreQuestion [status=implemented hash=748d8bad549e]
    public struct ScoreQuestion: Equatable, Hashable, Sendable, Codable {
        public struct Level: Equatable, Hashable, Sendable, Codable {
            public let label: String
            public let description: String?

            public init(label: String, description: String? = nil) {
                self.label = label
                self.description = description
            }
        }

        public let name: String
        public let instructions: String
        public let levels: [Level]

        public init(name: String, instructions: String, levels: [Level]) {
            self.name = name
            self.instructions = instructions
            self.levels = levels
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("score", from: container, forKey: .type)
            self.name = try container.decode(String.self, forKey: .name)
            self.instructions = try container.decode(String.self, forKey: .instructions)
            let levels = try container.decode([Level].self, forKey: .levels)
            guard !levels.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .levels,
                    in: container,
                    debugDescription: "ScoreQuestion.levels must contain at least 1 level"
                )
            }
            self.levels = levels
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("score", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(instructions, forKey: .instructions)
            try container.encode(levels, forKey: .levels)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case name
            case instructions
            case levels
        }
    }

    // parity: schema/src/generate.ts#DecisionQuestion [status=implemented hash=5cd0a18749b8]
    public enum DecisionQuestion: Equatable, Hashable, Sendable, Codable {
        case predicate(PredicateQuestion)
        case choice(ChoiceQuestion)
        case score(ScoreQuestion)

        enum TagKeys: String, CodingKey {
            case type
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: TagKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "predicate":
                self = .predicate(try PredicateQuestion(from: decoder))
            case "choice":
                self = .choice(try ChoiceQuestion(from: decoder))
            case "score":
                self = .score(try ScoreQuestion(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown Generate.DecisionQuestion type '\(type)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .predicate(let v):
                try v.encode(to: encoder)
            case .choice(let v):
                try v.encode(to: encoder)
            case .score(let v):
                try v.encode(to: encoder)
            }
        }
    }

    // parity: schema/src/generate.ts#DecisionRequest [status=implemented hash=29a7a66c45bd]
    public struct DecisionRequest: Equatable, Hashable, Sendable, Codable {
        public let model: ModelSchema.Ref
        public let input: [DecisionPart]
        public let questions: [DecisionQuestion]

        public init(model: ModelSchema.Ref, input: [DecisionPart], questions: [DecisionQuestion]) {
            self.model = model
            self.input = input
            self.questions = questions
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.model = try container.decode(ModelSchema.Ref.self, forKey: .model)
            self.input = try container.decode([DecisionPart].self, forKey: .input)
            let questions = try container.decode([DecisionQuestion].self, forKey: .questions)
            guard !questions.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .questions,
                    in: container,
                    debugDescription: "DecisionRequest.questions must contain at least 1 question"
                )
            }
            self.questions = questions
        }

        enum CodingKeys: String, CodingKey {
            case model
            case input
            case questions
        }
    }

    private static func decodeProbability<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K
    ) throws -> Double {
        let p = try SchemaPrimitive.decodeFinite(from: container, forKey: key)
        guard p >= 0 && p <= 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "Expected probability in 0...1, got \(p)"
            )
        }
        return p
    }

    // parity: schema/src/generate.ts#PredicateAnswer [status=implemented hash=f311e6e43b4e]
    public struct PredicateAnswer: Equatable, Hashable, Sendable, Codable {
        public let name: String
        public let probability: Double

        public init(name: String, probability: Double) {
            self.name = name
            self.probability = probability
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("predicate", from: container, forKey: .type)
            self.name = try container.decode(String.self, forKey: .name)
            self.probability = try GenerateSchema.decodeProbability(from: container, forKey: .probability)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("predicate", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(probability, forKey: .probability)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case name
            case probability
        }
    }

    // parity: schema/src/generate.ts#ChoiceAnswer [status=implemented hash=83ff9461f095]
    public struct ChoiceAnswer: Equatable, Hashable, Sendable, Codable {
        public struct Entry: Equatable, Hashable, Sendable, Codable {
            public let value: ChoiceValue
            public let probability: Double

            public init(value: ChoiceValue, probability: Double) {
                self.value = value
                self.probability = probability
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.value = try container.decode(ChoiceValue.self, forKey: .value)
                self.probability = try GenerateSchema.decodeProbability(from: container, forKey: .probability)
            }

            enum CodingKeys: String, CodingKey {
                case value
                case probability
            }
        }

        public let name: String
        public let choice: ChoiceValue
        public let probabilities: [Entry]
        public let confidence: Double

        public init(name: String, choice: ChoiceValue, probabilities: [Entry], confidence: Double) {
            self.name = name
            self.choice = choice
            self.probabilities = probabilities
            self.confidence = confidence
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("choice", from: container, forKey: .type)
            self.name = try container.decode(String.self, forKey: .name)
            self.choice = try container.decode(ChoiceValue.self, forKey: .choice)
            self.probabilities = try container.decode([Entry].self, forKey: .probabilities)
            self.confidence = try GenerateSchema.decodeProbability(from: container, forKey: .confidence)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("choice", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(choice, forKey: .choice)
            try container.encode(probabilities, forKey: .probabilities)
            try container.encode(confidence, forKey: .confidence)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case name
            case choice
            case probabilities
            case confidence
        }
    }

    // parity: schema/src/generate.ts#ScoreAnswer [status=implemented hash=46f1116be975]
    public struct ScoreAnswer: Equatable, Hashable, Sendable, Codable {
        public struct Entry: Equatable, Hashable, Sendable, Codable {
            public let value: Int
            public let label: String
            public let probability: Double

            public init(value: Int, label: String, probability: Double) {
                self.value = value
                self.label = label
                self.probability = probability
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.value = try container.decode(Int.self, forKey: .value)
                self.label = try container.decode(String.self, forKey: .label)
                self.probability = try GenerateSchema.decodeProbability(from: container, forKey: .probability)
            }

            enum CodingKeys: String, CodingKey {
                case value
                case label
                case probability
            }
        }

        public let name: String
        public let score: Double
        public let probabilities: [Entry]
        public let confidence: Double

        public init(name: String, score: Double, probabilities: [Entry], confidence: Double) {
            self.name = name
            self.score = score
            self.probabilities = probabilities
            self.confidence = confidence
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("score", from: container, forKey: .type)
            self.name = try container.decode(String.self, forKey: .name)
            self.score = try SchemaPrimitive.decodeFinite(from: container, forKey: .score)
            self.probabilities = try container.decode([Entry].self, forKey: .probabilities)
            self.confidence = try GenerateSchema.decodeProbability(from: container, forKey: .confidence)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("score", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(score, forKey: .score)
            try container.encode(probabilities, forKey: .probabilities)
            try container.encode(confidence, forKey: .confidence)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case name
            case score
            case probabilities
            case confidence
        }
    }

    // parity: schema/src/generate.ts#ErrorAnswer [status=implemented hash=53975b1c4906]
    public struct ErrorAnswer: Equatable, Hashable, Sendable, Codable {
        public let name: String
        public let reason: String
        public let message: String?

        public init(name: String, reason: String, message: String? = nil) {
            self.name = name
            self.reason = reason
            self.message = message
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("error", from: container, forKey: .type)
            self.name = try container.decode(String.self, forKey: .name)
            self.reason = try container.decode(String.self, forKey: .reason)
            self.message = try container.decodeIfPresent(String.self, forKey: .message)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("error", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(reason, forKey: .reason)
            try container.encodeIfPresent(message, forKey: .message)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case name
            case reason
            case message
        }
    }

    // parity: schema/src/generate.ts#DecisionAnswer [status=implemented hash=5535eb90cb82]
    public enum DecisionAnswer: Equatable, Hashable, Sendable, Codable {
        case predicate(PredicateAnswer)
        case choice(ChoiceAnswer)
        case score(ScoreAnswer)
        case error(ErrorAnswer)

        enum TagKeys: String, CodingKey {
            case type
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: TagKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "predicate":
                self = .predicate(try PredicateAnswer(from: decoder))
            case "choice":
                self = .choice(try ChoiceAnswer(from: decoder))
            case "score":
                self = .score(try ScoreAnswer(from: decoder))
            case "error":
                self = .error(try ErrorAnswer(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown Generate.DecisionAnswer type '\(type)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .predicate(let v):
                try v.encode(to: encoder)
            case .choice(let v):
                try v.encode(to: encoder)
            case .score(let v):
                try v.encode(to: encoder)
            case .error(let v):
                try v.encode(to: encoder)
            }
        }
    }

    // parity: schema/src/generate.ts#DecisionResult [status=implemented hash=b4a78b9ad235]
    public struct DecisionResult: Equatable, Hashable, Sendable, Codable {
        public let answers: [DecisionAnswer]
        public let cost: MoneySchema.USD?
        public let tokens: Usage?
        public let native: Native?

        public init(
            answers: [DecisionAnswer],
            cost: MoneySchema.USD? = nil,
            tokens: Usage? = nil,
            native: Native? = nil
        ) {
            self.answers = answers
            self.cost = cost
            self.tokens = tokens
            self.native = native
        }
    }
}
