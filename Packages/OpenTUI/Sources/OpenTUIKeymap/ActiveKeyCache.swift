// Pure Swift 6 port of keymap/src/services/active-key-cache.ts and keymap/src/services/activation.ts.

// MARK: - Active Key & Active Binding Types

/// Snapshot of an active binding exposed by active-key and command-binding queries.
public struct ActiveBinding<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public let sequence: [KeySequencePart]
    public let command: BindingCommand<Target, Event>?
    public let commandAttrs: Attributes?
    public let attrs: Attributes?
    public let event: BindingEvent
    public let preventDefault: Bool
    public let `fallthrough`: Bool

    public init(
        sequence: [KeySequencePart],
        command: BindingCommand<Target, Event>? = nil,
        commandAttrs: Attributes? = nil,
        attrs: Attributes? = nil,
        event: BindingEvent = .press,
        preventDefault: Bool = true,
        fallthrough isFallthrough: Bool = false
    ) {
        self.sequence = sequence
        self.command = command
        self.commandAttrs = commandAttrs
        self.attrs = attrs
        self.event = event
        self.preventDefault = preventDefault
        self.`fallthrough` = isFallthrough
    }
}

/// Options controlling what data `getActiveKeys` materializes.
public struct ActiveKeyOptions: Equatable, Hashable, Sendable {
    public let includeBindings: Bool
    public let includeMetadata: Bool

    public init(includeBindings: Bool = false, includeMetadata: Bool = false) {
        self.includeBindings = includeBindings
        self.includeMetadata = includeMetadata
    }
}

/// Materialized next-stroke option available at the current root or pending sequence position.
public struct ActiveKey<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public let stroke: NormalizedKeyStroke
    public let display: String
    public let tokenName: String?
    public let bindings: [ActiveBinding<Target, Event>]?
    public let bindingAttrs: Attributes?
    public let commandAttrs: Attributes?
    public let command: BindingCommand<Target, Event>?
    public let continues: Bool

    public init(
        stroke: NormalizedKeyStroke,
        display: String,
        tokenName: String? = nil,
        bindings: [ActiveBinding<Target, Event>]? = nil,
        bindingAttrs: Attributes? = nil,
        commandAttrs: Attributes? = nil,
        command: BindingCommand<Target, Event>? = nil,
        continues: Bool
    ) {
        self.stroke = stroke
        self.display = display
        self.tokenName = tokenName
        self.bindings = bindings
        self.bindingAttrs = bindingAttrs
        self.commandAttrs = commandAttrs
        self.command = command
        self.continues = continues
    }
}

/// Cached active-key slice keyed by a specific `cacheVersion`.
public struct FocusedActiveKeysCacheEntry<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public let version: Int
    public let value: [ActiveKey<Target, Event>]

    public init(version: Int, value: [ActiveKey<Target, Event>]) {
        self.version = version
        self.value = value
    }
}

// MARK: - Active Keys Cache (active-key-cache.ts)

// parity: keymap/src/services/active-key-cache.ts#ActiveKeysCache [status=implemented hash=1e9e45b77d61]
public final class ActiveKeysCache<Target: Hashable & Sendable, Event: KeymapEvent>: @unchecked Sendable {
    public var version: Int = -1
    public var notifyVersion: Int = -1
    public var hasFocused: Bool = false
    public var focused: Target? = nil
    public var value: [ActiveKey<Target, Event>] = []
    public var targets: [Target: FocusedActiveKeysCacheEntry<Target, Event>] = [:]
    public var nullTarget: FocusedActiveKeysCacheEntry<Target, Event>? = nil

    public init() {}

    public func invalidate() {
        version = -1
        notifyVersion = -1
        hasFocused = false
        focused = nil
        value = []
        targets.removeAll(keepingCapacity: false)
        nullTarget = nil
    }
}

// parity: keymap/src/services/active-key-cache.ts#ActiveKeysCaches [status=implemented hash=6f01a6ec51f1]
public final class ActiveKeysCaches<Target: Hashable & Sendable, Event: KeymapEvent>: @unchecked Sendable {
    public let plain: ActiveKeysCache<Target, Event>
    public let bindings: ActiveKeysCache<Target, Event>
    public let metadata: ActiveKeysCache<Target, Event>
    public let bindingsAndMetadata: ActiveKeysCache<Target, Event>

    public init(
        plain: ActiveKeysCache<Target, Event> = ActiveKeysCache(),
        bindings: ActiveKeysCache<Target, Event> = ActiveKeysCache(),
        metadata: ActiveKeysCache<Target, Event> = ActiveKeysCache(),
        bindingsAndMetadata: ActiveKeysCache<Target, Event> = ActiveKeysCache()
    ) {
        self.plain = plain
        self.bindings = bindings
        self.metadata = metadata
        self.bindingsAndMetadata = bindingsAndMetadata
    }

