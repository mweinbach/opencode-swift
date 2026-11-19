import OpenTUICore
import OpenTUILayout
import Synchronization

/// Pure-Swift plugin registry, composable `SlotRenderable` / `CoreSlotRenderable` error boundaries,
/// managed slot lifecycle hooks, and runtime plugin specifier rewriting matching
/// `packages/core/src/plugins/{types,registry,core-slot}.ts` and
/// `packages/core/src/runtime-plugin{,-support,-support-configure}.ts`.

// MARK: - Core Plugin Types (`core/src/plugins/types.ts`)

/// Reference-type constraint for plugin host contexts (matches TS `PluginContext = object`).
// parity: core/src/plugins/types.ts#PluginContext [status=adapted hash=878748dcf412]
public typealias PluginContext = AnyObject

/// Default empty plugin context object when a host does not need custom context state.
public final class EmptyPluginContext: Sendable {
    public init() {}
}

/// Slot composition mode controlling how fallback and plugin nodes combine.
// parity: core/src/plugins/types.ts#SlotMode [status=implemented hash=9a4b5e5c44b5]
public enum SlotMode: String, Equatable, Hashable, Sendable, Codable {
    case append = "append"
    case replace = "replace"
    case singleWinner = "single_winner"

    /// Ergonomic alias for `.singleWinner`.
    public static var single: SlotMode { .singleWinner }
}

/// Lifecycle phase in which a plugin error occurred.
// parity: core/src/plugins/types.ts#PluginErrorPhase [status=implemented hash=0055cf7b3e36]
public enum PluginErrorPhase: String, Equatable, Hashable, Sendable, Codable {
    case setup = "setup"
    case render = "render"
    case dispose = "dispose"
    case errorPlaceholder = "error_placeholder"
}

/// Origin of a reported plugin error (`"registry"`, `"core"`, or custom host string).
// parity: core/src/plugins/types.ts#PluginErrorSource [status=implemented hash=9de1af3404fa]
public struct PluginErrorSource: RawRepresentable, Equatable, Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public static let registry: PluginErrorSource = "registry"
    public static let core: PluginErrorSource = "core"
}

/// Normalized error value captured inside a `PluginErrorEvent`.
public struct PluginErrorInfo: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public init(_ error: any Error) {
        if let info = error as? PluginErrorInfo {
            self = info
        } else {
            self.message = String(describing: error)
        }
    }

    public var description: String { message }
}

/// Recorded error event emitted by `SlotRegistry` and passed to failure placeholders.
// parity: core/src/plugins/types.ts#PluginErrorEvent [status=implemented hash=dbbda2eb944e]
public struct PluginErrorEvent: @unchecked Sendable {
    public let pluginId: String
    public let slot: String?
    public let phase: PluginErrorPhase
    public let source: PluginErrorSource
    public let error: any Error
    public let errorMessage: String
    public let timestamp: Double

    public init(
        pluginId: String,
        slot: String? = nil,
        phase: PluginErrorPhase,
        source: PluginErrorSource,
        error: any Error,
        timestamp: Double
    ) {
        self.pluginId = pluginId
        self.slot = slot
        self.phase = phase
        self.source = source
        self.error = error
        self.errorMessage = String(describing: error)
        self.timestamp = timestamp
    }
}

/// Input payload passed to `SlotRegistry.reportPluginError(_:)`.
// parity: core/src/plugins/types.ts#PluginErrorReport [status=implemented hash=2f496a113afb]
public struct PluginErrorReport {
    public var pluginId: String
    public var slot: String?
    public var phase: PluginErrorPhase
    public var source: PluginErrorSource?
    public var error: any Error

    public init(
        pluginId: String,
        slot: String? = nil,
        phase: PluginErrorPhase,
        source: PluginErrorSource? = nil,
        error: any Error
    ) {
        self.pluginId = pluginId
        self.slot = slot
        self.phase = phase
        self.source = source
        self.error = error
    }
}

/// Synchronous slot rendering closure mapping `(context, props)` to a rendered node.
// parity: core/src/plugins/types.ts#SlotRenderer [status=implemented hash=3758139d0cd0]
public typealias SlotRenderer<TNode, TProps, TContext: PluginContext> = (TContext, TProps) throws -> TNode

/// Plugin definition registered into a `SlotRegistry`.
// parity: core/src/plugins/types.ts#Plugin [status=implemented hash=2923bd5134f2]
public final class Plugin<TNode, TSlotName: Hashable, TProps, TContext: PluginContext> {
    public let id: String
    public var order: Int?
    public var setup: ((TContext, CliRenderer) throws -> Void)?
    public var dispose: (() throws -> Void)?
    public var slots: [TSlotName: SlotRenderer<TNode, TProps, TContext>]

    public init(
        id: String,
        order: Int? = nil,
        setup: ((TContext, CliRenderer) throws -> Void)? = nil,
        dispose: (() throws -> Void)? = nil,
        slots: [TSlotName: SlotRenderer<TNode, TProps, TContext>] = [:]
    ) {
        self.id = id
        self.order = order
        self.setup = setup
        self.dispose = dispose
        self.slots = slots
    }
}

/// Pair of owning plugin ID and resolved slot renderer returned by `SlotRegistry.resolveEntries(_:)`.
// parity: core/src/plugins/types.ts#ResolvedSlotRenderer [status=implemented hash=68ba6c93b467]
public struct ResolvedSlotRenderer<TNode, TProps, TContext: PluginContext> {
    public let id: String
    public let renderer: SlotRenderer<TNode, TProps, TContext>

    public init(id: String, renderer: @escaping SlotRenderer<TNode, TProps, TContext>) {
        self.id = id
        self.renderer = renderer
    }
}

// MARK: - Registry Errors & Options (`core/src/plugins/registry.ts`)

/// Errors thrown synchronously by `SlotRegistry` or `CoreSlotRenderable` contract violations.
public enum PluginRegistryError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    case duplicatePlugin(id: String)
    case mismatchedContext(key: String)
    case invalidSlotNode(String)
    case incompatibleRuntimePluginSupport(String)

    public var description: String {
        switch self {
        case .duplicatePlugin(let id):
            return "Plugin with id \"\(id)\" is already registered"
        case .mismatchedContext(let key):
            return "createSlotRegistry called with a different context for renderer key \"\(key)\". Reuse the original context object."
        case .invalidSlotNode(let message), .incompatibleRuntimePluginSupport(let message):
            return message
        }
    }
}

/// Configuration options for `SlotRegistry` error containment and retention.
// parity: core/src/plugins/registry.ts#SlotRegistryOptions [status=implemented hash=9a1a2a60eb7a]
public struct SlotRegistryOptions {
    public var onPluginError: ((PluginErrorEvent) -> Void)?
    public var debugPluginErrors: Bool?
    public var maxPluginErrors: Int?

