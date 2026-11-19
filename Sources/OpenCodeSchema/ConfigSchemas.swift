/// Pure Swift 6.2 configuration schemas.
/// Ports `packages/schema/src/config.ts` and all 20 files in `packages/schema/src/config/*`.
/// 100% pure Swift standard library (zero OS imports, zero Foundation imports).

// MARK: - src/config/flag.ts

public enum ConfigFlagSchema {
    /// The `OPENCODE_FLAGS` entry that enables all flags except opt-in-only flags, as in `all,-media_blob`.
    // parity: schema/src/config/flag.ts#wildcard [status=implemented hash=290ac391d6eb]
    public static let wildcard: String = "all"

    /// Known experimental feature flag keys.
    // parity: schema/src/config/flag.ts#Key [status=implemented hash=6ef13bd3704b]
    public enum Key: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case todo
        case mediaBlob = "media_blob"
        case automations
        case artifacts
        case videoGenerate = "video_generate"
        case consoleWatches = "console_watches"
        case mcpEvents = "mcp_events"
        case fullCodemode = "full_codemode"
    }

    /// Registry mapping each feature flag key to its human-readable description.
    // parity: schema/src/config/flag.ts#registry [status=implemented hash=9abbe7f406ab]
    public static let registry: [Key: String] = [
        .todo:
            "Enable the experimental todowrite tool. Off by default in every build, including local and dev; opt in with OPENCODE_FLAGS=todo or experimental.todo: true.",
        .mediaBlob:
            "Store new session media once in a deduplicated blob table instead of inline in every message row.",
        .automations:
            "Run a prompt or Code Mode action on a timer, or on a connected MCP server's push event when mcp_events is enabled.",
        .artifacts:
            "Enable experimental artifacts backed by pluggable providers.",
        .videoGenerate:
            "Enable the experimental video generation API.",
        .consoleWatches:
            "Watch Slack threads, GitHub pull requests, issues, commits and Actions runs, and the workspace's MCP servers' events through OpenCode Console, and wake sessions when they change.",
        .mcpEvents:
            "Enable experimental MCP Events, a draft MCP extension: declare support to MCP servers and read the events of servers that offer them.",
        .fullCodemode:
            "Enable the full Code Mode work in progress. Off by default in every build, including local and dev; opt in with OPENCODE_FLAGS=full_codemode or experimental.full_codemode: true.",
    ]

    /// Flags that require explicit opt-in across every build channel (skipped by `all` and `all_flags`).
    // parity: schema/src/config/flag.ts#optInOnly [status=implemented hash=cdad59fd4508]
    public static let optInOnly: Set<Key> = [.todo, .fullCodemode]

    /// Legacy flag names mapped to their canonical flag key.
    // parity: schema/src/config/flag.ts#aliases [status=implemented hash=40e4d64669eb]
    public static let aliases: [String: Key] = [
        "schedules": .automations,
    ]
}

// MARK: - src/config/model.ts

public enum ConfigModelSchema {
    /// Model selection decoding either `"providerID/model#variant"` or `{ providerID, model, variant? }`
    /// and encoding as the explicit object representation.
    // parity: schema/src/config/model.ts#Selection [status=implemented hash=8263bd95b59e]
    public struct Selection: Equatable, Hashable, Sendable, Codable {
        public let providerID: ProviderSchema.ID
        public let model: ModelSchema.ID
        public let variant: ModelSchema.VariantID?

        public init(
            providerID: ProviderSchema.ID,
            model: ModelSchema.ID,
            variant: ModelSchema.VariantID? = nil
        ) {
            self.providerID = providerID
            self.model = model
            self.variant = variant
        }

        public static func parse(_ input: String) throws(SchemaPrimitive.ValidationError) -> Selection {
            let ref = try ModelSchema.Ref.parse(input)
            return Selection(providerID: ref.providerID, model: ref.id, variant: ref.variant)
        }

        public init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(),
               let short = try? single.decode(String.self)
            {
                do {
                    self = try Selection.parse(short)
                    return
                } catch {
                    throw DecodingError.dataCorruptedError(
                        in: single,
                        debugDescription: "Invalid short model selection '\(short)'"
                    )
                }
            }

            let container = try decoder.container(keyedBy: CodingKeys.self)
            let providerID = try container.decode(ProviderSchema.ID.self, forKey: .providerID)
            let model = try container.decode(ModelSchema.ID.self, forKey: .model)
            let variant = try container.decodeIfPresent(ModelSchema.VariantID.self, forKey: .variant)

            guard !providerID.rawValue.isEmpty,
                  !providerID.rawValue.contains("/"),
                  !providerID.rawValue.contains("#")
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .providerID,
                    in: container,
                    debugDescription: "Invalid providerID '\(providerID.rawValue)'"
                )
            }
            guard !model.rawValue.isEmpty, !model.rawValue.contains("#") else {
                throw DecodingError.dataCorruptedError(
                    forKey: .model,
                    in: container,
                    debugDescription: "Invalid model '\(model.rawValue)'"
                )
            }
            if let variant, variant.rawValue.isEmpty || variant.rawValue.contains("#") {
                throw DecodingError.dataCorruptedError(
                    forKey: .variant,
                    in: container,
                    debugDescription: "Invalid variant '\(variant.rawValue)'"
                )
            }

            self.providerID = providerID
            self.model = model
            self.variant = variant
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(providerID, forKey: .providerID)
            try container.encode(model, forKey: .model)
            try container.encodeIfPresent(variant, forKey: .variant)
        }

        enum CodingKeys: String, CodingKey {
            case providerID
            case model
            case variant
        }
    }
}

// MARK: - src/config/policy.ts

public enum ConfigPolicySchema {
    // parity: schema/src/config/policy.ts#Effect [status=implemented hash=3c0a578c6438]
    public enum Effect: String, Equatable, Hashable, Sendable, Codable {
        case allow
        case deny
    }

    // parity: schema/src/config/policy.ts#Action [status=implemented hash=2798573e5cc6]
    public enum Action: String, Equatable, Hashable, Sendable, Codable {
        case providerUse = "provider.use"
        case toolUse = "tool.use"
        case integrationConnect = "integration.connect"
        case integrationUse = "integration.use"
        case mcpUse = "mcp.use"
        case skillUse = "skill.use"
        case pluginUse = "plugin.use"
        case websearchUse = "websearch.use"
    }

    private static let legacyPrefixMap: [String: Action] = [
        "mcp": .mcpUse,
        "skill": .skillUse,
        "plugin": .pluginUse,
    ]

