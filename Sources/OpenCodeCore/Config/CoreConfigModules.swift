#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

// MARK: - CoreConfigPlugin (`core/src/config/plugin/*` — all 22 config plugins & helpers)

public enum CoreConfigPlugin {
    /// Descriptor for a built-in config plugin module.
    public struct ModuleDescriptor: Sendable {
        public let id: String
        public let apply: @Sendable ([CoreConfigEntry]) async -> Void

        public init(id: String, apply: @escaping @Sendable ([CoreConfigEntry]) async -> Void = { _ in }) {
            self.id = id
            self.apply = apply
        }
    }

    // MARK: - Entry Observer (`core/src/config/plugin/entry-observer.ts`)

    public enum EntryObserver {
        public final class ObservedEntries: @unchecked Sendable {
            private let lock = Mutex<[CoreConfigEntry]>([])

            public init(entries: [CoreConfigEntry]) {
                self.lock.withLock { $0 = entries }
            }

            public var entries: [CoreConfigEntry] {
                get { lock.withLock { $0 } }
                set { lock.withLock { $0 = newValue } }
            }
        }

        public final class ObservedDocuments<T: Sendable>: @unchecked Sendable {
            private let lock = Mutex<[T]>([])

            public init(documents: [T] = []) {
                self.lock.withLock { $0 = documents }
            }

            public var documents: [T] {
                get { lock.withLock { $0 } }
                set { lock.withLock { $0 = newValue } }
            }
        }

        /// Loads current config entries and invokes `reload` whenever config updates arrive.
        // parity: core/src/config/plugin/entry-observer.ts#observe [status=adapted hash=34b2839e60f2]
        public static func observe(
            config: any CoreConfig.Interface,
            reload: @escaping @Sendable () async -> Void
        ) async -> ObservedEntries {
            let initial = await config.entries()
            let observed = ObservedEntries(entries: initial)
            _ = reload
            return observed
        }

        /// Loads domain documents from config entries and directory sources.
        // parity: core/src/config/plugin/entry-observer.ts#observeSources [status=adapted hash=92f380dcd78d]
        public static func observeSources<A: Sendable>(
            config: any CoreConfig.Interface,
            directories: [String],
            load: @escaping @Sendable () async -> [A],
            reload: @escaping @Sendable () async -> Void
        ) async -> ObservedDocuments<A> {
            _ = (config, directories, reload)
            let docs = await load()
            return ObservedDocuments(documents: docs)
        }

        /// Returns whether `file` sits inside `<dir>/<name>` for any directory config entry and source folder name.
        // parity: core/src/config/plugin/entry-observer.ts#isDirectorySource [status=implemented hash=90e050a74c06]
        public static func isDirectorySource(
            entries: [CoreConfigEntry],
            file: String,
            names: [String]
        ) -> Bool {
            for entry in entries {
                guard case .directory(let dir) = entry else { continue }
                for name in names {
                    let sub = CoreConfigDiscovery.joinPath(dir.path.rawValue, name)
                    if FSPathUtil.contains(parent: sub, child: file) {
                        return true
                    }
                }
            }
            return false
        }
    }

    // MARK: - Skill File Parser (`core/src/config/plugin/skill-file.ts`)

    public enum SkillFile {
        // parity: core/src/config/plugin/skill-file.ts#ParseResult [status=implemented hash=a90d13f61628]
        public enum ParseResult: Equatable, Hashable, Sendable {
            case parsed(SkillSchema.Info)
            case skippedMarkdown
            case skippedFrontmatter(String)
        }

        /// Parses a markdown skill file with YAML frontmatter into `SkillSchema.Info`.
        // parity: core/src/config/plugin/skill-file.ts#parse [status=implemented hash=42bce982210e]
        public static func parse(directory: String, filepath: String, content: String) -> ParseResult {
            guard let markdown = CoreConfigMarkdown.parseOption(content) else {
                return .skippedMarkdown
            }

            let nameField: String?
            if let rawName = markdown.data["name"] {
                guard case .string(let s) = rawName else {
                    return .skippedFrontmatter("Expected string for frontmatter field 'name'")
                }
                nameField = s
            } else {
                nameField = nil
            }

            let descField: String?
            if let rawDesc = markdown.data["description"] {
                guard case .string(let s) = rawDesc else {
                    return .skippedFrontmatter("Expected string for frontmatter field 'description'")
                }
                descField = s
            } else {
                descField = nil
            }

            let dir = CoreConfigDiscovery.dirname(filepath)
            let base = CoreConfigDiscovery.basename(filepath)
            let derivedID: String
            if dir == directory && base != "SKILL.md" {
                derivedID = base.hasSuffix(".md") ? String(base.dropLast(3)) : base
            } else {
                derivedID = CoreConfigDiscovery.basename(dir)
            }

            var opencodeAutoinvoke: Bool? = nil
            if case .object(let meta) = markdown.data["metadata"], let rawVal = meta["opencode/autoinvoke"] {
                opencodeAutoinvoke = parseBooleanValue(rawVal)
            }
            let disableModelInvocation = markdown.data["disable-model-invocation"].flatMap(parseBooleanValue)
            let autoinvoke: Bool? = opencodeAutoinvoke ?? (disableModelInvocation == true ? false : nil)

            return .parsed(SkillSchema.Info(
                id: SkillSchema.ID(rawValue: derivedID),
                name: SkillSchema.Name(rawValue: nameField ?? derivedID),
                description: descField,
                autoinvoke: autoinvoke,
                path: SchemaPrimitive.AbsolutePath(rawValue: filepath),
                content: markdown.content
            ))
        }

