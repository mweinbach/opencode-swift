// Pure Swift 6 port of keymap/src/services/runtime.ts, keymap/src/services/environment.ts,
// and keymap/src/keymap.ts.

// MARK: - Host Metadata & Interactive Host Protocol

public enum HostPlatform: String, Equatable, Hashable, Sendable, Codable {
    case macos
    case windows
    case linux
    case unknown
}

public enum HostModifier: String, Equatable, Hashable, Sendable, Codable {
    case ctrl
    case shift
    case meta
    case `super`
    case hyper
}

public enum HostCapability: String, Equatable, Hashable, Sendable, Codable {
    case supported
    case unsupported
    case unknown
}

public enum HostPrimaryModifier: String, Equatable, Hashable, Sendable, Codable {
    case ctrl
    case `super`
    case unknown
}

public struct HostMetadata: Equatable, Hashable, Sendable, Codable {
    public let platform: HostPlatform
    public let primaryModifier: HostPrimaryModifier
    public let modifiers: [HostModifier: HostCapability]

    public init(
        platform: HostPlatform = .unknown,
        primaryModifier: HostPrimaryModifier = .unknown,
        modifiers: [HostModifier: HostCapability] = [
            .ctrl: .unknown,
            .shift: .unknown,
            .meta: .unknown,
            .super: .unknown,
            .hyper: .unknown,
        ]
    ) {
        self.platform = platform
        self.primaryModifier = primaryModifier
        self.modifiers = modifiers
    }

    public static let `default` = HostMetadata()
}

/// Optional extended host protocol for hosts that push live key/raw/focus/destroy events.
public protocol InteractiveKeymapHost: KeymapHost {
    var metadata: HostMetadata { get }
    func onKeyPress(_ listener: @escaping @Sendable (Event) -> Void) -> @Sendable () -> Void
    func onKeyRelease(_ listener: @escaping @Sendable (Event) -> Void) -> @Sendable () -> Void
    func onFocusChange(_ listener: @escaping @Sendable (Target?) -> Void) -> @Sendable () -> Void
    func onDestroy(_ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void
    func onRawInput(_ listener: @escaping @Sendable (String) -> Bool) -> @Sendable () -> Void
    func createCommandEvent() -> Event
}

public extension InteractiveKeymapHost {
    var metadata: HostMetadata { .default }
    func onDestroy(_ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void { {} }
    func onRawInput(_ listener: @escaping @Sendable (String) -> Bool) -> @Sendable () -> Void { {} }
}

// MARK: - Token & Sequence Pattern Registration Types (environment.ts)

public struct KeyToken: Equatable, Hashable, Sendable {
    public let name: String
    public let key: KeyLike

    public init(name: String, key: KeyLike) {
        self.name = name
        self.key = key
    }
}

public struct SequencePattern<Event: KeymapEvent>: Sendable {
    public let name: String
    public let display: String?
    public let payloadKey: String?
    public let min: Int?
    public let max: Int?
    public let match: @Sendable (Event) throws -> SequencePatternMatch?
    public let finalize: (@Sendable ([KeymapValue]) throws -> KeymapValue)?

    public init(
        name: String,
        display: String? = nil,
        payloadKey: String? = nil,
        min: Int? = nil,
        max: Int? = nil,
        match: @escaping @Sendable (Event) throws -> SequencePatternMatch?,
        finalize: (@Sendable ([KeymapValue]) throws -> KeymapValue)? = nil
    ) {
        self.name = name
        self.display = display
        self.payloadKey = payloadKey
        self.min = min
        self.max = max
        self.match = match
        self.finalize = finalize
    }
}

public enum EnvironmentFieldKind: String, Equatable, Hashable, Sendable {
    case layer
    case binding
    case command
}

public enum KeymapEnvironmentError: Error, Equatable, Sendable, KeymapDescribedError {
    case invalidPatternLimit(name: String, field: String)
    case patternMaxLessThanMin(name: String)
    case tokenExpectedConcreteStroke(key: String)

