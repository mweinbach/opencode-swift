import OpenCodeUtil

/// Validation and serialization error raised by `RecorderSchema`.
public struct RecorderSchemaError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let schema: String
    public let message: String

    public init(schema: String, message: String) {
        self.schema = schema
        self.message = message
    }

    public var description: String {
        "\(schema): \(message)"
    }
}

/// Portable runtime schema codec mirroring upstream Effect `Schema` descriptors.
public struct RecorderSchema<Value: Sendable>: Sendable {
    public let name: String
    private let decodeImpl: @Sendable (PureJSONValue) throws -> Value
    private let encodeImpl: @Sendable (Value) -> PureJSONValue

    public init(
        name: String,
        decode: @escaping @Sendable (PureJSONValue) throws -> Value,
        encode: @escaping @Sendable (Value) -> PureJSONValue
    ) {
        self.name = name
        self.decodeImpl = decode
        self.encodeImpl = encode
    }

    public func decode(_ value: PureJSONValue) throws -> Value {
        try decodeImpl(value)
    }

    public func decode(fromJSON text: String) throws -> Value {
        guard let parsed = PureJSON.parse(text) else {
            throw RecorderSchemaError(schema: name, message: "Invalid JSON syntax")
        }
        return try decodeImpl(parsed)
    }

    public func encode(_ value: Value) -> PureJSONValue {
        encodeImpl(value)
    }

    public func encodeToJSON(_ value: Value, pretty: Bool = false) -> String {
        let json = encodeImpl(value)
        return pretty ? PureJSON.stringifyPretty(json, indent: 2) : PureJSON.stringifyCompact(json)
    }
}

// MARK: - Schema Decoding Helpers

internal enum SchemaJSONHelper {
    static func objectMap(_ value: PureJSONValue, schema: String) throws -> [String: PureJSONValue] {
        guard case .object(let entries) = value else {
            throw RecorderSchemaError(schema: schema, message: "Expected JSON object")
        }
        var dict: [String: PureJSONValue] = [:]
        dict.reserveCapacity(entries.count)
        for (key, child) in entries {
            dict[key] = child
        }
        return dict
    }

    static func requiredString(_ dict: [String: PureJSONValue], key: String, schema: String) throws -> String {
        guard let raw = dict[key], case .string(let s) = raw else {
            throw RecorderSchemaError(schema: schema, message: "Expected string at '\(key)'")
        }
        return s
    }

    static func requiredInt(_ dict: [String: PureJSONValue], key: String, schema: String) throws -> Int {
        guard let raw = dict[key], case .number(let n) = raw, n.isFinite, n.rounded() == n,
              n >= Double(Int.min), n <= Double(Int.max) else {
            throw RecorderSchemaError(schema: schema, message: "Expected integer at '\(key)'")
        }
        return Int(n)
    }

    static func requiredStringMap(
        _ dict: [String: PureJSONValue],
        key: String,
        schema: String
    ) throws -> [String: String] {
        guard let raw = dict[key], case .object(let entries) = raw else {
            throw RecorderSchemaError(schema: schema, message: "Expected string record at '\(key)'")
        }
        var out: [String: String] = [:]
        out.reserveCapacity(entries.count)
        for (entryKey, entryVal) in entries {
            guard case .string(let str) = entryVal else {
                throw RecorderSchemaError(
                    schema: schema,
                    message: "Expected string value at '\(key).\(entryKey)'"
                )
            }
            out[entryKey] = str
        }
        return out
    }

    static func requiredStringArray(
        _ dict: [String: PureJSONValue],
        key: String,
        schema: String
    ) throws -> [String] {
        guard let raw = dict[key], case .array(let items) = raw else {
            throw RecorderSchemaError(schema: schema, message: "Expected string array at '\(key)'")
        }
        var out: [String] = []
        out.reserveCapacity(items.count)
        for (idx, item) in items.enumerated() {
            guard case .string(let str) = item else {
                throw RecorderSchemaError(
                    schema: schema,
                    message: "Expected string at '\(key)[\(idx)]'"
                )
            }
            out.append(str)
        }
        return out
    }

    static func encodeStringMap(_ map: [String: String]) -> PureJSONValue {
        let entries = map.keys.sorted(by: jsStringLessThan).map { key in
            (key, PureJSONValue.string(map[key]!))
        }
        return .object(entries)
    }
}
