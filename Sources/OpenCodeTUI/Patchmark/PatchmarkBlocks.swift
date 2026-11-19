// CommonMark 0.31.2 block parser (line-by-line persistent parser), extended with GFM tables and
// OpenCode's `$$`/`$` display-math blocks. Complete lines are incorporated once, and the streaming tail
// is produced by forking only the open spine (the open last-child chain) of the tree.

/// Internal block node type in `BlockParser`'s persistent tree.
// parity: patchmark/src/blocks.ts#BlockType [status=implemented hash=34396db81ae7]
public enum BlockType: String, Equatable, Hashable, Sendable {
    case document
    case blockQuote = "block_quote"
    case list
    case item
    case heading
    case thematicBreak = "thematic_break"
    case codeBlock = "code_block"
    case htmlBlock = "html_block"
    case paragraph
    case table
    case mathBlock = "math_block"
}

/// Bullet or ordered list kind.
public enum ListKind: String, Equatable, Hashable, Sendable {
    case bullet
    case ordered
}

/// List metadata shared by a `list` container and its `item` children.
// parity: patchmark/src/blocks.ts#ListData [status=implemented hash=4833033dab3f]
public struct ListData: Equatable, Hashable, Sendable {
    public var type: ListKind
    public var tight: Bool
    public var bulletChar: String?
    public var start: Int?
    public var delimiter: String?
    public var padding: Int
    public var markerOffset: Int

    public init(
        type: ListKind,
        tight: Bool,
        bulletChar: String? = nil,
        start: Int? = nil,
        delimiter: String? = nil,
        padding: Int = 0,
        markerOffset: Int = 0
    ) {
        self.type = type
        self.tight = tight
        self.bulletChar = bulletChar
        self.start = start
        self.delimiter = delimiter
        self.padding = padding
        self.markerOffset = markerOffset
    }
}

/// Shared memoization cache across forks of an open GFM table so streaming flushes only parse new rows.
// parity: patchmark/src/blocks.ts#TableMemo [status=implemented hash=445677fbc33d]
public final class TableMemo {
    public var version: Int
    public var headers: [[InlineNode]]?
    public var rows: [[[InlineNode]]]
    public var rawRows: [String]
    public var used: Set<String>
    public var unresolved: Set<String>

    public init(
        version: Int = -1,
        headers: [[InlineNode]]? = nil,
        rows: [[[InlineNode]]] = [],
        rawRows: [String] = [],
        used: Set<String> = [],
        unresolved: Set<String> = []
    ) {
        self.version = version
        self.headers = headers
        self.rows = rows
        self.rawRows = rawRows
        self.used = used
        self.unresolved = unresolved
    }
}

/// Shared memoization cache across forks of an open list so streaming flushes only convert new items.
// parity: patchmark/src/blocks.ts#ListMemo [status=implemented hash=cbf9a90dea5e]
public final class ListMemo {
    public var version: Int
    public var items: [ListItemNode]
    public var count: Int
    public var used: Set<String>
    public var unresolved: Set<String>
    public var tightChecked: Int

    public init(
        version: Int = -1,
        items: [ListItemNode] = [],
        count: Int = 0,
        used: Set<String> = [],
        unresolved: Set<String> = [],
        tightChecked: Int = 0
    ) {
        self.version = version
        self.items = items
        self.count = count
        self.used = used
        self.unresolved = unresolved
        self.tightChecked = tightChecked
    }
}

/// Shared monotonic serial counter box passed between a `BlockParser` and its throwaway forks.
public final class BlockSerialCounter {
    public var n: Int

    public init(_ n: Int = 0) {
        self.n = n
    }

    func next() -> Int {
        let cur = n
        n += 1
        return cur
    }
}

/// Persistent block-level AST node managed by `BlockParser`.
// parity: patchmark/src/blocks.ts#BNode [status=implemented hash=c5906bd18350]
public final class BNode {
    public var type: BlockType
    public weak var parent: BNode?
    public var children: [BNode] = []
    public var open = true
    public var startLine: Int
    public var endLine = 0
    public var content = ""
    public var level = 0
    public var listData: ListData?
    public var isFenced = false
    public var fenceChar = ""
    public var fenceLength = 0
    public var fenceOffset = 0
    public var info = ""
    public var literal = ""
    public var htmlBlockType = 0
    /// Paragraph whose whole content was reference definitions; renders nothing.
    public var defsOnly = false
    public var align: [TableAlign?] = []
    public var header: [String] = []
    public var rows: [String] = []
    public var tableMemo: TableMemo?
    public var listMemo: ListMemo?
    public var mathDelimiter = ""
    public var mathClosed = false
    public var mathLines = 0
    public var fenceClosed = false
    public var lastLineCannotHeadTable = false
    /// Created or cloned by a throwaway fork (never cached).
    public var forked = false
    public var rowsCloned = false
    /// Monotonically increasing identity, stable across forks of the same logical node.
    public let serial: Int

    public init(type: BlockType, startLine: Int, serial: Int) {
        self.type = type
        self.startLine = startLine
        self.serial = serial
    }

    // parity: patchmark/src/blocks.ts#BNode.lastChild [status=implemented hash=b2312ebfa820]
    public var lastChild: BNode? {
        children.last
    }

