import OpenCodeSchema

/// Common protocol conformed to by every tagged HTTP API error in `OpenCodeProtocol`.
public protocol ProtocolError: Error, Equatable, Hashable, Sendable, Codable {
    /// Exact upstream Effect `Schema.TaggedError` `_tag` wire discriminator.
    static var tag: String { get }
    /// Exact upstream HTTP status code (`httpApiStatus`).
    static var httpStatusCode: Int { get }
    /// Human-readable error message.
    var message: String { get }
}

/// Lightweight type-erased reference to a tagged protocol error and its HTTP status code.
public struct ProtocolErrorRef: Equatable, Hashable, Sendable, Codable {
    public let tag: String
    public let httpStatusCode: Int

    public init(tag: String, httpStatusCode: Int) {
        self.tag = tag
        self.httpStatusCode = httpStatusCode
    }

    public init<E: ProtocolError>(_ errorType: E.Type) {
        self.tag = E.tag
        self.httpStatusCode = E.httpStatusCode
    }
}

/// Internal error category for `RpcInternalError`.
public enum RpcInternalErrorType: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case rpcInternal = "rpc.internal"
    case rpcInvalidOutput = "rpc.invalid_output"
}

/// Failure category for `ProviderRequestError`.
public enum ProviderRequestErrorReason: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case authentication
    case rateLimit = "rate_limit"
    case contentFilter = "content_filter"
    case invalidRequest = "invalid_request"
    case overloaded
    case provider
}

internal func validateErrorTag<K: CodingKey>(
    _ expected: String,
    in container: KeyedDecodingContainer<K>,
    key: K
) throws {
    let actual = try container.decode(String.self, forKey: key)
    guard actual == expected else {
        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: container,
            debugDescription: "Expected _tag '\(expected)', got '\(actual)'"
        )
    }
}

// MARK: - Tagged HTTP API Errors (packages/protocol/src/errors.ts — 40 symbols)

// parity: protocol/src/errors.ts#LocationNotFoundError [status=implemented hash=c066da9fc971]
public struct LocationNotFoundError: ProtocolError {
    public static let tag = "LocationNotFoundError"
    public static let httpStatusCode = 404

    public let location: OpenCodeLocation
    public let message: String

    public init(location: OpenCodeLocation, message: String) {
        self.location = location
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, location, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.location = try c.decode(OpenCodeLocation.self, forKey: .location)
        self.message = try c.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(location, forKey: .location)
        try c.encode(message, forKey: .message)
    }
}

// parity: protocol/src/errors.ts#InvalidRequestError [status=implemented hash=9e1cc28f39a1]
public struct InvalidRequestError: ProtocolError {
    public static let tag = "InvalidRequestError"
    public static let httpStatusCode = 400

    public let message: String
    public let kind: String?
    public let field: String?

    public init(message: String, kind: String? = nil, field: String? = nil) {
        self.message = message
        self.kind = kind
        self.field = field
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, message, kind, field
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.message = try c.decode(String.self, forKey: .message)
        self.kind = try c.decodeIfPresent(String.self, forKey: .kind)
        self.field = try c.decodeIfPresent(String.self, forKey: .field)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(message, forKey: .message)
        try c.encodeIfPresent(kind, forKey: .kind)
        try c.encodeIfPresent(field, forKey: .field)
    }
}

// parity: protocol/src/errors.ts#RpcError [status=implemented hash=68a574f0c86c]
public struct RpcError: ProtocolError {
    public static let tag = "RpcError"
    public static let httpStatusCode = 400

    public let type: String
    public let message: String
    public let data: JSONValue?

    public init(type: String, message: String, data: JSONValue? = nil) {
        self.type = type
        self.message = message
        self.data = data
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, type, message, data
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.type = try c.decode(String.self, forKey: .type)
        self.message = try c.decode(String.self, forKey: .message)
        self.data = try c.decodeIfPresent(JSONValue.self, forKey: .data)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(type, forKey: .type)
        try c.encode(message, forKey: .message)
        try c.encodeIfPresent(data, forKey: .data)
    }
}

// parity: protocol/src/errors.ts#RpcInternalError [status=implemented hash=1de980b22a52]
public struct RpcInternalError: ProtocolError {
    public static let tag = "RpcInternalError"
    public static let httpStatusCode = 500

    public let type: RpcInternalErrorType
    public let message: String
    public let data: JSONValue?

    public init(type: RpcInternalErrorType, message: String, data: JSONValue? = nil) {
        self.type = type
        self.message = message
        self.data = data
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, type, message, data
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.type = try c.decode(RpcInternalErrorType.self, forKey: .type)
        self.message = try c.decode(String.self, forKey: .message)
        self.data = try c.decodeIfPresent(JSONValue.self, forKey: .data)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(type, forKey: .type)
        try c.encode(message, forKey: .message)
        try c.encodeIfPresent(data, forKey: .data)
    }
}

// parity: protocol/src/errors.ts#UnauthorizedError [status=implemented hash=80c0f4b281f5]
public struct UnauthorizedError: ProtocolError {
    public static let tag = "UnauthorizedError"
    public static let httpStatusCode = 401

    public let message: String

    public init(message: String) {
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.message = try c.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(message, forKey: .message)
    }
}

// parity: protocol/src/errors.ts#ConflictError [status=implemented hash=e2020bfe2790]
public struct ConflictError: ProtocolError {
    public static let tag = "ConflictError"
    public static let httpStatusCode = 409

    public let message: String
    public let resource: String?

    public init(message: String, resource: String? = nil) {
        self.message = message
        self.resource = resource
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, message, resource
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.message = try c.decode(String.self, forKey: .message)
        self.resource = try c.decodeIfPresent(String.self, forKey: .resource)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(message, forKey: .message)
        try c.encodeIfPresent(resource, forKey: .resource)
    }
}

