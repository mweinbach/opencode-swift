#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

// MARK: - CoreRipgrep (`core/src/ripgrep.ts` & `core/src/ripgrep/binary.ts`)

public enum CoreRipgrep {
    private static let maxSubmatches = 100
    private static let maxLineChars = 2_000

    // parity: core/src/ripgrep.ts#Error [status=implemented hash=354a201c0361]
    public struct RipgrepError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public static let tag = "Ripgrep.Error"
        public let message: String
        public let cause: String?

        public init(message: String, cause: String? = nil) {
            self.message = message
            self.cause = cause
        }

        public var description: String { message }
    }

    // parity: core/src/ripgrep.ts#InvalidGlobError [status=implemented hash=5bc259cc7f85]
    public struct InvalidGlobError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public static let tag = "Ripgrep.InvalidGlobError"
        public let message: String

        public init(message: String) {
            self.message = message
        }

        public var description: String { message }
    }

    // parity: core/src/ripgrep.ts#InvalidPatternError [status=implemented hash=6ad1d679af75]
    public struct InvalidPatternError: Swift.Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        public static let tag = "Ripgrep.InvalidPatternError"
        public let pattern: String
        public let message: String

        public init(pattern: String, message: String) {
            self.pattern = pattern
            self.message = message
        }

        public var description: String { message }
    }

    // parity: core/src/ripgrep.ts#FindInput [status=implemented hash=d396a41012ec]
    public struct FindInput: Sendable {
        /// Where `cwd` lives, and so where the search runs.
        public let environment: any CoreLocation.Environment.Interface
        public let cwd: String
        public let pattern: String
        public let limit: Int
        public let exclude: [String]?
        public let hidden: Bool?
        public let follow: Bool?
        public let signal: AbortSignal?
        public let onEntry: (@Sendable (FileSystemSchema.Entry) async -> Void)?

        public init(
            environment: any CoreLocation.Environment.Interface = CoreLocation.Environment.host,
            cwd: String,
            pattern: String,
            limit: Int,
            exclude: [String]? = nil,
            hidden: Bool? = nil,
            follow: Bool? = nil,
            signal: AbortSignal? = nil,
            onEntry: (@Sendable (FileSystemSchema.Entry) async -> Void)? = nil
        ) {
            self.environment = environment
            self.cwd = cwd
            self.pattern = pattern
            self.limit = limit
            self.exclude = exclude
            self.hidden = hidden
            self.follow = follow
            self.signal = signal
            self.onEntry = onEntry
        }
    }

    // parity: core/src/ripgrep.ts#GlobInput [status=implemented hash=27a7783d8133]
    public struct GlobInput: Sendable {
        /// Where `cwd` lives, and so where the search runs.
        public let environment: any CoreLocation.Environment.Interface
        public let cwd: String
        public let pattern: String
        public let limit: Int
        public let hidden: Bool?
        public let follow: Bool?
        public let signal: AbortSignal?

        public init(
            environment: any CoreLocation.Environment.Interface = CoreLocation.Environment.host,
            cwd: String,
            pattern: String,
            limit: Int,
            hidden: Bool? = nil,
            follow: Bool? = nil,
            signal: AbortSignal? = nil
        ) {
            self.environment = environment
            self.cwd = cwd
            self.pattern = pattern
            self.limit = limit
            self.hidden = hidden
            self.follow = follow
            self.signal = signal
        }
    }

    // parity: core/src/ripgrep.ts#GrepInput [status=implemented hash=f9f58a4f17fe]
    public struct GrepInput: Sendable {
        /// Where `cwd` lives, and so where the search runs.
        public let environment: any CoreLocation.Environment.Interface
        public let cwd: String
        public let pattern: String
        public let file: String?
        public let include: String?
        public let literal: Bool?
        public let caseSensitive: Bool?
        public let limit: Int
        public let signal: AbortSignal?

        public init(
            environment: any CoreLocation.Environment.Interface = CoreLocation.Environment.host,
            cwd: String,
            pattern: String,
            file: String? = nil,
            include: String? = nil,
            literal: Bool? = nil,
            caseSensitive: Bool? = nil,
            limit: Int,
            signal: AbortSignal? = nil
        ) {
            self.environment = environment
            self.cwd = cwd
            self.pattern = pattern
            self.file = file
            self.include = include
            self.literal = literal
            self.caseSensitive = caseSensitive
            self.limit = limit
            self.signal = signal
        }
    }

    // parity: core/src/ripgrep.ts#Interface [status=adapted hash=e3b93c93a42b]
    public protocol Interface: Sendable {
        func find(_ input: FindInput) async throws -> [FileSystemSchema.Entry]
        func glob(_ input: GlobInput) async throws -> [FileSystemSchema.Entry]
        func grep(_ input: GrepInput) async throws -> [FileSystemSchema.Match]
    }

    /// Ripgrep binary resolver and pinned SHA-256 release verifier (`core/src/ripgrep/binary.ts`).
    // parity: core/src/ripgrep/binary.ts#RipgrepBinary [status=implemented hash=093bd5f0aee8]
    public enum Binary {
        public static let version = "15.1.0"

        public struct PlatformAsset: Equatable, Hashable, Sendable {
            public let platform: String
            public let extensionName: String
            public let sha256: String

            public init(platform: String, extensionName: String, sha256: String) {
                self.platform = platform
                self.extensionName = extensionName
                self.sha256 = sha256
            }
        }

        public static let platformAssets: [String: PlatformAsset] = [
            "arm64-darwin": PlatformAsset(
                platform: "aarch64-apple-darwin",
                extensionName: "tar.gz",
                sha256: "378e973289176ca0c6054054ee7f631a065874a352bf43f0fa60ef079b6ba715"
            ),
            "arm64-linux": PlatformAsset(
                platform: "aarch64-unknown-linux-gnu",
                extensionName: "tar.gz",
                sha256: "2b661c6ef508e902f388e9098d9c4c5aca72c87b55922d94abdba830b4dc885e"
            ),
            "x64-darwin": PlatformAsset(
                platform: "x86_64-apple-darwin",
                extensionName: "tar.gz",
                sha256: "64811cb24e77cac3057d6c40b63ac9becf9082eedd54ca411b475b755d334882"
            ),
            "x64-linux": PlatformAsset(
                platform: "x86_64-unknown-linux-musl",
                extensionName: "tar.gz",
                sha256: "1c9297be4a084eea7ecaedf93eb03d058d6faae29bbc57ecdaf5063921491599"
            ),
            "arm64-win32": PlatformAsset(
                platform: "aarch64-pc-windows-msvc",
                extensionName: "zip",
                sha256: "00d931fb5237c9696ca49308818edb76d8eb6fc132761cb2a1bd616b2df02f8e"
            ),
            "ia32-win32": PlatformAsset(
                platform: "i686-pc-windows-msvc",
                extensionName: "zip",
                sha256: "725be85a1e8f92878a548f40ee4f6df64bc93b809586462b3c6d884e1de1e83a"
            ),
            "x64-win32": PlatformAsset(
                platform: "x86_64-pc-windows-msvc",
                extensionName: "zip",
                sha256: "124510b94b6baa3380d051fdf4650eaa80a302c876d611e9dba0b2e18d87493a"
            ),
        ]

        /// Verifies downloaded ripgrep archive bytes against its pinned SHA-256 digest.
        // parity: core/src/ripgrep/binary.ts#RipgrepBinary.verify [status=implemented hash=60d2de072a1d]
        public static func verify(_ bytes: [UInt8], filename: String, expected: String) throws {
            let actual = Hash.sha256(bytes)
            if actual != expected {
                throw RipgrepError(
                    message: "ripgrep download \(filename) failed SHA-256 verification: expected \(expected), got \(actual)"
                )
            }
        }

        // parity: core/src/ripgrep/binary.ts#RipgrepBinary.Service [status=adapted hash=1f3e8cf41a54]
        public final class Service: Sendable {
            public static let serviceKey = "@opencode/RipgrepBinary"

            private let globalPaths: Global.Interface
            private let fileSystem: any OpenCodeFileSystem
            private let environment: any EnvironmentProviding

            public init(
                globalPaths: Global.Interface = Global.make(),
                fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
                environment: any EnvironmentProviding = SystemEnvironment.shared
            ) {
                self.globalPaths = globalPaths
                self.fileSystem = fileSystem
                self.environment = environment
            }

            public func filepath() async throws -> String {
                let exeName = Platform.current == .windows ? "rg.exe" : "rg"
                if let found = await CoreRipgrep.findExecutable(exeName, binDir: globalPaths.bin, environment: environment, fileSystem: fileSystem) {
                    return found
                }
                let cached = CoreConfigDiscovery.joinPath(globalPaths.bin, exeName)
                if await FSUtil.Service(fileSystem: fileSystem).isFile(cached) {
                    return cached
                }
                throw RipgrepError(message: "ripgrep binary '\(exeName)' not found on PATH or in \(globalPaths.bin)")
            }
        }

        // parity: core/src/ripgrep/binary.ts#RipgrepBinary.node [status=adapted hash=3dc9704f2848]
        public static let node: LayerNode.Provider = AppNode.makeGlobalNode(
            Service.serviceKey,
            LayerNode.ExecutableLayer { deps, _ in
                let global = deps.get(Global.Service.serviceKey, as: Global.Service.self)?.paths ?? Global.make()
                let fsUtil = deps.get(FSUtil.Service.serviceKey, as: FSUtil.Service.self)
                let svc = Service(globalPaths: global, fileSystem: fsUtil?.fileSystem ?? LocalFileSystem.shared)
                return LayerNode.Output([Service.serviceKey: svc])
            },
            [FSUtil.node, Global.node]
        )
    }

    // parity: core/src/ripgrep.ts#Service [status=adapted hash=6eecef14f0ae]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/Ripgrep"

        private let fileSystem: any OpenCodeFileSystem

        public init(fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared) {
            self.fileSystem = fileSystem
        }

        /// The disk a search runs over: this machine's file system for the local environment, the input environment's
        /// files anywhere else (upstream spawns `rg` through `input.environment.spawner`).
        private func disk(_ environment: any CoreLocation.Environment.Interface) -> any OpenCodeFileSystem {
            CoreFilesystem.FileMutation.fileSystem(for: environment, local: fileSystem)
        }

        public func find(_ input: FindInput) async throws -> [FileSystemSchema.Entry] {
            try checkAborted(input.signal)
            let files = try await walkFiles(disk(input.environment), root: input.cwd, hidden: input.hidden ?? false)
            let excludes = input.exclude ?? []
            var results: [FileSystemSchema.Entry] = []
            for rel in files {
                try checkAborted(input.signal)
                if excludes.contains(where: { Glob.match($0, filepath: rel, dot: true) }) {
                    continue
                }
                if input.pattern != "*" && !matchRipgrepGlob(input.pattern, relativePath: rel) {
                    continue
                }
                let entry = FileSystemSchema.Entry(
                    path: SchemaPrimitive.RelativePath(rawValue: rel),
                    type: .file
                )
                results.append(entry)
                if let onEntry = input.onEntry {
                    await onEntry(entry)
                }
                if results.count >= input.limit { break }
            }
            return results
        }

        public func glob(_ input: GlobInput) async throws -> [FileSystemSchema.Entry] {
            try checkAborted(input.signal)
            try validateGlobPattern(input.pattern)
            let hidden = input.hidden ?? false
            let files = try await walkFiles(disk(input.environment), root: input.cwd, hidden: hidden)
            var results: [FileSystemSchema.Entry] = []
            for rel in files {
                try checkAborted(input.signal)
                if !hidden && hasHiddenComponent(rel) {
                    continue
                }
                if matchRipgrepGlob(input.pattern, relativePath: rel) {
                    results.append(FileSystemSchema.Entry(
                        path: SchemaPrimitive.RelativePath(rawValue: rel),
                        type: .file
                    ))
                    if results.count >= input.limit { break }
                }
            }
            return results
        }

        public func grep(_ input: GrepInput) async throws -> [FileSystemSchema.Match] {
            try checkAborted(input.signal)
            if let include = input.include {
                try validateGlobPattern(include)
            }
            let caseSensitive = input.caseSensitive ?? true
            let literal = input.literal ?? false

            #if !os(WASI)
            let regex: NSRegularExpression?
            if !literal {
                var opts: NSRegularExpression.Options = []
                if !caseSensitive { opts.insert(.caseInsensitive) }
                do {
                    regex = try NSRegularExpression(pattern: input.pattern, options: opts)
                } catch {
                    throw InvalidPatternError(pattern: input.pattern, message: "regex parse error: \(error)")
                }
            } else {
                regex = nil
            }
            #endif

            let disk = self.disk(input.environment)
            let targets: [String]
            if let singleFile = input.file {
                targets = [normalizeRelPath(singleFile)]
            } else {
                targets = try await walkFiles(disk, root: input.cwd, hidden: true)
            }

            var matches: [FileSystemSchema.Match] = []
            for rel in targets {
                try checkAborted(input.signal)
                if let include = input.include, !matchRipgrepGlob(include, relativePath: rel) {
                    continue
                }
                let abs = CoreConfigDiscovery.joinPath(input.cwd, rel)
                guard let bytes = try? await disk.readFile(at: abs) else { continue }
                if bytes.contains(0) { continue } // skip binary files like ripgrep
                let content = String(decoding: bytes, as: UTF8.self)
                let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
                var byteOffset = 0

                for (idx, rawLineSub) in lines.enumerated() {
                    let rawLine = String(rawLineSub)
                    let lineText = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
                    let lineByteCount = rawLine.utf8.count + 1
                    defer { byteOffset += lineByteCount }

                    if idx == lines.count - 1 && rawLine.isEmpty { continue }

                    var submatches: [FileSystemSchema.Submatch] = []
                    if literal {
                        submatches = findLiteralSubmatches(
                            in: lineText,
                            needle: input.pattern,
                            caseSensitive: caseSensitive
                        )
                    } else {
                        #if !os(WASI)
                        if let regex {
                            let nsLine = lineText as NSString
                            let found = regex.matches(in: lineText, options: [], range: NSRange(location: 0, length: nsLine.length))
                            for m in found.prefix(CoreRipgrep.maxSubmatches) {
                                guard let swiftRange = Range(m.range, in: lineText) else { continue }
                                let startByte = lineText[..<swiftRange.lowerBound].utf8.count
                                let endByte = lineText[..<swiftRange.upperBound].utf8.count
                                submatches.append(FileSystemSchema.Submatch(
                                    text: String(lineText[swiftRange]),
                                    start: SchemaPrimitive.NonNegativeInt(rawValue: startByte) ?? .zero,
                                    end: SchemaPrimitive.NonNegativeInt(rawValue: endByte) ?? .zero
                                ))
                            }
                        }
                        #else
                        submatches = findLiteralSubmatches(
                            in: lineText,
                            needle: input.pattern,
                            caseSensitive: caseSensitive
                        )
                        #endif
                    }

                    if !submatches.isEmpty {
                        let clampedText = lineText.utf16.count > CoreRipgrep.maxLineChars
                            ? TextBoundary.head(lineText, limit: CoreRipgrep.maxLineChars) + "..."
                            : lineText
                        matches.append(FileSystemSchema.Match(
                            entry: FileSystemSchema.Entry(
                                path: SchemaPrimitive.RelativePath(rawValue: rel),
                                type: .file
                            ),
                            line: SchemaPrimitive.PositiveInt(rawValue: idx + 1)!,
                            offset: SchemaPrimitive.NonNegativeInt(rawValue: byteOffset) ?? .zero,
                            text: clampedText,
                            submatches: submatches
                        ))
                        if matches.count >= input.limit {
                            return matches
                        }
                    }
                }
            }
            return matches
        }

        private func checkAborted(_ signal: AbortSignal?) throws {
            if let signal, signal.isAborted {
                throw RipgrepError(message: "ripgrep aborted")
            }
        }

        private func validateGlobPattern(_ pattern: String) throws {
            var depth = 0
            for ch in pattern {
                if ch == "{" { depth += 1 }
                else if ch == "}" {
                    depth -= 1
                    if depth < 0 {
                        throw InvalidGlobError(message: "'\(pattern)': unbalanced closing '}'")
                    }
                }
            }
            if depth != 0 {
                throw InvalidGlobError(message: "'\(pattern)': unclosed '{'")
            }
        }

        private func matchRipgrepGlob(_ pattern: String, relativePath: String) -> Bool {
            if Glob.match(pattern, filepath: relativePath, dot: true) { return true }
            // Ripgrep globs without a slash match against any path segment (basename).
            if !pattern.contains("/") {
                let base = CoreConfigDiscovery.basename(relativePath)
                if Glob.match(pattern, filepath: base, dot: true) { return true }
            }
            return false
        }

        private func hasHiddenComponent(_ relativePath: String) -> Bool {
            relativePath.split(separator: "/").contains { $0.hasPrefix(".") && $0 != "." && $0 != ".." }
        }

        private func normalizeRelPath(_ value: String) -> String {
            var s = value.replacing("\\", with: "/")
            while s.hasPrefix("./") { s.removeFirst(2) }
            while s.hasPrefix("/") { s.removeFirst() }
            return s
        }

        private func walkFiles(_ disk: any OpenCodeFileSystem, root: String, hidden: Bool) async throws -> [String] {
            var out: [String] = []
            try await walkRec(disk, root: root, relative: "", hidden: hidden, into: &out)
            return out.sorted()
        }

        private func walkRec(
            _ disk: any OpenCodeFileSystem,
            root: String,
            relative: String,
            hidden: Bool,
            into out: inout [String]
        ) async throws {
            let current = relative.isEmpty ? root : CoreConfigDiscovery.joinPath(root, relative)
            guard let names = try? await disk.readDirectory(at: current) else { return }
            for name in names.sorted() {
                if name == ".git" { continue }
                if !hidden && name.hasPrefix(".") { continue }
                let rel = relative.isEmpty ? name : "\(relative)/\(name)"
                let abs = CoreConfigDiscovery.joinPath(root, rel)
                guard let st = try? await disk.stat(at: abs) else { continue }
                if st.type == .directory {
                    try await walkRec(disk, root: root, relative: rel, hidden: hidden, into: &out)
                } else if st.type == .file {
                    out.append(rel)
                }
            }
        }

        private func findLiteralSubmatches(
            in line: String,
            needle: String,
            caseSensitive: Bool
        ) -> [FileSystemSchema.Submatch] {
            guard !needle.isEmpty else { return [] }
            let hay = caseSensitive ? line : line.lowercased()
            let ndl = caseSensitive ? needle : needle.lowercased()
            var out: [FileSystemSchema.Submatch] = []
            var searchStart = hay.startIndex
            while searchStart < hay.endIndex,
                  let range = hay.range(of: ndl, range: searchStart..<hay.endIndex)
            {
                let startByte = hay[..<range.lowerBound].utf8.count
                let endByte = hay[..<range.upperBound].utf8.count
                // Slice original line by UTF-8 byte offsets if lengths match, else use matched slice
                let matchedText: String
                if line.utf8.count == hay.utf8.count {
                    let lineStart = line.utf8.index(line.utf8.startIndex, offsetBy: startByte)
                    let lineEnd = line.utf8.index(line.utf8.startIndex, offsetBy: endByte)
                    matchedText = String(decoding: line.utf8[lineStart..<lineEnd], as: UTF8.self)
                } else {
                    matchedText = String(hay[range])
                }
                out.append(FileSystemSchema.Submatch(
                    text: matchedText,
                    start: SchemaPrimitive.NonNegativeInt(rawValue: startByte) ?? .zero,
                    end: SchemaPrimitive.NonNegativeInt(rawValue: endByte) ?? .zero
                ))
                if out.count >= CoreRipgrep.maxSubmatches { break }
                searchStart = range.upperBound
            }
            return out
        }
    }

    // parity: core/src/ripgrep.ts#node [status=adapted hash=51e5c738c1d0]
    public static let node: LayerNode.Provider = AppNode.makeLocationNode(
        Service.serviceKey,
        LayerNode.ExecutableLayer { deps, _ in
            let fsUtil = deps.get(FSUtil.Service.serviceKey, as: FSUtil.Service.self)
            let svc = Service(fileSystem: fsUtil?.fileSystem ?? LocalFileSystem.shared)
            return LayerNode.Output([Service.serviceKey: svc as any Interface])
        },
        [FSUtil.node, Binary.node]
    )

    internal static func findExecutable(
        _ name: String,
        binDir: String?,
        environment: any EnvironmentProviding = SystemEnvironment.shared,
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared
    ) async -> String? {
        let fsUtil = FSUtil.Service(fileSystem: fileSystem)
        var dirs: [String] = []
        if let binDir, !binDir.isEmpty { dirs.append(binDir) }
        let sep: Character = Platform.current == .windows ? ";" : ":"
        if let pathEnv = environment.variable("PATH") {
            dirs.append(contentsOf: pathEnv.split(separator: sep).map(String.init))
        }
        for dir in dirs where !dir.isEmpty {
            let candidate = CoreConfigDiscovery.joinPath(dir, name)
            if await fsUtil.isFile(candidate) {
                return candidate
            }
        }
        return nil
    }
}

