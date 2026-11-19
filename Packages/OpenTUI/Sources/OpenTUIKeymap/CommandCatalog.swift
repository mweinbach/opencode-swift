// Pure Swift 6 port of keymap/src/services/command-catalog.ts and keymap/src/services/runtime-view.ts.

// MARK: - Ordered & Priority Registry Helpers

/// Internal insertion-ordered registry with prepend/append/clear and ID-based disposal.
public final class OrderedRegistry<T: Sendable>: @unchecked Sendable {
    private var nextID: Int = 0
    private var entries: [(id: Int, value: T)] = []

    public init(_ initial: [T] = []) {
        for item in initial {
            _ = append(item)
        }
    }

    @discardableResult
    public func prepend(_ value: T) -> @Sendable () -> Void {
        let id = nextID
        nextID += 1
        entries.insert((id: id, value: value), at: 0)
        return { [weak self] in
            self?.entries.removeAll { $0.id == id }
        }
    }

    @discardableResult
    public func append(_ value: T) -> @Sendable () -> Void {
        let id = nextID
        nextID += 1
        entries.append((id: id, value: value))
        return { [weak self] in
            self?.entries.removeAll { $0.id == id }
        }
    }

    public func clear() {
        entries.removeAll()
    }

    public func values() -> [T] {
        entries.map(\.value)
    }

    public func has() -> Bool {
        !entries.isEmpty
    }

    public var count: Int {
        entries.count
    }
}

/// Priority-ordered listener registry (higher priority runs first; ties keep insertion order).
public final class PriorityRegistry<Listener: Sendable, Meta: Sendable>: @unchecked Sendable {
    public struct Entry: Sendable {
        public let id: Int
        public let priority: Int
        public let listener: Listener
        public let meta: Meta
    }

    private var nextID: Int = 0
    private var items: [Entry] = []

    public init() {}

    @discardableResult
    public func register(
        _ listener: Listener,
        priority: Int = 0,
        meta: Meta
    ) -> @Sendable () -> Void {
        let id = nextID
        nextID += 1
        let entry = Entry(id: id, priority: priority, listener: listener, meta: meta)
        if let insertIndex = items.firstIndex(where: { $0.priority < priority }) {
            items.insert(entry, at: insertIndex)
        } else {
            items.append(entry)
        }
        return { [weak self] in
            self?.items.removeAll { $0.id == id }
        }
    }

    public func entries() -> [Entry] {
        items
    }

    public func clear() {
        items.removeAll()
    }

    public var isEmpty: Bool {
        items.isEmpty
    }
}

// MARK: - Command View & Query Types

public struct LayerCommandEntry<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public let layer: RegisteredLayer<Target, Event>
    public let commandState: CommandState<Target, Event>

    public init(layer: RegisteredLayer<Target, Event>, commandState: CommandState<Target, Event>) {
        self.layer = layer
        self.commandState = commandState
    }
}

public struct ResolvedCommandEntry<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public let target: Target?
    public let command: Command<Target, Event>
    public let attrs: Attributes?
    public let input: String?
    public let payload: KeymapValue?

    public init(
        target: Target? = nil,
        command: Command<Target, Event>,
        attrs: Attributes? = nil,
        input: String? = nil,
        payload: KeymapValue? = nil
    ) {
        self.target = target
        self.command = command
        self.attrs = attrs
        self.input = input
        self.payload = payload
    }
}

public struct CommandView<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public let entries: [LayerCommandEntry<Target, Event>]
    public let chainsByName: [String: [LayerCommandEntry<Target, Event>]]

    public init(
        entries: [LayerCommandEntry<Target, Event>],
        chainsByName: [String: [LayerCommandEntry<Target, Event>]]
    ) {
        self.entries = entries
        self.chainsByName = chainsByName
    }
}

public struct ActiveCommandView<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public let layers: [RegisteredLayer<Target, Event>]
    public let entries: [LayerCommandEntry<Target, Event>]
    public let reachable: [LayerCommandEntry<Target, Event>]
    public let reachableByName: [String: LayerCommandEntry<Target, Event>]
    public let chainsByName: [String: [LayerCommandEntry<Target, Event>]]

    public init(
        layers: [RegisteredLayer<Target, Event>],
        entries: [LayerCommandEntry<Target, Event>],
        reachable: [LayerCommandEntry<Target, Event>],
        reachableByName: [String: LayerCommandEntry<Target, Event>],
        chainsByName: [String: [LayerCommandEntry<Target, Event>]]
    ) {
        self.layers = layers
        self.entries = entries
        self.reachable = reachable
        self.reachableByName = reachableByName
        self.chainsByName = chainsByName
    }
}

public enum CommandVisibility: String, Equatable, Hashable, Sendable {
    case reachable
    case active
    case registered
}

public enum CommandQueryValue<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    case exact(KeymapValue)
    case anyOf([KeymapValue])
    case predicate(@Sendable (KeymapValue, Command<Target, Event>) throws -> Bool)
}

public enum CommandFilter<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    case fields([String: CommandQueryValue<Target, Event>])
    case predicate(@Sendable (Command<Target, Event>) throws -> Bool)
}

