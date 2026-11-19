// Pure Swift 6 port of keymap/src/services/compiler.ts, schema.ts,
// primitives/bindings.ts, primitives/command-normalization.ts, and addons/universal/default-parser.ts.

// MARK: - Reserved Schema Fields

// parity: keymap/src/schema.ts#RESERVED_COMMAND_FIELDS [status=implemented hash=fdda056af42c]
public let RESERVED_COMMAND_FIELDS: Set<String> = ["name", "run", "fields", "attrs", "rejectedResult"]

// parity: keymap/src/schema.ts#RESERVED_BINDING_FIELDS [status=implemented hash=3d70442b1245]
public let RESERVED_BINDING_FIELDS: Set<String> = ["key", "cmd", "event", "preventDefault", "fallthrough"]

// parity: keymap/src/schema.ts#RESERVED_LAYER_FIELDS [status=implemented hash=00c3f12023fd]
public let RESERVED_LAYER_FIELDS: Set<String> = ["target", "targetMode", "priority", "bindings", "commands"]

// MARK: - Compiler Errors & Core Binding Types

public enum KeymapCompileError: Error, Equatable, Sendable {
    case emptySequence
    case noBindingParsersRegistered
    case parserDidNotAdvance(input: String, index: Int)
    case noParserHandledInput(input: String, index: Int)
    case expectedSingleKeyStroke(input: String)
    case multipleKeyNamesNotSupported(input: String)
    case missingKeyName(input: String)
    case emptyCommand
    case emptyCommandName
    case commandNameContainsWhitespace(name: String)
    case invalidBindingEvent(String)
    case releaseBindingSingleStrokeOnly
    case unboundedTerminalPattern
    case exactPrefixAmbiguity
    case emptyExpanderResult(input: String)
    case expansionDisplaysLengthMismatch(input: String)
    case invalidBindings(reason: String)
}

public enum KeyLike: Equatable, Hashable, Sendable, ExpressibleByStringLiteral {
    case string(String)
    case stroke(KeyStrokeInput)

    public init(stringLiteral value: String) {
        self = .string(value)
    }

    internal var descriptionForDiagnostics: String {
        switch self {
        case .string(let s): return s
        case .stroke(let stroke): return stroke.name
        }
    }
}

public enum BindingEvent: String, Equatable, Hashable, Sendable, Codable {
    case press
    case release
}

public struct ResolvedKeyToken: Equatable, Hashable, Sendable {
    public let stroke: NormalizedKeyStroke
    public let match: KeyMatch

    public init(stroke: NormalizedKeyStroke, match: KeyMatch) {
        self.stroke = stroke
        self.match = match
    }
}

public struct SequencePatternMatch: Equatable, Sendable {
    public let value: KeymapValue?
    public let display: String?

    public init(value: KeymapValue? = nil, display: String? = nil) {
        self.value = value
        self.display = display
    }
}

/// Metadata-only view of a sequence pattern exposed to binding parsers and sequence trees.
public struct SequencePatternDescriptor: Equatable, Hashable, Sendable {
    public let name: String
    public let display: String?
    public let payloadKey: String
    public let match: KeyMatch
    public let min: Int
    public let max: Int

    public init(
        name: String,
        display: String? = nil,
        payloadKey: String? = nil,
        match: KeyMatch? = nil,
        min: Int = 1,
        max: Int = Int.max
    ) {
        self.name = name
        self.display = display
        self.payloadKey = payloadKey ?? name
        self.match = match ?? "pattern:\(name)"
        self.min = min
        self.max = max
    }
}

/// Event-typed sequence pattern with matcher and optional finalizer.
public struct ResolvedSequencePattern<Event: KeymapEvent>: Sendable {
    public let name: String
    public let display: String?
    public let payloadKey: String
    public let match: KeyMatch
    public let min: Int
    public let max: Int
    public let matcher: @Sendable (Event) throws -> SequencePatternMatch?
    public let finalize: (@Sendable ([KeymapValue]) throws -> KeymapValue)?

    public init(
        name: String,
        display: String? = nil,
        payloadKey: String? = nil,
        match: KeyMatch? = nil,
        min: Int = 1,
        max: Int = Int.max,
        matcher: @escaping @Sendable (Event) throws -> SequencePatternMatch?,
        finalize: (@Sendable ([KeymapValue]) throws -> KeymapValue)? = nil
    ) {
        self.name = name
        self.display = display
        self.payloadKey = payloadKey ?? name
        self.match = match ?? "pattern:\(name)"
        self.min = min
        self.max = max
        self.matcher = matcher
        self.finalize = finalize
    }

    public var descriptor: SequencePatternDescriptor {
        SequencePatternDescriptor(
            name: name,
            display: display,
            payloadKey: payloadKey,
            match: match,
            min: min,
            max: max
        )
    }
}

public struct CommandContext<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public let event: Event
    public let focused: Target?
    public let target: Target?
    public let data: EventData
    public let input: String
    public let payload: KeymapValue?

    public init(
        event: Event,
        focused: Target? = nil,
        target: Target? = nil,
        data: EventData = [:],
        input: String = "",
        payload: KeymapValue? = nil
    ) {
        self.event = event
        self.focused = focused
        self.target = target
        self.data = data
        self.input = input
        self.payload = payload
    }
}

public typealias CommandHandler<Target: Hashable & Sendable, Event: KeymapEvent> =
    @Sendable (CommandContext<Target, Event>) throws -> Bool?

public enum BindingCommand<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    case named(String)
    case handler(CommandHandler<Target, Event>)

    public var commandName: String? {
        if case .named(let name) = self { return name }
        return nil
    }

    public var handlerClosure: CommandHandler<Target, Event>? {
        if case .handler(let fn) = self { return fn }
        return nil
    }
}

