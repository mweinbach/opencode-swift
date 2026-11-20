/// Branded Workspace identifier (`wrk_<26 ascending chars>`).
// parity: schema/src/workspace-id.ts#WorkspaceID [status=implemented hash=7f9a293fa514]
public struct WorkspaceID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.hasPrefix("wrk") else { return nil }
        self.rawValue = rawValue
    }

    public init(validating value: String) throws(IdentifierValidationError) {
        guard value.hasPrefix("wrk") else {
            throw .invalidPrefix(expected: "wrk", actual: value)
        }
        self.rawValue = value
    }

    public static func create() -> WorkspaceID {
        WorkspaceID(unchecked: "wrk_" + Identifier.ascending())
    }

    public static func ascending(_ id: String? = nil) throws(IdentifierValidationError) -> WorkspaceID {
        guard let id else { return create() }
        return try WorkspaceID(validating: id)
    }

    private init(unchecked value: String) {
        self.rawValue = value
    }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        self = try WorkspaceID(validating: value)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
