// Pure Swift 6.2 recursive-descent LaTeX math parser and macro expander (`packages/latex/src/parser.ts`).

private let accentCommands: [String: AccentKind] = [
    "hat": .hat,
    "widehat": .widehat,
    "bar": .bar,
    "overline": .overline,
    "underline": .underline,
    "vec": .vec,
    "tilde": .tilde,
    "widetilde": .tilde,
    "dot": .dot,
    "ddot": .ddot,
]

private let variantCommands: [String: MathVariant] = [
    "mathrm": .normal,
    "textrm": .normal,
    "mathnormal": .normal,
    "mathbf": .bold,
    "boldsymbol": .bold,
    "bm": .bold,
    "mathit": .italic,
    "mathsf": .sans,
    "mathtt": .monospace,
    "mathbb": .doubleStruck,
    "mathcal": .script,
    "mathscr": .script,
    "mathfrak": .fraktur,
]

private let sizingDelimiterCommands: Set<String> = [
    "big", "bigl", "bigr", "bigm",
    "Big", "Bigl", "Bigr", "Bigm",
    "bigg", "biggl", "biggr", "biggm",
    "Bigg", "Biggl", "Biggr", "Biggm",
]

private let ignoredStyleCommands: Set<String> = [
    "limits",
    "nolimits",
    "displaystyle",
    "textstyle",
    "scriptstyle",
    "scriptscriptstyle",
]

private let escapedLiteralCommands: Set<String> = ["%", "#", "$", "&", "_"]

private let textGroupEscapedLiterals: Set<String> = ["{", "}", "%", "#", "$", "&", "_", " "]

private let negatedSymbols: [String: String] = [
    "=": "≠",
    "∈": "∉",
    "∋": "∌",
    "≡": "≢",
    "≈": "≉",
    "∼": "≁",
    "<": "≮",
    ">": "≯",
    "≤": "≰",
    "≥": "≱",
    "⊂": "⊄",
    "⊃": "⊅",
    "⊆": "⊈",
    "⊇": "⊉",
    "∣": "∤",
    "∥": "∦",
]

/// Expands user macros, enforces source-length and nesting-depth bounds, and parses LaTeX math into a `MathNode` AST.
// parity: latex/src/parser.ts#parseLatex [status=implemented hash=4229b2b1ebf9]
public func parseLatex(_ source: String, options: ParseOptions = ParseOptions()) throws -> MathNode {
    let expanded = try expandLatexMacros(source, options: options)
    let maxDepth = try resolvePositiveInteger(options.maxDepth, fallback: DEFAULT_MAX_NESTING_DEPTH, optionName: "maxDepth")
    var parser = LatexParserState(source: expanded, strict: options.strict ?? false, maxDepth: maxDepth)
    return try parser.parse()
}

/// Validates source length and brace nesting, then expands configured user macros up to `maxExpand` passes.
// parity: latex/src/parser.ts#expandLatexMacros [status=implemented hash=bd480af42008]
public func expandLatexMacros(_ source: String, options: ParseOptions = ParseOptions()) throws -> String {
    let maxSourceLength = try resolvePositiveInteger(
        options.maxSourceLength,
        fallback: DEFAULT_MAX_SOURCE_LENGTH,
        optionName: "maxSourceLength"
    )
    let maxExpandedLength = try resolvePositiveInteger(
        options.maxExpandedLength,
        fallback: maxSourceLength,
        optionName: "maxExpandedLength"
    )
    let maxExpand = try resolvePositiveInteger(options.maxExpand, fallback: 100, optionName: "maxExpand")
    let maxDepth = try resolvePositiveInteger(options.maxDepth, fallback: DEFAULT_MAX_NESTING_DEPTH, optionName: "maxDepth")

    try assertSourceLength(source, maximum: maxSourceLength)
    try assertNestingDepth(source, maximum: maxDepth)
    let expanded = try expandMacros(
        source: source,
        macros: options.macros,
        maxExpand: maxExpand,
        maxExpandedLength: maxExpandedLength
    )
    if expanded != source {
        try assertNestingDepth(expanded, maximum: maxDepth)
    }
    return expanded
}

private func isCommandLetter(_ scalar: UnicodeScalar) -> Bool {
    let v = scalar.value
    return (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) || v == 0x40 // A-Z, a-z, @
}

