// Pure Swift 6.2 LaTeX math AST, layout, and error types (`packages/latex/src/types.ts`).

/// Mathematical alphabet / typeface variant applied by commands such as `\mathbf`, `\mathbb`, `\mathcal`, and `\mathfrak`.
// parity: latex/src/types.ts#MathVariant [status=implemented hash=661cddc7f9aa]
public enum MathVariant: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
    case normal
    case bold
    case italic
    case sans
    case monospace
    case doubleStruck = "double-struck"
    case script
    case fraktur
}

/// Horizontal alignment for `\cfrac` numerators (`[l]` or `[r]`).
public enum FractionNumeratorAlign: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
    case left
    case right
}

/// Vertical placement for horizontal curly braces (`\overbrace` or `\underbrace`).
public enum BracePosition: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
    case over
    case under
}

/// Structural AST node produced by `parseLatex` and consumed by `layoutMath`.
// parity: latex/src/types.ts#MathNode [status=implemented hash=2c80b1b55963]
public indirect enum MathNode: Equatable, Hashable, Sendable, Codable {
    case row([MathNode])
    case symbol(value: String, role: SymbolRole? = nil)
    case text(String)
    case space(width: Int)
    case fraction(
        numerator: MathNode,
        denominator: MathNode,
        bar: Bool,
        numeratorAlign: FractionNumeratorAlign? = nil
    )
    case root(body: MathNode, index: MathNode? = nil)
    case scripts(base: MathNode, superscript: MathNode? = nil, subscript: MathNode? = nil)
    case delimited(left: String, body: MathNode, right: String)
    case matrix(rows: [[MathNode]], environment: MatrixEnvironment, columns: String? = nil)
    case brace(body: MathNode, position: BracePosition)
    case accent(accent: AccentKind, body: MathNode)
    case variant(variant: MathVariant, body: MathNode)
    case `operator`(value: String, limits: Bool)
    case overunder(base: MathNode, over: MathNode? = nil, under: MathNode? = nil)
    case color(color: String, body: MathNode)
}

/// Semantic TeX math atom spacing class.
// parity: latex/src/types.ts#SymbolRole [status=implemented hash=09f161ec72e2]
public enum SymbolRole: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
    case ordinary
    case binary
    case relation
    case `operator`
    case punctuation
    case opening
    case closing
}

/// Supported multi-row matrix, alignment, and piecewise math environments.
// parity: latex/src/types.ts#MatrixEnvironment [status=implemented hash=ef257e25d600]
public enum MatrixEnvironment: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
    case matrix
    case pmatrix
    case bmatrix
    case Bmatrix
    case vmatrix
    case Vmatrix
    case cases
    case aligned
    case align
    case gathered
    case gather
    case smallmatrix
    case array
}

/// Supported over/under accent kinds.
// parity: latex/src/types.ts#AccentKind [status=implemented hash=29062f74f6e2]
public enum AccentKind: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
    case hat
    case widehat
    case bar
    case overline
    case underline
    case vec
    case tilde
    case dot
    case ddot
}

/// Options controlling LaTeX macro expansion, resource bounds, and strict command validation.
// parity: latex/src/types.ts#ParseOptions [status=implemented hash=c23945adf9d3]
public struct ParseOptions: Equatable, Hashable, Sendable {
    public var macros: [String: String]?
    public var maxExpand: Int?
    /// Maximum accepted input length (UTF-16 code units). Guards interactive and AI-generated formulas
    /// against accidentally exhausting the terminal process.
    public var maxSourceLength: Int?
    /// Maximum length after user-macro expansion (UTF-16 code units). Defaults to `maxSourceLength`.
    public var maxExpandedLength: Int?
    /// Maximum structural nesting depth.
    public var maxDepth: Int?
    public var strict: Bool?

    public init(
        macros: [String: String]? = nil,
        maxExpand: Int? = nil,
        maxSourceLength: Int? = nil,
        maxExpandedLength: Int? = nil,
        maxDepth: Int? = nil,
        strict: Bool? = nil
    ) {
        self.macros = macros
        self.maxExpand = maxExpand
        self.maxSourceLength = maxSourceLength
        self.maxExpandedLength = maxExpandedLength
        self.maxDepth = maxDepth
        self.strict = strict
    }
}

/// Parse or resource-limit error carrying the 0-based UTF-16 offset into the LaTeX source.
// parity: latex/src/types.ts#LatexParseError [status=implemented hash=61b33ff735f8]
public struct LatexParseError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let name: String
    public let message: String
    public let position: Int

    public init(_ message: String, position: Int) {
        self.name = "LatexParseError"
        self.message = "\(message) at offset \(position)"
        self.position = position
    }

    public var description: String {
        message
    }
}

