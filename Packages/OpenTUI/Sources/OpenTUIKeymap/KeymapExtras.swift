// Pure Swift 6 port of keymap/src/extras/binding-lookup.ts, command-bindings.ts,
// formatting.ts, graph.ts, lib/graph-types.ts, and lib/graph-snapshot.ts.

// MARK: - Binding Lookup (extras/binding-lookup.ts)

public enum BindingLookupError: Error, Equatable, Sendable, KeymapDescribedError {
    case emptyCommand
    case emptyMappedCommand(String)
    case invalidBindingValue(String)

    public var errorMessage: String {
        switch self {
        case .emptyCommand:
            return "Invalid binding command: command cannot be empty"
        case .emptyMappedCommand(let cmd):
            return "Invalid binding command map entry for \"\(cmd)\": command cannot be empty"
        case .invalidBindingValue(let msg):
            return msg
        }
    }
}

// parity: keymap/src/extras/binding-lookup.ts#BindingConfigItem [status=implemented hash=92d1e31d1f3a]
public enum BindingConfigItem<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable,
    ExpressibleByStringLiteral
{
    case key(KeyLike)
    case binding(Binding<Target, Event>)

    public init(stringLiteral value: String) {
        self = .key(.string(value))
    }

    public static func stroke(_ stroke: KeyStrokeInput) -> Self {
        .key(.stroke(stroke))
    }
}

// parity: keymap/src/extras/binding-lookup.ts#BindingValue [status=implemented hash=04864009d396]
public enum BindingValue<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable,
    ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral
{
    case disabled
    case item(BindingConfigItem<Target, Event>)
    case items([BindingConfigItem<Target, Event>])

    public init(stringLiteral value: String) {
        if value == "none" {
            self = .disabled
        } else {
            self = .item(.key(.string(value)))
        }
    }

    public init(booleanLiteral value: Bool) {
        // Upstream only treats `false` as disabled; `true` is rejected during normalization.
        self = value ? .items([]) : .disabled
    }

    public init(arrayLiteral elements: BindingConfigItem<Target, Event>...) {
        self = .items(elements)
    }

    public static var none: Self { .disabled }
}

// parity: keymap/src/extras/binding-lookup.ts#BindingConfig [status=implemented hash=1f6eccf582af]
public typealias BindingConfig<Target: Hashable & Sendable, Event: KeymapEvent> =
    [String: BindingValue<Target, Event>]

// parity: keymap/src/extras/binding-lookup.ts#BindingCommandMap [status=implemented hash=a701d18018b9]
public typealias BindingCommandMap = [String: String]

// parity: keymap/src/extras/binding-lookup.ts#BindingDefaultsContext [status=implemented hash=422c2926b86a]
public struct BindingDefaultsContext<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public let command: String
    public let binding: Binding<Target, Event>

    public init(command: String, binding: Binding<Target, Event>) {
        self.command = command
        self.binding = binding
    }
}

// parity: keymap/src/extras/binding-lookup.ts#BindingDefaults [status=implemented hash=d69008f50766]
public typealias BindingDefaults<Target: Hashable & Sendable, Event: KeymapEvent> =
    @Sendable (BindingDefaultsContext<Target, Event>) -> [String: KeymapValue]?

// parity: keymap/src/extras/binding-lookup.ts#CreateBindingLookupOptions [status=implemented hash=50d227eacb89]
public struct CreateBindingLookupOptions<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public let commandMap: BindingCommandMap?
    public let bindingDefaults: BindingDefaults<Target, Event>?

    public init(
        commandMap: BindingCommandMap? = nil,
        bindingDefaults: BindingDefaults<Target, Event>? = nil
    ) {
        self.commandMap = commandMap
        self.bindingDefaults = bindingDefaults
    }
}

// parity: keymap/src/extras/binding-lookup.ts#BindingLookup [status=implemented hash=13e49b2d2f63]
public protocol BindingLookup<Target, Event>: AnyObject, Sendable {
    associatedtype Target: Hashable & Sendable
    associatedtype Event: KeymapEvent

    var bindings: [Binding<Target, Event>] { get }
    func get(_ command: String) -> [Binding<Target, Event>]
    func has(_ command: String) -> Bool
    func gather(_ name: String, commands: [String]) -> [Binding<Target, Event>]
    func pick(_ name: String, commands: [String]) -> [Binding<Target, Event>]
    func omit(_ name: String, commands: [String]) -> [Binding<Target, Event>]
    func invalidate(_ name: String?)
    func update(_ config: BindingConfig<Target, Event>?) throws
}

public extension BindingLookup {
    func invalidate() {
        invalidate(nil)
    }

    func update() throws {
        try update(nil)
    }
}