private func isJSLineTerminator(_ scalar: UnicodeScalar) -> Bool {
    let v = scalar.value
    return v == 0x0A || v == 0x0D || v == 0x2028 || v == 0x2029
}

private func expandMacros(
    source: String,
    macros: [String: String]?,
    maxExpand: Int,
    maxExpandedLength: Int
) throws -> String {
    try assertSourceLength(source, maximum: maxExpandedLength, label: "Expanded LaTeX source")
    guard let macros, !macros.isEmpty else { return source }

    var result = source
    for _ in 0..<maxExpand {
        let scalars = Array(result.unicodeScalars)
        var changed = false
        var cursor = 0
        var outputLength = 0
        var output: [String] = []

        var i = 0
        while i < scalars.count {
            if scalars[i].value != 0x5C { // '\'
                i += 1
                continue
            }
            let nextIdx = i + 1
            guard nextIdx < scalars.count else {
                i += 1
                continue
            }
            let matchEnd: Int
            if isCommandLetter(scalars[nextIdx]) {
                var end = nextIdx + 1
                while end < scalars.count && isCommandLetter(scalars[end]) {
                    end += 1
                }
                matchEnd = end
            } else if !isJSLineTerminator(scalars[nextIdx]) {
                matchEnd = nextIdx + 1
            } else {
                i += 1
                continue
            }

            let command = String(String.UnicodeScalarView(scalars[i..<matchEnd]))
            let bareName = String(String.UnicodeScalarView(scalars[nextIdx..<matchEnd]))
            if let replacement = macros[command] ?? macros[bareName] {
                let prefix = String(String.UnicodeScalarView(scalars[cursor..<i]))
                try appendWithinLimit(&output, value: prefix, currentLength: &outputLength, maximum: maxExpandedLength)
                try appendWithinLimit(&output, value: replacement, currentLength: &outputLength, maximum: maxExpandedLength)
                cursor = matchEnd
                changed = true
            }
            i = matchEnd
        }

        if !changed {
            return result
        }
        let tail = String(String.UnicodeScalarView(scalars[cursor...]))
        try appendWithinLimit(&output, value: tail, currentLength: &outputLength, maximum: maxExpandedLength)
        result = output.joined()
    }

    throw LatexParseError("Macro expansion exceeded \(maxExpand) passes", position: 0)
}

private func appendWithinLimit(
    _ output: inout [String],
    value: String,
    currentLength: inout Int,
    maximum: Int
) throws {
    let added = value.utf16.count
    if currentLength + added > maximum {
        throw LatexParseError("Expanded LaTeX source exceeds the \(maximum)-character limit", position: maximum)
    }
    output.append(value)
    currentLength += added
}

private struct LatexParserState {
    private let scalars: [UnicodeScalar]
    private let utf16Offsets: [Int]
    private let strict: Bool
    private let maxDepth: Int
    private var position: Int = 0
    private var depth: Int = 0

    init(source: String, strict: Bool, maxDepth: Int) {
        var scalarList: [UnicodeScalar] = []
        var offsets: [Int] = []
        scalarList.reserveCapacity(source.unicodeScalars.count)
        offsets.reserveCapacity(source.unicodeScalars.count + 1)
        var utf16Pos = 0
        for scalar in source.unicodeScalars {
            offsets.append(utf16Pos)
            scalarList.append(scalar)
            utf16Pos += scalar.utf16.count
        }
        offsets.append(utf16Pos)
        self.scalars = scalarList
        self.utf16Offsets = offsets
        self.strict = strict
        self.maxDepth = maxDepth
    }

    mutating func parse() throws -> MathNode {
        let body = try parseRow()
        skipMathWhitespace()
        if !done() {
            try fail("Unexpected \"\(peekString())\"")
        }
        return makeRow(body)
    }

