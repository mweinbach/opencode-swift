#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import OpenCodeUtil

/// JSON-compatible cassette metadata value matching `packages/http-recorder/src/api.ts#JsonValue`.
// parity: http-recorder/src/api.ts#JsonValue [status=implemented hash=19bb7e359c5a]
public enum JsonValue: Equatable, Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JsonValue])
    case object([String: JsonValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let boolValue = try? container.decode(Bool.self) {
            self = .bool(boolValue)
        } else if let intValue = try? container.decode(Int64.self) {
            self = .number(Double(intValue))
        } else if let doubleValue = try? container.decode(Double.self) {
            self = .number(doubleValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else if let arrayValue = try? container.decode([JsonValue].self) {
            self = .array(arrayValue)
        } else if let objectValue = try? container.decode([String: JsonValue].self) {
            self = .object(objectValue)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let values):
            try container.encode(values)
        case .object(let dictionary):
            try container.encode(dictionary)
        }
    }

    /// Converts this value into an ordered `PureJSONValue` (with keys sorted lexicographically).
    public func toPureJSON() -> PureJSONValue {
        switch self {
        case .null:
            return .null
        case .bool(let value):
            return .bool(value)
        case .number(let value):
            return .number(value)
        case .string(let value):
            return .string(value)
        case .array(let items):
            return .array(items.map { $0.toPureJSON() })
        case .object(let dict):
            let sorted = dict.keys.sorted(by: jsStringLessThan).map { key in
                (key, dict[key]!.toPureJSON())
            }
            return .object(sorted)
        }
    }

    /// Constructs a `JsonValue` from a `PureJSONValue`.
    public static func fromPureJSON(_ value: PureJSONValue) -> JsonValue {
        switch value {
        case .null:
            return .null
        case .bool(let b):
            return .bool(b)
        case .number(let n):
            return .number(n)
        case .string(let s):
            return .string(s)
        case .array(let items):
            return .array(items.map(JsonValue.fromPureJSON))
        case .object(let entries):
            var dict: [String: JsonValue] = [:]
            dict.reserveCapacity(entries.count)
            for (key, child) in entries {
                dict[key] = JsonValue.fromPureJSON(child)
            }
            return .object(dict)
        }
    }
}

extension JsonValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) {
        self = .null
    }
}

extension JsonValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension JsonValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .number(Double(value))
    }
}

extension JsonValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .number(value)
    }
}

extension JsonValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension JsonValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JsonValue...) {
        self = .array(elements)
    }
}

extension JsonValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JsonValue)...) {
        var dict: [String: JsonValue] = [:]
        dict.reserveCapacity(elements.count)
        for (key, value) in elements {
            dict[key] = value
        }
        self = .object(dict)
    }
}

/// Additional JSON metadata stored with a cassette.
// parity: http-recorder/src/api.ts#CassetteMetadata [status=implemented hash=f76b9d15a2fe]
public typealias CassetteMetadata = [String: JsonValue]

/// The normalized HTTP request representation used for matching.
// parity: http-recorder/src/api.ts#RequestSnapshot [status=implemented hash=20645ee9543a]
public struct RequestSnapshot: Equatable, Hashable, Sendable, Codable {
    public let method: String
    public let url: String
    public let headers: [String: String]
    public let body: String

    public init(
        method: String,
        url: String,
        headers: [String: String] = [:],
        body: String = ""
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

/// Returns whether an incoming HTTP request matches a recorded request.
// parity: http-recorder/src/api.ts#RequestMatcher [status=implemented hash=3d23e3163dcc]
public typealias RequestMatcher = @Sendable (_ incoming: RequestSnapshot, _ recorded: RequestSnapshot) -> Bool

/// Additive redaction and header-preservation policy.
// parity: http-recorder/src/api.ts#RedactOptions [status=implemented hash=4fcd250acb19]
public struct RedactOptions: Sendable {
    public let headers: [String]?
    public let allowRequestHeaders: [String]?
    public let allowResponseHeaders: [String]?
    public let queryParameters: [String]?
    public let jsonFields: [String]?
    public let url: (@Sendable (String) -> String)?
    public let body: (@Sendable (String) -> String)?

    public init(
        headers: [String]? = nil,
        allowRequestHeaders: [String]? = nil,
        allowResponseHeaders: [String]? = nil,
        queryParameters: [String]? = nil,
        jsonFields: [String]? = nil,
        url: (@Sendable (String) -> String)? = nil,
        body: (@Sendable (String) -> String)? = nil
    ) {
        self.headers = headers
        self.allowRequestHeaders = allowRequestHeaders
        self.allowResponseHeaders = allowResponseHeaders
        self.queryParameters = queryParameters
        self.jsonFields = jsonFields
        self.url = url
        self.body = body
    }
}

/// Options shared by HTTP recorder layers.
// parity: http-recorder/src/api.ts#RecorderOptions [status=implemented hash=44c6bbcf13b0]
public struct RecorderOptions: Sendable {
    public let directory: String?
    public let metadata: CassetteMetadata?
    public let redact: RedactOptions?
    public let match: RequestMatcher?

    public init(
        directory: String? = nil,
        metadata: CassetteMetadata? = nil,
        redact: RedactOptions? = nil,
        match: RequestMatcher? = nil
    ) {
        self.directory = directory
        self.metadata = metadata
        self.redact = redact
        self.match = match
    }
}

/// Recorder configuration for socket and WebSocket layers (`Omit<RecorderOptions, "match">`).
// parity: http-recorder/src/api.ts#SocketRecorderOptions [status=implemented hash=f63b90f9b3cd]
public struct SocketRecorderOptions: Sendable {
    public let directory: String?
    public let metadata: CassetteMetadata?
    public let redact: RedactOptions?

    public init(
        directory: String? = nil,
        metadata: CassetteMetadata? = nil,
        redact: RedactOptions? = nil
    ) {
        self.directory = directory
        self.metadata = metadata
        self.redact = redact
    }
}

/// UTF-16 code-unit lexicographic comparison matching JavaScript's `Array.prototype.toSorted()`.
internal func jsStringLessThan(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf16.lexicographicallyPrecedes(rhs.utf16)
}