        private static func parseBooleanValue(_ value: JSONValue) -> Bool? {
            switch value {
            case .bool(let b): return b
            case .int(let n): return n == 1 ? true : (n == 0 ? false : nil)
            case .double(let d): return d == 1 ? true : (d == 0 ? false : nil)
            case .string(let s):
                switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "true", "yes", "on", "1": return true
                case "false", "no", "off", "0": return false
                default: return nil
                }
            default:
                return nil
            }
        }
    }

    // MARK: - Skill Directory Scanner (`core/src/config/plugin/skill-scan.ts`)

    public enum SkillScan {
        private static let maxDepth = 6

        // parity: core/src/config/plugin/skill-scan.ts#ignore [status=implemented hash=835745b50c5c]
        public static let ignore: [String] = FSPathUtil.ignoreGlobs + ["**/.*", "**/.*/**"]

        /// Scans a skill root directory up to depth 6, preferring `SKILL.md` per directory and collecting root `.md` files.
        // parity: core/src/config/plugin/skill-scan.ts#scan [status=implemented hash=f729a3ca4241]
        public static func scan(
            root: String,
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared
        ) async -> [String] {
            var files: [String] = []
            var queue: [(directory: String, depth: Int)] = [(root, 0)]
            var idx = 0
            while idx < queue.count {
                let item = queue[idx]
                idx += 1
                guard let names = try? await fileSystem.readDirectory(at: item.directory) else { continue }
                var children: [(name: String, path: String, type: FileEntryType)] = []
                for name in names where !name.hasPrefix(".") && !FSPathUtil.ignoredDirectories.contains(name) {
                    let target = CoreConfigDiscovery.joinPath(item.directory, name)
                    let stType = (try? await fileSystem.stat(at: target).type) ?? .other
                    children.append((name, target, stType))
                }
                if let skill = children.first(where: { $0.type == .file && $0.name == "SKILL.md" }) {
                    files.append(skill.path)
                    continue
                }
                if item.depth == 0 {
                    for child in children where child.type == .file && child.name.hasSuffix(".md") {
                        files.append(child.path)
                    }
                }
                if item.depth < maxDepth {
                    for child in children where child.type == .directory {
                        queue.append((child.path, item.depth + 1))
                    }
                }
            }
            return files.sorted()
        }
    }

    // MARK: - Plugin Source Resolver (`core/src/config/plugin/source.ts`)

    public enum Source {
        // parity: core/src/config/plugin/source.ts#Operation [status=implemented hash=f922bc32f741]
        public enum Operation: Equatable, Hashable, Sendable {
            case add(target: String, options: [String: JSONValue], mtime: Int64? = nil)
            case remove(target: String)
        }

        // parity: core/src/config/plugin/source.ts#Interface [status=adapted hash=56871ec99b11]
        public protocol Interface: Sendable {
            func operations() async -> [Operation]
            func changes() -> AsyncStream<Void>
        }

        // parity: core/src/config/plugin/source.ts#Service [status=adapted hash=dc585e7cb657]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/ConfigPluginSource"

            private let config: any CoreConfig.Interface
            private let directory: String

            public init(config: any CoreConfig.Interface, directory: String = "/") {
                self.config = config
                self.directory = directory
            }

            public func operations() async -> [Operation] {
                let entries = await config.entries()
                var ops: [Operation] = []
                for entry in entries {
                    guard entry.isDocument, let plugins = entry.info?.plugins else { continue }
                    let baseDir = entry.path.map { CoreConfigDiscovery.dirname($0.rawValue) } ?? directory
                    for plugin in plugins {
                        switch plugin {
                        case .entry(let e):
                            let target = resolveTarget(e.package, baseDir: baseDir)
                            ops.append(.add(target: target, options: e.options ?? [:]))
                        case .specifier(let spec):
                            if spec.hasPrefix("-") {
                                let name = String(spec.dropFirst())
                                if !name.isEmpty { ops.append(.remove(target: name)) }
                            } else {
                                let target = resolveTarget(spec, baseDir: baseDir)
                                ops.append(.add(target: target, options: [:]))
                            }
                        }
                    }
                }
                return ops
            }

            public func changes() -> AsyncStream<Void> {
                AsyncStream { $0.finish() }
            }

            private func resolveTarget(_ raw: String, baseDir: String) -> String {
                if raw.hasPrefix("file://") {
                    return String(raw.dropFirst("file://".count))
                }
                if raw.hasPrefix("./") || raw.hasPrefix("../") {
                    return CoreConfigDiscovery.resolvePath(base: baseDir, relative: raw)
                }
                return raw
            }
        }

        private final class EmptyService: Interface, Sendable {
            func operations() async -> [Operation] { [] }
            func changes() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
        }

        // parity: core/src/config/plugin/source.ts#layer [status=adapted hash=b49d8b9b9101]
        public static let layer: LayerNode.ExecutableLayer = LayerNode.ExecutableLayer { deps, _ in
            let cfg = deps.get(CoreConfig.Service.serviceKey, as: (any CoreConfig.Interface).self) ?? CoreConfig.Test()
            let dir = deps.get("@opencode/Location.directory", as: String.self) ?? "/"
            return LayerNode.Output([Service.serviceKey: Service(config: cfg, directory: dir) as any Interface])
        }

        // parity: core/src/config/plugin/source.ts#node [status=adapted hash=04da21632e3f]
        public static let node: LayerNode.Provider = AppNode.makeLocationNode(
            Service.serviceKey,
            layer,
            [CoreConfig.node, FSUtil.node, CoreFilesystem.Watcher.node]
        )

        // parity: core/src/config/plugin/source.ts#empty [status=adapted hash=84ea884965d4]
        public static let empty: LayerNode.Provider = AppNode.makeLocationNode(
            Service.serviceKey,
            LayerNode.ExecutableLayer.succeed(key: Service.serviceKey, value: EmptyService() as any Interface),
            []
        )
    }

    // MARK: - Domain Config Plugins (All Remaining 18 `src/config/plugin/*.ts` Files)

    public enum Agent {
        // parity: core/src/config/plugin/agent.ts#Plugin [status=adapted hash=381318ebd823]
        public static let Plugin = ModuleDescriptor(id: "opencode.config.agent")
    }

    public enum Command {
        // parity: core/src/config/plugin/command.ts#Plugin [status=adapted hash=c90f8838f4fa]
        public static let Plugin = ModuleDescriptor(id: "opencode.config.command")
    }

    public enum Compaction {
        // parity: core/src/config/plugin/compaction.ts#Plugin [status=adapted hash=c99106074e82]
        public static let Plugin = ModuleDescriptor(id: "opencode.config.compaction")
    }

    public enum Compatibility {
        // parity: core/src/config/plugin/compatibility.ts#Plugin [status=adapted hash=77546d21e439]
        public static let Plugin = ModuleDescriptor(id: "opencode.config.compatibility")
    }

    public enum Formatter {
        // parity: core/src/config/plugin/formatter.ts#Plugin [status=adapted hash=c3f4b95e6fa4]
        public static let Plugin = ModuleDescriptor(id: "opencode.config.formatter")

        public static func apply(
            entries: [CoreConfigEntry],
            to service: any CoreFormatter.Interface,
            makeInput: CoreFormatter.MakeInput
        ) async {
            var resolvedEnabled: Bool? = nil
            var overrides: [String: ConfigFormatterSchema.Entry] = [:]
            for entry in entries {
                guard let fmt = entry.info?.formatter else { continue }
                switch fmt {
                case .enabled(let flag):
                    resolvedEnabled = flag
                    overrides.removeAll()
                case .overrides(let map):
                    resolvedEnabled = nil
                    for (name, item) in map {
                        let prev = overrides[name]
                        var mergedEnv = prev?.environment ?? [:]
                        for (k, v) in item.environment ?? [:] { mergedEnv[k] = v }
                        overrides[name] = ConfigFormatterSchema.Entry(
                            disabled: item.disabled ?? prev?.disabled,
                            command: item.command ?? prev?.command,
                            environment: mergedEnv.isEmpty ? nil : mergedEnv,
                            extensions: item.extensions ?? prev?.extensions
                        )
                    }
                }
            }
            if resolvedEnabled == false { return }
            let builtins = CoreFormatter.make(makeInput)
            let snapshotOverrides = overrides
            let enabledAll = resolvedEnabled == true
            _ = await service.transform { editor in
                for item in builtins { editor.set(item) }
                if enabledAll { return }
                for (name, entry) in snapshotOverrides {
                    if entry.disabled == true {
                        editor.remove(name)
                        continue
                    }
                    let builtIn = builtins.first(where: { $0.name == name })
                    var env = builtIn?.environment ?? [:]
                    for (k, v) in entry.environment ?? [:] { env[k] = v }
                    let cmd = entry.command
                    let info = CoreFormatter.Info(
                        name: name,
                        environment: env.isEmpty ? nil : env,
                        extensions: entry.extensions ?? builtIn?.extensions ?? [],
                        enabled: {
                            if let cmd { return cmd }
                            return await builtIn?.enabled()
                        }
                    )
                    editor.set(info)
                }
            }
        }
    }

    public enum Image {
        // parity: core/src/config/plugin/image.ts#Plugin [status=adapted hash=4b80502b90aa]
        public static let Plugin = ModuleDescriptor(id: "opencode.config.image")
    }

    public enum Instruction {
        /// Ports `core/src/config/plugin/instruction.ts#Plugin`: loads global AGENTS.md (falling back to
        /// `~/.claude/CLAUDE.md`), ancestor project instruction files, and configured paths/globs/URLs,
        /// keeping `InstructionDiscovery` live via debounced file watches and `config.updated` reloads.
        // parity: core/src/config/plugin/instruction.ts#Plugin [status=implemented hash=0a7d4cb2760b]
        public static let Plugin = ModuleDescriptor(id: "opencode.config.instruction")

        /// Feeds one Location's `InstructionDiscovery`: the global AGENTS.md (or `~/.claude/CLAUDE.md` in its
        /// place), the AGENTS.md / CLAUDE.md files from the Location up to the project root (or the home directory
        /// when the Location sits beneath it), and the files, globs, and URLs named by config `instructions` entries.
        ///
        /// Keeps discovery current via `CoreFilesystem.Watcher` (100 ms trailing debounce) and `config.updated`
        /// subscriptions scoped to the Location lifecycle, with a 5-second timeout and concurrency limit of 4 on
        /// remote URL fetches.
        public actor Loader {
            public typealias File = CoreInstruction.Discovery.File

            /// Trailing-edge debounce window for bursty editor saves (upstream: `100 millis`).
            public static let defaultDebounce: Duration = .milliseconds(100)
            /// Timeout per remote instruction URL fetch (upstream: `5 seconds`).
            public static let defaultURLFetchTimeout: Duration = .seconds(5)
            /// Max concurrent remote instruction URL fetches (upstream: `{ concurrency: 4 }`).
            public static let defaultURLFetchConcurrency: Int = 4

            public struct Paths: Sendable {
                public let directory: String
                public let projectDirectory: String
                public let home: String
                public let globalConfig: String

                public init(directory: String, projectDirectory: String, home: String, globalConfig: String) {
                    self.directory = directory
                    self.projectDirectory = projectDirectory
                    self.home = home
                    self.globalConfig = globalConfig
                }
            }

            enum Loaded: Equatable, Sendable {
                case available([File])
                case unavailable
            }

            private enum Read {
                case file(File)
                case missing
                case denied
            }

            private struct Resolved: Sendable {
                let start: String
                let root: String
                let home: String
                let stop: String
                let project: Bool
                let names: [String]
                let globalFiles: [String]
            }

            private enum PatternWatchKey: Hashable, Sendable {
                case directory(base: String, pattern: String)
                case missingChild(parent: String, name: String)
            }

            private final class Current: Sendable {
                let value = Mutex<Loaded>(.available([]))
            }

            private let discovery: CoreInstruction.Discovery.Service
            private let fs: FSUtil.Service
            private let watcher: (any CoreFilesystem.Watcher.Interface)?
            private let http: (any HTTPTransport)?
            private let entries: @Sendable () async -> [CoreConfigEntry]
            private let configUpdates: (@Sendable () -> AsyncStream<Void>)?
            private let paths: Paths
            private let debounce: Duration
            private let urlFetchTimeout: Duration
            private let urlFetchConcurrency: Int

            private let current = Current()
            private var resolved: Resolved?
            private var started = false
            private var closed = false
            private var ready = false
            private var readyWaiters: [CheckedContinuation<Void, Never>] = []

            private var locked = false
            private var lockWaiters: [CheckedContinuation<Void, Never>] = []

            private var registration: CoreState.Registration?
            private var configuredSources: [String] = []
            private var configuredRemote: [String: File] = [:]

            private var candidateWatchTasks: [Task<Void, Never>] = []
            private var configuredFileWatches: [String: Task<Void, Never>] = [:]
            private var configuredPatternWatches: [PatternWatchKey: Task<Void, Never>] = [:]
            private var configUpdateTask: Task<Void, Never>?
            private var debounceTask: Task<Void, Never>?
            private var debounceGeneration: UInt64 = 0
            private var pendingChangeFile: String?

            /// Total number of instruction rescans executed by this loader (initial + watcher/config reloads).
            public private(set) var rescanCount: Int = 0

            public init(
                discovery: CoreInstruction.Discovery.Service,
                paths: Paths,
                fileSystem: any OpenCodeFileSystem,
                watcher: (any CoreFilesystem.Watcher.Interface)? = nil,
                http: (any HTTPTransport)? = nil,
                entries: @escaping @Sendable () async -> [CoreConfigEntry],
                configUpdates: (@Sendable () -> AsyncStream<Void>)? = nil,
                debounce: Duration = Loader.defaultDebounce,
                urlFetchTimeout: Duration = Loader.defaultURLFetchTimeout,
                urlFetchConcurrency: Int = Loader.defaultURLFetchConcurrency
            ) {
                self.discovery = discovery
                self.paths = paths
                self.fs = FSUtil.Service(fileSystem: fileSystem)
                self.watcher = watcher
                self.http = http
                self.entries = entries
                self.configUpdates = configUpdates
                self.debounce = debounce
                self.urlFetchTimeout = urlFetchTimeout
                self.urlFetchConcurrency = max(1, urlFetchConcurrency)
            }

            /// Activates candidate file watches, `config.updated` observation, initial load, and
            /// `InstructionDiscovery` transform registration. Safe to call once per Location lifecycle.
            public func start() async {
                guard !started && !closed else { return }
                started = true
                defer { markReady() }

                let r = await resolve()

                // 1. Subscribe to candidate global & ancestor instruction files before the initial scan.
                if let watcher {
                    var candidateList: [String] = []
                    if discovery.global {
                        candidateList.append(contentsOf: r.globalFiles)
                    }
                    if r.project {
                        for directory in Self.ancestorDirectories(start: r.start, stop: r.stop) {
                            for name in r.names {
                                let file = Self.join(directory, name)
                                if discovery.global || !r.globalFiles.contains(file) {
                                    candidateList.append(file)
                                }
                            }
                        }
                    }
                    for file in Self.unique(candidateList) {
                        if closed || Task.isCancelled { break }
                        let updates = await watcher.subscribe(.file(path: file), onReady: nil)
                        let task = Task { [weak self] in
                            for await update in updates {
                                if Task.isCancelled { break }
                                await self?.publishChange(update.path)
                            }
                        }
                        candidateWatchTasks.append(task)
                    }
                }

                // 2. Subscribe to `config.updated` before the first config read so updates in between still reload.
                if let configUpdates, !closed, !Task.isCancelled {
                    let stream = configUpdates()
                    configUpdateTask = Task { [weak self] in
                        for await _ in stream {
                            if Task.isCancelled { break }
                            await self?.handleConfigUpdated()
                        }
                    }
                }

                if closed || Task.isCancelled {
                    await close()
                    return
                }

                // 3. Perform initial config load, file scan, dynamic configured watch setup, and transform registration.
                await acquireLock()
                await reconfigureLocked()
                await performRefreshLocked(file: nil)
                if !closed && !Task.isCancelled && registration == nil {
                    let currentBox = self.current
                    registration = try? await discovery.transform { editor in
                        switch currentBox.value.withLock({ $0 }) {
                        case .unavailable:
                            editor.unavailable()
                        case .available(let files):
                            for file in files { editor.add(file) }
                        }
                    }
                }
                releaseLock()

                if closed || Task.isCancelled {
                    await close()
                }
            }

            /// Waits until initial activation (`start()`) completes (or the loader is closed).
            /// Once ready, returns immediately without rescanning any files.
            public func awaitReady() async {
                if ready || closed { return }
                await withCheckedContinuation { continuation in
                    if ready || closed {
                        continuation.resume()
                    } else {
                        readyWaiters.append(continuation)
                    }
                }
            }

            /// Stops all file watchers, pending debounce timers, and config subscriptions for this Location.
            public func close() async {
                if closed {
                    markReady()
                    return
                }
                closed = true
                pendingChangeFile = nil
                debounceTask?.cancel()
                debounceTask = nil
                configUpdateTask?.cancel()
                configUpdateTask = nil
                for task in candidateWatchTasks { task.cancel() }
                candidateWatchTasks.removeAll()
                for task in configuredFileWatches.values { task.cancel() }
                configuredFileWatches.removeAll()
                for task in configuredPatternWatches.values { task.cancel() }
                configuredPatternWatches.removeAll()
                let reg = registration
                registration = nil
                markReady()
                if let reg {
                    await reg.dispose()
                }
            }

            /// Explicit manual refresh (for callers/tests driving `Loader` directly without live watchers).
            public func refresh() async {
                guard !closed else { return }
                if !started {
                    await start()
                    return
                }
                await acquireLock()
                let latestSources = Self.unique(
                    (await entries()).flatMap { $0.isDocument ? ($0.info?.instructions ?? []) : [] }
                )
                if configuredSources != latestSources {
                    await reconfigureLocked()
                }
                await performRefreshLocked(file: nil)
                let shouldReload = !closed && registration != nil
                releaseLock()
                if shouldReload {
                    await discovery.reload()
                }
            }

            // MARK: - Internal Reactive Handlers

            private func publishChange(_ path: String) {
                guard !closed else { return }
                pendingChangeFile = path
                debounceGeneration &+= 1
                let generation = debounceGeneration
                debounceTask?.cancel()
                let delay = self.debounce
                debounceTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: delay)
                    } catch {
                        return
                    }
                    await self?.flushDebouncedChange(generation: generation)
                }
            }

            private func flushDebouncedChange(generation: UInt64) async {
                guard !closed, generation == debounceGeneration, let file = pendingChangeFile else { return }
                pendingChangeFile = nil
                debounceTask = nil
                await acquireLock()
                guard !closed else {
                    releaseLock()
                    return
                }
                await performRefreshLocked(file: file)
                let shouldReload = !closed && registration != nil
                releaseLock()
                if shouldReload {
                    await discovery.reload()
                }
            }

            private func handleConfigUpdated() async {
                guard !closed else { return }
                await acquireLock()
                guard !closed else {
                    releaseLock()
                    return
                }
                await reconfigureLocked()
                await performRefreshLocked(file: nil)
                let shouldReload = !closed && registration != nil
                releaseLock()
                if shouldReload {
                    await discovery.reload()
                }
            }

            // MARK: - Synchronization Helpers

            private func markReady() {
                ready = true
                if !readyWaiters.isEmpty {
                    let waiters = readyWaiters
                    readyWaiters.removeAll()
                    for waiter in waiters {
                        waiter.resume()
                    }
                }
            }

            private func acquireLock() async {
                if !locked {
                    locked = true
                    return
                }
                await withCheckedContinuation { continuation in
                    lockWaiters.append(continuation)
                }
            }

            private func releaseLock() {
                if !lockWaiters.isEmpty {
                    let next = lockWaiters.removeFirst()
                    next.resume()
                } else {
                    locked = false
                }
            }

            // MARK: - Resolution & Source Loading

            private func resolve() async -> Resolved {
                if let resolved { return resolved }
                let start = await fs.resolve(paths.directory)
                let root = await fs.resolve(paths.projectDirectory)
                let home = await fs.resolve(paths.home)
                let globalFile = await fs.resolve(Self.join(paths.globalConfig, "AGENTS.md"))
                // ~/.claude/CLAUDE.md stands in for the global AGENTS.md when it is missing.
                let claudeGlobalFile = await fs.resolve(Self.join(Self.join(home, ".claude"), "CLAUDE.md"))
                let value = Resolved(
                    start: start,
                    root: root,
                    home: home,
                    stop: FSPathUtil.contains(parent: home, child: start) ? home : root,
                    project: discovery.project && FSPathUtil.contains(parent: root, child: start),
                    names: CoreInstruction.Discovery.filenames(claude: discovery.claude),
                    globalFiles: discovery.claude ? [globalFile, claudeGlobalFile] : [globalFile]
                )
                resolved = value
                return value
            }

            // A missing file may be mid-save and is transient; a denied file stays absent.
            private func read(_ filepath: String) async -> Read? {
                do {
                    let bytes = try await fs.fileSystem.readFile(at: filepath)
                    return .file(File(path: filepath, content: String(decoding: bytes, as: UTF8.self)))
                } catch let error as PlatformError {
                    if case .notFound = error { return .missing }
                    if FSUtil.isAccessDenied(error) { return .denied }
                    return nil
                } catch {
                    return nil
                }
            }

            private func performRefreshLocked(file: String?) async {
                _ = file
                guard !closed else { return }
                rescanCount += 1
                let r = await resolve()
                let loaded = await load(r)
                current.value.withLock { $0 = loaded }
            }

            private func load(_ r: Resolved) async -> Loaded {
                guard let global = await globalSource(r),
                      let project = await projectSource(r),
                      let configured = await configuredSource(r)
                else { return .unavailable }
                return .available(global + project + configured)
            }

            private func globalSource(_ r: Resolved) async -> [File]? {
                if !discovery.global { return [] }
                for candidate in r.globalFiles {
                    guard await fs.isFile(candidate) else { continue }
                    switch await read(candidate) {
                    case .file(let file): return [file]
                    case .missing, .denied: return []
                    case nil: return nil
                    }
                }
                return []
            }

            private func projectSource(_ r: Resolved) async -> [File]? {
                if !r.project { return [] }
                guard let found = try? await fs.up(FSPathUtil.UpOptions(targets: r.names, start: r.start, stop: r.stop, type: .file)) else {
                    return nil
                }
                var discovered: [String] = []
                for path in CoreInstruction.Discovery.preferAgents(found) {
                    let walked = await fs.resolve(path)
                    // The ancestor walk can reach the global file; global: false excludes it there too.
                    if !discovery.global && r.globalFiles.contains(walked) { continue }
                    if !discovered.contains(walked) { discovered.append(walked) }
                }
                var files: [File] = []
                for path in discovered {
                    switch await read(path) {
                    case .file(let file): files.append(file)
                    case .denied: continue
                    case .missing, nil: return nil
                    }
                }
                return files
            }

            private func configuredSource(_ r: Resolved) async -> [File]? {
                var files: [File] = []
                var watchedFiles: Set<String> = []
                var desiredPatternWatches: Set<PatternWatchKey> = []

                for source in configuredSources {
                    if Self.isURL(source) {
                        if let file = configuredRemote[source] { files.append(file) }
                        continue
                    }
                    let matched = await match(source, r).sorted()
                    for item in matched {
                        let resolved = await fs.resolve(item)
                        if !watchedFiles.insert(resolved).inserted { continue }
                        if case .file(let file) = await read(resolved) { files.append(file) }
                    }
                    if watcher != nil {
                        for key in await patternWatchKeys(for: source, r) {
                            desiredPatternWatches.insert(key)
                        }
                    }
                }

                if let watcher, !closed {
                    // Reconcile per-file watches for currently matched configured files.
                    for (key, task) in configuredFileWatches where !watchedFiles.contains(key) {
                        task.cancel()
                        configuredFileWatches.removeValue(forKey: key)
                    }
                    for file in watchedFiles.sorted() where configuredFileWatches[file] == nil {
                        if closed || Task.isCancelled { break }
                        let updates = await watcher.subscribe(.file(path: file), onReady: nil)
                        configuredFileWatches[file] = Task { [weak self] in
                            for await update in updates {
                                if Task.isCancelled { break }
                                await self?.publishChange(update.path)
                            }
                        }
                    }

                    // Reconcile glob/pattern directory watches so configured globs gaining new matches trigger refresh.
                    for (key, task) in configuredPatternWatches where !desiredPatternWatches.contains(key) {
                        task.cancel()
                        configuredPatternWatches.removeValue(forKey: key)
                    }
                    for key in desiredPatternWatches where configuredPatternWatches[key] == nil {
                        if closed || Task.isCancelled { break }
                        switch key {
                        case let .directory(base, pattern):
                            let updates = await watcher.subscribe(
                                .directory(path: base, ignore: FSPathUtil.ignoreGlobs),
                                onReady: nil
                            )
                            configuredPatternWatches[key] = Task { [weak self] in
                                for await update in updates {
                                    if Task.isCancelled { break }
                                    if Self.patternWatchMatches(update: update, base: base, pattern: pattern) {
                                        await self?.publishChange(update.path)
                                    }
                                }
                            }
                        case let .missingChild(parent, name):
                            let updates = await watcher.subscribe(.entries(path: parent, names: [name]), onReady: nil)
                            configuredPatternWatches[key] = Task { [weak self] in
                                for await update in updates {
                                    if Task.isCancelled { break }
                                    await self?.publishChange(update.path)
                                }
                            }
                        }
                    }
                }

                return files
            }

            /// Remote instructions are fetched only when config loads (or on `config.updated`), never on file
            /// rescans. Each fetch enforces a 5-second timeout with concurrency 4; a failed or timed-out fetch
            /// keeps the last good copy or omits the URL without marking the instruction set unavailable.
            private func reconfigureLocked() async {
                let rawEntries = await entries()
                let sources = Self.unique(
                    rawEntries.flatMap { $0.isDocument ? ($0.info?.instructions ?? []) : [] }
                )
                let urls = sources.filter(Self.isURL)
                let previousRemote = configuredRemote
                var nextRemote: [String: File] = [:]

                if let http, !urls.isEmpty {
                    let maxConcurrency = max(1, urlFetchConcurrency)
                    let timeout = urlFetchTimeout
                    var results = Array<File?>(repeating: nil, count: urls.count)
                    await withTaskGroup(of: (Int, File?).self) { group in
                        var nextIndex = 0
                        func enqueueNext() {
                            guard nextIndex < urls.count else { return }
                            let idx = nextIndex
                            let url = urls[idx]
                            nextIndex += 1
                            group.addTask {
                                let file = await Self.fetchWithTimeout(url: url, http: http, timeout: timeout)
                                return (idx, file)
                            }
                        }
                        for _ in 0..<min(maxConcurrency, urls.count) {
                            enqueueNext()
                        }
                        while let (idx, file) = await group.next() {
                            results[idx] = file
                            enqueueNext()
                        }
                    }
                    for (idx, url) in urls.enumerated() {
                        if let file = results[idx] {
                            nextRemote[url] = file
                        } else if let previous = previousRemote[url] {
                            nextRemote[url] = previous
                        }
                    }
                } else {
                    for url in urls {
                        if let previous = previousRemote[url] {
                            nextRemote[url] = previous
                        }
                    }
                }

                configuredSources = sources
                configuredRemote = nextRemote
            }

            private static func fetchWithTimeout(
                url: String,
                http: any HTTPTransport,
                timeout: Duration
            ) async -> File? {
                final class RaceBox: Sendable {
                    struct State: Sendable {
                        var completed = false
                        var continuation: CheckedContinuation<File?, Never>?
                        var fetchTask: Task<Void, Never>?
                        var timeoutTask: Task<Void, Never>?
                    }

                    let state = Mutex(State())

                    func resolve(_ value: File?) {
                        let (cont, fetchTask, timeoutTask) = state.withLock { s -> (
                            CheckedContinuation<File?, Never>?,
                            Task<Void, Never>?,
                            Task<Void, Never>?
                        ) in
                            guard !s.completed else { return (nil, nil, nil) }
                            s.completed = true
                            let c = s.continuation
                            s.continuation = nil
                            let f = s.fetchTask
                            let t = s.timeoutTask
                            s.fetchTask = nil
                            s.timeoutTask = nil
                            return (c, f, t)
                        }
                        fetchTask?.cancel()
                        timeoutTask?.cancel()
                        cont?.resume(returning: value)
                    }
                }

                let box = RaceBox()
                return await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        let alreadyDone = box.state.withLock { s -> Bool in
                            if s.completed { return true }
                            s.continuation = continuation
                            return false
                        }
                        if alreadyDone {
                            continuation.resume(returning: nil)
                            return
                        }
                        let fetchTask = Task {
                            defer { box.resolve(nil) }
                            guard !Task.isCancelled else { return }
                            guard let response = try? await http.send(HTTPRequest(method: "GET", url: url)),
                                  !Task.isCancelled,
                                  (200..<300).contains(response.head.statusCode)
                            else {
                                return
                            }
                            let file = File(path: url, content: String(decoding: response.body, as: UTF8.self))
                            box.resolve(file)
                        }
                        let timeoutTask = Task {
                            do {
                                try await Task.sleep(for: timeout)
                            } catch {
                                return
                            }
                            box.resolve(nil)
                        }
                        let cancelNow = box.state.withLock { s -> Bool in
                            if s.completed { return true }
                            s.fetchTask = fetchTask
                            s.timeoutTask = timeoutTask
                            return false
                        }
                        if cancelNow {
                            fetchTask.cancel()
                            timeoutTask.cancel()
                        }
                    }
                } onCancel: {
                    box.resolve(nil)
                }
            }

            // Relative patterns search upward from the location to the project root. Without project discovery
            // they resolve against the global config directory instead.
            private func match(_ source: String, _ r: Resolved) async -> [String] {
                let expanded = Self.expandSource(source, home: r.home)
                func options(_ cwd: String) -> Glob.Options {
                    Glob.Options(cwd: cwd, absolute: true, include: .file, dot: true)
                }
                if Self.isAbsolutePath(expanded) {
                    if !Self.hasGlob(expanded) { return await fs.isFile(expanded) ? [expanded] : [] }
                    let directory = Self.dirname(expanded)
                    if await fs.isDir(directory) {
                        return (try? await fs.scan(pattern: Self.basename(expanded), options: options(directory))) ?? []
                    }
                    // No literal parent (`~/notes/**/*.md`): scan from the longest literal prefix.
                    let (base, rest) = Self.literalPrefix(expanded)
                    return (try? await fs.scan(pattern: rest, options: options(base))) ?? []
                }
                if r.project {
                    if Self.hasGlob(expanded) {
                        return (try? await fs.globUp(pattern: expanded, start: r.start, stop: r.root)) ?? []
                    }
                    var found: [String] = []
                    for directory in Self.ancestorDirectories(start: r.start, stop: r.root) {
                        let candidate = Self.join(directory, expanded)
                        if await fs.isFile(candidate) { found.append(candidate) }
                    }
                    return found
                }
                if !discovery.global { return [] }
                if !Self.hasGlob(expanded) {
                    let candidate = Self.join(paths.globalConfig, expanded)
                    return await fs.isFile(candidate) ? [candidate] : []
                }
                return (try? await fs.scan(pattern: expanded, options: options(paths.globalConfig))) ?? []
            }

            private func resolveGlobWatchKey(_ fullPattern: String, stopAt anchor: String?) async -> PatternWatchKey? {
                let (literalBase, rest) = Self.literalPrefix(fullPattern)
                if await fs.isDir(literalBase) {
                    let resolvedBase = await fs.resolve(literalBase)
                    return resolvedBase != "/" ? .directory(base: resolvedBase, pattern: rest) : nil
                }
                // Literal directory does not exist yet: watch the nearest existing ancestor for its first missing child.
                var missing = literalBase
                while true {
                    let parent = Self.dirname(missing)
                    if parent == missing { break }
                    if await fs.isDir(parent) {
                        let resolvedParent = await fs.resolve(parent)
                        let childName = Self.basename(missing)
                        if !childName.isEmpty {
                            return .missingChild(parent: resolvedParent, name: childName)
                        }
                        break
                    }
                    if let anchor, sameDirectory(parent, anchor) { break }
                    missing = parent
                }
                return nil
            }

            private func patternWatchKeys(for source: String, _ r: Resolved) async -> [PatternWatchKey] {
                let expanded = Self.expandSource(source, home: r.home)
                guard Self.hasGlob(expanded) else { return [] }

                var keys: [PatternWatchKey] = []
                if Self.isAbsolutePath(expanded) {
                    if let key = await resolveGlobWatchKey(expanded, stopAt: nil) {
                        keys.append(key)
                    }
                } else if r.project {
                    for directory in Self.ancestorDirectories(start: r.start, stop: r.root) {
                        if let key = await resolveGlobWatchKey(Self.join(directory, expanded), stopAt: directory) {
                            keys.append(key)
                        }
                    }
                } else if discovery.global {
                    let resolvedGlobal = await fs.resolve(paths.globalConfig)
                    if let key = await resolveGlobWatchKey(Self.join(resolvedGlobal, expanded), stopAt: resolvedGlobal) {
                        keys.append(key)
                    }
                }
                return keys
            }

            private static func patternWatchMatches(
                update: CoreFilesystem.Watcher.Update,
                base: String,
                pattern: String
            ) -> Bool {
                let normalizedUpdate = update.path.replacing("\\", with: "/")
                let normalizedBase = base.replacing("\\", with: "/")
                guard let rel = relativeSuffix(of: normalizedUpdate, under: normalizedBase), !rel.isEmpty else {
                    return update.type == .delete
                }
                if Glob.match(pattern, filepath: rel, dot: true) {
                    return true
                }
                // Directory deletion may remove matched files inside it without individual child events.
                if update.type == .delete && !rel.contains(".") {
                    return true
                }
                return false
            }

            private static func relativeSuffix(of path: String, under base: String) -> String? {
                if path == base { return "" }
                let prefix = base.hasSuffix("/") ? base : base + "/"
                guard path.hasPrefix(prefix) else { return nil }
                return String(path.dropFirst(prefix.count))
            }

            // `start` keeps the client's spelling while `stop` may come from git, so a Windows drive
            // letter can differ only in case (`c:\repo` vs `C:\repo`). Compare with `sameDirectory`
            // and stop at filesystem root as a safety bound.
            private static func ancestorDirectories(start: String, stop: String) -> [String] {
                var dirs: [String] = []
                var current = start
                while true {
                    dirs.append(current)
                    if sameDirectory(current, stop) { break }
                    let parent = dirname(current)
                    if parent == current { break }
                    current = parent
                }
                return dirs
            }

            private static func expandSource(_ source: String, home: String) -> String {
                let normalized = source.replacing("\\", with: "/")
                if normalized.hasPrefix("~/") {
                    return join(home, String(normalized.dropFirst(2)))
                }
                return normalized
            }

            private static func isAbsolutePath(_ path: String) -> Bool {
                if path.hasPrefix("/") { return true }
                let chars = Array(path)
                guard chars.count >= 2, let ascii = chars[0].asciiValue else { return false }
                let isAlpha = (ascii >= 65 && ascii <= 90) || (ascii >= 97 && ascii <= 122)
                return isAlpha && chars[1] == ":"
            }

            private static func unique(_ values: [String]) -> [String] {
                var seen: Set<String> = []
                return values.filter { seen.insert($0).inserted }
            }

            private static func isURL(_ source: String) -> Bool {
                let lower = source.lowercased()
                let rest: Substring
                if lower.hasPrefix("https://") {
                    rest = source.dropFirst("https://".count)
                } else if lower.hasPrefix("http://") {
                    rest = source.dropFirst("http://".count)
                } else {
                    return false
                }
                let authority = rest.split(separator: "/", maxSplits: 1).first ?? ""
                return !authority.isEmpty && !authority.contains(where: \.isWhitespace)
            }

            private static func hasGlob(_ pattern: String) -> Bool {
                pattern.contains { "*?[]{}".contains($0) }
            }

            private static func join(_ base: String, _ child: String) -> String {
                if child.isEmpty { return base }
                return base.hasSuffix("/") ? base + child : base + "/" + child
            }

            private static func dirname(_ path: String) -> String {
                var p = path
                while p.count > 1 && p.hasSuffix("/") {
                    if p.count == 3 && isAbsolutePath(p) && p.dropFirst().hasPrefix(":/") { break }
                    p.removeLast()
                }
                guard let index = p.lastIndex(of: "/") else { return "." }
                if index == p.startIndex { return "/" }
                return String(p[..<index])
            }

            private static func basename(_ path: String) -> String {
                guard let index = path.lastIndex(of: "/") else { return path }
                return String(path[path.index(after: index)...])
            }

            private static func literalPrefix(_ path: String) -> (base: String, rest: String) {
                let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                var base: [String] = []
                var index = 0
                while index < segments.count - 1, !hasGlob(segments[index]) {
                    base.append(segments[index])
                    index += 1
                }
                let joined = base.joined(separator: "/")
                return (joined.isEmpty ? "/" : joined, segments[index...].joined(separator: "/"))
            }
        }
    }

    public enum LocationWatcher {
        // parity: core/src/config/plugin/location-watcher.ts#Plugin [status=implemented hash=85f37e173177]
        public static let Plugin = ModuleDescriptor(id: "opencode.config.location-watcher")

        /// Live observer keeping `LocationWatcherPolicy` synchronized with config `watcher.ignore` entries
        /// on initial load and every `config.updated` bus event (matching `ConfigEntryObserver.observe`).
        public final class Observer: Sendable {
            private struct State: Sendable {
                var entries: [CoreConfigEntry]
                var task: Task<Void, Never>?
                var registration: CoreFilesystem.LocationWatcherPolicy.Registration?
                var closed: Bool = false
            }

            private let state: Mutex<State>
            private let config: any CoreConfig.Interface
            private let policy: any CoreFilesystem.LocationWatcherPolicy.Interface

            private init(
                initial: [CoreConfigEntry],
                config: any CoreConfig.Interface,
                policy: any CoreFilesystem.LocationWatcherPolicy.Interface
            ) {
                self.state = Mutex(State(entries: initial))
                self.config = config
                self.policy = policy
            }

            deinit {
                let (task, reg) = state.withLock { s -> (Task<Void, Never>?, CoreFilesystem.LocationWatcherPolicy.Registration?) in
                    s.closed = true
                    let t = s.task
                    let r = s.registration
                    s.task = nil
                    s.registration = nil
                    return (t, r)
                }
                task?.cancel()
                reg?.dispose()
            }

            fileprivate static func start(
                config: any CoreConfig.Interface,
                bus: (any CoreBus.Interface)?,
                location: OpenCodeLocation?,
                policy: any CoreFilesystem.LocationWatcherPolicy.Interface
            ) async -> Observer {
                // Subscribe before reading initial entries so an update in between still triggers a reload.
                let updates = bus?.subscribe(types: [ConfigSchema.Event.updated.type], location: location)
                let initial = await config.entries()
                let observer = Observer(initial: initial, config: config, policy: policy)

                let registration = await policy.transform { [weak observer] editor in
                    guard let entries = observer?.state.withLock({ $0.entries }) else { return }
                    for entry in entries {
                        guard entry.isDocument, let ignore = entry.info?.watcher?.ignore else { continue }
                        editor.add(ignore)
                    }
                }

                let task: Task<Void, Never>?
                if let updates {
                    task = Task { [weak observer] in
                        for await _ in updates {
                            if Task.isCancelled { break }
                            guard let observer else { break }
                            let nextEntries = await observer.config.entries()
                            let stillOpen = observer.state.withLock { s -> Bool in
                                guard !s.closed else { return false }
                                s.entries = nextEntries
                                return true
                            }
                            if stillOpen {
                                await observer.policy.reload()
                            }
                        }
                    }
                } else {
                    task = nil
                }

                let cancelIfClosed: (Task<Void, Never>?, CoreFilesystem.LocationWatcherPolicy.Registration?)? = observer.state.withLock { s in
                    if s.closed { return (task, registration) }
                    s.task = task
                    s.registration = registration
                    return nil
                }
                if let (t, r) = cancelIfClosed {
                    t?.cancel()
                    r?.dispose()
                }
                return observer
            }

            /// Stops observing `config.updated` and removes the transform registration from `LocationWatcherPolicy`.
            public func close() async {
                let (task, reg) = state.withLock { s -> (Task<Void, Never>?, CoreFilesystem.LocationWatcherPolicy.Registration?) in
                    s.closed = true
                    let t = s.task
                    let r = s.registration
                    s.task = nil
                    s.registration = nil
                    return (t, r)
                }
                task?.cancel()
                reg?.dispose()
            }
        }

        /// Starts live synchronization of `watcher.ignore` config entries into `policy`.
        public static func start(
            config: any CoreConfig.Interface,
            bus: (any CoreBus.Interface)? = nil,
            location: OpenCodeLocation? = nil,
            policy: any CoreFilesystem.LocationWatcherPolicy.Interface
        ) async -> Observer {
            await Observer.start(config: config, bus: bus, location: location, policy: policy)
        }

        public static func apply(
            entries: [CoreConfigEntry],
            to policy: any CoreFilesystem.LocationWatcherPolicy.Interface
        ) async {
            let ignores = entries.flatMap { $0.isDocument ? ($0.info?.watcher?.ignore ?? []) : [] }
            _ = await policy.transform { editor in
                editor.add(ignores)
            }
        }
    }

    public enum Mcp {
        // parity: core/src/config/plugin/mcp.ts#Plugin [status=adapted hash=035484776ba1]
        public static let Plugin = ModuleDescriptor(id: "opencode.config.mcp")

        /// Merges global MCP timeouts and per-server MCP configs across ordered config entries.
        // parity: core/src/config/plugin/mcp.ts#register [status=adapted hash=083699dda3ee]
        public static func register(entries: [CoreConfigEntry]) -> [String: McpSchema.ServerConfig] {
            var startup: SchemaPrimitive.PositiveInt? = nil
            var catalog: SchemaPrimitive.PositiveInt? = nil
            var execution: SchemaPrimitive.PositiveInt? = nil
            var servers: [String: McpSchema.ServerConfig] = [:]

            for entry in entries {
                guard let mcp = entry.info?.mcp else { continue }
                if let t = mcp.timeout {
                    if let v = t.startup { startup = v }
                    if let v = t.catalog { catalog = v }
                    if let v = t.execution { execution = v }
                }
                for (name, server) in mcp.servers ?? [:] {
                    servers[name] = server
                }
            }

            let globalTimeout = McpSchema.TimeoutConfig(startup: startup, catalog: catalog, execution: execution)
            var resolved: [String: McpSchema.ServerConfig] = [:]
            for (name, server) in servers {
                switch server {
                case .local(let cfg):
                    let merged = McpSchema.TimeoutConfig(
                        startup: cfg.timeout?.startup ?? globalTimeout.startup,
                        catalog: cfg.timeout?.catalog ?? globalTimeout.catalog,
                        execution: cfg.timeout?.execution ?? globalTimeout.execution
                    )
                    resolved[name] = .local(McpSchema.LocalConfig(
                        command: cfg.command,
                        cwd: cfg.cwd,
                        environment: cfg.environment,
                        disabled: cfg.disabled,
                        codemode: cfg.codemode,
                        timeout: merged,
                        wireProtocol: cfg.wireProtocol,
                        pool: cfg.pool
                    ))
                case .remote(let cfg):
                    let merged = McpSchema.TimeoutConfig(
                        startup: cfg.timeout?.startup ?? globalTimeout.startup,
                        catalog: cfg.timeout?.catalog ?? globalTimeout.catalog,
                        execution: cfg.timeout?.execution ?? globalTimeout.execution
                    )
                    resolved[name] = .remote(McpSchema.RemoteConfig(
                        url: cfg.url,
                        headers: cfg.headers,
                        oauth: cfg.oauth,
                        disabled: cfg.disabled,
                        codemode: cfg.codemode,
                        timeout: merged,
                        wireProtocol: cfg.wireProtocol,
                        pool: cfg.pool
                    ))
                }
            }
            return resolved
        }
    }

    public enum Policy {
        // parity: core/src/config/plugin/policy.ts#Plugin [status=adapted hash=33965854bd6d]
        public static let Plugin = ModuleDescriptor(id: "opencode.config.policy")

        /// Evaluates `tool.use` managed policies on a permission hook event (`action:resource`).
        public static func evaluatePermissionHook(
            entries: [CoreConfigEntry],
            event: CorePermission.EvaluateHookEvent
        ) -> CorePermission.EvaluateHookEvent {
            let statements = CoreManagedPolicy.statements(entries)
            let ignoreCase = CorePermission.ignoresCase(event.action)
            for resource in event.resources {
                let key = "\(event.action):\(resource)"
                for policy in statements.reversed() {
                    if policy.action == .toolUse &&
                        CorePermissionWildcard.match(key, pattern: policy.resource, ignoreCase: ignoreCase)
                    {
                        if policy.effect == .deny {
                            var updated = event
                            updated.effect = .deny
                            updated.message = policy.message
                            return updated
                        }
                        break
                    }
                }
            }
            return event
        }
    }

    public enum Provider {
        // parity: core/src/config/plugin/provider.ts#Plugin [status=adapted hash=0b464e7e38fb]
        public static let Plugin = ModuleDescriptor(id: "opencode.config.provider")

        /// Extracts configured providers from an integration document, keyed by provider ID.
        // parity: core/src/config/plugin/provider.ts#integrate [status=adapted hash=0b7b38cbf747]
        public static func integrate(
            document: CoreConfigIntegration.Document
        ) -> [String: ConfigProviderSchema.Info] {
            document.info.providers ?? [:]
        }
    }

    public enum Reference {
        // parity: core/src/config/plugin/reference.ts#Plugin [status=adapted hash=97d1aee11d4e]
        public static let Plugin = ModuleDescriptor(id: "opencode.config.reference")
    }

    public enum Shell {
        // parity: core/src/config/plugin/shell.ts#Plugin [status=adapted hash=7f1efab0dc8e]
        public static let Plugin = ModuleDescriptor(id: "opencode.config.shell")

        public static func apply(
            entries: [CoreConfigEntry],
            to service: any CoreShell.Select.Interface
        ) async {
            if let configured = CoreConfig.latest(entries, \.shell) {
                _ = await service.transform { editor in
                    editor.configure(configured)
                }
            }
        }
    }

    public enum Skill {
        // parity: core/src/config/plugin/skill.ts#Plugin [status=adapted hash=5a1f7a0301fc]
        public static let Plugin = ModuleDescriptor(id: "opencode.config.skill")
    }

    public enum Snapshot {
        // parity: core/src/config/plugin/snapshot.ts#Plugin [status=adapted hash=6a78b10cf21a]
        public static let Plugin = ModuleDescriptor(id: "opencode.config.snapshot")

        public static func apply(
            entries: [CoreConfigEntry],
            to service: any CoreSnapshot.Interface
        ) async {
            if let enabled = CoreConfig.latest(entries, \.snapshots) {
                _ = await service.transform { editor in
                    editor.configure(enabled)
                }
            }
        }
    }

    public enum ToolOutput {
        // parity: core/src/config/plugin/tool-output.ts#Plugin [status=adapted hash=17bdb56d4bbf]
        public static let Plugin = ModuleDescriptor(id: "opencode.config.tool-output")

        public static func apply(
            entries: [CoreConfigEntry],
            to service: any CoreToolOutput.Interface
        ) async {
            if let cfg = CoreConfig.latest(entries, \.toolOutput) {
                let maxLines = cfg.maxLines?.rawValue
                let maxBytes = cfg.maxBytes?.rawValue
                _ = await service.transform { editor in
                    editor.configure(maxLines: maxLines, maxBytes: maxBytes)
                }
            }
        }
    }

    public enum WebSearch {
        // parity: core/src/config/plugin/websearch.ts#Plugin [status=adapted hash=c13f572e87cc]
        public static let Plugin = ModuleDescriptor(id: "opencode.config.websearch")
    }

    public enum Worktree {
        // parity: core/src/config/plugin/worktree.ts#Plugin [status=adapted hash=86faf031b6f0]
        public static let Plugin = ModuleDescriptor(id: "opencode.config.worktree")
    }
}
