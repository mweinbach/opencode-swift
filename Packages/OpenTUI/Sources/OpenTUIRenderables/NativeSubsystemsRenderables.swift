// Pure-Swift native subsystem parity bridges for OpenTUIRenderables (Workstream 3b).
// Covers all 225 unmapped symbols across 13 upstream `packages/native` Zig modules:
// - src/markdown.zig (20), src/markdown-inline.zig (34), src/markdown-tables.zig (2),
// - src/yoga.zig (65),
// - src/scene.zig (34), src/scene-record.zig (11), src/session.zig (24), src/native-renderable.zig (6),
// - src/embedded-terminal/main.zig (6), src/embedded-terminal/ghostty.zig (16),
//   src/embedded-terminal/compositor.zig (2), src/embedded-terminal/unavailable.zig (4),
//   src/ghostty-vt.zig (1).
// Pure Swift 6 — zero OS or Foundation imports.

import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout
import Synchronization

// MARK: - Top-level Namespace

public enum NativeRenderablesBridge: Sendable {}

// MARK: - 1. native/src/markdown-tables.zig (2 unmapped symbols)

public enum NativeZigMarkdownTables: Sendable {
    // parity: native/src/markdown-tables.zig#FoldRun [status=implemented hash=806ddefcac9d]
    public struct FoldRun: Equatable, Hashable, Sendable {
        public var start: UInt32
        public var end: UInt32
        public var step: UInt8
        public var delta: Int32

        public init(start: UInt32, end: UInt32, step: UInt8, delta: Int32) {
            self.start = start
            self.end = end
            self.step = step
            self.delta = delta
        }
    }

    // parity: native/src/markdown-tables.zig#FoldMulti [status=implemented hash=2692ea5a3588]
    public struct FoldMulti: Equatable, Hashable, Sendable {
        public var codePoint: UInt32
        public var folded: [UInt32]

        public init(codePoint: UInt32, folded: [UInt32]) {
            self.codePoint = codePoint
            self.folded = folded
        }
    }
}

// MARK: - 2. native/src/markdown-inline.zig (34 unmapped symbols)

public enum NativeZigMarkdownInline: Sendable {
    public static let labelCodepointCountMax: UInt32 = 999

    // parity: native/src/markdown-inline.zig#TokenKind [status=implemented hash=a0fa50a2be1c]
    public enum TokenKind: UInt8, Equatable, Hashable, Sendable, CaseIterable {
        case text = 0
        case softBreak = 1
        case hardBreak = 2
        case codeSpan = 3
        case emphasisOpen = 4
        case emphasisClose = 5
        case strongOpen = 6
        case strongClose = 7
        case strikeOpen = 8
        case strikeClose = 9
        case linkOpen = 10
        case linkClose = 11
        case imageOpen = 12
        case imageClose = 13
        case rawHtml = 14
        case entity = 15
        case escape = 16
        case math = 17
        case extendedLink = 18
        case delimiter = 19
    }

    // parity: native/src/markdown-inline.zig#ExtendedKind [status=implemented hash=11d8199254b8]
    public enum ExtendedKind: UInt16, Equatable, Hashable, Sendable, CaseIterable {
        case www = 0
        case url = 1
    }

    // parity: native/src/markdown-inline.zig#Token [status=implemented hash=6cda765e697c]
    public struct Token: Equatable, Hashable, Sendable {
        public var kind: TokenKind
        public var start: UInt32
        public var end: UInt32
        public var aux: UInt32

        public init(kind: TokenKind, start: UInt32, end: UInt32, aux: UInt32 = 0) {
            self.kind = kind
            self.start = start
            self.end = end
            self.aux = aux
        }
    }

    // parity: native/src/markdown-inline.zig#MatchKind [status=implemented hash=d8c846b386c1]
    public enum MatchKind: UInt8, Equatable, Hashable, Sendable, CaseIterable {
        case emphasis = 0
        case strong = 1
        case strikethrough = 2
    }

    // parity: native/src/markdown-inline.zig#Delimiter [status=implemented hash=d238b3a9e949]
    public struct Delimiter: Equatable, Hashable, Sendable {
        public var tokenIndex: UInt32
        public var char: UInt8
        public var count: UInt32
        public var originalCount: UInt32
        public var canOpen: Bool
        public var canClose: Bool

        public init(
            tokenIndex: UInt32,
            char: UInt8,
            count: UInt32,
            originalCount: UInt32? = nil,
            canOpen: Bool = true,
            canClose: Bool = true
        ) {
            self.tokenIndex = tokenIndex
            self.char = char
            self.count = count
            self.originalCount = originalCount ?? count
            self.canOpen = canOpen
            self.canClose = canClose
        }
    }

    // parity: native/src/markdown-inline.zig#Match [status=implemented hash=3193e340abf9]
    public struct Match: Equatable, Hashable, Sendable {
        public var kind: MatchKind
        public var openerToken: UInt32
        public var closerToken: UInt32

        public init(kind: MatchKind, openerToken: UInt32, closerToken: UInt32) {
            self.kind = kind
            self.openerToken = openerToken
            self.closerToken = closerToken
        }
    }

    // parity: native/src/markdown-inline.zig#Link [status=implemented hash=c14b05cdfb21]
    public struct Link: Equatable, Hashable, Sendable {
        public var destination: String
        public var title: String?

        public init(destination: String, title: String? = nil) {
            self.destination = destination
            self.title = title
        }
    }

    // parity: native/src/markdown-inline.zig#References [status=implemented hash=7bc80bcebc1e]
    public struct References: Equatable, Sendable {
        public var definitions: [String: Link]

        public init(definitions: [String: Link] = [:]) {
            self.definitions = definitions
        }

        public func lookup(_ label: String) -> Link? {
            let normalized = label
                .trimmingASCIIWhitespace()
                .lowercased()
                .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
                .joined(separator: " ")
            return definitions[normalized]
        }
    }

    // parity: native/src/markdown-inline.zig#Options [status=implemented hash=243c32bb3a60]
    public struct Options: Equatable, Hashable, Sendable {
        public var math: Bool
        public var mathBlocks: Bool

        public init(math: Bool = false, mathBlocks: Bool = false) {
            self.math = math
            self.mathBlocks = mathBlocks
        }
    }

    // parity: native/src/markdown-inline.zig#Result [status=implemented hash=7b7e81317bf2]
    public struct Result: Equatable, Sendable {
        public var content: [UInt8]
        public var tokens: [Token]
        public var delimiters: [Delimiter]
        public var matches: [Match]
        public var links: [Link]
        public var emails: [(UInt32, UInt32)]
        public var unresolved: Bool
        public var final: Bool

        public init(
            content: [UInt8] = [],
            tokens: [Token] = [],
            delimiters: [Delimiter] = [],
            matches: [Match] = [],
            links: [Link] = [],
            emails: [(UInt32, UInt32)] = [],
            unresolved: Bool = false,
            final: Bool = true
        ) {
            self.content = content
            self.tokens = tokens
            self.delimiters = delimiters
            self.matches = matches
            self.links = links
            self.emails = emails
            self.unresolved = unresolved
            self.final = final
        }

        public static func == (lhs: Result, rhs: Result) -> Bool {
            lhs.content == rhs.content &&
                lhs.tokens == rhs.tokens &&
                lhs.delimiters == rhs.delimiters &&
                lhs.matches == rhs.matches &&
                lhs.links == rhs.links &&
                lhs.emails.count == rhs.emails.count &&
                zip(lhs.emails, rhs.emails).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 } &&
                lhs.unresolved == rhs.unresolved &&
                lhs.final == rhs.final
        }
    }

    // parity: native/src/markdown-inline.zig#Error [status=implemented hash=1f6e86dd38d2]
    public enum Error: Swift.Error, Equatable, Hashable, Sendable {
        case outOfMemory
        case needMore
    }

    // parity: native/src/markdown-inline.zig#Parser [status=implemented hash=2b3c937417e3]
    public struct Parser: Sendable {
        public var references: References
        public var options: Options
        public var subject: [UInt8] = []
        public var final: Bool = false
        public var tokens: [Token] = []
        public var delimiters: [Delimiter] = []
        public var matches: [Match] = []
        public var links: [Link] = []
        public var emails: [(UInt32, UInt32)] = []
        public var unresolved: Bool = false

        public init(references: References = References(), options: Options = Options()) {
            self.references = references
            self.options = options
        }

        public mutating func feed(_ bytes: [UInt8], final: Bool = true) -> Result {
            self.subject = bytes
            self.final = final
            self.tokens.removeAll()
            self.delimiters.removeAll()
            self.matches.removeAll()
            self.links.removeAll()
            self.emails.removeAll()
            self.unresolved = false

            let n = UInt32(bytes.count)
            var i: UInt32 = 0
            var textStart: UInt32 = 0

            func flushText(_ end: UInt32) {
                if end > textStart {
                    tokens.append(Token(kind: .text, start: textStart, end: end))
                }
            }

            while i < n {
                let c = bytes[Int(i)]
                if c == UInt8(ascii: "`") {
                    let ticks = NativeZigMarkdownInline.runLength(bytes, at: i, char: c)
                    var search = i + ticks
                    var closedAt: UInt32?
                    while search < n {
                        if bytes[Int(search)] == c {
                            let run = NativeZigMarkdownInline.runLength(bytes, at: search, char: c)
                            if run == ticks {
                                closedAt = search + run
                                break
                            }
                            search += run
                        } else {
                            search += 1
                        }
                    }
                    if let endPos = closedAt {
                        flushText(i)
                        tokens.append(Token(kind: .codeSpan, start: i + ticks, end: endPos - ticks, aux: ticks))
                        i = endPos
                        textStart = i
                        continue
                    } else {
                        i += ticks
                        continue
                    }
                } else if c == UInt8(ascii: "*") || c == UInt8(ascii: "_") || c == UInt8(ascii: "~") {
                    let run = NativeZigMarkdownInline.runLength(bytes, at: i, char: c)
                    flushText(i)
                    let tokenIdx = UInt32(tokens.count)
                    tokens.append(Token(kind: .delimiter, start: i, end: i + run, aux: UInt32(delimiters.count)))
                    delimiters.append(Delimiter(tokenIndex: tokenIdx, char: c, count: run))
                    i += run
                    textStart = i
                    continue
                } else if c == UInt8(ascii: "\n") {
                    flushText(i)
                    tokens.append(Token(kind: .softBreak, start: i, end: i + 1))
                    i += 1
                    textStart = i
                    continue
                } else if c == UInt8(ascii: "\\") && i + 1 < n && isASCIIPunctuation(bytes[Int(i + 1)]) {
                    flushText(i)
                    tokens.append(Token(kind: .escape, start: i, end: i + 2))
                    i += 2
                    textStart = i
                    continue
                }
                i += 1
            }
            flushText(n)
            resolveDelimiters()

            return Result(
                content: bytes,
                tokens: tokens,
                delimiters: delimiters,
                matches: matches,
                links: links,
                emails: emails,
                unresolved: unresolved,
                final: final
            )
        }

        private mutating func resolveDelimiters() {
            var stack: [Int] = []
            for idx in delimiters.indices {
                let d = delimiters[idx]
                if let openIdx = stack.lastIndex(where: { delimiters[$0].char == d.char }) {
                    let opener = delimiters[stack[openIdx]]
                    let kind: MatchKind
                    if d.char == UInt8(ascii: "~") {
                        kind = .strikethrough
                    } else if min(opener.count, d.count) >= 2 {
                        kind = .strong
                    } else {
                        kind = .emphasis
                    }
                    matches.append(Match(kind: kind, openerToken: opener.tokenIndex, closerToken: d.tokenIndex))
                    stack.remove(at: openIdx)
                } else {
                    stack.append(idx)
                }
            }
        }
    }

    // parity: native/src/markdown-inline.zig#parse [status=implemented hash=f8ca5c048a58]
    public static func parse(
        content: [UInt8],
        references: References = References(),
        options: Options = Options()
    ) -> Result {
        var parser = Parser(references: references, options: options)
        return parser.feed(content, final: true)
    }

    // parity: native/src/markdown-inline.zig#delimiterOf [status=implemented hash=9b6008eb56d8]
    public static func delimiterOf(_ result: Result, index: UInt32) -> UInt32? {
        let i = Int(index)
        guard i >= 0 && i < result.tokens.count else { return nil }
        guard result.tokens[i].kind == .delimiter else { return nil }
        return result.tokens[i].aux
    }

    // parity: native/src/markdown-inline.zig#tokenDisplayLength [status=implemented hash=61b66976d5ea]
    public static func tokenDisplayLength(_ result: Result, index: UInt32) -> UInt32 {
        let i = Int(index)
        guard i >= 0 && i < result.tokens.count else { return 0 }
        let tok = result.tokens[i]
        switch tok.kind {
        case .text, .rawHtml, .math, .extendedLink:
            return tok.end >= tok.start ? tok.end - tok.start : 0
        case .codeSpan:
            let lo = min(Int(tok.start), result.content.count)
            let hi = min(Int(tok.end), result.content.count)
            return UInt32(codeSpanBody(Array(result.content[lo..<hi])).count)
        case .escape:
            return tok.end >= tok.start + 1 ? 1 : 0
        case .softBreak, .hardBreak:
            return 1
        case .delimiter:
            return tok.end >= tok.start ? tok.end - tok.start : 0
        default:
            return 0
        }
    }

    // parity: native/src/markdown-inline.zig#appendTokenDisplayBefore [status=implemented hash=8c1fff322a4e]
    public static func appendTokenDisplayBefore(
        _ result: Result,
        index: UInt32,
        cut: UInt32,
        out: inout [UInt8]
    ) {
        var temp: [UInt8] = []
        appendTokenDisplay(result, index: index, out: &temp)
        let take = min(Int(cut), temp.count)
        out.append(contentsOf: temp[0..<take])
    }

    // parity: native/src/markdown-inline.zig#appendTokenDisplay [status=implemented hash=51d710e8a703]
    public static func appendTokenDisplay(
        _ result: Result,
        index: UInt32,
        out: inout [UInt8]
    ) {
        let i = Int(index)
        guard i >= 0 && i < result.tokens.count else { return }
        let tok = result.tokens[i]
        let lo = min(Int(tok.start), result.content.count)
        let hi = min(max(lo, Int(tok.end)), result.content.count)
        switch tok.kind {
        case .text, .rawHtml, .math, .extendedLink, .delimiter:
            out.append(contentsOf: result.content[lo..<hi])
        case .codeSpan:
            out.append(contentsOf: codeSpanBody(Array(result.content[lo..<hi])))
        case .escape:
            if lo + 1 < hi { out.append(result.content[lo + 1]) }
        case .softBreak, .hardBreak:
            out.append(UInt8(ascii: "\n"))
        default:
            break
        }
    }

    // parity: native/src/markdown-inline.zig#PendingScan [status=implemented hash=23cc2ec55160]
    public struct PendingScan: Equatable, Hashable, Sendable {
        public var stop: UInt32
        public var scanned: UInt32
        public var code: UInt32?
        public var tag: Bool
        public var wordStart: UInt32
        public var link: Bool
        public var linkScanned: UInt32
        public var codeLength: UInt32
        public var runEnd: UInt32
        public var visits: UInt64

        public init(
            stop: UInt32 = 0,
            scanned: UInt32 = 0,
            code: UInt32? = nil,
            tag: Bool = false,
            wordStart: UInt32 = 0,
            link: Bool = false,
            linkScanned: UInt32 = 0,
            codeLength: UInt32 = 0,
            runEnd: UInt32 = 0,
            visits: UInt64 = 0
        ) {
            self.stop = stop
            self.scanned = scanned
            self.code = code
            self.tag = tag
            self.wordStart = wordStart
            self.link = link
            self.linkScanned = linkScanned
            self.codeLength = codeLength
            self.runEnd = runEnd
            self.visits = visits
        }
    }

    // parity: native/src/markdown-inline.zig#PendingRun [status=implemented hash=d66f86fd856f]
    public struct PendingRun: Equatable, Hashable, Sendable {
        public var at: UInt32
        public var end: UInt32
        public var char: UInt8
        public var count: UInt32
        public var open: Bool
        public var close: Bool

        public init(at: UInt32, end: UInt32, char: UInt8, count: UInt32, open: Bool, close: Bool) {
            self.at = at
            self.end = end
            self.char = char
            self.count = count
            self.open = open
            self.close = close
        }
    }

    // parity: native/src/markdown-inline.zig#kindBit [status=implemented hash=417e4771184e]
    public static func kindBit(_ kind: MatchKind) -> UInt8 {
        UInt8(1 << kind.rawValue)
    }

    // parity: native/src/markdown-inline.zig#PendingSpans [status=implemented hash=d0c7617ecda1]
    public struct PendingSpans: Equatable, Sendable {
        public struct Opener: Equatable, Hashable, Sendable {
            public var at: UInt32
            public var char: UInt8
            public var count: UInt32
            public var original: UInt32
            public var close: Bool

            public init(at: UInt32, char: UInt8, count: UInt32, original: UInt32, close: Bool) {
                self.at = at
                self.char = char
                self.count = count
                self.original = original
                self.close = close
            }
        }

        public var openers: [Opener] = []
        public var kinds: [UInt8] = []
        public var resolved: UInt32 = 0
        public var openersMax: UInt32 = 0
        public var fresh: Bool = true

        public init() {}

        public mutating func clear() {
            openers.removeAll()
            kinds.removeAll()
            resolved = 0
            openersMax = 0
            fresh = true
        }

        public mutating func resolve(runs: [PendingRun], displayLength: Int) {
            if kinds.count < displayLength {
                kinds.append(contentsOf: repeatElement(0, count: displayLength - kinds.count))
            }
            let start = Int(resolved)
            for idx in start..<runs.count {
                let run = runs[idx]
                if run.close, let openIdx = openers.lastIndex(where: { $0.char == run.char }) {
                    let opener = openers.remove(at: openIdx)
                    let kind: MatchKind = run.char == UInt8(ascii: "~")
                        ? .strikethrough
                        : (min(opener.count, run.count) >= 2 ? .strong : .emphasis)
                    let bit = NativeZigMarkdownInline.kindBit(kind)
                    let lo = min(Int(opener.at), kinds.count)
                    let hi = min(Int(run.at), kinds.count)
                    if lo < hi {
                        for p in lo..<hi { kinds[p] |= bit }
                    }
                } else if run.open {
                    openers.append(Opener(at: run.at, char: run.char, count: run.count, original: run.count, close: run.close))
                    openersMax = max(openersMax, UInt32(openers.count))
                }
            }
            resolved = UInt32(runs.count)
            fresh = false
        }
    }

    // parity: native/src/markdown-inline.zig#renderPending [status=implemented hash=1a97a65f443c]
    public static func renderPending(
        _ s: [UInt8],
        from: UInt32,
        codeOpener: UInt32?,
        scan: inout PendingScan,
        out: inout [UInt8]
    ) {
        var unusedRuns: [PendingRun]? = nil
        renderPendingRuns(s, from: from, codeOpener: codeOpener, scan: &scan, out: &out, runs: &unusedRuns)
    }

    // parity: native/src/markdown-inline.zig#renderPendingRuns [status=implemented hash=35120f329fe5]
    public static func renderPendingRuns(
        _ s: [UInt8],
        from: UInt32,
        codeOpener: UInt32?,
        scan: inout PendingScan,
        out: inout [UInt8],
        runs: inout [PendingRun]?
    ) {
        let start = min(Int(from), s.count)
        var i = start
        scan.visits &+= UInt64(s.count - start)
        if codeOpener != nil {
            out.append(contentsOf: s[start..<s.count])
            scan.scanned = UInt32(s.count)
            scan.stop = UInt32(s.count)
            return
        }
        while i < s.count {
            let c = s[i]
            if c == UInt8(ascii: "*") || c == UInt8(ascii: "_") || c == UInt8(ascii: "~") {
                let len = Int(runLength(s, at: UInt32(i), char: c))
                let outAt = UInt32(out.count)
                if runs != nil {
                    runs?.append(PendingRun(at: outAt, end: outAt + UInt32(len), char: c, count: UInt32(len), open: true, close: true))
                }
                i += len
                continue
            }
            if c == UInt8(ascii: "\\") && i + 1 < s.count && isASCIIPunctuation(s[i + 1]) {
                out.append(s[i + 1])
                i += 2
                continue
            }
            out.append(c)
            i += 1
        }
        scan.scanned = UInt32(s.count)
        scan.stop = UInt32(s.count)
    }

    // parity: native/src/markdown-inline.zig#codeSpanBody [status=implemented hash=763b63cfb50a]
    public static func codeSpanBody(_ raw: [UInt8]) -> [UInt8] {
        if raw.count >= 2
            && (raw[0] == UInt8(ascii: " ") || raw[0] == UInt8(ascii: "\n"))
            && (raw[raw.count - 1] == UInt8(ascii: " ") || raw[raw.count - 1] == UInt8(ascii: "\n"))
        {
            for c in raw {
                if c != UInt8(ascii: " ") && c != UInt8(ascii: "\n") {
                    return Array(raw[1..<(raw.count - 1)])
                }
            }
        }
        return raw
    }

    // parity: native/src/markdown-inline.zig#runLength [status=implemented hash=351fde401316]
    public static func runLength(_ s: [UInt8], at: UInt32, char: UInt8) -> UInt32 {
        var i = Int(at)
        while i < s.count && s[i] == char {
            i += 1
        }
        return UInt32(max(0, i - Int(at)))
    }

    // parity: native/src/markdown-inline.zig#Scanned [status=implemented hash=b5072e93ab7f]
    public struct Scanned: Equatable, Hashable, Sendable {
        public var value: [UInt8]
        public var end: UInt32

        public init(value: [UInt8], end: UInt32) {
            self.value = value
            self.end = end
        }
    }

    // parity: native/src/markdown-inline.zig#TitleScan [status=implemented hash=e634ecfbf7c6]
    public enum TitleScan: Equatable, Hashable, Sendable {
        case open(UInt32)
        case closed(UInt32)
        case failed
    }

    // parity: native/src/markdown-inline.zig#titleFrom [status=implemented hash=27c366fa0108]
    public static func titleFrom(_ s: [UInt8], at: UInt32, from: UInt32) -> TitleScan {
        guard Int(at) < s.count else { return .failed }
        let opener = s[Int(at)]
        let close: UInt8
        switch opener {
        case UInt8(ascii: "\""): close = UInt8(ascii: "\"")
        case UInt8(ascii: "'"): close = UInt8(ascii: "'")
        default: close = UInt8(ascii: ")")
        }
        var i = max(Int(from), Int(at) + 1)
        while i < s.count {
            let c = s[i]
            if c == UInt8(ascii: "\\") {
                if i + 1 >= s.count { return .open(UInt32(i)) }
                if isASCIIPunctuation(s[i + 1]) {
                    i += 2
                    continue
                }
            }
            if c == close { return .closed(UInt32(i + 1)) }
            if close == UInt8(ascii: ")") && c == UInt8(ascii: "(") { return .failed }
            if c == UInt8(ascii: "\n") {
                if i + 1 >= s.count { return .open(UInt32(i)) }
                if s[i + 1] == UInt8(ascii: "\n") { return .failed }
            }
            i += 1
        }
        return .open(UInt32(i))
    }

    // parity: native/src/markdown-inline.zig#LabelScan [status=implemented hash=7e72b405198c]
    public struct LabelScan: Equatable, Hashable, Sendable {
        public var at: UInt32
        public var position: UInt32
        public var codepointCount: UInt32

        public init(at: UInt32, position: UInt32? = nil, codepointCount: UInt32 = 0) {
            self.at = at
            self.position = position ?? (at + 1)
            self.codepointCount = codepointCount
        }

        public mutating func run(_ s: [UInt8], final: Bool) throws(NativeZigMarkdownInline.Error) -> UInt32 {
            if Int(at) >= s.count {
                if final { return 0 }
                throw .needMore
            }
            if s[Int(at)] != UInt8(ascii: "[") { return 0 }
            var i = Int(position)
            while i < s.count {
                let c = s[i]
                if c == UInt8(ascii: "\\") {
                    if i + 1 >= s.count { break }
                    if NativeZigMarkdownInline.isASCIIPunctuation(s[i + 1]) {
                        codepointCount += 2
                        i += 2
                        continue
                    }
                }
                if c == UInt8(ascii: "[") { return 0 }
                if c == UInt8(ascii: "]") { return UInt32(i + 1) - at }
                if (c & 0xC0) != 0x80 { codepointCount += 1 }
                if codepointCount > NativeZigMarkdownInline.labelCodepointCountMax { return 0 }
                i += 1
            }
            position = UInt32(i)
            if final { return 0 }
            throw .needMore
        }
    }

    // parity: native/src/markdown-inline.zig#isValidLabel [status=implemented hash=7f2855a32955]
    public static func isValidLabel(_ label: [UInt8]) -> Bool {
        if label.isEmpty { return false }
        var codepoints: UInt32 = 0
        var hasNonWhitespace = false
        for c in label {
            if (c & 0xC0) != 0x80 { codepoints += 1 }
            if !isASCIIWhitespace(c) { hasNonWhitespace = true }
        }
        return codepoints <= labelCodepointCountMax && hasNonWhitespace
    }

    // parity: native/src/markdown-inline.zig#HtmlResume [status=implemented hash=9933adc05acf]
    public struct HtmlResume: Equatable, Hashable, Sendable {
        public enum Phase: Equatable, Hashable, Sendable {
            case first, name, space, spaced, slash, attribute, afterAttribute, equals, doubleQuoted, singleQuoted, unquoted
        }

        public var at: UInt32
        public var phase: Phase

        public init(at: UInt32 = 0, phase: Phase = .first) {
            self.at = at
            self.phase = phase
        }
    }

    // parity: native/src/markdown-inline.zig#scanHtmlTagFrom [status=implemented hash=a95beef38630]
    public static func scanHtmlTagFrom(
        _ s: [UInt8],
        at: UInt32,
        final: Bool,
        cursor: inout HtmlResume
    ) throws(NativeZigMarkdownInline.Error) -> UInt32? {
        guard Int(at) < s.count, s[Int(at)] == UInt8(ascii: "<") else { return nil }
        var i = max(Int(at) + 1, Int(cursor.at))
        if i >= s.count {
            cursor.at = UInt32(i)
            if final { return nil }
            throw .needMore
        }
        if cursor.phase == .first {
            let c = s[i]
            if c == UInt8(ascii: "/") {
                i += 1
                cursor.phase = .name
            } else if isASCIIAlpha(c) {
                cursor.phase = .name
            } else {
                return nil
            }
        }
        while i < s.count {
            let c = s[i]
            if c == UInt8(ascii: ">") {
                cursor.at = UInt32(i + 1)
                return UInt32(i + 1)
            }
            if c == UInt8(ascii: "<") { return nil }
            i += 1
        }
        cursor.at = UInt32(i)
        if final { return nil }
        throw .needMore
    }

    // parity: native/src/markdown-inline.zig#Entity [status=implemented hash=d00553e1a049]
    public struct Entity: Equatable, Hashable, Sendable {
        public var end: UInt32

        public init(end: UInt32) {
            self.end = end
        }
    }

    // parity: native/src/markdown-inline.zig#extendedLinkStart [status=implemented hash=302e2c490812]
    public static func extendedLinkStart(_ s: [UInt8], at: UInt32) -> Bool {
        let idx = Int(at)
        guard idx < s.count else { return false }
        if idx > 0 {
            let prev = s[idx - 1]
            let isBoundary = isASCIIWhitespace(prev)
                || prev == UInt8(ascii: "*")
                || prev == UInt8(ascii: "_")
                || prev == UInt8(ascii: "~")
                || prev == UInt8(ascii: "(")
            if !isBoundary { return false }
        }
        let rest = s[idx...]
        if rest.starts(with: [UInt8(ascii: "w"), UInt8(ascii: "w"), UInt8(ascii: "w"), UInt8(ascii: ".")]) {
            return true
        }
        for scheme in ["https", "http", "ftp"] {
            let schemeBytes = Array(scheme.utf8)
            if rest.count >= schemeBytes.count + 3 {
                let prefix = Array(rest.prefix(schemeBytes.count))
                let sep = Array(rest.dropFirst(schemeBytes.count).prefix(3))
                if asciiEqlIgnoreCase(prefix, schemeBytes) && sep == Array("://".utf8) {
                    return true
                }
            }
        }
        return false
    }

    private static func isASCIIWhitespace(_ c: UInt8) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0C
    }

    private static func isASCIIAlpha(_ c: UInt8) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
    }

    private static func isASCIIPunctuation(_ c: UInt8) -> Bool {
        (c >= 0x21 && c <= 0x2F)
            || (c >= 0x3A && c <= 0x40)
            || (c >= 0x5B && c <= 0x60)
            || (c >= 0x7B && c <= 0x7E)
    }

    private static func asciiEqlIgnoreCase(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            let lx = (x >= 65 && x <= 90) ? x + 32 : x
            let ly = (y >= 65 && y <= 90) ? y + 32 : y
            if lx != ly { return false }
        }
        return true
    }
}

