public enum KeymapError: Error, Equatable, Sendable {
    case emptyToken
    case emptyKeyName
    case emptyMatchID
}

public struct KeyStrokeInput: Equatable, Hashable, Sendable, Codable {
    public let name: String
    public let ctrl: Bool?
    public let shift: Bool?
    public let meta: Bool?
    public let `super`: Bool?
    public let hyper: Bool?

    public init(
        name: String,
        ctrl: Bool? = nil,
        shift: Bool? = nil,
        meta: Bool? = nil,
        super isSuper: Bool? = nil,
        hyper: Bool? = nil
    ) {
        self.name = name
        self.ctrl = ctrl
        self.shift = shift
        self.meta = meta
        self.`super` = isSuper
        self.hyper = hyper
    }
}

public struct NormalizedKeyStroke: Equatable, Hashable, Sendable, Codable {
    public let name: String
    public let ctrl: Bool
    public let shift: Bool
    public let meta: Bool
    public let `super`: Bool
    public let hyper: Bool?

    public init(
        name: String,
        ctrl: Bool = false,
        shift: Bool = false,
        meta: Bool = false,
        super isSuper: Bool = false,
        hyper: Bool? = nil
    ) {
        self.name = name
        self.ctrl = ctrl
        self.shift = shift
        self.meta = meta
        self.`super` = isSuper
        self.hyper = (hyper == true) ? true : nil
    }
}

public struct KeySequencePart: Equatable, Hashable, Sendable, Codable {
    public let stroke: NormalizedKeyStroke
    public let display: String
    public let match: String
    public let tokenName: String?
    public let patternName: String?
    public let payloadKey: String?

    public init(
        stroke: NormalizedKeyStroke,
        display: String,
        match: String,
        tokenName: String? = nil,
        patternName: String? = nil,
        payloadKey: String? = nil
    ) {
        self.stroke = stroke
        self.display = display
        self.match = match
        self.tokenName = tokenName
        self.patternName = patternName
        self.payloadKey = payloadKey
    }
}

public struct StringifyOptions: Equatable, Hashable, Sendable, Codable {
    public let preferDisplay: Bool?
    public let separator: String?

    public init(preferDisplay: Bool? = nil, separator: String? = nil) {
        self.preferDisplay = preferDisplay
        self.separator = separator
    }
}

public enum KeyStringifyInput: Equatable, Hashable, Sendable {
    case stroke(KeyStrokeInput)
    case part(KeySequencePart)
}

// parity: keymap/src/services/keys.ts#normalizeBindingTokenName [status=implemented hash=3f028a11e039]
public func normalizeBindingTokenName(_ token: String) throws(KeymapError) -> String {
    let normalized = trimWhitespace(token).lowercased()
    if normalized.isEmpty {
        throw .emptyToken
    }
    return normalized
}

// parity: keymap/src/services/keys.ts#normalizeKeyName [status=implemented hash=74fd45b4e021]
public func normalizeKeyName(_ name: String) throws(KeymapError) -> String {
    let normalized = trimWhitespace(name).lowercased()
    if normalized.isEmpty {
        throw .emptyKeyName
    }
    return normalized
}

// parity: keymap/src/services/keys.ts#normalizeKeyStroke [status=implemented hash=c6cc65fb3ee7]
public func normalizeKeyStroke(_ input: KeyStrokeInput) throws(KeymapError) -> NormalizedKeyStroke {
    NormalizedKeyStroke(
        name: try normalizeKeyName(input.name),
        ctrl: input.ctrl ?? false,
        shift: input.shift ?? false,
        meta: input.meta ?? false,
        super: input.`super` ?? false,
        hyper: (input.hyper == true) ? true : nil
    )
}

// parity: keymap/src/services/keys.ts#normalizeEventKeyStroke [status=implemented hash=fd317a125a47]
public func normalizeEventKeyStroke(_ input: KeyStrokeInput) throws(KeymapError) -> NormalizedKeyStroke {
    try normalizeKeyStroke(input)
}

// parity: keymap/src/services/keys.ts#cloneKeyStroke [status=implemented hash=550b7c16edc3]
public func cloneKeyStroke(_ stroke: NormalizedKeyStroke) -> NormalizedKeyStroke {
    NormalizedKeyStroke(
        name: stroke.name,
        ctrl: stroke.ctrl,
        shift: stroke.shift,
        meta: stroke.meta,
        super: stroke.`super`,
        hyper: (stroke.hyper == true) ? true : nil
    )
}

