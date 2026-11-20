#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(CRT)
import CRT
#endif
import Synchronization
import OpenCodeUtil

/// Cross-platform filesystem and subprocess protocol boundaries.
/// Concrete host implementations live behind `#if os(...)` guards, while pure tests and
/// restricted environments (iOS/WASI) can supply in-memory or remote implementations.

public enum PlatformError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedOnPlatform(PlatformOS, operation: String)
    case notFound(String)
    case alreadyExists(String)
    case permissionDenied(String, code: String? = nil)
    case ioFailure(String, code: String? = nil)

    public var description: String {
        switch self {
        case let .unsupportedOnPlatform(os, operation):
            return "Unsupported operation '\(operation)' on \(os.rawValue)"
        case .notFound(let path):
            return "Not found: \(path)"
        case .alreadyExists(let path):
            return "Already exists: \(path)"
        case let .permissionDenied(path, code):
            return "Permission denied: \(path)\(code.map { " (\($0))" } ?? "")"
        case let .ioFailure(msg, code):
            return "I/O failure: \(msg)\(code.map { " (\($0))" } ?? "")"
        }
    }
}

public enum FileEntryType: String, Equatable, Hashable, Sendable, Codable {
    case file
    case directory
    case symlink
    case other
}

public struct FileStat: Equatable, Hashable, Sendable, Codable {
    public let type: FileEntryType
    public let size: Int64
    public let modifiedAtMs: Int64

    public init(type: FileEntryType, size: Int64 = 0, modifiedAtMs: Int64 = 0) {
        self.type = type
        self.size = size
        self.modifiedAtMs = modifiedAtMs
    }
}

public protocol OpenCodeFileSystem: Sendable {
    func readFile(at path: String) async throws -> [UInt8]
    func writeFile(_ bytes: [UInt8], to path: String, createDirectories: Bool) async throws
    func writeFileExclusive(_ bytes: [UInt8], to path: String) async throws
    func exists(at path: String) async -> Bool
    func stat(at path: String) async throws -> FileStat
    func makeDirectory(at path: String, recursive: Bool) async throws
    func readDirectory(at path: String) async throws -> [String]
    func remove(at path: String) async throws
    func rename(from source: String, to destination: String) async throws
    func realPath(at path: String) async throws -> String
    func setModificationTime(at path: String, epochMs: Int64) async throws
    func chmod(at path: String, mode: UInt16) async throws
}

public extension OpenCodeFileSystem {
    func writeFileExclusive(_ bytes: [UInt8], to path: String) async throws {
        if await exists(at: path) {
            throw PlatformError.alreadyExists(path)
        }
        try await writeFile(bytes, to: path, createDirectories: false)
    }

    func stat(at path: String) async throws -> FileStat {
        guard await exists(at: path) else {
            throw PlatformError.notFound(path)
        }
        let data = try await readFile(at: path)
        return FileStat(type: .file, size: Int64(data.count), modifiedAtMs: 0)
    }

    func makeDirectory(at path: String, recursive: Bool) async throws {
        _ = (path, recursive)
    }

    func readDirectory(at path: String) async throws -> [String] {
        throw PlatformError.notFound(path)
    }

    func rename(from source: String, to destination: String) async throws {
        let bytes = try await readFile(at: source)
        try await writeFile(bytes, to: destination, createDirectories: true)
        try await remove(at: source)
    }

    func realPath(at path: String) async throws -> String {
        path
    }

    func setModificationTime(at path: String, epochMs: Int64) async throws {
        _ = (path, epochMs)
    }

    func chmod(at path: String, mode: UInt16) async throws {
        _ = (path, mode)
    }
}

/// Deterministic, thread-safe in-memory `OpenCodeFileSystem` that works identically on every Swift platform
/// (macOS, iOS, Linux, Windows, Android, FreeBSD, WASI).
public final class InMemoryFileSystem: OpenCodeFileSystem, Sendable {
    private struct Node: Sendable {
        var type: FileEntryType
        var bytes: [UInt8]
        var modifiedAtMs: Int64
        var mode: UInt16
    }