    public var errorMessage: String {
        switch self {
        case .invalidPatternLimit(let name, let field):
            return "Keymap sequence pattern \"\(name)\" \(field) must be a non-negative integer"
        case .patternMaxLessThanMin(let name):
            return "Keymap sequence pattern \"\(name)\" max must be greater than or equal to min"
        case .tokenExpectedConcreteStroke(let key):
            return "Invalid key \"\(key)\": expected a concrete key stroke"
        }
    }
}

// MARK: - Runtime Data Service (runtime.ts)

// parity: keymap/src/services/runtime.ts#RuntimeService [status=implemented hash=6aed2c9fdcf8]
public protocol RuntimeService: AnyObject, Sendable {
    func getData(_ name: String) -> KeymapValue
    func setData(_ name: String, _ value: KeymapValue)
    func getReadonlyData() -> EventData
}

public final class DefaultRuntimeService<Target: Hashable & Sendable, Event: KeymapEvent>: RuntimeService,
    @unchecked Sendable
{
    private let state: LayerStackState<Target, Event>
    private let notify: KeymapNotifier
    private let ensureValidPendingSequence: @Sendable () -> Void
    private var dataVersion: Int = 0
    private var readonlyDataVersion: Int = -1
    private var readonlyData: EventData = [:]

    public init(
        state: LayerStackState<Target, Event>,
        notify: KeymapNotifier,
        ensureValidPendingSequence: @escaping @Sendable () -> Void
    ) {
        self.state = state
        self.notify = notify
        self.ensureValidPendingSequence = ensureValidPendingSequence
    }

    public func getData(_ name: String) -> KeymapValue {
        state.data[name] ?? .undefined
    }

    public func setData(_ name: String, _ value: KeymapValue) {
        notify.runWithStateChangeBatch {
            if value == .undefined {
                if state.data[name] == nil {
                    return
                }
                state.data.removeValue(forKey: name)
                dataVersion += 1
                ensureValidPendingSequence()
                notify.queueStateChange()
                return
            }

            if let existing = state.data[name], objectIs(existing, value) {
                return
            }

            state.data[name] = value
            dataVersion += 1
            ensureValidPendingSequence()
            notify.queueStateChange()
        }
    }

    public func getReadonlyData() -> EventData {
        if readonlyDataVersion == dataVersion {
            return readonlyData
        }
        readonlyData = state.data
        readonlyDataVersion = dataVersion
        return readonlyData
    }
}

// parity: keymap/src/services/runtime.ts#createRuntimeService [status=implemented hash=14349efc54db]
public func createRuntimeService<Target: Hashable & Sendable, Event: KeymapEvent>(
    state: LayerStackState<Target, Event>,
    notify: KeymapNotifier,
    activation: any ActivationService<Target, Event>
) -> DefaultRuntimeService<Target, Event> {
    DefaultRuntimeService(
        state: state,
        notify: notify,
        ensureValidPendingSequence: { _ = activation.ensureValidPendingSequence() }
    )
}

// MARK: - Environment Registration Helpers (environment.ts)

// parity: keymap/src/services/environment.ts#registerToken [status=implemented hash=80b5f3c97b82]
@discardableResult
public func registerToken<Target: Hashable & Sendable, Event: KeymapEvent>(
    state: LayerStackState<Target, Event>,
    compilerEnvironment: CompilerEnvironment<Target, Event>,
    notify: KeymapNotifier,
    compiler: any CompilerService<Target, Event>,
    layers: any LayerService<Target, Event>,
    token: KeyToken
) -> @Sendable () -> Void {
    let normalizedToken: String
    do {
        normalizedToken = try normalizeBindingTokenName(token.name)
    } catch {
        notify.emitError(
            "token-name-normalize-error",
            error: error,
            message: getErrorMessage(error, fallback: "Failed to register keymap token")
        )
        return {}
    }

    if state.tokens[normalizedToken] != nil || state.patterns[normalizedToken] != nil {
        notify.emitError(
            "duplicate-token",
            detail: normalizedToken,
            message: "Keymap token \"\(normalizedToken)\" is already registered"
        )
        return {}
    }

    let parsedToken: KeySequencePart
    do {
        parsedToken = try compiler.parseTokenKey(token.key)
        if parsedToken.patternName != nil {
            throw KeymapEnvironmentError.tokenExpectedConcreteStroke(key: token.key.descriptionForDiagnostics)
        }
    } catch {
        notify.emitError(
            "token-parse-error",
            error: error,
            message: getErrorMessage(error, fallback: "Failed to register keymap token \"\(normalizedToken)\"")
        )
        return {}
    }

    let registeredToken = ResolvedKeyToken(stroke: parsedToken.stroke, match: parsedToken.match)
    var nextTokens = state.tokens
    nextTokens[normalizedToken] = registeredToken
    compilerEnvironment.tokens = nextTokens
    layers.applyTokenState(nextTokens)

    return { [state, compilerEnvironment, layers] in
        guard state.tokens[normalizedToken] == registeredToken else {
            return
        }
        var updated = state.tokens
        updated.removeValue(forKey: normalizedToken)
        compilerEnvironment.tokens = updated
        layers.applyTokenState(updated)
    }
}

// parity: keymap/src/services/environment.ts#registerSequencePattern [status=implemented hash=b83b032ac300]
@discardableResult
public func registerSequencePattern<Target: Hashable & Sendable, Event: KeymapEvent>(
    state: LayerStackState<Target, Event>,
    compilerEnvironment: CompilerEnvironment<Target, Event>,
    notify: KeymapNotifier,
    layers: any LayerService<Target, Event>,
    pattern: SequencePattern<Event>
) -> @Sendable () -> Void {
    let normalizedName: String
    let resolvedPattern: ResolvedSequencePattern<Event>

    do {
        normalizedName = try normalizeBindingTokenName(pattern.name)
        let minCount = pattern.min ?? 1
        let maxCount = pattern.max ?? Int.max
        if minCount < 0 {
            throw KeymapEnvironmentError.invalidPatternLimit(name: normalizedName, field: "min")
        }
        if maxCount < 0 {
            throw KeymapEnvironmentError.invalidPatternLimit(name: normalizedName, field: "max")
        }
        if maxCount < minCount {
            throw KeymapEnvironmentError.patternMaxLessThanMin(name: normalizedName)
        }
        let matchID = try createTextKeyMatch("pattern:\(normalizedName)")
        resolvedPattern = ResolvedSequencePattern<Event>(
            name: normalizedName,
            display: pattern.display,
            payloadKey: pattern.payloadKey ?? normalizedName,
            match: matchID,
            min: minCount,
            max: maxCount,
            matcher: pattern.match,
            finalize: pattern.finalize
        )
    } catch {
        notify.emitError(
            "sequence-pattern-register-error",
            error: error,
            message: getErrorMessage(error, fallback: "Failed to register keymap sequence pattern")
        )
        return {}
    }

    if state.tokens[normalizedName] != nil || state.patterns[normalizedName] != nil {
        notify.emitError(
            "duplicate-sequence-pattern",
            detail: normalizedName,
            message: "Keymap sequence pattern \"\(normalizedName)\" is already registered"
        )
        return {}
    }

    state.patterns[normalizedName] = resolvedPattern
    compilerEnvironment.patterns[normalizedName] = resolvedPattern
    layers.recompileBindings()

    return { [state, compilerEnvironment, layers] in
        guard state.patterns[normalizedName]?.match == resolvedPattern.match else {
            return
        }
        state.patterns.removeValue(forKey: normalizedName)
        compilerEnvironment.patterns.removeValue(forKey: normalizedName)
        layers.recompileBindings()
    }
}

// parity: keymap/src/services/environment.ts#registerFields [status=implemented hash=243fe43de7db]
@discardableResult
public func registerFields<Target: Hashable & Sendable, Event: KeymapEvent>(
    state: LayerStackState<Target, Event>,
    compilerEnvironment: CompilerEnvironment<Target, Event>,
    notify: KeymapNotifier,
    kind: EnvironmentFieldKind,
    fields: [String: FieldCompiler]
) -> @Sendable () -> Void {
    let reserved: Set<String>
    switch kind {
    case .layer:
        reserved = RESERVED_LAYER_FIELDS
    case .binding:
        reserved = RESERVED_BINDING_FIELDS
    case .command:
        reserved = RESERVED_COMMAND_FIELDS
    }

    var registeredNames: [String] = []
    for name in fields.keys.sorted() {
        guard let compiler = fields[name] else { continue }
        if reserved.contains(name) {
            notify.emitError(
                "reserved-\(kind.rawValue)-field",
                detail: name,
                message: "Keymap \(kind.rawValue) field \"\(name)\" is reserved"
            )
            continue
        }

        let alreadyExists: Bool
        switch kind {
        case .layer:
            alreadyExists = state.layerFields[name] != nil
        case .binding:
            alreadyExists = compilerEnvironment.bindingFields[name] != nil
        case .command:
            alreadyExists = state.commandFields[name] != nil
        }

        if alreadyExists {
            notify.emitError(
                "duplicate-\(kind.rawValue)-field",
                detail: name,
                message: "Keymap \(kind.rawValue) field \"\(name)\" is already registered"
            )
            continue
        }

        switch kind {
        case .layer:
            state.layerFields[name] = compiler
        case .binding:
            compilerEnvironment.bindingFields[name] = compiler
        case .command:
            state.commandFields[name] = compiler
        }
        registeredNames.append(name)
    }

    let namesToUnregister = registeredNames
    return { [state, compilerEnvironment] in
        for name in namesToUnregister {
            switch kind {
            case .layer:
                state.layerFields.removeValue(forKey: name)
            case .binding:
                compilerEnvironment.bindingFields.removeValue(forKey: name)
            case .command:
                state.commandFields.removeValue(forKey: name)
            }
        }
    }
}

// MARK: - Event & Intercept Subscriptions

public enum KeymapEventSubscription<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    case state(@Sendable () -> Void)
    case pendingSequence(@Sendable ([KeySequencePart]) -> Void)
    case dispatch(@Sendable (DispatchEvent<Target, Event>) -> Void)
    case warning(@Sendable (KeymapDiagnosticEvent) -> Void)
    case error(@Sendable (KeymapDiagnosticEvent) -> Void)
}

public enum KeymapInterceptSubscription<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    case key(@Sendable (KeyInputContext<Event>) throws -> Void, KeyInterceptOptions = KeyInterceptOptions())
    case keyAfter(
        @Sendable (KeyAfterInputContext<Target, Event>) throws -> Void,
        KeyInterceptOptions = KeyInterceptOptions()
    )
    case raw(@Sendable (RawInputContext) throws -> Void, RawInterceptOptions = RawInterceptOptions())
}

