// CommonMark 0.31.2 inline parser (delimiter-stack & bracket-stack algorithm),
// extended with GFM strikethrough and extended autolinks, and OpenCode's `$…$`, `$$…$$`, and `\(…\)` math.

/// Link reference definition parsed from `[label]: href "title"`.
// parity: patchmark/src/inline.ts#ReferenceDef [status=implemented hash=2788e31f8c9e]
public struct ReferenceDef: Equatable, Hashable, Sendable {
    public var href: String
    public var title: String?
    /// Source text of the definition (container prefixes stripped), for renderers that re-parse a block on its own.
    public var raw: String?
    /// 1-based start line of the paragraph that defined this reference.
    public var line: Int?

    public init(href: String, title: String? = nil, raw: String? = nil, line: Int? = nil) {
        self.href = href
        self.title = title
        self.raw = raw
        self.line = line
    }
}

/// Map from normalized reference labels to `ReferenceDef`.
// parity: patchmark/src/inline.ts#RefMap [status=implemented hash=4f2d8ac8746d]
public typealias RefMap = [String: ReferenceDef]

/// Configuration options for `parseInlines(_:options:)`.
// parity: patchmark/src/inline.ts#InlineParseOptions [status=implemented hash=9e38651da997]
public struct InlineParseOptions: Sendable {
    public var gfm: Bool
    public var math: Bool
    public var defs: RefMap

    public init(gfm: Bool = true, math: Bool = true, defs: RefMap = [:]) {
        self.gfm = gfm
        self.math = math
        self.defs = defs
    }
}

// MARK: - Constants & Shared Tag Patterns

private let tagNamePattern = "[A-Za-z][A-Za-z0-9-]*"
private let attributeNamePattern = "[a-zA-Z_:][a-zA-Z0-9:._-]*"
private let unquotedValuePattern = "[^\"'=<>`\\x00-\\x20]+"
private let singleQuotedValuePattern = "'[^']*'"
private let doubleQuotedValuePattern = "\"[^\"]*\""
private let attributeValuePattern = "(?:\(unquotedValuePattern)|\(singleQuotedValuePattern)|\(doubleQuotedValuePattern))"
private let attributeValueSpecPattern = "(?:\\s*=\\s*\(attributeValuePattern))"
private let attributePattern = "(?:\\s+\(attributeNamePattern)\(attributeValueSpecPattern)?)"

/// CommonMark HTML open-tag regular expression pattern.
// parity: patchmark/src/inline.ts#OPENTAG [status=implemented hash=72cb11a397df]
public let OPENTAG: String = "<\(tagNamePattern)\(attributePattern)*\\s*/?>"

/// CommonMark HTML close-tag regular expression pattern.
// parity: patchmark/src/inline.ts#CLOSETAG [status=implemented hash=663548261dc6]
public let CLOSETAG: String = "</\(tagNamePattern)\\s*[>]"

// MARK: - Character & UTF-16 Helpers

@inline(__always)
func isAsciiWhitespace(_ c: UInt16) -> Bool {
    c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0B || c == 0x0C || c == 0x0D
}

func trimJsWhitespace(_ s: String) -> String {
    let u = Array(s.utf16)
    var start = 0
    var end = u.count
    while start < end && isJsWhitespace(u[start]) { start += 1 }
    while end > start && isJsWhitespace(u[end - 1]) { end -= 1 }
    if start == 0 && end == u.count { return s }
    return String(decoding: u[start..<end], as: UTF16.self)
}

private func isUnicodePunctuation(_ scalar: UnicodeScalar) -> Bool {
    let v = scalar.value
    if v < 128 {
        return isEscapableAscii(UInt16(v))
    }
    switch scalar.properties.generalCategory {
    case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
         .initialPunctuation, .finalPunctuation, .otherPunctuation,
         .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
        return true
    default:
        return false
    }
}

private func isUnicodeWhitespace(_ scalar: UnicodeScalar) -> Bool {
    let v = scalar.value
    if v <= 0xFFFF {
        return isJsWhitespace(UInt16(v))
    }
    return scalar.properties.isWhitespace
}

private func scalarBefore(in u: [UInt16], index: Int) -> UnicodeScalar {
    guard index > 0 else { return "\n" }
    let low = u[index - 1]
    if low >= 0xDC00 && low <= 0xDFFF && index >= 2 {
        let high = u[index - 2]
        if high >= 0xD800 && high <= 0xDBFF {
            let cp = 0x10000 + ((UInt32(high - 0xD800) << 10) | UInt32(low - 0xDC00))
            if let s = UnicodeScalar(cp) { return s }
        }
    }
    return UnicodeScalar(low) ?? "\u{FFFD}"
}

private func scalarAt(in u: [UInt16], index: Int) -> UnicodeScalar {
    guard index < u.count else { return "\n" }
    let high = u[index]
    if high >= 0xD800 && high <= 0xDBFF && index + 1 < u.count {
        let low = u[index + 1]
        if low >= 0xDC00 && low <= 0xDFFF {
            let cp = 0x10000 + ((UInt32(high - 0xD800) << 10) | UInt32(low - 0xDC00))
            if let s = UnicodeScalar(cp) { return s }
        }
    }
    return UnicodeScalar(high) ?? "\u{FFFD}"
}

// MARK: - Shared HTML Open/Close Tag Scanners (also used by PatchmarkBlocks)

@inline(__always)
private func isTagNameChar(_ c: UInt16) -> Bool {
    isAsciiAlnum(c) || c == 0x2D
}

@inline(__always)
private func isAttrNameStart(_ c: UInt16) -> Bool {
    isAsciiLetter(c) || c == 0x5F || c == 0x3A
}

@inline(__always)
private func isAttrNameChar(_ c: UInt16) -> Bool {
    isAsciiAlnum(c) || c == 0x3A || c == 0x2E || c == 0x5F || c == 0x2D
}

@inline(__always)
private func isUnquotedAttrChar(_ c: UInt16) -> Bool {
    c > 0x20 && c != 0x22 && c != 0x27 && c != 0x3D && c != 0x3C && c != 0x3E && c != 0x60
}