public struct CommandQuery<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public var visibility: CommandVisibility
    /// `.none` uses the host's current focused target; `.some(nil)` explicitly queries unfocused; `.some(t)` queries `t`.
    public var focused: Target??
    public var namespace: [String]?
    public var search: String?
    public var searchIn: [String]?
    public var filter: CommandFilter<Target, Event>?
    public var limit: Int?

    public init(
        visibility: CommandVisibility = .reachable,
        focused: Target?? = nil,
        namespace: [String]? = nil,
        search: String? = nil,
        searchIn: [String]? = nil,
        filter: CommandFilter<Target, Event>? = nil,
        limit: Int? = nil
    ) {
        self.visibility = visibility
        self.focused = focused
        self.namespace = namespace
        self.search = search
        self.searchIn = searchIn
        self.filter = filter
        self.limit = limit
    }

    public init(
        visibility: CommandVisibility = .reachable,
        focused: Target?? = nil,
        namespace: String,
        search: String? = nil,
        searchIn: [String]? = nil,
        filter: CommandFilter<Target, Event>? = nil,
        limit: Int? = nil
    ) {
        self.init(
            visibility: visibility,
            focused: focused,
            namespace: [namespace],
            search: search,
            searchIn: searchIn,
            filter: filter,
            limit: limit
        )
    }
}

public struct CommandBindingsQuery<Target: Hashable & Sendable>: Sendable {
    public var visibility: CommandVisibility
    public var focused: Target??
    public var commands: [String]

    public init(
        visibility: CommandVisibility = .reachable,
        focused: Target?? = nil,
        commands: [String]
    ) {
        self.visibility = visibility
        self.focused = focused
        self.commands = commands
    }
}

public struct CommandEntry<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public let command: Command<Target, Event>
    public let bindings: [ActiveBinding<Target, Event>]

    public init(command: Command<Target, Event>, bindings: [ActiveBinding<Target, Event>]) {
        self.command = command
        self.bindings = bindings
    }
}

public struct CommandExecutionFields: Equatable, Sendable {
    public let input: String
    public let payload: KeymapValue?

    public init(input: String, payload: KeymapValue? = nil) {
        self.input = input
        self.payload = payload
    }
}

public struct ResolvedCommandLookup<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public var resolved: ResolvedCommandEntry<Target, Event>?
    public let hadError: Bool

    public init(resolved: ResolvedCommandEntry<Target, Event>? = nil, hadError: Bool = false) {
        self.resolved = resolved
        self.hadError = hadError
    }
}

public struct CommandChainLookup<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public let entries: [ResolvedCommandEntry<Target, Event>]?
    public let hadError: Bool

    public init(entries: [ResolvedCommandEntry<Target, Event>]? = nil, hadError: Bool = false) {
        self.entries = entries
        self.hadError = hadError
    }
}

public enum UnavailableCommandReason: String, Equatable, Hashable, Sendable {
    case inactive
    case disabled
}

public struct UnavailableCommandState<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public let reason: UnavailableCommandReason
    public let command: Command<Target, Event>?

    public init(reason: UnavailableCommandReason, command: Command<Target, Event>? = nil) {
        self.reason = reason
        self.command = command
    }
}

public final class CommandResolverContext<Target: Hashable & Sendable, Event: KeymapEvent>: @unchecked Sendable {
    public private(set) var input: String
    public private(set) var payload: KeymapValue?
    private let lookupCommand: @Sendable (String) -> Command<Target, Event>?

    public init(
        input: String,
        payload: KeymapValue? = nil,
        getCommand: @escaping @Sendable (String) -> Command<Target, Event>?
    ) {
        self.input = input
        self.payload = payload
        self.lookupCommand = getCommand
    }

    public func setInput(_ nextInput: String) {
        self.input = nextInput
    }

    public func setPayload(_ nextPayload: KeymapValue?) {
        self.payload = nextPayload
    }

    public func getCommand(_ name: String) -> Command<Target, Event>? {
        lookupCommand(name)
    }

    internal var executionFields: CommandExecutionFields {
        CommandExecutionFields(input: input, payload: payload)
    }
}

public typealias CommandResolver<Target: Hashable & Sendable, Event: KeymapEvent> =
    @Sendable (String, CommandResolverContext<Target, Event>) throws -> Command<Target, Event>?

public struct CommandCatalogOptions: Sendable {
    public let onCommandResolversChanged: @Sendable () -> Void

    public init(onCommandResolversChanged: @escaping @Sendable () -> Void = {}) {
        self.onCommandResolversChanged = onCommandResolversChanged
    }
}

// MARK: - Runtime View Projections (runtime-view.ts)

// parity: keymap/src/services/runtime-view.ts#getRegisteredCommandView [status=implemented hash=be3c634b9a2f]
public func getRegisteredCommandView<Target: Hashable & Sendable, Event: KeymapEvent>(
    _ state: LayerStackState<Target, Event>
) -> CommandView<Target, Event> {
    var entries: [LayerCommandEntry<Target, Event>] = []
    var chainsByName: [String: [LayerCommandEntry<Target, Event>]] = [:]

    for layer in state.layers {
        for commandState in layer.commands {
            let entry = LayerCommandEntry(layer: layer, commandState: commandState)
            entries.append(entry)
            chainsByName[commandState.command.name, default: []].append(entry)
        }
    }

    return CommandView(entries: entries, chainsByName: chainsByName)
}

// parity: keymap/src/services/runtime-view.ts#getActiveCommandView [status=implemented hash=f4c88617ec50]
public func getActiveCommandView<Host: KeymapHost>(
    state: LayerStackState<Host.Target, Host.Event>,
    host: Host,
    conditions: any ConditionService,
    focused: Host.Target?
) -> ActiveCommandView<Host.Target, Host.Event> {
    let activeLayers = getActiveLayersForFocused(
        layers: state.sortedLayers,
        host: host,
        focused: focused,
        alreadySorted: true
    )
    return collectActiveCommands(layers: activeLayers, conditions: conditions, checkLayerConditions: true)
}

