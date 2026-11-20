#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import OpenCodePlatform
import OpenCodeUtil

/// Raised when a requested cassette does not exist.
// parity: http-recorder/src/cassette/store.ts#CassetteNotFoundError [status=implemented hash=12f0b724b12a]
public struct CassetteNotFoundError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    public static let tag = "CassetteNotFoundError"
    public let cassetteName: String

    public init(cassetteName: String) {
        self.cassetteName = cassetteName
    }

    // parity: http-recorder/src/cassette/store.ts#CassetteNotFoundError.message [status=implemented hash=ff3a633ea3dc]
    public var message: String {
        "Cassette \"\(cassetteName)\" not found"
    }

    public var description: String { message }
}

/// Raised when a cassette file cannot be parsed or fails schema validation.
// parity: http-recorder/src/cassette/store.ts#InvalidCassetteError [status=implemented hash=2663f30979a9]
public struct InvalidCassetteError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    public static let tag = "InvalidCassetteError"
    public let cassetteName: String
    public let detail: String

    public init(cassetteName: String, description: String) {
        self.cassetteName = cassetteName
        self.detail = description
    }

    // parity: http-recorder/src/cassette/store.ts#InvalidCassetteError.message [status=implemented hash=ff3a633ea3dc]
    public var message: String {
        "Cassette \"\(cassetteName)\" is invalid: \(detail)"
    }

    public var description: String { message }
}

/// Raised when persisting a cassette would leak detected secrets.
// parity: http-recorder/src/cassette/store.ts#UnsafeCassetteError [status=implemented hash=93e8f184a4a3]
public struct UnsafeCassetteError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    public static let tag = "UnsafeCassetteError"
    public let cassetteName: String
    public let findings: [SecretFinding]

    public init(cassetteName: String, findings: [SecretFinding]) {
        self.cassetteName = cassetteName
        self.findings = findings
    }

    // parity: http-recorder/src/cassette/store.ts#UnsafeCassetteError.message [status=implemented hash=a24907177e5f]
    public var message: String {
        let rendered = findings.map { "\($0.path) (\($0.reason))" }.joined(separator: ", ")
        return "Refusing to write cassette \"\(cassetteName)\" because it contains possible secrets: \(rendered)"
    }

    public var description: String { message }
}

/// Raised when a cassette name escapes the recordings root directory.
public struct InvalidCassetteNameError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let name: String

    public init(name: String) {
        self.name = name
    }

    public var message: String {
        "Invalid cassette name \"\(name)\""
    }

    public var description: String { message }
}

/// Storage abstraction for reading, appending, checking, and listing cassettes.
// parity: http-recorder/src/cassette/store.ts#Interface [status=implemented hash=9844f7a06af0]
public protocol CassetteStoreInterface: Sendable {
    func read(_ name: String) async throws -> [Interaction]
    func append(_ name: String, interaction: Interaction, metadata: CassetteMetadata?) async throws
    func exists(_ name: String) async -> Bool
    func list() async throws -> [String]
}

public extension CassetteStoreInterface {
    func append(_ name: String, interaction: Interaction) async throws {
        try await append(name, interaction: interaction, metadata: nil)
    }
}

/// Concrete cassette store service token matching `@opencode/http-recorder/Cassette`.
// parity: http-recorder/src/cassette/store.ts#Service [status=implemented hash=75893509fb7b]
public struct CassetteStoreService: CassetteStoreInterface, Sendable {
    public static let serviceKey = "@opencode/http-recorder/Cassette"

    private let backend: any CassetteStoreInterface

    public init(_ backend: any CassetteStoreInterface) {
        self.backend = backend
    }

    public func read(_ name: String) async throws -> [Interaction] {
        try await backend.read(name)
    }

    public func append(_ name: String, interaction: Interaction, metadata: CassetteMetadata? = nil) async throws {
        try await backend.append(name, interaction: interaction, metadata: metadata)
    }

    public func exists(_ name: String) async -> Bool {
        await backend.exists(name)
    }

    public func list() async throws -> [String] {
        try await backend.list()
    }