    public init(
        onPluginError: ((PluginErrorEvent) -> Void)? = nil,
        debugPluginErrors: Bool? = nil,
        maxPluginErrors: Int? = nil
    ) {
        self.onPluginError = onPluginError
        self.debugPluginErrors = debugPluginErrors
        self.maxPluginErrors = maxPluginErrors
    }
}

// MARK: - SlotRegistry (`core/src/plugins/registry.ts`)

private let defaultDebugPluginErrors = false
private let defaultMaxPluginErrors = 100

internal enum CoreSlotOwnership: Equatable, Hashable, Sendable {
    case host
    case plugin
}

internal struct CoreSlotContributionMeta {
    let ownership: CoreSlotOwnership
    let managedSlot: Any?
}

/// Ordered, error-contained plugin registry supporting registration, dynamic priority ordering,
/// batched change notifications, and per-renderer teardown.
// parity: core/src/plugins/registry.ts#SlotRegistry [status=implemented hash=2f35591654f6]
public final class SlotRegistry<TNode, TSlotName: Hashable, TProps, TContext: PluginContext>: @unchecked Sendable {
    private final class RegisteredPlugin {
        let plugin: Plugin<TNode, TSlotName, TProps, TContext>
        let registrationOrder: Int
        var cachedOrder: Int
        var cachedId: String

        init(plugin: Plugin<TNode, TSlotName, TProps, TContext>, registrationOrder: Int) {
            self.plugin = plugin
            self.registrationOrder = registrationOrder
            self.cachedOrder = plugin.order ?? 0
            self.cachedId = plugin.id
        }
    }

    private struct ChangeListenerEntry {
        let id: UInt64
        let handler: () -> Void
    }

    private struct ErrorListenerEntry {
        let id: UInt64
        let handler: (PluginErrorEvent) -> Void
    }

    private var plugins: [RegisteredPlugin] = []
    private var sortedPluginsCache: [RegisteredPlugin]? = nil
    private var nextListenerId: UInt64 = 1
    private var listeners: [ChangeListenerEntry] = []
    private var errorListeners: [ErrorListenerEntry] = []
    private var pluginErrors: [PluginErrorEvent] = []
    private var registrationOrder: Int = 0
    private var batchDepth: Int = 0
    private var batchedNotify: Bool = false

    private let rendererInstance: CliRenderer
    private let hostContext: TContext

    private var debugPluginErrors: Bool
    private var maxPluginErrors: Int
    private var onPluginErrorCallback: ((PluginErrorEvent) -> Void)?

    internal var coreSlotMetadata: [String: [TSlotName: CoreSlotContributionMeta]] = [:]

    public init(renderer: CliRenderer, context: TContext, options: SlotRegistryOptions = SlotRegistryOptions()) {
        self.rendererInstance = renderer
        self.hostContext = context
        self.debugPluginErrors = options.debugPluginErrors ?? defaultDebugPluginErrors
        self.maxPluginErrors = max(0, options.maxPluginErrors ?? defaultMaxPluginErrors)
        self.onPluginErrorCallback = options.onPluginError
    }

    // parity: core/src/plugins/registry.ts#SlotRegistry.renderer [status=implemented hash=901c39fa365e]
    public var renderer: CliRenderer { rendererInstance }

    // parity: core/src/plugins/registry.ts#SlotRegistry.context [status=implemented hash=7e73d23a4ba6]
    public var context: TContext { hostContext }

    /// Updates error-handling options in place.
    // parity: core/src/plugins/registry.ts#SlotRegistry.configure [status=implemented hash=127ebdbe3f38]
    public func configure(_ options: SlotRegistryOptions) {
        if let debug = options.debugPluginErrors {
            self.debugPluginErrors = debug
        }
        if let maxErrors = options.maxPluginErrors {
            self.maxPluginErrors = max(0, maxErrors)
        }
        if let callback = options.onPluginError {
            self.onPluginErrorCallback = callback
        }
    }

    /// Registers `plugin`, invoking its optional `setup` hook inside an error boundary.
    /// Throws `PluginRegistryError.duplicatePlugin` if a plugin with the same `id` is already registered.
    // parity: core/src/plugins/registry.ts#SlotRegistry.register [status=implemented hash=3f6c7155aca9]
    @discardableResult
    public func register(_ plugin: Plugin<TNode, TSlotName, TProps, TContext>) throws(PluginRegistryError) -> () -> Void {
        if plugins.contains(where: { $0.plugin.id == plugin.id }) {
            throw .duplicatePlugin(id: plugin.id)
        }

        if let setup = plugin.setup {
            do {
                try setup(hostContext, rendererInstance)
            } catch {
                _ = reportPluginError(
                    PluginErrorReport(
                        pluginId: plugin.id,
                        phase: .setup,
                        source: .registry,
                        error: error
                    )
                )
                return {}
            }
        }

        let orderIndex = registrationOrder
        registrationOrder += 1
        plugins.append(RegisteredPlugin(plugin: plugin, registrationOrder: orderIndex))
        invalidateSortedPluginsCache()
        notifyListeners()

        let id = plugin.id
        return { [weak self] in
            _ = self?.unregister(id)
        }
    }

    /// Unregisters the plugin with `id`, running its `dispose` hook inside an error boundary.
    // parity: core/src/plugins/registry.ts#SlotRegistry.unregister [status=implemented hash=01fc8fca3359]
    @discardableResult
    public func unregister(_ id: String) -> Bool {
        guard let index = plugins.firstIndex(where: { $0.plugin.id == id }) else {
            return false
        }
        let entry = plugins.remove(at: index)
        coreSlotMetadata.removeValue(forKey: id)
        invalidateSortedPluginsCache()

        if let dispose = entry.plugin.dispose {
            do {
                try dispose()
            } catch {
                _ = reportPluginError(
                    PluginErrorReport(
                        pluginId: id,
                        phase: .dispose,
                        source: .registry,
                        error: error
                    )
                )
            }
        }

        notifyListeners()
        return true
    }

    /// Updates the priority `order` of a registered plugin and notifies subscribers if changed.
    // parity: core/src/plugins/registry.ts#SlotRegistry.updateOrder [status=implemented hash=9f8b15408d4e]
    @discardableResult
    public func updateOrder(_ id: String, order: Int) -> Bool {
        guard let entry = plugins.first(where: { $0.plugin.id == id }) else {
            return false
        }
        if (entry.plugin.order ?? 0) == order {
            return true
        }
        entry.plugin.order = order
        entry.cachedOrder = order
        invalidateSortedPluginsCache()
        notifyListeners()
        return true
    }

    /// Unregisters and disposes all registered plugins with error containment.
    // parity: core/src/plugins/registry.ts#SlotRegistry.clear [status=implemented hash=56246ec505b5]
    public func clear() {
        guard !plugins.isEmpty else { return }
        let snapshot = plugins
        plugins.removeAll()
        coreSlotMetadata.removeAll()
        invalidateSortedPluginsCache()

        for entry in snapshot {
            if let dispose = entry.plugin.dispose {
                do {
                    try dispose()
                } catch {
                    _ = reportPluginError(
                        PluginErrorReport(
                            pluginId: entry.plugin.id,
                            phase: .dispose,
                            source: .registry,
                            error: error
                        )
                    )
                }
            }
        }

        notifyListeners()
    }

