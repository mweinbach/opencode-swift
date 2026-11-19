import Foundation
import Synchronization
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Protocol abstracting OpenTunnel profile identity persistence (XDG disk store, in-memory store,
/// or custom virtual filesystem adapter).
public protocol OpenTunnelStorage: Sendable {
    func profiles() async throws -> [String]
    func load(profile: String) async throws -> OpenTunnelIdentity?
    func save(profile: String, identity: OpenTunnelIdentity) async throws
    func loadPending(profile: String) async throws -> OpenTunnelPendingIdentity?
    func savePending(profile: String, pending: OpenTunnelPendingIdentity) async throws
    func remove(profile: String) async throws
    func list() async throws -> [OpenTunnelStoredTunnel]
}

public extension OpenTunnelStorage {
    func load() async throws -> OpenTunnelIdentity? {
        try await load(profile: OpenTunnelClientModule.defaultProfile)
    }

    func save(_ identity: OpenTunnelIdentity) async throws {
        try await save(profile: OpenTunnelClientModule.defaultProfile, identity: identity)
    }

    func loadPending() async throws -> OpenTunnelPendingIdentity? {
        try await loadPending(profile: OpenTunnelClientModule.defaultProfile)
    }

    func savePending(_ pending: OpenTunnelPendingIdentity) async throws {
        try await savePending(profile: OpenTunnelClientModule.defaultProfile, pending: pending)
    }

    func remove() async throws {
        try await remove(profile: OpenTunnelClientModule.defaultProfile)
    }
}

/// Platform selector for XDG / Windows storage root resolution.
public enum OpenTunnelStoragePlatform: String, Equatable, Hashable, Sendable {
    case posix
    case windows

    public static var current: OpenTunnelStoragePlatform {
        #if os(Windows)
        return .windows
        #else
        return .posix
        #endif
    }
}

/// XDG & Windows profile directory path resolution for OpenTunnel storage.
public enum OpenTunnelXDGPaths {
    /// Resolves the primary OpenTunnel storage root directory:
    /// - POSIX: `$XDG_CONFIG_HOME/opentunnel` -> `~/.config/opentunnel` (or `$XDG_DATA_HOME/opentunnel` if only `XDG_DATA_HOME` is set)
    /// - Windows: `%XDG_CONFIG_HOME%\opentunnel` -> `%APPDATA%\opentunnel` -> `%LOCALAPPDATA%\opentunnel` -> `<home>\.config\opentunnel`
    public static func primaryRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String? = nil,
        platform: OpenTunnelStoragePlatform = .current
    ) -> String {
        let sep = platform == .windows ? "\\" : "/"
        let home = homeDirectory ?? defaultHomeDirectory(environment: environment)

        func nonEmpty(_ key: String) -> String? {
            guard let val = environment[key]?.trimmingASCIIWhitespace(), !val.isEmpty else { return nil }
            return val
        }

        if let xdgConfig = nonEmpty("XDG_CONFIG_HOME") {
            return joinPath([xdgConfig, "opentunnel"], separator: sep)
        }

        if platform == .windows {
            if let appData = nonEmpty("APPDATA") {
                return joinPath([appData, "opentunnel"], separator: sep)
            }
            if let localAppData = nonEmpty("LOCALAPPDATA") {
                return joinPath([localAppData, "opentunnel"], separator: sep)
            }
        }

        return joinPath([home, ".config", "opentunnel"], separator: sep)
    }

    /// Additional fallback roots checked when reading existing identities created by upstream
    /// OpenTunnel CLI/SDK (`$XDG_DATA_HOME/opentunnel` / `~/.local/share/opentunnel`) or state stores.
    public static func fallbackReadRoots(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String? = nil,
        platform: OpenTunnelStoragePlatform = .current
    ) -> [String] {
        let sep = platform == .windows ? "\\" : "/"
        let home = homeDirectory ?? defaultHomeDirectory(environment: environment)
        let primary = primaryRoot(environment: environment, homeDirectory: home, platform: platform)

        func nonEmpty(_ key: String) -> String? {
            guard let val = environment[key]?.trimmingASCIIWhitespace(), !val.isEmpty else { return nil }
            return val
        }

        var candidates: [String] = []
        if let xdgData = nonEmpty("XDG_DATA_HOME") {
            candidates.append(joinPath([xdgData, "opentunnel"], separator: sep))
        } else {
            candidates.append(joinPath([home, ".local", "share", "opentunnel"], separator: sep))
        }
        if let xdgConfig = nonEmpty("XDG_CONFIG_HOME") {
            candidates.append(joinPath([xdgConfig, "opentunnel"], separator: sep))
        } else {
            candidates.append(joinPath([home, ".config", "opentunnel"], separator: sep))
        }
        if let xdgState = nonEmpty("XDG_STATE_HOME") {
            candidates.append(joinPath([xdgState, "opentunnel"], separator: sep))
        } else {
            candidates.append(joinPath([home, ".local", "state", "opentunnel"], separator: sep))
        }

        var seen: Set<String> = [primary]
        var unique: [String] = []
        for path in candidates where seen.insert(path).inserted {
            unique.append(path)
        }
        return unique
    }

    internal static func defaultHomeDirectory(environment: [String: String]) -> String {
        if let home = environment["HOME"]?.trimmingASCIIWhitespace(), !home.isEmpty {
            return home
        }
        if let profile = environment["USERPROFILE"]?.trimmingASCIIWhitespace(), !profile.isEmpty {
            return profile
        }
        #if os(WASI)
        return "/"
        #else
        return FileManager.default.homeDirectoryForCurrentUser.path
        #endif
    }

    internal static func joinPath(_ parts: [String], separator: String = "/") -> String {
        var cleaned: [String] = []
        for (idx, part) in parts.enumerated() {
            if part.isEmpty { continue }
            var segment = part
            if idx > 0 {
                while segment.hasPrefix("/") || segment.hasPrefix("\\") {
                    segment.removeFirst()
                }
            }
            while segment.count > 1 && (segment.hasSuffix("/") || segment.hasSuffix("\\")) {
                segment.removeLast()
            }
            cleaned.append(segment)
        }
        return cleaned.joined(separator: separator)
    }
}