    public func invalidateAll() {
        plain.invalidate()
        bindings.invalidate()
        metadata.invalidate()
        bindingsAndMetadata.invalidate()
    }
}

// parity: keymap/src/services/active-key-cache.ts#createActiveKeysCache [status=implemented hash=8bf3c5d4c6ce]
public func createActiveKeysCache<Target: Hashable & Sendable, Event: KeymapEvent>() -> ActiveKeysCache<Target, Event>
{
    ActiveKeysCache()
}

// parity: keymap/src/services/active-key-cache.ts#createActiveKeysCaches [status=implemented hash=27a899162d1a]
public func createActiveKeysCaches<Target: Hashable & Sendable, Event: KeymapEvent>() -> ActiveKeysCaches<
    Target, Event
> {
    ActiveKeysCaches(
        plain: createActiveKeysCache(),
        bindings: createActiveKeysCache(),
        metadata: createActiveKeysCache(),
        bindingsAndMetadata: createActiveKeysCache()
    )
}

// parity: keymap/src/services/active-key-cache.ts#getActiveKeysCache [status=implemented hash=041992d12914]
public func getActiveKeysCache<Target: Hashable & Sendable, Event: KeymapEvent>(
    _ caches: ActiveKeysCaches<Target, Event>,
    options: ActiveKeyOptions? = nil
) -> ActiveKeysCache<Target, Event> {
    guard let options else {
        return caches.plain
    }
    if options.includeBindings {
        return options.includeMetadata ? caches.bindingsAndMetadata : caches.bindings
    }
    return options.includeMetadata ? caches.metadata : caches.plain
}

// parity: keymap/src/services/active-key-cache.ts#getFocusedActiveKeysCache [status=implemented hash=f6fa20e0cba4]
public func getFocusedActiveKeysCache<Target: Hashable & Sendable, Event: KeymapEvent>(
    _ cache: ActiveKeysCache<Target, Event>,
    cacheVersion: Int,
    focused: Target?
) -> FocusedActiveKeysCacheEntry<Target, Event>? {
    let cached: FocusedActiveKeysCacheEntry<Target, Event>?
    if let focused {
        cached = cache.targets[focused]
    } else {
        cached = cache.nullTarget
    }
    return cached?.version == cacheVersion ? cached : nil
}

// parity: keymap/src/services/active-key-cache.ts#setFocusedActiveKeysCache [status=implemented hash=b412aa3c5642]
public func setFocusedActiveKeysCache<Target: Hashable & Sendable, Event: KeymapEvent>(
    _ cache: ActiveKeysCache<Target, Event>,
    cacheVersion: Int,
    focused: Target?,
    value: [ActiveKey<Target, Event>]
) {
    let entry = FocusedActiveKeysCacheEntry(version: cacheVersion, value: value)
    if let focused {
        cache.targets[focused] = entry
    } else {
        cache.nullTarget = entry
    }
}

// MARK: - Activation Service (activation.ts)

/// Error thrown when using a keymap whose host has been destroyed.
public enum KeymapHostError: Error, Equatable, Sendable, KeymapDescribedError {
    case hostDestroyed

    public var errorMessage: String {
        switch self {
        case .hostDestroyed:
            return "Cannot use a keymap after its host was destroyed"
        }
    }
}

public struct ActivationOptions<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public let onPendingSequenceChanged:
        (@Sendable (PendingSequenceState<Target, Event>?, PendingSequenceState<Target, Event>?) -> Void)?
    public let onEmitPendingSequence: (@Sendable ([KeySequencePart]) -> Void)?

    public init(
        onPendingSequenceChanged: (
            @Sendable (PendingSequenceState<Target, Event>?, PendingSequenceState<Target, Event>?) -> Void
        )? = nil,
        onEmitPendingSequence: (@Sendable ([KeySequencePart]) -> Void)? = nil
    ) {
        self.onPendingSequenceChanged = onPendingSequenceChanged
        self.onEmitPendingSequence = onEmitPendingSequence
    }
}

// parity: keymap/src/services/activation.ts#ActivationService [status=implemented hash=e46e3ae90a5f]
public protocol ActivationService<Target, Event>: AnyObject, Sendable {
    associatedtype Target: Hashable & Sendable
    associatedtype Event: KeymapEvent

