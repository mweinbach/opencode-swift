import Synchronization

// MARK: - Filetype Resolution (`core/src/lib/tree-sitter/resolve-ft.ts`)

/// Mapping of lowercase file extensions (without leading dot) to canonical syntax filetype identifiers.
// parity: core/src/lib/tree-sitter/resolve-ft.ts#extensionToFiletype [status=implemented hash=38a0aa12d8e7]
public let extensionToFiletype: [String: String] = [
    "astro": "astro",
    "bash": "bash",
    "c": "c",
    "cc": "cpp",
    "cjs": "javascript",
    "clj": "clojure",
    "cljs": "clojure",
    "cljc": "clojure",
    "cpp": "cpp",
    "cxx": "cpp",
    "cs": "csharp",
    "cts": "typescript",
    "ctsx": "typescriptreact",
    "dart": "dart",
    "diff": "diff",
    "edn": "clojure",
    "go": "go",
    "gemspec": "ruby",
    "groovy": "groovy",
    "h": "c",
    "handlebars": "handlebars",
    "hbs": "handlebars",
    "hpp": "cpp",
    "hxx": "cpp",
    "h++": "cpp",
    "hh": "cpp",
    "hrl": "erlang",
    "hs": "haskell",
    "htm": "html",
    "html": "html",
    "ini": "ini",
    "js": "javascript",
    "jsx": "javascriptreact",
    "jl": "julia",
    "json": "json",
    "ksh": "bash",
    "kt": "kotlin",
    "kts": "kotlin",
    "latex": "latex",
    "less": "less",
    "lua": "lua",
    "markdown": "markdown",
    "md": "markdown",
    "mdown": "markdown",
    "mkd": "markdown",
    "mjs": "javascript",
    "ml": "ocaml",
    "mli": "ocaml",
    "mts": "typescript",
    "mtsx": "typescriptreact",
    "patch": "diff",
    "php": "php",
    "pl": "perl",
    "pm": "perl",
    "ps1": "powershell",
    "psm1": "powershell",
    "py": "python",
    "pyi": "python",
    "r": "r",
    "rb": "ruby",
    "rake": "ruby",
    "rs": "rust",
    "ru": "ruby",
    "sass": "sass",
    "sc": "scala",
    "scala": "scala",
    "scss": "scss",
    "sh": "bash",
    "sql": "sql",
    "svelte": "svelte",
    "swift": "swift",
    "ts": "typescript",
    "tsx": "typescriptreact",
    "tex": "latex",
    "toml": "toml",
    "vue": "vue",
    "vim": "vim",
    "xml": "xml",
    "xsl": "xsl",
    "yaml": "yaml",
    "yml": "yaml",
    "zig": "zig",
    "zon": "zig",
    "zsh": "bash",
    "c++": "cpp",
    "erl": "erlang",
    "exs": "elixir",
    "ex": "elixir",
    "elm": "elm",
    "fsharp": "fsharp",
    "fs": "fsharp",
    "fsx": "fsharp",
    "fsscript": "fsharp",
    "fsi": "fsharp",
    "java": "java",
    "css": "css",
]

/// Mapping of lowercase file basenames (including dotfiles and extensionless build files)
/// to canonical syntax filetype identifiers.
// parity: core/src/lib/tree-sitter/resolve-ft.ts#basenameToFiletype [status=implemented hash=3c3365524472]
public let basenameToFiletype: [String: String] = [
    ".bash_aliases": "bash",
    ".bash_logout": "bash",
    ".bash_profile": "bash",
    ".bashrc": "bash",
    ".kshrc": "bash",
    ".profile": "bash",
    ".vimrc": "vim",
    ".zlogin": "bash",
    ".zlogout": "bash",
    ".zprofile": "bash",
    ".zshenv": "bash",
    ".zshrc": "bash",
    "appfile": "ruby",
    "berksfile": "ruby",
    "brewfile": "ruby",
    "cheffile": "ruby",
    "containerfile": "dockerfile",
    "dockerfile": "dockerfile",
    "fastfile": "ruby",
    "gemfile": "ruby",
    "gnumakefile": "make",
    "gvimrc": "vim",
    "guardfile": "ruby",
    "makefile": "make",
    "podfile": "ruby",
    "rakefile": "ruby",
    "thorfile": "ruby",
    "vagrantfile": "ruby",
]

