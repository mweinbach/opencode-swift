#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodeAI
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

/// Core plugin contract, host resolution, module runtime, source tracking, storage, permission,
/// and worktree primitives ported from `packages/plugin/src/*.ts`.
public enum PluginContract {
    // MARK: - src/app.ts

    /// Metadata identifying the running OpenCode host application.
    // parity: plugin/src/app.ts#App [status=implemented hash=acd45aa152f2]
    public struct App: Equatable, Hashable, Sendable, Codable {
        public let name: String
        public let version: String
        public let channel: String

        public init(name: String, version: String, channel: String) {
            self.name = name
            self.version = version
            self.channel = channel
        }
    }

    // MARK: - src/options.ts

    /// JSON-serializable options supplied to a plugin from configuration.
    // parity: plugin/src/options.ts#PluginOptions [status=implemented hash=0231204ac6d1]
    public typealias PluginOptions = [String: JSONValue]

    // MARK: - src/permission.ts

    /// Validated input for `context.permission.assert(...)`.
    // parity: plugin/src/permission.ts#AssertInput [status=implemented hash=0b22f3864603]
    public struct AssertInput: Equatable, Hashable, Sendable, Codable {
        public let sessionID: SessionID
        public let agent: AgentSchema.ID?
        public let action: String
        public let resources: [String]
        public let save: [String]?
        public let metadata: [String: JSONValue]?
        public let source: PermissionSchema.Source?

        public init(
            sessionID: SessionID,
            agent: AgentSchema.ID? = nil,
            action: String,
            resources: [String],
            save: [String]? = nil,
            metadata: [String: JSONValue]? = nil,
            source: PermissionSchema.Source? = nil
        ) {
            self.sessionID = sessionID
            self.agent = agent
            self.action = action
            self.resources = resources
            self.save = save
            self.metadata = metadata
            self.source = source
        }
    }

    // MARK: - src/storage.ts

    /// One key-value pair returned by plugin-scoped storage scan operations.
    // parity: plugin/src/storage.ts#StorageEntry [status=implemented hash=476ba9a668d2]
    public struct StorageEntry: Equatable, Hashable, Sendable, Codable {
        public let key: String
        public let value: JSONValue

        public init(key: String, value: JSONValue) {
            self.key = key
            self.value = value
        }
    }

    /// Options controlling a prefix-scoped key scan over plugin storage.
    // parity: plugin/src/storage.ts#StorageScanOptions [status=implemented hash=f3e6696a728c]
    public struct StorageScanOptions: Equatable, Hashable, Sendable, Codable {
        public let prefix: String
        public let after: String?
        public let limit: Int?

        public init(prefix: String, after: String? = nil, limit: Int? = nil) {
            self.prefix = prefix
            self.after = after
            self.limit = limit
        }
    }

    /// One page of plugin storage entries with an optional continuation cursor.
    // parity: plugin/src/storage.ts#StorageScanResult [status=implemented hash=efb4a2edb525]
    public struct StorageScanResult: Equatable, Hashable, Sendable, Codable {
        public let entries: [StorageEntry]
        public let next: String?

        public init(entries: [StorageEntry], next: String? = nil) {
            self.entries = entries
            self.next = next
        }
    }

    // MARK: - src/worktree.ts

    /// Input supplied to a worktree strategy when creating a new worktree.
    // parity: plugin/src/worktree.ts#WorktreeCreateInput [status=implemented hash=1a864f8286a8]
    public struct WorktreeCreateInput: Equatable, Hashable, Sendable, Codable {
        public let sourceDirectory: String
        public let directory: String
        public let branch: String?

        public init(sourceDirectory: String, directory: String, branch: String? = nil) {
            self.sourceDirectory = sourceDirectory
            self.directory = directory
            self.branch = branch
        }
    }

    /// Input supplied to a worktree strategy when removing an existing worktree.
    // parity: plugin/src/worktree.ts#WorktreeRemoveInput [status=implemented hash=f23e294a6894]
    public struct WorktreeRemoveInput: Equatable, Hashable, Sendable, Codable {
        public let directory: String
        public let force: Bool

        public init(directory: String, force: Bool) {
            self.directory = directory
            self.force = force
        }
    }

    /// Result returned after creating a worktree.
    // parity: plugin/src/worktree.ts#WorktreeResult [status=implemented hash=c6386a6cc867]
    public struct WorktreeResult: Equatable, Hashable, Sendable, Codable {
        public let directory: String

        public init(directory: String) {
            self.directory = directory
        }
    }

    /// Inventory entry reported by a worktree strategy's `list`.
    // parity: plugin/src/worktree.ts#WorktreeEntry [status=implemented hash=6fbd92ae98fe]
    public struct WorktreeEntry: Equatable, Hashable, Sendable, Codable {
        public enum EntryType: String, Equatable, Hashable, Sendable, Codable {
            case root
            case worktree
        }