public final class DefaultBindingLookup<Target: Hashable & Sendable, Event: KeymapEvent>: BindingLookup,
    @unchecked Sendable
{
    private struct GatheredGroup: Sendable {
        let bindings: [Binding<Target, Event>]
        let byCommand: [String: [Binding<Target, Event>]]
    }

    private var currentConfig: BindingConfig<Target, Event>
    private let options: CreateBindingLookupOptions<Target, Event>?
    private var orderedBindings: [Binding<Target, Event>] = []
    private var byCommand: [String: [Binding<Target, Event>]] = [:]
    private var gathered: [String: GatheredGroup] = [:]

    public init(
        config: BindingConfig<Target, Event>,
        options: CreateBindingLookupOptions<Target, Event>? = nil
    ) throws {
        self.currentConfig = config
        self.options = options
        try rebuild(config)
    }

    public var bindings: [Binding<Target, Event>] {
        orderedBindings
    }

    public func get(_ command: String) -> [Binding<Target, Event>] {
        byCommand[command] ?? []
    }

    public func has(_ command: String) -> Bool {
        byCommand[command] != nil
    }

    public func gather(_ name: String, commands: [String]) -> [Binding<Target, Event>] {
        if let existing = gathered[name] {
            return existing.bindings
        }
        var groupByCommand: [String: [Binding<Target, Event>]] = [:]
        var groupBindings: [Binding<Target, Event>] = []
        for command in commands {
            guard let commandBindings = byCommand[command] else { continue }
            groupByCommand[command] = commandBindings
            groupBindings.append(contentsOf: commandBindings)
        }
        let next = GatheredGroup(bindings: groupBindings, byCommand: groupByCommand)
        gathered[name] = next
        return next.bindings
    }

    public func pick(_ name: String, commands: [String]) -> [Binding<Target, Event>] {
        guard let group = gathered[name] else { return [] }
        var result: [Binding<Target, Event>] = []
        for command in commands {
            if let found = group.byCommand[command] {
                result.append(contentsOf: found)
            }
        }
        return result
    }

    public func omit(_ name: String, commands: [String]) -> [Binding<Target, Event>] {
        guard let group = gathered[name] else { return [] }
        if commands.isEmpty {
            return group.bindings
        }
        let omitted = Set(commands)
        return group.bindings.filter { binding in
            guard let cmdName = binding.cmd?.commandName else { return true }
            return !omitted.contains(cmdName)
        }
    }

    public func invalidate(_ name: String? = nil) {
        if let name {
            gathered.removeValue(forKey: name)
        } else {
            gathered.removeAll()
        }
    }

    public func update(_ config: BindingConfig<Target, Event>? = nil) throws {
        if let config {
            currentConfig = config
        }
        try rebuild(currentConfig)
        gathered.removeAll()
    }

    private func rebuild(_ config: BindingConfig<Target, Event>) throws {
        var nextByCommand: [String: [Binding<Target, Event>]] = [:]
        var commandOrder: [String] = []

        for rawCommand in config.keys.sorted() {
            let mapped = try mapCommand(rawCommand)
            guard let value = config[rawCommand] else { continue }
            if let resolved = resolveBindingValue(command: mapped, value: value) {
                if nextByCommand[mapped] == nil {
                    commandOrder.append(mapped)
                }
                nextByCommand[mapped] = resolved
            } else {
                nextByCommand.removeValue(forKey: mapped)
                commandOrder.removeAll { $0 == mapped }
            }
        }

        var flattened: [Binding<Target, Event>] = []
        for cmd in commandOrder {
            if let entries = nextByCommand[cmd] {
                flattened.append(contentsOf: entries)
            }
        }

        self.byCommand = nextByCommand
        self.orderedBindings = flattened
    }

    private func mapCommand(_ raw: String) throws(BindingLookupError) -> String {
        if raw.isEmpty {
            throw .emptyCommand
        }
        guard let commandMap = options?.commandMap, let mapped = commandMap[raw] else {
            return raw
        }
        if mapped.isEmpty {
            throw .emptyMappedCommand(raw)
        }
        return mapped
    }

    private func resolveBindingItem(
        command: String,
        item: BindingConfigItem<Target, Event>
    ) -> Binding<Target, Event> {
        let base: Binding<Target, Event>
        switch item {
        case .key(let key):
            base = Binding(key: key, commandName: command)
        case .binding(var binding):
            binding.cmd = .named(command)
            base = binding
        }
        guard let bindingDefaults = options?.bindingDefaults,
            let defaults = bindingDefaults(BindingDefaultsContext(command: command, binding: base)),
            !defaults.isEmpty
        else {
            return base
        }
        var merged = base
        var nextFields = defaults
        for (k, v) in base.fields {
            nextFields[k] = v
        }
        merged.fields = nextFields
        return merged
    }

    private func resolveBindingValue(
        command: String,
        value: BindingValue<Target, Event>
    ) -> [Binding<Target, Event>]? {
        switch value {
        case .disabled:
            return nil
        case .item(let item):
            return [resolveBindingItem(command: command, item: item)]
        case .items(let items):
            if items.isEmpty {
                return nil
            }
            return items.map { resolveBindingItem(command: command, item: $0) }
        }
    }
}

// parity: keymap/src/extras/binding-lookup.ts#createBindingLookup [status=implemented hash=d57474438f00]
public func createBindingLookup<Target: Hashable & Sendable, Event: KeymapEvent>(
    _ config: BindingConfig<Target, Event>,
    options: CreateBindingLookupOptions<Target, Event>? = nil
) throws -> DefaultBindingLookup<Target, Event> {
    try DefaultBindingLookup(config: config, options: options)
}

// MARK: - Command Bindings Helper (extras/command-bindings.ts)

// parity: keymap/src/extras/command-bindings.ts#CommandBindingMap [status=implemented hash=54054e962150]
public typealias CommandBindingMap = [String: KeyLike]

// parity: keymap/src/extras/command-bindings.ts#CommandBindingsOverrideWarning [status=implemented hash=7d947f43fbe1]
public struct CommandBindingsOverrideWarning: Equatable, Sendable {
    public let code: String
    public let command: String
    public let previousKey: KeyLike
    public let nextKey: KeyLike

    public init(command: String, previousKey: KeyLike, nextKey: KeyLike) {
        self.code = "command-binding-override"
        self.command = command
        self.previousKey = previousKey
        self.nextKey = nextKey
    }
}

// parity: keymap/src/extras/command-bindings.ts#CommandBindingsError [status=implemented hash=16004a1cd582]
public struct CommandBindingsError: Sendable {
    public let code: String
    public let command: String
    public let value: KeymapValue?
    public let reason: any Error