// MARK: - Keymap Runtime Facade (keymap.ts)

private final class AcquiredResourceBox: @unchecked Sendable {
    var count: Int
    let dispose: @Sendable () -> Void

    init(count: Int = 1, dispose: @escaping @Sendable () -> Void) {
        self.count = count
        self.dispose = dispose
    }
}

private final class ListenerRegistry<Payload: Sendable>: @unchecked Sendable {
    private var nextID: Int = 0
    private var listeners: [(id: Int, fn: @Sendable (Payload) -> Void)] = []

    @discardableResult
    func add(_ fn: @escaping @Sendable (Payload) -> Void) -> @Sendable () -> Void {
        let id = nextID
        nextID += 1
        listeners.append((id: id, fn: fn))
        return { [weak self] in
            self?.listeners.removeAll { $0.id == id }
        }
    }

    func emit(_ payload: Payload) {
        let snapshot = listeners
        for entry in snapshot {
            entry.fn(payload)
        }
    }

    var isEmpty: Bool {
        listeners.isEmpty
    }
}

private final class WeakActivationBox<Host: KeymapHost>: @unchecked Sendable {
    weak var value: DefaultActivationService<Host>?
}

/// Alias matching runtime-oriented naming while preserving upstream `Keymap`.
public typealias KeymapRuntime<Host: KeymapHost> = Keymap<Host>

// parity: keymap/src/keymap.ts#Keymap [status=implemented hash=b3b2f20c0c16]
public final class Keymap<Host: KeymapHost>: @unchecked Sendable {
    public typealias Target = Host.Target
    public typealias Event = Host.Event

    public let host: Host
    private let hostMetadata: HostMetadata
    private let state: LayerStackState<Target, Event>
    private let compilerEnvironment: CompilerEnvironment<Target, Event>
    public let notifier: KeymapNotifier

    private let conditions: DefaultConditionService
    private let catalog: DefaultCommandCatalogService<Host>
    private let activation: DefaultActivationService<Host>
    private let runtime: DefaultRuntimeService<Target, Event>
    private let executor: DefaultCommandExecutorService<Target, Event>
    private let compiler: DefaultCompilerService<Target, Event>
    private let layerDiagnostics: DefaultLayerDiagnostics<Target, Event>
    private let layers: DefaultLayerService<Host, DefaultCompilerService<Target, Event>>
    private let dispatch: DefaultDispatchService<Target, Event>