    /// Policy statement. Automatically normalizes legacy `integration.use` prefixed with
    /// `mcp:`, `skill:`, or `plugin:` into `mcp.use`, `skill.use`, and `plugin.use`.
    // parity: schema/src/config/policy.ts#Info [status=implemented hash=c8dc5bd5761d]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public let action: Action
        public let resource: String
        public let effect: Effect

        public init(action: Action, resource: String, effect: Effect) {
            self.action = action
            self.resource = resource
            self.effect = effect
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let rawAction = try container.decode(Action.self, forKey: .action)
            let rawResource = try container.decode(String.self, forKey: .resource)
            let effect = try container.decode(Effect.self, forKey: .effect)

            if rawAction == .integrationUse,
               let colon = rawResource.firstIndex(of: ":")
            {
                let prefix = String(rawResource[..<colon])
                if let normalized = ConfigPolicySchema.legacyPrefixMap[prefix] {
                    let restStart = rawResource.index(after: colon)
                    self.action = normalized
                    self.resource = String(rawResource[restStart...])
                    self.effect = effect
                    return
                }
            }

            self.action = rawAction
            self.resource = rawResource
            self.effect = effect
        }

        enum CodingKeys: String, CodingKey {
            case action
            case resource
            case effect
        }
    }
}

// MARK: - src/config/provider.ts

public enum ConfigProviderSchema {
    /// Open-ended provider settings (`Provider.Settings` + arbitrary JSON extra keys).
    // parity: schema/src/config/provider.ts#Settings [status=implemented hash=d105e3493570]
    public typealias Settings = ProviderSchema.Settings

    /// Open-ended model settings (`Model.Settings` + arbitrary JSON extra keys).
    // parity: schema/src/config/provider.ts#ModelSettings [status=implemented hash=266b120f8332]
    public typealias ModelSettings = ModelSchema.Settings

    /// Shared provider overlay fields (`settings`, `headers`, `body`).
    // parity: schema/src/config/provider.ts#Overlays [status=implemented hash=d36807f81d7c]
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

    // parity: schema/src/config/provider.ts#Request [status=implemented hash=bd0248542b3f]
    public struct Request: Equatable, Hashable, Sendable, Codable {
        public let headers: [String: String]?
        public let body: [String: JSONValue]?

        public init(headers: [String: String]? = nil, body: [String: JSONValue]? = nil) {
            self.headers = headers
            self.body = body
        }
    }

    public struct CostCache: Equatable, Hashable, Sendable, Codable {
        public let read: MoneySchema.USDPerMillionTokens?
        public let write: MoneySchema.USDPerMillionTokens?

        public init(read: MoneySchema.USDPerMillionTokens? = nil, write: MoneySchema.USDPerMillionTokens? = nil) {
            self.read = read
            self.write = write
        }
    }

    public struct CostTier: Equatable, Hashable, Sendable, Codable {
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

    public struct Cost: Equatable, Hashable, Sendable, Codable {
        public let tier: CostTier?
        public let input: MoneySchema.USDPerMillionTokens
        public let output: MoneySchema.USDPerMillionTokens
        public let cache: CostCache?

        public init(
            tier: CostTier? = nil,
            input: MoneySchema.USDPerMillionTokens,
            output: MoneySchema.USDPerMillionTokens,
            cache: CostCache? = nil
        ) {
            self.tier = tier
            self.input = input
            self.output = output
            self.cache = cache
        }
    }

    public enum CostValue: Equatable, Hashable, Sendable, Codable {
        case single(Cost)
        case tiered([Cost])

        public init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let arr = try? single.decode([Cost].self) {
                self = .tiered(arr)
            } else {
                self = .single(try single.decode(Cost.self))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var single = encoder.singleValueContainer()
            switch self {
            case .single(let c):
                try single.encode(c)
            case .tiered(let arr):
                try single.encode(arr)
            }
        }
    }

    public struct Limit: Equatable, Hashable, Sendable, Codable {
        public let context: Int?
        public let input: Int?
        public let output: Int?

        public init(context: Int? = nil, input: Int? = nil, output: Int? = nil) {
            self.context = context
            self.input = input
            self.output = output
        }
    }

    public struct ReasoningBudget: Equatable, Hashable, Sendable, Codable {
        public let min: Int?
        public let max: Int?

        public init(min: Int? = nil, max: Int? = nil) {
            self.min = min
            self.max = max
        }
    }

    /// models.dev v2's `capabilities.reasoning`.
    // parity: schema/src/config/provider.ts#Reasoning [status=implemented hash=c763fbd05f30]
    public enum Reasoning: Equatable, Hashable, Sendable, Codable {
        case unsupported
        case supported(toggle: Bool? = nil, effort: [String]? = nil, budget: ReasoningBudget? = nil)

        enum CodingKeys: String, CodingKey {
            case supported
            case toggle
            case effort
            case budget
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let isSupported = try container.decode(Bool.self, forKey: .supported)
            if !isSupported {
                self = .unsupported
            } else {
                let toggle = try container.decodeIfPresent(Bool.self, forKey: .toggle)
                let effort = try container.decodeIfPresent([String].self, forKey: .effort)
                let budget = try container.decodeIfPresent(ReasoningBudget.self, forKey: .budget)
                self = .supported(toggle: toggle, effort: effort, budget: budget)
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .unsupported:
                try container.encode(false, forKey: .supported)
            case .supported(let toggle, let effort, let budget):
                try container.encode(true, forKey: .supported)
                try container.encodeIfPresent(toggle, forKey: .toggle)
                try container.encodeIfPresent(effort, forKey: .effort)
                try container.encodeIfPresent(budget, forKey: .budget)
            }
        }
    }

    public struct ModelCapabilities: Equatable, Hashable, Sendable, Codable {
        public let tools: Bool?
        public let freeform: [ToolSchema.FreeformFormat]?
        public let input: [String]?
        public let output: [String]?
        public let temperature: Bool?
        public let reasoning: Reasoning?

        public init(
            tools: Bool? = nil,
            freeform: [ToolSchema.FreeformFormat]? = nil,
            input: [String]? = nil,
            output: [String]? = nil,
            temperature: Bool? = nil,
            reasoning: Reasoning? = nil
        ) {
            self.tools = tools
            self.freeform = freeform
            self.input = input
            self.output = output
            self.temperature = temperature
            self.reasoning = reasoning
        }
    }

    public struct VariantConfig: Equatable, Hashable, Sendable, Codable {
        public let id: ModelSchema.VariantID
        public let settings: ModelSchema.VariantSettings?
        public let headers: [String: String]?
        public let body: [String: JSONValue]?

