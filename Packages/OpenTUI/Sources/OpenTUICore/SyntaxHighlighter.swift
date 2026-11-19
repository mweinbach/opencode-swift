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

// MARK: - Pure-Swift Built-In Tree-Sitter Syntax Highlighter

/// Fast, zero-dependency, pure-Swift stateful `SyntaxHighlighter` producing exact UTF-16
/// `SimpleHighlight` ranges using upstream Tree-Sitter capture scopes (`keyword`,
/// `keyword.function`, `keyword.return`, `keyword.operator`, `type`, `type.builtin`,
/// `function`, `function.method`, `function.macro`, `string`, `string.escape`,
/// `string.special.url`, `comment`, `number`, `boolean`, `constant`, `constant.builtin`,
/// `operator`, `punctuation.bracket`, `punctuation.delimiter`, `tag`, `attribute`,
/// `property`, `variable.parameter`, `markup.heading`, `markup.raw`, `markup.link.label`,
/// `markup.link.url`, `markup.strong`, `markup.italic`, `conceal`, `diff.plus`,
/// `diff.minus`, `diff.delta`).
///
/// Covers all 34 upstream OpenCode languages from `packages/tui/src/parsers-config.ts`,
/// OpenTUI's built-in parsers (`javascript`, `javascriptreact`, `typescript`,
/// `typescriptreact`, `markdown`, `markdown_inline`, `zig`), all filetype aliases from
/// `resolve-ft.ts`, and dynamically registered custom grammars via `TreeSitterGrammarRegistry`.
public struct BuiltInSyntaxHighlighter: SyntaxHighlighter, Sendable {
    public static let shared = BuiltInSyntaxHighlighter()

    private let registry: TreeSitterGrammarRegistry

    public init(registry: TreeSitterGrammarRegistry = .shared) {
        self.registry = registry
    }

    /// Canonical set of built-in languages handled directly by `BuiltInSyntaxHighlighter`.
    public static let supportedFiletypes: Set<String> = TreeSitterGrammars.supportedFiletypes

    /// Returns `true` if `filetype` (canonical name, extension, path, basename, alias, or custom grammar)
    /// is supported by the shared `TreeSitterGrammarRegistry`.
    public static func supports(filetype: String) -> Bool {
        TreeSitterGrammars.supports(filetype: filetype)
    }

    /// Returns `true` if `filetype` (canonical name, extension, path, basename, alias, or custom grammar)
    /// is supported by this highlighter's `TreeSitterGrammarRegistry`.
    public func supports(filetype: String) -> Bool {
        registry.supports(filetype: filetype)
    }

    public func highlight(content: String, filetype: String) -> SyntaxHighlightResult {
        registry.highlight(content: content, filetype: filetype)
    }
}