    private let stateListeners = ListenerRegistry<Void>()
    private let pendingSequenceListeners = ListenerRegistry<[KeySequencePart]>()
    private let dispatchListeners = ListenerRegistry<DispatchEvent<Target, Event>>()
    private let warningListeners = ListenerRegistry<KeymapDiagnosticEvent>()
    private let errorListeners = ListenerRegistry<KeymapDiagnosticEvent>()

    private let layerBindingsTransformers = OrderedRegistry<LayerBindingsTransformer<Target, Event>>()
    private let bindingExpanders = OrderedRegistry<BindingExpander>()
    private let bindingParsers = OrderedRegistry<BindingParser>([defaultBindingParser])
    private let bindingTransformers = OrderedRegistry<BindingTransformer<Target, Event>>()
    private let commandTransformers = OrderedRegistry<CommandTransformer<Target, Event>>()

    private var cleanedUp: Bool = false
    private var resources: [String: AcquiredResourceBox] = [:]
    private var cleanupListeners: [@Sendable () -> Void] = []

    public init(
        host: Host,
        metadata: HostMetadata = .default,
        createCommandEvent: @escaping @Sendable () -> Event
    ) throws {
        if host.isDestroyed {
            throw KeymapHostError.hostDestroyed
        }

        self.host = host
        self.hostMetadata = metadata
        let state = LayerStackState<Target, Event>()
        self.state = state
        let compilerEnvironment = CompilerEnvironment<Target, Event>()
        self.compilerEnvironment = compilerEnvironment

        let warnListeners = self.warningListeners
        let errListeners = self.errorListeners
        let notifier = KeymapNotifier(
            onError: { event in errListeners.emit(event) },
            onWarning: { event in warnListeners.emit(event) }
        )
        self.notifier = notifier

        let stateListenersRef = self.stateListeners
        notifier.onStateChange {
            stateListenersRef.emit(())
        }

        let conditions = DefaultConditionService(
            readData: { state.data },
            notify: notifier
        )
        self.conditions = conditions

        let activationBox = WeakActivationBox<Host>()
        let catalog = DefaultCommandCatalogService(
            state: state,
            host: host,
            notify: notifier,
            conditions: conditions,
            options: CommandCatalogOptions(onCommandResolversChanged: {
                _ = activationBox.value?.ensureValidPendingSequence()
            })
        )
        self.catalog = catalog

        let pendingListenersRef = self.pendingSequenceListeners
        let activation = DefaultActivationService(
            state: state,
            host: host,
            notify: notifier,
            conditions: conditions,
            catalog: catalog,
            hasCommandResolvers: { [catalog] in catalog.hasCommandResolvers() },
            options: ActivationOptions(
                onEmitPendingSequence: { parts in
                    pendingListenersRef.emit(parts)
                }
            )
        )
        activationBox.value = activation
        self.activation = activation

        let runtime = DefaultRuntimeService(
            state: state,
            notify: notifier,
            ensureValidPendingSequence: { [activation] in
                _ = activation.ensureValidPendingSequence()
            }
        )
        self.runtime = runtime

        let executor = DefaultCommandExecutorService(
            notify: notifier,
            runtime: runtime,
            activation: activation,
            catalog: catalog,
            options: CommandExecutorOptions(createCommandEvent: createCommandEvent)
        )
        self.executor = executor

        let compiler = DefaultCompilerService(
            environment: compilerEnvironment,
            notify: notifier,
            conditions: conditions,
            options: CompilerOptions(
                warnUnknownField: { [notifier] kind, fieldName in
                    Keymap.emitUnknownFieldWarning(notifier: notifier, kind: kind, fieldName: fieldName)
                },
                warnUnknownToken: { [notifier] token, sequence in
                    Keymap.emitUnknownTokenWarning(notifier: notifier, token: token, sequence: sequence)
                }
            )
        )
        self.compiler = compiler

        let layerDiagnostics = createLayerDiagnostics(notify: notifier) { [catalog] command, localCommands in
            catalog.getCommandResolutionStatus(command, layerCommands: localCommands)
        }
        self.layerDiagnostics = layerDiagnostics

        let layers = DefaultLayerService(
            state: state,
            notify: notifier,
            conditions: conditions,
            activation: LayerActivationHooks(
                hasPendingSequenceState: { [activation] in activation.hasPendingSequenceState() },
                setPendingSequence: { [activation] next in activation.setPendingSequence(next) },
                ensureValidPendingSequence: { [activation] in _ = activation.ensureValidPendingSequence() },
                revalidatePendingSequenceIfNeeded: { [activation] in activation.revalidatePendingSequenceIfNeeded() }
            ),
            compiler: compiler,
            host: host,
            diagnostics: layerDiagnostics,
            warnUnknownField: { [notifier] kind, fieldName in
                Keymap.emitUnknownFieldWarning(notifier: notifier, kind: kind, fieldName: fieldName)
            }
        )
        self.layers = layers

        let dispatchListenersRef = self.dispatchListeners
        let dispatch = DefaultDispatchService(
            state: state,
            notify: notifier,
            runtime: runtime,
            activation: activation,
            conditions: conditions,
            executor: executor,
            compiler: compiler,
            catalog: catalog,
            layers: layers,
            initialEventMatchResolvers: [defaultEventMatchResolver],
            onDisambiguationPresenceChanged: { [compilerEnvironment] hasResolvers in
                compilerEnvironment.allowExactPrefixAmbiguity = hasResolvers
            },
            onEmitDispatch: { event in
                dispatchListenersRef.emit(event)
            }
        )
        self.dispatch = dispatch

        activation.setPendingSequenceChangedHandler { [dispatch] previous, next in
            dispatch.handlePendingSequenceChange(previous: previous, next: next)
        }
    }