        public init(
            id: ModelSchema.VariantID,
            settings: ModelSchema.VariantSettings? = nil,
            headers: [String: String]? = nil,
            body: [String: JSONValue]? = nil
        ) {
            self.id = id
            self.settings = settings
            self.headers = headers
            self.body = body
        }
    }

    public struct ModelConfig: Equatable, Hashable, Sendable, Codable {
        public let modelID: ModelSchema.ID?
        public let type: ModelSchema.ModelType?
        public let family: ModelSchema.Family?
        public let name: String?
        public let releaseDate: String?
        public let compatibility: ModelCompatibilitySchema.Compatibility?
        public let package: String?
        public let settings: ModelSettings?
        public let headers: [String: String]?
        public let body: [String: JSONValue]?
        public let capabilities: ModelCapabilities?
        public let variants: [VariantConfig]?
        public let cost: CostValue?
        public let disabled: Bool?
        public let limit: Limit?

        public init(
            modelID: ModelSchema.ID? = nil,
            type: ModelSchema.ModelType? = nil,
            family: ModelSchema.Family? = nil,
            name: String? = nil,
            releaseDate: String? = nil,
            compatibility: ModelCompatibilitySchema.Compatibility? = nil,
            package: String? = nil,
            settings: ModelSettings? = nil,
            headers: [String: String]? = nil,
            body: [String: JSONValue]? = nil,
            capabilities: ModelCapabilities? = nil,
            variants: [VariantConfig]? = nil,
            cost: CostValue? = nil,
            disabled: Bool? = nil,
            limit: Limit? = nil
        ) {
            self.modelID = modelID
            self.type = type
            self.family = family
            self.name = name
            self.releaseDate = releaseDate
            self.compatibility = compatibility
            self.package = package
            self.settings = settings
            self.headers = headers
            self.body = body
            self.capabilities = capabilities
            self.variants = variants
            self.cost = cost
            self.disabled = disabled
            self.limit = limit
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.modelID = try container.decodeIfPresent(ModelSchema.ID.self, forKey: .modelID)
            self.type = try container.decodeIfPresent(ModelSchema.ModelType.self, forKey: .type)
            self.family = try container.decodeIfPresent(ModelSchema.Family.self, forKey: .family)
            self.name = try container.decodeIfPresent(String.self, forKey: .name)
            if let rd = try container.decodeIfPresent(String.self, forKey: .releaseDate) {
                guard SchemaPrimitive.isReleaseDate(rd) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .releaseDate,
                        in: container,
                        debugDescription: "Invalid releaseDate '\(rd)', expected YYYY-MM or YYYY-MM-DD"
                    )
                }
                self.releaseDate = rd
            } else {
                self.releaseDate = nil
            }
            self.compatibility = try container.decodeIfPresent(
                ModelCompatibilitySchema.Compatibility.self,
                forKey: .compatibility
            )
            self.package = try container.decodeIfPresent(String.self, forKey: .package)
            self.settings = try container.decodeIfPresent(ModelSettings.self, forKey: .settings)
            self.headers = try container.decodeIfPresent([String: String].self, forKey: .headers)
            self.body = try container.decodeIfPresent([String: JSONValue].self, forKey: .body)
            self.capabilities = try container.decodeIfPresent(ModelCapabilities.self, forKey: .capabilities)
            self.variants = try container.decodeIfPresent([VariantConfig].self, forKey: .variants)
            self.cost = try container.decodeIfPresent(CostValue.self, forKey: .cost)
            self.disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled)
            self.limit = try container.decodeIfPresent(Limit.self, forKey: .limit)
        }

        enum CodingKeys: String, CodingKey {
            case modelID
            case type
            case family
            case name
            case releaseDate
            case compatibility
            case package
            case settings
            case headers
            case body
            case capabilities
            case variants
            case cost
            case disabled
            case limit
        }
    }

    // parity: schema/src/config/provider.ts#Info [status=implemented hash=62bc3fe458d4]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public let canonical: ProviderSchema.ID?
        public let name: String?
        public let env: [String]?
        public let package: String?
        public let compatibility: ModelCompatibilitySchema.ProviderCompatibility?
        public let settings: Settings?
        public let headers: [String: String]?
        public let body: [String: JSONValue]?
        public let models: [String: ModelConfig]?

        public init(
            canonical: ProviderSchema.ID? = nil,
            name: String? = nil,
            env: [String]? = nil,
            package: String? = nil,
            compatibility: ModelCompatibilitySchema.ProviderCompatibility? = nil,
            settings: Settings? = nil,
            headers: [String: String]? = nil,
            body: [String: JSONValue]? = nil,
            models: [String: ModelConfig]? = nil
        ) {
            self.canonical = canonical
            self.name = name
            self.env = env
            self.package = package
            self.compatibility = compatibility
            self.settings = settings
            self.headers = headers
            self.body = body
            self.models = models
        }
    }
}

// MARK: - src/config/agent.ts

public enum ConfigAgentSchema {
    /// Hex color string matching `^#[0-9a-fA-F]{6}$`.
    // parity: schema/src/config/agent.ts#Color [status=implemented hash=0b295df1bde7]
    public struct Color: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public init?(rawValue: String) {
            guard SchemaPrimitive.isHexColor(rawValue) else { return nil }
            self.rawValue = rawValue
        }

        public init(validating value: String) throws(SchemaPrimitive.ValidationError) {
            guard SchemaPrimitive.isHexColor(value) else {
                throw .invalidFormat(expected: "^#[0-9a-fA-F]{6}$", actual: value)
            }
            self.rawValue = value
        }