// MARK: - CoreFormatter (`core/src/formatter.ts` & `core/src/formatter/builtins.ts`)

public enum CoreFormatter {
    // parity: core/src/formatter/builtins.ts#Info [status=adapted hash=3413990b702a]
    public struct Info: Sendable {
        public let name: String
        public let environment: [String: String]?
        public let extensions: [String]
        public let enabled: @Sendable () async -> [String]?

        public init(
            name: String,
            environment: [String: String]? = nil,
            extensions: [String],
            enabled: @escaping @Sendable () async -> [String]?
        ) {
            self.name = name
            self.environment = environment
            self.extensions = extensions
            self.enabled = enabled
        }
    }

    public struct MakeInput: Sendable {
        public let directory: String
        public let worktree: String
        public let fileSystem: any OpenCodeFileSystem
        public let processes: any AppProcess.Interface
        public let bin: String
        public let environment: any EnvironmentProviding

        public init(
            directory: String,
            worktree: String,
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
            processes: any AppProcess.Interface = AppProcess.Service(),
            bin: String = Global.Path.bin,
            environment: any EnvironmentProviding = SystemEnvironment.shared
        ) {
            self.directory = directory
            self.worktree = worktree
            self.fileSystem = fileSystem
            self.processes = processes
            self.bin = bin
            self.environment = environment
        }
    }

