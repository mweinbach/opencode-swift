// Pure Swift 6.2 2D Unicode box layout engine for LaTeX math ASTs (`packages/latex/src/layout.ts`).

private struct MathBox {
    var width: Int
    var height: Int
    var baseline: Int
    var cells: [[MathCell?]]
}

private struct LayoutContext {
    var displayMode: Bool
    var compactScripts: Bool
    var style: MathStyle?
    var variant: MathVariant?
}

private let superscriptGlyphs: [UnicodeScalar: String] = [
    "0": "⁰",
    "1": "¹",
    "2": "²",
    "3": "³",
    "4": "⁴",
    "5": "⁵",
    "6": "⁶",
    "7": "⁷",
    "8": "⁸",
    "9": "⁹",
    "+": "⁺",
    "-": "⁻",
    "=": "⁼",
    "(": "⁽",
    ")": "⁾",
    "n": "ⁿ",
    "i": "ⁱ",
]

private let subscriptGlyphs: [UnicodeScalar: String] = [
    "0": "₀",
    "1": "₁",
    "2": "₂",
    "3": "₃",
    "4": "₄",
    "5": "₅",
    "6": "₆",
    "7": "₇",
    "8": "₈",
    "9": "₉",
    "+": "₊",
    "-": "₋",
    "=": "₌",
    "(": "₍",
    ")": "₎",
    "a": "ₐ",
    "e": "ₑ",
    "h": "ₕ",
    "i": "ᵢ",
    "j": "ⱼ",
    "k": "ₖ",
    "l": "ₗ",
    "m": "ₘ",
    "n": "ₙ",
    "o": "ₒ",
    "p": "ₚ",
    "r": "ᵣ",
    "s": "ₛ",
    "t": "ₜ",
    "u": "ᵤ",
    "v": "ᵥ",
    "x": "ₓ",
]

private let doubleStruckExceptions: [UnicodeScalar: String] = [
    "C": "ℂ",
    "H": "ℍ",
    "N": "ℕ",
    "P": "ℙ",
    "Q": "ℚ",
    "R": "ℝ",
    "Z": "ℤ",
]

private let scriptExceptions: [UnicodeScalar: String] = [
    "B": "ℬ",
    "E": "ℰ",
    "F": "ℱ",
    "H": "ℋ",
    "I": "ℐ",
    "L": "ℒ",
    "M": "ℳ",
    "R": "ℛ",
    "e": "ℯ",
    "g": "ℊ",
    "o": "ℴ",
]

private let frakturExceptions: [UnicodeScalar: String] = [
    "C": "ℭ",
    "H": "ℌ",
    "I": "ℑ",
    "R": "ℜ",
    "Z": "ℨ",
]

/// Lays out a parsed `MathNode` AST onto a 2D terminal character grid with math-axis baseline tracking.
// parity: latex/src/layout.ts#layoutMath [status=implemented hash=b88f3f6a8889]
public func layoutMath(_ node: MathNode, options: RenderLatexOptions = RenderLatexOptions()) -> MathLayout {
    let context = LayoutContext(
        displayMode: options.displayMode ?? true,
        compactScripts: options.compactScripts ?? true,
        style: options.color.map { MathStyle(color: $0) },
        variant: nil
    )
    let box = layoutNode(node, context: context)
    return MathLayout(width: box.width, height: box.height, baseline: box.baseline, cells: box.cells)
}

