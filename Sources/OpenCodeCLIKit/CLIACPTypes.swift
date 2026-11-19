#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import OpenCodeClient
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeTUI
import OpenCodeUtil

/// Complete Agent Client Protocol (ACP) bridge, wire models, translators, and JSON-RPC NDJSON
/// transport ported from `packages/cli/src/acp/*`.
public enum CLIACP {

    // MARK: - JSON-RPC 2.0 & ACP Protocol Error

    public enum JSONRPCId: Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        case int(Int64)
        case string(String)

        public var description: String {
            switch self {
            case .int(let value): String(value)
            case .string(let value): value
            }
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let intVal = try? container.decode(Int64.self) {
                self = .int(intVal)
            } else if let strVal = try? container.decode(String.self) {
                self = .string(strVal)
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "JSON-RPC id must be an integer or string"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .int(let value): try container.encode(value)
            case .string(let value): try container.encode(value)
            }
        }
    }

    public struct JSONRPCErrorObject: Equatable, Hashable, Sendable, Codable {
        public let code: Int
        public let message: String
        public let data: JSONValue?

        public init(code: Int, message: String, data: JSONValue? = nil) {
            self.code = code
            self.message = message
            self.data = data
        }
    }

    public struct RequestError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let code: Int
        public let message: String
        public let data: JSONValue?

        public init(code: Int, message: String, data: JSONValue? = nil) {
            self.code = code
            self.message = message
            self.data = data
        }

        public var description: String {
            "RequestError(\(code)): \(message)"
        }

        public func toErrorResponse() -> JSONRPCErrorObject {
            JSONRPCErrorObject(code: code, message: message, data: data)
        }

        public static func parseError(data: JSONValue? = nil, detail: String? = nil) -> RequestError {
            RequestError(
                code: -32700,
                message: detail.map { "Parse error: \($0)" } ?? "Parse error",
                data: data
            )
        }

        public static func invalidRequest(data: JSONValue? = nil, detail: String? = nil) -> RequestError {
            RequestError(
                code: -32600,
                message: detail.map { "Invalid Request: \($0)" } ?? "Invalid Request",
                data: data
            )
        }

        public static func methodNotFound(_ method: String) -> RequestError {
            RequestError(code: -32601, message: "Method not found: \(method)")
        }

        public static func invalidParams(data: [String: JSONValue]? = nil, detail: String? = nil) -> RequestError {
            RequestError(
                code: -32602,
                message: detail.map { "Invalid params: \($0)" } ?? "Invalid params",
                data: data.map { .object($0) }
            )
        }

        public static func internalError(data: [String: JSONValue]? = nil, detail: String? = nil) -> RequestError {
            RequestError(
                code: -32603,
                message: detail.map { "Internal error: \($0)" } ?? "Internal error",
                data: data.map { .object($0) }
            )
        }

        public static func authRequired(data: [String: JSONValue]? = nil, detail: String? = nil) -> RequestError {
            RequestError(
                code: -32000,
                message: detail.map { "Authentication required: \($0)" } ?? "Authentication required",
                data: data.map { .object($0) }
            )
        }
    }

    public enum JSONRPCMessage: Equatable, Hashable, Sendable, Codable {
        case request(id: JSONRPCId, method: String, params: JSONValue? = nil)
        case notification(method: String, params: JSONValue? = nil)
        case response(id: JSONRPCId, result: JSONValue)
        case errorResponse(id: JSONRPCId?, error: JSONRPCErrorObject)

        private enum CodingKeys: String, CodingKey {
            case jsonrpc
            case id
            case method
            case params
            case result
            case error
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let version = try c.decodeIfPresent(String.self, forKey: .jsonrpc)
            if let version, version != "2.0" {
                throw DecodingError.dataCorruptedError(
                    forKey: .jsonrpc,
                    in: c,
                    debugDescription: "Expected jsonrpc '2.0', got '\(version)'"
                )
            }
            if let method = try c.decodeIfPresent(String.self, forKey: .method) {
                let params = try c.decodeIfPresent(JSONValue.self, forKey: .params)
                if let id = try c.decodeIfPresent(JSONRPCId.self, forKey: .id) {
                    self = .request(id: id, method: method, params: params)
                } else {
                    self = .notification(method: method, params: params)
                }
            } else if let error = try c.decodeIfPresent(JSONRPCErrorObject.self, forKey: .error) {
                let id = try c.decodeIfPresent(JSONRPCId.self, forKey: .id)
                self = .errorResponse(id: id, error: error)
            } else if c.contains(.result) {
                let id = try c.decode(JSONRPCId.self, forKey: .id)
                let result = try c.decode(JSONValue.self, forKey: .result)
                self = .response(id: id, result: result)
            } else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "JSON-RPC message must contain method, result, or error"
                    )
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("2.0", forKey: .jsonrpc)
            switch self {
            case .request(let id, let method, let params):
                try c.encode(id, forKey: .id)
                try c.encode(method, forKey: .method)
                try c.encodeIfPresent(params, forKey: .params)
            case .notification(let method, let params):
                try c.encode(method, forKey: .method)
                try c.encodeIfPresent(params, forKey: .params)
            case .response(let id, let result):
                try c.encode(id, forKey: .id)
                try c.encode(result, forKey: .result)
            case .errorResponse(let id, let error):
                if let id {
                    try c.encode(id, forKey: .id)
                } else {
                    try c.encodeNil(forKey: .id)
                }
                try c.encode(error, forKey: .error)
            }
        }
    }

    public enum Methods {
        public static let initialize = "initialize"
        public static let authenticate = "authenticate"
        public static let sessionNew = "session/new"
        public static let sessionLoad = "session/load"
        public static let sessionList = "session/list"
        public static let sessionDelete = "session/delete"
        public static let sessionResume = "session/resume"
        public static let sessionClose = "session/close"
        public static let sessionFork = "session/fork"
        public static let sessionSetConfigOption = "session/set_config_option"
        public static let sessionSetMode = "session/set_mode"
        public static let sessionPrompt = "session/prompt"
        public static let sessionCancel = "session/cancel"
        public static let sessionSteering = "_session/steering"

        public static let clientSessionUpdate = "session/update"
        public static let clientSessionRequestPermission = "session/request_permission"
        public static let clientElicitationCreate = "elicitation/create"
        public static let cancelRequest = "$/cancel_request"
    }

    // MARK: - ACP Protocol Wire Types

    public struct EmptyObject: Equatable, Hashable, Sendable, Codable {
        public init() {}
    }

    public struct ClientAuthCapabilities: Equatable, Hashable, Sendable, Codable {
        public let terminal: Bool?

        public init(terminal: Bool? = nil) {
            self.terminal = terminal
        }
    }

    public struct ClientElicitationCapabilities: Equatable, Hashable, Sendable, Codable {
        public let form: JSONValue?
        public let url: JSONValue?

        public init(form: JSONValue? = nil, url: JSONValue? = nil) {
            self.form = form
            self.url = url
        }
    }

    public struct ClientSessionCapabilities: Equatable, Hashable, Sendable, Codable {
        public let compaction: JSONValue?

        public init(compaction: JSONValue? = nil) {
            self.compaction = compaction
        }
    }

    public struct ClientCapabilities: Equatable, Hashable, Sendable, Codable {
        public let auth: ClientAuthCapabilities?
        public let elicitation: ClientElicitationCapabilities?
        public let session: ClientSessionCapabilities?
        public let fs: JSONValue?
        public let terminal: Bool?
        public let _meta: [String: JSONValue]?

        public init(
            auth: ClientAuthCapabilities? = nil,
            elicitation: ClientElicitationCapabilities? = nil,
            session: ClientSessionCapabilities? = nil,
            fs: JSONValue? = nil,
            terminal: Bool? = nil,
            _meta: [String: JSONValue]? = nil
        ) {
            self.auth = auth
            self.elicitation = elicitation
            self.session = session
            self.fs = fs
            self.terminal = terminal
            self._meta = _meta
        }
    }

    public struct McpCapabilities: Equatable, Hashable, Sendable, Codable {
        public let http: Bool
        public let sse: Bool

        public init(http: Bool = true, sse: Bool = false) {
            self.http = http
            self.sse = sse
        }
    }

    public struct PromptCapabilities: Equatable, Hashable, Sendable, Codable {
        public let embeddedContext: Bool
        public let image: Bool

        public init(embeddedContext: Bool = true, image: Bool = true) {
            self.embeddedContext = embeddedContext
            self.image = image
        }
    }

    public struct AgentSessionCapabilities: Equatable, Hashable, Sendable, Codable {
        public let additionalDirectories: EmptyObject
        public let close: EmptyObject
        public let delete: EmptyObject
        public let fork: EmptyObject
        public let list: EmptyObject
        public let resume: EmptyObject

        public init(
            additionalDirectories: EmptyObject = EmptyObject(),
            close: EmptyObject = EmptyObject(),
            delete: EmptyObject = EmptyObject(),
            fork: EmptyObject = EmptyObject(),
            list: EmptyObject = EmptyObject(),
            resume: EmptyObject = EmptyObject()
        ) {
            self.additionalDirectories = additionalDirectories
            self.close = close
            self.delete = delete
            self.fork = fork
            self.list = list
            self.resume = resume
        }
    }

    public struct AgentCapabilities: Equatable, Hashable, Sendable, Codable {
        public let loadSession: Bool
        public let mcpCapabilities: McpCapabilities
        public let promptCapabilities: PromptCapabilities
        public let sessionCapabilities: AgentSessionCapabilities
        public let _meta: [String: JSONValue]?

        public init(
            loadSession: Bool = true,
            mcpCapabilities: McpCapabilities = McpCapabilities(),
            promptCapabilities: PromptCapabilities = PromptCapabilities(),
            sessionCapabilities: AgentSessionCapabilities = AgentSessionCapabilities(),
            _meta: [String: JSONValue]? = nil
        ) {
            self.loadSession = loadSession
            self.mcpCapabilities = mcpCapabilities
            self.promptCapabilities = promptCapabilities
            self.sessionCapabilities = sessionCapabilities
            self._meta = _meta
        }
    }

    public struct AuthMethod: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let name: String
        public let description: String
        public let type: String?
        public let args: [String]?
        public var _meta: [String: JSONValue]?

        public init(
            id: String,
            name: String,
            description: String,
            type: String? = nil,
            args: [String]? = nil,
            _meta: [String: JSONValue]? = nil
        ) {
            self.id = id
            self.name = name
            self.description = description
            self.type = type
            self.args = args
            self._meta = _meta
        }
    }

    public struct AgentInfo: Equatable, Hashable, Sendable, Codable {
        public let name: String
        public let version: String

        public init(name: String, version: String) {
            self.name = name
            self.version = version
        }
    }

    public struct InitializeRequest: Equatable, Hashable, Sendable, Codable {
        public let protocolVersion: Int
        public let clientCapabilities: ClientCapabilities?
        public let clientInfo: AgentInfo?

        public init(
            protocolVersion: Int = 1,
            clientCapabilities: ClientCapabilities? = nil,
            clientInfo: AgentInfo? = nil
        ) {
            self.protocolVersion = protocolVersion
            self.clientCapabilities = clientCapabilities
            self.clientInfo = clientInfo
        }
    }

    public struct InitializeResponse: Equatable, Hashable, Sendable, Codable {
        public let protocolVersion: Int
        public let agentCapabilities: AgentCapabilities
        public let authMethods: [AuthMethod]
        public let _meta: [String: JSONValue]?
        public let agentInfo: AgentInfo

        public init(
            protocolVersion: Int,
            agentCapabilities: AgentCapabilities,
            authMethods: [AuthMethod],
            _meta: [String: JSONValue]? = nil,
            agentInfo: AgentInfo
        ) {
            self.protocolVersion = protocolVersion
            self.agentCapabilities = agentCapabilities
            self.authMethods = authMethods
            self._meta = _meta
            self.agentInfo = agentInfo
        }
    }

    public struct AuthenticateRequest: Equatable, Hashable, Sendable, Codable {
        public let methodId: String

        public init(methodId: String) {
            self.methodId = methodId
        }
    }

    public typealias AuthenticateResponse = EmptyObject

    public struct NameValuePair: Equatable, Hashable, Sendable, Codable {
        public let name: String
        public let value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    public struct McpServerStdio: Equatable, Hashable, Sendable, Codable {
        public let name: String
        public let command: String
        public let args: [String]
        public let env: [NameValuePair]

        public init(name: String, command: String, args: [String] = [], env: [NameValuePair] = []) {
            self.name = name
            self.command = command
            self.args = args
            self.env = env
        }
    }

    public struct McpServerHttp: Equatable, Hashable, Sendable, Codable {
        public let type: String
        public let name: String
        public let url: String
        public let headers: [NameValuePair]

        public init(name: String, url: String, headers: [NameValuePair] = []) {
            self.type = "http"
            self.name = name
            self.url = url
            self.headers = headers
        }
    }

    public struct McpServerUnsupported: Equatable, Hashable, Sendable, Codable {
        public let type: String
        public let name: String
        public let url: String?

        public init(type: String, name: String, url: String? = nil) {
            self.type = type
            self.name = name
            self.url = url
        }
    }

    public enum McpServer: Equatable, Hashable, Sendable, Codable {
        case stdio(McpServerStdio)
        case http(McpServerHttp)
        case sse(McpServerUnsupported)
        case acp(McpServerUnsupported)

        private enum TagKeys: String, CodingKey {
            case type
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: TagKeys.self)
            guard let type = try c.decodeIfPresent(String.self, forKey: .type) else {
                self = .stdio(try McpServerStdio(from: decoder))
                return
            }
            switch type {
            case "http":
                self = .http(try McpServerHttp(from: decoder))
            case "sse":
                self = .sse(try McpServerUnsupported(from: decoder))
            case "acp":
                self = .acp(try McpServerUnsupported(from: decoder))
            default:
                self = .acp(try McpServerUnsupported(from: decoder))
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .stdio(let s): try s.encode(to: encoder)
            case .http(let h): try h.encode(to: encoder)
            case .sse(let u): try u.encode(to: encoder)
            case .acp(let u): try u.encode(to: encoder)
            }
        }
    }

    public struct SessionConfigSelectOption: Equatable, Hashable, Sendable, Codable {
        public let value: String
        public let name: String
        public let description: String?

        public init(value: String, name: String, description: String? = nil) {
            self.value = value
            self.name = name
            self.description = description
        }
    }

    public struct SessionConfigOption: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let name: String
        public let description: String?
        public let category: String
        public let type: String
        public let currentValue: String
        public let options: [SessionConfigSelectOption]

        public init(
            id: String,
            name: String,
            description: String? = nil,
            category: String,
            type: String = "select",
            currentValue: String,
            options: [SessionConfigSelectOption]
        ) {
            self.id = id
            self.name = name
            self.description = description
            self.category = category
            self.type = type
            self.currentValue = currentValue
            self.options = options
        }
    }

    public struct AvailableCommand: Equatable, Hashable, Sendable, Codable {
        public let name: String
        public let description: String

        public init(name: String, description: String) {
            self.name = name
            self.description = description
        }
    }

    public struct NewSessionRequest: Equatable, Hashable, Sendable, Codable {
        public let cwd: String
        public let additionalDirectories: [String]?
        public let mcpServers: [McpServer]?

        public init(cwd: String, additionalDirectories: [String]? = nil, mcpServers: [McpServer]? = nil) {
            self.cwd = cwd
            self.additionalDirectories = additionalDirectories
            self.mcpServers = mcpServers
        }
    }

    public struct NewSessionResponse: Equatable, Hashable, Sendable, Codable {
        public let sessionId: String
        public let configOptions: [SessionConfigOption]

        public init(sessionId: String, configOptions: [SessionConfigOption]) {
            self.sessionId = sessionId
            self.configOptions = configOptions
        }
    }

    public struct LoadSessionRequest: Equatable, Hashable, Sendable, Codable {
        public let sessionId: String
        public let cwd: String
        public let additionalDirectories: [String]?
        public let mcpServers: [McpServer]?

        public init(
            sessionId: String,
            cwd: String,
            additionalDirectories: [String]? = nil,
            mcpServers: [McpServer]? = nil
        ) {
            self.sessionId = sessionId
            self.cwd = cwd
            self.additionalDirectories = additionalDirectories
            self.mcpServers = mcpServers
        }
    }

    public struct LoadSessionResponse: Equatable, Hashable, Sendable, Codable {
        public let configOptions: [SessionConfigOption]

        public init(configOptions: [SessionConfigOption]) {
            self.configOptions = configOptions
        }
    }

    public struct ListSessionsRequest: Equatable, Hashable, Sendable, Codable {
        public let cwd: String?
        public let cursor: String?

        public init(cwd: String? = nil, cursor: String? = nil) {
            self.cwd = cwd
            self.cursor = cursor
        }
    }

    public struct SessionListEntry: Equatable, Hashable, Sendable, Codable {
        public let sessionId: String
        public let cwd: String
        public let additionalDirectories: [String]?
        public let title: String
        public let updatedAt: String

        public init(
            sessionId: String,
            cwd: String,
            additionalDirectories: [String]? = nil,
            title: String,
            updatedAt: String
        ) {
            self.sessionId = sessionId
            self.cwd = cwd
            self.additionalDirectories = additionalDirectories
            self.title = title
            self.updatedAt = updatedAt
        }
    }

    public struct ListSessionsResponse: Equatable, Hashable, Sendable, Codable {
        public let sessions: [SessionListEntry]
        public let nextCursor: String?

        public init(sessions: [SessionListEntry], nextCursor: String? = nil) {
            self.sessions = sessions
            self.nextCursor = nextCursor
        }
    }

    public struct DeleteSessionRequest: Equatable, Hashable, Sendable, Codable {
        public let sessionId: String

        public init(sessionId: String) {
            self.sessionId = sessionId
        }
    }

    public typealias DeleteSessionResponse = EmptyObject

    public struct ResumeSessionRequest: Equatable, Hashable, Sendable, Codable {
        public let sessionId: String
        public let cwd: String
        public let additionalDirectories: [String]?
        public let mcpServers: [McpServer]?

        public init(
            sessionId: String,
            cwd: String,
            additionalDirectories: [String]? = nil,
            mcpServers: [McpServer]? = nil
        ) {
            self.sessionId = sessionId
            self.cwd = cwd
            self.additionalDirectories = additionalDirectories
            self.mcpServers = mcpServers
        }
    }

    public struct ResumeSessionResponse: Equatable, Hashable, Sendable, Codable {
        public let configOptions: [SessionConfigOption]

        public init(configOptions: [SessionConfigOption]) {
            self.configOptions = configOptions
        }
    }

    public struct CloseSessionRequest: Equatable, Hashable, Sendable, Codable {
        public let sessionId: String

        public init(sessionId: String) {
            self.sessionId = sessionId
        }
    }

    public typealias CloseSessionResponse = EmptyObject

    public struct ForkSessionRequest: Equatable, Hashable, Sendable, Codable {
        public let sessionId: String
        public let cwd: String
        public let additionalDirectories: [String]?
        public let mcpServers: [McpServer]?

        public init(
            sessionId: String,
            cwd: String,
            additionalDirectories: [String]? = nil,
            mcpServers: [McpServer]? = nil
        ) {
            self.sessionId = sessionId
            self.cwd = cwd
            self.additionalDirectories = additionalDirectories
            self.mcpServers = mcpServers
        }
    }

    public struct ForkSessionResponse: Equatable, Hashable, Sendable, Codable {
        public let sessionId: String
        public let configOptions: [SessionConfigOption]

        public init(sessionId: String, configOptions: [SessionConfigOption]) {
            self.sessionId = sessionId
            self.configOptions = configOptions
        }
    }

    public struct SetSessionConfigOptionRequest: Equatable, Hashable, Sendable, Codable {
        public let sessionId: String
        public let configId: String
        public let value: JSONValue

        public init(sessionId: String, configId: String, value: JSONValue) {
            self.sessionId = sessionId
            self.configId = configId
            self.value = value
        }

        public init(sessionId: String, configId: String, value: String) {
            self.sessionId = sessionId
            self.configId = configId
            self.value = .string(value)
        }
    }

    public struct SetSessionConfigOptionResponse: Equatable, Hashable, Sendable, Codable {
        public let configOptions: [SessionConfigOption]

        public init(configOptions: [SessionConfigOption]) {
            self.configOptions = configOptions
        }
    }

    public struct SetSessionModeRequest: Equatable, Hashable, Sendable, Codable {
        public let sessionId: String
        public let modeId: String

        public init(sessionId: String, modeId: String) {
            self.sessionId = sessionId
            self.modeId = modeId
        }
    }

    public typealias SetSessionModeResponse = EmptyObject

    public struct CancelNotification: Equatable, Hashable, Sendable, Codable {
        public let sessionId: String

        public init(sessionId: String) {
            self.sessionId = sessionId
        }
    }

    public struct ContentAnnotations: Equatable, Hashable, Sendable, Codable {
        public let audience: [String]?
        public let priority: Double?

        public init(audience: [String]? = nil, priority: Double? = nil) {
            self.audience = audience
            self.priority = priority
        }
    }

    public struct ResourceLink: Equatable, Hashable, Sendable, Codable {
        public let uri: String
        public let name: String
        public let mimeType: String?
        public let title: String?
        public let description: String?

        public init(
            uri: String,
            name: String,
            mimeType: String? = nil,
            title: String? = nil,
            description: String? = nil
        ) {
            self.uri = uri
            self.name = name
            self.mimeType = mimeType
            self.title = title
            self.description = description
        }
    }

    public enum EmbeddedResource: Equatable, Hashable, Sendable, Codable {
        case text(uri: String, text: String, mimeType: String? = nil)
        case blob(uri: String, blob: String, mimeType: String? = nil)

        private enum CodingKeys: String, CodingKey {
            case uri
            case text
            case blob
            case mimeType
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let uri = try c.decode(String.self, forKey: .uri)
            let mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType)
            if let text = try c.decodeIfPresent(String.self, forKey: .text) {
                self = .text(uri: uri, text: text, mimeType: mimeType)
            } else if let blob = try c.decodeIfPresent(String.self, forKey: .blob) {
                self = .blob(uri: uri, blob: blob, mimeType: mimeType)
            } else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "EmbeddedResource must contain 'text' or 'blob'"
                    )
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let uri, let text, let mimeType):
                try c.encode(uri, forKey: .uri)
                try c.encodeIfPresent(mimeType, forKey: .mimeType)
                try c.encode(text, forKey: .text)
            case .blob(let uri, let blob, let mimeType):
                try c.encode(uri, forKey: .uri)
                try c.encodeIfPresent(mimeType, forKey: .mimeType)
                try c.encode(blob, forKey: .blob)
            }
        }
    }

    public enum ContentBlock: Equatable, Hashable, Sendable, Codable {
        case text(text: String, annotations: ContentAnnotations? = nil)
        case image(mimeType: String, data: String? = nil, uri: String? = nil)
        case resourceLink(ResourceLink)
        case resource(EmbeddedResource)
        case audio(mimeType: String, data: String)

        private enum CodingKeys: String, CodingKey {
            case type
            case text
            case annotations
            case mimeType
            case data
            case uri
            case name
            case title
            case description
            case resource
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            switch type {
            case "text":
                let text = try c.decode(String.self, forKey: .text)
                let annotations = try c.decodeIfPresent(ContentAnnotations.self, forKey: .annotations)
                self = .text(text: text, annotations: annotations)
            case "image":
                let mimeType = try c.decode(String.self, forKey: .mimeType)
                let data = try c.decodeIfPresent(String.self, forKey: .data)
                let uri = try c.decodeIfPresent(String.self, forKey: .uri)
                self = .image(mimeType: mimeType, data: data, uri: uri)
            case "resource_link":
                let uri = try c.decode(String.self, forKey: .uri)
                let name = try c.decode(String.self, forKey: .name)
                let mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType)
                let title = try c.decodeIfPresent(String.self, forKey: .title)
                let description = try c.decodeIfPresent(String.self, forKey: .description)
                self = .resourceLink(ResourceLink(uri: uri, name: name, mimeType: mimeType, title: title, description: description))
            case "resource":
                let resource = try c.decode(EmbeddedResource.self, forKey: .resource)
                self = .resource(resource)
            case "audio":
                let mimeType = try c.decode(String.self, forKey: .mimeType)
                let data = try c.decode(String.self, forKey: .data)
                self = .audio(mimeType: mimeType, data: data)
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: c,
                    debugDescription: "Unknown ContentBlock type '\(type)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text, let annotations):
                try c.encode("text", forKey: .type)
                try c.encode(text, forKey: .text)
                try c.encodeIfPresent(annotations, forKey: .annotations)
            case .image(let mimeType, let data, let uri):
                try c.encode("image", forKey: .type)
                try c.encode(mimeType, forKey: .mimeType)
                try c.encodeIfPresent(data, forKey: .data)
                try c.encodeIfPresent(uri, forKey: .uri)
            case .resourceLink(let link):
                try c.encode("resource_link", forKey: .type)
                try c.encode(link.uri, forKey: .uri)
                try c.encode(link.name, forKey: .name)
                try c.encodeIfPresent(link.mimeType, forKey: .mimeType)
                try c.encodeIfPresent(link.title, forKey: .title)
                try c.encodeIfPresent(link.description, forKey: .description)
            case .resource(let resource):
                try c.encode("resource", forKey: .type)
                try c.encode(resource, forKey: .resource)
            case .audio(let mimeType, let data):
                try c.encode("audio", forKey: .type)
                try c.encode(mimeType, forKey: .mimeType)
                try c.encode(data, forKey: .data)
            }
        }
    }

    public struct ContentChunk: Equatable, Hashable, Sendable, Codable {
        public let content: ContentBlock

        public init(content: ContentBlock) {
            self.content = content
        }
    }

    public struct PromptRequest: Equatable, Hashable, Sendable, Codable {
        public let sessionId: String
        public let prompt: [ContentBlock]

        public init(sessionId: String, prompt: [ContentBlock]) {
            self.sessionId = sessionId
            self.prompt = prompt
        }
    }

    public enum StopReason: String, Equatable, Hashable, Sendable, Codable {
        case endTurn = "end_turn"
        case maxTokens = "max_tokens"
        case maxTurnRequests = "max_turn_requests"
        case refusal
        case cancelled
    }

    public struct UsageSummary: Equatable, Hashable, Sendable, Codable {
        public let inputTokens: Double
        public let outputTokens: Double
        public let totalTokens: Double
        public let thoughtTokens: Double?
        public let cachedReadTokens: Double?
        public let cachedWriteTokens: Double?

        public init(
            inputTokens: Double,
            outputTokens: Double,
            totalTokens: Double,
            thoughtTokens: Double? = nil,
            cachedReadTokens: Double? = nil,
            cachedWriteTokens: Double? = nil
        ) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.totalTokens = totalTokens
            self.thoughtTokens = thoughtTokens
            self.cachedReadTokens = cachedReadTokens
            self.cachedWriteTokens = cachedWriteTokens
        }
    }

    public struct PromptResponse: Equatable, Hashable, Sendable, Codable {
        public let stopReason: StopReason
        public let usage: UsageSummary?
        public let _meta: [String: JSONValue]?

        public init(stopReason: StopReason, usage: UsageSummary? = nil, _meta: [String: JSONValue]? = [:]) {
            self.stopReason = stopReason
            self.usage = usage
            self._meta = _meta
        }
    }

    public enum ToolKind: String, Equatable, Hashable, Sendable, Codable {
        case read
        case edit
        case delete
        case move
        case search
        case execute
        case think
        case fetch
        case switchMode = "switch_mode"
        case other
    }

    public enum ToolCallStatus: String, Equatable, Hashable, Sendable, Codable {
        case pending
        case inProgress = "in_progress"
        case completed
        case failed
    }

    public struct ToolCallLocation: Equatable, Hashable, Sendable, Codable {
        public let path: String
        public let line: Int?

        public init(path: String, line: Int? = nil) {
            self.path = path
            self.line = line
        }
    }

    public struct DiffContent: Equatable, Hashable, Sendable, Codable {
        public let path: String
        public let oldText: String?
        public let newText: String

        public init(path: String, oldText: String?, newText: String) {
            self.path = path
            self.oldText = oldText
            self.newText = newText
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case path
            case oldText
            case newText
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            guard type == "diff" else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Expected type 'diff'")
            }
            self.path = try c.decode(String.self, forKey: .path)
            self.oldText = try c.decodeIfPresent(String.self, forKey: .oldText)
            self.newText = try c.decode(String.self, forKey: .newText)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("diff", forKey: .type)
            try c.encode(path, forKey: .path)
            // Explicitly encode `null` when `oldText == nil` (matching ACP diff schema for newly added files).
            try c.encode(oldText, forKey: .oldText)
            try c.encode(newText, forKey: .newText)
        }
    }

    public enum ToolCallContent: Equatable, Hashable, Sendable, Codable {
        case content(ContentBlock)
        case diff(DiffContent)
        case terminal(terminalId: String)

        private enum CodingKeys: String, CodingKey {
            case type
            case content
            case terminalId
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            switch type {
            case "content":
                self = .content(try c.decode(ContentBlock.self, forKey: .content))
            case "diff":
                self = .diff(try DiffContent(from: decoder))
            case "terminal":
                self = .terminal(terminalId: try c.decode(String.self, forKey: .terminalId))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: c,
                    debugDescription: "Unknown ToolCallContent type '\(type)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .content(let block):
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode("content", forKey: .type)
                try c.encode(block, forKey: .content)
            case .diff(let diff):
                try diff.encode(to: encoder)
            case .terminal(let terminalId):
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode("terminal", forKey: .type)
                try c.encode(terminalId, forKey: .terminalId)
            }
        }
    }

    public struct ToolCall: Equatable, Hashable, Sendable, Codable {
        public var toolCallId: String
        public var name: String?
        public var title: String
        public var kind: ToolKind
        public var status: ToolCallStatus
        public var locations: [ToolCallLocation]
        public var rawInput: [String: JSONValue]?
        public var content: [ToolCallContent]?
        public var _meta: [String: JSONValue]?

        public init(
            toolCallId: String,
            name: String? = nil,
            title: String,
            kind: ToolKind,
            status: ToolCallStatus = .pending,
            locations: [ToolCallLocation] = [],
            rawInput: [String: JSONValue]? = nil,
            content: [ToolCallContent]? = nil,
            _meta: [String: JSONValue]? = nil
        ) {
            self.toolCallId = toolCallId
            self.name = name
            self.title = title
            self.kind = kind
            self.status = status
            self.locations = locations
            self.rawInput = rawInput
            self.content = content
            self._meta = _meta
        }
    }

    public struct ToolCallUpdate: Equatable, Hashable, Sendable, Codable {
        public var toolCallId: String
        public var status: ToolCallStatus?
        public var kind: ToolKind?
        public var title: String?
        public var locations: [ToolCallLocation]?
        public var rawInput: [String: JSONValue]?
        public var content: [ToolCallContent]?
        public var rawOutput: [String: JSONValue]?
        public var _meta: [String: JSONValue]?

        public init(
            toolCallId: String,
            status: ToolCallStatus? = nil,
            kind: ToolKind? = nil,
            title: String? = nil,
            locations: [ToolCallLocation]? = nil,
            rawInput: [String: JSONValue]? = nil,
            content: [ToolCallContent]? = nil,
            rawOutput: [String: JSONValue]? = nil,
            _meta: [String: JSONValue]? = nil
        ) {
            self.toolCallId = toolCallId
            self.status = status
            self.kind = kind
            self.title = title
            self.locations = locations
            self.rawInput = rawInput
            self.content = content
            self.rawOutput = rawOutput
            self._meta = _meta
        }
    }

    public struct UsageCost: Equatable, Hashable, Sendable, Codable {
        public let amount: Double
        public let currency: String

        public init(amount: Double, currency: String = "USD") {
            self.amount = amount
            self.currency = currency
        }
    }

    public enum CompactionStatus: String, Equatable, Hashable, Sendable, Codable {
        case inProgress = "in_progress"
        case completed
        case cancelled
        case failed
    }

    /// Distinguishes an omitted JSON field from an explicit `null` value (needed for `compaction_update.summary`).
    public enum NullableField<T: Equatable & Hashable & Sendable & Codable>: Equatable, Hashable, Sendable {
        case absent
        case null
        case value(T)
    }

    public struct CompactionUpdatePayload: Equatable, Hashable, Sendable, Codable {
        public let compactionId: String
        public let status: CompactionStatus
        public let summary: NullableField<[ContentBlock]>
        public let error: String?
        public var _meta: [String: JSONValue]?

        public init(
            compactionId: String,
            status: CompactionStatus,
            summary: NullableField<[ContentBlock]> = .absent,
            error: String? = nil,
            _meta: [String: JSONValue]? = nil
        ) {
            self.compactionId = compactionId
            self.status = status
            self.summary = summary
            self.error = error
            self._meta = _meta
        }

        private enum CodingKeys: String, CodingKey {
            case compactionId
            case status
            case summary
            case error
            case _meta
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.compactionId = try c.decode(String.self, forKey: .compactionId)
            self.status = try c.decode(CompactionStatus.self, forKey: .status)
            if c.contains(.summary) {
                if try c.decodeNil(forKey: .summary) {
                    self.summary = .null
                } else {
                    self.summary = .value(try c.decode([ContentBlock].self, forKey: .summary))
                }
            } else {
                self.summary = .absent
            }
            self.error = try c.decodeIfPresent(String.self, forKey: .error)
            self._meta = try c.decodeIfPresent([String: JSONValue].self, forKey: ._meta)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(compactionId, forKey: .compactionId)
            try c.encode(status, forKey: .status)
            switch summary {
            case .absent:
                break
            case .null:
                try c.encodeNil(forKey: .summary)
            case .value(let blocks):
                try c.encode(blocks, forKey: .summary)
            }
            try c.encodeIfPresent(error, forKey: .error)
            try c.encodeIfPresent(_meta, forKey: ._meta)
        }
    }

    public enum SessionUpdate: Equatable, Hashable, Sendable, Codable {
        case userMessageChunk(messageId: String?, content: ContentBlock, _meta: [String: JSONValue]? = nil)
        case agentMessageChunk(messageId: String?, content: ContentBlock, _meta: [String: JSONValue]? = nil)
        case agentThoughtChunk(messageId: String?, content: ContentBlock, _meta: [String: JSONValue]? = nil)
        case toolCall(ToolCall)
        case toolCallUpdate(ToolCallUpdate)
        case availableCommandsUpdate(availableCommands: [AvailableCommand], _meta: [String: JSONValue]? = nil)
        case configOptionUpdate(configOptions: [SessionConfigOption], _meta: [String: JSONValue]? = nil)
        case sessionInfoUpdate(title: String? = nil, updatedAt: String? = nil, _meta: [String: JSONValue]? = nil)
        case usageUpdate(used: Double, size: Int, cost: UsageCost? = nil, _meta: [String: JSONValue]? = nil)
        case compactionUpdate(CompactionUpdatePayload)
        case compactionSummaryChunk(compactionId: String, content: ContentBlock, _meta: [String: JSONValue]? = nil)

        public var sessionUpdateKind: String {
            switch self {
            case .userMessageChunk: "user_message_chunk"
            case .agentMessageChunk: "agent_message_chunk"
            case .agentThoughtChunk: "agent_thought_chunk"
            case .toolCall: "tool_call"
            case .toolCallUpdate: "tool_call_update"
            case .availableCommandsUpdate: "available_commands_update"
            case .configOptionUpdate: "config_option_update"
            case .sessionInfoUpdate: "session_info_update"
            case .usageUpdate: "usage_update"
            case .compactionUpdate: "compaction_update"
            case .compactionSummaryChunk: "compaction_summary_chunk"
            }
        }

        public var meta: [String: JSONValue]? {
            switch self {
            case .userMessageChunk(_, _, let m),
                 .agentMessageChunk(_, _, let m),
                 .agentThoughtChunk(_, _, let m),
                 .availableCommandsUpdate(_, let m),
                 .configOptionUpdate(_, let m),
                 .sessionInfoUpdate(_, _, let m),
                 .usageUpdate(_, _, _, let m),
                 .compactionSummaryChunk(_, _, let m):
                return m
            case .toolCall(let tc): return tc._meta
            case .toolCallUpdate(let tu): return tu._meta
            case .compactionUpdate(let cu): return cu._meta
            }
        }

        public func mergingMeta(_ extra: [String: JSONValue]) -> SessionUpdate {
            var merged = meta ?? [:]
            for (k, v) in extra { merged[k] = v }
            switch self {
            case .userMessageChunk(let id, let content, _):
                return .userMessageChunk(messageId: id, content: content, _meta: merged)
            case .agentMessageChunk(let id, let content, _):
                return .agentMessageChunk(messageId: id, content: content, _meta: merged)
            case .agentThoughtChunk(let id, let content, _):
                return .agentThoughtChunk(messageId: id, content: content, _meta: merged)
            case .toolCall(var tc):
                tc._meta = merged
                return .toolCall(tc)
            case .toolCallUpdate(var tu):
                tu._meta = merged
                return .toolCallUpdate(tu)
            case .availableCommandsUpdate(let cmds, _):
                return .availableCommandsUpdate(availableCommands: cmds, _meta: merged)
            case .configOptionUpdate(let opts, _):
                return .configOptionUpdate(configOptions: opts, _meta: merged)
            case .sessionInfoUpdate(let title, let updatedAt, _):
                return .sessionInfoUpdate(title: title, updatedAt: updatedAt, _meta: merged)
            case .usageUpdate(let used, let size, let cost, _):
                return .usageUpdate(used: used, size: size, cost: cost, _meta: merged)
            case .compactionUpdate(var cu):
                cu._meta = merged
                return .compactionUpdate(cu)
            case .compactionSummaryChunk(let id, let content, _):
                return .compactionSummaryChunk(compactionId: id, content: content, _meta: merged)
            }
        }

        private enum CodingKeys: String, CodingKey {
            case sessionUpdate
            case messageId
            case content
            case availableCommands
            case configOptions
            case title
            case updatedAt
            case used
            case size
            case cost
            case compactionId
            case status
            case summary
            case error
            case _meta
            case toolCallId
            case name
            case kind
            case locations
            case rawInput
            case rawOutput
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try c.decode(String.self, forKey: .sessionUpdate)
            let meta = try c.decodeIfPresent([String: JSONValue].self, forKey: ._meta)
            switch kind {
            case "user_message_chunk":
                self = .userMessageChunk(
                    messageId: try c.decodeIfPresent(String.self, forKey: .messageId),
                    content: try c.decode(ContentBlock.self, forKey: .content),
                    _meta: meta
                )
            case "agent_message_chunk":
                self = .agentMessageChunk(
                    messageId: try c.decodeIfPresent(String.self, forKey: .messageId),
                    content: try c.decode(ContentBlock.self, forKey: .content),
                    _meta: meta
                )
            case "agent_thought_chunk":
                self = .agentThoughtChunk(
                    messageId: try c.decodeIfPresent(String.self, forKey: .messageId),
                    content: try c.decode(ContentBlock.self, forKey: .content),
                    _meta: meta
                )
            case "tool_call":
                self = .toolCall(try ToolCall(from: decoder))
            case "tool_call_update":
                self = .toolCallUpdate(try ToolCallUpdate(from: decoder))
            case "available_commands_update":
                self = .availableCommandsUpdate(
                    availableCommands: try c.decode([AvailableCommand].self, forKey: .availableCommands),
                    _meta: meta
                )
            case "config_option_update":
                self = .configOptionUpdate(
                    configOptions: try c.decode([SessionConfigOption].self, forKey: .configOptions),
                    _meta: meta
                )
            case "session_info_update":
                self = .sessionInfoUpdate(
                    title: try c.decodeIfPresent(String.self, forKey: .title),
                    updatedAt: try c.decodeIfPresent(String.self, forKey: .updatedAt),
                    _meta: meta
                )
            case "usage_update":
                self = .usageUpdate(
                    used: try c.decode(Double.self, forKey: .used),
                    size: try c.decode(Int.self, forKey: .size),
                    cost: try c.decodeIfPresent(UsageCost.self, forKey: .cost),
                    _meta: meta
                )
            case "compaction_update":
                self = .compactionUpdate(try CompactionUpdatePayload(from: decoder))
            case "compaction_summary_chunk":
                self = .compactionSummaryChunk(
                    compactionId: try c.decode(String.self, forKey: .compactionId),
                    content: try c.decode(ContentBlock.self, forKey: .content),
                    _meta: meta
                )
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .sessionUpdate,
                    in: c,
                    debugDescription: "Unknown sessionUpdate kind '\(kind)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(sessionUpdateKind, forKey: .sessionUpdate)
            switch self {
            case .userMessageChunk(let messageId, let content, let meta):
                try c.encodeIfPresent(messageId, forKey: .messageId)
                try c.encode(content, forKey: .content)
                try c.encodeIfPresent(meta, forKey: ._meta)
            case .agentMessageChunk(let messageId, let content, let meta):
                try c.encodeIfPresent(messageId, forKey: .messageId)
                try c.encode(content, forKey: .content)
                try c.encodeIfPresent(meta, forKey: ._meta)
            case .agentThoughtChunk(let messageId, let content, let meta):
                try c.encodeIfPresent(messageId, forKey: .messageId)
                try c.encode(content, forKey: .content)
                try c.encodeIfPresent(meta, forKey: ._meta)
            case .toolCall(let tc):
                try c.encode(tc.toolCallId, forKey: .toolCallId)
                try c.encodeIfPresent(tc.name, forKey: .name)
                try c.encode(tc.title, forKey: .title)
                try c.encode(tc.kind, forKey: .kind)
                try c.encode(tc.status, forKey: .status)
                try c.encode(tc.locations, forKey: .locations)
                try c.encodeIfPresent(tc.rawInput, forKey: .rawInput)
                try c.encodeIfPresent(tc.content, forKey: .content)
                try c.encodeIfPresent(tc._meta, forKey: ._meta)
            case .toolCallUpdate(let tu):
                try c.encode(tu.toolCallId, forKey: .toolCallId)
                try c.encodeIfPresent(tu.status, forKey: .status)
                try c.encodeIfPresent(tu.kind, forKey: .kind)
                try c.encodeIfPresent(tu.title, forKey: .title)
                try c.encodeIfPresent(tu.locations, forKey: .locations)
                try c.encodeIfPresent(tu.rawInput, forKey: .rawInput)
                try c.encodeIfPresent(tu.content, forKey: .content)
                try c.encodeIfPresent(tu.rawOutput, forKey: .rawOutput)
                try c.encodeIfPresent(tu._meta, forKey: ._meta)
            case .availableCommandsUpdate(let commands, let meta):
                try c.encode(commands, forKey: .availableCommands)
                try c.encodeIfPresent(meta, forKey: ._meta)
            case .configOptionUpdate(let options, let meta):
                try c.encode(options, forKey: .configOptions)
                try c.encodeIfPresent(meta, forKey: ._meta)
            case .sessionInfoUpdate(let title, let updatedAt, let meta):
                try c.encodeIfPresent(title, forKey: .title)
                try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
                try c.encodeIfPresent(meta, forKey: ._meta)
            case .usageUpdate(let used, let size, let cost, let meta):
                try c.encode(used, forKey: .used)
                try c.encode(size, forKey: .size)
                try c.encodeIfPresent(cost, forKey: .cost)
                try c.encodeIfPresent(meta, forKey: ._meta)
            case .compactionUpdate(let cu):
                try c.encode(cu.compactionId, forKey: .compactionId)
                try c.encode(cu.status, forKey: .status)
                switch cu.summary {
                case .absent: break
                case .null: try c.encodeNil(forKey: .summary)
                case .value(let blocks): try c.encode(blocks, forKey: .summary)
                }
                try c.encodeIfPresent(cu.error, forKey: .error)
                try c.encodeIfPresent(cu._meta, forKey: ._meta)
            case .compactionSummaryChunk(let compactionId, let content, let meta):
                try c.encode(compactionId, forKey: .compactionId)
                try c.encode(content, forKey: .content)
                try c.encodeIfPresent(meta, forKey: ._meta)
            }
        }
    }

    public struct SessionNotification: Equatable, Hashable, Sendable, Codable {
        public let sessionId: String
        public let update: SessionUpdate

        public init(sessionId: String, update: SessionUpdate) {
            self.sessionId = sessionId
            self.update = update
        }
    }

    public struct PermissionOption: Equatable, Hashable, Sendable, Codable {
        public let optionId: String
        public let kind: String
        public let name: String

        public init(optionId: String, kind: String, name: String) {
            self.optionId = optionId
            self.kind = kind
            self.name = name
        }
    }

    public struct RequestPermissionRequest: Equatable, Hashable, Sendable, Codable {
        public let sessionId: String
        public let toolCall: ToolCall
        public let options: [PermissionOption]

        public init(sessionId: String, toolCall: ToolCall, options: [PermissionOption]) {
            self.sessionId = sessionId
            self.toolCall = toolCall
            self.options = options
        }
    }

    public enum RequestPermissionOutcome: Equatable, Hashable, Sendable, Codable {
        case selected(optionId: String)
        case cancelled

        private enum CodingKeys: String, CodingKey {
            case outcome
            case optionId
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let outcome = try c.decode(String.self, forKey: .outcome)
            switch outcome {
            case "selected":
                self = .selected(optionId: try c.decode(String.self, forKey: .optionId))
            case "cancelled":
                self = .cancelled
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .outcome,
                    in: c,
                    debugDescription: "Unknown permission outcome '\(outcome)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .selected(let optionId):
                try c.encode("selected", forKey: .outcome)
                try c.encode(optionId, forKey: .optionId)
            case .cancelled:
                try c.encode("cancelled", forKey: .outcome)
            }
        }
    }

    public struct RequestPermissionResponse: Equatable, Hashable, Sendable, Codable {
        public let outcome: RequestPermissionOutcome

        public init(outcome: RequestPermissionOutcome) {
            self.outcome = outcome
        }
    }

    public struct EnumOption: Equatable, Hashable, Sendable, Codable {
        public let const: String
        public let title: String
        public let description: String?

        public init(const: String, title: String, description: String? = nil) {
            self.const = const
            self.title = title
            self.description = description
        }
    }

    public struct ElicitationArrayItems: Equatable, Hashable, Sendable, Codable {
        public let anyOf: [EnumOption]

        public init(anyOf: [EnumOption]) {
            self.anyOf = anyOf
        }
    }

    public struct ElicitationPropertySchema: Equatable, Hashable, Sendable, Codable {
        public let type: String
        public let title: String?
        public let description: String?
        public let format: String?
        public let minLength: Int?
        public let maxLength: Int?
        public let pattern: String?
        public let oneOf: [EnumOption]?
        public let items: ElicitationArrayItems?
        public let minItems: Int?
        public let maxItems: Int?
        public let minimum: Double?
        public let maximum: Double?
        public let defaultValue: JSONValue?

        public init(
            type: String,
            title: String? = nil,
            description: String? = nil,
            format: String? = nil,
            minLength: Int? = nil,
            maxLength: Int? = nil,
            pattern: String? = nil,
            oneOf: [EnumOption]? = nil,
            items: ElicitationArrayItems? = nil,
            minItems: Int? = nil,
            maxItems: Int? = nil,
            minimum: Double? = nil,
            maximum: Double? = nil,
            defaultValue: JSONValue? = nil
        ) {
            self.type = type
            self.title = title
            self.description = description
            self.format = format
            self.minLength = minLength
            self.maxLength = maxLength
            self.pattern = pattern
            self.oneOf = oneOf
            self.items = items
            self.minItems = minItems
            self.maxItems = maxItems
            self.minimum = minimum
            self.maximum = maximum
            self.defaultValue = defaultValue
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case title
            case description
            case format
            case minLength
            case maxLength
            case pattern
            case oneOf
            case items
            case minItems
            case maxItems
            case minimum
            case maximum
            case defaultValue = "default"
        }
    }

    public struct ElicitationSchema: Equatable, Hashable, Sendable, Codable {
        public let type: String
        public let properties: [String: ElicitationPropertySchema]
        public let required: [String]

        public init(
            type: String = "object",
            properties: [String: ElicitationPropertySchema],
            required: [String]
        ) {
            self.type = type
            self.properties = properties
            self.required = required
        }
    }

    public struct CreateElicitationRequest: Equatable, Hashable, Sendable, Codable {
        public let mode: String
        public let sessionId: String
        public let toolCallId: String?
        public let message: String
        public let requestedSchema: ElicitationSchema

        public init(
            mode: String = "form",
            sessionId: String,
            toolCallId: String? = nil,
            message: String,
            requestedSchema: ElicitationSchema
        ) {
            self.mode = mode
            self.sessionId = sessionId
            self.toolCallId = toolCallId
            self.message = message
            self.requestedSchema = requestedSchema
        }
    }

    public struct CreateElicitationResponse: Equatable, Hashable, Sendable, Codable {
        public let action: String
        public let content: [String: JSONValue]?

        public init(action: String, content: [String: JSONValue]? = nil) {
            self.action = action
            self.content = content
        }
    }

    // MARK: - 1. Errors (`packages/cli/src/acp/error.ts`)

    public enum Errors {
        // parity: cli/src/acp/error.ts#SessionNotFoundError [status=implemented hash=1f69087e1aa7]
        public struct SessionNotFoundError: Swift.Error, Equatable, Hashable, Sendable, Codable {
            public static let tag = "ACPSessionNotFoundError"
            public let sessionId: String

            public init(sessionId: String) {
                self.sessionId = sessionId
            }
        }

        // parity: cli/src/acp/error.ts#SessionDirectoryMismatchError [status=implemented hash=fcaf7c5f24d1]
        public struct SessionDirectoryMismatchError: Swift.Error, Equatable, Hashable, Sendable, Codable {
            public static let tag = "ACPSessionDirectoryMismatchError"
            public let sessionId: String
            public let cwd: String

            public init(sessionId: String, cwd: String) {
                self.sessionId = sessionId
                self.cwd = cwd
            }
        }

        // parity: cli/src/acp/error.ts#InvalidConfigOptionError [status=implemented hash=67219d62d053]
        public struct InvalidConfigOptionError: Swift.Error, Equatable, Hashable, Sendable, Codable {
            public static let tag = "ACPInvalidConfigOptionError"
            public let configId: String

            public init(configId: String) {
                self.configId = configId
            }
        }

        // parity: cli/src/acp/error.ts#InvalidModelError [status=implemented hash=bcbd51464c3d]
        public struct InvalidModelError: Swift.Error, Equatable, Hashable, Sendable, Codable {
            public static let tag = "ACPInvalidModelError"
            public let modelId: String
            public let providerId: String?

            public init(modelId: String, providerId: String? = nil) {
                self.modelId = modelId
                self.providerId = providerId
            }
        }

        // parity: cli/src/acp/error.ts#InvalidEffortError [status=implemented hash=2b98a9204083]
        public struct InvalidEffortError: Swift.Error, Equatable, Hashable, Sendable, Codable {
            public static let tag = "ACPInvalidEffortError"
            public let effort: String

            public init(effort: String) {
                self.effort = effort
            }
        }

        // parity: cli/src/acp/error.ts#InvalidModeError [status=implemented hash=fe34d9e4f116]
        public struct InvalidModeError: Swift.Error, Equatable, Hashable, Sendable, Codable {
            public static let tag = "ACPInvalidModeError"
            public let mode: String

            public init(mode: String) {
                self.mode = mode
            }
        }

        // parity: cli/src/acp/error.ts#InvalidAdditionalDirectoryError [status=implemented hash=dd5b9896c72f]
        public struct InvalidAdditionalDirectoryError: Swift.Error, Equatable, Hashable, Sendable, Codable {
            public static let tag = "ACPInvalidAdditionalDirectoryError"
            public let directory: String

            public init(directory: String) {
                self.directory = directory
            }
        }

        // parity: cli/src/acp/error.ts#AuthRequiredError [status=implemented hash=c332ff99686e]
        public struct AuthRequiredError: Swift.Error, Equatable, Hashable, Sendable, Codable {
            public static let tag = "ACPAuthRequiredError"

            public init() {}
        }

        // parity: cli/src/acp/error.ts#UnknownAuthMethodError [status=implemented hash=66b40eafb996]
        public struct UnknownAuthMethodError: Swift.Error, Equatable, Hashable, Sendable, Codable {
            public static let tag = "ACPUnknownAuthMethodError"
            public let methodId: String

            public init(methodId: String) {
                self.methodId = methodId
            }
        }

        // parity: cli/src/acp/error.ts#InvalidRequestError [status=implemented hash=5c35701eaa35]
        public struct InvalidRequestError: Swift.Error, Equatable, Hashable, Sendable, Codable {
            public static let tag = "ACPInvalidRequestError"
            public let message: String
            public let field: String?

            public init(message: String, field: String? = nil) {
                self.message = message
                self.field = field
            }
        }

        // parity: cli/src/acp/error.ts#ServiceFailureError [status=implemented hash=e444da2bf7e8]
        public struct ServiceFailureError: Swift.Error, Equatable, Hashable, Sendable, Codable {
            public static let tag = "ACPServiceFailureError"
            public let safeMessage: String
            public let service: String?
            public let errorName: String?

            public init(safeMessage: String, service: String? = nil, errorName: String? = nil) {
                self.safeMessage = safeMessage
                self.service = service
                self.errorName = errorName
            }
        }

        // parity: cli/src/acp/error.ts#ServerUnavailableError [status=implemented hash=7577060ccf26]
        public struct ServerUnavailableError: Swift.Error, Equatable, Hashable, Sendable, Codable {
            public static let tag = "ACPServerUnavailableError"

            public init() {}
        }

        // parity: cli/src/acp/error.ts#CatalogNotReadyError [status=implemented hash=37eec7e47c8f]
        public struct CatalogNotReadyError: Swift.Error, Equatable, Hashable, Sendable, Codable {
            public static let tag = "ACPCatalogNotReadyError"

            public enum Reason: String, Equatable, Hashable, Sendable, Codable {
                case models
                case agents
            }

            public let reason: Reason

            public init(reason: Reason) {
                self.reason = reason
            }

            public var message: String {
                reason == .models ? "No models are available" : "No primary agents are available"
            }
        }

        // parity: cli/src/acp/error.ts#CatalogLoadError [status=implemented hash=ed245d47e44c]
        public struct CatalogLoadError: Swift.Error, Sendable {
            public static let tag = "ACPCatalogLoadError"
            public let cause: any Swift.Error & Sendable

            public init(cause: any Swift.Error & Sendable) {
                self.cause = cause
            }
        }

        // parity: cli/src/acp/error.ts#CatalogError [status=implemented hash=8382e628d218]
        public enum CatalogError: Swift.Error, Sendable {
            case notReady(CatalogNotReadyError)
            case load(CatalogLoadError)
        }

        // parity: cli/src/acp/error.ts#Error [status=implemented hash=54bf127ad9c1]
        public enum ACPError: Swift.Error, Equatable, Hashable, Sendable {
            case sessionNotFound(SessionNotFoundError)
            case sessionDirectoryMismatch(SessionDirectoryMismatchError)
            case invalidConfigOption(InvalidConfigOptionError)
            case invalidModel(InvalidModelError)
            case invalidEffort(InvalidEffortError)
            case invalidMode(InvalidModeError)
            case invalidAdditionalDirectory(InvalidAdditionalDirectoryError)
            case authRequired(AuthRequiredError)
            case unknownAuthMethod(UnknownAuthMethodError)
            case invalidRequest(InvalidRequestError)
            case serviceFailure(ServiceFailureError)
            case serverUnavailable(ServerUnavailableError)

            public var tag: String {
                switch self {
                case .sessionNotFound: SessionNotFoundError.tag
                case .sessionDirectoryMismatch: SessionDirectoryMismatchError.tag
                case .invalidConfigOption: InvalidConfigOptionError.tag
                case .invalidModel: InvalidModelError.tag
                case .invalidEffort: InvalidEffortError.tag
                case .invalidMode: InvalidModeError.tag
                case .invalidAdditionalDirectory: InvalidAdditionalDirectoryError.tag
                case .authRequired: AuthRequiredError.tag
                case .unknownAuthMethod: UnknownAuthMethodError.tag
                case .invalidRequest: InvalidRequestError.tag
                case .serviceFailure: ServiceFailureError.tag
                case .serverUnavailable: ServerUnavailableError.tag
                }
            }
        }

        // parity: cli/src/acp/error.ts#Failure [status=implemented hash=98ac912417d2]
        public enum Failure: Swift.Error, Sendable {
            case error(ACPError)
            case request(RequestError)
            case catalog(CatalogError)
        }

        // parity: cli/src/acp/error.ts#toRequestError [status=implemented hash=d512d5d415ab]
        public static func toRequestError(_ error: ACPError) -> RequestError {
            switch error {
            case .sessionNotFound(let err):
                return .invalidParams(
                    data: ["sessionId": .string(err.sessionId)],
                    detail: "session not found: \(err.sessionId)"
                )
            case .sessionDirectoryMismatch(let err):
                return .invalidParams(
                    data: ["sessionId": .string(err.sessionId), "cwd": .string(err.cwd)],
                    detail: "session \(err.sessionId) does not belong to cwd: \(err.cwd)"
                )
            case .invalidConfigOption(let err):
                return .invalidParams(
                    data: ["configId": .string(err.configId)],
                    detail: "unknown config option: \(err.configId)"
                )
            case .invalidModel(let err):
                var data: [String: JSONValue] = ["modelId": .string(err.modelId)]
                if let providerId = err.providerId {
                    data["providerId"] = .string(providerId)
                }
                return .invalidParams(data: data, detail: "model not found: \(err.modelId)")
            case .invalidEffort(let err):
                return .invalidParams(
                    data: ["effort": .string(err.effort)],
                    detail: "effort not found: \(err.effort)"
                )
            case .invalidMode(let err):
                return .invalidParams(
                    data: ["mode": .string(err.mode)],
                    detail: "mode not found: \(err.mode)"
                )
            case .invalidAdditionalDirectory(let err):
                return .invalidParams(
                    data: ["additionalDirectory": .string(err.directory)],
                    detail: "additional directory must be an absolute path without glob characters: \(err.directory)"
                )
            case .authRequired:
                return .authRequired(data: [:], detail: "provider authentication required")
            case .unknownAuthMethod(let err):
                return .invalidParams(
                    data: ["methodId": .string(err.methodId)],
                    detail: "unknown auth method: \(err.methodId)"
                )
            case .invalidRequest(let err):
                let data: [String: JSONValue] = err.field.map { ["field": .string($0)] } ?? [:]
                return .invalidParams(data: data, detail: err.message)
            case .serviceFailure(let err):
                var data: [String: JSONValue] = [:]
                if let service = err.service, !service.isEmpty {
                    data["service"] = .string(service)
                }
                if let errorName = err.errorName, !errorName.isEmpty {
                    data["errorName"] = .string(errorName)
                }
                return .internalError(data: data, detail: err.safeMessage)
            case .serverUnavailable:
                return .internalError(
                    data: ["errorName": .string("ServerUnavailable")],
                    detail: "OpenCode server is unavailable"
                )
            }
        }

        // parity: cli/src/acp/error.ts#fromUnknown [status=implemented hash=8eaf450208eb]
        public static func fromUnknown(_ error: Any) -> ServiceFailureError {
            // Never include raw error descriptions or stack traces; report only the type name.
            let errorName: String? = (error is any Swift.Error) ? String(describing: type(of: error)) : nil
            return ServiceFailureError(safeMessage: "Internal service failure", errorName: errorName)
        }
    }

    // MARK: - 2. Capabilities (`packages/cli/src/acp/capabilities.ts`)

    public enum Capabilities {
        // parity: cli/src/acp/capabilities.ts#ChildSessionUpdates [status=implemented hash=990400454520]
        public static let childSessionUpdatesKey = "opencode/child-session-updates"

        // parity: cli/src/acp/capabilities.ts#Capabilities [status=implemented hash=882a90d73540]
        public struct Parsed: Equatable, Hashable, Sendable, Codable {
            public let childSessionUpdates: Bool
            public let formElicitation: Bool
            public let compaction: Bool

            public init(
                childSessionUpdates: Bool = false,
                formElicitation: Bool = false,
                compaction: Bool = false
            ) {
                self.childSessionUpdates = childSessionUpdates
                self.formElicitation = formElicitation
                self.compaction = compaction
            }
        }

        // parity: cli/src/acp/capabilities.ts#parse [status=implemented hash=f9b234621a1f]
        public static func parse(_ client: ClientCapabilities?) -> Parsed {
            let childSessionUpdates = client?._meta?[childSessionUpdatesKey] == .bool(true)
            let formElicitation: Bool = {
                guard let form = client?.elicitation?.form else { return false }
                return form != .null
            }()
            let compaction: Bool = {
                guard let comp = client?.session?.compaction else { return false }
                return comp != .null
            }()
            return Parsed(
                childSessionUpdates: childSessionUpdates,
                formElicitation: formElicitation,
                compaction: compaction
            )
        }
    }

    // MARK: - 3. Child Session Projection (`packages/cli/src/acp/child.ts`)

    public enum Child {
        // parity: cli/src/acp/child.ts#UpdateMethod [status=implemented hash=6543877c2d7c]
        public static let updateMethod = "opencode/session/child_update"

        public enum Status: String, Equatable, Hashable, Sendable, Codable {
            case created
            case running
            case completed
            case failed
            case interrupted
        }

        public struct StatusError: Equatable, Hashable, Sendable, Codable {
            public let type: String
            public let message: String

            public init(type: String, message: String) {
                self.type = type
                self.message = message
            }
        }

        // parity: cli/src/acp/child.ts#Session [status=implemented hash=d96dd1127417]
        public struct Session: Equatable, Hashable, Sendable, Codable {
            public let id: String
            public let parentID: String
            public let depth: Int
            public let title: String?

            public init(id: String, parentID: String, depth: Int, title: String? = nil) {
                self.id = id
                self.parentID = parentID
                self.depth = depth
                self.title = title
            }
        }

        // parity: cli/src/acp/child.ts#Event [status=implemented hash=80becddcf37b]
        public enum Event: Equatable, Hashable, Sendable, Codable {
            case update(SessionUpdate)
            case status(Status, error: StatusError? = nil)

            private enum CodingKeys: String, CodingKey {
                case type
                case update
                case status
                case error
            }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let type = try c.decode(String.self, forKey: .type)
                switch type {
                case "update":
                    self = .update(try c.decode(SessionUpdate.self, forKey: .update))
                case "status":
                    let status = try c.decode(Status.self, forKey: .status)
                    let error = try c.decodeIfPresent(StatusError.self, forKey: .error)
                    self = .status(status, error: error)
                default:
                    throw DecodingError.dataCorruptedError(
                        forKey: .type,
                        in: c,
                        debugDescription: "Unknown Child.Event type '\(type)'"
                    )
                }
            }

            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .update(let update):
                    try c.encode("update", forKey: .type)
                    try c.encode(update, forKey: .update)
                case .status(let status, let error):
                    try c.encode("status", forKey: .type)
                    try c.encode(status, forKey: .status)
                    try c.encodeIfPresent(error, forKey: .error)
                }
            }
        }

        // parity: cli/src/acp/child.ts#Update [status=implemented hash=30af5a2f78fc]
        public struct Update: Equatable, Hashable, Sendable, Codable {
            public let rootSessionId: String
            public let childSessionId: String
            public let parentSessionId: String
            public let depth: Int
            public let title: String?
            public let event: Event

            public init(
                rootSessionId: String,
                childSessionId: String,
                parentSessionId: String,
                depth: Int,
                title: String? = nil,
                event: Event
            ) {
                self.rootSessionId = rootSessionId
                self.childSessionId = childSessionId
                self.parentSessionId = parentSessionId
                self.depth = depth
                self.title = title
                self.event = event
            }

            private enum CodingKeys: String, CodingKey {
                case rootSessionId
                case childSessionId
                case parentSessionId
                case depth
                case title
                case type
                case update
                case status
                case error
            }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                self.rootSessionId = try c.decode(String.self, forKey: .rootSessionId)
                self.childSessionId = try c.decode(String.self, forKey: .childSessionId)
                self.parentSessionId = try c.decode(String.self, forKey: .parentSessionId)
                self.depth = try c.decode(Int.self, forKey: .depth)
                self.title = try c.decodeIfPresent(String.self, forKey: .title)
                self.event = try Event(from: decoder)
            }

            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(rootSessionId, forKey: .rootSessionId)
                try c.encode(childSessionId, forKey: .childSessionId)
                try c.encode(parentSessionId, forKey: .parentSessionId)
                try c.encode(depth, forKey: .depth)
                if let title, !title.isEmpty {
                    try c.encode(title, forKey: .title)
                }
                switch event {
                case .update(let update):
                    try c.encode("update", forKey: .type)
                    try c.encode(update, forKey: .update)
                case .status(let status, let error):
                    try c.encode("status", forKey: .type)
                    try c.encode(status, forKey: .status)
                    try c.encodeIfPresent(error, forKey: .error)
                }
            }
        }

        // parity: cli/src/acp/child.ts#update [status=implemented hash=b2aa918889af]
        public static func update(rootSessionID: String, child: Session, event: Event) -> Update {
            Update(
                rootSessionId: rootSessionID,
                childSessionId: child.id,
                parentSessionId: child.parentID,
                depth: child.depth,
                title: (child.title?.isEmpty == false) ? child.title : nil,
                event: event
            )
        }

        // parity: cli/src/acp/child.ts#project [status=implemented hash=7e5a1ebb9d16]
        public static func project(_ sessionUpdate: SessionUpdate, child: Session) -> SessionUpdate {
            var projected = sessionUpdate.mergingMeta(meta(child))
            switch projected {
            case .toolCall(var tc):
                tc.toolCallId = toolCallID(child, id: tc.toolCallId)
                if !tc.title.isEmpty {
                    tc.title = prefixTitle(child, value: tc.title)
                }
                projected = .toolCall(tc)
            case .toolCallUpdate(var tu):
                tu.toolCallId = toolCallID(child, id: tu.toolCallId)
                if let title = tu.title, !title.isEmpty {
                    tu.title = prefixTitle(child, value: title)
                }
                projected = .toolCallUpdate(tu)
            default:
                break
            }
            return projected
        }

        // parity: cli/src/acp/child.ts#meta [status=implemented hash=24250c72f789]
        public static func meta(_ child: Session) -> [String: JSONValue] {
            var payload: [String: JSONValue] = [
                "id": .string(child.id),
                "parentID": .string(child.parentID),
                "depth": .int(Int64(child.depth)),
            ]
            if let title = child.title, !title.isEmpty {
                payload["title"] = .string(title)
            }
            return ["opencode/child-session": .object(payload)]
        }

        // parity: cli/src/acp/child.ts#toolCallID [status=implemented hash=b30558e04117]
        public static func toolCallID(_ child: Session?, id: String) -> String {
            guard let child else { return id }
            return "\(child.id):\(id)"
        }

        // parity: cli/src/acp/child.ts#prefixTitle [status=implemented hash=8de1326b09dd]
        public static func prefixTitle(_ child: Session?, value: String) -> String {
            guard let title = child?.title, !title.isEmpty else { return value }
            return "\(title): \(value)"
        }
    }

    // MARK: - 4. Compaction Updates (`packages/cli/src/acp/compaction.ts`)

    public enum Compaction {
        private static let markerMeta = "opencode/compaction"
        private static let cancelledErrorTypes: Set<String> = ["aborted", "compaction.interrupted"]

        public struct Started: Equatable, Hashable, Sendable {
            public let messageId: String
            public let reason: SessionMessageSchema.CompactionReason

            public init(messageId: String, reason: SessionMessageSchema.CompactionReason) {
                self.messageId = messageId
                self.reason = reason
            }
        }

        public enum LifecycleEvent: Equatable, Hashable, Sendable {
            case started(
                eventID: String,
                sessionID: String,
                reason: SessionMessageSchema.CompactionReason,
                inputID: String?
            )
            case ended(
                sessionID: String,
                reason: SessionMessageSchema.CompactionReason,
                text: String
            )
            case failed(
                eventID: String,
                sessionID: String,
                reason: SessionMessageSchema.CompactionReason,
                inputID: String?,
                error: SessionErrorSchema.Error
            )
        }

        private enum State {
            case started(Started)
            case completed(messageId: String, reason: SessionMessageSchema.CompactionReason, summary: String)
            case failed(messageId: String, reason: SessionMessageSchema.CompactionReason, error: SessionErrorSchema.Error)
        }

        // parity: cli/src/acp/compaction.ts#Tracked [status=implemented hash=bf5a1f97b094]
        public typealias Tracked = [String: Started]

        // parity: cli/src/acp/compaction.ts#usesStandardUpdates [status=implemented hash=5877395bfad9]
        public static func usesStandardUpdates(compaction: Bool, childUpdates: Bool, child: Bool) -> Bool {
            compaction && (!child || childUpdates)
        }

        // parity: cli/src/acp/compaction.ts#apply [status=implemented hash=a33e25d807fc]
        public static func apply(
            event: LifecycleEvent,
            tracked: Tracked,
            standardUpdates: Bool
        ) -> (tracked: Tracked, updates: [SessionUpdate]) {
            switch event {
            case .started(let eventID, let sessionID, let reason, let inputID):
                let started = open(eventID: eventID, reason: reason, inputID: inputID)
                var next = tracked
                next[sessionID] = started
                return (next, [makeUpdate(.started(started), standardUpdates: standardUpdates)])

            case .ended(let sessionID, let reason, let text):
                let current = tracked[sessionID]
                var remaining = tracked
                remaining.removeValue(forKey: sessionID)
                guard let current else { return (remaining, []) }
                return (
                    remaining,
                    [makeUpdate(.completed(messageId: current.messageId, reason: reason, summary: text), standardUpdates: standardUpdates)]
                )

            case .failed(let eventID, let sessionID, let reason, let inputID, let error):
                let current = tracked[sessionID]
                var remaining = tracked
                remaining.removeValue(forKey: sessionID)
                // Auto compaction can fail without a started event; open it first for standard clients.
                let started = current ?? open(eventID: eventID, reason: reason, inputID: inputID)
                var updates: [SessionUpdate] = []
                if current == nil && standardUpdates {
                    updates.append(makeUpdate(.started(started), standardUpdates: standardUpdates))
                }
                updates.append(
                    makeUpdate(
                        .failed(messageId: started.messageId, reason: reason, error: error),
                        standardUpdates: standardUpdates
                    )
                )
                return (remaining, updates)
            }
        }

        // parity: cli/src/acp/compaction.ts#chunk [status=implemented hash=2748380d617e]
        public static func chunk(started: Started?, text: String, standardUpdates: Bool) -> SessionUpdate? {
            guard let started, standardUpdates else { return nil }
            return .compactionSummaryChunk(
                compactionId: started.messageId,
                content: .text(text: text)
            )
        }

        // parity: cli/src/acp/compaction.ts#abandon [status=implemented hash=c58d1473bf6f]
        public static func abandon(started: Started, standardUpdates: Bool) -> SessionUpdate {
            makeUpdate(
                .failed(
                    messageId: started.messageId,
                    reason: started.reason,
                    error: SessionErrorSchema.Error(type: "aborted", message: "Compaction cancelled")
                ),
                standardUpdates: standardUpdates
            )
        }

        // parity: cli/src/acp/compaction.ts#replay [status=implemented hash=f12144e4b5fd]
        public static func replay(
            message: SessionMessageSchema.Compaction,
            standardUpdates: Bool
        ) -> SessionUpdate? {
            switch message {
            case .running:
                return nil
            case .completed(let done):
                return makeUpdate(
                    .completed(messageId: done.id.rawValue, reason: done.reason, summary: done.summary),
                    standardUpdates: standardUpdates
                )
            case .failed(let failed):
                return makeUpdate(
                    .failed(messageId: failed.id.rawValue, reason: failed.reason, error: failed.error),
                    standardUpdates: standardUpdates
                )
            }
        }

        private static func open(
            eventID: String,
            reason: SessionMessageSchema.CompactionReason,
            inputID: String?
        ) -> Started {
            let messageId: String
            if let inputID, !inputID.isEmpty {
                messageId = inputID
            } else if let converted = try? SessionMessageSchema.ID.fromEvent(eventID) {
                messageId = converted.rawValue
            } else if eventID.hasPrefix("evt_") {
                messageId = "msg_" + eventID.dropFirst(4)
            } else {
                messageId = eventID
            }
            return Started(messageId: messageId, reason: reason)
        }

        private static func makeUpdate(_ compaction: State, standardUpdates: Bool) -> SessionUpdate {
            if !standardUpdates {
                var marker: [String: JSONValue] = [:]
                switch compaction {
                case .started(let s):
                    marker["status"] = .string("started")
                    marker["messageId"] = .string(s.messageId)
                    marker["reason"] = .string(s.reason.rawValue)
                case .completed(let messageId, let reason, _):
                    marker["status"] = .string("completed")
                    marker["messageId"] = .string(messageId)
                    marker["reason"] = .string(reason.rawValue)
                case .failed(let messageId, let reason, let error):
                    marker["status"] = .string("failed")
                    marker["messageId"] = .string(messageId)
                    marker["reason"] = .string(reason.rawValue)
                    marker["error"] = encodeErrorJSON(error)
                }
                return .sessionInfoUpdate(_meta: [markerMeta: .object(marker)])
            }
            switch compaction {
            case .started(let s):
                return .compactionUpdate(
                    CompactionUpdatePayload(compactionId: s.messageId, status: .inProgress)
                )
            case .completed(let messageId, _, let summary):
                let blocks: NullableField<[ContentBlock]> = summary.isEmpty ? .null : .value([.text(text: summary)])
                return .compactionUpdate(
                    CompactionUpdatePayload(compactionId: messageId, status: .completed, summary: blocks)
                )
            case .failed(let messageId, _, let error):
                if cancelledErrorTypes.contains(error.type) {
                    return .compactionUpdate(
                        CompactionUpdatePayload(compactionId: messageId, status: .cancelled, summary: .null)
                    )
                }
                return .compactionUpdate(
                    CompactionUpdatePayload(
                        compactionId: messageId,
                        status: .failed,
                        summary: .null,
                        error: displayError(error)
                    )
                )
            }
        }

        private static func displayError(_ error: SessionErrorSchema.Error) -> String {
            if error.message.isEmpty || (error.type == "compaction.failed" && error.message.contains("\n")) {
                return "Compaction failed"
            }
            return error.message
        }

        internal static func encodeErrorJSON(_ error: SessionErrorSchema.Error) -> JSONValue {
            var obj: [String: JSONValue] = [
                "type": .string(error.type),
                "message": .string(error.message),
            ]
            if let status = error.status {
                obj["status"] = .int(Int64(status))
            }
            if let response = error.response {
                obj["response"] = .object(["body": .string(response.body)])
            }
            if let retryAfterMs = error.retryAfterMs {
                obj["retryAfterMs"] = .int(retryAfterMs)
            }
            return .object(obj)
        }
    }

    // MARK: - 5. Catalog Types (`packages/cli/src/acp/catalog.ts`)

    public enum CatalogStore {
        public struct BuiltinCommand: Equatable, Hashable, Sendable {
            public enum StartKind: String, Equatable, Hashable, Sendable {
                case compaction
            }

            public let description: String
            public let start: StartKind

            public init(description: String, start: StartKind) {
                self.description = description
                self.start = start
            }
        }

        public struct Mode: Equatable, Hashable, Sendable, Codable {
            public let id: AgentSchema.ID
            public let name: String
            public let description: String?

            public init(id: AgentSchema.ID, name: String, description: String? = nil) {
                self.id = id
                self.name = name
                self.description = description
            }
        }

        // parity: cli/src/acp/catalog.ts#builtinCommands [status=implemented hash=fadf857768ac]
        public static let builtinCommands: [String: BuiltinCommand] = [
            "compact": BuiltinCommand(description: "Compact the session", start: .compaction),
        ]

        // parity: cli/src/acp/catalog.ts#Catalog [status=implemented hash=2b4c598ff364]
        public struct Catalog: Equatable, Hashable, Sendable {
            public let models: [ModelSchema.Info]
            public let defaultModel: ModelSchema.Ref
            public let modes: [Mode]
            public let defaultModeID: AgentSchema.ID
            public let commands: [CommandSchema.Info]

            public init(
                models: [ModelSchema.Info],
                defaultModel: ModelSchema.Ref,
                modes: [Mode],
                defaultModeID: AgentSchema.ID,
                commands: [CommandSchema.Info]
            ) {
                self.models = models
                self.defaultModel = defaultModel
                self.modes = modes
                self.defaultModeID = defaultModeID
                self.commands = commands
            }
        }

        // parity: cli/src/acp/catalog.ts#findModel [status=implemented hash=4347cd6c7d4e]
        public static func findModel(_ models: [ModelSchema.Info], ref: ModelSchema.Ref) -> ModelSchema.Info? {
            models.first { $0.providerID == ref.providerID && $0.id == ref.id }
        }

        // parity: cli/src/acp/catalog.ts#Interface [status=implemented hash=162d1ab22459]
        public protocol Interface: Sendable {
            func get(cwd: String) async throws -> Catalog
            func reload(cwd: String) async throws
            func changes(cwd: String) -> AsyncThrowingStream<Catalog, any Swift.Error>
        }
    }

    // MARK: - 6. Config Options (`packages/cli/src/acp/config-option.ts`)

    public enum ConfigOption {
        private static let defaultVariantValue = "default"

        // parity: cli/src/acp/config-option.ts#Selection [status=implemented hash=e68b9de2247a]
        public struct Selection: Equatable, Hashable, Sendable, Codable {
            public var model: ModelSchema.Ref?
            public var modeID: AgentSchema.ID?

            public init(model: ModelSchema.Ref? = nil, modeID: AgentSchema.ID? = nil) {
                self.model = model
                self.modeID = modeID
            }

            public func applying(_ change: Change) -> Selection {
                var next = self
                switch change {
                case .model(let ref): next.model = ref
                case .modeID(let id): next.modeID = id
                }
                return next
            }

            public func merging(_ patch: Selection) -> Selection {
                Selection(
                    model: patch.model ?? model,
                    modeID: patch.modeID ?? modeID
                )
            }
        }

        // parity: cli/src/acp/config-option.ts#Change [status=implemented hash=7a76c88ab675]
        public enum Change: Equatable, Hashable, Sendable, Codable {
            case model(ModelSchema.Ref)
            case modeID(AgentSchema.ID)
        }

        // parity: cli/src/acp/config-option.ts#currentModel [status=implemented hash=3bcb37ccaea1]
        public static func currentModel(_ catalog: CatalogStore.Catalog, selection: Selection) -> ModelSchema.Ref {
            selection.model ?? catalog.defaultModel
        }

        // parity: cli/src/acp/config-option.ts#configOptions [status=implemented hash=cdb362cc5087]
        public static func configOptions(
            _ catalog: CatalogStore.Catalog,
            selection: Selection
        ) -> [SessionConfigOption] {
            let model = currentModel(catalog, selection: selection)
            let variants = CatalogStore.findModel(catalog.models, ref: model)?.variants.map(\.id.rawValue) ?? []
            let sortedModels = catalog.models.sorted { a, b in
                if a.providerID.rawValue != b.providerID.rawValue {
                    return a.providerID.rawValue < b.providerID.rawValue
                }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }

            var result: [SessionConfigOption] = [
                SessionConfigOption(
                    id: "model",
                    name: "Model",
                    category: "model",
                    type: "select",
                    currentValue: advertisedModel(providerID: model.providerID.rawValue, id: model.id.rawValue),
                    options: sortedModels.map { item in
                        SessionConfigSelectOption(
                            value: advertisedModel(providerID: item.providerID.rawValue, id: item.id.rawValue),
                            name: "\(item.providerID.rawValue)/\(item.name)"
                        )
                    }
                ),
            ]

            if !variants.isEmpty {
                var seen: Set<String> = []
                var uniqueVariants: [String] = []
                for variant in variants + [defaultVariantValue] {
                    if seen.insert(variant).inserted {
                        uniqueVariants.append(variant)
                    }
                }
                result.append(
                    SessionConfigOption(
                        id: "effort",
                        name: "Effort",
                        description: "Available effort levels for this model",
                        category: "thought_level",
                        type: "select",
                        currentValue: selectVariant(model.variant?.rawValue, variants: variants),
                        options: uniqueVariants.map { variant in
                            let display = variant
                                .split(omittingEmptySubsequences: false) { $0 == "_" || $0 == "-" }
                                .map { part -> String in
                                    guard let first = part.first else { return "" }
                                    return first.uppercased() + part.dropFirst()
                                }
                                .joined(separator: " ")
                            return SessionConfigSelectOption(value: variant, name: display)
                        }
                    )
                )
            }

            result.append(
                SessionConfigOption(
                    id: "mode",
                    name: "Session Mode",
                    category: "mode",
                    type: "select",
                    currentValue: (selection.modeID ?? catalog.defaultModeID).rawValue,
                    options: catalog.modes.map { mode in
                        SessionConfigSelectOption(
                            value: mode.id.rawValue,
                            name: mode.name,
                            description: (mode.description?.isEmpty == false) ? mode.description : nil
                        )
                    }
                )
            )

            return result
        }

        // parity: cli/src/acp/config-option.ts#availableCommands [status=implemented hash=c755d948a826]
        public static func availableCommands(_ catalog: CatalogStore.Catalog) -> [AvailableCommand] {
            var list = catalog.commands.map { command in
                AvailableCommand(name: command.name, description: command.description ?? "")
            }
            for (name, command) in CatalogStore.builtinCommands.sorted(by: { $0.key < $1.key }) {
                list.append(AvailableCommand(name: name, description: command.description))
            }
            return list
        }

        // parity: cli/src/acp/config-option.ts#resolveChange [status=implemented hash=192fbda36bcb]
        public static func resolveChange(
            _ catalog: CatalogStore.Catalog,
            selection: Selection,
            configId: String,
            value: String
        ) throws(Errors.ACPError) -> Change {
            let current = currentModel(catalog, selection: selection)
            switch configId {
            case "model":
                return .model(try requireModel(catalog: catalog, value: value, current: current))
            case "effort":
                guard let model = CatalogStore.findModel(catalog.models, ref: current),
                      value == defaultVariantValue || model.variants.contains(where: { $0.id.rawValue == value })
                else {
                    throw .invalidEffort(Errors.InvalidEffortError(effort: value))
                }
                return .model(
                    ModelSchema.Ref(
                        id: current.id,
                        providerID: current.providerID,
                        variant: ModelSchema.VariantID(rawValue: value)
                    )
                )
            case "mode":
                guard let mode = catalog.modes.first(where: { $0.id.rawValue == value }) else {
                    throw .invalidMode(Errors.InvalidModeError(mode: value))
                }
                return .modeID(mode.id)
            default:
                throw .invalidConfigOption(Errors.InvalidConfigOptionError(configId: configId))
            }
        }

        // parity: cli/src/acp/config-option.ts#parseModelSelection [status=implemented hash=852469ce2787]
        public static func parseModelSelection(_ value: String, models: [ModelSchema.Info]) -> ModelSchema.Ref {
            if let exact = models.first(where: {
                advertisedModel(providerID: $0.providerID.rawValue, id: $0.id.rawValue) == value
            }) {
                return ModelSchema.Ref(id: exact.id, providerID: exact.providerID)
            }
            if let lastSlash = value.lastIndex(of: "/") {
                let prefix = String(value[..<lastSlash])
                let variantRaw = String(value[value.index(after: lastSlash)...])
                let variant = ModelSchema.VariantID(rawValue: variantRaw)
                if let base = models.first(where: { model in
                    advertisedModel(providerID: model.providerID.rawValue, id: model.id.rawValue) == prefix
                        && model.variants.contains(where: { $0.id == variant })
                }) {
                    return ModelSchema.Ref(id: base.id, providerID: base.providerID, variant: variant)
                }
            }
            guard let firstSlash = value.firstIndex(of: "/") else {
                return ModelSchema.Ref(id: ModelSchema.ID(rawValue: ""), providerID: ProviderSchema.ID(rawValue: value))
            }
            return ModelSchema.Ref(
                id: ModelSchema.ID(rawValue: String(value[value.index(after: firstSlash)...])),
                providerID: ProviderSchema.ID(rawValue: String(value[..<firstSlash]))
            )
        }

        private static func requireModel(
            catalog: CatalogStore.Catalog,
            value: String,
            current: ModelSchema.Ref
        ) throws(Errors.ACPError) -> ModelSchema.Ref {
            let selected = parseModelSelection(value, models: catalog.models)
            guard let model = CatalogStore.findModel(catalog.models, ref: selected) else {
                throw .invalidModel(
                    Errors.InvalidModelError(modelId: value, providerId: selected.providerID.rawValue)
                )
            }
            let selectedVariant = selected.variant.flatMap { wanted in
                model.variants.first(where: { $0.id == wanted })
            }
            if let requestedVariant = selected.variant, selectedVariant == nil {
                throw .invalidEffort(Errors.InvalidEffortError(effort: requestedVariant.rawValue))
            }
            let variant: ModelSchema.VariantID?
            if let selectedVariant {
                variant = selectedVariant.id
            } else if current.providerID == model.providerID
                && current.id == model.id
                && (current.variant?.rawValue == defaultVariantValue
                    || model.variants.contains(where: { $0.id == current.variant }))
            {
                variant = current.variant
            } else {
                variant = nil
            }
            return ModelSchema.Ref(id: model.id, providerID: model.providerID, variant: variant)
        }

        private static func advertisedModel(providerID: String, id: String) -> String {
            "\(providerID)/\(id)"
        }

        private static func selectVariant(_ variant: String?, variants: [String]) -> String {
            guard let variant, !variant.isEmpty, variant != defaultVariantValue else {
                return defaultVariantValue
            }
            if variants.contains(variant) { return variant }
            if variants.contains(defaultVariantValue) { return defaultVariantValue }
            return variants.first ?? defaultVariantValue
        }
    }

    // MARK: - 7. Content Translation (`packages/cli/src/acp/content.ts`)

    public enum Content {
        // parity: cli/src/acp/content.ts#PromptPart [status=implemented hash=e67aab78704e]
        public enum PromptPart: Equatable, Hashable, Sendable, Codable {
            case text(text: String, synthetic: Bool? = nil, ignored: Bool? = nil)
            case file(url: String, filename: String? = nil, mime: String)
        }

        public enum ReplayPart: Equatable, Hashable, Sendable {
            case text(text: String, synthetic: Bool? = nil, ignored: Bool? = nil)
            case reasoning(text: String)
            case file(url: String, filename: String? = nil, mime: String)
        }

        // parity: cli/src/acp/content.ts#promptContentToParts [status=implemented hash=f37d79c6d88f]
        public static func promptContentToParts(_ content: [ContentBlock]) -> [PromptPart] {
            content.flatMap(contentBlockToParts)
        }

        // parity: cli/src/acp/content.ts#partsToContentChunks [status=implemented hash=372f05c1370b]
        public static func partsToContentChunks(_ parts: [ReplayPart]) -> [ContentChunk] {
            parts.flatMap { part -> [ContentChunk] in
                switch part {
                case .text(let text, let synthetic, let ignored):
                    guard !text.isEmpty else { return [] }
                    let annotations: ContentAnnotations?
                    if synthetic == true {
                        annotations = ContentAnnotations(audience: ["assistant"])
                    } else if synthetic != true && ignored == true {
                        annotations = ContentAnnotations(audience: ["user"])
                    } else {
                        annotations = nil
                    }
                    return [ContentChunk(content: .text(text: text, annotations: annotations))]

                case .reasoning(let text):
                    guard !text.isEmpty else { return [] }
                    return [ContentChunk(content: .text(text: text))]

                case .file(let url, let filename, let mime):
                    if url.hasPrefix("file://") {
                        return [
                            ContentChunk(
                                content: .resourceLink(
                                    ResourceLink(uri: url, name: filename ?? "file", mimeType: mime)
                                )
                            ),
                        ]
                    }
                    guard let parsed = parseBase64DataURI(url) else { return [] }
                    if parsed.mime.hasPrefix("image/") {
                        return [
                            ContentChunk(
                                content: .image(
                                    mimeType: parsed.mime,
                                    data: parsed.data,
                                    uri: pathToFileURL(filename ?? "image")
                                )
                            ),
                        ]
                    }
                    let fileURI = pathToFileURL(filename ?? "file")
                    if parsed.mime.hasPrefix("text/") || parsed.mime == "application/json" {
                        let decodedText = (try? base64ToBytes(parsed.data)).map { String(decoding: $0, as: UTF8.self) } ?? ""
                        return [
                            ContentChunk(
                                content: .resource(.text(uri: fileURI, text: decodedText, mimeType: parsed.mime))
                            ),
                        ]
                    }
                    return [
                        ContentChunk(
                            content: .resource(.blob(uri: fileURI, blob: parsed.data, mimeType: parsed.mime))
                        ),
                    ]
                }
            }
        }

        // parity: cli/src/acp/content.ts#linkReference [status=implemented hash=d1ad3cec9809]
        public static func linkReference(name: String?, uri: String) -> PromptPart {
            if let name, !name.isEmpty {
                return .text(text: "[\(name)](\(uri))")
            }
            return .text(text: uri)
        }

        private static func contentBlockToParts(_ block: ContentBlock) -> [PromptPart] {
            switch block {
            case .text(let text, let annotations):
                let audience = annotations?.audience
                if audience?.count == 1 && audience?.first == "assistant" {
                    return [.text(text: text, synthetic: true)]
                }
                if audience?.count == 1 && audience?.first == "user" {
                    return [.text(text: text, ignored: true)]
                }
                return [.text(text: text)]

            case .image(let mimeType, let data, let uri):
                let url: String?
                if let data, !data.isEmpty {
                    url = "data:\(mimeType);base64,\(data)"
                } else {
                    url = (uri?.isEmpty == false) ? uri : nil
                }
                guard let url else { return [] }
                let filename = filenameFromURI(uri) ?? "image"
                if url.hasPrefix("data:") {
                    return [.file(url: url, filename: filename, mime: mimeType)]
                }
                return [resourceLinkToPart(ResourceLink(uri: url, name: filename, mimeType: mimeType))]

            case .resourceLink(let link):
                return [resourceLinkToPart(link)]

            case .resource(let resource):
                switch resource {
                case .text(let uri, let text, _):
                    guard let parsed = parseURI(uri), parsed.scheme == "file" else {
                        return [.text(text: "[\(uri)]\n\(text)")]
                    }
                    guard let decoded = fileURLToPath(uri) else {
                        return [.text(text: "[\(uri)]\n\(text)")]
                    }
                    let line = parseLineFragment(parsed.fragment)
                    let filepath = decoded.replacing("\\", with: "/")
                    let suffix = line.map { ":\($0)" } ?? ""
                    return [.text(text: "[\(filepath)\(suffix)]\n\(text)")]

                case .blob(let uri, let blob, let mimeType):
                    guard let mimeType, !mimeType.isEmpty else { return [] }
                    let url = uri.hasPrefix("data:") ? uri : "data:\(mimeType);base64,\(blob)"
                    return [.file(url: url, filename: filenameFromURI(uri) ?? "file", mime: mimeType)]
                }

            case .audio:
                return []
            }
        }

        private static func resourceLinkToPart(_ link: ResourceLink) -> PromptPart {
            if link.uri.hasPrefix("file://") {
                let name = !link.name.isEmpty ? link.name : (filenameFromURI(link.uri) ?? "file")
                return .file(url: link.uri, filename: name, mime: link.mimeType ?? "text/plain")
            }
            if link.uri.hasPrefix("zed://"), let parsed = parseURI(link.uri),
               let pathname = parsed.queryParam("path"), !pathname.isEmpty
            {
                let name = !link.name.isEmpty ? link.name : (basename(pathname) ?? "file")
                return .file(url: pathToFileURL(pathname), filename: name, mime: link.mimeType ?? "text/plain")
            }
            return linkReference(name: link.name.isEmpty ? nil : link.name, uri: link.uri)
        }

        private static func filenameFromURI(_ uri: String?) -> String? {
            guard let uri, !uri.isEmpty, !uri.hasPrefix("data:") else { return nil }
            if let parsed = parseURI(uri) {
                let target: String
                if parsed.scheme == "zed", let qPath = parsed.queryParam("path"), !qPath.isEmpty {
                    target = qPath
                } else {
                    target = parsed.path
                }
                return basename(target)
            }
            return basename(uri)
        }

        internal struct ParsedURI {
            let scheme: String
            let host: String
            let path: String
            let query: String?
            let fragment: String?

            func queryParam(_ key: String) -> String? {
                guard let query, !query.isEmpty else { return nil }
                for pair in query.split(separator: "&") {
                    let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    let k = percentDecode(String(parts[0]).replacing("+", with: " "))
                    if k == key {
                        let rawVal = parts.count > 1 ? String(parts[1]) : ""
                        return percentDecode(rawVal.replacing("+", with: " "))
                    }
                }
                return nil
            }
        }

        internal static func parseURI(_ raw: String) -> ParsedURI? {
            guard let colonIdx = raw.firstIndex(of: ":") else { return nil }
            let scheme = String(raw[..<colonIdx]).lowercased()
            guard !scheme.isEmpty, scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }) else {
                return nil
            }
            var rest = String(raw[raw.index(after: colonIdx)...])
            var fragment: String? = nil
            if let hashIdx = rest.firstIndex(of: "#") {
                fragment = String(rest[rest.index(after: hashIdx)...])
                rest = String(rest[..<hashIdx])
            }
            var query: String? = nil
            if let qIdx = rest.firstIndex(of: "?") {
                query = String(rest[rest.index(after: qIdx)...])
                rest = String(rest[..<qIdx])
            }
            var host = ""
            var path = rest
            if rest.hasPrefix("//") {
                let afterSlashes = rest.dropFirst(2)
                if let slashIdx = afterSlashes.firstIndex(of: "/") {
                    host = String(afterSlashes[..<slashIdx])
                    path = String(afterSlashes[slashIdx...])
                } else {
                    host = String(afterSlashes)
                    path = ""
                }
            }
            return ParsedURI(scheme: scheme, host: host, path: path, query: query, fragment: fragment)
        }

        internal static func fileURLToPath(_ uri: String) -> String? {
            guard let parsed = parseURI(uri), parsed.scheme == "file" else { return nil }
            guard parsed.host.isEmpty || parsed.host.lowercased() == "localhost" else { return nil }
            let decoded = percentDecode(parsed.path)
            return decoded.isEmpty ? "/" : decoded
        }

        internal static func pathToFileURL(_ path: String) -> String {
            let normalized = path.hasPrefix("/") ? path : "/\(path)"
            var encoded = "file://"
            for byte in normalized.utf8 {
                if isPathURLSafe(byte) {
                    encoded.append(Character(UnicodeScalar(byte)))
                } else {
                    encoded.append("%")
                    encoded.append(hexDigit(byte >> 4))
                    encoded.append(hexDigit(byte & 0x0F))
                }
            }
            return encoded
        }

        private static func parseLineFragment(_ fragment: String?) -> String? {
            guard let fragment, fragment.hasPrefix("L") else { return nil }
            let digits = fragment.dropFirst().prefix(while: { $0.isASCII && $0.isNumber })
            return digits.isEmpty ? nil : String(digits)
        }

        private static func basename(_ path: String) -> String? {
            var trimmed = path
            while trimmed.count > 1 && (trimmed.hasSuffix("/") || trimmed.hasSuffix("\\")) {
                trimmed.removeLast()
            }
            let last = trimmed.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init)
            guard let last, !last.isEmpty else { return nil }
            return last
        }

        internal static func parseBase64DataURI(_ uri: String) -> (mime: String, data: String)? {
            guard uri.hasPrefix("data:") else { return nil }
            let rest = uri.dropFirst("data:".count)
            guard let markerRange = rest.range(of: ";base64,") else { return nil }
            let header = String(rest[..<markerRange.lowerBound])
            let mime = header.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            guard !mime.isEmpty else { return nil }
            let data = String(rest[markerRange.upperBound...])
            return (mime, data)
        }

        private static func percentDecode(_ value: String) -> String {
            var out: [UInt8] = []
            let bytes = Array(value.utf8)
            var i = 0
            while i < bytes.count {
                if bytes[i] == UInt8(ascii: "%"),
                   i + 2 < bytes.count,
                   let hi = fromHex(bytes[i + 1]),
                   let lo = fromHex(bytes[i + 2])
                {
                    out.append((hi << 4) | lo)
                    i += 3
                } else {
                    out.append(bytes[i])
                    i += 1
                }
            }
            return String(decoding: out, as: UTF8.self)
        }

        private static func isPathURLSafe(_ b: UInt8) -> Bool {
            (b >= 0x41 && b <= 0x5A) // A-Z
                || (b >= 0x61 && b <= 0x7A) // a-z
                || (b >= 0x30 && b <= 0x39) // 0-9
                || b == UInt8(ascii: "/")
                || b == UInt8(ascii: "-")
                || b == UInt8(ascii: "_")
                || b == UInt8(ascii: ".")
                || b == UInt8(ascii: "~")
                || b == UInt8(ascii: ":")
        }

        private static func hexDigit(_ nibble: UInt8) -> Character {
            let table: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "A", "B", "C", "D", "E", "F"]
            return table[Int(nibble & 0x0F)]
        }

        private static func fromHex(_ b: UInt8) -> UInt8? {
            switch b {
            case 0x30...0x39: return b - 0x30
            case 0x41...0x46: return b - 0x41 + 10
            case 0x61...0x66: return b - 0x61 + 10
            default: return nil
            }
        }
    }

    // MARK: - 8. Tool Translation (`packages/cli/src/acp/tool.ts`)

    public enum ToolMapper {
        private static let v1Aliases: [String: String] = [
            "bash": "shell",
            "task": "subagent",
            "apply_patch": "patch",
        ]

        // parity: cli/src/acp/tool.ts#ToolInput [status=implemented hash=0f64d5bd4f9d]
        public typealias ToolInput = [String: JSONValue]

        // parity: cli/src/acp/tool.ts#DiffSource [status=implemented hash=6cc9072e993c]
        public struct DiffSource: Equatable, Hashable, Sendable {
            public let toolName: String
            public let input: ToolInput
            public let metadata: [String: JSONValue]?

            public init(toolName: String, input: ToolInput, metadata: [String: JSONValue]? = nil) {
                self.toolName = toolName
                self.input = input
                self.metadata = metadata
            }
        }

        // parity: cli/src/acp/tool.ts#toLocations [status=implemented hash=4fb4e875e3fb]
        public static func toLocations(toolName: String, input: ToolInput, cwd: String) -> [ToolCallLocation] {
            switch canonicalName(toolName) {
            case "shell":
                let dir = stringValue(input["workdir"]) ?? stringValue(input["cwd"]) ?? cwd
                return locationFrom(cwd: cwd, values: [dir])
            case "read", "edit", "write":
                return locationFrom(cwd: cwd, values: [filePath(input)])
            case "patch":
                let paths = patchHunks(input).flatMap { hunk -> [String?] in
                    switch hunk {
                    case .add(let path, _), .delete(let path):
                        return [path]
                    case .update(let path, let movePath, _):
                        return [path, movePath]
                    }
                }
                return locationFrom(cwd: cwd, values: paths)
            case "external_directory":
                return locationFrom(cwd: cwd, values: [stringValue(input["filepath"])])
            case "grep", "glob", "context", "context7_resolve_library_id", "context7_get_library_docs":
                return locationFrom(cwd: cwd, values: [stringValue(input["path"])])
            default:
                return []
            }
        }

        // parity: cli/src/acp/tool.ts#pendingToolCall [status=implemented hash=ba608ad33c26]
        public static func pendingToolCall(
            toolCallId: String,
            toolName: String,
            input: ToolInput,
            title: String? = nil,
            cwd: String
        ) -> ToolCall {
            ToolCall(
                toolCallId: toolCallId,
                name: toolName,
                title: toolTitle(toolName: toolName, input: input, fallback: title),
                kind: toToolKind(toolName),
                status: .pending,
                locations: toLocations(toolName: toolName, input: input, cwd: cwd),
                rawInput: rawInput(toolName: toolName, input: input, cwd: cwd)
            )
        }

        // parity: cli/src/acp/tool.ts#runningToolUpdate [status=implemented hash=c21a44898b12]
        public static func runningToolUpdate(
            toolCallId: String,
            toolName: String,
            input: ToolInput,
            cwd: String
        ) -> ToolCallUpdate {
            ToolCallUpdate(
                toolCallId: toolCallId,
                status: .inProgress,
                kind: toToolKind(toolName),
                title: toolTitle(toolName: toolName, input: input, fallback: nil),
                locations: toLocations(toolName: toolName, input: input, cwd: cwd),
                rawInput: rawInput(toolName: toolName, input: input, cwd: cwd)
            )
        }

        // parity: cli/src/acp/tool.ts#completedToolUpdate [status=implemented hash=eabf7d53a46b]
        public static func completedToolUpdate(
            toolCallId: String,
            toolName: String,
            input: ToolInput,
            content: [SessionMessageSchema.ToolContent],
            metadata: [String: JSONValue]? = nil,
            cwd: String
        ) -> ToolCallUpdate {
            let normalized = toolContent(content)
            let firstText: String? = content.compactMap { part -> String? in
                if case .text(let t) = part { return t }
                return nil
            }.first
            let readText: String? = (canonicalName(toolName) == "read" && firstText != nil)
                ? TUIMini.readDisplayText(firstText!)
                : nil
            let images = normalized.filter { item in
                if case .content(.image) = item { return true }
                return false
            }
            let primary: [ToolCallContent]
            if let readText {
                primary = [.content(.text(text: readText))]
            } else {
                primary = normalized.filter { item in
                    if case .content(.image) = item { return false }
                    return true
                }
            }
            var rawOutput: [String: JSONValue] = [:]
            if let metadata {
                rawOutput["metadata"] = .object(metadata)
            }
            return ToolCallUpdate(
                toolCallId: toolCallId,
                status: .completed,
                locations: toLocations(toolName: toolName, input: input, cwd: cwd),
                content: primary + images,
                rawOutput: rawOutput
            )
        }

        // parity: cli/src/acp/tool.ts#errorToolUpdate [status=implemented hash=fc858086f523]
        public static func errorToolUpdate(
            toolCallId: String,
            toolName: String,
            input: ToolInput,
            content: [SessionMessageSchema.ToolContent]? = nil,
            metadata: [String: JSONValue]? = nil,
            error: String,
            cwd: String
        ) -> ToolCallUpdate {
            var rawOutput: [String: JSONValue] = ["error": .string(error)]
            if let metadata {
                rawOutput["metadata"] = .object(metadata)
            }
            return ToolCallUpdate(
                toolCallId: toolCallId,
                status: .failed,
                kind: toToolKind(toolName),
                title: toolTitle(toolName: toolName, input: input, fallback: nil),
                locations: toLocations(toolName: toolName, input: input, cwd: cwd),
                rawInput: rawInput(toolName: toolName, input: input, cwd: cwd),
                content: toolContent(content ?? []) + [.content(.text(text: error))],
                rawOutput: rawOutput
            )
        }

        // parity: cli/src/acp/tool.ts#canonicalName [status=implemented hash=3a7e01dbd51e]
        public static func canonicalName(_ toolName: String) -> String {
            let lowered = toolName.lowercased()
            return v1Aliases[lowered] ?? lowered
        }

        // parity: cli/src/acp/tool.ts#filePath [status=implemented hash=914d0dfbda76]
        public static func filePath(_ input: ToolInput) -> String? {
            stringValue(input["path"]) ?? stringValue(input["filePath"])
        }

        // parity: cli/src/acp/tool.ts#patchHunks [status=implemented hash=d2b7783d5aea]
        public static func patchHunks(_ input: ToolInput) -> [Patch.Hunk] {
            guard let patchText = stringValue(input["patchText"]), !patchText.isEmpty else { return [] }
            switch Patch.parse(patchText) {
            case .success(let hunks): return hunks
            case .failure: return []
            }
        }

        // parity: cli/src/acp/tool.ts#absolutePath [status=implemented hash=8ff5f8d42a3f]
        public static func absolutePath(_ path: String, cwd: String) -> String {
            if isAbsolutePath(path) { return path }
            return resolvePath(base: cwd, relative: path)
        }

        // parity: cli/src/acp/tool.ts#stringValue [status=implemented hash=e5efd048e19c]
        public static func stringValue(_ value: JSONValue?) -> String? {
            guard case .string(let s) = value else { return nil }
            return s
        }

        private static func toToolKind(_ toolName: String) -> ToolKind {
            switch canonicalName(toolName) {
            case "shell": return .execute
            case "webfetch": return .fetch
            case "edit", "patch", "write": return .edit
            case "grep", "glob", "context", "context7_resolve_library_id", "context7_get_library_docs":
                return .search
            case "read": return .read
            case "subagent": return .think
            default: return .other
            }
        }

        private static func toolContent(_ content: [SessionMessageSchema.ToolContent]) -> [ToolCallContent] {
            content.compactMap { part -> ToolCallContent? in
                switch part {
                case .text(let text):
                    return .content(.text(text: text))
                case .file(let uri, _, _):
                    guard let parsed = Content.parseBase64DataURI(uri), parsed.mime.hasPrefix("image/") else {
                        return nil
                    }
                    return .content(.image(mimeType: parsed.mime, data: parsed.data))
                }
            }
        }

        private static func toolTitle(toolName: String, input: ToolInput, fallback: String?) -> String {
            if isShell(toolName) {
                return stringValue(input["command"])
                    ?? stringValue(input["cmd"])
                    ?? fallback
                    ?? toolName
            }
            if let fallback, !fallback.isEmpty { return fallback }
            return toolName
        }

        private static func rawInput(toolName: String, input: ToolInput, cwd: String) -> ToolInput {
            if !isShell(toolName) { return input }
            let hasCwd: Bool = {
                if case .string(let s) = input["cwd"], !s.isEmpty { return true }
                return false
            }()
            let hasWorkdir: Bool = {
                if case .string(let s) = input["workdir"], !s.isEmpty { return true }
                return false
            }()
            if hasCwd || hasWorkdir { return input }
            var copy = input
            copy["cwd"] = .string(cwd)
            return copy
        }

        private static func isShell(_ toolName: String) -> Bool {
            canonicalName(toolName) == "shell"
        }

        private static func locationFrom(cwd: String, values: [String?]) -> [ToolCallLocation] {
            var seen: Set<String> = []
            var locations: [ToolCallLocation] = []
            for value in values {
                guard let value, !value.isEmpty else { continue }
                let abs = absolutePath(value, cwd: cwd)
                if seen.insert(abs).inserted {
                    locations.append(ToolCallLocation(path: abs))
                }
            }
            return locations
        }

        internal static func isAbsolutePath(_ path: String) -> Bool {
            if path.hasPrefix("/") { return true }
            let chars = Array(path)
            if chars.count >= 3, chars[1] == ":", (chars[2] == "/" || chars[2] == "\\") {
                return chars[0].isASCII && chars[0].isLetter
            }
            return false
        }

        internal static func resolvePath(base: String, relative: String) -> String {
            let combined: String
            if isAbsolutePath(relative) {
                combined = relative
            } else if base.hasSuffix("/") {
                combined = base + relative
            } else {
                combined = base + "/" + relative
            }
            return normalizePOSIXPath(combined)
        }

        internal static func normalizePOSIXPath(_ path: String) -> String {
            let absolute = path.hasPrefix("/")
            var stack: [String] = []
            for part in path.split(separator: "/", omittingEmptySubsequences: true) {
                if part == "." { continue }
                if part == ".." {
                    if !stack.isEmpty && stack.last != ".." {
                        stack.removeLast()
                    } else if !absolute {
                        stack.append("..")
                    }
                } else {
                    stack.append(String(part))
                }
            }
            let joined = stack.joined(separator: "/")
            return absolute ? "/\(joined)" : (joined.isEmpty ? "." : joined)
        }
    }

    // MARK: - 9. Turn Event Translator (`packages/cli/src/acp/translate.ts`)

    public enum Translate {
        private static let retryMeta = "opencode/retry"

        // parity: cli/src/acp/translate.ts#TurnStart [status=implemented hash=392218aa792a]
        public struct TurnStart: Equatable, Hashable, Sendable {
            public enum Kind: String, Equatable, Hashable, Sendable {
                case input
                case compaction
            }

            public let type: Kind
            public let id: SessionMessageSchema.ID

            public init(type: Kind, id: SessionMessageSchema.ID) {
                self.type = type
                self.id = id
            }
        }

        // parity: cli/src/acp/translate.ts#Terminal [status=implemented hash=46eafed8d9d5]
        public enum Terminal: String, Equatable, Hashable, Sendable, Codable {
            case succeeded
            case failed
            case interrupted
        }

        // parity: cli/src/acp/translate.ts#TurnContext [status=implemented hash=764171c642eb]
        public struct TurnContext: Equatable, Hashable, Sendable {
            public let sessionID: SessionID
            public let cwd: String
            public let start: TurnStart?
            public let childUpdates: Bool
            public let compaction: Bool

            public init(
                sessionID: SessionID,
                cwd: String,
                start: TurnStart? = nil,
                childUpdates: Bool = false,
                compaction: Bool = false
            ) {
                self.sessionID = sessionID
                self.cwd = cwd
                self.start = start
                self.childUpdates = childUpdates
                self.compaction = compaction
            }
        }

        public struct TrackedTool: Equatable, Hashable, Sendable {
            public let sessionID: String
            public let id: String
            public let name: String
            public let input: ToolMapper.ToolInput
            public let metadata: [String: JSONValue]

            public init(
                sessionID: String,
                id: String,
                name: String,
                input: ToolMapper.ToolInput = [:],
                metadata: [String: JSONValue] = [:]
            ) {
                self.sessionID = sessionID
                self.id = id
                self.name = name
                self.input = input
                self.metadata = metadata
            }
        }

        public struct RetryStatus: Equatable, Hashable, Sendable, Codable {
            public let attempt: Int
            public let nextRetryAt: String
            public let error: SessionErrorSchema.Error

            public init(attempt: Int, nextRetryAt: String, error: SessionErrorSchema.Error) {
                self.attempt = attempt
                self.nextRetryAt = nextRetryAt
                self.error = error
            }

            public var asJSONValue: JSONValue {
                .object([
                    "attempt": .int(Int64(attempt)),
                    "nextRetryAt": .string(nextRetryAt),
                    "error": Compaction.encodeErrorJSON(error),
                ])
            }
        }

        public struct TrackedChild: Equatable, Hashable, Sendable {
            public let session: Child.Session
            public let turnID: String?

            public var id: String { session.id }
            public var parentID: String { session.parentID }
            public var depth: Int { session.depth }
            public var title: String? { session.title }

            public init(session: Child.Session, turnID: String? = nil) {
                self.session = session
                self.turnID = turnID
            }
        }

        public struct TrackedUsage: Equatable, Hashable, Sendable {
            public let turn: SessionSchema.TokenUsage
            public let last: SessionSchema.TokenUsage

            public init(turn: SessionSchema.TokenUsage, last: SessionSchema.TokenUsage) {
                self.turn = turn
                self.last = last
            }
        }

        public struct ExecutionError: Equatable, Hashable, Sendable {
            public let type: String
            public let message: String

            public init(type: String, message: String) {
                self.type = type
                self.message = message
            }
        }

        // parity: cli/src/acp/translate.ts#TurnState [status=implemented hash=c4836d8f5814]
        public struct TurnState: Equatable, Sendable {
            public var started: Bool
            public var tools: [String: TrackedTool]
            public var retries: [String: RetryStatus]
            public var compactions: Compaction.Tracked
            public var children: [String: TrackedChild]
            public var openChildren: Set<String>
            /// Background shells that will wake their session, with the inbox ID of their notice once queued.
            public var shells: [String: String?]
            public var asks: Set<String>
            public var finish: SessionMessageSchema.FinishReason?
            public var usage: TrackedUsage?
            public var stepError: SessionErrorSchema.Error?
            public var executionError: ExecutionError?

            public init(
                started: Bool = false,
                tools: [String: TrackedTool] = [:],
                retries: [String: RetryStatus] = [:],
                compactions: Compaction.Tracked = [:],
                children: [String: TrackedChild] = [:],
                openChildren: Set<String> = [],
                shells: [String: String?] = [:],
                asks: Set<String> = [],
                finish: SessionMessageSchema.FinishReason? = nil,
                usage: TrackedUsage? = nil,
                stepError: SessionErrorSchema.Error? = nil,
                executionError: ExecutionError? = nil
            ) {
                self.started = started
                self.tools = tools
                self.retries = retries
                self.compactions = compactions
                self.children = children
                self.openChildren = openChildren
                self.shells = shells
                self.asks = asks
                self.finish = finish
                self.usage = usage
                self.stepError = stepError
                self.executionError = executionError
            }
        }

        public struct PermissionAskEvent: Equatable, Hashable, Sendable {
            public let id: String
            public let sessionID: String
            public let action: String
            public let resources: [String]
            public let metadata: [String: JSONValue]?
            public let sourceToolID: String?

            public init(
                id: String,
                sessionID: String,
                action: String,
                resources: [String] = [],
                metadata: [String: JSONValue]? = nil,
                sourceToolID: String? = nil
            ) {
                self.id = id
                self.sessionID = sessionID
                self.action = action
                self.resources = resources
                self.metadata = metadata
                self.sourceToolID = sourceToolID
            }
        }

        // parity: cli/src/acp/translate.ts#Output [status=implemented hash=175ef473b0d3]
        public enum Output: Equatable, Sendable {
            case sessionUpdate(update: SessionUpdate, diff: ToolMapper.DiffSource? = nil)
            case childUpdate(update: Child.Update, diff: ToolMapper.DiffSource? = nil)
            case permissionAsk(event: PermissionAskEvent, tool: TrackedTool? = nil, child: TrackedChild? = nil)
            case formAsk(form: Elicitation.AskedForm, child: TrackedChild? = nil)
            case askSettled(id: String)
        }

        // parity: cli/src/acp/translate.ts#Folded [status=implemented hash=fdaf64a1349e]
        public struct Folded: Equatable, Sendable {
            public let state: TurnState
            public let outputs: [Output]
            public let terminal: Terminal?

            public init(state: TurnState, outputs: [Output] = [], terminal: Terminal? = nil) {
                self.state = state
                self.outputs = outputs
                self.terminal = terminal
            }
        }

        // parity: cli/src/acp/translate.ts#initial [status=implemented hash=dce844db4191]
        public static let initial = TurnState()

        // parity: cli/src/acp/translate.ts#fold [status=implemented hash=77068dba750d]
        public static func fold(_ state: TurnState, event: OpenCodeEvent, ctx: TurnContext) -> Folded {
            if event.type == "session.created" {
                return childCreated(state: state, event: event, ctx: ctx)
            }

            let sessionID = sessionIDFromEvent(event)
            let child = sessionID.flatMap { state.children[$0] }
            let openChild = child.flatMap { state.openChildren.contains($0.id) ? $0 : nil }

            if event.type == "permission.asked",
               let ask = decodePermissionAsk(event),
               (ask.sessionID == ctx.sessionID.rawValue || openChild != nil)
            {
                let tool = ask.sourceToolID.flatMap { state.tools[toolKey(ask.sessionID, $0)] }
                var next = state
                next.asks.insert(ask.id)
                return Folded(state: next, outputs: [.permissionAsk(event: ask, tool: tool, child: openChild)])
            }

            if event.type == "form.created",
               let form = decodeFormCreated(event),
               (form.sessionID == ctx.sessionID.rawValue || openChild != nil)
            {
                var next = state
                next.asks.insert(form.id)
                return Folded(state: next, outputs: [.formAsk(form: form, child: openChild)])
            }

            let settledID: String? = {
                guard case .object(let obj) = event.data else { return nil }
                if event.type == "permission.replied" {
                    return ToolMapper.stringValue(obj["requestID"])
                }
                if event.type == "form.replied" || event.type == "form.cancelled" {
                    return ToolMapper.stringValue(obj["id"])
                }
                return nil
            }()
            if let settledID, state.asks.contains(settledID) {
                var next = state
                next.asks.remove(settledID)
                return Folded(state: next, outputs: [.askSettled(id: settledID)])
            }

            guard let sessionID, (sessionID == ctx.sessionID.rawValue || child != nil) else {
                return Folded(state: state)
            }

            if event.type == "session.inbox.enqueued" {
                return Folded(state: shellNoticed(state: state, event: event))
            }

            if event.type == "session.inbox.delivered" || event.type == "session.inbox.cancelled" {
                let inboxID = objectField(event.data, "inboxID") ?? ""
                var settled = noticeSettled(state: state, inboxID: inboxID)
                if sessionID == ctx.sessionID.rawValue
                    && event.type == "session.inbox.delivered"
                    && (ctx.start == nil || inboxID == ctx.start?.id.rawValue)
                {
                    settled.started = true
                }
                return Folded(state: settled)
            }

            if child == nil && !state.started {
                return Folded(state: state)
            }

            if let child {
                return childEvent(state: state, event: event, ctx: ctx, child: child)
            }
            return rootEvent(state: state, event: event, ctx: ctx)
        }

        /// Whether work that outlives the turn, such as a background child or shell, can still wake the session.
        // parity: cli/src/acp/translate.ts#pending [status=implemented hash=b7e8f75a2ba1]
        public static func pending(_ state: TurnState) -> Bool {
            !state.openChildren.isEmpty || !state.shells.isEmpty
        }

        // parity: cli/src/acp/translate.ts#projectChild [status=implemented hash=d8df1693ae8b]
        public static func projectChild(ctx: TurnContext, child: TrackedChild) -> Bool {
            !ctx.childUpdates && ctx.start != nil && child.turnID == ctx.start?.id.rawValue
        }

        // parity: cli/src/acp/translate.ts#failure [status=implemented hash=e2147eb93841]
        public static func failure(_ state: TurnState) -> Errors.ACPError? {
            let type: String?
            let message: String?
            if let step = state.stepError {
                type = step.type
                message = step.message
            } else if let exec = state.executionError {
                type = exec.type
                message = exec.message
            } else {
                type = nil
                message = nil
            }
            guard let type else { return nil }
            if type == "provider.auth" {
                return .authRequired(Errors.AuthRequiredError())
            }
            if type != "aborted" && type != "provider.content-filter" {
                let safeMessage = (message?.isEmpty == false) ? message! : "OpenCode prompt failed"
                return .serviceFailure(
                    Errors.ServiceFailureError(safeMessage: safeMessage, service: "session", errorName: type)
                )
            }
            return nil
        }

        // parity: cli/src/acp/translate.ts#response [status=implemented hash=a369d3e26cab]
        public static func response(_ state: TurnState, sessionID: String, terminal: Terminal) -> PromptResponse {
            let usage: UsageSummary? = state.usage.map { tracked in
                let tokens = tracked.turn
                return UsageSummary(
                    inputTokens: tokens.input,
                    outputTokens: tokens.output,
                    totalTokens: tokens.total,
                    thoughtTokens: tokens.reasoning > 0 ? tokens.reasoning : nil,
                    cachedReadTokens: tokens.cache.read > 0 ? tokens.cache.read : nil,
                    cachedWriteTokens: tokens.cache.write > 0 ? tokens.cache.write : nil
                )
            }
            let errorType = state.stepError?.type ?? state.executionError?.type
            let stopReason = resolveStopReason(terminal: terminal, finish: state.finish, error: errorType)
            let meta: [String: JSONValue] = state.retries[sessionID].map { [retryMeta: $0.asJSONValue] } ?? [:]
            return PromptResponse(stopReason: stopReason, usage: usage, _meta: meta)
        }

        // parity: cli/src/acp/translate.ts#abandon [status=implemented hash=c06986a9fd4a]
        public static func abandon(_ state: TurnState, ctx: TurnContext) -> Folded {
            let compaction = state.compactions[ctx.sessionID.rawValue]
            var next = state
            next.tools = [:]
            next.compactions.removeValue(forKey: ctx.sessionID.rawValue)

            var outputs: [Output] = []
            for tool in state.tools.values {
                let child = state.children[tool.sessionID]
                let update = SessionUpdate.toolCallUpdate(
                    ToolMapper.errorToolUpdate(
                        toolCallId: tool.id,
                        toolName: tool.name,
                        input: tool.input,
                        content: [],
                        metadata: tool.metadata,
                        error: "Cancelled",
                        cwd: ctx.cwd
                    )
                )
                outputs.append(contentsOf: route(ctx: ctx, child: child, update: update))
            }
            if let compaction {
                let standard = Compaction.usesStandardUpdates(
                    compaction: ctx.compaction,
                    childUpdates: ctx.childUpdates,
                    child: false
                )
                outputs.append(
                    contentsOf: route(
                        ctx: ctx,
                        child: nil,
                        update: Compaction.abandon(started: compaction, standardUpdates: standard)
                    )
                )
            }
            return Folded(state: next, outputs: outputs)
        }

        // parity: cli/src/acp/translate.ts#reasoningMessageID [status=implemented hash=996fae7b44b7]
        public static func reasoningMessageID(_ messageID: String, ordinal: Int) -> String {
            "\(messageID):reasoning:\(ordinal)"
        }

        private static func childCreated(state: TurnState, event: OpenCodeEvent, ctx: TurnContext) -> Folded {
            guard case .object(let obj) = event.data,
                  let parentID = ToolMapper.stringValue(obj["parentID"]),
                  !parentID.isEmpty,
                  let childSessionID = ToolMapper.stringValue(obj["sessionID"])
            else {
                return Folded(state: state)
            }
            let parent = parentID == ctx.sessionID.rawValue ? nil : state.children[parentID]
            guard parent != nil || parentID == ctx.sessionID.rawValue else {
                return Folded(state: state)
            }
            let child = TrackedChild(
                session: Child.Session(
                    id: childSessionID,
                    parentID: parentID,
                    depth: parent.map { $0.depth + 1 } ?? 1,
                    title: ToolMapper.stringValue(obj["title"])
                ),
                turnID: parent != nil ? parent?.turnID : ctx.start?.id.rawValue
            )
            var next = state
            next.children[child.id] = child
            next.openChildren.insert(child.id)
            return Folded(state: next, outputs: childStatus(ctx: ctx, child: child.session, event: .status(.created)))
        }

        private static func rootEvent(state: TurnState, event: OpenCodeEvent, ctx: TurnContext) -> Folded {
            switch event.type {
            case "session.step.started":
                var cleared = state
                cleared.stepError = nil
                return sessionEvent(state: cleared, event: event, ctx: ctx, child: nil)

            case "session.step.ended":
                var next = state
                if let tokens = decodeTokenUsage(event.data, key: "tokens") {
                    next = recordStep(state: next, tokens: tokens)
                }
                if let finishRaw = objectField(event.data, "finish"),
                   let finish = SessionMessageSchema.FinishReason(rawValue: finishRaw)
                {
                    next.finish = finish
                }
                return Folded(state: next)

            case "session.step.failed":
                var next = state
                if let tokens = decodeTokenUsage(event.data, key: "tokens") {
                    next = recordStep(state: next, tokens: tokens)
                }
                if let err = decodeSessionError(event.data, key: "error") {
                    next.stepError = err
                }
                return Folded(state: next)

            case "session.execution.succeeded":
                var next = state
                next.started = ctx.start != nil
                return Folded(state: next, terminal: .succeeded)

            case "session.execution.interrupted":
                var next = state
                next.started = ctx.start != nil
                return Folded(state: next, terminal: .interrupted)

            case "session.execution.failed":
                var next = state
                next.started = ctx.start != nil
                if let err = decodeSessionError(event.data, key: "error") {
                    next.executionError = ExecutionError(type: err.type, message: err.message)
                }
                return Folded(state: next, terminal: .failed)

            default:
                return sessionEvent(state: state, event: event, ctx: ctx, child: nil)
            }
        }

        private static func childEvent(
            state: TurnState,
            event: OpenCodeEvent,
            ctx: TurnContext,
            child: TrackedChild
        ) -> Folded {
            switch event.type {
            case "session.execution.started":
                var next = state
                next.openChildren.insert(child.id)
                return Folded(
                    state: next,
                    outputs: childStatus(ctx: ctx, child: child.session, event: .status(.running))
                )
            case "session.execution.succeeded":
                return childEnded(state: state, ctx: ctx, child: child.session, status: .status(.completed))
            case "session.execution.interrupted":
                return childEnded(state: state, ctx: ctx, child: child.session, status: .status(.interrupted))
            case "session.execution.failed":
                let err = decodeSessionError(event.data, key: "error").map {
                    Child.StatusError(type: $0.type, message: $0.message)
                }
                return childEnded(state: state, ctx: ctx, child: child.session, status: .status(.failed, error: err))
            default:
                return sessionEvent(state: state, event: event, ctx: ctx, child: child)
            }
        }

        private static func sessionEvent(
            state: TurnState,
            event: OpenCodeEvent,
            ctx: TurnContext,
            child: TrackedChild?
        ) -> Folded {
            let sessionID = child?.id ?? ctx.sessionID.rawValue
            let send: (SessionUpdate) -> [Output] = { route(ctx: ctx, child: child, update: $0) }

            switch event.type {
            case "session.step.started":
                guard state.retries[sessionID] != nil else { return Folded(state: state) }
                var next = state
                next.retries.removeValue(forKey: sessionID)
                return Folded(state: next, outputs: send(.sessionInfoUpdate(_meta: [retryMeta: .null])))

            case "session.retry.scheduled":
                guard case .object(let obj) = event.data,
                      let attempt = intValue(obj["attempt"]),
                      let atMs = int64Value(obj["at"]),
                      let error = decodeSessionError(event.data, key: "error")
                else {
                    return Folded(state: state)
                }
                let retry = RetryStatus(
                    attempt: attempt,
                    nextRetryAt: formatISO8601UTC(epochMillis: atMs),
                    error: error
                )
                var next = state
                next.retries[sessionID] = retry
                return Folded(state: next, outputs: send(.sessionInfoUpdate(_meta: [retryMeta: retry.asJSONValue])))

            case "session.compaction.started", "session.compaction.ended", "session.compaction.failed":
                guard let lifecycle = decodeCompactionLifecycle(event) else { return Folded(state: state) }
                let standard = Compaction.usesStandardUpdates(
                    compaction: ctx.compaction,
                    childUpdates: ctx.childUpdates,
                    child: child != nil
                )
                let applied = Compaction.apply(event: lifecycle, tracked: state.compactions, standardUpdates: standard)
                var next = state
                next.compactions = applied.tracked
                return Folded(state: next, outputs: applied.updates.flatMap(send))

            case "session.compaction.delta":
                let text = objectField(event.data, "text") ?? ""
                let standard = Compaction.usesStandardUpdates(
                    compaction: ctx.compaction,
                    childUpdates: ctx.childUpdates,
                    child: child != nil
                )
                let update = Compaction.chunk(
                    started: state.compactions[sessionID],
                    text: text,
                    standardUpdates: standard
                )
                return Folded(state: state, outputs: update.map(send) ?? [])

            case "session.text.delta":
                let messageId = objectField(event.data, "assistantMessageID") ?? ""
                let delta = objectField(event.data, "delta") ?? ""
                return Folded(
                    state: state,
                    outputs: send(.agentMessageChunk(messageId: messageId, content: .text(text: delta)))
                )

            case "session.reasoning.delta":
                guard case .object(let obj) = event.data else { return Folded(state: state) }
                let messageId = ToolMapper.stringValue(obj["assistantMessageID"]) ?? ""
                let ordinal = intValue(obj["ordinal"]) ?? 0
                let delta = ToolMapper.stringValue(obj["delta"]) ?? ""
                return Folded(
                    state: state,
                    outputs: send(
                        .agentThoughtChunk(
                            messageId: reasoningMessageID(messageId, ordinal: ordinal),
                            content: .text(text: delta)
                        )
                    )
                )

            case "session.tool.input.started":
                guard case .object(let obj) = event.data,
                      let eventSessionID = ToolMapper.stringValue(obj["sessionID"]),
                      let id = ToolMapper.stringValue(obj["id"]),
                      let name = ToolMapper.stringValue(obj["name"])
                else {
                    return Folded(state: state)
                }
                var next = state
                next.tools[toolKey(eventSessionID, id)] = TrackedTool(sessionID: eventSessionID, id: id, name: name)
                let call = ToolMapper.pendingToolCall(toolCallId: id, toolName: name, input: [:], cwd: ctx.cwd)
                return Folded(state: next, outputs: send(.toolCall(call)))

            case "session.tool.called":
                guard case .object(let obj) = event.data,
                      let eventSessionID = ToolMapper.stringValue(obj["sessionID"]),
                      let id = ToolMapper.stringValue(obj["id"])
                else {
                    return Folded(state: state)
                }
                let inputDict = objectDict(obj["input"]) ?? [:]
                let key = toolKey(eventSessionID, id)
                let existing = state.tools[key] ?? TrackedTool(sessionID: eventSessionID, id: id, name: "tool")
                let updated = TrackedTool(
                    sessionID: existing.sessionID,
                    id: existing.id,
                    name: existing.name,
                    input: inputDict,
                    metadata: existing.metadata
                )
                var next = state
                next.tools[key] = updated
                let update = ToolMapper.runningToolUpdate(
                    toolCallId: id,
                    toolName: updated.name,
                    input: updated.input,
                    cwd: ctx.cwd
                )
                return Folded(state: next, outputs: send(.toolCallUpdate(update)))

            case "session.tool.progress":
                guard case .object(let obj) = event.data,
                      let eventSessionID = ToolMapper.stringValue(obj["sessionID"]),
                      let id = ToolMapper.stringValue(obj["id"])
                else {
                    return Folded(state: state)
                }
                let key = toolKey(eventSessionID, id)
                guard let current = state.tools[key] else { return Folded(state: state) }
                let meta = objectDict(obj["metadata"]) ?? [:]
                var next = state
                next.tools[key] = TrackedTool(
                    sessionID: current.sessionID,
                    id: current.id,
                    name: current.name,
                    input: current.input,
                    metadata: meta
                )
                let update = ToolMapper.runningToolUpdate(
                    toolCallId: id,
                    toolName: current.name,
                    input: current.input,
                    cwd: ctx.cwd
                )
                return Folded(state: next, outputs: send(.toolCallUpdate(update)))

            case "session.tool.success":
                guard case .object(let obj) = event.data,
                      let eventSessionID = ToolMapper.stringValue(obj["sessionID"]),
                      let id = ToolMapper.stringValue(obj["id"])
                else {
                    return Folded(state: state)
                }
                let key = toolKey(eventSessionID, id)
                let tool = state.tools[key] ?? TrackedTool(sessionID: eventSessionID, id: id, name: "tool")
                let metadata = objectDict(obj["metadata"])
                let content = decodeToolContent(obj["content"])
                var next = state
                next.tools.removeValue(forKey: key)
                if let metadata,
                   case .string("running") = metadata["status"],
                   case .string(let shellID) = metadata["shellID"],
                   next.shells[shellID] == nil
                {
                    next.shells[shellID] = Optional<String>.none
                }
                let update = ToolMapper.completedToolUpdate(
                    toolCallId: id,
                    toolName: tool.name,
                    input: tool.input,
                    content: content,
                    metadata: metadata,
                    cwd: ctx.cwd
                )
                let diffSource = ToolMapper.DiffSource(toolName: tool.name, input: tool.input, metadata: metadata)
                let routed = send(.toolCallUpdate(update)).map { out -> Output in
                    switch out {
                    case .sessionUpdate(let u, _):
                        return .sessionUpdate(update: u, diff: diffSource)
                    case .childUpdate(let u, _):
                        return .childUpdate(update: u, diff: diffSource)
                    default:
                        return out
                    }
                }
                return Folded(state: next, outputs: routed)

            case "session.tool.failed":
                guard case .object(let obj) = event.data,
                      let eventSessionID = ToolMapper.stringValue(obj["sessionID"]),
                      let id = ToolMapper.stringValue(obj["id"])
                else {
                    return Folded(state: state)
                }
                let key = toolKey(eventSessionID, id)
                let tool = state.tools[key] ?? TrackedTool(sessionID: eventSessionID, id: id, name: "tool")
                let metadata = objectDict(obj["metadata"]) ?? tool.metadata
                let content = decodeToolContent(obj["content"])
                let errorMessage = decodeSessionError(event.data, key: "error")?.message ?? "Tool failed"
                var next = state
                next.tools.removeValue(forKey: key)
                let update = ToolMapper.errorToolUpdate(
                    toolCallId: id,
                    toolName: tool.name,
                    input: tool.input,
                    content: content,
                    metadata: metadata,
                    error: errorMessage,
                    cwd: ctx.cwd
                )
                return Folded(state: next, outputs: send(.toolCallUpdate(update)))

            default:
                return Folded(state: state)
            }
        }

        private static func route(ctx: TurnContext, child: TrackedChild?, update: SessionUpdate) -> [Output] {
            guard let child else { return [.sessionUpdate(update: update)] }
            let projected = Child.project(update, child: child.session)
            if ctx.childUpdates {
                return childStatus(ctx: ctx, child: child.session, event: .update(projected))
            }
            return projectChild(ctx: ctx, child: child) ? [.sessionUpdate(update: projected)] : []
        }

        private static func childStatus(ctx: TurnContext, child: Child.Session, event: Child.Event) -> [Output] {
            guard ctx.childUpdates else { return [] }
            return [.childUpdate(update: Child.update(rootSessionID: ctx.sessionID.rawValue, child: child, event: event))]
        }

        private static func childEnded(
            state: TurnState,
            ctx: TurnContext,
            child: Child.Session,
            status: Child.Event
        ) -> Folded {
            var next = state
            next.openChildren.remove(child.id)
            return Folded(state: next, outputs: childStatus(ctx: ctx, child: child, event: status))
        }

        private static func shellNoticed(state: TurnState, event: OpenCodeEvent) -> TurnState {
            guard case .object(let obj) = event.data,
                  let inboxID = ToolMapper.stringValue(obj["inboxID"]),
                  case .object(let item) = obj["item"],
                  ToolMapper.stringValue(item["type"]) == "synthetic",
                  case .object(let payload) = item["payload"],
                  case .object(let metadata) = payload["metadata"],
                  let shellID = ToolMapper.stringValue(metadata["shellID"]),
                  ToolMapper.stringValue(metadata["jobID"]) != nil
            else {
                return state
            }
            var next = state
            next.shells[shellID] = inboxID
            return next
        }

        private static func noticeSettled(state: TurnState, inboxID: String) -> TurnState {
            let remaining = state.shells.filter { $0.value != inboxID }
            if remaining.count == state.shells.count { return state }
            var next = state
            next.shells = remaining
            return next
        }

        private static func recordStep(state: TurnState, tokens: SessionSchema.TokenUsage) -> TurnState {
            var next = state
            if let existing = state.usage?.turn {
                let sum = SessionSchema.TokenUsage(
                    input: existing.input + tokens.input,
                    output: existing.output + tokens.output,
                    reasoning: existing.reasoning + tokens.reasoning,
                    cache: SessionSchema.TokenUsage.Cache(
                        read: existing.cache.read + tokens.cache.read,
                        write: existing.cache.write + tokens.cache.write
                    )
                )
                next.usage = TrackedUsage(turn: sum, last: tokens)
            } else {
                next.usage = TrackedUsage(turn: tokens, last: tokens)
            }
            return next
        }

        private static func sessionIDFromEvent(_ event: OpenCodeEvent) -> String? {
            guard case .object(let obj) = event.data else { return nil }
            if let sid = ToolMapper.stringValue(obj["sessionID"]) {
                return sid
            }
            if event.type == "form.created",
               case .object(let form) = obj["form"],
               let sid = ToolMapper.stringValue(form["sessionID"])
            {
                return sid
            }
            return nil
        }

        private static func toolKey(_ sessionID: String, _ id: String) -> String {
            "\(sessionID):\(id)"
        }

        private static func resolveStopReason(
            terminal: Terminal,
            finish: SessionMessageSchema.FinishReason?,
            error: String?
        ) -> StopReason {
            if terminal == .interrupted || error == "aborted" { return .cancelled }
            if finish == .length { return .maxTokens }
            if finish == .contentFilter || error == "provider.content-filter" { return .refusal }
            return .endTurn
        }

        // MARK: Event JSON decoding helpers

        private static func objectField(_ data: JSONValue, _ key: String) -> String? {
            guard case .object(let obj) = data else { return nil }
            return ToolMapper.stringValue(obj[key])
        }

        private static func objectDict(_ value: JSONValue?) -> [String: JSONValue]? {
            guard case .object(let obj) = value else { return nil }
            return obj
        }

        private static func intValue(_ value: JSONValue?) -> Int? {
            switch value {
            case .int(let i): return Int(i)
            case .double(let d): return Int(d)
            default: return nil
            }
        }

        private static func int64Value(_ value: JSONValue?) -> Int64? {
            switch value {
            case .int(let i): return i
            case .double(let d): return Int64(d)
            default: return nil
            }
        }

        private static func doubleValue(_ value: JSONValue?) -> Double? {
            switch value {
            case .double(let d): return d
            case .int(let i): return Double(i)
            default: return nil
            }
        }

        private static func decodeTokenUsage(_ data: JSONValue, key: String) -> SessionSchema.TokenUsage? {
            guard case .object(let obj) = data,
                  case .object(let tok) = obj[key],
                  let input = doubleValue(tok["input"]),
                  let output = doubleValue(tok["output"])
            else {
                return nil
            }
            let reasoning = doubleValue(tok["reasoning"]) ?? 0
            let cacheObj = objectDict(tok["cache"]) ?? [:]
            let read = doubleValue(cacheObj["read"]) ?? 0
            let write = doubleValue(cacheObj["write"]) ?? 0
            return SessionSchema.TokenUsage(
                input: input,
                output: output,
                reasoning: reasoning,
                cache: SessionSchema.TokenUsage.Cache(read: read, write: write)
            )
        }

        private static func decodeSessionError(_ data: JSONValue, key: String) -> SessionErrorSchema.Error? {
            guard case .object(let obj) = data,
                  case .object(let err) = obj[key],
                  let type = ToolMapper.stringValue(err["type"]),
                  let message = ToolMapper.stringValue(err["message"])
            else {
                return nil
            }
            let status = intValue(err["status"])
            let retryAfterMs = int64Value(err["retryAfterMs"])
            let response: SessionErrorSchema.Error.Response? = {
                if case .object(let resp) = err["response"], let body = ToolMapper.stringValue(resp["body"]) {
                    return SessionErrorSchema.Error.Response(body: body)
                }
                return nil
            }()
            return SessionErrorSchema.Error(
                type: type,
                message: message,
                status: status,
                response: response,
                retryAfterMs: retryAfterMs
            )
        }

        private static func decodePermissionAsk(_ event: OpenCodeEvent) -> PermissionAskEvent? {
            guard case .object(let obj) = event.data,
                  let id = ToolMapper.stringValue(obj["id"]),
                  let sessionID = ToolMapper.stringValue(obj["sessionID"]),
                  let action = ToolMapper.stringValue(obj["action"])
            else {
                return nil
            }
            let resources: [String] = {
                guard case .array(let arr) = obj["resources"] else { return [] }
                return arr.compactMap { ToolMapper.stringValue($0) }
            }()
            let metadata = objectDict(obj["metadata"])
            let sourceToolID: String? = {
                guard case .object(let src) = obj["source"] else { return nil }
                return ToolMapper.stringValue(src["id"])
            }()
            return PermissionAskEvent(
                id: id,
                sessionID: sessionID,
                action: action,
                resources: resources,
                metadata: metadata,
                sourceToolID: sourceToolID
            )
        }

        private static func decodeFormCreated(_ event: OpenCodeEvent) -> Elicitation.AskedForm? {
            guard case .object(let obj) = event.data,
                  let formValue = obj["form"]
            else {
                return nil
            }
            return try? ClientCodec.fromJSONValue(Elicitation.AskedForm.self, value: formValue)
        }

        private static func decodeCompactionLifecycle(_ event: OpenCodeEvent) -> Compaction.LifecycleEvent? {
            guard case .object(let obj) = event.data,
                  let sessionID = ToolMapper.stringValue(obj["sessionID"]),
                  let reasonRaw = ToolMapper.stringValue(obj["reason"]),
                  let reason = SessionMessageSchema.CompactionReason(rawValue: reasonRaw)
            else {
                return nil
            }
            switch event.type {
            case "session.compaction.started":
                return .started(
                    eventID: event.id,
                    sessionID: sessionID,
                    reason: reason,
                    inputID: ToolMapper.stringValue(obj["inputID"])
                )
            case "session.compaction.ended":
                return .ended(
                    sessionID: sessionID,
                    reason: reason,
                    text: ToolMapper.stringValue(obj["text"]) ?? ""
                )
            case "session.compaction.failed":
                guard let error = decodeSessionError(event.data, key: "error") else { return nil }
                return .failed(
                    eventID: event.id,
                    sessionID: sessionID,
                    reason: reason,
                    inputID: ToolMapper.stringValue(obj["inputID"]),
                    error: error
                )
            default:
                return nil
            }
        }

        private static func decodeToolContent(_ value: JSONValue?) -> [SessionMessageSchema.ToolContent] {
            guard case .array(let items) = value else { return [] }
            return items.compactMap { item -> SessionMessageSchema.ToolContent? in
                guard case .object(let dict) = item,
                      let type = ToolMapper.stringValue(dict["type"])
                else {
                    return nil
                }
                switch type {
                case "text":
                    guard let text = ToolMapper.stringValue(dict["text"]) else { return nil }
                    return .text(text)
                case "file":
                    guard let uri = ToolMapper.stringValue(dict["uri"]),
                          let mime = ToolMapper.stringValue(dict["mime"])
                    else {
                        return nil
                    }
                    return .file(uri: uri, mime: mime, name: ToolMapper.stringValue(dict["name"]))
                default:
                    return nil
                }
            }
        }

        internal static func formatISO8601UTC(epochMillis: Int64) -> String {
            let millisPerDay: Int64 = 86_400_000
            var days = epochMillis / millisPerDay
            var rem = epochMillis % millisPerDay
            if rem < 0 {
                rem += millisPerDay
                days -= 1
            }
            let millis = Int(rem % 1000)
            let totalSeconds = Int(rem / 1000)
            let second = totalSeconds % 60
            let minute = (totalSeconds / 60) % 60
            let hour = totalSeconds / 3600

            let z = days + 719_468
            let era = (z >= 0 ? z : z - 146_096) / 146_097
            let doe = z - era * 146_097
            let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
            let y = yoe + era * 400
            let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
            let mp = (5 * doy + 2) / 153
            let day = Int(doy - (153 * mp + 2) / 5 + 1)
            let month = Int(mp < 10 ? mp + 3 : mp - 9)
            let year = Int(y + (month <= 2 ? 1 : 0))

            return "\(padZero(year, 4))-\(padZero(month, 2))-\(padZero(day, 2))T"
                + "\(padZero(hour, 2)):\(padZero(minute, 2)):\(padZero(second, 2)).\(padZero(millis, 3))Z"
        }

        private static func padZero(_ value: Int, _ width: Int) -> String {
            let s = String(value)
            if s.count >= width { return s }
            return String(repeating: "0", count: width - s.count) + s
        }
    }

    // MARK: - 10. Elicitation Data Model (`packages/cli/src/acp/elicitation.ts` core types)

    public enum Elicitation {
        // parity: cli/src/acp/elicitation.ts#AskedForm [status=implemented hash=52f5f5604677]
        public struct AskedForm: Equatable, Hashable, Sendable, Codable {
            public let id: String
            public let sessionID: String
            public let title: String
            public let metadata: FormSchema.Metadata?
            public let fields: [FormSchema.Field]

            public init(
                id: String,
                sessionID: String,
                title: String,
                metadata: FormSchema.Metadata? = nil,
                fields: [FormSchema.Field]
            ) {
                self.id = id
                self.sessionID = sessionID
                self.title = title
                self.metadata = metadata
                self.fields = fields
            }

            public init(from info: FormSchema.Info) {
                self.id = info.id.rawValue
                self.sessionID = info.sessionID
                self.title = info.title
                self.metadata = info.metadata
                self.fields = info.fields.elements
            }
        }

        // parity: cli/src/acp/elicitation.ts#UnshownQuestionMessage [status=implemented hash=cb642872b285]
        public static let unshownQuestionMessage =
            "The question couldn't be shown to the user in this client. Continue without an answer: make reasonable assumptions and state them, or ask the user in your reply if you can't proceed."

        public enum Outcome: Equatable, Hashable, Sendable {
            case answer(FormSchema.Answer)
            case cancel
        }
    }

    // MARK: - Pure-Swift Unified Diff Engine (supports permission previews & completed diffs)

    public enum UnifiedDiff {
        public struct Hunk: Equatable, Hashable, Sendable {
            public var oldStart: Int
            public var oldLines: Int
            public var newStart: Int
            public var newLines: Int
            public var lines: [String]
            public var lineDelimiters: [String]

            public init(
                oldStart: Int,
                oldLines: Int,
                newStart: Int,
                newLines: Int,
                lines: [String],
                lineDelimiters: [String] = []
            ) {
                self.oldStart = oldStart
                self.oldLines = oldLines
                self.newStart = newStart
                self.newLines = newLines
                self.lines = lines
                self.lineDelimiters = lineDelimiters
            }
        }

        public struct StructuredPatch: Equatable, Hashable, Sendable {
            public var oldFileName: String?
            public var newFileName: String?
            public var hunks: [Hunk]

            public init(oldFileName: String? = nil, newFileName: String? = nil, hunks: [Hunk] = []) {
                self.oldFileName = oldFileName
                self.newFileName = newFileName
                self.hunks = hunks
            }

            public var rangesSignature: String {
                hunks.map { "\($0.oldStart),\($0.oldLines),\($0.newStart),\($0.newLines)" }.joined(separator: " ")
            }
        }

        public static func parsePatch(_ uniDiff: String) -> [StructuredPatch] {
            let rawLines = splitLinesKeepingDelimiters(uniDiff)
            var patches: [StructuredPatch] = []
            var i = 0

            while i < rawLines.count {
                var oldFile: String? = nil
                var newFile: String? = nil
                var hunks: [Hunk] = []

                while i < rawLines.count {
                    let line = rawLines[i].text
                    if line.hasPrefix("@@ ") { break }
                    if line.hasPrefix("--- ") {
                        oldFile = String(line.dropFirst(4)).split(separator: "\t", maxSplits: 1).first.map(String.init)
                    } else if line.hasPrefix("+++ ") {
                        newFile = String(line.dropFirst(4)).split(separator: "\t", maxSplits: 1).first.map(String.init)
                    }
                    i += 1
                }

                while i < rawLines.count && rawLines[i].text.hasPrefix("@@ ") {
                    guard let header = parseHunkHeader(rawLines[i].text) else {
                        i += 1
                        continue
                    }
                    i += 1
                    var lines: [String] = []
                    var delims: [String] = []
                    var oldCount = 0
                    var newCount = 0
                    while i < rawLines.count {
                        let entry = rawLines[i]
                        let t = entry.text
                        if t.hasPrefix("@@ ") || t.hasPrefix("--- ") || t.hasPrefix("diff ") || t.hasPrefix("Index: ") {
                            break
                        }
                        if t.hasPrefix("\\") {
                            lines.append(t)
                            delims.append(entry.delimiter)
                            i += 1
                            continue
                        }
                        if oldCount >= header.oldLines && newCount >= header.newLines {
                            break
                        }
                        if t.hasPrefix(" ") {
                            lines.append(t)
                            delims.append(entry.delimiter)
                            oldCount += 1
                            newCount += 1
                            i += 1
                        } else if t.hasPrefix("-") {
                            lines.append(t)
                            delims.append(entry.delimiter)
                            oldCount += 1
                            i += 1
                        } else if t.hasPrefix("+") {
                            lines.append(t)
                            delims.append(entry.delimiter)
                            newCount += 1
                            i += 1
                        } else if t.isEmpty {
                            lines.append(" ")
                            delims.append(entry.delimiter)
                            oldCount += 1
                            newCount += 1
                            i += 1
                        } else {
                            break
                        }
                    }
                    hunks.append(
                        Hunk(
                            oldStart: header.oldStart,
                            oldLines: header.oldLines,
                            newStart: header.newStart,
                            newLines: header.newLines,
                            lines: lines,
                            lineDelimiters: delims
                        )
                    )
                }

                if oldFile != nil || newFile != nil || !hunks.isEmpty {
                    patches.append(StructuredPatch(oldFileName: oldFile, newFileName: newFile, hunks: hunks))
                } else {
                    i += 1
                }
            }

            return patches
        }

        public static func reversePatch(_ patch: StructuredPatch) -> StructuredPatch {
            let reversedHunks = patch.hunks.map { hunk -> Hunk in
                var newLines: [String] = []
                var newDelims: [String] = []

                // Flip '-' <-> '+' while keeping any '\ No newline at end of file' attached to its owning block.
                var idx = 0
                while idx < hunk.lines.count {
                    let line = hunk.lines[idx]
                    let delim = idx < hunk.lineDelimiters.count ? hunk.lineDelimiters[idx] : "\n"
                    if line.hasPrefix(" ") {
                        newLines.append(line)
                        newDelims.append(delim)
                        idx += 1
                    } else if line.hasPrefix("-") || line.hasPrefix("+") {
                        var removed: [(String, String)] = []
                        var added: [(String, String)] = []
                        while idx < hunk.lines.count {
                            let cur = hunk.lines[idx]
                            let curD = idx < hunk.lineDelimiters.count ? hunk.lineDelimiters[idx] : "\n"
                            if cur.hasPrefix("-") {
                                removed.append(("+" + cur.dropFirst(), curD))
                                idx += 1
                                if idx < hunk.lines.count && hunk.lines[idx].hasPrefix("\\") {
                                    let nlD = idx < hunk.lineDelimiters.count ? hunk.lineDelimiters[idx] : "\n"
                                    removed.append((hunk.lines[idx], nlD))
                                    idx += 1
                                }
                            } else if cur.hasPrefix("+") {
                                added.append(("-" + cur.dropFirst(), curD))
                                idx += 1
                                if idx < hunk.lines.count && hunk.lines[idx].hasPrefix("\\") {
                                    let nlD = idx < hunk.lineDelimiters.count ? hunk.lineDelimiters[idx] : "\n"
                                    added.append((hunk.lines[idx], nlD))
                                    idx += 1
                                }
                            } else {
                                break
                            }
                        }
                        // In unified diffs removals come before additions.
                        for (l, d) in added {
                            newLines.append(l)
                            newDelims.append(d)
                        }
                        for (l, d) in removed {
                            newLines.append(l)
                            newDelims.append(d)
                        }
                    } else {
                        newLines.append(line)
                        newDelims.append(delim)
                        idx += 1
                    }
                }
                return Hunk(
                    oldStart: hunk.newStart,
                    oldLines: hunk.newLines,
                    newStart: hunk.oldStart,
                    newLines: hunk.oldLines,
                    lines: newLines,
                    lineDelimiters: newDelims
                )
            }
            return StructuredPatch(
                oldFileName: patch.newFileName,
                newFileName: patch.oldFileName,
                hunks: reversedHunks
            )
        }

        public static func applyPatch(_ source: String, _ patchText: String) -> String? {
            guard let first = parsePatch(patchText).first else { return nil }
            return applyPatch(source, first)
        }

        public static func applyPatch(_ source: String, _ patch: StructuredPatch) -> String? {
            if patch.hunks.isEmpty { return source }
            var entries = splitFileLines(source)
            let defaultNewline = entries.first(where: { !$0.delimiter.isEmpty })?.delimiter ?? "\n"
            var delta = 0

            for hunk in patch.hunks {
                // Collect expected old lines and replacement new lines.
                var oldEntries: [(text: String, noNewline: Bool)] = []
                var newEntries: [(text: String, delim: String, noNewline: Bool)] = []
                var i = 0
                while i < hunk.lines.count {
                    let line = hunk.lines[i]
                    let rawDelim = i < hunk.lineDelimiters.count ? hunk.lineDelimiters[i] : ""
                    let nextIsNoNewline = (i + 1 < hunk.lines.count) && hunk.lines[i + 1].hasPrefix("\\")
                    if line.hasPrefix(" ") {
                        let body = String(line.dropFirst())
                        oldEntries.append((body, nextIsNoNewline))
                        newEntries.append((body, rawDelim.isEmpty ? defaultNewline : rawDelim, nextIsNoNewline))
                        i += nextIsNoNewline ? 2 : 1
                    } else if line.hasPrefix("-") {
                        let body = String(line.dropFirst())
                        oldEntries.append((body, nextIsNoNewline))
                        i += nextIsNoNewline ? 2 : 1
                    } else if line.hasPrefix("+") {
                        let body = String(line.dropFirst())
                        newEntries.append((body, rawDelim.isEmpty ? defaultNewline : rawDelim, nextIsNoNewline))
                        i += nextIsNoNewline ? 2 : 1
                    } else {
                        i += 1
                    }
                }

                if oldEntries.isEmpty {
                    let insertPos = max(0, min(entries.count, (hunk.oldStart == 0 ? 0 : hunk.oldStart - 1) + delta))
                    let inserted = newEntries.map { item in
                        LineEntry(text: item.text, delimiter: item.noNewline ? "" : item.delim)
                    }
                    entries.insert(contentsOf: inserted, at: insertPos)
                    delta += inserted.count
                    continue
                }

                let preferred = max(0, hunk.oldStart - 1 + delta)
                guard let matchPos = findHunkPosition(entries: entries, expected: oldEntries, preferred: preferred) else {
                    return nil
                }

                // Preserve existing delimiter style on unchanged context lines and infer for added lines.
                let inferredDelim = (matchPos < entries.count && !entries[matchPos].delimiter.isEmpty)
                    ? entries[matchPos].delimiter
                    : defaultNewline
                let replacement = newEntries.map { item -> LineEntry in
                    let delim: String
                    if item.noNewline {
                        delim = ""
                    } else if item.delim == "\r\n" || item.delim == "\n" {
                        delim = inferredDelim == "\r\n" ? "\r\n" : item.delim
                    } else {
                        delim = inferredDelim
                    }
                    return LineEntry(text: item.text, delimiter: delim)
                }
                entries.replaceSubrange(matchPos..<(matchPos + oldEntries.count), with: replacement)
                delta += replacement.count - oldEntries.count
            }

            return entries.map { $0.text + $0.delimiter }.joined()
        }

        public static func structuredPatch(
            oldFileName: String,
            newFileName: String,
            oldStr: String,
            newStr: String,
            context: Int = 4
        ) -> StructuredPatch {
            let oldLines = splitFileLines(oldStr)
            let newLines = splitFileLines(newStr)
            let ops = computeLineDiff(old: oldLines, new: newLines)
            if !ops.contains(where: { $0.kind != .equal }) {
                return StructuredPatch(oldFileName: oldFileName, newFileName: newFileName, hunks: [])
            }

            // Identify indices of changed ops and merge nearby hunks separated by <= 2 * context equal lines.
            var ranges: [(start: Int, end: Int)] = []
            var idx = 0
            while idx < ops.count {
                if ops[idx].kind == .equal {
                    idx += 1
                    continue
                }
                let start = max(0, idx - context)
                var end = idx + 1
                while end < ops.count {
                    if ops[end].kind != .equal {
                        end += 1
                    } else {
                        var eqRun = 0
                        while end + eqRun < ops.count && ops[end + eqRun].kind == .equal {
                            eqRun += 1
                        }
                        if end + eqRun < ops.count && eqRun <= context * 2 {
                            end += eqRun
                        } else {
                            end = min(ops.count, end + context)
                            break
                        }
                    }
                }
                ranges.append((start, end))
                idx = end
            }

            var hunks: [Hunk] = []
            for r in ranges {
                var oldLineNum = 1
                var newLineNum = 1
                for k in 0..<r.start {
                    switch ops[k].kind {
                    case .equal:
                        oldLineNum += 1
                        newLineNum += 1
                    case .delete:
                        oldLineNum += 1
                    case .insert:
                        newLineNum += 1
                    }
                }
                var oldCount = 0
                var newCount = 0
                var lines: [String] = []
                var delims: [String] = []
                for k in r.start..<r.end {
                    let op = ops[k]
                    switch op.kind {
                    case .equal:
                        lines.append(" " + op.entry.text)
                        delims.append(op.entry.delimiter.isEmpty ? "\n" : op.entry.delimiter)
                        if op.entry.delimiter.isEmpty {
                            lines.append("\\ No newline at end of file")
                            delims.append("\n")
                        }
                        oldCount += 1
                        newCount += 1
                    case .delete:
                        lines.append("-" + op.entry.text)
                        delims.append(op.entry.delimiter.isEmpty ? "\n" : op.entry.delimiter)
                        if op.entry.delimiter.isEmpty {
                            lines.append("\\ No newline at end of file")
                            delims.append("\n")
                        }
                        oldCount += 1
                    case .insert:
                        lines.append("+" + op.entry.text)
                        delims.append(op.entry.delimiter.isEmpty ? "\n" : op.entry.delimiter)
                        if op.entry.delimiter.isEmpty {
                            lines.append("\\ No newline at end of file")
                            delims.append("\n")
                        }
                        newCount += 1
                    }
                }
                let oldStart = oldCount == 0 ? max(0, oldLineNum - 1) : oldLineNum
                let newStart = newCount == 0 ? max(0, newLineNum - 1) : newLineNum
                hunks.append(
                    Hunk(
                        oldStart: oldStart,
                        oldLines: oldCount,
                        newStart: newStart,
                        newLines: newCount,
                        lines: lines,
                        lineDelimiters: delims
                    )
                )
            }
            return StructuredPatch(oldFileName: oldFileName, newFileName: newFileName, hunks: hunks)
        }

        private struct LineEntry: Equatable {
            let text: String
            let delimiter: String
        }

        private enum DiffOpKind {
            case equal
            case delete
            case insert
        }

        private struct DiffOp {
            let kind: DiffOpKind
            let entry: LineEntry
        }

        private static func splitLinesKeepingDelimiters(_ text: String) -> [LineEntry] {
            var out: [LineEntry] = []
            let bytes = Array(text.utf8)
            var start = 0
            var i = 0
            while i < bytes.count {
                if bytes[i] == 0x0A {
                    if i > start && bytes[i - 1] == 0x0D {
                        let line = String(decoding: bytes[start..<(i - 1)], as: UTF8.self)
                        out.append(LineEntry(text: line, delimiter: "\r\n"))
                    } else {
                        let line = String(decoding: bytes[start..<i], as: UTF8.self)
                        out.append(LineEntry(text: line, delimiter: "\n"))
                    }
                    i += 1
                    start = i
                } else {
                    i += 1
                }
            }
            if start < bytes.count {
                out.append(LineEntry(text: String(decoding: bytes[start..<bytes.count], as: UTF8.self), delimiter: ""))
            }
            return out
        }

        private static func splitFileLines(_ text: String) -> [LineEntry] {
            if text.isEmpty { return [] }
            return splitLinesKeepingDelimiters(text)
        }

        private static func parseHunkHeader(_ line: String) -> (oldStart: Int, oldLines: Int, newStart: Int, newLines: Int)? {
            // Format: @@ -oldStart[,oldLines] +newStart[,newLines] @@
            guard line.hasPrefix("@@ -") else { return nil }
            let rest = line.dropFirst(4)
            guard let endIdx = rest.range(of: " @@") else { return nil }
            let headerBody = rest[..<endIdx.lowerBound]
            let parts = headerBody.split(separator: " ")
            guard parts.count == 2, parts[1].hasPrefix("+") else { return nil }
            guard let oldPair = parseRange(String(parts[0])),
                  let newPair = parseRange(String(parts[1].dropFirst()))
            else {
                return nil
            }
            return (oldPair.0, oldPair.1, newPair.0, newPair.1)
        }

        private static func parseRange(_ token: String) -> (Int, Int)? {
            let parts = token.split(separator: ",", maxSplits: 1)
            guard let start = Int(parts[0]) else { return nil }
            let count = parts.count > 1 ? Int(parts[1]) : 1
            guard let count else { return nil }
            return (start, count)
        }

        private static func findHunkPosition(
            entries: [LineEntry],
            expected: [(text: String, noNewline: Bool)],
            preferred: Int
        ) -> Int? {
            guard expected.count <= entries.count else { return nil }
            func matches(at pos: Int) -> Bool {
                guard pos >= 0 && pos + expected.count <= entries.count else { return false }
                for k in 0..<expected.count {
                    if entries[pos + k].text != expected[k].text {
                        return false
                    }
                }
                return true
            }
            if matches(at: preferred) { return preferred }
            let maxOffset = max(preferred, entries.count - expected.count - preferred)
            if maxOffset > 0 {
                for dist in 1...maxOffset {
                    if matches(at: preferred - dist) { return preferred - dist }
                    if matches(at: preferred + dist) { return preferred + dist }
                }
            }
            return nil
        }

        private static func computeLineDiff(old: [LineEntry], new: [LineEntry]) -> [DiffOp] {
            // Standard LCS DP over lines (sufficient and exact for source file diffs).
            let m = old.count
            let n = new.count
            var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
            if m > 0 && n > 0 {
                for i in stride(from: m - 1, through: 0, by: -1) {
                    for j in stride(from: n - 1, through: 0, by: -1) {
                        if old[i] == new[j] {
                            dp[i][j] = dp[i + 1][j + 1] + 1
                        } else {
                            dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
                        }
                    }
                }
            }
            var ops: [DiffOp] = []
            var i = 0
            var j = 0
            while i < m && j < n {
                if old[i] == new[j] {
                    ops.append(DiffOp(kind: .equal, entry: old[i]))
                    i += 1
                    j += 1
                } else if dp[i + 1][j] >= dp[i][j + 1] {
                    ops.append(DiffOp(kind: .delete, entry: old[i]))
                    i += 1
                } else {
                    ops.append(DiffOp(kind: .insert, entry: new[j]))
                    j += 1
                }
            }
            while i < m {
                ops.append(DiffOp(kind: .delete, entry: old[i]))
                i += 1
            }
            while j < n {
                ops.append(DiffOp(kind: .insert, entry: new[j]))
                j += 1
            }
            return ops
        }
    }
}
