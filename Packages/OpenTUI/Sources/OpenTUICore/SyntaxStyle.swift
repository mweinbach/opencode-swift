/// Pure-Swift syntax highlight styling registry with hierarchical scope fallback,
/// cached multi-scope merging, and `LinkStyleResolving` conformance, matching
/// `packages/core/src/syntax-style.ts` and `packages/native/src/syntax-style.zig`.

// parity: native/src/syntax-style.zig#SyntaxStyleError [status=implemented hash=78e3a49e1da5]
public enum SyntaxStyleError: Error, Equatable, Hashable, Sendable {
    case outOfMemory
    case invalidId
    case styleNotFound
    case destroyed
}

/// Resolved foreground, background, and text attribute overrides for a syntax scope.
// parity: core/src/syntax-style.ts#StyleDefinition [status=implemented hash=dd42cabeb722]
public struct StyleDefinition: Equatable, Hashable, Sendable, Codable {
    public var fg: RGBA?
    public var bg: RGBA?
    public var bold: Bool?
    public var italic: Bool?
    public var underline: Bool?
    public var dim: Bool?
    public var strikethrough: Bool?

    public init(
        fg: RGBA? = nil,
        bg: RGBA? = nil,
        bold: Bool? = nil,
        italic: Bool? = nil,
        underline: Bool? = nil,
        dim: Bool? = nil,
        strikethrough: Bool? = nil
    ) {
        self.fg = fg
        self.bg = bg
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.dim = dim
        self.strikethrough = strikethrough
    }
}

/// Declarative input for registering a syntax scope style, accepting CSS/hex strings or `RGBA`.
// parity: core/src/syntax-style.ts#StyleDefinitionInput [status=implemented hash=5ce564a99f91]
public struct StyleDefinitionInput: Equatable, Hashable, Sendable {
    public var fg: Color?
    public var bg: Color?
    public var bold: Bool?
    public var italic: Bool?
    public var underline: Bool?
    public var dim: Bool?
    public var strikethrough: Bool?

    public init(
        fg: Color? = nil,
        bg: Color? = nil,
        bold: Bool? = nil,
        italic: Bool? = nil,
        underline: Bool? = nil,
        dim: Bool? = nil,
        strikethrough: Bool? = nil
    ) {
        self.fg = fg
        self.bg = bg
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.dim = dim
        self.strikethrough = strikethrough
    }

    public init(
        fg: (any ColorConvertible)? = nil,
        bg: (any ColorConvertible)? = nil,
        bold: Bool? = nil,
        italic: Bool? = nil,
        underline: Bool? = nil,
        dim: Bool? = nil,
        strikethrough: Bool? = nil
    ) {
        self.fg = fg?.asColor()
        self.bg = bg?.asColor()
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.dim = dim
        self.strikethrough = strikethrough
    }

    public func resolved() -> StyleDefinition {
        StyleDefinition(
            fg: fg.map { RGBA.clone($0.resolved()) },
            bg: bg.map { RGBA.clone($0.resolved()) },
            bold: bold,
            italic: italic,
            underline: underline,
            dim: dim,
            strikethrough: strikethrough
        )
    }
}

/// Result of composing one or more syntax scope styles into a single paintable style.
// parity: core/src/syntax-style.ts#MergedStyle [status=implemented hash=5bf48178322b]
public struct MergedStyle: Equatable, Hashable, Sendable, Codable {
    public var fg: RGBA?
    public var bg: RGBA?
    public var attributes: UInt32

    public init(fg: RGBA? = nil, bg: RGBA? = nil, attributes: UInt32 = TextAttributes.none) {
        self.fg = fg
        self.bg = bg
        self.attributes = attributes
    }
}