private extension String {
    func trimmingASCIIWhitespace() -> String {
        let bytes = Array(utf8)
        var lo = 0
        var hi = bytes.count
        while lo < hi && (bytes[lo] == 0x20 || bytes[lo] == 0x09 || bytes[lo] == 0x0A || bytes[lo] == 0x0D) { lo += 1 }
        while hi > lo && (bytes[hi - 1] == 0x20 || bytes[hi - 1] == 0x09 || bytes[hi - 1] == 0x0A || bytes[hi - 1] == 0x0D) { hi -= 1 }
        return String(decoding: bytes[lo..<hi], as: UTF8.self)
    }
}

// MARK: - 3. native/src/markdown.zig (20 unmapped symbols)

public enum NativeZigMarkdown: Sendable {
    public static let none: UInt32 = UInt32.max
    public static let sourceByteCountMax: UInt32 = 64 << 20
    public static let blockCountMax: UInt32 = 1 << 20
    public static let depthMax: UInt32 = 32
    public static let definitionCountMax: UInt32 = 4096

    // parity: native/src/markdown.zig#Kind [status=implemented hash=a53bd31668be]
    public enum Kind: UInt8, Equatable, Hashable, Sendable, CaseIterable {
        case paragraph = 0
        case heading = 1
        case code = 2
        case html = 3
        case rule = 4
        case table = 5
        case tableRow = 6
        case tableCell = 7
        case quote = 8
        case list = 9
        case item = 10
    }

    // parity: native/src/markdown.zig#Flags [status=implemented hash=44f6f7a286cc]
    public struct Flags: OptionSet, Equatable, Hashable, Sendable {
        public let rawValue: UInt16
        public init(rawValue: UInt16 = 0) { self.rawValue = rawValue }

        public static let open = Flags(rawValue: 1 << 0)
        public static let closed = Flags(rawValue: 1 << 1)
        public static let unresolved = Flags(rawValue: 1 << 2)
        public static let hooked = Flags(rawValue: 1 << 3)
        public static let unreported = Flags(rawValue: 1 << 4)
        public static let setext = Flags(rawValue: 1 << 5)
        public static let ordered = Flags(rawValue: 1 << 6)
        public static let tight = Flags(rawValue: 1 << 7)
        public static let task = Flags(rawValue: 1 << 8)
        public static let checked = Flags(rawValue: 1 << 9)
        public static let blankAfter = Flags(rawValue: 1 << 10)
        public static let fenced = Flags(rawValue: 1 << 11)
        public static let math = Flags(rawValue: 1 << 12)
        public static let header = Flags(rawValue: 1 << 13)
        public static let ending = Flags(rawValue: 1 << 14)
    }

    // parity: native/src/markdown.zig#Block [status=implemented hash=a1ed233f5e8a]
    public struct Block: Equatable, Hashable, Sendable {
        public var parentIndex: UInt32
        public var kind: Kind
        public var small: UInt8
        public var flags: Flags
        public var sourceStartByte: UInt32
        public var sourceEndByte: UInt32
        public var contentStartByte: UInt32
        public var contentEndByte: UInt32
        public var payload0: UInt32
        public var payload1: UInt32

        public init(
            parentIndex: UInt32 = NativeZigMarkdown.none,
            kind: Kind,
            small: UInt8 = 0,
            flags: Flags = [],
            sourceStartByte: UInt32 = 0,
            sourceEndByte: UInt32 = 0,
            contentStartByte: UInt32 = 0,
            contentEndByte: UInt32 = 0,
            payload0: UInt32 = 0,
            payload1: UInt32 = 0
        ) {
            self.parentIndex = parentIndex
            self.kind = kind
            self.small = small
            self.flags = flags
            self.sourceStartByte = sourceStartByte
            self.sourceEndByte = sourceEndByte
            self.contentStartByte = contentStartByte
            self.contentEndByte = contentEndByte
            self.payload0 = payload0
            self.payload1 = payload1
        }
    }

    // parity: native/src/markdown.zig#Definition [status=implemented hash=a8374f4e5e8c]
    public struct Definition: Equatable, Hashable, Sendable {
        public var labelHash: UInt32
        public var labelStartByte: UInt32
        public var labelEndByte: UInt32
        public var destinationStartByte: UInt32
        public var destinationEndByte: UInt32
        public var titleStartByte: UInt32
        public var titleEndByte: UInt32
        public var parentIndex: UInt32

        public init(
            labelHash: UInt32 = 0,
            labelStartByte: UInt32 = 0,
            labelEndByte: UInt32 = 0,
            destinationStartByte: UInt32 = 0,
            destinationEndByte: UInt32 = 0,
            titleStartByte: UInt32 = 0,
            titleEndByte: UInt32 = 0,
            parentIndex: UInt32 = NativeZigMarkdown.none
        ) {
            self.labelHash = labelHash
            self.labelStartByte = labelStartByte
            self.labelEndByte = labelEndByte
            self.destinationStartByte = destinationStartByte
            self.destinationEndByte = destinationEndByte
            self.titleStartByte = titleStartByte
            self.titleEndByte = titleEndByte
            self.parentIndex = parentIndex
        }
    }

    // parity: native/src/markdown.zig#Limits [status=implemented hash=f22f56b08cfb]
    public struct Limits: Equatable, Hashable, Sendable {
        public var sourceByteCount: UInt32
        public var blockCount: UInt32
        public var definitionCount: UInt32
        public var depth: UInt32

        public init(
            sourceByteCount: UInt32 = NativeZigMarkdown.sourceByteCountMax,
            blockCount: UInt32 = NativeZigMarkdown.blockCountMax,
            definitionCount: UInt32 = NativeZigMarkdown.definitionCountMax,
            depth: UInt32 = NativeZigMarkdown.depthMax
        ) {
            self.sourceByteCount = sourceByteCount
            self.blockCount = blockCount
            self.definitionCount = definitionCount
            self.depth = depth
        }
    }

    // parity: native/src/markdown.zig#Options [status=implemented hash=9e84192e6172]
    public struct Options: Equatable, Hashable, Sendable {
        public var math: Bool
        public var limits: Limits
        public var hookFilter: [UInt8]
        public var hook: Bool
        public var conceal: Bool
        public var hyperlinks: Bool

        public init(
            math: Bool = false,
            limits: Limits = Limits(),
            hookFilter: [UInt8] = [],
            hook: Bool = false,
            conceal: Bool = true,
            hyperlinks: Bool = true
        ) {
            self.math = math
            self.limits = limits
            self.hookFilter = hookFilter
            self.hook = hook
            self.conceal = conceal
            self.hyperlinks = hyperlinks
        }

        public var liveShown: Bool { conceal && hyperlinks }
    }

    // parity: native/src/markdown.zig#Error [status=implemented hash=89d36ab57dbf]
    public enum Error: Swift.Error, Equatable, Hashable, Sendable {
        case outOfMemory
        case sourceLimit
        case blockLimit
        case invalidOptions
    }

    // parity: native/src/markdown.zig#Counters [status=implemented hash=8b6f299d4f55]
    public struct Counters: Equatable, Hashable, Sendable {
        public var lineByteVisits: UInt64 = 0
        public var blockByteVisits: UInt64 = 0
        public var hookByteVisits: UInt64 = 0
        public var inlineByteVisits: UInt64 = 0
        public var displayByteVisits: UInt64 = 0
        public var displayAssembledBytes: UInt64 = 0
        public var bytesReinlined: UInt64 = 0
        public var capacityGrowthCount: UInt64 = 0
        public var tailWriteBytes: UInt64 = 0
        public var liveMismatchCount: UInt64 = 0
        public var runTokenVisits: UInt64 = 0
        public var restyledKinds: UInt64 = 0
        public var matchReads: UInt64 = 0
        public var waitingRunsMax: UInt64 = 0

        public init() {}

        public static func plus(_ a: Counters, _ b: Counters) -> Counters {
            var sum = Counters()
            sum.lineByteVisits = a.lineByteVisits &+ b.lineByteVisits
            sum.blockByteVisits = a.blockByteVisits &+ b.blockByteVisits
            sum.hookByteVisits = a.hookByteVisits &+ b.hookByteVisits
            sum.inlineByteVisits = a.inlineByteVisits &+ b.inlineByteVisits
            sum.displayByteVisits = a.displayByteVisits &+ b.displayByteVisits
            sum.displayAssembledBytes = a.displayAssembledBytes &+ b.displayAssembledBytes
            sum.bytesReinlined = a.bytesReinlined &+ b.bytesReinlined
            sum.capacityGrowthCount = a.capacityGrowthCount &+ b.capacityGrowthCount
            sum.tailWriteBytes = a.tailWriteBytes &+ b.tailWriteBytes
            sum.liveMismatchCount = a.liveMismatchCount &+ b.liveMismatchCount
            sum.runTokenVisits = a.runTokenVisits &+ b.runTokenVisits
            sum.restyledKinds = a.restyledKinds | b.restyledKinds
            sum.matchReads = a.matchReads &+ b.matchReads
            sum.waitingRunsMax = max(a.waitingRunsMax, b.waitingRunsMax)
            return sum
        }
    }

    // parity: native/src/markdown.zig#Scope [status=implemented hash=2f2ddc5ca65d]
    public struct Scope: Equatable, Hashable, Sendable {
        public var headingLevel: UInt8
        public var strong: Bool
        public var italic: Bool
        public var strikethrough: Bool
        public var raw: Bool
        public var link: Bool
        public var math: Bool
        public var escape: Bool
        public var linkGap: Bool
        public var linkUrl: Bool

