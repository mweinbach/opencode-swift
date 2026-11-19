// MARK: - Public AST & Document Types

/// Options controlling Markdown parsing extensions.
public struct MarkdownParseOptions: Equatable, Hashable, Sendable, Codable {
    /// Enable GFM extensions (tables, strikethrough, task lists, extended autolinks).
    public var enableGFM: Bool
    /// Enable math blocks (`$$...$$`, `\[...\]`) and inline math (`$...$`, `\(...\)`).
    public var enableMath: Bool

    public init(enableGFM: Bool = true, enableMath: Bool = false) {
        self.enableGFM = enableGFM
        self.enableMath = enableMath
    }
}

/// Column alignment for GFM table cells.
// parity: native/src/markdown.zig#Alignment [status=implemented hash=ac9b87ff2e38]
public enum MarkdownTableAlignment: String, Equatable, Hashable, Sendable, Codable {
    case none
    case left
    case center
    case right
}

/// A resolved link reference definition (`[label]: destination "title"`).
public struct MarkdownLinkDefinition: Equatable, Hashable, Sendable, Codable {
    public let destination: String
    public let title: String?

    public init(destination: String, title: String? = nil) {
        self.destination = destination
        self.title = title
    }
}

/// A single item inside an ordered or unordered Markdown list.
public struct MarkdownListItem: Equatable, Hashable, Sendable {
    public let blocks: [MarkdownBlock]
    /// `nil` for ordinary items, `false` for `- [ ]`, `true` for `- [x]` / `- [X]`.
    public let taskChecked: Bool?

    public init(blocks: [MarkdownBlock], taskChecked: Bool? = nil) {
        self.blocks = blocks
        self.taskChecked = taskChecked
    }
}

/// Inline AST node inside paragraphs, headings, and table cells.
public indirect enum MarkdownInline: Equatable, Hashable, Sendable {
    case text(String)
    case softBreak
    case hardBreak
    case codeSpan(String)
    case emphasis([MarkdownInline])
    case strong([MarkdownInline])
    case strikethrough([MarkdownInline])
    case link(destination: String, title: String?, children: [MarkdownInline])
    case image(destination: String, title: String?, alt: [MarkdownInline])
    case rawHTML(String)
    case math(String)
}

/// Block-level AST node in a parsed Markdown document.
public indirect enum MarkdownBlock: Equatable, Hashable, Sendable {
    case paragraph([MarkdownInline])
    case heading(level: Int, content: [MarkdownInline])
    case codeBlock(info: String?, literal: String, fenced: Bool, isMath: Bool)
    case htmlBlock(String)
    case thematicBreak
    case blockquote([MarkdownBlock])
    case list(ordered: Bool, start: Int, tight: Bool, items: [MarkdownListItem])
    case table(
        alignments: [MarkdownTableAlignment],
        header: [[MarkdownInline]],
        rows: [[[MarkdownInline]]]
    )
}

/// A parsed CommonMark + GFM Markdown document.
// parity: core/src/renderables/markdown-document.ts#MarkdownDocument [status=adapted hash=a68dfc731475]
public struct MarkdownDocument: Equatable, Hashable, Sendable {
    public let source: String
    public let options: MarkdownParseOptions
    public let blocks: [MarkdownBlock]
    public let definitions: [String: MarkdownLinkDefinition]

    public init(
        source: String,
        options: MarkdownParseOptions = MarkdownParseOptions(),
        blocks: [MarkdownBlock],
        definitions: [String: MarkdownLinkDefinition] = [:]
    ) {
        self.source = source
        self.options = options
        self.blocks = blocks
        self.definitions = definitions
    }

    /// Renders this parsed document into CommonMark/GFM reference HTML.
    public func renderHTML() -> String {
        MarkdownHTMLRenderer.render(blocks)
    }
}

/// Parses CommonMark 0.31.2 + GFM (and optional math) Markdown source into a `MarkdownDocument`.
public func parseMarkdown(
    _ source: String,
    options: MarkdownParseOptions = MarkdownParseOptions()
) -> MarkdownDocument {
    var parser = MarkdownBlockParser(source: source, options: options)
    return parser.parse()
}

/// Normalizes rendered HTML according to OpenTUI's `markdown.conformance.json` corpus normalization rules
/// (matching `markdown-html.zig#normalize`).
public func normalizeMarkdownHTML(_ html: String) -> String {
    let blockTags: Set<String> = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6", "pre",
        "ul", "ol", "li", "blockquote", "hr",
        "table", "thead", "tbody", "tr", "th", "td",
    ]
    let voidTags: Set<String> = ["br", "hr", "img", "input"]
    let bytes = Array(html.utf8)
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count)
    var i = 0
    while i < bytes.count {
        if bytes[i] == 0x3C { // '<'
            var close = i
            while close < bytes.count && bytes[close] != 0x3E { close += 1 }
            let endIdx = close < bytes.count ? close : bytes.count - 1
            let tag = bytes[i...endIdx]
            let isClosing = tag.count > 1 && bytes[i + 1] == 0x2F // '/'
            let nameStart = i + (isClosing ? 2 : 1)
            var nameEnd = nameStart
            while nameEnd <= endIdx && mdIsAsciiAlnum(bytes[nameEnd]) { nameEnd += 1 }
            let name = String(decoding: bytes[nameStart..<nameEnd], as: UTF8.self)
            let isBlock = blockTags.contains(name)
            let isVoid = voidTags.contains(name)

            if isBlock {
                while out.last == 0x0A { out.removeLast() }
            }
            if isVoid && tag.count >= 3
                && bytes[endIdx - 2] == 0x20 && bytes[endIdx - 1] == 0x2F && bytes[endIdx] == 0x3E
            {
                out.append(contentsOf: bytes[i..<(endIdx - 2)])
                out.append(0x3E)
            } else {
                out.append(contentsOf: tag)
            }
            i = endIdx + 1
            if isBlock {
                while i < bytes.count && bytes[i] == 0x0A { i += 1 }
            } else if name == "br" && !isClosing && i < bytes.count && bytes[i] == 0x0A {
                i += 1
            }
            continue
        }
        if i + 4 < bytes.count
            && bytes[i] == 0x26 && bytes[i + 1] == 0x23 && bytes[i + 2] == 0x33
            && bytes[i + 3] == 0x39 && bytes[i + 4] == 0x3B
        {
            out.append(0x27) // '\''
            i += 5
            continue
        }
        out.append(bytes[i])
        i += 1
    }
    return String(decoding: out, as: UTF8.self)
}

// MARK: - Character Classification & Unicode Utilities

private func mdIsAsciiSpaceOrTab(_ b: UInt8) -> Bool {
    b == 0x20 || b == 0x09
}

private func mdIsAsciiWhitespace(_ b: UInt8) -> Bool {
    b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0C || b == 0x0D
}

private func mdIsAsciiDigit(_ b: UInt8) -> Bool {
    b >= 0x30 && b <= 0x39
}

private func mdIsAsciiAlpha(_ b: UInt8) -> Bool {
    (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
}

private func mdIsAsciiAlnum(_ b: UInt8) -> Bool {
    mdIsAsciiDigit(b) || mdIsAsciiAlpha(b)
}

private func mdIsAsciiHex(_ b: UInt8) -> Bool {
    mdIsAsciiDigit(b) || (b >= 0x41 && b <= 0x46) || (b >= 0x61 && b <= 0x66)
}

// parity: native/src/markdown-inline.zig#isAsciiPunctuation [status=implemented hash=f64e21bca0be]
private func mdIsAsciiPunctuation(_ b: UInt8) -> Bool {
    (b >= 0x21 && b <= 0x2F)
        || (b >= 0x3A && b <= 0x40)
        || (b >= 0x5B && b <= 0x60)
        || (b >= 0x7B && b <= 0x7E)
}

private func mdAsciiLower(_ b: UInt8) -> UInt8 {
    (b >= 0x41 && b <= 0x5A) ? (b + 32) : b
}

private func mdEqualsIgnoreAsciiCase(_ slice: ArraySlice<UInt8>, _ literal: String) -> Bool {
    let target = Array(literal.utf8)
    guard slice.count == target.count else { return false }
    var idx = slice.startIndex
    for t in target {
        if mdAsciiLower(slice[idx]) != mdAsciiLower(t) { return false }
        idx += 1
    }
    return true
}

private func mdStartsWithIgnoreAsciiCase(_ slice: ArraySlice<UInt8>, _ literal: String) -> Bool {
    let target = Array(literal.utf8)
    guard slice.count >= target.count else { return false }
    var idx = slice.startIndex
    for t in target {
        if mdAsciiLower(slice[idx]) != mdAsciiLower(t) { return false }
        idx += 1
    }
    return true
}

private func mdContainsIgnoreAsciiCase(_ bytes: [UInt8], _ literal: String) -> Bool {
    let target = Array(literal.utf8)
    guard !target.isEmpty, bytes.count >= target.count else { return false }
    let limit = bytes.count - target.count
    for start in 0...limit {
        var match = true
        for k in 0..<target.count {
            if mdAsciiLower(bytes[start + k]) != mdAsciiLower(target[k]) {
                match = false
                break
            }
        }
        if match { return true }
    }
    return false
}

// parity: native/src/markdown-inline.zig#isUnicodeWhitespace [status=implemented hash=b03d92c352f8]
private func mdIsUnicodeWhitespace(_ scalar: UInt32) -> Bool {
    if scalar == 0x20 || scalar == 0x09 || scalar == 0x0A || scalar == 0x0C || scalar == 0x0D {
        return true
    }
    if scalar < 0xA0 { return false }
    return MarkdownTables.spaceSeparators.contains(scalar)
}

// parity: native/src/markdown-inline.zig#isUnicodePunctuation [status=implemented hash=06d582c14602]
private func mdIsUnicodePunctuation(_ scalar: UInt32) -> Bool {
    if scalar < 0x80 {
        return mdIsAsciiPunctuation(UInt8(scalar))
    }
    let ranges = MarkdownTables.punctuationRanges
    var lo = 0
    var hi = ranges.count
    while lo < hi {
        let mid = (lo + hi) / 2
        let r = ranges[mid]
        if scalar < r.0 {
            hi = mid
        } else if scalar > r.1 {
            lo = mid + 1
        } else {
            return true
        }
    }
    return false
}

/// Decodes the Unicode scalar ending immediately before `byteIndex` in `bytes`.
private func mdScalarBefore(_ bytes: [UInt8], _ byteIndex: Int) -> UInt32 {
    if byteIndex <= 0 { return 0x0A }
    var start = byteIndex - 1
    while start > 0 && (bytes[start] & 0xC0) == 0x80 {
        start -= 1
    }
    return mdDecodeScalarAt(bytes, start).scalar
}

/// Decodes the Unicode scalar starting at `byteIndex` in `bytes`.
private func mdDecodeScalarAt(_ bytes: [UInt8], _ byteIndex: Int) -> (scalar: UInt32, length: Int) {
    if byteIndex >= bytes.count { return (0x0A, 0) }
    let b0 = bytes[byteIndex]
    if b0 < 0x80 { return (UInt32(b0), 1) }
    if (b0 & 0xE0) == 0xC0 && byteIndex + 1 < bytes.count {
        let v = (UInt32(b0 & 0x1F) << 6) | UInt32(bytes[byteIndex + 1] & 0x3F)
        return (v, 2)
    }
    if (b0 & 0xF0) == 0xE0 && byteIndex + 2 < bytes.count {
        let v = (UInt32(b0 & 0x0F) << 12)
            | (UInt32(bytes[byteIndex + 1] & 0x3F) << 6)
            | UInt32(bytes[byteIndex + 2] & 0x3F)
        return (v, 3)
    }
    if (b0 & 0xF8) == 0xF0 && byteIndex + 3 < bytes.count {
        let v = (UInt32(b0 & 0x07) << 18)
            | (UInt32(bytes[byteIndex + 1] & 0x3F) << 12)
            | (UInt32(bytes[byteIndex + 2] & 0x3F) << 6)
            | UInt32(bytes[byteIndex + 3] & 0x3F)
        return (v, 4)
    }
    return (0xFFFD, 1)
}

/// Normalizes a CommonMark link label: trim, collapse Unicode whitespace runs to a single space,
/// and apply Unicode full case folding.
// parity: native/src/markdown.zig#normalizeLabel [status=implemented hash=35fd866d06d6]
private func mdNormalizeLabel(_ raw: String) -> String {
    var out = ""
    out.reserveCapacity(raw.utf8.count)
    var inSpace = false
    var started = false

    func appendFolded(_ cp: UInt32) {
        if let multi = MarkdownTables.foldMulti[cp] {
            for m in multi {
                if let sc = UnicodeScalar(m) { out.unicodeScalars.append(sc) }
            }
            return
        }
        let runs = MarkdownTables.foldRuns
        var lo = 0
        var hi = runs.count
        while lo < hi {
            let mid = (lo + hi) / 2
            let r = runs[mid]
            if cp < r.first {
                hi = mid
            } else if cp > r.last {
                lo = mid + 1
            } else {
                if (cp - r.first) % r.stride == 0 {
                    let folded = UInt32(Int32(cp) + r.delta)
                    if let sc = UnicodeScalar(folded) { out.unicodeScalars.append(sc) }
                    return
                }
                break
            }
        }
        if let sc = UnicodeScalar(cp) { out.unicodeScalars.append(sc) }
    }

    for sc in raw.unicodeScalars {
        let v = sc.value
        if mdIsUnicodeWhitespace(v) {
            if started { inSpace = true }
        } else {
            if inSpace {
                out.append(" ")
                inSpace = false
            }
            started = true
            appendFolded(v)
        }
    }
    return out
}

// parity: native/src/markdown-inline.zig#decodeEntity [status=implemented hash=6b2ad5e0629a]
private func mdDecodeEntity(_ raw: String) -> String? {
    let bytes = Array(raw.utf8)
    guard bytes.count >= 3, bytes.first == 0x26, bytes.last == 0x3B else { return nil }
    if bytes[1] == 0x23 { // '#'
        if bytes.count >= 4 && (bytes[2] == 0x78 || bytes[2] == 0x58) {
            let digitCount = bytes.count - 4
            guard digitCount >= 1 && digitCount <= 6 else { return nil }
            var val: UInt32 = 0
            for i in 3..<(bytes.count - 1) {
                let b = bytes[i]
                let d: UInt32
                if b >= 0x30 && b <= 0x39 { d = UInt32(b - 0x30) }
                else if b >= 0x41 && b <= 0x46 { d = UInt32(b - 0x41 + 10) }
                else if b >= 0x61 && b <= 0x66 { d = UInt32(b - 0x61 + 10) }
                else { return nil }
                val = (val << 4) | d
            }
            if val == 0 || val > 0x10FFFF || (val >= 0xD800 && val <= 0xDFFF) {
                return "\u{FFFD}"
            }
            return String(UnicodeScalar(val)!)
        } else {
            let digitCount = bytes.count - 3
            guard digitCount >= 1 && digitCount <= 7 else { return nil }
            var val: UInt32 = 0
            for i in 2..<(bytes.count - 1) {
                let b = bytes[i]
                guard b >= 0x30 && b <= 0x39 else { return nil }
                val = val * 10 + UInt32(b - 0x30)
            }
            if val == 0 || val > 0x10FFFF || (val >= 0xD800 && val <= 0xDFFF) {
                return "\u{FFFD}"
            }
            return String(UnicodeScalar(val)!)
        }
    }
    let name = String(decoding: bytes[1..<(bytes.count - 1)], as: UTF8.self)
    return MarkdownTables.entities[name]
}

// parity: native/src/markdown-inline.zig#scanEntity [status=implemented hash=f7cbb0631b22]
private func mdScanEntity(_ bytes: [UInt8], at start: Int) -> (end: Int, decoded: String)? {
    guard start < bytes.count && bytes[start] == 0x26 else { return nil }
    var i = start + 1
    if i >= bytes.count { return nil }
    if bytes[i] == 0x23 { // '#'
        i += 1
        if i < bytes.count && (bytes[i] == 0x78 || bytes[i] == 0x58) {
            i += 1
            let digitStart = i
            while i < bytes.count && i - digitStart < 6 && mdIsAsciiHex(bytes[i]) { i += 1 }
            if i > digitStart && i < bytes.count && bytes[i] == 0x3B {
                let raw = String(decoding: bytes[start...i], as: UTF8.self)
                if let decoded = mdDecodeEntity(raw) {
                    return (i + 1, decoded)
                }
            }
            return nil
        } else {
            let digitStart = i
            while i < bytes.count && i - digitStart < 7 && mdIsAsciiDigit(bytes[i]) { i += 1 }
            if i > digitStart && i < bytes.count && bytes[i] == 0x3B {
                let raw = String(decoding: bytes[start...i], as: UTF8.self)
                if let decoded = mdDecodeEntity(raw) {
                    return (i + 1, decoded)
                }
            }
            return nil
        }
    }
    let nameStart = i
    while i < bytes.count && i - nameStart < 32 && mdIsAsciiAlnum(bytes[i]) { i += 1 }
    if i > nameStart + 1 && i < bytes.count && bytes[i] == 0x3B {
        let name = String(decoding: bytes[nameStart..<i], as: UTF8.self)
        if let decoded = MarkdownTables.entities[name] {
            return (i + 1, decoded)
        }
    }
    return nil
}

/// Unescapes backslash-escaped ASCII punctuation and HTML character references.
// parity: native/src/markdown-inline.zig#unescapeText [status=implemented hash=796e3127346a]
private func mdUnescapeString(_ text: String) -> String {
    let bytes = Array(text.utf8)
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count)
    var i = 0
    while i < bytes.count {
        if bytes[i] == 0x5C && i + 1 < bytes.count && mdIsAsciiPunctuation(bytes[i + 1]) {
            out.append(bytes[i + 1])
            i += 2
            continue
        }
        if bytes[i] == 0x26, let ent = mdScanEntity(bytes, at: i) {
            out.append(contentsOf: ent.decoded.utf8)
            i = ent.end
            continue
        }
        out.append(bytes[i])
        i += 1
    }
    return String(decoding: out, as: UTF8.self)
}

// MARK: - Column-Aware Line Cursor

private struct LineCursor {
    let bytes: [UInt8]
    var index: Int = 0
    var column: Int = 0
    var partiallyConsumedTab: Bool = false

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var isAtEnd: Bool {
        !partiallyConsumedTab && index >= bytes.count
    }

    /// Number of columns of ASCII space/tab indentation starting at the current cursor position.
    func indentColumns() -> Int {
        var col = column
        var idx = index
        if partiallyConsumedTab {
            let tabRemaining = 4 - (col % 4)
            col += tabRemaining
            idx += 1
        }
        while idx < bytes.count {
            let b = bytes[idx]
            if b == 0x20 {
                col += 1
                idx += 1
            } else if b == 0x09 {
                col += 4 - (col % 4)
                idx += 1
            } else {
                break
            }
        }
        return col - column
    }

    /// Index of the first non-space/tab byte from current cursor position (or `bytes.count`).
    func nextNonBlankIndex() -> Int {
        var idx = partiallyConsumedTab ? index + 1 : index
        while idx < bytes.count && mdIsAsciiSpaceOrTab(bytes[idx]) {
            idx += 1
        }
        return idx
    }

    var isBlank: Bool {
        nextNonBlankIndex() >= bytes.count
    }

    /// Advances by `count` visual columns across spaces/tabs.
    mutating func advanceColumns(_ count: Int) {
        var remaining = count
        while remaining > 0 {
            if partiallyConsumedTab {
                let charsToTab = 4 - (column % 4)
                if remaining < charsToTab {
                    column += remaining
                    remaining = 0
                } else {
                    column += charsToTab
                    remaining -= charsToTab
                    partiallyConsumedTab = false
                    index += 1
                }
            } else if index < bytes.count {
                let b = bytes[index]
                if b == 0x09 {
                    let charsToTab = 4 - (column % 4)
                    if remaining < charsToTab {
                        column += remaining
                        remaining = 0
                        partiallyConsumedTab = true
                    } else {
                        column += charsToTab
                        remaining -= charsToTab
                        index += 1
                    }
                } else if b == 0x20 {
                    column += 1
                    remaining -= 1
                    index += 1
                } else {
                    break
                }
            } else {
                break
            }
        }
    }

    /// Advances over all leading spaces and tabs up to the first non-space/tab byte.
    mutating func skipSpacesAndTabs() {
        if partiallyConsumedTab {
            column += 4 - (column % 4)
            partiallyConsumedTab = false
            index += 1
        }
        while index < bytes.count {
            let b = bytes[index]
            if b == 0x20 {
                column += 1
                index += 1
            } else if b == 0x09 {
                column += 4 - (column % 4)
                index += 1
            } else {
                break
            }
        }
    }

    /// Advances past `byteCount` non-tab ASCII bytes.
    mutating func advanceBytes(_ byteCount: Int) {
        if partiallyConsumedTab {
            column += 4 - (column % 4)
            partiallyConsumedTab = false
            index += 1
        }
        let target = min(bytes.count, index + byteCount)
        column += target - index
        index = target
    }

    /// Consumes a single optional space column (or 1 column of a tab).
    mutating func advanceOptionalSpace() {
        if partiallyConsumedTab {
            advanceColumns(1)
        } else if index < bytes.count && (bytes[index] == 0x20 || bytes[index] == 0x09) {
            advanceColumns(1)
        }
    }

    /// Returns the remaining bytes on this line, expanding any partially consumed tab into spaces.
    func remainingBytes() -> [UInt8] {
        var out: [UInt8] = []
        var startIdx = index
        if partiallyConsumedTab {
            let spaces = 4 - (column % 4)
            out.append(contentsOf: repeatElement(0x20, count: spaces))
            startIdx += 1
        }
        if startIdx < bytes.count {
            out.append(contentsOf: bytes[startIdx...])
        }
        return out
    }

    func remainingString() -> String {
        String(decoding: remainingBytes(), as: UTF8.self)
    }
}

// MARK: - Block Parser (CommonMark 0.31.2 + GFM + Math)

private final class BlockNode {
    enum Kind {
        case document
        case blockquote
        case list(ordered: Bool, start: Int, delimiter: UInt8)
        case listItem(padding: Int)
        case paragraph
        case heading(level: Int)
        case codeBlock(fenced: Bool, fenceChar: UInt8, fenceLen: Int, fenceIndent: Int, info: String?, isMath: Bool)
        case htmlBlock(htmlType: Int)
        case thematicBreak
        case table(alignments: [MarkdownTableAlignment], headerRawCells: [String], bodyRawRows: [[String]])
    }

    var kind: Kind
    weak var parent: BlockNode?
    var children: [BlockNode] = []
    var lines: [String] = []
    var open: Bool = true
    var lastLineBlank: Bool = false
    var endsWithBlankLine: Bool = false
    var emptyItemHadBlankLine: Bool = false
    var removedAsDefinitionOnly: Bool = false

