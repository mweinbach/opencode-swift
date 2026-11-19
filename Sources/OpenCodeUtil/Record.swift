/// Plain-record narrowing matching `util/src/record.ts`.
/// Accepts key/value dictionaries (`[String: Any]` or `.object` JSON values) and excludes arrays, nil, and primitives.
// parity: util/src/record.ts#isRecord [status=implemented hash=edbb9bd43aff]
public func isRecord(_ value: Any?) -> Bool {
    guard let value else { return false }
    if let json = value as? PureJSONValue {
        if case .object = json { return true }
        return false
    }
    if value is [String: Any] || value is [String: AnySendableValue] {
        return true
    }
    return false
}

/// Type-erased Sendable value container for record/dynamic payloads in pure Swift 6.
public enum AnySendableValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([AnySendableValue])
    case object([String: AnySendableValue])

    public var isRecordValue: Bool {
        if case .object = self { return true }
        return false
    }
}