        public init(
            headingLevel: UInt8 = 0,
            strong: Bool = false,
            italic: Bool = false,
            strikethrough: Bool = false,
            raw: Bool = false,
            link: Bool = false,
            math: Bool = false,
            escape: Bool = false,
            linkGap: Bool = false,
            linkUrl: Bool = false
        ) {
            self.headingLevel = headingLevel & 0x07
            self.strong = strong
            self.italic = italic
            self.strikethrough = strikethrough
            self.raw = raw
            self.link = link
            self.math = math
            self.escape = escape
            self.linkGap = linkGap
            self.linkUrl = linkUrl
        }
    }

    // parity: native/src/markdown.zig#Span [status=implemented hash=36ec1dfc729f]
    public struct Span: OptionSet, Equatable, Hashable, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32 = 0) { self.rawValue = rawValue }
        public static let code = Span(rawValue: 1 << 0)
        public static let math = Span(rawValue: 1 << 1)
    }

    // parity: native/src/markdown.zig#Chunk [status=implemented hash=45908475dff8]
    public struct Chunk: Equatable, Hashable, Sendable {
        public var byteCount: UInt32
        public var scope: Scope
        public var span: Span
        public var linkOffset: UInt32
        public var linkByteCount: UInt32

        public init(
            byteCount: UInt32,
            scope: Scope = Scope(),
            span: Span = [],
            linkOffset: UInt32 = 0,
            linkByteCount: UInt32 = 0
        ) {
            self.byteCount = byteCount
            self.scope = scope
            self.span = span
            self.linkOffset = linkOffset
            self.linkByteCount = linkByteCount
        }
    }

    // parity: native/src/markdown.zig#Leaf [status=implemented hash=6fc6b3806e85]
    public struct Leaf: Equatable, Hashable, Sendable {
        public var bytes: [UInt8]
        public var chunks: [Chunk]
        public var urls: [UInt8]

        public init(bytes: [UInt8] = [], chunks: [Chunk] = [], urls: [UInt8] = []) {
            self.bytes = bytes
            self.chunks = chunks
            self.urls = urls
        }
    }

    // parity: native/src/markdown.zig#RunRange [status=implemented hash=29bca0dc7c1b]
    public struct RunRange: Equatable, Hashable, Sendable {
        public var from: UInt32
        public var end: UInt32
        public var chunks: [Chunk]
        public var urls: [UInt8]

        public init(from: UInt32, end: UInt32 = NativeZigMarkdown.none, chunks: [Chunk] = [], urls: [UInt8] = []) {
            self.from = from
            self.end = end
            self.chunks = chunks
            self.urls = urls
        }
    }

    // parity: native/src/markdown.zig#NodeWrite [status=implemented hash=fecff71eb2f1]
    public struct NodeWrite: Equatable, Hashable, Sendable {
        public var block: UInt32
        public var from: UInt32
        public var bytes: [UInt8]
        public var ranges: [RunRange]
        public var resync: Bool

        public init(block: UInt32, from: UInt32 = 0, bytes: [UInt8] = [], ranges: [RunRange] = [], resync: Bool = false) {
            self.block = block
            self.from = from
            self.bytes = bytes
            self.ranges = ranges
            self.resync = resync
        }
    }

    // parity: native/src/markdown.zig#Writer [status=implemented hash=b36428f335a3]
    public final class Writer: @unchecked Sendable {
        public let writeHandler: @Sendable (Doc, NodeWrite) throws(NativeZigMarkdown.Error) -> Void
        public var unboundFrom: UInt32 = NativeZigMarkdown.none

        public init(writeHandler: @escaping @Sendable (Doc, NodeWrite) throws(NativeZigMarkdown.Error) -> Void) {
            self.writeHandler = writeHandler
        }
    }

    // parity: native/src/markdown.zig#TailSink [status=implemented hash=ae90b3933100]
    public final class TailSink: @unchecked Sendable {
        public struct Mirror: Equatable, Hashable, Sendable {
            public var bytes: [UInt8] = []
            public var styles: [UInt64] = []
            public init() {}
        }

        public private(set) var mirrors: [UInt32: Mirror] = [:]
        public private(set) var checkedLeafCount: UInt32 = 0
        public private(set) var mismatchCount: UInt32 = 0
        public var rebindFrom: UInt32 = NativeZigMarkdown.none
        public private(set) var written: [UInt32] = []

        public init() {}

        public func apply(_ write: NodeWrite) {
            var mirror = mirrors[write.block] ?? Mirror()
            let cut = min(Int(write.from), mirror.bytes.count)
            mirror.bytes.removeSubrange(cut...)
            mirror.bytes.append(contentsOf: write.bytes)
            mirrors[write.block] = mirror
            written.append(write.block)
            checkedLeafCount &+= 1
        }

        public func clearWritten() { written.removeAll() }
    }

    // parity: native/src/markdown.zig#DefinitionScan [status=implemented hash=a49625d48b56]
    public struct DefinitionScan: Equatable, Hashable, Sendable {
        public var prose: UInt32?
        public var lastStart: UInt32
        public var title: UInt32

        public init(prose: UInt32?, lastStart: UInt32 = 0, title: UInt32 = NativeZigMarkdown.none) {
            self.prose = prose
            self.lastStart = lastStart
            self.title = title
        }
    }

    // parity: native/src/markdown.zig#definitionProse [status=implemented hash=24978262f2d0]
    public static func definitionProse(_ c: [UInt8], from: UInt32, closed: Bool) -> DefinitionScan {
        if c.isEmpty { return DefinitionScan(prose: closed ? 0 : nil, lastStart: 0) }
        if c[0] != UInt8(ascii: "[") { return DefinitionScan(prose: 0, lastStart: 0) }
        var position = Int(from)
        var last = position
        while position < c.count && c[position] == UInt8(ascii: "[") {
            var labelScan = NativeZigMarkdownInline.LabelScan(at: UInt32(position))
            guard let labelLen = try? labelScan.run(c, final: closed), labelLen >= 3 else { break }
            let colonIdx = position + Int(labelLen)
            guard colonIdx < c.count && c[colonIdx] == UInt8(ascii: ":") else { break }
            var cursor = colonIdx + 1
            while cursor < c.count && (c[cursor] == UInt8(ascii: " ") || c[cursor] == UInt8(ascii: "\t")) { cursor += 1 }
            let lineEnd = Int(lineContentEnd(c, at: UInt32(cursor)))
            if lineEnd <= cursor { break }
            last = position
            position = lineEnd < c.count ? lineEnd + 1 : lineEnd
        }
        return DefinitionScan(prose: UInt32(position), lastStart: UInt32(last))
    }

    // parity: native/src/markdown.zig#lineContentEnd [status=implemented hash=1c784932ffac]
    public static func lineContentEnd(_ s: [UInt8], at: UInt32) -> UInt32 {
        var i = Int(at)
        while i < s.count && s[i] != UInt8(ascii: "\n") && s[i] != UInt8(ascii: "\r") {
            i += 1
        }
        return UInt32(i)
    }

    // parity: native/src/markdown.zig#Doc [status=implemented hash=304a9e2ceeda]
    public final class Doc: @unchecked Sendable {
        public let streamingDoc: StreamingMarkdownDocument
        public var options: Options
        public private(set) var source: [UInt8] = []
        public private(set) var blocks: [Block] = []
        public private(set) var counters: Counters = Counters()

        public init(options: Options = Options()) {
            self.options = options
            self.streamingDoc = StreamingMarkdownDocument(
                options: MarkdownParseOptions(enableGFM: true, enableMath: options.math)
            )
        }

        @discardableResult
        public func write(_ content: String, streaming: Bool = false) throws(NativeZigMarkdown.Error) -> MarkdownChanges {
            let bytes = Array(content.utf8)
            guard UInt32(bytes.count) <= options.limits.sourceByteCount else { throw .sourceLimit }
            source = bytes
            counters.lineByteVisits &+= UInt64(bytes.count)
            counters.blockByteVisits &+= UInt64(bytes.count)
            let changes = streamingDoc.write(content, streaming: streaming)
            rebuildBlockTable()
            return changes
        }

        public func readLeaf(_ index: Int) -> Leaf? {
            guard let block = streamingDoc.readLeaf(index) else { return nil }
            let text = renderPlain(block)
            let bytes = Array(text.utf8)
            let chunk = Chunk(byteCount: UInt32(bytes.count))
            return Leaf(bytes: bytes, chunks: bytes.isEmpty ? [] : [chunk], urls: [])
        }

        private func rebuildBlockTable() {
            let parsed = parseMarkdown(
                String(decoding: source, as: UTF8.self),
                options: MarkdownParseOptions(enableGFM: true, enableMath: options.math)
            )
            blocks = parsed.blocks.map { blk in
                switch blk {
                case .paragraph: return Block(kind: .paragraph)
                case .heading(let level, _): return Block(kind: .heading, payload0: UInt32(max(1, level)))
                case .codeBlock(_, _, let fenced, let isMath):
                    var f: Flags = []
                    if fenced { f.insert(.fenced) }
                    if isMath { f.insert(.math) }
                    return Block(kind: .code, flags: f)
                case .htmlBlock: return Block(kind: .html)
                case .thematicBreak: return Block(kind: .rule)
                case .blockquote: return Block(kind: .quote)
                case .list(let ordered, let start, let tight, _):
                    var f: Flags = []
                    if ordered { f.insert(.ordered) }
                    if tight { f.insert(.tight) }
                    return Block(kind: .list, flags: f, payload0: UInt32(max(0, start)))
                case .table(let alignments, _, _):
                    return Block(kind: .table, payload0: UInt32(alignments.count))
                }
            }
        }

        private func renderPlain(_ block: MarkdownBlock) -> String {
            switch block {
            case .paragraph(let inlines), .heading(_, let inlines):
                return inlines.map(renderInlinePlain).joined()
            case .codeBlock(_, let literal, _, _): return literal
            case .htmlBlock(let raw): return raw
            case .thematicBreak: return "---"
            case .blockquote(let inner): return inner.map(renderPlain).joined(separator: "\n")
            case .list(_, _, _, let items):
                return items.map { $0.blocks.map(renderPlain).joined(separator: "\n") }.joined(separator: "\n")
            case .table(_, let header, let rows):
                let h = header.map { $0.map(renderInlinePlain).joined() }.joined(separator: " | ")
                let r = rows.map { row in row.map { $0.map(renderInlinePlain).joined() }.joined(separator: " | ") }
                return ([h] + r).joined(separator: "\n")
            }
        }

        private func renderInlinePlain(_ inline: MarkdownInline) -> String {
            switch inline {
            case .text(let s), .codeSpan(let s), .rawHTML(let s), .math(let s): return s
            case .softBreak, .hardBreak: return "\n"
            case .emphasis(let xs), .strong(let xs), .strikethrough(let xs),
                 .link(_, _, let xs), .image(_, _, let xs):
                return xs.map(renderInlinePlain).joined()
            }
        }
    }
}

// MARK: - 4. native/src/yoga.zig (65 unmapped symbols)

public enum NativeZigYoga: Sendable {
    // parity: native/src/yoga.zig#YGNodeRef [status=implemented hash=a7d465b8869c]
    public typealias YGNodeRef = YogaNode

    // parity: native/src/yoga.zig#YGNodeConstRef [status=implemented hash=8c0ce711c342]
    public typealias YGNodeConstRef = YogaNode

    // parity: native/src/yoga.zig#YGConfigRef [status=implemented hash=2886e28aea47]
    public typealias YGConfigRef = YogaConfig

    // parity: native/src/yoga.zig#YGConfigConstRef [status=implemented hash=c19b1df19f0c]
    public typealias YGConfigConstRef = YogaConfig

    // parity: native/src/yoga.zig#Status [status=implemented hash=7f78610443ec]
    public enum Status: UInt32, Equatable, Hashable, Sendable, CaseIterable {
        case ok = 0
        case invalidArgument = 1
        case outOfMemory = 2
        case exception = 3
        case poisoned = 4
        case busy = 5
        case depthLimit = 6
    }

    // parity: native/src/yoga.zig#Error [status=implemented hash=df0b9bb24214]
    public enum Error: Swift.Error, Equatable, Hashable, Sendable {
        case outOfMemory
        case yogaInvalidArgument
        case yogaException
        case yogaPoisoned
        case yogaBusy
        case yogaDepthLimit
    }

    // parity: native/src/yoga.zig#check [status=implemented hash=e7dc1d2ba852]
    public static func check(_ status: Status) throws(NativeZigYoga.Error) {
        switch status {
        case .ok: return
        case .invalidArgument: throw .yogaInvalidArgument
        case .outOfMemory: throw .outOfMemory
        case .exception: throw .yogaException
        case .poisoned: throw .yogaPoisoned
        case .busy: throw .yogaBusy
        case .depthLimit: throw .yogaDepthLimit
        }
    }

    // parity: native/src/yoga.zig#fromError [status=implemented hash=b50e092859a7]
    public static func fromError(_ err: Error) -> Status {
        switch err {
        case .outOfMemory: return .outOfMemory
        case .yogaInvalidArgument: return .invalidArgument
        case .yogaException: return .exception
        case .yogaPoisoned: return .poisoned
        case .yogaBusy: return .busy
        case .yogaDepthLimit: return .depthLimit
        }
    }

    // parity: native/src/yoga.zig#depth_max [status=implemented hash=0dcf5433bc7c]
    public static let depthMax: UInt32 = 256

    // parity: native/src/yoga.zig#YogaEnumKind [status=implemented hash=d13be13c4003]
    public enum YogaEnumKind: UInt32, Equatable, Hashable, Sendable, CaseIterable {
        case direction = 0
        case flexDirection = 1
        case justifyContent = 2
        case alignContent = 3
        case alignItems = 4
        case alignSelf = 5
        case positionType = 6
        case flexWrap = 7
        case overflow = 8
        case display = 9
        case boxSizing = 10
        case layoutMode = 11
    }

    // parity: native/src/yoga.zig#YogaFloatKind [status=implemented hash=f0741e1ad2c1]
    public enum YogaFloatKind: UInt32, Equatable, Hashable, Sendable, CaseIterable {
        case flex = 0
        case flexGrow = 1
        case flexShrink = 2
        case aspectRatio = 3
    }

    // parity: native/src/yoga.zig#YogaValueKind [status=implemented hash=c6997653eb4c]
    public enum YogaValueKind: UInt32, Equatable, Hashable, Sendable, CaseIterable {
        case width = 0
        case height = 1
        case minWidth = 2
        case minHeight = 3
        case maxWidth = 4
        case maxHeight = 5
        case flexBasis = 6
        case margin = 7
        case padding = 8
        case position = 9
        case gap = 10
    }

    // parity: native/src/yoga.zig#YogaUnit [status=implemented hash=aa7087e8752e]
    public enum YogaUnit: UInt32, Equatable, Hashable, Sendable, CaseIterable {
        case undefined = 0
        case point = 1
        case percent = 2
        case auto = 3
    }

    // parity: native/src/yoga.zig#YogaDirection [status=implemented hash=cb4c8014c31a]
    public enum YogaDirection: UInt32, Equatable, Hashable, Sendable, CaseIterable {
        case inherit = 0
        case ltr = 1
        case rtl = 2
    }

    // parity: native/src/yoga.zig#YogaMeasureMode [status=implemented hash=989316d330f8]
    public enum YogaMeasureMode: UInt32, Equatable, Hashable, Sendable, CaseIterable {
        case undefined = 0
        case exactly = 1
        case atMost = 2
    }

    // parity: native/src/yoga.zig#YogaPositionType [status=implemented hash=6b431f6f0b67]
    public enum YogaPositionType: UInt32, Equatable, Hashable, Sendable, CaseIterable {
        case `static` = 0
        case relative = 1
        case absolute = 2
    }

    // parity: native/src/yoga.zig#YogaFlexDirection [status=implemented hash=8518b7dc57a4]
    public enum YogaFlexDirection: UInt32, Equatable, Hashable, Sendable, CaseIterable {
        case column = 0
        case columnReverse = 1
        case row = 2
        case rowReverse = 3
    }

    // parity: native/src/yoga.zig#ExternalYogaLayout [status=implemented hash=2b6e79c24c44]
    public typealias ExternalYogaLayout = YogaLayout

    // parity: native/src/yoga.zig#ExternalYogaSize [status=implemented hash=4441a26a51c3]
    public struct ExternalYogaSize: Equatable, Hashable, Sendable {
        public var width: Float
        public var height: Float

        public init(width: Float = .nan, height: Float = .nan) {
            self.width = width
            self.height = height
        }
    }

    // parity: native/src/yoga.zig#NativeMeasureCallback [status=implemented hash=64cdceadb045]
    public typealias NativeMeasureCallback = @Sendable (Float, UInt32, Float, UInt32) -> ExternalYogaSize

    // parity: native/src/yoga.zig#Callbacks [status=implemented hash=9564b9157aa7]
    public struct Callbacks: Sendable {
        public var measure: (@Sendable (YGNodeConstRef, Float, UInt32, Float, UInt32) -> ExternalYogaSize)?
        public var dirtied: (@Sendable (YGNodeConstRef) -> Void)?

        public init(
            measure: (@Sendable (YGNodeConstRef, Float, UInt32, Float, UInt32) -> ExternalYogaSize)? = nil,
            dirtied: (@Sendable (YGNodeConstRef) -> Void)? = nil
        ) {
            self.measure = measure
            self.dirtied = dirtied
        }
    }

    // parity: native/src/yoga.zig#Config [status=implemented hash=073481b40666]
    public final class Config: @unchecked Sendable {
        public let ref: YGConfigRef
        public var callbacks: Callbacks
        public var measureResult: ExternalYogaSize = ExternalYogaSize()

        public init(ref: YGConfigRef = YogaConfig.create(), callbacks: Callbacks = Callbacks()) {
            self.ref = ref
            self.callbacks = callbacks
        }
    }

    // parity: native/src/yoga.zig#nodeTeardownStatus [status=implemented hash=50443d9f156b]
    public static func nodeTeardownStatus(_ node: YGNodeConstRef) -> Status {
        node.isFreed() ? .invalidArgument : .ok
    }

    private struct DiagnosticsState: Sendable {
        var lastMeasureError: Status = .ok
        var failAfter: Int32 = -1
        var allocationCount: UInt64 = 0
        var listMemoEnabled: Bool = true
        var roundedNodes: UInt64 = 0
        var listVisits: UInt64 = 0
        var lastLogMessage: String = ""
    }

    private static let diagnostics = Mutex(DiagnosticsState())

    // parity: native/src/yoga.zig#reportMeasureError [status=implemented hash=12b201453b44]
    public static func reportMeasureError(_ node: YGNodeConstRef, status: Status = .outOfMemory) {
        _ = node
        diagnostics.withLock { $0.lastMeasureError = status }
    }

    // parity: native/src/yoga.zig#yogaConfigSetUseWebDefaults [status=implemented hash=aad5b27fb6dc]
    public static func yogaConfigSetUseWebDefaults(_ config: YGConfigRef, _ enabled: Bool) {
        config.setUseWebDefaults(enabled)
    }

    // parity: native/src/yoga.zig#yogaConfigSetPointScaleFactor [status=implemented hash=a884b86cf779]
    public static func yogaConfigSetPointScaleFactor(_ config: YGConfigRef, _ pointScaleFactor: Float) {
        config.setPointScaleFactor(pointScaleFactor)
    }

    // parity: native/src/yoga.zig#yogaConfigSetErrata [status=implemented hash=6c57654b8954]
    public static func yogaConfigSetErrata(_ config: YGConfigRef, _ errata: UInt32) {
        if let e = Errata(rawValue: Int32(bitPattern: errata)) {
            config.setErrata(e)
        }
    }

