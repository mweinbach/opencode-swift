#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

// MARK: - CoreLocation (`location*`, `instance*`, `environment/*`)

public enum CoreLocation {
    // MARK: - core/src/environment/*

    public enum Environment {
        public enum Files {
            // parity: core/src/environment/files.ts#FileType [status=implemented hash=9db06da102d7]
            public enum FileType: String, Equatable, Hashable, Sendable, Codable {
                case file
                case directory
                case symlink
                case other
            }

            // parity: core/src/environment/files.ts#FileInfo [status=implemented hash=5c1a0565574b]
            public struct FileInfo: Equatable, Hashable, Sendable, Codable {
                public let type: FileType
                public let size: Int64
                public let mtimeMs: Int64

                public init(type: FileType, size: Int64, mtimeMs: Int64) {
                    self.type = type
                    self.size = size
                    self.mtimeMs = mtimeMs
                }
            }

            // parity: core/src/environment/files.ts#DirEntry [status=implemented hash=31585bdc393b]
            public struct DirEntry: Equatable, Hashable, Sendable, Codable {
                public let name: String
                public let type: FileType

                public init(name: String, type: FileType) {
                    self.name = name
                    self.type = type
                }
            }

            // parity: core/src/environment/files.ts#NotFound [status=implemented hash=5a48bdb45a5d]
            public struct NotFound: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
                public static let tag = "Environment.NotFound"
                public let path: String

                public init(path: String) {
                    self.path = path
                }

                public var description: String { "Environment path not found: \(path)" }
            }

            // parity: core/src/environment/files.ts#WrongKind [status=implemented hash=014dd9c20746]
            public struct WrongKind: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
                public static let tag = "Environment.WrongKind"
                public let path: String
                public let actual: FileType

                public init(path: String, actual: FileType) {
                    self.path = path
                    self.actual = actual
                }

                public var description: String { "Wrong file kind at \(path): \(actual.rawValue)" }
            }

            // parity: core/src/environment/files.ts#Failed [status=implemented hash=3844cbc6030f]
            public struct Failed: Swift.Error, Sendable, CustomStringConvertible {
                public static let tag = "Environment.Failed"
                public let path: String
                public let causeMessage: String

                public init(path: String, cause: any Error) {
                    self.path = path
                    self.causeMessage = String(describing: cause)
                }

                public init(path: String, message: String) {
                    self.path = path
                    self.causeMessage = message
                }

                public var description: String { "Environment operation failed for \(path): \(causeMessage)" }
            }

            public struct ReadRange: Equatable, Hashable, Sendable {
                public let offset: Int
                public let length: Int

                public init(offset: Int, length: Int) {
                    self.offset = offset
                    self.length = length
                }
            }

            public struct ReadResult: Equatable, Sendable {
                public let info: FileInfo
                public let bytes: [UInt8]

                public init(info: FileInfo, bytes: [UInt8]) {
                    self.info = info
                    self.bytes = bytes
                }
            }

            // parity: core/src/environment/files.ts#FilesImpl [status=implemented hash=6f96e664e47d]
            public protocol FilesImpl: Sendable {
                func read(_ path: String, range: ReadRange?) async throws -> ReadResult
                func write(_ path: String, bytes: [UInt8]) async throws
                func stat(_ path: String) async throws -> FileInfo
                func list(_ path: String) async throws -> [DirEntry]
                func remove(_ path: String) async throws
                func move(from: String, to: String) async throws
                func mkdir(_ path: String) async throws
                func append(_ path: String, bytes: [UInt8]) async throws
            }

            // parity: core/src/environment/files.ts#Files [status=implemented hash=d0b4d6070fb4]
            public protocol Interface: FilesImpl {}

            // parity: core/src/environment/files.ts#typeFollowing [status=implemented hash=ff45f582ada8]
            public static func typeFollowing(_ files: any FilesImpl, path: String) async throws -> FileType {
                let info = try await files.stat(path)
                guard info.type == .symlink else { return info.type }
                do {
                    let result = try await files.read(path, range: ReadRange(offset: 0, length: 0))
                    return result.info.type
                } catch let wrong as WrongKind {
                    return wrong.actual
                }
            }