/// A TextMate / tree-sitter theme token rule mapping one or more scope names to a style.
// parity: core/src/syntax-style.ts#ThemeTokenStyle [status=implemented hash=df9f4138f89f]
public struct ThemeTokenStyle: Equatable, Hashable, Sendable {
    public struct Style: Equatable, Hashable, Sendable {
        public var foreground: Color?
        public var background: Color?
        public var bold: Bool?
        public var italic: Bool?
        public var underline: Bool?
        public var dim: Bool?
        public var strikethrough: Bool?

        public init(
            foreground: Color? = nil,
            background: Color? = nil,
            bold: Bool? = nil,
            italic: Bool? = nil,
            underline: Bool? = nil,
            dim: Bool? = nil,
            strikethrough: Bool? = nil
        ) {
            self.foreground = foreground
            self.background = background
            self.bold = bold
            self.italic = italic
            self.underline = underline
            self.dim = dim
            self.strikethrough = strikethrough
        }
    }

    public var scope: [String]
    public var style: Style

    public init(scope: [String], style: Style) {
        self.scope = scope
        self.style = style
    }
}

/// Flattens an array of `ThemeTokenStyle` rules into a dictionary of scope names to `StyleDefinition`.
// parity: core/src/syntax-style.ts#convertThemeToStyles [status=implemented hash=229e5cf0fc62]
public func convertThemeToStyles(_ theme: [ThemeTokenStyle]) -> [String: StyleDefinition] {
    var flatStyles: [String: StyleDefinition] = [:]
    for tokenStyle in theme {
        var definition = StyleDefinition()
        if let foreground = tokenStyle.style.foreground {
            definition.fg = foreground.resolved()
        }
        if let background = tokenStyle.style.background {
            definition.bg = background.resolved()
        }
        if let bold = tokenStyle.style.bold { definition.bold = bold }
        if let italic = tokenStyle.style.italic { definition.italic = italic }
        if let underline = tokenStyle.style.underline { definition.underline = underline }
        if let dim = tokenStyle.style.dim { definition.dim = dim }
        if let strikethrough = tokenStyle.style.strikethrough { definition.strikethrough = strikethrough }

        for scope in tokenStyle.scope {
            flatStyles[scope] = definition
        }
    }
    return flatStyles
}

/// Hierarchical syntax style table supporting dotted scope fallback
/// (`keyword.control.flow` -> `keyword.control` -> `keyword`), cached `mergeStyles`,
/// and `LinkStyleResolving` integration with `detectLinks`.
// parity: core/src/syntax-style.ts#SyntaxStyle [status=implemented hash=3cc8d85db367]
public final class SyntaxStyle: LinkStyleResolving, @unchecked Sendable {
    private static let idLimit: UInt32 = 0x8000_0000

    private var nameToId: [String: UInt32] = [:]
    private var nameCache: [String: UInt32] = [:]
    private var idToStyle: [UInt32: StyleDefinition] = [:]
    private var styleDefs: [String: StyleDefinition] = [:]
    private var insertionOrder: [String] = []
    private var mergedCache: [[String]: MergedStyle] = [:]
    private var nextId: UInt32 = 1
    public private(set) var isDestroyed: Bool = false

    public init() {}

    // parity: core/src/syntax-style.ts#SyntaxStyle.create [status=implemented hash=4bd51880dec9]
    public static func create() -> SyntaxStyle {
        SyntaxStyle()
    }

    // parity: core/src/syntax-style.ts#SyntaxStyle.fromTheme [status=implemented hash=cebe50c81c0b]
    public static func fromTheme(_ theme: [ThemeTokenStyle]) -> SyntaxStyle {
        fromStyles(convertThemeToStyles(theme))
    }

    // parity: core/src/syntax-style.ts#SyntaxStyle.fromStyles [status=implemented hash=9d9ed5b1ff07]
    public static func fromStyles(_ styles: [String: StyleDefinitionInput]) -> SyntaxStyle {
        let style = SyntaxStyle.create()
        for (name, styleDef) in styles {
            _ = style.registerStyle(name, styleDef)
        }
        return style
    }