private func collectActiveCommands<Target: Hashable & Sendable, Event: KeymapEvent>(
    layers: [RegisteredLayer<Target, Event>],
    conditions: any ConditionService,
    checkLayerConditions: Bool
) -> ActiveCommandView<Target, Event> {
    var entries: [LayerCommandEntry<Target, Event>] = []
    var reachable: [LayerCommandEntry<Target, Event>] = []
    var reachableByName: [String: LayerCommandEntry<Target, Event>] = [:]
    var chainsByName: [String: [LayerCommandEntry<Target, Event>]] = [:]

    for layer in layers {
        if layer.commands.isEmpty {
            continue
        }
        if checkLayerConditions && !conditions.matchesConditions(layer) {
            continue
        }

        for commandState in layer.commands {
            if !conditions.matchesConditions(commandState) {
                continue
            }

            let entry = LayerCommandEntry(layer: layer, commandState: commandState)
            entries.append(entry)
            chainsByName[commandState.command.name, default: []].append(entry)
            if reachableByName[commandState.command.name] == nil {
                reachableByName[commandState.command.name] = entry
                reachable.append(entry)
            }
        }
    }

    return ActiveCommandView(
        layers: layers,
        entries: entries,
        reachable: reachable,
        reachableByName: reachableByName,
        chainsByName: chainsByName
    )
}

// MARK: - Command Catalog Service (command-catalog.ts)

// parity: keymap/src/services/command-catalog.ts#getCommand [status=implemented hash=7c38706c2df2]
public func getCommand<Target: Hashable & Sendable, Event: KeymapEvent>(
    _ state: CommandState<Target, Event>
) -> Command<Target, Event> {
    state.command
}

// parity: keymap/src/services/command-catalog.ts#CommandCatalogService [status=implemented hash=da926c364ea1]
public protocol CommandCatalogService<Target, Event>: AnyObject, Sendable {
    associatedtype Target: Hashable & Sendable
    associatedtype Event: KeymapEvent

    func normalizeCommands(
        _ commands: [Command<Target, Event>],
        owned: Bool
    ) -> [CommandState<Target, Event>]
    @discardableResult
    func prependCommandResolver(_ resolver: @escaping CommandResolver<Target, Event>) -> @Sendable () -> Void
    @discardableResult
    func appendCommandResolver(_ resolver: @escaping CommandResolver<Target, Event>) -> @Sendable () -> Void
    func clearCommandResolvers()
    func hasCommandResolvers() -> Bool
    func getCommands(_ query: CommandQuery<Target, Event>?) -> [Command<Target, Event>]
    func getCommandEntries(_ query: CommandQuery<Target, Event>?) -> [CommandEntry<Target, Event>]
    func getCommandBindings(_ query: CommandBindingsQuery<Target>) -> [String: [ActiveBinding<Target, Event>]]
    func getResolvedCommandChain(
        _ command: String,
        focused: Target?,
        execution: CommandExecutionFields?
    ) -> CommandChainLookup<Target, Event>
    func getRegisteredResolvedEntries(_ command: String) -> [ResolvedCommandEntry<Target, Event>]?
    func getActiveRegisteredResolvedEntries(
        _ command: String,
        focused: Target?
    ) -> [ResolvedCommandEntry<Target, Event>]?
    func resolveRegisteredResolverFallback(
        _ command: String,
        execution: CommandExecutionFields?
    ) -> ResolvedCommandLookup<Target, Event>
    func resolveActiveResolverFallback(
        _ command: String,
        focused: Target?,
        execution: CommandExecutionFields?
    ) -> ResolvedCommandLookup<Target, Event>
    func getTopCommand(_ command: String, focused: Target?) -> Command<Target, Event>?
    func getDispatchUnavailableCommandState(
        _ command: String,
        focused: Target?,
        includeCommand: Bool
    ) -> UnavailableCommandState<Target, Event>?
    func getActiveCommandView(focused: Target?) -> ActiveCommandView<Target, Event>
    func isBindingVisible(
        _ binding: BindingState<Target, Event>,
        focused: Target?,
        activeView: ActiveCommandView<Target, Event>
    ) -> Bool
    func getBindingCommandAttrs(
        _ binding: BindingState<Target, Event>,
        focused: Target?,
        activeView: ActiveCommandView<Target, Event>
    ) -> Attributes?
    func getCommandResolutionStatus(
        _ command: String,
        layerCommands: [CommandState<Target, Event>]?
    ) -> CommandResolutionStatus
}

private enum CommandResolutionMode {
    case active
    case registered
}

public final class DefaultCommandCatalogService<Host: KeymapHost>: CommandCatalogService, @unchecked Sendable {
    public typealias Target = Host.Target
    public typealias Event = Host.Event

    private static var defaultSearchFields: [String] { ["name"] }

    private let state: LayerStackState<Target, Event>
    private let host: Host
    private let notify: KeymapNotifier
    private let conditions: any ConditionService
    private let options: CommandCatalogOptions
    private let commandResolvers = OrderedRegistry<CommandResolver<Target, Event>>()

    private var registeredViewVersion: Int = -1
    private var registeredView: CommandView<Target, Event>?
    private var activeViewVersion: Int = -1
    private var activeViewHasFocused: Bool = false
    private var activeViewFocused: Target?
    private var activeView: ActiveCommandView<Target, Event>?

    private var registeredBindingsCacheVersion: Int = -1
    private var registeredBindingsCacheCommands: [String]?
    private var registeredBindingsCache: [String: [ActiveBinding<Target, Event>]]?

    private var registeredBindingsByCommandVersion: Int = -1
    private var registeredBindingsByCommand: [String: [BindingState<Target, Event>]]?

    private var registeredResolvedCacheVersion: Int = -1
    private var registeredResolvedCache: [String: [ResolvedCommandEntry<Target, Event>]?] = [:]

    private var searchCache: [ObjectIdentifier: [String: String?]] = [:]