    public init(command: String, value: KeymapValue? = nil, reason: any Error) {
        self.code = "invalid-command-binding"
        self.command = command
        self.value = value
        self.reason = reason
    }
}

// parity: keymap/src/extras/command-bindings.ts#CommandBindingsOptions [status=implemented hash=37bf0ac6d7bb]
public struct CommandBindingsOptions: Sendable {
    public let onWarning: (@Sendable (CommandBindingsOverrideWarning) -> Void)?
    public let onError: (@Sendable (CommandBindingsError) -> Void)?

    public init(
        onWarning: (@Sendable (CommandBindingsOverrideWarning) -> Void)? = nil,
        onError: (@Sendable (CommandBindingsError) -> Void)? = nil
    ) {
        self.onWarning = onWarning
        self.onError = onError
    }
}

/// Converts a command-to-key map (or ordered list of command-key pairs) into normalized `Binding` entries,
/// warning when a trimmed command name overrides an earlier binding.
// parity: keymap/src/extras/command-bindings.ts#commandBindings [status=implemented hash=128c780bc284]
public func commandBindings<Target: Hashable & Sendable, Event: KeymapEvent>(
    _ entries: [(String, KeyLike)],
    options: CommandBindingsOptions? = nil
) -> [Binding<Target, Event>] {
    var normalized: [Binding<Target, Event>] = []
    var indexesByCommand: [String: Int] = [:]

    for (rawCommand, key) in entries {
        if case .stroke(let stroke) = key, keymapTrimWhitespace(stroke.name).isEmpty {
            let err = BindingLookupError.invalidBindingValue(
                "Invalid command binding for \"\(rawCommand)\": command bindings must map command strings to key strings or keystroke objects"
            )
            options?.onError?(CommandBindingsError(command: rawCommand, reason: err))
            continue
        }

        let normalizedCommand = keymapTrimWhitespace(rawCommand)
        let nextBinding = Binding<Target, Event>(key: key, commandName: normalizedCommand)

        if let existingIndex = indexesByCommand[normalizedCommand] {
            let previousBinding = normalized[existingIndex]
            options?.onWarning?(
                CommandBindingsOverrideWarning(
                    command: normalizedCommand,
                    previousKey: previousBinding.key,
                    nextKey: nextBinding.key
                )
            )
            normalized[existingIndex] = nextBinding
            continue
        }

        indexesByCommand[normalizedCommand] = normalized.count
        normalized.append(nextBinding)
    }

    return normalized
}

/// Dictionary convenience overload for `commandBindings`.
public func commandBindings<Target: Hashable & Sendable, Event: KeymapEvent>(
    _ bindings: CommandBindingMap,
    options: CommandBindingsOptions? = nil
) -> [Binding<Target, Event>] {
    let ordered = bindings.keys.sorted().compactMap { key -> (String, KeyLike)? in
        guard let value = bindings[key] else { return nil }
        return (key, value)
    }
    return commandBindings(ordered, options: options)
}

// MARK: - Formatting Extras (extras/formatting.ts)

// parity: keymap/src/extras/formatting.ts#KeyModifierName [status=implemented hash=69d4a1c0ea12]
public enum KeyModifierName: String, Equatable, Hashable, Sendable, CaseIterable {
    case ctrl
    case shift
    case meta
    case `super`
    case hyper
}

// parity: keymap/src/extras/formatting.ts#KeySequenceFormatPart [status=implemented hash=28116868cfe3]
public struct KeySequenceFormatPart: Equatable, Hashable, Sendable {
    public let stroke: NormalizedKeyStroke
    public let display: String
    public let match: KeyMatch?
    public let tokenName: String?
    public let patternName: String?

    public init(
        stroke: NormalizedKeyStroke,
        display: String,
        match: KeyMatch? = nil,
        tokenName: String? = nil,
        patternName: String? = nil
    ) {
        self.stroke = stroke
        self.display = display
        self.match = match
        self.tokenName = tokenName
        self.patternName = patternName
    }

    public init(_ part: KeySequencePart) {
        self.stroke = part.stroke
        self.display = part.display
        self.match = part.match
        self.tokenName = part.tokenName
        self.patternName = part.patternName
    }
}

// parity: keymap/src/extras/formatting.ts#TokenDisplayResolver [status=implemented hash=672767d447b8]
public enum TokenDisplayResolver: Sendable {
    case map([String: String])
    case resolver(@Sendable (String, KeySequenceFormatPart) -> String?)

    public func resolve(_ tokenName: String, part: KeySequenceFormatPart) -> String? {
        switch self {
        case .map(let dict): return dict[tokenName]
        case .resolver(let fn): return fn(tokenName, part)
        }
    }
}

// parity: keymap/src/extras/formatting.ts#PatternDisplayResolver [status=implemented hash=e49386c18e82]
public enum PatternDisplayResolver: Sendable {
    case map([String: String])
    case resolver(@Sendable (String, KeySequenceFormatPart) -> String?)

    public func resolve(_ patternName: String, part: KeySequenceFormatPart) -> String? {
        switch self {
        case .map(let dict): return dict[patternName]
        case .resolver(let fn): return fn(patternName, part)
        }
    }
}

// parity: keymap/src/extras/formatting.ts#FormatKeySequenceOptions [status=implemented hash=bf36223cbe9e]
public struct FormatKeySequenceOptions: Sendable {
    public let tokenDisplay: TokenDisplayResolver?
    public let patternDisplay: PatternDisplayResolver?
    public let keyNameAliases: [String: String]?
    public let modifierAliases: [KeyModifierName: String]?
    public let separator: String
    public let modifierJoiner: String