    /// Constructs the 26 built-in language formatters (`gofmt`, `prettier`, `biome`, `rustfmt`, `ruff`, etc.).
    // parity: core/src/formatter/builtins.ts#make [status=implemented hash=78f2399dd2cb]
    public static func make(_ input: MakeInput) -> [Info] {
        let fsUtil = FSUtil.Service(fileSystem: input.fileSystem)

        func executable(_ name: String, extensions: [String], args: [String]) -> Info {
            Info(name: name, extensions: extensions) {
                guard let bin = await CoreRipgrep.findExecutable(
                    name,
                    binDir: input.bin,
                    environment: input.environment,
                    fileSystem: input.fileSystem
                ) else {
                    return nil
                }
                return [bin] + args
            }
        }

        let hasPackageDep: @Sendable (String) async -> Bool = { target in
            let files = (try? await fsUtil.findUp(target: "package.json", start: input.directory, stop: input.worktree)) ?? []
            for file in files {
                guard let json = try? await fsUtil.readJson(file),
                      case .object(let entries) = json else { continue }
                for field in ["dependencies", "devDependencies"] {
                    if let (_, val) = entries.first(where: { $0.0 == field }),
                       case .object(let deps) = val,
                       deps.contains(where: { $0.0 == target })
                    {
                        return true
                    }
                }
            }
            return false
        }

        let jsDocExts = [
            ".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx", ".mts", ".cts",
            ".html", ".htm", ".css", ".scss", ".sass", ".less", ".vue", ".svelte",
            ".json", ".jsonc", ".yaml", ".yml", ".toml", ".xml", ".md", ".mdx",
            ".graphql", ".gql",
        ]

        let prettier = Info(name: "prettier", environment: ["BUN_BE_BUN": "1"], extensions: jsDocExts) {
            guard await hasPackageDep("prettier"),
                  let bin = await CoreRipgrep.findExecutable("prettier", binDir: input.bin, environment: input.environment, fileSystem: input.fileSystem)
            else { return nil }
            return [bin, "--write", "$FILE"]
        }

        let oxfmt = Info(
            name: "oxfmt",
            environment: ["BUN_BE_BUN": "1"],
            extensions: [".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx", ".mts", ".cts"]
        ) {
            guard await hasPackageDep("oxfmt"),
                  let bin = await CoreRipgrep.findExecutable("oxfmt", binDir: input.bin, environment: input.environment, fileSystem: input.fileSystem)
            else { return nil }
            return [bin, "$FILE"]
        }

        let biome = Info(name: "biome", environment: ["BUN_BE_BUN": "1"], extensions: jsDocExts) {
            let b1 = (try? await fsUtil.findUp(target: "biome.json", start: input.directory, stop: input.worktree)) ?? []
            let b2 = (try? await fsUtil.findUp(target: "biome.jsonc", start: input.directory, stop: input.worktree)) ?? []
            guard !b1.isEmpty || !b2.isEmpty,
                  let bin = await CoreRipgrep.findExecutable("biome", binDir: input.bin, environment: input.environment, fileSystem: input.fileSystem)
            else { return nil }
            return [bin, "format", "--write", "$FILE"]
        }

        let clang = Info(
            name: "clang-format",
            extensions: [".c", ".cc", ".cpp", ".cxx", ".c++", ".h", ".hh", ".hpp", ".hxx", ".h++", ".ino", ".C", ".H"]
        ) {
            let found = (try? await fsUtil.findUp(target: ".clang-format", start: input.directory, stop: input.worktree)) ?? []
            guard !found.isEmpty,
                  let bin = await CoreRipgrep.findExecutable("clang-format", binDir: input.bin, environment: input.environment, fileSystem: input.fileSystem)
            else { return nil }
            return [bin, "-i", "$FILE"]
        }

        let ruff = Info(name: "ruff", extensions: [".py", ".pyi"]) {
            guard let bin = await CoreRipgrep.findExecutable("ruff", binDir: input.bin, environment: input.environment, fileSystem: input.fileSystem) else {
                return nil
            }
            for cfg in ["pyproject.toml", "ruff.toml", ".ruff.toml"] {
                let found = (try? await fsUtil.findUp(target: cfg, start: input.directory, stop: input.worktree)) ?? []
                guard let first = found.first else { continue }
                if cfg != "pyproject.toml" { return [bin, "format", "$FILE"] }
                let text = (try? await fsUtil.readFileStringSafe(first)) ?? ""
                if text.contains("[tool.ruff]") { return [bin, "format", "$FILE"] }
            }
            for dep in ["requirements.txt", "pyproject.toml", "Pipfile"] {
                let found = (try? await fsUtil.findUp(target: dep, start: input.directory, stop: input.worktree)) ?? []
                if let first = found.first,
                   ((try? await fsUtil.readFileStringSafe(first)) ?? "").contains("ruff")
                {
                    return [bin, "format", "$FILE"]
                }
            }
            return nil
        }

        let air = Info(name: "air", extensions: [".R"]) {
            guard let bin = await CoreRipgrep.findExecutable("air", binDir: input.bin, environment: input.environment, fileSystem: input.fileSystem) else {
                return nil
            }
            guard let out = try? await input.processes.run(
                ProcessSpec(executable: bin, arguments: ["--help"], workingDirectory: input.directory),
                options: AppProcess.RunOptions()
            ), out.exitCode == 0 else { return nil }
            let first = String(decoding: out.stdout, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? ""
            return first.contains("R language") && first.contains("formatter") ? [bin, "format", "$FILE"] : nil
        }

        let uv = Info(name: "uv", extensions: [".py", ".pyi"]) {
            guard let bin = await CoreRipgrep.findExecutable("uv", binDir: input.bin, environment: input.environment, fileSystem: input.fileSystem) else {
                return nil
            }
            guard let out = try? await input.processes.run(
                ProcessSpec(executable: bin, arguments: ["format", "--help"], workingDirectory: input.directory),
                options: AppProcess.RunOptions()
            ), out.exitCode == 0 else { return nil }
            return [bin, "format", "--", "$FILE"]
        }

        let ocamlformat = Info(name: "ocamlformat", extensions: [".ml", ".mli"]) {
            let found = (try? await fsUtil.findUp(target: ".ocamlformat", start: input.directory, stop: input.worktree)) ?? []
            guard !found.isEmpty,
                  let bin = await CoreRipgrep.findExecutable("ocamlformat", binDir: input.bin, environment: input.environment, fileSystem: input.fileSystem)
            else { return nil }
            return [bin, "-i", "$FILE"]
        }

        let pint = Info(name: "pint", extensions: [".php"]) {
            let found = (try? await fsUtil.findUp(target: "composer.json", start: input.directory, stop: input.worktree)) ?? []
            for file in found {
                guard let json = try? await fsUtil.readJson(file),
                      case .object(let entries) = json else { continue }
                for field in ["require", "require-dev"] {
                    if let (_, val) = entries.first(where: { $0.0 == field }),
                       case .object(let deps) = val,
                       deps.contains(where: { $0.0 == "laravel/pint" })
                    {
                        return ["./vendor/bin/pint", "$FILE"]
                    }
                }
            }
            return nil
        }

        return [
            executable("gofmt", extensions: [".go"], args: ["-w", "$FILE"]),
            executable("mix", extensions: [".ex", ".exs", ".eex", ".heex", ".leex", ".neex", ".sface"], args: ["format", "$FILE"]),
            oxfmt,
            prettier,
            biome,
            executable("zig", extensions: [".zig", ".zon"], args: ["fmt", "$FILE"]),
            clang,
            executable("ktlint", extensions: [".kt", ".kts"], args: ["-F", "$FILE"]),
            ruff,
            air,
            uv,
            executable("rubocop", extensions: [".rb", ".rake", ".gemspec", ".ru"], args: ["--autocorrect", "$FILE"]),
            executable("standardrb", extensions: [".rb", ".rake", ".gemspec", ".ru"], args: ["--fix", "$FILE"]),
            executable("htmlbeautifier", extensions: [".erb", ".html.erb"], args: ["$FILE"]),
            executable("dart", extensions: [".dart"], args: ["format", "$FILE"]),
            ocamlformat,
            executable("terraform", extensions: [".tf", ".tfvars"], args: ["fmt", "$FILE"]),
            executable("latexindent", extensions: [".tex"], args: ["-w", "-s", "$FILE"]),
            executable("gleam", extensions: [".gleam"], args: ["format", "$FILE"]),
            executable("shfmt", extensions: [".sh", ".bash"], args: ["-w", "$FILE"]),
            executable("nixfmt", extensions: [".nix"], args: ["$FILE"]),
            executable("rustfmt", extensions: [".rs"], args: ["$FILE"]),
            pint,
            executable("ormolu", extensions: [".hs"], args: ["-i", "$FILE"]),
            executable("cljfmt", extensions: [".clj", ".cljs", ".cljc", ".edn"], args: ["fix", "--quiet", "$FILE"]),
            executable("dfmt", extensions: [".d"], args: ["-i", "$FILE"]),
        ]
    }

    // parity: core/src/formatter.ts#Editor [status=adapted hash=59a424607473]
    public final class Editor: @unchecked Sendable {
        public private(set) var formatters: [Info] = []

        public init(initial: [Info] = []) {
            self.formatters = initial
        }

        public func set(_ formatter: Info) {
            if let idx = formatters.firstIndex(where: { $0.name == formatter.name }) {
                formatters[idx] = formatter
            } else {
                formatters.append(formatter)
            }
        }

        public func remove(_ name: String) {
            formatters.removeAll { $0.name == name }
        }
    }

    // parity: core/src/formatter.ts#Interface [status=adapted hash=bbb97f7d34a2]
    public protocol Interface: Sendable {
        func transform(_ fn: @escaping @Sendable (Editor) -> Void) async -> CoreFilesystem.LocationWatcherPolicy.Registration
        func reload() async
        func file(_ target: CoreFilesystem.FileAccess.Target) async -> Bool
    }

    // parity: core/src/formatter.ts#Service [status=adapted hash=e5bd60fd47c6]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/v2/Formatter"

        private struct State: Sendable {
            var transforms: [UInt64: @Sendable (Editor) -> Void] = [:]
            var order: [UInt64] = []
            var formatters: [Info] = []
            var commandCache: [String: [String]?] = [:]
            var nextID: UInt64 = 1
        }

        private let directory: String
        private let processes: any AppProcess.Interface
        private let state = Mutex(State())

        public init(
            directory: String = "/",
            processes: any AppProcess.Interface = AppProcess.Service()
        ) {
            self.directory = directory
            self.processes = processes
        }

        public func transform(
            _ fn: @escaping @Sendable (Editor) -> Void
        ) async -> CoreFilesystem.LocationWatcherPolicy.Registration {
            let id = state.withLock { s -> UInt64 in
                let id = s.nextID
                s.nextID &+= 1
                s.transforms[id] = fn
                s.order.append(id)
                return id
            }
            await reload()
            return CoreFilesystem.LocationWatcherPolicy.Registration { [weak self] in
                self?.state.withLock { s in
                    _ = s.transforms.removeValue(forKey: id)
                    s.order.removeAll { $0 == id }
                }
            }
        }

        public func reload() async {
            state.withLock { s in
                let editor = Editor()
                for id in s.order {
                    s.transforms[id]?(editor)
                }
                s.formatters = editor.formatters
                s.commandCache.removeAll()
            }
        }

        public func file(_ target: CoreFilesystem.FileAccess.Target) async -> Bool {
            // A formatter is a process on this machine acting on this machine's disk.
            if target.environment.id != CoreLocation.Environment.localID { return false }
            let filepath = target.absolute.rawValue
            let ext = Self.fileExtension(filepath)
            let matching = state.withLock { s in
                s.formatters.filter { $0.extensions.contains(ext) }
            }
            for formatter in matching {
                let resolvedCmd: [String]?
                if let cached = state.withLock({ $0.commandCache[formatter.name] }) {
                    resolvedCmd = cached
                } else {
                    let computed = await formatter.enabled()
                    if computed != nil {
                        state.withLock { $0.commandCache[formatter.name] = computed }
                    }
                    resolvedCmd = computed
                }
                guard let cmd = resolvedCmd, let exe = cmd.first else { continue }
                let args = cmd.dropFirst().map { $0.replacing("$FILE", with: filepath) }
                if let res = try? await processes.run(
                    ProcessSpec(
                        executable: exe,
                        arguments: args,
                        workingDirectory: directory,
                        environment: formatter.environment
                    ),
                    options: AppProcess.RunOptions()
                ), res.exitCode == 0 {
                    return true
                }
            }
            return false
        }

        private static func fileExtension(_ filepath: String) -> String {
            let base = CoreConfigDiscovery.basename(filepath)
            guard let dot = base.lastIndex(of: "."), dot != base.startIndex else { return "" }
            return String(base[dot...])
        }
    }