    public init(
        state: LayerStackState<Target, Event>,
        host: Host,
        notify: KeymapNotifier,
        conditions: any ConditionService,
        options: CommandCatalogOptions = CommandCatalogOptions()
    ) {
        self.state = state
        self.host = host
        self.notify = notify
        self.conditions = conditions
        self.options = options
    }

    public func hasCommandResolvers() -> Bool {
        commandResolvers.has()
    }

    public func normalizeCommands(
        _ commands: [Command<Target, Event>],
        owned: Bool = false
    ) -> [CommandState<Target, Event>] {
        var normalizedCommands: [CommandState<Target, Event>] = []
        var seen: Set<String> = []

        for command in commands {
            do {
                let normalizedName = try normalizeCommandName(command.name)
                if seen.contains(normalizedName) {
                    notify.emitError(
                        "duplicate-command",
                        detail: normalizedName,
                        message: "Duplicate keymap command \"\(normalizedName)\" in the same layer"
                    )
                    continue
                }

                var exposed = command
                exposed.name = normalizedName
                if owned {
                    let forwarder = createForwarder(command.run)
                    exposed.run = { ctx in try forwarder.target(ctx) }
                }

                let fields = extractCommandFields(command)
                let accumulator = FieldAccumulator(allowsAttributes: true)
                for fieldName in fields.keys.sorted() {
                    guard let value = fields[fieldName], value != .undefined else {
                        continue
                    }
                    guard let fieldCompiler = state.commandFields[fieldName] else {
                        continue
                    }
                    let ctx = createFieldCompilerContext(
                        fieldName: fieldName,
                        conditions: conditions,
                        accumulator: accumulator
                    )
                    try fieldCompiler(value, ctx)
                }

                let commandState = CommandState(
                    command: exposed,
                    fields: fields,
                    attrs: accumulator.attrs.isEmpty ? nil : accumulator.attrs,
                    requires: accumulator.orderedRequirements,
                    matchers: accumulator.matchers
                )
                seen.insert(normalizedName)
                normalizedCommands.append(commandState)
            } catch {
                notify.emitError(
                    "register-command-failed",
                    error: error,
                    message: getErrorMessage(error, fallback: "Failed to register keymap command \"\(command.name)\"")
                )
            }
        }

        return normalizedCommands
    }

    @discardableResult
    public func prependCommandResolver(
        _ resolver: @escaping CommandResolver<Target, Event>
    ) -> @Sendable () -> Void {
        mutateCommandResolvers {
            commandResolvers.prepend(resolver)
        }
    }

    @discardableResult
    public func appendCommandResolver(
        _ resolver: @escaping CommandResolver<Target, Event>
    ) -> @Sendable () -> Void {
        mutateCommandResolvers {
            commandResolvers.append(resolver)
        }
    }

    public func clearCommandResolvers() {
        if !commandResolvers.has() {
            return
        }
        notify.runWithStateChangeBatch {
            commandResolvers.clear()
            options.onCommandResolversChanged()
            notify.queueStateChange()
        }
    }

    public func getCommands(_ query: CommandQuery<Target, Event>? = nil) -> [Command<Target, Event>] {
        getFilteredCommandEntries(query: query).map { getCommand($0.commandState) }
    }

    public func getCommandEntries(_ query: CommandQuery<Target, Event>? = nil) -> [CommandEntry<Target, Event>] {
        let context = getCommandQueryContext(query)
        let filteredEntries = getFilteredCommandEntries(query: query, context: context)
        if filteredEntries.isEmpty {
            return []
        }

        var grouped: [(command: Command<Target, Event>, commandAttrs: Attributes?, bindings: [ActiveBinding<Target, Event>])] =
            filteredEntries.map { entry in
                (
                    command: getCommand(entry.commandState),
                    commandAttrs: entry.commandState.attrs,
                    bindings: []
                )
            }
        var indexesByName: [String: [Int]] = [:]
        for (index, item) in grouped.enumerated() {
            indexesByName[item.command.name, default: []].append(index)
        }

        if !indexesByName.isEmpty {
            visitCommandQueryBindings(context: context) { binding in
                guard let name = binding.command?.commandName, let indexes = indexesByName[name] else {
                    return
                }
                for idx in indexes {
                    grouped[idx].bindings.append(createActiveBinding(binding, commandAttrs: grouped[idx].commandAttrs))
                }
            }
        }

        return grouped.map { CommandEntry(command: $0.command, bindings: $0.bindings) }
    }

    public func getCommandBindings(
        _ query: CommandBindingsQuery<Target>
    ) -> [String: [ActiveBinding<Target, Event>]] {
        if query.visibility == .registered,
            registeredBindingsCacheVersion == notify.derivedVersion,
            registeredBindingsCacheCommands == query.commands,
            let cached = registeredBindingsCache
        {
            return cached
        }

        var bindingsByCommand: [String: [ActiveBinding<Target, Event>]] = [:]
        for command in query.commands where bindingsByCommand[command] == nil {
            bindingsByCommand[command] = []
        }

        if bindingsByCommand.isEmpty {
            return bindingsByCommand
        }

        let context = getCommandQueryContext(visibility: query.visibility, focusedOverride: query.focused)
        if context.visibility == .registered {
            let registeredBindings = getRegisteredBindingsByCommand()
            let view = getCommandView()
            for command in Array(bindingsByCommand.keys) {
                let commandAttrs = view.chainsByName[command]?.first?.commandState.attrs
                for binding in registeredBindings[command] ?? [] {
                    bindingsByCommand[command]?.append(createActiveBinding(binding, commandAttrs: commandAttrs))
                }
            }
            registeredBindingsCacheVersion = notify.derivedVersion
            registeredBindingsCacheCommands = query.commands
            registeredBindingsCache = bindingsByCommand
            return bindingsByCommand
        }

        visitCommandQueryBindings(context: context) { binding in
            guard let name = binding.command?.commandName, bindingsByCommand[name] != nil else {
                return
            }
            let attrs = getCommandBindingAttrsForQuery(binding, context: context)
            bindingsByCommand[name]?.append(createActiveBinding(binding, commandAttrs: attrs))
        }

        return bindingsByCommand
    }