    func getFocusedTarget() -> Target?
    func getFocusedTargetIfAvailable() -> Target?
    func setPendingSequence(_ next: PendingSequenceState<Target, Event>?)
    func ensureValidPendingSequence() -> PendingSequenceState<Target, Event>?
    func revalidatePendingSequenceIfNeeded()
    func hasPendingSequenceState() -> Bool
    func getPendingSequence() -> [KeySequencePart]
    func popPendingSequence() -> Bool
    func getActiveKeys(options: ActiveKeyOptions?) -> [ActiveKey<Target, Event>]
    func getActiveKeysForCaptures(
        _ captures: [PendingSequenceCapture<Target, Event>],
        options: ActiveKeyOptions?
    ) -> [ActiveKey<Target, Event>]
    func getActiveKeysForFocused(
        _ focused: Target?,
        options: ActiveKeyOptions?
    ) -> [ActiveKey<Target, Event>]
    func getActiveLayers(focused: Target?) -> [RegisteredLayer<Target, Event>]
    func isLayerActiveForFocused(_ layer: RegisteredLayer<Target, Event>, focused: Target?) -> Bool
    func collectSequencePartsFromPending(_ pending: PendingSequenceState<Target, Event>) -> [KeySequencePart]
    func collectMatchingBindings(
        _ bindings: [BindingState<Target, Event>],
        focused: Target?,
        activeView: ActiveCommandView<Target, Event>
    ) -> [BindingState<Target, Event>]
    func collectActiveBindings(
        _ bindings: [BindingState<Target, Event>],
        focused: Target?,
        activeView: ActiveCommandView<Target, Event>
    ) -> [ActiveBinding<Target, Event>]
}

private struct ActiveKeySelection<Target: Hashable & Sendable, Event: KeymapEvent> {
    let display: String
    let tokenName: String?
    let continues: Bool
    let firstBinding: BindingState<Target, Event>?
    let commandBinding: BindingState<Target, Event>?
    let bindings: [BindingState<Target, Event>]?
    let stop: Bool
}

private final class ActiveKeyState<Target: Hashable & Sendable, Event: KeymapEvent> {
    let stroke: NormalizedKeyStroke
    let display: String
    let tokenName: String?
    var continues: Bool
    var firstBinding: BindingState<Target, Event>?
    var commandBinding: BindingState<Target, Event>?
    var bindings: [BindingState<Target, Event>]?

    init(
        stroke: NormalizedKeyStroke,
        display: String,
        tokenName: String?,
        continues: Bool,
        firstBinding: BindingState<Target, Event>?,
        commandBinding: BindingState<Target, Event>?,
        bindings: [BindingState<Target, Event>]?
    ) {
        self.stroke = stroke
        self.display = display
        self.tokenName = tokenName
        self.continues = continues
        self.firstBinding = firstBinding
        self.commandBinding = commandBinding
        self.bindings = bindings
    }
}

public final class DefaultActivationService<Host: KeymapHost>: ActivationService, @unchecked Sendable {
    public typealias Target = Host.Target
    public typealias Event = Host.Event

    private let state: LayerStackState<Target, Event>
    private let host: Host
    private let notify: KeymapNotifier
    private let conditions: any ConditionService
    private let catalog: any CommandCatalogService<Target, Event>
    private let hasCommandResolvers: @Sendable () -> Bool
    private var options: ActivationOptions<Target, Event>

    private let activeKeysCaches: ActiveKeysCaches<Target, Event>
    private var pendingSequenceCacheVersion: Int = -1
    private var pendingSequenceCache: [KeySequencePart] = []

    private var activeLayersCacheVersion: Int = -1
    private var activeLayersCacheHasFocused: Bool = false
    private var activeLayersCacheFocused: Target? = nil
    private var activeLayersCache: [RegisteredLayer<Target, Event>] = []

    public init(
        state: LayerStackState<Target, Event>,
        host: Host,
        notify: KeymapNotifier,
        conditions: any ConditionService,
        catalog: any CommandCatalogService<Target, Event>,
        hasCommandResolvers: @escaping @Sendable () -> Bool = { false },
        options: ActivationOptions<Target, Event> = ActivationOptions()
    ) {
        self.state = state
        self.host = host
        self.notify = notify
        self.conditions = conditions
        self.catalog = catalog
        self.hasCommandResolvers = hasCommandResolvers
        self.options = options
        self.activeKeysCaches = createActiveKeysCaches()
    }

    internal func setPendingSequenceChangedHandler(
        _ handler: (@Sendable (PendingSequenceState<Target, Event>?, PendingSequenceState<Target, Event>?) -> Void)?
    ) {
        self.options = ActivationOptions(
            onPendingSequenceChanged: handler,
            onEmitPendingSequence: options.onEmitPendingSequence
        )
    }

    public func getFocusedTarget() -> Target? {
        if host.isDestroyed {
            return nil
        }
        return host.getFocusedTarget()
    }