            // parity: core/src/environment/files.ts#exists [status=implemented hash=f3f584d24dbc]
            public static func exists(_ files: any FilesImpl, path: String) async throws -> Bool {
                do {
                    _ = try await typeFollowing(files, path: path)
                    return true
                } catch is NotFound {
                    return false
                }
            }
        }

        // parity: core/src/environment/driver.ts#Driver [status=implemented hash=14790dcf7cc6]
        public struct Driver: Sendable {
            public let spawner: any ProcessSpawner
            public let overrides: (any Files.FilesImpl)?

            public init(spawner: any ProcessSpawner, overrides: (any Files.FilesImpl)? = nil) {
                self.spawner = spawner
                self.overrides = overrides
            }
        }

        /// Process-backed `FilesImpl` matching `core/src/environment/exec-defaults.ts`.
        public final class ExecFilesImpl: Files.Interface, Sendable {
            private let spawner: any ProcessSpawner

            public init(spawner: any ProcessSpawner) {
                self.spawner = spawner
            }

            private func runScript(_ path: String, script: String, args: [String] = [], stdin: [UInt8]? = nil) async throws -> ProcessOutput {
                let spec = ProcessSpec(
                    executable: "sh",
                    arguments: ["-c", script, "sh", path] + args,
                    environment: ["LC_ALL": "C"],
                    stdin: stdin
                )
                do {
                    return try await spawner.run(spec)
                } catch {
                    throw Files.Failed(path: path, cause: error)
                }
            }

            private static func parseType(_ raw: String) -> Files.FileType {
                switch raw {
                case "regular file", "regular empty file", "f": return .file
                case "directory", "d": return .directory
                case "symbolic link", "l": return .symlink
                default: return .other
                }
            }

            private static func parseInfo(_ bytes: [UInt8], path: String) throws -> Files.FileInfo {
                let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let parts = text.split(separator: "\t").map(String.init)
                guard parts.count >= 3, let size = Int64(parts[1]), let mtimeSec = Int64(parts[2]) else {
                    throw Files.Failed(path: path, message: "Invalid stat output: \(text)")
                }
                return Files.FileInfo(type: parseType(parts[0]), size: size, mtimeMs: mtimeSec * 1_000)
            }

            public func stat(_ path: String) async throws -> Files.FileInfo {
                let script = """
                    metadata=$(stat -c '%F\t%s\t%Y' -- "$1" 2>&1) || {
                      case "$metadata" in *'No such file'*|*'Not a directory'*) exit 44 ;; *) printf '%s' "$metadata" >&2; exit 46 ;; esac
                    }
                    printf '%s\n' "$metadata"
                    """
                let out = try await runScript(path, script: script)
                if out.exitCode == 44 { throw Files.NotFound(path: path) }
                if out.exitCode != 0 { throw Files.Failed(path: path, message: String(decoding: out.stderr, as: UTF8.self)) }
                return try Self.parseInfo(out.stdout, path: path)
            }

            public func read(_ path: String, range: Files.ReadRange?) async throws -> Files.ReadResult {
                let script = """
                    metadata=$(stat -L -c '%F\t%s\t%Y' -- "$1" 2>&1) || {
                      case "$metadata" in *'No such file'*|*'Not a directory'*) exit 44 ;; *) printf '%s' "$metadata" >&2; exit 46 ;; esac
                    }
                    kind=${metadata%%\t*}
                    if [ "$kind" != 'regular file' ] && [ "$kind" != 'regular empty file' ]; then printf '%s' "$kind" >&2; exit 45; fi
                    printf '%s\n' "$metadata"
                    if [ "$2" = range ]; then dd if="$1" iflag=skip_bytes,count_bytes skip="$3" count="$4" status=none; else cat -- "$1"; fi
                    """
                let args = range.map { ["range", String($0.offset), String($0.length)] } ?? ["whole"]
                let out = try await runScript(path, script: script, args: args)
                if out.exitCode == 44 { throw Files.NotFound(path: path) }
                if out.exitCode == 45 {
                    throw Files.WrongKind(path: path, actual: Self.parseType(String(decoding: out.stderr, as: UTF8.self)))
                }
                if out.exitCode != 0 { throw Files.Failed(path: path, message: String(decoding: out.stderr, as: UTF8.self)) }
                guard let nl = out.stdout.firstIndex(of: 0x0A) else {
                    throw Files.Failed(path: path, message: "Missing read metadata header")
                }
                let info = try Self.parseInfo(Array(out.stdout[..<nl]), path: path)
                let body = Array(out.stdout[out.stdout.index(after: nl)...])
                return Files.ReadResult(info: info, bytes: body)
            }

            public func write(_ path: String, bytes: [UInt8]) async throws {
                let out = try await runScript(path, script: "mkdir -p \"$(dirname \"$1\")\" && cat > \"$1\"", stdin: bytes)
                if out.exitCode != 0 { throw Files.Failed(path: path, message: String(decoding: out.stderr, as: UTF8.self)) }
            }

            public func list(_ path: String) async throws -> [Files.DirEntry] {
                let script = """
                    metadata=$(stat -L -c '%F\t%s\t%Y' -- "$1" 2>&1) || {
                      case "$metadata" in *'No such file'*|*'Not a directory'*) exit 44 ;; *) printf '%s' "$metadata" >&2; exit 46 ;; esac
                    }
                    kind=${metadata%%\t*}
                    if [ "$kind" != directory ]; then printf '%s' "$kind" >&2; exit 45; fi
                    find -H "$1" -mindepth 1 -maxdepth 1 -printf '%y\\0%f\\0'
                    """
                let out = try await runScript(path, script: script)
                if out.exitCode == 44 { throw Files.NotFound(path: path) }
                if out.exitCode == 45 {
                    throw Files.WrongKind(path: path, actual: Self.parseType(String(decoding: out.stderr, as: UTF8.self)))
                }
                if out.exitCode != 0 { throw Files.Failed(path: path, message: String(decoding: out.stderr, as: UTF8.self)) }
                let fields = String(decoding: out.stdout, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
                var entries: [Files.DirEntry] = []
                var idx = 0
                while idx + 1 < fields.count {
                    let kind = fields[idx]
                    let name = fields[idx + 1]
                    if !name.isEmpty {
                        entries.append(Files.DirEntry(name: name, type: Self.parseType(kind)))
                    }
                    idx += 2
                }
                return entries
            }

            public func remove(_ path: String) async throws {
                let out = try await runScript(path, script: "rm -rf -- \"$1\"")
                if out.exitCode != 0 { throw Files.Failed(path: path, message: String(decoding: out.stderr, as: UTF8.self)) }
            }

            public func move(from: String, to: String) async throws {
                let out = try await runScript(from, script: "mv -- \"$1\" \"$2\"", args: [to])
                if out.exitCode != 0 { throw Files.Failed(path: from, message: String(decoding: out.stderr, as: UTF8.self)) }
            }

            public func mkdir(_ path: String) async throws {
                let out = try await runScript(path, script: "mkdir -p -- \"$1\"")
                if out.exitCode != 0 { throw Files.Failed(path: path, message: String(decoding: out.stderr, as: UTF8.self)) }
            }

            public func append(_ path: String, bytes: [UInt8]) async throws {
                let out = try await runScript(path, script: "cat >> \"$1\"", stdin: bytes)
                if out.exitCode != 0 { throw Files.Failed(path: path, message: String(decoding: out.stderr, as: UTF8.self)) }
            }
        }

        // parity: core/src/environment/exec-defaults.ts#execDefaults [status=implemented hash=a358f6804ea4]
        public static func execDefaults(_ spawner: any ProcessSpawner) -> any Files.Interface {
            ExecFilesImpl(spawner: spawner)
        }

        // parity: core/src/environment/exec-defaults.ts#makeFiles [status=implemented hash=02de2968e8e4]
        public static func makeFiles(_ driver: Driver) -> any Files.Interface {
            if let overrides = driver.overrides as? any Files.Interface {
                return overrides
            }
            if let overrides = driver.overrides {
                return WrappedFiles(overrides)
            }
            return execDefaults(driver.spawner)
        }

        private struct WrappedFiles: Files.Interface, Sendable {
            let impl: any Files.FilesImpl
            init(_ impl: any Files.FilesImpl) { self.impl = impl }
            func read(_ path: String, range: Files.ReadRange?) async throws -> Files.ReadResult { try await impl.read(path, range: range) }
            func write(_ path: String, bytes: [UInt8]) async throws { try await impl.write(path, bytes: bytes) }
            func stat(_ path: String) async throws -> Files.FileInfo { try await impl.stat(path) }
            func list(_ path: String) async throws -> [Files.DirEntry] { try await impl.list(path) }
            func remove(_ path: String) async throws { try await impl.remove(path) }
            func move(from: String, to: String) async throws { try await impl.move(from: from, to: to) }
            func mkdir(_ path: String) async throws { try await impl.mkdir(path) }
            func append(_ path: String, bytes: [UInt8]) async throws { try await impl.append(path, bytes: bytes) }
        }

        /// Host filesystem `Files.Interface` backed by `OpenCodeFileSystem`.
        public final class LocalFilesImpl: Files.Interface, Sendable {
            private let fs: any OpenCodeFileSystem

            public init(fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared) {
                self.fs = fileSystem
            }

            private static func mapType(_ t: FileEntryType) -> Files.FileType {
                switch t {
                case .file: return .file
                case .directory: return .directory
                case .symlink: return .symlink
                case .other: return .other
                }
            }

            public func stat(_ path: String) async throws -> Files.FileInfo {
                do {
                    let s = try await fs.stat(at: path)
                    return Files.FileInfo(type: Self.mapType(s.type), size: s.size, mtimeMs: s.modifiedAtMs)
                } catch let err as PlatformError {
                    if case .notFound = err { throw Files.NotFound(path: path) }
                    throw Files.Failed(path: path, cause: err)
                } catch {
                    throw Files.Failed(path: path, cause: error)
                }
            }

            public func read(_ path: String, range: Files.ReadRange?) async throws -> Files.ReadResult {
                let info = try await stat(path)
                guard info.type == .file else { throw Files.WrongKind(path: path, actual: info.type) }
                do {
                    let bytes = try await fs.readFile(at: path)
                    if let range {
                        let start = min(max(0, range.offset), bytes.count)
                        let end = min(bytes.count, start + max(0, range.length))
                        return Files.ReadResult(info: info, bytes: Array(bytes[start..<end]))
                    }
                    return Files.ReadResult(info: info, bytes: bytes)
                } catch let err as PlatformError {
                    if case .notFound = err { throw Files.NotFound(path: path) }
                    throw Files.Failed(path: path, cause: err)
                }
            }

            public func write(_ path: String, bytes: [UInt8]) async throws {
                do {
                    try await fs.writeFile(bytes, to: path, createDirectories: true)
                } catch {
                    throw Files.Failed(path: path, cause: error)
                }
            }

            public func list(_ path: String) async throws -> [Files.DirEntry] {
                let info = try await stat(path)
                guard info.type == .directory else { throw Files.WrongKind(path: path, actual: info.type) }
                do {
                    let names = try await fs.readDirectory(at: path)
                    var out: [Files.DirEntry] = []
                    for name in names {
                        let full = path == "/" ? "/\(name)" : "\(path)/\(name)"
                        let entryType = (try? await fs.stat(at: full)).map { Self.mapType($0.type) } ?? .other
                        out.append(Files.DirEntry(name: name, type: entryType))
                    }
                    return out.sorted { $0.name < $1.name }
                } catch {
                    throw Files.Failed(path: path, cause: error)
                }
            }

            public func remove(_ path: String) async throws {
                do {
                    try await fs.remove(at: path)
                } catch {
                    throw Files.Failed(path: path, cause: error)
                }
            }

            public func move(from: String, to: String) async throws {
                _ = try await stat(from)
                let destination: String
                if let destInfo = try? await stat(to), destInfo.type == .directory {
                    let base = CoreInstruction.Discovery.lastPathComponent(from)
                    destination = to == "/" ? "/\(base)" : "\(to)/\(base)"
                } else {
                    destination = to
                }
                do {
                    try await fs.rename(from: from, to: destination)
                } catch {
                    throw Files.Failed(path: from, cause: error)
                }
            }

            public func mkdir(_ path: String) async throws {
                do {
                    try await fs.makeDirectory(at: path, recursive: true)
                } catch {
                    throw Files.Failed(path: path, cause: error)
                }
            }

            public func append(_ path: String, bytes: [UInt8]) async throws {
                var existing: [UInt8] = []
                if await fs.exists(at: path) {
                    existing = (try? await fs.readFile(at: path)) ?? []
                }
                existing.append(contentsOf: bytes)
                try await write(path, bytes: existing)
            }
        }

        // parity: core/src/environment/local.ts#makeLocalDriver [status=implemented hash=a19cb8dbb165]
        public static func makeLocalDriver(
            spawner: any ProcessSpawner = CrossSpawnSpawner.HostProcessSpawner.shared,
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared
        ) -> Driver {
            Driver(spawner: spawner, overrides: LocalFilesImpl(fileSystem: fileSystem))
        }

        // parity: core/src/environment/unavailable.ts#spawner [status=implemented hash=d27b55a791c0]
        public struct UnavailableSpawner: ProcessSpawner, Sendable {
            public init() {}
            public func run(_ spec: ProcessSpec) async throws -> ProcessOutput {
                _ = spec
                throw PlatformError.ioFailure(
                    "This location has no execution plane: no workspace is attached and the host cannot spawn processes"
                )
            }
        }

        public static let unavailableSpawner: any ProcessSpawner = UnavailableSpawner()

        // parity: core/src/environment/unavailable.ts#layer [status=implemented hash=a5a285f3c6ec]
        public static let unavailableLayer: LayerNode.ExecutableLayer = LayerNode.ExecutableLayer.succeed(
            key: CrossSpawnSpawner.spawnerKey,
            value: unavailableSpawner
        )

        /// Pure in-memory environment driver supporting files, directories, symlinks, and cycle detection.
        // parity: core/src/environment/memory.ts#MemoryDriver [status=implemented hash=996b9c281739]
        public final class MemoryDriver: Files.Interface, Sendable {
            private enum Node: Sendable {
                case file(bytes: [UInt8], mtimeMs: Int64)
                case directory(mtimeMs: Int64)
                case symlink(target: String, mtimeMs: Int64)

                var fileInfo: Files.FileInfo {
                    switch self {
                    case .file(let bytes, let mtime): return Files.FileInfo(type: .file, size: Int64(bytes.count), mtimeMs: mtime)
                    case .directory(let mtime): return Files.FileInfo(type: .directory, size: 0, mtimeMs: mtime)
                    case .symlink(let target, let mtime): return Files.FileInfo(type: .symlink, size: Int64(target.utf8.count), mtimeMs: mtime)
                    }
                }
            }

            public let driver: Driver
            private let nodes = Mutex<[String: Node]>(["/": .directory(mtimeMs: Flock.currentEpochMs())])

            public init() {
                self.driver = Driver(spawner: UnavailableSpawner(), overrides: nil)
            }

            public var asDriver: Driver {
                Driver(spawner: UnavailableSpawner(), overrides: self)
            }

            private static func normalize(_ raw: String) -> String {
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
                return slash == norm.startIndex ? "/" : String(norm[..<slash])
            }

            private static func basename(_ norm: String) -> String {
                guard norm != "/" else { return "/" }
                return norm.split(separator: "/").last.map(String.init) ?? norm
            }

            private static func resolveKey(
                _ raw: String,
                followFinal: Bool,
                in map: [String: Node],
                seen: inout Set<String>
            ) -> String? {
                let norm = normalize(raw)
                let parts = norm.split(separator: "/").map(String.init)
                var current = "/"
                for (index, part) in parts.enumerated() {
                    let candidate = current == "/" ? "/\(part)" : "\(current)/\(part)"
                    let isLast = index == parts.count - 1
                    if case .symlink(let target, _) = map[candidate], (followFinal || !isLast) {
                        if seen.contains(candidate) { return nil }
                        seen.insert(candidate)
                        let base = target.hasPrefix("/") ? target : "\(dirname(candidate))/\(target)"
                        let rest = parts.dropFirst(index + 1).joined(separator: "/")
                        let combined = rest.isEmpty ? base : "\(base)/\(rest)"
                        return resolveKey(combined, followFinal: followFinal, in: map, seen: &seen)
                    }
                    current = candidate
                }
                return current
            }

            private static func ensureDirLocked(_ raw: String, in map: inout [String: Node]) throws {
                let norm = normalize(raw)
                if case .directory = map[norm] { return }
                if map[norm] != nil {
                    throw Files.Failed(path: raw, message: "Path is not a directory: \(raw)")
                }
                let parent = dirname(norm)
                if parent != norm {
                    try ensureDirLocked(parent, in: &map)
                }
                map[norm] = .directory(mtimeMs: Flock.currentEpochMs())
            }

            public func symlink(target: String, at path: String) async throws {
                try nodes.withLock { map in
                    let norm = Self.normalize(path)
                    let parent = Self.dirname(norm)
                    var seen: Set<String> = []
                    let resolvedParent = Self.resolveKey(parent, followFinal: true, in: map, seen: &seen) ?? parent
                    guard case .directory = map[resolvedParent] else {
                        throw Files.Failed(path: path, message: "Parent directory does not exist: \(parent)")
                    }
                    var seen2: Set<String> = []
                    let dest = Self.resolveKey(norm, followFinal: false, in: map, seen: &seen2) ?? norm
                    map[dest] = .symlink(target: target, mtimeMs: Flock.currentEpochMs())
                }
            }

            public func stat(_ path: String) async throws -> Files.FileInfo {
                try nodes.withLock { map in
                    var seen: Set<String> = []
                    let k = Self.resolveKey(path, followFinal: false, in: map, seen: &seen) ?? Self.normalize(path)
                    guard let node = map[k] else { throw Files.NotFound(path: path) }
                    return node.fileInfo
                }
            }

            public func read(_ path: String, range: Files.ReadRange?) async throws -> Files.ReadResult {
                try nodes.withLock { map in
                    var seen1: Set<String> = []
                    let origKey = Self.resolveKey(path, followFinal: false, in: map, seen: &seen1) ?? Self.normalize(path)
                    guard let orig = map[origKey] else { throw Files.NotFound(path: path) }
                    if case .directory = orig { throw Files.WrongKind(path: path, actual: .directory) }
                    var seen2: Set<String> = []
                    guard let resolved = Self.resolveKey(path, followFinal: true, in: map, seen: &seen2),
                          let node = map[resolved]
                    else {
                        throw Files.NotFound(path: path)
                    }
                    guard case .file(let bytes, _) = node else {
                        throw Files.WrongKind(path: path, actual: node.fileInfo.type)
                    }
                    if let range {
                        let start = min(max(0, range.offset), bytes.count)
                        let end = min(bytes.count, start + max(0, range.length))
                        return Files.ReadResult(info: node.fileInfo, bytes: Array(bytes[start..<end]))
                    }
                    return Files.ReadResult(info: node.fileInfo, bytes: bytes)
                }
            }

            public func write(_ path: String, bytes: [UInt8]) async throws {
                try nodes.withLock { map in
                    let norm = Self.normalize(path)
                    try Self.ensureDirLocked(Self.dirname(norm), in: &map)
                    var seen1: Set<String> = []
                    let origKey = Self.resolveKey(norm, followFinal: false, in: map, seen: &seen1) ?? norm
                    if case .directory = map[origKey] {
                        throw Files.Failed(path: path, message: "Path is a directory: \(path)")
                    }
                    let target: String
                    if case .symlink = map[origKey] {
                        var seen2: Set<String> = []
                        guard let resolved = Self.resolveKey(norm, followFinal: true, in: map, seen: &seen2) else {
                            throw Files.Failed(path: path, message: "Cannot resolve symlink: \(path)")
                        }
                        target = resolved
                    } else {
                        target = origKey
                    }
                    map[target] = .file(bytes: bytes, mtimeMs: Flock.currentEpochMs())
                }
            }

            public func list(_ path: String) async throws -> [Files.DirEntry] {
                try nodes.withLock { map in
                    var seen: Set<String> = []
                    let target = Self.resolveKey(path, followFinal: true, in: map, seen: &seen) ?? Self.normalize(path)
                    guard let node = map[target] else { throw Files.NotFound(path: path) }
                    guard case .directory = node else { throw Files.WrongKind(path: path, actual: node.fileInfo.type) }
                    var entries: [Files.DirEntry] = []
                    for (entry, child) in map where entry != target && Self.dirname(entry) == target {
                        entries.append(Files.DirEntry(name: Self.basename(entry), type: child.fileInfo.type))
                    }
                    return entries.sorted { $0.name < $1.name }
                }
            }

            public func remove(_ path: String) async throws {
                nodes.withLock { map in
                    var seen: Set<String> = []
                    let target = Self.resolveKey(path, followFinal: false, in: map, seen: &seen) ?? Self.normalize(path)
                    let prefix = target == "/" ? "/" : "\(target)/"
                    map = map.filter { k, _ in k != target && !k.hasPrefix(prefix) }
                }
            }

            public func move(from: String, to: String) async throws {
                try nodes.withLock { map in
                    var seen1: Set<String> = []
                    let source = Self.resolveKey(from, followFinal: false, in: map, seen: &seen1) ?? Self.normalize(from)
                    guard let srcNode = map[source] else { throw Files.NotFound(path: from) }
                    var seen2: Set<String> = []
                    let requested = Self.resolveKey(to, followFinal: false, in: map, seen: &seen2) ?? Self.normalize(to)
                    let destination: String
                    if case .directory = map[requested] {
                        destination = requested == "/" ? "/\(Self.basename(source))" : "\(requested)/\(Self.basename(source))"
                    } else {
                        destination = requested
                    }
                    if case .directory = srcNode, destination.hasPrefix("\(source)/") {
                        throw Files.Failed(path: from, message: "Cannot move a directory into itself: \(from)")
                    }
                    try Self.ensureDirLocked(Self.dirname(destination), in: &map)
                    let prefix = "\(source)/"
                    let moved = map.filter { $0.key == source || $0.key.hasPrefix(prefix) }
                    for (k, _) in moved { map.removeValue(forKey: k) }
                    for (k, v) in moved {
                        let suffix = String(k.dropFirst(source.count))
                        map[destination + suffix] = v
                    }
                }
            }

            public func mkdir(_ path: String) async throws {
                try nodes.withLock { map in
                    try Self.ensureDirLocked(path, in: &map)
                }
            }

            public func append(_ path: String, bytes: [UInt8]) async throws {
                try nodes.withLock { map in
                    var seen: Set<String> = []
                    let target = Self.resolveKey(path, followFinal: true, in: map, seen: &seen) ?? Self.normalize(path)
                    var existing: [UInt8] = []
                    if let cur = map[target] {
                        guard case .file(let oldBytes, _) = cur else {
                            throw Files.Failed(path: path, message: "Path is not a file: \(path)")
                        }
                        existing = oldBytes
                    } else {
                        try Self.ensureDirLocked(Self.dirname(target), in: &map)
                    }
                    existing.append(contentsOf: bytes)
                    map[target] = .file(bytes: existing, mtimeMs: Flock.currentEpochMs())
                }
            }
        }

        // parity: core/src/environment/memory.ts#makeMemoryDriver [status=implemented hash=402f34589438]
        public static func makeMemoryDriver() -> MemoryDriver {
            MemoryDriver()
        }

        /// An environment's name: what a path will later use to say where it lives.
        // parity: core/src/environment/environment.ts#ID [status=implemented hash=134c33d64231]
        public struct ID: RawRepresentable, Hashable, Comparable, Sendable, Codable,
            ExpressibleByStringLiteral, CustomStringConvertible
        {
            public let rawValue: String

            public init(rawValue: String) {
                self.rawValue = rawValue
            }

            public init(stringLiteral value: String) {
                self.rawValue = value
            }

            public init(from decoder: any Decoder) throws {
                self.rawValue = try decoder.singleValueContainer().decode(String.self)
            }

            public func encode(to encoder: any Encoder) throws {
                var container = encoder.singleValueContainer()
                try container.encode(rawValue)
            }

            /// Brands a plain string as an environment ID (`ID.make`).
            public static func make(_ value: String) -> ID {
                ID(rawValue: value)
            }

            public static func < (lhs: ID, rhs: ID) -> Bool {
                lhs.rawValue < rhs.rawValue
            }

            public var description: String { rawValue }
        }

        /// The server's own machine.
        // parity: core/src/environment/environment.ts#localID [status=implemented hash=8b4e2b8c4caf]
        public static let localID: ID = ID.make("local")

        // parity: core/src/environment/environment.ts#Interface [status=implemented hash=28fec2c5f219]
        public protocol Interface: Sendable {
            var id: ID { get }
            var files: any Files.Interface { get }
            var spawner: any ProcessSpawner { get }
        }

        // parity: core/src/environment/environment.ts#Service [status=implemented hash=9274a0bff79e]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/Environment"
            public let id: ID
            public let files: any Files.Interface
            public let spawner: any ProcessSpawner

            public init(id: ID = Environment.localID, driver: Driver) {
                self.id = id
                self.files = Environment.makeFiles(driver)
                self.spawner = driver.spawner
            }

            public init(id: ID = Environment.localID, files: any Files.Interface, spawner: any ProcessSpawner) {
                self.id = id
                self.files = files
                self.spawner = spawner
            }
        }

        // parity: core/src/environment/environment.ts#make [status=implemented hash=7e95b2809bf7]
        public static func make(_ id: ID, _ driver: Driver) -> any Interface {
            Service(id: id, driver: driver)
        }

        /// The server's own machine over `fileSystem` (the host disk by default) and the host spawner: the environment
        /// a Location outside any workspace binds, for services constructed without a layer graph.
        public static func local(
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
            spawner: any ProcessSpawner = CrossSpawnSpawner.HostProcessSpawner.shared
        ) -> any Interface {
            make(localID, makeLocalDriver(spawner: spawner, fileSystem: fileSystem))
        }

        /// Shared host environment used as the default `environment` of targets and inputs built without one.
        public static let host: any Interface = local()

        // parity: core/src/environment/environment.ts#node [status=adapted hash=978b3a2f1450]
        public static let node: LayerNode.Provider = AppNode.makeLocationNode(
            Service.serviceKey,
            LayerNode.ExecutableLayer { deps, _ in
                let spawner = deps.get(CrossSpawnSpawner.spawnerKey, as: (any ProcessSpawner).self)
                    ?? CrossSpawnSpawner.HostProcessSpawner.shared
                let location = deps.get(Location.Service.serviceKey, as: Location.Service.self)
                let driver = makeLocalDriver(spawner: spawner)
                // A workspace-bound Location names its environment after the workspace; otherwise it is this machine.
                let id = location?.info.workspaceID.map { ID.make($0.rawValue) } ?? localID
                return LayerNode.Output([Service.serviceKey: Service(id: id, driver: driver)])
            },
            [CrossSpawnSpawner.node, Location.node]
        )
    }

    // MARK: - core/src/location.ts

    public enum Location {
        // parity: core/src/location.ts#Info [status=implemented hash=af4dc07668a1]
        public typealias Info = LocationSchema.Info

        // parity: core/src/location.ts#Ref [status=implemented hash=af4dc07668a1]
        public typealias Ref = LocationSchema.Ref

        // parity: core/src/location.ts#response [status=implemented hash=af4dc07668a1]
        public static func response<Data: Equatable & Hashable & Sendable & Codable>(
            location: LocationSchema.PublicRef,
            data: Data
        ) -> LocationSchema.ResponseEnvelope<Data> {
            LocationSchema.response(location: location, data: data)
        }

        // parity: core/src/location.ts#Interface [status=implemented hash=d2b2bcff5b1f]
        public protocol Interface: Sendable {
            var info: LocationSchema.Info { get }
            var vcs: CoreProject.Schema.Vcs? { get }
        }

        // parity: core/src/location.ts#Service [status=implemented hash=f57b792aa938]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/Location"
            public let info: LocationSchema.Info
            public let vcs: CoreProject.Schema.Vcs?

            public init(info: LocationSchema.Info, vcs: CoreProject.Schema.Vcs? = nil) {
                self.info = info
                self.vcs = vcs
            }
        }

        // parity: core/src/location.ts#node [status=implemented hash=6bb0d9c0108c]
        public static let node: LayerNode.Node = LayerNode.unbound(
            name: Service.serviceKey,
            tag: AppNode.tags.values["location"]!
        )

        // parity: core/src/location.ts#boundNode [status=implemented hash=16230e6e805a]
        public static func boundNode(_ ref: LocationSchema.Ref) -> LayerNode.Provider {
            AppNode.makeLocationNode(
                Service.serviceKey,
                LayerNode.ExecutableLayer { deps, _ in
                    let projectSvc = deps.get(CoreProject.Project.Service.serviceKey, as: CoreProject.Project.Service.self)
                    let fs = deps.get(LayerNodePlatform.fileSystemKey, as: (any OpenCodeFileSystem).self) ?? LocalFileSystem.shared
                    let isDir = (try? await fs.stat(at: ref.directory.rawValue).type == .directory) ?? false
                    let persist = ref.workspaceID != nil || isDir
                    let resolved: CoreProject.Project.Resolved
                    if let projectSvc {
                        resolved = try await projectSvc.resolve(ref.directory, options: CoreProject.Project.ResolveOptions(persist: persist))
                    } else {
                        resolved = CoreProject.Project.Resolved(
                            id: ProjectID.global,
                            directory: ref.directory,
                            canonical: ref.directory,
                            vcs: nil
                        )
                    }
                    let info = LocationSchema.Info(
                        directory: ref.directory,
                        workspaceID: ref.workspaceID,
                        project: LocationSchema.ProjectRef(
                            id: resolved.id,
                            directory: resolved.directory,
                            canonical: resolved.canonical
                        )
                    )
                    return LayerNode.Output([Service.serviceKey: Service(info: info, vcs: resolved.vcs)])
                },
                [LayerNodePlatform.filesystem, CoreProject.Project.node]
            )
        }
    }

    // MARK: - core/src/location-lifecycle.ts

    public enum Lifecycle {
        // parity: core/src/location-lifecycle.ts#Service [status=implemented hash=f79b68bd7b6f]
        public final class Service: Sendable {
            public static let serviceKey = "@opencode/LocationLifecycle"

            private struct Inner: Sendable {
                var closed = false
                var retainedCount = 0
                var waiters: [CheckedContinuation<Void, Never>] = []
            }

            private let inner = Mutex(Inner())
            private let onShutdown: (@Sendable () async -> Void)?

            public init(onShutdown: (@Sendable () async -> Void)? = nil) {
                self.onShutdown = onShutdown
            }

            public func isClosed() -> Bool {
                inner.withLock { $0.closed }
            }

            public func isRetained() -> Bool {
                inner.withLock { $0.retainedCount > 0 }
            }

            /// Increments the retain count and returns a release closure.
            public func retain() -> @Sendable () -> Void {
                inner.withLock { $0.retainedCount += 1 }
                let released = Mutex(false)
                return { [self] in
                    let shouldDecrement = released.withLock { done -> Bool in
                        if done { return false }
                        done = true
                        return true
                    }
                    if shouldDecrement {
                        self.inner.withLock { $0.retainedCount = max(0, $0.retainedCount - 1) }
                    }
                }
            }

            public func shutdown() async {
                let shouldRun = inner.withLock { s -> Bool in
                    if s.closed { return false }
                    s.closed = true
                    return true
                }
                if shouldRun {
                    if let onShutdown {
                        await onShutdown()
                    }
                    let waiters = inner.withLock { s -> [CheckedContinuation<Void, Never>] in
                        let list = s.waiters
                        s.waiters.removeAll()
                        return list
                    }
                    for w in waiters { w.resume() }
                }
            }

            public func awaitShutdown() async {
                if isClosed() { return }
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    let alreadyClosed = inner.withLock { s -> Bool in
                        if s.closed { return true }
                        s.waiters.append(cont)
                        return false
                    }
                    if alreadyClosed { cont.resume() }
                }
            }
        }

        // parity: core/src/location-lifecycle.ts#node [status=implemented hash=550b84d065d8]
        public static let node: LayerNode.Provider = AppNode.makeLocationNode(
            Service.serviceKey,
            LayerNode.ExecutableLayer { _, _ in
                LayerNode.Output([Service.serviceKey: Service()])
            },
            [Location.node]
        )
    }

    // MARK: - core/src/location-service-map.ts

    public enum ServiceMap {
        /// Normalizes equivalent directory paths before they become resource-cache keys.
        // parity: core/src/location-service-map.ts#canonical [status=implemented hash=851c304cf8c9]
        public static func canonical(
            _ ref: LocationSchema.Ref,
            platform: PlatformOS = Platform.current
        ) -> LocationSchema.Ref {
            let raw = ref.directory.rawValue
            if platform == .windows && !raw.hasPrefix("/") {
                let norm = raw.replacing("/", with: "\\")
                let trimmed = norm.count > 3 && norm.hasSuffix("\\") ? String(norm.dropLast()) : norm
                return LocationSchema.Ref(
                    directory: SchemaPrimitive.AbsolutePath(rawValue: trimmed),
                    workspaceID: ref.workspaceID
                )
            }
            var parts: [String] = []
            for seg in raw.replacing("\\", with: "/").split(separator: "/") {
                if seg == "." || seg.isEmpty { continue }
                if seg == ".." {
                    if !parts.isEmpty { parts.removeLast() }
                } else {
                    parts.append(String(seg))
                }
            }
            let normalized = "/" + parts.joined(separator: "/")
            return LocationSchema.Ref(
                directory: SchemaPrimitive.AbsolutePath(rawValue: normalized),
                workspaceID: ref.workspaceID
            )
        }

        /// Process-global map of cached per-Location service containers with canonical lookup,
        /// invalidation, shutdown propagation, and full reload.
        // parity: core/src/location-service-map.ts#Service [status=implemented hash=8f2246752b53]
        public final class Service: Sendable {
            public static let serviceKey = "@opencode/LocationServiceMap"

            private struct CachedEntry: Sendable {
                let ref: LocationSchema.Ref
                let services: LayerNode.Output
                let scope: LayerNode.ResourceScope
                let lifecycle: Lifecycle.Service
            }

            private let builder: @Sendable (LocationSchema.Ref, LayerNode.ResourceScope) async throws -> LayerNode.Output
            private let entries = Mutex<[LocationSchema.Ref: CachedEntry]>([:])
            private let buildMutex = CoreSubsystems.Effect.KeyedMutex<LocationSchema.Ref>()

            public init(
                builder: @escaping @Sendable (LocationSchema.Ref, LayerNode.ResourceScope) async throws -> LayerNode.Output
            ) {
                self.builder = builder
            }

            // parity: core/src/location-service-map.ts#Service.get [status=implemented hash=bb135092fa1d]
            public func get(_ ref: LocationSchema.Ref) async throws -> LayerNode.Output {
                let key = ServiceMap.canonical(ref)
                if let cached = entries.withLock({ $0[key]?.services }) {
                    return cached
                }
                return try await buildMutex.withLock(key) { [self] in
                    if let cached = self.entries.withLock({ $0[key]?.services }) {
                        return cached
                    }
                    let scope = LayerNode.ResourceScope()
                    do {
                        let output = try await self.builder(key, scope)
                        let lifecycle = output.get(Lifecycle.Service.serviceKey, as: Lifecycle.Service.self) ?? Lifecycle.Service()
                        let entry = CachedEntry(ref: key, services: output, scope: scope, lifecycle: lifecycle)
                        self.entries.withLock { $0[key] = entry }
                        return output
                    } catch {
                        await scope.close()
                        throw error
                    }
                }
            }

            public func cached(_ ref: LocationSchema.Ref) -> LayerNode.Output? {
                entries.withLock { $0[ServiceMap.canonical(ref)]?.services }
            }

            public func has(_ ref: LocationSchema.Ref) -> Bool {
                entries.withLock { $0[ServiceMap.canonical(ref)] != nil }
            }

            public func keys() -> [LocationSchema.Ref] {
                entries.withLock { Array($0.keys) }
            }

            public func invalidate(_ ref: LocationSchema.Ref) async {
                let key = ServiceMap.canonical(ref)
                let removed = entries.withLock { $0.removeValue(forKey: key) }
                if let removed {
                    await removed.lifecycle.shutdown()
                    await removed.scope.close()
                }
            }

            public func closeAll() async {
                let all = entries.withLock { map -> [CachedEntry] in
                    let values = Array(map.values)
                    map.removeAll()
                    return values
                }
                for entry in all {
                    await entry.lifecycle.shutdown()
                    await entry.scope.close()
                }
            }
        }

        // parity: core/src/location-service-map.ts#node [status=implemented hash=d83632d3f70b]
        public static let node: LayerNode.Node = LayerNode.unbound(
            name: Service.serviceKey,
            tag: AppNode.tags.values["global"]!
        )

        // parity: core/src/location-service-map.ts#reload [status=implemented hash=a76169df8c51]
        public static func reload(_ locations: Service) async throws {
            let refs = locations.keys()
            for ref in refs {
                await locations.invalidate(ref)
            }
            var firstError: (any Error)?
            for ref in refs {
                do {
                    _ = try await locations.get(ref)
                } catch {
                    if firstError == nil { firstError = error }
                }
            }
            if let firstError {
                throw firstError
            }
        }
    }

    // MARK: - core/src/location-services.ts

    public enum Services {
        // parity: core/src/location-services.ts#LocationServices [status=implemented hash=08f42d7f8b48]
        public typealias LocationServices = Instance.Services

        // parity: core/src/location-services.ts#buildLocationServiceMap [status=implemented hash=c274f81c5663]
        public static func buildLocationServiceMap(
            replacements: [LayerNode.Replacement] = []
        ) -> LayerNode.Provider {
            AppNode.makeGlobalNode(
                ServiceMap.Service.serviceKey,
                LayerNode.ExecutableLayer { _, scope in
                    let memo = LayerNode.MemoMap()
                    let map = ServiceMap.Service { ref, locScope in
                        let compiled = try Instance.layer(ref, options: Instance.Options(replacements: replacements))
                        return try await compiled.build(memoMap: memo, scope: locScope)
                    }
                    scope.addFinalizer {
                        await map.closeAll()
                    }
                    return LayerNode.Output([ServiceMap.Service.serviceKey: map])
                },
                []
            )
        }
    }

    // MARK: - core/src/location-activity.ts

    public enum Activity {
        // parity: core/src/location-activity.ts#Service [status=implemented hash=84a48615aff0]
        public final class Service: Sendable {
            public static let serviceKey = "@opencode/LocationActivity"

            private struct Entry: Sendable {
                let ref: LocationSchema.Ref
                var touchedAtMs: Int64
            }

            private let entries = Mutex<[LocationSchema.Ref: Entry]>([:])
            private let timeToLiveMs: Int64
            private let clock: @Sendable () -> Int64

            public init(
                timeToLiveMs: Int64 = 60 * 60 * 1_000,
                clock: @escaping @Sendable () -> Int64 = { Flock.currentEpochMs() }
            ) {
                self.timeToLiveMs = timeToLiveMs
                self.clock = clock
            }

            public func touch(_ ref: LocationSchema.Ref) {
                let key = ServiceMap.canonical(ref)
                entries.withLock { $0[key] = Entry(ref: key, touchedAtMs: clock()) }
            }

            public func sweep(
                locations: ServiceMap.Service,
                occupied: Set<LocationSchema.Ref> = []
            ) async -> [LocationSchema.Ref] {
                let now = clock()
                let activeRefs = Set(locations.keys())
                let expired: [LocationSchema.Ref] = entries.withLock { map in
                    for ref in activeRefs where map[ref] == nil {
                        map[ref] = Entry(ref: ref, touchedAtMs: now)
                    }
                    map = map.filter { activeRefs.contains($0.key) }
                    return map.values.compactMap { entry in
                        (entry.touchedAtMs + timeToLiveMs <= now) ? entry.ref : nil
                    }
                }
                var evicted: [LocationSchema.Ref] = []
                for ref in expired {
                    if occupied.contains(ref) {
                        touch(ref)
                        continue
                    }
                    if let services = locations.cached(ref),
                       let lifecycle = services.get(Lifecycle.Service.serviceKey, as: Lifecycle.Service.self),
                       lifecycle.isRetained() {
                        touch(ref)
                        continue
                    }
                    entries.withLock { _ = $0.removeValue(forKey: ref) }
                    await locations.invalidate(ref)
                    evicted.append(ref)
                }
                return evicted
            }
        }

        // parity: core/src/location-activity.ts#layer [status=implemented hash=950e0a0bf464]
        public static func layer(timeToLiveMs: Int64 = 60 * 60 * 1_000) -> LayerNode.ExecutableLayer {
            LayerNode.ExecutableLayer.succeed(key: Service.serviceKey, value: Service(timeToLiveMs: timeToLiveMs))
        }

        // parity: core/src/location-activity.ts#node [status=implemented hash=2d6090f54b16]
        public static let node: LayerNode.Provider = AppNode.makeGlobalNode(
            Service.serviceKey,
            layer(),
            [ServiceMap.node]
        )
    }

    // MARK: - core/src/instance.ts & core/src/instance/service.ts

    public enum Instance {
        // parity: core/src/instance/service.ts#Interface [status=implemented hash=ad6c0efc01ae]
        public protocol Interface: Sendable {
            func provide<T: Sendable>(
                location: LocationSchema.Ref,
                operation: @Sendable (Services) async throws -> T
            ) async throws -> T
            func live(location: LocationSchema.Ref) async -> Bool
        }

        // parity: core/src/instance/service.ts#Service [status=implemented hash=527e6b1b2689]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/Instance"
            private let locations: ServiceMap.Service

            public init(locations: ServiceMap.Service) {
                self.locations = locations
            }

            public func provide<T: Sendable>(
                location: LocationSchema.Ref,
                operation: @Sendable (Services) async throws -> T
            ) async throws -> T {
                let services = try await locations.get(location)
                return try await operation(services)
            }

            public func live(location: LocationSchema.Ref) async -> Bool {
                locations.has(location)
            }
        }

        // parity: core/src/instance/service.ts#node [status=implemented hash=d83632d3f70b]
        public static let node: LayerNode.Node = LayerNode.unbound(
            name: Service.serviceKey,
            tag: AppNode.tags.values["global"]!
        )

        internal static func boundServiceNode(locationMap: LayerNode.Provider) -> LayerNode.Provider {
            AppNode.makeGlobalNode(
                Service.serviceKey,
                LayerNode.ExecutableLayer { deps, _ in
                    guard let map = deps.get(ServiceMap.Service.serviceKey, as: ServiceMap.Service.self) else {
                        throw LayerNode.GraphError("LocationServiceMap not provided")
                    }
                    return LayerNode.Output([Service.serviceKey: Service(locations: map)])
                },
                [locationMap]
            )
        }

        // parity: core/src/instance.ts#graph [status=adapted hash=3c8aa29fee89]
        public static let graph: LayerNode.Graph = LayerNode.group([
            CoreSubsystems.App.node,
            Location.node,
            Lifecycle.node,
            Environment.node,
            CoreAgent.Agent.node,
            CoreSubsystems.Command.node,
            CoreInstruction.Reference.node,
            CoreSkill.node,
            CoreInstruction.BuiltIns.node,
            CoreInstruction.Discovery.node,
            CoreSkill.SkillInstructions.node,
            CoreInstruction.Reference.ReferenceInstructions.node,
            CoreVcs.Vcs.node,
            CoreWorktree.Strategies.node,
        ])

        // parity: core/src/instance.ts#Services [status=implemented hash=8b9849faea07]
        public typealias Services = LayerNode.Output

        // parity: core/src/instance.ts#Error [status=adapted hash=e8b93c81ac35]
        public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
            case directoryNotFound(String)
            case bootFailed(String)

            public var description: String {
                switch self {
                case .directoryNotFound(let d): return "Directory not found: \(d)"
                case .bootFailed(let msg): return "Instance boot failed: \(msg)"
                }
            }
        }

        // parity: core/src/instance.ts#Options [status=implemented hash=2c70bcebdf58]
        public struct Options: Sendable {
            public let discovery: Bool
            public let replacements: [LayerNode.Replacement]

            public init(discovery: Bool = true, replacements: [LayerNode.Replacement] = []) {
                self.discovery = discovery
                self.replacements = replacements
            }
        }

        // parity: core/src/instance.ts#layer [status=implemented hash=b7d7eedc8e34]
        public static func layer(
            _ ref: LocationSchema.Ref,
            options: Options = Options()
        ) throws -> LayerNode.CompiledGraph {
            var reps: [LayerNode.Replacement] = []
            if !options.discovery {
                reps.append(try CoreInstruction.Discovery.node.replace(
                    with: CoreInstruction.Discovery.configured(CoreInstruction.Discovery.Options(project: false, global: false))
                ))
            }
            reps.append(contentsOf: options.replacements)
            reps.append(try Location.node.replace(with: Location.boundNode(ref)))
            return try LayerNode.compile(graph, options: LayerNode.CompileOptions(replacements: reps, shared: AppNode.tags.values["global"]))
        }
    }
}