    public func getResolvedCommandChain(
        _ command: String,
        focused: Target?,
        execution: CommandExecutionFields? = nil
    ) -> CommandChainLookup<Target, Event> {
        let view = getActiveCommandView(focused: focused)
        var resolved: [ResolvedCommandEntry<Target, Event>] = []

        if let chain = view.chainsByName[command] {
            for entry in chain {
                resolved.append(
                    ResolvedCommandEntry(
                        target: entry.layer.target,
                        command: entry.commandState.command,
                        attrs: entry.commandState.attrs,
                        input: nil,
                        payload: execution?.payload
                    )
                )
            }
        }

        let fallback = resolveCommandWithResolversForMode(
            command,
            focused: focused,
            mode: .active,
            execution: execution
        )
        if let fallbackEntry = fallback.resolved {
            resolved.append(fallbackEntry)
        }

        return CommandChainLookup(
            entries: resolved.isEmpty ? nil : resolved,
            hadError: fallback.hadError
        )
    }

    public func getRegisteredResolvedEntries(_ command: String) -> [ResolvedCommandEntry<Target, Event>]? {
        if registeredResolvedCacheVersion != notify.derivedVersion {
            registeredResolvedCacheVersion = notify.derivedVersion
            registeredResolvedCache.removeAll(keepingCapacity: true)
        }

        if let cached = registeredResolvedCache[command] {
            return cached
        }

        let resolved = resolveRegisteredEntries(getRegisteredCommandChain(command))
        registeredResolvedCache[command] = resolved
        return resolved
    }

    public func getActiveRegisteredResolvedEntries(
        _ command: String,
        focused: Target?
    ) -> [ResolvedCommandEntry<Target, Event>]? {
        resolveRegisteredEntries(getActiveCommandView(focused: focused).chainsByName[command])
    }

    public func resolveRegisteredResolverFallback(
        _ command: String,
        execution: CommandExecutionFields? = nil
    ) -> ResolvedCommandLookup<Target, Event> {
        resolveCommandWithResolversForMode(command, focused: nil, mode: .registered, execution: execution)
    }

    public func resolveActiveResolverFallback(
        _ command: String,
        focused: Target?,
        execution: CommandExecutionFields? = nil
    ) -> ResolvedCommandLookup<Target, Event> {
        resolveCommandWithResolversForMode(command, focused: focused, mode: .active, execution: execution)
    }

    public func getTopCommand(_ command: String, focused: Target?) -> Command<Target, Event>? {
        getTopResolvedCommand(command, focused: focused)?.command
    }

    public func getDispatchUnavailableCommandState(
        _ command: String,
        focused: Target?,
        includeCommand: Bool
    ) -> UnavailableCommandState<Target, Event>? {
        let view = getCommandView()
        guard let chain = view.chainsByName[command], !chain.isEmpty else {
            return nil
        }

        var inactiveEntry: LayerCommandEntry<Target, Event>?
        var disabledEntry: LayerCommandEntry<Target, Event>?

        for entry in chain {
            if !isLayerActiveForFocused(host: host, layer: entry.layer, focused: focused) {
                if inactiveEntry == nil {
                    inactiveEntry = entry
                }
                continue
            }

            if !conditions.matchesConditions(entry.layer) || !conditions.matchesConditions(entry.commandState) {
                if disabledEntry == nil {
                    disabledEntry = entry
                }
            }
        }

        guard let unavailableEntry = disabledEntry ?? inactiveEntry else {
            return nil
        }

        return UnavailableCommandState(
            reason: disabledEntry != nil ? .disabled : .inactive,
            command: includeCommand ? unavailableEntry.commandState.command : nil
        )
    }

    public func getActiveCommandView(focused: Target?) -> ActiveCommandView<Target, Event> {
        if activeViewVersion == notify.derivedVersion
            && activeViewHasFocused
            && activeViewFocused == focused,
            let activeView
        {
            return activeView
        }

        let view = OpenTUIKeymap.getActiveCommandView(
            state: state,
            host: host,
            conditions: conditions,
            focused: focused
        )
        if state.activeCommandViewCacheBlockers == 0 {
            activeViewVersion = notify.derivedVersion
            activeViewHasFocused = true
            activeViewFocused = focused
            activeView = view
        }
        return view
    }

    public func isBindingVisible(
        _ binding: BindingState<Target, Event>,
        focused: Target?,
        activeView: ActiveCommandView<Target, Event>
    ) -> Bool {
        if binding.command == nil || binding.run != nil {
            return true
        }
        guard let commandName = binding.command?.commandName else {
            return false
        }
        if activeView.reachableByName[commandName] != nil {
            return true
        }
        return resolveCommandWithResolversForMode(commandName, focused: focused, mode: .active).resolved != nil
    }

    public func getBindingCommandAttrs(
        _ binding: BindingState<Target, Event>,
        focused: Target?,
        activeView: ActiveCommandView<Target, Event>
    ) -> Attributes? {
        guard let commandName = binding.command?.commandName else {
            return nil
        }
        if let active = activeView.reachableByName[commandName] {
            return active.commandState.attrs
        }
        return resolveCommandWithResolversForMode(commandName, focused: focused, mode: .active).resolved?.attrs
    }