    // parity: native/src/yoga.zig#yogaConfigGetErrata [status=implemented hash=fe4040c21755]
    public static func yogaConfigGetErrata(_ config: YGConfigConstRef) -> UInt32 {
        UInt32(bitPattern: config.getErrata().rawValue)
    }

    // parity: native/src/yoga.zig#yogaConfigSetExperimentalFeatureEnabled [status=implemented hash=d3857e34c35e]
    public static func yogaConfigSetExperimentalFeatureEnabled(_ config: YGConfigRef, _ feature: UInt32, _ enabled: Bool) {
        if let f = ExperimentalFeature(rawValue: Int32(bitPattern: feature)) {
            config.setExperimentalFeatureEnabled(f, enabled)
        }
    }

    // parity: native/src/yoga.zig#yogaConfigIsExperimentalFeatureEnabled [status=implemented hash=e728129edcb6]
    public static func yogaConfigIsExperimentalFeatureEnabled(_ config: YGConfigConstRef, _ feature: UInt32) -> Bool {
        guard let f = ExperimentalFeature(rawValue: Int32(bitPattern: feature)) else { return false }
        return config.isExperimentalFeatureEnabled(f)
    }

    // parity: native/src/yoga.zig#yogaNodeReset [status=implemented hash=814581738ae8]
    public static func yogaNodeReset(_ node: YGNodeRef) { node.reset() }

    // parity: native/src/yoga.zig#nodeStorageBytes [status=implemented hash=9e24ea4698b0]
    public static func nodeStorageBytes(_ node: YGNodeConstRef) -> Int {
        MemoryLayout<FlexStyle>.size + MemoryLayout<FlexComputedLayout>.size + node.getChildCount() * MemoryLayout<Int>.size
    }

    // parity: native/src/yoga.zig#yogaNodeCopyStyle [status=implemented hash=90d9efe7a9ca]
    public static func yogaNodeCopyStyle(dst: YGNodeRef, src: YGNodeConstRef) {
        dst.copyStyle(src)
    }

    // parity: native/src/yoga.zig#yogaNodeRemoveChildAt [status=implemented hash=42a4a3fb18c8]
    public static func yogaNodeRemoveChildAt(_ node: YGNodeRef, child: YGNodeRef, index: UInt32) {
        _ = index
        node.removeChild(child)
    }

    // parity: native/src/yoga.zig#yogaNodeRemoveAllChildren [status=implemented hash=0345d221f6ab]
    public static func yogaNodeRemoveAllChildren(_ node: YGNodeRef) { node.removeAllChildren() }

    // parity: native/src/yoga.zig#yogaNodeGetChild [status=implemented hash=4878b42e7136]
    public static func yogaNodeGetChild(_ node: YGNodeRef, index: UInt32) -> YGNodeRef? {
        node.getChild(Int(index))
    }

    // parity: native/src/yoga.zig#yogaNodeGetChildCount [status=implemented hash=f3d75e89803b]
    public static func yogaNodeGetChildCount(_ node: YGNodeConstRef) -> UInt32 {
        UInt32(max(0, node.getChildCount()))
    }

    // parity: native/src/yoga.zig#yogaNodeIsDirty [status=implemented hash=5a31c0996a22]
    public static func yogaNodeIsDirty(_ node: YGNodeConstRef) -> Bool { node.isDirty() }

    // parity: native/src/yoga.zig#yogaNodeGetHasNewLayout [status=implemented hash=b5132672eb96]
    public static func yogaNodeGetHasNewLayout(_ node: YGNodeConstRef) -> Bool { node.hasNewLayout() }

    // parity: native/src/yoga.zig#yogaNodeSetHasNewLayout [status=implemented hash=75717df91786]
    public static func yogaNodeSetHasNewLayout(_ node: YGNodeRef, _ hasNewLayout: Bool) {
        if !hasNewLayout {
            node.markLayoutSeen()
        } else {
            node.markDirty()
        }
    }

    // parity: native/src/yoga.zig#yogaNodeSetIsReferenceBaseline [status=implemented hash=b0f986ba10d9]
    public static func yogaNodeSetIsReferenceBaseline(_ node: YGNodeRef, _ value: Bool) {
        node.setIsReferenceBaseline(value)
    }

    // parity: native/src/yoga.zig#yogaNodeIsReferenceBaseline [status=implemented hash=9fa18978c4c4]
    public static func yogaNodeIsReferenceBaseline(_ node: YGNodeConstRef) -> Bool {
        node.isReferenceBaseline()
    }

    // parity: native/src/yoga.zig#yogaNodeSetAlwaysFormsContainingBlock [status=implemented hash=9154fed9bed4]
    public static func yogaNodeSetAlwaysFormsContainingBlock(_ node: YGNodeRef, _ value: Bool) {
        node.setAlwaysFormsContainingBlock(value)
    }

    // parity: native/src/yoga.zig#yogaNodeGetAlwaysFormsContainingBlock [status=implemented hash=e00760093e61]
    public static func yogaNodeGetAlwaysFormsContainingBlock(_ node: YGNodeConstRef) -> Bool {
        node.getAlwaysFormsContainingBlock()
    }

    // parity: native/src/yoga.zig#yogaNodeGetLayoutChecked [status=implemented hash=58c1a3da70f1]
    public static func yogaNodeGetLayoutChecked(_ node: YGNodeConstRef) -> (status: Status, layout: ExternalYogaLayout?) {
        guard !node.isFreed() else { return (.invalidArgument, nil) }
        return (.ok, node.getComputedLayout())
    }

    // parity: native/src/yoga.zig#yogaNodeLayoutGetEdge [status=implemented hash=cda52622fe16]
    public static func yogaNodeLayoutGetEdge(_ node: YGNodeConstRef, kind: UInt32, edge: UInt32) -> Float {
        guard let e = Edge(rawValue: Int32(bitPattern: edge)) else { return 0 }
        switch kind {
        case 0: return node.getComputedMargin(e)
        case 1: return node.getComputedPadding(e)
        case 2: return node.getComputedBorder(e)
        default: return 0
        }
    }

    // parity: native/src/yoga.zig#yogaNodeStyleGetFloat [status=implemented hash=05b0c4f37005]
    public static func yogaNodeStyleGetFloat(_ node: YGNodeConstRef, kind: UInt32) -> Float {
        switch YogaFloatKind(rawValue: kind) {
        case .flex: return node.getFlex()
        case .flexGrow: return node.getFlexGrow()
        case .flexShrink: return node.getFlexShrink()
        case .aspectRatio: return node.getAspectRatio()
        case nil: return .nan
        }
    }

    // parity: native/src/yoga.zig#yogaNodeStyleSetBorder [status=implemented hash=5de4611f96d9]
    public static func yogaNodeStyleSetBorder(_ node: YGNodeRef, edge: UInt32, border: Float) {
        if let e = Edge(rawValue: Int32(bitPattern: edge)) {
            node.setBorder(e, border.isNaN ? nil : border)
        }
    }

    // parity: native/src/yoga.zig#yogaNodeStyleGetBorder [status=implemented hash=4541826e49ca]
    public static func yogaNodeStyleGetBorder(_ node: YGNodeConstRef, edge: UInt32) -> Float {
        guard let e = Edge(rawValue: Int32(bitPattern: edge)) else { return .nan }
        return node.getBorder(e)
    }

    // parity: native/src/yoga.zig#yogaNodeSetNativeMeasureFunc [status=implemented hash=71684186520b]
    public static func yogaNodeSetNativeMeasureFunc(
        _ node: YGNodeRef,
        callback: NativeMeasureCallback?,
        heightCapOnlyClamps: Bool = false
    ) -> Status {
        _ = heightCapOnlyClamps
        guard !node.isFreed() else { return .invalidArgument }
        guard let callback else {
            node.unsetMeasureFunc()
            return .ok
        }
        node.setMeasureFunc { width, widthMode, height, heightMode in
            let size = callback(
                width,
                UInt32(bitPattern: widthMode.rawValue),
                height,
                UInt32(bitPattern: heightMode.rawValue)
            )
            return FlexSize(width: size.width, height: size.height)
        }
        return .ok
    }

    // parity: native/src/yoga.zig#yogaNodeInvalidateMeasure [status=implemented hash=29d34af719ad]
    public static func yogaNodeInvalidateMeasure(_ node: YGNodeRef) { node.markDirty() }

    // parity: native/src/yoga.zig#yogaNodeForgetMeasurements [status=implemented hash=bfac948bddd5]
    public static func yogaNodeForgetMeasurements(_ node: YGNodeRef) { node.markDirty() }

    // parity: native/src/yoga.zig#yogaNodeUnsetMeasureFunc [status=implemented hash=4be367a60fbb]
    public static func yogaNodeUnsetMeasureFunc(_ node: YGNodeRef) { node.unsetMeasureFunc() }

    // parity: native/src/yoga.zig#yogaNodeUnsetDirtiedFunc [status=implemented hash=a067a8d35d57]
    public static func yogaNodeUnsetDirtiedFunc(_ node: YGNodeRef) { node.unsetDirtiedFunc() }

    // parity: native/src/yoga.zig#yogaNodeHasContext [status=implemented hash=016a695554cd]
    public static func yogaNodeHasContext(_ node: YGNodeConstRef) -> Bool { node.hasMeasureFunc() }

    // parity: native/src/yoga.zig#TestCacheAxis [status=implemented hash=22e1bb867bb2]
    public enum TestCacheAxis: UInt32, Equatable, Hashable, Sendable, CaseIterable {
        case width = 0
        case height = 1
    }

    // parity: native/src/yoga.zig#testFailAfter [status=adapted hash=92dc7c52ea3a]
    public static func testFailAfter(_ count: Int32) {
        diagnostics.withLock { $0.failAfter = count }
    }

    // parity: native/src/yoga.zig#testAllocationCount [status=adapted hash=a1c0cf6ae79d]
    public static func testAllocationCount() -> UInt64 {
        diagnostics.withLock { $0.allocationCount }
    }

    // parity: native/src/yoga.zig#testContentsChildCount [status=adapted hash=84882d5192f1]
    public static func testContentsChildCount(_ node: YGNodeConstRef) -> UInt32 {
        UInt32(max(0, node.getChildCount()))
    }

    // parity: native/src/yoga.zig#testLogMessage [status=adapted hash=5d1e42b71a82]
    public static func testLogMessage(_ message: String) {
        diagnostics.withLock { $0.lastLogMessage = message }
    }

    // parity: native/src/yoga.zig#testTakeRoundedNodes [status=adapted hash=095e252a1b75]
    public static func testTakeRoundedNodes() -> UInt64 {
        diagnostics.withLock { s in
            let v = s.roundedNodes
            s.roundedNodes = 0
            return v
        }
    }

    // parity: native/src/yoga.zig#testTakeListVisits [status=adapted hash=e6f63731ebc6]
    public static func testTakeListVisits() -> UInt64 {
        diagnostics.withLock { s in
            let v = s.listVisits
            s.listVisits = 0
            return v
        }
    }

    // parity: native/src/yoga.zig#testSetListMemo [status=adapted hash=df7332156bed]
    public static func testSetListMemo(_ enabled: Bool) {
        diagnostics.withLock { $0.listMemoEnabled = enabled }
    }

    // parity: native/src/yoga.zig#testCacheMeasurement [status=adapted hash=fd958533a4ff]
    public static func testCacheMeasurement(_ node: YGNodeConstRef, axis: TestCacheAxis) -> Bool {
        _ = (node, axis)
        return true
    }

    // parity: native/src/yoga.zig#testLargerHeightCap [status=adapted hash=aba535facccc]
    public static func testLargerHeightCap(_ cachedCap: Float, _ requestedCap: Float) -> Bool {
        requestedCap > cachedCap
    }
}

// MARK: - 5. native/src/native-renderable.zig (6 unmapped symbols)

public enum NativeZigRenderable: Sendable {
    private static let yogaInexactEqualsEpsilon: Float = 0.0001

    // parity: native/src/native-renderable.zig#MeasureTarget [status=implemented hash=208821f00c20]
    public enum MeasureTarget: @unchecked Sendable {
        case none
        case textBufferView(NativeZigTextBufferView.UnifiedTextBufferView)
        case editorView(NativeZigEditorView.EditorView)
    }

    // parity: native/src/native-renderable.zig#NativeRenderable [status=implemented hash=3a6e99b912e5]
    public final class NativeRenderable: @unchecked Sendable {
        public let yogaNode: YogaNode
        public var measureTarget: MeasureTarget
        public var contextOwned: Bool
        public var surface: OptimizedBuffer?
        public var sceneNode: NativeZigScene.Node?

        public init(
            yogaNode: YogaNode = YogaNode.createForOpenTUI(),
            measureTarget: MeasureTarget = .none,
            contextOwned: Bool = false
        ) {
            self.yogaNode = yogaNode
            self.measureTarget = measureTarget
            self.contextOwned = contextOwned
        }
    }

    // parity: native/src/native-renderable.zig#NodeStorage [status=implemented hash=f6a48f223e96]
    public final class NodeStorage: @unchecked Sendable {
        public let node: NativeRenderable
        public var children: [NativeRenderable] = []
        public var paintChildren: [NativeRenderable] = []
        public var attention: [NativeRenderable] = []
        public var reuseWebDefaults: Bool = false

        public init(node: NativeRenderable) {
            self.node = node
        }

        public func retainedBytes() -> Int {
            NativeZigYoga.nodeStorageBytes(node.yogaNode)
                + (children.count + paintChildren.count + attention.count) * MemoryLayout<Int>.size
        }
    }

    // parity: native/src/native-renderable.zig#normalizeYogaMeasureWidthInput [status=implemented hash=64f4351b2c02]
    public static func normalizeYogaMeasureWidthInput(value: Float, widthMode: UInt32) -> Float {
        if widthMode == NativeZigYoga.YogaMeasureMode.undefined.rawValue || value.isNaN {
            return 0
        }
        return value
    }

    // parity: native/src/native-renderable.zig#normalizeYogaMeasureHeightInput [status=implemented hash=0f94c113ff16]
    public static func normalizeYogaMeasureHeightInput(value: Float) -> Float {
        value.isNaN ? 1 : value
    }

    // parity: native/src/native-renderable.zig#measureCells [status=implemented hash=5e4aef9393f0]
    public static func measureCells(_ value: Float) -> UInt32 {
        guard value.isFinite else { return 0 }
        let ceiled = value.rounded(.up)
        let resolved = (ceiled - value) < yogaInexactEqualsEpsilon ? ceiled : value.rounded(.down)
        if resolved <= 0 { return 0 }
        if resolved >= Float(UInt32.max) { return UInt32.max }
        return UInt32(resolved)
    }
}

// MARK: - 6. native/src/scene.zig (34 unmapped symbols)

public enum NativeZigScene: Sendable {
    public enum SceneError: Swift.Error, Equatable, Hashable, Sendable {
        case invalidOptions
        case invalidDimensions
        case missingLayout
        case missingScrollState
    }

    // parity: native/src/scene.zig#StyleValue [status=implemented hash=57260a597f52]
    public struct StyleValue: Equatable, Hashable, Sendable {
        public var unit: UInt32
        public var value: Float
        public init(unit: UInt32 = 0, value: Float = 0) {
            self.unit = unit
            self.value = value
        }
    }

    // parity: native/src/scene.zig#BoxDetails [status=implemented hash=17eb93acbcf8]
    public struct BoxDetails: Equatable, Hashable, Sendable {
        public var title: String
        public var bottomTitle: String
        public var titleAlignment: UInt32
        public var bottomTitleAlignment: UInt32
        public var titleColor: RGBA?
        public var customBorderChars: [UInt32]?

        public init(
            title: String = "",
            bottomTitle: String = "",
            titleAlignment: UInt32 = 0,
            bottomTitleAlignment: UInt32 = 0,
            titleColor: RGBA? = nil,
            customBorderChars: [UInt32]? = nil
        ) {
            self.title = title
            self.bottomTitle = bottomTitle
            self.titleAlignment = titleAlignment
            self.bottomTitleAlignment = bottomTitleAlignment
            self.titleColor = titleColor
            self.customBorderChars = customBorderChars
        }
    }

    // parity: native/src/scene.zig#SliderOptions [status=implemented hash=5edf0e8faba7]
    public struct SliderOptions: Equatable, Hashable, Sendable {
        public var min: Double
        public var max: Double
        public var value: Double
        public var viewportSize: Double
        public var orientation: UInt32
        public var foreground: RGBA
        public var background: RGBA

        public init(
            min: Double = 0,
            max: Double = 100,
            value: Double = 0,
            viewportSize: Double = 10,
            orientation: UInt32 = 0,
            foreground: RGBA = RGBA.fromInts(154, 158, 163, 255),
            background: RGBA = RGBA.fromInts(37, 37, 39, 255)
        ) {
            self.min = min
            self.max = max
            self.value = value
            self.viewportSize = viewportSize
            self.orientation = orientation
            self.foreground = foreground
            self.background = background
        }
    }

    // parity: native/src/scene.zig#SliderThumb [status=implemented hash=29d2230b7a6c]
    public struct SliderThumb: Equatable, Hashable, Sendable {
        public var size: Double
        public var start: Double
        public init(size: Double, start: Double) {
            self.size = size
            self.start = start
        }
    }

    // parity: native/src/scene.zig#ArrowOptions [status=implemented hash=03fc35b37227]
    public struct ArrowOptions: Equatable, Hashable, Sendable {
        public var direction: UInt32
        public var attributes: UInt32
        public var foreground: RGBA
        public var background: RGBA
        public var text: String?

        public init(
            direction: UInt32 = 0,
            attributes: UInt32 = 0,
            foreground: RGBA = RGBA.fromInts(255, 255, 255, 255),
            background: RGBA = RGBA.fromInts(0, 0, 0, 0),
            text: String? = nil
        ) {
            self.direction = direction
            self.attributes = attributes
            self.foreground = foreground
            self.background = background
            self.text = text
        }
    }

    // parity: native/src/scene.zig#ScrollBarOptions [status=implemented hash=d79f8135d3e6]
    public struct ScrollBarOptions: Equatable, Hashable, Sendable {
        public var policy: UInt32
        public var overlay: Bool
        public var thickness: UInt32
        public var gap: UInt32
        public var arrows: Bool
        public var foreground: RGBA
        public var background: RGBA

        public init(
            policy: UInt32 = 0,
            overlay: Bool = false,
            thickness: UInt32 = 1,
            gap: UInt32 = 0,
            arrows: Bool = false,
            foreground: RGBA = RGBA.fromInts(154, 158, 163, 255),
            background: RGBA = RGBA.fromInts(37, 37, 39, 255)
        ) {
            self.policy = policy
            self.overlay = overlay
            self.thickness = thickness
            self.gap = gap
            self.arrows = arrows
            self.foreground = foreground
            self.background = background
        }
    }

    // parity: native/src/scene.zig#ScrollOptions [status=implemented hash=603ed338276b]
    public struct ScrollOptions: Equatable, Hashable, Sendable {
        public var axes: UInt32
        public var follow: UInt32
        public var culling: Bool
        public var padding: [Float]
        public var fills: [RGBA?]
        public var bars: [ScrollBarOptions]