    public static func fromStyles(_ styles: [String: StyleDefinition]) -> SyntaxStyle {
        let style = SyntaxStyle.create()
        for (name, styleDef) in styles {
            _ = style.registerStyle(name, styleDef)
        }
        return style
    }

    /// Registers or updates a named scope style and returns its stable non-zero ID.
    // parity: core/src/syntax-style.ts#SyntaxStyle.registerStyle [status=implemented hash=0f7907d9fabb]
    @discardableResult
    public func registerStyle(_ name: String, _ style: StyleDefinitionInput) -> UInt32 {
        registerStyle(name, style.resolved())
    }

    @discardableResult
    public func registerStyle(_ name: String, _ definition: StyleDefinition) -> UInt32 {
        precondition(!isDestroyed, "SyntaxStyle is destroyed")

        let id: UInt32
        if let existingId = nameToId[name] {
            id = existingId
            idToStyle[existingId] = definition
        } else {
            precondition(nextId > 0 && nextId < Self.idLimit, "SyntaxStyle ID limit reached")
            id = nextId
            nextId += 1
            nameToId[name] = id
            idToStyle[id] = definition
            insertionOrder.append(name)
        }

        nameCache[name] = id
        styleDefs[name] = definition
        mergedCache.removeAll(keepingCapacity: true)
        return id
    }

    /// Resolves an exact registered scope name to its numeric style ID.
    // parity: core/src/syntax-style.ts#SyntaxStyle.resolveStyleId [status=implemented hash=739850acd8e5]
    public func resolveStyleId(_ name: String) -> UInt32? {
        precondition(!isDestroyed, "SyntaxStyle is destroyed")
        if let cached = nameCache[name] {
            return cached
        }
        if let id = nameToId[name] {
            nameCache[name] = id
            return id
        }
        return nil
    }

    /// Resolves a scope name with hierarchical dotted-prefix fallback:
    /// `"keyword.control.flow"` -> `"keyword.control"` -> `"keyword"`.
    // parity: core/src/syntax-style.ts#SyntaxStyle.getStyleId [status=implemented hash=9297a3e25979]
    public func getStyleId(_ name: String) -> UInt32? {
        precondition(!isDestroyed, "SyntaxStyle is destroyed")
        if let exact = resolveStyleId(name) {
            return exact
        }
        var current = Substring(name)
        while let dotIndex = current.lastIndex(of: ".") {
            current = current[..<dotIndex]
            if let fallback = resolveStyleId(String(current)) {
                return fallback
            }
        }
        return nil
    }

    /// Looks up a registered `StyleDefinition` by its numeric style ID.
    public func resolveById(_ id: UInt32) -> StyleDefinition? {
        precondition(!isDestroyed, "SyntaxStyle is destroyed")
        return idToStyle[id]
    }

    // parity: core/src/syntax-style.ts#SyntaxStyle.getStyleCount [status=implemented hash=8aa8951f203b]
    public func getStyleCount() -> Int {
        precondition(!isDestroyed, "SyntaxStyle is destroyed")
        return idToStyle.count
    }

    // parity: core/src/syntax-style.ts#SyntaxStyle.clearNameCache [status=implemented hash=f13b59e070ad]
    public func clearNameCache() {
        precondition(!isDestroyed, "SyntaxStyle is destroyed")
        nameCache.removeAll(keepingCapacity: true)
    }

    /// Resolves the `StyleDefinition` for `name` using hierarchical dotted-scope fallback
    /// (`"a.b.c"` -> `"a.b"` -> `"a"`), applying OpenTUI's default strikethrough behavior
    /// for `"markup.strikethrough"`.
    // parity: core/src/syntax-style.ts#SyntaxStyle.getStyle [status=implemented hash=f499bc4e1981]
    public func getStyle(_ name: String) -> StyleDefinition? {
        precondition(!isDestroyed, "SyntaxStyle is destroyed")

        var resolved: StyleDefinition? = styleDefs[name]
        if resolved == nil {
            var current = Substring(name)
            while let dotIndex = current.lastIndex(of: ".") {
                current = current[..<dotIndex]
                if let candidate = styleDefs[String(current)] {
                    resolved = candidate
                    break
                }
            }
        }

        if name == "markup.strikethrough" && resolved?.strikethrough == nil {
            var merged = resolved ?? styleDefs["default"] ?? StyleDefinition()
            merged.strikethrough = true
            return merged
        }
        return resolved
    }