/// Declarative keymap binding definition prior to compilation.
public struct Binding<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public var key: KeyLike
    public var cmd: BindingCommand<Target, Event>?
    public var event: BindingEvent?
    public var preventDefault: Bool?
    public var `fallthrough`: Bool?
    public var fields: [String: KeymapValue]

    public init(
        key: KeyLike,
        cmd: BindingCommand<Target, Event>? = nil,
        event: BindingEvent? = nil,
        preventDefault: Bool? = nil,
        fallthrough isFallthrough: Bool? = nil,
        fields: [String: KeymapValue] = [:]
    ) {
        self.key = key
        self.cmd = cmd
        self.event = event
        self.preventDefault = preventDefault
        self.`fallthrough` = isFallthrough
        self.fields = fields
    }

    public init(
        key: KeyLike,
        commandName: String,
        event: BindingEvent? = nil,
        preventDefault: Bool? = nil,
        fallthrough isFallthrough: Bool? = nil,
        fields: [String: KeymapValue] = [:]
    ) {
        self.init(
            key: key,
            cmd: .named(commandName),
            event: event,
            preventDefault: preventDefault,
            fallthrough: isFallthrough,
            fields: fields
        )
    }
}

/// Parsed binding representation passed through binding transformers and stored on `BindingState`.
public struct ParsedBinding<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public var key: KeyLike
    public var sequence: [KeySequencePart]
    public var cmd: BindingCommand<Target, Event>?
    public var event: BindingEvent?
    public var preventDefault: Bool?
    public var `fallthrough`: Bool?
    public var fields: [String: KeymapValue]

    public init(
        key: KeyLike,
        sequence: [KeySequencePart],
        cmd: BindingCommand<Target, Event>? = nil,
        event: BindingEvent? = nil,
        preventDefault: Bool? = nil,
        fallthrough isFallthrough: Bool? = nil,
        fields: [String: KeymapValue] = [:]
    ) {
        self.key = key
        self.sequence = sequence
        self.cmd = cmd
        self.event = event
        self.preventDefault = preventDefault
        self.`fallthrough` = isFallthrough
        self.fields = fields
    }
}

/// Compiled binding runtime state with reference identity (matching JS object identity in pending captures).
public final class BindingState<Target: Hashable & Sendable, Event: KeymapEvent>: RuntimeMatchable, @unchecked Sendable {
    public let binding: Binding<Target, Event>
    public let sequence: [KeySequencePart]
    public var command: BindingCommand<Target, Event>?
    public var run: CommandHandler<Target, Event>?
    public let event: BindingEvent
    public let parsedBinding: ParsedBinding<Target, Event>
    public let sourceTarget: Target?
    public let sourceLayerOrder: Int
    public let bindingIndex: Int
    public let requires: [KeymapRequirement]
    public let matchers: [RuntimeMatcher]
    public let preventDefault: Bool
    public let `fallthrough`: Bool
    public let attrs: Attributes?

    public init(
        binding: Binding<Target, Event>,
        sequence: [KeySequencePart],
        command: BindingCommand<Target, Event>?,
        run: CommandHandler<Target, Event>? = nil,
        event: BindingEvent = .press,
        parsedBinding: ParsedBinding<Target, Event>,
        sourceTarget: Target? = nil,
        sourceLayerOrder: Int = 0,
        bindingIndex: Int = 0,
        requires: [KeymapRequirement] = [],
        matchers: [RuntimeMatcher] = [],
        preventDefault: Bool = true,
        fallthrough isFallthrough: Bool = false,
        attrs: Attributes? = nil
    ) {
        self.binding = binding
        self.sequence = sequence
        self.command = command
        self.run = run ?? command?.handlerClosure
        self.event = event
        self.parsedBinding = parsedBinding
        self.sourceTarget = sourceTarget
        self.sourceLayerOrder = sourceLayerOrder
        self.bindingIndex = bindingIndex
        self.requires = requires
        self.matchers = matchers
        self.preventDefault = preventDefault
        self.`fallthrough` = isFallthrough
        self.attrs = attrs
    }
}

public struct BindingCompilationResult<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public let bindings: [BindingState<Target, Event>]
    public let hasTokenBindings: Bool

    public init(bindings: [BindingState<Target, Event>], hasTokenBindings: Bool) {
        self.bindings = bindings
        self.hasTokenBindings = hasTokenBindings
    }
}

// MARK: - Command Normalization Primitives

// parity: keymap/src/services/primitives/command-normalization.ts#normalizeBindingCommand [status=implemented hash=c6b48f381837]
public func normalizeBindingCommand<Target: Hashable & Sendable, Event: KeymapEvent>(
    _ command: BindingCommand<Target, Event>?
) throws(KeymapCompileError) -> BindingCommand<Target, Event>? {
    guard let command else {
        return nil
    }
    switch command {
    case .handler:
        return command
    case .named(let raw):
        let trimmed = keymapTrimWhitespace(raw)
        if trimmed.isEmpty {
            throw .emptyCommand
        }
        return .named(trimmed)
    }
}

// parity: keymap/src/services/primitives/command-normalization.ts#normalizeCommandName [status=implemented hash=930d145b8fb9]
public func normalizeCommandName(_ name: String) throws(KeymapCompileError) -> String {
    let trimmed = keymapTrimWhitespace(name)
    if trimmed.isEmpty {
        throw .emptyCommandName
    }
    if keymapContainsWhitespace(trimmed) {
        throw .commandNameContainsWhitespace(name: name)
    }
    return trimmed
}

// MARK: - Binding Validation & Snapshotting Primitives

public enum BindingsValidationResult: Equatable, Sendable {
    case ok
    case invalid(reason: String)

    public var isOK: Bool {
        if case .ok = self { return true }
        return false
    }
}

// parity: keymap/src/services/primitives/bindings.ts#validateBindings [status=implemented hash=914b440e0603]
public func validateBindings<Target: Hashable & Sendable, Event: KeymapEvent>(
    _ bindings: [Binding<Target, Event>]?
) -> BindingsValidationResult {
    guard let bindings else {
        return .invalid(reason: "Invalid keymap bindings: expected an array of binding objects")
    }
    for (index, binding) in bindings.enumerated() {
        switch binding.key {
        case .string:
            break
        case .stroke(let stroke):
            if keymapTrimWhitespace(stroke.name).isEmpty {
                return .invalid(
                    reason:
                        "Invalid keymap binding at index \(index): expected \"key\" to be a string or keystroke object"
                )
            }
        }
    }
    return .ok
}