    // parity: core/src/formatter.ts#node [status=adapted hash=3fcb8accf2a3]
    public static let node: LayerNode.Provider = AppNode.makeLocationNode(
        Service.serviceKey,
        LayerNode.ExecutableLayer { deps, _ in
            let dir = deps.get("@opencode/Location.directory", as: String.self) ?? "/"
            let proc = deps.get(AppProcess.Service.serviceKey, as: (any AppProcess.Interface).self) ?? AppProcess.Service()
            let svc = Service(directory: dir, processes: proc)
            return LayerNode.Output([Service.serviceKey: svc as any Interface])
        },
        [AppProcess.node]
    )
}

extension CoreFormatter.Interface {
    /// Formats a path on this server's own machine (a local target named by its absolute path).
    public func file(_ filepath: String) async -> Bool {
        await file(CoreFilesystem.FileAccess.Target(
            absolute: SchemaPrimitive.AbsolutePath(rawValue: filepath),
            resource: filepath
        ))
    }
}

// MARK: - CoreFuzzyFileIndex Wiring into CoreFilesystem.Search & CoreFilesystem.Fff

extension CoreFilesystem.Fff {
    /// Native Swift `Fff.Picker` backed by `CoreFuzzyFileIndex`.
    public final class NativePicker: CoreFilesystem.Fff.Picker, Sendable {
        private struct PickerState: Sendable {
            var destroyed: Bool = false
            var warmTask: Task<Void, Never>?
        }

