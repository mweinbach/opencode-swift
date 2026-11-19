// Pure Swift 6 port of all universal addons under keymap/src/addons/universal/.

// MARK: - Addon Error Types

public enum KeymapAddonError: Error, Equatable, Sendable, KeymapDescribedError {
    case invalidLeaderTrigger(String)
    case invalidAliases(String)
    case invalidBindingOverrides(String)
    case invalidCommaBinding(String)
    case invalidEmacsSequence(String)
    case invalidEnabledField(String)
    case invalidMetadataField(String)
    case invalidExCommand(String)

    public var errorMessage: String {
        switch self {
        case .invalidLeaderTrigger(let msg),
            .invalidAliases(let msg),
            .invalidBindingOverrides(let msg),
            .invalidCommaBinding(let msg),
            .invalidEmacsSequence(let msg),
            .invalidEnabledField(let msg),
            .invalidMetadataField(let msg),
            .invalidExCommand(let msg):
            return msg
        }
    }
}

// MARK: - Default Parser Addons (addons/universal/default-parser.ts)

/// Parses the built-in string binding syntax, including modifiers, `<token>` aliases,
/// and `{pattern}` dynamic sequence segments.
// parity: keymap/src/addons/universal/default-parser.ts#registerDefaultBindingParser [status=implemented hash=be783900a9b1]
@discardableResult
public func registerDefaultBindingParser<Host: KeymapHost>(
    _ keymap: Keymap<Host>
) -> @Sendable () -> Void {
    keymap.appendBindingParser { ctx in
        try defaultBindingParser(ctx)
    }
}

/// Matches incoming key events against their canonical normalized stroke.
// parity: keymap/src/addons/universal/default-parser.ts#registerDefaultEventMatchResolver [status=implemented hash=b04e88eb694a]
@discardableResult
public func registerDefaultEventMatchResolver<Host: KeymapHost>(
    _ keymap: Keymap<Host>
) -> @Sendable () -> Void {
    keymap.appendEventMatchResolver { event, ctx in
        try defaultEventMatchResolver(event, ctx: ctx)
    }
}

/// Installs the standard parser and event matcher used by most keymaps.
// parity: keymap/src/addons/universal/default-parser.ts#registerDefaultKeys [status=implemented hash=188fa0c65cd3]
@discardableResult
public func registerDefaultKeys<Host: KeymapHost>(
    _ keymap: Keymap<Host>
) -> @Sendable () -> Void {
    let offParser = registerDefaultBindingParser(keymap)
    let offResolver = registerDefaultEventMatchResolver(keymap)
    return {
        offResolver()
        offParser()
    }
}

// MARK: - Leader Addon (addons/universal/leader.ts)

public struct LeaderBindingTrigger: Equatable, Hashable, Sendable {
    public let key: KeyLike

    public init(key: KeyLike) {
        self.key = key
    }
}

// parity: keymap/src/addons/universal/leader.ts#LeaderTrigger [status=implemented hash=540ce58b0dbb]
public enum LeaderTrigger: Equatable, Hashable, Sendable, ExpressibleByStringLiteral {
    case key(KeyLike)
    case binding(LeaderBindingTrigger)
    case bindings([LeaderBindingTrigger])

    public init(stringLiteral value: String) {
        self = .key(.string(value))
    }

    public static func stroke(_ stroke: KeyStrokeInput) -> LeaderTrigger {
        .key(.stroke(stroke))
    }
}

// parity: keymap/src/addons/universal/leader.ts#LeaderOptions [status=implemented hash=ba78c891906b]
public struct LeaderOptions: Equatable, Hashable, Sendable {
    public let trigger: LeaderTrigger
    public let name: String?

    public init(trigger: LeaderTrigger, name: String? = nil) {
        self.trigger = trigger
        self.name = name
    }
}

// parity: keymap/src/addons/universal/leader.ts#resolveLeaderTrigger [status=implemented hash=07cf24b7b8ae]
public func resolveLeaderTrigger(_ trigger: LeaderTrigger) throws(KeymapAddonError) -> KeyLike? {
    switch trigger {
    case .key(let key):
        return key
    case .binding(let binding):
        return binding.key
    case .bindings(let bindings):
        if bindings.isEmpty {
            return nil
        }
        if bindings.count > 1 {
            throw .invalidLeaderTrigger("Invalid leader trigger: expected exactly one binding")
        }
        return bindings[0].key
    }
}

/// Defines a token such as `leader` that the default parser can reference as `<leader>`.
// parity: keymap/src/addons/universal/leader.ts#registerLeader [status=implemented hash=5c43f6ab7587]
@discardableResult
public func registerLeader<Host: KeymapHost>(
    _ keymap: Keymap<Host>,
    options: LeaderOptions
) throws(KeymapAddonError) -> @Sendable () -> Void {
    guard let key = try resolveLeaderTrigger(options.trigger) else {
        return {}
    }
    return keymap.registerToken(KeyToken(name: options.name ?? "leader", key: key))
}

// MARK: - Timed Leader Addon (addons/universal/timed-leader.ts)

// parity: keymap/src/addons/universal/timed-leader.ts#TimedLeaderOptions [status=implemented hash=d24f9b79fabf]
public struct TimedLeaderOptions: Sendable {
    public let trigger: LeaderTrigger
    public let name: String?
    public let timeoutMs: Int
    public let onArm: (@Sendable () -> Void)?
    public let onDisarm: (@Sendable () -> Void)?

    public init(
        trigger: LeaderTrigger,
        name: String? = nil,
        timeoutMs: Int = 1500,
        onArm: (@Sendable () -> Void)? = nil,
        onDisarm: (@Sendable () -> Void)? = nil
    ) {
        self.trigger = trigger
        self.name = name
        self.timeoutMs = timeoutMs
        self.onArm = onArm
        self.onDisarm = onDisarm
    }
}

private final class TimedLeaderState: @unchecked Sendable {
    var armed: Bool = false
    var timerTask: Task<Void, Never>? = nil

    func cancelTimer() {
        timerTask?.cancel()
        timerTask = nil
    }
}