    public init(
        tokenDisplay: TokenDisplayResolver? = nil,
        patternDisplay: PatternDisplayResolver? = nil,
        keyNameAliases: [String: String]? = nil,
        modifierAliases: [KeyModifierName: String]? = nil,
        separator: String = " ",
        modifierJoiner: String = "+"
    ) {
        self.tokenDisplay = tokenDisplay
        self.patternDisplay = patternDisplay
        self.keyNameAliases = keyNameAliases
        self.modifierAliases = modifierAliases
        self.separator = separator
        self.modifierJoiner = modifierJoiner
    }

    /// macOS symbol formatting preset (`⌃`, `⇧`, `⌥`, `⌘`, `✦`).
    public static let macOSSymbols = FormatKeySequenceOptions(
        keyNameAliases: [
            "enter": "↩",
            "return": "↩",
            "escape": "⎋",
            "tab": "⇥",
            "backspace": "⌫",
            "delete": "⌦",
            "space": "␣",
            "up": "↑",
            "down": "↓",
            "left": "←",
            "right": "→",
        ],
        modifierAliases: [
            .ctrl: "⌃",
            .shift: "⇧",
            .meta: "⌥",
            .super: "⌘",
            .hyper: "✦",
        ],
        separator: " ",
        modifierJoiner: ""
    )

    /// POSIX / cross-platform label preset (`Ctrl`, `Shift`, `Alt`, `Super`, `Hyper`).
    public static let posixLabels = FormatKeySequenceOptions(
        keyNameAliases: [
            "enter": "Enter",
            "escape": "Esc",
            "tab": "Tab",
            "backspace": "Backspace",
            "delete": "Del",
            "space": "Space",
        ],
        modifierAliases: [
            .ctrl: "Ctrl",
            .shift: "Shift",
            .meta: "Alt",
            .super: "Super",
            .hyper: "Hyper",
        ],
        separator: " ",
        modifierJoiner: "+"
    )
}

// parity: keymap/src/extras/formatting.ts#FormatCommandBindingsOptions [status=implemented hash=1e938b14ea3a]
public struct FormatCommandBindingsOptions: Sendable {
    public let keySequenceOptions: FormatKeySequenceOptions
    public let bindingSeparator: String
    public let dedupe: Bool

    public init(
        tokenDisplay: TokenDisplayResolver? = nil,
        patternDisplay: PatternDisplayResolver? = nil,
        keyNameAliases: [String: String]? = nil,
        modifierAliases: [KeyModifierName: String]? = nil,
        separator: String = " ",
        modifierJoiner: String = "+",
        bindingSeparator: String = ", ",
        dedupe: Bool = true
    ) {
        self.keySequenceOptions = FormatKeySequenceOptions(
            tokenDisplay: tokenDisplay,
            patternDisplay: patternDisplay,
            keyNameAliases: keyNameAliases,
            modifierAliases: modifierAliases,
            separator: separator,
            modifierJoiner: modifierJoiner
        )
        self.bindingSeparator = bindingSeparator
        self.dedupe = dedupe
    }

    public init(
        keySequenceOptions: FormatKeySequenceOptions,
        bindingSeparator: String = ", ",
        dedupe: Bool = true
    ) {
        self.keySequenceOptions = keySequenceOptions
        self.bindingSeparator = bindingSeparator
        self.dedupe = dedupe
    }
}

// parity: keymap/src/extras/formatting.ts#SequenceBindingLike [status=implemented hash=a5aba914a35a]
public protocol SequenceBindingLike: Sendable {
    var formatSequence: [KeySequenceFormatPart] { get }
}

extension ActiveBinding: SequenceBindingLike {
    public var formatSequence: [KeySequenceFormatPart] {
        sequence.map(KeySequenceFormatPart.init)
    }
}

extension DispatchBinding: SequenceBindingLike {
    public var formatSequence: [KeySequenceFormatPart] {
        sequence.map(KeySequenceFormatPart.init)
    }
}

extension BindingState: SequenceBindingLike {
    public var formatSequence: [KeySequenceFormatPart] {
        sequence.map(KeySequenceFormatPart.init)
    }
}

private func formatSingleStroke(_ part: KeySequenceFormatPart, options: FormatKeySequenceOptions) -> String {
    if let tokenName = part.tokenName {
        guard let tokenDisplay = options.tokenDisplay else {
            return part.display
        }
        return tokenDisplay.resolve(tokenName, part: part) ?? part.display
    }

    if let patternName = part.patternName {
        guard let patternDisplay = options.patternDisplay else {
            return part.display
        }
        return patternDisplay.resolve(patternName, part: part) ?? part.display
    }

    if options.keyNameAliases == nil && options.modifierAliases == nil {
        return part.display
    }

    let stroke = part.stroke
    let modifierAliases = options.modifierAliases
    let joiner = options.modifierJoiner
    var formatted = ""
    var pieceCount = 0

    func appendPiece(_ text: String) {
        if pieceCount == 0 {
            formatted = text
        } else {
            formatted += joiner + text
        }
        pieceCount += 1
    }

    if stroke.ctrl {
        appendPiece(modifierAliases?[.ctrl] ?? "ctrl")
    }
    if stroke.shift {
        appendPiece(modifierAliases?[.shift] ?? "shift")
    }
    if stroke.meta {
        appendPiece(modifierAliases?[.meta] ?? "meta")
    }
    if stroke.`super` {
        appendPiece(modifierAliases?[.super] ?? "super")
    }
    if stroke.hyper == true {
        appendPiece(modifierAliases?[.hyper] ?? "hyper")
    }

    let normalizedName = stroke.name == "return" ? "enter" : stroke.name
    let keyName = options.keyNameAliases?[normalizedName] ?? normalizedName
    appendPiece(keyName)
    return formatted
}