    private mutating func parseRow(stop: ((LatexParserState) -> Bool)? = nil) throws -> [MathNode] {
        var body: [MathNode] = []

        while !done() {
            skipMathWhitespace()
            if done() { break }
            if let stop, stop(self) { break }

            let current = peekScalar()!
            if current == "}" { break }

            if current == "^" || current == "_" {
                position += 1
                let script = try parseArgument()
                let previous = body.popLast() ?? .row([])
                let updated: MathNode
                if case .scripts(let base, let existingSup, let existingSub) = previous {
                    if current == "^" {
                        updated = .scripts(base: base, superscript: script, subscript: existingSub)
                    } else {
                        updated = .scripts(base: base, superscript: existingSup, subscript: script)
                    }
                } else {
                    if current == "^" {
                        updated = .scripts(base: previous, superscript: script, subscript: nil)
                    } else {
                        updated = .scripts(base: previous, superscript: nil, subscript: script)
                    }
                }
                body.append(updated)
                continue
            }

            if current == "\\" && applyLimitsModifier(&body) {
                continue
            }
            body.append(try parseAtom())
        }

        return body
    }

    private mutating func parseAtom() throws -> MathNode {
        depth += 1
        if depth > maxDepth {
            depth -= 1
            try fail("LaTeX nesting exceeds the \(maxDepth)-level limit")
        }
        defer { depth -= 1 }
        return try parseAtomInner()
    }

    private mutating func parseAtomInner() throws -> MathNode {
        let current = peekScalar()!
        if current == "{" { return try parseGroup() }
        if current == "\\" { return try parseCommand() }
        if current == "~" {
            position += 1
            return .space(width: 1)
        }

        position += 1
        let value = String(current)
        return .symbol(value: value, role: inferRole(value))
    }

    private mutating func parseCommand() throws -> MathNode {
        let start = position
        let command = try readCommand()

        if command == "\\" {
            return .row([])
        }
        if command == "begin" {
            return try parseEnvironment()
        }
        if command == "frac" || command == "dfrac" || command == "tfrac" || command == "cfrac" {
            skipMathWhitespace()
            var numeratorAlign: FractionNumeratorAlign? = nil
            if command == "cfrac" && peekScalar() == "[" {
                if startsWith("[]") {
                    position += 2
                } else if startsWith("[l]") {
                    position += 3
                    numeratorAlign = .left
                } else if startsWith("[r]") {
                    position += 3
                    numeratorAlign = .right
                } else {
                    try fail("Unsupported \\cfrac alignment; expected [l], [r], or []")
                }
            }
            let numerator = try parseArgument()
            let denominator = try parseArgument()
            return .fraction(numerator: numerator, denominator: denominator, bar: true, numeratorAlign: numeratorAlign)
        }
        if command == "binom" || command == "dbinom" || command == "tbinom" {
            let numerator = try parseArgument()
            let denominator = try parseArgument()
            let fraction: MathNode = .fraction(numerator: numerator, denominator: denominator, bar: false, numeratorAlign: nil)
            return .delimited(left: "(", body: fraction, right: ")")
        }
        if command == "sqrt" {
            let index = try parseOptionalArgument()
            let body = try parseArgument()
            return .root(body: body, index: index)
        }
        if command == "left" {
            return try parseLeftRight()
        }
        if command == "middle" {
            return .symbol(value: try readDelimiter(), role: nil)
        }
        if command == "right" {
            position = start
            try fail("Unexpected \\right")
        }
        if let accent = accentCommands[command] {
            return .accent(accent: accent, body: try parseArgument())
        }
        if let variant = variantCommands[command] {
            let body: MathNode = command == "textrm" ? .text(try readTextGroup()) : try parseArgument()
            return .variant(variant: variant, body: body)
        }
        if command == "text" || command == "mbox" {
            return .text(try readTextGroup())
        }
        if command == "operatorname" {
            let limits = peekScalar() == "*"
            if limits {
                position += 1
            }
            return .operator(value: try readTextGroup(), limits: limits)
        }
        if command == "overset" || command == "stackrel" {
            let over = try parseArgument()
            let base = try parseArgument()
            return .overunder(base: base, over: over, under: nil)
        }
        if command == "underset" {
            let under = try parseArgument()
            let base = try parseArgument()
            return .overunder(base: base, over: nil, under: under)
        }
        if command == "overbrace" || command == "underbrace" {
            return .brace(body: try parseArgument(), position: command == "overbrace" ? .over : .under)
        }
        if command == "textcolor" {
            let color = try readRawGroup()
            return .color(color: color, body: try parseArgument())
        }
        if command == "color" {
            let color = try readRawGroup()
            return .color(color: color, body: makeRow(try parseRow()))
        }
        if command == "not" {
            let target = try parseAtom()
            if case .symbol(let value, let role) = target {
                return .symbol(value: negateSymbol(value), role: role)
            }
            return .row([.symbol(value: "¬", role: nil), target])
        }
        if command == "pmod" {
            return .row([
                .space(width: 1),
                .text("(mod "),
                try parseArgument(),
                .text(")"),
            ])
        }
        if command == "mod" || command == "bmod" {
            return .operator(value: "mod", limits: false)
        }
        if command == "displaylines" {
            skipMathWhitespace()
            try expect("{")
            return try parseMatrix(environment: .gathered, end: "}", columns: nil)
        }
        if ignoredStyleCommands.contains(command) {
            return .row([])
        }
        if sizingDelimiterCommands.contains(command) {
            return .symbol(value: try readDelimiter(), role: nil)
        }
        if let width = spacingCommands[command] {
            return .space(width: width)
        }
        if let symbol = symbolTable[command] {
            return .symbol(value: symbol.value, role: symbol.role)
        }
        if let op = largeOperators[command] {
            return .operator(value: op, limits: !command.contains("int"))
        }
        if namedOperators.contains(command) {
            let limits = command.hasPrefix("lim") || command == "min" || command == "max"
            return .operator(value: command, limits: limits)
        }
        if command == "backslash" {
            return .symbol(value: "\\", role: nil)
        }
        if let delimiter = delimiterTable["\\\(command)"] ?? delimiterTable[command] {
            return .symbol(value: delimiter, role: nil)
        }
        if command == "{" || command == "}" {
            return .symbol(value: command, role: nil)
        }
        if escapedLiteralCommands.contains(command) {
            return .symbol(value: command, role: nil)
        }

        if strict {
            try fail("Unsupported command \\\(command)", at: start)
        }
        return .text("\\\(command)")
    }