    public convenience init(host: Host) throws where Host: InteractiveKeymapHost {
        try self.init(
            host: host,
            metadata: host.metadata,
            createCommandEvent: { [host] in host.createCommandEvent() }
        )
        cleanupListeners.append(host.onKeyPress { [weak self] event in
            self?.handleKeyEvent(event, release: false)
        })
        cleanupListeners.append(host.onKeyRelease { [weak self] event in
            self?.handleKeyEvent(event, release: true)
        })
        cleanupListeners.append(host.onRawInput { [weak self] sequence in
            self?.handleRawSequence(sequence) ?? false
        })
        cleanupListeners.append(host.onFocusChange { [weak self] focused in
            self?.handleFocusedTargetChange(focused)
        })
        cleanupListeners.append(host.onDestroy { [weak self] in
            self?.cleanup()
        })
    }

    public convenience init(
        host: Host,
        metadata: HostMetadata = .default
    ) throws where Host.Event == BasicKeymapEvent {
        try self.init(
            host: host,
            metadata: metadata,
            createCommandEvent: { BasicKeymapEvent(name: "") }
        )
    }

    // MARK: - Direct Event Entry Points & Lifecycle

    public func handleKeyPress(_ event: Event) {
        dispatch.handleKeyEvent(event, release: false)
    }

    public func handleKeyRelease(_ event: Event) {
        dispatch.handleKeyEvent(event, release: true)
    }

    public func handleKeyEvent(_ event: Event, release: Bool = false) {
        dispatch.handleKeyEvent(event, release: release)
    }

    @discardableResult
    public func handleRawSequence(_ sequence: String) -> Bool {
        dispatch.handleRawSequence(sequence)
    }

    public func handleFocusedTargetChange(_ focused: Target?) {
        notifier.runWithStateChangeBatch {
            activation.setPendingSequence(nil)
            notifier.queueStateChange(invalidateCaches: false)
        }
    }

    public func getPendingSequence() -> [KeySequencePart] {
        activation.getPendingSequence()
    }

    public func getActiveKeys(_ options: ActiveKeyOptions? = nil) -> [ActiveKey<Target, Event>] {
        activation.getActiveKeys(options: options)
    }

    public func cleanup() {
        if cleanedUp {
            return
        }
        cleanedUp = true

        activation.setPendingSequence(nil)

        for resource in resources.values {
            resource.dispose()
        }
        resources.removeAll()

        layers.cleanup()

        let pendingCleanups = cleanupListeners
        cleanupListeners.removeAll()
        for off in pendingCleanups {
            off()
        }
    }

    // MARK: - Keymap Public API (keymap.ts parity)

    // parity: keymap/src/keymap.ts#Keymap.setData [status=implemented hash=377c3699c1c7]
    public func setData(_ name: String, _ value: KeymapValue) {
        runtime.setData(name, value)
    }

    // parity: keymap/src/keymap.ts#Keymap.getData [status=implemented hash=0acd79a93e9f]
    public func getData(_ name: String) -> KeymapValue {
        runtime.getData(name)
    }

    // parity: keymap/src/keymap.ts#Keymap.getHostMetadata [status=implemented hash=4889936f1135]
    public func getHostMetadata() -> HostMetadata {
        hostMetadata
    }

    // parity: keymap/src/keymap.ts#Keymap.hasPendingSequence [status=implemented hash=f23680148c31]
    public func hasPendingSequence() -> Bool {
        activation.ensureValidPendingSequence() != nil
    }

    // parity: keymap/src/keymap.ts#Keymap.createKeyMatcher [status=implemented hash=1d801db4305d]
    public func createKeyMatcher(_ key: KeyLike) throws -> @Sendable (KeyStringifyInput?) -> Bool {
        let match = try compiler.parseTokenKey(key).match
        return { input in
            guard let input else {
                return false
            }
            return (try? resolveKeyMatch(input)) == match
        }
    }

    // parity: keymap/src/keymap.ts#Keymap.parseKeySequence [status=implemented hash=801c04da5dd4]
    public func parseKeySequence(_ key: KeyLike) throws -> [KeySequencePart] {
        try compiler.parseKeySequence(key)
    }

    // parity: keymap/src/keymap.ts#Keymap.formatKey [status=implemented hash=9f18f4a10d77]
    public func formatKey(_ key: KeyLike, options: StringifyOptions? = nil) throws -> String {
        try compiler.formatKey(key, options: options)
    }

    // parity: keymap/src/keymap.ts#Keymap.clearPendingSequence [status=implemented hash=66d96c6098dc]
    public func clearPendingSequence() {
        activation.setPendingSequence(nil)
    }

    // parity: keymap/src/keymap.ts#Keymap.popPendingSequence [status=implemented hash=30230ef2fec5]
    @discardableResult
    public func popPendingSequence() -> Bool {
        activation.popPendingSequence()
    }

    // parity: keymap/src/keymap.ts#Keymap.getCommands [status=implemented hash=b5c731299a02]
    public func getCommands(_ query: CommandQuery<Target, Event>? = nil) -> [Command<Target, Event>] {
        catalog.getCommands(query)
    }

    // parity: keymap/src/keymap.ts#Keymap.getCommandEntries [status=implemented hash=8c6b66a2a108]
    public func getCommandEntries(_ query: CommandQuery<Target, Event>? = nil) -> [CommandEntry<Target, Event>] {
        catalog.getCommandEntries(query)
    }

    // parity: keymap/src/keymap.ts#Keymap.getCommandBindings [status=implemented hash=ca456cd05f53]
    public func getCommandBindings(
        _ query: CommandBindingsQuery<Target>
    ) -> [String: [ActiveBinding<Target, Event>]] {
        catalog.getCommandBindings(query)
    }

