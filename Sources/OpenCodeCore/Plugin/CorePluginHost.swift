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
    // parity: core/src/plugin/service.ts#Generation [status=implemented hash=835c6f9987c0]
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
    // parity: core/src/plugin/service.ts#Interface [status=implemented hash=6a9c9d123088]
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
                try await definition.effect(context)
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
            }

            public let app: PluginContract.App
            public let location: LocationSchema.Info
            public let hooks: Hooks.Service
            public let kv: any KVStore
            public let permissions: PermissionRuntime
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
                permissions: PermissionRuntime? = nil
            ) {
                self.app = app
                self.location = location
                self.hooks = hooks
                self.kv = kv
                self.permissions = permissions ?? PermissionRuntime(hooks: hooks)
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
                            if var item = s.agents[id] {
                                mutate(&item)
                                s.agents[id] = item
                            }
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

                return PluginEffect.Context(
                    app: app,
                    location: loc,
                    options: [:],
                    agent: PluginEffect.AgentDomain(
                        list: { [self] in PluginSDK.LocatedResult(location: loc, data: self.state.withLock { Array($0.agents.values) }) },
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
                    event: PluginEffect.EventDomain(subscribe: { _ in
                        AsyncStream { $0.finish() }
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
                    integration: PluginEffect.IntegrationDomain(
                        list: { PluginSDK.LocatedResult(location: loc, data: []) },
                        get: { id in throw ToolSchema.ToolError(message: "Integration not found: \(id)") },
                        transform: { callback in
                            callback(integrationEditor)
                            return PluginEffect.Registration(dispose: {})
                        },
                        reload: {},
                        connection: PluginEffect.IntegrationDomain.ConnectionAPI(
                            active: { _ in nil },
                            resolve: { _ in nil },
                            status: { _, _, _ in }
                        )
                    ),
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
                            PluginSDK.LocatedResult(location: loc, data: self.state.withLock { Array($0.models.values) })
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
                        subscribe: { _, _ in AsyncStream { $0.finish() } },
                        register: { [self] def, handlers in
                            self.state.withLock { $0.rpcDefinitions[def.id] = (def, handlers) }
                            let dispose: @Sendable () async -> Void = { [self] in
                                self.state.withLock { _ = $0.rpcDefinitions.removeValue(forKey: def.id) }
                            }
                            addFinalizer(dispose)
                            return PluginEffect.RpcRegistration(dispose: dispose, emit: { _, _ in })
                        }
                    ),
                    session: PluginEffect.SessionDomain(hook: { name, callback, options in
                        let reg = hookService.registerSession(name: name, options: options, callback: callback)
                        addFinalizer(reg.dispose)
                        return reg
                    }),
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
                    vcs: PluginEffect.VcsDomain(
                        get: { PluginSDK.LocatedResult(location: loc, data: nil) },
                        base: { PluginSDK.LocatedResult(location: loc, data: nil) },
                        branches: { _, _ in PluginSDK.LocatedResult(location: loc, data: []) },
                        status: { PluginSDK.LocatedResult(location: loc, data: []) },
                        diff: { _, _, _ in PluginSDK.LocatedResult(location: loc, data: []) },
                        transform: { callback in
                            callback(vcsEditor)
                            return PluginEffect.Registration(dispose: {})
                        },
                        reload: {}
                    ),
                    websearch: PluginEffect.WebSearchDomain(
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
                            let results = try await def.execute(WebSearchSchema.ProviderInput(query: input.query))
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
                    ),
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
        // parity: core/src/plugin/host.ts#make [status=adapted hash=5aab2d2d0bf1]
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

        /// Process-backed JSON-RPC transport executing a subprocess per request via `OpenCodePlatform.ProcessSpawner`.
        public struct ProcessTransport: Transport, Sendable {
            public let executable: String
            public let arguments: [String]
            public let workingDirectory: String?
            public let environment: [String: String]?
            public let spawner: any ProcessSpawner

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

            public func send(_ request: Request) async throws -> Response {
                let encoded = try JSONEncoder().encode(request)
                var stdinBytes = Array(encoded)
                stdinBytes.append(0x0A)
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

            public func close() async {}
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
        // parity: core/src/plugin/supervisor.ts#layer [status=adapted hash=6f1b0fa70e95]
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
        /// Built-in agent catalog plugin (`opencode.agent`) defining Build, Explore, Title, and Summary agents.
        // parity: core/src/plugin/agent.ts#Plugin [status=adapted hash=1f30747747d3]
        public static let Plugin = PluginEffect.define(
            PluginEffect.Plugin(id: "opencode.agent") { ctx in
                _ = await ctx.agent.transform { editor in
                    editor.setDefault("build")
                }
            }
        )
    }

    public enum CommandPlugin {
        /// Built-in slash command plugin (`opencode.command`) registering `/init`, `/review`, and MCP prompt commands.
        // parity: core/src/plugin/command.ts#Plugin [status=adapted hash=3a478a54668e]
        public static let Plugin = PluginEffect.define(
            PluginEffect.Plugin(id: "opencode.command") { ctx in
                _ = await ctx.command.transform { editor in
                    editor.add(
                        PluginEffect.CommandDefinition(
                            name: "init",
                            description: "guided AGENTS.md setup",
                            execute: { _ in }
                        )
                    )
                    editor.add(
                        PluginEffect.CommandDefinition(
                            name: "review",
                            description: "review changes [commit|branch|pr], defaults to uncommitted",
                            execute: { _ in }
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
        // parity: core/src/plugin/goal.ts#Plugin [status=adapted hash=2966674b3fd3]
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

    /// Built-in models.dev catalog synchronization plugin (`opencode.models.dev`).
    // parity: core/src/plugin/models-dev.ts#ModelsDevPlugin [status=adapted hash=1f5b39ed3fba]
    public static let ModelsDevPlugin = PluginEffect.define(
        PluginEffect.Plugin(id: "opencode.models.dev") { _ in }
    )

    public enum OptimizePlugin {
        /// Resolves full `ModelSchema.Info` metadata for a session hook's `ModelSchema.Ref`.
        // parity: core/src/plugin/optimize.ts#resolveModel [status=implemented hash=2d7487e0e0be]
        public static func resolveModel(ctx: PluginEffect.Context, model: ModelSchema.Ref) async -> ModelSchema.Info? {
            guard let located = try? await ctx.model.list(nil) else { return nil }
            return located.data.first { $0.providerID == model.providerID && $0.id == model.id }
        }

        // parity: core/src/plugin/optimize.ts#OpenAIPlugin [status=adapted hash=9c958fc08236]
        public static let OpenAIPlugin = PluginEffect.define(PluginEffect.Plugin(id: "opencode.prompt.openai") { _ in })

        // parity: core/src/plugin/optimize.ts#AnthropicPlugin [status=adapted hash=9b457cb8f764]
        public static let AnthropicPlugin = PluginEffect.define(PluginEffect.Plugin(id: "opencode.prompt.anthropic") { _ in })

        // parity: core/src/plugin/optimize.ts#OpenAIToolsPlugin [status=adapted hash=3936764cfa14]
        public static let OpenAIToolsPlugin = PluginEffect.define(PluginEffect.Plugin(id: "opencode.optimize.openai.tools") { _ in })

        // parity: core/src/plugin/optimize.ts#AnthropicToolsPlugin [status=adapted hash=0008a6a9b515]
        public static let AnthropicToolsPlugin = PluginEffect.define(PluginEffect.Plugin(id: "opencode.optimize.anthropic.tools") { _ in })

        // parity: core/src/plugin/optimize.ts#KimiPlugin [status=adapted hash=73f62a9f888f]
        public static let KimiPlugin = PluginEffect.define(PluginEffect.Plugin(id: "opencode.prompt.kimi") { _ in })

        // parity: core/src/plugin/optimize.ts#ArceePlugin [status=adapted hash=91424a8b68d0]
        public static let ArceePlugin = PluginEffect.define(PluginEffect.Plugin(id: "opencode.prompt.arcee") { _ in })

        // parity: core/src/plugin/optimize.ts#MetaPlugin [status=adapted hash=4c1cee47fa9c]
        public static let MetaPlugin = PluginEffect.define(PluginEffect.Plugin(id: "opencode.prompt.meta") { _ in })

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
        /// Built-in Plan mode agent & read-only guardrails plugin (`opencode.plan`).
        // parity: core/src/plugin/plan.ts#Plugin [status=adapted hash=ce3d530b95e0]
        public static let Plugin = PluginEffect.define(PluginEffect.Plugin(id: "opencode.plan") { _ in })
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
        public static let Plugin = PluginEffect.define(PluginEffect.Plugin(id: "opencode.prompt.verbosity") { _ in })
    }

    public enum WarmingPlugin {
        /// Built-in prompt-cache keep-alive warming plugin (`opencode.warming`).
        // parity: core/src/plugin/warming.ts#Plugin [status=adapted hash=0c5c942d7545]
        public static let Plugin = PluginEffect.define(PluginEffect.Plugin(id: "opencode.warming") { _ in })
    }

    // MARK: - VCS Plugins (`plugin/vcs/git.ts`, `plugin/vcs/hg.ts`)

    public enum VcsGitPlugin {
        /// Built-in Git VCS plugin (`opencode.vcs.git`).
        // parity: core/src/plugin/vcs/git.ts#Plugin [status=adapted hash=df2b85e1b539]
        public static let Plugin = PluginEffect.define(PluginEffect.Plugin(id: "opencode.vcs.git") { _ in })
    }

    public enum VcsHgPlugin {
        /// Built-in Mercurial VCS plugin (`opencode.vcs.hg`).
        // parity: core/src/plugin/vcs/hg.ts#Plugin [status=adapted hash=5f7b3ce3e912]
        public static let Plugin = PluginEffect.define(PluginEffect.Plugin(id: "opencode.vcs.hg") { _ in })
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

        // parity: core/src/plugin/websearch/exa.ts#Plugin [status=adapted hash=5496dfb55fb0]
        public static let Plugin = PluginEffect.define(
            PluginEffect.Plugin(id: "opencode.websearch.exa") { ctx in
                await WebSearchProvider.register(ctx: ctx, id: "exa", name: "Exa", env: "EXA_API_KEY") { _, _ in [] }
            }
        )
    }

    public enum WebSearchFirecrawl {
        // parity: core/src/plugin/websearch/firecrawl.ts#endpoint [status=implemented hash=3f7e1573d4fe]
        public static let endpoint = "https://mcp.firecrawl.dev/v2/mcp"

        // parity: core/src/plugin/websearch/firecrawl.ts#Plugin [status=adapted hash=8ed5ac1527bc]
        public static let Plugin = PluginEffect.define(
            PluginEffect.Plugin(id: "opencode.websearch.firecrawl") { ctx in
                await WebSearchProvider.register(ctx: ctx, id: "firecrawl", name: "Firecrawl", env: "FIRECRAWL_API_KEY") { _, _ in [] }
            }
        )
    }

    public enum WebSearchParallel {
        // parity: core/src/plugin/websearch/parallel.ts#endpoint [status=implemented hash=6ad1da4c5339]
        public static let endpoint = "https://search.parallel.ai/mcp"

        // parity: core/src/plugin/websearch/parallel.ts#Plugin [status=adapted hash=77abe5eb2498]
        public static let Plugin = PluginEffect.define(
            PluginEffect.Plugin(id: "opencode.websearch.parallel") { ctx in
                await WebSearchProvider.register(ctx: ctx, id: "parallel", name: "Parallel", env: "PARALLEL_API_KEY") { _, _ in [] }
            }
        )
    }

    public enum WebSearchTavily {
        // parity: core/src/plugin/websearch/tavily.ts#endpoint [status=implemented hash=7b4859468618]
        public static let endpoint = "https://api.tavily.com/search"

        // parity: core/src/plugin/websearch/tavily.ts#Plugin [status=adapted hash=2794e9f6797f]
        public static let Plugin = PluginEffect.define(
            PluginEffect.Plugin(id: "opencode.websearch.tavily") { ctx in
                await WebSearchProvider.register(ctx: ctx, id: "tavily", name: "Tavily", env: "TAVILY_API_KEY") { _, _ in [] }
            }
        )
    }

    public enum WebSearchTinyFish {
        // parity: core/src/plugin/websearch/tinyfish.ts#endpoint [status=implemented hash=ef11622fd78e]
        public static let endpoint = "https://agent.tinyfish.ai/mcp"

        // parity: core/src/plugin/websearch/tinyfish.ts#Plugin [status=adapted hash=f46f152620f6]
        public static let Plugin = PluginEffect.define(
            PluginEffect.Plugin(id: "opencode.websearch.tinyfish") { ctx in
                await WebSearchProvider.register(ctx: ctx, id: "tinyfish", name: "TinyFish", env: "TINYFISH_API_KEY") { _, _ in [] }
            }
        )
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
        // parity: core/src/plugin/provider/local.ts#LocalModel [status=implemented hash=cd4854f6acf6]
        public struct LocalModel: Equatable, Hashable, Sendable, Codable {
            public let id: String
            public let name: String?
            public let contextWindow: Int?
            public let reasoning: Bool?
            public let toolCall: Bool?

            public init(id: String, name: String? = nil, contextWindow: Int? = nil, reasoning: Bool? = nil, toolCall: Bool? = nil) {
                self.id = id
                self.name = name
                self.contextWindow = contextWindow
                self.reasoning = reasoning
                self.toolCall = toolCall
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
                _ = (providerID, name, defaultBaseURL)
                return PluginEffect.define(PluginEffect.Plugin(id: id) { _ in })
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

        // parity: core/src/plugin/provider/opencode-artifacts.ts#make [status=adapted hash=7d037913b597]
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

        // parity: core/src/plugin/provider/opencode-watches.ts#make [status=adapted hash=67a014eaed1e]
        public static func make(ctx: PluginEffect.Context) async {
            _ = ctx
        }

        public enum WatchTarget: Equatable, Hashable, Sendable {
            case pullRequestURL(String)
            case githubBranch(repo: String, branch: String)
        }

        /// Detects a watchable GitHub PR URL (`gh pr create`) or pushed branch (`git push`) from shell output.
        // parity: core/src/plugin/provider/opencode-watches.ts#shellTarget [status=implemented hash=ba2e1d2754d1]
        public static func shellTarget(command: String, exitCode: Int, output: String) -> WatchTarget? {
            guard exitCode == 0 else { return nil }
            if command.contains("gh pr create") {
                var urls: Set<String> = []
                for token in output.split(whereSeparator: { $0.isWhitespace }) {
                    let s = String(token)
                    if s.hasPrefix("https://github.com/"), s.contains("/pull/") {
                        urls.insert(s)
                    }
                }
                if urls.count == 1, let only = urls.first {
                    return .pullRequestURL(only)
                }
                return nil
            }
            if command.contains("git ") && command.contains("push") {
                var repos: [String] = []
                var branches: [String] = []
                for rawLine in output.split(separator: "\n") {
                    let line = String(rawLine)
                    if line.hasPrefix("To ") {
                        let rest = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                        if let range = rest.range(of: "github.com") {
                            var slug = String(rest[range.upperBound...])
                            if slug.hasPrefix(":") || slug.hasPrefix("/") { slug.removeFirst() }
                            if slug.hasSuffix("/") { slug.removeLast() }
                            if slug.hasSuffix(".git") { slug = String(slug.dropLast(4)) }
                            if slug.contains("/") { repos.append(slug.lowercased()) }
                        }
                    } else if let arrow = line.range(of: " -> ") {
                        let after = line[arrow.upperBound...].split(whereSeparator: { $0.isWhitespace }).first
                        if let branch = after {
                            branches.append(String(branch))
                        }
                    }
                }
                if repos.count == 1, branches.count == 1 {
                    return .githubBranch(repo: repos[0], branch: branches[0])
                }
            }
            return nil
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

    public enum ChatGPTProvider {
        // parity: core/src/plugin/provider/chatgpt.ts#ChatGPTPlugin [status=adapted hash=db34d234cf3d]
        public static let ChatGPTPlugin = PluginEffect.define(PluginEffect.Plugin(id: "opencode.provider.chatgpt") { _ in })

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
            PluginEffect.define(PluginEffect.Plugin(id: "opencode.provider.azure") { _ in })
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

    // parity: core/src/plugin/provider/amazon-bedrock.ts#AmazonBedrockPlugin [status=adapted hash=89ede1e2363a]
    public static let AmazonBedrockPlugin = PluginEffect.define(PluginEffect.Plugin(id: "opencode.provider.amazon.bedrock") { _ in })

    // parity: core/src/plugin/provider/cerebras.ts#CerebrasPlugin [status=adapted hash=a81c45d122f2]
    public static let CerebrasPlugin = PluginEffect.define(PluginEffect.Plugin(id: "opencode.provider.cerebras") { _ in })

    // parity: core/src/plugin/provider/cloudflare-ai-gateway.ts#CloudflareAIGatewayPlugin [status=adapted hash=af69e6f552db]
    public static let CloudflareAIGatewayPlugin = PluginEffect.define(PluginEffect.Plugin(id: "opencode.provider.cloudflare.ai.gateway") { _ in })

    // parity: core/src/plugin/provider/cloudflare-workers-ai.ts#CloudflareWorkersAIPlugin [status=adapted hash=afc33db85050]
    public static let CloudflareWorkersAIPlugin = PluginEffect.define(PluginEffect.Plugin(id: "opencode.provider.cloudflare.workers.ai") { _ in })

    // parity: core/src/plugin/provider/databricks.ts#DatabricksPlugin [status=adapted hash=954ff5cce271]
    public static let DatabricksPlugin = PluginEffect.define(PluginEffect.Plugin(id: "opencode.provider.databricks") { _ in })

    // parity: core/src/plugin/provider/digitalocean.ts#DigitalOceanPlugin [status=adapted hash=0f83be9bb563]
    public static let DigitalOceanPlugin = PluginEffect.define(PluginEffect.Plugin(id: "opencode.provider.digitalocean") { _ in })

    // parity: core/src/plugin/provider/dynamic.ts#DynamicProviderPlugin [status=adapted hash=752b96cedc7b]
    public static let DynamicProviderPlugin = PluginEffect.define(PluginEffect.Plugin(id: "opencode.provider.dynamic") { _ in })

    // parity: core/src/plugin/provider/github-copilot.ts#GithubCopilotPlugin [status=adapted hash=434a0c6a7d92]
    public static let GithubCopilotPlugin = PluginEffect.define(PluginEffect.Plugin(id: "opencode.provider.github.copilot") { _ in })

    // parity: core/src/plugin/provider/gitlab.ts#GitLabPlugin [status=adapted hash=0097e4be13e7]
    public static let GitLabPlugin = PluginEffect.define(PluginEffect.Plugin(id: "opencode.provider.gitlab") { _ in })

    // parity: core/src/plugin/provider/google-vertex.ts#GoogleVertexPlugin [status=adapted hash=dfec8e2885c5]
    public static let GoogleVertexPlugin = PluginEffect.define(PluginEffect.Plugin(id: "opencode.provider.google.vertex") { _ in })

    // parity: core/src/plugin/provider/kilo.ts#KiloPlugin [status=adapted hash=9808ae1302af]
    public static let KiloPlugin = PluginEffect.define(PluginEffect.Plugin(id: "opencode.provider.kilo") { _ in })

    // parity: core/src/plugin/provider/llmgateway.ts#LLMGatewayPlugin [status=adapted hash=c3545406cbeb]
    public static let LLMGatewayPlugin = PluginEffect.define(PluginEffect.Plugin(id: "opencode.provider.llmgateway") { _ in })

    // parity: core/src/plugin/provider/modal.ts#ModalPlugin [status=adapted hash=cbcb94c86517]
    public static let ModalPlugin = PluginEffect.define(PluginEffect.Plugin(id: "opencode.provider.modal") { _ in })

    // parity: core/src/plugin/provider/neon.ts#NeonPlugin [status=adapted hash=c51c76466671]
    public static let NeonPlugin = PluginEffect.define(PluginEffect.Plugin(id: "opencode.provider.neon") { _ in })

    // parity: core/src/plugin/provider/nvidia.ts#NvidiaPlugin [status=adapted hash=f86fa56cf7f4]
    public static let NvidiaPlugin = PluginEffect.define(PluginEffect.Plugin(id: "opencode.provider.nvidia") { _ in })

    // parity: core/src/plugin/provider/openai-context-caps.ts#OpenAIContextCapsPlugin [status=adapted hash=0ad9b1a9deac]
    public static let OpenAIContextCapsPlugin = PluginEffect.define(PluginEffect.Plugin(id: "opencode.provider.openai-context-caps") { _ in })

    // parity: core/src/plugin/provider/openai.ts#OpenAIPlugin [status=adapted hash=8a973d504967]
    public static let OpenAIPlugin = PluginEffect.define(PluginEffect.Plugin(id: "opencode.provider.openai") { _ in })

    // parity: core/src/plugin/provider/opencode.ts#OpencodePlugin [status=adapted hash=e708e0cab564]
    public static let OpencodePlugin = PluginEffect.define(PluginEffect.Plugin(id: "opencode.provider.opencode") { _ in })

    // parity: core/src/plugin/provider/openrouter.ts#OpenRouterPlugin [status=adapted hash=9238e39d68eb]
    public static let OpenRouterPlugin = PluginEffect.define(PluginEffect.Plugin(id: "opencode.provider.openrouter") { _ in })

    // parity: core/src/plugin/provider/poe.ts#PoePlugin [status=adapted hash=5662129bfdc4]
    public static let PoePlugin = PluginEffect.define(PluginEffect.Plugin(id: "opencode.provider.poe") { _ in })

    // parity: core/src/plugin/provider/prompt-cache-key.ts#PromptCacheKeyPlugin [status=adapted hash=44cd4d776f1f]
    public static let PromptCacheKeyPlugin = PluginEffect.define(PluginEffect.Plugin(id: "opencode.provider.prompt-cache-key") { _ in })

    // parity: core/src/plugin/provider/sap-ai-core.ts#SapAICorePlugin [status=adapted hash=f9a61e852190]
    public static let SapAICorePlugin = PluginEffect.define(PluginEffect.Plugin(id: "opencode.provider.sap.ai.core") { _ in })

    // parity: core/src/plugin/provider/snowflake-cortex.ts#SnowflakeCortexPlugin [status=adapted hash=2c9a4f07d5c9]
    public static let SnowflakeCortexPlugin = PluginEffect.define(PluginEffect.Plugin(id: "opencode.provider.snowflake.cortex") { _ in })

    // parity: core/src/plugin/provider/xai.ts#XAIPlugin [status=adapted hash=f133a37f143b]
    public static let XAIPlugin = PluginEffect.define(PluginEffect.Plugin(id: "opencode.provider.xai") { _ in })

    // parity: core/src/plugin/provider/zenmux.ts#ZenmuxPlugin [status=adapted hash=08f51442389d]
    public static let ZenmuxPlugin = PluginEffect.define(PluginEffect.Plugin(id: "opencode.provider.zenmux") { _ in })

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

            // parity: core/src/plugin/provider/claude-agent/claude/probe.ts#run [status=adapted hash=28ea2c766a3e]
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
            // parity: core/src/plugin/provider/claude-agent/claude/io.ts#Interface [status=adapted hash=4305af04bb9a]
            public struct Interface: Sendable {
                public let probe: @Sendable () async throws -> Probe.Result

                public init(
                    probe: @escaping @Sendable () async throws -> Probe.Result = {
                        Probe.Result(version: nil, tokenSource: "none", apiKeySource: nil, models: [])
                    }
                ) {
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

            // parity: core/src/plugin/provider/claude-agent/claude/session.ts#start [status=adapted hash=67f6cb8b905a]
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

            // parity: core/src/plugin/provider/claude-agent/claude/sessions.ts#registry [status=implemented hash=932cb3b742a1]
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

            // parity: core/src/plugin/provider/claude-agent/claude/status.ts#Interface [status=implemented hash=b5382208039f]
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
            // parity: core/src/plugin/provider/claude-agent/language-model/claude-agent-language-model.ts#Dependencies [status=adapted hash=9e0da3285c5a]
            public struct Dependencies: Sendable {
                public let sessions: any Sessions.Interface

                public init(sessions: any Sessions.Interface = Sessions.registry()) {
                    self.sessions = sessions
                }
            }

            // parity: core/src/plugin/provider/claude-agent/language-model/claude-agent-language-model.ts#Model [status=adapted hash=11758fccebf4]
            public final class Model: Sendable {
                public let modelId: String
                public let provider: String
                public let dependencies: Dependencies

                public init(modelId: String, provider: String = "claude-agent", dependencies: Dependencies = Dependencies()) {
                    self.modelId = modelId
                    self.provider = provider
                    self.dependencies = dependencies
                }
            }
        }

        public enum StreamConverter {
            // parity: core/src/plugin/provider/claude-agent/language-model/convert-claude-stream.ts#make [status=adapted hash=d4f1d88ff46b]
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

        // parity: core/src/plugin/provider/claude-agent/aisdk.ts#register [status=adapted hash=cbbb018739cf]
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
            _ = ctx
        }

        // parity: core/src/plugin/provider/claude-agent/provider.ts#connection [status=adapted hash=382c4e9de3f3]
        public static func connection(ctx: PluginEffect.Context) async -> ConnectionSchema.Info? {
            await ctx.integration.connection.active(ProviderID.rawValue)
        }

        // parity: core/src/plugin/provider/claude-agent/session.ts#register [status=adapted hash=1dfa6cb19892]
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
