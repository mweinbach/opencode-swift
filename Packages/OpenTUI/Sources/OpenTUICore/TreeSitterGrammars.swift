import Synchronization

// MARK: - Custom Grammar Protocol & Registry

/// Pluggable pure-Swift syntax grammar emitting exact UTF-16 `SimpleHighlight` ranges.
///
/// Conformers may be registered at runtime via `TreeSitterGrammarRegistry.shared.register(_:)`
/// or `TreeSitterGrammars.registerGrammar(_:)` to extend or override built-in highlighting.
public protocol TreeSitterGrammar: Sendable {
    /// Canonical lowercase filetype identifier (for example `"rust"`, `"python"`, `"vue"`).
    var filetype: String { get }

    /// Optional lowercase aliases or extensions routed to this grammar.
    var aliases: [String] { get }

    /// Produces sorted, non-overlapping UTF-16 `SimpleHighlight` spans for `units`.
    func highlight(utf16 units: [UInt16]) -> [SimpleHighlight]
}

public extension TreeSitterGrammar {
    var aliases: [String] { [] }

    /// Convenience helper encoding `content` as UTF-16 code units before highlighting.
    func highlight(content: String) -> [SimpleHighlight] {
        highlight(utf16: Array(content.utf16))
    }
}

/// Closure-backed `TreeSitterGrammar` for concise custom grammar registration.
public struct ClosureTreeSitterGrammar: TreeSitterGrammar {
    public let filetype: String
    public let aliases: [String]
    private let tokenize: @Sendable ([UInt16]) -> [SimpleHighlight]

    public init(
        filetype: String,
        aliases: [String] = [],
        highlight: @escaping @Sendable ([UInt16]) -> [SimpleHighlight]
    ) {
        self.filetype = filetype.lowercased()
        self.aliases = aliases.map { $0.lowercased() }
        self.tokenize = highlight
    }

    public func highlight(utf16 units: [UInt16]) -> [SimpleHighlight] {
        tokenize(units)
    }
}

/// Thread-safe registry of built-in and custom `TreeSitterGrammar` implementations.
public final class TreeSitterGrammarRegistry: Sendable {
    public static let shared = TreeSitterGrammarRegistry()

    private struct State: Sendable {
        var customGrammars: [String: any TreeSitterGrammar] = [:]
        var customAliases: [String: String] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    /// Registers (or overrides) a custom grammar for its canonical `filetype` and all `aliases`.
    public func register(_ grammar: any TreeSitterGrammar) {
        let canonical = grammar.filetype.lowercased()
        guard !canonical.isEmpty else { return }
        state.withLock { s in
            s.customGrammars[canonical] = grammar
            for alias in grammar.aliases {
                let lower = alias.lowercased()
                if !lower.isEmpty && lower != canonical {
                    s.customAliases[lower] = canonical
                }
            }
        }
    }

    /// Registers a closure-based custom grammar for `filetype` and optional `aliases`.
    public func register(
        filetype: String,
        aliases: [String] = [],
        highlight: @escaping @Sendable ([UInt16]) -> [SimpleHighlight]
    ) {
        register(ClosureTreeSitterGrammar(filetype: filetype, aliases: aliases, highlight: highlight))
    }

    /// Removes a previously registered custom grammar and any aliases pointing to it.
    public func unregister(filetype: String) {
        let canonical = filetype.lowercased()
        state.withLock { s in
            s.customGrammars.removeValue(forKey: canonical)
            s.customAliases = s.customAliases.filter { $0.value != canonical }
        }
    }

    /// Clears all custom grammars registered in this registry (built-in grammars remain intact).
    public func resetCustomGrammars() {
        state.withLock { s in
            s.customGrammars.removeAll()
            s.customAliases.removeAll()
        }
    }

    /// Returns the set of canonical filetypes currently registered as custom grammars.
    public func registeredCustomFiletypes() -> Set<String> {
        state.withLock { Set($0.customGrammars.keys) }
    }

    /// Resolves `raw` (filetype, extension, path, basename, or fence info string) to a canonical filetype.
    public func canonicalFiletype(for raw: String) -> String {
        let trimmed = trimGrammarWhitespace(raw)
        guard !trimmed.isEmpty else { return "" }
        let lower = String(trimmed).lowercased()

        // 1. Direct custom grammar or custom alias lookup
        if let customMatch = state.withLock({ s -> String? in
            if s.customGrammars[lower] != nil { return lower }
            return s.customAliases[lower]
        }) {
            return customMatch
        }

        // 2. Direct built-in alias lookup (handles aliases like "udiff", "golang", "shell", "tf", "c#")
        if let directAlias = TreeSitterGrammars.aliasToCanonicalFiletype[lower] {
            return directAlias
        }
        if TreeSitterGrammars.supportedFiletypes.contains(lower) {
            return lower
        }

        // 3. Path / basename / extension / Markdown info-string resolution via resolve-ft.ts parity helpers
        if let resolved = resolveFiletype(raw) {
            let resolvedLower = resolved.lowercased()
            if let customMatch = state.withLock({ s -> String? in
                if s.customGrammars[resolvedLower] != nil { return resolvedLower }
                return s.customAliases[resolvedLower]
            }) {
                return customMatch
            }
            if let mapped = TreeSitterGrammars.aliasToCanonicalFiletype[resolvedLower] {
                return mapped
            }
            if TreeSitterGrammars.supportedFiletypes.contains(resolvedLower) {
                return resolvedLower
            }
        }

        // 4. Fallback extension extraction for filenames/paths whose extensions are in our 34+ grammar
        //    catalog or custom registry (e.g. `flake.nix`, `Info.plist`, `main.tf`, `Proof.agda`).
        if let ext = extractFilenameExtension(lower) {
            if let customMatch = state.withLock({ s -> String? in
                if s.customGrammars[ext] != nil { return ext }
                return s.customAliases[ext]
            }) {
                return customMatch
            }
            if let mapped = TreeSitterGrammars.aliasToCanonicalFiletype[ext] {
                return mapped
            }
            if TreeSitterGrammars.supportedFiletypes.contains(ext) {
                return ext
            }
        }

        return lower
    }

    /// Returns whether this registry has a built-in or custom grammar for `filetype`.
    public func supports(filetype: String) -> Bool {
        let canonical = canonicalFiletype(for: filetype)
        guard !canonical.isEmpty else { return false }
        if state.withLock({ $0.customGrammars[canonical] != nil }) {
            return true
        }
        return TreeSitterGrammars.builtInGrammar(forCanonical: canonical) != nil
    }

    /// Looks up the active grammar for `filetype` (custom registrations take precedence over built-ins).
    public func grammar(for filetype: String) -> (any TreeSitterGrammar)? {
        let canonical = canonicalFiletype(for: filetype)
        guard !canonical.isEmpty else { return nil }
        if let custom = state.withLock({ $0.customGrammars[canonical] }) {
            return custom
        }
        return TreeSitterGrammars.builtInGrammar(forCanonical: canonical)
    }

    /// Highlights `content` for `filetype` using the resolved grammar, returning exact UTF-16 offsets.
    public func highlight(content: String, filetype: String) -> SyntaxHighlightResult {
        guard !content.isEmpty else {
            return SyntaxHighlightResult()
        }
        let canonical = canonicalFiletype(for: filetype)
        guard let grammar = grammar(for: canonical) else {
            return SyntaxHighlightResult(
                highlights: [],
                warning: "Unsupported built-in syntax highlighter filetype: \(canonical)"
            )
        }
        let units = Array(content.utf16)
        return SyntaxHighlightResult(highlights: grammar.highlight(utf16: units))
    }
}

// MARK: - TreeSitterGrammars Catalog & Dispatcher

/// Pure-Swift Tree-Sitter grammar suite covering all 34 upstream OpenCode parsers from
/// `packages/tui/src/parsers-config.ts` plus OpenTUI's built-in parsers (`javascript`,
/// `javascriptreact`, `typescript`, `typescriptreact`, `markdown`, `markdown_inline`, `zig`).
public enum TreeSitterGrammars {
    /// Exact ordered list of all 34 upstream parser filetypes from `opencode/packages/tui/src/parsers-config.ts`.
    public static let upstreamParserFiletypes: [String] = [
        "python",
        "rust",
        "go",
        "cpp",
        "csharp",
        "bash",
        "c",
        "java",
        "kotlin",
        "ruby",
        "php",
        "scala",
        "html",
        "vue",
        "hcl",
        "json",
        "yaml",
        "haskell",
        "css",
        "julia",
        "lua",
        "ocaml",
        "clojure",
        "swift",
        "toml",
        "nix",
        "diff",
        "elixir",
        "fsharp",
        "r",
        "make",
        "vim",
        "xml",
        "agda",
    ]

    /// Built-in OpenTUI parser filetypes paired alongside the 34 upstream OpenCode parsers.
    public static let builtInOpenTUIFiletypes: [String] = [
        "javascript",
        "javascriptreact",
        "typescript",
        "typescriptreact",
        "markdown",
        "markdown_inline",
        "zig",
    ]

    /// Complete canonical set of built-in supported filetypes (all 34 upstream + 7 OpenTUI built-ins).
    public static let supportedFiletypes: Set<String> = Set(upstreamParserFiletypes + builtInOpenTUIFiletypes)

    /// Mapping from filetype aliases and extensions to their canonical grammar filetype.
    public static let aliasToCanonicalFiletype: [String: String] = [
        // Python
        "py": "python",
        "pyi": "python",
        "pyw": "python",
        // Rust
        "rs": "rust",
        // Go
        "golang": "go",
        // C / C++
        "h": "c",
        "cc": "cpp",
        "cxx": "cpp",
        "hpp": "cpp",
        "hxx": "cpp",
        "h++": "cpp",
        "hh": "cpp",
        "c++": "cpp",
        // C#
        "cs": "csharp",
        "c#": "csharp",
        "csx": "csharp",
        "c_sharp": "csharp",
        // Bash / Shell
        "sh": "bash",
        "zsh": "bash",
        "ksh": "bash",
        "shell": "bash",
        "shellscript": "bash",
        // Kotlin
        "kt": "kotlin",
        "kts": "kotlin",
        // Ruby
        "rb": "ruby",
        "rake": "ruby",
        "ru": "ruby",
        "gemspec": "ruby",
        // PHP
        "phtml": "php",
        // Scala
        "sc": "scala",
        "sbt": "scala",
        // HTML
        "htm": "html",
        // HCL / Terraform
        "tf": "hcl",
        "tfvars": "hcl",
        "terraform": "hcl",
        // JSON
        "jsonc": "json",
        // YAML
        "yml": "yaml",
        // Haskell
        "hs": "haskell",
        "lhs": "haskell",
        // CSS & CSS-like stylesheets
        "scss": "css",
        "sass": "css",
        "less": "css",
        // Julia
        "jl": "julia",
        // OCaml
        "ml": "ocaml",
        "mli": "ocaml",
        // Clojure
        "clj": "clojure",
        "cljs": "clojure",
        "cljc": "clojure",
        "edn": "clojure",
        // Diff
        "patch": "diff",
        "udiff": "diff",
        // Elixir
        "ex": "elixir",
        "exs": "elixir",
        // F#
        "fs": "fsharp",
        "fsx": "fsharp",
        "fsscript": "fsharp",
        "fsi": "fsharp",
        "f#": "fsharp",
        // Make
        "makefile": "make",
        "gnumakefile": "make",
        "mk": "make",
        // Vim
        "viml": "vim",
        "vimscript": "vim",
        // XML
        "xsl": "xml",
        "xslt": "xml",
        "svg": "xml",
        "plist": "xml",
        "xsd": "xml",
        // Agda
        "lagda": "agda",
        // OpenTUI built-in parsers
        "js": "javascript",
        "mjs": "javascript",
        "cjs": "javascript",
        "jsx": "javascriptreact",
        "ts": "typescript",
        "mts": "typescript",
        "cts": "typescript",
        "tsx": "typescriptreact",
        "mtsx": "typescriptreact",
        "ctsx": "typescriptreact",
        "md": "markdown",
        "mdown": "markdown",
        "mkd": "markdown",
        "zon": "zig",
    ]

    public static func canonicalFiletype(
        for raw: String,
        registry: TreeSitterGrammarRegistry = .shared
    ) -> String {
        registry.canonicalFiletype(for: raw)
    }

    public static func supports(
        filetype: String,
        registry: TreeSitterGrammarRegistry = .shared
    ) -> Bool {
        registry.supports(filetype: filetype)
    }

    public static func grammar(
        for filetype: String,
        registry: TreeSitterGrammarRegistry = .shared
    ) -> (any TreeSitterGrammar)? {
        registry.grammar(for: filetype)
    }

    public static func highlight(
        content: String,
        filetype: String,
        registry: TreeSitterGrammarRegistry = .shared
    ) -> SyntaxHighlightResult {
        registry.highlight(content: content, filetype: filetype)
    }

    public static func registerGrammar(_ grammar: any TreeSitterGrammar) {
        TreeSitterGrammarRegistry.shared.register(grammar)
    }

    public static func registerGrammar(
        filetype: String,
        aliases: [String] = [],
        highlight: @escaping @Sendable ([UInt16]) -> [SimpleHighlight]
    ) {
        TreeSitterGrammarRegistry.shared.register(filetype: filetype, aliases: aliases, highlight: highlight)
    }

    public static func unregisterGrammar(filetype: String) {
        TreeSitterGrammarRegistry.shared.unregister(filetype: filetype)
    }

    public static func resetCustomGrammars() {
        TreeSitterGrammarRegistry.shared.resetCustomGrammars()
    }

    fileprivate static func builtInGrammar(forCanonical canonical: String) -> (any TreeSitterGrammar)? {
        switch canonical {
        case "swift":
            return ClosureTreeSitterGrammar(filetype: "swift") { tokenizeCodeGrammar($0, spec: .swift) }
        case "typescript":
            return ClosureTreeSitterGrammar(filetype: "typescript") { tokenizeCodeGrammar($0, spec: .typeScript) }
        case "javascript":
            return ClosureTreeSitterGrammar(filetype: "javascript") { tokenizeCodeGrammar($0, spec: .javaScript) }
        case "typescriptreact":
            return ClosureTreeSitterGrammar(filetype: "typescriptreact") { tokenizeCodeGrammar($0, spec: .tsx) }
        case "javascriptreact":
            return ClosureTreeSitterGrammar(filetype: "javascriptreact") { tokenizeCodeGrammar($0, spec: .jsx) }
        case "rust":
            return ClosureTreeSitterGrammar(filetype: "rust") { tokenizeCodeGrammar($0, spec: .rust) }
        case "go":
            return ClosureTreeSitterGrammar(filetype: "go") { tokenizeCodeGrammar($0, spec: .go) }
        case "c":
            return ClosureTreeSitterGrammar(filetype: "c") { tokenizeCodeGrammar($0, spec: .c) }
        case "cpp":
            return ClosureTreeSitterGrammar(filetype: "cpp") { tokenizeCodeGrammar($0, spec: .cpp) }
        case "csharp":
            return ClosureTreeSitterGrammar(filetype: "csharp") { tokenizeCodeGrammar($0, spec: .csharp) }
        case "java":
            return ClosureTreeSitterGrammar(filetype: "java") { tokenizeCodeGrammar($0, spec: .java) }
        case "kotlin":
            return ClosureTreeSitterGrammar(filetype: "kotlin") { tokenizeCodeGrammar($0, spec: .kotlin) }
        case "scala":
            return ClosureTreeSitterGrammar(filetype: "scala") { tokenizeCodeGrammar($0, spec: .scala) }
        case "zig":
            return ClosureTreeSitterGrammar(filetype: "zig") { tokenizeCodeGrammar($0, spec: .zig) }
        case "python":
            return ClosureTreeSitterGrammar(filetype: "python") { tokenizePythonGrammar($0) }
        case "bash":
            return ClosureTreeSitterGrammar(filetype: "bash") { tokenizeBashGrammar($0) }
        case "ruby":
            return ClosureTreeSitterGrammar(filetype: "ruby") { tokenizeRubyGrammar($0) }
        case "php":
            return ClosureTreeSitterGrammar(filetype: "php") { tokenizePHPGrammar($0) }
        case "html":
            return ClosureTreeSitterGrammar(filetype: "html") { tokenizeMarkupGrammar($0, mode: .html) }
        case "vue":
            return ClosureTreeSitterGrammar(filetype: "vue") { tokenizeMarkupGrammar($0, mode: .vue) }
        case "xml":
            return ClosureTreeSitterGrammar(filetype: "xml") { tokenizeMarkupGrammar($0, mode: .xml) }
        case "css":
            return ClosureTreeSitterGrammar(filetype: "css") { tokenizeCSSGrammar($0) }
        case "json":
            return ClosureTreeSitterGrammar(filetype: "json") { tokenizeJSONGrammar($0) }
        case "yaml":
            return ClosureTreeSitterGrammar(filetype: "yaml") { tokenizeYAMLGrammar($0) }
        case "toml":
            return ClosureTreeSitterGrammar(filetype: "toml") { tokenizeTOMLGrammar($0) }
        case "hcl":
            return ClosureTreeSitterGrammar(filetype: "hcl") { tokenizeHCLGrammar($0) }
        case "haskell":
            return ClosureTreeSitterGrammar(filetype: "haskell") { tokenizeHaskellGrammar($0) }
        case "agda":
            return ClosureTreeSitterGrammar(filetype: "agda") { tokenizeAgdaGrammar($0) }
        case "ocaml":
            return ClosureTreeSitterGrammar(filetype: "ocaml") { tokenizeOCamlGrammar($0) }
        case "fsharp":
            return ClosureTreeSitterGrammar(filetype: "fsharp") { tokenizeFSharpGrammar($0) }
        case "julia":
            return ClosureTreeSitterGrammar(filetype: "julia") { tokenizeJuliaGrammar($0) }
        case "lua":
            return ClosureTreeSitterGrammar(filetype: "lua") { tokenizeLuaGrammar($0) }
        case "clojure":
            return ClosureTreeSitterGrammar(filetype: "clojure") { tokenizeClojureGrammar($0) }
        case "elixir":
            return ClosureTreeSitterGrammar(filetype: "elixir") { tokenizeElixirGrammar($0) }
        case "nix":
            return ClosureTreeSitterGrammar(filetype: "nix") { tokenizeNixGrammar($0) }
        case "r":
            return ClosureTreeSitterGrammar(filetype: "r") { tokenizeRGrammar($0) }
        case "make":
            return ClosureTreeSitterGrammar(filetype: "make") { tokenizeMakeGrammar($0) }
        case "vim":
            return ClosureTreeSitterGrammar(filetype: "vim") { tokenizeVimGrammar($0) }
        case "markdown":
            return ClosureTreeSitterGrammar(filetype: "markdown") { tokenizeMarkdownGrammar($0) }
        case "markdown_inline":
            return ClosureTreeSitterGrammar(filetype: "markdown_inline") { tokenizeMarkdownInlineGrammar($0) }
        case "diff":
            return ClosureTreeSitterGrammar(filetype: "diff") { tokenizeDiffGrammar($0) }
        default:
            return nil
        }
    }
}

private func extractFilenameExtension(_ lower: String) -> String? {
    // Take first whitespace-delimited token (for Markdown fence info strings like "flake.nix title=x")
    var tokenEnd = lower.startIndex
    while tokenEnd < lower.endIndex && !lower[tokenEnd].isWhitespace {
        tokenEnd = lower.index(after: tokenEnd)
    }
    let token = lower[..<tokenEnd]
    // Extract basename after last '/' or '\'
    var baseStart = token.startIndex
    var idx = token.startIndex
    while idx < token.endIndex {
        let ch = token[idx]
        let next = token.index(after: idx)
        if ch == "/" || ch == "\\" {
            baseStart = next
        }
        idx = next
    }
    let basename = token[baseStart..<token.endIndex]
    guard let dot = basename.lastIndex(of: ".") else { return nil }
    let afterDot = basename.index(after: dot)
    guard afterDot < basename.endIndex else { return nil }
    return String(basename[afterDot...])
}

private func trimGrammarWhitespace(_ value: String) -> Substring {
    var start = value.startIndex
    var end = value.endIndex
    while start < end, value[start].isWhitespace {
        start = value.index(after: start)
    }
    while end > start {
        let prev = value.index(before: end)
        if value[prev].isWhitespace {
            end = prev
        } else {
            break
        }
    }
    return value[start..<end]
}

// MARK: - UTF-16 Scanner & Monotonic Highlight Builder

private enum U16 {
    static let tab: UInt16 = 0x09
    static let lf: UInt16 = 0x0A
    static let cr: UInt16 = 0x0D
    static let space: UInt16 = 0x20
    static let bang: UInt16 = 0x21       // !
    static let quote: UInt16 = 0x22      // "
    static let hash: UInt16 = 0x23       // #
    static let dollar: UInt16 = 0x24     // $
    static let percent: UInt16 = 0x25    // %
    static let amp: UInt16 = 0x26        // &
    static let apos: UInt16 = 0x27       // '
    static let lparen: UInt16 = 0x28     // (
    static let rparen: UInt16 = 0x29     // )
    static let star: UInt16 = 0x2A       // *
    static let plus: UInt16 = 0x2B       // +
    static let comma: UInt16 = 0x2C      // ,
    static let minus: UInt16 = 0x2D      // -
    static let dot: UInt16 = 0x2E        // .
    static let slash: UInt16 = 0x2F      // /
    static let zero: UInt16 = 0x30       // 0
    static let one: UInt16 = 0x31        // 1
    static let seven: UInt16 = 0x37      // 7
    static let nine: UInt16 = 0x39       // 9
    static let colon: UInt16 = 0x3A      // :
    static let semi: UInt16 = 0x3B       // ;
    static let lt: UInt16 = 0x3C         // <
    static let eq: UInt16 = 0x3D         // =
    static let gt: UInt16 = 0x3E         // >
    static let question: UInt16 = 0x3F   // ?
    static let at: UInt16 = 0x40         // @
    static let upperA: UInt16 = 0x41
    static let upperB: UInt16 = 0x42
    static let upperC: UInt16 = 0x43
    static let upperE: UInt16 = 0x45
    static let upperF: UInt16 = 0x46
    static let upperL: UInt16 = 0x4C
    static let upperO: UInt16 = 0x4F
    static let upperR: UInt16 = 0x52
    static let upperS: UInt16 = 0x53
    static let upperU: UInt16 = 0x55
    static let upperX: UInt16 = 0x58
    static let upperZ: UInt16 = 0x5A
    static let lbracket: UInt16 = 0x5B   // [
    static let backslash: UInt16 = 0x5C  // \
    static let rbracket: UInt16 = 0x5D   // ]
    static let caret: UInt16 = 0x5E      // ^
    static let underscore: UInt16 = 0x5F // _
    static let backtick: UInt16 = 0x60   // `
    static let lowerA: UInt16 = 0x61
    static let lowerB: UInt16 = 0x62
    static let lowerC: UInt16 = 0x63
    static let lowerE: UInt16 = 0x65
    static let lowerF: UInt16 = 0x66
    static let lowerI: UInt16 = 0x69
    static let lowerO: UInt16 = 0x6F
    static let lowerQ: UInt16 = 0x71
    static let lowerR: UInt16 = 0x72
    static let lowerS: UInt16 = 0x73
    static let lowerU: UInt16 = 0x75
    static let lowerV: UInt16 = 0x76
    static let lowerX: UInt16 = 0x78
    static let lowerZ: UInt16 = 0x7A
    static let lbrace: UInt16 = 0x7B     // {
    static let pipe: UInt16 = 0x7C       // |
    static let rbrace: UInt16 = 0x7D     // }
    static let tilde: UInt16 = 0x7E      // ~

    @inline(__always) static func isLeadSurrogate(_ u: UInt16) -> Bool { u >= 0xD800 && u <= 0xDBFF }
    @inline(__always) static func isTrailSurrogate(_ u: UInt16) -> Bool { u >= 0xDC00 && u <= 0xDFFF }

    @inline(__always)
    static func step(_ units: [UInt16], _ index: Int) -> Int {
        if index + 1 < units.count && isLeadSurrogate(units[index]) && isTrailSurrogate(units[index + 1]) {
            return index + 2
        }
        return index + 1
    }

    @inline(__always) static func isDigit(_ u: UInt16) -> Bool { u >= zero && u <= nine }
    @inline(__always) static func isHexDigit(_ u: UInt16) -> Bool {
        isDigit(u) || (u >= lowerA && u <= lowerF) || (u >= upperA && u <= upperF)
    }
    @inline(__always) static func isASCIIUpper(_ u: UInt16) -> Bool { u >= upperA && u <= upperZ }
    @inline(__always) static func isASCIILower(_ u: UInt16) -> Bool { u >= lowerA && u <= lowerZ }
    @inline(__always) static func isASCIILetter(_ u: UInt16) -> Bool { isASCIIUpper(u) || isASCIILower(u) }
    @inline(__always) static func isIdentStart(_ u: UInt16, allowDollar: Bool = false) -> Bool {
        isASCIILetter(u) || u == underscore || (allowDollar && u == dollar)
    }
    @inline(__always) static func isIdentContinue(_ u: UInt16, allowDollar: Bool = false) -> Bool {
        isIdentStart(u, allowDollar: allowDollar) || isDigit(u)
    }
    @inline(__always) static func isInlineWS(_ u: UInt16) -> Bool { u == space || u == tab }
    @inline(__always) static func isWS(_ u: UInt16) -> Bool { u == space || u == tab || u == lf || u == cr }
    @inline(__always) static func isNewline(_ u: UInt16) -> Bool { u == lf || u == cr }

    @inline(__always)
    static func isBracket(_ u: UInt16) -> Bool {
        u == lparen || u == rparen || u == lbrace || u == rbrace || u == lbracket || u == rbracket
    }

    @inline(__always)
    static func isDelimiter(_ u: UInt16) -> Bool {
        u == comma || u == semi || u == dot
    }

    @inline(__always)
    static func isOperatorChar(_ u: UInt16) -> Bool {
        switch u {
        case plus, minus, star, slash, percent, eq, bang, lt, gt, amp, pipe, caret, tilde, question, colon:
            return true
        default:
            return false
        }
    }

    @inline(__always)
    static func slice(_ units: [UInt16], _ start: Int, _ end: Int) -> String {
        String(decoding: units[start..<end], as: UTF16.self)
    }

    static func matchesASCII(_ units: [UInt16], at offset: Int, _ text: String) -> Bool {
        let target = Array(text.utf16)
        guard offset >= 0 && offset + target.count <= units.count else { return false }
        for k in target.indices where units[offset + k] != target[k] {
            return false
        }
        return true
    }

    static func matchesASCII(_ units: [UInt16], at offset: Int, limit: Int, _ text: String) -> Bool {
        let target = Array(text.utf16)
        guard offset >= 0 && offset + target.count <= limit else { return false }
        for k in target.indices where units[offset + k] != target[k] {
            return false
        }
        return true
    }

    static func isAllCapsConstant(_ units: [UInt16], start: Int, end: Int) -> Bool {
        guard end - start >= 2 else { return false }
        var hasLetter = false
        for idx in start..<end {
            let u = units[idx]
            if isASCIIUpper(u) {
                hasLetter = true
            } else if isDigit(u) || u == underscore {
                continue
            } else {
                return false
            }
        }
        return hasLetter
    }

    static func lineEnd(_ units: [UInt16], from start: Int) -> Int {
        var i = start
        while i < units.count && !isNewline(units[i]) {
            i = step(units, i)
        }
        return i
    }

    static func nextLineStart(_ units: [UInt16], after lineEnd: Int) -> Int {
        guard lineEnd < units.count else { return units.count }
        if units[lineEnd] == cr && lineEnd + 1 < units.count && units[lineEnd + 1] == lf {
            return lineEnd + 2
        }
        return lineEnd + 1
    }

    static func scanURL(_ units: [UInt16], from start: Int, limit: Int) -> Int? {
        guard matchesASCII(units, at: start, limit: limit, "https://")
            || matchesASCII(units, at: start, limit: limit, "http://")
        else { return nil }
        var j = start
        while j < limit {
            let c = units[j]
            if isWS(c) || c == quote || c == apos || c == lt || c == gt || c == rparen || c == rbracket || c == rbrace {
                break
            }
            j = step(units, j)
        }
        while j > start && (units[j - 1] == dot || units[j - 1] == comma || units[j - 1] == semi) {
            j -= 1
        }
        return j > start + 8 ? j : nil
    }
}

/// Enforces strictly monotonic, non-overlapping, valid UTF-16 `SimpleHighlight` emission.
private struct HighlightBuilder {
    var highlights: [SimpleHighlight] = []
    private var lastEnd: Int = 0
    private let limit: Int

    init(unitCount: Int) {
        self.limit = unitCount
        self.highlights.reserveCapacity(max(8, unitCount / 6))
    }

    mutating func emit(_ start: Int, _ end: Int, _ group: String, meta: HighlightMeta? = nil) {
        let s = max(lastEnd, start)
        let e = min(limit, end)
        guard s < e else { return }
        highlights.append(SimpleHighlight(s, e, group, meta))
        lastEnd = e
    }

