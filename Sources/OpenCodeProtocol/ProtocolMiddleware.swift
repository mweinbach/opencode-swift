import OpenCodeSchema

/// Declarative descriptor for an HTTP API middleware service and the errors it may fail with.
/// Mirrors Effect's `HttpApiMiddleware.Service` / `Context.Key`.
public struct MiddlewareDescriptor: Equatable, Hashable, Sendable, Codable {
    public let id: String
    public let errors: [ProtocolErrorRef]

    public init(id: String, errors: [ProtocolErrorRef] = []) {
        self.id = id
        self.errors = errors
    }
}

/// HTTP API authorization middleware (`@opencode/HttpApiAuthorization`) failing with `UnauthorizedError` (401).
// parity: protocol/src/middleware/authorization.ts#Authorization [status=implemented hash=a899fb3e262a]
public enum Authorization {
    public static let id = "@opencode/HttpApiAuthorization"
    public static let error = ProtocolErrorRef(UnauthorizedError.self)
    public static let descriptor = MiddlewareDescriptor(id: id, errors: [error])
}

/// HTTP API schema validation error middleware (`@opencode/HttpApiSchemaError`) failing with `InvalidRequestError` (400).
// parity: protocol/src/middleware/schema-error.ts#SchemaErrorMiddleware [status=implemented hash=9c71df644a41]
public enum SchemaErrorMiddleware {
    public static let id = "@opencode/HttpApiSchemaError"
    public static let error = ProtocolErrorRef(InvalidRequestError.self)
    public static let descriptor = MiddlewareDescriptor(id: id, errors: [error])
}