        public let directory: String
        public let type: EntryType

        public init(directory: String, type: EntryType) {
            self.directory = directory
            self.type = type
        }
    }

    // MARK: - src/host.ts

    public enum Host {
        /// Plugin package or directory location passed to entrypoint resolution.
        // parity: plugin/src/host.ts#Target [status=implemented hash=519a3215d88f]
        public struct Target: Equatable, Hashable, Sendable, Codable {
            public let directory: String
            public let name: String?

            public init(directory: String, name: String? = nil) {
                self.directory = directory
                self.name = name
            }
        }

        /// Resolved module entrypoints exported by a plugin package or directory.
        // parity: plugin/src/host.ts#Entrypoints [status=implemented hash=8dfdd89faaba]
        public struct Entrypoints: Equatable, Hashable, Sendable, Codable {
            public let server: String?
            public let tui: String?
            public let rpc: String?
            public let gui: String?

            public init(
                server: String? = nil,
                tui: String? = nil,
                rpc: String? = nil,
                gui: String? = nil
            ) {
                self.server = server
                self.tui = tui
                self.rpc = rpc
                self.gui = gui
            }
        }

        private struct PackageManifest: Decodable {
            let name: String?
            let exports: JSONValue?
            let main: String?
        }

        private static func readManifest(
            directory: String,
            fileSystem: any OpenCodeFileSystem
        ) async -> PackageManifest? {
            let manifestPath = joinPath(directory, "package.json")
            guard await fileSystem.exists(at: manifestPath),
                  let bytes = try? await fileSystem.readFile(at: manifestPath)
            else {
                return nil
            }
            return try? JSONDecoder().decode(PackageManifest.self, from: Data(bytes))
        }

        private static func extractExportTarget(exports: JSONValue?, subpath: String) -> String? {
            guard let exports else { return nil }
            let key = subpath.isEmpty ? "." : "./\(subpath)"
            switch exports {
            case .string(let value):
                return subpath.isEmpty ? value : nil
            case .object(let map):
                if let entry = map[key] {
                    return resolveExportCondition(entry)
                }
                if subpath.isEmpty && !map.keys.contains(where: { $0.hasPrefix(".") }) {
                    return resolveExportCondition(exports)
                }
                return nil
            default:
                return nil
            }
        }

        private static func resolveExportCondition(_ value: JSONValue) -> String? {
            switch value {
            case .string(let path):
                return path
            case .object(let dict):
                for key in ["import", "default", "bun", "node", "require"] {
                    if let nested = dict[key], let resolved = resolveExportCondition(nested) {
                        return resolved
                    }
                }
                return nil
            case .array(let items):
                for item in items {
                    if let resolved = resolveExportCondition(item) {
                        return resolved
                    }
                }
                return nil
            default:
                return nil
            }
        }

        private static func isCommonJSFile(_ path: String) -> Bool {
            let clean = path.split(separator: "?").first.map(String.init) ?? path
            return clean.hasSuffix(".cjs") || clean.hasSuffix(".js")
        }

        /// Resolves `server`, `tui`, `rpc`, and `gui` (`./gui-experimental`) entrypoints from a target directory.
        // parity: plugin/src/host.ts#resolve [status=implemented hash=8979d8a2c690]
        public static func resolve(
            _ input: Target,
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared
        ) async -> Entrypoints {
            let manifest = await readManifest(directory: input.directory, fileSystem: fileSystem)
            let useExports = manifest?.exports != nil && (input.name != nil || (manifest?.name?.isEmpty == false))
            let effectiveName = useExports ? (input.name ?? manifest?.name) : input.name

            func probeEntry(_ subpaths: [String]) async -> String? {
                for subpath in subpaths {
                    if useExports, let rel = extractExportTarget(exports: manifest?.exports, subpath: subpath) {
                        let resolved = resolvePath(rel, relativeTo: input.directory)
                        if await fileSystem.exists(at: resolved) {
                            return toFileURLString(resolved)
                        }
                        if let probed = try? await RuntimeImport.resolveNodeModule(
                            specifier: rel,
                            directory: input.directory,
                            fileSystem: fileSystem
                        ) {
                            return probed
                        }
                        continue
                    }

                    if !useExports {
                        let candidate = subpath.isEmpty ? "index" : subpath
                        if let probed = try? await RuntimeImport.resolveNodeModule(
                            specifier: candidate,
                            directory: input.directory,
                            fileSystem: fileSystem
                        ) {
                            return probed
                        }
                        // Also check package.json "main" for root entry when no exports map exists
                        if subpath.isEmpty, let mainField = manifest?.main,
                           let probed = try? await RuntimeImport.resolveNodeModule(
                               specifier: mainField,
                               directory: input.directory,
                               fileSystem: fileSystem
                           ) {
                            return probed
                        }
                    }
                }
                return nil
            }

            let server = await probeEntry(["server", ""])
            let tui = await probeEntry(["tui"])
            let rpc = await probeEntry(["rpc"])
            let rawGui: String?
            if effectiveName != nil && useExports {
                rawGui = await probeEntry(["gui-experimental"])
            } else {
                rawGui = await probeEntry(["gui-experimental.cjs", "gui-experimental.js"])
            }
            let gui = rawGui.flatMap { isCommonJSFile($0) ? $0 : nil }
            return Entrypoints(server: server, tui: tui, rpc: rpc, gui: gui)
        }