    private struct State: Sendable {
        var nodes: [String: Node] = ["/": Node(type: .directory, bytes: [], modifiedAtMs: 0, mode: 0o755)]
        var clockMs: Int64 = 1_700_000_000_000
    }

    private let state = Mutex(State())

    public init(initialFiles: [String: [UInt8]] = [:], initialClockMs: Int64? = nil) {
        state.withLock { s in
            if let initialClockMs { s.clockMs = initialClockMs }
            let now = s.clockMs
            for (rawPath, data) in initialFiles {
                let norm = Self.normalize(rawPath)
                Self.ensureParentsLocked(norm, in: &s, now: now)
                s.nodes[norm] = Node(type: .file, bytes: data, modifiedAtMs: now, mode: 0o644)
            }
        }
    }

    public func setClockMs(_ ms: Int64) {
        state.withLock { $0.clockMs = ms }
    }

    public func currentClockMs() -> Int64 {
        state.withLock { $0.clockMs }
    }

    public func readFile(at path: String) async throws -> [UInt8] {
        let norm = Self.normalize(path)
        return try state.withLock { s in
            guard let node = s.nodes[norm] else { throw PlatformError.notFound(norm) }
            guard node.type == .file else { throw PlatformError.ioFailure("Path is a directory: \(norm)") }
            return node.bytes
        }
    }

    public func writeFile(_ bytes: [UInt8], to path: String, createDirectories: Bool) async throws {
        let norm = Self.normalize(path)
        try state.withLock { s in
            let parent = Self.dirname(norm)
            if createDirectories {
                Self.ensureParentsLocked(norm, in: &s, now: s.clockMs)
            } else if s.nodes[parent]?.type != .directory {
                throw PlatformError.notFound(parent)
            }
            s.nodes[norm] = Node(type: .file, bytes: bytes, modifiedAtMs: s.clockMs, mode: 0o644)
        }
    }

    public func writeFileExclusive(_ bytes: [UInt8], to path: String) async throws {
        let norm = Self.normalize(path)
        try state.withLock { s in
            if s.nodes[norm] != nil {
                throw PlatformError.alreadyExists(norm)
            }
            let parent = Self.dirname(norm)
            guard s.nodes[parent]?.type == .directory else {
                throw PlatformError.notFound(parent)
            }
            s.nodes[norm] = Node(type: .file, bytes: bytes, modifiedAtMs: s.clockMs, mode: 0o644)
        }
    }

    public func exists(at path: String) async -> Bool {
        let norm = Self.normalize(path)
        return state.withLock { $0.nodes[norm] != nil }
    }

    public func stat(at path: String) async throws -> FileStat {
        let norm = Self.normalize(path)
        return try state.withLock { s in
            guard let node = s.nodes[norm] else { throw PlatformError.notFound(norm) }
            return FileStat(type: node.type, size: Int64(node.bytes.count), modifiedAtMs: node.modifiedAtMs)
        }
    }

    public func makeDirectory(at path: String, recursive: Bool) async throws {
        let norm = Self.normalize(path)
        try state.withLock { s in
            if let existing = s.nodes[norm] {
                if recursive && existing.type == .directory { return }
                throw PlatformError.alreadyExists(norm)
            }
            let parent = Self.dirname(norm)
            if recursive {
                Self.ensureParentsLocked(norm, in: &s, now: s.clockMs)
            } else if s.nodes[parent]?.type != .directory {
                throw PlatformError.notFound(parent)
            }
            s.nodes[norm] = Node(type: .directory, bytes: [], modifiedAtMs: s.clockMs, mode: 0o755)
        }
    }