/// Defines a leader token and clears it if no follow-up key arrives before `timeoutMs`.
// parity: keymap/src/addons/universal/timed-leader.ts#registerTimedLeader [status=implemented hash=261219fa2f8b]
@discardableResult
public func registerTimedLeader<Host: KeymapHost>(
    _ keymap: Keymap<Host>,
    options: TimedLeaderOptions
) throws -> @Sendable () -> Void {
    guard let trigger = try resolveLeaderTrigger(options.trigger) else {
        return {}
    }

    let matchesTrigger = try keymap.createKeyMatcher(trigger)
    let timeoutMs = max(0, options.timeoutMs)
    let state = TimedLeaderState()

    let syncArmedState: @Sendable ([KeySequencePart]) -> Void = { [weak keymap] sequence in
        let firstInput: KeyStringifyInput? = sequence.first.map { .part($0) }
        let nextArmed = matchesTrigger(firstInput)
        state.cancelTimer()

        if nextArmed {
            state.timerTask = Task { [weak keymap] in
                do {
                    try await Task.sleep(for: .milliseconds(timeoutMs))
                    try Task.checkCancellation()
                    await Task.yield()
                    try Task.checkCancellation()
                    keymap?.clearPendingSequence()
                } catch {
                    // Cancelled before timeout
                }
            }
        }

        if nextArmed == state.armed {
            return
        }

        state.armed = nextArmed
        if nextArmed {
            options.onArm?()
        } else {
            options.onDisarm?()
        }
    }

    let offLeader = try registerLeader(keymap, options: LeaderOptions(trigger: .key(trigger), name: options.name))
    let offPending = keymap.on(.pendingSequence(syncArmedState))
    syncArmedState(keymap.getPendingSequence())

    return {
        state.cancelTimer()
        offPending()
        offLeader()
        if state.armed {
            state.armed = false
            options.onDisarm?()
        }
    }
}

// MARK: - Aliases Addon (addons/universal/aliases.ts)

// parity: keymap/src/addons/universal/aliases.ts#Aliases [status=implemented hash=c67a42492a68]
public typealias Aliases = [String: String]

private let ALIASES_FIELD_RESOURCE = "keymap:aliases-field"

private func normalizeAliasesValue(_ value: KeymapValue) throws(KeymapAddonError) -> Aliases {
    guard case .object(let dict) = value else {
        throw .invalidAliases("Keymap aliases field \"aliases\" must be an object of key-name mappings")
    }

    var aliases: Aliases = [:]
    for (name, rawKey) in dict {
        let trimmedName = keymapTrimWhitespace(name)
        if trimmedName.isEmpty {
            throw .invalidAliases("Keymap aliases field \"aliases\" cannot contain empty alias names")
        }
        guard case .string(let key) = rawKey else {
            throw .invalidAliases("Keymap alias \"\(trimmedName)\" must map to a string key name")
        }
        let trimmedKey = keymapTrimWhitespace(key)
        if trimmedKey.isEmpty {
            throw .invalidAliases("Keymap alias \"\(trimmedName)\" cannot map to an empty key name")
        }
        aliases[trimmedName.lowercased()] = trimmedKey.lowercased()
    }
    return aliases
}

/// Adds an `aliases` layer field for remapping single-key binding names within that layer.
// parity: keymap/src/addons/universal/aliases.ts#registerAliasesField [status=implemented hash=f0e7dba9ba6c]
@discardableResult
public func registerAliasesField<Host: KeymapHost>(
    _ keymap: Keymap<Host>
) throws -> @Sendable () -> Void {
    try keymap.acquireResource(key: ALIASES_FIELD_RESOURCE) {
        let offLayerField = keymap.registerLayerFields([
            "aliases": { value, _ in
                _ = try normalizeAliasesValue(value)
            }
        ])

        let offBindingTransformer = keymap.appendBindingTransformer { binding, ctx in
            guard let rawAliases = ctx.layer["aliases"],
                case .object = rawAliases
            else {
                return
            }
            let aliases = try normalizeAliasesValue(rawAliases)
            guard binding.sequence.count == 1, let part = binding.sequence.first else {
                return
            }
            guard let aliasedName = aliases[part.stroke.name] else {
                return
            }

            let aliasedStroke = KeyStrokeInput(
                name: aliasedName,
                ctrl: part.stroke.ctrl,
                shift: part.stroke.shift,
                meta: part.stroke.meta,
                super: part.stroke.`super`,
                hyper: part.stroke.hyper
            )
            var aliasedBinding = binding
            aliasedBinding.sequence = [try ctx.parseKey(.stroke(aliasedStroke))]
            ctx.add(aliasedBinding)
        }

        return {
            offBindingTransformer()
            offLayerField()
        }
    }
}

// MARK: - Backspace Pops Pending Sequence (addons/universal/backspace-pops-pending-sequence.ts)

// parity: keymap/src/addons/universal/backspace-pops-pending-sequence.ts#BackspacePopsPendingSequenceOptions [status=implemented hash=36f10a173781]
public struct BackspacePopsPendingSequenceOptions: Equatable, Hashable, Sendable {
    public let preventDefault: Bool
    public let priority: Int

    public init(preventDefault: Bool = true, priority: Int = 0) {
        self.preventDefault = preventDefault
        self.priority = priority
    }
}

/// Lets `Backspace` step back through the current pending multi-key sequence.
// parity: keymap/src/addons/universal/backspace-pops-pending-sequence.ts#registerBackspacePopsPendingSequence [status=implemented hash=cfd794f286fc]
@discardableResult
public func registerBackspacePopsPendingSequence<Host: KeymapHost>(
    _ keymap: Keymap<Host>,
    options: BackspacePopsPendingSequenceOptions = BackspacePopsPendingSequenceOptions()
) -> @Sendable () -> Void {
    let shouldPreventDefault = options.preventDefault
    return keymap.intercept(
        .key(
            { [weak keymap] ctx in
                guard ctx.event.name == "backspace" else {
                    return
                }
                guard keymap?.popPendingSequence() == true else {
                    return
                }
                if shouldPreventDefault {
                    ctx.consume()
                }
            },
            KeyInterceptOptions(priority: options.priority)
        )
    )
}

// MARK: - Escape Clears Pending Sequence (addons/universal/escape-clears-pending-sequence.ts)

// parity: keymap/src/addons/universal/escape-clears-pending-sequence.ts#EscapeClearsPendingSequenceOptions [status=implemented hash=fc708a6e65e4]
public struct EscapeClearsPendingSequenceOptions: Equatable, Hashable, Sendable {
    public let preventDefault: Bool
    public let priority: Int