        /// Loads a resolved plugin entrypoint via an injectable loader or `RuntimeImport`.
        // parity: plugin/src/host.ts#load [status=adapted hash=c9f8f6f382dd]
        public static func load(
            _ entrypoint: String,
            loader: (@Sendable (String) async throws -> AnySendableValue)? = nil
        ) async throws -> AnySendableValue {
            if let loader {
                return try await loader(entrypoint)
            }
            return try await RuntimeImport.importNodeModule(entrypoint)
        }

        /// Computes the fallback plugin identifier for packages without a server `Plugin.define` ID:
        /// `target.name`, else `package.json` `name`, else directory basename.
        // parity: plugin/src/host.ts#packageID [status=implemented hash=af92032959f7]
        public static func packageID(
            _ target: Target,
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared
        ) async -> String {
            if let name = target.name, !name.isEmpty {
                return name
            }
            if let manifestName = await readManifest(directory: target.directory, fileSystem: fileSystem)?.name,
               !manifestName.isEmpty {
                return manifestName
            }
            return basenameOfPath(target.directory)
        }
    }

    // MARK: - src/runtime-modules.ts

    public enum RuntimeModules {
        /// Loader returning a runtime module's exported bindings map.
        // parity: plugin/src/runtime-modules.ts#RuntimeModuleLoader [status=adapted hash=3d251e351d9e]
        public typealias RuntimeModuleLoader = @Sendable () async throws -> [String: AnySendableValue]

        public static let defaultRuntimePackages: [String] = ["effect", "@opencode/plugin"]

        /// Resolves host package roots for the given runtime packages (`effect`, `@opencode/plugin`).
        // parity: plugin/src/runtime-modules.ts#resolveHostPackageRoots [status=adapted hash=497fb6fac934]
        public static func resolveHostPackageRoots(
            from directory: String,
            packages: [String] = defaultRuntimePackages,
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared
        ) async -> [String] {
            var roots: [String] = []
            for pkg in packages {
                let candidate = await findNodeModulesDir(pkgName: pkg, from: directory, fileSystem: fileSystem)
                if let candidate {
                    if let real = try? await fileSystem.realPath(at: candidate), real != candidate {
                        roots.append(real)
                    }
                    roots.append(candidate)
                }
            }
            return roots
        }

        /// Builds cached module loaders for all discovered runtime specifiers.
        // parity: plugin/src/runtime-modules.ts#loadRuntimeModules [status=adapted hash=2d89db9938a9]
        public static func loadRuntimeModules(
            from directory: String = ".",
            packages: [String] = defaultRuntimePackages,
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
            importer: (@Sendable (String) async throws -> [String: AnySendableValue])? = nil
        ) async -> [String: RuntimeModuleLoader] {
            let discovered = await discoverPluginRuntimeSpecifiers(
                from: directory,
                packages: packages,
                fileSystem: fileSystem
            )
            var result: [String: RuntimeModuleLoader] = [:]
            for (specifier, resolved) in discovered {
                result[specifier] = createLoader(resolved, importer: importer)
            }
            return result
        }