// parity: protocol/src/errors.ts#SessionBusyError [status=implemented hash=1aa00e00b672]
public struct SessionBusyError: ProtocolError {
    public static let tag = "SessionBusyError"
    public static let httpStatusCode = 409

    public let sessionID: String
    public let message: String

    public init(sessionID: String, message: String) {
        self.sessionID = sessionID
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, sessionID, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.sessionID = try c.decode(String.self, forKey: .sessionID)
        self.message = try c.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(sessionID, forKey: .sessionID)
        try c.encode(message, forKey: .message)
    }
}

// parity: protocol/src/errors.ts#ServiceUnavailableError [status=implemented hash=2140743074b0]
public struct ServiceUnavailableError: ProtocolError {
    public static let tag = "ServiceUnavailableError"
    public static let httpStatusCode = 503

    public let message: String
    public let service: String?

    public init(message: String, service: String? = nil) {
        self.message = message
        self.service = service
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, message, service
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.message = try c.decode(String.self, forKey: .message)
        self.service = try c.decodeIfPresent(String.self, forKey: .service)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(message, forKey: .message)
        try c.encodeIfPresent(service, forKey: .service)
    }
}

// parity: protocol/src/errors.ts#UnknownError [status=implemented hash=0c4736016759]
public struct UnknownError: ProtocolError {
    public static let tag = "UnknownError"
    public static let httpStatusCode = 500

    public let message: String
    public let ref: String?

    public init(message: String, ref: String? = nil) {
        self.message = message
        self.ref = ref
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, message, ref
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.message = try c.decode(String.self, forKey: .message)
        self.ref = try c.decodeIfPresent(String.self, forKey: .ref)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(message, forKey: .message)
        try c.encodeIfPresent(ref, forKey: .ref)
    }
}

// parity: protocol/src/errors.ts#ProviderNotFoundError [status=implemented hash=91c064d9c45e]
public struct ProviderNotFoundError: ProtocolError {
    public static let tag = "ProviderNotFoundError"
    public static let httpStatusCode = 404

    public let providerID: String
    public let message: String

    public init(providerID: String, message: String) {
        self.providerID = providerID
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, providerID, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.providerID = try c.decode(String.self, forKey: .providerID)
        self.message = try c.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(providerID, forKey: .providerID)
        try c.encode(message, forKey: .message)
    }
}

// parity: protocol/src/errors.ts#IntegrationNotFoundError [status=implemented hash=dc36fa38eb49]
public struct IntegrationNotFoundError: ProtocolError {
    public static let tag = "IntegrationNotFoundError"
    public static let httpStatusCode = 404

    public let integrationID: String
    public let message: String

    public init(integrationID: String, message: String) {
        self.integrationID = integrationID
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, integrationID, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.integrationID = try c.decode(String.self, forKey: .integrationID)
        self.message = try c.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(integrationID, forKey: .integrationID)
        try c.encode(message, forKey: .message)
    }
}

// parity: protocol/src/errors.ts#IntegrationAttemptNotFoundError [status=implemented hash=9eda2f8edb97]
public struct IntegrationAttemptNotFoundError: ProtocolError {
    public static let tag = "IntegrationAttemptNotFoundError"
    public static let httpStatusCode = 404

    public let integrationID: String
    public let attemptID: String
    public let message: String

    public init(integrationID: String, attemptID: String, message: String) {
        self.integrationID = integrationID
        self.attemptID = attemptID
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, integrationID, attemptID, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.integrationID = try c.decode(String.self, forKey: .integrationID)
        self.attemptID = try c.decode(String.self, forKey: .attemptID)
        self.message = try c.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(integrationID, forKey: .integrationID)
        try c.encode(attemptID, forKey: .attemptID)
        try c.encode(message, forKey: .message)
    }
}

// parity: protocol/src/errors.ts#IntegrationMethodNotFoundError [status=implemented hash=9d96d926ced1]
public struct IntegrationMethodNotFoundError: ProtocolError {
    public static let tag = "IntegrationMethodNotFoundError"
    public static let httpStatusCode = 404

    public let integrationID: String
    public let methodID: String
    public let message: String

    public init(integrationID: String, methodID: String, message: String) {
        self.integrationID = integrationID
        self.methodID = methodID
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, integrationID, methodID, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.integrationID = try c.decode(String.self, forKey: .integrationID)
        self.methodID = try c.decode(String.self, forKey: .methodID)
        self.message = try c.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(integrationID, forKey: .integrationID)
        try c.encode(methodID, forKey: .methodID)
        try c.encode(message, forKey: .message)
    }
}

// parity: protocol/src/errors.ts#ProjectNotFoundError [status=implemented hash=b2eb564267f6]
public struct ProjectNotFoundError: ProtocolError {
    public static let tag = "ProjectNotFoundError"
    public static let httpStatusCode = 404

    public let projectID: String
    public let message: String

    public init(projectID: String, message: String) {
        self.projectID = projectID
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, projectID, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.projectID = try c.decode(String.self, forKey: .projectID)
        self.message = try c.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(projectID, forKey: .projectID)
        try c.encode(message, forKey: .message)
    }
}

// parity: protocol/src/errors.ts#FileNotFoundError [status=implemented hash=96768fabbee8]
public struct FileNotFoundError: ProtocolError {
    public static let tag = "FileNotFoundError"
    public static let httpStatusCode = 404

    public let path: String
    public let message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, path, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.path = try c.decode(String.self, forKey: .path)
        self.message = try c.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(path, forKey: .path)
        try c.encode(message, forKey: .message)
    }
}

// parity: protocol/src/errors.ts#PluginNotFoundError [status=implemented hash=4e5d4002cad1]
public struct PluginNotFoundError: ProtocolError {
    public static let tag = "PluginNotFoundError"
    public static let httpStatusCode = 404

    public let pluginID: String
    public let message: String

