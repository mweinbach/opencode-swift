#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import OpenCodeUtil

/// Dynamic module resolution and loading contracts adapted for native Swift from
/// `packages/util/src/runtime/import.{bun,node,workerd}.ts`.
public enum RuntimeImport {
    public struct Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
        public let message: String

        public init(_ message: String) {
            self.message = message
        }

        public var description: String { message }
    }

    public static let candidateExtensions: [String] = [
        ".ts", ".tsx", ".js", ".jsx", ".mts", ".mjs", ".cts", ".cjs",
    ]

    /// Node-style module loader contract (Swift native plugin host resolves out-of-process JS/TS modules).
    // parity: util/src/runtime/import.node.ts#importModule [status=adapted hash=344852c6ab04]
    public static func importNodeModule(_ specifier: String) async throws -> AnySendableValue {
        throw Error("Native Swift runtime delegates dynamic JS module import '\(specifier)' to the plugin host")
    }

    /// Resolves a module specifier relative to `directory`, probing TypeScript/JavaScript extensions when omitted.
    // parity: util/src/runtime/import.node.ts#resolveModule [status=adapted hash=dcce5f69130a]
    public static func resolveNodeModule(
        specifier: String,
        directory: String,
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared
    ) async throws -> String {
        if specifier.hasPrefix("node:") { return specifier }
        let base: String
        if specifier.hasPrefix("/") {
            base = specifier
        } else {
            let trimmedDir = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
            let trimmedSpec = specifier.hasPrefix("./") ? String(specifier.dropFirst(2)) : specifier
            base = "\(trimmedDir)/\(trimmedSpec)"
        }
        if await fileSystem.exists(at: base) {
            return "file://\(base)"
        }
        let hasExt = (base.split(separator: "/").last?.contains(".") == true)
        if !hasExt {
            for ext in candidateExtensions {
                let candidate = base + ext
                if await fileSystem.exists(at: candidate) {
                    return "file://\(candidate)"
                }
            }
        }
        throw Error("Unable to resolve module '\(specifier)' from '\(directory)'")
    }

    // parity: util/src/runtime/import.bun.ts#importModule [status=adapted hash=2688fbecd340]
    public static func importBunModule(_ specifier: String) async throws -> AnySendableValue {
        try await importNodeModule(specifier)
    }

    // parity: util/src/runtime/import.bun.ts#resolveModule [status=adapted hash=730bfa5525a3]
    public static func resolveBunModule(
        specifier: String,
        directory: String,
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared
    ) async throws -> String {
        try await resolveNodeModule(specifier: specifier, directory: directory, fileSystem: fileSystem)
    }

    // parity: util/src/runtime/import.workerd.ts#importModule [status=implemented hash=bcc321a0fd4e]
    public static func importWorkerdModule(_ specifier: String) async throws -> AnySendableValue {
        _ = specifier
        throw Error("Dynamic module loading is unavailable on workerd")
    }

    // parity: util/src/runtime/import.workerd.ts#resolveModule [status=implemented hash=06410dbe7f08]
    public static func resolveWorkerdModule(_ specifier: String, directory: String) throws -> String {
        _ = (specifier, directory)
        throw Error("Dynamic module loading is unavailable on workerd")
    }
}
