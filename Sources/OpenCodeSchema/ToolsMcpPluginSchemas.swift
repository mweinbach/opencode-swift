/// Pure Swift 6.2 tool, MCP, plugin, skill, instruction, permission, websearch, artifact, form, and RPC schemas.
/// Ports `packages/schema/src/{tool,mcp,plugin,skill,instruction,instruction-entry,permission,permission-saved,websearch,artifact,form,rpc}.ts`.
/// 100% pure Swift standard library (zero OS imports, zero Foundation imports).

// MARK: - src/tool.ts

public enum ToolSchema {
    // parity: schema/src/tool.ts#Metadata [status=implemented hash=787456e878d1]
    public typealias Metadata = [String: JSONValue]

    /// Optional wire encoding of a tool's single required string field.
    // parity: schema/src/tool.ts#Freeform [status=implemented hash=b0ce838dcd97]
    public enum Freeform: Equatable, Hashable, Sendable, Codable {
        case text
        case regex(pattern: String)
        case lark(grammar: String)

        enum CodingKeys: String, CodingKey {
            case type
            case pattern
            case grammar
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "text":
                self = .text
            case "regex":
                self = .regex(pattern: try container.decode(String.self, forKey: .pattern))
            case "lark":
                self = .lark(grammar: try container.decode(String.self, forKey: .grammar))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown Tool.Freeform type '\(type)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text:
                try container.encode("text", forKey: .type)
            case .regex(let pattern):
                try container.encode("regex", forKey: .type)
                try container.encode(pattern, forKey: .pattern)
            case .lark(let grammar):
                try container.encode("lark", forKey: .type)
                try container.encode(grammar, forKey: .grammar)
            }
        }
    }

    // parity: schema/src/tool.ts#FreeformFormat [status=implemented hash=eb8edeaa034c]
    public enum FreeformFormat: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case text
        case regex
        case lark
    }

    // parity: schema/src/tool.ts#CallID [status=implemented hash=07679c119848]
    public struct CallID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
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

    // parity: schema/src/tool.ts#Context [status=adapted hash=5d22f8d429b3]
    public struct Context: Sendable {
        public let sessionID: SessionID
        public let agent: AgentSchema.ID
        public let messageID: String
        public let id: CallID
        public let progress: @Sendable (Metadata) async -> Void
        public let cancel: (@Sendable () async -> Void)?
        /// True when the tool is invoked from inside Code Mode (`execute`).
        public let codemode: Bool?

        public init(
            sessionID: SessionID,
            agent: AgentSchema.ID,
            messageID: String,
            id: CallID,
            progress: @escaping @Sendable (Metadata) async -> Void,
            cancel: (@Sendable () async -> Void)? = nil,
            codemode: Bool? = nil
        ) {
            self.sessionID = sessionID
            self.agent = agent
            self.messageID = messageID
            self.id = id
            self.progress = progress
            self.cancel = cancel
            self.codemode = codemode
        }
    }

    // parity: schema/src/tool.ts#Namespace [status=implemented hash=ca3c665a8937]
    public struct Namespace: Equatable, Hashable, Sendable, Codable {
        public let name: String
        public let description: String

        public init(name: String, description: String) {
            self.name = name
            self.description = description
        }
    }

    /// The object form of `Options.codemode`: Code Mode settings that may override the direct tool's
    /// description and input/output schemas inside Code Mode.
    public struct CodeModeOptions: Equatable, Hashable, Sendable, Codable {
        public let pinned: Bool?
        public let description: String?
        public let input: ValueSchema?
        public let output: ValueSchema?

        public init(
            pinned: Bool? = nil,
            description: String? = nil,
            input: ValueSchema? = nil,
            output: ValueSchema? = nil
        ) {
            self.pinned = pinned
            self.description = description
            self.input = input
            self.output = output
        }
    }

    /// `Options.codemode`: `boolean | { pinned?, description?, input?, output? }`.
    public enum CodeModeSetting: Equatable, Hashable, Sendable, Codable {
        case enabled(Bool)
        case configured(CodeModeOptions)

        public init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let flag = try? single.decode(Bool.self) {
                self = .enabled(flag)
            } else {
                self = .configured(try single.decode(CodeModeOptions.self))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var single = encoder.singleValueContainer()
            switch self {
            case .enabled(let flag): try single.encode(flag)
            case .configured(let options): try single.encode(options)
            }
        }
    }

    // parity: schema/src/tool.ts#Options [status=implemented hash=fc9ade3d5c96]
    public struct Options: Equatable, Hashable, Sendable, Codable {
        public let namespace: String?
        public let permission: String?
        /// `codemode` exactly as declared: a boolean, or an object of Code Mode settings.
        public let codemodeSetting: CodeModeSetting?
        /// Deprecated: use `codemode.pinned` instead. Removed in the next minor.
        public let legacyPinned: Bool?

        /// The boolean view of `codemode`: an object form leaves Code Mode on.
        public var codemode: Bool? {
            switch codemodeSetting {
            case .enabled(let flag): return flag
            case .configured: return true
            case nil: return nil
            }
        }

        /// The Code Mode settings object, when `codemode` is one.
        public var codemodeOptions: CodeModeOptions? {
            if case .configured(let options) = codemodeSetting { return options }
            return nil
        }

        /// `codemode.pinned`, falling back to the deprecated top-level `pinned`.
        public var pinned: Bool? {
            codemodeOptions?.pinned ?? legacyPinned
        }

        public init(
            namespace: String? = nil,
            permission: String? = nil,
            codemode: Bool? = nil,
            pinned: Bool? = nil
        ) {
            self.namespace = namespace
            self.permission = permission
            if let pinned, codemode != false {
                self.codemodeSetting = .configured(CodeModeOptions(pinned: pinned))
            } else {
                self.codemodeSetting = codemode.map { .enabled($0) }
            }
            self.legacyPinned = nil
        }

        public init(
            namespace: String? = nil,
            permission: String? = nil,
            codemodeSetting: CodeModeSetting?,
            legacyPinned: Bool? = nil
        ) {
            self.namespace = namespace
            self.permission = permission
            self.codemodeSetting = codemodeSetting
            self.legacyPinned = legacyPinned
        }

        enum CodingKeys: String, CodingKey {
            case namespace
            case permission
            case codemode
            case pinned
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.namespace = try container.decodeIfPresent(String.self, forKey: .namespace)
            self.permission = try container.decodeIfPresent(String.self, forKey: .permission)
            self.codemodeSetting = try container.decodeIfPresent(CodeModeSetting.self, forKey: .codemode)
            self.legacyPinned = try container.decodeIfPresent(Bool.self, forKey: .pinned)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(namespace, forKey: .namespace)
            try container.encodeIfPresent(permission, forKey: .permission)
            try container.encodeIfPresent(codemodeSetting, forKey: .codemode)
            try container.encodeIfPresent(legacyPinned, forKey: .pinned)
        }
    }

    /// Portable descriptor for a tool/RPC value schema (JSON Schema or named contract).
    // parity: schema/src/tool.ts#ValueSchema [status=adapted hash=04e624531409]
    public enum ValueSchema: Equatable, Hashable, Sendable, Codable {
        case jsonSchema([String: JSONValue])
        case named(String, schema: [String: JSONValue]? = nil)

        enum CodingKeys: String, CodingKey {
            case kind
            case name
            case schema
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let kind = try container.decodeIfPresent(String.self, forKey: .kind), kind == "named" {
                let name = try container.decode(String.self, forKey: .name)
                let schema = try container.decodeIfPresent([String: JSONValue].self, forKey: .schema)
                self = .named(name, schema: schema)
            } else {
                let single = try decoder.singleValueContainer()
                self = .jsonSchema(try single.decode([String: JSONValue].self))
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .jsonSchema(let dict):
                var single = encoder.singleValueContainer()
                try single.encode(dict)
            case .named(let name, let schema):
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("named", forKey: .kind)
                try container.encode(name, forKey: .name)
                try container.encodeIfPresent(schema, forKey: .schema)
            }
        }
    }

    // parity: schema/src/tool.ts#Error [status=implemented hash=8e9f055fe6ec]
    public struct ToolError: Swift.Error, Equatable, Hashable, Sendable, Codable {
        public static let tag = "Tool.Error"
        public let message: String
        public let error: JSONValue?
        public let metadata: [String: JSONValue]?

        public init(message: String, error: JSONValue? = nil, metadata: [String: JSONValue]? = nil) {
            self.message = message
            self.error = error
            self.metadata = metadata
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if container.contains(.tag) {
                try SchemaPrimitive.decodeRequiredLiteral(Self.tag, from: container, forKey: .tag)
            }
            self.message = try container.decode(String.self, forKey: .message)
            self.error = try container.decodeIfPresent(JSONValue.self, forKey: .error)
            self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Self.tag, forKey: .tag)
            try container.encode(message, forKey: .message)
            try container.encodeIfPresent(error, forKey: .error)
            try container.encodeIfPresent(metadata, forKey: .metadata)
        }

        enum CodingKeys: String, CodingKey {
            case tag = "_tag"
            case message
            case error
            case metadata
        }
    }

    // parity: schema/src/tool.ts#TextContent [status=implemented hash=76bcfa160e22]
    public struct TextContent: Equatable, Hashable, Sendable, Codable {
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

    // parity: schema/src/tool.ts#FileContent [status=implemented hash=d1cbe14dd067]
    public struct FileContent: Equatable, Hashable, Sendable, Codable {
        public let uri: String
        public let mime: String
        public let name: String?

        public init(uri: String, mime: String, name: String? = nil) {
            self.uri = uri
            self.mime = mime
            self.name = name
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("file", from: container, forKey: .type)
            self.uri = try container.decode(String.self, forKey: .uri)
            self.mime = try container.decode(String.self, forKey: .mime)
            self.name = try container.decodeIfPresent(String.self, forKey: .name)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("file", forKey: .type)
            try container.encode(uri, forKey: .uri)
            try container.encode(mime, forKey: .mime)
            try container.encodeIfPresent(name, forKey: .name)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case uri
            case mime
            case name
        }
    }

    // parity: schema/src/tool.ts#Content [status=implemented hash=6adfa0144357]
    public enum Content: Equatable, Hashable, Sendable, Codable {
        case text(TextContent)
        case file(FileContent)

        enum TagKeys: String, CodingKey {
            case type
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: TagKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "text":
                self = .text(try TextContent(from: decoder))
            case "file":
                self = .file(try FileContent(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown Tool.Content type '\(type)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .text(let v):
                try v.encode(to: encoder)
            case .file(let v):
                try v.encode(to: encoder)
            }
        }
    }

    public enum ResultContent: Equatable, Hashable, Sendable, Codable {
        case text(String)
        case parts([Content])

        public init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let str = try? single.decode(String.self) {
                self = .text(str)
            } else {
                self = .parts(try single.decode([Content].self))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var single = encoder.singleValueContainer()
            switch self {
            case .text(let s):
                try single.encode(s)
            case .parts(let arr):
                try single.encode(arr)
            }
        }
    }

    // parity: schema/src/tool.ts#Result [status=implemented hash=884efacce0bf]
    public struct Result<Output: Equatable & Hashable & Sendable & Codable>: Equatable, Hashable, Sendable, Codable {
        public let output: Output?
        public let content: ResultContent?
        public let metadata: Metadata?

        public init(output: Output? = nil, content: ResultContent? = nil, metadata: Metadata? = nil) {
            self.output = output
            self.content = content
            self.metadata = metadata
        }
    }

    // parity: schema/src/tool.ts#Info [status=adapted hash=5b1f0fb8e236]
    public struct Info<
        Input: Sendable,
        Output: Equatable & Hashable & Sendable & Codable
    >: Sendable {
        public let name: String
        public let input: ValueSchema
        public let freeform: Freeform?
        public let description: String
        public let execute: @Sendable (Input, Context) async throws(ToolError) -> Result<Output>
        public let output: ValueSchema?
        public let options: Options?

        public init(
            name: String,
            input: ValueSchema,
            freeform: Freeform? = nil,
            description: String,
            execute: @escaping @Sendable (Input, Context) async throws(ToolError) -> Result<Output>,
            output: ValueSchema? = nil,
            options: Options? = nil
        ) {
            self.name = name
            self.input = input
            self.freeform = freeform
            self.description = description
            self.execute = execute
            self.output = output
            self.options = options
        }
    }
}

// MARK: - src/mcp.ts

public enum McpSchema {
    // parity: schema/src/mcp.ts#TimeoutConfig [status=implemented hash=cf1424a461a3]
    public struct TimeoutConfig: Equatable, Hashable, Sendable, Codable {
        public let startup: SchemaPrimitive.PositiveInt?
        public let catalog: SchemaPrimitive.PositiveInt?
        public let execution: SchemaPrimitive.PositiveInt?

        public init(
            startup: SchemaPrimitive.PositiveInt? = nil,
            catalog: SchemaPrimitive.PositiveInt? = nil,
            execution: SchemaPrimitive.PositiveInt? = nil
        ) {
            self.startup = startup
            self.catalog = catalog
            self.execution = execution
        }
    }

    // parity: schema/src/mcp.ts#Protocol [status=implemented hash=5b5efec86fb7]
    public enum WireProtocol: String, Equatable, Hashable, Sendable, Codable {
        case legacy
        case auto
        case rev20260728 = "2026-07-28"
    }

    // parity: schema/src/mcp.ts#LocalConfig [status=implemented hash=d518171edd28]
    public struct LocalConfig: Equatable, Hashable, Sendable, Codable {
        public let command: [String]
        public let cwd: String?
        public let environment: [String: String]?
        public let disabled: Bool?
        public let codemode: Bool?
        public let timeout: TimeoutConfig?
        public let wireProtocol: WireProtocol?
        public let pool: Bool?

        public init(
            command: [String],
            cwd: String? = nil,
            environment: [String: String]? = nil,
            disabled: Bool? = nil,
            codemode: Bool? = nil,
            timeout: TimeoutConfig? = nil,
            wireProtocol: WireProtocol? = nil,
            pool: Bool? = nil
        ) {
            self.command = command
            self.cwd = cwd
            self.environment = environment
            self.disabled = disabled
            self.codemode = codemode
            self.timeout = timeout
            self.wireProtocol = wireProtocol
            self.pool = pool
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("local", from: container, forKey: .type)
            self.command = try container.decode([String].self, forKey: .command)
            self.cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
            self.environment = try container.decodeIfPresent([String: String].self, forKey: .environment)
            self.disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled)
            self.codemode = try container.decodeIfPresent(Bool.self, forKey: .codemode)
            self.timeout = try container.decodeIfPresent(TimeoutConfig.self, forKey: .timeout)
            self.wireProtocol = try container.decodeIfPresent(WireProtocol.self, forKey: .wireProtocol)
            self.pool = try container.decodeIfPresent(Bool.self, forKey: .pool)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("local", forKey: .type)
            try container.encode(command, forKey: .command)
            try container.encodeIfPresent(cwd, forKey: .cwd)
            try container.encodeIfPresent(environment, forKey: .environment)
            try container.encodeIfPresent(disabled, forKey: .disabled)
            try container.encodeIfPresent(codemode, forKey: .codemode)
            try container.encodeIfPresent(timeout, forKey: .timeout)
            try container.encodeIfPresent(wireProtocol, forKey: .wireProtocol)
            try container.encodeIfPresent(pool, forKey: .pool)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case command
            case cwd
            case environment
            case disabled
            case codemode
            case timeout
            case wireProtocol = "protocol"
            case pool
        }
    }

    // parity: schema/src/mcp.ts#OAuthConfig [status=implemented hash=e333e0ed3e63]
    public struct OAuthConfig: Equatable, Hashable, Sendable, Codable {
        public let clientID: String?
        public let clientSecret: String?
        public let scope: String?
        public let callbackPort: Int?
        public let redirectURI: String?
        public let authServerMetadataURL: String?

        public init(
            clientID: String? = nil,
            clientSecret: String? = nil,
            scope: String? = nil,
            callbackPort: Int? = nil,
            redirectURI: String? = nil,
            authServerMetadataURL: String? = nil
        ) {
            self.clientID = clientID
            self.clientSecret = clientSecret
            self.scope = scope
            self.callbackPort = callbackPort
            self.redirectURI = redirectURI
            self.authServerMetadataURL = authServerMetadataURL
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.clientID = try container.decodeIfPresent(String.self, forKey: .clientID)
            self.clientSecret = try container.decodeIfPresent(String.self, forKey: .clientSecret)
            self.scope = try container.decodeIfPresent(String.self, forKey: .scope)
            if let port = try container.decodeIfPresent(Int.self, forKey: .callbackPort) {
                guard port >= 1 && port <= 65_535 else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .callbackPort,
                        in: container,
                        debugDescription: "Expected callback_port in 1...65535, got \(port)"
                    )
                }
                self.callbackPort = port
            } else {
                self.callbackPort = nil
            }
            self.redirectURI = try container.decodeIfPresent(String.self, forKey: .redirectURI)
            self.authServerMetadataURL = try container.decodeIfPresent(String.self, forKey: .authServerMetadataURL)
        }

        enum CodingKeys: String, CodingKey {
            case clientID = "client_id"
            case clientSecret = "client_secret"
            case scope
            case callbackPort = "callback_port"
            case redirectURI = "redirect_uri"
            case authServerMetadataURL = "auth_server_metadata_url"
        }
    }

    public enum OAuthOption: Equatable, Hashable, Sendable, Codable {
        case disabled
        case configured(OAuthConfig)

        public init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let flag = try? single.decode(Bool.self) {
                guard flag == false else {
                    throw DecodingError.dataCorruptedError(
                        in: single,
                        debugDescription: "Expected OAuthConfig or false for mcp remote oauth, got true"
                    )
                }
                self = .disabled
            } else {
                self = .configured(try single.decode(OAuthConfig.self))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var single = encoder.singleValueContainer()
            switch self {
            case .disabled:
                try single.encode(false)
            case .configured(let cfg):
                try single.encode(cfg)
            }
        }
    }

    // parity: schema/src/mcp.ts#RemoteConfig [status=implemented hash=bd7d05a38f04]
    public struct RemoteConfig: Equatable, Hashable, Sendable, Codable {
        public let url: String
        public let headers: [String: String]?
        public let oauth: OAuthOption?
        public let disabled: Bool?
        public let codemode: Bool?
        public let timeout: TimeoutConfig?
        public let wireProtocol: WireProtocol?
        public let pool: Bool?

        public init(
            url: String,
            headers: [String: String]? = nil,
            oauth: OAuthOption? = nil,
            disabled: Bool? = nil,
            codemode: Bool? = nil,
            timeout: TimeoutConfig? = nil,
            wireProtocol: WireProtocol? = nil,
            pool: Bool? = nil
        ) {
            self.url = url
            self.headers = headers
            self.oauth = oauth
            self.disabled = disabled
            self.codemode = codemode
            self.timeout = timeout
            self.wireProtocol = wireProtocol
            self.pool = pool
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("remote", from: container, forKey: .type)
            self.url = try container.decode(String.self, forKey: .url)
            self.headers = try container.decodeIfPresent([String: String].self, forKey: .headers)
            self.oauth = try container.decodeIfPresent(OAuthOption.self, forKey: .oauth)
            self.disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled)
            self.codemode = try container.decodeIfPresent(Bool.self, forKey: .codemode)
            self.timeout = try container.decodeIfPresent(TimeoutConfig.self, forKey: .timeout)
            self.wireProtocol = try container.decodeIfPresent(WireProtocol.self, forKey: .wireProtocol)
            self.pool = try container.decodeIfPresent(Bool.self, forKey: .pool)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("remote", forKey: .type)
            try container.encode(url, forKey: .url)
            try container.encodeIfPresent(headers, forKey: .headers)
            try container.encodeIfPresent(oauth, forKey: .oauth)
            try container.encodeIfPresent(disabled, forKey: .disabled)
            try container.encodeIfPresent(codemode, forKey: .codemode)
            try container.encodeIfPresent(timeout, forKey: .timeout)
            try container.encodeIfPresent(wireProtocol, forKey: .wireProtocol)
            try container.encodeIfPresent(pool, forKey: .pool)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case url
            case headers
            case oauth
            case disabled
            case codemode
            case timeout
            case wireProtocol = "protocol"
            case pool
        }
    }

    // parity: schema/src/mcp.ts#ServerConfig [status=implemented hash=a92e060af5d6]
    public enum ServerConfig: Equatable, Hashable, Sendable, Codable {
        case local(LocalConfig)
        case remote(RemoteConfig)

        enum TagKeys: String, CodingKey {
            case type
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: TagKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "local":
                self = .local(try LocalConfig(from: decoder))
            case "remote":
                self = .remote(try RemoteConfig(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown Mcp.ServerConfig type '\(type)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .local(let v):
                try v.encode(to: encoder)
            case .remote(let v):
                try v.encode(to: encoder)
            }
        }
    }

    // parity: schema/src/mcp.ts#Status [status=implemented hash=57e5e0ca0d57]
    public enum Status: Equatable, Hashable, Sendable, Codable {
        case connected
        case pending
        case disabled
        case failed(error: String)
        case needsAuth(error: String)

        enum CodingKeys: String, CodingKey {
            case status
            case error
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let status = try container.decode(String.self, forKey: .status)
            switch status {
            case "connected":
                self = .connected
            case "pending":
                self = .pending
            case "disabled":
                self = .disabled
            case "failed":
                self = .failed(error: try container.decode(String.self, forKey: .error))
            case "needs_auth":
                self = .needsAuth(error: try container.decode(String.self, forKey: .error))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .status,
                    in: container,
                    debugDescription: "Unknown Mcp.Status '\(status)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .connected:
                try container.encode("connected", forKey: .status)
            case .pending:
                try container.encode("pending", forKey: .status)
            case .disabled:
                try container.encode("disabled", forKey: .status)
            case .failed(let error):
                try container.encode("failed", forKey: .status)
                try container.encode(error, forKey: .error)
            case .needsAuth(let error):
                try container.encode("needs_auth", forKey: .status)
                try container.encode(error, forKey: .error)
            }
        }
    }

    // parity: schema/src/mcp.ts#SubscriptionStatus [status=implemented hash=2be7ef66dce6]
    public enum SubscriptionStatus: Equatable, Hashable, Sendable, Codable {
        public struct EndError: Equatable, Hashable, Sendable, Codable {
            public let code: Double
            public let message: String

            public init(code: Double, message: String) {
                self.code = code
                self.message = message
            }
        }

        case pending
        case active
        case unavailable
        case terminated(error: EndError)
        case rejected(error: EndError)

        enum CodingKeys: String, CodingKey {
            case status
            case reason
            case error
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let status = try container.decode(String.self, forKey: .status)
            switch status {
            case "pending":
                self = .pending
            case "active":
                self = .active
            case "ended":
                let reason = try container.decode(String.self, forKey: .reason)
                switch reason {
                case "unavailable":
                    self = .unavailable
                case "terminated":
                    self = .terminated(error: try container.decode(EndError.self, forKey: .error))
                case "rejected":
                    self = .rejected(error: try container.decode(EndError.self, forKey: .error))
                default:
                    throw DecodingError.dataCorruptedError(
                        forKey: .reason,
                        in: container,
                        debugDescription: "Unknown Mcp.SubscriptionStatus ended reason '\(reason)'"
                    )
                }
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .status,
                    in: container,
                    debugDescription: "Unknown Mcp.SubscriptionStatus '\(status)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .pending:
                try container.encode("pending", forKey: .status)
            case .active:
                try container.encode("active", forKey: .status)
            case .unavailable:
                try container.encode("ended", forKey: .status)
                try container.encode("unavailable", forKey: .reason)
            case .terminated(let error):
                try container.encode("ended", forKey: .status)
                try container.encode("terminated", forKey: .reason)
                try container.encode(error, forKey: .error)
            case .rejected(let error):
                try container.encode("ended", forKey: .status)
                try container.encode("rejected", forKey: .reason)
                try container.encode(error, forKey: .error)
            }
        }
    }

    // parity: schema/src/mcp.ts#Server [status=implemented hash=8c4d5ec02205]
    public struct Server: Equatable, Hashable, Sendable, Codable {
        public let name: String
        public let status: Status
        public let title: String?
        public let integrationID: IntegrationID?

        public init(name: String, status: Status, title: String? = nil, integrationID: IntegrationID? = nil) {
            self.name = name
            self.status = status
            self.title = title
            self.integrationID = integrationID
        }
    }

    // parity: schema/src/mcp.ts#Resource [status=implemented hash=31be5cfbcaab]
    public struct Resource: Equatable, Hashable, Sendable, Codable {
        public let server: String
        public let name: String
        public let uri: String
        public let description: String?
        public let mimeType: String?

        public init(
            server: String,
            name: String,
            uri: String,
            description: String? = nil,
            mimeType: String? = nil
        ) {
            self.server = server
            self.name = name
            self.uri = uri
            self.description = description
            self.mimeType = mimeType
        }
    }

    // parity: schema/src/mcp.ts#ResourceTemplate [status=implemented hash=2e927d699b53]
    public struct ResourceTemplate: Equatable, Hashable, Sendable, Codable {
        public let server: String
        public let name: String
        public let uriTemplate: String
        public let description: String?
        public let mimeType: String?

        public init(
            server: String,
            name: String,
            uriTemplate: String,
            description: String? = nil,
            mimeType: String? = nil
        ) {
            self.server = server
            self.name = name
            self.uriTemplate = uriTemplate
            self.description = description
            self.mimeType = mimeType
        }
    }

    // parity: schema/src/mcp.ts#ResourceCatalog [status=implemented hash=16dd9bff30e5]
    public struct ResourceCatalog: Equatable, Hashable, Sendable, Codable {
        public let resources: [Resource]
        public let templates: [ResourceTemplate]

        public init(resources: [Resource], templates: [ResourceTemplate]) {
            self.resources = resources
            self.templates = templates
        }
    }

    // parity: schema/src/mcp.ts#ResourceContentPart [status=implemented hash=f68ae94fcdcb]
    public enum ResourceContentPart: Equatable, Hashable, Sendable, Codable {
        case text(uri: String, text: String, mimeType: String? = nil)
        case blob(uri: String, blob: String, mimeType: String? = nil)

        enum CodingKeys: String, CodingKey {
            case type
            case uri
            case text
            case blob
            case mimeType
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            let uri = try container.decode(String.self, forKey: .uri)
            let mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
            switch type {
            case "text":
                let text = try container.decode(String.self, forKey: .text)
                self = .text(uri: uri, text: text, mimeType: mimeType)
            case "blob":
                let blob = try container.decode(String.self, forKey: .blob)
                self = .blob(uri: uri, blob: blob, mimeType: mimeType)
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown Mcp.ResourceContentPart type '\(type)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let uri, let text, let mimeType):
                try container.encode("text", forKey: .type)
                try container.encode(uri, forKey: .uri)
                try container.encode(text, forKey: .text)
                try container.encodeIfPresent(mimeType, forKey: .mimeType)
            case .blob(let uri, let blob, let mimeType):
                try container.encode("blob", forKey: .type)
                try container.encode(uri, forKey: .uri)
                try container.encode(blob, forKey: .blob)
                try container.encodeIfPresent(mimeType, forKey: .mimeType)
            }
        }
    }

    // parity: schema/src/mcp.ts#ResourceContent [status=implemented hash=c4b9aae07746]
    public struct ResourceContent: Equatable, Hashable, Sendable, Codable {
        public let server: String
        public let uri: String
        public let contents: [ResourceContentPart]

        public init(server: String, uri: String, contents: [ResourceContentPart]) {
            self.server = server
            self.uri = uri
            self.contents = contents
        }
    }
}

