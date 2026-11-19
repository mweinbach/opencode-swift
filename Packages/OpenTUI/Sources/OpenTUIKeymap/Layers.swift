// Pure Swift 6 port of keymap/src/services/layers.ts, layer-diagnostics.ts,
// and services/primitives/active-layers.ts.

// MARK: - Target Mode, Host, Command & Layer Types

public enum TargetMode: String, Equatable, Hashable, Sendable, Codable {
    case focus
    case focusWithin = "focus-within"
}

public enum CommandResolutionStatus: String, Equatable, Hashable, Sendable {
    case resolved
    case unresolved
    case error
}

public protocol KeymapHost<Target, Event>: AnyObject, Sendable {
    associatedtype Target: Hashable & Sendable
    associatedtype Event: KeymapEvent

    var rootTarget: Target { get }
    var isDestroyed: Bool { get }
    func getFocusedTarget() -> Target?
    func getParentTarget(_ target: Target) -> Target?
    func isTargetDestroyed(_ target: Target) -> Bool
    func onTargetDestroy(_ target: Target, _ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void
}

/// Pure-Swift in-memory host suitable for headless execution and unit tests.
public final class InMemoryKeymapHost<Target: Hashable & Sendable, Event: KeymapEvent>: KeymapHost, @unchecked Sendable
{
    public let rootTarget: Target
    public var isDestroyed: Bool = false
    private var focusedTarget: Target?
    private var parents: [Target: Target] = [:]
    private var destroyedTargets: Set<Target> = []
    private var targetDestroyListeners: [Target: [(id: Int, fn: @Sendable () -> Void)]] = [:]
    private var nextListenerID: Int = 0

    public init(rootTarget: Target, focusedTarget: Target? = nil) {
        self.rootTarget = rootTarget
        self.focusedTarget = focusedTarget
    }

    public func setParent(_ parent: Target?, for target: Target) {
        parents[target] = parent
    }

    public func setFocusedTarget(_ target: Target?) {
        focusedTarget = target
    }

    public func destroyTarget(_ target: Target) {
        destroyedTargets.insert(target)
        if focusedTarget == target {
            focusedTarget = nil
        }
        let listeners = targetDestroyListeners.removeValue(forKey: target) ?? []
        for entry in listeners {
            entry.fn()
        }
    }

    public func getFocusedTarget() -> Target? {
        focusedTarget
    }

    public func getParentTarget(_ target: Target) -> Target? {
        parents[target]
    }

    public func isTargetDestroyed(_ target: Target) -> Bool {
        destroyedTargets.contains(target)
    }

    public func onTargetDestroy(_ target: Target, _ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let id = nextListenerID
        nextListenerID += 1
        targetDestroyListeners[target, default: []].append((id: id, fn: listener))
        return { [weak self] in
            self?.targetDestroyListeners[target]?.removeAll { $0.id == id }
        }
    }
}

public struct Command<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public var name: String
    public var run: CommandHandler<Target, Event>
    public var fields: [String: KeymapValue]

    public init(
        name: String,
        fields: [String: KeymapValue] = [:],
        run: @escaping CommandHandler<Target, Event>
    ) {
        self.name = name
        self.fields = fields
        self.run = run
    }
}

public final class CommandState<Target: Hashable & Sendable, Event: KeymapEvent>: RuntimeMatchable, @unchecked Sendable
{
    public let command: Command<Target, Event>
    public let fields: [String: KeymapValue]
    public let attrs: Attributes?
    public let requires: [KeymapRequirement]
    public let matchers: [RuntimeMatcher]

    public init(
        command: Command<Target, Event>,
        fields: [String: KeymapValue] = [:],
        attrs: Attributes? = nil,
        requires: [KeymapRequirement] = [],
        matchers: [RuntimeMatcher] = []
    ) {
        self.command = command
        self.fields = fields
        self.attrs = attrs
        self.requires = requires
        self.matchers = matchers
    }
}

public struct Layer<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public var target: Target?
    public var priority: Int?
    public var bindings: [Binding<Target, Event>]?
    public var commands: [Command<Target, Event>]?
    public var targetMode: TargetMode?
    public var fields: [String: KeymapValue]

    public init(
        target: Target? = nil,
        priority: Int? = nil,
        bindings: [Binding<Target, Event>]? = nil,
        commands: [Command<Target, Event>]? = nil,
        targetMode: TargetMode? = nil,
        fields: [String: KeymapValue] = [:]
    ) {
        self.target = target
        self.priority = priority
        self.bindings = bindings
        self.commands = commands
        self.targetMode = targetMode
        self.fields = fields
    }
}

public final class RegisteredLayer<Target: Hashable & Sendable, Event: KeymapEvent>: RuntimeMatchable,
    @unchecked Sendable
{
    public let order: Int
    public let target: Target?
    public let targetMode: TargetMode?
    public let priority: Int
    public let requires: [KeymapRequirement]
    public let matchers: [RuntimeMatcher]
    public let fields: [String: KeymapValue]?
    public let attrs: Attributes?
    public let commands: [CommandState<Target, Event>]
    public let sourceBindings: [Binding<Target, Event>]
    public var bindings: [BindingState<Target, Event>]
    public var root: SequenceNode<Target, Event>
    public var hasTokenBindings: Bool
    public var activeKeyCacheBlocked: Bool
    public var activeCommandViewCacheBlocked: Bool
    public var offTargetDestroy: (@Sendable () -> Void)?

    public init(
        order: Int,
        target: Target? = nil,
        targetMode: TargetMode? = nil,
        priority: Int = 0,
        requires: [KeymapRequirement] = [],
        matchers: [RuntimeMatcher] = [],
        fields: [String: KeymapValue]? = nil,
        attrs: Attributes? = nil,
        commands: [CommandState<Target, Event>] = [],
        sourceBindings: [Binding<Target, Event>] = [],
        bindings: [BindingState<Target, Event>] = [],
        root: SequenceNode<Target, Event>,
        hasTokenBindings: Bool = false,
        activeKeyCacheBlocked: Bool = false,
        activeCommandViewCacheBlocked: Bool = false,
        offTargetDestroy: (@Sendable () -> Void)? = nil
    ) {
        self.order = order
        self.target = target
        self.targetMode = targetMode
        self.priority = priority
        self.requires = requires
        self.matchers = matchers
        self.fields = fields
        self.attrs = attrs
        self.commands = commands
        self.sourceBindings = sourceBindings
        self.bindings = bindings
        self.root = root
        self.hasTokenBindings = hasTokenBindings
        self.activeKeyCacheBlocked = activeKeyCacheBlocked
        self.activeCommandViewCacheBlocked = activeCommandViewCacheBlocked
        self.offTargetDestroy = offTargetDestroy
    }
}