    init(_ kind: Kind, parent: BlockNode? = nil) {
        self.kind = kind
        self.parent = parent
    }

    var acceptsChildren: Bool {
        switch kind {
        case .document, .blockquote, .list, .listItem:
            return true
        default:
            return false
        }
    }

    var isParagraph: Bool {
        if case .paragraph = kind { return true }
        return false
    }

    var isCodeBlock: Bool {
        if case .codeBlock = kind { return true }
        return false
    }

    var isHTMLBlock: Bool {
        if case .htmlBlock = kind { return true }
        return false
    }

    var isTable: Bool {
        if case .table = kind { return true }
        return false
    }

    var isList: Bool {
        if case .list = kind { return true }
        return false
    }

    var isListItem: Bool {
        if case .listItem = kind { return true }
        return false
    }
}

private struct MarkdownBlockParser {
    let source: String
    let options: MarkdownParseOptions
    let root = BlockNode(.document)
    var tip: BlockNode
    var definitions: [String: MarkdownLinkDefinition] = [:]

    init(source: String, options: MarkdownParseOptions) {
        self.source = source
        self.options = options
        self.tip = root
    }

    mutating func parse() -> MarkdownDocument {
        let rawLines = splitNormalizedLines(source)
        for lineBytes in rawLines {
            incorporateLine(lineBytes)
        }
        finalizeAll(downTo: root)
        let blocks = convertChildren(of: root)
        return MarkdownDocument(
            source: source,
            options: options,
            blocks: blocks,
            definitions: definitions
        )
    }

    /// Normalizes CRLF/CR to LF and replaces U+0000 with U+FFFD, splitting into lines.
    private func splitNormalizedLines(_ text: String) -> [[UInt8]] {
        if text.isEmpty { return [] }
        let input = Array(text.utf8)
        var lines: [[UInt8]] = []
        var current: [UInt8] = []
        var i = 0
        while i < input.count {
            let b = input[i]
            if b == 0x0D { // \r
                lines.append(current)
                current = []
                if i + 1 < input.count && input[i + 1] == 0x0A {
                    i += 2
                } else {
                    i += 1
                }
            } else if b == 0x0A { // \n
                lines.append(current)
                current = []
                i += 1
            } else if b == 0x00 {
                current.append(contentsOf: [0xEF, 0xBF, 0xBD]) // U+FFFD
                i += 1
            } else {
                current.append(b)
                i += 1
            }
        }
        if !current.isEmpty {
            lines.append(current)
        }
        return lines
    }

    // MARK: - Line Incorporation (CommonMark Appendix A)

    private mutating func incorporateLine(_ lineBytes: [UInt8]) {
        var cursor = LineCursor(lineBytes)
        var allMatched = true
        var container = root
        let oldTip = tip

        // Phase 1: Check existing open containers & leaves
        while let lastChild = container.children.last, lastChild.open {
            container = lastChild
            let indent = cursor.indentColumns()
            let blank = cursor.isBlank

            switch container.kind {
            case .blockquote:
                if indent <= 3 {
                    let nb = cursor.nextNonBlankIndex()
                    if nb < cursor.bytes.count && cursor.bytes[nb] == 0x3E { // '>'
                        cursor.skipSpacesAndTabs()
                        cursor.advanceBytes(1)
                        cursor.advanceOptionalSpace()
                    } else {
                        allMatched = false
                    }
                } else {
                    allMatched = false
                }

            case .list:
                break

            case .listItem(let padding):
                if blank {
                    if container.children.isEmpty {
                        // Blank line in an empty list item: item ends on this blank line (spec 280)
                        allMatched = false
                    } else {
                        cursor.advanceColumns(min(indent, padding))
                    }
                } else if indent >= padding {
                    cursor.advanceColumns(padding)
                } else {
                    allMatched = false
                }

            case .codeBlock(let fenced, let fenceChar, let fenceLen, let fenceIndent, _, let isMath):
                if isMath {
                    if indent <= 3 && isMathBlockCloser(cursor, openerChar: fenceChar) {
                        closeNode(container)
                        return
                    }
                    cursor.advanceColumns(min(indent, fenceIndent))
                } else if fenced {
                    if indent <= 3 && isClosingCodeFence(cursor, fenceChar: fenceChar, minLen: fenceLen) {
                        closeNode(container)
                        return
                    }
                    cursor.advanceColumns(min(indent, fenceIndent))
                } else {
                    if indent >= 4 {
                        cursor.advanceColumns(4)
                    } else if blank {
                        cursor.advanceColumns(min(indent, 4))
                    } else {
                        allMatched = false
                    }
                }

            case .htmlBlock(let htmlType):
                if (htmlType == 6 || htmlType == 7) && blank {
                    allMatched = false
                }

            case .table:
                if blank {
                    allMatched = false
                }

            case .paragraph:
                if blank {
                    allMatched = false
                }

            case .document, .heading, .thematicBreak:
                break
            }

            if !allMatched {
                container = container.parent ?? root
                break
            }
        }

        let lastMatchedContainer = container
        var matchedLeaf = !container.acceptsChildren && !container.isParagraph

        // Check if an open table is interrupted by a new block starter
        if case .table = container.kind, allMatched {
            let indent = cursor.indentColumns()
            if indent <= 3 && interruptsTable(cursor) {
                closeNode(container)
                container = container.parent ?? root
                allMatched = false
                matchedLeaf = false
            }
        }

        func closeUnmatchedBlocks() {
            var node = oldTip
            while node !== lastMatchedContainer && node !== root {
                closeNode(node)
                guard let p = node.parent else { break }
                node = p
            }
            tip = lastMatchedContainer
        }

        // Phase 2: Look for new block starts
        var closedUnmatched = false
        func ensureUnmatchedClosed() {
            if !closedUnmatched {
                closeUnmatchedBlocks()
                closedUnmatched = true
            }
        }

        func closeParagraphIfOpen() {
            if container.isParagraph {
                closeNode(container)
                container = container.parent ?? root
                tip = container
            }
        }

        func ensureContainerAcceptsNonListItem() {
            closeParagraphIfOpen()
            while container.isList {
                closeNode(container)
                container = container.parent ?? root
                tip = container
            }
        }

        while !matchedLeaf {
            let indent = cursor.indentColumns()
            let blank = cursor.isBlank

            // Indented code block (cannot interrupt a paragraph)
            if indent >= 4 && !blank && !tip.isParagraph {
                ensureUnmatchedClosed()
                ensureContainerAcceptsNonListItem()
                cursor.advanceColumns(4)
                let code = BlockNode(.codeBlock(fenced: false, fenceChar: 0, fenceLen: 0, fenceIndent: 0, info: nil, isMath: false), parent: container)
                container.children.append(code)
                container = code
                tip = code
                matchedLeaf = true
                break
            }

            if blank {
                break
            }

            if indent <= 3 {
                let nb = cursor.nextNonBlankIndex()
                let firstByte = cursor.bytes[nb]

                // 1. Blockquote
                if firstByte == 0x3E { // '>'
                    ensureUnmatchedClosed()
                    ensureContainerAcceptsNonListItem()
                    cursor.skipSpacesAndTabs()
                    cursor.advanceBytes(1)
                    cursor.advanceOptionalSpace()
                    let bq = BlockNode(.blockquote, parent: container)
                    container.children.append(bq)
                    container = bq
                    tip = bq
                    continue
                }

                // 2. ATX Heading
                if firstByte == 0x23, let atx = parseATXHeading(cursor) {
                    ensureUnmatchedClosed()
                    ensureContainerAcceptsNonListItem()
                    let heading = BlockNode(.heading(level: atx.level), parent: container)
                    heading.lines = [atx.content]
                    heading.open = false
                    container.children.append(heading)
                    tip = container
                    return
                }

                // 3. Fenced Code Block
                if (firstByte == 0x60 || firstByte == 0x7E), let fence = parseOpeningCodeFence(cursor, indent: indent) {
                    ensureUnmatchedClosed()
                    ensureContainerAcceptsNonListItem()
                    let code = BlockNode(
                        .codeBlock(
                            fenced: true,
                            fenceChar: fence.char,
                            fenceLen: fence.length,
                            fenceIndent: indent,
                            info: fence.info,
                            isMath: false
                        ),
                        parent: container
                    )
                    container.children.append(code)
                    tip = code
                    return
                }

                // 4. Math Block (when enabled)
                if options.enableMath, (firstByte == 0x24 || firstByte == 0x5C),
                   let mathOpen = parseMathBlockOpener(cursor)
                {
                    ensureUnmatchedClosed()
                    ensureContainerAcceptsNonListItem()
                    let code = BlockNode(
                        .codeBlock(
                            fenced: true,
                            fenceChar: mathOpen.openerChar,
                            fenceLen: 2,
                            fenceIndent: indent,
                            info: "math",
                            isMath: true
                        ),
                        parent: container
                    )
                    if let oneLineBody = mathOpen.oneLineBody {
                        code.lines = [oneLineBody]
                        code.open = false
                        container.children.append(code)
                        tip = container
                    } else {
                        container.children.append(code)
                        tip = code
                    }
                    return
                }

                // 5. HTML Block (types 1..7; type 7 cannot interrupt a paragraph)
                if firstByte == 0x3C, let htmlType = detectHTMLBlockStart(cursor, canInterruptParagraph: !tip.isParagraph) {
                    ensureUnmatchedClosed()
                    ensureContainerAcceptsNonListItem()
                    let html = BlockNode(.htmlBlock(htmlType: htmlType), parent: container)
                    let text = cursor.remainingString()
                    html.lines.append(text)
                    container.children.append(html)
                    if htmlType <= 5 && htmlBlockEndsOnLine(Array(text.utf8), htmlType: htmlType) {
                        html.open = false
                        tip = container
                    } else {
                        tip = html
                    }
                    return
                }

                // 6. Setext Heading Underline (only if tip is an open paragraph directly matched)
                if allMatched && tip.isParagraph && (firstByte == 0x3D || firstByte == 0x2D),
                   let setextLevel = parseSetextUnderline(cursor)
                {
                    extractLinkDefinitions(from: tip)
                    if !tip.lines.isEmpty {
                        tip.kind = .heading(level: setextLevel)
                        tip.open = false
                        tip = tip.parent ?? root
                        return
                    }
                }

                // 7. Thematic Break
                if (firstByte == 0x2A || firstByte == 0x2D || firstByte == 0x5F) && isThematicBreak(cursor) {
                    ensureUnmatchedClosed()
                    ensureContainerAcceptsNonListItem()
                    let hr = BlockNode(.thematicBreak, parent: container)
                    hr.open = false
                    container.children.append(hr)
                    tip = container
                    return
                }

                // 8. GFM Table Delimiter Row (converts 1-line open paragraph into table)
                if options.enableGFM && allMatched && tip.isParagraph,
                   (firstByte == 0x7C || firstByte == 0x3A || firstByte == 0x2D),
                   let alignments = parseTableDelimiterRow(cursor)
                {
                    extractLinkDefinitions(from: tip)
                    if tip.lines.count == 1 {
                        let headerCells = splitTableRow(tip.lines[0])
                        if headerCells.count == alignments.count && !headerCells.isEmpty {
                            tip.kind = .table(alignments: alignments, headerRawCells: headerCells, bodyRawRows: [])
                            tip.lines = []
                            return
                        }
                    }
                }

                // 9. List Item
                if let listItem = parseListMarker(cursor, indent: indent, interruptingParagraph: tip.isParagraph && !container.isList) {
                    ensureUnmatchedClosed()
                    closeParagraphIfOpen()
                    cursor = listItem.nextCursor

                    let listNode: BlockNode
                    if case .list(let existingOrdered, _, let existingDelim) = container.kind,
                       existingOrdered == listItem.ordered && existingDelim == listItem.delimiter
                    {
                        listNode = container
                    } else {
                        ensureContainerAcceptsNonListItem()
                        listNode = BlockNode(
                            .list(ordered: listItem.ordered, start: listItem.start, delimiter: listItem.delimiter),
                            parent: container
                        )
                        container.children.append(listNode)
                    }

                    let item = BlockNode(.listItem(padding: listItem.padding), parent: listNode)
                    listNode.children.append(item)
                    container = item
                    tip = item
                    continue
                }
            }

            break
        }

        // Phase 3: Consume remaining text on line
        if !closedUnmatched && !cursor.isBlank && tip.isParagraph {
            // Lazy paragraph continuation
            cursor.skipSpacesAndTabs()
            tip.lines.append(cursor.remainingString())
            return
        }

        ensureUnmatchedClosed()

        // Mark blank lines for tight/loose list detection
        if cursor.isBlank {
            if let last = container.children.last {
                last.lastLineBlank = true
            }
            if case .listItem = container.kind, container.children.isEmpty {
                container.emptyItemHadBlankLine = true
            }
        }

        // Propagate blank-line-after markers when starting a non-blank sibling
        if !cursor.isBlank && !matchedLeaf {
            ensureContainerAcceptsNonListItem()
            markBlankBetweenSiblings(in: container)
        }

        switch container.kind {
        case .codeBlock:
            container.lines.append(cursor.remainingString())

        case .htmlBlock(let htmlType):
            let text = cursor.remainingString()
            container.lines.append(text)
            if htmlType <= 5 && htmlBlockEndsOnLine(Array(text.utf8), htmlType: htmlType) {
                container.open = false
                tip = container.parent ?? root
            }

        case .table(let alignments, let headerCells, var bodyRows):
            let rowCells = splitTableRow(cursor.remainingString())
            bodyRows.append(rowCells)
            container.kind = .table(alignments: alignments, headerRawCells: headerCells, bodyRawRows: bodyRows)

        case .paragraph:
            cursor.skipSpacesAndTabs()
            container.lines.append(cursor.remainingString())

        case .document, .blockquote, .list, .listItem:
            if !cursor.isBlank {
                cursor.skipSpacesAndTabs()
                let para = BlockNode(.paragraph, parent: container)
                para.lines.append(cursor.remainingString())
                container.children.append(para)
                tip = para
            }

        case .heading, .thematicBreak:
            break
        }
    }

    private func markBlankBetweenSiblings(in container: BlockNode) {
        // Walk upward: if a container's last child ended with a blank line, preserve that flag on the child
        // (already stored in `lastLineBlank`).
        if let last = container.children.last, last.lastLineBlank {
            last.endsWithBlankLine = true
        }
    }

    private mutating func closeNode(_ node: BlockNode) {
        guard node.open else { return }
        node.open = false

        // Propagate lastLineBlank upward through list items and lists
        if (node.isListItem || node.isList),
           let lastChild = node.children.last,
           lastChild.lastLineBlank
        {
            node.lastLineBlank = true
        }
        if let parent = node.parent, (parent.isListItem || parent.isList), node === parent.children.last {
            if node.lastLineBlank {
                parent.lastLineBlank = true
            }
        }

        switch node.kind {
        case .paragraph:
            extractLinkDefinitions(from: node)
            if node.lines.isEmpty {
                node.removedAsDefinitionOnly = true
            }
        case .codeBlock(let fenced, _, _, _, _, let isMath):
            if !fenced && !isMath {
                // Trim leading and trailing blank lines from indented code blocks (spec 111, 117)
                while let first = node.lines.first, mdIsBlankLine(first) {
                    node.lines.removeFirst()
                }
                while let last = node.lines.last, mdIsBlankLine(last) {
                    node.lines.removeLast()
                }
            }
        default:
            break
        }
    }

    private mutating func finalizeAll(downTo target: BlockNode) {
        var node = tip
        while node !== target {
            closeNode(node)
            guard let p = node.parent else { break }
            node = p
        }
        closeNode(target)
        tip = target
    }

    // MARK: - Block Starter Recognizers

    private func isThematicBreak(_ cursor: LineCursor) -> Bool {
        let nb = cursor.nextNonBlankIndex()
        guard nb < cursor.bytes.count else { return false }
        let marker = cursor.bytes[nb]
        guard marker == 0x2A || marker == 0x2D || marker == 0x5F else { return false }
        var count = 0
        var i = nb
        while i < cursor.bytes.count {
            let b = cursor.bytes[i]
            if b == marker {
                count += 1
            } else if !mdIsAsciiSpaceOrTab(b) {
                return false
            }
            i += 1
        }
        return count >= 3
    }

    private func parseATXHeading(_ cursor: LineCursor) -> (level: Int, content: String)? {
        let nb = cursor.nextNonBlankIndex()
        var i = nb
        while i < cursor.bytes.count && cursor.bytes[i] == 0x23 { i += 1 }
        let level = i - nb
        guard level >= 1 && level <= 6 else { return nil }
        if i < cursor.bytes.count && !mdIsAsciiSpaceOrTab(cursor.bytes[i]) {
            return nil
        }
        while i < cursor.bytes.count && mdIsAsciiSpaceOrTab(cursor.bytes[i]) { i += 1 }
        var end = cursor.bytes.count
        while end > i && mdIsAsciiSpaceOrTab(cursor.bytes[end - 1]) { end -= 1 }

        // Optional closing '#' sequence preceded by space/tab or start of content
        var hashStart = end
        while hashStart > i && cursor.bytes[hashStart - 1] == 0x23 { hashStart -= 1 }
        if hashStart < end {
            if hashStart == i {
                end = i
            } else if mdIsAsciiSpaceOrTab(cursor.bytes[hashStart - 1]) {
                end = hashStart
                while end > i && mdIsAsciiSpaceOrTab(cursor.bytes[end - 1]) { end -= 1 }
            }
        }
        let content = String(decoding: cursor.bytes[i..<end], as: UTF8.self)
        return (level, content)
    }

    private func parseSetextUnderline(_ cursor: LineCursor) -> Int? {
        let nb = cursor.nextNonBlankIndex()
        guard nb < cursor.bytes.count else { return nil }
        let ch = cursor.bytes[nb]
        guard ch == 0x3D || ch == 0x2D else { return nil }
        var i = nb
        while i < cursor.bytes.count && cursor.bytes[i] == ch { i += 1 }
        while i < cursor.bytes.count && mdIsAsciiSpaceOrTab(cursor.bytes[i]) { i += 1 }
        guard i == cursor.bytes.count else { return nil }
        return ch == 0x3D ? 1 : 2
    }

    private func parseOpeningCodeFence(
        _ cursor: LineCursor,
        indent: Int
    ) -> (char: UInt8, length: Int, info: String?)? {
        let nb = cursor.nextNonBlankIndex()
        guard nb < cursor.bytes.count else { return nil }
        let ch = cursor.bytes[nb]
        guard ch == 0x60 || ch == 0x7E else { return nil }
        var i = nb
        while i < cursor.bytes.count && cursor.bytes[i] == ch { i += 1 }
        let len = i - nb
        guard len >= 3 else { return nil }

        // Backtick fence info string cannot contain backticks
        if ch == 0x60 {
            for k in i..<cursor.bytes.count where cursor.bytes[k] == 0x60 {
                return nil
            }
        }

        var infoStart = i
        var infoEnd = cursor.bytes.count
        while infoStart < infoEnd && mdIsAsciiSpaceOrTab(cursor.bytes[infoStart]) { infoStart += 1 }
        while infoEnd > infoStart && mdIsAsciiSpaceOrTab(cursor.bytes[infoEnd - 1]) { infoEnd -= 1 }
        let info: String?
        if infoStart < infoEnd {
            let rawInfo = String(decoding: cursor.bytes[infoStart..<infoEnd], as: UTF8.self)
            info = mdUnescapeString(rawInfo)
        } else {
            info = nil
        }
        return (ch, len, info)
    }

    private func isClosingCodeFence(_ cursor: LineCursor, fenceChar: UInt8, minLen: Int) -> Bool {
        let nb = cursor.nextNonBlankIndex()
        var i = nb
        while i < cursor.bytes.count && cursor.bytes[i] == fenceChar { i += 1 }
        guard i - nb >= minLen else { return false }
        while i < cursor.bytes.count && mdIsAsciiSpaceOrTab(cursor.bytes[i]) { i += 1 }
        return i == cursor.bytes.count
    }

    private func parseMathBlockOpener(_ cursor: LineCursor) -> (openerChar: UInt8, oneLineBody: String?)? {
        let nb = cursor.nextNonBlankIndex()
        var end = cursor.bytes.count
        while end > nb && mdIsAsciiSpaceOrTab(cursor.bytes[end - 1]) { end -= 1 }
        let len = end - nb
        guard len >= 2 else { return nil }
        let slice = cursor.bytes[nb..<end]
        let isDollars = slice[nb] == 0x24 && slice[nb + 1] == 0x24
        let isBracket = slice[nb] == 0x5C && slice[nb + 1] == 0x5B
        guard isDollars || isBracket else { return nil }
        let openerChar: UInt8 = isDollars ? 0x24 : 0x5C
        if len == 2 {
            return (openerChar, nil)
        }
        if len > 4 {
            let close0: UInt8 = isDollars ? 0x24 : 0x5C
            let close1: UInt8 = isDollars ? 0x24 : 0x5D
            if slice[end - 2] == close0 && slice[end - 1] == close1 {
                let body = Array(slice[(nb + 2)..<(end - 2)])
                let bodyStr = String(decoding: body, as: UTF8.self)
                let openStr = isDollars ? "$$" : "\\["
                let closeStr = isDollars ? "$$" : "\\]"
                if !bodyStr.contains(openStr) && !bodyStr.contains(closeStr) {
                    return (openerChar, bodyStr)
                }
            }
        }
        return nil
    }

    private func isMathBlockCloser(_ cursor: LineCursor, openerChar: UInt8) -> Bool {
        let nb = cursor.nextNonBlankIndex()
        var end = cursor.bytes.count
        while end > nb && mdIsAsciiSpaceOrTab(cursor.bytes[end - 1]) { end -= 1 }
        guard end - nb == 2 else { return false }
        if openerChar == 0x24 {
            return cursor.bytes[nb] == 0x24 && cursor.bytes[nb + 1] == 0x24
        }
        return cursor.bytes[nb] == 0x5C && cursor.bytes[nb + 1] == 0x5D
    }

    private static let htmlBlockTagNames: Set<String> = [
        "address", "article", "aside", "base", "basefont", "blockquote", "body", "caption",
        "center", "col", "colgroup", "dd", "details", "dialog", "dir", "div",
        "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", "frame",
        "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head",
        "header", "hr", "html", "iframe", "legend", "li", "link", "main",
        "menu", "menuitem", "nav", "noframes", "ol", "optgroup", "option", "p",
        "param", "search", "section", "summary", "table", "tbody", "td", "tfoot",
        "th", "thead", "title", "tr", "track", "ul",
    ]

