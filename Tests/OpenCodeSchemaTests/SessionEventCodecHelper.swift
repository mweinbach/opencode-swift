#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import OpenCodeSchema

enum SessionEventCodecHelper {
    static func encodeToString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeFromString<T: Decodable>(_ type: T.Type, json: String) throws -> T {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(type, from: data)
    }

    static func roundTrip<T: Codable>(_ value: T) throws -> (decoded: T, json: String) {
        let json = try encodeToString(value)
        let decoded = try decodeFromString(T.self, json: json)
        return (decoded, json)
    }

    static func decodeJSONObject(_ json: String) throws -> [String: JSONValue] {
        try decodeFromString([String: JSONValue].self, json: json)
    }
}