public enum KeymapLayerError: Error, Equatable, Sendable {
    case targetModeRequiresTarget(TargetMode)
}

// MARK: - Active Layer Resolution Primitives (primitives/active-layers.ts)

// parity: keymap/src/services/primitives/active-layers.ts#getFocusedTargetIfAvailable [status=implemented hash=074955151af8]
public func getFocusedTargetIfAvailable<Host: KeymapHost>(
    _ host: Host
) -> Host.Target? {
    if host.isDestroyed {
        return nil
    }
    return host.getFocusedTarget()
}

// parity: keymap/src/services/primitives/active-layers.ts#forEachActivationTarget [status=implemented hash=dcd09828e244]
public func forEachActivationTarget<Host: KeymapHost>(
    host: Host,
    focused: Host.Target?,
    visit: (Host.Target, Bool) -> Bool
) {
    var current: Host.Target? = focused ?? host.rootTarget
    var isFocusedTarget = focused != nil

    while let target = current {
        let shouldContinue = visit(target, isFocusedTarget)
        if !shouldContinue {
            return
        }
        current = host.getParentTarget(target)
        isFocusedTarget = false
    }
}

// parity: keymap/src/services/primitives/active-layers.ts#getActivationPath [status=implemented hash=21ebf1a4e0fd]
public func getActivationPath<Host: KeymapHost>(
    host: Host,
    focused: Host.Target?
) -> Set<Host.Target> {
    var path: Set<Host.Target> = []
    forEachActivationTarget(host: host, focused: focused) { current, _ in
        path.insert(current)
        return true
    }
    return path
}

// parity: keymap/src/services/primitives/active-layers.ts#getSortedLayers [status=implemented hash=393b1bab11de]
public func getSortedLayers<Target: Hashable & Sendable, Event: KeymapEvent>(
    _ layers: [RegisteredLayer<Target, Event>]
) -> [RegisteredLayer<Target, Event>] {
    layers.sorted(by: layerComesBefore)
}

// parity: keymap/src/services/primitives/active-layers.ts#isLayerActiveForFocused [status=implemented hash=5933359c30cb]
public func isLayerActiveForFocused<Host: KeymapHost>(
    host: Host,
    layer: RegisteredLayer<Host.Target, Host.Event>,
    focused: Host.Target?,
    activationPath: Set<Host.Target>? = nil
) -> Bool {
    guard let target = layer.target else {
        return true
    }
    if host.isTargetDestroyed(target) {
        return false
    }
    if layer.targetMode == .focus {
        return target == focused
    }
    let resolvedPath = activationPath ?? getActivationPath(host: host, focused: focused)
    return resolvedPath.contains(target)
}

// parity: keymap/src/services/primitives/active-layers.ts#getActiveLayersForFocused [status=implemented hash=fa26c53ebf6c]
public func getActiveLayersForFocused<Host: KeymapHost>(
    layers: [RegisteredLayer<Host.Target, Host.Event>],
    host: Host,
    focused: Host.Target?,
    alreadySorted: Bool = true
) -> [RegisteredLayer<Host.Target, Host.Event>] {
    let activationPath = getActivationPath(host: host, focused: focused)
    let sorted = alreadySorted ? layers : getSortedLayers(layers)
    return sorted.filter { layer in
        isLayerActiveForFocused(host: host, layer: layer, focused: focused, activationPath: activationPath)
    }
}

private func layerComesBefore<Target: Hashable & Sendable, Event: KeymapEvent>(
    _ left: RegisteredLayer<Target, Event>,
    _ right: RegisteredLayer<Target, Event>
) -> Bool {
    if left.priority != right.priority {
        return left.priority > right.priority
    }
    return left.order > right.order
}

// MARK: - Layer Diagnostics (layer-diagnostics.ts & layers.ts)

public struct LayerBindingAnalysis<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public let sequence: [KeySequencePart]
    public let command: BindingCommand<Target, Event>?
    public let attrs: Attributes?
    public let event: BindingEvent
    public let preventDefault: Bool
    public let `fallthrough`: Bool
    public let parsedBinding: ParsedBinding<Target, Event>
    public let sourceTarget: Target?
    public let sourceLayerOrder: Int
    public let bindingIndex: Int
    public let hasCommandAtSequence: Bool
    public let hasContinuations: Bool
}

