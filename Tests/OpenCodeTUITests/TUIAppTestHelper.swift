#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeTUI
import OpenCodeUtil

/// Foundation/JSON/Filesystem helpers kept outside `import Testing` files per the macOS CLT cross-import rule.
enum TUIAppTestHelper {
    static func decodeJSON(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    static func encodeJSON(_ value: JSONValue) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    static func roundTrip<T: Codable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func encodePromptJSONL(_ prompts: [TUIPrompt.PromptInfo]) throws -> String {
        try prompts.map { prompt in
            String(decoding: try JSONEncoder().encode(prompt), as: UTF8.self)
        }.joined(separator: "\n")
    }

    static func encodeStashJSONL(_ entries: [TUIPrompt.StashEntry]) throws -> String {
        try entries.map { entry in
            String(decoding: try JSONEncoder().encode(entry), as: UTF8.self)
        }.joined(separator: "\n")
    }

    static func encodeFrecencyJSONL(_ entries: [TUIPrompt.FrecencyEntry]) throws -> String {
        try entries.map { entry in
            String(decoding: try JSONEncoder().encode(entry), as: UTF8.self)
        }.joined(separator: "\n")
    }

    static func tempDirectory(prefix: String = "swift-opencode-tui-test") throws -> String {
        #if os(WASI)
        return "/tmp/\(prefix)-\(uuid())"
        #else
        let base = SystemEnvironment.shared.temporaryDirectory
        let dir = "\(base)/\(prefix)-\(uuid())"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
        #endif
    }

    static func removePath(_ path: String) {
        #if !os(WASI)
        try? FileManager.default.removeItem(atPath: path)
        #endif
    }

    static func writeTextFile(_ content: String, to path: String) throws {
        #if !os(WASI)
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(content.utf8).write(to: url)
        #endif
    }
}