        public let basePath: String
        public let index: CoreFuzzyFileIndex
        private let ownsIndex: Bool
        private let pickerState = Mutex(PickerState())

        public init(
            basePath: String,
            index: CoreFuzzyFileIndex,
            ownsIndex: Bool = false,
            autoWarm: Bool = true
        ) {
            self.basePath = basePath
            self.index = index
            self.ownsIndex = ownsIndex

            if autoWarm && index.entryCount(root: basePath) == 0 {
                let targetRoot = basePath
                let idx = index
                let task = Task<Void, Never> { [weak self] in
                    _ = try? await idx.warm(root: targetRoot)
                    self?.pickerState.withLock { $0.warmTask = nil }
                }
                pickerState.withLock { $0.warmTask = task }
            }
        }

        /// Awaits completion of the initial background scan (or warms on demand if not yet scanned).
        public func waitUntilReady() async {
            let task = pickerState.withLock { $0.warmTask }
            if let task {
                await task.value
            } else if !pickerState.withLock({ $0.destroyed }) && index.entryCount(root: basePath) == 0 {
                _ = try? await index.warm(root: basePath)
            }
        }

        public func destroy() {
            let task: Task<Void, Never>? = pickerState.withLock { s in
                s.destroyed = true
                let existing = s.warmTask
                s.warmTask = nil
                return existing
            }
            task?.cancel()
            if ownsIndex {
                index.invalidate(root: basePath)
            }
        }