    public init(pluginID: String, message: String) {
        self.pluginID = pluginID
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, pluginID, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.pluginID = try c.decode(String.self, forKey: .pluginID)
        self.message = try c.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(pluginID, forKey: .pluginID)
        try c.encode(message, forKey: .message)
    }
}

// parity: protocol/src/errors.ts#AgentNotFoundError [status=implemented hash=f428fcb94a57]
public struct AgentNotFoundError: ProtocolError {
    public static let tag = "AgentNotFoundError"
    public static let httpStatusCode = 404

    public let agentID: String
    public let message: String

    public init(agentID: String, message: String) {
        self.agentID = agentID
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, agentID, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.agentID = try c.decode(String.self, forKey: .agentID)
        self.message = try c.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(agentID, forKey: .agentID)
        try c.encode(message, forKey: .message)
    }
}

// parity: protocol/src/errors.ts#SessionNotFoundError [status=implemented hash=1247560e4bd3]
public struct SessionNotFoundError: ProtocolError {
    public static let tag = "SessionNotFoundError"
    public static let httpStatusCode = 404

    public let sessionID: String
    public let message: String

    public init(sessionID: String, message: String) {
        self.sessionID = sessionID
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, sessionID, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.sessionID = try c.decode(String.self, forKey: .sessionID)
        self.message = try c.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(sessionID, forKey: .sessionID)
        try c.encode(message, forKey: .message)
    }
}

// parity: protocol/src/errors.ts#MessageNotFoundError [status=implemented hash=dc9a77e55dd7]
public struct MessageNotFoundError: ProtocolError {
    public static let tag = "MessageNotFoundError"
    public static let httpStatusCode = 404

    public let sessionID: String
    public let messageID: String
    public let message: String

    public init(sessionID: String, messageID: String, message: String) {
        self.sessionID = sessionID
        self.messageID = messageID
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, sessionID, messageID, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.sessionID = try c.decode(String.self, forKey: .sessionID)
        self.messageID = try c.decode(String.self, forKey: .messageID)
        self.message = try c.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(sessionID, forKey: .sessionID)
        try c.encode(messageID, forKey: .messageID)
        try c.encode(message, forKey: .message)
    }
}

// parity: protocol/src/errors.ts#SkillNotFoundError [status=implemented hash=ed449b37e962]
public struct SkillNotFoundError: ProtocolError {
    public static let tag = "SkillNotFoundError"
    public static let httpStatusCode = 404

    public let skill: String
    public let message: String

    public init(skill: String, message: String) {
        self.skill = skill
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, skill, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.skill = try c.decode(String.self, forKey: .skill)
        self.message = try c.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(skill, forKey: .skill)
        try c.encode(message, forKey: .message)
    }
}

// parity: protocol/src/errors.ts#McpServerNotFoundError [status=implemented hash=6be6d1f8bbc0]
public struct McpServerNotFoundError: ProtocolError {
    public static let tag = "McpServerNotFoundError"
    public static let httpStatusCode = 404

    public let server: String
    public let message: String

    public init(server: String, message: String) {
        self.server = server
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, server, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.server = try c.decode(String.self, forKey: .server)
        self.message = try c.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(server, forKey: .server)
        try c.encode(message, forKey: .message)
    }
}

// parity: protocol/src/errors.ts#CommandNotFoundError [status=implemented hash=a19e2bc52f6e]
public struct CommandNotFoundError: ProtocolError {
    public static let tag = "CommandNotFoundError"
    public static let httpStatusCode = 404

    public let command: String
    public let message: String

    public init(command: String, message: String) {
        self.command = command
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, command, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.command = try c.decode(String.self, forKey: .command)
        self.message = try c.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(command, forKey: .command)
        try c.encode(message, forKey: .message)
    }
}

// parity: protocol/src/errors.ts#CommandExecutionError [status=implemented hash=846325f446fc]
public struct CommandExecutionError: ProtocolError {
    public static let tag = "CommandExecutionError"
    public static let httpStatusCode = 500

    public let command: String
    public let message: String

    public init(command: String, message: String) {
        self.command = command
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, command, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.command = try c.decode(String.self, forKey: .command)
        self.message = try c.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(command, forKey: .command)
        try c.encode(message, forKey: .message)
    }
}

// parity: protocol/src/errors.ts#InvalidCursorError [status=implemented hash=cfbca08a195d]
public struct InvalidCursorError: ProtocolError {
    public static let tag = "InvalidCursorError"
    public static let httpStatusCode = 400

    public let message: String

    public init(message: String) {
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.message = try c.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(message, forKey: .message)
    }
}

// parity: protocol/src/errors.ts#PermissionNotFoundError [status=implemented hash=30b726ae53d4]
public struct PermissionNotFoundError: ProtocolError {
    public static let tag = "PermissionNotFoundError"
    public static let httpStatusCode = 404

    public let requestID: String
    public let message: String

    public init(requestID: String, message: String) {
        self.requestID = requestID
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, requestID, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.requestID = try c.decode(String.self, forKey: .requestID)
        self.message = try c.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(requestID, forKey: .requestID)
        try c.encode(message, forKey: .message)
    }
}

// parity: protocol/src/errors.ts#PermissionSavedNotFoundError [status=implemented hash=e73f50c9c687]
public struct PermissionSavedNotFoundError: ProtocolError {
    public static let tag = "PermissionSavedNotFoundError"
    public static let httpStatusCode = 404

    public let id: String
    public let message: String

    public init(id: String, message: String) {
        self.id = id
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, id, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.id = try c.decode(String.self, forKey: .id)
        self.message = try c.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(id, forKey: .id)
        try c.encode(message, forKey: .message)
    }
}

// parity: protocol/src/errors.ts#FormNotFoundError [status=implemented hash=9b40047cf073]
public struct FormNotFoundError: ProtocolError {
    public static let tag = "FormNotFoundError"
    public static let httpStatusCode = 404