// parity: keymap/src/services/keys.ts#createKeySequencePart [status=implemented hash=3f90872913ee]
public func createKeySequencePart(
    _ input: KeyStrokeInput,
    display: String? = nil,
    match: String? = nil,
    tokenName: String? = nil
) throws(KeymapError) -> KeySequencePart {
    let stroke = cloneKeyStroke(try normalizeKeyStroke(input))
    let normalizedToken = try tokenName.map(normalizeBindingTokenName)
    return KeySequencePart(
        stroke: stroke,
        display: display ?? stringifyCanonicalStroke(stroke),
        match: match ?? "key:\(buildKeyMatchId(stroke))",
        tokenName: normalizedToken
    )
}

// parity: keymap/src/services/keys.ts#cloneKeySequencePart [status=implemented hash=3d7219208684]
public func cloneKeySequencePart(_ part: KeySequencePart) -> KeySequencePart {
    KeySequencePart(
        stroke: cloneKeyStroke(part.stroke),
        display: part.display,
        match: part.match,
        tokenName: part.tokenName,
        patternName: part.patternName,
        payloadKey: part.payloadKey
    )
}

// parity: keymap/src/services/keys.ts#cloneKeySequence [status=implemented hash=3ef34f258dac]
public func cloneKeySequence(_ parts: [KeySequencePart]) -> [KeySequencePart] {
    parts.map(cloneKeySequencePart)
}

// parity: keymap/src/services/keys.ts#resolveKeyMatch [status=implemented hash=b4cc9bea89ae]
public func resolveKeyMatch(_ input: KeyStringifyInput) throws(KeymapError) -> String {
    switch input {
    case .part(let part):
        return part.match
    case .stroke(let stroke):
        return try createKeyMatch(stroke)
    }
}

// parity: keymap/src/services/keys.ts#createKeyMatch [status=implemented hash=1d9a010d67a4]
public func createKeyMatch(_ input: KeyStrokeInput) throws(KeymapError) -> String {
    let stroke = try normalizeKeyStroke(input)
    return "key:\(buildKeyMatchId(stroke))"
}

// parity: keymap/src/services/keys.ts#createTextKeyMatch [status=implemented hash=fe28548b4a00]
public func createTextKeyMatch(_ id: String) throws(KeymapError) -> String {
    let normalized = trimWhitespace(id)
    if normalized.isEmpty {
        throw .emptyMatchID
    }
    return "text:\(normalized)"
}

// parity: keymap/src/services/keys.ts#stringifyKeyStroke [status=implemented hash=101ec175cc37]
public func stringifyKeyStroke(
    _ input: KeyStringifyInput,
    options: StringifyOptions? = nil
) throws(KeymapError) -> String {
    switch input {
    case .part(let part):
        if options?.preferDisplay == true && !part.display.isEmpty {
            return part.display
        }
        return stringifyCanonicalStroke(part.stroke)
    case .stroke(let stroke):
        return stringifyCanonicalStroke(try normalizeKeyStroke(stroke))
    }
}

// parity: keymap/src/services/keys.ts#stringifyKeySequence [status=implemented hash=6729afc0b8fe]
public func stringifyKeySequence(
    _ input: [KeyStringifyInput],
    options: StringifyOptions? = nil
) throws(KeymapError) -> String {
    let rendered = try input.map { item throws(KeymapError) -> String in
        try stringifyKeyStroke(item, options: options)
    }
    return rendered.joined(separator: options?.separator ?? "")
}

private func stringifyCanonicalStroke(_ stroke: NormalizedKeyStroke) -> String {
    var parts: [String] = []
    if stroke.ctrl { parts.append("ctrl") }
    if stroke.shift { parts.append("shift") }
    if stroke.meta { parts.append("meta") }
    if stroke.`super` { parts.append("super") }
    if stroke.hyper == true { parts.append("hyper") }
    parts.append(stroke.name == "return" ? "enter" : stroke.name)
    return parts.joined(separator: "+")
}

private func buildKeyMatchId(_ stroke: NormalizedKeyStroke) -> String {
    "\(stroke.name):\(stroke.ctrl ? 1 : 0):\(stroke.shift ? 1 : 0):\(stroke.meta ? 1 : 0):\(stroke.`super` ? 1 : 0):\(stroke.hyper == true ? 1 : 0)"
}

private func trimWhitespace(_ value: String) -> String {
    let scalars = value.unicodeScalars
    var start = scalars.startIndex
    var end = scalars.endIndex
    func isWS(_ s: Unicode.Scalar) -> Bool {
        s.value == 0x20 || s.value == 0x09 || s.value == 0x0A || s.value == 0x0B || s.value == 0x0C
            || s.value == 0x0D || s.value == 0xA0 || s.value == 0xFEFF
    }
    while start < end && isWS(scalars[start]) {
        start = scalars.index(after: start)
    }
    while end > start {
        let prev = scalars.index(before: end)
        if isWS(scalars[prev]) {
            end = prev
        } else {
            break
        }
    }
    return String(scalars[start..<end])
}