// MARK: - src/plugin.ts

public enum PluginSchema {
    // parity: schema/src/plugin.ts#ID [status=implemented hash=b554fe429c65]
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

    // parity: schema/src/plugin.ts#Source [status=implemented hash=2bade1f6bc27]
    public enum Source: Equatable, Hashable, Sendable, Codable {
        case builtin
        case package(target: String, version: String? = nil, outdated: Bool? = nil, updating: Bool? = nil)
        case local(path: String)
        case sdk

        enum CodingKeys: String, CodingKey {
            case type
            case target
            case version
            case outdated
            case updating
            case path
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "builtin":
                self = .builtin
            case "package":
                let target = try container.decode(String.self, forKey: .target)
                let version = try container.decodeIfPresent(String.self, forKey: .version)
                let outdated = try SchemaPrimitive.decodeOptionalLiteralTrue(from: container, forKey: .outdated)
                let updating = try SchemaPrimitive.decodeOptionalLiteralTrue(from: container, forKey: .updating)
                self = .package(target: target, version: version, outdated: outdated, updating: updating)
            case "local":
                self = .local(path: try container.decode(String.self, forKey: .path))
            case "sdk":
                self = .sdk
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown Plugin.Source type '\(type)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .builtin:
                try container.encode("builtin", forKey: .type)
            case .package(let target, let version, let outdated, let updating):
                try container.encode("package", forKey: .type)
                try container.encode(target, forKey: .target)
                try container.encodeIfPresent(version, forKey: .version)
                if outdated == true { try container.encode(true, forKey: .outdated) }
                if updating == true { try container.encode(true, forKey: .updating) }
            case .local(let path):
                try container.encode("local", forKey: .type)
                try container.encode(path, forKey: .path)
            case .sdk:
                try container.encode("sdk", forKey: .type)
            }
        }
    }

    // parity: schema/src/plugin.ts#Features [status=implemented hash=a618d05301e2]
    public struct Features: Equatable, Hashable, Sendable, Codable {
        public let server: Bool?
        public let tui: Bool?
        public let rpc: Bool?
        public let gui: Bool?

        public init(server: Bool? = nil, tui: Bool? = nil, rpc: Bool? = nil, gui: Bool? = nil) {
            self.server = server
            self.tui = tui
            self.rpc = rpc
            self.gui = gui
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.server = try SchemaPrimitive.decodeOptionalLiteralTrue(from: container, forKey: .server)
            self.tui = try SchemaPrimitive.decodeOptionalLiteralTrue(from: container, forKey: .tui)
            self.rpc = try SchemaPrimitive.decodeOptionalLiteralTrue(from: container, forKey: .rpc)
            self.gui = try SchemaPrimitive.decodeOptionalLiteralTrue(from: container, forKey: .gui)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            if server == true { try container.encode(true, forKey: .server) }
            if tui == true { try container.encode(true, forKey: .tui) }
            if rpc == true { try container.encode(true, forKey: .rpc) }
            if gui == true { try container.encode(true, forKey: .gui) }
        }

        enum CodingKeys: String, CodingKey {
            case server
            case tui
            case rpc
            case gui
        }
    }

    // parity: schema/src/plugin.ts#GuiBundle [status=implemented hash=85545d94240d]
    public struct GuiBundle: Equatable, Hashable, Sendable, Codable {
        public let code: String
        public let revision: String
        public let options: [String: JSONValue]

        public init(code: String, revision: String, options: [String: JSONValue]) {
            self.code = code
            self.revision = revision
            self.options = options
        }
    }

    // parity: schema/src/plugin.ts#State [status=implemented hash=5aa4a3a9b0a9]
    public enum State: Equatable, Hashable, Sendable, Codable {
        case active
        case failed(error: String, ref: String? = nil)

        enum CodingKeys: String, CodingKey {
            case status
            case error
            case ref
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let status = try container.decode(String.self, forKey: .status)
            switch status {
            case "active":
                self = .active
            case "failed":
                let error = try container.decode(String.self, forKey: .error)
                let ref = try container.decodeIfPresent(String.self, forKey: .ref)
                self = .failed(error: error, ref: ref)
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .status,
                    in: container,
                    debugDescription: "Unknown Plugin.State status '\(status)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .active:
                try container.encode("active", forKey: .status)
            case .failed(let error, let ref):
                try container.encode("failed", forKey: .status)
                try container.encode(error, forKey: .error)
                try container.encodeIfPresent(ref, forKey: .ref)
            }
        }
    }

    // parity: schema/src/plugin.ts#Info [status=implemented hash=1821aa3b7f74]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public let id: ID?
        public let source: Source
        public let features: Features
        public let state: State

        public init(id: ID? = nil, source: Source, features: Features, state: State) {
            self.id = id
            self.source = source
            self.features = features
            self.state = state
        }
    }

    // parity: schema/src/plugin.ts#Event [status=implemented hash=e7550d251b3a]
    public enum Event {
        public static let updated = SchemaPrimitive.EventDescriptor.ephemeral(type: "plugin.updated")
        public static let definitions: [SchemaPrimitive.EventDescriptor] = [updated]
    }
}

