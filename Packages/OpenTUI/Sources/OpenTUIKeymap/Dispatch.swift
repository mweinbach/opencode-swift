// Pure Swift 6 port of keymap/src/services/dispatch.ts.

// MARK: - Dispatch Events, Interceptors & Disambiguation Types

public struct DispatchLayer<Target: Hashable & Sendable>: Equatable, Sendable {
    public let order: Int
    public let priority: Int
    public let target: Target?
    public let targetMode: TargetMode?

    public init(order: Int, priority: Int, target: Target? = nil, targetMode: TargetMode? = nil) {
        self.order = order
        self.priority = priority
        self.target = target
        self.targetMode = targetMode
    }
}

public struct DispatchBinding<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public let sequence: [KeySequencePart]
    public let command: BindingCommand<Target, Event>?
    public let commandAttrs: Attributes?
    public let attrs: Attributes?
    public let event: BindingEvent
    public let preventDefault: Bool
    public let `fallthrough`: Bool
    public let sourceLayerOrder: Int
    public let bindingIndex: Int

    public init(
        sequence: [KeySequencePart],
        command: BindingCommand<Target, Event>? = nil,
        commandAttrs: Attributes? = nil,
        attrs: Attributes? = nil,
        event: BindingEvent = .press,
        preventDefault: Bool = true,
        fallthrough isFallthrough: Bool = false,
        sourceLayerOrder: Int,
        bindingIndex: Int
    ) {
        self.sequence = sequence
        self.command = command
        self.commandAttrs = commandAttrs
        self.attrs = attrs
        self.event = event
        self.preventDefault = preventDefault
        self.`fallthrough` = isFallthrough
        self.sourceLayerOrder = sourceLayerOrder
        self.bindingIndex = bindingIndex
    }
}

public enum DispatchPhase: String, Equatable, Hashable, Sendable {
    case sequenceStart = "sequence-start"
    case sequenceAdvance = "sequence-advance"
    case sequenceClear = "sequence-clear"
    case bindingExecute = "binding-execute"
    case bindingReject = "binding-reject"
}

public struct DispatchEvent<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public let phase: DispatchPhase
    public let event: BindingEvent
    public let focused: Target?
    public let layer: DispatchLayer<Target>?
    public let binding: DispatchBinding<Target, Event>?
    public let sequence: [KeySequencePart]
    public let command: BindingCommand<Target, Event>?

    public init(
        phase: DispatchPhase,
        event: BindingEvent,
        focused: Target? = nil,
        layer: DispatchLayer<Target>? = nil,
        binding: DispatchBinding<Target, Event>? = nil,
        sequence: [KeySequencePart] = [],
        command: BindingCommand<Target, Event>? = nil
    ) {
        self.phase = phase
        self.event = event
        self.focused = focused
        self.layer = layer
        self.binding = binding
        self.sequence = sequence
        self.command = command
    }
}

public enum KeyAfterReason: String, Equatable, Hashable, Sendable {
    case interceptConsumed = "intercept-consumed"
    case bindingHandled = "binding-handled"
    case bindingRejected = "binding-rejected"
    case noMatch = "no-match"
    case sequencePending = "sequence-pending"
    case sequenceMiss = "sequence-miss"
    case sequenceCleared = "sequence-cleared"
}

public struct KeyConsumeOptions: Equatable, Hashable, Sendable {
    public let preventDefault: Bool
    public let stopPropagation: Bool

    public init(preventDefault: Bool = true, stopPropagation: Bool = true) {
        self.preventDefault = preventDefault
        self.stopPropagation = stopPropagation
    }
}

public struct KeyInterceptOptions: Equatable, Hashable, Sendable {
    public let priority: Int
    public let release: Bool

    public init(priority: Int = 0, release: Bool = false) {
        self.priority = priority
        self.release = release
    }
}

public struct RawInterceptOptions: Equatable, Hashable, Sendable {
    public let priority: Int

    public init(priority: Int = 0) {
        self.priority = priority
    }
}

public struct KeyInputContext<Event: KeymapEvent>: Sendable {
    public let event: Event
    private let setDataHandler: @Sendable (String, KeymapValue) -> Void
    private let getDataHandler: @Sendable (String) -> KeymapValue

    public init(
        event: Event,
        setData: @escaping @Sendable (String, KeymapValue) -> Void,
        getData: @escaping @Sendable (String) -> KeymapValue
    ) {
        self.event = event
        self.setDataHandler = setData
        self.getDataHandler = getData
    }

    public func setData(_ name: String, _ value: KeymapValue) {
        setDataHandler(name, value)
    }

    public func getData(_ name: String) -> KeymapValue {
        getDataHandler(name)
    }

    public func consume(_ options: KeyConsumeOptions = KeyConsumeOptions()) {
        if options.preventDefault {
            event.preventDefault()
        }
        if options.stopPropagation {
            event.stopPropagation()
        }
    }
}

public struct KeyAfterInputContext<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public let event: Event
    public let eventType: BindingEvent
    public let focused: Target?
    public let handled: Bool
    public let reason: KeyAfterReason
    public let sequence: [KeySequencePart]
    public let pendingSequence: [KeySequencePart]
    private let setDataHandler: @Sendable (String, KeymapValue) -> Void
    private let getDataHandler: @Sendable (String) -> KeymapValue

    public init(
        event: Event,
        eventType: BindingEvent,
        focused: Target?,
        handled: Bool,
        reason: KeyAfterReason,
        sequence: [KeySequencePart],
        pendingSequence: [KeySequencePart],
        setData: @escaping @Sendable (String, KeymapValue) -> Void,
        getData: @escaping @Sendable (String) -> KeymapValue
    ) {
        self.event = event
        self.eventType = eventType
        self.focused = focused
        self.handled = handled
        self.reason = reason
        self.sequence = sequence
        self.pendingSequence = pendingSequence
        self.setDataHandler = setData
        self.getDataHandler = getData
    }

    public func setData(_ name: String, _ value: KeymapValue) {
        setDataHandler(name, value)
    }

    public func getData(_ name: String) -> KeymapValue {
        getDataHandler(name)
    }

    public func consume(_ options: KeyConsumeOptions = KeyConsumeOptions()) {
        if options.preventDefault {
            event.preventDefault()
        }
        if options.stopPropagation {
            event.stopPropagation()
        }
    }
}

public final class RawInputContext: @unchecked Sendable {
    public let sequence: String
    public private(set) var isStopped: Bool = false

