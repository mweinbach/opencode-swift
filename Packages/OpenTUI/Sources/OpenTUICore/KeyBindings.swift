/// Key binding normalization, merging, aliasing, and Kitty base-layout lookup utilities,
/// matching `packages/core/src/lib/keybinding.internal.ts`.

/// Minimal key-chord descriptor shared by key binding definitions and lookup queries.
// parity: core/src/lib/keybinding.internal.ts#KeyBindingLike [status=implemented hash=16149a7d3e9f]
public protocol KeyBindingLike {
    var name: String { get }
    var ctrl: Bool { get }
    var shift: Bool { get }
    var meta: Bool { get }
    var `super`: Bool { get }
}

/// Associates a key chord with an application or widget action.
// parity: core/src/lib/keybinding.internal.ts#KeyBinding [status=implemented hash=5bf5fe90cd99]
public struct KeyBinding<Action>: KeyBindingLike {
    public var name: String
    public var ctrl: Bool
    public var shift: Bool
    public var meta: Bool
    public var `super`: Bool
    public var action: Action

    public init(
        name: String,
        ctrl: Bool = false,
        shift: Bool = false,
        meta: Bool = false,
        super: Bool = false,
        action: Action
    ) {
        self.name = name
        self.ctrl = ctrl
        self.shift = shift
        self.meta = meta
        self.`super` = `super`
        self.action = action
    }
}

extension KeyBinding: Equatable where Action: Equatable {}
extension KeyBinding: Hashable where Action: Hashable {}
extension KeyBinding: Sendable where Action: Sendable {}
extension KeyBinding: Codable where Action: Codable {}

/// Key-chord lookup query optionally carrying Kitty's base-layout Unicode code point.
// parity: core/src/lib/keybinding.internal.ts#KeyBindingLookup [status=implemented hash=501b3c9d25f0]
public struct KeyBindingLookup: KeyBindingLike, Equatable, Hashable, Sendable, Codable {
    public var name: String
    public var ctrl: Bool
    public var shift: Bool
    public var meta: Bool
    public var `super`: Bool
    /// Kitty's base-layout code point as a Unicode scalar value (e.g. `99` means `"c"`).
    public var baseCode: UInt32?

    public init(
        name: String,
        ctrl: Bool = false,
        shift: Bool = false,
        meta: Bool = false,
        super: Bool = false,
        baseCode: UInt32? = nil
    ) {
        self.name = name
        self.ctrl = ctrl
        self.shift = shift
        self.meta = meta
        self.`super` = `super`
        self.baseCode = baseCode
    }

    public init(_ event: KeyEvent) {
        self.name = event.name
        self.ctrl = event.ctrl
        self.shift = event.shift
        self.meta = event.meta
        self.`super` = event.`super` ?? false
        self.baseCode = event.baseCode
    }

    public init(_ key: ParsedKey) {
        self.name = key.name
        self.ctrl = key.ctrl
        self.shift = key.shift
        self.meta = key.meta
        self.`super` = key.`super` ?? false
        self.baseCode = key.baseCode
    }
}

/// Mapping from alias key names (e.g. `"enter"`, `"esc"`, `"kp0"`) to canonical key names.
// parity: core/src/lib/keybinding.internal.ts#KeyAliasMap [status=implemented hash=fd85f9898951]
public typealias KeyAliasMap = [String: String]

/// Default key name aliases for keypad and shorthand key names.
// parity: core/src/lib/keybinding.internal.ts#defaultKeyAliases [status=implemented hash=f1c75d19e5ac]
public let defaultKeyAliases: KeyAliasMap = [
    "enter": "return",
    "esc": "escape",
    "kp0": "0",
    "kp1": "1",
    "kp2": "2",
    "kp3": "3",
    "kp4": "4",
    "kp5": "5",
    "kp6": "6",
    "kp7": "7",
    "kp8": "8",
    "kp9": "9",
    "kpdecimal": ".",
    "kpdivide": "/",
    "kpmultiply": "*",
    "kpminus": "-",
    "kpplus": "+",
    "kpenter": "enter",
    "kpequal": "=",
    "kpseparator": ",",
    "kpleft": "left",
    "kpright": "right",
    "kpup": "up",
    "kpdown": "down",
    "kppageup": "pageup",
    "kppagedown": "pagedown",
    "kphome": "home",
    "kpend": "end",
    "kpinsert": "insert",
    "kpdelete": "delete",
]