    public func getFocusedTargetIfAvailable() -> Target? {
        OpenTUIKeymap.getFocusedTargetIfAvailable(host)
    }

    public func setPendingSequence(_ next: PendingSequenceState<Target, Event>?) {
        let previous = state.pending
        if isSamePendingSequence(previous, next) {
            return
        }

        state.pending = next
        options.onPendingSequenceChanged?(previous, next)
        if let emit = options.onEmitPendingSequence {
            emit(next.map { OpenTUIKeymap.collectSequencePartsFromPending($0) } ?? [])
        }
        notify.queueStateChange()
    }

    public func ensureValidPendingSequence() -> PendingSequenceState<Target, Event>? {
        guard let pending = state.pending else {
            return nil
        }

        let focused = getFocusedTarget()
        let activeView = catalog.getActiveCommandView(focused: focused)
        let captures = pending.captures.filter { capture in
            state.layers.contains(where: { $0 === capture.layer })
                && isLayerActiveForFocused(capture.layer, focused: focused)
                && conditions.matchesConditions(capture.layer)
                && bindingMatchesRuntimeState(capture.binding, focused: focused, activeView: activeView)
                && captureHasContinuations(capture, patterns: state.patterns)
        }

        if captures.isEmpty {
            setPendingSequence(nil)
            return nil
        }

        if captures.count != pending.captures.count {
            setPendingSequence(PendingSequenceState(captures: captures))
        }

        return state.pending
    }

    public func revalidatePendingSequenceIfNeeded() {
        if host.isDestroyed || state.pending == nil {
            return
        }
        _ = ensureValidPendingSequence()
    }

    public func hasPendingSequenceState() -> Bool {
        !host.isDestroyed && state.pending != nil
    }

    public func getPendingSequence() -> [KeySequencePart] {
        if pendingSequenceCacheVersion == notify.cacheVersion {
            return pendingSequenceCache
        }

        let pending = ensureValidPendingSequence()
        let sequence = pending.map { OpenTUIKeymap.collectSequencePartsFromPending($0) } ?? []
        if pending == nil || allRegisteredLayersCanCacheActiveKeys() {
            pendingSequenceCacheVersion = notify.cacheVersion
            pendingSequenceCache = sequence
        }
        return sequence
    }

    public func popPendingSequence() -> Bool {
        guard let pending = ensureValidPendingSequence() else {
            return false
        }

        guard let firstCapture = pending.captures.first, firstCapture.parts.count > 1 else {
            setPendingSequence(nil)
            return true
        }

        var nextCaptures: [PendingSequenceCapture<Target, Event>] = []
        for capture in pending.captures {
            if let nextCapture = popCapture(capture) {
                nextCaptures.append(nextCapture)
            }
        }

        if nextCaptures.isEmpty {
            setPendingSequence(nil)
            return true
        }

        setPendingSequence(PendingSequenceState(captures: nextCaptures))
        return true
    }

    public func getActiveKeys(options: ActiveKeyOptions? = nil) -> [ActiveKey<Target, Event>] {
        let includeBindings = options?.includeBindings == true
        let includeMetadata = options?.includeMetadata == true
        let cache = getActiveKeysCache(activeKeysCaches, options: options)

        if cache.notifyVersion == notify.derivedVersion {
            return cache.value
        }

        return collectActiveKeysForCache(
            cache,
            includeBindings: includeBindings,
            includeMetadata: includeMetadata
        )
    }

    public func getActiveKeysForCaptures(
        _ captures: [PendingSequenceCapture<Target, Event>],
        options: ActiveKeyOptions? = nil
    ) -> [ActiveKey<Target, Event>] {
        let includeBindings = options?.includeBindings == true
        let includeMetadata = options?.includeMetadata == true
        let focused = getFocusedTarget()
        let activeView = catalog.getActiveCommandView(focused: focused)
        return collectActiveKeysFromPending(
            captures,
            includeBindings: includeBindings,
            includeMetadata: includeMetadata,
            focused: focused,
            activeView: activeView
        )
    }

    public func getActiveKeysForFocused(
        _ focused: Target?,
        options: ActiveKeyOptions? = nil
    ) -> [ActiveKey<Target, Event>] {
        let includeBindings = options?.includeBindings == true
        let includeMetadata = options?.includeMetadata == true
        let currentFocused = getFocusedTargetIfAvailable()
        let pending = (focused == currentFocused) ? ensureValidPendingSequence() : nil
        let activeView = catalog.getActiveCommandView(focused: focused)

        if let pending {
            return collectActiveKeysFromPending(
                pending.captures,
                includeBindings: includeBindings,
                includeMetadata: includeMetadata,
                focused: focused,
                activeView: activeView
            )
        }

        return collectActiveKeysAtRoot(
            getActiveLayers(focused: focused),
            includeBindings: includeBindings,
            includeMetadata: includeMetadata,
            focused: focused,
            activeView: activeView
        )
    }