// parity: keymap/src/services/primitives/bindings.ts#snapshotBindings [status=implemented hash=793868975fbe]
public func snapshotBindings<Target: Hashable & Sendable, Event: KeymapEvent>(
    _ bindings: [Binding<Target, Event>]
) throws(KeymapCompileError) -> [Binding<Target, Event>] {
    let validation = validateBindings(bindings)
    if case .invalid(let reason) = validation {
        throw .invalidBindings(reason: reason)
    }
    return bindings
}

// parity: keymap/src/services/primitives/bindings.ts#snapshotParsedBinding [status=implemented hash=68bfa9dc2591]
public func snapshotParsedBinding<Target: Hashable & Sendable, Event: KeymapEvent>(
    _ binding: ParsedBinding<Target, Event>
) -> ParsedBinding<Target, Event> {
    var copy = binding
    copy.sequence = cloneKeySequence(binding.sequence)
    return copy
}

// MARK: - Parser, Expander & Transformer Contracts

public struct BindingExpansion: Equatable, Sendable {
    public let key: String
    public let displays: [String]?

    public init(key: String, displays: [String]? = nil) {
        self.key = key
        self.displays = displays
    }
}

public struct BindingExpanderContext: Sendable {
    public let input: String
    public let displays: [String]?
    public let layer: [String: KeymapValue]

    public init(input: String, displays: [String]? = nil, layer: [String: KeymapValue] = [:]) {
        self.input = input
        self.displays = displays
        self.layer = layer
    }
}

public typealias BindingExpander = @Sendable (BindingExpanderContext) throws -> [BindingExpansion]?

public struct BindingParserResult: Equatable, Sendable {
    public let parts: [KeySequencePart]
    public let nextIndex: Int
    public let usedTokens: [String]
    public let unknownTokens: [String]

    public init(
        parts: [KeySequencePart],
        nextIndex: Int,
        usedTokens: [String] = [],
        unknownTokens: [String] = []
    ) {
        self.parts = parts
        self.nextIndex = nextIndex
        self.usedTokens = usedTokens
        self.unknownTokens = unknownTokens
    }
}

public struct BindingParserContext: Sendable {
    public let input: String
    /// UTF-16 code-unit offset into `input`, matching JavaScript string indexing.
    public let index: Int
    public let layer: [String: KeymapValue]
    public let tokens: [String: ResolvedKeyToken]
    public let patterns: [String: SequencePatternDescriptor]

    public init(
        input: String,
        index: Int,
        layer: [String: KeymapValue] = [:],
        tokens: [String: ResolvedKeyToken] = [:],
        patterns: [String: SequencePatternDescriptor] = [:]
    ) {
        self.input = input
        self.index = index
        self.layer = layer
        self.tokens = tokens
        self.patterns = patterns
    }

    public func normalizeTokenName(_ token: String) throws(KeymapError) -> String {
        try normalizeBindingTokenName(token)
    }

    public func createMatch(_ id: String) throws(KeymapError) -> KeyMatch {
        try createTextKeyMatch(id)
    }

    public func parseObjectKey(
        _ key: KeyStrokeInput,
        display: String? = nil,
        match: KeyMatch? = nil,
        tokenName: String? = nil
    ) throws(KeymapError) -> KeySequencePart {
        try createKeySequencePart(key, display: display, match: match, tokenName: tokenName)
    }
}

public typealias BindingParser = @Sendable (BindingParserContext) throws -> BindingParserResult?

public final class BindingTransformerContext<Target: Hashable & Sendable, Event: KeymapEvent>: @unchecked Sendable {
    public let layer: [String: KeymapValue]
    private let parseKeyHandler: (KeyLike) throws -> KeySequencePart
    private let addHandler: (ParsedBinding<Target, Event>) -> Void
    private let skipHandler: () -> Void

    internal init(
        layer: [String: KeymapValue],
        parseKey: @escaping (KeyLike) throws -> KeySequencePart,
        add: @escaping (ParsedBinding<Target, Event>) -> Void,
        skipOriginal: @escaping () -> Void
    ) {
        self.layer = layer
        self.parseKeyHandler = parseKey
        self.addHandler = add
        self.skipHandler = skipOriginal
    }

    public func parseKey(_ key: KeyLike) throws -> KeySequencePart {
        try parseKeyHandler(key)
    }

    public func add(_ binding: ParsedBinding<Target, Event>) {
        addHandler(snapshotParsedBinding(binding))
    }

    public func skipOriginal() {
        skipHandler()
    }
}

public typealias BindingTransformer<Target: Hashable & Sendable, Event: KeymapEvent> =
    @Sendable (inout ParsedBinding<Target, Event>, BindingTransformerContext<Target, Event>) throws -> Void

public struct EventMatchResolverContext: Sendable {
    private let resolveKeyHandler: @Sendable (KeyLike) throws -> KeyMatch

    public init(resolveKey: @escaping @Sendable (KeyLike) throws -> KeyMatch) {
        self.resolveKeyHandler = resolveKey
    }

    public func resolveKey(_ key: KeyLike) throws -> KeyMatch {
        try resolveKeyHandler(key)
    }
}

public typealias EventMatchResolver<Event: KeymapEvent> =
    @Sendable (Event, EventMatchResolverContext) throws -> [KeyMatch]?

// MARK: - Built-in Default Binding Parser (addons/universal/default-parser.ts)