        public func isScanning() -> Bool {
            let hasTask = pickerState.withLock { $0.warmTask != nil }
            return hasTask || index.isScanning(root: basePath)
        }

        public func fileSearch(_ query: String, options: SearchOptions? = nil) -> Result<Search> {
            guard !pickerState.withLock({ $0.destroyed }) else {
                return .error("fff picker destroyed")
            }
            let sliced = runPagedSearch(query: query, kind: .file, options: options)
            return .ok(Search(
                items: sliced.map { File(relativePath: $0.relativePath) },
                scores: sliced.map { Score(total: $0.totalScore) }
            ))
        }

        public func directorySearch(_ query: String, options: SearchOptions? = nil) -> Result<DirSearch> {
            guard !pickerState.withLock({ $0.destroyed }) else {
                return .error("fff picker destroyed")
            }
            let sliced = runPagedSearch(query: query, kind: .directory, options: options)
            return .ok(DirSearch(
                items: sliced.map { Directory(relativePath: $0.relativePath) },
                scores: sliced.map { Score(total: $0.totalScore) }
            ))
        }

        public func mixedSearch(_ query: String, options: SearchOptions? = nil) -> Result<MixedSearch> {
            guard !pickerState.withLock({ $0.destroyed }) else {
                return .error("fff picker destroyed")
            }
            let sliced = runPagedSearch(query: query, kind: nil, options: options)
            let items: [Mixed] = sliced.map { match in
                switch match.kind {
                case .file: return .file(File(relativePath: match.relativePath))
                case .directory: return .directory(Directory(relativePath: match.relativePath))
                }
            }
            return .ok(MixedSearch(
                items: items,
                scores: sliced.map { Score(total: $0.totalScore) }
            ))
        }