    public init(preventDefault: Bool = true, priority: Int = 0) {
        self.preventDefault = preventDefault
        self.priority = priority
    }
}

/// Lets `Escape` cancel an in-progress multi-key sequence before it dispatches further.
// parity: keymap/src/addons/universal/escape-clears-pending-sequence.ts#registerEscapeClearsPendingSequence [status=implemented hash=d145c70e4a22]
@discardableResult
public func registerEscapeClearsPendingSequence<Host: KeymapHost>(
    _ keymap: Keymap<Host>,
    options: EscapeClearsPendingSequenceOptions = EscapeClearsPendingSequenceOptions()
) -> @Sendable () -> Void {
    let shouldPreventDefault = options.preventDefault
    return keymap.intercept(
        .key(
            { [weak keymap] ctx in
                guard ctx.event.name == "escape" else {
                    return
                }
                guard let keymap, keymap.hasPendingSequence() else {
                    return
                }
                keymap.clearPendingSequence()
                if shouldPreventDefault {
                    ctx.consume()
                }
            },
            KeyInterceptOptions(priority: options.priority)
        )
    )
}

// MARK: - Neovim Disambiguation (addons/universal/neovim-disambiguation.ts)

// parity: keymap/src/addons/universal/neovim-disambiguation.ts#NeovimDisambiguationOptions [status=implemented hash=07d68e819be0]
public struct NeovimDisambiguationOptions: Equatable, Hashable, Sendable {
    public let timeoutMs: Int

    public init(timeoutMs: Int = 300) {
        self.timeoutMs = timeoutMs
    }
}

/// Defers ambiguous exact-vs-prefix bindings and runs the exact binding if no continuation
/// arrives before `timeoutMs`, matching Neovim-style `timeoutlen` disambiguation.
// parity: keymap/src/addons/universal/neovim-disambiguation.ts#registerNeovimDisambiguation [status=implemented hash=bba23416c109]
@discardableResult
public func registerNeovimDisambiguation<Host: KeymapHost>(
    _ keymap: Keymap<Host>,
    options: NeovimDisambiguationOptions = NeovimDisambiguationOptions()
) -> @Sendable () -> Void {
    let timeoutMs = options.timeoutMs
    return keymap.appendDisambiguationResolver { ctx in
        ctx.defer { deferred in
            if await deferred.sleep(timeoutMs), await deferred.sleep(0) {
                return deferred.runExact()
            }
            return nil
        }
    }
}

// MARK: - Ex Commands (addons/universal/ex-commands.ts)

private let EX_COMMANDS_RESOURCE = "keymap:ex-commands"

public enum ExCommandNargs: String, Equatable, Hashable, Sendable, CaseIterable {
    case zero = "0"
    case one = "1"
    case optional = "?"
    case zeroOrMore = "*"
    case oneOrMore = "+"
}

// parity: keymap/src/addons/universal/ex-commands.ts#ExCommandPayload [status=implemented hash=1d4ef8d75a88]
public struct ExCommandPayload: Equatable, Sendable {
    public let raw: String
    public let args: [String]
    public let payload: KeymapValue?

    public init(raw: String, args: [String] = [], payload: KeymapValue? = nil) {
        self.raw = raw
        self.args = args
        self.payload = payload
    }

    public func toKeymapValue() -> KeymapValue {
        var dict: [String: KeymapValue] = [
            "raw": .string(raw),
            "args": .array(args.map { .string($0) }),
        ]
        if let payload, payload != .undefined {
            dict["payload"] = payload
        }
        return .object(dict)
    }

    public static func fromKeymapValue(_ value: KeymapValue?) -> ExCommandPayload? {
        guard case .object(let dict) = value,
            case .string(let raw) = dict["raw"],
            case .array(let rawArgs) = dict["args"]
        else {
            return nil
        }
        var args: [String] = []
        args.reserveCapacity(rawArgs.count)
        for item in rawArgs {
            guard case .string(let arg) = item else { return nil }
            args.append(arg)
        }
        return ExCommandPayload(raw: raw, args: args, payload: dict["payload"])
    }
}

// parity: keymap/src/addons/universal/ex-commands.ts#ExCommand [status=implemented hash=8467f402aab8]
public struct ExCommand<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public var name: String
    public var aliases: [String]?
    public var nargs: ExCommandNargs?
    public var fields: [String: KeymapValue]
    public var run: @Sendable (CommandContext<Target, Event>, ExCommandPayload) throws -> Bool?

    public init(
        name: String,
        aliases: [String]? = nil,
        nargs: ExCommandNargs? = nil,
        fields: [String: KeymapValue] = [:],
        run: @escaping @Sendable (CommandContext<Target, Event>, ExCommandPayload) throws -> Bool?
    ) {
        self.name = name
        self.aliases = aliases
        self.nargs = nargs
        self.fields = fields
        self.run = run
    }

    /// Converts this typed `ExCommand` into a standard `Command` suitable for `Layer.commands`.
    public func toCommand() -> Command<Target, Event> {
        var mergedFields = fields
        mergedFields["namespace"] = .string("excommands")
        if let aliases {
            mergedFields["aliases"] = .array(aliases.map { .string($0) })
        }
        if let nargs {
            mergedFields["nargs"] = .string(nargs.rawValue)
        }
        let handler = self.run
        return Command(name: name, fields: mergedFields) { ctx in
            let exPayload = ExCommandPayload.fromKeymapValue(ctx.payload)
                ?? ExCommandPayload(raw: ctx.input, args: [], payload: ctx.payload)
            return try handler(ctx, exPayload)
        }
    }
}

private func normalizeExCommandName(_ name: String) throws(KeymapAddonError) -> String {
    let normalized = keymapTrimWhitespace(name)
    if normalized.isEmpty {
        throw .invalidExCommand("Invalid keymap command name: name cannot be empty")
    }
    if keymapContainsWhitespace(normalized) {
        throw .invalidExCommand("Invalid keymap command name \"\(name)\": command names cannot contain whitespace")
    }
    if normalized.hasPrefix(":") {
        return normalized
    }
    return ":\(normalized)"
}