    private func detectHTMLBlockStart(_ cursor: LineCursor, canInterruptParagraph: Bool) -> Int? {
        let nb = cursor.nextNonBlankIndex()
        guard nb < cursor.bytes.count && cursor.bytes[nb] == 0x3C else { return nil }
        let line = cursor.bytes[nb...]

        // Type 1: <pre, <script, <style, <textarea
        for tag in ["script", "pre", "style", "textarea"] {
            if line.count >= 1 + tag.count && mdStartsWithIgnoreAsciiCase(line.dropFirst(), tag) {
                let after = nb + 1 + tag.count
                if after == cursor.bytes.count
                    || mdIsAsciiSpaceOrTab(cursor.bytes[after])
                    || cursor.bytes[after] == 0x3E
                {
                    return 1
                }
            }
        }
        // Type 2: <!--
        if line.count >= 4 && cursor.bytes[nb + 1] == 0x21 && cursor.bytes[nb + 2] == 0x2D && cursor.bytes[nb + 3] == 0x2D {
            return 2
        }
        // Type 3: <?
        if line.count >= 2 && cursor.bytes[nb + 1] == 0x3F {
            return 3
        }
        // Type 4: <! followed by ASCII letter
        if line.count >= 3 && cursor.bytes[nb + 1] == 0x21 && mdIsAsciiAlpha(cursor.bytes[nb + 2]) {
            return 4
        }
        // Type 5: <![CDATA[
        if line.count >= 9 && String(decoding: cursor.bytes[nb..<(nb + 9)], as: UTF8.self) == "<![CDATA[" {
            return 5
        }
        // Type 6: known block tag name
        var i = nb + 1
        if i < cursor.bytes.count && cursor.bytes[i] == 0x2F { i += 1 }
        let nameStart = i
        while i < cursor.bytes.count && mdIsAsciiAlnum(cursor.bytes[i]) { i += 1 }
        if i > nameStart {
            let name = String(decoding: cursor.bytes[nameStart..<i], as: UTF8.self).lowercased()
            if Self.htmlBlockTagNames.contains(name) {
                if i == cursor.bytes.count
                    || mdIsAsciiSpaceOrTab(cursor.bytes[i])
                    || cursor.bytes[i] == 0x3E
                    || (i + 1 < cursor.bytes.count && cursor.bytes[i] == 0x2F && cursor.bytes[i + 1] == 0x3E)
                {
                    return 6
                }
            }
        }
        // Type 7: complete single open or closing tag followed only by spaces/tabs (cannot interrupt paragraph)
        if !canInterruptParagraph { return nil }
        let tailBytes = Array(line)
        if tailBytes.count >= 2 && tailBytes[1] == 0x2F {
            var j = 2
            guard j < tailBytes.count && mdIsAsciiAlpha(tailBytes[j]) else { return nil }
            while j < tailBytes.count && (mdIsAsciiAlnum(tailBytes[j]) || tailBytes[j] == 0x2D) { j += 1 }
            while j < tailBytes.count && mdIsAsciiSpaceOrTab(tailBytes[j]) { j += 1 }
            if j < tailBytes.count && tailBytes[j] == 0x3E {
                var k = j + 1
                while k < tailBytes.count && mdIsAsciiSpaceOrTab(tailBytes[k]) { k += 1 }
                if k == tailBytes.count { return 7 }
            }
            return nil
        }
        if let tagEnd = mdScanOpenTag(tailBytes, at: 0, allowNewlines: false) {
            var j = 1
            while j < tailBytes.count && (mdIsAsciiAlnum(tailBytes[j]) || tailBytes[j] == 0x2D) { j += 1 }
            let tagName = String(decoding: tailBytes[1..<j], as: UTF8.self).lowercased()
            if tagName == "script" || tagName == "pre" || tagName == "style" || tagName == "textarea" {
                return nil
            }
            var k = tagEnd
            while k < tailBytes.count && mdIsAsciiSpaceOrTab(tailBytes[k]) { k += 1 }
            if k == tailBytes.count { return 7 }
        }
        return nil
    }

    private func htmlBlockEndsOnLine(_ bytes: [UInt8], htmlType: Int) -> Bool {
        switch htmlType {
        case 1:
            return mdContainsIgnoreAsciiCase(bytes, "</script>")
                || mdContainsIgnoreAsciiCase(bytes, "</pre>")
                || mdContainsIgnoreAsciiCase(bytes, "</style>")
                || mdContainsIgnoreAsciiCase(bytes, "</textarea>")
        case 2:
            return mdContainsBytes(bytes, [0x2D, 0x2D, 0x3E]) // -->
        case 3:
            return mdContainsBytes(bytes, [0x3F, 0x3E]) // ?>
        case 4:
            return bytes.contains(0x3E) // >
        case 5:
            return mdContainsBytes(bytes, [0x5D, 0x5D, 0x3E]) // ]]>
        default:
            return false
        }
    }

    private func interruptsTable(_ cursor: LineCursor) -> Bool {
        let nb = cursor.nextNonBlankIndex()
        guard nb < cursor.bytes.count else { return true }
        let b = cursor.bytes[nb]
        if b == 0x3E { return true } // blockquote
        if b == 0x23 && parseATXHeading(cursor) != nil { return true }
        if (b == 0x60 || b == 0x7E) && parseOpeningCodeFence(cursor, indent: cursor.indentColumns()) != nil { return true }
        if options.enableMath && (b == 0x24 || b == 0x5C) && parseMathBlockOpener(cursor) != nil { return true }
        if b == 0x3C, let t = detectHTMLBlockStart(cursor, canInterruptParagraph: false), t <= 6 { return true }
        if (b == 0x2A || b == 0x2D || b == 0x5F) && isThematicBreak(cursor) { return true }
        if parseListMarker(cursor, indent: cursor.indentColumns(), interruptingParagraph: true) != nil { return true }
        return false
    }

    private struct ParsedListMarker {
        let ordered: Bool
        let start: Int
        let delimiter: UInt8
        let padding: Int
        let nextCursor: LineCursor
    }

    private func parseListMarker(
        _ cursor: LineCursor,
        indent: Int,
        interruptingParagraph: Bool
    ) -> ParsedListMarker? {
        var cur = cursor
        cur.skipSpacesAndTabs()
        guard cur.index < cur.bytes.count else { return nil }
        let first = cur.bytes[cur.index]

        let ordered: Bool
        let start: Int
        let delimiter: UInt8
        let markerLen: Int

        if first == 0x2D || first == 0x2B || first == 0x2A { // -, +, *
            ordered = false
            start = 1
            delimiter = first
            markerLen = 1
        } else if mdIsAsciiDigit(first) {
            var i = cur.index
            while i < cur.bytes.count && mdIsAsciiDigit(cur.bytes[i]) { i += 1 }
            let digits = i - cur.index
            guard digits >= 1 && digits <= 9, i < cur.bytes.count else { return nil }
            let delim = cur.bytes[i]
            guard delim == 0x2E || delim == 0x29 else { return nil } // '.' or ')'
            var val = 0
            for k in cur.index..<i {
                val = val * 10 + Int(cur.bytes[k] - 0x30)
            }
            ordered = true
            start = val
            delimiter = delim
            markerLen = digits + 1
        } else {
            return nil
        }

        cur.advanceBytes(markerLen)

        // Must be followed by space, tab, or EOL
        if cur.index < cur.bytes.count && !mdIsAsciiSpaceOrTab(cur.bytes[cur.index]) {
            return nil
        }

        let spacesAfterMarker = cur.indentColumns()
        let restBlank = cur.isBlank

        // CommonMark 5.2 paragraph interruption rules
        if interruptingParagraph {
            if restBlank { return nil }
            if ordered && start != 1 { return nil }
        }

        let padding: Int
        if restBlank || spacesAfterMarker >= 5 {
            padding = indent + markerLen + 1
            cur.advanceColumns(min(1, spacesAfterMarker))
        } else {
            padding = indent + markerLen + spacesAfterMarker
            cur.advanceColumns(spacesAfterMarker)
        }

        return ParsedListMarker(
            ordered: ordered,
            start: start,
            delimiter: delimiter,
            padding: padding,
            nextCursor: cur
        )
    }

    // MARK: - GFM Table Helpers

    private func parseTableDelimiterRow(_ cursor: LineCursor) -> [MarkdownTableAlignment]? {
        let nb = cursor.nextNonBlankIndex()
        var end = cursor.bytes.count
        while end > nb && mdIsAsciiSpaceOrTab(cursor.bytes[end - 1]) { end -= 1 }
        guard nb < end else { return nil }

        var i = nb
        var pipes = 0
        if cursor.bytes[i] == 0x7C { // '|'
            i += 1
            pipes += 1
        }

        var alignments: [MarkdownTableAlignment] = []
        while true {
            while i < end && mdIsAsciiSpaceOrTab(cursor.bytes[i]) { i += 1 }
            if i >= end { break }

            let leftColon = cursor.bytes[i] == 0x3A
            if leftColon { i += 1 }
            let dashStart = i
            while i < end && cursor.bytes[i] == 0x2D { i += 1 }
            guard i > dashStart else { return nil }
            let rightColon = i < end && cursor.bytes[i] == 0x3A
            if rightColon { i += 1 }

            let align: MarkdownTableAlignment
            if leftColon && rightColon { align = .center }
            else if leftColon { align = .left }
            else if rightColon { align = .right }
            else { align = .none }
            alignments.append(align)

            while i < end && mdIsAsciiSpaceOrTab(cursor.bytes[i]) { i += 1 }
            if i >= end { break }
            guard cursor.bytes[i] == 0x7C else { return nil }
            i += 1
            pipes += 1
        }

        guard !alignments.isEmpty else { return nil }
        // Single-column delimiter row without any pipe could be a Setext underline (handled earlier),
        // and GFM requires at least one pipe or valid cells.
        if alignments.count == 1 && pipes == 0 { return nil }
        return alignments
    }

    private func splitTableRow(_ line: String) -> [String] {
        let bytes = Array(line.utf8)
        var start = 0
        var end = bytes.count
        while start < end && mdIsAsciiSpaceOrTab(bytes[start]) { start += 1 }
        while end > start && mdIsAsciiSpaceOrTab(bytes[end - 1]) { end -= 1 }
        if start < end && bytes[start] == 0x7C { start += 1 }
        // Strip unescaped trailing pipe
        if end > start && bytes[end - 1] == 0x7C {
            var bsCount = 0
            var k = end - 2
            while k >= start && bytes[k] == 0x5C {
                bsCount += 1
                if k == start { break }
                k -= 1
            }
            if bsCount % 2 == 0 {
                end -= 1
            }
        }

        var cells: [String] = []
        var cur: [UInt8] = []
        var i = start
        while i < end {
            let b = bytes[i]
            if b == 0x5C && i + 1 < end && bytes[i + 1] == 0x7C {
                // Escaped pipe inside GFM table cell becomes literal '|' (spec gfm 200)
                cur.append(0x7C)
                i += 2
                continue
            }
            if b == 0x7C {
                cells.append(mdTrimAsciiSpaceAndTab(cur))
                cur = []
                i += 1
                continue
            }
            cur.append(b)
            i += 1
        }
        cells.append(mdTrimAsciiSpaceAndTab(cur))
        return cells
    }

    // MARK: - Link Reference Definitions (CommonMark 4.7)

    private mutating func extractLinkDefinitions(from para: BlockNode) {
        guard para.isParagraph && !para.lines.isEmpty else { return }
        var text = para.lines.joined(separator: "\n")
        let bytes = Array(text.utf8)
        var pos = 0

        while pos < bytes.count {
            guard let def = parseSingleLinkDefinition(bytes, from: pos) else {
                break
            }
            if definitions[def.normalizedLabel] == nil {
                definitions[def.normalizedLabel] = MarkdownLinkDefinition(
                    destination: def.destination,
                    title: def.title
                )
            }
            pos = def.nextIndex
        }

        if pos == 0 { return }
        if pos >= bytes.count {
            para.lines = []
        } else {
            text = String(decoding: bytes[pos...], as: UTF8.self)
            para.lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            // Trim leading spaces/tabs on remaining first line
            if !para.lines.isEmpty {
                let firstBytes = Array(para.lines[0].utf8)
                var s = 0
                while s < firstBytes.count && mdIsAsciiSpaceOrTab(firstBytes[s]) { s += 1 }
                para.lines[0] = String(decoding: firstBytes[s...], as: UTF8.self)
            }
        }
    }

    private func parseSingleLinkDefinition(
        _ bytes: [UInt8],
        from start: Int
    ) -> (normalizedLabel: String, destination: String, title: String?, nextIndex: Int)? {
        var i = start
        // Up to 3 leading spaces
        var leadingSpaces = 0
        while i < bytes.count && bytes[i] == 0x20 && leadingSpaces < 3 {
            leadingSpaces += 1
            i += 1
        }
        guard i < bytes.count && bytes[i] == 0x5B else { return nil } // '['

        // Parse label (max 999 Unicode scalars, no unescaped '[' or ']', at least one non-whitespace)
        guard let labelScan = mdScanLinkLabel(bytes, at: i) else { return nil }
        let normalizedLabel = mdNormalizeLabel(labelScan.rawLabel)
        guard !normalizedLabel.isEmpty else { return nil }
        i = labelScan.endIndex

        guard i < bytes.count && bytes[i] == 0x3A else { return nil } // ':'
        i += 1

        // Optional spaces/tabs and at most one newline
        i = mdSkipOptionalWhitespaceOneNewline(bytes, from: i)

        // Destination
        guard let destScan = mdScanLinkDestination(bytes, at: i) else { return nil }
        let destination = mdUnescapeString(destScan.rawDestination)
        i = destScan.endIndex

        let afterDest = i
        // Check for optional title
        var wsEnd = i
        var sawNewline = false
        while wsEnd < bytes.count && mdIsAsciiSpaceOrTab(bytes[wsEnd]) { wsEnd += 1 }
        if wsEnd < bytes.count && bytes[wsEnd] == 0x0A {
            sawNewline = true
            wsEnd += 1
            while wsEnd < bytes.count && mdIsAsciiSpaceOrTab(bytes[wsEnd]) { wsEnd += 1 }
        }

        let hasSpaceBeforeTitle = wsEnd > afterDest
        var title: String? = nil
        var endAfterDef = afterDest

        if hasSpaceBeforeTitle, let titleScan = mdScanLinkTitle(bytes, at: wsEnd) {
            // Check rest of title's closing line has only spaces/tabs
            var lineEnd = titleScan.endIndex
            while lineEnd < bytes.count && mdIsAsciiSpaceOrTab(bytes[lineEnd]) { lineEnd += 1 }
            if lineEnd == bytes.count || bytes[lineEnd] == 0x0A {
                title = mdUnescapeString(titleScan.rawTitle)
                endAfterDef = lineEnd < bytes.count ? lineEnd + 1 : lineEnd
                return (normalizedLabel, destination, title, endAfterDef)
            }
            // Title failed trailing check: only valid if title started on a new line (spec 210)
            if !sawNewline {
                return nil
            }
        }

        // No title used: rest of destination line must have only spaces/tabs
        var destLineEnd = afterDest
        while destLineEnd < bytes.count && mdIsAsciiSpaceOrTab(bytes[destLineEnd]) { destLineEnd += 1 }
        guard destLineEnd == bytes.count || bytes[destLineEnd] == 0x0A else {
            return nil
        }
        let nextIndex = destLineEnd < bytes.count ? destLineEnd + 1 : destLineEnd
        return (normalizedLabel, destination, nil, nextIndex)
    }

    // MARK: - AST Conversion & Tight/Loose List Finalization

    private func convertChildren(of node: BlockNode) -> [MarkdownBlock] {
        var out: [MarkdownBlock] = []
        for child in node.children {
            if let converted = convertNode(child) {
                out.append(converted)
            }
        }
        return out
    }

    private func convertNode(_ node: BlockNode) -> MarkdownBlock? {
        switch node.kind {
        case .document:
            return nil

        case .paragraph:
            if node.removedAsDefinitionOnly || node.lines.isEmpty { return nil }
            let content = trimParagraphTrailingSpaces(node.lines.joined(separator: "\n"))
            let inlines = parseInlines(content)
            return .paragraph(inlines)

        case .heading(let level):
            let raw = trimParagraphTrailingSpaces(node.lines.joined(separator: "\n"))
            let inlines = parseInlines(raw)
            return .heading(level: level, content: inlines)

        case .codeBlock(let fenced, _, _, _, let info, let isMath):
            var literal = node.lines.joined(separator: "\n")
            if !node.lines.isEmpty {
                literal.append("\n")
            }
            return .codeBlock(info: info, literal: literal, fenced: fenced, isMath: isMath)

        case .htmlBlock:
            return .htmlBlock(node.lines.joined(separator: "\n"))

        case .thematicBreak:
            return .thematicBreak

        case .blockquote:
            return .blockquote(convertChildren(of: node))

        case .list(let ordered, let start, _):
            let tight = isListTight(node)
            var items: [MarkdownListItem] = []
            for itemNode in node.children {
                var blocks = convertChildren(of: itemNode)
                var taskChecked: Bool? = nil
                if options.enableGFM, let firstBlock = blocks.first, case .paragraph(let inlines) = firstBlock {
                    if let task = extractTaskCheckbox(from: inlines) {
                        taskChecked = task.checked
                        blocks[0] = .paragraph(task.remaining)
                    }
                }
                items.append(MarkdownListItem(blocks: blocks, taskChecked: taskChecked))
            }
            return .list(ordered: ordered, start: start, tight: tight, items: items)

        case .listItem:
            return nil

        case .table(let alignments, let headerRaw, let bodyRaw):
            let colCount = alignments.count
            let header: [[MarkdownInline]] = (0..<colCount).map { col in
                col < headerRaw.count ? parseInlines(headerRaw[col]) : []
            }
            let rows: [[[MarkdownInline]]] = bodyRaw.map { rawRow in
                (0..<colCount).map { col in
                    col < rawRow.count ? parseInlines(rawRow[col]) : []
                }
            }
            return .table(alignments: alignments, header: header, rows: rows)
        }
    }

    private func isListTight(_ list: BlockNode) -> Bool {
        for (itemIdx, item) in list.children.enumerated() {
            // Blank line directly after an item before a following sibling item
            if itemIdx + 1 < list.children.count {
                if item.endsWithBlankLine || item.lastLineBlank {
                    return false
                }
                if let lastSub = item.children.last, lastSub.endsWithBlankLine || (lastSub.lastLineBlank && !lastSub.isCodeBlock) {
                    return false
                }
            }
            // Blank line directly between two block-level children of an item
            for (subIdx, sub) in item.children.enumerated() where subIdx + 1 < item.children.count {
                if sub.endsWithBlankLine || sub.lastLineBlank {
                    return false
                }
            }
        }
        return true
    }

    private func extractTaskCheckbox(from inlines: [MarkdownInline]) -> (checked: Bool, remaining: [MarkdownInline])? {
        guard let first = inlines.first, case .text(let s) = first else { return nil }
        let bytes = Array(s.utf8)
        guard bytes.count >= 4,
              bytes[0] == 0x5B, // '['
              bytes[2] == 0x5D, // ']'
              (bytes[1] == 0x20 || bytes[1] == 0x78 || bytes[1] == 0x58),
              mdIsAsciiSpaceOrTab(bytes[3])
        else {
            return nil
        }
        let checked = bytes[1] != 0x20
        var remaining = inlines
        var nextIdx = 4
        while nextIdx < bytes.count && mdIsAsciiSpaceOrTab(bytes[nextIdx]) { nextIdx += 1 }
        if nextIdx < bytes.count {
            remaining[0] = .text(String(decoding: bytes[nextIdx...], as: UTF8.self))
        } else {
            remaining.removeFirst()
        }
        return (checked, remaining)
    }