    private mutating func parseEnvironment() throws -> MathNode {
        let rawEnvironment = try readRawGroup()
        let unstarred = rawEnvironment.hasSuffix("*") ? String(rawEnvironment.dropLast()) : rawEnvironment
        guard let environment = MatrixEnvironment(rawValue: unstarred) else {
            if strict {
                try fail("Unsupported environment \(unstarred)")
            }
            let content = try readUntilEnd(rawEnvironment)
            return .text(content)
        }

        var columns: String? = nil
        if environment == .array {
            let rawColumns = try readRawGroup()
            let cleaned = String(rawColumns.unicodeScalars.filter { !latexIsJSWhitespace($0) })
            let hasOnlyValidChars = !cleaned.isEmpty && cleaned.unicodeScalars.allSatisfy { s in
                s == "l" || s == "c" || s == "r" || s == "|"
            }
            let hasColumn = cleaned.unicodeScalars.contains { s in
                s == "l" || s == "c" || s == "r"
            }
            if !hasOnlyValidChars || !hasColumn {
                try fail("Unsupported array columns; expected l, c, r, and |")
            }
            columns = cleaned
        }

        return try parseMatrix(environment: environment, end: "\\end{\(rawEnvironment)}", columns: columns)
    }

    private mutating func parseMatrix(
        environment: MatrixEnvironment,
        end: String,
        columns: String?
    ) throws -> MathNode {
        var rows: [[MathNode]] = []
        var cells: [MathNode] = []

        while !done() {
            skipMathWhitespace()
            if startsWith(end) && cells.isEmpty { break }

            let cellStart = position
            let cell = makeRow(try parseRow { state in
                state.peekScalar() == "&" || state.startsWith("\\\\") || state.startsWith(end)
            })
            cells.append(cell)
            skipMathWhitespace()

            if peekScalar() == "&" {
                position += 1
                continue
            }
            if startsWith("\\\\") {
                position += 2
                consumeOptionalBracket()
                rows.append(cells)
                cells = []
                continue
            }
            if startsWith(end) { break }
            // Empty cells are valid only when a cell, row, or closing delimiter advances the parser.
            if position == cellStart {
                try fail("Unexpected \"\(peekString())\" in \(environment.rawValue)")
            }
        }

        if !startsWith(end) {
            try fail("Missing \(end)")
        }
        try expect(end)
        if !cells.isEmpty || rows.isEmpty {
            rows.append(cells)
        }
        return .matrix(rows: rows, environment: environment, columns: columns)
    }