        /// Discovers host runtime module specifiers while excluding `internal/`, `source.*`, `runtime*`, and `gui/`.
        // parity: plugin/src/runtime-modules.ts#discoverPluginRuntimeSpecifiers [status=adapted hash=364638305d78]
        public static func discoverPluginRuntimeSpecifiers(
            from directory: String = ".",
            packages: [String] = defaultRuntimePackages,
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared
        ) async -> [String: String] {
            var entries: [String: String] = [:]
            for pkgName in packages {
                guard let pkgDir = await findNodeModulesDir(pkgName: pkgName, from: directory, fileSystem: fileSystem) else {
                    continue
                }
                let scanRoot: String
                let srcDir = joinPath(pkgDir, "src")
                let distDir = joinPath(pkgDir, "dist")
                if await fileSystem.exists(at: distDir) {
                    scanRoot = distDir
                } else if await fileSystem.exists(at: srcDir) {
                    scanRoot = srcDir
                } else {
                    scanRoot = pkgDir
                }

                let indexJs = joinPath(scanRoot, "index.js")
                let indexTs = joinPath(scanRoot, "index.ts")
                if await fileSystem.exists(at: indexJs) {
                    entries[pkgName] = indexJs
                } else if await fileSystem.exists(at: indexTs) {
                    entries[pkgName] = indexTs
                }

                let files = await walkRelativeFiles(under: scanRoot, prefix: "", fileSystem: fileSystem)
                for file in files {
                    let normalized = file.replacing("\\", with: "/")
                    guard normalized.hasSuffix(".js") || normalized.hasSuffix(".ts") else { continue }
                    if normalized.hasPrefix("internal/")
                        || normalized.contains("/internal/")
                        || normalized.hasPrefix("source.")
                        || normalized.hasPrefix("runtime")
                        || normalized.hasPrefix("gui/")
                    {
                        continue
                    }
                    let extLen = 3
                    let base = String(normalized.dropLast(extLen))
                    if base == "index" { continue }
                    let candidates: [String]
                    if base.hasSuffix("/index") {
                        let parent = String(base.dropLast("/index".count))
                        candidates = ["\(pkgName)/\(parent)", "\(pkgName)/\(base)"]
                    } else {
                        candidates = ["\(pkgName)/\(base)"]
                    }
                    let fullPath = joinPath(scanRoot, normalized)
                    for specifier in candidates where entries[specifier] == nil {
                        entries[specifier] = fullPath
                    }
                }
            }
            return entries
        }

        /// Emits the JS loader expression string for a runtime specifier, collapsing `effect/<member>` when aliased.
        // parity: plugin/src/runtime-modules.ts#pluginRuntimeLoaderCode [status=implemented hash=fb55097ea798]
        public static func pluginRuntimeLoaderCode(
            specifier: String,
            entries: [String: String],
            isReexportedMember: ((_ parentResolved: String, _ member: String, _ memberResolved: String) -> Bool)? = nil
        ) -> String {
            if specifier.hasPrefix("effect/"), let slashIdx = specifier.lastIndex(of: "/") {
                let parent = String(specifier[..<slashIdx])
                let member = String(specifier[specifier.index(after: slashIdx)...])
                if member != "index",
                   let parentResolved = entries[parent],
                   let resolved = entries[specifier],
                   isReexportedMember?(parentResolved, member, resolved) == true
                {
                    return "() => require(\(jsonQuoted(parent)))[\(jsonQuoted(member))]"
                }
            }
            return "() => require(\(jsonQuoted(specifier)))"
        }

        /// Creates a memoized, concurrency-safe module loader that caches resolved exports and clears failures.
        // parity: plugin/src/runtime-modules.ts#createLoader [status=adapted hash=9409d1d869a5]
        public static func createLoader(
            _ resolved: String,
            importer: (@Sendable (String) async throws -> [String: AnySendableValue])? = nil
        ) -> RuntimeModuleLoader {
            final class LoaderBox: @unchecked Sendable {
                private let lock = Mutex<State>(State())
                private let resolved: String
                private let importer: (@Sendable (String) async throws -> [String: AnySendableValue])?

                struct State {
                    var cached: [String: AnySendableValue]?
                    var pending: Task<[String: AnySendableValue], any Error>?
                }

                init(
                    resolved: String,
                    importer: (@Sendable (String) async throws -> [String: AnySendableValue])?
                ) {
                    self.resolved = resolved
                    self.importer = importer
                }

                func load() async throws -> [String: AnySendableValue] {
                    if let cached = lock.withLock({ $0.cached }) {
                        return cached
                    }
                    let task: Task<[String: AnySendableValue], any Error> = lock.withLock { state in
                        if let existing = state.pending {
                            return existing
                        }
                        let path = self.resolved
                        let customImporter = self.importer
                        let created = Task<[String: AnySendableValue], any Error> {
                            if let customImporter {
                                return try await customImporter(path)
                            }
                            let value = try await RuntimeImport.importNodeModule(path)
                            if case .object(let dict) = value {
                                return dict
                            }
                            return ["default": value]
                        }
                        state.pending = created
                        return created
                    }
                    do {
                        let loaded = try await task.value
                        lock.withLock { state in
                            state.cached = loaded
                            state.pending = nil
                        }
                        return loaded
                    } catch {
                        lock.withLock { state in
                            state.pending = nil
                        }
                        throw error
                    }
                }
            }

            let box = LoaderBox(resolved: resolved, importer: importer)
            return { try await box.load() }
        }

        private static func findNodeModulesDir(
            pkgName: String,
            from directory: String,
            fileSystem: any OpenCodeFileSystem
        ) async -> String? {
            var current = normalizeAbsolutePath(directory)
            while true {
                let candidate = joinPath(joinPath(current, "node_modules"), pkgName)
                let hasPkgJson = await fileSystem.exists(at: joinPath(candidate, "package.json"))
                let hasDir = hasPkgJson ? true : await fileSystem.exists(at: candidate)
                if hasDir {
                    return candidate
                }
                let parent = dirnameOfPath(current)
                if parent == current {
                    return nil
                }
                current = parent
            }
        }

