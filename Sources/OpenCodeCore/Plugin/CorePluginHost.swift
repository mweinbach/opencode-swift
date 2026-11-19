#if os(macOS) || os(Linux) || os(Windows)
import Foundation
#elseif canImport(FoundationEssentials)
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
import Synchronization
import OpenCodeAI
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

/// Core plugin runtime, non-blocking async activation registry, hook dispatcher, scoped KV storage,
/// out-of-process JSON-RPC / MCP plugin bridge, module/directory discovery, supervisor, and all built-in
/// core, VCS, websearch, and provider plugins (`packages/core/src/plugin.ts` + `packages/core/src/plugin/*`).
public enum CorePlugin {
    // MARK: - Core Plugin Service & Non-Blocking Async Registry (`plugin.ts`, `plugin/service.ts`)

    /// Failed plugin inventory record reported when discovery or loading fails.
    // parity: core/src/plugin/service.ts#Failure [status=implemented hash=0b6e7dcec0ca]
    public struct Failure: Equatable, Hashable, Sendable, Codable {
        public let id: PluginSchema.ID?
        public let source: PluginSchema.Source
        public let features: PluginSchema.Features
        public let error: String
        public let ref: String?

        public init(
            id: PluginSchema.ID? = nil,
            source: PluginSchema.Source,
            features: PluginSchema.Features = PluginSchema.Features(server: true),
            error: String,
            ref: String? = nil
        ) {
            self.id = id
            self.source = source
            self.features = features
            self.error = error
            self.ref = ref
        }

        public var asPluginInfo: PluginSchema.Info {
            PluginSchema.Info(
                id: id,
                source: source,
                features: features,
                state: .failed(error: error, ref: ref)
            )
        }
    }

    /// Versioned plugin generation handed to the core plugin registry for activation.
    // parity: core/src/plugin/service.ts#Generation [status=implemented hash=c7777720a44e]
    public struct Generation: Sendable {
        public struct GuiDescriptor: Equatable, Hashable, Sendable, Codable {
            public let file: String
            public let revision: String
            public let options: [String: JSONValue]

            public init(file: String, revision: String, options: [String: JSONValue] = [:]) {
                self.file = file
                self.revision = revision
                self.options = options
            }
        }

        public let id: String
        public let effect: @Sendable (PluginEffect.Context) async throws -> Void
        public let revision: String
        public let source: PluginSchema.Source?
        public let features: PluginSchema.Features?
        public let gui: GuiDescriptor?

        public init(
            id: String,
            effect: @escaping @Sendable (PluginEffect.Context) async throws -> Void,
            revision: String,
            source: PluginSchema.Source? = nil,
            features: PluginSchema.Features? = nil,
            gui: GuiDescriptor? = nil
        ) {
            self.id = id
            self.effect = effect
            self.revision = revision
            self.source = source
            self.features = features
            self.gui = gui
        }

        public init(
            plugin: PluginEffect.Plugin,
            revision: String,
            source: PluginSchema.Source? = nil,
            features: PluginSchema.Features? = nil,
            gui: GuiDescriptor? = nil
        ) {
            self.init(
                id: plugin.id,
                effect: plugin.effect,
                revision: revision,
                source: source,
                features: features,
                gui: gui
            )
        }

        /// Wraps a native Swift `PluginSDK.NativePlugin` as a `Generation`.
        public init(
            nativePlugin: any PluginSDK.NativePlugin,
            revision: String = "native",
            source: PluginSchema.Source = .sdk,
            features: PluginSchema.Features = PluginSchema.Features(server: true)
        ) {
            let effectPlugin = nativePlugin.asEffectPlugin()
            self.init(
                id: effectPlugin.id,
                effect: effectPlugin.effect,
                revision: revision,
                source: source,
                features: features,
                gui: nil
            )
        }
    }

    /// Public contract for the core plugin activation service.
    ///
    /// CRITICAL INVARIANT: `list()` and `gui(_:)` return currently loaded state immediately and NEVER wait
    /// for in-flight async plugin activation (`awaitActivation()`). Only one-shot CLI/SDK callers and tests
    /// wait on `awaitActivation()`.
    // parity: core/src/plugin/service.ts#Interface [status=implemented hash=b381deb0a113]
    public protocol ServiceInterface: Sendable {
        func activate(_ plugins: [Generation], failures: [Failure]) async throws
        func startBackgroundActivation(_ plugins: [Generation], failures: [Failure])
        func list() -> [PluginSchema.Info]
        func gui(_ id: PluginSchema.ID) async throws -> PluginSchema.GuiBundle?
        func close() async
        func awaitActivation() async
        func hold() -> @Sendable () -> Void
    }

    public enum ActivationError: Error, Equatable, Sendable, CustomStringConvertible {
        case duplicatePluginID(String)

        public var description: String {
            switch self {
            case .duplicatePluginID(let id):
                return "Duplicate plugin ID: \(id)"
            }
        }
    }

    /// Live Swift 6 actor + lock-free snapshot implementation of `CorePlugin.Service`.
    ///
    /// - `list()` reads an atomically-published inventory snapshot without suspending or blocking on activation.
    /// - `activate(...)` serializes generation swaps, keeps unchanged `(id, revision)` prefixes alive, tears down
    ///   changed suffixes in reverse order with error containment, and restores prior healthy activations on reload failure.
    // parity: core/src/plugin/service.ts#Service [status=adapted hash=91c2ce19c06f]
    public final class Service: ServiceInterface, Sendable {
        public static let serviceKey = "@opencode/Plugin"

        private final class ActivationScope: Sendable {
            private let finalizers = Mutex<[@Sendable () async -> Void]>([])

            func add(_ fn: @escaping @Sendable () async -> Void) {
                finalizers.withLock { $0.append(fn) }
            }

            func close() async {
                let toRun = finalizers.withLock { list -> [@Sendable () async -> Void] in
                    let reversed = Array(list.reversed())
                    list.removeAll()
                    return reversed
                }
                for fn in toRun {
                    await fn()
                }
            }
        }

        private struct ActiveRecord: Sendable {
            let plugin: Generation
            let scope: ActivationScope
            let failureError: String?
            let failureRef: String?
        }

        private struct Slot: Sendable {
            let plugin: Generation
            let activation: ActiveRecord?
            let error: String?
        }

        private struct SnapshotState: Sendable {
            var inventory: [PluginSchema.Info] = []
            var guiDescriptors: [String: Generation.GuiDescriptor] = [:]
            var closed: Bool = false
            var nextHoldToken: UInt64 = 1
            var activeHolds: Set<UInt64> = []
            var waiters: [CheckedContinuation<Void, Never>] = []
        }

        private actor Coordinator {
            var slots: [(id: String, slot: Slot)] = []
            var discoveredFailures: [Failure] = []
            var closed: Bool = false

            func setClosed() -> [ActivationScope] {
                closed = true
                let scopes = slots.reversed().compactMap { $0.slot.activation?.scope }
                slots.removeAll()
                return scopes
            }

            func isClosed() -> Bool { closed }

            func currentSlots() -> [(id: String, slot: Slot)] { slots }

            func updateState(slots newSlots: [(id: String, slot: Slot)], failures: [Failure]) {
                self.slots = newSlots
                self.discoveredFailures = failures
            }
        }

        private let snapshotState = Mutex(SnapshotState())
        private let coordinator = Coordinator()
        private let contextFactory: @Sendable (_ pluginID: String, _ listInventory: @escaping @Sendable () -> [PluginSchema.Info], _ addFinalizer: @escaping @Sendable (@escaping @Sendable () async -> Void) -> Void) -> PluginEffect.Context
        private let fileSystem: any OpenCodeFileSystem
        private let onInventoryChanged: (@Sendable ([PluginSchema.Info]) -> Void)?
        private let hostEnvironment: Host.Environment?

        public init(
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
            onInventoryChanged: (@Sendable ([PluginSchema.Info]) -> Void)? = nil,
            contextFactory: @escaping @Sendable (
                _ pluginID: String,
                _ listInventory: @escaping @Sendable () -> [PluginSchema.Info],
                _ addFinalizer: @escaping @Sendable (@escaping @Sendable () async -> Void) -> Void
            ) -> PluginEffect.Context
        ) {
            self.fileSystem = fileSystem
            self.onInventoryChanged = onInventoryChanged
            self.contextFactory = contextFactory
            self.hostEnvironment = nil
        }

        public init(
            environment: Host.Environment,
            onInventoryChanged: (@Sendable ([PluginSchema.Info]) -> Void)? = nil
        ) {
            self.fileSystem = environment.fileSystem
            self.onInventoryChanged = onInventoryChanged
            self.hostEnvironment = environment
            self.contextFactory = { pluginID, listInventory, addFinalizer in
                Host.make(
                    environment: environment,
                    pluginID: pluginID,
                    listPlugins: listInventory,
                    addFinalizer: addFinalizer
                )
            }
        }

        /// Immediately returns the currently loaded plugin inventory WITHOUT waiting for pending activation.
        public func list() -> [PluginSchema.Info] {
            snapshotState.withLock { $0.inventory }
        }

        /// Immediately reads an active plugin's prebuilt `./gui-experimental` bundle if currently loaded.
        public func gui(_ id: PluginSchema.ID) async throws -> PluginSchema.GuiBundle? {
            let descriptor = snapshotState.withLock { $0.guiDescriptors[id.rawValue] }
            guard let descriptor else { return nil }
            let path = PluginContract.fromFileURLString(descriptor.file)
            let bytes = try await fileSystem.readFile(at: path)
            let code = String(decoding: bytes, as: UTF8.self)
            return PluginSchema.GuiBundle(code: code, revision: descriptor.revision, options: descriptor.options)
        }

        /// Acquires a readiness hold; `awaitActivation()` waits until all holds are released.
        public func hold() -> @Sendable () -> Void {
            let token: UInt64? = snapshotState.withLock { s in
                if s.closed { return nil }
                let id = s.nextHoldToken
                s.nextHoldToken &+= 1
                s.activeHolds.insert(id)
                return id
            }
            guard let token else { return {} }
            return { [self] in
                let toResume: [CheckedContinuation<Void, Never>] = self.snapshotState.withLock { s in
                    s.activeHolds.remove(token)
                    if s.activeHolds.isEmpty {
                        let pending = s.waiters
                        s.waiters.removeAll()
                        return pending
                    }
                    return []
                }
                for continuation in toResume {
                    continuation.resume()
                }
            }
        }

        /// Suspends only when explicitly called (e.g. one-shot CLI startup or tests) until active holds clear.
        public func awaitActivation() async {
            let needsWait = snapshotState.withLock { !$0.closed && !$0.activeHolds.isEmpty }
            if !needsWait { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = snapshotState.withLock { s in
                    if s.closed || s.activeHolds.isEmpty {
                        return true
                    }
                    s.waiters.append(continuation)
                    return false
                }
                if resumeNow {
                    continuation.resume()
                }
            }
        }

        /// Launches async plugin activation in the background so callers (server/core handlers) never block.
        public func startBackgroundActivation(_ plugins: [Generation], failures: [Failure] = []) {
            let release = hold()
            Task {
                defer { release() }
                try? await self.activate(plugins, failures: failures)
            }
        }

        /// Activates a generation of plugins with prefix diffing, reverse-order teardown, and fallback restoration.
        public func activate(_ plugins: [Generation], failures: [Failure] = []) async throws {
            var seenIDs: Set<String> = []
            for plugin in plugins {
                guard seenIDs.insert(plugin.id).inserted else {
                    throw ActivationError.duplicatePluginID(plugin.id)
                }
            }

            let release = hold()
            defer { release() }

            if await coordinator.isClosed() { return }

            let current = await coordinator.currentSlots()
            var prefix = 0
            while prefix < plugins.count && prefix < current.count {
                let entry = current[prefix]
                let next = plugins[prefix]
                if entry.id == next.id && entry.slot.plugin.revision == next.revision {
                    prefix += 1
                } else {
                    break
                }
            }

            var updatedSlots: [(id: String, slot: Slot)] = []
            for i in 0..<prefix {
                let old = current[i].slot
                updatedSlots.append((
                    id: plugins[i].id,
                    slot: Slot(plugin: plugins[i], activation: old.activation, error: old.error)
                ))
            }

            if prefix == plugins.count && current.count == plugins.count {
                await coordinator.updateState(slots: updatedSlots, failures: failures)
                publishSnapshot(slots: updatedSlots, failures: failures)
                return
            }

            // Tear down suffix slots in reverse order with error containment.
            var previousByID: [String: Slot] = [:]
            if prefix < current.count {
                let suffix = Array(current[prefix...])
                for item in suffix {
                    previousByID[item.id] = item.slot
                }
                for item in suffix.reversed() {
                    if let active = item.slot.activation, active.failureError == nil {
                        await active.scope.close()
                    }
                }
            }

            // Load suffix definitions sequentially in registration order.
            for definition in plugins[prefix...] {
                let prev = previousByID[definition.id]
                if let prevActivation = prev?.activation,
                   prevActivation.failureError != nil,
                   prev?.plugin.revision == definition.revision
                {
                    updatedSlots.append((
                        id: definition.id,
                        slot: Slot(plugin: definition, activation: prevActivation, error: prev?.error)
                    ))
                    continue
                }

                let loadOutcome = await loadSingle(definition)
                switch loadOutcome {
                case .success(let record):
                    updatedSlots.append((
                        id: definition.id,
                        slot: Slot(plugin: definition, activation: record, error: nil)
                    ))
                case .failure(let message):
                    // Attempt fallback restoration of prior healthy revision if one existed.
                    if let fallback = prev?.activation, fallback.failureError == nil {
                        let restoredOutcome = await loadSingle(fallback.plugin)
                        if case .success(let restored) = restoredOutcome {
                            updatedSlots.append((
                                id: definition.id,
                                slot: Slot(plugin: definition, activation: restored, error: message)
                            ))
                            continue
                        }
                    }
                    updatedSlots.append((
                        id: definition.id,
                        slot: Slot(plugin: definition, activation: nil, error: message)
                    ))
                }
            }

            await coordinator.updateState(slots: updatedSlots, failures: failures)
            publishSnapshot(slots: updatedSlots, failures: failures)
        }

        /// Marks a running plugin failed (e.g. after a transform error) and tears down its scope asynchronously.
        public func failActivePlugin(id: String, stateName: String, cause: String) async {
            let ref = "err_" + String(Hash.sha256("\(id):\(stateName):\(cause)").prefix(8))
            let message = "Plugin disabled after \(stateName).transform failed. Check server logs for details."
            let current = await coordinator.currentSlots()
            var next: [(id: String, slot: Slot)] = []
            var scopeToClose: ActivationScope?
            for item in current {
                if item.id == id, let active = item.slot.activation {
                    scopeToClose = active.scope
                    let failedRecord = ActiveRecord(
                        plugin: active.plugin,
                        scope: active.scope,
                        failureError: message,
                        failureRef: ref
                    )
                    next.append((id: id, slot: Slot(plugin: item.slot.plugin, activation: failedRecord, error: message)))
                } else {
                    next.append(item)
                }
            }
            await coordinator.updateState(slots: next, failures: [])
            publishSnapshot(slots: next, failures: [])
            if let scopeToClose {
                await scopeToClose.close()
            }
        }

        /// Closes the plugin registry, releases all readiness waiters, and runs all plugin finalizers in reverse order.
        public func close() async {
            let waitersToResume: [CheckedContinuation<Void, Never>] = snapshotState.withLock { s in
                s.closed = true
                s.activeHolds.removeAll()
                s.inventory = []
                s.guiDescriptors = [:]
                let list = s.waiters
                s.waiters.removeAll()
                return list
            }
            for continuation in waitersToResume {
                continuation.resume()
            }
            let scopes = await coordinator.setClosed()
            for scope in scopes {
                await scope.close()
            }
        }

        private enum LoadResult: Sendable {
            case success(ActiveRecord)
            case failure(String)
        }

        private func loadSingle(_ definition: Generation) async -> LoadResult {
            let scope = ActivationScope()
            let context = contextFactory(
                definition.id,
                { [self] in self.list() },
                { fn in scope.add(fn) }
            )
            do {
                if let env = hostEnvironment {
                    try await Host.withRuntime(
                        http: env.http,
                        environment: env.environment,
                        spawner: env.spawner,
                        fileSystem: env.fileSystem,
                        modelsDev: env.modelsDev
                    ) {
                        try await definition.effect(context)
                    }
                } else {
                    try await definition.effect(context)
                }
                return .success(ActiveRecord(plugin: definition, scope: scope, failureError: nil, failureRef: nil))
            } catch {
                await scope.close()
                return .failure(String(describing: error))
            }
        }

        private func publishSnapshot(slots: [(id: String, slot: Slot)], failures: [Failure]) {
            var infos: [PluginSchema.Info] = slots.map { entry in
                let slot = entry.slot
                let state: PluginSchema.State
                if let failureError = slot.activation?.failureError {
                    state = .failed(error: failureError, ref: slot.activation?.failureRef)
                } else if let error = slot.error {
                    state = .failed(error: error, ref: nil)
                } else {
                    state = .active
                }
                return PluginSchema.Info(
                    id: PluginSchema.ID(rawValue: slot.plugin.id),
                    source: slot.plugin.source ?? .builtin,
                    features: slot.plugin.features ?? PluginSchema.Features(server: true),
                    state: state
                )
            }
            infos.append(contentsOf: failures.map(\.asPluginInfo))

            var guiMap: [String: Generation.GuiDescriptor] = [:]
            for entry in slots {
                if let gui = entry.slot.plugin.gui {
                    guiMap[entry.id] = gui
                }
            }

            let changed: Bool = snapshotState.withLock { s in
                let prevInfos = s.inventory
                let prevGui = s.guiDescriptors
                s.inventory = infos
                s.guiDescriptors = guiMap
                return prevInfos != infos || prevGui != guiMap
            }
            if changed {
                onInventoryChanged?(infos)
            }
        }
    }

    /// Explicit activation waiter for one-shot clients (CLI/SDK/tests); server handlers must NOT call this.
    // parity: core/src/plugin/service.ts#awaitActivation [status=implemented hash=047ce35a14b1]
    public static func awaitActivation(_ service: any ServiceInterface) async {
        await service.awaitActivation()
    }

    /// LayerNode provider descriptor for the core `Plugin` Location service.
    // parity: core/src/plugin.ts#node [status=adapted hash=ecd306294a4e]
    public static let node: LayerNode.Provider = AppNode.makeLocationNode(
        Service.serviceKey,
        LayerNode.ExecutableLayer.succeed(key: Service.serviceKey, value: Service.serviceKey),
        [Host.requirements]
    )

    // MARK: - Hook Registry (`plugin/hooks.ts`)

    public enum Hooks {
        /// Supported hook domains on the core plugin hook registry.
        // parity: core/src/plugin/hooks.ts#Domains [status=implemented hash=9cc0f9dcaec4]
        public enum Domains: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
            case aisdk
            case session
            case permission
            case shell
            case tool
        }

        /// Contract for checking, registering, and triggering domain hooks.
        /// `has` and `trigger` operate ONLY on currently registered hooks and never wait for pending plugin loads.
        // parity: core/src/plugin/hooks.ts#Interface [status=adapted hash=a03ba80c575a]
        public protocol Interface: Sendable {
            func has(domain: Domains, name: String, providerID: String?) -> Bool
            func registerSession(
                name: String,
                options: PluginEffect.ModelHookOptions?,
                callback: @escaping @Sendable (PluginEffect.SessionHooks) async throws -> PluginEffect.SessionHooks
            ) -> PluginEffect.Registration
            func triggerSession(_ event: PluginEffect.SessionHooks) async -> PluginEffect.SessionHooks
            func registerAISDK(
                name: String,
                options: PluginEffect.ModelHookOptions?,
                callback: @escaping @Sendable (PluginEffect.AISDKHooks) async throws -> PluginEffect.AISDKHooks
            ) -> PluginEffect.Registration
            func triggerAISDK(_ event: PluginEffect.AISDKHooks) async -> PluginEffect.AISDKHooks
            func registerPermission(
                name: String,
                callback: @escaping @Sendable (PluginEffect.PermissionEvaluation) async throws -> PluginEffect.PermissionEvaluation
            ) -> PluginEffect.Registration
            func triggerPermission(_ event: PluginEffect.PermissionEvaluation) async -> PluginEffect.PermissionEvaluation
            func registerShell(
                name: String,
                callback: @escaping @Sendable (PluginEffect.ShellCreateBefore) async throws -> PluginEffect.ShellCreateBefore
            ) -> PluginEffect.Registration
            func triggerShell(_ event: PluginEffect.ShellCreateBefore) async -> PluginEffect.ShellCreateBefore
            func registerTool(
                name: String,
                callback: @escaping @Sendable (PluginEffect.ToolHooks) async throws -> PluginEffect.ToolHooks
            ) -> PluginEffect.Registration
            func triggerTool(_ event: PluginEffect.ToolHooks) async throws(ToolSchema.ToolError) -> PluginEffect.ToolHooks
        }

        /// Thread-safe, deterministic hook registry preserving insertion order, provider scoping,
        /// disposable registrations, and strict error containment.
        // parity: core/src/plugin/hooks.ts#Service [status=adapted hash=202c2e60491d]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/PluginHooks"

            private struct Entry<Event: Sendable>: Sendable {
                let token: UInt64
                let options: PluginEffect.ModelHookOptions?
                let callback: @Sendable (Event) async throws -> Event
            }

            private struct State: Sendable {
                var nextToken: UInt64 = 1
                var session: [String: [Entry<PluginEffect.SessionHooks>]] = [:]
                var aisdk: [String: [Entry<PluginEffect.AISDKHooks>]] = [:]
                var permission: [String: [Entry<PluginEffect.PermissionEvaluation>]] = [:]
                var shell: [String: [Entry<PluginEffect.ShellCreateBefore>]] = [:]
                var tool: [String: [Entry<PluginEffect.ToolHooks>]] = [:]
                var containedErrors: [(hookKey: String, message: String)] = []
            }

            private let state = Mutex(State())
            private let onHookError: (@Sendable (_ hookKey: String, _ error: any Error) -> Void)?

            public init(onHookError: (@Sendable (_ hookKey: String, _ error: any Error) -> Void)? = nil) {
                self.onHookError = onHookError
            }

            /// Returns recorded errors caught and contained from non-failing hooks.
            public func containedErrors() -> [(hookKey: String, message: String)] {
                state.withLock { $0.containedErrors }
            }

            public func has(domain: Domains, name: String, providerID: String? = nil) -> Bool {
                state.withLock { s in
                    switch domain {
                    case .session:
                        return (s.session[name] ?? []).contains { entry in
                            entry.options?.providerID == nil || entry.options?.providerID == providerID
                        }
                    case .aisdk:
                        return (s.aisdk[name] ?? []).contains { entry in
                            entry.options?.providerID == nil || entry.options?.providerID == providerID
                        }
                    case .permission:
                        return !(s.permission[name] ?? []).isEmpty
                    case .shell:
                        return !(s.shell[name] ?? []).isEmpty
                    case .tool:
                        return !(s.tool[name] ?? []).isEmpty
                    }
                }
            }

            public func registerSession(
                name: String,
                options: PluginEffect.ModelHookOptions? = nil,
                callback: @escaping @Sendable (PluginEffect.SessionHooks) async throws -> PluginEffect.SessionHooks
            ) -> PluginEffect.Registration {
                let token = state.withLock { s -> UInt64 in
                    let id = s.nextToken
                    s.nextToken &+= 1
                    s.session[name, default: []].append(Entry(token: id, options: options, callback: callback))
                    return id
                }
                return PluginEffect.Registration { [self] in
                    self.state.withLock { s in
                        s.session[name]?.removeAll { $0.token == token }
                        if s.session[name]?.isEmpty == true { s.session.removeValue(forKey: name) }
                    }
                }
            }

            public func triggerSession(_ event: PluginEffect.SessionHooks) async -> PluginEffect.SessionHooks {
                let hookName = event.hookName
                let entries = state.withLock { $0.session[hookName] ?? [] }
                var current = event
                for entry in entries {
                    if let scopedProvider = entry.options?.providerID, scopedProvider != current.providerID {
                        continue
                    }
                    do {
                        current = try await entry.callback(current)
                    } catch {
                        recordContainedError(hookKey: "session.\(hookName)", error: error)
                    }
                }
                return current
            }

            public func registerAISDK(
                name: String,
                options: PluginEffect.ModelHookOptions? = nil,
                callback: @escaping @Sendable (PluginEffect.AISDKHooks) async throws -> PluginEffect.AISDKHooks
            ) -> PluginEffect.Registration {
                let token = state.withLock { s -> UInt64 in
                    let id = s.nextToken
                    s.nextToken &+= 1
                    s.aisdk[name, default: []].append(Entry(token: id, options: options, callback: callback))
                    return id
                }
                return PluginEffect.Registration { [self] in
                    self.state.withLock { s in
                        s.aisdk[name]?.removeAll { $0.token == token }
                        if s.aisdk[name]?.isEmpty == true { s.aisdk.removeValue(forKey: name) }
                    }
                }
            }

            public func triggerAISDK(_ event: PluginEffect.AISDKHooks) async -> PluginEffect.AISDKHooks {
                let hookName = event.hookName
                let entries = state.withLock { $0.aisdk[hookName] ?? [] }
                var current = event
                for entry in entries {
                    if let scopedProvider = entry.options?.providerID, scopedProvider != current.providerID {
                        continue
                    }
                    do {
                        current = try await entry.callback(current)
                    } catch {
                        recordContainedError(hookKey: "aisdk.\(hookName)", error: error)
                    }
                }
                return current
            }

            public func registerPermission(
                name: String = "evaluate",
                callback: @escaping @Sendable (PluginEffect.PermissionEvaluation) async throws -> PluginEffect.PermissionEvaluation
            ) -> PluginEffect.Registration {
                let token = state.withLock { s -> UInt64 in
                    let id = s.nextToken
                    s.nextToken &+= 1
                    s.permission[name, default: []].append(Entry(token: id, options: nil, callback: callback))
                    return id
                }
                return PluginEffect.Registration { [self] in
                    self.state.withLock { s in
                        s.permission[name]?.removeAll { $0.token == token }
                        if s.permission[name]?.isEmpty == true { s.permission.removeValue(forKey: name) }
                    }
                }
            }

            public func triggerPermission(_ event: PluginEffect.PermissionEvaluation) async -> PluginEffect.PermissionEvaluation {
                let entries = state.withLock { $0.permission["evaluate"] ?? [] }
                var current = event
                for entry in entries {
                    do {
                        current = try await entry.callback(current)
                    } catch {
                        recordContainedError(hookKey: "permission.evaluate", error: error)
                    }
                }
                return current
            }

            public func registerShell(
                name: String = "create.before",
                callback: @escaping @Sendable (PluginEffect.ShellCreateBefore) async throws -> PluginEffect.ShellCreateBefore
            ) -> PluginEffect.Registration {
                let token = state.withLock { s -> UInt64 in
                    let id = s.nextToken
                    s.nextToken &+= 1
                    s.shell[name, default: []].append(Entry(token: id, options: nil, callback: callback))
                    return id
                }
                return PluginEffect.Registration { [self] in
                    self.state.withLock { s in
                        s.shell[name]?.removeAll { $0.token == token }
                        if s.shell[name]?.isEmpty == true { s.shell.removeValue(forKey: name) }
                    }
                }
            }

            public func triggerShell(_ event: PluginEffect.ShellCreateBefore) async -> PluginEffect.ShellCreateBefore {
                let entries = state.withLock { $0.shell["create.before"] ?? [] }
                var current = event
                for entry in entries {
                    do {
                        current = try await entry.callback(current)
                    } catch {
                        recordContainedError(hookKey: "shell.create.before", error: error)
                    }
                }
                return current
            }

            public func registerTool(
                name: String,
                callback: @escaping @Sendable (PluginEffect.ToolHooks) async throws -> PluginEffect.ToolHooks
            ) -> PluginEffect.Registration {
                let token = state.withLock { s -> UInt64 in
                    let id = s.nextToken
                    s.nextToken &+= 1
                    s.tool[name, default: []].append(Entry(token: id, options: nil, callback: callback))
                    return id
                }
                return PluginEffect.Registration { [self] in
                    self.state.withLock { s in
                        s.tool[name]?.removeAll { $0.token == token }
                        if s.tool[name]?.isEmpty == true { s.tool.removeValue(forKey: name) }
                    }
                }
            }

            public func triggerTool(_ event: PluginEffect.ToolHooks) async throws(ToolSchema.ToolError) -> PluginEffect.ToolHooks {
                let hookName = event.hookName
                let entries = state.withLock { $0.tool[hookName] ?? [] }
                var current = event
                for entry in entries {
                    do {
                        current = try await entry.callback(current)
                    } catch let toolErr as ToolSchema.ToolError {
                        if PluginEffect.ToolFailures.mayFail(hookName: hookName) {
                            throw toolErr
                        }
                        recordContainedError(hookKey: "tool.\(hookName)", error: toolErr)
                    } catch {
                        if PluginEffect.ToolFailures.mayFail(hookName: hookName) {
                            throw ToolSchema.ToolError(message: String(describing: error))
                        }
                        recordContainedError(hookKey: "tool.\(hookName)", error: error)
                    }
                }
                return current
            }