    public init(sequence: String) {
        self.sequence = sequence
    }

    public func stop() {
        isStopped = true
    }
}

public final class KeyDisambiguationContext<Target: Hashable & Sendable, Event: KeymapEvent>: @unchecked Sendable {
    public let event: Event
    public let focused: Target?
    private let sequenceProvider: @Sendable () -> [KeySequencePart]
    private let exactProvider: @Sendable () -> [ActiveBinding<Target, Event>]
    private let continuationsProvider: @Sendable () -> [ActiveKey<Target, Event>]
    private let getDataHandler: @Sendable (String) -> KeymapValue
    private let setDataHandler: @Sendable (String, KeymapValue) -> Void

    private var cachedSequence: [KeySequencePart]?
    private var cachedStroke: KeySequencePart?
    private var cachedExact: [ActiveBinding<Target, Event>]?
    private var cachedContinuations: [ActiveKey<Target, Event>]?

    public init(
        event: Event,
        focused: Target?,
        sequenceProvider: @escaping @Sendable () -> [KeySequencePart],
        exactProvider: @escaping @Sendable () -> [ActiveBinding<Target, Event>],
        continuationsProvider: @escaping @Sendable () -> [ActiveKey<Target, Event>],
        getData: @escaping @Sendable (String) -> KeymapValue,
        setData: @escaping @Sendable (String, KeymapValue) -> Void
    ) {
        self.event = event
        self.focused = focused
        self.sequenceProvider = sequenceProvider
        self.exactProvider = exactProvider
        self.continuationsProvider = continuationsProvider
        self.getDataHandler = getData
        self.setDataHandler = setData
    }

    public var sequence: [KeySequencePart] {
        if let cachedSequence {
            return cachedSequence
        }
        let cloned = cloneKeySequence(sequenceProvider())
        cachedSequence = cloned
        return cloned
    }

    public var stroke: KeySequencePart? {
        if let cachedStroke {
            return cachedStroke
        }
        guard let last = sequenceProvider().last else {
            return nil
        }
        let cloned = cloneKeySequencePart(last)
        cachedStroke = cloned
        return cloned
    }

    public var exact: [ActiveBinding<Target, Event>] {
        if let cachedExact {
            return cachedExact
        }
        let resolved = exactProvider()
        cachedExact = resolved
        return resolved
    }

    public var continuations: [ActiveKey<Target, Event>] {
        if let cachedContinuations {
            return cachedContinuations
        }
        let resolved = continuationsProvider()
        cachedContinuations = resolved
        return resolved
    }

    public func getData(_ name: String) -> KeymapValue {
        getDataHandler(name)
    }

    public func setData(_ name: String, _ value: KeymapValue) {
        setDataHandler(name, value)
    }

    public func runExact() -> InternalDisambiguationDecision {
        createSyncDecision(.runExact)
    }

    public func continueSequence() -> InternalDisambiguationDecision {
        createSyncDecision(.continueSequence)
    }

    public func clear() -> InternalDisambiguationDecision {
        createSyncDecision(.clear)
    }

    public func `defer`(_ run: @escaping KeyDeferredDisambiguationHandler) -> InternalDisambiguationDecision {
        createSyncDecision(.defer, handler: run)
    }
}

public typealias KeyDisambiguationResolver<Target: Hashable & Sendable, Event: KeymapEvent> =
    @Sendable (KeyDisambiguationContext<Target, Event>) throws -> InternalDisambiguationDecision?

// MARK: - Dispatch Service

// parity: keymap/src/services/dispatch.ts#DispatchService [status=implemented hash=c2768d18cd37]
public protocol DispatchService<Target, Event>: AnyObject, Sendable {
    associatedtype Target: Hashable & Sendable
    associatedtype Event: KeymapEvent

    @discardableResult
    func interceptKey(
        _ fn: @escaping @Sendable (KeyInputContext<Event>) throws -> Void,
        options: KeyInterceptOptions
    ) -> @Sendable () -> Void
    @discardableResult
    func interceptKeyAfter(
        _ fn: @escaping @Sendable (KeyAfterInputContext<Target, Event>) throws -> Void,
        options: KeyInterceptOptions
    ) -> @Sendable () -> Void
    @discardableResult
    func interceptRaw(
        _ fn: @escaping @Sendable (RawInputContext) throws -> Void,
        options: RawInterceptOptions
    ) -> @Sendable () -> Void
    @discardableResult
    func prependEventMatchResolver(_ resolver: @escaping EventMatchResolver<Event>) -> @Sendable () -> Void
    @discardableResult
    func appendEventMatchResolver(_ resolver: @escaping EventMatchResolver<Event>) -> @Sendable () -> Void
    func clearEventMatchResolvers()
    @discardableResult
    func prependDisambiguationResolver(
        _ resolver: @escaping KeyDisambiguationResolver<Target, Event>
    ) -> @Sendable () -> Void
    @discardableResult
    func appendDisambiguationResolver(
        _ resolver: @escaping KeyDisambiguationResolver<Target, Event>
    ) -> @Sendable () -> Void
    func clearDisambiguationResolvers()
    func handlePendingSequenceChange(
        previous: PendingSequenceState<Target, Event>?,
        next: PendingSequenceState<Target, Event>?
    )
    func handleRawSequence(_ sequence: String) -> Bool
    func handleKeyEvent(_ event: Event, release: Bool)
}

private struct KeyDispatchOutcome<Target: Hashable & Sendable, Event: KeymapEvent> {
    let handled: Bool
    let reason: KeyAfterReason
    let sequence: [KeySequencePart]?
    let captures: [PendingSequenceCapture<Target, Event>]?
}