private func normalizeExCommandAliases(_ value: KeymapValue) throws(KeymapAddonError) -> [String] {
    guard case .array(let items) = value else {
        throw .invalidExCommand("Keymap ex-command field \"aliases\" must be an array of command names")
    }
    var aliases: [String] = []
    aliases.reserveCapacity(items.count)
    for item in items {
        guard case .string(let alias) = item else {
            throw .invalidExCommand("Keymap ex-command field \"aliases\" must only contain command names")
        }
        aliases.append(alias)
    }
    return aliases
}

private func normalizeExCommandNargs(_ value: KeymapValue) throws(KeymapAddonError) -> ExCommandNargs {
    if case .string(let s) = value, let nargs = ExCommandNargs(rawValue: s) {
        return nargs
    }
    throw .invalidExCommand("Keymap ex-command field \"nargs\" must be \"0\", \"1\", \"?\", \"*\", or \"+\"")
}

private func splitByWhitespace(_ input: String) -> [String] {
    var parts: [String] = []
    var current = ""
    for scalar in input.unicodeScalars {
        let isWS =
            scalar.value == 0x20 || scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0B
            || scalar.value == 0x0C || scalar.value == 0x0D || scalar.value == 0xA0 || scalar.value == 0xFEFF
        if isWS {
            if !current.isEmpty {
                parts.append(current)
                current = ""
            }
        } else {
            current.unicodeScalars.append(scalar)
        }
    }
    if !current.isEmpty {
        parts.append(current)
    }
    return parts
}

/// Parses an Ex command input string such as `":e foo.swift bar.swift"` into a `ParsedCommand`.
public func parseExCommandInput(_ input: String) throws(KeymapAddonError) -> ParsedCommand {
    let trimmed = keymapTrimWhitespace(input)
    if trimmed.isEmpty {
        throw .invalidExCommand("Invalid keymap command: command cannot be empty")
    }
    let parts = splitByWhitespace(trimmed)
    guard let name = parts.first, !name.isEmpty else {
        throw .invalidExCommand("Invalid keymap command \"\(input)\"")
    }
    return ParsedCommand(input: trimmed, name: name, args: Array(parts.dropFirst()))
}

private func validateExCommandArgs(nargsValue: KeymapValue?, args: [String]) throws(KeymapAddonError) -> Bool {
    guard let nargsValue, nargsValue != .undefined else {
        return true
    }
    let nargs = try normalizeExCommandNargs(nargsValue)
    let count = args.count
    switch nargs {
    case .zero: return count == 0
    case .one: return count == 1
    case .optional: return count <= 1
    case .zeroOrMore: return true
    case .oneOrMore: return count >= 1
    }
}

/// Installs Ex command support. Ex commands are registered through normal keymap layers
/// by using a colon-prefixed command name or `fields["namespace"] = .string("excommands")`.
// parity: keymap/src/addons/universal/ex-commands.ts#registerExCommands [status=implemented hash=59f7449dfc21]
@discardableResult
public func registerExCommands<Host: KeymapHost>(
    _ keymap: Keymap<Host>
) throws -> @Sendable () -> Void {
    try keymap.acquireResource(key: EX_COMMANDS_RESOURCE) {
        let offFields = keymap.registerCommandFields([
            "aliases": { value, _ in
                _ = try normalizeExCommandAliases(value)
            },
            "nargs": { value, _ in
                _ = try normalizeExCommandNargs(value)
            },
        ])

        let offTransformer = keymap.appendCommandTransformer { command, ctx in
            let isEx =
                keymapTrimWhitespace(command.name).hasPrefix(":")
                || command.fields["namespace"] == .string("excommands")
            if !isEx {
                return
            }

            ctx.skipOriginal()

            if let nargsVal = command.fields["nargs"], nargsVal != .undefined {
                _ = try normalizeExCommandNargs(nargsVal)
            }

            let aliases: [String]
            if let aliasVal = command.fields["aliases"], aliasVal != .undefined {
                aliases = try normalizeExCommandAliases(aliasVal)
            } else {
                aliases = []
            }

            let names = try ([command.name] + aliases).map(normalizeExCommandName)
            let originalRun = command.run
            let nargsField = command.fields["nargs"]

            for name in names {
                var nextFields = command.fields
                nextFields["namespace"] = .string("excommands")
                let wrapped = Command<Host.Target, Host.Event>(name: name, fields: nextFields) { cmdCtx in
                    let exPayload =
                        ExCommandPayload.fromKeymapValue(cmdCtx.payload)
                        ?? ExCommandPayload(raw: cmdCtx.input, args: [], payload: cmdCtx.payload)
                    let valid = try validateExCommandArgs(nargsValue: nargsField, args: exPayload.args)
                    if !valid {
                        return false
                    }
                    let nextCtx = CommandContext<Host.Target, Host.Event>(
                        event: cmdCtx.event,
                        focused: cmdCtx.focused,
                        target: cmdCtx.target,
                        data: cmdCtx.data,
                        input: cmdCtx.input,
                        payload: exPayload.toKeymapValue()
                    )
                    return try originalRun(nextCtx)
                }
                ctx.add(wrapped)
            }
        }

        let offResolver = keymap.appendCommandResolver { input, ctx in
            guard input.hasPrefix(":") else {
                return nil
            }
            let parsed = try parseExCommandInput(input)
            let normalizedName = try normalizeExCommandName(parsed.name)
            guard let command = ctx.getCommand(normalizedName) else {
                return nil
            }
            ctx.setInput(parsed.input)
            let exPayload = ExCommandPayload(raw: parsed.input, args: parsed.args, payload: ctx.payload)
            ctx.setPayload(exPayload.toKeymapValue())
            return command
        }

        return {
            offResolver()
            offTransformer()
            offFields()
        }
    }
}

// MARK: - Binding Overrides (addons/universal/binding-overrides.ts)

private let BINDING_OVERRIDES_RESOURCE = "keymap:binding-overrides"

