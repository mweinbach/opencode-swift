import OpenCodeSchema
import OpenTUICore

// MARK: - Error

/// Error thrown when decoding, validating, migrating, or resolving a TUI theme fails.
public struct ThemeError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let message: String
    public let underlyingDescription: String?

    public init(_ message: String, underlyingDescription: String? = nil) {
        self.message = message
        self.underlyingDescription = underlyingDescription
    }

    public var description: String { message }
}

// MARK: - Copy-on-Write / Immutable Storage Boxes

/// Sound copy-on-write reference box keeping large value-typed theme structs small on cooperative thread stacks.
/// Mutated exclusively after `isKnownUniquelyReferenced(&box)` succeeds; shared instances are strictly immutable.
private final class ThemeCoWBox<Value: Sendable>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// Strictly immutable reference box for large read-only resolved theme payloads (`Sendable` without `@unchecked`).
private final class ThemeImmutableBox<Value: Sendable>: Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

// MARK: - Coding Key Helper

struct ThemeDynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = Int(stringValue)
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }

    init(raw: String) {
        self.stringValue = raw
        self.intValue = Int(raw)
    }
}

// MARK: - Schema Primitives (`packages/theme/src/tui/schema.ts`)

/// Scale step index (`100` through `900`) within a theme hue ramp.
// parity: theme/src/tui/schema.ts#HueStep [status=implemented hash=d0a8e2f2669d]
public enum HueStep: Int, CaseIterable, Equatable, Hashable, Sendable, Codable, CodingKeyRepresentable {
    case s100 = 100
    case s200 = 200
    case s300 = 300
    case s400 = 400
    case s500 = 500
    case s600 = 600
    case s700 = 700
    case s800 = 800
    case s900 = 900

    public static let literals: [HueStep] = allCases

    public var codingKey: any CodingKey {
        ThemeDynamicCodingKey(raw: String(rawValue))
    }

    public init?<T: CodingKey>(codingKey: T) {
        guard let intVal = Int(codingKey.stringValue), let step = HueStep(rawValue: intVal) else {
            return nil
        }
        self = step
    }
}

/// Required semantic hue aliases present on every theme.
// parity: theme/src/tui/schema.ts#SemanticHue [status=implemented hash=9b8b4423754a]
public enum SemanticHue: String, CaseIterable, Equatable, Hashable, Sendable, Codable, CodingKeyRepresentable {
    case accent
    case interactive
    case neutral
}

/// Action emphasis variants for buttons, rows, and interactive controls.
// parity: theme/src/tui/schema.ts#ActionVariant [status=implemented hash=56ee407df867]
public enum ActionVariant: String, CaseIterable, Equatable, Hashable, Sendable, Codable, CodingKeyRepresentable {
    case primary
    case secondary
    case destructive

    public static let literals: [ActionVariant] = allCases
}

/// Interactive states in priority order (`disabled` > `pressed` > `focused` > `selected` > `hovered`).
// parity: theme/src/tui/schema.ts#ActionState [status=implemented hash=ff9f35513113]
public enum ActionState: String, CaseIterable, Equatable, Hashable, Sendable, Codable, CodingKeyRepresentable {
    case disabled
    case pressed
    case focused
    case selected
    case hovered

    public static let literals: [ActionState] = allCases

    public var stateKey: ActionStateKey {
        switch self {
        case .disabled: return .disabled
        case .pressed: return .pressed
        case .focused: return .focused
        case .selected: return .selected
        case .hovered: return .hovered
        }
    }
}

/// Token definition key form (`$disabled`, `$pressed`, `$focused`, `$selected`, `$hovered`).
// parity: theme/src/tui/schema.ts#ActionStateKey [status=implemented hash=50f3bf17660b]
public enum ActionStateKey: String, CaseIterable, Equatable, Hashable, Sendable, Codable, CodingKeyRepresentable {
    case disabled = "$disabled"
    case pressed = "$pressed"
    case focused = "$focused"
    case selected = "$selected"
    case hovered = "$hovered"
}

/// Raised surface contexts supported by `ResolvedTheme.surface(_:)`.
// parity: theme/src/tui/schema.ts#SurfaceName [status=implemented hash=70482e6b2540]
public enum SurfaceName: String, CaseIterable, Equatable, Hashable, Sendable, Codable, CodingKeyRepresentable {
    case dialog = "dialog"
    case dialogFooter = "dialog.footer"

    public static let literals: [SurfaceName] = allCases
}

/// Interactive states for form fields (identical to `ActionState`).
// parity: theme/src/tui/schema.ts#FormfieldState [status=implemented hash=ba23c82386e9]
public typealias FormfieldState = ActionState

/// Token definition key form for form-field states (`$disabled`, etc.).
// parity: theme/src/tui/schema.ts#FormfieldStateKey [status=implemented hash=79ede8815450]
public typealias FormfieldStateKey = ActionStateKey

/// Outcome/status feedback token categories.
// parity: theme/src/tui/schema.ts#FeedbackKind [status=implemented hash=2ced488a446b]
public enum FeedbackKind: String, CaseIterable, Equatable, Hashable, Sendable, Codable, CodingKeyRepresentable {
    case error
    case warning
    case success
    case info

    public static let literals: [FeedbackKind] = allCases
}

/// Color appearance mode (`light` or `dark`), directly integrated with `OpenTUICore.ThemeMode`.
// parity: theme/src/tui/schema.ts#Mode [status=implemented hash=7c96f6f25dea]
public typealias Mode = ThemeMode

/// Name of a hue scale in a theme definition.
// parity: theme/src/tui/schema.ts#HueName [status=implemented hash=7d66964f1da6]
public typealias HueName = String

/// Ordered list of hue names used for categorical visualization / agents / skills.
// parity: theme/src/tui/schema.ts#CategoricalDefinition [status=implemented hash=27954566ec0e]
public typealias CategoricalDefinition = [HueName]

/// A single entry in a `HueDefinition`: either a `$hue.<target>` alias or a concrete 100..900 hex scale.
public enum HueValueDefinition: Equatable, Hashable, Sendable, Codable {
    case alias(String)
    case scale([HueStep: String])

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let str = try? single.decode(String.self) {
            self = .alias(str)
            return
        }
        let keyed = try decoder.container(keyedBy: ThemeDynamicCodingKey.self)
        var map: [HueStep: String] = [:]
        for key in keyed.allKeys {
            guard let intVal = Int(key.stringValue), let step = HueStep(rawValue: intVal) else {
                throw ThemeError("Unknown hue step \"\(key.stringValue)\"")
            }
            let value = try keyed.decode(String.self, forKey: key)
            map[step] = value
        }
        self = .scale(map)
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .alias(let ref):
            var container = encoder.singleValueContainer()
            try container.encode(ref)
        case .scale(let map):
            var container = encoder.container(keyedBy: ThemeDynamicCodingKey.self)
            for step in HueStep.allCases {
                if let hex = map[step] {
                    try container.encode(hex, forKey: ThemeDynamicCodingKey(raw: String(step.rawValue)))
                }
            }
        }
    }
}

/// Complete map of hue scales and semantic aliases (`accent`, `interactive`, `neutral`).
// parity: theme/src/tui/schema.ts#HueDefinition [status=implemented hash=fdd94370388b]
public struct HueDefinition: Equatable, Hashable, Sendable, Codable {
    public var values: [HueName: HueValueDefinition]
    /// Preserves insertion order for deterministic hue indexing and JSON emission.
    public var keyOrder: [HueName]

    public init(_ values: [HueName: HueValueDefinition] = [:], keyOrder: [HueName]? = nil) {
        self.values = values
        if let keyOrder {
            self.keyOrder = keyOrder
        } else {
            // Deterministic order: non-semantic sorted, then semantic hues last.
            let semantic = Set(SemanticHue.allCases.map(\.rawValue))
            let nonSemantic = values.keys.filter { !semantic.contains($0) }.sorted()
            let semanticPresent = SemanticHue.allCases.map(\.rawValue).filter { values[$0] != nil }
            self.keyOrder = nonSemantic + semanticPresent
        }
    }

    public subscript(_ name: HueName) -> HueValueDefinition? {
        get { values[name] }
        set {
            values[name] = newValue
            if newValue != nil, !keyOrder.contains(name) {
                keyOrder.append(name)
            } else if newValue == nil {
                keyOrder.removeAll { $0 == name }
            }
        }
    }

    public subscript(_ semantic: SemanticHue) -> HueValueDefinition? {
        get { values[semantic.rawValue] }
        set { self[semantic.rawValue] = newValue }
    }

    public var orderedNames: [HueName] {
        var seen = Set<HueName>()
        var result: [HueName] = []
        for k in keyOrder where values[k] != nil && seen.insert(k).inserted {
            result.append(k)
        }
        for k in values.keys.sorted() where seen.insert(k).inserted {
            result.append(k)
        }
        return result
    }