    // parity: keymap/src/keymap.ts#Keymap.acquireResource [status=implemented hash=d2b63fa94afd]
    @discardableResult
    public func acquireResource(
        key: String,
        setup: () throws -> (@Sendable () -> Void)
    ) throws -> @Sendable () -> Void {
        if cleanedUp || host.isDestroyed {
            throw KeymapHostError.hostDestroyed
        }

        if let existing = resources[key] {
            existing.count += 1
            return { [weak self, existing] in
                self?.releaseResource(key: key, resource: existing)
            }
        }

        let dispose = try setup()
        let resource = AcquiredResourceBox(count: 1, dispose: dispose)
        resources[key] = resource
        return { [weak self, resource] in
            self?.releaseResource(key: key, resource: resource)
        }
    }

    // parity: keymap/src/keymap.ts#Keymap.runCommand [status=implemented hash=702c5c50a09b]
    @discardableResult
    public func runCommand(
        _ cmd: String,
        options: RunCommandOptions<Target, Event>? = nil
    ) -> RunCommandResult<Target, Event> {
        executor.runCommand(cmd, options: options)
    }

    // parity: keymap/src/keymap.ts#Keymap.dispatchCommand [status=implemented hash=4d025fe4e2b9]
    @discardableResult
    public func dispatchCommand(
        _ cmd: String,
        options: RunCommandOptions<Target, Event>? = nil
    ) -> RunCommandResult<Target, Event> {
        executor.dispatchCommand(cmd, options: options)
    }

    // parity: keymap/src/keymap.ts#Keymap.on [status=implemented hash=f1acc8cdb38c]
    @discardableResult
    public func on(_ subscription: KeymapEventSubscription<Target, Event>) -> @Sendable () -> Void {
        switch subscription {
        case .state(let fn):
            return stateListeners.add { _ in fn() }
        case .pendingSequence(let fn):
            return pendingSequenceListeners.add(fn)
        case .dispatch(let fn):
            return dispatchListeners.add(fn)
        case .warning(let fn):
            return warningListeners.add(fn)
        case .error(let fn):
            return errorListeners.add(fn)
        }
    }

    // parity: keymap/src/keymap.ts#Keymap.intercept [status=implemented hash=0f6ec2b2a001]
    @discardableResult
    public func intercept(_ subscription: KeymapInterceptSubscription<Target, Event>) -> @Sendable () -> Void {
        switch subscription {
        case .key(let fn, let options):
            return dispatch.interceptKey(fn, options: options)
        case .keyAfter(let fn, let options):
            return dispatch.interceptKeyAfter(fn, options: options)
        case .raw(let fn, let options):
            return dispatch.interceptRaw(fn, options: options)
        }
    }

    // parity: keymap/src/keymap.ts#Keymap.registerLayer [status=implemented hash=d5b1a99a1649]
    @discardableResult
    public func registerLayer(_ layer: Layer<Target, Event>) -> @Sendable () -> Void {
        layers.registerLayer(layer)
    }

    // parity: keymap/src/keymap.ts#Keymap.registerLayerFields [status=implemented hash=cd048d676537]
    @discardableResult
    public func registerLayerFields(_ fields: [String: FieldCompiler]) -> @Sendable () -> Void {
        registerFields(
            state: state,
            compilerEnvironment: compilerEnvironment,
            notify: notifier,
            kind: .layer,
            fields: fields
        )
    }

    // parity: keymap/src/keymap.ts#Keymap.prependLayerBindingsTransformer [status=implemented hash=c3585262655e]
    @discardableResult
    public func prependLayerBindingsTransformer(
        _ transformer: @escaping LayerBindingsTransformer<Target, Event>
    ) -> @Sendable () -> Void {
        let off = layerBindingsTransformers.prepend(transformer)
        syncLayerBindingsTransformers()
        return { [weak self] in
            off()
            self?.syncLayerBindingsTransformers()
        }
    }

    // parity: keymap/src/keymap.ts#Keymap.appendLayerBindingsTransformer [status=implemented hash=60a01040babb]
    @discardableResult
    public func appendLayerBindingsTransformer(
        _ transformer: @escaping LayerBindingsTransformer<Target, Event>
    ) -> @Sendable () -> Void {
        let off = layerBindingsTransformers.append(transformer)
        syncLayerBindingsTransformers()
        return { [weak self] in
            off()
            self?.syncLayerBindingsTransformers()
        }
    }

    // parity: keymap/src/keymap.ts#Keymap.clearLayerBindingsTransformers [status=implemented hash=0c5d5c63569f]
    public func clearLayerBindingsTransformers() {
        layerBindingsTransformers.clear()
        syncLayerBindingsTransformers()
    }

    // parity: keymap/src/keymap.ts#Keymap.prependBindingTransformer [status=implemented hash=dd999d9756bf]
    @discardableResult
    public func prependBindingTransformer(
        _ transformer: @escaping BindingTransformer<Target, Event>
    ) -> @Sendable () -> Void {
        let off = bindingTransformers.prepend(transformer)
        syncBindingTransformers()
        return { [weak self] in
            off()
            self?.syncBindingTransformers()
        }
    }

    // parity: keymap/src/keymap.ts#Keymap.appendBindingTransformer [status=implemented hash=6b772234668b]
    @discardableResult
    public func appendBindingTransformer(
        _ transformer: @escaping BindingTransformer<Target, Event>
    ) -> @Sendable () -> Void {
        let off = bindingTransformers.append(transformer)
        syncBindingTransformers()
        return { [weak self] in
            off()
            self?.syncBindingTransformers()
        }
    }