public extension Binding {
    /// Serializes a string-command binding into a `KeymapValue` suitable for `layer.fields["bindingOverrides"]`.
    func toOverrideValue() -> KeymapValue {
        var dict = fields
        switch key {
        case .string(let s):
            dict["key"] = .string(s)
        case .stroke(let stroke):
            var strokeObj: [String: KeymapValue] = ["name": .string(stroke.name)]
            if let ctrl = stroke.ctrl { strokeObj["ctrl"] = .bool(ctrl) }
            if let shift = stroke.shift { strokeObj["shift"] = .bool(shift) }
            if let meta = stroke.meta { strokeObj["meta"] = .bool(meta) }
            if let sup = stroke.`super` { strokeObj["super"] = .bool(sup) }
            if let hyper = stroke.hyper { strokeObj["hyper"] = .bool(hyper) }
            dict["key"] = .object(strokeObj)
        }
        if let name = cmd?.commandName {
            dict["cmd"] = .string(name)
        }
        if let event {
            dict["event"] = .string(event.rawValue)
        }
        if let preventDefault {
            dict["preventDefault"] = .bool(preventDefault)
        }
        if let isFallthrough = `fallthrough` {
            dict["fallthrough"] = .bool(isFallthrough)
        }
        return .object(dict)
    }
}

private func decodeBindingOverride<Target: Hashable & Sendable, Event: KeymapEvent>(
    _ value: KeymapValue
) throws(KeymapAddonError) -> Binding<Target, Event> {
    guard case .object(let dict) = value else {
        throw .invalidBindingOverrides("Keymap layer field \"bindingOverrides\" entries must be binding objects")
    }

    let key: KeyLike
    switch dict["key"] {
    case .string(let rawKey):
        key = .string(rawKey)
    case .object(let strokeObj):
        guard case .string(let name) = strokeObj["name"] else {
            throw .invalidBindingOverrides("Keymap binding override stroke must include a string \"name\"")
        }
        let ctrl: Bool? = if case .bool(let b) = strokeObj["ctrl"] { b } else { nil }
        let shift: Bool? = if case .bool(let b) = strokeObj["shift"] { b } else { nil }
        let meta: Bool? = if case .bool(let b) = strokeObj["meta"] { b } else { nil }
        let superKey: Bool? = if case .bool(let b) = strokeObj["super"] { b } else { nil }
        let hyper: Bool? = if case .bool(let b) = strokeObj["hyper"] { b } else { nil }
        key = .stroke(
            KeyStrokeInput(name: name, ctrl: ctrl, shift: shift, meta: meta, super: superKey, hyper: hyper)
        )
    default:
        throw .invalidBindingOverrides("Keymap binding override must specify a \"key\" string or stroke object")
    }

    var cmd: BindingCommand<Target, Event>? = nil
    if case .string(let cmdName) = dict["cmd"] {
        cmd = .named(cmdName)
    }

    var event: BindingEvent? = nil
    if case .string(let evStr) = dict["event"] {
        guard let parsed = BindingEvent(rawValue: evStr) else {
            throw .invalidBindingOverrides("Invalid binding override event \"\(evStr)\"")
        }
        event = parsed
    }

    let preventDefault: Bool? = if case .bool(let b) = dict["preventDefault"] { b } else { nil }
    let fallthroughVal: Bool? = if case .bool(let b) = dict["fallthrough"] { b } else { nil }

    var extraFields: [String: KeymapValue] = [:]
    for (k, v) in dict where !RESERVED_BINDING_FIELDS.contains(k) {
        extraFields[k] = v
    }

    return Binding(
        key: key,
        cmd: cmd,
        event: event,
        preventDefault: preventDefault,
        fallthrough: fallthroughVal,
        fields: extraFields
    )
}

private func normalizeBindingOverridesValue<Target: Hashable & Sendable, Event: KeymapEvent>(
    _ value: KeymapValue
) throws(KeymapAddonError) -> [Binding<Target, Event>] {
    guard case .array(let items) = value else {
        throw .invalidBindingOverrides("Keymap layer field \"bindingOverrides\" must be an array of binding objects")
    }
    return try items.map(decodeBindingOverride)
}

/// Adds a `bindingOverrides` layer field that replaces bindings by string command name
/// within that layer before compilation.
// parity: keymap/src/addons/universal/binding-overrides.ts#registerBindingOverrides [status=implemented hash=228379022bf5]
@discardableResult
public func registerBindingOverrides<Host: KeymapHost>(
    _ keymap: Keymap<Host>
) throws -> @Sendable () -> Void {
    try keymap.acquireResource(key: BINDING_OVERRIDES_RESOURCE) {
        let offLayerField = keymap.registerLayerFields([
            "bindingOverrides": { value, _ in
                let _: [Binding<Host.Target, Host.Event>] = try normalizeBindingOverridesValue(value)
            }
        ])

        let offTransformer = keymap.appendLayerBindingsTransformer { bindings, ctx in
            guard let rawOverrides = ctx.layer.fields["bindingOverrides"], rawOverrides != .undefined else {
                return nil
            }
            let overrides: [Binding<Host.Target, Host.Event>] = try normalizeBindingOverridesValue(rawOverrides)
            let validation = ctx.validateBindings(overrides)
            if case .invalid(let reason) = validation {
                throw KeymapAddonError.invalidBindingOverrides(reason)
            }

            var overrideCommands: Set<String> = []
            for overrideBinding in overrides {
                if let name = overrideBinding.cmd?.commandName {
                    overrideCommands.insert(keymapTrimWhitespace(name))
                }
            }

            let filtered = bindings.filter { binding in
                guard let name = binding.cmd?.commandName else {
                    return true
                }
                return !overrideCommands.contains(keymapTrimWhitespace(name))
            }
            return overrides + filtered
        }

        return {
            offTransformer()
            offLayerField()
        }
    }
}

// MARK: - Comma Bindings (addons/universal/comma-bindings.ts)

private let COMMA_BINDINGS_RESOURCE = "keymap:comma-bindings"

private let commaBindingExpander: BindingExpander = { ctx in
    let input = ctx.input
    guard input.contains(",") else {
        return nil
    }

    let parts = input.split(separator: ",", omittingEmptySubsequences: false).map {
        keymapTrimWhitespace(String($0))
    }
    if parts.contains(where: { $0.isEmpty }) {
        throw KeymapAddonError.invalidCommaBinding(
            "Invalid key sequence \"\(input)\": comma-separated bindings cannot contain empty entries"
        )
    }

    guard let displays = ctx.displays else {
        return parts.map { BindingExpansion(key: $0) }
    }

    let displayParts: [String]
    if displays.count == 1 {
        displayParts = displays[0].split(separator: ",", omittingEmptySubsequences: false).map {
            keymapTrimWhitespace(String($0))
        }
    } else {
        displayParts = displays
    }

    if displayParts.count != parts.count || displayParts.contains(where: { $0.isEmpty }) {
        return parts.map { BindingExpansion(key: $0) }
    }

    return zip(parts, displayParts).map { key, displayText in
        BindingExpansion(key: key, displays: splitByWhitespace(keymapTrimWhitespace(displayText)))
    }
}

