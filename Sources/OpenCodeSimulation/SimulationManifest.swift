#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import OpenCodePlatform
import OpenCodeUtil

/// Drive manifest loading, validation, and registry path resolution (`packages/simulation/src/manifest.ts`).
public enum DriveManifest {
    /// Loopback WebSocket endpoints and optional viewport/recording configuration for a Drive instance.
    // parity: simulation/src/manifest.ts#Manifest [status=implemented hash=7ee528f5bafd]
    public struct Manifest: Equatable, Hashable, Sendable, Codable {
        public struct Endpoints: Equatable, Hashable, Sendable, Codable {
            public let ui: String
            public let backend: String

            public init(ui: String, backend: String) {
                self.ui = ui
                self.backend = backend
            }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let ui = try c.decode(String.self, forKey: .ui)
                let backend = try c.decode(String.self, forKey: .backend)
                if let err = DriveManifest.validateEndpoint(ui) {
                    throw DecodingError.dataCorruptedError(forKey: .ui, in: c, debugDescription: err)
                }
                if let err = DriveManifest.validateEndpoint(backend) {
                    throw DecodingError.dataCorruptedError(forKey: .backend, in: c, debugDescription: err)
                }
                self.ui = ui
                self.backend = backend
            }

            private enum CodingKeys: String, CodingKey {
                case ui, backend
            }
        }

        public struct Viewport: Equatable, Hashable, Sendable, Codable {
            public let cols: Int
            public let rows: Int

            public init(cols: Int, rows: Int) {
                self.cols = cols
                self.rows = rows
            }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let cols = try c.decode(Int.self, forKey: .cols)
                let rows = try c.decode(Int.self, forKey: .rows)
                guard cols > 0 else {
                    throw DecodingError.dataCorruptedError(forKey: .cols, in: c, debugDescription: "viewport.cols must be a positive integer")
                }
                guard rows > 0 else {
                    throw DecodingError.dataCorruptedError(forKey: .rows, in: c, debugDescription: "viewport.rows must be a positive integer")
                }
                self.cols = cols
                self.rows = rows
            }