func matchOpenTagEnd(in u: [UInt16], at start: Int) -> Int? {
    let n = u.count
    guard start + 2 < n, u[start] == 0x3C /* < */, isAsciiLetter(u[start + 1]) else { return nil }
    var i = start + 2
    while i < n && isTagNameChar(u[i]) { i += 1 }

    while true {
        let wsStart = i
        while i < n && isJsWhitespace(u[i]) { i += 1 }
        guard i < n else { return nil }
        if u[i] == 0x3E /* > */ { return i + 1 }
        if u[i] == 0x2F /* / */ {
            guard i + 1 < n && u[i + 1] == 0x3E else { return nil }
            return i + 2
        }
        guard i > wsStart, isAttrNameStart(u[i]) else { return nil }
        i += 1
        while i < n && isAttrNameChar(u[i]) { i += 1 }

        let afterName = i
        while i < n && isJsWhitespace(u[i]) { i += 1 }
        if i < n && u[i] == 0x3D /* = */ {
            i += 1
            while i < n && isJsWhitespace(u[i]) { i += 1 }
            guard i < n else { return nil }
            let q = u[i]
            if q == 0x27 /* ' */ || q == 0x22 /* " */ {
                i += 1
                while i < n && u[i] != q { i += 1 }
                guard i < n else { return nil }
                i += 1
            } else {
                let valStart = i
                while i < n && isUnquotedAttrChar(u[i]) { i += 1 }
                guard i > valStart else { return nil }
            }
        } else {
            i = afterName
        }
    }
}

func matchCloseTagEnd(in u: [UInt16], at start: Int) -> Int? {
    let n = u.count
    guard start + 3 < n, u[start] == 0x3C, u[start + 1] == 0x2F, isAsciiLetter(u[start + 2]) else { return nil }
    var i = start + 3
    while i < n && isTagNameChar(u[i]) { i += 1 }
    while i < n && isJsWhitespace(u[i]) { i += 1 }
    guard i < n, u[i] == 0x3E else { return nil }
    return i + 1
}

private func matchHtmlTagEnd(in u: [UInt16], at start: Int) -> Int? {
    let n = u.count
    guard start + 2 < n, u[start] == 0x3C /* < */ else { return nil }
    if let end = matchOpenTagEnd(in: u, at: start) { return end }
    if let end = matchCloseTagEnd(in: u, at: start) { return end }

    let second = u[start + 1]
    if second == 0x21 /* ! */ {
        // HTMLCOMMENT: <!-->|<!--->|<!--[\s\S]*?-->
        if start + 3 < n && u[start + 2] == 0x2D && u[start + 3] == 0x2D {
            if start + 4 < n && u[start + 4] == 0x3E { return start + 5 }
            if start + 5 < n && u[start + 4] == 0x2D && u[start + 5] == 0x3E { return start + 6 }
            var i = start + 4
            while i + 2 < n {
                if u[i] == 0x2D && u[i + 1] == 0x2D && u[i + 2] == 0x3E {
                    return i + 3
                }
                i += 1
            }
            return nil
        }
        // CDATA: <![CDATA[[\s\S]*?]]>
        if start + 8 < n
            && u[start + 2] == 0x5B // [
            && u[start + 3] == 0x43 // C
            && u[start + 4] == 0x44 // D
            && u[start + 5] == 0x41 // A
            && u[start + 6] == 0x54 // T
            && u[start + 7] == 0x41 // A
            && u[start + 8] == 0x5B // [
        {
            var i = start + 9
            while i + 2 < n {
                if u[i] == 0x5D && u[i + 1] == 0x5D && u[i + 2] == 0x3E {
                    return i + 3
                }
                i += 1
            }
            return nil
        }
        // DECLARATION: <![A-Za-z]+[^>]*>
        if start + 2 < n && isAsciiLetter(u[start + 2]) {
            var i = start + 3
            while i < n && isAsciiLetter(u[i]) { i += 1 }
            while i < n && u[i] != 0x3E { i += 1 }
            if i < n && u[i] == 0x3E { return i + 1 }
            return nil
        }
    } else if second == 0x3F /* ? */ {
        // PROCESSINGINSTRUCTION: <\?[\s\S]*?\?>
        var i = start + 2
        while i + 1 < n {
            if u[i] == 0x3F && u[i + 1] == 0x3E {
                return i + 2
            }
            i += 1
        }
        return nil
    }
    return nil
}

// MARK: - Reference Normalization

/// Normalizes a link label: strips surrounding brackets, trims, collapses whitespace, and Unicode case-folds.
// parity: patchmark/src/inline.ts#normalizeReference [status=implemented hash=cd28c0c91d3b]
public func normalizeReference(_ label: String) -> String {
    let u = Array(label.utf16)
    guard u.count >= 2 else { return "" }
    let inner = trimJsWhitespace(String(decoding: u[1..<(u.count - 1)], as: UTF16.self))
    let innerU = Array(inner.utf16)
    var collapsed: [UInt16] = []
    collapsed.reserveCapacity(innerU.count)
    var inWs = false
    for c in innerU {
        if c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0A {
            if !inWs {
                collapsed.append(0x20)
                inWs = true
            }
        } else {
            collapsed.append(c)
            inWs = false
        }
    }
    return String(decoding: collapsed, as: UTF16.self).lowercased().uppercased()
}

// MARK: - Internal AST & Delimiter/Bracket Stack

private enum INodeType {
    case text
    case softbreak
    case linebreak
    case code
    case emph
    case strong
    case del
    case link
    case image
    case htmlInline
    case math
    case root
}

private final class INode {
    var type: INodeType
    var literal: String
    var escaped = false
    var destination = ""
    var title = ""
    var delimiter: MathDelimiter = .dollar
    var display = false
    weak var parent: INode?
    var first: INode?
    var last: INode?
    var next: INode?
    weak var prev: INode?

    init(_ type: INodeType, _ literal: String = "") {
        self.type = type
        self.literal = literal
    }

    func appendChild(_ child: INode) {
        child.unlink()
        child.parent = self
        if let last {
            last.next = child
            child.prev = last
            self.last = child
        } else {
            self.first = child
            self.last = child
        }
    }

    func insertAfter(_ sibling: INode) {
        sibling.unlink()
        sibling.next = self.next
        if let next = sibling.next { next.prev = sibling }
        sibling.prev = self
        self.next = sibling
        sibling.parent = self.parent
        if let parent = sibling.parent, sibling.next == nil {
            parent.last = sibling
        }
    }

    func unlink() {
        if let prev {
            prev.next = self.next
        } else if let parent {
            parent.first = self.next
        }
        if let next {
            next.prev = self.prev
        } else if let parent {
            parent.last = self.prev
        }
        self.parent = nil
        self.next = nil
        self.prev = nil
    }
}

private final class Delimiter {
    var cc: UInt16
    var numdelims: Int
    var origdelims: Int
    var node: INode
    var previous: Delimiter?
    var next: Delimiter?
    var canOpen: Bool
    var canClose: Bool

    init(
        cc: UInt16,
        numdelims: Int,
        origdelims: Int,
        node: INode,
        previous: Delimiter?,
        canOpen: Bool,
        canClose: Bool
    ) {
        self.cc = cc
        self.numdelims = numdelims
        self.origdelims = origdelims
        self.node = node
        self.previous = previous
        self.next = nil
        self.canOpen = canOpen
        self.canClose = canClose
    }
}