    // parity: patchmark/src/blocks.ts#BNode.shallowClone [status=implemented hash=b5ab9a88a67e]
    public func shallowClone(cloneChildren: Bool = true) -> BNode {
        let copy = BNode(type: type, startLine: startLine, serial: serial)
        copy.parent = parent
        copy.children = cloneChildren ? children : []
        copy.open = open
        copy.endLine = endLine
        copy.content = content
        copy.level = level
        copy.listData = listData
        copy.isFenced = isFenced
        copy.fenceChar = fenceChar
        copy.fenceLength = fenceLength
        copy.fenceOffset = fenceOffset
        copy.info = info
        copy.literal = literal
        copy.htmlBlockType = htmlBlockType
        copy.defsOnly = defsOnly
        copy.align = align
        copy.header = header
        copy.rows = rows
        copy.tableMemo = tableMemo
        copy.listMemo = listMemo
        copy.mathDelimiter = mathDelimiter
        copy.mathClosed = mathClosed
        copy.mathLines = mathLines
        copy.fenceClosed = fenceClosed
        copy.lastLineCannotHeadTable = lastLineCannotHeadTable
        copy.forked = true
        return copy
    }
}

// MARK: - Block Parsing Scanners

private let codeIndent = 4
private let cTab: UInt16 = 9
private let cGreaterThan: UInt16 = 62
private let cLessThanBlock: UInt16 = 60
private let cSpace: UInt16 = 32
private let cOpenBracketBlock: UInt16 = 91

private let htmlBlockType1Tags: Set<String> = ["script", "pre", "textarea", "style"]

private let htmlBlockType6Tags: Set<String> = [
    "address", "article", "aside", "base", "basefont", "blockquote", "body", "caption", "center",
    "col", "colgroup", "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset",
    "figcaption", "figure", "footer", "form", "frame", "frameset",
    "h1", "h2", "h3", "h4", "h5", "h6",
    "head", "header", "hr", "html", "iframe", "legend", "li", "link", "main", "menu", "menuitem",
    "nav", "noframes", "ol", "optgroup", "option", "p", "param", "section", "search", "summary",
    "table", "tbody", "td", "tfoot", "th", "thead", "title", "tr", "track", "ul",
]

@inline(__always)
private func isSpaceOrTab(_ c: Int) -> Bool {
    c == Int(cSpace) || c == Int(cTab)
}

@inline(__always)
private func peekU16(_ u: [UInt16], _ pos: Int) -> Int {
    pos < u.count ? Int(u[pos]) : -1
}

private func hasNonSpace(_ s: String) -> Bool {
    for c in s.utf16 {
        if c != 0x20 && c != 0x09 && c != 0x0C && c != 0x0B && c != 0x0D && c != 0x0A {
            return true
        }
    }
    return false
}

private func isBlankString(_ s: String) -> Bool {
    !hasNonSpace(s)
}

private func isSpacesOrTabsOnly(_ s: Substring) -> Bool {
    for c in s.utf16 {
        if c != 0x20 && c != 0x09 { return false }
    }
    return true
}

private func isThematicBreak(_ u: [UInt16], start: Int) -> Bool {
    let marker = peekU16(u, start)
    if marker != 0x2A /* * */ && marker != 0x5F /* _ */ && marker != 0x2D /* - */ { return false }
    var count = 0
    for i in stride(from: u.count - 1, through: start, by: -1) {
        let c = Int(u[i])
        if c == marker { count += 1 }
        else if c != Int(cSpace) && c != Int(cTab) { return false }
    }
    return count >= 3
}

private func isMaybeSpecial(_ c: Int, ext: Bool) -> Bool {
    switch c {
    case 0x23, 0x60, 0x7E, 0x2A, 0x2B, 0x5F, 0x3D, 0x3C, 0x3E, 0x2D:
        return true
    case 0x7C, 0x3A, 0x24:
        return ext
    default:
        return c >= 0x30 && c <= 0x39
    }
}

private func endsWithBlankLine(_ block: BNode, _ next: BNode?) -> Bool {
    guard let next else { return false }
    return block.endLine != next.startLine - 1
}

private func isEscapedAt(_ u: [UInt16], idx: Int) -> Bool {
    var backslashes = 0
    var k = idx - 1
    while k >= 0 && u[k] == 0x5C {
        backslashes += 1
        k -= 1
    }
    return backslashes % 2 == 1
}

/// Splits a GFM table row into raw cell strings (escaped pipes stay escaped; they are unescaped per cell later).
// parity: patchmark/src/blocks.ts#splitTableRow [status=implemented hash=71ab5ae9838a]
public func splitTableRow(_ line: String) -> [String] {
    var s = trimJsWhitespace(line)
    var u = Array(s.utf16)
    if !u.isEmpty && u[0] == 0x7C /* | */ {
        u.removeFirst()
    }
    if !u.isEmpty && u[u.count - 1] == 0x7C && !isEscapedAt(u, idx: u.count - 1) {
        u.removeLast()
    }
    s = String(decoding: u, as: UTF16.self)
    var cells: [String] = []
    var start = 0
    var i = 0
    while i < u.count {
        let c = u[i]
        if c == 0x5C /* \ */ {
            i += 2
            continue
        }
        if c == 0x7C /* | */ {
            cells.append(trimJsWhitespace(String(decoding: u[start..<i], as: UTF16.self)))
            start = i + 1
        }
        i += 1
    }
    cells.append(trimJsWhitespace(String(decoding: u[start..<u.count], as: UTF16.self)))
    return cells
}

private func parseAlign(_ delimiterRow: String) -> [TableAlign?] {
    splitTableRow(delimiterRow).map { cell in
        let left = cell.hasPrefix(":")
        let right = cell.hasSuffix(":")
        if left && right { return .center }
        if right { return .right }
        if left { return .left }
        return nil
    }
}