    private func trimParagraphTrailingSpaces(_ text: String) -> String {
        var bytes = Array(text.utf8)
        while let last = bytes.last, mdIsAsciiSpaceOrTab(last) {
            bytes.removeLast()
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func parseInlines(_ content: String) -> [MarkdownInline] {
        var inlineParser = MarkdownInlineParser(
            content: content,
            definitions: definitions,
            options: options
        )
        return inlineParser.parse()
    }
}

// MARK: - Shared Link/HTML Scanners

private func mdIsBlankLine(_ line: String) -> Bool {
    line.utf8.allSatisfy(mdIsAsciiSpaceOrTab)
}

private func mdTrimAsciiSpaceAndTab(_ bytes: [UInt8]) -> String {
    var start = 0
    var end = bytes.count
    while start < end && mdIsAsciiSpaceOrTab(bytes[start]) { start += 1 }
    while end > start && mdIsAsciiSpaceOrTab(bytes[end - 1]) { end -= 1 }
    return String(decoding: bytes[start..<end], as: UTF8.self)
}

private func mdContainsBytes(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
    guard !needle.isEmpty, haystack.count >= needle.count else { return false }
    let limit = haystack.count - needle.count
    for i in 0...limit {
        var ok = true
        for j in 0..<needle.count where haystack[i + j] != needle[j] {
            ok = false
            break
        }
        if ok { return true }
    }
    return false
}

private func mdSkipOptionalWhitespaceOneNewline(_ bytes: [UInt8], from start: Int) -> Int {
    var i = start
    while i < bytes.count && mdIsAsciiSpaceOrTab(bytes[i]) { i += 1 }
    if i < bytes.count && bytes[i] == 0x0A {
        i += 1
        while i < bytes.count && mdIsAsciiSpaceOrTab(bytes[i]) { i += 1 }
    }
    return i
}

// parity: native/src/markdown-inline.zig#scanLinkLabel [status=implemented hash=c82d5099f542]
private func mdScanLinkLabel(_ bytes: [UInt8], at start: Int) -> (rawLabel: String, endIndex: Int)? {
    guard start < bytes.count && bytes[start] == 0x5B else { return nil }
    var i = start + 1
    var scalars = 0
    while i < bytes.count {
        let b = bytes[i]
        if b == 0x5D { // ']'
            let raw = String(decoding: bytes[(start + 1)..<i], as: UTF8.self)
            return (raw, i + 1)
        }
        if b == 0x5B { return nil } // unescaped '[' disallowed
        if b == 0x5C && i + 1 < bytes.count {
            scalars += 2
            if scalars > 999 { return nil }
            i += 2
            continue
        }
        let dec = mdDecodeScalarAt(bytes, i)
        scalars += 1
        if scalars > 999 { return nil }
        i += max(1, dec.length)
    }
    return nil
}

// parity: native/src/markdown-inline.zig#scanDestination [status=implemented hash=cea75bae89ea]
private func mdScanLinkDestination(_ bytes: [UInt8], at start: Int) -> (rawDestination: String, endIndex: Int)? {
    guard start < bytes.count else { return nil }
    if bytes[start] == 0x3C { // '<'
        var i = start + 1
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x3E { // '>'
                return (String(decoding: bytes[(start + 1)..<i], as: UTF8.self), i + 1)
            }
            if b == 0x0A || b == 0x3C { return nil }
            if b == 0x5C && i + 1 < bytes.count && mdIsAsciiPunctuation(bytes[i + 1]) {
                i += 2
                continue
            }
            i += 1
        }
        return nil
    }

    var i = start
    var parens = 0
    while i < bytes.count {
        let b = bytes[i]
        if b <= 0x20 || b == 0x7F { break }
        if b == 0x5C && i + 1 < bytes.count && mdIsAsciiPunctuation(bytes[i + 1]) {
            i += 2
            continue
        }
        if b == 0x28 { // '('
            parens += 1
            if parens > 32 { return nil }
            i += 1
            continue
        }
        if b == 0x29 { // ')'
            if parens == 0 { break }
            parens -= 1
            i += 1
            continue
        }
        i += 1
    }
    guard i > start && parens == 0 else { return nil }
    return (String(decoding: bytes[start..<i], as: UTF8.self), i)
}

// parity: native/src/markdown-inline.zig#scanTitle [status=implemented hash=23b6e85ee7df]
private func mdScanLinkTitle(_ bytes: [UInt8], at start: Int) -> (rawTitle: String, endIndex: Int)? {
    guard start < bytes.count else { return nil }
    let opener = bytes[start]
    let closer: UInt8
    switch opener {
    case 0x22: closer = 0x22 // '"'
    case 0x27: closer = 0x27 // '\''
    case 0x28: closer = 0x29 // '(' -> ')'
    default: return nil
    }
    var i = start + 1
    while i < bytes.count {
        let b = bytes[i]
        if b == closer {
            return (String(decoding: bytes[(start + 1)..<i], as: UTF8.self), i + 1)
        }
        if opener == 0x28 && b == 0x28 { return nil } // unescaped '(' inside '(...)' title
        if b == 0x5C && i + 1 < bytes.count && mdIsAsciiPunctuation(bytes[i + 1]) {
            i += 2
            continue
        }
        if b == 0x0A {
            // Blank line disallowed inside title (spec 197)
            var j = i + 1
            while j < bytes.count && mdIsAsciiSpaceOrTab(bytes[j]) { j += 1 }
            if j < bytes.count && bytes[j] == 0x0A { return nil }
        }
        i += 1
    }
    return nil
}

// parity: native/src/markdown-inline.zig#scanOpenTag [status=implemented hash=14c6b255baec]
private func mdScanOpenTag(_ bytes: [UInt8], at start: Int, allowNewlines: Bool = true) -> Int? {
    var i = start
    guard i + 2 < bytes.count && bytes[i] == 0x3C else { return nil }
    i += 1
    guard mdIsAsciiAlpha(bytes[i]) else { return nil }
    i += 1
    while i < bytes.count && (mdIsAsciiAlnum(bytes[i]) || bytes[i] == 0x2D) { i += 1 }

    while true {
        let wsStart = i
        while i < bytes.count && (mdIsAsciiSpaceOrTab(bytes[i]) || (allowNewlines && bytes[i] == 0x0A)) {
            i += 1
        }
        if i >= bytes.count { return nil }
        if bytes[i] == 0x3E { return i + 1 }
        if bytes[i] == 0x2F {
            if i + 1 < bytes.count && bytes[i + 1] == 0x3E { return i + 2 }
            return nil
        }
        // Attribute must be preceded by whitespace
        guard i > wsStart else { return nil }
        guard mdIsAsciiAlpha(bytes[i]) || bytes[i] == 0x5F || bytes[i] == 0x3A else { return nil }
        i += 1
        while i < bytes.count
            && (mdIsAsciiAlnum(bytes[i]) || bytes[i] == 0x5F || bytes[i] == 0x2E || bytes[i] == 0x3A || bytes[i] == 0x2D)
        {
            i += 1
        }
        let afterName = i
        while i < bytes.count && (mdIsAsciiSpaceOrTab(bytes[i]) || (allowNewlines && bytes[i] == 0x0A)) {
            i += 1
        }
        if i < bytes.count && bytes[i] == 0x3D { // '='
            i += 1
            while i < bytes.count && (mdIsAsciiSpaceOrTab(bytes[i]) || (allowNewlines && bytes[i] == 0x0A)) {
                i += 1
            }
            guard i < bytes.count else { return nil }
            let q = bytes[i]
            if q == 0x22 || q == 0x27 {
                i += 1
                while i < bytes.count && bytes[i] != q {
                    if !allowNewlines && bytes[i] == 0x0A { return nil }
                    i += 1
                }
                guard i < bytes.count else { return nil }
                i += 1
            } else {
                let valStart = i
                while i < bytes.count {
                    let c = bytes[i]
                    if mdIsAsciiWhitespace(c) || c == 0x22 || c == 0x27 || c == 0x3D || c == 0x3C || c == 0x3E || c == 0x60 {
                        break
                    }
                    i += 1
                }
                guard i > valStart else { return nil }
            }
        } else {
            i = afterName
        }
    }
}

// parity: native/src/markdown-inline.zig#scanHtmlTag [status=implemented hash=9c54c9b85991]
private func mdScanInlineHTML(_ bytes: [UInt8], at start: Int) -> Int? {
    guard start + 2 < bytes.count && bytes[start] == 0x3C else { return nil }
    let next = bytes[start + 1]

    // Closing tag: </tagname \s*>
    if next == 0x2F {
        var i = start + 2
        guard i < bytes.count && mdIsAsciiAlpha(bytes[i]) else { return nil }
        i += 1
        while i < bytes.count && (mdIsAsciiAlnum(bytes[i]) || bytes[i] == 0x2D) { i += 1 }
        while i < bytes.count && (mdIsAsciiSpaceOrTab(bytes[i]) || bytes[i] == 0x0A) { i += 1 }
        if i < bytes.count && bytes[i] == 0x3E { return i + 1 }
        return nil
    }

    // Comment, Declaration, CDATA
    if next == 0x21 {
        // HTML comment (CommonMark 0.31.2: <!--> or <!---> or <!-- ... -->)
        if start + 3 < bytes.count && bytes[start + 2] == 0x2D && bytes[start + 3] == 0x2D {
            if start + 4 < bytes.count && bytes[start + 4] == 0x3E { return start + 5 }
            if start + 5 < bytes.count && bytes[start + 4] == 0x2D && bytes[start + 5] == 0x3E { return start + 6 }
            var i = start + 4
            while i + 2 < bytes.count {
                if bytes[i] == 0x2D && bytes[i + 1] == 0x2D {
                    if bytes[i + 2] == 0x3E { return i + 3 }
                    // CommonMark 0.31.2 allows '--' inside comment body
                }
                i += 1
            }
            return nil
        }
        // CDATA: <![CDATA[ ... ]]>
        if start + 9 <= bytes.count && String(decoding: bytes[start..<(start + 9)], as: UTF8.self) == "<![CDATA[" {
            var i = start + 9
            while i + 2 < bytes.count {
                if bytes[i] == 0x5D && bytes[i + 1] == 0x5D && bytes[i + 2] == 0x3E {
                    return i + 3
                }
                i += 1
            }
            return nil
        }
        // Declaration: <!NAME ... >
        if start + 2 < bytes.count && mdIsAsciiAlpha(bytes[start + 2]) {
            var i = start + 3
            while i < bytes.count && mdIsAsciiAlpha(bytes[i]) { i += 1 }
            guard i < bytes.count && mdIsAsciiWhitespace(bytes[i]) else { return nil }
            while i < bytes.count && bytes[i] != 0x3E { i += 1 }
            if i < bytes.count { return i + 1 }
            return nil
        }
        return nil
    }

    // Processing instruction: <? ... ?>
    if next == 0x3F {
        var i = start + 2
        while i + 1 < bytes.count {
            if bytes[i] == 0x3F && bytes[i + 1] == 0x3E {
                return i + 2
            }
            i += 1
        }
        return nil
    }

    // Open tag
    return mdScanOpenTag(bytes, at: start, allowNewlines: true)
}

// MARK: - Inline Parser (CommonMark 6 + GFM + Math)

private struct MarkdownInlineParser {
    let bytes: [UInt8]
    let definitions: [String: MarkdownLinkDefinition]
    let options: MarkdownParseOptions

    private final class InlineItem {
        var node: MarkdownInline
        var mergeableText: Bool
        var plainForEmail: Bool
        var prev: InlineItem?
        var next: InlineItem?

        init(_ node: MarkdownInline, mergeableText: Bool = false, plainForEmail: Bool = false) {
            self.node = node
            self.mergeableText = mergeableText
            self.plainForEmail = plainForEmail
        }
    }

    private final class DelimiterEntry {
        var item: InlineItem
        let char: UInt8
        let origLength: Int
        var length: Int
        let canOpen: Bool
        let canClose: Bool
        var prev: DelimiterEntry?
        var next: DelimiterEntry?

        init(
            item: InlineItem,
            char: UInt8,
            length: Int,
            canOpen: Bool,
            canClose: Bool
        ) {
            self.item = item
            self.char = char
            self.origLength = length
            self.length = length
            self.canOpen = canOpen
            self.canClose = canClose
        }
    }

    private final class BracketEntry {
        let item: InlineItem
        let index: Int
        let isImage: Bool
        var active: Bool = true
        let prevDelimiter: DelimiterEntry?
        let prevBracket: BracketEntry?

        init(
            item: InlineItem,
            index: Int,
            isImage: Bool,
            prevDelimiter: DelimiterEntry?,
            prevBracket: BracketEntry?
        ) {
            self.item = item
            self.index = index
            self.isImage = isImage
            self.prevDelimiter = prevDelimiter
            self.prevBracket = prevBracket
        }
    }

    private var head: InlineItem? = nil
    private var tail: InlineItem? = nil
    private var delimTop: DelimiterEntry? = nil
    private var bracketTop: BracketEntry? = nil

    init(
        content: String,
        definitions: [String: MarkdownLinkDefinition],
        options: MarkdownParseOptions
    ) {
        self.bytes = Array(content.utf8)
        self.definitions = definitions
        self.options = options
    }

    private mutating func appendItem(
        _ node: MarkdownInline,
        mergeableText: Bool = false,
        plainForEmail: Bool = false
    ) -> InlineItem {
        let item = InlineItem(node, mergeableText: mergeableText, plainForEmail: plainForEmail)
        if let t = tail {
            t.next = item
            item.prev = t
            tail = item
        } else {
            head = item
            tail = item
        }
        return item
    }

    private mutating func appendText(_ str: String, plainForEmail: Bool = true) {
        if str.isEmpty { return }
        if let t = tail, t.mergeableText, t.plainForEmail == plainForEmail, case .text(let existing) = t.node {
            t.node = .text(existing + str)
        } else {
            _ = appendItem(.text(str), mergeableText: true, plainForEmail: plainForEmail)
        }
    }

    private mutating func pushDelimiter(_ entry: DelimiterEntry) {
        if let top = delimTop {
            top.next = entry
            entry.prev = top
        }
        delimTop = entry
    }

    private mutating func removeDelimiter(_ entry: DelimiterEntry) {
        if let p = entry.prev { p.next = entry.next }
        if let n = entry.next { n.prev = entry.prev }
        else if delimTop === entry { delimTop = entry.prev }
        entry.prev = nil
        entry.next = nil
    }

    mutating func parse() -> [MarkdownInline] {
        var pos = 0
        while pos < bytes.count {
            let b = bytes[pos]
            switch b {
            case 0x0A: // '\n'
                pos = handleNewline(at: pos)
            case 0x5C: // '\\'
                pos = handleBackslash(at: pos)
            case 0x60: // '`'
                pos = handleBackticks(at: pos)
            case 0x2A, 0x5F, 0x7E: // '*', '_', '~'
                if b == 0x7E && !options.enableGFM {
                    appendText("~")
                    pos += 1
                } else {
                    pos = handleDelimiter(at: pos, char: b)
                }
            case 0x5B: // '['
                let item = appendItem(.text("["))
                bracketTop = BracketEntry(
                    item: item,
                    index: pos,
                    isImage: false,
                    prevDelimiter: delimTop,
                    prevBracket: bracketTop
                )
                pos += 1
            case 0x21: // '!'
                if pos + 1 < bytes.count && bytes[pos + 1] == 0x5B {
                    let item = appendItem(.text("!["))
                    bracketTop = BracketEntry(
                        item: item,
                        index: pos,
                        isImage: true,
                        prevDelimiter: delimTop,
                        prevBracket: bracketTop
                    )
                    pos += 2
                } else {
                    appendText("!")
                    pos += 1
                }
            case 0x5D: // ']'
                pos = handleCloseBracket(at: pos)
            case 0x3C: // '<'
                pos = handleLessThan(at: pos)
            case 0x26: // '&'
                if let ent = mdScanEntity(bytes, at: pos) {
                    appendText(ent.decoded, plainForEmail: false)
                    pos = ent.end
                } else {
                    appendText("&")
                    pos += 1
                }
            case 0x24: // '$'
                if options.enableMath {
                    pos = handleDollarMath(at: pos)
                } else {
                    appendText("$")
                    pos += 1
                }
            default:
                // Check GFM extended URL / www / mailto / xmpp autolinks
                if options.enableGFM, let ext = tryExtendedAutolink(at: pos) {
                    _ = appendItem(ext.node)
                    pos = ext.endIndex
                } else {
                    pos = handlePlainText(at: pos)
                }
            }
        }

        processEmphasis(stackBottom: nil)
        let rawNodes = collectNodesWithEmails(from: head, to: nil)
        return mergeAdjacentText(rawNodes)
    }

    private func isInlineSpecial(_ b: UInt8) -> Bool {
        switch b {
        case 0x0A, 0x5C, 0x60, 0x2A, 0x5F, 0x5B, 0x21, 0x5D, 0x3C, 0x26:
            return true
        case 0x7E:
            return options.enableGFM
        case 0x24:
            return options.enableMath
        case 0x77, 0x68, 0x48, 0x66, 0x46, 0x6D, 0x4D, 0x78, 0x58: // w, h/H, f/F, m/M, x/X for GFM autolinks
            return options.enableGFM
        default:
            return false
        }
    }

    private mutating func handlePlainText(at start: Int) -> Int {
        var i = start + 1
        while i < bytes.count && !isInlineSpecial(bytes[i]) {
            i += 1
        }
        appendText(String(decoding: bytes[start..<i], as: UTF8.self))
        return i
    }

    private mutating func handleNewline(at pos: Int) -> Int {
        var spaces = 0
        if let t = tail, case .text(let s) = t.node {
            var tb = Array(s.utf8)
            while tb.last == 0x20 {
                tb.removeLast()
                spaces += 1
            }
            if spaces > 0 {
                if tb.isEmpty {
                    removeItem(t)
                } else {
                    t.node = .text(String(decoding: tb, as: UTF8.self))
                }
            }
        }
        var next = pos + 1
        while next < bytes.count && mdIsAsciiSpaceOrTab(bytes[next]) { next += 1 }
        _ = appendItem(spaces >= 2 ? .hardBreak : .softBreak)
        return next
    }

    private mutating func handleBackslash(at pos: Int) -> Int {
        if pos + 1 >= bytes.count {
            appendText("\\")
            return pos + 1
        }
        let next = bytes[pos + 1]
        if next == 0x0A {
            var after = pos + 2
            while after < bytes.count && mdIsAsciiSpaceOrTab(bytes[after]) { after += 1 }
            _ = appendItem(.hardBreak)
            return after
        }
        if options.enableMath && next == 0x28 { // '\('
            if let closeIdx = findParenMathClose(from: pos + 2) {
                let body = String(decoding: bytes[(pos + 2)..<closeIdx], as: UTF8.self)
                _ = appendItem(.math(body))
                return closeIdx + 2
            }
        }
        if mdIsAsciiPunctuation(next) {
            appendText(String(UnicodeScalar(next)), plainForEmail: false)
            return pos + 2
        }
        appendText("\\")
        return pos + 1
    }

    private func findParenMathClose(from start: Int) -> Int? {
        var i = start
        while i < bytes.count {
            if bytes[i] == 0x5C && i + 1 < bytes.count {
                if bytes[i + 1] == 0x29 { return i }
                i += 2
                continue
            }
            if bytes[i] == 0x0A && i + 1 < bytes.count && bytes[i + 1] == 0x0A {
                return nil
            }
            i += 1
        }
        return nil
    }

    private mutating func handleDollarMath(at pos: Int) -> Int {
        var runEnd = pos
        while runEnd < bytes.count && bytes[runEnd] == 0x24 { runEnd += 1 }
        let runLen = runEnd - pos
        if runLen != 1 {
            appendText(String(repeating: "$", count: runLen))
            return runEnd
        }
        let beforeDigit = pos > 0 && mdIsAsciiDigit(bytes[pos - 1])
        let next = pos + 1
        if beforeDigit || next >= bytes.count || mdIsAsciiWhitespace(bytes[next]) {
            appendText("$")
            return next
        }
        var i = next
        while i < bytes.count {
            let c = bytes[i]
            if c == 0x5C {
                if i + 1 >= bytes.count { break }
                i += 2
                continue
            }
            if c == 0x60 || (c == 0x0A && i + 1 < bytes.count && bytes[i + 1] == 0x0A) {
                break
            }
            if c == 0x24 {
                let closes = !mdIsAsciiWhitespace(bytes[i - 1])
                    && (i + 1 >= bytes.count || (!mdIsAsciiDigit(bytes[i + 1]) && bytes[i + 1] != 0x24))
                if closes {
                    let body = String(decoding: bytes[next..<i], as: UTF8.self)
                    _ = appendItem(.math(body))
                    return i + 1
                }
                break
            }
            i += 1
        }
        appendText("$")
        return next
    }

    private mutating func handleBackticks(at pos: Int) -> Int {
        var openEnd = pos
        while openEnd < bytes.count && bytes[openEnd] == 0x60 { openEnd += 1 }
        let tickCount = openEnd - pos

        var i = openEnd
        while i < bytes.count {
            if bytes[i] == 0x60 {
                let closeStart = i
                while i < bytes.count && bytes[i] == 0x60 { i += 1 }
                if i - closeStart == tickCount {
                    var body = Array(bytes[openEnd..<closeStart])
                    for k in 0..<body.count where body[k] == 0x0A {
                        body[k] = 0x20
                    }
                    if body.count >= 2 && body.first == 0x20 && body.last == 0x20
                        && body.contains(where: { $0 != 0x20 })
                    {
                        body.removeFirst()
                        body.removeLast()
                    }
                    _ = appendItem(.codeSpan(String(decoding: body, as: UTF8.self)))
                    return i
                }
            } else {
                i += 1
            }
        }

        appendText(String(repeating: "`", count: tickCount))
        return openEnd
    }

    private mutating func handleDelimiter(at pos: Int, char: UInt8) -> Int {
        var end = pos
        while end < bytes.count && bytes[end] == char { end += 1 }
        let len = end - pos

        // GFM strikethrough only allows runs of length 1 or 2
        if char == 0x7E && len > 2 {
            appendText(String(repeating: "~", count: len))
            return end
        }

        let before = mdScalarBefore(bytes, pos)
        let after = mdDecodeScalarAt(bytes, end).scalar

        let beforeWs = mdIsUnicodeWhitespace(before)
        let afterWs = mdIsUnicodeWhitespace(after)
        let beforePunc = mdIsUnicodePunctuation(before)
        let afterPunc = mdIsUnicodePunctuation(after)

        let leftFlanking = !afterWs && (!afterPunc || beforeWs || beforePunc)
        let rightFlanking = !beforeWs && (!beforePunc || afterWs || afterPunc)

        let canOpen: Bool
        let canClose: Bool
        if char == 0x5F { // '_'
            canOpen = leftFlanking && (!rightFlanking || beforePunc)
            canClose = rightFlanking && (!leftFlanking || afterPunc)
        } else {
            canOpen = leftFlanking
            canClose = rightFlanking
        }

        let rawStr = String(repeating: String(UnicodeScalar(char)), count: len)
        let item = appendItem(.text(rawStr), mergeableText: false, plainForEmail: true)
        if canOpen || canClose {
            pushDelimiter(DelimiterEntry(
                item: item,
                char: char,
                length: len,
                canOpen: canOpen,
                canClose: canClose
            ))
        }
        return end
    }

    private mutating func handleLessThan(at pos: Int) -> Int {
        // 1. URI Autolink: <scheme:...>
        if let uri = scanURIAutolink(at: pos) {
            _ = appendItem(.link(destination: uri.destination, title: nil, children: [.text(uri.label)]))
            return uri.endIndex
        }
        // 2. Email Autolink: <user@host>
        if let email = scanEmailAutolink(at: pos) {
            _ = appendItem(.link(destination: "mailto:" + email.address, title: nil, children: [.text(email.address)]))
            return email.endIndex
        }
        // 3. Inline raw HTML
        if let htmlEnd = mdScanInlineHTML(bytes, at: pos) {
            let raw = String(decoding: bytes[pos..<htmlEnd], as: UTF8.self)
            _ = appendItem(.rawHTML(raw))
            return htmlEnd
        }
        appendText("<")
        return pos + 1
    }

    private func scanURIAutolink(at start: Int) -> (label: String, destination: String, endIndex: Int)? {
        guard start + 4 < bytes.count && bytes[start] == 0x3C else { return nil }
        var i = start + 1
        guard mdIsAsciiAlpha(bytes[i]) else { return nil }
        i += 1
        while i < bytes.count {
            let b = bytes[i]
            if mdIsAsciiAlnum(b) || b == 0x2B || b == 0x2D || b == 0x2E {
                i += 1
            } else {
                break
            }
        }
        let schemeLen = i - (start + 1)
        guard schemeLen >= 2 && schemeLen <= 32, i < bytes.count && bytes[i] == 0x3A else { return nil }
        i += 1
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x3E {
                let raw = String(decoding: bytes[(start + 1)..<i], as: UTF8.self)
                return (raw, raw, i + 1)
            }
            if b <= 0x20 || b == 0x3C { return nil }
            i += 1
        }
        return nil
    }