    public static func == (lhs: HueDefinition, rhs: HueDefinition) -> Bool {
        lhs.values == rhs.values
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(values)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ThemeDynamicCodingKey.self)
        var values: [HueName: HueValueDefinition] = [:]
        var order: [HueName] = []
        for key in container.allKeys {
            let val = try container.decode(HueValueDefinition.self, forKey: key)
            values[key.stringValue] = val
            order.append(key.stringValue)
        }
        self.values = values
        self.keyOrder = order
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ThemeDynamicCodingKey.self)
        for name in orderedNames {
            if let value = values[name] {
                try container.encode(value, forKey: ThemeDynamicCodingKey(raw: name))
            }
        }
    }
}

/// Declarative color value with optional state overrides (`base`, `$hovered`, `$focused`, `$pressed`, `$selected`, `$disabled`).
// parity: theme/src/tui/schema.ts#StatefulColorDefinition [status=implemented hash=8723dbb52bf4]
public struct StatefulColorDefinition: Equatable, Hashable, Sendable, Codable {
    public var base: String?
    public var hovered: String?
    public var focused: String?
    public var pressed: String?
    public var selected: String?
    public var disabled: String?

    public init(
        base: String? = nil,
        hovered: String? = nil,
        focused: String? = nil,
        pressed: String? = nil,
        selected: String? = nil,
        disabled: String? = nil
    ) {
        self.base = base
        self.hovered = hovered
        self.focused = focused
        self.pressed = pressed
        self.selected = selected
        self.disabled = disabled
    }