        private static func walkRelativeFiles(
            under root: String,
            prefix: String,
            fileSystem: any OpenCodeFileSystem
        ) async -> [String] {
            let dir = prefix.isEmpty ? root : joinPath(root, prefix)
            guard let names = try? await fileSystem.readDirectory(at: dir) else { return [] }
            var results: [String] = []
            for name in names.sorted() {
                let rel = prefix.isEmpty ? name : "\(prefix)/\(name)"
                let full = joinPath(root, rel)
                if let stat = try? await fileSystem.stat(at: full), stat.type == .directory {
                    let nested = await walkRelativeFiles(under: root, prefix: rel, fileSystem: fileSystem)
                    results.append(contentsOf: nested)
                } else {
                    results.append(rel)
                }
            }
            return results
        }
    }

    // MARK: - src/runtime.ts

    public enum Runtime {
        private static let installedModules = Mutex<[String: RuntimeModules.RuntimeModuleLoader]?>(nil)

        private static let foreignPkgSuffix =
            #"(?:node_modules[/\\](@opencode[/\\]plugin|effect)|(@opencode[/\\]plugin|effect)@[^/\\]+@@@\d+)"#

        /// Returns whether the host plugin runtime provides `specifier`.
        // parity: plugin/src/runtime.ts#provides [status=implemented hash=866b7e0448e7]
        public static func provides(_ specifier: String) -> Bool {
            installedModules.withLock { modules in
                guard let modules else { return false }
                return modules[specifier] != nil
            }
        }

        /// Ensures the host plugin runtime module map is installed once and returns the active registry.
        // parity: plugin/src/runtime.ts#ensurePluginRuntime [status=adapted hash=451968fddde6]
        @discardableResult
        public static func ensurePluginRuntime(
            modules overrideModules: [String: RuntimeModules.RuntimeModuleLoader]? = nil
        ) -> [String: RuntimeModules.RuntimeModuleLoader] {
            installedModules.withLock { current in
                if let overrideModules {
                    current = overrideModules
                    return overrideModules
                }
                if let existing = current {
                    return existing
                }
                let defaults: [String: RuntimeModules.RuntimeModuleLoader] = [
                    "@opencode/plugin": { [:] },
                    "@opencode/plugin/effect": { [:] },
                    "@opencode/plugin/promise": { [:] },
                    "@opencode/plugin/tui": { [:] },
                    "effect": { [:] },
                ]
                current = defaults
                return defaults
            }
        }

        /// Resets installed runtime modules (useful in isolated tests).
        public static func resetPluginRuntimeForTesting() {
            installedModules.withLock { $0 = nil }
        }

        /// Builds the regex pattern string rejecting foreign `node_modules/(effect|@opencode/plugin)` copies outside host roots.
        // parity: plugin/src/runtime.ts#createForeignPackageFilter [status=implemented hash=47f6b9871b2a]
        public static func createForeignPackageFilter(rootsInput: [String] = []) -> String {
            let suffix = #"[/\\]"# + foreignPkgSuffix + #"[/\\].*\.[cm]?[jt]sx?(?:[?#].*)?$"#
            var seen: Set<String> = []
            var uniqueRoots: [String] = []
            for root in rootsInput where seen.insert(root).inserted {
                uniqueRoots.append(root)
            }
            if uniqueRoots.isEmpty {
                return suffix
            }
            let escaped = uniqueRoots.map { escapeRegexRoot($0) }.joined(separator: "|")
            return #"^(?!(?:"# + escaped + #")[/\\]).*"# + suffix
        }

        private static func escapeRegexRoot(_ value: String) -> String {
            let special: Set<Character> = [".", "*", "+", "?", "^", "$", "{", "}", "(", ")", "|", "[", "]", "\\"]
            var out = ""
            var i = value.startIndex
            while i < value.endIndex {
                let ch = value[i]
                if ch == "/" || ch == "\\" {
                    while i < value.endIndex && (value[i] == "/" || value[i] == "\\") {
                        i = value.index(after: i)
                    }
                    out.append(#"[/\\]"#)
                    continue
                }
                if special.contains(ch) {
                    out.append("\\")
                }
                out.append(ch)
                i = value.index(after: i)
            }
            return out
        }
    }

    // MARK: - src/source.ts, source.bun.ts, source.node.ts, source.package.ts

    public enum Source {
        public struct PreparedSource: Sendable {
            public let version: String
            public let load: @Sendable () async throws -> AnySendableValue
            public let dispose: (@Sendable () -> Void)?

