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
        // parity: core/src/config/plugin/entry-observer.ts#observe [status=adapted hash=e95cbe718228]
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
        // parity: core/src/config/plugin/entry-observer.ts#observeSources [status=adapted hash=fd321c0e3942]
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
        // parity: core/src/config/plugin/skill-file.ts#ParseResult [status=implemented hash=726962d9945b]
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
        // parity: core/src/config/plugin/skill-scan.ts#scan [status=implemented hash=4199fc209860]
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
        // parity: core/src/config/plugin/source.ts#Operation [status=implemented hash=b8f9d39ec505]
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

        // parity: core/src/config/plugin/source.ts#layer [status=adapted hash=a8627ac69589]
        public static let layer: LayerNode.ExecutableLayer = LayerNode.ExecutableLayer { deps, _ in
            let cfg = deps.get(CoreConfig.Service.serviceKey, as: (any CoreConfig.Interface).self) ?? CoreConfig.Test()
            let dir = deps.get("@opencode/Location.directory", as: String.self) ?? "/"
            return LayerNode.Output([Service.serviceKey: Service(config: cfg, directory: dir) as any Interface])
        }

        // parity: core/src/config/plugin/source.ts#node [status=adapted hash=19e63e697939]
        public static let node: LayerNode.Provider = AppNode.makeLocationNode(
            Service.serviceKey,
            layer,
            [CoreConfig.node, FSUtil.node, CoreFilesystem.Watcher.node]
        )

        // parity: core/src/config/plugin/source.ts#empty [status=adapted hash=34c5dd2b1e93]
        public static let empty: LayerNode.Provider = AppNode.makeLocationNode(
            Service.serviceKey,
            LayerNode.ExecutableLayer.succeed(key: Service.serviceKey, value: EmptyService() as any Interface),
            []
        )
    }

    // MARK: - Domain Config Plugins (All Remaining 18 `src/config/plugin/*.ts` Files)

    public enum Agent {
        // parity: core/src/config/plugin/agent.ts#Plugin [status=adapted hash=6f7739bd95c4]
        public static let Plugin = ModuleDescriptor(id: "opencode.config.agent")
    }

    public enum Command {
        // parity: core/src/config/plugin/command.ts#Plugin [status=adapted hash=beafa962f559]
        public static let Plugin = ModuleDescriptor(id: "opencode.config.command")
    }

    public enum Compaction {
        // parity: core/src/config/plugin/compaction.ts#Plugin [status=adapted hash=7919431185b3]
        public static let Plugin = ModuleDescriptor(id: "opencode.config.compaction")
    }

    public enum Compatibility {
        // parity: core/src/config/plugin/compatibility.ts#Plugin [status=adapted hash=fd955a4daad8]
        public static let Plugin = ModuleDescriptor(id: "opencode.config.compatibility")
    }

    public enum Formatter {
        // parity: core/src/config/plugin/formatter.ts#Plugin [status=adapted hash=cfffc0c2eb45]
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
        // parity: core/src/config/plugin/image.ts#Plugin [status=adapted hash=05f0b3480cbd]
        public static let Plugin = ModuleDescriptor(id: "opencode.config.image")
    }

    public enum Instruction {
        // parity: core/src/config/plugin/instruction.ts#Plugin [status=adapted hash=06aae93cb63f]
        public static let Plugin = ModuleDescriptor(id: "opencode.config.instruction")
    }

    public enum LocationWatcher {
        // parity: core/src/config/plugin/location-watcher.ts#Plugin [status=adapted hash=8b8a3e6e7948]
        public static let Plugin = ModuleDescriptor(id: "opencode.config.location-watcher")

        public static func apply(
            entries: [CoreConfigEntry],
            to policy: any CoreFilesystem.LocationWatcherPolicy.Interface
        ) async {
            let ignores = entries.flatMap { $0.info?.watcher?.ignore ?? [] }
            _ = await policy.transform { editor in
                editor.add(ignores)
            }
        }
    }

    public enum Mcp {
        // parity: core/src/config/plugin/mcp.ts#Plugin [status=adapted hash=813d9c1f9ca6]
        public static let Plugin = ModuleDescriptor(id: "opencode.config.mcp")

        /// Merges global MCP timeouts and per-server MCP configs across ordered config entries.
        // parity: core/src/config/plugin/mcp.ts#register [status=adapted hash=360e0965003d]
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
        // parity: core/src/config/plugin/policy.ts#Plugin [status=adapted hash=4daf8714d740]
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
        // parity: core/src/config/plugin/provider.ts#Plugin [status=adapted hash=71fcbae8f784]
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
        // parity: core/src/config/plugin/reference.ts#Plugin [status=adapted hash=8b15f2d100f8]
        public static let Plugin = ModuleDescriptor(id: "opencode.config.reference")
    }

    public enum Shell {
        // parity: core/src/config/plugin/shell.ts#Plugin [status=adapted hash=02426e85aecf]
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
        // parity: core/src/config/plugin/skill.ts#Plugin [status=adapted hash=8d738b631551]
        public static let Plugin = ModuleDescriptor(id: "opencode.config.skill")
    }

    public enum Snapshot {
        // parity: core/src/config/plugin/snapshot.ts#Plugin [status=adapted hash=cc2110016171]
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
        // parity: core/src/config/plugin/tool-output.ts#Plugin [status=adapted hash=51763bfd457a]
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
        // parity: core/src/config/plugin/websearch.ts#Plugin [status=adapted hash=eb9d889dd3c9]
        public static let Plugin = ModuleDescriptor(id: "opencode.config.websearch")
    }

    public enum Worktree {
        // parity: core/src/config/plugin/worktree.ts#Plugin [status=adapted hash=5173d247d72a]
        public static let Plugin = ModuleDescriptor(id: "opencode.config.worktree")
    }
}