private final class Bracket {
    var node: INode
    var previous: Bracket?
    var previousDelimiter: Delimiter?
    var index: Int
    var image: Bool
    var active: Bool
    var bracketAfter: Bool

    init(
        node: INode,
        previous: Bracket?,
        previousDelimiter: Delimiter?,
        index: Int,
        image: Bool
    ) {
        self.node = node
        self.previous = previous
        self.previousDelimiter = previousDelimiter
        self.index = index
        self.image = image
        self.active = true
        self.bracketAfter = false
    }
}

private let cNewline: UInt16 = 10
private let cAsterisk: UInt16 = 42
private let cUnderscore: UInt16 = 95
private let cBacktick: UInt16 = 96
private let cOpenBracket: UInt16 = 91
private let cCloseBracket: UInt16 = 93
private let cLessThan: UInt16 = 60
private let cBang: UInt16 = 33
private let cBackslash: UInt16 = 92
private let cAmpersand: UInt16 = 38
private let cOpenParen: UInt16 = 40
private let cCloseParen: UInt16 = 41
private let cColon: UInt16 = 58
private let cTilde: UInt16 = 126
private let cDollar: UInt16 = 36

private func isSpecialFastPath(_ u: [UInt16], gfm: Bool, math: Bool) -> Bool {
    for c in u {
        if c == cNewline
            || c == cBackslash
            || c == cBacktick
            || c == cAsterisk
            || c == cUnderscore
            || c == cOpenBracket
            || c == cCloseBracket
            || c == cBang
            || c == cLessThan
            || c == cAmpersand
            || (gfm && (c == cTilde || c == cColon || c == 0x40 || c == 0x2E))
            || (math && c == cDollar)
        {
            return true
        }
    }
    return false
}

// MARK: - Inline Parser Implementation

private final class InlineParser {
    var u: [UInt16] = []
    var pos = 0
    var delimiters: Delimiter?
    var brackets: Bracket?
    var refmap: RefMap = [:]
    var gfm = false
    var math = false
    var tickRuns: [Int: [Int]]?
    var unresolvedRefs: Set<String> = []
    var usedRefs: Set<String> = []
    var trackRefs = false

    @inline(__always)
    func peek() -> Int {
        pos < u.count ? Int(u[pos]) : -1
    }

    @inline(__always)
    func slice(_ start: Int, _ end: Int) -> String {
        String(decoding: u[start..<end], as: UTF16.self)
    }

    @discardableResult
    func spnl() -> Bool {
        while pos < u.count && u[pos] == 0x20 { pos += 1 }
        if pos < u.count && u[pos] == 0x0A {
            pos += 1
            while pos < u.count && u[pos] == 0x20 { pos += 1 }
        }
        return true
    }

    func parseBackticks(_ block: INode) -> Bool {
        guard pos < u.count && u[pos] == cBacktick else { return false }
        let start = pos
        while pos < u.count && u[pos] == cBacktick { pos += 1 }
        let afterOpenTicks = pos
        let len = afterOpenTicks - start
        let ticks = slice(start, afterOpenTicks)

        func makeCodeNode(from contentStart: Int, to contentEnd: Int) -> INode {
            var contentU = Array(u[contentStart..<contentEnd])
            for k in 0..<contentU.count where contentU[k] == 0x0A {
                contentU[k] = 0x20
            }
            let hasNonSpace = contentU.contains { $0 != 0x20 }
            let lit: String
            if contentU.count >= 2 && hasNonSpace && contentU[0] == 0x20 && contentU[contentU.count - 1] == 0x20 {
                lit = String(decoding: contentU[1..<(contentU.count - 1)], as: UTF16.self)
            } else {
                lit = String(decoding: contentU, as: UTF16.self)
            }
            return INode(.code, lit)
        }

        if tickRuns == nil {
            // Find next run of backticks
            var j = pos
            while j < u.count && u[j] != cBacktick { j += 1 }
            if j >= u.count {
                pos = afterOpenTicks
                block.appendChild(INode(.text, ticks))
                return true
            }
            let runStart = j
            while j < u.count && u[j] == cBacktick { j += 1 }
            let runLen = j - runStart
            if runLen == len {
                pos = j
                block.appendChild(makeCodeNode(from: afterOpenTicks, to: runStart))
                return true
            }
            var map: [Int: [Int]] = [runLen: [j]]
            while j < u.count {
                while j < u.count && u[j] != cBacktick { j += 1 }
                if j >= u.count { break }
                let rs = j
                while j < u.count && u[j] == cBacktick { j += 1 }
                map[j - rs, default: []].append(j)
            }
            tickRuns = map
        }

        if let candidates = tickRuns?[len] {
            for endPos in candidates {
                if endPos - len >= afterOpenTicks {
                    pos = endPos
                    block.appendChild(makeCodeNode(from: afterOpenTicks, to: endPos - len))
                    return true
                }
            }
        }

        pos = afterOpenTicks
        block.appendChild(INode(.text, ticks))
        return true
    }

    func parseBackslash(_ block: INode) -> Bool {
        if math, let m = matchInlineParenMath(in: u, at: pos) {
            let body = trimJsWhitespace(slice(m.bodyStart, m.bodyEnd))
            let node = INode(.math, body)
            node.delimiter = .paren
            node.display = false
            block.appendChild(node)
            pos = m.end
            return true
        }
        pos += 1
        if peek() == Int(cNewline) {
            pos += 1
            block.appendChild(INode(.linebreak))
        } else if pos < u.count && isEscapableAscii(u[pos]) {
            let node = INode(.text, slice(pos, pos + 1))
            node.escaped = true
            block.appendChild(node)
            pos += 1
        } else {
            block.appendChild(INode(.text, "\\"))
        }
        return true
    }

    func parseDollar(_ block: INode) -> Bool {
        guard let m = matchInlineDollarMath(in: u, at: pos) else { return false }
        let body = trimJsWhitespace(slice(m.bodyStart, m.bodyEnd))
        let node = INode(.math, body)
        node.delimiter = m.display ? .doubleDollar : .dollar
        node.display = m.display
        block.appendChild(node)
        pos = m.end
        return true
    }