// parity: keymap/src/addons/universal/default-parser.ts#namedSingleStrokeKeys [status=implemented hash=f30801ed197e]
public let namedSingleStrokeKeys: Set<String> = [
    "up", "down", "left", "right", "clear", "escape", "return", "linefeed", "enter", "tab",
    "backspace", "delete", "insert", "home", "end", "pageup", "pagedown", "space", "lt", "gt",
    "plus", "minus", "equal", "comma", "period", "slash", "backslash", "semicolon", "quote",
    "backquote", "leftbracket", "rightbracket", "capslock", "numlock", "scrolllock",
    "printscreen", "pause", "menu", "apps",
    "kp0", "kp1", "kp2", "kp3", "kp4", "kp5", "kp6", "kp7", "kp8", "kp9",
    "kpdecimal", "kpdivide", "kpmultiply", "kpminus", "kpplus", "kpenter", "kpequal",
    "kpseparator", "kpleft", "kpright", "kpup", "kpdown", "kppageup", "kppagedown",
    "kphome", "kpend", "kpinsert", "kpdelete",
    "mediaplay", "mediapause", "mediaplaypause", "mediareverse", "mediastop",
    "mediafastforward", "mediarewind", "medianext", "mediaprev", "mediarecord",
    "volumedown", "volumeup", "mute",
    "leftshift", "leftctrl", "leftalt", "leftsuper", "lefthyper", "leftmeta",
    "rightshift", "rightctrl", "rightalt", "rightsuper", "righthyper", "rightmeta",
    "iso_level3_shift", "iso_level5_shift",
    "option", "alt", "meta", "super", "hyper", "control", "ctrl", "shift",
]

// parity: keymap/src/addons/universal/default-parser.ts#modifierKeyNames [status=implemented hash=f076c5266e24]
public let modifierKeyNames: Set<String> = [
    "ctrl", "control", "shift", "meta", "alt", "option", "super", "hyper",
]

private let namedSingleStrokeKeyBuckets: [UInt16: [String]] = buildPrefixBuckets(namedSingleStrokeKeys)
private let modifierKeyBuckets: [UInt16: [String]] = buildPrefixBuckets(modifierKeyNames)

private func buildPrefixBuckets(_ values: Set<String>) -> [UInt16: [String]] {
    var buckets: [UInt16: [String]] = [:]
    for value in values {
        guard let first = value.utf16.first else { continue }
        buckets[first, default: []].append(value)
    }
    for key in buckets.keys {
        buckets[key]?.sort { lhs, rhs in
            if lhs.utf16.count != rhs.utf16.count {
                return lhs.utf16.count > rhs.utf16.count
            }
            return lhs < rhs
        }
    }
    return buckets
}

private func toLowerAscii(_ code: UInt16) -> UInt16 {
    (code >= 65 && code <= 90) ? (code + 32) : code
}

private func isAsciiDigit(_ code: UInt16) -> Bool {
    code >= 48 && code <= 57
}

private func utf16CodeUnit(at offset: Int, in units: [UInt16]) -> UInt16? {
    guard offset >= 0 && offset < units.count else { return nil }
    return units[offset]
}

private func startsWithAsciiInsensitive(_ units: [UInt16], prefix: String, at offset: Int) -> Bool {
    let prefixUnits = Array(prefix.utf16)
    if offset + prefixUnits.count > units.count {
        return false
    }
    for i in 0..<prefixUnits.count {
        if toLowerAscii(units[offset + i]) != prefixUnits[i] {
            return false
        }
    }
    return true
}

private func findBucketedPrefixMatch(
    _ buckets: [UInt16: [String]],
    units: [UInt16],
    at offset: Int
) -> String? {
    guard let first = utf16CodeUnit(at: offset, in: units),
        let candidates = buckets[toLowerAscii(first)]
    else {
        return nil
    }
    for candidate in candidates {
        if startsWithAsciiInsensitive(units, prefix: candidate, at: offset) {
            return candidate
        }
    }
    return nil
}

private func findNamedSingleStrokeKey(units: [UInt16], at offset: Int) -> String? {
    if let named = findBucketedPrefixMatch(namedSingleStrokeKeyBuckets, units: units, at: offset) {
        return named
    }
    guard let c0 = utf16CodeUnit(at: offset, in: units),
        toLowerAscii(c0) == 102, // 'f'
        let c1 = utf16CodeUnit(at: offset + 1, in: units),
        isAsciiDigit(c1)
    else {
        return nil
    }
    let hasSecondDigit = utf16CodeUnit(at: offset + 2, in: units).map(isAsciiDigit) ?? false
    let end = hasSecondDigit ? offset + 3 : offset + 2
    return String(decoding: units[offset..<end], as: UTF16.self).lowercased()
}

private func parseStringKeyPart(_ input: String, ctx: BindingParserContext) throws -> KeySequencePart {
    if input == " " {
        return try ctx.parseObjectKey(KeyStrokeInput(name: "space"), display: "space")
    }
    if input == "+" {
        return try ctx.parseObjectKey(KeyStrokeInput(name: "+"), display: "+")
    }

    let rawParts = input.split(separator: "+", omittingEmptySubsequences: false)
    var name = ""
    var displayName = ""
    var ctrl = false
    var shift = false
    var meta = false
    var superKey = false
    var hyper = false

    for rawPart in rawParts {
        let part = keymapTrimWhitespace(String(rawPart))
        if part.isEmpty {
            continue
        }
        let lowered = part.lowercased()
        switch lowered {
        case "ctrl", "control":
            ctrl = true
        case "shift":
            shift = true
        case "meta", "alt", "option":
            meta = true
        case "super":
            superKey = true
        case "hyper":
            hyper = true
        default:
            if !name.isEmpty {
                throw KeymapCompileError.multipleKeyNamesNotSupported(input: input)
            }
            name = part
            displayName = lowered
        }
    }

    if name.isEmpty {
        throw KeymapCompileError.missingKeyName(input: input)
    }

    var displayParts: [String] = []
    if ctrl { displayParts.append("ctrl") }
    if shift { displayParts.append("shift") }
    if meta { displayParts.append("meta") }
    if superKey { displayParts.append("super") }
    if hyper { displayParts.append("hyper") }
    displayParts.append(displayName)

    return try ctx.parseObjectKey(
        KeyStrokeInput(
            name: name,
            ctrl: ctrl,
            shift: shift,
            meta: meta,
            super: superKey,
            hyper: hyper ? true : nil
        ),
        display: displayParts.joined(separator: "+")
    )
}

private func nextCharacterSlice(units: [UInt16], at offset: Int) -> (text: String, length: Int)? {
    guard offset < units.count else { return nil }
    let first = units[offset]
    if (0xD800...0xDBFF).contains(first),
        offset + 1 < units.count,
        (0xDC00...0xDFFF).contains(units[offset + 1])
    {
        return (String(decoding: units[offset..<(offset + 2)], as: UTF16.self), 2)
    }
    return (String(decoding: units[offset..<(offset + 1)], as: UTF16.self), 1)
}