public struct LayerAnalysisContext<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public let target: Target?
    public let order: Int
    public let sourceBindings: [Binding<Target, Event>]
    public let bindings: [LayerBindingAnalysis<Target, Event>]
    public let hasTokenBindings: Bool
    private let checkResolution: @Sendable (String) -> CommandResolutionStatus
    private let warnHandler: @Sendable (String, String?, String) -> Void
    private let warnOnceHandler: @Sendable (String, String, String?, String) -> Void
    private let errorHandler: @Sendable (String, String?, String) -> Void

    internal init(
        target: Target?,
        order: Int,
        sourceBindings: [Binding<Target, Event>],
        bindings: [LayerBindingAnalysis<Target, Event>],
        hasTokenBindings: Bool,
        checkCommandResolution: @escaping @Sendable (String) -> CommandResolutionStatus,
        warn: @escaping @Sendable (String, String?, String) -> Void,
        warnOnce: @escaping @Sendable (String, String, String?, String) -> Void,
        error: @escaping @Sendable (String, String?, String) -> Void
    ) {
        self.target = target
        self.order = order
        self.sourceBindings = sourceBindings
        self.bindings = bindings
        self.hasTokenBindings = hasTokenBindings
        self.checkResolution = checkCommandResolution
        self.warnHandler = warn
        self.warnOnceHandler = warnOnce
        self.errorHandler = error
    }

    public func checkCommandResolution(_ command: String) -> CommandResolutionStatus {
        checkResolution(command)
    }

    public func warn(_ code: String, detail: String? = nil, message: String) {
        warnHandler(code, detail, message)
    }

    public func warnOnce(key: String, code: String, detail: String? = nil, message: String) {
        warnOnceHandler(key, code, detail, message)
    }

    public func error(_ code: String, detail: String? = nil, message: String) {
        errorHandler(code, detail, message)
    }
}

public typealias LayerAnalyzer<Target: Hashable & Sendable, Event: KeymapEvent> =
    @Sendable (LayerAnalysisContext<Target, Event>) throws -> Void

// parity: keymap/src/services/layers.ts#AnalyzeLayerOptions [status=implemented hash=c8bef290669a]
public struct AnalyzeLayerOptions<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public let target: Target?
    public let order: Int
    public let commands: [CommandState<Target, Event>]
    public let sourceBindings: [Binding<Target, Event>]
    public let bindings: [BindingState<Target, Event>]
    public let hasTokenBindings: Bool

    public init(
        target: Target?,
        order: Int,
        commands: [CommandState<Target, Event>],
        sourceBindings: [Binding<Target, Event>],
        bindings: [BindingState<Target, Event>],
        hasTokenBindings: Bool
    ) {
        self.target = target
        self.order = order
        self.commands = commands
        self.sourceBindings = sourceBindings
        self.bindings = bindings
        self.hasTokenBindings = hasTokenBindings
    }
}

// parity: keymap/src/services/layers.ts#LayerDiagnostics [status=implemented hash=c6fc5aa8cbcc]
public protocol LayerDiagnostics<Target, Event>: AnyObject, Sendable {
    associatedtype Target: Hashable & Sendable
    associatedtype Event: KeymapEvent

    func analyzeLayer(_ options: AnalyzeLayerOptions<Target, Event>)
}

// parity: keymap/src/services/layer-diagnostics.ts#LayerDiagnosticsCore [status=implemented hash=9d345375fbb8]
public protocol LayerDiagnosticsCore<Target, Event>: LayerDiagnostics {
    @discardableResult
    func prependLayerAnalyzer(_ analyzer: @escaping LayerAnalyzer<Target, Event>) -> @Sendable () -> Void
    @discardableResult
    func appendLayerAnalyzer(_ analyzer: @escaping LayerAnalyzer<Target, Event>) -> @Sendable () -> Void
    func clearLayerAnalyzers()
}

public final class DefaultLayerDiagnostics<Target: Hashable & Sendable, Event: KeymapEvent>: LayerDiagnosticsCore,
    @unchecked Sendable
{
    private let notify: KeymapNotifier
    private let checkCommand: @Sendable (String, [CommandState<Target, Event>]) -> CommandResolutionStatus
    private var nextID: Int = 0
    private var analyzers: [(id: Int, fn: LayerAnalyzer<Target, Event>)] = []

    public init(
        notify: KeymapNotifier,
        checkCommandResolution: @escaping @Sendable (String, [CommandState<Target, Event>]) -> CommandResolutionStatus =
            { name, localCommands in
                localCommands.contains(where: { $0.command.name == name }) ? .resolved : .unresolved
            }
    ) {
        self.notify = notify
        self.checkCommand = checkCommandResolution
    }

    @discardableResult
    public func prependLayerAnalyzer(_ analyzer: @escaping LayerAnalyzer<Target, Event>) -> @Sendable () -> Void {
        let id = nextID
        nextID += 1
        analyzers.insert((id: id, fn: analyzer), at: 0)
        return { [weak self] in
            self?.analyzers.removeAll { $0.id == id }
        }
    }

    @discardableResult
    public func appendLayerAnalyzer(_ analyzer: @escaping LayerAnalyzer<Target, Event>) -> @Sendable () -> Void {
        let id = nextID
        nextID += 1
        analyzers.append((id: id, fn: analyzer))
        return { [weak self] in
            self?.analyzers.removeAll { $0.id == id }
        }
    }

    public func clearLayerAnalyzers() {
        analyzers.removeAll()
    }

    public func analyzeLayer(_ options: AnalyzeLayerOptions<Target, Event>) {
        if analyzers.isEmpty {
            return
        }

        let analyses = buildLayerBindingAnalyses(options.bindings)
        let localCommands = options.commands
        let ctx = LayerAnalysisContext<Target, Event>(
            target: options.target,
            order: options.order,
            sourceBindings: options.sourceBindings,
            bindings: analyses,
            hasTokenBindings: options.hasTokenBindings,
            checkCommandResolution: { [checkCommand] name in
                checkCommand(name, localCommands)
            },
            warn: { [notify] code, detail, message in
                notify.emitWarning(code, detail: detail, message: message)
            },
            warnOnce: { [notify] key, code, detail, message in
                notify.warnOnce(key: key, code: code, detail: detail, message: message)
            },
            error: { [notify] code, detail, message in
                notify.emitError(code, detail: detail, message: message)
            }
        )

        for entry in analyzers {
            do {
                try entry.fn(ctx)
            } catch {
                notify.emitError("layer-analyzer-error", error: error, message: "[Keymap] Error in layer analyzer:")
            }
        }
    }
}