    public let id: String
    public let message: String

    public init(id: String, message: String) {
        self.id = id
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, id, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.id = try c.decode(String.self, forKey: .id)
        self.message = try c.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(id, forKey: .id)
        try c.encode(message, forKey: .message)
    }
}

// parity: protocol/src/errors.ts#FormAlreadySettledError [status=implemented hash=c18ec82840b9]
public struct FormAlreadySettledError: ProtocolError {
    public static let tag = "FormAlreadySettledError"
    public static let httpStatusCode = 409

    public let id: String
    public let message: String

    public init(id: String, message: String) {
        self.id = id
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, id, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.id = try c.decode(String.self, forKey: .id)
        self.message = try c.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(id, forKey: .id)
        try c.encode(message, forKey: .message)
    }
}

// parity: protocol/src/errors.ts#FormInvalidAnswerError [status=implemented hash=834434537f1d]
public struct FormInvalidAnswerError: ProtocolError {
    public static let tag = "FormInvalidAnswerError"
    public static let httpStatusCode = 400

    public let id: String
    public let message: String

    public init(id: String, message: String) {
        self.id = id
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, id, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.id = try c.decode(String.self, forKey: .id)
        self.message = try c.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(id, forKey: .id)
        try c.encode(message, forKey: .message)
    }
}

// parity: protocol/src/errors.ts#ForbiddenError [status=implemented hash=cf5b3130c398]
public struct ForbiddenError: ProtocolError {
    public static let tag = "ForbiddenError"
    public static let httpStatusCode = 403

    public let message: String

    public init(message: String) {
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.message = try c.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(message, forKey: .message)
    }
}

// parity: protocol/src/errors.ts#PtyNotFoundError [status=implemented hash=367c0cb482da]
public struct PtyNotFoundError: ProtocolError {
    public static let tag = "PtyNotFoundError"
    public static let httpStatusCode = 404

    public let ptyID: String
    public let message: String

    public init(ptyID: String, message: String) {
        self.ptyID = ptyID
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, ptyID, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.ptyID = try c.decode(String.self, forKey: .ptyID)
        self.message = try c.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(ptyID, forKey: .ptyID)
        try c.encode(message, forKey: .message)
    }
}

// parity: protocol/src/errors.ts#PtyFeatureUnsupportedError [status=implemented hash=f036d2ae797d]
public struct PtyFeatureUnsupportedError: ProtocolError {
    public static let tag = "PtyFeatureUnsupportedError"
    public static let httpStatusCode = 501

    public let feature: String
    public let message: String

    public init(feature: String, message: String) {
        self.feature = feature
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, feature, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.feature = try c.decode(String.self, forKey: .feature)
        self.message = try c.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(feature, forKey: .feature)
        try c.encode(message, forKey: .message)
    }
}

// parity: protocol/src/errors.ts#ShellNotFoundError [status=implemented hash=21f93e5be356]
public struct ShellNotFoundError: ProtocolError {
    public static let tag = "ShellNotFoundError"
    public static let httpStatusCode = 404

    public let id: String
    public let message: String

    public init(id: String, message: String) {
        self.id = id
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, id, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.id = try c.decode(String.self, forKey: .id)
        self.message = try c.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(id, forKey: .id)
        try c.encode(message, forKey: .message)
    }
}

// parity: protocol/src/errors.ts#ModelNotFoundError [status=implemented hash=5c68fde6d33e]
public struct ModelNotFoundError: ProtocolError {
    public static let tag = "ModelNotFoundError"
    public static let httpStatusCode = 404

    public let providerID: String
    public let modelID: String
    public let message: String

    public init(providerID: String, modelID: String, message: String) {
        self.providerID = providerID
        self.modelID = modelID
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, providerID, modelID, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.providerID = try c.decode(String.self, forKey: .providerID)
        self.modelID = try c.decode(String.self, forKey: .modelID)
        self.message = try c.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(providerID, forKey: .providerID)
        try c.encode(modelID, forKey: .modelID)
        try c.encode(message, forKey: .message)
    }
}

/// The model exists but cannot serve this request, such as a chat model asked for images.
// parity: protocol/src/errors.ts#UnsupportedModelError [status=implemented hash=94a88acac9bf]
public struct UnsupportedModelError: ProtocolError {
    public static let tag = "UnsupportedModelError"
    public static let httpStatusCode = 422

    public let providerID: String
    public let modelID: String
    public let capability: String
    public let message: String

    public init(providerID: String, modelID: String, capability: String, message: String) {
        self.providerID = providerID
        self.modelID = modelID
        self.capability = capability
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, providerID, modelID, capability, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.providerID = try c.decode(String.self, forKey: .providerID)
        self.modelID = try c.decode(String.self, forKey: .modelID)
        self.capability = try c.decode(String.self, forKey: .capability)
        self.message = try c.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(providerID, forKey: .providerID)
        try c.encode(modelID, forKey: .modelID)
        try c.encode(capability, forKey: .capability)
        try c.encode(message, forKey: .message)
    }
}

/// The provider rejected or failed the request after the server sent it.
// parity: protocol/src/errors.ts#ProviderRequestError [status=implemented hash=2bdde19be966]
public struct ProviderRequestError: ProtocolError {
    public static let tag = "ProviderRequestError"
    public static let httpStatusCode = 502

    public let providerID: String
    public let reason: ProviderRequestErrorReason
    public let message: String
    public let status: Int?
    public let retryAfterMs: Int?