    /// Subscribes to plugin registration, removal, and order changes; returns an unsubscribe closure.
    // parity: core/src/plugins/registry.ts#SlotRegistry.subscribe [status=implemented hash=87f2dbd3f04f]
    @discardableResult
    public func subscribe(_ listener: @escaping () -> Void) -> () -> Void {
        let id = nextListenerId
        nextListenerId &+= 1
        listeners.append(ChangeListenerEntry(id: id, handler: listener))
        return { [weak self] in
            self?.listeners.removeAll { $0.id == id }
        }
    }

    /// Subscribes to plugin error events; returns an unsubscribe closure.
    // parity: core/src/plugins/registry.ts#SlotRegistry.onPluginError [status=implemented hash=a8d5e490323b]
    @discardableResult
    public func onPluginError(_ listener: @escaping (PluginErrorEvent) -> Void) -> () -> Void {
        let id = nextListenerId
        nextListenerId &+= 1
        errorListeners.append(ErrorListenerEntry(id: id, handler: listener))
        return { [weak self] in
            self?.errorListeners.removeAll { $0.id == id }
        }
    }

    /// Coalesces multiple mutations into a single subscriber notification when the outermost batch exits.
    // parity: core/src/plugins/registry.ts#SlotRegistry.batch [status=implemented hash=eb2472c93a25]
    public func batch<T>(_ run: () throws -> T) rethrows -> T {
        batchDepth += 1
        defer {
            batchDepth -= 1
            if batchDepth == 0 && batchedNotify {
                batchedNotify = false
                flushListeners()
            }
        }
        return try run()
    }

    /// Returns all retained plugin error events (bounded by `maxPluginErrors`).
    // parity: core/src/plugins/registry.ts#SlotRegistry.getPluginErrors [status=implemented hash=406b0b2db114]
    public func getPluginErrors() -> [PluginErrorEvent] {
        pluginErrors
    }

    /// Clears the retained plugin error buffer.
    // parity: core/src/plugins/registry.ts#SlotRegistry.clearPluginErrors [status=implemented hash=80b9867c9837]
    public func clearPluginErrors() {
        pluginErrors.removeAll()
    }

    /// Records a plugin error, trims history to `maxPluginErrors`, and notifies error listeners.
    // parity: core/src/plugins/registry.ts#SlotRegistry.reportPluginError [status=implemented hash=c9edf87344e8]
    @discardableResult
    public func reportPluginError(_ report: PluginErrorReport) -> PluginErrorEvent {
        let event = PluginErrorEvent(
            pluginId: report.pluginId,
            slot: report.slot,
            phase: report.phase,
            source: report.source ?? .registry,
            error: report.error,
            timestamp: rendererInstance.clock.now()
        )

        pluginErrors.append(event)
        if pluginErrors.count > maxPluginErrors {
            pluginErrors.removeFirst(pluginErrors.count - maxPluginErrors)
        }

        let snapshotListeners = errorListeners
        for entry in snapshotListeners {
            entry.handler(event)
        }
        onPluginErrorCallback?(event)

        return event
    }

    /// Resolves all slot renderer closures for `slot` in deterministic priority order.
    // parity: core/src/plugins/registry.ts#SlotRegistry.resolve [status=implemented hash=62729053797b]
    public func resolve(_ slot: TSlotName) -> [SlotRenderer<TNode, TProps, TContext>] {
        resolveEntries(slot).map(\.renderer)
    }

    /// Resolves `(id, renderer)` entries for `slot` sorted by `(order, registrationOrder, id)`.
    // parity: core/src/plugins/registry.ts#SlotRegistry.resolveEntries [status=implemented hash=e6d88e2d5a3e]
    public func resolveEntries(_ slot: TSlotName) -> [ResolvedSlotRenderer<TNode, TProps, TContext>] {
        var result: [ResolvedSlotRenderer<TNode, TProps, TContext>] = []
        for entry in getSortedPlugins() {
            if let renderer = entry.plugin.slots[slot] {
                result.append(ResolvedSlotRenderer(id: entry.plugin.id, renderer: renderer))
            }
        }
        return result
    }

    /// Returns currently registered plugin IDs in sorted priority order.
    public var registeredPluginIds: [String] {
        getSortedPlugins().map(\.plugin.id)
    }

    private func getSortedPlugins() -> [RegisteredPlugin] {
        syncPluginSortMetadata()
        if let cached = sortedPluginsCache {
            return cached
        }
        let sorted = plugins.sorted { lhs, rhs in
            if lhs.cachedOrder != rhs.cachedOrder {
                return lhs.cachedOrder < rhs.cachedOrder
            }
            if lhs.registrationOrder != rhs.registrationOrder {
                return lhs.registrationOrder < rhs.registrationOrder
            }
            return lhs.cachedId < rhs.cachedId
        }
        sortedPluginsCache = sorted
        return sorted
    }

    private func syncPluginSortMetadata() {
        var hasChanges = false
        for entry in plugins {
            let nextOrder = entry.plugin.order ?? 0
            let nextId = entry.plugin.id
            if entry.cachedOrder != nextOrder || entry.cachedId != nextId {
                entry.cachedOrder = nextOrder
                entry.cachedId = nextId
                hasChanges = true
            }
        }
        if hasChanges {
            invalidateSortedPluginsCache()
        }
    }

    private func invalidateSortedPluginsCache() {
        sortedPluginsCache = nil
    }

    private func notifyListeners() {
        if batchDepth > 0 {
            batchedNotify = true
            return
        }
        flushListeners()
    }

    private func flushListeners() {
        let snapshot = listeners
        for entry in snapshot {
            entry.handler()
        }
    }
}

/// Alias matching the naming used across OpenTUI plugin host guides.
public typealias PluginRegistry = SlotRegistry

// MARK: - Per-Renderer SlotRegistry Store (`createSlotRegistry`)

private final class AnySlotRegistryBox: @unchecked Sendable {
    let context: AnyObject
    let registry: AnyObject
    let clearFn: () -> Void

    init(context: AnyObject, registry: AnyObject, clearFn: @escaping () -> Void) {
        self.context = context
        self.registry = registry
        self.clearFn = clearFn
    }
}

private final class RendererSlotRegistryStore: @unchecked Sendable {
    weak var renderer: CliRenderer?
    var registries: [String: AnySlotRegistryBox] = [:]

    init(renderer: CliRenderer) {
        self.renderer = renderer
    }
}

private let slotRegistriesByRenderer = Mutex<[ObjectIdentifier: RendererSlotRegistryStore]>([:])