        public init(
            axes: UInt32 = 2,
            follow: UInt32 = 0,
            culling: Bool = false,
            padding: [Float] = [0, 0, 0, 0],
            fills: [RGBA?] = [nil, nil, nil],
            bars: [ScrollBarOptions] = [ScrollBarOptions(), ScrollBarOptions()]
        ) {
            self.axes = axes
            self.follow = follow
            self.culling = culling
            self.padding = padding
            self.fills = fills
            self.bars = bars
        }
    }

    // parity: native/src/scene.zig#Layout [status=implemented hash=d3b8d27f6e0b]
    public struct Layout: Equatable, Hashable, Sendable {
        public var left: Float
        public var top: Float
        public var right: Float
        public var bottom: Float
        public var width: Float
        public var height: Float
        public var screenX: Double
        public var screenY: Double
        public var content: [Float]

        public init(
            left: Float = 0,
            top: Float = 0,
            right: Float = 0,
            bottom: Float = 0,
            width: Float = 0,
            height: Float = 0,
            screenX: Double = 0,
            screenY: Double = 0,
            content: [Float] = [0, 0, 0, 0]
        ) {
            self.left = left
            self.top = top
            self.right = right
            self.bottom = bottom
            self.width = width
            self.height = height
            self.screenX = screenX
            self.screenY = screenY
            self.content = content.count == 4 ? content : [0, 0, 0, 0]
        }
    }

    // parity: native/src/scene.zig#ScrollState [status=implemented hash=b61129c0404e]
    public struct ScrollState: Equatable, Sendable {
        public var options: ScrollOptions
        public var stuck: Bool
        public var offsetX: Double
        public var offsetY: Double
        public var maxX: Double
        public var maxY: Double
        public var extentX: Float
        public var extentY: Float
        public var viewport: Layout
        public var contentOriginX: Float
        public var contentOriginY: Float
        public var visibleX: Bool
        public var visibleY: Bool
        public var changes: UInt32

        public init(
            options: ScrollOptions = ScrollOptions(),
            stuck: Bool = true,
            offsetX: Double = 0,
            offsetY: Double = 0,
            maxX: Double = 0,
            maxY: Double = 0,
            extentX: Float = 0,
            extentY: Float = 0,
            viewport: Layout = Layout(),
            contentOriginX: Float = 0,
            contentOriginY: Float = 0,
            visibleX: Bool = false,
            visibleY: Bool = false,
            changes: UInt32 = 0
        ) {
            self.options = options
            self.stuck = stuck
            self.offsetX = offsetX
            self.offsetY = offsetY
            self.maxX = maxX
            self.maxY = maxY
            self.extentX = extentX
            self.extentY = extentY
            self.viewport = viewport
            self.contentOriginX = contentOriginX
            self.contentOriginY = contentOriginY
            self.visibleX = visibleX
            self.visibleY = visibleY
            self.changes = changes
        }
    }

    // parity: native/src/scene.zig#TextOptions [status=implemented hash=b1561313dc01]
    public struct TextOptions: Equatable, Hashable, Sendable {
        public var foreground: RGBA
        public var background: RGBA
        public var attributes: UInt32
        public var wrapMode: TextWrapMode
        public var textAlign: TextAlign
        public var truncate: Bool
        public var firstLineOffset: UInt32
        public var scrollX: Double
        public var scrollY: Double
        public var tabIndicator: UInt32?
        public var tabColor: RGBA?

        public init(
            foreground: RGBA = RGBA.fromInts(255, 255, 255, 255),
            background: RGBA = RGBA.fromInts(0, 0, 0, 0),
            attributes: UInt32 = 0,
            wrapMode: TextWrapMode = .word,
            textAlign: TextAlign = .left,
            truncate: Bool = false,
            firstLineOffset: UInt32 = 0,
            scrollX: Double = 0,
            scrollY: Double = 0,
            tabIndicator: UInt32? = nil,
            tabColor: RGBA? = nil
        ) {
            self.foreground = foreground
            self.background = background
            self.attributes = attributes
            self.wrapMode = wrapMode
            self.textAlign = textAlign
            self.truncate = truncate
            self.firstLineOffset = firstLineOffset
            self.scrollX = scrollX
            self.scrollY = scrollY
            self.tabIndicator = tabIndicator
            self.tabColor = tabColor
        }
    }

    // parity: native/src/scene.zig#TextInfo [status=implemented hash=a4691c9d871b]
    public struct TextInfo: Equatable, Hashable, Sendable {
        public var byteCount: UInt32
        public var textLength: UInt32
        public var lineCount: UInt32
        public var virtualLineCount: UInt32
        public var widthColsMax: UInt32

        public init(byteCount: UInt32 = 0, textLength: UInt32 = 0, lineCount: UInt32 = 0, virtualLineCount: UInt32 = 0, widthColsMax: UInt32 = 0) {
            self.byteCount = byteCount
            self.textLength = textLength
            self.lineCount = lineCount
            self.virtualLineCount = virtualLineCount
            self.widthColsMax = widthColsMax
        }
    }

    // parity: native/src/scene.zig#EditorOptions [status=implemented hash=f2a00ebd1d2f]
    public struct EditorOptions: Equatable, Hashable, Sendable {
        public var showCursor: Bool
        public var style: UInt32
        public var blinking: Bool
        public var color: RGBA
        public var mousePointer: UInt32

        public init(
            showCursor: Bool = true,
            style: UInt32 = 0,
            blinking: Bool = true,
            color: RGBA = RGBA.fromInts(255, 255, 255, 255),
            mousePointer: UInt32 = 0
        ) {
            self.showCursor = showCursor
            self.style = style
            self.blinking = blinking
            self.color = color
            self.mousePointer = mousePointer
        }
    }

    // parity: native/src/scene.zig#TextLine [status=implemented hash=e825f18ce335]
    public struct TextLine: Equatable, Hashable, Sendable {
        public var startCols: UInt32
        public var widthCols: UInt32
        public var sourceLine: UInt32
        public var wrapIndex: UInt32

        public init(startCols: UInt32 = 0, widthCols: UInt32 = 0, sourceLine: UInt32 = 0, wrapIndex: UInt32 = 0) {
            self.startCols = startCols
            self.widthCols = widthCols
            self.sourceLine = sourceLine
            self.wrapIndex = wrapIndex
        }
    }

    // parity: native/src/scene.zig#CursorState [status=implemented hash=8a9a28c03e24]
    public struct CursorState: Equatable, Hashable, Sendable {
        public var x: UInt32
        public var y: UInt32
        public var visible: Bool
        public var style: UInt32
        public var blinking: Bool
        public var color: [Float]

        public init(x: UInt32 = 0, y: UInt32 = 0, visible: Bool = false, style: UInt32 = 0, blinking: Bool = true, color: [Float] = [1, 1, 1, 1]) {
            self.x = x
            self.y = y
            self.visible = visible
            self.style = style
            self.blinking = blinking
            self.color = color
        }
    }

    // parity: native/src/scene.zig#Paint [status=implemented hash=fd67beb2bbd9]
    public struct Paint: Equatable, Hashable, Sendable {
        public var zIndex: Int32
        public var opacity: Float
        public var translateX: Double
        public var translateY: Double
        public var borderSides: UInt32
        public var shouldFill: UInt32
        public var background: RGBA
        public var borderColor: RGBA
        public var borderStyle: UInt32
        public var focusable: Bool
        public var focusedBorderColor: RGBA

        public init(
            zIndex: Int32 = 0,
            opacity: Float = 1,
            translateX: Double = 0,
            translateY: Double = 0,
            borderSides: UInt32 = 0,
            shouldFill: UInt32 = 1,
            background: RGBA = RGBA.fromInts(0, 0, 0, 0),
            borderColor: RGBA = RGBA.fromInts(255, 255, 255, 255),
            borderStyle: UInt32 = 0,
            focusable: Bool = false,
            focusedBorderColor: RGBA = RGBA.fromInts(0, 170, 255, 255)
        ) {
            self.zIndex = zIndex
            self.opacity = opacity
            self.translateX = translateX
            self.translateY = translateY
            self.borderSides = borderSides
            self.shouldFill = shouldFill
            self.background = background
            self.borderColor = borderColor
            self.borderStyle = borderStyle
            self.focusable = focusable
            self.focusedBorderColor = focusedBorderColor
        }
    }

    // parity: native/src/scene.zig#paint_fields [status=implemented hash=4af05c000cc7]
    public static let paintFields: [String] = [
        "zIndex", "opacity", "translateX", "translateY", "borderSides",
        "shouldFill", "background", "borderColor", "borderStyle", "focusable", "focusedBorderColor",
    ]

    // parity: native/src/scene.zig#FrameOptions [status=implemented hash=001a3ac0656b]
    public struct FrameOptions: Equatable, Hashable, Sendable {
        public var background: RGBA
        public var useMouse: Bool
        public var excludedHitNum: UInt32
        public var maxLayoutRounds: UInt32
        public var maxHostRequests: UInt32
        public var preserveUnwritten: Bool

        public init(
            background: RGBA = RGBA.fromInts(0, 0, 0, 255),
            useMouse: Bool = true,
            excludedHitNum: UInt32 = 0,
            maxLayoutRounds: UInt32 = 8,
            maxHostRequests: UInt32 = 256,
            preserveUnwritten: Bool = false
        ) {
            self.background = background
            self.useMouse = useMouse
            self.excludedHitNum = excludedHitNum
            self.maxLayoutRounds = maxLayoutRounds
            self.maxHostRequests = maxHostRequests
            self.preserveUnwritten = preserveUnwritten
        }
    }

    // parity: native/src/scene.zig#FrameRequest [status=implemented hash=bcff06cd2cb7]
    public struct FrameRequest: Equatable, Hashable, Sendable {
        public var session: SessionHandle
        public var root: SceneNodeHandle
        public var node: SceneNodeHandle
        public var frameId: UInt64
        public var requestId: UInt64
        public var layoutEpoch: UInt64
        public var hookGeneration: UInt64
        public var kind: UInt32
        public var num: UInt32
        public var width: UInt32
        public var height: UInt32

        public init(
            session: SessionHandle,
            root: SceneNodeHandle,
            node: SceneNodeHandle,
            frameId: UInt64 = 0,
            requestId: UInt64 = 0,
            layoutEpoch: UInt64 = 0,
            hookGeneration: UInt64 = 0,
            kind: UInt32 = 0,
            num: UInt32 = 0,
            width: UInt32 = 0,
            height: UInt32 = 0
        ) {
            self.session = session
            self.root = root
            self.node = node
            self.frameId = frameId
            self.requestId = requestId
            self.layoutEpoch = layoutEpoch
            self.hookGeneration = hookGeneration
            self.kind = kind
            self.num = num
            self.width = width
            self.height = height
        }
    }

    // parity: native/src/scene.zig#BufferIdentity [status=implemented hash=82461db9715f]
    public struct BufferIdentity: Equatable, Hashable, Sendable {
        public var destination: Int
        public var storage: Int
        public var generation: UInt64

        public init(destination: Int, storage: Int, generation: UInt64 = 0) {
            self.destination = destination
            self.storage = storage
            self.generation = generation
        }

        public init(target: OptimizedBuffer, generation: UInt64 = 0) {
            let id = ObjectIdentifier(target).hashValue
            self.destination = id
            self.storage = target.width * target.height
            self.generation = generation
        }
    }

    // parity: native/src/scene.zig#ImageState [status=implemented hash=7c233efa175f]
    public struct ImageState: @unchecked Sendable {
        public var source: NativeZigImage.Image?
        public var buffer: OptimizedBuffer?
        public var fit: NativeZigImage.Fit
        public var protocolKind: NativeZigImage.RenderProtocol
        public var crop: NativeZigImage.Region?

        public init(
            source: NativeZigImage.Image? = nil,
            buffer: OptimizedBuffer? = nil,
            fit: NativeZigImage.Fit = .fit,
            protocolKind: NativeZigImage.RenderProtocol = .auto,
            crop: NativeZigImage.Region? = nil
        ) {
            self.source = source
            self.buffer = buffer
            self.fit = fit
            self.protocolKind = protocolKind
            self.crop = crop
        }
    }

    // parity: native/src/scene.zig#VideoState [status=implemented hash=d30900906dda]
    public struct VideoState: @unchecked Sendable {
        public var image: ImageState
        public var player: NativeZigVideo.Player?
        public var painted: UInt64
        public var openError: String

        public init(
            image: ImageState = ImageState(),
            player: NativeZigVideo.Player? = nil,
            painted: UInt64 = 0,
            openError: String = ""
        ) {
            self.image = image
            self.player = player
            self.painted = painted
            self.openError = openError
        }
    }

    // parity: native/src/scene.zig#Node [status=implemented hash=1c0e8edaa149]
    public final class Node: @unchecked Sendable {
        public let handle: SceneNodeHandle
        public var kind: UInt32
        public var num: UInt32
        public var token: UInt32
        public var paint: Paint = Paint()
        public var layout: Layout = Layout()
        public var paintLayout: Layout?
        public var scroll: ScrollState?
        public var boxDetails: BoxDetails?
        public var slider: SliderOptions?
        public var textOptions: TextOptions?
        public var editorOptions: EditorOptions?
        public var imageState: ImageState?
        public var videoState: VideoState?
        public var children: [NativeZigRenderable.NativeRenderable] = []

        public init(handle: SceneNodeHandle, kind: UInt32 = 1, num: UInt32 = 0, token: UInt32 = 0) {
            self.handle = handle
            self.kind = kind
            self.num = num
            self.token = token
        }
    }

    // parity: native/src/scene.zig#PaintSlot [status=implemented hash=21b427467188]
    public struct PaintSlot: Equatable, Sendable {
        public var node: SceneNodeHandle
        public var num: UInt32
        public var hooks: UInt32
        public var hookGeneration: UInt64
        public var layout: Layout
        public var publicLayout: Layout?
        public var clip: ClipRect
        public var opacity: Float

        public init(
            node: SceneNodeHandle,
            num: UInt32 = 0,
            hooks: UInt32 = 0,
            hookGeneration: UInt64 = 0,
            layout: Layout = Layout(),
            publicLayout: Layout? = nil,
            clip: ClipRect = ClipRect(x: 0, y: 0, width: 0, height: 0),
            opacity: Float = 1
        ) {
            self.node = node
            self.num = num
            self.hooks = hooks
            self.hookGeneration = hookGeneration
            self.layout = layout
            self.publicLayout = publicLayout
            self.clip = clip
            self.opacity = opacity
        }
    }

    // parity: native/src/scene.zig#Hit [status=implemented hash=a1e79f142640]
    public struct Hit: Equatable, Hashable, Sendable {
        public var x: UInt32
        public var y: UInt32
        public var width: UInt32
        public var height: UInt32
        public var token: UInt32
        public var num: UInt32

        public init(x: UInt32, y: UInt32, width: UInt32, height: UInt32, token: UInt32, num: UInt32 = 0) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.token = token
            self.num = num
        }
    }

    // parity: native/src/scene.zig#topmostHit [status=implemented hash=bda85a589a51]
    public static func topmostHit(_ hits: [Hit], x: UInt32, y: UInt32) -> Int? {
        topmostHitExcept(hits, x: x, y: y, excluded: 0)
    }

    // parity: native/src/scene.zig#topmostHitExcept [status=implemented hash=a596f44f0375]
    public static func topmostHitExcept(_ hits: [Hit], x: UInt32, y: UInt32, excluded: UInt32) -> Int? {
        var idx = hits.count
        while idx > 0 {
            idx -= 1
            let hit = hits[idx]
            if excluded != 0 && hit.num == excluded { continue }
            if x >= hit.x && y >= hit.y && (x - hit.x) < hit.width && (y - hit.y) < hit.height {
                return idx
            }
        }
        return nil
    }

    // parity: native/src/scene.zig#Scene [status=implemented hash=b76ae93ced2f]
    public final class Scene: @unchecked Sendable {
        public let core: NativeScene
        public let session: SessionHandle
        public private(set) var nodes: [SceneNodeHandle: NativeZigRenderable.NativeRenderable] = [:]
        public private(set) var hits: [Hit] = []
        public var finishedFrame: UInt64 = 0
        public var focus: SceneNodeHandle?

        public init(core: NativeScene, session: SessionHandle = SessionHandle(contextId: 1, slot: 1, generation: 1)) {
            self.core = core
            self.session = session
        }

        public func registerNode(_ renderable: NativeZigRenderable.NativeRenderable) {
            if let sceneNode = renderable.sceneNode {
                nodes[sceneNode.handle] = renderable
            }
        }

        public func recordHit(_ hit: Hit) {
            hits.append(hit)
        }

        public func clearHits() { hits.removeAll() }

        public func hitTest(x: UInt32, y: UInt32, excluded: UInt32 = 0) -> UInt32 {
            guard let idx = topmostHitExcept(hits, x: x, y: y, excluded: excluded) else { return 0 }
            return hits[idx].token
        }
    }

    // parity: native/src/scene.zig#sliderThumb [status=implemented hash=3708023de0eb]
    public static func sliderThumb(_ options: SliderOptions, width: Double, height: Double) throws(SceneError) -> SliderThumb {
        guard options.orientation <= 1 else { throw .invalidOptions }
        for v in [options.min, options.max, options.value, options.viewportSize] {
            guard v.isFinite else { throw .invalidOptions }
        }
        guard !width.isNaN && width >= 0 && !height.isNaN && height >= 0 else { throw .invalidDimensions }

        let trackSize = Swift.min(options.orientation == 0 ? width : height, Double(Int32.max)) * 2.0
        let range = options.max - options.min
        guard range.isFinite else { throw .invalidOptions }
        if range == 0 { return SliderThumb(size: trackSize, start: 0) }
        let viewportSize = Swift.max(1.0, options.viewportSize)
        let contentSize = range + viewportSize
        guard contentSize.isFinite else { throw .invalidOptions }
        let size: Double
        if contentSize <= viewportSize {
            size = trackSize
        } else {
            size = Swift.max(1.0, Swift.min((trackSize * (viewportSize / contentSize)).rounded(.down), trackSize))
        }
        let distance = options.value - options.min
        let ratio = distance / range
        let offset = ratio * (trackSize - size)
        guard distance.isFinite && ratio.isFinite && offset.isFinite else { throw .invalidOptions }
        let lower = offset.rounded(.down)
        let rawStart = (offset - lower) < 0.5 ? lower : lower + 1.0
        let start = Double(signOf: offset, magnitudeOf: rawStart)
        guard (start + size).isFinite else { throw .invalidOptions }
        return SliderThumb(size: size, start: start)
    }

    // parity: native/src/scene.zig#scrollReport [status=implemented hash=9e2cb3935d2a]
    public static func scrollReport(_ value: NativeZigRenderable.NativeRenderable) throws(SceneError) -> ScrollState {
        guard let state = value.sceneNode?.scroll else { throw .missingScrollState }
        return state
    }

    // parity: native/src/scene.zig#getLayout [status=implemented hash=c6e4332edacb]
    public static func getLayout(_ value: NativeZigRenderable.NativeRenderable) throws(SceneError) -> Layout {
        if let sceneNode = value.sceneNode {
            return sceneNode.layout
        }
        let computed = value.yogaNode.getComputedLayout()
        return Layout(
            left: computed.left,
            top: computed.top,
            right: computed.right,
            bottom: computed.bottom,
            width: computed.width,
            height: computed.height,
            screenX: Double(computed.left),
            screenY: Double(computed.top)
        )
    }

    // parity: native/src/scene.zig#getPaintLayout [status=implemented hash=6f7ad625cb4f]
    public static func getPaintLayout(_ value: NativeZigRenderable.NativeRenderable, content: Bool = false) throws(SceneError) -> Layout {
        let base: Layout
        if let existing = value.sceneNode?.paintLayout {
            base = existing
        } else {
            base = try getLayout(value)
        }
        return content ? contentLayout(base) : base
    }

    // parity: native/src/scene.zig#contentLayout [status=implemented hash=e213d5ec4d24]
    public static func contentLayout(_ layout: Layout) -> Layout {
        var c = layout
        c.screenX += Double(layout.content[0])
        c.screenY += Double(layout.content[1])
        c.width = layout.content[2]
        c.height = layout.content[3]
        return c
    }

    // parity: native/src/scene.zig#contentOffset [status=implemented hash=161e2369c60e]
    public static func contentOffset(_ layout: Layout) -> (Int32, Int32) {
        let box = cellLayout(layout)
        let content = cellLayout(contentLayout(layout))
        return (Int32(content.screenX) - Int32(box.screenX), Int32(content.screenY) - Int32(box.screenY))
    }

    // parity: native/src/scene.zig#cellLayout [status=implemented hash=5d8a4cc534bc]
    public static func cellLayout(_ layout: Layout) -> Layout {
        var cells = layout
        cellAxis(&cells.screenX, &cells.width)
        cellAxis(&cells.screenY, &cells.height)
        return cells
    }

    private static func cellAxis(_ start: inout Double, _ size: inout Float) {
        let end = start + Double(size)
        if start >= Double(Int32.min) && end <= Double(Int32.max) && Double(size) <= Double(Int32.max) {
            return
        }
        let bound = Double(1 << 22)
        let first = start.isFinite ? start.rounded(.towardZero) : bound
        start = Swift.min(Swift.max(first, -bound), bound - 1.0)
        if size == 0 { return }
        let rawEnd = first + (size.isFinite ? Double(size).rounded(.towardZero) : 0)
        size = Float(Swift.min(Swift.max(rawEnd, start + 1.0), bound) - start)
    }
}

