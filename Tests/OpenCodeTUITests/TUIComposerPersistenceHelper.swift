#if os(macOS) || os(Linux) || os(Windows)
import Foundation
#elseif canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeTUI

/// Foundation-backed fixture and temp-directory helpers for `TUIComposerPersistenceTests`
/// (kept separate from `import Testing` to satisfy macOS CLT cross-import constraints).
enum TUIComposerPersistenceHelper {
    static func makeInMemoryFileSystem(textFiles: [String: String] = [:]) -> InMemoryFileSystem {
        var binary: [String: [UInt8]] = [:]
        for (path, content) in textFiles {
            binary[path] = Array(content.utf8)
        }
        return InMemoryFileSystem(initialFiles: binary)
    }

    static func readTextFile(_ path: String, from fs: InMemoryFileSystem) async -> String? {
        guard let bytes = try? await fs.readFile(at: path) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func decodeJSONObject(_ text: String) -> [String: JSONValue]? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
              case .object(let dict) = value
        else {
            return nil
        }
        return dict
    }

    static func encodeModelState(_ state: TUIPersistedModelState) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(state) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeModelState(_ json: String) -> TUIPersistedModelState? {
        try? JSONDecoder().decode(TUIPersistedModelState.self, from: Data(json.utf8))
    }

    static func decodePreferences(_ json: String) -> TUIPersistedPreferences? {
        try? JSONDecoder().decode(TUIPersistedPreferences.self, from: Data(json.utf8))
    }

    #if os(macOS) || os(Linux)
    static func makeTemporaryDirectory(prefix: String = "opencode-tui-editor-test") throws -> String {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.path
    }

    static func listDirectory(_ path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }

    static func removePath(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
    #endif
}