    public func readDirectory(at path: String) async throws -> [String] {
        let norm = Self.normalize(path)
        return try state.withLock { s in
            guard s.nodes[norm]?.type == .directory else {
                throw PlatformError.notFound(norm)
            }
            let prefix = norm == "/" ? "/" : norm + "/"
            var entries: Set<String> = []
            for key in s.nodes.keys where key != norm && key.hasPrefix(prefix) {
                let rest = key.dropFirst(prefix.count)
                if let slash = rest.firstIndex(of: "/") {
                    entries.insert(String(rest[..<slash]))
                } else if !rest.isEmpty {
                    entries.insert(String(rest))
                }
            }
            return entries.sorted()
        }
    }

    public func remove(at path: String) async throws {
        let norm = Self.normalize(path)
        state.withLock { s in
            let prefix = norm == "/" ? "/" : norm + "/"
            s.nodes = s.nodes.filter { key, _ in
                key != norm && !key.hasPrefix(prefix)
            }
        }
    }

    public func rename(from source: String, to destination: String) async throws {
        let src = Self.normalize(source)
        let dst = Self.normalize(destination)
        try state.withLock { s in
            guard s.nodes[src] != nil else { throw PlatformError.notFound(src) }
            Self.ensureParentsLocked(dst, in: &s, now: s.clockMs)
            let prefix = src == "/" ? "/" : src + "/"
            var moved: [(String, Node)] = []
            for (key, node) in s.nodes {
                if key == src {
                    moved.append((dst, node))
                } else if key.hasPrefix(prefix) {
                    moved.append((dst + "/" + key.dropFirst(prefix.count), node))
                }
            }
            for (key, _) in s.nodes where key == src || key.hasPrefix(prefix) {
                s.nodes.removeValue(forKey: key)
            }
            for (newKey, node) in moved {
                s.nodes[newKey] = node
            }
        }
    }

    public func realPath(at path: String) async throws -> String {
        let norm = Self.normalize(path)
        return try state.withLock { s in
            guard s.nodes[norm] != nil else { throw PlatformError.notFound(norm) }
            return norm
        }
    }

    public func setModificationTime(at path: String, epochMs: Int64) async throws {
        let norm = Self.normalize(path)
        try state.withLock { s in
            guard var node = s.nodes[norm] else { throw PlatformError.notFound(norm) }
            node.modifiedAtMs = epochMs
            s.nodes[norm] = node
        }
    }

    public func chmod(at path: String, mode: UInt16) async throws {
        let norm = Self.normalize(path)
        try state.withLock { s in
            guard var node = s.nodes[norm] else { throw PlatformError.notFound(norm) }
            node.mode = mode
            s.nodes[norm] = node
        }
    }