    mutating func emitEmbedded(_ subHighlights: [SimpleHighlight], offset: Int, maxEnd: Int) {
        for h in subHighlights {
            let s = h.start + offset
            let e = min(maxEnd, h.end + offset)
            emit(s, e, h.group, meta: h.meta)
        }
    }
}

// MARK: - Shared Stateful Multi-Line Scanners

private func scanDelimitedComment(
    _ units: [UInt16],
    from start: Int,
    open: [UInt16],
    close: [UInt16],
    nested: Bool
) -> Int {
    let n = units.count
    var i = start + open.count
    var depth = 1
    while i < n && depth > 0 {
        if nested && i + open.count <= n && matchUnits(units, at: i, open) {
            depth += 1
            i += open.count
        } else if i + close.count <= n && matchUnits(units, at: i, close) {
            depth -= 1
            i += close.count
        } else {
            i = U16.step(units, i)
        }
    }
    return i
}

@inline(__always)
private func matchUnits(_ units: [UInt16], at offset: Int, _ pattern: [UInt16]) -> Bool {
    guard offset + pattern.count <= units.count else { return false }
    for k in pattern.indices where units[offset + k] != pattern[k] {
        return false
    }
    return true
}

private func scanQuotedEnd(
    _ units: [UInt16],
    from start: Int,
    delimiter: UInt16,
    allowMultiline: Bool,
    allowEscapes: Bool = true,
    doubledQuoteEscape: Bool = false
) -> Int {
    let n = units.count
    var i = start + 1
    while i < n {
        let u = units[i]
        if allowEscapes && u == U16.backslash {
            i += 1
            if i < n { i = U16.step(units, i) }
            continue
        }
        if u == delimiter {
            if doubledQuoteEscape && i + 1 < n && units[i + 1] == delimiter {
                i += 2
                continue
            }
            return i + 1
        }
        if !allowMultiline && U16.isNewline(u) {
            return i
        }
        i = U16.step(units, i)
    }
    return n
}

private func scanTripleQuotedEnd(
    _ units: [UInt16],
    from start: Int,
    delimiter: UInt16,
    allowEscapes: Bool = true
) -> Int {
    let n = units.count
    var i = start + 3
    while i < n {
        if allowEscapes && units[i] == U16.backslash {
            i += 1
            if i < n { i = U16.step(units, i) }
            continue
        }
        if i + 2 < n && units[i] == delimiter && units[i + 1] == delimiter && units[i + 2] == delimiter {
            return i + 3
        }
        i = U16.step(units, i)
    }
    return n
}

private func scanEscapeLength(_ units: [UInt16], at backslashIndex: Int, limit: Int) -> Int {
    guard backslashIndex + 1 < limit else { return 1 }
    let next = units[backslashIndex + 1]
    if next == U16.lowerX {
        var j = backslashIndex + 2
        var digits = 0
        while j < limit && digits < 2 && U16.isHexDigit(units[j]) {
            j += 1
            digits += 1
        }
        return j - backslashIndex
    }
    if next == U16.lowerU {
        if backslashIndex + 2 < limit && units[backslashIndex + 2] == U16.lbrace {
            var j = backslashIndex + 3
            while j < limit && units[j] != U16.rbrace && !U16.isNewline(units[j]) {
                j += 1
            }
            if j < limit && units[j] == U16.rbrace { j += 1 }
            return j - backslashIndex
        }
        var j = backslashIndex + 2
        var digits = 0
        while j < limit && digits < 4 && U16.isHexDigit(units[j]) {
            j += 1
            digits += 1
        }
        return j - backslashIndex
    }
    if next == U16.upperU {
        var j = backslashIndex + 2
        var digits = 0
        while j < limit && digits < 8 && U16.isHexDigit(units[j]) {
            j += 1
            digits += 1
        }
        return j - backslashIndex
    }
    return U16.step(units, backslashIndex + 1) - backslashIndex
}

/// Emits a string span with `string.escape` sub-spans for backslash escapes and `string.special.url`
/// when the quoted interior is a pure HTTP(S) URL. Emits a single `string` span when plain.
private func emitStringSpan(
    _ units: [UInt16],
    start: Int,
    end: Int,
    contentStart: Int,
    contentEnd: Int,
    allowEscapes: Bool,
    detectURL: Bool = true,
    into out: inout HighlightBuilder
) {
    guard start < end else { return }

    if detectURL && contentStart < contentEnd {
        if let urlEnd = U16.scanURL(units, from: contentStart, limit: contentEnd), urlEnd == contentEnd {
            if start < contentStart { out.emit(start, contentStart, "string") }
            out.emit(contentStart, contentEnd, "string.special.url")
            if contentEnd < end { out.emit(contentEnd, end, "string") }
            return
        }
    }

    if !allowEscapes {
        out.emit(start, end, "string")
        return
    }

    // Fast path: check if any backslash exists inside contentStart..<contentEnd
    var hasBackslash = false
    var scan = contentStart
    while scan < contentEnd {
        if units[scan] == U16.backslash {
            hasBackslash = true
            break
        }
        scan += 1
    }
    guard hasBackslash else {
        out.emit(start, end, "string")
        return
    }

    var cursor = start
    var i = contentStart
    while i < contentEnd {
        if units[i] == U16.backslash {
            if cursor < i {
                out.emit(cursor, i, "string")
            }
            let escLen = scanEscapeLength(units, at: i, limit: contentEnd)
            let escEnd = min(contentEnd, i + escLen)
            out.emit(i, escEnd, "string.escape")
            i = escEnd
            cursor = escEnd
        } else {
            i = U16.step(units, i)
        }
    }
    if cursor < end {
        out.emit(cursor, end, "string")
    }
}

private func scanNumberLiteral(_ units: [UInt16], from start: Int, allowSuffix: Bool = true) -> Int {
    let n = units.count
    var i = start
    if i + 1 < n && units[i] == U16.zero {
        let next = units[i + 1]
        if next == U16.lowerX || next == U16.upperX {
            i += 2
            while i < n && (U16.isHexDigit(units[i]) || units[i] == U16.underscore) { i += 1 }
            return allowSuffix ? scanNumberSuffix(units, from: i) : i
        }
        if next == U16.lowerB || next == U16.upperB {
            i += 2
            while i < n && (units[i] == U16.zero || units[i] == U16.one || units[i] == U16.underscore) { i += 1 }
            return allowSuffix ? scanNumberSuffix(units, from: i) : i
        }
        if next == U16.lowerO || next == U16.upperO {
            i += 2
            while i < n && ((units[i] >= U16.zero && units[i] <= U16.seven) || units[i] == U16.underscore) { i += 1 }
            return allowSuffix ? scanNumberSuffix(units, from: i) : i
        }
    }

    while i < n && (U16.isDigit(units[i]) || units[i] == U16.underscore) { i += 1 }
    if i + 1 < n && units[i] == U16.dot && U16.isDigit(units[i + 1]) {
        i += 1
        while i < n && (U16.isDigit(units[i]) || units[i] == U16.underscore) { i += 1 }
    }
    if i < n && (units[i] == U16.lowerE || units[i] == U16.upperE) {
        var exp = i + 1
        if exp < n && (units[exp] == U16.plus || units[exp] == U16.minus) { exp += 1 }
        if exp < n && U16.isDigit(units[exp]) {
            i = exp
            while i < n && (U16.isDigit(units[i]) || units[i] == U16.underscore) { i += 1 }
        }
    }
    return allowSuffix ? scanNumberSuffix(units, from: i) : i
}

private func scanNumberSuffix(_ units: [UInt16], from start: Int) -> Int {
    let n = units.count
    var i = start
    while i < n && (U16.isASCIILetter(units[i]) || U16.isDigit(units[i])) {
        i += 1
    }
    return i
}

/// Scans a multi-line heredoc body starting at the line after the heredoc header.
/// Returns the UTF-16 offset immediately after the closing delimiter line.
private func scanHeredocBody(
    _ units: [UInt16],
    bodyStart: Int,
    delimiter: String,
    allowLeadingWhitespace: Bool,
    allowTrailingSemicolon: Bool = false
) -> Int {
    let n = units.count
    let delimUnits = Array(delimiter.utf16)
    var lineStart = bodyStart
    while lineStart < n {
        let lineEnd = U16.lineEnd(units, from: lineStart)
        var check = lineStart
        if allowLeadingWhitespace {
            while check < lineEnd && U16.isInlineWS(units[check]) { check += 1 }
        }
        if check + delimUnits.count <= lineEnd && matchUnits(units, at: check, delimUnits) {
            var after = check + delimUnits.count
            if allowTrailingSemicolon && after < lineEnd && units[after] == U16.semi {
                after += 1
            }
            while after < lineEnd && U16.isInlineWS(units[after]) { after += 1 }
            if after == lineEnd {
                return lineEnd
            }
        }
        lineStart = U16.nextLineStart(units, after: lineEnd)
    }
    return n
}

// MARK: - C-Family & Modern Compiled Languages Engine

private struct CodeGrammarSpec: Sendable {
    let keywords: Set<String>
    let functionKeywords: Set<String>
    let returnKeywords: Set<String>
    let operatorKeywords: Set<String>
    let booleans: Set<String>
    let constants: Set<String>
    let constantGroup: String
    let builtinConstants: Set<String>
    let builtinTypes: Set<String>
    let builtinTypeGroup: String
    let functionDeclKeywords: Set<String>
    let typeDeclKeywords: Set<String>
    let nestedBlockComments: Bool
    let allowDollarIdentifiers: Bool
    let supportTripleDoubleQuotes: Bool
    let supportBacktickStrings: Bool
    let backtickAllowsEscapes: Bool
    let supportSingleQuoteStrings: Bool
    let rustMode: Bool
    let swiftMode: Bool
    let cppMode: Bool
    let csharpMode: Bool
    let zigMode: Bool
    let scalaStringPrefix: Bool
    let jsxMode: Bool
    let supportPreprocessorHash: Bool
    let supportAtAttribute: Bool
    let supportArrowMemberAccess: Bool

    static let swift = CodeGrammarSpec(
        keywords: [
            "actor", "associatedtype", "async", "await", "borrowing", "break", "case", "catch",
            "class", "consuming", "continue", "default", "defer", "deinit", "do", "else", "enum",
            "extension", "fallthrough", "fileprivate", "final", "for", "get", "guard", "if",
            "import", "indirect", "infix", "init", "inout", "internal", "isolated", "lazy", "let",
            "macro", "mutating", "nonisolated", "nonmutating", "open", "operator", "optional",
            "override", "package", "postfix", "precedencegroup", "prefix", "private", "protocol",
            "public", "repeat", "required", "rethrows", "sending", "set", "some", "any", "static",
            "struct", "subscript", "super", "switch", "throw", "throws", "try", "typealias",
            "unowned", "var", "weak", "where", "while", "willSet", "didSet", "self", "Self",
        ],
        functionKeywords: ["func"],
        returnKeywords: ["return"],
        operatorKeywords: ["as", "is", "in"],
        booleans: ["true", "false"],
        constants: [],
        constantGroup: "constant",
        builtinConstants: ["nil"],
        builtinTypes: [
            "Int", "Int8", "Int16", "Int32", "Int64",
            "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
            "Float", "Double", "Bool", "String", "Substring", "Character",
            "Array", "Dictionary", "Set", "Optional", "Result", "Void", "Never",
            "Any", "AnyObject", "Error", "Sendable", "Equatable", "Hashable", "Codable",
            "Task", "Range", "ClosedRange", "Mutex",
        ],
        builtinTypeGroup: "type",
        functionDeclKeywords: ["func"],
        typeDeclKeywords: ["struct", "class", "enum", "protocol", "actor", "typealias", "extension"],
        nestedBlockComments: true,
        allowDollarIdentifiers: true,
        supportTripleDoubleQuotes: true,
        supportBacktickStrings: false,
        backtickAllowsEscapes: false,
        supportSingleQuoteStrings: false,
        rustMode: false,
        swiftMode: true,
        cppMode: false,
        csharpMode: false,
        zigMode: false,
        scalaStringPrefix: false,
        jsxMode: false,
        supportPreprocessorHash: false,
        supportAtAttribute: true,
        supportArrowMemberAccess: false
    )

    static let typeScript = CodeGrammarSpec(
        keywords: [
            "abstract", "asserts", "async", "await", "break", "case", "catch", "class", "const",
            "continue", "debugger", "declare", "default", "do", "else", "enum", "export", "extends",
            "finally", "for", "from", "get", "if", "implements", "import", "interface", "let",
            "module", "namespace", "override", "package", "private", "protected", "public",
            "readonly", "set", "static", "super", "switch", "this", "throw", "try", "type", "using",
            "var", "while", "with",
        ],
        functionKeywords: ["function"],
        returnKeywords: ["return", "yield"],
        operatorKeywords: ["as", "delete", "in", "infer", "instanceof", "is", "keyof", "new", "of", "satisfies", "typeof", "void"],
        booleans: ["true", "false"],
        constants: ["null"],
        constantGroup: "constant",
        builtinConstants: ["undefined", "NaN", "Infinity"],
        builtinTypes: [
            "string", "number", "boolean", "bigint", "symbol", "object", "unknown", "never", "any",
            "Array", "Map", "Set", "Promise", "Record", "Partial", "Required", "Readonly", "Pick",
            "Omit", "Uint8Array", "Uint16Array", "Uint32Array", "Error",
        ],
        builtinTypeGroup: "type",
        functionDeclKeywords: ["function"],
        typeDeclKeywords: ["class", "interface", "type", "enum"],
        nestedBlockComments: false,
        allowDollarIdentifiers: true,
        supportTripleDoubleQuotes: false,
        supportBacktickStrings: true,
        backtickAllowsEscapes: true,
        supportSingleQuoteStrings: true,
        rustMode: false,
        swiftMode: false,
        cppMode: false,
        csharpMode: false,
        zigMode: false,
        scalaStringPrefix: false,
        jsxMode: false,
        supportPreprocessorHash: false,
        supportAtAttribute: true,
        supportArrowMemberAccess: false
    )

    static let javaScript = typeScript

    static let tsx = CodeGrammarSpec(
        keywords: typeScript.keywords,
        functionKeywords: typeScript.functionKeywords,
        returnKeywords: typeScript.returnKeywords,
        operatorKeywords: typeScript.operatorKeywords,
        booleans: typeScript.booleans,
        constants: typeScript.constants,
        constantGroup: typeScript.constantGroup,
        builtinConstants: typeScript.builtinConstants,
        builtinTypes: typeScript.builtinTypes,
        builtinTypeGroup: typeScript.builtinTypeGroup,
        functionDeclKeywords: typeScript.functionDeclKeywords,
        typeDeclKeywords: typeScript.typeDeclKeywords,
        nestedBlockComments: false,
        allowDollarIdentifiers: true,
        supportTripleDoubleQuotes: false,
        supportBacktickStrings: true,
        backtickAllowsEscapes: true,
        supportSingleQuoteStrings: true,
        rustMode: false,
        swiftMode: false,
        cppMode: false,
        csharpMode: false,
        zigMode: false,
        scalaStringPrefix: false,
        jsxMode: true,
        supportPreprocessorHash: false,
        supportAtAttribute: true,
        supportArrowMemberAccess: false
    )

    static let jsx = tsx

    static let rust = CodeGrammarSpec(
        keywords: [
            "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
            "extern", "for", "if", "impl", "let", "loop", "match", "mod", "move", "mut", "pub",
            "ref", "self", "Self", "static", "struct", "super", "trait", "type", "union", "unsafe",
            "use", "where", "while",
        ],
        functionKeywords: ["fn"],
        returnKeywords: ["return"],
        operatorKeywords: ["as", "in"],
        booleans: ["true", "false"],
        constants: ["Some", "None", "Ok", "Err"],
        constantGroup: "constant",
        builtinConstants: [],
        builtinTypes: [
            "i8", "i16", "i32", "i64", "i128", "isize",
            "u8", "u16", "u32", "u64", "u128", "usize",
            "f32", "f64", "bool", "char", "str",
        ],
        builtinTypeGroup: "type.builtin",
        functionDeclKeywords: ["fn"],
        typeDeclKeywords: ["struct", "enum", "trait", "type", "union"],
        nestedBlockComments: true,
        allowDollarIdentifiers: false,
        supportTripleDoubleQuotes: false,
        supportBacktickStrings: false,
        backtickAllowsEscapes: false,
        supportSingleQuoteStrings: false,
        rustMode: true,
        swiftMode: false,
        cppMode: false,
        csharpMode: false,
        zigMode: false,
        scalaStringPrefix: false,
        jsxMode: false,
        supportPreprocessorHash: false,
        supportAtAttribute: false,
        supportArrowMemberAccess: false
    )

    static let go = CodeGrammarSpec(
        keywords: [
            "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough",
            "for", "go", "goto", "if", "import", "interface", "map", "package", "range", "select",
            "struct", "switch", "type", "var",
        ],
        functionKeywords: ["func"],
        returnKeywords: ["return"],
        operatorKeywords: [],
        booleans: ["true", "false"],
        constants: ["iota"],
        constantGroup: "constant",
        builtinConstants: ["nil"],
        builtinTypes: [
            "any", "bool", "byte", "comparable", "complex64", "complex128", "error", "float32",
            "float64", "int", "int8", "int16", "int32", "int64", "rune", "string", "uint", "uint8",
            "uint16", "uint32", "uint64", "uintptr",
        ],
        builtinTypeGroup: "type.builtin",
        functionDeclKeywords: ["func"],
        typeDeclKeywords: ["type", "struct", "interface"],
        nestedBlockComments: false,
        allowDollarIdentifiers: false,
        supportTripleDoubleQuotes: false,
        supportBacktickStrings: true,
        backtickAllowsEscapes: false,
        supportSingleQuoteStrings: true,
        rustMode: false,
        swiftMode: false,
        cppMode: false,
        csharpMode: false,
        zigMode: false,
        scalaStringPrefix: false,
        jsxMode: false,
        supportPreprocessorHash: false,
        supportAtAttribute: false,
        supportArrowMemberAccess: false
    )

    static let c = CodeGrammarSpec(
        keywords: [
            "auto", "break", "case", "const", "constexpr", "continue", "default", "do", "else",
            "enum", "extern", "for", "goto", "if", "inline", "register", "restrict", "static",
            "struct", "switch", "typedef", "union", "volatile", "while", "_Atomic", "_Generic",
            "_Noreturn", "_Static_assert", "_Thread_local",
        ],
        functionKeywords: [],
        returnKeywords: ["return"],
        operatorKeywords: ["sizeof", "alignof", "_Alignof", "typeof"],
        booleans: ["true", "false"],
        constants: [],
        constantGroup: "constant",
        builtinConstants: ["NULL", "nullptr", "EOF"],
        builtinTypes: [
            "void", "bool", "_Bool", "char", "signed", "unsigned", "short", "int", "long", "float",
            "double", "size_t", "ssize_t", "ptrdiff_t", "intptr_t", "uintptr_t", "int8_t", "int16_t",
            "int32_t", "int64_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t", "wchar_t", "FILE",
        ],
        builtinTypeGroup: "type.builtin",
        functionDeclKeywords: [],
        typeDeclKeywords: ["struct", "enum", "union", "typedef"],
        nestedBlockComments: false,
        allowDollarIdentifiers: false,
        supportTripleDoubleQuotes: false,
        supportBacktickStrings: false,
        backtickAllowsEscapes: false,
        supportSingleQuoteStrings: true,
        rustMode: false,
        swiftMode: false,
        cppMode: true,
        csharpMode: false,
        zigMode: false,
        scalaStringPrefix: false,
        jsxMode: false,
        supportPreprocessorHash: true,
        supportAtAttribute: false,
        supportArrowMemberAccess: true
    )

    static let cpp = CodeGrammarSpec(
        keywords: [
            "alignas", "asm", "auto", "break", "case", "catch", "class", "concept", "const",
            "consteval", "constexpr", "constinit", "continue", "co_await", "decltype", "default",
            "do", "else", "enum", "explicit", "export", "extern", "final", "for", "friend", "goto",
            "if", "inline", "mutable", "namespace", "noexcept", "operator", "override", "private",
            "protected", "public", "register", "reinterpret_cast", "requires", "restrict", "static",
            "static_assert", "static_cast", "dynamic_cast", "const_cast", "struct", "switch",
            "template", "this", "thread_local", "throw", "try", "typedef", "typename", "union",
            "using", "virtual", "volatile", "while",
        ],
        functionKeywords: [],
        returnKeywords: ["return", "co_return", "co_yield"],
        operatorKeywords: [
            "alignof", "and", "bitand", "bitor", "compl", "delete", "new", "not", "or", "sizeof",
            "typeid", "xor",
        ],
        booleans: ["true", "false"],
        constants: ["nullptr"],
        constantGroup: "constant",
        builtinConstants: ["NULL", "EOF"],
        builtinTypes: [
            "void", "bool", "char", "signed", "unsigned", "short", "int", "long", "float", "double",
            "wchar_t", "char8_t", "char16_t", "char32_t", "size_t", "ssize_t", "ptrdiff_t",
            "intptr_t", "uintptr_t", "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t",
            "uint32_t", "uint64_t", "string", "string_view", "vector", "map", "unordered_map",
            "unique_ptr", "shared_ptr", "optional", "variant", "span",
        ],
        builtinTypeGroup: "type.builtin",
        functionDeclKeywords: [],
        typeDeclKeywords: ["struct", "class", "enum", "union", "typename", "namespace", "concept"],
        nestedBlockComments: false,
        allowDollarIdentifiers: false,
        supportTripleDoubleQuotes: false,
        supportBacktickStrings: false,
        backtickAllowsEscapes: false,
        supportSingleQuoteStrings: true,
        rustMode: false,
        swiftMode: false,
        cppMode: true,
        csharpMode: false,
        zigMode: false,
        scalaStringPrefix: false,
        jsxMode: false,
        supportPreprocessorHash: true,
        supportAtAttribute: false,
        supportArrowMemberAccess: true
    )

    static let csharp = CodeGrammarSpec(
        keywords: [
            "abstract", "async", "await", "base", "break", "case", "catch", "checked", "class",
            "const", "continue", "default", "delegate", "do", "else", "enum", "event", "explicit",
            "extern", "file", "finally", "fixed", "for", "foreach", "get", "goto", "if", "implicit",
            "in", "init", "interface", "internal", "lock", "namespace", "operator", "out", "override",
            "params", "partial", "private", "protected", "public", "readonly", "record", "ref",
            "required", "scoped", "sealed", "set", "static", "struct", "switch", "this", "throw",
            "try", "unchecked", "unsafe", "using", "var", "virtual", "volatile", "when", "where",
            "while",
        ],
        functionKeywords: [],
        returnKeywords: ["return", "yield"],
        operatorKeywords: ["and", "as", "is", "nameof", "new", "not", "or", "sizeof", "stackalloc", "typeof"],
        booleans: ["true", "false"],
        constants: [],
        constantGroup: "constant",
        builtinConstants: ["null"],
        builtinTypes: [
            "void", "bool", "byte", "sbyte", "char", "decimal", "double", "float", "int", "uint",
            "nint", "nuint", "long", "ulong", "short", "ushort", "object", "string", "dynamic",
        ],
        builtinTypeGroup: "type.builtin",
        functionDeclKeywords: [],
        typeDeclKeywords: ["class", "struct", "record", "interface", "enum", "namespace"],
        nestedBlockComments: false,
        allowDollarIdentifiers: false,
        supportTripleDoubleQuotes: true,
        supportBacktickStrings: false,
        backtickAllowsEscapes: false,
        supportSingleQuoteStrings: true,
        rustMode: false,
        swiftMode: false,
        cppMode: false,
        csharpMode: true,
        zigMode: false,
        scalaStringPrefix: false,
        jsxMode: false,
        supportPreprocessorHash: true,
        supportAtAttribute: false,
        supportArrowMemberAccess: false
    )

    static let java = CodeGrammarSpec(
        keywords: [
            "abstract", "assert", "break", "case", "catch", "class", "continue", "default", "do",
            "else", "enum", "exports", "extends", "final", "finally", "for", "if", "implements",
            "import", "interface", "module", "native", "non-sealed", "open", "opens", "package",
            "permits", "private", "protected", "provides", "public", "record", "requires", "sealed",
            "static", "strictfp", "super", "switch", "synchronized", "this", "throw", "throws", "to",
            "transient", "transitive", "try", "uses", "var", "volatile", "when", "while", "with",
        ],
        functionKeywords: [],
        returnKeywords: ["return", "yield"],
        operatorKeywords: ["instanceof", "new"],
        booleans: ["true", "false"],
        constants: [],
        constantGroup: "constant",
        builtinConstants: ["null"],
        builtinTypes: ["boolean", "byte", "char", "double", "float", "int", "long", "short", "void"],
        builtinTypeGroup: "type.builtin",
        functionDeclKeywords: [],
        typeDeclKeywords: ["class", "interface", "enum", "record"],
        nestedBlockComments: false,
        allowDollarIdentifiers: true,
        supportTripleDoubleQuotes: true,
        supportBacktickStrings: false,
        backtickAllowsEscapes: false,
        supportSingleQuoteStrings: true,
        rustMode: false,
        swiftMode: false,
        cppMode: false,
        csharpMode: false,
        zigMode: false,
        scalaStringPrefix: false,
        jsxMode: false,
        supportPreprocessorHash: false,
        supportAtAttribute: true,
        supportArrowMemberAccess: false
    )

    static let kotlin = CodeGrammarSpec(
        keywords: [
            "abstract", "actual", "annotation", "by", "catch", "class", "companion", "const",
            "constructor", "crossinline", "data", "delegate", "do", "else", "enum", "expect",
            "external", "final", "finally", "for", "get", "if", "import", "infix", "init", "inline",
            "inner", "interface", "internal", "lateinit", "noinline", "object", "open", "operator",
            "out", "override", "package", "private", "protected", "public", "reified", "sealed",
            "set", "super", "suspend", "tailrec", "this", "throw", "try", "typealias", "val",
            "value", "var", "vararg", "when", "where", "while",
        ],
        functionKeywords: ["fun"],
        returnKeywords: ["return"],
        operatorKeywords: ["as", "in", "is"],
        booleans: ["true", "false"],
        constants: [],
        constantGroup: "constant",
        builtinConstants: ["null"],
        builtinTypes: [
            "Any", "Unit", "Nothing", "Boolean", "Byte", "Short", "Int", "Long", "UByte", "UShort",
            "UInt", "ULong", "Float", "Double", "Char", "String", "Array", "List", "Map", "Set",
        ],
        builtinTypeGroup: "type.builtin",
        functionDeclKeywords: ["fun"],
        typeDeclKeywords: ["class", "interface", "object", "typealias", "enum"],
        nestedBlockComments: true,
        allowDollarIdentifiers: false,
        supportTripleDoubleQuotes: true,
        supportBacktickStrings: true,
        backtickAllowsEscapes: false,
        supportSingleQuoteStrings: true,
        rustMode: false,
        swiftMode: false,
        cppMode: false,
        csharpMode: false,
        zigMode: false,
        scalaStringPrefix: false,
        jsxMode: false,
        supportPreprocessorHash: false,
        supportAtAttribute: true,
        supportArrowMemberAccess: false
    )

    static let scala = CodeGrammarSpec(
        keywords: [
            "abstract", "case", "catch", "class", "derives", "do", "else", "end", "enum", "export",
            "extends", "extension", "final", "finally", "for", "given", "if", "implicit", "import",
            "inline", "lazy", "match", "object", "opaque", "open", "override", "package", "private",
            "protected", "sealed", "super", "then", "this", "throw", "trait", "transparent", "try",
            "type", "using", "val", "var", "while", "with",
        ],
        functionKeywords: ["def"],
        returnKeywords: ["return", "yield"],
        operatorKeywords: ["new"],
        booleans: ["true", "false"],
        constants: [],
        constantGroup: "constant",
        builtinConstants: ["null", "None", "Nil"],
        builtinTypes: [
            "Any", "AnyVal", "AnyRef", "Unit", "Nothing", "Null", "Boolean", "Byte", "Short", "Int",
            "Long", "Float", "Double", "Char", "String", "Option", "Either", "List", "Seq", "Map",
            "Set", "Future",
        ],
        builtinTypeGroup: "type.builtin",
        functionDeclKeywords: ["def"],
        typeDeclKeywords: ["class", "trait", "object", "enum", "type"],
        nestedBlockComments: true,
        allowDollarIdentifiers: true,
        supportTripleDoubleQuotes: true,
        supportBacktickStrings: true,
        backtickAllowsEscapes: false,
        supportSingleQuoteStrings: true,
        rustMode: false,
        swiftMode: false,
        cppMode: false,
        csharpMode: false,
        zigMode: false,
        scalaStringPrefix: true,
        jsxMode: false,
        supportPreprocessorHash: false,
        supportAtAttribute: true,
        supportArrowMemberAccess: false
    )