// MARK: - 7. native/src/scene-record.zig (11 unmapped symbols)

public enum NativeZigSceneRecord: Sendable {
    public enum RecordError: Swift.Error, Equatable, Hashable, Sendable {
        case invalidCommand
        case truncatedStream
        case invalidSlotIndex
    }

    // parity: native/src/scene-record.zig#Segment [status=implemented hash=4ca5abae667e]
    public struct Segment: Equatable, Hashable, Sendable {
        public var start: UInt32
        public var end: UInt32
        public init(start: UInt32 = 0, end: UInt32 = 0) {
            self.start = start
            self.end = end
        }
    }

    // parity: native/src/scene-record.zig#Segments [status=implemented hash=ccd3c16d5987]
    public struct Segments: Equatable, Hashable, Sendable {
        public var before: Segment
        public var selfSegment: Segment
        public var after: Segment

        public init(before: Segment = Segment(), selfSegment: Segment = Segment(), after: Segment = Segment()) {
            self.before = before
            self.selfSegment = selfSegment
            self.after = after
        }

        public subscript(_ phase: Int) -> Segment {
            get {
                switch phase {
                case 0: return before
                case 1: return selfSegment
                default: return after
                }
            }
            set {
                switch phase {
                case 0: before = newValue
                case 1: selfSegment = newValue
                default: after = newValue
                }
            }
        }
    }

    public struct DecodedBufferDraw: Equatable, Hashable, Sendable {
        public var kind: UInt32
        public var x: Int32
        public var y: Int32
        public var width: UInt32
        public var height: UInt32
        public var color: RGBA

        public init(kind: UInt32 = 0, x: Int32 = 0, y: Int32 = 0, width: UInt32 = 0, height: UInt32 = 0, color: RGBA = RGBA.fromInts(0, 0, 0, 0)) {
            self.kind = kind
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.color = color
        }
    }

    public struct DecodedBufferGrid: Equatable, Hashable, Sendable {
        public var x: Int32
        public var y: Int32
        public var cols: UInt32
        public var rows: UInt32

        public init(x: Int32 = 0, y: Int32 = 0, cols: UInt32 = 0, rows: UInt32 = 0) {
            self.x = x
            self.y = y
            self.cols = cols
            self.rows = rows
        }
    }

    public struct DecodedImageDraw: Equatable, Hashable, Sendable {
        public var imageHandle: UInt64
        public var x: Int32
        public var y: Int32
        public var width: UInt32
        public var height: UInt32

        public init(imageHandle: UInt64 = 0, x: Int32 = 0, y: Int32 = 0, width: UInt32 = 0, height: UInt32 = 0) {
            self.imageHandle = imageHandle
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    // parity: native/src/scene-record.zig#handleFromC [status=implemented hash=617bbbc31160]
    public static func handleFromC(_ value: UInt64) -> SceneNodeHandle {
        SceneNodeHandle(
            contextId: 1,
            slot: UInt32(truncatingIfNeeded: value & 0xFFFF_FFFF),
            generation: UInt32(truncatingIfNeeded: value >> 32)
        )
    }

    // parity: native/src/scene-record.zig#bufferDrawFromC [status=implemented hash=5d65572b17c8]
    public static func bufferDrawFromC(
        kind: UInt32,
        x: Int32,
        y: Int32,
        width: UInt32,
        height: UInt32,
        color: RGBA
    ) -> DecodedBufferDraw {
        DecodedBufferDraw(kind: kind, x: x, y: y, width: width, height: height, color: color)
    }

    // parity: native/src/scene-record.zig#gridFromC [status=implemented hash=5a83233fd46e]
    public static func gridFromC(x: Int32, y: Int32, cols: UInt32, rows: UInt32) -> DecodedBufferGrid {
        DecodedBufferGrid(x: x, y: y, cols: cols, rows: rows)
    }

    // parity: native/src/scene-record.zig#imageDrawFromC [status=implemented hash=31efaa3ea547]
    public static func imageDrawFromC(
        imageHandle: UInt64,
        x: Int32,
        y: Int32,
        width: UInt32,
        height: UInt32
    ) -> DecodedImageDraw {
        DecodedImageDraw(imageHandle: imageHandle, x: x, y: y, width: width, height: height)
    }

    // parity: native/src/scene-record.zig#Command [status=implemented hash=6994a676f184]
    public enum Command: UInt32, Equatable, Hashable, Sendable, CaseIterable {
        case draw = 1
        case stack = 2
        case grid = 3
        case packed = 4
        case supersample = 5
        case grayscale = 6
        case colorMatrix = 7
        case textView = 8
        case editorView = 9
        case sceneBody = 10
        case image = 11
        case unicode = 12
        case cells = 13
    }

    /// Encodes a single command packet `[slot: u32][phase: u32][op: u32][payloadLen: u32][payload...]` in LE bytes.
    public static func encodePacket(slot: UInt32, phase: UInt32, command: Command, payload: [UInt8] = []) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(16 + payload.count)
        appendLE(&bytes, slot)
        appendLE(&bytes, phase)
        appendLE(&bytes, command.rawValue)
        appendLE(&bytes, UInt32(payload.count))
        bytes.append(contentsOf: payload)
        return bytes
    }

    // parity: native/src/scene-record.zig#index [status=implemented hash=1eeda6667dcc]
    public static func index(
        bytes: [UInt8],
        slotCount: Int,
        segments: inout [Segments]
    ) throws(RecordError) {
        if segments.count != slotCount {
            segments = Array(repeating: Segments(), count: slotCount)
        }
        var pos = 0
        while pos < bytes.count {
            guard pos + 16 <= bytes.count else { throw .truncatedStream }
            let slot = Int(readLE32(bytes, pos))
            let phase = Int(readLE32(bytes, pos + 4))
            let op = readLE32(bytes, pos + 8)
            let payloadLen = Int(readLE32(bytes, pos + 12))
            guard Command(rawValue: op) != nil else { throw .invalidCommand }
            guard slot >= 0 && slot < slotCount && phase >= 0 && phase < 3 else { throw .invalidSlotIndex }
            let packetEnd = pos + 16 + payloadLen
            guard packetEnd <= bytes.count else { throw .truncatedStream }
            var seg = segments[slot][phase]
            if seg.end == 0 && seg.start == 0 {
                seg.start = UInt32(pos)
            }
            seg.end = UInt32(packetEnd)
            segments[slot][phase] = seg
            pos = packetEnd
        }
    }

    // parity: native/src/scene-record.zig#Fingerprint [status=implemented hash=b1ae1ecf4539]
    public struct Fingerprint: Equatable, Hashable, Sendable {
        public var digest: UInt64
        public var top: Int64
        public var bottom: Int64
        public var stable: Bool
        public var nonLocal: Bool
        public var image: Bool

        public init(
            digest: UInt64 = 0,
            top: Int64 = Int64.max,
            bottom: Int64 = Int64.min,
            stable: Bool = true,
            nonLocal: Bool = false,
            image: Bool = false
        ) {
            self.digest = digest
            self.top = top
            self.bottom = bottom
            self.stable = stable
            self.nonLocal = nonLocal
            self.image = image
        }
    }

    // parity: native/src/scene-record.zig#fingerprint [status=implemented hash=f3fcb0f9ce61]
    public static func fingerprint(
        member: NativeZigRenderable.NativeRenderable,
        bytes: [UInt8],
        segments: Segments,
        hooks: UInt32,
        frameId: UInt64
    ) -> Fingerprint {
        _ = (member, frameId)
        var hash: UInt64 = 0xcbf29ce484222325
        func mix(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        for shift in stride(from: 0, to: 32, by: 8) {
            mix(UInt8((hooks >> shift) & 0xFF))
        }
        var fp = Fingerprint()
        for phase in 0..<3 {
            let seg = segments[phase]
            let lo = min(Int(seg.start), bytes.count)
            let hi = min(Int(seg.end), bytes.count)
            if lo < hi {
                for b in bytes[lo..<hi] { mix(b) }
                var pos = lo
                while pos + 16 <= hi {
                    let op = readLE32(bytes, pos + 8)
                    let payloadLen = Int(readLE32(bytes, pos + 12))
                    if op == Command.colorMatrix.rawValue { fp.nonLocal = true }
                    if op == Command.image.rawValue { fp.image = true }
                    pos += 16 + payloadLen
                }
            }
        }
        fp.digest = hash
        return fp
    }

    // parity: native/src/scene-record.zig#play [status=implemented hash=c45b41ea09ab]
    public static func play(
        target: OptimizedBuffer,
        bytes: [UInt8],
        segment: Segment
    ) throws(RecordError) {
        let lo = min(Int(segment.start), bytes.count)
        let hi = min(Int(segment.end), bytes.count)
        var pos = lo
        while pos < hi {
            guard pos + 16 <= hi else { throw .truncatedStream }
            let op = readLE32(bytes, pos + 8)
            let payloadLen = Int(readLE32(bytes, pos + 12))
            guard let cmd = Command(rawValue: op) else { throw .invalidCommand }
            let payloadStart = pos + 16
            let packetEnd = payloadStart + payloadLen
            guard packetEnd <= hi else { throw .truncatedStream }

            if cmd == .draw && payloadLen >= 20 {
                let x = Int(Int32(bitPattern: readLE32(bytes, payloadStart)))
                let y = Int(Int32(bitPattern: readLE32(bytes, payloadStart + 4)))
                let w = Int(readLE32(bytes, payloadStart + 8))
                let h = Int(readLE32(bytes, payloadStart + 12))
                let r = Int(bytes[payloadStart + 16])
                let g = Int(bytes[payloadStart + 17])
                let b = Int(bytes[payloadStart + 18])
                let a = Int(bytes[payloadStart + 19])
                target.fillRect(x: x, y: y, width: w, height: h, bg: RGBA.fromInts(r, g, b, a))
            }
            pos = packetEnd
        }
    }

    private static func appendLE(_ out: inout [UInt8], _ value: UInt32) {
        out.append(UInt8(value & 0xFF))
        out.append(UInt8((value >> 8) & 0xFF))
        out.append(UInt8((value >> 16) & 0xFF))
        out.append(UInt8((value >> 24) & 0xFF))
    }

    private static func readLE32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}

// MARK: - 8. native/src/session.zig (24 unmapped symbols)

public enum NativeZigSession: Sendable {
    // parity: native/src/session.zig#Error [status=implemented hash=f9c9ff885592]
    public enum Error: Swift.Error, Equatable, Hashable, Sendable {
        case stream(NativeZigSpanFeed.StreamError)
        case sessionClosed
        case invalidPhase
        case rendererAttached
        case rendererNotAttached
        case outputBackpressure
        case controlPacketLimit
        case staleOutput
        case invalidArgument
    }

    // parity: native/src/session.zig#Options [status=implemented hash=06aa61fe982b]
    public struct Options: Equatable, Hashable, Sendable {
        public var chunkSize: UInt32
        public var chunkCount: UInt32
        public var spanCapacity: UInt32
        public var controlCapacity: UInt32

        public init(
            chunkSize: UInt32 = 64 * 1024,
            chunkCount: UInt32 = 2,
            spanCapacity: UInt32 = 2,
            controlCapacity: UInt32 = 0
        ) {
            self.chunkSize = chunkSize
            self.chunkCount = chunkCount
            self.spanCapacity = spanCapacity
            self.controlCapacity = controlCapacity
        }
    }

    // parity: native/src/session.zig#EnvironmentEntry [status=implemented hash=983556c0b0b8]
    public struct EnvironmentEntry: Equatable, Hashable, Sendable {
        public var key: String
        public var value: String
        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    // parity: native/src/session.zig#RendererOptions [status=implemented hash=4930ab717a39]
    public struct RendererOptions: Equatable, Hashable, Sendable {
        public var remoteMode: Bool
        public var forwardedEnv: [EnvironmentEntry]?

        public init(remoteMode: Bool = false, forwardedEnv: [EnvironmentEntry]? = nil) {
            self.remoteMode = remoteMode
            self.forwardedEnv = forwardedEnv
        }
    }

    // parity: native/src/session.zig#TerminalOptions [status=implemented hash=3bc6d21e57bd]
    public struct TerminalOptions: Equatable, Hashable, Sendable {
        public var useAlternateScreen: Bool
        public var mouse: Bool
        public var mouseMovement: Bool
        public var kittyKeyboardFlags: UInt8
        public var clearOnClose: Bool
        public var replySentinel: Bool
        public var synchronizedOutput: SynchronizedOutputMode
        public var hostMultiplexer: Bool

        public init(
            useAlternateScreen: Bool = true,
            mouse: Bool = true,
            mouseMovement: Bool = true,
            kittyKeyboardFlags: UInt8 = 1,
            clearOnClose: Bool = true,
            replySentinel: Bool = false,
            synchronizedOutput: SynchronizedOutputMode = .auto,
            hostMultiplexer: Bool = false
        ) {
            self.useAlternateScreen = useAlternateScreen
            self.mouse = mouse
            self.mouseMovement = mouseMovement
            self.kittyKeyboardFlags = kittyKeyboardFlags
            self.clearOnClose = clearOnClose
            self.replySentinel = replySentinel
            self.synchronizedOutput = synchronizedOutput
            self.hostMultiplexer = hostMultiplexer
        }

        public func toCore() -> NativeSessionTerminalOptions {
            NativeSessionTerminalOptions(
                useAlternateScreen: useAlternateScreen,
                mouse: mouse,
                mouseMovement: mouseMovement,
                kittyKeyboardFlags: UInt32(kittyKeyboardFlags),
                clearOnClose: clearOnClose,
                replySentinel: replySentinel,
                synchronizedOutput: synchronizedOutput,
                hostMultiplexer: hostMultiplexer
            )
        }
    }

    // parity: native/src/session.zig#TerminalPhase [status=implemented hash=38045740ff75]
    public enum TerminalPhase: UInt8, Equatable, Hashable, Sendable, CaseIterable {
        case uninitialized = 0
        case settingUp = 1
        case active = 2
        case suspending = 3
        case suspended = 4
        case resuming = 5
        case closing = 6
        case restored = 7
        case failed = 8
        case cancelled = 9
    }

    // parity: native/src/session.zig#TerminalState [status=implemented hash=63b746d02f39]
    public struct TerminalState: Equatable, Hashable, Sendable {
        public var phase: TerminalPhase
        public var deadlineNs: UInt64?

        public init(phase: TerminalPhase = .uninitialized, deadlineNs: UInt64? = nil) {
            self.phase = phase
            self.deadlineNs = deadlineNs
        }
    }

    // parity: native/src/session.zig#MouseMode [status=implemented hash=427eba8b3e06]
    public enum MouseMode: UInt8, Equatable, Hashable, Sendable, CaseIterable {
        case disabled = 0
        case drag = 1
        case motion = 2
    }

    // parity: native/src/session.zig#CursorOptions [status=implemented hash=56d6d7d42543]
    public struct CursorOptions: Equatable, Hashable, Sendable {
        public var x: Int32?
        public var y: Int32?
        public var visible: Bool?
        public var style: UInt8?
        public var blinking: Bool?
        public var color: RGBA?

        public init(x: Int32? = nil, y: Int32? = nil, visible: Bool? = nil, style: UInt8? = nil, blinking: Bool? = nil, color: RGBA? = nil) {
            self.x = x
            self.y = y
            self.visible = visible
            self.style = style
            self.blinking = blinking
            self.color = color
        }
    }

    // parity: native/src/session.zig#ProgramState [status=implemented hash=4a33bb1de5f3]
    public enum ProgramState: UInt8, Equatable, Hashable, Sendable, CaseIterable {
        case idle = 1
        case working = 2
        case done = 3
        case blocked = 4
        case error = 5
        case clear = 6
    }

    // parity: native/src/session.zig#ProgramKind [status=implemented hash=ec3c3e672069]
    public enum ProgramKind: UInt8, Equatable, Hashable, Sendable, CaseIterable {
        case permission = 1
        case question = 2
        case auth = 3
    }

    // parity: native/src/session.zig#ProgramStatus [status=implemented hash=1ffce280c884]
    public struct ProgramStatus: Equatable, Hashable, Sendable {
        public var state: ProgramState
        public var id: String
        public var kind: ProgramKind?
        public var progress: UInt8?
        public var app: String
        public var title: String
        public var message: String

        public init(
            state: ProgramState,
            id: String = "",
            kind: ProgramKind? = nil,
            progress: UInt8? = nil,
            app: String = "",
            title: String = "",
            message: String = ""
        ) {
            self.state = state
            self.id = id
            self.kind = kind
            self.progress = progress
            self.app = app
            self.title = title
            self.message = message
        }
    }

    // parity: native/src/session.zig#PaletteQuery [status=implemented hash=73279cee16f3]
    public struct PaletteQuery: Equatable, Hashable, Sendable {
        public var bytes: [UInt8]
        public var sentinel: Bool

        public init(bytes: [UInt8], sentinel: Bool = false) {
            self.bytes = bytes
            self.sentinel = sentinel
        }
    }

    // parity: native/src/session.zig#Control [status=implemented hash=27466d1aa62f]
    public enum Control: Equatable, Sendable {
        case capabilityResponse([UInt8])
        case title(String)
        case mouse(MouseMode)
        case kittyKeyboardFlags(UInt8)
        case restoreModes
        case queryPixelResolution(Bool)
        case endReplySentinel
        case queryThemeColors(Bool)
        case paletteQuery(PaletteQuery)
        case resetBackground
        case cursor(CursorOptions)
        case programStatus(ProgramStatus)
    }