private func getSlotRegistryStore(for renderer: CliRenderer) -> RendererSlotRegistryStore {
    let key = ObjectIdentifier(renderer)
    let (store, created) = slotRegistriesByRenderer.withLock { map -> (RendererSlotRegistryStore, Bool) in
        // Prune deallocated renderers opportunistically.
        map = map.filter { $0.value.renderer != nil }
        if let existing = map[key] {
            return (existing, false)
        }
        let createdStore = RendererSlotRegistryStore(renderer: renderer)
        map[key] = createdStore
        return (createdStore, true)
    }

    if created {
        _ = renderer.on(.destroy) {
            let removed = slotRegistriesByRenderer.withLock { map in
                map.removeValue(forKey: key)
            }
            if let removed {
                let boxes = Array(removed.registries.values)
                removed.registries.removeAll()
                for box in boxes {
                    box.clearFn()
                }
            }
        }
    }

    return store
}

/// Creates or retrieves a keyed `SlotRegistry` scoped to `renderer` that automatically clears on `renderer.destroy()`.
// parity: core/src/plugins/registry.ts#createSlotRegistry [status=implemented hash=7603cdefd1b2]
public func createSlotRegistry<TNode, TSlotName: Hashable, TProps, TContext: PluginContext>(
    renderer: CliRenderer,
    key: String,
    context: TContext,
    options: SlotRegistryOptions = SlotRegistryOptions()
) throws(PluginRegistryError) -> SlotRegistry<TNode, TSlotName, TProps, TContext> {
    let store = getSlotRegistryStore(for: renderer)
    if let existingBox = store.registries[key] {
        guard existingBox.context === context else {
            throw .mismatchedContext(key: key)
        }
        if let typed = existingBox.registry as? SlotRegistry<TNode, TSlotName, TProps, TContext> {
            typed.configure(options)
            return typed
        }
    }

    let created = SlotRegistry<TNode, TSlotName, TProps, TContext>(
        renderer: renderer,
        context: context,
        options: options
    )
    store.registries[key] = AnySlotRegistryBox(
        context: context,
        registry: created,
        clearFn: { created.clear() }
    )
    return created
}

// MARK: - Core Slot System (`core/src/plugins/core-slot.ts`)

/// Slot mode alias for core `Renderable` slots.
// parity: core/src/plugins/core-slot.ts#CoreSlotMode [status=implemented hash=0e0643c3b9ad]
public typealias CoreSlotMode = SlotMode

/// Specialized `SlotRegistry` whose slot renderers produce `Renderable` nodes.
// parity: core/src/plugins/core-slot.ts#CoreSlotRegistry [status=implemented hash=c69b49bf2cb0]
public typealias CoreSlotRegistry<TSlotName: Hashable, TContext: PluginContext, TData> =
    SlotRegistry<Renderable, TSlotName, TData, TContext>

/// Synchronous core slot renderer producing a `Renderable`.
// parity: core/src/plugins/core-slot.ts#CoreSlotRenderer [status=implemented hash=1dec1aa18fa9]
public typealias CoreSlotRenderer<TContext: PluginContext, TData> = (TContext, TData) throws -> Renderable

/// Plugin-owned slot contribution with explicit activation, deactivation, and disposal lifecycle hooks.
// parity: core/src/plugins/core-slot.ts#CoreManagedSlot [status=implemented hash=dc3642b01dec]
public struct CoreManagedSlot<TContext: PluginContext, TData> {
    public var render: CoreSlotRenderer<TContext, TData>
    public var onActivate: ((TContext) throws -> Void)?
    public var onDeactivate: ((TContext) throws -> Void)?
    public var onDispose: ((TContext) throws -> Void)?

    public init(
        render: @escaping CoreSlotRenderer<TContext, TData>,
        onActivate: ((TContext) throws -> Void)? = nil,
        onDeactivate: ((TContext) throws -> Void)? = nil,
        onDispose: ((TContext) throws -> Void)? = nil
    ) {
        self.render = render
        self.onActivate = onActivate
        self.onDeactivate = onDeactivate
        self.onDispose = onDispose
    }
}

/// Either a host-owned plain renderer closure or a plugin-owned `CoreManagedSlot`.
// parity: core/src/plugins/core-slot.ts#CoreSlotContribution [status=implemented hash=d7317e08f74e]
public enum CoreSlotContribution<TContext: PluginContext, TData> {
    case renderer(CoreSlotRenderer<TContext, TData>)
    case managed(CoreManagedSlot<TContext, TData>)
}

/// Core plugin descriptor registering one or more `CoreSlotContribution`s.
// parity: core/src/plugins/core-slot.ts#CorePlugin [status=implemented hash=cdab8cfb2110]
public struct CorePlugin<TSlotName: Hashable, TContext: PluginContext, TData> {
    public var id: String
    public var order: Int?
    public var setup: ((TContext, CliRenderer) throws -> Void)?
    public var dispose: (() throws -> Void)?
    public var slots: [TSlotName: CoreSlotContribution<TContext, TData>]

    public init(
        id: String,
        order: Int? = nil,
        setup: ((TContext, CliRenderer) throws -> Void)? = nil,
        dispose: (() throws -> Void)? = nil,
        slots: [TSlotName: CoreSlotContribution<TContext, TData>] = [:]
    ) {
        self.id = id
        self.order = order
        self.setup = setup
        self.dispose = dispose
        self.slots = slots
    }
}

/// Resolved `(id, renderer)` entry returned by `resolveCoreSlot`.
// parity: core/src/plugins/core-slot.ts#CoreResolvedSlotRenderer [status=implemented hash=d01467d9b34e]
public struct CoreResolvedSlotRenderer<TContext: PluginContext, TData> {
    public let id: String
    public let renderer: CoreSlotRenderer<TContext, TData>

    public init(id: String, renderer: @escaping CoreSlotRenderer<TContext, TData>) {
        self.id = id
        self.renderer = renderer
    }
}

/// Error-boundary placeholder builder invoked when a plugin fails during slot rendering.
// parity: core/src/plugins/core-slot.ts#CoreSlotFailurePlaceholder [status=implemented hash=32140960bc5a]
public typealias CoreSlotFailurePlaceholder<TContext: PluginContext> =
    (PluginErrorEvent, TContext) throws -> [Renderable]

/// Creates or retrieves the default `"core:slot-registry"` for `renderer`.
// parity: core/src/plugins/core-slot.ts#createCoreSlotRegistry [status=implemented hash=4620cdc72265]
public func createCoreSlotRegistry<TSlotName: Hashable, TContext: PluginContext, TData>(
    renderer: CliRenderer,
    context: TContext,
    options: SlotRegistryOptions = SlotRegistryOptions()
) throws(PluginRegistryError) -> CoreSlotRegistry<TSlotName, TContext, TData> {
    try createSlotRegistry(
        renderer: renderer,
        key: "core:slot-registry",
        context: context,
        options: options
    )
}

