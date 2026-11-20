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
#endif
import OpenCodeUtil

/// Cross-platform filesystem utility service matching `packages/util/src/fs-util.ts`.
// parity: util/src/fs-util.ts#FSUtil [status=implemented hash=61971a01513d]
public enum FSUtil {
    // parity: util/src/fs-util.ts#FSUtil.Error [status=implemented hash=cbb8b70433d4]
    public enum FSError: Error, Equatable, Sendable, CustomStringConvertible {
        case platform(PlatformError)
        case fileSystem(FSPathUtil.FileSystemError)

        public var description: String {
            switch self {
            case .platform(let e): return e.description
            case .fileSystem(let e): return e.description
            }
        }
    }

    // parity: util/src/fs-util.ts#FSUtil.Interface [status=implemented hash=9579fa9115f3]
    public protocol Interface: Sendable {
        var fileSystem: any OpenCodeFileSystem { get }
        func isDir(_ path: String) async -> Bool
        func isFile(_ path: String) async -> Bool
        func existsSafe(_ path: String) async -> Bool
        func readFileStringSafe(_ path: String) async throws -> String?
        func readJson(_ path: String) async throws -> PureJSONValue
        func writeJson(_ path: String, data: PureJSONValue, mode: UInt16?) async throws
        func ensureDir(_ path: String) async throws
        func writeWithDirs(_ path: String, content: [UInt8], mode: UInt16?) async throws
        func resolve(_ path: String) async -> String
        func findUp(target: String, start: String, stop: String?) async throws -> [String]
        func up(_ options: FSPathUtil.UpOptions) async throws -> [String]
        func globUp(pattern: String, start: String, stop: String?) async throws -> [String]
        func scan(pattern: String, options: Glob.Options) async throws -> [String]
        func globMatch(pattern: String, filepath: String) -> Bool
    }

    // parity: util/src/fs-util.ts#FSUtil.Service [status=implemented hash=2fa19bd318ca]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/FSUtil"
        public let fileSystem: any OpenCodeFileSystem

        public init(fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared) {
            self.fileSystem = fileSystem
        }

        public func isDir(_ path: String) async -> Bool {
            guard let info = try? await fileSystem.stat(at: path) else { return false }
            return info.type == .directory
        }

        public func isFile(_ path: String) async -> Bool {
            guard let info = try? await fileSystem.stat(at: path) else { return false }
            return info.type == .file
        }

        public func existsSafe(_ path: String) async -> Bool {
            await fileSystem.exists(at: path)
        }

        public func readFileStringSafe(_ path: String) async throws -> String? {
            do {
                let bytes = try await fileSystem.readFile(at: path)
                return String(decoding: bytes, as: UTF8.self)
            } catch let err as PlatformError {
                if case .notFound = err { return nil }
                if FSUtil.isAccessDenied(err) { return nil }
                throw FSError.platform(err)
            }
        }

        public func readJson(_ path: String) async throws -> PureJSONValue {
            let bytes = try await fileSystem.readFile(at: path)
            let text = String(decoding: bytes, as: UTF8.self)
            guard let parsed = PureJSON.parse(text) else {
                throw FSError.fileSystem(FSPathUtil.FileSystemError(method: "readJson", detail: "Invalid JSON at \(path)"))
            }
            return parsed
        }

        public func writeJson(_ path: String, data: PureJSONValue, mode: UInt16? = nil) async throws {
            let text = PureJSON.stringifyPretty(data, indent: 2)
            try await fileSystem.writeFile(Array(text.utf8), to: path, createDirectories: false)
            if let mode {
                try await fileSystem.chmod(at: path, mode: mode)
            }
        }

        public func ensureDir(_ path: String) async throws {
            do {
                try await fileSystem.makeDirectory(at: path, recursive: true)
            } catch let err as PlatformError {
                if case .alreadyExists = err, await isDir(path) {
                    return
                }
                throw FSError.platform(err)
            }
        }

        public func writeWithDirs(_ path: String, content: [UInt8], mode: UInt16? = nil) async throws {
            try await fileSystem.writeFile(content, to: path, createDirectories: true)
            if let mode {
                try await fileSystem.chmod(at: path, mode: mode)
            }
        }

        public func resolve(_ input: String) async -> String {
            let normalized = FSPathUtil.windowsPath(input)
            let resolved = Self.resolveAbsolute(normalized)
            do {
                let real = try await fileSystem.realPath(at: resolved)
                #if os(Windows)
                if real.lowercased() == resolved.lowercased() { return resolved }
                #endif
                return real
            } catch {
                return resolved
            }
        }

        public func findUp(target: String, start: String, stop: String? = nil) async throws -> [String] {
            try await up(FSPathUtil.UpOptions(targets: [target], start: start, stop: stop))
        }