private func isTableDelimiterRow(_ u: [UInt16], from start: Int) -> Bool {
    let n = u.count
    var i = start
    if i < n && u[i] == 0x7C { i += 1 }

    func readCell() -> Bool {
        while i < n && (u[i] == 0x20 || u[i] == 0x09) { i += 1 }
        if i < n && u[i] == 0x3A { i += 1 }
        let dashStart = i
        while i < n && u[i] == 0x2D { i += 1 }
        guard i > dashStart else { return false }
        if i < n && u[i] == 0x3A { i += 1 }
        while i < n && (u[i] == 0x20 || u[i] == 0x09) { i += 1 }
        return true
    }

    guard readCell() else { return false }
    while i < n && u[i] == 0x7C {
        let afterPipe = i + 1
        var peekIdx = afterPipe
        while peekIdx < n && (u[peekIdx] == 0x20 || u[peekIdx] == 0x09) { peekIdx += 1 }
        if peekIdx == n {
            // trailing optional pipe
            return true
        }
        i = afterPipe
        guard readCell() else { return false }
    }
    return i == n
}

private func matchHtmlBlockOpen(in u: [UInt16], from start: Int) -> Int? {
    let n = u.count
    guard start < n, u[start] == cLessThanBlock else { return nil }

    // Type 1: /^<(?:script|pre|textarea|style)(?:\s|>|$)/i
    if start + 1 < n && isAsciiLetter(u[start + 1]) {
        var j = start + 1
        while j < n && isAsciiLetter(u[j]) { j += 1 }
        let tag = String(decoding: u[(start + 1)..<j], as: UTF16.self).lowercased()
        if htmlBlockType1Tags.contains(tag) {
            if j == n || u[j] == 0x3E || isJsWhitespace(u[j]) {
                return 1
            }
        }
    }

    // Type 2: /^<!--/
    if start + 3 < n && u[start + 1] == 0x21 && u[start + 2] == 0x2D && u[start + 3] == 0x2D {
        return 2
    }

    // Type 3: /^<[?]/
    if start + 1 < n && u[start + 1] == 0x3F {
        return 3
    }

    // Type 4: /^<![A-Za-z]/
    if start + 2 < n && u[start + 1] == 0x21 && isAsciiLetter(u[start + 2]) {
        return 4
    }

    // Type 5: /^<!\[CDATA\[/
    if start + 8 < n
        && u[start + 1] == 0x21
        && u[start + 2] == 0x5B
        && u[start + 3] == 0x43
        && u[start + 4] == 0x44
        && u[start + 5] == 0x41
        && u[start + 6] == 0x54
        && u[start + 7] == 0x41
        && u[start + 8] == 0x5B
    {
        return 5
    }

    // Type 6: /^<[/]?(?:address|article|...|ul)(?:\s|[/]?[>]|$)/i
    do {
        var j = start + 1
        if j < n && u[j] == 0x2F { j += 1 }
        let nameStart = j
        while j < n && isAsciiAlnum(u[j]) { j += 1 }
        if j > nameStart {
            let tag = String(decoding: u[nameStart..<j], as: UTF16.self).lowercased()
            if htmlBlockType6Tags.contains(tag) {
                if j == n || isJsWhitespace(u[j]) || u[j] == 0x3E || (u[j] == 0x2F && j + 1 < n && u[j + 1] == 0x3E) {
                    return 6
                }
            }
        }
    }

    // Type 7: /^(?:OPENTAG|CLOSETAG)\s*$/i
    if let end = matchOpenTagEnd(in: u, at: start) ?? matchCloseTagEnd(in: u, at: start) {
        var k = end
        while k < n && isJsWhitespace(u[k]) { k += 1 }
        if k == n { return 7 }
    }

    return nil
}

private func matchesHtmlBlockClose(_ blockType: Int, in u: [UInt16], from start: Int) -> Bool {
    let n = u.count
    switch blockType {
    case 1:
        // /<\/(?:script|pre|textarea|style)>/i
        var i = start
        while i + 2 < n {
            if u[i] == 0x3C && u[i + 1] == 0x2F {
                var j = i + 2
                while j < n && isAsciiLetter(u[j]) { j += 1 }
                if j < n && u[j] == 0x3E {
                    let tag = String(decoding: u[(i + 2)..<j], as: UTF16.self).lowercased()
                    if htmlBlockType1Tags.contains(tag) { return true }
                }
            }
            i += 1
        }
        return false
    case 2:
        // /-->/
        var i = start
        while i + 2 < n {
            if u[i] == 0x2D && u[i + 1] == 0x2D && u[i + 2] == 0x3E { return true }
            i += 1
        }
        return false
    case 3:
        // /\?>/
        var i = start
        while i + 1 < n {
            if u[i] == 0x3F && u[i + 1] == 0x3E { return true }
            i += 1
        }
        return false
    case 4:
        // />/
        for i in start..<n where u[i] == 0x3E { return true }
        return false
    case 5:
        // /\]\]>/
        var i = start
        while i + 2 < n {
            if u[i] == 0x5D && u[i + 1] == 0x5D && u[i + 2] == 0x3E { return true }
            i += 1
        }
        return false
    default:
        return false
    }
}

private func matchATXHeading(_ u: [UInt16], from start: Int) -> (markerLen: Int, level: Int)? {
    let n = u.count
    var i = start
    while i < n && u[i] == 0x23 && i - start < 7 { i += 1 }
    let level = i - start
    guard level >= 1 && level <= 6 else { return nil }
    if i == n { return (level, level) }
    guard u[i] == 0x20 || u[i] == 0x09 else { return nil }
    while i < n && (u[i] == 0x20 || u[i] == 0x09) { i += 1 }
    return (i - start, level)
}