// MARK: - src/skill.ts

public enum SkillSchema {
    // parity: schema/src/skill.ts#ID [status=implemented hash=4996eedbc6af]
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

    // parity: schema/src/skill.ts#Name [status=implemented hash=07e23e273106]
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

    // parity: schema/src/skill.ts#DirectorySource [status=implemented hash=498b058a7a70]
    public struct DirectorySource: Equatable, Hashable, Sendable, Codable {
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

    // parity: schema/src/skill.ts#UrlSource [status=implemented hash=55e0028f35d0]
    public struct UrlSource: Equatable, Hashable, Sendable, Codable {
        public let url: String

        public init(url: String) {
            self.url = url
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("url", from: container, forKey: .type)
            self.url = try container.decode(String.self, forKey: .url)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("url", forKey: .type)
            try container.encode(url, forKey: .url)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case url
        }
    }

    // parity: schema/src/skill.ts#Info [status=implemented hash=1821aa3b7f74]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public let id: ID
        public let name: Name
        public let description: String?
        public let autoinvoke: Bool?
        public let path: SchemaPrimitive.AbsolutePath
        public let content: String

        public init(
            id: ID,
            name: Name,
            description: String? = nil,
            autoinvoke: Bool? = nil,
            path: SchemaPrimitive.AbsolutePath,
            content: String
        ) {
            self.id = id
            self.name = name
            self.description = description
            self.autoinvoke = autoinvoke
            self.path = path
            self.content = content
        }
    }