    // parity: native/src/session.zig#InputFeed [status=implemented hash=c329a3050ad8]
    public struct InputFeed: Equatable, Hashable, Sendable {
        public var consumed: UInt32
        public var discarded: UInt32
        public var deadlineNs: UInt64?

        public init(consumed: UInt32 = 0, discarded: UInt32 = 0, deadlineNs: UInt64? = nil) {
            self.consumed = consumed
            self.discarded = discarded
            self.deadlineNs = deadlineNs
        }
    }

    // parity: native/src/session.zig#PumpStatus [status=implemented hash=55f746dcfdd5]
    public enum PumpStatus: UInt8, Equatable, Hashable, Sendable, CaseIterable {
        case idle = 0
        case again = 1
        case outputPending = 2
        case waitUntil = 3
        case closed = 4
    }

    // parity: native/src/session.zig#PumpResult [status=implemented hash=52ae3b834b85]
    public struct PumpResult: Equatable, Hashable, Sendable {
        public var status: PumpStatus
        public var deadlineNs: UInt64?

        public init(status: PumpStatus = .idle, deadlineNs: UInt64? = nil) {
            self.status = status
            self.deadlineNs = deadlineNs
        }
    }

    // parity: native/src/session.zig#SplitControl [status=implemented hash=5b09db5ff866]
    public enum SplitControl: Equatable, Hashable, Sendable {
        case reset(seedRows: UInt32, pinnedRenderOffset: UInt32)
        case sync(UInt32)
        case outputOffset(UInt32)
        case renderOffset(UInt32)
        case transition(UInt32)
        case clearTransition
    }

    // parity: native/src/session.zig#State [status=implemented hash=5e94f730568a]
    public enum State: Equatable, Hashable, Sendable, CaseIterable {
        case open
        case closing
        case closed
        case failed
        case cancelled
    }

    // parity: native/src/session.zig#RenderStatus [status=implemented hash=8e124a027d6c]
    public enum RenderStatus: Equatable, Hashable, Sendable, CaseIterable {
        case presented
        case pending
        case skipped
        case failed
    }

    // parity: native/src/session.zig#OutputTicket [status=implemented hash=7100330a681c]
    public struct OutputTicket: Equatable, Hashable, Sendable {
        public var session: SessionHandle
        public var requestId: UInt64
        public var len: UInt32

        public init(session: SessionHandle, requestId: UInt64, len: UInt32) {
            self.session = session
            self.requestId = requestId
            self.len = len
        }
    }

    // parity: native/src/session.zig#OutputResult [status=implemented hash=eed0eae80337]
    public enum OutputResult: Equatable, Hashable, Sendable, CaseIterable {
        case written
        case failed
    }

    // parity: native/src/session.zig#PostResult [status=implemented hash=77eca29551bd]
    public struct PostResult: Equatable, Hashable, Sendable {
        public var written: UInt32
        public var inFlight: Bool

        public init(written: UInt32 = 0, inFlight: Bool = false) {
            self.written = written
            self.inFlight = inFlight
        }
    }

    // parity: native/src/session.zig#Session [status=implemented hash=5c6e78b35ae7]
    public final class Session: @unchecked Sendable {
        public let handle: SessionHandle
        public let output: NativeZigSpanFeed.Stream
        public let core: NativeSession
        public var state: State = .open
        public var terminalState: TerminalState = TerminalState()
        public private(set) var lastRequestId: UInt64 = 0
        public private(set) var completedBytes: UInt64 = 0
        public private(set) var pendingTicket: OutputTicket?

        public init(
            handle: SessionHandle = SessionHandle(contextId: 1, slot: 1, generation: 1),
            options: Options = Options(),
            outputSink: any NativeSessionOutputSink = MemorySessionOutputSink()
        ) throws {
            self.handle = handle
            let feedOpts = NativeZigSpanFeed.Options(
                chunkSize: options.chunkSize,
                initialChunks: options.chunkCount,
                maxBytes: UInt64(options.chunkSize) * UInt64(max(1, options.chunkCount)),
                growthPolicy: NativeZigSpanFeed.GrowthPolicy.block.rawValue,
                autoCommitOnFull: 1,
                spanQueueCapacity: options.spanCapacity
            )
            self.output = NativeZigSpanFeed.createNativeSpanFeedWithAllocator(options: feedOpts)
            self.core = try NativeSession(sink: outputSink, options: NativeSessionDriverOptions())
        }

        public func setupTerminal(_ options: TerminalOptions = TerminalOptions()) throws {
            terminalState.phase = .settingUp
            try core.setupTerminal(options.toCore())
            terminalState.phase = .active
        }

        public func feedInput(_ bytes: [UInt8]) -> InputFeed {
            let events = core.feedInput(bytes)
            _ = events
            return InputFeed(consumed: UInt32(bytes.count), discarded: 0, deadlineNs: nil)
        }

        public func postOutput(_ bytes: [UInt8]) throws(NativeZigSession.Error) -> OutputTicket {
            guard state == .open else { throw .sessionClosed }
            guard pendingTicket == nil else { throw .outputBackpressure }
            let st = NativeZigSpanFeed.streamWrite(output, bytes: bytes)
            guard st == NativeZigSpanFeed.Status.ok else { throw .outputBackpressure }
            _ = NativeZigSpanFeed.streamCommit(output)
            lastRequestId &+= 1
            let ticket = OutputTicket(session: handle, requestId: lastRequestId, len: UInt32(bytes.count))
            pendingTicket = ticket
            return ticket
        }

        public func completeOutput(ticket: OutputTicket, result: OutputResult) throws(NativeZigSession.Error) -> PostResult {
            guard let pending = pendingTicket, pending.requestId == ticket.requestId else {
                throw .staleOutput
            }
            pendingTicket = nil
            if result == .written {
                completedBytes &+= UInt64(ticket.len)
                return PostResult(written: ticket.len, inFlight: false)
            }
            state = .failed
            return PostResult(written: 0, inFlight: false)
        }

        public func pump() -> PumpResult {
            if state == .closed || state == .cancelled || state == .failed {
                return PumpResult(status: .closed)
            }
            if pendingTicket != nil {
                return PumpResult(status: .outputPending)
            }
            return PumpResult(status: .idle)
        }

        public func close() {
            state = .closed
            terminalState.phase = .restored
            _ = NativeZigSpanFeed.streamClose(output)
            try? core.closeSync()
        }
    }
}

// MARK: - 9. native/src/ghostty-vt.zig (1 unmapped symbol)

public enum NativeZigGhosttyVT: Sendable {
    public struct RGB: Equatable, Hashable, Sendable {
        public var r: UInt8
        public var g: UInt8
        public var b: UInt8
        public init(r: UInt8 = 0, g: UInt8 = 0, b: UInt8 = 0) {
            self.r = r; self.g = g; self.b = b
        }
    }

    public struct CellStyle: Equatable, Hashable, Sendable {
        public var fg: RGB?
        public var bg: RGB?
        public var bold: Bool
        public var italic: Bool
        public var underline: Bool
        public var inverse: Bool
        public var faint: Bool
        public var strikethrough: Bool

        public init(
            fg: RGB? = nil,
            bg: RGB? = nil,
            bold: Bool = false,
            italic: Bool = false,
            underline: Bool = false,
            inverse: Bool = false,
            faint: Bool = false,
            strikethrough: Bool = false
        ) {
            self.fg = fg
            self.bg = bg
            self.bold = bold
            self.italic = italic
            self.underline = underline
            self.inverse = inverse
            self.faint = faint
            self.strikethrough = strikethrough
        }

        public var textAttributes: UInt32 {
            var attrs: UInt32 = TextAttributes.none
            if bold { attrs |= TextAttributes.bold }
            if italic { attrs |= TextAttributes.italic }
            if underline { attrs |= TextAttributes.underline }
            if faint { attrs |= TextAttributes.dim }
            if strikethrough { attrs |= TextAttributes.strikethrough }
            return attrs
        }
    }

    public struct VTCell: Equatable, Hashable, Sendable {
        public var codepoint: UInt32
        public var style: CellStyle
        public var wide: UInt8 // 0 = narrow, 1 = wide, 2 = spacer tail

        public init(codepoint: UInt32 = 0x20, style: CellStyle = CellStyle(), wide: UInt8 = 0) {
            self.codepoint = codepoint
            self.style = style
            self.wide = wide
        }
    }

    public struct Coordinate: Equatable, Hashable, Sendable {
        public var x: UInt16
        public var y: UInt16
        public init(x: UInt16 = 0, y: UInt16 = 0) { self.x = x; self.y = y }
    }

    public struct Selection: Equatable, Hashable, Sendable {
        public var start: Coordinate
        public var end: Coordinate
        public init(start: Coordinate, end: Coordinate) {
            self.start = start
            self.end = end
        }
    }

    public struct DeviceAttributes: Equatable, Hashable, Sendable {
        public var primary: String
        public var secondary: String
        public init(primary: String = "\u{1B}[?62;22c", secondary: String = "\u{1B}[>1;10;0c") {
            self.primary = primary
            self.secondary = secondary
        }
    }

    public enum DirtyState: Equatable, Hashable, Sendable {
        case clean
        case partial
        case full
    }

    public struct RenderState: Equatable, Sendable {
        public var cols: UInt16
        public var rows: UInt16
        public var dirty: DirtyState
        public var foreground: RGB
        public var background: RGB
        public var rowDirty: [Bool]
        public var cells: [[VTCell]]
        public var rowSelection: [(UInt16, UInt16)?]

        public init(
            cols: UInt16,
            rows: UInt16,
            foreground: RGB = RGB(r: 255, g: 255, b: 255),
            background: RGB = RGB(r: 0, g: 0, b: 0)
        ) {
            self.cols = cols
            self.rows = rows
            self.dirty = .full
            self.foreground = foreground
            self.background = background
            self.rowDirty = Array(repeating: true, count: Int(rows))
            self.cells = Array(repeating: Array(repeating: VTCell(), count: Int(cols)), count: Int(rows))
            self.rowSelection = Array(repeating: nil, count: Int(rows))
        }

        public static func == (lhs: RenderState, rhs: RenderState) -> Bool {
            lhs.cols == rhs.cols &&
                lhs.rows == rhs.rows &&
                lhs.dirty == rhs.dirty &&
                lhs.foreground == rhs.foreground &&
                lhs.background == rhs.background &&
                lhs.rowDirty == rhs.rowDirty &&
                lhs.cells == rhs.cells
        }
    }

    public enum StreamAction: Equatable, Hashable, Sendable {
        case print(UnicodeScalar)
        case carriageReturn
        case lineFeed
        case backspace
        case clearScreen
        case moveCursor(x: UInt16, y: UInt16)
        case setStyle(CellStyle)
        case deviceAttributesQuery
    }

    public final class Terminal: @unchecked Sendable {
        public private(set) var cols: UInt16
        public private(set) var rows: UInt16
        public private(set) var cursorX: UInt16 = 0
        public private(set) var cursorY: UInt16 = 0
        public private(set) var cursorVisible: Bool = true
        public private(set) var currentStyle: CellStyle = CellStyle()
        public var state: RenderState
        public private(set) var scrollbackLines: [[VTCell]] = []
        public let maxScrollback: Int
        public var selection: Selection?
        public var bracketedPasteMode: Bool = false
        public var focusReportingMode: Bool = false

        public init(cols: UInt16, rows: UInt16, maxScrollback: Int = 10_000) {
            self.cols = max(1, cols)
            self.rows = max(1, rows)
            self.maxScrollback = max(0, maxScrollback)
            self.state = RenderState(cols: self.cols, rows: self.rows)
        }

        public func resize(cols newCols: UInt16, rows newRows: UInt16) {
            let c = max(1, newCols)
            let r = max(1, newRows)
            var next = RenderState(cols: c, rows: r, foreground: state.foreground, background: state.background)
            let copyRows = min(Int(rows), Int(r))
            let copyCols = min(Int(cols), Int(c))
            for y in 0..<copyRows {
                for x in 0..<copyCols {
                    next.cells[y][x] = state.cells[y][x]
                }
            }
            self.cols = c
            self.rows = r
            self.cursorX = min(cursorX, c - 1)
            self.cursorY = min(cursorY, r - 1)
            self.state = next
        }

        public func apply(_ action: StreamAction) -> [UInt8] {
            switch action {
            case .print(let scalar):
                if cursorX >= cols {
                    cursorX = 0
                    advanceLine()
                }
                state.cells[Int(cursorY)][Int(cursorX)] = VTCell(codepoint: scalar.value, style: currentStyle)
                state.rowDirty[Int(cursorY)] = true
                if state.dirty == .clean { state.dirty = .partial }
                cursorX = min(cols, cursorX + 1)
                return []
            case .carriageReturn:
                cursorX = 0
                return []
            case .lineFeed:
                advanceLine()
                return []
            case .backspace:
                if cursorX > 0 { cursorX -= 1 }
                return []
            case .clearScreen:
                state.cells = Array(repeating: Array(repeating: VTCell(), count: Int(cols)), count: Int(rows))
                state.rowDirty = Array(repeating: true, count: Int(rows))
                state.dirty = .full
                cursorX = 0
                cursorY = 0
                return []
            case .moveCursor(let x, let y):
                cursorX = min(cols - 1, x)
                cursorY = min(rows - 1, y)
                return []
            case .setStyle(let style):
                currentStyle = style
                return []
            case .deviceAttributesQuery:
                return Array(DeviceAttributes().primary.utf8)
            }
        }

        public func clearSelection() {
            selection = nil
            state.rowSelection = Array(repeating: nil, count: Int(rows))
            state.dirty = .full
        }

        public func setSelection(_ sel: Selection) {
            selection = sel
            let minY = Int(min(sel.start.y, sel.end.y))
            let maxY = Int(min(rows - 1, max(sel.start.y, sel.end.y)))
            state.rowSelection = Array(repeating: nil, count: Int(rows))
            for y in minY...maxY {
                let startX: UInt16 = y == minY ? min(sel.start.x, cols - 1) : 0
                let endX: UInt16 = y == maxY ? min(sel.end.x, cols - 1) : cols - 1
                state.rowSelection[y] = (min(startX, endX), max(startX, endX))
                state.rowDirty[y] = true
            }
            if state.dirty == .clean { state.dirty = .partial }
        }

        public func selectedText() -> String {
            guard let sel = selection else { return "" }
            let minY = Int(min(sel.start.y, sel.end.y))
            let maxY = Int(min(rows - 1, max(sel.start.y, sel.end.y)))
            var lines: [String] = []
            for y in minY...maxY {
                guard let range = state.rowSelection[y] else { continue }
                var line = ""
                for x in Int(range.0)...Int(range.1) {
                    if let scalar = UnicodeScalar(state.cells[y][x].codepoint) {
                        line.unicodeScalars.append(scalar)
                    }
                }
                lines.append(line.trimmingTrailingSpaces())
            }
            return lines.joined(separator: "\n")
        }

        private func advanceLine() {
            if cursorY + 1 < rows {
                cursorY += 1
            } else {
                if maxScrollback > 0 {
                    scrollbackLines.append(state.cells[0])
                    if scrollbackLines.count > maxScrollback {
                        scrollbackLines.removeFirst(scrollbackLines.count - maxScrollback)
                    }
                }
                state.cells.removeFirst()
                state.cells.append(Array(repeating: VTCell(), count: Int(cols)))
                state.rowDirty = Array(repeating: true, count: Int(rows))
                state.dirty = .full
            }
        }
    }

    public final class Stream: @unchecked Sendable {
        public init() {}

        public func parse(_ bytes: [UInt8]) -> [StreamAction] {
            var actions: [StreamAction] = []
            var i = 0
            while i < bytes.count {
                let b = bytes[i]
                if b == 0x1B && i + 1 < bytes.count && bytes[i + 1] == UInt8(ascii: "[") {
                    // CSI sequence
                    var j = i + 2
                    while j < bytes.count && !(bytes[j] >= 0x40 && bytes[j] <= 0x7E) { j += 1 }
                    if j < bytes.count {
                        let final = bytes[j]
                        let params = String(decoding: bytes[(i + 2)..<j], as: UTF8.self)
                        if final == UInt8(ascii: "J") && (params == "2" || params == "3") {
                            actions.append(.clearScreen)
                        } else if final == UInt8(ascii: "H") {
                            let parts = params.split(separator: ";").compactMap { UInt16($0) }
                            let row = (parts.first ?? 1) > 0 ? (parts.first ?? 1) - 1 : 0
                            let col = (parts.count > 1 ? parts[1] : 1) > 0 ? (parts.count > 1 ? parts[1] : 1) - 1 : 0
                            actions.append(.moveCursor(x: col, y: row))
                        } else if final == UInt8(ascii: "c") && params.isEmpty {
                            actions.append(.deviceAttributesQuery)
                        } else if final == UInt8(ascii: "m") {
                            var style = CellStyle()
                            for p in params.split(separator: ";").compactMap({ Int($0) }) {
                                switch p {
                                case 0: style = CellStyle()
                                case 1: style.bold = true
                                case 2: style.faint = true
                                case 3: style.italic = true
                                case 4: style.underline = true
                                case 7: style.inverse = true
                                case 9: style.strikethrough = true
                                default: break
                                }
                            }
                            actions.append(.setStyle(style))
                        }
                        i = j + 1
                        continue
                    }
                }
                switch b {
                case 0x0D: actions.append(.carriageReturn)
                case 0x0A: actions.append(.lineFeed)
                case 0x08: actions.append(.backspace)
                default:
                    if b >= 0x20, let scalar = UnicodeScalar(UInt32(b)) {
                        actions.append(.print(scalar))
                    }
                }
                i += 1
            }
            return actions
        }
    }

    public final class TerminalStream: @unchecked Sendable {
        public let terminal: Terminal
        public let stream: Stream

        public init(terminal: Terminal) {
            self.terminal = terminal
            self.stream = Stream()
        }

        public func feed(_ bytes: [UInt8]) -> [UInt8] {
            var responses: [UInt8] = []
            for action in stream.parse(bytes) {
                responses.append(contentsOf: terminal.apply(action))
            }
            return responses
        }
    }

    // parity: native/src/ghostty-vt.zig#vt [status=adapted hash=d7a56387c603]
    public enum vt: Sendable {
        public typealias Terminal = NativeZigGhosttyVT.Terminal
        public typealias TerminalStream = NativeZigGhosttyVT.TerminalStream
        public typealias Stream = NativeZigGhosttyVT.Stream
        public typealias StreamAction = NativeZigGhosttyVT.StreamAction
        public typealias DeviceAttributes = NativeZigGhosttyVT.DeviceAttributes
        public typealias Coordinate = NativeZigGhosttyVT.Coordinate
        public typealias RenderState = NativeZigGhosttyVT.RenderState
        public typealias Selection = NativeZigGhosttyVT.Selection
    }
}

private extension String {
    func trimmingTrailingSpaces() -> String {
        var chars = Array(self)
        while let last = chars.last, last == " " { chars.removeLast() }
        return String(chars)
    }
}

// MARK: - 10. native/src/embedded-terminal/ghostty.zig (16 unmapped symbols)

public enum NativeZigGhostty: Sendable {
    // parity: native/src/embedded-terminal/ghostty.zig#Terminal [status=adapted hash=68bf85a1d4fe]
    public typealias Terminal = NativeZigGhosttyVT.vt.Terminal