    /// Creates a filesystem-backed cassette store using `OpenCodeFileSystem`.
    // parity: http-recorder/src/cassette/store.ts#fileSystem [status=implemented hash=6da4d3347b0f]
    public static func fileSystem(
        directory: String? = nil,
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
        environment: any EnvironmentProviding = SystemEnvironment.shared
    ) -> CassetteStoreService {
        let dir = directory ?? defaultRecordingsDirectory()
        return CassetteStoreService(
            FileSystemCassetteStore(directory: dir, fileSystem: fileSystem, environment: environment)
        )
    }

    /// Creates an in-memory cassette store for deterministic tests and WASI environments.
    // parity: http-recorder/src/cassette/store.ts#memory [status=implemented hash=6d1fb93ee1b7]
    public static func memory(
        _ initial: [String: [Interaction]] = [:],
        environment: any EnvironmentProviding = SystemEnvironment.shared
    ) -> CassetteStoreService {
        CassetteStoreService(MemoryCassetteStore(initial: initial, environment: environment))
    }
}

// MARK: - Path Resolution & Validation

internal func defaultRecordingsDirectory() -> String {
    #if os(WASI)
    return "/test/fixtures/recordings"
    #else
    return resolveNormalizedPath(FileManager.default.currentDirectoryPath, "test/fixtures/recordings")
    #endif
}

private func isWindowsAbsolutePath(_ path: String) -> Bool {
    let bytes = Array(path.utf8)
    if bytes.isEmpty { return false }
    if bytes[0] == UInt8(ascii: "\\") || bytes[0] == UInt8(ascii: "/") {
        return true
    }
    if bytes.count >= 2 {
        let isAlpha = (bytes[0] >= 0x41 && bytes[0] <= 0x5A) || (bytes[0] >= 0x61 && bytes[0] <= 0x7A)
        if isAlpha && bytes[1] == UInt8(ascii: ":") {
            return true
        }
    }
    return false
}

internal func resolveNormalizedPath(_ base: String, _ child: String? = nil) -> String {
    let combined: String
    if let child {
        let normalizedBase = base.replacing("\\", with: "/")
        let normalizedChild = child.replacing("\\", with: "/")
        if normalizedChild.hasPrefix("/") {
            combined = normalizedChild
        } else if normalizedBase.hasSuffix("/") {
            combined = normalizedBase + normalizedChild
        } else {
            combined = normalizedBase + "/" + normalizedChild
        }
    } else {
        combined = base.replacing("\\", with: "/")
    }

    let leadingSlash = combined.hasPrefix("/")
    var stack: [String] = []
    for seg in combined.split(separator: "/") {
        if seg == "." || seg.isEmpty { continue }
        if seg == ".." {
            if !stack.isEmpty { stack.removeLast() }
        } else {
            stack.append(String(seg))
        }
    }
    let joined = stack.joined(separator: "/")
    return leadingSlash ? "/" + joined : (joined.isEmpty ? "." : joined)
}

private func parentDirectoryPath(_ path: String) -> String {
    let norm = resolveNormalizedPath(path)
    guard norm != "/" else { return "/" }
    guard let slash = norm.lastIndex(of: "/") else { return "." }
    if slash == norm.startIndex { return "/" }
    return String(norm[..<slash])
}

internal func cassettePath(directory: String, name: String) throws -> String {
    let segments = name.split { $0 == "/" || $0 == "\\" }
    if name.isEmpty || name.hasPrefix("/") || isWindowsAbsolutePath(name) || segments.contains("..") {
        throw InvalidCassetteNameError(name: name)
    }
    let root = resolveNormalizedPath(directory)
    let target = resolveNormalizedPath(root, "\(name).json")
    let relative = FSPathUtil.posixRelative(from: root, to: target)
    if relative.isEmpty || relative.hasPrefix("..") || relative.hasPrefix("/") {
        throw InvalidCassetteNameError(name: name)
    }
    return target
}

/// Synchronously checks whether a recorded cassette exists on disk.
// parity: http-recorder/src/cassette/store.ts#hasCassetteSync [status=implemented hash=fc02a0063785]
public func hasCassetteSync(_ name: String, directory: String? = nil) throws -> Bool {
    let target = try cassettePath(directory: directory ?? defaultRecordingsDirectory(), name: name)
    #if os(WASI)
    return false
    #else
    return FileManager.default.fileExists(atPath: target)
    #endif
}