// MARK: - In-Memory Storage (Injectable for Tests)

/// Thread-safe in-memory `OpenTunnelStorage` implementation for tests and ephemeral sessions.
public final class OpenTunnelMemoryStorage: OpenTunnelStorage, Sendable {
    private struct State: Sendable {
        var identities: [String: OpenTunnelIdentity] = [:]
        var pending: [String: OpenTunnelPendingIdentity] = [:]
    }

    private let state: Mutex<State>

    public init(
        initialIdentities: [String: OpenTunnelIdentity] = [:],
        initialPending: [String: OpenTunnelPendingIdentity] = [:]
    ) {
        self.state = Mutex(State(identities: initialIdentities, pending: initialPending))
    }

    public func profiles() async throws -> [String] {
        state.withLock { s in
            Array(Set(s.identities.keys).union(s.pending.keys)).sorted()
        }
    }

    public func load(profile: String) async throws -> OpenTunnelIdentity? {
        try validateProfile(profile)
        return state.withLock { $0.identities[profile] }
    }

    public func save(profile: String, identity: OpenTunnelIdentity) async throws {
        try validateProfile(profile)
        state.withLock { s in
            s.identities[profile] = identity
            s.pending.removeValue(forKey: profile)
        }
    }

    public func loadPending(profile: String) async throws -> OpenTunnelPendingIdentity? {
        try validateProfile(profile)
        return state.withLock { $0.pending[profile] }
    }

    public func savePending(profile: String, pending: OpenTunnelPendingIdentity) async throws {
        try validateProfile(profile)
        state.withLock { s in
            s.pending[profile] = pending
        }
    }

    public func remove(profile: String) async throws {
        try validateProfile(profile)
        state.withLock { s in
            s.identities.removeValue(forKey: profile)
            s.pending.removeValue(forKey: profile)
        }
    }