            private enum CodingKeys: String, CodingKey {
                case cols, rows
            }
        }

        public struct Recording: Equatable, Hashable, Sendable, Codable {
            public let timeline: String

            public init(timeline: String) {
                self.timeline = timeline
            }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let timeline = try c.decode(String.self, forKey: .timeline)
                guard DriveManifest.isAbsolutePath(timeline) else {
                    throw DecodingError.dataCorruptedError(forKey: .timeline, in: c, debugDescription: "an absolute path")
                }
                self.timeline = timeline
            }

            private enum CodingKeys: String, CodingKey {
                case timeline
            }
        }

        public let endpoints: Endpoints
        public let viewport: Viewport?
        public let recording: Recording?

        public init(
            endpoints: Endpoints,
            viewport: Viewport? = nil,
            recording: Recording? = nil
        ) {
            self.endpoints = endpoints
            self.viewport = viewport
            self.recording = recording
        }

        /// Validates every constraint on an in-memory `Manifest`.
        public func validate() throws(ResolveError) {
            if let err = DriveManifest.validateEndpoint(endpoints.ui) {
                throw ResolveError(reason: .decode, message: "Invalid ui endpoint: \(err)")
            }
            if let err = DriveManifest.validateEndpoint(endpoints.backend) {
                throw ResolveError(reason: .decode, message: "Invalid backend endpoint: \(err)")
            }
            if let viewport {
                guard viewport.cols > 0 && viewport.rows > 0 else {
                    throw ResolveError(reason: .decode, message: "viewport cols and rows must be positive integers")
                }
            }
            if let recording, !DriveManifest.isAbsolutePath(recording.timeline) {
                throw ResolveError(reason: .decode, message: "recording.timeline must be an absolute path")
            }
        }
    }

    /// Tagged error returned when Drive manifest configuration, I/O, or JSON decoding fails.
    // parity: simulation/src/manifest.ts#ResolveError [status=implemented hash=66f4fbdc5bb1]
    public struct ResolveError: Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public static let tag = "DriveManifest.ResolveError"

        public enum Reason: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
            case config
            case notFound = "not-found"
            case read
            case decode
        }

        public let reason: Reason
        public let path: String?
        public let message: String
        public let causeDescription: String?

        public init(
            reason: Reason,
            path: String? = nil,
            message: String,
            causeDescription: String? = nil
        ) {
            self.reason = reason
            self.path = path
            self.message = message
            self.causeDescription = causeDescription
        }

        public var description: String { message }

        private enum CodingKeys: String, CodingKey {
            case _tag, reason, path, message, causeDescription
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let tag = try c.decodeIfPresent(String.self, forKey: ._tag), tag != Self.tag {
                throw DecodingError.dataCorruptedError(forKey: ._tag, in: c, debugDescription: "Expected tag '\(Self.tag)', got '\(tag)'")
            }
            self.reason = try c.decode(Reason.self, forKey: .reason)
            self.path = try c.decodeIfPresent(String.self, forKey: .path)
            self.message = try c.decode(String.self, forKey: .message)
            self.causeDescription = try c.decodeIfPresent(String.self, forKey: .causeDescription)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(Self.tag, forKey: ._tag)
            try c.encode(reason, forKey: .reason)
            try c.encodeIfPresent(path, forKey: .path)
            try c.encode(message, forKey: .message)
            try c.encodeIfPresent(causeDescription, forKey: .causeDescription)
        }
    }

    /// Default Drive manifest used when `OPENCODE_DRIVE=1`.
    // parity: simulation/src/manifest.ts#defaults [status=implemented hash=a968a2785c9c]
    public static let defaults = Manifest(
        endpoints: Manifest.Endpoints(
            ui: "ws://127.0.0.1:40900",
            backend: "ws://127.0.0.1:40950"
        )
    )

    /// Resolves and validates the Drive manifest from `OPENCODE_DRIVE`, `DRIVE_REGISTRY_DIR`, and `XDG_STATE_HOME`.
    // parity: simulation/src/manifest.ts#resolve [status=implemented hash=181dcf45b07d]
    public static func resolve(
        environment: any EnvironmentProviding = SystemEnvironment.shared,
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared
    ) async throws(ResolveError) -> Manifest {
        guard let name = environment.variable("OPENCODE_DRIVE"), isValidInstanceName(name) else {
            let raw = environment.variable("OPENCODE_DRIVE") ?? "<unset>"
            throw ResolveError(
                reason: .config,
                message: "Invalid Drive configuration: expected a valid Drive instance name for OPENCODE_DRIVE (got \(raw))",
                causeDescription: raw
            )
        }
        if name == "1" {
            return defaults
        }

        let stateDir: String
        if let xdg = environment.variable("XDG_STATE_HOME"), !xdg.isEmpty {
            stateDir = xdg
        } else {
            let home = environment.homeDirectory ?? "/"
            stateDir = joinPath(joinPath(home, ".local"), "state")
        }

        let directory: String
        if let registryDir = environment.variable("DRIVE_REGISTRY_DIR"), !registryDir.isEmpty {
            directory = registryDir
        } else {
            directory = joinPath(joinPath(stateDir, "opencode-drive"), "instances")
        }

        let file = joinPath(directory, "\(name).json")
        let bytes: [UInt8]
        do {
            bytes = try await fileSystem.readFile(at: file)
        } catch let err as PlatformError {
            switch err {
            case .notFound:
                throw ResolveError(
                    reason: .notFound,
                    path: file,
                    message: "Drive manifest not found: \(file)",
                    causeDescription: err.description
                )
            default:
                throw ResolveError(
                    reason: .read,
                    path: file,
                    message: "Failed to read Drive manifest: \(file): \(err.description)",
                    causeDescription: err.description
                )
            }
        } catch {
            let desc = String(describing: error)
            throw ResolveError(
                reason: .read,
                path: file,
                message: "Failed to read Drive manifest: \(file): \(desc)",
                causeDescription: desc
            )
        }

        do {
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(bytes))
            try manifest.validate()
            return manifest
        } catch let err as ResolveError {
            throw ResolveError(
                reason: .decode,
                path: file,
                message: "Invalid Drive manifest: \(file): \(err.message)",
                causeDescription: err.causeDescription ?? err.message
            )
        } catch {
            let desc = String(describing: error)
            throw ResolveError(
                reason: .decode,
                path: file,
                message: "Invalid Drive manifest: \(file): \(desc)",
                causeDescription: desc
            )
        }
    }

    /// Decodes and validates a Drive manifest directly from a JSON string.
    public static func decode(_ jsonString: String) throws(ResolveError) -> Manifest {
        do {
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(jsonString.utf8))
            try manifest.validate()
            return manifest
        } catch let err as ResolveError {
            throw err
        } catch {
            let desc = String(describing: error)
            throw ResolveError(reason: .decode, message: "Invalid Drive manifest: \(desc)", causeDescription: desc)
        }
    }

    // MARK: - Validation Helpers

    internal static func isValidInstanceName(_ value: String) -> Bool {
        let utf8 = Array(value.utf8)
        guard utf8.count >= 1 && utf8.count <= 64 else { return false }
        let first = utf8[0]
        let firstValid =
            (first >= 0x30 && first <= 0x39) ||
            (first >= 0x41 && first <= 0x5A) ||
            (first >= 0x61 && first <= 0x7A)
        guard firstValid else { return false }
        for b in utf8.dropFirst() {
            let ok =
                (b >= 0x30 && b <= 0x39) ||
                (b >= 0x41 && b <= 0x5A) ||
                (b >= 0x61 && b <= 0x7A) ||
                b == 0x2E || // '.'
                b == 0x5F || // '_'
                b == 0x2D    // '-'
            if !ok { return false }
        }
        return true
    }

    internal static func validateEndpoint(_ value: String) -> String? {
        guard let components = parseLoopbackWSEndpoint(value) else {
            return "a loopback WebSocket endpoint with an explicit port"
        }
        guard components.port >= 1 && components.port <= 65_535 else {
            return "a loopback WebSocket endpoint with an explicit port"
        }
        return nil
    }

    internal static func parseLoopbackWSEndpoint(_ value: String) -> (host: String, port: Int)? {
        guard value.hasPrefix("ws://") else { return nil }
        let remainder = value.dropFirst(5)
        let authorityEnd = remainder.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? remainder.endIndex
        let authority = String(remainder[..<authorityEnd])
        guard !authority.contains("@") else { return nil }
        guard let colon = authority.lastIndex(of: ":") else { return nil }
        let host = String(authority[..<colon])
        let portStr = String(authority[authority.index(after: colon)...])
        guard host == "127.0.0.1" else { return nil }
        guard !portStr.isEmpty, portStr.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
        guard let port = Int(portStr), port >= 1, port <= 65_535 else { return nil }
        return (host: host, port: port)
    }

    internal static func isAbsolutePath(_ value: String) -> Bool {
        if value.hasPrefix("/") { return true }
        let chars = Array(value)
        if chars.count >= 3, chars[0].isASCII && chars[0].isLetter, chars[1] == ":", (chars[2] == "/" || chars[2] == "\\") {
            return true
        }
        if value.hasPrefix("\\\\") { return true }
        return false
    }

    private static func joinPath(_ base: String, _ component: String) -> String {
        if base.isEmpty { return component }
        if base.hasSuffix("/") { return base + component }
        return "\(base)/\(component)"
    }
}