private func layoutNode(_ node: MathNode, context: LayoutContext) -> MathBox {
    switch node {
    case .row(let body):
        return layoutRow(body, context: context)
    case .symbol(let value, _), .text(let value), .operator(let value, _):
        return textBox(applyVariant(value, variant: context.variant), style: context.style)
    case .space(let width):
        return blankBox(width: width, height: 1, baseline: 0)
    case .fraction(let numerator, let denominator, let bar, let numeratorAlign):
        return layoutFraction(
            numerator: numerator,
            denominator: denominator,
            bar: bar,
            numeratorAlign: numeratorAlign,
            context: context
        )
    case .root(let body, let index):
        return layoutRoot(bodyNode: body, indexNode: index, context: context)
    case .scripts(let base, let superscript, let sub):
        return layoutScripts(baseNode: base, superscriptNode: superscript, subscriptNode: sub, context: context)
    case .delimited(let left, let body, let right):
        return layoutDelimited(left: left, bodyNode: body, right: right, context: context)
    case .matrix(let rows, let environment, let columns):
        return layoutMatrix(rows: rows, environment: environment, columns: columns, context: context)
    case .brace(let body, let position):
        return layoutBrace(bodyNode: body, position: position, context: context)
    case .accent(let accent, let body):
        return layoutAccent(accent: accent, bodyNode: body, context: context)
    case .variant(let variant, let body):
        return layoutNode(body, context: withVariant(context, variant: variant))
    case .overunder(let base, let over, let under):
        return layoutOverUnder(baseNode: base, overNode: over, underNode: under, context: context)
    case .color(let color, let body):
        var updatedStyle = context.style ?? MathStyle()
        updatedStyle.color = color
        var nextContext = context
        nextContext.style = updatedStyle
        return layoutNode(body, context: nextContext)
    }
}

private func layoutRow(_ nodes: [MathNode], context: LayoutContext) -> MathBox {
    if nodes.isEmpty {
        return blankBox(width: 0, height: 1, baseline: 0)
    }

    var boxes: [MathBox] = []
    boxes.reserveCapacity(nodes.count)
    var previousRole: SymbolRole? = nil

    for index in nodes.indices {
        let node = nodes[index]
        let rawRole = nodeRole(node)
        let role = normalizeBinaryRole(rawRole, previous: previousRole, next: nextSignificantRole(nodes, start: index + 1))
        if needsMathSpace(previous: previousRole, current: role, count: boxes.count) {
            boxes.append(blankBox(width: 1, height: 1, baseline: 0))
        }
        boxes.append(layoutNode(node, context: context))
        if case .space = node {
            // Explicit spacing atoms do not reset semantic role tracking.
        } else {
            previousRole = role ?? .ordinary
        }
    }

    return hpack(boxes)
}

private func layoutFraction(
    numerator numeratorNode: MathNode,
    denominator denominatorNode: MathNode,
    bar: Bool,
    numeratorAlign: FractionNumeratorAlign?,
    context: LayoutContext
) -> MathBox {
    let numerator = layoutNode(numeratorNode, context: context)
    let denominator = layoutNode(denominatorNode, context: context)
    let width = max(numerator.width, denominator.width) + 2
    // Barless fractions (binomials) still reserve an axis row so surrounding
    // atoms and their stretching parentheses align between the two entries.
    let gap = 1
    let height = numerator.height + denominator.height + gap
    // TeX places a fraction's math axis on its rule (or the equivalent empty
    // axis row for a binomial). Align neighbors there, not on the denominator.
    let baseline = numerator.height
    var result = blankBox(width: width, height: height, baseline: baseline)

    let numeratorX: Int
    switch numeratorAlign {
    case .left:
        numeratorX = 1
    case .right:
        numeratorX = width - numerator.width - 1
    case nil:
        numeratorX = (width - numerator.width) / 2
    }
    overlay(&result, source: numerator, x: numeratorX, y: 0)
    if bar {
        drawHorizontal(&result, y: numerator.height, x: 0, width: width, char: "─", style: context.style)
    }
    overlay(&result, source: denominator, x: (width - denominator.width) / 2, y: numerator.height + gap)
    return result
}

private func layoutRoot(bodyNode: MathNode, indexNode: MathNode?, context: LayoutContext) -> MathBox {
    let body = layoutNode(bodyNode, context: context)
    let index = indexNode.map { layoutNode($0, context: context) }
    let indexWidth = index.map { max(0, $0.width - 1) } ?? 0
    // The index ends beside the overbar, never inside the hook or radicand.
    let top = max(0, (index?.height ?? 1) - 1)
    let bodyX = indexWidth + 2
    let width = bodyX + body.width
    let height = top + body.height + 1
    let baseline = top + body.baseline + 1
    var result = blankBox(width: width, height: height, baseline: baseline)

    setCell(&result, x: bodyX - 1, y: top, char: "╭", style: context.style)
    drawHorizontal(&result, y: top, x: bodyX, width: body.width, char: "─", style: context.style)
    if top + 1 < height - 1 {
        for y in (top + 1)..<(height - 1) {
            setCell(&result, x: bodyX - 1, y: y, char: "│", style: context.style)
        }
    }
    setCell(&result, x: bodyX - 2, y: height - 1, char: "╰", style: context.style)
    setCell(&result, x: bodyX - 1, y: height - 1, char: "╯", style: context.style)
    overlay(&result, source: body, x: bodyX, y: top + 1)
    if let index {
        overlay(&result, source: index, x: 0, y: 0)
    }
    return result
}