private func stripATXClosingHashes(_ u: [UInt16], from start: Int) -> String {
    let n = u.count
    // Check /^[ \t]*#+[ \t]*$/
    var i = start
    while i < n && (u[i] == 0x20 || u[i] == 0x09) { i += 1 }
    let hashStart = i
    while i < n && u[i] == 0x23 { i += 1 }
    if i > hashStart {
        var j = i
        while j < n && (u[j] == 0x20 || u[j] == 0x09) { j += 1 }
        if j == n { return "" }
    }
    // Strip /[ \t]+#+[ \t]*$/
    var end = n
    while end > start && (u[end - 1] == 0x20 || u[end - 1] == 0x09) { end -= 1 }
    let afterHashes = end
    while end > start && u[end - 1] == 0x23 { end -= 1 }
    if end < afterHashes {
        let beforeHashes = end
        while end > start && (u[end - 1] == 0x20 || u[end - 1] == 0x09) { end -= 1 }
        if end < beforeHashes {
            return String(decoding: u[start..<end], as: UTF16.self)
        }
    }
    return String(decoding: u[start..<n], as: UTF16.self)
}

private func matchCodeFenceOpen(_ u: [UInt16], from start: Int) -> (char: UInt16, length: Int)? {
    let n = u.count
    guard start < n else { return nil }
    let first = u[start]
    guard first == 0x60 || first == 0x7E else { return nil }
    var i = start
    while i < n && u[i] == first { i += 1 }
    let len = i - start
    guard len >= 3 else { return nil }
    if first == 0x60 {
        for j in i..<n where u[j] == 0x60 { return nil }
    }
    return (first, len)
}

private func matchClosingCodeFence(_ u: [UInt16], from start: Int, fenceChar: UInt16, minLength: Int) -> Bool {
    let n = u.count
    guard start < n, u[start] == fenceChar else { return false }
    var i = start
    while i < n && u[i] == fenceChar { i += 1 }
    guard i - start >= minLength else { return false }
    while i < n && (u[i] == 0x20 || u[i] == 0x09) { i += 1 }
    return i == n
}

private func matchSetextHeading(_ u: [UInt16], from start: Int) -> Int? {
    let n = u.count
    guard start < n else { return nil }
    let first = u[start]
    guard first == 0x3D || first == 0x2D else { return nil }
    var i = start
    while i < n && u[i] == first { i += 1 }
    while i < n && (u[i] == 0x20 || u[i] == 0x09) { i += 1 }
    guard i == n else { return nil }
    return first == 0x3D ? 1 : 2
}

// MARK: - BlockParser Options & Implementation

/// Options for `BlockParser`.
// parity: patchmark/src/blocks.ts#ParserOptions [status=implemented hash=bf5a1fe3c2fa]
public struct ParserOptions: Equatable, Hashable, Sendable {
    public var gfm: Bool
    public var math: Bool

    public init(gfm: Bool = true, math: Bool = true) {
        self.gfm = gfm
        self.math = math
    }
}

/// Continuation result for `BlockParser.continueBlock(_:)`.
public enum ContinueResult: Equatable, Hashable, Sendable {
    case matched
    case notMatched
    case finishedLine
}

/// Persistent incremental CommonMark + GFM + Math block parser.
// parity: patchmark/src/blocks.ts#BlockParser [status=implemented hash=7827c4c7b94c]
public final class BlockParser {
    public var doc: BNode
    public var tip: BNode
    public var oldtip: BNode
    public var currentLine = ""
    private var currentU16: [UInt16] = []
    public var lineNumber = 0
    public var offset = 0
    public var column = 0
    public var nextNonspace = 0
    public var nextNonspaceColumn = 0
    public var indent = 0
    public var indented = false
    public var blank = false
    public var partiallyConsumedTab = false
    public var allClosed = true
    public var lastMatchedContainer: BNode
    public var refmap: RefMap
    public var options: ParserOptions
    public var disallowMath: Set<Int>
    public var unclosedMathAt = 0
    public let serialCounter: BlockSerialCounter
    public var refsAdded: [String] = []
    public var forkMode = false
    public var refmapCloned = false

    public init(
        options: ParserOptions,
        disallowMath: Set<Int> = [],
        serialCounter: BlockSerialCounter = BlockSerialCounter(0),
        doc: BNode? = nil,
        refmap: RefMap? = nil
    ) {
        self.options = options
        self.disallowMath = disallowMath
        self.serialCounter = serialCounter
        let root = doc ?? BNode(type: .document, startLine: 1, serial: serialCounter.next())
        self.doc = root
        self.tip = root
        self.oldtip = root
        self.lastMatchedContainer = root
        self.refmap = refmap ?? [:]
    }

    // parity: patchmark/src/blocks.ts#BlockParser.newNode [status=implemented hash=74eebce2a3bd]
    public func newNode(_ type: BlockType, startLine: Int) -> BNode {
        let node = BNode(type: type, startLine: startLine, serial: serialCounter.next())
        if type == .list {
            node.listMemo = ListMemo()
        } else if type == .table {
            node.rows = []
            node.tableMemo = TableMemo()
        }
        if forkMode { node.forked = true }
        return node
    }

    /// Forks the parser for a throwaway continuation (the streaming tail). Only the open spine is cloned;
    /// closed nodes are shared and never mutated.
    // parity: patchmark/src/blocks.ts#BlockParser.fork [status=implemented hash=29d12add6528]
    public func fork() -> BlockParser {
        let forkedDoc = doc.shallowClone(cloneChildren: false)
        let f = BlockParser(
            options: options,
            disallowMath: disallowMath,
            serialCounter: serialCounter,
            doc: forkedDoc,
            refmap: refmap
        )
        f.lineNumber = lineNumber
        f.forkMode = true
        var src = doc
        var dst = forkedDoc
        while src !== tip {
            guard let child = src.lastChild else { break }
            let copy = child.shallowClone(cloneChildren: !child.children.isEmpty)
            copy.parent = dst
            if dst === forkedDoc {
                forkedDoc.children = [copy]
            } else {
                dst.children[dst.children.count - 1] = copy
            }
            src = child
            dst = copy
        }
        f.tip = dst
        f.oldtip = f.tip
        f.lastMatchedContainer = f.tip
        return f
    }