private func parseModifiedKeyPart(
    units: [UInt16],
    at index: Int,
    ctx: BindingParserContext
) throws -> (part: KeySequencePart, nextIndex: Int)? {
    var cursor = index
    var ctrl = false
    var shift = false
    var meta = false
    var superKey = false
    var hyper = false

    while cursor < units.count {
        guard let modifier = findBucketedPrefixMatch(modifierKeyBuckets, units: units, at: cursor) else {
            break
        }
        let plusIndex = cursor + modifier.utf16.count
        guard utf16CodeUnit(at: plusIndex, in: units) == 43 else { // '+'
            break
        }
        switch modifier {
        case "ctrl", "control": ctrl = true
        case "shift": shift = true
        case "meta", "alt", "option": meta = true
        case "super": superKey = true
        case "hyper": hyper = true
        default: break
        }
        cursor = plusIndex + 1
    }

    if cursor == index {
        return nil
    }

    guard let charSlice = nextCharacterSlice(units: units, at: cursor) else {
        let slice = String(decoding: units[index..<units.count], as: UTF16.self)
        throw KeymapCompileError.missingKeyName(input: slice)
    }

    let named = findNamedSingleStrokeKey(units: units, at: cursor)
    let name = named ?? charSlice.text
    let advanceLen = named?.utf16.count ?? charSlice.length
    let displayName: String =
        if name == " " {
            "space"
        } else if name == "+" {
            "+"
        } else {
            name.lowercased()
        }

    var displayParts: [String] = []
    if ctrl { displayParts.append("ctrl") }
    if shift { displayParts.append("shift") }
    if meta { displayParts.append("meta") }
    if superKey { displayParts.append("super") }
    if hyper { displayParts.append("hyper") }
    displayParts.append(displayName)

    let part = try ctx.parseObjectKey(
        KeyStrokeInput(
            name: name == " " ? "space" : name,
            ctrl: ctrl,
            shift: shift,
            meta: meta,
            super: superKey,
            hyper: hyper ? true : nil
        ),
        display: displayParts.joined(separator: "+")
    )
    return (part, cursor + advanceLen)
}

// parity: keymap/src/addons/universal/default-parser.ts#defaultBindingParser [status=implemented hash=808439d81331]
public let defaultBindingParser: BindingParser = { ctx in
    let input = ctx.input
    let index = ctx.index
    let units = Array(input.utf16)

    if index == 0 && input.contains("+") && keymapContainsWhitespace(input) {
        return BindingParserResult(
            parts: [try parseStringKeyPart(input, ctx: ctx)],
            nextIndex: units.count
        )
    }

    guard let charSlice = nextCharacterSlice(units: units, at: index) else {
        return nil
    }

    if charSlice.text == "<" {
        if let end = units[index..<units.count].firstIndex(of: 62) { // '>'
            let inner = String(decoding: units[(index + 1)..<end], as: UTF16.self)
            let tokenName = try ctx.normalizeTokenName(inner)
            guard let token = ctx.tokens[tokenName] else {
                return BindingParserResult(
                    parts: [],
                    nextIndex: end + 1,
                    unknownTokens: [tokenName]
                )
            }
            let part = try ctx.parseObjectKey(
                token.stroke.asStrokeInput,
                display: "<\(tokenName)>",
                match: token.match,
                tokenName: tokenName
            )
            return BindingParserResult(
                parts: [part],
                nextIndex: end + 1,
                usedTokens: [tokenName]
            )
        }
        return BindingParserResult(
            parts: [try parseStringKeyPart(charSlice.text, ctx: ctx)],
            nextIndex: index + charSlice.length
        )
    }

    if charSlice.text == "{" {
        if let end = units[index..<units.count].firstIndex(of: 125) { // '}'
            let inner = String(decoding: units[(index + 1)..<end], as: UTF16.self)
            let patternName = try ctx.normalizeTokenName(inner)
            guard let pattern = ctx.patterns[patternName] else {
                return BindingParserResult(
                    parts: [],
                    nextIndex: end + 1,
                    unknownTokens: [patternName]
                )
            }
            let basePart = try ctx.parseObjectKey(
                KeyStrokeInput(name: patternName, ctrl: false, shift: false, meta: false, super: false),
                display: pattern.display ?? "{\(patternName)}",
                match: pattern.match
            )
            let patternPart = KeySequencePart(
                stroke: basePart.stroke,
                display: basePart.display,
                match: basePart.match,
                tokenName: basePart.tokenName,
                patternName: pattern.name,
                payloadKey: pattern.payloadKey
            )
            return BindingParserResult(
                parts: [patternPart],
                nextIndex: end + 1,
                usedTokens: [patternName]
            )
        }
        return BindingParserResult(
            parts: [try parseStringKeyPart(charSlice.text, ctx: ctx)],
            nextIndex: index + charSlice.length
        )
    }

    if let modified = try parseModifiedKeyPart(units: units, at: index, ctx: ctx) {
        return BindingParserResult(parts: [modified.part], nextIndex: modified.nextIndex)
    }

    if let named = findNamedSingleStrokeKey(units: units, at: index) {
        let normalized = keymapTrimWhitespace(named).lowercased()
        let part = try ctx.parseObjectKey(KeyStrokeInput(name: normalized), display: normalized)
        return BindingParserResult(parts: [part], nextIndex: index + named.utf16.count)
    }

    return BindingParserResult(
        parts: [try parseStringKeyPart(charSlice.text, ctx: ctx)],
        nextIndex: index + charSlice.length
    )
}

// parity: keymap/src/addons/universal/default-parser.ts#defaultEventMatchResolver [status=implemented hash=fb36d6e59812]
public func defaultEventMatchResolver<Event: KeymapEvent>(
    _ event: Event,
    ctx: EventMatchResolverContext
) throws -> [KeyMatch] {
    [
        try ctx.resolveKey(
            .stroke(
                KeyStrokeInput(
                    name: event.name,
                    ctrl: event.ctrl,
                    shift: event.shift,
                    meta: event.meta,
                    super: event.`super` ?? false,
                    hyper: event.hyper == true ? true : nil
                )
            )
        )
    ]
}