    // parity: schema/src/skill.ts#Event [status=implemented hash=e7550d251b3a]
    public enum Event {
        public static let updated = SchemaPrimitive.EventDescriptor.ephemeral(type: "skill.updated")
        public static let definitions: [SchemaPrimitive.EventDescriptor] = [updated]
    }

    // parity: schema/src/skill.ts#EmbeddedSource [status=implemented hash=091c7a9e7c05]
    public struct EmbeddedSource: Equatable, Hashable, Sendable, Codable {
        public let skill: Info

        public init(skill: Info) {
            self.skill = skill
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("embedded", from: container, forKey: .type)
            self.skill = try container.decode(Info.self, forKey: .skill)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("embedded", forKey: .type)
            try container.encode(skill, forKey: .skill)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case skill
        }
    }

    // parity: schema/src/skill.ts#Source [status=implemented hash=59b3e522fe0e]
    public enum Source: Equatable, Hashable, Sendable, Codable {
        case directory(DirectorySource)
        case url(UrlSource)
        case embedded(EmbeddedSource)

        enum TagKeys: String, CodingKey {
            case type
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: TagKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "directory":
                self = .directory(try DirectorySource(from: decoder))
            case "url":
                self = .url(try UrlSource(from: decoder))
            case "embedded":
                self = .embedded(try EmbeddedSource(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown Skill.Source type '\(type)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .directory(let v):
                try v.encode(to: encoder)
            case .url(let v):
                try v.encode(to: encoder)
            case .embedded(let v):
                try v.encode(to: encoder)
            }
        }

        public static func equals(_ a: Source, _ b: Source) -> Bool {
            switch (a, b) {
            case (.directory(let x), .directory(let y)):
                return x.path == y.path
            case (.url(let x), .url(let y)):
                return x.url == y.url
            case (.embedded(let x), .embedded(let y)):
                return x.skill.id == y.skill.id
            default:
                return false
            }
        }

        public static func key(_ source: Source) -> String {
            switch source {
            case .directory(let d):
                return "directory:\(d.path.rawValue)"
            case .url(let u):
                return "url:\(u.url)"
            case .embedded(let e):
                return "embedded:\(e.skill.id.rawValue)"
            }
        }
    }
}

// MARK: - src/instruction.ts

public enum InstructionSchema {
    /// Namespaced instruction key matching `^[a-z0-9][a-z0-9._-]*\/[a-z0-9][a-z0-9._/-]*$`.
    // parity: schema/src/instruction.ts#Key [status=implemented hash=b049539b16dc]
    public struct Key: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public init?(rawValue: String) {
            guard SchemaPrimitive.isInstructionKey(rawValue) else { return nil }
            self.rawValue = rawValue
        }

        public init(validating value: String) throws(SchemaPrimitive.ValidationError) {
            guard SchemaPrimitive.isInstructionKey(value) else {
                throw .invalidFormat(expected: "^[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._/-]*$", actual: value)
            }
            self.rawValue = value
        }

        public var description: String { rawValue }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard SchemaPrimitive.isInstructionKey(value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid Instruction.Key '\(value)'"
                )
            }
            self.rawValue = value
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    /// Lowercase SHA-256 hex digest matching `^[a-f0-9]{64}$`.
    // parity: schema/src/instruction.ts#Hash [status=implemented hash=962e9c1cb57f]
    public struct Hash: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public init?(rawValue: String) {
            guard SchemaPrimitive.isSha256Hex(rawValue) else { return nil }
            self.rawValue = rawValue
        }

        public init(validating value: String) throws(SchemaPrimitive.ValidationError) {
            guard SchemaPrimitive.isSha256Hex(value) else {
                throw .invalidFormat(expected: "^[a-f0-9]{64}$", actual: value)
            }
            self.rawValue = value
        }

        public var description: String { rawValue }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard SchemaPrimitive.isSha256Hex(value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid Instruction.Hash '\(value)'"
                )
            }
            self.rawValue = value
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    // parity: schema/src/instruction.ts#Values [status=implemented hash=524fc5875e65]
    public struct Values: Equatable, Hashable, Sendable, Codable {
        public let entries: [String: Hash]

        public init(entries: [String: Hash] = [:]) {
            self.entries = entries
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: SchemaPrimitive.AnyCodingKey.self)
            var result: [String: Hash] = [:]
            for key in container.allKeys {
                guard SchemaPrimitive.isInstructionKey(key.stringValue) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: key,
                        in: container,
                        debugDescription: "Invalid Instruction.Key '\(key.stringValue)'"
                    )
                }
                result[key.stringValue] = try container.decode(Hash.self, forKey: key)
            }
            self.entries = result
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: SchemaPrimitive.AnyCodingKey.self)
            for (k, v) in entries {
                try container.encode(v, forKey: .init(k))
            }
        }
    }

    // parity: schema/src/instruction.ts#Removed [status=implemented hash=6c76ed6927d6]
    public enum Removed: String, Equatable, Hashable, Sendable, Codable {
        case removed
    }

    // parity: schema/src/instruction.ts#removed [status=implemented hash=4a64b53af05d]
    public static let removed: Removed = .removed

    public enum DeltaValue: Equatable, Hashable, Sendable, Codable {
        case hash(Hash)
        case removed

        public init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            let str = try single.decode(String.self)
            if str == "removed" {
                self = .removed
            } else if let hash = Hash(rawValue: str) {
                self = .hash(hash)
            } else {
                throw DecodingError.dataCorruptedError(
                    in: single,
                    debugDescription: "Expected 64-char sha256 hash or 'removed', got '\(str)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var single = encoder.singleValueContainer()
            switch self {
            case .hash(let h):
                try single.encode(h)
            case .removed:
                try single.encode("removed")
            }
        }
    }

    // parity: schema/src/instruction.ts#Delta [status=implemented hash=a9e430f6afe6]
    public typealias Delta = [String: DeltaValue]
}

// MARK: - src/instruction-entry.ts

public enum InstructionEntrySchema {
    /// Slash-free client-facing key matching `^[a-z0-9][a-z0-9._-]*$`.
    // parity: schema/src/instruction-entry.ts#Key [status=implemented hash=d13ec758389e]
    public struct Key: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public init?(rawValue: String) {
            guard SchemaPrimitive.isInstructionEntryKey(rawValue) else { return nil }
            self.rawValue = rawValue
        }

        public init(validating value: String) throws(SchemaPrimitive.ValidationError) {
            guard SchemaPrimitive.isInstructionEntryKey(value) else {
                throw .invalidFormat(expected: "^[a-z0-9][a-z0-9._-]*$", actual: value)
            }
            self.rawValue = value
        }

        public var description: String { rawValue }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard SchemaPrimitive.isInstructionEntryKey(value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid InstructionEntry.Key '\(value)'"
                )
            }
            self.rawValue = value
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    // parity: schema/src/instruction-entry.ts#Info [status=implemented hash=88b58f16ebe8]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public let key: Key
        public let value: JSONValue

        public init(key: Key, value: JSONValue) {
            self.key = key
            self.value = value
        }
    }

    public struct SnapshotEntry: Equatable, Hashable, Sendable, Codable {
        public let key: Key
        public let value: JSONValue
        public let removed: Bool

        public init(key: Key, value: JSONValue, removed: Bool) {
            self.key = key
            self.value = value
            self.removed = removed
        }
    }

    // parity: schema/src/instruction-entry.ts#Snapshot [status=implemented hash=d0d6837d224b]
    public typealias Snapshot = [SnapshotEntry]

    // parity: schema/src/instruction-entry.ts#MaxValueBytes [status=implemented hash=fab379cc07f6]
    public static let maxValueBytes: Int = 256 * 1024

    // parity: schema/src/instruction-entry.ts#ValueTooLargeError [status=implemented hash=1a872136be3b]
    public struct ValueTooLargeError: Swift.Error, Equatable, Hashable, Sendable, Codable {
        public static let tag = "InstructionEntryValueTooLargeError"
        public static let httpApiStatus = 413

        public let actualBytes: Int
        public let maxBytes: Int
        public let message: String

        public init(actualBytes: Int, maxBytes: Int, message: String) {
            self.actualBytes = actualBytes
            self.maxBytes = maxBytes
            self.message = message
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if container.contains(.tag) {
                try SchemaPrimitive.decodeRequiredLiteral(Self.tag, from: container, forKey: .tag)
            }
            self.actualBytes = try container.decode(Int.self, forKey: .actualBytes)
            self.maxBytes = try container.decode(Int.self, forKey: .maxBytes)
            self.message = try container.decode(String.self, forKey: .message)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Self.tag, forKey: .tag)
            try container.encode(actualBytes, forKey: .actualBytes)
            try container.encode(maxBytes, forKey: .maxBytes)
            try container.encode(message, forKey: .message)
        }

        enum CodingKeys: String, CodingKey {
            case tag = "_tag"
            case actualBytes
            case maxBytes
            case message
        }
    }
}

// MARK: - src/permission.ts

public enum PermissionSchema {
    // parity: schema/src/permission.ts#ID [status=implemented hash=7a07181d4eb0]
    public struct ID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public init?(rawValue: String) {
            guard rawValue.hasPrefix("per") else { return nil }
            self.rawValue = rawValue
        }

        public init(validating value: String) throws(IdentifierValidationError) {
            guard value.hasPrefix("per") else {
                throw .invalidPrefix(expected: "per", actual: value)
            }
            self.rawValue = value
        }

        private init(unchecked value: String) {
            self.rawValue = value
        }

        public static func create() -> ID {
            ID(unchecked: "per_" + Identifier.ascending())
        }

        public static func create(_ id: String?) throws(IdentifierValidationError) -> ID {
            guard let id else { return create() }
            return try ID(validating: id)
        }