        public var description: String { rawValue }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard SchemaPrimitive.isHexColor(value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid hex color '\(value)'"
                )
            }
            self.rawValue = value
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    // parity: schema/src/config/agent.ts#Info [status=implemented hash=fa245cb8df47]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public enum Mode: String, Equatable, Hashable, Sendable, Codable {
            case subagent
            case primary
            case all
        }

        public let model: ConfigModelSchema.Selection?
        public let request: ConfigProviderSchema.Request?
        public let system: String?
        public let description: String?
        public let mode: Mode?
        public let hidden: Bool?
        public let color: Color?
        public let steps: SchemaPrimitive.PositiveInt?
        public let disabled: Bool?
        public let permissions: PermissionSchema.Ruleset?

        public init(
            model: ConfigModelSchema.Selection? = nil,
            request: ConfigProviderSchema.Request? = nil,
            system: String? = nil,
            description: String? = nil,
            mode: Mode? = nil,
            hidden: Bool? = nil,
            color: Color? = nil,
            steps: SchemaPrimitive.PositiveInt? = nil,
            disabled: Bool? = nil,
            permissions: PermissionSchema.Ruleset? = nil
        ) {
            self.model = model
            self.request = request
            self.system = system
            self.description = description
            self.mode = mode
            self.hidden = hidden
            self.color = color
            self.steps = steps
            self.disabled = disabled
            self.permissions = permissions
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.model = try container.decodeIfPresent(ConfigModelSchema.Selection.self, forKey: .model)
            self.request = try container.decodeIfPresent(ConfigProviderSchema.Request.self, forKey: .request)
            self.system = try container.decodeIfPresent(String.self, forKey: .system)
            self.description = try container.decodeIfPresent(String.self, forKey: .description)
            self.mode = try container.decodeIfPresent(Mode.self, forKey: .mode)
            self.hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden)
            // Forgiving decode: an unsupported color (such as a V1 theme name) decodes as nil rather than dropping the agent.
            if container.contains(.color) {
                self.color = try? container.decodeIfPresent(Color.self, forKey: .color)
            } else {
                self.color = nil
            }
            self.steps = try container.decodeIfPresent(SchemaPrimitive.PositiveInt.self, forKey: .steps)
            self.disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled)
            self.permissions = try container.decodeIfPresent(PermissionSchema.Ruleset.self, forKey: .permissions)
        }

        enum CodingKeys: String, CodingKey {
            case model
            case request
            case system
            case description
            case mode
            case hidden
            case color
            case steps
            case disabled
            case permissions
        }
    }
}

// MARK: - src/config/command.ts

public enum ConfigCommandSchema {
    // parity: schema/src/config/command.ts#Info [status=implemented hash=37a0361f3f31]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public let template: String
        public let description: String?
        public let agent: String?
        public let model: ConfigModelSchema.Selection?
        public let subagent: Bool?
        public let subtask: Bool?

        public init(
            template: String,
            description: String? = nil,
            agent: String? = nil,
            model: ConfigModelSchema.Selection? = nil,
            subagent: Bool? = nil,
            subtask: Bool? = nil
        ) {
            self.template = template
            self.description = description
            self.agent = agent
            self.model = model
            self.subagent = subagent
            self.subtask = subtask
        }
    }
}

// MARK: - src/config/compaction.ts

public enum ConfigCompactionSchema {
    // parity: schema/src/config/compaction.ts#Keep [status=implemented hash=572805bf0b7f]
    public struct Keep: Equatable, Hashable, Sendable, Codable {
        public let tokens: SchemaPrimitive.NonNegativeInt?

        public init(tokens: SchemaPrimitive.NonNegativeInt? = nil) {
            self.tokens = tokens
        }
    }

    /// Percentage string from "1%" up to "99.9...%" matching `^([1-9]\d?(\.\d+)?)%$`.
    // parity: schema/src/config/compaction.ts#Percent [status=implemented hash=fa18ee74b8cd]
    public struct Percent: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public init?(rawValue: String) {
            guard SchemaPrimitive.isCompactionPercent(rawValue) else { return nil }
            self.rawValue = rawValue
        }

        public init(validating value: String) throws(SchemaPrimitive.ValidationError) {
            guard SchemaPrimitive.isCompactionPercent(value) else {
                throw .invalidFormat(expected: "^([1-9]\\d?(\\.\\d+)?)%$", actual: value)
            }
            self.rawValue = value
        }

        public var description: String { rawValue }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard SchemaPrimitive.isCompactionPercent(value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid compaction percent '\(value)'"
                )
            }
            self.rawValue = value
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    public enum Buffer: Equatable, Hashable, Sendable, Codable {
        case percent(Percent)
        case tokens(SchemaPrimitive.NonNegativeInt)

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let pct = try? container.decode(Percent.self) {
                self = .percent(pct)
            } else if let n = try? container.decode(SchemaPrimitive.NonNegativeInt.self) {
                self = .tokens(n)
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected compaction Percent string or NonNegativeInt token count"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .percent(let p):
                try container.encode(p)
            case .tokens(let n):
                try container.encode(n)
            }
        }
    }

    // parity: schema/src/config/compaction.ts#Info [status=implemented hash=0851ad15973d]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public let auto: Bool?
        public let background: Bool?
        public let keep: Keep?
        public let buffer: Buffer?

        public init(
            auto: Bool? = nil,
            background: Bool? = nil,
            keep: Keep? = nil,
            buffer: Buffer? = nil
        ) {
            self.auto = auto
            self.background = background
            self.keep = keep
            self.buffer = buffer
        }
    }
}

// MARK: - src/config/experimental.ts

public enum ConfigExperimentalSchema {
    public struct ImageGenerateOptions: Equatable, Hashable, Sendable, Codable {
        public let model: ConfigModelSchema.Selection?

        public init(model: ConfigModelSchema.Selection? = nil) {
            self.model = model
        }
    }

    public enum ImageGenerate: Equatable, Hashable, Sendable, Codable {
        case enabled(Bool)
        case configured(ImageGenerateOptions)

        public init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let flag = try? single.decode(Bool.self) {
                self = .enabled(flag)
            } else {
                self = .configured(try single.decode(ImageGenerateOptions.self))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var single = encoder.singleValueContainer()
            switch self {
            case .enabled(let flag):
                try single.encode(flag)
            case .configured(let options):
                try single.encode(options)
            }
        }
    }

    public enum LocationIdleTimeout: Equatable, Hashable, Sendable, Codable {
        case duration(String)
        case disabled

        public init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let boolVal = try? single.decode(Bool.self) {
                guard boolVal == false else {
                    throw DecodingError.dataCorruptedError(
                        in: single,
                        debugDescription: "Expected duration string or false for location_idle_timeout, got true"
                    )
                }
                self = .disabled
                return
            }
            let str = try single.decode(String.self)
            guard AutomationSchema.durationMillis(str) != nil else {
                throw DecodingError.dataCorruptedError(
                    in: single,
                    debugDescription: "Invalid duration string '\(str)' for location_idle_timeout"
                )
            }
            self = .duration(str)
        }