    private func matchEmailAutolinkEnd() -> Int? {
        let n = u.count
        guard pos + 4 < n, u[pos] == cLessThan else { return nil }
        var i = pos + 1
        let localStart = i
        while i < n {
            let c = u[i]
            let ok = isAsciiAlnum(c)
                || c == 0x2E || c == 0x21 || c == 0x23 || c == 0x24 || c == 0x25 || c == 0x26
                || c == 0x27 || c == 0x2A || c == 0x2B || c == 0x2F || c == 0x3D || c == 0x3F
                || c == 0x5E || c == 0x5F || c == 0x60 || c == 0x7B || c == 0x7C || c == 0x7D
                || c == 0x7E || c == 0x2D
            if ok { i += 1 } else { break }
        }
        guard i > localStart, i < n, u[i] == 0x40 /* @ */ else { return nil }
        i += 1
        // Domain labels separated by '.'
        func readLabel() -> Bool {
            guard i < n, isAsciiAlnum(u[i]) else { return false }
            let start = i
            i += 1
            while i < n && (isAsciiAlnum(u[i]) || u[i] == 0x2D) { i += 1 }
            let length = i - start
            guard length <= 63 else { return false }
            guard isAsciiAlnum(u[i - 1]) else { return false }
            return true
        }
        guard readLabel() else { return nil }
        while i < n && u[i] == 0x2E {
            i += 1
            guard readLabel() else { return nil }
        }
        guard i < n, u[i] == 0x3E /* > */ else { return nil }
        return i + 1
    }

    private func matchUriAutolinkEnd() -> Int? {
        let n = u.count
        guard pos + 4 < n, u[pos] == cLessThan, isAsciiLetter(u[pos + 1]) else { return nil }
        var i = pos + 2
        while i < n {
            let c = u[i]
            if isAsciiAlnum(c) || c == 0x2E || c == 0x2B || c == 0x2D {
                i += 1
            } else {
                break
            }
        }
        let schemeLen = i - (pos + 1)
        guard schemeLen >= 2 && schemeLen <= 32, i < n, u[i] == cColon else { return nil }
        i += 1
        while i < n {
            let c = u[i]
            if c == 0x3E /* > */ { return i + 1 }
            if c == 0x3C || c <= 0x20 { return nil }
            i += 1
        }
        return nil
    }

    func parseAutolink(_ block: INode) -> Bool {
        if let end = matchEmailAutolinkEnd() {
            let dest = slice(pos + 1, end - 1)
            pos = end
            let node = INode(.link)
            node.destination = normalizeURI("mailto:" + dest)
            node.appendChild(INode(.text, dest))
            block.appendChild(node)
            return true
        }
        if let end = matchUriAutolinkEnd() {
            let dest = slice(pos + 1, end - 1)
            pos = end
            let node = INode(.link)
            node.destination = normalizeURI(dest)
            node.appendChild(INode(.text, dest))
            block.appendChild(node)
            return true
        }
        return false
    }

    func parseHtmlTag(_ block: INode) -> Bool {
        guard let end = matchHtmlTagEnd(in: u, at: pos) else { return false }
        let raw = slice(pos, end)
        pos = end
        block.appendChild(INode(.htmlInline, raw))
        return true
    }

    func scanDelims(_ cc: UInt16) -> (numdelims: Int, canOpen: Bool, canClose: Bool)? {
        var numdelims = 0
        let startpos = pos
        while pos < u.count && u[pos] == cc {
            numdelims += 1
            pos += 1
        }
        if numdelims == 0 { return nil }

        let beforeScalar = scalarBefore(in: u, index: startpos)
        let afterScalar = scalarAt(in: u, index: pos)

        let afterIsWhitespace = isUnicodeWhitespace(afterScalar)
        let afterIsPunctuation = isUnicodePunctuation(afterScalar)
        let beforeIsWhitespace = isUnicodeWhitespace(beforeScalar)
        let beforeIsPunctuation = isUnicodePunctuation(beforeScalar)

        let leftFlanking =
            (!afterIsWhitespace && (!afterIsPunctuation || beforeIsWhitespace || beforeIsPunctuation))
            || (gfm && cc != cTilde && afterScalar == "~")
        let rightFlanking =
            (!beforeIsWhitespace && (!beforeIsPunctuation || afterIsWhitespace || afterIsPunctuation))
            || (gfm && cc != cTilde && beforeScalar == "~")

        var canOpen: Bool
        var canClose: Bool
        if cc == cUnderscore {
            canOpen = leftFlanking && (!rightFlanking || beforeIsPunctuation)
            canClose = rightFlanking && (!leftFlanking || afterIsPunctuation)
        } else {
            canOpen = leftFlanking
            canClose = rightFlanking
        }
        if cc == cTilde && numdelims > 2 {
            canOpen = false
            canClose = false
        }
        pos = startpos
        return (numdelims, canOpen, canClose)
    }

    func handleDelim(_ cc: UInt16, _ block: INode) -> Bool {
        guard let res = scanDelims(cc) else { return false }
        let numdelims = res.numdelims
        let startpos = pos
        pos += numdelims
        let node = INode(.text, slice(startpos, pos))
        block.appendChild(node)

        if res.canOpen || res.canClose {
            let delim = Delimiter(
                cc: cc,
                numdelims: numdelims,
                origdelims: numdelims,
                node: node,
                previous: delimiters,
                canOpen: res.canOpen,
                canClose: res.canClose
            )
            if let prev = delim.previous { prev.next = delim }
            delimiters = delim
        }
        return true
    }

    func removeDelimiter(_ delim: Delimiter) {
        if let prev = delim.previous { prev.next = delim.next }
        if let next = delim.next {
            next.previous = delim.previous
        } else {
            delimiters = delim.previous
        }
    }