            public init(
                version: String,
                load: @escaping @Sendable () async throws -> AnySendableValue,
                dispose: (@Sendable () -> Void)? = nil
            ) {
                self.version = version
                self.load = load
                self.dispose = dispose
            }
        }

        public struct LoadedModule: Sendable {
            public let version: String
            public let module: AnySendableValue

            public init(version: String, module: AnySendableValue) {
                self.version = version
                self.module = module
            }
        }

        /// Stateful source fingerprint & reload tracker created by `createPluginSources`.
        public actor PluginSources {
            private struct TrackedFile: Sendable {
                let digest: String
                let directory: Bool
            }

            private struct CachedEntry {
                let task: Task<LoadedModule, any Error>
                let files: [String: TrackedFile]
            }

            private let watch: @Sendable (String) async -> Void
            private let fileSystem: any OpenCodeFileSystem
            private let prepare: @Sendable (String, @Sendable (String, Bool) -> Void) async throws -> PreparedSource
            private var sources: [String: CachedEntry] = [:]
            private var cleanups: [@Sendable () -> Void] = []

            public init(
                watch: @escaping @Sendable (String) async -> Void,
                fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
                prepare: (@Sendable (String, @Sendable (String, Bool) -> Void) async throws -> PreparedSource)? = nil
            ) {
                self.watch = watch
                self.fileSystem = fileSystem
                self.prepare = prepare ?? { entrypoint, track in
                    try await PluginContract.Source.prepareBunSource(
                        entrypoint: entrypoint,
                        track: track,
                        fileSystem: fileSystem
                    )
                }
            }

            /// Reads and caches a plugin entrypoint, re-evaluating only when a tracked file or directory digest changes.
            public func read(_ entrypoint: String) async throws -> LoadedModule {
                if let previous = sources[entrypoint] {
                    var unchanged = true
                    for (file, info) in previous.files {
                        let current = await PluginContract.Source.digest(
                            file: file,
                            directory: info.directory,
                            fileSystem: fileSystem
                        )
                        if current != info.digest {
                            unchanged = false
                            break
                        }
                    }
                    if unchanged {
                        return try await previous.task.value
                    }
                }

                let trackedPaths = Mutex<[(String, Bool)]>([])
                let track: @Sendable (String, Bool) -> Void = { file, isDirectory in
                    trackedPaths.withLock { list in
                        if !list.contains(where: { $0.0 == file }) {
                            list.append((file, isDirectory))
                        }
                    }
                }

                let rootPath = fromFileURLString(entrypoint)
                track(rootPath, false)

                let prepared = try await prepare(entrypoint, track)
                if let dispose = prepared.dispose {
                    cleanups.append(dispose)
                }

                let capturedPaths = trackedPaths.withLock { $0 }
                var fileMap: [String: TrackedFile] = [:]
                for (path, isDir) in capturedPaths {
                    let d = await PluginContract.Source.digest(file: path, directory: isDir, fileSystem: fileSystem)
                    fileMap[path] = TrackedFile(digest: d, directory: isDir)
                    await watch(path)
                }

                let task = Task<LoadedModule, any Error> {
                    let mod = try await prepared.load()
                    return LoadedModule(version: prepared.version, module: mod)
                }
                sources[entrypoint] = CachedEntry(task: task, files: fileMap)
                return try await task.value
            }

            public func dispose() {
                let toRun = cleanups
                cleanups.removeAll()
                sources.removeAll()
                for cleanup in toRun {
                    cleanup()
                }
            }
        }

        private static let generationCounter = Mutex<UInt64>(1)

        private static func nextGeneration() -> String {
            let value = generationCounter.withLock { counter -> UInt64 in
                counter &+= 1
                return counter
            }
            return String(value)
        }

        internal static func digest(
            file: String,
            directory: Bool,
            fileSystem: any OpenCodeFileSystem
        ) async -> String {
            if directory {
                guard let names = try? await fileSystem.readDirectory(at: file) else {
                    return "missing"
                }
                let sorted = names.sorted()
                let encoded = (try? JSONEncoder().encode(sorted)).map { Array($0) } ?? []
                return Hash.sha256(encoded)
            }
            guard let bytes = try? await fileSystem.readFile(at: file) else {
                return "missing"
            }
            return Hash.sha256(bytes)
        }

        /// Keeps source fingerprints and import attempts together so unchanged modules do not re-evaluate.
        // parity: plugin/src/source.ts#createPluginSources [status=implemented hash=dde78b15d426]
        public static func createPluginSources(
            watch: @escaping @Sendable (String) async -> Void,
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
            prepare: (@Sendable (String, @Sendable (String, Bool) -> Void) async throws -> PreparedSource)? = nil
        ) -> PluginSources {
            PluginSources(watch: watch, fileSystem: fileSystem, prepare: prepare)
        }