// parity: keymap/src/extras/formatting.ts#formatKeySequence [status=implemented hash=550b9a88fc1e]
public func formatKeySequence(
    _ parts: [KeySequenceFormatPart]?,
    options: FormatKeySequenceOptions = FormatKeySequenceOptions()
) -> String {
    guard let parts, !parts.isEmpty else {
        return ""
    }
    var formatted = formatSingleStroke(parts[0], options: options)
    for index in 1..<parts.count {
        formatted += options.separator + formatSingleStroke(parts[index], options: options)
    }
    return formatted
}

/// Convenience overload accepting `[KeySequencePart]` directly.
public func formatKeySequence(
    _ parts: [KeySequencePart]?,
    options: FormatKeySequenceOptions = FormatKeySequenceOptions()
) -> String {
    formatKeySequence(parts?.map(KeySequenceFormatPart.init), options: options)
}

// parity: keymap/src/extras/formatting.ts#formatCommandBindings [status=implemented hash=6487df0dabb9]
public func formatCommandBindings<B: SequenceBindingLike>(
    _ bindings: [B]?,
    options: FormatCommandBindingsOptions = FormatCommandBindingsOptions()
) -> String? {
    guard let bindings, !bindings.isEmpty else {
        return nil
    }
    var seen: Set<String>? = options.dedupe ? [] : nil
    var formatted = ""
    var itemCount = 0

    for binding in bindings {
        let item = formatKeySequence(binding.formatSequence, options: options.keySequenceOptions)
        if item.isEmpty { continue }
        if seen != nil {
            if seen!.contains(item) { continue }
            seen!.insert(item)
        }
        if itemCount == 0 {
            formatted = item
        } else {
            formatted += options.bindingSeparator + item
        }
        itemCount += 1
    }

    return formatted
}

// MARK: - Graph Snapshot Types (extras/lib/graph-types.ts)

// parity: keymap/src/extras/lib/graph-types.ts#GraphSnapshotOptions [status=implemented hash=30e8293269db]
public struct GraphSnapshotOptions<Target: Hashable & Sendable>: Sendable {
    /// `.none` uses the host's live focused target; `.some(nil)` queries unfocused; `.some(t)` queries `t`.
    public let focused: Target??
    public let includeTargets: Bool

    public init(focused: Target?? = nil, includeTargets: Bool = true) {
        self.focused = focused
        self.includeTargets = includeTargets
    }
}

// parity: keymap/src/extras/lib/graph-types.ts#GraphInactiveReason [status=implemented hash=4b6fb1b5064b]
public enum GraphInactiveReason: String, Equatable, Hashable, Sendable, Codable {
    case focus
    case targetDestroyed = "target-destroyed"
    case layerDisabled = "layer-disabled"
    case bindingDisabled = "binding-disabled"
    case commandDisabled = "command-disabled"
    case commandInactive = "command-inactive"
    case commandUnresolved = "command-unresolved"
    case shadowed
}

// parity: keymap/src/extras/lib/graph-types.ts#GraphLayer [status=implemented hash=169a5d172783]
public struct GraphLayer<Target: Hashable & Sendable>: Sendable {
    public let id: String
    public let order: Int
    public let priority: Int
    public let target: Target?
    public let targetMode: TargetMode?
    public let fields: [String: KeymapValue]
    public let attrs: Attributes?
    public let active: Bool
    public let focusActive: Bool
    public let enabled: Bool
    public let inactiveReasons: [GraphInactiveReason]
    public let rootNodeId: String
    public let bindingIds: [String]
    public let commandIds: [String]
}

// parity: keymap/src/extras/lib/graph-types.ts#GraphCommand [status=implemented hash=26c0f445b504]
public struct GraphCommand<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public let id: String
    public let layerId: String
    public let name: String
    public let command: Command<Target, Event>
    public let fields: [String: KeymapValue]
    public let attrs: Attributes?
    public let target: Target?
    public let active: Bool
    public let reachable: Bool
    public let enabled: Bool
    public let inactiveReasons: [GraphInactiveReason]
}

// parity: keymap/src/extras/lib/graph-types.ts#GraphBinding [status=implemented hash=87cb286c74b7]
public struct GraphBinding<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public let id: String
    public let layerId: String
    public let sourceLayerOrder: Int
    public let bindingIndex: Int
    public let nodeId: String?
    public let commandIds: [String]
    public let sequence: [KeySequencePart]
    public let command: BindingCommand<Target, Event>?
    public let commandAttrs: Attributes?
    public let attrs: Attributes?
    public let event: BindingEvent
    public let preventDefault: Bool
    public let `fallthrough`: Bool
    public let active: Bool
    public let reachable: Bool
    public let enabled: Bool
    public let commandResolved: Bool
    public let shadowed: Bool
    public let inactiveReasons: [GraphInactiveReason]
}

// parity: keymap/src/extras/lib/graph-types.ts#GraphSequenceNode [status=implemented hash=0ce1608f7fb3]
public struct GraphSequenceNode: Equatable, Sendable {
    public let id: String
    public let layerId: String
    public let parentId: String?
    public let childIds: [String]
    public let bindingIds: [String]
    public let reachableBindingIds: [String]
    public let depth: Int
    public let sequence: [KeySequencePart]
    public let stroke: NormalizedKeyStroke?
    public let match: KeyMatch?
    public let display: String
    public let tokenName: String?
    public let active: Bool
    public let reachable: Bool
    public let pending: Bool
    public let pendingPath: Bool
}