    func processEmphasis(_ stackBottom: Delimiter?) {
        if delimiters === stackBottom { return }
        var openersBottom: [Delimiter?] = Array(repeating: stackBottom, count: 16)

        var closer = delimiters
        while let c = closer, c.previous !== stackBottom {
            closer = c.previous
        }

        while let c = closer {
            let closercc = c.cc
            if !c.canClose {
                closer = c.next
                continue
            }
            var opener = c.previous
            var openerFound = false
            let openersBottomIndex: Int
            if closercc == cUnderscore {
                openersBottomIndex = 2 + (c.canOpen ? 3 : 0) + (c.origdelims % 3)
            } else if closercc == cAsterisk {
                openersBottomIndex = 8 + (c.canOpen ? 3 : 0) + (c.origdelims % 3)
            } else {
                openersBottomIndex = 14 + (c.origdelims == 2 ? 1 : 0)
            }

            while let op = opener, op !== stackBottom, op !== openersBottom[openersBottomIndex] {
                if closercc == cTilde {
                    if op.cc == cTilde && op.canOpen && op.origdelims == c.origdelims {
                        openerFound = true
                        break
                    }
                } else {
                    let oddMatch =
                        (c.canOpen || op.canClose)
                        && c.origdelims % 3 != 0
                        && (op.origdelims + c.origdelims) % 3 == 0
                    if op.cc == c.cc && op.canOpen && !oddMatch {
                        openerFound = true
                        break
                    }
                }
                opener = op.previous
            }
            let oldCloser = c

            if !openerFound {
                closer = c.next
            } else if let op = opener {
                let useDelims = closercc == cTilde ? c.numdelims : (c.numdelims >= 2 && op.numdelims >= 2 ? 2 : 1)
                let openerInl = op.node
                let closerInl = c.node
                op.numdelims -= useDelims
                c.numdelims -= useDelims
                openerInl.literal = String(openerInl.literal.dropLast(useDelims))
                closerInl.literal = String(closerInl.literal.dropLast(useDelims))

                let emphType: INodeType = closercc == cTilde ? .del : (useDelims == 1 ? .emph : .strong)
                let emph = INode(emphType)
                var tmp = openerInl.next
                while let node = tmp, node !== closerInl {
                    let next = node.next
                    node.unlink()
                    emph.appendChild(node)
                    tmp = next
                }
                openerInl.insertAfter(emph)

                if op.next !== c {
                    op.next = c
                    c.previous = op
                }

                if op.numdelims == 0 {
                    openerInl.unlink()
                    removeDelimiter(op)
                }
                if c.numdelims == 0 {
                    closerInl.unlink()
                    let tempstack = c.next
                    removeDelimiter(c)
                    closer = tempstack
                }
            }
            if !openerFound {
                openersBottom[openersBottomIndex] = oldCloser.previous
                if !oldCloser.canOpen { removeDelimiter(oldCloser) }
            }
        }

        while let d = delimiters, d !== stackBottom {
            removeDelimiter(d)
        }
    }

    func parseLinkTitle() -> String? {
        let n = u.count
        guard pos < n else { return nil }
        let open = u[pos]
        let close: UInt16
        let disallowOpen: Bool
        if open == 0x22 /* " */ {
            close = 0x22
            disallowOpen = false
        } else if open == 0x27 /* ' */ {
            close = 0x27
            disallowOpen = false
        } else if open == 0x28 /* ( */ {
            close = 0x29
            disallowOpen = true
        } else {
            return nil
        }

        var i = pos + 1
        while i < n {
            let c = u[i]
            if c == close {
                let raw = slice(pos + 1, i)
                pos = i + 1
                return unescapeString(raw)
            }
            if c == cBackslash {
                guard i + 1 < n else { return nil }
                i += 2
                continue
            }
            if c == 0x00 || (disallowOpen && c == 0x28) {
                return nil
            }
            i += 1
        }
        return nil
    }

    func parseLinkDestination() -> String? {
        let n = u.count
        if pos < n && u[pos] == cLessThan {
            var i = pos + 1
            while i < n {
                let c = u[i]
                if c == 0x3E /* > */ {
                    let raw = slice(pos + 1, i)
                    pos = i + 1
                    return normalizeURI(unescapeString(raw))
                }
                if c == cBackslash {
                    guard i + 1 < n && !isJsLineTerminator(u[i + 1]) else { return nil }
                    i += 2
                    continue
                }
                if c == cLessThan || c == cNewline || c == 0x00 {
                    return nil
                }
                i += 1
            }
            return nil
        }

        let savepos = pos
        var openparens = 0
        var c = peek()
        while c != -1 {
            let cu = UInt16(c)
            if cu == cBackslash && pos + 1 < n && isEscapableAscii(u[pos + 1]) {
                pos += 1
                if peek() != -1 { pos += 1 }
            } else if cu == cOpenParen {
                pos += 1
                openparens += 1
            } else if cu == cCloseParen {
                if openparens < 1 { break }
                pos += 1
                openparens -= 1
            } else if isAsciiWhitespace(cu) {
                break
            } else if cu < 0x20 || cu == 0x7F {
                break
            } else {
                pos += 1
            }
            c = peek()
        }
        if pos == savepos && c != Int(cCloseParen) { return nil }
        if openparens != 0 { return nil }
        let res = slice(savepos, pos)
        return normalizeURI(unescapeString(res))
    }

    func parseLinkLabel() -> Int {
        let n = u.count
        guard pos < n, u[pos] == cOpenBracket else { return 0 }
        let start = pos
        var i = pos + 1
        var atoms = 0
        while i < n {
            let c = u[i]
            if c == cCloseBracket {
                let len = i + 1 - start
                guard len <= 1001 else { return 0 }
                pos = i + 1
                return len
            }
            if c == cOpenBracket { return 0 }
            if c == cBackslash {
                guard i + 1 < n else { return 0 }
                i += 2
                atoms += 1
            } else {
                i += 1
                atoms += 1
            }
            if atoms > 1000 { return 0 }
        }
        return 0
    }

    func parseOpenBracket(_ block: INode) -> Bool {
        let startpos = pos
        pos += 1
        let node = INode(.text, "[")
        block.appendChild(node)
        addBracket(node, index: startpos, image: false)
        return true
    }

    func parseBang(_ block: INode) -> Bool {
        let startpos = pos
        pos += 1
        if peek() == Int(cOpenBracket) {
            pos += 1
            let node = INode(.text, "![")
            block.appendChild(node)
            addBracket(node, index: startpos + 1, image: true)
        } else {
            block.appendChild(INode(.text, "!"))
        }
        return true
    }

    func lookupRef(_ label: String) -> ReferenceDef? {
        let norm = normalizeReference(label)
        if let def = refmap[norm] {
            if trackRefs { usedRefs.insert(norm) }
            return def
        }
        if trackRefs && !norm.isEmpty {
            unresolvedRefs.insert(norm)
        }
        return nil
    }