        public var description: String { rawValue }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            self = try ID(validating: value)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    // parity: schema/src/permission.ts#Source [status=implemented hash=5b881e45e5be]
    public enum Source: Equatable, Hashable, Sendable, Codable {
        case tool(messageID: String, id: String)

        enum CodingKeys: String, CodingKey {
            case type
            case messageID
            case id
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("tool", from: container, forKey: .type)
            let messageID = try container.decode(String.self, forKey: .messageID)
            let id = try container.decode(String.self, forKey: .id)
            self = .tool(messageID: messageID, id: id)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .tool(let messageID, let id):
                try container.encode("tool", forKey: .type)
                try container.encode(messageID, forKey: .messageID)
                try container.encode(id, forKey: .id)
            }
        }
    }

    // parity: schema/src/permission.ts#Request [status=implemented hash=118023628c57]
    public struct Request: Equatable, Hashable, Sendable, Codable {
        public let id: ID
        public let sessionID: SessionID
        public let action: String
        public let resources: [String]
        public let save: [String]?
        public let metadata: [String: JSONValue]?
        public let source: Source?
        public let message: String?

        public init(
            id: ID,
            sessionID: SessionID,
            action: String,
            resources: [String],
            save: [String]? = nil,
            metadata: [String: JSONValue]? = nil,
            source: Source? = nil,
            message: String? = nil
        ) {
            self.id = id
            self.sessionID = sessionID
            self.action = action
            self.resources = resources
            self.save = save
            self.metadata = metadata
            self.source = source
            self.message = message
        }
    }

    // parity: schema/src/permission.ts#Reply [status=implemented hash=55e2bda1b939]
    public enum Reply: String, Equatable, Hashable, Sendable, Codable {
        case once
        case always
        case reject
    }

    // parity: schema/src/permission.ts#Event [status=implemented hash=18473cd164e0]
    public enum Event {
        public struct RepliedPayload: Equatable, Hashable, Sendable, Codable {
            public let sessionID: SessionID
            public let requestID: ID
            public let reply: Reply

            public init(sessionID: SessionID, requestID: ID, reply: Reply) {
                self.sessionID = sessionID
                self.requestID = requestID
                self.reply = reply
            }
        }

        public static let asked = SchemaPrimitive.EventDescriptor.ephemeral(type: "permission.asked")
        public static let replied = SchemaPrimitive.EventDescriptor.ephemeral(type: "permission.replied")
        public static let definitions: [SchemaPrimitive.EventDescriptor] = [asked, replied]
    }

    // parity: schema/src/permission.ts#Effect [status=implemented hash=0466ce4d785e]
    public enum Effect: String, Equatable, Hashable, Sendable, Codable {
        case allow
        case deny
        case ask
    }

    // parity: schema/src/permission.ts#Rule [status=implemented hash=710d168a4167]
    public struct Rule: Equatable, Hashable, Sendable, Codable {
        public let action: String
        public let resource: String
        public let effect: Effect

        public init(action: String, resource: String, effect: Effect) {
            self.action = action
            self.resource = resource
            self.effect = effect
        }
    }

    // parity: schema/src/permission.ts#Ruleset [status=implemented hash=e4feba8a4bae]
    public typealias Ruleset = [Rule]
}

// MARK: - src/permission-saved.ts

public enum PermissionSavedSchema {
    // parity: schema/src/permission-saved.ts#ID [status=implemented hash=447fc0674566]
    public struct ID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static func create() -> ID {
            ID(rawValue: "psv_" + Identifier.ascending())
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

    // parity: schema/src/permission-saved.ts#Info [status=implemented hash=774c6dec45d4]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public struct Time: Equatable, Hashable, Sendable, Codable {
            public let created: SchemaPrimitive.DateTimeUtcFromMillis
            public let updated: SchemaPrimitive.DateTimeUtcFromMillis

            public init(
                created: SchemaPrimitive.DateTimeUtcFromMillis,
                updated: SchemaPrimitive.DateTimeUtcFromMillis
            ) {
                self.created = created
                self.updated = updated
            }
        }

        public let id: ID
        public let projectID: ProjectID
        public let action: String
        public let resource: String
        public let time: Time

        public init(id: ID, projectID: ProjectID, action: String, resource: String, time: Time) {
            self.id = id
            self.projectID = projectID
            self.action = action
            self.resource = resource
            self.time = time
        }
    }
}

// MARK: - src/websearch.ts

public enum WebSearchSchema {
    // parity: schema/src/websearch.ts#ID [status=implemented hash=818d028f5863]
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

    // parity: schema/src/websearch.ts#Provider [status=implemented hash=e575a1c08322]
    public struct Provider: Equatable, Hashable, Sendable, Codable {
        public let id: ID
        public let name: String

        public init(id: ID, name: String) {
            self.id = id
            self.name = name
        }
    }

    // parity: schema/src/websearch.ts#Input [status=implemented hash=ad4b571f3729]
    public struct Input: Equatable, Hashable, Sendable, Codable {
        public let query: String
        public let providerID: ID?

        public init(query: String, providerID: ID? = nil) {
            self.query = query
            self.providerID = providerID
        }
    }

    // parity: schema/src/websearch.ts#ProviderInput [status=implemented hash=0449c0a35f5f]
    public struct ProviderInput: Equatable, Hashable, Sendable, Codable {
        public let query: String

        public init(query: String) {
            self.query = query
        }
    }

    // parity: schema/src/websearch.ts#Result [status=implemented hash=5b5fe8d31a63]
    public struct Result: Equatable, Hashable, Sendable, Codable {
        public struct Time: Equatable, Hashable, Sendable, Codable {
            public let published: Double?

            public init(published: Double? = nil) {
                self.published = published
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.published = try SchemaPrimitive.decodeFiniteIfPresent(from: container, forKey: .published)
            }

            enum CodingKeys: String, CodingKey {
                case published
            }
        }

        public let url: String
        public let title: String?
        public let content: String?
        public let time: Time

        public init(url: String, title: String? = nil, content: String? = nil, time: Time = Time()) {
            self.url = url
            self.title = title
            self.content = content
            self.time = time
        }
    }

    // parity: schema/src/websearch.ts#Response [status=implemented hash=b53799f6e2de]
    public struct Response: Equatable, Hashable, Sendable, Codable {
        public let providerID: ID
        public let results: [Result]

        public init(providerID: ID, results: [Result]) {
            self.providerID = providerID
            self.results = results
        }
    }

    // parity: schema/src/websearch.ts#Event [status=implemented hash=e7550d251b3a]
    public enum Event {
        public static let updated = SchemaPrimitive.EventDescriptor.ephemeral(type: "websearch.updated")
        public static let definitions: [SchemaPrimitive.EventDescriptor] = [updated]
    }
}

// MARK: - src/artifact.ts

public enum ArtifactSchema {
    // parity: schema/src/artifact.ts#ID [status=implemented hash=a23710a2ae6e]
    public struct ID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public init?(rawValue: String) {
            guard rawValue.hasPrefix("art_") else { return nil }
            self.rawValue = rawValue
        }

        public init(validating value: String) throws(IdentifierValidationError) {
            guard value.hasPrefix("art_") else {
                throw .invalidPrefix(expected: "art_", actual: value)
            }
            self.rawValue = value
        }

        private init(unchecked value: String) {
            self.rawValue = value
        }

        public static func create() -> ID {
            ID(unchecked: "art_" + Identifier.ascending())
        }

        public var description: String { rawValue }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            self = try ID(validating: value)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    // parity: schema/src/artifact.ts#ProviderID [status=implemented hash=b9a32b2a7fea]
    public struct ProviderID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public init?(rawValue: String) {
            let trimmed = SchemaPrimitive.trimWhitespace(rawValue)
            guard !trimmed.isEmpty else { return nil }
            self.rawValue = trimmed
        }

        public init(validating value: String) throws(SchemaPrimitive.ValidationError) {
            let trimmed = SchemaPrimitive.trimWhitespace(value)
            guard !trimmed.isEmpty else { throw .emptyString(field: "provider") }
            self.rawValue = trimmed
        }

        public var description: String { rawValue }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            let trimmed = SchemaPrimitive.trimWhitespace(raw)
            guard !trimmed.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Artifact.ProviderID must be non-empty"
                )
            }
            self.rawValue = trimmed
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    // parity: schema/src/artifact.ts#Capability [status=implemented hash=9ef8e9fef146]
    public enum Capability: String, Equatable, Hashable, Sendable, Codable {
        case `static`
        case serverCode = "server-code"
        case sqlite
        case durableObjects = "durable-objects"
    }

    // parity: schema/src/artifact.ts#Provider [status=implemented hash=e575a1c08322]
    public struct Provider: Equatable, Hashable, Sendable, Codable {
        public let id: ProviderID
        public let name: String
        public let capabilities: [Capability]
        public let isDefault: Bool

        public init(id: ProviderID, name: String, capabilities: [Capability], isDefault: Bool) {
            self.id = id
            self.name = name
            self.capabilities = capabilities
            self.isDefault = isDefault
        }

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case capabilities
            case isDefault = "default"
        }
    }

    // parity: schema/src/artifact.ts#Time [status=implemented hash=ba89737c1446]
    public struct Time: Equatable, Hashable, Sendable, Codable {
        public let created: Double
        public let updated: Double

        public init(created: Double, updated: Double) {
            self.created = created
            self.updated = updated
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.created = try SchemaPrimitive.decodeFinite(from: container, forKey: .created)
            self.updated = try SchemaPrimitive.decodeFinite(from: container, forKey: .updated)
        }

        enum CodingKeys: String, CodingKey {
            case created
            case updated
        }
    }

    // parity: schema/src/artifact.ts#Info [status=implemented hash=1821aa3b7f74]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public let id: ID
        public let provider: ProviderID
        public let sessionID: SessionID?
        public let title: String
        public let entry: String
        public let url: String
        public let time: Time

        public init(
            id: ID,
            provider: ProviderID,
            sessionID: SessionID? = nil,
            title: String,
            entry: String,
            url: String,
            time: Time
        ) {
            self.id = id
            self.provider = provider
            self.sessionID = sessionID
            self.title = title
            self.entry = entry
            self.url = url
            self.time = time
        }
    }

    // parity: schema/src/artifact.ts#Content [status=implemented hash=c2f4f3c0cc82]
    public struct Content: Equatable, Hashable, Sendable, Codable {
        public let info: Info
        public let files: [String: String]

        public init(info: Info, files: [String: String]) {
            self.info = info
            self.files = files
        }
    }

    // parity: schema/src/artifact.ts#CreateInput [status=implemented hash=d8768400ea9e]
    public struct CreateInput: Equatable, Hashable, Sendable, Codable {
        public let title: String
        public let files: [String: String]
        public let entry: String?
        public let provider: ProviderID?
        public let sessionID: SessionID?

        public init(
            title: String,
            files: [String: String],
            entry: String? = nil,
            provider: ProviderID? = nil,
            sessionID: SessionID? = nil
        ) {
            self.title = title
            self.files = files
            self.entry = entry
            self.provider = provider
            self.sessionID = sessionID
        }
    }

    // parity: schema/src/artifact.ts#UpdateInput [status=implemented hash=128918d977c7]
    public struct UpdateInput: Equatable, Hashable, Sendable, Codable {
        public let title: String?
        public let files: [String: String]
        public let entry: String?
        public let sessionID: SessionID?

        public init(
            title: String? = nil,
            files: [String: String],
            entry: String? = nil,
            sessionID: SessionID? = nil
        ) {
            self.title = title
            self.files = files
            self.entry = entry
            self.sessionID = sessionID
        }
    }

    // parity: schema/src/artifact.ts#Event [status=implemented hash=e7550d251b3a]
    public enum Event {
        public static let updated = SchemaPrimitive.EventDescriptor.ephemeral(type: "artifact.updated")
        public static let definitions: [SchemaPrimitive.EventDescriptor] = [updated]
    }
}