    // parity: keymap/src/keymap.ts#Keymap.clearBindingTransformers [status=implemented hash=6fb6026da67d]
    public func clearBindingTransformers() {
        bindingTransformers.clear()
        syncBindingTransformers()
    }

    // parity: keymap/src/keymap.ts#Keymap.prependCommandTransformer [status=implemented hash=31ede8239242]
    @discardableResult
    public func prependCommandTransformer(
        _ transformer: @escaping CommandTransformer<Target, Event>
    ) -> @Sendable () -> Void {
        let off = commandTransformers.prepend(transformer)
        syncCommandTransformers()
        return { [weak self] in
            off()
            self?.syncCommandTransformers()
        }
    }

    // parity: keymap/src/keymap.ts#Keymap.appendCommandTransformer [status=implemented hash=c91a6b61eb71]
    @discardableResult
    public func appendCommandTransformer(
        _ transformer: @escaping CommandTransformer<Target, Event>
    ) -> @Sendable () -> Void {
        let off = commandTransformers.append(transformer)
        syncCommandTransformers()
        return { [weak self] in
            off()
            self?.syncCommandTransformers()
        }
    }

    // parity: keymap/src/keymap.ts#Keymap.clearCommandTransformers [status=implemented hash=941cd86fb4ec]
    public func clearCommandTransformers() {
        commandTransformers.clear()
        syncCommandTransformers()
    }

    // parity: keymap/src/keymap.ts#Keymap.prependBindingParser [status=implemented hash=3de481a26e6d]
    @discardableResult
    public func prependBindingParser(_ parser: @escaping BindingParser) -> @Sendable () -> Void {
        let off = bindingParsers.prepend(parser)
        syncBindingParsers()
        return { [weak self] in
            off()
            self?.syncBindingParsers()
        }
    }

    // parity: keymap/src/keymap.ts#Keymap.appendBindingParser [status=implemented hash=2c82ddb7a2c3]
    @discardableResult
    public func appendBindingParser(_ parser: @escaping BindingParser) -> @Sendable () -> Void {
        let off = bindingParsers.append(parser)
        syncBindingParsers()
        return { [weak self] in
            off()
            self?.syncBindingParsers()
        }
    }

    // parity: keymap/src/keymap.ts#Keymap.clearBindingParsers [status=implemented hash=0d72a7ff72fc]
    public func clearBindingParsers() {
        bindingParsers.clear()
        syncBindingParsers()
    }

    // parity: keymap/src/keymap.ts#Keymap.registerToken [status=implemented hash=5e047b8a9f7c]
    @discardableResult
    public func registerToken(_ token: KeyToken) -> @Sendable () -> Void {
        OpenTUIKeymap.registerToken(
            state: state,
            compilerEnvironment: compilerEnvironment,
            notify: notifier,
            compiler: compiler,
            layers: layers,
            token: token
        )
    }

    // parity: keymap/src/keymap.ts#Keymap.registerSequencePattern [status=implemented hash=948cb765dfde]
    @discardableResult
    public func registerSequencePattern(_ pattern: SequencePattern<Event>) -> @Sendable () -> Void {
        OpenTUIKeymap.registerSequencePattern(
            state: state,
            compilerEnvironment: compilerEnvironment,
            notify: notifier,
            layers: layers,
            pattern: pattern
        )
    }

    // parity: keymap/src/keymap.ts#Keymap.prependBindingExpander [status=implemented hash=8eeee3466eda]
    @discardableResult
    public func prependBindingExpander(_ expander: @escaping BindingExpander) -> @Sendable () -> Void {
        let off = bindingExpanders.prepend(expander)
        syncBindingExpanders()
        return { [weak self] in
            off()
            self?.syncBindingExpanders()
        }
    }

    // parity: keymap/src/keymap.ts#Keymap.appendBindingExpander [status=implemented hash=9bd3c4183605]
    @discardableResult
    public func appendBindingExpander(_ expander: @escaping BindingExpander) -> @Sendable () -> Void {
        let off = bindingExpanders.append(expander)
        syncBindingExpanders()
        return { [weak self] in
            off()
            self?.syncBindingExpanders()
        }
    }

    // parity: keymap/src/keymap.ts#Keymap.clearBindingExpanders [status=implemented hash=eb33004eacbe]
    public func clearBindingExpanders() {
        bindingExpanders.clear()
        syncBindingExpanders()
    }

    // parity: keymap/src/keymap.ts#Keymap.registerBindingFields [status=implemented hash=f97eb47deee6]
    @discardableResult
    public func registerBindingFields(_ fields: [String: FieldCompiler]) -> @Sendable () -> Void {
        registerFields(
            state: state,
            compilerEnvironment: compilerEnvironment,
            notify: notifier,
            kind: .binding,
            fields: fields
        )
    }

    // parity: keymap/src/keymap.ts#Keymap.registerCommandFields [status=implemented hash=772c2d0d595b]
    @discardableResult
    public func registerCommandFields(_ fields: [String: FieldCompiler]) -> @Sendable () -> Void {
        registerFields(
            state: state,
            compilerEnvironment: compilerEnvironment,
            notify: notifier,
            kind: .command,
            fields: fields
        )
    }

    // parity: keymap/src/keymap.ts#Keymap.prependCommandResolver [status=implemented hash=ed490af0b739]
    @discardableResult
    public func prependCommandResolver(_ resolver: @escaping CommandResolver<Target, Event>) -> @Sendable () -> Void {
        catalog.prependCommandResolver(resolver)
    }

    // parity: keymap/src/keymap.ts#Keymap.appendCommandResolver [status=implemented hash=41e920f46d0d]
    @discardableResult
    public func appendCommandResolver(_ resolver: @escaping CommandResolver<Target, Event>) -> @Sendable () -> Void {
        catalog.appendCommandResolver(resolver)
    }