    public init(
        providerID: String,
        reason: ProviderRequestErrorReason,
        message: String,
        status: Int? = nil,
        retryAfterMs: Int? = nil
    ) {
        self.providerID = providerID
        self.reason = reason
        self.message = message
        self.status = status
        self.retryAfterMs = retryAfterMs
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, providerID, reason, message, status, retryAfterMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.providerID = try c.decode(String.self, forKey: .providerID)
        self.reason = try c.decode(ProviderRequestErrorReason.self, forKey: .reason)
        self.message = try c.decode(String.self, forKey: .message)
        self.status = try c.decodeIfPresent(Int.self, forKey: .status)
        self.retryAfterMs = try c.decodeIfPresent(Int.self, forKey: .retryAfterMs)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(providerID, forKey: .providerID)
        try c.encode(reason, forKey: .reason)
        try c.encode(message, forKey: .message)
        try c.encodeIfPresent(status, forKey: .status)
        try c.encodeIfPresent(retryAfterMs, forKey: .retryAfterMs)
    }
}

// parity: protocol/src/errors.ts#AutomationNotFoundError [status=implemented hash=ffc9a2affb3d]
public struct AutomationNotFoundError: ProtocolError {
    public static let tag = "AutomationNotFoundError"
    public static let httpStatusCode = 404

    public let automationID: String
    public let message: String

    public init(automationID: String, message: String) {
        self.automationID = automationID
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, automationID, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.automationID = try c.decode(String.self, forKey: .automationID)
        self.message = try c.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(automationID, forKey: .automationID)
        try c.encode(message, forKey: .message)
    }
}

// parity: protocol/src/errors.ts#VideoNotFoundError [status=implemented hash=7030c7adf23a]
public struct VideoNotFoundError: ProtocolError {
    public static let tag = "VideoNotFoundError"
    public static let httpStatusCode = 404

    public let videoID: String
    public let message: String

    public init(videoID: String, message: String) {
        self.videoID = videoID
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, videoID, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.videoID = try c.decode(String.self, forKey: .videoID)
        self.message = try c.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(videoID, forKey: .videoID)
        try c.encode(message, forKey: .message)
    }
}

// parity: protocol/src/errors.ts#BlobNotFoundError [status=implemented hash=4c8b6e09ac5b]
public struct BlobNotFoundError: ProtocolError {
    public static let tag = "BlobNotFoundError"
    public static let httpStatusCode = 404

    public let blobID: String
    public let message: String

    public init(blobID: String, message: String) {
        self.blobID = blobID
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, blobID, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.blobID = try c.decode(String.self, forKey: .blobID)
        self.message = try c.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(blobID, forKey: .blobID)
        try c.encode(message, forKey: .message)
    }
}

// parity: protocol/src/errors.ts#ArtifactNotFoundError [status=implemented hash=a8fe4c1d2096]
public struct ArtifactNotFoundError: ProtocolError {
    public static let tag = "ArtifactNotFoundError"
    public static let httpStatusCode = 404

    public let artifactID: String
    public let message: String

    public init(artifactID: String, message: String) {
        self.artifactID = artifactID
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case _tag, artifactID, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try validateErrorTag(Self.tag, in: c, key: ._tag)
        self.artifactID = try c.decode(String.self, forKey: .artifactID)
        self.message = try c.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.tag, forKey: ._tag)
        try c.encode(artifactID, forKey: .artifactID)
        try c.encode(message, forKey: .message)
    }
}

/// Discriminated union of all protocol tagged HTTP API errors for polymorphic wire decoding.
public enum ProtocolErrorEnvelope: Error, Equatable, Hashable, Sendable, Codable {
    case locationNotFound(LocationNotFoundError)
    case invalidRequest(InvalidRequestError)
    case rpc(RpcError)
    case rpcInternal(RpcInternalError)
    case unauthorized(UnauthorizedError)
    case conflict(ConflictError)
    case sessionBusy(SessionBusyError)
    case serviceUnavailable(ServiceUnavailableError)
    case unknown(UnknownError)
    case providerNotFound(ProviderNotFoundError)
    case integrationNotFound(IntegrationNotFoundError)
    case integrationAttemptNotFound(IntegrationAttemptNotFoundError)
    case integrationMethodNotFound(IntegrationMethodNotFoundError)
    case projectNotFound(ProjectNotFoundError)
    case fileNotFound(FileNotFoundError)
    case pluginNotFound(PluginNotFoundError)
    case agentNotFound(AgentNotFoundError)
    case sessionNotFound(SessionNotFoundError)
    case messageNotFound(MessageNotFoundError)
    case skillNotFound(SkillNotFoundError)
    case mcpServerNotFound(McpServerNotFoundError)
    case commandNotFound(CommandNotFoundError)
    case commandExecution(CommandExecutionError)
    case invalidCursor(InvalidCursorError)
    case permissionNotFound(PermissionNotFoundError)
    case permissionSavedNotFound(PermissionSavedNotFoundError)
    case formNotFound(FormNotFoundError)
    case formAlreadySettled(FormAlreadySettledError)
    case formInvalidAnswer(FormInvalidAnswerError)
    case forbidden(ForbiddenError)
    case ptyNotFound(PtyNotFoundError)
    case ptyFeatureUnsupported(PtyFeatureUnsupportedError)
    case shellNotFound(ShellNotFoundError)
    case modelNotFound(ModelNotFoundError)
    case unsupportedModel(UnsupportedModelError)
    case providerRequest(ProviderRequestError)
    case automationNotFound(AutomationNotFoundError)
    case videoNotFound(VideoNotFoundError)
    case blobNotFound(BlobNotFoundError)
    case artifactNotFound(ArtifactNotFoundError)
    case vcsInitNotSupported(VcsInitNotSupportedError)
    case worktree(WorktreeError)