/// Merges custom key aliases over default aliases.
// parity: core/src/lib/keybinding.internal.ts#mergeKeyAliases [status=implemented hash=2bb25c0fbd98]
public func mergeKeyAliases(_ defaults: KeyAliasMap, _ custom: KeyAliasMap) -> KeyAliasMap {
    var result = defaults
    for (key, value) in custom {
        result[key] = value
    }
    return result
}

/// Merges custom key bindings over defaults by normalized key chord, preserving insertion order.
// parity: core/src/lib/keybinding.internal.ts#mergeKeyBindings [status=implemented hash=fea3f4236279]
public func mergeKeyBindings<Action>(
    _ defaults: [KeyBinding<Action>],
    _ custom: [KeyBinding<Action>]
) -> [KeyBinding<Action>] {
    var result: [KeyBinding<Action>] = []
    var keyToIndex: [String: Int] = [:]
    result.reserveCapacity(defaults.count + custom.count)

    for binding in defaults {
        let key = getKeyBindingKey(binding)
        if let existingIdx = keyToIndex[key] {
            result[existingIdx] = binding
        } else {
            keyToIndex[key] = result.count
            result.append(binding)
        }
    }

    for binding in custom {
        let key = getKeyBindingKey(binding)
        if let existingIdx = keyToIndex[key] {
            result[existingIdx] = binding
        } else {
            keyToIndex[key] = result.count
            result.append(binding)
        }
    }

    return result
}

/// Serializes a key chord into its canonical lookup key (`"name:ctrl:shift:meta:super"`).
// parity: core/src/lib/keybinding.internal.ts#getKeyBindingKey [status=implemented hash=ede90c431ea5]
public func getKeyBindingKey<T: KeyBindingLike>(_ binding: T) -> String {
    "\(binding.name):\(binding.ctrl ? 1 : 0):\(binding.shift ? 1 : 0):\(binding.meta ? 1 : 0):\(binding.`super` ? 1 : 0)"
}

/// Serializes a `KeyEvent` into its canonical key-binding lookup key.
public func getKeyBindingKeyFromEvent(_ event: KeyEvent) -> String {
    getKeyBindingKey(KeyBindingLookup(event))
}

/// Serializes a `ParsedKey` into its canonical key-binding lookup key.
public func getKeyBindingKeyFromParsedKey(_ key: ParsedKey) -> String {
    getKeyBindingKey(KeyBindingLookup(key))
}

/// Resolves Kitty's base-layout code point fallback name for non-Latin or AZERTY digit layouts.
private func getBaseCodeKeyName(_ binding: KeyBindingLookup) -> String? {
    guard let baseCode = binding.baseCode, baseCode > 32, baseCode != 127 else {
        return nil
    }

    let isSingleNonAsciiScalar: Bool
    if binding.name.unicodeScalars.count == 1, let firstScalar = binding.name.unicodeScalars.first {
        isSingleNonAsciiScalar = firstScalar.value > 0x7F
    } else {
        isSingleNonAsciiScalar = false
    }

    let isAsciiDigit = baseCode >= 48 && baseCode <= 57
    if !isSingleNonAsciiScalar && !isAsciiDigit {
        return nil
    }

    guard let scalar = Unicode.Scalar(baseCode) else {
        return nil
    }

    if scalar.value >= 0x41 && scalar.value <= 0x5A,
       let lowered = Unicode.Scalar(scalar.value + 32)
    {
        return String(lowered)
    }

    return String(scalar)
}