/// Expands comma-separated binding strings such as `"ctrl+a, ctrl+b"` or `"j,k"` into separate bindings.
// parity: keymap/src/addons/universal/comma-bindings.ts#registerCommaBindings [status=implemented hash=7a764f12fc93]
@discardableResult
public func registerCommaBindings<Host: KeymapHost>(
    _ keymap: Keymap<Host>
) throws -> @Sendable () -> Void {
    try keymap.acquireResource(key: COMMA_BINDINGS_RESOURCE) {
        keymap.appendBindingExpander(commaBindingExpander)
    }
}

// MARK: - Dead Binding Warnings (addons/universal/dead-bindings.ts)

private let DEAD_BINDING_WARNINGS_RESOURCE = "keymap:dead-binding-warnings"

private func isDeadMetadataOnlyBinding<Target: Hashable & Sendable, Event: KeymapEvent>(
    _ binding: LayerBindingAnalysis<Target, Event>
) -> Bool {
    if binding.command != nil {
        return false
    }
    if binding.event == .release {
        return true
    }
    return !binding.hasContinuations && !binding.hasCommandAtSequence
}

/// Warns about bindings that can never trigger because they have no command and no reachable continuation.
// parity: keymap/src/addons/universal/dead-bindings.ts#registerDeadBindingWarnings [status=implemented hash=93ce8b723387]
@discardableResult
public func registerDeadBindingWarnings<Host: KeymapHost>(
    _ keymap: Keymap<Host>
) throws -> @Sendable () -> Void {
    try keymap.acquireResource(key: DEAD_BINDING_WARNINGS_RESOURCE) {
        keymap.appendLayerAnalyzer { ctx in
            for binding in ctx.bindings {
                if !isDeadMetadataOnlyBinding(binding) {
                    continue
                }
                let sequence =
                    (try? stringifyKeySequence(
                        binding.parsedBinding.sequence.map { .part($0) },
                        options: StringifyOptions(preferDisplay: true)
                    )) ?? binding.parsedBinding.sequence.map(\.display).joined()
                let sourceKey: String
                switch binding.parsedBinding.key {
                case .string(let s):
                    sourceKey = s
                case .stroke(let stroke):
                    sourceKey = (try? stringifyKeyStroke(.stroke(stroke))) ?? stroke.name
                }
                let warningKey = "dead-binding:\(binding.sourceLayerOrder):\(binding.bindingIndex):\(sourceKey)"
                ctx.warnOnce(
                    key: warningKey,
                    code: "dead-binding",
                    detail: sequence,
                    message:
                        "[Keymap] Binding \"\(sequence)\" has no command and no reachable continuations; it will never trigger"
                )
            }
        }
    }
}

// MARK: - Emacs Bindings (addons/universal/emacs-bindings.ts)

private let EMACS_BINDINGS_RESOURCE = "keymap:emacs-bindings"

private func hasEmacsHyphenPrefix(_ stroke: String) -> Bool {
    let units = Array(stroke.utf16)
    guard units.count >= 3, units[1] == 45 else { return false } // '-'
    let first = units[0]
    return first == 67 || first == 77 || first == 83 || first == 115 || first == 72 // C, M, S, s, H
}

private func parseEmacsHyphenStroke(
    _ stroke: String,
    sequence: String,
    ctx: BindingParserContext
) throws -> KeySequencePart {
    var remaining = stroke[...]
    var ctrl = false
    var shift = false
    var meta = false
    var superKey = false
    var hyper = false

    while remaining.count >= 3 {
        let idx0 = remaining.startIndex
        let idx1 = remaining.index(after: idx0)
        guard remaining[idx1] == "-" else { break }
        switch remaining[idx0] {
        case "C": ctrl = true
        case "M": meta = true
        case "S": shift = true
        case "s": superKey = true
        case "H": hyper = true
        default:
            break
        }
        if remaining[idx0] == "C" || remaining[idx0] == "M" || remaining[idx0] == "S" || remaining[idx0] == "s"
            || remaining[idx0] == "H"
        {
            remaining = remaining[remaining.index(after: idx1)...]
        } else {
            break
        }
    }

    let name = keymapTrimWhitespace(String(remaining))
    if name.isEmpty {
        throw KeymapAddonError.invalidEmacsSequence(
            "Invalid emacs key sequence \"\(sequence)\": stroke \"\(stroke)\" is missing a key name"
        )
    }

    return try ctx.parseObjectKey(
        KeyStrokeInput(
            name: name,
            ctrl: ctrl,
            shift: shift,
            meta: meta,
            super: superKey,
            hyper: hyper ? true : nil
        )
    )
}

private func parseEmacsPlusStroke(
    _ input: String,
    sequence: String,
    ctx: BindingParserContext
) throws -> KeySequencePart {
    let parts = input.split(separator: "+", omittingEmptySubsequences: false)
    var name = ""
    var ctrl = false
    var shift = false
    var meta = false
    var superKey = false
    var hyper = false

    for rawPart in parts {
        let part = keymapTrimWhitespace(String(rawPart))
        if part.isEmpty { continue }
        let lowered = part.lowercased()
        switch lowered {
        case "ctrl", "control": ctrl = true
        case "shift": shift = true
        case "meta", "alt", "option": meta = true
        case "super": superKey = true
        case "hyper": hyper = true
        default:
            if !name.isEmpty {
                throw KeymapAddonError.invalidEmacsSequence(
                    "Invalid emacs key sequence \"\(sequence)\": stroke \"\(input)\" contains multiple key names"
                )
            }
            name = part
        }
    }

    if name.isEmpty {
        throw KeymapAddonError.invalidEmacsSequence(
            "Invalid emacs key sequence \"\(sequence)\": stroke \"\(input)\" is missing a key name"
        )
    }

    return try ctx.parseObjectKey(
        KeyStrokeInput(
            name: name,
            ctrl: ctrl,
            shift: shift,
            meta: meta,
            super: superKey,
            hyper: hyper ? true : nil
        )
    )
}