// MARK: - src/form.ts

public enum FormSchema {
    // parity: schema/src/form.ts#ID [status=implemented hash=527dbcbc381d]
    public struct ID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public init?(rawValue: String) {
            guard rawValue.hasPrefix("frm_") else { return nil }
            self.rawValue = rawValue
        }

        public init(validating value: String) throws(IdentifierValidationError) {
            guard value.hasPrefix("frm_") else {
                throw .invalidPrefix(expected: "frm_", actual: value)
            }
            self.rawValue = value
        }

        private init(unchecked value: String) {
            self.rawValue = value
        }

        public static func create() -> ID {
            ID(unchecked: "frm_" + Identifier.ascending())
        }

        public static func create(_ id: String?) throws(IdentifierValidationError) -> ID {
            guard let id else { return create() }
            return try ID(validating: id)
        }

        public var description: String { rawValue }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            self = try ID(validating: value)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    // parity: schema/src/form.ts#Metadata [status=implemented hash=274225d72d47]
    public typealias Metadata = [String: JSONValue]

    // parity: schema/src/form.ts#Option [status=implemented hash=69d136accddc]
    public struct Option: Equatable, Hashable, Sendable, Codable {
        public let value: String
        public let label: String
        public let description: String?

        public init(value: String, label: String, description: String? = nil) {
            self.value = value
            self.label = label
            self.description = description
        }
    }

    // parity: schema/src/form.ts#When [status=implemented hash=468df053b4e1]
    public struct When: Equatable, Hashable, Sendable, Codable {
        public enum Operator: String, Equatable, Hashable, Sendable, Codable {
            case eq
            case neq
        }

        public enum CompareValue: Equatable, Hashable, Sendable, Codable {
            case string(String)
            case number(Double)
            case bool(Bool)

            public init(from decoder: Decoder) throws {
                let single = try decoder.singleValueContainer()
                if let b = try? single.decode(Bool.self) {
                    self = .bool(b)
                } else if let n = try? single.decode(Double.self) {
                    self = .number(n)
                } else if let s = try? single.decode(String.self) {
                    self = .string(s)
                } else {
                    throw DecodingError.dataCorruptedError(
                        in: single,
                        debugDescription: "Expected String, Number, or Bool for Form.When.value"
                    )
                }
            }

            public func encode(to encoder: Encoder) throws {
                var single = encoder.singleValueContainer()
                switch self {
                case .string(let s): try single.encode(s)
                case .number(let n): try single.encode(n)
                case .bool(let b): try single.encode(b)
                }
            }
        }

        public let key: String
        public let op: Operator
        public let value: CompareValue

        public init(key: String, op: Operator, value: CompareValue) {
            self.key = key
            self.op = op
            self.value = value
        }
    }

    // parity: schema/src/form.ts#StringField [status=implemented hash=0c2cbee3174f]
    public struct StringField: Equatable, Hashable, Sendable, Codable {
        public enum Format: String, Equatable, Hashable, Sendable, Codable {
            case email
            case uri
            case date
            case dateTime = "date-time"
        }

        public let key: String
        public let title: String?
        public let description: String?
        public let required: Bool?
        public let hidden: Bool?
        public let when: [When]?
        public let format: Format?
        public let minLength: SchemaPrimitive.NonNegativeInt?
        public let maxLength: SchemaPrimitive.NonNegativeInt?
        public let pattern: String?
        public let placeholder: String?
        public let defaultValue: String?
        public let options: [Option]?
        public let custom: Bool?