// parity: keymap/src/extras/lib/graph-types.ts#GraphSnapshot [status=implemented hash=aad0f6cc505b]
public struct GraphSnapshot<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public let focused: Target?
    public let pendingSequence: [KeySequencePart]
    public let activeKeys: [ActiveKey<Target, Event>]
    public let layers: [GraphLayer<Target>]
    public let commands: [GraphCommand<Target, Event>]
    public let bindings: [GraphBinding<Target, Event>]
    public let sequenceNodes: [GraphSequenceNode]
}

// MARK: - Graph Snapshot Builder (extras/lib/graph-snapshot.ts)

private struct SequenceStopEntry {
    let event: BindingEvent
    let matches: [KeyMatch]
}

private func isMatchPrefix(_ left: [KeyMatch], _ right: [KeyMatch]) -> Bool {
    guard left.count <= right.count else { return false }
    for index in 0..<left.count {
        if left[index] != right[index] {
            return false
        }
    }
    return true
}

private struct GraphLayerMeta<Target: Hashable & Sendable, Event: KeymapEvent> {
    let layer: RegisteredLayer<Target, Event>
    let id: String
    let focusActive: Bool
    let enabled: Bool
    let active: Bool
    let inactiveReasons: [GraphInactiveReason]
}

private struct GraphCommandMeta<Target: Hashable & Sendable, Event: KeymapEvent> {
    let command: CommandState<Target, Event>
    let id: String
    let layerMeta: GraphLayerMeta<Target, Event>
    let active: Bool
    let reachable: Bool
    let enabled: Bool
    let inactiveReasons: [GraphInactiveReason]
}

private struct GraphBindingMeta<Target: Hashable & Sendable, Event: KeymapEvent> {
    let binding: BindingState<Target, Event>
    let id: String
    let layerMeta: GraphLayerMeta<Target, Event>
    var commandIds: [String]
    let enabled: Bool
    let commandResolved: Bool
    let active: Bool
    let reachable: Bool
    let shadowed: Bool
    let inactiveReasons: [GraphInactiveReason]
}