/// Registers a `CorePlugin` (handling both host-owned renderers and plugin-owned `CoreManagedSlot`s).
// parity: core/src/plugins/core-slot.ts#registerCorePlugin [status=implemented hash=f3718753aeab]
@discardableResult
public func registerCorePlugin<TSlotName: Hashable, TContext: PluginContext, TData>(
    in registry: CoreSlotRegistry<TSlotName, TContext, TData>,
    plugin: CorePlugin<TSlotName, TContext, TData>
) throws(PluginRegistryError) -> () -> Void {
    var wrappedSlots: [TSlotName: CoreSlotRenderer<TContext, TData>] = [:]
    var metaForPlugin: [TSlotName: CoreSlotContributionMeta] = [:]

    for (slotName, contribution) in plugin.slots {
        switch contribution {
        case .renderer(let fn):
            wrappedSlots[slotName] = fn
            metaForPlugin[slotName] = CoreSlotContributionMeta(ownership: .host, managedSlot: nil)
        case .managed(let managed):
            wrappedSlots[slotName] = managed.render
            metaForPlugin[slotName] = CoreSlotContributionMeta(ownership: .plugin, managedSlot: managed)
        }
    }

    let adapted = Plugin<Renderable, TSlotName, TData, TContext>(
        id: plugin.id,
        order: plugin.order,
        setup: plugin.setup,
        dispose: plugin.dispose,
        slots: wrappedSlots
    )
    registry.coreSlotMetadata[plugin.id] = metaForPlugin
    do {
        let unregister = try registry.register(adapted)
        if !registry.registeredPluginIds.contains(plugin.id) {
            registry.coreSlotMetadata.removeValue(forKey: plugin.id)
        }
        return unregister
    } catch {
        registry.coreSlotMetadata.removeValue(forKey: plugin.id)
        throw error
    }
}

/// Resolves all registered renderers for `slot` in deterministic priority order.
// parity: core/src/plugins/core-slot.ts#resolveCoreSlot [status=implemented hash=83f3dafcc3e2]
public func resolveCoreSlot<TSlotName: Hashable, TContext: PluginContext, TData>(
    in registry: CoreSlotRegistry<TSlotName, TContext, TData>,
    slot: TSlotName
) -> [CoreResolvedSlotRenderer<TContext, TData>] {
    registry.resolveEntries(slot).map { entry in
        CoreResolvedSlotRenderer(id: entry.id, renderer: entry.renderer)
    }
}

// MARK: - SlotRenderable / CoreSlotRenderable

/// Declarative options for constructing a `SlotRenderable` (`CoreSlotRenderable`).
// parity: core/src/plugins/core-slot.ts#SlotRenderableOptions [status=implemented hash=b52c1f74dd9c]
public struct SlotRenderableOptions<TSlotName: Hashable, TContext: PluginContext, TData> {
    public var renderable: RenderableOptions
    public var registry: CoreSlotRegistry<TSlotName, TContext, TData>
    public var name: TSlotName
    public var data: TData
    public var mode: CoreSlotMode
    public var fallback: (() -> [Renderable])?
    public var pluginFailurePlaceholder: CoreSlotFailurePlaceholder<TContext>?

    public init(
        renderable: RenderableOptions = RenderableOptions(),
        registry: CoreSlotRegistry<TSlotName, TContext, TData>,
        name: TSlotName,
        data: TData,
        mode: CoreSlotMode = .append,
        fallback: (() -> [Renderable])? = nil,
        pluginFailurePlaceholder: CoreSlotFailurePlaceholder<TContext>? = nil
    ) {
        self.renderable = renderable
        self.registry = registry
        self.name = name
        self.data = data
        self.mode = mode
        self.fallback = fallback
        self.pluginFailurePlaceholder = pluginFailurePlaceholder
    }
}

/// Scene-graph container `Renderable` that mounts plugin contributions for a named slot with
/// `.append`, `.replace`, and `.singleWinner` (`.single`) composition modes, fallback nodes,
/// managed slot lifecycle hooks, and per-plugin error boundaries.
// parity: core/src/plugins/core-slot.ts#SlotRenderable [status=implemented hash=728856e6920a]
public final class SlotRenderable<TSlotName: Hashable, TContext: PluginContext, TData>: Renderable, @unchecked Sendable {
    private struct ResolvedEntry {
        let id: String
        let renderer: CoreSlotRenderer<TContext, TData>
        let ownership: CoreSlotOwnership
        let managedSlot: CoreManagedSlot<TContext, TData>?
    }

    private final class SlotNodeState {
        var nodes: [Renderable]
        let ownership: CoreSlotOwnership
        let managedSlot: CoreManagedSlot<TContext, TData>?
        let dataRevision: UInt64

        init(
            nodes: [Renderable],
            ownership: CoreSlotOwnership,
            managedSlot: CoreManagedSlot<TContext, TData>?,
            dataRevision: UInt64
        ) {
            self.nodes = nodes
            self.ownership = ownership
            self.managedSlot = managedSlot
            self.dataRevision = dataRevision
        }
    }

    private var _mode: CoreSlotMode
    private let _slotRegistry: CoreSlotRegistry<TSlotName, TContext, TData>
    private let _slotName: TSlotName
    private var _data: TData
    private var _dataRevision: UInt64 = 1
    private let _fallbackBuilder: (() -> [Renderable])?
    private let _pluginFailurePlaceholder: CoreSlotFailurePlaceholder<TContext>?

    private var _disposed: Bool = false
    private var _mountedNodes: [Renderable] = []
    private var _pluginNodes: [String: SlotNodeState] = [:]
    private var _activePluginIds: Set<String> = []
    private var _fallbackNodes: [Renderable]? = nil
    private var _unsubscribe: (() -> Void)? = nil

    public init(
        ctx: any RenderContext,
        options: SlotRenderableOptions<TSlotName, TContext, TData>
    ) throws {
        self._slotRegistry = options.registry
        self._slotName = options.name
        self._data = options.data
        self._mode = options.mode
        self._fallbackBuilder = options.fallback
        self._pluginFailurePlaceholder = options.pluginFailurePlaceholder
        super.init(ctx: ctx, options: options.renderable)

        self._unsubscribe = self._slotRegistry.subscribe { [weak self] in
            try? self?.refresh()
        }

        do {
            try self.refresh()
        } catch {
            self.cleanupAll()
            throw error
        }
    }

    // parity: core/src/plugins/core-slot.ts#SlotRenderable.mode [status=implemented hash=bae7091ae40a]
    public var mode: CoreSlotMode {
        get { _mode }
        set {
            _mode = newValue
            try? refresh()
        }
    }

    // parity: core/src/plugins/core-slot.ts#SlotRenderable.data [status=implemented hash=22e7520ce9d5]
    public var data: TData {
        get { _data }
        set {
            _data = newValue
            _dataRevision &+= 1
            try? refresh()
        }
    }