    /// Merges an ordered list of scope names (later names override non-nil fields from earlier ones)
    /// and caches the resulting `MergedStyle` until the next registration or `clearCache()`.
    // parity: core/src/syntax-style.ts#SyntaxStyle.mergeStyles [status=implemented hash=c93daa70930f]
    public func mergeStyles(_ styleNames: [String]) -> MergedStyle {
        precondition(!isDestroyed, "SyntaxStyle is destroyed")

        if let cached = mergedCache[styleNames] {
            return cached
        }

        var composed = StyleDefinition()
        for name in styleNames {
            guard let style = getStyle(name) else { continue }
            if let fg = style.fg { composed.fg = fg }
            if let bg = style.bg { composed.bg = bg }
            if let bold = style.bold { composed.bold = bold }
            if let italic = style.italic { composed.italic = italic }
            if let underline = style.underline { composed.underline = underline }
            if let dim = style.dim { composed.dim = dim }
            if let strikethrough = style.strikethrough { composed.strikethrough = strikethrough }
        }

        let attrs = createTextAttributes(
            bold: composed.bold ?? false,
            italic: composed.italic ?? false,
            underline: composed.underline ?? false,
            dim: composed.dim ?? false,
            strikethrough: composed.strikethrough ?? false
        )
        let merged = MergedStyle(fg: composed.fg, bg: composed.bg, attributes: attrs)
        mergedCache[styleNames] = merged
        return merged
    }

    public func mergeStyles(_ styleNames: String...) -> MergedStyle {
        mergeStyles(styleNames)
    }

    // parity: core/src/syntax-style.ts#SyntaxStyle.clearCache [status=implemented hash=68e1be4f7212]
    public func clearCache() {
        precondition(!isDestroyed, "SyntaxStyle is destroyed")
        mergedCache.removeAll(keepingCapacity: true)
    }

    // parity: core/src/syntax-style.ts#SyntaxStyle.getCacheSize [status=implemented hash=ed4d07ac35cb]
    public func getCacheSize() -> Int {
        precondition(!isDestroyed, "SyntaxStyle is destroyed")
        return mergedCache.count
    }

    // parity: core/src/syntax-style.ts#SyntaxStyle.getAllStyles [status=implemented hash=0a73279a768c]
    public func getAllStyles() -> [String: StyleDefinition] {
        precondition(!isDestroyed, "SyntaxStyle is destroyed")
        return styleDefs
    }

    // parity: core/src/syntax-style.ts#SyntaxStyle.getRegisteredNames [status=implemented hash=6cf7ced7fcc2]
    public func getRegisteredNames() -> [String] {
        precondition(!isDestroyed, "SyntaxStyle is destroyed")
        return insertionOrder
    }

    // parity: core/src/syntax-style.ts#SyntaxStyle.destroy [status=implemented hash=e28bf50f1d7b]
    public func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        nameToId.removeAll()
        nameCache.removeAll()
        idToStyle.removeAll()
        styleDefs.removeAll()
        insertionOrder.removeAll()
        mergedCache.removeAll()
    }

    // MARK: - LinkStyleResolving

    public func mergeLinkStyles(_ styleNames: [String]) -> LinkMergedStyle? {
        guard !isDestroyed else { return nil }
        let merged = mergeStyles(styleNames)
        return LinkMergedStyle(fg: merged.fg, bg: merged.bg, attributes: merged.attributes)
    }
}