private func layoutScripts(
    baseNode: MathNode,
    superscriptNode rawSuperscript: MathNode?,
    subscriptNode rawSubscript: MathNode?,
    context: LayoutContext
) -> MathBox {
    let superscriptNode: MathNode? = rawSuperscript.flatMap { simpleNodeText($0) == "" ? nil : $0 }
    let subscriptNode: MathNode? = rawSubscript.flatMap { simpleNodeText($0) == "" ? nil : $0 }

    let usesOverUnder: Bool
    switch baseNode {
    case .brace:
        usesOverUnder = true
    case .operator(_, let limits):
        usesOverUnder = limits && context.displayMode
    default:
        usesOverUnder = false
    }
    if usesOverUnder {
        return layoutOverUnder(baseNode: baseNode, overNode: superscriptNode, underNode: subscriptNode, context: context)
    }

    let base = layoutNode(baseNode, context: context)
    if context.compactScripts && base.height == 1 {
        let supText: String? = superscriptNode.map(simpleNodeText) ?? ""
        let subText: String? = subscriptNode.map(simpleNodeText) ?? ""
        if let compactSup = mapScript(supText, table: superscriptGlyphs),
           let compactSub = mapScript(subText, table: subscriptGlyphs)
        {
            return hpack([base, textBox(compactSup + compactSub, style: context.style)])
        }
    }

    let superscript = superscriptNode.map { layoutNode($0, context: context) }
    let sub = subscriptNode.map { layoutNode($0, context: context) }
    let scriptWidth = max(superscript?.width ?? 0, sub?.width ?? 0)
    let topHeight = superscript?.height ?? 0
    let bottomHeight = sub?.height ?? 0
    let width = base.width + scriptWidth
    let height = topHeight + base.height + bottomHeight
    let baseline = topHeight + base.baseline
    var result = blankBox(width: width, height: height, baseline: baseline)

    overlay(&result, source: base, x: 0, y: topHeight)
    if let superscript {
        overlay(&result, source: superscript, x: base.width, y: 0)
    }
    if let sub {
        overlay(&result, source: sub, x: base.width, y: topHeight + base.height)
    }
    return result
}

private func layoutOverUnder(
    baseNode: MathNode,
    overNode: MathNode?,
    underNode: MathNode?,
    context: LayoutContext
) -> MathBox {
    let base = layoutNode(baseNode, context: context)
    let over = overNode.map { layoutNode($0, context: context) }
    let under = underNode.map { layoutNode($0, context: context) }
    let width = max(base.width, over?.width ?? 0, under?.width ?? 0)
    let overHeight = over?.height ?? 0
    let height = overHeight + base.height + (under?.height ?? 0)
    let baseline = overHeight + base.baseline
    var result = blankBox(width: width, height: height, baseline: baseline)

    if let over {
        overlay(&result, source: over, x: (width - over.width) / 2, y: 0)
    }
    overlay(&result, source: base, x: (width - base.width) / 2, y: overHeight)
    if let under {
        overlay(&result, source: under, x: (width - under.width) / 2, y: overHeight + base.height)
    }
    return result
}

private func layoutDelimited(left: String, bodyNode: MathNode, right: String, context: LayoutContext) -> MathBox {
    let body = layoutNode(bodyNode, context: context)
    let leftBox = delimiterBox(left, height: body.height, baseline: body.baseline, left: true, style: context.style)
    let rightBox = delimiterBox(right, height: body.height, baseline: body.baseline, left: false, style: context.style)
    return hpack([leftBox, body, rightBox])
}

