#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import OpenCodeProtocol
import OpenCodeSchema

/// Foundation-backed JSON encoding/decoding helpers for `OpenCodeProtocolTests`.
/// Kept in a separate file that does NOT `import Testing` to satisfy the macOS CLT cross-import rule.
enum ProtocolTestCodec {
    static func encodeToString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeFromString<T: Decodable>(_ type: T.Type, json: String) throws -> T {
        let decoder = JSONDecoder()
        return try decoder.decode(type, from: Data(json.utf8))
    }

    static func roundTrip<T: Codable>(_ value: T) throws -> T {
        let json = try encodeToString(value)
        return try decodeFromString(T.self, json: json)
    }

    static func encodeToJSONValue<T: Encodable>(_ value: T) throws -> JSONValue {
        let json = try encodeToString(value)
        return try decodeFromString(JSONValue.self, json: json)
    }

    static func encodeObjectFields<T: Encodable>(_ value: T) throws -> [String: JSONValue] {
        let jsonValue = try encodeToJSONValue(value)
        guard case .object(let fields) = jsonValue else {
            return [:]
        }
        return fields
    }
}