        public func encode(to encoder: Encoder) throws {
            var single = encoder.singleValueContainer()
            switch self {
            case .duration(let s):
                try single.encode(s)
            case .disabled:
                try single.encode(false)
            }
        }
    }

    // parity: schema/src/config/experimental.ts#Info [status=implemented hash=b1c1008367eb]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public let portableShellScanner: Bool?
        public let codemodeVM: Bool?
        public let allFlags: Bool?
        public let todo: Bool?
        public let mediaBlob: Bool?
        public let automations: Bool?
        public let artifacts: Bool?
        public let videoGenerate: Bool?
        public let consoleWatches: Bool?
        public let mcpEvents: Bool?
        public let fullCodemode: Bool?
        public let schedules: Bool?
        public let partRows: Bool?
        public let imageGenerate: ImageGenerate?
        public let subagentDepth: SchemaPrimitive.NonNegativeInt?
        public let locationIdleTimeout: LocationIdleTimeout?
        public let policies: [ConfigPolicySchema.Info]?

        public init(
            portableShellScanner: Bool? = nil,
            codemodeVM: Bool? = nil,
            allFlags: Bool? = nil,
            todo: Bool? = nil,
            mediaBlob: Bool? = nil,
            automations: Bool? = nil,
            artifacts: Bool? = nil,
            videoGenerate: Bool? = nil,
            consoleWatches: Bool? = nil,
            mcpEvents: Bool? = nil,
            fullCodemode: Bool? = nil,
            schedules: Bool? = nil,
            partRows: Bool? = nil,
            imageGenerate: ImageGenerate? = nil,
            subagentDepth: SchemaPrimitive.NonNegativeInt? = nil,
            locationIdleTimeout: LocationIdleTimeout? = nil,
            policies: [ConfigPolicySchema.Info]? = nil
        ) {
            self.portableShellScanner = portableShellScanner
            self.codemodeVM = codemodeVM
            self.allFlags = allFlags
            self.todo = todo
            self.mediaBlob = mediaBlob
            self.automations = automations
            self.artifacts = artifacts
            self.videoGenerate = videoGenerate
            self.consoleWatches = consoleWatches
            self.mcpEvents = mcpEvents
            self.fullCodemode = fullCodemode
            self.schedules = schedules
            self.partRows = partRows
            self.imageGenerate = imageGenerate
            self.subagentDepth = subagentDepth
            self.locationIdleTimeout = locationIdleTimeout
            self.policies = policies
        }

        public func flagValue(for key: ConfigFlagSchema.Key) -> Bool? {
            switch key {
            case .todo: return todo
            case .mediaBlob: return mediaBlob
            case .automations: return automations
            case .artifacts: return artifacts
            case .videoGenerate: return videoGenerate
            case .consoleWatches: return consoleWatches
            case .mcpEvents: return mcpEvents
            case .fullCodemode: return fullCodemode
            }
        }

        enum CodingKeys: String, CodingKey {
            case portableShellScanner = "portable_shell_scanner"
            case codemodeVM = "codemode_vm"
            case allFlags = "all_flags"
            case todo
            case mediaBlob = "media_blob"
            case automations
            case artifacts
            case videoGenerate = "video_generate"
            case consoleWatches = "console_watches"
            case mcpEvents = "mcp_events"
            case fullCodemode = "full_codemode"
            case schedules
            case partRows = "part_rows"
            case imageGenerate = "image_generate"
            case subagentDepth = "subagent_depth"
            case locationIdleTimeout = "location_idle_timeout"
            case policies
        }
    }
}

// MARK: - src/config/formatter.ts

public enum ConfigFormatterSchema {
    // parity: schema/src/config/formatter.ts#Entry [status=implemented hash=3b73e50565cd]
    public struct Entry: Equatable, Hashable, Sendable, Codable {
        public let disabled: Bool?
        public let command: [String]?
        public let environment: [String: String]?
        public let extensions: [String]?

        public init(
            disabled: Bool? = nil,
            command: [String]? = nil,
            environment: [String: String]? = nil,
            extensions: [String]? = nil
        ) {
            self.disabled = disabled
            self.command = command
            self.environment = environment
            self.extensions = extensions
        }
    }

    // parity: schema/src/config/formatter.ts#Info [status=implemented hash=b87d2633c081]
    public enum Info: Equatable, Hashable, Sendable, Codable {
        case enabled(Bool)
        case overrides([String: Entry])

        public init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let flag = try? single.decode(Bool.self) {
                self = .enabled(flag)
            } else {
                self = .overrides(try single.decode([String: Entry].self))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var single = encoder.singleValueContainer()
            switch self {
            case .enabled(let flag):
                try single.encode(flag)
            case .overrides(let map):
                try single.encode(map)
            }
        }
    }
}

// MARK: - src/config/lsp.ts

public enum ConfigLSPSchema {
    // parity: schema/src/config/lsp.ts#Disabled [status=implemented hash=7419512d601f]
    public struct Disabled: Equatable, Hashable, Sendable, Codable {
        public let disabled: Bool

        public init() {
            self.disabled = true
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let flag = try container.decode(Bool.self, forKey: .disabled)
            guard flag == true else {
                throw DecodingError.dataCorruptedError(
                    forKey: .disabled,
                    in: container,
                    debugDescription: "Expected disabled: true"
                )
            }
            self.disabled = true
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(true, forKey: .disabled)
        }

        enum CodingKeys: String, CodingKey {
            case disabled
        }
    }

    // parity: schema/src/config/lsp.ts#Server [status=implemented hash=03471fb91849]
    public struct Server: Equatable, Hashable, Sendable, Codable {
        public let command: [String]
        public let extensions: [String]?
        public let disabled: Bool?
        public let env: [String: String]?
        public let initialization: [String: JSONValue]?

        public init(
            command: [String],
            extensions: [String]? = nil,
            disabled: Bool? = nil,
            env: [String: String]? = nil,
            initialization: [String: JSONValue]? = nil
        ) {
            self.command = command
            self.extensions = extensions
            self.disabled = disabled
            self.env = env
            self.initialization = initialization
        }
    }

    // parity: schema/src/config/lsp.ts#Entry [status=implemented hash=5e89f0d437e0]
    public enum Entry: Equatable, Hashable, Sendable, Codable {
        case disabled(Disabled)
        case server(Server)

        enum ProbeKeys: String, CodingKey {
            case command
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: ProbeKeys.self)
            if container.contains(.command) {
                self = .server(try Server(from: decoder))
            } else {
                self = .disabled(try Disabled(from: decoder))
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .disabled(let d):
                try d.encode(to: encoder)
            case .server(let s):
                try s.encode(to: encoder)
            }
        }
    }

    // parity: schema/src/config/lsp.ts#Info [status=implemented hash=b87d2633c081]
    public enum Info: Equatable, Hashable, Sendable, Codable {
        case enabled(Bool)
        case servers([String: Entry])

        public init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let flag = try? single.decode(Bool.self) {
                self = .enabled(flag)
            } else {
                self = .servers(try single.decode([String: Entry].self))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var single = encoder.singleValueContainer()
            switch self {
            case .enabled(let flag):
                try single.encode(flag)
            case .servers(let map):
                try single.encode(map)
            }
        }
    }
}