    private mutating func parseLeftRight() throws -> MathNode {
        let left = try readDelimiter()
        let isAtRight: (LatexParserState) -> Bool = { state in
            guard state.startsWith("\\right") else { return false }
            let nextIdx = state.position + 6
            if nextIdx >= state.scalars.count { return true }
            return !isCommandLetter(state.scalars[nextIdx])
        }
        let body = makeRow(try parseRow(stop: isAtRight))
        if !isAtRight(self) {
            try fail("Missing \\right")
        }
        _ = try readCommand()
        let right = try readDelimiter()
        return .delimited(left: left, body: body, right: right)
    }

    private mutating func parseArgument() throws -> MathNode {
        skipMathWhitespace()
        if peekScalar() == "{" { return try parseGroup() }
        if done() { try fail("Expected an argument") }
        return try parseAtom()
    }

    private mutating func parseGroup() throws -> MathNode {
        try expect("{")
        let body = makeRow(try parseRow())
        try expect("}")
        return body
    }

    private mutating func parseOptionalArgument() throws -> MathNode? {
        skipMathWhitespace()
        if peekScalar() != "[" { return nil }
        position += 1
        let body = makeRow(try parseRow { $0.peekScalar() == "]" })
        try expect("]")
        return body
    }

    private mutating func consumeOptionalBracket() {
        skipMathWhitespace()
        if peekScalar() != "[" { return }
        var bracketDepth = 0
        while !done() {
            let ch = scalars[position]
            position += 1
            if ch == "[" { bracketDepth += 1 }
            if ch == "]" {
                bracketDepth -= 1
                if bracketDepth == 0 { return }
            }
        }
    }

    private mutating func readDelimiter() throws -> String {
        skipMathWhitespace()
        if done() { try fail("Expected a delimiter") }
        let start = position
        if peekScalar() == "\\" {
            let command = try readCommand()
            if let delimiter = delimiterTable["\\\(command)"] ?? delimiterTable[command] {
                return delimiter
            }
            if strict {
                try fail("Unsupported delimiter \\\(command)", at: start)
            }
            return "\\\(command)"
        }
        let token = String(scalars[position])
        position += 1
        return delimiterTable[token] ?? token
    }

    private mutating func readCommand() throws -> String {
        try expect("\\")
        if done() { return "\\" }
        let next = scalars[position]
        if !isCommandLetter(next) {
            position += 1
            return String(next)
        }
        let start = position
        while !done() && isCommandLetter(scalars[position]) {
            position += 1
        }
        let command = slice(start..<position)
        if peekScalar() == " " {
            position += 1
        }
        return command
    }

    private mutating func readRawGroup() throws -> String {
        skipMathWhitespace()
        try expect("{")
        let start = position
        var groupDepth = 1
        while !done() {
            let idx = position
            let ch = scalars[idx]
            position += 1
            let escaped = (ch == "{" || ch == "}") && isEscaped(idx)
            if ch == "{" && !escaped {
                groupDepth += 1
            }
            if ch == "}" && !escaped {
                groupDepth -= 1
                if groupDepth == 0 {
                    return slice(start..<(position - 1))
                }
            }
        }
        try fail("Unterminated group", at: start)
    }

    private mutating func applyLimitsModifier(_ body: inout [MathNode]) -> Bool {
        let isLimits: Bool
        let length: Int
        if startsWith("\\limits") {
            isLimits = true
            length = 7
        } else if startsWith("\\nolimits") {
            isLimits = false
            length = 9
        } else {
            return false
        }
        let afterIdx = position + length
        if afterIdx < scalars.count && isCommandLetter(scalars[afterIdx]) {
            return false
        }
        position += length

        guard let lastIndex = body.indices.last else { return true }
        switch body[lastIndex] {
        case .operator(let value, _):
            body[lastIndex] = .operator(value: value, limits: isLimits)
        case .scripts(.operator(let value, _), let sup, let sub):
            body[lastIndex] = .scripts(base: .operator(value: value, limits: isLimits), superscript: sup, subscript: sub)
        default:
            break
        }
        return true
    }

    private func isEscaped(_ index: Int) -> Bool {
        var slashCount = 0
        var cursor = index - 1
        while cursor >= 0 && scalars[cursor] == "\\" {
            slashCount += 1
            cursor -= 1
        }
        return (slashCount % 2) == 1
    }