    public func getCommandResolutionStatus(
        _ command: String,
        layerCommands: [CommandState<Target, Event>]? = nil
    ) -> CommandResolutionStatus {
        if layerCommands?.contains(where: { $0.command.name == command }) == true
            || getCommandView().chainsByName[command] != nil
        {
            return .resolved
        }

        let lookup = resolveCommandWithResolversForMode(
            command,
            focused: getFocusedTargetIfAvailable(host),
            mode: .active
        )
        if lookup.resolved != nil {
            return .resolved
        }
        if lookup.hadError {
            return .error
        }
        return .unresolved
    }

    // MARK: - Internal Helpers

    private func mutateCommandResolvers(
        _ register: () -> (@Sendable () -> Void)
    ) -> @Sendable () -> Void {
        notify.runWithStateChangeBatch {
            let off = register()
            options.onCommandResolversChanged()
            notify.queueStateChange()

            return { [weak self] in
                guard let self else { return }
                self.notify.runWithStateChangeBatch {
                    let countBefore = self.commandResolvers.count
                    off()
                    if self.commandResolvers.count == countBefore {
                        return
                    }
                    self.options.onCommandResolversChanged()
                    self.notify.queueStateChange()
                }
            }
        }
    }

    private func getCommandView() -> CommandView<Target, Event> {
        if registeredViewVersion == notify.derivedVersion, let registeredView {
            return registeredView
        }
        let view = getRegisteredCommandView(state)
        registeredViewVersion = notify.derivedVersion
        registeredView = view
        return view
    }

    private func getRegisteredCommandChain(_ command: String) -> [LayerCommandEntry<Target, Event>]? {
        var entries: [LayerCommandEntry<Target, Event>] = []
        for layer in state.sortedLayers {
            for commandState in layer.commands where commandState.command.name == command {
                entries.append(LayerCommandEntry(layer: layer, commandState: commandState))
            }
        }
        return entries.isEmpty ? nil : entries
    }

    private func resolveRegisteredEntries(
        _ chain: [LayerCommandEntry<Target, Event>]?
    ) -> [ResolvedCommandEntry<Target, Event>]? {
        guard let chain, !chain.isEmpty else {
            return nil
        }
        return chain.map { entry in
            ResolvedCommandEntry(
                target: entry.layer.target,
                command: entry.commandState.command,
                attrs: entry.commandState.attrs
            )
        }
    }

    private func getCommandEntry(_ command: String) -> LayerCommandEntry<Target, Event>? {
        getRegisteredCommandChain(command)?.first
    }

    private func getTopResolvedCommand(
        _ command: String,
        focused: Target?
    ) -> ResolvedCommandEntry<Target, Event>? {
        let view = getActiveCommandView(focused: focused)
        if let active = view.reachableByName[command] {
            return ResolvedCommandEntry(
                target: active.layer.target,
                command: active.commandState.command,
                attrs: active.commandState.attrs
            )
        }
        return resolveCommandWithResolversForMode(command, focused: focused, mode: .active).resolved
    }

    private func getRegisteredBindingsByCommand() -> [String: [BindingState<Target, Event>]] {
        if registeredBindingsByCommandVersion == notify.derivedVersion,
            let cached = registeredBindingsByCommand
        {
            return cached
        }

        var map: [String: [BindingState<Target, Event>]] = [:]
        for layer in state.layers {
            for binding in layer.bindings {
                guard let name = binding.command?.commandName else { continue }
                map[name, default: []].append(binding)
            }
        }

        registeredBindingsByCommandVersion = notify.derivedVersion
        registeredBindingsByCommand = map
        return map
    }

    private struct QueryContext {
        let visibility: CommandVisibility
        let focused: Target?
        let activeView: ActiveCommandView<Target, Event>?
    }

    private func getCommandQueryContext(_ query: CommandQuery<Target, Event>?) -> QueryContext {
        getCommandQueryContext(
            visibility: query?.visibility ?? .reachable,
            focusedOverride: query?.focused
        )
    }

    private func getCommandQueryContext(
        visibility: CommandVisibility,
        focusedOverride: Target??
    ) -> QueryContext {
        let focused: Target?
        if let explicit = focusedOverride {
            focused = explicit
        } else {
            focused = getFocusedTargetIfAvailable(host)
        }

        if visibility == .registered {
            return QueryContext(visibility: visibility, focused: focused, activeView: nil)
        }

        return QueryContext(
            visibility: visibility,
            focused: focused,
            activeView: getActiveCommandView(focused: focused)
        )
    }

    private func getFilteredCommandEntries(
        query: CommandQuery<Target, Event>?,
        context: QueryContext? = nil
    ) -> [LayerCommandEntry<Target, Event>] {
        let resolvedContext = context ?? getCommandQueryContext(query)
        let sourceEntries: [LayerCommandEntry<Target, Event>]
        switch resolvedContext.visibility {
        case .registered:
            sourceEntries = getCommandView().entries
        case .active:
            sourceEntries = resolvedContext.activeView?.entries ?? []
        case .reachable:
            sourceEntries = resolvedContext.activeView?.reachable ?? []
        }

        if let limit = query?.limit, limit <= 0 {
            return []
        }

        let normalizedSearch = query?.search.map { keymapTrimWhitespace($0).lowercased() } ?? ""
        let searchKeys: [String]
        if let provided = query?.searchIn, !provided.isEmpty {
            searchKeys = provided
        } else {
            searchKeys = Self.defaultSearchFields
        }

        var filterEntries: [(String, CommandQueryValue<Target, Event>)] = []
        var filterPredicate: (@Sendable (Command<Target, Event>) throws -> Bool)?
        var exactNameFilter: Set<String>?

        if let filter = query?.filter {
            switch filter {
            case .predicate(let fn):
                filterPredicate = fn
            case .fields(let dict):
                for (key, matcher) in dict {
                    if key == "name" {
                        switch matcher {
                        case .exact(.string(let name)):
                            exactNameFilter = [name]
                            continue
                        case .anyOf(let values):
                            var names: Set<String> = []
                            for value in values {
                                if case .string(let s) = value {
                                    names.insert(s)
                                }
                            }
                            exactNameFilter = names
                            continue
                        default:
                            break
                        }
                    }
                    filterEntries.append((key, matcher))
                }
            }
        }

        var results: [LayerCommandEntry<Target, Event>] = []
        for entry in sourceEntries {
            let commandState = entry.commandState

            if !commandMatchesNamespace(commandState, namespace: query?.namespace) {
                continue
            }

            if !commandMatchesSearch(commandState, search: normalizedSearch, searchKeys: searchKeys) {
                continue
            }

            if let exactNameFilter, !exactNameFilter.contains(commandState.command.name) {
                continue
            }

            if !commandMatchesFilters(commandState, filters: filterEntries) {
                continue
            }

            if let filterPredicate {
                let matches: Bool
                do {
                    matches = try filterPredicate(getCommand(commandState))
                } catch {
                    notify.emitError(
                        "command-query-filter-error",
                        error: error,
                        message: "[Keymap] Error in command query filter:"
                    )
                    continue
                }
                if !matches {
                    continue
                }
            }

            results.append(entry)
            if let limit = query?.limit, results.count >= limit {
                break
            }
        }

        return results
    }