// parity: keymap/src/extras/lib/graph-snapshot.ts#createGraphSnapshot [status=implemented hash=3f848a47b1ae]
public func createGraphSnapshot<Host: KeymapHost>(
    state: LayerStackState<Host.Target, Host.Event>,
    host: Host,
    conditions: any ConditionService,
    catalog: any CommandCatalogService<Host.Target, Host.Event>,
    activation: any ActivationService<Host.Target, Host.Event>,
    snapshotOptions: GraphSnapshotOptions<Host.Target>? = nil
) -> GraphSnapshot<Host.Target, Host.Event> {
    typealias Target = Host.Target
    typealias Event = Host.Event
    typealias LayerMeta = GraphLayerMeta<Target, Event>
    typealias CommandMeta = GraphCommandMeta<Target, Event>
    typealias BindingMeta = GraphBindingMeta<Target, Event>

    let includeTargets = snapshotOptions?.includeTargets ?? true
    let currentFocused = getFocusedTargetIfAvailable(host)
    let focused: Target?
    if let explicitFocused = snapshotOptions?.focused {
        focused = explicitFocused
    } else {
        focused = currentFocused
    }

    let activeView = catalog.getActiveCommandView(focused: focused)
    let activeCommandIDs = Set(activeView.entries.map { ObjectIdentifier($0.commandState) })
    let reachableCommandIDs = Set(activeView.reachable.map { ObjectIdentifier($0.commandState) })
    let activationPath = getActivationPath(host: host, focused: focused)
    let sortedLayers = getSortedLayers(state.layers)

    var layerMetas: [ObjectIdentifier: LayerMeta] = [:]
    var layerIds: [ObjectIdentifier: String] = [:]
    var layerRoots: [ObjectIdentifier: SequenceNode<Target, Event>] = [:]
    var commandMetasByID: [ObjectIdentifier: CommandMeta] = [:]
    var orderedCommandMetas: [CommandMeta] = []
    var commandIdsByName: [String: [String]] = [:]
    var nodeIds: [ObjectIdentifier: String] = [:]
    var bindingNodeIds: [ObjectIdentifier: String] = [:]

    for layer in sortedLayers {
        let key = ObjectIdentifier(layer)
        let id = "layer:\(layer.order)"
        layerRoots[key] = layer.root
        let targetDestroyed = layer.target.map { host.isTargetDestroyed($0) } ?? false
        let focusActive = isLayerActiveForFocused(
            host: host,
            layer: layer,
            focused: focused,
            activationPath: activationPath
        )
        let enabled = conditions.matchesConditions(layer)
        var reasons: [GraphInactiveReason] = []
        if targetDestroyed { reasons.append(.targetDestroyed) }
        if !focusActive { reasons.append(.focus) }
        if !enabled { reasons.append(.layerDisabled) }

        layerIds[key] = id
        layerMetas[key] = LayerMeta(
            layer: layer,
            id: id,
            focusActive: focusActive,
            enabled: enabled,
            active: !targetDestroyed && focusActive && enabled,
            inactiveReasons: reasons
        )
    }

    for layer in sortedLayers {
        let layerKey = ObjectIdentifier(layer)
        let meta = layerMetas[layerKey]!
        for (index, commandState) in layer.commands.enumerated() {
            let cmdId = "command:\(layer.order):\(index)"
            commandIdsByName[commandState.command.name, default: []].append(cmdId)

            let enabled = conditions.matchesConditions(commandState)
            let cmdObjID = ObjectIdentifier(commandState)
            let active = activeCommandIDs.contains(cmdObjID)
            let reachable = reachableCommandIDs.contains(cmdObjID)
            var reasons = meta.inactiveReasons
            if !enabled { reasons.append(.commandDisabled) }
            if active && !reachable { reasons.append(.shadowed) }

            let cmdMeta = CommandMeta(
                command: commandState,
                id: cmdId,
                layerMeta: meta,
                active: active,
                reachable: reachable,
                enabled: enabled,
                inactiveReasons: reasons
            )
            commandMetasByID[cmdObjID] = cmdMeta
            orderedCommandMetas.append(cmdMeta)
        }

        var nextNodeIndex = 0
        func assignNodeIDs(_ node: SequenceNode<Target, Event>) {
            let currentID = "node:\(layer.order):\(nextNodeIndex)"
            nextNodeIndex += 1
            nodeIds[ObjectIdentifier(node)] = currentID
            for binding in node.bindings {
                bindingNodeIds[ObjectIdentifier(binding)] = currentID
            }
            for child in childNodes(node) {
                assignNodeIDs(child)
            }
        }
        assignNodeIDs(layer.root)
    }

    var stoppedSequences: [SequenceStopEntry] = []
    var bindingMetasByID: [ObjectIdentifier: BindingMeta] = [:]
    var orderedBindingMetas: [BindingMeta] = []

    for layer in sortedLayers {
        let meta = layerMetas[ObjectIdentifier(layer)]!
        for (index, binding) in layer.bindings.enumerated() {
            let enabled = conditions.matchesConditions(binding)
            let commandResolved = catalog.isBindingVisible(binding, focused: focused, activeView: activeView)
            let active = meta.active && enabled && commandResolved
            let matches = binding.sequence.map(\.match)
            let shadowed =
                active && stoppedSequences.contains { $0.event == binding.event && isMatchPrefix($0.matches, matches) }

            var reasons = meta.inactiveReasons
            if !enabled { reasons.append(.bindingDisabled) }
            if !commandResolved {
                if let commandName = binding.command?.commandName,
                    let unavailable = catalog.getDispatchUnavailableCommandState(
                        commandName,
                        focused: focused,
                        includeCommand: false
                    )
                {
                    reasons.append(unavailable.reason == .disabled ? .commandDisabled : .commandInactive)
                } else {
                    reasons.append(.commandUnresolved)
                }
            }
            if shadowed { reasons.append(.shadowed) }

            var commandIds: [String] = []
            if let commandName = binding.command?.commandName {
                var idSet: Set<String> = []
                for id in commandIdsByName[commandName] ?? [] where !idSet.contains(id) {
                    idSet.insert(id)
                    commandIds.append(id)
                }
                if let entries = catalog.getResolvedCommandChain(commandName, focused: focused, execution: nil).entries {
                    for entry in entries {
                        for id in commandIdsByName[entry.command.name] ?? [] where !idSet.contains(id) {
                            idSet.insert(id)
                            commandIds.append(id)
                        }
                    }
                }
            }

            let bindingMeta = BindingMeta(
                binding: binding,
                id: "binding:\(layer.order):\(index)",
                layerMeta: meta,
                commandIds: commandIds,
                enabled: enabled,
                commandResolved: commandResolved,
                active: active,
                reachable: active && !shadowed,
                shadowed: shadowed,
                inactiveReasons: reasons
            )
            bindingMetasByID[ObjectIdentifier(binding)] = bindingMeta
            orderedBindingMetas.append(bindingMeta)

            if active && binding.command != nil && !binding.fallthrough {
                stoppedSequences.append(SequenceStopEntry(event: binding.event, matches: matches))
            }
        }
    }

    let pending = (focused == currentFocused) ? activation.ensureValidPendingSequence() : nil
    var pendingNodeIds: Set<String> = []
    var pendingPathNodeIds: Set<String> = []

    if let pending {
        for capture in pending.captures {
            let layerKey = ObjectIdentifier(capture.layer)
            guard let root = layerRoots[layerKey] else { continue }
            var current = getCaptureNode(root: root, capture: capture)
            if let capturedNode = current, let capturedId = nodeIds[ObjectIdentifier(capturedNode)] {
                pendingNodeIds.insert(capturedId)
            }
            while let node = current {
                if let id = nodeIds[ObjectIdentifier(node)] {
                    pendingPathNodeIds.insert(id)
                }
                current = node.parent
            }
        }
    }

    var sequenceNodes: [GraphSequenceNode] = []
    for layer in sortedLayers {
        let currentLayerId = layerIds[ObjectIdentifier(layer)]!
        func collectNodes(_ node: SequenceNode<Target, Event>, parentId: String?) {
            let currentNodeId = nodeIds[ObjectIdentifier(node)]!
            let children = childNodes(node)
            let childIds = children.compactMap { nodeIds[ObjectIdentifier($0)] }
            let bindingIds = node.bindings.compactMap { bindingMetasByID[ObjectIdentifier($0)]?.id }
            let reachableBindingIds = node.reachableBindings.compactMap { bindingMetasByID[ObjectIdentifier($0)]?.id }
            var sequence = getNodeSequence(node)
            let presentation = getNodePresentation(node)
            let active = node.reachableBindings.contains { bindingMetasByID[ObjectIdentifier($0)]?.active == true }
            let reachable = node.reachableBindings.contains { bindingMetasByID[ObjectIdentifier($0)]?.reachable == true }

            if let firstReachable = node.reachableBindings.first {
                for idx in 0..<sequence.count where idx < firstReachable.sequence.count {
                    sequence[idx] = cloneKeySequencePart(firstReachable.sequence[idx])
                }
            }

            sequenceNodes.append(
                GraphSequenceNode(
                    id: currentNodeId,
                    layerId: currentLayerId,
                    parentId: parentId,
                    childIds: childIds,
                    bindingIds: bindingIds,
                    reachableBindingIds: reachableBindingIds,
                    depth: node.depth,
                    sequence: sequence,
                    stroke: node.stroke.map(cloneKeyStroke),
                    match: node.match,
                    display: presentation.display,
                    tokenName: presentation.tokenName,
                    active: active,
                    reachable: reachable,
                    pending: pendingNodeIds.contains(currentNodeId),
                    pendingPath: pendingPathNodeIds.contains(currentNodeId)
                )
            )

            for child in children {
                collectNodes(child, parentId: currentNodeId)
            }
        }
        collectNodes(layer.root, parentId: nil)
    }

    let graphLayers: [GraphLayer<Target>] = sortedLayers.map { layer in
        let meta = layerMetas[ObjectIdentifier(layer)]!
        return GraphLayer(
            id: meta.id,
            order: layer.order,
            priority: layer.priority,
            target: includeTargets ? layer.target : nil,
            targetMode: layer.targetMode,
            fields: layer.fields ?? [:],
            attrs: layer.attrs,
            active: meta.active,
            focusActive: meta.focusActive,
            enabled: meta.enabled,
            inactiveReasons: meta.inactiveReasons,
            rootNodeId: nodeIds[ObjectIdentifier(layer.root)]!,
            bindingIds: layer.bindings.compactMap { bindingMetasByID[ObjectIdentifier($0)]?.id },
            commandIds: layer.commands.compactMap { commandMetasByID[ObjectIdentifier($0)]?.id }
        )
    }

    let graphCommands: [GraphCommand<Target, Event>] = orderedCommandMetas.map { meta in
        GraphCommand(
            id: meta.id,
            layerId: meta.layerMeta.id,
            name: meta.command.command.name,
            command: meta.command.command,
            fields: meta.command.fields,
            attrs: meta.command.attrs,
            target: includeTargets ? meta.layerMeta.layer.target : nil,
            active: meta.active,
            reachable: meta.reachable,
            enabled: meta.enabled,
            inactiveReasons: meta.inactiveReasons
        )
    }

    let graphBindings: [GraphBinding<Target, Event>] = orderedBindingMetas.map { meta in
        let binding = meta.binding
        return GraphBinding(
            id: meta.id,
            layerId: meta.layerMeta.id,
            sourceLayerOrder: binding.sourceLayerOrder,
            bindingIndex: binding.bindingIndex,
            nodeId: bindingNodeIds[ObjectIdentifier(binding)],
            commandIds: meta.commandIds,
            sequence: cloneKeySequence(binding.sequence),
            command: binding.command,
            commandAttrs: catalog.getBindingCommandAttrs(binding, focused: focused, activeView: activeView),
            attrs: binding.attrs,
            event: binding.event,
            preventDefault: binding.preventDefault,
            fallthrough: binding.fallthrough,
            active: meta.active,
            reachable: meta.reachable,
            enabled: meta.enabled,
            commandResolved: meta.commandResolved,
            shadowed: meta.shadowed,
            inactiveReasons: meta.inactiveReasons
        )
    }

    let activeKeys = activation.getActiveKeysForFocused(
        focused,
        options: ActiveKeyOptions(includeBindings: true, includeMetadata: true)
    )

    return GraphSnapshot(
        focused: includeTargets ? focused : nil,
        pendingSequence: (focused == currentFocused) ? activation.getPendingSequence() : [],
        activeKeys: activeKeys,
        layers: graphLayers,
        commands: graphCommands,
        bindings: graphBindings,
        sequenceNodes: sequenceNodes
    )
}