    internal static func normalize(_ raw: String) -> String {
        let clean = raw.replacing("\\", with: "/")
        var parts: [String] = []
        for seg in clean.split(separator: "/") {
            if seg == "." || seg.isEmpty { continue }
            if seg == ".." {
                if !parts.isEmpty { parts.removeLast() }
            } else {
                parts.append(String(seg))
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    private static func dirname(_ norm: String) -> String {
        guard norm != "/" else { return "/" }
        guard let slash = norm.lastIndex(of: "/") else { return "/" }
        if slash == norm.startIndex { return "/" }
        return String(norm[..<slash])
    }

    private static func ensureParentsLocked(_ norm: String, in state: inout State, now: Int64) {
        let parts = norm.split(separator: "/").dropLast()
        var current = ""
        for part in parts {
            current += "/\(part)"
            if state.nodes[current] == nil {
                state.nodes[current] = Node(type: .directory, bytes: [], modifiedAtMs: now, mode: 0o755)
            }
        }
    }
}

/// Host filesystem implementation backed by `FileManager` and POSIX/CRT atomic creation where available.
public struct LocalFileSystem: OpenCodeFileSystem, Sendable {
    public static let shared = LocalFileSystem()

    public init() {}

    public func readFile(at path: String) async throws -> [UInt8] {
        #if os(WASI)
        throw PlatformError.unsupportedOnPlatform(.wasi, operation: "LocalFileSystem.readFile")
        #else
        let url = URL(fileURLWithPath: path)
        do {
            let data = try Data(contentsOf: url)
            return Array(data)
        } catch {
            throw Self.mapError(error, path: path)
        }
        #endif
    }

    public func writeFile(_ bytes: [UInt8], to path: String, createDirectories: Bool) async throws {
        #if os(WASI)
        throw PlatformError.unsupportedOnPlatform(.wasi, operation: "LocalFileSystem.writeFile")
        #else
        let url = URL(fileURLWithPath: path)
        if createDirectories {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        do {
            try Data(bytes).write(to: url)
        } catch {
            throw Self.mapError(error, path: path)
        }
        #endif
    }

    public func writeFileExclusive(_ bytes: [UInt8], to path: String) async throws {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        if fd < 0 {
            let err = errno
            if err == EEXIST { throw PlatformError.alreadyExists(path) }
            if err == ENOENT { throw PlatformError.notFound(path) }
            if err == EACCES || err == EPERM { throw PlatformError.permissionDenied(path, code: err == EPERM ? "EPERM" : "EACCES") }
            throw PlatformError.ioFailure("open(\(path)) failed with errno \(err)")
        }
        defer { close(fd) }
        var written = 0
        while written < bytes.count {
            let n = bytes.withUnsafeBytes { buf -> Int in
                guard let base = buf.baseAddress else { return 0 }
                return write(fd, base.advanced(by: written), bytes.count - written)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw PlatformError.ioFailure("write(\(path)) failed with errno \(errno)")
            }
            written += n
        }
        #elseif os(WASI)
        throw PlatformError.unsupportedOnPlatform(.wasi, operation: "LocalFileSystem.writeFileExclusive")
        #else
        if FileManager.default.fileExists(atPath: path) {
            throw PlatformError.alreadyExists(path)
        }
        try await writeFile(bytes, to: path, createDirectories: false)
        #endif
    }

    public func exists(at path: String) async -> Bool {
        #if os(WASI)
        return false
        #else
        return FileManager.default.fileExists(atPath: path)
        #endif
    }

    public func stat(at path: String) async throws -> FileStat {
        #if os(WASI)
        throw PlatformError.unsupportedOnPlatform(.wasi, operation: "LocalFileSystem.stat")
        #else
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let fileType = attrs[.type] as? FileAttributeType
            let entryType: FileEntryType
            switch fileType {
            case .typeDirectory: entryType = .directory
            case .typeRegular: entryType = .file
            case .typeSymbolicLink: entryType = .symlink
            default: entryType = .other
            }
            let size: Int64
            if let numeric = attrs[.size] as? any BinaryInteger {
                size = Int64(clamping: numeric)
            } else if let int64 = attrs[.size] as? Int64 {
                size = int64
            } else {
                size = 0
            }
            let modDate = attrs[.modificationDate] as? Date
            let modMs = modDate.map { Int64(($0.timeIntervalSince1970 * 1_000.0).rounded()) } ?? 0
            return FileStat(type: entryType, size: size, modifiedAtMs: modMs)
        } catch {
            throw Self.mapError(error, path: path)
        }
        #endif
    }

    public func makeDirectory(at path: String, recursive: Bool) async throws {
        #if os(WASI)
        throw PlatformError.unsupportedOnPlatform(.wasi, operation: "LocalFileSystem.makeDirectory")
        #elseif canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        if !recursive {
            if mkdir(path, 0o700) != 0 {
                let err = errno
                if err == EEXIST { throw PlatformError.alreadyExists(path) }
                if err == ENOENT { throw PlatformError.notFound(path) }
                if err == EACCES || err == EPERM { throw PlatformError.permissionDenied(path, code: err == EPERM ? "EPERM" : "EACCES") }
                throw PlatformError.ioFailure("mkdir(\(path)) failed with errno \(err)")
            }
            return
        }
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        } catch {
            throw Self.mapError(error, path: path)
        }
        #else
        do {
            if !recursive && FileManager.default.fileExists(atPath: path) {
                throw PlatformError.alreadyExists(path)
            }
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: recursive)
        } catch let e as PlatformError {
            throw e
        } catch {
            throw Self.mapError(error, path: path)
        }
        #endif
    }