// parity: keymap/src/services/layer-diagnostics.ts#createLayerDiagnostics [status=implemented hash=351676c8a7d9]
public func createLayerDiagnostics<Target: Hashable & Sendable, Event: KeymapEvent>(
    notify: KeymapNotifier,
    checkCommandResolution: @escaping @Sendable (String, [CommandState<Target, Event>]) -> CommandResolutionStatus =
        { name, localCommands in
            localCommands.contains(where: { $0.command.name == name }) ? .resolved : .unresolved
        }
) -> DefaultLayerDiagnostics<Target, Event> {
    DefaultLayerDiagnostics(notify: notify, checkCommandResolution: checkCommandResolution)
}

private func buildLayerBindingAnalyses<Target: Hashable & Sendable, Event: KeymapEvent>(
    _ bindings: [BindingState<Target, Event>]
) -> [LayerBindingAnalysis<Target, Event>] {
    bindings.map { binding in
        LayerBindingAnalysis(
            sequence: cloneKeySequence(binding.sequence),
            command: binding.command,
            attrs: binding.attrs,
            event: binding.event,
            preventDefault: binding.preventDefault,
            fallthrough: binding.fallthrough,
            parsedBinding: snapshotParsedBinding(binding.parsedBinding),
            sourceTarget: binding.sourceTarget,
            sourceLayerOrder: binding.sourceLayerOrder,
            bindingIndex: binding.bindingIndex,
            hasCommandAtSequence: bindings.contains { candidate in
                candidate.event == .press && candidate.command != nil && sameBindingSequence(candidate, binding)
            },
            hasContinuations: bindings.contains { candidate in
                candidate.event == .press && isBindingSequencePrefix(binding, candidate)
            }
        )
    }
}

private func sameBindingSequence<Target: Hashable & Sendable, Event: KeymapEvent>(
    _ left: BindingState<Target, Event>,
    _ right: BindingState<Target, Event>
) -> Bool {
    guard left.sequence.count == right.sequence.count else { return false }
    for idx in 0..<left.sequence.count {
        if left.sequence[idx].match != right.sequence[idx].match {
            return false
        }
    }
    return true
}

private func isBindingSequencePrefix<Target: Hashable & Sendable, Event: KeymapEvent>(
    _ left: BindingState<Target, Event>,
    _ right: BindingState<Target, Event>
) -> Bool {
    guard left.sequence.count < right.sequence.count else { return false }
    for idx in 0..<left.sequence.count {
        if left.sequence[idx].match != right.sequence[idx].match {
            return false
        }
    }
    return true
}

// MARK: - Layer Service (layers.ts)

public final class LayerBindingsTransformerContext<Target: Hashable & Sendable, Event: KeymapEvent>: @unchecked Sendable
{
    public let layer: Layer<Target, Event>

    public init(layer: Layer<Target, Event>) {
        self.layer = layer
    }

    public func validateBindings(_ bindings: [Binding<Target, Event>]?) -> BindingsValidationResult {
        OpenTUIKeymap.validateBindings(bindings)
    }
}

public typealias LayerBindingsTransformer<Target: Hashable & Sendable, Event: KeymapEvent> =
    @Sendable ([Binding<Target, Event>], LayerBindingsTransformerContext<Target, Event>) throws ->
    [Binding<Target, Event>]?

public final class CommandTransformerContext<Target: Hashable & Sendable, Event: KeymapEvent>: @unchecked Sendable {
    public let layer: Layer<Target, Event>
    private let addHandler: (Command<Target, Event>) -> Void
    private let skipHandler: () -> Void

    internal init(
        layer: Layer<Target, Event>,
        add: @escaping (Command<Target, Event>) -> Void,
        skipOriginal: @escaping () -> Void
    ) {
        self.layer = layer
        self.addHandler = add
        self.skipHandler = skipOriginal
    }

    public func add(_ command: Command<Target, Event>) {
        addHandler(command)
    }

    public func skipOriginal() {
        skipHandler()
    }
}

public typealias CommandTransformer<Target: Hashable & Sendable, Event: KeymapEvent> =
    @Sendable (inout Command<Target, Event>, CommandTransformerContext<Target, Event>) throws -> Void

/// Mutable runtime state owned by the keymap layer stack.
public final class LayerStackState<Target: Hashable & Sendable, Event: KeymapEvent>: @unchecked Sendable {
    public var order: Int = 0
    public var data: EventData = [:]
    public var tokens: [String: ResolvedKeyToken] = [:]
    public var patterns: [String: ResolvedSequencePattern<Event>] = [:]
    public var layerFields: [String: FieldCompiler] = [:]
    public var commandFields: [String: FieldCompiler] = [:]
    public var layerBindingsTransformers: [LayerBindingsTransformer<Target, Event>] = []
    public var commandTransformers: [CommandTransformer<Target, Event>] = []
    public var layers: [RegisteredLayer<Target, Event>] = []
    public var sortedLayers: [RegisteredLayer<Target, Event>] = []
    public var activeKeyCacheBlockers: Int = 0
    public var activeCommandViewCacheBlockers: Int = 0
    public var pending: PendingSequenceState<Target, Event>? = nil

    public init() {}
}