    private mutating func readTextGroup() throws -> String {
        let raw = try readRawGroup()
        let rawScalars = Array(raw.unicodeScalars)
        var replaced = ""
        replaced.reserveCapacity(raw.count)

        var i = 0
        while i < rawScalars.count {
            if rawScalars[i] == "\\" && i + 1 < rawScalars.count {
                let nextIdx = i + 1
                let matchEnd: Int
                if isCommandLetter(rawScalars[nextIdx]) {
                    var end = nextIdx + 1
                    while end < rawScalars.count && isCommandLetter(rawScalars[end]) {
                        end += 1
                    }
                    matchEnd = end
                } else if !isJSLineTerminator(rawScalars[nextIdx]) {
                    matchEnd = nextIdx + 1
                } else {
                    replaced.unicodeScalars.append(rawScalars[i])
                    i += 1
                    continue
                }
                let command = String(String.UnicodeScalarView(rawScalars[nextIdx..<matchEnd]))
                if textGroupEscapedLiterals.contains(command) {
                    replaced.append(command)
                } else if command == "textbackslash" {
                    replaced.append("\\")
                } else if command == "!" {
                    // Negative thin space is omitted in text groups.
                } else if let width = spacingCommands[command] {
                    replaced.append(String(repeating: " ", count: max(1, width)))
                } else {
                    replaced.append(String(String.UnicodeScalarView(rawScalars[i..<matchEnd])))
                }
                i = matchEnd
                continue
            }
            replaced.unicodeScalars.append(rawScalars[i])
            i += 1
        }

        var result = ""
        result.reserveCapacity(replaced.count)
        for scalar in replaced.unicodeScalars {
            if scalar == "~" {
                result.append(" ")
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private mutating func readUntilEnd(_ environment: String) throws -> String {
        let marker = "\\end{\(environment)}"
        let markerScalars = Array(marker.unicodeScalars)
        var search = position
        while search + markerScalars.count <= scalars.count {
            var matched = true
            for offset in 0..<markerScalars.count {
                if scalars[search + offset] != markerScalars[offset] {
                    matched = false
                    break
                }
            }
            if matched {
                let content = slice(position..<search)
                position = search + markerScalars.count
                return content
            }
            search += 1
        }
        try fail("Missing \(marker)")
    }

    private mutating func skipMathWhitespace() {
        while !done() {
            let current = scalars[position]
            if latexIsJSWhitespace(current) {
                position += 1
                continue
            }
            if current == "%" {
                while !done() && scalars[position] != "\n" {
                    position += 1
                }
                continue
            }
            break
        }
    }

    private mutating func expect(_ value: String) throws {
        if !startsWith(value) {
            try fail("Expected \"\(value)\"")
        }
        position += value.unicodeScalars.count
    }

    private func startsWith(_ value: String) -> Bool {
        let target = value.unicodeScalars
        var idx = position
        for scalar in target {
            guard idx < scalars.count, scalars[idx] == scalar else { return false }
            idx += 1
        }
        return true
    }

    private func slice(_ range: Range<Int>) -> String {
        String(String.UnicodeScalarView(scalars[range]))
    }

    private func peekScalar() -> UnicodeScalar? {
        position < scalars.count ? scalars[position] : nil
    }

    private func peekString() -> String {
        guard let scalar = peekScalar() else { return "" }
        return String(scalar)
    }

    private func done() -> Bool {
        position >= scalars.count
    }

    private func fail(_ message: String, at scalarIndex: Int? = nil) throws -> Never {
        let idx = scalarIndex ?? position
        let offset = idx < utf16Offsets.count ? utf16Offsets[idx] : (utf16Offsets.last ?? 0)
        throw LatexParseError(message, position: offset)
    }
}

private func makeRow(_ body: [MathNode]) -> MathNode {
    if body.count == 1 { return body[0] }
    return .row(body)
}

private func inferRole(_ value: String) -> SymbolRole {
    switch value {
    case "+", "-", "*", "/", "×", "÷", "±", "∓":
        return .binary
    case "=", "<", ">", "≤", "≥", "≠", "≈", "∈", "∉", "⊂", "⊃":
        return .relation
    case ",", ";", ":":
        return .punctuation
    case "(", "[", "{":
        return .opening
    case ")", "]", "}":
        return .closing
    default:
        return .ordinary
    }
}

private func negateSymbol(_ value: String) -> String {
    negatedSymbols[value] ?? "\(value)\u{0338}"
}