// MARK: - src/config/mcp.ts

public enum ConfigMCPSchema {
    // parity: schema/src/config/mcp.ts#Timeout [status=implemented hash=e1062912adde]
    public typealias Timeout = McpSchema.TimeoutConfig

    // parity: schema/src/config/mcp.ts#Local [status=implemented hash=c388d1390cbc]
    public typealias Local = McpSchema.LocalConfig

    // parity: schema/src/config/mcp.ts#OAuth [status=implemented hash=f87533bbbc61]
    public typealias OAuth = McpSchema.OAuthConfig

    // parity: schema/src/config/mcp.ts#Remote [status=implemented hash=feb3f429f6a4]
    public typealias Remote = McpSchema.RemoteConfig

    // parity: schema/src/config/mcp.ts#Server [status=implemented hash=903d559667e4]
    public typealias Server = McpSchema.ServerConfig

    // parity: schema/src/config/mcp.ts#Protocol [status=implemented hash=1f6c14823bea]
    public typealias WireProtocol = McpSchema.WireProtocol

    // parity: schema/src/config/mcp.ts#Info [status=implemented hash=241335f1b75e]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public let timeout: Timeout?
        public let servers: [String: Server]?

        public init(timeout: Timeout? = nil, servers: [String: Server]? = nil) {
            self.timeout = timeout
            self.servers = servers
        }
    }
}

// MARK: - src/config/media.ts

public enum ConfigMediaSchema {
    // parity: schema/src/config/media.ts#Image [status=implemented hash=10bb2a04f22c]
    public struct Image: Equatable, Hashable, Sendable, Codable {
        public let autoResize: Bool?
        public let maxWidth: SchemaPrimitive.PositiveInt?
        public let maxHeight: SchemaPrimitive.PositiveInt?
        public let maxBase64Bytes: SchemaPrimitive.PositiveInt?

        public init(
            autoResize: Bool? = nil,
            maxWidth: SchemaPrimitive.PositiveInt? = nil,
            maxHeight: SchemaPrimitive.PositiveInt? = nil,
            maxBase64Bytes: SchemaPrimitive.PositiveInt? = nil
        ) {
            self.autoResize = autoResize
            self.maxWidth = maxWidth
            self.maxHeight = maxHeight
            self.maxBase64Bytes = maxBase64Bytes
        }

        enum CodingKeys: String, CodingKey {
            case autoResize = "auto_resize"
            case maxWidth = "max_width"
            case maxHeight = "max_height"
            case maxBase64Bytes = "max_base64_bytes"
        }
    }

    // parity: schema/src/config/media.ts#Info [status=implemented hash=1cfd8f564e65]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public let image: Image?

        public init(image: Image? = nil) {
            self.image = image
        }
    }
}

// MARK: - src/config/plugin.ts

public enum ConfigPluginSchema {
    // parity: schema/src/config/plugin.ts#Entry [status=implemented hash=1d991bb1959b]
    public struct Entry: Equatable, Hashable, Sendable, Codable {
        public let package: String
        public let options: [String: JSONValue]?

        public init(package: String, options: [String: JSONValue]? = nil) {
            self.package = package
            self.options = options
        }
    }

    // parity: schema/src/config/plugin.ts#Plugin [status=implemented hash=bebef55fd90d]
    public enum Plugin: Equatable, Hashable, Sendable, Codable {
        case specifier(String)
        case entry(Entry)

        public init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let str = try? single.decode(String.self) {
                self = .specifier(str)
            } else {
                self = .entry(try single.decode(Entry.self))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var single = encoder.singleValueContainer()
            switch self {
            case .specifier(let str):
                try single.encode(str)
            case .entry(let entry):
                try single.encode(entry)
            }
        }
    }

    // parity: schema/src/config/plugin.ts#Plugins [status=implemented hash=7b0c3eaf6d52]
    public typealias Plugins = [Plugin]
}

// MARK: - src/config/reference.ts

public enum ConfigReferenceSchema {
    // parity: schema/src/config/reference.ts#Git [status=implemented hash=c9678fc30660]
    public struct Git: Equatable, Hashable, Sendable, Codable {
        public let repository: String
        public let branch: String?
        public let description: String?
        public let hidden: Bool?

        public init(
            repository: String,
            branch: String? = nil,
            description: String? = nil,
            hidden: Bool? = nil
        ) {
            self.repository = repository
            self.branch = branch
            self.description = description
            self.hidden = hidden
        }
    }

    // parity: schema/src/config/reference.ts#Local [status=implemented hash=8980b6d277e7]
    public struct Local: Equatable, Hashable, Sendable, Codable {
        public let path: String
        public let description: String?
        public let hidden: Bool?

        public init(path: String, description: String? = nil, hidden: Bool? = nil) {
            self.path = path
            self.description = description
            self.hidden = hidden
        }
    }

    // parity: schema/src/config/reference.ts#Entry [status=implemented hash=c326a9b6dcf1]
    public enum Entry: Equatable, Hashable, Sendable, Codable {
        case string(String)
        case git(Git)
        case local(Local)

        enum ProbeKeys: String, CodingKey {
            case repository
            case path
        }

        public init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(),
               let s = try? single.decode(String.self)
            {
                self = .string(s)
                return
            }
            let container = try decoder.container(keyedBy: ProbeKeys.self)
            if container.contains(.repository) {
                self = .git(try Git(from: decoder))
            } else if container.contains(.path) {
                self = .local(try Local(from: decoder))
            } else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Expected String, Git ({ repository }), or Local ({ path }) reference entry"
                    )
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .string(let s):
                var single = encoder.singleValueContainer()
                try single.encode(s)
            case .git(let g):
                try g.encode(to: encoder)
            case .local(let l):
                try l.encode(to: encoder)
            }
        }
    }

    // parity: schema/src/config/reference.ts#Info [status=implemented hash=4f148c7e6368]
    public typealias Info = [String: Entry]
}

// MARK: - src/config/shell.ts

public enum ConfigShellSchema {
    // parity: schema/src/config/shell.ts#Option [status=implemented hash=139beeda63f3]
    public struct Option: Equatable, Hashable, Sendable, Codable {
        public let path: String
        public let name: String
        public let acceptable: Bool

        public init(path: String, name: String, acceptable: Bool) {
            self.path = path
            self.name = name
            self.acceptable = acceptable
        }
    }
}