private func parseArrayColumnSpec(_ spec: String?) -> (columns: [Character]?, rules: [Int]) {
    guard let spec else { return (nil, []) }
    var columns: [Character] = []
    var rules: [Int] = []
    var currentBars = 0
    for ch in spec {
        if ch == "l" || ch == "c" || ch == "r" {
            rules.append(currentBars)
            currentBars = 0
            columns.append(ch)
        } else {
            currentBars += 1
        }
    }
    rules.append(currentBars)
    return (columns.isEmpty ? nil : columns, rules)
}

private func layoutMatrix(
    rows: [[MathNode]],
    environment: MatrixEnvironment,
    columns columnSpec: String?,
    context: LayoutContext
) -> MathBox {
    let cellRows: [[MathBox]] = rows.map { row in
        row.map { layoutNode($0, context: context) }
    }
    let (columns, rules) = parseArrayColumnSpec(columnSpec)
    let maxRowColumns = cellRows.map(\.count).max() ?? 0
    let columnCount = max(columns?.count ?? 0, maxRowColumns)

    let columnWidths: [Int] = (0..<columnCount).map { column in
        cellRows.map { row in
            column < row.count ? row[column].width : 0
        }.max() ?? 0
    }
    let rowAscents: [Int] = cellRows.map { row in
        row.map(\.baseline).max() ?? 0
    }
    let rowDescents: [Int] = cellRows.map { row in
        row.map { $0.height - $0.baseline - 1 }.max() ?? 0
    }
    let rowHeights: [Int] = rowAscents.indices.map { index in
        rowAscents[index] + 1 + rowDescents[index]
    }

    let aligned = environment == .aligned || environment == .align
    let columnGap = (environment == .cases || aligned) ? 2 : 1
    let gaps: [Int] = (0...columnCount).map { boundary in
        let edge = boundary == 0 || boundary == columnCount
        let ruleCount = boundary < rules.count ? rules[boundary] : 0
        if ruleCount > 0 {
            return ruleCount + (edge ? 1 : 2)
        }
        return edge ? 0 : columnGap
    }

    let width = columnWidths.reduce(0, +) + gaps.reduce(0, +)
    let height = max(1, rowHeights.reduce(0, +) + max(0, rows.count - 1))
    var result = blankBox(width: width, height: height, baseline: height / 2)

    var y = 0
    for rowIndex in cellRows.indices {
        var x = gaps[0]
        let cells = cellRows[rowIndex]
        for column in 0..<columnCount {
            let columnWidth = columnWidths[column]
            if column < cells.count {
                let cell = cells[column]
                let alignment: Character
                if let columns, column < columns.count {
                    alignment = columns[column]
                } else if environment == .cases {
                    alignment = "l"
                } else if aligned {
                    alignment = (column % 2 == 0) ? "r" : "l"
                } else {
                    alignment = "c"
                }
                let offsetX: Int
                if alignment == "l" {
                    offsetX = 0
                } else if alignment == "r" {
                    offsetX = columnWidth - cell.width
                } else {
                    offsetX = (columnWidth - cell.width) / 2
                }
                let cellY = y + rowAscents[rowIndex] - cell.baseline
                overlay(&result, source: cell, x: x + offsetX, y: cellY)
            }
            x += columnWidth + gaps[column + 1]
        }
        y += rowHeights[rowIndex] + 1
    }

    var boundaryX = 0
    for boundary in 0...columnCount {
        let ruleCount = boundary < rules.count ? rules[boundary] : 0
        for rule in 0..<ruleCount {
            let ruleX = boundaryX + (boundary == 0 ? 0 : 1) + rule
            for row in 0..<height {
                setCell(&result, x: ruleX, y: row, char: "│", style: context.style)
            }
        }
        boundaryX += gaps[boundary] + (boundary < columnWidths.count ? columnWidths[boundary] : 0)
    }

    if let (leftDelim, rightDelim) = matrixDelimiters(environment) {
        return hpack([
            delimiterBox(leftDelim, height: height, baseline: result.baseline, left: true, style: context.style),
            result,
            delimiterBox(rightDelim, height: height, baseline: result.baseline, left: false, style: context.style),
        ])
    }
    return result
}

