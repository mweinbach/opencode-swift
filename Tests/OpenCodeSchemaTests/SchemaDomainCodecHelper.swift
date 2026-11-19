#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import OpenCodeSchema

/// Foundation JSON codec helper separated from Swift Testing files per the macOS CLT cross-import rule.
enum SchemaDomainCodecHelper {
    static func encodeToJSONString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeFromJSONString<T: Decodable>(_ type: T.Type, json: String) throws -> T {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(type, from: data)
    }

    static func roundTrip<T: Codable>(_ value: T) throws -> T {
        let json = try encodeToJSONString(value)
        return try decodeFromJSONString(T.self, json: json)
    }

    static func encodeToJSONValue<T: Encodable>(_ value: T) throws -> JSONValue {
        let json = try encodeToJSONString(value)
        return try decodeFromJSONString(JSONValue.self, json: json)
    }

    static func decodeFromJSONValue<T: Decodable>(_ type: T.Type, value: JSONValue) throws -> T {
        let json = try encodeToJSONString(value)
        return try decodeFromJSONString(type, json: json)
    }

    static func canDecode<T: Decodable>(_ type: T.Type, json: String) -> Bool {
        (try? decodeFromJSONString(type, json: json)) != nil
    }
}
