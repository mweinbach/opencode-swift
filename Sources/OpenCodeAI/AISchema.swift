#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

/// Canonical portable AI data schemas: branded IDs, typed error taxonomy, request & transport
/// options, normalized messages/tools, streaming LLM events, and the event-to-response fold.
///
/// Ports `packages/ai/src/schema/{ids,errors,options,messages,events}.ts`.
public enum AISchema {

    // MARK: - src/schema/ids.ts

    /// Stable string identifier for a protocol implementation.
    // parity: ai/src/schema/ids.ts#ProtocolID [status=implemented hash=802cf04b31d4]
    public typealias ProtocolID = String

    /// Stable string identifier for the runnable route.
    // parity: ai/src/schema/ids.ts#RouteID [status=implemented hash=735ef56ef1ab]
    public typealias RouteID = String

    /// Branded model identifier (`AI.ModelID`).
    // parity: ai/src/schema/ids.ts#ModelID [status=implemented hash=31d5a7eddd80]
    public struct ModelID: RawRepresentable, Hashable, Comparable, Sendable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(stringLiteral value: String) {
            self.rawValue = value
        }

        public static func make(_ value: String) -> ModelID {
            ModelID(rawValue: value)
        }

        public static func make(_ value: ModelID) -> ModelID {
            value
        }

        public var description: String { rawValue }

        public static func < (lhs: ModelID, rhs: ModelID) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.rawValue = try container.decode(String.self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    /// Branded provider identifier (`AI.ProviderID`).
    // parity: ai/src/schema/ids.ts#ProviderID [status=implemented hash=83c8fbd9c1c9]
    public struct ProviderID: RawRepresentable, Hashable, Comparable, Sendable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(stringLiteral value: String) {
            self.rawValue = value
        }

        public static func make(_ value: String) -> ProviderID {
            ProviderID(rawValue: value)
        }

        public static func make(_ value: ProviderID) -> ProviderID {
            value
        }

        public var description: String { rawValue }

        public static func < (lhs: ProviderID, rhs: ProviderID) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.rawValue = try container.decode(String.self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    // parity: ai/src/schema/ids.ts#ResponseID [status=implemented hash=cf98b1559004]
    public typealias ResponseID = String

    // parity: ai/src/schema/ids.ts#ContentBlockID [status=implemented hash=4593c673c94d]
    public typealias ContentBlockID = String

    // parity: ai/src/schema/ids.ts#ToolCallID [status=implemented hash=cdc1bb7d4d75]
    public typealias ToolCallID = String

    // MARK: - src/schema/errors.ts

    // parity: ai/src/schema/errors.ts#ProviderFailureClassification [status=implemented hash=1f15f48a45e3]
    public enum ProviderFailureClassification: String, Equatable, Hashable, Sendable, Codable {
        case contextOverflow = "context-overflow"
        case payloadTooLarge = "payload-too-large"
    }

    // parity: ai/src/schema/errors.ts#HttpContext [status=implemented hash=7ed2b9adf249]
    public struct HttpContext: Equatable, Hashable, Sendable, Codable {
        public let url: String
        public let status: Int
        public let headers: [String: String]

        public init(url: String, status: Int, headers: [String: String]) {
            self.url = url
            self.status = status
            self.headers = headers
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.url = try container.decode(String.self, forKey: .url)
            let status = try container.decode(Int.self, forKey: .status)
            guard status >= 100 && status <= 599 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .status,
                    in: container,
                    debugDescription: "HTTP status \(status) out of range 100...599"
                )
            }
            self.status = status
            self.headers = try container.decode([String: String].self, forKey: .headers)
        }

        enum CodingKeys: String, CodingKey {
            case url
            case status
            case headers
        }
    }

    // parity: ai/src/schema/errors.ts#HttpRateLimitDetails [status=implemented hash=cf31ccdeffec]
    public struct HttpRateLimitDetails: Equatable, Hashable, Sendable, Codable {
        public let retryAfterMs: Int?
        public let limit: [String: String]?
        public let remaining: [String: String]?
        public let reset: [String: String]?

        public init(
            retryAfterMs: Int? = nil,
            limit: [String: String]? = nil,
            remaining: [String: String]? = nil,
            reset: [String: String]? = nil
        ) {
            self.retryAfterMs = retryAfterMs
            self.limit = limit
            self.remaining = remaining
            self.reset = reset
        }
    }

    // parity: ai/src/schema/errors.ts#InvalidRequestError [status=implemented hash=f8c535d268ab]
    public struct InvalidRequestError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public static let tag = "InvalidRequest"
        public let message: String
        public let body: String?
        public let http: HttpContext?
        public let cause: String?
        public let parameter: String?
        public let classification: ProviderFailureClassification?

        public init(
            message: String,
            body: String? = nil,
            http: HttpContext? = nil,
            cause: String? = nil,
            parameter: String? = nil,
            classification: ProviderFailureClassification? = nil
        ) {
            self.message = message
            self.body = body
            self.http = http
            self.cause = cause
            self.parameter = parameter
            self.classification = classification
        }