private func layoutBrace(bodyNode: MathNode, position: BracePosition, context: LayoutContext) -> MathBox {
    let body = layoutNode(bodyNode, context: context)
    let over = position == .over
    let width = max(3, body.width)
    var result = blankBox(width: width, height: body.height + 1, baseline: body.baseline + (over ? 1 : 0))
    let y = over ? 0 : body.height
    overlay(&result, source: body, x: (width - body.width) / 2, y: over ? 1 : 0)
    drawHorizontal(&result, y: y, x: 0, width: width, char: "─", style: context.style)
    setCell(&result, x: 0, y: y, char: over ? "╭" : "╰", style: context.style)
    setCell(&result, x: width - 1, y: y, char: over ? "╮" : "╯", style: context.style)
    setCell(&result, x: (width - 1) / 2, y: y, char: over ? "┴" : "┬", style: context.style)
    return result
}

private func layoutAccent(accent: AccentKind, bodyNode: MathNode, context: LayoutContext) -> MathBox {
    let body = layoutNode(bodyNode, context: context)
    if accent == .underline {
        var result = blankBox(width: body.width, height: body.height + 1, baseline: body.baseline)
        overlay(&result, source: body, x: 0, y: 0)
        drawHorizontal(&result, y: body.height, x: 0, width: body.width, char: "─", style: context.style)
        return result
    }

    var result = blankBox(width: body.width, height: body.height + 1, baseline: body.baseline + 1)
    overlay(&result, source: body, x: 0, y: 1)
    let mark: String
    switch accent {
    case .hat, .widehat:
        mark = body.width == 1 ? "^" : "⌢"
    case .bar, .overline:
        mark = "─"
    case .vec:
        mark = "→"
    case .tilde:
        mark = "~"
    case .dot:
        mark = "·"
    case .ddot:
        mark = "¨"
    case .underline:
        mark = "─"
    }

    if accent == .bar || accent == .overline {
        drawHorizontal(&result, y: 0, x: 0, width: body.width, char: mark, style: context.style)
    } else {
        let diff = body.width - latexCellWidth(mark)
        let centerX = diff >= 0 ? diff / 2 : 0
        setCell(&result, x: centerX, y: 0, char: mark, style: context.style)
    }
    return result
}

private func delimiterBox(
    _ delimiter: String,
    height: Int,
    baseline: Int,
    left: Bool,
    style: MathStyle?
) -> MathBox {
    if delimiter.isEmpty {
        return blankBox(width: 0, height: height, baseline: baseline)
    }
    if height <= 1 {
        return textBox(delimiter, style: style)
    }
    let glyphs = delimiterGlyphs(delimiter)
    let width = max(latexCellWidth(glyphs.0), max(latexCellWidth(glyphs.1), latexCellWidth(glyphs.2)))
    var result = blankBox(width: width, height: height, baseline: baseline)
    for y in 0..<height {
        let glyph = y == 0 ? glyphs.0 : (y == height - 1 ? glyphs.2 : glyphs.1)
        setCell(&result, x: 0, y: y, char: glyph, style: style)
    }
    if (delimiter == "{" || delimiter == "}") && height >= 3 {
        setCell(&result, x: 0, y: height / 2, char: left ? "⎨" : "⎬", style: style)
    }
    return result
}

private func delimiterGlyphs(_ delimiter: String) -> (String, String, String) {
    switch delimiter {
    case "(":
        return ("⎛", "⎜", "⎝")
    case ")":
        return ("⎞", "⎟", "⎠")
    case "[":
        return ("⎡", "⎢", "⎣")
    case "]":
        return ("⎤", "⎥", "⎦")
    case "{":
        return ("⎧", "⎪", "⎩")
    case "}":
        return ("⎫", "⎪", "⎭")
    case "⌊":
        return ("│", "│", "⌊")
    case "⌋":
        return ("│", "│", "⌋")
    case "⌈":
        return ("⌈", "│", "│")
    case "⌉":
        return ("⌉", "│", "│")
    case "⟨":
        return ("/", "│", "\\")
    case "⟩":
        return ("\\", "│", "/")
    default:
        return (delimiter, delimiter, delimiter)
    }
}

private func matrixDelimiters(_ environment: MatrixEnvironment) -> (String, String)? {
    switch environment {
    case .pmatrix:
        return ("(", ")")
    case .bmatrix:
        return ("[", "]")
    case .Bmatrix:
        return ("{", "}")
    case .vmatrix:
        return ("│", "│")
    case .Vmatrix:
        return ("║", "║")
    case .cases:
        return ("{", "")
    case .matrix, .aligned, .align, .gathered, .gather, .smallmatrix, .array:
        return nil
    }
}

