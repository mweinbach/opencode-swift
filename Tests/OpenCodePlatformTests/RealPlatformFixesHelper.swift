#if !os(WASI)
import Foundation
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import OpenCodePlatform
import OpenCodeUtil

/// Helper utilities for `RealPlatformFixesTests` (kept separate from `import Testing`
/// to obey the macOS Command Line Tools Swift Testing cross-import rule).
enum RealPlatformFixesHelper {
    static func sendSIGUSR1ToSelf() -> Bool {
        #if os(macOS) || os(Linux)
        return kill(getpid(), SIGUSR1) == 0
        #else
        return false
        #endif
    }

    static func currentEpochMs() -> Int64 {
        Flock.currentEpochMs()
    }

    static func parseJSON(_ bytes: [UInt8]) throws -> PureJSONValue {
        let text = String(decoding: bytes, as: UTF8.self)
        guard let parsed = PureJSON.parse(text) else {
            throw PlatformError.ioFailure("Failed to parse JSON payload: \(text)")
        }
        return parsed
    }

    static func objectField(_ value: PureJSONValue, _ key: String) -> PureJSONValue? {
        guard case .object(let pairs) = value else { return nil }
        for (k, v) in pairs where k == key {
            return v
        }
        return nil
    }

    static func arrayElements(_ value: PureJSONValue) -> [PureJSONValue]? {
        guard case .array(let items) = value else { return nil }
        return items
    }

    static func stringValue(_ value: PureJSONValue?) -> String? {
        guard case .string(let s) = value else { return nil }
        return s
    }

    static func numberValue(_ value: PureJSONValue?) -> Double? {
        guard case .number(let n) = value else { return nil }
        return n
    }

    static func makeTempDirectory(prefix: String = "opencode-real-fixes") throws -> String {
        try PlatformPhase2Helper.makeTempDirectory(prefix: prefix)
    }

    static func removeItemIfExists(at path: String) {
        PlatformPhase2Helper.removeItemIfExists(at: path)
    }
}