public final class DefaultDispatchService<Target: Hashable & Sendable, Event: KeymapEvent>: DispatchService,
    @unchecked Sendable
{
    private let state: LayerStackState<Target, Event>
    private let notify: KeymapNotifier
    private let runtime: any RuntimeService
    private let activation: any ActivationService<Target, Event>
    private let conditions: any ConditionService
    private let executor: any CommandExecutorService<Target, Event>
    private let compiler: any CompilerService<Target, Event>
    private let catalog: any CommandCatalogService<Target, Event>
    private let layers: any LayerService<Target, Event>
    private let onDisambiguationPresenceChanged: @Sendable (Bool) -> Void
    private let onEmitDispatch: (@Sendable (DispatchEvent<Target, Event>) -> Void)?

    private let keyHooks = PriorityRegistry<@Sendable (KeyInputContext<Event>) throws -> Void, Bool>()
    private let keyAfterHooks = PriorityRegistry<@Sendable (KeyAfterInputContext<Target, Event>) throws -> Void, Bool>()
    private let rawHooks = PriorityRegistry<@Sendable (RawInputContext) throws -> Void, Void>()
    private let eventMatchResolvers: OrderedRegistry<EventMatchResolver<Event>>
    private let disambiguationResolvers = OrderedRegistry<KeyDisambiguationResolver<Target, Event>>()

    private var pendingDisambiguation: PendingDisambiguation<Target, Event>?
    private var nextPendingDisambiguationID: Int = 0

    public init(
        state: LayerStackState<Target, Event>,
        notify: KeymapNotifier,
        runtime: any RuntimeService,
        activation: any ActivationService<Target, Event>,
        conditions: any ConditionService,
        executor: any CommandExecutorService<Target, Event>,
        compiler: any CompilerService<Target, Event>,
        catalog: any CommandCatalogService<Target, Event>,
        layers: any LayerService<Target, Event>,
        initialEventMatchResolvers: [EventMatchResolver<Event>] = [defaultEventMatchResolver],
        onDisambiguationPresenceChanged: @escaping @Sendable (Bool) -> Void = { _ in },
        onEmitDispatch: (@Sendable (DispatchEvent<Target, Event>) -> Void)? = nil
    ) {
        self.state = state
        self.notify = notify
        self.runtime = runtime
        self.activation = activation
        self.conditions = conditions
        self.executor = executor
        self.compiler = compiler
        self.catalog = catalog
        self.layers = layers
        self.eventMatchResolvers = OrderedRegistry(initialEventMatchResolvers)
        self.onDisambiguationPresenceChanged = onDisambiguationPresenceChanged
        self.onEmitDispatch = onEmitDispatch
    }

    @discardableResult
    public func interceptKey(
        _ fn: @escaping @Sendable (KeyInputContext<Event>) throws -> Void,
        options: KeyInterceptOptions = KeyInterceptOptions()
    ) -> @Sendable () -> Void {
        keyHooks.register(fn, priority: options.priority, meta: options.release)
    }

    @discardableResult
    public func interceptKeyAfter(
        _ fn: @escaping @Sendable (KeyAfterInputContext<Target, Event>) throws -> Void,
        options: KeyInterceptOptions = KeyInterceptOptions()
    ) -> @Sendable () -> Void {
        keyAfterHooks.register(fn, priority: options.priority, meta: options.release)
    }

    @discardableResult
    public func interceptRaw(
        _ fn: @escaping @Sendable (RawInputContext) throws -> Void,
        options: RawInterceptOptions = RawInterceptOptions()
    ) -> @Sendable () -> Void {
        rawHooks.register(fn, priority: options.priority, meta: ())
    }

    @discardableResult
    public func prependEventMatchResolver(
        _ resolver: @escaping EventMatchResolver<Event>
    ) -> @Sendable () -> Void {
        eventMatchResolvers.prepend(resolver)
    }

    @discardableResult
    public func appendEventMatchResolver(
        _ resolver: @escaping EventMatchResolver<Event>
    ) -> @Sendable () -> Void {
        eventMatchResolvers.append(resolver)
    }

    public func clearEventMatchResolvers() {
        eventMatchResolvers.clear()
    }

    @discardableResult
    public func prependDisambiguationResolver(
        _ resolver: @escaping KeyDisambiguationResolver<Target, Event>
    ) -> @Sendable () -> Void {
        mutateDisambiguationResolvers {
            disambiguationResolvers.prepend(resolver)
        }
    }

    @discardableResult
    public func appendDisambiguationResolver(
        _ resolver: @escaping KeyDisambiguationResolver<Target, Event>
    ) -> @Sendable () -> Void {
        mutateDisambiguationResolvers {
            disambiguationResolvers.append(resolver)
        }
    }

    public func clearDisambiguationResolvers() {
        if !disambiguationResolvers.has() {
            return
        }
        notify.runWithStateChangeBatch {
            disambiguationResolvers.clear()
            onDisambiguationPresenceChanged(false)
            layers.recompileBindings()
        }
    }

    public func handlePendingSequenceChange(
        previous: PendingSequenceState<Target, Event>?,
        next: PendingSequenceState<Target, Event>?
    ) {
        if pendingDisambiguation == nil {
            return
        }
        cancelPendingDisambiguation()
    }

    public func handleRawSequence(_ sequence: String) -> Bool {
        let hooks = rawHooks.entries()
        if hooks.isEmpty {
            return false
        }

        let context = RawInputContext(sequence: sequence)
        for hook in hooks {
            do {
                try hook.listener(context)
            } catch {
                notify.emitError(
                    "raw-intercept-error",
                    error: error,
                    message: "[Keymap] Error in raw intercept listener:"
                )
            }
            if context.isStopped {
                return true
            }
        }
        return false
    }

    public func handleKeyEvent(_ event: Event, release: Bool = false) {
        if !release {
            cancelPendingDisambiguation()
        }

        let afterHooks = getKeyAfterHooks(release: release)
        let afterFocused = afterHooks != nil ? activation.getFocusedTarget() : nil
        let hooks = keyHooks.entries()
        let context = KeyInputContext<Event>(
            event: event,
            setData: { [runtime] name, value in runtime.setData(name, value) },
            getData: { [runtime] name in runtime.getData(name) }
        )

        for hook in hooks where hook.meta == release {
            do {
                try hook.listener(context)
            } catch {
                notify.emitError(
                    "key-intercept-error",
                    error: error,
                    message: "[Keymap] Error in key intercept listener:"
                )
            }

            if event.propagationStopped {
                if let afterHooks {
                    emitKeyAfter(
                        afterHooks,
                        event: event,
                        release: release,
                        focused: afterFocused,
                        outcome: KeyDispatchOutcome(
                            handled: true,
                            reason: .interceptConsumed,
                            sequence: [],
                            captures: nil
                        )
                    )
                }
                return
            }
        }

        let outcome: KeyDispatchOutcome<Target, Event>
        if release {
            outcome = dispatchReleaseLayers(event)
        } else {
            outcome = dispatchLayers(event)
        }

        if let afterHooks {
            emitKeyAfter(afterHooks, event: event, release: release, focused: afterFocused, outcome: outcome)
        }
    }

    // MARK: - Internal Dispatch Flow

    private func mutateDisambiguationResolvers(
        _ register: () -> (@Sendable () -> Void)
    ) -> @Sendable () -> Void {
        notify.runWithStateChangeBatch {
            let hadResolvers = disambiguationResolvers.has()
            let off = register()

            if !hadResolvers && disambiguationResolvers.has() {
                onDisambiguationPresenceChanged(true)
                layers.recompileBindings()
            }

            return { [weak self] in
                guard let self else { return }
                self.notify.runWithStateChangeBatch {
                    let hadBeforeRemoval = self.disambiguationResolvers.has()
                    off()
                    if hadBeforeRemoval && !self.disambiguationResolvers.has() {
                        self.onDisambiguationPresenceChanged(false)
                        self.layers.recompileBindings()
                    }
                }
            }
        }
    }

    private func getKeyAfterHooks(
        release: Bool
    ) -> [PriorityRegistry<@Sendable (KeyAfterInputContext<Target, Event>) throws -> Void, Bool>.Entry]? {
        let entries = keyAfterHooks.entries()
        if entries.contains(where: { $0.meta == release }) {
            return entries
        }
        return nil
    }

    private func emitKeyAfter(
        _ hooks: [PriorityRegistry<@Sendable (KeyAfterInputContext<Target, Event>) throws -> Void, Bool>.Entry],
        event: Event,
        release: Bool,
        focused: Target?,
        outcome: KeyDispatchOutcome<Target, Event>
    ) {
        let sequence: [KeySequencePart]
        if let seq = outcome.sequence {
            sequence = cloneKeySequence(seq)
        } else if let captures = outcome.captures {
            sequence = activation.collectSequencePartsFromPending(PendingSequenceState(captures: captures))
        } else {
            sequence = []
        }

        let ctx = KeyAfterInputContext<Target, Event>(
            event: event,
            eventType: release ? .release : .press,
            focused: focused,
            handled: outcome.handled,
            reason: outcome.reason,
            sequence: sequence,
            pendingSequence: activation.getPendingSequence(),
            setData: { [runtime] name, value in runtime.setData(name, value) },
            getData: { [runtime] name in runtime.getData(name) }
        )

        for hook in hooks where hook.meta == release {
            do {
                try hook.listener(ctx)
            } catch {
                notify.emitError(
                    "key-after-intercept-error",
                    error: error,
                    message: "[Keymap] Error in key:after intercept listener:"
                )
            }
        }
    }

    private func emitBindingDispatch(
        phase: DispatchPhase,
        layer: RegisteredLayer<Target, Event>,
        binding: BindingState<Target, Event>,
        focused: Target?
    ) {
        guard let onEmitDispatch else { return }
        let dispatchBinding = DispatchBinding<Target, Event>(
            sequence: cloneKeySequence(binding.sequence),
            command: binding.command,
            commandAttrs: catalog.getBindingCommandAttrs(
                binding,
                focused: focused,
                activeView: catalog.getActiveCommandView(focused: focused)
            ),
            attrs: binding.attrs,
            event: binding.event,
            preventDefault: binding.preventDefault,
            fallthrough: binding.fallthrough,
            sourceLayerOrder: binding.sourceLayerOrder,
            bindingIndex: binding.bindingIndex
        )
        onEmitDispatch(
            DispatchEvent(
                phase: phase,
                event: binding.event,
                focused: focused,
                layer: DispatchLayer(
                    order: layer.order,
                    priority: layer.priority,
                    target: layer.target,
                    targetMode: layer.targetMode
                ),
                binding: dispatchBinding,
                sequence: cloneKeySequence(binding.sequence),
                command: binding.command
            )
        )
    }

    private func emitSequenceDispatch(
        phase: DispatchPhase,
        captures: [PendingSequenceCapture<Target, Event>],
        focused: Target?
    ) {
        guard let onEmitDispatch else { return }
        let first = captures.first
        let sequence =
            captures.isEmpty
            ? []
            : activation.collectSequencePartsFromPending(PendingSequenceState(captures: captures))
        onEmitDispatch(
            DispatchEvent(
                phase: phase,
                event: .press,
                focused: focused,
                layer: first.map {
                    DispatchLayer(
                        order: $0.layer.order,
                        priority: $0.layer.priority,
                        target: $0.layer.target,
                        targetMode: $0.layer.targetMode
                    )
                },
                binding: nil,
                sequence: sequence,
                command: nil
            )
        )
    }

    private func noMatchOutcome() -> KeyDispatchOutcome<Target, Event> {
        KeyDispatchOutcome(handled: false, reason: .noMatch, sequence: nil, captures: nil)
    }

    private func createSequenceOutcome(
        reason: KeyAfterReason,
        captures: [PendingSequenceCapture<Target, Event>]
    ) -> KeyDispatchOutcome<Target, Event> {
        KeyDispatchOutcome(handled: reason != .sequenceMiss, reason: reason, sequence: nil, captures: captures)
    }

    private func createBindingOutcome(
        _ binding: BindingState<Target, Event>,
        handled: Bool
    ) -> KeyDispatchOutcome<Target, Event> {
        KeyDispatchOutcome(
            handled: handled,
            reason: handled ? .bindingHandled : .bindingRejected,
            sequence: binding.sequence,
            captures: nil
        )
    }

    private func preferDispatchOutcome(
        _ current: KeyDispatchOutcome<Target, Event>,
        _ next: KeyDispatchOutcome<Target, Event>
    ) -> KeyDispatchOutcome<Target, Event> {
        if next.handled || current.reason == .noMatch {
            return next
        }
        return current
    }

    private func consumeSequenceEvent(_ event: Event) {
        event.preventDefault()
        event.stopPropagation()
    }

    private func holdSequence(
        phase: DispatchPhase,
        captures: [PendingSequenceCapture<Target, Event>],
        focused: Target?,
        event: Event
    ) -> KeyDispatchOutcome<Target, Event> {
        activation.setPendingSequence(PendingSequenceState(captures: captures))
        let outcome = createSequenceOutcome(reason: .sequencePending, captures: captures)
        emitSequenceDispatch(phase: phase, captures: captures, focused: focused)
        consumeSequenceEvent(event)
        return outcome
    }

    private func clearSequence(
        captures: [PendingSequenceCapture<Target, Event>],
        focused: Target?,
        event: Event
    ) -> KeyDispatchOutcome<Target, Event> {
        let outcome = createSequenceOutcome(reason: .sequenceCleared, captures: captures)
        emitSequenceDispatch(phase: .sequenceClear, captures: captures, focused: focused)
        activation.setPendingSequence(nil)
        consumeSequenceEvent(event)
        return outcome
    }

    private func dispatchReleaseLayers(_ event: Event) -> KeyDispatchOutcome<Target, Event> {
        let focused = activation.getFocusedTarget()
        let activeLayers = activation.getActiveLayers(focused: focused)
        let matchKeys = resolveEventMatchKeys(event)
        var outcome = noMatchOutcome()

        for strokeKey in matchKeys {
            for layer in activeLayers {
                if layer.bindings.isEmpty || !conditions.matchesConditions(layer) {
                    continue
                }
                let result = runReleaseBindings(layer: layer, strokeKey: strokeKey, event: event, focused: focused)
                outcome = preferDispatchOutcome(outcome, result.outcome)
                if !result.handled {
                    continue
                }
                if result.stop {
                    return outcome
                }
            }
        }

        return outcome
    }

    private func dispatchLayers(_ event: Event) -> KeyDispatchOutcome<Target, Event> {
        let focused = activation.getFocusedTarget()
        let pending = activation.ensureValidPendingSequence()
        let matchKeys = resolveEventMatchKeys(event)

        if let pending {
            return dispatchPendingSequence(pending, matchKeys: matchKeys, event: event, focused: focused)
        }

        let activeLayers = activation.getActiveLayers(focused: focused)
        var outcome = noMatchOutcome()

        for matchKey in matchKeys {
            let result = dispatchFromRootAtIndex(
                activeLayers: activeLayers,
                startIndex: 0,
                matchKeys: [matchKey],
                event: event,
                focused: focused
            )
            outcome = preferDispatchOutcome(outcome, result)
            if result.handled {
                return outcome
            }
        }

        return outcome
    }

    private func dispatchPendingSequence(
        _ pending: PendingSequenceState<Target, Event>,
        matchKeys: [KeyMatch],
        event: Event,
        focused: Target?
    ) -> KeyDispatchOutcome<Target, Event> {
        let activeView = catalog.getActiveCommandView(focused: focused)
        var advancedCaptures: [PendingSequenceCapture<Target, Event>] = []

        for capture in pending.captures {
            if let advanced = advanceSequenceCapture(
                capture,
                matchKeys: matchKeys,
                event: event,
                patterns: state.patterns,
                matchPattern: { [self] name, ev in self.matchPattern(name, ev) },
                createPatternPart: { [self] ev, name, match in self.createPatternPart(ev, name, match) }
            ) {
                advancedCaptures.append(advanced)
            }
        }

        let bestPriority = advancedCaptures.reduce(Int.max) { best, capture in
            min(best, capturePriority(capture, matchKeys: matchKeys))
        }
        let prioritizedCaptures = advancedCaptures.filter {
            capturePriority($0, matchKeys: matchKeys) == bestPriority
        }

        if prioritizedCaptures.isEmpty
            || !prioritizedCaptures.contains(where: { captureIsReachable($0, focused: focused, activeView: activeView) })
        {
            let outcome = createSequenceOutcome(reason: .sequenceMiss, captures: pending.captures)
            emitSequenceDispatch(phase: .sequenceClear, captures: pending.captures, focused: focused)
            activation.setPendingSequence(nil)
            return outcome
        }

        return dispatchPendingCapturesFromIndex(
            prioritizedCaptures,
            startIndex: 0,
            handledExact: false,
            event: event,
            focused: focused
        )
    }

    private func dispatchPendingCapturesFromIndex(
        _ advancedCaptures: [PendingSequenceCapture<Target, Event>],
        startIndex: Int,
        handledExact: Bool,
        event: Event,
        focused: Target?
    ) -> KeyDispatchOutcome<Target, Event> {
        var hasHandledExact = handledExact
        var outcome = noMatchOutcome()
        var processedExactBindings: Set<ObjectIdentifier> = []

        for index in startIndex..<advancedCaptures.count {
            let capture = advancedCaptures[index]
            if processedExactBindings.contains(ObjectIdentifier(capture.binding)) {
                continue
            }

            let continuationCapturesForPrefix = collectContinuationCapturesForPrefix(
                advancedCaptures,
                startIndex: index,
                prefix: capture
            )
            if !continuationCapturesForPrefix.isEmpty {
                if hasHandledExact {
                    continue
                }

                let exactCaptures = collectExactCapturesForPrefix(advancedCaptures, prefix: capture)
                if let resolvedOutcome = tryResolvePendingAmbiguity(
                    advancedCaptures: advancedCaptures,
                    captureIndex: index,
                    continuationCaptures: continuationCapturesForPrefix,
                    exactCaptures: exactCaptures,
                    event: event,
                    focused: focused,
                    handledExact: hasHandledExact
                ) {
                    return resolvedOutcome
                }

                return holdSequence(
                    phase: .sequenceAdvance,
                    captures: continuationCapturesForPrefix,
                    focused: focused,
                    event: event
                )
            }

            if !captureIsExact(capture, patterns: state.patterns) {
                continue
            }

            let exactCaptures = collectExactCapturesForPrefix(advancedCaptures, prefix: capture)
            for exact in exactCaptures {
                processedExactBindings.insert(ObjectIdentifier(exact.binding))
            }
            let result = runCaptureBindings(layer: capture.layer, captures: exactCaptures, event: event, focused: focused)
            outcome = preferDispatchOutcome(outcome, result.outcome)
            if !result.handled {
                continue
            }

            hasHandledExact = true
            if result.stop {
                emitSequenceDispatch(phase: .sequenceClear, captures: advancedCaptures, focused: focused)
                activation.setPendingSequence(nil)
                return outcome
            }
        }

        emitSequenceDispatch(phase: .sequenceClear, captures: advancedCaptures, focused: focused)
        activation.setPendingSequence(nil)
        return outcome
    }

    private func dispatchFromRootAtIndex(
        activeLayers: [RegisteredLayer<Target, Event>],
        startIndex: Int,
        matchKeys: [KeyMatch],
        event: Event,
        focused: Target?
    ) -> KeyDispatchOutcome<Target, Event> {
        let activeView = catalog.getActiveCommandView(focused: focused)
        var outcome = noMatchOutcome()

        for index in startIndex..<activeLayers.count {
            let layer = activeLayers[index]
            if !conditions.matchesConditions(layer) {
                continue
            }

            let captures = collectRootCaptures(
                layer: layer,
                matchKeys: matchKeys,
                event: event,
                focused: focused,
                activeView: activeView
            )
            if captures.isEmpty {
                continue
            }

            let layerContinuationCaptures = captures.filter {
                captureHasContinuations($0, patterns: state.patterns, missingPatternMinimum: false)
            }
            if !layerContinuationCaptures.isEmpty {
                let exactCaptures = captures.filter { captureIsExact($0, patterns: state.patterns) }
                let continuationCaptures = collectPendingCapturesFromRoot(
                    activeLayers: activeLayers,
                    startIndex: index,
                    matchKeys: matchKeys,
                    event: event,
                    focused: focused
                )
                if let resolvedOutcome = tryResolveRootAmbiguity(
                    activeLayers: activeLayers,
                    layerIndex: index,
                    matchKeys: matchKeys,
                    continuationCaptures: continuationCaptures,
                    exactCaptures: exactCaptures,
                    event: event,
                    focused: focused
                ) {
                    return resolvedOutcome
                }

                return holdSequence(
                    phase: .sequenceStart,
                    captures: continuationCaptures,
                    focused: focused,
                    event: event
                )
            }

            let exactCaptures = captures.filter { captureIsExact($0, patterns: state.patterns) }
            let result = runCaptureBindings(layer: layer, captures: exactCaptures, event: event, focused: focused)
            outcome = preferDispatchOutcome(outcome, result.outcome)
            if !result.handled {
                continue
            }
            if result.stop {
                return outcome
            }
        }

        return outcome
    }

    private func tryResolveRootAmbiguity(
        activeLayers: [RegisteredLayer<Target, Event>],
        layerIndex: Int,
        matchKeys: [KeyMatch],
        continuationCaptures: [PendingSequenceCapture<Target, Event>],
        exactCaptures: [PendingSequenceCapture<Target, Event>],
        event: Event,
        focused: Target?
    ) -> KeyDispatchOutcome<Target, Event>? {
        let applyExact: @Sendable () -> KeyDispatchOutcome<Target, Event> = { [self] in
            self.activation.setPendingSequence(nil)
            guard let layer = exactCaptures.first?.layer else {
                return self.noMatchOutcome()
            }
            let result = self.runCaptureBindings(layer: layer, captures: exactCaptures, event: event, focused: focused)
            if !result.stop {
                return self.preferDispatchOutcome(
                    result.outcome,
                    self.dispatchFromRootAtIndex(
                        activeLayers: activeLayers,
                        startIndex: layerIndex + 1,
                        matchKeys: matchKeys,
                        event: event,
                        focused: focused
                    )
                )
            }
            return result.outcome
        }

        return tryResolveAmbiguity(
            event: event,
            focused: focused,
            continuationCaptures: continuationCaptures,
            exactBindingsSource: exactCaptures.map(\.binding),
            sequencePhase: .sequenceStart,
            runExact: applyExact
        )
    }

    private func tryResolvePendingAmbiguity(
        advancedCaptures: [PendingSequenceCapture<Target, Event>],
        captureIndex: Int,
        continuationCaptures: [PendingSequenceCapture<Target, Event>],
        exactCaptures: [PendingSequenceCapture<Target, Event>],
        event: Event,
        focused: Target?,
        handledExact: Bool
    ) -> KeyDispatchOutcome<Target, Event>? {
        let applyExact: @Sendable () -> KeyDispatchOutcome<Target, Event> = { [self] in
            self.activation.setPendingSequence(nil)
            guard let layer = exactCaptures.first?.layer else {
                return self.noMatchOutcome()
            }
            let result = self.runCaptureBindings(layer: layer, captures: exactCaptures, event: event, focused: focused)
            if result.stop {
                return result.outcome
            }
            return self.preferDispatchOutcome(
                result.outcome,
                self.dispatchPendingCapturesFromIndex(
                    advancedCaptures,
                    startIndex: captureIndex + 1,
                    handledExact: handledExact || result.handled,
                    event: event,
                    focused: focused
                )
            )
        }

        return tryResolveAmbiguity(
            event: event,
            focused: focused,
            continuationCaptures: continuationCaptures,
            exactBindingsSource: exactCaptures.map(\.binding),
            sequencePhase: .sequenceAdvance,
            runExact: applyExact
        )
    }

    private func tryResolveAmbiguity(
        event: Event,
        focused: Target?,
        continuationCaptures: [PendingSequenceCapture<Target, Event>],
        exactBindingsSource: [BindingState<Target, Event>],
        sequencePhase: DispatchPhase,
        runExact: @escaping @Sendable () -> KeyDispatchOutcome<Target, Event>
    ) -> KeyDispatchOutcome<Target, Event>? {
        if !disambiguationResolvers.has() || continuationCaptures.isEmpty {
            return nil
        }

        let activeView = catalog.getActiveCommandView(focused: focused)
        let exactBindings = activation.collectMatchingBindings(exactBindingsSource, focused: focused, activeView: activeView)
        if !exactBindings.contains(where: { $0.command != nil }) {
            return nil
        }

        let continueSequence: @Sendable () -> KeyDispatchOutcome<Target, Event> = { [self] in
            self.holdSequence(phase: sequencePhase, captures: continuationCaptures, focused: focused, event: event)
        }
        let clear: @Sendable () -> KeyDispatchOutcome<Target, Event> = { [self] in
            self.clearSequence(captures: continuationCaptures, focused: focused, event: event)
        }

        let sequenceParts = activation.collectSequencePartsFromPending(
            PendingSequenceState(captures: continuationCaptures)
        )
        let decision = resolveDisambiguation(
            event: event,
            focused: focused,
            sequenceParts: sequenceParts,
            exactBindings: exactBindings,
            continuationCaptures: continuationCaptures,
            activeView: activeView
        )

        guard let decision else {
            warnUnresolvedAmbiguity(sequenceParts)
            return continueSequence()
        }

        switch decision.action {
        case .runExact:
            return runExact()
        case .continueSequence:
            return continueSequence()
        case .clear:
            return clear()
        case .defer:
            let outcome = continueSequence()
            if let handler = decision.handler {
                scheduleDeferredDisambiguation(
                    captures: continuationCaptures,
                    handler: handler,
                    focused: focused,
                    sequence: sequenceParts,
                    apply: { nextDecision in
                        guard let nextDecision else { return }
                        switch nextDecision.action {
                        case .runExact:
                            _ = runExact()
                        case .continueSequence:
                            _ = continueSequence()
                        case .clear:
                            _ = clear()
                        }
                    }
                )
            }
            return outcome
        }
    }

    private func resolveDisambiguation(
        event: Event,
        focused: Target?,
        sequenceParts: [KeySequencePart],
        exactBindings: [BindingState<Target, Event>],
        continuationCaptures: [PendingSequenceCapture<Target, Event>],
        activeView: ActiveCommandView<Target, Event>
    ) -> InternalDisambiguationDecision? {
        let ctx = KeyDisambiguationContext<Target, Event>(
            event: event,
            focused: focused,
            sequenceProvider: { sequenceParts },
            exactProvider: { [activation] in
                activation.collectActiveBindings(exactBindings, focused: focused, activeView: activeView).map { binding in
                    ActiveBinding(
                        sequence: cloneKeySequence(binding.sequence),
                        command: binding.command,
                        commandAttrs: binding.commandAttrs,
                        attrs: binding.attrs,
                        event: binding.event,
                        preventDefault: binding.preventDefault,
                        fallthrough: binding.fallthrough
                    )
                }
            },
            continuationsProvider: { [activation] in
                activation.getActiveKeysForCaptures(
                    continuationCaptures,
                    options: ActiveKeyOptions(includeBindings: true, includeMetadata: true)
                )
            },
            getData: { [runtime] name in runtime.getData(name) },
            setData: { [runtime] name, value in runtime.setData(name, value) }
        )

        for resolver in disambiguationResolvers.values() {
            do {
                if let result = try resolver(ctx) {
                    return result
                }
            } catch {
                notify.emitError(
                    "disambiguation-resolver-error",
                    error: error,
                    message: "[Keymap] Error in disambiguation resolver:"
                )
            }
        }
        return nil
    }

    private func scheduleDeferredDisambiguation(
        captures: [PendingSequenceCapture<Target, Event>],
        handler: @escaping KeyDeferredDisambiguationHandler,
        focused: Target?,
        sequence: [KeySequencePart],
        apply: @escaping @Sendable (InternalDeferredDisambiguationDecision?) -> Void
    ) {
        cancelPendingDisambiguation()

        let controller = KeymapAbortController()
        let id = nextPendingDisambiguationID
        nextPendingDisambiguationID += 1
        let pending = PendingDisambiguation<Target, Event>(
            id: id,
            controller: controller,
            captures: captures,
            apply: apply
        )
        pendingDisambiguation = pending

        let clonedSequence = cloneKeySequence(sequence)
        Task { [weak self] in
            guard let self, self.isPendingDisambiguationCurrent(id: id) else {
                return
            }
            let deferredCtx = KeyDeferredDisambiguationContext(
                signal: controller.signal,
                sequence: clonedSequence,
                focused: focused
            )
            let result = await handler(deferredCtx)
            guard self.isPendingDisambiguationCurrent(id: id) else {
                return
            }
            self.finishPendingDisambiguation(id: id)
            pending.apply(result)
        }
    }

    private func finishPendingDisambiguation(id: Int) {
        if pendingDisambiguation?.id == id {
            pendingDisambiguation = nil
        }
    }

    private func cancelPendingDisambiguation() {
        guard let pending = pendingDisambiguation else {
            return
        }
        pendingDisambiguation = nil
        pending.controller.abort()
    }

    private func isPendingDisambiguationCurrent(id: Int) -> Bool {
        pendingDisambiguation?.id == id
    }

    private func warnUnresolvedAmbiguity(_ sequence: [KeySequencePart]) {
        let display =
            (try? stringifyKeySequence(sequence.map { .part($0) }, options: StringifyOptions(preferDisplay: true)))
            ?? sequence.map(\.display).joined()
        notify.warnOnce(
            key: "unresolved-disambiguation:\(display)",
            code: "unresolved-disambiguation",
            detail: display,
            message:
                "[Keymap] Ambiguous exact/prefix sequence \"\(display)\" fell back to prefix handling because no disambiguation resolver resolved it"
        )
    }

    private func collectPendingCapturesFromRoot(
        activeLayers: [RegisteredLayer<Target, Event>],
        startIndex: Int,
        matchKeys: [KeyMatch],
        event: Event,
        focused: Target?
    ) -> [PendingSequenceCapture<Target, Event>] {
        var captures: [PendingSequenceCapture<Target, Event>] = []
        let activeView = catalog.getActiveCommandView(focused: focused)

        for index in startIndex..<activeLayers.count {
            let layer = activeLayers[index]
            if !conditions.matchesConditions(layer) {
                continue
            }
            for capture in collectRootCaptures(
                layer: layer,
                matchKeys: matchKeys,
                event: event,
                focused: focused,
                activeView: activeView
            ) {
                if captureHasContinuations(capture, patterns: state.patterns, missingPatternMinimum: false) {
                    captures.append(capture)
                }
            }
        }
        return captures
    }

    private func collectContinuationCapturesForPrefix(
        _ captures: [PendingSequenceCapture<Target, Event>],
        startIndex: Int,
        prefix: PendingSequenceCapture<Target, Event>
    ) -> [PendingSequenceCapture<Target, Event>] {
        var result: [PendingSequenceCapture<Target, Event>] = []
        for idx in startIndex..<captures.count {
            let candidate = captures[idx]
            if captureHasContinuations(candidate, patterns: state.patterns, missingPatternMinimum: false)
                && sameSequenceParts(candidate.parts, prefix.parts)
            {
                result.append(candidate)
            }
        }
        return result
    }

    private func collectExactCapturesForPrefix(
        _ captures: [PendingSequenceCapture<Target, Event>],
        prefix: PendingSequenceCapture<Target, Event>
    ) -> [PendingSequenceCapture<Target, Event>] {
        captures.filter { capture in
            capture.layer === prefix.layer
                && captureIsExact(capture, patterns: state.patterns)
                && sameSequenceParts(capture.parts, prefix.parts)
        }
    }

    private func resolveEventMatchKeys(_ event: Event) -> [KeyMatch] {
        let resolvers = eventMatchResolvers.values()
        if resolvers.isEmpty {
            return []
        }

        let ctx = EventMatchResolverContext { [compiler] key in
            try compiler.parseTokenKey(key).match
        }

        var keys: [KeyMatch] = []
        var seen: Set<KeyMatch> = []

        for resolver in resolvers {
            let resolved: [KeyMatch]?
            do {
                resolved = try resolver(event, ctx)
            } catch {
                notify.emitError(
                    "event-match-resolver-error",
                    error: error,
                    message: "[Keymap] Error in event match resolver:"
                )
                continue
            }

            guard let resolved, !resolved.isEmpty else {
                continue
            }

            for candidate in resolved where !seen.contains(candidate) {
                seen.insert(candidate)
                keys.append(candidate)
            }
        }

        return keys
    }

    private func runReleaseBindings(
        layer: RegisteredLayer<Target, Event>,
        strokeKey: KeyMatch,
        event: Event,
        focused: Target?
    ) -> (handled: Bool, stop: Bool, outcome: KeyDispatchOutcome<Target, Event>) {
        var handled = false
        var outcome = noMatchOutcome()

        for binding in layer.bindings {
            if binding.event != .release {
                continue
            }
            guard let firstPart = binding.sequence.first, firstPart.match == strokeKey else {
                continue
            }
            if !conditions.matchesConditions(binding) {
                continue
            }

            let bindingHandled = executor.runBinding(
                layer: layer,
                binding: binding,
                event: event,
                focused: focused,
                payload: nil
            )
            outcome = preferDispatchOutcome(outcome, createBindingOutcome(binding, handled: bindingHandled))
            if !bindingHandled {
                emitBindingDispatch(phase: .bindingReject, layer: layer, binding: binding, focused: focused)
                continue
            }

            emitBindingDispatch(phase: .bindingExecute, layer: layer, binding: binding, focused: focused)
            handled = true
            if !binding.fallthrough {
                return (true, true, outcome)
            }
        }

        return (handled, false, outcome)
    }

    private func matchPattern(_ patternName: String, _ event: Event) -> SequencePatternMatch? {
        matchSequencePattern(patterns: state.patterns, notify: notify, patternName: patternName, event: event)
    }

    private func createPatternPart(
        _ event: Event,
        _ patternName: String,
        _ match: SequencePatternMatch
    ) -> KeySequencePart {
        if let created = try? createPatternEventPart(
            patterns: state.patterns,
            event: event,
            patternName: patternName,
            match: match
        ) {
            return created
        }
        let pattern = state.patterns[patternName]
        return KeySequencePart(
            stroke: NormalizedKeyStroke(
                name: event.name.lowercased(),
                ctrl: event.ctrl,
                shift: event.shift,
                meta: event.meta,
                super: event.`super` ?? false,
                hyper: event.hyper == true ? true : nil
            ),
            display: match.display ?? match.value?.stringDescription ?? event.name,
            match: pattern?.match ?? "pattern:\(patternName)",
            patternName: patternName,
            payloadKey: pattern?.payloadKey ?? patternName
        )
    }

    private func collectRootCaptures(
        layer: RegisteredLayer<Target, Event>,
        matchKeys: [KeyMatch],
        event: Event,
        focused: Target?,
        activeView: ActiveCommandView<Target, Event>
    ) -> [PendingSequenceCapture<Target, Event>] {
        let captures = collectRootSequenceCaptures(
            layer: layer,
            matchKeys: matchKeys,
            event: event,
            matchPattern: { [self] name, ev in self.matchPattern(name, ev) },
            createPatternPart: { [self] ev, name, match in self.createPatternPart(ev, name, match) }
        )
        return captures.contains(where: { captureIsReachable($0, focused: focused, activeView: activeView) })
            ? captures
            : []
    }

    private func captureIsReachable(
        _ capture: PendingSequenceCapture<Target, Event>,
        focused: Target?,
        activeView: ActiveCommandView<Target, Event>
    ) -> Bool {
        conditions.matchesConditions(capture.binding)
            && catalog.isBindingVisible(capture.binding, focused: focused, activeView: activeView)
    }

    private func runCaptureBindings(
        layer: RegisteredLayer<Target, Event>,
        captures: [PendingSequenceCapture<Target, Event>],
        event: Event,
        focused: Target?
    ) -> (handled: Bool, stop: Bool, outcome: KeyDispatchOutcome<Target, Event>) {
        var handled = false
        var outcome = noMatchOutcome()

        for capture in captures {
            let binding = capture.binding
            if !conditions.matchesConditions(binding) {
                continue
            }

            let payload = createSequencePayload(patterns: state.patterns, notify: notify, capture: capture)
            let bindingHandled = executor.runBinding(
                layer: layer,
                binding: binding,
                event: event,
                focused: focused,
                payload: payload
            )
            outcome = preferDispatchOutcome(outcome, createBindingOutcome(binding, handled: bindingHandled))
            if !bindingHandled {
                emitBindingDispatch(phase: .bindingReject, layer: layer, binding: binding, focused: focused)
                continue
            }

            emitBindingDispatch(phase: .bindingExecute, layer: layer, binding: binding, focused: focused)
            handled = true
            if !binding.fallthrough {
                return (true, true, outcome)
            }
        }

        return (handled, false, outcome)
    }
}