        public var description: String { message }
    }

    // parity: ai/src/schema/errors.ts#UnsupportedOperationError [status=implemented hash=21800ea68491]
    public struct UnsupportedOperationError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public static let tag = "UnsupportedOperation"
        public let message: String
        public let body: String?
        public let http: HttpContext?
        public let cause: String?
        public let operation: String
        public let provider: ProviderID?
        public let route: RouteID?

        public init(
            message: String,
            body: String? = nil,
            http: HttpContext? = nil,
            cause: String? = nil,
            operation: String,
            provider: ProviderID? = nil,
            route: RouteID? = nil
        ) {
            self.message = message
            self.body = body
            self.http = http
            self.cause = cause
            self.operation = operation
            self.provider = provider
            self.route = route
        }

        public var description: String { message }
    }

    // parity: ai/src/schema/errors.ts#ProviderConfigurationError [status=implemented hash=1af594dfd7e8]
    public struct ProviderConfigurationError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public static let tag = "ProviderConfiguration"
        public let provider: ProviderID
        public let message: String

        public init(provider: ProviderID, message: String) {
            self.provider = provider
            self.message = message
        }

        public var description: String { "\(provider.rawValue): \(message)" }
    }

    // parity: ai/src/schema/errors.ts#AuthenticationError [status=implemented hash=8665e6da5ccb]
    public struct AuthenticationError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public static let tag = "Authentication"
        public let message: String
        public let body: String?
        public let http: HttpContext?
        public let cause: String?

        public init(
            message: String,
            body: String? = nil,
            http: HttpContext? = nil,
            cause: String? = nil
        ) {
            self.message = message
            self.body = body
            self.http = http
            self.cause = cause
        }

        public var description: String { message }
    }

    // parity: ai/src/schema/errors.ts#RateLimitError [status=implemented hash=9499ef1d4a70]
    public struct RateLimitError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public static let tag = "RateLimit"
        public let message: String
        public let body: String?
        public let http: HttpContext?
        public let cause: String?
        public let retryAfterMs: Int?
        public let rateLimit: HttpRateLimitDetails?

        public init(
            message: String,
            body: String? = nil,
            http: HttpContext? = nil,
            cause: String? = nil,
            retryAfterMs: Int? = nil,
            rateLimit: HttpRateLimitDetails? = nil
        ) {
            self.message = message
            self.body = body
            self.http = http
            self.cause = cause
            self.retryAfterMs = retryAfterMs
            self.rateLimit = rateLimit
        }

        public var description: String { message }
    }

    // parity: ai/src/schema/errors.ts#QuotaExceededError [status=implemented hash=e73acaf967c4]
    public struct QuotaExceededError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public static let tag = "QuotaExceeded"
        public let message: String
        public let body: String?
        public let http: HttpContext?
        public let cause: String?
        public let retryAfterMs: Int?

        public init(
            message: String,
            body: String? = nil,
            http: HttpContext? = nil,
            cause: String? = nil,
            retryAfterMs: Int? = nil
        ) {
            self.message = message
            self.body = body
            self.http = http
            self.cause = cause
            self.retryAfterMs = retryAfterMs
        }

        public var description: String { message }
    }

    // parity: ai/src/schema/errors.ts#ContentPolicyError [status=implemented hash=9d0e86ed9d44]
    public struct ContentPolicyError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public static let tag = "ContentPolicy"
        public let message: String
        public let body: String?
        public let http: HttpContext?
        public let cause: String?

        public init(
            message: String,
            body: String? = nil,
            http: HttpContext? = nil,
            cause: String? = nil
        ) {
            self.message = message
            self.body = body
            self.http = http
            self.cause = cause
        }

        public var description: String { message }
    }

    // parity: ai/src/schema/errors.ts#ProviderInternalError [status=implemented hash=87fd6647866f]
    public struct ProviderInternalError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public static let tag = "ProviderInternal"
        public let message: String
        public let body: String?
        public let http: HttpContext?
        public let cause: String?
        public let retryAfterMs: Int?

        public init(
            message: String,
            body: String? = nil,
            http: HttpContext? = nil,
            cause: String? = nil,
            retryAfterMs: Int? = nil
        ) {
            self.message = message
            self.body = body
            self.http = http
            self.cause = cause
            self.retryAfterMs = retryAfterMs
        }

        public var description: String { message }
    }

    // parity: ai/src/schema/errors.ts#TransportType [status=implemented hash=d0a5a46fee95]
    public enum TransportType: String, Equatable, Hashable, Sendable, Codable {
        case http
        case websocket
    }

    // parity: ai/src/schema/errors.ts#TransportOperation [status=implemented hash=62d5a4db4543]
    public enum TransportOperation: String, Equatable, Hashable, Sendable, Codable {
        case request
        case read
        case write
    }

    // parity: ai/src/schema/errors.ts#TransportError [status=implemented hash=c0727dff9609]
    public struct TransportError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public static let tag = "Transport"

        public enum Phase: String, Equatable, Hashable, Sendable, Codable {
            case prepare
            case queue
            case connect
            case send
            case receive
            case decode
            case complete
            case fallback
            case close
        }

        public enum Delivery: String, Equatable, Hashable, Sendable, Codable {
            case notSent = "not-sent"
            case rejected
            case ambiguous
            case accepted
        }

        public enum Recovery: String, Equatable, Hashable, Sendable, Codable {
            case retryConnect = "retry-connect"
            case retryFull = "retry-full"
            case rotateAndRetryFull = "rotate-and-retry-full"
            case fallbackHttp = "fallback-http"
            case fail
        }

        public let message: String
        public let body: String?
        public let http: HttpContext?
        public let cause: String?
        public let transport: TransportType
        public let operation: TransportOperation
        public let code: String?
        public let url: String?
        public let phase: Phase?
        public let delivery: Delivery?
        public let recovery: Recovery?

        public init(
            message: String,
            body: String? = nil,
            http: HttpContext? = nil,
            cause: String? = nil,
            transport: TransportType,
            operation: TransportOperation,
            code: String? = nil,
            url: String? = nil,
            phase: Phase? = nil,
            delivery: Delivery? = nil,
            recovery: Recovery? = nil
        ) {
            self.message = message
            self.body = body
            self.http = http
            self.cause = cause
            self.transport = transport
            self.operation = operation
            self.code = code
            self.url = url
            self.phase = phase
            self.delivery = delivery
            self.recovery = recovery
        }

        public var description: String { message }
    }

    // parity: ai/src/schema/errors.ts#InvalidProviderOutputError [status=implemented hash=0e71211caf77]
    public struct InvalidProviderOutputError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public static let tag = "InvalidProviderOutput"

        public enum Classification: String, Equatable, Hashable, Sendable, Codable {
            case incompleteStream = "incomplete-stream"
        }

        public let message: String
        public let body: String?
        public let http: HttpContext?
        public let cause: String?
        public let classification: Classification?
        public let route: String?

        public init(
            message: String,
            body: String? = nil,
            http: HttpContext? = nil,
            cause: String? = nil,
            classification: Classification? = nil,
            route: String? = nil
        ) {
            self.message = message
            self.body = body
            self.http = http
            self.cause = cause
            self.classification = classification
            self.route = route
        }

        public var description: String { message }
    }

    // parity: ai/src/schema/errors.ts#UnknownProviderError [status=implemented hash=5bf678eff037]
    public struct UnknownProviderError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public static let tag = "UnknownProvider"
        public let message: String
        public let body: String?
        public let http: HttpContext?
        public let cause: String?

        public init(
            message: String,
            body: String? = nil,
            http: HttpContext? = nil,
            cause: String? = nil
        ) {
            self.message = message
            self.body = body
            self.http = http
            self.cause = cause
        }

        public var description: String { message }
    }

    // parity: ai/src/schema/errors.ts#TimeoutError [status=implemented hash=3035b6e740d9]
    public struct TimeoutError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public static let tag = "Timeout"
        public let message: String
        public let body: String?
        public let http: HttpContext?
        public let cause: String?
        public let timeoutMs: Int?

        public init(
            message: String,
            body: String? = nil,
            http: HttpContext? = nil,
            cause: String? = nil,
            timeoutMs: Int? = nil
        ) {
            self.message = message
            self.body = body
            self.http = http
            self.cause = cause
            self.timeoutMs = timeoutMs
        }

        public var description: String { message }
    }

    // parity: ai/src/schema/errors.ts#AIErrorReason [status=implemented hash=6f88528b8fab]
    public enum AIErrorReason: Equatable, Hashable, Sendable, Codable {
        case invalidRequest(InvalidRequestError)
        case unsupportedOperation(UnsupportedOperationError)
        case authentication(AuthenticationError)
        case rateLimit(RateLimitError)
        case quotaExceeded(QuotaExceededError)
        case contentPolicy(ContentPolicyError)
        case providerInternal(ProviderInternalError)
        case transport(TransportError)
        case invalidProviderOutput(InvalidProviderOutputError)
        case unknownProvider(UnknownProviderError)
        case timeout(TimeoutError)

        public var tag: String {
            switch self {
            case .invalidRequest: InvalidRequestError.tag
            case .unsupportedOperation: UnsupportedOperationError.tag
            case .authentication: AuthenticationError.tag
            case .rateLimit: RateLimitError.tag
            case .quotaExceeded: QuotaExceededError.tag
            case .contentPolicy: ContentPolicyError.tag
            case .providerInternal: ProviderInternalError.tag
            case .transport: TransportError.tag
            case .invalidProviderOutput: InvalidProviderOutputError.tag
            case .unknownProvider: UnknownProviderError.tag
            case .timeout: TimeoutError.tag
            }
        }

        public var message: String {
            switch self {
            case .invalidRequest(let e): e.message
            case .unsupportedOperation(let e): e.message
            case .authentication(let e): e.message
            case .rateLimit(let e): e.message
            case .quotaExceeded(let e): e.message
            case .contentPolicy(let e): e.message
            case .providerInternal(let e): e.message
            case .transport(let e): e.message
            case .invalidProviderOutput(let e): e.message
            case .unknownProvider(let e): e.message
            case .timeout(let e): e.message
            }
        }

        public var body: String? {
            switch self {
            case .invalidRequest(let e): e.body
            case .unsupportedOperation(let e): e.body
            case .authentication(let e): e.body
            case .rateLimit(let e): e.body
            case .quotaExceeded(let e): e.body
            case .contentPolicy(let e): e.body
            case .providerInternal(let e): e.body
            case .transport(let e): e.body
            case .invalidProviderOutput(let e): e.body
            case .unknownProvider(let e): e.body
            case .timeout(let e): e.body
            }
        }

        public var http: HttpContext? {
            switch self {
            case .invalidRequest(let e): e.http
            case .unsupportedOperation(let e): e.http
            case .authentication(let e): e.http
            case .rateLimit(let e): e.http
            case .quotaExceeded(let e): e.http
            case .contentPolicy(let e): e.http
            case .providerInternal(let e): e.http
            case .transport(let e): e.http
            case .invalidProviderOutput(let e): e.http
            case .unknownProvider(let e): e.http
            case .timeout(let e): e.http
            }
        }

        public var cause: String? {
            switch self {
            case .invalidRequest(let e): e.cause
            case .unsupportedOperation(let e): e.cause
            case .authentication(let e): e.cause
            case .rateLimit(let e): e.cause
            case .quotaExceeded(let e): e.cause
            case .contentPolicy(let e): e.cause
            case .providerInternal(let e): e.cause
            case .transport(let e): e.cause
            case .invalidProviderOutput(let e): e.cause
            case .unknownProvider(let e): e.cause
            case .timeout(let e): e.cause
            }
        }

        public func with(body: String? = nil, http: HttpContext? = nil) -> AIErrorReason {
            switch self {
            case .invalidRequest(let e):
                return .invalidRequest(InvalidRequestError(
                    message: e.message, body: body ?? e.body, http: http ?? e.http, cause: e.cause,
                    parameter: e.parameter, classification: e.classification
                ))
            case .unsupportedOperation(let e):
                return .unsupportedOperation(UnsupportedOperationError(
                    message: e.message, body: body ?? e.body, http: http ?? e.http, cause: e.cause,
                    operation: e.operation, provider: e.provider, route: e.route
                ))
            case .authentication(let e):
                return .authentication(AuthenticationError(
                    message: e.message, body: body ?? e.body, http: http ?? e.http, cause: e.cause
                ))
            case .rateLimit(let e):
                return .rateLimit(RateLimitError(
                    message: e.message, body: body ?? e.body, http: http ?? e.http, cause: e.cause,
                    retryAfterMs: e.retryAfterMs, rateLimit: e.rateLimit
                ))
            case .quotaExceeded(let e):
                return .quotaExceeded(QuotaExceededError(
                    message: e.message, body: body ?? e.body, http: http ?? e.http, cause: e.cause,
                    retryAfterMs: e.retryAfterMs
                ))
            case .contentPolicy(let e):
                return .contentPolicy(ContentPolicyError(
                    message: e.message, body: body ?? e.body, http: http ?? e.http, cause: e.cause
                ))
            case .providerInternal(let e):
                return .providerInternal(ProviderInternalError(
                    message: e.message, body: body ?? e.body, http: http ?? e.http, cause: e.cause,
                    retryAfterMs: e.retryAfterMs
                ))
            case .transport(let e):
                return .transport(TransportError(
                    message: e.message, body: body ?? e.body, http: http ?? e.http, cause: e.cause,
                    transport: e.transport, operation: e.operation, code: e.code, url: e.url,
                    phase: e.phase, delivery: e.delivery, recovery: e.recovery
                ))
            case .invalidProviderOutput(let e):
                return .invalidProviderOutput(InvalidProviderOutputError(
                    message: e.message, body: body ?? e.body, http: http ?? e.http, cause: e.cause,
                    classification: e.classification, route: e.route
                ))
            case .unknownProvider(let e):
                return .unknownProvider(UnknownProviderError(
                    message: e.message, body: body ?? e.body, http: http ?? e.http, cause: e.cause
                ))
            case .timeout(let e):
                return .timeout(TimeoutError(
                    message: e.message, body: body ?? e.body, http: http ?? e.http, cause: e.cause,
                    timeoutMs: e.timeoutMs
                ))
            }
        }

        enum TagKeys: String, CodingKey {
            case tag = "_tag"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: TagKeys.self)
            let tag = try container.decode(String.self, forKey: .tag)
            switch tag {
            case InvalidRequestError.tag: self = .invalidRequest(try InvalidRequestError(from: decoder))
            case UnsupportedOperationError.tag: self = .unsupportedOperation(try UnsupportedOperationError(from: decoder))
            case AuthenticationError.tag: self = .authentication(try AuthenticationError(from: decoder))
            case RateLimitError.tag: self = .rateLimit(try RateLimitError(from: decoder))
            case QuotaExceededError.tag: self = .quotaExceeded(try QuotaExceededError(from: decoder))
            case ContentPolicyError.tag: self = .contentPolicy(try ContentPolicyError(from: decoder))
            case ProviderInternalError.tag: self = .providerInternal(try ProviderInternalError(from: decoder))
            case TransportError.tag: self = .transport(try TransportError(from: decoder))
            case InvalidProviderOutputError.tag: self = .invalidProviderOutput(try InvalidProviderOutputError(from: decoder))
            case UnknownProviderError.tag: self = .unknownProvider(try UnknownProviderError(from: decoder))
            case TimeoutError.tag: self = .timeout(try TimeoutError(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .tag,
                    in: container,
                    debugDescription: "Unknown AIErrorReason _tag '\(tag)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var tagContainer = encoder.container(keyedBy: TagKeys.self)
            try tagContainer.encode(tag, forKey: .tag)
            switch self {
            case .invalidRequest(let e): try e.encode(to: encoder)
            case .unsupportedOperation(let e): try e.encode(to: encoder)
            case .authentication(let e): try e.encode(to: encoder)
            case .rateLimit(let e): try e.encode(to: encoder)
            case .quotaExceeded(let e): try e.encode(to: encoder)
            case .contentPolicy(let e): try e.encode(to: encoder)
            case .providerInternal(let e): try e.encode(to: encoder)
            case .transport(let e): try e.encode(to: encoder)
            case .invalidProviderOutput(let e): try e.encode(to: encoder)
            case .unknownProvider(let e): try e.encode(to: encoder)
            case .timeout(let e): try e.encode(to: encoder)
            }
        }
    }

    // parity: ai/src/schema/errors.ts#AIError [status=implemented hash=fca5de491664]
    public struct AIError: Swift.Error, Equatable, Sendable, Codable, CustomStringConvertible {
        public static let tag = "AI.Error"
        public let reason: AIErrorReason
        /// Output that arrived before `generate` or a `loop` step failed. Omitted when encoding.
        public let partial: LLMResponse?

        public init(reason: AIErrorReason, partial: LLMResponse? = nil) {
            self.reason = reason
            self.partial = partial
        }

        // parity: ai/src/schema/errors.ts#AIError.message [status=implemented hash=a024d8270e86]
        public var message: String { reason.message }
        public var description: String { reason.message }

        /// HTTP status of the failed response, when the failure came from one.
        // parity: ai/src/schema/errors.ts#AIError.status [status=implemented hash=b0fb7f40b6e4]
        public var status: Int? { reason.http?.status }

        /// The provider's error code from the response body or `x-amzn-errortype`, or the transport's system error code.
        // parity: ai/src/schema/errors.ts#AIError.code [status=implemented hash=a08c3b90470c]
        public var code: String? {
            if case .transport(let transport) = reason, let code = transport.code {
                return code
            }
            var codes: [String] = []
            if let body = reason.body {
                codes.append(contentsOf: AIUtils.providerCodes(body))
            }
            if let errType = reason.http?.headers["x-amzn-errortype"] {
                codes.append(contentsOf: AIUtils.awsErrorType(errType))
            }
            return codes.first
        }

        /// Delay the provider asked for before retrying, from `retry-after` style headers.
        // parity: ai/src/schema/errors.ts#AIError.retryAfterMs [status=implemented hash=ad188bbe044e]
        public var retryAfterMs: Int? {
            switch reason {
            case .rateLimit(let e):
                return e.retryAfterMs ?? e.rateLimit?.retryAfterMs
            case .quotaExceeded(let e):
                return e.retryAfterMs
            case .providerInternal(let e):
                return e.retryAfterMs
            default:
                return nil
            }
        }

        /// Whether a failed call may succeed when sent again.
        // parity: ai/src/schema/errors.ts#AIError.isRetryable [status=implemented hash=8ba2441e3070]
        public var isRetryable: Bool {
            if let override = reason.http?.headers["x-should-retry"] {
                if override == "true" { return true }
                if override == "false" { return false }
            }
            switch reason {
            case .rateLimit, .providerInternal:
                return true
            case .transport(let t):
                return t.delivery != .rejected && (t.delivery != .accepted || t.operation == .read)
            case .invalidProviderOutput(let o):
                return o.classification == .incompleteStream
            case .unknownProvider:
                return true
            case .authentication, .quotaExceeded, .contentPolicy, .invalidRequest, .unsupportedOperation, .timeout:
                return false
            }
        }

        enum CodingKeys: String, CodingKey {
            case tag = "_tag"
            case reason
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.reason = try container.decode(AIErrorReason.self, forKey: .reason)
            self.partial = nil
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Self.tag, forKey: .tag)
            try container.encode(reason, forKey: .reason)
        }
    }

    /// Return `error` with `partial` attached, or unchanged when there is no partial output.
    // parity: ai/src/schema/errors.ts#withPartial [status=implemented hash=132fc8a120ba]
    public static func withPartial(_ error: AIError, partial: LLMResponse?) -> AIError {
        guard let partial else { return error }
        return AIError(reason: error.reason, partial: partial)
    }

    /// Failure type for tool execute handlers.
    // parity: ai/src/schema/errors.ts#ToolFailure [status=implemented hash=3acb019c337d]
    public typealias ToolFailure = ToolSchema.ToolError

    // MARK: - src/schema/options.ts

    // parity: ai/src/schema/options.ts#JsonSchema [status=implemented hash=c41cfc48f430]
    public typealias JsonSchema = [String: JSONValue]

    // parity: ai/src/schema/options.ts#mergeJsonRecords [status=implemented hash=19e02cb16063]
    public static func mergeJsonRecords(_ items: [String: JSONValue]?...) -> [String: JSONValue]? {
        mergeJsonRecords(items)
    }

    public static func mergeJsonRecords(_ items: [[String: JSONValue]?]) -> [String: JSONValue]? {
        let defined = items.compactMap { $0 }
        if defined.isEmpty { return nil }
        if defined.count == 1 { return defined[0].isEmpty ? nil : defined[0] }
        var result: [String: JSONValue] = [:]
        for item in defined {
            for (key, value) in item {
                if case .object(let existingObj) = result[key], case .object(let nextObj) = value {
                    if let merged = mergeJsonRecords([existingObj, nextObj]) {
                        result[key] = .object(merged)
                    } else {
                        result[key] = .object([:])
                    }
                } else {
                    result[key] = value
                }
            }
        }
        return result.isEmpty ? nil : result
    }

    // parity: ai/src/schema/options.ts#ProviderOptions [status=implemented hash=4dc14ed18d0c]
    public typealias ProviderOptions = [String: JSONValue]

    // parity: ai/src/schema/options.ts#ProviderMetadata [status=implemented hash=1f8afa1c1dff]
    public typealias ProviderMetadata = [String: [String: JSONValue]]

    // parity: ai/src/schema/options.ts#mergeProviderOptions [status=implemented hash=002e902c54c5]
    public static func mergeProviderOptions(_ items: ProviderOptions?...) -> ProviderOptions? {
        mergeJsonRecords(items)
    }

    public static func mergeProviderOptions(_ items: [ProviderOptions?]) -> ProviderOptions? {
        mergeJsonRecords(items)
    }

    /// Milliseconds for an HTTP timeout, or `false` (`.disabled`) to disable it.
    // parity: ai/src/schema/options.ts#HttpTimeout [status=implemented hash=7dc48837e513]
    public enum HttpTimeout: Equatable, Hashable, Sendable, Codable {
        case milliseconds(Double)
        case disabled

        public init?(milliseconds: Double) {
            guard milliseconds.isFinite && milliseconds > 0 else { return nil }
            self = .milliseconds(milliseconds)
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let boolValue = try? container.decode(Bool.self) {
                guard boolValue == false else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "Expected false or positive number for HttpTimeout"
                    )
                }
                self = .disabled
                return
            }
            let ms = try container.decode(Double.self)
            guard ms.isFinite && ms > 0 else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "HttpTimeout milliseconds must be > 0, got \(ms)"
                )
            }
            self = .milliseconds(ms)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .milliseconds(let ms):
                try container.encode(ms)
            case .disabled:
                try container.encode(false)
            }
        }
    }

    /// Applied to `timeout.headers` when a request leaves it unset.
    // parity: ai/src/schema/options.ts#DEFAULT_HTTP_TIMEOUT_MS [status=implemented hash=345616a5250d]
    public static let DEFAULT_HTTP_TIMEOUT_MS: Double = 300_000

    /// Applied to `timeout.chunk` when a request leaves it unset.
    // parity: ai/src/schema/options.ts#DEFAULT_CHUNK_TIMEOUT_MS [status=implemented hash=ad58a6869793]
    public static let DEFAULT_CHUNK_TIMEOUT_MS: Double = 900_000

    /// `Content-Encoding` for JSON request bodies; `none` sends plain JSON.
    // parity: ai/src/schema/options.ts#RequestEncoding [status=implemented hash=4dc354b10365]
    public enum RequestEncoding: String, Equatable, Hashable, Sendable, Codable {
        case zstd
        case gzip
        case none
    }

    /// PEM client certificate and private key, with the passphrase of an encrypted key.
    // parity: ai/src/schema/options.ts#ClientTls [status=implemented hash=2688224cc1d8]
    public struct ClientTls: Equatable, Hashable, Sendable, Codable {
        public let cert: String
        public let key: String
        public let passphrase: String?

        public init(cert: String, key: String, passphrase: String? = nil) {
            self.cert = cert
            self.key = key
            self.passphrase = passphrase
        }
    }

    /// Rare wire-level overrides.
    // parity: ai/src/schema/options.ts#HttpOptions [status=implemented hash=51e140b4fb5a]
    public struct HttpOptions: Equatable, Hashable, Sendable, Codable {
        public let query: [String: String]?
        public let body: [String: JSONValue]?
        public let encoding: RequestEncoding?
        public let tls: ClientTls?

        public init(
            query: [String: String]? = nil,
            body: [String: JSONValue]? = nil,
            encoding: RequestEncoding? = nil,
            tls: ClientTls? = nil
        ) {
            self.query = query
            self.body = body
            self.encoding = encoding
            self.tls = tls
        }

        public var isEmpty: Bool {
            query == nil && body == nil && encoding == nil && tls == nil
        }
    }

    /// Per-phase time limits in milliseconds.
    // parity: ai/src/schema/options.ts#TimeoutConfig [status=implemented hash=9cab390e6550]
    public struct TimeoutConfig: Equatable, Hashable, Sendable, Codable {
        public let total: HttpTimeout?
        public let headers: HttpTimeout?
        public let chunk: HttpTimeout?

        public init(total: HttpTimeout? = nil, headers: HttpTimeout? = nil, chunk: HttpTimeout? = nil) {
            self.total = total
            self.headers = headers
            self.chunk = chunk
        }

        public var isEmpty: Bool {
            total == nil && headers == nil && chunk == nil
        }
    }

    /// Milliseconds for the whole request, `false` to disable it, or per-phase limits.
    // parity: ai/src/schema/options.ts#RequestTimeout [status=implemented hash=a2f38cc10525]
    public enum RequestTimeout: Equatable, Hashable, Sendable, Codable {
        case single(HttpTimeout)
        case phases(TimeoutConfig)

        public init(from decoder: Decoder) throws {
            if let single = try? HttpTimeout(from: decoder) {
                self = .single(single)
                return
            }
            self = .phases(try TimeoutConfig(from: decoder))
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .single(let t): try t.encode(to: encoder)
            case .phases(let c): try c.encode(to: encoder)
            }
        }
    }

    /// Transport settings shared by requests, models and routes.
    // parity: ai/src/schema/options.ts#TransportOptions [status=implemented hash=ffd61c820d00]
    public struct TransportOptions: Equatable, Hashable, Sendable, Codable {
        public let headers: [String: String]?
        public let timeout: RequestTimeout?
        public let http: HttpOptions?

        public init(
            headers: [String: String]? = nil,
            timeout: RequestTimeout? = nil,
            http: HttpOptions? = nil
        ) {
            self.headers = headers
            self.timeout = timeout
            self.http = http
        }

        public var isEmpty: Bool {
            headers == nil && timeout == nil && http == nil
        }
    }

    /// The fields every request shares, whatever its modality.
    // parity: ai/src/schema/options.ts#BaseRequest [status=adapted hash=894d8877b31a]
    public protocol BaseRequest: Sendable {
        associatedtype Model: Sendable
        var model: Model { get }
        var headers: [String: String]? { get }
        var timeout: RequestTimeout? { get }
        var http: HttpOptions? { get }
        var providerOptions: ProviderOptions? { get }
        var fetch: (any HTTPTransport)? { get }
    }

    // parity: ai/src/schema/options.ts#timeoutConfig [status=implemented hash=e86a36b31a11]
    public static func timeoutConfig(_ timeout: RequestTimeout?) -> TimeoutConfig {
        switch timeout {
        case .none:
            return TimeoutConfig()
        case .single(let single):
            return TimeoutConfig(total: single)
        case .phases(let config):
            return config
        }
    }

    private static func mergeStringRecords(_ items: [[String: String]?]) -> [String: String]? {
        let defined = items.compactMap { $0 }
        if defined.isEmpty { return nil }
        if defined.count == 1 { return defined[0].isEmpty ? nil : defined[0] }
        var result: [String: String] = [:]
        for item in defined {
            for (k, v) in item {
                result[k] = v
            }
        }
        return result.isEmpty ? nil : result
    }

    /// Merge transport settings; later items win, headers, query and body merge by key.
    // parity: ai/src/schema/options.ts#mergeTransport [status=implemented hash=3c52a9ca5a90]
    public static func mergeTransport(_ items: TransportOptions?...) -> TransportOptions {
        mergeTransport(items)
    }

    public static func mergeTransport(_ items: [TransportOptions?]) -> TransportOptions {
        let timeouts = items.map { timeoutConfig($0?.timeout) }
        let https = items.map { $0?.http }
        let mergedTimeout = TimeoutConfig(
            total: timeouts.compactMap(\.total).last,
            headers: timeouts.compactMap(\.headers).last,
            chunk: timeouts.compactMap(\.chunk).last
        )
        let mergedHttp = HttpOptions(
            query: mergeStringRecords(https.map { $0?.query }),
            body: mergeJsonRecords(https.map { $0?.body }),
            encoding: https.compactMap { $0?.encoding }.last,
            tls: https.compactMap { $0?.tls }.last
        )
        return TransportOptions(
            headers: mergeStringRecords(items.map { $0?.headers }),
            timeout: mergedTimeout.isEmpty ? nil : .phases(mergedTimeout),
            http: mergedHttp.isEmpty ? nil : mergedHttp
        )
    }

    /// Portable sampling knobs, set at the top level of text requests, model defaults and route defaults.
    // parity: ai/src/schema/options.ts#GenerationOptionsFields [status=implemented hash=982cad68b930]
    public struct GenerationOptionsFields: Equatable, Hashable, Sendable, Codable {
        public let maxTokens: Int?
        public let temperature: Double?
        public let topP: Double?
        public let topK: Int?
        public let frequencyPenalty: Double?
        public let presencePenalty: Double?
        public let seed: Int?
        public let stop: [String]?

        public init(
            maxTokens: Int? = nil,
            temperature: Double? = nil,
            topP: Double? = nil,
            topK: Int? = nil,
            frequencyPenalty: Double? = nil,
            presencePenalty: Double? = nil,
            seed: Int? = nil,
            stop: [String]? = nil
        ) {
            self.maxTokens = maxTokens
            self.temperature = temperature
            self.topP = topP
            self.topK = topK
            self.frequencyPenalty = frequencyPenalty
            self.presencePenalty = presencePenalty
            self.seed = seed
            self.stop = stop
        }

        public var isEmpty: Bool {
            maxTokens == nil && temperature == nil && topP == nil && topK == nil
                && frequencyPenalty == nil && presencePenalty == nil && seed == nil && stop == nil
        }
    }

    /// The keys of `GenerationOptionsFields`, for splitting a flat record into portable knobs and provider options.
    // parity: ai/src/schema/options.ts#GENERATION_KEYS [status=implemented hash=cc9819c5548b]
    public static let GENERATION_KEYS: Set<String> = [
        "maxTokens",
        "temperature",
        "topP",
        "topK",
        "frequencyPenalty",
        "presencePenalty",
        "seed",
        "stop",
    ]

    /// Pick the generation knobs out of each item; later items win per knob.
    // parity: ai/src/schema/options.ts#mergeGeneration [status=implemented hash=ba6e4410f927]
    public static func mergeGeneration(_ items: GenerationOptionsFields?...) -> GenerationOptionsFields {
        mergeGeneration(items)
    }

    public static func mergeGeneration(_ items: [GenerationOptionsFields?]) -> GenerationOptionsFields {
        GenerationOptionsFields(
            maxTokens: items.compactMap { $0?.maxTokens }.last,
            temperature: items.compactMap { $0?.temperature }.last,
            topP: items.compactMap { $0?.topP }.last,
            topK: items.compactMap { $0?.topK }.last,
            frequencyPenalty: items.compactMap { $0?.frequencyPenalty }.last,
            presencePenalty: items.compactMap { $0?.presencePenalty }.last,
            seed: items.compactMap { $0?.seed }.last,
            stop: items.compactMap { $0?.stop }.last
        )
    }

    /// Request options a model applies under each request: the same keys as a request, and the request wins.
    // parity: ai/src/schema/options.ts#RequestOptions [status=implemented hash=52b58e299824]
    public struct RequestOptions: Equatable, Hashable, Sendable, Codable {
        public let headers: [String: String]?
        public let timeout: RequestTimeout?
        public let http: HttpOptions?
        public let maxTokens: Int?
        public let temperature: Double?
        public let topP: Double?
        public let topK: Int?
        public let frequencyPenalty: Double?
        public let presencePenalty: Double?
        public let seed: Int?
        public let stop: [String]?
        public let providerOptions: ProviderOptions?

        public init(
            headers: [String: String]? = nil,
            timeout: RequestTimeout? = nil,
            http: HttpOptions? = nil,
            maxTokens: Int? = nil,
            temperature: Double? = nil,
            topP: Double? = nil,
            topK: Int? = nil,
            frequencyPenalty: Double? = nil,
            presencePenalty: Double? = nil,
            seed: Int? = nil,
            stop: [String]? = nil,
            providerOptions: ProviderOptions? = nil
        ) {
            self.headers = headers
            self.timeout = timeout
            self.http = http
            self.maxTokens = maxTokens
            self.temperature = temperature
            self.topP = topP
            self.topK = topK
            self.frequencyPenalty = frequencyPenalty
            self.presencePenalty = presencePenalty
            self.seed = seed
            self.stop = stop
            self.providerOptions = providerOptions
        }

        public var transport: TransportOptions {
            TransportOptions(headers: headers, timeout: timeout, http: http)
        }

        public var generation: GenerationOptionsFields {
            GenerationOptionsFields(
                maxTokens: maxTokens,
                temperature: temperature,
                topP: topP,
                topK: topK,
                frequencyPenalty: frequencyPenalty,
                presencePenalty: presencePenalty,
                seed: seed,
                stop: stop
            )
        }

        public var isEmpty: Bool {
            transport.isEmpty && generation.isEmpty && providerOptions == nil
        }
    }

    /// Merge model options; later items win per key. Empty results are `nil`.
    // parity: ai/src/schema/options.ts#mergeRequestOptions [status=implemented hash=598b969b7ab5]
    public static func mergeRequestOptions(_ items: RequestOptions?...) -> RequestOptions? {
        mergeRequestOptions(items)
    }

    public static func mergeRequestOptions(_ items: [RequestOptions?]) -> RequestOptions? {
        let transport = mergeTransport(items.map { $0?.transport })
        let gen = mergeGeneration(items.map { $0?.generation })
        let providerOpts = mergeProviderOptions(items.map { $0?.providerOptions })
        let merged = RequestOptions(
            headers: transport.headers,
            timeout: transport.timeout,
            http: transport.http,
            maxTokens: gen.maxTokens,
            temperature: gen.temperature,
            topP: gen.topP,
            topK: gen.topK,
            frequencyPenalty: gen.frequencyPenalty,
            presencePenalty: gen.presencePenalty,
            seed: gen.seed,
            stop: gen.stop,
            providerOptions: providerOpts
        )
        return merged.isEmpty ? nil : merged
    }

    /// Provider-defined string enum: known values for autocomplete, any string accepted.
    // parity: ai/src/schema/options.ts#OpenString [status=implemented hash=43d23e83202a]
    public struct OpenString<Known: RawRepresentable & Hashable & Sendable>: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible where Known.RawValue == String {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(_ known: Known) {
            self.rawValue = known.rawValue
        }

        public init(stringLiteral value: String) {
            self.rawValue = value
        }

        public var known: Known? { Known(rawValue: rawValue) }
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

    // parity: ai/src/schema/options.ts#ReasoningEfforts [status=implemented hash=3cca9a9b0e31]
    public static let ReasoningEfforts: [String] = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

    // parity: ai/src/schema/options.ts#ReasoningEffort [status=implemented hash=648351ab150b]
    public struct ReasoningEffort: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
        public let rawValue: String

        public static let none = ReasoningEffort(rawValue: "none")
        public static let minimal = ReasoningEffort(rawValue: "minimal")
        public static let low = ReasoningEffort(rawValue: "low")
        public static let medium = ReasoningEffort(rawValue: "medium")
        public static let high = ReasoningEffort(rawValue: "high")
        public static let xhigh = ReasoningEffort(rawValue: "xhigh")
        public static let max = ReasoningEffort(rawValue: "max")

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(stringLiteral value: String) {
            self.rawValue = value
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

    // parity: ai/src/schema/options.ts#LanguageModelSanitizerCompatibility [status=implemented hash=bbcbda905216]
    public enum LanguageModelSanitizerCompatibility: String, Equatable, Hashable, Sendable, Codable {
        case gemini
        case moonshot
        case none
    }

    // parity: ai/src/schema/options.ts#LanguageModelMaxTokensFieldCompatibility [status=implemented hash=6c4aee46eefc]
    public enum LanguageModelMaxTokensFieldCompatibility: String, Equatable, Hashable, Sendable, Codable {
        case maxCompletionTokens = "max_completion_tokens"
        case maxTokens = "max_tokens"
    }

    // parity: ai/src/schema/options.ts#LanguageModelCacheFormatCompatibility [status=implemented hash=07af5a46a173]
    public enum LanguageModelCacheFormatCompatibility: String, Equatable, Hashable, Sendable, Codable {
        case anthropic
        case alibaba
    }

    // parity: ai/src/schema/options.ts#LanguageModelCompatibility [status=implemented hash=8930f87180c1]
    public struct LanguageModelCompatibility: Equatable, Hashable, Sendable, Codable {
        // parity: ai/src/schema/options.ts#LanguageModelCompatibility.Input [status=implemented hash=0b5db6ff2fe3]
        public typealias Input = LanguageModelCompatibility

        public let sanitizer: LanguageModelSanitizerCompatibility?
        public let reasoningField: String?
        public let requireReasoning: Bool?
        public let maxTokensField: LanguageModelMaxTokensFieldCompatibility?
        public let requireFinishReason: Bool?
        public let requireAssistantAfterTool: Bool?
        public let cacheFormat: LanguageModelCacheFormatCompatibility?
        public let zaiToolStream: Bool?
        public let requireSignature: Bool?
        public let supportsThinkingBlockBinding: Bool?

        public init(
            sanitizer: LanguageModelSanitizerCompatibility? = nil,
            reasoningField: String? = nil,
            requireReasoning: Bool? = nil,
            maxTokensField: LanguageModelMaxTokensFieldCompatibility? = nil,
            requireFinishReason: Bool? = nil,
            requireAssistantAfterTool: Bool? = nil,
            cacheFormat: LanguageModelCacheFormatCompatibility? = nil,
            zaiToolStream: Bool? = nil,
            requireSignature: Bool? = nil,
            supportsThinkingBlockBinding: Bool? = nil
        ) {
            self.sanitizer = sanitizer
            self.reasoningField = reasoningField
            self.requireReasoning = requireReasoning
            self.maxTokensField = maxTokensField
            self.requireFinishReason = requireFinishReason
            self.requireAssistantAfterTool = requireAssistantAfterTool
            self.cacheFormat = cacheFormat
            self.zaiToolStream = zaiToolStream
            self.requireSignature = requireSignature
            self.supportsThinkingBlockBinding = supportsThinkingBlockBinding
        }

        // parity: ai/src/schema/options.ts#LanguageModelCompatibility.make [status=implemented hash=760d7ac2e0a8]
        public static func make(_ input: Input) -> LanguageModelCompatibility {
            input
        }
    }

    // parity: ai/src/schema/options.ts#Capabilities [status=implemented hash=c4b28bcb1688]
    public struct Capabilities: Equatable, Hashable, Sendable, Codable {
        public enum ToolChoiceKind: String, Equatable, Hashable, Sendable, Codable {
            case auto
            case none
            case required
            case tool
        }

        public enum FreeformKind: String, Equatable, Hashable, Sendable, Codable {
            case text
            case lark
            case regex
        }

        public enum ToolUpdateKind: String, Equatable, Hashable, Sendable, Codable {
            case add
            case remove
            case replace
        }

        public struct Tools: Equatable, Hashable, Sendable, Codable {
            public let supported: Bool?
            public let strict: Bool?
            public let choice: [ToolChoiceKind]?
            public let search: Bool?
            public let freeform: [FreeformKind]?
            public let updates: [ToolUpdateKind]?

            public init(
                supported: Bool? = nil,
                strict: Bool? = nil,
                choice: [ToolChoiceKind]? = nil,
                search: Bool? = nil,
                freeform: [FreeformKind]? = nil,
                updates: [ToolUpdateKind]? = nil
            ) {
                self.supported = supported
                self.strict = strict
                self.choice = choice
                self.search = search
                self.freeform = freeform
                self.updates = updates
            }
        }

        public enum ReasoningDefault: Equatable, Hashable, Sendable, Codable {
            case toggle(Bool)
            case effort(ReasoningEffort)
            case budget(Int)

            enum CodingKeys: String, CodingKey {
                case type
                case value
            }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let type = try c.decode(String.self, forKey: .type)
                switch type {
                case "toggle": self = .toggle(try c.decode(Bool.self, forKey: .value))
                case "effort": self = .effort(try c.decode(ReasoningEffort.self, forKey: .value))
                case "budget": self = .budget(try c.decode(Int.self, forKey: .value))
                default:
                    throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown ReasoningDefault type '\(type)'")
                }
            }

            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .toggle(let v):
                    try c.encode("toggle", forKey: .type)
                    try c.encode(v, forKey: .value)
                case .effort(let v):
                    try c.encode("effort", forKey: .type)
                    try c.encode(v, forKey: .value)
                case .budget(let v):
                    try c.encode("budget", forKey: .type)
                    try c.encode(v, forKey: .value)
                }
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

        public struct Reasoning: Equatable, Hashable, Sendable, Codable {
            public let supported: Bool?
            public let defaultValue: ReasoningDefault?
            public let toggle: Bool?
            public let effort: [ReasoningEffort]?
            public let budget: ReasoningBudget?
            public let updates: Bool?

            public init(
                supported: Bool? = nil,
                defaultValue: ReasoningDefault? = nil,
                toggle: Bool? = nil,
                effort: [ReasoningEffort]? = nil,
                budget: ReasoningBudget? = nil,
                updates: Bool? = nil
            ) {
                self.supported = supported
                self.defaultValue = defaultValue
                self.toggle = toggle
                self.effort = effort
                self.budget = budget
                self.updates = updates
            }

            enum CodingKeys: String, CodingKey {
                case supported
                case defaultValue = "default"
                case toggle
                case effort
                case budget
                case updates
            }
        }

        public enum CacheTarget: String, Equatable, Hashable, Sendable, Codable {
            case tools
            case system
            case messages
        }

        public enum ImplicitCache: Equatable, Hashable, Sendable, Codable {
            case enabled
            case detailed(ttl: [CacheTTL]?, minTokens: Int?)

            enum CodingKeys: String, CodingKey { case ttl, minTokens }

            public init(from decoder: Decoder) throws {
                if let b = try? decoder.singleValueContainer().decode(Bool.self), b {
                    self = .enabled
                    return
                }
                let c = try decoder.container(keyedBy: CodingKeys.self)
                self = .detailed(
                    ttl: try c.decodeIfPresent([CacheTTL].self, forKey: .ttl),
                    minTokens: try c.decodeIfPresent(Int.self, forKey: .minTokens)
                )
            }

            public func encode(to encoder: Encoder) throws {
                switch self {
                case .enabled:
                    var single = encoder.singleValueContainer()
                    try single.encode(true)
                case .detailed(let ttl, let minTokens):
                    var c = encoder.container(keyedBy: CodingKeys.self)
                    try c.encodeIfPresent(ttl, forKey: .ttl)
                    try c.encodeIfPresent(minTokens, forKey: .minTokens)
                }
            }
        }

        public enum ExplicitCache: Equatable, Hashable, Sendable, Codable {
            case enabled
            case detailed(ttl: [CacheTTL]?, maxBreakpoints: Int?, targets: [CacheTarget]?, minTokens: Int?)

            enum CodingKeys: String, CodingKey { case ttl, maxBreakpoints, targets, minTokens }

            public init(from decoder: Decoder) throws {
                if let b = try? decoder.singleValueContainer().decode(Bool.self), b {
                    self = .enabled
                    return
                }
                let c = try decoder.container(keyedBy: CodingKeys.self)
                self = .detailed(
                    ttl: try c.decodeIfPresent([CacheTTL].self, forKey: .ttl),
                    maxBreakpoints: try c.decodeIfPresent(Int.self, forKey: .maxBreakpoints),
                    targets: try c.decodeIfPresent([CacheTarget].self, forKey: .targets),
                    minTokens: try c.decodeIfPresent(Int.self, forKey: .minTokens)
                )
            }

            public func encode(to encoder: Encoder) throws {
                switch self {
                case .enabled:
                    var single = encoder.singleValueContainer()
                    try single.encode(true)
                case .detailed(let ttl, let maxBreakpoints, let targets, let minTokens):
                    var c = encoder.container(keyedBy: CodingKeys.self)
                    try c.encodeIfPresent(ttl, forKey: .ttl)
                    try c.encodeIfPresent(maxBreakpoints, forKey: .maxBreakpoints)
                    try c.encodeIfPresent(targets, forKey: .targets)
                    try c.encodeIfPresent(minTokens, forKey: .minTokens)
                }
            }
        }

        public enum Cache: Equatable, Hashable, Sendable, Codable {
            case disabled
            case config(implicit: ImplicitCache?, explicit: ExplicitCache?)

            enum CodingKeys: String, CodingKey { case implicit, explicit }

            public init(from decoder: Decoder) throws {
                if let b = try? decoder.singleValueContainer().decode(Bool.self), b == false {
                    self = .disabled
                    return
                }
                let c = try decoder.container(keyedBy: CodingKeys.self)
                self = .config(
                    implicit: try c.decodeIfPresent(ImplicitCache.self, forKey: .implicit),
                    explicit: try c.decodeIfPresent(ExplicitCache.self, forKey: .explicit)
                )
            }

            public func encode(to encoder: Encoder) throws {
                switch self {
                case .disabled:
                    var single = encoder.singleValueContainer()
                    try single.encode(false)
                case .config(let implicit, let explicit):
                    var c = encoder.container(keyedBy: CodingKeys.self)
                    try c.encodeIfPresent(implicit, forKey: .implicit)
                    try c.encodeIfPresent(explicit, forKey: .explicit)
                }
            }
        }

        public enum KnownServiceTier: String, Equatable, Hashable, Sendable, Codable {
            case flex
            case priority
            case fast
            case ultrafast
            case standby
        }

        public let tools: Tools?
        public let reasoning: Reasoning?
        public let cache: Cache?
        public let structuredOutput: Bool?
        public let temperature: Bool?
        public let topP: Bool?
        public let topK: Bool?
        public let systemUpdates: Bool?
        public let store: Bool?
        public let streamUsage: Bool?
        public let promptCacheKey: Bool?
        public let serviceTier: [OpenString<KnownServiceTier>]?

        public init(
            tools: Tools? = nil,
            reasoning: Reasoning? = nil,
            cache: Cache? = nil,
            structuredOutput: Bool? = nil,
            temperature: Bool? = nil,
            topP: Bool? = nil,
            topK: Bool? = nil,
            systemUpdates: Bool? = nil,
            store: Bool? = nil,
            streamUsage: Bool? = nil,
            promptCacheKey: Bool? = nil,
            serviceTier: [OpenString<KnownServiceTier>]? = nil
        ) {
            self.tools = tools
            self.reasoning = reasoning
            self.cache = cache
            self.structuredOutput = structuredOutput
            self.temperature = temperature
            self.topP = topP
            self.topK = topK
            self.systemUpdates = systemUpdates
            self.store = store
            self.streamUsage = streamUsage
            self.promptCacheKey = promptCacheKey
            self.serviceTier = serviceTier
        }
    }

    // parity: ai/src/schema/options.ts#LanguageModel [status=implemented hash=3d1130ddd2b3]
    public struct LanguageModel: Sendable {
        // parity: ai/src/schema/options.ts#LanguageModel.ConstructorInput [status=implemented hash=83e578bc3dc1]
        public struct ConstructorInput: Sendable {
            public let id: ModelID
            public let provider: ProviderID
            public let route: AIRoute.AnyRoute
            public let options: RequestOptions?
            public let capabilities: Capabilities?
            public let compatibility: LanguageModelCompatibility?

            public init(
                id: ModelID,
                provider: ProviderID,
                route: AIRoute.AnyRoute,
                options: RequestOptions? = nil,
                capabilities: Capabilities? = nil,
                compatibility: LanguageModelCompatibility? = nil
            ) {
                self.id = id
                self.provider = provider
                self.route = route
                self.options = options
                self.capabilities = capabilities
                self.compatibility = compatibility
            }
        }

        // parity: ai/src/schema/options.ts#LanguageModel.Input [status=implemented hash=3c2a74b4227a]
        public struct Input: Sendable {
            public let id: String
            public let provider: String
            public let route: AIRoute.AnyRoute
            public let options: RequestOptions?
            public let capabilities: Capabilities?
            public let compatibility: LanguageModelCompatibility.Input?

            public init(
                id: String,
                provider: String,
                route: AIRoute.AnyRoute,
                options: RequestOptions? = nil,
                capabilities: Capabilities? = nil,
                compatibility: LanguageModelCompatibility.Input? = nil
            ) {
                self.id = id
                self.provider = provider
                self.route = route
                self.options = options
                self.capabilities = capabilities
                self.compatibility = compatibility
            }

            public init(
                id: ModelID,
                provider: ProviderID,
                route: AIRoute.AnyRoute,
                options: RequestOptions? = nil,
                capabilities: Capabilities? = nil,
                compatibility: LanguageModelCompatibility.Input? = nil
            ) {
                self.id = id.rawValue
                self.provider = provider.rawValue
                self.route = route
                self.options = options
                self.capabilities = capabilities
                self.compatibility = compatibility
            }
        }

        public let id: ModelID
        public let provider: ProviderID
        public let route: AIRoute.AnyRoute
        public let options: RequestOptions?
        public let capabilities: Capabilities?
        public let compatibility: LanguageModelCompatibility?

        public init(_ input: ConstructorInput) {
            self.id = input.id
            self.provider = input.provider
            self.route = input.route
            self.options = input.options
            self.capabilities = input.capabilities
            self.compatibility = input.compatibility
        }

        // parity: ai/src/schema/options.ts#LanguageModel.make [status=implemented hash=e9c0c0b35e4d]
        public static func make(_ input: Input) -> LanguageModel {
            LanguageModel(ConstructorInput(
                id: ModelID.make(input.id),
                provider: ProviderID.make(input.provider),
                route: input.route,
                options: AISchema.mergeRequestOptions(input.route.options, input.options),
                capabilities: input.capabilities,
                compatibility: input.compatibility.map(LanguageModelCompatibility.make)
            ))
        }

        // parity: ai/src/schema/options.ts#LanguageModel.input [status=implemented hash=2fe5e1872bc2]
        public static func input(_ model: LanguageModel) -> ConstructorInput {
            ConstructorInput(
                id: model.id,
                provider: model.provider,
                route: model.route,
                options: model.options,
                capabilities: model.capabilities,
                compatibility: model.compatibility
            )
        }

        // parity: ai/src/schema/options.ts#LanguageModel.update [status=implemented hash=6366a64d8a73]
        public static func update(
            _ model: LanguageModel,
            id: String? = nil,
            provider: String? = nil,
            route: AIRoute.AnyRoute? = nil,
            options: RequestOptions? = nil,
            capabilities: Capabilities? = nil,
            compatibility: LanguageModelCompatibility.Input? = nil
        ) -> LanguageModel {
            if id == nil && provider == nil && route == nil && options == nil && capabilities == nil && compatibility == nil {
                return model
            }
            return LanguageModel.make(Input(
                id: id ?? model.id.rawValue,
                provider: provider ?? model.provider.rawValue,
                route: route ?? model.route,
                options: options ?? model.options,
                capabilities: capabilities ?? model.capabilities,
                compatibility: compatibility ?? model.compatibility
            ))
        }
    }

    // parity: ai/src/schema/options.ts#LanguageModelInput [status=implemented hash=7b472ce8afbc]
    public typealias LanguageModelInput = LanguageModel.Input

    // parity: ai/src/schema/options.ts#LanguageModelProviderOptions [status=adapted hash=12766d0ef36b]
    public typealias LanguageModelProviderOptions = ProviderOptions

    // parity: ai/src/schema/options.ts#LanguageModelSchema [status=adapted hash=db647a905339]
    public static func LanguageModelSchema(_ value: Any) -> LanguageModel? {
        value as? LanguageModel
    }

    /// Provider cache lifetime such as `"5m"`, `"30m"`, `"1h"` or `"24h"`.
    // parity: ai/src/schema/options.ts#CacheTTL [status=implemented hash=e25cfb3439d4]
    public struct CacheTTL: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public init?(rawValue: String) {
            guard Self.isValid(rawValue) else { return nil }
            self.rawValue = rawValue
        }

        public var description: String { rawValue }

        public static func isValid(_ value: String) -> Bool {
            let bytes = Array(value.utf8)
            var i = 0
            while i < bytes.count && bytes[i] >= 0x30 && bytes[i] <= 0x39 {
                i += 1
            }
            guard i > 0, i < bytes.count else { return false }
            let suffix = bytes[i...]
            if suffix.count == 2 {
                return suffix[i] == 0x6D && suffix[i + 1] == 0x73 // "ms"
            }
            if suffix.count == 1 {
                let c = suffix[i]
                return c == 0x73 || c == 0x6D || c == 0x68 || c == 0x64 // s, m, h, d
            }
            return false
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard Self.isValid(value) else {
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

    // parity: ai/src/schema/options.ts#CacheHint [status=implemented hash=63d7c8ea261d]
    public struct CacheHint: Equatable, Hashable, Sendable, Codable {
        public enum Kind: String, Equatable, Hashable, Sendable, Codable {
            case ephemeral
            case persistent
        }

        public let type: Kind
        public let ttl: CacheTTL?

        public init(type: Kind, ttl: CacheTTL? = nil) {
            self.type = type
            self.ttl = ttl
        }
    }

    // parity: ai/src/schema/options.ts#CachePolicyObject [status=implemented hash=693b5f84a0c5]
    public struct CachePolicyObject: Equatable, Hashable, Sendable, Codable {
        public enum MessagesStrategy: Equatable, Hashable, Sendable, Codable {
            case latestUserMessage
            case latestAssistant
            case tail(Int)

            enum CodingKeys: String, CodingKey { case tail }

            public init(from decoder: Decoder) throws {
                if let single = try? decoder.singleValueContainer(), let literal = try? single.decode(String.self) {
                    switch literal {
                    case "latest-user-message":
                        self = .latestUserMessage
                        return
                    case "latest-assistant":
                        self = .latestAssistant
                        return
                    default:
                        throw DecodingError.dataCorruptedError(
                            in: single,
                            debugDescription: "Unknown CachePolicyObject.messages literal '\(literal)'"
                        )
                    }
                }
                let container = try decoder.container(keyedBy: CodingKeys.self)
                let count = try container.decode(Int.self, forKey: .tail)
                guard count >= 0 else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .tail,
                        in: container,
                        debugDescription: "CachePolicyObject.messages.tail must be >= 0, got \(count)"
                    )
                }
                self = .tail(count)
            }

            public func encode(to encoder: Encoder) throws {
                switch self {
                case .latestUserMessage:
                    var single = encoder.singleValueContainer()
                    try single.encode("latest-user-message")
                case .latestAssistant:
                    var single = encoder.singleValueContainer()
                    try single.encode("latest-assistant")
                case .tail(let count):
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encode(count, forKey: .tail)
                }
            }
        }

        public let tools: Bool?
        public let system: Bool?
        public let messages: MessagesStrategy?
        public let ttl: CacheTTL?

        public init(
            tools: Bool? = nil,
            system: Bool? = nil,
            messages: MessagesStrategy? = nil,
            ttl: CacheTTL? = nil
        ) {
            self.tools = tools
            self.system = system
            self.messages = messages
            self.ttl = ttl
        }
    }

    // parity: ai/src/schema/options.ts#CachePolicy [status=implemented hash=7c413cbf0ca6]
    public enum CachePolicy: Equatable, Hashable, Sendable, Codable {
        case auto
        case none
        case object(CachePolicyObject)

        public init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(), let literal = try? single.decode(String.self) {
                switch literal {
                case "auto": self = .auto; return
                case "none": self = .none; return
                default:
                    throw DecodingError.dataCorruptedError(
                        in: single,
                        debugDescription: "Unknown CachePolicy literal '\(literal)'"
                    )
                }
            }
            self = .object(try CachePolicyObject(from: decoder))
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .auto:
                var single = encoder.singleValueContainer()
                try single.encode("auto")
            case .none:
                var single = encoder.singleValueContainer()
                try single.encode("none")
            case .object(let obj):
                try obj.encode(to: encoder)
            }
        }
    }

    // MARK: - src/schema/messages.ts

    // parity: ai/src/schema/messages.ts#MessageRole [status=implemented hash=c4fc4939fdd4]
    public enum MessageRole: String, Equatable, Hashable, Sendable, Codable {
        case system
        case user
        case assistant
        case tool
    }

    // parity: ai/src/schema/messages.ts#SystemPart [status=implemented hash=a223cae12fa7]
    public struct SystemPart: Equatable, Hashable, Sendable, Codable {
        public let text: String
        public let cache: CacheHint?
        public let metadata: [String: JSONValue]?

        public init(text: String, cache: CacheHint? = nil, metadata: [String: JSONValue]? = nil) {
            self.text = text
            self.cache = cache
            self.metadata = metadata
        }

        public static func make(_ text: String) -> SystemPart {
            SystemPart(text: text)
        }

        public static func content(_ input: String?) -> [SystemPart] {
            guard let input else { return [] }
            return [make(input)]
        }

        public static func content(_ input: SystemPart) -> [SystemPart] {
            [input]
        }

        public static func content(_ input: [SystemPart]) -> [SystemPart] {
            input
        }

        enum CodingKeys: String, CodingKey { case type, text, cache, metadata }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            guard type == "text" else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Expected literal 'text', got '\(type)'")
            }
            self.text = try c.decode(String.self, forKey: .text)
            self.cache = try c.decodeIfPresent(CacheHint.self, forKey: .cache)
            self.metadata = try c.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("text", forKey: .type)
            try c.encode(text, forKey: .text)
            try c.encodeIfPresent(cache, forKey: .cache)
            try c.encodeIfPresent(metadata, forKey: .metadata)
        }
    }

    // parity: ai/src/schema/messages.ts#TextPart [status=implemented hash=970eb32ce874]
    public struct TextPart: Equatable, Hashable, Sendable, Codable {
        public let text: String
        public let cache: CacheHint?
        public let providerMetadata: ProviderMetadata?

        public init(text: String, cache: CacheHint? = nil, providerMetadata: ProviderMetadata? = nil) {
            self.text = text
            self.cache = cache
            self.providerMetadata = providerMetadata
        }

        enum CodingKeys: String, CodingKey { case type, text, cache, providerMetadata }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            guard type == "text" else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Expected literal 'text', got '\(type)'")
            }
            self.text = try c.decode(String.self, forKey: .text)
            self.cache = try c.decodeIfPresent(CacheHint.self, forKey: .cache)
            self.providerMetadata = try c.decodeIfPresent(ProviderMetadata.self, forKey: .providerMetadata)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("text", forKey: .type)
            try c.encode(text, forKey: .text)
            try c.encodeIfPresent(cache, forKey: .cache)
            try c.encodeIfPresent(providerMetadata, forKey: .providerMetadata)
        }
    }

    // parity: ai/src/schema/messages.ts#MediaPart [status=implemented hash=a5efbad44794]
    public struct MediaPart: Equatable, Sendable, Codable {
        public let media: AIMedia.Asset
        public let filename: String?
        public let cache: CacheHint?
        public let providerMetadata: ProviderMetadata?

        public init(
            media: AIMedia.Asset,
            filename: String? = nil,
            cache: CacheHint? = nil,
            providerMetadata: ProviderMetadata? = nil
        ) {
            self.media = media
            self.filename = filename
            self.cache = cache
            self.providerMetadata = providerMetadata
        }

        enum CodingKeys: String, CodingKey { case type, media, filename, cache, providerMetadata }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            guard type == "media" else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Expected literal 'media', got '\(type)'")
            }
            self.media = try c.decode(AIMedia.Asset.self, forKey: .media)
            self.filename = try c.decodeIfPresent(String.self, forKey: .filename)
            self.cache = try c.decodeIfPresent(CacheHint.self, forKey: .cache)
            self.providerMetadata = try c.decodeIfPresent(ProviderMetadata.self, forKey: .providerMetadata)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("media", forKey: .type)
            try c.encode(media, forKey: .media)
            try c.encodeIfPresent(filename, forKey: .filename)
            try c.encodeIfPresent(cache, forKey: .cache)
            try c.encodeIfPresent(providerMetadata, forKey: .providerMetadata)
        }
    }

    // parity: ai/src/schema/messages.ts#MediaPartInput [status=implemented hash=e5ceb2c36953]
    public struct MediaPartInput: Sendable {
        public let media: AIMedia.Input
        public let mediaType: String?
        public let filename: String?
        public let cache: CacheHint?
        public let providerMetadata: ProviderMetadata?

        public init(
            media: AIMedia.Input,
            mediaType: String? = nil,
            filename: String? = nil,
            cache: CacheHint? = nil,
            providerMetadata: ProviderMetadata? = nil
        ) {
            self.media = media
            self.mediaType = mediaType
            self.filename = filename
            self.cache = cache
            self.providerMetadata = providerMetadata
        }

        public func toMediaPart() throws(AIError) -> MediaPart {
            MediaPart(
                media: try AIMedia.make(media, mediaType: mediaType),
                filename: filename,
                cache: cache,
                providerMetadata: providerMetadata
            )
        }
    }

    // parity: ai/src/schema/messages.ts#ToolResultValue [status=implemented hash=994970039f30]
    public enum ToolResultValue: Equatable, Hashable, Sendable, Codable {
        case json(JSONValue)
        case text(JSONValue)
        case error(JSONValue)
        case content([ToolSchema.Content])

        public enum Kind: String, Equatable, Hashable, Sendable, Codable {
            case json
            case text
            case error
            case content
        }

        public var kind: Kind {
            switch self {
            case .json: .json
            case .text: .text
            case .error: .error
            case .content: .content
            }
        }

        public static func make(_ value: ToolResultValue) -> ToolResultValue {
            value
        }

        public static func make(_ value: JSONValue, type: Kind = .json) -> ToolResultValue {
            switch type {
            case .json: return .json(value)
            case .text: return .text(value)
            case .error: return .error(value)
            case .content: return .content([])
            }
        }

        public static func make(content: [ToolSchema.Content]) -> ToolResultValue {
            .content(content)
        }

        enum CodingKeys: String, CodingKey { case type, value }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            switch type {
            case "json": self = .json(try c.decode(JSONValue.self, forKey: .value))
            case "text": self = .text(try c.decode(JSONValue.self, forKey: .value))
            case "error": self = .error(try c.decode(JSONValue.self, forKey: .value))
            case "content": self = .content(try c.decode([ToolSchema.Content].self, forKey: .value))
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown ToolResultValue type '\(type)'")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(kind.rawValue, forKey: .type)
            switch self {
            case .json(let v), .text(let v), .error(let v):
                try c.encode(v, forKey: .value)
            case .content(let parts):
                try c.encode(parts, forKey: .value)
            }
        }
    }

    // parity: ai/src/schema/messages.ts#ToolOutput [status=implemented hash=cffb86f12b9b]
    public struct ToolOutput: Equatable, Hashable, Sendable, Codable {
        public let structured: JSONValue
        public let content: [ToolSchema.Content]

        public init(structured: JSONValue, content: [ToolSchema.Content] = []) {
            self.structured = structured
            self.content = content
        }

        public static func make(_ structured: JSONValue, content: [ToolSchema.Content] = []) -> ToolOutput {
            ToolOutput(structured: structured, content: content)
        }

        public static func fromResultValue(_ result: ToolResultValue) -> ToolOutput? {
            switch result {
            case .json(let v):
                return ToolOutput(structured: v, content: [])
            case .text(let v):
                return ToolOutput(structured: .object([:]), content: [.text(ToolSchema.TextContent(text: toolResultText(v)))])
            case .content(let parts):
                return ToolOutput(structured: .object([:]), content: parts)
            case .error:
                return nil
            }
        }

        public static func toResultValue(_ output: ToolOutput) -> ToolResultValue {
            if output.content.isEmpty {
                return .json(output.structured)
            }
            if output.content.count == 1, case .text(let textPart) = output.content[0] {
                return .text(.string(textPart.text))
            }
            return .content(output.content)
        }

        private static func toolResultText(_ value: JSONValue) -> String {
            if case .string(let s) = value { return s }
            return (try? AIUtils.encodeJson(value)) ?? String(describing: value)
        }
    }

    // parity: ai/src/schema/messages.ts#ToolCallPart [status=implemented hash=65ad8cb9ccc6]
    public struct ToolCallPart: Equatable, Hashable, Sendable, Codable {
        public let id: ToolCallID
        public let name: String
        public let namespace: String?
        public let input: JSONValue
        public let providerExecuted: Bool?
        public let cache: CacheHint?
        public let providerMetadata: ProviderMetadata?

        public init(
            id: ToolCallID,
            name: String,
            namespace: String? = nil,
            input: JSONValue,
            providerExecuted: Bool? = nil,
            cache: CacheHint? = nil,
            providerMetadata: ProviderMetadata? = nil
        ) {
            self.id = id
            self.name = name
            self.namespace = namespace
            self.input = input
            self.providerExecuted = providerExecuted
            self.cache = cache
            self.providerMetadata = providerMetadata
        }

        public static func make(
            id: ToolCallID,
            name: String,
            namespace: String? = nil,
            input: JSONValue,
            providerExecuted: Bool? = nil,
            cache: CacheHint? = nil,
            providerMetadata: ProviderMetadata? = nil
        ) -> ToolCallPart {
            ToolCallPart(
                id: id,
                name: name,
                namespace: namespace,
                input: input,
                providerExecuted: providerExecuted,
                cache: cache,
                providerMetadata: providerMetadata
            )
        }

        enum CodingKeys: String, CodingKey {
            case type, id, name, namespace, input, providerExecuted, cache, providerMetadata
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            guard type == "tool-call" else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Expected literal 'tool-call', got '\(type)'")
            }
            self.id = try c.decode(ToolCallID.self, forKey: .id)
            self.name = try c.decode(String.self, forKey: .name)
            self.namespace = try c.decodeIfPresent(String.self, forKey: .namespace)
            self.input = try c.decodeIfPresent(JSONValue.self, forKey: .input) ?? .null
            self.providerExecuted = try c.decodeIfPresent(Bool.self, forKey: .providerExecuted)
            self.cache = try c.decodeIfPresent(CacheHint.self, forKey: .cache)
            self.providerMetadata = try c.decodeIfPresent(ProviderMetadata.self, forKey: .providerMetadata)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("tool-call", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(namespace, forKey: .namespace)
            try c.encode(input, forKey: .input)
            try c.encodeIfPresent(providerExecuted, forKey: .providerExecuted)
            try c.encodeIfPresent(cache, forKey: .cache)
            try c.encodeIfPresent(providerMetadata, forKey: .providerMetadata)
        }
    }

    // parity: ai/src/schema/messages.ts#ToolResultPart [status=implemented hash=452386d6931d]
    public struct ToolResultPart: Equatable, Hashable, Sendable, Codable {
        public let id: ToolCallID
        public let name: String
        public let namespace: String?
        public let result: ToolResultValue
        public let providerExecuted: Bool?
        public let cache: CacheHint?
        public let providerMetadata: ProviderMetadata?

        public init(
            id: ToolCallID,
            name: String,
            namespace: String? = nil,
            result: ToolResultValue,
            providerExecuted: Bool? = nil,
            cache: CacheHint? = nil,
            providerMetadata: ProviderMetadata? = nil
        ) {
            self.id = id
            self.name = name
            self.namespace = namespace
            self.result = result
            self.providerExecuted = providerExecuted
            self.cache = cache
            self.providerMetadata = providerMetadata
        }

        public static func make(
            id: ToolCallID,
            name: String,
            namespace: String? = nil,
            result: ToolResultValue,
            providerExecuted: Bool? = nil,
            cache: CacheHint? = nil,
            providerMetadata: ProviderMetadata? = nil
        ) -> ToolResultPart {
            ToolResultPart(
                id: id,
                name: name,
                namespace: namespace,
                result: result,
                providerExecuted: providerExecuted,
                cache: cache,
                providerMetadata: providerMetadata
            )
        }

        public static func make(
            id: ToolCallID,
            name: String,
            namespace: String? = nil,
            result: JSONValue,
            resultType: ToolResultValue.Kind = .json,
            providerExecuted: Bool? = nil,
            cache: CacheHint? = nil,
            providerMetadata: ProviderMetadata? = nil
        ) -> ToolResultPart {
            ToolResultPart(
                id: id,
                name: name,
                namespace: namespace,
                result: ToolResultValue.make(result, type: resultType),
                providerExecuted: providerExecuted,
                cache: cache,
                providerMetadata: providerMetadata
            )
        }

        enum CodingKeys: String, CodingKey {
            case type, id, name, namespace, result, providerExecuted, cache, providerMetadata
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            guard type == "tool-result" else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Expected literal 'tool-result', got '\(type)'")
            }
            self.id = try c.decode(ToolCallID.self, forKey: .id)
            self.name = try c.decode(String.self, forKey: .name)
            self.namespace = try c.decodeIfPresent(String.self, forKey: .namespace)
            self.result = try c.decode(ToolResultValue.self, forKey: .result)
            self.providerExecuted = try c.decodeIfPresent(Bool.self, forKey: .providerExecuted)
            self.cache = try c.decodeIfPresent(CacheHint.self, forKey: .cache)
            self.providerMetadata = try c.decodeIfPresent(ProviderMetadata.self, forKey: .providerMetadata)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("tool-result", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(namespace, forKey: .namespace)
            try c.encode(result, forKey: .result)
            try c.encodeIfPresent(providerExecuted, forKey: .providerExecuted)
            try c.encodeIfPresent(cache, forKey: .cache)
            try c.encodeIfPresent(providerMetadata, forKey: .providerMetadata)
        }
    }

    // parity: ai/src/schema/messages.ts#ReasoningPart [status=implemented hash=a991ddf8f084]
    public struct ReasoningPart: Equatable, Hashable, Sendable, Codable {
        public let text: String
        public let encrypted: String?
        public let cache: CacheHint?
        public let providerMetadata: ProviderMetadata?

        public init(
            text: String,
            encrypted: String? = nil,
            cache: CacheHint? = nil,
            providerMetadata: ProviderMetadata? = nil
        ) {
            self.text = text
            self.encrypted = encrypted
            self.cache = cache
            self.providerMetadata = providerMetadata
        }

        enum CodingKeys: String, CodingKey { case type, text, encrypted, cache, providerMetadata }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            guard type == "reasoning" else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Expected literal 'reasoning', got '\(type)'")
            }
            self.text = try c.decode(String.self, forKey: .text)
            self.encrypted = try c.decodeIfPresent(String.self, forKey: .encrypted)
            self.cache = try c.decodeIfPresent(CacheHint.self, forKey: .cache)
            self.providerMetadata = try c.decodeIfPresent(ProviderMetadata.self, forKey: .providerMetadata)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("reasoning", forKey: .type)
            try c.encode(text, forKey: .text)
            try c.encodeIfPresent(encrypted, forKey: .encrypted)
            try c.encodeIfPresent(cache, forKey: .cache)
            try c.encodeIfPresent(providerMetadata, forKey: .providerMetadata)
        }
    }

    /// A provider-generated context checkpoint, distinct from visible assistant text.
    // parity: ai/src/schema/messages.ts#CompactionPart [status=implemented hash=20e13ab805e1]
    public struct CompactionPart: Equatable, Hashable, Sendable, Codable {
        public enum Content: Equatable, Hashable, Sendable {
            case encrypted(String)
            case text(String?)
        }

        public let provider: ProviderID
        public let id: String?
        public let content: Content

        public var encrypted: String? {
            if case .encrypted(let s) = content { return s }
            return nil
        }

        public var text: String? {
            if case .text(let s) = content { return s }
            return nil
        }

        public var hasTextField: Bool {
            if case .text = content { return true }
            return false
        }

        public init(provider: ProviderID, id: String? = nil, content: Content) {
            self.provider = provider
            self.id = id
            self.content = content
        }

        public static func make(provider: ProviderID, id: String? = nil, encrypted: String) -> CompactionPart {
            CompactionPart(provider: provider, id: id, content: .encrypted(encrypted))
        }

        public static func make(provider: ProviderID, id: String? = nil, text: String?) -> CompactionPart {
            CompactionPart(provider: provider, id: id, content: .text(text))
        }

        enum CodingKeys: String, CodingKey { case type, provider, id, encrypted, text }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            guard type == "compaction" else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Expected literal 'compaction', got '\(type)'")
            }
            self.provider = try c.decode(ProviderID.self, forKey: .provider)
            self.id = try c.decodeIfPresent(String.self, forKey: .id)
            let hasEncrypted = c.contains(.encrypted) && (try? c.decodeNil(forKey: .encrypted)) == false
            let hasText = c.contains(.text)
            guard hasEncrypted != hasText else {
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: c,
                    debugDescription: "Compaction requires either encrypted content or a summary"
                )
            }
            if hasEncrypted {
                self.content = .encrypted(try c.decode(String.self, forKey: .encrypted))
            } else {
                if try c.decodeNil(forKey: .text) {
                    self.content = .text(nil)
                } else {
                    self.content = .text(try c.decode(String.self, forKey: .text))
                }
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("compaction", forKey: .type)
            try c.encode(provider, forKey: .provider)
            try c.encodeIfPresent(id, forKey: .id)
            switch content {
            case .encrypted(let s):
                try c.encode(s, forKey: .encrypted)
            case .text(let s):
                if let s {
                    try c.encode(s, forKey: .text)
                } else {
                    try c.encodeNil(forKey: .text)
                }
            }
        }
    }

    /// Reasoning effort changed here, from `previous` to `effort`; `nil` is the model default.
    // parity: ai/src/schema/messages.ts#EffortPart [status=implemented hash=5ddf7da1464a]
    public struct EffortPart: Equatable, Hashable, Sendable, Codable {
        public let effort: ReasoningEffort?
        public let previous: ReasoningEffort?

        public init(effort: ReasoningEffort? = nil, previous: ReasoningEffort? = nil) {
            self.effort = effort
            self.previous = previous
        }

        enum CodingKeys: String, CodingKey { case type, effort, previous }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            guard type == "effort" else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Expected literal 'effort', got '\(type)'")
            }
            self.effort = try c.decodeIfPresent(ReasoningEffort.self, forKey: .effort)
            self.previous = try c.decodeIfPresent(ReasoningEffort.self, forKey: .previous)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("effort", forKey: .type)
            try c.encodeIfPresent(effort, forKey: .effort)
            try c.encodeIfPresent(previous, forKey: .previous)
        }
    }

    // parity: ai/src/schema/messages.ts#ContentPart [status=implemented hash=4cb0880d6ce5]
    public enum ContentPart: Equatable, Sendable, Codable {
        case text(TextPart)
        case media(MediaPart)
        case toolCall(ToolCallPart)
        case toolResult(ToolResultPart)
        case reasoning(ReasoningPart)
        case compaction(CompactionPart)
        case effort(EffortPart)

        public var cache: CacheHint? {
            switch self {
            case .text(let p): p.cache
            case .media(let p): p.cache
            case .toolCall(let p): p.cache
            case .toolResult(let p): p.cache
            case .reasoning(let p): p.cache
            case .compaction, .effort: nil
            }
        }

        public var isCacheable: Bool {
            switch self {
            case .compaction, .effort: return false
            default: return true
            }
        }

        public func withCache(_ hint: CacheHint) -> ContentPart {
            switch self {
            case .text(let p):
                return .text(TextPart(text: p.text, cache: hint, providerMetadata: p.providerMetadata))
            case .media(let p):
                return .media(MediaPart(media: p.media, filename: p.filename, cache: hint, providerMetadata: p.providerMetadata))
            case .toolCall(let p):
                return .toolCall(ToolCallPart(id: p.id, name: p.name, namespace: p.namespace, input: p.input, providerExecuted: p.providerExecuted, cache: hint, providerMetadata: p.providerMetadata))
            case .toolResult(let p):
                return .toolResult(ToolResultPart(id: p.id, name: p.name, namespace: p.namespace, result: p.result, providerExecuted: p.providerExecuted, cache: hint, providerMetadata: p.providerMetadata))
            case .reasoning(let p):
                return .reasoning(ReasoningPart(text: p.text, encrypted: p.encrypted, cache: hint, providerMetadata: p.providerMetadata))
            case .compaction, .effort:
                return self
            }
        }

        enum TagKeys: String, CodingKey { case type }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: TagKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            switch type {
            case "text": self = .text(try TextPart(from: decoder))
            case "media": self = .media(try MediaPart(from: decoder))
            case "tool-call": self = .toolCall(try ToolCallPart(from: decoder))
            case "tool-result": self = .toolResult(try ToolResultPart(from: decoder))
            case "reasoning": self = .reasoning(try ReasoningPart(from: decoder))
            case "compaction": self = .compaction(try CompactionPart(from: decoder))
            case "effort": self = .effort(try EffortPart(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown ContentPart type '\(type)'")
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .text(let p): try p.encode(to: encoder)
            case .media(let p): try p.encode(to: encoder)
            case .toolCall(let p): try p.encode(to: encoder)
            case .toolResult(let p): try p.encode(to: encoder)
            case .reasoning(let p): try p.encode(to: encoder)
            case .compaction(let p): try p.encode(to: encoder)
            case .effort(let p): try p.encode(to: encoder)
            }
        }
    }

    // parity: ai/src/schema/messages.ts#ContentPartInput [status=implemented hash=5d0c1135f493]
    public enum ContentPartInput: Sendable {
        case text(TextPart)
        case media(MediaPartInput)
        case toolCall(ToolCallPart)
        case toolResult(ToolResultPart)
        case reasoning(ReasoningPart)
        case compaction(CompactionPart)
        case effort(EffortPart)

        public func toContentPart() throws(AIError) -> ContentPart {
            switch self {
            case .text(let p): .text(p)
            case .media(let p): .media(try p.toMediaPart())
            case .toolCall(let p): .toolCall(p)
            case .toolResult(let p): .toolResult(p)
            case .reasoning(let p): .reasoning(p)
            case .compaction(let p): .compaction(p)
            case .effort(let p): .effort(p)
            }
        }
    }

    /// Tools changed here: `add` appends or redefines tools by name, `remove` drops them by name.
    // parity: ai/src/schema/messages.ts#ToolChanges [status=implemented hash=2ec9681ac60d]
    public struct ToolChanges: Equatable, Hashable, Sendable, Codable {
        public let add: [ToolEntry]
        public let remove: [String]

        public init(add: [ToolEntry] = [], remove: [String] = []) {
            self.add = add
            self.remove = remove
        }
    }

    // parity: ai/src/schema/messages.ts#SystemMessage [status=implemented hash=1076fd909c3e]
    public struct SystemMessage: Equatable, Hashable, Sendable, Codable {
        public enum Part: Equatable, Hashable, Sendable, Codable {
            case text(TextPart)
            case effort(EffortPart)

            public var asContentPart: ContentPart {
                switch self {
                case .text(let p): .text(p)
                case .effort(let p): .effort(p)
                }
            }

            enum TagKeys: String, CodingKey { case type }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: TagKeys.self)
                let type = try c.decode(String.self, forKey: .type)
                switch type {
                case "text": self = .text(try TextPart(from: decoder))
                case "effort": self = .effort(try EffortPart(from: decoder))
                default:
                    throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown SystemMessage part '\(type)'")
                }
            }

            public func encode(to encoder: Encoder) throws {
                switch self {
                case .text(let p): try p.encode(to: encoder)
                case .effort(let p): try p.encode(to: encoder)
                }
            }
        }

        public let id: String?
        public let content: [Part]
        public let tools: ToolChanges?

        public init(id: String? = nil, content: [Part], tools: ToolChanges? = nil) {
            self.id = id
            self.content = content
            self.tools = tools
        }

        enum CodingKeys: String, CodingKey { case id, role, content, tools }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let role = try c.decode(String.self, forKey: .role)
            guard role == "system" else {
                throw DecodingError.dataCorruptedError(forKey: .role, in: c, debugDescription: "Expected role 'system', got '\(role)'")
            }
            self.id = try c.decodeIfPresent(String.self, forKey: .id)
            self.content = try c.decode([Part].self, forKey: .content)
            self.tools = try c.decodeIfPresent(ToolChanges.self, forKey: .tools)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(id, forKey: .id)
            try c.encode("system", forKey: .role)
            try c.encode(content, forKey: .content)
            try c.encodeIfPresent(tools, forKey: .tools)
        }
    }

    // parity: ai/src/schema/messages.ts#UserMessage [status=implemented hash=28df469200af]
    public struct UserMessage: Equatable, Sendable, Codable {
        public enum Part: Equatable, Sendable, Codable {
            case text(TextPart)
            case media(MediaPart)

            public var asContentPart: ContentPart {
                switch self {
                case .text(let p): .text(p)
                case .media(let p): .media(p)
                }
            }

            enum TagKeys: String, CodingKey { case type }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: TagKeys.self)
                let type = try c.decode(String.self, forKey: .type)
                switch type {
                case "text": self = .text(try TextPart(from: decoder))
                case "media": self = .media(try MediaPart(from: decoder))
                default:
                    throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown UserMessage part '\(type)'")
                }
            }

            public func encode(to encoder: Encoder) throws {
                switch self {
                case .text(let p): try p.encode(to: encoder)
                case .media(let p): try p.encode(to: encoder)
                }
            }
        }

        public let id: String?
        public let content: [Part]
        public let providerMetadata: ProviderMetadata?

        public init(id: String? = nil, content: [Part], providerMetadata: ProviderMetadata? = nil) {
            self.id = id
            self.content = content
            self.providerMetadata = providerMetadata
        }

        enum CodingKeys: String, CodingKey { case id, role, content, providerMetadata }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let role = try c.decode(String.self, forKey: .role)
            guard role == "user" else {
                throw DecodingError.dataCorruptedError(forKey: .role, in: c, debugDescription: "Expected role 'user', got '\(role)'")
            }
            self.id = try c.decodeIfPresent(String.self, forKey: .id)
            self.content = try c.decode([Part].self, forKey: .content)
            self.providerMetadata = try c.decodeIfPresent(ProviderMetadata.self, forKey: .providerMetadata)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(id, forKey: .id)
            try c.encode("user", forKey: .role)
            try c.encode(content, forKey: .content)
            try c.encodeIfPresent(providerMetadata, forKey: .providerMetadata)
        }
    }

    // parity: ai/src/schema/messages.ts#AssistantMessage [status=implemented hash=ad61f5bf70e6]
    public struct AssistantMessage: Equatable, Sendable, Codable {
        public enum Part: Equatable, Sendable, Codable {
            case text(TextPart)
            case reasoning(ReasoningPart)
            case toolCall(ToolCallPart)
            case toolResult(ToolResultPart)
            case media(MediaPart)
            case compaction(CompactionPart)

            public var asContentPart: ContentPart {
                switch self {
                case .text(let p): .text(p)
                case .reasoning(let p): .reasoning(p)
                case .toolCall(let p): .toolCall(p)
                case .toolResult(let p): .toolResult(p)
                case .media(let p): .media(p)
                case .compaction(let p): .compaction(p)
                }
            }

            enum TagKeys: String, CodingKey { case type }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: TagKeys.self)
                let type = try c.decode(String.self, forKey: .type)
                switch type {
                case "text": self = .text(try TextPart(from: decoder))
                case "reasoning": self = .reasoning(try ReasoningPart(from: decoder))
                case "tool-call": self = .toolCall(try ToolCallPart(from: decoder))
                case "tool-result": self = .toolResult(try ToolResultPart(from: decoder))
                case "media": self = .media(try MediaPart(from: decoder))
                case "compaction": self = .compaction(try CompactionPart(from: decoder))
                default:
                    throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown AssistantMessage part '\(type)'")
                }
            }

            public func encode(to encoder: Encoder) throws {
                switch self {
                case .text(let p): try p.encode(to: encoder)
                case .reasoning(let p): try p.encode(to: encoder)
                case .toolCall(let p): try p.encode(to: encoder)
                case .toolResult(let p): try p.encode(to: encoder)
                case .media(let p): try p.encode(to: encoder)
                case .compaction(let p): try p.encode(to: encoder)
                }
            }
        }

        public let id: String?
        public let content: [Part]
        public let providerMetadata: ProviderMetadata?

        public init(id: String? = nil, content: [Part], providerMetadata: ProviderMetadata? = nil) {
            self.id = id
            self.content = content
            self.providerMetadata = providerMetadata
        }

        enum CodingKeys: String, CodingKey { case id, role, content, providerMetadata }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let role = try c.decode(String.self, forKey: .role)
            guard role == "assistant" else {
                throw DecodingError.dataCorruptedError(forKey: .role, in: c, debugDescription: "Expected role 'assistant', got '\(role)'")
            }
            self.id = try c.decodeIfPresent(String.self, forKey: .id)
            self.content = try c.decode([Part].self, forKey: .content)
            self.providerMetadata = try c.decodeIfPresent(ProviderMetadata.self, forKey: .providerMetadata)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(id, forKey: .id)
            try c.encode("assistant", forKey: .role)
            try c.encode(content, forKey: .content)
            try c.encodeIfPresent(providerMetadata, forKey: .providerMetadata)
        }
    }

    // parity: ai/src/schema/messages.ts#ToolMessage [status=implemented hash=55878c7830a9]
    public struct ToolMessage: Equatable, Hashable, Sendable, Codable {
        public let id: String?
        public let content: [ToolResultPart]

        public init(id: String? = nil, content: [ToolResultPart]) {
            self.id = id
            self.content = content
        }

        enum CodingKeys: String, CodingKey { case id, role, content }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let role = try c.decode(String.self, forKey: .role)
            guard role == "tool" else {
                throw DecodingError.dataCorruptedError(forKey: .role, in: c, debugDescription: "Expected role 'tool', got '\(role)'")
            }
            self.id = try c.decodeIfPresent(String.self, forKey: .id)
            self.content = try c.decode([ToolResultPart].self, forKey: .content)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(id, forKey: .id)
            try c.encode("tool", forKey: .role)
            try c.encode(content, forKey: .content)
        }
    }

    // parity: ai/src/schema/messages.ts#Message [status=implemented hash=a7e9d5250abd]
    public enum Message: Equatable, Sendable, Codable {
        case system(SystemMessage)
        case user(UserMessage)
        case assistant(AssistantMessage)
        case tool(ToolMessage)

        // parity: ai/src/schema/messages.ts#Message.ContentInput [status=implemented hash=2a6d7594cb80]
        public enum ContentInput<Part: Sendable>: Sendable {
            case text(String)
            case part(Part)
            case parts([Part])
        }

        // parity: ai/src/schema/messages.ts#Message.SystemContentInput [status=implemented hash=f483ce9ff494]
        public typealias SystemContentInput = ContentInput<TextPart>

        // parity: ai/src/schema/messages.ts#Message.UserContentInput [status=implemented hash=97eadc7ab5a5]
        public typealias UserContentInput = ContentInput<UserMessage.Part>

        // parity: ai/src/schema/messages.ts#Message.AssistantContentInput [status=implemented hash=7c07c52328ba]
        public typealias AssistantContentInput = ContentInput<AssistantMessage.Part>

        // parity: ai/src/schema/messages.ts#Message.SystemInput [status=implemented hash=2940e6a5a4d3]
        public struct SystemInput: Sendable {
            public let id: String?
            public let content: ContentInput<SystemMessage.Part>
            public let tools: AITool.ToolChangesInput?

            public init(id: String? = nil, content: ContentInput<SystemMessage.Part> = .parts([]), tools: AITool.ToolChangesInput? = nil) {
                self.id = id
                self.content = content
                self.tools = tools
            }
        }

        // parity: ai/src/schema/messages.ts#Message.UserInput [status=implemented hash=72cabdc6e0b3]
        public struct UserInput: Sendable {
            public let id: String?
            public let content: UserContentInput
            public let providerMetadata: ProviderMetadata?

            public init(id: String? = nil, content: UserContentInput, providerMetadata: ProviderMetadata? = nil) {
                self.id = id
                self.content = content
                self.providerMetadata = providerMetadata
            }
        }

        // parity: ai/src/schema/messages.ts#Message.AssistantInput [status=implemented hash=b00abfaeab6e]
        public struct AssistantInput: Sendable {
            public let id: String?
            public let content: AssistantContentInput
            public let providerMetadata: ProviderMetadata?

            public init(id: String? = nil, content: AssistantContentInput, providerMetadata: ProviderMetadata? = nil) {
                self.id = id
                self.content = content
                self.providerMetadata = providerMetadata
            }
        }

        // parity: ai/src/schema/messages.ts#Message.ToolInput [status=implemented hash=3a4dbcdd4dd8]
        public struct ToolInput: Sendable {
            public let id: String?
            public let content: [ToolResultPart]

            public init(id: String? = nil, content: [ToolResultPart]) {
                self.id = id
                self.content = content
            }

            public init(id: String? = nil, result: ToolResultPart) {
                self.id = id
                self.content = [result]
            }
        }

        // parity: ai/src/schema/messages.ts#Message.Input [status=implemented hash=2255e5168bf4]
        public enum Input: Sendable {
            case message(Message)
            case system(SystemInput)
            case user(UserInput)
            case assistant(AssistantInput)
            case tool(ToolInput)

            public func toMessage() -> Message {
                Message.make(self)
            }
        }

        public var role: MessageRole {
            switch self {
            case .system: .system
            case .user: .user
            case .assistant: .assistant
            case .tool: .tool
            }
        }

        public var contentParts: [ContentPart] {
            switch self {
            case .system(let m): m.content.map(\.asContentPart)
            case .user(let m): m.content.map(\.asContentPart)
            case .assistant(let m): m.content.map(\.asContentPart)
            case .tool(let m): m.content.map { .toolResult($0) }
            }
        }

        public static func text(_ value: String) -> TextPart {
            TextPart(text: value)
        }

        public static func media(
            _ media: AIMedia.Input,
            mediaType: String? = nil,
            filename: String? = nil,
            cache: CacheHint? = nil,
            providerMetadata: ProviderMetadata? = nil
        ) throws(AIError) -> MediaPart {
            try MediaPartInput(
                media: media,
                mediaType: mediaType,
                filename: filename,
                cache: cache,
                providerMetadata: providerMetadata
            ).toMediaPart()
        }

        public static func make(_ input: Input) -> Message {
            switch input {
            case .message(let m):
                return m
            case .system(let s):
                let parts: [SystemMessage.Part] = switch s.content {
                case .text(let str): [.text(TextPart(text: str))]
                case .part(let p): [p]
                case .parts(let ps): ps
                }
                return .system(SystemMessage(id: s.id, content: parts, tools: s.tools?.toToolChanges()))
            case .user(let u):
                let parts: [UserMessage.Part] = switch u.content {
                case .text(let str): [.text(TextPart(text: str))]
                case .part(let p): [p]
                case .parts(let ps): ps
                }
                return .user(UserMessage(id: u.id, content: parts, providerMetadata: u.providerMetadata))
            case .assistant(let a):
                let parts: [AssistantMessage.Part] = switch a.content {
                case .text(let str): [.text(TextPart(text: str))]
                case .part(let p): [p]
                case .parts(let ps): ps
                }
                return .assistant(AssistantMessage(id: a.id, content: parts, providerMetadata: a.providerMetadata))
            case .tool(let t):
                return .tool(ToolMessage(id: t.id, content: t.content))
            }
        }

        public static func user(_ text: String) -> Message {
            .user(UserMessage(content: [.text(TextPart(text: text))]))
        }

        public static func user(_ parts: [UserMessage.Part]) -> Message {
            .user(UserMessage(content: parts))
        }

        public static func assistant(_ text: String) -> Message {
            .assistant(AssistantMessage(content: [.text(TextPart(text: text))]))
        }

        public static func assistant(_ parts: [AssistantMessage.Part]) -> Message {
            .assistant(AssistantMessage(content: parts))
        }

        public static func system(_ text: String) -> Message {
            .system(SystemMessage(content: [.text(TextPart(text: text))]))
        }

        public static func system(_ parts: [SystemMessage.Part]) -> Message {
            .system(SystemMessage(content: parts))
        }

        public static func effort(effort: ReasoningEffort? = nil, previous: ReasoningEffort? = nil) -> Message {
            .system(SystemMessage(content: [.effort(EffortPart(effort: effort, previous: previous))]))
        }

        public static func tools(_ input: AITool.ToolChangesInput) -> Input {
            .system(SystemInput(content: .parts([]), tools: input))
        }

        public static func tool(_ result: ToolResultPart) -> Message {
            .tool(ToolMessage(content: [result]))
        }

        public static func tool(
            id: ToolCallID,
            name: String,
            namespace: String? = nil,
            result: ToolResultValue,
            providerExecuted: Bool? = nil,
            cache: CacheHint? = nil,
            providerMetadata: ProviderMetadata? = nil
        ) -> Message {
            .tool(ToolMessage(content: [
                ToolResultPart.make(
                    id: id,
                    name: name,
                    namespace: namespace,
                    result: result,
                    providerExecuted: providerExecuted,
                    cache: cache,
                    providerMetadata: providerMetadata
                )
            ]))
        }

        enum TagKeys: String, CodingKey { case role }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: TagKeys.self)
            let role = try c.decode(String.self, forKey: .role)
            switch role {
            case "system": self = .system(try SystemMessage(from: decoder))
            case "user": self = .user(try UserMessage(from: decoder))
            case "assistant": self = .assistant(try AssistantMessage(from: decoder))
            case "tool": self = .tool(try ToolMessage(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(forKey: .role, in: c, debugDescription: "Unknown Message role '\(role)'")
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .system(let m): try m.encode(to: encoder)
            case .user(let m): try m.encode(to: encoder)
            case .assistant(let m): try m.encode(to: encoder)
            case .tool(let m): try m.encode(to: encoder)
            }
        }
    }

    // parity: ai/src/schema/messages.ts#Freeform [status=implemented hash=e915a27c7c48]
    public typealias Freeform = ToolSchema.Freeform

    // parity: ai/src/schema/messages.ts#ToolDefinitionInput [status=implemented hash=229a2ec1df6f]
    public struct ToolDefinitionInput: Equatable, Hashable, Sendable, Codable {
        public let name: String
        public let description: String
        public let inputSchema: JsonSchema
        public let outputSchema: JsonSchema?
        public let freeform: Freeform?
        public let cache: CacheHint?
        public let native: [String: JSONValue]?

        public init(
            name: String,
            description: String,
            inputSchema: JsonSchema,
            outputSchema: JsonSchema? = nil,
            freeform: Freeform? = nil,
            cache: CacheHint? = nil,
            native: [String: JSONValue]? = nil
        ) {
            self.name = name
            self.description = description
            self.inputSchema = inputSchema
            self.outputSchema = outputSchema
            self.freeform = freeform
            self.cache = cache
            self.native = native
        }
    }

    // parity: ai/src/schema/messages.ts#ToolDefinition [status=implemented hash=79ba74eb8cdc]
    public struct ToolDefinition: Equatable, Hashable, Sendable, Codable {
        // parity: ai/src/schema/messages.ts#ToolDefinition.Input [status=implemented hash=3bbed93656fe]
        public typealias Input = ToolDefinitionInput

        public let name: String
        public let description: String
        public let inputSchema: JsonSchema
        public let outputSchema: JsonSchema?
        public let freeform: Freeform?
        public let cache: CacheHint?
        public let native: [String: JSONValue]?

        public init(
            name: String,
            description: String,
            inputSchema: JsonSchema,
            outputSchema: JsonSchema? = nil,
            freeform: Freeform? = nil,
            cache: CacheHint? = nil,
            native: [String: JSONValue]? = nil
        ) {
            self.name = name
            self.description = description
            self.inputSchema = inputSchema
            self.outputSchema = outputSchema
            self.freeform = freeform
            self.cache = cache
            self.native = native
        }

        public init(_ input: ToolDefinitionInput) {
            self.init(
                name: input.name,
                description: input.description,
                inputSchema: input.inputSchema,
                outputSchema: input.outputSchema,
                freeform: input.freeform,
                cache: input.cache,
                native: input.native
            )
        }

        // parity: ai/src/schema/messages.ts#ToolDefinition.make [status=implemented hash=859bfa5a88c9]
        public static func make(_ input: Input) -> ToolDefinition {
            ToolDefinition(input)
        }

        public static func make(_ input: ToolDefinition) -> ToolDefinition {
            input
        }

        /// The parameter a freeform call fills: the input schema's only property, when it is a required string.
        // parity: ai/src/schema/messages.ts#ToolDefinition.freeformField [status=implemented hash=92def914e339]
        public static func freeformField(_ schema: JsonSchema) -> String? {
            guard case .object(let properties) = schema["properties"], properties.count == 1,
                  let (name, propVal) = properties.first,
                  case .object(let propObj) = propVal,
                  case .string(let propType) = propObj["type"],
                  propType == "string",
                  case .array(let required) = schema["required"]
            else {
                return nil
            }
            return required.contains(.string(name)) ? name : nil
        }

        public func withCache(_ hint: CacheHint) -> ToolDefinition {
            ToolDefinition(
                name: name,
                description: description,
                inputSchema: inputSchema,
                outputSchema: outputSchema,
                freeform: freeform,
                cache: hint,
                native: native
            )
        }

        enum CodingKeys: String, CodingKey {
            case type, name, description, inputSchema, outputSchema, freeform, cache, native
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let type = try c.decodeIfPresent(String.self, forKey: .type), type != "tool" {
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Expected literal 'tool', got '\(type)'")
            }
            self.name = try c.decode(String.self, forKey: .name)
            self.description = try c.decode(String.self, forKey: .description)
            self.inputSchema = try c.decode(JsonSchema.self, forKey: .inputSchema)
            self.outputSchema = try c.decodeIfPresent(JsonSchema.self, forKey: .outputSchema)
            self.freeform = try c.decodeIfPresent(Freeform.self, forKey: .freeform)
            self.cache = try c.decodeIfPresent(CacheHint.self, forKey: .cache)
            self.native = try c.decodeIfPresent([String: JSONValue].self, forKey: .native)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("tool", forKey: .type)
            try c.encode(name, forKey: .name)
            try c.encode(description, forKey: .description)
            try c.encode(inputSchema, forKey: .inputSchema)
            try c.encodeIfPresent(outputSchema, forKey: .outputSchema)
            try c.encodeIfPresent(freeform, forKey: .freeform)
            try c.encodeIfPresent(cache, forKey: .cache)
            try c.encodeIfPresent(native, forKey: .native)
        }
    }

    // parity: ai/src/schema/messages.ts#ToolNamespaceInput [status=implemented hash=246d9c7f9aa5]
    public struct ToolNamespaceInput: Equatable, Hashable, Sendable {
        public let name: String
        public let description: String?
        public let tools: [ToolEntryInput]

        public init(name: String, description: String? = nil, tools: [ToolEntryInput]) {
            self.name = name
            self.description = description
            self.tools = tools
        }
    }

    // parity: ai/src/schema/messages.ts#ToolNamespaceEntryInput [status=implemented hash=0ef3871ee1a0]
    public typealias ToolNamespaceEntryInput = ToolNamespaceInput

    // parity: ai/src/schema/messages.ts#ToolNamespace [status=implemented hash=00916b5a5140]
    public struct ToolNamespace: Equatable, Hashable, Sendable, Codable {
        public let name: String
        public let description: String?
        public let tools: [ToolEntry]

        public init(name: String, description: String? = nil, tools: [ToolEntry]) {
            self.name = name
            self.description = description
            self.tools = tools
        }

        public static func make(_ input: ToolNamespaceInput) -> ToolNamespace {
            ToolNamespace(
                name: input.name,
                description: input.description,
                tools: input.tools.map(ToolEntry.make)
            )
        }

        public static func make(_ input: ToolNamespace) -> ToolNamespace {
            input
        }

        enum CodingKeys: String, CodingKey { case type, name, description, tools }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            guard type == "namespace" else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Expected literal 'namespace', got '\(type)'")
            }
            self.name = try c.decode(String.self, forKey: .name)
            self.description = try c.decodeIfPresent(String.self, forKey: .description)
            self.tools = try c.decode([ToolEntry].self, forKey: .tools)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("namespace", forKey: .type)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(description, forKey: .description)
            try c.encode(tools, forKey: .tools)
        }
    }

    // parity: ai/src/schema/messages.ts#ToolEntryInput [status=implemented hash=393ef57bc84f]
    public indirect enum ToolEntryInput: Equatable, Hashable, Sendable {
        case tool(ToolDefinition)
        case toolInput(ToolDefinitionInput)
        case namespace(ToolNamespaceInput)

        public var name: String {
            switch self {
            case .tool(let d): d.name
            case .toolInput(let d): d.name
            case .namespace(let n): n.name
            }
        }
    }

    // parity: ai/src/schema/messages.ts#ToolEntry [status=implemented hash=7371063db550]
    public indirect enum ToolEntry: Equatable, Hashable, Sendable, Codable {
        case tool(ToolDefinition)
        case namespace(ToolNamespace)

        public var name: String {
            switch self {
            case .tool(let d): d.name
            case .namespace(let n): n.name
            }
        }

        public var typeTag: String {
            switch self {
            case .tool: "tool"
            case .namespace: "namespace"
            }
        }

        public static func make(_ input: ToolEntryInput) -> ToolEntry {
            switch input {
            case .tool(let d): .tool(d)
            case .toolInput(let d): .tool(ToolDefinition.make(d))
            case .namespace(let n): .namespace(ToolNamespace.make(n))
            }
        }

        public static func make(_ entry: ToolEntry) -> ToolEntry {
            entry
        }

        enum TagKeys: String, CodingKey { case type }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: TagKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            switch type {
            case "tool": self = .tool(try ToolDefinition(from: decoder))
            case "namespace": self = .namespace(try ToolNamespace(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown ToolEntry type '\(type)'")
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .tool(let d): try d.encode(to: encoder)
            case .namespace(let n): try n.encode(to: encoder)
            }
        }
    }

    // parity: ai/src/schema/messages.ts#ToolChoice [status=implemented hash=4f4bcc5bbea3]
    public struct ToolChoice: Equatable, Hashable, Sendable, Codable {
        public enum Kind: String, Equatable, Hashable, Sendable, Codable {
            case auto
            case none
            case required
            case tool
        }

        // parity: ai/src/schema/messages.ts#ToolChoice.Mode [status=implemented hash=f5dce27e3b0f]
        public enum Mode: String, Equatable, Hashable, Sendable, Codable {
            case auto
            case none
            case required
        }

        // parity: ai/src/schema/messages.ts#ToolChoice.Input [status=implemented hash=11765ef457c8]
        public enum Input: Equatable, Hashable, Sendable {
            case choice(ToolChoice)
            case definition(ToolDefinition)
            case string(String)
        }

        public let type: Kind
        public let name: String?
        public let disableParallelToolUse: Bool?

        public init(type: Kind, name: String? = nil, disableParallelToolUse: Bool? = nil) {
            self.type = type
            self.name = name
            self.disableParallelToolUse = disableParallelToolUse
        }

        /// Select a specific named tool.
        // parity: ai/src/schema/messages.ts#ToolChoice.named [status=implemented hash=5b5e565e3b9a]
        public static func named(_ value: String) -> ToolChoice {
            ToolChoice(type: .tool, name: value)
        }

        /// Normalize ergonomic tool-choice inputs into the canonical `ToolChoice`.
        // parity: ai/src/schema/messages.ts#ToolChoice.make [status=implemented hash=ed5ee4377d08]
        public static func make(_ input: Input) -> ToolChoice {
            switch input {
            case .choice(let c):
                return c
            case .definition(let d):
                return named(d.name)
            case .string(let s):
                if let mode = Mode(rawValue: s) {
                    return ToolChoice(type: Kind(rawValue: mode.rawValue)!)
                }
                return named(s)
            }
        }
    }

    // parity: ai/src/schema/messages.ts#LLMRequest [status=implemented hash=492fb0cd228f]
    public struct LLMRequest: BaseRequest, Sendable {
        public let id: String?
        public let model: LanguageModel
        public let system: [SystemPart]
        public let messages: [Message]
        public let tools: [ToolEntry]
        public let toolChoice: ToolChoice?
        public let maxTokens: Int?
        public let temperature: Double?
        public let topP: Double?
        public let topK: Int?
        public let frequencyPenalty: Double?
        public let presencePenalty: Double?
        public let seed: Int?
        public let stop: [String]?
        public let providerOptions: ProviderOptions?
        public let headers: [String: String]?
        public let timeout: RequestTimeout?
        public let http: HttpOptions?
        public let fetch: (any HTTPTransport)?
        public let cache: CachePolicy?
        public let promptCacheKey: String?
        public let includeRaw: Bool?

        public init(
            id: String? = nil,
            model: LanguageModel,
            system: [SystemPart] = [],
            messages: [Message],
            tools: [ToolEntry] = [],
            toolChoice: ToolChoice? = nil,
            maxTokens: Int? = nil,
            temperature: Double? = nil,
            topP: Double? = nil,
            topK: Int? = nil,
            frequencyPenalty: Double? = nil,
            presencePenalty: Double? = nil,
            seed: Int? = nil,
            stop: [String]? = nil,
            providerOptions: ProviderOptions? = nil,
            headers: [String: String]? = nil,
            timeout: RequestTimeout? = nil,
            http: HttpOptions? = nil,
            fetch: (any HTTPTransport)? = nil,
            cache: CachePolicy? = nil,
            promptCacheKey: String? = nil,
            includeRaw: Bool? = nil
        ) {
            self.id = id
            self.model = model
            self.system = system
            self.messages = messages
            self.tools = tools
            self.toolChoice = toolChoice
            self.maxTokens = maxTokens
            self.temperature = temperature
            self.topP = topP
            self.topK = topK
            self.frequencyPenalty = frequencyPenalty
            self.presencePenalty = presencePenalty
            self.seed = seed
            self.stop = stop
            self.providerOptions = providerOptions
            self.headers = headers
            self.timeout = timeout
            self.http = http
            self.fetch = fetch
            self.cache = cache
            self.promptCacheKey = promptCacheKey
            self.includeRaw = includeRaw
        }

        public var generationOptions: GenerationOptionsFields {
            GenerationOptionsFields(
                maxTokens: maxTokens,
                temperature: temperature,
                topP: topP,
                topK: topK,
                frequencyPenalty: frequencyPenalty,
                presencePenalty: presencePenalty,
                seed: seed,
                stop: stop
            )
        }

        public var transportOptions: TransportOptions {
            TransportOptions(headers: headers, timeout: timeout, http: http)
        }

        public func replacing(
            system: [SystemPart]? = nil,
            messages: [Message]? = nil,
            tools: [ToolEntry]? = nil,
            toolChoice: ToolChoice?? = nil,
            generation: GenerationOptionsFields? = nil,
            transport: TransportOptions? = nil,
            providerOptions: ProviderOptions?? = nil,
            headers: [String: String]?? = nil
        ) -> LLMRequest {
            let gen = generation ?? generationOptions
            let tr = transport ?? transportOptions
            return LLMRequest(
                id: id,
                model: model,
                system: system ?? self.system,
                messages: messages ?? self.messages,
                tools: tools ?? self.tools,
                toolChoice: toolChoice ?? self.toolChoice,
                maxTokens: gen.maxTokens,
                temperature: gen.temperature,
                topP: gen.topP,
                topK: gen.topK,
                frequencyPenalty: gen.frequencyPenalty,
                presencePenalty: gen.presencePenalty,
                seed: gen.seed,
                stop: gen.stop,
                providerOptions: providerOptions ?? self.providerOptions,
                headers: headers ?? tr.headers,
                timeout: tr.timeout,
                http: tr.http,
                fetch: fetch,
                cache: cache,
                promptCacheKey: promptCacheKey,
                includeRaw: includeRaw
            )
        }
    }

    // MARK: - src/schema/events.ts

    // parity: ai/src/schema/events.ts#FinishReason [status=implemented hash=6b20075db089]
    public typealias FinishReason = LLMSchema.FinishReason

    // parity: ai/src/schema/events.ts#Usage [status=implemented hash=5d975a27cc11]
    public struct Usage: Equatable, Hashable, Sendable, Codable {
        public let contextTokens: Double?
        public let inputTokens: Double?
        public let outputTokens: Double?
        public let nonCachedInputTokens: Double?
        public let cacheReadInputTokens: Double?
        public let cacheWriteInputTokens: Double?
        public let reasoningTokens: Double?
        public let totalTokens: Double?
        public let cost: Double?
        public let providerMetadata: ProviderMetadata?

        public init(
            contextTokens: Double? = nil,
            inputTokens: Double? = nil,
            outputTokens: Double? = nil,
            nonCachedInputTokens: Double? = nil,
            cacheReadInputTokens: Double? = nil,
            cacheWriteInputTokens: Double? = nil,
            reasoningTokens: Double? = nil,
            totalTokens: Double? = nil,
            cost: Double? = nil,
            providerMetadata: ProviderMetadata? = nil
        ) {
            self.contextTokens = contextTokens
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.nonCachedInputTokens = nonCachedInputTokens
            self.cacheReadInputTokens = cacheReadInputTokens
            self.cacheWriteInputTokens = cacheWriteInputTokens
            self.reasoningTokens = reasoningTokens
            self.totalTokens = totalTokens
            self.cost = cost
            self.providerMetadata = providerMetadata
        }

        /// Non-reasoning output tokens, clamped to zero.
        // parity: ai/src/schema/events.ts#Usage.visibleOutputTokens [status=implemented hash=84009c6dddcb]
        public var visibleOutputTokens: Double {
            max(0, (outputTokens ?? 0) - (reasoningTokens ?? 0))
        }

        public static func from(_ input: UsageInput) -> Usage {
            input
        }
    }

    // parity: ai/src/schema/events.ts#UsageInput [status=implemented hash=5bbe4b34c20e]
    public typealias UsageInput = Usage

    // parity: ai/src/schema/events.ts#MediaUsage [status=implemented hash=bcd57b9c32af]
    public enum MediaUsage: Equatable, Hashable, Sendable, Codable {
        case tokens(input: Double?, output: Double?, total: Double?, details: [String: JSONValue]?)
        case seconds(Double)
        case characters(Double)
        case credits(Double)
        case compute(seconds: Double)

        enum CodingKeys: String, CodingKey {
            case type, input, output, total, details, seconds, characters, credits
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            switch type {
            case "tokens":
                self = .tokens(
                    input: try c.decodeIfPresent(Double.self, forKey: .input),
                    output: try c.decodeIfPresent(Double.self, forKey: .output),
                    total: try c.decodeIfPresent(Double.self, forKey: .total),
                    details: try c.decodeIfPresent([String: JSONValue].self, forKey: .details)
                )
            case "seconds":
                self = .seconds(try c.decode(Double.self, forKey: .seconds))
            case "characters":
                self = .characters(try c.decode(Double.self, forKey: .characters))
            case "credits":
                self = .credits(try c.decode(Double.self, forKey: .credits))
            case "compute":
                self = .compute(seconds: try c.decode(Double.self, forKey: .seconds))
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown MediaUsage type '\(type)'")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .tokens(let input, let output, let total, let details):
                try c.encode("tokens", forKey: .type)
                try c.encodeIfPresent(input, forKey: .input)
                try c.encodeIfPresent(output, forKey: .output)
                try c.encodeIfPresent(total, forKey: .total)
                try c.encodeIfPresent(details, forKey: .details)
            case .seconds(let s):
                try c.encode("seconds", forKey: .type)
                try c.encode(s, forKey: .seconds)
            case .characters(let ch):
                try c.encode("characters", forKey: .type)
                try c.encode(ch, forKey: .characters)
            case .credits(let cr):
                try c.encode("credits", forKey: .type)
                try c.encode(cr, forKey: .credits)
            case .compute(let s):
                try c.encode("compute", forKey: .type)
                try c.encode(s, forKey: .seconds)
            }
        }
    }

    /// Token usage from a provider's counts; returns `nil` when no count is present.
    // parity: ai/src/schema/events.ts#tokenUsage [status=implemented hash=c7322c4982c9]
    public static func tokenUsage(
        input: Double? = nil,
        output: Double? = nil,
        total: Double? = nil,
        details: [String: JSONValue]? = nil
    ) -> MediaUsage? {
        if input == nil && output == nil && total == nil { return nil }
        return .tokens(input: input, output: output, total: total, details: details)
    }

    // parity: ai/src/schema/events.ts#CompactionResponse [status=implemented hash=ea38501ee785]
    public struct CompactionResponse: Equatable, Sendable, Codable {
        public let replacement: [Message]
        public let usage: Usage?

        public init(replacement: [Message], usage: Usage? = nil) {
            self.replacement = replacement
            self.usage = usage
        }
    }

    // parity: ai/src/schema/events.ts#CompactionCheckpointResponse [status=implemented hash=41a13316aca0]
    public struct CompactionCheckpointResponse: Equatable, Hashable, Sendable, Codable {
        public let checkpoint: CompactionPart
        public let responseID: String
        public let usage: Usage?

        public init(checkpoint: CompactionPart, responseID: String, usage: Usage? = nil) throws(AIError) {
            guard let encrypted = checkpoint.encrypted, !encrypted.isEmpty else {
                throw AIError(reason: .invalidRequest(InvalidRequestError(
                    message: "A checkpoint response requires encrypted compaction content"
                )))
            }
            guard responseID.contains(where: { !$0.isWhitespace }) else {
                throw AIError(reason: .invalidRequest(InvalidRequestError(
                    message: "A checkpoint response requires a non-empty responseID"
                )))
            }
            self.checkpoint = checkpoint
            self.responseID = responseID
            self.usage = usage
        }

        enum CodingKeys: String, CodingKey { case checkpoint, responseID, usage }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let checkpoint = try c.decode(CompactionPart.self, forKey: .checkpoint)
            guard let encrypted = checkpoint.encrypted, !encrypted.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .checkpoint,
                    in: c,
                    debugDescription: "A checkpoint response requires encrypted compaction content"
                )
            }
            let responseID = try c.decode(String.self, forKey: .responseID)
            guard responseID.contains(where: { !$0.isWhitespace }) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .responseID,
                    in: c,
                    debugDescription: "responseID must contain non-whitespace characters"
                )
            }
            self.checkpoint = checkpoint
            self.responseID = responseID
            self.usage = try c.decodeIfPresent(Usage.self, forKey: .usage)
        }
    }

    // parity: ai/src/schema/events.ts#StepStart [status=implemented hash=80434ce6bb4d]
    public struct StepStart: Equatable, Hashable, Sendable, Codable {
        public let index: Int
        public init(index: Int) { self.index = index }

        enum CodingKeys: String, CodingKey { case type, index }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.index = try c.decode(Int.self, forKey: .index)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("step-start", forKey: .type)
            try c.encode(index, forKey: .index)
        }
    }

    // parity: ai/src/schema/events.ts#TextStart [status=implemented hash=4bebfd2ec9c9]
    public struct TextStart: Equatable, Hashable, Sendable, Codable {
        public let id: ContentBlockID
        public let providerMetadata: ProviderMetadata?
        public init(id: ContentBlockID, providerMetadata: ProviderMetadata? = nil) {
            self.id = id
            self.providerMetadata = providerMetadata
        }

        enum CodingKeys: String, CodingKey { case type, id, providerMetadata }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(ContentBlockID.self, forKey: .id)
            self.providerMetadata = try c.decodeIfPresent(ProviderMetadata.self, forKey: .providerMetadata)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("text-start", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(providerMetadata, forKey: .providerMetadata)
        }
    }

    // parity: ai/src/schema/events.ts#TextDelta [status=implemented hash=9d5a2c471474]
    public struct TextDelta: Equatable, Hashable, Sendable, Codable {
        public let id: ContentBlockID
        public let text: String
        public let providerMetadata: ProviderMetadata?
        public init(id: ContentBlockID, text: String, providerMetadata: ProviderMetadata? = nil) {
            self.id = id
            self.text = text
            self.providerMetadata = providerMetadata
        }

        enum CodingKeys: String, CodingKey { case type, id, text, providerMetadata }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(ContentBlockID.self, forKey: .id)
            self.text = try c.decode(String.self, forKey: .text)
            self.providerMetadata = try c.decodeIfPresent(ProviderMetadata.self, forKey: .providerMetadata)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("text-delta", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(text, forKey: .text)
            try c.encodeIfPresent(providerMetadata, forKey: .providerMetadata)
        }
    }

    // parity: ai/src/schema/events.ts#TextEnd [status=implemented hash=aad135c2a0cc]
    public struct TextEnd: Equatable, Hashable, Sendable, Codable {
        public let id: ContentBlockID
        public let text: String?
        public let providerMetadata: ProviderMetadata?
        public init(id: ContentBlockID, text: String? = nil, providerMetadata: ProviderMetadata? = nil) {
            self.id = id
            self.text = text
            self.providerMetadata = providerMetadata
        }

        enum CodingKeys: String, CodingKey { case type, id, text, providerMetadata }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(ContentBlockID.self, forKey: .id)
            self.text = try c.decodeIfPresent(String.self, forKey: .text)
            self.providerMetadata = try c.decodeIfPresent(ProviderMetadata.self, forKey: .providerMetadata)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("text-end", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(text, forKey: .text)
            try c.encodeIfPresent(providerMetadata, forKey: .providerMetadata)
        }
    }

    // parity: ai/src/schema/events.ts#ReasoningStart [status=implemented hash=1b720cded415]
    public struct ReasoningStart: Equatable, Hashable, Sendable, Codable {
        public let id: ContentBlockID
        public let providerMetadata: ProviderMetadata?
        public init(id: ContentBlockID, providerMetadata: ProviderMetadata? = nil) {
            self.id = id
            self.providerMetadata = providerMetadata
        }

        enum CodingKeys: String, CodingKey { case type, id, providerMetadata }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(ContentBlockID.self, forKey: .id)
            self.providerMetadata = try c.decodeIfPresent(ProviderMetadata.self, forKey: .providerMetadata)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("reasoning-start", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(providerMetadata, forKey: .providerMetadata)
        }
    }

    // parity: ai/src/schema/events.ts#ReasoningDelta [status=implemented hash=f56c39e56e8e]
    public struct ReasoningDelta: Equatable, Hashable, Sendable, Codable {
        public let id: ContentBlockID
        public let text: String
        public let providerMetadata: ProviderMetadata?
        public init(id: ContentBlockID, text: String, providerMetadata: ProviderMetadata? = nil) {
            self.id = id
            self.text = text
            self.providerMetadata = providerMetadata
        }

        enum CodingKeys: String, CodingKey { case type, id, text, providerMetadata }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(ContentBlockID.self, forKey: .id)
            self.text = try c.decode(String.self, forKey: .text)
            self.providerMetadata = try c.decodeIfPresent(ProviderMetadata.self, forKey: .providerMetadata)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("reasoning-delta", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(text, forKey: .text)
            try c.encodeIfPresent(providerMetadata, forKey: .providerMetadata)
        }
    }

    // parity: ai/src/schema/events.ts#ReasoningEnd [status=implemented hash=2a792b80fcd2]
    public struct ReasoningEnd: Equatable, Hashable, Sendable, Codable {
        public let id: ContentBlockID
        public let text: String?
        public let providerMetadata: ProviderMetadata?
        public init(id: ContentBlockID, text: String? = nil, providerMetadata: ProviderMetadata? = nil) {
            self.id = id
            self.text = text
            self.providerMetadata = providerMetadata
        }

        enum CodingKeys: String, CodingKey { case type, id, text, providerMetadata }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(ContentBlockID.self, forKey: .id)
            self.text = try c.decodeIfPresent(String.self, forKey: .text)
            self.providerMetadata = try c.decodeIfPresent(ProviderMetadata.self, forKey: .providerMetadata)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("reasoning-end", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(text, forKey: .text)
            try c.encodeIfPresent(providerMetadata, forKey: .providerMetadata)
        }
    }

    // parity: ai/src/schema/events.ts#ToolInputStart [status=implemented hash=c44470f8e3cb]
    public struct ToolInputStart: Equatable, Hashable, Sendable, Codable {
        public let id: ToolCallID
        public let name: String
        public let namespace: String?
        public let providerExecuted: Bool?
        public let providerMetadata: ProviderMetadata?
        public init(
            id: ToolCallID,
            name: String,
            namespace: String? = nil,
            providerExecuted: Bool? = nil,
            providerMetadata: ProviderMetadata? = nil
        ) {
            self.id = id
            self.name = name
            self.namespace = namespace
            self.providerExecuted = providerExecuted
            self.providerMetadata = providerMetadata
        }

        enum CodingKeys: String, CodingKey { case type, id, name, namespace, providerExecuted, providerMetadata }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(ToolCallID.self, forKey: .id)
            self.name = try c.decode(String.self, forKey: .name)
            self.namespace = try c.decodeIfPresent(String.self, forKey: .namespace)
            self.providerExecuted = try c.decodeIfPresent(Bool.self, forKey: .providerExecuted)
            self.providerMetadata = try c.decodeIfPresent(ProviderMetadata.self, forKey: .providerMetadata)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("tool-input-start", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(namespace, forKey: .namespace)
            try c.encodeIfPresent(providerExecuted, forKey: .providerExecuted)
            try c.encodeIfPresent(providerMetadata, forKey: .providerMetadata)
        }
    }

    // parity: ai/src/schema/events.ts#ToolInputDelta [status=implemented hash=11eb54d88ec3]
    public struct ToolInputDelta: Equatable, Hashable, Sendable, Codable {
        public let id: ToolCallID
        public let name: String
        public let namespace: String?
        public let text: String
        public let input: JSONValue?
        public init(
            id: ToolCallID,
            name: String,
            namespace: String? = nil,
            text: String,
            input: JSONValue? = nil
        ) {
            self.id = id
            self.name = name
            self.namespace = namespace
            self.text = text
            self.input = input
        }

        enum CodingKeys: String, CodingKey { case type, id, name, namespace, text, input }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(ToolCallID.self, forKey: .id)
            self.name = try c.decode(String.self, forKey: .name)
            self.namespace = try c.decodeIfPresent(String.self, forKey: .namespace)
            self.text = try c.decode(String.self, forKey: .text)
            self.input = try c.decodeIfPresent(JSONValue.self, forKey: .input)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("tool-input-delta", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(namespace, forKey: .namespace)
            try c.encode(text, forKey: .text)
            try c.encodeIfPresent(input, forKey: .input)
        }
    }

    // parity: ai/src/schema/events.ts#ToolInputEnd [status=implemented hash=3c5f23ee88ca]
    public struct ToolInputEnd: Equatable, Hashable, Sendable, Codable {
        public let id: ToolCallID
        public let name: String
        public let namespace: String?
        public let providerMetadata: ProviderMetadata?
        public init(
            id: ToolCallID,
            name: String,
            namespace: String? = nil,
            providerMetadata: ProviderMetadata? = nil
        ) {
            self.id = id
            self.name = name
            self.namespace = namespace
            self.providerMetadata = providerMetadata
        }

        enum CodingKeys: String, CodingKey { case type, id, name, namespace, providerMetadata }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(ToolCallID.self, forKey: .id)
            self.name = try c.decode(String.self, forKey: .name)
            self.namespace = try c.decodeIfPresent(String.self, forKey: .namespace)
            self.providerMetadata = try c.decodeIfPresent(ProviderMetadata.self, forKey: .providerMetadata)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("tool-input-end", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(namespace, forKey: .namespace)
            try c.encodeIfPresent(providerMetadata, forKey: .providerMetadata)
        }
    }

    // parity: ai/src/schema/events.ts#ToolInputError [status=implemented hash=dd86faa52edc]
    public struct ToolInputError: Equatable, Hashable, Sendable, Codable {
        public let id: ToolCallID
        public let name: String
        public let namespace: String?
        public let raw: String
        public init(id: ToolCallID, name: String, namespace: String? = nil, raw: String) {
            self.id = id
            self.name = name
            self.namespace = namespace
            self.raw = raw
        }

        enum CodingKeys: String, CodingKey { case type, id, name, namespace, raw }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(ToolCallID.self, forKey: .id)
            self.name = try c.decode(String.self, forKey: .name)
            self.namespace = try c.decodeIfPresent(String.self, forKey: .namespace)
            self.raw = try c.decode(String.self, forKey: .raw)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("tool-input-error", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(namespace, forKey: .namespace)
            try c.encode(raw, forKey: .raw)
        }
    }

    // parity: ai/src/schema/events.ts#ToolCall [status=implemented hash=9bdf9cca610c]
    public struct ToolCall: Equatable, Hashable, Sendable, Codable {
        public let id: ToolCallID
        public let name: String
        public let namespace: String?
        public let input: JSONValue
        public let providerExecuted: Bool?
        public let providerMetadata: ProviderMetadata?

        public init(
            id: ToolCallID,
            name: String,
            namespace: String? = nil,
            input: JSONValue,
            providerExecuted: Bool? = nil,
            providerMetadata: ProviderMetadata? = nil
        ) {
            self.id = id
            self.name = name
            self.namespace = namespace
            self.input = input
            self.providerExecuted = providerExecuted
            self.providerMetadata = providerMetadata
        }

        public var asToolCallPart: ToolCallPart {
            ToolCallPart(
                id: id,
                name: name,
                namespace: namespace,
                input: input,
                providerExecuted: providerExecuted,
                providerMetadata: providerMetadata
            )
        }

        enum CodingKeys: String, CodingKey {
            case type, id, name, namespace, input, providerExecuted, providerMetadata
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(ToolCallID.self, forKey: .id)
            self.name = try c.decode(String.self, forKey: .name)
            self.namespace = try c.decodeIfPresent(String.self, forKey: .namespace)
            self.input = try c.decodeIfPresent(JSONValue.self, forKey: .input) ?? .null
            self.providerExecuted = try c.decodeIfPresent(Bool.self, forKey: .providerExecuted)
            self.providerMetadata = try c.decodeIfPresent(ProviderMetadata.self, forKey: .providerMetadata)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("tool-call", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(namespace, forKey: .namespace)
            try c.encode(input, forKey: .input)
            try c.encodeIfPresent(providerExecuted, forKey: .providerExecuted)
            try c.encodeIfPresent(providerMetadata, forKey: .providerMetadata)
        }
    }

    // parity: ai/src/schema/events.ts#ToolResult [status=implemented hash=d9cccd43e0bc]
    public struct ToolResult: Equatable, Hashable, Sendable, Codable {
        public let id: ToolCallID
        public let name: String
        public let namespace: String?
        public let result: ToolResultValue
        public let output: ToolOutput?
        public let providerExecuted: Bool?
        public let providerMetadata: ProviderMetadata?

        public init(
            id: ToolCallID,
            name: String,
            namespace: String? = nil,
            result: ToolResultValue,
            output: ToolOutput? = nil,
            providerExecuted: Bool? = nil,
            providerMetadata: ProviderMetadata? = nil
        ) {
            self.id = id
            self.name = name
            self.namespace = namespace
            self.result = result
            self.output = output
            self.providerExecuted = providerExecuted
            self.providerMetadata = providerMetadata
        }

        enum CodingKeys: String, CodingKey {
            case type, id, name, namespace, result, output, providerExecuted, providerMetadata
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(ToolCallID.self, forKey: .id)
            self.name = try c.decode(String.self, forKey: .name)
            self.namespace = try c.decodeIfPresent(String.self, forKey: .namespace)
            self.result = try c.decode(ToolResultValue.self, forKey: .result)
            self.output = try c.decodeIfPresent(ToolOutput.self, forKey: .output)
            self.providerExecuted = try c.decodeIfPresent(Bool.self, forKey: .providerExecuted)
            self.providerMetadata = try c.decodeIfPresent(ProviderMetadata.self, forKey: .providerMetadata)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("tool-result", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(namespace, forKey: .namespace)
            try c.encode(result, forKey: .result)
            try c.encodeIfPresent(output, forKey: .output)
            try c.encodeIfPresent(providerExecuted, forKey: .providerExecuted)
            try c.encodeIfPresent(providerMetadata, forKey: .providerMetadata)
        }
    }

    // parity: ai/src/schema/events.ts#FinishReasonDetails [status=implemented hash=717176200e46]
    public struct FinishReasonDetails: Equatable, Hashable, Sendable, Codable {
        public let normalized: FinishReason
        public let raw: String?
        public let category: String?
        public let explanation: String?

        public init(
            normalized: FinishReason,
            raw: String? = nil,
            category: String? = nil,
            explanation: String? = nil
        ) {
            self.normalized = normalized
            self.raw = raw
            self.category = category
            self.explanation = explanation
        }
    }

    // parity: ai/src/schema/events.ts#StepFinish [status=implemented hash=435d92e3b109]
    public struct StepFinish: Equatable, Hashable, Sendable, Codable {
        public let index: Int
        public let reason: FinishReasonDetails
        public let usage: Usage?
        public let providerMetadata: ProviderMetadata?

        public init(
            index: Int,
            reason: FinishReasonDetails,
            usage: Usage? = nil,
            providerMetadata: ProviderMetadata? = nil
        ) {
            self.index = index
            self.reason = reason
            self.usage = usage
            self.providerMetadata = providerMetadata
        }

        enum CodingKeys: String, CodingKey { case type, index, reason, usage, providerMetadata }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.index = try c.decode(Int.self, forKey: .index)
            self.reason = try c.decode(FinishReasonDetails.self, forKey: .reason)
            self.usage = try c.decodeIfPresent(Usage.self, forKey: .usage)
            self.providerMetadata = try c.decodeIfPresent(ProviderMetadata.self, forKey: .providerMetadata)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("step-finish", forKey: .type)
            try c.encode(index, forKey: .index)
            try c.encode(reason, forKey: .reason)
            try c.encodeIfPresent(usage, forKey: .usage)
            try c.encodeIfPresent(providerMetadata, forKey: .providerMetadata)
        }
    }

    // parity: ai/src/schema/events.ts#Finish [status=implemented hash=b08bef87fcd2]
    public struct Finish: Equatable, Sendable, Codable {
        public let reason: FinishReasonDetails
        public let usage: Usage?
        public let message: AssistantMessage?
        public let providerMetadata: ProviderMetadata?
        public let object: JSONValue?

        public init(
            reason: FinishReasonDetails,
            usage: Usage? = nil,
            message: AssistantMessage? = nil,
            providerMetadata: ProviderMetadata? = nil,
            object: JSONValue? = nil
        ) {
            self.reason = reason
            self.usage = usage
            self.message = message
            self.providerMetadata = providerMetadata
            self.object = object
        }

        enum CodingKeys: String, CodingKey { case type, reason, usage, message, providerMetadata, object }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.reason = try c.decode(FinishReasonDetails.self, forKey: .reason)
            self.usage = try c.decodeIfPresent(Usage.self, forKey: .usage)
            self.message = try c.decodeIfPresent(AssistantMessage.self, forKey: .message)
            self.providerMetadata = try c.decodeIfPresent(ProviderMetadata.self, forKey: .providerMetadata)
            self.object = try c.decodeIfPresent(JSONValue.self, forKey: .object)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("finish", forKey: .type)
            try c.encode(reason, forKey: .reason)
            try c.encodeIfPresent(usage, forKey: .usage)
            try c.encodeIfPresent(message, forKey: .message)
            try c.encodeIfPresent(providerMetadata, forKey: .providerMetadata)
            try c.encodeIfPresent(object, forKey: .object)
        }
    }

    // parity: ai/src/schema/events.ts#MediaEvent [status=implemented hash=a96ad4a64be1]
    public struct MediaEvent: Equatable, Sendable, Codable {
        public let media: AIMedia.Asset
        public let providerMetadata: ProviderMetadata?

        public init(media: AIMedia.Asset, providerMetadata: ProviderMetadata? = nil) {
            self.media = media
            self.providerMetadata = providerMetadata
        }

        enum CodingKeys: String, CodingKey { case type, media, providerMetadata }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.media = try c.decode(AIMedia.Asset.self, forKey: .media)
            self.providerMetadata = try c.decodeIfPresent(ProviderMetadata.self, forKey: .providerMetadata)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("media", forKey: .type)
            try c.encode(media, forKey: .media)
            try c.encodeIfPresent(providerMetadata, forKey: .providerMetadata)
        }
    }

    // parity: ai/src/schema/events.ts#RawEvent [status=implemented hash=b56813cb2608]
    public struct RawEvent: Equatable, Hashable, Sendable, Codable {
        public let data: JSONValue

        public init(data: JSONValue) {
            self.data = data
        }

        enum CodingKeys: String, CodingKey { case type, data }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.data = try c.decode(JSONValue.self, forKey: .data)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("raw", forKey: .type)
            try c.encode(data, forKey: .data)
        }
    }

    // parity: ai/src/schema/events.ts#LLMEvent [status=implemented hash=61f51a4e1f9e]
    public enum LLMEvent: Equatable, Sendable, Codable {
        case compaction(CompactionPart)
        case stepStart(StepStart)
        case textStart(TextStart)
        case textDelta(TextDelta)
        case textEnd(TextEnd)
        case reasoningStart(ReasoningStart)
        case reasoningDelta(ReasoningDelta)
        case reasoningEnd(ReasoningEnd)
        case toolInputStart(ToolInputStart)
        case toolInputDelta(ToolInputDelta)
        case toolInputEnd(ToolInputEnd)
        case toolInputError(ToolInputError)
        case toolCall(ToolCall)
        case toolResult(ToolResult)
        case media(MediaEvent)
        case stepFinish(StepFinish)
        case finish(Finish)
        case raw(RawEvent)

        public var typeName: String {
            switch self {
            case .compaction: "compaction"
            case .stepStart: "step-start"
            case .textStart: "text-start"
            case .textDelta: "text-delta"
            case .textEnd: "text-end"
            case .reasoningStart: "reasoning-start"
            case .reasoningDelta: "reasoning-delta"
            case .reasoningEnd: "reasoning-end"
            case .toolInputStart: "tool-input-start"
            case .toolInputDelta: "tool-input-delta"
            case .toolInputEnd: "tool-input-end"
            case .toolInputError: "tool-input-error"
            case .toolCall: "tool-call"
            case .toolResult: "tool-result"
            case .media: "media"
            case .stepFinish: "step-finish"
            case .finish: "finish"
            case .raw: "raw"
            }
        }

        public var isStepStart: Bool {
            if case .stepStart = self { return true }
            return false
        }

        public var isFinish: Bool {
            if case .finish = self { return true }
            return false
        }

        public var isRaw: Bool {
            if case .raw = self { return true }
            return false
        }

        public var usage: Usage? {
            switch self {
            case .stepFinish(let e): e.usage
            case .finish(let e): e.usage
            default: nil
            }
        }

        enum TagKeys: String, CodingKey { case type }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: TagKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            switch type {
            case "compaction": self = .compaction(try CompactionPart(from: decoder))
            case "step-start": self = .stepStart(try StepStart(from: decoder))
            case "text-start": self = .textStart(try TextStart(from: decoder))
            case "text-delta": self = .textDelta(try TextDelta(from: decoder))
            case "text-end": self = .textEnd(try TextEnd(from: decoder))
            case "reasoning-start": self = .reasoningStart(try ReasoningStart(from: decoder))
            case "reasoning-delta": self = .reasoningDelta(try ReasoningDelta(from: decoder))
            case "reasoning-end": self = .reasoningEnd(try ReasoningEnd(from: decoder))
            case "tool-input-start": self = .toolInputStart(try ToolInputStart(from: decoder))
            case "tool-input-delta": self = .toolInputDelta(try ToolInputDelta(from: decoder))
            case "tool-input-end": self = .toolInputEnd(try ToolInputEnd(from: decoder))
            case "tool-input-error": self = .toolInputError(try ToolInputError(from: decoder))
            case "tool-call": self = .toolCall(try ToolCall(from: decoder))
            case "tool-result": self = .toolResult(try ToolResult(from: decoder))
            case "media": self = .media(try MediaEvent(from: decoder))
            case "step-finish": self = .stepFinish(try StepFinish(from: decoder))
            case "finish": self = .finish(try Finish(from: decoder))
            case "raw": self = .raw(try RawEvent(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown LLMEvent type '\(type)'")
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .compaction(let e): try e.encode(to: encoder)
            case .stepStart(let e): try e.encode(to: encoder)
            case .textStart(let e): try e.encode(to: encoder)
            case .textDelta(let e): try e.encode(to: encoder)
            case .textEnd(let e): try e.encode(to: encoder)
            case .reasoningStart(let e): try e.encode(to: encoder)
            case .reasoningDelta(let e): try e.encode(to: encoder)
            case .reasoningEnd(let e): try e.encode(to: encoder)
            case .toolInputStart(let e): try e.encode(to: encoder)
            case .toolInputDelta(let e): try e.encode(to: encoder)
            case .toolInputEnd(let e): try e.encode(to: encoder)
            case .toolInputError(let e): try e.encode(to: encoder)
            case .toolCall(let e): try e.encode(to: encoder)
            case .toolResult(let e): try e.encode(to: encoder)
            case .media(let e): try e.encode(to: encoder)
            case .stepFinish(let e): try e.encode(to: encoder)
            case .finish(let e): try e.encode(to: encoder)
            case .raw(let e): try e.encode(to: encoder)
            }
        }
    }

    // parity: ai/src/schema/events.ts#LLMResponse [status=implemented hash=82a06a1bcc00]
    public struct LLMResponse: Equatable, Sendable, Codable {
        // parity: ai/src/schema/events.ts#LLMResponse.Output [status=implemented hash=f825ee5c00f2]
        public struct Output: Sendable {
            public let events: [LLMEvent]
            public let usage: Usage?

            public init(events: [LLMEvent], usage: Usage? = nil) {
                self.events = events
                self.usage = usage
            }

            public init(_ response: LLMResponse) {
                self.events = response.events
                self.usage = response.usage
            }
        }

        public let message: AssistantMessage
        public let events: [LLMEvent]
        public let usage: Usage?
        public let finishReason: FinishReasonDetails

        public init(
            message: AssistantMessage,
            events: [LLMEvent],
            usage: Usage? = nil,
            finishReason: FinishReasonDetails
        ) {
            self.message = message
            self.events = events
            self.usage = usage
            self.finishReason = finishReason
        }

        /// Concatenated assistant text; each fragment's `text-end` value replaces its accumulated deltas when present.
        // parity: ai/src/schema/events.ts#LLMResponse.prototype.text [status=implemented hash=d15c68f7aaf9]
        public var text: String {
            Self.joinText(events)
        }

        /// Concatenated reasoning text; each fragment's `reasoning-end` value replaces its accumulated deltas when present.
        // parity: ai/src/schema/events.ts#LLMResponse.prototype.reasoning [status=implemented hash=3f47318ae5af]
        public var reasoning: String {
            Self.joinReasoning(events)
        }

        /// Completed tool calls emitted by the provider.
        // parity: ai/src/schema/events.ts#LLMResponse.prototype.toolCalls [status=implemented hash=5bf3ad9d23c4]
        public var toolCalls: [ToolCall] {
            events.compactMap { if case .toolCall(let tc) = $0 { return tc } else { return nil } }
        }

        /// Assemble a response from a collected event list, or `nil` if it has no terminal finish.
        // parity: ai/src/schema/events.ts#LLMResponse.fromEvents [status=implemented hash=d3ac822aa045]
        public static func fromEvents(_ events: [LLMEvent]) -> LLMResponse? {
            let state = events.reduce(ResponseFold.empty(), ResponseFold.reduce)
            return ResponseFold.complete(state)
        }

        /// Concatenate assistant text from a response or collected event list.
        // parity: ai/src/schema/events.ts#LLMResponse.text [status=implemented hash=9c278c655e85]
        public static func text(_ response: Output) -> String {
            joinText(response.events)
        }

        public static func text(_ response: LLMResponse) -> String {
            response.text
        }

        /// Return response usage, falling back to the latest usage-bearing event.
        // parity: ai/src/schema/events.ts#LLMResponse.usage [status=implemented hash=fd4636d19509]
        public static func usage(_ response: Output) -> Usage? {
            response.usage ?? response.events.reduce(nil as Usage?) { current, event in
                event.usage ?? current
            }
        }

        public static func usage(_ response: LLMResponse) -> Usage? {
            usage(Output(response))
        }

        /// Return completed tool calls from a response or collected event list.
        // parity: ai/src/schema/events.ts#LLMResponse.toolCalls [status=implemented hash=223787898b7a]
        public static func toolCalls(_ response: Output) -> [ToolCall] {
            response.events.compactMap { if case .toolCall(let tc) = $0 { return tc } else { return nil } }
        }

        public static func toolCalls(_ response: LLMResponse) -> [ToolCall] {
            response.toolCalls
        }

        /// Concatenate reasoning text from a response or collected event list.
        // parity: ai/src/schema/events.ts#LLMResponse.reasoning [status=implemented hash=a8ba54d2cd58]
        public static func reasoning(_ response: Output) -> String {
            joinReasoning(response.events)
        }

        public static func reasoning(_ response: LLMResponse) -> String {
            response.reasoning
        }

        private static func joinText(_ events: [LLMEvent]) -> String {
            var order: [ContentBlockID] = []
            var parts: [ContentBlockID: String] = [:]
            for event in events {
                switch event {
                case .textDelta(let d):
                    if parts[d.id] == nil { order.append(d.id) }
                    parts[d.id, default: ""] += d.text
                case .textEnd(let e):
                    if let full = e.text {
                        if parts[e.id] == nil { order.append(e.id) }
                        parts[e.id] = full
                    }
                default:
                    break
                }
            }
            return order.compactMap { parts[$0] }.joined()
        }

        private static func joinReasoning(_ events: [LLMEvent]) -> String {
            var order: [ContentBlockID] = []
            var parts: [ContentBlockID: String] = [:]
            for event in events {
                switch event {
                case .reasoningDelta(let d):
                    if parts[d.id] == nil { order.append(d.id) }
                    parts[d.id, default: ""] += d.text
                case .reasoningEnd(let e):
                    if let full = e.text {
                        if parts[e.id] == nil { order.append(e.id) }
                        parts[e.id] = full
                    }
                default:
                    break
                }
            }
            return order.compactMap { parts[$0] }.joined()
        }
    }

    // parity: ai/src/schema/events.ts#ResponseFold [status=implemented hash=91081375f4f7]
    public enum ResponseFold {
        public struct ContentAssembly: Equatable, Sendable {
            public let contentIndex: Int
            public var text: String
            public var providerMetadata: ProviderMetadata?
        }

        public struct ToolInputAssembly: Equatable, Sendable {
            public var name: String
            public var namespace: String?
            public var text: String
            public var providerMetadata: ProviderMetadata?
        }

        // parity: ai/src/schema/events.ts#ResponseFold.State [status=implemented hash=474a2c87af2a]
        public struct State: Equatable, Sendable {
            public var events: [LLMEvent]
            public var message: AssistantMessage
            public var usage: Usage?
            public var finishReason: FinishReasonDetails?
            public var textParts: [ContentBlockID: ContentAssembly]
            public var reasoningParts: [ContentBlockID: ContentAssembly]
            public var toolInputs: [ToolCallID: ToolInputAssembly]

            public init(
                events: [LLMEvent] = [],
                message: AssistantMessage = AssistantMessage(content: []),
                usage: Usage? = nil,
                finishReason: FinishReasonDetails? = nil,
                textParts: [ContentBlockID: ContentAssembly] = [:],
                reasoningParts: [ContentBlockID: ContentAssembly] = [:],
                toolInputs: [ToolCallID: ToolInputAssembly] = [:]
            ) {
                self.events = events
                self.message = message
                self.usage = usage
                self.finishReason = finishReason
                self.textParts = textParts
                self.reasoningParts = reasoningParts
                self.toolInputs = toolInputs
            }
        }

        /// Initial state with a fresh events buffer.
        // parity: ai/src/schema/events.ts#ResponseFold.empty [status=implemented hash=f0e9267a57cc]
        public static func empty() -> State {
            State()
        }

        /// Fold one provider-neutral event into the state.
        // parity: ai/src/schema/events.ts#ResponseFold.reduce [status=implemented hash=15048f2b4557]
        public static func reduce(_ state: State, _ event: LLMEvent) -> State {
            if case .raw = event { return state }
            var next = state
            next.events.append(event)
            switch event {
            case .finish(let f):
                next.usage = f.usage ?? next.usage
                next.finishReason = f.reason
                return next
            case .stepFinish(let sf):
                if let u = sf.usage { next.usage = u }
                return next
            case .compaction(let cp):
                appendContent(&next, .compaction(cp))
                return next
            case .textStart(let ts):
                ensureText(&next, id: ts.id, metadata: ts.providerMetadata)
                return next
            case .textDelta(let td):
                ensureText(&next, id: td.id, metadata: td.providerMetadata)
                if var entry = next.textParts[td.id] {
                    entry.text += td.text
                    entry.providerMetadata = td.providerMetadata ?? entry.providerMetadata
                    next.textParts[td.id] = entry
                    replaceContent(&next, at: entry.contentIndex, with: .text(TextPart(text: entry.text, providerMetadata: entry.providerMetadata)))
                }
                return next
            case .textEnd(let te):
                if var entry = next.textParts[te.id] {
                    entry.text = te.text ?? entry.text
                    entry.providerMetadata = te.providerMetadata ?? entry.providerMetadata
                    next.textParts[te.id] = entry
                    replaceContent(&next, at: entry.contentIndex, with: .text(TextPart(text: entry.text, providerMetadata: entry.providerMetadata)))
                }
                return next
            case .reasoningStart(let rs):
                ensureReasoning(&next, id: rs.id, metadata: rs.providerMetadata)
                return next
            case .reasoningDelta(let rd):
                ensureReasoning(&next, id: rd.id, metadata: rd.providerMetadata)
                if var entry = next.reasoningParts[rd.id] {
                    entry.text += rd.text
                    entry.providerMetadata = rd.providerMetadata ?? entry.providerMetadata
                    next.reasoningParts[rd.id] = entry
                    replaceContent(&next, at: entry.contentIndex, with: .reasoning(ReasoningPart(text: entry.text, providerMetadata: entry.providerMetadata)))
                }
                return next
            case .reasoningEnd(let re):
                if var entry = next.reasoningParts[re.id] {
                    entry.text = re.text ?? entry.text
                    entry.providerMetadata = re.providerMetadata ?? entry.providerMetadata
                    next.reasoningParts[re.id] = entry
                    replaceContent(&next, at: entry.contentIndex, with: .reasoning(ReasoningPart(text: entry.text, providerMetadata: entry.providerMetadata)))
                }
                return next
            case .toolInputStart(let tis):
                next.toolInputs[tis.id] = ToolInputAssembly(
                    name: tis.name,
                    namespace: tis.namespace,
                    text: "",
                    providerMetadata: tis.providerMetadata
                )
                return next
            case .toolInputDelta(let tid):
                var entry = next.toolInputs[tid.id] ?? ToolInputAssembly(name: tid.name, namespace: tid.namespace, text: "", providerMetadata: nil)
                entry.text += tid.text
                next.toolInputs[tid.id] = entry
                return next
            case .toolInputEnd(let tie):
                var entry = next.toolInputs[tie.id] ?? ToolInputAssembly(name: tie.name, namespace: tie.namespace, text: "", providerMetadata: nil)
                entry.name = tie.name
                entry.namespace = tie.namespace
                entry.providerMetadata = tie.providerMetadata ?? entry.providerMetadata
                next.toolInputs[tie.id] = entry
                return next
            case .toolInputError(let tie):
                next.toolInputs.removeValue(forKey: tie.id)
                return next
            case .toolCall(let tc):
                next.toolInputs.removeValue(forKey: tc.id)
                appendContent(&next, .toolCall(tc.asToolCallPart))
                return next
            case .toolResult(let tr):
                appendContent(&next, .toolResult(ToolResultPart(
                    id: tr.id,
                    name: tr.name,
                    namespace: tr.namespace,
                    result: tr.result,
                    providerExecuted: tr.providerExecuted,
                    providerMetadata: tr.providerMetadata
                )))
                return next
            case .media(let m):
                appendContent(&next, .media(MediaPart(media: m.media, providerMetadata: m.providerMetadata)))
                return next
            case .stepStart, .raw:
                return next
            }
        }

        /// Return a completed response only after the terminal finish.
        // parity: ai/src/schema/events.ts#ResponseFold.complete [status=implemented hash=11bec2f1a18d]
        public static func complete(_ state: State) -> LLMResponse? {
            guard let finishReason = state.finishReason else { return nil }
            return LLMResponse(
                message: state.message,
                events: state.events,
                usage: state.usage,
                finishReason: finishReason
            )
        }

        /// Output that arrived before a failure, or `nil` if only `step-start` did; an unfinished response reports `error`.
        // parity: ai/src/schema/events.ts#ResponseFold.partial [status=implemented hash=1abbf93ebb2b]
        public static func partial(_ state: State) -> LLMResponse? {
            if state.events.allSatisfy(\.isStepStart) { return nil }
            var copy = state
            if copy.finishReason == nil {
                copy.finishReason = FinishReasonDetails(normalized: .error)
            }
            return complete(copy)
        }

        private static func appendContent(_ state: inout State, _ part: AssistantMessage.Part) {
            var content = state.message.content
            content.append(part)
            state.message = AssistantMessage(id: state.message.id, content: content, providerMetadata: state.message.providerMetadata)
        }

        private static func replaceContent(_ state: inout State, at index: Int, with part: AssistantMessage.Part) {
            var content = state.message.content
            guard index >= 0 && index < content.count else { return }
            content[index] = part
            state.message = AssistantMessage(id: state.message.id, content: content, providerMetadata: state.message.providerMetadata)
        }

        private static func ensureText(_ state: inout State, id: ContentBlockID, metadata: ProviderMetadata?) {
            guard state.textParts[id] == nil else { return }
            let idx = state.message.content.count
            appendContent(&state, .text(TextPart(text: "", providerMetadata: metadata)))
            state.textParts[id] = ContentAssembly(contentIndex: idx, text: "", providerMetadata: metadata)
        }

        private static func ensureReasoning(_ state: inout State, id: ContentBlockID, metadata: ProviderMetadata?) {
            guard state.reasoningParts[id] == nil else { return }
            let idx = state.message.content.count
            appendContent(&state, .reasoning(ReasoningPart(text: "", providerMetadata: metadata)))
            state.reasoningParts[id] = ContentAssembly(contentIndex: idx, text: "", providerMetadata: metadata)
        }
    }
}