        /// Resolves a local file specifier (`file://`, `./`, `../`, or absolute path) into a `file://` URL string.
        // parity: plugin/src/source.ts#localSource [status=implemented hash=9d13c5bc2908]
        public static func localSource(_ spec: String, directory: String) -> String? {
            if spec.hasPrefix("file://") {
                return spec
            }
            if spec.hasPrefix("./") || spec.hasPrefix("../") || isAbsolutePath(spec) {
                return toFileURLString(resolvePath(spec, relativeTo: directory))
            }
            return nil
        }

        /// Computes the `node_modules/<pkg>` directory to watch when an external package import is missing.
        // parity: plugin/src/source.package.ts#missingPackageTarget [status=implemented hash=08de4b29b08a]
        public static func missingPackageTarget(
            specifier: String,
            importer: String,
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared
        ) async -> String? {
            if specifier.hasPrefix("#") {
                return nil
            }
            let parts = specifier.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { return nil }
            let name: String
            if specifier.hasPrefix("@") {
                name = parts.prefix(2).joined(separator: "/")
            } else {
                name = parts[0]
            }
            let start = dirnameOfPath(importer)
            var directory = start
            while true {
                if await fileSystem.exists(at: joinPath(directory, "package.json")) {
                    return joinPath(joinPath(directory, "node_modules"), name)
                }
                let parent = dirnameOfPath(directory)
                if parent == directory {
                    return joinPath(joinPath(start, "node_modules"), name)
                }
                directory = parent
            }
        }

        /// Bun-style source preparation: scans local file dependencies, tracks missing packages, and returns a reload version.
        // parity: plugin/src/source.bun.ts#prepareSource [status=adapted hash=dd3b920cb81d]
        public static func prepareBunSource(
            entrypoint: String,
            track: @Sendable (String, Bool) -> Void,
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
            loader: (@Sendable (String) async throws -> AnySendableValue)? = nil
        ) async throws -> PreparedSource {
            let root = fromFileURLString(entrypoint)
            track(root, false)
            if let bytes = try? await fileSystem.readFile(at: root) {
                let sourceText = String(decoding: bytes, as: UTF8.self)
                for imported in scanStaticImportSpecifiers(sourceText) {
                    if let local = localSource(imported, directory: dirnameOfPath(root)) {
                        let resolvedFile = fromFileURLString(local)
                        if !resolvedFile.split(separator: "/").contains("node_modules") {
                            if await fileSystem.exists(at: resolvedFile) {
                                track(resolvedFile, false)
                            } else {
                                track(dirnameOfPath(resolvedFile), true)
                            }
                        }
                    } else if !Runtime.provides(imported) {
                        if let missing = await missingPackageTarget(
                            specifier: imported,
                            importer: root,
                            fileSystem: fileSystem
                        ) {
                            track(missing, true)
                        }
                    }
                }
            }
            let version = nextGeneration()
            return PreparedSource(
                version: version,
                load: { try await Host.load(entrypoint, loader: loader) },
                dispose: nil
            )
        }

        /// Node-style source preparation: attaches `__opencode_reload=<version>` query parameter for cache busting.
        // parity: plugin/src/source.node.ts#prepareSource [status=adapted hash=9624c05dfcb1]
        public static func prepareNodeSource(
            entrypoint: String,
            track: @Sendable (String, Bool) -> Void,
            loader: (@Sendable (String) async throws -> AnySendableValue)? = nil
        ) async throws -> PreparedSource {
            let root = fromFileURLString(entrypoint)
            track(root, false)
            let version = nextGeneration()
            let separator = entrypoint.contains("?") ? "&" : "?"
            let freshSpecifier = "\(entrypoint)\(separator)__opencode_reload=\(version)"
            return PreparedSource(
                version: freshSpecifier,
                load: { try await Host.load(freshSpecifier, loader: loader) },
                dispose: {}
            )
        }

        private static func scanStaticImportSpecifiers(_ source: String) -> [String] {
            var results: [String] = []
            for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if let range = line.range(of: " from \"") ?? line.range(of: " from '") {
                    let quote = line[line.index(before: range.upperBound)]
                    let tail = line[range.upperBound...]
                    if let end = tail.firstIndex(of: quote) {
                        results.append(String(tail[..<end]))
                    }
                } else if let range = line.range(of: "require(\"") ?? line.range(of: "require('") {
                    let quote = line[line.index(before: range.upperBound)]
                    let tail = line[range.upperBound...]
                    if let end = tail.firstIndex(of: quote) {
                        results.append(String(tail[..<end]))
                    }
                }
            }
            return results
        }
    }

    // MARK: - Internal Portable Path Helpers