    func parseCloseBracket(_ block: INode) -> Bool {
        var dest: String? = nil
        var title: String? = nil
        var matched = false

        pos += 1
        let startpos = pos
        guard let opener = brackets else {
            block.appendChild(INode(.text, "]"))
            return true
        }
        if !opener.active {
            block.appendChild(INode(.text, "]"))
            removeBracket()
            return true
        }
        let isImage = opener.image
        let savepos = pos

        if peek() == Int(cOpenParen) {
            pos += 1
            _ = spnl()
            if let parsedDest = parseLinkDestination() {
                dest = parsedDest
                _ = spnl()
                if pos > 0 && isAsciiWhitespace(u[pos - 1]) {
                    title = parseLinkTitle()
                }
                _ = spnl()
                if peek() == Int(cCloseParen) {
                    pos += 1
                    matched = true
                } else {
                    pos = savepos
                }
            } else {
                pos = savepos
            }
        }

        if !matched {
            let beforelabel = pos
            let n = parseLinkLabel()
            var reflabel: String? = nil
            if n > 2 {
                reflabel = slice(beforelabel, beforelabel + n)
            } else if !opener.bracketAfter {
                reflabel = slice(opener.index, startpos)
            }
            if n == 0 { pos = savepos }
            if let reflabel, let link = lookupRef(reflabel) {
                dest = link.href
                title = link.title
                matched = true
            }
        }

        if matched {
            let node = INode(isImage ? .image : .link)
            node.destination = dest ?? ""
            node.title = title ?? ""
            var tmp = opener.node.next
            while let cur = tmp {
                let next = cur.next
                cur.unlink()
                node.appendChild(cur)
                tmp = next
            }
            block.appendChild(node)
            processEmphasis(opener.previousDelimiter)
            removeBracket()
            opener.node.unlink()
            if !isImage {
                var b = brackets
                while let cur = b {
                    if !cur.image {
                        if !cur.active { break }
                        cur.active = false
                    }
                    b = cur.previous
                }
            }
            return true
        }

        removeBracket()
        pos = startpos
        block.appendChild(INode(.text, "]"))
        return true
    }

    func addBracket(_ node: INode, index: Int, image: Bool) {
        brackets?.bracketAfter = true
        brackets = Bracket(
            node: node,
            previous: brackets,
            previousDelimiter: delimiters,
            index: index,
            image: image
        )
    }

    func removeBracket() {
        brackets = brackets?.previous
    }

    func parseEntity(_ block: INode) -> Bool {
        guard let end = matchEntityEnd(in: u, at: pos) else { return false }
        let raw = slice(pos, end)
        pos = end
        let node = INode(.text, decodeEntity(raw))
        node.escaped = true
        block.appendChild(node)
        return true
    }

    func parseString(_ block: INode) -> Bool {
        let start = pos
        let n = u.count
        while pos < n {
            let c = u[pos]
            if c == cNewline || c == cBacktick || c == cOpenBracket || c == cCloseBracket
                || c == cBackslash || c == cBang || c == cLessThan || c == cAmpersand
                || c == cAsterisk || c == cUnderscore || c == 0x27 || c == 0x22
                || (gfm && c == cTilde)
                || (math && c == cDollar)
            {
                break
            }
            pos += 1
        }
        guard pos > start else { return false }
        block.appendChild(INode(.text, slice(start, pos)))
        return true
    }

    func parseNewline(_ block: INode) -> Bool {
        pos += 1
        if let lastc = block.last, lastc.type == .text, !lastc.literal.isEmpty {
            let lastU = Array(lastc.literal.utf16)
            if lastU[lastU.count - 1] == 0x20 {
                let hardbreak = lastU.count >= 2 && lastU[lastU.count - 2] == 0x20
                var trimEnd = lastU.count
                while trimEnd > 0 && lastU[trimEnd - 1] == 0x20 { trimEnd -= 1 }
                lastc.literal = String(decoding: lastU[0..<trimEnd], as: UTF16.self)
                block.appendChild(INode(hardbreak ? .linebreak : .softbreak))
            } else {
                block.appendChild(INode(.softbreak))
            }
        } else {
            block.appendChild(INode(.softbreak))
        }
        while pos < u.count && u[pos] == 0x20 { pos += 1 }
        return true
    }

    func matchSpaceAtEndOfLine() -> Bool {
        let save = pos
        while pos < u.count && u[pos] == 0x20 { pos += 1 }
        if pos == u.count { return true }
        if u[pos] == cNewline {
            pos += 1
            return true
        }
        pos = save
        return false
    }

    func parseReference(_ s: String, into refmap: inout RefMap) -> (consumed: Int, addedKey: String?) {
        self.u = Array(s.utf16)
        self.pos = 0
        let startpos = 0
        var title: String? = nil

        let matchChars = parseLinkLabel()
        if matchChars == 0 { return (0, nil) }
        let rawlabel = slice(0, matchChars)

        if peek() == Int(cColon) {
            pos += 1
        } else {
            pos = startpos
            return (0, nil)
        }

        _ = spnl()
        guard let dest = parseLinkDestination() else {
            pos = startpos
            return (0, nil)
        }

        let beforetitle = pos
        _ = spnl()
        if pos != beforetitle {
            title = parseLinkTitle()
        }
        if title == nil { pos = beforetitle }

        var atLineEnd = true
        if !matchSpaceAtEndOfLine() {
            if title == nil {
                atLineEnd = false
            } else {
                title = nil
                pos = beforetitle
                atLineEnd = matchSpaceAtEndOfLine()
            }
        }
        if !atLineEnd {
            pos = startpos
            return (0, nil)
        }

        let normlabel = normalizeReference(rawlabel)
        if normlabel.isEmpty {
            pos = startpos
            return (0, nil)
        }
        var addedKey: String? = nil
        if refmap[normlabel] == nil {
            let cleanTitle = (title?.isEmpty == false) ? title : nil
            refmap[normlabel] = ReferenceDef(
                href: dest,
                title: cleanTitle,
                raw: trimJsWhitespace(slice(0, pos))
            )
            addedKey = normlabel
        }
        return (pos - startpos, addedKey)
    }

    func parseInline(_ block: INode) -> Bool {
        let c = peek()
        if c == -1 { return false }
        let cu = UInt16(c)
        let res: Bool
        switch cu {
        case cNewline:
            res = parseNewline(block)
        case cBackslash:
            res = parseBackslash(block)
        case cBacktick:
            res = parseBackticks(block)
        case cAsterisk, cUnderscore:
            res = handleDelim(cu, block)
        case cTilde:
            res = gfm && handleDelim(cu, block)
        case cDollar:
            res = math && parseDollar(block)
        case cOpenBracket:
            res = parseOpenBracket(block)
        case cBang:
            res = parseBang(block)
        case cCloseBracket:
            res = parseCloseBracket(block)
        case cLessThan:
            res = parseAutolink(block) || parseHtmlTag(block)
        case cAmpersand:
            res = parseEntity(block)
        default:
            res = parseString(block)
        }
        if !res {
            let start = pos
            pos += 1
            block.appendChild(INode(.text, slice(start, pos)))
        }
        return true
    }

    func parse(_ content: String) -> INode {
        let root = INode(.root)
        self.u = Array(trimJsWhitespace(content).utf16)
        self.pos = 0
        self.delimiters = nil
        self.brackets = nil
        self.tickRuns = nil
        while parseInline(root) {}
        processEmphasis(nil)
        return root
    }
}

// MARK: - Public Entry Points