        private func runPagedSearch(
            query: String,
            kind: CoreFuzzyFileIndex.EntryKind?,
            options: SearchOptions?
        ) -> [CoreFuzzyFileIndex.MatchResult] {
            let pageIndex = max(0, options?.pageIndex ?? 0)
            let pageSize = max(1, options?.pageSize ?? 50)
            let offset = pageIndex * pageSize
            let fetchLimit = offset + pageSize
            let all = index.searchCached(
                root: basePath,
                query: query,
                options: CoreFuzzyFileIndex.SearchOptions(kind: kind, limit: fetchLimit)
            )
            guard offset < all.count else { return [] }
            return Array(all[offset..<min(all.count, fetchLimit)])
        }
    }

    /// Native Swift `Fff.Backend` backed by `CoreFuzzyFileIndex`.
    public final class NativeBackend: CoreFilesystem.Fff.Backend, Sendable {
        private let fileSystem: any OpenCodeFileSystem
        private let sharedIndex: CoreFuzzyFileIndex?
        private let configuration: CoreFuzzyFileIndex.Configuration

        public init(
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
            index: CoreFuzzyFileIndex? = nil,
            configuration: CoreFuzzyFileIndex.Configuration = CoreFuzzyFileIndex.Configuration()
        ) {
            self.fileSystem = fileSystem
            self.sharedIndex = index
            self.configuration = configuration
        }