    public func getActiveLayers(focused: Target?) -> [RegisteredLayer<Target, Event>] {
        if activeLayersCacheVersion == notify.cacheVersion
            && activeLayersCacheHasFocused
            && activeLayersCacheFocused == focused
        {
            return activeLayersCache
        }

        activeLayersCacheVersion = notify.cacheVersion
        activeLayersCacheHasFocused = true
        activeLayersCacheFocused = focused
        activeLayersCache = getActiveLayersForFocused(
            layers: state.sortedLayers,
            host: host,
            focused: focused,
            alreadySorted: true
        )
        return activeLayersCache
    }

    public func isLayerActiveForFocused(_ layer: RegisteredLayer<Target, Event>, focused: Target?) -> Bool {
        OpenTUIKeymap.isLayerActiveForFocused(host: host, layer: layer, focused: focused)
    }

    public func collectSequencePartsFromPending(_ pending: PendingSequenceState<Target, Event>) -> [KeySequencePart] {
        OpenTUIKeymap.collectSequencePartsFromPending(pending)
    }

    public func collectMatchingBindings(
        _ bindings: [BindingState<Target, Event>],
        focused: Target?,
        activeView: ActiveCommandView<Target, Event>
    ) -> [BindingState<Target, Event>] {
        var matches: [BindingState<Target, Event>] = []
        for binding in bindings {
            if bindingMatchesRuntimeState(binding, focused: focused, activeView: activeView) {
                matches.append(binding)
            }
        }
        return matches
    }

    public func collectActiveBindings(
        _ bindings: [BindingState<Target, Event>],
        focused: Target?,
        activeView: ActiveCommandView<Target, Event>
    ) -> [ActiveBinding<Target, Event>] {
        bindings.map { toActiveBinding($0, focused: focused, activeView: activeView) }
    }

    // MARK: - Internal Active Key Materialization

    private func collectActiveKeysForCache(
        _ cache: ActiveKeysCache<Target, Event>,
        includeBindings: Bool,
        includeMetadata: Bool
    ) -> [ActiveKey<Target, Event>] {
        let focused = getFocusedTarget()
        if let cached = getFocusedActiveKeysCache(cache, cacheVersion: notify.cacheVersion, focused: focused) {
            cache.notifyVersion = notify.derivedVersion
            cache.version = notify.cacheVersion
            cache.hasFocused = true
            cache.focused = focused
            cache.value = cached.value
            return cached.value
        }

        let activeView = catalog.getActiveCommandView(focused: focused)
        let pending = ensureValidPendingSequence()
        let activeLayers = pending != nil ? [] : getActiveLayers(focused: focused)

        let activeKeys: [ActiveKey<Target, Event>]
        if let pending {
            activeKeys = collectActiveKeysFromPending(
                pending.captures,
                includeBindings: includeBindings,
                includeMetadata: includeMetadata,
                focused: focused,
                activeView: activeView
            )
        } else {
            activeKeys = collectActiveKeysAtRoot(
                activeLayers,
                includeBindings: includeBindings,
                includeMetadata: includeMetadata,
                focused: focused,
                activeView: activeView
            )
        }

        let canUseCache = allRegisteredLayersCanCacheActiveKeys()
        if canUseCache {
            cache.version = notify.cacheVersion
            cache.notifyVersion = notify.derivedVersion
            cache.hasFocused = true
            cache.focused = focused
            cache.value = activeKeys
            setFocusedActiveKeysCache(cache, cacheVersion: notify.cacheVersion, focused: focused, value: activeKeys)
        }

        return activeKeys
    }

    private func allRegisteredLayersCanCacheActiveKeys() -> Bool {
        !hasCommandResolvers() && state.activeKeyCacheBlockers == 0
    }

    private func bindingMatchesRuntimeState(
        _ binding: BindingState<Target, Event>,
        focused: Target?,
        activeView: ActiveCommandView<Target, Event>
    ) -> Bool {
        conditions.matchesConditions(binding) && catalog.isBindingVisible(binding, focused: focused, activeView: activeView)
    }

    private func toActiveBinding(
        _ binding: BindingState<Target, Event>,
        focused: Target?,
        activeView: ActiveCommandView<Target, Event>
    ) -> ActiveBinding<Target, Event> {
        ActiveBinding(
            sequence: binding.sequence,
            command: binding.command,
            commandAttrs: catalog.getBindingCommandAttrs(binding, focused: focused, activeView: activeView),
            attrs: binding.attrs,
            event: binding.event,
            preventDefault: binding.preventDefault,
            fallthrough: binding.fallthrough
        )
    }