    /// Re-resolves active plugin contributions, runs managed lifecycle hooks, enforces error boundaries,
    /// and reconciles mounted children in layout order.
    // parity: core/src/plugins/core-slot.ts#SlotRenderable.refresh [status=implemented hash=f584dedfbc52]
    public func refresh() throws {
        guard !_disposed else { return }

        let allEntries = resolveCoreSlotEntries()
        let activeEntries: [ResolvedEntry]
        if _mode == .singleWinner, let first = allEntries.first {
            activeEntries = [first]
        } else {
            activeEntries = allEntries
        }

        let nextActivePluginIds = Set(activeEntries.map(\.id))
        let registeredPluginIds = Set(allEntries.map(\.id))

        cleanupInactivePluginNodes(nextActiveIds: nextActivePluginIds, registeredIds: registeredPluginIds)

        for entry in activeEntries {
            var state = _pluginNodes[entry.id]
            let shouldRender = state == nil
                || (state!.ownership == .plugin && state!.nodes.isEmpty)
                || state!.dataRevision != _dataRevision

            if shouldRender {
                let previousState = state
                let newState: SlotNodeState
                do {
                    let node = try entry.renderer(_slotRegistry.context, _data)
                    try ensureValidNode(node, pluginId: entry.id)
                    newState = SlotNodeState(
                        nodes: [node],
                        ownership: entry.ownership,
                        managedSlot: entry.managedSlot ?? previousState?.managedSlot,
                        dataRevision: _dataRevision
                    )
                } catch {
                    let failure = _slotRegistry.reportPluginError(
                        PluginErrorReport(
                            pluginId: entry.id,
                            slot: String(describing: _slotName),
                            phase: .render,
                            source: .core,
                            error: error
                        )
                    )
                    newState = SlotNodeState(
                        nodes: resolvePluginFailurePlaceholder(failure),
                        ownership: .host,
                        managedSlot: entry.managedSlot ?? previousState?.managedSlot,
                        dataRevision: _dataRevision
                    )
                }

                if let previousState {
                    cleanupReplacedPluginNodes(previousState: previousState, nextNodes: newState.nodes)
                }

                _pluginNodes[entry.id] = newState
                state = newState
            }

            if !_activePluginIds.contains(entry.id), let activeState = state {
                callManagedHook(
                    pluginId: entry.id,
                    managedSlot: activeState.managedSlot,
                    phase: .setup,
                    hook: { $0.onActivate }
                )
            }
        }

        var desiredNodes: [Renderable] = []

        if _mode == .append || activeEntries.isEmpty {
            desiredNodes.append(contentsOf: try ensureFallbackNodes())
        }

        for entry in activeEntries {
            if let state = _pluginNodes[entry.id] {
                desiredNodes.append(contentsOf: state.nodes)
            }
        }

        if _mode != .append && desiredNodes.isEmpty {
            desiredNodes.append(contentsOf: try ensureFallbackNodes())
        }

        reconcileMountedNodes(desiredNodes)
        _activePluginIds = nextActivePluginIds
    }

    public override func destroySelf() {
        cleanupAll()
    }

    private func resolveCoreSlotEntries() -> [ResolvedEntry] {
        _slotRegistry.resolveEntries(_slotName).map { entry in
            let meta = _slotRegistry.coreSlotMetadata[entry.id]?[_slotName]
            let managed = meta?.managedSlot as? CoreManagedSlot<TContext, TData>
            return ResolvedEntry(
                id: entry.id,
                renderer: entry.renderer,
                ownership: meta?.ownership ?? .host,
                managedSlot: managed
            )
        }
    }

    private func ensureValidNode(_ node: Renderable, pluginId: String) throws(PluginRegistryError) {
        if node === self {
            throw .invalidSlotNode("Plugin \"\(pluginId)\" returned the slot mount container as its node")
        }
        if let parent = node.parent, parent !== self {
            throw .invalidSlotNode("Plugin \"\(pluginId)\" returned a renderable already attached to another parent")
        }
    }

    private func ensureFallbackNodes() throws -> [Renderable] {
        if let cached = _fallbackNodes {
            return cached
        }
        let nodes = _fallbackBuilder?() ?? []
        for node in nodes {
            try ensureValidNode(node, pluginId: "fallback")
        }
        _fallbackNodes = nodes
        return nodes
    }

    private func callManagedHook(
        pluginId: String,
        managedSlot: CoreManagedSlot<TContext, TData>?,
        phase: PluginErrorPhase,
        hook: (CoreManagedSlot<TContext, TData>) -> ((TContext) throws -> Void)?
    ) {
        guard let managedSlot, let callback = hook(managedSlot) else { return }
        do {
            try callback(_slotRegistry.context)
        } catch {
            _ = _slotRegistry.reportPluginError(
                PluginErrorReport(
                    pluginId: pluginId,
                    slot: String(describing: _slotName),
                    phase: phase,
                    source: .core,
                    error: error
                )
            )
        }
    }

    private func detachNodeFromMount(_ node: Renderable) {
        if node.parent === self {
            remove(node)
        }
    }

    private func cleanupInactivePluginNodes(nextActiveIds: Set<String>, registeredIds: Set<String>) {
        let existingKeys = Array(_pluginNodes.keys)
        for pluginId in existingKeys {
            guard !nextActiveIds.contains(pluginId), let state = _pluginNodes[pluginId] else {
                continue
            }

            if _activePluginIds.contains(pluginId) {
                callManagedHook(
                    pluginId: pluginId,
                    managedSlot: state.managedSlot,
                    phase: .dispose,
                    hook: { $0.onDeactivate }
                )
            }

            for node in state.nodes {
                detachNodeFromMount(node)
            }

            if !registeredIds.contains(pluginId) {
                callManagedHook(
                    pluginId: pluginId,
                    managedSlot: state.managedSlot,
                    phase: .dispose,
                    hook: { $0.onDispose }
                )
                if state.ownership == .host {
                    for node in state.nodes {
                        node.destroyRecursively()
                    }
                }
                _pluginNodes.removeValue(forKey: pluginId)
                continue
            }

            if state.ownership == .host {
                for node in state.nodes {
                    node.destroyRecursively()
                }
                _pluginNodes.removeValue(forKey: pluginId)
                continue
            }

            state.nodes = []
        }
    }

    private func cleanupReplacedPluginNodes(previousState: SlotNodeState, nextNodes: [Renderable]) {
        for node in previousState.nodes {
            if nextNodes.contains(where: { $0 === node }) {
                continue
            }
            detachNodeFromMount(node)
            if previousState.ownership == .host {
                node.destroyRecursively()
            }
        }
    }

    private func resolvePluginFailurePlaceholder(_ failure: PluginErrorEvent) -> [Renderable] {
        guard let placeholderBuilder = _pluginFailurePlaceholder else {
            return []
        }
        do {
            let nodes = try placeholderBuilder(failure, _slotRegistry.context)
            for node in nodes {
                try ensureValidNode(node, pluginId: "\(failure.pluginId):error-placeholder")
            }
            return nodes
        } catch {
            _ = _slotRegistry.reportPluginError(
                PluginErrorReport(
                    pluginId: failure.pluginId,
                    slot: String(describing: _slotName),
                    phase: .errorPlaceholder,
                    source: .core,
                    error: error
                )
            )
            return []
        }
    }