// MARK: - Compiler Service

public enum FieldKind: String, Equatable, Sendable {
    case binding
    case layer
}

// parity: keymap/src/services/compiler.ts#CompilerOptions [status=implemented hash=f6d57ee92bff]
public struct CompilerOptions: Sendable {
    public let warnUnknownField: @Sendable (FieldKind, String) -> Void
    public let warnUnknownToken: @Sendable (String, String) -> Void

    public init(
        warnUnknownField: @escaping @Sendable (FieldKind, String) -> Void = { _, _ in },
        warnUnknownToken: @escaping @Sendable (String, String) -> Void = { _, _ in }
    ) {
        self.warnUnknownField = warnUnknownField
        self.warnUnknownToken = warnUnknownToken
    }
}

/// Configuration state consumed by `CompilerService`.
public final class CompilerEnvironment<Target: Hashable & Sendable, Event: KeymapEvent>: @unchecked Sendable {
    public var tokens: [String: ResolvedKeyToken]
    public var patterns: [String: ResolvedSequencePattern<Event>]
    public var bindingExpanders: [BindingExpander]
    public var bindingParsers: [BindingParser]
    public var bindingTransformers: [BindingTransformer<Target, Event>]
    public var bindingFields: [String: FieldCompiler]
    public var allowExactPrefixAmbiguity: Bool

    public init(
        tokens: [String: ResolvedKeyToken] = [:],
        patterns: [String: ResolvedSequencePattern<Event>] = [:],
        bindingExpanders: [BindingExpander] = [],
        bindingParsers: [BindingParser] = [defaultBindingParser],
        bindingTransformers: [BindingTransformer<Target, Event>] = [],
        bindingFields: [String: FieldCompiler] = [:],
        allowExactPrefixAmbiguity: Bool = false
    ) {
        self.tokens = tokens
        self.patterns = patterns
        self.bindingExpanders = bindingExpanders
        self.bindingParsers = bindingParsers
        self.bindingTransformers = bindingTransformers
        self.bindingFields = bindingFields
        self.allowExactPrefixAmbiguity = allowExactPrefixAmbiguity
    }

    internal var patternDescriptors: [String: SequencePatternDescriptor] {
        patterns.mapValues(\.descriptor)
    }
}

// parity: keymap/src/services/compiler.ts#CompilerService [status=implemented hash=2664732b0cdf]
public protocol CompilerService<Target, Event>: AnyObject, Sendable {
    associatedtype Target: Hashable & Sendable
    associatedtype Event: KeymapEvent

    func parseTokenKey(_ key: KeyLike) throws -> KeySequencePart
    func parseKeySequence(_ key: KeyLike) throws -> [KeySequencePart]
    func formatKey(_ key: KeyLike, options: StringifyOptions?) throws -> String
    func compileBindings(
        _ bindings: [Binding<Target, Event>],
        tokens: [String: ResolvedKeyToken],
        sourceTarget: Target?,
        sourceLayerOrder: Int,
        fields: [String: KeymapValue]?
    ) -> BindingCompilationResult<Target, Event>
}

private struct ParsedBindingSequenceResult {
    var parts: [KeySequencePart]
    var usedTokens: [String]
    var unknownTokens: [String]
    var hasTokenBindings: Bool
}

private struct ExpandedBindingKey {
    let key: KeyLike
    let displays: [String]?
}