// MARK: - CoreVcs (`git.ts`, `vcs.ts`, `vcs/patch.ts`)

public enum CoreVcs {
    // MARK: - core/src/vcs/patch.ts

    public enum Patch {
        // parity: core/src/vcs/patch.ts#PATCH_CONTEXT_LINES [status=implemented hash=b74482b6afe8]
        public static let PATCH_CONTEXT_LINES: Int = 2_147_483_647

        // parity: core/src/vcs/patch.ts#MAX_PATCH_BYTES [status=implemented hash=f9bfef8ee271]
        public static let MAX_PATCH_BYTES: Int = 10_000_000

        // parity: core/src/vcs/patch.ts#MAX_TOTAL_PATCH_BYTES [status=implemented hash=4df1f97daade]
        public static let MAX_TOTAL_PATCH_BYTES: Int = 10_000_000

        // parity: core/src/vcs/patch.ts#Patch [status=implemented hash=5fa306a22882]
        public struct Info: Equatable, Hashable, Sendable, Codable {
            public let text: String
            public let truncated: Bool

            public init(text: String, truncated: Bool = false) {
                self.text = text
                self.truncated = truncated
            }
        }

        /// Builds a standard unified diff between `before` and `after` for `file`.
        public static func unifiedDiff(file: String, before: String, after: String) -> String {
            let oldLines = before.isEmpty ? [] : before.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let newLines = after.isEmpty ? [] : after.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var out = [
                "Index: \(file)",
                "===================================================================",
                "--- \(file)",
                "+++ \(file)",
            ]
            if oldLines == newLines {
                return out.joined(separator: "\n") + "\n"
            }
            let oldStart = oldLines.isEmpty ? 0 : 1
            let newStart = newLines.isEmpty ? 0 : 1
            out.append("@@ -\(oldStart),\(oldLines.count) +\(newStart),\(newLines.count) @@")
            for line in oldLines { out.append("-\(line)") }
            for line in newLines { out.append("+\(line)") }
            return out.joined(separator: "\n") + "\n"
        }

        // parity: core/src/vcs/patch.ts#emptyPatch [status=implemented hash=531fd6e54ecf]
        public static func emptyPatch(_ file: String) -> String {
            unifiedDiff(file: file, before: "", after: "")
        }

        // parity: core/src/vcs/patch.ts#addPatch [status=implemented hash=a4548a6c59a2]
        public static func addPatch(file: String, content: String) -> String {
            unifiedDiff(file: file, before: "", after: content)
        }

        // parity: core/src/vcs/patch.ts#deletePatch [status=implemented hash=99509b5e1e3c]
        public static func deletePatch(file: String, content: String) -> String {
            unifiedDiff(file: file, before: content, after: "")
        }