    private func visitCommandQueryBindings(
        context: QueryContext,
        visit: (BindingState<Target, Event>) -> Void
    ) {
        if context.visibility == .registered {
            for layer in state.layers {
                for binding in layer.bindings {
                    visit(binding)
                }
            }
            return
        }

        guard let activeView = context.activeView else {
            return
        }

        for layer in activeView.layers {
            if layer.bindings.isEmpty || !conditions.matchesConditions(layer) {
                continue
            }
            for binding in layer.bindings {
                if conditions.matchesConditions(binding)
                    && isBindingVisible(binding, focused: context.focused, activeView: activeView)
                {
                    visit(binding)
                }
            }
        }
    }

    private func createActiveBinding(
        _ binding: BindingState<Target, Event>,
        commandAttrs: Attributes?
    ) -> ActiveBinding<Target, Event> {
        ActiveBinding(
            sequence: binding.sequence,
            command: binding.command,
            commandAttrs: commandAttrs,
            attrs: binding.attrs,
            event: binding.event,
            preventDefault: binding.preventDefault,
            fallthrough: binding.fallthrough
        )
    }

    private func getCommandBindingAttrsForQuery(
        _ binding: BindingState<Target, Event>,
        context: QueryContext
    ) -> Attributes? {
        guard let name = binding.command?.commandName else {
            return nil
        }
        if context.visibility == .registered {
            return getCommandView().chainsByName[name]?.first?.commandState.attrs
        }
        guard let activeView = context.activeView else {
            return nil
        }
        return getBindingCommandAttrs(binding, focused: context.focused, activeView: activeView)
    }

    private func resolveCommandWithResolversForMode(
        _ command: String,
        focused: Target?,
        mode: CommandResolutionMode,
        execution: CommandExecutionFields? = nil
    ) -> ResolvedCommandLookup<Target, Event> {
        let resolvers = commandResolvers.values()
        if resolvers.isEmpty {
            return ResolvedCommandLookup(resolved: nil, hadError: false)
        }

        let exec = execution ?? CommandExecutionFields(input: command, payload: nil)
        var hadError = false

        for resolver in resolvers {
            let ctx = CommandResolverContext<Target, Event>(
                input: exec.input,
                payload: exec.payload,
                getCommand: { [weak self] name in
                    guard let self else { return nil }
                    switch mode {
                    case .registered:
                        return self.getCommandEntry(name)?.commandState.command
                    case .active:
                        return self.getTopCommand(name, focused: focused)
                    }
                }
            )

            let resolvedCommand: Command<Target, Event>?
            do {
                resolvedCommand = try resolver(command, ctx)
            } catch {
                hadError = true
                notify.emitError(
                    "command-resolver-error",
                    error: error,
                    message: "[Keymap] Error in command resolver for \"\(command)\":"
                )
                continue
            }

            guard let resolvedCommand else {
                continue
            }

            let fields = ctx.executionFields
            let matchedEntry = getCommandEntryForMode(resolvedCommand.name, focused: focused, mode: mode)
            let resolvedTarget: Target? = matchedEntry?.layer.target
            let resolvedAttrs =
                getCommandStateAttrs(resolvedCommand.name, focused: focused, mode: mode)
                ?? extractResolverCommandAttrs(resolvedCommand)

            return ResolvedCommandLookup(
                resolved: ResolvedCommandEntry(
                    target: resolvedTarget,
                    command: resolvedCommand,
                    attrs: resolvedAttrs,
                    input: fields.input,
                    payload: fields.payload
                ),
                hadError: hadError
            )
        }

        return ResolvedCommandLookup(resolved: nil, hadError: hadError)
    }

    private func getCommandEntryForMode(
        _ command: String,
        focused: Target?,
        mode: CommandResolutionMode
    ) -> LayerCommandEntry<Target, Event>? {
        switch mode {
        case .registered:
            return getCommandEntry(command)
        case .active:
            return getActiveCommandView(focused: focused).reachableByName[command]
        }
    }

    private func getCommandStateAttrs(
        _ command: String,
        focused: Target?,
        mode: CommandResolutionMode
    ) -> Attributes? {
        getCommandEntryForMode(command, focused: focused, mode: mode)?.commandState.attrs
    }

    private func commandMatchesNamespace(
        _ commandState: CommandState<Target, Event>,
        namespace: [String]?
    ) -> Bool {
        guard let namespace else {
            return true
        }
        guard let value = commandState.fields["namespace"] else {
            return false
        }
        let expected = namespace.map { KeymapValue.string($0) }
        return valueMatchesAny(value, expected: expected)
    }