        public init(
            key: String,
            title: String? = nil,
            description: String? = nil,
            required: Bool? = nil,
            hidden: Bool? = nil,
            when: [When]? = nil,
            format: Format? = nil,
            minLength: SchemaPrimitive.NonNegativeInt? = nil,
            maxLength: SchemaPrimitive.NonNegativeInt? = nil,
            pattern: String? = nil,
            placeholder: String? = nil,
            defaultValue: String? = nil,
            options: [Option]? = nil,
            custom: Bool? = nil
        ) {
            self.key = key
            self.title = title
            self.description = description
            self.required = required
            self.hidden = hidden
            self.when = when
            self.format = format
            self.minLength = minLength
            self.maxLength = maxLength
            self.pattern = pattern
            self.placeholder = placeholder
            self.defaultValue = defaultValue
            self.options = options
            self.custom = custom
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("string", from: container, forKey: .type)
            self.key = try container.decode(String.self, forKey: .key)
            self.title = try container.decodeIfPresent(String.self, forKey: .title)
            self.description = try container.decodeIfPresent(String.self, forKey: .description)
            self.required = try container.decodeIfPresent(Bool.self, forKey: .required)
            self.hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden)
            self.when = try container.decodeIfPresent([When].self, forKey: .when)
            self.format = try container.decodeIfPresent(Format.self, forKey: .format)
            self.minLength = try container.decodeIfPresent(SchemaPrimitive.NonNegativeInt.self, forKey: .minLength)
            self.maxLength = try container.decodeIfPresent(SchemaPrimitive.NonNegativeInt.self, forKey: .maxLength)
            self.pattern = try container.decodeIfPresent(String.self, forKey: .pattern)
            self.placeholder = try container.decodeIfPresent(String.self, forKey: .placeholder)
            self.defaultValue = try container.decodeIfPresent(String.self, forKey: .defaultValue)
            self.options = try container.decodeIfPresent([Option].self, forKey: .options)
            self.custom = try container.decodeIfPresent(Bool.self, forKey: .custom)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("string", forKey: .type)
            try container.encode(key, forKey: .key)
            try container.encodeIfPresent(title, forKey: .title)
            try container.encodeIfPresent(description, forKey: .description)
            try container.encodeIfPresent(required, forKey: .required)
            try container.encodeIfPresent(hidden, forKey: .hidden)
            try container.encodeIfPresent(when, forKey: .when)
            try container.encodeIfPresent(format, forKey: .format)
            try container.encodeIfPresent(minLength, forKey: .minLength)
            try container.encodeIfPresent(maxLength, forKey: .maxLength)
            try container.encodeIfPresent(pattern, forKey: .pattern)
            try container.encodeIfPresent(placeholder, forKey: .placeholder)
            try container.encodeIfPresent(defaultValue, forKey: .defaultValue)
            try container.encodeIfPresent(options, forKey: .options)
            try container.encodeIfPresent(custom, forKey: .custom)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case key
            case title
            case description
            case required
            case hidden
            case when
            case format
            case minLength
            case maxLength
            case pattern
            case placeholder
            case defaultValue = "default"
            case options
            case custom
        }
    }

    // parity: schema/src/form.ts#NumberField [status=implemented hash=6a98b6c27be6]
    public struct NumberField: Equatable, Hashable, Sendable, Codable {
        public let key: String
        public let title: String?
        public let description: String?
        public let required: Bool?
        public let hidden: Bool?
        public let when: [When]?
        public let minimum: Double?
        public let maximum: Double?
        public let defaultValue: Double?

        public init(
            key: String,
            title: String? = nil,
            description: String? = nil,
            required: Bool? = nil,
            hidden: Bool? = nil,
            when: [When]? = nil,
            minimum: Double? = nil,
            maximum: Double? = nil,
            defaultValue: Double? = nil
        ) {
            self.key = key
            self.title = title
            self.description = description
            self.required = required
            self.hidden = hidden
            self.when = when
            self.minimum = minimum
            self.maximum = maximum
            self.defaultValue = defaultValue
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("number", from: container, forKey: .type)
            self.key = try container.decode(String.self, forKey: .key)
            self.title = try container.decodeIfPresent(String.self, forKey: .title)
            self.description = try container.decodeIfPresent(String.self, forKey: .description)
            self.required = try container.decodeIfPresent(Bool.self, forKey: .required)
            self.hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden)
            self.when = try container.decodeIfPresent([When].self, forKey: .when)
            self.minimum = try container.decodeIfPresent(Double.self, forKey: .minimum)
            self.maximum = try container.decodeIfPresent(Double.self, forKey: .maximum)
            self.defaultValue = try container.decodeIfPresent(Double.self, forKey: .defaultValue)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("number", forKey: .type)
            try container.encode(key, forKey: .key)
            try container.encodeIfPresent(title, forKey: .title)
            try container.encodeIfPresent(description, forKey: .description)
            try container.encodeIfPresent(required, forKey: .required)
            try container.encodeIfPresent(hidden, forKey: .hidden)
            try container.encodeIfPresent(when, forKey: .when)
            try container.encodeIfPresent(minimum, forKey: .minimum)
            try container.encodeIfPresent(maximum, forKey: .maximum)
            try container.encodeIfPresent(defaultValue, forKey: .defaultValue)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case key
            case title
            case description
            case required
            case hidden
            case when
            case minimum
            case maximum
            case defaultValue = "default"
        }
    }

    // parity: schema/src/form.ts#IntegerField [status=implemented hash=92aeda781004]
    public struct IntegerField: Equatable, Hashable, Sendable, Codable {
        public let key: String
        public let title: String?
        public let description: String?
        public let required: Bool?
        public let hidden: Bool?
        public let when: [When]?
        public let minimum: Double?
        public let maximum: Double?
        public let defaultValue: Double?

        public init(
            key: String,
            title: String? = nil,
            description: String? = nil,
            required: Bool? = nil,
            hidden: Bool? = nil,
            when: [When]? = nil,
            minimum: Double? = nil,
            maximum: Double? = nil,
            defaultValue: Double? = nil
        ) {
            self.key = key
            self.title = title
            self.description = description
            self.required = required
            self.hidden = hidden
            self.when = when
            self.minimum = minimum
            self.maximum = maximum
            self.defaultValue = defaultValue
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("integer", from: container, forKey: .type)
            self.key = try container.decode(String.self, forKey: .key)
            self.title = try container.decodeIfPresent(String.self, forKey: .title)
            self.description = try container.decodeIfPresent(String.self, forKey: .description)
            self.required = try container.decodeIfPresent(Bool.self, forKey: .required)
            self.hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden)
            self.when = try container.decodeIfPresent([When].self, forKey: .when)
            self.minimum = try container.decodeIfPresent(Double.self, forKey: .minimum)
            self.maximum = try container.decodeIfPresent(Double.self, forKey: .maximum)
            self.defaultValue = try container.decodeIfPresent(Double.self, forKey: .defaultValue)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("integer", forKey: .type)
            try container.encode(key, forKey: .key)
            try container.encodeIfPresent(title, forKey: .title)
            try container.encodeIfPresent(description, forKey: .description)
            try container.encodeIfPresent(required, forKey: .required)
            try container.encodeIfPresent(hidden, forKey: .hidden)
            try container.encodeIfPresent(when, forKey: .when)
            try container.encodeIfPresent(minimum, forKey: .minimum)
            try container.encodeIfPresent(maximum, forKey: .maximum)
            try container.encodeIfPresent(defaultValue, forKey: .defaultValue)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case key
            case title
            case description
            case required
            case hidden
            case when
            case minimum
            case maximum
            case defaultValue = "default"
        }
    }

    // parity: schema/src/form.ts#BooleanField [status=implemented hash=74f7dcd8aa73]
    public struct BooleanField: Equatable, Hashable, Sendable, Codable {
        public let key: String
        public let title: String?
        public let description: String?
        public let required: Bool?
        public let hidden: Bool?
        public let when: [When]?
        public let defaultValue: Bool?

        public init(
            key: String,
            title: String? = nil,
            description: String? = nil,
            required: Bool? = nil,
            hidden: Bool? = nil,
            when: [When]? = nil,
            defaultValue: Bool? = nil
        ) {
            self.key = key
            self.title = title
            self.description = description
            self.required = required
            self.hidden = hidden
            self.when = when
            self.defaultValue = defaultValue
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("boolean", from: container, forKey: .type)
            self.key = try container.decode(String.self, forKey: .key)
            self.title = try container.decodeIfPresent(String.self, forKey: .title)
            self.description = try container.decodeIfPresent(String.self, forKey: .description)
            self.required = try container.decodeIfPresent(Bool.self, forKey: .required)
            self.hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden)
            self.when = try container.decodeIfPresent([When].self, forKey: .when)
            self.defaultValue = try container.decodeIfPresent(Bool.self, forKey: .defaultValue)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("boolean", forKey: .type)
            try container.encode(key, forKey: .key)
            try container.encodeIfPresent(title, forKey: .title)
            try container.encodeIfPresent(description, forKey: .description)
            try container.encodeIfPresent(required, forKey: .required)
            try container.encodeIfPresent(hidden, forKey: .hidden)
            try container.encodeIfPresent(when, forKey: .when)
            try container.encodeIfPresent(defaultValue, forKey: .defaultValue)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case key
            case title
            case description
            case required
            case hidden
            case when
            case defaultValue = "default"
        }
    }

    // parity: schema/src/form.ts#MultiselectField [status=implemented hash=e6abd030150b]
    public struct MultiselectField: Equatable, Hashable, Sendable, Codable {
        public let key: String
        public let title: String?
        public let description: String?
        public let required: Bool?
        public let hidden: Bool?
        public let when: [When]?
        public let options: [Option]
        public let minItems: SchemaPrimitive.NonNegativeInt?
        public let maxItems: SchemaPrimitive.NonNegativeInt?
        public let custom: Bool?
        public let defaultValue: [String]?

        public init(
            key: String,
            title: String? = nil,
            description: String? = nil,
            required: Bool? = nil,
            hidden: Bool? = nil,
            when: [When]? = nil,
            options: [Option],
            minItems: SchemaPrimitive.NonNegativeInt? = nil,
            maxItems: SchemaPrimitive.NonNegativeInt? = nil,
            custom: Bool? = nil,
            defaultValue: [String]? = nil
        ) {
            self.key = key
            self.title = title
            self.description = description
            self.required = required
            self.hidden = hidden
            self.when = when
            self.options = options
            self.minItems = minItems
            self.maxItems = maxItems
            self.custom = custom
            self.defaultValue = defaultValue
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("multiselect", from: container, forKey: .type)
            self.key = try container.decode(String.self, forKey: .key)
            self.title = try container.decodeIfPresent(String.self, forKey: .title)
            self.description = try container.decodeIfPresent(String.self, forKey: .description)
            self.required = try container.decodeIfPresent(Bool.self, forKey: .required)
            self.hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden)
            self.when = try container.decodeIfPresent([When].self, forKey: .when)
            self.options = try container.decode([Option].self, forKey: .options)
            self.minItems = try container.decodeIfPresent(SchemaPrimitive.NonNegativeInt.self, forKey: .minItems)
            self.maxItems = try container.decodeIfPresent(SchemaPrimitive.NonNegativeInt.self, forKey: .maxItems)
            self.custom = try container.decodeIfPresent(Bool.self, forKey: .custom)
            self.defaultValue = try container.decodeIfPresent([String].self, forKey: .defaultValue)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("multiselect", forKey: .type)
            try container.encode(key, forKey: .key)
            try container.encodeIfPresent(title, forKey: .title)
            try container.encodeIfPresent(description, forKey: .description)
            try container.encodeIfPresent(required, forKey: .required)
            try container.encodeIfPresent(hidden, forKey: .hidden)
            try container.encodeIfPresent(when, forKey: .when)
            try container.encode(options, forKey: .options)
            try container.encodeIfPresent(minItems, forKey: .minItems)
            try container.encodeIfPresent(maxItems, forKey: .maxItems)
            try container.encodeIfPresent(custom, forKey: .custom)
            try container.encodeIfPresent(defaultValue, forKey: .defaultValue)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case key
            case title
            case description
            case required
            case hidden
            case when
            case options
            case minItems
            case maxItems
            case custom
            case defaultValue = "default"
        }
    }

    // parity: schema/src/form.ts#ExternalField [status=implemented hash=d9d55fa19688]
    public struct ExternalField: Equatable, Hashable, Sendable, Codable {
        public let key: String
        public let url: String
        public let title: String?
        public let description: String?

        public init(key: String, url: String, title: String? = nil, description: String? = nil) {
            self.key = key
            self.url = url
            self.title = title
            self.description = description
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try SchemaPrimitive.decodeRequiredLiteral("external", from: container, forKey: .type)
            self.key = try container.decode(String.self, forKey: .key)
            self.url = try container.decode(String.self, forKey: .url)
            self.title = try container.decodeIfPresent(String.self, forKey: .title)
            self.description = try container.decodeIfPresent(String.self, forKey: .description)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("external", forKey: .type)
            try container.encode(key, forKey: .key)
            try container.encode(url, forKey: .url)
            try container.encodeIfPresent(title, forKey: .title)
            try container.encodeIfPresent(description, forKey: .description)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case key
            case url
            case title
            case description
        }
    }

    // parity: schema/src/form.ts#Field [status=implemented hash=d90edb2acf26]
    public enum Field: Equatable, Hashable, Sendable, Codable {
        case string(StringField)
        case number(NumberField)
        case integer(IntegerField)
        case boolean(BooleanField)
        case multiselect(MultiselectField)
        case external(ExternalField)

        enum TagKeys: String, CodingKey {
            case type
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: TagKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "string":
                self = .string(try StringField(from: decoder))
            case "number":
                self = .number(try NumberField(from: decoder))
            case "integer":
                self = .integer(try IntegerField(from: decoder))
            case "boolean":
                self = .boolean(try BooleanField(from: decoder))
            case "multiselect":
                self = .multiselect(try MultiselectField(from: decoder))
            case "external":
                self = .external(try ExternalField(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown Form.Field type '\(type)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .string(let v): try v.encode(to: encoder)
            case .number(let v): try v.encode(to: encoder)
            case .integer(let v): try v.encode(to: encoder)
            case .boolean(let v): try v.encode(to: encoder)
            case .multiselect(let v): try v.encode(to: encoder)
            case .external(let v): try v.encode(to: encoder)
            }
        }
    }

    /// Non-empty list of form fields matching `Schema.NonEmptyArray(Field)`.
    // parity: schema/src/form.ts#Fields [status=implemented hash=11bdfb9fafcd]
    public struct Fields: Equatable, Hashable, Sendable, Codable, RandomAccessCollection {
        public let elements: [Field]

        public init?(_ elements: [Field]) {
            guard !elements.isEmpty else { return nil }
            self.elements = elements
        }

        public init(first: Field, rest: [Field] = []) {
            self.elements = [first] + rest
        }

        public var startIndex: Int { elements.startIndex }
        public var endIndex: Int { elements.endIndex }
        public subscript(position: Int) -> Field { elements[position] }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let list = try container.decode([Field].self)
            guard !list.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Form.Fields must contain at least 1 field"
                )
            }
            self.elements = list
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(elements)
        }
    }

    // parity: schema/src/form.ts#Info [status=implemented hash=86e88b75a684]
    public struct Info: Equatable, Hashable, Sendable, Codable {
        public let id: ID
        public let sessionID: String
        public let title: String
        public let metadata: Metadata?
        public let fields: Fields

        public init(id: ID, sessionID: String, title: String, metadata: Metadata? = nil, fields: Fields) {
            self.id = id
            self.sessionID = sessionID
            self.title = title
            self.metadata = metadata
            self.fields = fields
        }
    }

    // parity: schema/src/form.ts#Value [status=implemented hash=3c61399f0cc7]
    public enum Value: Equatable, Hashable, Sendable, Codable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case strings([String])

        public var asJSONValue: JSONValue {
            switch self {
            case .string(let s):
                return .string(s)
            case .number(let n):
                if n.isFinite && n.rounded(.towardZero) == n && abs(n) < 9_007_199_254_740_992.0 {
                    return .int(Int64(n))
                }
                return .double(n)
            case .bool(let b):
                return .bool(b)
            case .strings(let arr):
                return .array(arr.map { .string($0) })
            }
        }

        public init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let b = try? single.decode(Bool.self) {
                self = .bool(b)
            } else if let n = try? single.decode(Double.self) {
                self = .number(n)
            } else if let s = try? single.decode(String.self) {
                self = .string(s)
            } else if let arr = try? single.decode([String].self) {
                self = .strings(arr)
            } else {
                throw DecodingError.dataCorruptedError(
                    in: single,
                    debugDescription: "Expected String, Number, Bool, or [String] for Form.Value"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var single = encoder.singleValueContainer()
            switch self {
            case .string(let s): try single.encode(s)
            case .number(let n): try single.encode(n)
            case .bool(let b): try single.encode(b)
            case .strings(let arr): try single.encode(arr)
            }
        }
    }

    // parity: schema/src/form.ts#Answer [status=implemented hash=ea87ec659a3d]
    public typealias Answer = [String: Value]

    // parity: schema/src/form.ts#State [status=implemented hash=2b2cc8e3af1f]
    public enum State: Equatable, Hashable, Sendable, Codable {
        case pending
        case answered(answer: Answer)
        case cancelled(message: String? = nil)

        enum CodingKeys: String, CodingKey {
            case status
            case answer
            case message
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let status = try container.decode(String.self, forKey: .status)
            switch status {
            case "pending":
                self = .pending
            case "answered":
                self = .answered(answer: try container.decode(Answer.self, forKey: .answer))
            case "cancelled":
                self = .cancelled(message: try container.decodeIfPresent(String.self, forKey: .message))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .status,
                    in: container,
                    debugDescription: "Unknown Form.State status '\(status)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .pending:
                try container.encode("pending", forKey: .status)
            case .answered(let answer):
                try container.encode("answered", forKey: .status)
                try container.encode(answer, forKey: .answer)
            case .cancelled(let message):
                try container.encode("cancelled", forKey: .status)
                try container.encodeIfPresent(message, forKey: .message)
            }
        }
    }

    // parity: schema/src/form.ts#Detail [status=implemented hash=f379795d3319]
    public struct Detail: Equatable, Hashable, Sendable, Codable {
        public let id: ID
        public let sessionID: String
        public let title: String
        public let metadata: Metadata?
        public let fields: Fields
        public let state: State

        public init(
            id: ID,
            sessionID: String,
            title: String,
            metadata: Metadata? = nil,
            fields: Fields,
            state: State
        ) {
            self.id = id
            self.sessionID = sessionID
            self.title = title
            self.metadata = metadata
            self.fields = fields
            self.state = state
        }
    }

    // parity: schema/src/form.ts#Reply [status=implemented hash=5e092215cebb]
    public struct Reply: Equatable, Hashable, Sendable, Codable {
        public let answer: Answer

        public init(answer: Answer) {
            self.answer = answer
        }
    }

    // parity: schema/src/form.ts#Event [status=implemented hash=e84064a3c12a]
    public enum Event {
        public struct CreatedPayload: Equatable, Hashable, Sendable, Codable {
            public let form: Info

            public init(form: Info) {
                self.form = form
            }
        }

        public struct RepliedPayload: Equatable, Hashable, Sendable, Codable {
            public let id: ID
            public let sessionID: String
            public let answer: Answer

            public init(id: ID, sessionID: String, answer: Answer) {
                self.id = id
                self.sessionID = sessionID
                self.answer = answer
            }
        }

        public struct CancelledPayload: Equatable, Hashable, Sendable, Codable {
            public let id: ID
            public let sessionID: String

            public init(id: ID, sessionID: String) {
                self.id = id
                self.sessionID = sessionID
            }
        }

        public static let created = SchemaPrimitive.EventDescriptor.ephemeral(type: "form.created")
        public static let replied = SchemaPrimitive.EventDescriptor.ephemeral(type: "form.replied")
        public static let cancelled = SchemaPrimitive.EventDescriptor.ephemeral(type: "form.cancelled")
        public static let definitions: [SchemaPrimitive.EventDescriptor] = [created, replied, cancelled]
    }
}