        // parity: core/src/vcs/patch.ts#countPatch [status=implemented hash=b601df1f6155]
        public static func countPatch(_ patch: String) -> (additions: Int, deletions: Int) {
            var additions = 0
            var deletions = 0
            for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasPrefix("+") && !line.hasPrefix("+++") {
                    additions += 1
                } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                    deletions += 1
                }
            }
            return (additions, deletions)
        }

        private static func parseQuotedPath(_ value: String) -> (value: String, endIndex: String.Index)? {
            guard value.first == "\"" else { return nil }
            var out = ""
            var idx = value.index(after: value.startIndex)
            while idx < value.endIndex {
                let ch = value[idx]
                if ch == "\"" {
                    return (out, value.index(after: idx))
                }
                if ch != "\\" {
                    out.append(ch)
                    idx = value.index(after: idx)
                    continue
                }
                idx = value.index(after: idx)
                guard idx < value.endIndex else { break }
                let next = value[idx]
                switch next {
                case "t": out.append("\t")
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "\"", "\\": out.append(next)
                default: out.append(next)
                }
                idx = value.index(after: idx)
            }
            return nil
        }

        private static func parsePathToken(_ value: String) -> String {
            if value.hasPrefix("\"") {
                return parseQuotedPath(value)?.value ?? value
            }
            if let tab = value.firstIndex(of: "\t") {
                return String(value[..<tab])
            }
            return value
        }

        private static func fileFromDiffPath(_ value: String?) -> String? {
            guard let value, !value.isEmpty, value != "/dev/null" else { return nil }
            let file = parsePathToken(value)
            if file.hasPrefix("a/") || file.hasPrefix("b/") {
                return String(file.dropFirst(2))
            }
            return file
        }

        private static func fileFromGitHeader(_ header: String) -> String? {
            if header.hasPrefix("\"") {
                guard let first = parseQuotedPath(header) else { return nil }
                let second = String(header[first.endIndex...]).trimmingCharacters(in: .whitespaces)
                if second.isEmpty { return nil }
                if !second.hasPrefix("\"") { return fileFromDiffPath(second) }
                return fileFromDiffPath(parseQuotedPath(second)?.value)
            }
            guard let range = header.range(of: " b/") else { return nil }
            return fileFromDiffPath(String(header[header.index(after: range.lowerBound)...]))
        }

        // parity: core/src/vcs/patch.ts#fileFromPatchChunk [status=implemented hash=23968ee93238]
        public static func fileFromPatchChunk(_ chunk: String) -> String? {
            var nextPath: String?
            var beforePath: String?
            var gitHeader: String?
            for lineSub in chunk.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(lineSub)
                if nextPath == nil, line.hasPrefix("+++ ") {
                    nextPath = String(line.dropFirst(4))
                } else if beforePath == nil, line.hasPrefix("--- ") {
                    beforePath = String(line.dropFirst(4))
                } else if gitHeader == nil, line.hasPrefix("diff --git ") {
                    gitHeader = String(line.dropFirst("diff --git ".count))
                }
            }
            if let file = fileFromDiffPath(nextPath) ?? fileFromDiffPath(beforePath) {
                return file
            }
            return gitHeader.flatMap(fileFromGitHeader)
        }

        // parity: core/src/vcs/patch.ts#splitGitPatch [status=implemented hash=62a9e6c94041]
        public static func splitGitPatch(_ patch: Info) -> [String] {
            let text = patch.text
            var starts: [String.Index] = []
            var cursor = text.startIndex
            while cursor < text.endIndex {
                if text[cursor...].hasPrefix("diff --git ") {
                    if cursor == text.startIndex || text[text.index(before: cursor)] == "\n" {
                        starts.append(cursor)
                    }
                }
                guard let nl = text[cursor...].firstIndex(of: "\n") else { break }
                cursor = text.index(after: nl)
            }
            guard !starts.isEmpty else { return [] }
            var chunks: [String] = []
            for idx in 0..<starts.count {
                let end = idx + 1 < starts.count ? starts[idx + 1] : text.endIndex
                chunks.append(String(text[starts[idx]..<end]))
            }
            if patch.truncated && !chunks.isEmpty {
                chunks.removeLast()
            }
            return chunks
        }

        // parity: core/src/vcs/patch.ts#chunksByFile [status=implemented hash=9bf080406bfc]
        public static func chunksByFile(
            _ patch: Info,
            fallback: (Int) -> String? = { _ in nil }
        ) -> [String: String] {
            var result: [String: String] = [:]
            for (idx, chunk) in splitGitPatch(patch).enumerated() {
                guard let file = fileFromPatchChunk(chunk) ?? fallback(idx) else { continue }
                result[file, default: ""] += chunk
            }
            return result
        }
    }

    // MARK: - core/src/git.ts

    public enum Git {
        // parity: core/src/git.ts#Repository [status=implemented hash=901f0d32ea9d]
        public struct Repository: Equatable, Hashable, Sendable, Codable {
            public let worktree: SchemaPrimitive.AbsolutePath
            public let gitDirectory: SchemaPrimitive.AbsolutePath
            public let commonDirectory: SchemaPrimitive.AbsolutePath

            public init(
                worktree: SchemaPrimitive.AbsolutePath,
                gitDirectory: SchemaPrimitive.AbsolutePath,
                commonDirectory: SchemaPrimitive.AbsolutePath
            ) {
                self.worktree = worktree
                self.gitDirectory = gitDirectory
                self.commonDirectory = commonDirectory
            }
        }

        // parity: core/src/git.ts#TreeID [status=implemented hash=3873abf10190]
        public struct TreeID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
            public let rawValue: String

            public init(rawValue: String) {
                self.rawValue = rawValue
            }

            public var description: String { rawValue }
        }

        // parity: core/src/git.ts#CaptureInput [status=implemented hash=d84334cbe964]
        public struct CaptureInput: Equatable, Hashable, Sendable {
            public let repository: Repository
            public let scopes: [SchemaPrimitive.RelativePath]
            public let ignores: Repository?
            public let maximumUntrackedFileBytes: Int?

            public init(
                repository: Repository,
                scopes: [SchemaPrimitive.RelativePath],
                ignores: Repository? = nil,
                maximumUntrackedFileBytes: Int? = nil
            ) {
                self.repository = repository
                self.scopes = scopes
                self.ignores = ignores
                self.maximumUntrackedFileBytes = maximumUntrackedFileBytes
            }
        }

        // parity: core/src/git.ts#OperationError [status=implemented hash=ad682a4ed387]
        public struct OperationError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "Git.OperationError"

            public enum Operation: String, Equatable, Hashable, Sendable, Codable {
                case clone, fetch, checkout, reset, create, refresh
                case writeTree = "write_tree"
                case listFiles = "list_files"
                case diff, restore, pack
            }

            public let operation: Operation
            public let message: String
            public let directory: SchemaPrimitive.AbsolutePath?

            public init(operation: Operation, message: String, directory: SchemaPrimitive.AbsolutePath? = nil) {
                self.operation = operation
                self.message = message
                self.directory = directory
            }

            public var description: String { "Git \(operation.rawValue) failed: \(message)" }
        }

        // parity: core/src/git.ts#CommandError [status=implemented hash=07359b7b1abd]
        public struct CommandError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "Git.CommandError"
            public let args: [String]
            public let exitCode: Int32?
            public let detail: String?

            public init(args: [String], exitCode: Int32? = nil, detail: String? = nil) {
                self.args = args
                self.exitCode = exitCode
                self.detail = detail
            }

            public var description: String {
                "git \(args.joined(separator: " ")) failed\(exitCode.map { " (exit \($0))" } ?? "")\(detail.map { ": \($0)" } ?? "")"
            }
        }

        // parity: core/src/git.ts#Worktree [status=implemented hash=cede745bb761]
        public struct Worktree: Equatable, Hashable, Sendable, Codable {
            public enum Kind: String, Equatable, Hashable, Sendable, Codable {
                case main
                case linked
            }

            public let directory: SchemaPrimitive.AbsolutePath
            public let kind: Kind

            public init(directory: SchemaPrimitive.AbsolutePath, kind: Kind) {
                self.directory = directory
                self.kind = kind
            }
        }

        // parity: core/src/git.ts#WorktreeError [status=implemented hash=ba991410ac3e]
        public struct WorktreeError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "Git.WorktreeError"

            public enum Operation: String, Equatable, Hashable, Sendable, Codable {
                case create, remove, list
            }

            public let operation: Operation
            public let message: String
            public let directory: SchemaPrimitive.AbsolutePath?
            public let forceRequired: Bool?

            public init(
                operation: Operation,
                message: String,
                directory: SchemaPrimitive.AbsolutePath? = nil,
                forceRequired: Bool? = nil
            ) {
                self.operation = operation
                self.message = message
                self.directory = directory
                self.forceRequired = forceRequired
            }

            public var description: String { "Git worktree \(operation.rawValue) failed: \(message)" }
        }

        // parity: core/src/git.ts#Interface [status=implemented hash=db35fd6205d1]
        public protocol Interface: Sendable {
            func discover(_ input: SchemaPrimitive.AbsolutePath) async -> Repository?
            func fingerprint(_ dotGit: SchemaPrimitive.AbsolutePath) async -> String?
            func clone(remote: String, directory: SchemaPrimitive.AbsolutePath, branch: String?, depth: Int?) async throws -> Repository
            func create(worktree: SchemaPrimitive.AbsolutePath, gitDirectory: SchemaPrimitive.AbsolutePath) async throws -> Repository
            func remoteGet(_ repository: Repository, name: String) async throws -> String?
            func head(_ repository: Repository) async -> String?
            func branch(_ repository: Repository) async -> String?
            func defaultRemoteBranch(_ repository: Repository, remote: String) async -> String?
            func rootCommits(_ repository: Repository) async throws -> [String]
            func fetchRemotes(_ repository: Repository, prune: Bool) async throws
            func fetchBranch(_ repository: Repository, remote: String, branch: String, force: Bool) async throws
            func checkoutRemoteBranch(_ repository: Repository, remote: String, branch: String, reset: Bool) async throws
            func resetHard(_ repository: Repository, revision: String) async throws
            func worktreeCreate(repository: Repository, directory: SchemaPrimitive.AbsolutePath, ref: String?) async throws -> Repository
            func worktreeRemove(repository: Repository, directory: SchemaPrimitive.AbsolutePath, force: Bool) async throws
            func worktreeList(_ repository: Repository) async throws -> [Worktree]
            func writeTree(_ repository: Repository) async throws -> TreeID
            func diffTree(repository: Repository, from: TreeID, to: TreeID, context: Int?) async throws -> [FileDiffSchema.Info]
        }

        // parity: core/src/git.ts#Service [status=implemented hash=ee7b17ae1b08]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/Git"
            private let spawner: any ProcessSpawner
            private let fileSystem: any OpenCodeFileSystem
            private let executable: String

            public init(
                spawner: any ProcessSpawner = CrossSpawnSpawner.HostProcessSpawner.shared,
                fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
                executable: String = CoreSubsystems.Util.GitExecutable.gitExecutable()
            ) {
                self.spawner = spawner
                self.fileSystem = fileSystem
                self.executable = executable
            }

            private func runGit(_ args: [String], cwd: String? = nil) async throws -> ProcessOutput {
                try await spawner.run(ProcessSpec(
                    executable: executable,
                    arguments: args,
                    workingDirectory: cwd
                ))
            }

            private static let safeConfigArgs: [String] = [
                "--no-optional-locks",
                "-c", "core.autocrlf=false",
                "-c", "core.fsmonitor=false",
                "-c", "core.longpaths=true",
                "-c", "core.symlinks=true",
                "-c", "core.quotepath=false",
            ]

            private func runSafeGit(_ args: [String], cwd: String) async throws -> ProcessOutput {
                try await runGit(Self.safeConfigArgs + args, cwd: cwd)
            }

            private static func parsePorcelainStatus(_ code: String) -> VcsSchema.FileStatus.Status {
                if code == "??" { return .added }
                if code.contains("U") { return .modified }
                if code.contains("A") && !code.contains("D") { return .added }
                if code.contains("D") && !code.contains("A") { return .deleted }
                return .modified
            }

            private static func parseDiffStatus(_ status: VcsSchema.FileStatus.Status) -> FileDiffSchema.Status {
                switch status {
                case .added: return .added
                case .deleted: return .deleted
                case .modified: return .modified
                }
            }

            private static func parseNumstat(_ text: String) -> [String: (additions: Int, deletions: Int)] {
                var result: [String: (additions: Int, deletions: Int)] = [:]
                for raw in text.split(separator: "\0", omittingEmptySubsequences: true) {
                    let parts = raw.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                    guard parts.count == 3 else { continue }
                    let file = String(parts[2])
                    guard !file.isEmpty else { continue }
                    let add = parts[0] == "-" ? 0 : (Int(parts[0]) ?? 0)
                    let del = parts[1] == "-" ? 0 : (Int(parts[1]) ?? 0)
                    result[file] = (add, del)
                }
                return result
            }

            private static func parsePorcelainEntries(_ text: String) -> [(file: String, code: String, status: VcsSchema.FileStatus.Status)] {
                var items: [(file: String, code: String, status: VcsSchema.FileStatus.Status)] = []
                for raw in text.split(separator: "\0", omittingEmptySubsequences: true) {
                    guard raw.count >= 4 else { continue }
                    let idx2 = raw.index(raw.startIndex, offsetBy: 2)
                    let idx3 = raw.index(raw.startIndex, offsetBy: 3)
                    let code = String(raw[..<idx2])
                    let file = String(raw[idx3...])
                    guard !file.isEmpty else { continue }
                    items.append((file: file, code: code, status: parsePorcelainStatus(code)))
                }
                return items
            }

            public func initRepository(at directory: String) async throws {
                let out = try await runGit(["init"], cwd: directory)
                guard out.exitCode == 0 else {
                    throw OperationError(
                        operation: .create,
                        message: String(decoding: out.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                        directory: SchemaPrimitive.AbsolutePath(rawValue: directory)
                    )
                }
            }

            public func hasHead(in directory: String) async -> Bool {
                guard let out = try? await runSafeGit(["rev-parse", "--verify", "HEAD"], cwd: directory) else {
                    return false
                }
                return out.exitCode == 0
            }

            public func currentBranch(in directory: String) async -> String? {
                if let out = try? await runSafeGit(["rev-parse", "--abbrev-ref", "HEAD"], cwd: directory),
                   out.exitCode == 0
                {
                    let name = String(decoding: out.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty && name != "HEAD" {
                        return name
                    }
                }
                if let out = try? await runSafeGit(["symbolic-ref", "--quiet", "--short", "HEAD"], cwd: directory),
                   out.exitCode == 0
                {
                    let name = String(decoding: out.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty {
                        return name
                    }
                }
                return nil
            }

            public func defaultBranch(in directory: String) async -> (name: String, ref: String)? {
                if let remotesOut = try? await runSafeGit(["remote"], cwd: directory), remotesOut.exitCode == 0 {
                    let remotes = String(decoding: remotesOut.stdout, as: UTF8.self)
                        .split(whereSeparator: \.isNewline)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    let primary: String? = if remotes.contains("origin") {
                        "origin"
                    } else if remotes.count == 1 {
                        remotes[0]
                    } else if remotes.contains("upstream") {
                        "upstream"
                    } else {
                        remotes.first
                    }
                    if let primary,
                       let headOut = try? await runSafeGit(["symbolic-ref", "refs/remotes/\(primary)/HEAD"], cwd: directory),
                       headOut.exitCode == 0
                    {
                        var ref = String(decoding: headOut.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        if ref.hasPrefix("refs/remotes/") {
                            ref = String(ref.dropFirst("refs/remotes/".count))
                        }
                        let prefix = "\(primary)/"
                        if ref.hasPrefix(prefix) {
                            let name = String(ref.dropFirst(prefix.count))
                            if !name.isEmpty { return (name, ref) }
                        }
                    }
                }
                if let headsOut = try? await runSafeGit(["for-each-ref", "--format=%(refname:lstrip=2)", "refs/heads"], cwd: directory),
                   headsOut.exitCode == 0
                {
                    let heads = String(decoding: headsOut.stdout, as: UTF8.self)
                        .split(whereSeparator: \.isNewline)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    if let cfgOut = try? await runSafeGit(["config", "init.defaultBranch"], cwd: directory),
                       cfgOut.exitCode == 0
                    {
                        let configured = String(decoding: cfgOut.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !configured.isEmpty && heads.contains(configured) {
                            return (configured, configured)
                        }
                    }
                    if heads.contains("main") { return ("main", "main") }
                    if heads.contains("master") { return ("master", "master") }
                }
                return nil
            }

            public func branches(in directory: String, options: CoreVcs.Vcs.BranchOptions? = nil) async -> VcsSchema.BranchList {
                guard let out = try? await runSafeGit(
                    ["for-each-ref", "--sort=refname", "--sort=-committerdate", "--format=%(refname:lstrip=2)", "refs/heads", "refs/remotes"],
                    cwd: directory
                ), out.exitCode == 0 else {
                    return []
                }
                let needle = options?.search?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                var list = String(decoding: out.stdout, as: UTF8.self)
                    .split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && !$0.hasSuffix("/HEAD") }
                if let needle, !needle.isEmpty {
                    list = list.filter { $0.lowercased().contains(needle) }
                }
                if let limit = options?.limit, limit >= 0, list.count > limit {
                    return Array(list.prefix(limit))
                }
                return list
            }

            public func base(in directory: String) async throws -> VcsSchema.Base? {
                guard await hasHead(in: directory) else { return nil }
                guard let current = await currentBranch(in: directory) else {
                    throw CoreVcs.Vcs.DiffError(message: "Choose a review base")
                }
                guard let root = await defaultBranch(in: directory), current == root.name else {
                    throw CoreVcs.Vcs.DiffError(message: "Choose a review base")
                }
                guard let refOut = try? await runSafeGit(
                    ["rev-parse", "--symbolic-full-name", "--verify", "--end-of-options", root.ref],
                    cwd: directory
                ), refOut.exitCode == 0 else {
                    throw CoreVcs.Vcs.DiffError(message: "The default review base is unavailable")
                }
                let fullRef = String(decoding: refOut.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !fullRef.isEmpty else {
                    throw CoreVcs.Vcs.DiffError(message: "The default review base is unavailable")
                }
                return VcsSchema.Base(name: root.name, ref: fullRef, source: .default)
            }

            private func statUntrackedFile(worktree: String, file: String) async -> (additions: Int, deletions: Int) {
                guard !file.hasSuffix("/") else { return (0, 0) }
                if let out = try? await runSafeGit(["diff", "--no-index", "--numstat", "--", "/dev/null", file], cwd: worktree) {
                    let line = String(decoding: out.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    let parts = line.split(separator: "\t")
                    if parts.count >= 2 {
                        let add = parts[0] == "-" ? 0 : (Int(parts[0]) ?? 0)
                        let del = parts[1] == "-" ? 0 : (Int(parts[1]) ?? 0)
                        return (add, del)
                    }
                }
                let fullPath = worktree.hasSuffix("/") ? "\(worktree)\(file)" : "\(worktree)/\(file)"
                if let bytes = try? await fileSystem.readFile(at: fullPath), !bytes.isEmpty {
                    let text = String(decoding: bytes, as: UTF8.self)
                    let count = text.split(separator: "\n", omittingEmptySubsequences: false).count
                    return (max(1, count), 0)
                }
                return (0, 0)
            }

            public func status(in directory: String, worktree: String? = nil) async -> [VcsSchema.FileStatus] {
                guard let statusOut = try? await runSafeGit(
                    ["status", "--porcelain=v1", "--untracked-files=all", "--no-renames", "-z", "--", "."],
                    cwd: directory
                ), statusOut.exitCode == 0 else {
                    return []
                }
                let entries = Self.parsePorcelainEntries(String(decoding: statusOut.stdout, as: UTF8.self))
                let headExists = await hasHead(in: directory)
                var numstats: [String: (additions: Int, deletions: Int)] = [:]
                if headExists,
                   let statOut = try? await runSafeGit(
                       ["diff", "--no-ext-diff", "--no-renames", "--numstat", "-z", "HEAD", "--", "."],
                       cwd: directory
                   ), statOut.exitCode == 0
                {
                    numstats = Self.parseNumstat(String(decoding: statOut.stdout, as: UTF8.self))
                }
                let wt = worktree ?? directory
                var results: [VcsSchema.FileStatus] = []
                for entry in entries.sorted(by: { $0.file < $1.file }) {
                    let counts: (additions: Int, deletions: Int)
                    if let existing = numstats[entry.file] {
                        counts = existing
                    } else if entry.status == .added {
                        counts = await statUntrackedFile(worktree: wt, file: entry.file)
                    } else {
                        counts = (0, 0)
                    }
                    results.append(VcsSchema.FileStatus(
                        file: entry.file,
                        additions: SchemaPrimitive.NonNegativeInt(rawValue: max(0, counts.additions)) ?? .zero,
                        deletions: SchemaPrimitive.NonNegativeInt(rawValue: max(0, counts.deletions)) ?? .zero,
                        status: entry.status
                    ))
                }
                return results
            }

            private func patchUntrackedFile(worktree: String, file: String, context: Int) async -> String {
                guard !file.hasSuffix("/") else { return Patch.emptyPatch(file) }
                if let out = try? await runSafeGit(
                    ["diff", "--no-color", "--no-index", "--patch", "--no-ext-diff", "--no-renames", "--unified=\(context)", "--", "/dev/null", file],
                    cwd: worktree
                ) {
                    let text = String(decoding: out.stdout, as: UTF8.self)
                    if !text.isEmpty { return text }
                }
                let fullPath = worktree.hasSuffix("/") ? "\(worktree)\(file)" : "\(worktree)/\(file)"
                if let bytes = try? await fileSystem.readFile(at: fullPath) {
                    return Patch.addPatch(file: file, content: String(decoding: bytes, as: UTF8.self))
                }
                return Patch.emptyPatch(file)
            }

            public func diff(
                in directory: String,
                worktree: String? = nil,
                mode: VcsSchema.Mode,
                options: CoreVcs.Vcs.DiffOptions? = nil
            ) async throws -> [FileDiffSchema.Info] {
                let context = options?.context ?? 3
                let wt = worktree ?? directory
                let headExists = await hasHead(in: directory)

                if mode == .working || !headExists {
                    if mode == .committed && !headExists { return [] }
                    let statusOut = try? await runSafeGit(
                        ["status", "--porcelain=v1", "--untracked-files=all", "--no-renames", "-z", "--", "."],
                        cwd: directory
                    )
                    let entries = statusOut.map { Self.parsePorcelainEntries(String(decoding: $0.stdout, as: UTF8.self)) } ?? []
                    var rawPatch = ""
                    if headExists {
                        if let diffOut = try? await runSafeGit(
                            ["diff", "--no-color", "--patch", "--no-ext-diff", "--no-renames", "--unified=\(context)", "HEAD", "--", "."],
                            cwd: directory
                        ), diffOut.exitCode == 0 {
                            rawPatch = String(decoding: diffOut.stdout, as: UTF8.self)
                        }
                    } else {
                        if let diffOut = try? await runSafeGit(
                            ["diff", "--cached", "--no-color", "--patch", "--no-ext-diff", "--no-renames", "--unified=\(context)", "--", "."],
                            cwd: directory
                        ), diffOut.exitCode == 0 {
                            rawPatch = String(decoding: diffOut.stdout, as: UTF8.self)
                        }
                    }
                    let chunks = Patch.chunksByFile(Patch.Info(text: rawPatch, truncated: false))
                    var rowsByFile: [String: FileDiffSchema.Info] = [:]
                    for (file, chunk) in chunks {
                        let counts = Patch.countPatch(chunk)
                        let status: FileDiffSchema.Status = chunk.contains("new file mode")
                            ? .added
                            : chunk.contains("deleted file mode") ? .deleted : .modified
                        rowsByFile[file] = FileDiffSchema.Info(
                            file: file,
                            patch: chunk,
                            additions: SchemaPrimitive.NonNegativeInt(rawValue: counts.additions) ?? .zero,
                            deletions: SchemaPrimitive.NonNegativeInt(rawValue: counts.deletions) ?? .zero,
                            status: status
                        )
                    }
                    for entry in entries where rowsByFile[entry.file] == nil {
                        let patchText = entry.code == "??" || entry.status == .added
                            ? await patchUntrackedFile(worktree: wt, file: entry.file, context: context)
                            : Patch.emptyPatch(entry.file)
                        let counts = Patch.countPatch(patchText)
                        rowsByFile[entry.file] = FileDiffSchema.Info(
                            file: entry.file,
                            patch: patchText,
                            additions: SchemaPrimitive.NonNegativeInt(rawValue: counts.additions) ?? .zero,
                            deletions: SchemaPrimitive.NonNegativeInt(rawValue: counts.deletions) ?? .zero,
                            status: Self.parseDiffStatus(entry.status)
                        )
                    }
                    return rowsByFile.keys.sorted().compactMap { rowsByFile[$0] }
                }

                let baseRef: String?
                if let explicitBase = options?.base {
                    baseRef = explicitBase
                } else {
                    baseRef = (await defaultBranch(in: directory))?.ref
                }
                guard let baseRef else {
                    throw CoreVcs.Vcs.DiffError(message: "No review base available")
                }
                guard let mbOut = try? await runSafeGit(["merge-base", baseRef, "HEAD"], cwd: directory),
                      mbOut.exitCode == 0
                else {
                    throw CoreVcs.Vcs.DiffError(message: "No merge base available for \(baseRef)")
                }
                let mergeBase = String(decoding: mbOut.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !mergeBase.isEmpty else {
                    throw CoreVcs.Vcs.DiffError(message: "No merge base available for \(baseRef)")
                }

                var args = ["diff", "--no-color", "--patch", "--no-ext-diff", "--no-renames", "--unified=\(context)", mergeBase]
                if mode == .committed { args.append("HEAD") }
                args += ["--", "."]
                let diffOut = try await runSafeGit(args, cwd: directory)
                guard diffOut.exitCode == 0 else {
                    throw CoreVcs.Vcs.DiffError(message: "Unable to produce Git diff")
                }
                let chunks = Patch.chunksByFile(Patch.Info(text: String(decoding: diffOut.stdout, as: UTF8.self), truncated: false))
                var rowsByFile: [String: FileDiffSchema.Info] = [:]
                for (file, chunk) in chunks {
                    let counts = Patch.countPatch(chunk)
                    let status: FileDiffSchema.Status = chunk.contains("new file mode")
                        ? .added
                        : chunk.contains("deleted file mode") ? .deleted : .modified
                    rowsByFile[file] = FileDiffSchema.Info(
                        file: file,
                        patch: chunk,
                        additions: SchemaPrimitive.NonNegativeInt(rawValue: counts.additions) ?? .zero,
                        deletions: SchemaPrimitive.NonNegativeInt(rawValue: counts.deletions) ?? .zero,
                        status: status
                    )
                }
                if mode == .branch,
                   let statusOut = try? await runSafeGit(
                       ["status", "--porcelain=v1", "--untracked-files=all", "--no-renames", "-z", "--", "."],
                       cwd: directory
                   ), statusOut.exitCode == 0
                {
                    for entry in Self.parsePorcelainEntries(String(decoding: statusOut.stdout, as: UTF8.self)) where entry.code == "??" && rowsByFile[entry.file] == nil {
                        let patchText = await patchUntrackedFile(worktree: wt, file: entry.file, context: context)
                        let counts = Patch.countPatch(patchText)
                        rowsByFile[entry.file] = FileDiffSchema.Info(
                            file: entry.file,
                            patch: patchText,
                            additions: SchemaPrimitive.NonNegativeInt(rawValue: counts.additions) ?? .zero,
                            deletions: SchemaPrimitive.NonNegativeInt(rawValue: counts.deletions) ?? .zero,
                            status: .added
                        )
                    }
                }
                return rowsByFile.keys.sorted().compactMap { rowsByFile[$0] }
            }

            public func discover(_ input: SchemaPrimitive.AbsolutePath) async -> Repository? {
                guard let out = try? await runGit(
                    ["rev-parse", "--show-toplevel", "--git-dir", "--git-common-dir"],
                    cwd: input.rawValue
                ), out.exitCode == 0 else {
                    return nil
                }
                let lines = String(decoding: out.stdout, as: UTF8.self)
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard lines.count >= 3 else { return nil }
                func resolveDir(_ rel: String, base: String) -> String {
                    rel.hasPrefix("/") ? rel : "\(base)/\(rel)"
                }
                let top = lines[0]
                return Repository(
                    worktree: SchemaPrimitive.AbsolutePath(rawValue: top),
                    gitDirectory: SchemaPrimitive.AbsolutePath(rawValue: resolveDir(lines[1], base: input.rawValue)),
                    commonDirectory: SchemaPrimitive.AbsolutePath(rawValue: resolveDir(lines[2], base: input.rawValue))
                )
            }

            public func fingerprint(_ dotGit: SchemaPrimitive.AbsolutePath) async -> String? {
                guard let stat = try? await fileSystem.stat(at: dotGit.rawValue) else { return nil }
                if stat.type == .file {
                    let text = (try? await fileSystem.readFile(at: dotGit.rawValue)).map { String(decoding: $0, as: UTF8.self) } ?? ""
                    return Hash.fast("file:\(stat.modifiedAtMs):\(text)")
                }
                let headPath = "\(dotGit.rawValue)/HEAD"
                let configPath = "\(dotGit.rawValue)/config"
                let headMtime = (try? await fileSystem.stat(at: headPath).modifiedAtMs) ?? 0
                let configMtime = (try? await fileSystem.stat(at: configPath).modifiedAtMs) ?? 0
                return Hash.fast("dir:\(stat.modifiedAtMs):\(headMtime):\(configMtime)")
            }

            public func clone(
                remote: String,
                directory: SchemaPrimitive.AbsolutePath,
                branch: String? = nil,
                depth: Int? = nil
            ) async throws -> Repository {
                var args = ["clone"]
                if let branch { args += ["--branch", branch] }
                if let depth { args += ["--depth", String(depth)] }
                args += [remote, directory.rawValue]
                let out = try await runGit(args)
                guard out.exitCode == 0, let repo = await discover(directory) else {
                    throw OperationError(
                        operation: .clone,
                        message: String(decoding: out.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                        directory: directory
                    )
                }
                return repo
            }

            public func create(
                worktree: SchemaPrimitive.AbsolutePath,
                gitDirectory: SchemaPrimitive.AbsolutePath
            ) async throws -> Repository {
                let out = try await runGit(["init", "--separate-git-dir", gitDirectory.rawValue, worktree.rawValue])
                guard out.exitCode == 0 else {
                    throw OperationError(
                        operation: .create,
                        message: String(decoding: out.stderr, as: UTF8.self),
                        directory: worktree
                    )
                }
                return Repository(worktree: worktree, gitDirectory: gitDirectory, commonDirectory: gitDirectory)
            }

            public func remoteGet(_ repository: Repository, name: String = "origin") async throws -> String? {
                let out = try await runGit(["remote", "get-url", name], cwd: repository.worktree.rawValue)
                if out.exitCode == 2 || out.exitCode == 128 {
                    let stderr = String(decoding: out.stderr, as: UTF8.self)
                    if stderr.contains("No such remote") { return nil }
                }
                guard out.exitCode == 0 else {
                    throw CommandError(args: ["remote", "get-url", name], exitCode: out.exitCode, detail: String(decoding: out.stderr, as: UTF8.self))
                }
                let url = String(decoding: out.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                return url.isEmpty ? nil : url
            }

            public func head(_ repository: Repository) async -> String? {
                guard let out = try? await runGit(["rev-parse", "HEAD"], cwd: repository.worktree.rawValue),
                      out.exitCode == 0
                else { return nil }
                let sha = String(decoding: out.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                return sha.isEmpty ? nil : sha
            }

            public func branch(_ repository: Repository) async -> String? {
                guard let out = try? await runGit(["symbolic-ref", "--short", "HEAD"], cwd: repository.worktree.rawValue),
                      out.exitCode == 0
                else { return nil }
                let name = String(decoding: out.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? nil : name
            }

            public func defaultRemoteBranch(_ repository: Repository, remote: String = "origin") async -> String? {
                guard let out = try? await runGit(["symbolic-ref", "--short", "refs/remotes/\(remote)/HEAD"], cwd: repository.worktree.rawValue),
                      out.exitCode == 0
                else { return nil }
                let full = String(decoding: out.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let prefix = "\(remote)/"
                return full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : full
            }

            public func rootCommits(_ repository: Repository) async throws -> [String] {
                let out = try await runGit(["rev-list", "--max-parents=0", "--all"], cwd: repository.worktree.rawValue)
                if out.exitCode != 0 { return [] }
                return String(decoding: out.stdout, as: UTF8.self)
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .sorted()
            }

            public func fetchRemotes(_ repository: Repository, prune: Bool = true) async throws {
                var args = ["fetch", "--all"]
                if prune { args.append("--prune") }
                let out = try await runGit(args, cwd: repository.worktree.rawValue)
                guard out.exitCode == 0 else {
                    throw OperationError(operation: .fetch, message: String(decoding: out.stderr, as: UTF8.self), directory: repository.worktree)
                }
            }

            public func fetchBranch(_ repository: Repository, remote: String = "origin", branch: String, force: Bool = false) async throws {
                var args = ["fetch", remote, branch]
                if force { args.append("--force") }
                let out = try await runGit(args, cwd: repository.worktree.rawValue)
                guard out.exitCode == 0 else {
                    throw OperationError(operation: .fetch, message: String(decoding: out.stderr, as: UTF8.self), directory: repository.worktree)
                }
            }

            public func checkoutRemoteBranch(_ repository: Repository, remote: String = "origin", branch: String, reset: Bool = true) async throws {
                let args = reset ? ["checkout", "-B", branch, "\(remote)/\(branch)"] : ["checkout", branch]
                let out = try await runGit(args, cwd: repository.worktree.rawValue)
                guard out.exitCode == 0 else {
                    throw OperationError(operation: .checkout, message: String(decoding: out.stderr, as: UTF8.self), directory: repository.worktree)
                }
            }

            public func resetHard(_ repository: Repository, revision: String) async throws {
                let out = try await runGit(["reset", "--hard", revision], cwd: repository.worktree.rawValue)
                guard out.exitCode == 0 else {
                    throw OperationError(operation: .reset, message: String(decoding: out.stderr, as: UTF8.self), directory: repository.worktree)
                }
            }

            public func worktreeCreate(
                repository: Repository,
                directory: SchemaPrimitive.AbsolutePath,
                ref: String? = nil
            ) async throws -> Repository {
                var args = ["worktree", "add", "--detach", directory.rawValue]
                if let ref { args = ["worktree", "add", "-b", ref, directory.rawValue] }
                let out = try await runGit(args, cwd: repository.worktree.rawValue)
                guard out.exitCode == 0 else {
                    throw WorktreeError(operation: .create, message: String(decoding: out.stderr, as: UTF8.self), directory: directory)
                }
                return (await discover(directory)) ?? Repository(
                    worktree: directory,
                    gitDirectory: repository.gitDirectory,
                    commonDirectory: repository.commonDirectory
                )
            }

            public func worktreeRemove(
                repository: Repository,
                directory: SchemaPrimitive.AbsolutePath,
                force: Bool
            ) async throws {
                var args = ["worktree", "remove"]
                if force { args.append("--force") }
                args.append(directory.rawValue)
                let out = try await runGit(args, cwd: repository.worktree.rawValue)
                guard out.exitCode == 0 else {
                    let err = String(decoding: out.stderr, as: UTF8.self)
                    let needsForce = err.contains("--force") || err.contains("contains modified or untracked files")
                    throw WorktreeError(operation: .remove, message: err, directory: directory, forceRequired: needsForce)
                }
            }

            public func worktreeList(_ repository: Repository) async throws -> [Worktree] {
                let out = try await runGit(["worktree", "list", "--porcelain"], cwd: repository.worktree.rawValue)
                guard out.exitCode == 0 else {
                    throw WorktreeError(operation: .list, message: String(decoding: out.stderr, as: UTF8.self), directory: repository.worktree)
                }
                let text = String(decoding: out.stdout, as: UTF8.self)
                var list: [Worktree] = []
                for line in text.split(separator: "\n") where line.hasPrefix("worktree ") {
                    let path = String(line.dropFirst("worktree ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    let kind: Worktree.Kind = list.isEmpty ? .main : .linked
                    list.append(Worktree(directory: SchemaPrimitive.AbsolutePath(rawValue: path), kind: kind))
                }
                return list
            }

            public func writeTree(_ repository: Repository) async throws -> TreeID {
                let out = try await runGit(["write-tree"], cwd: repository.worktree.rawValue)
                guard out.exitCode == 0 else {
                    throw OperationError(operation: .writeTree, message: String(decoding: out.stderr, as: UTF8.self), directory: repository.worktree)
                }
                return TreeID(rawValue: String(decoding: out.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }

            public func diffTree(
                repository: Repository,
                from: TreeID,
                to: TreeID,
                context: Int? = nil
            ) async throws -> [FileDiffSchema.Info] {
                var args = ["diff", "--no-color", "--no-ext-diff"]
                if let context { args.append("-U\(context)") }
                args += [from.rawValue, to.rawValue]
                let out = try await runGit(args, cwd: repository.worktree.rawValue)
                guard out.exitCode == 0 else {
                    throw OperationError(operation: .diff, message: String(decoding: out.stderr, as: UTF8.self), directory: repository.worktree)
                }
                let raw = String(decoding: out.stdout, as: UTF8.self)
                let byFile = Patch.chunksByFile(Patch.Info(text: raw, truncated: false))
                return byFile.keys.sorted().map { file in
                    let chunk = byFile[file] ?? ""
                    let counts = Patch.countPatch(chunk)
                    let status: FileDiffSchema.Status = chunk.contains("new file mode")
                        ? .added
                        : chunk.contains("deleted file mode") ? .deleted : .modified
                    return FileDiffSchema.Info(
                        file: file,
                        patch: chunk,
                        additions: SchemaPrimitive.NonNegativeInt(rawValue: counts.additions) ?? .zero,
                        deletions: SchemaPrimitive.NonNegativeInt(rawValue: counts.deletions) ?? .zero,
                        status: status
                    )
                }
            }
        }

        /// Builds a real `CoreVcs.Vcs.ProviderDefinition` backed by `CoreVcs.Git.Service`.
        public static func makeVcsProvider(
            directory: String,
            worktree: String? = nil,
            git: Service = Service()
        ) -> CoreVcs.Vcs.ProviderDefinition {
            let wt = worktree ?? directory
            return CoreVcs.Vcs.ProviderDefinition(
                id: "git",
                info: {
                    let current = await git.currentBranch(in: directory)
                    let root = await git.defaultBranch(in: directory)
                    return VcsSchema.Info(
                        provider: "git",
                        branch: VcsSchema.Branch(current: current, defaultBranch: root?.name)
                    )
                },
                base: {
                    try await git.base(in: directory)
                },
                branches: { options in
                    await git.branches(in: directory, options: options)
                },
                status: {
                    await git.status(in: directory, worktree: wt)
                },
                diff: { mode, options in
                    try await git.diff(in: directory, worktree: wt, mode: mode, options: options)
                },
                initialize: {
                    try await git.initRepository(at: wt)
                }
            )
        }

        // parity: core/src/git.ts#node [status=implemented hash=536d31f43a8e]
        public static let node: LayerNode.Provider = AppNode.makeGlobalNode(
            Service.serviceKey,
            LayerNode.ExecutableLayer { deps, _ in
                let spawner = deps.get(CrossSpawnSpawner.spawnerKey, as: (any ProcessSpawner).self)
                    ?? CrossSpawnSpawner.HostProcessSpawner.shared
                let fs = deps.get(LayerNodePlatform.fileSystemKey, as: (any OpenCodeFileSystem).self) ?? LocalFileSystem.shared
                return LayerNode.Output([Service.serviceKey: Service(spawner: spawner, fileSystem: fs)])
            },
            [CrossSpawnSpawner.node, LayerNodePlatform.filesystem]
        )
    }

    // MARK: - core/src/vcs.ts

    public enum Vcs {
        // parity: core/src/vcs.ts#Base [status=implemented hash=ed8666a3d18d]
        public typealias Base = VcsSchema.Base
        // parity: core/src/vcs.ts#BranchList [status=implemented hash=ed8666a3d18d]
        public typealias BranchList = VcsSchema.BranchList
        // parity: core/src/vcs.ts#FileStatus [status=implemented hash=ed8666a3d18d]
        public typealias FileStatus = VcsSchema.FileStatus
        // parity: core/src/vcs.ts#Info [status=implemented hash=ed8666a3d18d]
        public typealias Info = VcsSchema.Info
        // parity: core/src/vcs.ts#Mode [status=implemented hash=ed8666a3d18d]
        public typealias Mode = VcsSchema.Mode
        // parity: core/src/vcs.ts#Untracked [status=implemented hash=ed8666a3d18d]
        public typealias Untracked = VcsSchema.Untracked

        // parity: core/src/vcs.ts#DiffError [status=implemented hash=431ebc53d6c8]
        public struct DiffError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "Vcs.DiffError"
            public let message: String

            public init(message: String) {
                self.message = message
            }

            public var description: String { message }
        }

        // parity: core/src/vcs.ts#InitializeError [status=implemented hash=bfcf0565494f]
        public struct InitializeError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "Vcs.InitializeError"

            public enum Kind: String, Equatable, Hashable, Sendable, Codable {
                case missing, conflict, unknown, unsupported, failed
            }

            public let kind: Kind

            public init(kind: Kind) {
                self.kind = kind
            }

            public var description: String { "Vcs initialization failed: \(kind.rawValue)" }
        }

        // parity: core/src/vcs.ts#DiffOptions [status=implemented hash=f3584e0ec1b0]
        public struct DiffOptions: Equatable, Hashable, Sendable {
            public let context: Int?
            public let base: String?
            public let untracked: VcsSchema.Untracked?

            public init(context: Int? = nil, base: String? = nil, untracked: VcsSchema.Untracked? = nil) {
                self.context = context
                self.base = base
                self.untracked = untracked
            }
        }

        // parity: core/src/vcs.ts#BranchOptions [status=implemented hash=4983f58a6e05]
        public struct BranchOptions: Equatable, Hashable, Sendable {
            public let search: String?
            public let limit: Int?

            public init(search: String? = nil, limit: Int? = nil) {
                self.search = search
                self.limit = limit
            }
        }

        public struct ProviderDefinition: Sendable {
            public let id: String
            public let info: @Sendable () async throws -> VcsSchema.Info
            public let base: (@Sendable () async throws -> VcsSchema.Base?)?
            public let branches: @Sendable (BranchOptions?) async throws -> VcsSchema.BranchList
            public let status: @Sendable () async throws -> [VcsSchema.FileStatus]
            public let diff: @Sendable (VcsSchema.Mode, DiffOptions?) async throws -> [FileDiffSchema.Info]
            public let initialize: (@Sendable () async throws -> Void)?

            public init(
                id: String,
                info: @escaping @Sendable () async throws -> VcsSchema.Info,
                base: (@Sendable () async throws -> VcsSchema.Base?)? = nil,
                branches: @escaping @Sendable (BranchOptions?) async throws -> VcsSchema.BranchList = { _ in [] },
                status: @escaping @Sendable () async throws -> [VcsSchema.FileStatus] = { [] },
                diff: @escaping @Sendable (VcsSchema.Mode, DiffOptions?) async throws -> [FileDiffSchema.Info] = { _, _ in [] },
                initialize: (@Sendable () async throws -> Void)? = nil
            ) {
                self.id = id
                self.info = info
                self.base = base
                self.branches = branches
                self.status = status
                self.diff = diff
                self.initialize = initialize
            }
        }

        public struct Data: Sendable {
            public var providers: [String: ProviderDefinition]
            public var selection: String?

            public init(providers: [String: ProviderDefinition] = [:], selection: String? = nil) {
                self.providers = providers
                self.selection = selection
            }
        }

        public final class Editor: @unchecked Sendable {
            internal var data: Data
            internal init(data: Data) { self.data = data }
            public func add(_ provider: ProviderDefinition) { data.providers[provider.id] = provider }
            public var defaultSelection: String? {
                get { data.selection }
                set { data.selection = newValue }
            }
        }

        // parity: core/src/vcs.ts#Adapter [status=implemented hash=7c25e2a5cf9d]
        public protocol Adapter: Sendable {
            func info() async -> VcsSchema.Info
            func base() async throws -> VcsSchema.Base?
            func branches(_ options: BranchOptions?) async -> VcsSchema.BranchList
            func status() async -> [VcsSchema.FileStatus]
            func diff(_ mode: VcsSchema.Mode, options: DiffOptions?) async throws -> [FileDiffSchema.Info]
        }

        // parity: core/src/vcs.ts#Interface [status=implemented hash=2c4517c9ed4b]
        public protocol Interface: Adapter, CoreState.Transformable where Editor == Vcs.Editor {
            func initialize(providerID: String) async throws
        }

        // parity: core/src/vcs.ts#Service [status=implemented hash=df7d49ccd2a1]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/Vcs"
            private let projectDirectory: SchemaPrimitive.AbsolutePath
            private let detectedVcsType: String?
            private let fileSystem: any OpenCodeFileSystem
            private let state: CoreState.Store<Data, Editor>
            private let cachedInfo = Mutex(VcsSchema.Info(provider: nil, branch: VcsSchema.Branch()))

            public init(
                projectDirectory: SchemaPrimitive.AbsolutePath = SchemaPrimitive.AbsolutePath(rawValue: "/"),
                detectedVcsType: String? = nil,
                fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared
            ) {
                self.projectDirectory = projectDirectory
                self.detectedVcsType = detectedVcsType
                self.fileSystem = fileSystem
                self.state = CoreState.create(CoreState.Options(
                    name: "vcs",
                    initial: { Data() },
                    makeEditor: { Editor(data: $0) },
                    commitEditor: { $0.data }
                ))
            }

            public var directory: SchemaPrimitive.AbsolutePath { projectDirectory }

            private func selectedProvider() -> ProviderDefinition? {
                let data = state.get()
                guard let id = data.selection ?? detectedVcsType else { return nil }
                return data.providers[id]
            }

            @discardableResult
            public func transform(_ update: @escaping @Sendable (Editor) throws -> Void) async throws -> CoreState.Registration {
                let reg = try await state.transform(update)
                await refresh()
                return reg
            }

            public func reload() async {
                await state.reload()
                await refresh()
            }

            public func refresh() async {
                guard let provider = selectedProvider() else {
                    cachedInfo.withLock { $0 = VcsSchema.Info(provider: nil, branch: VcsSchema.Branch()) }
                    return
                }
                if let fetched = try? await provider.info() {
                    cachedInfo.withLock { $0 = VcsSchema.Info(provider: provider.id, branch: fetched.branch) }
                }
            }

            public func initialize(providerID: String) async throws {
                let isDir = (try? await fileSystem.stat(at: projectDirectory.rawValue).type == .directory) ?? false
                guard isDir else { throw InitializeError(kind: .missing) }
                if await CoreProject.Project.root(fileSystem: fileSystem, input: projectDirectory) != nil {
                    throw InitializeError(kind: .conflict)
                }
                guard let provider = state.get().providers[providerID] else {
                    throw InitializeError(kind: .unknown)
                }
                guard let initFn = provider.initialize else {
                    throw InitializeError(kind: .unsupported)
                }
                do {
                    try await initFn()
                } catch {
                    throw InitializeError(kind: .failed)
                }
            }

            public func info() async -> VcsSchema.Info {
                cachedInfo.withLock { $0 }
            }

            public func base() async throws -> VcsSchema.Base? {
                guard let provider = selectedProvider(), let baseFn = provider.base else { return nil }
                do {
                    return try await baseFn()
                } catch let err as DiffError {
                    throw err
                } catch {
                    throw DiffError(message: "VCS provider could not resolve a review base")
                }
            }

            public func branches(_ options: BranchOptions? = nil) async -> VcsSchema.BranchList {
                guard let provider = selectedProvider() else { return [] }
                return (try? await provider.branches(options)) ?? []
            }

            public func status() async -> [VcsSchema.FileStatus] {
                guard let provider = selectedProvider() else { return [] }
                return (try? await provider.status()) ?? []
            }

            public func diff(_ mode: VcsSchema.Mode, options: DiffOptions? = nil) async throws -> [FileDiffSchema.Info] {
                guard let provider = selectedProvider() else { return [] }
                let rows: [FileDiffSchema.Info]
                do {
                    rows = try await provider.diff(mode, options)
                } catch let err as DiffError {
                    throw err
                } catch {
                    throw DiffError(message: "VCS provider could not produce a diff")
                }
                var total = 0
                return rows.map { row in
                    let bytes = row.patch.utf8.count
                    if total + bytes > Patch.MAX_TOTAL_PATCH_BYTES {
                        return FileDiffSchema.Info(
                            file: row.file,
                            patch: Patch.emptyPatch(row.file),
                            additions: row.additions,
                            deletions: row.deletions,
                            status: row.status,
                            more: row.more
                        )
                    }
                    total += bytes
                    return row
                }
            }
        }

        // parity: core/src/vcs.ts#node [status=implemented hash=abc8df045023]
        public static let node: LayerNode.Provider = AppNode.makeLocationNode(
            Service.serviceKey,
            LayerNode.ExecutableLayer { deps, _ in
                let loc = deps.get(CoreLocation.Location.Service.serviceKey, as: CoreLocation.Location.Service.self)
                let fs = deps.get(LayerNodePlatform.fileSystemKey, as: (any OpenCodeFileSystem).self) ?? LocalFileSystem.shared
                let svc = Service(
                    projectDirectory: loc?.info.project.directory ?? SchemaPrimitive.AbsolutePath(rawValue: "/"),
                    detectedVcsType: loc?.vcs?.type.rawValue,
                    fileSystem: fs
                )
                return LayerNode.Output([Service.serviceKey: svc])
            },
            [LayerNodePlatform.filesystem, CoreLocation.Location.node]
        )
    }
}

// MARK: - CoreProject (`project*`, `repository.ts`, `repository-cache.ts`, `workspace*`)

public enum CoreProject {
    // MARK: - core/src/project/schema.ts

    public enum Schema {
        // parity: core/src/project/schema.ts#ID [status=implemented hash=58a3f9825aff]
        public typealias ID = ProjectSchema.ID

        // parity: core/src/project/schema.ts#Current [status=implemented hash=43d5c23a792c]
        public typealias Current = ProjectSchema.Current

        // parity: core/src/project/schema.ts#Info [status=implemented hash=548872463f2f]
        public typealias Info = ProjectSchema.Info

        // parity: core/src/project/schema.ts#UpdateInput [status=implemented hash=77d23226ab34]
        public typealias UpdateInput = ProjectSchema.UpdateInput

        // parity: core/src/project/schema.ts#Event [status=implemented hash=9c71f88f580c]
        public typealias Event = ProjectSchema.Event

        // parity: core/src/project/schema.ts#Vcs [status=implemented hash=ca37f14e83af]
        public struct Vcs: Equatable, Hashable, Sendable, Codable {
            public let type: ProjectSchema.Vcs
            public let store: SchemaPrimitive.AbsolutePath

            public init(type: ProjectSchema.Vcs, store: SchemaPrimitive.AbsolutePath) {
                self.type = type
                self.store = store
            }
        }
    }

    // MARK: - core/src/project/sql.ts

    public enum SQL {
        // parity: core/src/project/sql.ts#ProjectTable [status=adapted hash=f042ff64f5a3]
        public enum ProjectTable {
            public static let tableName = "project"
            public static let createTableSQL = """
                CREATE TABLE IF NOT EXISTS project (
                    id TEXT PRIMARY KEY,
                    worktree TEXT NOT NULL,
                    vcs TEXT,
                    name TEXT,
                    icon_url TEXT,
                    icon_url_override TEXT,
                    icon_color TEXT,
                    time_created INTEGER NOT NULL,
                    time_updated INTEGER NOT NULL,
                    time_initialized INTEGER,
                    time_active INTEGER NOT NULL DEFAULT 0,
                    time_archived INTEGER,
                    sandboxes TEXT NOT NULL DEFAULT '[]',
                    commands TEXT
                );
                """
        }

        // parity: core/src/project/sql.ts#ProjectDirectoryTable [status=adapted hash=e9c0c176d792]
        public enum ProjectDirectoryTable {
            public static let tableName = "project_directory"
            public static let createTableSQL = """
                CREATE TABLE IF NOT EXISTS project_directory (
                    project_id TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
                    directory TEXT NOT NULL,
                    type TEXT,
                    strategy TEXT,
                    time_created INTEGER NOT NULL,
                    PRIMARY KEY (project_id, directory)
                );
                """
        }

        // parity: core/src/project/sql.ts#upsertProject [status=implemented hash=90177c108c0b]
        public static func upsertProject(
            database: any SQLiteDatabase,
            id: Schema.ID,
            canonical: SchemaPrimitive.AbsolutePath,
            vcs: Schema.Vcs?
        ) throws {
            let now = Flock.currentEpochMs()
            let vcsType = vcs?.type.rawValue
            try database.transaction {
                if let existing = try database.queryOne("SELECT vcs FROM project WHERE id = ?", parameters: [.text(id.rawValue)]) {
                    if existing.string("vcs") != vcsType {
                        _ = try database.execute(
                            "UPDATE project SET vcs = ?, time_updated = ? WHERE id = ?",
                            parameters: [vcsType.map(SQLiteValue.text) ?? .null, .integer(now), .text(id.rawValue)]
                        )
                    }
                } else {
                    _ = try database.execute(
                        """
                        INSERT INTO project (id, worktree, vcs, time_created, time_updated, time_active, sandboxes)
                        VALUES (?, ?, ?, ?, ?, ?, '[]')
                        """,
                        parameters: [
                            .text(id.rawValue),
                            .text(canonical.rawValue),
                            vcsType.map(SQLiteValue.text) ?? .null,
                            .integer(now),
                            .integer(now),
                            .integer(now),
                        ]
                    )
                }
            }
        }
    }

    // MARK: - core/src/project/icon.ts

    public enum Icon {
        private static let imageExtensions: Set<String> = [".svg", ".png", ".ico", ".jpg", ".jpeg", ".webp"]
        private static let candidates: [String] = [
            "Assets.xcassets/AppIcon.appiconset",
            "ios/App/Assets.xcassets/AppIcon.appiconset",
            "assets/app-icon.svg", "assets/app-icon.png",
            "build/icon.svg", "build/icon.png",
            "src-tauri/icons/icon.svg", "src-tauri/icons/icon.png",
            "resources/icon.svg", "resources/icon.png",
            "icons/icon.svg", "icons/icon.png",
            "extension/icons/icon.svg", "extension/icons/icon.png",
            "public/favicon.svg", "app/favicon.svg", "src/app/favicon.svg", "site/public/favicon.svg", "favicon.svg",
            "public/icon.svg", "app/icon.svg", "src/app/icon.svg", "site/public/icon.svg", "icon.svg",
            "public/favicon.png", "app/favicon.png", "src/app/favicon.png", "site/public/favicon.png", "favicon.png",
            "public/apple-touch-icon.png", "app/apple-touch-icon.png", "apple-touch-icon.png",
            "public/icon.png", "app/icon.png", "icon.png",
            "public/favicon.ico", "favicon.ico",
            "assets/icon.svg", "assets/icon.png", "assets/logo.svg", "assets/logo.png",
            "public/logo.svg", "public/logo.png", "logo.svg", "logo.png",
        ]

        public struct DiscoveredIcon: Equatable, Hashable, Sendable {
            public let path: String
            public let url: String

            public init(path: String, url: String) {
                self.path = path
                self.url = url
            }
        }

        // parity: core/src/project/icon.ts#discover [status=implemented hash=a88646055ae6]
        public static func discover(
            fileSystem: any OpenCodeFileSystem,
            directory: String
        ) async -> DiscoveredIcon? {
            guard let root = try? await fileSystem.realPath(at: directory) else { return nil }
            for name in candidates {
                let candidate = "\(root)/\(name)"
                guard let resolved = try? await fileSystem.realPath(at: candidate),
                      resolved != root,
                      FSPathUtil.contains(parent: root, child: resolved),
                      let stat = try? await fileSystem.stat(at: resolved)
                else { continue }

                var files: [String] = []
                if stat.type == .directory && name.hasSuffix(".appiconset") {
                    let entries = (try? await fileSystem.readDirectory(at: resolved)) ?? []
                    files = entries
                        .filter { imageExtensions.contains(extname($0)) }
                        .sorted { a, b in
                            let ra = (a.contains("128") || a.contains("256")) ? 0 : 1
                            let rb = (b.contains("128") || b.contains("256")) ? 0 : 1
                            return ra == rb ? a < b : ra < rb
                        }
                        .map { "\(resolved)/\($0)" }
                } else if stat.type == .file && imageExtensions.contains(extname(resolved)) {
                    files = [resolved]
                }

                for file in files {
                    guard let fileStat = try? await fileSystem.stat(at: file),
                          fileStat.type == .file,
                          fileStat.size > 0,
                          fileStat.size <= 64 * 1024,
                          let bytes = try? await fileSystem.readFile(at: file)
                    else { continue }
                    let mime = mimeForExtension(extname(file))
                    let url = "data:\(mime);base64,\(bytesToBase64(bytes))"
                    if url.utf8.count <= 64 * 1024 {
                        let rel = file.hasPrefix("\(root)/") ? String(file.dropFirst(root.count + 1)) : file
                        return DiscoveredIcon(path: rel, url: url)
                    }
                }
            }
            return nil
        }

        // parity: core/src/project/icon.ts#refresh [status=implemented hash=9cf02fc4ee22]
        public static func refresh(
            fileSystem: any OpenCodeFileSystem,
            database: any SQLiteDatabase,
            id: Schema.ID
        ) async throws -> String? {
            guard id != ProjectID.global,
                  let row = try database.queryOne("SELECT worktree, icon_url FROM project WHERE id = ?", parameters: [.text(id.rawValue)]),
                  let worktree = row.string("worktree"),
                  let image = await discover(fileSystem: fileSystem, directory: worktree)
            else {
                return nil
            }
            if let existing = row.string("icon_url"), Hash.fast(existing) == Hash.fast(image.url) {
                return nil
            }
            _ = try database.execute(
                "UPDATE project SET icon_url = ?, time_updated = ? WHERE id = ?",
                parameters: [.text(image.url), .integer(Flock.currentEpochMs()), .text(id.rawValue)]
            )
            return image.url
        }

        private static func extname(_ path: String) -> String {
            let base = CoreInstruction.Discovery.lastPathComponent(path)
            guard let dot = base.lastIndex(of: ".") else { return "" }
            return String(base[dot...]).lowercased()
        }

        private static func mimeForExtension(_ ext: String) -> String {
            switch ext {
            case ".svg": return "image/svg+xml"
            case ".png": return "image/png"
            case ".ico": return "image/x-icon"
            case ".jpg", ".jpeg": return "image/jpeg"
            case ".webp": return "image/webp"
            default: return "application/octet-stream"
            }
        }
    }

    // MARK: - core/src/project.ts

    public enum Project {
        // parity: core/src/project.ts#ID [status=implemented hash=8638f2128622]
        public typealias ID = Schema.ID

        // parity: core/src/project.ts#Vcs [status=implemented hash=7fab6ca60dcb]
        public typealias Vcs = Schema.Vcs

        // parity: core/src/project.ts#Current [status=implemented hash=980d04d2fd21]
        public typealias Current = Schema.Current

        // parity: core/src/project.ts#Info [status=implemented hash=e18f0387a3d2]
        public typealias Info = Schema.Info

        // parity: core/src/project.ts#UpdateInput [status=implemented hash=e829e2e144bd]
        public typealias UpdateInput = Schema.UpdateInput

        // parity: core/src/project.ts#NotFoundError [status=implemented hash=06908269bb16]
        public struct NotFoundError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "Project.NotFoundError"
            public let projectID: ID

            public init(projectID: ID) {
                self.projectID = projectID
            }

            public var description: String { "Project not found: \(projectID.rawValue)" }
        }

        // parity: core/src/project.ts#Resolved [status=implemented hash=e36fd6ae770d]
        public struct Resolved: Equatable, Hashable, Sendable {
            public let previous: ID?
            public let id: ID
            public let directory: SchemaPrimitive.AbsolutePath
            public let canonical: SchemaPrimitive.AbsolutePath
            public let vcs: Vcs?

            public init(
                previous: ID? = nil,
                id: ID,
                directory: SchemaPrimitive.AbsolutePath,
                canonical: SchemaPrimitive.AbsolutePath,
                vcs: Vcs? = nil
            ) {
                self.previous = previous
                self.id = id
                self.directory = directory
                self.canonical = canonical
                self.vcs = vcs
            }
        }

        /// Walks upward from `input` looking for any VCS marker (default `[".git", ".hg"]`).
        // parity: core/src/project.ts#root [status=implemented hash=6b39bccef2e2]
        public static func root(
            fileSystem: any OpenCodeFileSystem,
            input: SchemaPrimitive.AbsolutePath,
            markers: [String] = [".git", ".hg"]
        ) async -> SchemaPrimitive.AbsolutePath? {
            var current = input.rawValue
            while true {
                for marker in markers {
                    let candidate = current == "/" ? "/\(marker)" : "\(current)/\(marker)"
                    if await fileSystem.exists(at: candidate) {
                        return SchemaPrimitive.AbsolutePath(rawValue: current)
                    }
                }
                let parent = CoreInstruction.Discovery.parentPath(current)
                if parent == current || current.isEmpty {
                    return nil
                }
                current = parent
            }
        }

        // parity: core/src/project.ts#ACTIVATE_INTERVAL [status=implemented hash=474eed618b98]
        public static let ACTIVATE_INTERVAL: Int64 = 60_000

        // parity: core/src/project.ts#Options [status=implemented hash=666f8bfd8f18]
        public struct Options: Sendable {
            public let now: (@Sendable () -> Int64)?

            public init(now: (@Sendable () -> Int64)? = nil) {
                self.now = now
            }
        }

        // parity: core/src/project.ts#ListInput [status=implemented hash=30f2a3d2cc44]
        public struct ListInput: Equatable, Hashable, Sendable {
            public let archived: Bool?

            public init(archived: Bool? = nil) {
                self.archived = archived
            }
        }

        // parity: core/src/project.ts#ResolveOptions [status=implemented hash=aa47c2d20819]
        public struct ResolveOptions: Equatable, Hashable, Sendable {
            public let persist: Bool?

            public init(persist: Bool? = nil) {
                self.persist = persist
            }
        }

        // parity: core/src/project.ts#ActivateOptions [status=implemented hash=372e7087e238]
        public struct ActivateOptions: Equatable, Hashable, Sendable {
            public let background: Bool

            public init(background: Bool = false) {
                self.background = background
            }
        }

        // parity: core/src/project.ts#Interface [status=implemented hash=abd8af220ca2]
        public protocol Interface: Sendable {
            func list(_ input: ListInput?) async throws -> [Info]
            func update(_ input: UpdateInput) async throws -> Info
            func activate(_ projectID: ID, options: ActivateOptions?) async throws
            func resolve(_ input: SchemaPrimitive.AbsolutePath, options: ResolveOptions?) async throws -> Resolved
            func sweep() async throws
        }

        // parity: core/src/project.ts#Service [status=implemented hash=85e364820b91]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/Project"
            private let db: any SQLiteDatabase
            private let fileSystem: any OpenCodeFileSystem
            private let git: any CoreVcs.Git.Interface
            private let now: @Sendable () -> Int64
            private let lastActivated = Mutex<[ID: Int64]>([:])

            public init(
                database: any SQLiteDatabase,
                fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
                git: any CoreVcs.Git.Interface = CoreVcs.Git.Service(),
                options: Options = Options()
            ) throws {
                self.db = database
                self.fileSystem = fileSystem
                self.git = git
                self.now = options.now ?? { Flock.currentEpochMs() }
                try database.executeScript(SQL.ProjectTable.createTableSQL)
                try database.executeScript(CoreWorktree.SQL.WorktreeTable.createTableSQL)
            }

            public static func inMemory(
                fileSystem: any OpenCodeFileSystem = InMemoryFileSystem(),
                git: any CoreVcs.Git.Interface = CoreVcs.Git.Service()
            ) throws -> Service {
                try Service(
                    database: SQLiteDatabaseFactory.open(path: ":memory:"),
                    fileSystem: fileSystem,
                    git: git
                )
            }

            public func list(_ input: ListInput? = nil) async throws -> [Info] {
                let includeArchived = input?.archived == true
                let sql = includeArchived
                    ? "SELECT * FROM project ORDER BY time_active DESC, time_created DESC"
                    : "SELECT * FROM project WHERE time_archived IS NULL ORDER BY time_active DESC, time_created DESC"
                let rows = try db.query(sql)
                return rows.compactMap(Self.fromRow)
            }

            public func update(_ input: UpdateInput) async throws -> Info {
                guard let row = try db.queryOne("SELECT * FROM project WHERE id = ?", parameters: [.text(input.projectID.rawValue)]),
                      let existing = Self.fromRow(row)
                else {
                    throw NotFoundError(projectID: input.projectID)
                }
                let updatedAt = now()
                let nextCanonical = input.canonical ?? existing.canonical
                let nextName = input.name ?? existing.name
                let nextIcon = input.icon ?? existing.icon
                let nextCommands = input.commands ?? existing.commands
                let commandsJSON = nextCommands.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
                _ = try db.execute(
                    """
                    UPDATE project
                    SET worktree = ?, name = ?, icon_url = ?, icon_url_override = ?, icon_color = ?, commands = ?, time_updated = ?
                    WHERE id = ?
                    """,
                    parameters: [
                        .text(nextCanonical.rawValue),
                        nextName.map(SQLiteValue.text) ?? .null,
                        nextIcon?.url.map(SQLiteValue.text) ?? .null,
                        nextIcon?.override.map(SQLiteValue.text) ?? .null,
                        nextIcon?.color.map(SQLiteValue.text) ?? .null,
                        commandsJSON.map(SQLiteValue.text) ?? .null,
                        .integer(updatedAt),
                        .text(input.projectID.rawValue),
                    ]
                )
                guard let refreshed = try db.queryOne("SELECT * FROM project WHERE id = ?", parameters: [.text(input.projectID.rawValue)]),
                      let info = Self.fromRow(refreshed)
                else {
                    throw NotFoundError(projectID: input.projectID)
                }
                return info
            }

            public func activate(_ projectID: ID, options: ActivateOptions? = nil) async throws {
                _ = options
                let currentNow = now()
                let shouldWrite = lastActivated.withLock { map -> Bool in
                    if let prev = map[projectID], currentNow - prev < Project.ACTIVATE_INTERVAL {
                        return false
                    }
                    map[projectID] = currentNow
                    return true
                }
                guard shouldWrite else { return }
                _ = try db.execute(
                    "UPDATE project SET time_active = ? WHERE id = ?",
                    parameters: [.integer(currentNow), .text(projectID.rawValue)]
                )
            }

            public func resolve(
                _ input: SchemaPrimitive.AbsolutePath,
                options: ResolveOptions? = nil
            ) async throws -> Resolved {
                let resolvedDir = (try? await fileSystem.realPath(at: input.rawValue)) ?? input.rawValue
                let absDir = SchemaPrimitive.AbsolutePath(rawValue: resolvedDir)
                let resolved: Resolved
                if let gitRepo = await git.discover(absDir) {
                    let roots = (try? await git.rootCommits(gitRepo)) ?? []
                    let idStr = roots.first ?? Hash.fast(gitRepo.commonDirectory.rawValue)
                    let vcs = Vcs(type: ProjectSchema.Vcs(rawValue: "git")!, store: gitRepo.gitDirectory)
                    resolved = Resolved(
                        id: ProjectID(rawValue: idStr),
                        directory: gitRepo.worktree,
                        canonical: gitRepo.worktree,
                        vcs: vcs
                    )
                } else if let foundRoot = await Project.root(fileSystem: fileSystem, input: absDir, markers: [".git", ".hg"]) {
                    let hasGit = await fileSystem.exists(at: "\(foundRoot.rawValue)/.git")
                    let marker = hasGit ? ".git" : ".hg"
                    let vcsType = hasGit ? "git" : "hg"
                    let vcs = Vcs(
                        type: ProjectSchema.Vcs(rawValue: vcsType)!,
                        store: SchemaPrimitive.AbsolutePath(rawValue: "\(foundRoot.rawValue)/\(marker)")
                    )
                    resolved = Resolved(
                        id: ProjectID(rawValue: Hash.fast(foundRoot.rawValue)),
                        directory: foundRoot,
                        canonical: foundRoot,
                        vcs: vcs
                    )
                } else {
                    resolved = Resolved(
                        id: ProjectID(rawValue: Hash.fast(absDir.rawValue)),
                        directory: absDir,
                        canonical: absDir,
                        vcs: nil
                    )
                }
                if options?.persist != false {
                    try SQL.upsertProject(database: db, id: resolved.id, canonical: resolved.canonical, vcs: resolved.vcs)
                    _ = try db.execute(
                        "UPDATE project SET time_archived = NULL WHERE id = ? AND time_archived IS NOT NULL",
                        parameters: [.text(resolved.id.rawValue)]
                    )
                }
                return resolved
            }

            public func sweep() async throws {
                let rows = try db.query("SELECT id, worktree FROM project WHERE time_archived IS NULL")
                let currentNow = now()
                for row in rows {
                    guard let id = row.string("id"), id != ProjectID.global.rawValue,
                          let worktree = row.string("worktree")
                    else { continue }
                    let exists = await fileSystem.exists(at: worktree)
                    if !exists {
                        _ = try db.execute(
                            "UPDATE project SET time_archived = ?, time_updated = ? WHERE id = ?",
                            parameters: [.integer(currentNow), .integer(currentNow), .text(id)]
                        )
                    }
                }
            }

            private static func fromRow(_ row: SQLiteRow) -> Info? {
                guard let id = row.string("id"),
                      let worktree = row.string("worktree"),
                      let created = row.int64("time_created"),
                      let updated = row.int64("time_updated"),
                      let active = row.int64("time_active")
                else { return nil }
                let iconURL = row.string("icon_url")
                let iconOverride = row.string("icon_url_override")
                let iconColor = row.string("icon_color")
                let icon: ProjectSchema.Icon? = (iconURL != nil || iconOverride != nil || iconColor != nil)
                    ? ProjectSchema.Icon(url: iconURL, override: iconOverride, color: iconColor)
                    : nil
                let commands: ProjectSchema.Commands? = row.string("commands").flatMap {
                    try? JSONDecoder().decode(ProjectSchema.Commands.self, from: Data($0.utf8))
                }
                let sandboxes: [String] = row.string("sandboxes").flatMap {
                    try? JSONDecoder().decode([String].self, from: Data($0.utf8))
                } ?? []
                return Info(
                    id: ProjectID(rawValue: id),
                    canonical: SchemaPrimitive.AbsolutePath(rawValue: worktree),
                    vcs: row.string("vcs").flatMap(ProjectSchema.Vcs.init(rawValue:)),
                    name: row.string("name"),
                    icon: icon,
                    commands: commands,
                    time: ProjectSchema.Time(
                        created: SchemaPrimitive.NonNegativeInt(rawValue: Int(created)) ?? .zero,
                        updated: SchemaPrimitive.NonNegativeInt(rawValue: Int(updated)) ?? .zero,
                        active: SchemaPrimitive.NonNegativeInt(rawValue: Int(active)) ?? .zero,
                        archived: row.int64("time_archived").flatMap { SchemaPrimitive.NonNegativeInt(rawValue: Int($0)) }
                    ),
                    sandboxes: sandboxes
                )
            }
        }

        // parity: core/src/project.ts#configured [status=implemented hash=9402ca490fdd]
        public static func configured(_ options: Options = Options()) -> LayerNode.Provider {
            AppNode.makeGlobalNode(
                Service.serviceKey,
                LayerNode.ExecutableLayer { deps, _ in
                    let fs = deps.get(LayerNodePlatform.fileSystemKey, as: (any OpenCodeFileSystem).self) ?? LocalFileSystem.shared
                    let git = deps.get(CoreVcs.Git.Service.serviceKey, as: CoreVcs.Git.Service.self) ?? CoreVcs.Git.Service()
                    let db = try SQLiteDatabaseFactory.open(path: ":memory:")
                    let svc = try Service(database: db, fileSystem: fs, git: git, options: options)
                    return LayerNode.Output([Service.serviceKey: svc])
                },
                [LayerNodePlatform.filesystem, CoreVcs.Git.node]
            )
        }

        // parity: core/src/project.ts#node [status=implemented hash=aea3814ebc3b]
        public static let node: LayerNode.Provider = configured()

        // parity: core/src/project.ts#sweepNode [status=adapted hash=a0549cd0e8fe]
        public static let sweepNode: LayerNode.Provider = AppNode.makeGlobalNode(
            "@opencode/ProjectSweep",
            LayerNode.ExecutableLayer.empty,
            [node]
        )
    }

    // MARK: - core/src/repository.ts

    public enum Repository {
        // parity: core/src/repository.ts#RemoteReference [status=implemented hash=7aa3eb10299c]
        public struct RemoteReference: Equatable, Hashable, Sendable, Codable {
            public let host: String
            public let path: String
            public let segments: [String]
            public let owner: String?
            public let repo: String
            public let remote: String
            public let label: String
            public let protocolScheme: String?

            public init(
                host: String,
                path: String,
                segments: [String],
                owner: String? = nil,
                repo: String,
                remote: String,
                label: String,
                protocolScheme: String? = nil
            ) {
                self.host = host
                self.path = path
                self.segments = segments
                self.owner = owner
                self.repo = repo
                self.remote = remote
                self.label = label
                self.protocolScheme = protocolScheme
            }
        }

        // parity: core/src/repository.ts#FileReference [status=implemented hash=f07cbbd15a99]
        public struct FileReference: Equatable, Hashable, Sendable, Codable {
            public let host: String
            public let path: String
            public let segments: [String]
            public let owner: String?
            public let repo: String
            public let remote: String
            public let label: String
            public let protocolScheme: String

            public init(path: String, segments: [String], repo: String, remote: String, label: String) {
                self.host = "file"
                self.path = path
                self.segments = segments
                self.owner = nil
                self.repo = repo
                self.remote = remote
                self.label = label
                self.protocolScheme = "file:"
            }
        }

        // parity: core/src/repository.ts#Reference [status=implemented hash=45d7870d2565]
        public enum Reference: Equatable, Hashable, Sendable, Codable {
            case remote(RemoteReference)
            case file(FileReference)

            public var host: String {
                switch self { case .remote(let r): r.host; case .file(let f): f.host }
            }
            public var path: String {
                switch self { case .remote(let r): r.path; case .file(let f): f.path }
            }
            public var segments: [String] {
                switch self { case .remote(let r): r.segments; case .file(let f): f.segments }
            }
            public var remoteURL: String {
                switch self { case .remote(let r): r.remote; case .file(let f): f.remote }
            }
            public var label: String {
                switch self { case .remote(let r): r.label; case .file(let f): f.label }
            }
        }

        // parity: core/src/repository.ts#InvalidReferenceError [status=implemented hash=5a217452f904]
        public struct InvalidReferenceError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "RepositoryInvalidReferenceError"
            public let repository: String
            public let message: String

            public init(repository: String, message: String) {
                self.repository = repository
                self.message = message
            }

            public var description: String { message }
        }

        // parity: core/src/repository.ts#UnsupportedLocalRepositoryError [status=implemented hash=bc5baffdb795]
        public struct UnsupportedLocalRepositoryError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "RepositoryUnsupportedLocalRepositoryError"
            public let repository: String
            public let message: String

            public init(repository: String, message: String) {
                self.repository = repository
                self.message = message
            }

            public var description: String { message }
        }

        // parity: core/src/repository.ts#InvalidBranchError [status=implemented hash=eca2a5004d6c]
        public struct InvalidBranchError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "RepositoryInvalidBranchError"
            public let branch: String
            public let message: String

            public init(branch: String, message: String) {
                self.branch = branch
                self.message = message
            }

            public var description: String { message }
        }

        private static func normalizeInput(_ input: String) -> String {
            var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.hasPrefix("git+") { s = String(s.dropFirst(4)) }
            if let hashIdx = s.firstIndex(of: "#") { s = String(s[..<hashIdx]) }
            while s.hasSuffix("/") { s.removeLast() }
            return s
        }

        private static func trimGitSuffix(_ s: String) -> String {
            s.hasSuffix(".git") ? String(s.dropLast(4)) : s
        }

        private static func safeSegment(_ s: String) -> Bool {
            !s.isEmpty && s != "." && s != ".." && !s.contains(":") && !s.contains("/") && !s.contains("\\") && !s.contains(where: \.isWhitespace)
        }

        private static func safeHost(_ host: String) -> Bool {
            !host.isEmpty && !host.hasPrefix("-") && host.split(separator: ":", omittingEmptySubsequences: false).allSatisfy { safeSegment(String($0)) }
        }

        private static func hostLike(_ s: String) -> Bool {
            s.contains(".") || s.contains(":") || s == "localhost"
        }

        private static func buildRemote(host: String, rawSegments: [String], remote: String? = nil, scheme: String? = nil) -> RemoteReference? {
            let segments = rawSegments.map { trimGitSuffix($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
            guard safeHost(host), !segments.isEmpty, segments.allSatisfy(safeSegment) else { return nil }
            let lowerHost = host.lowercased()
            let repoPath = segments.joined(separator: "/")
            let defaultRemote = lowerHost == "github.com"
                ? "https://github.com/\(repoPath).git"
                : "https://\(lowerHost)/\(repoPath).git"
            let label = (lowerHost == "github.com" && segments.count == 2) ? repoPath : "\(lowerHost)/\(repoPath)"
            return RemoteReference(
                host: lowerHost,
                path: repoPath,
                segments: segments,
                owner: segments.count == 2 ? segments[0] : nil,
                repo: segments.last!,
                remote: remote ?? defaultRemote,
                label: label,
                protocolScheme: scheme
            )
        }

        // parity: core/src/repository.ts#parse [status=implemented hash=a10cd031e6f4]
        public static func parse(_ input: String) -> Reference? {
            let cleaned = normalizeInput(input)
            guard !cleaned.isEmpty else { return nil }

            if cleaned.hasPrefix("github:") {
                let rest = String(cleaned.dropFirst("github:".count))
                let parts = rest.split(separator: "/").map(String.init)
                if parts.count == 2, !parts[0].contains(where: \.isWhitespace), !parts[1].contains(where: \.isWhitespace) {
                    return buildRemote(host: "github.com", rawSegments: parts).map(Reference.remote)
                }
            }

            if !cleaned.contains("://") {
                if let colon = cleaned.firstIndex(of: ":"), !cleaned[..<colon].contains("/") {
                    let hostPart = String(cleaned[..<colon])
                    let pathPart = String(cleaned[cleaned.index(after: colon)...])
                    let host: String
                    if let at = hostPart.lastIndex(of: "@") {
                        host = String(hostPart[hostPart.index(after: at)...])
                    } else {
                        host = hostPart
                    }
                    let segs = pathPart.split(separator: "/").map(String.init)
                    if let r = buildRemote(host: host, rawSegments: segs, remote: cleaned) {
                        return .remote(r)
                    }
                }
                let direct = cleaned.split(separator: "/").map(String.init)
                if direct.count >= 2 && hostLike(direct[0]) {
                    return buildRemote(host: direct[0], rawSegments: Array(direct.dropFirst())).map(Reference.remote)
                }
                if direct.count == 2 {
                    return buildRemote(host: "github.com", rawSegments: direct).map(Reference.remote)
                }
            }

            guard let url = URL(string: cleaned), let scheme = url.scheme?.lowercased() else { return nil }
            if scheme == "file" {
                let filePath = url.path
                let segs = filePath.split(separator: "/").map(String.init)
                guard let last = segs.last else { return nil }
                return .file(FileReference(
                    path: filePath,
                    segments: segs,
                    repo: trimGitSuffix(last),
                    remote: cleaned,
                    label: filePath
                ))
            }
            guard let host = url.host else { return nil }
            let hostWithPort = url.port.map { "\(host):\($0)" } ?? host
            let segs = url.path.split(separator: "/").map(String.init)
            let normalizedRemote = hostWithPort.lowercased() == "github.com"
                ? "https://github.com/\(segs.map(trimGitSuffix).joined(separator: "/")).git"
                : cleaned
            return buildRemote(
                host: hostWithPort,
                rawSegments: segs,
                remote: normalizedRemote,
                scheme: "\(scheme):"
            ).map(Reference.remote)
        }

        // parity: core/src/repository.ts#parseRemote [status=implemented hash=455c09a6381b]
        public static func parseRemote(_ input: String) throws -> RemoteReference {
            guard let ref = parse(input) else {
                throw InvalidReferenceError(
                    repository: input,
                    message: "Repository must be a git URL, host/path reference, or GitHub owner/repo shorthand"
                )
            }
            switch ref {
            case .remote(let remote):
                return remote
            case .file:
                throw UnsupportedLocalRepositoryError(
                    repository: input,
                    message: "Local file repositories are not supported"
                )
            }
        }

        // parity: core/src/repository.ts#validateBranch [status=implemented hash=4b155900e5f0]
        public static func validateBranch(_ branch: String) throws(InvalidBranchError) {
            let validChars = !branch.isEmpty && branch.unicodeScalars.allSatisfy { s in
                (s.value >= 0x30 && s.value <= 0x39) ||
                    (s.value >= 0x41 && s.value <= 0x5A) ||
                    (s.value >= 0x61 && s.value <= 0x7A) ||
                    s == "/" || s == "_" || s == "." || s == "-"
            }
            if validChars && !branch.hasPrefix("-") && !branch.contains("..") {
                return
            }
            throw InvalidBranchError(
                branch: branch,
                message: "Branch must contain only alphanumeric characters, /, _, ., and -, and cannot start with - or contain .."
            )
        }

        // parity: core/src/repository.ts#isFile [status=implemented hash=a87dcfbaacc3]
        public static func isFile(_ reference: Reference) -> Bool {
            if case .file = reference { return true }
            return false
        }

        // parity: core/src/repository.ts#isRemote [status=implemented hash=2d5f2a0e7899]
        public static func isRemote(_ reference: Reference) -> Bool {
            !isFile(reference)
        }

        // parity: core/src/repository.ts#cachePath [status=implemented hash=35ff2aa5ca8f]
        public static func cachePath(root: String, reference: Reference, branch: String? = nil) -> String {
            var parts = [root.hasSuffix("/") ? String(root.dropLast()) : root]
            parts.append(contentsOf: reference.host.split(separator: ":").map(String.init))
            parts.append(contentsOf: reference.segments)
            let base = parts.joined(separator: "/")
            guard let branch else { return base }
            let encoded = branch.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? branch
            return "\(base)@\(encoded)"
        }

        // parity: core/src/repository.ts#cacheIdentity [status=implemented hash=1c95fb1decb7]
        public static func cacheIdentity(_ reference: Reference) -> String {
            "\(reference.host)/\(reference.path)"
        }

        // parity: core/src/repository.ts#same [status=implemented hash=bd18e259c212]
        public static func same(_ left: Reference, _ right: Reference) -> Bool {
            cacheIdentity(left) == cacheIdentity(right)
        }
    }

    // MARK: - core/src/repository-cache.ts

    public enum RepositoryCache {
        // parity: core/src/repository-cache.ts#Result [status=implemented hash=9c5bae68e77c]
        public struct Result: Equatable, Hashable, Sendable, Codable {
            public enum Status: String, Equatable, Hashable, Sendable, Codable {
                case cached, cloned, refreshed
            }

            public let repository: String
            public let host: String
            public let remote: String
            public let localPath: String
            public let status: Status
            public let head: String?
            public let branch: String?

            public init(
                repository: String,
                host: String,
                remote: String,
                localPath: String,
                status: Status,
                head: String? = nil,
                branch: String? = nil
            ) {
                self.repository = repository
                self.host = host
                self.remote = remote
                self.localPath = localPath
                self.status = status
                self.head = head
                self.branch = branch
            }
        }

        public enum RefreshPolicy: Equatable, Hashable, Sendable {
            case never
            case daily
            case force
        }

        // parity: core/src/repository-cache.ts#EnsureInput [status=implemented hash=f62c7e4abfc5]
        public struct EnsureInput: Equatable, Hashable, Sendable {
            public let reference: Repository.RemoteReference
            public let refresh: RefreshPolicy
            public let branch: String?

            public init(reference: Repository.RemoteReference, refresh: RefreshPolicy = .never, branch: String? = nil) {
                self.reference = reference
                self.refresh = refresh
                self.branch = branch
            }
        }

        // parity: core/src/repository-cache.ts#InvalidBranchError [status=implemented hash=37a1ce862311]
        public struct InvalidBranchError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "RepositoryCacheInvalidBranchError"
            public let branch: String
            public let message: String
            public init(branch: String, message: String) { self.branch = branch; self.message = message }
            public var description: String { message }
        }

        // parity: core/src/repository-cache.ts#CloneFailedError [status=implemented hash=98f46b6b4df6]
        public struct CloneFailedError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "RepositoryCacheCloneFailedError"
            public let repository: String
            public let message: String
            public init(repository: String, message: String) { self.repository = repository; self.message = message }
            public var description: String { message }
        }

        // parity: core/src/repository-cache.ts#FetchFailedError [status=implemented hash=981191ca26f2]
        public struct FetchFailedError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "RepositoryCacheFetchFailedError"
            public let repository: String
            public let message: String
            public init(repository: String, message: String) { self.repository = repository; self.message = message }
            public var description: String { message }
        }

        // parity: core/src/repository-cache.ts#CheckoutFailedError [status=implemented hash=182be87d57dc]
        public struct CheckoutFailedError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "RepositoryCacheCheckoutFailedError"
            public let repository: String
            public let branch: String
            public let message: String
            public init(repository: String, branch: String, message: String) {
                self.repository = repository; self.branch = branch; self.message = message
            }
            public var description: String { message }
        }

        // parity: core/src/repository-cache.ts#ResetFailedError [status=implemented hash=ad54511c6eed]
        public struct ResetFailedError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "RepositoryCacheResetFailedError"
            public let repository: String
            public let message: String
            public init(repository: String, message: String) { self.repository = repository; self.message = message }
            public var description: String { message }
        }

        // parity: core/src/repository-cache.ts#LockFailedError [status=implemented hash=9d6c44d419e4]
        public struct LockFailedError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "RepositoryCacheLockFailedError"
            public let localPath: String
            public let message: String
            public init(localPath: String, message: String) { self.localPath = localPath; self.message = message }
            public var description: String { message }
        }

        // parity: core/src/repository-cache.ts#CacheOperationError [status=implemented hash=7ac898e4b0b9]
        public struct CacheOperationError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "RepositoryCacheOperationError"
            public let operation: String
            public let path: String
            public let message: String
            public init(operation: String, path: String, message: String) {
                self.operation = operation; self.path = path; self.message = message
            }
            public var description: String { message }
        }

        // parity: core/src/repository-cache.ts#Error [status=implemented hash=d9e0e909632b]
        public enum CacheError: Swift.Error, Equatable, Hashable, Sendable {
            case invalidBranch(InvalidBranchError)
            case cloneFailed(CloneFailedError)
            case fetchFailed(FetchFailedError)
            case checkoutFailed(CheckoutFailedError)
            case resetFailed(ResetFailedError)
            case lockFailed(LockFailedError)
            case cacheOperation(CacheOperationError)
        }

        // parity: core/src/repository-cache.ts#isError [status=implemented hash=7941e8ee93fa]
        public static func isError(_ error: any Error) -> Bool {
            error is InvalidBranchError ||
                error is CloneFailedError ||
                error is FetchFailedError ||
                error is CheckoutFailedError ||
                error is ResetFailedError ||
                error is LockFailedError ||
                error is CacheOperationError ||
                error is CacheError
        }

        // parity: core/src/repository-cache.ts#validateBranch [status=implemented hash=e091b2866706]
        public static func validateBranch(_ branch: String) throws(InvalidBranchError) {
            do {
                try Repository.validateBranch(branch)
            } catch {
                throw InvalidBranchError(branch: branch, message: error.message)
            }
        }

        // parity: core/src/repository-cache.ts#Interface [status=implemented hash=9848914f6701]
        public protocol Interface: Sendable {
            func ensure(_ input: EnsureInput) async throws -> Result
        }

        // parity: core/src/repository-cache.ts#Service [status=implemented hash=0171e8250106]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/RepositoryCache"
            private static let dailyIntervalMs: Int64 = 24 * 60 * 60 * 1_000

            private let reposRoot: String
            private let fileSystem: any OpenCodeFileSystem
            private let git: any CoreVcs.Git.Interface
            private let kv: any CoreKV.Interface
            private let mutex = CoreSubsystems.Effect.KeyedMutex<String>()

            public init(
                reposRoot: String = GlobalPaths.roots().data + "/repos",
                fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
                git: any CoreVcs.Git.Interface = CoreVcs.Git.Service(),
                kv: any CoreKV.Interface
            ) {
                self.reposRoot = reposRoot
                self.fileSystem = fileSystem
                self.git = git
                self.kv = kv
            }

            public func ensure(_ input: EnsureInput) async throws -> Result {
                if let branch = input.branch {
                    try RepositoryCache.validateBranch(branch)
                }
                let localPath = Repository.cachePath(root: reposRoot, reference: .remote(input.reference), branch: input.branch)
                let key = "repository-cache:\(localPath)"
                return try await mutex.withLock(key) { [self] in
                    let parent = CoreInstruction.Discovery.parentPath(localPath)
                    do {
                        try await self.fileSystem.makeDirectory(at: parent, recursive: true)
                    } catch {
                        throw CacheOperationError(operation: "ensure cache directory", path: localPath, message: String(describing: error))
                    }
                    let absLocal = SchemaPrimitive.AbsolutePath(rawValue: localPath)
                    let existing = await self.git.discover(absLocal)
                    let origin = existing != nil ? (try? await self.git.remoteGet(existing!, name: "origin")) : nil
                    let originRef = origin.flatMap(Repository.parse)
                    let targetRef = Repository.parse(input.reference.remote) ?? .remote(input.reference)
                    let resolvedLocal = (try? await self.fileSystem.realPath(at: localPath)) ?? localPath
                    let reuse = existing != nil &&
                        existing!.worktree.rawValue == resolvedLocal &&
                        originRef != nil &&
                        Repository.same(originRef!, targetRef)

                    let localExists = await self.fileSystem.exists(at: localPath)
                    if !reuse && localExists {
                        try? await self.fileSystem.remove(at: localPath)
                    }
                    let now = Flock.currentEpochMs()
                    let prevVal = try? await self.kv.get(key)
                    let prevAttempt: Int64?
                    if case .object(let obj) = prevVal, case .int(let ts) = obj["attemptedAt"] {
                        prevAttempt = ts
                    } else {
                        prevAttempt = nil
                    }
                    let shouldRefresh: Bool
                    switch input.refresh {
                    case .never: shouldRefresh = false
                    case .force: shouldRefresh = true
                    case .daily: shouldRefresh = prevAttempt == nil || (now - prevAttempt!) >= Self.dailyIntervalMs
                    }

                    let status: Result.Status = !reuse ? .cloned : (shouldRefresh ? .refreshed : .cached)
                    if status != .cached {
                        try? await self.kv.set(key, value: .object(["attemptedAt": .int(now)]))
                        if status == .cloned {
                            do {
                                _ = try await self.git.clone(remote: input.reference.remote, directory: absLocal, branch: input.branch, depth: nil)
                            } catch {
                                throw CloneFailedError(repository: input.reference.label, message: String(describing: error))
                            }
                        } else if let existing {
                            do {
                                try await self.git.fetchRemotes(existing, prune: true)
                                if let b = input.branch {
                                    try await self.git.fetchBranch(existing, remote: "origin", branch: b, force: false)
                                }
                            } catch {
                                throw FetchFailedError(repository: input.reference.label, message: String(describing: error))
                            }
                            let targetBranch: String?
                            if let b = input.branch {
                                targetBranch = b
                            } else {
                                targetBranch = await self.git.defaultRemoteBranch(existing, remote: "origin")
                            }
                            if let b = targetBranch {
                                do {
                                    try await self.git.checkoutRemoteBranch(existing, remote: "origin", branch: b, reset: true)
                                } catch {
                                    throw CheckoutFailedError(repository: input.reference.label, branch: b, message: String(describing: error))
                                }
                            }
                            let resolvedBranch: String?
                            if let targetBranch {
                                resolvedBranch = targetBranch
                            } else {
                                resolvedBranch = await self.git.branch(existing)
                            }
                            let rev = resolvedBranch.map { "origin/\($0)" } ?? "HEAD"
                            do {
                                try await self.git.resetHard(existing, revision: rev)
                            } catch {
                                throw ResetFailedError(repository: input.reference.label, message: String(describing: error))
                            }
                        }
                    }

                    let checkout = await self.git.discover(absLocal)
                    let headSHA = checkout != nil ? await self.git.head(checkout!) : nil
                    let currentBranch = checkout != nil ? await self.git.branch(checkout!) : nil
                    return Result(
                        repository: input.reference.label,
                        host: input.reference.host,
                        remote: input.reference.remote,
                        localPath: localPath,
                        status: status,
                        head: headSHA,
                        branch: currentBranch
                    )
                }
            }
        }

        // parity: core/src/repository-cache.ts#node [status=implemented hash=01b42eb8b5ec]
        public static let node: LayerNode.Provider = AppNode.makeGlobalNode(
            Service.serviceKey,
            LayerNode.ExecutableLayer { deps, _ in
                let fs = deps.get(LayerNodePlatform.fileSystemKey, as: (any OpenCodeFileSystem).self) ?? LocalFileSystem.shared
                let git = deps.get(CoreVcs.Git.Service.serviceKey, as: CoreVcs.Git.Service.self) ?? CoreVcs.Git.Service()
                let kv = try deps.get(CoreKV.Service.serviceKey, as: CoreKV.Service.self) ?? CoreKV.Service.inMemory()
                return LayerNode.Output([Service.serviceKey: Service(fileSystem: fs, git: git, kv: kv)])
            },
            [LayerNodePlatform.filesystem, CoreVcs.Git.node, CoreKV.node]
        )
    }

    // MARK: - core/src/workspace/*

    public enum Workspace {
        // parity: core/src/workspace/sql.ts#WorkspaceTable [status=adapted hash=560aecfb2bde]
        public enum WorkspaceTable {
            public static let tableName = "workspace"
            public static let createTableSQL = """
                CREATE TABLE IF NOT EXISTS workspace (
                    id TEXT PRIMARY KEY,
                    provider TEXT NOT NULL,
                    binding TEXT,
                    created_at INTEGER NOT NULL,
                    last_used_at INTEGER NOT NULL
                );
                """
        }

        public enum Driver {
            // parity: core/src/workspace/driver.ts#Binding [status=implemented hash=33a5330bd53b]
            public typealias Binding = [String: JSONValue]

            // parity: core/src/workspace/driver.ts#Error [status=implemented hash=4b67f19c55fb]
            public struct DriverError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
                public static let tag = "WorkspaceDriver.Error"
                public let message: String?

                public init(message: String? = nil) {
                    self.message = message
                }

                public var description: String { message ?? "Workspace driver error" }
            }

            // parity: core/src/workspace/driver.ts#ProviderNotFound [status=implemented hash=809fb82e7e21]
            public struct ProviderNotFound: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
                public static let tag = "WorkspaceDriver.ProviderNotFound"
                public let provider: String

                public init(provider: String) {
                    self.provider = provider
                }

                public var description: String { "Workspace provider not found: \(provider)" }
            }

            // parity: core/src/workspace/driver.ts#Interface [status=implemented hash=e34538a03306]
            public protocol Interface: Sendable {
                func create(workspaceID: WorkspaceID) async throws -> Binding
                func connect(
                    workspaceID: WorkspaceID,
                    binding: Binding,
                    saveBinding: @escaping @Sendable (Binding) async throws -> Void
                ) async throws -> CoreLocation.Environment.Driver
                func suspendForIdle(
                    workspaceID: WorkspaceID,
                    binding: Binding,
                    saveBinding: @escaping @Sendable (Binding) async throws -> Void
                ) async throws
                func destroy(workspaceID: WorkspaceID, binding: Binding?) async throws
            }

            // parity: core/src/workspace/driver.ts#make [status=implemented hash=0af64152e5f3]
            public static func make(_ driver: any Interface) -> any Interface {
                driver
            }

            // parity: core/src/workspace/driver.ts#Registry [status=implemented hash=7d2342d62a15]
            public protocol Registry: Sendable {
                func get(_ provider: String) throws(ProviderNotFound) -> any Interface
            }

            // parity: core/src/workspace/driver.ts#RegistryService [status=implemented hash=c54f4d251080]
            public final class RegistryService: Registry, Sendable {
                public static let serviceKey = "@opencode/WorkspaceDriverRegistry"
                private let drivers: [String: any Interface]

                public init(_ drivers: [String: any Interface] = [:]) {
                    self.drivers = drivers
                }

                public func get(_ provider: String) throws(ProviderNotFound) -> any Interface {
                    guard let driver = drivers[provider] else {
                        throw ProviderNotFound(provider: provider)
                    }
                    return driver
                }
            }

            // parity: core/src/workspace/driver.ts#registry [status=implemented hash=552d443f1e0c]
            public static func registry(_ drivers: [String: any Interface]) -> RegistryService {
                RegistryService(drivers)
            }

            // parity: core/src/workspace/driver.ts#registryNode [status=implemented hash=f291dfcd9363]
            public static func registryNode(_ drivers: [String: any Interface]) -> LayerNode.Provider {
                AppNode.makeGlobalNode(
                    RegistryService.serviceKey,
                    LayerNode.ExecutableLayer.succeed(key: RegistryService.serviceKey, value: RegistryService(drivers)),
                    []
                )
            }

            // parity: core/src/workspace/driver.ts#node [status=implemented hash=cea941e1133e]
            public static let node: LayerNode.Provider = registryNode([:])
        }

        // parity: core/src/workspace.ts#ID [status=implemented hash=53d8ed3214a8]
        public typealias ID = WorkspaceSchema.ID

        // parity: core/src/workspace.ts#Info [status=implemented hash=44bfe5d01625]
        public struct Info: Equatable, Hashable, Sendable, Codable {
            public let id: ID
            public let provider: String
            public let binding: Driver.Binding
            public let createdAt: Int64
            public let lastUsedAt: Int64

            public init(id: ID, provider: String, binding: Driver.Binding, createdAt: Int64, lastUsedAt: Int64) {
                self.id = id
                self.provider = provider
                self.binding = binding
                self.createdAt = createdAt
                self.lastUsedAt = lastUsedAt
            }
        }

        // parity: core/src/workspace.ts#NotFound [status=implemented hash=8ec4032f9ea7]
        public struct NotFound: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "Workspace.NotFound"
            public let workspaceID: ID
            public init(workspaceID: ID) { self.workspaceID = workspaceID }
            public var description: String { "Workspace not found: \(workspaceID.rawValue)" }
        }

        // parity: core/src/workspace.ts#CreateConflict [status=implemented hash=d0945f8ea122]
        public struct CreateConflict: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "Workspace.CreateConflict"
            public let workspaceID: ID
            public let provider: String
            public let existingProvider: String

            public init(workspaceID: ID, provider: String, existingProvider: String) {
                self.workspaceID = workspaceID
                self.provider = provider
                self.existingProvider = existingProvider
            }

            public var description: String {
                "Workspace \(workspaceID.rawValue) already exists with provider '\(existingProvider)' (requested '\(provider)')"
            }
        }

        // parity: core/src/workspace.ts#Options [status=implemented hash=77bbcc65f6ff]
        public struct Options: Equatable, Hashable, Sendable {
            public let idleThresholdMs: Int64
            public let pollIntervalMs: Int64

            public init(idleThresholdMs: Int64 = 20 * 60 * 1_000, pollIntervalMs: Int64 = 60 * 1_000) {
                self.idleThresholdMs = idleThresholdMs
                self.pollIntervalMs = pollIntervalMs
            }
        }

        // parity: core/src/workspace.ts#Interface [status=implemented hash=985bff14ce29]
        public protocol Interface: Sendable {
            func create(id: ID?, provider: String) async throws -> ID
            func provision(_ workspaceID: ID) async throws -> Info
            func connect(_ workspaceID: ID) async throws -> CoreLocation.Environment.Driver
            func destroy(_ workspaceID: ID) async throws -> WorkspaceSchema.DestroyResult
        }

        // parity: core/src/workspace.ts#Service [status=implemented hash=510fefa8226b]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/Workspace"
            private let db: any SQLiteDatabase
            private let registry: any Driver.Registry
            private let locks = CoreSubsystems.Effect.KeyedMutex<ID>()
            private let activeConnections = Mutex<[ID: CoreLocation.Environment.Driver]>([:])

            public init(database: any SQLiteDatabase, registry: any Driver.Registry) throws {
                self.db = database
                self.registry = registry
                try database.executeScript(WorkspaceTable.createTableSQL)
            }

            public func create(id: ID? = nil, provider: String) async throws -> ID {
                let workspaceID = id ?? WorkspaceID.create()
                if let row = try db.queryOne("SELECT provider FROM workspace WHERE id = ?", parameters: [.text(workspaceID.rawValue)]),
                   let existingProvider = row.string("provider") {
                    if existingProvider == provider { return workspaceID }
                    throw CreateConflict(workspaceID: workspaceID, provider: provider, existingProvider: existingProvider)
                }
                _ = try registry.get(provider)
                let now = Flock.currentEpochMs()
                _ = try db.execute(
                    "INSERT INTO workspace (id, provider, binding, created_at, last_used_at) VALUES (?, ?, NULL, ?, ?)",
                    parameters: [.text(workspaceID.rawValue), .text(provider), .integer(now), .integer(now)]
                )
                return workspaceID
            }

            public func provision(_ workspaceID: ID) async throws -> Info {
                try await locks.withLock(workspaceID) { [self] in
                    guard let row = try self.db.queryOne("SELECT * FROM workspace WHERE id = ?", parameters: [.text(workspaceID.rawValue)]),
                          let provider = row.string("provider"),
                          let createdAt = row.int64("created_at"),
                          let lastUsedAt = row.int64("last_used_at")
                    else {
                        throw NotFound(workspaceID: workspaceID)
                    }
                    if let rawBinding = row.string("binding"),
                       let decoded = try? JSONDecoder().decode(Driver.Binding.self, from: Data(rawBinding.utf8)) {
                        return Info(id: workspaceID, provider: provider, binding: decoded, createdAt: createdAt, lastUsedAt: lastUsedAt)
                    }
                    let driver = try self.registry.get(provider)
                    let binding = try await driver.create(workspaceID: workspaceID)
                    let encoded = String(decoding: try JSONEncoder().encode(binding), as: UTF8.self)
                    _ = try self.db.execute(
                        "UPDATE workspace SET binding = ? WHERE id = ?",
                        parameters: [.text(encoded), .text(workspaceID.rawValue)]
                    )
                    return Info(id: workspaceID, provider: provider, binding: binding, createdAt: createdAt, lastUsedAt: lastUsedAt)
                }
            }

            public func connect(_ workspaceID: ID) async throws -> CoreLocation.Environment.Driver {
                if let existing = activeConnections.withLock({ $0[workspaceID] }) {
                    return existing
                }
                let info = try await provision(workspaceID)
                let driver = try registry.get(info.provider)
                let envDriver = try await driver.connect(workspaceID: workspaceID, binding: info.binding) { [self] nextBinding in
                    let encoded = String(decoding: try JSONEncoder().encode(nextBinding), as: UTF8.self)
                    _ = try self.db.execute(
                        "UPDATE workspace SET binding = ? WHERE id = ?",
                        parameters: [.text(encoded), .text(workspaceID.rawValue)]
                    )
                }
                activeConnections.withLock { $0[workspaceID] = envDriver }
                _ = try db.execute(
                    "UPDATE workspace SET last_used_at = ? WHERE id = ?",
                    parameters: [.integer(Flock.currentEpochMs()), .text(workspaceID.rawValue)]
                )
                return envDriver
            }

            public func destroy(_ workspaceID: ID) async throws -> WorkspaceSchema.DestroyResult {
                try await locks.withLock(workspaceID) { [self] in
                    guard let row = try self.db.queryOne("SELECT provider, binding FROM workspace WHERE id = ?", parameters: [.text(workspaceID.rawValue)]),
                          let provider = row.string("provider")
                    else {
                        return WorkspaceSchema.DestroyResult(destroyed: false)
                    }
                    let binding: Driver.Binding? = row.string("binding").flatMap {
                        try? JSONDecoder().decode(Driver.Binding.self, from: Data($0.utf8))
                    }
                    let driver = try self.registry.get(provider)
                    try await driver.destroy(workspaceID: workspaceID, binding: binding)
                    self.activeConnections.withLock { _ = $0.removeValue(forKey: workspaceID) }
                    _ = try self.db.execute("DELETE FROM workspace WHERE id = ?", parameters: [.text(workspaceID.rawValue)])
                    return WorkspaceSchema.DestroyResult(destroyed: true)
                }
            }
        }

        // parity: core/src/workspace.ts#configured [status=implemented hash=165313b0a8b6]
        public static func configured(_ options: Options = Options()) -> LayerNode.Provider {
            _ = options
            return AppNode.makeGlobalNode(
                Service.serviceKey,
                LayerNode.ExecutableLayer { deps, _ in
                    let reg = deps.get(Driver.RegistryService.serviceKey, as: Driver.RegistryService.self) ?? Driver.RegistryService()
                    let db = try SQLiteDatabaseFactory.open(path: ":memory:")
                    return LayerNode.Output([Service.serviceKey: try Service(database: db, registry: reg)])
                },
                [Driver.node]
            )
        }

        // parity: core/src/workspace.ts#node [status=implemented hash=aea3814ebc3b]
        public static let node: LayerNode.Provider = configured()
    }
}