    // parity: keymap/src/keymap.ts#Keymap.clearCommandResolvers [status=implemented hash=60a0208db083]
    public func clearCommandResolvers() {
        catalog.clearCommandResolvers()
    }

    // parity: keymap/src/keymap.ts#Keymap.prependLayerAnalyzer [status=implemented hash=b462ef8891df]
    @discardableResult
    public func prependLayerAnalyzer(_ analyzer: @escaping LayerAnalyzer<Target, Event>) -> @Sendable () -> Void {
        layerDiagnostics.prependLayerAnalyzer(analyzer)
    }

    // parity: keymap/src/keymap.ts#Keymap.appendLayerAnalyzer [status=implemented hash=850194495169]
    @discardableResult
    public func appendLayerAnalyzer(_ analyzer: @escaping LayerAnalyzer<Target, Event>) -> @Sendable () -> Void {
        layerDiagnostics.appendLayerAnalyzer(analyzer)
    }

    // parity: keymap/src/keymap.ts#Keymap.clearLayerAnalyzers [status=implemented hash=fed9498fd9a0]
    public func clearLayerAnalyzers() {
        layerDiagnostics.clearLayerAnalyzers()
    }

    // parity: keymap/src/keymap.ts#Keymap.prependEventMatchResolver [status=implemented hash=373e8d421430]
    @discardableResult
    public func prependEventMatchResolver(_ resolver: @escaping EventMatchResolver<Event>) -> @Sendable () -> Void {
        dispatch.prependEventMatchResolver(resolver)
    }

    // parity: keymap/src/keymap.ts#Keymap.appendEventMatchResolver [status=implemented hash=8b477d65ead6]
    @discardableResult
    public func appendEventMatchResolver(_ resolver: @escaping EventMatchResolver<Event>) -> @Sendable () -> Void {
        dispatch.appendEventMatchResolver(resolver)
    }

    // parity: keymap/src/keymap.ts#Keymap.clearEventMatchResolvers [status=implemented hash=2cd6515ca309]
    public func clearEventMatchResolvers() {
        dispatch.clearEventMatchResolvers()
    }

    // parity: keymap/src/keymap.ts#Keymap.prependDisambiguationResolver [status=implemented hash=e9aa3d24b245]
    @discardableResult
    public func prependDisambiguationResolver(
        _ resolver: @escaping KeyDisambiguationResolver<Target, Event>
    ) -> @Sendable () -> Void {
        dispatch.prependDisambiguationResolver(resolver)
    }

    // parity: keymap/src/keymap.ts#Keymap.appendDisambiguationResolver [status=implemented hash=a22e81a459e6]
    @discardableResult
    public func appendDisambiguationResolver(
        _ resolver: @escaping KeyDisambiguationResolver<Target, Event>
    ) -> @Sendable () -> Void {
        dispatch.appendDisambiguationResolver(resolver)
    }

    // parity: keymap/src/keymap.ts#Keymap.clearDisambiguationResolvers [status=implemented hash=fba969ff8c62]
    public func clearDisambiguationResolvers() {
        dispatch.clearDisambiguationResolvers()
    }

    // MARK: - Internal Synchronization & Resource Helpers

    private func syncLayerBindingsTransformers() {
        state.layerBindingsTransformers = layerBindingsTransformers.values()
    }

    private func syncBindingExpanders() {
        compilerEnvironment.bindingExpanders = bindingExpanders.values()
    }

    private func syncBindingParsers() {
        compilerEnvironment.bindingParsers = bindingParsers.values()
    }

    private func syncBindingTransformers() {
        compilerEnvironment.bindingTransformers = bindingTransformers.values()
    }

    private func syncCommandTransformers() {
        state.commandTransformers = commandTransformers.values()
    }

    private func releaseResource(key: String, resource: AcquiredResourceBox) {
        guard let current = resources[key], current === resource else {
            return
        }
        resource.count -= 1
        if resource.count > 0 {
            return
        }
        resource.dispose()
        resources.removeValue(forKey: key)
    }

    private static func emitUnknownFieldWarning(
        notifier: KeymapNotifier,
        kind: FieldKind,
        fieldName: String
    ) {
        notifier.warnOnce(
            key: "\(kind.rawValue):\(fieldName)",
            code: "unknown-\(kind.rawValue)-field",
            detail: fieldName,
            message: "[Keymap] Unknown \(kind.rawValue) field \"\(fieldName)\" was ignored"
        )
    }

    private static func emitUnknownTokenWarning(
        notifier: KeymapNotifier,
        token: String,
        sequence: String
    ) {
        notifier.warnOnce(
            key: "token:\(token)",
            code: "unknown-token",
            detail: "\(token):\(sequence)",
            message:
                "[Keymap] Unknown token \"\(token)\" in key sequence \"\(sequence)\"; binding was skipped until the token is registered"
        )
    }
}

/// Convenience factory creating a runnable `Keymap` facade for any `KeymapHost`.
public func createKeymap<Host: KeymapHost>(
    host: Host,
    metadata: HostMetadata = .default,
    createCommandEvent: @escaping @Sendable () -> Host.Event
) throws -> Keymap<Host> {
    try Keymap(host: host, metadata: metadata, createCommandEvent: createCommandEvent)
}

/// Convenience factory creating a runnable `Keymap` facade for `BasicKeymapEvent` hosts.
public func createKeymap<Host: KeymapHost>(
    host: Host,
    metadata: HostMetadata = .default
) throws -> Keymap<Host> where Host.Event == BasicKeymapEvent {
    try Keymap(host: host, metadata: metadata)
}