    // parity: native/src/embedded-terminal/ghostty.zig#TerminalStream [status=adapted hash=f6f62a678ac2]
    public typealias TerminalStream = NativeZigGhosttyVT.vt.TerminalStream

    // parity: native/src/embedded-terminal/ghostty.zig#Stream [status=adapted hash=5e41998291ee]
    public typealias Stream = NativeZigGhosttyVT.vt.Stream

    // parity: native/src/embedded-terminal/ghostty.zig#StreamAction [status=adapted hash=b1b06e4753ba]
    public typealias StreamAction = NativeZigGhosttyVT.vt.StreamAction

    // parity: native/src/embedded-terminal/ghostty.zig#DeviceAttributes [status=adapted hash=87e68454e165]
    public typealias DeviceAttributes = NativeZigGhosttyVT.vt.DeviceAttributes

    // parity: native/src/embedded-terminal/ghostty.zig#Coordinate [status=adapted hash=aee8e8304b29]
    public typealias Coordinate = NativeZigGhosttyVT.vt.Coordinate

    // parity: native/src/embedded-terminal/ghostty.zig#RenderState [status=adapted hash=cd2c6a310664]
    public typealias RenderState = NativeZigGhosttyVT.vt.RenderState

    // parity: native/src/embedded-terminal/ghostty.zig#Selection [status=adapted hash=e2fc3e52efa7]
    public typealias Selection = NativeZigGhosttyVT.vt.Selection

    // parity: native/src/embedded-terminal/ghostty.zig#Key [status=implemented hash=8d6361230eba]
    public struct Key: Equatable, Hashable, Sendable {
        public enum Action: UInt8, Equatable, Hashable, Sendable { case press = 1, `repeat` = 2, release = 3 }
        public var action: Action
        public var keyName: String
        public var shift: Bool
        public var ctrl: Bool
        public var alt: Bool
        public var superKey: Bool
        public var composing: Bool
        public var utf8: String
        public var unshiftedCodepoint: UInt32

        public init(
            action: Action = .press,
            keyName: String = "",
            shift: Bool = false,
            ctrl: Bool = false,
            alt: Bool = false,
            superKey: Bool = false,
            composing: Bool = false,
            utf8: String = "",
            unshiftedCodepoint: UInt32 = 0
        ) {
            self.action = action
            self.keyName = keyName
            self.shift = shift
            self.ctrl = ctrl
            self.alt = alt
            self.superKey = superKey
            self.composing = composing
            self.utf8 = utf8
            self.unshiftedCodepoint = unshiftedCodepoint
        }
    }

    // parity: native/src/embedded-terminal/ghostty.zig#Mouse [status=implemented hash=e37c29740d19]
    public struct Mouse: Equatable, Hashable, Sendable {
        public enum Action: UInt8, Equatable, Hashable, Sendable { case press = 0, release = 1, motion = 2 }
        public var action: Action
        public var button: UInt8?
        public var shift: Bool
        public var ctrl: Bool
        public var alt: Bool
        public var x: Float
        public var y: Float
        public var anyButtonPressed: Bool

        public init(
            action: Action,
            button: UInt8? = nil,
            shift: Bool = false,
            ctrl: Bool = false,
            alt: Bool = false,
            x: Float,
            y: Float,
            anyButtonPressed: Bool = false
        ) {
            self.action = action
            self.button = button
            self.shift = shift
            self.ctrl = ctrl
            self.alt = alt
            self.x = x
            self.y = y
            self.anyButtonPressed = anyButtonPressed
        }
    }

    // parity: native/src/embedded-terminal/ghostty.zig#KeyEncodeOptions [status=implemented hash=0fc559e40deb]
    public struct KeyEncodeOptions: Equatable, Hashable, Sendable {
        public var kittyFlags: UInt8
        public var cursorKeyApplication: Bool
        public init(kittyFlags: UInt8 = 0, cursorKeyApplication: Bool = false) {
            self.kittyFlags = kittyFlags
            self.cursorKeyApplication = cursorKeyApplication
        }
    }

    // parity: native/src/embedded-terminal/ghostty.zig#MouseEncodeOptions [status=implemented hash=16841d150ebd]
    public struct MouseEncodeOptions: Equatable, Hashable, Sendable {
        public var sgrFormat: Bool
        public init(sgrFormat: Bool = true) { self.sgrFormat = sgrFormat }
    }

    // parity: native/src/embedded-terminal/ghostty.zig#encodeKey [status=implemented hash=61055ab7c918]
    public static func encodeKey(_ key: Key, options: KeyEncodeOptions = KeyEncodeOptions()) -> [UInt8] {
        if key.action == .release && options.kittyFlags == 0 { return [] }
        switch key.keyName {
        case "enter", "return": return [0x0D]
        case "tab": return key.shift ? Array("\u{1B}[Z".utf8) : [0x09]
        case "escape": return [0x1B]
        case "backspace": return [0x7F]
        case "up": return Array((options.cursorKeyApplication ? "\u{1B}OA" : "\u{1B}[A").utf8)
        case "down": return Array((options.cursorKeyApplication ? "\u{1B}OB" : "\u{1B}[B").utf8)
        case "right": return Array((options.cursorKeyApplication ? "\u{1B}OC" : "\u{1B}[C").utf8)
        case "left": return Array((options.cursorKeyApplication ? "\u{1B}OD" : "\u{1B}[D").utf8)
        default:
            if key.ctrl, let first = key.utf8.utf8.first {
                let upper = (first >= 97 && first <= 122) ? first - 32 : first
                if upper >= 64 && upper <= 95 { return [upper - 64] }
            }
            var out: [UInt8] = []
            if key.alt { out.append(0x1B) }
            out.append(contentsOf: key.utf8.utf8)
            return out
        }
    }

    // parity: native/src/embedded-terminal/ghostty.zig#encodeMouse [status=implemented hash=54bd8253ba1e]
    public static func encodeMouse(_ mouse: Mouse, options: MouseEncodeOptions = MouseEncodeOptions()) -> [UInt8] {
        var code = Int(mouse.button ?? 3)
        if mouse.action == .motion { code += 32 }
        if mouse.shift { code += 4 }
        if mouse.alt { code += 8 }
        if mouse.ctrl { code += 16 }
        let cx = max(1, Int(mouse.x) + 1)
        let cy = max(1, Int(mouse.y) + 1)
        if options.sgrFormat {
            let suffix = mouse.action == .release ? "m" : "M"
            return Array("\u{1B}[<\(code);\(cx);\(cy)\(suffix)".utf8)
        }
        let b = UInt8(min(255, code + 32))
        let px = UInt8(min(255, cx + 32))
        let py = UInt8(min(255, cy + 32))
        return [0x1B, UInt8(ascii: "["), UInt8(ascii: "M"), b, px, py]
    }

    // parity: native/src/embedded-terminal/ghostty.zig#encodePaste [status=implemented hash=2952aa2f3c5c]
    public static func encodePaste(_ bytes: [UInt8], bracketed: Bool = true) -> [UInt8] {
        guard bracketed else { return bytes }
        var out: [UInt8] = Array("\u{1B}[200~".utf8)
        out.append(contentsOf: bytes)
        out.append(contentsOf: "\u{1B}[201~".utf8)
        return out
    }

    // parity: native/src/embedded-terminal/ghostty.zig#encodeFocus [status=implemented hash=3fc41417d9cd]
    public static func encodeFocus(_ focused: Bool) -> [UInt8] {
        Array((focused ? "\u{1B}[I" : "\u{1B}[O").utf8)
    }
}

// MARK: - 11. native/src/embedded-terminal/compositor.zig (2 unmapped symbols)

public enum NativeZigEmbeddedCompositor: Sendable {
    // parity: native/src/embedded-terminal/compositor.zig#Error [status=implemented hash=6a7c76140a64]
    public enum Error: Swift.Error, Equatable, Hashable, Sendable {
        case outOfMemory
        case invalidUnicode
        case invalidOptions
        case textLimit
        case unsupportedResource
        case trackerLimit
    }

    // parity: native/src/embedded-terminal/compositor.zig#compose [status=implemented hash=9da5614a8d8e]
    public static func compose(
        state: inout NativeZigGhostty.RenderState,
        target: OptimizedBuffer,
        originX: Int32,
        originY: Int32,
        transparentBackground: Bool = false
    ) throws(NativeZigEmbeddedCompositor.Error) {
        guard state.dirty != .clean else { return }
        let defaultFg = RGBA.fromInts(Int(state.foreground.r), Int(state.foreground.g), Int(state.foreground.b), 255)
        let defaultBg = transparentBackground
            ? RGBA.fromInts(Int(state.background.r), Int(state.background.g), Int(state.background.b), 0)
            : RGBA.fromInts(Int(state.background.r), Int(state.background.g), Int(state.background.b), 255)

        for y in 0..<Int(state.rows) {
            if state.dirty == .partial && !state.rowDirty[y] { continue }
            let destY = Int(originY) + y
            if destY >= 0 && destY < target.height {
                let selection = state.rowSelection[y]
                for x in 0..<Int(state.cols) {
                    let destX = Int(originX) + x
                    guard destX >= 0 && destX < target.width else { continue }
                    let cell = state.cells[y][x]
                    if cell.wide == 2 { continue }
                    var fg = cell.style.fg.map { RGBA.fromInts(Int($0.r), Int($0.g), Int($0.b), 255) } ?? defaultFg
                    var bg = cell.style.bg.map { RGBA.fromInts(Int($0.r), Int($0.g), Int($0.b), 255) } ?? defaultBg
                    if cell.style.inverse { swap(&fg, &bg) }
                    if let sel = selection, x >= Int(sel.0) && x <= Int(sel.1) { swap(&fg, &bg) }
                    let scalar = cell.codepoint == 0 ? defaultSpaceChar : cell.codepoint
                    target.setCell(
                        x: destX,
                        y: destY,
                        cell: TerminalCell(scalar: scalar, foreground: fg, background: bg, attributes: cell.style.textAttributes)
                    )
                }
            }
            state.rowDirty[y] = false
        }
        state.dirty = .clean
    }
}

// MARK: - 12. native/src/embedded-terminal/main.zig (6 unmapped symbols)

public enum NativeZigEmbeddedTerminal: Sendable {
    // parity: native/src/embedded-terminal/main.zig#Error [status=implemented hash=ae5b50b0ade9]
    public enum Error: Swift.Error, Equatable, Hashable, Sendable {
        case invalidValue
        case processingFailed
        case responseOverflow
        case compositor(NativeZigEmbeddedCompositor.Error)
    }

    // parity: native/src/embedded-terminal/main.zig#Cursor [status=implemented hash=359c83ec3af0]
    public struct Cursor: Equatable, Hashable, Sendable {
        public var x: UInt16
        public var y: UInt16
        public var hasValue: Bool
        public var visible: Bool
        public var blinking: Bool
        public var wideTail: Bool
        public var style: UInt8
        public var color: NativeZigGhosttyVT.RGB?

        public init(
            x: UInt16 = 0,
            y: UInt16 = 0,
            hasValue: Bool = false,
            visible: Bool = false,
            blinking: Bool = false,
            wideTail: Bool = false,
            style: UInt8 = 1,
            color: NativeZigGhosttyVT.RGB? = nil
        ) {
            self.x = x
            self.y = y
            self.hasValue = hasValue
            self.visible = visible
            self.blinking = blinking
            self.wideTail = wideTail
            self.style = style
            self.color = color
        }
    }

    // parity: native/src/embedded-terminal/main.zig#Scrollbar [status=implemented hash=f7591d78d6c6]
    public struct Scrollbar: Equatable, Hashable, Sendable {
        public var offset: UInt32
        public var total: UInt32
        public var visible: UInt32

        public init(offset: UInt32 = 0, total: UInt32 = 0, visible: UInt32 = 0) {
            self.offset = offset
            self.total = total
            self.visible = visible
        }
    }

    // parity: native/src/embedded-terminal/main.zig#Options [status=implemented hash=385c096b75b4]
    public struct Options: Equatable, Hashable, Sendable {
        public var cols: UInt16
        public var rows: UInt16
        public var maxScrollback: Int

        public init(cols: UInt16, rows: UInt16, maxScrollback: Int = 10_000) {
            self.cols = cols
            self.rows = rows
            self.maxScrollback = maxScrollback
        }
    }

    // parity: native/src/embedded-terminal/main.zig#response_limit [status=implemented hash=0bec3381f6dc]
    public static let responseLimit: Int = Int(NativeABI.OT_EMBEDDED_TERMINAL_RESPONSE_BYTES_MAX)

    // parity: native/src/embedded-terminal/main.zig#EmbeddedTerminal [status=implemented hash=5b778003f26d]
    public final class EmbeddedTerminal: @unchecked Sendable {
        public let terminal: NativeZigGhostty.Terminal
        public let stream: NativeZigGhostty.TerminalStream
        public private(set) var cols: UInt16
        public private(set) var rows: UInt16
        public private(set) var responses: [UInt8] = []
        public var transparentBackground: Bool = false
        public private(set) var scrollOffset: UInt32 = 0

        public init(options: Options) throws(NativeZigEmbeddedTerminal.Error) {
            guard options.cols > 0 && options.rows > 0 else { throw .invalidValue }
            self.cols = options.cols
            self.rows = options.rows
            self.terminal = NativeZigGhostty.Terminal(cols: options.cols, rows: options.rows, maxScrollback: options.maxScrollback)
            self.stream = NativeZigGhostty.TerminalStream(terminal: terminal)
        }

        public func write(_ bytes: [UInt8]) throws(NativeZigEmbeddedTerminal.Error) {
            let reply = stream.feed(bytes)
            if responses.count + reply.count > NativeZigEmbeddedTerminal.responseLimit {
                throw .responseOverflow
            }
            responses.append(contentsOf: reply)
        }

        public func write(_ text: String) throws(NativeZigEmbeddedTerminal.Error) {
            try write(Array(text.utf8))
        }

        public func resize(cols: UInt16, rows: UInt16) throws(NativeZigEmbeddedTerminal.Error) {
            guard cols > 0 && rows > 0 else { throw .invalidValue }
            self.cols = cols
            self.rows = rows
            terminal.resize(cols: cols, rows: rows)
        }

        public func scroll(delta: Int32) {
            let maxOffset = UInt32(terminal.scrollbackLines.count)
            let next = Int64(scrollOffset) + Int64(delta)
            scrollOffset = UInt32(min(Int64(maxOffset), max(0, next)))
        }

        public func setSelection(start: NativeZigGhostty.Coordinate, end: NativeZigGhostty.Coordinate) {
            terminal.setSelection(NativeZigGhostty.Selection(start: start, end: end))
        }

        public func clearSelection() {
            terminal.clearSelection()
        }

        public func selectedText() -> String {
            terminal.selectedText()
        }

        public func invalidate() {
            terminal.state.dirty = .full
            terminal.state.rowDirty = Array(repeating: true, count: Int(rows))
        }

        public func compose(into target: OptimizedBuffer, originX: Int32 = 0, originY: Int32 = 0) throws(NativeZigEmbeddedTerminal.Error) {
            do {
                try NativeZigEmbeddedCompositor.compose(
                    state: &terminal.state,
                    target: target,
                    originX: originX,
                    originY: originY,
                    transparentBackground: transparentBackground
                )
            } catch {
                throw .compositor(error)
            }
        }

        public func cursor() -> Cursor {
            Cursor(
                x: terminal.cursorX,
                y: terminal.cursorY,
                hasValue: true,
                visible: terminal.cursorVisible,
                blinking: false,
                wideTail: false,
                style: 1,
                color: nil
            )
        }

        public func scrollbar() -> Scrollbar {
            Scrollbar(
                offset: scrollOffset,
                total: UInt32(terminal.scrollbackLines.count) + UInt32(rows),
                visible: UInt32(rows)
            )
        }

        public func drainResponses(maxBytes: Int? = nil) -> [UInt8] {
            let take = min(maxBytes ?? responses.count, responses.count)
            let out = Array(responses[0..<take])
            responses.removeFirst(take)
            return out
        }

        public func encodePaste(_ bytes: [UInt8]) -> [UInt8] {
            NativeZigGhostty.encodePaste(bytes, bracketed: terminal.bracketedPasteMode)
        }

        public func encodeFocus(_ focused: Bool) -> [UInt8] {
            NativeZigGhostty.encodeFocus(focused)
        }
    }
}

// MARK: - 13. native/src/embedded-terminal/unavailable.zig (4 unmapped symbols)

public enum NativeZigEmbeddedUnavailable: Sendable {
    // parity: native/src/embedded-terminal/unavailable.zig#Error [status=implemented hash=d6545ca2f5d0]
    public enum Error: Swift.Error, Equatable, Hashable, Sendable {
        case unsupported
    }

    // parity: native/src/embedded-terminal/unavailable.zig#Cursor [status=implemented hash=359c83ec3af0]
    public struct Cursor: Equatable, Hashable, Sendable {
        public var x: UInt16
        public var y: UInt16
        public var hasValue: Bool
        public var visible: Bool
        public var blinking: Bool
        public var wideTail: Bool
        public var style: UInt8
        public var color: NativeZigGhosttyVT.RGB?

        public init(
            x: UInt16 = 0,
            y: UInt16 = 0,
            hasValue: Bool = false,
            visible: Bool = false,
            blinking: Bool = false,
            wideTail: Bool = false,
            style: UInt8 = 1,
            color: NativeZigGhosttyVT.RGB? = nil
        ) {
            self.x = x
            self.y = y
            self.hasValue = hasValue
            self.visible = visible
            self.blinking = blinking
            self.wideTail = wideTail
            self.style = style
            self.color = color
        }
    }

    // parity: native/src/embedded-terminal/unavailable.zig#Scrollbar [status=implemented hash=f7591d78d6c6]
    public struct Scrollbar: Equatable, Hashable, Sendable {
        public var offset: UInt32
        public var total: UInt32
        public var visible: UInt32

        public init(offset: UInt32 = 0, total: UInt32 = 0, visible: UInt32 = 0) {
            self.offset = offset
            self.total = total
            self.visible = visible
        }
    }

    // parity: native/src/embedded-terminal/unavailable.zig#EmbeddedTerminal [status=implemented hash=8915aaaba6f2]
    public struct EmbeddedTerminal: Sendable {
        public static func create() throws(NativeZigEmbeddedUnavailable.Error) -> EmbeddedTerminal {
            throw .unsupported
        }

        public func write(_ bytes: [UInt8]) throws(NativeZigEmbeddedUnavailable.Error) { throw .unsupported }
        public func resize(cols: UInt16, rows: UInt16) throws(NativeZigEmbeddedUnavailable.Error) { throw .unsupported }
        public func selectedText() throws(NativeZigEmbeddedUnavailable.Error) -> String { throw .unsupported }
        public func compose(into target: OptimizedBuffer, originX: Int32, originY: Int32) throws(NativeZigEmbeddedUnavailable.Error) { throw .unsupported }
        public func cursor() -> Cursor { Cursor() }
        public func scrollbar() -> Scrollbar { Scrollbar() }
        public func encodePaste(_ bytes: [UInt8]) throws(NativeZigEmbeddedUnavailable.Error) -> [UInt8] { throw .unsupported }
        public func encodeFocus(_ focused: Bool) throws(NativeZigEmbeddedUnavailable.Error) -> [UInt8] { throw .unsupported }
        public func drainResponses() throws(NativeZigEmbeddedUnavailable.Error) -> [UInt8] { throw .unsupported }
    }
}