/// Synchronously removes a recorded cassette from disk; removing a missing cassette is a no-op.
// parity: http-recorder/src/cassette/store.ts#removeCassetteSync [status=implemented hash=b8cdeb919226]
public func removeCassetteSync(_ name: String, directory: String? = nil) throws {
    let target = try cassettePath(directory: directory ?? defaultRecordingsDirectory(), name: name)
    #if !os(WASI)
    if FileManager.default.fileExists(atPath: target) {
        try FileManager.default.removeItem(atPath: target)
    }
    #endif
}

// MARK: - Portable UTC ISO-8601 Formatting

internal func formatISO8601UTC(epochMs: Int64) -> String {
    let totalSeconds: Int64
    let millis: Int64
    if epochMs >= 0 {
        totalSeconds = epochMs / 1_000
        millis = epochMs % 1_000
    } else {
        let rem = epochMs % 1_000
        if rem == 0 {
            totalSeconds = epochMs / 1_000
            millis = 0
        } else {
            totalSeconds = (epochMs / 1_000) - 1
            millis = rem + 1_000
        }
    }

    var days = totalSeconds / 86_400
    var secsOfDay = totalSeconds % 86_400
    if secsOfDay < 0 {
        secsOfDay += 86_400
        days -= 1
    }

    // Howard Hinnant civil-from-days algorithm (UTC Gregorian calendar).
    let z = days + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let doe = z - era * 146_097
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
    let y = yoe + era * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let day = doy - (153 * mp + 2) / 5 + 1
    let month = mp < 10 ? mp + 3 : mp - 9
    let year = y + (month <= 2 ? 1 : 0)

    let hour = secsOfDay / 3_600
    let minute = (secsOfDay % 3_600) / 60
    let second = secsOfDay % 60

    func pad2(_ n: Int64) -> String {
        n < 10 ? "0\(n)" : "\(n)"
    }
    func pad3(_ n: Int64) -> String {
        if n < 10 { return "00\(n)" }
        if n < 100 { return "0\(n)" }
        return "\(n)"
    }
    func pad4(_ n: Int64) -> String {
        let absVal = abs(n)
        let prefix = n < 0 ? "-" : ""
        if absVal < 10 { return "\(prefix)000\(absVal)" }
        if absVal < 100 { return "\(prefix)00\(absVal)" }
        if absVal < 1_000 { return "\(prefix)0\(absVal)" }
        return "\(prefix)\(absVal)"
    }

    return "\(pad4(year))-\(pad2(month))-\(pad2(day))T\(pad2(hour)):\(pad2(minute)):\(pad2(second)).\(pad3(millis))Z"
}

private func buildCassette(
    name: String,
    interactions: [Interaction],
    metadata: CassetteMetadata?
) -> Cassette {
    var merged = metadata ?? [:]
    merged["name"] = .string(name)
    merged["recordedAt"] = .string(formatISO8601UTC(epochMs: Flock.currentEpochMs()))
    return Cassette(version: 1, metadata: merged, interactions: interactions)
}

// MARK: - Non-Reentrant Async Serial Lock

private actor AsyncSerialLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { continuation in
            if !locked {
                locked = true
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            locked = false
        }
    }
}

// MARK: - Filesystem Store Actor