private func parseEmacsSequence(
    _ input: String,
    ctx: BindingParserContext
) throws -> [KeySequencePart]? {
    let strokes = splitByWhitespace(keymapTrimWhitespace(input))
    if strokes.isEmpty {
        return nil
    }

    let hasHyphenNotation = strokes.contains(where: hasEmacsHyphenPrefix)
    let hasMultiPlusChord = strokes.count > 1 && strokes.contains(where: { $0.contains("+") })

    guard hasHyphenNotation || hasMultiPlusChord else {
        return nil
    }

    return try strokes.map { stroke in
        if hasEmacsHyphenPrefix(stroke) {
            return try parseEmacsHyphenStroke(stroke, sequence: input, ctx: ctx)
        }
        return try parseEmacsPlusStroke(stroke, sequence: input, ctx: ctx)
    }
}

/// Parses Emacs-style space-separated chords such as `"ctrl+x ctrl+s"`, `"C-x C-f"`, and `"M-x"`.
// parity: keymap/src/addons/universal/emacs-bindings.ts#registerEmacsBindings [status=implemented hash=050796c02389]
@discardableResult
public func registerEmacsBindings<Host: KeymapHost>(
    _ keymap: Keymap<Host>
) throws -> @Sendable () -> Void {
    try keymap.acquireResource(key: EMACS_BINDINGS_RESOURCE) {
        let parseEmacsBinding: BindingParser = { ctx in
            guard ctx.index == 0, let parsed = try parseEmacsSequence(ctx.input, ctx: ctx) else {
                return nil
            }
            return BindingParserResult(parts: parsed, nextIndex: ctx.input.utf16.count)
        }
        return keymap.prependBindingParser(parseEmacsBinding)
    }
}

// MARK: - Enabled Fields (addons/universal/enabled.ts)

private let ENABLED_FIELDS_RESOURCE = "keymap:enabled-fields"

/// Accepted `enabled` values: boolean, predicate `() throws -> Bool`, or `ReactiveMatcher`.
// parity: keymap/src/addons/universal/enabled.ts#Enabled [status=implemented hash=ff66d1b7c6e9]
public enum Enabled: Sendable, ExpressibleByBooleanLiteral {
    case bool(Bool)
    case predicate(@Sendable () throws -> Bool)
    case reactive(ReactiveMatcher)

    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }

    /// Applies this `Enabled` condition directly to a `FieldCompilerContext`.
    public func apply(to ctx: FieldCompilerContext) {
        switch self {
        case .bool(true):
            return
        case .bool(false):
            ctx.activeWhen { false }
        case .predicate(let fn):
            ctx.activeWhen(fn)
        case .reactive(let reactive):
            ctx.activeWhen(reactive)
        }
    }
}

/// Registry allowing callback and reactive `Enabled` values to be referenced by token in `Layer.fields["enabled"]`
/// and `Command.fields["enabled"]`.
public final class EnabledConditionRegistry: @unchecked Sendable {
    public static let shared = EnabledConditionRegistry()
    private static let tokenPrefix = "__keymap_enabled_ref__:"

    private var nextID: Int = 0
    private var entries: [String: Enabled] = [:]

    public init() {}

    /// Registers a dynamic `Enabled` condition and returns a `KeymapValue` handle usable in `fields["enabled"]`.
    public func register(_ enabled: Enabled) -> KeymapValue {
        if case .bool(let flag) = enabled {
            return .bool(flag)
        }
        let id = nextID
        nextID += 1
        let token = "\(Self.tokenPrefix)\(id)"
        entries[token] = enabled
        return .string(token)
    }

    /// Removes a previously registered dynamic `Enabled` handle.
    public func unregister(_ handle: KeymapValue) {
        if case .string(let token) = handle {
            entries.removeValue(forKey: token)
        }
    }

    public func resolve(_ value: KeymapValue) -> Enabled? {
        switch value {
        case .bool(let flag):
            return .bool(flag)
        case .string(let token) where token.hasPrefix(Self.tokenPrefix):
            return entries[token]
        default:
            return nil
        }
    }
}

private func compileEnabledFieldValue(
    _ value: KeymapValue,
    ctx: FieldCompilerContext,
    registry: EnabledConditionRegistry
) throws(KeymapAddonError) {
    guard let resolved = registry.resolve(value) else {
        throw .invalidEnabledField(
            "Keymap enabled field \"enabled\" must be a boolean, a function, or a reactive matcher"
        )
    }
    resolved.apply(to: ctx)
}

/// Adds `enabled` layer, binding, and command fields for boolean, callback, or reactive matcher gating.
// parity: keymap/src/addons/universal/enabled.ts#registerEnabledFields [status=implemented hash=ce37395625bd]
@discardableResult
public func registerEnabledFields<Host: KeymapHost>(
    _ keymap: Keymap<Host>,
    registry: EnabledConditionRegistry = .shared
) throws -> @Sendable () -> Void {
    try keymap.acquireResource(key: ENABLED_FIELDS_RESOURCE) {
        let offLayerFields = keymap.registerLayerFields([
            "enabled": { value, ctx in
                try compileEnabledFieldValue(value, ctx: ctx, registry: registry)
            }
        ])

        let offCommandFields = keymap.registerCommandFields([
            "enabled": { value, ctx in
                try compileEnabledFieldValue(value, ctx: ctx, registry: registry)
            }
        ])

        let offBindingFields = keymap.registerBindingFields([
            "enabled": { value, ctx in
                try compileEnabledFieldValue(value, ctx: ctx, registry: registry)
            }
        ])

        return {
            offBindingFields()
            offCommandFields()
            offLayerFields()
        }
    }
}

// MARK: - Metadata Fields (addons/universal/metadata.ts)

private let METADATA_FIELDS_RESOURCE = "keymap:metadata-fields"

private func normalizeMetadataText(fieldName: String, value: KeymapValue) throws(KeymapAddonError) -> String {
    guard case .string(let text) = value else {
        throw .invalidMetadataField("Keymap metadata field \"\(fieldName)\" must be a string")
    }
    let trimmed = keymapTrimWhitespace(text)
    if trimmed.isEmpty {
        throw .invalidMetadataField("Keymap metadata field \"\(fieldName)\" cannot be empty")
    }
    return trimmed
}