/// Internal variant returning both characters consumed and any newly inserted normalized key.
func parseReferenceWithKey(_ s: String, into refmap: inout RefMap) -> (consumed: Int, addedKey: String?) {
    let parser = InlineParser()
    return parser.parseReference(s, into: &refmap)
}

/// Parses a link reference definition at the start of `s` into `refmap`; returns the number of UTF-16 code units consumed.
// parity: patchmark/src/inline.ts#parseReference [status=implemented hash=2f918a63500c]
public func parseReference(_ s: String, into refmap: inout RefMap) -> Int {
    parseReferenceWithKey(s, into: &refmap).consumed
}

/// Parses inline markdown syntax into an array of `InlineNode`s.
// parity: patchmark/src/inline.ts#parseInlines [status=implemented hash=40749a4adf6a]
public func parseInlines(_ raw: String, options: InlineParseOptions = InlineParseOptions()) -> [InlineNode] {
    var used = Set<String>()
    var unresolved = Set<String>()
    return parseInlinesTracking(raw, options: options, trackRefs: false, usedRefs: &used, unresolvedRefs: &unresolved)
}

/// Internal inline parser entry point with reference-usage tracking for `PatchmarkStream`.
func parseInlinesTracking(
    _ raw: String,
    options: InlineParseOptions,
    trackRefs: Bool,
    usedRefs: inout Set<String>,
    unresolvedRefs: inout Set<String>
) -> [InlineNode] {
    let src = trimJsWhitespace(raw)
    if src.isEmpty { return [] }
    let srcU = Array(src.utf16)
    if !isSpecialFastPath(srcU, gfm: options.gfm, math: options.math) {
        return [.text(src)]
    }
    let parser = InlineParser()
    parser.refmap = options.defs
    parser.gfm = options.gfm
    parser.math = options.math
    parser.trackRefs = trackRefs
    let root = parser.parse(src)
    if trackRefs {
        usedRefs.formUnion(parser.usedRefs)
        unresolvedRefs.formUnion(parser.unresolvedRefs)
    }
    return convertChildren(root, gfm: options.gfm, inLink: false)
}

// MARK: - INode Tree to InlineNode Conversion + GFM Extended Autolinks

private func convertChildren(_ parent: INode, gfm: Bool, inLink: Bool) -> [InlineNode] {
    var out: [InlineNode] = []
    var pendingText = ""
    var prevChar: UInt16 = 0

    func pushText(_ s: String) {
        if s.isEmpty { return }
        if case .text(let prev) = out.last {
            out[out.count - 1] = .text(prev + s)
        } else {
            out.append(.text(s))
        }
    }

    func flush() {
        if pendingText.isEmpty { return }
        if gfm && !inLink {
            for node in autolinkLiterals(pendingText, prevChar: prevChar) {
                if case .text(let t) = node { pushText(t) }
                else { out.append(node) }
            }
        } else {
            pushText(pendingText)
        }
        prevChar = pendingText.utf16.last ?? 0
        pendingText = ""
    }

    var cursor = parent.first
    while let n = cursor {
        switch n.type {
        case .text:
            if gfm && !inLink && n.escaped {
                flush()
                pushText(n.literal)
                prevChar = n.literal.utf16.last ?? 0
            } else {
                pendingText.append(n.literal)
            }
        case .softbreak:
            pendingText.append("\n")
        case .linebreak:
            flush()
            out.append(.br)
            prevChar = cNewline
        case .code:
            flush()
            out.append(.code(n.literal))
            prevChar = cBacktick
        case .emph:
            flush()
            out.append(.em(convertChildren(n, gfm: gfm, inLink: inLink)))
            prevChar = cAsterisk
        case .strong:
            flush()
            out.append(.strong(convertChildren(n, gfm: gfm, inLink: inLink)))
            prevChar = cAsterisk
        case .del:
            flush()
            out.append(.del(convertChildren(n, gfm: gfm, inLink: inLink)))
            prevChar = cTilde
        case .link:
            flush()
            out.append(.link(
                href: n.destination,
                title: n.title.isEmpty ? nil : n.title,
                children: convertChildren(n, gfm: gfm, inLink: true)
            ))
            prevChar = cCloseParen
        case .image:
            flush()
            let children = convertChildren(n, gfm: gfm, inLink: true)
            out.append(.image(
                src: n.destination,
                alt: inlinePlainText(children),
                title: n.title.isEmpty ? nil : n.title,
                children: children
            ))
            prevChar = cCloseParen
        case .htmlInline:
            flush()
            out.append(.htmlInline(n.literal))
            prevChar = 0x3E
        case .math:
            flush()
            out.append(.math(source: n.literal, delimiter: n.delimiter, display: n.display))
            prevChar = cDollar
        case .root:
            break
        }
        cursor = n.next
    }
    flush()
    return out
}

private func inlinePlainText(_ nodes: [InlineNode]) -> String {
    var out = ""
    for node in nodes {
        switch node {
        case .text(let s), .code(let s):
            out.append(s)
        case .strong(let children), .em(let children), .del(let children), .link(_, _, let children):
            out.append(inlinePlainText(children))
        case .image(_, let alt, _, let children):
            out.append(children.map(inlinePlainText) ?? alt)
        case .math(let source, _, _):
            out.append(source)
        case .br:
            out.append("\n")
        case .htmlInline(let raw):
            out.append(raw)
        }
    }
    return out
}

// MARK: - GFM Extended Autolinks (cmark-gfm semantics)

@inline(__always)
private func isValidPrecedingForWww(_ u: [UInt16], _ i: Int, _ prevChar: UInt16) -> Bool {
    if i == 0 && prevChar == 0 { return true }
    let c = i == 0 ? prevChar : u[i - 1]
    return isAsciiWhitespace(c)
        || c == cAsterisk
        || c == cUnderscore
        || c == cTilde
        || c == cOpenParen
        || c == cOpenBracket
        || c == cCloseBracket
}

private func checkDomain(_ u: [UInt16], _ i: Int, allowShort: Bool) -> Int {
    var np = 0
    var uscore1 = 0
    var uscore2 = 0
    var j = i
    while j < u.count {
        let c = u[j]
        if c == cBackslash && j + 1 < u.count { break }
        if c == cUnderscore {
            uscore2 += 1
        } else if c == 0x2E {
            uscore1 = uscore2
            uscore2 = 0
            np += 1
        } else if !isAsciiAlnum(c) && c != 0x2D && c < 0x80 {
            break
        }
        j += 1
    }
    if (uscore1 > 0 || uscore2 > 0) && np <= 10 { return 0 }
    if allowShort || np > 0 { return j - i }
    return 0
}