    public func readDirectory(at path: String) async throws -> [String] {
        #if os(WASI)
        throw PlatformError.unsupportedOnPlatform(.wasi, operation: "LocalFileSystem.readDirectory")
        #else
        do {
            return try FileManager.default.contentsOfDirectory(atPath: path)
        } catch {
            throw Self.mapError(error, path: path)
        }
        #endif
    }

    public func remove(at path: String) async throws {
        #if os(WASI)
        throw PlatformError.unsupportedOnPlatform(.wasi, operation: "LocalFileSystem.remove")
        #else
        guard FileManager.default.fileExists(atPath: path) else { return }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            throw Self.mapError(error, path: path)
        }
        #endif
    }

    public func rename(from source: String, to destination: String) async throws {
        #if os(WASI)
        throw PlatformError.unsupportedOnPlatform(.wasi, operation: "LocalFileSystem.rename")
        #else
        do {
            if FileManager.default.fileExists(atPath: destination) {
                try FileManager.default.removeItem(atPath: destination)
            }
            try FileManager.default.moveItem(atPath: source, toPath: destination)
        } catch {
            throw Self.mapError(error, path: source)
        }
        #endif
    }

    public func realPath(at path: String) async throws -> String {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let err = errno
        if err == ENOENT || err == ENOTDIR { throw PlatformError.notFound(path) }
        if err == EACCES || err == EPERM { throw PlatformError.permissionDenied(path, code: err == EPERM ? "EPERM" : "EACCES") }
        throw PlatformError.ioFailure("realpath(\(path)) failed with errno \(err)")
        #elseif os(WASI)
        throw PlatformError.unsupportedOnPlatform(.wasi, operation: "LocalFileSystem.realPath")
        #else
        return URL(fileURLWithPath: path).standardizedFileURL.path
        #endif
    }

    public func setModificationTime(at path: String, epochMs: Int64) async throws {
        #if os(WASI)
        throw PlatformError.unsupportedOnPlatform(.wasi, operation: "LocalFileSystem.setModificationTime")
        #else
        let date = Date(timeIntervalSince1970: Double(epochMs) / 1_000.0)
        do {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
        } catch {
            throw Self.mapError(error, path: path)
        }
        #endif
    }

    public func chmod(at path: String, mode: UInt16) async throws {
        #if os(WASI)
        throw PlatformError.unsupportedOnPlatform(.wasi, operation: "LocalFileSystem.chmod")
        #else
        do {
            try FileManager.default.setAttributes([.posixPermissions: Int(mode)], ofItemAtPath: path)
        } catch {
            throw Self.mapError(error, path: path)
        }
        #endif
    }

    private static func mapError(_ error: any Error, path: String) -> PlatformError {
        let desc = String(describing: error)
        if desc.contains("No such file") || desc.contains("NSFileReadNoSuchFileError") || desc.contains("ENOENT") {
            return .notFound(path)
        }
        if desc.contains("File exists") || desc.contains("NSFileWriteFileExistsError") || desc.contains("EEXIST") {
            return .alreadyExists(path)
        }
        if desc.contains("Permission denied") || desc.contains("EPERM") || desc.contains("EACCES") {
            return .permissionDenied(path, code: desc.contains("EPERM") ? "EPERM" : "EACCES")
        }
        return .ioFailure(desc)
    }
}

public struct ProcessSpec: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let workingDirectory: String?
    public let environment: [String: String]?
    public let stdin: [UInt8]?

    public init(
        executable: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        stdin: [UInt8]? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.stdin = stdin
    }
}

public struct ProcessOutput: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: [UInt8]
    public let stderr: [UInt8]

    public init(exitCode: Int32, stdout: [UInt8], stderr: [UInt8]) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol ProcessSpawner: Sendable {
    func run(_ spec: ProcessSpec) async throws -> ProcessOutput
}