/// Callback hooks connecting `LayerService` to pending-sequence validation and clearing.
public struct LayerActivationHooks<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public let hasPendingSequenceState: @Sendable () -> Bool
    public let setPendingSequence: @Sendable (PendingSequenceState<Target, Event>?) -> Void
    public let ensureValidPendingSequence: @Sendable () -> Void
    public let revalidatePendingSequenceIfNeeded: @Sendable () -> Void

    public init(
        hasPendingSequenceState: @escaping @Sendable () -> Bool = { false },
        setPendingSequence: @escaping @Sendable (PendingSequenceState<Target, Event>?) -> Void = { _ in },
        ensureValidPendingSequence: @escaping @Sendable () -> Void = {},
        revalidatePendingSequenceIfNeeded: @escaping @Sendable () -> Void = {}
    ) {
        self.hasPendingSequenceState = hasPendingSequenceState
        self.setPendingSequence = setPendingSequence
        self.ensureValidPendingSequence = ensureValidPendingSequence
        self.revalidatePendingSequenceIfNeeded = revalidatePendingSequenceIfNeeded
    }
}

// parity: keymap/src/services/layers.ts#LayerSlot [status=implemented hash=4936522806dc]
public final class LayerSlot<Target: Hashable & Sendable, Event: KeymapEvent>: @unchecked Sendable {
    public let order: Int
    public var layer: RegisteredLayer<Target, Event>?

    public init(order: Int, layer: RegisteredLayer<Target, Event>? = nil) {
        self.order = order
        self.layer = layer
    }
}

/// Resolved binding entry paired with its owning layer, returned by active binding resolution.
public struct ResolvedActiveBinding<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public let layer: RegisteredLayer<Target, Event>
    public let binding: BindingState<Target, Event>

    public init(layer: RegisteredLayer<Target, Event>, binding: BindingState<Target, Event>) {
        self.layer = layer
        self.binding = binding
    }
}

/// Cross-layer conflict diagnostic entry describing shadowed or duplicate active bindings.
public struct BindingConflictDiagnostic<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public let sequenceKey: String
    public let winningLayer: RegisteredLayer<Target, Event>
    public let winningBinding: BindingState<Target, Event>
    public let shadowedLayer: RegisteredLayer<Target, Event>
    public let shadowedBinding: BindingState<Target, Event>
}

// parity: keymap/src/services/layers.ts#LayerService [status=implemented hash=61c232f6d30d]
public protocol LayerService<Target, Event>: AnyObject, Sendable {
    associatedtype Target: Hashable & Sendable
    associatedtype Event: KeymapEvent

    @discardableResult
    func registerLayer(_ layer: Layer<Target, Event>) -> @Sendable () -> Void
    func createSlot() -> LayerSlot<Target, Event>
    @discardableResult
    func replaceLayer(
        slot: LayerSlot<Target, Event>,
        layer: Layer<Target, Event>?
    ) -> RegisteredLayer<Target, Event>?
    func applyTokenState(_ nextTokens: [String: ResolvedKeyToken])
    func recompileBindings()
    func cleanup()
}