        public func isAvailable() -> Bool {
            true
        }

        public func create(_ options: Init) -> Result<any Picker> {
            let ownsIndex = sharedIndex == nil
            let index = sharedIndex ?? CoreFuzzyFileIndex(fileSystem: fileSystem, configuration: configuration)
            let picker = NativePicker(basePath: options.basePath, index: index, ownsIndex: ownsIndex)
            return .ok(picker)
        }
    }

    /// Returns a bound `Fff` adapter powered by `CoreFuzzyFileIndex`.
    public static func nativeAdapter(
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
        index: CoreFuzzyFileIndex? = nil,
        configuration: CoreFuzzyFileIndex.Configuration = CoreFuzzyFileIndex.Configuration()
    ) -> BoundAdapter {
        bind(NativeBackend(fileSystem: fileSystem, index: index, configuration: configuration))
    }
}

extension CoreFilesystem.Search {
    /// High-speed `CoreFilesystem.Search.Interface` backed by `CoreFuzzyFileIndex`.
    public final class FuzzyIndexedService: CoreFilesystem.Search.Interface, Sendable {
        public static let serviceKey = CoreFilesystem.Search.Service.serviceKey

        public let directory: String
        public let index: CoreFuzzyFileIndex

        public init(
            directory: String,
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
            index: CoreFuzzyFileIndex? = nil,
            configuration: CoreFuzzyFileIndex.Configuration = CoreFuzzyFileIndex.Configuration()
        ) {
            self.directory = directory
            self.index = index ?? CoreFuzzyFileIndex(fileSystem: fileSystem, configuration: configuration)
        }

        /// Warms the background index for this service's directory.
        @discardableResult
        public func warm() async throws -> Int {
            try await index.warm(root: directory)
        }

        /// Incrementally applies a single-entry filesystem change without full rescan.
        public func applyChange(path: String, kind: CoreFuzzyFileIndex.ChangeKind) {
            index.applyChange(path: path, kind: kind, root: directory)
        }

        /// Invalidates this directory's cached index snapshot.
        public func invalidate() {
            index.invalidate(root: directory)
        }

        /// Records an access for frecency ranking.
        public func recordAccess(path: String, at epochMs: Int64? = nil) {
            index.recordAccess(path: path, at: epochMs, root: directory)
        }

        /// Returns detailed fuzzy/frecency match results including UTF-16 highlight indices.
        public func findDetailed(_ input: FileSystemSchema.FindInput) async -> [CoreFuzzyFileIndex.MatchResult] {
            let entryKind: CoreFuzzyFileIndex.EntryKind?
            switch input.type {
            case .file: entryKind = .file
            case .directory: entryKind = .directory
            case nil: entryKind = nil
            }
            let limit = input.limit?.rawValue ?? 50
            return await index.search(
                root: directory,
                query: input.query,
                options: CoreFuzzyFileIndex.SearchOptions(kind: entryKind, limit: limit)
            )
        }

        public func find(_ input: FileSystemSchema.FindInput) async -> [FileSystemSchema.Entry] {
            let matches = await findDetailed(input)
            return matches.map { match in
                let displayPath: String
                let schemaType: FileSystemSchema.EntryType
                switch match.kind {
                case .file:
                    displayPath = match.relativePath
                    schemaType = .file
                case .directory:
                    displayPath = match.relativePath.hasSuffix("/") ? match.relativePath : match.relativePath + "/"
                    schemaType = .directory
                }
                return FileSystemSchema.Entry(
                    path: SchemaPrimitive.RelativePath(rawValue: displayPath),
                    type: schemaType
                )
            }
        }
    }

    /// Location-scoped `LayerNode.ExecutableLayer` wiring `CoreFuzzyFileIndex` into `CoreFilesystem.Search`.
    public static func fuzzyIndexLayer(
        index: CoreFuzzyFileIndex? = nil,
        configuration: CoreFuzzyFileIndex.Configuration = CoreFuzzyFileIndex.Configuration()
    ) -> LayerNode.ExecutableLayer {
        LayerNode.ExecutableLayer { deps, _ in
            let directory = deps.get("@opencode/Location.directory", as: String.self) ?? "/"
            let fsUtil = deps.get(FSUtil.Service.serviceKey, as: FSUtil.Service.self)
            let fs = fsUtil?.fileSystem ?? LocalFileSystem.shared
            let service = FuzzyIndexedService(
                directory: directory,
                fileSystem: fs,
                index: index,
                configuration: configuration
            )
            return LayerNode.Output([Service.serviceKey: service as any Interface])
        }
    }

    /// Drop-in `LayerNode.Provider` providing `CoreFilesystem.Search.Service.serviceKey` via `CoreFuzzyFileIndex`.
    public static func fuzzyIndexNode(
        index: CoreFuzzyFileIndex? = nil,
        configuration: CoreFuzzyFileIndex.Configuration = CoreFuzzyFileIndex.Configuration()
    ) -> LayerNode.Provider {
        AppNode.makeLocationNode(
            Service.serviceKey,
            fuzzyIndexLayer(index: index, configuration: configuration),
            [FSUtil.node]
        )
    }

    /// Native `fff`-protocol layer composed directly via `CoreFilesystem.Search.makeFffLayer`.
    public static func nativeFffLayer(
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
        index: CoreFuzzyFileIndex? = nil,
        configuration: CoreFuzzyFileIndex.Configuration = CoreFuzzyFileIndex.Configuration()
    ) -> LayerNode.ExecutableLayer {
        let backend = CoreFilesystem.Fff.NativeBackend(
            fileSystem: fileSystem,
            index: index,
            configuration: configuration
        )
        return makeFffLayer { options in
            backend.create(options)
        }
    }
}