    public func list() async throws -> [OpenTunnelStoredTunnel] {
        state.withLock { s in
            s.identities.keys.sorted().compactMap { key in
                s.identities[key].map { OpenTunnelStoredTunnel(profile: key, tunnel: $0) }
            }
        }
    }

    private func validateProfile(_ profile: String) throws {
        guard OpenTunnelNames.isValidProfileName(profile) else {
            throw OpenTunnelStorageError(message: "Invalid profile name '\(profile)'")
        }
    }
}

// MARK: - XDG Disk Storage (Atomic 0600 Persistence)

/// On-disk JSON metadata stored in `tunnel.json` matching upstream OpenTunnel layout.
public struct OpenTunnelMetadataRecord: Equatable, Hashable, Sendable, Codable {
    public let id: String
    public let hostname: String
    public let certificateExpiry: String

    public init(id: String, hostname: String, certificateExpiry: String) {
        self.id = id
        self.hostname = hostname
        self.certificateExpiry = certificateExpiry
    }
}

/// On-disk JSON metadata stored in `pending.json` while certificate issuance is in progress.
public struct OpenTunnelPendingMetadataRecord: Equatable, Hashable, Sendable, Codable {
    public let id: String
    public let hostname: String
    public let csr: String

    public init(id: String, hostname: String, csr: String) {
        self.id = id
        self.hostname = hostname
        self.csr = csr
    }
}

/// XDG-compliant on-disk profile store persisting OpenTunnel identities and secrets atomically
/// with `0700` profile directories and `0600` file permissions.
public final class OpenTunnelXDGStorage: OpenTunnelStorage, Sendable {
    public let rootDirectory: String
    public let fallbackRoots: [String]
    private let pathSeparator: String

    /// Creates an XDG/Windows storage rooted according to environment variables and platform conventions.
    public static func xdg(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String? = nil,
        platform: OpenTunnelStoragePlatform = .current
    ) -> OpenTunnelXDGStorage {
        let root = OpenTunnelXDGPaths.primaryRoot(
            environment: environment,
            homeDirectory: homeDirectory,
            platform: platform
        )
        let fallbacks = OpenTunnelXDGPaths.fallbackReadRoots(
            environment: environment,
            homeDirectory: homeDirectory,
            platform: platform
        )
        return OpenTunnelXDGStorage(
            rootDirectory: root,
            fallbackRoots: fallbacks,
            platform: platform
        )
    }

    /// Creates a storage explicitly rooted at `rootDirectory` (with optional fallback read roots).
    public init(
        rootDirectory: String,
        fallbackRoots: [String] = [],
        platform: OpenTunnelStoragePlatform = .current
    ) {
        self.rootDirectory = rootDirectory
        self.fallbackRoots = fallbackRoots
        self.pathSeparator = platform == .windows ? "\\" : "/"
    }

    /// Returns the filesystem directory path for a given profile under `rootDirectory`.
    public func profileDirectory(for profile: String) -> String {
        OpenTunnelXDGPaths.joinPath([rootDirectory, profile], separator: pathSeparator)
    }

    public func profiles() async throws -> [String] {
        #if os(WASI)
        return []
        #else
        var found: Set<String> = []
        for root in [rootDirectory] + fallbackRoots {
            guard FileManager.default.fileExists(atPath: root) else { continue }
            let entries: [String]
            do {
                entries = try FileManager.default.contentsOfDirectory(atPath: root)
            } catch {
                if root == rootDirectory {
                    throw OpenTunnelStorageError(message: "Failed to list \(root)", cause: error)
                }
                continue
            }
            for entry in entries {
                var isDir: ObjCBool = false
                let full = OpenTunnelXDGPaths.joinPath([root, entry], separator: pathSeparator)
                if FileManager.default.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue {
                    if OpenTunnelNames.isValidProfileName(entry) {
                        found.insert(entry)
                    }
                }
            }
        }
        return found.sorted()
        #endif
    }