    private func sliceCurrent(from start: Int) -> String {
        if start <= 0 { return currentLine }
        if start >= currentU16.count { return "" }
        return String(decoding: currentU16[start..<currentU16.count], as: UTF16.self)
    }

    // parity: patchmark/src/blocks.ts#BlockParser.addLine [status=implemented hash=cf485ca69c7a]
    public func addLine() {
        if partiallyConsumedTab {
            offset += 1
            let charsToTab = 4 - (column % 4)
            tip.content.append(String(repeating: " ", count: charsToTab))
        }
        tip.content.append(sliceCurrent(from: offset))
        tip.content.append("\n")
    }

    // parity: patchmark/src/blocks.ts#BlockParser.addChild [status=implemented hash=592813e66568]
    @discardableResult
    public func addChild(_ tag: BlockType, offset: Int) -> BNode {
        while !canContain(tip.type, tag) {
            finalize(tip, lineNumber: lineNumber - 1)
        }
        _ = offset
        let newBlock = newNode(tag, startLine: lineNumber)
        newBlock.parent = tip
        tip.children.append(newBlock)
        tip = newBlock
        return newBlock
    }

    // parity: patchmark/src/blocks.ts#BlockParser.canContain [status=implemented hash=e1ea9d80c6b5]
    public func canContain(_ parent: BlockType, _ child: BlockType) -> Bool {
        switch parent {
        case .document, .blockQuote, .item:
            return child != .item
        case .list:
            return child == .item
        default:
            return false
        }
    }

    // parity: patchmark/src/blocks.ts#BlockParser.acceptsLines [status=implemented hash=d72fb65b730b]
    public func acceptsLines(_ t: BlockType) -> Bool {
        t == .paragraph || t == .codeBlock || t == .htmlBlock || t == .table || t == .mathBlock
    }

    // parity: patchmark/src/blocks.ts#BlockParser.parseListMarker [status=implemented hash=968eeec513a3]
    public func parseListMarker(_ container: BNode) -> ListData? {
        if indent >= 4 { return nil }
        let n = currentU16.count
        let start = nextNonspace
        guard start < n else { return nil }

        var data = ListData(type: .bullet, tight: true, markerOffset: indent)
        let first = currentU16[start]
        var markerLen = 0

        if first == 0x2A || first == 0x2B || first == 0x2D {
            data.type = .bullet
            data.bulletChar = String(UnicodeScalar(first)!)
            markerLen = 1
        } else if isAsciiDigit(first) {
            var i = start
            while i < n && isAsciiDigit(currentU16[i]) && i - start < 9 { i += 1 }
            guard i < n, currentU16[i] == 0x2E || currentU16[i] == 0x29 else { return nil }
            let digits = String(decoding: currentU16[start..<i], as: UTF16.self)
            if container.type == .paragraph && digits != "1" { return nil }
            data.type = .ordered
            data.start = Int(digits)
            data.delimiter = String(UnicodeScalar(currentU16[i])!)
            markerLen = (i - start) + 1
        } else {
            return nil
        }

        var nextc = peekU16(currentU16, start + markerLen)
        if !(nextc == -1 || nextc == Int(cTab) || nextc == Int(cSpace)) { return nil }
        if container.type == .paragraph && !hasNonSpace(sliceCurrent(from: start + markerLen)) {
            return nil
        }

        advanceNextNonspace()
        advanceOffset(markerLen, columns: true)
        let spacesStartCol = column
        let spacesStartOffset = offset
        repeat {
            advanceOffset(1, columns: true)
            nextc = peekU16(currentU16, offset)
        } while column - spacesStartCol < 5 && isSpaceOrTab(nextc)

        let blankItem = peekU16(currentU16, offset) == -1
        let spacesAfterMarker = column - spacesStartCol
        if spacesAfterMarker >= 5 || spacesAfterMarker < 1 || blankItem {
            data.padding = markerLen + 1
            column = spacesStartCol
            offset = spacesStartOffset
            if isSpaceOrTab(peekU16(currentU16, offset)) {
                advanceOffset(1, columns: true)
            }
        } else {
            data.padding = markerLen + spacesAfterMarker
        }
        return data
    }

    // parity: patchmark/src/blocks.ts#BlockParser.closeUnmatchedBlocks [status=implemented hash=ad3fcf83bae3]
    public func closeUnmatchedBlocks() {
        if !allClosed {
            while oldtip !== lastMatchedContainer {
                let parent = oldtip.parent!
                finalize(oldtip, lineNumber: lineNumber - 1)
                oldtip = parent
            }
            allClosed = true
        }
    }