    public subscript(_ state: ActionState) -> String? {
        get {
            switch state {
            case .disabled: return disabled
            case .pressed: return pressed
            case .focused: return focused
            case .selected: return selected
            case .hovered: return hovered
            }
        }
        set {
            switch state {
            case .disabled: disabled = newValue
            case .pressed: pressed = newValue
            case .focused: focused = newValue
            case .selected: selected = newValue
            case .hovered: hovered = newValue
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case base
        case hovered = "$hovered"
        case focused = "$focused"
        case pressed = "$pressed"
        case selected = "$selected"
        case disabled = "$disabled"
    }
}

/// Declarative form-field color definition (identical structure to `StatefulColorDefinition`).
// parity: theme/src/tui/schema.ts#FormfieldColorDefinition [status=implemented hash=d1c714e2b8b3]
public typealias FormfieldColorDefinition = StatefulColorDefinition

/// Action variant color definitions (`primary`, `secondary`, `destructive`).
public struct ActionColorDefinition: Equatable, Hashable, Sendable, Codable {
    public var primary: StatefulColorDefinition?
    public var secondary: StatefulColorDefinition?
    public var destructive: StatefulColorDefinition?

    public init(
        primary: StatefulColorDefinition? = nil,
        secondary: StatefulColorDefinition? = nil,
        destructive: StatefulColorDefinition? = nil
    ) {
        self.primary = primary
        self.secondary = secondary
        self.destructive = destructive
    }

    public subscript(_ variant: ActionVariant) -> StatefulColorDefinition? {
        get {
            switch variant {
            case .primary: return primary
            case .secondary: return secondary
            case .destructive: return destructive
            }
        }
        set {
            switch variant {
            case .primary: primary = newValue
            case .secondary: secondary = newValue
            case .destructive: destructive = newValue
            }
        }
    }
}

/// Text feedback token pair (`base` and optional `muted`).
public struct TextFeedbackItemDefinition: Equatable, Hashable, Sendable, Codable {
    public var base: String?
    public var muted: String?

    public init(base: String? = nil, muted: String? = nil) {
        self.base = base
        self.muted = muted
    }
}

/// Text feedback tokens grouped by `FeedbackKind`.
public struct TextFeedbackDefinition: Equatable, Hashable, Sendable, Codable {
    public var error: TextFeedbackItemDefinition?
    public var warning: TextFeedbackItemDefinition?
    public var success: TextFeedbackItemDefinition?
    public var info: TextFeedbackItemDefinition?

    public init(
        error: TextFeedbackItemDefinition? = nil,
        warning: TextFeedbackItemDefinition? = nil,
        success: TextFeedbackItemDefinition? = nil,
        info: TextFeedbackItemDefinition? = nil
    ) {
        self.error = error
        self.warning = warning
        self.success = success
        self.info = info
    }

    public subscript(_ kind: FeedbackKind) -> TextFeedbackItemDefinition? {
        get {
            switch kind {
            case .error: return error
            case .warning: return warning
            case .success: return success
            case .info: return info
            }
        }
        set {
            switch kind {
            case .error: error = newValue
            case .warning: warning = newValue
            case .success: success = newValue
            case .info: info = newValue
            }
        }
    }
}

/// Background feedback token (`base`).
public struct BackgroundFeedbackItemDefinition: Equatable, Hashable, Sendable, Codable {
    public var base: String?

    public init(base: String? = nil) {
        self.base = base
    }
}

/// Background feedback tokens grouped by `FeedbackKind`.
public struct BackgroundFeedbackDefinition: Equatable, Hashable, Sendable, Codable {
    public var error: BackgroundFeedbackItemDefinition?
    public var warning: BackgroundFeedbackItemDefinition?
    public var success: BackgroundFeedbackItemDefinition?
    public var info: BackgroundFeedbackItemDefinition?

    public init(
        error: BackgroundFeedbackItemDefinition? = nil,
        warning: BackgroundFeedbackItemDefinition? = nil,
        success: BackgroundFeedbackItemDefinition? = nil,
        info: BackgroundFeedbackItemDefinition? = nil
    ) {
        self.error = error
        self.warning = warning
        self.success = success
        self.info = info
    }

    public subscript(_ kind: FeedbackKind) -> BackgroundFeedbackItemDefinition? {
        get {
            switch kind {
            case .error: return error
            case .warning: return warning
            case .success: return success
            case .info: return info
            }
        }
        set {
            switch kind {
            case .error: error = newValue
            case .warning: warning = newValue
            case .success: success = newValue
            case .info: info = newValue
            }
        }
    }
}

/// Raised background surface elevation steps (`base`, `high`, `max`).
public struct RaisedBackgroundDefinition: Equatable, Hashable, Sendable, Codable {
    public var base: String?
    public var high: String?
    public var max: String?

    public init(base: String? = nil, high: String? = nil, max: String? = nil) {
        self.base = base
        self.high = high
        self.max = max
    }
}

/// Single-slot `{ base }` token definition (used by `border` and `scrollbar`).
public struct SingleColorDefinition: Equatable, Hashable, Sendable, Codable {
    public var base: String?

    public init(base: String? = nil) {
        self.base = base
    }
}

/// Semantic text token definitions.
// parity: theme/src/tui/schema.ts#TextDefinition [status=implemented hash=0c2677b676dc]
public struct TextDefinition: Equatable, Hashable, Sendable, Codable {
    private struct Storage: Equatable, Hashable, Sendable, Codable {
        var base: String?
        var muted: String?
        var faint: String?
        var action: ActionColorDefinition?
        var formfield: StatefulColorDefinition?
        var feedback: TextFeedbackDefinition?
    }

    private var box: ThemeCoWBox<Storage>

    public var base: String? {
        get { box.value.base }
        set { ensureUnique(); box.value.base = newValue }
    }
    public var muted: String? {
        get { box.value.muted }
        set { ensureUnique(); box.value.muted = newValue }
    }
    public var faint: String? {
        get { box.value.faint }
        set { ensureUnique(); box.value.faint = newValue }
    }
    public var action: ActionColorDefinition? {
        get { box.value.action }
        set { ensureUnique(); box.value.action = newValue }
    }
    public var formfield: StatefulColorDefinition? {
        get { box.value.formfield }
        set { ensureUnique(); box.value.formfield = newValue }
    }
    public var feedback: TextFeedbackDefinition? {
        get { box.value.feedback }
        set { ensureUnique(); box.value.feedback = newValue }
    }

    private mutating func ensureUnique() {
        if !isKnownUniquelyReferenced(&box) {
            box = ThemeCoWBox(box.value)
        }
    }

    public init(
        base: String? = nil,
        muted: String? = nil,
        faint: String? = nil,
        action: ActionColorDefinition? = nil,
        formfield: StatefulColorDefinition? = nil,
        feedback: TextFeedbackDefinition? = nil
    ) {
        self.box = ThemeCoWBox(Storage(
            base: base,
            muted: muted,
            faint: faint,
            action: action,
            formfield: formfield,
            feedback: feedback
        ))
    }

    public static func == (lhs: TextDefinition, rhs: TextDefinition) -> Bool {
        lhs.box === rhs.box || lhs.box.value == rhs.box.value
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(box.value)
    }

    public init(from decoder: Decoder) throws {
        self.box = ThemeCoWBox(try Storage(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try box.value.encode(to: encoder)
    }
}

/// Semantic background token definitions.
// parity: theme/src/tui/schema.ts#BackgroundDefinition [status=implemented hash=af5ef297f437]
public struct BackgroundDefinition: Equatable, Hashable, Sendable, Codable {
    private struct Storage: Equatable, Hashable, Sendable, Codable {
        var base: String?
        var raised: RaisedBackgroundDefinition?
        var action: ActionColorDefinition?
        var formfield: StatefulColorDefinition?
        var feedback: BackgroundFeedbackDefinition?
    }

    private var box: ThemeCoWBox<Storage>

    public var base: String? {
        get { box.value.base }
        set { ensureUnique(); box.value.base = newValue }
    }
    public var raised: RaisedBackgroundDefinition? {
        get { box.value.raised }
        set { ensureUnique(); box.value.raised = newValue }
    }
    public var action: ActionColorDefinition? {
        get { box.value.action }
        set { ensureUnique(); box.value.action = newValue }
    }
    public var formfield: StatefulColorDefinition? {
        get { box.value.formfield }
        set { ensureUnique(); box.value.formfield = newValue }
    }
    public var feedback: BackgroundFeedbackDefinition? {
        get { box.value.feedback }
        set { ensureUnique(); box.value.feedback = newValue }
    }

    private mutating func ensureUnique() {
        if !isKnownUniquelyReferenced(&box) {
            box = ThemeCoWBox(box.value)
        }
    }

    public init(
        base: String? = nil,
        raised: RaisedBackgroundDefinition? = nil,
        action: ActionColorDefinition? = nil,
        formfield: StatefulColorDefinition? = nil,
        feedback: BackgroundFeedbackDefinition? = nil
    ) {
        self.box = ThemeCoWBox(Storage(
            base: base,
            raised: raised,
            action: action,
            formfield: formfield,
            feedback: feedback
        ))
    }

    public static func == (lhs: BackgroundDefinition, rhs: BackgroundDefinition) -> Bool {
        lhs.box === rhs.box || lhs.box.value == rhs.box.value
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(box.value)
    }

    public init(from decoder: Decoder) throws {
        self.box = ThemeCoWBox(try Storage(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try box.value.encode(to: encoder)
    }
}

/// Syntax highlighting token names.
// parity: theme/src/tui/schema.ts#SyntaxToken [status=implemented hash=595f00c861cc]
public enum SyntaxToken: String, CaseIterable, Equatable, Hashable, Sendable, Codable, CodingKeyRepresentable {
    case comment
    case keyword
    case function
    case variable
    case string
    case number
    case type
    case `operator`
    case punctuation

    public static let literals: [SyntaxToken] = allCases
}

/// Declarative map of `SyntaxToken` to hex color or `$hue.<name>.<step>` reference.
// parity: theme/src/tui/schema.ts#SyntaxDefinition [status=implemented hash=9474ccf9468f]
public typealias SyntaxDefinition = [SyntaxToken: String]

/// Markdown rendering token names.
// parity: theme/src/tui/schema.ts#MarkdownToken [status=implemented hash=1a4dd37adae4]
public enum MarkdownToken: String, CaseIterable, Equatable, Hashable, Sendable, Codable, CodingKeyRepresentable {
    case text
    case heading
    case link
    case linkText
    case code
    case blockQuote
    case emphasis
    case strong
    case horizontalRule
    case listItem
    case listEnumeration
    case image
    case imageText
    case codeBlock

    public static let literals: [MarkdownToken] = allCases
}

/// Declarative map of `MarkdownToken` to hex color or `$hue.<name>.<step>` reference.
// parity: theme/src/tui/schema.ts#MarkdownDefinition [status=implemented hash=b20237c09f78]
public typealias MarkdownDefinition = [MarkdownToken: String]

/// Diff view token definitions (`text`, `background`, `highlight`, `lineNumber`).
// parity: theme/src/tui/schema.ts#DiffDefinition [status=implemented hash=fdb31f2bc281]
public struct DiffDefinition: Equatable, Hashable, Sendable, Codable {
    public struct Text: Equatable, Hashable, Sendable, Codable {
        public var added: String?
        public var removed: String?
        public var context: String?
        public var hunkHeader: String?

        public init(added: String? = nil, removed: String? = nil, context: String? = nil, hunkHeader: String? = nil) {
            self.added = added
            self.removed = removed
            self.context = context
            self.hunkHeader = hunkHeader
        }
    }

    public struct Background: Equatable, Hashable, Sendable, Codable {
        public var added: String?
        public var removed: String?
        public var context: String?

        public init(added: String? = nil, removed: String? = nil, context: String? = nil) {
            self.added = added
            self.removed = removed
            self.context = context
        }
    }

    public struct Highlight: Equatable, Hashable, Sendable, Codable {
        public var added: String?
        public var removed: String?

        public init(added: String? = nil, removed: String? = nil) {
            self.added = added
            self.removed = removed
        }
    }

    public struct LineNumber: Equatable, Hashable, Sendable, Codable {
        public struct LineNumberBackground: Equatable, Hashable, Sendable, Codable {
            public var added: String?
            public var removed: String?

            public init(added: String? = nil, removed: String? = nil) {
                self.added = added
                self.removed = removed
            }
        }

        public var text: String?
        public var background: LineNumberBackground?

        public init(text: String? = nil, background: LineNumberBackground? = nil) {
            self.text = text
            self.background = background
        }
    }

    private struct Storage: Equatable, Hashable, Sendable, Codable {
        var text: Text?
        var background: Background?
        var highlight: Highlight?
        var lineNumber: LineNumber?
    }

    private var box: ThemeCoWBox<Storage>

    public var text: Text? {
        get { box.value.text }
        set { ensureUnique(); box.value.text = newValue }
    }
    public var background: Background? {
        get { box.value.background }
        set { ensureUnique(); box.value.background = newValue }
    }
    public var highlight: Highlight? {
        get { box.value.highlight }
        set { ensureUnique(); box.value.highlight = newValue }
    }
    public var lineNumber: LineNumber? {
        get { box.value.lineNumber }
        set { ensureUnique(); box.value.lineNumber = newValue }
    }

    private mutating func ensureUnique() {
        if !isKnownUniquelyReferenced(&box) {
            box = ThemeCoWBox(box.value)
        }
    }

    public init(
        text: Text? = nil,
        background: Background? = nil,
        highlight: Highlight? = nil,
        lineNumber: LineNumber? = nil
    ) {
        self.box = ThemeCoWBox(Storage(
            text: text,
            background: background,
            highlight: highlight,
            lineNumber: lineNumber
        ))
    }

    public static func == (lhs: DiffDefinition, rhs: DiffDefinition) -> Bool {
        lhs.box === rhs.box || lhs.box.value == rhs.box.value
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(box.value)
    }

    public init(from decoder: Decoder) throws {
        self.box = ThemeCoWBox(try Storage(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try box.value.encode(to: encoder)
    }
}

/// Optional semantic token layer shared by mode overrides and surface overrides.
// parity: theme/src/tui/schema.ts#ThemeTokensDefinition [status=implemented hash=303d7f532785]
public struct ThemeTokensDefinition: Equatable, Hashable, Sendable, Codable {
    public var text: TextDefinition?
    public var background: BackgroundDefinition?
    public var border: SingleColorDefinition?
    public var scrollbar: SingleColorDefinition?
    public var diff: DiffDefinition?
    public var syntax: SyntaxDefinition?
    public var markdown: MarkdownDefinition?

    public init(
        text: TextDefinition? = nil,
        background: BackgroundDefinition? = nil,
        border: SingleColorDefinition? = nil,
        scrollbar: SingleColorDefinition? = nil,
        diff: DiffDefinition? = nil,
        syntax: SyntaxDefinition? = nil,
        markdown: MarkdownDefinition? = nil
    ) {
        self.text = text
        self.background = background
        self.border = border
        self.scrollbar = scrollbar
        self.diff = diff
        self.syntax = syntax
        self.markdown = markdown
    }
}

/// Dialog surface token overrides, with an optional nested `@footer` surface override.
// parity: theme/src/tui/schema.ts#DialogTokensDefinition [status=implemented hash=bbe9e553dfa7]
public struct DialogTokensDefinition: Equatable, Hashable, Sendable, Codable {
    private struct Storage: Equatable, Hashable, Sendable, Codable {
        var text: TextDefinition?
        var background: BackgroundDefinition?
        var border: SingleColorDefinition?
        var scrollbar: SingleColorDefinition?
        var diff: DiffDefinition?
        var syntax: SyntaxDefinition?
        var markdown: MarkdownDefinition?
        var footer: ThemeTokensDefinition?

        enum CodingKeys: String, CodingKey {
            case text
            case background
            case border
            case scrollbar
            case diff
            case syntax
            case markdown
            case footer = "@footer"
        }
    }

    private var box: ThemeCoWBox<Storage>

    public var text: TextDefinition? {
        get { box.value.text }
        set { ensureUnique(); box.value.text = newValue }
    }
    public var background: BackgroundDefinition? {
        get { box.value.background }
        set { ensureUnique(); box.value.background = newValue }
    }
    public var border: SingleColorDefinition? {
        get { box.value.border }
        set { ensureUnique(); box.value.border = newValue }
    }
    public var scrollbar: SingleColorDefinition? {
        get { box.value.scrollbar }
        set { ensureUnique(); box.value.scrollbar = newValue }
    }
    public var diff: DiffDefinition? {
        get { box.value.diff }
        set { ensureUnique(); box.value.diff = newValue }
    }
    public var syntax: SyntaxDefinition? {
        get { box.value.syntax }
        set { ensureUnique(); box.value.syntax = newValue }
    }
    public var markdown: MarkdownDefinition? {
        get { box.value.markdown }
        set { ensureUnique(); box.value.markdown = newValue }
    }
    public var footer: ThemeTokensDefinition? {
        get { box.value.footer }
        set { ensureUnique(); box.value.footer = newValue }
    }

    private mutating func ensureUnique() {
        if !isKnownUniquelyReferenced(&box) {
            box = ThemeCoWBox(box.value)
        }
    }

    public init(
        text: TextDefinition? = nil,
        background: BackgroundDefinition? = nil,
        border: SingleColorDefinition? = nil,
        scrollbar: SingleColorDefinition? = nil,
        diff: DiffDefinition? = nil,
        syntax: SyntaxDefinition? = nil,
        markdown: MarkdownDefinition? = nil,
        footer: ThemeTokensDefinition? = nil
    ) {
        self.box = ThemeCoWBox(Storage(
            text: text,
            background: background,
            border: border,
            scrollbar: scrollbar,
            diff: diff,
            syntax: syntax,
            markdown: markdown,
            footer: footer
        ))
    }

    public var asTokens: ThemeTokensDefinition {
        ThemeTokensDefinition(
            text: text,
            background: background,
            border: border,
            scrollbar: scrollbar,
            diff: diff,
            syntax: syntax,
            markdown: markdown
        )
    }

    public static func == (lhs: DialogTokensDefinition, rhs: DialogTokensDefinition) -> Bool {
        lhs.box === rhs.box || lhs.box.value == rhs.box.value
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(box.value)
    }

    public init(from decoder: Decoder) throws {
        self.box = ThemeCoWBox(try Storage(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try box.value.encode(to: encoder)
    }
}

/// Complete single-mode theme definition (hues + categorical + all semantic tokens + optional `@dialog`).
// parity: theme/src/tui/schema.ts#ThemeDefinition [status=implemented hash=82a0bbb60599]
public struct ThemeDefinition: Equatable, Hashable, Sendable, Codable {
    public var hue: HueDefinition
    public var categorical: CategoricalDefinition
    public var text: TextDefinition
    public var background: BackgroundDefinition
    public var border: SingleColorDefinition
    public var scrollbar: SingleColorDefinition
    public var diff: DiffDefinition
    public var syntax: SyntaxDefinition
    public var markdown: MarkdownDefinition
    public var dialog: DialogTokensDefinition?

    public init(
        hue: HueDefinition,
        categorical: CategoricalDefinition,
        text: TextDefinition,
        background: BackgroundDefinition,
        border: SingleColorDefinition,
        scrollbar: SingleColorDefinition,
        diff: DiffDefinition,
        syntax: SyntaxDefinition,
        markdown: MarkdownDefinition,
        dialog: DialogTokensDefinition? = nil
    ) {
        self.hue = hue
        self.categorical = categorical
        self.text = text
        self.background = background
        self.border = border
        self.scrollbar = scrollbar
        self.diff = diff
        self.syntax = syntax
        self.markdown = markdown
        self.dialog = dialog
    }

    public var tokens: ThemeTokensDefinition {
        ThemeTokensDefinition(
            text: text,
            background: background,
            border: border,
            scrollbar: scrollbar,
            diff: diff,
            syntax: syntax,
            markdown: markdown
        )
    }

    enum CodingKeys: String, CodingKey {
        case hue
        case categorical
        case text
        case background
        case border
        case scrollbar
        case diff
        case syntax
        case markdown
        case dialog = "@dialog"
    }
}

/// Shared base token layer of a `ThemeDocument` (everything except `hue`).
// parity: theme/src/tui/schema.ts#BaseThemeDefinition [status=implemented hash=742ffb250417]
public struct BaseThemeDefinition: Equatable, Hashable, Sendable, Codable {
    public var categorical: CategoricalDefinition
    public var text: TextDefinition
    public var background: BackgroundDefinition
    public var border: SingleColorDefinition
    public var scrollbar: SingleColorDefinition
    public var diff: DiffDefinition
    public var syntax: SyntaxDefinition
    public var markdown: MarkdownDefinition
    public var dialog: DialogTokensDefinition?

    public init(
        categorical: CategoricalDefinition,
        text: TextDefinition,
        background: BackgroundDefinition,
        border: SingleColorDefinition,
        scrollbar: SingleColorDefinition,
        diff: DiffDefinition,
        syntax: SyntaxDefinition,
        markdown: MarkdownDefinition,
        dialog: DialogTokensDefinition? = nil
    ) {
        self.categorical = categorical
        self.text = text
        self.background = background
        self.border = border
        self.scrollbar = scrollbar
        self.diff = diff
        self.syntax = syntax
        self.markdown = markdown
        self.dialog = dialog
    }

    enum CodingKeys: String, CodingKey {
        case categorical
        case text
        case background
        case border
        case scrollbar
        case diff
        case syntax
        case markdown
        case dialog = "@dialog"
    }
}

/// Per-mode override layer in a `ThemeDocument` (provides required `hue` and optional token overrides).
// parity: theme/src/tui/schema.ts#ModeDefinition [status=implemented hash=42cd124429f9]
public struct ModeDefinition: Equatable, Hashable, Sendable, Codable {
    public var hue: HueDefinition
    public var categorical: CategoricalDefinition?
    public var text: TextDefinition?
    public var background: BackgroundDefinition?
    public var border: SingleColorDefinition?
    public var scrollbar: SingleColorDefinition?
    public var diff: DiffDefinition?
    public var syntax: SyntaxDefinition?
    public var markdown: MarkdownDefinition?
    public var dialog: DialogTokensDefinition?

    public init(
        hue: HueDefinition,
        categorical: CategoricalDefinition? = nil,
        text: TextDefinition? = nil,
        background: BackgroundDefinition? = nil,
        border: SingleColorDefinition? = nil,
        scrollbar: SingleColorDefinition? = nil,
        diff: DiffDefinition? = nil,
        syntax: SyntaxDefinition? = nil,
        markdown: MarkdownDefinition? = nil,
        dialog: DialogTokensDefinition? = nil
    ) {
        self.hue = hue
        self.categorical = categorical
        self.text = text
        self.background = background
        self.border = border
        self.scrollbar = scrollbar
        self.diff = diff
        self.syntax = syntax
        self.markdown = markdown
        self.dialog = dialog
    }

    public init(from definition: ThemeDefinition) {
        self.hue = definition.hue
        self.categorical = definition.categorical
        self.text = definition.text
        self.background = definition.background
        self.border = definition.border
        self.scrollbar = definition.scrollbar
        self.diff = definition.diff
        self.syntax = definition.syntax
        self.markdown = definition.markdown
        self.dialog = definition.dialog
    }

    enum CodingKeys: String, CodingKey {
        case hue
        case categorical
        case text
        case background
        case border
        case scrollbar
        case diff
        case syntax
        case markdown
        case dialog = "@dialog"
    }
}

/// Multi-mode TUI theme document (`base` plus at least one of `light` or `dark`).
// parity: theme/src/tui/schema.ts#ThemeDocument [status=implemented hash=ad9b227ca255]
public struct ThemeDocument: Equatable, Hashable, Sendable, Codable {
    public var schema: String?
    public var base: BaseThemeDefinition
    public var light: ModeDefinition?
    public var dark: ModeDefinition?

    public init(
        schema: String? = nil,
        base: BaseThemeDefinition,
        light: ModeDefinition? = nil,
        dark: ModeDefinition? = nil
    ) {
        self.schema = schema
        self.base = base
        self.light = light
        self.dark = dark
    }

    enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case base
        case light
        case dark
    }
}

// MARK: - Resolved Runtime Theme Types (`packages/theme/src/tui/types.ts`)

/// Resolved interactive state key including `"base"`.
// parity: theme/src/tui/types.ts#ResolvedActionState [status=implemented hash=3bd92837cab8]
public enum ResolvedActionState: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
    case base
    case disabled
    case pressed
    case focused
    case selected
    case hovered
}

/// Resolved interactive state key for form fields.
// parity: theme/src/tui/types.ts#ResolvedFormfieldState [status=implemented hash=9a3f9d91cd5f]
public typealias ResolvedFormfieldState = ResolvedActionState

/// Resolved 9-step `RGBA` color ramp (`100` through `900`).
// parity: theme/src/tui/types.ts#HueScale [status=implemented hash=b5720f365336]
public struct HueScale: Equatable, Hashable, Sendable, Codable {
    public let s100: RGBA
    public let s200: RGBA
    public let s300: RGBA
    public let s400: RGBA
    public let s500: RGBA
    public let s600: RGBA
    public let s700: RGBA
    public let s800: RGBA
    public let s900: RGBA

    public init(
        s100: RGBA,
        s200: RGBA,
        s300: RGBA,
        s400: RGBA,
        s500: RGBA,
        s600: RGBA,
        s700: RGBA,
        s800: RGBA,
        s900: RGBA
    ) {
        self.s100 = s100
        self.s200 = s200
        self.s300 = s300
        self.s400 = s400
        self.s500 = s500
        self.s600 = s600
        self.s700 = s700
        self.s800 = s800
        self.s900 = s900
    }

    public subscript(_ step: HueStep) -> RGBA {
        switch step {
        case .s100: return s100
        case .s200: return s200
        case .s300: return s300
        case .s400: return s400
        case .s500: return s500
        case .s600: return s600
        case .s700: return s700
        case .s800: return s800
        case .s900: return s900
        }
    }

    public subscript(_ rawStep: Int) -> RGBA? {
        HueStep(rawValue: rawStep).map { self[$0] }
    }
}

/// Resolved semantic and named hue scales (`accent`, `interactive`, `neutral`, plus all custom hues).
// parity: theme/src/tui/types.ts#Hue [status=implemented hash=e0183bbbb8f8]
public struct Hue: Equatable, Hashable, Sendable, Codable {
    public let accent: HueScale
    public let interactive: HueScale
    public let neutral: HueScale
    public let scales: [String: HueScale]

    public init(accent: HueScale, interactive: HueScale, neutral: HueScale, scales: [String: HueScale]) {
        self.accent = accent
        self.interactive = interactive
        self.neutral = neutral
        var all = scales
        all["accent"] = accent
        all["interactive"] = interactive
        all["neutral"] = neutral
        self.scales = all
    }

    public subscript(_ name: String) -> HueScale? {
        scales[name]
    }

    public subscript(_ semantic: SemanticHue) -> HueScale {
        switch semantic {
        case .accent: return accent
        case .interactive: return interactive
        case .neutral: return neutral
        }
    }
}

/// Provenance of a resolved `RGBA` color within the theme's hue scales.
// parity: theme/src/tui/types.ts#HueSource [status=implemented hash=04dbc0e5bb72]
public struct HueSource: Equatable, Hashable, Sendable, Codable {
    public let hue: String
    public let step: HueStep

    public init(hue: String, step: HueStep) {
        self.hue = hue
        self.step = step
    }
}

/// Ordered categorical hue scales resolved for a theme.
// parity: theme/src/tui/types.ts#Categorical [status=implemented hash=9293428779ef]
public typealias Categorical = [HueScale]

/// Active interaction state flags passed to `StatefulColor.state(_:)`.
// parity: theme/src/tui/types.ts#ActionStates [status=implemented hash=1ae1e6067c54]
public struct ActionStates: Equatable, Hashable, Sendable, Codable {
    public var disabled: Bool
    public var pressed: Bool
    public var focused: Bool
    public var selected: Bool
    public var hovered: Bool

    public init(
        disabled: Bool = false,
        pressed: Bool = false,
        focused: Bool = false,
        selected: Bool = false,
        hovered: Bool = false
    ) {
        self.disabled = disabled
        self.pressed = pressed
        self.focused = focused
        self.selected = selected
        self.hovered = hovered
    }

    public subscript(_ state: ActionState) -> Bool {
        switch state {
        case .disabled: return disabled
        case .pressed: return pressed
        case .focused: return focused
        case .selected: return selected
        case .hovered: return hovered
        }
    }
}

/// Resolved color across all interactive states, with priority-ordered `state(_:)` lookup.
// parity: theme/src/tui/types.ts#StatefulColor [status=implemented hash=61e0d1b6d6ee]
public struct StatefulColor: Equatable, Hashable, Sendable, Codable {
    public let base: RGBA
    public let disabled: RGBA
    public let pressed: RGBA
    public let focused: RGBA
    public let selected: RGBA
    public let hovered: RGBA

    public init(
        base: RGBA,
        disabled: RGBA,
        pressed: RGBA,
        focused: RGBA,
        selected: RGBA,
        hovered: RGBA
    ) {
        self.base = base
        self.disabled = disabled
        self.pressed = pressed
        self.focused = focused
        self.selected = selected
        self.hovered = hovered
    }

    public subscript(_ state: ResolvedActionState) -> RGBA {
        switch state {
        case .base: return base
        case .disabled: return disabled
        case .pressed: return pressed
        case .focused: return focused
        case .selected: return selected
        case .hovered: return hovered
        }
    }

    /// Selects the highest-priority active state (`disabled` > `pressed` > `focused` > `selected` > `hovered` > `base`).
    public func state(_ states: ActionStates) -> RGBA {
        for candidate in ActionState.literals {
            if states[candidate] {
                switch candidate {
                case .disabled: return disabled
                case .pressed: return pressed
                case .focused: return focused
                case .selected: return selected
                case .hovered: return hovered
                }
            }
        }
        return base
    }
}

/// Resolved stateful color for form fields.
// parity: theme/src/tui/types.ts#FormfieldColor [status=implemented hash=f7feb78ca75b]
public typealias FormfieldColor = StatefulColor

/// Resolved action colors for `primary`, `secondary`, and `destructive` variants.
public struct ResolvedActionColors: Equatable, Hashable, Sendable, Codable {
    public let primary: StatefulColor
    public let secondary: StatefulColor
    public let destructive: StatefulColor

    public init(primary: StatefulColor, secondary: StatefulColor, destructive: StatefulColor) {
        self.primary = primary
        self.secondary = secondary
        self.destructive = destructive
    }

    public subscript(_ variant: ActionVariant) -> StatefulColor {
        switch variant {
        case .primary: return primary
        case .secondary: return secondary
        case .destructive: return destructive
        }
    }
}

/// Resolved text feedback color pair (`base` and `muted`).
public struct ResolvedTextFeedbackColor: Equatable, Hashable, Sendable, Codable {
    public let base: RGBA
    public let muted: RGBA

    public init(base: RGBA, muted: RGBA) {
        self.base = base
        self.muted = muted
    }
}

/// Resolved text feedback colors grouped by `FeedbackKind`.
public struct ResolvedTextFeedback: Equatable, Hashable, Sendable, Codable {
    public let error: ResolvedTextFeedbackColor
    public let warning: ResolvedTextFeedbackColor
    public let success: ResolvedTextFeedbackColor
    public let info: ResolvedTextFeedbackColor

    public init(
        error: ResolvedTextFeedbackColor,
        warning: ResolvedTextFeedbackColor,
        success: ResolvedTextFeedbackColor,
        info: ResolvedTextFeedbackColor
    ) {
        self.error = error
        self.warning = warning
        self.success = success
        self.info = info
    }

    public subscript(_ kind: FeedbackKind) -> ResolvedTextFeedbackColor {
        switch kind {
        case .error: return error
        case .warning: return warning
        case .success: return success
        case .info: return info
        }
    }
}

/// Resolved single-slot `{ base }` color token.
public struct ResolvedBaseColor: Equatable, Hashable, Sendable, Codable {
    public let base: RGBA

    public init(base: RGBA) {
        self.base = base
    }
}

/// Resolved background feedback colors grouped by `FeedbackKind`.
public struct ResolvedBackgroundFeedback: Equatable, Hashable, Sendable, Codable {
    public let error: ResolvedBaseColor
    public let warning: ResolvedBaseColor
    public let success: ResolvedBaseColor
    public let info: ResolvedBaseColor

    public init(
        error: ResolvedBaseColor,
        warning: ResolvedBaseColor,
        success: ResolvedBaseColor,
        info: ResolvedBaseColor
    ) {
        self.error = error
        self.warning = warning
        self.success = success
        self.info = info
    }

    public subscript(_ kind: FeedbackKind) -> ResolvedBaseColor {
        switch kind {
        case .error: return error
        case .warning: return warning
        case .success: return success
        case .info: return info
        }
    }
}

/// Resolved raised background elevations (`base`, `high`, `max`).
public struct ResolvedRaisedBackground: Equatable, Hashable, Sendable, Codable {
    public let base: RGBA
    public let high: RGBA
    public let max: RGBA

    public init(base: RGBA, high: RGBA, max: RGBA) {
        self.base = base
        self.high = high
        self.max = max
    }
}

/// Resolved semantic text tokens.
public struct ResolvedTextTokens: Equatable, Hashable, Sendable, Codable {
    public let base: RGBA
    public let muted: RGBA
    public let faint: RGBA
    public let action: ResolvedActionColors
    public let formfield: FormfieldColor
    public let feedback: ResolvedTextFeedback

    public init(
        base: RGBA,
        muted: RGBA,
        faint: RGBA,
        action: ResolvedActionColors,
        formfield: FormfieldColor,
        feedback: ResolvedTextFeedback
    ) {
        self.base = base
        self.muted = muted
        self.faint = faint
        self.action = action
        self.formfield = formfield
        self.feedback = feedback
    }
}

/// Resolved semantic background tokens.
public struct ResolvedBackgroundTokens: Equatable, Hashable, Sendable, Codable {
    public let base: RGBA
    public let raised: ResolvedRaisedBackground
    public let action: ResolvedActionColors
    public let formfield: FormfieldColor
    public let feedback: ResolvedBackgroundFeedback

    public init(
        base: RGBA,
        raised: ResolvedRaisedBackground,
        action: ResolvedActionColors,
        formfield: FormfieldColor,
        feedback: ResolvedBackgroundFeedback
    ) {
        self.base = base
        self.raised = raised
        self.action = action
        self.formfield = formfield
        self.feedback = feedback
    }
}

/// Resolved diff view tokens.
public struct ResolvedDiffTokens: Equatable, Hashable, Sendable, Codable {
    public struct Text: Equatable, Hashable, Sendable, Codable {
        public let added: RGBA
        public let removed: RGBA
        public let context: RGBA
        public let hunkHeader: RGBA

        public init(added: RGBA, removed: RGBA, context: RGBA, hunkHeader: RGBA) {
            self.added = added
            self.removed = removed
            self.context = context
            self.hunkHeader = hunkHeader
        }
    }

    public struct Background: Equatable, Hashable, Sendable, Codable {
        public let added: RGBA
        public let removed: RGBA
        public let context: RGBA

        public init(added: RGBA, removed: RGBA, context: RGBA) {
            self.added = added
            self.removed = removed
            self.context = context
        }
    }

    public struct Highlight: Equatable, Hashable, Sendable, Codable {
        public let added: RGBA
        public let removed: RGBA

        public init(added: RGBA, removed: RGBA) {
            self.added = added
            self.removed = removed
        }
    }

    public struct LineNumber: Equatable, Hashable, Sendable, Codable {
        public struct Background: Equatable, Hashable, Sendable, Codable {
            public let added: RGBA
            public let removed: RGBA

            public init(added: RGBA, removed: RGBA) {
                self.added = added
                self.removed = removed
            }
        }

        public let text: RGBA
        public let background: Background

        public init(text: RGBA, background: Background) {
            self.text = text
            self.background = background
        }
    }

    public let text: Text
    public let background: Background
    public let highlight: Highlight
    public let lineNumber: LineNumber

    public init(text: Text, background: Background, highlight: Highlight, lineNumber: LineNumber) {
        self.text = text
        self.background = background
        self.highlight = highlight
        self.lineNumber = lineNumber
    }
}

/// Resolved syntax highlighting colors keyed by `SyntaxToken`.
public struct ResolvedSyntaxTokens: Equatable, Hashable, Sendable, Codable {
    public let comment: RGBA
    public let keyword: RGBA
    public let function: RGBA
    public let variable: RGBA
    public let string: RGBA
    public let number: RGBA
    public let type: RGBA
    public let `operator`: RGBA
    public let punctuation: RGBA

    public init(
        comment: RGBA,
        keyword: RGBA,
        function: RGBA,
        variable: RGBA,
        string: RGBA,
        number: RGBA,
        type: RGBA,
        operator: RGBA,
        punctuation: RGBA
    ) {
        self.comment = comment
        self.keyword = keyword
        self.function = function
        self.variable = variable
        self.string = string
        self.number = number
        self.type = type
        self.operator = `operator`
        self.punctuation = punctuation
    }

    public subscript(_ token: SyntaxToken) -> RGBA {
        switch token {
        case .comment: return comment
        case .keyword: return keyword
        case .function: return function
        case .variable: return variable
        case .string: return string
        case .number: return number
        case .type: return type
        case .operator: return `operator`
        case .punctuation: return punctuation
        }
    }
}

/// Resolved markdown rendering colors keyed by `MarkdownToken`.
public struct ResolvedMarkdownTokens: Equatable, Hashable, Sendable, Codable {
    public let text: RGBA
    public let heading: RGBA
    public let link: RGBA
    public let linkText: RGBA
    public let code: RGBA
    public let blockQuote: RGBA
    public let emphasis: RGBA
    public let strong: RGBA
    public let horizontalRule: RGBA
    public let listItem: RGBA
    public let listEnumeration: RGBA
    public let image: RGBA
    public let imageText: RGBA
    public let codeBlock: RGBA

    public init(
        text: RGBA,
        heading: RGBA,
        link: RGBA,
        linkText: RGBA,
        code: RGBA,
        blockQuote: RGBA,
        emphasis: RGBA,
        strong: RGBA,
        horizontalRule: RGBA,
        listItem: RGBA,
        listEnumeration: RGBA,
        image: RGBA,
        imageText: RGBA,
        codeBlock: RGBA
    ) {
        self.text = text
        self.heading = heading
        self.link = link
        self.linkText = linkText
        self.code = code
        self.blockQuote = blockQuote
        self.emphasis = emphasis
        self.strong = strong
        self.horizontalRule = horizontalRule
        self.listItem = listItem
        self.listEnumeration = listEnumeration
        self.image = image
        self.imageText = imageText
        self.codeBlock = codeBlock
    }

    public subscript(_ token: MarkdownToken) -> RGBA {
        switch token {
        case .text: return text
        case .heading: return heading
        case .link: return link
        case .linkText: return linkText
        case .code: return code
        case .blockQuote: return blockQuote
        case .emphasis: return emphasis
        case .strong: return strong
        case .horizontalRule: return horizontalRule
        case .listItem: return listItem
        case .listEnumeration: return listEnumeration
        case .image: return image
        case .imageText: return imageText
        case .codeBlock: return codeBlock
        }
    }
}

/// Internal hue-step lookup table powering `source`, `increase`, and `decrease`.
struct HueStepIndex: Equatable, Hashable, Sendable {
    struct Entry: Equatable, Hashable, Sendable {
        let hue: String
        let step: HueStep
        let position: Int
    }

    let entries: [RGBA: Entry]
    let scales: [String: HueScale]

    init(hue: Hue, orderedNames: [String]) {
        var map: [RGBA: Entry] = [:]
        for name in orderedNames {
            guard let scale = hue[name] else { continue }
            for (position, step) in HueStep.literals.enumerated() {
                map[scale[step]] = Entry(hue: name, step: step, position: position)
            }
        }
        self.entries = map
        self.scales = hue.scales
    }

    func source(_ color: RGBA) -> HueSource? {
        entries[color].map { HueSource(hue: $0.hue, step: $0.step) }
    }

    func shift(_ color: RGBA, by amount: Double) -> RGBA {
        guard let match = entries[color], let scale = scales[match.hue] else { return color }
        let offset = amount.isFinite ? Int(amount.rounded(.towardZero)) : 0
        let position = max(0, min(HueStep.literals.count - 1, match.position + offset))
        return scale[HueStep.literals[position]]
    }
}

/// Fully resolved TUI semantic theme tokens and hue-step navigation helpers.
// parity: theme/src/tui/types.ts#ResolvedThemeTokens [status=implemented hash=f4aaa5bacbb7]
public struct ResolvedThemeTokens: Equatable, Hashable, Sendable {
    private struct Storage: Equatable, Hashable, Sendable {
        let hue: Hue
        let categorical: Categorical
        let text: ResolvedTextTokens
        let background: ResolvedBackgroundTokens
        let border: ResolvedBaseColor
        let scrollbar: ResolvedBaseColor
        let diff: ResolvedDiffTokens
        let syntax: ResolvedSyntaxTokens
        let markdown: ResolvedMarkdownTokens
        let hueIndex: HueStepIndex
    }

    private let box: ThemeImmutableBox<Storage>

    public var hue: Hue { box.value.hue }
    public var categorical: Categorical { box.value.categorical }
    public var text: ResolvedTextTokens { box.value.text }
    public var background: ResolvedBackgroundTokens { box.value.background }
    public var border: ResolvedBaseColor { box.value.border }
    public var scrollbar: ResolvedBaseColor { box.value.scrollbar }
    public var diff: ResolvedDiffTokens { box.value.diff }
    public var syntax: ResolvedSyntaxTokens { box.value.syntax }
    public var markdown: ResolvedMarkdownTokens { box.value.markdown }
    var hueIndex: HueStepIndex { box.value.hueIndex }

    init(
        hue: Hue,
        categorical: Categorical,
        text: ResolvedTextTokens,
        background: ResolvedBackgroundTokens,
        border: ResolvedBaseColor,
        scrollbar: ResolvedBaseColor,
        diff: ResolvedDiffTokens,
        syntax: ResolvedSyntaxTokens,
        markdown: ResolvedMarkdownTokens,
        hueIndex: HueStepIndex
    ) {
        self.box = ThemeImmutableBox(Storage(
            hue: hue,
            categorical: categorical,
            text: text,
            background: background,
            border: border,
            scrollbar: scrollbar,
            diff: diff,
            syntax: syntax,
            markdown: markdown,
            hueIndex: hueIndex
        ))
    }

    public static func == (lhs: ResolvedThemeTokens, rhs: ResolvedThemeTokens) -> Bool {
        lhs.box === rhs.box || lhs.box.value == rhs.box.value
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(box.value)
    }

    public func source(_ color: RGBA) -> HueSource? {
        box.value.hueIndex.source(color)
    }

    public func increase(_ color: RGBA, _ amount: Int = 1) -> RGBA {
        box.value.hueIndex.shift(color, by: Double(amount))
    }

    public func increase(_ color: RGBA, _ amount: Double) -> RGBA {
        box.value.hueIndex.shift(color, by: amount)
    }

    public func decrease(_ color: RGBA, _ amount: Int = 1) -> RGBA {
        box.value.hueIndex.shift(color, by: Double(-amount))
    }

    public func decrease(_ color: RGBA, _ amount: Double) -> RGBA {
        box.value.hueIndex.shift(color, by: -amount)
    }
}

/// Immutable value-typed resolved theme carrying its base tokens and absolute raised surface views.
// parity: theme/src/tui/types.ts#ResolvedTheme [status=implemented hash=e2f5830beaf4]
public struct ResolvedTheme: Equatable, Hashable, Sendable {
    public let tokens: ResolvedThemeTokens
    private let surfaceTokens: [SurfaceName: ResolvedThemeTokens]

    init(tokens: ResolvedThemeTokens, surfaceTokens: [SurfaceName: ResolvedThemeTokens]) {
        self.tokens = tokens
        self.surfaceTokens = surfaceTokens
    }

    public var hue: Hue { tokens.hue }
    public var categorical: Categorical { tokens.categorical }
    public var text: ResolvedTextTokens { tokens.text }
    public var background: ResolvedBackgroundTokens { tokens.background }
    public var border: ResolvedBaseColor { tokens.border }
    public var scrollbar: ResolvedBaseColor { tokens.scrollbar }
    public var diff: ResolvedDiffTokens { tokens.diff }
    public var syntax: ResolvedSyntaxTokens { tokens.syntax }
    public var markdown: ResolvedMarkdownTokens { tokens.markdown }

    public func source(_ color: RGBA) -> HueSource? {
        tokens.source(color)
    }

    public func increase(_ color: RGBA, _ amount: Int = 1) -> RGBA {
        tokens.increase(color, amount)
    }

    public func increase(_ color: RGBA, _ amount: Double) -> RGBA {
        tokens.increase(color, amount)
    }

    public func decrease(_ color: RGBA, _ amount: Int = 1) -> RGBA {
        tokens.decrease(color, amount)
    }

    public func decrease(_ color: RGBA, _ amount: Double) -> RGBA {
        tokens.decrease(color, amount)
    }

    /// The same theme re-resolved on a raised surface. Absolute: every view's surfaces are the base theme's.
    public func surface(_ name: SurfaceName) -> ResolvedTheme {
        let viewTokens = surfaceTokens[name] ?? tokens
        return ResolvedTheme(tokens: viewTokens, surfaceTokens: surfaceTokens)
    }
}

// MARK: - V1 Legacy Theme Types (`packages/theme/src/tui/v1.ts`)

/// Resolved V1 TUI theme structure (52 RGBA tokens + `thinkingOpacity` + `_hasSelectedListItemText`).
// parity: theme/src/tui/v1.ts#Theme [status=implemented hash=2143a30f4f40]
public struct V1Theme: Equatable, Hashable, Sendable {
    public let primary: RGBA
    public let secondary: RGBA
    public let accent: RGBA
    public let error: RGBA
    public let warning: RGBA
    public let success: RGBA
    public let info: RGBA
    public let text: RGBA
    public let textMuted: RGBA
    public let selectedListItemText: RGBA
    public let background: RGBA
    public let backgroundPanel: RGBA
    public let backgroundElement: RGBA
    public let backgroundMenu: RGBA
    public let border: RGBA
    public let borderActive: RGBA
    public let borderSubtle: RGBA
    public let diffAdded: RGBA
    public let diffRemoved: RGBA
    public let diffContext: RGBA
    public let diffHunkHeader: RGBA
    public let diffHighlightAdded: RGBA
    public let diffHighlightRemoved: RGBA
    public let diffAddedBg: RGBA
    public let diffRemovedBg: RGBA
    public let diffContextBg: RGBA
    public let diffLineNumber: RGBA
    public let diffAddedLineNumberBg: RGBA
    public let diffRemovedLineNumberBg: RGBA
    public let markdownText: RGBA
    public let markdownHeading: RGBA
    public let markdownLink: RGBA
    public let markdownLinkText: RGBA
    public let markdownCode: RGBA
    public let markdownBlockQuote: RGBA
    public let markdownEmph: RGBA
    public let markdownStrong: RGBA
    public let markdownHorizontalRule: RGBA
    public let markdownListItem: RGBA
    public let markdownListEnumeration: RGBA
    public let markdownImage: RGBA
    public let markdownImageText: RGBA
    public let markdownCodeBlock: RGBA
    public let syntaxComment: RGBA
    public let syntaxKeyword: RGBA
    public let syntaxFunction: RGBA
    public let syntaxVariable: RGBA
    public let syntaxString: RGBA
    public let syntaxNumber: RGBA
    public let syntaxType: RGBA
    public let syntaxOperator: RGBA
    public let syntaxPunctuation: RGBA
    public let thinkingOpacity: Double
    public var _hasSelectedListItemText: Bool

    public init(
        primary: RGBA,
        secondary: RGBA,
        accent: RGBA,
        error: RGBA,
        warning: RGBA,
        success: RGBA,
        info: RGBA,
        text: RGBA,
        textMuted: RGBA,
        selectedListItemText: RGBA,
        background: RGBA,
        backgroundPanel: RGBA,
        backgroundElement: RGBA,
        backgroundMenu: RGBA,
        border: RGBA,
        borderActive: RGBA,
        borderSubtle: RGBA,
        diffAdded: RGBA,
        diffRemoved: RGBA,
        diffContext: RGBA,
        diffHunkHeader: RGBA,
        diffHighlightAdded: RGBA,
        diffHighlightRemoved: RGBA,
        diffAddedBg: RGBA,
        diffRemovedBg: RGBA,
        diffContextBg: RGBA,
        diffLineNumber: RGBA,
        diffAddedLineNumberBg: RGBA,
        diffRemovedLineNumberBg: RGBA,
        markdownText: RGBA,
        markdownHeading: RGBA,
        markdownLink: RGBA,
        markdownLinkText: RGBA,
        markdownCode: RGBA,
        markdownBlockQuote: RGBA,
        markdownEmph: RGBA,
        markdownStrong: RGBA,
        markdownHorizontalRule: RGBA,
        markdownListItem: RGBA,
        markdownListEnumeration: RGBA,
        markdownImage: RGBA,
        markdownImageText: RGBA,
        markdownCodeBlock: RGBA,
        syntaxComment: RGBA,
        syntaxKeyword: RGBA,
        syntaxFunction: RGBA,
        syntaxVariable: RGBA,
        syntaxString: RGBA,
        syntaxNumber: RGBA,
        syntaxType: RGBA,
        syntaxOperator: RGBA,
        syntaxPunctuation: RGBA,
        thinkingOpacity: Double = 0.6,
        _hasSelectedListItemText: Bool = false
    ) {
        self.primary = primary
        self.secondary = secondary
        self.accent = accent
        self.error = error
        self.warning = warning
        self.success = success
        self.info = info
        self.text = text
        self.textMuted = textMuted
        self.selectedListItemText = selectedListItemText
        self.background = background
        self.backgroundPanel = backgroundPanel
        self.backgroundElement = backgroundElement
        self.backgroundMenu = backgroundMenu
        self.border = border
        self.borderActive = borderActive
        self.borderSubtle = borderSubtle
        self.diffAdded = diffAdded
        self.diffRemoved = diffRemoved
        self.diffContext = diffContext
        self.diffHunkHeader = diffHunkHeader
        self.diffHighlightAdded = diffHighlightAdded
        self.diffHighlightRemoved = diffHighlightRemoved
        self.diffAddedBg = diffAddedBg
        self.diffRemovedBg = diffRemovedBg
        self.diffContextBg = diffContextBg
        self.diffLineNumber = diffLineNumber
        self.diffAddedLineNumberBg = diffAddedLineNumberBg
        self.diffRemovedLineNumberBg = diffRemovedLineNumberBg
        self.markdownText = markdownText
        self.markdownHeading = markdownHeading
        self.markdownLink = markdownLink
        self.markdownLinkText = markdownLinkText
        self.markdownCode = markdownCode
        self.markdownBlockQuote = markdownBlockQuote
        self.markdownEmph = markdownEmph
        self.markdownStrong = markdownStrong
        self.markdownHorizontalRule = markdownHorizontalRule
        self.markdownListItem = markdownListItem
        self.markdownListEnumeration = markdownListEnumeration
        self.markdownImage = markdownImage
        self.markdownImageText = markdownImageText
        self.markdownCodeBlock = markdownCodeBlock
        self.syntaxComment = syntaxComment
        self.syntaxKeyword = syntaxKeyword
        self.syntaxFunction = syntaxFunction
        self.syntaxVariable = syntaxVariable
        self.syntaxString = syntaxString
        self.syntaxNumber = syntaxNumber
        self.syntaxType = syntaxType
        self.syntaxOperator = syntaxOperator
        self.syntaxPunctuation = syntaxPunctuation
        self.thinkingOpacity = thinkingOpacity
        self._hasSelectedListItemText = _hasSelectedListItemText
    }

    public subscript(_ color: V1ThemeColor) -> RGBA {
        switch color {
        case .primary: return primary
        case .secondary: return secondary
        case .accent: return accent
        case .error: return error
        case .warning: return warning
        case .success: return success
        case .info: return info
        case .text: return text
        case .textMuted: return textMuted
        case .selectedListItemText: return selectedListItemText
        case .background: return background
        case .backgroundPanel: return backgroundPanel
        case .backgroundElement: return backgroundElement
        case .backgroundMenu: return backgroundMenu
        case .border: return border
        case .borderActive: return borderActive
        case .borderSubtle: return borderSubtle
        case .diffAdded: return diffAdded
        case .diffRemoved: return diffRemoved
        case .diffContext: return diffContext
        case .diffHunkHeader: return diffHunkHeader
        case .diffHighlightAdded: return diffHighlightAdded
        case .diffHighlightRemoved: return diffHighlightRemoved
        case .diffAddedBg: return diffAddedBg
        case .diffRemovedBg: return diffRemovedBg
        case .diffContextBg: return diffContextBg
        case .diffLineNumber: return diffLineNumber
        case .diffAddedLineNumberBg: return diffAddedLineNumberBg
        case .diffRemovedLineNumberBg: return diffRemovedLineNumberBg
        case .markdownText: return markdownText
        case .markdownHeading: return markdownHeading
        case .markdownLink: return markdownLink
        case .markdownLinkText: return markdownLinkText
        case .markdownCode: return markdownCode
        case .markdownBlockQuote: return markdownBlockQuote
        case .markdownEmph: return markdownEmph
        case .markdownStrong: return markdownStrong
        case .markdownHorizontalRule: return markdownHorizontalRule
        case .markdownListItem: return markdownListItem
        case .markdownListEnumeration: return markdownListEnumeration
        case .markdownImage: return markdownImage
        case .markdownImageText: return markdownImageText
        case .markdownCodeBlock: return markdownCodeBlock
        case .syntaxComment: return syntaxComment
        case .syntaxKeyword: return syntaxKeyword
        case .syntaxFunction: return syntaxFunction
        case .syntaxVariable: return syntaxVariable
        case .syntaxString: return syntaxString
        case .syntaxNumber: return syntaxNumber
        case .syntaxType: return syntaxType
        case .syntaxOperator: return syntaxOperator
        case .syntaxPunctuation: return syntaxPunctuation
        }
    }
}

/// All 52 color property keys of a V1 theme.
// parity: theme/src/tui/v1.ts#ThemeColor [status=implemented hash=410e4b7935a5]
public enum V1ThemeColor: String, CaseIterable, Equatable, Hashable, Sendable, Codable, CodingKeyRepresentable {
    case primary
    case secondary
    case accent
    case error
    case warning
    case success
    case info
    case text
    case textMuted
    case selectedListItemText
    case background
    case backgroundPanel
    case backgroundElement
    case backgroundMenu
    case border
    case borderActive
    case borderSubtle
    case diffAdded
    case diffRemoved
    case diffContext
    case diffHunkHeader
    case diffHighlightAdded
    case diffHighlightRemoved
    case diffAddedBg
    case diffRemovedBg
    case diffContextBg
    case diffLineNumber
    case diffAddedLineNumberBg
    case diffRemovedLineNumberBg
    case markdownText
    case markdownHeading
    case markdownLink
    case markdownLinkText
    case markdownCode
    case markdownBlockQuote
    case markdownEmph
    case markdownStrong
    case markdownHorizontalRule
    case markdownListItem
    case markdownListEnumeration
    case markdownImage
    case markdownImageText
    case markdownCodeBlock
    case syntaxComment
    case syntaxKeyword
    case syntaxFunction
    case syntaxVariable
    case syntaxString
    case syntaxNumber
    case syntaxType
    case syntaxOperator
    case syntaxPunctuation
}

/// Hex color string (`#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`).
// parity: theme/src/tui/v1.ts#HexColor [status=implemented hash=16ce3edf1f88]
public typealias V1HexColor = String

/// Reference name into `defs` or another `theme` color key.
// parity: theme/src/tui/v1.ts#RefName [status=implemented hash=7ef321b8d6e8]
public typealias V1RefName = String

/// Dark/light color pair in a V1 theme JSON file.
// parity: theme/src/tui/v1.ts#Variant [status=implemented hash=9f998d8c7685]
public struct V1ColorVariant: Equatable, Hashable, Sendable, Codable {
    public var dark: String
    public var light: String

    public init(dark: String, light: String) {
        self.dark = dark
        self.light = light
    }
}

/// Any color value accepted in a V1 theme JSON entry.
// parity: theme/src/tui/v1.ts#ColorValue [status=implemented hash=19fb8834be0c]
public enum V1ColorValue: Equatable, Hashable, Sendable, Codable {
    case string(String)
    case variant(V1ColorVariant)
    case rgba(RGBA)
    case ansi(Int)

    public static func variant(dark: String, light: String) -> V1ColorValue {
        .variant(V1ColorVariant(dark: dark, light: light))
    }

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let str = try? single.decode(String.self) {
            self = .string(str)
        } else if let intVal = try? single.decode(Int.self) {
            self = .ansi(intVal)
        } else if let variant = try? single.decode(V1ColorVariant.self) {
            self = .variant(variant)
        } else if let rgba = try? single.decode(RGBA.self) {
            self = .rgba(rgba)
        } else {
            throw ThemeError("Invalid V1 theme color")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case .string(let s): try single.encode(s)
        case .variant(let v): try single.encode(v)
        case .rgba(let r): try single.encode(r)
        case .ansi(let n): try single.encode(n)
        }
    }
}

/// Legacy V1 JSON theme document (`$schema`, `defs`, `theme`).
// parity: theme/src/tui/v1.ts#ThemeV1Json [status=implemented hash=d4b034778314]
public struct ThemeV1Json: Equatable, Hashable, Sendable, Codable {
    public var schema: String?
    public var defs: [String: String]?
    public var theme: [V1ThemeColor: V1ColorValue]
    public var thinkingOpacity: Double?

    public init(
        schema: String? = nil,
        defs: [String: String]? = nil,
        theme: [V1ThemeColor: V1ColorValue],
        thinkingOpacity: Double? = nil
    ) {
        self.schema = schema
        self.defs = defs
        self.theme = theme
        self.thinkingOpacity = thinkingOpacity
    }

    enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case defs
        case theme
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schema = try container.decodeIfPresent(String.self, forKey: .schema)
        self.defs = try container.decodeIfPresent([String: String].self, forKey: .defs)
        let themeContainer = try container.nestedContainer(keyedBy: ThemeDynamicCodingKey.self, forKey: .theme)
        var colors: [V1ThemeColor: V1ColorValue] = [:]
        var opacity: Double? = nil
        for key in themeContainer.allKeys {
            if key.stringValue == "thinkingOpacity" {
                opacity = try themeContainer.decode(Double.self, forKey: key)
            } else if let token = V1ThemeColor(rawValue: key.stringValue) {
                colors[token] = try themeContainer.decode(V1ColorValue.self, forKey: key)
            }
        }
        self.theme = colors
        self.thinkingOpacity = opacity
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(schema, forKey: .schema)
        try container.encodeIfPresent(defs, forKey: .defs)
        var themeContainer = container.nestedContainer(keyedBy: ThemeDynamicCodingKey.self, forKey: .theme)
        for color in V1ThemeColor.allCases {
            if let value = theme[color] {
                try themeContainer.encode(value, forKey: ThemeDynamicCodingKey(raw: color.rawValue))
            }
        }
        if let thinkingOpacity {
            try themeContainer.encode(thinkingOpacity, forKey: ThemeDynamicCodingKey(raw: "thinkingOpacity"))
        }
    }
}