public final class DefaultLayerService<Host: KeymapHost, Compiler: CompilerService>: LayerService, @unchecked Sendable
where Compiler.Target == Host.Target, Compiler.Event == Host.Event {
    public typealias Target = Host.Target
    public typealias Event = Host.Event

    private let state: LayerStackState<Target, Event>
    private let notify: KeymapNotifier
    private let conditions: any ConditionService
    private let activation: LayerActivationHooks<Target, Event>
    private let compiler: Compiler
    private let host: Host
    private let diagnostics: (any LayerDiagnostics<Target, Event>)?
    private let warnUnknownField: @Sendable (FieldKind, String) -> Void

    public init(
        state: LayerStackState<Target, Event>,
        notify: KeymapNotifier,
        conditions: any ConditionService,
        activation: LayerActivationHooks<Target, Event> = LayerActivationHooks(),
        compiler: Compiler,
        host: Host,
        diagnostics: (any LayerDiagnostics<Target, Event>)? = nil,
        warnUnknownField: @escaping @Sendable (FieldKind, String) -> Void = { _, _ in }
    ) {
        self.state = state
        self.notify = notify
        self.conditions = conditions
        self.activation = activation
        self.compiler = compiler
        self.host = host
        self.diagnostics = diagnostics
        self.warnUnknownField = warnUnknownField
    }

    @discardableResult
    public func registerLayer(_ layer: Layer<Target, Event>) -> @Sendable () -> Void {
        notify.runWithStateChangeBatch {
            guard let registeredLayer = compileLayer(layer, slotOrder: nil) else {
                return {}
            }
            addLayer(registeredLayer)
            return { [weak self] in
                self?.unregisterLayer(registeredLayer)
            }
        }
    }

    public func createSlot() -> LayerSlot<Target, Event> {
        let order = state.order
        state.order += 1
        return LayerSlot(order: order)
    }

    @discardableResult
    public func replaceLayer(
        slot: LayerSlot<Target, Event>,
        layer: Layer<Target, Event>?
    ) -> RegisteredLayer<Target, Event>? {
        notify.runWithStateChangeBatch {
            let next = layer.flatMap { compileLayer($0, slotOrder: slot.order) }
            if let existing = slot.layer {
                unregisterLayer(existing)
            }
            slot.layer = next
            guard let next else {
                return nil
            }
            addLayer(next)
            return next
        }
    }

    public func applyTokenState(_ nextTokens: [String: ResolvedKeyToken]) {
        notify.runWithStateChangeBatch {
            var nextCompilations: [(RegisteredLayer<Target, Event>, BindingCompilationResult<Target, Event>)] = []
            for layer in state.layers where layer.hasTokenBindings {
                let compilation = compiler.compileBindings(
                    layer.sourceBindings,
                    tokens: nextTokens,
                    sourceTarget: layer.target,
                    sourceLayerOrder: layer.order,
                    fields: layer.fields
                )
                nextCompilations.append((layer, compilation))
            }

            state.tokens = nextTokens

            var shouldClearPending = false
            for (layer, compilation) in nextCompilations {
                if applyBindingStates(layer: layer, compilation: compilation) {
                    shouldClearPending = true
                }
            }

            if shouldClearPending {
                activation.setPendingSequence(nil)
            }

            if !nextCompilations.isEmpty {
                notify.queueStateChange()
            }
        }
    }

    public func recompileBindings() {
        notify.runWithStateChangeBatch {
            var recompiledLayers = 0
            var shouldClearPending = false

            for layer in state.layers where !layer.sourceBindings.isEmpty {
                let compilation = compiler.compileBindings(
                    layer.sourceBindings,
                    tokens: state.tokens,
                    sourceTarget: layer.target,
                    sourceLayerOrder: layer.order,
                    fields: layer.fields
                )
                if applyBindingStates(layer: layer, compilation: compilation) {
                    shouldClearPending = true
                }
                recompiledLayers += 1
            }

            if shouldClearPending {
                activation.setPendingSequence(nil)
            }

            if recompiledLayers > 0 {
                notify.queueStateChange()
            }
        }
    }

    public func cleanup() {
        for layer in state.layers {
            detachReactiveMatchers(layer)
            for command in layer.commands {
                detachReactiveMatchers(command)
            }
            for binding in layer.bindings {
                detachReactiveMatchers(binding)
            }
            layer.offTargetDestroy?()
            layer.offTargetDestroy = nil
        }
    }

    /// Resolves currently active layers in precedence order (priority desc, order desc),
    /// filtered by target focus semantics and runtime conditions.
    public func activeLayers(focused: Target? = nil) -> [RegisteredLayer<Target, Event>] {
        let effectiveFocus = focused ?? getFocusedTargetIfAvailable(host)
        return getActiveLayersForFocused(
            layers: state.sortedLayers,
            host: host,
            focused: effectiveFocus,
            alreadySorted: true
        ).filter { conditions.matchesConditions($0) }
    }

    /// Resolves active bindings across active layers in precedence order, applying layer & binding conditions.
    public func resolveActiveBindings(
        focused: Target? = nil,
        event: BindingEvent? = nil
    ) -> [ResolvedActiveBinding<Target, Event>] {
        var resolved: [ResolvedActiveBinding<Target, Event>] = []
        for layer in activeLayers(focused: focused) {
            for binding in layer.bindings {
                if let event, binding.event != event {
                    continue
                }
                if conditions.matchesConditions(binding) {
                    resolved.append(ResolvedActiveBinding(layer: layer, binding: binding))
                }
            }
        }
        return resolved
    }

    /// Detects sequence shadowing/conflicts among active bindings across layers.
    public func detectActiveConflicts(
        focused: Target? = nil,
        event: BindingEvent = .press
    ) -> [BindingConflictDiagnostic<Target, Event>] {
        var winners: [String: ResolvedActiveBinding<Target, Event>] = [:]
        var conflicts: [BindingConflictDiagnostic<Target, Event>] = []

        for entry in resolveActiveBindings(focused: focused, event: event) {
            let key = entry.binding.sequence.map(\.match).joined(separator: " ")
            if let existing = winners[key] {
                if !existing.binding.fallthrough {
                    conflicts.append(
                        BindingConflictDiagnostic(
                            sequenceKey: key,
                            winningLayer: existing.layer,
                            winningBinding: existing.binding,
                            shadowedLayer: entry.layer,
                            shadowedBinding: entry.binding
                        )
                    )
                }
            } else {
                winners[key] = entry
            }
        }

        return conflicts
    }

    // MARK: - Internal Layer Compilation & Lifecycle

    private func compileLayer(
        _ layer: Layer<Target, Event>,
        slotOrder: Int?
    ) -> RegisteredLayer<Target, Event>? {
        if let target = layer.target, host.isTargetDestroyed(target) {
            notify.emitError(
                "destroyed-layer-target",
                detail: String(describing: target),
                message: "Cannot register a keymap layer for a destroyed keymap target"
            )
            return nil
        }

        let targetMode: TargetMode?
        let sourceBindings: [Binding<Target, Event>]
        let commands: [CommandState<Target, Event>]
        let runtimeState: CompiledLayerRuntimeState

        do {
            targetMode = try normalizeTargetMode(layer)
            let snapshotted = try snapshotBindings(layer.bindings ?? [])
            sourceBindings = try applyLayerBindingsTransformers(snapshotted, layer: layer)
            let sourceCommands = applyCommandTransformers(layer.commands ?? [], layer: layer)
            commands = try normalizeCommands(sourceCommands)
            runtimeState = try compileLayerRuntimeState(layer)
        } catch {
            notify.emitError(
                "register-layer-failed",
                error: error,
                message: "Failed to register keymap layer"
            )
            return nil
        }

        let order: Int
        if let slotOrder {
            order = slotOrder
        } else {
            order = state.order
            state.order += 1
        }

        let compiledBindings = compiler.compileBindings(
            sourceBindings,
            tokens: state.tokens,
            sourceTarget: layer.target,
            sourceLayerOrder: order,
            fields: runtimeState.fields
        )

        if compiledBindings.bindings.isEmpty && !compiledBindings.hasTokenBindings && commands.isEmpty {
            return nil
        }

        return RegisteredLayer(
            order: order,
            target: layer.target,
            targetMode: targetMode,
            priority: layer.priority ?? 0,
            requires: runtimeState.requires,
            matchers: runtimeState.matchers,
            fields: runtimeState.fields,
            attrs: runtimeState.attrs,
            commands: commands,
            sourceBindings: sourceBindings,
            bindings: compiledBindings.bindings,
            root: buildSequenceTree(compiledBindings.bindings, patterns: state.patterns),
            hasTokenBindings: compiledBindings.hasTokenBindings
        )
    }

    private func addLayer(_ registeredLayer: RegisteredLayer<Target, Event>) {
        diagnostics?.analyzeLayer(
            AnalyzeLayerOptions(
                target: registeredLayer.target,
                order: registeredLayer.order,
                commands: registeredLayer.commands,
                sourceBindings: registeredLayer.sourceBindings,
                bindings: registeredLayer.bindings,
                hasTokenBindings: registeredLayer.hasTokenBindings
            )
        )
        updateCacheBlockers(registeredLayer)

        state.layers.append(registeredLayer)
        if registeredLayer.order < state.order - 1 {
            state.layers.sort { $0.order < $1.order }
        }
        state.sortedLayers.append(registeredLayer)
        state.sortedLayers.sort(by: layerComesBefore)

        attachReactiveMatchers(registeredLayer)
        for command in registeredLayer.commands {
            attachReactiveMatchers(command)
        }
        for binding in registeredLayer.bindings {
            attachReactiveMatchers(binding)
        }

        if let target = registeredLayer.target {
            registeredLayer.offTargetDestroy = host.onTargetDestroy(target) { [weak self, weak registeredLayer] in
                guard let self, let registeredLayer else { return }
                self.unregisterLayer(registeredLayer)
            }
        }

        if !registeredLayer.commands.isEmpty {
            activation.ensureValidPendingSequence()
        }

        notify.queueStateChange()
    }

    private func unregisterLayer(_ layer: RegisteredLayer<Target, Event>) {
        notify.runWithStateChangeBatch {
            guard let idx = state.layers.firstIndex(where: { $0 === layer }) else {
                return
            }
            state.layers.remove(at: idx)
            state.sortedLayers.removeAll { $0 === layer }
            untrackCacheBlockers(layer)

            detachReactiveMatchers(layer)
            for command in layer.commands {
                detachReactiveMatchers(command)
            }
            for binding in layer.bindings {
                detachReactiveMatchers(binding)
            }

            layer.offTargetDestroy?()
            layer.offTargetDestroy = nil

            if state.pending?.captures.contains(where: { $0.layer === layer }) == true {
                activation.setPendingSequence(nil)
            } else if !layer.commands.isEmpty && !host.isDestroyed {
                activation.ensureValidPendingSequence()
            }

            notify.queueStateChange()
        }
    }

    private func applyBindingStates(
        layer: RegisteredLayer<Target, Event>,
        compilation: BindingCompilationResult<Target, Event>
    ) -> Bool {
        diagnostics?.analyzeLayer(
            AnalyzeLayerOptions(
                target: layer.target,
                order: layer.order,
                commands: layer.commands,
                sourceBindings: layer.sourceBindings,
                bindings: compilation.bindings,
                hasTokenBindings: compilation.hasTokenBindings
            )
        )

        untrackCacheBlockers(layer)
        for binding in layer.bindings {
            detachReactiveMatchers(binding)
        }

        layer.bindings = compilation.bindings
        layer.root = buildSequenceTree(compilation.bindings, patterns: state.patterns)
        layer.hasTokenBindings = compilation.hasTokenBindings
        updateCacheBlockers(layer)

        for binding in layer.bindings {
            attachReactiveMatchers(binding)
        }

        return state.pending?.captures.contains(where: { $0.layer === layer }) ?? false
    }

    private func normalizeTargetMode(_ layer: Layer<Target, Event>) throws(KeymapLayerError) -> TargetMode? {
        if let targetMode = layer.targetMode {
            guard layer.target != nil else {
                throw .targetModeRequiresTarget(targetMode)
            }
            return targetMode
        }
        return layer.target != nil ? .focusWithin : nil
    }

    private func applyLayerBindingsTransformers(
        _ bindings: [Binding<Target, Event>],
        layer: Layer<Target, Event>
    ) throws -> [Binding<Target, Event>] {
        let transformers = state.layerBindingsTransformers
        if transformers.isEmpty {
            return bindings
        }
        var current = bindings
        let ctx = LayerBindingsTransformerContext(layer: layer)
        for transformer in transformers {
            if let next = try transformer(current, ctx) {
                current = try snapshotBindings(next)
            }
        }
        return current
    }

    private func applyCommandTransformers(
        _ commands: [Command<Target, Event>],
        layer: Layer<Target, Event>
    ) -> [Command<Target, Event>] {
        let transformers = state.commandTransformers
        if commands.isEmpty || transformers.isEmpty {
            return commands
        }
        var transformedCommands: [Command<Target, Event>] = []
        for command in commands {
            var current = command
            var extras: [Command<Target, Event>] = []
            var keepOriginal = true
            let ctx = CommandTransformerContext<Target, Event>(
                layer: layer,
                add: { nextCommand in extras.append(nextCommand) },
                skipOriginal: { keepOriginal = false }
            )
            for transformer in transformers {
                do {
                    try transformer(&current, ctx)
                } catch {
                    notify.emitError(
                        "command-transformer-error",
                        error: error,
                        message: "[Keymap] Error in command transformer:"
                    )
                }
            }
            if keepOriginal {
                transformedCommands.append(current)
            }
            transformedCommands.append(contentsOf: extras)
        }
        return transformedCommands
    }

    private func normalizeCommands(_ commands: [Command<Target, Event>]) throws -> [CommandState<Target, Event>] {
        var result: [CommandState<Target, Event>] = []
        for command in commands {
            let normalizedName = try normalizeCommandName(command.name)
            var normalizedCommand = command
            normalizedCommand.name = normalizedName
            let accumulator = FieldAccumulator(allowsAttributes: true)
            for fieldName in command.fields.keys.sorted() {
                if RESERVED_COMMAND_FIELDS.contains(fieldName) {
                    continue
                }
                guard let value = command.fields[fieldName], value != .undefined else {
                    continue
                }
                if let fieldCompiler = state.commandFields[fieldName] {
                    let ctx = createFieldCompilerContext(
                        fieldName: fieldName,
                        conditions: conditions,
                        accumulator: accumulator
                    )
                    try fieldCompiler(value, ctx)
                }
            }
            result.append(
                CommandState(
                    command: normalizedCommand,
                    fields: command.fields,
                    attrs: accumulator.attrs.isEmpty ? nil : accumulator.attrs,
                    requires: accumulator.orderedRequirements,
                    matchers: accumulator.matchers
                )
            )
        }
        return result
    }

    private struct CompiledLayerRuntimeState {
        let requires: [KeymapRequirement]
        let matchers: [RuntimeMatcher]
        let fields: [String: KeymapValue]?
        let attrs: Attributes?
    }

    private func compileLayerRuntimeState(_ layer: Layer<Target, Event>) throws -> CompiledLayerRuntimeState {
        let accumulator = FieldAccumulator(allowsAttributes: true)
        var fields: [String: KeymapValue] = [:]

        for fieldName in layer.fields.keys.sorted() {
            if RESERVED_LAYER_FIELDS.contains(fieldName) {
                continue
            }
            guard let value = layer.fields[fieldName], value != .undefined else {
                continue
            }
            fields[fieldName] = value

            guard let fieldCompiler = state.layerFields[fieldName] else {
                warnUnknownField(.layer, fieldName)
                continue
            }
            let ctx = createFieldCompilerContext(
                fieldName: fieldName,
                conditions: conditions,
                accumulator: accumulator
            )
            try fieldCompiler(value, ctx)
        }

        return CompiledLayerRuntimeState(
            requires: accumulator.orderedRequirements,
            matchers: accumulator.matchers,
            fields: fields.isEmpty ? nil : fields,
            attrs: accumulator.attrs.isEmpty ? nil : accumulator.attrs
        )
    }

    private func updateCacheBlockers(_ layer: RegisteredLayer<Target, Event>) {
        let activeKeyBlocked = layerBlocksActiveKeyCache(layer)
        let activeCommandViewBlocked = layerBlocksActiveCommandViewCache(layer)
        layer.activeKeyCacheBlocked = activeKeyBlocked
        layer.activeCommandViewCacheBlocked = activeCommandViewBlocked
        if activeKeyBlocked { state.activeKeyCacheBlockers += 1 }
        if activeCommandViewBlocked { state.activeCommandViewCacheBlockers += 1 }
    }

    private func untrackCacheBlockers(_ layer: RegisteredLayer<Target, Event>) {
        if layer.activeKeyCacheBlocked {
            state.activeKeyCacheBlockers -= 1
            layer.activeKeyCacheBlocked = false
        }
        if layer.activeCommandViewCacheBlocked {
            state.activeCommandViewCacheBlockers -= 1
            layer.activeCommandViewCacheBlocked = false
        }
    }

    private func attachReactiveMatchers(_ target: any RuntimeMatchable) {
        for matcher in target.matchers {
            guard let subscribe = matcher.subscribe else {
                continue
            }
            do {
                matcher.dispose = try subscribe { [weak self] in
                    guard let self else { return }
                    if !self.activation.hasPendingSequenceState() {
                        self.notify.queueStateChange()
                        return
                    }
                    self.notify.runWithStateChangeBatch {
                        self.activation.revalidatePendingSequenceIfNeeded()
                        self.notify.queueStateChange()
                    }
                }
            } catch {
                notify.emitError(
                    "reactive-matcher-subscribe-error",
                    error: error,
                    message: "Failed to subscribe to reactive matcher from \(matcher.source)"
                )
            }
        }
    }

    private func detachReactiveMatchers(_ target: any RuntimeMatchable) {
        for matcher in target.matchers {
            guard let dispose = matcher.dispose else {
                continue
            }
            do {
                try dispose()
            } catch {
                notify.emitError(
                    "reactive-matcher-dispose-error",
                    error: error,
                    message: "Failed to dispose reactive matcher from \(matcher.source)"
                )
            }
            matcher.dispose = nil
        }
    }
}