    private func scanEmailAutolink(at start: Int) -> (address: String, endIndex: Int)? {
        guard start + 4 < bytes.count && bytes[start] == 0x3C else { return nil }
        var i = start + 1
        let localStart = i
        while i < bytes.count {
            let b = bytes[i]
            if mdIsAsciiAlnum(b) || b == 0x2E || b == 0x21 || b == 0x23 || b == 0x24 || b == 0x25
                || b == 0x26 || b == 0x27 || b == 0x2A || b == 0x2B || b == 0x2F || b == 0x3D
                || b == 0x3F || b == 0x5E || b == 0x5F || b == 0x60 || b == 0x7B || b == 0x7C
                || b == 0x7D || b == 0x7E || b == 0x2D
            {
                i += 1
            } else {
                break
            }
        }
        guard i > localStart && i < bytes.count && bytes[i] == 0x40 else { return nil } // '@'
        i += 1
        var labelCount = 0
        while i < bytes.count {
            let segStart = i
            while i < bytes.count && (mdIsAsciiAlnum(bytes[i]) || bytes[i] == 0x2D) {
                i += 1
            }
            let segLen = i - segStart
            guard segLen >= 1 && segLen <= 63 else { return nil }
            guard bytes[segStart] != 0x2D && bytes[i - 1] != 0x2D else { return nil }
            labelCount += 1
            if i < bytes.count && bytes[i] == 0x2E {
                i += 1
                continue
            }
            break
        }
        guard labelCount >= 1 && i < bytes.count && bytes[i] == 0x3E else { return nil }
        let addr = String(decoding: bytes[(start + 1)..<i], as: UTF8.self)
        return (addr, i + 1)
    }

    private mutating func handleCloseBracket(at pos: Int) -> Int {
        guard let opener = bracketTop else {
            appendText("]")
            return pos + 1
        }
        bracketTop = opener.prevBracket

        if !opener.active {
            appendText("]")
            return pos + 1
        }

        var matchedDest: String? = nil
        var matchedTitle: String? = nil
        var endPos = pos + 1

        // 1. Inline link: ](destination "title")
        if endPos < bytes.count && bytes[endPos] == 0x28 { // '('
            var i = endPos + 1
            while i < bytes.count && mdIsAsciiWhitespace(bytes[i]) { i += 1 }
            if i < bytes.count && bytes[i] == 0x29 { // empty ()
                matchedDest = ""
                matchedTitle = nil
                endPos = i + 1
            } else if let destScan = mdScanLinkDestination(bytes, at: i) {
                let dest = mdUnescapeString(destScan.rawDestination)
                i = destScan.endIndex
                let beforeWs = i
                while i < bytes.count && mdIsAsciiWhitespace(bytes[i]) { i += 1 }
                if i < bytes.count && bytes[i] == 0x29 {
                    matchedDest = dest
                    matchedTitle = nil
                    endPos = i + 1
                } else if i > beforeWs, let titleScan = mdScanLinkTitle(bytes, at: i) {
                    var afterTitle = titleScan.endIndex
                    while afterTitle < bytes.count && mdIsAsciiWhitespace(bytes[afterTitle]) { afterTitle += 1 }
                    if afterTitle < bytes.count && bytes[afterTitle] == 0x29 {
                        matchedDest = dest
                        matchedTitle = mdUnescapeString(titleScan.rawTitle)
                        endPos = afterTitle + 1
                    }
                }
            }
        }

        // 2. Reference link: full [text][label], collapsed [text][], or shortcut [text]
        if matchedDest == nil {
            var refLabel: String? = nil
            var candidateEnd = pos + 1

            if candidateEnd < bytes.count && bytes[candidateEnd] == 0x5B { // '['
                if candidateEnd + 1 < bytes.count && bytes[candidateEnd + 1] == 0x5D {
                    // Collapsed reference [text][]
                    let rawStart = opener.index + (opener.isImage ? 2 : 1)
                    if let labelCheck = mdScanLinkLabel(bytes, at: rawStart - 1), labelCheck.endIndex == pos + 1 {
                        refLabel = labelCheck.rawLabel
                        candidateEnd += 2
                    }
                } else if let fullLabel = mdScanLinkLabel(bytes, at: candidateEnd) {
                    refLabel = fullLabel.rawLabel
                    candidateEnd = fullLabel.endIndex
                }
            }

            // Shortcut reference [text] (only if not followed by '[')
            if refLabel == nil {
                let rawStart = opener.index + (opener.isImage ? 2 : 1)
                if let labelCheck = mdScanLinkLabel(bytes, at: rawStart - 1), labelCheck.endIndex == pos + 1 {
                    refLabel = labelCheck.rawLabel
                    candidateEnd = pos + 1
                }
            }

            if let label = refLabel {
                let norm = mdNormalizeLabel(label)
                if !norm.isEmpty, let def = definitions[norm] {
                    matchedDest = def.destination
                    matchedTitle = def.title
                    endPos = candidateEnd
                }
            }
        }

        guard let destination = matchedDest else {
            appendText("]")
            return pos + 1
        }

        // Process emphasis inside the link/image label
        processEmphasis(stackBottom: opener.prevDelimiter)

        // Collect child nodes between opener.item.next and tail
        let children = mergeAdjacentText(collectNodes(from: opener.item.next, to: nil))
        let node: MarkdownInline = opener.isImage
            ? .image(destination: destination, title: matchedTitle, alt: children)
            : .link(destination: destination, title: matchedTitle, children: children)

        // Replace opener.item..tail with the single link/image item
        opener.item.node = node
        opener.item.next = nil
        tail = opener.item

        // If this was a link (not an image), deactivate all earlier non-image brackets (CommonMark 6.5)
        if !opener.isImage {
            var b = bracketTop
            while let cur = b {
                if !cur.isImage { cur.active = false }
                b = cur.prevBracket
            }
        }

        return endPos
    }

    // MARK: - Emphasis / Strong / Strikethrough Delimiter Matching (CommonMark 6.2)

    private mutating func processEmphasis(stackBottom: DelimiterEntry?) {
        // Track earliest failed opener search per (char, closerLen % 3, closerCanOpen)
        var openersBottom: [Int: DelimiterEntry?] = [:]
        func bottomKey(_ char: UInt8, _ lenMod3: Int, _ canOpen: Bool) -> Int {
            (Int(char) << 3) | (lenMod3 << 1) | (canOpen ? 1 : 0)
        }

        var closer = stackBottom == nil ? findFirstDelimiter() : stackBottom?.next
        while let curCloser = closer {
            if !curCloser.canClose {
                closer = curCloser.next
                continue
            }

            let key = bottomKey(curCloser.char, curCloser.origLength % 3, curCloser.canOpen)
            let stopAt = openersBottom[key] ?? stackBottom

            var opener = curCloser.prev
            var foundOpener: DelimiterEntry? = nil
            while let cand = opener, cand !== stopAt, cand !== stackBottom {
                if cand.char == curCloser.char && cand.canOpen {
                    if curCloser.char == 0x7E { // GFM strikethrough: exact length match (1 or 2)
                        if cand.length == curCloser.length {
                            foundOpener = cand
                            break
                        }
                    } else {
                        // CommonMark rule of 3
                        let oddMatch = (cand.canClose || curCloser.canOpen)
                            && (cand.origLength + curCloser.origLength) % 3 == 0
                            && !(cand.origLength % 3 == 0 && curCloser.origLength % 3 == 0)
                        if !oddMatch {
                            foundOpener = cand
                            break
                        }
                    }
                }
                opener = cand.prev
            }

            guard let matchedOpener = foundOpener else {
                openersBottom[key] = curCloser.prev
                if !curCloser.canOpen {
                    let next = curCloser.next
                    removeDelimiter(curCloser)
                    closer = next
                } else {
                    closer = curCloser.next
                }
                continue
            }

            let useDelims: Int
            if curCloser.char == 0x7E {
                useDelims = curCloser.length
            } else {
                useDelims = (matchedOpener.length >= 2 && curCloser.length >= 2) ? 2 : 1
            }

            matchedOpener.length -= useDelims
            curCloser.length -= useDelims

            // Trim delimiter text items
            matchedOpener.item.node = .text(
                String(repeating: String(UnicodeScalar(matchedOpener.char)), count: matchedOpener.length)
            )
            curCloser.item.node = .text(
                String(repeating: String(UnicodeScalar(curCloser.char)), count: curCloser.length)
            )

            // Wrap items strictly between matchedOpener.item and curCloser.item
            let innerNodes = mergeAdjacentText(collectNodesWithEmails(from: matchedOpener.item.next, to: curCloser.item))
            let wrapped: MarkdownInline
            if curCloser.char == 0x7E {
                wrapped = .strikethrough(innerNodes)
            } else if useDelims == 2 {
                wrapped = .strong(innerNodes)
            } else {
                wrapped = .emphasis(innerNodes)
            }

            let wrappedItem = InlineItem(wrapped)
            wrappedItem.prev = matchedOpener.item
            wrappedItem.next = curCloser.item
            matchedOpener.item.next = wrappedItem
            curCloser.item.prev = wrappedItem

            // Remove any delimiters strictly between matchedOpener and curCloser
            var between = matchedOpener.next
            while let d = between, d !== curCloser {
                let nextD = d.next
                removeDelimiter(d)
                between = nextD
            }

            if matchedOpener.length == 0 {
                removeItem(matchedOpener.item)
                removeDelimiter(matchedOpener)
            }

            if curCloser.length == 0 {
                let nextCloser = curCloser.next
                removeItem(curCloser.item)
                removeDelimiter(curCloser)
                closer = nextCloser
            }
        }

        // Remove all remaining delimiters above stackBottom
        while let top = delimTop, top !== stackBottom {
            removeDelimiter(top)
        }
    }

    private func findFirstDelimiter() -> DelimiterEntry? {
        var cur = delimTop
        while let p = cur?.prev { cur = p }
        return cur
    }

    private mutating func removeItem(_ item: InlineItem) {
        if let p = item.prev { p.next = item.next } else { head = item.next }
        if let n = item.next { n.prev = item.prev } else { tail = item.prev }
        item.prev = nil
        item.next = nil
    }

    private func collectNodes(from start: InlineItem?, to stop: InlineItem?) -> [MarkdownInline] {
        var out: [MarkdownInline] = []
        var cur = start
        while let item = cur, item !== stop {
            out.append(item.node)
            cur = item.next
        }
        return out
    }

    private func collectNodesWithEmails(from start: InlineItem?, to stop: InlineItem?) -> [MarkdownInline] {
        if !options.enableGFM {
            return collectNodes(from: start, to: stop)
        }
        var out: [MarkdownInline] = []
        var plainBuf = ""
        func flushPlain() {
            if !plainBuf.isEmpty {
                out.append(contentsOf: splitBareEmails(in: plainBuf))
                plainBuf = ""
            }
        }
        var cur = start
        while let item = cur, item !== stop {
            if item.plainForEmail, case .text(let s) = item.node {
                plainBuf += s
            } else {
                flushPlain()
                out.append(item.node)
            }
            cur = item.next
        }
        flushPlain()
        return out
    }

    private func mergeAdjacentText(_ nodes: [MarkdownInline]) -> [MarkdownInline] {
        var out: [MarkdownInline] = []
        out.reserveCapacity(nodes.count)
        for node in nodes {
            if case .text(let s) = node {
                if s.isEmpty { continue }
                if case .text(let prev) = out.last {
                    out[out.count - 1] = .text(prev + s)
                } else {
                    out.append(node)
                }
            } else {
                out.append(node)
            }
        }
        return out
    }

    // MARK: - GFM Extended Autolinks (www, http/https/ftp, mailto, xmpp, bare email)

    private func isExtendedBoundary(_ b: UInt8) -> Bool {
        mdIsAsciiWhitespace(b) || b == 0x2A || b == 0x5F || b == 0x7E || b == 0x28
    }

    private func isPrecededByExtendedBoundary(at pos: Int) -> Bool {
        if pos == 0 { return true }
        // Must not follow a backslash-escaped character like \<https://a.b> (review rows 805-808)
        if tail == nil { return true }
        if case .text(let prevText) = tail?.node, let lastByte = prevText.utf8.last {
            return isExtendedBoundary(lastByte)
        }
        return isExtendedBoundary(bytes[pos - 1])
    }

    private func tryExtendedAutolink(at pos: Int) -> (node: MarkdownInline, endIndex: Int)? {
        guard isPrecededByExtendedBoundary(at: pos) else { return nil }
        // Make sure previous character in source was genuinely a boundary (not an escaped '<')
        if pos > 0 && !isExtendedBoundary(bytes[pos - 1]) { return nil }
        // Also check that we aren't immediately after an escaped delimiter (e.g. `\*www.a.b` or `\<https://a.b>`)
        if pos >= 2 && bytes[pos - 2] == 0x5C && mdIsAsciiPunctuation(bytes[pos - 1]) { return nil }

        let rest = bytes[pos...]

        // 1. www.domain...
        if rest.count >= 6
            && bytes[pos] == 0x77 && bytes[pos + 1] == 0x77 && bytes[pos + 2] == 0x77 && bytes[pos + 3] == 0x2E
        {
            if let end = scanExtendedURL(from: pos, isWWW: true) {
                let raw = String(decoding: bytes[pos..<end], as: UTF8.self)
                return (.link(destination: "http://" + raw, title: nil, children: [.text(raw)]), end)
            }
        }

        // 2. http://, https://, ftp://
        for scheme in ["https://", "http://", "ftp://"] {
            if mdStartsWithIgnoreAsciiCase(rest, scheme) {
                let domainStart = pos + scheme.utf8.count
                if let end = scanExtendedURL(from: domainStart, isWWW: false) {
                    let raw = String(decoding: bytes[pos..<end], as: UTF8.self)
                    return (.link(destination: raw, title: nil, children: [.text(raw)]), end)
                }
            }
        }

        // 3. mailto: / xmpp:
        for scheme in ["mailto:", "xmpp:"] {
            if mdStartsWithIgnoreAsciiCase(rest, scheme) {
                let addrStart = pos + scheme.utf8.count
                var i = addrStart
                while i < bytes.count && (mdIsAsciiAlnum(bytes[i]) || bytes[i] == 0x2E || bytes[i] == 0x2D || bytes[i] == 0x5F || bytes[i] == 0x2B) {
                    i += 1
                }
                if i > addrStart && i < bytes.count && bytes[i] == 0x40 {
                    if let email = scanBareEmail(in: bytes, runStart: addrStart, runEnd: bytes.count, atIndex: i),
                       email.start == addrStart
                    {
                        var end = email.end
                        if scheme == "xmpp:" && end < bytes.count && bytes[end] == 0x2F {
                            var j = end + 1
                            while j < bytes.count && (mdIsAsciiAlnum(bytes[j]) || bytes[j] == 0x40 || bytes[j] == 0x2E) {
                                j += 1
                            }
                            while j > end + 1 && bytes[j - 1] == 0x2E { j -= 1 }
                            if j > end + 1 { end = j }
                        }
                        let raw = String(decoding: bytes[pos..<end], as: UTF8.self)
                        return (.link(destination: raw, title: nil, children: [.text(raw)]), end)
                    }
                }
            }
        }

        return nil
    }

    private func scanExtendedURL(from domainStart: Int, isWWW: Bool) -> Int? {
        var i = domainStart
        var segments = 0
        var underscoreLast = false
        var underscorePrev = false

        while i < bytes.count {
            let segStart = i
            var underscore = false
            while i < bytes.count && (mdIsAsciiAlnum(bytes[i]) || bytes[i] == 0x2D || bytes[i] == 0x5F || bytes[i] >= 0x80) {
                if bytes[i] == 0x5F { underscore = true }
                i += 1
            }
            if i == segStart { break }
            segments += 1
            underscorePrev = underscoreLast
            underscoreLast = underscore
            if i < bytes.count && bytes[i] == 0x2E && i + 1 < bytes.count
                && (mdIsAsciiAlnum(bytes[i + 1]) || bytes[i + 1] == 0x2D || bytes[i + 1] == 0x5F || bytes[i + 1] >= 0x80)
            {
                i += 1
                continue
            }
            break
        }

        if segments == 0 || underscoreLast || underscorePrev { return nil }
        if isWWW && segments < 2 { return nil }

        // Path until whitespace or '<'
        while i < bytes.count && !mdIsAsciiWhitespace(bytes[i]) && bytes[i] != 0x3C {
            i += 1
        }

        // Trim trailing GFM punctuation, unbalanced ')', and trailing HTML entities
        var end = i
        while end > domainStart {
            let c = bytes[end - 1]
            if c == 0x3F || c == 0x21 || c == 0x2E || c == 0x2C || c == 0x3A
                || c == 0x2A || c == 0x5F || c == 0x7E || c == 0x27 || c == 0x22
            {
                end -= 1
                continue
            }
            if c == 0x29 { // ')'
                var openCount = 0
                var closeCount = 0
                for k in domainStart..<end {
                    if bytes[k] == 0x28 { openCount += 1 }
                    else if bytes[k] == 0x29 { closeCount += 1 }
                }
                if closeCount > openCount {
                    end -= 1
                    continue
                }
                break
            }
            if c == 0x3B { // ';'
                var j = end - 1
                while j > domainStart && mdIsAsciiAlnum(bytes[j - 1]) { j -= 1 }
                if j > domainStart && bytes[j - 1] == 0x26 && j < end - 1 {
                    end = j - 1
                    continue
                }
                break
            }
            break
        }
        return end > domainStart ? end : nil
    }

    private func scanBareEmail(
        in buf: [UInt8],
        runStart: Int,
        runEnd: Int,
        atIndex: Int
    ) -> (start: Int, end: Int)? {
        var start = atIndex
        while start > runStart && (mdIsAsciiAlnum(buf[start - 1]) || buf[start - 1] == 0x2E || buf[start - 1] == 0x2D || buf[start - 1] == 0x5F || buf[start - 1] == 0x2B) {
            start -= 1
        }
        if start == atIndex { return nil }
        var i = atIndex + 1
        var periods = 0
        while i < runEnd && (mdIsAsciiAlnum(buf[i]) || buf[i] == 0x2D || buf[i] == 0x5F || buf[i] == 0x2E) {
            if buf[i] == 0x2E && i + 1 < runEnd && mdIsAsciiAlnum(buf[i + 1]) {
                periods += 1
            }
            i += 1
        }
        while i > atIndex + 1 && buf[i - 1] == 0x2E { i -= 1 }
        if i == atIndex + 1 || periods == 0 { return nil }
        if buf[i - 1] == 0x2D || buf[i - 1] == 0x5F { return nil }
        // Make sure next char isn't '+' or invalid domain continuation like mail+xyz.example
        if i < runEnd && buf[i] == 0x2B { return nil }
        return (start, i)
    }

    private func applyExtendedEmailAutolinks(_ nodes: [MarkdownInline]) -> [MarkdownInline] {
        var out: [MarkdownInline] = []
        for node in nodes {
            switch node {
            case .text(let s):
                out.append(contentsOf: splitBareEmails(in: s))
            case .emphasis(let children):
                out.append(.emphasis(applyExtendedEmailAutolinks(children)))
            case .strong(let children):
                out.append(.strong(applyExtendedEmailAutolinks(children)))
            case .strikethrough(let children):
                out.append(.strikethrough(applyExtendedEmailAutolinks(children)))
            case .link, .image, .codeSpan, .rawHTML, .math, .softBreak, .hardBreak:
                out.append(node)
            }
        }
        return out
    }

    private func splitBareEmails(in text: String) -> [MarkdownInline] {
        let buf = Array(text.utf8)
        guard buf.contains(0x40) else { return [.text(text)] }
        var out: [MarkdownInline] = []
        var cursor = 0
        var i = 0
        while i < buf.count {
            if buf[i] == 0x40, let email = scanBareEmail(in: buf, runStart: cursor, runEnd: buf.count, atIndex: i) {
                if email.start > cursor && buf[email.start - 1] == 0x3A {
                    i += 1
                    continue
                }
                if email.start > cursor {
                    out.append(.text(String(decoding: buf[cursor..<email.start], as: UTF8.self)))
                }
                let addr = String(decoding: buf[email.start..<email.end], as: UTF8.self)
                out.append(.link(destination: "mailto:" + addr, title: nil, children: [.text(addr)]))
                cursor = email.end
                i = email.end
                continue
            }
            i += 1
        }
        if cursor < buf.count {
            out.append(.text(String(decoding: buf[cursor...], as: UTF8.self)))
        }
        return out
    }
}

// MARK: - Reference HTML Renderer (matching markdown-html.zig)

private enum MarkdownHTMLRenderer {
    static func render(_ blocks: [MarkdownBlock]) -> String {
        var out = ""
        for block in blocks {
            renderBlock(block, tight: false, into: &out)
        }
        return out
    }

    private static func renderBlock(_ block: MarkdownBlock, tight: Bool, into out: inout String) {
        switch block {
        case .paragraph(let inlines):
            if !tight { out += "<p>" }
            renderInlines(inlines, plainTextOnly: false, into: &out)
            if !tight { out += "</p>\n" }

        case .heading(let level, let content):
            out += "<h\(level)>"
            renderInlines(content, plainTextOnly: false, into: &out)
            out += "</h\(level)>\n"

        case .codeBlock(let info, let literal, _, let isMath):
            out += "<pre><code"
            if isMath {
                out += " class=\"language-math\""
            } else if let info, !info.isEmpty {
                let lang = info.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
                if !lang.isEmpty {
                    out += " class=\"language-"
                    escapeHTML(lang, into: &out)
                    out += "\""
                }
            }
            out += ">"
            escapeHTML(literal, into: &out)
            out += "</code></pre>\n"

        case .htmlBlock(let raw):
            out += raw
            out += "\n"

        case .thematicBreak:
            out += "<hr />\n"

        case .blockquote(let children):
            out += "<blockquote>\n"
            for child in children {
                renderBlock(child, tight: false, into: &out)
            }
            out += "</blockquote>\n"

        case .list(let ordered, let start, let isTight, let items):
            if ordered {
                if start != 1 {
                    out += "<ol start=\"\(start)\">\n"
                } else {
                    out += "<ol>\n"
                }
            } else {
                out += "<ul>\n"
            }

            for item in items {
                out += "<li>"
                if item.blocks.isEmpty {
                    if let checked = item.taskChecked {
                        out += checked
                            ? "<input checked=\"\" disabled=\"\" type=\"checkbox\"> "
                            : "<input disabled=\"\" type=\"checkbox\"> "
                    }
                    out += "</li>\n"
                    continue
                }
                for (idx, child) in item.blocks.enumerated() {
                    if idx == 0, let checked = item.taskChecked, case .paragraph(let inlines) = child {
                        if !isTight { out += "\n<p>" }
                        out += checked
                            ? "<input checked=\"\" disabled=\"\" type=\"checkbox\"> "
                            : "<input disabled=\"\" type=\"checkbox\"> "
                        renderInlines(inlines, plainTextOnly: false, into: &out)
                        if !isTight { out += "</p>\n" }
                        continue
                    }
                    if idx == 0 && !(isTight && isParagraph(child)) {
                        out += "\n"
                    } else if idx > 0 && isTight && isParagraph(item.blocks[idx - 1]) {
                        out += "\n"
                    }
                    renderBlock(child, tight: isTight, into: &out)
                }
                out += "</li>\n"
            }

            out += ordered ? "</ol>\n" : "</ul>\n"

        case .table(let alignments, let header, let rows):
            out += "<table>\n<thead>\n<tr>\n"
            for (col, cell) in header.enumerated() {
                out += "<th"
                appendAlignment(col < alignments.count ? alignments[col] : .none, into: &out)
                out += ">"
                renderInlines(cell, plainTextOnly: false, into: &out)
                out += "</th>\n"
            }
            out += "</tr>\n</thead>\n"
            if !rows.isEmpty {
                out += "<tbody>\n"
                for row in rows {
                    out += "<tr>\n"
                    for (col, cell) in row.enumerated() {
                        out += "<td"
                        appendAlignment(col < alignments.count ? alignments[col] : .none, into: &out)
                        out += ">"
                        renderInlines(cell, plainTextOnly: false, into: &out)
                        out += "</td>\n"
                    }
                    out += "</tr>\n"
                }
                out += "</tbody>\n"
            }
            out += "</table>\n"
        }
    }