private func sameSequenceParts(_ left: [KeySequencePart], _ right: [KeySequencePart]) -> Bool {
    guard left.count == right.count else {
        return false
    }
    for index in 0..<left.count {
        if left[index].match != right[index].match {
            return false
        }
    }
    return true
}

// parity: keymap/src/services/dispatch.ts#createDispatchService [status=implemented hash=778beb5bf1e9]
public func createDispatchService<Target: Hashable & Sendable, Event: KeymapEvent>(
    state: LayerStackState<Target, Event>,
    notify: KeymapNotifier,
    runtime: any RuntimeService,
    activation: any ActivationService<Target, Event>,
    conditions: any ConditionService,
    executor: any CommandExecutorService<Target, Event>,
    compiler: any CompilerService<Target, Event>,
    catalog: any CommandCatalogService<Target, Event>,
    layers: any LayerService<Target, Event>,
    initialEventMatchResolvers: [EventMatchResolver<Event>] = [defaultEventMatchResolver],
    onDisambiguationPresenceChanged: @escaping @Sendable (Bool) -> Void = { _ in },
    onEmitDispatch: (@Sendable (DispatchEvent<Target, Event>) -> Void)? = nil
) -> DefaultDispatchService<Target, Event> {
    DefaultDispatchService(
        state: state,
        notify: notify,
        runtime: runtime,
        activation: activation,
        conditions: conditions,
        executor: executor,
        compiler: compiler,
        catalog: catalog,
        layers: layers,
        initialEventMatchResolvers: initialEventMatchResolvers,
        onDisambiguationPresenceChanged: onDisambiguationPresenceChanged,
        onEmitDispatch: onEmitDispatch
    )
}