/// Range error thrown when a numeric limit option (such as `maxSourceLength` or `maxDepth`) is invalid,
/// matching JavaScript `RangeError` in `packages/latex/src/limits.ts`.
public struct LatexRangeError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String {
        message
    }
}

/// Terminal text style attached to an individual `MathCell`.
// parity: latex/src/types.ts#MathStyle [status=implemented hash=bbb57de87f6c]
public struct MathStyle: Equatable, Hashable, Sendable, Codable {
    public var color: String?
    public var bold: Bool?
    public var italic: Bool?
    public var dim: Bool?

    public init(
        color: String? = nil,
        bold: Bool? = nil,
        italic: Bool? = nil,
        dim: Bool? = nil
    ) {
        self.color = color
        self.bold = bold
        self.italic = italic
        self.dim = dim
    }
}

/// Single grapheme cell placed on the 2D `MathLayout` character grid.
// parity: latex/src/types.ts#MathCell [status=implemented hash=1c1fd8a6be57]
public struct MathCell: Equatable, Hashable, Sendable, Codable {
    public var char: String
    public var style: MathStyle?

    public init(char: String, style: MathStyle? = nil) {
        self.char = char
        self.style = style
    }
}

/// Intrinsic 2D terminal cell grid and math-axis baseline produced by `layoutMath` and `renderLatex`.
// parity: latex/src/types.ts#MathLayout [status=implemented hash=db9769e5bac0]
public struct MathLayout: Equatable, Hashable, Sendable, CustomStringConvertible {
    public let width: Int
    public let height: Int
    public let baseline: Int
    public let cells: [[MathCell?]]

    public init(width: Int, height: Int, baseline: Int, cells: [[MathCell?]]) {
        self.width = width
        self.height = height
        self.baseline = baseline
        self.cells = cells
    }

    /// Serializes the 2D cell grid into newline-separated Unicode lines with trailing whitespace trimmed.
    public func toString() -> String {
        var lines: [String] = []
        lines.reserveCapacity(cells.count)
        for row in cells {
            var output = ""
            var x = 0
            while x < width {
                let cell = x < row.count ? row[x] : nil
                output.append(cell?.char ?? " ")
                if let cell {
                    let cellW = latexCellWidth(cell.char)
                    if cellW > 1 {
                        x += cellW - 1
                    }
                }
                x += 1
            }
            lines.append(latexTrimEnd(output))
        }
        return lines.joined(separator: "\n")
    }

    public var description: String {
        toString()
    }
}

/// Combined parse and 2D terminal layout options accepted by `renderLatex`, `renderLatexToString`, and `layoutMath`.
// parity: latex/src/types.ts#RenderLatexOptions [status=implemented hash=36fe40f953b3]
public struct RenderLatexOptions: Equatable, Hashable, Sendable {
    public var macros: [String: String]?
    public var maxExpand: Int?
    public var maxSourceLength: Int?
    public var maxExpandedLength: Int?
    public var maxDepth: Int?
    public var strict: Bool?
    public var displayMode: Bool?
    public var compactScripts: Bool?
    public var color: String?

    public init(
        macros: [String: String]? = nil,
        maxExpand: Int? = nil,
        maxSourceLength: Int? = nil,
        maxExpandedLength: Int? = nil,
        maxDepth: Int? = nil,
        strict: Bool? = nil,
        displayMode: Bool? = nil,
        compactScripts: Bool? = nil,
        color: String? = nil
    ) {
        self.macros = macros
        self.maxExpand = maxExpand
        self.maxSourceLength = maxSourceLength
        self.maxExpandedLength = maxExpandedLength
        self.maxDepth = maxDepth
        self.strict = strict
        self.displayMode = displayMode
        self.compactScripts = compactScripts
        self.color = color
    }

    /// Extracts the `ParseOptions` subset for `parseLatex` and `expandLatexMacros`.
    public var parseOptions: ParseOptions {
        ParseOptions(
            macros: macros,
            maxExpand: maxExpand,
            maxSourceLength: maxSourceLength,
            maxExpandedLength: maxExpandedLength,
            maxDepth: maxDepth,
            strict: strict
        )
    }
}

/// ECMAScript-compatible `String.prototype.trimEnd()` helper without Foundation dependencies.
internal func latexTrimEnd(_ value: String) -> String {
    var end = value.unicodeScalars.endIndex
    while end > value.unicodeScalars.startIndex {
        let prev = value.unicodeScalars.index(before: end)
        if !latexIsJSWhitespace(value.unicodeScalars[prev]) {
            break
        }
        end = prev
    }
    return String(value.unicodeScalars[..<end])
}

/// Matches ECMAScript `\s` whitespace scalars.
internal func latexIsJSWhitespace(_ scalar: UnicodeScalar) -> Bool {
    switch scalar.value {
    case 0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x0020,
         0x00A0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029,
         0x202F, 0x205F, 0x3000, 0xFEFF:
        return true
    default:
        return false
    }
}
