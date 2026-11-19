#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import OpenCodeSchema
import OpenCodeTUI

/// Foundation/Codable helpers kept outside `import Testing` files per the macOS CLT cross-import rule.
enum ThemePatchmarkTestHelper {
    static func encodeThemeDocumentJSON(_ document: ThemeDocument) throws -> String {
        let data = try JSONEncoder().encode(document)
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeThemeV1JSON(_ json: String) throws -> ThemeV1Json {
        try JSONDecoder().decode(ThemeV1Json.self, from: Data(json.utf8))
    }

    static func encodeThemeV1JSON(_ v1: ThemeV1Json) throws -> String {
        let data = try JSONEncoder().encode(v1)
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeJSONValue(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    static func roundTripJSON<T: Codable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