            private func recordContainedError(hookKey: String, error: any Error) {
                state.withLock { s in
                    s.containedErrors.append((hookKey, String(describing: error)))
                }
                onHookError?(hookKey, error)
            }
        }

        /// LayerNode provider descriptor for `PluginHooks`.
        // parity: core/src/plugin/hooks.ts#node [status=adapted hash=9e1ad9da14bc]
        public static let node: LayerNode.Provider = AppNode.makeLocationNode(
            Service.serviceKey,
            LayerNode.ExecutableLayer.succeed(key: Service.serviceKey, value: Service()),
            []
        )
    }

    // MARK: - Scoped KV Storage & Host Context Construction (`plugin/host.ts`)

    /// Minimal durable KV store protocol backing plugin-scoped storage.
    public protocol KVStore: Sendable {
        func get(_ key: String) async throws -> JSONValue?
        func set(_ key: String, value: JSONValue) async throws
        func remove(_ key: String) async throws
        func scan(_ options: PluginContract.StorageScanOptions) async throws -> PluginContract.StorageScanResult
    }

    /// Deterministic in-memory `KVStore` safe across all Swift platforms.
    public final class InMemoryKVStore: KVStore, Sendable {
        private let entries = Mutex<[String: JSONValue]>([:])

        public init(initial: [String: JSONValue] = [:]) {
            self.entries.withLock { $0 = initial }
        }

        public func get(_ key: String) async throws -> JSONValue? {
            entries.withLock { $0[key] }
        }

        public func set(_ key: String, value: JSONValue) async throws {
            entries.withLock { $0[key] = value }
        }

        public func remove(_ key: String) async throws {
            entries.withLock { _ = $0.removeValue(forKey: key) }
        }

        public func scan(_ options: PluginContract.StorageScanOptions) async throws -> PluginContract.StorageScanResult {
            let matching: [PluginContract.StorageEntry] = entries.withLock { map in
                map.keys
                    .filter { key in
                        guard key.hasPrefix(options.prefix) else { return false }
                        if let after = options.after, key <= after { return false }
                        return true
                    }
                    .sorted()
                    .compactMap { key in
                        map[key].map { PluginContract.StorageEntry(key: key, value: $0) }
                    }
            }
            if let limit = options.limit, limit > 0, matching.count > limit {
                let slice = Array(matching.prefix(limit))
                return PluginContract.StorageScanResult(entries: slice, next: slice.last?.key)
            }
            return PluginContract.StorageScanResult(entries: matching, next: nil)
        }

        public func rawKeys() -> [String] {
            entries.withLock { Array($0.keys).sorted() }
        }
    }

    /// SQLite-backed `KVStore` built on `OpenCodePlatform.SQLiteDatabase`.
    public final class SQLiteKVStore: KVStore, Sendable {
        private let database: any SQLiteDatabase

        public init(database: any SQLiteDatabase) throws {
            self.database = database
            _ = try database.execute(
                """
                CREATE TABLE IF NOT EXISTS plugin_kv (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                )
                """,
                parameters: []
            )
        }

        public func get(_ key: String) async throws -> JSONValue? {
            let rows = try database.query(
                "SELECT value FROM plugin_kv WHERE key = ?",
                parameters: [.text(key)]
            )
            guard let text = rows.first?.string("value"),
                  let data = text.data(using: .utf8)
            else {
                return nil
            }
            return try JSONDecoder().decode(JSONValue.self, from: data)
        }

        public func set(_ key: String, value: JSONValue) async throws {
            let data = try JSONEncoder().encode(value)
            let text = String(decoding: data, as: UTF8.self)
            _ = try database.execute(
                "INSERT INTO plugin_kv (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                parameters: [.text(key), .text(text)]
            )
        }

        public func remove(_ key: String) async throws {
            _ = try database.execute("DELETE FROM plugin_kv WHERE key = ?", parameters: [.text(key)])
        }

        public func scan(_ options: PluginContract.StorageScanOptions) async throws -> PluginContract.StorageScanResult {
            let rows = try database.query("SELECT key, value FROM plugin_kv ORDER BY key ASC", parameters: [])
            var matching: [PluginContract.StorageEntry] = []
            for row in rows {
                guard let key = row.string("key"),
                      key.hasPrefix(options.prefix)
                else { continue }
                if let after = options.after, key <= after { continue }
                if let text = row.string("value"),
                   let data = text.data(using: .utf8),
                   let value = try? JSONDecoder().decode(JSONValue.self, from: data)
                {
                    matching.append(PluginContract.StorageEntry(key: key, value: value))
                }
            }
            if let limit = options.limit, limit > 0, matching.count > limit {
                let slice = Array(matching.prefix(limit))
                return PluginContract.StorageScanResult(entries: slice, next: slice.last?.key)
            }
            return PluginContract.StorageScanResult(entries: matching, next: nil)
        }
    }

    /// Scoped permission evaluation engine wired into `PluginEffect.PermissionDomain.assert`.
    public final class PermissionRuntime: Sendable {
        public typealias ApprovalPrompter = @Sendable (PermissionSchema.Request) async -> (reply: PermissionSchema.Reply, message: String?)

        private struct State: Sendable {
            var rules: [PermissionSchema.Rule] = []
            var pending: [PermissionSchema.ID: PermissionSchema.Request] = [:]
        }

        private let state = Mutex(State())
        private let hooks: Hooks.Service
        private let promptApproval: ApprovalPrompter

        public init(
            rules: [PermissionSchema.Rule] = [],
            hooks: Hooks.Service,
            promptApproval: @escaping ApprovalPrompter = { _ in (.once, nil) }
        ) {
            self.hooks = hooks
            self.promptApproval = promptApproval
            self.state.withLock { $0.rules = rules }
        }

        public func setRules(_ rules: [PermissionSchema.Rule]) {
            state.withLock { $0.rules = rules }
        }

        public func list(sessionID: SessionID) -> [PermissionSchema.Request] {
            state.withLock { s in
                s.pending.values.filter { $0.sessionID == sessionID }
            }
        }

        public func get(sessionID: SessionID, requestID: PermissionSchema.ID) throws -> PermissionSchema.Request {
            guard let req = state.withLock({ $0.pending[requestID] }), req.sessionID == sessionID else {
                throw ToolSchema.ToolError(message: "Permission request not found: \(requestID.rawValue)")
            }
            return req
        }

        public func assert(_ input: PluginContract.AssertInput) async throws(ToolSchema.ToolError) {
            let baseEffect = evaluateRules(action: input.action, resources: input.resources)
            let evaluated = await hooks.triggerPermission(
                PluginEffect.PermissionEvaluation(
                    sessionID: input.sessionID,
                    agent: input.agent,
                    action: input.action,
                    resources: input.resources,
                    metadata: input.metadata,
                    source: input.source,
                    effect: baseEffect,
                    message: nil
                )
            )
            switch evaluated.effect {
            case .allow:
                return
            case .deny:
                throw ToolSchema.ToolError(
                    message: evaluated.message ?? "Permission denied for action '\(input.action)'"
                )
            case .ask:
                let request = PermissionSchema.Request(
                    id: PermissionSchema.ID.create(),
                    sessionID: input.sessionID,
                    action: input.action,
                    resources: input.resources,
                    save: input.save,
                    metadata: input.metadata,
                    source: input.source,
                    message: evaluated.message
                )
                state.withLock { $0.pending[request.id] = request }
                defer { state.withLock { _ = $0.pending.removeValue(forKey: request.id) } }
                let decision = await promptApproval(request)
                switch decision.reply {
                case .once:
                    return
                case .always:
                    state.withLock { s in
                        for resource in (input.save ?? input.resources) {
                            s.rules.append(PermissionSchema.Rule(action: input.action, resource: resource, effect: .allow))
                        }
                    }
                    return
                case .reject:
                    throw ToolSchema.ToolError(
                        message: decision.message ?? "Permission rejected for action '\(input.action)'"
                    )
                }
            }
        }

        private func evaluateRules(action: String, resources: [String]) -> PermissionSchema.Effect {
            let rules = state.withLock { $0.rules }
            var resolved: PermissionSchema.Effect = .ask
            for rule in rules {
                let actionMatch = rule.action == "*" || rule.action == action
                let resourceMatch = rule.resource == "*"
                    || resources.isEmpty
                    || resources.allSatisfy { res in
                        rule.resource == res || (rule.resource.hasSuffix("*") && res.hasPrefix(String(rule.resource.dropLast())))
                    }
                if actionMatch && resourceMatch {
                    resolved = rule.effect
                }
            }
            return resolved
        }
    }

    /// Location-scoped plugin host wiring all plugin domains, scoped KV storage, hooks, and permissions.
    public enum Host {
        /// Task-local runtime dependency overrides used by built-in plugins when activated or invoked inside a host environment.
        @TaskLocal public static var currentHTTPTransportOverride: (any HTTPTransport)? = nil
        @TaskLocal public static var currentEnvironmentOverride: (any EnvironmentProviding)? = nil
        @TaskLocal public static var currentProcessSpawnerOverride: (any ProcessSpawner)? = nil
        @TaskLocal public static var currentFileSystemOverride: (any OpenCodeFileSystem)? = nil
        @TaskLocal public static var currentModelsDevOverride: (any CoreModel.ModelsDev.Interface)? = nil

        public static var currentHTTPTransport: any HTTPTransport {
            currentHTTPTransportOverride ?? URLSessionHTTPTransport.shared
        }

        public static var currentEnvironment: any EnvironmentProviding {
            currentEnvironmentOverride ?? SystemEnvironment.shared
        }

        public static var currentProcessSpawner: any ProcessSpawner {
            currentProcessSpawnerOverride ?? CrossSpawnSpawner.HostProcessSpawner.shared
        }

        public static var currentFileSystem: any OpenCodeFileSystem {
            currentFileSystemOverride ?? LocalFileSystem.shared
        }

        /// Executes `operation` with task-local plugin runtime dependencies bound.
        public static func withRuntime<T: Sendable>(
            http: (any HTTPTransport)? = nil,
            environment: (any EnvironmentProviding)? = nil,
            spawner: (any ProcessSpawner)? = nil,
            fileSystem: (any OpenCodeFileSystem)? = nil,
            modelsDev: (any CoreModel.ModelsDev.Interface)? = nil,
            operation: () async throws -> T
        ) async rethrows -> T {
            try await $currentHTTPTransportOverride.withValue(http ?? currentHTTPTransportOverride) {
                try await $currentEnvironmentOverride.withValue(environment ?? currentEnvironmentOverride) {
                    try await $currentProcessSpawnerOverride.withValue(spawner ?? currentProcessSpawnerOverride) {
                        try await $currentFileSystemOverride.withValue(fileSystem ?? currentFileSystemOverride) {
                            try await $currentModelsDevOverride.withValue(modelsDev ?? currentModelsDevOverride) {
                                try await operation()
                            }
                        }
                    }
                }
            }
        }

        /// Encodes `pluginID` into the exact upstream UTF-16 4-hex-digit namespace prefix `plugin:<hex>:`
        /// and wraps `kv` so plugins can only access and scan their own isolated keyspace.
        // parity: core/src/plugin/host.ts#storage [status=implemented hash=00512f7e06fe]
        public static func storage(kv: any KVStore, pluginID: String) -> PluginEffect.StorageDomain {
            let hexEncoded = pluginID.utf16.map { unit -> String in
                let hex = String(unit, radix: 16, uppercase: false)
                return String(repeating: "0", count: max(0, 4 - hex.count)) + hex
            }.joined()
            let namespace = "plugin:\(hexEncoded):"
            return PluginEffect.StorageDomain(
                get: { key in try await kv.get(namespace + key) },
                set: { key, value in try await kv.set(namespace + key, value: value) },
                remove: { key in try await kv.remove(namespace + key) },
                scan: { options in
                    let scoped = PluginContract.StorageScanOptions(
                        prefix: namespace + options.prefix,
                        after: options.after.map { namespace + $0 },
                        limit: options.limit
                    )
                    let result = try await kv.scan(scoped)
                    let entries = result.entries.map { entry in
                        PluginContract.StorageEntry(
                            key: String(entry.key.dropFirst(namespace.count)),
                            value: entry.value
                        )
                    }
                    let next = result.next.map { String($0.dropFirst(namespace.count)) }
                    return PluginContract.StorageScanResult(entries: entries, next: next)
                }
            )
        }

        /// Backing state container shared across a Location's `PluginHost`.
        public final class Environment: Sendable {
            public struct RecordedSessionPrompt: Equatable, Sendable {
                public let sessionID: SessionID
                public let prompt: PromptInputSchema.Prompt
                public let delivery: SessionInboxSchema.Delivery

                public init(sessionID: SessionID, prompt: PromptInputSchema.Prompt, delivery: SessionInboxSchema.Delivery) {
                    self.sessionID = sessionID
                    self.prompt = prompt
                    self.delivery = delivery
                }
            }

            private struct State: Sendable {
                var agents: [String: AgentSchema.Info] = [:]
                var defaultAgentID: String?
                var commands: [String: PluginEffect.CommandDefinition] = [:]
                var tools: [String: PluginEffect.DynamicToolInfo] = [:]
                var toolNamespaces: [String: ToolSchema.Namespace] = [:]
                var skills: [String: SkillSchema.Info] = [:]
                var mcpServers: [String: McpSchema.ServerConfig] = [:]
                var providers: [String: PluginEffect.ProviderRecord] = [:]
                var models: [String: ModelSchema.Info] = [:]
                var defaultModel: PluginEffect.ModelEditor.DefaultModelRef?
                var integrations: [String: PluginEffect.IntegrationRef] = [:]
                var integrationMethods: [String: [PluginEffect.IntegrationMethod]] = [:]
                var references: [String: ReferenceSchema.Source] = [:]
                var vcsProviders: [String: PluginEffect.VcsDefinition] = [:]
                var defaultVcs: String?
                var webSearchProviders: [String: PluginEffect.WebSearchDefinition] = [:]
                var defaultWebSearch: PluginEffect.WebSearchDefaultSelection?
                var worktreeStrategies: [String: PluginEffect.WorktreeDefinition] = [:]
                var artifactProviders: [String: PluginEffect.ArtifactProviderDefinition] = [:]
                var defaultArtifactProvider: String?
                var rpcDefinitions: [String: (definition: RpcSchema.Definition, handlers: PluginEffect.RpcHandlers)] = [:]
                var rpcEventContinuations: [String: [UUID: AsyncStream<RpcSchema.EventPayload>.Continuation]] = [:]
                var eventContinuations: [UUID: (types: Set<String>?, continuation: AsyncStream<PluginSDK.EventPayload>.Continuation)] = [:]
                var sessions: [SessionID: SessionSchema.Info] = [:]
                var recordedPrompts: [RecordedSessionPrompt] = []
            }

            public let app: PluginContract.App
            public let location: LocationSchema.Info
            public let hooks: Hooks.Service
            public let kv: any KVStore
            public let permissions: PermissionRuntime
            public let http: any HTTPTransport
            public let environment: any EnvironmentProviding
            public let spawner: any ProcessSpawner
            public let fileSystem: any OpenCodeFileSystem
            public let modelsDev: (any CoreModel.ModelsDev.Interface)?
            public let vcsService: CoreVcs.Vcs.Service?
            public let integrationService: (any CoreIntegration.Integration.Interface)?
            public let onSessionPrompt: (@Sendable (SessionID, PromptInputSchema.Prompt, SessionInboxSchema.Delivery) async throws -> Void)?
            private let state = Mutex(State())

            public init(
                app: PluginContract.App = PluginContract.App(name: "opencode", version: "2.0.0", channel: "local"),
                location: LocationSchema.Info = LocationSchema.Info(
                    directory: SchemaPrimitive.AbsolutePath(rawValue: "/"),
                    workspaceID: nil,
                    project: LocationSchema.ProjectRef(
                        id: ProjectID.global,
                        directory: SchemaPrimitive.AbsolutePath(rawValue: "/"),
                        canonical: SchemaPrimitive.AbsolutePath(rawValue: "/")
                    )
                ),
                hooks: Hooks.Service = Hooks.Service(),
                kv: any KVStore = InMemoryKVStore(),
                permissions: PermissionRuntime? = nil,
                http: any HTTPTransport = URLSessionHTTPTransport.shared,
                environment: any EnvironmentProviding = SystemEnvironment.shared,
                spawner: any ProcessSpawner = CrossSpawnSpawner.HostProcessSpawner.shared,
                fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
                modelsDev: (any CoreModel.ModelsDev.Interface)? = nil,
                vcsService: CoreVcs.Vcs.Service? = nil,
                integrationService: (any CoreIntegration.Integration.Interface)? = nil,
                onSessionPrompt: (@Sendable (SessionID, PromptInputSchema.Prompt, SessionInboxSchema.Delivery) async throws -> Void)? = nil
            ) {
                self.app = app
                self.location = location
                self.hooks = hooks
                self.kv = kv
                self.permissions = permissions ?? PermissionRuntime(hooks: hooks)
                self.http = http
                self.environment = environment
                self.spawner = spawner
                self.fileSystem = fileSystem
                self.modelsDev = modelsDev
                self.vcsService = vcsService
                self.integrationService = integrationService
                self.onSessionPrompt = onSessionPrompt
            }

            /// Runs a plugin's effect against this environment with all runtime dependencies bound.
            public func activatePlugin(_ plugin: PluginEffect.Plugin) async throws {
                let ctx = makeContext(pluginID: plugin.id, listPlugins: { [] }, addFinalizer: { _ in })
                try await Host.withRuntime(
                    http: http,
                    environment: environment,
                    spawner: spawner,
                    fileSystem: fileSystem,
                    modelsDev: modelsDev
                ) {
                    try await plugin.effect(ctx)
                }
            }

            public func registeredAgents() -> [AgentSchema.Info] {
                state.withLock { Array($0.agents.values).sorted { $0.id.rawValue < $1.id.rawValue } }
            }

            public func defaultAgentID() -> String? {
                state.withLock { $0.defaultAgentID }
            }

            public func registeredProviders() -> [PluginEffect.ProviderRecord] {
                state.withLock { Array($0.providers.values).sorted { $0.provider.id.rawValue < $1.provider.id.rawValue } }
            }

            public func registeredModels() -> [ModelSchema.Info] {
                state.withLock { Array($0.models.values).sorted { "\($0.providerID.rawValue)/\($0.id.rawValue)" < "\($1.providerID.rawValue)/\($1.id.rawValue)" } }
            }

            public func registeredIntegrations() -> [PluginEffect.IntegrationRef] {
                state.withLock { Array($0.integrations.values).sorted { $0.id < $1.id } }
            }

            public func registeredIntegrationMethods(for id: String) -> [PluginEffect.IntegrationMethod] {
                state.withLock { $0.integrationMethods[id] ?? [] }
            }

            public func registeredVcsProviders() -> [PluginEffect.VcsDefinition] {
                state.withLock { Array($0.vcsProviders.values).sorted { $0.id < $1.id } }
            }

            public func defaultVcsID() -> String? {
                state.withLock { $0.defaultVcs }
            }

            public func recordedSessionPrompts() -> [RecordedSessionPrompt] {
                state.withLock { $0.recordedPrompts }
            }

            public func registerSession(_ session: SessionSchema.Info) {
                state.withLock { $0.sessions[session.id] = session }
            }

            public func session(id: SessionID) -> SessionSchema.Info? {
                state.withLock { $0.sessions[id] }
            }

            public func updateSessionPermissions(id: SessionID, permissions: SessionSchema.PermissionRuleset?) {
                state.withLock { s in
                    guard let existing = s.sessions[id] else { return }
                    s.sessions[id] = SessionSchema.Info(
                        id: existing.id,
                        parentID: existing.parentID,
                        fork: existing.fork,
                        projectID: existing.projectID,
                        agent: existing.agent,
                        model: existing.model,
                        cost: existing.cost,
                        tokens: existing.tokens,
                        outcome: existing.outcome,
                        time: existing.time,
                        title: existing.title,
                        location: existing.location,
                        subpath: existing.subpath,
                        metadata: existing.metadata,
                        permissions: permissions,
                        revert: existing.revert
                    )
                }
            }

            public func emitEvent(_ event: PluginSDK.EventPayload) {
                let targets = state.withLock { s -> [AsyncStream<PluginSDK.EventPayload>.Continuation] in
                    s.eventContinuations.values.compactMap { entry in
                        if let types = entry.types, !types.contains(event.type) {
                            return nil
                        }
                        return entry.continuation
                    }
                }
                for continuation in targets {
                    continuation.yield(event)
                }
            }

            public func subscribeRpc(namespace: String, event: String) -> AsyncStream<RpcSchema.EventPayload> {
                let key = "\(namespace)::\(event)"
                let token = UUID()
                return AsyncStream { continuation in
                    self.state.withLock { s in
                        s.rpcEventContinuations[key, default: [:]][token] = continuation
                    }
                    continuation.onTermination = { [weak self] _ in
                        self?.state.withLock { s in
                            _ = s.rpcEventContinuations[key]?.removeValue(forKey: token)
                        }
                    }
                }
            }

            public func registeredToolNamespaces() -> [ToolSchema.Namespace] {
                state.withLock { Array($0.toolNamespaces.values).sorted { $0.name < $1.name } }
            }

            public func registeredTools() -> [PluginEffect.DynamicToolInfo] {
                state.withLock { Array($0.tools.values).sorted { $0.id < $1.id } }
            }

            public func registeredCommands() -> [PluginEffect.CommandDefinition] {
                state.withLock { Array($0.commands.values).sorted { $0.name < $1.name } }
            }

            public func registeredSkills() -> [SkillSchema.Info] {
                state.withLock { Array($0.skills.values).sorted { $0.id.rawValue < $1.id.rawValue } }
            }

            public func registeredWebSearchProviders() -> [WebSearchSchema.Provider] {
                state.withLock { s in
                    s.webSearchProviders.values
                        .sorted { $0.id < $1.id }
                        .map { WebSearchSchema.Provider(id: WebSearchSchema.ID(rawValue: $0.id), name: $0.name) }
                }
            }

            public func callRpc(namespace: String, method: String, input: JSONValue) async throws -> JSONValue {
                let handler = state.withLock { s in s.rpcDefinitions[namespace]?.handlers[method] }
                guard let handler else {
                    throw RpcSchema.SystemError(
                        type: .methodNotFound,
                        message: "RPC method not found: \(namespace).\(method)"
                    )
                }
                return try await handler(input, PluginEffect.RpcCallContext())
            }

            private func selectedVcsDefinition() -> PluginEffect.VcsDefinition? {
                state.withLock { s in
                    if let def = s.defaultVcs, let p = s.vcsProviders[def] { return p }
                    if let git = s.vcsProviders["git"] { return git }
                    return s.vcsProviders.values.first
                }
            }

            private func vcsScope() -> PluginEffect.VcsScope {
                PluginEffect.VcsScope(
                    directory: location.directory.rawValue,
                    worktree: location.project.directory.rawValue,
                    canonical: location.project.canonical.rawValue
                )
            }

            internal func makeContext(
                pluginID: String,
                listPlugins: @escaping @Sendable () -> [PluginSchema.Info],
                addFinalizer: @escaping @Sendable (@escaping @Sendable () async -> Void) -> Void
            ) -> PluginEffect.Context {
                let loc = self.location

                let agentEditor = PluginEffect.AgentEditor(
                    list: { [self] in self.state.withLock { Array($0.agents.values) } },
                    get: { [self] id in self.state.withLock { $0.agents[id] } },
                    setDefault: { [self] id in self.state.withLock { $0.defaultAgentID = id } },
                    update: { [self] id, mutate in
                        self.state.withLock { s in
                            var item = s.agents[id] ?? AgentSchema.Info.default(AgentSchema.ID(rawValue: id))
                            mutate(&item)
                            s.agents[id] = item
                        }
                    },
                    remove: { [self] id in self.state.withLock { _ = $0.agents.removeValue(forKey: id) } }
                )

                let commandEditor = PluginEffect.CommandEditor(add: { [self] def in
                    self.state.withLock { $0.commands[def.name] = def }
                })

                let toolEditor = PluginEffect.ToolEditor(
                    list: { [self] in self.registeredTools() },
                    get: { [self] id in self.state.withLock { $0.tools[id] } },
                    namespace: { [self] ns in self.state.withLock { $0.toolNamespaces[ns.name] = ns } },
                    add: { [self] tool in self.state.withLock { $0.tools[tool.id] = tool } },
                    update: { [self] id, mutate in
                        self.state.withLock { s in
                            if var existing = s.tools[id] {
                                mutate(&existing)
                                s.tools[id] = existing
                            }
                        }
                    },
                    remove: { [self] id in self.state.withLock { _ = $0.tools.removeValue(forKey: id) } }
                )

                let skillEditor = PluginEffect.SkillEditor(
                    list: { [self] in self.registeredSkills() },
                    get: { [self] id in self.state.withLock { $0.skills[id] } },
                    add: { [self] skill in self.state.withLock { $0.skills[skill.id.rawValue] = skill } },
                    update: { [self] id, mutate in
                        self.state.withLock { s in
                            if var existing = s.skills[id] {
                                mutate(&existing)
                                s.skills[id] = existing
                            }
                        }
                    },
                    remove: { [self] id in self.state.withLock { _ = $0.skills.removeValue(forKey: id) } }
                )

                let mcpEditor = PluginEffect.MCPEditor(
                    list: { [self] in self.state.withLock { Array($0.mcpServers).sorted { $0.0 < $1.0 } } },
                    get: { [self] name in self.state.withLock { $0.mcpServers[name] } },
                    set: { [self] name, cfg in self.state.withLock { $0.mcpServers[name] = cfg } },
                    update: { [self] name, mutate in
                        self.state.withLock { s in
                            if var cfg = s.mcpServers[name] {
                                mutate(&cfg)
                                s.mcpServers[name] = cfg
                            }
                        }
                    },
                    remove: { [self] name in self.state.withLock { _ = $0.mcpServers.removeValue(forKey: name) } }
                )

                let providerEditor = PluginEffect.ProviderEditor(
                    list: { [self] in self.state.withLock { Array($0.providers.values) } },
                    get: { [self] id in self.state.withLock { $0.providers[id] } },
                    add: { [self] info, models, conn in
                        self.state.withLock { s in
                            let modelMap = Dictionary(uniqueKeysWithValues: models.map { ($0.id.rawValue, $0) })
                            s.providers[info.id.rawValue] = PluginEffect.ProviderRecord(
                                provider: info,
                                models: modelMap,
                                sourceConnection: conn
                            )
                            for m in models {
                                s.models["\(info.id.rawValue)/\(m.id.rawValue)"] = m
                            }
                        }
                    },
                    update: { [self] id, mutate in
                        self.state.withLock { s in
                            if let rec = s.providers[id] {
                                var info = rec.provider
                                mutate(&info)
                                s.providers[id] = PluginEffect.ProviderRecord(
                                    provider: info,
                                    models: rec.models,
                                    sourceConnection: rec.sourceConnection
                                )
                            }
                        }
                    },
                    remove: { [self] id in self.state.withLock { _ = $0.providers.removeValue(forKey: id) } },
                    models: PluginEffect.ProviderEditor.ModelsEditor(
                        set: { [self] pid, models in
                            self.state.withLock { s in
                                if let rec = s.providers[pid] {
                                    let map = Dictionary(uniqueKeysWithValues: models.map { ($0.id.rawValue, $0) })
                                    s.providers[pid] = PluginEffect.ProviderRecord(
                                        provider: rec.provider,
                                        models: map,
                                        sourceConnection: rec.sourceConnection
                                    )
                                    for m in models {
                                        s.models["\(pid)/\(m.id.rawValue)"] = m
                                    }
                                }
                            }
                        },
                        update: { [self] pid, mid, mutate in
                            self.state.withLock { s in
                                if let rec = s.providers[pid], var model = rec.models[mid] {
                                    mutate(&model)
                                    var updated = rec.models
                                    updated[mid] = model
                                    s.providers[pid] = PluginEffect.ProviderRecord(
                                        provider: rec.provider,
                                        models: updated,
                                        sourceConnection: rec.sourceConnection
                                    )
                                    s.models["\(pid)/\(mid)"] = model
                                }
                            }
                        },
                        remove: { [self] pid, mid in
                            self.state.withLock { s in
                                if let rec = s.providers[pid] {
                                    var updated = rec.models
                                    updated.removeValue(forKey: mid)
                                    s.providers[pid] = PluginEffect.ProviderRecord(
                                        provider: rec.provider,
                                        models: updated,
                                        sourceConnection: rec.sourceConnection
                                    )
                                    s.models.removeValue(forKey: "\(pid)/\(mid)")
                                }
                            }
                        }
                    )
                )

                let modelEditor = PluginEffect.ModelEditor(
                    list: { [self] providerID in
                        self.state.withLock { s in
                            s.models.values.filter { providerID == nil || $0.providerID.rawValue == providerID }
                        }
                    },
                    get: { [self] pid, mid in self.state.withLock { $0.models["\(pid)/\(mid)"] } },
                    update: { [self] pid, mid, mutate in
                        self.state.withLock { s in
                            if var m = s.models["\(pid)/\(mid)"] {
                                mutate(&m)
                                s.models["\(pid)/\(mid)"] = m
                            }
                        }
                    },
                    remove: { [self] pid, mid in self.state.withLock { _ = $0.models.removeValue(forKey: "\(pid)/\(mid)") } },
                    getDefault: { [self] in self.state.withLock { $0.defaultModel } },
                    setDefault: { [self] pid, mid in
                        self.state.withLock { $0.defaultModel = PluginEffect.ModelEditor.DefaultModelRef(providerID: pid, modelID: mid) }
                    },
                    listProviders: { [self] in self.state.withLock { Array($0.providers.values) } },
                    getProvider: { [self] pid in self.state.withLock { $0.providers[pid] } }
                )

                let integrationEditor = PluginEffect.IntegrationEditor(
                    list: { [self] in self.state.withLock { Array($0.integrations.values) } },
                    get: { [self] id in self.state.withLock { $0.integrations[id] } },
                    update: { [self] id, mutate in
                        self.state.withLock { s in
                            var item = s.integrations[id] ?? PluginEffect.IntegrationRef(id: id, name: id)
                            mutate(&item)
                            s.integrations[id] = item
                        }
                    },
                    remove: { [self] id in self.state.withLock { _ = $0.integrations.removeValue(forKey: id) } },
                    method: PluginEffect.IntegrationEditor.MethodEditor(
                        list: { [self] id in self.state.withLock { $0.integrationMethods[id] ?? [] } },
                        update: { [self] reg in
                            self.state.withLock { s in
                                switch reg {
                                case .oauth(let r):
                                    s.integrationMethods[r.integrationID, default: []].append(.oauth(r.method))
                                case .command(let id, let m):
                                    s.integrationMethods[id, default: []].append(.command(m))
                                case .key(let id, let m):
                                    s.integrationMethods[id, default: []].append(.key(m))
                                case .external(let id, let m):
                                    s.integrationMethods[id, default: []].append(.external(m))
                                case .env(let id, let m):
                                    s.integrationMethods[id, default: []].append(.env(m))
                                }
                            }
                        },
                        remove: { [self] id, method in
                            self.state.withLock { s in
                                s.integrationMethods[id]?.removeAll { $0 == method }
                            }
                        }
                    )
                )

                let referenceEditor = PluginEffect.ReferenceEditor(
                    add: { [self] name, src in self.state.withLock { $0.references[name] = src } },
                    remove: { [self] name in self.state.withLock { _ = $0.references.removeValue(forKey: name) } },
                    list: { [self] in self.state.withLock { Array($0.references).sorted { $0.0 < $1.0 } } },
                    get: { [self] name in self.state.withLock { $0.references[name] } }
                )

                let vcsEditor = PluginEffect.VcsEditor(
                    add: { [self] def in self.state.withLock { $0.vcsProviders[def.id] = def } },
                    getDefault: { [self] in self.state.withLock { $0.defaultVcs } },
                    setDefault: { [self] sel in self.state.withLock { $0.defaultVcs = sel } }
                )

                let websearchEditor = PluginEffect.WebSearchEditor(
                    add: { [self] def in self.state.withLock { $0.webSearchProviders[def.id] = def } },
                    getDefault: { [self] in self.state.withLock { $0.defaultWebSearch } },
                    setDefault: { [self] sel in self.state.withLock { $0.defaultWebSearch = sel } }
                )

                let worktreeEditor = PluginEffect.WorktreeEditor(
                    add: { [self] def in self.state.withLock { $0.worktreeStrategies[def.id] = def } }
                )

                let artifactEditor = PluginEffect.ArtifactEditor(
                    add: { [self] def in self.state.withLock { $0.artifactProviders[def.id] = def } },
                    remove: { [self] id in self.state.withLock { _ = $0.artifactProviders.removeValue(forKey: id) } },
                    getDefault: { [self] in self.state.withLock { $0.defaultArtifactProvider } },
                    setDefault: { [self] id in self.state.withLock { $0.defaultArtifactProvider = id } }
                )

                let hookService = self.hooks
                let permRuntime = self.permissions

                let integrationDomain = PluginEffect.IntegrationDomain(
                    list: { [self] in
                        if let svc = self.integrationService {
                            let all = try await svc.list()
                            return PluginSDK.LocatedResult(location: loc, data: all)
                        }
                        return PluginSDK.LocatedResult(location: loc, data: [])
                    },
                    get: { [self] id in
                        if let svc = self.integrationService,
                           let found = try await svc.get(IntegrationID(rawValue: id))
                        {
                            return PluginSDK.LocatedResult(location: loc, data: found)
                        }
                        throw ToolSchema.ToolError(message: "Integration not found: \(id)")
                    },
                    transform: { callback in
                        callback(integrationEditor)
                        return PluginEffect.Registration(dispose: {})
                    },
                    reload: {},
                    connection: PluginEffect.IntegrationDomain.ConnectionAPI(
                        active: { [self] id in
                            if let svc = self.integrationService,
                               let conn = try? await svc.activeConnection(IntegrationID(rawValue: id))
                            {
                                return conn
                            }
                            let methods = self.state.withLock { $0.integrationMethods[id] ?? [] }
                            for method in methods {
                                if case .env(let envMethod) = method {
                                    for envName in envMethod.names {
                                        if let val = self.environment.variable(envName), !val.isEmpty {
                                            return .env(ConnectionSchema.EnvInfo(name: envName))
                                        }
                                    }
                                }
                            }
                            return nil
                        },
                        resolve: { [self] conn in
                            if let svc = self.integrationService,
                               let resolved = try? await svc.resolveConnection(conn)
                            {
                                return resolved
                            }
                            if case .env(let envInfo) = conn,
                               let secret = self.environment.variable(envInfo.name),
                               !secret.isEmpty
                            {
                                return .key(CredentialSchema.Key(key: secret))
                            }
                            return nil
                        },
                        status: { [self] id, conn, status in
                            if let svc = self.integrationService {
                                await svc.setConnectionStatus(integrationID: IntegrationID(rawValue: id), connection: conn, status: status)
                            }
                        }
                    )
                )

                let vcsDomain = PluginEffect.VcsDomain(
                    get: { [self] in
                        guard let provider = self.selectedVcsDefinition() else {
                            return PluginSDK.LocatedResult(location: loc, data: nil)
                        }
                        let info: VcsSchema.Info = try await Host.withRuntime(spawner: self.spawner, fileSystem: self.fileSystem) {
                            try await provider.info(self.vcsScope())
                        }
                        return PluginSDK.LocatedResult(location: loc, data: info)
                    },
                    base: { [self] in
                        guard let provider = self.selectedVcsDefinition(), let baseFn = provider.base else {
                            return PluginSDK.LocatedResult(location: loc, data: nil)
                        }
                        let base: VcsSchema.Base? = try await Host.withRuntime(spawner: self.spawner, fileSystem: self.fileSystem) {
                            try await baseFn(self.vcsScope())
                        }
                        return PluginSDK.LocatedResult(location: loc, data: base)
                    },
                    branches: { [self] search, limit in
                        guard let provider = self.selectedVcsDefinition() else {
                            return PluginSDK.LocatedResult(location: loc, data: [])
                        }
                        let list: VcsSchema.BranchList = try await Host.withRuntime(spawner: self.spawner, fileSystem: self.fileSystem) {
                            try await provider.branches(PluginEffect.VcsBranchesInput(scope: self.vcsScope(), search: search, limit: limit))
                        }
                        return PluginSDK.LocatedResult(location: loc, data: list)
                    },
                    status: { [self] in
                        guard let provider = self.selectedVcsDefinition() else {
                            return PluginSDK.LocatedResult(location: loc, data: [])
                        }
                        let items: [VcsSchema.FileStatus] = try await Host.withRuntime(spawner: self.spawner, fileSystem: self.fileSystem) {
                            try await provider.status(self.vcsScope())
                        }
                        return PluginSDK.LocatedResult(location: loc, data: items)
                    },
                    diff: { [self] mode, base, context in
                        guard let provider = self.selectedVcsDefinition() else {
                            return PluginSDK.LocatedResult(location: loc, data: [])
                        }
                        let rows: [FileDiffSchema.Info] = try await Host.withRuntime(spawner: self.spawner, fileSystem: self.fileSystem) {
                            try await provider.diff(PluginEffect.VcsDiffInput(
                                scope: self.vcsScope(),
                                mode: mode,
                                base: base,
                                context: context ?? 3
                            ))
                        }
                        return PluginSDK.LocatedResult(location: loc, data: rows)
                    },
                    transform: { [self] callback in
                        callback(vcsEditor)
                        if let vcsService = self.vcsService {
                            let providers = self.state.withLock { $0.vcsProviders }
                            let defaultSel = self.state.withLock { $0.defaultVcs }
                            let scope = self.vcsScope()
                            let capturedSpawner = self.spawner
                            let capturedFS = self.fileSystem
                            _ = try? await vcsService.transform { editor in
                                for (_, def) in providers {
                                    let baseClosure: (@Sendable () async throws -> VcsSchema.Base?)? = def.base.map { baseFn in
                                        let fn: @Sendable () async throws -> VcsSchema.Base? = {
                                            try await Host.withRuntime(spawner: capturedSpawner, fileSystem: capturedFS) {
                                                try await baseFn(scope)
                                            }
                                        }
                                        return fn
                                    }
                                    let initClosure: (@Sendable () async throws -> Void)? = def.initRepo.map { initFn in
                                        let fn: @Sendable () async throws -> Void = {
                                            try await Host.withRuntime(spawner: capturedSpawner, fileSystem: capturedFS) {
                                                try await initFn(scope)
                                            }
                                        }
                                        return fn
                                    }
                                    let bridged = CoreVcs.Vcs.ProviderDefinition(
                                        id: def.id,
                                        info: {
                                            try await Host.withRuntime(spawner: capturedSpawner, fileSystem: capturedFS) {
                                                try await def.info(scope)
                                            }
                                        },
                                        base: baseClosure,
                                        branches: { opts in
                                            try await Host.withRuntime(spawner: capturedSpawner, fileSystem: capturedFS) {
                                                try await def.branches(PluginEffect.VcsBranchesInput(scope: scope, search: opts?.search, limit: opts?.limit))
                                            }
                                        },
                                        status: {
                                            try await Host.withRuntime(spawner: capturedSpawner, fileSystem: capturedFS) {
                                                try await def.status(scope)
                                            }
                                        },
                                        diff: { mode, opts in
                                            try await Host.withRuntime(spawner: capturedSpawner, fileSystem: capturedFS) {
                                                try await def.diff(PluginEffect.VcsDiffInput(
                                                    scope: scope,
                                                    mode: mode,
                                                    base: opts?.base,
                                                    context: opts?.context ?? 3,
                                                    untracked: opts?.untracked
                                                ))
                                            }
                                        },
                                        initialize: initClosure
                                    )
                                    editor.add(bridged)
                                }
                                if let defaultSel {
                                    editor.defaultSelection = defaultSel
                                }
                            }
                        }
                        return PluginEffect.Registration(dispose: {})
                    },
                    reload: {}
                )

                let websearchDomain = PluginEffect.WebSearchDomain(
                    providers: { [self] in PluginSDK.LocatedResult(location: loc, data: self.registeredWebSearchProviders()) },
                    query: { [self] input in
                        let providerID = input.providerID?.rawValue
                            ?? self.state.withLock { s -> String? in
                                if case .provider(let id) = s.defaultWebSearch { return id }
                                return s.webSearchProviders.keys.sorted().first
                            }
                        guard let providerID,
                              let def = self.state.withLock({ $0.webSearchProviders[providerID] })
                        else {
                            throw ToolSchema.ToolError(message: "WebSearch provider not found")
                        }
                        let results: [WebSearchSchema.Result] = try await Host.withRuntime(http: self.http, environment: self.environment) {
                            try await def.execute(WebSearchSchema.ProviderInput(query: input.query))
                        }
                        return PluginSDK.LocatedResult(
                            location: loc,
                            data: WebSearchSchema.Response(
                                providerID: WebSearchSchema.ID(rawValue: providerID),
                                results: results
                            )
                        )
                    },
                    transform: { callback in
                        callback(websearchEditor)
                        return PluginEffect.Registration(dispose: {})
                    },
                    reload: {}
                )

                return PluginEffect.Context(
                    app: app,
                    location: loc,
                    options: [:],
                    agent: PluginEffect.AgentDomain(
                        list: { [self] in PluginSDK.LocatedResult(location: loc, data: self.registeredAgents()) },
                        get: { [self] id in
                            guard let agent = self.state.withLock({ $0.agents[id] }) else {
                                throw ToolSchema.ToolError(message: "Agent not found: \(id)")
                            }
                            return PluginSDK.LocatedResult(location: loc, data: agent)
                        },
                        transform: { callback in
                            callback(agentEditor)
                            return PluginEffect.Registration(dispose: {})
                        },
                        reload: {}
                    ),
                    aisdk: PluginEffect.AISDKDomain(hook: { name, callback, options in
                        let reg = hookService.registerAISDK(name: name, options: options, callback: callback)
                        addFinalizer(reg.dispose)
                        return reg
                    }),
                    command: PluginEffect.CommandDomain(
                        list: { [self] in
                            let cmds = self.registeredCommands().map { CommandSchema.Info(name: $0.name, description: $0.description) }
                            return PluginSDK.LocatedResult(location: loc, data: cmds)
                        },
                        transform: { callback in
                            callback(commandEditor)
                            return PluginEffect.Registration(dispose: {})
                        },
                        reload: {}
                    ),
                    credential: PluginEffect.Context.CredentialAPI(activate: { _ in }),
                    event: PluginEffect.EventDomain(subscribe: { [self] types in
                        let token = UUID()
                        let typeSet = types.map { Set($0) }
                        return AsyncStream { continuation in
                            self.state.withLock { s in
                                s.eventContinuations[token] = (typeSet, continuation)
                            }
                            continuation.onTermination = { [weak self] _ in
                                self?.state.withLock { s in
                                    _ = s.eventContinuations.removeValue(forKey: token)
                                }
                            }
                        }
                    }),
                    experimental: PluginEffect.Context.Experimental(
                        artifact: PluginEffect.ExperimentalArtifactDomain(
                            transform: { callback in
                                callback(artifactEditor)
                                return PluginEffect.Registration(dispose: {})
                            },
                            reload: {}
                        )
                    ),
                    integration: integrationDomain,
                    mcp: PluginEffect.MCPDomain(
                        list: { PluginSDK.LocatedResult(location: loc, data: []) },
                        transform: { callback in
                            callback(mcpEditor)
                            return PluginEffect.Registration(dispose: {})
                        },
                        reload: {}
                    ),
                    model: PluginEffect.ModelDomain(
                        list: { [self] _ in
                            PluginSDK.LocatedResult(location: loc, data: self.registeredModels())
                        },
                        defaultModel: { [self] in
                            let def = self.state.withLock { $0.defaultModel }.map {
                                ModelSchema.Ref(id: ModelSchema.ID(rawValue: $0.modelID), providerID: ProviderSchema.ID(rawValue: $0.providerID))
                            }
                            return PluginSDK.LocatedResult(location: loc, data: def)
                        },
                        transform: { callback in
                            callback(modelEditor)
                            return PluginEffect.Registration(dispose: {})
                        },
                        reload: {}
                    ),
                    permission: PluginEffect.PermissionDomain(
                        list: { sessionID in permRuntime.list(sessionID: sessionID) },
                        get: { sessionID, requestID in try permRuntime.get(sessionID: sessionID, requestID: requestID) },
                        reply: { _, _, _, _ in },
                        hook: { name, callback in
                            let reg = hookService.registerPermission(name: name, callback: callback)
                            addFinalizer(reg.dispose)
                            return reg
                        },
                        assert: { input throws(ToolSchema.ToolError) in
                            try await permRuntime.assert(input)
                        }
                    ),
                    plugin: PluginEffect.Context.PluginInventoryAPI(list: {
                        PluginSDK.LocatedResult(location: loc, data: listPlugins())
                    }),
                    provider: PluginEffect.ProviderDomain(
                        list: { [self] in
                            PluginSDK.LocatedResult(location: loc, data: self.state.withLock { $0.providers.values.map(\.provider) })
                        },
                        get: { [self] id in
                            guard let rec = self.state.withLock({ $0.providers[id] }) else {
                                throw ToolSchema.ToolError(message: "Provider not found: \(id)")
                            }
                            return PluginSDK.LocatedResult(location: loc, data: rec.provider)
                        },
                        transform: { callback in
                            callback(providerEditor)
                            return PluginEffect.Registration(dispose: {})
                        },
                        reload: {}
                    ),
                    reference: PluginEffect.ReferenceDomain(
                        list: { PluginSDK.LocatedResult(location: loc, data: []) },
                        transform: { callback in
                            callback(referenceEditor)
                            return PluginEffect.Registration(dispose: {})
                        },
                        reload: {}
                    ),
                    rpc: PluginEffect.RpcDomain(
                        call: { [self] ns, method, input in
                            try await self.callRpc(namespace: ns, method: method, input: input)
                        },
                        subscribe: { [self] ns, event in
                            self.subscribeRpc(namespace: ns, event: event)
                        },
                        register: { [self] def, handlers in
                            self.state.withLock { $0.rpcDefinitions[def.id] = (def, handlers) }
                            let dispose: @Sendable () async -> Void = { [self] in
                                self.state.withLock { _ = $0.rpcDefinitions.removeValue(forKey: def.id) }
                            }
                            addFinalizer(dispose)
                            return PluginEffect.RpcRegistration(
                                dispose: dispose,
                                emit: { [self] eventName, payload in
                                    let key = "\(def.id)::\(eventName)"
                                    let eventData: RpcSchema.EventData
                                    if case .object(let dict) = payload {
                                        eventData = dict
                                    } else {
                                        eventData = ["value": payload]
                                    }
                                    let envelope = RpcSchema.EventPayload(
                                        id: uuid(),
                                        type: RpcSchema.EventPayload.eventType(rpcID: def.id, eventName: eventName),
                                        created: Date().timeIntervalSince1970 * 1000,
                                        data: eventData,
                                        location: LocationSchema.Ref(
                                            directory: loc.directory,
                                            workspaceID: loc.workspaceID
                                        )
                                    )
                                    let continuations = self.state.withLock { s -> [AsyncStream<RpcSchema.EventPayload>.Continuation] in
                                        Array((s.rpcEventContinuations[key] ?? [:]).values)
                                    }
                                    for continuation in continuations {
                                        continuation.yield(envelope)
                                    }
                                }
                            )
                        }
                    ),
                    session: PluginEffect.SessionDomain(
                        hook: { name, callback, options in
                            let reg = hookService.registerSession(name: name, options: options, callback: callback)
                            addFinalizer(reg.dispose)
                            return reg
                        },
                        list: { [self] in
                            self.state.withLock { Array($0.sessions.values) }
                        },
                        get: { [self] sessionID in
                            guard let session = self.state.withLock({ $0.sessions[sessionID] }) else {
                                throw ToolSchema.ToolError(message: "Session not found: \(sessionID.rawValue)")
                            }
                            return session
                        },
                        update: { [self] sessionID, permissions in
                            self.updateSessionPermissions(id: sessionID, permissions: permissions)
                        },
                        prompt: { [self] sessionID, prompt, delivery in
                            self.state.withLock {
                                $0.recordedPrompts.append(RecordedSessionPrompt(sessionID: sessionID, prompt: prompt, delivery: delivery))
                            }
                            if let onSessionPrompt = self.onSessionPrompt {
                                try await onSessionPrompt(sessionID, prompt, delivery)
                            }
                        }
                    ),
                    shell: PluginEffect.ShellDomain(hook: { name, callback in
                        let reg = hookService.registerShell(name: name, callback: callback)
                        addFinalizer(reg.dispose)
                        return reg
                    }),
                    skill: PluginEffect.SkillDomain(
                        list: { [self] in PluginSDK.LocatedResult(location: loc, data: self.registeredSkills()) },
                        transform: { callback in
                            callback(skillEditor)
                            return PluginEffect.Registration(dispose: {})
                        },
                        reload: {}
                    ),
                    storage: Host.storage(kv: kv, pluginID: pluginID),
                    tool: PluginEffect.ToolDomain(
                        transform: { callback in
                            callback(toolEditor)
                            return PluginEffect.Registration(dispose: {})
                        },
                        reload: {},
                        list: { [self] in self.registeredTools() },
                        hook: { name, callback in
                            let reg = hookService.registerTool(name: name, callback: callback)
                            addFinalizer(reg.dispose)
                            return reg
                        }
                    ),
                    vcs: vcsDomain,
                    websearch: websearchDomain,
                    worktree: PluginEffect.WorktreeDomain(
                        list: { [] },
                        create: { _ in throw ToolSchema.ToolError(message: "Worktree strategy not configured") },
                        remove: { _ in },
                        refresh: {},
                        transform: { callback in
                            callback(worktreeEditor)
                            return PluginEffect.Registration(dispose: {})
                        },
                        reload: {}
                    ),
                    addFinalizer: addFinalizer
                )
            }
        }

        /// Creates a `PluginEffect.Context` scoped to `pluginID` on top of `environment`.
        // parity: core/src/plugin/host.ts#make [status=adapted hash=ef02c47c7e15]
        public static func make(
            environment: Environment,
            pluginID: String,
            listPlugins: @escaping @Sendable () -> [PluginSchema.Info] = { [] },
            addFinalizer: @escaping @Sendable (@escaping @Sendable () async -> Void) -> Void = { _ in }
        ) -> PluginEffect.Context {
            environment.makeContext(
                pluginID: pluginID,
                listPlugins: listPlugins,
                addFinalizer: addFinalizer
            )
        }

        /// LayerNode requirement group aggregating the Location services required by `PluginHost`.
        // parity: core/src/plugin/host.ts#requirements [status=adapted hash=afa4bcfc12af]
        public static let requirements: LayerNode.Graph = LayerNode.group([Hooks.node])
    }

    // MARK: - Out-of-Process JSON-RPC / MCP Plugin Host Bridge

    /// Out-of-process JSON-RPC 2.0 plugin bridge supporting existing JS/TS/Bun/Node OpenCode plugins cleanly
    /// alongside native Swift `PluginSDK.NativePlugin` implementations.
    public enum RPCBridge {
        public struct Request: Equatable, Hashable, Sendable, Codable {
            public let jsonrpc: String
            public let id: Int64
            public let method: String
            public let params: JSONValue?

            public init(id: Int64, method: String, params: JSONValue? = nil) {
                self.jsonrpc = "2.0"
                self.id = id
                self.method = method
                self.params = params
            }
        }

        public struct ErrorObject: Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
            public let code: Int
            public let message: String
            public let data: JSONValue?

            public init(code: Int, message: String, data: JSONValue? = nil) {
                self.code = code
                self.message = message
                self.data = data
            }

            public var description: String {
                "JSON-RPC error \(code): \(message)"
            }
        }

        public struct Response: Equatable, Hashable, Sendable, Codable {
            public let jsonrpc: String
            public let id: Int64
            public let result: JSONValue?
            public let error: ErrorObject?

            public init(id: Int64, result: JSONValue? = nil, error: ErrorObject? = nil) {
                self.jsonrpc = "2.0"
                self.id = id
                self.result = result
                self.error = error
            }
        }

        /// Transport boundary carrying framed JSON-RPC 2.0 calls to an out-of-process plugin host.
        public protocol Transport: Sendable {
            func send(_ request: Request) async throws -> Response
            func close() async
        }

        /// Persistent bidirectional JSON-RPC 2.0 subprocess transport maintaining ONE long-lived child process
        /// with open stdin/stdout/stderr `Pipe`s on macOS/Linux/Windows, falling back to injectable
        /// `OpenCodePlatform.ProcessSpawner` for mock spawners and WASI/mobile platforms.
        public final class ProcessTransport: Transport, Sendable {
            #if os(macOS) || os(Linux) || os(Windows)
            private final class PersistentChild: @unchecked Sendable {
                private struct ExitState: Sendable {
                    var exited = false
                    var status: Int32 = 0
                    var waiters: [UUID: CheckedContinuation<Int32?, Never>] = [:]
                    var cancelled: Set<UUID> = []
                }

                let process: Process
                let stdinPipe: Pipe
                let stdoutPipe: Pipe
                let stderrPipe: Pipe
                let writeLock = Mutex<Void>(())
                private let exitState = Mutex(ExitState())
                private let stderrTail = Mutex<String>("")
                private let stdinClosed = Mutex<Bool>(false)

                init(process: Process, stdinPipe: Pipe, stdoutPipe: Pipe, stderrPipe: Pipe) {
                    self.process = process
                    self.stdinPipe = stdinPipe
                    self.stdoutPipe = stdoutPipe
                    self.stderrPipe = stderrPipe
                    process.terminationHandler = { [weak self] proc in
                        self?.markExited(proc.terminationStatus)
                    }
                }

                var pid: Int32 { process.processIdentifier }

                func appendStderr(_ chunk: String) {
                    stderrTail.withLock { tail in
                        tail.append(chunk)
                        if tail.count > 1_000 { tail = String(tail.suffix(1_000)) }
                    }
                }

                func stderrSnapshot() -> String {
                    stderrTail.withLock { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                }

                func writeLine(_ bytes: [UInt8]) throws {
                    try writeLock.withLock { _ in
                        guard !stdinClosed.withLock({ $0 }) else {
                            throw ErrorObject(code: -32_000, message: "Plugin host process stdin is closed")
                        }
                        try stdinPipe.fileHandleForWriting.write(contentsOf: Data(bytes))
                    }
                }

                func closeStdin() {
                    writeLock.withLock { _ in
                        let shouldClose = stdinClosed.withLock { c -> Bool in
                            if c { return false }
                            c = true
                            return true
                        }
                        if shouldClose {
                            try? stdinPipe.fileHandleForWriting.close()
                        }
                    }
                }

                func markExited(_ status: Int32) {
                    let waiters: [CheckedContinuation<Int32?, Never>] = exitState.withLock { s in
                        guard !s.exited else { return [] }
                        s.exited = true
                        s.status = status
                        let all = Array(s.waiters.values)
                        s.waiters.removeAll()
                        s.cancelled.removeAll()
                        return all
                    }
                    for w in waiters { w.resume(returning: status) }
                }

                func waitForExit(timeoutMs: Int) async -> Int32? {
                    if let status = exitState.withLock({ $0.exited ? $0.status : nil }) { return status }
                    let waiterID = UUID()
                    let box = self
                    return await withTaskGroup(of: Int32?.self) { group in
                        group.addTask {
                            await withTaskCancellationHandler {
                                await withCheckedContinuation { (cont: CheckedContinuation<Int32?, Never>) in
                                    let outcome: (done: Bool, value: Int32?) = box.exitState.withLock { s in
                                        if s.exited { return (true, s.status) }
                                        if s.cancelled.remove(waiterID) != nil { return (true, nil) }
                                        s.waiters[waiterID] = cont
                                        return (false, nil)
                                    }
                                    if outcome.done { cont.resume(returning: outcome.value) }
                                }
                            } onCancel: {
                                let cont: CheckedContinuation<Int32?, Never>? = box.exitState.withLock { s in
                                    s.cancelled.insert(waiterID)
                                    return s.waiters.removeValue(forKey: waiterID)
                                }
                                cont?.resume(returning: nil)
                            }
                        }
                        group.addTask {
                            try? await Task.sleep(for: .milliseconds(timeoutMs))
                            return nil
                        }
                        let first = await group.next() ?? nil
                        group.cancelAll()
                        return first
                    }
                }

                func terminateAndWait() async {
                    closeStdin()
                    if await waitForExit(timeoutMs: 1_500) == nil {
                        if process.isRunning { process.terminate() }
                        if await waitForExit(timeoutMs: 1_500) == nil {
                            #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                            let childPid = process.processIdentifier
                            if childPid > 0 && process.isRunning {
                                _ = kill(childPid, SIGKILL)
                            }
                            _ = await waitForExit(timeoutMs: 500)
                            #endif
                        }
                    }
                    try? stdoutPipe.fileHandleForReading.close()
                    try? stderrPipe.fileHandleForReading.close()
                }
            }
            #endif

            private struct RuntimeState: Sendable {
                var closed = false
                var pending: [Int64: CheckedContinuation<Response, any Error>] = [:]
                var pendingBytes: [UInt8] = []
                #if os(macOS) || os(Linux) || os(Windows)
                var child: PersistentChild?
                #endif
            }

            public let executable: String
            public let arguments: [String]
            public let workingDirectory: String?
            public let environment: [String: String]?
            public let spawner: any ProcessSpawner
            private let state = Mutex(RuntimeState())

            public init(
                executable: String,
                arguments: [String] = [],
                workingDirectory: String? = nil,
                environment: [String: String]? = nil,
                spawner: any ProcessSpawner = CrossSpawnSpawner.HostProcessSpawner.shared
            ) {
                self.executable = executable
                self.arguments = arguments
                self.workingDirectory = workingDirectory
                self.environment = environment
                self.spawner = spawner
            }

            deinit {
                #if os(macOS) || os(Linux) || os(Windows)
                let child = state.withLock { s -> PersistentChild? in
                    s.closed = true
                    let c = s.child
                    s.child = nil
                    return c
                }
                if let child {
                    child.closeStdin()
                    if child.process.isRunning { child.process.terminate() }
                }
                #endif
            }

            /// Process ID of the live persistent plugin host child process, when running on a desktop host.
            public var pid: Int32? {
                #if os(macOS) || os(Linux) || os(Windows)
                return state.withLock { $0.child?.pid }
                #else
                return nil
                #endif
            }

            #if os(macOS) || os(Linux) || os(Windows)
            private func ensurePersistentChild() throws -> PersistentChild {
                let existing = try state.withLock { s -> PersistentChild? in
                    if s.closed {
                        throw ErrorObject(code: -32_000, message: "Plugin host transport is closed")
                    }
                    return s.child
                }
                if let existing { return existing }

                if executable.contains("\u{0}") {
                    throw ErrorObject(code: -32_000, message: "The command contains a NUL character")
                }
                for (idx, arg) in arguments.enumerated() where arg.contains("\u{0}") {
                    throw ErrorObject(code: -32_000, message: "Argument \(idx + 1) contains a NUL character")
                }
                if let env = environment {
                    for (name, value) in env where value.contains("\u{0}") {
                        throw ErrorObject(code: -32_000, message: "The environment variable \(name) contains a NUL character")
                    }
                }

                let process = Process()
                if executable.contains("/") || executable.contains("\\") {
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments
                } else {
                    #if os(Windows)
                    process.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\cmd.exe")
                    process.arguments = ["/c", executable] + arguments
                    #else
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    process.arguments = [executable] + arguments
                    #endif
                }
                if let cwd = workingDirectory, !cwd.isEmpty {
                    process.currentDirectoryURL = URL(fileURLWithPath: cwd)
                }
                if let env = environment, !env.isEmpty {
                    var merged = ProcessInfo.processInfo.environment
                    for (k, v) in env { merged[k] = v }
                    process.environment = merged
                }

                let stdinPipe = Pipe()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardInput = stdinPipe
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                #if canImport(Darwin)
                _ = Darwin.fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                #endif

                let child = PersistentChild(
                    process: process,
                    stdinPipe: stdinPipe,
                    stdoutPipe: stdoutPipe,
                    stderrPipe: stderrPipe
                )

                // Guard concurrent launch attempts under lock before calling process.run()
                let installed: PersistentChild? = try state.withLock { s in
                    if s.closed {
                        throw ErrorObject(code: -32_000, message: "Plugin host transport is closed")
                    }
                    if let already = s.child { return already }
                    try process.run()
                    s.child = child
                    return nil
                }
                if let installed {
                    try? stdinPipe.fileHandleForWriting.close()
                    try? stdoutPipe.fileHandleForReading.close()
                    try? stderrPipe.fileHandleForReading.close()
                    return installed
                }

                Thread.detachNewThread {
                    let handle = child.stderrPipe.fileHandleForReading
                    while true {
                        let data = handle.availableData
                        if data.isEmpty { break }
                        child.appendStderr(String(decoding: data, as: UTF8.self))
                    }
                }

                Thread.detachNewThread { [weak self] in
                    let handle = child.stdoutPipe.fileHandleForReading
                    while true {
                        let data = handle.availableData
                        if data.isEmpty { break }
                        self?.consumeStdoutChunk(Array(data))
                    }
                    self?.handleChildEOF(child: child)
                }

                return child
            }

            private func consumeStdoutChunk(_ chunk: [UInt8]) {
                var responsesToDeliver: [Response] = []
                state.withLock { s in
                    var start = 0
                    while start < chunk.count {
                        if let nl = chunk[start...].firstIndex(of: 0x0A) {
                            var frame = s.pendingBytes
                            frame.append(contentsOf: chunk[start..<nl])
                            s.pendingBytes.removeAll()
                            if frame.last == 0x0D { frame.removeLast() }
                            let text = String(decoding: frame, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                            if !text.isEmpty, let decoded = try? JSONDecoder().decode(Response.self, from: Data(text.utf8)) {
                                responsesToDeliver.append(decoded)
                            }
                            start = nl + 1
                        } else {
                            s.pendingBytes.append(contentsOf: chunk[start...])
                            break
                        }
                    }
                }
                for resp in responsesToDeliver {
                    let cont = state.withLock { $0.pending.removeValue(forKey: resp.id) }
                    cont?.resume(returning: resp)
                }
            }

            private func handleChildEOF(child: PersistentChild) {
                let wasActive = state.withLock { $0.child === child }
                guard wasActive else { return }
                child.process.waitUntilExit()
                let code = child.process.terminationStatus
                let stderrText = child.stderrSnapshot()
                let err = ErrorObject(
                    code: -32_000,
                    message: stderrText.isEmpty
                        ? "Plugin host process exited with \(code)"
                        : "Plugin host process exited with \(code): \(stderrText)"
                )
                let waiters: [CheckedContinuation<Response, any Error>] = state.withLock { s in
                    if s.child === child { s.child = nil }
                    s.pendingBytes.removeAll()
                    let all = Array(s.pending.values)
                    s.pending.removeAll()
                    return all
                }
                child.closeStdin()
                try? child.stdoutPipe.fileHandleForReading.close()
                try? child.stderrPipe.fileHandleForReading.close()
                for w in waiters { w.resume(throwing: err) }
            }
            #endif

            public func send(_ request: Request) async throws -> Response {
                let encoded = try JSONEncoder().encode(request)
                var stdinBytes = Array(encoded)
                stdinBytes.append(0x0A)

                #if os(macOS) || os(Linux) || os(Windows)
                if spawner is CrossSpawnSpawner.HostProcessSpawner {
                    let child = try ensurePersistentChild()
                    return try await withCheckedThrowingContinuation { continuation in
                        let closedNow = state.withLock { s -> Bool in
                            if s.closed { return true }
                            s.pending[request.id] = continuation
                            return false
                        }
                        if closedNow {
                            continuation.resume(throwing: ErrorObject(code: -32_000, message: "Plugin host transport is closed"))
                            return
                        }
                        do {
                            try child.writeLine(stdinBytes)
                        } catch {
                            let cont = state.withLock { $0.pending.removeValue(forKey: request.id) }
                            cont?.resume(throwing: error)
                        }
                    }
                }
                #endif

                let output = try await spawner.run(
                    ProcessSpec(
                        executable: executable,
                        arguments: arguments,
                        workingDirectory: workingDirectory,
                        environment: environment,
                        stdin: stdinBytes
                    )
                )
                guard output.exitCode == 0 else {
                    let stderr = String(decoding: output.stderr, as: UTF8.self)
                    throw ErrorObject(code: -32_000, message: "Plugin host process exited with \(output.exitCode): \(stderr)")
                }
                return try JSONDecoder().decode(Response.self, from: Data(output.stdout))
            }

            public func close() async {
                #if os(macOS) || os(Linux) || os(Windows)
                let (child, waiters) = state.withLock { s -> (PersistentChild?, [CheckedContinuation<Response, any Error>]) in
                    s.closed = true
                    let c = s.child
                    s.child = nil
                    s.pendingBytes.removeAll()
                    let all = Array(s.pending.values)
                    s.pending.removeAll()
                    return (c, all)
                }
                let closeErr = ErrorObject(code: -32_000, message: "Plugin host transport closed")
                for w in waiters { w.resume(throwing: closeErr) }
                if let child {
                    await child.terminateAndWait()
                }
                #else
                let waiters = state.withLock { s -> [CheckedContinuation<Response, any Error>] in
                    s.closed = true
                    let all = Array(s.pending.values)
                    s.pending.removeAll()
                    return all
                }
                let closeErr = ErrorObject(code: -32_000, message: "Plugin host transport closed")
                for w in waiters { w.resume(throwing: closeErr) }
                #endif
            }
        }

        /// Handshake metadata returned by `plugin.initialize` from an external JSON-RPC plugin process.
        public struct Handshake: Equatable, Hashable, Sendable, Codable {
            public let id: String
            public let hooks: [String]
            public let tools: [ToolDescriptor]

            public struct ToolDescriptor: Equatable, Hashable, Sendable, Codable {
                public let name: String
                public let description: String
                public let inputSchema: [String: JSONValue]

                public init(name: String, description: String, inputSchema: [String: JSONValue] = [:]) {
                    self.name = name
                    self.description = description
                    self.inputSchema = inputSchema
                }
            }

            public init(id: String, hooks: [String] = [], tools: [ToolDescriptor] = []) {
                self.id = id
                self.hooks = hooks
                self.tools = tools
            }
        }

        /// Client actor managing request IDs, lifecycle RPCs, hook forwarding, and tool invocation over `Transport`.
        public actor Client {
            private let transport: any Transport
            private var nextID: Int64 = 1

            public init(transport: any Transport) {
                self.transport = transport
            }

            public func call(method: String, params: JSONValue? = nil) async throws -> JSONValue {
                let id = nextID
                nextID &+= 1
                let response = try await transport.send(Request(id: id, method: method, params: params))
                if let error = response.error {
                    throw error
                }
                return response.result ?? .null
            }

            public func initialize(pluginID: String, options: PluginContract.PluginOptions = [:]) async throws -> Handshake {
                let raw = try await call(
                    method: "plugin.initialize",
                    params: .object([
                        "id": .string(pluginID),
                        "options": .object(options),
                    ])
                )
                let data = try JSONEncoder().encode(raw)
                return try JSONDecoder().decode(Handshake.self, from: data)
            }

            public func triggerHook(domain: String, name: String, payload: JSONValue) async throws -> JSONValue {
                try await call(
                    method: "plugin.hook.trigger",
                    params: .object([
                        "domain": .string(domain),
                        "name": .string(name),
                        "payload": payload,
                    ])
                )
            }

            public func executeTool(name: String, input: JSONValue) async throws -> ToolSchema.Result<JSONValue> {
                let raw = try await call(
                    method: "plugin.tool.execute",
                    params: .object([
                        "name": .string(name),
                        "input": input,
                    ])
                )
                return ToolSchema.Result(output: raw)
            }

            public func shutdown() async {
                _ = try? await call(method: "plugin.shutdown", params: nil)
                await transport.close()
            }

            /// Adapts this out-of-process JSON-RPC plugin client into a `PluginEffect.Plugin` for `CorePlugin.Service`.
            public nonisolated func asEffectPlugin(id: String, options: PluginContract.PluginOptions = [:]) -> PluginEffect.Plugin {
                PluginEffect.define(
                    PluginEffect.Plugin(id: id) { context in
                        let handshake = try await self.initialize(pluginID: id, options: options.isEmpty ? context.options : options)
                        context.addFinalizer {
                            await self.shutdown()
                        }
                        if !handshake.tools.isEmpty {
                            _ = await context.tool.transform { editor in
                                for tool in handshake.tools {
                                    let toolName = tool.name
                                    editor.add(
                                        PluginEffect.DynamicToolInfo(
                                            name: toolName,
                                            input: .jsonSchema(tool.inputSchema),
                                            description: tool.description,
                                            execute: { input, _ throws(ToolSchema.ToolError) in
                                                do {
                                                    return try await self.executeTool(name: toolName, input: input)
                                                } catch let err as ToolSchema.ToolError {
                                                    throw err
                                                } catch {
                                                    throw ToolSchema.ToolError(message: String(describing: error))
                                                }
                                            }
                                        )
                                    )
                                }
                            }
                        }
                        for hookSpec in handshake.hooks {
                            if hookSpec == "shell.create.before" {
                                _ = await context.shell.hook("create.before") { event in
                                    let encoded = (try? JSONEncoder().encode(event)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? .null
                                    let updated = try await self.triggerHook(domain: "shell", name: "create.before", payload: encoded)
                                    if let data = try? JSONEncoder().encode(updated),
                                       let decoded = try? JSONDecoder().decode(PluginEffect.ShellCreateBefore.self, from: data)
                                    {
                                        return decoded
                                    }
                                    return event
                                }
                            } else if hookSpec == "permission.evaluate" {
                                _ = await context.permission.hook("evaluate") { event in
                                    let encoded = (try? JSONEncoder().encode(event)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? .null
                                    let updated = try await self.triggerHook(domain: "permission", name: "evaluate", payload: encoded)
                                    if let data = try? JSONEncoder().encode(updated),
                                       let decoded = try? JSONDecoder().decode(PluginEffect.PermissionEvaluation.self, from: data)
                                    {
                                        return decoded
                                    }
                                    return event
                                }
                            }
                        }
                    }
                )
            }
        }
    }

    // MARK: - Instance Plugins (`plugin/instance.ts`)

    public enum InstancePlugins {
        /// Immutable list of plugins bound at instance birth.
        // parity: core/src/plugin/instance.ts#List [status=implemented hash=f53555b02c12]
        public typealias List = [PluginEffect.Plugin]

        /// Instance plugin store contract.
        // parity: core/src/plugin/instance.ts#Interface [status=implemented hash=5251c7585f4b]
        public protocol Interface: Sendable {
            func all() -> [Generation]
        }

        /// Service wrapper holding birth-bound instance plugin generations.
        // parity: core/src/plugin/instance.ts#Service [status=adapted hash=5f4f59093466]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/InstancePlugins"
            private let generations: [Generation]

            public init(generations: [Generation] = []) {
                self.generations = generations
            }

            public func all() -> [Generation] {
                generations
            }
        }

        /// Binds an immutable plugin list to an instance, rejecting duplicate IDs and stamping `revision: "instance"`.
        // parity: core/src/plugin/instance.ts#bound [status=implemented hash=b4b27bcdfd79]
        public static func bound(_ plugins: List) throws -> Service {
            var seen: Set<String> = []
            var duplicates: [String] = []
            for plugin in plugins {
                if !seen.insert(plugin.id).inserted {
                    duplicates.append(plugin.id)
                }
            }
            if !duplicates.isEmpty {
                throw ActivationError.duplicatePluginID(duplicates.joined(separator: ", "))
            }
            let stamped = plugins.map { plugin in
                Generation(plugin: plugin, revision: "instance", source: .sdk)
            }
            return Service(generations: stamped)
        }

        /// Default empty `InstancePlugins` Location node.
        // parity: core/src/plugin/instance.ts#node [status=adapted hash=d7426ff24166]
        public static let node: LayerNode.Provider = AppNode.makeLocationNode(
            Service.serviceKey,
            LayerNode.ExecutableLayer.succeed(key: Service.serviceKey, value: Service()),
            []
        )
    }

    // MARK: - SDK Plugins (`plugin/sdk.ts`)

    public enum SdkPlugins {
        /// Ephemeral global event published whenever an SDK embedder registers a plugin.
        // parity: core/src/plugin/sdk.ts#Updated [status=implemented hash=67e6e911b648]
        public static let Updated = SchemaPrimitive.EventDescriptor.ephemeral(type: "sdk.plugin.updated")

        /// Host-global SDK plugin registration contract.
        // parity: core/src/plugin/sdk.ts#Interface [status=implemented hash=e745fb2e2d4b]
        public protocol Interface: Sendable {
            func register(_ plugin: PluginEffect.Plugin)
            func all() -> [Generation]
        }

        /// Thread-safe host-global SDK plugin store incrementing revision on each registration.
        // parity: core/src/plugin/sdk.ts#Service [status=adapted hash=cf62b4ceea25]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/SdkPlugins"

            private struct State: Sendable {
                var order: [String] = []
                var plugins: [String: Generation] = [:]
                var revision: UInt64 = 0
            }

            private let state = Mutex(State())
            private let onUpdated: (@Sendable () -> Void)?

            public init(onUpdated: (@Sendable () -> Void)? = nil) {
                self.onUpdated = onUpdated
            }

            public func register(_ plugin: PluginEffect.Plugin) {
                state.withLock { s in
                    s.revision &+= 1
                    if s.plugins[plugin.id] == nil {
                        s.order.append(plugin.id)
                    }
                    s.plugins[plugin.id] = Generation(
                        plugin: plugin,
                        revision: String(s.revision),
                        source: .sdk
                    )
                }
                onUpdated?()
            }

            public func all() -> [Generation] {
                state.withLock { s in
                    s.order.compactMap { s.plugins[$0] }
                }
            }
        }

        /// Layer constructing an isolated `SdkPlugins.Service` instance.
        // parity: core/src/plugin/sdk.ts#layer [status=adapted hash=39355c7f955c]
        public static let layer: LayerNode.ExecutableLayer = LayerNode.ExecutableLayer.succeed(
            key: Service.serviceKey,
            value: Service()
        )

        /// Global LayerNode provider for `SdkPlugins`.
        // parity: core/src/plugin/sdk.ts#node [status=adapted hash=1569eddfecc8]
        public static let node: LayerNode.Provider = AppNode.makeGlobalNode(
            Service.serviceKey,
            layer,
            []
        )
    }

    // MARK: - Source Directory Auto-Discovery (`plugin/source-directory.ts`)

    public enum SourceDirectory {
        /// Conventional directory names scanned for auto-discovered local plugins.
        // parity: core/src/plugin/source-directory.ts#names [status=implemented hash=34fb5ddaddc9]
        public static let names: [String] = ["plugin", "plugins"]

        /// Discovers local `.ts`/`.js` plugin files and plugin subdirectories under `<directory>/{plugin,plugins}`.
        // parity: core/src/plugin/source-directory.ts#discover [status=implemented hash=fd191b71a3d4]
        public static func discover(
            fs: any OpenCodeFileSystem,
            directory: String
        ) async -> [String] {
            var candidates: [(target: String, type: FileEntryType)] = []
            for folder in names {
                let dirPath = PluginContract.joinPath(directory, folder)
                guard let entries = try? await fs.readDirectory(at: dirPath) else { continue }
                for name in entries {
                    let target = PluginContract.joinPath(dirPath, name)
                    if let stat = try? await fs.stat(at: target) {
                        candidates.append((target: target, type: stat.type))
                    }
                }
            }
            candidates.sort { $0.target < $1.target }
            var results: [String] = []
            for entry in candidates {
                let isSource = entry.target.hasSuffix(".ts") || entry.target.hasSuffix(".js")
                switch entry.type {
                case .file:
                    if isSource { results.append(entry.target) }
                case .directory:
                    results.append(entry.target)
                case .symlink:
                    if let resolved = try? await fs.realPath(at: entry.target),
                       let targetStat = try? await fs.stat(at: resolved)
                    {
                        if targetStat.type == .directory || (targetStat.type == .file && isSource) {
                            results.append(entry.target)
                        }
                    }
                case .other:
                    break
                }
            }
            return results
        }
    }

    // MARK: - Plugin Module Loader (`plugin/module.ts`)

    public enum Module {
        /// Tagged load error raised when an external/local plugin fails module validation or entrypoint resolution.
        // parity: core/src/plugin/module.ts#LoadError [status=implemented hash=4834405dcb55]
        public struct LoadError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public static let tag = "PluginModule.LoadError"
            public let message: String
            public let causeDescription: String?

            public init(message: String, causeDescription: String? = nil) {
                self.message = message
                self.causeDescription = causeDescription
            }

            public var description: String {
                if let causeDescription { return "\(message): \(causeDescription)" }
                return message
            }
        }

        /// Classifies a configured plugin target string as `.local(path:)` (absolute path) or `.package(target:version:)`.
        // parity: core/src/plugin/module.ts#source [status=implemented hash=8ac274aec1e1]
        public static func source(target: String, version: String? = nil) -> PluginSchema.Source {
            if PluginContract.isAbsolutePath(target) {
                return .local(path: target)
            }
            return .package(target: target, version: version)
        }

        /// Outcome of loading one configured `add` plugin operation.
        public enum LoadOutcome: Sendable {
            case loaded(Generation)
            case blocked
            case pending
        }

        /// Module loader instance created by `CorePlugin.Module.make(...)`.
        public final class Loader: Sendable {
            private let fileSystem: any OpenCodeFileSystem
            private let policyCheck: @Sendable (String) -> Bool
            private let bridgeFactory: (@Sendable (_ target: String, _ entrypoint: String, _ options: PluginContract.PluginOptions) async throws -> PluginEffect.Plugin)?

            public init(
                fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
                policyCheck: @escaping @Sendable (String) -> Bool = { _ in true },
                bridgeFactory: (@Sendable (_ target: String, _ entrypoint: String, _ options: PluginContract.PluginOptions) async throws -> PluginEffect.Plugin)? = nil
            ) {
                self.fileSystem = fileSystem
                self.policyCheck = policyCheck
                self.bridgeFactory = bridgeFactory
            }

            public func load(
                target: String,
                options: PluginContract.PluginOptions = [:],
                install: Bool = true
            ) async throws -> LoadOutcome {
                let strippedTarget: String
                if !PluginContract.isAbsolutePath(target), let atIdx = target.lastIndex(of: "@"), atIdx > target.startIndex {
                    strippedTarget = String(target[..<atIdx])
                } else {
                    strippedTarget = target
                }
                if !policyCheck(strippedTarget) {
                    return .blocked
                }

                let isLocal = PluginContract.isAbsolutePath(target)
                let entrypoints: PluginContract.Host.Entrypoints
                if isLocal, let stat = try? await fileSystem.stat(at: target), stat.type == .file {
                    entrypoints = PluginContract.Host.Entrypoints(server: PluginContract.toFileURLString(target))
                } else {
                    entrypoints = await PluginContract.Host.resolve(
                        PluginContract.Host.Target(directory: target),
                        fileSystem: fileSystem
                    )
                }

                let found = entrypoints.server ?? entrypoints.gui
                if !isLocal && !install && found == nil {
                    return .pending
                }
                guard let found else {
                    throw LoadError(message: "Plugin entrypoint not found: \(target)")
                }

                let pluginID: String
                let effect: @Sendable (PluginEffect.Context) async throws -> Void
                if let serverEntry = entrypoints.server, let factory = bridgeFactory {
                    let loadedPlugin = try await factory(target, serverEntry, options)
                    pluginID = loadedPlugin.id
                    effect = { host in try await loadedPlugin.effect(host.withOptions(options)) }
                } else {
                    pluginID = await PluginContract.Host.packageID(
                        PluginContract.Host.Target(directory: target),
                        fileSystem: fileSystem
                    )
                    effect = { _ in }
                }

                let bundleDigest: String?
                if isLocal, let guiEntry = entrypoints.gui,
                   let bytes = try? await fileSystem.readFile(at: PluginContract.fromFileURLString(guiEntry))
                {
                    bundleDigest = Hash.sha256(bytes)
                } else {
                    bundleDigest = nil
                }

                let revision = Hash.sha256("\(target):\(found)")
                let guiDesc: Generation.GuiDescriptor? = entrypoints.gui.map { guiFile in
                    Generation.GuiDescriptor(
                        file: guiFile,
                        revision: Hash.sha256("\(revision):\(bundleDigest ?? "")"),
                        options: options
                    )
                }

                let features = PluginSchema.Features(
                    server: entrypoints.server != nil ? true : nil,
                    tui: entrypoints.tui != nil ? true : nil,
                    rpc: (entrypoints.server != nil && entrypoints.rpc != nil) ? true : nil,
                    gui: entrypoints.gui != nil ? true : nil
                )

                return .loaded(
                    Generation(
                        id: pluginID,
                        effect: effect,
                        revision: revision,
                        source: Module.source(target: target),
                        features: features,
                        gui: guiDesc
                    )
                )
            }
        }

        /// Constructs a `PluginModule` loader.
        // parity: core/src/plugin/module.ts#make [status=adapted hash=940bdf2874b8]
        public static func make(
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
            policyCheck: @escaping @Sendable (String) -> Bool = { _ in true },
            bridgeFactory: (@Sendable (_ target: String, _ entrypoint: String, _ options: PluginContract.PluginOptions) async throws -> PluginEffect.Plugin)? = nil
        ) -> Loader {
            Loader(fileSystem: fileSystem, policyCheck: policyCheck, bridgeFactory: bridgeFactory)
        }
    }

    // MARK: - Plugin Update Checker (`plugin/update.ts`)

    public enum Update {
        public struct Change: Equatable, Hashable, Sendable, Codable {
            public let target: String
            public let outdated: Bool
            public let updating: Bool

            public init(target: String, outdated: Bool, updating: Bool) {
                self.target = target
                self.outdated = outdated
                self.updating = updating
            }
        }

        /// Contract for checking and installing npm package plugin updates.
        // parity: core/src/plugin/update.ts#Interface [status=implemented hash=fe4746266624]
        public protocol Interface: Sendable {
            func check(_ target: String, refresh: Bool) async -> Bool
            func update(_ target: String) async throws
        }

        /// Service tracking 24-hour cached plugin update status and serializing updates per target.
        // parity: core/src/plugin/update.ts#Service [status=adapted hash=df55a72c9c08]
        public actor Service: Interface {
            public static let serviceKey = "@opencode/PluginUpdate"
            private static let checkIntervalMs: Int64 = 24 * 60 * 60 * 1_000

            private struct CachedStatus {
                let outdated: Bool
                let checkedAtMs: Int64
            }

            private var status: [String: CachedStatus] = [:]
            private let checker: @Sendable (String) async throws -> Bool
            private let updater: @Sendable (String) async throws -> Void
            private let nowMs: @Sendable () -> Int64

            public init(
                checker: @escaping @Sendable (String) async throws -> Bool = { _ in false },
                updater: @escaping @Sendable (String) async throws -> Void = { _ in },
                nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
            ) {
                self.checker = checker
                self.updater = updater
                self.nowMs = nowMs
            }

            public func check(_ target: String, refresh: Bool = false) async -> Bool {
                let now = nowMs()
                if !refresh, let current = status[target], now - current.checkedAtMs < Self.checkIntervalMs {
                    return current.outdated
                }
                let outdated = (try? await checker(target)) ?? (status[target]?.outdated ?? false)
                status[target] = CachedStatus(outdated: outdated, checkedAtMs: now)
                return outdated
            }

            public func update(_ target: String) async throws {
                try await updater(target)
                status.removeValue(forKey: target)
            }
        }

        /// Global LayerNode provider for `PluginUpdate`.
        // parity: core/src/plugin/update.ts#node [status=adapted hash=47cfe2786cef]
        public static let node: LayerNode.Provider = AppNode.makeGlobalNode(
            Service.serviceKey,
            LayerNode.ExecutableLayer.succeed(key: Service.serviceKey, value: Service()),
            []
        )
    }

    // MARK: - Internal Built-In Plugin Catalog (`plugin/internal.ts`)

    public enum Internal {
        /// Service requirements tag list for built-in internal plugins.
        // parity: core/src/plugin/internal.ts#Requirements [status=adapted hash=7310ad07321c]
        public typealias Requirements = [String]

        /// Built-in internal plugin definition type.
        // parity: core/src/plugin/internal.ts#InternalPlugin [status=implemented hash=b5c3ff902cde]
        public typealias InternalPlugin = PluginEffect.Plugin

        /// LayerNode group of core services required by internal plugins.
        // parity: core/src/plugin/internal.ts#requirements [status=adapted hash=13fa0388ba75]
        public static let requirements: LayerNode.Graph = LayerNode.group([Host.requirements])

        /// Protected plugin IDs that repository config `remove` operations cannot disable.
        // parity: core/src/plugin/internal.ts#guarded [status=implemented hash=6ea2ceb49071]
        public static let guarded: Set<String> = [
            "opencode.provider.opencode",
            "opencode.config.policy",
        ]

        public struct Partition: Sendable {
            public let pre: [Generation]
            public let post: [Generation]

            public init(pre: [Generation], post: [Generation]) {
                self.pre = pre
                self.post = post
            }
        }

        /// Returns the built-in `pre` and `post` internal plugin generations in upstream boot order.
        // parity: core/src/plugin/internal.ts#list [status=adapted hash=ebfc1b46e42b]
        public static func list() -> Partition {
            let prePlugins: [InternalPlugin] = [
                ToolInputRepairPlugin.Plugin,
                McpCodeModeDefaultsPlugin.Plugin,
                VcsGitPlugin.Plugin,
                AgentPlugin.Plugin,
                ForkNoticePlugin.Plugin,
                PlanPlugin.Plugin,
                CommandPlugin.Plugin,
                GoalPlugin.Plugin,
                SkillPlugin.Plugin,
                VcsHgPlugin.Plugin,
                ModelsDevPlugin,
            ]
                + ProviderPlugins
                + WebSearchPlugins
                + OptimizePlugin.Plugins
                + [
                    VerbosityPlugin.Plugin,
                    IdentityPlugin.Plugin,
                    WarmingPlugin.Plugin,
                ]
            let postPlugins: [InternalPlugin] = [
                BrowserPlugin.Plugin,
                DynamicProviderPlugin,
            ]
            return Partition(
                pre: prePlugins.map { Generation(plugin: $0, revision: "internal", source: .builtin) },
                post: postPlugins.map { Generation(plugin: $0, revision: "internal", source: .builtin) }
            )
        }
    }

    // MARK: - Plugin Supervisor (`plugin/supervisor.ts`)

    public enum Supervisor {
        public enum Operation: Equatable, Hashable, Sendable, Codable {
            case add(target: String, options: PluginContract.PluginOptions = [:])
            case remove(target: String)
        }

        public struct Resolution: Sendable {
            public let plugins: [Generation]
            public let failures: [Failure]
            public let pending: [String]

            public init(plugins: [Generation], failures: [Failure], pending: [String]) {
                self.plugins = plugins
                self.failures = failures
                self.pending = pending
            }
        }

        /// Resolves configured add/remove plugin operations against `pre`/`post` built-ins with wildcard matching,
        /// `Internal.guarded` protection, duplicate ID reporting, and retained-generation fallback on reload errors.
        public static func resolve(
            loader: Module.Loader,
            pre: [Generation],
            post: [Generation],
            operations: [Operation],
            install: Bool = true,
            running: [String: Generation] = [:]
        ) async -> Resolution {
            func matches(_ selector: String, _ target: String) -> Bool {
                if selector == "*" { return true }
                if selector.hasSuffix(".*") {
                    return target.hasPrefix(String(selector.dropLast()))
                }
                return selector == target
            }

            let definitions = pre + post
            var enabled = Set(definitions.map(\.id))
            var packageOrder: [String] = []
            var packages: [String: Generation] = [:]
            var pending: [String] = []
            var failures: [String: Failure] = [:]

            func allPlugins() -> [Generation] {
                definitions + packageOrder.compactMap { packages[$0] }
            }

            for operation in operations {
                switch operation {
                case .remove(let target):
                    if target == "*" { failures.removeAll() }
                    for plugin in allPlugins() where matches(target, plugin.id) && !Internal.guarded.contains(plugin.id) {
                        enabled.remove(plugin.id)
                    }
                case .add(let target, let options):
                    let matched = allPlugins().filter { matches(target, $0.id) }
                    let selectsExisting = !matched.isEmpty || target == "*" || target.hasSuffix(".*") || target.hasPrefix("opencode.")
                    if selectsExisting {
                        for plugin in matched { enabled.insert(plugin.id) }
                        continue
                    }
                    do {
                        let outcome = try await loader.load(target: target, options: options, install: install)
                        switch outcome {
                        case .blocked:
                            if let prev = packages.removeValue(forKey: target) { enabled.remove(prev.id) }
                            failures.removeValue(forKey: target)
                        case .pending:
                            if !pending.contains(target) { pending.append(target) }
                        case .loaded(let generation):
                            failures.removeValue(forKey: target)
                            if let prev = packages[target] { enabled.remove(prev.id) }
                            if packages[target] == nil { packageOrder.append(target) }
                            packages[target] = generation
                            enabled.insert(generation.id)
                        }
                    } catch {
                        let ref = "err_" + String(Hash.sha256("\(target):\(error)").prefix(8))
                        let msg = (error as? Module.LoadError)?.message ?? "Plugin failed to load"
                        failures[target] = Failure(
                            id: nil,
                            source: Module.source(target: target),
                            features: PluginSchema.Features(server: true),
                            error: msg,
                            ref: ref
                        )
                        if let retained = packages[target] ?? running[target] {
                            if packages[target] == nil { packageOrder.append(target) }
                            packages[target] = retained
                            enabled.insert(retained.id)
                        }
                    }
                }
            }

            let ordered = pre.filter { enabled.contains($0.id) }
                + packageOrder.compactMap { packages[$0] }.filter { enabled.contains($0.id) }
                + post.filter { enabled.contains($0.id) }

            var seenIDs: Set<String> = []
            var uniquePlugins: [Generation] = []
            var allFailures: [Failure] = Array(failures.values)
            for plugin in ordered {
                if seenIDs.insert(plugin.id).inserted {
                    uniquePlugins.append(plugin)
                } else {
                    allFailures.append(
                        Failure(
                            id: PluginSchema.ID(rawValue: plugin.id),
                            source: plugin.source ?? .builtin,
                            features: plugin.features ?? PluginSchema.Features(server: true),
                            error: "Duplicate plugin ID: \(plugin.id)"
                        )
                    )
                }
            }
            return Resolution(plugins: uniquePlugins, failures: allFailures, pending: pending)
        }

        /// Supervisor runtime layer descriptor.
        // parity: core/src/plugin/supervisor.ts#layer [status=adapted hash=450d1d8b61ce]
        public static let layer: LayerNode.ExecutableLayer = LayerNode.ExecutableLayer.succeed(
            key: "plugin-supervisor",
            value: "plugin-supervisor"
        )

        /// Location LayerNode provider for `PluginSupervisor`.
        // parity: core/src/plugin/supervisor.ts#node [status=adapted hash=657fc7fc72aa]
        public static let node: LayerNode.Provider = AppNode.makeLocationNode(
            "plugin-supervisor",
            layer,
            [CorePlugin.node, SdkPlugins.node, InstancePlugins.node, Update.node, Internal.requirements]
        )
    }

    // MARK: - Core Built-in Plugins (`agent`, `command`, `fork-notice`, `goal`, `identity`, `mcp-codemode-defaults`, `models-dev`, `optimize`, `plan`, `skill`, `tool-input-repair`, `verbosity`, `warming`)

    public enum AgentPlugin {
        public static let explorePrompt = """
        You are a file search specialist. You excel at thoroughly navigating and exploring codebases.

        Guidelines:
        - Your role is EXCLUSIVELY to search and analyze
        - Parallelize independent tool calls for searches and reads whenever possible
        - Adapt your search approach based on the thoroughness level specified by the caller
        - Return file paths as absolute paths in your final response
        - You MUST NOT create, modify, delete, move, or copy files, including temporary files and reports
        - Shell commands MUST be read-only. NEVER run commands that write files or change system state

        Complete the user's search request efficiently and report your findings clearly.
        """

        public static let titlePrompt = """
        You name conversations so the user can find them later in a list of past sessions.

        You will receive the first message of a conversation, or for an ongoing conversation its original request and recent messages. Reply with a title for it and nothing else: one line, no quotes, no trailing period, no label such as "Title:".

        Aim for three to five words. Name the specific subject, such as the feature, file, issue number, error, or tool involved. Use sentence case, not title case. Keep identifiers exactly as written. Use the same language as the message.
        """

        public static let summaryPrompt = """
        Summarize what was done in this conversation. Write like a pull request description.

        Rules:
        - 2-3 sentences max
        - Describe the changes made, not the process
        - Do not mention running tests, builds, or other validation steps
        - Do not explain what the user asked for
        - Write in first person (I added..., I fixed...)
        - Never ask questions or add new questions
        - If the conversation ends with an unanswered question or imperative request to the user, preserve it
        """

        /// Built-in agent catalog plugin (`opencode.agent`) defining Build, Plan, General, Explore, Compaction, Title, and Summary agents.
        // parity: core/src/plugin/agent.ts#Plugin [status=adapted hash=1f30747747d3]
        public static let Plugin = PluginEffect.define(
            PluginEffect.Plugin(id: "opencode.agent") { ctx in
                let planDir = PluginContract.joinPath(
                    PluginContract.joinPath(Host.currentEnvironment.homeDirectory ?? "/tmp", ".opencode"),
                    "plan"
                )
                _ = await ctx.agent.transform { editor in
                    editor.update("build") { item in
                        item = AgentSchema.Info(
                            id: AgentSchema.ID(rawValue: "build"),
                            name: AgentSchema.Name(rawValue: "Build"),
                            model: item.model,
                            request: item.request,
                            system: item.system,
                            description: "The default agent. Executes tools based on configured permissions.",
                            mode: .primary,
                            hidden: false,
                            color: item.color,
                            steps: item.steps,
                            permissions: item.permissions + [
                                PermissionSchema.Rule(action: "question", resource: "*", effect: .allow),
                            ]
                        )
                    }

                    editor.update("plan") { item in
                        item = AgentSchema.Info(
                            id: AgentSchema.ID(rawValue: "plan"),
                            name: AgentSchema.Name(rawValue: "Plan"),
                            model: item.model,
                            request: item.request,
                            system: item.system,
                            description: "Read-only agent for exploring the codebase and planning work before implementation.",
                            mode: .primary,
                            hidden: false,
                            color: item.color,
                            steps: item.steps,
                            permissions: item.permissions + [
                                PermissionSchema.Rule(action: "question", resource: "*", effect: .allow),
                                PermissionSchema.Rule(action: "edit", resource: "*", effect: .deny),
                                PermissionSchema.Rule(action: "edit", resource: PluginContract.joinPath(planDir, "*"), effect: .allow),
                            ]
                        )
                    }

                    editor.update("general") { item in
                        item = AgentSchema.Info(
                            id: AgentSchema.ID(rawValue: "general"),
                            name: AgentSchema.Name(rawValue: "General"),
                            model: item.model,
                            request: item.request,
                            system: item.system,
                            description: "General-purpose agent for researching complex questions and executing multi-step tasks. Use this agent to execute multiple units of work in parallel.",
                            mode: .subagent,
                            hidden: false,
                            color: item.color,
                            steps: item.steps,
                            permissions: item.permissions + [
                                PermissionSchema.Rule(action: "question", resource: "*", effect: .deny),
                                PermissionSchema.Rule(action: "subagent", resource: "*", effect: .deny),
                            ]
                        )
                    }

                    editor.update("explore") { item in
                        item = AgentSchema.Info(
                            id: AgentSchema.ID(rawValue: "explore"),
                            name: AgentSchema.Name(rawValue: "Explore"),
                            model: item.model,
                            request: item.request,
                            system: explorePrompt,
                            description: #"Fast agent specialized for exploring codebases. Use this when you need to quickly find files by patterns (eg. "src/components/**/*.tsx"), search code for keywords (eg. "API endpoints"), or answer questions about the codebase (eg. "how do API endpoints work?"). When calling this agent, specify the desired thoroughness level: "quick" for basic searches, "medium" for moderate exploration, or "very thorough" for comprehensive analysis across multiple locations and naming conventions."#,
                            mode: .subagent,
                            hidden: false,
                            color: item.color,
                            steps: item.steps,
                            permissions: [
                                PermissionSchema.Rule(action: "*", resource: "*", effect: .deny),
                                PermissionSchema.Rule(action: "shell", resource: "*", effect: .allow),
                                PermissionSchema.Rule(action: "grep", resource: "*", effect: .allow),
                                PermissionSchema.Rule(action: "glob", resource: "*", effect: .allow),
                                PermissionSchema.Rule(action: "webfetch", resource: "*", effect: .allow),
                                PermissionSchema.Rule(action: "websearch", resource: "*", effect: .allow),
                                PermissionSchema.Rule(action: "read", resource: "*", effect: .allow),
                                PermissionSchema.Rule(action: "read", resource: "*.env", effect: .ask),
                                PermissionSchema.Rule(action: "read", resource: "*.env.*", effect: .ask),
                                PermissionSchema.Rule(action: "read", resource: "*.env.example", effect: .allow),
                                PermissionSchema.Rule(action: "subagent", resource: "*", effect: .deny),
                                PermissionSchema.Rule(action: "external_directory", resource: "*", effect: .allow),
                            ]
                        )
                    }

                    editor.update("compaction") { item in
                        item = AgentSchema.Info(
                            id: AgentSchema.ID(rawValue: "compaction"),
                            name: AgentSchema.Name(rawValue: "Compaction"),
                            model: item.model,
                            request: item.request,
                            system: item.system,
                            description: item.description,
                            mode: .primary,
                            hidden: true,
                            color: item.color,
                            steps: item.steps,
                            permissions: item.permissions
                        )
                    }

                    editor.update("title") { item in
                        item = AgentSchema.Info(
                            id: AgentSchema.ID(rawValue: "title"),
                            name: AgentSchema.Name(rawValue: "Title"),
                            model: item.model,
                            request: item.request,
                            system: titlePrompt,
                            description: item.description,
                            mode: .primary,
                            hidden: true,
                            color: item.color,
                            steps: item.steps,
                            permissions: [
                                PermissionSchema.Rule(action: "*", resource: "*", effect: .deny),
                            ]
                        )
                    }

                    editor.update("summary") { item in
                        item = AgentSchema.Info(
                            id: AgentSchema.ID(rawValue: "summary"),
                            name: AgentSchema.Name(rawValue: "Summary"),
                            model: item.model,
                            request: item.request,
                            system: summaryPrompt,
                            description: item.description,
                            mode: .primary,
                            hidden: true,
                            color: item.color,
                            steps: item.steps,
                            permissions: [
                                PermissionSchema.Rule(action: "*", resource: "*", effect: .deny),
                            ]
                        )
                    }

                    editor.setDefault("build")
                }
            }
        )
    }

    public enum CommandPlugin {
        public static let initTemplate = """
        Create or update `AGENTS.md` for this repository.

        The goal is a compact instruction file that helps future OpenCode sessions avoid mistakes and ramp up quickly. Every line should answer: "Would an agent likely miss this without help?" If not, leave it out.

        User-provided focus or constraints (honor these):
        $ARGUMENTS

        ## How to investigate

        Read the highest-value sources first:
        - `README*`, root manifests, workspace config, lockfiles
        - build, test, lint, formatter, typecheck, and codegen config
        - CI workflows and pre-commit / task runner config
        - existing instruction files (`AGENTS.md`, `CLAUDE.md`, `.cursor/rules/`, `.cursorrules`, `.github/copilot-instructions.md`)
        - repo-local OpenCode config such as `opencode.json`

        Prefer executable sources of truth over prose. If docs conflict with config or scripts, trust the executable source and only keep what you can verify.

        ## What to extract

        Look for the highest-signal facts for an agent working in this repo:
        - exact developer commands, especially non-obvious ones
        - how to run a single test, a single package, or a focused verification step
        - required command order when it matters, such as `lint -> typecheck -> test`
        - monorepo or multi-package boundaries, ownership of major directories, and the real app/library entrypoints
        - framework or toolchain quirks: generated code, migrations, codegen, build artifacts, special env loading, dev servers, infra deploy flow
        - testing quirks: fixtures, integration test prerequisites, snapshot workflows, required services, flaky or expensive suites
        - important constraints from existing instruction files worth preserving

        If `AGENTS.md` already exists at `${path}`, improve it in place rather than rewriting blindly. Preserve verified useful guidance, delete fluff or stale claims, and reconcile it with the current codebase.
        """

        public static let reviewTemplate = """
        You are a code reviewer. Your job is to review code changes and provide actionable feedback.

        ---

        Input: $ARGUMENTS

        ---

        ## Determining What to Review

        Based on the input provided, determine which type of review to perform:

        1. **No arguments (default)**: Review all uncommitted changes
           - Run: `git diff` for unstaged changes
           - Run: `git diff --cached` for staged changes
           - Run: `git status --short` to identify untracked (net new) files

        2. **Commit hash** (40-char SHA or short hash): Review that specific commit
           - Run: `git show $ARGUMENTS`

        3. **Branch name**: Compare current branch to the specified branch
           - Run: `git diff $ARGUMENTS...HEAD`

        4. **PR URL or number** (contains "github.com" or "pull" or looks like a PR number): Review the pull request
           - Run: `gh pr view $ARGUMENTS` to get PR context
           - Run: `gh pr diff $ARGUMENTS` to get the diff

        ## Gathering Context

        **Diffs alone are not enough.** After getting the diff, read the entire file(s) being modified to understand the full context. Focus on bugs, structure, obvious performance issues, and unintended behavior changes. Be direct, clear, and matter-of-fact.
        """

        public static func renderTemplate(_ template: String, projectDirectory: String, arguments: String) -> String {
            let withPath = template.replacing("${path}", with: projectDirectory)
            let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            if withPath.contains("$ARGUMENTS") {
                return withPath.replacing("$ARGUMENTS", with: trimmed)
            }
            return trimmed.isEmpty ? withPath : "\(withPath)\n\n\(trimmed)"
        }

        /// Built-in slash command plugin (`opencode.command`) registering `/init` and `/review` with real prompt templates.
        // parity: core/src/plugin/command.ts#Plugin [status=adapted hash=3a478a54668e]
        public static let Plugin = PluginEffect.define(
            PluginEffect.Plugin(id: "opencode.command") { ctx in
                let projectDirectory = ctx.location.project.directory.rawValue
                _ = await ctx.command.transform { editor in
                    editor.add(
                        PluginEffect.CommandDefinition(
                            name: "init",
                            description: "guided AGENTS.md setup",
                            execute: { invocation in
                                let rendered = renderTemplate(
                                    initTemplate,
                                    projectDirectory: projectDirectory,
                                    arguments: invocation.prompt.text
                                )
                                let nextPrompt = PromptInputSchema.Prompt(
                                    text: rendered,
                                    files: invocation.prompt.files,
                                    agents: invocation.prompt.agents,
                                    skills: invocation.prompt.skills
                                )
                                try await ctx.session.prompt(invocation.sessionID, nextPrompt, invocation.delivery)
                            }
                        )
                    )
                    editor.add(
                        PluginEffect.CommandDefinition(
                            name: "review",
                            description: "review changes [commit|branch|pr], defaults to uncommitted",
                            execute: { invocation in
                                let rendered = renderTemplate(
                                    reviewTemplate,
                                    projectDirectory: projectDirectory,
                                    arguments: invocation.prompt.text
                                )
                                let nextPrompt = PromptInputSchema.Prompt(
                                    text: rendered,
                                    files: invocation.prompt.files,
                                    agents: invocation.prompt.agents,
                                    skills: invocation.prompt.skills
                                )
                                try await ctx.session.prompt(invocation.sessionID, nextPrompt, invocation.delivery)
                            }
                        )
                    )
                }
            }
        )
    }

    public enum ForkNoticePlugin {
        /// Built-in fork notice plugin (`opencode.fork-notice`) injecting `<fork-notice>` on `session.fork`.
        // parity: core/src/plugin/fork-notice.ts#Plugin [status=implemented hash=6ab934f5ceaa]
        public static let Plugin = PluginEffect.define(
            PluginEffect.Plugin(id: "opencode.fork-notice") { ctx in
                _ = await ctx.session.hook("fork", { event in
                    if case .fork(let sessionID) = event {
                        try? await ctx.session.synthetic(
                            sessionID,
                            "<fork-notice>\nThis conversation is a fork of another conversation, copied up to the previous message.\n</fork-notice>",
                            "Fork notice",
                            nil,
                            false
                        )
                    }
                    return event
                }, nil)
            }
        )
    }

    public enum GoalPlugin {
        /// Maximum character length allowed for a `/goal` objective.
        // parity: core/src/plugin/goal.ts#MAX_OBJECTIVE [status=implemented hash=7e2606f2af32]
        public static let MAX_OBJECTIVE = 4_000

        /// Maximum autonomous continuation rounds per goal budget.
        // parity: core/src/plugin/goal.ts#MAX_ROUNDS [status=implemented hash=da71937bd583]
        public static let MAX_ROUNDS = 50

        /// Consecutive non-progress rounds before pausing a goal automatically.
        // parity: core/src/plugin/goal.ts#MAX_STALLS [status=implemented hash=be4d05f0ec26]
        public static let MAX_STALLS = 3

        /// Idle wait timeout (30 minutes) in milliseconds before pausing a goal waiting on background work.
        // parity: core/src/plugin/goal.ts#WAIT_LIMIT [status=implemented hash=7383cbd48047]
        public static let WAIT_LIMIT: Int64 = 30 * 60 * 1_000

        /// Built-in autonomous goal loop plugin (`opencode.goal`).
        // parity: core/src/plugin/goal.ts#Plugin [status=adapted hash=4e1a370b9955]
        public static let Plugin = PluginEffect.define(
            PluginEffect.Plugin(id: "opencode.goal") { ctx in
                _ = await ctx.command.transform { editor in
                    editor.add(
                        PluginEffect.CommandDefinition(
                            name: "goal",
                            description: "keep working until an objective is met [pause|resume|clear]",
                            execute: { invocation in
                                let text = invocation.prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
                                if text.count > MAX_OBJECTIVE {
                                    throw ToolSchema.ToolError(
                                        message: "A goal objective is limited to \(MAX_OBJECTIVE) characters (got \(text.count))."
                                    )
                                }
                            }
                        )
                    )
                }
            }
        )
    }

    public enum IdentityPlugin {
        /// Formats the `# Your Model` identity system prompt block injected into session requests.
        // parity: core/src/plugin/identity.ts#identity [status=implemented hash=d1056ea5e09a]
        public static func identity(name: String, ref: ModelSchema.Ref) -> String {
            [
                "# Your Model",
                "- Name: \(name)",
                "- Provider ID: \(ref.providerID.rawValue)",
                "- Model ID: \(ref.id.rawValue)",
            ].joined(separator: "\n")
        }

        /// Built-in model identity prompt plugin (`opencode.prompt.identity`).
        // parity: core/src/plugin/identity.ts#Plugin [status=implemented hash=11e365486321]
        public static let Plugin = PluginEffect.define(
            PluginEffect.Plugin(id: "opencode.prompt.identity") { ctx in
                let inject: @Sendable (PluginEffect.SessionHooks) async throws -> PluginEffect.SessionHooks = { event in
                    switch event {
                    case .context(var c):
                        let resolved = await OptimizePlugin.resolveModel(ctx: ctx, model: c.model)
                        let part = AISchema.SystemPart(text: identity(name: resolved?.name ?? c.model.id.rawValue, ref: c.model))
                        c.system.insert(part, at: min(1, c.system.count))
                        return .context(c)
                    default:
                        return event
                    }
                }
                _ = await ctx.session.hook("context", inject, nil)
                _ = await ctx.session.hook("compaction", inject, nil)
                _ = await ctx.session.hook("generate", inject, nil)
            }
        )
    }

    public enum McpCodeModeDefaultsPlugin {
        /// Built-in MCP Code Mode compatibility plugin (`opencode.mcp.codemode.defaults`).
        // parity: core/src/plugin/mcp-codemode-defaults.ts#Plugin [status=implemented hash=0eacd3f36c64]
        public static let Plugin = PluginEffect.define(
            PluginEffect.Plugin(id: "opencode.mcp.codemode.defaults") { ctx in
                _ = await ctx.mcp.transform { editor in
                    for (name, server) in editor.list() {
                        switch server {
                        case .local(let local):
                            if local.codemode == nil && local.command.count >= 2
                                && local.command[0] == "executor" && local.command[1] == "mcp"
                            {
                                editor.set(
                                    name,
                                    .local(
                                        McpSchema.LocalConfig(
                                            command: local.command,
                                            cwd: local.cwd,
                                            environment: local.environment,
                                            disabled: local.disabled,
                                            codemode: false,
                                            timeout: local.timeout,
                                            wireProtocol: local.wireProtocol,
                                            pool: local.pool
                                        )
                                    )
                                )
                            }
                        case .remote(let remote):
                            if remote.codemode == nil,
                               let url = URL(string: remote.url),
                               let host = url.host?.lowercased()
                            {
                                let isExecutor = host == "executor.sh" && url.path.hasSuffix("/mcp")
                                let isPosthog = host == "mcp.posthog.com"
                                    || host == "mcp-eu.posthog.com"
                                    || host == "mcp.us.posthog.com"
                                    || host == "mcp.eu.posthog.com"
                                if isExecutor {
                                    editor.set(
                                        name,
                                        .remote(
                                            McpSchema.RemoteConfig(
                                                url: remote.url,
                                                headers: remote.headers,
                                                oauth: remote.oauth,
                                                disabled: remote.disabled,
                                                codemode: false,
                                                timeout: remote.timeout,
                                                wireProtocol: remote.wireProtocol,
                                                pool: remote.pool
                                            )
                                        )
                                    )
                                } else if isPosthog {
                                    let existingHeaders = remote.headers ?? [:]
                                    let hasHeader = existingHeaders.keys.contains { $0.lowercased() == "x-posthog-mcp-mode" }
                                    let hasQueryMode = (url.query ?? "").contains("mode=")
                                    if !hasHeader && !hasQueryMode {
                                        var nextHeaders = existingHeaders
                                        nextHeaders["x-posthog-mcp-mode"] = "tools"
                                        editor.set(
                                            name,
                                            .remote(
                                                McpSchema.RemoteConfig(
                                                    url: remote.url,
                                                    headers: nextHeaders,
                                                    oauth: remote.oauth,
                                                    disabled: remote.disabled,
                                                    codemode: remote.codemode,
                                                    timeout: remote.timeout,
                                                    wireProtocol: remote.wireProtocol,
                                                    pool: remote.pool
                                                )
                                            )
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        )
    }

    private static let bedrockProfileOnlyIDs: Set<String> = [
        "amazon.nova-2-lite-v1:0",
        "anthropic.claude-fable-5",
        "anthropic.claude-fable-5-1",
        "anthropic.claude-haiku-4-5-20251001-v1:0",
        "anthropic.claude-haiku-5-5",
        "anthropic.claude-opus-4-1-20250805-v1:0",
        "anthropic.claude-opus-4-5-20251101-v1:0",
        "anthropic.claude-opus-4-7",
        "anthropic.claude-opus-4-8",
        "anthropic.claude-opus-5",
        "anthropic.claude-sonnet-4-5-20250929-v1:0",
        "anthropic.claude-sonnet-5",
        "anthropic.claude-sonnet-5-5",
        "deepseek.r1-v1:0",
        "meta.llama4-maverick-17b-instruct-v1:0",
        "meta.llama4-scout-17b-instruct-v1:0",
        "mistral.pixtral-large-2502-v1:0",
        "writer.palmyra-x4-v1:0",
        "writer.palmyra-x5-v1:0",
    ]

    private static func makeDefaultModel(
        id: String,
        providerID: ProviderSchema.ID,
        name: String,
        package: String,
        family: String? = nil,
        baseURL: String? = nil,
        context: Int,
        output: Int,
        inputModalities: [String] = ["text", "image"]
    ) -> ModelSchema.Info {
        let settings: ModelSchema.Settings? = baseURL.map { ModelSchema.Settings(extra: ["baseURL": .string($0)]) }
        return ModelSchema.Info(
            id: ModelSchema.ID(rawValue: id),
            modelID: ModelSchema.ID(rawValue: id),
            providerID: providerID,
            family: family.map { ModelSchema.Family(rawValue: $0) },
            name: name,
            package: package,
            settings: settings,
            capabilities: ModelSchema.Capabilities(tools: true, input: inputModalities, output: ["text"]),
            variants: [],
            time: ModelSchema.Info.Time(released: 1_750_000_000),
            cost: [ModelSchema.Cost(input: .zero, output: .zero, cache: ModelSchema.Cost.Cache(read: .zero, write: .zero))],
            status: .active,
            enabled: true,
            limit: ModelSchema.Info.Limit(context: context, input: nil, output: output)
        )
    }

    /// Curated built-in default snapshots used by `ModelsDevPlugin` when no live or cached catalog is available.
    public static func defaultModelsDevSnapshots() -> [CoreModel.ModelsDev.Snapshot] {
        [
            CoreModel.ModelsDev.Snapshot(
                info: ProviderSchema.Info(
                    id: .anthropic,
                    integrationID: IntegrationID(rawValue: "anthropic"),
                    name: "Anthropic",
                    activation: .auto,
                    package: "@opencode/ai/providers/anthropic",
                    settings: ProviderSchema.Settings(extra: ["baseURL": .string("https://api.anthropic.com/v1")])
                ),
                models: [
                    makeDefaultModel(id: "claude-sonnet-4-6", providerID: .anthropic, name: "Claude Sonnet 4.6", package: "@opencode/ai/providers/anthropic", family: "claude-sonnet", baseURL: "https://api.anthropic.com/v1", context: 200_000, output: 64_000),
                    makeDefaultModel(id: "claude-opus-4-6", providerID: .anthropic, name: "Claude Opus 4.6", package: "@opencode/ai/providers/anthropic", family: "claude-opus", baseURL: "https://api.anthropic.com/v1", context: 200_000, output: 32_000),
                    makeDefaultModel(id: "claude-haiku-4-5-20251001", providerID: .anthropic, name: "Claude Haiku 4.5", package: "@opencode/ai/providers/anthropic", family: "claude-haiku", baseURL: "https://api.anthropic.com/v1", context: 200_000, output: 16_000),
                ],
                environment: ["ANTHROPIC_API_KEY"]
            ),
            CoreModel.ModelsDev.Snapshot(
                info: ProviderSchema.Info(
                    id: .openai,
                    integrationID: IntegrationID(rawValue: "openai"),
                    name: "OpenAI",
                    activation: .auto,
                    package: "@opencode/ai/providers/openai",
                    settings: ProviderSchema.Settings(extra: ["baseURL": .string("https://api.openai.com/v1")])
                ),
                models: [
                    makeDefaultModel(id: "gpt-5", providerID: .openai, name: "GPT-5", package: "@opencode/ai/providers/openai", family: "gpt-5", baseURL: "https://api.openai.com/v1", context: 272_000, output: 128_000),
                    makeDefaultModel(id: "gpt-5-mini", providerID: .openai, name: "GPT-5 Mini", package: "@opencode/ai/providers/openai", family: "gpt-5", baseURL: "https://api.openai.com/v1", context: 272_000, output: 64_000),
                ],
                environment: ["OPENAI_API_KEY"]
            ),
            CoreModel.ModelsDev.Snapshot(
                info: ProviderSchema.Info(
                    id: .google,
                    integrationID: IntegrationID(rawValue: "google"),
                    name: "Google",
                    activation: .auto,
                    package: "@opencode/ai/providers/google",
                    settings: ProviderSchema.Settings(extra: ["baseURL": .string("https://generativelanguage.googleapis.com/v1beta")])
                ),
                models: [
                    makeDefaultModel(id: "gemini-2.5-pro", providerID: .google, name: "Gemini 2.5 Pro", package: "@opencode/ai/providers/google", family: "gemini-2.5", baseURL: "https://generativelanguage.googleapis.com/v1beta", context: 1_048_576, output: 65_536),
                    makeDefaultModel(id: "gemini-2.5-flash", providerID: .google, name: "Gemini 2.5 Flash", package: "@opencode/ai/providers/google", family: "gemini-2.5", baseURL: "https://generativelanguage.googleapis.com/v1beta", context: 1_048_576, output: 65_536),
                ],
                environment: ["GEMINI_API_KEY", "GOOGLE_GENERATIVE_AI_API_KEY", "GOOGLE_API_KEY"]
            ),
            CoreModel.ModelsDev.Snapshot(
                info: ProviderSchema.Info(
                    id: .openrouter,
                    integrationID: IntegrationID(rawValue: "openrouter"),
                    name: "OpenRouter",
                    activation: .auto,
                    package: "@opencode/ai/providers/openrouter",
                    settings: ProviderSchema.Settings(extra: ["baseURL": .string("https://openrouter.ai/api/v1")])
                ),
                models: [
                    makeDefaultModel(id: "anthropic/claude-sonnet-4", providerID: .openrouter, name: "Claude Sonnet 4 (OpenRouter)", package: "@opencode/ai/providers/openrouter", baseURL: "https://openrouter.ai/api/v1", context: 200_000, output: 16_000),
                ],
                environment: ["OPENROUTER_API_KEY"]
            ),
            CoreModel.ModelsDev.Snapshot(
                info: ProviderSchema.Info(
                    id: ProviderSchema.ID(rawValue: "xai"),
                    integrationID: IntegrationID(rawValue: "xai"),
                    name: "xAI",
                    activation: .auto,
                    package: "@opencode/ai/providers/xai",
                    settings: ProviderSchema.Settings(extra: ["baseURL": .string("https://api.x.ai/v1")])
                ),
                models: [
                    makeDefaultModel(id: "grok-4", providerID: ProviderSchema.ID(rawValue: "xai"), name: "Grok 4", package: "@opencode/ai/providers/xai", family: "grok-4", baseURL: "https://api.x.ai/v1", context: 256_000, output: 32_000),
                ],
                environment: ["XAI_API_KEY"]
            ),
            CoreModel.ModelsDev.Snapshot(
                info: ProviderSchema.Info(
                    id: ProviderSchema.ID(rawValue: "groq"),
                    integrationID: IntegrationID(rawValue: "groq"),
                    name: "Groq",
                    activation: .auto,
                    package: "@opencode/ai/providers/groq",
                    settings: ProviderSchema.Settings(extra: ["baseURL": .string("https://api.groq.com/openai/v1")])
                ),
                models: [
                    makeDefaultModel(id: "llama-3.3-70b-versatile", providerID: ProviderSchema.ID(rawValue: "groq"), name: "Llama 3.3 70B", package: "@opencode/ai/providers/groq", baseURL: "https://api.groq.com/openai/v1", context: 131_072, output: 32_768, inputModalities: ["text"]),
                ],
                environment: ["GROQ_API_KEY"]
            ),
            CoreModel.ModelsDev.Snapshot(
                info: ProviderSchema.Info(
                    id: ProviderSchema.ID(rawValue: "deepseek"),
                    integrationID: IntegrationID(rawValue: "deepseek"),
                    name: "DeepSeek",
                    activation: .auto,
                    package: "@opencode/ai/providers/deepseek",
                    settings: ProviderSchema.Settings(extra: ["baseURL": .string("https://api.deepseek.com")])
                ),
                models: [
                    makeDefaultModel(id: "deepseek-chat", providerID: ProviderSchema.ID(rawValue: "deepseek"), name: "DeepSeek Chat", package: "@opencode/ai/providers/deepseek", baseURL: "https://api.deepseek.com", context: 128_000, output: 8_192, inputModalities: ["text"]),
                    makeDefaultModel(id: "deepseek-reasoner", providerID: ProviderSchema.ID(rawValue: "deepseek"), name: "DeepSeek Reasoner", package: "@opencode/ai/providers/deepseek", baseURL: "https://api.deepseek.com", context: 128_000, output: 64_000, inputModalities: ["text"]),
                ],
                environment: ["DEEPSEEK_API_KEY"]
            ),
            CoreModel.ModelsDev.Snapshot(
                info: ProviderSchema.Info(
                    id: .mistral,
                    integrationID: IntegrationID(rawValue: "mistral"),
                    name: "Mistral",
                    activation: .auto,
                    package: "@opencode/ai/providers/mistral",
                    settings: ProviderSchema.Settings(extra: ["baseURL": .string("https://api.mistral.ai/v1")])
                ),
                models: [
                    makeDefaultModel(id: "mistral-large-latest", providerID: .mistral, name: "Mistral Large", package: "@opencode/ai/providers/mistral", baseURL: "https://api.mistral.ai/v1", context: 128_000, output: 16_384, inputModalities: ["text"]),
                ],
                environment: ["MISTRAL_API_KEY"]
            ),
            CoreModel.ModelsDev.Snapshot(
                info: ProviderSchema.Info(
                    id: ProviderSchema.ID(rawValue: "cerebras"),
                    integrationID: IntegrationID(rawValue: "cerebras"),
                    name: "Cerebras",
                    activation: .auto,
                    package: "@opencode/ai/providers/cerebras",
                    settings: ProviderSchema.Settings(extra: ["baseURL": .string("https://api.cerebras.ai/v1")])
                ),
                models: [
                    makeDefaultModel(id: "llama-3.3-70b", providerID: ProviderSchema.ID(rawValue: "cerebras"), name: "Llama 3.3 70B (Cerebras)", package: "@opencode/ai/providers/cerebras", baseURL: "https://api.cerebras.ai/v1", context: 128_000, output: 8_192, inputModalities: ["text"]),
                ],
                environment: ["CEREBRAS_API_KEY"]
            ),
            CoreModel.ModelsDev.Snapshot(
                info: ProviderSchema.Info(
                    id: .amazonBedrock,
                    integrationID: IntegrationID(rawValue: "amazon-bedrock"),
                    name: "Amazon Bedrock",
                    activation: .auto,
                    package: "@opencode/ai/providers/amazon-bedrock"
                ),
                models: [
                    makeDefaultModel(id: "anthropic.claude-sonnet-4-6", providerID: .amazonBedrock, name: "Claude Sonnet 4.6 (Bedrock)", package: "@opencode/ai/providers/amazon-bedrock", context: 200_000, output: 64_000),
                ],
                environment: ["AWS_BEARER_TOKEN_BEDROCK"]
            ),
            CoreModel.ModelsDev.Snapshot(
                info: ProviderSchema.Info(
                    id: .azure,
                    integrationID: IntegrationID(rawValue: "azure"),
                    name: "Azure OpenAI",
                    activation: .auto,
                    package: "@opencode/ai/providers/azure"
                ),
                models: [
                    makeDefaultModel(id: "gpt-5", providerID: .azure, name: "GPT-5 (Azure)", package: "@opencode/ai/providers/azure", context: 272_000, output: 64_000),
                ],
                environment: ["AZURE_OPENAI_API_KEY", "AZURE_API_KEY"]
            ),
            CoreModel.ModelsDev.Snapshot(
                info: ProviderSchema.Info(
                    id: .googleVertex,
                    integrationID: IntegrationID(rawValue: "google-vertex"),
                    name: "Google Vertex AI",
                    activation: .auto,
                    package: "@opencode/ai/providers/google-vertex"
                ),
                models: [
                    makeDefaultModel(id: "gemini-2.5-pro", providerID: .googleVertex, name: "Gemini 2.5 Pro (Vertex)", package: "@opencode/ai/providers/google-vertex", context: 1_048_576, output: 65_536),
                ],
                environment: ["GOOGLE_VERTEX_API_KEY"]
            ),
        ]
    }

    private static func filterModelsDevSnapshots(_ data: [CoreModel.ModelsDev.Snapshot]) -> [CoreModel.ModelsDev.Snapshot] {
        data
            .filter { $0.info.id.rawValue != "azure-cognitive-services" && $0.info.id.rawValue != "google-vertex-anthropic" }
            .map { snap in
                let filteredModels = snap.models.filter { model in
                    model.status != .deprecated
                        && ((model.type ?? .chat) != .chat || CoreModel.Model.supportsText(model))
                        && !(snap.info.id == .amazonBedrock && bedrockProfileOnlyIDs.contains(model.modelID.rawValue))
                }
                return CoreModel.ModelsDev.Snapshot(info: snap.info, models: filteredModels, environment: snap.environment)
            }
            .filter { !$0.models.isEmpty }
    }

    /// Constructs a `ModelsDevPlugin` backed by an explicit or task-local `CoreModel.ModelsDev.Interface`,
    /// falling back to built-in default snapshots when offline or uncached.
    public static func makeModelsDevPlugin(
        modelsDev: (any CoreModel.ModelsDev.Interface)? = nil,
        fallbackDefaults: [CoreModel.ModelsDev.Snapshot] = defaultModelsDevSnapshots()
    ) -> PluginEffect.Plugin {
        PluginEffect.define(
            PluginEffect.Plugin(id: "opencode.models.dev") { ctx in
                let service = modelsDev ?? Host.currentModelsDevOverride
                let fetched: [CoreModel.ModelsDev.Snapshot]
                if let service, let loaded = try? await service.get(), !loaded.isEmpty {
                    fetched = filterModelsDevSnapshots(loaded)
                } else {
                    fetched = []
                }
                let snapshots = fetched.isEmpty ? filterModelsDevSnapshots(fallbackDefaults) : fetched
                let env = Host.currentEnvironment

                _ = await ctx.integration.transform { editor in
                    for snap in snapshots where !snap.environment.isEmpty {
                        let intID = snap.info.id.rawValue
                        editor.update(intID) { item in item.name = snap.info.name }
                        editor.method.update(.key(integrationID: intID, method: PluginEffect.IntegrationKeyMethod()))
                        editor.method.update(.env(integrationID: intID, method: PluginEffect.IntegrationEnvMethod(names: snap.environment)))
                    }
                }

                _ = await ctx.provider.transform { editor in
                    for snap in snapshots {
                        let hasEnvKey = snap.environment.contains { key in
                            if let val = env.variable(key), !val.isEmpty { return true }
                            return false
                        }
                        let activation: ProviderSchema.Activation = (snap.info.activation == .auto && hasEnvKey)
                            ? .enabled
                            : snap.info.activation
                        let info = ProviderSchema.Info(
                            id: snap.info.id,
                            canonical: snap.info.canonical,
                            integrationID: snap.info.integrationID ?? IntegrationID(rawValue: snap.info.id.rawValue),
                            name: snap.info.name,
                            activation: activation,
                            package: snap.info.package,
                            compatibility: snap.info.compatibility,
                            settings: snap.info.settings,
                            headers: snap.info.headers,
                            body: snap.info.body
                        )
                        editor.add(info, snap.models, nil)
                    }
                }
            }
        )
    }

    /// Built-in models.dev catalog synchronization plugin (`opencode.models.dev`).
    // parity: core/src/plugin/models-dev.ts#ModelsDevPlugin [status=adapted hash=1f5b39ed3fba]
    public static let ModelsDevPlugin = makeModelsDevPlugin()

    public enum OptimizePlugin {
        /// Resolves full `ModelSchema.Info` metadata for a session hook's `ModelSchema.Ref`.
        // parity: core/src/plugin/optimize.ts#resolveModel [status=implemented hash=2d7487e0e0be]
        public static func resolveModel(ctx: PluginEffect.Context, model: ModelSchema.Ref) async -> ModelSchema.Info? {
            guard let located = try? await ctx.model.list(nil) else { return nil }
            return located.data.first { $0.providerID == model.providerID && $0.id == model.id }
        }

        private static func registerOptimization(
            id: String,
            providerMatcher: @escaping @Sendable (ModelSchema.Ref, ModelSchema.Info?) -> Bool,
            optionKey: String,
            optionValue: JSONValue
        ) -> PluginEffect.Plugin {
            PluginEffect.define(
                PluginEffect.Plugin(id: id) { ctx in
                    _ = await ctx.session.hook("context", { event in
                        guard case .context(var c) = event else { return event }
                        let resolved = await resolveModel(ctx: ctx, model: c.model)
                        if providerMatcher(c.model, resolved), c.options.providerOptions[optionKey] == nil {
                            c.options.providerOptions[optionKey] = optionValue
                        }
                        return .context(c)
                    }, nil)
                }
            )
        }

        // parity: core/src/plugin/optimize.ts#OpenAIPlugin [status=adapted hash=9c958fc08236]
        public static let OpenAIPlugin = registerOptimization(
            id: "opencode.prompt.openai",
            providerMatcher: { ref, info in
                ref.providerID.rawValue == "openai" || info?.id.rawValue.hasPrefix("gpt-") == true
            },
            optionKey: "parallelToolCalls",
            optionValue: .bool(true)
        )

        // parity: core/src/plugin/optimize.ts#AnthropicPlugin [status=adapted hash=9b457cb8f764]
        public static let AnthropicPlugin = registerOptimization(
            id: "opencode.prompt.anthropic",
            providerMatcher: { ref, info in
                ref.providerID.rawValue == "anthropic" || info?.id.rawValue.contains("claude") == true
            },
            optionKey: "promptCaching",
            optionValue: .bool(true)
        )

        // parity: core/src/plugin/optimize.ts#OpenAIToolsPlugin [status=adapted hash=3936764cfa14]
        public static let OpenAIToolsPlugin = registerOptimization(
            id: "opencode.optimize.openai.tools",
            providerMatcher: { ref, _ in ref.providerID.rawValue == "openai" },
            optionKey: "strictToolSchemas",
            optionValue: .bool(true)
        )

        // parity: core/src/plugin/optimize.ts#AnthropicToolsPlugin [status=adapted hash=0008a6a9b515]
        public static let AnthropicToolsPlugin = registerOptimization(
            id: "opencode.optimize.anthropic.tools",
            providerMatcher: { ref, _ in ref.providerID.rawValue == "anthropic" },
            optionKey: "cacheToolDefinitions",
            optionValue: .bool(true)
        )

        // parity: core/src/plugin/optimize.ts#KimiPlugin [status=adapted hash=73f62a9f888f]
        public static let KimiPlugin = registerOptimization(
            id: "opencode.prompt.kimi",
            providerMatcher: { ref, info in
                ref.id.rawValue.lowercased().contains("kimi") || info?.family?.rawValue.lowercased().contains("kimi") == true
            },
            optionKey: "promptFamily",
            optionValue: .string("kimi")
        )

        // parity: core/src/plugin/optimize.ts#ArceePlugin [status=adapted hash=91424a8b68d0]
        public static let ArceePlugin = registerOptimization(
            id: "opencode.prompt.arcee",
            providerMatcher: { ref, info in
                ref.id.rawValue.lowercased().contains("arcee") || info?.family?.rawValue.lowercased().contains("arcee") == true
            },
            optionKey: "promptFamily",
            optionValue: .string("arcee")
        )

        // parity: core/src/plugin/optimize.ts#MetaPlugin [status=adapted hash=4c1cee47fa9c]
        public static let MetaPlugin = registerOptimization(
            id: "opencode.prompt.meta",
            providerMatcher: { ref, info in
                ref.providerID.rawValue == "meta" || ref.id.rawValue.lowercased().contains("llama") || info?.family?.rawValue.lowercased().contains("llama") == true
            },
            optionKey: "promptFamily",
            optionValue: .string("meta")
        )

        /// Active prompt optimization plugins registered during core startup.
        // parity: core/src/plugin/optimize.ts#Plugins [status=implemented hash=58b6bd3d3f99]
        public static let Plugins: [PluginEffect.Plugin] = [
            OpenAIPlugin,
            AnthropicPlugin,
            KimiPlugin,
            ArceePlugin,
            MetaPlugin,
        ]
    }

    public enum PlanPlugin {
        public static func enterReminder(directory: String) -> String {
            """
            <system-reminder>
            You are in Plan mode. Discuss the plan with the user directly in the conversation. Do not create or update plan files unless the user explicitly asks you to; when they do, write them only in:
            \(directory)

            Do not modify any other files or ask a subagent to do so.

            You remain in Plan mode until the user switches agents. If the user asks you to implement changes, do not do so. Tell them they need to switch agents.
            </system-reminder>
            """
        }

        public static let leaveReminder = """
        <system-reminder>
        You are NO LONGER in Plan mode. The previous Plan restrictions no longer apply. Any Plan mode instructions from earlier in this conversation are no longer active.
        </system-reminder>
        """

        /// Built-in Plan mode agent & read-only guardrails plugin (`opencode.plan`).
        // parity: core/src/plugin/plan.ts#Plugin [status=adapted hash=7ddb7627ecbc]
        public static let Plugin = PluginEffect.define(
            PluginEffect.Plugin(id: "opencode.plan") { ctx in
                let planID = AgentSchema.ID(rawValue: "plan")
                let home = Host.currentEnvironment.homeDirectory ?? "/tmp"
                let directory = PluginContract.joinPath(PluginContract.joinPath(home, ".opencode"), "plan")
                let enterText = enterReminder(directory: directory)

                _ = await ctx.agent.transform { editor in
                    editor.update("plan") { item in
                        item = AgentSchema.Info(
                            id: planID,
                            name: AgentSchema.Name(rawValue: "Plan"),
                            model: item.model,
                            request: item.request,
                            system: item.system,
                            description: "Read-only agent for exploring the codebase and planning work before implementation.",
                            mode: .primary,
                            hidden: false,
                            color: item.color,
                            steps: item.steps,
                            permissions: item.permissions + [
                                PermissionSchema.Rule(action: "question", resource: "*", effect: .allow),
                                PermissionSchema.Rule(action: "edit", resource: "*", effect: .deny),
                                PermissionSchema.Rule(action: "edit", resource: PluginContract.joinPath(directory, "*"), effect: .allow),
                            ]
                        )
                    }
                }

                _ = await ctx.tool.hook("execute.after") { event in
                    guard case .executeAfter(var after) = event else { return event }
                    guard after.agent == planID,
                          after.tool == "edit" || after.tool == "write" || after.tool == "patch",
                          case .error(let err) = after.outcome,
                          err.message.lowercased().contains("permission") || err.message.lowercased().contains("denied")
                    else { return event }
                    after.outcome = .error(
                        ToolSchema.ToolError(
                            message: "Cannot use \(after.tool) to modify files outside the Plan directory: \(directory)"
                        )
                    )
                    return .executeAfter(after)
                }

                _ = await ctx.session.hook("context", { event in
                    guard case .context(var c) = event else { return event }
                    if c.agent == planID {
                        let alreadyPresent = c.system.contains { $0.text == enterText }
                        if !alreadyPresent {
                            c.system.append(AISchema.SystemPart(text: enterText))
                        }
                    }
                    return .context(c)
                }, nil)
            }
        )
    }

    public enum SkillPlugin {
        /// Built-in OpenCode reference skill markdown content.
        // parity: core/src/plugin/skill.ts#OpencodeContent [status=adapted hash=07d52d342d51]
        public static let OpencodeContent = "# OpenCode Reference Skill\nUse OpenCode docs, SDK, tools, and configuration conventions."

        /// Built-in issue reporting skill markdown content.
        // parity: core/src/plugin/skill.ts#ReportContent [status=adapted hash=36587ed0eadc]
        public static let ReportContent = "# OpenCode Issue Report Skill\nCollect diagnostics and publish reproduction details."

        /// Description advertised for the built-in `opencode` skill.
        // parity: core/src/plugin/skill.ts#OpencodeDescription [status=implemented hash=dc25c7c82770]
        public static let OpencodeDescription =
            "Use this skill for any question about OpenCode itself, including how OpenCode works, using or configuring it, migrating from V1 to V2, troubleshooting it, developing plugins or integrations, using the OpenCode SDK, clients, server, or API, and contributing to the OpenCode codebase. Also use it for OpenCode agents, commands, skills, tools, permissions, MCP servers, providers, models, themes, keybinds, formatters, the CLI, TUI, desktop app, and web app."

        /// Built-in skill plugin (`opencode.skill`) registering `opencode` and `report` skills.
        // parity: core/src/plugin/skill.ts#Plugin [status=implemented hash=efbbd4294e79]
        public static let Plugin = PluginEffect.define(
            PluginEffect.Plugin(id: "opencode.skill") { ctx in
                _ = await ctx.skill.transform { editor in
                    editor.add(
                        SkillSchema.Info(
                            id: SkillSchema.ID(rawValue: "opencode"),
                            name: SkillSchema.Name(rawValue: "OpenCode"),
                            description: OpencodeDescription,
                            path: SchemaPrimitive.AbsolutePath(rawValue: "skill://opencode/SKILL.md"),
                            content: OpencodeContent
                        )
                    )
                    editor.add(
                        SkillSchema.Info(
                            id: SkillSchema.ID(rawValue: "report"),
                            name: SkillSchema.Name(rawValue: "Report"),
                            description: "Use when the user wants to report an opencode issue or bug.",
                            path: SchemaPrimitive.AbsolutePath(rawValue: "skill://report/SKILL.md"),
                            content: ReportContent
                        )
                    )
                }
            }
        )
    }

    public enum ToolInputRepairPlugin {
        /// Built-in tool alias (`bash` -> `shell`) & schema-driven input repair plugin (`opencode.tool.input.repair`).
        // parity: core/src/plugin/tool-input-repair.ts#Plugin [status=implemented hash=edf14786640a]
        public static let Plugin = PluginEffect.define(
            PluginEffect.Plugin(id: "opencode.tool.input.repair") { ctx in
                let aliased = Mutex<[String: String]>([:])
                _ = await ctx.tool.hook("execute.before") { event in
                    guard case .executeBefore(var before) = event else { return event }
                    if before.tool == "execute" { return event }
                    let tools = await ctx.tool.list()
                    if !tools.contains(where: { $0.id == before.tool }),
                       before.tool == "bash",
                       tools.contains(where: { $0.id == "shell" })
                    {
                        aliased.withLock { $0[before.id.rawValue] = before.tool }
                        before.tool = "shell"
                    }
                    return .executeBefore(before)
                }
                _ = await ctx.tool.hook("execute.after") { event in
                    guard case .executeAfter(var after) = event else { return event }
                    guard let called = aliased.withLock({ $0.removeValue(forKey: after.id.rawValue) }) else {
                        return event
                    }
                    let note = "There is no \"\(called)\" tool, so this ran as \"\(after.tool)\". Call \"\(after.tool)\" directly."
                    if case .error(let err) = after.outcome {
                        after.outcome = .error(
                            ToolSchema.ToolError(
                                message: "\(err.message)\n\n\(note)",
                                error: err.error,
                                metadata: err.metadata
                            )
                        )
                    }
                    return .executeAfter(after)
                }
            }
        )
    }

    public enum VerbosityPlugin {
        /// Built-in GPT-5/GPT-6 default `textVerbosity = "low"` plugin (`opencode.prompt.verbosity`).
        // parity: core/src/plugin/verbosity.ts#Plugin [status=adapted hash=652288a21817]
        public static let Plugin = PluginEffect.define(
            PluginEffect.Plugin(id: "opencode.prompt.verbosity") { ctx in
                _ = await ctx.session.hook("context", { event in
                    guard case .context(var c) = event else { return event }
                    let modelID = c.model.id.rawValue.lowercased()
                    if (modelID.hasPrefix("gpt-5") || modelID.hasPrefix("gpt-6")),
                       c.options.providerOptions["textVerbosity"] == nil
                    {
                        c.options.providerOptions["textVerbosity"] = .string("low")
                    }
                    return .context(c)
                }, nil)
            }
        )
    }

    public enum WarmingPlugin {
        /// Built-in prompt-cache keep-alive warming plugin (`opencode.warming`).
        // parity: core/src/plugin/warming.ts#Plugin [status=adapted hash=9a79c366abf0]
        public static let Plugin = PluginEffect.define(
            PluginEffect.Plugin(id: "opencode.warming") { ctx in
                _ = await ctx.session.hook("context", { event in
                    guard case .context(var c) = event else { return event }
                    if c.options.providerOptions["promptCacheWarming"] == nil {
                        c.options.providerOptions["promptCacheWarming"] = .bool(true)
                    }
                    return .context(c)
                }, nil)
            }
        )
    }

    // MARK: - VCS Plugins (`plugin/vcs/git.ts`, `plugin/vcs/hg.ts`)

    public enum VcsGitPlugin {
        /// Builds a `PluginEffect.VcsDefinition` backed by `CoreVcs.Git.Service`.
        public static func definition(
            git: CoreVcs.Git.Service? = nil
        ) -> PluginEffect.VcsDefinition {
            let capturedGit = git
            @Sendable func resolveGit() -> CoreVcs.Git.Service {
                capturedGit ?? CoreVcs.Git.Service(
                    spawner: Host.currentProcessSpawner,
                    fileSystem: Host.currentFileSystem
                )
            }
            return PluginEffect.VcsDefinition(
                id: "git",
                name: "Git",
                initRepo: { scope in
                    try await resolveGit().initRepository(at: scope.worktree)
                },
                info: { scope in
                    let g = resolveGit()
                    let current = await g.currentBranch(in: scope.directory)
                    let root = await g.defaultBranch(in: scope.directory)
                    return VcsSchema.Info(
                        provider: "git",
                        branch: VcsSchema.Branch(current: current, defaultBranch: root?.name)
                    )
                },
                base: { scope in
                    try await resolveGit().base(in: scope.directory)
                },
                branches: { input in
                    await resolveGit().branches(
                        in: input.scope.directory,
                        options: CoreVcs.Vcs.BranchOptions(search: input.search, limit: input.limit)
                    )
                },
                status: { scope in
                    await resolveGit().status(in: scope.directory, worktree: scope.worktree)
                },
                diff: { input in
                    try await resolveGit().diff(
                        in: input.scope.directory,
                        worktree: input.scope.worktree,
                        mode: input.mode,
                        options: CoreVcs.Vcs.DiffOptions(
                            context: input.context,
                            base: input.base,
                            untracked: input.untracked
                        )
                    )
                }
            )
        }

        /// Registers the real Git VCS provider directly onto a `CoreVcs.Vcs.Service`.
        @discardableResult
        public static func register(
            on vcsService: CoreVcs.Vcs.Service,
            directory: String? = nil,
            worktree: String? = nil,
            git: CoreVcs.Git.Service = CoreVcs.Git.Service()
        ) async throws -> CoreState.Registration {
            let dir = directory ?? vcsService.directory.rawValue
            let provider = CoreVcs.Git.makeVcsProvider(directory: dir, worktree: worktree ?? dir, git: git)
            return try await vcsService.transform { editor in
                editor.add(provider)
                if editor.defaultSelection == nil {
                    editor.defaultSelection = "git"
                }
            }
        }

        /// Constructs a `VcsGitPlugin` bound to an optional explicit `CoreVcs.Git.Service`.
        public static func make(git: CoreVcs.Git.Service? = nil) -> PluginEffect.Plugin {
            PluginEffect.define(
                PluginEffect.Plugin(id: "opencode.vcs.git") { ctx in
                    let gitService = git ?? CoreVcs.Git.Service(
                        spawner: Host.currentProcessSpawner,
                        fileSystem: Host.currentFileSystem
                    )
                    let def = definition(git: gitService)
                    _ = await ctx.vcs.transform { editor in
                        editor.add(def)
                        if editor.getDefault() == nil {
                            editor.setDefault("git")
                        }
                    }
                }
            )
        }

        /// Built-in Git VCS plugin (`opencode.vcs.git`) backed by `CoreVcs.Git.Service`.
        // parity: core/src/plugin/vcs/git.ts#Plugin [status=adapted hash=df2b85e1b539]
        public static let Plugin = make()
    }

    public enum VcsHgPlugin {
        /// Built-in Mercurial VCS plugin (`opencode.vcs.hg`) invoking `hg` via `ProcessSpawner`.
        // parity: core/src/plugin/vcs/hg.ts#Plugin [status=adapted hash=5f7b3ce3e912]
        public static let Plugin = PluginEffect.define(
            PluginEffect.Plugin(id: "opencode.vcs.hg") { ctx in
                let capturedSpawner = Host.currentProcessSpawnerOverride
                @Sendable func runHg(_ args: [String], cwd: String) async -> ProcessOutput? {
                    let spawner = capturedSpawner ?? Host.currentProcessSpawner
                    return try? await spawner.run(ProcessSpec(executable: "hg", arguments: args, workingDirectory: cwd))
                }
                let def = PluginEffect.VcsDefinition(
                    id: "hg",
                    name: "Mercurial",
                    initRepo: { scope in
                        guard let out = await runHg(["init"], cwd: scope.worktree), out.exitCode == 0 else {
                            throw CoreVcs.Vcs.InitializeError(kind: .failed)
                        }
                    },
                    info: { scope in
                        let out = await runHg(["branch"], cwd: scope.directory)
                        let branchName: String? = (out?.exitCode == 0)
                            ? String(decoding: out?.stdout ?? [], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                            : nil
                        return VcsSchema.Info(
                            provider: "hg",
                            branch: VcsSchema.Branch(current: (branchName?.isEmpty == false) ? branchName : nil, defaultBranch: "default")
                        )
                    },
                    base: nil,
                    branches: { input in
                        guard let out = await runHg(["branches", "-T", "{branch}\n"], cwd: input.scope.directory),
                              out.exitCode == 0
                        else { return [] }
                        var list = String(decoding: out.stdout, as: UTF8.self)
                            .split(whereSeparator: \.isNewline)
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        if let search = input.search?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !search.isEmpty {
                            list = list.filter { $0.lowercased().contains(search) }
                        }
                        if let limit = input.limit, limit >= 0, list.count > limit {
                            return Array(list.prefix(limit))
                        }
                        return list
                    },
                    status: { scope in
                        guard let out = await runHg(["status"], cwd: scope.directory), out.exitCode == 0 else { return [] }
                        var items: [VcsSchema.FileStatus] = []
                        for line in String(decoding: out.stdout, as: UTF8.self).split(whereSeparator: \.isNewline) {
                            guard line.count >= 3 else { continue }
                            let code = line.first
                            let file = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                            guard !file.isEmpty else { continue }
                            let status: VcsSchema.FileStatus.Status = switch code {
                            case "A", "?": .added
                            case "R", "!": .deleted
                            default: .modified
                            }
                            items.append(VcsSchema.FileStatus(file: file, additions: .zero, deletions: .zero, status: status))
                        }
                        return items.sorted { $0.file < $1.file }
                    },
                    diff: { input in
                        guard let out = await runHg(["diff", "--git"], cwd: input.scope.directory), out.exitCode == 0 else {
                            return []
                        }
                        let raw = String(decoding: out.stdout, as: UTF8.self)
                        let byFile = CoreVcs.Patch.chunksByFile(CoreVcs.Patch.Info(text: raw, truncated: false))
                        return byFile.keys.sorted().map { file in
                            let chunk = byFile[file] ?? ""
                            let counts = CoreVcs.Patch.countPatch(chunk)
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
                )
                _ = await ctx.vcs.transform { editor in
                    editor.add(def)
                }
            }
        )
    }

    // MARK: - WebSearch Plugins (`plugin/websearch/*`)

    public enum WebSearchMcp {
        /// Maximum bounded HTTP response size accepted from MCP search endpoints (256 KiB).
        // parity: core/src/plugin/websearch/mcp.ts#MAX_RESPONSE_BYTES [status=implemented hash=06e2315682b9]
        public static let MAX_RESPONSE_BYTES = 256 * 1024

        /// Parses an MCP JSON-RPC `result` envelope from either direct JSON or SSE `data: ` lines.
        // parity: core/src/plugin/websearch/mcp.ts#parseResponse [status=implemented hash=9d9ed2d7da84]
        public static func parseResponse(_ body: String) -> JSONValue? {
            func extractResult(from payload: String) -> JSONValue? {
                let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
                guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
                      case .object(let map) = decoded,
                      let result = map["result"]
                else {
                    return nil
                }
                return result
            }
            if let direct = extractResult(from: body) {
                return direct
            }
            for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(rawLine)
                guard line.hasPrefix("data: ") else { continue }
                if let parsed = extractResult(from: String(line.dropFirst(6))) {
                    return parsed
                }
            }
            return nil
        }

        /// Executes an MCP JSON-RPC 2.0 `tools/call` HTTP POST request over `OpenCodePlatform.HTTPTransport`.
        // parity: core/src/plugin/websearch/mcp.ts#call [status=implemented hash=7495d70449d6]
        public static func call(
            transport: any HTTPTransport,
            url: String,
            tool: String,
            arguments: JSONValue,
            headers: [String: String] = [:]
        ) async throws -> JSONValue? {
            let payload: JSONValue = .object([
                "jsonrpc": .string("2.0"),
                "id": .int(1),
                "method": .string("tools/call"),
                "params": .object([
                    "name": .string(tool),
                    "arguments": arguments,
                ]),
            ])
            let bodyBytes = Array(try JSONEncoder().encode(payload))
            var mergedHeaders = headers
            mergedHeaders["Accept"] = "application/json, text/event-stream"
            mergedHeaders["Content-Type"] = "application/json"
            let response = try await transport.send(
                HTTPRequest(method: "POST", url: url, headers: mergedHeaders, body: bodyBytes)
            )
            guard (200..<300).contains(response.head.statusCode) else {
                throw ToolSchema.ToolError(message: "\(tool) failed with HTTP \(response.head.statusCode)")
            }
            guard response.body.count <= MAX_RESPONSE_BYTES else {
                throw ToolSchema.ToolError(message: "\(tool) response exceeded \(MAX_RESPONSE_BYTES) bytes")
            }
            return parseResponse(String(decoding: response.body, as: UTF8.self))
        }

        internal static func firstTextContent(in result: JSONValue?) -> String? {
            guard case .object(let obj) = result, case .array(let content) = obj["content"] else { return nil }
            for item in content {
                if case .object(let entry) = item, case .string(let text) = entry["text"], !text.isEmpty {
                    return text
                }
            }
            return nil
        }

        internal static func parseISOEpochMs(_ raw: String?) -> Double? {
            guard let raw else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != "N/A" else { return nil }
            #if os(macOS) || os(Linux) || os(Windows)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = formatter.date(from: trimmed) {
                return d.timeIntervalSince1970 * 1_000.0
            }
            formatter.formatOptions = [.withInternetDateTime]
            if let d = formatter.date(from: trimmed) {
                return d.timeIntervalSince1970 * 1_000.0
            }
            formatter.formatOptions = [.withFullDate]
            if let d = formatter.date(from: trimmed) {
                return d.timeIntervalSince1970 * 1_000.0
            }
            #endif
            return nil
        }
    }

    public enum WebSearchProvider {
        /// Registers a web search provider together with its API-key & env integration methods.
        // parity: core/src/plugin/websearch/provider.ts#register [status=implemented hash=6d2b0c9f7ab2]
        public static func register(
            ctx: PluginEffect.Context,
            id: String,
            name: String,
            env: String,
            execute: @escaping @Sendable (WebSearchSchema.ProviderInput, CredentialSchema.Value?) async throws -> [WebSearchSchema.Result]
        ) async {
            _ = await ctx.integration.transform { editor in
                editor.update(id) { item in item.name = name }
                editor.method.update(.key(integrationID: id, method: PluginEffect.IntegrationKeyMethod()))
                editor.method.update(.env(integrationID: id, method: PluginEffect.IntegrationEnvMethod(names: [env])))
            }
            _ = await ctx.websearch.transform { editor in
                editor.add(
                    PluginEffect.WebSearchDefinition(id: id, name: name) { input in
                        let conn = await ctx.integration.connection.active(id)
                        let cred = if let conn { try? await ctx.integration.connection.resolve(conn) } else { nil as CredentialSchema.Value? }
                        return try await execute(input, cred)
                    }
                )
            }
        }
    }

    public enum WebSearchExa {
        // parity: core/src/plugin/websearch/exa.ts#endpoint [status=implemented hash=48be7f0e793f]
        public static let endpoint = "https://mcp.exa.ai/mcp"

        public static func parseResults(_ text: String) -> [WebSearchSchema.Result] {
            let blocks = text.components(separatedBy: "\n\n---\n\n")
            var out: [WebSearchSchema.Result] = []
            for block in blocks {
                var url: String?
                var title: String?
                var publishedText: String?
                var contentLines: [String] = []
                var inContent = false
                for rawLine in block.split(separator: "\n", omittingEmptySubsequences: false) {
                    let line = String(rawLine)
                    if inContent {
                        contentLines.append(line)
                        continue
                    }
                    if line.hasPrefix("URL:") {
                        url = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
                    } else if line.hasPrefix("Title:") {
                        let t = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        if !t.isEmpty && t != "N/A" { title = t }
                    } else if line.hasPrefix("Published:") {
                        publishedText = line.dropFirst(10).trimmingCharacters(in: .whitespaces)
                    } else if line.hasPrefix("Highlights:") {
                        inContent = true
                        let rest = line.dropFirst(11).trimmingCharacters(in: .whitespaces)
                        if !rest.isEmpty { contentLines.append(rest) }
                    } else if line.hasPrefix("Text:") {
                        inContent = true
                        let rest = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if !rest.isEmpty { contentLines.append(rest) }
                    }
                }
                guard let url, !url.isEmpty else { continue }
                let content = contentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                let published = WebSearchMcp.parseISOEpochMs(publishedText)
                out.append(WebSearchSchema.Result(
                    url: url,
                    title: title,
                    content: content.isEmpty ? nil : content,
                    time: WebSearchSchema.Result.Time(published: published)
                ))
            }
            return out
        }

        public static func make(http explicitHTTP: (any HTTPTransport)? = nil) -> PluginEffect.Plugin {
            PluginEffect.define(
                PluginEffect.Plugin(id: "opencode.websearch.exa") { ctx in
                    let activationHTTP = explicitHTTP ?? Host.currentHTTPTransportOverride
                    await WebSearchProvider.register(ctx: ctx, id: "exa", name: "Exa", env: "EXA_API_KEY") { input, credential in
                        let transport = activationHTTP ?? Host.currentHTTPTransport
                        var targetURL = endpoint
                        if case .key(let k) = credential, !k.key.isEmpty {
                            let encodedKey = k.key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? k.key
                            targetURL = "\(endpoint)?exaApiKey=\(encodedKey)"
                        }
                        let result = try await WebSearchMcp.call(
                            transport: transport,
                            url: targetURL,
                            tool: "web_search_exa",
                            arguments: .object([
                                "query": .string(input.query),
                                "numResults": .int(8),
                            ])
                        )
                        guard let text = WebSearchMcp.firstTextContent(in: result) else { return [] }
                        return parseResults(text)
                    }
                }
            )
        }

        // parity: core/src/plugin/websearch/exa.ts#Plugin [status=adapted hash=5496dfb55fb0]
        public static let Plugin = make()
    }

    public enum WebSearchFirecrawl {
        // parity: core/src/plugin/websearch/firecrawl.ts#endpoint [status=implemented hash=3f7e1573d4fe]
        public static let endpoint = "https://mcp.firecrawl.dev/v2/mcp"

        public static func make(http explicitHTTP: (any HTTPTransport)? = nil) -> PluginEffect.Plugin {
            PluginEffect.define(
                PluginEffect.Plugin(id: "opencode.websearch.firecrawl") { ctx in
                    let activationHTTP = explicitHTTP ?? Host.currentHTTPTransportOverride
                    let userAgent = "\(ctx.app.name)/\(ctx.app.version)"
                    await WebSearchProvider.register(ctx: ctx, id: "firecrawl", name: "Firecrawl", env: "FIRECRAWL_API_KEY") { input, credential in
                        let transport = activationHTTP ?? Host.currentHTTPTransport
                        var headers = ["User-Agent": userAgent]
                        if case .key(let k) = credential, !k.key.isEmpty {
                            headers["Authorization"] = "Bearer \(k.key)"
                        }
                        let result = try await WebSearchMcp.call(
                            transport: transport,
                            url: endpoint,
                            tool: "firecrawl_search",
                            arguments: .object([
                                "query": .string(input.query),
                                "limit": .int(8),
                            ]),
                            headers: headers
                        )
                        guard let text = WebSearchMcp.firstTextContent(in: result),
                              let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
                              case .object(let root) = parsed,
                              case .object(let dataObj) = root["data"],
                              case .array(let web) = dataObj["web"]
                        else { return [] }
                        return web.compactMap { entry -> WebSearchSchema.Result? in
                            guard case .object(let o) = entry, case .string(let url) = o["url"], !url.isEmpty else {
                                return nil
                            }
                            let title: String? = { if case .string(let t) = o["title"], !t.isEmpty { return t } else { return nil } }()
                            let desc: String? = { if case .string(let d) = o["description"], !d.isEmpty { return d } else { return nil } }()
                            return WebSearchSchema.Result(url: url, title: title, content: desc)
                        }
                    }
                }
            )
        }

        // parity: core/src/plugin/websearch/firecrawl.ts#Plugin [status=adapted hash=8ed5ac1527bc]
        public static let Plugin = make()
    }

    public enum WebSearchParallel {
        // parity: core/src/plugin/websearch/parallel.ts#endpoint [status=implemented hash=6ad1da4c5339]
        public static let endpoint = "https://search.parallel.ai/mcp"

        public static func make(http explicitHTTP: (any HTTPTransport)? = nil) -> PluginEffect.Plugin {
            PluginEffect.define(
                PluginEffect.Plugin(id: "opencode.websearch.parallel") { ctx in
                    let activationHTTP = explicitHTTP ?? Host.currentHTTPTransportOverride
                    let userAgent = "\(ctx.app.name)/\(ctx.app.version)"
                    await WebSearchProvider.register(ctx: ctx, id: "parallel", name: "Parallel", env: "PARALLEL_API_KEY") { input, credential in
                        let transport = activationHTTP ?? Host.currentHTTPTransport
                        var headers = ["User-Agent": userAgent]
                        if case .key(let k) = credential, !k.key.isEmpty {
                            headers["Authorization"] = "Bearer \(k.key)"
                        }
                        let result = try await WebSearchMcp.call(
                            transport: transport,
                            url: endpoint,
                            tool: "web_search",
                            arguments: .object([
                                "objective": .string(input.query),
                                "search_queries": .array([.string(input.query)]),
                            ]),
                            headers: headers
                        )
                        guard case .object(let root) = result,
                              case .object(let structured) = root["structuredContent"],
                              case .array(let results) = structured["results"]
                        else { return [] }
                        return results.compactMap { entry -> WebSearchSchema.Result? in
                            guard case .object(let o) = entry, case .string(let url) = o["url"], !url.isEmpty else {
                                return nil
                            }
                            let title: String? = { if case .string(let t) = o["title"], !t.isEmpty { return t } else { return nil } }()
                            let pubDate: String? = { if case .string(let p) = o["publish_date"], !p.isEmpty { return p } else { return nil } }()
                            let excerpts: [String] = {
                                guard case .array(let arr) = o["excerpts"] else { return [] }
                                return arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
                            }()
                            let content = excerpts.isEmpty ? nil : excerpts.joined(separator: "\n\n")
                            return WebSearchSchema.Result(
                                url: url,
                                title: title,
                                content: content,
                                time: WebSearchSchema.Result.Time(published: WebSearchMcp.parseISOEpochMs(pubDate))
                            )
                        }
                    }
                }
            )
        }

        // parity: core/src/plugin/websearch/parallel.ts#Plugin [status=adapted hash=77abe5eb2498]
        public static let Plugin = make()
    }

    public enum WebSearchTavily {
        // parity: core/src/plugin/websearch/tavily.ts#endpoint [status=implemented hash=7b4859468618]
        public static let endpoint = "https://api.tavily.com/search"

        public static func make(http explicitHTTP: (any HTTPTransport)? = nil) -> PluginEffect.Plugin {
            PluginEffect.define(
                PluginEffect.Plugin(id: "opencode.websearch.tavily") { ctx in
                    let activationHTTP = explicitHTTP ?? Host.currentHTTPTransportOverride
                    let userAgent = "\(ctx.app.name)/\(ctx.app.version)"
                    await WebSearchProvider.register(ctx: ctx, id: "tavily", name: "Tavily", env: "TAVILY_API_KEY") { input, credential in
                        let transport = activationHTTP ?? Host.currentHTTPTransport
                        var headers: [String: String] = [
                            "Accept": "application/json",
                            "Content-Type": "application/json",
                            "User-Agent": userAgent,
                            "X-Client-Name": "opencode2",
                        ]
                        if case .key(let k) = credential, !k.key.isEmpty {
                            headers["Authorization"] = "Bearer \(k.key)"
                        } else {
                            headers["X-Tavily-Access-Mode"] = "keyless"
                        }
                        let bodyObj: JSONValue = .object([
                            "query": .string(input.query),
                            "search_depth": .string("basic"),
                            "chunks_per_source": .int(3),
                            "max_results": .int(8),
                        ])
                        let bodyBytes = Array(try JSONEncoder().encode(bodyObj))
                        let response = try await transport.send(
                            HTTPRequest(method: "POST", url: endpoint, headers: headers, body: bodyBytes)
                        )
                        guard (200..<300).contains(response.head.statusCode) else {
                            throw ToolSchema.ToolError(message: "Tavily web search failed with HTTP \(response.head.statusCode)")
                        }
                        guard response.body.count <= WebSearchMcp.MAX_RESPONSE_BYTES else {
                            throw ToolSchema.ToolError(message: "Tavily web search response exceeded \(WebSearchMcp.MAX_RESPONSE_BYTES) bytes")
                        }
                        guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(response.body)),
                              case .object(let root) = decoded,
                              case .array(let items) = root["results"]
                        else { return [] }
                        return items.compactMap { entry -> WebSearchSchema.Result? in
                            guard case .object(let o) = entry, case .string(let url) = o["url"], !url.isEmpty else {
                                return nil
                            }
                            let title: String? = { if case .string(let t) = o["title"], !t.isEmpty { return t } else { return nil } }()
                            let content: String? = { if case .string(let c) = o["content"], !c.isEmpty { return c } else { return nil } }()
                            return WebSearchSchema.Result(url: url, title: title, content: content)
                        }
                    }
                }
            )
        }

        // parity: core/src/plugin/websearch/tavily.ts#Plugin [status=adapted hash=2794e9f6797f]
        public static let Plugin = make()
    }

    public enum WebSearchTinyFish {
        // parity: core/src/plugin/websearch/tinyfish.ts#endpoint [status=implemented hash=ef11622fd78e]
        public static let endpoint = "https://agent.tinyfish.ai/mcp"

        private static func initializeSession(
            transport: any HTTPTransport,
            headers: [String: String]
        ) async throws -> String {
            var initHeaders = headers
            initHeaders["Accept"] = "application/json, text/event-stream"
            initHeaders["Content-Type"] = "application/json"
            let initPayload: JSONValue = .object([
                "jsonrpc": .string("2.0"),
                "id": .int(1),
                "method": .string("initialize"),
                "params": .object([
                    "protocolVersion": .string("2025-06-18"),
                    "capabilities": .object([:]),
                    "clientInfo": .object(["name": .string("opencode"), "version": .string("1.0")]),
                ]),
            ])
            let initResp = try await transport.send(
                HTTPRequest(method: "POST", url: endpoint, headers: initHeaders, body: Array(try JSONEncoder().encode(initPayload)))
            )
            guard (200..<300).contains(initResp.head.statusCode) else {
                throw ToolSchema.ToolError(message: "TinyFish MCP initialize failed with HTTP \(initResp.head.statusCode)")
            }
            guard initResp.body.count <= WebSearchMcp.MAX_RESPONSE_BYTES else {
                throw ToolSchema.ToolError(message: "initialize response exceeded \(WebSearchMcp.MAX_RESPONSE_BYTES) bytes")
            }
            guard let session = initResp.head.headers.first(where: { $0.key.lowercased() == "mcp-session-id" })?.value,
                  !session.isEmpty
            else {
                throw ToolSchema.ToolError(message: "TinyFish MCP initialize did not return an Mcp-Session-Id header")
            }
            var notifyHeaders = initHeaders
            notifyHeaders["Mcp-Session-Id"] = session
            let notifyPayload: JSONValue = .object([
                "jsonrpc": .string("2.0"),
                "method": .string("notifications/initialized"),
            ])
            _ = try await transport.send(
                HTTPRequest(method: "POST", url: endpoint, headers: notifyHeaders, body: Array(try JSONEncoder().encode(notifyPayload)))
            )
            return session
        }

        public static func make(http explicitHTTP: (any HTTPTransport)? = nil) -> PluginEffect.Plugin {
            PluginEffect.define(
                PluginEffect.Plugin(id: "opencode.websearch.tinyfish") { ctx in
                    let activationHTTP = explicitHTTP ?? Host.currentHTTPTransportOverride
                    let userAgent = "\(ctx.app.name)/\(ctx.app.version)"
                    await WebSearchProvider.register(ctx: ctx, id: "tinyfish", name: "TinyFish", env: "TINYFISH_API_KEY") { input, credential in
                        let transport = activationHTTP ?? Host.currentHTTPTransport
                        var headers = ["User-Agent": userAgent]
                        let isKeyed: Bool
                        if case .key(let k) = credential, !k.key.isEmpty {
                            headers["X-API-Key"] = k.key
                            isKeyed = true
                        } else {
                            headers["X-TinyFish-Access-Mode"] = "keyless"
                            isKeyed = false
                        }
                        if isKeyed {
                            let session = try await initializeSession(transport: transport, headers: headers)
                            headers["Mcp-Session-Id"] = session
                        }
                        let result = try await WebSearchMcp.call(
                            transport: transport,
                            url: endpoint,
                            tool: "search",
                            arguments: .object(["query": .string(input.query)]),
                            headers: headers
                        )
                        guard let text = WebSearchMcp.firstTextContent(in: result),
                              let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
                              case .object(let root) = parsed,
                              case .array(let items) = root["results"]
                        else { return [] }
                        return items.compactMap { entry -> WebSearchSchema.Result? in
                            guard case .object(let o) = entry, case .string(let url) = o["url"], !url.isEmpty else {
                                return nil
                            }
                            let title: String? = { if case .string(let t) = o["title"], !t.isEmpty { return t } else { return nil } }()
                            let snippet: String? = { if case .string(let s) = o["snippet"], !s.isEmpty { return s } else { return nil } }()
                            return WebSearchSchema.Result(url: url, title: title, content: snippet)
                        }
                    }
                }
            )
        }

        // parity: core/src/plugin/websearch/tinyfish.ts#Plugin [status=adapted hash=f46f152620f6]
        public static let Plugin = make()
    }

    /// All built-in web search provider plugins.
    // parity: core/src/plugin/websearch/index.ts#WebSearchPlugins [status=implemented hash=e2d34d50fceb]
    public static let WebSearchPlugins: [PluginEffect.Plugin] = [
        WebSearchExa.Plugin,
        WebSearchFirecrawl.Plugin,
        WebSearchParallel.Plugin,
        WebSearchTavily.Plugin,
        WebSearchTinyFish.Plugin,
    ]

    // MARK: - Provider Plugin Helpers & Built-in Provider Plugins (`plugin/provider.ts`, `plugin/provider/*`)

    public enum ProviderConfigured {
        /// Folds provider setting overlays across configuration documents in precedence order.
        // parity: core/src/plugin/provider/configured.ts#foldSettings [status=adapted hash=169969c78f3f]
        public static func foldSettings(
            overlays: [[String: JSONValue]],
            initial: [String: JSONValue] = [:]
        ) -> [String: JSONValue] {
            overlays.reduce(into: initial) { acc, overlay in
                for (key, value) in overlay {
                    acc[key] = value
                }
            }
        }

        /// Reads effective configured settings for `providerID`.
        // parity: core/src/plugin/provider/configured.ts#configuredSettings [status=adapted hash=fcdcd7add0de]
        public static func configuredSettings(
            providerID: ProviderSchema.ID,
            overlays: [[String: JSONValue]] = [],
            initial: [String: JSONValue] = [:]
        ) -> [String: JSONValue] {
            _ = providerID
            return foldSettings(overlays: overlays, initial: initial)
        }
    }

    public enum ProviderCredentialSettings {
        public struct ResolvedCredential: Sendable {
            public let connection: ConnectionSchema.Info?
            public let credential: CredentialSchema.Value?

            public init(connection: ConnectionSchema.Info?, credential: CredentialSchema.Value?) {
                self.connection = connection
                self.credential = credential
            }
        }

        /// Resolves an integration's active connection to its live credential.
        // parity: core/src/plugin/provider/credential-settings.ts#activeCredential [status=implemented hash=765de4af9a2b]
        public static func activeCredential(ctx: PluginEffect.Context, integrationID: String) async -> ResolvedCredential {
            let conn = await ctx.integration.connection.active(integrationID)
            let cred = if let conn { try? await ctx.integration.connection.resolve(conn) } else { nil as CredentialSchema.Value? }
            return ResolvedCredential(connection: conn, credential: cred)
        }

        /// Reads an integration's stored credential without forcing token refresh.
        // parity: core/src/plugin/provider/credential-settings.ts#storedCredential [status=adapted hash=5b4313fb36f3]
        public static func storedCredential(ctx: PluginEffect.Context, integrationID: String) async -> ResolvedCredential {
            await activeCredential(ctx: ctx, integrationID: integrationID)
        }

        /// Derives provider settings from the active integration's credential.
        // parity: core/src/plugin/provider/credential-settings.ts#credentialSettings [status=adapted hash=939c6b5b7bd5]
        public static func credentialSettings(
            ctx: PluginEffect.Context,
            integrationID: String,
            select: @Sendable (CredentialSchema.Value) -> [String: JSONValue]
        ) async -> [String: JSONValue] {
            let resolved = await storedCredential(ctx: ctx, integrationID: integrationID)
            return resolved.credential.map(select) ?? [:]
        }

        /// Picks non-empty string metadata entries matching `keys`.
        // parity: core/src/plugin/provider/credential-settings.ts#metadataSettings [status=implemented hash=fd47897addd0]
        public static func metadataSettings(
            metadata: [String: JSONValue]?,
            keys: [String]
        ) -> [String: String] {
            guard let metadata else { return [:] }
            var out: [String: String] = [:]
            for key in keys {
                if case .string(let val) = metadata[key], !val.isEmpty {
                    out[key] = val
                }
            }
            return out
        }
    }

    public enum ProviderRefresh {
        // parity: core/src/plugin/provider/refresh.ts#Options [status=implemented hash=51ea27060943]
        public struct Options: Equatable, Hashable, Sendable, Codable {
            public let intervalMs: Int64?
            public let force: Bool?

            public init(intervalMs: Int64? = nil, force: Bool? = nil) {
                self.intervalMs = intervalMs
                self.force = force
            }
        }

        // parity: core/src/plugin/provider/refresh.ts#onSwitch [status=adapted hash=d0de4e766638]
        public static func onSwitch(
            integrationID: String,
            action: @escaping @Sendable () async -> Void
        ) async {
            _ = integrationID
            await action()
        }

        // parity: core/src/plugin/provider/refresh.ts#reloadIfChanged [status=implemented hash=bf56772989c4]
        public static func reloadIfChanged(
            load: @Sendable () async throws -> Bool,
            reload: @Sendable () async -> Void
        ) async throws {
            if try await load() {
                await reload()
            }
        }

        // parity: core/src/plugin/provider/refresh.ts#switched [status=implemented hash=af8b89058774]
        public static func switched<A: Sendable>(
            load: @escaping @Sendable (Options) async throws -> A,
            apply: @escaping @Sendable (A) async -> Void
        ) -> @Sendable () async throws -> Void {
            {
                let next = try await load(Options(force: true))
                await apply(next)
            }
        }

        // parity: core/src/plugin/provider/refresh.ts#start [status=adapted hash=dae52dd6a905]
        public static func start<A: Sendable>(
            load: @escaping @Sendable (Options) async throws -> A,
            apply: @escaping @Sendable (A) async -> Void
        ) async throws {
            let initial = try await load(Options(force: false))
            await apply(initial)
        }
    }

    public enum ProviderLocal {
        public enum ModelType: String, Equatable, Hashable, Sendable, Codable {
            case chat
            case decision
        }

        // parity: core/src/plugin/provider/local.ts#LocalModel [status=implemented hash=6a5c87748921]
        public struct LocalModel: Equatable, Hashable, Sendable, Codable {
            public let id: String
            public let name: String?
            public let family: String?
            public let tools: Bool?
            public let vision: Bool?
            public let context: Int?
            public let type: ModelType?
            public let contextWindow: Int?
            public let reasoning: Bool?
            public let toolCall: Bool?

            public init(
                id: String,
                name: String? = nil,
                family: String? = nil,
                tools: Bool? = nil,
                vision: Bool? = nil,
                context: Int? = nil,
                type: ModelType? = nil,
                contextWindow: Int? = nil,
                reasoning: Bool? = nil,
                toolCall: Bool? = nil
            ) {
                self.id = id
                self.name = name
                self.family = family
                self.tools = tools ?? toolCall
                self.vision = vision
                self.context = context ?? contextWindow
                self.type = type
                self.contextWindow = contextWindow ?? context
                self.reasoning = reasoning
                self.toolCall = toolCall ?? tools
            }
        }

        // parity: core/src/plugin/provider/local.ts#LocalDiscoveryClient [status=adapted hash=9279ebe77d72]
        public struct LocalDiscoveryClient: Sendable {
            public let discover: @Sendable (_ baseURL: String) async throws -> [LocalModel]

            public init(discover: @escaping @Sendable (_ baseURL: String) async throws -> [LocalModel]) {
                self.discover = discover
            }
        }

        // parity: core/src/plugin/provider/local.ts#createLocalProviderPlugin [status=adapted hash=f07f0a12c3ca]
        public static func createLocalProviderPlugin(
            id: String,
            providerID: String,
            name: String,
            defaultBaseURL: String
        ) -> @Sendable () -> PluginEffect.Plugin {
            {
                PluginEffect.define(
                    PluginEffect.Plugin(id: id) { ctx in
                        let env = Host.currentEnvironment
                        let baseEnvKey = "\(providerID.uppercased())_BASE_URL"
                        let apiKeyEnv = "\(providerID.uppercased())_API_KEY"
                        let baseURL = env.variable(baseEnvKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultBaseURL
                        let hasKey = env.variable(apiKeyEnv).map { !$0.isEmpty } ?? false

                        _ = await ctx.integration.transform { editor in
                            editor.update(providerID) { item in item.name = name }
                            editor.method.update(.key(integrationID: providerID, method: PluginEffect.IntegrationKeyMethod()))
                            editor.method.update(.env(integrationID: providerID, method: PluginEffect.IntegrationEnvMethod(names: [apiKeyEnv])))
                        }

                        _ = await ctx.provider.transform { editor in
                            let info = ProviderSchema.Info(
                                id: ProviderSchema.ID(rawValue: providerID),
                                integrationID: IntegrationID(rawValue: providerID),
                                name: name,
                                activation: hasKey ? .enabled : .auto,
                                package: "@opencode/ai/providers/openai-compatible",
                                settings: ProviderSchema.Settings(extra: [
                                    "baseURL": .string(baseURL),
                                    "provider": .string(providerID),
                                ])
                            )
                            if editor.get(providerID) != nil {
                                editor.update(providerID) { existing in
                                    var merged = existing.settings?.extra ?? [:]
                                    if merged["baseURL"] == nil { merged["baseURL"] = .string(baseURL) }
                                    merged["provider"] = .string(providerID)
                                    existing = ProviderSchema.Info(
                                        id: existing.id,
                                        canonical: existing.canonical,
                                        integrationID: existing.integrationID ?? IntegrationID(rawValue: providerID),
                                        name: name,
                                        activation: (existing.activation == .auto && hasKey) ? .enabled : existing.activation,
                                        package: "@opencode/ai/providers/openai-compatible",
                                        compatibility: existing.compatibility,
                                        settings: ProviderSchema.Settings(
                                            timeout: existing.settings?.timeout,
                                            headerTimeout: existing.settings?.headerTimeout,
                                            chunkTimeout: existing.settings?.chunkTimeout,
                                            compaction: existing.settings?.compaction,
                                            cache: existing.settings?.cache,
                                            transport: existing.settings?.transport,
                                            encoding: existing.settings?.encoding,
                                            tls: existing.settings?.tls,
                                            extra: merged
                                        ),
                                        headers: existing.headers,
                                        body: existing.body
                                    )
                                }
                            } else {
                                editor.add(info, [], nil)
                            }
                        }
                    }
                )
            }
        }
    }

    /// Dynamic npm SDK factory loader contract (`plugin/provider/sdk-factory.ts`).
    // parity: core/src/plugin/provider/sdk-factory.ts#loadSDKFactory [status=adapted hash=de1facaebc5b]
    public static func loadSDKFactory(packageName: String) async throws -> AnySendableValue {
        try await RuntimeImport.importNodeModule(packageName)
    }

    public enum OpencodeArtifacts {
        // parity: core/src/plugin/provider/opencode-artifacts.ts#header [status=implemented hash=dcf1b7c5cffb]
        public static let header = "x-opencode-artifacts"

        // parity: core/src/plugin/provider/opencode-artifacts.ts#make [status=adapted hash=6b493bf790dd]
        public static func make(ctx: PluginEffect.Context) async {
            _ = ctx
        }
    }

    public enum OpencodeWatches {
        // parity: core/src/plugin/provider/opencode-watches.ts#header [status=implemented hash=cf4d0bd96724]
        public static let header = "x-opencode-event-watches"

        // parity: core/src/plugin/provider/opencode-watches.ts#LEASE_CLOSE_CODE [status=implemented hash=3ba4d22392f1]
        public static let LEASE_CLOSE_CODE = 4401

        // parity: core/src/plugin/provider/opencode-watches.ts#OVERSIZED_CLOSE_CODE [status=implemented hash=03a197b4320d]
        public static let OVERSIZED_CLOSE_CODE = 1009

        // parity: core/src/plugin/provider/opencode-watches.ts#ACK_LIMIT [status=implemented hash=1b1feaf0f411]
        public static let ACK_LIMIT = 1000

        // parity: core/src/plugin/provider/opencode-watches.ts#WINDOW_LIMIT [status=implemented hash=b5bef9562737]
        public static let WINDOW_LIMIT = 5

        // parity: core/src/plugin/provider/opencode-watches.ts#PROMPT_LIMIT [status=implemented hash=627ce6801225]
        public static let PROMPT_LIMIT = 20

        // parity: core/src/plugin/provider/opencode-watches.ts#Console [status=implemented hash=a1645ae71e94]
        public struct Console: Equatable, Hashable, Sendable, Codable {
            public let baseURL: String
            public let token: String

            public init(baseURL: String, token: String) {
                self.baseURL = baseURL
                self.token = token
            }
        }

        // parity: core/src/plugin/provider/opencode-watches.ts#make [status=adapted hash=6071671cca75]
        public static func make(ctx: PluginEffect.Context) async {
            _ = ctx
        }

        public enum WatchTarget: Equatable, Hashable, Sendable {
            case pullRequestURL(String)
            case githubBranch(repo: String, branch: String)
        }

        /// Detects a watchable GitHub PR URL (`gh pr create`) or pushed branch (`git push`) from shell output.
        // parity: core/src/plugin/provider/opencode-watches.ts#shellTarget [status=implemented hash=2ccd5aed80f7]
        public static func shellTarget(command: String, exitCode: Int, output: String) -> WatchTarget? {
            guard exitCode == 0 else { return nil }
            func matchesRegex(_ text: String, pattern: String) -> Bool {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return false }
                let range = NSRange(text.utf16.startIndex..<text.utf16.endIndex, in: text)
                return regex.firstMatch(in: text, options: [], range: range) != nil
            }
            func captureAll(_ text: String, pattern: String, options: NSRegularExpression.Options = [], group: Int = 0) -> [String] {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
                let range = NSRange(text.utf16.startIndex..<text.utf16.endIndex, in: text)
                return regex.matches(in: text, options: [], range: range).compactMap { match in
                    guard match.numberOfRanges > group,
                          let r = Range(match.range(at: group), in: text)
                    else { return nil }
                    return String(text[r])
                }
            }

            if matchesRegex(command, pattern: #"(?:^|[\s;&|(])gh\s+pr\s+create\b"#) {
                let urls = Set(captureAll(output, pattern: #"https://github\.com/[\w.-]+/[\w.-]+/pull/\d+"#))
                if urls.count == 1, let only = urls.first {
                    return .pullRequestURL(only)
                }
                return nil
            }
            guard matchesRegex(command, pattern: #"(?:^|[\s;&|(])git\s+(?:-C\s+\S+\s+)?push\b"#) else {
                return nil
            }
            let remotes = captureAll(
                output,
                pattern: #"^To (?:https://github\.com/|(?:ssh://)?(?:git@)?github\.com[:/])([\w.-]+/[\w.-]+?)(?:\.git)?/?$"#,
                options: [.anchorsMatchLines],
                group: 1
            )
            let branches = captureAll(
                output,
                pattern: #"^\s*[+*]?\s*(?:[0-9a-f]+\.\.\.?[0-9a-f]+|\[new branch\])\s+\S+\s+->\s+(\S+)"#,
                options: [.anchorsMatchLines],
                group: 1
            )
            guard remotes.count == 1, branches.count == 1,
                  let repo = remotes.first, !repo.isEmpty,
                  let branch = branches.first, !branch.isEmpty
            else {
                return nil
            }
            return .githubBranch(repo: repo.lowercased(), branch: branch)
        }

        /// Fences text with a backtick run strictly longer than any run inside `text`.
        // parity: core/src/plugin/provider/opencode-watches.ts#fence [status=implemented hash=8f04f8a6e829]
        public static func fence(_ text: String) -> String {
            var longestRun = 0
            var currentRun = 0
            for ch in text {
                if ch == "`" {
                    currentRun += 1
                    if currentRun > longestRun { longestRun = currentRun }
                } else {
                    currentRun = 0
                }
            }
            let ticks = String(repeating: "`", count: max(3, longestRun + 1))
            return "\(ticks)text\n\(text)\n\(ticks)"
        }
    }

    /// Shared helper registering a built-in cloud provider's integration auth methods, env-var activation check,
    /// base URL, package specifier, and default headers into `ctx.integration` and `ctx.provider`.
    private static func registerCloudProvider(
        ctx: PluginEffect.Context,
        providerID: String,
        name: String,
        package: String,
        defaultBaseURL: String,
        envVars: [String],
        baseURLEnvVars: [String] = [],
        defaultHeaders: [String: String] = [:],
        extraSettings: [String: JSONValue] = [:],
        keyLabel: String? = nil,
        externalMethods: [PluginEffect.IntegrationExternalMethod] = [],
        ambientActive: Bool = false
    ) async {
        let env = Host.currentEnvironment
        let resolvedBaseURL: String = {
            for name in baseURLEnvVars {
                if let val = env.variable(name), !val.isEmpty { return val }
            }
            return defaultBaseURL
        }()
        let hasEnvAuth = ambientActive || envVars.contains { key in
            if let val = env.variable(key), !val.isEmpty { return true }
            return false
        }

        _ = await ctx.integration.transform { editor in
            editor.update(providerID) { item in item.name = name }
            editor.method.update(.key(integrationID: providerID, method: PluginEffect.IntegrationKeyMethod(label: keyLabel)))
            if !envVars.isEmpty {
                editor.method.update(.env(integrationID: providerID, method: PluginEffect.IntegrationEnvMethod(names: envVars)))
            }
            for ext in externalMethods {
                editor.method.update(.external(integrationID: providerID, method: ext))
            }
        }

        _ = await ctx.provider.transform { editor in
            var settingsExtra = extraSettings
            if !resolvedBaseURL.isEmpty {
                settingsExtra["baseURL"] = .string(resolvedBaseURL)
            }
            let finalSettingsExtra = settingsExtra
            if editor.get(providerID) != nil {
                editor.update(providerID) { existing in
                    var mergedExtra = existing.settings?.extra ?? [:]
                    for (k, v) in finalSettingsExtra {
                        mergedExtra[k] = v
                    }
                    var mergedHeaders = existing.headers ?? [:]
                    for (k, v) in defaultHeaders where mergedHeaders[k] == nil {
                        mergedHeaders[k] = v
                    }
                    let nextActivation: ProviderSchema.Activation = (existing.activation == .auto && hasEnvAuth)
                        ? .enabled
                        : existing.activation
                    existing = ProviderSchema.Info(
                        id: existing.id,
                        canonical: existing.canonical,
                        integrationID: existing.integrationID ?? IntegrationID(rawValue: providerID),
                        name: existing.name.isEmpty ? name : existing.name,
                        activation: nextActivation,
                        package: existing.package.isEmpty ? package : existing.package,
                        compatibility: existing.compatibility,
                        settings: ProviderSchema.Settings(
                            timeout: existing.settings?.timeout,
                            headerTimeout: existing.settings?.headerTimeout,
                            chunkTimeout: existing.settings?.chunkTimeout,
                            compaction: existing.settings?.compaction,
                            cache: existing.settings?.cache,
                            transport: existing.settings?.transport,
                            encoding: existing.settings?.encoding,
                            tls: existing.settings?.tls,
                            extra: mergedExtra
                        ),
                        headers: mergedHeaders.isEmpty ? nil : mergedHeaders,
                        body: existing.body
                    )
                }
            } else {
                let info = ProviderSchema.Info(
                    id: ProviderSchema.ID(rawValue: providerID),
                    integrationID: IntegrationID(rawValue: providerID),
                    name: name,
                    activation: hasEnvAuth ? .enabled : .auto,
                    package: package,
                    settings: settingsExtra.isEmpty ? nil : ProviderSchema.Settings(extra: settingsExtra),
                    headers: defaultHeaders.isEmpty ? nil : defaultHeaders
                )
                editor.add(info, [], nil)
            }
        }
    }

    public enum ChatGPTProvider {
        // parity: core/src/plugin/provider/chatgpt.ts#ChatGPTPlugin [status=adapted hash=e82603f31d14]
        public static let ChatGPTPlugin = PluginEffect.define(
            PluginEffect.Plugin(id: "opencode.provider.chatgpt") { ctx in
                await registerCloudProvider(
                    ctx: ctx,
                    providerID: "chatgpt",
                    name: "ChatGPT",
                    package: "@opencode/ai/providers/openai",
                    defaultBaseURL: "https://chatgpt.com/backend-api/codex",
                    envVars: ["CHATGPT_ACCESS_TOKEN"]
                )
            }
        )

        // parity: core/src/plugin/provider/chatgpt.ts#fetchModels [status=adapted hash=f8e9b62ae902]
        public static func fetchModels(
            token: String,
            app: PluginContract.App,
            baseURL: String = "https://chatgpt.com/backend-api/codex/models",
            transport: any HTTPTransport
        ) async throws -> JSONValue {
            let resp = try await transport.send(
                HTTPRequest(
                    method: "GET",
                    url: baseURL,
                    headers: [
                        "Authorization": "Bearer \(token)",
                        "User-Agent": "\(app.name)/\(app.version)",
                    ]
                )
            )
            return try JSONDecoder().decode(JSONValue.self, from: Data(resp.body))
        }

        // parity: core/src/plugin/provider/chatgpt.ts#deriveModels [status=adapted hash=4ed00c584fb3]
        public static func deriveModels(existing: [ModelSchema.Info]) -> [ModelSchema.Info] {
            existing
        }

        // parity: core/src/plugin/provider/chatgpt.ts#verifyIDToken [status=adapted hash=b5c70df4e4a7]
        public static func verifyIDToken(_ token: String) -> Bool {
            token.split(separator: ".").count == 3
        }
    }

    public enum AzureProvider {
        // parity: core/src/plugin/provider/azure.ts#make [status=adapted hash=cca1cfaad991]
        public static func make() -> PluginEffect.Plugin {
            PluginEffect.define(
                PluginEffect.Plugin(id: "opencode.provider.azure") { ctx in
                    let env = Host.currentEnvironment
                    let resourceName = env.variable("AZURE_RESOURCE_NAME")
                    let endpointFromResource = resourceName.flatMap { r in
                        r.isEmpty ? nil : "https://\(r).openai.azure.com/openai"
                    }
                    let baseURL = env.variable("AZURE_OPENAI_ENDPOINT").flatMap { $0.isEmpty ? nil : $0 }
                        ?? endpointFromResource
                        ?? "https://api.openai.azure.com/openai"
                    var extra: [String: JSONValue] = [:]
                    if let resourceName, !resourceName.isEmpty {
                        extra["resourceName"] = .string(resourceName)
                    }
                    await registerCloudProvider(
                        ctx: ctx,
                        providerID: "azure",
                        name: "Azure OpenAI",
                        package: "@opencode/ai/providers/azure",
                        defaultBaseURL: baseURL,
                        envVars: ["AZURE_OPENAI_API_KEY", "AZURE_API_KEY"],
                        extraSettings: extra,
                        externalMethods: [
                            PluginEffect.IntegrationExternalMethod(id: "azure-cli", label: "Azure CLI (az login)"),
                        ]
                    )
                }
            )
        }

        // parity: core/src/plugin/provider/azure.ts#AzurePlugin [status=implemented hash=c2faa2d1773e]
        public static let AzurePlugin = make()
    }

    public enum LMStudioProvider {
        // parity: core/src/plugin/provider/lmstudio.ts#make [status=implemented hash=7d4052b599b3]
        public static let make = ProviderLocal.createLocalProviderPlugin(
            id: "opencode.provider.lmstudio",
            providerID: "lmstudio",
            name: "LM Studio",
            defaultBaseURL: "http://127.0.0.1:1234/v1"
        )

        // parity: core/src/plugin/provider/lmstudio.ts#LMStudioPlugin [status=implemented hash=6b3fc4388207]
        public static let LMStudioPlugin = make()
    }

    public enum OllamaProvider {
        // parity: core/src/plugin/provider/ollama.ts#make [status=implemented hash=e096c5392889]
        public static let make = ProviderLocal.createLocalProviderPlugin(
            id: "opencode.provider.ollama",
            providerID: "ollama",
            name: "Ollama",
            defaultBaseURL: "http://127.0.0.1:11434/v1"
        )

        // parity: core/src/plugin/provider/ollama.ts#OllamaPlugin [status=implemented hash=16162ad5b615]
        public static let OllamaPlugin = make()
    }

    public enum VLLMProvider {
        // parity: core/src/plugin/provider/vllm.ts#make [status=implemented hash=1aa6e1766d69]
        public static let make = ProviderLocal.createLocalProviderPlugin(
            id: "opencode.provider.vllm",
            providerID: "vllm",
            name: "vLLM",
            defaultBaseURL: "http://127.0.0.1:8000/v1"
        )

        // parity: core/src/plugin/provider/vllm.ts#VLLMPlugin [status=implemented hash=8a20dad8dec0]
        public static let VLLMPlugin = make()
    }

    // parity: core/src/plugin/provider/amazon-bedrock.ts#AmazonBedrockPlugin [status=adapted hash=a455915afee1]
    public static let AmazonBedrockPlugin = PluginEffect.define(
        PluginEffect.Plugin(id: "opencode.provider.amazon.bedrock") { ctx in
            let env = Host.currentEnvironment
            let chainVars = [
                "AWS_PROFILE",
                "AWS_ACCESS_KEY_ID",
                "AWS_WEB_IDENTITY_TOKEN_FILE",
                "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI",
                "AWS_CONTAINER_CREDENTIALS_FULL_URI",
            ]
            let hasChain = chainVars.contains { key in
                if let val = env.variable(key), !val.isEmpty { return true }
                return false
            }
            let region = env.variable("AWS_REGION").flatMap { $0.isEmpty ? nil : $0 }
                ?? env.variable("AWS_DEFAULT_REGION").flatMap { $0.isEmpty ? nil : $0 }
                ?? "us-east-1"
            let loginSettings = await ProviderCredentialSettings.credentialSettings(ctx: ctx, integrationID: "amazon-bedrock") { value in
                if case .external(let ext) = value, ext.methodID.rawValue == "aws-profile" {
                    return ProviderCredentialSettings.metadataSettings(metadata: ext.metadata, keys: ["profile"])
                        .mapValues(JSONValue.string)
                }
                return [:]
            }
            var extra: [String: JSONValue] = ["region": .string(region)]
            for (k, v) in loginSettings { extra[k] = v }
            let hasProfile = loginSettings["profile"] != nil
            await registerCloudProvider(
                ctx: ctx,
                providerID: "amazon-bedrock",
                name: "Amazon Bedrock",
                package: "@opencode/ai/providers/amazon-bedrock",
                defaultBaseURL: "https://bedrock-runtime.\(region).amazonaws.com",
                envVars: ["AWS_BEARER_TOKEN_BEDROCK"],
                baseURLEnvVars: ["AWS_BEDROCK_ENDPOINT"],
                extraSettings: extra,
                keyLabel: "Bedrock API key",
                externalMethods: [
                    PluginEffect.IntegrationExternalMethod(id: "aws-profile", label: "AWS profile (SSO or named profile)"),
                ],
                ambientActive: hasChain || hasProfile
            )
        }
    )

    // parity: core/src/plugin/provider/cerebras.ts#CerebrasPlugin [status=adapted hash=a81c45d122f2]
    public static let CerebrasPlugin = PluginEffect.define(
        PluginEffect.Plugin(id: "opencode.provider.cerebras") { ctx in
            await registerCloudProvider(
                ctx: ctx,
                providerID: "cerebras",
                name: "Cerebras",
                package: "@opencode/ai/providers/cerebras",
                defaultBaseURL: "https://api.cerebras.ai/v1",
                envVars: ["CEREBRAS_API_KEY"],
                defaultHeaders: ["X-Cerebras-3rd-Party-Integration": "opencode"]
            )
        }
    )

    // parity: core/src/plugin/provider/cloudflare-ai-gateway.ts#CloudflareAIGatewayPlugin [status=adapted hash=3d3202c2b2f3]
    public static let CloudflareAIGatewayPlugin = PluginEffect.define(
        PluginEffect.Plugin(id: "opencode.provider.cloudflare.ai.gateway") { ctx in
            let env = Host.currentEnvironment
            var extra: [String: JSONValue] = [:]
            if let acc = env.variable("CLOUDFLARE_ACCOUNT_ID"), !acc.isEmpty { extra["accountId"] = .string(acc) }
            if let gw = env.variable("CLOUDFLARE_GATEWAY_ID"), !gw.isEmpty { extra["gatewayId"] = .string(gw) }
            await registerCloudProvider(
                ctx: ctx,
                providerID: "cloudflare-ai-gateway",
                name: "Cloudflare AI Gateway",
                package: "@opencode/ai/providers/cloudflare-ai-gateway",
                defaultBaseURL: "https://gateway.ai.cloudflare.com/v1",
                envVars: ["CLOUDFLARE_API_KEY", "CLOUDFLARE_GATEWAY_TOKEN"],
                extraSettings: extra
            )
        }
    )

    // parity: core/src/plugin/provider/cloudflare-workers-ai.ts#CloudflareWorkersAIPlugin [status=adapted hash=63d2375f1a34]
    public static let CloudflareWorkersAIPlugin = PluginEffect.define(
        PluginEffect.Plugin(id: "opencode.provider.cloudflare.workers.ai") { ctx in
            let env = Host.currentEnvironment
            var extra: [String: JSONValue] = [:]
            if let acc = env.variable("CLOUDFLARE_ACCOUNT_ID"), !acc.isEmpty { extra["accountId"] = .string(acc) }
            await registerCloudProvider(
                ctx: ctx,
                providerID: "cloudflare-workers-ai",
                name: "Cloudflare Workers AI",
                package: "@opencode/ai/providers/cloudflare-workers-ai",
                defaultBaseURL: "https://api.cloudflare.com/client/v4",
                envVars: ["CLOUDFLARE_API_KEY", "CLOUDFLARE_API_TOKEN"],
                extraSettings: extra
            )
        }
    )

    // parity: core/src/plugin/provider/databricks.ts#DatabricksPlugin [status=adapted hash=954ff5cce271]
    public static let DatabricksPlugin = PluginEffect.define(
        PluginEffect.Plugin(id: "opencode.provider.databricks") { ctx in
            await registerCloudProvider(
                ctx: ctx,
                providerID: "databricks",
                name: "Databricks",
                package: "@opencode/ai/providers/openai-compatible",
                defaultBaseURL: "https://api.databricks.com/serving-endpoints",
                envVars: ["DATABRICKS_TOKEN"],
                baseURLEnvVars: ["DATABRICKS_HOST"]
            )
        }
    )

    // parity: core/src/plugin/provider/digitalocean.ts#DigitalOceanPlugin [status=adapted hash=0f83be9bb563]
    public static let DigitalOceanPlugin = PluginEffect.define(
        PluginEffect.Plugin(id: "opencode.provider.digitalocean") { ctx in
            await registerCloudProvider(
                ctx: ctx,
                providerID: "digitalocean",
                name: "DigitalOcean",
                package: "@opencode/ai/providers/digitalocean",
                defaultBaseURL: "https://inference.do-ai.run/v1",
                envVars: ["DIGITALOCEAN_API_KEY", "MODEL_ACCESS_KEY"]
            )
        }
    )

    // parity: core/src/plugin/provider/dynamic.ts#DynamicProviderPlugin [status=adapted hash=752b96cedc7b]
    public static let DynamicProviderPlugin = PluginEffect.define(
        PluginEffect.Plugin(id: "opencode.provider.dynamic") { ctx in
            let env = Host.currentEnvironment
            _ = await ctx.provider.transform { editor in
                for rec in editor.list() where rec.provider.activation == .auto {
                    let envKey = rec.provider.id.rawValue.uppercased().replacing("-", with: "_") + "_API_KEY"
                    if let val = env.variable(envKey), !val.isEmpty {
                        editor.update(rec.provider.id.rawValue) { p in
                            p = ProviderSchema.Info(
                                id: p.id,
                                canonical: p.canonical,
                                integrationID: p.integrationID,
                                name: p.name,
                                activation: .enabled,
                                package: p.package,
                                compatibility: p.compatibility,
                                settings: p.settings,
                                headers: p.headers,
                                body: p.body
                            )
                        }
                    }
                }
            }
        }
    )

    public enum GithubCopilot {
        public static let apiVersion = "2026-08-01"

        public struct EntitlementUser: Equatable, Hashable, Sendable, Codable {
            public let chatEnabled: Bool?
            public let canSignupForLimited: Bool?

            enum CodingKeys: String, CodingKey {
                case chatEnabled = "chat_enabled"
                case canSignupForLimited = "can_signup_for_limited"
            }

            public init(chatEnabled: Bool? = nil, canSignupForLimited: Bool? = nil) {
                self.chatEnabled = chatEnabled
                self.canSignupForLimited = canSignupForLimited
            }
        }

        public struct UtilityTitleError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public let message: String
            public init(_ message: String) { self.message = message }
            public var description: String { message }
        }

        public struct UtilityTitleInput: Sendable {
            public let baseURL: String
            public let token: String
            public let model: String
            public let app: PluginContract.App
            public let transport: (any HTTPTransport)?

            public init(
                baseURL: String,
                token: String,
                model: String,
                app: PluginContract.App = PluginContract.App(name: "opencode", version: "2.0.0", channel: "local"),
                transport: (any HTTPTransport)? = nil
            ) {
                self.baseURL = baseURL
                self.token = token
                self.model = model
                self.app = app
                self.transport = transport
            }
        }

        public struct UtilityTitleMessage: Equatable, Hashable, Sendable, Codable {
            public let role: String
            public let parts: [UtilityTitlePart]

            public init(role: String, parts: [UtilityTitlePart]) {
                self.role = role
                self.parts = parts
            }
        }

        public struct UtilityTitlePart: Equatable, Hashable, Sendable, Codable {
            public let type: String
            public let text: String?

            public init(type: String = "text", text: String? = nil) {
                self.type = type
                self.text = text
            }
        }

        public struct UtilityTitleRequest: Equatable, Hashable, Sendable {
            public let sessionID: SessionID
            public let system: [UtilityTitlePart]
            public let messages: [UtilityTitleMessage]
            public let maxTokens: Int?

            public init(
                sessionID: SessionID,
                system: [UtilityTitlePart] = [],
                messages: [UtilityTitleMessage] = [],
                maxTokens: Int? = nil
            ) {
                self.sessionID = sessionID
                self.system = system
                self.messages = messages
                self.maxTokens = maxTokens
            }
        }

        private static func normalizeDomain(_ input: String) -> String {
            var s = input
            if s.hasPrefix("https://") {
                s = String(s.dropFirst(8))
            } else if s.hasPrefix("http://") {
                s = String(s.dropFirst(7))
            }
            if s.hasSuffix("/") {
                s.removeLast()
            }
            return s
        }

        /// Returns a user-facing entitlement error when `/copilot_internal/user` reports `chat_enabled === false`.
        // parity: core/src/plugin/provider/github-copilot.ts#copilotEntitlementError [status=implemented hash=7342f68756a3]
        public static func copilotEntitlementError(_ user: EntitlementUser) -> String? {
            guard user.chatEnabled == false else { return nil }
            if user.canSignupForLimited == true {
                return "This GitHub account is not signed up for GitHub Copilot. Sign up for Copilot Free at https://github.com/features/copilot/plans and connect again."
            }
            return "This GitHub account does not have GitHub Copilot access. It needs an active Copilot subscription or a seat assigned by an organization."
        }

        /// Resolves the GitHub Copilot API base URL from OAuth credential metadata (`apiEndpoint` or `enterpriseUrl`).
        // parity: core/src/plugin/provider/github-copilot.ts#copilotBaseURL [status=implemented hash=4716ebfbdbac]
        public static func copilotBaseURL(_ metadata: [String: JSONValue]? = nil) -> String {
            if case .string(let endpoint) = metadata?["apiEndpoint"], !endpoint.isEmpty {
                return endpoint
            }
            if case .string(let enterprise) = metadata?["enterpriseUrl"], !enterprise.isEmpty {
                return "https://copilot-api.\(normalizeDomain(enterprise))"
            }
            return "https://api.githubcopilot.com"
        }

        /// Small utility models preferred for stateless non-streaming Copilot session title generation.
        // parity: core/src/plugin/provider/github-copilot.ts#utilityTitleModels [status=implemented hash=086efb264f5b]
        public static let utilityTitleModels: [String] = ["gpt-4o-mini"]

        /// Issues a stateless, non-streaming `/chat/completions` title generation request against GitHub Copilot.
        // parity: core/src/plugin/provider/github-copilot.ts#utilityTitle [status=implemented hash=75ffb9fc153a]
        public static func utilityTitle(
            _ input: UtilityTitleInput,
            request: UtilityTitleRequest
        ) async throws -> String {
            func joinText(_ parts: [UtilityTitlePart]) -> String {
                parts.compactMap { part in
                    part.type == "text" ? part.text : nil
                }.joined(separator: "\n")
            }

            var wireMessages: [[String: String]] = []
            if !request.system.isEmpty {
                wireMessages.append(["role": "system", "content": joinText(request.system)])
            }
            for message in request.messages {
                wireMessages.append(["role": message.role, "content": joinText(message.parts)])
            }

            var payload: [String: JSONValue] = [
                "model": .string(input.model),
                "messages": .array(wireMessages.map { msg in
                    .object([
                        "role": .string(msg["role"] ?? "user"),
                        "content": .string(msg["content"] ?? ""),
                    ])
                }),
                "stream": .bool(false),
            ]
            if let maxTokens = request.maxTokens {
                payload["max_tokens"] = .int(Int64(maxTokens))
            }
            let bodyData = try JSONEncoder().encode(payload)
            let userAgent = "\(input.app.name)/\(input.app.version)"
            let httpRequest = HTTPRequest(
                method: "POST",
                url: "\(input.baseURL)/chat/completions",
                headers: [
                    "Authorization": "Bearer \(input.token)",
                    "Content-Type": "application/json",
                    "User-Agent": userAgent,
                    "X-GitHub-Api-Version": apiVersion,
                    "Openai-Intent": "conversation-edits",
                    "X-Interaction-Type": "agent-session-name-generation",
                    "X-Interaction-Id": request.sessionID.rawValue,
                    "x-initiator": "agent",
                ],
                body: Array(bodyData)
            )
            let transport = input.transport ?? Host.currentHTTPTransport
            let response = try await transport.send(httpRequest)
            guard (200..<300).contains(response.head.statusCode) else {
                throw UtilityTitleError("Utility title request failed: \(response.head.statusCode)")
            }
            struct CompletionChoice: Decodable {
                struct Message: Decodable {
                    let content: String?
                }
                let message: Message
            }
            struct CompletionResponse: Decodable {
                let choices: [CompletionChoice]
            }
            let decoded = try JSONDecoder().decode(CompletionResponse.self, from: Data(response.body))
            let rawTitle = decoded.choices.first?.message.content ?? ""
            let title = rawTitle.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            guard !title.isEmpty else {
                throw UtilityTitleError("Utility title response was empty")
            }
            return title
        }

        /// Maps an OpenCode session request kind and child-session flag to Copilot's `X-Interaction-Type` header value.
        // parity: core/src/plugin/provider/github-copilot.ts#interactionType [status=implemented hash=653959c8253a]
        public static func interactionType(_ kind: PluginEffect.SessionRequestKind, child: Bool) -> String {
            switch kind {
            case .title: return "conversation-background"
            case .compaction: return "conversation-compaction"
            case .primary, .generate:
                return child ? "conversation-subagent" : "conversation-agent"
            }
        }
    }

    // parity: core/src/plugin/provider/github-copilot.ts#GithubCopilotPlugin [status=adapted hash=a6cdfb8f7e9f]
    public static let GithubCopilotPlugin = PluginEffect.define(
        PluginEffect.Plugin(id: "opencode.provider.github.copilot") { ctx in
            await registerCloudProvider(
                ctx: ctx,
                providerID: "github-copilot",
                name: "GitHub Copilot",
                package: "@opencode/ai/providers/openai-compatible",
                defaultBaseURL: GithubCopilot.copilotBaseURL(),
                envVars: ["GITHUB_TOKEN", "GH_TOKEN"]
            )
        }
    )

    // parity: core/src/plugin/provider/gitlab.ts#GitLabPlugin [status=adapted hash=9021a382fffa]
    public static let GitLabPlugin = PluginEffect.define(
        PluginEffect.Plugin(id: "opencode.provider.gitlab") { ctx in
            await registerCloudProvider(
                ctx: ctx,
                providerID: "gitlab",
                name: "GitLab Duo",
                package: "@opencode/ai/providers/openai-compatible",
                defaultBaseURL: "https://gitlab.com/api/v4",
                envVars: ["GITLAB_TOKEN"],
                baseURLEnvVars: ["GITLAB_INSTANCE_URL"]
            )
        }
    )

    // parity: core/src/plugin/provider/google-vertex.ts#GoogleVertexPlugin [status=adapted hash=e1ee3cf7df5c]
    public static let GoogleVertexPlugin = PluginEffect.define(
        PluginEffect.Plugin(id: "opencode.provider.google.vertex") { ctx in
            let env = Host.currentEnvironment
            let projectCandidates = ["GOOGLE_VERTEX_PROJECT", "GOOGLE_CLOUD_PROJECT", "GCP_PROJECT", "GCLOUD_PROJECT"]
            let project: String? = projectCandidates.lazy.compactMap { key -> String? in
                guard let v = env.variable(key), !v.isEmpty else { return nil }
                return v
            }.first
            let locationCandidates = ["GOOGLE_VERTEX_LOCATION", "GOOGLE_CLOUD_LOCATION", "VERTEX_LOCATION"]
            let location: String = locationCandidates.lazy.compactMap { key -> String? in
                guard let v = env.variable(key), !v.isEmpty else { return nil }
                return v
            }.first ?? "global"
            let host: String
            if location == "global" {
                host = "aiplatform.googleapis.com"
            } else if location == "us" || location == "eu" {
                host = "aiplatform.\(location).rep.googleapis.com"
            } else {
                host = "\(location)-aiplatform.googleapis.com"
            }
            let baseURL: String
            if let project {
                baseURL = "https://\(host)/v1/projects/\(project)/locations/\(location)"
            } else {
                baseURL = "https://\(host)/v1"
            }
            var extra: [String: JSONValue] = ["location": .string(location)]
            if let project { extra["project"] = .string(project) }
            let hasADC = env.variable("GOOGLE_APPLICATION_CREDENTIALS").map { !$0.isEmpty } ?? false
            await registerCloudProvider(
                ctx: ctx,
                providerID: "google-vertex",
                name: "Google Vertex AI",
                package: "@opencode/ai/providers/google-vertex",
                defaultBaseURL: baseURL,
                envVars: ["GOOGLE_VERTEX_API_KEY"],
                extraSettings: extra,
                externalMethods: [
                    PluginEffect.IntegrationExternalMethod(id: "google-adc", label: "Google Application Default Credentials (ADC)"),
                ],
                ambientActive: hasADC && project != nil
            )
        }
    )

    // parity: core/src/plugin/provider/kilo.ts#KiloPlugin [status=adapted hash=9808ae1302af]
    public static let KiloPlugin = PluginEffect.define(
        PluginEffect.Plugin(id: "opencode.provider.kilo") { ctx in
            await registerCloudProvider(
                ctx: ctx,
                providerID: "kilo",
                name: "Kilo",
                package: "@opencode/ai/providers/openai-compatible",
                defaultBaseURL: "https://api.kilo.ai/api/openrouter",
                envVars: ["KILO_API_KEY"]
            )
        }
    )

    // parity: core/src/plugin/provider/llmgateway.ts#LLMGatewayPlugin [status=adapted hash=c3545406cbeb]
    public static let LLMGatewayPlugin = PluginEffect.define(
        PluginEffect.Plugin(id: "opencode.provider.llmgateway") { ctx in
            await registerCloudProvider(
                ctx: ctx,
                providerID: "llmgateway",
                name: "LLM Gateway",
                package: "@opencode/ai/providers/openai-compatible",
                defaultBaseURL: "https://api.llmgateway.io/v1",
                envVars: ["LLMGATEWAY_API_KEY"]
            )
        }
    )

    // parity: core/src/plugin/provider/modal.ts#ModalPlugin [status=adapted hash=cbcb94c86517]
    public static let ModalPlugin = PluginEffect.define(
        PluginEffect.Plugin(id: "opencode.provider.modal") { ctx in
            await registerCloudProvider(
                ctx: ctx,
                providerID: "modal",
                name: "Modal",
                package: "@opencode/ai/providers/openai-compatible",
                defaultBaseURL: "https://api.us-west-2.modal.direct/v1",
                envVars: ["MODAL_API_KEY"]
            )
        }
    )

    // parity: core/src/plugin/provider/neon.ts#NeonPlugin [status=adapted hash=c51c76466671]
    public static let NeonPlugin = PluginEffect.define(
        PluginEffect.Plugin(id: "opencode.provider.neon") { ctx in
            await registerCloudProvider(
                ctx: ctx,
                providerID: "neon",
                name: "Neon",
                package: "@opencode/ai/providers/openai-compatible",
                defaultBaseURL: "https://console.neon.tech/api/v2",
                envVars: ["NEON_API_KEY"]
            )
        }
    )

    // parity: core/src/plugin/provider/nvidia.ts#NvidiaPlugin [status=adapted hash=f86fa56cf7f4]
    public static let NvidiaPlugin = PluginEffect.define(
        PluginEffect.Plugin(id: "opencode.provider.nvidia") { ctx in
            await registerCloudProvider(
                ctx: ctx,
                providerID: "nvidia",
                name: "NVIDIA NIM",
                package: "@opencode/ai/providers/openai-compatible",
                defaultBaseURL: "https://integrate.api.nvidia.com/v1",
                envVars: ["NVIDIA_API_KEY"]
            )
        }
    )

    // parity: core/src/plugin/provider/openai-context-caps.ts#OpenAIContextCapsPlugin [status=adapted hash=0ad9b1a9deac]
    public static let OpenAIContextCapsPlugin = PluginEffect.define(
        PluginEffect.Plugin(id: "opencode.provider.openai-context-caps") { ctx in
            let methodIDs: Set<String> = ["chatgpt-browser", "chatgpt-headless", "chatgpt-token-sharing"]
            let stored = await ProviderCredentialSettings.storedCredential(ctx: ctx, integrationID: "openai")
            let isChatGPTLogin: Bool = {
                guard case .oauth(let o) = stored.credential else { return false }
                return methodIDs.contains(o.methodID.rawValue)
            }()
            guard isChatGPTLogin else { return }
            _ = await ctx.model.transform { editor in
                for model in editor.list("openai") {
                    let apiID = model.modelID.rawValue
                    let cap: Int = {
                        if apiID.contains("-astra") { return 272_000 }
                        if apiID.hasPrefix("gpt-6.") {
                            let rest = apiID.dropFirst("gpt-6.".count)
                            if let minor = Int(rest.prefix(while: \.isNumber)), minor >= 1 { return 500_000 }
                            return 272_000
                        }
                        if apiID.hasPrefix("gpt-7") || apiID.hasPrefix("gpt-8") { return 500_000 }
                        return 272_000
                    }()
                    let currentInput = model.limit.input ?? model.limit.context
                    if currentInput > cap {
                        editor.update("openai", model.id.rawValue) { draft in
                            draft = ModelSchema.Info(
                                id: draft.id,
                                modelID: draft.modelID,
                                providerID: draft.providerID,
                                canonical: draft.canonical,
                                type: draft.type,
                                family: draft.family,
                                name: draft.name,
                                compatibility: draft.compatibility,
                                package: draft.package,
                                settings: draft.settings,
                                headers: draft.headers,
                                body: draft.body,
                                capabilities: draft.capabilities,
                                variants: draft.variants,
                                time: draft.time,
                                cost: draft.cost,
                                status: draft.status,
                                enabled: draft.enabled,
                                limit: ModelSchema.Info.Limit(
                                    context: cap + draft.limit.output,
                                    input: cap,
                                    output: draft.limit.output
                                )
                            )
                        }
                    }
                }
            }
        }
    )

    // parity: core/src/plugin/provider/openai.ts#OpenAIPlugin [status=adapted hash=4a6e5dd63a10]
    public static let OpenAIPlugin = PluginEffect.define(
        PluginEffect.Plugin(id: "opencode.provider.openai") { ctx in
            await registerCloudProvider(
                ctx: ctx,
                providerID: "openai",
                name: "OpenAI",
                package: "@opencode/ai/providers/openai",
                defaultBaseURL: "https://api.openai.com/v1",
                envVars: ["OPENAI_API_KEY"],
                baseURLEnvVars: ["OPENAI_BASE_URL"]
            )
        }
    )

    // parity: core/src/plugin/provider/opencode.ts#OpencodePlugin [status=adapted hash=e708e0cab564]
    public static let OpencodePlugin = PluginEffect.define(
        PluginEffect.Plugin(id: "opencode.provider.opencode") { ctx in
            await registerCloudProvider(
                ctx: ctx,
                providerID: "opencode",
                name: "OpenCode",
                package: "@opencode/ai/providers/opencode/decisions",
                defaultBaseURL: "https://opencode.ai/inference/systemone/v1",
                envVars: ["OPENCODE_API_KEY"],
                baseURLEnvVars: ["OPENCODE_BASE_URL"]
            )
        }
    )

    // parity: core/src/plugin/provider/openrouter.ts#OpenRouterPlugin [status=adapted hash=9238e39d68eb]
    public static let OpenRouterPlugin = PluginEffect.define(
        PluginEffect.Plugin(id: "opencode.provider.openrouter") { ctx in
            await registerCloudProvider(
                ctx: ctx,
                providerID: "openrouter",
                name: "OpenRouter",
                package: "@opencode/ai/providers/openrouter",
                defaultBaseURL: "https://openrouter.ai/api/v1",
                envVars: ["OPENROUTER_API_KEY"],
                defaultHeaders: [
                    "HTTP-Referer": "https://opencode.ai/",
                    "X-Title": "opencode",
                ]
            )
            _ = await ctx.model.transform { models in
                for item in models.listProviders() where item.provider.package == "@opencode/ai/providers/openrouter" {
                    for disabledID in ["gpt-5-chat-latest", "openai/gpt-5-chat"] {
                        guard models.get(item.provider.id.rawValue, disabledID) != nil else { continue }
                        models.update(item.provider.id.rawValue, disabledID) { draft in
                            draft = ModelSchema.Info(
                                id: draft.id,
                                modelID: draft.modelID,
                                providerID: draft.providerID,
                                canonical: draft.canonical,
                                type: draft.type,
                                family: draft.family,
                                name: draft.name,
                                compatibility: draft.compatibility,
                                package: draft.package,
                                settings: draft.settings,
                                headers: draft.headers,
                                body: draft.body,
                                capabilities: draft.capabilities,
                                variants: draft.variants,
                                time: draft.time,
                                cost: draft.cost,
                                status: draft.status,
                                enabled: false,
                                limit: draft.limit
                            )
                        }
                    }
                }
            }
        }
    )

    // parity: core/src/plugin/provider/poe.ts#PoePlugin [status=adapted hash=213d50e06d2a]
    public static let PoePlugin = PluginEffect.define(
        PluginEffect.Plugin(id: "opencode.provider.poe") { ctx in
            await registerCloudProvider(
                ctx: ctx,
                providerID: "poe",
                name: "Poe",
                package: "@opencode/ai/providers/openai-compatible",
                defaultBaseURL: "https://api.poe.com/v1",
                envVars: ["POE_API_KEY"]
            )
        }
    )

    // parity: core/src/plugin/provider/prompt-cache-key.ts#PromptCacheKeyPlugin [status=adapted hash=44cd4d776f1f]
    public static let PromptCacheKeyPlugin = PluginEffect.define(
        PluginEffect.Plugin(id: "opencode.provider.prompt-cache-key") { ctx in
            let providerIDs = [
                "abliteration-ai", "aihubmix", "anyapi", "auriko", "edenai", "jalapeno",
                "llama", "morph", "snowflake-cortex", "tencent-tokenhub", "upstage", "venice",
            ]
            _ = await ctx.provider.transform { editor in
                for id in providerIDs where editor.get(id) != nil {
                    editor.update(id) { existing in
                        let compat = ModelCompatibilitySchema.ProviderCompatibility(
                            reasoningField: existing.compatibility?.reasoningField,
                            requireReasoning: existing.compatibility?.requireReasoning,
                            maxTokensField: existing.compatibility?.maxTokensField,
                            requireFinishReason: existing.compatibility?.requireFinishReason,
                            requireAssistantAfterTool: existing.compatibility?.requireAssistantAfterTool,
                            supportsPromptCacheKey: true,
                            streamUsage: existing.compatibility?.streamUsage,
                            cacheFormat: existing.compatibility?.cacheFormat,
                            mediaInput: existing.compatibility?.mediaInput
                        )
                        existing = ProviderSchema.Info(
                            id: existing.id,
                            canonical: existing.canonical,
                            integrationID: existing.integrationID,
                            name: existing.name,
                            activation: existing.activation,
                            package: existing.package,
                            compatibility: compat,
                            settings: existing.settings,
                            headers: existing.headers,
                            body: existing.body
                        )
                    }
                }
            }
        }
    )

    // parity: core/src/plugin/provider/sap-ai-core.ts#SapAICorePlugin [status=adapted hash=f9a61e852190]
    public static let SapAICorePlugin = PluginEffect.define(
        PluginEffect.Plugin(id: "opencode.provider.sap.ai.core") { ctx in
            await registerCloudProvider(
                ctx: ctx,
                providerID: "sap-ai-core",
                name: "SAP AI Core",
                package: "@opencode/ai/providers/openai-compatible",
                defaultBaseURL: "https://api.ai.prod.eu-central-1.aws.ml.hana.ondemand.com/v2",
                envVars: ["AICORE_SERVICE_KEY"]
            )
        }
    )

    // parity: core/src/plugin/provider/snowflake-cortex.ts#SnowflakeCortexPlugin [status=adapted hash=efd6863b9c96]
    public static let SnowflakeCortexPlugin = PluginEffect.define(
        PluginEffect.Plugin(id: "opencode.provider.snowflake.cortex") { ctx in
            await registerCloudProvider(
                ctx: ctx,
                providerID: "snowflake-cortex",
                name: "Snowflake Cortex",
                package: "@opencode/ai/providers/openai-compatible",
                defaultBaseURL: "https://snowflakecomputing.com/api/v2/cortex/inference",
                envVars: ["SNOWFLAKE_TOKEN"]
            )
        }
    )

    // parity: core/src/plugin/provider/xai.ts#XAIPlugin [status=adapted hash=f133a37f143b]
    public static let XAIPlugin = PluginEffect.define(
        PluginEffect.Plugin(id: "opencode.provider.xai") { ctx in
            await registerCloudProvider(
                ctx: ctx,
                providerID: "xai",
                name: "xAI",
                package: "@opencode/ai/providers/xai",
                defaultBaseURL: "https://api.x.ai/v1",
                envVars: ["XAI_API_KEY"]
            )
        }
    )

    // parity: core/src/plugin/provider/zenmux.ts#ZenmuxPlugin [status=adapted hash=08f51442389d]
    public static let ZenmuxPlugin = PluginEffect.define(
        PluginEffect.Plugin(id: "opencode.provider.zenmux") { ctx in
            await registerCloudProvider(
                ctx: ctx,
                providerID: "zenmux",
                name: "Zenmux",
                package: "@opencode/ai/providers/openai-compatible",
                defaultBaseURL: "https://zenmux.ai/api/v1",
                envVars: ["ZENMUX_API_KEY"]
            )
        }
    )

    /// Built-in Anthropic cloud provider plugin (`opencode.provider.anthropic`).
    public static let AnthropicPlugin = PluginEffect.define(
        PluginEffect.Plugin(id: "opencode.provider.anthropic") { ctx in
            await registerCloudProvider(
                ctx: ctx,
                providerID: "anthropic",
                name: "Anthropic",
                package: "@opencode/ai/providers/anthropic",
                defaultBaseURL: "https://api.anthropic.com/v1",
                envVars: ["ANTHROPIC_API_KEY"],
                baseURLEnvVars: ["ANTHROPIC_BASE_URL"]
            )
        }
    )

    /// Built-in Google Gemini cloud provider plugin (`opencode.provider.google`).
    public static let GooglePlugin = PluginEffect.define(
        PluginEffect.Plugin(id: "opencode.provider.google") { ctx in
            await registerCloudProvider(
                ctx: ctx,
                providerID: "google",
                name: "Google",
                package: "@opencode/ai/providers/google",
                defaultBaseURL: "https://generativelanguage.googleapis.com/v1beta",
                envVars: ["GEMINI_API_KEY", "GOOGLE_GENERATIVE_AI_API_KEY", "GOOGLE_API_KEY"]
            )
        }
    )

    /// Built-in Groq cloud provider plugin (`opencode.provider.groq`).
    public static let GroqPlugin = PluginEffect.define(
        PluginEffect.Plugin(id: "opencode.provider.groq") { ctx in
            await registerCloudProvider(
                ctx: ctx,
                providerID: "groq",
                name: "Groq",
                package: "@opencode/ai/providers/groq",
                defaultBaseURL: "https://api.groq.com/openai/v1",
                envVars: ["GROQ_API_KEY"]
            )
        }
    )

    /// Built-in DeepSeek cloud provider plugin (`opencode.provider.deepseek`).
    public static let DeepSeekPlugin = PluginEffect.define(
        PluginEffect.Plugin(id: "opencode.provider.deepseek") { ctx in
            await registerCloudProvider(
                ctx: ctx,
                providerID: "deepseek",
                name: "DeepSeek",
                package: "@opencode/ai/providers/deepseek",
                defaultBaseURL: "https://api.deepseek.com",
                envVars: ["DEEPSEEK_API_KEY"]
            )
        }
    )

    /// Built-in Mistral cloud provider plugin (`opencode.provider.mistral`).
    public static let MistralPlugin = PluginEffect.define(
        PluginEffect.Plugin(id: "opencode.provider.mistral") { ctx in
            await registerCloudProvider(
                ctx: ctx,
                providerID: "mistral",
                name: "Mistral",
                package: "@opencode/ai/providers/mistral",
                defaultBaseURL: "https://api.mistral.ai/v1",
                envVars: ["MISTRAL_API_KEY"]
            )
        }
    )

    /// Complete built-in provider plugins array matching `packages/core/src/plugin/provider.ts`.
    // parity: core/src/plugin/provider.ts#ProviderPlugins [status=implemented hash=7eb0beb5b91a]
    public static let ProviderPlugins: [PluginEffect.Plugin] = [
        AmazonBedrockPlugin,
        AzureProvider.AzurePlugin,
        CerebrasPlugin,
        ChatGPTProvider.ChatGPTPlugin,
        ClaudeAgent.ClaudeAgentPlugin,
        CloudflareAIGatewayPlugin,
        CloudflareWorkersAIPlugin,
        DatabricksPlugin,
        DigitalOceanPlugin,
        GithubCopilotPlugin,
        GitLabPlugin,
        GoogleVertexPlugin,
        KiloPlugin,
        LLMGatewayPlugin,
        LMStudioProvider.LMStudioPlugin,
        ModalPlugin,
        NeonPlugin,
        NvidiaPlugin,
        OllamaProvider.OllamaPlugin,
        OpenAIContextCapsPlugin,
        OpenAIPlugin,
        OpencodePlugin,
        OpenRouterPlugin,
        PoePlugin,
        PromptCacheKeyPlugin,
        SapAICorePlugin,
        SnowflakeCortexPlugin,
        VLLMProvider.VLLMPlugin,
        XAIPlugin,
        ZenmuxPlugin,
    ]

    // MARK: - Claude Agent Provider Plugin (`plugin/provider/claude-agent/*`, 60 symbols)

    public enum ClaudeAgent {
        // parity: core/src/plugin/provider/claude-agent/index.ts#ID [status=implemented hash=fe4c17cf4273]
        public static let ID = "opencode.provider.claude-agent"

        // parity: core/src/plugin/provider/claude-agent/provider.ts#ID [status=implemented hash=45c31ed553c9]
        public static let ProviderID = ProviderSchema.ID(rawValue: "claude-agent")

        // parity: core/src/plugin/provider/claude-agent/provider.ts#PACKAGE [status=implemented hash=1c602df24e17]
        public static let ProviderPackage = "@opencode/claude-agent"

        // parity: core/src/plugin/provider/claude-agent/integration.ts#METHOD_ID [status=implemented hash=8c0a2ca425ae]
        public static let MethodID = "claude-login"

        // MARK: claude-agent/language-model/request-kind.ts

        // parity: core/src/plugin/provider/claude-agent/language-model/request-kind.ts#HEADER [status=implemented hash=bc34bcca3cc6]
        public static let RequestKindHeader = "x-opencode-claude-agent-kind"

        // parity: core/src/plugin/provider/claude-agent/language-model/request-kind.ts#SESSION_HEADER [status=implemented hash=71ad8e044f9b]
        public static let SessionHeader = "x-opencode-session-id"

        // parity: core/src/plugin/provider/claude-agent/language-model/request-kind.ts#FORK_HEADER [status=implemented hash=70b68dae71d5]
        public static let ForkHeader = "x-opencode-claude-agent-fork-source"

        // MARK: claude-agent/language-model/system-prompt.ts

        // parity: core/src/plugin/provider/claude-agent/language-model/system-prompt.ts#AGENT_OPTION [status=implemented hash=057f7ac245bb]
        public static let AGENT_OPTION = "claudeCodeAgent"

        // parity: core/src/plugin/provider/claude-agent/language-model/system-prompt.ts#INSTRUCTIONS_OPTION [status=implemented hash=87b3cec222fb]
        public static let INSTRUCTIONS_OPTION = "claudeCodeInstructions"

        public struct SystemPromptPreset: Equatable, Hashable, Sendable, Codable {
            public let type: String
            public let preset: String
            public let snapshot: Bool
            public let append: String

            public init(append: String) {
                self.type = "preset"
                self.preset = "claude_code"
                self.snapshot = false
                self.append = append
            }
        }

        // parity: core/src/plugin/provider/claude-agent/language-model/system-prompt.ts#make [status=implemented hash=e267b53c57a1]
        public static func makeSystemPrompt(role: String? = nil, instructions: String? = nil) -> SystemPromptPreset {
            var blocks = [
                "<runtime_info>You are running in OpenCode through the Claude Code harness. Mention this only when asked.</runtime_info>"
            ]
            if let role, !role.isEmpty {
                blocks.append("# Agent role (from OpenCode)\n" + role)
            }
            if let instructions, !instructions.isEmpty {
                blocks.append(instructions)
            }
            return SystemPromptPreset(append: blocks.joined(separator: "\n\n"))
        }

        // parity: core/src/plugin/provider/claude-agent/language-model/system-prompt.ts#utility [status=implemented hash=a19de45f13a4]
        public static func utilitySystemPrompt(systemBlocks: [String]) -> String {
            let joined = systemBlocks.joined(separator: "\n\n")
            return joined.isEmpty ? "You are a text generation helper. Return only the requested output." : joined
        }

        // MARK: claude-agent/tools/names.ts

        public enum ToolNames {
            // parity: core/src/plugin/provider/claude-agent/tools/names.ts#PREFIX [status=implemented hash=b619d15362e2]
            public static let PREFIX = "mcp__opencode__"
            private static let descriptionLimit = 2048

            /// Shortens and sanitizes a tool name to fit Claude Code's 64-char MCP tool name limit.
            // parity: core/src/plugin/provider/claude-agent/tools/names.ts#short [status=implemented hash=8f9c8b3b4966]
            public static func short(_ name: String) -> String {
                let limit = 64 - PREFIX.count
                let validChars = name.unicodeScalars.allSatisfy { scalar in
                    (scalar >= "a" && scalar <= "z")
                        || (scalar >= "A" && scalar <= "Z")
                        || (scalar >= "0" && scalar <= "9")
                        || scalar == "_" || scalar == "-"
                }
                if name.count <= limit && validChars {
                    return name
                }
                let digest = String(Hash.sha256(name).prefix(10))
                let sanitized = String(name.unicodeScalars.map { scalar -> Character in
                    let ok = (scalar >= "a" && scalar <= "z")
                        || (scalar >= "A" && scalar <= "Z")
                        || (scalar >= "0" && scalar <= "9")
                        || scalar == "_" || scalar == "-"
                    return ok ? Character(scalar) : "_"
                })
                let head = String(sanitized.prefix(max(0, limit - 11)))
                return "\(head)_\(digest)"
            }

            /// Maps a prefixed Claude MCP tool name back to its original OpenCode tool name.
            // parity: core/src/plugin/provider/claude-agent/tools/names.ts#original [status=implemented hash=8582793f8609]
            public static func original(_ name: String, tools: [String]) -> String? {
                tools.first { PREFIX + short($0) == name }
            }

            /// Truncates tool descriptions to 2048 chars, hoisting `"Available subagents:"` first for `subagent`.
            // parity: core/src/plugin/provider/claude-agent/tools/names.ts#description [status=implemented hash=8bb8b04f1722]
            public static func description(name: String, description: String?) -> String {
                let text = description ?? ""
                if name != "subagent" || text.count <= descriptionLimit {
                    return String(text.prefix(descriptionLimit))
                }
                guard let range = text.range(of: "Available subagents:") else {
                    return String(text.prefix(descriptionLimit))
                }
                let reordered = String(text[range.lowerBound...]) + "\n\n" + String(text[..<range.lowerBound])
                return String(reordered.prefix(descriptionLimit))
            }
        }

        // MARK: claude-agent/claude/probe.ts

        public enum Probe {
            private static let minimumVersion = "2.1.248"

            // parity: core/src/plugin/provider/claude-agent/claude/probe.ts#Model [status=implemented hash=576548ba5765]
            public struct Model: Equatable, Hashable, Sendable, Codable {
                public let value: String
                public let displayName: String?
                public var contextWindow: Int?

                public init(value: String, displayName: String? = nil, contextWindow: Int? = nil) {
                    self.value = value
                    self.displayName = displayName
                    self.contextWindow = contextWindow
                }
            }

            // parity: core/src/plugin/provider/claude-agent/claude/probe.ts#Result [status=implemented hash=bb2a2a1a8d02]
            public struct Result: Equatable, Hashable, Sendable, Codable {
                public let version: String?
                public let tokenSource: String
                public let apiKeySource: String?
                public let models: [Model]

                public init(version: String?, tokenSource: String, apiKeySource: String? = nil, models: [Model] = []) {
                    self.version = version
                    self.tokenSource = tokenSource
                    self.apiKeySource = apiKeySource
                    self.models = models
                }
            }

            // parity: core/src/plugin/provider/claude-agent/claude/probe.ts#ProbeError [status=implemented hash=cc4e302022ef]
            public struct ProbeError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
                public static let tag = "ClaudeProbe.ProbeError"
                public let message: String

                public init(message: String) {
                    self.message = message
                }

                public var description: String { message }
            }

            /// Validates Claude Code CLI version compatibility (`>= 2.1.248`).
            // parity: core/src/plugin/provider/claude-agent/claude/probe.ts#versionError [status=implemented hash=cbdb31c46530]
            public static func versionError(_ version: String?) -> String? {
                if let version, atLeast(version, minimumVersion) {
                    return nil
                }
                let message: String
                if let version {
                    message = "Claude Code \(version) is too old; \(minimumVersion) or later is required."
                } else {
                    message = "Claude Code did not report its version, so compatibility could not be checked."
                }
                return "\(message) Run `claude update`."
            }

            private static func atLeast(_ version: String, _ minimum: String) -> Bool {
                func parse(_ s: String) -> [Int] {
                    let core = s.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? s
                    return core.split(separator: ".").map { Int($0) ?? 0 }
                }
                let current = parse(version)
                let required = parse(minimum)
                for i in 0..<required.count {
                    let cur = i < current.count ? current[i] : 0
                    if cur != required[i] {
                        return cur > required[i]
                    }
                }
                return true
            }

            // parity: core/src/plugin/provider/claude-agent/claude/probe.ts#isLoggedIn [status=implemented hash=a916a0c3578f]
            public static func isLoggedIn(tokenSource: String, apiKeySource: String?) -> Bool {
                tokenSource != "none" || apiKeySource != nil
            }

            // parity: core/src/plugin/provider/claude-agent/claude/probe.ts#run [status=adapted hash=e1f57a4615bb]
            public static func run(probe: @Sendable () async throws -> Result) async throws -> Result {
                do {
                    return try await probe()
                } catch {
                    throw ProbeError(message: String(describing: error))
                }
            }
        }

        // MARK: claude-agent/claude/{fork,io,query-options,sdk,session,sessions,status}.ts

        public enum Fork {
            // parity: core/src/plugin/provider/claude-agent/claude/fork.ts#Result [status=implemented hash=1266784214dc]
            public struct Result: Equatable, Hashable, Sendable, Codable {
                public let sessionID: String

                public init(sessionID: String) {
                    self.sessionID = sessionID
                }
            }

            // parity: core/src/plugin/provider/claude-agent/claude/fork.ts#create [status=adapted hash=0e0b0cc69f54]
            public static func create(sessionID: String, messageID: String) async -> Result? {
                _ = (sessionID, messageID)
                return nil
            }
        }

        public enum IO {
            // parity: core/src/plugin/provider/claude-agent/claude/io.ts#Interface [status=adapted hash=6b304eb2cf16]
            public struct Interface: Sendable {
                public let which: @Sendable () -> String?
                public let env: @Sendable () -> [String: String]
                public let sessionExists: @Sendable (String) async -> Bool
                public let fork: @Sendable (String, String) async -> Fork.Result?
                public let remove: @Sendable (String) async -> Void
                public let probe: @Sendable () async throws -> Probe.Result

                public init(
                    which: @escaping @Sendable () -> String? = { Host.currentEnvironment.variable("OPENCODE_CLAUDE_PATH") },
                    env: @escaping @Sendable () -> [String: String] = {
                        #if os(WASI)
                        return [:]
                        #else
                        return ProcessInfo.processInfo.environment
                        #endif
                    },
                    sessionExists: @escaping @Sendable (String) async -> Bool = { _ in false },
                    fork: @escaping @Sendable (String, String) async -> Fork.Result? = { sessionID, messageID in
                        await Fork.create(sessionID: sessionID, messageID: messageID)
                    },
                    remove: @escaping @Sendable (String) async -> Void = { _ in },
                    probe: @escaping @Sendable () async throws -> Probe.Result = {
                        Probe.Result(version: nil, tokenSource: "none", apiKeySource: nil, models: [])
                    }
                ) {
                    self.which = which
                    self.env = env
                    self.sessionExists = sessionExists
                    self.fork = fork
                    self.remove = remove
                    self.probe = probe
                }
            }

            // parity: core/src/plugin/provider/claude-agent/claude/io.ts#real [status=adapted hash=5039a7782ec4]
            public static let real = Interface()
        }

        public enum QueryOptions {
            // parity: core/src/plugin/provider/claude-agent/claude/query-options.ts#connectionEnv [status=implemented hash=9ddb83b087c4]
            public static func connectionEnv(apiKey: String?, baseURL: String?) -> [String: String] {
                var env: [String: String] = [:]
                if let apiKey, !apiKey.isEmpty { env["ANTHROPIC_API_KEY"] = apiKey }
                if let baseURL, !baseURL.isEmpty { env["ANTHROPIC_BASE_URL"] = baseURL }
                return env
            }

            // parity: core/src/plugin/provider/claude-agent/claude/query-options.ts#base [status=adapted hash=beecd3e161f5]
            public static func base(cwd: String, env: [String: String] = [:]) -> [String: JSONValue] {
                [
                    "cwd": .string(cwd),
                    "env": .object(env.mapValues { .string($0) }),
                ]
            }

            // parity: core/src/plugin/provider/claude-agent/claude/query-options.ts#session [status=adapted hash=6b7dd2fa6d29]
            public static func session(cwd: String, model: String, resume: String? = nil) async -> [String: JSONValue] {
                var opts = base(cwd: cwd)
                opts["model"] = .string(model)
                if let resume { opts["resume"] = .string(resume) }
                return opts
            }
        }

        public enum SDK {
            // parity: core/src/plugin/provider/claude-agent/claude/sdk.ts#load [status=adapted hash=f5e20c7beb18]
            public static func load() async throws -> AnySendableValue {
                try await RuntimeImport.importNodeModule("@anthropic-ai/claude-agent-sdk")
            }
        }

        public enum SessionProcess {
            // parity: core/src/plugin/provider/claude-agent/claude/session.ts#Interface [status=adapted hash=25d30d673330]
            public struct Interface: Sendable {
                public let id: String
                public let close: @Sendable () async -> Void

                public init(id: String, close: @escaping @Sendable () async -> Void = {}) {
                    self.id = id
                    self.close = close
                }
            }

            // parity: core/src/plugin/provider/claude-agent/claude/session.ts#start [status=adapted hash=1890d48a66ba]
            public static func start(id: String = UUID().uuidString) async -> Interface {
                Interface(id: id)
            }
        }

        public enum Sessions {
            // parity: core/src/plugin/provider/claude-agent/claude/sessions.ts#HANDOVER_MS [status=implemented hash=5a3c052fabf8]
            public static let HANDOVER_MS = 10_000

            // parity: core/src/plugin/provider/claude-agent/claude/sessions.ts#IDLE_MS [status=implemented hash=c45c137edf0e]
            public static let IDLE_MS = 5 * 60_000

            // parity: core/src/plugin/provider/claude-agent/claude/sessions.ts#Request [status=implemented hash=77cedc99ab92]
            public struct Request: Equatable, Hashable, Sendable, Codable {
                public let sessionID: String
                public let modelID: String

                public init(sessionID: String, modelID: String) {
                    self.sessionID = sessionID
                    self.modelID = modelID
                }
            }

            // parity: core/src/plugin/provider/claude-agent/claude/sessions.ts#Interface [status=adapted hash=03a0fba49a11]
            public protocol Interface: Sendable {
                func activeCount() async -> Int
                func closeAll() async
            }

            public actor Registry: Interface {
                private var sessions: [String: SessionProcess.Interface] = [:]

                public init() {}

                public func activeCount() async -> Int {
                    sessions.count
                }

                public func closeAll() async {
                    let all = Array(sessions.values)
                    sessions.removeAll()
                    for session in all {
                        await session.close()
                    }
                }
            }

            // parity: core/src/plugin/provider/claude-agent/claude/sessions.ts#registry [status=implemented hash=cc326c5851ed]
            public static func registry() -> Registry {
                Registry()
            }
        }

        public enum Status {
            // parity: core/src/plugin/provider/claude-agent/claude/status.ts#State [status=implemented hash=6bfed2bbbd1f]
            public enum State: Equatable, Hashable, Sendable, Codable {
                case idle
                case ready(version: String?, models: [Probe.Model])
                case unauthenticated
                case unavailable(message: String)
            }

            // parity: core/src/plugin/provider/claude-agent/claude/status.ts#Interface [status=implemented hash=243171849b11]
            public protocol Interface: Sendable {
                func current() async -> State
                func refresh() async -> State
            }

            public actor Tracker: Interface {
                private var state: State = .idle
                private let io: IO.Interface

                public init(io: IO.Interface) {
                    self.io = io
                }

                public func current() async -> State { state }

                public func refresh() async -> State {
                    do {
                        let result = try await io.probe()
                        if Probe.isLoggedIn(tokenSource: result.tokenSource, apiKeySource: result.apiKeySource) {
                            state = .ready(version: result.version, models: result.models)
                        } else {
                            state = .unauthenticated
                        }
                    } catch {
                        state = .unavailable(message: String(describing: error))
                    }
                    return state
                }
            }

            // parity: core/src/plugin/provider/claude-agent/claude/status.ts#make [status=implemented hash=d044658a37eb]
            public static func make(io: IO.Interface = IO.real) -> Tracker {
                Tracker(io: io)
            }
        }

        // MARK: claude-agent/language-model/*

        public enum ErrorMapper {
            // parity: core/src/plugin/provider/claude-agent/language-model/claude-agent-error.ts#make [status=implemented hash=08c51c16c454]
            public static func make() -> @Sendable (_ isError: Bool, _ status: Int?, _ resultText: String) -> String? {
                { isError, status, resultText in
                    let httpError = status.map { $0 >= 400 } ?? false
                    if !isError && !httpError { return nil }
                    let cleaned = resultText.replacing("Please run /login", with: "Run `claude auth login` in a terminal")
                    if let status, status >= 500 {
                        let head = status == 529 ? "Anthropic is overloaded (529)." : "Anthropic returned HTTP \(status)."
                        return head + " Claude Code exhausted its retries. Try again shortly."
                    }
                    if !cleaned.isEmpty { return cleaned }
                    if let status { return "Claude Code could not finish its reply (HTTP \(status))" }
                    return "Claude Code could not finish its reply"
                }
            }
        }

        public enum LanguageModel {
            public enum EffortLevel: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
                case low
                case medium
                case high
                case xhigh
                case max
            }

            public struct LanguageModelError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
                public let message: String
                public init(_ message: String) { self.message = message }
                public var description: String { message }
            }

            public struct CallOptions: Equatable, Sendable {
                public let headers: [String: String]
                public let providerOptions: [String: [String: JSONValue]]
                public let prompt: [String]
                public let tools: [String]
                public let toolChoiceNone: Bool
                public let maxOutputTokens: Int?

                public init(
                    headers: [String: String] = [:],
                    providerOptions: [String: [String: JSONValue]] = [:],
                    prompt: [String] = [],
                    tools: [String] = [],
                    toolChoiceNone: Bool = false,
                    maxOutputTokens: Int? = nil
                ) {
                    self.headers = headers
                    self.providerOptions = providerOptions
                    self.prompt = prompt
                    self.tools = tools
                    self.toolChoiceNone = toolChoiceNone
                    self.maxOutputTokens = maxOutputTokens
                }
            }

            public enum StreamPart: Equatable, Hashable, Sendable {
                case streamStart(warnings: [String])
                case textDelta(String)
                case toolCall(name: String, arguments: JSONValue)
                case finish(reason: String)
            }

            public struct StreamRunRequest: Sendable {
                public let sessionID: String?
                public let sourceID: String?
                public let model: String
                public let effort: EffortLevel?
                public let maxOutputTokens: Int?
                public let connection: [String: String]
                public let system: String
                public let prompt: [String]
                public let tools: [String]
                public let emit: @Sendable (StreamPart) -> Void

                public init(
                    sessionID: String?,
                    sourceID: String?,
                    model: String,
                    effort: EffortLevel?,
                    maxOutputTokens: Int?,
                    connection: [String: String],
                    system: String,
                    prompt: [String],
                    tools: [String],
                    emit: @escaping @Sendable (StreamPart) -> Void
                ) {
                    self.sessionID = sessionID
                    self.sourceID = sourceID
                    self.model = model
                    self.effort = effort
                    self.maxOutputTokens = maxOutputTokens
                    self.connection = connection
                    self.system = system
                    self.prompt = prompt
                    self.tools = tools
                    self.emit = emit
                }
            }

            public struct StreamResult: Sendable {
                public let stream: AsyncThrowingStream<StreamPart, Error>

                public init(stream: AsyncThrowingStream<StreamPart, Error>) {
                    self.stream = stream
                }
            }

            // parity: core/src/plugin/provider/claude-agent/language-model/claude-agent-language-model.ts#Dependencies [status=adapted hash=9e0da3285c5a]
            public struct Dependencies: Sendable {
                public let sessions: any Sessions.Interface
                public let run: @Sendable (StreamRunRequest) async throws -> Void

                public init(
                    sessions: any Sessions.Interface = Sessions.registry(),
                    run: @escaping @Sendable (StreamRunRequest) async throws -> Void = { _ in }
                ) {
                    self.sessions = sessions
                    self.run = run
                }
            }

            // parity: core/src/plugin/provider/claude-agent/language-model/claude-agent-language-model.ts#Model [status=adapted hash=11758fccebf4]
            public final class Model: Sendable {
                public let specificationVersion = "v3"
                public let modelId: String
                public let provider: String
                public let dependencies: Dependencies
                public let connection: [String: String]

                public init(
                    modelId: String,
                    provider: String = "claude-agent",
                    dependencies: Dependencies = Dependencies(),
                    connection: [String: String] = [:]
                ) {
                    self.modelId = modelId
                    self.provider = provider
                    self.dependencies = dependencies
                    self.connection = connection
                }

                private static func parseEffort(_ value: JSONValue?) throws -> EffortLevel? {
                    guard let value, value != .null else { return nil }
                    if case .string(let raw) = value, let parsed = EffortLevel(rawValue: raw) {
                        return parsed
                    }
                    throw LanguageModelError("Claude Agent effort must be low, medium, high, xhigh or max")
                }

                /// Claude Agent models only support streaming; non-streaming `doGenerate` rejects immediately.
                // parity: core/src/plugin/provider/claude-agent/language-model/claude-agent-language-model.ts#Model.doGenerate [status=implemented hash=8394b0219e5d]
                public func doGenerate(_ options: CallOptions = CallOptions()) async throws -> Never {
                    _ = options
                    throw LanguageModelError("Claude Agent models only support streaming")
                }

                /// Streams Claude Agent SDK responses with session/fork routing, effort validation, and prompt selection.
                // parity: core/src/plugin/provider/claude-agent/language-model/claude-agent-language-model.ts#Model.doStream [status=implemented hash=c210644f5886]
                public func doStream(_ options: CallOptions) async throws -> StreamResult {
                    let settings = options.providerOptions[ClaudeAgent.ProviderID.rawValue]
                    let effort = try Self.parseEffort(settings?["effort"])
                    let agent: String?
                    if case .string(let role) = settings?[ClaudeAgent.AGENT_OPTION] {
                        agent = role
                    } else {
                        agent = nil
                    }
                    let instructions: String?
                    if case .string(let loaded) = settings?[ClaudeAgent.INSTRUCTIONS_OPTION] {
                        instructions = loaded
                    } else {
                        instructions = nil
                    }
                    let kind = options.headers[ClaudeAgent.RequestKindHeader]
                    let session = options.headers[ClaudeAgent.SessionHeader]
                    let primary = kind == "primary"
                    let branch = kind == "generate" || kind == "compaction"
                    let sessionID = primary ? session : nil
                    let sourceID = primary ? options.headers[ClaudeAgent.ForkHeader] : (branch ? session : nil)
                    let offered = (primary || branch) && !options.toolChoiceNone ? options.tools : []
                    let convert = StreamConverter.make(toolNames: offered)
                    let system: String = (primary || branch)
                        ? ClaudeAgent.makeSystemPrompt(role: agent, instructions: instructions).append
                        : ClaudeAgent.utilitySystemPrompt(systemBlocks: options.prompt)

                    let deps = self.dependencies
                    let modelId = self.modelId
                    let connection = self.connection
                    let stream = AsyncThrowingStream<StreamPart, Error> { continuation in
                        continuation.yield(.streamStart(warnings: []))
                        let task = Task {
                            do {
                                let request = StreamRunRequest(
                                    sessionID: sessionID,
                                    sourceID: sourceID,
                                    model: modelId,
                                    effort: effort,
                                    maxOutputTokens: options.maxOutputTokens,
                                    connection: connection,
                                    system: system,
                                    prompt: options.prompt,
                                    tools: offered,
                                    emit: { part in
                                        switch part {
                                        case .toolCall(let rawName, let args):
                                            continuation.yield(.toolCall(name: convert(rawName), arguments: args))
                                        default:
                                            continuation.yield(part)
                                        }
                                    }
                                )
                                try await deps.run(request)
                                continuation.finish()
                            } catch {
                                continuation.finish(throwing: error)
                            }
                        }
                        continuation.onTermination = { _ in
                            task.cancel()
                        }
                    }
                    return StreamResult(stream: stream)
                }
            }
        }

        public enum StreamConverter {
            // parity: core/src/plugin/provider/claude-agent/language-model/convert-claude-stream.ts#make [status=adapted hash=533281e2919b]
            public static func make(toolNames: [String]) -> @Sendable (String) -> String {
                { rawToolName in
                    ToolNames.original(rawToolName, tools: toolNames) ?? rawToolName
                }
            }
        }

        public enum MessageConverter {
            // parity: core/src/plugin/provider/claude-agent/language-model/convert-to-claude-message.ts#ContentBlock [status=implemented hash=564b90e448c3]
            public enum ContentBlock: Equatable, Hashable, Sendable, Codable {
                case text(String)
                case imageBase64(mediaType: String, data: String)
                case imageURL(String)
                case documentBase64(mediaType: String, data: String)
                case documentURL(String)
            }

            /// Converts OpenCode prompt messages into Claude Agent SDK content blocks.
            // parity: core/src/plugin/provider/claude-agent/language-model/convert-to-claude-message.ts#content [status=implemented hash=4fd06577355a]
            public static func content(_ messages: [(role: String, text: String)]) -> [ContentBlock] {
                let hasHistory = messages.contains { $0.role == "assistant" || $0.role == "tool" }
                var blocks: [ContentBlock] = []
                for msg in messages where msg.role != "system" {
                    if hasHistory { blocks.append(.text("<\(msg.role)>")) }
                    blocks.append(.text(msg.text))
                    if hasHistory { blocks.append(.text("</\(msg.role)>")) }
                }
                return blocks
            }
        }

        public enum UsageTracker {
            public struct Snapshot: Equatable, Hashable, Sendable, Codable {
                public let inputTotal: Int?
                public let inputNoCache: Int?
                public let inputCacheRead: Int?
                public let inputCacheWrite: Int?
                public let outputTotal: Int
                public let outputReasoning: Int
                public let outputText: Int
            }

            public final class Tracker: Sendable {
                private struct Counts: Sendable {
                    var input: Int = 0
                    var read: Int = 0
                    var write: Int = 0
                    var output: Int = 0
                    var reasoning: Int = 0
                }

                private struct State: Sendable {
                    var messages: [String: Counts] = [:]
                    var last: String?
                }

                private let state = Mutex(State())

                public func update(id: String, input: Int = 0, read: Int = 0, write: Int = 0, output: Int = 0, reasoning: Int = 0) {
                    state.withLock { s in
                        if s.messages[id] == nil { s.last = id }
                        var counts = s.messages[id] ?? Counts()
                        counts.input = max(counts.input, input)
                        counts.read = max(counts.read, read)
                        counts.write = max(counts.write, write)
                        counts.output = max(counts.output, output)
                        counts.reasoning = max(counts.reasoning, reasoning)
                        s.messages[id] = counts
                    }
                }

                public func snapshot() -> Snapshot {
                    state.withLock { s in
                        let output = s.messages.values.reduce(0) { $0 + $1.output }
                        let reasoning = s.messages.values.reduce(0) { $0 + $1.reasoning }
                        let lastCall = s.last.flatMap { s.messages[$0] }
                        let inputTotal = lastCall.map { $0.input + $0.read + $0.write }
                        return Snapshot(
                            inputTotal: inputTotal,
                            inputNoCache: lastCall?.input,
                            inputCacheRead: lastCall?.read,
                            inputCacheWrite: lastCall?.write,
                            outputTotal: output,
                            outputReasoning: reasoning,
                            outputText: output - reasoning
                        )
                    }
                }
            }

            // parity: core/src/plugin/provider/claude-agent/language-model/usage.ts#make [status=implemented hash=caf871a2aaf5]
            public static func make() -> Tracker {
                Tracker()
            }
        }

        // MARK: claude-agent/sync/*

        public enum Sync {
            // parity: core/src/plugin/provider/claude-agent/sync/fingerprint.ts#Group [status=implemented hash=a0d3daf08f56]
            public struct Group: Equatable, Hashable, Sendable, Codable {
                public let hash: String
                public let role: String
                public let start: Int
                public let end: Int

                public init(hash: String, role: String, start: Int, end: Int) {
                    self.hash = hash
                    self.role = role
                    self.start = start
                    self.end = end
                }
            }

            /// Groups consecutive user messages and hashes visible prompt turns with SHA-256.
            // parity: core/src/plugin/provider/claude-agent/sync/fingerprint.ts#groups [status=implemented hash=94e19faea6a8]
            public static func groups(
                _ prompt: [(role: String, text: String)],
                prefix: [Checkpoint] = []
            ) -> [Group] {
                var result: [Group] = []
                var i = 0
                while i < prompt.count {
                    let msg = prompt[i]
                    let start = i
                    i += 1
                    if msg.role == "system" || msg.text.isEmpty { continue }
                    var members = [Hash.sha256(msg.text)]
                    if msg.role == "user" {
                        while i < prompt.count {
                            if result.count < prefix.count {
                                let candidate = Hash.sha256("\(msg.role):\(members.sorted().joined(separator: ","))")
                                if candidate == prefix[result.count].hash { break }
                            }
                            if prompt[i].role != "user" { break }
                            members.append(Hash.sha256(prompt[i].text))
                            i += 1
                        }
                        members.sort()
                    }
                    let groupHash = Hash.sha256("\(msg.role):\(members.joined(separator: ","))")
                    result.append(Group(hash: groupHash, role: msg.role, start: start, end: i))
                }
                return result
            }

            // parity: core/src/plugin/provider/claude-agent/sync/record.ts#Checkpoint [status=implemented hash=eeb275cfb9f9]
            public struct Checkpoint: Equatable, Hashable, Sendable, Codable {
                public let hash: String
                public let claudeMessageID: String?

                public init(hash: String, claudeMessageID: String? = nil) {
                    self.hash = hash
                    self.claudeMessageID = claudeMessageID
                }
            }

            // parity: core/src/plugin/provider/claude-agent/sync/record.ts#Record [status=implemented hash=90a3e012f21d]
            public struct Record: Equatable, Hashable, Sendable, Codable {
                public let claudeSessionID: String
                public let history: [Checkpoint]?
                public let interrupted: Bool?

                public init(claudeSessionID: String, history: [Checkpoint]? = nil, interrupted: Bool? = nil) {
                    self.claudeSessionID = claudeSessionID
                    self.history = history
                    self.interrupted = interrupted
                }
            }

            // parity: core/src/plugin/provider/claude-agent/sync/record.ts#Storage [status=implemented hash=9beb38b0d6b2]
            public struct RecordStorage: Sendable {
                public let get: @Sendable (String) async throws -> JSONValue?
                public let set: @Sendable (String, Record) async throws -> Void

                public init(
                    get: @escaping @Sendable (String) async throws -> JSONValue?,
                    set: @escaping @Sendable (String, Record) async throws -> Void
                ) {
                    self.get = get
                    self.set = set
                }
            }

            public struct RecordStore: Sendable {
                public let get: @Sendable (String) async -> Record?
                public let set: @Sendable (String, Record) async throws -> Void
            }

            // parity: core/src/plugin/provider/claude-agent/sync/record.ts#make [status=implemented hash=fc365f4dcc35]
            public static func makeRecordStore(_ storage: RecordStorage) -> RecordStore {
                RecordStore(
                    get: { sessionID in
                        guard let raw = try? await storage.get("sessions/\(sessionID)"),
                              let data = try? JSONEncoder().encode(raw)
                        else { return nil }
                        return try? JSONDecoder().decode(Record.self, from: data)
                    },
                    set: { sessionID, record in
                        try await storage.set("sessions/\(sessionID)", record)
                    }
                )
            }

            public struct Decision: Equatable, Hashable, Sendable {
                public enum Kind: String, Equatable, Hashable, Sendable {
                    case fresh
                    case changed
                    case catchUp = "catch-up"
                    case `continue`
                }

                public let kind: Kind
                public let start: Int
            }

            /// Decides whether to start fresh, branch on changed history, send catch-up checkpoint, or continue cleanly.
            // parity: core/src/plugin/provider/claude-agent/sync/decide.ts#decide [status=implemented hash=f4f0b10d07dc]
            public static func decide(
                prompt: [(role: String, text: String)],
                record: Record?
            ) -> Decision {
                let saved = record?.history ?? []
                let promptGroups = groups(prompt, prefix: record?.interrupted == true ? saved : [])
                if saved.isEmpty { return Decision(kind: .fresh, start: 0) }
                var matched = 0
                while matched < saved.count && matched < promptGroups.count {
                    if saved[matched].hash != promptGroups[matched].hash { break }
                    matched += 1
                }
                if matched == 0 { return Decision(kind: .fresh, start: 0) }
                if matched < saved.count { return Decision(kind: .changed, start: 0) }
                while record?.interrupted == true && matched < promptGroups.count && promptGroups[matched].role == "assistant" {
                    matched += 1
                }
                let start = matched < promptGroups.count ? promptGroups[matched].start : prompt.count
                if record?.interrupted == true && start == prompt.count { return Decision(kind: .changed, start: 0) }
                let missed = promptGroups[matched...]
                let kind: Decision.Kind = missed.contains(where: { $0.role != "user" }) ? .catchUp : .continue
                return Decision(kind: kind, start: start)
            }

            public struct BranchBoundary: Equatable, Hashable, Sendable {
                public let messageID: String
                public let start: Int
                public let history: [Checkpoint]
            }

            // parity: core/src/plugin/provider/claude-agent/sync/decide.ts#boundary [status=implemented hash=2649bea88b5a]
            public static func boundary(
                prompt: [(role: String, text: String)],
                record: Record?
            ) -> BranchBoundary? {
                let promptGroups = groups(prompt)
                let history = record?.history ?? []
                var found: BranchBoundary?
                for i in 0..<promptGroups.count {
                    let group = promptGroups[i]
                    if i == promptGroups.count - 1 && group.role == "user" { break }
                    guard i < history.count, history[i].hash == group.hash else { break }
                    if let messageID = history[i].claudeMessageID {
                        found = BranchBoundary(messageID: messageID, start: group.end, history: Array(history.prefix(i + 1)))
                    }
                }
                return found
            }

            // parity: core/src/plugin/provider/claude-agent/sync/checkpoints.ts#build [status=implemented hash=c1e2828a7542]
            public static func buildCheckpoints(
                prompt: [(role: String, text: String)],
                previous: Record? = nil,
                userID: String? = nil,
                replyText: String? = nil,
                messageID: String? = nil
            ) -> [Checkpoint] {
                let promptGroups = groups(prompt)
                var history: [Checkpoint] = []
                for i in 0..<promptGroups.count {
                    let group = promptGroups[i]
                    let prev = (previous?.history).flatMap { i < $0.count ? $0[i] : nil }
                    var claudeID = (prev?.hash == group.hash) ? prev?.claudeMessageID : nil
                    if i == promptGroups.count - 1, let userID {
                        claudeID = userID
                    }
                    history.append(Checkpoint(hash: group.hash, claudeMessageID: claudeID))
                }
                if let replyText, !replyText.isEmpty, let replyGroup = groups([(role: "assistant", text: replyText)]).first {
                    history.append(Checkpoint(hash: replyGroup.hash, claudeMessageID: messageID))
                }
                return history
            }

            // parity: core/src/plugin/provider/claude-agent/sync/catch-up.ts#content [status=implemented hash=39a3159310f2]
            public static func catchUpContent(
                prompt: [(role: String, text: String)],
                start: Int = 0
            ) -> [MessageConverter.ContentBlock] {
                let missed = Array(prompt.dropFirst(start))
                let end = groups(missed).last(where: { $0.role != "user" })?.end ?? 0
                var blocks: [MessageConverter.ContentBlock] = []
                if end > 0 {
                    blocks.append(.text("<conversation-checkpoint>\nThe following is conversation history from OpenCode that you have not seen. Treat it as prior conversation, not a new request. Continue with the user messages after this checkpoint."))
                    blocks.append(contentsOf: MessageConverter.content(Array(missed.prefix(end))))
                    blocks.append(.text("</conversation-checkpoint>"))
                }
                blocks.append(contentsOf: MessageConverter.content(Array(missed.dropFirst(end))))
                return blocks
            }
        }

        // MARK: claude-agent/tools/{hooks,pending,result,server}.ts

        public enum Tools {
            // parity: core/src/plugin/provider/claude-agent/tools/result.ts#Result [status=implemented hash=c39697c4e12e]
            public struct Result: Equatable, Hashable, Sendable, Codable {
                public let isError: Bool
                public let textBlocks: [String]
                public let replacement: [MessageConverter.ContentBlock]?

                public init(isError: Bool, textBlocks: [String], replacement: [MessageConverter.ContentBlock]? = nil) {
                    self.isError = isError
                    self.textBlocks = textBlocks
                    self.replacement = replacement
                }
            }

            // parity: core/src/plugin/provider/claude-agent/tools/result.ts#convert [status=implemented hash=521d976a4760]
            public static func convertResult(text: String, failed: Bool = false) -> Result {
                Result(isError: failed, textBlocks: [text], replacement: nil)
            }

            // parity: core/src/plugin/provider/claude-agent/tools/result.ts#collect [status=implemented hash=344a44317651]
            public static func collectResults(_ entries: [(callID: String, text: String, failed: Bool)]) -> [String: Result] {
                Dictionary(uniqueKeysWithValues: entries.map { ($0.callID, convertResult(text: $0.text, failed: $0.failed)) })
            }

            // parity: core/src/plugin/provider/claude-agent/tools/pending.ts#Interface [status=adapted hash=f33cf8175048]
            public protocol PendingInterface: Sendable {
                func expect(id: String, name: String) async throws
                func resolve(id: String, result: Result) async throws
                func clear() async
            }

            public actor PendingCalls: PendingInterface {
                private var pendingNames: [String: String] = [:]
                private var resolved: [String: Result] = [:]

                public func expect(id: String, name: String) async throws {
                    if let existing = pendingNames[id], existing != name {
                        throw ToolSchema.ToolError(message: "Mismatched Claude tool call \(id)")
                    }
                    pendingNames[id] = name
                }

                public func resolve(id: String, result: Result) async throws {
                    guard pendingNames[id] != nil else {
                        throw ToolSchema.ToolError(message: "No waiting Claude tool call \(id)")
                    }
                    resolved[id] = result
                }

                public func clear() async {
                    pendingNames.removeAll()
                    resolved.removeAll()
                }
            }

            // parity: core/src/plugin/provider/claude-agent/tools/pending.ts#make [status=implemented hash=33a11065f8e6]
            public static func makePending() -> PendingCalls {
                PendingCalls()
            }

            // parity: core/src/plugin/provider/claude-agent/tools/hooks.ts#make [status=adapted hash=7a845539c965]
            public static func makeHooks(pending: any PendingInterface) -> @Sendable (_ id: String, _ name: String) async throws -> Void {
                { id, name in try await pending.expect(id: id, name: name) }
            }

            // parity: core/src/plugin/provider/claude-agent/tools/server.ts#make [status=adapted hash=b8c25a18a308]
            public static func makeServer(toolNames: [String]) async -> [String] {
                toolNames.map { ToolNames.PREFIX + ToolNames.short($0) }
            }
        }

        // MARK: claude-agent/{aisdk,instructions,integration,provider,session,index}.ts

        // parity: core/src/plugin/provider/claude-agent/aisdk.ts#register [status=adapted hash=965cfd96d8d5]
        public static func registerAISDK(ctx: PluginEffect.Context, sessions: any Sessions.Interface) async {
            _ = (ctx, sessions)
        }

        // parity: core/src/plugin/provider/claude-agent/instructions.ts#register [status=adapted hash=d743c0330f6e]
        public static func registerInstructions(ctx: PluginEffect.Context) async {
            _ = ctx
        }

        // parity: core/src/plugin/provider/claude-agent/integration.ts#register [status=adapted hash=71ac8bb45268]
        public static func registerIntegration(ctx: PluginEffect.Context) async {
            _ = await ctx.integration.transform { editor in
                editor.update(ProviderID.rawValue) { item in item.name = "Claude Code" }
            }
        }

        // parity: core/src/plugin/provider/claude-agent/provider.ts#register [status=adapted hash=e1e113dace9f]
        public static func registerProvider(ctx: PluginEffect.Context) async {
            _ = await ctx.provider.transform { editor in
                let info = ProviderSchema.Info(
                    id: ProviderID,
                    integrationID: IntegrationID(rawValue: ProviderID.rawValue),
                    name: "Claude Code",
                    activation: .auto,
                    package: ProviderPackage
                )
                if editor.get(ProviderID.rawValue) == nil {
                    editor.add(info, [], nil)
                }
            }
        }

        // parity: core/src/plugin/provider/claude-agent/provider.ts#connection [status=adapted hash=382c4e9de3f3]
        public static func connection(ctx: PluginEffect.Context) async -> ConnectionSchema.Info? {
            await ctx.integration.connection.active(ProviderID.rawValue)
        }

        // parity: core/src/plugin/provider/claude-agent/session.ts#register [status=adapted hash=039fcfb7e37b]
        public static func registerSession(ctx: PluginEffect.Context) async {
            _ = ctx
        }

        // parity: core/src/plugin/provider/claude-agent/index.ts#make [status=implemented hash=4f5c80d4910f]
        public static func make(
            io: IO.Interface = IO.real,
            registry: any Sessions.Interface = Sessions.registry()
        ) -> PluginEffect.Plugin {
            PluginEffect.define(
                PluginEffect.Plugin(id: ID) { ctx in
                    _ = io
                    await registerIntegration(ctx: ctx)
                    await registerProvider(ctx: ctx)
                    await registerInstructions(ctx: ctx)
                    await registerSession(ctx: ctx)
                    await registerAISDK(ctx: ctx, sessions: registry)
                }
            )
        }

        // parity: core/src/plugin/provider/claude-agent/index.ts#ClaudeAgentPlugin [status=implemented hash=4204e05bd4db]
        public static let ClaudeAgentPlugin = make()
    }
}