    public func load(profile: String) async throws -> OpenTunnelIdentity? {
        try validateProfile(profile)
        #if os(WASI)
        return nil
        #else
        for root in [rootDirectory] + fallbackRoots {
            if let loaded = try loadFromDirectory(root: root, profile: profile) {
                return loaded
            }
            if let legacy = try loadLegacySingleFile(root: root, profile: profile) {
                return legacy
            }
        }
        return nil
        #endif
    }

    public func save(profile: String, identity: OpenTunnelIdentity) async throws {
        try validateProfile(profile)
        #if os(WASI)
        throw OpenTunnelStorageError(message: "Disk storage is unavailable on WASI; use OpenTunnelMemoryStorage")
        #else
        let dir = profileDirectory(for: profile)
        try ensureSecureDirectory(dir)

        let metadata = OpenTunnelMetadataRecord(
            id: identity.id,
            hostname: identity.hostname,
            certificateExpiry: identity.certificateExpiry
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metaBytes: [UInt8]
        do {
            var data = try encoder.encode(metadata)
            data.append(0x0A)
            metaBytes = Array(data)
        } catch {
            throw OpenTunnelStorageError(message: "Failed to encode tunnel metadata for \(profile)", cause: error)
        }

        try writeAtomicPrivateFile(metaBytes, to: join(dir, "tunnel.json"))
        try writeAtomicPrivateFile(Array("\(identity.token)\n".utf8), to: join(dir, "token"))
        try writeAtomicPrivateFile(Array(identity.privateKey.utf8), to: join(dir, "private-key.pem"))
        try writeAtomicPrivateFile(Array(identity.certificate.utf8), to: join(dir, "certificate.pem"))
        try writeAtomicPrivateFile(Array(identity.chain.utf8), to: join(dir, "chain.pem"))

        let pendingPath = join(dir, "pending.json")
        if FileManager.default.fileExists(atPath: pendingPath) {
            try? FileManager.default.removeItem(atPath: pendingPath)
        }
        #endif
    }

    public func loadPending(profile: String) async throws -> OpenTunnelPendingIdentity? {
        try validateProfile(profile)
        #if os(WASI)
        return nil
        #else
        for root in [rootDirectory] + fallbackRoots {
            let dir = OpenTunnelXDGPaths.joinPath([root, profile], separator: pathSeparator)
            guard let metadataText = try readOptionalUTF8(join(dir, "pending.json")) else {
                continue
            }
            let token = try readOptionalUTF8(join(dir, "token"))?.trimmingASCIIWhitespace()
            let privateKey = try readOptionalUTF8(join(dir, "private-key.pem"))
            guard let token, !token.isEmpty, let privateKey, !privateKey.isEmpty else {
                throw OpenTunnelStorageError(message: "Incomplete pending tunnel identity for \(profile)")
            }
            do {
                let record = try JSONDecoder().decode(
                    OpenTunnelPendingMetadataRecord.self,
                    from: Data(metadataText.utf8)
                )
                return OpenTunnelPendingIdentity(
                    id: record.id,
                    hostname: record.hostname,
                    token: token,
                    privateKey: privateKey,
                    csr: record.csr
                )
            } catch {
                throw OpenTunnelStorageError(message: "Corrupt pending tunnel metadata for \(profile)", cause: error)
            }
        }
        return nil
        #endif
    }

    public func savePending(profile: String, pending: OpenTunnelPendingIdentity) async throws {
        try validateProfile(profile)
        #if os(WASI)
        throw OpenTunnelStorageError(message: "Disk storage is unavailable on WASI; use OpenTunnelMemoryStorage")
        #else
        let dir = profileDirectory(for: profile)
        try ensureSecureDirectory(dir)

        let metadata = OpenTunnelPendingMetadataRecord(
            id: pending.id,
            hostname: pending.hostname,
            csr: pending.csr
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metaBytes: [UInt8]
        do {
            var data = try encoder.encode(metadata)
            data.append(0x0A)
            metaBytes = Array(data)
        } catch {
            throw OpenTunnelStorageError(message: "Failed to encode pending tunnel metadata for \(profile)", cause: error)
        }

        try writeAtomicPrivateFile(metaBytes, to: join(dir, "pending.json"))
        try writeAtomicPrivateFile(Array("\(pending.token)\n".utf8), to: join(dir, "token"))
        try writeAtomicPrivateFile(Array(pending.privateKey.utf8), to: join(dir, "private-key.pem"))
        #endif
    }

    public func remove(profile: String) async throws {
        try validateProfile(profile)
        #if os(WASI)
        return
        #else
        let dir = profileDirectory(for: profile)
        if FileManager.default.fileExists(atPath: dir) {
            do {
                try FileManager.default.removeItem(atPath: dir)
            } catch {
                throw OpenTunnelStorageError(message: "Failed to remove tunnel identity for \(profile)", cause: error)
            }
        }
        #endif
    }

    public func list() async throws -> [OpenTunnelStoredTunnel] {
        let names = try await profiles()
        var results: [OpenTunnelStoredTunnel] = []
        for name in names {
            if let identity = try await load(profile: name) {
                results.append(OpenTunnelStoredTunnel(profile: name, tunnel: identity))
            }
        }
        return results
    }

    // MARK: - Internal Helpers

    private func validateProfile(_ profile: String) throws {
        guard OpenTunnelNames.isValidProfileName(profile) else {
            throw OpenTunnelStorageError(message: "Invalid profile name '\(profile)'")
        }
    }

    private func join(_ base: String, _ name: String) -> String {
        OpenTunnelXDGPaths.joinPath([base, name], separator: pathSeparator)
    }

    #if !os(WASI)
    private func loadFromDirectory(root: String, profile: String) throws -> OpenTunnelIdentity? {
        let dir = OpenTunnelXDGPaths.joinPath([root, profile], separator: pathSeparator)
        guard let metadataText = try readOptionalUTF8(join(dir, "tunnel.json")) else {
            return nil
        }
        let token = try readOptionalUTF8(join(dir, "token"))?.trimmingASCIIWhitespace()
        let privateKey = try readOptionalUTF8(join(dir, "private-key.pem"))
        let certificate = try readOptionalUTF8(join(dir, "certificate.pem"))
        let chain = try readOptionalUTF8(join(dir, "chain.pem"))

        guard let token, !token.isEmpty,
              let privateKey, !privateKey.isEmpty,
              let certificate, !certificate.isEmpty,
              let chain
        else {
            throw OpenTunnelStorageError(message: "Incomplete tunnel identity for \(profile)")
        }

        do {
            let record = try JSONDecoder().decode(
                OpenTunnelMetadataRecord.self,
                from: Data(metadataText.utf8)
            )
            return OpenTunnelIdentity(
                id: record.id,
                hostname: record.hostname,
                token: token,
                privateKey: privateKey,
                certificate: certificate,
                chain: chain,
                certificateExpiry: record.certificateExpiry
            )
        } catch {
            throw OpenTunnelStorageError(message: "Corrupt tunnel metadata for \(profile)", cause: error)
        }
    }

    private func loadLegacySingleFile(root: String, profile: String) throws -> OpenTunnelIdentity? {
        let singlePath = OpenTunnelXDGPaths.joinPath([root, "\(profile).json"], separator: pathSeparator)
        guard let raw = try readOptionalUTF8(singlePath) else {
            return nil
        }
        if let decoded = try? JSONDecoder().decode(OpenTunnelIdentity.self, from: Data(raw.utf8)),
           !decoded.hostname.isEmpty
        {
            return decoded
        }
        struct MinimalLegacy: Decodable {
            let id: String?
            let hostname: String
            let token: String?
            let privateKey: String?
            let certificate: String?
            let chain: String?
            let certificateExpiry: String?
        }
        if let minimal = try? JSONDecoder().decode(MinimalLegacy.self, from: Data(raw.utf8)),
           !minimal.hostname.isEmpty
        {
            return OpenTunnelIdentity(
                id: minimal.id ?? profile,
                hostname: minimal.hostname,
                token: minimal.token ?? "",
                privateKey: minimal.privateKey ?? "",
                certificate: minimal.certificate ?? "",
                chain: minimal.chain ?? "",
                certificateExpiry: minimal.certificateExpiry ?? "2099-01-01T00:00:00.000Z"
            )
        }
        return nil
    }

    private func readOptionalUTF8(_ path: String) throws -> String? {
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return String(decoding: data, as: UTF8.self)
        } catch {
            let nsErr = error as NSError
            if nsErr.domain == NSCocoaErrorDomain && nsErr.code == NSFileReadNoSuchFileError {
                return nil
            }
            if nsErr.domain == NSPOSIXErrorDomain && nsErr.code == Int(ENOENT) {
                return nil
            }
            throw OpenTunnelStorageError(message: "Failed to read \(path)", cause: error)
        }
    }

    private func ensureSecureDirectory(_ path: String) throws {
        do {
            try FileManager.default.createDirectory(
                atPath: path,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        } catch {
            throw OpenTunnelStorageError(message: "Failed to create directory \(path)", cause: error)
        }
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        _ = path.withCString { chmod($0, 0o700) }
        #endif
    }

    /// Atomically writes `bytes` to `targetPath` with `0600` owner-only permissions and zero
    /// world-readable creation window on POSIX platforms.
    private func writeAtomicPrivateFile(_ bytes: [UInt8], to targetPath: String) throws {
        let dir = (targetPath as NSString).deletingLastPathComponent
        let baseName = (targetPath as NSString).lastPathComponent
        let nonce = UInt64.random(in: 0...UInt64.max)
        let tempPath = OpenTunnelXDGPaths.joinPath(
            [dir, ".\(baseName).\(String(nonce, radix: 16)).tmp"],
            separator: pathSeparator
        )

        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        let fd = tempPath.withCString { cPath in
            open(cPath, O_WRONLY | O_CREAT | O_TRUNC, mode_t(0o600))
        }
        guard fd >= 0 else {
            throw OpenTunnelStorageError(message: "Failed to create temporary file \(tempPath) (errno \(errno))")
        }

        var writeFailedErrno: Int32? = nil
        var written = 0
        while written < bytes.count {
            let n: Int = bytes.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return 0 }
                #if canImport(Darwin)
                return Int(Darwin.write(fd, base.advanced(by: written), bytes.count - written))
                #elseif canImport(Glibc)
                return Int(Glibc.write(fd, base.advanced(by: written), bytes.count - written))
                #elseif canImport(Musl)
                return Int(Musl.write(fd, base.advanced(by: written), bytes.count - written))
                #endif
            }
            if n > 0 {
                written += n
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                writeFailedErrno = errno
                break
            }
        }
        _ = fchmod(fd, 0o600)
        #if canImport(Darwin)
        _ = Darwin.close(fd)
        #elseif canImport(Glibc)
        _ = Glibc.close(fd)
        #elseif canImport(Musl)
        _ = Musl.close(fd)
        #endif

        if let err = writeFailedErrno {
            _ = tempPath.withCString { unlink($0) }
            throw OpenTunnelStorageError(message: "Failed to write \(targetPath) (errno \(err))")
        }

        let renamed = tempPath.withCString { src in
            targetPath.withCString { dst in
                rename(src, dst)
            }
        }
        if renamed != 0 {
            let err = errno
            _ = tempPath.withCString { unlink($0) }
            throw OpenTunnelStorageError(message: "Failed to atomically replace \(targetPath) (errno \(err))")
        }
        #else
        do {
            try Data(bytes).write(to: URL(fileURLWithPath: tempPath), options: .atomic)
            if FileManager.default.fileExists(atPath: targetPath) {
                try FileManager.default.removeItem(atPath: targetPath)
            }
            try FileManager.default.moveItem(atPath: tempPath, toPath: targetPath)
        } catch {
            try? FileManager.default.removeItem(atPath: tempPath)
            throw OpenTunnelStorageError(message: "Failed to write \(targetPath)", cause: error)
        }
        #endif
    }
    #endif
}