// MARK: - src/config/tool-output.ts

public enum ConfigToolOutputSchema {
    // parity: schema/src/config/tool-output.ts#Info [status=implemented hash=a8fef01f89f2]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public let maxLines: SchemaPrimitive.PositiveInt?
        public let maxBytes: SchemaPrimitive.PositiveInt?

        public init(
            maxLines: SchemaPrimitive.PositiveInt? = nil,
            maxBytes: SchemaPrimitive.PositiveInt? = nil
        ) {
            self.maxLines = maxLines
            self.maxBytes = maxBytes
        }

        enum CodingKeys: String, CodingKey {
            case maxLines = "max_lines"
            case maxBytes = "max_bytes"
        }
    }
}

// MARK: - src/config/warming.ts

public enum ConfigWarmingSchema {
    public enum Interval: Equatable, Hashable, Sendable, Codable {
        case auto
        case duration(String)

        public init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            let str = try single.decode(String.self)
            if str == "auto" {
                self = .auto
                return
            }
            guard AutomationSchema.durationMillis(str) != nil else {
                throw DecodingError.dataCorruptedError(
                    in: single,
                    debugDescription: "Expected 'auto' or duration string for warming interval, got '\(str)'"
                )
            }
            self = .duration(str)
        }

        public func encode(to encoder: Encoder) throws {
            var single = encoder.singleValueContainer()
            switch self {
            case .auto:
                try single.encode("auto")
            case .duration(let s):
                try single.encode(s)
            }
        }
    }

    // parity: schema/src/config/warming.ts#Info [status=implemented hash=ac9ff30d364b]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public let prompt: String?
        public let interval: Interval?
        public let duration: String?

        public init(prompt: String? = nil, interval: Interval? = nil, duration: String? = nil) {
            self.prompt = prompt
            self.interval = interval
            self.duration = duration
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
            self.interval = try container.decodeIfPresent(Interval.self, forKey: .interval)
            if let dur = try container.decodeIfPresent(String.self, forKey: .duration) {
                guard AutomationSchema.durationMillis(dur) != nil else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .duration,
                        in: container,
                        debugDescription: "Invalid duration string '\(dur)' for warming duration"
                    )
                }
                self.duration = dur
            } else {
                self.duration = nil
            }
        }

        enum CodingKeys: String, CodingKey {
            case prompt
            case interval
            case duration
        }
    }

    // parity: schema/src/config/warming.ts#Warming [status=implemented hash=122fae94ae6b]
    public enum Warming: Equatable, Hashable, Sendable, Codable {
        case enabled(Bool)
        case configured(Info)

        public init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let flag = try? single.decode(Bool.self) {
                self = .enabled(flag)
            } else {
                self = .configured(try single.decode(Info.self))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var single = encoder.singleValueContainer()
            switch self {
            case .enabled(let flag):
                try single.encode(flag)
            case .configured(let info):
                try single.encode(info)
            }
        }
    }
}

// MARK: - src/config/watcher.ts

public enum ConfigWatcherSchema {
    // parity: schema/src/config/watcher.ts#Info [status=implemented hash=e5a332052074]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public let ignore: [String]?

        public init(ignore: [String]? = nil) {
            self.ignore = ignore
        }
    }
}

// MARK: - src/config/websearch.ts

public enum ConfigWebSearchSchema {
    public enum ProviderChoice: Equatable, Hashable, Sendable, Codable {
        case random
        case provider(WebSearchSchema.ID)

        public init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            let raw = try single.decode(String.self)
            if raw == "random" {
                self = .random
            } else {
                self = .provider(WebSearchSchema.ID(rawValue: raw))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var single = encoder.singleValueContainer()
            switch self {
            case .random:
                try single.encode("random")
            case .provider(let id):
                try single.encode(id)
            }
        }
    }

    // parity: schema/src/config/websearch.ts#Info [status=implemented hash=fe2b87c5fa9e]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public let provider: ProviderChoice

        public init(provider: ProviderChoice) {
            self.provider = provider
        }
    }

    // parity: schema/src/config/websearch.ts#Selection [status=implemented hash=7e36effa086d]
    public enum Selection: Equatable, Hashable, Sendable, Codable {
        case disabled
        case enabled(Info)

        public init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let flag = try? single.decode(Bool.self) {
                guard flag == false else {
                    throw DecodingError.dataCorruptedError(
                        in: single,
                        debugDescription: "Expected false or ConfigWebSearch.Info, got true"
                    )
                }
                self = .disabled
            } else {
                self = .enabled(try single.decode(Info.self))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var single = encoder.singleValueContainer()
            switch self {
            case .disabled:
                try single.encode(false)
            case .enabled(let info):
                try single.encode(info)
            }
        }
    }
}

// MARK: - src/config/worktree.ts

public enum ConfigWorktreeSchema {
    // parity: schema/src/config/worktree.ts#Info [status=implemented hash=4a4087e46737]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public let directory: String

        public init?(directory: String) {
            let trimmed = SchemaPrimitive.trimWhitespace(directory)
            guard !trimmed.isEmpty else { return nil }
            self.directory = trimmed
        }

        public init(validating directory: String) throws(SchemaPrimitive.ValidationError) {
            let trimmed = SchemaPrimitive.trimWhitespace(directory)
            guard !trimmed.isEmpty else { throw .emptyString(field: "directory") }
            self.directory = trimmed
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let raw = try container.decode(String.self, forKey: .directory)
            let trimmed = SchemaPrimitive.trimWhitespace(raw)
            guard !trimmed.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .directory,
                    in: container,
                    debugDescription: "Worktree directory must be non-empty after trimming"
                )
            }
            self.directory = trimmed
        }

        enum CodingKeys: String, CodingKey {
            case directory
        }
    }
}

// MARK: - src/config.ts

public enum ConfigSchema {
    public enum UpdateMode: String, Equatable, Hashable, Sendable, Codable {
        case disable
        case notify
        case auto
    }

    public enum ShareMode: String, Equatable, Hashable, Sendable, Codable {
        case manual
        case auto
        case disabled
    }

    public struct Enterprise: Equatable, Hashable, Sendable, Codable {
        public let url: String?

        public init(url: String? = nil) {
            self.url = url
        }
    }