private actor FileSystemCassetteStore: CassetteStoreInterface {
    private struct RecordedEntry {
        var interactions: [Interaction]
        var findings: [SecretFinding]
    }

    private let directory: String
    private let fileSystem: any OpenCodeFileSystem
    private let environment: any EnvironmentProviding
    private let appendLock = AsyncSerialLock()
    private var recorded: [String: RecordedEntry] = [:]

    init(
        directory: String,
        fileSystem: any OpenCodeFileSystem,
        environment: any EnvironmentProviding
    ) {
        self.directory = resolveNormalizedPath(directory)
        self.fileSystem = fileSystem
        self.environment = environment
    }

    func read(_ name: String) async throws -> [Interaction] {
        let target = try cassettePath(directory: directory, name: name)
        let bytes: [UInt8]
        do {
            bytes = try await fileSystem.readFile(at: target)
        } catch let error as PlatformError {
            if case .notFound = error {
                throw CassetteNotFoundError(cassetteName: name)
            }
            throw InvalidCassetteError(cassetteName: name, description: error.description)
        } catch {
            throw InvalidCassetteError(cassetteName: name, description: String(describing: error))
        }

        do {
            let cassette = try decodeCassette(fromBytes: bytes)
            return cassette.interactions
        } catch {
            throw InvalidCassetteError(cassetteName: name, description: String(describing: error))
        }
    }

    func append(_ name: String, interaction: Interaction, metadata: CassetteMetadata?) async throws {
        let target = try cassettePath(directory: directory, name: name)
        await appendLock.acquire()
        do {
            let entry = recorded[name] ?? RecordedEntry(interactions: [], findings: [])
            let interactions = entry.interactions + [interaction]
            let interactionFindings = entry.findings + secretFindings(interaction, environment: environment)
            let cassette = buildCassette(name: name, interactions: interactions, metadata: metadata)
            let allFindings = interactionFindings + secretFindings(cassette.metadata ?? [:], environment: environment)
            if !allFindings.isEmpty {
                throw UnsafeCassetteError(cassetteName: name, findings: allFindings)
            }

            let parent = parentDirectoryPath(target)
            try await fileSystem.makeDirectory(at: parent, recursive: true)
            let temporary = "\(target).\(uuid()).tmp"
            let payload = Array(formatCassetteJSON(cassette).utf8)
            do {
                try await fileSystem.writeFile(payload, to: temporary, createDirectories: true)
                try await fileSystem.rename(from: temporary, to: target)
            } catch {
                try? await fileSystem.remove(at: temporary)
                throw error
            }
            recorded[name] = RecordedEntry(interactions: interactions, findings: interactionFindings)
            await appendLock.release()
        } catch {
            await appendLock.release()
            throw error
        }
    }

    func exists(_ name: String) async -> Bool {
        guard let target = try? cassettePath(directory: directory, name: name) else {
            return false
        }
        return await fileSystem.exists(at: target)
    }

    func list() async throws -> [String] {
        let files = await walkDirectory(directory)
        return files
            .filter { $0.hasSuffix(".json") }
            .map { file -> String in
                let rel = FSPathUtil.posixRelative(from: directory, to: file).replacing("\\", with: "/")
                return String(rel.dropLast(5))
            }
            .sorted(by: jsStringLessThan)
    }

    private func walkDirectory(_ current: String) async -> [String] {
        guard let entries = try? await fileSystem.readDirectory(at: current) else {
            return []
        }
        var results: [String] = []
        for entry in entries {
            let full = resolveNormalizedPath(current, entry)
            guard let stat = try? await fileSystem.stat(at: full) else { continue }
            if stat.type == .directory {
                let nested = await walkDirectory(full)
                results.append(contentsOf: nested)
            } else {
                results.append(full)
            }
        }
        return results
    }
}

// MARK: - In-Memory Store Actor

private actor MemoryCassetteStore: CassetteStoreInterface {
    private var stored: [String: [Interaction]]
    private var accumulatedFindings: [String: [SecretFinding]] = [:]
    private let environment: any EnvironmentProviding

    init(
        initial: [String: [Interaction]],
        environment: any EnvironmentProviding
    ) {
        self.stored = initial
        self.environment = environment
    }

    func read(_ name: String) async throws -> [Interaction] {
        guard let interactions = stored[name] else {
            throw CassetteNotFoundError(cassetteName: name)
        }
        return interactions
    }

    func append(_ name: String, interaction: Interaction, metadata: CassetteMetadata?) async throws {
        let interactions = (stored[name] ?? []) + [interaction]
        let findings = (accumulatedFindings[name] ?? []) + secretFindings(interaction, environment: environment)
        var allFindings = findings
        if let metadata {
            var withName = metadata
            withName["name"] = .string(name)
            allFindings.append(contentsOf: secretFindings(withName, environment: environment))
        }
        if !allFindings.isEmpty {
            throw UnsafeCassetteError(cassetteName: name, findings: allFindings)
        }
        stored[name] = interactions
        accumulatedFindings[name] = findings
    }

    func exists(_ name: String) async -> Bool {
        stored[name] != nil
    }

    func list() async throws -> [String] {
        stored.keys.sorted(by: jsStringLessThan)
    }
}