private func hpack(_ boxes: [MathBox]) -> MathBox {
    if boxes.isEmpty {
        return blankBox(width: 0, height: 1, baseline: 0)
    }
    var ascent = 0
    var descent = 0
    var width = 0
    for box in boxes {
        if box.baseline > ascent { ascent = box.baseline }
        let boxDescent = box.height - box.baseline - 1
        if boxDescent > descent { descent = boxDescent }
        width += box.width
    }
    var result = blankBox(width: width, height: ascent + descent + 1, baseline: ascent)
    var x = 0
    for box in boxes {
        overlay(&result, source: box, x: x, y: ascent - box.baseline)
        x += box.width
    }
    return result
}

private func textBox(_ text: String, style: MathStyle?) -> MathBox {
    let graphemes = text.map(String.init)
    var width = 0
    for grapheme in graphemes {
        width += latexCellWidth(grapheme)
    }
    var result = blankBox(width: width, height: 1, baseline: 0)
    var x = 0
    for grapheme in graphemes {
        setCell(&result, x: x, y: 0, char: grapheme, style: style)
        x += latexCellWidth(grapheme)
    }
    return result
}

private func blankBox(width: Int, height: Int, baseline: Int) -> MathBox {
    let safeWidth = max(0, width)
    let safeHeight = max(1, height)
    let safeBaseline = max(0, baseline)
    let row = Array<MathCell?>(repeating: nil, count: safeWidth)
    return MathBox(
        width: safeWidth,
        height: safeHeight,
        baseline: safeBaseline,
        cells: Array(repeating: row, count: safeHeight)
    )
}

private func overlay(_ target: inout MathBox, source: MathBox, x: Int, y: Int) {
    for sourceY in 0..<source.height {
        let destY = y + sourceY
        guard destY >= 0 && destY < target.height else { continue }
        for sourceX in 0..<source.width {
            let destX = x + sourceX
            guard destX >= 0 && destX < target.width else { continue }
            if let cell = source.cells[sourceY][sourceX] {
                target.cells[destY][destX] = cell
            }
        }
    }
}

private func drawHorizontal(_ box: inout MathBox, y: Int, x: Int, width: Int, char: String, style: MathStyle?) {
    guard width > 0 else { return }
    for offset in 0..<width {
        setCell(&box, x: x + offset, y: y, char: char, style: style)
    }
}

private func setCell(_ box: inout MathBox, x: Int, y: Int, char: String, style: MathStyle?) {
    guard x >= 0 && y >= 0 && x < box.width && y < box.height else { return }
    box.cells[y][x] = MathCell(char: char, style: style)
}

private func nodeRole(_ node: MathNode) -> SymbolRole? {
    switch node {
    case .symbol(_, let role):
        return role
    case .operator:
        return .operator
    // Tall constructs need a terminal-cell side bearing. Treating them like
    // operators gives their fraction bars/radical hooks breathing room without
    // adding padding inside the construct itself.
    case .fraction, .root, .matrix:
        return .operator
    case .scripts(let base, _, _):
        return nodeRole(base)
    default:
        return nil
    }
}

private func needsMathSpace(previous: SymbolRole?, current: SymbolRole?, count: Int) -> Bool {
    if count == 0 { return false }
    if previous == .punctuation || previous == .opening || current == .punctuation || current == .closing {
        return false
    }
    return previous == .binary
        || previous == .relation
        || previous == .operator
        || current == .binary
        || current == .relation
        || current == .operator
}

private func normalizeBinaryRole(_ role: SymbolRole?, previous: SymbolRole?, next: SymbolRole?) -> SymbolRole? {
    guard role == .binary else { return role }
    if previous == nil
        || previous == .binary
        || previous == .relation
        || previous == .operator
        || previous == .punctuation
        || previous == .opening
        || next == nil
        || next == .binary
        || next == .relation
        || next == .punctuation
        || next == .closing
    {
        return .ordinary
    }
    return role
}

private func nextSignificantRole(_ nodes: [MathNode], start: Int) -> SymbolRole? {
    guard start < nodes.count else { return nil }
    for index in start..<nodes.count {
        let node = nodes[index]
        if case .space = node { continue }
        return nodeRole(node) ?? .ordinary
    }
    return nil
}