// MARK: - src/rpc.ts

public enum RpcSchema {
    public enum DefinitionError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        case reservedErrorName(String)

        public var description: String {
            switch self {
            case .reservedErrorName(let name):
                return "RPC error names starting with \"rpc.\" are reserved: \(name)"
            }
        }
    }

    // parity: schema/src/rpc.ts#ErrorMap [status=implemented hash=b2c6ec296416]
    public typealias ErrorMap = [String: ToolSchema.ValueSchema]

    // parity: schema/src/rpc.ts#Method [status=implemented hash=c96ad4b083bf]
    public struct Method: Equatable, Hashable, Sendable, Codable {
        public let input: ToolSchema.ValueSchema
        public let output: ToolSchema.ValueSchema
        public let errors: ErrorMap?

        public init(
            input: ToolSchema.ValueSchema,
            output: ToolSchema.ValueSchema,
            errors: ErrorMap? = nil
        ) {
            self.input = input
            self.output = output
            self.errors = errors
        }
    }

    // parity: schema/src/rpc.ts#PortableValueSchema [status=implemented hash=d66eafcd9eec]
    public typealias PortableValueSchema = ToolSchema.ValueSchema

    // parity: schema/src/rpc.ts#PortableMethod [status=implemented hash=88d35b298ddb]
    public struct PortableMethod: Equatable, Hashable, Sendable, Codable {
        public let input: PortableValueSchema
        public let output: PortableValueSchema
        public let errors: [String: PortableValueSchema]?

        public init(
            input: PortableValueSchema,
            output: PortableValueSchema,
            errors: [String: PortableValueSchema]? = nil
        ) {
            self.input = input
            self.output = output
            self.errors = errors
        }
    }

    // parity: schema/src/rpc.ts#EventDefinition [status=implemented hash=fa66033339fe]
    public struct EventDefinition: Equatable, Hashable, Sendable, Codable {
        public let schema: ToolSchema.ValueSchema

        public init(schema: ToolSchema.ValueSchema) {
            self.schema = schema
        }
    }

    // parity: schema/src/rpc.ts#PortableEventDefinition [status=implemented hash=162ab23f1fd7]
    public typealias PortableEventDefinition = EventDefinition

    // parity: schema/src/rpc.ts#Definition [status=implemented hash=2eb535fa4a85]
    public struct Definition: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let methods: [String: Method]
        public let events: [String: EventDefinition]

        public init(id: String, methods: [String: Method], events: [String: EventDefinition] = [:]) {
            self.id = id
            self.methods = methods
            self.events = events
        }
    }

    // parity: schema/src/rpc.ts#PortableDefinition [status=implemented hash=24374cc6efb5]
    public struct PortableDefinition: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let methods: [String: PortableMethod]
        public let events: [String: PortableEventDefinition]

        public init(id: String, methods: [String: PortableMethod], events: [String: PortableEventDefinition] = [:]) {
            self.id = id
            self.methods = methods
            self.events = events
        }
    }

    /// Validates and returns an RPC definition, rejecting any method error name starting with `"rpc."`.
    // parity: schema/src/rpc.ts#define [status=implemented hash=9330bd9834be]
    public static func define(_ definition: Definition) throws(DefinitionError) -> Definition {
        for method in definition.methods.values {
            if let errors = method.errors {
                for name in errors.keys where name.hasPrefix("rpc.") {
                    throw .reservedErrorName(name)
                }
            }
        }
        return definition
    }

    /// Overload validating a `PortableDefinition`.
    public static func define(_ definition: PortableDefinition) throws(DefinitionError) -> PortableDefinition {
        for method in definition.methods.values {
            if let errors = method.errors {
                for name in errors.keys where name.hasPrefix("rpc.") {
                    throw .reservedErrorName(name)
                }
            }
        }
        return definition
    }

    // parity: schema/src/rpc.ts#Input [status=adapted hash=3c19a1ac7e39]
    public typealias Input<T> = T

    // parity: schema/src/rpc.ts#Output [status=adapted hash=7963947ad03f]
    public typealias Output<T> = T

    // parity: schema/src/rpc.ts#HandlerOutput [status=adapted hash=319bc9cbd24e]
    public typealias HandlerOutput<T> = T

    // parity: schema/src/rpc.ts#Failure [status=implemented hash=407dfb9cf603]
    public struct Failure<Data: Equatable & Hashable & Sendable & Codable>: Swift.Error, Equatable, Hashable, Sendable, Codable {
        public let type: String
        public let message: String
        public let data: Data?

        public init(type: String, message: String, data: Data? = nil) {
            self.type = type
            self.message = message
            self.data = data
        }
    }

    public enum SystemErrorCode: String, Equatable, Hashable, Sendable, Codable {
        case unavailable = "rpc.unavailable"
        case methodNotFound = "rpc.method_not_found"
        case invalidInput = "rpc.invalid_input"
        case invalidOutput = "rpc.invalid_output"
        case `internal` = "rpc.internal"
    }

    // parity: schema/src/rpc.ts#SystemError [status=implemented hash=f70d3c09a345]
    public struct SystemError: Swift.Error, Equatable, Hashable, Sendable, Codable {
        public let type: SystemErrorCode
        public let message: String

        public init(type: SystemErrorCode, message: String) {
            self.type = type
            self.message = message
        }
    }

    // parity: schema/src/rpc.ts#ErrorName [status=adapted hash=6948f18d0352]
    public typealias ErrorName = String

    // parity: schema/src/rpc.ts#HandlerErrorFor [status=adapted hash=52995e5888a3]
    public struct HandlerErrorFor<Data: Equatable & Hashable & Sendable & Codable>: Swift.Error, Equatable, Hashable, Sendable, Codable {
        public let type: ErrorName
        public let message: String
        public let data: Data?

        public init(type: ErrorName, message: String, data: Data? = nil) {
            self.type = type
            self.message = message
            self.data = data
        }
    }

    // parity: schema/src/rpc.ts#HandlerError [status=adapted hash=bddde09de14b]
    public typealias HandlerError = HandlerErrorFor<JSONValue>

    // parity: schema/src/rpc.ts#MethodErrorFor [status=adapted hash=2fb86fcedeba]
    public typealias MethodErrorFor<Data: Equatable & Hashable & Sendable & Codable> = Failure<Data>

    // parity: schema/src/rpc.ts#MethodError [status=adapted hash=ca74fa55cb59]
    public typealias MethodError = Failure<JSONValue>

    // parity: schema/src/rpc.ts#ErrorArguments [status=adapted hash=cf08224804c6]
    public struct ErrorArguments<Data: Equatable & Hashable & Sendable & Codable>: Equatable, Hashable, Sendable {
        public let type: ErrorName
        public let message: String
        public let data: Data?

        public init(type: ErrorName, message: String, data: Data? = nil) {
            self.type = type
            self.message = message
            self.data = data
        }
    }

    // parity: schema/src/rpc.ts#ErrorFactory [status=adapted hash=f5742d91825e]
    public typealias ErrorFactory<Data: Equatable & Hashable & Sendable & Codable> =
        @Sendable (ErrorName, String, Data?) -> HandlerErrorFor<Data>

    // parity: schema/src/rpc.ts#EventInputData [status=adapted hash=3e3e4ee6fef9]
    public typealias EventInputData = [String: JSONValue]

    // parity: schema/src/rpc.ts#EventData [status=adapted hash=31f7f483cc05]
    public typealias EventData = [String: JSONValue]

    // parity: schema/src/rpc.ts#EventInput [status=adapted hash=cc1fb1d63420]
    public struct EventInput: Equatable, Hashable, Sendable, Codable {
        public let name: String
        public let data: EventInputData

        public init(name: String, data: EventInputData) {
            self.name = name
            self.data = data
        }
    }

    // parity: schema/src/rpc.ts#EventPayload [status=implemented hash=2ae73169af88]
    public struct EventPayload: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let type: String
        public let created: Double
        public let data: EventData
        public let location: LocationSchema.Ref
        public let metadata: [String: JSONValue]?

        public init(
            id: String,
            type: String,
            created: Double,
            data: EventData,
            location: LocationSchema.Ref,
            metadata: [String: JSONValue]? = nil
        ) {
            self.id = id
            self.type = type
            self.created = created
            self.data = data
            self.location = location
            self.metadata = metadata
        }

        public static func eventType(rpcID: String, eventName: String) -> String {
            "rpc.\(rpcID).\(eventName)"
        }
    }
}