    private func reconcileMountedNodes(_ desiredNodes: [Renderable]) {
        for node in _mountedNodes {
            if !desiredNodes.contains(where: { $0 === node }) {
                if node.parent === self {
                    remove(node)
                }
            }
        }

        for (index, node) in desiredNodes.enumerated() {
            if node.parent !== self {
                add(node, index: index)
                continue
            }
            let currentChildren = getChildren()
            if index >= currentChildren.count || currentChildren[index] !== node {
                add(node, index: index)
            }
        }

        _mountedNodes = desiredNodes
    }

    private func cleanupAll() {
        guard !_disposed else { return }
        _disposed = true

        _unsubscribe?()
        _unsubscribe = nil

        for (pluginId, state) in _pluginNodes {
            if _activePluginIds.contains(pluginId) {
                callManagedHook(
                    pluginId: pluginId,
                    managedSlot: state.managedSlot,
                    phase: .dispose,
                    hook: { $0.onDeactivate }
                )
            }
            callManagedHook(
                pluginId: pluginId,
                managedSlot: state.managedSlot,
                phase: .dispose,
                hook: { $0.onDispose }
            )
            for node in state.nodes {
                detachNodeFromMount(node)
            }
            if state.ownership == .host {
                for node in state.nodes {
                    node.destroyRecursively()
                }
            }
        }

        _pluginNodes.removeAll()
        _activePluginIds.removeAll()

        if let fallbackNodes = _fallbackNodes {
            for node in fallbackNodes {
                detachNodeFromMount(node)
                node.destroyRecursively()
            }
            _fallbackNodes = nil
        }

        _mountedNodes.removeAll()
    }
}

/// Alias matching the naming used across OpenTUI plugin host guides.
public typealias CoreSlotRenderable = SlotRenderable

// MARK: - Runtime Plugin Module Support (`core/src/runtime-plugin.ts`, `runtime-plugin-support-configure.ts`)

private let coreRuntimeSpecifier = "@opentui/core"
private let coreTestingRuntimeSpecifier = "@opentui/core/testing"
private let runtimeModulePrefix = "opentui:runtime-module:"
private let defaultCoreRuntimeModuleSpecifiers: Set<String> = [
    coreRuntimeSpecifier,
    coreTestingRuntimeSpecifier,
]

/// Export map exposed by a virtual runtime module.
// parity: core/src/runtime-plugin.ts#RuntimeModuleExports [status=adapted hash=567fe2ec6301]
public typealias RuntimeModuleExports = [String: AnySendablePayload]

/// Async loader producing a virtual runtime module's exports.
// parity: core/src/runtime-plugin.ts#RuntimeModuleLoader [status=adapted hash=ba9a85768ebb]
public typealias RuntimeModuleLoader = @Sendable () async throws -> RuntimeModuleExports

/// Either an eager export dictionary or a lazy async loader closure.
// parity: core/src/runtime-plugin.ts#RuntimeModuleEntry [status=adapted hash=2abb3bf642cc]
public enum RuntimeModuleEntry: Sendable {
    case exports(RuntimeModuleExports)
    case loader(RuntimeModuleLoader)

    public func load() async throws -> RuntimeModuleExports {
        switch self {
        case .exports(let dict): return dict
        case .loader(let fn): return try await fn()
        }
    }
}

/// Strategy describing which bare import specifiers should be preserved verbatim without rewriting.
// parity: core/src/runtime-plugin.ts#RuntimeSpecifierPreserve [status=adapted hash=f56978694102]
public enum RuntimeSpecifierPreserve: Sendable {
    case list([String])
    case set(Set<String>)
    case predicate(@Sendable (String) -> Bool)

    internal func matches(_ specifier: String) -> Bool {
        switch self {
        case .list(let items): return items.contains(specifier)
        case .set(let set): return set.contains(specifier)
        case .predicate(let fn): return fn(specifier)
        }
    }

    internal var canonicalKey: String {
        switch self {
        case .list(let items):
            let sorted = Array(Set(items)).sorted()
            return sorted.isEmpty ? "" : "list:" + sorted.joined(separator: ",")
        case .set(let set):
            let sorted = Array(set).sorted()
            return sorted.isEmpty ? "" : "list:" + sorted.joined(separator: ",")
        case .predicate:
            return "predicate"
        }
    }
}

/// Options controlling specifier rewriting inside `node_modules`.
// parity: core/src/runtime-plugin.ts#RuntimePluginRewriteOptions [status=implemented hash=c2b2adfda1a3]
public struct RuntimePluginRewriteOptions: Equatable, Hashable, Sendable {
    public var nodeModulesRuntimeSpecifiers: Bool
    public var nodeModulesBareSpecifiers: Bool

    public init(
        nodeModulesRuntimeSpecifiers: Bool = true,
        nodeModulesBareSpecifiers: Bool = false
    ) {
        self.nodeModulesRuntimeSpecifiers = nodeModulesRuntimeSpecifiers
        self.nodeModulesBareSpecifiers = nodeModulesBareSpecifiers
    }
}

/// Options accepted by `createRuntimePlugin` and `ensureRuntimePluginSupport`.
// parity: core/src/runtime-plugin.ts#CreateRuntimePluginOptions [status=adapted hash=21fe23200029]
public struct CreateRuntimePluginOptions: Sendable {
    public var core: RuntimeModuleEntry?
    public var additional: [String: RuntimeModuleEntry]
    public var preserve: RuntimeSpecifierPreserve?
    public var rewrite: RuntimePluginRewriteOptions?

    public init(
        core: RuntimeModuleEntry? = nil,
        additional: [String: RuntimeModuleEntry] = [:],
        preserve: RuntimeSpecifierPreserve? = nil,
        rewrite: RuntimePluginRewriteOptions? = nil
    ) {
        self.core = core
        self.additional = additional
        self.preserve = preserve
        self.rewrite = rewrite
    }
}

/// Reports whether `specifier` is a built-in OpenTUI core runtime module specifier.
// parity: core/src/runtime-plugin.ts#isCoreRuntimeModuleSpecifier [status=implemented hash=414ca4553522]
public func isCoreRuntimeModuleSpecifier(_ specifier: String) -> Bool {
    defaultCoreRuntimeModuleSpecifiers.contains(specifier)
}

/// Pure-Swift RFC 3986 / JavaScript `encodeURIComponent` encoder (zero Foundation imports).
private func encodeURIComponentPure(_ value: String) -> String {
    let hex: [UInt8] = Array("0123456789ABCDEF".utf8)
    var out: [UInt8] = []
    out.reserveCapacity(value.utf8.count * 2)
    for byte in value.utf8 {
        let isUnescaped =
            (byte >= 0x41 && byte <= 0x5A) // A-Z
            || (byte >= 0x61 && byte <= 0x7A) // a-z
            || (byte >= 0x30 && byte <= 0x39) // 0-9
            || byte == UInt8(ascii: "-")
            || byte == UInt8(ascii: "_")
            || byte == UInt8(ascii: ".")
            || byte == UInt8(ascii: "!")
            || byte == UInt8(ascii: "~")
            || byte == UInt8(ascii: "*")
            || byte == UInt8(ascii: "'")
            || byte == UInt8(ascii: "(")
            || byte == UInt8(ascii: ")")
        if isUnescaped {
            out.append(byte)
        } else {
            out.append(UInt8(ascii: "%"))
            out.append(hex[Int(byte >> 4)])
            out.append(hex[Int(byte & 0x0F)])
        }
    }
    return String(decoding: out, as: UTF8.self)
}