    static let zig = CodeGrammarSpec(
        keywords: [
            "align", "allowzero", "anyframe", "anytype", "asm", "async", "await", "break", "callconv",
            "comptime", "const", "continue", "defer", "else", "enum", "errdefer", "error", "export",
            "extern", "for", "if", "inline", "linksection", "noalias", "noinline", "nosuspend",
            "opaque", "packed", "pub", "resume", "struct", "suspend", "switch", "test", "threadlocal",
            "union", "unreachable", "usingnamespace", "var", "volatile", "while",
        ],
        functionKeywords: ["fn"],
        returnKeywords: ["return"],
        operatorKeywords: ["and", "catch", "or", "orelse", "try"],
        booleans: ["true", "false"],
        constants: [],
        constantGroup: "constant",
        builtinConstants: ["null", "undefined"],
        builtinTypes: [
            "bool", "void", "noreturn", "type", "anyerror", "anyopaque", "comptime_int",
            "comptime_float", "isize", "usize", "c_char", "c_short", "c_ushort", "c_int", "c_uint",
            "c_long", "c_ulong", "c_longlong", "c_ulonglong", "c_longdouble", "f16", "f32", "f64",
            "f80", "f128", "i8", "u8", "i16", "u16", "i32", "u32", "i64", "u64", "i128", "u128",
        ],
        builtinTypeGroup: "type.builtin",
        functionDeclKeywords: ["fn"],
        typeDeclKeywords: ["struct", "enum", "union", "error", "opaque"],
        nestedBlockComments: false,
        allowDollarIdentifiers: false,
        supportTripleDoubleQuotes: false,
        supportBacktickStrings: false,
        backtickAllowsEscapes: false,
        supportSingleQuoteStrings: true,
        rustMode: false,
        swiftMode: false,
        cppMode: false,
        csharpMode: false,
        zigMode: true,
        scalaStringPrefix: false,
        jsxMode: false,
        supportPreprocessorHash: false,
        supportAtAttribute: false,
        supportArrowMemberAccess: false
    )
}

private func isZigArbitraryIntType(_ word: String) -> Bool {
    guard word.count >= 2, let first = word.utf8.first,
          first == UInt8(ascii: "i") || first == UInt8(ascii: "u")
    else { return false }
    var digits = 0
    for b in word.utf8.dropFirst() {
        guard b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") else { return false }
        digits += 1
    }
    return digits > 0
}

private func scanRustRawString(_ units: [UInt16], from start: Int) -> (end: Int, contentStart: Int, contentEnd: Int)? {
    let n = units.count
    var i = start
    if i < n && (units[i] == U16.lowerB || units[i] == U16.lowerC) {
        i += 1
    }
    guard i < n && units[i] == U16.lowerR else { return nil }
    i += 1
    var hashes = 0
    while i < n && units[i] == U16.hash {
        hashes += 1
        i += 1
    }
    guard i < n && units[i] == U16.quote else { return nil }
    let contentStart = i + 1
    i = contentStart
    while i < n {
        if units[i] == U16.quote {
            var matched = 0
            var j = i + 1
            while matched < hashes && j < n && units[j] == U16.hash {
                matched += 1
                j += 1
            }
            if matched == hashes {
                return (j, contentStart, i)
            }
        }
        i = U16.step(units, i)
    }
    return (n, contentStart, n)
}

private func scanSwiftRawString(_ units: [UInt16], from start: Int) -> Int? {
    let n = units.count
    var i = start
    var hashes = 0
    while i < n && units[i] == U16.hash {
        hashes += 1
        i += 1
    }
    guard hashes > 0 && i < n && units[i] == U16.quote else { return nil }
    let isTriple = i + 2 < n && units[i + 1] == U16.quote && units[i + 2] == U16.quote
    i += isTriple ? 3 : 1
    while i < n {
        if isTriple {
            if i + 2 < n && units[i] == U16.quote && units[i + 1] == U16.quote && units[i + 2] == U16.quote {
                var matched = 0
                var j = i + 3
                while matched < hashes && j < n && units[j] == U16.hash {
                    matched += 1
                    j += 1
                }
                if matched == hashes { return j }
            }
        } else {
            if units[i] == U16.quote {
                var matched = 0
                var j = i + 1
                while matched < hashes && j < n && units[j] == U16.hash {
                    matched += 1
                    j += 1
                }
                if matched == hashes { return j }
            }
            if U16.isNewline(units[i]) { return i }
        }
        i = U16.step(units, i)
    }
    return n
}

private func scanCppRawString(_ units: [UInt16], from start: Int) -> Int? {
    let n = units.count
    guard start + 2 < n && units[start] == U16.upperR && units[start + 1] == U16.quote else { return nil }
    var d = start + 2
    while d < n && units[d] != U16.lparen && !U16.isWS(units[d]) && units[d] != U16.backslash && d - (start + 2) <= 16 {
        d += 1
    }
    guard d < n && units[d] == U16.lparen else { return nil }
    let delim = Array(units[(start + 2)..<d])
    var closePattern: [UInt16] = [U16.rparen]
    closePattern.append(contentsOf: delim)
    closePattern.append(U16.quote)
    var i = d + 1
    while i < n {
        if matchUnits(units, at: i, closePattern) {
            return i + closePattern.count
        }
        i = U16.step(units, i)
    }
    return n
}

private func scanRustApostrophe(_ units: [UInt16], from start: Int) -> (end: Int, group: String)? {
    let n = units.count
    guard start + 1 < n && units[start] == U16.apos else { return nil }
    if units[start + 1] == U16.backslash {
        var i = start + 2
        if i < n { i = U16.step(units, i) }
        while i < n && units[i] != U16.apos && !U16.isNewline(units[i]) {
            i = U16.step(units, i)
        }
        if i < n && units[i] == U16.apos { return (i + 1, "string") }
        return nil
    }
    let afterChar = U16.step(units, start + 1)
    if afterChar < n && units[afterChar] == U16.apos {
        return (afterChar + 1, "string")
    }
    if U16.isIdentStart(units[start + 1]) {
        var i = start + 2
        while i < n && U16.isIdentContinue(units[i]) { i += 1 }
        return (i, "type")
    }
    return nil
}

private func isCStyleFunctionDecl(_ units: [UInt16], openParen: Int) -> Bool {
    let n = units.count
    guard openParen < n && units[openParen] == U16.lparen else { return false }
    var depth = 1
    var i = openParen + 1
    var steps = 0
    while i < n && depth > 0 && steps < 512 {
        if units[i] == U16.lparen { depth += 1 }
        else if units[i] == U16.rparen { depth -= 1 }
        i = U16.step(units, i)
        steps += 1
    }
    guard depth == 0 else { return false }
    // Scan past whitespace and optional trailing qualifiers (const, noexcept, override, throws X, -> T) to '{'
    var look = i
    var qualSteps = 0
    while look < n && qualSteps < 128 {
        let c = units[look]
        if U16.isWS(c) { look += 1; continue }
        if c == U16.lbrace { return true }
        if c == U16.semi || c == U16.rparen || c == U16.comma { return false }
        look = U16.step(units, look)
        qualSteps += 1
    }
    return false
}

private func tokenizeCodeGrammar(_ units: [UInt16], spec: CodeGrammarSpec) -> [SimpleHighlight] {
    let n = units.count
    var out = HighlightBuilder(unitCount: n)
    var i = 0
    var previousWord: String? = nil
    var precededByMember = false
    var expectParamList = false
    var inParamList = false
    var paramParenDepth = 0
    var paramAngleDepth = 0
    var expectParamName = false
    var lastLineStart = true

    while i < n {
        let u = units[i]

        if U16.isNewline(u) {
            lastLineStart = true
            i += 1
            continue
        }
        if U16.isInlineWS(u) {
            i += 1
            continue
        }

        // Line comment //
        if u == U16.slash && i + 1 < n && units[i + 1] == U16.slash {
            let end = U16.lineEnd(units, from: i + 2)
            out.emit(i, end, "comment")
            i = end
            continue
        }

        // Block comment /* ... */ (supports multi-line & nested where applicable)
        if u == U16.slash && i + 1 < n && units[i + 1] == U16.star {
            let end = scanDelimitedComment(
                units,
                from: i,
                open: [U16.slash, U16.star],
                close: [U16.star, U16.slash],
                nested: spec.nestedBlockComments
            )
            out.emit(i, end, "comment")
            i = end
            continue
        }

        // Zig multi-line string literal \\...
        if spec.zigMode && u == U16.backslash && i + 1 < n && units[i + 1] == U16.backslash {
            let end = U16.lineEnd(units, from: i + 2)
            out.emit(i, end, "string")
            i = end
            lastLineStart = false
            previousWord = nil
            precededByMember = false
            continue
        }

        // Zig @builtin(...) macro calls
        if spec.zigMode && u == U16.at && i + 1 < n && U16.isIdentStart(units[i + 1]) {
            var j = i + 2
            while j < n && U16.isIdentContinue(units[j]) { j += 1 }
            out.emit(i, j, "function.macro")
            i = j
            lastLineStart = false
            previousWord = nil
            precededByMember = false
            continue
        }

        // Rust attributes #[...] / #![...]
        if spec.rustMode && u == U16.hash {
            var k = i + 1
            if k < n && units[k] == U16.bang { k += 1 }
            if k < n && units[k] == U16.lbracket {
                out.emit(i, k, "attribute")
                out.emit(k, k + 1, "punctuation.bracket")
                i = k + 1
                if i < n && U16.isIdentStart(units[i]) {
                    var j = i + 1
                    while j < n && (U16.isIdentContinue(units[j]) || units[j] == U16.colon) { j += 1 }
                    out.emit(i, j, "attribute")
                    i = j
                }
                lastLineStart = false
                previousWord = nil
                precededByMember = false
                continue
            }
        }

        // C / C++ / C# preprocessor directives (#include, #define, #region, #if, ...)
        if spec.supportPreprocessorHash && u == U16.hash {
            var j = i + 1
            while j < n && U16.isInlineWS(units[j]) { j += 1 }
            let wordStart = j
            while j < n && U16.isIdentContinue(units[j]) { j += 1 }
            if j > wordStart {
                let directive = U16.slice(units, wordStart, j)
                out.emit(i, j, "keyword")
                i = j
                // C/C++ #include <header.h>
                if spec.cppMode && directive == "include" {
                    var h = i
                    while h < n && U16.isInlineWS(units[h]) { h += 1 }
                    if h < n && units[h] == U16.lt {
                        var close = h + 1
                        while close < n && units[close] != U16.gt && !U16.isNewline(units[close]) {
                            close = U16.step(units, close)
                        }
                        if close < n && units[close] == U16.gt {
                            out.emit(h, close + 1, "string")
                            i = close + 1
                        }
                    }
                } else if spec.cppMode && directive == "define" {
                    var m = i
                    while m < n && U16.isInlineWS(units[m]) { m += 1 }
                    if m < n && U16.isIdentStart(units[m]) {
                        var mEnd = m + 1
                        while mEnd < n && U16.isIdentContinue(units[mEnd]) { mEnd += 1 }
                        out.emit(m, mEnd, "function.macro")
                        i = mEnd
                    }
                }
                lastLineStart = false
                previousWord = nil
                precededByMember = false
                continue
            }
        }

        // C++ [[attribute]]
        if spec.cppMode && u == U16.lbracket && i + 1 < n && units[i + 1] == U16.lbracket {
            out.emit(i, i + 2, "punctuation.bracket")
            var j = i + 2
            while j + 1 < n && !(units[j] == U16.rbracket && units[j + 1] == U16.rbracket) && !U16.isNewline(units[j]) {
                if U16.isIdentStart(units[j]) {
                    let s = j
                    j += 1
                    while j < n && (U16.isIdentContinue(units[j]) || units[j] == U16.colon) { j += 1 }
                    out.emit(s, j, "attribute")
                } else {
                    j = U16.step(units, j)
                }
            }
            if j + 1 < n && units[j] == U16.rbracket && units[j + 1] == U16.rbracket {
                out.emit(j, j + 2, "punctuation.bracket")
                i = j + 2
            } else {
                i = j
            }
            lastLineStart = false
            previousWord = nil
            precededByMember = false
            continue
        }

        // C# [Attribute] at line start
        if spec.csharpMode && lastLineStart && u == U16.lbracket && i + 1 < n && U16.isASCIIUpper(units[i + 1]) {
            out.emit(i, i + 1, "punctuation.bracket")
            var j = i + 1
            while j < n && U16.isIdentContinue(units[j]) { j += 1 }
            out.emit(i + 1, j, "attribute")
            i = j
            lastLineStart = false
            previousWord = nil
            precededByMember = false
            continue
        }

        // Swift raw strings #"..."# / #"""..."""# and hash directives (#if) / macros (#expect(...))
        if spec.swiftMode && u == U16.hash {
            if let rawEnd = scanSwiftRawString(units, from: i) {
                out.emit(i, rawEnd, "string")
                i = rawEnd
                lastLineStart = false
                previousWord = nil
                precededByMember = false
                continue
            }
            if i + 1 < n && U16.isIdentStart(units[i + 1]) {
                var j = i + 2
                while j < n && U16.isIdentContinue(units[j]) { j += 1 }
                let group = (j < n && units[j] == U16.lparen) ? "function.macro" : "keyword"
                out.emit(i, j, group)
                i = j
                lastLineStart = false
                previousWord = nil
                precededByMember = false
                continue
            }
        }

        // @attribute / @decorator (Swift, TypeScript, Java, Kotlin, Scala)
        if spec.supportAtAttribute && u == U16.at && i + 1 < n && U16.isIdentStart(units[i + 1]) {
            var j = i + 2
            while j < n && U16.isIdentContinue(units[j]) { j += 1 }
            out.emit(i, j, "attribute")
            i = j
            lastLineStart = false
            previousWord = nil
            precededByMember = false
            continue
        }

        // C# verbatim / interpolated strings: @"...", $"...", $@"...", @$"..."
        if spec.csharpMode && (u == U16.at || u == U16.dollar) {
            var q = i
            var isVerbatim = false
            if q < n && (units[q] == U16.at || units[q] == U16.dollar) {
                if units[q] == U16.at { isVerbatim = true }
                q += 1
            }
            if q < n && (units[q] == U16.at || units[q] == U16.dollar) && units[q] != u {
                if units[q] == U16.at { isVerbatim = true }
                q += 1
            }
            if q < n && units[q] == U16.quote {
                if q + 2 < n && units[q + 1] == U16.quote && units[q + 2] == U16.quote {
                    let end = scanTripleQuotedEnd(units, from: q, delimiter: U16.quote, allowEscapes: false)
                    out.emit(i, end, "string")
                    i = end
                } else {
                    let end = scanQuotedEnd(
                        units,
                        from: q,
                        delimiter: U16.quote,
                        allowMultiline: isVerbatim,
                        allowEscapes: !isVerbatim,
                        doubledQuoteEscape: isVerbatim
                    )
                    emitStringSpan(
                        units,
                        start: i,
                        end: end,
                        contentStart: q + 1,
                        contentEnd: max(q + 1, end - 1),
                        allowEscapes: !isVerbatim,
                        into: &out
                    )
                    i = end
                }
                lastLineStart = false
                previousWord = nil
                precededByMember = false
                continue
            }
        }

        // Rust raw strings r#"..."#, br#"..."#, cr#"..."#
        if spec.rustMode && (u == U16.lowerR || u == U16.lowerB || u == U16.lowerC) {
            if let raw = scanRustRawString(units, from: i) {
                emitStringSpan(
                    units,
                    start: i,
                    end: raw.end,
                    contentStart: raw.contentStart,
                    contentEnd: raw.contentEnd,
                    allowEscapes: false,
                    into: &out
                )
                i = raw.end
                lastLineStart = false
                previousWord = nil
                precededByMember = false
                continue
            }
            if (u == U16.lowerB || u == U16.lowerC) && i + 1 < n && units[i + 1] == U16.quote {
                let end = scanQuotedEnd(units, from: i + 1, delimiter: U16.quote, allowMultiline: true)
                emitStringSpan(
                    units,
                    start: i,
                    end: end,
                    contentStart: i + 2,
                    contentEnd: max(i + 2, end - 1),
                    allowEscapes: true,
                    into: &out
                )
                i = end
                lastLineStart = false
                previousWord = nil
                precededByMember = false
                continue
            }
        }

        // C++ raw strings R"delim(...)delim"
        if spec.cppMode && u == U16.upperR {
            if let rawEnd = scanCppRawString(units, from: i) {
                out.emit(i, rawEnd, "string")
                i = rawEnd
                lastLineStart = false
                previousWord = nil
                precededByMember = false
                continue
            }
        }

        // Scala interpolated strings s"...", f"...", raw"..."
        if spec.scalaStringPrefix && (u == U16.lowerS || u == U16.lowerF || U16.matchesASCII(units, at: i, "raw\"")) {
            let prefixLen = (u == U16.lowerR) ? 3 : 1
            let q = i + prefixLen
            if q < n && units[q] == U16.quote {
                let isRaw = (u == U16.lowerR)
                if q + 2 < n && units[q + 1] == U16.quote && units[q + 2] == U16.quote {
                    let end = scanTripleQuotedEnd(units, from: q, delimiter: U16.quote, allowEscapes: false)
                    out.emit(i, end, "string")
                    i = end
                } else {
                    let end = scanQuotedEnd(units, from: q, delimiter: U16.quote, allowMultiline: false, allowEscapes: !isRaw)
                    emitStringSpan(
                        units,
                        start: i,
                        end: end,
                        contentStart: q + 1,
                        contentEnd: max(q + 1, end - 1),
                        allowEscapes: !isRaw,
                        into: &out
                    )
                    i = end
                }
                lastLineStart = false
                previousWord = nil
                precededByMember = false
                continue
            }
        }

        // Triple-quoted strings """..."""
        if spec.supportTripleDoubleQuotes
            && u == U16.quote
            && i + 2 < n
            && units[i + 1] == U16.quote
            && units[i + 2] == U16.quote
        {
            let allowEsc = !spec.csharpMode
            let end = scanTripleQuotedEnd(units, from: i, delimiter: U16.quote, allowEscapes: allowEsc)
            emitStringSpan(
                units,
                start: i,
                end: end,
                contentStart: i + 3,
                contentEnd: max(i + 3, end - 3),
                allowEscapes: allowEsc,
                detectURL: false,
                into: &out
            )
            i = end
            lastLineStart = false
            previousWord = nil
            precededByMember = false
            continue
        }

        // Double-quoted strings "..."
        if u == U16.quote {
            let allowMultiline = spec.rustMode
            let end = scanQuotedEnd(units, from: i, delimiter: U16.quote, allowMultiline: allowMultiline)
            emitStringSpan(
                units,
                start: i,
                end: end,
                contentStart: i + 1,
                contentEnd: max(i + 1, end - 1),
                allowEscapes: true,
                into: &out
            )
            i = end
            lastLineStart = false
            previousWord = nil
            precededByMember = false
            continue
        }

        // Backtick template / raw strings `...`
        if spec.supportBacktickStrings && u == U16.backtick {
            let end = scanQuotedEnd(
                units,
                from: i,
                delimiter: U16.backtick,
                allowMultiline: true,
                allowEscapes: spec.backtickAllowsEscapes
            )
            emitStringSpan(
                units,
                start: i,
                end: end,
                contentStart: i + 1,
                contentEnd: max(i + 1, end - 1),
                allowEscapes: spec.backtickAllowsEscapes,
                detectURL: false,
                into: &out
            )
            i = end
            lastLineStart = false
            previousWord = nil
            precededByMember = false
            continue
        }

        // Rust lifetimes & char literals
        if spec.rustMode && u == U16.apos {
            if let matched = scanRustApostrophe(units, from: i) {
                out.emit(i, matched.end, matched.group)
                i = matched.end
                lastLineStart = false
                previousWord = nil
                precededByMember = false
                continue
            }
        }

        // Single-quoted strings / char literals
        if spec.supportSingleQuoteStrings && u == U16.apos {
            let end = scanQuotedEnd(units, from: i, delimiter: U16.apos, allowMultiline: false)
            emitStringSpan(
                units,
                start: i,
                end: end,
                contentStart: i + 1,
                contentEnd: max(i + 1, end - 1),
                allowEscapes: true,
                into: &out
            )
            i = end
            lastLineStart = false
            previousWord = nil
            precededByMember = false
            continue
        }

        // JSX / TSX opening and closing tags: <Tag prop="v"> or </Tag>
        if spec.jsxMode && u == U16.lt {
            if let nextIdx = tryScanJSXTag(units, from: i, into: &out) {
                i = nextIdx
                lastLineStart = false
                previousWord = nil
                precededByMember = false
                continue
            }
        }

        // Numbers
        if U16.isDigit(u) {
            let end = scanNumberLiteral(units, from: i)
            out.emit(i, end, "number")
            i = end
            lastLineStart = false
            previousWord = nil
            precededByMember = false
            continue
        }

        // Identifiers, keywords, types, functions, methods, macros, parameters, properties
        if U16.isIdentStart(u, allowDollar: spec.allowDollarIdentifiers) {
            var j = i + 1
            while j < n && U16.isIdentContinue(units[j], allowDollar: spec.allowDollarIdentifiers) { j += 1 }
            let word = U16.slice(units, i, j)

            // Rust macro invocation: name!(...) or name![...]
            if spec.rustMode && j < n && units[j] == U16.bang && !precededByMember {
                let macroEnd = j + 1
                out.emit(i, macroEnd, "function.macro")
                previousWord = word
                precededByMember = false
                lastLineStart = false
                i = macroEnd
                continue
            }

            let nextIsCall = j < n && units[j] == U16.lparen
            let group: String?

            if spec.booleans.contains(word) {
                group = "boolean"
            } else if spec.constants.contains(word) {
                group = spec.constantGroup
            } else if spec.builtinConstants.contains(word) {
                group = "constant.builtin"
            } else if spec.functionKeywords.contains(word) && !precededByMember {
                group = "keyword.function"
                expectParamList = true
            } else if spec.returnKeywords.contains(word) && !precededByMember {
                group = "keyword.return"
            } else if spec.operatorKeywords.contains(word) && !precededByMember {
                group = "keyword.operator"
            } else if spec.keywords.contains(word) && !precededByMember {
                group = "keyword"
            } else if let prev = previousWord, spec.functionDeclKeywords.contains(prev) {
                group = "function"
                expectParamList = true
            } else if let prev = previousWord, spec.typeDeclKeywords.contains(prev) {
                group = "type"
            } else if (spec.builtinTypes.contains(word) || (spec.zigMode && isZigArbitraryIntType(word))) && !precededByMember {
                group = spec.builtinTypeGroup
            } else if inParamList && paramParenDepth == 1 && expectParamName && !nextIsCall && !precededByMember {
                // Parameter name in `func foo(name: Type)`, `fn bar(x: i32)`, `int add(int lhs, int rhs)`
                var look = j
                while look < n && U16.isInlineWS(units[look]) { look += 1 }
                let followedByParamSep = look < n && (
                    units[look] == U16.colon
                        || units[look] == U16.comma
                        || units[look] == U16.rparen
                        || units[look] == U16.eq
                        || units[look] == U16.question
                )
                if followedByParamSep {
                    group = "variable.parameter"
                    expectParamName = false
                } else if U16.isASCIIUpper(u) {
                    group = "type"
                } else if !spec.functionDeclKeywords.isEmpty {
                    group = "variable.parameter"
                    expectParamName = false
                } else {
                    group = nil
                }
            } else if nextIsCall {
                if !precededByMember && spec.functionDeclKeywords.isEmpty && isCStyleFunctionDecl(units, openParen: j) {
                    expectParamList = true
                }
                group = precededByMember ? "function.method" : "function"
            } else if precededByMember {
                group = "property"
            } else if U16.isAllCapsConstant(units, start: i, end: j) {
                group = "constant"
            } else if U16.isASCIIUpper(u) {
                group = "type"
            } else {
                group = nil
            }

            if let group {
                out.emit(i, j, group)
            }
            previousWord = word
            precededByMember = false
            lastLineStart = false
            i = j
            continue
        }

        // Arrow member access `->` for C / C++
        if spec.supportArrowMemberAccess && u == U16.minus && i + 1 < n && units[i + 1] == U16.gt {
            out.emit(i, i + 2, "operator")
            precededByMember = true
            previousWord = nil
            lastLineStart = false
            i += 2
            continue
        }

        // Brackets: ( ) { } [ ]
        if U16.isBracket(u) {
            out.emit(i, i + 1, "punctuation.bracket")
            if u == U16.lparen {
                if expectParamList && paramAngleDepth == 0 {
                    inParamList = true
                    expectParamList = false
                    paramParenDepth = 1
                    expectParamName = true
                } else if inParamList {
                    paramParenDepth += 1
                }
            } else if u == U16.rparen && inParamList {
                paramParenDepth -= 1
                if paramParenDepth <= 0 {
                    inParamList = false
                    paramParenDepth = 0
                    expectParamName = false
                }
            } else if u == U16.lbrace {
                expectParamList = false
                inParamList = false
                paramParenDepth = 0
            }
            precededByMember = false
            previousWord = nil
            lastLineStart = false
            i += 1
            continue
        }

        // Delimiters: , ; .
        if U16.isDelimiter(u) {
            out.emit(i, i + 1, "punctuation.delimiter")
            if u == U16.comma && inParamList && paramParenDepth == 1 {
                expectParamName = true
            }
            if u == U16.semi {
                expectParamList = false
                inParamList = false
            }
            precededByMember = (u == U16.dot)
            previousWord = nil
            lastLineStart = false
            i += 1
            continue
        }

        // Angle brackets tracking inside generic function declarations `fn parse<'a>(...)`
        if expectParamList && (u == U16.lt || u == U16.gt) {
            out.emit(i, i + 1, "punctuation.bracket")
            if u == U16.lt { paramAngleDepth += 1 } else if paramAngleDepth > 0 { paramAngleDepth -= 1 }
            precededByMember = false
            previousWord = nil
            lastLineStart = false
            i += 1
            continue
        }

        // Operators (stop before // or /*)
        if U16.isOperatorChar(u) {
            var j = i + 1
            while j < n && U16.isOperatorChar(units[j]) {
                if units[j] == U16.slash && j + 1 < n && (units[j + 1] == U16.slash || units[j + 1] == U16.star) {
                    break
                }
                j += 1
            }
            out.emit(i, j, "operator")
            if inParamList && paramParenDepth == 1 && u == U16.colon && j == i + 1 {
                expectParamName = false
            }
            precededByMember = false
            previousWord = nil
            lastLineStart = false
            i = j
            continue
        }

        lastLineStart = false
        previousWord = nil
        precededByMember = false
        i = U16.step(units, i)
    }

    return out.highlights
}

private func tryScanJSXTag(_ units: [UInt16], from start: Int, into out: inout HighlightBuilder) -> Int? {
    let n = units.count
    guard start + 1 < n && units[start] == U16.lt else { return nil }
    var j = start + 1
    var isClosing = false
    if units[j] == U16.slash {
        isClosing = true
        j += 1
    }
    guard j < n && U16.isASCIILetter(units[j]) else { return nil }
    let tagStart = j
    while j < n && (U16.isIdentContinue(units[j]) || units[j] == U16.dot || units[j] == U16.minus) {
        j += 1
    }
    let tagEnd = j

    // Confirm this looks like a JSX tag (followed by '>', '/>', or whitespace + attr/'>'), not a generic `<T>`
    var probe = tagEnd
    while probe < n && U16.isInlineWS(units[probe]) { probe += 1 }
    let validJSX: Bool
    if isClosing {
        validJSX = probe < n && units[probe] == U16.gt
    } else if probe < n && (units[probe] == U16.gt || (units[probe] == U16.slash && probe + 1 < n && units[probe + 1] == U16.gt)) {
        validJSX = true
    } else if probe > tagEnd && probe < n && U16.isASCIILetter(units[probe]) {
        // Check for attribute name followed by '=' or '>' or '/>'
        var a = probe
        while a < n && (U16.isIdentContinue(units[a]) || units[a] == U16.minus) { a += 1 }
        while a < n && U16.isInlineWS(units[a]) { a += 1 }
        validJSX = a < n && (units[a] == U16.eq || units[a] == U16.gt || units[a] == U16.slash)
    } else {
        validJSX = false
    }
    guard validJSX else { return nil }

    out.emit(start, isClosing ? start + 2 : start + 1, "punctuation.bracket")
    out.emit(tagStart, tagEnd, "tag")

    var cur = tagEnd
    while cur < n {
        let c = units[cur]
        if U16.isWS(c) {
            cur += 1
            continue
        }
        if c == U16.gt {
            out.emit(cur, cur + 1, "punctuation.bracket")
            return cur + 1
        }
        if c == U16.slash && cur + 1 < n && units[cur + 1] == U16.gt {
            out.emit(cur, cur + 2, "punctuation.bracket")
            return cur + 2
        }
        if U16.isIdentStart(c) {
            var aEnd = cur + 1
            while aEnd < n && (U16.isIdentContinue(units[aEnd]) || units[aEnd] == U16.minus) { aEnd += 1 }
            out.emit(cur, aEnd, "attribute")
            cur = aEnd
            continue
        }
        if c == U16.eq {
            out.emit(cur, cur + 1, "operator")
            cur += 1
            continue
        }
        if c == U16.quote || c == U16.apos {
            let sEnd = scanQuotedEnd(units, from: cur, delimiter: c, allowMultiline: false)
            emitStringSpan(units, start: cur, end: sEnd, contentStart: cur + 1, contentEnd: max(cur + 1, sEnd - 1), allowEscapes: true, into: &out)
            cur = sEnd
            continue
        }
        if c == U16.lbrace {
            out.emit(cur, cur + 1, "punctuation.bracket")
            var depth = 1
            let exprStart = cur + 1
            var e = exprStart
            while e < n && depth > 0 {
                if units[e] == U16.lbrace { depth += 1 }
                else if units[e] == U16.rbrace { depth -= 1; if depth == 0 { break } }
                e = U16.step(units, e)
            }
            if e > exprStart {
                let sub = tokenizeCodeGrammar(Array(units[exprStart..<e]), spec: .typeScript)
                out.emitEmbedded(sub, offset: exprStart, maxEnd: e)
            }
            if e < n && units[e] == U16.rbrace {
                out.emit(e, e + 1, "punctuation.bracket")
                cur = e + 1
            } else {
                cur = e
            }
            continue
        }
        return cur
    }
    return cur
}

// MARK: - Python Lexer

private let pythonKeywords: Set<String> = [
    "as", "assert", "async", "await", "break", "case", "class", "continue", "def", "del",
    "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "lambda",
    "match", "nonlocal", "pass", "raise", "try", "while", "with",
]

private let pythonReturnKeywords: Set<String> = ["return", "yield"]
private let pythonOperatorKeywords: Set<String> = ["and", "in", "is", "not", "or"]

private let pythonBuiltinTypes: Set<String> = [
    "bool", "bytearray", "bytes", "complex", "dict", "float", "frozenset", "int", "list",
    "memoryview", "object", "range", "set", "str", "tuple", "type",
]

private func isPythonStringPrefix(_ u: UInt16) -> Bool {
    switch u {
    case U16.lowerF, U16.upperF, U16.lowerR, U16.upperR, U16.lowerB, U16.upperB, U16.lowerU, U16.upperU:
        return true
    default:
        return false
    }
}

private func tokenizePythonGrammar(_ units: [UInt16]) -> [SimpleHighlight] {
    let n = units.count
    var out = HighlightBuilder(unitCount: n)
    var i = 0
    var previousWord: String? = nil
    var precededByDot = false
    var expectParamList = false
    var inParamList = false
    var paramParenDepth = 0
    var expectParamName = false

    while i < n {
        let u = units[i]

        if U16.isWS(u) {
            i += 1
            continue
        }

        // Comment # ...
        if u == U16.hash {
            let end = U16.lineEnd(units, from: i + 1)
            out.emit(i, end, "comment")
            i = end
            continue
        }

        // Decorator @name.sub
        if u == U16.at && i + 1 < n && U16.isIdentStart(units[i + 1]) {
            var j = i + 2
            while j < n && (U16.isIdentContinue(units[j]) || units[j] == U16.dot) { j += 1 }
            out.emit(i, j, "attribute")
            i = j
            previousWord = nil
            precededByDot = false
            continue
        }

        // Prefixed strings: f"...", r'...', rf"""...""", b"..."
        if isPythonStringPrefix(u) {
            var q = i + 1
            var isRaw = (u == U16.lowerR || u == U16.upperR)
            if q < n && isPythonStringPrefix(units[q]) {
                if units[q] == U16.lowerR || units[q] == U16.upperR { isRaw = true }
                q += 1
            }
            if q < n && (units[q] == U16.quote || units[q] == U16.apos) {
                let delim = units[q]
                let isTriple = q + 2 < n && units[q + 1] == delim && units[q + 2] == delim
                let end = isTriple
                    ? scanTripleQuotedEnd(units, from: q, delimiter: delim, allowEscapes: !isRaw)
                    : scanQuotedEnd(units, from: q, delimiter: delim, allowMultiline: false, allowEscapes: !isRaw)
                let delimLen = isTriple ? 3 : 1
                emitStringSpan(
                    units,
                    start: i,
                    end: end,
                    contentStart: q + delimLen,
                    contentEnd: max(q + delimLen, end - delimLen),
                    allowEscapes: !isRaw,
                    into: &out
                )
                i = end
                previousWord = nil
                precededByDot = false
                continue
            }
        }

        // Strings (single, double, triple)
        if u == U16.quote || u == U16.apos {
            let isTriple = i + 2 < n && units[i + 1] == u && units[i + 2] == u
            let end = isTriple
                ? scanTripleQuotedEnd(units, from: i, delimiter: u)
                : scanQuotedEnd(units, from: i, delimiter: u, allowMultiline: false)
            let delimLen = isTriple ? 3 : 1
            emitStringSpan(
                units,
                start: i,
                end: end,
                contentStart: i + delimLen,
                contentEnd: max(i + delimLen, end - delimLen),
                allowEscapes: true,
                into: &out
            )
            i = end
            previousWord = nil
            precededByDot = false
            continue
        }

        // Numbers
        if U16.isDigit(u) {
            let end = scanNumberLiteral(units, from: i)
            out.emit(i, end, "number")
            i = end
            previousWord = nil
            precededByDot = false
            continue
        }

        // Identifiers
        if U16.isIdentStart(u) {
            var j = i + 1
            while j < n && U16.isIdentContinue(units[j]) { j += 1 }
            let word = U16.slice(units, i, j)
            let nextIsCall = j < n && units[j] == U16.lparen

            let group: String?
            if word == "True" || word == "False" {
                group = "boolean"
            } else if word == "None" {
                group = "constant"
            } else if word == "Ellipsis" || word == "NotImplemented" {
                group = "constant.builtin"
            } else if pythonReturnKeywords.contains(word) && !precededByDot {
                group = "keyword.return"
            } else if pythonOperatorKeywords.contains(word) && !precededByDot {
                group = "keyword.operator"
            } else if pythonKeywords.contains(word) && !precededByDot {
                group = "keyword"
                if word == "def" { expectParamList = true }
            } else if previousWord == "def" {
                group = "function"
                expectParamList = true
            } else if previousWord == "class" {
                group = "type"
            } else if pythonBuiltinTypes.contains(word) && !precededByDot {
                group = "type.builtin"
            } else if inParamList && paramParenDepth == 1 && expectParamName && !nextIsCall && !precededByDot {
                group = "variable.parameter"
                expectParamName = false
            } else if nextIsCall {
                group = precededByDot ? "function.method" : "function"
            } else if precededByDot {
                group = "property"
            } else if U16.isAllCapsConstant(units, start: i, end: j) {
                group = "constant"
            } else if U16.isASCIIUpper(u) {
                group = "type"
            } else {
                group = nil
            }

            if let group { out.emit(i, j, group) }
            previousWord = word
            precededByDot = false
            i = j
            continue
        }

        if U16.isBracket(u) {
            out.emit(i, i + 1, "punctuation.bracket")
            if u == U16.lparen {
                if expectParamList {
                    inParamList = true
                    expectParamList = false
                    paramParenDepth = 1
                    expectParamName = true
                } else if inParamList {
                    paramParenDepth += 1
                }
            } else if u == U16.rparen && inParamList {
                paramParenDepth -= 1
                if paramParenDepth <= 0 {
                    inParamList = false
                    paramParenDepth = 0
                    expectParamName = false
                }
            }
            precededByDot = false
            previousWord = nil
            i += 1
            continue
        }

        if U16.isDelimiter(u) {
            out.emit(i, i + 1, "punctuation.delimiter")
            if u == U16.comma && inParamList && paramParenDepth == 1 {
                expectParamName = true
            }
            precededByDot = (u == U16.dot)
            previousWord = nil
            i += 1
            continue
        }

        if U16.isOperatorChar(u) {
            var j = i + 1
            while j < n && U16.isOperatorChar(units[j]) { j += 1 }
            out.emit(i, j, "operator")
            if inParamList && paramParenDepth == 1 && (u == U16.colon || u == U16.eq) {
                expectParamName = false
            }
            previousWord = nil
            precededByDot = false
            i = j
            continue
        }

        previousWord = nil
        precededByDot = false
        i = U16.step(units, i)
    }

    return out.highlights
}

// MARK: - Bash / Shell Lexer (with Multi-Line Heredocs)

private let bashKeywords: Set<String> = [
    "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until",
    "case", "esac", "select", "exit", "export", "local", "readonly", "declare",
    "typeset", "unset", "shift", "source", "break", "continue", "set", "trap", "eval", "exec",
]

private func tokenizeBashGrammar(_ units: [UInt16]) -> [SimpleHighlight] {
    let n = units.count
    var out = HighlightBuilder(unitCount: n)
    var i = 0
    var atCommandBoundary = true
    var pendingHeredoc: (delimiter: String, stripTabs: Bool)? = nil

    while i < n {
        let u = units[i]

        if U16.isNewline(u) {
            i = U16.nextLineStart(units, after: i)
            if let hd = pendingHeredoc {
                let end = scanHeredocBody(units, bodyStart: i, delimiter: hd.delimiter, allowLeadingWhitespace: hd.stripTabs)
                out.emit(i, end, "string")
                i = end
                pendingHeredoc = nil
            }
            atCommandBoundary = true
            continue
        }
        if U16.isInlineWS(u) {
            i += 1
            continue
        }

        // Comment # ...
        if u == U16.hash && (i == 0 || U16.isWS(units[i - 1]) || units[i - 1] == U16.semi) {
            let end = U16.lineEnd(units, from: i + 1)
            out.emit(i, end, "comment")
            i = end
            continue
        }

        // Heredoc operator: <<EOF, <<-EOF, <<'EOF', <<"EOF"
        if u == U16.lt && i + 1 < n && units[i + 1] == U16.lt && (i + 2 >= n || units[i + 2] != U16.lt) {
            var j = i + 2
            var stripTabs = false
            if j < n && units[j] == U16.minus {
                stripTabs = true
                j += 1
            }
            out.emit(i, j, "operator")
            while j < n && U16.isInlineWS(units[j]) { j += 1 }
            let delimStart = j
            var quoteChar: UInt16 = 0
            if j < n && (units[j] == U16.apos || units[j] == U16.quote) {
                quoteChar = units[j]
                j += 1
            }
            let wordStart = j
            while j < n && (U16.isIdentContinue(units[j]) || units[j] == U16.minus) { j += 1 }
            let wordEnd = j
            if quoteChar != 0 && j < n && units[j] == quoteChar { j += 1 }
            if wordEnd > wordStart {
                let delim = U16.slice(units, wordStart, wordEnd)
                out.emit(delimStart, j, "string")
                pendingHeredoc = (delim, stripTabs)
            }
            atCommandBoundary = false
            i = j
            continue
        }

        // ANSI-C string $'...'
        if u == U16.dollar && i + 1 < n && units[i + 1] == U16.apos {
            let end = scanQuotedEnd(units, from: i + 1, delimiter: U16.apos, allowMultiline: true, allowEscapes: true)
            emitStringSpan(units, start: i, end: end, contentStart: i + 2, contentEnd: max(i + 2, end - 1), allowEscapes: true, into: &out)
            atCommandBoundary = false
            i = end
            continue
        }

        // Strings: "...", '...', `...`
        if u == U16.quote || u == U16.apos || u == U16.backtick {
            let allowEsc = (u != U16.apos)
            let end = scanQuotedEnd(units, from: i, delimiter: u, allowMultiline: true, allowEscapes: allowEsc)
            emitStringSpan(units, start: i, end: end, contentStart: i + 1, contentEnd: max(i + 1, end - 1), allowEscapes: allowEsc, into: &out)
            atCommandBoundary = false
            i = end
            continue
        }

        // Variables: $VAR, ${VAR}, $1, $?, $@, $#, $$
        if u == U16.dollar {
            var j = i + 1
            if j < n && units[j] == U16.lbrace {
                j += 1
                while j < n && units[j] != U16.rbrace && !U16.isNewline(units[j]) { j = U16.step(units, j) }
                if j < n && units[j] == U16.rbrace { j += 1 }
            } else if j < n && U16.isIdentStart(units[j]) {
                j += 1
                while j < n && U16.isIdentContinue(units[j]) { j += 1 }
            } else if j < n && (U16.isDigit(units[j]) || units[j] == U16.question || units[j] == U16.at || units[j] == U16.star || units[j] == U16.hash || units[j] == U16.dollar) {
                j += 1
            }
            if j > i + 1 {
                out.emit(i, j, "constant")
                atCommandBoundary = false
                i = j
                continue
            }
        }

        // CLI flags --flag / -f
        if u == U16.minus && !atCommandBoundary && i + 1 < n && (U16.isASCIILetter(units[i + 1]) || units[i + 1] == U16.minus) {
            var j = i + 1
            while j < n && (U16.isIdentContinue(units[j]) || units[j] == U16.minus) { j += 1 }
            out.emit(i, j, "variable.parameter")
            i = j
            continue
        }

        // Numbers
        if U16.isDigit(u) && (i == 0 || U16.isWS(units[i - 1]) || units[i - 1] == U16.eq) {
            let end = scanNumberLiteral(units, from: i, allowSuffix: false)
            out.emit(i, end, "number")
            atCommandBoundary = false
            i = end
            continue
        }

        // Words / keywords / assignment targets / commands
        if U16.isIdentStart(u) {
            var j = i + 1
            while j < n && (U16.isIdentContinue(units[j]) || units[j] == U16.minus) { j += 1 }
            let word = U16.slice(units, i, j)
            if word == "true" || word == "false" {
                out.emit(i, j, "boolean")
            } else if word == "function" {
                out.emit(i, j, "keyword.function")
            } else if word == "return" {
                out.emit(i, j, "keyword.return")
            } else if bashKeywords.contains(word) {
                out.emit(i, j, "keyword")
            } else if j < n && units[j] == U16.eq {
                out.emit(i, j, "property")
            } else if atCommandBoundary {
                out.emit(i, j, "function")
            }
            atCommandBoundary = (word == "then" || word == "do" || word == "else" || word == "elif")
            i = j
            continue
        }

        if u == U16.semi {
            out.emit(i, i + 1, "punctuation.delimiter")
            atCommandBoundary = true
            i += 1
            continue
        }

        if u == U16.pipe || u == U16.amp || u == U16.gt || u == U16.lt || u == U16.eq || u == U16.bang {
            var j = i + 1
            while j < n && (units[j] == U16.pipe || units[j] == U16.amp || units[j] == U16.gt || units[j] == U16.lt || units[j] == U16.eq) { j += 1 }
            out.emit(i, j, "operator")
            atCommandBoundary = (u == U16.pipe || u == U16.amp)
            i = j
            continue
        }

        if U16.isBracket(u) {
            out.emit(i, i + 1, "punctuation.bracket")
            atCommandBoundary = (u == U16.lparen || u == U16.lbrace)
            i += 1
            continue
        }

        if U16.isDelimiter(u) {
            out.emit(i, i + 1, "punctuation.delimiter")
            atCommandBoundary = false
            i += 1
            continue
        }

        atCommandBoundary = false
        i = U16.step(units, i)
    }

    return out.highlights
}

// MARK: - Ruby Lexer

private let rubyKeywords: Set<String> = [
    "alias", "begin", "break", "case", "class", "do", "else", "elsif", "end", "ensure",
    "for", "if", "in", "module", "next", "private", "protected", "public", "raise", "redo",
    "require", "require_relative", "rescue", "retry", "self", "super", "then", "undef",
    "unless", "until", "when", "while", "include", "extend", "prepend", "attr_reader",
    "attr_writer", "attr_accessor", "lambda", "proc",
]

private func tokenizeRubyGrammar(_ units: [UInt16]) -> [SimpleHighlight] {
    let n = units.count
    var out = HighlightBuilder(unitCount: n)
    var i = 0
    var atLineStart = true
    var prevWord: String? = nil
    var precededByDot = false
    var expectParamList = false
    var inParamList = false
    var paramDepth = 0
    var expectParamName = false
    var pendingHeredoc: (delimiter: String, indented: Bool)? = nil

    while i < n {
        let u = units[i]

        if U16.isNewline(u) {
            i = U16.nextLineStart(units, after: i)
            if let hd = pendingHeredoc {
                let end = scanHeredocBody(units, bodyStart: i, delimiter: hd.delimiter, allowLeadingWhitespace: hd.indented)
                out.emit(i, end, "string")
                i = end
                pendingHeredoc = nil
            }
            atLineStart = true
            continue
        }
        if U16.isInlineWS(u) {
            i += 1
            continue
        }

        // Multi-line =begin ... =end block comment
        if atLineStart && U16.matchesASCII(units, at: i, "=begin") && (i + 6 == n || U16.isWS(units[i + 6])) {
            let start = i
            var lineStart = U16.nextLineStart(units, after: U16.lineEnd(units, from: i + 6))
            var end = n
            while lineStart < n {
                let lineEnd = U16.lineEnd(units, from: lineStart)
                if U16.matchesASCII(units, at: lineStart, limit: lineEnd, "=end")
                    && (lineStart + 4 == lineEnd || U16.isInlineWS(units[lineStart + 4]))
                {
                    end = lineEnd
                    break
                }
                lineStart = U16.nextLineStart(units, after: lineEnd)
            }
            out.emit(start, end, "comment")
            i = end
            atLineStart = false
            continue
        }

        // Single-line comment # ...
        if u == U16.hash {
            let end = U16.lineEnd(units, from: i + 1)
            out.emit(i, end, "comment")
            i = end
            continue
        }

        // Heredocs <<EOF, <<-EOF, <<~EOF
        if u == U16.lt && i + 1 < n && units[i + 1] == U16.lt {
            var j = i + 2
            var indented = false
            if j < n && (units[j] == U16.minus || units[j] == U16.tilde) {
                indented = true
                j += 1
            }
            var q: UInt16 = 0
            if j < n && (units[j] == U16.apos || units[j] == U16.quote) {
                q = units[j]
                j += 1
            }
            let dStart = j
            while j < n && U16.isIdentContinue(units[j]) { j += 1 }
            let dEnd = j
            if dEnd > dStart && (q == 0 || (j < n && units[j] == q)) {
                let closeIdx = q == 0 ? j : j + 1
                out.emit(i, closeIdx, "string")
                pendingHeredoc = (U16.slice(units, dStart, dEnd), indented)
                i = closeIdx
                atLineStart = false
                prevWord = nil
                precededByDot = false
                continue
            }
        }

        // Strings "..." / '...'
        if u == U16.quote || u == U16.apos {
            let allowEsc = (u == U16.quote)
            let end = scanQuotedEnd(units, from: i, delimiter: u, allowMultiline: true, allowEscapes: allowEsc)
            emitStringSpan(units, start: i, end: end, contentStart: i + 1, contentEnd: max(i + 1, end - 1), allowEscapes: allowEsc, into: &out)
            i = end
            atLineStart = false
            prevWord = nil
            precededByDot = false
            continue
        }

        // Instance/class variables @var, @@cvar
        if u == U16.at {
            var j = i + 1
            if j < n && units[j] == U16.at { j += 1 }
            if j < n && U16.isIdentStart(units[j]) {
                j += 1
                while j < n && U16.isIdentContinue(units[j]) { j += 1 }
                out.emit(i, j, "property")
                i = j
                atLineStart = false
                prevWord = nil
                precededByDot = false
                continue
            }
        }

        // Symbols :foo (not ::)
        if u == U16.colon && i + 1 < n && units[i + 1] != U16.colon && U16.isIdentStart(units[i + 1]) {
            var j = i + 2
            while j < n && (U16.isIdentContinue(units[j]) || units[j] == U16.question || units[j] == U16.bang) { j += 1 }
            out.emit(i, j, "constant.builtin")
            i = j
            atLineStart = false
            prevWord = nil
            precededByDot = false
            continue
        }

        // Numbers
        if U16.isDigit(u) {
            let end = scanNumberLiteral(units, from: i, allowSuffix: false)
            out.emit(i, end, "number")
            i = end
            atLineStart = false
            prevWord = nil
            precededByDot = false
            continue
        }

        // Identifiers / keywords / methods / hash keys
        if U16.isIdentStart(u) {
            var j = i + 1
            while j < n && U16.isIdentContinue(units[j]) { j += 1 }
            if j < n && (units[j] == U16.question || units[j] == U16.bang) { j += 1 }
            let word = U16.slice(units, i, j)
            let isHashKey = j < n && units[j] == U16.colon && (j + 1 >= n || units[j + 1] != U16.colon)
            let nextIsCall = j < n && units[j] == U16.lparen

            let group: String?
            if isHashKey {
                group = "property"
            } else if word == "true" || word == "false" {
                group = "boolean"
            } else if word == "nil" || word == "__FILE__" || word == "__LINE__" || word == "__ENCODING__" {
                group = "constant.builtin"
            } else if word == "def" && !precededByDot {
                group = "keyword.function"
                expectParamList = true
            } else if (word == "return" || word == "yield") && !precededByDot {
                group = "keyword.return"
            } else if (word == "and" || word == "or" || word == "not" || word == "defined?") && !precededByDot {
                group = "keyword.operator"
            } else if rubyKeywords.contains(word) && !precededByDot {
                group = "keyword"
            } else if prevWord == "def" {
                group = "function"
                expectParamList = true
            } else if prevWord == "class" || prevWord == "module" {
                group = "type"
            } else if inParamList && paramDepth == 1 && expectParamName && !nextIsCall {
                group = "variable.parameter"
                expectParamName = false
            } else if nextIsCall {
                group = precededByDot ? "function.method" : "function"
            } else if precededByDot {
                group = "function.method"
            } else if U16.isAllCapsConstant(units, start: i, end: j) {
                group = "constant"
            } else if U16.isASCIIUpper(u) {
                group = "type"
            } else {
                group = nil
            }

            if let group { out.emit(i, j, group) }
            prevWord = word
            precededByDot = false
            atLineStart = false
            i = j
            continue
        }

        if U16.isBracket(u) {
            out.emit(i, i + 1, "punctuation.bracket")
            if u == U16.lparen {
                if expectParamList {
                    inParamList = true
                    expectParamList = false
                    paramDepth = 1
                    expectParamName = true
                } else if inParamList {
                    paramDepth += 1
                }
            } else if u == U16.rparen && inParamList {
                paramDepth -= 1
                if paramDepth <= 0 { inParamList = false; expectParamName = false }
            }
            atLineStart = false
            prevWord = nil
            precededByDot = false
            i += 1
            continue
        }

        if U16.isDelimiter(u) {
            out.emit(i, i + 1, "punctuation.delimiter")
            if u == U16.comma && inParamList && paramDepth == 1 { expectParamName = true }
            precededByDot = (u == U16.dot)
            atLineStart = false
            prevWord = nil
            i += 1
            continue
        }

        if U16.isOperatorChar(u) {
            var j = i + 1
            while j < n && U16.isOperatorChar(units[j]) { j += 1 }
            out.emit(i, j, "operator")
            atLineStart = false
            prevWord = nil
            precededByDot = false
            i = j
            continue
        }

        atLineStart = false
        prevWord = nil
        precededByDot = false
        i = U16.step(units, i)
    }

    return out.highlights
}

// MARK: - PHP Lexer

private let phpKeywords: Set<String> = [
    "abstract", "array", "as", "break", "callable", "case", "catch", "class", "const",
    "continue", "declare", "default", "do", "echo", "else", "elseif", "empty", "endfor",
    "endforeach", "endif", "endswitch", "endwhile", "enum", "eval", "exit", "extends", "final",
    "finally", "for", "foreach", "global", "goto", "if", "implements", "include",
    "include_once", "interface", "isset", "list", "match", "namespace", "print", "private",
    "protected", "public", "readonly", "require", "require_once", "static", "switch", "throw",
    "trait", "try", "unset", "use", "var", "while",
]

private let phpBuiltinTypes: Set<String> = [
    "int", "float", "string", "bool", "array", "object", "callable", "iterable", "void",
    "never", "mixed", "self", "parent",
]

private func tokenizePHPGrammar(_ units: [UInt16]) -> [SimpleHighlight] {
    let n = units.count
    var out = HighlightBuilder(unitCount: n)
    var i = 0
    var prevWord: String? = nil
    var precededByMember = false
    var expectParamList = false
    var inParamList = false
    var paramDepth = 0

    while i < n {
        let u = units[i]

        if U16.isWS(u) { i += 1; continue }

        // PHP tags <?php, <?=, ?>
        if U16.matchesASCII(units, at: i, "<?php") {
            out.emit(i, i + 5, "tag")
            i += 5
            continue
        }
        if U16.matchesASCII(units, at: i, "<?=") {
            out.emit(i, i + 3, "tag")
            i += 3
            continue
        }
        if u == U16.question && i + 1 < n && units[i + 1] == U16.gt {
            out.emit(i, i + 2, "tag")
            i += 2
            continue
        }

        // PHP 8 attributes #[Route(...)]
        if u == U16.hash && i + 1 < n && units[i + 1] == U16.lbracket {
            out.emit(i, i + 2, "punctuation.bracket")
            i += 2
            if i < n && U16.isIdentStart(units[i]) {
                var j = i + 1
                while j < n && (U16.isIdentContinue(units[j]) || units[j] == U16.backslash) { j += 1 }
                out.emit(i, j, "attribute")
                i = j
            }
            continue
        }

        // Comments //, #, /* ... */
        if (u == U16.slash && i + 1 < n && units[i + 1] == U16.slash) || u == U16.hash {
            let end = U16.lineEnd(units, from: i + 1)
            out.emit(i, end, "comment")
            i = end
            continue
        }
        if u == U16.slash && i + 1 < n && units[i + 1] == U16.star {
            let end = scanDelimitedComment(units, from: i, open: [U16.slash, U16.star], close: [U16.star, U16.slash], nested: false)
            out.emit(i, end, "comment")
            i = end
            continue
        }

        // Heredoc / Nowdoc <<<EOT ... EOT;
        if U16.matchesASCII(units, at: i, "<<<") {
            var j = i + 3
            while j < n && U16.isInlineWS(units[j]) { j += 1 }
            var q: UInt16 = 0
            if j < n && (units[j] == U16.apos || units[j] == U16.quote) { q = units[j]; j += 1 }
            let dStart = j
            while j < n && U16.isIdentContinue(units[j]) { j += 1 }
            let dEnd = j
            if q != 0 && j < n && units[j] == q { j += 1 }
            if dEnd > dStart {
                let delim = U16.slice(units, dStart, dEnd)
                let bodyStart = U16.nextLineStart(units, after: U16.lineEnd(units, from: j))
                let bodyEnd = scanHeredocBody(units, bodyStart: bodyStart, delimiter: delim, allowLeadingWhitespace: true, allowTrailingSemicolon: true)
                out.emit(i, bodyEnd, "string")
                i = bodyEnd
                prevWord = nil
                precededByMember = false
                continue
            }
        }

        // Strings
        if u == U16.quote || u == U16.apos {
            let allowEsc = (u == U16.quote)
            let end = scanQuotedEnd(units, from: i, delimiter: u, allowMultiline: true, allowEscapes: allowEsc)
            emitStringSpan(units, start: i, end: end, contentStart: i + 1, contentEnd: max(i + 1, end - 1), allowEscapes: allowEsc, into: &out)
            i = end
            prevWord = nil
            precededByMember = false
            continue
        }

        // PHP variables $name
        if u == U16.dollar && i + 1 < n && U16.isIdentStart(units[i + 1]) {
            var j = i + 2
            while j < n && U16.isIdentContinue(units[j]) { j += 1 }
            if inParamList && paramDepth == 1 {
                out.emit(i, j, "variable.parameter")
            } else {
                let name = U16.slice(units, i, j)
                if name == "$this" { out.emit(i, j, "constant.builtin") }
            }
            i = j
            prevWord = nil
            precededByMember = false
            continue
        }

        // Member access -> or ::
        if (u == U16.minus && i + 1 < n && units[i + 1] == U16.gt)
            || (u == U16.colon && i + 1 < n && units[i + 1] == U16.colon)
        {
            out.emit(i, i + 2, "operator")
            precededByMember = true
            prevWord = nil
            i += 2
            continue
        }

        // Numbers
        if U16.isDigit(u) {
            let end = scanNumberLiteral(units, from: i, allowSuffix: false)
            out.emit(i, end, "number")
            i = end
            prevWord = nil
            precededByMember = false
            continue
        }

        // Identifiers / keywords / types / functions
        if U16.isIdentStart(u) {
            var j = i + 1
            while j < n && U16.isIdentContinue(units[j]) { j += 1 }
            let word = U16.slice(units, i, j)
            let lower = word.lowercased()
            let nextIsCall = j < n && units[j] == U16.lparen

            let group: String?
            if lower == "true" || lower == "false" {
                group = "boolean"
            } else if lower == "null" || word == "__FILE__" || word == "__DIR__" || word == "__LINE__" || word == "__CLASS__" {
                group = "constant.builtin"
            } else if (lower == "function" || lower == "fn") && !precededByMember {
                group = "keyword.function"
                expectParamList = true
            } else if (lower == "return" || lower == "yield") && !precededByMember {
                group = "keyword.return"
            } else if (lower == "and" || lower == "or" || lower == "xor" || lower == "new" || lower == "instanceof" || lower == "clone") && !precededByMember {
                group = "keyword.operator"
            } else if phpKeywords.contains(lower) && !precededByMember {
                group = "keyword"
            } else if prevWord == "function" {
                group = "function"
                expectParamList = true
            } else if prevWord == "class" || prevWord == "interface" || prevWord == "trait" || prevWord == "enum" {
                group = "type"
            } else if phpBuiltinTypes.contains(lower) && !precededByMember {
                group = "type.builtin"
            } else if nextIsCall {
                group = precededByMember ? "function.method" : "function"
            } else if precededByMember {
                group = "property"
            } else if U16.isAllCapsConstant(units, start: i, end: j) {
                group = "constant"
            } else if U16.isASCIIUpper(u) {
                group = "type"
            } else {
                group = nil
            }

            if let group { out.emit(i, j, group) }
            prevWord = lower
            precededByMember = false
            i = j
            continue
        }

        if U16.isBracket(u) {
            out.emit(i, i + 1, "punctuation.bracket")
            if u == U16.lparen {
                if expectParamList { inParamList = true; expectParamList = false; paramDepth = 1 }
                else if inParamList { paramDepth += 1 }
            } else if u == U16.rparen && inParamList {
                paramDepth -= 1
                if paramDepth <= 0 { inParamList = false }
            }
            prevWord = nil
            precededByMember = false
            i += 1
            continue
        }

        if U16.isDelimiter(u) {
            out.emit(i, i + 1, "punctuation.delimiter")
            prevWord = nil
            precededByMember = false
            i += 1
            continue
        }

        if U16.isOperatorChar(u) {
            var j = i + 1
            while j < n && U16.isOperatorChar(units[j]) {
                if units[j] == U16.slash && j + 1 < n && (units[j + 1] == U16.slash || units[j + 1] == U16.star) { break }
                j += 1
            }
            out.emit(i, j, "operator")
            prevWord = nil
            precededByMember = false
            i = j
            continue
        }

        prevWord = nil
        precededByMember = false
        i = U16.step(units, i)
    }

    return out.highlights
}

// MARK: - Stateful HTML / Vue / XML Markup Lexer

private enum MarkupMode {
    case html
    case vue
    case xml
}

private func findClosingTag(_ units: [UInt16], from start: Int, tagLower: String) -> Int? {
    let n = units.count
    let target = Array(("</" + tagLower).utf16)
    var i = start
    while i + target.count < n {
        if units[i] == U16.lt && units[i + 1] == U16.slash {
            var matched = true
            for k in 2..<target.count {
                let c = units[i + k]
                let lowerC = (c >= U16.upperA && c <= U16.upperZ) ? (c + 32) : c
                if lowerC != target[k] {
                    matched = false
                    break
                }
            }
            if matched {
                let after = i + target.count
                if after < n && (units[after] == U16.gt || U16.isWS(units[after])) {
                    return i
                }
            }
        }
        i = U16.step(units, i)
    }
    return nil
}

private func tokenizeMarkupGrammar(_ units: [UInt16], mode: MarkupMode) -> [SimpleHighlight] {
    let n = units.count
    var out = HighlightBuilder(unitCount: n)
    var i = 0

    while i < n {
        let u = units[i]

        // Vue mustache interpolation {{ expr }}
        if mode == .vue && u == U16.lbrace && i + 1 < n && units[i + 1] == U16.lbrace {
            out.emit(i, i + 2, "punctuation.bracket")
            let exprStart = i + 2
            var e = exprStart
            while e + 1 < n && !(units[e] == U16.rbrace && units[e + 1] == U16.rbrace) {
                e = U16.step(units, e)
            }
            if e > exprStart {
                let sub = tokenizeCodeGrammar(Array(units[exprStart..<e]), spec: .typeScript)
                out.emitEmbedded(sub, offset: exprStart, maxEnd: e)
            }
            if e + 1 < n && units[e] == U16.rbrace && units[e + 1] == U16.rbrace {
                out.emit(e, e + 2, "punctuation.bracket")
                i = e + 2
            } else {
                i = e
            }
            continue
        }

        // XML / HTML comments <!-- ... --> (multi-line)
        if U16.matchesASCII(units, at: i, "<!--") {
            let end = scanDelimitedComment(
                units,
                from: i,
                open: [U16.lt, U16.bang, U16.minus, U16.minus],
                close: [U16.minus, U16.minus, U16.gt],
                nested: false
            )
            out.emit(i, end, "comment")
            i = end
            continue
        }

        // XML CDATA <![CDATA[ ... ]]> (multi-line)
        if mode == .xml && U16.matchesASCII(units, at: i, "<![CDATA[") {
            let openEnd = i + 9
            out.emit(i, openEnd, "punctuation.bracket")
            var j = openEnd
            while j < n && !U16.matchesASCII(units, at: j, "]]>") {
                j = U16.step(units, j)
            }
            if j > openEnd { out.emit(openEnd, j, "markup.raw") }
            if j + 3 <= n && U16.matchesASCII(units, at: j, "]]>") {
                out.emit(j, j + 3, "punctuation.bracket")
                i = j + 3
            } else {
                i = j
            }
            continue
        }

        // XML processing instruction <?xml version="1.0"?>
        if mode == .xml && u == U16.lt && i + 1 < n && units[i + 1] == U16.question {
            out.emit(i, i + 2, "punctuation.bracket")
            var cur = i + 2
            if cur < n && U16.isIdentStart(units[cur]) {
                let s = cur
                while cur < n && (U16.isIdentContinue(units[cur]) || units[cur] == U16.minus) { cur += 1 }
                out.emit(s, cur, "keyword")
            }
            while cur < n {
                if units[cur] == U16.question && cur + 1 < n && units[cur + 1] == U16.gt {
                    out.emit(cur, cur + 2, "punctuation.bracket")
                    cur += 2
                    break
                }
                if U16.isWS(units[cur]) { cur += 1; continue }
                if U16.isIdentStart(units[cur]) {
                    let s = cur
                    while cur < n && (U16.isIdentContinue(units[cur]) || units[cur] == U16.minus || units[cur] == U16.colon) { cur += 1 }
                    out.emit(s, cur, "attribute")
                    continue
                }
                if units[cur] == U16.eq { out.emit(cur, cur + 1, "operator"); cur += 1; continue }
                if units[cur] == U16.quote || units[cur] == U16.apos {
                    let sEnd = scanQuotedEnd(units, from: cur, delimiter: units[cur], allowMultiline: true, allowEscapes: false)
                    emitStringSpan(units, start: cur, end: sEnd, contentStart: cur + 1, contentEnd: max(cur + 1, sEnd - 1), allowEscapes: false, into: &out)
                    cur = sEnd
                    continue
                }
                cur = U16.step(units, cur)
            }
            i = cur
            continue
        }

        // DOCTYPE / declarations <!DOCTYPE html>
        if u == U16.lt && i + 1 < n && units[i + 1] == U16.bang {
            out.emit(i, i + 2, "punctuation.bracket")
            var cur = i + 2
            let kwStart = cur
            while cur < n && U16.isASCIILetter(units[cur]) { cur += 1 }
            if cur > kwStart { out.emit(kwStart, cur, "keyword") }
            while cur < n && units[cur] != U16.gt {
                if units[cur] == U16.quote || units[cur] == U16.apos {
                    let sEnd = scanQuotedEnd(units, from: cur, delimiter: units[cur], allowMultiline: true, allowEscapes: false)
                    emitStringSpan(units, start: cur, end: sEnd, contentStart: cur + 1, contentEnd: max(cur + 1, sEnd - 1), allowEscapes: false, into: &out)
                    cur = sEnd
                } else {
                    cur = U16.step(units, cur)
                }
            }
            if cur < n && units[cur] == U16.gt {
                out.emit(cur, cur + 1, "punctuation.bracket")
                cur += 1
            }
            i = cur
            continue
        }

        // Opening / closing tags: <tag ...> or </tag>
        if u == U16.lt && i + 1 < n {
            var cur = i + 1
            var isClosing = false
            if units[cur] == U16.slash {
                isClosing = true
                cur += 1
            }
            if cur < n && U16.isASCIILetter(units[cur]) {
                out.emit(i, cur, "punctuation.bracket")
                let tagStart = cur
                while cur < n && (U16.isIdentContinue(units[cur]) || units[cur] == U16.minus || units[cur] == U16.colon || units[cur] == U16.dot) {
                    cur += 1
                }
                let tagName = U16.slice(units, tagStart, cur).lowercased()
                out.emit(tagStart, cur, "tag")

                var selfClosing = false
                while cur < n {
                    let c = units[cur]
                    if U16.isWS(c) { cur += 1; continue }
                    if c == U16.gt {
                        out.emit(cur, cur + 1, "punctuation.bracket")
                        cur += 1
                        break
                    }
                    if c == U16.slash && cur + 1 < n && units[cur + 1] == U16.gt {
                        out.emit(cur, cur + 2, "punctuation.bracket")
                        selfClosing = true
                        cur += 2
                        break
                    }
                    if c == U16.eq {
                        out.emit(cur, cur + 1, "operator")
                        cur += 1
                        continue
                    }
                    if c == U16.quote || c == U16.apos {
                        let sEnd = scanQuotedEnd(units, from: cur, delimiter: c, allowMultiline: true, allowEscapes: false)
                        emitStringSpan(units, start: cur, end: sEnd, contentStart: cur + 1, contentEnd: max(cur + 1, sEnd - 1), allowEscapes: false, into: &out)
                        cur = sEnd
                        continue
                    }
                    // Attribute names (including Vue directives: @click.prevent, :class, v-if, #header)
                    if U16.isASCIILetter(c) || c == U16.at || c == U16.colon || c == U16.hash || c == U16.underscore {
                        let aStart = cur
                        cur += 1
                        while cur < n && (U16.isIdentContinue(units[cur]) || units[cur] == U16.minus || units[cur] == U16.colon || units[cur] == U16.dot) {
                            cur += 1
                        }
                        out.emit(aStart, cur, "attribute")
                        continue
                    }
                    cur = U16.step(units, cur)
                }

                // Stateful multi-line injection for <script> and <style> blocks in HTML & Vue
                if !isClosing && !selfClosing && (mode == .html || mode == .vue) && (tagName == "script" || tagName == "style") {
                    let bodyEnd = findClosingTag(units, from: cur, tagLower: tagName) ?? n
                    if bodyEnd > cur {
                        let subUnits = Array(units[cur..<bodyEnd])
                        let subHighlights = (tagName == "script")
                            ? tokenizeCodeGrammar(subUnits, spec: .typeScript)
                            : tokenizeCSSGrammar(subUnits)
                        out.emitEmbedded(subHighlights, offset: cur, maxEnd: bodyEnd)
                    }
                    i = bodyEnd
                    continue
                }

                i = cur
                continue
            }
        }

        // Character entity references &amp; &#x1F680;
        if u == U16.amp {
            var j = i + 1
            if j < n && units[j] == U16.hash { j += 1 }
            while j < n && U16.isIdentContinue(units[j]) && j - i < 16 { j += 1 }
            if j > i + 1 && j < n && units[j] == U16.semi {
                out.emit(i, j + 1, "string.escape")
                i = j + 1
                continue
            }
        }

        i = U16.step(units, i)
    }

    return out.highlights
}

// MARK: - CSS Lexer

private func tokenizeCSSGrammar(_ units: [UInt16]) -> [SimpleHighlight] {
    let n = units.count
    var out = HighlightBuilder(unitCount: n)
    var i = 0
    var braceDepth = 0
    var expectValue = false

    while i < n {
        let u = units[i]

        if U16.isWS(u) { i += 1; continue }

        // Block comment /* ... */ (multi-line)
        if u == U16.slash && i + 1 < n && units[i + 1] == U16.star {
            let end = scanDelimitedComment(units, from: i, open: [U16.slash, U16.star], close: [U16.star, U16.slash], nested: false)
            out.emit(i, end, "comment")
            i = end
            continue
        }
        // SCSS/Less line comment //
        if u == U16.slash && i + 1 < n && units[i + 1] == U16.slash {
            let end = U16.lineEnd(units, from: i + 2)
            out.emit(i, end, "comment")
            i = end
            continue
        }

        // At-rules @media, @import, @keyframes, @layer
        if u == U16.at && i + 1 < n && U16.isASCIILetter(units[i + 1]) {
            var j = i + 2
            while j < n && (U16.isIdentContinue(units[j]) || units[j] == U16.minus) { j += 1 }
            out.emit(i, j, "keyword")
            i = j
            continue
        }

        // !important
        if u == U16.bang && i + 1 < n && U16.isASCIILetter(units[i + 1]) {
            var j = i + 2
            while j < n && U16.isASCIILetter(units[j]) { j += 1 }
            out.emit(i, j, "keyword")
            i = j
            continue
        }

        // Strings
        if u == U16.quote || u == U16.apos {
            let end = scanQuotedEnd(units, from: i, delimiter: u, allowMultiline: false)
            emitStringSpan(units, start: i, end: end, contentStart: i + 1, contentEnd: max(i + 1, end - 1), allowEscapes: true, into: &out)
            i = end
            continue
        }

        // Hex color #fff / #ff7b72 inside value, or ID selector #header outside block
        if u == U16.hash {
            var j = i + 1
            while j < n && (U16.isIdentContinue(units[j]) || units[j] == U16.minus) { j += 1 }
            if j > i + 1 {
                out.emit(i, j, expectValue ? "number" : "attribute")
                i = j
                continue
            }
        }

        // Numbers with optional units (16px, 1.5rem, 100%, 45deg, -2em)
        if U16.isDigit(u) || (u == U16.minus && expectValue && i + 1 < n && U16.isDigit(units[i + 1])) {
            let start = i
            if u == U16.minus { i += 1 }
            var end = scanNumberLiteral(units, from: i, allowSuffix: false)
            if end < n && units[end] == U16.percent {
                end += 1
            } else {
                while end < n && U16.isASCIILetter(units[end]) { end += 1 }
            }
            out.emit(start, end, "number")
            i = end
            continue
        }

        // Class selector .btn-primary
        if u == U16.dot && !expectValue && i + 1 < n && (U16.isASCIILetter(units[i + 1]) || units[i + 1] == U16.underscore || units[i + 1] == U16.minus) {
            var j = i + 2
            while j < n && (U16.isIdentContinue(units[j]) || units[j] == U16.minus) { j += 1 }
            out.emit(i, j, "type")
            i = j
            continue
        }

        // Pseudo-class / pseudo-element :hover ::before in selector context
        if u == U16.colon && !expectValue && braceDepth == 0 {
            var j = i + 1
            if j < n && units[j] == U16.colon { j += 1 }
            if j < n && U16.isASCIILetter(units[j]) {
                while j < n && (U16.isIdentContinue(units[j]) || units[j] == U16.minus) { j += 1 }
                out.emit(i, j, "attribute")
                i = j
                continue
            }
        }

        // CSS custom property --var-name or identifier
        if U16.isASCIILetter(u) || u == U16.underscore || (u == U16.minus && i + 1 < n && (units[i + 1] == U16.minus || U16.isASCIILetter(units[i + 1]))) {
            var j = i + 1
            while j < n && (U16.isIdentContinue(units[j]) || units[j] == U16.minus) { j += 1 }
            let word = U16.slice(units, i, j)

            // Lookahead for ':' (property declaration) or '(' (function like rgb(), calc(), url())
            var look = j
            while look < n && U16.isInlineWS(units[look]) { look += 1 }

            if look < n && units[look] == U16.lparen {
                out.emit(i, j, "function")
                // Special case: unquoted url(https://...)
                if word == "url" {
                    out.emit(look, look + 1, "punctuation.bracket")
                    var uStart = look + 1
                    while uStart < n && U16.isInlineWS(units[uStart]) { uStart += 1 }
                    if uStart < n && units[uStart] != U16.quote && units[uStart] != U16.apos {
                        var uEnd = uStart
                        while uEnd < n && units[uEnd] != U16.rparen && !U16.isWS(units[uEnd]) { uEnd = U16.step(units, uEnd) }
                        if uEnd > uStart { out.emit(uStart, uEnd, "string.special.url") }
                        i = uEnd
                        continue
                    }
                    i = look + 1
                    continue
                }
                i = j
                continue
            }

            if braceDepth > 0 && !expectValue && look < n && units[look] == U16.colon && (look + 1 >= n || units[look + 1] != U16.colon) {
                out.emit(i, j, "property")
            } else if !expectValue && (braceDepth == 0 || (look < n && (units[look] == U16.lbrace || units[look] == U16.comma))) {
                out.emit(i, j, "tag")
            } else if expectValue {
                out.emit(i, j, "constant.builtin")
            }
            i = j
            continue
        }

        if u == U16.lbrace {
            out.emit(i, i + 1, "punctuation.bracket")
            braceDepth += 1
            expectValue = false
            i += 1
            continue
        }
        if u == U16.rbrace {
            out.emit(i, i + 1, "punctuation.bracket")
            braceDepth = max(0, braceDepth - 1)
            expectValue = false
            i += 1
            continue
        }
        if U16.isBracket(u) {
            out.emit(i, i + 1, "punctuation.bracket")
            i += 1
            continue
        }
        if u == U16.colon {
            out.emit(i, i + 1, "punctuation.delimiter")
            if braceDepth > 0 { expectValue = true }
            i += 1
            continue
        }
        if u == U16.semi {
            out.emit(i, i + 1, "punctuation.delimiter")
            expectValue = false
            i += 1
            continue
        }
        if U16.isDelimiter(u) {
            out.emit(i, i + 1, "punctuation.delimiter")
            i += 1
            continue
        }
        if U16.isOperatorChar(u) {
            out.emit(i, i + 1, "operator")
            i += 1
            continue
        }

        i = U16.step(units, i)
    }

    return out.highlights
}

// MARK: - JSON / JSONC Lexer

private func tokenizeJSONGrammar(_ units: [UInt16]) -> [SimpleHighlight] {
    let n = units.count
    var out = HighlightBuilder(unitCount: n)
    var i = 0

    while i < n {
        let u = units[i]
        if U16.isWS(u) { i += 1; continue }

        if u == U16.slash && i + 1 < n && units[i + 1] == U16.slash {
            let end = U16.lineEnd(units, from: i + 2)
            out.emit(i, end, "comment")
            i = end
            continue
        }
        if u == U16.slash && i + 1 < n && units[i + 1] == U16.star {
            let end = scanDelimitedComment(units, from: i, open: [U16.slash, U16.star], close: [U16.star, U16.slash], nested: false)
            out.emit(i, end, "comment")
            i = end
            continue
        }

        if u == U16.quote {
            let end = scanQuotedEnd(units, from: i, delimiter: U16.quote, allowMultiline: false)
            var lookahead = end
            while lookahead < n && U16.isWS(units[lookahead]) { lookahead += 1 }
            if lookahead < n && units[lookahead] == U16.colon {
                out.emit(i, end, "property")
            } else {
                emitStringSpan(units, start: i, end: end, contentStart: i + 1, contentEnd: max(i + 1, end - 1), allowEscapes: true, into: &out)
            }
            i = end
            continue
        }

        if U16.isDigit(u) || (u == U16.minus && i + 1 < n && U16.isDigit(units[i + 1])) {
            let start = i
            if u == U16.minus { i += 1 }
            let end = scanNumberLiteral(units, from: i, allowSuffix: false)
            out.emit(start, end, "number")
            i = end
            continue
        }

        if U16.isASCIILower(u) {
            var j = i + 1
            while j < n && U16.isASCIILower(units[j]) { j += 1 }
            let word = U16.slice(units, i, j)
            if word == "true" || word == "false" {
                out.emit(i, j, "boolean")
            } else if word == "null" {
                out.emit(i, j, "constant")
            }
            i = j
            continue
        }

        if u == U16.lbrace || u == U16.rbrace || u == U16.lbracket || u == U16.rbracket {
            out.emit(i, i + 1, "punctuation.bracket")
            i += 1
            continue
        }
        if u == U16.comma || u == U16.colon {
            out.emit(i, i + 1, "punctuation.delimiter")
            i += 1
            continue
        }

        i = U16.step(units, i)
    }

    return out.highlights
}

// MARK: - YAML Lexer (with Stateful Multi-Line Block Scalars)

private func tokenizeYAMLGrammar(_ units: [UInt16]) -> [SimpleHighlight] {
    let n = units.count
    var out = HighlightBuilder(unitCount: n)
    var i = 0
    var blockScalarIndent: Int? = nil

    while i < n {
        let lineStart = i
        let lineEnd = U16.lineEnd(units, from: lineStart)
        let nextLine = U16.nextLineStart(units, after: lineEnd)

        var lead = lineStart
        while lead < lineEnd && units[lead] == U16.space { lead += 1 }
        let indent = lead - lineStart

        // Active multi-line block scalar (`|` / `>`)
        if let minIndent = blockScalarIndent {
            if lead == lineEnd {
                i = nextLine
                continue
            }
            if indent > minIndent {
                out.emit(lead, lineEnd, "string")
                i = nextLine
                continue
            } else {
                blockScalarIndent = nil
            }
        }

        if lead == lineEnd {
            i = nextLine
            continue
        }

        // Document markers --- or ...
        if (U16.matchesASCII(units, at: lead, limit: lineEnd, "---") || U16.matchesASCII(units, at: lead, limit: lineEnd, "..."))
            && (lead + 3 == lineEnd || U16.isInlineWS(units[lead + 3]))
        {
            out.emit(lead, lead + 3, "punctuation.delimiter")
            i = nextLine
            continue
        }

        // Directives %YAML / %TAG
        if units[lead] == U16.percent {
            out.emit(lead, lineEnd, "keyword")
            i = nextLine
            continue
        }

        var cur = lead
        while cur < lineEnd {
            let u = units[cur]
            if U16.isInlineWS(u) { cur += 1; continue }

            // Comment # ...
            if u == U16.hash && (cur == lineStart || U16.isInlineWS(units[cur - 1])) {
                out.emit(cur, lineEnd, "comment")
                cur = lineEnd
                break
            }

            // List item marker `- `
            if u == U16.minus && (cur + 1 == lineEnd || U16.isInlineWS(units[cur + 1])) {
                out.emit(cur, cur + 1, "punctuation.delimiter")
                cur += 1
                continue
            }

            // Anchors &name / aliases *name
            if (u == U16.amp || u == U16.star) && cur + 1 < lineEnd && !U16.isWS(units[cur + 1]) {
                var j = cur + 1
                while j < lineEnd && !U16.isWS(units[j]) && units[j] != U16.comma && units[j] != U16.rbracket && units[j] != U16.rbrace { j += 1 }
                out.emit(cur, j, "attribute")
                cur = j
                continue
            }

            // Tags !!str / !custom
            if u == U16.bang {
                var j = cur + 1
                while j < lineEnd && !U16.isWS(units[j]) { j += 1 }
                out.emit(cur, j, "type")
                cur = j
                continue
            }

            // Block scalar header `|` or `>` (with optional chomping `-`/`+` and indent digit)
            if (u == U16.pipe || u == U16.gt) && cur > lead {
                var j = cur + 1
                while j < lineEnd && (units[j] == U16.minus || units[j] == U16.plus || U16.isDigit(units[j])) { j += 1 }
                var tail = j
                while tail < lineEnd && U16.isInlineWS(units[tail]) { tail += 1 }
                if tail == lineEnd || units[tail] == U16.hash {
                    out.emit(cur, j, "operator")
                    blockScalarIndent = indent
                    cur = j
                    continue
                }
            }

            // Quoted strings "..." / '...'
            if u == U16.quote || u == U16.apos {
                let end = scanQuotedEnd(units, from: cur, delimiter: u, allowMultiline: true, allowEscapes: u == U16.quote, doubledQuoteEscape: u == U16.apos)
                var after = end
                while after < lineEnd && U16.isInlineWS(units[after]) { after += 1 }
                if after < lineEnd && units[after] == U16.colon && (after + 1 == lineEnd || U16.isInlineWS(units[after + 1])) {
                    out.emit(cur, end, "property")
                } else {
                    emitStringSpan(units, start: cur, end: end, contentStart: cur + 1, contentEnd: max(cur + 1, end - 1), allowEscapes: u == U16.quote, into: &out)
                }
                if end > lineEnd {
                    i = U16.nextLineStart(units, after: U16.lineEnd(units, from: end))
                    cur = lineEnd
                    break
                }
                cur = end
                continue
            }

            // Bare URL https://...
            if let urlEnd = U16.scanURL(units, from: cur, limit: lineEnd) {
                out.emit(cur, urlEnd, "string.special.url")
                cur = urlEnd
                continue
            }

            // Brackets / delimiters in flow style
            if u == U16.lbracket || u == U16.rbracket || u == U16.lbrace || u == U16.rbrace {
                out.emit(cur, cur + 1, "punctuation.bracket")
                cur += 1
                continue
            }
            if u == U16.comma || u == U16.colon {
                out.emit(cur, cur + 1, "punctuation.delimiter")
                cur += 1
                continue
            }

            // Check for mapping key `key:`
            var colonIdx: Int? = nil
            var scan = cur
            while scan < lineEnd {
                if units[scan] == U16.colon && (scan + 1 == lineEnd || U16.isInlineWS(units[scan + 1])) {
                    colonIdx = scan
                    break
                }
                if units[scan] == U16.hash && scan > cur && U16.isInlineWS(units[scan - 1]) { break }
                if units[scan] == U16.lbracket || units[scan] == U16.lbrace || units[scan] == U16.comma { break }
                scan = U16.step(units, scan)
            }
            if let cIdx = colonIdx, cIdx > cur {
                var keyEnd = cIdx
                while keyEnd > cur && U16.isInlineWS(units[keyEnd - 1]) { keyEnd -= 1 }
                out.emit(cur, keyEnd, "property")
                out.emit(cIdx, cIdx + 1, "punctuation.delimiter")
                cur = cIdx + 1
                continue
            }

            // Scalar values: numbers, booleans, null, strings
            var vEnd = cur
            while vEnd < lineEnd && units[vEnd] != U16.comma && units[vEnd] != U16.rbracket && units[vEnd] != U16.rbrace {
                if units[vEnd] == U16.hash && vEnd > cur && U16.isInlineWS(units[vEnd - 1]) { break }
                vEnd = U16.step(units, vEnd)
            }
            var trimmedEnd = vEnd
            while trimmedEnd > cur && U16.isInlineWS(units[trimmedEnd - 1]) { trimmedEnd -= 1 }
            if trimmedEnd > cur {
                let rawVal = U16.slice(units, cur, trimmedEnd)
                let lower = rawVal.lowercased()
                if lower == "true" || lower == "false" {
                    out.emit(cur, trimmedEnd, "boolean")
                } else if lower == "null" || rawVal == "~" {
                    out.emit(cur, trimmedEnd, "constant.builtin")
                } else if isYAMLNumber(units, start: cur, end: trimmedEnd) {
                    out.emit(cur, trimmedEnd, "number")
                } else {
                    out.emit(cur, trimmedEnd, "string")
                }
            }
            cur = vEnd
        }

        if i == lineStart {
            i = nextLine
        }
    }

    return out.highlights
}

private func isYAMLNumber(_ units: [UInt16], start: Int, end: Int) -> Bool {
    guard start < end else { return false }
    var idx = start
    if units[idx] == U16.minus || units[idx] == U16.plus { idx += 1 }
    guard idx < end && U16.isDigit(units[idx]) else { return false }
    let numEnd = scanNumberLiteral(units, from: idx, allowSuffix: false)
    return numEnd == end
}

// MARK: - TOML Lexer

private func tokenizeTOMLGrammar(_ units: [UInt16]) -> [SimpleHighlight] {
    let n = units.count
    var out = HighlightBuilder(unitCount: n)
    var i = 0
    var atLineStart = true
    var afterEquals = false

    while i < n {
        let u = units[i]

        if U16.isNewline(u) {
            i = U16.nextLineStart(units, after: i)
            atLineStart = true
            afterEquals = false
            continue
        }
        if U16.isInlineWS(u) { i += 1; continue }

        // Comment # ...
        if u == U16.hash {
            let end = U16.lineEnd(units, from: i + 1)
            out.emit(i, end, "comment")
            i = end
            continue
        }

        // Table headers [table] and [[array_of_tables]]
        if atLineStart && u == U16.lbracket {
            let isDouble = i + 1 < n && units[i + 1] == U16.lbracket
            let openEnd = i + (isDouble ? 2 : 1)
            out.emit(i, openEnd, "punctuation.bracket")
            var cur = openEnd
            while cur < n && !U16.isNewline(units[cur]) {
                if isDouble && cur + 1 < n && units[cur] == U16.rbracket && units[cur + 1] == U16.rbracket {
                    out.emit(cur, cur + 2, "punctuation.bracket")
                    cur += 2
                    break
                } else if !isDouble && units[cur] == U16.rbracket {
                    out.emit(cur, cur + 1, "punctuation.bracket")
                    cur += 1
                    break
                } else if units[cur] == U16.dot {
                    out.emit(cur, cur + 1, "punctuation.delimiter")
                    cur += 1
                } else if U16.isInlineWS(units[cur]) {
                    cur += 1
                } else {
                    let s = cur
                    while cur < n && units[cur] != U16.rbracket && units[cur] != U16.dot && !U16.isWS(units[cur]) {
                        cur = U16.step(units, cur)
                    }
                    out.emit(s, cur, "type")
                }
            }
            i = cur
            atLineStart = false
            continue
        }

        // Triple-quoted strings """...""" / '''...'''
        if (u == U16.quote || u == U16.apos) && i + 2 < n && units[i + 1] == u && units[i + 2] == u {
            let allowEsc = (u == U16.quote)
            let end = scanTripleQuotedEnd(units, from: i, delimiter: u, allowEscapes: allowEsc)
            emitStringSpan(units, start: i, end: end, contentStart: i + 3, contentEnd: max(i + 3, end - 3), allowEscapes: allowEsc, detectURL: false, into: &out)
            i = end
            atLineStart = false
            continue
        }

        // Single-line strings "..." / '...'
        if u == U16.quote || u == U16.apos {
            let allowEsc = (u == U16.quote)
            let end = scanQuotedEnd(units, from: i, delimiter: u, allowMultiline: false, allowEscapes: allowEsc)
            var look = end
            while look < n && U16.isInlineWS(units[look]) { look += 1 }
            if !afterEquals && look < n && (units[look] == U16.eq || units[look] == U16.dot) {
                out.emit(i, end, "property")
            } else {
                emitStringSpan(units, start: i, end: end, contentStart: i + 1, contentEnd: max(i + 1, end - 1), allowEscapes: allowEsc, into: &out)
            }
            i = end
            atLineStart = false
            continue
        }

        // Numbers & ISO-8601 datetimes
        if afterEquals && (U16.isDigit(u) || ((u == U16.plus || u == U16.minus) && i + 1 < n && U16.isDigit(units[i + 1]))) {
            let start = i
            var j = i + 1
            while j < n && (U16.isDigit(units[j]) || U16.isASCIILetter(units[j]) || units[j] == U16.underscore || units[j] == U16.dot || units[j] == U16.minus || units[j] == U16.plus || units[j] == U16.colon) {
                j += 1
            }
            out.emit(start, j, "number")
            i = j
            atLineStart = false
            continue
        }

        // Keys & values (booleans, inf, nan)
        if U16.isIdentStart(u) || (!afterEquals && U16.isDigit(u)) {
            var j = i + 1
            while j < n && (U16.isIdentContinue(units[j]) || units[j] == U16.minus) { j += 1 }
            let word = U16.slice(units, i, j)
            if afterEquals {
                if word == "true" || word == "false" {
                    out.emit(i, j, "boolean")
                } else if word == "inf" || word == "nan" {
                    out.emit(i, j, "number")
                }
            } else {
                out.emit(i, j, "property")
            }
            i = j
            atLineStart = false
            continue
        }

        if u == U16.eq {
            out.emit(i, i + 1, "operator")
            afterEquals = true
            atLineStart = false
            i += 1
            continue
        }
        if U16.isBracket(u) {
            out.emit(i, i + 1, "punctuation.bracket")
            if u == U16.lbrace { afterEquals = false }
            atLineStart = false
            i += 1
            continue
        }
        if U16.isDelimiter(u) {
            out.emit(i, i + 1, "punctuation.delimiter")
            if u == U16.comma { afterEquals = false }
            atLineStart = false
            i += 1
            continue
        }

        atLineStart = false
        i = U16.step(units, i)
    }

    return out.highlights
}

// MARK: - HCL / Terraform Lexer (with Multi-Line Heredocs)

private let hclKeywords: Set<String> = [
    "resource", "data", "variable", "output", "locals", "module", "provider", "terraform",
    "backend", "required_providers", "dynamic", "lifecycle", "provisioner", "moved", "import",
    "check", "assert", "for", "in", "if", "else", "endif", "endfor",
]

private let hclBuiltinTypes: Set<String> = [
    "string", "number", "bool", "list", "set", "map", "object", "tuple", "any",
]

private func tokenizeHCLGrammar(_ units: [UInt16]) -> [SimpleHighlight] {
    let n = units.count
    var out = HighlightBuilder(unitCount: n)
    var i = 0
    var precededByDot = false

    while i < n {
        let u = units[i]
        if U16.isWS(u) { i += 1; continue }

        // Comments #, //, /* ... */
        if u == U16.hash || (u == U16.slash && i + 1 < n && units[i + 1] == U16.slash) {
            let end = U16.lineEnd(units, from: i + 1)
            out.emit(i, end, "comment")
            i = end
            continue
        }
        if u == U16.slash && i + 1 < n && units[i + 1] == U16.star {
            let end = scanDelimitedComment(units, from: i, open: [U16.slash, U16.star], close: [U16.star, U16.slash], nested: false)
            out.emit(i, end, "comment")
            i = end
            continue
        }

        // Heredocs <<EOF ... EOF and <<-EOF ... EOF
        if u == U16.lt && i + 1 < n && units[i + 1] == U16.lt {
            var j = i + 2
            var indented = false
            if j < n && units[j] == U16.minus { indented = true; j += 1 }
            let dStart = j
            while j < n && U16.isIdentContinue(units[j]) { j += 1 }
            if j > dStart {
                let delim = U16.slice(units, dStart, j)
                let bodyStart = U16.nextLineStart(units, after: U16.lineEnd(units, from: j))
                let bodyEnd = scanHeredocBody(units, bodyStart: bodyStart, delimiter: delim, allowLeadingWhitespace: indented)
                out.emit(i, bodyEnd, "string")
                i = bodyEnd
                precededByDot = false
                continue
            }
        }

        // Strings
        if u == U16.quote {
            let end = scanQuotedEnd(units, from: i, delimiter: U16.quote, allowMultiline: false)
            emitStringSpan(units, start: i, end: end, contentStart: i + 1, contentEnd: max(i + 1, end - 1), allowEscapes: true, into: &out)
            i = end
            precededByDot = false
            continue
        }

        // Numbers
        if U16.isDigit(u) {
            let end = scanNumberLiteral(units, from: i, allowSuffix: false)
            out.emit(i, end, "number")
            i = end
            precededByDot = false
            continue
        }

        // Identifiers / keywords / properties / types / functions
        if U16.isIdentStart(u) {
            var j = i + 1
            while j < n && (U16.isIdentContinue(units[j]) || units[j] == U16.minus) { j += 1 }
            let word = U16.slice(units, i, j)
            var look = j
            while look < n && U16.isInlineWS(units[look]) { look += 1 }
            let isAssign = look < n && units[look] == U16.eq && (look + 1 >= n || (units[look + 1] != U16.eq && units[look + 1] != U16.gt))
            let isCall = j < n && units[j] == U16.lparen

            if word == "true" || word == "false" {
                out.emit(i, j, "boolean")
            } else if word == "null" {
                out.emit(i, j, "constant.builtin")
            } else if isAssign && !precededByDot {
                out.emit(i, j, "property")
            } else if hclKeywords.contains(word) && !precededByDot {
                out.emit(i, j, "keyword")
            } else if hclBuiltinTypes.contains(word) && !precededByDot {
                out.emit(i, j, "type.builtin")
            } else if isCall {
                out.emit(i, j, "function")
            } else if precededByDot {
                out.emit(i, j, "property")
            }
            i = j
            precededByDot = false
            continue
        }

        if U16.isBracket(u) {
            out.emit(i, i + 1, "punctuation.bracket")
            precededByDot = false
            i += 1
            continue
        }
        if U16.isDelimiter(u) {
            out.emit(i, i + 1, "punctuation.delimiter")
            precededByDot = (u == U16.dot)
            i += 1
            continue
        }
        if U16.isOperatorChar(u) {
            var j = i + 1
            while j < n && U16.isOperatorChar(units[j]) { j += 1 }
            out.emit(i, j, "operator")
            precededByDot = false
            i = j
            continue
        }

        precededByDot = false
        i = U16.step(units, i)
    }

    return out.highlights
}

// MARK: - Haskell Lexer

private let haskellKeywords: Set<String> = [
    "case", "class", "data", "default", "deriving", "do", "else", "family", "forall",
    "foreign", "hiding", "if", "import", "in", "infix", "infixl", "infixr", "instance",
    "let", "mdo", "module", "newtype", "of", "pattern", "proc", "qualified", "rec", "stock",
    "then", "type", "via", "where",
]

private let haskellBuiltinTypes: Set<String> = [
    "Int", "Integer", "Float", "Double", "Bool", "Char", "String", "Text", "ByteString",
    "IO", "Maybe", "Either", "Ordering", "Word",
]

private let haskellBuiltinConstants: Set<String> = ["Nothing", "Just", "Left", "Right", "EQ", "LT", "GT"]

private func tokenizeHaskellGrammar(_ units: [UInt16]) -> [SimpleHighlight] {
    let n = units.count
    var out = HighlightBuilder(unitCount: n)
    var i = 0

    while i < n {
        let u = units[i]
        if U16.isWS(u) { i += 1; continue }

        // Pragma {-# ... #-}
        if U16.matchesASCII(units, at: i, "{-#") {
            var j = i + 3
            while j < n && !U16.matchesASCII(units, at: j, "#-}") { j = U16.step(units, j) }
            let end = (j + 3 <= n && U16.matchesASCII(units, at: j, "#-}")) ? j + 3 : j
            out.emit(i, end, "attribute")
            i = end
            continue
        }

        // Nested multi-line block comment {- ... -}
        if u == U16.lbrace && i + 1 < n && units[i + 1] == U16.minus {
            let end = scanDelimitedComment(units, from: i, open: [U16.lbrace, U16.minus], close: [U16.minus, U16.rbrace], nested: true)
            out.emit(i, end, "comment")
            i = end
            continue
        }

        // Line comment -- ... (not an operator like -->)
        if u == U16.minus && i + 1 < n && units[i + 1] == U16.minus {
            var k = i + 2
            while k < n && units[k] == U16.minus { k += 1 }
            if k == n || !U16.isOperatorChar(units[k]) {
                let end = U16.lineEnd(units, from: k)
                out.emit(i, end, "comment")
                i = end
                continue
            }
        }

        // Strings & char literals
        if u == U16.quote {
            let end = scanQuotedEnd(units, from: i, delimiter: U16.quote, allowMultiline: true)
            emitStringSpan(units, start: i, end: end, contentStart: i + 1, contentEnd: max(i + 1, end - 1), allowEscapes: true, into: &out)
            i = end
            continue
        }
        if u == U16.apos {
            let end = scanQuotedEnd(units, from: i, delimiter: U16.apos, allowMultiline: false)
            emitStringSpan(units, start: i, end: end, contentStart: i + 1, contentEnd: max(i + 1, end - 1), allowEscapes: true, detectURL: false, into: &out)
            i = end
            continue
        }

        // Numbers
        if U16.isDigit(u) {
            let end = scanNumberLiteral(units, from: i, allowSuffix: false)
            out.emit(i, end, "number")
            i = end
            continue
        }

        // Identifiers / constructors / types / function signatures
        if U16.isIdentStart(u) {
            var j = i + 1
            while j < n && (U16.isIdentContinue(units[j]) || units[j] == U16.apos) { j += 1 }
            let word = U16.slice(units, i, j)
            var look = j
            while look < n && U16.isInlineWS(units[look]) { look += 1 }
            let isTypeSig = look + 1 < n && units[look] == U16.colon && units[look + 1] == U16.colon

            if word == "True" || word == "False" {
                out.emit(i, j, "boolean")
            } else if haskellBuiltinConstants.contains(word) {
                out.emit(i, j, "constant.builtin")
            } else if haskellKeywords.contains(word) {
                out.emit(i, j, "keyword")
            } else if haskellBuiltinTypes.contains(word) {
                out.emit(i, j, "type.builtin")
            } else if isTypeSig {
                out.emit(i, j, "function")
            } else if U16.isASCIIUpper(u) {
                out.emit(i, j, "type")
            }
            i = j
            continue
        }

        if U16.isBracket(u) { out.emit(i, i + 1, "punctuation.bracket"); i += 1; continue }
        if U16.isDelimiter(u) { out.emit(i, i + 1, "punctuation.delimiter"); i += 1; continue }
        if U16.isOperatorChar(u) || u == U16.backslash {
            var j = i + 1
            while j < n && U16.isOperatorChar(units[j]) { j += 1 }
            out.emit(i, j, "operator")
            i = j
            continue
        }

        i = U16.step(units, i)
    }

    return out.highlights
}

// MARK: - Agda Lexer (with Unicode Operators, Pragmas, & Typed Holes)

private let agdaKeywords: Set<String> = [
    "abstract", "codata", "coinductive", "constructor", "data", "do", "eta-equality", "field",
    "forall", "hiding", "import", "in", "inductive", "infix", "infixl", "infixr", "instance",
    "interleaved", "let", "macro", "module", "mutual", "no-eta-equality", "open", "overlap",
    "pattern", "postulate", "primitive", "private", "public", "quote", "quoteTerm", "record",
    "renaming", "rewrite", "syntax", "tactic", "unquote", "unquoteDecl", "unquoteDef", "using",
    "variable", "where", "with",
]

private let agdaBuiltinTypes: Set<String> = [
    "Set", "Set₀", "Set₁", "Set₂", "Prop", "Level", "ℕ", "ℤ", "Bool", "Nat", "List", "Vec",
    "Maybe", "String", "Char", "Float", "⊤", "⊥",
]

private func isAgdaUnicodeOperator(_ u: UInt16) -> Bool {
    // → (0x2192), λ (0x03BB), ∀ (0x2200), ≡ (0x2261), × (0x00D7), ⊎ (0x228E), ∶ (0x2236), ↦ (0x21A6)
    switch u {
    case 0x2192, 0x03BB, 0x2200, 0x2261, 0x00D7, 0x228E, 0x2236, 0x21A6, 0x2264, 0x2265, 0x2260:
        return true
    default:
        return false
    }
}

private func isAgdaIdentStop(_ u: UInt16) -> Bool {
    U16.isWS(u) || U16.isBracket(u) || u == U16.semi || u == U16.dot || u == U16.quote || u == U16.at || u == U16.colon || u == U16.eq || isAgdaUnicodeOperator(u)
}

private func tokenizeAgdaGrammar(_ units: [UInt16]) -> [SimpleHighlight] {
    let n = units.count
    var out = HighlightBuilder(unitCount: n)
    var i = 0

    while i < n {
        let u = units[i]
        if U16.isWS(u) { i += 1; continue }

        // Pragma {-# ... #-}
        if U16.matchesASCII(units, at: i, "{-#") {
            var j = i + 3
            while j < n && !U16.matchesASCII(units, at: j, "#-}") { j = U16.step(units, j) }
            let end = (j + 3 <= n && U16.matchesASCII(units, at: j, "#-}")) ? j + 3 : j
            out.emit(i, end, "attribute")
            i = end
            continue
        }

        // Typed hole {! ... !}
        if U16.matchesASCII(units, at: i, "{!") {
            let end = scanDelimitedComment(units, from: i, open: [U16.lbrace, U16.bang], close: [U16.bang, U16.rbrace], nested: true)
            out.emit(i, end, "attribute")
            i = end
            continue
        }

        // Nested multi-line comment {- ... -}
        if u == U16.lbrace && i + 1 < n && units[i + 1] == U16.minus {
            let end = scanDelimitedComment(units, from: i, open: [U16.lbrace, U16.minus], close: [U16.minus, U16.rbrace], nested: true)
            out.emit(i, end, "comment")
            i = end
            continue
        }

        // Line comment -- ...
        if u == U16.minus && i + 1 < n && units[i + 1] == U16.minus && (i + 2 == n || U16.isWS(units[i + 2])) {
            let end = U16.lineEnd(units, from: i + 2)
            out.emit(i, end, "comment")
            i = end
            continue
        }

        // Strings & char literals
        if u == U16.quote {
            let end = scanQuotedEnd(units, from: i, delimiter: U16.quote, allowMultiline: false)
            emitStringSpan(units, start: i, end: end, contentStart: i + 1, contentEnd: max(i + 1, end - 1), allowEscapes: true, into: &out)
            i = end
            continue
        }
        if u == U16.apos {
            let end = scanQuotedEnd(units, from: i, delimiter: U16.apos, allowMultiline: false)
            emitStringSpan(units, start: i, end: end, contentStart: i + 1, contentEnd: max(i + 1, end - 1), allowEscapes: true, detectURL: false, into: &out)
            i = end
            continue
        }

        // Numbers
        if U16.isDigit(u) {
            let end = scanNumberLiteral(units, from: i, allowSuffix: false)
            out.emit(i, end, "number")
            i = end
            continue
        }

        if U16.isBracket(u) { out.emit(i, i + 1, "punctuation.bracket"); i += 1; continue }
        if u == U16.semi || u == U16.dot || u == U16.comma { out.emit(i, i + 1, "punctuation.delimiter"); i += 1; continue }

        // Unicode & ASCII operators
        if isAgdaUnicodeOperator(u) || u == U16.colon || u == U16.eq || u == U16.backslash || u == U16.question
            || (u == U16.minus && i + 1 < n && units[i + 1] == U16.gt)
        {
            let end = (u == U16.minus && i + 1 < n && units[i + 1] == U16.gt) ? i + 2 : U16.step(units, i)
            out.emit(i, end, "operator")
            i = end
            continue
        }

        // Agda identifiers (may include Unicode letters, subscripts, hyphens, etc.)
        var j = U16.step(units, i)
        while j < n && !isAgdaIdentStop(units[j]) {
            j = U16.step(units, j)
        }
        let word = U16.slice(units, i, j)
        var look = j
        while look < n && U16.isInlineWS(units[look]) { look += 1 }
        let isTypeSig = look < n && (units[look] == U16.colon || units[look] == 0x2236)

        if word == "true" || word == "false" {
            out.emit(i, j, "boolean")
        } else if agdaKeywords.contains(word) {
            out.emit(i, j, "keyword")
        } else if agdaBuiltinTypes.contains(word) {
            out.emit(i, j, "type.builtin")
        } else if isTypeSig {
            out.emit(i, j, "function")
        } else if U16.isASCIIUpper(u) {
            out.emit(i, j, "type")
        }
        i = j
    }

    return out.highlights
}

// MARK: - OCaml Lexer

private let ocamlKeywords: Set<String> = [
    "as", "assert", "begin", "class", "constraint", "do", "done", "downto", "else", "end",
    "exception", "external", "for", "functor", "if", "in", "include", "inherit", "initializer",
    "lazy", "let", "match", "method", "module", "mutable", "new", "nonrec", "object", "of",
    "open", "private", "rec", "sig", "struct", "then", "to", "try", "type", "val", "virtual",
    "when", "while", "with",
]

private let ocamlOperatorKeywords: Set<String> = [
    "and", "asr", "land", "lor", "lsl", "lsr", "lxor", "mod", "not", "or",
]

private let ocamlBuiltinTypes: Set<String> = [
    "int", "float", "bool", "char", "string", "bytes", "unit", "list", "array", "option",
    "result", "ref", "exn",
]

private func scanOCamlQuotedString(_ units: [UInt16], from start: Int) -> Int? {
    let n = units.count
    guard start + 1 < n && units[start] == U16.lbrace else { return nil }
    var d = start + 1
    while d < n && (U16.isASCIILower(units[d]) || units[d] == U16.underscore) { d += 1 }
    guard d < n && units[d] == U16.pipe else { return nil }
    var closePattern: [UInt16] = [U16.pipe]
    closePattern.append(contentsOf: units[(start + 1)..<d])
    closePattern.append(U16.rbrace)
    var i = d + 1
    while i < n {
        if matchUnits(units, at: i, closePattern) { return i + closePattern.count }
        i = U16.step(units, i)
    }
    return n
}

private func tokenizeOCamlGrammar(_ units: [UInt16]) -> [SimpleHighlight] {
    let n = units.count
    var out = HighlightBuilder(unitCount: n)
    var i = 0
    var prevWord: String? = nil

    while i < n {
        let u = units[i]
        if U16.isWS(u) { i += 1; continue }

        // Nested multi-line comment (* ... *)
        if u == U16.lparen && i + 1 < n && units[i + 1] == U16.star {
            let end = scanDelimitedComment(units, from: i, open: [U16.lparen, U16.star], close: [U16.star, U16.rparen], nested: true)
            out.emit(i, end, "comment")
            i = end
            continue
        }

        // Attributes [@attr] / [@@attr] / [%ext]
        if u == U16.lbracket && i + 1 < n && (units[i + 1] == U16.at || units[i + 1] == U16.percent) {
            out.emit(i, i + 1, "punctuation.bracket")
            var j = i + 1
            while j < n && (units[j] == U16.at || units[j] == U16.percent) { j += 1 }
            while j < n && (U16.isIdentContinue(units[j]) || units[j] == U16.dot) { j += 1 }
            out.emit(i + 1, j, "attribute")
            i = j
            prevWord = nil
            continue
        }

        // Quoted multi-line string {| ... |} / {tag| ... |tag}
        if u == U16.lbrace, let end = scanOCamlQuotedString(units, from: i) {
            out.emit(i, end, "string")
            i = end
            prevWord = nil
            continue
        }

        // Regular strings "..."
        if u == U16.quote {
            let end = scanQuotedEnd(units, from: i, delimiter: U16.quote, allowMultiline: true)
            emitStringSpan(units, start: i, end: end, contentStart: i + 1, contentEnd: max(i + 1, end - 1), allowEscapes: true, into: &out)
            i = end
            prevWord = nil
            continue
        }

        // Char literal 'a' or type variable 'a
        if u == U16.apos && i + 1 < n {
            if units[i + 1] == U16.backslash {
                let end = scanQuotedEnd(units, from: i, delimiter: U16.apos, allowMultiline: false)
                emitStringSpan(units, start: i, end: end, contentStart: i + 1, contentEnd: max(i + 1, end - 1), allowEscapes: true, detectURL: false, into: &out)
                i = end
                prevWord = nil
                continue
            }
            let afterChar = U16.step(units, i + 1)
            if afterChar < n && units[afterChar] == U16.apos {
                out.emit(i, afterChar + 1, "string")
                i = afterChar + 1
                prevWord = nil
                continue
            }
            if U16.isIdentStart(units[i + 1]) {
                var j = i + 2
                while j < n && U16.isIdentContinue(units[j]) { j += 1 }
                out.emit(i, j, "type")
                i = j
                prevWord = nil
                continue
            }
        }

        // Numbers
        if U16.isDigit(u) {
            let end = scanNumberLiteral(units, from: i)
            out.emit(i, end, "number")
            i = end
            prevWord = nil
            continue
        }

        // Identifiers
        if U16.isIdentStart(u) {
            var j = i + 1
            while j < n && (U16.isIdentContinue(units[j]) || units[j] == U16.apos) { j += 1 }
            let word = U16.slice(units, i, j)
            if word == "true" || word == "false" {
                out.emit(i, j, "boolean")
            } else if word == "None" || word == "Some" || word == "Ok" || word == "Error" {
                out.emit(i, j, "constant.builtin")
            } else if word == "fun" || word == "function" {
                out.emit(i, j, "keyword.function")
            } else if ocamlOperatorKeywords.contains(word) {
                out.emit(i, j, "keyword.operator")
            } else if ocamlKeywords.contains(word) {
                out.emit(i, j, "keyword")
            } else if prevWord == "let" || prevWord == "rec" || prevWord == "val" {
                out.emit(i, j, "function")
            } else if prevWord == "type" || prevWord == "module" {
                out.emit(i, j, "type")
            } else if ocamlBuiltinTypes.contains(word) {
                out.emit(i, j, "type.builtin")
            } else if U16.isASCIIUpper(u) {
                out.emit(i, j, "type")
            }
            prevWord = word
            i = j
            continue
        }

        if U16.isBracket(u) { out.emit(i, i + 1, "punctuation.bracket"); prevWord = nil; i += 1; continue }
        if U16.isDelimiter(u) { out.emit(i, i + 1, "punctuation.delimiter"); prevWord = nil; i += 1; continue }
        if U16.isOperatorChar(u) {
            var j = i + 1
            while j < n && U16.isOperatorChar(units[j]) { j += 1 }
            out.emit(i, j, "operator")
            prevWord = nil
            i = j
            continue
        }

        prevWord = nil
        i = U16.step(units, i)
    }

    return out.highlights
}

// MARK: - F# Lexer

private let fsharpKeywords: Set<String> = [
    "abstract", "as", "assert", "base", "begin", "class", "default", "delegate", "do", "do!",
    "done", "downcast", "downto", "elif", "else", "end", "exception", "extern", "finally", "for",
    "global", "if", "inherit", "inline", "interface", "internal", "lazy", "let", "let!", "match",
    "match!", "member", "module", "mutable", "namespace", "new", "of", "open", "override",
    "private", "public", "rec", "select", "static", "struct", "then", "to", "try", "type",
    "upcast", "use", "use!", "val", "void", "when", "while", "with",
]

private let fsharpBuiltinTypes: Set<String> = [
    "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64",
    "float", "float32", "decimal", "bool", "char", "string", "byte", "sbyte", "unit", "obj",
    "exn", "list", "seq", "array", "option", "voption", "Result", "Async", "Task",
]

private func tokenizeFSharpGrammar(_ units: [UInt16]) -> [SimpleHighlight] {
    let n = units.count
    var out = HighlightBuilder(unitCount: n)
    var i = 0
    var prevWord: String? = nil

    while i < n {
        let u = units[i]
        if U16.isWS(u) { i += 1; continue }

        // Line comment //
        if u == U16.slash && i + 1 < n && units[i + 1] == U16.slash {
            let end = U16.lineEnd(units, from: i + 2)
            out.emit(i, end, "comment")
            i = end
            continue
        }

        // Nested multi-line block comment (* ... *)
        if u == U16.lparen && i + 1 < n && units[i + 1] == U16.star {
            let end = scanDelimitedComment(units, from: i, open: [U16.lparen, U16.star], close: [U16.star, U16.rparen], nested: true)
            out.emit(i, end, "comment")
            i = end
            continue
        }

        // Attributes [<EntryPoint>]
        if u == U16.lbracket && i + 1 < n && units[i + 1] == U16.lt {
            out.emit(i, i + 2, "punctuation.bracket")
            var j = i + 2
            while j + 1 < n && !(units[j] == U16.gt && units[j + 1] == U16.rbracket) && !U16.isNewline(units[j]) {
                if U16.isIdentStart(units[j]) {
                    let s = j
                    while j < n && (U16.isIdentContinue(units[j]) || units[j] == U16.dot) { j += 1 }
                    out.emit(s, j, "attribute")
                } else {
                    j = U16.step(units, j)
                }
            }
            if j + 1 < n && units[j] == U16.gt && units[j + 1] == U16.rbracket {
                out.emit(j, j + 2, "punctuation.bracket")
                i = j + 2
            } else {
                i = j
            }
            prevWord = nil
            continue
        }

        // Preprocessor directives #if, #r, #load, #open
        if u == U16.hash && i + 1 < n && U16.isASCIILetter(units[i + 1]) {
            var j = i + 2
            while j < n && U16.isIdentContinue(units[j]) { j += 1 }
            out.emit(i, j, "keyword")
            i = j
            prevWord = nil
            continue
        }

        // Verbatim / interpolated strings @"...", $"..."
        if (u == U16.at || u == U16.dollar) && i + 1 < n && units[i + 1] == U16.quote {
            let isVerbatim = (u == U16.at)
            let end = scanQuotedEnd(units, from: i + 1, delimiter: U16.quote, allowMultiline: true, allowEscapes: !isVerbatim, doubledQuoteEscape: isVerbatim)
            emitStringSpan(units, start: i, end: end, contentStart: i + 2, contentEnd: max(i + 2, end - 1), allowEscapes: !isVerbatim, into: &out)
            i = end
            prevWord = nil
            continue
        }

        // Triple-quoted strings """..."""
        if u == U16.quote && i + 2 < n && units[i + 1] == U16.quote && units[i + 2] == U16.quote {
            let end = scanTripleQuotedEnd(units, from: i, delimiter: U16.quote, allowEscapes: false)
            out.emit(i, end, "string")
            i = end
            prevWord = nil
            continue
        }

        // Strings & chars
        if u == U16.quote || u == U16.apos {
            let end = scanQuotedEnd(units, from: i, delimiter: u, allowMultiline: u == U16.quote)
            emitStringSpan(units, start: i, end: end, contentStart: i + 1, contentEnd: max(i + 1, end - 1), allowEscapes: true, detectURL: u == U16.quote, into: &out)
            i = end
            prevWord = nil
            continue
        }

        // Numbers
        if U16.isDigit(u) {
            let end = scanNumberLiteral(units, from: i)
            out.emit(i, end, "number")
            i = end
            prevWord = nil
            continue
        }

        // Identifiers
        if U16.isIdentStart(u) {
            var j = i + 1
            while j < n && U16.isIdentContinue(units[j]) { j += 1 }
            if j < n && units[j] == U16.bang { j += 1 }
            let word = U16.slice(units, i, j)
            if word == "true" || word == "false" {
                out.emit(i, j, "boolean")
            } else if word == "null" || word == "None" || word == "Some" || word == "Ok" || word == "Error" {
                out.emit(i, j, "constant.builtin")
            } else if word == "fun" || word == "function" {
                out.emit(i, j, "keyword.function")
            } else if word == "return" || word == "return!" || word == "yield" || word == "yield!" {
                out.emit(i, j, "keyword.return")
            } else if word == "and" || word == "or" || word == "not" || word == "in" {
                out.emit(i, j, "keyword.operator")
            } else if fsharpKeywords.contains(word) {
                out.emit(i, j, "keyword")
            } else if prevWord == "let" || prevWord == "rec" || prevWord == "member" {
                out.emit(i, j, "function")
            } else if prevWord == "type" || prevWord == "module" || prevWord == "namespace" {
                out.emit(i, j, "type")
            } else if fsharpBuiltinTypes.contains(word) {
                out.emit(i, j, "type.builtin")
            } else if U16.isASCIIUpper(u) {
                out.emit(i, j, "type")
            }
            prevWord = word
            i = j
            continue
        }

        if U16.isBracket(u) { out.emit(i, i + 1, "punctuation.bracket"); prevWord = nil; i += 1; continue }
        if U16.isDelimiter(u) { out.emit(i, i + 1, "punctuation.delimiter"); prevWord = nil; i += 1; continue }
        if U16.isOperatorChar(u) {
            var j = i + 1
            while j < n && U16.isOperatorChar(units[j]) {
                if units[j] == U16.slash && j + 1 < n && units[j + 1] == U16.slash { break }
                j += 1
            }
            out.emit(i, j, "operator")
            prevWord = nil
            i = j
            continue
        }

        prevWord = nil
        i = U16.step(units, i)
    }

    return out.highlights
}

// MARK: - Julia Lexer

private let juliaKeywords: Set<String> = [
    "abstract", "baremodule", "begin", "break", "catch", "const", "continue", "do", "else",
    "elseif", "end", "export", "finally", "for", "global", "if", "import", "let", "local",
    "module", "mutable", "outer", "primitive", "quote", "struct", "try", "type", "using",
    "where", "while",
]

private let juliaBuiltinTypes: Set<String> = [
    "Any", "Nothing", "Missing", "Bool", "Char", "String", "Symbol", "Int", "Int8", "Int16",
    "Int32", "Int64", "Int128", "UInt", "UInt8", "UInt16", "UInt32", "UInt64", "UInt128",
    "Float16", "Float32", "Float64", "Number", "Real", "Complex", "Vector", "Matrix", "Array",
    "Dict", "Set", "Tuple", "NamedTuple", "Union", "Type",
]

private func tokenizeJuliaGrammar(_ units: [UInt16]) -> [SimpleHighlight] {
    let n = units.count
    var out = HighlightBuilder(unitCount: n)
    var i = 0
    var prevWord: String? = nil
    var precededByDot = false
    var expectParamList = false
    var inParamList = false
    var paramDepth = 0
    var expectParamName = false

    while i < n {
        let u = units[i]
        if U16.isWS(u) { i += 1; continue }

        // Nested multi-line block comment #= ... =#
        if u == U16.hash && i + 1 < n && units[i + 1] == U16.eq {
            let end = scanDelimitedComment(units, from: i, open: [U16.hash, U16.eq], close: [U16.eq, U16.hash], nested: true)
            out.emit(i, end, "comment")
            i = end
            continue
        }

        // Line comment # ...
        if u == U16.hash {
            let end = U16.lineEnd(units, from: i + 1)
            out.emit(i, end, "comment")
            i = end
            continue
        }

        // Macros @show, @time, @inline, @testset
        if u == U16.at && i + 1 < n && U16.isIdentStart(units[i + 1]) {
            var j = i + 2
            while j < n && (U16.isIdentContinue(units[j]) || units[j] == U16.bang) { j += 1 }
            out.emit(i, j, "function.macro")
            i = j
            prevWord = nil
            precededByDot = false
            continue
        }

        // Prefixed strings raw"...", r"...", b"...", v"..."
        if U16.matchesASCII(units, at: i, "raw\"") || ((u == U16.lowerR || u == U16.lowerB || u == U16.lowerV) && i + 1 < n && units[i + 1] == U16.quote) {
            let q = U16.matchesASCII(units, at: i, "raw\"") ? i + 3 : i + 1
            let isRaw = (u == U16.lowerR)
            let end = scanQuotedEnd(units, from: q, delimiter: U16.quote, allowMultiline: true, allowEscapes: !isRaw)
            emitStringSpan(units, start: i, end: end, contentStart: q + 1, contentEnd: max(q + 1, end - 1), allowEscapes: !isRaw, into: &out)
            i = end
            prevWord = nil
            precededByDot = false
            continue
        }

        // Triple-quoted strings """..."""
        if u == U16.quote && i + 2 < n && units[i + 1] == U16.quote && units[i + 2] == U16.quote {
            let end = scanTripleQuotedEnd(units, from: i, delimiter: U16.quote)
            emitStringSpan(units, start: i, end: end, contentStart: i + 3, contentEnd: max(i + 3, end - 3), allowEscapes: true, detectURL: false, into: &out)
            i = end
            prevWord = nil
            precededByDot = false
            continue
        }

        // Strings "..." / command literals `...` / char '...'
        if u == U16.quote || u == U16.backtick || u == U16.apos {
            let end = scanQuotedEnd(units, from: i, delimiter: u, allowMultiline: u != U16.apos)
            emitStringSpan(units, start: i, end: end, contentStart: i + 1, contentEnd: max(i + 1, end - 1), allowEscapes: true, detectURL: u == U16.quote, into: &out)
            i = end
            prevWord = nil
            precededByDot = false
            continue
        }

        // Symbols :foo (not ::)
        if u == U16.colon && i + 1 < n && units[i + 1] != U16.colon && U16.isIdentStart(units[i + 1]) {
            var j = i + 2
            while j < n && U16.isIdentContinue(units[j]) { j += 1 }
            out.emit(i, j, "constant.builtin")
            i = j
            prevWord = nil
            precededByDot = false
            continue
        }

        // Numbers
        if U16.isDigit(u) {
            let end = scanNumberLiteral(units, from: i)
            out.emit(i, end, "number")
            i = end
            prevWord = nil
            precededByDot = false
            continue
        }

        // Identifiers
        if U16.isIdentStart(u) {
            var j = i + 1
            while j < n && (U16.isIdentContinue(units[j]) || units[j] == U16.bang) { j += 1 }
            let word = U16.slice(units, i, j)
            let nextIsCall = j < n && units[j] == U16.lparen

            if word == "true" || word == "false" {
                out.emit(i, j, "boolean")
            } else if word == "nothing" || word == "missing" || word == "NaN" || word == "Inf" || word == "pi" || word == "im" {
                out.emit(i, j, "constant.builtin")
            } else if (word == "function" || word == "macro") && !precededByDot {
                out.emit(i, j, "keyword.function")
                expectParamList = true
            } else if word == "return" && !precededByDot {
                out.emit(i, j, "keyword.return")
            } else if (word == "in" || word == "isa") && !precededByDot {
                out.emit(i, j, "keyword.operator")
            } else if juliaKeywords.contains(word) && !precededByDot {
                out.emit(i, j, "keyword")
            } else if prevWord == "function" || prevWord == "macro" {
                out.emit(i, j, "function")
                expectParamList = true
            } else if prevWord == "struct" || prevWord == "module" {
                out.emit(i, j, "type")
            } else if juliaBuiltinTypes.contains(word) && !precededByDot {
                out.emit(i, j, "type.builtin")
            } else if inParamList && paramDepth == 1 && expectParamName && !nextIsCall {
                out.emit(i, j, "variable.parameter")
                expectParamName = false
            } else if nextIsCall {
                out.emit(i, j, precededByDot ? "function.method" : "function")
            } else if precededByDot {
                out.emit(i, j, "property")
            } else if U16.isASCIIUpper(u) {
                out.emit(i, j, "type")
            }
            prevWord = word
            precededByDot = false
            i = j
            continue
        }

        if U16.isBracket(u) {
            out.emit(i, i + 1, "punctuation.bracket")
            if u == U16.lparen {
                if expectParamList { inParamList = true; expectParamList = false; paramDepth = 1; expectParamName = true }
                else if inParamList { paramDepth += 1 }
            } else if u == U16.rparen && inParamList {
                paramDepth -= 1
                if paramDepth <= 0 { inParamList = false; expectParamName = false }
            }
            prevWord = nil
            precededByDot = false
            i += 1
            continue
        }

        if U16.isDelimiter(u) {
            out.emit(i, i + 1, "punctuation.delimiter")
            if u == U16.comma && inParamList && paramDepth == 1 { expectParamName = true }
            precededByDot = (u == U16.dot)
            prevWord = nil
            i += 1
            continue
        }

        if U16.isOperatorChar(u) {
            var j = i + 1
            while j < n && U16.isOperatorChar(units[j]) { j += 1 }
            out.emit(i, j, "operator")
            if inParamList && paramDepth == 1 && u == U16.colon { expectParamName = false }
            prevWord = nil
            precededByDot = false
            i = j
            continue
        }

        prevWord = nil
        precededByDot = false
        i = U16.step(units, i)
    }

    return out.highlights
}

// MARK: - Lua Lexer (with Arbitrary-Level Long Bracket Strings & Comments)

private let luaKeywords: Set<String> = [
    "break", "do", "else", "elseif", "end", "for", "goto", "if", "in", "local", "repeat",
    "then", "until", "while",
]

private func scanLuaLongBracket(_ units: [UInt16], from start: Int) -> Int? {
    let n = units.count
    guard start + 1 < n && units[start] == U16.lbracket else { return nil }
    var eqCount = 0
    var j = start + 1
    while j < n && units[j] == U16.eq { eqCount += 1; j += 1 }
    guard j < n && units[j] == U16.lbracket else { return nil }
    var closePattern: [UInt16] = [U16.rbracket]
    if eqCount > 0 { closePattern.append(contentsOf: repeatElement(U16.eq, count: eqCount)) }
    closePattern.append(U16.rbracket)
    var i = j + 1
    while i < n {
        if matchUnits(units, at: i, closePattern) { return i + closePattern.count }
        i = U16.step(units, i)
    }
    return n
}

private func tokenizeLuaGrammar(_ units: [UInt16]) -> [SimpleHighlight] {
    let n = units.count
    var out = HighlightBuilder(unitCount: n)
    var i = 0
    var prevWord: String? = nil
    var precededByDot = false
    var precededByColon = false
    var expectParamList = false
    var inParamList = false
    var paramDepth = 0
    var expectParamName = false

    while i < n {
        let u = units[i]
        if U16.isWS(u) { i += 1; continue }

        // Comments -- ... and multi-line --[=[ ... ]=]
        if u == U16.minus && i + 1 < n && units[i + 1] == U16.minus {
            if let longEnd = scanLuaLongBracket(units, from: i + 2) {
                out.emit(i, longEnd, "comment")
                i = longEnd
            } else {
                let end = U16.lineEnd(units, from: i + 2)
                out.emit(i, end, "comment")
                i = end
            }
            continue
        }

        // Long-bracket multi-line strings [[ ... ]] / [=[ ... ]=]
        if u == U16.lbracket, let longEnd = scanLuaLongBracket(units, from: i) {
            out.emit(i, longEnd, "string")
            i = longEnd
            prevWord = nil
            precededByDot = false
            precededByColon = false
            continue
        }

        // Labels ::label::
        if u == U16.colon && i + 1 < n && units[i + 1] == U16.colon {
            var j = i + 2
            while j < n && U16.isIdentContinue(units[j]) { j += 1 }
            if j + 1 < n && units[j] == U16.colon && units[j + 1] == U16.colon {
                out.emit(i, j + 2, "attribute")
                i = j + 2
                prevWord = nil
                precededByDot = false
                precededByColon = false
                continue
            }
        }

        // Strings "..." / '...'
        if u == U16.quote || u == U16.apos {
            let end = scanQuotedEnd(units, from: i, delimiter: u, allowMultiline: false)
            emitStringSpan(units, start: i, end: end, contentStart: i + 1, contentEnd: max(i + 1, end - 1), allowEscapes: true, into: &out)
            i = end
            prevWord = nil
            precededByDot = false
            precededByColon = false
            continue
        }

        // Numbers
        if U16.isDigit(u) {
            let end = scanNumberLiteral(units, from: i, allowSuffix: false)
            out.emit(i, end, "number")
            i = end
            prevWord = nil
            precededByDot = false
            precededByColon = false
            continue
        }

        // Identifiers / keywords / methods
        if U16.isIdentStart(u) {
            var j = i + 1
            while j < n && U16.isIdentContinue(units[j]) { j += 1 }
            let word = U16.slice(units, i, j)
            let nextIsCall = j < n && (units[j] == U16.lparen || units[j] == U16.quote || units[j] == U16.lbrace)

            if word == "true" || word == "false" {
                out.emit(i, j, "boolean")
            } else if word == "nil" {
                out.emit(i, j, "constant.builtin")
            } else if word == "function" && !precededByDot && !precededByColon {
                out.emit(i, j, "keyword.function")
                expectParamList = true
            } else if word == "return" && !precededByDot && !precededByColon {
                out.emit(i, j, "keyword.return")
            } else if (word == "and" || word == "or" || word == "not") && !precededByDot && !precededByColon {
                out.emit(i, j, "keyword.operator")
            } else if luaKeywords.contains(word) && !precededByDot && !precededByColon {
                out.emit(i, j, "keyword")
            } else if prevWord == "function" {
                out.emit(i, j, (precededByDot || precededByColon) ? "function.method" : "function")
                expectParamList = true
            } else if inParamList && paramDepth == 1 && expectParamName {
                out.emit(i, j, "variable.parameter")
                expectParamName = false
            } else if precededByColon {
                out.emit(i, j, "function.method")
            } else if nextIsCall {
                out.emit(i, j, precededByDot ? "function.method" : "function")
            } else if precededByDot {
                out.emit(i, j, "property")
            }
            prevWord = word
            precededByDot = false
            precededByColon = false
            i = j
            continue
        }

        if U16.isBracket(u) {
            out.emit(i, i + 1, "punctuation.bracket")
            if u == U16.lparen {
                if expectParamList { inParamList = true; expectParamList = false; paramDepth = 1; expectParamName = true }
                else if inParamList { paramDepth += 1 }
            } else if u == U16.rparen && inParamList {
                paramDepth -= 1
                if paramDepth <= 0 { inParamList = false; expectParamName = false }
            }
            prevWord = nil
            precededByDot = false
            precededByColon = false
            i += 1
            continue
        }

        if U16.isDelimiter(u) {
            out.emit(i, i + 1, "punctuation.delimiter")
            if u == U16.comma && inParamList && paramDepth == 1 { expectParamName = true }
            precededByDot = (u == U16.dot)
            precededByColon = false
            prevWord = nil
            i += 1
            continue
        }

        if u == U16.colon {
            out.emit(i, i + 1, "punctuation.delimiter")
            precededByColon = true
            precededByDot = false
            prevWord = nil
            i += 1
            continue
        }

        if U16.isOperatorChar(u) {
            var j = i + 1
            while j < n && U16.isOperatorChar(units[j]) { j += 1 }
            out.emit(i, j, "operator")
            prevWord = nil
            precededByDot = false
            precededByColon = false
            i = j
            continue
        }

        prevWord = nil
        precededByDot = false
        precededByColon = false
        i = U16.step(units, i)
    }

    return out.highlights
}

// MARK: - Clojure Lexer

private let clojureFunctionKeywords: Set<String> = ["defn", "defn-", "fn", "defmacro", "defmethod", "defmulti"]
private let clojureMacroForms: Set<String> = ["->", "->>", "as->", "some->", "some->>", "cond->", "cond->>", "doto"]
private let clojureKeywords: Set<String> = [
    "case", "catch", "cond", "def", "defonce", "defprotocol", "defrecord", "deftype", "do",
    "doseq", "dotimes", "finally", "for", "if", "if-let", "if-not", "import", "let", "letfn",
    "loop", "ns", "quote", "recur", "require", "throw", "try", "use", "var", "when", "when-let",
    "when-not",
]

private func isClojureDelimiter(_ u: UInt16) -> Bool {
    U16.isWS(u) || U16.isBracket(u) || u == U16.quote || u == U16.semi || u == U16.comma
}

private func tokenizeClojureGrammar(_ units: [UInt16]) -> [SimpleHighlight] {
    let n = units.count
    var out = HighlightBuilder(unitCount: n)
    var i = 0
    var atListHead = false
    var expectDefName = false
    var expectParamVector = false
    var inParamVector = false

    while i < n {
        let u = units[i]
        if U16.isWS(u) || u == U16.comma {
            if u == U16.comma { out.emit(i, i + 1, "punctuation.delimiter") }
            i += 1
            continue
        }

        // Line comment ; ...
        if u == U16.semi {
            let end = U16.lineEnd(units, from: i + 1)
            out.emit(i, end, "comment")
            i = end
            continue
        }

        // Regex literal #"..."
        if u == U16.hash && i + 1 < n && units[i + 1] == U16.quote {
            let end = scanQuotedEnd(units, from: i + 1, delimiter: U16.quote, allowMultiline: true)
            emitStringSpan(units, start: i, end: end, contentStart: i + 2, contentEnd: max(i + 2, end - 1), allowEscapes: true, detectURL: false, into: &out)
            i = end
            atListHead = false
            continue
        }

        // Multi-line double-quoted string "..."
        if u == U16.quote {
            let end = scanQuotedEnd(units, from: i, delimiter: U16.quote, allowMultiline: true)
            emitStringSpan(units, start: i, end: end, contentStart: i + 1, contentEnd: max(i + 1, end - 1), allowEscapes: true, into: &out)
            i = end
            atListHead = false
            continue
        }

        // Character literal \a, \newline, \u03BB
        if u == U16.backslash && i + 1 < n {
            var j = U16.step(units, i + 1)
            while j < n && !isClojureDelimiter(units[j]) { j = U16.step(units, j) }
            out.emit(i, j, "string")
            i = j
            atListHead = false
            continue
        }

        // Metadata ^:private / ^String
        if u == U16.caret && i + 1 < n && !isClojureDelimiter(units[i + 1]) {
            var j = i + 1
            while j < n && !isClojureDelimiter(units[j]) { j = U16.step(units, j) }
            out.emit(i, j, "attribute")
            i = j
            continue
        }

        // Clojure keywords :foo / ::ns/bar
        if u == U16.colon {
            var j = i + 1
            while j < n && !isClojureDelimiter(units[j]) { j = U16.step(units, j) }
            out.emit(i, j, "property")
            i = j
            atListHead = false
            continue
        }

        // Brackets
        if U16.isBracket(u) {
            out.emit(i, i + 1, "punctuation.bracket")
            if u == U16.lparen {
                atListHead = true
            } else if u == U16.lbracket && expectParamVector {
                inParamVector = true
                expectParamVector = false
                atListHead = false
            } else if u == U16.rbracket && inParamVector {
                inParamVector = false
                atListHead = false
            } else {
                atListHead = false
            }
            i += 1
            continue
        }

        // Numbers (including ratios like 1/3 and BigInt 42N)
        if U16.isDigit(u) || (u == U16.minus && i + 1 < n && U16.isDigit(units[i + 1])) {
            var j = (u == U16.minus) ? i + 1 : i
            while j < n && !isClojureDelimiter(units[j]) { j += 1 }
            out.emit(i, j, "number")
            i = j
            atListHead = false
            continue
        }

        // Symbols / special forms / macros / functions / parameters
        var j = U16.step(units, i)
        while j < n && !isClojureDelimiter(units[j]) { j = U16.step(units, j) }
        let sym = U16.slice(units, i, j)

        if sym == "true" || sym == "false" {
            out.emit(i, j, "boolean")
        } else if sym == "nil" {
            out.emit(i, j, "constant.builtin")
        } else if clojureFunctionKeywords.contains(sym) {
            out.emit(i, j, "keyword.function")
            expectDefName = (sym != "fn")
            expectParamVector = (sym == "fn")
        } else if clojureMacroForms.contains(sym) {
            out.emit(i, j, "function.macro")
        } else if clojureKeywords.contains(sym) {
            out.emit(i, j, "keyword")
        } else if expectDefName {
            out.emit(i, j, "function")
            expectDefName = false
            expectParamVector = true
        } else if inParamVector {
            out.emit(i, j, sym == "&" ? "operator" : "variable.parameter")
        } else if atListHead {
            out.emit(i, j, "function")
        }
        atListHead = false
        i = j
    }

    return out.highlights
}

// MARK: - Elixir Lexer

private let elixirFunctionKeywords: Set<String> = [
    "def", "defp", "defmacro", "defmacrop", "defguard", "defguardp", "defdelegate", "fn",
]
private let elixirOperatorKeywords: Set<String> = ["and", "in", "not", "or", "when"]
private let elixirKeywords: Set<String> = [
    "after", "alias", "case", "catch", "cond", "defexception", "defimpl", "defmodule",
    "defprotocol", "defstruct", "do", "else", "end", "for", "if", "import", "quote", "raise",
    "receive", "require", "rescue", "send", "throw", "try", "unless", "unquote", "use", "with",
]

private func tokenizeElixirGrammar(_ units: [UInt16]) -> [SimpleHighlight] {
    let n = units.count
    var out = HighlightBuilder(unitCount: n)
    var i = 0
    var prevWord: String? = nil
    var precededByDot = false
    var expectParamList = false
    var inParamList = false
    var paramDepth = 0
    var expectParamName = false

    while i < n {
        let u = units[i]
        if U16.isWS(u) { i += 1; continue }

        // Comment # ...
        if u == U16.hash {
            let end = U16.lineEnd(units, from: i + 1)
            out.emit(i, end, "comment")
            i = end
            continue
        }

        // Module attributes @moduledoc, @doc, @spec, @impl
        if u == U16.at && i + 1 < n && U16.isIdentStart(units[i + 1]) {
            var j = i + 2
            while j < n && U16.isIdentContinue(units[j]) { j += 1 }
            out.emit(i, j, "attribute")
            i = j
            prevWord = nil
            precededByDot = false
            continue
        }

        // Sigils ~r/.../, ~s(...), ~w[...], ~S"""..."""
        if u == U16.tilde && i + 2 < n && U16.isASCIILetter(units[i + 1]) {
            let open = units[i + 2]
            let close: UInt16?
            switch open {
            case U16.slash: close = U16.slash
            case U16.pipe: close = U16.pipe
            case U16.lparen: close = U16.rparen
            case U16.lbracket: close = U16.rbracket
            case U16.lbrace: close = U16.rbrace
            case U16.lt: close = U16.gt
            case U16.quote: close = U16.quote
            case U16.apos: close = U16.apos
            default: close = nil
            }
            if let close {
                let isTriple = (open == U16.quote || open == U16.apos)
                    && i + 4 < n && units[i + 3] == open && units[i + 4] == open
                var end = isTriple
                    ? scanTripleQuotedEnd(units, from: i + 2, delimiter: open, allowEscapes: U16.isASCIILower(units[i + 1]))
                    : scanQuotedEnd(units, from: i + 2, delimiter: close, allowMultiline: true, allowEscapes: U16.isASCIILower(units[i + 1]))
                while end < n && U16.isASCIILetter(units[end]) { end += 1 }
                out.emit(i, end, "string")
                i = end
                prevWord = nil
                precededByDot = false
                continue
            }
        }

        // Triple-quoted heredocs """...""" / '''...'''
        if (u == U16.quote || u == U16.apos) && i + 2 < n && units[i + 1] == u && units[i + 2] == u {
            let end = scanTripleQuotedEnd(units, from: i, delimiter: u)
            emitStringSpan(units, start: i, end: end, contentStart: i + 3, contentEnd: max(i + 3, end - 3), allowEscapes: true, detectURL: false, into: &out)
            i = end
            prevWord = nil
            precededByDot = false
            continue
        }

        // Strings "..." and charlists '...'
        if u == U16.quote || u == U16.apos {
            let end = scanQuotedEnd(units, from: i, delimiter: u, allowMultiline: true)
            emitStringSpan(units, start: i, end: end, contentStart: i + 1, contentEnd: max(i + 1, end - 1), allowEscapes: true, into: &out)
            i = end
            prevWord = nil
            precededByDot = false
            continue
        }

        // Atoms :ok, :error, :my_atom
        if u == U16.colon && i + 1 < n && units[i + 1] != U16.colon && U16.isIdentStart(units[i + 1]) {
            var j = i + 2
            while j < n && (U16.isIdentContinue(units[j]) || units[j] == U16.question || units[j] == U16.bang) { j += 1 }
            out.emit(i, j, "constant.builtin")
            i = j
            prevWord = nil
            precededByDot = false
            continue
        }

        // Numbers
        if U16.isDigit(u) {
            let end = scanNumberLiteral(units, from: i, allowSuffix: false)
            out.emit(i, end, "number")
            i = end
            prevWord = nil
            precededByDot = false
            continue
        }

        // Identifiers
        if U16.isIdentStart(u) {
            var j = i + 1
            while j < n && U16.isIdentContinue(units[j]) { j += 1 }
            if j < n && (units[j] == U16.question || units[j] == U16.bang) { j += 1 }
            let word = U16.slice(units, i, j)
            let isKeywordKey = j < n && units[j] == U16.colon && (j + 1 >= n || units[j + 1] != U16.colon)
            let nextIsCall = j < n && units[j] == U16.lparen

            if isKeywordKey {
                out.emit(i, j, "property")
            } else if word == "true" || word == "false" {
                out.emit(i, j, "boolean")
            } else if word == "nil" {
                out.emit(i, j, "constant.builtin")
            } else if elixirFunctionKeywords.contains(word) && !precededByDot {
                out.emit(i, j, "keyword.function")
                expectParamList = true
            } else if elixirOperatorKeywords.contains(word) && !precededByDot {
                out.emit(i, j, "keyword.operator")
            } else if elixirKeywords.contains(word) && !precededByDot {
                out.emit(i, j, "keyword")
            } else if let prev = prevWord, elixirFunctionKeywords.contains(prev) {
                out.emit(i, j, "function")
                expectParamList = true
            } else if inParamList && paramDepth == 1 && expectParamName && !nextIsCall {
                out.emit(i, j, "variable.parameter")
                expectParamName = false
            } else if nextIsCall {
                out.emit(i, j, precededByDot ? "function.method" : "function")
            } else if U16.isASCIIUpper(u) {
                out.emit(i, j, "type")
            }
            prevWord = word
            precededByDot = false
            i = j
            continue
        }

        if U16.isBracket(u) {
            out.emit(i, i + 1, "punctuation.bracket")
            if u == U16.lparen {
                if expectParamList { inParamList = true; expectParamList = false; paramDepth = 1; expectParamName = true }
                else if inParamList { paramDepth += 1 }
            } else if u == U16.rparen && inParamList {
                paramDepth -= 1
                if paramDepth <= 0 { inParamList = false; expectParamName = false }
            }
            prevWord = nil
            precededByDot = false
            i += 1
            continue
        }

        if U16.isDelimiter(u) {
            out.emit(i, i + 1, "punctuation.delimiter")
            if u == U16.comma && inParamList && paramDepth == 1 { expectParamName = true }
            precededByDot = (u == U16.dot)
            prevWord = nil
            i += 1
            continue
        }

        if U16.isOperatorChar(u) {
            var j = i + 1
            while j < n && U16.isOperatorChar(units[j]) { j += 1 }
            out.emit(i, j, "operator")
            prevWord = nil
            precededByDot = false
            i = j
            continue
        }

        prevWord = nil
        precededByDot = false
        i = U16.step(units, i)
    }

    return out.highlights
}

// MARK: - Nix Lexer

private let nixKeywords: Set<String> = [
    "assert", "else", "if", "in", "inherit", "let", "rec", "then", "with",
]

private func tokenizeNixGrammar(_ units: [UInt16]) -> [SimpleHighlight] {
    let n = units.count
    var out = HighlightBuilder(unitCount: n)
    var i = 0
    var precededByDot = false

    while i < n {
        let u = units[i]
        if U16.isWS(u) { i += 1; continue }

        // Comments # ... and /* ... */
        if u == U16.hash {
            let end = U16.lineEnd(units, from: i + 1)
            out.emit(i, end, "comment")
            i = end
            continue
        }
        if u == U16.slash && i + 1 < n && units[i + 1] == U16.star {
            let end = scanDelimitedComment(units, from: i, open: [U16.slash, U16.star], close: [U16.star, U16.slash], nested: false)
            out.emit(i, end, "comment")
            i = end
            continue
        }

        // Indented multi-line strings '' ... ''
        if u == U16.apos && i + 1 < n && units[i + 1] == U16.apos {
            var j = i + 2
            while j < n {
                if units[j] == U16.apos && j + 1 < n && units[j + 1] == U16.apos {
                    // Escaped ''' or ''$ or ''\x
                    if j + 2 < n && (units[j + 2] == U16.apos || units[j + 2] == U16.dollar || units[j + 2] == U16.backslash) {
                        j += 3
                        continue
                    }
                    j += 2
                    break
                }
                j = U16.step(units, j)
            }
            out.emit(i, j, "string")
            i = j
            precededByDot = false
            continue
        }

        // Double-quoted multi-line strings "..."
        if u == U16.quote {
            let end = scanQuotedEnd(units, from: i, delimiter: U16.quote, allowMultiline: true)
            emitStringSpan(units, start: i, end: end, contentStart: i + 1, contentEnd: max(i + 1, end - 1), allowEscapes: true, into: &out)
            i = end
            precededByDot = false
            continue
        }

        // Bare URLs https://...
        if let urlEnd = U16.scanURL(units, from: i, limit: n) {
            out.emit(i, urlEnd, "string.special.url")
            i = urlEnd
            precededByDot = false
            continue
        }

        // Search path <nixpkgs>
        if u == U16.lt && i + 1 < n && U16.isASCIILetter(units[i + 1]) {
            var j = i + 2
            while j < n && (U16.isIdentContinue(units[j]) || units[j] == U16.slash || units[j] == U16.minus || units[j] == U16.dot) { j += 1 }
            if j < n && units[j] == U16.gt {
                out.emit(i, j + 1, "string")
                i = j + 1
                precededByDot = false
                continue
            }
        }

        // Relative/absolute path literals ./foo/bar.nix or ../foo
        if (u == U16.dot && i + 1 < n && units[i + 1] == U16.slash)
            || (u == U16.dot && i + 2 < n && units[i + 1] == U16.dot && units[i + 2] == U16.slash)
        {
            var j = i
            while j < n && !U16.isWS(units[j]) && units[j] != U16.semi && units[j] != U16.rparen && units[j] != U16.rbrace && units[j] != U16.rbracket {
                j = U16.step(units, j)
            }
            out.emit(i, j, "string")
            i = j
            precededByDot = false
            continue
        }

        // Numbers
        if U16.isDigit(u) {
            let end = scanNumberLiteral(units, from: i, allowSuffix: false)
            out.emit(i, end, "number")
            i = end
            precededByDot = false
            continue
        }

        // Identifiers / keywords / attr keys
        if U16.isIdentStart(u) {
            var j = i + 1
            while j < n && (U16.isIdentContinue(units[j]) || units[j] == U16.minus || units[j] == U16.apos) { j += 1 }
            let word = U16.slice(units, i, j)
            var look = j
            while look < n && U16.isInlineWS(units[look]) { look += 1 }
            let isAssign = look < n && units[look] == U16.eq && (look + 1 >= n || units[look + 1] != U16.eq)
            let isParamColon = look < n && units[look] == U16.colon && (look + 1 >= n || units[look + 1] != U16.colon)

            if word == "true" || word == "false" {
                out.emit(i, j, "boolean")
            } else if word == "null" {
                out.emit(i, j, "constant.builtin")
            } else if word == "or" && !precededByDot {
                out.emit(i, j, "keyword.operator")
            } else if nixKeywords.contains(word) && !precededByDot {
                out.emit(i, j, "keyword")
            } else if word == "import" || word == "builtins" || word == "derivation" || word == "throw" || word == "abort" {
                out.emit(i, j, "function")
            } else if isAssign {
                out.emit(i, j, "property")
            } else if isParamColon {
                out.emit(i, j, "variable.parameter")
            } else if precededByDot {
                out.emit(i, j, "property")
            }
            i = j
            precededByDot = false
            continue
        }

        if U16.isBracket(u) { out.emit(i, i + 1, "punctuation.bracket"); precededByDot = false; i += 1; continue }
        if U16.isDelimiter(u) { out.emit(i, i + 1, "punctuation.delimiter"); precededByDot = (u == U16.dot); i += 1; continue }
        if U16.isOperatorChar(u) {
            var j = i + 1
            while j < n && U16.isOperatorChar(units[j]) {
                if units[j] == U16.slash && j + 1 < n && units[j + 1] == U16.star { break }
                j += 1
            }
            out.emit(i, j, "operator")
            precededByDot = false
            i = j
            continue
        }

        precededByDot = false
        i = U16.step(units, i)
    }

    return out.highlights
}

// MARK: - R Lexer

private let rKeywords: Set<String> = ["if", "else", "repeat", "while", "for", "next", "break"]
private let rBuiltinConstants: Set<String> = [
    "NULL", "NA", "NA_integer_", "NA_real_", "NA_complex_", "NA_character_", "NaN", "Inf", "pi",
]

private func scanRRawString(_ units: [UInt16], from start: Int) -> Int? {
    let n = units.count
    guard start + 3 < n && (units[start] == U16.lowerR || units[start] == U16.upperR) else { return nil }
    let q = units[start + 1]
    guard q == U16.quote || q == U16.apos else { return nil }
    var d = start + 2
    var dashes = 0
    while d < n && units[d] == U16.minus { dashes += 1; d += 1 }
    guard d < n else { return nil }
    let closeDelim: UInt16
    switch units[d] {
    case U16.lparen: closeDelim = U16.rparen
    case U16.lbracket: closeDelim = U16.rbracket
    case U16.lbrace: closeDelim = U16.rbrace
    default: return nil
    }
    var closePattern: [UInt16] = [closeDelim]
    if dashes > 0 { closePattern.append(contentsOf: repeatElement(U16.minus, count: dashes)) }
    closePattern.append(q)
    var i = d + 1
    while i < n {
        if matchUnits(units, at: i, closePattern) { return i + closePattern.count }
        i = U16.step(units, i)
    }
    return n
}

private func tokenizeRGrammar(_ units: [UInt16]) -> [SimpleHighlight] {
    let n = units.count
    var out = HighlightBuilder(unitCount: n)
    var i = 0
    var precededByField = false
    var expectParamList = false
    var inParamList = false
    var paramDepth = 0
    var expectParamName = false

    while i < n {
        let u = units[i]
        if U16.isWS(u) { i += 1; continue }

        // Comment # ...
        if u == U16.hash {
            let end = U16.lineEnd(units, from: i + 1)
            out.emit(i, end, "comment")
            i = end
            continue
        }

        // Raw strings r"(...)" / R"[...]"
        if (u == U16.lowerR || u == U16.upperR), let end = scanRRawString(units, from: i) {
            out.emit(i, end, "string")
            i = end
            precededByField = false
            continue
        }

        // Strings "..." / '...'
        if u == U16.quote || u == U16.apos {
            let end = scanQuotedEnd(units, from: i, delimiter: u, allowMultiline: true)
            emitStringSpan(units, start: i, end: end, contentStart: i + 1, contentEnd: max(i + 1, end - 1), allowEscapes: true, into: &out)
            i = end
            precededByField = false
            continue
        }

        // Special infix operators %in%, %>%, %*%
        if u == U16.percent {
            var j = i + 1
            while j < n && units[j] != U16.percent && !U16.isNewline(units[j]) { j = U16.step(units, j) }
            if j < n && units[j] == U16.percent {
                out.emit(i, j + 1, "operator")
                i = j + 1
                precededByField = false
                continue
            }
        }

        // Numbers (including 42L, 3i)
        if U16.isDigit(u) {
            let end = scanNumberLiteral(units, from: i)
            out.emit(i, end, "number")
            i = end
            precededByField = false
            continue
        }

        // Identifiers (R allows dots in identifiers like `data.frame`, `is.na`)
        if U16.isASCIILetter(u) || u == U16.underscore || (u == U16.dot && i + 1 < n && U16.isASCIILetter(units[i + 1])) {
            var j = i + 1
            while j < n && (U16.isIdentContinue(units[j]) || units[j] == U16.dot) { j += 1 }
            let word = U16.slice(units, i, j)
            let nextIsCall = j < n && units[j] == U16.lparen

            if word == "TRUE" || word == "FALSE" {
                out.emit(i, j, "boolean")
            } else if rBuiltinConstants.contains(word) {
                out.emit(i, j, "constant.builtin")
            } else if word == "function" {
                out.emit(i, j, "keyword.function")
                expectParamList = true
            } else if word == "return" {
                out.emit(i, j, "keyword.return")
            } else if word == "in" {
                out.emit(i, j, "keyword.operator")
            } else if rKeywords.contains(word) {
                out.emit(i, j, "keyword")
            } else if inParamList && paramDepth == 1 && expectParamName && !nextIsCall {
                out.emit(i, j, "variable.parameter")
                expectParamName = false
            } else if nextIsCall {
                out.emit(i, j, "function")
            } else if precededByField {
                out.emit(i, j, "property")
            }
            i = j
            precededByField = false
            continue
        }

        if u == U16.dollar || u == U16.at {
            out.emit(i, i + 1, "operator")
            precededByField = true
            i += 1
            continue
        }

        if U16.isBracket(u) {
            out.emit(i, i + 1, "punctuation.bracket")
            if u == U16.lparen {
                if expectParamList { inParamList = true; expectParamList = false; paramDepth = 1; expectParamName = true }
                else if inParamList { paramDepth += 1 }
            } else if u == U16.rparen && inParamList {
                paramDepth -= 1
                if paramDepth <= 0 { inParamList = false; expectParamName = false }
            }
            precededByField = false
            i += 1
            continue
        }

        if U16.isDelimiter(u) {
            out.emit(i, i + 1, "punctuation.delimiter")
            if u == U16.comma && inParamList && paramDepth == 1 { expectParamName = true }
            precededByField = false
            i += 1
            continue
        }

        if U16.isOperatorChar(u) {
            var j = i + 1
            while j < n && U16.isOperatorChar(units[j]) { j += 1 }
            out.emit(i, j, "operator")
            if inParamList && paramDepth == 1 && u == U16.eq { expectParamName = false }
            precededByField = false
            i = j
            continue
        }

        precededByField = false
        i = U16.step(units, i)
    }

    return out.highlights
}

// MARK: - Makefile Lexer

private let makeDirectives: Set<String> = [
    "include", "-include", "sinclude", "ifeq", "ifneq", "ifdef", "ifndef", "else", "endif",
    "define", "endef", "export", "unexport", "override", "private", "vpath",
    ".PHONY", ".DEFAULT_GOAL", ".SUFFIXES", ".PRECIOUS", ".SILENT", ".DELETE_ON_ERROR",
]

private let makeBuiltinFunctions: Set<String> = [
    "subst", "patsubst", "strip", "findstring", "filter", "filter-out", "sort", "word",
    "wordlist", "words", "firstword", "lastword", "dir", "notdir", "suffix", "basename",
    "addsuffix", "addprefix", "join", "wildcard", "realpath", "abspath", "if", "or", "and",
    "foreach", "file", "call", "value", "eval", "origin", "flavor", "shell", "error", "warning",
    "info",
]

private func scanMakeVariableRef(_ units: [UInt16], from start: Int, limit: Int, into out: inout HighlightBuilder) -> Int {
    guard start + 1 < limit && units[start] == U16.dollar else { return start + 1 }
    let next = units[start + 1]
    if next == U16.lparen || next == U16.lbrace {
        let close: UInt16 = (next == U16.lparen) ? U16.rparen : U16.rbrace
        out.emit(start, start + 2, "punctuation.bracket")
        var cur = start + 2
        let wordStart = cur
        while cur < limit && (U16.isIdentContinue(units[cur]) || units[cur] == U16.minus) { cur += 1 }
        let word = U16.slice(units, wordStart, cur)
        if cur > wordStart && cur < limit && U16.isInlineWS(units[cur]) && makeBuiltinFunctions.contains(word) {
            out.emit(wordStart, cur, "function")
        } else if cur > wordStart {
            out.emit(wordStart, cur, "constant.builtin")
        }
        var depth = 1
        while cur < limit && depth > 0 {
            if units[cur] == next { depth += 1; cur += 1 }
            else if units[cur] == close {
                depth -= 1
                if depth == 0 {
                    out.emit(cur, cur + 1, "punctuation.bracket")
                    return cur + 1
                }
                cur += 1
            } else if units[cur] == U16.dollar {
                cur = scanMakeVariableRef(units, from: cur, limit: limit, into: &out)
            } else {
                cur = U16.step(units, cur)
            }
        }
        return cur
    }
    // Automatic variable $@, $<, $^, $*, $?, $+, $$
    out.emit(start, start + 2, "constant.builtin")
    return start + 2
}

private func tokenizeMakeGrammar(_ units: [UInt16]) -> [SimpleHighlight] {
    let n = units.count
    var out = HighlightBuilder(unitCount: n)
    var i = 0

    while i < n {
        let lineStart = i
        let lineEnd = U16.lineEnd(units, from: lineStart)
        let nextLine = U16.nextLineStart(units, after: lineEnd)

        guard lineStart < lineEnd else { i = nextLine; continue }

        // Recipe line (indented with leading tab)
        if units[lineStart] == U16.tab {
            var cur = lineStart + 1
            while cur < lineEnd && (U16.isInlineWS(units[cur]) || units[cur] == U16.at || units[cur] == U16.minus) {
                if units[cur] == U16.at || units[cur] == U16.minus { out.emit(cur, cur + 1, "operator") }
                cur += 1
            }
            var atCmd = true
            while cur < lineEnd {
                let c = units[cur]
                if U16.isInlineWS(c) { cur += 1; continue }
                if c == U16.hash { out.emit(cur, lineEnd, "comment"); break }
                if c == U16.dollar {
                    cur = scanMakeVariableRef(units, from: cur, limit: lineEnd, into: &out)
                    atCmd = false
                    continue
                }
                if c == U16.quote || c == U16.apos {
                    let sEnd = min(lineEnd, scanQuotedEnd(units, from: cur, delimiter: c, allowMultiline: false, allowEscapes: c == U16.quote))
                    emitStringSpan(units, start: cur, end: sEnd, contentStart: cur + 1, contentEnd: max(cur + 1, sEnd - 1), allowEscapes: c == U16.quote, into: &out)
                    cur = sEnd
                    atCmd = false
                    continue
                }
                if atCmd && U16.isIdentStart(c) {
                    var j = cur + 1
                    while j < lineEnd && (U16.isIdentContinue(units[j]) || units[j] == U16.minus || units[j] == U16.slash) { j += 1 }
                    out.emit(cur, j, "function")
                    cur = j
                    atCmd = false
                    continue
                }
                if c == U16.semi || c == U16.pipe || c == U16.amp {
                    out.emit(cur, cur + 1, "operator")
                    atCmd = true
                    cur += 1
                    continue
                }
                cur = U16.step(units, cur)
            }
            i = nextLine
            continue
        }

        var cur = lineStart
        while cur < lineEnd && U16.isInlineWS(units[cur]) { cur += 1 }
        guard cur < lineEnd else { i = nextLine; continue }

        // Comment # ...
        if units[cur] == U16.hash {
            out.emit(cur, lineEnd, "comment")
            i = nextLine
            continue
        }

        // Check leading word for directive, variable assignment, or rule target
        let wordStart = cur
        var w = cur
        while w < lineEnd && !U16.isWS(units[w]) && units[w] != U16.colon && units[w] != U16.eq && units[w] != U16.plus && units[w] != U16.question {
            w = U16.step(units, w)
        }
        let firstWord = U16.slice(units, wordStart, w)
        var afterWord = w
        while afterWord < lineEnd && U16.isInlineWS(units[afterWord]) { afterWord += 1 }

        if makeDirectives.contains(firstWord) {
            out.emit(wordStart, w, "keyword")
            cur = w
        } else if afterWord < lineEnd && (units[afterWord] == U16.eq
            || ((units[afterWord] == U16.colon || units[afterWord] == U16.plus || units[afterWord] == U16.question)
                && afterWord + 1 < lineEnd && units[afterWord + 1] == U16.eq))
        {
            out.emit(wordStart, w, "property")
            let opLen = (units[afterWord] == U16.eq) ? 1 : 2
            out.emit(afterWord, afterWord + opLen, "operator")
            cur = afterWord + opLen
        } else if afterWord < lineEnd && units[afterWord] == U16.colon {
            out.emit(wordStart, w, "function")
            let opLen = (afterWord + 1 < lineEnd && units[afterWord + 1] == U16.colon) ? 2 : 1
            out.emit(afterWord, afterWord + opLen, "operator")
            cur = afterWord + opLen
        }

        // Scan remainder of line for variable references, strings, comments, numbers
        while cur < lineEnd {
            let c = units[cur]
            if U16.isInlineWS(c) { cur += 1; continue }
            if c == U16.hash { out.emit(cur, lineEnd, "comment"); break }
            if c == U16.dollar {
                cur = scanMakeVariableRef(units, from: cur, limit: lineEnd, into: &out)
                continue
            }
            if c == U16.quote || c == U16.apos {
                let sEnd = min(lineEnd, scanQuotedEnd(units, from: cur, delimiter: c, allowMultiline: false, allowEscapes: c == U16.quote))
                emitStringSpan(units, start: cur, end: sEnd, contentStart: cur + 1, contentEnd: max(cur + 1, sEnd - 1), allowEscapes: c == U16.quote, into: &out)
                cur = sEnd
                continue
            }
            if U16.isBracket(c) { out.emit(cur, cur + 1, "punctuation.bracket"); cur += 1; continue }
            cur = U16.step(units, cur)
        }

        i = nextLine
    }

    return out.highlights
}

// MARK: - Vimscript Lexer

private let vimFunctionKeywords: Set<String> = [
    "function", "function!", "func", "func!", "fun", "fun!", "def", "def!",
    "endfunction", "endfunc", "endfun", "enddef",
]

private let vimKeywords: Set<String> = [
    "au", "autocmd", "augroup", "break", "call", "catch", "class", "command", "const",
    "continue", "echo", "echohl", "echom", "else", "elseif", "endclass", "endfor", "endif",
    "endtry", "endwhile", "execute", "export", "finally", "for", "hi", "highlight", "if",
    "imap", "import", "in", "inoremap", "let", "map", "nmap", "nnoremap", "normal", "plug",
    "runtime", "set", "setlocal", "silent", "source", "syn", "syntax", "throw", "try",
    "unlet", "unmap", "var", "vim9script", "vmap", "vnoremap", "while",
]

private func tokenizeVimGrammar(_ units: [UInt16]) -> [SimpleHighlight] {
    let n = units.count
    var out = HighlightBuilder(unitCount: n)
    var i = 0
    var atCommandStart = true
    var prevWord: String? = nil

    while i < n {
        let u = units[i]
        if U16.isNewline(u) {
            i = U16.nextLineStart(units, after: i)
            atCommandStart = true
            prevWord = nil
            continue
        }
        if U16.isInlineWS(u) { i += 1; continue }

        // Vimscript line comment `"` at command start OR Vim9 `#` comment
        if (atCommandStart && u == U16.quote) || (atCommandStart && u == U16.hash) {
            let end = U16.lineEnd(units, from: i + 1)
            out.emit(i, end, "comment")
            i = end
            continue
        }

        // Strings '...' (doubled '' escape) / "..." (backslash escape)
        if u == U16.apos || u == U16.quote {
            let isSingle = (u == U16.apos)
            let end = scanQuotedEnd(units, from: i, delimiter: u, allowMultiline: false, allowEscapes: !isSingle, doubledQuoteEscape: isSingle)
            emitStringSpan(units, start: i, end: end, contentStart: i + 1, contentEnd: max(i + 1, end - 1), allowEscapes: !isSingle, into: &out)
            i = end
            atCommandStart = false
            prevWord = nil
            continue
        }

        // Options &number, &shiftwidth and env vars $HOME
        if (u == U16.amp || u == U16.dollar) && i + 1 < n && U16.isIdentStart(units[i + 1]) {
            var j = i + 2
            while j < n && U16.isIdentContinue(units[j]) { j += 1 }
            out.emit(i, j, u == U16.amp ? "property" : "constant.builtin")
            i = j
            atCommandStart = false
            prevWord = nil
            continue
        }

        // Numbers
        if U16.isDigit(u) {
            let end = scanNumberLiteral(units, from: i, allowSuffix: false)
            out.emit(i, end, "number")
            i = end
            atCommandStart = false
            prevWord = nil
            continue
        }

        // Identifiers / scoped variables (g:foo, s:bar, v:true, a:arg) / commands
        if U16.isIdentStart(u) {
            var j = i + 1
            while j < n && (U16.isIdentContinue(units[j]) || units[j] == U16.colon) { j += 1 }
            if j < n && units[j] == U16.bang { j += 1 }
            let word = U16.slice(units, i, j)
            let nextIsCall = j < n && units[j] == U16.lparen

            if word == "true" || word == "false" || word == "v:true" || word == "v:false" {
                out.emit(i, j, "boolean")
            } else if word == "v:null" || word == "v:none" {
                out.emit(i, j, "constant.builtin")
            } else if vimFunctionKeywords.contains(word) {
                out.emit(i, j, "keyword.function")
            } else if word == "return" {
                out.emit(i, j, "keyword.return")
            } else if atCommandStart && vimKeywords.contains(word) {
                out.emit(i, j, "keyword")
            } else if let prev = prevWord, vimFunctionKeywords.contains(prev) {
                out.emit(i, j, "function")
            } else if nextIsCall {
                out.emit(i, j, "function")
            } else if word.hasPrefix("a:") {
                out.emit(i, j, "variable.parameter")
            } else if word.contains(":") {
                out.emit(i, j, "property")
            }
            prevWord = word
            atCommandStart = false
            i = j
            continue
        }

        if u == U16.pipe {
            out.emit(i, i + 1, "operator")
            atCommandStart = true
            prevWord = nil
            i += 1
            continue
        }
        if U16.isBracket(u) { out.emit(i, i + 1, "punctuation.bracket"); atCommandStart = false; prevWord = nil; i += 1; continue }
        if U16.isDelimiter(u) { out.emit(i, i + 1, "punctuation.delimiter"); atCommandStart = false; prevWord = nil; i += 1; continue }
        if U16.isOperatorChar(u) {
            var j = i + 1
            while j < n && U16.isOperatorChar(units[j]) { j += 1 }
            out.emit(i, j, "operator")
            atCommandStart = false
            prevWord = nil
            i = j
            continue
        }

        atCommandStart = false
        prevWord = nil
        i = U16.step(units, i)
    }

    return out.highlights
}

// MARK: - Stateful Markdown & Markdown Inline Lexers (with Conceal Captures)

private func emitMarkdownInlineSpan(
    _ units: [UInt16],
    start: Int,
    end: Int,
    into out: inout HighlightBuilder
) {
    var cursor = start
    while cursor < end {
        let u = units[cursor]

        // Backslash escape: \*, \[, \\
        if u == U16.backslash && cursor + 1 < end {
            let escEnd = U16.step(units, cursor + 1)
            out.emit(cursor, escEnd, "string.escape")
            cursor = escEnd
            continue
        }

        // Inline code `...` (matched backtick run)
        if u == U16.backtick {
            var ticks = 0
            var k = cursor
            while k < end && units[k] == U16.backtick { ticks += 1; k += 1 }
            var search = k
            var closeEnd: Int? = nil
            while search < end {
                if units[search] == U16.backtick {
                    var closeCount = 0
                    var m = search
                    while m < end && units[m] == U16.backtick { closeCount += 1; m += 1 }
                    if closeCount == ticks { closeEnd = m; break }
                    search = m
                } else {
                    search = U16.step(units, search)
                }
            }
            if let cEnd = closeEnd {
                out.emit(cursor, cEnd, "markup.raw")
                cursor = cEnd
                continue
            }
            cursor = k
            continue
        }

        // Image link ![alt](url) with conceal captures
        if u == U16.bang && cursor + 1 < end && units[cursor + 1] == U16.lbracket {
            if let next = tryEmitMarkdownLink(units, from: cursor, limit: end, isImage: true, into: &out) {
                cursor = next
                continue
            }
        }

        // Inline link [label](url) with conceal captures matching markdown_inline/highlights.scm
        if u == U16.lbracket {
            if let next = tryEmitMarkdownLink(units, from: cursor, limit: end, isImage: false, into: &out) {
                cursor = next
                continue
            }
        }

        // Autolink <https://...> with conceal on angle brackets
        if u == U16.lt && cursor + 1 < end {
            if let urlEnd = U16.scanURL(units, from: cursor + 1, limit: end), urlEnd < end && units[urlEnd] == U16.gt {
                let inlineConceal = HighlightMeta(isInjection: true, injectionLang: "markdown_inline", conceal: "")
                out.emit(cursor, cursor + 1, "conceal", meta: inlineConceal)
                out.emit(cursor + 1, urlEnd, "markup.link.url")
                out.emit(urlEnd, urlEnd + 1, "conceal", meta: inlineConceal)
                cursor = urlEnd + 1
                continue
            }
        }

        // Bare URL https://...
        if let urlEnd = U16.scanURL(units, from: cursor, limit: end) {
            out.emit(cursor, urlEnd, "string.special.url")
            cursor = urlEnd
            continue
        }

        // Strikethrough ~~text~~ with conceal captures
        if u == U16.tilde && cursor + 1 < end && units[cursor + 1] == U16.tilde {
            if let closeIdx = findInlineDelimiter(units, from: cursor + 2, limit: end, char: U16.tilde, count: 2),
               closeIdx > cursor + 2
            {
                let inlineConceal = HighlightMeta(isInjection: true, injectionLang: "markdown_inline", conceal: "")
                out.emit(cursor, cursor + 2, "conceal", meta: inlineConceal)
                out.emit(cursor + 2, closeIdx, "markup.strikethrough")
                out.emit(closeIdx, closeIdx + 2, "conceal", meta: inlineConceal)
                cursor = closeIdx + 2
                continue
            }
        }

        // Strong emphasis **text** or __text__ with conceal captures
        if (u == U16.star || u == U16.underscore) && cursor + 1 < end && units[cursor + 1] == u {
            if let closeIdx = findInlineDelimiter(units, from: cursor + 2, limit: end, char: u, count: 2),
               closeIdx > cursor + 2
            {
                let inlineConceal = HighlightMeta(isInjection: true, injectionLang: "markdown_inline", conceal: "")
                out.emit(cursor, cursor + 2, "conceal", meta: inlineConceal)
                out.emit(cursor + 2, closeIdx, "markup.strong")
                out.emit(closeIdx, closeIdx + 2, "conceal", meta: inlineConceal)
                cursor = closeIdx + 2
                continue
            }
        }

        // Italic emphasis *text* or _text_ with conceal captures
        if (u == U16.star || u == U16.underscore)
            && cursor + 1 < end
            && !U16.isInlineWS(units[cursor + 1])
            && (u != U16.underscore || cursor == start || U16.isWS(units[cursor - 1]))
        {
            if let closeIdx = findInlineDelimiter(units, from: cursor + 1, limit: end, char: u, count: 1),
               closeIdx > cursor + 1
            {
                let inlineConceal = HighlightMeta(isInjection: true, injectionLang: "markdown_inline", conceal: "")
                out.emit(cursor, cursor + 1, "conceal", meta: inlineConceal)
                out.emit(cursor + 1, closeIdx, "markup.italic")
                out.emit(closeIdx, closeIdx + 1, "conceal", meta: inlineConceal)
                cursor = closeIdx + 1
                continue
            }
        }

        // Pipe table cell separator
        if u == U16.pipe {
            out.emit(cursor, cursor + 1, "punctuation.special")
            cursor += 1
            continue
        }

        // HTML entities (&amp;, &lt;, &gt;, &quot;, &nbsp;)
        if u == U16.amp {
            var j = cursor + 1
            while j < end && U16.isASCIILetter(units[j]) && j - cursor < 10 { j += 1 }
            if j > cursor + 1 && j < end && units[j] == U16.semi {
                let entity = U16.slice(units, cursor, j + 1)
                let concealVal: String?
                switch entity {
                case "&nbsp;": concealVal = ""
                case "&lt;": concealVal = "<"
                case "&gt;": concealVal = ">"
                case "&amp;": concealVal = "&"
                case "&quot;": concealVal = "\""
                default: concealVal = nil
                }
                if let concealVal {
                    out.emit(cursor, j + 1, "string.escape", meta: HighlightMeta(conceal: concealVal))
                    cursor = j + 1
                    continue
                }
            }
        }

        cursor = U16.step(units, cursor)
    }
}

private func findInlineDelimiter(
    _ units: [UInt16],
    from start: Int,
    limit: Int,
    char: UInt16,
    count: Int
) -> Int? {
    var i = start
    while i + count <= limit {
        if units[i] == U16.backslash {
            i += 1
            if i < limit { i = U16.step(units, i) }
            continue
        }
        if units[i] == char {
            var run = 0
            while i + run < limit && units[i + run] == char { run += 1 }
            let boundaryOK = (char != U16.underscore)
                || (i + run == limit || !U16.isIdentContinue(units[i + run]))
            if run == count && i > start && !U16.isInlineWS(units[i - 1]) && boundaryOK {
                return i
            }
            i += run
            continue
        }
        i = U16.step(units, i)
    }
    return nil
}

private func tryEmitMarkdownLink(
    _ units: [UInt16],
    from start: Int,
    limit: Int,
    isImage: Bool,
    into out: inout HighlightBuilder
) -> Int? {
    let bracketOpen = isImage ? start + 1 : start
    var closeBracket = bracketOpen + 1
    while closeBracket < limit && units[closeBracket] != U16.rbracket {
        if units[closeBracket] == U16.backslash && closeBracket + 1 < limit {
            closeBracket = U16.step(units, closeBracket + 1)
            continue
        }
        closeBracket = U16.step(units, closeBracket)
    }
    guard closeBracket + 1 < limit
        && units[closeBracket] == U16.rbracket
        && units[closeBracket + 1] == U16.lparen
    else { return nil }

    let urlStart = closeBracket + 2
    var closeParen = urlStart
    var parenDepth = 1
    while closeParen < limit && parenDepth > 0 {
        if units[closeParen] == U16.lparen { parenDepth += 1 }
        else if units[closeParen] == U16.rparen {
            parenDepth -= 1
            if parenDepth == 0 { break }
        }
        closeParen = U16.step(units, closeParen)
    }
    guard closeParen < limit && units[closeParen] == U16.rparen else { return nil }

    // Emit strictly non-overlapping upstream markdown_inline conceal & link scopes
    let inlineConceal = HighlightMeta(isInjection: true, injectionLang: "markdown_inline", conceal: "")
    let spaceConceal = HighlightMeta(isInjection: true, injectionLang: "markdown_inline", conceal: " ")
    out.emit(start, bracketOpen + 1, "conceal", meta: inlineConceal)
    if bracketOpen + 1 < closeBracket {
        out.emit(bracketOpen + 1, closeBracket, "markup.link.label")
    }
    if isImage {
        out.emit(closeBracket, closeParen + 1, "conceal", meta: inlineConceal)
    } else {
        out.emit(closeBracket, closeBracket + 1, "conceal", meta: spaceConceal)
        out.emit(closeBracket + 1, urlStart, "conceal", meta: inlineConceal)
        if urlStart < closeParen {
            out.emit(urlStart, closeParen, "markup.link.url")
        }
        out.emit(closeParen, closeParen + 1, "conceal", meta: inlineConceal)
    }
    return closeParen + 1
}

private func tokenizeMarkdownInlineGrammar(_ units: [UInt16]) -> [SimpleHighlight] {
    var out = HighlightBuilder(unitCount: units.count)
    emitMarkdownInlineSpan(units, start: 0, end: units.count, into: &out)
    return out.highlights
}

private func tokenizeMarkdownGrammar(_ units: [UInt16]) -> [SimpleHighlight] {
    let n = units.count
    var out = HighlightBuilder(unitCount: n)
    var i = 0
    var inFence = false
    var fenceChar: UInt16 = 0
    var fenceLen = 0

    while i < n {
        let lineStart = i
        let lineEnd = U16.lineEnd(units, from: lineStart)
        let nextLine = U16.nextLineStart(units, after: lineEnd)

        var lead = lineStart
        var spaces = 0
        while lead < lineEnd && units[lead] == U16.space && spaces < 3 {
            lead += 1
            spaces += 1
        }

        // Opening / closing code fences (``` or ~~~) with conceal_lines metadata matching markdown/highlights.scm
        if lead < lineEnd && (units[lead] == U16.backtick || units[lead] == U16.tilde) {
            let ch = units[lead]
            var count = 0
            var k = lead
            while k < lineEnd && units[k] == ch { count += 1; k += 1 }
            if count >= 3 {
                if !inFence {
                    inFence = true
                    fenceChar = ch
                    fenceLen = count
                    if lineStart < lineEnd {
                        out.emit(lineStart, lineEnd, "markup.raw", meta: HighlightMeta(conceal: "", concealLines: ""))
                    }
                    i = nextLine
                    continue
                } else if ch == fenceChar && count >= fenceLen {
                    var rest = k
                    while rest < lineEnd && U16.isInlineWS(units[rest]) { rest += 1 }
                    if rest == lineEnd {
                        inFence = false
                        if lineStart < lineEnd {
                            out.emit(lineStart, lineEnd, "markup.raw", meta: HighlightMeta(conceal: "", concealLines: ""))
                        }
                        i = nextLine
                        continue
                    }
                }
            }
        }

        if inFence {
            if lineStart < lineEnd {
                out.emit(lineStart, lineEnd, "markup.raw")
            }
            i = nextLine
            continue
        }

        // ATX Headings: # .. ######
        if lead < lineEnd && units[lead] == U16.hash {
            var hashes = 0
            var k = lead
            while k < lineEnd && units[k] == U16.hash && hashes < 7 { hashes += 1; k += 1 }
            if hashes >= 1 && hashes <= 6 && (k == lineEnd || U16.isInlineWS(units[k])) {
                out.emit(lead, lineEnd, "markup.heading")
                i = nextLine
                continue
            }
        }

        // Thematic break: --- / *** / ___
        if lead + 2 < lineEnd && (units[lead] == U16.minus || units[lead] == U16.star || units[lead] == U16.underscore) {
            let marker = units[lead]
            var count = 0
            var ok = true
            var k = lead
            while k < lineEnd {
                if units[k] == marker { count += 1 }
                else if !U16.isInlineWS(units[k]) { ok = false; break }
                k += 1
            }
            if ok && count >= 3 {
                out.emit(lead, lineEnd, "punctuation.special")
                i = nextLine
                continue
            }
        }

        // Blockquotes: > ...
        if lead < lineEnd && units[lead] == U16.gt {
            out.emit(lead, lineEnd, "markup.quote")
            i = nextLine
            continue
        }

        // Bullet / task list markers: - , * , + , 1. , - [x] , - [ ]
        var contentStart = lineStart
        if lead + 1 < lineEnd && (units[lead] == U16.minus || units[lead] == U16.star || units[lead] == U16.plus) && U16.isInlineWS(units[lead + 1]) {
            out.emit(lead, lead + 1, "markup.list")
            contentStart = lead + 2
            if contentStart + 2 < lineEnd
                && units[contentStart] == U16.lbracket
                && units[contentStart + 2] == U16.rbracket
                && (units[contentStart + 1] == U16.space || units[contentStart + 1] == U16.lowerX || units[contentStart + 1] == U16.upperX)
            {
                let checked = (units[contentStart + 1] != U16.space)
                out.emit(contentStart, contentStart + 3, checked ? "markup.list.checked" : "markup.list.unchecked")
                contentStart += 3
            }
        } else if lead < lineEnd && U16.isDigit(units[lead]) {
            var d = lead
            while d < lineEnd && U16.isDigit(units[d]) { d += 1 }
            if d + 1 < lineEnd && (units[d] == U16.dot || units[d] == U16.rparen) && U16.isInlineWS(units[d + 1]) {
                out.emit(lead, d + 1, "markup.list")
                contentStart = d + 2
            }
        }

        emitMarkdownInlineSpan(units, start: contentStart, end: lineEnd, into: &out)
        i = nextLine
    }

    return out.highlights
}

// MARK: - Unified & Context Diff Lexer

private func tokenizeDiffGrammar(_ units: [UInt16]) -> [SimpleHighlight] {
    let n = units.count
    var out = HighlightBuilder(unitCount: n)
    var i = 0

    while i < n {
        let lineStart = i
        let lineEnd = U16.lineEnd(units, from: lineStart)
        let nextLine = U16.nextLineStart(units, after: lineEnd)

        if lineStart < lineEnd {
            let first = units[lineStart]
            if U16.matchesASCII(units, at: lineStart, limit: lineEnd, "@@") {
                out.emit(lineStart, lineEnd, "markup.heading")
            } else if U16.matchesASCII(units, at: lineStart, limit: lineEnd, "+++ ")
                || U16.matchesASCII(units, at: lineStart, limit: lineEnd, "--- ")
                || U16.matchesASCII(units, at: lineStart, limit: lineEnd, "diff --git ")
                || U16.matchesASCII(units, at: lineStart, limit: lineEnd, "index ")
                || U16.matchesASCII(units, at: lineStart, limit: lineEnd, "new file mode ")
                || U16.matchesASCII(units, at: lineStart, limit: lineEnd, "deleted file mode ")
                || U16.matchesASCII(units, at: lineStart, limit: lineEnd, "rename from ")
                || U16.matchesASCII(units, at: lineStart, limit: lineEnd, "rename to ")
                || U16.matchesASCII(units, at: lineStart, limit: lineEnd, "similarity index ")
            {
                out.emit(lineStart, lineEnd, "comment")
            } else if first == U16.bang
                || U16.matchesASCII(units, at: lineStart, limit: lineEnd, "*** ")
                || U16.matchesASCII(units, at: lineStart, limit: lineEnd, "===")
                || U16.matchesASCII(units, at: lineStart, limit: lineEnd, "Binary files ")
            {
                out.emit(lineStart, lineEnd, "diff.delta")
            } else if first == U16.plus {
                out.emit(lineStart, lineEnd, "diff.plus")
            } else if first == U16.minus {
                out.emit(lineStart, lineEnd, "diff.minus")
            }
        }

        i = nextLine
    }

    return out.highlights
}