    public var tag: String {
        switch self {
        case .locationNotFound: LocationNotFoundError.tag
        case .invalidRequest: InvalidRequestError.tag
        case .rpc: RpcError.tag
        case .rpcInternal: RpcInternalError.tag
        case .unauthorized: UnauthorizedError.tag
        case .conflict: ConflictError.tag
        case .sessionBusy: SessionBusyError.tag
        case .serviceUnavailable: ServiceUnavailableError.tag
        case .unknown: UnknownError.tag
        case .providerNotFound: ProviderNotFoundError.tag
        case .integrationNotFound: IntegrationNotFoundError.tag
        case .integrationAttemptNotFound: IntegrationAttemptNotFoundError.tag
        case .integrationMethodNotFound: IntegrationMethodNotFoundError.tag
        case .projectNotFound: ProjectNotFoundError.tag
        case .fileNotFound: FileNotFoundError.tag
        case .pluginNotFound: PluginNotFoundError.tag
        case .agentNotFound: AgentNotFoundError.tag
        case .sessionNotFound: SessionNotFoundError.tag
        case .messageNotFound: MessageNotFoundError.tag
        case .skillNotFound: SkillNotFoundError.tag
        case .mcpServerNotFound: McpServerNotFoundError.tag
        case .commandNotFound: CommandNotFoundError.tag
        case .commandExecution: CommandExecutionError.tag
        case .invalidCursor: InvalidCursorError.tag
        case .permissionNotFound: PermissionNotFoundError.tag
        case .permissionSavedNotFound: PermissionSavedNotFoundError.tag
        case .formNotFound: FormNotFoundError.tag
        case .formAlreadySettled: FormAlreadySettledError.tag
        case .formInvalidAnswer: FormInvalidAnswerError.tag
        case .forbidden: ForbiddenError.tag
        case .ptyNotFound: PtyNotFoundError.tag
        case .ptyFeatureUnsupported: PtyFeatureUnsupportedError.tag
        case .shellNotFound: ShellNotFoundError.tag
        case .modelNotFound: ModelNotFoundError.tag
        case .unsupportedModel: UnsupportedModelError.tag
        case .providerRequest: ProviderRequestError.tag
        case .automationNotFound: AutomationNotFoundError.tag
        case .videoNotFound: VideoNotFoundError.tag
        case .blobNotFound: BlobNotFoundError.tag
        case .artifactNotFound: ArtifactNotFoundError.tag
        case .vcsInitNotSupported: VcsInitNotSupportedError.tag
        case .worktree: WorktreeError.tag
        }
    }

    public var httpStatusCode: Int {
        switch self {
        case .locationNotFound: LocationNotFoundError.httpStatusCode
        case .invalidRequest: InvalidRequestError.httpStatusCode
        case .rpc: RpcError.httpStatusCode
        case .rpcInternal: RpcInternalError.httpStatusCode
        case .unauthorized: UnauthorizedError.httpStatusCode
        case .conflict: ConflictError.httpStatusCode
        case .sessionBusy: SessionBusyError.httpStatusCode
        case .serviceUnavailable: ServiceUnavailableError.httpStatusCode
        case .unknown: UnknownError.httpStatusCode
        case .providerNotFound: ProviderNotFoundError.httpStatusCode
        case .integrationNotFound: IntegrationNotFoundError.httpStatusCode
        case .integrationAttemptNotFound: IntegrationAttemptNotFoundError.httpStatusCode
        case .integrationMethodNotFound: IntegrationMethodNotFoundError.httpStatusCode
        case .projectNotFound: ProjectNotFoundError.httpStatusCode
        case .fileNotFound: FileNotFoundError.httpStatusCode
        case .pluginNotFound: PluginNotFoundError.httpStatusCode
        case .agentNotFound: AgentNotFoundError.httpStatusCode
        case .sessionNotFound: SessionNotFoundError.httpStatusCode
        case .messageNotFound: MessageNotFoundError.httpStatusCode
        case .skillNotFound: SkillNotFoundError.httpStatusCode
        case .mcpServerNotFound: McpServerNotFoundError.httpStatusCode
        case .commandNotFound: CommandNotFoundError.httpStatusCode
        case .commandExecution: CommandExecutionError.httpStatusCode
        case .invalidCursor: InvalidCursorError.httpStatusCode
        case .permissionNotFound: PermissionNotFoundError.httpStatusCode
        case .permissionSavedNotFound: PermissionSavedNotFoundError.httpStatusCode
        case .formNotFound: FormNotFoundError.httpStatusCode
        case .formAlreadySettled: FormAlreadySettledError.httpStatusCode
        case .formInvalidAnswer: FormInvalidAnswerError.httpStatusCode
        case .forbidden: ForbiddenError.httpStatusCode
        case .ptyNotFound: PtyNotFoundError.httpStatusCode
        case .ptyFeatureUnsupported: PtyFeatureUnsupportedError.httpStatusCode
        case .shellNotFound: ShellNotFoundError.httpStatusCode
        case .modelNotFound: ModelNotFoundError.httpStatusCode
        case .unsupportedModel: UnsupportedModelError.httpStatusCode
        case .providerRequest: ProviderRequestError.httpStatusCode
        case .automationNotFound: AutomationNotFoundError.httpStatusCode
        case .videoNotFound: VideoNotFoundError.httpStatusCode
        case .blobNotFound: BlobNotFoundError.httpStatusCode
        case .artifactNotFound: ArtifactNotFoundError.httpStatusCode
        case .vcsInitNotSupported: VcsInitNotSupportedError.httpStatusCode
        case .worktree: WorktreeError.httpStatusCode
        }
    }