    // parity: patchmark/src/blocks.ts#BlockParser.continueBlock [status=implemented hash=966f09931704]
    public func continueBlock(_ container: BNode) -> ContinueResult {
        switch container.type {
        case .document, .list:
            return .matched
        case .blockQuote:
            if !indented && peekU16(currentU16, nextNonspace) == Int(cGreaterThan) {
                advanceNextNonspace()
                advanceOffset(1, columns: false)
                if isSpaceOrTab(peekU16(currentU16, offset)) {
                    advanceOffset(1, columns: true)
                }
                return .matched
            }
            return .notMatched
        case .item:
            let ld = container.listData!
            if blank {
                if container.children.isEmpty { return .notMatched }
                advanceNextNonspace()
            } else if indent >= ld.markerOffset + ld.padding {
                advanceOffset(ld.markerOffset + ld.padding, columns: true)
            } else {
                return .notMatched
            }
            return .matched
        case .heading, .thematicBreak:
            return .notMatched
        case .codeBlock:
            if container.isFenced {
                let fc = container.fenceChar.utf16.first ?? 0
                if indent <= 3 && matchClosingCodeFence(currentU16, from: nextNonspace, fenceChar: fc, minLength: container.fenceLength) {
                    container.fenceClosed = true
                    finalize(container, lineNumber: lineNumber)
                    return .finishedLine
                }
                var i = container.fenceOffset
                while i > 0 && isSpaceOrTab(peekU16(currentU16, offset)) {
                    advanceOffset(1, columns: true)
                    i -= 1
                }
            } else if indent >= codeIndent {
                advanceOffset(codeIndent, columns: true)
            } else if blank {
                advanceNextNonspace()
            } else {
                return .notMatched
            }
            return .matched
        case .htmlBlock:
            return (blank && (container.htmlBlockType == 6 || container.htmlBlockType == 7)) ? .notMatched : .matched
        case .paragraph, .table:
            return blank ? .notMatched : .matched
        case .mathBlock:
            if container.mathLines > 0 && sliceCurrent(from: offset) == container.mathDelimiter {
                container.mathClosed = true
                finalize(container, lineNumber: lineNumber)
                return .finishedLine
            }
            return .matched
        }
    }

    // parity: patchmark/src/blocks.ts#BlockParser.finalizeBlock [status=implemented hash=c891a72b587d]
    public func finalizeBlock(_ block: BNode) {
        switch block.type {
        case .list:
            let items = block.children
            let memo = block.listMemo!
            let start = block.listData!.tight ? max(0, memo.tightChecked - 1) : items.count
            outer: for i in start..<items.count {
                let item = items[i]
                if i + 1 < items.count && endsWithBlankLine(item, items[i + 1]) {
                    block.listData!.tight = false
                    break
                }
                let subs = item.children
                for j in 0..<subs.count {
                    if j + 1 < subs.count && endsWithBlankLine(subs[j], subs[j + 1]) {
                        block.listData!.tight = false
                        break outer
                    }
                }
            }
            if block.listData!.tight && items.count > 1 && !block.forked {
                memo.tightChecked = max(memo.tightChecked, items.count - 1)
            }
            if let last = block.lastChild {
                block.endLine = last.endLine
            }
        case .item:
            block.endLine = block.lastChild?.endLine ?? block.startLine
        case .codeBlock:
            if block.isFenced {
                let u = Array(block.content.utf16)
                if let nlIdx = u.firstIndex(of: 0x0A) {
                    let firstLine = String(decoding: u[0..<nlIdx], as: UTF16.self)
                    block.info = unescapeString(trimJsWhitespace(firstLine))
                    block.literal = String(decoding: u[(nlIdx + 1)..<u.count], as: UTF16.self)
                } else {
                    block.info = unescapeString(trimJsWhitespace(block.content))
                    block.literal = ""
                }
            } else {
                var lines = block.content.split(separator: "\n", omittingEmptySubsequences: false)
                while let last = lines.last, isSpacesOrTabsOnly(last) {
                    lines.removeLast()
                }
                block.literal = lines.joined(separator: "\n") + "\n"
                block.endLine = block.startLine + lines.count - 1
            }
            block.content = ""
        case .htmlBlock:
            if block.content.hasSuffix("\n") {
                block.literal = String(block.content.dropLast())
            } else {
                block.literal = block.content
            }
            block.content = ""
        case .paragraph:
            while block.content.utf16.first == cOpenBracketBlock {
                let pos = parseRef(block.content, startLine: block.startLine)
                if pos == 0 { break }
                let u = Array(block.content.utf16)
                block.content = String(decoding: u[pos..<u.count], as: UTF16.self)
            }
            if isBlankString(block.content) { block.defsOnly = true }
        case .mathBlock:
            let u = Array(block.content.utf16)
            if let nlIdx = u.firstIndex(of: 0x0A) {
                block.literal = String(decoding: u[(nlIdx + 1)..<u.count], as: UTF16.self)
            } else {
                block.literal = block.content
            }
            block.content = ""
            if !block.mathClosed && unclosedMathAt == 0 {
                unclosedMathAt = block.startLine
            }
        default:
            break
        }
    }

    // parity: patchmark/src/blocks.ts#BlockParser.parseRef [status=implemented hash=f011761d1d18]
    public func parseRef(_ s: String, startLine: Int) -> Int {
        if forkMode && !refmapCloned {
            refmapCloned = true
        }
        let result = parseReferenceWithKey(s, into: &refmap)
        if result.consumed > 0, let key = result.addedKey {
            if var def = refmap[key] {
                def.line = startLine
                refmap[key] = def
            }
            refsAdded.append(key)
        }
        return result.consumed
    }