/// Encodes a module specifier into its virtual `opentui:runtime-module:*` identifier.
// parity: core/src/runtime-plugin.ts#runtimeModuleIdForSpecifier [status=implemented hash=beacacfb720c]
public func runtimeModuleIdForSpecifier(_ specifier: String) -> String {
    "\(runtimeModulePrefix)\(encodeURIComponentPure(specifier))"
}

/// Portable Swift representation of a configured runtime module plugin.
public struct RuntimePluginDescriptor: Sendable {
    public let name: String
    public let moduleIdsBySpecifier: [String: String]
    public let modulesBySpecifier: [String: RuntimeModuleEntry]
    public let preserve: RuntimeSpecifierPreserve?
    public let rewrite: RuntimePluginRewriteOptions

    public init(
        name: String = "swift-plugin-opentui-runtime-modules",
        moduleIdsBySpecifier: [String: String],
        modulesBySpecifier: [String: RuntimeModuleEntry],
        preserve: RuntimeSpecifierPreserve?,
        rewrite: RuntimePluginRewriteOptions
    ) {
        self.name = name
        self.moduleIdsBySpecifier = moduleIdsBySpecifier
        self.modulesBySpecifier = modulesBySpecifier
        self.preserve = preserve
        self.rewrite = rewrite
    }

    public func isPreserved(_ specifier: String) -> Bool {
        preserve?.matches(specifier) ?? false
    }

    public func resolveVirtualId(for specifier: String) -> String? {
        moduleIdsBySpecifier[specifier]
    }

    public func loadModule(for specifier: String) async throws -> RuntimeModuleExports? {
        guard let entry = modulesBySpecifier[specifier] else { return nil }
        return try await entry.load()
    }
}

/// Creates a `RuntimePluginDescriptor` mapping `@opentui/core`, `@opentui/core/testing`, and additional specifiers.
// parity: core/src/runtime-plugin.ts#createRuntimePlugin [status=adapted hash=8e8055cbc45a]
public func createRuntimePlugin(_ options: CreateRuntimePluginOptions = CreateRuntimePluginOptions()) -> RuntimePluginDescriptor {
    var modules: [String: RuntimeModuleEntry] = [
        coreRuntimeSpecifier: options.core ?? .exports([:]),
        coreTestingRuntimeSpecifier: .exports([:]),
    ]
    for (specifier, entry) in options.additional {
        modules[specifier] = entry
    }
    var ids: [String: String] = [:]
    for specifier in modules.keys {
        ids[specifier] = runtimeModuleIdForSpecifier(specifier)
    }
    return RuntimePluginDescriptor(
        moduleIdsBySpecifier: ids,
        modulesBySpecifier: modules,
        preserve: options.preserve,
        rewrite: options.rewrite ?? RuntimePluginRewriteOptions()
    )
}

/// Process-wide runtime plugin support installation state matching `runtime-plugin-support-configure.ts`.
public enum RuntimePluginSupport {
    private struct InstallRecord: Sendable {
        let plugin: RuntimePluginDescriptor
        let additionalSpecifiers: Set<String>
        let hasCustomCore: Bool
        let preserveKey: String
        let rewriteKey: String
    }

    private static let installed = Mutex<InstallRecord?>(nil)

    /// Returns the currently installed runtime plugin descriptor, if `ensureRuntimePluginSupport` has run.
    public static var current: RuntimePluginDescriptor? {
        installed.withLock { $0?.plugin }
    }

    /// Reports whether runtime plugin support is installed.
    public static var isInstalled: Bool {
        installed.withLock { $0 != nil }
    }

    /// Resets the process-wide installation record (primarily for isolated tests).
    public static func reset() {
        installed.withLock { $0 = nil }
    }

    internal static func ensure(_ options: CreateRuntimePluginOptions) throws(PluginRegistryError) -> Bool {
        let rewrite = options.rewrite ?? RuntimePluginRewriteOptions()
        let rewriteKey = "\(rewrite.nodeModulesRuntimeSpecifiers):\(rewrite.nodeModulesBareSpecifiers)"
        let preserveKey = options.preserve?.canonicalKey ?? ""

        return try installed.withLock { record throws(PluginRegistryError) -> Bool in
            if let existing = record {
                for specifier in options.additional.keys where !existing.additionalSpecifiers.contains(specifier) {
                    throw .incompatibleRuntimePluginSupport(
                        "OpenTUI Core runtime plugin support is already installed without \(specifier)."
                    )
                }
                if options.core != nil && !existing.hasCustomCore {
                    throw .incompatibleRuntimePluginSupport(
                        "OpenTUI Core runtime plugin support is already installed with a different core runtime module."
                    )
                }
                if options.preserve != nil && preserveKey != existing.preserveKey {
                    throw .incompatibleRuntimePluginSupport(
                        "OpenTUI Core runtime plugin support is already installed with different preserve options."
                    )
                }
                if options.rewrite != nil && rewriteKey != existing.rewriteKey {
                    throw .incompatibleRuntimePluginSupport(
                        "OpenTUI Core runtime plugin support is already installed with different rewrite options."
                    )
                }
                return false
            }

            let descriptor = createRuntimePlugin(options)
            record = InstallRecord(
                plugin: descriptor,
                additionalSpecifiers: Set(options.additional.keys),
                hasCustomCore: options.core != nil,
                preserveKey: preserveKey,
                rewriteKey: rewriteKey
            )
            return true
        }
    }
}

/// Idempotently installs process-wide runtime plugin support, returning `true` on initial install
/// or `false` when already installed with compatible options. Throws on incompatible re-configuration.
// parity: core/src/runtime-plugin-support-configure.ts#ensureRuntimePluginSupport [status=adapted hash=21f67016a16b]
@discardableResult
public func ensureRuntimePluginSupport(
    _ options: CreateRuntimePluginOptions = CreateRuntimePluginOptions()
) throws(PluginRegistryError) -> Bool {
    try RuntimePluginSupport.ensure(options)
}

/// Convenience alias for `ensureRuntimePluginSupport(_:)`.
// parity: core/src/runtime-plugin-support.ts#ensureRuntimePluginSupport [status=adapted hash=7347886ead1e]
@discardableResult
public func configureRuntimePluginSupport(
    _ options: CreateRuntimePluginOptions = CreateRuntimePluginOptions()
) throws(PluginRegistryError) -> Bool {
    try ensureRuntimePluginSupport(options)
}