    public var message: String {
        switch self {
        case .locationNotFound(let e): e.message
        case .invalidRequest(let e): e.message
        case .rpc(let e): e.message
        case .rpcInternal(let e): e.message
        case .unauthorized(let e): e.message
        case .conflict(let e): e.message
        case .sessionBusy(let e): e.message
        case .serviceUnavailable(let e): e.message
        case .unknown(let e): e.message
        case .providerNotFound(let e): e.message
        case .integrationNotFound(let e): e.message
        case .integrationAttemptNotFound(let e): e.message
        case .integrationMethodNotFound(let e): e.message
        case .projectNotFound(let e): e.message
        case .fileNotFound(let e): e.message
        case .pluginNotFound(let e): e.message
        case .agentNotFound(let e): e.message
        case .sessionNotFound(let e): e.message
        case .messageNotFound(let e): e.message
        case .skillNotFound(let e): e.message
        case .mcpServerNotFound(let e): e.message
        case .commandNotFound(let e): e.message
        case .commandExecution(let e): e.message
        case .invalidCursor(let e): e.message
        case .permissionNotFound(let e): e.message
        case .permissionSavedNotFound(let e): e.message
        case .formNotFound(let e): e.message
        case .formAlreadySettled(let e): e.message
        case .formInvalidAnswer(let e): e.message
        case .forbidden(let e): e.message
        case .ptyNotFound(let e): e.message
        case .ptyFeatureUnsupported(let e): e.message
        case .shellNotFound(let e): e.message
        case .modelNotFound(let e): e.message
        case .unsupportedModel(let e): e.message
        case .providerRequest(let e): e.message
        case .automationNotFound(let e): e.message
        case .videoNotFound(let e): e.message
        case .blobNotFound(let e): e.message
        case .artifactNotFound(let e): e.message
        case .vcsInitNotSupported(let e): e.message
        case .worktree(let e): e.message
        }
    }

    private enum TagCodingKeys: String, CodingKey {
        case _tag
    }