    /// Block starts. Returns 0 = no match, 1 = matched container, 2 = matched leaf.
    // parity: patchmark/src/blocks.ts#BlockParser.tryStart [status=implemented hash=9fe41f52c8e4]
    public func tryStart(_ i: Int, container: inout BNode) -> Int {
        switch i {
        case 0:
            // block quote
            if !indented && peekU16(currentU16, nextNonspace) == Int(cGreaterThan) {
                advanceNextNonspace()
                advanceOffset(1, columns: false)
                if isSpaceOrTab(peekU16(currentU16, offset)) { advanceOffset(1, columns: true) }
                closeUnmatchedBlocks()
                addChild(.blockQuote, offset: nextNonspace)
                return 1
            }
            return 0
        case 1:
            // ATX heading
            if !indented && peekU16(currentU16, nextNonspace) == 0x23,
               let match = matchATXHeading(currentU16, from: nextNonspace)
            {
                advanceNextNonspace()
                advanceOffset(match.markerLen, columns: false)
                closeUnmatchedBlocks()
                let c = addChild(.heading, offset: nextNonspace)
                c.level = match.level
                c.content = stripATXClosingHashes(currentU16, from: offset)
                advanceOffset(currentU16.count - offset, columns: false)
                return 2
            }
            return 0
        case 2:
            // fenced code block
            let first = peekU16(currentU16, nextNonspace)
            if !indented && (first == 0x60 || first == 0x7E),
               let fence = matchCodeFenceOpen(currentU16, from: nextNonspace)
            {
                closeUnmatchedBlocks()
                let c = addChild(.codeBlock, offset: nextNonspace)
                c.isFenced = true
                c.fenceLength = fence.length
                c.fenceChar = String(UnicodeScalar(fence.char)!)
                c.fenceOffset = indent
                advanceNextNonspace()
                advanceOffset(fence.length, columns: false)
                return 2
            }
            return 0
        case 3:
            // HTML block
            if !indented && peekU16(currentU16, nextNonspace) == Int(cLessThanBlock),
               let blockType = matchHtmlBlockOpen(in: currentU16, from: nextNonspace)
            {
                if blockType < 7
                    || (container.type != .paragraph && !(!allClosed && !blank && tip.type == .paragraph))
                {
                    closeUnmatchedBlocks()
                    let b = addChild(.htmlBlock, offset: offset)
                    b.htmlBlockType = blockType
                    return 2
                }
            }
            return 0
        case 4:
            // setext heading
            let first = peekU16(currentU16, nextNonspace)
            if !indented && container.type == .paragraph && (first == 0x3D || first == 0x2D),
               let level = matchSetextHeading(currentU16, from: nextNonspace)
            {
                closeUnmatchedBlocks()
                while container.content.utf16.first == cOpenBracketBlock {
                    let pos = parseRef(container.content, startLine: container.startLine)
                    if pos == 0 { break }
                    let u = Array(container.content.utf16)
                    container.content = String(decoding: u[pos..<u.count], as: UTF16.self)
                }
                if !container.content.isEmpty {
                    let heading = newNode(.heading, startLine: container.startLine)
                    heading.level = level
                    heading.content = container.content
                    let parent = container.parent!
                    heading.parent = parent
                    if let idx = parent.children.firstIndex(where: { $0 === container }) {
                        parent.children[idx] = heading
                    }
                    tip = heading
                    advanceOffset(currentU16.count - offset, columns: false)
                    return 2
                }
                return 0
            }
            return 0
        case 5:
            // thematic break
            if !indented && isThematicBreak(currentU16, start: nextNonspace) {
                closeUnmatchedBlocks()
                addChild(.thematicBreak, offset: nextNonspace)
                advanceOffset(currentU16.count - offset, columns: false)
                return 2
            }
            return 0
        case 6:
            // list item
            let first = peekU16(currentU16, nextNonspace)
            if (!indented || container.type == .list)
                && (first == 0x2A || first == 0x2B || first == 0x2D || (first >= 0x30 && first <= 0x39)),
               let data = parseListMarker(container)
            {
                closeUnmatchedBlocks()
                if tip.type != .list || !listsMatch(container.listData, data) {
                    container = addChild(.list, offset: nextNonspace)
                    container.listData = data
                }
                container = addChild(.item, offset: nextNonspace)
                container.listData = data
                return 1
            }
            return 0
        case 7:
            // indented code block
            if indented && tip.type != .paragraph && !blank {
                advanceOffset(codeIndent, columns: true)
                closeUnmatchedBlocks()
                addChild(.codeBlock, offset: offset)
                return 2
            }
            return 0
        case 8:
            // GFM table
            if !options.gfm || indented || container.type != .paragraph || container.lastLineCannotHeadTable {
                return 0
            }
            if !isTableDelimiterRow(currentU16, from: nextNonspace) { return 0 }
            let rest = sliceCurrent(from: nextNonspace)
            let content = container.content
            let body = content.hasSuffix("\n") ? String(content.dropLast()) : content
            let bodyU = Array(body.utf16)
            var lastNl = -1
            for k in stride(from: bodyU.count - 1, through: 0, by: -1) {
                if bodyU[k] == 0x0A { lastNl = k; break }
            }
            let headerLine = String(decoding: bodyU[(lastNl + 1)..<bodyU.count], as: UTF16.self)
            let align = parseAlign(rest)
            if trimJsWhitespace(headerLine) == "|" { return 0 }
            let header = splitTableRow(headerLine)
            if header.count != align.count { return 0 }
            if !rest.contains("|") && !rest.contains(":") { return 0 }
            closeUnmatchedBlocks()
            let parent = container.parent!
            let table = newNode(.table, startLine: lineNumber - 1)
            table.align = align
            table.header = header
            table.parent = parent
            if lastNl < 0 {
                if let idx = parent.children.firstIndex(where: { $0 === container }) {
                    parent.children[idx] = table
                }
            } else {
                container.content = String(decoding: bodyU[0...(lastNl)], as: UTF16.self)
                tip = container
                finalize(container, lineNumber: lineNumber - 2)
                parent.children.append(table)
            }
            tip = table
            advanceOffset(currentU16.count - offset, columns: false)
            return 2
        case 9:
            // OpenCode display math: `$$` or `$` alone on a line
            if !options.math || indent != 0 || tip.type == .paragraph || container.type == .paragraph {
                return 0
            }
            let rest = sliceCurrent(from: nextNonspace)
            if (rest == "$$" || rest == "$") && !disallowMath.contains(lineNumber) {
                closeUnmatchedBlocks()
                let b = addChild(.mathBlock, offset: nextNonspace)
                b.mathDelimiter = rest
                b.mathLines = -1
                advanceOffset(currentU16.count - offset, columns: false)
                return 2
            }
            return 0
        default:
            return 0
        }
    }