    private func collectActiveKeysAtRoot(
        _ activeLayers: [RegisteredLayer<Target, Event>],
        includeBindings: Bool,
        includeMetadata: Bool,
        focused: Target?,
        activeView: ActiveCommandView<Target, Event>
    ) -> [ActiveKey<Target, Event>] {
        var activeKeys: [KeyMatch: ActiveKeyState<Target, Event>] = [:]
        var keyOrder: [KeyMatch] = []
        var stopped: Set<KeyMatch> = []

        for layer in activeLayers {
            if (layer.root.children.isEmpty && layer.root.patternChildren.isEmpty)
                || !conditions.matchesConditions(layer)
            {
                continue
            }

            let nodes = childNodes(layer.root)
            collectActiveKeyNodes(
                nodes,
                activeKeys: &activeKeys,
                keyOrder: &keyOrder,
                stopped: &stopped,
                includeBindings: includeBindings,
                focused: focused,
                activeView: activeView
            )
        }

        return materializeActiveKeys(
            activeKeys,
            keyOrder: keyOrder,
            includeBindings: includeBindings,
            includeMetadata: includeMetadata,
            focused: focused,
            activeView: activeView
        )
    }

    private func collectActiveKeyNodes(
        _ nodes: [SequenceNode<Target, Event>],
        activeKeys: inout [KeyMatch: ActiveKeyState<Target, Event>],
        keyOrder: inout [KeyMatch],
        stopped: inout Set<KeyMatch>,
        includeBindings: Bool,
        focused: Target?,
        activeView: ActiveCommandView<Target, Event>
    ) {
        for node in nodes {
            guard let bindingKey = node.match, !stopped.contains(bindingKey), let stroke = node.stroke else {
                continue
            }

            guard
                let selection = selectActiveKeyNode(
                    node,
                    includeBindings: includeBindings,
                    focused: focused,
                    activeView: activeView
                )
            else {
                continue
            }

            if let existing = activeKeys[bindingKey] {
                updateActiveKeyState(existing, selection: selection, includeBindings: includeBindings)
            } else {
                keyOrder.append(bindingKey)
                activeKeys[bindingKey] = createActiveKeyState(
                    stroke: stroke,
                    selection: selection,
                    includeBindings: includeBindings
                )
            }

            if selection.stop {
                stopped.insert(bindingKey)
            }
        }
    }

    private func selectActiveKeyNode(
        _ node: SequenceNode<Target, Event>,
        includeBindings: Bool,
        focused: Target?,
        activeView: ActiveCommandView<Target, Event>
    ) -> ActiveKeySelection<Target, Event>? {
        let continues = !node.children.isEmpty || !node.patternChildren.isEmpty
        if !continues {
            let candidates =
                nodeExactBindingsNeedPrefilter(node)
                ? collectMatchingBindings(node.bindings, focused: focused, activeView: activeView)
                : node.bindings
            guard let selected = selectActiveBindings(candidates, focused: focused, activeView: activeView) else {
                return nil
            }

            let presentation = getPartPresentation(selected.bindings, partIndex: node.depth - 1)
            return ActiveKeySelection(
                display: presentation.display,
                tokenName: presentation.tokenName,
                continues: false,
                firstBinding: selected.bindings.first,
                commandBinding: selected.commandBinding,
                bindings: includeBindings ? selected.bindings : nil,
                stop: selected.stop
            )
        }

        let reachableBindings = collectMatchingBindings(node.reachableBindings, focused: focused, activeView: activeView)
        if reachableBindings.isEmpty {
            return nil
        }

        let selected = selectActiveBindings(node.bindings, focused: focused, activeView: activeView)
        let presentation = getPartPresentation(reachableBindings, partIndex: node.depth - 1)
        return ActiveKeySelection(
            display: presentation.display,
            tokenName: presentation.tokenName,
            continues: true,
            firstBinding: selected?.bindings.first,
            commandBinding: selected?.commandBinding,
            bindings: (includeBindings && selected != nil) ? selected?.bindings : nil,
            stop: true
        )
    }

    private func nodeExactBindingsNeedPrefilter(_ node: SequenceNode<Target, Event>) -> Bool {
        if hasCommandResolvers() {
            return true
        }
        return node.bindings.contains { !$0.matchers.isEmpty }
    }