public final class DefaultCompilerService<Target: Hashable & Sendable, Event: KeymapEvent>: CompilerService,
    @unchecked Sendable
{
    private let environment: CompilerEnvironment<Target, Event>
    private let notify: KeymapNotifier
    private let conditions: any ConditionService
    private let options: CompilerOptions

    public init(
        environment: CompilerEnvironment<Target, Event>,
        notify: KeymapNotifier,
        conditions: any ConditionService,
        options: CompilerOptions
    ) {
        self.environment = environment
        self.notify = notify
        self.conditions = conditions
        self.options = options
    }

    public func parseTokenKey(_ key: KeyLike) throws -> KeySequencePart {
        try parseSingleKeyPartWithParsers(
            key,
            parsers: environment.bindingParsers,
            tokens: environment.tokens,
            patterns: environment.patternDescriptors,
            layer: [:]
        )
    }

    public func parseKeySequence(_ key: KeyLike) throws -> [KeySequencePart] {
        switch key {
        case .stroke(let stroke):
            return [try createKeySequencePart(stroke)]
        case .string(let raw):
            let parsed = try parseBindingSequenceWithParsers(
                raw,
                parsers: environment.bindingParsers,
                tokens: environment.tokens,
                patterns: environment.patternDescriptors,
                layer: [:]
            )
            for tokenName in parsed.unknownTokens {
                options.warnUnknownToken(tokenName, raw)
            }
            if !parsed.unknownTokens.isEmpty {
                return []
            }
            return parsed.parts
        }
    }

    public func formatKey(_ key: KeyLike, options stringifyOptions: StringifyOptions? = nil) throws -> String {
        let parts = try parseKeySequence(key)
        return try stringifyKeySequence(parts.map { .part($0) }, options: stringifyOptions)
    }

    public func compileBindings(
        _ bindings: [Binding<Target, Event>],
        tokens: [String: ResolvedKeyToken],
        sourceTarget: Target?,
        sourceLayerOrder: Int,
        fields compileFields: [String: KeymapValue]? = nil
    ) -> BindingCompilationResult<Target, Event> {
        var bindingStates: [BindingState<Target, Event>] = []
        var hasTokenBindings = false
        let bindingExpanders = environment.bindingExpanders
        let bindingParsers = environment.bindingParsers
        let bindingFieldCompilers = environment.bindingFields
        let patternDescriptors = environment.patternDescriptors
        let allowExactPrefixAmbiguity = environment.allowExactPrefixAmbiguity

        for (bindingIndex, binding) in bindings.enumerated() {
            let expandedKeys: [ExpandedBindingKey]
            do {
                expandedKeys = try expandBindingKeyWithExpanders(
                    binding.key,
                    expanders: bindingExpanders,
                    layer: compileFields ?? [:]
                )
            } catch {
                notify.emitError(
                    "binding-expand-error",
                    error: error,
                    message: "Failed to expand keymap binding"
                )
                continue
            }

            for expandedBindingKey in expandedKeys {
                let parsed: ParsedBindingSequenceResult
                do {
                    var initial: ParsedBindingSequenceResult
                    switch expandedBindingKey.key {
                    case .string(let raw):
                        initial = try parseBindingSequenceWithParsers(
                            raw,
                            parsers: bindingParsers,
                            tokens: tokens,
                            patterns: patternDescriptors,
                            layer: compileFields ?? [:]
                        )
                    case .stroke(let stroke):
                        initial = ParsedBindingSequenceResult(
                            parts: [try createKeySequencePart(stroke)],
                            usedTokens: [],
                            unknownTokens: [],
                            hasTokenBindings: false
                        )
                    }
                    parsed = try applyExpansionDisplays(initial, expansion: expandedBindingKey)
                } catch {
                    notify.emitError(
                        "binding-parse-error",
                        error: error,
                        message: "Failed to parse keymap binding"
                    )
                    continue
                }

                let sequence = parsed.parts
                hasTokenBindings = hasTokenBindings || parsed.hasTokenBindings

                for tokenName in parsed.unknownTokens {
                    options.warnUnknownToken(tokenName, expandedBindingKey.key.descriptionForDiagnostics)
                }
                if !parsed.unknownTokens.isEmpty {
                    continue
                }

                let transformedInputs = applyBindingTransformers(
                    binding: binding,
                    sequence: sequence,
                    tokens: tokens,
                    parsers: bindingParsers,
                    patterns: patternDescriptors,
                    compileFields: compileFields
                )

                for compiledInput in transformedInputs {
                    do {
                        let event = compiledInput.event ?? .press
                        let compiledSequence = compiledInput.sequence
                        let accumulator = FieldAccumulator(allowsAttributes: true)

                        for fieldName in compiledInput.fields.keys.sorted() {
                            if fieldName == "sequence" || RESERVED_BINDING_FIELDS.contains(fieldName) {
                                continue
                            }
                            guard let value = compiledInput.fields[fieldName], value != .undefined else {
                                continue
                            }
                            guard let fieldCompiler = bindingFieldCompilers[fieldName] else {
                                options.warnUnknownField(.binding, fieldName)
                                continue
                            }
                            let fieldCtx = createFieldCompilerContext(
                                fieldName: fieldName,
                                conditions: conditions,
                                accumulator: accumulator
                            )
                            try fieldCompiler(value, fieldCtx)
                        }

                        let attrs = accumulator.attrs.isEmpty ? nil : accumulator.attrs
                        let command = try normalizeBindingCommand(compiledInput.cmd)
                        let compiledBinding = BindingState<Target, Event>(
                            binding: binding,
                            sequence: compiledSequence,
                            command: command,
                            run: command?.handlerClosure,
                            event: event,
                            parsedBinding: snapshotParsedBinding(compiledInput),
                            sourceTarget: sourceTarget,
                            sourceLayerOrder: sourceLayerOrder,
                            bindingIndex: bindingIndex,
                            requires: accumulator.orderedRequirements,
                            matchers: accumulator.matchers,
                            preventDefault: compiledInput.preventDefault ?? true,
                            fallthrough: compiledInput.fallthrough ?? false,
                            attrs: attrs
                        )

                        if compiledSequence.isEmpty {
                            continue
                        }

                        if event == .release && compiledSequence.count > 1 {
                            throw KeymapCompileError.releaseBindingSingleStrokeOnly
                        }

                        if let terminalPatternName = compiledSequence.last?.patternName,
                            let pattern = environment.patterns[terminalPatternName],
                            pattern.max != pattern.min
                        {
                            throw KeymapCompileError.unboundedTerminalPattern
                        }

                        if event == .press && !allowExactPrefixAmbiguity {
                            try validateExactPrefixAmbiguity(existing: bindingStates, next: compiledBinding)
                        }

                        bindingStates.append(compiledBinding)
                    } catch {
                        notify.emitError(
                            "binding-compile-error",
                            error: error,
                            message: "Failed to compile keymap binding"
                        )
                    }
                }
            }
        }

        return BindingCompilationResult(bindings: bindingStates, hasTokenBindings: hasTokenBindings)
    }

    private func applyBindingTransformers(
        binding: Binding<Target, Event>,
        sequence: [KeySequencePart],
        tokens: [String: ResolvedKeyToken],
        parsers: [BindingParser],
        patterns: [String: SequencePatternDescriptor],
        compileFields: [String: KeymapValue]?
    ) -> [ParsedBinding<Target, Event>] {
        let transformers = environment.bindingTransformers
        var parsedBinding = ParsedBinding<Target, Event>(
            key: binding.key,
            sequence: cloneKeySequence(sequence),
            cmd: binding.cmd,
            event: binding.event,
            preventDefault: binding.preventDefault,
            fallthrough: binding.fallthrough,
            fields: binding.fields
        )
        if transformers.isEmpty {
            return [parsedBinding]
        }

        var extraBindings: [ParsedBinding<Target, Event>] = []
        var keepOriginal = true
        let layer = compileFields ?? [:]

        for transformer in transformers {
            let ctx = BindingTransformerContext<Target, Event>(
                layer: layer,
                parseKey: { [self] key in
                    try self.parseSingleKeyPartWithParsers(
                        key,
                        parsers: parsers,
                        tokens: tokens,
                        patterns: patterns,
                        layer: layer
                    )
                },
                add: { nextBinding in
                    extraBindings.append(nextBinding)
                },
                skipOriginal: {
                    keepOriginal = false
                }
            )
            do {
                try transformer(&parsedBinding, ctx)
            } catch {
                notify.emitError(
                    "binding-transformer-error",
                    error: error,
                    message: "[Keymap] Error in binding transformer:"
                )
            }
        }

        if !keepOriginal {
            return extraBindings
        }
        if extraBindings.isEmpty {
            return [parsedBinding]
        }
        return [parsedBinding] + extraBindings
    }

    private func parseSingleKeyPartWithParsers(
        _ key: KeyLike,
        parsers: [BindingParser],
        tokens: [String: ResolvedKeyToken],
        patterns: [String: SequencePatternDescriptor],
        layer: [String: KeymapValue]
    ) throws -> KeySequencePart {
        switch key {
        case .stroke(let stroke):
            return try createKeySequencePart(stroke)
        case .string(let raw):
            let parsed = try parseBindingSequenceWithParsers(
                raw,
                parsers: parsers,
                tokens: tokens,
                patterns: patterns,
                layer: layer
            )
            guard parsed.parts.count == 1, let part = parsed.parts.first else {
                throw KeymapCompileError.expectedSingleKeyStroke(input: raw)
            }
            return part
        }
    }
}