// MARK: - CoreWorktree (`worktree.ts`, `worktree/*`)

public enum CoreWorktree {
    // MARK: - core/src/worktree/sql.ts

    public enum SQL {
        // parity: core/src/worktree/sql.ts#WorktreeTable [status=adapted hash=df061a3d41d3]
        public enum WorktreeTable {
            public static let tableName = "worktree"
            public static let createTableSQL = """
                CREATE TABLE IF NOT EXISTS worktree (
                    project_id TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
                    directory TEXT NOT NULL,
                    strategy TEXT,
                    time_created INTEGER NOT NULL,
                    PRIMARY KEY (project_id, directory)
                );
                """
        }
    }

    // MARK: - core/src/worktree/directory.ts

    public enum Directory {
        // parity: core/src/worktree/directory.ts#DirectoryUnavailableError [status=implemented hash=f52cf757e43e]
        public struct DirectoryUnavailableError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "Worktree.DirectoryUnavailableError"
            public let directory: SchemaPrimitive.AbsolutePath

            public init(directory: SchemaPrimitive.AbsolutePath) {
                self.directory = directory
            }

            public var description: String { "Worktree directory unavailable: \(directory.rawValue)" }
        }

        // parity: core/src/worktree/directory.ts#canonical [status=implemented hash=5b4a3815c22c]
        public static func canonical(
            fileSystem: any OpenCodeFileSystem,
            input: SchemaPrimitive.AbsolutePath
        ) async throws -> SchemaPrimitive.AbsolutePath {
            let resolved = (try? await fileSystem.realPath(at: input.rawValue)) ?? input.rawValue
            guard let stat = try? await fileSystem.stat(at: resolved), stat.type == .directory else {
                throw DirectoryUnavailableError(directory: input)
            }
            return SchemaPrimitive.AbsolutePath(rawValue: resolved)
        }
    }

    // MARK: - core/src/worktree/strategies.ts & core/src/worktree/git.ts

    public enum Strategies {
        // parity: core/src/worktree/strategies.ts#Strategy [status=implemented hash=6fdb74388c5c]
        public struct Strategy: Sendable {
            public let id: WorktreeSchema.StrategyID
            public let create: @Sendable (
                _ sourceDirectory: SchemaPrimitive.AbsolutePath,
                _ directory: SchemaPrimitive.AbsolutePath,
                _ branch: String?
            ) async throws -> WorktreeSchema.Info
            public let remove: @Sendable (_ directory: SchemaPrimitive.AbsolutePath, _ force: Bool) async throws -> Void
            public let list: @Sendable (_ directory: SchemaPrimitive.AbsolutePath) async throws -> [WorktreeSchema.ListEntry]

            public init(
                id: WorktreeSchema.StrategyID,
                create: @escaping @Sendable (SchemaPrimitive.AbsolutePath, SchemaPrimitive.AbsolutePath, String?) async throws -> WorktreeSchema.Info,
                remove: @escaping @Sendable (SchemaPrimitive.AbsolutePath, Bool) async throws -> Void,
                list: @escaping @Sendable (SchemaPrimitive.AbsolutePath) async throws -> [WorktreeSchema.ListEntry]
            ) {
                self.id = id
                self.create = create
                self.remove = remove
                self.list = list
            }
        }

        public struct SettingsSnapshot: Sendable {
            public var directory: SchemaPrimitive.AbsolutePath
            public var strategies: [WorktreeSchema.StrategyID: Strategy]
            public var selected: WorktreeSchema.StrategyID

            public init(
                directory: SchemaPrimitive.AbsolutePath,
                strategies: [WorktreeSchema.StrategyID: Strategy],
                selected: WorktreeSchema.StrategyID
            ) {
                self.directory = directory
                self.strategies = strategies
                self.selected = selected
            }
        }

        // parity: core/src/worktree/strategies.ts#Editor [status=implemented hash=50eda3512316]
        public final class Editor: @unchecked Sendable {
            internal var snapshot: SettingsSnapshot

            internal init(snapshot: SettingsSnapshot) {
                self.snapshot = snapshot
            }

            public func configure(directory: SchemaPrimitive.AbsolutePath) {
                snapshot.directory = directory
            }

            public func add(_ strategy: Strategy) {
                snapshot.strategies[strategy.id] = strategy
                snapshot.selected = strategy.id
            }
        }

        // parity: core/src/worktree/strategies.ts#Interface [status=implemented hash=3561ebfcc997]
        public protocol Interface: CoreState.Transformable where Editor == Strategies.Editor {
            var directory: SchemaPrimitive.AbsolutePath { get }
            func get() -> SettingsSnapshot
        }

        // parity: core/src/worktree/strategies.ts#Service [status=implemented hash=9756189938bd]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/WorktreeStrategies"
            public let directory: SchemaPrimitive.AbsolutePath
            private let state: CoreState.Store<SettingsSnapshot, Editor>

            public init(
                locationDirectory: SchemaPrimitive.AbsolutePath,
                defaultWorktreeRoot: SchemaPrimitive.AbsolutePath,
                gitStrategy: Strategy
            ) {
                self.directory = locationDirectory
                self.state = CoreState.create(CoreState.Options(
                    name: "worktree",
                    initial: {
                        SettingsSnapshot(
                            directory: defaultWorktreeRoot,
                            strategies: [gitStrategy.id: gitStrategy],
                            selected: gitStrategy.id
                        )
                    },
                    makeEditor: { Editor(snapshot: $0) },
                    commitEditor: { $0.snapshot }
                ))
            }

            @discardableResult
            public func transform(_ update: @escaping @Sendable (Editor) throws -> Void) async throws -> CoreState.Registration {
                try await state.transform(update)
            }

            public func reload() async {
                await state.reload()
            }

            public func get() -> SettingsSnapshot {
                state.get()
            }
        }

        // parity: core/src/worktree/strategies.ts#node [status=implemented hash=e71b60d8ba2d]
        public static let node: LayerNode.Provider = AppNode.makeLocationNode(
            Service.serviceKey,
            LayerNode.ExecutableLayer { deps, _ in
                let loc = deps.get(CoreLocation.Location.Service.serviceKey, as: CoreLocation.Location.Service.self)
                let fs = deps.get(LayerNodePlatform.fileSystemKey, as: (any OpenCodeFileSystem).self) ?? LocalFileSystem.shared
                let git = deps.get(CoreVcs.Git.Service.serviceKey, as: CoreVcs.Git.Service.self) ?? CoreVcs.Git.Service()
                let projPrefix = String((loc?.info.project.id.rawValue ?? "global").prefix(6))
                let root = SchemaPrimitive.AbsolutePath(rawValue: "\(GlobalPaths.roots().data)/worktree/\(projPrefix)")
                let svc = Service(
                    locationDirectory: loc?.info.directory ?? SchemaPrimitive.AbsolutePath(rawValue: "/"),
                    defaultWorktreeRoot: root,
                    gitStrategy: GitStrategy.make(fileSystem: fs, git: git)
                )
                return LayerNode.Output([Service.serviceKey: svc])
            },
            [CoreLocation.Location.node, CoreVcs.Git.node, LayerNodePlatform.filesystem]
        )
    }

    public enum GitStrategy {
        // parity: core/src/worktree/git.ts#make [status=implemented hash=df7f44e4b735]
        public static func make(
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
            git: any CoreVcs.Git.Interface = CoreVcs.Git.Service()
        ) -> Strategies.Strategy {
            Strategies.Strategy(
                id: WorktreeSchema.StrategyID(rawValue: "git")!,
                create: { sourceDirectory, directory, branch in
                    guard let repo = await git.discover(sourceDirectory) else {
                        throw Directory.DirectoryUnavailableError(directory: sourceDirectory)
                    }
                    _ = try await git.worktreeCreate(repository: repo, directory: directory, ref: branch)
                    let resolved = try await Directory.canonical(fileSystem: fileSystem, input: directory)
                    return WorktreeSchema.Info(directory: resolved)
                },
                remove: { directory, force in
                    guard let repo = await git.discover(directory) else {
                        throw Directory.DirectoryUnavailableError(directory: directory)
                    }
                    try await git.worktreeRemove(repository: repo, directory: directory, force: force)
                },
                list: { directory in
                    guard let repo = await git.discover(directory) else {
                        throw Directory.DirectoryUnavailableError(directory: directory)
                    }
                    let entries = try await git.worktreeList(repo)
                    var out: [WorktreeSchema.ListEntry] = []
                    for entry in entries {
                        if let resolved = try? await Directory.canonical(fileSystem: fileSystem, input: entry.directory) {
                            out.append(WorktreeSchema.ListEntry(
                                directory: resolved,
                                type: entry.kind == .main ? .root : .worktree
                            ))
                        }
                    }
                    return out
                }
            )
        }
    }

    // MARK: - core/src/worktree.ts

    // parity: core/src/worktree.ts#StrategyID [status=implemented hash=8ba3c9a3e71e]
    public typealias StrategyID = WorktreeSchema.StrategyID

    // parity: core/src/worktree.ts#CreateInput [status=implemented hash=dd15ebda1895]
    public typealias CreateInput = WorktreeSchema.CreateInput

    // parity: core/src/worktree.ts#RemoveInput [status=implemented hash=c4fd97d582fa]
    public typealias RemoveInput = WorktreeSchema.RemoveInput

    // parity: core/src/worktree.ts#Info [status=implemented hash=ee1972167649]
    public typealias Info = WorktreeSchema.Info

    // parity: core/src/worktree.ts#List [status=implemented hash=97a748591c1f]
    public typealias List = WorktreeSchema.List

    // parity: core/src/worktree.ts#ListEntry [status=implemented hash=24e299df561c]
    public typealias ListEntry = WorktreeSchema.ListEntry

    // parity: core/src/worktree.ts#Event [status=implemented hash=6469c9b747d3]
    public typealias Event = WorktreeSchema.Event

    // parity: core/src/worktree.ts#SourceDirectoryNotFoundError [status=implemented hash=a1ddde23d17a]
    public struct SourceDirectoryNotFoundError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "Worktree.SourceDirectoryNotFoundError"
        public let projectID: ProjectID
        public let directory: SchemaPrimitive.AbsolutePath?
        public init(projectID: ProjectID, directory: SchemaPrimitive.AbsolutePath? = nil) {
            self.projectID = projectID; self.directory = directory
        }
        public var description: String { "Worktree source directory not found for project \(projectID.rawValue)" }
    }

    // parity: core/src/worktree.ts#DestinationExistsError [status=implemented hash=3bfb30fe56a8]
    public struct DestinationExistsError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "Worktree.DestinationExistsError"
        public let directory: SchemaPrimitive.AbsolutePath
        public init(directory: SchemaPrimitive.AbsolutePath) { self.directory = directory }
        public var description: String { "Worktree destination already exists: \(directory.rawValue)" }
    }

    // parity: core/src/worktree.ts#InvalidDirectoryError [status=implemented hash=7d6e302ac8cc]
    public struct InvalidDirectoryError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "Worktree.InvalidDirectoryError"
        public let directory: SchemaPrimitive.AbsolutePath
        public init(directory: SchemaPrimitive.AbsolutePath) { self.directory = directory }
        public var description: String { "Invalid worktree directory: \(directory.rawValue)" }
    }

    // parity: core/src/worktree.ts#StrategyUnavailableError [status=implemented hash=2ac50a4b66c6]
    public struct StrategyUnavailableError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "Worktree.StrategyUnavailableError"
        public let strategy: StrategyID
        public init(strategy: StrategyID) { self.strategy = strategy }
        public var description: String { "Worktree strategy unavailable: \(strategy.rawValue)" }
    }

    // parity: core/src/worktree.ts#Error [status=implemented hash=6eddfe8c5337]
    public enum WorktreeError: Swift.Error, Equatable, Hashable, Sendable {
        case projectNotFound(CoreProject.Project.NotFoundError)
        case sourceDirectoryNotFound(SourceDirectoryNotFoundError)
        case destinationExists(DestinationExistsError)
        case directoryUnavailable(Directory.DirectoryUnavailableError)
        case invalidDirectory(InvalidDirectoryError)
        case strategyUnavailable(StrategyUnavailableError)
        case operation(WorktreeSchema.OperationError)
    }

    // parity: core/src/worktree.ts#Interface [status=implemented hash=2df85ea94ae7]
    public protocol Interface: Sendable {
        func list(projectID: ProjectID) async throws -> List
        func create(_ input: CreateInput, strategies: (any Strategies.Interface)?) async throws -> Info
        func remove(_ input: RemoveInput, strategies: (any Strategies.Interface)?) async throws
        func refresh(projectID: ProjectID, strategies: (any Strategies.Interface)?) async throws
    }

    // parity: core/src/worktree.ts#Service [status=implemented hash=fdcfe425501d]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/Worktree"
        private let db: any SQLiteDatabase
        private let fileSystem: any OpenCodeFileSystem
        private let defaultStrategies: (any Strategies.Interface)?

        public init(
            database: any SQLiteDatabase,
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
            defaultStrategies: (any Strategies.Interface)? = nil
        ) throws {
            self.db = database
            self.fileSystem = fileSystem
            self.defaultStrategies = defaultStrategies
            try database.executeScript(CoreProject.SQL.ProjectTable.createTableSQL)
            try database.executeScript(SQL.WorktreeTable.createTableSQL)
        }

        public func registerRoot(projectID: ProjectID, directory: SchemaPrimitive.AbsolutePath, strategy: StrategyID? = nil) throws {
            let now = Flock.currentEpochMs()
            _ = try db.execute(
                "INSERT OR IGNORE INTO worktree (project_id, directory, strategy, time_created) VALUES (?, ?, ?, ?)",
                parameters: [
                    .text(projectID.rawValue),
                    .text(directory.rawValue),
                    strategy.map { .text($0.rawValue) } ?? .null,
                    .integer(now),
                ]
            )
        }

        public func list(projectID: ProjectID) async throws -> List {
            guard try db.queryOne("SELECT id FROM project WHERE id = ?", parameters: [.text(projectID.rawValue)]) != nil else {
                throw CoreProject.Project.NotFoundError(projectID: projectID)
            }
            let rows = try db.query(
                "SELECT directory, strategy FROM worktree WHERE project_id = ? ORDER BY time_created DESC, directory ASC",
                parameters: [.text(projectID.rawValue)]
            )
            return rows.compactMap { row in
                guard let dir = row.string("directory") else { return nil }
                return WorktreeSchema.Directory(
                    directory: SchemaPrimitive.AbsolutePath(rawValue: dir),
                    strategy: row.string("strategy")
                )
            }
        }

        public func create(_ input: CreateInput, strategies: (any Strategies.Interface)? = nil) async throws -> Info {
            guard let projRow = try db.queryOne("SELECT worktree FROM project WHERE id = ?", parameters: [.text(input.projectID.rawValue)]),
                  let projRoot = projRow.string("worktree")
            else {
                throw CoreProject.Project.NotFoundError(projectID: input.projectID)
            }
            guard let stratService = strategies ?? defaultStrategies else {
                throw StrategyUnavailableError(strategy: StrategyID(rawValue: "git")!)
            }
            let settings = stratService.get()
            guard let selected = settings.strategies[settings.selected] else {
                throw StrategyUnavailableError(strategy: settings.selected)
            }
            let targetParent = input.directory ?? settings.directory
            let rawSource = input.from ?? SchemaPrimitive.AbsolutePath(rawValue: projRoot)
            let sourceDir = try await Directory.canonical(fileSystem: fileSystem, input: rawSource)
            try await fileSystem.makeDirectory(at: targetParent.rawValue, recursive: true)

            let baseName = input.name ?? CoreSubsystems.Util.Slug.create()
            var candidate = SchemaPrimitive.AbsolutePath(rawValue: "\(targetParent.rawValue)/\(baseName)")
            var suffix = 1
            while await fileSystem.exists(at: candidate.rawValue) {
                suffix += 1
                if suffix > 10 {
                    throw DestinationExistsError(directory: candidate)
                }
                candidate = SchemaPrimitive.AbsolutePath(rawValue: "\(targetParent.rawValue)/\(baseName)-\(suffix)")
            }

            let created = try await selected.create(sourceDir, candidate, input.branch)
            let canonicalCreated = try await Directory.canonical(fileSystem: fileSystem, input: created.directory)
            try registerRoot(projectID: input.projectID, directory: canonicalCreated, strategy: selected.id)
            return Info(directory: canonicalCreated)
        }

        public func remove(_ input: RemoveInput, strategies: (any Strategies.Interface)? = nil) async throws {
            guard let projRow = try db.queryOne("SELECT worktree FROM project WHERE id = ?", parameters: [.text(input.projectID.rawValue)]),
                  let projRoot = projRow.string("worktree")
            else {
                throw CoreProject.Project.NotFoundError(projectID: input.projectID)
            }
            let resolved = (try? await fileSystem.realPath(at: input.directory.rawValue)) ?? input.directory.rawValue
            if resolved == projRoot {
                throw InvalidDirectoryError(directory: input.directory)
            }
            if let row = try db.queryOne(
                "SELECT strategy FROM worktree WHERE project_id = ? AND directory = ?",
                parameters: [.text(input.projectID.rawValue), .text(resolved)]
            ), let stratName = row.string("strategy"),
               let stratID = StrategyID(rawValue: stratName),
               let strat = (strategies ?? defaultStrategies)?.get().strategies[stratID] {
                try await strat.remove(SchemaPrimitive.AbsolutePath(rawValue: resolved), input.force)
            }
            _ = try db.execute(
                "DELETE FROM worktree WHERE project_id = ? AND directory = ?",
                parameters: [.text(input.projectID.rawValue), .text(resolved)]
            )
        }

        public func refresh(projectID: ProjectID, strategies: (any Strategies.Interface)? = nil) async throws {
            guard let projRow = try db.queryOne("SELECT worktree FROM project WHERE id = ?", parameters: [.text(projectID.rawValue)]),
                  let projRoot = projRow.string("worktree")
            else {
                throw CoreProject.Project.NotFoundError(projectID: projectID)
            }
            guard let stratService = strategies ?? defaultStrategies else { return }
            let settings = stratService.get()
            for (stratID, strat) in settings.strategies {
                let discovered = (try? await strat.list(SchemaPrimitive.AbsolutePath(rawValue: projRoot))) ?? []
                for entry in discovered {
                    try registerRoot(projectID: projectID, directory: entry.directory, strategy: entry.type == .worktree ? stratID : nil)
                }
            }
        }
    }

    // parity: core/src/worktree.ts#node [status=implemented hash=fd8029feb3e0]
    public static let node: LayerNode.Provider = AppNode.makeGlobalNode(
        Service.serviceKey,
        LayerNode.ExecutableLayer { deps, _ in
            let fs = deps.get(LayerNodePlatform.fileSystemKey, as: (any OpenCodeFileSystem).self) ?? LocalFileSystem.shared
            let db = try SQLiteDatabaseFactory.open(path: ":memory:")
            return LayerNode.Output([Service.serviceKey: try Service(database: db, fileSystem: fs)])
        },
        [LayerNodePlatform.filesystem]
    )
}
