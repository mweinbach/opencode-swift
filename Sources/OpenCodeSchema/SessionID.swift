public enum IdentifierValidationError: Error, Equatable, Sendable {
    case invalidPrefix(expected: String, actual: String)
}

/// Branded Session identifier (`ses_<26 descending chars>`).
// parity: schema/src/session-id.ts#SessionID [status=implemented hash=9f46b877b5c6]
public struct SessionID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.hasPrefix("ses") else { return nil }
        self.rawValue = rawValue
    }

    public init(validating value: String) throws(IdentifierValidationError) {
        guard value.hasPrefix("ses") else {
            throw .invalidPrefix(expected: "ses", actual: value)
        }
        self.rawValue = value
    }

    public static func create() -> SessionID {
        SessionID(unchecked: "ses_" + Identifier.descending())
    }

    private init(unchecked value: String) {
        self.rawValue = value
    }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        self = try SessionID(validating: value)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