// parity: keymap/src/services/compiler.ts#createCompilerService [status=implemented hash=76d515a5c112]
public func createCompilerService<Target: Hashable & Sendable, Event: KeymapEvent>(
    environment: CompilerEnvironment<Target, Event>,
    notify: KeymapNotifier,
    conditions: any ConditionService,
    options: CompilerOptions = CompilerOptions()
) -> DefaultCompilerService<Target, Event> {
    DefaultCompilerService(
        environment: environment,
        notify: notify,
        conditions: conditions,
        options: options
    )
}

// MARK: - Internal Compiler Helpers

private func sequenceMatchesPrefix(_ left: [KeySequencePart], _ right: [KeySequencePart]) -> Bool {
    if left.count >= right.count {
        return false
    }
    for index in 0..<left.count {
        if left[index].match != right[index].match {
            return false
        }
    }
    return true
}

private func validateExactPrefixAmbiguity<Target: Hashable & Sendable, Event: KeymapEvent>(
    existing bindings: [BindingState<Target, Event>],
    next: BindingState<Target, Event>
) throws(KeymapCompileError) {
    for existing in bindings {
        if existing.event != .press {
            continue
        }
        if (existing.command != nil && sequenceMatchesPrefix(existing.sequence, next.sequence))
            || (next.command != nil && sequenceMatchesPrefix(next.sequence, existing.sequence))
        {
            throw .exactPrefixAmbiguity
        }
    }
}

private func expandBindingKeyWithExpanders(
    _ key: KeyLike,
    expanders: [BindingExpander],
    layer: [String: KeymapValue]
) throws -> [ExpandedBindingKey] {
    guard case .string(let rawKey) = key, !expanders.isEmpty else {
        return [ExpandedBindingKey(key: key, displays: nil)]
    }

    var candidates: [BindingExpansion] = [BindingExpansion(key: rawKey, displays: nil)]

    for expander in expanders {
        var nextCandidates: [BindingExpansion] = []
        for candidate in candidates {
            let ctx = BindingExpanderContext(
                input: candidate.key,
                displays: candidate.displays,
                layer: layer
            )
            guard let result = try expander(ctx) else {
                nextCandidates.append(candidate)
                continue
            }
            if result.isEmpty {
                throw KeymapCompileError.emptyExpanderResult(input: candidate.key)
            }
            nextCandidates.append(contentsOf: result)
        }
        candidates = nextCandidates
    }

    return candidates.map { ExpandedBindingKey(key: .string($0.key), displays: $0.displays) }
}

private func applyExpansionDisplays(
    _ parsed: ParsedBindingSequenceResult,
    expansion: ExpandedBindingKey
) throws(KeymapCompileError) -> ParsedBindingSequenceResult {
    guard let displays = expansion.displays else {
        return parsed
    }
    if displays.count != parsed.parts.count {
        throw .expansionDisplaysLengthMismatch(input: expansion.key.descriptionForDiagnostics)
    }
    var updated = parsed
    updated.parts = zip(parsed.parts, displays).map { part, display in
        KeySequencePart(
            stroke: part.stroke,
            display: display,
            match: part.match,
            tokenName: part.tokenName,
            patternName: part.patternName,
            payloadKey: part.payloadKey
        )
    }
    return updated
}

private func parseBindingSequenceWithParsers(
    _ key: String,
    parsers: [BindingParser],
    tokens: [String: ResolvedKeyToken],
    patterns: [String: SequencePatternDescriptor],
    layer: [String: KeymapValue]
) throws -> ParsedBindingSequenceResult {
    let totalUnits = key.utf16.count
    if totalUnits == 0 {
        throw KeymapCompileError.emptySequence
    }
    if parsers.isEmpty {
        throw KeymapCompileError.noBindingParsersRegistered
    }

    var parts: [KeySequencePart] = []
    var usedTokens: [String] = []
    var usedTokenSet: Set<String> = []
    var unknownTokens: [String] = []
    var unknownTokenSet: Set<String> = []

    var index = 0
    while index < totalUnits {
        var matched = false

        for parser in parsers {
            let ctx = BindingParserContext(
                input: key,
                index: index,
                layer: layer,
                tokens: tokens,
                patterns: patterns
            )
            guard let result = try parser(ctx) else {
                continue
            }
            if result.nextIndex <= index || result.nextIndex > totalUnits {
                throw KeymapCompileError.parserDidNotAdvance(input: key, index: index)
            }

            parts.append(contentsOf: result.parts)
            for tokenName in result.usedTokens where usedTokenSet.insert(tokenName).inserted {
                usedTokens.append(tokenName)
            }
            for tokenName in result.unknownTokens where unknownTokenSet.insert(tokenName).inserted {
                unknownTokens.append(tokenName)
            }

            index = result.nextIndex
            matched = true
            break
        }

        if !matched {
            throw KeymapCompileError.noParserHandledInput(input: key, index: index)
        }
    }

    return ParsedBindingSequenceResult(
        parts: parts,
        usedTokens: usedTokens,
        unknownTokens: unknownTokens,
        hasTokenBindings: !usedTokens.isEmpty || !unknownTokens.isEmpty
    )
}