    // parity: schema/src/config.ts#Info [status=implemented hash=7066d2a4ea13]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public let schema: String?
        public let shell: String?
        public let model: ConfigModelSchema.Selection?
        public let defaultAgent: String?
        public let update: UpdateMode?
        public let share: ShareMode?
        public let enterprise: Enterprise?
        public let username: String?
        public let timezone: String?
        public let permissions: PermissionSchema.Ruleset?
        public let policies: [ConfigPolicySchema.Info]?
        public let agents: [String: ConfigAgentSchema.Info]?
        public let snapshots: Bool?
        public let watcher: ConfigWatcherSchema.Info?
        public let formatter: ConfigFormatterSchema.Info?
        public let lsp: ConfigLSPSchema.Info?
        public let media: ConfigMediaSchema.Info?
        public let toolOutput: ConfigToolOutputSchema.Info?
        public let mcp: ConfigMCPSchema.Info?
        public let compaction: ConfigCompactionSchema.Info?
        public let skills: [String]?
        public let commands: [String: ConfigCommandSchema.Info]?
        public let instructions: [String]?
        public let references: ConfigReferenceSchema.Info?
        public let websearch: ConfigWebSearchSchema.Selection?
        public let plugins: ConfigPluginSchema.Plugins?
        public let worktree: ConfigWorktreeSchema.Info?
        public let warming: ConfigWarmingSchema.Warming?
        public let providers: [String: ConfigProviderSchema.Info]?
        public let experimental: ConfigExperimentalSchema.Info?

        public init(
            schema: String? = nil,
            shell: String? = nil,
            model: ConfigModelSchema.Selection? = nil,
            defaultAgent: String? = nil,
            update: UpdateMode? = nil,
            share: ShareMode? = nil,
            enterprise: Enterprise? = nil,
            username: String? = nil,
            timezone: String? = nil,
            permissions: PermissionSchema.Ruleset? = nil,
            policies: [ConfigPolicySchema.Info]? = nil,
            agents: [String: ConfigAgentSchema.Info]? = nil,
            snapshots: Bool? = nil,
            watcher: ConfigWatcherSchema.Info? = nil,
            formatter: ConfigFormatterSchema.Info? = nil,
            lsp: ConfigLSPSchema.Info? = nil,
            media: ConfigMediaSchema.Info? = nil,
            toolOutput: ConfigToolOutputSchema.Info? = nil,
            mcp: ConfigMCPSchema.Info? = nil,
            compaction: ConfigCompactionSchema.Info? = nil,
            skills: [String]? = nil,
            commands: [String: ConfigCommandSchema.Info]? = nil,
            instructions: [String]? = nil,
            references: ConfigReferenceSchema.Info? = nil,
            websearch: ConfigWebSearchSchema.Selection? = nil,
            plugins: ConfigPluginSchema.Plugins? = nil,
            worktree: ConfigWorktreeSchema.Info? = nil,
            warming: ConfigWarmingSchema.Warming? = nil,
            providers: [String: ConfigProviderSchema.Info]? = nil,
            experimental: ConfigExperimentalSchema.Info? = nil
        ) {
            self.schema = schema
            self.shell = shell
            self.model = model
            self.defaultAgent = defaultAgent
            self.update = update
            self.share = share
            self.enterprise = enterprise
            self.username = username
            self.timezone = timezone
            self.permissions = permissions
            self.policies = policies
            self.agents = agents
            self.snapshots = snapshots
            self.watcher = watcher
            self.formatter = formatter
            self.lsp = lsp
            self.media = media
            self.toolOutput = toolOutput
            self.mcp = mcp
            self.compaction = compaction
            self.skills = skills
            self.commands = commands
            self.instructions = instructions
            self.references = references
            self.websearch = websearch
            self.plugins = plugins
            self.worktree = worktree
            self.warming = warming
            self.providers = providers
            self.experimental = experimental
        }

        enum CodingKeys: String, CodingKey {
            case schema = "$schema"
            case shell
            case model
            case defaultAgent = "default_agent"
            case update
            case share
            case enterprise
            case username
            case timezone
            case permissions
            case policies
            case agents
            case snapshots
            case watcher
            case formatter
            case lsp
            case media
            case toolOutput = "tool_output"
            case mcp
            case compaction
            case skills
            case commands
            case instructions
            case references
            case websearch
            case plugins
            case worktree
            case warming
            case providers
            case experimental
        }
    }

    // parity: schema/src/config.ts#Patch [status=implemented hash=699b5cf95877]
    public struct Patch: Equatable, Hashable, Sendable, Codable {
        public let shell: String?

        public init(shell: String?) {
            self.shell = shell
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.shell = try container.decode(String?.self, forKey: .shell)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(shell, forKey: .shell)
        }

        enum CodingKeys: String, CodingKey {
            case shell
        }
    }

    // parity: schema/src/config.ts#Document [status=implemented hash=86c10fc0e0e8]
    public struct Document: Equatable, Hashable, Sendable, Codable {
        public let path: SchemaPrimitive.AbsolutePath?
        public let info: Info

        public init(path: SchemaPrimitive.AbsolutePath? = nil, info: Info) {
            self.path = path
            self.info = info
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("document", from: container, forKey: .type)
            self.path = try container.decodeIfPresent(SchemaPrimitive.AbsolutePath.self, forKey: .path)
            self.info = try container.decode(Info.self, forKey: .info)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("document", forKey: .type)
            try container.encodeIfPresent(path, forKey: .path)
            try container.encode(info, forKey: .info)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case path
            case info
        }
    }

    // parity: schema/src/config.ts#Directory [status=implemented hash=0de1b05525bb]
    public struct Directory: Equatable, Hashable, Sendable, Codable {
        public let path: SchemaPrimitive.AbsolutePath

        public init(path: SchemaPrimitive.AbsolutePath) {
            self.path = path
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("directory", from: container, forKey: .type)
            self.path = try container.decode(SchemaPrimitive.AbsolutePath.self, forKey: .path)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("directory", forKey: .type)
            try container.encode(path, forKey: .path)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case path
        }
    }

    // parity: schema/src/config.ts#Entry [status=implemented hash=c3fe837cf934]
    public enum Entry: Equatable, Hashable, Sendable, Codable {
        case document(Document)
        case directory(Directory)

        enum TagKeys: String, CodingKey {
            case type
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: TagKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "document":
                self = .document(try Document(from: decoder))
            case "directory":
                self = .directory(try Directory(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown Config.Entry type '\(type)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .document(let d):
                try d.encode(to: encoder)
            case .directory(let d):
                try d.encode(to: encoder)
            }
        }
    }

    // parity: schema/src/config.ts#Event [status=implemented hash=e7550d251b3a]
    public enum Event {
        public static let updated = SchemaPrimitive.EventDescriptor.ephemeral(type: "config.updated")
        public static let definitions: [SchemaPrimitive.EventDescriptor] = [updated]
    }
}