private func layerBlocksActiveKeyCache<Target: Hashable & Sendable, Event: KeymapEvent>(
    _ layer: RegisteredLayer<Target, Event>
) -> Bool {
    if !layer.matchers.isEmpty { return true }
    if layer.commands.contains(where: { !$0.matchers.isEmpty }) { return true }
    if layer.bindings.contains(where: { !$0.matchers.isEmpty }) { return true }
    return false
}

private func layerBlocksActiveCommandViewCache<Target: Hashable & Sendable, Event: KeymapEvent>(
    _ layer: RegisteredLayer<Target, Event>
) -> Bool {
    if layer.commands.isEmpty { return false }
    if !layer.matchers.isEmpty { return true }
    if layer.commands.contains(where: { !$0.matchers.isEmpty }) { return true }
    return false
}

// parity: keymap/src/services/layers.ts#createLayerService [status=implemented hash=ea5f1cade54c]
public func createLayerService<Host: KeymapHost, Compiler: CompilerService>(
    state: LayerStackState<Host.Target, Host.Event>,
    notify: KeymapNotifier,
    conditions: any ConditionService,
    activation: LayerActivationHooks<Host.Target, Host.Event> = LayerActivationHooks(),
    compiler: Compiler,
    host: Host,
    diagnostics: (any LayerDiagnostics<Host.Target, Host.Event>)? = nil,
    warnUnknownField: @escaping @Sendable (FieldKind, String) -> Void = { _, _ in }
) -> DefaultLayerService<Host, Compiler> where Compiler.Target == Host.Target, Compiler.Event == Host.Event {
    DefaultLayerService(
        state: state,
        notify: notify,
        conditions: conditions,
        activation: activation,
        compiler: compiler,
        host: host,
        diagnostics: diagnostics,
        warnUnknownField: warnUnknownField
    )
}