// MARK: - Graph Extra Facade (extras/graph.ts)

// parity: keymap/src/extras/graph.ts#KeymapGraphExtra [status=implemented hash=acacffb692be]
public struct KeymapGraphExtra<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    private let snapshotProvider: @Sendable (GraphSnapshotOptions<Target>?) -> GraphSnapshot<Target, Event>

    public init(snapshotProvider: @escaping @Sendable (GraphSnapshotOptions<Target>?) -> GraphSnapshot<Target, Event>)
    {
        self.snapshotProvider = snapshotProvider
    }

    public func getGraphSnapshot(_ options: GraphSnapshotOptions<Target>? = nil) -> GraphSnapshot<Target, Event> {
        snapshotProvider(options)
    }
}

// parity: keymap/src/extras/graph.ts#getGraphSnapshot [status=implemented hash=0fabff839366]
public func getGraphSnapshot<Provider: KeymapExtensionProvider>(
    _ keymap: Provider,
    options: GraphSnapshotOptions<Provider.Host.Target>? = nil
) -> GraphSnapshot<Provider.Host.Target, Provider.Host.Event> {
    let context = keymap.keymapExtensionContext()
    return createGraphSnapshot(
        state: context.state,
        host: context.host,
        conditions: context.conditions,
        catalog: context.catalog,
        activation: context.activation,
        snapshotOptions: options
    )
}

// parity: keymap/src/extras/graph.ts#createGraphExtra [status=implemented hash=1145c000103d]
public func createGraphExtra<Provider: KeymapExtensionProvider>(
    _ keymap: Provider
) -> KeymapGraphExtra<Provider.Host.Target, Provider.Host.Event> {
    KeymapGraphExtra { options in
        getGraphSnapshot(keymap, options: options)
    }
}