    private static func isParagraph(_ block: MarkdownBlock) -> Bool {
        if case .paragraph = block { return true }
        return false
    }

    private static func appendAlignment(_ alignment: MarkdownTableAlignment, into out: inout String) {
        switch alignment {
        case .none: break
        case .left: out += " align=\"left\""
        case .center: out += " align=\"center\""
        case .right: out += " align=\"right\""
        }
    }

    private static func renderInlines(_ inlines: [MarkdownInline], plainTextOnly: Bool, into out: inout String) {
        for inline in inlines {
            switch inline {
            case .text(let s):
                escapeHTML(s, into: &out)
            case .softBreak:
                out += "\n"
            case .hardBreak:
                out += plainTextOnly ? "\n" : "<br />\n"
            case .codeSpan(let code):
                if !plainTextOnly { out += "<code>" }
                escapeHTML(code, into: &out)
                if !plainTextOnly { out += "</code>" }
            case .emphasis(let children):
                if !plainTextOnly { out += "<em>" }
                renderInlines(children, plainTextOnly: plainTextOnly, into: &out)
                if !plainTextOnly { out += "</em>" }
            case .strong(let children):
                if !plainTextOnly { out += "<strong>" }
                renderInlines(children, plainTextOnly: plainTextOnly, into: &out)
                if !plainTextOnly { out += "</strong>" }
            case .strikethrough(let children):
                if !plainTextOnly { out += "<del>" }
                renderInlines(children, plainTextOnly: plainTextOnly, into: &out)
                if !plainTextOnly { out += "</del>" }
            case .link(let dest, let title, let children):
                if !plainTextOnly {
                    out += "<a href=\""
                    encodeURL(dest, into: &out)
                    out += "\""
                    if let title {
                        out += " title=\""
                        escapeHTML(title, into: &out)
                        out += "\""
                    }
                    out += ">"
                }
                renderInlines(children, plainTextOnly: plainTextOnly, into: &out)
                if !plainTextOnly { out += "</a>" }
            case .image(let dest, let title, let alt):
                if !plainTextOnly {
                    out += "<img src=\""
                    encodeURL(dest, into: &out)
                    out += "\" alt=\""
                }
                renderInlines(alt, plainTextOnly: true, into: &out)
                if !plainTextOnly {
                    out += "\""
                    if let title {
                        out += " title=\""
                        escapeHTML(title, into: &out)
                        out += "\""
                    }
                    out += " />"
                }
            case .rawHTML(let raw):
                if !plainTextOnly { out += raw }
            case .math(let body):
                if !plainTextOnly { out += "<span class=\"math\">" }
                escapeHTML(body, into: &out)
                if !plainTextOnly { out += "</span>" }
            }
        }
    }

    private static func escapeHTML(_ text: String, into out: inout String) {
        for ch in text.unicodeScalars {
            switch ch.value {
            case 0x26: out += "&amp;"
            case 0x3C: out += "&lt;"
            case 0x3E: out += "&gt;"
            case 0x22: out += "&quot;"
            default: out.unicodeScalars.append(ch)
            }
        }
    }

    private static func encodeURL(_ url: String, into out: inout String) {
        let hexDigits: [Character] = Array("0123456789ABCDEF")
        let bytes = Array(url.utf8)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x25 && i + 2 < bytes.count && mdIsAsciiHex(bytes[i + 1]) && mdIsAsciiHex(bytes[i + 2]) {
                out.append("%")
                i += 1
                continue
            }
            if mdIsAsciiAlnum(b)
                || b == 0x3B || b == 0x2F || b == 0x3F || b == 0x3A || b == 0x40
                || b == 0x26 || b == 0x3D || b == 0x2B || b == 0x24 || b == 0x2C
                || b == 0x2D || b == 0x5F || b == 0x2E || b == 0x21 || b == 0x7E
                || b == 0x2A || b == 0x27 || b == 0x28 || b == 0x29 || b == 0x23
            {
                if b == 0x26 {
                    out += "&amp;"
                } else {
                    out.unicodeScalars.append(UnicodeScalar(b))
                }
            } else {
                out.append("%")
                out.append(hexDigits[Int((b >> 4) & 0xF)])
                out.append(hexDigits[Int(b & 0xF)])
            }
            i += 1
        }
    }
}
private enum MarkdownTables {
    // parity: native/src/markdown-tables.zig#space_separators [status=implemented hash=a5c32eb646b5]
    static let spaceSeparators: Set<UInt32> = [0x20, 0xA0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x202F, 0x205F, 0x3000]

    // parity: native/src/markdown-tables.zig#punctuation_ranges [status=implemented hash=a199cb3a8337]
    static let punctuationRanges: [(UInt32, UInt32)] = {
        let raw =
        """
        21-2F 3A-40 5B-60 7B-7E A1-A9 AB-AC AE-B1 B4 B6-B8 BB BF D7 F7 2C2-2C5 2D2-2DF 2E5-2EB 2ED 2EF-2FF \
        375 37E 384-385 387 3F6 482 55A-55F 589-58A 58D-58F 5BE 5C0 5C3 5C6 5F3-5F4 606-60F 61B 61D-61F \
        66A-66D 6D4 6DE 6E9 6FD-6FE 700-70D 7F6-7F9 7FE-7FF 830-83E 85E 888 964-965 970 9F2-9F3 9FA-9FB 9FD \
        A76 AF0-AF1 B70 BF3-BFA C77 C7F C84 D4F D79 DF4 E3F E4F E5A-E5B F01-F17 F1A-F1F F34 F36 F38 F3A-F3D \
        F85 FBE-FC5 FC7-FCC FCE-FDA 104A-104F 109E-109F 10FB 1360-1368 1390-1399 1400 166D-166E 169B-169C \
        16EB-16ED 1735-1736 17D4-17D6 17D8-17DB 1800-180A 1940 1944-1945 19DE-19FF 1A1E-1A1F 1AA0-1AA6 \
        1AA8-1AAD 1B4E-1B4F 1B5A-1B6A 1B74-1B7F 1BFC-1BFF 1C3B-1C3F 1C7E-1C7F 1CC0-1CC7 1CD3 1FBD 1FBF-1FC1 \
        1FCD-1FCF 1FDD-1FDF 1FED-1FEF 1FFD-1FFE 2010-2027 2030-205E 207A-207E 208A-208E 20A0-20C0 2100-2101 \
        2103-2106 2108-2109 2114 2116-2118 211E-2123 2125 2127 2129 212E 213A-213B 2140-2144 214A-214D 214F \
        218A-218B 2190-2429 2440-244A 249C-24E9 2500-2775 2794-2B73 2B76-2B95 2B97-2BFF 2CE5-2CEA 2CF9-2CFC \
        2CFE-2CFF 2D70 2E00-2E2E 2E30-2E5D 2E80-2E99 2E9B-2EF3 2F00-2FD5 2FF0-2FFF 3001-3004 3008-3020 3030 \
        3036-3037 303D-303F 309B-309C 30A0 30FB 3190-3191 3196-319F 31C0-31E5 31EF 3200-321E 322A-3247 3250 \
        3260-327F 328A-32B0 32C0-33FF 4DC0-4DFF A490-A4C6 A4FE-A4FF A60D-A60F A673 A67E A6F2-A6F7 A700-A716 \
        A720-A721 A789-A78A A828-A82B A836-A839 A874-A877 A8CE-A8CF A8F8-A8FA A8FC A92E-A92F A95F A9C1-A9CD \
        A9DE-A9DF AA5C-AA5F AA77-AA79 AADE-AADF AAF0-AAF1 AB5B AB6A-AB6B ABEB FB29 FBB2-FBC2 FD3E-FD4F FDCF \
        FDFC-FDFF FE10-FE19 FE30-FE52 FE54-FE66 FE68-FE6B FF01-FF0F FF1A-FF20 FF3B-FF40 FF5B-FF65 FFE0-FFE6 \
        FFE8-FFEE FFFC-FFFD 10100-10102 10137-1013F 10179-10189 1018C-1018E 10190-1019C 101A0 101D0-101FC \
        1039F 103D0 1056F 10857 10877-10878 1091F 1093F 10A50-10A58 10A7F 10AC8 10AF0-10AF6 10B39-10B3F \
        10B99-10B9C 10D6E 10D8E-10D8F 10EAD 10F55-10F59 10F86-10F89 11047-1104D 110BB-110BC 110BE-110C1 \
        11140-11143 11174-11175 111C5-111C8 111CD 111DB 111DD-111DF 11238-1123D 112A9 113D4-113D5 \
        113D7-113D8 1144B-1144F 1145A-1145B 1145D 114C6 115C1-115D7 11641-11643 11660-1166C 116B9 \
        1173C-1173F 1183B 11944-11946 119E2 11A3F-11A46 11A9A-11A9C 11A9E-11AA2 11B00-11B09 11BE1 \
        11C41-11C45 11C70-11C71 11EF7-11EF8 11F43-11F4F 11FD5-11FF1 11FFF 12470-12474 12FF1-12FF2 \
        16A6E-16A6F 16AF5 16B37-16B3F 16B44-16B45 16D6D-16D6F 16E97-16E9A 16FE2 1BC9C 1BC9F 1CC00-1CCEF \
        1CD00-1CEB3 1CF50-1CFC3 1D000-1D0F5 1D100-1D126 1D129-1D164 1D16A-1D16C 1D183-1D184 1D18C-1D1A9 \
        1D1AE-1D1EA 1D200-1D241 1D245 1D300-1D356 1D6C1 1D6DB 1D6FB 1D715 1D735 1D74F 1D76F 1D789 1D7A9 \
        1D7C3 1D800-1D9FF 1DA37-1DA3A 1DA6D-1DA74 1DA76-1DA83 1DA85-1DA8B 1E14F 1E2FF 1E5FF 1E95E-1E95F \
        1ECAC 1ECB0 1ED2E 1EEF0-1EEF1 1F000-1F02B 1F030-1F093 1F0A0-1F0AE 1F0B1-1F0BF 1F0C1-1F0CF \
        1F0D1-1F0F5 1F10D-1F1AD 1F1E6-1F202 1F210-1F23B 1F240-1F248 1F250-1F251 1F260-1F265 1F300-1F6D7 \
        1F6DC-1F6EC 1F6F0-1F6FC 1F700-1F776 1F77B-1F7D9 1F7E0-1F7EB 1F7F0 1F800-1F80B 1F810-1F847 \
        1F850-1F859 1F860-1F887 1F890-1F8AD 1F8B0-1F8BB 1F8C0-1F8C1 1F900-1FA53 1FA60-1FA6D 1FA70-1FA7C \
        1FA80-1FA89 1FA8F-1FAC6 1FACE-1FADC 1FADF-1FAE9 1FAF0-1FAF8 1FB00-1FB92 1FB94-1FBEF
        """
        var out: [(UInt32, UInt32)] = []
        out.reserveCapacity(350)
        for token in raw.split(separator: " ") {
            if let dash = token.firstIndex(of: "-") {
                if let lo = UInt32(token[..<dash], radix: 16),
                   let hi = UInt32(token[token.index(after: dash)...], radix: 16) {
                    out.append((lo, hi))
                }
            } else if let v = UInt32(token, radix: 16) {
                out.append((v, v))
            }
        }
        return out
    }()

    // parity: native/src/markdown-tables.zig#fold_runs [status=implemented hash=0da5547fc897]
    static let foldRuns: [(first: UInt32, last: UInt32, stride: UInt32, delta: Int32)] = {
        let raw =
        """
        41:5A:1:32 B5:B5:1:775 C0:D6:1:32 D8:DE:1:32 100:12E:2:1 132:136:2:1 139:147:2:1 14A:176:2:1 \
        178:178:1:-121 179:17D:2:1 17F:17F:1:-268 181:181:1:210 182:184:2:1 186:186:1:206 187:187:1:1 \
        189:18A:1:205 18B:18B:1:1 18E:18E:1:79 18F:18F:1:202 190:190:1:203 191:191:1:1 193:193:1:205 \
        194:194:1:207 196:196:1:211 197:197:1:209 198:198:1:1 19C:19C:1:211 19D:19D:1:213 19F:19F:1:214 \
        1A0:1A4:2:1 1A6:1A6:1:218 1A7:1A7:1:1 1A9:1A9:1:218 1AC:1AC:1:1 1AE:1AE:1:218 1AF:1AF:1:1 \
        1B1:1B2:1:217 1B3:1B5:2:1 1B7:1B7:1:219 1B8:1B8:1:1 1BC:1BC:1:1 1C4:1C4:1:2 1C5:1C5:1:1 1C7:1C7:1:2 \
        1C8:1C8:1:1 1CA:1CA:1:2 1CB:1DB:2:1 1DE:1EE:2:1 1F1:1F1:1:2 1F2:1F4:2:1 1F6:1F6:1:-97 1F7:1F7:1:-56 \
        1F8:21E:2:1 220:220:1:-130 222:232:2:1 23A:23A:1:10795 23B:23B:1:1 23D:23D:1:-163 23E:23E:1:10792 \
        241:241:1:1 243:243:1:-195 244:244:1:69 245:245:1:71 246:24E:2:1 345:345:1:116 370:372:2:1 \
        376:376:1:1 37F:37F:1:116 386:386:1:38 388:38A:1:37 38C:38C:1:64 38E:38F:1:63 391:3A1:1:32 \
        3A3:3AB:1:32 3C2:3C2:1:1 3CF:3CF:1:8 3D0:3D0:1:-30 3D1:3D1:1:-25 3D5:3D5:1:-15 3D6:3D6:1:-22 \
        3D8:3EE:2:1 3F0:3F0:1:-54 3F1:3F1:1:-48 3F4:3F4:1:-60 3F5:3F5:1:-64 3F7:3F7:1:1 3F9:3F9:1:-7 \
        3FA:3FA:1:1 3FD:3FF:1:-130 400:40F:1:80 410:42F:1:32 460:480:2:1 48A:4BE:2:1 4C0:4C0:1:15 \
        4C1:4CD:2:1 4D0:52E:2:1 531:556:1:48 10A0:10C5:1:7264 10C7:10C7:1:7264 10CD:10CD:1:7264 \
        13F8:13FD:1:-8 1C80:1C80:1:-6222 1C81:1C81:1:-6221 1C82:1C82:1:-6212 1C83:1C84:1:-6210 \
        1C85:1C85:1:-6211 1C86:1C86:1:-6204 1C87:1C87:1:-6180 1C88:1C88:1:35267 1C89:1C89:1:1 \
        1C90:1CBA:1:-3008 1CBD:1CBF:1:-3008 1E00:1E94:2:1 1E9B:1E9B:1:-58 1EA0:1EFE:2:1 1F08:1F0F:1:-8 \
        1F18:1F1D:1:-8 1F28:1F2F:1:-8 1F38:1F3F:1:-8 1F48:1F4D:1:-8 1F59:1F5F:2:-8 1F68:1F6F:1:-8 \
        1FB8:1FB9:1:-8 1FBA:1FBB:1:-74 1FBE:1FBE:1:-7173 1FC8:1FCB:1:-86 1FD8:1FD9:1:-8 1FDA:1FDB:1:-100 \
        1FE8:1FE9:1:-8 1FEA:1FEB:1:-112 1FEC:1FEC:1:-7 1FF8:1FF9:1:-128 1FFA:1FFB:1:-126 2126:2126:1:-7517 \
        212A:212A:1:-8383 212B:212B:1:-8262 2132:2132:1:28 2160:216F:1:16 2183:2183:1:1 24B6:24CF:1:26 \
        2C00:2C2F:1:48 2C60:2C60:1:1 2C62:2C62:1:-10743 2C63:2C63:1:-3814 2C64:2C64:1:-10727 2C67:2C6B:2:1 \
        2C6D:2C6D:1:-10780 2C6E:2C6E:1:-10749 2C6F:2C6F:1:-10783 2C70:2C70:1:-10782 2C72:2C72:1:1 \
        2C75:2C75:1:1 2C7E:2C7F:1:-10815 2C80:2CE2:2:1 2CEB:2CED:2:1 2CF2:2CF2:1:1 A640:A66C:2:1 \
        A680:A69A:2:1 A722:A72E:2:1 A732:A76E:2:1 A779:A77B:2:1 A77D:A77D:1:-35332 A77E:A786:2:1 \
        A78B:A78B:1:1 A78D:A78D:1:-42280 A790:A792:2:1 A796:A7A8:2:1 A7AA:A7AA:1:-42308 A7AB:A7AB:1:-42319 \
        A7AC:A7AC:1:-42315 A7AD:A7AD:1:-42305 A7AE:A7AE:1:-42308 A7B0:A7B0:1:-42258 A7B1:A7B1:1:-42282 \
        A7B2:A7B2:1:-42261 A7B3:A7B3:1:928 A7B4:A7C2:2:1 A7C4:A7C4:1:-48 A7C5:A7C5:1:-42307 \
        A7C6:A7C6:1:-35384 A7C7:A7C9:2:1 A7CB:A7CB:1:-42343 A7CC:A7CC:1:1 A7D0:A7D0:1:1 A7D6:A7DA:2:1 \
        A7DC:A7DC:1:-42561 A7F5:A7F5:1:1 AB70:ABBF:1:-38864 FF21:FF3A:1:32 10400:10427:1:40 \
        104B0:104D3:1:40 10570:1057A:1:39 1057C:1058A:1:39 1058C:10592:1:39 10594:10595:1:39 \
        10C80:10CB2:1:64 10D50:10D65:1:32 118A0:118BF:1:32 16E40:16E5F:1:32 1E900:1E921:1:34
        """
        var out: [(UInt32, UInt32, UInt32, Int32)] = []
        out.reserveCapacity(200)
        for token in raw.split(separator: " ") {
            let parts = token.split(separator: ":")
            if parts.count == 4,
               let a = UInt32(parts[0], radix: 16),
               let b = UInt32(parts[1], radix: 16),
               let s = UInt32(parts[2]),
               let d = Int32(parts[3]) {
                out.append((a, b, s, d))
            }
        }
        return out
    }()

    // parity: native/src/markdown-tables.zig#fold_multi [status=implemented hash=c7add68fca9f]
    static let foldMulti: [UInt32: [UInt32]] = {
        let raw =
        """
        DF:73,73 130:69,307 149:2BC,6E 1F0:6A,30C 390:3B9,308,301 3B0:3C5,308,301 587:565,582 1E96:68,331 \
        1E97:74,308 1E98:77,30A 1E99:79,30A 1E9A:61,2BE 1E9E:73,73 1F50:3C5,313 1F52:3C5,313,300 \
        1F54:3C5,313,301 1F56:3C5,313,342 1F80:1F00,3B9 1F81:1F01,3B9 1F82:1F02,3B9 1F83:1F03,3B9 \
        1F84:1F04,3B9 1F85:1F05,3B9 1F86:1F06,3B9 1F87:1F07,3B9 1F88:1F00,3B9 1F89:1F01,3B9 1F8A:1F02,3B9 \
        1F8B:1F03,3B9 1F8C:1F04,3B9 1F8D:1F05,3B9 1F8E:1F06,3B9 1F8F:1F07,3B9 1F90:1F20,3B9 1F91:1F21,3B9 \
        1F92:1F22,3B9 1F93:1F23,3B9 1F94:1F24,3B9 1F95:1F25,3B9 1F96:1F26,3B9 1F97:1F27,3B9 1F98:1F20,3B9 \
        1F99:1F21,3B9 1F9A:1F22,3B9 1F9B:1F23,3B9 1F9C:1F24,3B9 1F9D:1F25,3B9 1F9E:1F26,3B9 1F9F:1F27,3B9 \
        1FA0:1F60,3B9 1FA1:1F61,3B9 1FA2:1F62,3B9 1FA3:1F63,3B9 1FA4:1F64,3B9 1FA5:1F65,3B9 1FA6:1F66,3B9 \
        1FA7:1F67,3B9 1FA8:1F60,3B9 1FA9:1F61,3B9 1FAA:1F62,3B9 1FAB:1F63,3B9 1FAC:1F64,3B9 1FAD:1F65,3B9 \
        1FAE:1F66,3B9 1FAF:1F67,3B9 1FB2:1F70,3B9 1FB3:3B1,3B9 1FB4:3AC,3B9 1FB6:3B1,342 1FB7:3B1,342,3B9 \
        1FBC:3B1,3B9 1FC2:1F74,3B9 1FC3:3B7,3B9 1FC4:3AE,3B9 1FC6:3B7,342 1FC7:3B7,342,3B9 1FCC:3B7,3B9 \
        1FD2:3B9,308,300 1FD3:3B9,308,301 1FD6:3B9,342 1FD7:3B9,308,342 1FE2:3C5,308,300 1FE3:3C5,308,301 \
        1FE4:3C1,313 1FE6:3C5,342 1FE7:3C5,308,342 1FF2:1F7C,3B9 1FF3:3C9,3B9 1FF4:3CE,3B9 1FF6:3C9,342 \
        1FF7:3C9,342,3B9 1FFC:3C9,3B9 FB00:66,66 FB01:66,69 FB02:66,6C FB03:66,66,69 FB04:66,66,6C \
        FB05:73,74 FB06:73,74 FB13:574,576 FB14:574,565 FB15:574,56B FB16:57E,576 FB17:574,56D
        """
        var out: [UInt32: [UInt32]] = [:]
        out.reserveCapacity(110)
        for token in raw.split(separator: " ") {
            if let colon = token.firstIndex(of: ":") {
                if let key = UInt32(token[..<colon], radix: 16) {
                    let vals = token[token.index(after: colon)...].split(separator: ",").compactMap { UInt32($0, radix: 16) }
                    out[key] = vals
                }
            }
        }
        return out
    }()

