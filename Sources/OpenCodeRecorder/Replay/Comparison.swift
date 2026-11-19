import OpenCodePlatform
import OpenCodeUtil

/// Attempts to parse a JSON string into a `PureJSONValue`, returning `nil` if invalid JSON.
// parity: http-recorder/src/replay/comparison.ts#decodeJson [status=implemented hash=ecbf02576bbf]
public func decodeJson(_ text: String) -> PureJSONValue? {
    PureJSON.parse(text)
}

/// Recursively sorts object keys in UTF-16 lexicographic order so semantically identical JSON compares equal.
// parity: http-recorder/src/replay/comparison.ts#canonicalizeJson [status=implemented hash=50065834d9d4]
public func canonicalizeJson(_ value: PureJSONValue) -> PureJSONValue {
    switch value {
    case .array(let items):
        return .array(items.map(canonicalizeJson))
    case .object(let entries):
        // Deduplicate keys (last wins, matching JS Object.fromEntries) and sort by UTF-16 code units.
        var dict: [String: PureJSONValue] = [:]
        dict.reserveCapacity(entries.count)
        for (key, child) in entries {
            dict[key] = child
        }
        let sorted = dict.keys.sorted(by: jsStringLessThan).map { key in
            (key, canonicalizeJson(dict[key]!))
        }
        return .object(sorted)
    case .null, .bool, .number, .string:
        return value
    }
}

/// Canonicalizes a `JsonValue` by converting to a sorted `PureJSONValue`.
public func canonicalizeJson(_ value: JsonValue) -> PureJSONValue {
    canonicalizeJson(value.toPureJSON())
}

/// Safely renders a JSON value for mismatch diagnostics, scrubbing secrets and truncating past 300 UTF-16 units.
// parity: http-recorder/src/replay/comparison.ts#safeText [status=implemented hash=e3751cb1ca76]
public func safeText(
    _ value: PureJSONValue?,
    environment: any EnvironmentProviding = SystemEnvironment.shared
) -> String {
    guard let value else { return "undefined" }
    if !secretFindings(value, environment: environment).isEmpty {
        return PureJSON.stringifyCompact(.string(REDACTED))
    }
    let text = PureJSON.stringifyCompact(value)
    let units = Array(text.utf16)
    if units.count > 300 {
        return String(decoding: units[0..<300], as: UTF16.self) + "..."
    }
    return text
}

/// Safely renders an optional string for mismatch diagnostics.
public func safeText(
    _ value: String?,
    environment: any EnvironmentProviding = SystemEnvironment.shared
) -> String {
    safeText(value.map(PureJSONValue.string), environment: environment)
}

/// Safely renders an array of strings for mismatch diagnostics.
public func safeText(
    _ values: [String],
    environment: any EnvironmentProviding = SystemEnvironment.shared
) -> String {
    safeText(PureJSONValue.array(values.map(PureJSONValue.string)), environment: environment)
}

/// Parses an HTTP body string as JSON if valid, otherwise returns `nil`.
// parity: http-recorder/src/replay/comparison.ts#jsonBody [status=implemented hash=8274b60b7de2]
public func jsonBody(_ body: String) -> PureJSONValue? {
    decodeJson(body)
}

/// Returns `true` when `value` is a JSON object record (not null, primitive, or array).
// parity: http-recorder/src/replay/comparison.ts#isJsonRecord [status=implemented hash=85541c6eaa43]
public func isJsonRecord(_ value: PureJSONValue?) -> Bool {
    guard case .object = value else { return false }
    return true
}