    private func collectActiveKeysFromPending(
        _ captures: [PendingSequenceCapture<Target, Event>],
        includeBindings: Bool,
        includeMetadata: Bool,
        focused: Target?,
        activeView: ActiveCommandView<Target, Event>
    ) -> [ActiveKey<Target, Event>] {
        var activeKeys: [KeyMatch: ActiveKeyState<Target, Event>] = [:]
        var keyOrder: [KeyMatch] = []
        var stopped: Set<KeyMatch> = []
        let options = activeOptionsForCaptures(captures, patterns: state.patterns)

        var seen: Set<KeyMatch> = []
        for option in options {
            let bindingKey = option.part.match
            if seen.contains(bindingKey) {
                continue
            }
            seen.insert(bindingKey)
            if stopped.contains(bindingKey) {
                continue
            }
            guard
                let selection = selectActiveKeyOption(
                    option,
                    siblingOptions: options,
                    includeBindings: includeBindings,
                    focused: focused,
                    activeView: activeView
                )
            else {
                continue
            }

            if let existing = activeKeys[bindingKey] {
                updateActiveKeyState(existing, selection: selection, includeBindings: includeBindings)
            } else {
                keyOrder.append(bindingKey)
                activeKeys[bindingKey] = createActiveKeyState(
                    stroke: option.part.stroke,
                    selection: selection,
                    includeBindings: includeBindings
                )
            }

            if selection.stop {
                stopped.insert(bindingKey)
            }
        }

        return materializeActiveKeys(
            activeKeys,
            keyOrder: keyOrder,
            includeBindings: includeBindings,
            includeMetadata: includeMetadata,
            focused: focused,
            activeView: activeView
        )
    }

    private func selectActiveKeyOption(
        _ option: SequenceActiveOption<Target, Event>,
        siblingOptions: [SequenceActiveOption<Target, Event>],
        includeBindings: Bool,
        focused: Target?,
        activeView: ActiveCommandView<Target, Event>
    ) -> ActiveKeySelection<Target, Event>? {
        let matchingOptions = siblingOptions.filter { $0.part.match == option.part.match }
        let exactBindings = matchingOptions.filter(\.exact).map(\.binding)
        let selected = selectActiveBindings(exactBindings, focused: focused, activeView: activeView)
        let continues = matchingOptions.contains(where: \.continues)

        if !continues && selected == nil {
            return nil
        }

        let presentation = getOptionPresentation(matchingOptions)
        return ActiveKeySelection(
            display: presentation.display,
            tokenName: presentation.tokenName,
            continues: continues,
            firstBinding: selected?.bindings.first,
            commandBinding: selected?.commandBinding,
            bindings: (includeBindings && selected != nil) ? selected?.bindings : nil,
            stop: continues || selected?.stop == true
        )
    }

    private func getPartPresentation(
        _ bindings: [BindingState<Target, Event>],
        partIndex: Int
    ) -> (display: String, tokenName: String?) {
        var display: String?
        var tokenName: String?
        var hasDisplayConflict = false
        var hasTokenConflict = false

        for binding in bindings {
            guard partIndex >= 0, partIndex < binding.sequence.count else { continue }
            let part = binding.sequence[partIndex]
            if display == nil {
                display = part.display
                tokenName = part.tokenName
                continue
            }
            if !hasDisplayConflict && display != part.display {
                hasDisplayConflict = true
            }
            if !hasTokenConflict && tokenName != part.tokenName {
                hasTokenConflict = true
            }
        }

        let resolvedDisplay: String
        if let existing = display, !hasDisplayConflict {
            resolvedDisplay = existing
        } else if let firstBinding = bindings.first, partIndex >= 0, partIndex < firstBinding.sequence.count {
            let stroke = firstBinding.sequence[partIndex].stroke
            resolvedDisplay = (try? stringifyKeyStroke(.stroke(stroke.asStrokeInput))) ?? stroke.name
        } else {
            resolvedDisplay = ""
        }

        return (resolvedDisplay, hasTokenConflict ? nil : tokenName)
    }

    private func getOptionPresentation(
        _ options: [SequenceActiveOption<Target, Event>]
    ) -> (display: String, tokenName: String?) {
        var display: String?
        var tokenName: String?
        var hasDisplayConflict = false
        var hasTokenConflict = false

        for option in options {
            let part = option.part
            if display == nil {
                display = part.display
                tokenName = part.tokenName
                continue
            }
            if !hasDisplayConflict && display != part.display {
                hasDisplayConflict = true
            }
            if !hasTokenConflict && tokenName != part.tokenName {
                hasTokenConflict = true
            }
        }

        let resolvedDisplay: String
        if let existing = display, !hasDisplayConflict {
            resolvedDisplay = existing
        } else if let firstPart = options.first?.part {
            resolvedDisplay = (try? stringifyKeyStroke(.stroke(firstPart.stroke.asStrokeInput))) ?? firstPart.stroke.name
        } else {
            resolvedDisplay = ""
        }

        return (resolvedDisplay, hasTokenConflict ? nil : tokenName)
    }