    internal static func isAbsolutePath(_ path: String) -> Bool {
        if path.hasPrefix("/") { return true }
        let chars = Array(path)
        if chars.count >= 3 && chars[1] == ":" && (chars[2] == "/" || chars[2] == "\\") {
            return true
        }
        return false
    }

    internal static func normalizeAbsolutePath(_ raw: String) -> String {
        let unified = raw.replacing("\\", with: "/")
        let leadingSlash = unified.hasPrefix("/")
        var stack: [String] = []
        for component in unified.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                if !stack.isEmpty && stack.last != ".." {
                    stack.removeLast()
                } else if !leadingSlash {
                    stack.append("..")
                }
            } else {
                stack.append(String(component))
            }
        }
        if leadingSlash {
            return "/" + stack.joined(separator: "/")
        }
        return stack.isEmpty ? "." : stack.joined(separator: "/")
    }

    internal static func joinPath(_ base: String, _ component: String) -> String {
        if isAbsolutePath(component) {
            return normalizeAbsolutePath(component)
        }
        let trimmedBase = base.hasSuffix("/") && base.count > 1 ? String(base.dropLast()) : base
        let trimmedComp = component.hasPrefix("/") ? String(component.dropFirst()) : component
        if trimmedBase.isEmpty || trimmedBase == "." {
            return normalizeAbsolutePath(trimmedComp)
        }
        if trimmedComp.isEmpty {
            return normalizeAbsolutePath(trimmedBase)
        }
        return normalizeAbsolutePath("\(trimmedBase)/\(trimmedComp)")
    }

    internal static func resolvePath(_ spec: String, relativeTo directory: String) -> String {
        if isAbsolutePath(spec) {
            return normalizeAbsolutePath(spec)
        }
        return joinPath(directory, spec)
    }

    internal static func dirnameOfPath(_ raw: String) -> String {
        let normalized = normalizeAbsolutePath(raw)
        if normalized == "/" || normalized == "." {
            return normalized
        }
        guard let slash = normalized.lastIndex(of: "/") else {
            return "."
        }
        if slash == normalized.startIndex {
            return "/"
        }
        return String(normalized[..<slash])
    }

    internal static func basenameOfPath(_ raw: String) -> String {
        let normalized = normalizeAbsolutePath(raw)
        if normalized == "/" { return "" }
        guard let slash = normalized.lastIndex(of: "/") else {
            return normalized
        }
        return String(normalized[normalized.index(after: slash)...])
    }

    internal static func toFileURLString(_ path: String) -> String {
        if path.hasPrefix("file://") { return path }
        let norm = normalizeAbsolutePath(path)
        return norm.hasPrefix("/") ? "file://\(norm)" : "file:///\(norm)"
    }

    internal static func fromFileURLString(_ urlString: String) -> String {
        guard urlString.hasPrefix("file://") else {
            return urlString
        }
        let withoutScheme = String(urlString.dropFirst("file://".count))
        let withoutQuery = withoutScheme.split(separator: "?", maxSplits: 1).first.map(String.init) ?? withoutScheme
        return withoutQuery
    }

    internal static func jsonQuoted(_ string: String) -> String {
        guard let data = try? JSONEncoder().encode(string),
              let encoded = String(data: data, encoding: .utf8)
        else {
            return "\"\(string)\""
        }
        return encoded
    }
}

/// Shared OpenCode Plugin SDK primitives for native Swift plugins, envelopes, events, and registrations.
public enum PluginSDK {
    /// Enveloped response matching `{ location, data }` returned by Location-scoped plugin domain APIs.
    public struct LocatedResult<Data: Sendable>: Sendable {
        public let location: LocationSchema.Info
        public let data: Data

        public init(location: LocationSchema.Info, data: Data) {
            self.location = location
            self.data = data
        }
    }

    /// Generic event envelope delivered through `context.event.subscribe(...)`.
    public struct EventPayload: Equatable, Hashable, Sendable, Codable {
        public let type: String
        public let location: LocationSchema.Ref?
        public let data: [String: JSONValue]

        public init(
            type: String,
            location: LocationSchema.Ref? = nil,
            data: [String: JSONValue] = [:]
        ) {
            self.type = type
            self.location = location
            self.data = data
        }
    }

    /// Typed `Sendable` Swift protocol that native Swift plugins conform to directly.
    public protocol NativePlugin: Sendable {
        var id: String { get }
        func activate(in context: PluginEffect.Context) async throws -> (@Sendable () async -> Void)?
    }
}

public extension PluginSDK.NativePlugin {
    /// Converts a native Swift plugin into a `PluginEffect.Plugin` definition for the core host.
    func asEffectPlugin() -> PluginEffect.Plugin {
        PluginEffect.Plugin(id: self.id) { context in
            let cleanup = try await self.activate(in: context)
            if let cleanup {
                context.addFinalizer(cleanup)
            }
        }
    }
}