        public func up(_ options: FSPathUtil.UpOptions) async throws -> [String] {
            var result: [String] = []
            var current = options.start
            while true {
                for target in options.targets {
                    let search = Self.joinPath(current, target)
                    let found: Bool
                    switch options.type {
                    case .file: found = await isFile(search)
                    case .directory: found = await isDir(search)
                    case nil: found = await fileSystem.exists(at: search)
                    }
                    if found {
                        result.append(search)
                        if options.mode == .first { return result }
                    }
                }
                if let stop = options.stop, sameDirectory(stop, current) { break }
                let parent = Self.dirname(current)
                if parent == current { break }
                current = parent
            }
            return result
        }

        public func globUp(pattern: String, start: String, stop: String? = nil) async throws -> [String] {
            var result: [String] = []
            var current = start
            while true {
                let opts = Glob.Options(cwd: current, absolute: true, include: .file, dot: true)
                let matches = (try? await scan(pattern: pattern, options: opts)) ?? []
                result.append(contentsOf: matches)
                if let stop, sameDirectory(stop, current) { break }
                let parent = Self.dirname(current)
                if parent == current { break }
                current = parent
            }
            return result
        }

        public func scan(pattern: String, options: Glob.Options = Glob.Options()) async throws -> [String] {
            let fs = self.fileSystem
            return try await Glob.scan(pattern, options: options) { opts in
                let root = opts.cwd ?? "/"
                var collected: [GlobFileEntry] = []
                try await Self.walkDirectory(fs: fs, root: root, relative: "", into: &collected)
                return collected
            }
        }

        public func globMatch(pattern: String, filepath: String) -> Bool {
            Glob.match(pattern, filepath: filepath)
        }

        private static func walkDirectory(
            fs: any OpenCodeFileSystem,
            root: String,
            relative: String,
            into results: inout [GlobFileEntry]
        ) async throws {
            let dir = relative.isEmpty ? root : joinPath(root, relative)
            guard let names = try? await fs.readDirectory(at: dir) else { return }
            for name in names.sorted() {
                let rel = relative.isEmpty ? name : "\(relative)/\(name)"
                let abs = joinPath(root, rel)
                let isDirectory = (try? await fs.stat(at: abs).type) == .directory
                results.append(GlobFileEntry(relativePath: rel, absolutePath: abs, isDirectory: isDirectory))
                if isDirectory {
                    try await walkDirectory(fs: fs, root: root, relative: rel, into: &results)
                }
            }
        }

        private static func joinPath(_ base: String, _ child: String) -> String {
            if base == "/" { return "/\(child)" }
            if base.hasSuffix("/") { return base + child }
            return "\(base)/\(child)"
        }

        private static func dirname(_ path: String) -> String {
            var p = path
            while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
            guard let slash = p.lastIndex(of: "/") else { return "." }
            if slash == p.startIndex { return "/" }
            return String(p[..<slash])
        }

        private static func resolveAbsolute(_ p: String) -> String {
            if p.hasPrefix("/") { return p }
            #if os(WASI)
            return "/" + p
            #else
            return URL(fileURLWithPath: p).standardizedFileURL.path
            #endif
        }
    }

    // parity: util/src/fs-util.ts#FSUtil.layer [status=implemented hash=8dda177497c9]
    public static let layer: LayerNode.ExecutableLayer = LayerNode.ExecutableLayer { deps, _ in
        let fs = deps.get(LayerNodePlatform.fileSystemKey, as: (any OpenCodeFileSystem).self) ?? LocalFileSystem.shared
        return LayerNode.Output([Service.serviceKey: Service(fileSystem: fs)])
    }

    // parity: util/src/fs-util.ts#FSUtil.node [status=implemented hash=e7d952e0cec6]
    public static let node: LayerNode.Provider = AppNode.makeGlobalNode(
        Service.serviceKey,
        layer,
        [LayerNodePlatform.filesystem]
    )

    /// Permission denial, including macOS sandbox/privacy denials surfacing as `EPERM`.
    // parity: util/src/fs-util.ts#FSUtil.isAccessDenied [status=implemented hash=40bd0772ef86]
    public static func isAccessDenied(_ error: PlatformError) -> Bool {
        switch error {
        case .permissionDenied:
            return true
        case .ioFailure(_, let code):
            return code == "EPERM" || code == "EACCES"
        default:
            return false
        }
    }

    // parity: util/src/fs-util.ts#FSUtil.normalizePath [status=implemented hash=eb634425e254]
    public static func normalizePath(_ p: String) -> String {
        #if os(Windows)
        return resolve(p)
        #else
        return p
        #endif
    }

    // parity: util/src/fs-util.ts#FSUtil.resolve [status=implemented hash=9a54ef883ce7]
    public static func resolve(_ p: String) -> String {
        let win = FSPathUtil.windowsPath(p)
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        if let real = realpath(win, nil) {
            defer { free(real) }
            return normalizePath(String(cString: real))
        }
        return normalizePath(URL(fileURLWithPath: win).standardizedFileURL.path)
        #elseif os(WASI)
        return win
        #else
        return normalizePath(URL(fileURLWithPath: win).standardizedFileURL.path)
        #endif
    }
}