    public init(from decoder: Decoder) throws {
        let tagContainer = try decoder.container(keyedBy: TagCodingKeys.self)
        let tag = try tagContainer.decode(String.self, forKey: ._tag)
        switch tag {
        case LocationNotFoundError.tag: self = .locationNotFound(try LocationNotFoundError(from: decoder))
        case InvalidRequestError.tag: self = .invalidRequest(try InvalidRequestError(from: decoder))
        case RpcError.tag: self = .rpc(try RpcError(from: decoder))
        case RpcInternalError.tag: self = .rpcInternal(try RpcInternalError(from: decoder))
        case UnauthorizedError.tag: self = .unauthorized(try UnauthorizedError(from: decoder))
        case ConflictError.tag: self = .conflict(try ConflictError(from: decoder))
        case SessionBusyError.tag: self = .sessionBusy(try SessionBusyError(from: decoder))
        case ServiceUnavailableError.tag: self = .serviceUnavailable(try ServiceUnavailableError(from: decoder))
        case UnknownError.tag: self = .unknown(try UnknownError(from: decoder))
        case ProviderNotFoundError.tag: self = .providerNotFound(try ProviderNotFoundError(from: decoder))
        case IntegrationNotFoundError.tag: self = .integrationNotFound(try IntegrationNotFoundError(from: decoder))
        case IntegrationAttemptNotFoundError.tag: self = .integrationAttemptNotFound(try IntegrationAttemptNotFoundError(from: decoder))
        case IntegrationMethodNotFoundError.tag: self = .integrationMethodNotFound(try IntegrationMethodNotFoundError(from: decoder))
        case ProjectNotFoundError.tag: self = .projectNotFound(try ProjectNotFoundError(from: decoder))
        case FileNotFoundError.tag: self = .fileNotFound(try FileNotFoundError(from: decoder))
        case PluginNotFoundError.tag: self = .pluginNotFound(try PluginNotFoundError(from: decoder))
        case AgentNotFoundError.tag: self = .agentNotFound(try AgentNotFoundError(from: decoder))
        case SessionNotFoundError.tag: self = .sessionNotFound(try SessionNotFoundError(from: decoder))
        case MessageNotFoundError.tag: self = .messageNotFound(try MessageNotFoundError(from: decoder))
        case SkillNotFoundError.tag: self = .skillNotFound(try SkillNotFoundError(from: decoder))
        case McpServerNotFoundError.tag: self = .mcpServerNotFound(try McpServerNotFoundError(from: decoder))
        case CommandNotFoundError.tag: self = .commandNotFound(try CommandNotFoundError(from: decoder))
        case CommandExecutionError.tag: self = .commandExecution(try CommandExecutionError(from: decoder))
        case InvalidCursorError.tag: self = .invalidCursor(try InvalidCursorError(from: decoder))
        case PermissionNotFoundError.tag: self = .permissionNotFound(try PermissionNotFoundError(from: decoder))
        case PermissionSavedNotFoundError.tag: self = .permissionSavedNotFound(try PermissionSavedNotFoundError(from: decoder))
        case FormNotFoundError.tag: self = .formNotFound(try FormNotFoundError(from: decoder))
        case FormAlreadySettledError.tag: self = .formAlreadySettled(try FormAlreadySettledError(from: decoder))
        case FormInvalidAnswerError.tag: self = .formInvalidAnswer(try FormInvalidAnswerError(from: decoder))
        case ForbiddenError.tag: self = .forbidden(try ForbiddenError(from: decoder))
        case PtyNotFoundError.tag: self = .ptyNotFound(try PtyNotFoundError(from: decoder))
        case PtyFeatureUnsupportedError.tag: self = .ptyFeatureUnsupported(try PtyFeatureUnsupportedError(from: decoder))
        case ShellNotFoundError.tag: self = .shellNotFound(try ShellNotFoundError(from: decoder))
        case ModelNotFoundError.tag: self = .modelNotFound(try ModelNotFoundError(from: decoder))
        case UnsupportedModelError.tag: self = .unsupportedModel(try UnsupportedModelError(from: decoder))
        case ProviderRequestError.tag: self = .providerRequest(try ProviderRequestError(from: decoder))
        case AutomationNotFoundError.tag: self = .automationNotFound(try AutomationNotFoundError(from: decoder))
        case VideoNotFoundError.tag: self = .videoNotFound(try VideoNotFoundError(from: decoder))
        case BlobNotFoundError.tag: self = .blobNotFound(try BlobNotFoundError(from: decoder))
        case ArtifactNotFoundError.tag: self = .artifactNotFound(try ArtifactNotFoundError(from: decoder))
        case VcsInitNotSupportedError.tag: self = .vcsInitNotSupported(try VcsInitNotSupportedError(from: decoder))
        case WorktreeError.tag: self = .worktree(try WorktreeError(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: ._tag,
                in: tagContainer,
                debugDescription: "Unknown protocol error _tag '\(tag)'"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .locationNotFound(let e): try e.encode(to: encoder)
        case .invalidRequest(let e): try e.encode(to: encoder)
        case .rpc(let e): try e.encode(to: encoder)
        case .rpcInternal(let e): try e.encode(to: encoder)
        case .unauthorized(let e): try e.encode(to: encoder)
        case .conflict(let e): try e.encode(to: encoder)
        case .sessionBusy(let e): try e.encode(to: encoder)
        case .serviceUnavailable(let e): try e.encode(to: encoder)
        case .unknown(let e): try e.encode(to: encoder)
        case .providerNotFound(let e): try e.encode(to: encoder)
        case .integrationNotFound(let e): try e.encode(to: encoder)
        case .integrationAttemptNotFound(let e): try e.encode(to: encoder)
        case .integrationMethodNotFound(let e): try e.encode(to: encoder)
        case .projectNotFound(let e): try e.encode(to: encoder)
        case .fileNotFound(let e): try e.encode(to: encoder)
        case .pluginNotFound(let e): try e.encode(to: encoder)
        case .agentNotFound(let e): try e.encode(to: encoder)
        case .sessionNotFound(let e): try e.encode(to: encoder)
        case .messageNotFound(let e): try e.encode(to: encoder)
        case .skillNotFound(let e): try e.encode(to: encoder)
        case .mcpServerNotFound(let e): try e.encode(to: encoder)
        case .commandNotFound(let e): try e.encode(to: encoder)
        case .commandExecution(let e): try e.encode(to: encoder)
        case .invalidCursor(let e): try e.encode(to: encoder)
        case .permissionNotFound(let e): try e.encode(to: encoder)
        case .permissionSavedNotFound(let e): try e.encode(to: encoder)
        case .formNotFound(let e): try e.encode(to: encoder)
        case .formAlreadySettled(let e): try e.encode(to: encoder)
        case .formInvalidAnswer(let e): try e.encode(to: encoder)
        case .forbidden(let e): try e.encode(to: encoder)
        case .ptyNotFound(let e): try e.encode(to: encoder)
        case .ptyFeatureUnsupported(let e): try e.encode(to: encoder)
        case .shellNotFound(let e): try e.encode(to: encoder)
        case .modelNotFound(let e): try e.encode(to: encoder)
        case .unsupportedModel(let e): try e.encode(to: encoder)
        case .providerRequest(let e): try e.encode(to: encoder)
        case .automationNotFound(let e): try e.encode(to: encoder)
        case .videoNotFound(let e): try e.encode(to: encoder)
        case .blobNotFound(let e): try e.encode(to: encoder)
        case .artifactNotFound(let e): try e.encode(to: encoder)
        case .vcsInitNotSupported(let e): try e.encode(to: encoder)
        case .worktree(let e): try e.encode(to: encoder)
        }
    }

    /// Complete catalog of all 40 core protocol errors from `packages/protocol/src/errors.ts`.
    public static let allCoreErrorRefs: [ProtocolErrorRef] = [
        ProtocolErrorRef(LocationNotFoundError.self),
        ProtocolErrorRef(InvalidRequestError.self),
        ProtocolErrorRef(RpcError.self),
        ProtocolErrorRef(RpcInternalError.self),
        ProtocolErrorRef(UnauthorizedError.self),
        ProtocolErrorRef(ConflictError.self),
        ProtocolErrorRef(SessionBusyError.self),
        ProtocolErrorRef(ServiceUnavailableError.self),
        ProtocolErrorRef(UnknownError.self),
        ProtocolErrorRef(ProviderNotFoundError.self),
        ProtocolErrorRef(IntegrationNotFoundError.self),
        ProtocolErrorRef(IntegrationAttemptNotFoundError.self),
        ProtocolErrorRef(IntegrationMethodNotFoundError.self),
        ProtocolErrorRef(ProjectNotFoundError.self),
        ProtocolErrorRef(FileNotFoundError.self),
        ProtocolErrorRef(PluginNotFoundError.self),
        ProtocolErrorRef(AgentNotFoundError.self),
        ProtocolErrorRef(SessionNotFoundError.self),
        ProtocolErrorRef(MessageNotFoundError.self),
        ProtocolErrorRef(SkillNotFoundError.self),
        ProtocolErrorRef(McpServerNotFoundError.self),
        ProtocolErrorRef(CommandNotFoundError.self),
        ProtocolErrorRef(CommandExecutionError.self),
        ProtocolErrorRef(InvalidCursorError.self),
        ProtocolErrorRef(PermissionNotFoundError.self),
        ProtocolErrorRef(PermissionSavedNotFoundError.self),
        ProtocolErrorRef(FormNotFoundError.self),
        ProtocolErrorRef(FormAlreadySettledError.self),
        ProtocolErrorRef(FormInvalidAnswerError.self),
        ProtocolErrorRef(ForbiddenError.self),
        ProtocolErrorRef(PtyNotFoundError.self),
        ProtocolErrorRef(PtyFeatureUnsupportedError.self),
        ProtocolErrorRef(ShellNotFoundError.self),
        ProtocolErrorRef(ModelNotFoundError.self),
        ProtocolErrorRef(UnsupportedModelError.self),
        ProtocolErrorRef(ProviderRequestError.self),
        ProtocolErrorRef(AutomationNotFoundError.self),
        ProtocolErrorRef(VideoNotFoundError.self),
        ProtocolErrorRef(BlobNotFoundError.self),
        ProtocolErrorRef(ArtifactNotFoundError.self),
    ]
}