private func trimFiletypeWhitespace(_ value: String) -> Substring {
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

private func normalizeFiletypeToken(_ value: String) -> String? {
    var trimmed = trimFiletypeWhitespace(value)
    if trimmed.first == "." {
        trimmed = trimmed.dropFirst()
    }
    guard !trimmed.isEmpty else { return nil }
    return String(trimmed).lowercased()
}

private func posixBasename(_ value: String) -> String? {
    let trimmed = trimFiletypeWhitespace(value)
    guard !trimmed.isEmpty else { return nil }

    let normalized = String(trimmed.map { $0 == "\\" ? Character("/") : $0 })
    var end = normalized.endIndex
    while end > normalized.startIndex {
        let prev = normalized.index(before: end)
        if normalized[prev] == "/" {
            end = prev
        } else {
            break
        }
    }
    guard end > normalized.startIndex else { return nil }

    var start = end
    while start > normalized.startIndex {
        let prev = normalized.index(before: start)
        if normalized[prev] == "/" {
            break
        }
        start = prev
    }

    let basename = normalized[start..<end].lowercased()
    return basename.isEmpty ? nil : basename
}

/// Resolves a file extension (with or without leading `.`) to its canonical filetype identifier.
// parity: core/src/lib/tree-sitter/resolve-ft.ts#extToFiletype [status=implemented hash=62007dba4c3c]
public func extToFiletype(_ extension: String) -> String? {
    guard let normalizedExtension = normalizeFiletypeToken(`extension`) else { return nil }
    return extensionToFiletype[normalizedExtension]
}

/// Resolves a file path or filename (POSIX or Windows separators) to its canonical filetype identifier.
// parity: core/src/lib/tree-sitter/resolve-ft.ts#pathToFiletype [status=implemented hash=d51ee30e0f1f]
public func pathToFiletype(_ path: String) -> String? {
    guard let basename = posixBasename(path) else { return nil }

    if let basenameFiletype = basenameToFiletype[basename] {
        return basenameFiletype
    }

    guard let lastDot = basename.lastIndex(of: ".") else {
        return nil
    }
    let afterDot = basename.index(after: lastDot)
    guard afterDot < basename.endIndex else {
        return nil
    }

    let ext = String(basename[afterDot...])
    return extToFiletype(ext)
}

/// Normalizes a Markdown fenced code block info string (e.g. `"TSX title=Button.tsx"`, `".jsx"`, `"Dockerfile"`)
/// into a canonical filetype identifier.
// parity: core/src/lib/tree-sitter/resolve-ft.ts#infoStringToFiletype [status=implemented hash=e33465b6285c]
public func infoStringToFiletype(_ infoString: String) -> String? {
    let trimmed = trimFiletypeWhitespace(infoString)
    guard !trimmed.isEmpty else { return nil }

    var tokenEnd = trimmed.startIndex
    while tokenEnd < trimmed.endIndex, !trimmed[tokenEnd].isWhitespace {
        tokenEnd = trimmed.index(after: tokenEnd)
    }
    let token = String(trimmed[..<tokenEnd])

    if let directBasenameMatch = basenameToFiletype[token.lowercased()] {
        return directBasenameMatch
    }

    guard let normalizedToken = normalizeFiletypeToken(token) else { return nil }

    return basenameToFiletype[normalizedToken]
        ?? pathToFiletype(normalizedToken)
        ?? extToFiletype(normalizedToken)
        ?? normalizedToken
}

/// Convenience resolver accepting a file path, basename, extension, or Markdown fence info string.
public func resolveFiletype(_ input: String) -> String? {
    let trimmed = trimFiletypeWhitespace(input)
    guard !trimmed.isEmpty else { return nil }

    let value = String(trimmed)
    if value.contains("/") || value.contains("\\") {
        return pathToFiletype(value)
    }
    if value.contains(where: \.isWhitespace) {
        return infoStringToFiletype(value)
    }
    return pathToFiletype(value)
        ?? extToFiletype(value)
        ?? infoStringToFiletype(value)
}

// MARK: - Syntax Highlighter Abstraction

/// Result returned by a `SyntaxHighlighter` containing UTF-16 `SimpleHighlight` ranges
/// and an optional non-fatal diagnostic warning.
public struct SyntaxHighlightResult: Equatable, Hashable, Sendable, Codable {
    public var highlights: [SimpleHighlight]
    public var warning: String?

    public init(highlights: [SimpleHighlight] = [], warning: String? = nil) {
        self.highlights = highlights
        self.warning = warning
    }
}

/// Pluggable syntax highlighting seam consumable by code, diff, and markdown renderables.
/// Both pure-Swift lexical highlighters (`BuiltInSyntaxHighlighter`) and external
/// asynchronous tree-sitter engines conform cleanly to this protocol.
public protocol SyntaxHighlighter: Sendable {
    /// Synchronously highlights `content` for `filetype` using UTF-16 code-unit highlight offsets.
    func highlight(content: String, filetype: String) -> SyntaxHighlightResult

    /// Asynchronously highlights `content` once for `filetype`, matching tree-sitter one-shot highlighting.
    func highlightOnce(content: String, filetype: String) async -> SyntaxHighlightResult
}

public extension SyntaxHighlighter {
    func highlightOnce(content: String, filetype: String) async -> SyntaxHighlightResult {
        highlight(content: content, filetype: filetype)
    }

    /// Convenience helper combining `highlight(content:filetype:)` with `treeSitterToTextChunks`.
    func highlightToTextChunks(
        content: String,
        filetype: String,
        syntaxStyle: SyntaxStyle,
        conceal: ConcealOptions = ConcealOptions(),
        baseHighlight: String? = nil
    ) -> [TextChunk] {
        let result = highlight(content: content, filetype: filetype)
        return treeSitterToTextChunks(
            content: content,
            highlights: result.highlights,
            syntaxStyle: syntaxStyle,
            conceal: conceal,
            baseHighlight: baseHighlight
        )
    }

    /// Convenience helper combining `highlight(content:filetype:)` with `treeSitterToStyledText`.
    func highlightToStyledText(
        content: String,
        filetype: String,
        syntaxStyle: SyntaxStyle,
        options: TreeSitterToStyledTextOptions? = nil
    ) -> StyledText {
        let result = highlight(content: content, filetype: filetype)
        return treeSitterToStyledText(
            content: content,
            highlights: result.highlights,
            syntaxStyle: syntaxStyle,
            options: options
        )
    }
}

// MARK: - Deterministic Test Highlighters

/// Stateless deterministic `SyntaxHighlighter` returning preconfigured highlights
/// (optionally keyed by canonical filetype).
public struct StaticSyntaxHighlighter: SyntaxHighlighter, Equatable, Sendable {
    public var defaultResult: SyntaxHighlightResult
    public var resultsByFiletype: [String: SyntaxHighlightResult]

    public init(
        highlights: [SimpleHighlight] = [],
        warning: String? = nil,
        resultsByFiletype: [String: SyntaxHighlightResult] = [:]
    ) {
        self.defaultResult = SyntaxHighlightResult(highlights: highlights, warning: warning)
        self.resultsByFiletype = resultsByFiletype
    }

    public init(
        defaultResult: SyntaxHighlightResult = SyntaxHighlightResult(),
        resultsByFiletype: [String: SyntaxHighlightResult] = [:]
    ) {
        self.defaultResult = defaultResult
        self.resultsByFiletype = resultsByFiletype
    }

    public func highlight(content: String, filetype: String) -> SyntaxHighlightResult {
        if let exact = resultsByFiletype[filetype] {
            return exact
        }
        if let resolved = resolveFiletype(filetype), let mapped = resultsByFiletype[resolved] {
            return mapped
        }
        return defaultResult
    }
}

/// Thread-safe recording mock `SyntaxHighlighter` for deterministic unit and integration testing.
public final class MockSyntaxHighlighter: SyntaxHighlighter, @unchecked Sendable {
    public struct Call: Equatable, Hashable, Sendable {
        public let content: String
        public let filetype: String
        public let isAsync: Bool

        public init(content: String, filetype: String, isAsync: Bool) {
            self.content = content
            self.filetype = filetype
            self.isAsync = isAsync
        }
    }

    private struct State: Sendable {
        var calls: [Call] = []
        var defaultResult: SyntaxHighlightResult
        var resultsByFiletype: [String: SyntaxHighlightResult]
        var handler: (@Sendable (String, String) -> SyntaxHighlightResult)?
    }

    private let state: Mutex<State>

    public init(
        defaultResult: SyntaxHighlightResult = SyntaxHighlightResult(),
        resultsByFiletype: [String: SyntaxHighlightResult] = [:],
        handler: (@Sendable (String, String) -> SyntaxHighlightResult)? = nil
    ) {
        self.state = Mutex(
            State(
                defaultResult: defaultResult,
                resultsByFiletype: resultsByFiletype,
                handler: handler
            )
        )
    }

    public var recordedCalls: [Call] {
        state.withLock { $0.calls }
    }

    public func setResult(_ result: SyntaxHighlightResult, forFiletype filetype: String) {
        state.withLock { $0.resultsByFiletype[filetype] = result }
    }

    public func setDefaultResult(_ result: SyntaxHighlightResult) {
        state.withLock { $0.defaultResult = result }
    }

    public func reset() {
        state.withLock { $0.calls.removeAll() }
    }

    public func highlight(content: String, filetype: String) -> SyntaxHighlightResult {
        evaluate(content: content, filetype: filetype, isAsync: false)
    }

    public func highlightOnce(content: String, filetype: String) async -> SyntaxHighlightResult {
        evaluate(content: content, filetype: filetype, isAsync: true)
    }

    private func evaluate(content: String, filetype: String, isAsync: Bool) -> SyntaxHighlightResult {
        let (handler, matched, fallback) = state.withLock {
            s -> ((@Sendable (String, String) -> SyntaxHighlightResult)?, SyntaxHighlightResult?, SyntaxHighlightResult) in
            s.calls.append(Call(content: content, filetype: filetype, isAsync: isAsync))
            let direct = s.resultsByFiletype[filetype]
            let resolved = direct ?? resolveFiletype(filetype).flatMap { s.resultsByFiletype[$0] }
            return (s.handler, resolved, s.defaultResult)
        }
        if let handler {
            return handler(content, filetype)
        }
        return matched ?? fallback
    }
}

// MARK: - Pure-Swift Built-In Lexical Syntax Highlighter

/// Fast, zero-dependency, pure-Swift lexical `SyntaxHighlighter` producing exact UTF-16
/// `SimpleHighlight` ranges using standard TextMate / Tree-sitter scope names:
/// `keyword`, `string`, `comment`, `number`, `type`, `function`, `operator`,
/// `punctuation`, `property`, `boolean`, `constant`, `markup.heading`, `markup.raw`,
/// `diff.plus`, `diff.minus`.
///
/// Supported languages: Swift, TypeScript/JavaScript (incl. TSX/JSX), JSON, Python,
/// Rust, Go, Shell/Bash, C/C++, Markdown, and Unified Diff.
public struct BuiltInSyntaxHighlighter: SyntaxHighlighter, Sendable {
    public static let shared = BuiltInSyntaxHighlighter()

    public init() {}

    /// Canonical set of languages handled directly by `BuiltInSyntaxHighlighter`.
    public static let supportedFiletypes: Set<String> = [
        "swift",
        "typescript",
        "typescriptreact",
        "javascript",
        "javascriptreact",
        "json",
        "python",
        "rust",
        "go",
        "bash",
        "c",
        "cpp",
        "markdown",
        "diff",
    ]

    public func highlight(content: String, filetype: String) -> SyntaxHighlightResult {
        guard !content.isEmpty else {
            return SyntaxHighlightResult()
        }

        let canonical = canonicalizeFiletype(filetype)
        let units = Array(content.utf16)

        switch canonical {
        case "swift":
            return SyntaxHighlightResult(highlights: tokenizeCode(units, spec: .swift))
        case "typescript", "typescriptreact", "javascript", "javascriptreact":
            return SyntaxHighlightResult(highlights: tokenizeCode(units, spec: .typeScript))
        case "json":
            return SyntaxHighlightResult(highlights: tokenizeJSON(units))
        case "python":
            return SyntaxHighlightResult(highlights: tokenizePython(units))
        case "rust":
            return SyntaxHighlightResult(highlights: tokenizeCode(units, spec: .rust))
        case "go":
            return SyntaxHighlightResult(highlights: tokenizeCode(units, spec: .go))
        case "bash":
            return SyntaxHighlightResult(highlights: tokenizeShell(units))
        case "c", "cpp":
            return SyntaxHighlightResult(highlights: tokenizeCode(units, spec: .cCpp))
        case "markdown":
            return SyntaxHighlightResult(highlights: tokenizeMarkdown(units))
        case "diff":
            return SyntaxHighlightResult(highlights: tokenizeDiff(units))
        default:
            return SyntaxHighlightResult(
                highlights: [],
                warning: "Unsupported built-in syntax highlighter filetype: \(canonical)"
            )
        }
    }

    private func canonicalizeFiletype(_ raw: String) -> String {
        let lower = String(trimFiletypeWhitespace(raw)).lowercased()
        switch lower {
        case "golang": return "go"
        case "shell": return "bash"
        case "jsonc": return "json"
        default:
            return resolveFiletype(raw) ?? lower
        }
    }
}

// MARK: - UTF-16 Scanner Utilities

private enum UTF16Char {
    static let tab: UInt16 = 0x09
    static let lf: UInt16 = 0x0A
    static let cr: UInt16 = 0x0D
    static let space: UInt16 = 0x20
    static let bang: UInt16 = 0x21       // !
    static let quote: UInt16 = 0x22      // "
    static let hash: UInt16 = 0x23       // #
    static let dollar: UInt16 = 0x24     // $
    static let percent: UInt16 = 0x25    // %
    static let ampersand: UInt16 = 0x26  // &
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
    static let nine: UInt16 = 0x39       // 9
    static let colon: UInt16 = 0x3A      // :
    static let semicolon: UInt16 = 0x3B  // ;
    static let lt: UInt16 = 0x3C         // <
    static let eq: UInt16 = 0x3D         // =
    static let gt: UInt16 = 0x3E         // >
    static let question: UInt16 = 0x3F   // ?
    static let at: UInt16 = 0x40         // @
    static let upperA: UInt16 = 0x41
    static let upperF: UInt16 = 0x46
    static let upperZ: UInt16 = 0x5A
    static let lbracket: UInt16 = 0x5B   // [
    static let backslash: UInt16 = 0x5C  // \
    static let rbracket: UInt16 = 0x5D   // ]
    static let caret: UInt16 = 0x5E      // ^
    static let underscore: UInt16 = 0x5F // _
    static let backtick: UInt16 = 0x60   // `
    static let lowerA: UInt16 = 0x61
    static let lowerB: UInt16 = 0x62
    static let lowerE: UInt16 = 0x65
    static let lowerF: UInt16 = 0x66
    static let lowerO: UInt16 = 0x6F
    static let lowerR: UInt16 = 0x72
    static let lowerU: UInt16 = 0x75
    static let lowerX: UInt16 = 0x78
    static let lowerZ: UInt16 = 0x7A
    static let lbrace: UInt16 = 0x7B     // {
    static let pipe: UInt16 = 0x7C       // |
    static let rbrace: UInt16 = 0x7D     // }
    static let tilde: UInt16 = 0x7E      // ~

    @inline(__always)
    static func isLeadSurrogate(_ u: UInt16) -> Bool {
        u >= 0xD800 && u <= 0xDBFF
    }

    @inline(__always)
    static func isTrailSurrogate(_ u: UInt16) -> Bool {
        u >= 0xDC00 && u <= 0xDFFF
    }

    @inline(__always)
    static func step(_ units: [UInt16], _ index: Int) -> Int {
        if index + 1 < units.count && isLeadSurrogate(units[index]) && isTrailSurrogate(units[index + 1]) {
            return index + 2
        }
        return index + 1
    }

    @inline(__always)
    static func isDigit(_ u: UInt16) -> Bool {
        u >= zero && u <= nine
    }

    @inline(__always)
    static func isHexDigit(_ u: UInt16) -> Bool {
        isDigit(u) || (u >= lowerA && u <= lowerF) || (u >= upperA && u <= upperF)
    }

    @inline(__always)
    static func isASCIIUpper(_ u: UInt16) -> Bool {
        u >= upperA && u <= upperZ
    }

    @inline(__always)
    static func isASCIILower(_ u: UInt16) -> Bool {
        u >= lowerA && u <= lowerZ
    }

    @inline(__always)
    static func isIdentStart(_ u: UInt16, allowDollar: Bool = false) -> Bool {
        isASCIIUpper(u) || isASCIILower(u) || u == underscore || (allowDollar && u == dollar)
    }

    @inline(__always)
    static func isIdentContinue(_ u: UInt16, allowDollar: Bool = false) -> Bool {
        isIdentStart(u, allowDollar: allowDollar) || isDigit(u)
    }

    @inline(__always)
    static func isInlineWhitespace(_ u: UInt16) -> Bool {
        u == space || u == tab
    }

    @inline(__always)
    static func isWhitespace(_ u: UInt16) -> Bool {
        u == space || u == tab || u == lf || u == cr
    }

    @inline(__always)
    static func isOperatorChar(_ u: UInt16) -> Bool {
        switch u {
        case plus, minus, star, slash, percent, eq, bang, lt, gt, ampersand, pipe, caret, tilde, question, colon:
            return true
        default:
            return false
        }
    }

    @inline(__always)
    static func isPunctuationChar(_ u: UInt16) -> Bool {
        switch u {
        case lparen, rparen, lbrace, rbrace, lbracket, rbracket, comma, semicolon, dot:
            return true
        default:
            return false
        }
    }

    static func asciiString(_ units: [UInt16], start: Int, end: Int) -> String {
        String(decoding: units[start..<end], as: UTF16.self)
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
}

private func scanLineEnd(_ units: [UInt16], from start: Int) -> Int {
    var i = start
    while i < units.count && units[i] != UTF16Char.lf && units[i] != UTF16Char.cr {
        i = UTF16Char.step(units, i)
    }
    return i
}

private func scanBlockComment(_ units: [UInt16], from start: Int, nested: Bool) -> Int {
    let n = units.count
    var i = start + 2
    var depth = 1
    while i < n && depth > 0 {
        if nested && i + 1 < n && units[i] == UTF16Char.slash && units[i + 1] == UTF16Char.star {
            depth += 1
            i += 2
        } else if i + 1 < n && units[i] == UTF16Char.star && units[i + 1] == UTF16Char.slash {
            depth -= 1
            i += 2
        } else {
            i = UTF16Char.step(units, i)
        }
    }
    return i
}

private func scanQuotedString(
    _ units: [UInt16],
    from start: Int,
    delimiter: UInt16,
    allowMultiline: Bool,
    allowEscapes: Bool = true
) -> Int {
    let n = units.count
    var i = start + 1
    while i < n {
        let u = units[i]
        if allowEscapes && u == UTF16Char.backslash {
            i += 1
            if i < n {
                i = UTF16Char.step(units, i)
            }
            continue
        }
        if u == delimiter {
            return i + 1
        }
        if !allowMultiline && (u == UTF16Char.lf || u == UTF16Char.cr) {
            return i
        }
        i = UTF16Char.step(units, i)
    }
    return n
}

private func scanTripleQuotedString(_ units: [UInt16], from start: Int, delimiter: UInt16) -> Int {
    let n = units.count
    var i = start + 3
    while i < n {
        if units[i] == UTF16Char.backslash {
            i += 1
            if i < n {
                i = UTF16Char.step(units, i)
            }
            continue
        }
        if i + 2 < n && units[i] == delimiter && units[i + 1] == delimiter && units[i + 2] == delimiter {
            return i + 3
        }
        i = UTF16Char.step(units, i)
    }
    return n
}

private func scanNumber(_ units: [UInt16], from start: Int) -> Int {
    let n = units.count
    var i = start
    if i + 1 < n && units[i] == UTF16Char.zero {
        let next = units[i + 1]
        if next == UTF16Char.lowerX || next == 0x58 { // 0x / 0X
            i += 2
            while i < n && (UTF16Char.isHexDigit(units[i]) || units[i] == UTF16Char.underscore) {
                i += 1
            }
            return scanNumericSuffix(units, from: i)
        } else if next == UTF16Char.lowerB || next == 0x42 { // 0b / 0B
            i += 2
            while i < n && (units[i] == UTF16Char.zero || units[i] == 0x31 || units[i] == UTF16Char.underscore) {
                i += 1
            }
            return scanNumericSuffix(units, from: i)
        } else if next == UTF16Char.lowerO || next == 0x4F { // 0o / 0O
            i += 2
            while i < n && ((units[i] >= UTF16Char.zero && units[i] <= 0x37) || units[i] == UTF16Char.underscore) {
                i += 1
            }
            return scanNumericSuffix(units, from: i)
        }
    }

    while i < n && (UTF16Char.isDigit(units[i]) || units[i] == UTF16Char.underscore) {
        i += 1
    }
    if i + 1 < n && units[i] == UTF16Char.dot && UTF16Char.isDigit(units[i + 1]) {
        i += 1
        while i < n && (UTF16Char.isDigit(units[i]) || units[i] == UTF16Char.underscore) {
            i += 1
        }
    }
    if i < n && (units[i] == UTF16Char.lowerE || units[i] == 0x45) {
        var exp = i + 1
        if exp < n && (units[exp] == UTF16Char.plus || units[exp] == UTF16Char.minus) {
            exp += 1
        }
        if exp < n && UTF16Char.isDigit(units[exp]) {
            i = exp
            while i < n && (UTF16Char.isDigit(units[i]) || units[i] == UTF16Char.underscore) {
                i += 1
            }
        }
    }
    return scanNumericSuffix(units, from: i)
}

private func scanNumericSuffix(_ units: [UInt16], from start: Int) -> Int {
    let n = units.count
    var i = start
    // Rust / C++ / JS numeric suffixes such as u64, i32, f64, usize, n, UL, f
    while i < n && (UTF16Char.isASCIILower(units[i]) || UTF16Char.isASCIIUpper(units[i]) || UTF16Char.isDigit(units[i])) {
        i += 1
    }
    return i
}

// MARK: - C-Family & Modern Code Lexer (Swift, TypeScript/JS, Rust, Go, C/C++)

private struct CodeLanguageSpec: Sendable {
    let keywords: Set<String>
    let booleans: Set<String>
    let constants: Set<String>
    let builtinTypes: Set<String>
    let functionDeclKeywords: Set<String>
    let typeDeclKeywords: Set<String>
    let nestedBlockComments: Bool
    let allowDollarIdentifiers: Bool
    let supportTripleDoubleQuotes: Bool
    let supportBacktickStrings: Bool
    let supportSingleQuoteStrings: Bool
    let rustLifetimes: Bool
    let supportPreprocessorHash: Bool
    let supportAtAttribute: Bool
    let supportHashDirectives: Bool

    static let swift = CodeLanguageSpec(
        keywords: [
            "actor", "as", "associatedtype", "async", "await", "borrowing", "break", "case",
            "catch", "class", "consuming", "continue", "default", "defer", "deinit", "do",
            "else", "enum", "extension", "fallthrough", "fileprivate", "final", "for", "func",
            "get", "guard", "if", "import", "in", "indirect", "infix", "init", "inout",
            "internal", "is", "isolated", "lazy", "let", "macro", "mutating", "nonisolated",
            "nonmutating", "open", "operator", "optional", "override", "package", "postfix",
            "precedencegroup", "prefix", "private", "protocol", "public", "repeat", "required",
            "rethrows", "return", "sending", "set", "some", "any", "static", "struct",
            "subscript", "super", "switch", "throw", "throws", "try", "typealias", "unowned",
            "var", "weak", "where", "while", "willSet", "didSet", "self", "Self",
        ],
        booleans: ["true", "false"],
        constants: ["nil"],
        builtinTypes: [
            "Int", "Int8", "Int16", "Int32", "Int64",
            "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
            "Float", "Double", "Bool", "String", "Substring", "Character",
            "Array", "Dictionary", "Set", "Optional", "Result", "Void", "Never",
            "Any", "AnyObject", "Error", "Sendable", "Equatable", "Hashable", "Codable",
            "Task", "Range", "ClosedRange", "Mutex",
        ],
        functionDeclKeywords: ["func"],
        typeDeclKeywords: ["struct", "class", "enum", "protocol", "actor", "typealias", "extension"],
        nestedBlockComments: true,
        allowDollarIdentifiers: true,
        supportTripleDoubleQuotes: true,
        supportBacktickStrings: false,
        supportSingleQuoteStrings: false,
        rustLifetimes: false,
        supportPreprocessorHash: false,
        supportAtAttribute: true,
        supportHashDirectives: true
    )

    static let typeScript = CodeLanguageSpec(
        keywords: [
            "abstract", "as", "asserts", "async", "await", "break", "case", "catch", "class",
            "const", "continue", "debugger", "declare", "default", "delete", "do", "else",
            "enum", "export", "extends", "finally", "for", "from", "function", "get", "if",
            "implements", "import", "in", "infer", "instanceof", "interface", "is", "keyof",
            "let", "module", "namespace", "new", "of", "override", "package", "private",
            "protected", "public", "readonly", "return", "satisfies", "set", "static", "super",
            "switch", "this", "throw", "try", "type", "typeof", "using", "var", "void",
            "while", "with", "yield",
        ],
        booleans: ["true", "false"],
        constants: ["null", "undefined", "NaN", "Infinity"],
        builtinTypes: [
            "string", "number", "boolean", "bigint", "symbol", "object", "unknown", "never",
            "any", "void", "Array", "Map", "Set", "Promise", "Record", "Partial", "Required",
            "Readonly", "Pick", "Omit", "Uint8Array", "Uint16Array", "Uint32Array", "Error",
        ],
        functionDeclKeywords: ["function"],
        typeDeclKeywords: ["class", "interface", "type", "enum"],
        nestedBlockComments: false,
        allowDollarIdentifiers: true,
        supportTripleDoubleQuotes: false,
        supportBacktickStrings: true,
        supportSingleQuoteStrings: true,
        rustLifetimes: false,
        supportPreprocessorHash: false,
        supportAtAttribute: true,
        supportHashDirectives: false
    )

    static let rust = CodeLanguageSpec(
        keywords: [
            "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else",
            "enum", "extern", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod",
            "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super",
            "trait", "type", "unsafe", "use", "where", "while",
        ],
        booleans: ["true", "false"],
        constants: ["None", "Some", "Ok", "Err"],
        builtinTypes: [
            "i8", "i16", "i32", "i64", "i128", "isize",
            "u8", "u16", "u32", "u64", "u128", "usize",
            "f32", "f64", "bool", "char", "str",
            "String", "Vec", "Option", "Result", "Box", "Rc", "Arc", "HashMap", "HashSet",
        ],
        functionDeclKeywords: ["fn"],
        typeDeclKeywords: ["struct", "enum", "trait", "type", "union"],
        nestedBlockComments: true,
        allowDollarIdentifiers: false,
        supportTripleDoubleQuotes: false,
        supportBacktickStrings: false,
        supportSingleQuoteStrings: false,
        rustLifetimes: true,
        supportPreprocessorHash: false,
        supportAtAttribute: false,
        supportHashDirectives: false
    )

    static let go = CodeLanguageSpec(
        keywords: [
            "break", "case", "chan", "const", "continue", "default", "defer", "else",
            "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map",
            "package", "range", "return", "select", "struct", "switch", "type", "var",
        ],
        booleans: ["true", "false"],
        constants: ["nil", "iota"],
        builtinTypes: [
            "any", "bool", "byte", "comparable", "complex64", "complex128", "error",
            "float32", "float64", "int", "int8", "int16", "int32", "int64", "rune", "string",
            "uint", "uint8", "uint16", "uint32", "uint64", "uintptr",
        ],
        functionDeclKeywords: ["func"],
        typeDeclKeywords: ["type", "struct", "interface"],
        nestedBlockComments: false,
        allowDollarIdentifiers: false,
        supportTripleDoubleQuotes: false,
        supportBacktickStrings: true,
        supportSingleQuoteStrings: true,
        rustLifetimes: false,
        supportPreprocessorHash: false,
        supportAtAttribute: false,
        supportHashDirectives: false
    )

    static let cCpp = CodeLanguageSpec(
        keywords: [
            "alignas", "alignof", "asm", "auto", "break", "case", "catch", "class", "concept",
            "const", "consteval", "constexpr", "constinit", "continue", "co_await", "co_return",
            "co_yield", "decltype", "default", "delete", "do", "else", "enum", "explicit",
            "export", "extern", "final", "for", "friend", "goto", "if", "inline", "mutable",
            "namespace", "new", "noexcept", "operator", "override", "private", "protected",
            "public", "register", "reinterpret_cast", "requires", "restrict", "return", "sizeof",
            "static", "static_assert", "static_cast", "dynamic_cast", "const_cast", "struct",
            "switch", "template", "this", "thread_local", "throw", "try", "typedef", "typeid",
            "typename", "union", "using", "virtual", "volatile", "while",
        ],
        booleans: ["true", "false"],
        constants: ["NULL", "nullptr", "EOF"],
        builtinTypes: [
            "void", "bool", "char", "signed", "unsigned", "short", "int", "long", "float",
            "double", "wchar_t", "char8_t", "char16_t", "char32_t", "size_t", "ssize_t",
            "ptrdiff_t", "intptr_t", "uintptr_t", "int8_t", "int16_t", "int32_t", "int64_t",
            "uint8_t", "uint16_t", "uint32_t", "uint64_t", "string", "vector", "map", "unique_ptr",
        ],
        functionDeclKeywords: [],
        typeDeclKeywords: ["struct", "class", "enum", "union", "typename", "namespace"],
        nestedBlockComments: false,
        allowDollarIdentifiers: false,
        supportTripleDoubleQuotes: false,
        supportBacktickStrings: false,
        supportSingleQuoteStrings: true,
        rustLifetimes: false,
        supportPreprocessorHash: true,
        supportAtAttribute: false,
        supportHashDirectives: false
    )
}

private func scanRustRawString(_ units: [UInt16], from start: Int) -> Int? {
    let n = units.count
    guard start < n && units[start] == UTF16Char.lowerR else { return nil }
    var i = start + 1
    var hashes = 0
    while i < n && units[i] == UTF16Char.hash {
        hashes += 1
        i += 1
    }
    guard i < n && units[i] == UTF16Char.quote else { return nil }
    i += 1
    while i < n {
        if units[i] == UTF16Char.quote {
            var matched = 0
            var j = i + 1
            while matched < hashes && j < n && units[j] == UTF16Char.hash {
                matched += 1
                j += 1
            }
            if matched == hashes {
                return j
            }
        }
        i = UTF16Char.step(units, i)
    }
    return n
}

private func scanSwiftRawString(_ units: [UInt16], from start: Int) -> Int? {
    let n = units.count
    var i = start
    var hashes = 0
    while i < n && units[i] == UTF16Char.hash {
        hashes += 1
        i += 1
    }
    guard hashes > 0 && i < n && units[i] == UTF16Char.quote else { return nil }
    i += 1
    while i < n {
        if units[i] == UTF16Char.quote {
            var matched = 0
            var j = i + 1
            while matched < hashes && j < n && units[j] == UTF16Char.hash {
                matched += 1
                j += 1
            }
            if matched == hashes {
                return j
            }
        }
        if units[i] == UTF16Char.lf || units[i] == UTF16Char.cr {
            return i
        }
        i = UTF16Char.step(units, i)
    }
    return n
}

private func scanRustApostrophe(_ units: [UInt16], from start: Int) -> (end: Int, group: String)? {
    let n = units.count
    guard start + 1 < n && units[start] == UTF16Char.apos else { return nil }

    // Character literal with escape: '\n', '\x7F', '\u{1F600}'
    if units[start + 1] == UTF16Char.backslash {
        var i = start + 2
        if i < n { i = UTF16Char.step(units, i) }
        while i < n && units[i] != UTF16Char.apos && units[i] != UTF16Char.lf && units[i] != UTF16Char.cr {
            i = UTF16Char.step(units, i)
        }
        if i < n && units[i] == UTF16Char.apos {
            return (i + 1, "string")
        }
        return nil
    }

    // Single-character literal: 'a', '🚀'
    let afterChar = UTF16Char.step(units, start + 1)
    if afterChar < n && units[afterChar] == UTF16Char.apos {
        return (afterChar + 1, "string")
    }

    // Lifetime: 'a, 'static, '_
    if UTF16Char.isIdentStart(units[start + 1]) {
        var i = start + 2
        while i < n && UTF16Char.isIdentContinue(units[i]) {
            i += 1
        }
        return (i, "type")
    }

    return nil
}

private func tokenizeCode(_ units: [UInt16], spec: CodeLanguageSpec) -> [SimpleHighlight] {
    let n = units.count
    var out: [SimpleHighlight] = []
    var i = 0
    var previousWord: String? = nil
    var precededByDot = false

    while i < n {
        let u = units[i]

        if UTF16Char.isWhitespace(u) {
            i += 1
            continue
        }

        // Line comment //
        if u == UTF16Char.slash && i + 1 < n && units[i + 1] == UTF16Char.slash {
            let end = scanLineEnd(units, from: i + 2)
            out.append(SimpleHighlight(i, end, "comment"))
            i = end
            continue
        }

        // Block comment /* ... */
        if u == UTF16Char.slash && i + 1 < n && units[i + 1] == UTF16Char.star {
            let end = scanBlockComment(units, from: i, nested: spec.nestedBlockComments)
            out.append(SimpleHighlight(i, end, "comment"))
            i = end
            continue
        }

        // C/C++ preprocessor directive (#include, #define, ...)
        if spec.supportPreprocessorHash && u == UTF16Char.hash {
            var j = i + 1
            while j < n && UTF16Char.isInlineWhitespace(units[j]) {
                j += 1
            }
            let wordStart = j
            while j < n && UTF16Char.isIdentContinue(units[j]) {
                j += 1
            }
            if j > wordStart {
                out.append(SimpleHighlight(i, j, "keyword"))
                i = j
                previousWord = nil
                precededByDot = false
                continue
            }
        }

        // Swift raw strings #"..."# or hash directives (#if, #else, #endif, #expect, ...)
        if spec.supportHashDirectives && u == UTF16Char.hash {
            if let rawEnd = scanSwiftRawString(units, from: i) {
                out.append(SimpleHighlight(i, rawEnd, "string"))
                i = rawEnd
                previousWord = nil
                precededByDot = false
                continue
            }
            if i + 1 < n && UTF16Char.isIdentStart(units[i + 1]) {
                var j = i + 2
                while j < n && UTF16Char.isIdentContinue(units[j]) {
                    j += 1
                }
                out.append(SimpleHighlight(i, j, "keyword"))
                i = j
                previousWord = nil
                precededByDot = false
                continue
            }
        }

        // Swift / TypeScript @attributes & decorators
        if spec.supportAtAttribute && u == UTF16Char.at && i + 1 < n && UTF16Char.isIdentStart(units[i + 1]) {
            var j = i + 2
            while j < n && UTF16Char.isIdentContinue(units[j]) {
                j += 1
            }
            out.append(SimpleHighlight(i, j, "keyword"))
            i = j
            previousWord = nil
            precededByDot = false
            continue
        }

        // Rust raw strings r#"..."#
        if spec.rustLifetimes && u == UTF16Char.lowerR {
            if let rawEnd = scanRustRawString(units, from: i) {
                out.append(SimpleHighlight(i, rawEnd, "string"))
                i = rawEnd
                previousWord = nil
                precededByDot = false
                continue
            }
        }

        // Triple-quoted strings """..."""
        if spec.supportTripleDoubleQuotes
            && u == UTF16Char.quote
            && i + 2 < n
            && units[i + 1] == UTF16Char.quote
            && units[i + 2] == UTF16Char.quote
        {
            let end = scanTripleQuotedString(units, from: i, delimiter: UTF16Char.quote)
            out.append(SimpleHighlight(i, end, "string"))
            i = end
            previousWord = nil
            precededByDot = false
            continue
        }

        // Double-quoted strings "..."
        if u == UTF16Char.quote {
            let end = scanQuotedString(units, from: i, delimiter: UTF16Char.quote, allowMultiline: false)
            out.append(SimpleHighlight(i, end, "string"))
            i = end
            previousWord = nil
            precededByDot = false
            continue
        }

        // Backtick template / raw strings `...`
        if spec.supportBacktickStrings && u == UTF16Char.backtick {
            let end = scanQuotedString(
                units,
                from: i,
                delimiter: UTF16Char.backtick,
                allowMultiline: true,
                allowEscapes: !spec.keywords.contains("package") || spec.allowDollarIdentifiers
            )
            out.append(SimpleHighlight(i, end, "string"))
            i = end
            previousWord = nil
            precededByDot = false
            continue
        }

        // Rust lifetimes & char literals
        if spec.rustLifetimes && u == UTF16Char.apos {
            if let matched = scanRustApostrophe(units, from: i) {
                out.append(SimpleHighlight(i, matched.end, matched.group))
                i = matched.end
                previousWord = nil
                precededByDot = false
                continue
            }
        }

        // Single-quoted strings / char literals
        if spec.supportSingleQuoteStrings && u == UTF16Char.apos {
            let end = scanQuotedString(units, from: i, delimiter: UTF16Char.apos, allowMultiline: false)
            out.append(SimpleHighlight(i, end, "string"))
            i = end
            previousWord = nil
            precededByDot = false
            continue
        }

        // Numbers
        if UTF16Char.isDigit(u) {
            let end = scanNumber(units, from: i)
            out.append(SimpleHighlight(i, end, "number"))
            i = end
            previousWord = nil
            precededByDot = false
            continue
        }

        // Identifiers / keywords / types / functions / properties
        if UTF16Char.isIdentStart(u, allowDollar: spec.allowDollarIdentifiers) {
            var j = i + 1
            while j < n && UTF16Char.isIdentContinue(units[j], allowDollar: spec.allowDollarIdentifiers) {
                j += 1
            }
            let word = UTF16Char.asciiString(units, start: i, end: j)

            // Lookahead for call expression '(' or Rust macro '!'
            let nextIsCall = (j < n && units[j] == UTF16Char.lparen)
                || (spec.rustLifetimes && j < n && units[j] == UTF16Char.bang)

            let group: String?
            if spec.booleans.contains(word) {
                group = "boolean"
            } else if spec.constants.contains(word) {
                group = "constant"
            } else if spec.keywords.contains(word) && !precededByDot {
                group = "keyword"
            } else if let prev = previousWord, spec.functionDeclKeywords.contains(prev) {
                group = "function"
            } else if let prev = previousWord, spec.typeDeclKeywords.contains(prev) {
                group = "type"
            } else if spec.builtinTypes.contains(word) && !precededByDot {
                group = "type"
            } else if nextIsCall {
                group = "function"
            } else if precededByDot {
                group = "property"
            } else if UTF16Char.isAllCapsConstant(units, start: i, end: j) {
                group = "constant"
            } else if UTF16Char.isASCIIUpper(u) {
                group = "type"
            } else {
                group = nil
            }

            if let group {
                out.append(SimpleHighlight(i, j, group))
            }
            previousWord = word
            precededByDot = false
            i = j
            continue
        }

        // Punctuation
        if UTF16Char.isPunctuationChar(u) {
            out.append(SimpleHighlight(i, i + 1, "punctuation"))
            precededByDot = (u == UTF16Char.dot)
            previousWord = nil
            i += 1
            continue
        }

        // Operators (group contiguous operator characters, stopping before // or /*)
        if UTF16Char.isOperatorChar(u) {
            var j = i + 1
            while j < n && UTF16Char.isOperatorChar(units[j]) {
                if units[j] == UTF16Char.slash && j + 1 < n
                    && (units[j + 1] == UTF16Char.slash || units[j + 1] == UTF16Char.star)
                {
                    break
                }
                j += 1
            }
            out.append(SimpleHighlight(i, j, "operator"))
            previousWord = nil
            precededByDot = false
            i = j
            continue
        }

        // Non-ASCII or other character — advance safely without splitting surrogate pairs
        previousWord = nil
        precededByDot = false
        i = UTF16Char.step(units, i)
    }

    return out
}

// MARK: - JSON Lexer

private func tokenizeJSON(_ units: [UInt16]) -> [SimpleHighlight] {
    let n = units.count
    var out: [SimpleHighlight] = []
    var i = 0

    while i < n {
        let u = units[i]

        if UTF16Char.isWhitespace(u) {
            i += 1
            continue
        }

        // JSONC comment tolerance
        if u == UTF16Char.slash && i + 1 < n && units[i + 1] == UTF16Char.slash {
            let end = scanLineEnd(units, from: i + 2)
            out.append(SimpleHighlight(i, end, "comment"))
            i = end
            continue
        }
        if u == UTF16Char.slash && i + 1 < n && units[i + 1] == UTF16Char.star {
            let end = scanBlockComment(units, from: i, nested: false)
            out.append(SimpleHighlight(i, end, "comment"))
            i = end
            continue
        }

        // String or object property key
        if u == UTF16Char.quote {
            let end = scanQuotedString(units, from: i, delimiter: UTF16Char.quote, allowMultiline: false)
            var lookahead = end
            while lookahead < n && UTF16Char.isWhitespace(units[lookahead]) {
                lookahead += 1
            }
            let isPropertyKey = lookahead < n && units[lookahead] == UTF16Char.colon
            out.append(SimpleHighlight(i, end, isPropertyKey ? "property" : "string"))
            i = end
            continue
        }

        // Numbers (including leading '-')
        if UTF16Char.isDigit(u) || (u == UTF16Char.minus && i + 1 < n && UTF16Char.isDigit(units[i + 1])) {
            let start = i
            if u == UTF16Char.minus {
                i += 1
            }
            let end = scanNumber(units, from: i)
            out.append(SimpleHighlight(start, end, "number"))
            i = end
            continue
        }

        // Booleans & null
        if UTF16Char.isASCIILower(u) {
            var j = i + 1
            while j < n && UTF16Char.isASCIILower(units[j]) {
                j += 1
            }
            let word = UTF16Char.asciiString(units, start: i, end: j)
            if word == "true" || word == "false" {
                out.append(SimpleHighlight(i, j, "boolean"))
            } else if word == "null" {
                out.append(SimpleHighlight(i, j, "constant"))
            }
            i = j
            continue
        }

        // Punctuation: { } [ ] , :
        if u == UTF16Char.lbrace || u == UTF16Char.rbrace
            || u == UTF16Char.lbracket || u == UTF16Char.rbracket
            || u == UTF16Char.comma || u == UTF16Char.colon
        {
            out.append(SimpleHighlight(i, i + 1, "punctuation"))
            i += 1
            continue
        }

        i = UTF16Char.step(units, i)
    }

    return out
}

// MARK: - Python Lexer

private let pythonKeywords: Set<String> = [
    "and", "as", "assert", "async", "await", "break", "case", "class", "continue", "def",
    "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import",
    "in", "is", "lambda", "match", "nonlocal", "not", "or", "pass", "raise", "return",
    "try", "while", "with", "yield",
]

private let pythonBuiltinTypes: Set<String> = [
    "bool", "bytearray", "bytes", "complex", "dict", "float", "frozenset", "int",
    "list", "memoryview", "object", "range", "set", "str", "tuple", "type",
]

private func isPythonStringPrefix(_ u: UInt16) -> Bool {
    switch u {
    case UTF16Char.lowerF, 0x46, UTF16Char.lowerR, 0x52, UTF16Char.lowerB, 0x42, UTF16Char.lowerU, 0x55:
        return true
    default:
        return false
    }
}

private func tokenizePython(_ units: [UInt16]) -> [SimpleHighlight] {
    let n = units.count
    var out: [SimpleHighlight] = []
    var i = 0
    var previousWord: String? = nil
    var precededByDot = false

    while i < n {
        let u = units[i]

        if UTF16Char.isWhitespace(u) {
            i += 1
            continue
        }

        // Comment # ...
        if u == UTF16Char.hash {
            let end = scanLineEnd(units, from: i + 1)
            out.append(SimpleHighlight(i, end, "comment"))
            i = end
            continue
        }

        // Decorator @name
        if u == UTF16Char.at && i + 1 < n && UTF16Char.isIdentStart(units[i + 1]) {
            var j = i + 2
            while j < n && (UTF16Char.isIdentContinue(units[j]) || units[j] == UTF16Char.dot) {
                j += 1
            }
            out.append(SimpleHighlight(i, j, "function"))
            i = j
            previousWord = nil
            precededByDot = false
            continue
        }

        // Prefixed strings: f"...", r'...', rf"""...""", b"..."
        if isPythonStringPrefix(u) {
            var q = i + 1
            if q < n && isPythonStringPrefix(units[q]) {
                q += 1
            }
            if q < n && (units[q] == UTF16Char.quote || units[q] == UTF16Char.apos) {
                let delim = units[q]
                let end: Int
                if q + 2 < n && units[q + 1] == delim && units[q + 2] == delim {
                    end = scanTripleQuotedString(units, from: q, delimiter: delim)
                } else {
                    end = scanQuotedString(units, from: q, delimiter: delim, allowMultiline: false)
                }
                out.append(SimpleHighlight(i, end, "string"))
                i = end
                previousWord = nil
                precededByDot = false
                continue
            }
        }

        // Strings (single, double, triple)
        if u == UTF16Char.quote || u == UTF16Char.apos {
            let end: Int
            if i + 2 < n && units[i + 1] == u && units[i + 2] == u {
                end = scanTripleQuotedString(units, from: i, delimiter: u)
            } else {
                end = scanQuotedString(units, from: i, delimiter: u, allowMultiline: false)
            }
            out.append(SimpleHighlight(i, end, "string"))
            i = end
            previousWord = nil
            precededByDot = false
            continue
        }

        // Numbers
        if UTF16Char.isDigit(u) {
            let end = scanNumber(units, from: i)
            out.append(SimpleHighlight(i, end, "number"))
            i = end
            previousWord = nil
            precededByDot = false
            continue
        }

        // Identifiers
        if UTF16Char.isIdentStart(u) {
            var j = i + 1
            while j < n && UTF16Char.isIdentContinue(units[j]) {
                j += 1
            }
            let word = UTF16Char.asciiString(units, start: i, end: j)
            let nextIsCall = j < n && units[j] == UTF16Char.lparen

            let group: String?
            if word == "True" || word == "False" {
                group = "boolean"
            } else if word == "None" || word == "Ellipsis" || word == "NotImplemented" {
                group = "constant"
            } else if pythonKeywords.contains(word) && !precededByDot {
                group = "keyword"
            } else if previousWord == "def" {
                group = "function"
            } else if previousWord == "class" {
                group = "type"
            } else if pythonBuiltinTypes.contains(word) && !precededByDot {
                group = "type"
            } else if nextIsCall {
                group = "function"
            } else if precededByDot {
                group = "property"
            } else if UTF16Char.isAllCapsConstant(units, start: i, end: j) {
                group = "constant"
            } else if UTF16Char.isASCIIUpper(u) {
                group = "type"
            } else {
                group = nil
            }

            if let group {
                out.append(SimpleHighlight(i, j, group))
            }
            previousWord = word
            precededByDot = false
            i = j
            continue
        }

        if UTF16Char.isPunctuationChar(u) {
            out.append(SimpleHighlight(i, i + 1, "punctuation"))
            precededByDot = (u == UTF16Char.dot)
            previousWord = nil
            i += 1
            continue
        }

        if UTF16Char.isOperatorChar(u) {
            var j = i + 1
            while j < n && UTF16Char.isOperatorChar(units[j]) {
                j += 1
            }
            out.append(SimpleHighlight(i, j, "operator"))
            previousWord = nil
            precededByDot = false
            i = j
            continue
        }

        previousWord = nil
        precededByDot = false
        i = UTF16Char.step(units, i)
    }

    return out
}

// MARK: - Shell / Bash Lexer

private let shellKeywords: Set<String> = [
    "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until",
    "case", "esac", "function", "select", "return", "exit", "export", "local", "readonly",
    "declare", "typeset", "unset", "shift", "source", "break", "continue", "set", "trap",
]

private func tokenizeShell(_ units: [UInt16]) -> [SimpleHighlight] {
    let n = units.count
    var out: [SimpleHighlight] = []
    var i = 0
    var atCommandBoundary = true

    while i < n {
        let u = units[i]

        if u == UTF16Char.lf || u == UTF16Char.cr {
            atCommandBoundary = true
            i += 1
            continue
        }
        if UTF16Char.isInlineWhitespace(u) {
            i += 1
            continue
        }

        // Comment # ...
        if u == UTF16Char.hash && (i == 0 || UTF16Char.isWhitespace(units[i - 1]) || units[i - 1] == UTF16Char.semicolon) {
            let end = scanLineEnd(units, from: i + 1)
            out.append(SimpleHighlight(i, end, "comment"))
            i = end
            continue
        }

        // Strings: "...", '...', `...`
        if u == UTF16Char.quote || u == UTF16Char.apos || u == UTF16Char.backtick {
            let end = scanQuotedString(
                units,
                from: i,
                delimiter: u,
                allowMultiline: true,
                allowEscapes: u != UTF16Char.apos
            )
            out.append(SimpleHighlight(i, end, "string"))
            atCommandBoundary = false
            i = end
            continue
        }

        // Variables: $VAR, ${VAR}, $1, $?
        if u == UTF16Char.dollar {
            var j = i + 1
            if j < n && units[j] == UTF16Char.lbrace {
                j += 1
                while j < n && units[j] != UTF16Char.rbrace && units[j] != UTF16Char.lf {
                    j = UTF16Char.step(units, j)
                }
                if j < n && units[j] == UTF16Char.rbrace {
                    j += 1
                }
            } else if j < n && UTF16Char.isIdentStart(units[j]) {
                j += 1
                while j < n && UTF16Char.isIdentContinue(units[j]) {
                    j += 1
                }
            } else if j < n && (UTF16Char.isDigit(units[j]) || units[j] == UTF16Char.question || units[j] == UTF16Char.at || units[j] == UTF16Char.star || units[j] == UTF16Char.hash || units[j] == UTF16Char.dollar) {
                j += 1
            }
            if j > i + 1 {
                out.append(SimpleHighlight(i, j, "constant"))
                atCommandBoundary = false
                i = j
                continue
            }
        }

        // Numbers
        if UTF16Char.isDigit(u) && (i == 0 || UTF16Char.isWhitespace(units[i - 1]) || units[i - 1] == UTF16Char.eq) {
            let end = scanNumber(units, from: i)
            out.append(SimpleHighlight(i, end, "number"))
            atCommandBoundary = false
            i = end
            continue
        }

        // Words / keywords / assignment targets
        if UTF16Char.isIdentStart(u) {
            var j = i + 1
            while j < n && (UTF16Char.isIdentContinue(units[j]) || units[j] == UTF16Char.minus) {
                j += 1
            }
            let word = UTF16Char.asciiString(units, start: i, end: j)
            if word == "true" || word == "false" {
                out.append(SimpleHighlight(i, j, "boolean"))
            } else if shellKeywords.contains(word) {
                out.append(SimpleHighlight(i, j, "keyword"))
            } else if j < n && units[j] == UTF16Char.eq {
                out.append(SimpleHighlight(i, j, "property"))
            } else if atCommandBoundary {
                out.append(SimpleHighlight(i, j, "function"))
            }
            atCommandBoundary = false
            i = j
            continue
        }

        if u == UTF16Char.semicolon {
            out.append(SimpleHighlight(i, i + 1, "punctuation"))
            atCommandBoundary = true
            i += 1
            continue
        }

        if u == UTF16Char.pipe || u == UTF16Char.ampersand || u == UTF16Char.gt || u == UTF16Char.lt || u == UTF16Char.eq || u == UTF16Char.bang {
            var j = i + 1
            while j < n && (units[j] == UTF16Char.pipe || units[j] == UTF16Char.ampersand || units[j] == UTF16Char.gt || units[j] == UTF16Char.lt || units[j] == UTF16Char.eq) {
                j += 1
            }
            out.append(SimpleHighlight(i, j, "operator"))
            atCommandBoundary = (u == UTF16Char.pipe || u == UTF16Char.ampersand)
            i = j
            continue
        }

        if UTF16Char.isPunctuationChar(u) {
            out.append(SimpleHighlight(i, i + 1, "punctuation"))
            atCommandBoundary = (u == UTF16Char.lparen || u == UTF16Char.lbrace)
            i += 1
            continue
        }

        atCommandBoundary = false
        i = UTF16Char.step(units, i)
    }

    return out
}

// MARK: - Markdown Lexer

private func tokenizeMarkdown(_ units: [UInt16]) -> [SimpleHighlight] {
    let n = units.count
    var out: [SimpleHighlight] = []
    var i = 0
    var inFence = false
    var fenceChar: UInt16 = 0
    var fenceLen = 0

    while i < n {
        let lineStart = i
        let lineEnd = scanLineEnd(units, from: lineStart)
        let nextLine: Int
        if lineEnd < n {
            if units[lineEnd] == UTF16Char.cr && lineEnd + 1 < n && units[lineEnd + 1] == UTF16Char.lf {
                nextLine = lineEnd + 2
            } else {
                nextLine = lineEnd + 1
            }
        } else {
            nextLine = n
        }

        // Skip up to 3 leading spaces for Markdown block markers
        var lead = lineStart
        var spaces = 0
        while lead < lineEnd && units[lead] == UTF16Char.space && spaces < 3 {
            lead += 1
            spaces += 1
        }

        // Detect opening / closing code fences (``` or ~~~)
        if lead < lineEnd && (units[lead] == UTF16Char.backtick || units[lead] == UTF16Char.tilde) {
            let ch = units[lead]
            var count = 0
            var k = lead
            while k < lineEnd && units[k] == ch {
                count += 1
                k += 1
            }
            if count >= 3 {
                if !inFence {
                    inFence = true
                    fenceChar = ch
                    fenceLen = count
                    if lineStart < lineEnd {
                        out.append(SimpleHighlight(lineStart, lineEnd, "markup.raw"))
                    }
                    i = nextLine
                    continue
                } else if ch == fenceChar && count >= fenceLen {
                    var rest = k
                    while rest < lineEnd && UTF16Char.isInlineWhitespace(units[rest]) {
                        rest += 1
                    }
                    if rest == lineEnd {
                        inFence = false
                        if lineStart < lineEnd {
                            out.append(SimpleHighlight(lineStart, lineEnd, "markup.raw"))
                        }
                        i = nextLine
                        continue
                    }
                }
            }
        }

        if inFence {
            if lineStart < lineEnd {
                out.append(SimpleHighlight(lineStart, lineEnd, "markup.raw"))
            }
            i = nextLine
            continue
        }

        // ATX Headings: # .. ###### followed by space or end-of-line
        if lead < lineEnd && units[lead] == UTF16Char.hash {
            var hashes = 0
            var k = lead
            while k < lineEnd && units[k] == UTF16Char.hash && hashes < 7 {
                hashes += 1
                k += 1
            }
            if hashes >= 1 && hashes <= 6 && (k == lineEnd || UTF16Char.isInlineWhitespace(units[k])) {
                out.append(SimpleHighlight(lead, lineEnd, "markup.heading"))
                i = nextLine
                continue
            }
        }

        // Blockquotes: >
        if lead < lineEnd && units[lead] == UTF16Char.gt {
            out.append(SimpleHighlight(lead, lineEnd, "comment"))
            i = nextLine
            continue
        }

        // Inline spans on regular lines: inline code `...` and links [label](url)
        var cursor = lineStart
        while cursor < lineEnd {
            let u = units[cursor]
            if u == UTF16Char.backtick {
                var ticks = 0
                var k = cursor
                while k < lineEnd && units[k] == UTF16Char.backtick {
                    ticks += 1
                    k += 1
                }
                var search = k
                var closeEnd: Int? = nil
                while search < lineEnd {
                    if units[search] == UTF16Char.backtick {
                        var closeCount = 0
                        var m = search
                        while m < lineEnd && units[m] == UTF16Char.backtick {
                            closeCount += 1
                            m += 1
                        }
                        if closeCount == ticks {
                            closeEnd = m
                            break
                        }
                        search = m
                    } else {
                        search = UTF16Char.step(units, search)
                    }
                }
                if let end = closeEnd {
                    out.append(SimpleHighlight(cursor, end, "markup.raw"))
                    cursor = end
                    continue
                }
                cursor = k
                continue
            }

            if u == UTF16Char.lbracket {
                var closeBracket = cursor + 1
                while closeBracket < lineEnd && units[closeBracket] != UTF16Char.rbracket {
                    closeBracket = UTF16Char.step(units, closeBracket)
                }
                if closeBracket + 1 < lineEnd
                    && units[closeBracket] == UTF16Char.rbracket
                    && units[closeBracket + 1] == UTF16Char.lparen
                {
                    var closeParen = closeBracket + 2
                    while closeParen < lineEnd && units[closeParen] != UTF16Char.rparen {
                        closeParen = UTF16Char.step(units, closeParen)
                    }
                    if closeParen < lineEnd && units[closeParen] == UTF16Char.rparen {
                        out.append(SimpleHighlight(cursor, closeParen + 1, "string"))
                        cursor = closeParen + 1
                        continue
                    }
                }
            }

            cursor = UTF16Char.step(units, cursor)
        }

        i = nextLine
    }

    return out
}

// MARK: - Unified Diff Lexer

private func unitsHasPrefix(_ units: [UInt16], at offset: Int, lineEnd: Int, ascii: String) -> Bool {
    let prefixUnits = Array(ascii.utf16)
    guard offset + prefixUnits.count <= lineEnd else { return false }
    for idx in prefixUnits.indices {
        if units[offset + idx] != prefixUnits[idx] {
            return false
        }
    }
    return true
}

private func tokenizeDiff(_ units: [UInt16]) -> [SimpleHighlight] {
    let n = units.count
    var out: [SimpleHighlight] = []
    var i = 0

    while i < n {
        let lineStart = i
        let lineEnd = scanLineEnd(units, from: lineStart)
        let nextLine: Int
        if lineEnd < n {
            if units[lineEnd] == UTF16Char.cr && lineEnd + 1 < n && units[lineEnd + 1] == UTF16Char.lf {
                nextLine = lineEnd + 2
            } else {
                nextLine = lineEnd + 1
            }
        } else {
            nextLine = n
        }

        if lineStart < lineEnd {
            let first = units[lineStart]
            if unitsHasPrefix(units, at: lineStart, lineEnd: lineEnd, ascii: "@@") {
                out.append(SimpleHighlight(lineStart, lineEnd, "markup.heading"))
            } else if unitsHasPrefix(units, at: lineStart, lineEnd: lineEnd, ascii: "+++ ")
                || unitsHasPrefix(units, at: lineStart, lineEnd: lineEnd, ascii: "--- ")
                || unitsHasPrefix(units, at: lineStart, lineEnd: lineEnd, ascii: "diff --git ")
                || unitsHasPrefix(units, at: lineStart, lineEnd: lineEnd, ascii: "index ")
                || unitsHasPrefix(units, at: lineStart, lineEnd: lineEnd, ascii: "new file mode ")
                || unitsHasPrefix(units, at: lineStart, lineEnd: lineEnd, ascii: "deleted file mode ")
                || unitsHasPrefix(units, at: lineStart, lineEnd: lineEnd, ascii: "rename from ")
                || unitsHasPrefix(units, at: lineStart, lineEnd: lineEnd, ascii: "rename to ")
            {
                out.append(SimpleHighlight(lineStart, lineEnd, "comment"))
            } else if first == UTF16Char.plus {
                out.append(SimpleHighlight(lineStart, lineEnd, "diff.plus"))
            } else if first == UTF16Char.minus {
                out.append(SimpleHighlight(lineStart, lineEnd, "diff.minus"))
            }
        }

        i = nextLine
    }

    return out
}
