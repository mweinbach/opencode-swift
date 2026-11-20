#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import OpenCodeSchema
import OpenCodeUtil

/// V1 configuration schemas and V1-to-V2 configuration migrators (agents, commands, MCP servers,
/// permissions, plugins, providers, and provider/model options).
///
/// Ports all 8 files in `packages/core/src/v1/config/*.ts`.
public enum CoreV1Config {
    // MARK: - v1/config/permission.ts

    public enum Permission {
        // parity: core/src/v1/config/permission.ts#Action [status=implemented hash=2d8ea0231497]
        public enum Action: String, Equatable, Hashable, Sendable, Codable {
            case ask
            case allow
            case deny
        }

        public struct Entry<Value: Equatable & Hashable & Sendable & Codable>: Equatable, Hashable, Sendable, Codable {
            public let key: String
            public let value: Value

            public init(key: String, value: Value) {
                self.key = key
                self.value = value
            }
        }

        /// Codec returned by `entriesCodec(_:)` matching upstream `Entries(value)` schema factory.
        public struct EntriesCodec<Value: Equatable & Hashable & Sendable & Codable>: Sendable {
            public init() {}

            public func decode(_ data: Data) throws -> Entries<Value> {
                let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("{") else {
                    throw DecodingError.typeMismatch(
                        Entries<Value>.self,
                        DecodingError.Context(codingPath: [], debugDescription: "Expected a JSON object, not an array or scalar")
                    )
                }
                return try JSONDecoder().decode(Entries<Value>.self, from: data)
            }

            public func decode(jsonString: String) throws -> Entries<Value> {
                try decode(Data(jsonString.utf8))
            }

            public func decode(entries pairs: [(String, Value)]) -> Entries<Value> {
                Entries(pairs.map { Entry(key: $0.0, value: $0.1) })
            }

            public func encode(_ value: Entries<Value>) throws -> Data {
                try JSONEncoder().encode(value)
            }

            public func toDictionary(_ value: Entries<Value>) -> [String: Value] {
                var out: [String: Value] = [:]
                for entry in value.entries {
                    out[entry.key] = entry.value
                }
                return out
            }
        }

        /// Factory mirroring upstream `Entries(value)` schema codec constructor (rejects arrays, preserves entry order).
        // parity: core/src/v1/config/permission.ts#Entries [status=implemented hash=38aed2c80e79]
        public static func entriesCodec<Value: Equatable & Hashable & Sendable & Codable>(
            _ valueType: Value.Type
        ) -> EntriesCodec<Value> {
            _ = valueType
            return EntriesCodec<Value>()
        }

        /// Ordered key-value entries preserving author-written permission rule order (last-match-wins).
        public struct Entries<Value: Equatable & Hashable & Sendable & Codable>: Equatable, Hashable, Sendable, Codable {
            public let entries: [Entry<Value>]