/// Returns every lookup key that can represent `binding`: the parsed key name first,
/// followed by Kitty's base-layout fallback when applicable.
// parity: core/src/lib/keybinding.internal.ts#getKeyBindingKeys [status=implemented hash=9015ad1f3ef2]
public func getKeyBindingKeys(_ binding: KeyBindingLookup) -> [String] {
    var names: [String] = [binding.name]
    if let baseCodeName = getBaseCodeKeyName(binding), baseCodeName != binding.name {
        names.append(baseCodeName)
    }

    return names.map { candidateName in
        getKeyBindingKey(
            KeyBindingLookup(
                name: candidateName,
                ctrl: binding.ctrl,
                shift: binding.shift,
                meta: binding.meta,
                super: binding.`super`,
                baseCode: binding.baseCode
            )
        )
    }
}

/// Returns every lookup key that can represent a `KeyEvent`.
public func getKeyBindingKeys(_ event: KeyEvent) -> [String] {
    getKeyBindingKeys(KeyBindingLookup(event))
}

/// Returns every lookup key that can represent a `ParsedKey`.
public func getKeyBindingKeys(_ key: ParsedKey) -> [String] {
    getKeyBindingKeys(KeyBindingLookup(key))
}

/// Looks up the action bound to `binding` in a compiled key-bindings map, checking the direct
/// key name first and then the base-layout fallback.
// parity: core/src/lib/keybinding.internal.ts#getKeyBindingAction [status=implemented hash=7d465561419a]
public func getKeyBindingAction<Action>(
    _ map: [String: Action],
    _ binding: KeyBindingLookup
) -> Action? {
    for key in getKeyBindingKeys(binding) {
        if let action = map[key] {
            return action
        }
    }
    return nil
}

/// Looks up the action bound to a `KeyEvent` in a compiled key-bindings map.
public func getKeyBindingAction<Action>(
    _ map: [String: Action],
    _ event: KeyEvent
) -> Action? {
    getKeyBindingAction(map, KeyBindingLookup(event))
}

/// Reports whether `binding` matches `match` directly or through Kitty's base-layout fallback.
// parity: core/src/lib/keybinding.internal.ts#matchesKeyBinding [status=implemented hash=0fcdc09ad542]
public func matchesKeyBinding<Match: KeyBindingLike>(
    _ binding: KeyBindingLookup,
    _ match: Match
) -> Bool {
    let matchKey = getKeyBindingKey(match)
    return getKeyBindingKeys(binding).contains(matchKey)
}

/// Reports whether a `KeyEvent` matches `match` directly or through Kitty's base-layout fallback.
public func matchesKeyBinding<Match: KeyBindingLike>(
    _ event: KeyEvent,
    _ match: Match
) -> Bool {
    matchesKeyBinding(KeyBindingLookup(event), match)
}

/// Compiles an array of key bindings into a lookup dictionary, also populating normalized aliases.
// parity: core/src/lib/keybinding.internal.ts#buildKeyBindingsMap [status=implemented hash=2fa70323767c]
public func buildKeyBindingsMap<Action>(
    _ bindings: [KeyBinding<Action>],
    aliasMap: KeyAliasMap? = nil
) -> [String: Action] {
    var map: [String: Action] = [:]
    map.reserveCapacity(bindings.count)
    let aliases = aliasMap ?? [:]

    for binding in bindings {
        let key = getKeyBindingKey(binding)
        map[key] = binding.action
    }

    for binding in bindings {
        let normalizedName = aliases[binding.name] ?? binding.name
        if normalizedName != binding.name {
            let aliasedBinding = KeyBindingLookup(
                name: normalizedName,
                ctrl: binding.ctrl,
                shift: binding.shift,
                meta: binding.meta,
                super: binding.`super`
            )
            map[getKeyBindingKey(aliasedBinding)] = binding.action
        }
    }

    return map
}

/// Formats a key binding into a human-readable string such as `"ctrl+shift+y"` or `"escape"`.
// parity: core/src/lib/keybinding.internal.ts#keyBindingToString [status=implemented hash=0fa7fafe3119]
public func keyBindingToString<T: KeyBindingLike>(_ binding: T) -> String {
    var parts: [String] = []
    if binding.ctrl { parts.append("ctrl") }
    if binding.shift { parts.append("shift") }
    if binding.meta { parts.append("meta") }
    if binding.`super` { parts.append("super") }
    parts.append(binding.name)
    return parts.joined(separator: "+")
}