private func autolinkDelim(_ u: [UInt16], _ start: Int, _ initialLen: Int) -> Int {
    var len = initialLen
    for k in 0..<len {
        if u[start + k] == cLessThan {
            len = k
            break
        }
    }
    while len > 0 {
        let cclose = u[start + len - 1]
        if cclose == cCloseParen {
            var opening = 0
            var closing = 0
            for k in 0..<len {
                let c = u[start + k]
                if c == cOpenParen { opening += 1 }
                else if c == cCloseParen { closing += 1 }
            }
            if closing <= opening { break }
            len -= 1
        } else if cclose == 0x3F || cclose == 0x21 || cclose == 0x2E || cclose == 0x2C
            || cclose == 0x3A || cclose == cAsterisk || cclose == cUnderscore
            || cclose == cTilde || cclose == 0x27 || cclose == 0x22
        {
            len -= 1
        } else if cclose == 0x3B /* ; */ {
            var newEnd = len - 2
            while newEnd > 0 && isAsciiAlnum(u[start + newEnd]) { newEnd -= 1 }
            if newEnd >= 0 && newEnd < len - 2 && u[start + newEnd] == cAmpersand {
                len = newEnd
            } else {
                len -= 1
            }
        } else {
            break
        }
    }
    return len
}

private func startsWithLowerWwwDot(_ u: [UInt16], at i: Int) -> Bool {
    guard i + 4 <= u.count else { return false }
    return u[i] == 0x77 && u[i + 1] == 0x77 && u[i + 2] == 0x77 && u[i + 3] == 0x2E
}

private func matchWww(_ u: [UInt16], _ i: Int, _ prevChar: UInt16) -> Int {
    if !isValidPrecedingForWww(u, i, prevChar) { return 0 }
    if !startsWithLowerWwwDot(u, at: i) { return 0 }
    let domainLen = checkDomain(u, i, allowShort: false)
    if domainLen == 0 { return 0 }
    var end = i + domainLen
    while end < u.count && !isAsciiWhitespace(u[end]) { end += 1 }
    return autolinkDelim(u, i, end - i)
}

private func matchUrl(_ u: [UInt16], _ i: Int, _ prevChar: UInt16) -> (len: Int, schemeLen: Int)? {
    guard i + 3 <= u.count, u[i] == cColon, u[i + 1] == 0x2F, u[i + 2] == 0x2F else { return nil }
    var start = i
    while start > 0 && isAsciiLetter(u[start - 1]) { start -= 1 }
    if start == 0 && prevChar != 0 && isAsciiLetter(prevChar) { return nil }
    let scheme = String(decoding: u[start..<i], as: UTF16.self).lowercased()
    guard scheme == "https" || scheme == "http" || scheme == "ftp" else { return nil }
    let domainLen = checkDomain(u, i + 3, allowShort: true)
    if domainLen == 0 { return nil }
    var end = i + 3 + domainLen
    while end < u.count && !isAsciiWhitespace(u[end]) { end += 1 }
    let len = autolinkDelim(u, start, end - start)
    if len <= i + 3 - start { return nil }
    return (len, i - start)
}

@inline(__always)
private func isEmailLocal(_ c: UInt16) -> Bool {
    isAsciiAlnum(c) || c == 0x2E || c == 0x2B || c == 0x2D || c == cUnderscore
}

private func matchEmail(_ u: [UInt16], at: Int, minStart: Int, prevChar: UInt16) -> (start: Int, end: Int)? {
    var start = at
    while start > minStart && isEmailLocal(u[start - 1]) { start -= 1 }
    if start == at { return nil }
    if start > 0 {
        if u[start - 1] == 0x2F { return nil }
    } else if prevChar != 0 {
        if prevChar == 0x2F || isEmailLocal(prevChar) { return nil }
    }
    var np = 0
    var end = at + 1
    while end < u.count {
        let c = u[end]
        if isAsciiAlnum(c) {
            end += 1
            continue
        }
        if c == 0x40 { return nil }
        if c == 0x2E && end + 1 < u.count && isAsciiAlnum(u[end + 1]) {
            np += 1
            end += 1
            continue
        }
        if c != 0x2D && c != cUnderscore { break }
        end += 1
    }
    if end - at < 2 || np == 0 { return nil }
    let last = u[end - 1]
    if !isAsciiLetter(last) { return nil }
    return (start, end)
}

private func hasAutolinkCandidate(_ u: [UInt16]) -> Bool {
    let n = u.count
    var i = 0
    while i < n {
        let c = u[i]
        if c == 0x40 /* @ */ { return true }
        if c == cColon && i + 2 < n && u[i + 1] == 0x2F && u[i + 2] == 0x2F { return true }
        if (c == 0x77 || c == 0x57) && i + 3 < n
            && (u[i + 1] == 0x77 || u[i + 1] == 0x57)
            && (u[i + 2] == 0x77 || u[i + 2] == 0x57)
            && u[i + 3] == 0x2E
        {
            return true
        }
        i += 1
    }
    return false
}

private func autolinkLiterals(_ s: String, prevChar: UInt16) -> [InlineNode] {
    let u = Array(s.utf16)
    if !hasAutolinkCandidate(u) { return [.text(s)] }
    var out: [InlineNode] = []
    var textStart = 0
    var i = 0

    func emit(_ start: Int, _ end: Int, href: String) {
        if start > textStart {
            out.append(.text(String(decoding: u[textStart..<start], as: UTF16.self)))
        }
        let label = String(decoding: u[start..<end], as: UTF16.self)
        out.append(.link(href: normalizeURI(href), title: nil, children: [.text(label)]))
        textStart = end
        i = end
    }

    while i < u.count {
        let c = u[i]
        if (c == 0x77 || c == 0x57) && startsWithLowerWwwDot(u, at: i) {
            let len = matchWww(u, i, prevChar)
            if len > 0 {
                let raw = String(decoding: u[i..<(i + len)], as: UTF16.self)
                emit(i, i + len, href: "http://" + raw)
                continue
            }
        } else if c == cColon {
            if let m = matchUrl(u, i, prevChar) {
                let start = i - m.schemeLen
                if start >= textStart {
                    let raw = String(decoding: u[start..<(start + m.len)], as: UTF16.self)
                    emit(start, start + m.len, href: raw)
                    continue
                }
            }
        } else if c == 0x40 {
            if let m = matchEmail(u, at: i, minStart: textStart, prevChar: prevChar) {
                let raw = String(decoding: u[m.start..<m.end], as: UTF16.self)
                emit(m.start, m.end, href: "mailto:" + raw)
                continue
            }
        }
        i += 1
    }
    if textStart == 0 { return [.text(s)] }
    if textStart < u.count {
        out.append(.text(String(decoding: u[textStart..<u.count], as: UTF16.self)))
    }
    return out
}