    private func selectActiveBindings(
        _ bindings: [BindingState<Target, Event>],
        focused: Target?,
        activeView: ActiveCommandView<Target, Event>
    ) -> (bindings: [BindingState<Target, Event>], commandBinding: BindingState<Target, Event>?, stop: Bool)? {
        var selected: [BindingState<Target, Event>] = []
        var commandBinding: BindingState<Target, Event>?

        for binding in bindings {
            if !bindingMatchesRuntimeState(binding, focused: focused, activeView: activeView) {
                continue
            }

            selected.append(binding)
            if binding.command == nil {
                continue
            }

            if commandBinding == nil {
                commandBinding = binding
            }
            if !binding.fallthrough {
                return (selected, commandBinding, true)
            }
        }

        if selected.isEmpty {
            return nil
        }

        return (selected, commandBinding, false)
    }

    private func createActiveKeyState(
        stroke: NormalizedKeyStroke,
        selection: ActiveKeySelection<Target, Event>,
        includeBindings: Bool
    ) -> ActiveKeyState<Target, Event> {
        ActiveKeyState(
            stroke: stroke,
            display: selection.display,
            tokenName: selection.tokenName,
            continues: selection.continues,
            firstBinding: selection.firstBinding,
            commandBinding: selection.commandBinding,
            bindings: (includeBindings && selection.bindings != nil) ? selection.bindings : nil
        )
    }

    private func updateActiveKeyState(
        _ state: ActiveKeyState<Target, Event>,
        selection: ActiveKeySelection<Target, Event>,
        includeBindings: Bool
    ) {
        if state.firstBinding == nil, let first = selection.firstBinding {
            state.firstBinding = first
        }
        if state.commandBinding == nil, let cmd = selection.commandBinding {
            state.commandBinding = cmd
        }
        if selection.continues {
            state.continues = true
        }
        guard includeBindings, let extra = selection.bindings, !extra.isEmpty else {
            return
        }
        if state.bindings == nil {
            state.bindings = extra
        } else {
            state.bindings?.append(contentsOf: extra)
        }
    }

    private func materializeActiveKeys(
        _ activeKeys: [KeyMatch: ActiveKeyState<Target, Event>],
        keyOrder: [KeyMatch],
        includeBindings: Bool,
        includeMetadata: Bool,
        focused: Target?,
        activeView: ActiveCommandView<Target, Event>
    ) -> [ActiveKey<Target, Event>] {
        var materialized: [ActiveKey<Target, Event>] = []
        materialized.reserveCapacity(keyOrder.count)

        for key in keyOrder {
            guard let state = activeKeys[key] else { continue }
            if state.commandBinding == nil && !state.continues {
                continue
            }

            let bindings: [ActiveBinding<Target, Event>]?
            if includeBindings, let rawBindings = state.bindings, !rawBindings.isEmpty {
                bindings = collectActiveBindings(rawBindings, focused: focused, activeView: activeView)
            } else {
                bindings = nil
            }

            let bindingAttrs: Attributes? = includeMetadata ? state.firstBinding?.attrs : nil
            let commandAttrs: Attributes? =
                (includeMetadata && state.commandBinding != nil)
                ? catalog.getBindingCommandAttrs(state.commandBinding!, focused: focused, activeView: activeView)
                : nil

            materialized.append(
                ActiveKey(
                    stroke: cloneKeyStroke(state.stroke),
                    display: state.display,
                    tokenName: state.tokenName,
                    bindings: bindings,
                    bindingAttrs: bindingAttrs,
                    commandAttrs: commandAttrs,
                    command: state.commandBinding?.command,
                    continues: state.continues
                )
            )
        }

        return materialized
    }
}

// parity: keymap/src/services/activation.ts#createActivationService [status=implemented hash=02fb1eb288b6]
public func createActivationService<Host: KeymapHost>(
    state: LayerStackState<Host.Target, Host.Event>,
    host: Host,
    notify: KeymapNotifier,
    conditions: any ConditionService,
    catalog: any CommandCatalogService<Host.Target, Host.Event>,
    hasCommandResolvers: @escaping @Sendable () -> Bool = { false },
    options: ActivationOptions<Host.Target, Host.Event> = ActivationOptions()
) -> DefaultActivationService<Host> {
    DefaultActivationService(
        state: state,
        host: host,
        notify: notify,
        conditions: conditions,
        catalog: catalog,
        hasCommandResolvers: hasCommandResolvers,
        options: options
    )
}