    // parity: native/src/markdown-tables.zig#entity_names [status=implemented hash=73db30cf1cc5]
    // parity: native/src/markdown-tables.zig#entity_code_points [status=implemented hash=858cb13edd7d]
    static let entities: [String: String] = {
        let raw =
        """
        AElig:C6 AMP:26 Aacute:C1 Abreve:102 Acirc:C2 Acy:410 Afr:1D504 Agrave:C0 Alpha:391 Amacr:100 \
        And:2A53 Aogon:104 Aopf:1D538 ApplyFunction:2061 Aring:C5 Ascr:1D49C Assign:2254 Atilde:C3 Auml:C4 \
        Backslash:2216 Barv:2AE7 Barwed:2306 Bcy:411 Because:2235 Bernoullis:212C Beta:392 Bfr:1D505 \
        Bopf:1D539 Breve:2D8 Bscr:212C Bumpeq:224E CHcy:427 COPY:A9 Cacute:106 Cap:22D2 \
        CapitalDifferentialD:2145 Cayleys:212D Ccaron:10C Ccedil:C7 Ccirc:108 Cconint:2230 Cdot:10A \
        Cedilla:B8 CenterDot:B7 Cfr:212D Chi:3A7 CircleDot:2299 CircleMinus:2296 CirclePlus:2295 \
        CircleTimes:2297 ClockwiseContourIntegral:2232 CloseCurlyDoubleQuote:201D CloseCurlyQuote:2019 \
        Colon:2237 Colone:2A74 Congruent:2261 Conint:222F ContourIntegral:222E Copf:2102 Coproduct:2210 \
        CounterClockwiseContourIntegral:2233 Cross:2A2F Cscr:1D49E Cup:22D3 CupCap:224D DD:2145 \
        DDotrahd:2911 DJcy:402 DScy:405 DZcy:40F Dagger:2021 Darr:21A1 Dashv:2AE4 Dcaron:10E Dcy:414 \
        Del:2207 Delta:394 Dfr:1D507 DiacriticalAcute:B4 DiacriticalDot:2D9 DiacriticalDoubleAcute:2DD \
        DiacriticalGrave:60 DiacriticalTilde:2DC Diamond:22C4 DifferentialD:2146 Dopf:1D53B Dot:A8 \
        DotDot:20DC DotEqual:2250 DoubleContourIntegral:222F DoubleDot:A8 DoubleDownArrow:21D3 \
        DoubleLeftArrow:21D0 DoubleLeftRightArrow:21D4 DoubleLeftTee:2AE4 DoubleLongLeftArrow:27F8 \
        DoubleLongLeftRightArrow:27FA DoubleLongRightArrow:27F9 DoubleRightArrow:21D2 DoubleRightTee:22A8 \
        DoubleUpArrow:21D1 DoubleUpDownArrow:21D5 DoubleVerticalBar:2225 DownArrow:2193 DownArrowBar:2913 \
        DownArrowUpArrow:21F5 DownBreve:311 DownLeftRightVector:2950 DownLeftTeeVector:295E \
        DownLeftVector:21BD DownLeftVectorBar:2956 DownRightTeeVector:295F DownRightVector:21C1 \
        DownRightVectorBar:2957 DownTee:22A4 DownTeeArrow:21A7 Downarrow:21D3 Dscr:1D49F Dstrok:110 ENG:14A \
        ETH:D0 Eacute:C9 Ecaron:11A Ecirc:CA Ecy:42D Edot:116 Efr:1D508 Egrave:C8 Element:2208 Emacr:112 \
        EmptySmallSquare:25FB EmptyVerySmallSquare:25AB Eogon:118 Eopf:1D53C Epsilon:395 Equal:2A75 \
        EqualTilde:2242 Equilibrium:21CC Escr:2130 Esim:2A73 Eta:397 Euml:CB Exists:2203 ExponentialE:2147 \
        Fcy:424 Ffr:1D509 FilledSmallSquare:25FC FilledVerySmallSquare:25AA Fopf:1D53D ForAll:2200 \
        Fouriertrf:2131 Fscr:2131 GJcy:403 GT:3E Gamma:393 Gammad:3DC Gbreve:11E Gcedil:122 Gcirc:11C \
        Gcy:413 Gdot:120 Gfr:1D50A Gg:22D9 Gopf:1D53E GreaterEqual:2265 GreaterEqualLess:22DB \
        GreaterFullEqual:2267 GreaterGreater:2AA2 GreaterLess:2277 GreaterSlantEqual:2A7E GreaterTilde:2273 \
        Gscr:1D4A2 Gt:226B HARDcy:42A Hacek:2C7 Hat:5E Hcirc:124 Hfr:210C HilbertSpace:210B Hopf:210D \
        HorizontalLine:2500 Hscr:210B Hstrok:126 HumpDownHump:224E HumpEqual:224F IEcy:415 IJlig:132 \
        IOcy:401 Iacute:CD Icirc:CE Icy:418 Idot:130 Ifr:2111 Igrave:CC Im:2111 Imacr:12A ImaginaryI:2148 \
        Implies:21D2 Int:222C Integral:222B Intersection:22C2 InvisibleComma:2063 InvisibleTimes:2062 \
        Iogon:12E Iopf:1D540 Iota:399 Iscr:2110 Itilde:128 Iukcy:406 Iuml:CF Jcirc:134 Jcy:419 Jfr:1D50D \
        Jopf:1D541 Jscr:1D4A5 Jsercy:408 Jukcy:404 KHcy:425 KJcy:40C Kappa:39A Kcedil:136 Kcy:41A Kfr:1D50E \
        Kopf:1D542 Kscr:1D4A6 LJcy:409 LT:3C Lacute:139 Lambda:39B Lang:27EA Laplacetrf:2112 Larr:219E \
        Lcaron:13D Lcedil:13B Lcy:41B LeftAngleBracket:27E8 LeftArrow:2190 LeftArrowBar:21E4 \
        LeftArrowRightArrow:21C6 LeftCeiling:2308 LeftDoubleBracket:27E6 LeftDownTeeVector:2961 \
        LeftDownVector:21C3 LeftDownVectorBar:2959 LeftFloor:230A LeftRightArrow:2194 LeftRightVector:294E \
        LeftTee:22A3 LeftTeeArrow:21A4 LeftTeeVector:295A LeftTriangle:22B2 LeftTriangleBar:29CF \
        LeftTriangleEqual:22B4 LeftUpDownVector:2951 LeftUpTeeVector:2960 LeftUpVector:21BF \
        LeftUpVectorBar:2958 LeftVector:21BC LeftVectorBar:2952 Leftarrow:21D0 Leftrightarrow:21D4 \
        LessEqualGreater:22DA LessFullEqual:2266 LessGreater:2276 LessLess:2AA1 LessSlantEqual:2A7D \
        LessTilde:2272 Lfr:1D50F Ll:22D8 Lleftarrow:21DA Lmidot:13F LongLeftArrow:27F5 \
        LongLeftRightArrow:27F7 LongRightArrow:27F6 Longleftarrow:27F8 Longleftrightarrow:27FA \
        Longrightarrow:27F9 Lopf:1D543 LowerLeftArrow:2199 LowerRightArrow:2198 Lscr:2112 Lsh:21B0 \
        Lstrok:141 Lt:226A Map:2905 Mcy:41C MediumSpace:205F Mellintrf:2133 Mfr:1D510 MinusPlus:2213 \
        Mopf:1D544 Mscr:2133 Mu:39C NJcy:40A Nacute:143 Ncaron:147 Ncedil:145 Ncy:41D \
        NegativeMediumSpace:200B NegativeThickSpace:200B NegativeThinSpace:200B NegativeVeryThinSpace:200B \
        NestedGreaterGreater:226B NestedLessLess:226A NewLine:A Nfr:1D511 NoBreak:2060 NonBreakingSpace:A0 \
        Nopf:2115 Not:2AEC NotCongruent:2262 NotCupCap:226D NotDoubleVerticalBar:2226 NotElement:2209 \
        NotEqual:2260 NotEqualTilde:2242,338 NotExists:2204 NotGreater:226F NotGreaterEqual:2271 \
        NotGreaterFullEqual:2267,338 NotGreaterGreater:226B,338 NotGreaterLess:2279 \
        NotGreaterSlantEqual:2A7E,338 NotGreaterTilde:2275 NotHumpDownHump:224E,338 NotHumpEqual:224F,338 \
        NotLeftTriangle:22EA NotLeftTriangleBar:29CF,338 NotLeftTriangleEqual:22EC NotLess:226E \
        NotLessEqual:2270 NotLessGreater:2278 NotLessLess:226A,338 NotLessSlantEqual:2A7D,338 \
        NotLessTilde:2274 NotNestedGreaterGreater:2AA2,338 NotNestedLessLess:2AA1,338 NotPrecedes:2280 \
        NotPrecedesEqual:2AAF,338 NotPrecedesSlantEqual:22E0 NotReverseElement:220C NotRightTriangle:22EB \
        NotRightTriangleBar:29D0,338 NotRightTriangleEqual:22ED NotSquareSubset:228F,338 \
        NotSquareSubsetEqual:22E2 NotSquareSuperset:2290,338 NotSquareSupersetEqual:22E3 \
        NotSubset:2282,20D2 NotSubsetEqual:2288 NotSucceeds:2281 NotSucceedsEqual:2AB0,338 \
        NotSucceedsSlantEqual:22E1 NotSucceedsTilde:227F,338 NotSuperset:2283,20D2 NotSupersetEqual:2289 \
        NotTilde:2241 NotTildeEqual:2244 NotTildeFullEqual:2247 NotTildeTilde:2249 NotVerticalBar:2224 \
        Nscr:1D4A9 Ntilde:D1 Nu:39D OElig:152 Oacute:D3 Ocirc:D4 Ocy:41E Odblac:150 Ofr:1D512 Ograve:D2 \
        Omacr:14C Omega:3A9 Omicron:39F Oopf:1D546 OpenCurlyDoubleQuote:201C OpenCurlyQuote:2018 Or:2A54 \
        Oscr:1D4AA Oslash:D8 Otilde:D5 Otimes:2A37 Ouml:D6 OverBar:203E OverBrace:23DE OverBracket:23B4 \
        OverParenthesis:23DC PartialD:2202 Pcy:41F Pfr:1D513 Phi:3A6 Pi:3A0 PlusMinus:B1 Poincareplane:210C \
        Popf:2119 Pr:2ABB Precedes:227A PrecedesEqual:2AAF PrecedesSlantEqual:227C PrecedesTilde:227E \
        Prime:2033 Product:220F Proportion:2237 Proportional:221D Pscr:1D4AB Psi:3A8 QUOT:22 Qfr:1D514 \
        Qopf:211A Qscr:1D4AC RBarr:2910 REG:AE Racute:154 Rang:27EB Rarr:21A0 Rarrtl:2916 Rcaron:158 \
        Rcedil:156 Rcy:420 Re:211C ReverseElement:220B ReverseEquilibrium:21CB ReverseUpEquilibrium:296F \
        Rfr:211C Rho:3A1 RightAngleBracket:27E9 RightArrow:2192 RightArrowBar:21E5 RightArrowLeftArrow:21C4 \
        RightCeiling:2309 RightDoubleBracket:27E7 RightDownTeeVector:295D RightDownVector:21C2 \
        RightDownVectorBar:2955 RightFloor:230B RightTee:22A2 RightTeeArrow:21A6 RightTeeVector:295B \
        RightTriangle:22B3 RightTriangleBar:29D0 RightTriangleEqual:22B5 RightUpDownVector:294F \
        RightUpTeeVector:295C RightUpVector:21BE RightUpVectorBar:2954 RightVector:21C0 RightVectorBar:2953 \
        Rightarrow:21D2 Ropf:211D RoundImplies:2970 Rrightarrow:21DB Rscr:211B Rsh:21B1 RuleDelayed:29F4 \
        SHCHcy:429 SHcy:428 SOFTcy:42C Sacute:15A Sc:2ABC Scaron:160 Scedil:15E Scirc:15C Scy:421 Sfr:1D516 \
        ShortDownArrow:2193 ShortLeftArrow:2190 ShortRightArrow:2192 ShortUpArrow:2191 Sigma:3A3 \
        SmallCircle:2218 Sopf:1D54A Sqrt:221A Square:25A1 SquareIntersection:2293 SquareSubset:228F \
        SquareSubsetEqual:2291 SquareSuperset:2290 SquareSupersetEqual:2292 SquareUnion:2294 Sscr:1D4AE \
        Star:22C6 Sub:22D0 Subset:22D0 SubsetEqual:2286 Succeeds:227B SucceedsEqual:2AB0 \
        SucceedsSlantEqual:227D SucceedsTilde:227F SuchThat:220B Sum:2211 Sup:22D1 Superset:2283 \
        SupersetEqual:2287 Supset:22D1 THORN:DE TRADE:2122 TSHcy:40B TScy:426 Tab:9 Tau:3A4 Tcaron:164 \
        Tcedil:162 Tcy:422 Tfr:1D517 Therefore:2234 Theta:398 ThickSpace:205F,200A ThinSpace:2009 \
        Tilde:223C TildeEqual:2243 TildeFullEqual:2245 TildeTilde:2248 Topf:1D54B TripleDot:20DB Tscr:1D4AF \
        Tstrok:166 Uacute:DA Uarr:219F Uarrocir:2949 Ubrcy:40E Ubreve:16C Ucirc:DB Ucy:423 Udblac:170 \
        Ufr:1D518 Ugrave:D9 Umacr:16A UnderBar:5F UnderBrace:23DF UnderBracket:23B5 UnderParenthesis:23DD \
        Union:22C3 UnionPlus:228E Uogon:172 Uopf:1D54C UpArrow:2191 UpArrowBar:2912 UpArrowDownArrow:21C5 \
        UpDownArrow:2195 UpEquilibrium:296E UpTee:22A5 UpTeeArrow:21A5 Uparrow:21D1 Updownarrow:21D5 \
        UpperLeftArrow:2196 UpperRightArrow:2197 Upsi:3D2 Upsilon:3A5 Uring:16E Uscr:1D4B0 Utilde:168 \
        Uuml:DC VDash:22AB Vbar:2AEB Vcy:412 Vdash:22A9 Vdashl:2AE6 Vee:22C1 Verbar:2016 Vert:2016 \
        VerticalBar:2223 VerticalLine:7C VerticalSeparator:2758 VerticalTilde:2240 VeryThinSpace:200A \
        Vfr:1D519 Vopf:1D54D Vscr:1D4B1 Vvdash:22AA Wcirc:174 Wedge:22C0 Wfr:1D51A Wopf:1D54E Wscr:1D4B2 \
        Xfr:1D51B Xi:39E Xopf:1D54F Xscr:1D4B3 YAcy:42F YIcy:407 YUcy:42E Yacute:DD Ycirc:176 Ycy:42B \
        Yfr:1D51C Yopf:1D550 Yscr:1D4B4 Yuml:178 ZHcy:416 Zacute:179 Zcaron:17D Zcy:417 Zdot:17B \
        ZeroWidthSpace:200B Zeta:396 Zfr:2128 Zopf:2124 Zscr:1D4B5 aacute:E1 abreve:103 ac:223E \
        acE:223E,333 acd:223F acirc:E2 acute:B4 acy:430 aelig:E6 af:2061 afr:1D51E agrave:E0 alefsym:2135 \
        aleph:2135 alpha:3B1 amacr:101 amalg:2A3F amp:26 and:2227 andand:2A55 andd:2A5C andslope:2A58 \
        andv:2A5A ang:2220 ange:29A4 angle:2220 angmsd:2221 angmsdaa:29A8 angmsdab:29A9 angmsdac:29AA \
        angmsdad:29AB angmsdae:29AC angmsdaf:29AD angmsdag:29AE angmsdah:29AF angrt:221F angrtvb:22BE \
        angrtvbd:299D angsph:2222 angst:C5 angzarr:237C aogon:105 aopf:1D552 ap:2248 apE:2A70 apacir:2A6F \
        ape:224A apid:224B apos:27 approx:2248 approxeq:224A aring:E5 ascr:1D4B6 ast:2A asymp:2248 \
        asympeq:224D atilde:E3 auml:E4 awconint:2233 awint:2A11 bNot:2AED backcong:224C backepsilon:3F6 \
        backprime:2035 backsim:223D backsimeq:22CD barvee:22BD barwed:2305 barwedge:2305 bbrk:23B5 \
        bbrktbrk:23B6 bcong:224C bcy:431 bdquo:201E becaus:2235 because:2235 bemptyv:29B0 bepsi:3F6 \
        bernou:212C beta:3B2 beth:2136 between:226C bfr:1D51F bigcap:22C2 bigcirc:25EF bigcup:22C3 \
        bigodot:2A00 bigoplus:2A01 bigotimes:2A02 bigsqcup:2A06 bigstar:2605 bigtriangledown:25BD \
        bigtriangleup:25B3 biguplus:2A04 bigvee:22C1 bigwedge:22C0 bkarow:290D blacklozenge:29EB \
        blacksquare:25AA blacktriangle:25B4 blacktriangledown:25BE blacktriangleleft:25C2 \
        blacktriangleright:25B8 blank:2423 blk12:2592 blk14:2591 blk34:2593 block:2588 bne:3D,20E5 \
        bnequiv:2261,20E5 bnot:2310 bopf:1D553 bot:22A5 bottom:22A5 bowtie:22C8 boxDL:2557 boxDR:2554 \
        boxDl:2556 boxDr:2553 boxH:2550 boxHD:2566 boxHU:2569 boxHd:2564 boxHu:2567 boxUL:255D boxUR:255A \
        boxUl:255C boxUr:2559 boxV:2551 boxVH:256C boxVL:2563 boxVR:2560 boxVh:256B boxVl:2562 boxVr:255F \
        boxbox:29C9 boxdL:2555 boxdR:2552 boxdl:2510 boxdr:250C boxh:2500 boxhD:2565 boxhU:2568 boxhd:252C \
        boxhu:2534 boxminus:229F boxplus:229E boxtimes:22A0 boxuL:255B boxuR:2558 boxul:2518 boxur:2514 \
        boxv:2502 boxvH:256A boxvL:2561 boxvR:255E boxvh:253C boxvl:2524 boxvr:251C bprime:2035 breve:2D8 \
        brvbar:A6 bscr:1D4B7 bsemi:204F bsim:223D bsime:22CD bsol:5C bsolb:29C5 bsolhsub:27C8 bull:2022 \
        bullet:2022 bump:224E bumpE:2AAE bumpe:224F bumpeq:224F cacute:107 cap:2229 capand:2A44 \
        capbrcup:2A49 capcap:2A4B capcup:2A47 capdot:2A40 caps:2229,FE00 caret:2041 caron:2C7 ccaps:2A4D \
        ccaron:10D ccedil:E7 ccirc:109 ccups:2A4C ccupssm:2A50 cdot:10B cedil:B8 cemptyv:29B2 cent:A2 \
        centerdot:B7 cfr:1D520 chcy:447 check:2713 checkmark:2713 chi:3C7 cir:25CB cirE:29C3 circ:2C6 \
        circeq:2257 circlearrowleft:21BA circlearrowright:21BB circledR:AE circledS:24C8 circledast:229B \
        circledcirc:229A circleddash:229D cire:2257 cirfnint:2A10 cirmid:2AEF cirscir:29C2 clubs:2663 \
        clubsuit:2663 colon:3A colone:2254 coloneq:2254 comma:2C commat:40 comp:2201 compfn:2218 \
        complement:2201 complexes:2102 cong:2245 congdot:2A6D conint:222E copf:1D554 coprod:2210 copy:A9 \
        copysr:2117 crarr:21B5 cross:2717 cscr:1D4B8 csub:2ACF csube:2AD1 csup:2AD0 csupe:2AD2 ctdot:22EF \
        cudarrl:2938 cudarrr:2935 cuepr:22DE cuesc:22DF cularr:21B6 cularrp:293D cup:222A cupbrcap:2A48 \
        cupcap:2A46 cupcup:2A4A cupdot:228D cupor:2A45 cups:222A,FE00 curarr:21B7 curarrm:293C \
        curlyeqprec:22DE curlyeqsucc:22DF curlyvee:22CE curlywedge:22CF curren:A4 curvearrowleft:21B6 \
        curvearrowright:21B7 cuvee:22CE cuwed:22CF cwconint:2232 cwint:2231 cylcty:232D dArr:21D3 dHar:2965 \
        dagger:2020 daleth:2138 darr:2193 dash:2010 dashv:22A3 dbkarow:290F dblac:2DD dcaron:10F dcy:434 \
        dd:2146 ddagger:2021 ddarr:21CA ddotseq:2A77 deg:B0 delta:3B4 demptyv:29B1 dfisht:297F dfr:1D521 \
        dharl:21C3 dharr:21C2 diam:22C4 diamond:22C4 diamondsuit:2666 diams:2666 die:A8 digamma:3DD \
        disin:22F2 div:F7 divide:F7 divideontimes:22C7 divonx:22C7 djcy:452 dlcorn:231E dlcrop:230D \
        dollar:24 dopf:1D555 dot:2D9 doteq:2250 doteqdot:2251 dotminus:2238 dotplus:2214 dotsquare:22A1 \
        doublebarwedge:2306 downarrow:2193 downdownarrows:21CA downharpoonleft:21C3 downharpoonright:21C2 \
        drbkarow:2910 drcorn:231F drcrop:230C dscr:1D4B9 dscy:455 dsol:29F6 dstrok:111 dtdot:22F1 dtri:25BF \
        dtrif:25BE duarr:21F5 duhar:296F dwangle:29A6 dzcy:45F dzigrarr:27FF eDDot:2A77 eDot:2251 eacute:E9 \
        easter:2A6E ecaron:11B ecir:2256 ecirc:EA ecolon:2255 ecy:44D edot:117 ee:2147 efDot:2252 efr:1D522 \
        eg:2A9A egrave:E8 egs:2A96 egsdot:2A98 el:2A99 elinters:23E7 ell:2113 els:2A95 elsdot:2A97 \
        emacr:113 empty:2205 emptyset:2205 emptyv:2205 emsp:2003 emsp13:2004 emsp14:2005 eng:14B ensp:2002 \
        eogon:119 eopf:1D556 epar:22D5 eparsl:29E3 eplus:2A71 epsi:3B5 epsilon:3B5 epsiv:3F5 eqcirc:2256 \
        eqcolon:2255 eqsim:2242 eqslantgtr:2A96 eqslantless:2A95 equals:3D equest:225F equiv:2261 \
        equivDD:2A78 eqvparsl:29E5 erDot:2253 erarr:2971 escr:212F esdot:2250 esim:2242 eta:3B7 eth:F0 \
        euml:EB euro:20AC excl:21 exist:2203 expectation:2130 exponentiale:2147 fallingdotseq:2252 fcy:444 \
        female:2640 ffilig:FB03 fflig:FB00 ffllig:FB04 ffr:1D523 filig:FB01 fjlig:66,6A flat:266D \
        fllig:FB02 fltns:25B1 fnof:192 fopf:1D557 forall:2200 fork:22D4 forkv:2AD9 fpartint:2A0D frac12:BD \
        frac13:2153 frac14:BC frac15:2155 frac16:2159 frac18:215B frac23:2154 frac25:2156 frac34:BE \
        frac35:2157 frac38:215C frac45:2158 frac56:215A frac58:215D frac78:215E frasl:2044 frown:2322 \
        fscr:1D4BB gE:2267 gEl:2A8C gacute:1F5 gamma:3B3 gammad:3DD gap:2A86 gbreve:11F gcirc:11D gcy:433 \
        gdot:121 ge:2265 gel:22DB geq:2265 geqq:2267 geqslant:2A7E ges:2A7E gescc:2AA9 gesdot:2A80 \
        gesdoto:2A82 gesdotol:2A84 gesl:22DB,FE00 gesles:2A94 gfr:1D524 gg:226B ggg:22D9 gimel:2137 \
        gjcy:453 gl:2277 glE:2A92 gla:2AA5 glj:2AA4 gnE:2269 gnap:2A8A gnapprox:2A8A gne:2A88 gneq:2A88 \
        gneqq:2269 gnsim:22E7 gopf:1D558 grave:60 gscr:210A gsim:2273 gsime:2A8E gsiml:2A90 gt:3E gtcc:2AA7 \
        gtcir:2A7A gtdot:22D7 gtlPar:2995 gtquest:2A7C gtrapprox:2A86 gtrarr:2978 gtrdot:22D7 \
        gtreqless:22DB gtreqqless:2A8C gtrless:2277 gtrsim:2273 gvertneqq:2269,FE00 gvnE:2269,FE00 \
        hArr:21D4 hairsp:200A half:BD hamilt:210B hardcy:44A harr:2194 harrcir:2948 harrw:21AD hbar:210F \
        hcirc:125 hearts:2665 heartsuit:2665 hellip:2026 hercon:22B9 hfr:1D525 hksearow:2925 hkswarow:2926 \
        hoarr:21FF homtht:223B hookleftarrow:21A9 hookrightarrow:21AA hopf:1D559 horbar:2015 hscr:1D4BD \
        hslash:210F hstrok:127 hybull:2043 hyphen:2010 iacute:ED ic:2063 icirc:EE icy:438 iecy:435 iexcl:A1 \
        iff:21D4 ifr:1D526 igrave:EC ii:2148 iiiint:2A0C iiint:222D iinfin:29DC iiota:2129 ijlig:133 \
        imacr:12B image:2111 imagline:2110 imagpart:2111 imath:131 imof:22B7 imped:1B5 in:2208 incare:2105 \
        infin:221E infintie:29DD inodot:131 int:222B intcal:22BA integers:2124 intercal:22BA intlarhk:2A17 \
        intprod:2A3C iocy:451 iogon:12F iopf:1D55A iota:3B9 iprod:2A3C iquest:BF iscr:1D4BE isin:2208 \
        isinE:22F9 isindot:22F5 isins:22F4 isinsv:22F3 isinv:2208 it:2062 itilde:129 iukcy:456 iuml:EF \
        jcirc:135 jcy:439 jfr:1D527 jmath:237 jopf:1D55B jscr:1D4BF jsercy:458 jukcy:454 kappa:3BA \
        kappav:3F0 kcedil:137 kcy:43A kfr:1D528 kgreen:138 khcy:445 kjcy:45C kopf:1D55C kscr:1D4C0 \
        lAarr:21DA lArr:21D0 lAtail:291B lBarr:290E lE:2266 lEg:2A8B lHar:2962 lacute:13A laemptyv:29B4 \
        lagran:2112 lambda:3BB lang:27E8 langd:2991 langle:27E8 lap:2A85 laquo:AB larr:2190 larrb:21E4 \
        larrbfs:291F larrfs:291D larrhk:21A9 larrlp:21AB larrpl:2939 larrsim:2973 larrtl:21A2 lat:2AAB \
        latail:2919 late:2AAD lates:2AAD,FE00 lbarr:290C lbbrk:2772 lbrace:7B lbrack:5B lbrke:298B \
        lbrksld:298F lbrkslu:298D lcaron:13E lcedil:13C lceil:2308 lcub:7B lcy:43B ldca:2936 ldquo:201C \
        ldquor:201E ldrdhar:2967 ldrushar:294B ldsh:21B2 le:2264 leftarrow:2190 leftarrowtail:21A2 \
        leftharpoondown:21BD leftharpoonup:21BC leftleftarrows:21C7 leftrightarrow:2194 \
        leftrightarrows:21C6 leftrightharpoons:21CB leftrightsquigarrow:21AD leftthreetimes:22CB leg:22DA \
        leq:2264 leqq:2266 leqslant:2A7D les:2A7D lescc:2AA8 lesdot:2A7F lesdoto:2A81 lesdotor:2A83 \
        lesg:22DA,FE00 lesges:2A93 lessapprox:2A85 lessdot:22D6 lesseqgtr:22DA lesseqqgtr:2A8B lessgtr:2276 \
        lesssim:2272 lfisht:297C lfloor:230A lfr:1D529 lg:2276 lgE:2A91 lhard:21BD lharu:21BC lharul:296A \
        lhblk:2584 ljcy:459 ll:226A llarr:21C7 llcorner:231E llhard:296B lltri:25FA lmidot:140 lmoust:23B0 \
        lmoustache:23B0 lnE:2268 lnap:2A89 lnapprox:2A89 lne:2A87 lneq:2A87 lneqq:2268 lnsim:22E6 \
        loang:27EC loarr:21FD lobrk:27E6 longleftarrow:27F5 longleftrightarrow:27F7 longmapsto:27FC \
        longrightarrow:27F6 looparrowleft:21AB looparrowright:21AC lopar:2985 lopf:1D55D loplus:2A2D \
        lotimes:2A34 lowast:2217 lowbar:5F loz:25CA lozenge:25CA lozf:29EB lpar:28 lparlt:2993 lrarr:21C6 \
        lrcorner:231F lrhar:21CB lrhard:296D lrm:200E lrtri:22BF lsaquo:2039 lscr:1D4C1 lsh:21B0 lsim:2272 \
        lsime:2A8D lsimg:2A8F lsqb:5B lsquo:2018 lsquor:201A lstrok:142 lt:3C ltcc:2AA6 ltcir:2A79 \
        ltdot:22D6 lthree:22CB ltimes:22C9 ltlarr:2976 ltquest:2A7B ltrPar:2996 ltri:25C3 ltrie:22B4 \
        ltrif:25C2 lurdshar:294A luruhar:2966 lvertneqq:2268,FE00 lvnE:2268,FE00 mDDot:223A macr:AF \
        male:2642 malt:2720 maltese:2720 map:21A6 mapsto:21A6 mapstodown:21A7 mapstoleft:21A4 mapstoup:21A5 \
        marker:25AE mcomma:2A29 mcy:43C mdash:2014 measuredangle:2221 mfr:1D52A mho:2127 micro:B5 mid:2223 \
        midast:2A midcir:2AF0 middot:B7 minus:2212 minusb:229F minusd:2238 minusdu:2A2A mlcp:2ADB mldr:2026 \
        mnplus:2213 models:22A7 mopf:1D55E mp:2213 mscr:1D4C2 mstpos:223E mu:3BC multimap:22B8 mumap:22B8 \
        nGg:22D9,338 nGt:226B,20D2 nGtv:226B,338 nLeftarrow:21CD nLeftrightarrow:21CE nLl:22D8,338 \
        nLt:226A,20D2 nLtv:226A,338 nRightarrow:21CF nVDash:22AF nVdash:22AE nabla:2207 nacute:144 \
        nang:2220,20D2 nap:2249 napE:2A70,338 napid:224B,338 napos:149 napprox:2249 natur:266E natural:266E \
        naturals:2115 nbsp:A0 nbump:224E,338 nbumpe:224F,338 ncap:2A43 ncaron:148 ncedil:146 ncong:2247 \
        ncongdot:2A6D,338 ncup:2A42 ncy:43D ndash:2013 ne:2260 neArr:21D7 nearhk:2924 nearr:2197 \
        nearrow:2197 nedot:2250,338 nequiv:2262 nesear:2928 nesim:2242,338 nexist:2204 nexists:2204 \
        nfr:1D52B ngE:2267,338 nge:2271 ngeq:2271 ngeqq:2267,338 ngeqslant:2A7E,338 nges:2A7E,338 \
        ngsim:2275 ngt:226F ngtr:226F nhArr:21CE nharr:21AE nhpar:2AF2 ni:220B nis:22FC nisd:22FA niv:220B \
        njcy:45A nlArr:21CD nlE:2266,338 nlarr:219A nldr:2025 nle:2270 nleftarrow:219A nleftrightarrow:21AE \
        nleq:2270 nleqq:2266,338 nleqslant:2A7D,338 nles:2A7D,338 nless:226E nlsim:2274 nlt:226E nltri:22EA \
        nltrie:22EC nmid:2224 nopf:1D55F not:AC notin:2209 notinE:22F9,338 notindot:22F5,338 notinva:2209 \
        notinvb:22F7 notinvc:22F6 notni:220C notniva:220C notnivb:22FE notnivc:22FD npar:2226 \
        nparallel:2226 nparsl:2AFD,20E5 npart:2202,338 npolint:2A14 npr:2280 nprcue:22E0 npre:2AAF,338 \
        nprec:2280 npreceq:2AAF,338 nrArr:21CF nrarr:219B nrarrc:2933,338 nrarrw:219D,338 nrightarrow:219B \
        nrtri:22EB nrtrie:22ED nsc:2281 nsccue:22E1 nsce:2AB0,338 nscr:1D4C3 nshortmid:2224 \
        nshortparallel:2226 nsim:2241 nsime:2244 nsimeq:2244 nsmid:2224 nspar:2226 nsqsube:22E2 \
        nsqsupe:22E3 nsub:2284 nsubE:2AC5,338 nsube:2288 nsubset:2282,20D2 nsubseteq:2288 \
        nsubseteqq:2AC5,338 nsucc:2281 nsucceq:2AB0,338 nsup:2285 nsupE:2AC6,338 nsupe:2289 \
        nsupset:2283,20D2 nsupseteq:2289 nsupseteqq:2AC6,338 ntgl:2279 ntilde:F1 ntlg:2278 \
        ntriangleleft:22EA ntrianglelefteq:22EC ntriangleright:22EB ntrianglerighteq:22ED nu:3BD num:23 \
        numero:2116 numsp:2007 nvDash:22AD nvHarr:2904 nvap:224D,20D2 nvdash:22AC nvge:2265,20D2 \
        nvgt:3E,20D2 nvinfin:29DE nvlArr:2902 nvle:2264,20D2 nvlt:3C,20D2 nvltrie:22B4,20D2 nvrArr:2903 \
        nvrtrie:22B5,20D2 nvsim:223C,20D2 nwArr:21D6 nwarhk:2923 nwarr:2196 nwarrow:2196 nwnear:2927 \
        oS:24C8 oacute:F3 oast:229B ocir:229A ocirc:F4 ocy:43E odash:229D odblac:151 odiv:2A38 odot:2299 \
        odsold:29BC oelig:153 ofcir:29BF ofr:1D52C ogon:2DB ograve:F2 ogt:29C1 ohbar:29B5 ohm:3A9 oint:222E \
        olarr:21BA olcir:29BE olcross:29BB oline:203E olt:29C0 omacr:14D omega:3C9 omicron:3BF omid:29B6 \
        ominus:2296 oopf:1D560 opar:29B7 operp:29B9 oplus:2295 or:2228 orarr:21BB ord:2A5D order:2134 \
        orderof:2134 ordf:AA ordm:BA origof:22B6 oror:2A56 orslope:2A57 orv:2A5B oscr:2134 oslash:F8 \
        osol:2298 otilde:F5 otimes:2297 otimesas:2A36 ouml:F6 ovbar:233D par:2225 para:B6 parallel:2225 \
        parsim:2AF3 parsl:2AFD part:2202 pcy:43F percnt:25 period:2E permil:2030 perp:22A5 pertenk:2031 \
        pfr:1D52D phi:3C6 phiv:3D5 phmmat:2133 phone:260E pi:3C0 pitchfork:22D4 piv:3D6 planck:210F \
        planckh:210E plankv:210F plus:2B plusacir:2A23 plusb:229E pluscir:2A22 plusdo:2214 plusdu:2A25 \
        pluse:2A72 plusmn:B1 plussim:2A26 plustwo:2A27 pm:B1 pointint:2A15 popf:1D561 pound:A3 pr:227A \
        prE:2AB3 prap:2AB7 prcue:227C pre:2AAF prec:227A precapprox:2AB7 preccurlyeq:227C preceq:2AAF \
        precnapprox:2AB9 precneqq:2AB5 precnsim:22E8 precsim:227E prime:2032 primes:2119 prnE:2AB5 \
        prnap:2AB9 prnsim:22E8 prod:220F profalar:232E profline:2312 profsurf:2313 prop:221D propto:221D \
        prsim:227E prurel:22B0 pscr:1D4C5 psi:3C8 puncsp:2008 qfr:1D52E qint:2A0C qopf:1D562 qprime:2057 \
        qscr:1D4C6 quaternions:210D quatint:2A16 quest:3F questeq:225F quot:22 rAarr:21DB rArr:21D2 \
        rAtail:291C rBarr:290F rHar:2964 race:223D,331 racute:155 radic:221A raemptyv:29B3 rang:27E9 \
        rangd:2992 range:29A5 rangle:27E9 raquo:BB rarr:2192 rarrap:2975 rarrb:21E5 rarrbfs:2920 rarrc:2933 \
        rarrfs:291E rarrhk:21AA rarrlp:21AC rarrpl:2945 rarrsim:2974 rarrtl:21A3 rarrw:219D ratail:291A \
        ratio:2236 rationals:211A rbarr:290D rbbrk:2773 rbrace:7D rbrack:5D rbrke:298C rbrksld:298E \
        rbrkslu:2990 rcaron:159 rcedil:157 rceil:2309 rcub:7D rcy:440 rdca:2937 rdldhar:2969 rdquo:201D \
        rdquor:201D rdsh:21B3 real:211C realine:211B realpart:211C reals:211D rect:25AD reg:AE rfisht:297D \
        rfloor:230B rfr:1D52F rhard:21C1 rharu:21C0 rharul:296C rho:3C1 rhov:3F1 rightarrow:2192 \
        rightarrowtail:21A3 rightharpoondown:21C1 rightharpoonup:21C0 rightleftarrows:21C4 \
        rightleftharpoons:21CC rightrightarrows:21C9 rightsquigarrow:219D rightthreetimes:22CC ring:2DA \
        risingdotseq:2253 rlarr:21C4 rlhar:21CC rlm:200F rmoust:23B1 rmoustache:23B1 rnmid:2AEE roang:27ED \
        roarr:21FE robrk:27E7 ropar:2986 ropf:1D563 roplus:2A2E rotimes:2A35 rpar:29 rpargt:2994 \
        rppolint:2A12 rrarr:21C9 rsaquo:203A rscr:1D4C7 rsh:21B1 rsqb:5D rsquo:2019 rsquor:2019 rthree:22CC \
        rtimes:22CA rtri:25B9 rtrie:22B5 rtrif:25B8 rtriltri:29CE ruluhar:2968 rx:211E sacute:15B \
        sbquo:201A sc:227B scE:2AB4 scap:2AB8 scaron:161 sccue:227D sce:2AB0 scedil:15F scirc:15D scnE:2AB6 \
        scnap:2ABA scnsim:22E9 scpolint:2A13 scsim:227F scy:441 sdot:22C5 sdotb:22A1 sdote:2A66 seArr:21D8 \
        searhk:2925 searr:2198 searrow:2198 sect:A7 semi:3B seswar:2929 setminus:2216 setmn:2216 sext:2736 \
        sfr:1D530 sfrown:2322 sharp:266F shchcy:449 shcy:448 shortmid:2223 shortparallel:2225 shy:AD \
        sigma:3C3 sigmaf:3C2 sigmav:3C2 sim:223C simdot:2A6A sime:2243 simeq:2243 simg:2A9E simgE:2AA0 \
        siml:2A9D simlE:2A9F simne:2246 simplus:2A24 simrarr:2972 slarr:2190 smallsetminus:2216 smashp:2A33 \
        smeparsl:29E4 smid:2223 smile:2323 smt:2AAA smte:2AAC smtes:2AAC,FE00 softcy:44C sol:2F solb:29C4 \
        solbar:233F sopf:1D564 spades:2660 spadesuit:2660 spar:2225 sqcap:2293 sqcaps:2293,FE00 sqcup:2294 \
        sqcups:2294,FE00 sqsub:228F sqsube:2291 sqsubset:228F sqsubseteq:2291 sqsup:2290 sqsupe:2292 \
        sqsupset:2290 sqsupseteq:2292 squ:25A1 square:25A1 squarf:25AA squf:25AA srarr:2192 sscr:1D4C8 \
        ssetmn:2216 ssmile:2323 sstarf:22C6 star:2606 starf:2605 straightepsilon:3F5 straightphi:3D5 \
        strns:AF sub:2282 subE:2AC5 subdot:2ABD sube:2286 subedot:2AC3 submult:2AC1 subnE:2ACB subne:228A \
        subplus:2ABF subrarr:2979 subset:2282 subseteq:2286 subseteqq:2AC5 subsetneq:228A subsetneqq:2ACB \
        subsim:2AC7 subsub:2AD5 subsup:2AD3 succ:227B succapprox:2AB8 succcurlyeq:227D succeq:2AB0 \
        succnapprox:2ABA succneqq:2AB6 succnsim:22E9 succsim:227F sum:2211 sung:266A sup:2283 sup1:B9 \
        sup2:B2 sup3:B3 supE:2AC6 supdot:2ABE supdsub:2AD8 supe:2287 supedot:2AC4 suphsol:27C9 suphsub:2AD7 \
        suplarr:297B supmult:2AC2 supnE:2ACC supne:228B supplus:2AC0 supset:2283 supseteq:2287 \
        supseteqq:2AC6 supsetneq:228B supsetneqq:2ACC supsim:2AC8 supsub:2AD4 supsup:2AD6 swArr:21D9 \
        swarhk:2926 swarr:2199 swarrow:2199 swnwar:292A szlig:DF target:2316 tau:3C4 tbrk:23B4 tcaron:165 \
        tcedil:163 tcy:442 tdot:20DB telrec:2315 tfr:1D531 there4:2234 therefore:2234 theta:3B8 \
        thetasym:3D1 thetav:3D1 thickapprox:2248 thicksim:223C thinsp:2009 thkap:2248 thksim:223C thorn:FE \
        tilde:2DC times:D7 timesb:22A0 timesbar:2A31 timesd:2A30 tint:222D toea:2928 top:22A4 topbot:2336 \
        topcir:2AF1 topf:1D565 topfork:2ADA tosa:2929 tprime:2034 trade:2122 triangle:25B5 \
        triangledown:25BF triangleleft:25C3 trianglelefteq:22B4 triangleq:225C triangleright:25B9 \
        trianglerighteq:22B5 tridot:25EC trie:225C triminus:2A3A triplus:2A39 trisb:29CD tritime:2A3B \
        trpezium:23E2 tscr:1D4C9 tscy:446 tshcy:45B tstrok:167 twixt:226C twoheadleftarrow:219E \
        twoheadrightarrow:21A0 uArr:21D1 uHar:2963 uacute:FA uarr:2191 ubrcy:45E ubreve:16D ucirc:FB \
        ucy:443 udarr:21C5 udblac:171 udhar:296E ufisht:297E ufr:1D532 ugrave:F9 uharl:21BF uharr:21BE \
        uhblk:2580 ulcorn:231C ulcorner:231C ulcrop:230F ultri:25F8 umacr:16B uml:A8 uogon:173 uopf:1D566 \
        uparrow:2191 updownarrow:2195 upharpoonleft:21BF upharpoonright:21BE uplus:228E upsi:3C5 upsih:3D2 \
        upsilon:3C5 upuparrows:21C8 urcorn:231D urcorner:231D urcrop:230E uring:16F urtri:25F9 uscr:1D4CA \
        utdot:22F0 utilde:169 utri:25B5 utrif:25B4 uuarr:21C8 uuml:FC uwangle:29A7 vArr:21D5 vBar:2AE8 \
        vBarv:2AE9 vDash:22A8 vangrt:299C varepsilon:3F5 varkappa:3F0 varnothing:2205 varphi:3D5 varpi:3D6 \
        varpropto:221D varr:2195 varrho:3F1 varsigma:3C2 varsubsetneq:228A,FE00 varsubsetneqq:2ACB,FE00 \
        varsupsetneq:228B,FE00 varsupsetneqq:2ACC,FE00 vartheta:3D1 vartriangleleft:22B2 \
        vartriangleright:22B3 vcy:432 vdash:22A2 vee:2228 veebar:22BB veeeq:225A vellip:22EE verbar:7C \
        vert:7C vfr:1D533 vltri:22B2 vnsub:2282,20D2 vnsup:2283,20D2 vopf:1D567 vprop:221D vrtri:22B3 \
        vscr:1D4CB vsubnE:2ACB,FE00 vsubne:228A,FE00 vsupnE:2ACC,FE00 vsupne:228B,FE00 vzigzag:299A \
        wcirc:175 wedbar:2A5F wedge:2227 wedgeq:2259 weierp:2118 wfr:1D534 wopf:1D568 wp:2118 wr:2240 \
        wreath:2240 wscr:1D4CC xcap:22C2 xcirc:25EF xcup:22C3 xdtri:25BD xfr:1D535 xhArr:27FA xharr:27F7 \
        xi:3BE xlArr:27F8 xlarr:27F5 xmap:27FC xnis:22FB xodot:2A00 xopf:1D569 xoplus:2A01 xotime:2A02 \
        xrArr:27F9 xrarr:27F6 xscr:1D4CD xsqcup:2A06 xuplus:2A04 xutri:25B3 xvee:22C1 xwedge:22C0 yacute:FD \
        yacy:44F ycirc:177 ycy:44B yen:A5 yfr:1D536 yicy:457 yopf:1D56A yscr:1D4CE yucy:44E yuml:FF \
        zacute:17A zcaron:17E zcy:437 zdot:17C zeetrf:2128 zeta:3B6 zfr:1D537 zhcy:436 zigrarr:21DD \
        zopf:1D56B zscr:1D4CF zwj:200D zwnj:200C
        """
        var out: [String: String] = [:]
        out.reserveCapacity(2200)
        for token in raw.split(separator: " ") {
            if let colon = token.firstIndex(of: ":") {
                let name = String(token[..<colon])
                var s = ""
                for hex in token[token.index(after: colon)...].split(separator: ",") {
                    if let v = UInt32(hex, radix: 16), let sc = UnicodeScalar(v) {
                        s.unicodeScalars.append(sc)
                    }
                }
                out[name] = s
            }
        }
        return out
    }()
}