private func simpleNodeText(_ node: MathNode) -> String? {
    switch node {
    case .symbol(let value, _), .text(let value), .operator(let value, _):
        return value
    case .row(let body):
        var out = ""
        for child in body {
            guard let text = simpleNodeText(child) else { return nil }
            out.append(text)
        }
        return out
    default:
        return nil
    }
}

private func mapScript(_ value: String?, table: [UnicodeScalar: String]) -> String? {
    guard let value else { return nil }
    var result = ""
    for scalar in value.unicodeScalars {
        guard let mapped = table[scalar] else { return nil }
        result.append(mapped)
    }
    return result
}

private func withVariant(_ context: LayoutContext, variant: MathVariant) -> LayoutContext {
    var next = context
    next.variant = variant
    if variant == .bold {
        var style = context.style ?? MathStyle()
        style.bold = true
        next.style = style
    } else if variant == .italic {
        var style = context.style ?? MathStyle()
        style.italic = true
        next.style = style
    }
    return next
}

private func applyVariant(_ value: String, variant: MathVariant?) -> String {
    guard let variant, variant != .normal, variant != .bold, variant != .italic else {
        return value
    }

    let upperBase: UInt32
    let lowerBase: UInt32
    let digitBase: UInt32?
    let exceptions: [UnicodeScalar: String]?

    switch variant {
    case .doubleStruck:
        upperBase = 0x1D538
        lowerBase = 0x1D552
        digitBase = 0x1D7D8
        exceptions = doubleStruckExceptions
    case .script:
        upperBase = 0x1D49C
        lowerBase = 0x1D4B6
        digitBase = nil
        exceptions = scriptExceptions
    case .fraktur:
        upperBase = 0x1D504
        lowerBase = 0x1D51E
        digitBase = nil
        exceptions = frakturExceptions
    case .sans:
        upperBase = 0x1D5A0
        lowerBase = 0x1D5BA
        digitBase = 0x1D7E2
        exceptions = nil
    case .monospace:
        upperBase = 0x1D670
        lowerBase = 0x1D68A
        digitBase = 0x1D7F6
        exceptions = nil
    case .normal, .bold, .italic:
        return value
    }

    var out = ""
    out.reserveCapacity(value.count)
    for scalar in value.unicodeScalars {
        if let exception = exceptions?[scalar] {
            out.append(exception)
            continue
        }
        let code = scalar.value
        if code >= 65 && code <= 90, let mapped = UnicodeScalar(upperBase + code - 65) {
            out.unicodeScalars.append(mapped)
        } else if code >= 97 && code <= 122, let mapped = UnicodeScalar(lowerBase + code - 97) {
            out.unicodeScalars.append(mapped)
        } else if let digitBase, code >= 48 && code <= 57, let mapped = UnicodeScalar(digitBase + code - 48) {
            out.unicodeScalars.append(mapped)
        } else {
            out.unicodeScalars.append(scalar)
        }
    }
    return out
}

/// Computes terminal cell width for a single grapheme cluster matching `packages/latex/src/layout.ts#cellWidth`.
internal func latexCellWidth(_ value: String) -> Int {
    guard let first = value.unicodeScalars.first else { return 0 }
    if value.unicodeScalars.count == 1 {
        let v = first.value
        if v <= 0x001F || (v >= 0x007F && v <= 0x009F) || (v >= 0x0300 && v <= 0x036F) || (v >= 0xFE00 && v <= 0xFE0F) {
            return 0
        }
    }
    let code = first.value
    if code >= 0x1100
        && (code <= 0x115F
            || code == 0x2329
            || code == 0x232A
            || (code >= 0x2E80 && code <= 0xA4CF)
            || (code >= 0xAC00 && code <= 0xD7A3)
            || (code >= 0xF900 && code <= 0xFAFF)
            || (code >= 0xFE10 && code <= 0xFE6F)
            || (code >= 0xFF00 && code <= 0xFF60)
            || (code >= 0xFFE0 && code <= 0xFFE6)
            || (code >= 0x1F300 && code <= 0x1FAFF))
    {
        return 2
    }
    return 1
}