    private func commandMatchesSearch(
        _ commandState: CommandState<Target, Event>,
        search: String,
        searchKeys: [String]
    ) -> Bool {
        if search.isEmpty {
            return true
        }
        for key in searchKeys {
            if let text = getCommandSearchText(commandState, key: key), text.contains(search) {
                return true
            }
        }
        return false
    }

    private func getCommandSearchText(_ commandState: CommandState<Target, Event>, key: String) -> String? {
        let id = ObjectIdentifier(commandState)
        if let cached = searchCache[id], cached.keys.contains(key) {
            return cached[key] ?? nil
        }

        let value: KeymapValue?
        if key == "name" {
            value = .string(commandState.command.name)
        } else if let fieldValue = commandState.fields[key] {
            value = fieldValue
        } else if let attrValue = commandState.attrs?[key] {
            value = attrValue
        } else {
            value = nil
        }

        let text = value.flatMap(toSearchText)
        searchCache[id, default: [:]][key] = text
        return text
    }

    private func commandMatchesFilters(
        _ commandState: CommandState<Target, Event>,
        filters: [(String, CommandQueryValue<Target, Event>)]
    ) -> Bool {
        for (key, matcher) in filters {
            if !commandKeyMatchesQuery(commandState, key: key, matcher: matcher) {
                return false
            }
        }
        return true
    }

    private func commandKeyMatchesQuery(
        _ commandState: CommandState<Target, Event>,
        key: String,
        matcher: CommandQueryValue<Target, Event>
    ) -> Bool {
        switch matcher {
        case .predicate(let fn):
            let command = getCommand(commandState)
            var foundValue = false

            if key == "name" {
                foundValue = true
                if runQueryPredicate(fn, value: .string(command.name), command: command) {
                    return true
                }
            }
            if let fieldValue = commandState.fields[key] {
                foundValue = true
                if runQueryPredicate(fn, value: fieldValue, command: command) {
                    return true
                }
            }
            if let attrValue = commandState.attrs?[key] {
                foundValue = true
                if runQueryPredicate(fn, value: attrValue, command: command) {
                    return true
                }
            }
            return !foundValue && runQueryPredicate(fn, value: .undefined, command: command)

        case .exact(let expected):
            return commandKeyMatchesExact(commandState, key: key, expected: [expected])

        case .anyOf(let expectedList):
            return commandKeyMatchesExact(commandState, key: key, expected: expectedList)
        }
    }

    private func runQueryPredicate(
        _ predicate: @Sendable (KeymapValue, Command<Target, Event>) throws -> Bool,
        value: KeymapValue,
        command: Command<Target, Event>
    ) -> Bool {
        do {
            return try predicate(value, command)
        } catch {
            notify.emitError(
                "command-query-filter-error",
                error: error,
                message: "[Keymap] Error in command query filter:"
            )
            return false
        }
    }

    private func commandKeyMatchesExact(
        _ commandState: CommandState<Target, Event>,
        key: String,
        expected: [KeymapValue]
    ) -> Bool {
        if key == "name", valueMatchesAny(.string(commandState.command.name), expected: expected) {
            return true
        }
        if let fieldValue = commandState.fields[key], valueMatchesAny(fieldValue, expected: expected) {
            return true
        }
        if let attrValue = commandState.attrs?[key], valueMatchesAny(attrValue, expected: expected) {
            return true
        }
        return false
    }
}

private func extractCommandFields<Target: Hashable & Sendable, Event: KeymapEvent>(
    _ command: Command<Target, Event>
) -> [String: KeymapValue] {
    var result: [String: KeymapValue] = [:]
    for (name, value) in command.fields {
        if !RESERVED_COMMAND_FIELDS.contains(name) && value != .undefined {
            result[name] = value
        }
    }
    return result
}

private func extractResolverCommandAttrs<Target: Hashable & Sendable, Event: KeymapEvent>(
    _ command: Command<Target, Event>
) -> Attributes? {
    let fields = extractCommandFields(command)
    return fields.isEmpty ? nil : fields
}

private func toSearchText(_ value: KeymapValue) -> String? {
    switch value {
    case .array(let items):
        var parts: [String] = []
        for entry in items {
            if let text = toSearchText(entry) {
                parts.append(text)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\0")
    case .string(let s):
        return s.lowercased()
    case .int(let i):
        return String(i)
    case .double(let d):
        return KeymapValue.double(d).stringDescription.lowercased()
    case .bool(let b):
        return b ? "true" : "false"
    case .undefined, .null, .object:
        return nil
    }
}

private func valueMatchesAny(_ value: KeymapValue, expected: [KeymapValue]) -> Bool {
    for candidate in expected {
        if valueMatchesExact(value, expected: candidate) {
            return true
        }
    }
    return false
}

private func valueMatchesExact(_ value: KeymapValue, expected: KeymapValue) -> Bool {
    if case .array(let items) = value {
        return items.contains { valueMatchesExact($0, expected: expected) }
    }
    return objectIs(value, expected)
}

// parity: keymap/src/services/command-catalog.ts#createCommandCatalogService [status=implemented hash=db1d0bd885d8]
public func createCommandCatalogService<Host: KeymapHost>(
    state: LayerStackState<Host.Target, Host.Event>,
    host: Host,
    notify: KeymapNotifier,
    conditions: any ConditionService,
    options: CommandCatalogOptions = CommandCatalogOptions()
) -> DefaultCommandCatalogService<Host> {
    DefaultCommandCatalogService(
        state: state,
        host: host,
        notify: notify,
        conditions: conditions,
        options: options
    )
}