    // parity: patchmark/src/blocks.ts#BlockParser.advanceOffset [status=implemented hash=3cdf3f8d0ecf]
    public func advanceOffset(_ initialCount: Int, columns: Bool = false) {
        var count = initialCount
        let n = currentU16.count
        while count > 0 && offset < n {
            let c = currentU16[offset]
            if c == cTab {
                let charsToTab = 4 - (column % 4)
                if columns {
                    partiallyConsumedTab = charsToTab > count
                    let charsToAdvance = charsToTab > count ? count : charsToTab
                    column += charsToAdvance
                    offset += partiallyConsumedTab ? 0 : 1
                    count -= charsToAdvance
                } else {
                    partiallyConsumedTab = false
                    column += charsToTab
                    offset += 1
                    count -= 1
                }
            } else {
                partiallyConsumedTab = false
                offset += 1
                column += 1
                count -= 1
            }
        }
    }

    // parity: patchmark/src/blocks.ts#BlockParser.advanceNextNonspace [status=implemented hash=ba67577374a8]
    public func advanceNextNonspace() {
        offset = nextNonspace
        column = nextNonspaceColumn
        partiallyConsumedTab = false
    }

    // parity: patchmark/src/blocks.ts#BlockParser.findNextNonspace [status=implemented hash=634174b023b7]
    public func findNextNonspace() {
        let len = currentU16.count
        var i = offset
        var cols = column
        while i < len {
            let c = currentU16[i]
            if c == cSpace {
                i += 1
                cols += 1
            } else if c == cTab {
                i += 1
                cols += 4 - (cols % 4)
            } else {
                break
            }
        }
        let c = i < len ? Int(currentU16[i]) : -1
        blank = c == 0x0A || c == 0x0D || c == -1
        nextNonspace = i
        nextNonspaceColumn = cols
        indent = nextNonspaceColumn - column
        indented = indent >= codeIndent
    }

    // parity: patchmark/src/blocks.ts#BlockParser.incorporateLine [status=implemented hash=367a1d4318b6]
    public func incorporateLine(_ input: String) {
        var container = doc
        oldtip = tip
        offset = 0
        column = 0
        blank = false
        partiallyConsumedTab = false
        lineNumber += 1
        var u = Array(input.utf16)
        if u.contains(0) {
            for k in 0..<u.count where u[k] == 0 {
                u[k] = 0xFFFD
            }
            currentU16 = u
            currentLine = String(decoding: u, as: UTF16.self)
        } else {
            currentU16 = u
            currentLine = input
        }

        while let lastChild = container.lastChild, lastChild.open {
            container = lastChild
            findNextNonspace()
            let res = continueBlock(container)
            if res == .finishedLine { return }
            if res == .notMatched {
                container = container.parent!
                break
            }
        }

        allClosed = container === oldtip
        lastMatchedContainer = container

        var matchedLeaf = container.type != .paragraph && container.type != .table && acceptsLines(container.type)
        let ext = options.gfm || options.math
        while !matchedLeaf {
            findNextNonspace()
            if !indented && !isMaybeSpecial(peekU16(currentU16, nextNonspace), ext: ext) {
                advanceNextNonspace()
                break
            }
            var i = 0
            var matched = false
            while i < 10 {
                let res = tryStart(i, container: &container)
                if res == 1 {
                    container = tip
                    matched = true
                    break
                } else if res == 2 {
                    container = tip
                    matchedLeaf = true
                    matched = true
                    break
                }
                i += 1
            }
            if !matched {
                advanceNextNonspace()
                break
            }
        }

        if !allClosed && !blank && tip.type == .paragraph {
            tip.lastLineCannotHeadTable = indented
            addLine()
        } else {
            closeUnmatchedBlocks()
            let t = container.type
            if acceptsLines(t) {
                if t == .table {
                    if lineNumber > container.startLine + 1 {
                        if container.forked && !container.rowsCloned {
                            container.rowsCloned = true
                        }
                        container.rows.append(sliceCurrent(from: offset))
                    }
                } else {
                    if t == .paragraph { container.lastLineCannotHeadTable = indented }
                    addLine()
                    if t == .mathBlock { container.mathLines += 1 }
                }
                if t == .htmlBlock
                    && container.htmlBlockType >= 1
                    && container.htmlBlockType <= 5
                    && matchesHtmlBlockClose(container.htmlBlockType, in: currentU16, from: offset)
                {
                    finalize(container, lineNumber: lineNumber)
                }
            } else if offset < currentU16.count && !blank {
                container = addChild(.paragraph, offset: offset)
                advanceNextNonspace()
                addLine()
            }
        }
    }

    // parity: patchmark/src/blocks.ts#BlockParser.finalize [status=implemented hash=f40431f136be]
    public func finalize(_ block: BNode, lineNumber: Int) {
        let above = block.parent
        block.open = false
        block.endLine = lineNumber
        finalizeBlock(block)
        if let above { tip = above }
    }

    /// Closes every open block, as at the end of the document.
    // parity: patchmark/src/blocks.ts#BlockParser.finish [status=implemented hash=3491db482186]
    public func finish() {
        while tip !== doc {
            finalize(tip, lineNumber: lineNumber)
        }
        doc.open = false
        doc.endLine = lineNumber
    }
}

private func listsMatch(_ listData: ListData?, _ itemData: ListData) -> Bool {
    guard let listData else { return false }
    return listData.type == itemData.type
        && listData.delimiter == itemData.delimiter
        && listData.bulletChar == itemData.bulletChar
}