            public init(_ entries: [Entry<Value>] = []) {
                self.entries = entries
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: SchemaPrimitive.AnyCodingKey.self)
                var list: [Entry<Value>] = []
                for key in container.allKeys {
                    list.append(Entry(key: key.stringValue, value: try container.decode(Value.self, forKey: key)))
                }
                self.entries = list
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: SchemaPrimitive.AnyCodingKey.self)
                for entry in entries {
                    try container.encode(entry.value, forKey: .init(entry.key))
                }
            }
        }

        // parity: core/src/v1/config/permission.ts#Object [status=implemented hash=6c1e2974f00e]
        public typealias Object = Entries<Action>

        // parity: core/src/v1/config/permission.ts#Rule [status=implemented hash=b75d4de9b7da]
        public enum Rule: Equatable, Hashable, Sendable, Codable {
            case action(Action)
            case object(Object)

            public init(from decoder: Decoder) throws {
                if let single = try? decoder.singleValueContainer(),
                   let act = try? single.decode(Action.self)
                {
                    self = .action(act)
                    return
                }
                self = .object(try Object(from: decoder))
            }

            public func encode(to encoder: Encoder) throws {
                switch self {
                case .action(let act):
                    var single = encoder.singleValueContainer()
                    try single.encode(act)
                case .object(let obj):
                    try obj.encode(to: encoder)
                }
            }
        }

        private static let actionOnlyKeys: Set<String> = ["question", "websearch", "doom_loop"]

        // parity: core/src/v1/config/permission.ts#Info [status=implemented hash=996697d6a602]
        public struct Info: Equatable, Hashable, Sendable, Codable {
            public let rules: [Entry<Rule>]

            public init(_ rules: [Entry<Rule>] = []) {
                self.rules = rules
            }

            public init(from decoder: Decoder) throws {
                if let single = try? decoder.singleValueContainer(),
                   let act = try? single.decode(Action.self)
                {
                    self.rules = [Entry(key: "*", value: .action(act))]
                    return
                }
                let decoded = try Entries<Rule>(from: decoder)
                for entry in decoded.entries where Permission.actionOnlyKeys.contains(entry.key) {
                    guard case .action = entry.value else {
                        throw DecodingError.dataCorrupted(
                            DecodingError.Context(
                                codingPath: decoder.codingPath,
                                debugDescription: "question, websearch, and doom_loop must be ask, allow, or deny"
                            )
                        )
                    }
                }
                self.rules = decoded.entries
            }

            public func encode(to encoder: Encoder) throws {
                try Entries(rules).encode(to: encoder)
            }
        }
    }

    // MARK: - v1/config/agent.ts

    public enum Agent {
        // parity: core/src/v1/config/agent.ts#Info [status=implemented hash=cc78c718dd1c]
        public struct Info: Equatable, Hashable, Sendable, Codable {
            public let model: String?
            public let variant: String?
            public let temperature: Double?
            public let topP: Double?
            public let prompt: String?
            public let tools: Permission.Entries<Bool>?
            public let disable: Bool?
            public let description: String?
            public let mode: ConfigAgentSchema.Info.Mode?
            public let hidden: Bool?
            public let options: [String: JSONValue]
            public let color: String?
            public let steps: SchemaPrimitive.PositiveInt?
            public let maxSteps: SchemaPrimitive.PositiveInt?
            public let permission: Permission.Info?

            private static let knownKeys: Set<String> = [
                "name", "model", "variant", "temperature", "top_p", "prompt", "tools",
                "disable", "description", "mode", "hidden", "options", "color", "steps",
                "maxSteps", "permission",
            ]

            public init(
                model: String? = nil,
                variant: String? = nil,
                temperature: Double? = nil,
                topP: Double? = nil,
                prompt: String? = nil,
                tools: Permission.Entries<Bool>? = nil,
                disable: Bool? = nil,
                description: String? = nil,
                mode: ConfigAgentSchema.Info.Mode? = nil,
                hidden: Bool? = nil,
                options: [String: JSONValue] = [:],
                color: String? = nil,
                steps: SchemaPrimitive.PositiveInt? = nil,
                maxSteps: SchemaPrimitive.PositiveInt? = nil,
                permission: Permission.Info? = nil
            ) {
                self.model = model
                self.variant = variant
                self.temperature = temperature
                self.topP = topP
                self.prompt = prompt
                self.tools = tools
                self.disable = disable
                self.description = description
                self.mode = mode
                self.hidden = hidden
                self.options = options
                self.color = color
                self.steps = steps ?? maxSteps
                self.maxSteps = maxSteps
                self.permission = Self.mergePermissions(tools: tools, permission: permission)
            }

            private static func mergePermissions(
                tools: Permission.Entries<Bool>?,
                permission: Permission.Info?
            ) -> Permission.Info? {
                guard tools != nil || permission != nil else { return nil }
                var order: [String] = []
                var map: [String: Permission.Rule] = [:]
                for entry in tools?.entries ?? [] {
                    let key = (entry.key == "write" || entry.key == "patch") ? "edit" : entry.key
                    if map[key] == nil { order.append(key) }
                    map[key] = .action(entry.value ? .allow : .deny)
                }
                for entry in permission?.rules ?? [] {
                    if map[entry.key] == nil { order.append(entry.key) }
                    map[entry.key] = entry.value
                }
                return Permission.Info(order.compactMap { k in map[k].map { Permission.Entry(key: k, value: $0) } })
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: SchemaPrimitive.AnyCodingKey.self)
                let model = try container.decodeIfPresent(String.self, forKey: .init("model"))
                let variant = try container.decodeIfPresent(String.self, forKey: .init("variant"))
                let temperature = try container.decodeIfPresent(Double.self, forKey: .init("temperature"))
                let topP = try container.decodeIfPresent(Double.self, forKey: .init("top_p"))
                let prompt = try container.decodeIfPresent(String.self, forKey: .init("prompt"))
                let tools = try container.decodeIfPresent(Permission.Entries<Bool>.self, forKey: .init("tools"))
                let disable = try container.decodeIfPresent(Bool.self, forKey: .init("disable"))
                let description = try container.decodeIfPresent(String.self, forKey: .init("description"))
                let mode = try container.decodeIfPresent(ConfigAgentSchema.Info.Mode.self, forKey: .init("mode"))
                let hidden = try container.decodeIfPresent(Bool.self, forKey: .init("hidden"))
                var opts = try container.decodeIfPresent([String: JSONValue].self, forKey: .init("options")) ?? [:]
                for key in container.allKeys where !Self.knownKeys.contains(key.stringValue) {
                    opts[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
                }
                let color = try container.decodeIfPresent(String.self, forKey: .init("color"))
                let steps = try container.decodeIfPresent(SchemaPrimitive.PositiveInt.self, forKey: .init("steps"))
                let maxSteps = try container.decodeIfPresent(SchemaPrimitive.PositiveInt.self, forKey: .init("maxSteps"))
                let permission = try container.decodeIfPresent(Permission.Info.self, forKey: .init("permission"))

                self.init(
                    model: model,
                    variant: variant,
                    temperature: temperature,
                    topP: topP,
                    prompt: prompt,
                    tools: tools,
                    disable: disable,
                    description: description,
                    mode: mode,
                    hidden: hidden,
                    options: opts,
                    color: color,
                    steps: steps,
                    maxSteps: maxSteps,
                    permission: permission
                )
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: SchemaPrimitive.AnyCodingKey.self)
                try container.encodeIfPresent(model, forKey: .init("model"))
                try container.encodeIfPresent(variant, forKey: .init("variant"))
                try container.encodeIfPresent(temperature, forKey: .init("temperature"))
                try container.encodeIfPresent(topP, forKey: .init("top_p"))
                try container.encodeIfPresent(prompt, forKey: .init("prompt"))
                try container.encodeIfPresent(tools, forKey: .init("tools"))
                try container.encodeIfPresent(disable, forKey: .init("disable"))
                try container.encodeIfPresent(description, forKey: .init("description"))
                try container.encodeIfPresent(mode, forKey: .init("mode"))
                try container.encodeIfPresent(hidden, forKey: .init("hidden"))
                if !options.isEmpty { try container.encode(options, forKey: .init("options")) }
                try container.encodeIfPresent(color, forKey: .init("color"))
                try container.encodeIfPresent(steps, forKey: .init("steps"))
                try container.encodeIfPresent(permission, forKey: .init("permission"))
            }
        }
    }

    // MARK: - v1/config/command.ts

    public enum Command {
        // parity: core/src/v1/config/command.ts#Info [status=implemented hash=61d97abbd398]
        public struct Info: Equatable, Hashable, Sendable, Codable {
            public let template: String
            public let description: String?
            public let agent: String?
            public let model: String?
            public let variant: String?
            public let subtask: Bool?

            public init(
                template: String,
                description: String? = nil,
                agent: String? = nil,
                model: String? = nil,
                variant: String? = nil,
                subtask: Bool? = nil
            ) {
                self.template = template
                self.description = description
                self.agent = agent
                self.model = model
                self.variant = variant
                self.subtask = subtask
            }
        }
    }

    // MARK: - v1/config/mcp.ts

    public enum MCP {
        // parity: core/src/v1/config/mcp.ts#Local [status=implemented hash=2b3d9c2811ee]
        public struct Local: Equatable, Hashable, Sendable, Codable {
            public let command: [String]
            public let cwd: String?
            public let environment: [String: String]?
            public let enabled: Bool?
            public let codemode: Bool?
            public let timeout: Int?

            public init(
                command: [String],
                cwd: String? = nil,
                environment: [String: String]? = nil,
                enabled: Bool? = nil,
                codemode: Bool? = nil,
                timeout: Int? = nil
            ) {
                self.command = command
                self.cwd = cwd
                self.environment = environment
                self.enabled = enabled
                self.codemode = codemode
                self.timeout = timeout
            }

            enum CodingKeys: String, CodingKey {
                case type, command, cwd, environment, enabled, codemode, timeout
            }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let type = try c.decode(String.self, forKey: .type)
                guard type == "local" else {
                    throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Expected type 'local', got '\(type)'")
                }
                self.command = try c.decode([String].self, forKey: .command)
                self.cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
                self.environment = try c.decodeIfPresent([String: String].self, forKey: .environment)
                self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
                self.codemode = try c.decodeIfPresent(Bool.self, forKey: .codemode)
                self.timeout = try c.decodeIfPresent(Int.self, forKey: .timeout)
            }

            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode("local", forKey: .type)
                try c.encode(command, forKey: .command)
                try c.encodeIfPresent(cwd, forKey: .cwd)
                try c.encodeIfPresent(environment, forKey: .environment)
                try c.encodeIfPresent(enabled, forKey: .enabled)
                try c.encodeIfPresent(codemode, forKey: .codemode)
                try c.encodeIfPresent(timeout, forKey: .timeout)
            }
        }

        // parity: core/src/v1/config/mcp.ts#OAuth [status=implemented hash=d1bb2f84a211]
        public struct OAuth: Equatable, Hashable, Sendable, Codable {
            public let clientId: String?
            public let clientSecret: String?
            public let scope: String?
            public let callbackPort: Int?
            public let redirectUri: String?

            public init(
                clientId: String? = nil,
                clientSecret: String? = nil,
                scope: String? = nil,
                callbackPort: Int? = nil,
                redirectUri: String? = nil
            ) {
                self.clientId = clientId
                self.clientSecret = clientSecret
                self.scope = scope
                self.callbackPort = callbackPort
                self.redirectUri = redirectUri
            }
        }

        public enum OAuthOption: Equatable, Hashable, Sendable, Codable {
            case config(OAuth)
            case disabled

            public init(from decoder: Decoder) throws {
                if let single = try? decoder.singleValueContainer(),
                   let b = try? single.decode(Bool.self),
                   b == false
                {
                    self = .disabled
                    return
                }
                self = .config(try OAuth(from: decoder))
            }

            public func encode(to encoder: Encoder) throws {
                switch self {
                case .disabled:
                    var single = encoder.singleValueContainer()
                    try single.encode(false)
                case .config(let oauth):
                    try oauth.encode(to: encoder)
                }
            }
        }

        // parity: core/src/v1/config/mcp.ts#Remote [status=implemented hash=7ad13d579ef7]
        public struct Remote: Equatable, Hashable, Sendable, Codable {
            public let url: String
            public let enabled: Bool?
            public let codemode: Bool?
            public let headers: [String: String]?
            public let oauth: OAuthOption?
            public let timeout: Int?

            public init(
                url: String,
                enabled: Bool? = nil,
                codemode: Bool? = nil,
                headers: [String: String]? = nil,
                oauth: OAuthOption? = nil,
                timeout: Int? = nil
            ) {
                self.url = url
                self.enabled = enabled
                self.codemode = codemode
                self.headers = headers
                self.oauth = oauth
                self.timeout = timeout
            }

            enum CodingKeys: String, CodingKey {
                case type, url, enabled, codemode, headers, oauth, timeout
            }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let type = try c.decode(String.self, forKey: .type)
                guard type == "remote" else {
                    throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Expected type 'remote', got '\(type)'")
                }
                self.url = try c.decode(String.self, forKey: .url)
                self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
                self.codemode = try c.decodeIfPresent(Bool.self, forKey: .codemode)
                self.headers = try c.decodeIfPresent([String: String].self, forKey: .headers)
                self.oauth = try c.decodeIfPresent(OAuthOption.self, forKey: .oauth)
                self.timeout = try c.decodeIfPresent(Int.self, forKey: .timeout)
            }

            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode("remote", forKey: .type)
                try c.encode(url, forKey: .url)
                try c.encodeIfPresent(enabled, forKey: .enabled)
                try c.encodeIfPresent(codemode, forKey: .codemode)
                try c.encodeIfPresent(headers, forKey: .headers)
                try c.encodeIfPresent(oauth, forKey: .oauth)
                try c.encodeIfPresent(timeout, forKey: .timeout)
            }
        }

        // parity: core/src/v1/config/mcp.ts#Info [status=implemented hash=ffd8c858b673]
        public enum Info: Equatable, Hashable, Sendable, Codable {
            case local(Local)
            case remote(Remote)

            enum TagKeys: String, CodingKey { case type }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: TagKeys.self)
                let type = try c.decode(String.self, forKey: .type)
                switch type {
                case "local": self = .local(try Local(from: decoder))
                case "remote": self = .remote(try Remote(from: decoder))
                default:
                    throw DecodingError.dataCorruptedError(
                        forKey: .type,
                        in: c,
                        debugDescription: "Unknown V1 MCP type '\(type)'"
                    )
                }
            }

            public func encode(to encoder: Encoder) throws {
                switch self {
                case .local(let v): try v.encode(to: encoder)
                case .remote(let v): try v.encode(to: encoder)
                }
            }
        }
    }

    // MARK: - v1/config/plugin.ts

    public enum Plugin {
        // parity: core/src/v1/config/plugin.ts#Options [status=implemented hash=9034f93295ba]
        public typealias Options = [String: JSONValue]

        // parity: core/src/v1/config/plugin.ts#Spec [status=implemented hash=a11c620d2db5]
        public enum Spec: Equatable, Hashable, Sendable, Codable {
            case package(String)
            case packageWithOptions(String, Options)

            public init(from decoder: Decoder) throws {
                if let single = try? decoder.singleValueContainer(),
                   let str = try? single.decode(String.self)
                {
                    self = .package(str)
                    return
                }
                var unkeyed = try decoder.unkeyedContainer()
                let pkg = try unkeyed.decode(String.self)
                let opts = try unkeyed.decode(Options.self)
                self = .packageWithOptions(pkg, opts)
            }

            public func encode(to encoder: Encoder) throws {
                switch self {
                case .package(let str):
                    var single = encoder.singleValueContainer()
                    try single.encode(str)
                case .packageWithOptions(let pkg, let opts):
                    var unkeyed = encoder.unkeyedContainer()
                    try unkeyed.encode(pkg)
                    try unkeyed.encode(opts)
                }
            }
        }
    }

    // MARK: - v1/config/provider.ts

    public enum Provider {
        // parity: core/src/v1/config/provider.ts#ModelStatus [status=implemented hash=e55c2d27bb97]
        public enum ModelStatus: String, Equatable, Hashable, Sendable, Codable {
            case alpha
            case beta
            case deprecated
            case active
        }

        public struct CostTier: Equatable, Hashable, Sendable, Codable {
            public let input: Double
            public let output: Double
            public let cacheRead: Double?
            public let cacheWrite: Double?

            public init(input: Double, output: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil) {
                self.input = input
                self.output = output
                self.cacheRead = cacheRead
                self.cacheWrite = cacheWrite
            }

            enum CodingKeys: String, CodingKey {
                case input, output
                case cacheRead = "cache_read"
                case cacheWrite = "cache_write"
            }
        }

        public struct ModelCost: Equatable, Hashable, Sendable, Codable {
            public let input: Double
            public let output: Double
            public let cacheRead: Double?
            public let cacheWrite: Double?
            public let contextOver200k: CostTier?

            public init(
                input: Double,
                output: Double,
                cacheRead: Double? = nil,
                cacheWrite: Double? = nil,
                contextOver200k: CostTier? = nil
            ) {
                self.input = input
                self.output = output
                self.cacheRead = cacheRead
                self.cacheWrite = cacheWrite
                self.contextOver200k = contextOver200k
            }

            enum CodingKeys: String, CodingKey {
                case input, output
                case cacheRead = "cache_read"
                case cacheWrite = "cache_write"
                case contextOver200k = "context_over_200k"
            }
        }

        public struct ModelLimit: Equatable, Hashable, Sendable, Codable {
            public let context: Double?
            public let input: Double?
            public let output: Double?

            public init(context: Double? = nil, input: Double? = nil, output: Double? = nil) {
                self.context = context
                self.input = input
                self.output = output
            }
        }

        public struct ModelModalities: Equatable, Hashable, Sendable, Codable {
            public let input: [String]?
            public let output: [String]?

            public init(input: [String]? = nil, output: [String]? = nil) {
                self.input = input
                self.output = output
            }
        }

        public struct ModelProviderRef: Equatable, Hashable, Sendable, Codable {
            public let npm: String?
            public let api: String?

            public init(npm: String? = nil, api: String? = nil) {
                self.npm = npm
                self.api = api
            }
        }

        // parity: core/src/v1/config/provider.ts#Model [status=implemented hash=c0b7d8ee0354]
        public struct Model: Equatable, Hashable, Sendable, Codable {
            public let id: String?
            public let name: String?
            public let family: String?
            public let releaseDate: String?
            public let attachment: Bool?
            public let reasoning: Bool?
            public let temperature: Bool?
            public let toolCall: Bool?
            public let interleaved: JSONValue?
            public let cost: ModelCost?
            public let limit: ModelLimit?
            public let modalities: ModelModalities?
            public let experimental: Bool?
            public let status: ModelStatus?
            public let provider: ModelProviderRef?
            public let options: [String: JSONValue]?
            public let headers: [String: String]?
            public let variants: [String: [String: JSONValue]]?

            public init(
                id: String? = nil,
                name: String? = nil,
                family: String? = nil,
                releaseDate: String? = nil,
                attachment: Bool? = nil,
                reasoning: Bool? = nil,
                temperature: Bool? = nil,
                toolCall: Bool? = nil,
                interleaved: JSONValue? = nil,
                cost: ModelCost? = nil,
                limit: ModelLimit? = nil,
                modalities: ModelModalities? = nil,
                experimental: Bool? = nil,
                status: ModelStatus? = nil,
                provider: ModelProviderRef? = nil,
                options: [String: JSONValue]? = nil,
                headers: [String: String]? = nil,
                variants: [String: [String: JSONValue]]? = nil
            ) {
                self.id = id
                self.name = name
                self.family = family
                self.releaseDate = releaseDate
                self.attachment = attachment
                self.reasoning = reasoning
                self.temperature = temperature
                self.toolCall = toolCall
                self.interleaved = interleaved
                self.cost = cost
                self.limit = limit
                self.modalities = modalities
                self.experimental = experimental
                self.status = status
                self.provider = provider
                self.options = options
                self.headers = headers
                self.variants = variants
            }

            enum CodingKeys: String, CodingKey {
                case id, name, family
                case releaseDate = "release_date"
                case attachment, reasoning, temperature
                case toolCall = "tool_call"
                case interleaved, cost, limit, modalities, experimental, status, provider, options, headers, variants
            }
        }

        // parity: core/src/v1/config/provider.ts#Info [status=implemented hash=12b218e33e09]
        public struct Info: Equatable, Hashable, Sendable, Codable {
            public let api: String?
            public let name: String?
            public let env: [String]?
            public let id: String?
            public let npm: String?
            public let whitelist: [String]?
            public let blacklist: [String]?
            public let options: [String: JSONValue]?
            public let models: [String: Model]?

            public init(
                api: String? = nil,
                name: String? = nil,
                env: [String]? = nil,
                id: String? = nil,
                npm: String? = nil,
                whitelist: [String]? = nil,
                blacklist: [String]? = nil,
                options: [String: JSONValue]? = nil,
                models: [String: Model]? = nil
            ) {
                self.api = api
                self.name = name
                self.env = env
                self.id = id
                self.npm = npm
                self.whitelist = whitelist
                self.blacklist = blacklist
                self.options = options
                self.models = models
            }
        }
    }

    // MARK: - v1/config/provider-options.ts

    public enum ProviderOptions {
        // parity: core/src/v1/config/provider-options.ts#ProviderResult [status=implemented hash=15b3e416aa97]
        public struct ProviderResult: Equatable, Hashable, Sendable {
            public let settings: [String: JSONValue]
            public let headers: [String: String]?
            public let body: [String: JSONValue]?

            public init(
                settings: [String: JSONValue],
                headers: [String: String]? = nil,
                body: [String: JSONValue]? = nil
            ) {
                self.settings = settings
                self.headers = headers
                self.body = body
            }
        }

        public struct CompatibleModelResult: Equatable, Hashable, Sendable {
            public let settings: [String: JSONValue]
            public let body: [String: JSONValue]?

            public init(settings: [String: JSONValue], body: [String: JSONValue]? = nil) {
                self.settings = settings
                self.body = body
            }
        }

        private static let compatibleKeys: Set<String> = [
            "apiKey",
            "baseURL",
            "headers",
            "body",
            "extraBody",
            "timeout",
            "chunkTimeout",
            "headerTimeout",
            "disabled",
            "reasoningEffort",
            "textVerbosity",
            "user",
            "strictJsonSchema",
        ]

        // parity: core/src/v1/config/provider-options.ts#provider [status=implemented hash=ae708f6ea1c1]
        public static func provider(_ options: [String: JSONValue]) -> ProviderResult {
            var settings: [String: JSONValue] = [:]
            for (k, v) in options where k != "headers" && k != "body" {
                settings[k] = v
            }
            let headers: [String: String]? = if case .object(let h) = options["headers"] {
                h.reduce(into: [String: String]()) { acc, pair in
                    if case .string(let s) = pair.value { acc[pair.key] = s }
                }
            } else {
                nil
            }
            let body: [String: JSONValue]? = if case .object(let b) = options["body"] { b } else { nil }
            return ProviderResult(settings: settings, headers: headers, body: body)
        }

        // parity: core/src/v1/config/provider-options.ts#model [status=implemented hash=818a541d8683]
        public static func model(_ options: [String: JSONValue]) -> [String: JSONValue] {
            options
        }

        // parity: core/src/v1/config/provider-options.ts#compatibleModel [status=implemented hash=16bc4b4dcde7]
        public static func compatibleModel(_ options: [String: JSONValue]) -> CompatibleModelResult {
            var settings: [String: JSONValue] = [:]
            var body: [String: JSONValue] = [:]
            for (k, v) in options {
                if compatibleKeys.contains(k) {
                    settings[k] = v
                } else {
                    body[k] = v
                }
            }
            return CompatibleModelResult(settings: settings, body: body.isEmpty ? nil : body)
        }
    }

    // MARK: - v1/config/migrate.ts

    public enum Migrate {
        public struct MigratedProvider: Equatable, Hashable, Sendable {
            public let name: String?
            public let env: [String]?
            public let package: String?
            public let compatibility: ModelCompatibilitySchema.ProviderCompatibility?
            public let settings: [String: JSONValue]?
            public let headers: [String: String]?
            public let body: [String: JSONValue]?
            public let models: [String: MigratedModel]?

            public init(
                name: String? = nil,
                env: [String]? = nil,
                package: String? = nil,
                compatibility: ModelCompatibilitySchema.ProviderCompatibility? = nil,
                settings: [String: JSONValue]? = nil,
                headers: [String: String]? = nil,
                body: [String: JSONValue]? = nil,
                models: [String: MigratedModel]? = nil
            ) {
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

        public struct MigratedVariant: Equatable, Hashable, Sendable {
            public let id: String
            public let settings: [String: JSONValue]
            public let body: [String: JSONValue]?

            public init(id: String, settings: [String: JSONValue], body: [String: JSONValue]? = nil) {
                self.id = id
                self.settings = settings
                self.body = body
            }
        }

        public struct MigratedModel: Equatable, Hashable, Sendable {
            public let modelID: String?
            public let family: String?
            public let name: String?
            public let compatibility: ModelCompatibilitySchema.Compatibility?
            public let package: String?
            public let settings: [String: JSONValue]?
            public let capabilities: ConfigProviderSchema.ModelCapabilities?
            public let headers: [String: String]?
            public let body: [String: JSONValue]?
            public let variants: [MigratedVariant]?
            public let cost: [ConfigProviderSchema.Cost]?
            public let disabled: Bool?
            public let limit: ConfigProviderSchema.Limit?

            public init(
                modelID: String? = nil,
                family: String? = nil,
                name: String? = nil,
                compatibility: ModelCompatibilitySchema.Compatibility? = nil,
                package: String? = nil,
                settings: [String: JSONValue]? = nil,
                capabilities: ConfigProviderSchema.ModelCapabilities? = nil,
                headers: [String: String]? = nil,
                body: [String: JSONValue]? = nil,
                variants: [MigratedVariant]? = nil,
                cost: [ConfigProviderSchema.Cost]? = nil,
                disabled: Bool? = nil,
                limit: ConfigProviderSchema.Limit? = nil
            ) {
                self.modelID = modelID
                self.family = family
                self.name = name
                self.compatibility = compatibility
                self.package = package
                self.settings = settings
                self.capabilities = capabilities
                self.headers = headers
                self.body = body
                self.variants = variants
                self.cost = cost
                self.disabled = disabled
                self.limit = limit
            }
        }

        /// Maps V1 permission/tool keys onto their renamed V2 tool actions.
        // parity: core/src/v1/config/migrate.ts#normalizeAction [status=implemented hash=b3d51a74d9ed]
        public static func normalizeAction(_ action: String) -> String {
            if action == "write" || action == "patch" || action == "apply_patch" { return "edit" }
            if action == "task" { return "subagent" }
            if action == "bash" { return "shell" }
            return action
        }

        private static func migratePermissions(_ info: Permission.Info?) -> PermissionSchema.Ruleset? {
            guard let rules = info?.rules, !rules.isEmpty else { return nil }
            var out: [PermissionSchema.Rule] = []
            for entry in rules {
                let action = normalizeAction(entry.key)
                switch entry.value {
                case .action(let act):
                    out.append(PermissionSchema.Rule(
                        action: action,
                        resource: "*",
                        effect: mapEffect(act)
                    ))
                case .object(let obj):
                    for sub in obj.entries {
                        out.append(PermissionSchema.Rule(
                            action: action,
                            resource: sub.key,
                            effect: mapEffect(sub.value)
                        ))
                    }
                }
            }
            return out.isEmpty ? nil : out
        }

        private static func mapEffect(_ action: Permission.Action) -> PermissionSchema.Effect {
            switch action {
            case .allow: .allow
            case .deny: .deny
            case .ask: .ask
            }
        }

        /// Migrates a V1 agent configuration into V2 `ConfigAgentSchema.Info`.
        // parity: core/src/v1/config/migrate.ts#migrateAgent [status=implemented hash=79722e6e4a15]
        public static func migrateAgent(_ info: Agent.Info) -> ConfigAgentSchema.Info {
            var body = info.options
            if let temperature = info.temperature { body["temperature"] = .double(temperature) }
            if let topP = info.topP { body["top_p"] = .double(topP) }
            let resolvedColor: ConfigAgentSchema.Color? = info.color.flatMap { raw in
                if raw.hasPrefix("#") {
                    return ConfigAgentSchema.Color(rawValue: raw)
                }
                return ConfigAgentSchema.Color(rawValue: "#aaaaaa")
            }
            return ConfigAgentSchema.Info(
                model: modelSelection(info.model, variant: info.variant),
                request: body.isEmpty ? nil : ConfigProviderSchema.Request(body: body),
                system: info.prompt,
                description: info.description,
                mode: info.mode,
                hidden: info.hidden,
                color: resolvedColor,
                steps: info.steps,
                disabled: info.disable,
                permissions: migratePermissions(info.permission)
            )
        }

        /// Migrates a V1 command definition into V2 `ConfigCommandSchema.Info`.
        // parity: core/src/v1/config/migrate.ts#migrateCommand [status=implemented hash=58d9f6c88e14]
        public static func migrateCommand(_ command: Command.Info) -> ConfigCommandSchema.Info {
            ConfigCommandSchema.Info(
                template: command.template,
                description: command.description,
                agent: command.agent,
                model: modelSelection(command.model, variant: command.variant),
                subagent: command.subtask
            )
        }

        /// Parses a V1 model string + optional variant and applies retired provider ID renames.
        // parity: core/src/v1/config/migrate.ts#modelSelection [status=implemented hash=f7882d47b653]
        public static func modelSelection(_ input: String?, variant: String? = nil) -> ConfigModelSchema.Selection? {
            guard let input, let parsed = try? ConfigModelSchema.Selection.parse(input) else {
                return nil
            }
            let selected = parsed.variant?.rawValue ?? variant
            let cleanVariant: ModelSchema.VariantID? = {
                guard let selected, !selected.isEmpty, !selected.contains("#") else { return nil }
                return ModelSchema.VariantID(rawValue: selected)
            }()
            return ConfigModelSchema.Selection(
                providerID: ProviderSchema.ID(rawValue: providerID(parsed.providerID.rawValue)),
                model: parsed.model,
                variant: cleanVariant
            )
        }

        /// Expands a V1 single MCP timeout into V2 per-phase timeout bounds.
        // parity: core/src/v1/config/migrate.ts#migrateMcpTimeout [status=implemented hash=621c4357eeb0]
        public static func migrateMcpTimeout(_ timeout: Int) -> McpSchema.TimeoutConfig {
            let pos = SchemaPrimitive.PositiveInt(rawValue: max(1, timeout))
            return McpSchema.TimeoutConfig(startup: pos, catalog: pos, execution: pos)
        }

        /// Migrates a V1 MCP server configuration (local or remote) to V2 `McpSchema.ServerConfig`.
        // parity: core/src/v1/config/migrate.ts#migrateMcp [status=implemented hash=a7f0afb28cac]
        public static func migrateMcp(_ info: MCP.Info) -> McpSchema.ServerConfig {
            switch info {
            case .local(let local):
                return .local(McpSchema.LocalConfig(
                    command: local.command,
                    cwd: local.cwd,
                    environment: local.environment,
                    disabled: local.enabled.map { !$0 },
                    codemode: local.codemode,
                    timeout: local.timeout.map(migrateMcpTimeout)
                ))
            case .remote(let remote):
                let oauthOpt: McpSchema.OAuthOption? = remote.oauth.map { opt in
                    switch opt {
                    case .disabled:
                        return .disabled
                    case .config(let oauth):
                        return .configured(McpSchema.OAuthConfig(
                            clientID: oauth.clientId,
                            clientSecret: oauth.clientSecret,
                            scope: oauth.scope,
                            callbackPort: oauth.callbackPort,
                            redirectURI: oauth.redirectUri
                        ))
                    }
                }
                return .remote(McpSchema.RemoteConfig(
                    url: remote.url,
                    headers: remote.headers,
                    oauth: oauthOpt,
                    disabled: remote.enabled.map { !$0 },
                    codemode: remote.codemode,
                    timeout: remote.timeout.map(migrateMcpTimeout)
                ))
            }
        }

        /// Renames retired V1 provider IDs (`azure-cognitive-services` -> `azure`, `google-vertex-anthropic` -> `google-vertex`).
        // parity: core/src/v1/config/migrate.ts#providerID [status=implemented hash=caa0c3cf2068]
        public static func providerID(_ input: String) -> String {
            if input == "azure-cognitive-services" { return "azure" }
            if input == "google-vertex-anthropic" { return "google-vertex" }
            return input
        }

        /// Migrates a V1 provider configuration, including special-cased Azure Cognitive Services and Google Vertex Anthropic providers.
        // parity: core/src/v1/config/migrate.ts#migrateProvider [status=implemented hash=14e5dc22d019]
        public static func migrateProvider(sourceID: String, info: Provider.Info) -> MigratedProvider {
            if sourceID == "azure-cognitive-services" {
                return migrateAzureCognitiveServicesProvider(info)
            }
            if sourceID == "google-vertex-anthropic" {
                return migrateGoogleVertexAnthropicProvider(info)
            }
            return migrateStandardProvider(info)
        }

        private static func packageSpecifier(_ npm: String) -> String {
            let normalized: String
            if npm.hasPrefix("@opencode-ai/ai/") {
                normalized = "@opencode/" + npm.dropFirst("@opencode-ai/".count)
            } else if npm.hasPrefix("aisdk:") {
                normalized = String(npm.dropFirst("aisdk:".count))
            } else {
                normalized = npm
            }
            if normalized.hasPrefix("@opencode/ai/") {
                return normalized
            }
            return npm.hasPrefix("aisdk:") ? npm : "aisdk:\(npm)"
        }

        private static func modelCompatibility(from interleaved: JSONValue?) -> ModelCompatibilitySchema.Compatibility? {
            guard let interleaved else { return nil }
            if case .string(let field) = interleaved {
                return ModelCompatibilitySchema.Compatibility(reasoningField: .init(rawValue: field))
            }
            if case .object(let obj) = interleaved, case .string(let field) = obj["field"] {
                return ModelCompatibilitySchema.Compatibility(reasoningField: .init(rawValue: field))
            }
            return nil
        }

        private static func migrateStandardProvider(_ info: Provider.Info) -> MigratedProvider {
            var rest = info.options ?? [:]
            let setCacheKey: Bool? = if case .bool(let b) = rest.removeValue(forKey: "setCacheKey") { b } else { nil }
            let split = ProviderOptions.provider(rest)
            var settings: [String: JSONValue]? = info.options != nil ? split.settings : nil
            if let api = info.api {
                var merged = split.settings
                let existingBase: String? = if case .string(let s) = merged["baseURL"], !s.isEmpty { s } else { nil }
                merged["baseURL"] = .string(existingBase ?? api)
                settings = merged
            }
            let models: [String: MigratedModel]? = info.models?.mapValues { migrateModel($0, npm: info.npm) }
            return MigratedProvider(
                name: info.name,
                env: info.env,
                package: info.npm.map(packageSpecifier),
                compatibility: setCacheKey.map { ModelCompatibilitySchema.ProviderCompatibility(supportsPromptCacheKey: $0) },
                settings: settings,
                headers: info.options != nil ? split.headers : nil,
                body: info.options != nil ? split.body : nil,
                models: models
            )
        }

        private static func migrateAzureCognitiveServicesProvider(_ info: Provider.Info) -> MigratedProvider {
            let standard = migrateStandardProvider(info)
            let filteredEnv = standard.env?.filter { $0 != "AZURE_COGNITIVE_SERVICES_RESOURCE_NAME" }
            if info.npm != "@ai-sdk/openai-compatible" || info.api != nil {
                return MigratedProvider(
                    name: standard.name,
                    env: filteredEnv,
                    package: standard.package,
                    compatibility: standard.compatibility,
                    settings: standard.settings,
                    headers: standard.headers,
                    body: standard.body,
                    models: standard.models
                )
            }
            var nextSettings = standard.settings ?? [:]
            nextSettings["baseURL"] = .string("https://${AZURE_COGNITIVE_SERVICES_RESOURCE_NAME}.cognitiveservices.azure.com/openai")
            return MigratedProvider(
                name: standard.name,
                env: filteredEnv,
                package: standard.package,
                compatibility: standard.compatibility,
                settings: nextSettings,
                headers: standard.headers,
                body: standard.body,
                models: standard.models
            )
        }

        private static func migrateGoogleVertexAnthropicProvider(_ info: Provider.Info) -> MigratedProvider {
            let migrated = migrateStandardProvider(info)
            let packageName = migrated.package ?? "aisdk:@ai-sdk/google-vertex/anthropic"
            let models: [String: MigratedModel]? = migrated.models?.mapValues { model in
                if model.package != nil { return model }
                return MigratedModel(
                    modelID: model.modelID,
                    family: model.family,
                    name: model.name,
                    compatibility: model.compatibility,
                    package: packageName,
                    settings: model.settings,
                    capabilities: model.capabilities,
                    headers: model.headers,
                    body: model.body,
                    variants: model.variants,
                    cost: model.cost,
                    disabled: model.disabled,
                    limit: model.limit
                )
            }
            return MigratedProvider(
                name: migrated.name,
                env: migrated.env,
                package: nil,
                compatibility: migrated.compatibility,
                settings: migrated.settings,
                headers: migrated.headers,
                body: migrated.body,
                models: models
            )
        }

        private static func migrateModel(_ info: Provider.Model, npm: String?) -> MigratedModel {
            var options = info.options
            var disableThinkingBlockBinding = false
            if let opts = options {
                for key in ["thinking", "reasoningConfig"] {
                    if case .object(let nested) = opts[key], case .bool(false) = nested["blockBinding"] {
                        disableThinkingBlockBinding = true
                    }
                }
            }
            if disableThinkingBlockBinding, var opts = options {
                for key in ["thinking", "reasoningConfig"] {
                    guard case .object(var nested) = opts[key],
                          case .bool(false) = nested["blockBinding"]
                    else { continue }
                    nested.removeValue(forKey: "blockBinding")
                    if nested.isEmpty {
                        opts.removeValue(forKey: key)
                    } else {
                        opts[key] = .object(nested)
                    }
                }
                options = opts
            }

            let compatible = (info.provider?.npm ?? npm) == "@ai-sdk/openai-compatible"
            func splitOptions(_ input: [String: JSONValue]) -> (settings: [String: JSONValue], body: [String: JSONValue]?) {
                if compatible {
                    let res = ProviderOptions.compatibleModel(input)
                    return (res.settings, res.body)
                }
                return (ProviderOptions.model(input), nil)
            }

            let migratedOpts = options.map(splitOptions)
            var settings = migratedOpts?.settings
            if let api = info.provider?.api {
                var merged = settings ?? [:]
                merged["baseURL"] = .string(api)
                settings = merged
            }

            var compatibility = modelCompatibility(from: info.interleaved)
            if disableThinkingBlockBinding {
                compatibility = ModelCompatibilitySchema.Compatibility(
                    reasoningField: compatibility?.reasoningField,
                    requireReasoning: compatibility?.requireReasoning,
                    maxTokensField: compatibility?.maxTokensField,
                    requireFinishReason: compatibility?.requireFinishReason,
                    requireAssistantAfterTool: compatibility?.requireAssistantAfterTool,
                    supportsPromptCacheKey: compatibility?.supportsPromptCacheKey,
                    streamUsage: compatibility?.streamUsage,
                    cacheFormat: compatibility?.cacheFormat,
                    supportsThinkingBlockBinding: false,
                    supportsEffortUpdates: compatibility?.supportsEffortUpdates,
                    mediaInput: compatibility?.mediaInput
                )
            }

            let safeRate: (Double) -> MoneySchema.USDPerMillionTokens = { val in
                MoneySchema.USDPerMillionTokens(rawValue: val) ?? MoneySchema.USDPerMillionTokens(rawValue: 0)!
            }
            let costs: [ConfigProviderSchema.Cost]? = info.cost.map { cost in
                var list: [ConfigProviderSchema.Cost] = [
                    ConfigProviderSchema.Cost(
                        tier: nil,
                        input: safeRate(cost.input),
                        output: safeRate(cost.output),
                        cache: ConfigProviderSchema.CostCache(
                            read: cost.cacheRead.flatMap(MoneySchema.USDPerMillionTokens.init(rawValue:)),
                            write: cost.cacheWrite.flatMap(MoneySchema.USDPerMillionTokens.init(rawValue:))
                        )
                    ),
                ]
                if let over200k = cost.contextOver200k {
                    list.append(ConfigProviderSchema.Cost(
                        tier: ConfigProviderSchema.CostTier(size: 200_000),
                        input: safeRate(over200k.input),
                        output: safeRate(over200k.output),
                        cache: ConfigProviderSchema.CostCache(
                            read: over200k.cacheRead.flatMap(MoneySchema.USDPerMillionTokens.init(rawValue:)),
                            write: over200k.cacheWrite.flatMap(MoneySchema.USDPerMillionTokens.init(rawValue:))
                        )
                    ))
                }
                return list
            }

            let capabilities: ConfigProviderSchema.ModelCapabilities? =
                (info.toolCall != nil || info.modalities?.input != nil || info.modalities?.output != nil)
                    ? ConfigProviderSchema.ModelCapabilities(
                        tools: info.toolCall,
                        input: info.modalities?.input,
                        output: info.modalities?.output
                    )
                    : nil

            let variants: [MigratedVariant]? = info.variants?.sorted(by: { $0.key < $1.key }).map { id, vOpts in
                let split = splitOptions(vOpts)
                return MigratedVariant(id: id, settings: split.settings, body: split.body)
            }

            let limit: ConfigProviderSchema.Limit? = info.limit.map { lim in
                ConfigProviderSchema.Limit(
                    context: lim.context.map { Int($0.rounded(.towardZero)) },
                    input: lim.input.map { Int($0.rounded(.towardZero)) },
                    output: lim.output.map { Int($0.rounded(.towardZero)) }
                )
            }

            return MigratedModel(
                modelID: info.id,
                family: info.family,
                name: info.name,
                compatibility: compatibility,
                package: info.provider?.npm.map(packageSpecifier),
                settings: settings,
                capabilities: capabilities,
                headers: info.headers,
                body: migratedOpts?.body,
                variants: variants,
                cost: costs,
                disabled: info.status == .deprecated ? true : nil,
                limit: limit
            )
        }
    }
}