/// Maps `desc`, `group`, `title`, and `category` fields into binding and command attrs.
// parity: keymap/src/addons/universal/metadata.ts#registerMetadataFields [status=implemented hash=78e78ea851e7]
@discardableResult
public func registerMetadataFields<Host: KeymapHost>(
    _ keymap: Keymap<Host>
) throws -> @Sendable () -> Void {
    try keymap.acquireResource(key: METADATA_FIELDS_RESOURCE) {
        let offBindingFields = keymap.registerBindingFields([
            "desc": { value, ctx in
                try ctx.attr("desc", .string(try normalizeMetadataText(fieldName: "desc", value: value)))
            },
            "group": { value, ctx in
                try ctx.attr("group", .string(try normalizeMetadataText(fieldName: "group", value: value)))
            },
        ])

        let offCommandFields = keymap.registerCommandFields([
            "desc": { value, ctx in
                try ctx.attr("desc", .string(try normalizeMetadataText(fieldName: "desc", value: value)))
            },
            "title": { value, ctx in
                try ctx.attr("title", .string(try normalizeMetadataText(fieldName: "title", value: value)))
            },
            "category": { value, ctx in
                try ctx.attr("category", .string(try normalizeMetadataText(fieldName: "category", value: value)))
            },
        ])

        return {
            offCommandFields()
            offBindingFields()
        }
    }
}

// MARK: - Platform Mod Bindings (addons/universal/mod-bindings.ts)

private let MOD_BINDINGS_RESOURCE = "keymap:mod-bindings"

private func resolveModModifier(_ metadata: HostMetadata) -> String {
    switch metadata.primaryModifier {
    case .ctrl where metadata.modifiers[.ctrl] != .unsupported:
        return "ctrl"
    case .super where metadata.modifiers[.super] != .unsupported:
        return "super"
    default:
        break
    }

    if metadata.modifiers[.ctrl] != .unsupported {
        return "ctrl"
    }
    return "super"
}

private func isModPrefixBoundary(_ unit: UInt16) -> Bool {
    unit == 43 /* '+' */ || unit == 44 /* ',' */ || unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D
}

private func isAsciiWhitespaceUnit(_ unit: UInt16) -> Bool {
    unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0B || unit == 0x0C || unit == 0x0D
}

private func replaceModModifier(_ input: String, with modifier: String) -> String? {
    let units = Array(input.utf16)
    let modUnits = Array(modifier.utf16)
    var out: [UInt16] = []
    out.reserveCapacity(units.count + 4)

    var replaced = false
    var i = 0
    while i < units.count {
        if (i == 0 || isModPrefixBoundary(units[i - 1])),
            i + 3 < units.count,
            (units[i] == 109 || units[i] == 77), // m/M
            (units[i + 1] == 111 || units[i + 1] == 79), // o/O
            (units[i + 2] == 100 || units[i + 2] == 68) // d/D
        {
            var lookahead = i + 3
            while lookahead < units.count && isAsciiWhitespaceUnit(units[lookahead]) {
                lookahead += 1
            }
            if lookahead < units.count && units[lookahead] == 43 { // '+'
                out.append(contentsOf: modUnits)
                replaced = true
                i += 3
                continue
            }
        }
        out.append(units[i])
        i += 1
    }

    guard replaced else {
        return nil
    }
    return String(decoding: out, as: UTF16.self)
}

private func createModDisplays(_ input: String) -> [String] {
    if input.contains(",") {
        return [input]
    }
    let trimmed = keymapTrimWhitespace(input)
    if trimmed.contains(" ") {
        return splitByWhitespace(trimmed)
    }
    return [input]
}

/// Adds a platform-aware `mod+...` modifier alias. `mod` resolves to the host's primary
/// modifier (`super` on macOS, `ctrl` elsewhere), with `ctrl` as the fallback when unknown.
// parity: keymap/src/addons/universal/mod-bindings.ts#registerModBindings [status=implemented hash=9a1414d807ce]
@discardableResult
public func registerModBindings<Host: KeymapHost>(
    _ keymap: Keymap<Host>
) throws -> @Sendable () -> Void {
    try keymap.acquireResource(key: MOD_BINDINGS_RESOURCE) {
        let expandModBinding: BindingExpander = { [weak keymap] ctx in
            let metadata = keymap?.getHostMetadata() ?? .default
            let modifier = resolveModModifier(metadata)
            guard let rewritten = replaceModModifier(ctx.input, with: modifier) else {
                return nil
            }
            return [
                BindingExpansion(
                    key: rewritten,
                    displays: ctx.displays ?? createModDisplays(ctx.input)
                )
            ]
        }
        return keymap.appendBindingExpander(expandModBinding)
    }
}

// MARK: - Unresolved Command Warnings (addons/universal/unresolved-commands.ts)

private let UNRESOLVED_COMMAND_WARNINGS_RESOURCE = "keymap:unresolved-command-warnings"

/// Warns when a string command name cannot be resolved by registered commands or resolvers.
// parity: keymap/src/addons/universal/unresolved-commands.ts#registerUnresolvedCommandWarnings [status=implemented hash=065343fb3d19]
@discardableResult
public func registerUnresolvedCommandWarnings<Host: KeymapHost>(
    _ keymap: Keymap<Host>
) throws -> @Sendable () -> Void {
    try keymap.acquireResource(key: UNRESOLVED_COMMAND_WARNINGS_RESOURCE) {
        keymap.appendLayerAnalyzer { ctx in
            for binding in ctx.bindings {
                guard let commandName = binding.command?.commandName else {
                    continue
                }
                if ctx.checkCommandResolution(commandName) != .unresolved {
                    continue
                }
                let sequence =
                    (try? stringifyKeySequence(
                        binding.parsedBinding.sequence.map { .part($0) },
                        options: StringifyOptions(preferDisplay: true)
                    )) ?? binding.parsedBinding.sequence.map(\.display).joined()
                let sourceKey: String
                switch binding.parsedBinding.key {
                case .string(let s):
                    sourceKey = s
                case .stroke(let stroke):
                    sourceKey = (try? stringifyKeyStroke(.stroke(stroke))) ?? stroke.name
                }
                ctx.warnOnce(
                    key: "unresolved:\(binding.sourceLayerOrder):\(binding.bindingIndex):\(commandName):\(sourceKey)",
                    code: "unresolved-command",
                    detail: commandName,
                    message: "[Keymap] Unresolved command \"\(commandName)\" for binding \"\(sequence)\""
                )
            }
        }
    }
}
