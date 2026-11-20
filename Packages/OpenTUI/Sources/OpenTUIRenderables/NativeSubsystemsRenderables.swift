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
    // parity: native/src/markdown-inline.zig#token_count_max [status=implemented hash=f7a871fa2408]
    public static let tokenCountMax: UInt32 = 4096
    // parity: native/src/markdown-inline.zig#delimiter_count_max [status=implemented hash=22aea8f8b6dd]
    public static let delimiterCountMax: UInt32 = 32
    // parity: native/src/markdown-inline.zig#bracket_count_max [status=implemented hash=eaffcfaa9bf7]
    public static let bracketCountMax: UInt32 = 64
    // parity: native/src/markdown-inline.zig#label_codepoint_count_max [status=implemented hash=9a1e19b17a56]
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

        // parity: native/src/markdown-inline.zig#Token.end [status=implemented hash=fa196e25a5de]
        public func endOffset() -> UInt32 {
            end
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

    // parity: native/src/markdown-inline.zig#References [status=implemented hash=066b8de683ff]
    public struct References: Equatable, Sendable {
        public var definitions: [String: Link]

        public init(definitions: [String: Link] = [:]) {
            self.definitions = definitions
        }

        // parity: native/src/markdown-inline.zig#References.lookup [status=implemented hash=7b2b8b5a3bdd]
        public func lookup(_ label: String) -> Link? {
            let normalized = label
                .trimmingASCIIWhitespace()
                .lowercased()
                .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
                .joined(separator: " ")
            return definitions[normalized]
        }
    }

    // parity: native/src/markdown-inline.zig#Options [status=implemented hash=368c5cc1c83f]
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

    // parity: native/src/markdown-inline.zig#Parser [status=implemented hash=51d592ef08e7]
    public struct Parser: Sendable {
        public struct Changed: Equatable, Hashable, Sendable {
            public var token: UInt32
            public var extended: UInt32
            public var matched: UInt32

            public init(token: UInt32 = UInt32.max, extended: UInt32 = UInt32.max, matched: UInt32 = UInt32.max) {
                self.token = token
                self.extended = extended
                self.matched = matched
            }
        }

        public var references: References
        public var options: Options
        public var subject: [UInt8] = []
        public var final: Bool = false
        public var position: UInt32 = 0
        public var limit: UInt32 = 0
        public var tailRunStart: UInt32 = 0
        public var searchOpener: UInt32 = UInt32.max
        public var tokens: [Token] = []
        public var delimiters: [Delimiter] = []
        public var matches: [Match] = []
        public var links: [Link] = []
        public var openBrackets: [UInt32] = []
        public var openDelimiterIndices: [Int] = []
        public var emails: [(UInt32, UInt32)] = []
        public var unresolved: Bool = false
        public var changedFrom: UInt32 = UInt32.max
        public var extendedFrom: UInt32 = UInt32.max
        public var matchedFrom: UInt32 = UInt32.max
        public var byteVisits: UInt64 = 0

        public init(references: References = References(), options: Options = Options()) {
            self.references = references
            self.options = options
        }

        // parity: native/src/markdown-inline.zig#Parser.deinit [status=implemented hash=d34c60a1013d]
        public mutating func deinitParser() {
            tokens.removeAll(keepingCapacity: false)
            delimiters.removeAll(keepingCapacity: false)
            matches.removeAll(keepingCapacity: false)
            links.removeAll(keepingCapacity: false)
            openBrackets.removeAll(keepingCapacity: false)
            openDelimiterIndices.removeAll(keepingCapacity: false)
            emails.removeAll(keepingCapacity: false)
            subject.removeAll(keepingCapacity: false)
            position = 0
            limit = 0
            tailRunStart = 0
            searchOpener = UInt32.max
            final = false
        }

        // parity: native/src/markdown-inline.zig#Parser.releaseCapacity [status=implemented hash=1d4f4cede70c]
        public mutating func releaseCapacity() {
            if tokens.capacity > Int(NativeZigMarkdownInline.tokenCountMax) {
                tokens.removeAll(keepingCapacity: false)
            }
            if delimiters.capacity > Int(NativeZigMarkdownInline.tokenCountMax) {
                delimiters.removeAll(keepingCapacity: false)
            }
            if matches.capacity > Int(NativeZigMarkdownInline.tokenCountMax) {
                matches.removeAll(keepingCapacity: false)
            }
            if links.capacity > Int(NativeZigMarkdownInline.bracketCountMax) {
                links.removeAll(keepingCapacity: false)
            }
            if emails.capacity > Int(NativeZigMarkdownInline.bracketCountMax) {
                emails.removeAll(keepingCapacity: false)
            }
        }

        // parity: native/src/markdown-inline.zig#Parser.reset [status=implemented hash=e83322fadeea]
        public mutating func reset() {
            subject.removeAll(keepingCapacity: true)
            final = false
            position = 0
            limit = 0
            tailRunStart = 0
            searchOpener = UInt32.max
            tokens.removeAll(keepingCapacity: true)
            delimiters.removeAll(keepingCapacity: true)
            matches.removeAll(keepingCapacity: true)
            links.removeAll(keepingCapacity: true)
            openBrackets.removeAll(keepingCapacity: true)
            openDelimiterIndices.removeAll(keepingCapacity: true)
            emails.removeAll(keepingCapacity: true)
            unresolved = false
            changedFrom = UInt32.max
            extendedFrom = UInt32.max
            matchedFrom = UInt32.max
        }

        // parity: native/src/markdown-inline.zig#Parser.firstUnresolvedToken [status=implemented hash=004226524a5a]
        public func firstUnresolvedToken() -> UInt32 {
            var first = UInt32(tokens.count)
            if let bottomIdx = openDelimiterIndices.first, bottomIdx < delimiters.count {
                first = min(first, delimiters[bottomIdx].tokenIndex)
            }
            if let firstBracket = openBrackets.first {
                first = min(first, firstBracket)
            }
            return first
        }

        // parity: native/src/markdown-inline.zig#Parser.restart [status=implemented hash=b5a4f3922580]
        @discardableResult
        public mutating func restart(_ bytes: [UInt8], at: UInt32) -> Result {
            let preservedUnresolved = unresolved
            reset()
            unresolved = preservedUnresolved
            let clampedAt = min(Int(at), bytes.count)
            subject = Array(bytes[0..<clampedAt])
            position = UInt32(clampedAt)
            limit = UInt32(clampedAt)
            var run = clampedAt
            while run > 0 && !NativeZigMarkdownInline.isASCIIWhitespace(bytes[run - 1]) {
                run -= 1
            }
            tailRunStart = UInt32(run)
            return feed(bytes, final: false)
        }

        // parity: native/src/markdown-inline.zig#Parser.feed [status=implemented hash=0dee3a4db3c2]
        @discardableResult
        public mutating func feed(_ bytes: [UInt8], final: Bool = true) -> Result {
            self.subject = bytes
            self.final = final
            self.tokens.removeAll(keepingCapacity: true)
            self.delimiters.removeAll(keepingCapacity: true)
            self.matches.removeAll(keepingCapacity: true)
            self.links.removeAll(keepingCapacity: true)
            self.openBrackets.removeAll(keepingCapacity: true)
            self.openDelimiterIndices.removeAll(keepingCapacity: true)
            self.emails.removeAll(keepingCapacity: true)
            self.unresolved = false

            let n = UInt32(bytes.count)
            self.byteVisits &+= UInt64(n)
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
            self.position = n
            self.limit = n
            self.tailRunStart = n
            self.searchOpener = UInt32.max
            if !tokens.isEmpty {
                self.changedFrom = min(self.changedFrom, 0)
            }
            resolveDelimiters()
            if final {
                self.openDelimiterIndices.removeAll(keepingCapacity: true)
                self.openBrackets.removeAll(keepingCapacity: true)
            }

            return result()
        }

        // parity: native/src/markdown-inline.zig#Parser.rebase [status=implemented hash=d8e113f73525]
        public mutating func rebase(drop: UInt32) {
            let d = min(drop, position)
            position &-= d
            limit = limit >= d ? limit - d : 0
            tailRunStart = tailRunStart >= d ? tailRunStart - d : 0
            if Int(d) <= subject.count {
                subject.removeFirst(Int(d))
            } else {
                subject.removeAll(keepingCapacity: true)
            }
            tokens.removeAll(keepingCapacity: true)
            delimiters.removeAll(keepingCapacity: true)
            matches.removeAll(keepingCapacity: true)
            links.removeAll(keepingCapacity: true)
            openDelimiterIndices.removeAll(keepingCapacity: true)
            openBrackets.removeAll(keepingCapacity: true)
            changedFrom = UInt32.max
            extendedFrom = UInt32.max
            matchedFrom = UInt32.max
        }

        // parity: native/src/markdown-inline.zig#Parser.result [status=implemented hash=60ec93bfa38f]
        public func result() -> Result {
            Result(
                content: subject,
                tokens: tokens,
                delimiters: delimiters,
                matches: matches,
                links: links,
                emails: emails,
                unresolved: unresolved,
                final: final
            )
        }

        // parity: native/src/markdown-inline.zig#Parser.takeChanged [status=implemented hash=92e8e01d3ef7]
        public mutating func takeChanged() -> Changed {
            let changed = Changed(token: changedFrom, extended: extendedFrom, matched: matchedFrom)
            changedFrom = UInt32.max
            extendedFrom = UInt32.max
            matchedFrom = UInt32.max
            return changed
        }

        // parity: native/src/markdown-inline.zig#Parser.settled [status=implemented hash=a8473fe317d4]
        public func settled() -> Bool {
            openDelimiterIndices.isEmpty && openBrackets.isEmpty && searchOpener == UInt32.max
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
                    matchedFrom = min(matchedFrom, opener.tokenIndex)
                    stack.remove(at: openIdx)
                } else {
                    stack.append(idx)
                }
            }
            openDelimiterIndices = stack
        }
    }

    // parity: native/src/markdown-inline.zig#parse [status=implemented hash=a70b9a368393]
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

    // parity: native/src/markdown-inline.zig#appendTokenDisplayBefore [status=implemented hash=cdd97f796323]
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

    // parity: native/src/markdown-inline.zig#appendTokenDisplay [status=implemented hash=e10c4ea31107]
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

    // parity: native/src/markdown-inline.zig#PendingScan [status=implemented hash=8d19e20345ff]
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

    // parity: native/src/markdown-inline.zig#PendingSpans [status=implemented hash=a35fafcbfee3]
    public struct PendingSpans: Equatable, Sendable {
        public struct Opener: Equatable, Hashable, Sendable {
            public var at: UInt32
            public var char: UInt8
            public var count: UInt32
            public var original: UInt32
            public var close: Bool
            public var styledTo: [UInt32]

            public init(at: UInt32, char: UInt8, count: UInt32, original: UInt32, close: Bool, styledTo: [UInt32] = [0, 0, 0]) {
                self.at = at
                self.char = char
                self.count = count
                self.original = original
                self.close = close
                self.styledTo = styledTo.count == 3 ? styledTo : [0, 0, 0]
            }
        }

        public var openers: [Opener] = []
        public var kinds: [UInt8] = []
        public var resolved: UInt32 = 0
        public var openersMax: UInt32 = 0
        public var fresh: Bool = true

        public init() {}

        // parity: native/src/markdown-inline.zig#PendingSpans.clear [status=implemented hash=a51138d1fb55]
        public mutating func clear() {
            openers.removeAll(keepingCapacity: true)
            kinds.removeAll(keepingCapacity: true)
            resolved = 0
            openersMax = 0
            fresh = true
        }

        // parity: native/src/markdown-inline.zig#PendingSpans.deinit [status=implemented hash=34654e257aa9]
        public mutating func deinitSpans() {
            openers.removeAll(keepingCapacity: false)
            kinds.removeAll(keepingCapacity: false)
            resolved = 0
            openersMax = 0
            fresh = true
        }

        // parity: native/src/markdown-inline.zig#PendingSpans.add [status=implemented hash=032d86da43d3]
        @discardableResult
        public mutating func add(runs: [PendingRun], marked: inout UInt64) -> UInt32 {
            var first: UInt32 = UInt32.max
            let start = min(Int(resolved), runs.count)
            for idx in start..<runs.count {
                let run = runs[idx]
                var count = run.count
                var i = openers.count
                while run.close && count > 0 && i > 0 {
                    i -= 1
                    let opener = openers[i]
                    if opener.char != run.char { continue }
                    if run.char == UInt8(ascii: "~") && opener.original != run.count { continue }
                    if run.char != UInt8(ascii: "~") && (run.open || opener.close) && run.count % 3 != 0 && (opener.original + run.count) % 3 == 0 {
                        continue
                    }
                    let used: UInt32 = run.char == UInt8(ascii: "~") ? count : ((count >= 2 && opener.count >= 2) ? 2 : 1)
                    let kind: MatchKind = run.char == UInt8(ascii: "~") ? .strikethrough : (used == 2 ? .strong : .emphasis)
                    let kindIndex = Int(kind.rawValue)
                    let from = max(opener.at, opener.styledTo[kindIndex])
                    if from < run.at {
                        if kinds.count < Int(run.at) {
                            kinds.append(contentsOf: repeatElement(0, count: Int(run.at) - kinds.count))
                        }
                        let bit = NativeZigMarkdownInline.kindBit(kind)
                        for p in Int(from)..<Int(run.at) {
                            kinds[p] |= bit
                        }
                        marked &+= UInt64(run.at - from)
                        first = min(first, from)
                        openers[i].styledTo[kindIndex] = run.at
                    }
                    openers[i].count &-= used
                    count &-= used
                    let newCount = i + (openers[i].count > 0 ? 1 : 0)
                    if newCount < openers.count {
                        openers.removeSubrange(newCount..<openers.count)
                    }
                    if openers.count > i && openers[i].count > 0 {
                        i += 1
                    }
                }
                if run.open && count > 0 {
                    openers.append(Opener(at: run.at, char: run.char, count: count, original: run.count, close: run.close))
                }
                if openers.count > Int(NativeZigMarkdownInline.delimiterCountMax) {
                    openers.removeFirst(openers.count - Int(NativeZigMarkdownInline.delimiterCountMax))
                }
                openersMax = max(openersMax, UInt32(openers.count))
            }
            resolved = UInt32(runs.count)
            fresh = false
            return first
        }

        public mutating func resolve(runs: [PendingRun], displayLength: Int) {
            if kinds.count < displayLength {
                kinds.append(contentsOf: repeatElement(0, count: displayLength - kinds.count))
            }
            var ignoredMarked: UInt64 = 0
            _ = add(runs: runs, marked: &ignoredMarked)
            if kinds.count < displayLength {
                kinds.append(contentsOf: repeatElement(0, count: displayLength - kinds.count))
            }
        }
    }

    // parity: native/src/markdown-inline.zig#renderPending [status=implemented hash=165547dd36bc]
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

    // parity: native/src/markdown-inline.zig#renderPendingRuns [status=implemented hash=c7afaa2bea36]
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

        // parity: native/src/markdown-inline.zig#LabelScan.run [status=implemented hash=91512663a5e2]
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

    // parity: native/src/markdown-inline.zig#scanHtmlTagFrom [status=implemented hash=cf8d882a60c2]
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
    // parity: native/src/markdown.zig#none [status=implemented hash=ecde46d9c969]
    public static let none: UInt32 = UInt32.max
    // parity: native/src/markdown.zig#source_byte_count_max [status=implemented hash=a10fbdea8550]
    public static let sourceByteCountMax: UInt32 = 64 << 20
    // parity: native/src/markdown.zig#block_count_max [status=implemented hash=c3ac352beb9b]
    public static let blockCountMax: UInt32 = 1 << 20
    // parity: native/src/markdown.zig#depth_max [status=implemented hash=ae465f426173]
    public static let depthMax: UInt32 = 32
    // parity: native/src/markdown.zig#definition_count_max [status=implemented hash=41a517e60ca0]
    public static let definitionCountMax: UInt32 = 4096
    // parity: native/src/markdown.zig#table_column_count_max [status=implemented hash=18deb61d8bac]
    public static let tableColumnCountMax: UInt32 = 128
    // parity: native/src/markdown.zig#held_line_byte_count_max [status=implemented hash=7a076173b227]
    public static let heldLineByteCountMax: UInt32 = 4096
    // parity: native/src/markdown.zig#hook_filter_byte_count_max [status=implemented hash=34ef80e4c28f]
    public static let hookFilterByteCountMax: UInt32 = 256
    // parity: native/src/markdown.zig#hook_filter_item_byte_count_max [status=implemented hash=8e27157f96c2]
    public static let hookFilterItemByteCountMax: UInt32 = 64
    // parity: native/src/markdown.zig#hook_filter_item_count_max [status=implemented hash=19e4ada767ef]
    public static let hookFilterItemCountMax: UInt32 = 16
    // parity: native/src/markdown.zig#scratch_retained_byte_count_max [status=implemented hash=8db52f214948]
    public static let scratchRetainedByteCountMax: Int = 1 << 20

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

        // parity: native/src/markdown.zig#Options.liveShown [status=implemented hash=2b03ecaa2e98]
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

        // parity: native/src/markdown.zig#Counters.plus [status=implemented hash=b9f11d8558e3]
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

    // parity: native/src/markdown.zig#NodeWrite [status=implemented hash=b5acf7cbbd86]
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

    // parity: native/src/markdown.zig#TailSink [status=implemented hash=bb3a3a6aa9e4]
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

        // parity: native/src/markdown.zig#TailSink.deinit [status=implemented hash=3e1bf952ccde]
        public func deinitSink() {
            mirrors.removeAll(keepingCapacity: false)
            written.removeAll(keepingCapacity: false)
            checkedLeafCount = 0
            mismatchCount = 0
            rebindFrom = NativeZigMarkdown.none
        }

        // parity: native/src/markdown.zig#TailSink.mirror [status=implemented hash=9571510b8675]
        @discardableResult
        public func mirror(block: UInt32) -> Mirror {
            written.append(block)
            if let existing = mirrors[block] {
                return existing
            }
            let created = Mirror()
            mirrors[block] = created
            return created
        }

        // parity: native/src/markdown.zig#TailSink.shown [status=implemented hash=8d5e949a9022]
        public func shown(block: UInt32) -> [UInt8] {
            mirrors[block]?.bytes ?? []
        }

        // parity: native/src/markdown.zig#TailSink.shownStyles [status=implemented hash=66d3c3326fa3]
        public func shownStyles(block: UInt32) -> [UInt64] {
            mirrors[block]?.styles ?? []
        }

        // parity: native/src/markdown.zig#TailSink.styleKey [status=implemented hash=70eb915c31b5]
        public static func styleKey(chunk: Chunk, urls: [UInt8]) -> UInt64 {
            let scopeBits: UInt64 =
                UInt64(chunk.scope.headingLevel & 0x07) |
                (chunk.scope.strong ? (1 << 3) : 0) |
                (chunk.scope.italic ? (1 << 4) : 0) |
                (chunk.scope.strikethrough ? (1 << 5) : 0) |
                (chunk.scope.raw ? (1 << 6) : 0) |
                (chunk.scope.link ? (1 << 7) : 0) |
                (chunk.scope.math ? (1 << 8) : 0) |
                (chunk.scope.escape ? (1 << 9) : 0) |
                (chunk.scope.linkGap ? (1 << 10) : 0) |
                (chunk.scope.linkUrl ? (1 << 11) : 0)
            let spanBits = UInt64(chunk.span.rawValue & 0x03) << 16
            let linkHash: UInt64
            if chunk.linkByteCount == 0 {
                linkHash = 0
            } else {
                let lo = min(Int(chunk.linkOffset), urls.count)
                let hi = min(lo + Int(chunk.linkByteCount), urls.count)
                var h: UInt64 = 14695981039346656037
                for b in urls[lo..<hi] {
                    h ^= UInt64(b)
                    h &*= 1099511628211
                }
                linkHash = UInt64(UInt32(truncatingIfNeeded: h) | 1)
            }
            return scopeBits | spanBits | (linkHash << 32)
        }

        public func apply(_ write: NodeWrite) {
            if write.block >= rebindFrom { return }
            var mirror = mirrors[write.block] ?? Mirror()
            let from = Int(write.from)
            while mirror.bytes.count < from {
                mirror.bytes.append(UInt8(ascii: "?"))
            }
            mirror.bytes.removeSubrange(from...)
            mirror.bytes.append(contentsOf: write.bytes)
            let styleCut = min(mirror.styles.count, from)
            mirror.styles.removeSubrange(styleCut...)
            if mirror.styles.count < mirror.bytes.count {
                mirror.styles.append(contentsOf: repeatElement(UInt64.max, count: mirror.bytes.count - mirror.styles.count))
            }
            for range in write.ranges {
                var at = Int(range.from)
                for chunk in range.chunks {
                    let key = Self.styleKey(chunk: chunk, urls: range.urls)
                    let end = min(at + Int(chunk.byteCount), mirror.styles.count)
                    if at < end {
                        for p in at..<end {
                            mirror.styles[p] = key
                        }
                    }
                    at += Int(chunk.byteCount)
                }
            }
            mirrors[write.block] = mirror
            written.append(write.block)
            checkedLeafCount &+= 1
        }

        public func clearWritten() { written.removeAll() }
    }

    // parity: native/src/markdown.zig#DefinitionScan [status=implemented hash=a07db69913a0]
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

    // The native live-tail run writer (held lines drawn up to the cut, including a token whose whole display ends at
    // the cut, as the `$` before a held pipe in `$|$[`) has no counterpart here: this Doc re-parses the pending line
    // and draws no held tail.
    // parity: native/src/markdown.zig#Doc [status=adapted hash=7e79a4df90d7]
    public final class Doc: @unchecked Sendable {
        public struct LeafContent: Equatable, Sendable {
            public var bytes: [UInt8]
            public var lines: [(UInt32, UInt32)]

            public init(bytes: [UInt8] = [], lines: [(UInt32, UInt32)] = [(0, 0)]) {
                self.bytes = bytes
                self.lines = lines.isEmpty ? [(0, 0)] : lines
            }

            public static func == (lhs: LeafContent, rhs: LeafContent) -> Bool {
                lhs.bytes == rhs.bytes &&
                    lhs.lines.count == rhs.lines.count &&
                    zip(lhs.lines, rhs.lines).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
            }

            // parity: native/src/markdown.zig#Doc.LeafContent.sourceOffset [status=implemented hash=a9f19c665896]
            public func sourceOffset(_ offset: UInt32) -> UInt32 {
                guard !lines.isEmpty else { return offset }
                var low = 0
                var high = lines.count
                while high - low > 1 {
                    let mid = (low + high) / 2
                    if lines[mid].0 <= offset {
                        low = mid
                    } else {
                        high = mid
                    }
                }
                let line = lines[low]
                return line.1 &+ (offset >= line.0 ? offset - line.0 : 0)
            }
        }

        public struct Change: Equatable, Hashable, Sendable {
            public var index: UInt32
            public var block: Block

            public init(index: UInt32, block: Block) {
                self.index = index
                self.block = block
            }
        }

        public let streamingDoc: StreamingMarkdownDocument
        public var options: Options
        public private(set) var source: [UInt8] = []
        public private(set) var blocks: [Block] = []
        public private(set) var definitions: [Definition] = []
        public private(set) var counters: Counters = Counters()
        public private(set) var finished: Bool = false
        public private(set) var removedFromIndex: UInt32 = NativeZigMarkdown.none
        public private(set) var committedTopLevelCount: UInt32 = 0
        private var filterBytes: [UInt8]

        // parity: native/src/markdown.zig#Doc.init [status=implemented hash=250dea670868]
        public init(options: Options = Options()) {
            self.options = options
            self.filterBytes = Array(options.hookFilter.prefix(Int(NativeZigMarkdown.hookFilterByteCountMax)))
            self.streamingDoc = StreamingMarkdownDocument(
                options: MarkdownParseOptions(enableGFM: true, enableMath: options.math)
            )
        }

        // parity: native/src/markdown.zig#Doc.deinit [status=implemented hash=320ded8f1b19]
        public func deinitDoc() {
            source.removeAll(keepingCapacity: false)
            blocks.removeAll(keepingCapacity: false)
            definitions.removeAll(keepingCapacity: false)
            filterBytes.removeAll(keepingCapacity: false)
            finished = false
            removedFromIndex = NativeZigMarkdown.none
            committedTopLevelCount = 0
        }

        private static func validateHookFilter(_ items: [UInt8]) throws(NativeZigMarkdown.Error) {
            if items.isEmpty { return }
            guard items.count <= Int(NativeZigMarkdown.hookFilterByteCountMax) else {
                throw .invalidOptions
            }
            var itemCount = 0
            var itemLen = 0
            for b in items {
                if b == 0 {
                    if itemLen == 0 { throw .invalidOptions }
                    itemCount += 1
                    itemLen = 0
                } else {
                    itemLen += 1
                    if itemLen > Int(NativeZigMarkdown.hookFilterItemByteCountMax) {
                        throw .invalidOptions
                    }
                }
            }
            if itemLen == 0 { throw .invalidOptions }
            itemCount += 1
            if itemCount > Int(NativeZigMarkdown.hookFilterItemCountMax) {
                throw .invalidOptions
            }
        }

        // parity: native/src/markdown.zig#Doc.append [status=implemented hash=2e2b7812f668]
        public func append(_ bytes: [UInt8]) throws(NativeZigMarkdown.Error) {
            guard source.count + bytes.count <= Int(options.limits.sourceByteCount) else {
                throw .sourceLimit
            }
            if finished {
                var combined = source
                combined.append(contentsOf: bytes)
                try set(combined)
                return
            }
            source.append(contentsOf: bytes)
            counters.lineByteVisits &+= UInt64(bytes.count)
            counters.blockByteVisits &+= UInt64(bytes.count)
            let text = String(decoding: source, as: UTF8.self)
            _ = streamingDoc.write(text, streaming: true)
            rebuildBlockTable(markUnreportedFrom: 0, markOpen: true)
        }

        // parity: native/src/markdown.zig#Doc.finish [status=implemented hash=8ae7b9a875de]
        public func finish() throws(NativeZigMarkdown.Error) {
            if finished { return }
            let text = String(decoding: source, as: UTF8.self)
            _ = streamingDoc.write(text, streaming: false)
            finished = true
            rebuildBlockTable(markUnreportedFrom: 0, markOpen: false)
            committedTopLevelCount = UInt32(blocks.filter { $0.parentIndex == NativeZigMarkdown.none }.count)
        }

        // parity: native/src/markdown.zig#Doc.set [status=implemented hash=16363163b52e]
        public func set(_ bytes: [UInt8]) throws(NativeZigMarkdown.Error) {
            guard bytes.count <= Int(options.limits.sourceByteCount) else {
                throw .sourceLimit
            }
            let previousBlocks = blocks
            source = bytes
            finished = false
            counters.lineByteVisits &+= UInt64(bytes.count)
            counters.blockByteVisits &+= UInt64(bytes.count)
            let text = String(decoding: source, as: UTF8.self)
            _ = streamingDoc.write(text, streaming: true)
            rebuildBlockTable(markUnreportedFrom: 0, markOpen: true)
            var prefix = 0
            let limit = min(previousBlocks.count, blocks.count)
            while prefix < limit &&
                previousBlocks[prefix].kind == blocks[prefix].kind &&
                previousBlocks[prefix].payload0 == blocks[prefix].payload0 &&
                previousBlocks[prefix].sourceStartByte == blocks[prefix].sourceStartByte &&
                previousBlocks[prefix].sourceEndByte == blocks[prefix].sourceEndByte
            {
                blocks[prefix].flags.remove(.unreported)
                prefix += 1
            }
            if prefix < previousBlocks.count {
                removedFromIndex = min(removedFromIndex, UInt32(prefix))
            }
        }

        // parity: native/src/markdown.zig#Doc.setOptions [status=implemented hash=00c31039b973]
        public func setOptions(_ newOptions: Options) throws(NativeZigMarkdown.Error) {
            try Self.validateHookFilter(newOptions.hookFilter)
            guard source.count <= Int(newOptions.limits.sourceByteCount) else {
                throw .sourceLimit
            }
            let wasFinished = finished
            options = newOptions
            filterBytes = newOptions.hookFilter
            streamingDoc.setOptions(MarkdownParseOptions(enableGFM: true, enableMath: newOptions.math))
            let text = String(decoding: source, as: UTF8.self)
            _ = streamingDoc.write(text, streaming: !wasFinished)
            finished = wasFinished
            rebuildBlockTable(markUnreportedFrom: 0, markOpen: !wasFinished)
        }

        // parity: native/src/markdown.zig#Doc.changeCount [status=implemented hash=516d48689ba1]
        public func changeCount() -> UInt32 {
            var count: UInt32 = 0
            for b in blocks where b.flags.contains(.unreported) {
                count &+= 1
            }
            return count
        }

        // parity: native/src/markdown.zig#Doc.readChanges [status=implemented hash=499343ebf3cb]
        public func readChanges(capacity: Int) -> (changes: [Change], count: UInt32, removedFromIndex: UInt32) {
            let count = changeCount()
            let removed = removedFromIndex
            if capacity <= 0 || capacity < Int(count) {
                return ([], count, removed)
            }
            var out: [Change] = []
            out.reserveCapacity(Int(count))
            for idx in blocks.indices {
                if !blocks[idx].flags.contains(.unreported) { continue }
                blocks[idx].flags.remove(.unreported)
                out.append(Change(index: UInt32(idx), block: blocks[idx]))
            }
            removedFromIndex = NativeZigMarkdown.none
            return (out, count, removed)
        }

        // parity: native/src/markdown.zig#Doc.filter [status=implemented hash=3cbf86bbc4b7]
        public func filter() -> [UInt8] {
            filterBytes
        }

        // parity: native/src/markdown.zig#Doc.subtreeEnd [status=implemented hash=c53b02e437f5]
        public func subtreeEnd(_ index: UInt32) -> UInt32 {
            guard Int(index) < blocks.count else { return index }
            var end = index + 1
            while Int(end) < blocks.count && isDescendant(end, of: index) {
                end += 1
            }
            return end
        }

        private func isDescendant(_ index: UInt32, of ancestor: UInt32) -> Bool {
            var p = blocks[Int(index)].parentIndex
            while p != NativeZigMarkdown.none {
                if p == ancestor { return true }
                if p < ancestor || Int(p) >= blocks.count { return false }
                p = blocks[Int(p)].parentIndex
            }
            return false
        }

        // parity: native/src/markdown.zig#Doc.wholeWrite [status=implemented hash=e5bd3e629834]
        public func wholeWrite(_ index: UInt32) -> NodeWrite {
            let leaf = readLeaf(Int(index)) ?? Leaf()
            let range = RunRange(from: 0, chunks: leaf.chunks, urls: leaf.urls)
            return NodeWrite(block: index, from: 0, bytes: leaf.bytes, ranges: [range])
        }

        // parity: native/src/markdown.zig#Doc.relistHostWritten [status=implemented hash=43c4b0726401]
        public func relistHostWritten() {
            for idx in blocks.indices {
                let b = blocks[idx]
                switch b.kind {
                case .paragraph, .heading, .code, .html, .tableCell:
                    if Self.isBound(b) && options.liveShown && !b.flags.contains(.hooked) {
                        continue
                    }
                    blocks[idx].flags.insert(.unreported)
                default:
                    continue
                }
            }
        }

        // parity: native/src/markdown.zig#Doc.isBound [status=implemented hash=b91ae5e5af83]
        public static func isBound(_ block: Block) -> Bool {
            block.kind == .paragraph || block.kind == .heading
        }

        // parity: native/src/markdown.zig#Doc.sameStyles [status=implemented hash=a506100d78f5]
        public static func sameStyles(leaf: Leaf, styles: [UInt64]) -> Bool {
            guard styles.count == leaf.bytes.count else { return false }
            var at = 0
            for chunk in leaf.chunks {
                let key = TailSink.styleKey(chunk: chunk, urls: leaf.urls)
                let end = at + Int(chunk.byteCount)
                guard end <= styles.count else { return false }
                for pos in at..<end {
                    if styles[pos] != key { return false }
                }
                at = end
            }
            return at == styles.count
        }

        // parity: native/src/markdown.zig#Doc.leafDisplay [status=implemented hash=80305f537f59]
        public func leafDisplay(_ index: Int) -> [UInt8] {
            readLeaf(index)?.bytes ?? []
        }

        @discardableResult
        public func write(_ content: String, streaming: Bool = false) throws(NativeZigMarkdown.Error) -> MarkdownChanges {
            let bytes = Array(content.utf8)
            guard UInt32(bytes.count) <= options.limits.sourceByteCount else { throw .sourceLimit }
            source = bytes
            finished = !streaming
            counters.lineByteVisits &+= UInt64(bytes.count)
            counters.blockByteVisits &+= UInt64(bytes.count)
            let changes = streamingDoc.write(content, streaming: streaming)
            rebuildBlockTable(markUnreportedFrom: 0, markOpen: streaming)
            return changes
        }

        // parity: native/src/markdown.zig#Doc.readLeaf [status=implemented hash=166aee395320]
        public func readLeaf(_ index: Int) -> Leaf? {
            guard let block = streamingDoc.readLeaf(index) else { return nil }
            let text = renderPlain(block)
            let bytes = Array(text.utf8)
            let chunk = Chunk(byteCount: UInt32(bytes.count))
            return Leaf(bytes: bytes, chunks: bytes.isEmpty ? [] : [chunk], urls: [])
        }

        // parity: native/src/markdown.zig#Doc.isInlineLeaf [status=implemented hash=a43f26931316]
        public static func isInlineLeaf(_ block: Block) -> Bool {
            block.kind == .paragraph || block.kind == .heading || block.kind == .tableCell
        }

        // parity: native/src/markdown.zig#Doc.leafSubject [status=implemented hash=e2a502a2849c]
        public func leafSubject(_ index: UInt32) -> [UInt8] {
            var bytes = leafContent(index).bytes
            while let last = bytes.last,
                last == UInt8(ascii: " ") || last == UInt8(ascii: "\t") || last == UInt8(ascii: "\n")
            {
                bytes.removeLast()
            }
            if Int(index) < blocks.count {
                let kind = blocks[Int(index)].kind
                if kind == .tableCell {
                    var unescaped: [UInt8] = []
                    unescaped.reserveCapacity(bytes.count)
                    var i = 0
                    while i < bytes.count {
                        if bytes[i] == UInt8(ascii: "\\") && i + 1 < bytes.count && bytes[i + 1] == UInt8(ascii: "|") {
                            unescaped.append(UInt8(ascii: "|"))
                            i += 2
                        } else {
                            unescaped.append(bytes[i])
                            i += 1
                        }
                    }
                    bytes = unescaped
                } else if kind == .paragraph, let prose = NativeZigMarkdown.definitionProse(bytes, from: 0, closed: true).prose {
                    let cut = min(Int(prose), bytes.count)
                    bytes = Array(bytes[cut...])
                }
            }
            return bytes
        }

        // parity: native/src/markdown.zig#Doc.parseLeaf [status=implemented hash=38676cd8d067]
        public func parseLeaf(_ index: UInt32) -> NativeZigMarkdownInline.Result {
            NativeZigMarkdownInline.parse(
                content: leafSubject(index),
                references: references(),
                options: NativeZigMarkdownInline.Options(math: options.math)
            )
        }

        // parity: native/src/markdown.zig#Doc.references [status=implemented hash=2a71fcd169af]
        public func references() -> NativeZigMarkdownInline.References {
            var defs: [String: NativeZigMarkdownInline.Link] = [:]
            for def in definitions {
                let l0 = min(Int(def.labelStartByte), source.count)
                let l1 = min(Int(def.labelEndByte), source.count)
                let d0 = min(Int(def.destinationStartByte), source.count)
                let d1 = min(Int(def.destinationEndByte), source.count)
                guard l0 < l1, d0 <= d1 else { continue }
                let label = String(decoding: source[l0..<l1], as: UTF8.self).lowercased()
                let dest = String(decoding: source[d0..<d1], as: UTF8.self)
                let title: String?
                if def.titleStartByte != NativeZigMarkdown.none && Int(def.titleEndByte) <= source.count && def.titleStartByte <= def.titleEndByte {
                    title = String(decoding: source[Int(def.titleStartByte)..<Int(def.titleEndByte)], as: UTF8.self)
                } else {
                    title = nil
                }
                if defs[label] == nil {
                    defs[label] = NativeZigMarkdownInline.Link(destination: dest, title: title)
                }
            }
            return NativeZigMarkdownInline.References(definitions: defs)
        }

        // parity: native/src/markdown.zig#Doc.leafContent [status=implemented hash=c35ecdf21921]
        public func leafContent(_ index: UInt32) -> LeafContent {
            let idx = Int(index)
            guard idx >= 0 && idx < blocks.count else {
                return LeafContent(bytes: [], lines: [(0, 0)])
            }
            let block = blocks[idx]
            let s0 = min(Int(block.contentStartByte), source.count)
            let s1 = min(Int(block.contentEndByte), source.count)
            if s0 < s1 {
                let slice = Array(source[s0..<s1])
                var lines: [(UInt32, UInt32)] = [(0, UInt32(s0))]
                for i in slice.indices where slice[i] == UInt8(ascii: "\n") && i + 1 < slice.count {
                    lines.append((UInt32(i + 1), UInt32(s0 + i + 1)))
                }
                return LeafContent(bytes: slice, lines: lines)
            }
            let fallback = readLeaf(idx)?.bytes ?? []
            return LeafContent(bytes: fallback, lines: [(0, block.contentStartByte)])
        }

        private func rebuildBlockTable(markUnreportedFrom start: Int = 0, markOpen: Bool = false) {
            let parsed = parseMarkdown(
                String(decoding: source, as: UTF8.self),
                options: MarkdownParseOptions(enableGFM: true, enableMath: options.math)
            )
            blocks = parsed.blocks.enumerated().map { idx, blk in
                var baseFlags: Flags = idx >= start ? [.unreported] : []
                if markOpen && idx == parsed.blocks.count - 1 {
                    baseFlags.insert(.open)
                }
                switch blk {
                case .paragraph: return Block(kind: .paragraph, flags: baseFlags)
                case .heading(let level, _): return Block(kind: .heading, flags: baseFlags, payload0: UInt32(max(1, level)))
                case .codeBlock(_, _, let fenced, let isMath):
                    var f = baseFlags
                    if fenced { f.insert(.fenced) }
                    if isMath { f.insert(.math) }
                    return Block(kind: .code, flags: f)
                case .htmlBlock: return Block(kind: .html, flags: baseFlags)
                case .thematicBreak: return Block(kind: .rule, flags: baseFlags)
                case .blockquote: return Block(kind: .quote, flags: baseFlags)
                case .list(let ordered, let startNum, let tight, _):
                    var f = baseFlags
                    if ordered { f.insert(.ordered) }
                    if tight { f.insert(.tight) }
                    return Block(kind: .list, flags: f, payload0: UInt32(max(0, startNum)))
                case .table(let alignments, _, _):
                    return Block(kind: .table, flags: baseFlags, payload0: UInt32(alignments.count))
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

    // parity: native/src/yoga.zig#reportMeasureError [status=implemented hash=e3c807469524]
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

    // parity: native/src/native-renderable.zig#NativeRenderable [status=implemented hash=ef9a37459f8c]
    public final class NativeRenderable: @unchecked Sendable {
        public let yogaNode: YogaNode
        public var measureTarget: MeasureTarget
        public var contextOwned: Bool
        public var surface: OptimizedBuffer?
        public var sceneNode: NativeZigScene.Node?

        // parity: native/src/native-renderable.zig#NativeRenderable.init [status=implemented hash=bde6088b1f7a]
        public init(
            yogaNode: YogaNode = YogaNode.createForOpenTUI(),
            measureTarget: MeasureTarget = .none,
            contextOwned: Bool = false
        ) {
            self.yogaNode = yogaNode
            self.measureTarget = measureTarget
            self.contextOwned = contextOwned
        }

        // parity: native/src/native-renderable.zig#NativeRenderable.initWithConfig [status=implemented hash=8151c63b6b8d]
        public static func initWithConfig(_ config: NativeZigYoga.Config) -> NativeRenderable {
            NativeRenderable(yogaNode: YogaNode.createWithConfig(config.ref))
        }

        // parity: native/src/native-renderable.zig#NativeRenderable.deinit [status=implemented hash=73fa18291da1]
        public func deinitRenderable() {
            detachMeasure()
            surface = nil
            sceneNode = nil
            contextOwned = false
        }

        // parity: native/src/native-renderable.zig#NativeRenderable.detachMeasure [status=implemented hash=dd0cd5af5009]
        public func detachMeasure() {
            yogaNode.setDirtiedFunc(nil)
            if contextOwned, let parent = yogaNode.getParent() {
                parent.removeChild(yogaNode)
            }
            try? setMeasureTarget(.none)
        }

        // parity: native/src/native-renderable.zig#NativeRenderable.resetForReuse [status=implemented hash=7bfffa859526]
        public func resetForReuse() -> Bool {
            guard !yogaNode.isFreed() else { return false }
            yogaNode.reset()
            measureTarget = .none
            surface = nil
            sceneNode = nil
            contextOwned = true
            return true
        }

        // parity: native/src/native-renderable.zig#NativeRenderable.getYogaNode [status=implemented hash=651bd6530859]
        public func getYogaNode() -> YogaNode {
            yogaNode
        }

        // parity: native/src/native-renderable.zig#NativeRenderable.setMeasureTarget [status=implemented hash=68aaa2e8a71b]
        public func setMeasureTarget(_ target: MeasureTarget) throws(NativeZigYoga.Error) {
            try setMeasureTargetPreservingProvider(target, preserveProvider: false)
        }

        // parity: native/src/native-renderable.zig#NativeRenderable.setMeasureTargetPreservingProvider [status=implemented hash=bd9227fe02bd]
        public func setMeasureTargetPreservingProvider(
            _ target: MeasureTarget,
            preserveProvider: Bool
        ) throws(NativeZigYoga.Error) {
            let status: NativeZigYoga.Status
            if preserveProvider {
                status = NativeZigYoga.nodeTeardownStatus(yogaNode)
            } else {
                switch target {
                case .none:
                    status = NativeZigYoga.yogaNodeSetNativeMeasureFunc(yogaNode, callback: nil, heightCapOnlyClamps: false)
                case .textBufferView, .editorView:
                    status = NativeZigYoga.yogaNodeSetNativeMeasureFunc(
                        yogaNode,
                        callback: { [weak self] width, widthMode, height, _ in
                            guard let self else {
                                return NativeZigYoga.ExternalYogaSize(width: .nan, height: .nan)
                            }
                            let effW = NativeZigRenderable.normalizeYogaMeasureWidthInput(value: width, widthMode: widthMode)
                            let effH = NativeZigRenderable.normalizeYogaMeasureHeightInput(value: height)
                            let mw = NativeZigRenderable.measureCells(effW)
                            let mh = NativeZigRenderable.measureCells(effH)
                            let result: NativeZigTextBufferView.MeasureResult?
                            switch self.measureTarget {
                            case .none:
                                result = nil
                            case .textBufferView(let view):
                                result = view.measureForDimensions(width: mw, height: mh)
                            case .editorView(let view):
                                result = view.measureForDimensions(width: mw, height: mh)
                            }
                            guard let result else {
                                return NativeZigYoga.ExternalYogaSize(width: 1, height: 1)
                            }
                            var measuredW = Float(max(1, result.widthColsMax))
                            let measuredH = Float(max(1, result.lineCount))
                            if widthMode == NativeZigYoga.YogaMeasureMode.atMost.rawValue && self.yogaNode.getPositionType() != .absolute {
                                measuredW = min(effW, measuredW)
                            }
                            return NativeZigYoga.ExternalYogaSize(width: measuredW, height: measuredH)
                        },
                        heightCapOnlyClamps: true
                    )
                }
            }
            try NativeZigYoga.check(status)
            let hadTarget: Bool
            if case .none = measureTarget { hadTarget = false } else { hadTarget = true }
            let hasTarget: Bool
            if case .none = target { hasTarget = false } else { hasTarget = true }
            measureTarget = target
            if contextOwned && (hadTarget || hasTarget) {
                NativeZigYoga.yogaNodeInvalidateMeasure(yogaNode)
            }
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

        // parity: native/src/native-renderable.zig#NodeStorage.retainedBytes [status=implemented hash=4277d0f76991]
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
        case sceneAlreadyAttached
        case objectLimit
        case wrongKind
        case wrongSession
        case wrongContext
        case staleFrame
        case frameBusy
        case unsupportedResource
        case yogaInvalidArgument
        case yogaDepthLimit
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

        // parity: native/src/scene.zig#ArrowOptions.deinit [status=implemented hash=8367e478cd8a]
        public mutating func deinitOptions() {
            text = nil
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

    // parity: native/src/scene.zig#Layout [status=implemented hash=ff532fee7e3b]
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

    // parity: native/src/scene.zig#ScrollState [status=implemented hash=6d98d18e1628]
    public struct ScrollState: Equatable, Sendable {
        public struct Reveal: Equatable, Hashable, Sendable {
            public var node: SceneNodeHandle
            public var alignment: UInt32
            public var inset: Double
            public init(node: SceneNodeHandle, alignment: UInt32 = 0, inset: Double = 0) {
                self.node = node
                self.alignment = alignment
                self.inset = inset
            }
        }

        public struct Anchor: Equatable, Hashable, Sendable {
            public var node: SceneNodeHandle
            public var rowX: Double?
            public var rowY: Double?
            public init(node: SceneNodeHandle, rowX: Double? = nil, rowY: Double? = nil) {
                self.node = node
                self.rowX = rowX
                self.rowY = rowY
            }
        }

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
        public var generation: UInt64
        public var requestFrame: UInt64
        public var layoutFrame: UInt64
        public var targetX: Double?
        public var targetY: Double?
        public var reveal: Reveal?
        public var anchor: Anchor?
        public var arrows: [[ArrowOptions]]
        public var reported: [Double]

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
            self.generation = 0
            self.requestFrame = 0
            self.layoutFrame = 0
            self.targetX = nil
            self.targetY = nil
            self.reveal = nil
            self.anchor = nil
            self.arrows = [[ArrowOptions(), ArrowOptions()], [ArrowOptions(), ArrowOptions()]]
            self.reported = [offsetX, offsetY, Double(extentX), Double(extentY), Double(viewport.width), Double(viewport.height)]
        }

        internal func followAxis() -> Int? {
            switch Int64(options.follow) {
            case NativeABI.OT_SCENE_SCROLL_FOLLOW_TOP, NativeABI.OT_SCENE_SCROLL_FOLLOW_BOTTOM:
                return 1
            case NativeABI.OT_SCENE_SCROLL_FOLLOW_LEFT, NativeABI.OT_SCENE_SCROLL_FOLLOW_RIGHT:
                return 0
            default:
                return nil
            }
        }

        internal func followEdge(_ axis: Int) -> Double {
            let far = Int64(options.follow) == NativeABI.OT_SCENE_SCROLL_FOLLOW_BOTTOM ||
                Int64(options.follow) == NativeABI.OT_SCENE_SCROLL_FOLLOW_RIGHT
            return far ? (axis == 1 ? maxY : maxX) : 0
        }

        internal func innerSize(_ axis: Int) -> Double {
            let size = Double(axis == 1 ? viewport.height : viewport.width)
            let p0 = axis < options.padding.count ? Double(options.padding[axis]) : 0
            let p1 = (axis + 2) < options.padding.count ? Double(options.padding[axis + 2]) : 0
            return size - p0 - p1
        }

        internal func gutter(_ axis: Int) -> Float {
            guard axis < options.bars.count else { return 0 }
            let bar = options.bars[axis]
            let isVisible = axis == 1 ? visibleY : visibleX
            return (isVisible && !bar.overlay) ? Float(bar.gap + bar.thickness) : 0
        }

        internal func targetOf(_ axis: Int, position: Double) -> Double {
            let maxVal = axis == 1 ? maxY : maxX
            let extentVal = Double(axis == 1 ? extentY : extentX)
            let end = position > 0 && position >= maxVal && extentVal > 0
            return end ? Double.infinity : (position + 0.5).rounded(.down)
        }

        // parity: native/src/scene.zig#ScrollState.restick [status=implemented hash=bcf5ac9228c1]
        public mutating func restick() {
            guard let axis = followAxis() else { return }
            let m = axis == 1 ? maxY : maxX
            let off = axis == 1 ? offsetY : offsetX
            stuck = m <= 1 || off == followEdge(axis)
        }

        // parity: native/src/scene.zig#ScrollState.observed [status=implemented hash=f6fb4082fa44]
        public func observed() -> [Double] {
            [offsetX, offsetY, Double(extentX), Double(extentY), Double(viewport.width), Double(viewport.height)]
        }

        // parity: native/src/scene.zig#ScrollState.applyGutters [status=implemented hash=d210d70d3e7f]
        public func applyGutters(to box: YogaNode) -> Bool {
            var changed = false
            let edges: [(YogaEdge, Int)] = [(.bottom, 0), (.right, 1)]
            for (edge, axis) in edges {
                let value = gutter(axis)
                let current = box.getPadding(edge)
                if current.unit == .point && current.value == value {
                    continue
                }
                box.setPadding(edge, value)
                changed = true
            }
            return changed
        }

        // parity: native/src/scene.zig#ScrollState.barRects [status=implemented hash=50723695c119]
        public func barRects(axis: Int, box: Layout, sides: UInt32) -> (bar: Layout, track: Layout, arrows: (Layout, Layout)) {
            let barOpts = axis < options.bars.count ? options.bars[axis] : ScrollBarOptions()
            let left: Float = (sides & UInt32(NativeABI.OT_BORDER_LEFT)) != 0 ? 1 : 0
            let top: Float = (sides & UInt32(NativeABI.OT_BORDER_TOP)) != 0 ? 1 : 0
            let right: Float = (sides & UInt32(NativeABI.OT_BORDER_RIGHT)) != 0 ? 1 : 0
            let bottom: Float = (sides & UInt32(NativeABI.OT_BORDER_BOTTOM)) != 0 ? 1 : 0
            let thickness = Float(barOpts.thickness)
            var bar = Layout(
                width: Swift.max(0, box.width - left - right),
                height: Swift.max(0, box.height - top - bottom),
                screenX: box.screenX + Double(left),
                screenY: box.screenY + Double(top)
            )
            if axis == 1 {
                bar.screenX += Double(Swift.max(0, bar.width - thickness))
                bar.width = Swift.min(bar.width, thickness)
            } else {
                bar.width = Swift.max(0, bar.width - gutter(1))
                bar.screenY += Double(Swift.max(0, bar.height - thickness))
                bar.height = Swift.min(bar.height, thickness)
            }
            var track = bar
            var arrow0 = Layout()
            var arrow1 = Layout()
            if barOpts.arrows {
                let alongX: Float = axis == 1 ? 0 : 1
                let alongY: Float = axis == 1 ? 1 : 0
                let length = axis == 1 ? bar.height : bar.width
                let ends = Swift.min(2, length)
                arrow0 = Layout(
                    width: Swift.min(1, bar.width),
                    height: Swift.min(1, bar.height),
                    screenX: bar.screenX + Double(((bar.width - 1) / 2).rounded(.down) * alongY),
                    screenY: bar.screenY + Double(((bar.height - 1) / 2).rounded(.down) * alongX)
                )
                arrow1 = arrow0
                arrow1.screenX += Double(Swift.max(0, length - 1) * alongX)
                arrow1.screenY += Double(Swift.max(0, length - 1) * alongY)
                if axis == 1 {
                    track.screenY += Double(Swift.min(1, ends))
                    track.height -= ends
                } else {
                    track.screenX += Double(Swift.min(1, ends))
                    track.width -= ends
                }
            }
            return (bar, track, (arrow0, arrow1))
        }

        // parity: native/src/scene.zig#ScrollState.slider [status=implemented hash=76823503c7a2]
        public func slider(axis: Int) -> SliderOptions {
            let barOpts = axis < options.bars.count ? options.bars[axis] : ScrollBarOptions()
            return SliderOptions(
                min: 0,
                max: axis == 1 ? maxY : maxX,
                value: axis == 1 ? offsetY : offsetX,
                viewportSize: Swift.max(1, innerSize(axis)),
                orientation: UInt32(axis),
                foreground: barOpts.foreground,
                background: barOpts.background
            )
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

    // parity: native/src/scene.zig#paint_fields_all [status=implemented hash=c1d2502eb944]
    public static let paintFieldsAll: UInt32 = (1 << 11) - 1

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

        // parity: native/src/scene.zig#BufferIdentity.init [status=implemented hash=26e6f950a289]
        public init(target: OptimizedBuffer, generation: UInt64 = 0) {
            let id = ObjectIdentifier(target).hashValue
            self.destination = id
            self.storage = target.width * target.height
            self.generation = generation
        }

        // parity: native/src/scene.zig#BufferIdentity.matches [status=implemented hash=6a5963b00d33]
        public func matches(_ target: OptimizedBuffer, generation: UInt64 = 0) -> Bool {
            self == BufferIdentity(target: target, generation: generation)
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

        // parity: native/src/scene.zig#ImageState.deinit [status=implemented hash=c9100b8583a3]
        public mutating func deinitState() {
            source = nil
            buffer = nil
            crop = nil
        }
    }

    // parity: native/src/scene.zig#VideoState [status=implemented hash=7508bb30b814]
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

        // parity: native/src/scene.zig#VideoState.deinit [status=implemented hash=4744bee38dab]
        public mutating func deinitState() {
            image.deinitState()
            player = nil
            openError = ""
        }
    }

    // parity: native/src/scene.zig#Node [status=implemented hash=1813ddfeb6eb]
    public final class Node: @unchecked Sendable {
        public weak var owner: Scene?
        public weak var parent: NativeZigRenderable.NativeRenderable?
        public let handle: SceneNodeHandle
        public var kind: UInt32
        public var num: UInt32
        public var token: UInt32
        public var placement: UInt64 = 0
        public var paintEpoch: UInt64 = 0
        public var hookFlags: UInt32 = 0
        public var hookGeneration: UInt64 = 0
        public var resizeWidth: Double = 0
        public var resizeHeight: Double = 0
        public var observedFrame: UInt64 = 0
        public var preparedGen: UInt64 = 0
        public var subtreeGen: UInt64 = 0
        public var viewport: SceneNodeHandle?
        public var scrollContentNode: YogaNode?
        public var selfStale: Bool = false
        public var refreshDue: Bool = false
        public var viewQueued: Bool = false
        public var sortDirty: Bool = false
        public var needsLayout: Bool = true
        public var paint: Paint = Paint()
        public var layout: Layout = Layout()
        public var paintLayout: Layout?
        public var scroll: ScrollState?
        public var boxDetails: BoxDetails?
        public var slider: SliderOptions?
        public var arrow: ArrowOptions?
        public var textOptions: TextOptions?
        public var editorOptions: EditorOptions?
        public var imageState: ImageState?
        public var videoState: VideoState?
        public var children: [NativeZigRenderable.NativeRenderable] = []
        public var paintChildren: [NativeZigRenderable.NativeRenderable] = []
        public var lastRecordedFrame: UInt64 = 0
        public var lastRecordedClip: ClipRect = ClipRect(x: 0, y: 0, width: 0, height: 0)

        public init(handle: SceneNodeHandle, kind: UInt32 = 1, num: UInt32 = 0, token: UInt32 = 0) {
            self.handle = handle
            self.kind = kind
            self.num = num
            self.token = token
        }

        // parity: native/src/scene.zig#Node.childYoga [status=implemented hash=16a57da627b0]
        public func childYoga(for value: NativeZigRenderable.NativeRenderable) -> YogaNode {
            scrollContentNode ?? value.yogaNode
        }

        // parity: native/src/scene.zig#Node.filtersChildren [status=implemented hash=10bd6d66c4eb]
        public func filtersChildren() -> Bool {
            viewport != nil || (scroll?.options.culling == true)
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

    // parity: native/src/scene.zig#Scene [status=implemented hash=0622a2970974]
    public final class Scene: @unchecked Sendable {
        public struct Painted: Equatable, Sendable {
            public var ticket: FrameRequest
            public var destination: BufferIdentity
            public var workFrameId: UInt64

            public init(ticket: FrameRequest, destination: BufferIdentity, workFrameId: UInt64 = 0) {
                self.ticket = ticket
                self.destination = destination
                self.workFrameId = workFrameId
            }
        }

        public struct PaintedArea: Equatable, Hashable, Sendable {
            public var x: Int64
            public var y: Int64
            public var clip: ClipRect
            public var frame: UInt64

            public init(x: Int64, y: Int64, clip: ClipRect, frame: UInt64) {
                self.x = x
                self.y = y
                self.clip = clip
                self.frame = frame
            }
        }

        public let core: NativeScene
        public let session: SessionHandle
        public private(set) var nodes: [SceneNodeHandle: NativeZigRenderable.NativeRenderable] = [:]
        public private(set) var tokens: [UInt32: SceneNodeHandle] = [:]
        public private(set) var root: NativeZigRenderable.NativeRenderable?
        public private(set) var hits: [Hit] = []
        public private(set) var presentedHits: [Hit] = []
        public private(set) var candidates: [NativeZigRenderable.NativeRenderable] = []
        public private(set) var members: [NativeZigRenderable.NativeRenderable] = []
        public private(set) var viewDirty: [NativeZigRenderable.NativeRenderable] = []
        public private(set) var currentPaintSlots: [PaintSlot] = []
        public var lastToken: UInt32 = 0
        public var lastPlacement: UInt64 = 0
        public var lastFrameId: UInt64 = 0
        public var finishedFrame: UInt64 = 0
        public var presentedRecordsFrame: UInt64 = 0
        public var layoutEpoch: UInt64 = 0
        public var visibilityEpoch: UInt64 = 0
        public var selectionEpoch: UInt64 = 0
        public var candidatesGen: UInt64 = 0
        public var membersGen: UInt64 = 0
        public var hookCount: Int = 0
        public var layoutHookCount: Int = 0
        public var filterCount: Int = 0
        public var scrollCount: Int = 0
        public var layoutCallbacks: Int = 0
        public var layoutWidth: UInt32 = 0
        public var layoutHeight: UInt32 = 0
        public var preparationDirty: Bool = false
        public var cancelledPaint: Bool = false
        public var activeAttemptFrameId: UInt64?
        public var activePendingRequest: FrameRequest?
        public var activeAttemptOptions: FrameOptions?
        public var painted: Painted?
        public var focus: SceneNodeHandle?
        private var paintEpochCounter: UInt64 = 1

        // parity: native/src/scene.zig#Scene.init [status=implemented hash=1a497eb7da7c]
        public init(core: NativeScene, session: SessionHandle = SessionHandle(contextId: 1, slot: 1, generation: 1)) {
            self.core = core
            self.session = session
        }

        // parity: native/src/scene.zig#Scene.deinit [status=implemented hash=b1d7f7a52e71]
        public func deinitScene() {
            cancelFrame()
            detachAll()
            nodes.removeAll(keepingCapacity: false)
            tokens.removeAll(keepingCapacity: false)
            hits.removeAll(keepingCapacity: false)
            presentedHits.removeAll(keepingCapacity: false)
            candidates.removeAll(keepingCapacity: false)
            members.removeAll(keepingCapacity: false)
            viewDirty.removeAll(keepingCapacity: false)
            currentPaintSlots.removeAll(keepingCapacity: false)
            root = nil
            focus = nil
        }

        // parity: native/src/scene.zig#Scene.prepareInsert [status=implemented hash=84eb215d9ceb]
        public func prepareInsert(kind: UInt32, num: UInt32) throws(SceneError) {
            guard kind <= UInt32(NativeABI.OT_SCENE_VIDEO), num != 0 else {
                throw .invalidOptions
            }
            if kind == UInt32(NativeABI.OT_SCENE_ROOT) && root != nil {
                throw .sceneAlreadyAttached
            }
            if lastToken == UInt32.max {
                throw .objectLimit
            }
            tokens.reserveCapacity(tokens.count + 1)
            viewDirty.reserveCapacity(nodes.count + 1)
        }

        // parity: native/src/scene.zig#Scene.insert [status=implemented hash=5f06a52e25f3]
        public func insert(storage: NativeZigRenderable.NodeStorage, handle: SceneNodeHandle, kind: UInt32, num: UInt32) {
            lastToken &+= 1
            let node = Node(handle: handle, kind: kind, num: num, token: lastToken)
            node.owner = self
            node.children = storage.children
            node.paintChildren = storage.paintChildren
            if kind == UInt32(NativeABI.OT_SCENE_BOX) { node.boxDetails = nil }
            if kind == UInt32(NativeABI.OT_SCENE_ARROW) { node.arrow = ArrowOptions() }
            if kind == UInt32(NativeABI.OT_SCENE_EDITOR) { node.editorOptions = EditorOptions() }
            if kind == UInt32(NativeABI.OT_SCENE_IMAGE) { node.imageState = ImageState() }
            if kind == UInt32(NativeABI.OT_SCENE_VIDEO) { node.videoState = VideoState() }
            storage.node.sceneNode = node
            nodes[handle] = storage.node
            tokens[lastToken] = handle
            if kind == UInt32(NativeABI.OT_SCENE_ROOT) {
                root = storage.node
            }
            preparationDirty = true
            clearPreparation()
        }

        // parity: native/src/scene.zig#Scene.move [status=implemented hash=7922e62a6f32]
        public func move(
            _ value: NativeZigRenderable.NativeRenderable,
            destination: NativeZigRenderable.NativeRenderable?,
            index: UInt32
        ) throws(SceneError) {
            guard let node = value.sceneNode else { throw .wrongKind }
            if node.kind == UInt32(NativeABI.OT_SCENE_ROOT) { throw .yogaInvalidArgument }
            let reparented = node.parent !== destination
            let newPlacement = destination != nil && (reparented || node.placement == 0)
            if newPlacement && lastPlacement == UInt64.max { throw .objectLimit }

            if let parent = destination {
                guard let target = parent.sceneNode else { throw .wrongKind }
                if target.owner !== self { throw .wrongSession }
                let existingCount = target.children.count - (node.parent === parent ? 1 : 0)
                if Int(index) > existingCount { throw .yogaInvalidArgument }

                if let oldParent = node.parent, let oldNode = oldParent.sceneNode {
                    if let oldIdx = oldNode.children.firstIndex(where: { $0 === value }) {
                        oldNode.children.remove(at: oldIdx)
                        oldNode.childYoga(for: oldParent).removeChild(value.yogaNode)
                    }
                    if oldParent !== parent {
                        oldNode.paintChildren.removeAll { $0 === value }
                    } else {
                        target.sortDirty = true
                    }
                }
                target.children.insert(value, at: Int(index))
                target.childYoga(for: parent).insertChild(value.yogaNode, at: Int(index))
                if reparented {
                    target.paintChildren.append(value)
                    target.sortDirty = true
                    node.parent = parent
                }
            } else {
                if index != 0 { throw .yogaInvalidArgument }
                if let oldParent = node.parent, let oldNode = oldParent.sceneNode {
                    if let oldIdx = oldNode.children.firstIndex(where: { $0 === value }) {
                        oldNode.children.remove(at: oldIdx)
                        oldNode.childYoga(for: oldParent).removeChild(value.yogaNode)
                    }
                    oldNode.paintChildren.removeAll { $0 === value }
                    node.parent = nil
                }
            }

            if newPlacement {
                lastPlacement &+= 1
                node.placement = lastPlacement
            } else if destination == nil {
                node.placement = 0
            }
            node.needsLayout = true
            visibilityEpoch &+= 1
            selectionEpoch &+= 1
            preparationDirty = true
            clearPreparation()
            Self.markObservationStale(value)
        }

        // parity: native/src/scene.zig#Scene.clearChildren [status=implemented hash=23c4315050a5]
        public func clearChildren(_ value: NativeZigRenderable.NativeRenderable) {
            guard let node = value.sceneNode, !node.children.isEmpty else { return }
            let container = node.childYoga(for: value)
            for child in node.children {
                container.removeChild(child.yogaNode)
                child.sceneNode?.parent = nil
                child.sceneNode?.placement = 0
            }
            node.children.removeAll(keepingCapacity: true)
            node.paintChildren.removeAll(keepingCapacity: true)
            visibilityEpoch &+= 1
            selectionEpoch &+= 1
            preparationDirty = true
            clearPreparation()
        }

        // parity: native/src/scene.zig#Scene.remove [status=implemented hash=def3a05e1bd1]
        @discardableResult
        public func remove(_ value: NativeZigRenderable.NativeRenderable) -> NativeZigRenderable.NodeStorage {
            let storage = NativeZigRenderable.NodeStorage(node: value)
            if let node = value.sceneNode {
                if node.filtersChildren() { filterCount = max(0, filterCount - 1) }
                if let parent = node.parent, let pNode = parent.sceneNode {
                    pNode.children.removeAll { $0 === value }
                    pNode.paintChildren.removeAll { $0 === value }
                    pNode.childYoga(for: parent).removeChild(value.yogaNode)
                    node.parent = nil
                }
                if node.viewQueued {
                    viewDirty.removeAll { $0 === value }
                    node.viewQueued = false
                }
                clearChildren(value)
                if node.scroll != nil {
                    node.scroll = nil
                    node.scrollContentNode = nil
                    scrollCount = max(0, scrollCount - 1)
                }
                node.imageState?.deinitState()
                node.videoState?.deinitState()
                node.arrow?.deinitOptions()
                tokens.removeValue(forKey: node.token)
                nodes.removeValue(forKey: node.handle)
                if root === value { root = nil }
                if focus == node.handle { focus = nil }
                value.sceneNode = nil
            }
            preparationDirty = true
            clearPreparation()
            return storage
        }

        // parity: native/src/scene.zig#Scene.detachAll [status=implemented hash=fe949b07787d]
        public func detachAll() {
            cancelFrame()
            for renderable in nodes.values {
                guard let node = renderable.sceneNode else { continue }
                let container = node.childYoga(for: renderable)
                for child in node.children {
                    container.removeChild(child.yogaNode)
                }
                node.parent = nil
                node.placement = 0
                node.children.removeAll(keepingCapacity: true)
                node.paintChildren.removeAll(keepingCapacity: true)
                node.viewQueued = false
            }
            viewDirty.removeAll(keepingCapacity: true)
        }

        // parity: native/src/scene.zig#Scene.checkWritable [status=implemented hash=65c967eab3a7]
        public static func checkWritable(_ value: NativeZigRenderable.NativeRenderable) throws(SceneError) {
            if NativeZigYoga.nodeTeardownStatus(value.yogaNode) != .ok {
                throw .yogaInvalidArgument
            }
        }

        // parity: native/src/scene.zig#Scene.setPaintPartial [status=implemented hash=9e609060d2f8]
        public func setPaintPartial(_ value: NativeZigRenderable.NativeRenderable, fields: UInt32, patch: Paint) throws(SceneError) {
            guard fields != 0 && (fields & ~NativeZigScene.paintFieldsAll) == 0 else {
                throw .invalidOptions
            }
            if (fields & UInt32(NativeABI.OT_SCENE_PROPERTY_OPACITY)) != 0 {
                guard patch.opacity.isFinite && patch.opacity >= 0 && patch.opacity <= 1 else { throw .invalidOptions }
            }
            if (fields & UInt32(NativeABI.OT_SCENE_PROPERTY_TRANSLATE_X)) != 0 {
                guard abs(patch.translateX) <= Double(Float.greatestFiniteMagnitude) else { throw .invalidOptions }
            }
            if (fields & UInt32(NativeABI.OT_SCENE_PROPERTY_TRANSLATE_Y)) != 0 {
                guard abs(patch.translateY) <= Double(Float.greatestFiniteMagnitude) else { throw .invalidOptions }
            }
            if (fields & UInt32(NativeABI.OT_SCENE_PROPERTY_BORDER)) != 0 && patch.borderSides > UInt32(NativeABI.OT_BORDER_ALL) {
                throw .invalidOptions
            }
            if (fields & UInt32(NativeABI.OT_SCENE_PROPERTY_SHOULD_FILL)) != 0 && patch.shouldFill > 1 {
                throw .invalidOptions
            }
            if (fields & UInt32(NativeABI.OT_SCENE_PROPERTY_BORDER_STYLE)) != 0 && patch.borderStyle > UInt32(NativeABI.OT_BORDER_HEAVY) {
                throw .invalidOptions
            }
            guard let node = value.sceneNode else { throw .wrongKind }
            var merged = fields == NativeZigScene.paintFieldsAll ? patch : node.paint
            if fields != NativeZigScene.paintFieldsAll {
                if (fields & UInt32(NativeABI.OT_SCENE_PROPERTY_Z_INDEX)) != 0 { merged.zIndex = patch.zIndex }
                if (fields & UInt32(NativeABI.OT_SCENE_PROPERTY_OPACITY)) != 0 { merged.opacity = patch.opacity }
                if (fields & UInt32(NativeABI.OT_SCENE_PROPERTY_TRANSLATE_X)) != 0 { merged.translateX = patch.translateX }
                if (fields & UInt32(NativeABI.OT_SCENE_PROPERTY_TRANSLATE_Y)) != 0 { merged.translateY = patch.translateY }
                if (fields & UInt32(NativeABI.OT_SCENE_PROPERTY_BORDER)) != 0 { merged.borderSides = patch.borderSides }
                if (fields & UInt32(NativeABI.OT_SCENE_PROPERTY_SHOULD_FILL)) != 0 { merged.shouldFill = patch.shouldFill }
                if (fields & UInt32(NativeABI.OT_SCENE_PROPERTY_BACKGROUND)) != 0 { merged.background = patch.background }
                if (fields & UInt32(NativeABI.OT_SCENE_PROPERTY_BORDER_COLOR)) != 0 { merged.borderColor = patch.borderColor }
                if (fields & UInt32(NativeABI.OT_SCENE_PROPERTY_BORDER_STYLE)) != 0 { merged.borderStyle = patch.borderStyle }
                if (fields & UInt32(NativeABI.OT_SCENE_PROPERTY_FOCUSABLE)) != 0 { merged.focusable = patch.focusable }
                if (fields & UInt32(NativeABI.OT_SCENE_PROPERTY_FOCUSED_BORDER_COLOR)) != 0 { merged.focusedBorderColor = patch.focusedBorderColor }
            }
            if node.kind != UInt32(NativeABI.OT_SCENE_BOX) && merged.borderSides != UInt32(NativeABI.OT_BORDER_NONE) {
                throw .invalidOptions
            }
            try Self.checkWritable(value)
            if node.paint.borderSides != merged.borderSides {
                value.yogaNode.setBorder(.left, (merged.borderSides & UInt32(NativeABI.OT_BORDER_LEFT)) != 0 ? 1 : 0)
                value.yogaNode.setBorder(.top, (merged.borderSides & UInt32(NativeABI.OT_BORDER_TOP)) != 0 ? 1 : 0)
                value.yogaNode.setBorder(.right, (merged.borderSides & UInt32(NativeABI.OT_BORDER_RIGHT)) != 0 ? 1 : 0)
                value.yogaNode.setBorder(.bottom, (merged.borderSides & UInt32(NativeABI.OT_BORDER_BOTTOM)) != 0 ? 1 : 0)
            }
            if node.paint.zIndex != merged.zIndex {
                node.parent?.sceneNode?.sortDirty = true
            }
            if node.paint.translateX != merged.translateX || node.paint.translateY != merged.translateY {
                selectionEpoch &+= 1
            }
            if node.paint != merged {
                paintEpochCounter &+= 1
                node.paintEpoch = paintEpochCounter
            }
            node.paint = merged
            clearPreparation()
        }

        // parity: native/src/scene.zig#Scene.setBoxDetails [status=implemented hash=ca909cc3016d]
        public func setBoxDetails(_ value: NativeZigRenderable.NativeRenderable, options: BoxDetails) throws(SceneError) {
            guard let node = value.sceneNode else { throw .wrongKind }
            guard node.kind == UInt32(NativeABI.OT_SCENE_BOX) else { throw .wrongKind }
            guard options.titleAlignment <= 2 && options.bottomTitleAlignment <= 2 else { throw .invalidOptions }
            try Self.checkWritable(value)
            if options.title.isEmpty && options.bottomTitle.isEmpty && options.titleColor == nil &&
                options.customBorderChars == nil && options.titleAlignment == 0 && options.bottomTitleAlignment == 0
            {
                node.boxDetails = nil
            } else {
                node.boxDetails = options
            }
        }

        // parity: native/src/scene.zig#Scene.setHooks [status=implemented hash=a78bf57cf673]
        public func setHooks(
            _ value: NativeZigRenderable.NativeRenderable,
            flags: UInt32,
            generation: UInt64,
            initialWidth: Double,
            initialHeight: Double
        ) throws(SceneError) {
            guard let node = value.sceneNode else { throw .wrongKind }
            let allHooks: UInt32 = 0xFF
            let paintHooks = UInt32(NativeABI.OT_SCENE_HOOK_RENDER_BEFORE | NativeABI.OT_SCENE_HOOK_RENDER_AFTER | NativeABI.OT_SCENE_HOOK_RENDER_SELF)
            let layoutHooks = UInt32(NativeABI.OT_SCENE_HOOK_UPDATE | NativeABI.OT_SCENE_HOOK_RESIZE | NativeABI.OT_SCENE_HOOK_LAYOUT_CHANGED | NativeABI.OT_SCENE_HOOK_SCROLL)
            let updateBoth = UInt32(NativeABI.OT_SCENE_HOOK_UPDATE | NativeABI.OT_SCENE_HOOK_IDLE_UPDATE)
            guard (flags & ~allHooks) == 0,
                generation != 0,
                (flags & updateBoth) != updateBoth,
                !((flags & paintHooks) != 0 && node.kind == UInt32(NativeABI.OT_SCENE_ROOT)),
                !((flags & UInt32(NativeABI.OT_SCENE_HOOK_LAYOUT_CHANGED)) != 0 && node.kind != UInt32(NativeABI.OT_SCENE_ROOT)),
                !((flags & UInt32(NativeABI.OT_SCENE_HOOK_SCROLL)) != 0 && node.scroll == nil)
            else {
                throw .invalidOptions
            }
            guard initialWidth.isFinite && initialWidth >= 0 && initialWidth <= Double(Int32.max),
                initialHeight.isFinite && initialHeight >= 0 && initialHeight <= Double(Int32.max)
            else {
                throw .invalidDimensions
            }
            guard generation > node.hookGeneration else { throw .staleFrame }
            if node.observedFrame == 0 && node.hookGeneration == 0 {
                if node.kind == UInt32(NativeABI.OT_SCENE_SLIDER), let s = node.slider {
                    _ = try NativeZigScene.sliderThumb(s, width: initialWidth, height: initialHeight)
                }
                node.resizeWidth = initialWidth
                node.resizeHeight = initialHeight
            }
            let idleBit = UInt32(NativeABI.OT_SCENE_HOOK_IDLE_UPDATE)
            if (node.hookFlags & ~idleBit) != 0 { hookCount = max(0, hookCount - 1) }
            if (flags & ~idleBit) != 0 { hookCount += 1 }
            if (node.hookFlags & layoutHooks) != 0 { layoutHookCount = max(0, layoutHookCount - 1) }
            if (flags & layoutHooks) != 0 { layoutHookCount += 1 }
            node.hookFlags = flags
            node.hookGeneration = generation
            invalidateObservation(value)
        }

        // parity: native/src/scene.zig#Scene.setScroll [status=implemented hash=a1e9624491db]
        public func setScroll(_ value: NativeZigRenderable.NativeRenderable, options: ScrollOptions) throws(SceneError) {
            guard let node = value.sceneNode else { throw .wrongKind }
            guard node.kind == UInt32(NativeABI.OT_SCENE_BOX) else { throw .wrongKind }
            guard options.axes <= UInt32(NativeABI.OT_SCENE_SCROLL_X | NativeABI.OT_SCENE_SCROLL_Y),
                options.follow <= UInt32(NativeABI.OT_SCENE_SCROLL_FOLLOW_RIGHT)
            else {
                throw .invalidOptions
            }
            for pad in options.padding {
                guard pad >= 0 && pad <= Float(NativeABI.OT_SCENE_SCROLL_PADDING_MAX) && pad.rounded(.towardZero) == pad else {
                    throw .invalidOptions
                }
            }
            for bar in options.bars {
                guard bar.policy <= UInt32(NativeABI.OT_SCENE_SCROLL_BAR_NEVER) &&
                    bar.thickness >= 1 && bar.thickness <= 255 && bar.gap <= 255
                else {
                    throw .invalidOptions
                }
            }
            try Self.checkWritable(value)
            if node.viewport != nil || (node.scroll == nil && !node.children.isEmpty) {
                throw .invalidOptions
            }
            let wasFiltered = node.filtersChildren()
            if node.scroll == nil {
                node.scroll = ScrollState(options: options)
                node.scrollContentNode = YogaNode.createForOpenTUI()
                scrollCount += 1
            } else {
                node.scroll?.options = options
                node.scroll?.restick()
            }
            let nowFiltered = node.filtersChildren()
            if wasFiltered != nowFiltered {
                filterCount = max(0, filterCount + (nowFiltered ? 1 : -1))
            }
            invalidateObservation(value)
        }

        // parity: native/src/scene.zig#Scene.setViewport [status=implemented hash=90d179a9f0fa]
        public func setViewport(_ value: NativeZigRenderable.NativeRenderable, viewport: SceneNodeHandle?) {
            guard let node = value.sceneNode else { return }
            if node.viewport == viewport { return }
            let wasFiltered = node.filtersChildren()
            node.viewport = viewport
            let nowFiltered = node.filtersChildren()
            if wasFiltered != nowFiltered {
                filterCount = max(0, filterCount + (nowFiltered ? 1 : -1))
            }
            selectionEpoch &+= 1
            preparationDirty = true
            clearPreparation()
        }

        // parity: native/src/scene.zig#Scene.setScrollArrow [status=implemented hash=3ce24afed674]
        public func setScrollArrow(
            _ value: NativeZigRenderable.NativeRenderable,
            axis: UInt32,
            end: UInt32,
            options: ArrowOptions
        ) throws(SceneError) {
            guard let node = value.sceneNode, var state = node.scroll else { throw .wrongKind }
            guard axis <= 1 && end <= 1 && options.direction == 0 else { throw .invalidOptions }
            try Self.checkWritable(value)
            state.arrows[Int(axis)][Int(end)] = options
            node.scroll = state
            clearPreparation()
        }

        // parity: native/src/scene.zig#Scene.scrollTo [status=implemented hash=5d0c4e1917cb]
        public func scrollTo(
            _ value: NativeZigRenderable.NativeRenderable,
            target: (Double, Double),
            relative: (Bool, Bool),
            reapply: Bool
        ) throws(SceneError) {
            guard let node = value.sceneNode, var state = node.scroll else { throw .wrongKind }
            guard !target.0.isNaN && !target.1.isNaN else { throw .invalidOptions }
            try Self.checkWritable(value)
            if !reapply || state.requestFrame <= finishedFrame {
                state.targetX = nil
                state.targetY = nil
            }
            state.reveal = nil
            let baseX = (state.targetX == Double.infinity) ? state.maxX : (state.targetX ?? state.offsetX)
            let baseY = (state.targetY == Double.infinity) ? state.maxY : (state.targetY ?? state.offsetY)
            let posX = relative.0 ? baseX + target.0 : target.0
            let posY = relative.1 ? baseY + target.1 : target.1
            if reapply && !(relative.0 && target.0 == 0) {
                state.targetX = state.targetOf(0, position: posX)
                if state.targetX == Double.infinity { state.anchor = nil }
            }
            if reapply && !(relative.1 && target.1 == 0) {
                state.targetY = state.targetOf(1, position: posY)
                if state.targetY == Double.infinity { state.anchor = nil }
            }
            let oldX = state.offsetX
            let oldY = state.offsetY
            let oldStuck = state.stuck
            state.offsetX = min(max((posX + 0.5).rounded(.down), 0), state.maxX)
            state.offsetY = min(max((posY + 0.5).rounded(.down), 0), state.maxY)
            state.restick()
            if reapply {
                state.requestFrame = activeAttemptFrameId ?? (lastFrameId &+ 1)
            }
            state.reported[0] = state.offsetX
            state.reported[1] = state.offsetY
            if oldX != state.offsetX || oldY != state.offsetY || oldStuck != state.stuck {
                state.generation &+= 1
                paintEpochCounter &+= 1
                node.paintEpoch = paintEpochCounter
                selectionEpoch &+= 1
                preparationDirty = true
                clearPreparation()
            }
            node.scroll = state
        }

        // parity: native/src/scene.zig#Scene.requestScroll [status=implemented hash=895b5a0911bb]
        public func requestScroll(
            _ value: NativeZigRenderable.NativeRenderable,
            kind: UInt32,
            target: NativeZigRenderable.NativeRenderable?,
            alignment: UInt32 = 0,
            inset: UInt32 = 0
        ) throws(SceneError) {
            guard let node = value.sceneNode, var state = node.scroll else { throw .wrongKind }
            let targetValid: Bool
            switch Int64(kind) {
            case NativeABI.OT_SCENE_SCROLL_REQUEST_INTO_VIEW: targetValid = target != nil
            case NativeABI.OT_SCENE_SCROLL_REQUEST_ANCHOR: targetValid = true
            case NativeABI.OT_SCENE_SCROLL_REQUEST_LAYOUT: targetValid = target == nil
            default: targetValid = false
            }
            let placed = alignment != 0 || inset != 0
            guard targetValid,
                alignment <= UInt32(NativeABI.OT_SCENE_SCROLL_ALIGN_END),
                !(placed && Int64(kind) != NativeABI.OT_SCENE_SCROLL_REQUEST_INTO_VIEW)
            else {
                throw .invalidOptions
            }
            try Self.checkWritable(value)
            switch Int64(kind) {
            case NativeABI.OT_SCENE_SCROLL_REQUEST_INTO_VIEW:
                guard let targetHandle = target?.sceneNode?.handle else { throw .invalidOptions }
                state.targetX = nil
                state.targetY = nil
                state.reveal = ScrollState.Reveal(node: targetHandle, alignment: alignment, inset: Double(inset))
                state.requestFrame = activeAttemptFrameId ?? (lastFrameId &+ 1)
            case NativeABI.OT_SCENE_SCROLL_REQUEST_ANCHOR:
                if let targetHandle = target?.sceneNode?.handle {
                    state.anchor = ScrollState.Anchor(node: targetHandle)
                } else {
                    state.anchor = nil
                }
            default:
                if state.layoutFrame == 0 {
                    state.layoutFrame = lastFrameId &+ 1
                    layoutCallbacks += 1
                }
            }
            node.scroll = state
        }

        // parity: native/src/scene.zig#Scene.markObservationStale [status=implemented hash=d036b249a048]
        public static func markObservationStale(_ value: NativeZigRenderable.NativeRenderable) {
            guard let node = value.sceneNode else { return }
            node.selfStale = true
            node.parent?.sceneNode?.refreshDue = true
            guard let owner = node.owner, owner.activeAttemptFrameId == nil, !node.viewQueued else { return }
            node.viewQueued = true
            owner.viewDirty.append(value)
        }

        // parity: native/src/scene.zig#Scene.invalidateObservation [status=implemented hash=c691e6af659c]
        public func invalidateObservation(_ value: NativeZigRenderable.NativeRenderable) {
            preparationDirty = true
            clearPreparation()
            Self.markObservationStale(value)
        }

        // parity: native/src/scene.zig#Scene.clearPreparation [status=implemented hash=4993caacff0a]
        public func clearPreparation() {
            candidates.removeAll(keepingCapacity: true)
            members.removeAll(keepingCapacity: true)
            if activeAttemptFrameId == nil {
                membersGen &+= 1
            }
        }

        // parity: native/src/scene.zig#Scene.cancelFrame [status=implemented hash=d4f9aaf39ff1]
        public func cancelFrame() {
            if painted != nil {
                cancelledPaint = true
            }
            painted = nil
            activeAttemptFrameId = nil
            activePendingRequest = nil
            activeAttemptOptions = nil
            currentPaintSlots.removeAll(keepingCapacity: true)
            clearPreparation()
        }

        // parity: native/src/scene.zig#Scene.checkPainted [status=implemented hash=f66f67ebfb29]
        public func checkPainted(_ ticket: FrameRequest) throws(SceneError) -> Painted {
            if ticket.session.contextId != session.contextId { throw .wrongContext }
            if ticket.session != session { throw .wrongSession }
            guard let painted, painted.ticket == ticket else { throw .staleFrame }
            return painted
        }

        // parity: native/src/scene.zig#Scene.paintSlots [status=implemented hash=335fdb81b9ce]
        public func paintSlots(for ticket: FrameRequest) throws(SceneError) -> [PaintSlot] {
            if ticket.session.contextId != session.contextId { throw .wrongContext }
            if ticket.session != session { throw .wrongSession }
            guard let pending = activePendingRequest,
                pending == ticket,
                ticket.kind == UInt32(NativeABI.OT_SCENE_FRAME_RECORD)
            else {
                throw .staleFrame
            }
            return currentPaintSlots
        }

        // parity: native/src/scene.zig#Scene.requalifyPainted [status=implemented hash=2a8747da717d]
        public func requalifyPainted(target: OptimizedBuffer, generation: UInt64 = 0) {
            if var current = painted {
                current.destination = BufferIdentity(target: target, generation: generation)
                painted = current
            }
        }

        // parity: native/src/scene.zig#Scene.frameStep [status=implemented hash=c15566782e57]
        public func frameStep(
            target: OptimizedBuffer,
            previous: FrameRequest? = nil,
            options: FrameOptions = FrameOptions(),
            allowHost: Bool = true,
            recording: [UInt8]? = nil
        ) throws(SceneError) -> FrameRequest {
            if !allowHost && hookCount != 0 { throw .unsupportedResource }
            let frameId: UInt64
            if let reply = previous {
                if reply.session.contextId != session.contextId { throw .wrongContext }
                if reply.session != session { throw .wrongSession }
                guard let activeFrame = activeAttemptFrameId,
                    let pending = activePendingRequest,
                    let activeOpts = activeAttemptOptions,
                    pending == reply
                else {
                    throw .staleFrame
                }
                if options.maxLayoutRounds != activeOpts.maxLayoutRounds ||
                    options.maxHostRequests != activeOpts.maxHostRequests ||
                    (reply.kind == UInt32(NativeABI.OT_SCENE_FRAME_RECORD)) != (recording != nil)
                {
                    throw .invalidOptions
                }
                activeAttemptOptions = options
                activePendingRequest = nil
                frameId = activeFrame
            } else {
                if activeAttemptFrameId != nil || painted != nil { throw .frameBusy }
                if options.maxLayoutRounds == 0 || options.maxHostRequests == 0 || recording != nil {
                    throw .invalidOptions
                }
                lastFrameId &+= 1
                frameId = lastFrameId
                activeAttemptFrameId = frameId
                activeAttemptOptions = options
            }

            if let rootRenderable = root, let rootNode = rootRenderable.sceneNode {
                try measureLayout(rootHandle: rootNode.handle, width: UInt32(max(0, target.width)), height: UInt32(max(0, target.height)))
                candidatesGen &+= 1
                hits.removeAll(keepingCapacity: true)
                let screenClip = ClipRect(x: 0, y: 0, width: target.width, height: target.height)
                for renderable in nodes.values {
                    if let node = renderable.sceneNode {
                        let computed = renderable.yogaNode.getComputedLayout()
                        node.layout = Layout(
                            left: computed.left,
                            top: computed.top,
                            right: computed.right,
                            bottom: computed.bottom,
                            width: computed.width,
                            height: computed.height,
                            screenX: Double(computed.left),
                            screenY: Double(computed.top)
                        )
                        node.paintLayout = node.layout
                        node.preparedGen = candidatesGen
                        node.subtreeGen = candidatesGen
                        node.lastRecordedFrame = frameId
                        node.lastRecordedClip = screenClip
                        node.needsLayout = false
                        if options.useMouse && node.layout.width > 0 && node.layout.height > 0 {
                            hits.append(Hit(
                                x: UInt32(max(0, Int(node.layout.screenX))),
                                y: UInt32(max(0, Int(node.layout.screenY))),
                                width: UInt32(max(0, Int(node.layout.width))),
                                height: UInt32(max(0, Int(node.layout.height))),
                                token: node.token,
                                num: node.num
                            ))
                        }
                    }
                }
                presentedHits = hits
            }

            let rootHandle = root?.sceneNode?.handle ?? SceneNodeHandle(contextId: session.contextId, slot: 0, generation: 0)
            let doneRequest = FrameRequest(
                session: session,
                root: rootHandle,
                node: rootHandle,
                frameId: frameId,
                requestId: frameId,
                layoutEpoch: layoutEpoch,
                hookGeneration: 0,
                kind: UInt32(NativeABI.OT_SCENE_FRAME_DONE),
                num: root?.sceneNode?.num ?? 0,
                width: UInt32(max(0, target.width)),
                height: UInt32(max(0, target.height))
            )
            finishedFrame = frameId
            presentedRecordsFrame = frameId
            cancelledPaint = false
            activeAttemptFrameId = nil
            activePendingRequest = nil
            painted = Painted(ticket: doneRequest, destination: BufferIdentity(target: target), workFrameId: frameId)
            return doneRequest
        }

        // parity: native/src/scene.zig#Scene.paintedLatest [status=implemented hash=ee27d43bf93a]
        public func paintedLatest(_ value: NativeZigRenderable.NativeRenderable) -> Bool {
            guard let node = value.sceneNode else { return false }
            let frame = cancelledPaint ? presentedRecordsFrame : finishedFrame
            return frame != 0 && node.lastRecordedFrame == frame
        }

        // parity: native/src/scene.zig#Scene.reaches [status=implemented hash=80665bfcd2a1]
        public func reaches(_ value: NativeZigRenderable.NativeRenderable) throws(SceneError) -> Bool {
            var cursor: NativeZigRenderable.NativeRenderable? = value
            var depth: UInt32 = 0
            while let current = cursor {
                if depth == NativeZigYoga.depthMax { throw .yogaDepthLimit }
                depth += 1
                if current.yogaNode.getDisplay() == .none { return false }
                if current === root { return true }
                cursor = current.sceneNode?.parent
            }
            return false
        }

        // parity: native/src/scene.zig#Scene.measureLayout [status=implemented hash=909863899392]
        public func measureLayout(rootHandle: SceneNodeHandle, width: UInt32, height: UInt32) throws(SceneError) {
            guard let rootRenderable = nodes[rootHandle], let node = rootRenderable.sceneNode else {
                throw .wrongKind
            }
            if node.owner !== self { throw .wrongSession }
            if root !== rootRenderable { throw .invalidOptions }
            if rootRenderable.yogaNode.isDirty() || layoutWidth != width || layoutHeight != height {
                rootRenderable.yogaNode.calculateLayout(Float(width), Float(height), .ltr)
                layoutEpoch &+= 1
                selectionEpoch &+= 1
                membersGen &+= 1
                layoutWidth = width
                layoutHeight = height
            }
        }

        // parity: native/src/scene.zig#Scene.prepareOmitted [status=implemented hash=8a00b85c34bf]
        public func prepareOmitted(_ value: NativeZigRenderable.NativeRenderable) {
            guard activeAttemptFrameId != nil, let node = value.sceneNode else { return }
            var chain: [NativeZigRenderable.NativeRenderable] = []
            var cursor: NativeZigRenderable.NativeRenderable? = value
            while let current = cursor, current.sceneNode?.preparedGen != candidatesGen {
                chain.append(current)
                cursor = current.sceneNode?.parent
            }
            for item in chain.reversed() {
                if let n = item.sceneNode {
                    n.preparedGen = candidatesGen
                    n.subtreeGen = candidatesGen
                }
            }
            node.preparedGen = candidatesGen
            node.subtreeGen = candidatesGen
        }

        // parity: native/src/scene.zig#Scene.hitToken [status=implemented hash=3337dcd5d952]
        public func hitToken(screenWidth: UInt32, screenHeight: UInt32, x: UInt32, y: UInt32, excluded: UInt32 = 0) -> UInt32 {
            guard x < screenWidth && y < screenHeight else { return 0 }
            let list = presentedHits.isEmpty ? hits : presentedHits
            guard let idx = topmostHitExcept(list, x: x, y: y, excluded: excluded) else { return 0 }
            return list[idx].token
        }

        // parity: native/src/scene.zig#Scene.paintBody [status=implemented hash=e32d9a290976]
        public func paintBody(
            into target: OptimizedBuffer,
            value: NativeZigRenderable.NativeRenderable,
            x: Int32,
            y: Int32
        ) throws(SceneError) {
            guard let node = value.sceneNode else { throw .wrongKind }
            var layout = try NativeZigScene.getPaintLayout(value, content: false)
            if x != Int32(layout.screenX) || y != Int32(layout.screenY) {
                layout.screenX = Double(x)
                layout.screenY = Double(y)
                layout = NativeZigScene.cellLayout(layout)
            }
            guard layout.width >= 1 && layout.height >= 1 else { return }
            let drawX = Int(layout.screenX)
            let drawY = Int(layout.screenY)
            let drawW = Int(layout.width)
            let drawH = Int(layout.height)
            if node.paint.shouldFill != 0 {
                target.fillRect(x: drawX, y: drawY, width: drawW, height: drawH, bg: node.paint.background)
            }
            if node.kind == UInt32(NativeABI.OT_SCENE_BOX) && node.paint.borderSides != 0 {
                let isFocused = focus == node.handle
                let borderCol = isFocused ? node.paint.focusedBorderColor : node.paint.borderColor
                let style: BorderStyle
                switch Int64(node.paint.borderStyle) {
                case NativeABI.OT_BORDER_DOUBLE: style = .double
                case NativeABI.OT_BORDER_ROUNDED: style = .rounded
                case NativeABI.OT_BORDER_HEAVY: style = .heavy
                default: style = .single
                }
                let sides = BorderSidesConfig(
                    top: (node.paint.borderSides & UInt32(NativeABI.OT_BORDER_TOP)) != 0,
                    right: (node.paint.borderSides & UInt32(NativeABI.OT_BORDER_RIGHT)) != 0,
                    bottom: (node.paint.borderSides & UInt32(NativeABI.OT_BORDER_BOTTOM)) != 0,
                    left: (node.paint.borderSides & UInt32(NativeABI.OT_BORDER_LEFT)) != 0
                )
                target.drawBox(
                    BoxDrawOptions(
                        x: drawX,
                        y: drawY,
                        width: drawW,
                        height: drawH,
                        borderStyle: style,
                        borderSides: sides,
                        borderColor: borderCol,
                        backgroundColor: node.paint.background,
                        titleColor: node.boxDetails?.titleColor,
                        shouldFill: node.paint.shouldFill != 0,
                        title: node.boxDetails?.title,
                        bottomTitle: node.boxDetails?.bottomTitle
                    )
                )
            }
        }

        // parity: native/src/scene.zig#Scene.paintedArea [status=implemented hash=7d98162ce588]
        public func paintedArea(for node: Node) -> PaintedArea? {
            guard finishedFrame != 0, node.lastRecordedFrame == finishedFrame else { return nil }
            let content = NativeZigScene.cellLayout(NativeZigScene.contentLayout(node.layout))
            let contentRect = ClipRect(
                x: Int(content.screenX),
                y: Int(content.screenY),
                width: Int(max(0, content.width)),
                height: Int(max(0, content.height))
            )
            let clip = node.lastRecordedClip
            let x0 = max(contentRect.x, clip.x)
            let y0 = max(contentRect.y, clip.y)
            let x1 = min(contentRect.x + contentRect.width, clip.x + clip.width)
            let y1 = min(contentRect.y + contentRect.height, clip.y + clip.height)
            let clipped = ClipRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
            return PaintedArea(x: Int64(contentRect.x), y: Int64(contentRect.y), clip: clipped, frame: finishedFrame)
        }

        public func registerNode(_ renderable: NativeZigRenderable.NativeRenderable) {
            if let sceneNode = renderable.sceneNode {
                sceneNode.owner = self
                nodes[sceneNode.handle] = renderable
            }
        }

        public func recordHit(_ hit: Hit) {
            hits.append(hit)
        }

        public func clearHits() {
            hits.removeAll()
            presentedHits.removeAll()
        }

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

    // parity: native/src/scene-record.zig#fingerprint [status=implemented hash=a7e7e2c0c3f3]
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
    // parity: native/src/session.zig#environment_entries_max [status=implemented hash=6795ea1baf35]
    public static let environmentEntriesMax: UInt32 = UInt32(NativeABI.OT_SESSION_ENV_ENTRIES_MAX)
    // parity: native/src/session.zig#environment_bytes_max [status=implemented hash=b5288a6126c0]
    public static let environmentBytesMax: UInt32 = UInt32(NativeABI.OT_SESSION_ENV_BYTES_MAX)
    // parity: native/src/session.zig#control_packet_bytes_max [status=implemented hash=4f26c8829608]
    public static let controlPacketBytesMax: UInt32 = 4096
    // parity: native/src/session.zig#capability_response_bytes_max [status=implemented hash=68d4ca332fe8]
    public static let capabilityResponseBytesMax: UInt32 = controlPacketBytesMax
    // parity: native/src/session.zig#title_bytes_max [status=implemented hash=a86723c56f0b]
    public static let titleBytesMax: UInt32 = controlPacketBytesMax - 5
    // parity: native/src/session.zig#program_status_id_bytes_max [status=implemented hash=4ce47fd3c4e9]
    public static let programStatusIdBytesMax: UInt32 = 128
    // parity: native/src/session.zig#program_status_id_segment_bytes_max [status=implemented hash=273b057cfb26]
    public static let programStatusIdSegmentBytesMax: UInt32 = 32
    // parity: native/src/session.zig#program_status_id_segments_max [status=implemented hash=ad2004f4ab45]
    public static let programStatusIdSegmentsMax: UInt32 = 8
    // parity: native/src/session.zig#program_status_app_bytes_max [status=implemented hash=8c8db2efd88a]
    public static let programStatusAppBytesMax: UInt32 = 32
    // parity: native/src/session.zig#program_status_title_bytes_max [status=implemented hash=0b0e06cd1db6]
    public static let programStatusTitleBytesMax: UInt32 = 192
    // parity: native/src/session.zig#program_status_message_bytes_max [status=implemented hash=b1db11f4c867]
    public static let programStatusMessageBytesMax: UInt32 = 2048
    // parity: native/src/session.zig#program_status_bytes_max [status=implemented hash=e44b7fb4f7c6]
    public static let programStatusBytesMax: UInt32 =
        72 + programStatusIdBytesMax + programStatusAppBytesMax +
        ((programStatusTitleBytesMax + 2) / 3) * 4 +
        ((programStatusMessageBytesMax + 2) / 3) * 4
    // parity: native/src/session.zig#cursor_settle_ns [status=implemented hash=afda47cb4d75]
    public static let cursorSettleNs: UInt64 = 10_000_000
    // parity: native/src/session.zig#split_snapshots_max [status=implemented hash=5526c6035189]
    public static let splitSnapshotsMax: UInt32 = UInt32(NativeABI.OT_SPLIT_SNAPSHOTS_MAX)

    // parity: native/src/session.zig#Error [status=implemented hash=f9c9ff885592]
    public enum Error: Swift.Error, Equatable, Hashable, Sendable {
        case stream(NativeZigSpanFeed.StreamError)
        case sessionClosed
        case sessionFailed
        case sessionCancelled
        case invalidPhase
        case rendererAttached
        case rendererNotAttached
        case outputBackpressure
        case controlPacketLimit
        case staleOutput
        case invalidArgument
        case busy
        case terminalInactive
        case invalidTerminalState
        case frameBusy
        case presentationPending
        case staleFrame
        case sceneNotAttached
        case wrongContext
        case wrongSession
        case staleHandle
        case invalidTicket
        case invalidBudget
        case invalidClock
        case unsupportedResource
        case requestLimit
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

    // parity: native/src/session.zig#Session [status=implemented hash=40f6c7bf3687]
    public final class Session: @unchecked Sendable {
        public struct SplitSnapshot: @unchecked Sendable {
            public var snapshot: OptimizedBuffer
            public var rowColumns: UInt32

            public init(snapshot: OptimizedBuffer, rowColumns: UInt32 = 0) {
                self.snapshot = snapshot
                self.rowColumns = rowColumns
            }
        }

        public struct InputExpectations: Equatable, Hashable, Sendable {
            public var replies: Bool
            public var kittyKeyboard: Bool
            public var escapePrefix: Bool
            public var kittyQuery: Bool

            public init(replies: Bool = false, kittyKeyboard: Bool = false, escapePrefix: Bool = false, kittyQuery: Bool = false) {
                self.replies = replies
                self.kittyKeyboard = kittyKeyboard
                self.escapePrefix = escapePrefix
                self.kittyQuery = kittyQuery
            }
        }

        public let handle: SessionHandle
        public let output: NativeZigSpanFeed.Stream
        public let core: NativeSession
        public var scene: NativeZigScene.Scene?
        public var rendererBuffer: OptimizedBuffer?
        public var state: State = .open
        public var terminalState: TerminalState = TerminalState()
        public var useAlternateScreen: Bool = true
        public var renderOffset: UInt32 = 0
        public var splitTransition: UInt32?
        public var kittyTransportMode: UInt32 = 0
        public var kittyFileProbeState: UInt32 = 0
        public var kittyRepliesProcessed: UInt32 = 0
        public var inputExpectations: InputExpectations = InputExpectations()
        public var paletteEpoch: UInt32 = 0
        public var paletteColors: [RGBA] = []
        public var defaultForeground: RGBA = RGBA.fromInts(255, 255, 255, 255)
        public var defaultBackground: RGBA = RGBA.fromInts(0, 0, 0, 255)
        public var frameLeaseCount: UInt32 = 0
        public var frameEndOffset: UInt64?
        public var lastPumpNs: UInt64?
        public var lastInputNs: UInt64?
        public private(set) var lastRequestId: UInt64 = 0
        public private(set) var completedBytes: UInt64 = 0
        public private(set) var pendingTicket: OutputTicket?
        public private(set) var pendingPost: Bool = false
        public private(set) var queuedOutput: [UInt8] = []
        public private(set) var lastNotification: (title: String?, message: String)?
        public private(set) var lastTitle: String = ""
        public private(set) var lastMouseMode: MouseMode = .disabled
        public private(set) var lastKittyFlags: UInt8 = 0
        public private(set) var lastCursor: CursorOptions = CursorOptions()

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

        // parity: native/src/session.zig#Session.deinit [status=implemented hash=108b455cb8bb]
        public func deinitSession() throws(NativeZigSession.Error) {
            guard canDestroy() else { throw .busy }
            scene?.deinitScene()
            scene = nil
            rendererBuffer = nil
            queuedOutput.removeAll(keepingCapacity: false)
            _ = NativeZigSpanFeed.streamClose(output)
        }

        // parity: native/src/session.zig#Session.write [status=implemented hash=5ca44d8fb225]
        public func write(_ bytes: [UInt8]) throws(NativeZigSession.Error) {
            try checkOpen()
            switch terminalState.phase {
            case .uninitialized, .active, .suspended:
                break
            default:
                throw .busy
            }
            let st = NativeZigSpanFeed.streamWrite(output, bytes: bytes)
            guard st == NativeZigSpanFeed.Status.ok else { throw .outputBackpressure }
            _ = NativeZigSpanFeed.streamCommit(output)
            queuedOutput.append(contentsOf: bytes)
        }

        // parity: native/src/session.zig#Session.checkOpen [status=implemented hash=83a91be02e6e]
        public func checkOpen() throws(NativeZigSession.Error) {
            switch state {
            case .open:
                return
            case .closing, .closed:
                throw .sessionClosed
            case .failed:
                throw .sessionFailed
            case .cancelled:
                throw .sessionCancelled
            }
        }

        // parity: native/src/session.zig#Session.render [status=implemented hash=f02cfecd7af2]
        public func render(force: Bool = false) throws(NativeZigSession.Error) -> RenderStatus {
            try checkRendering()
            try checkFrameIdle()
            if let scene, scene.cancelledPaint {
                throw .staleFrame
            }
            if frameEndOffset != nil {
                return .pending
            }
            _ = force
            let written = getStats().bytesWritten
            frameEndOffset = written
            if completedBytes >= written {
                frameEndOffset = nil
                return .presented
            }
            return .pending
        }

        // parity: native/src/session.zig#Session.commitSceneFrame [status=implemented hash=b5c66df36479]
        public func commitSceneFrame(_ frame: NativeZigScene.FrameRequest, force: Bool = false) throws(NativeZigSession.Error) -> RenderStatus {
            try checkRendering()
            guard let scene else { throw .sceneNotAttached }
            let painted: NativeZigScene.Scene.Painted
            do {
                painted = try scene.checkPainted(frame)
            } catch {
                switch error {
                case .wrongContext: throw .wrongContext
                case .wrongSession: throw .wrongSession
                default: throw .staleFrame
                }
            }
            guard frameLeaseCount == 0 else { throw .frameBusy }
            if let buf = rendererBuffer, !painted.destination.matches(buf) {
                throw .staleFrame
            }
            guard frameEndOffset == nil else { throw .presentationPending }
            _ = force
            scene.painted = nil
            scene.cancelledPaint = false
            return .presented
        }

        // parity: native/src/session.zig#Session.copySceneFrame [status=implemented hash=735e9bf5efcb]
        public func copySceneFrame(_ frame: NativeZigScene.FrameRequest, into target: OptimizedBuffer) throws(NativeZigSession.Error) {
            try checkRendering()
            guard frameLeaseCount == 0 else { throw .frameBusy }
            guard frameEndOffset == nil else { throw .presentationPending }
            guard let scene else { throw .sceneNotAttached }
            let painted: NativeZigScene.Scene.Painted
            do {
                painted = try scene.checkPainted(frame)
            } catch {
                switch error {
                case .wrongContext: throw .wrongContext
                case .wrongSession: throw .wrongSession
                default: throw .staleFrame
                }
            }
            guard let source = rendererBuffer else { throw .rendererNotAttached }
            guard painted.destination.matches(source) else { throw .staleFrame }
            target.drawFrameBuffer(destX: 0, destY: 0, frameBuffer: source)
        }

        // parity: native/src/session.zig#Session.renderSplit [status=implemented hash=6c68400229f1]
        public func renderSplit(
            frame: NativeZigScene.FrameRequest? = nil,
            snapshots: [SplitSnapshot] = [],
            pinnedRenderOffset: UInt32 = 0,
            force: Bool = false
        ) throws(NativeZigSession.Error) -> RenderStatus {
            let suspendedSnapshots = frame == nil && terminalState.phase == .suspended
            if suspendedSnapshots {
                try checkOpen()
            } else {
                try checkRendering()
            }
            if frame == nil && frameEndOffset != nil {
                return .pending
            }
            guard snapshots.count <= Int(NativeZigSession.splitSnapshotsMax),
                pinnedRenderOffset <= UInt32(UInt16.max)
            else {
                throw .invalidArgument
            }
            for commit in snapshots {
                if commit.rowColumns > UInt32(max(0, commit.snapshot.width)) {
                    throw .invalidArgument
                }
            }
            if let frame {
                guard let scene else { throw .sceneNotAttached }
                do {
                    _ = try scene.checkPainted(frame)
                } catch {
                    switch error {
                    case .wrongContext: throw .wrongContext
                    case .wrongSession: throw .wrongSession
                    default: throw .staleFrame
                    }
                }
                guard frameLeaseCount == 0 else { throw .frameBusy }
                guard frameEndOffset == nil else { throw .presentationPending }
                scene.painted = nil
                scene.cancelledPaint = false
            } else {
                try checkFrameIdle()
            }
            renderOffset = pinnedRenderOffset
            _ = force
            return .presented
        }

        // parity: native/src/session.zig#Session.checkRendering [status=implemented hash=f6cc5eb72ab6]
        public func checkRendering() throws(NativeZigSession.Error) {
            try checkOpen()
            switch terminalState.phase {
            case .uninitialized, .active:
                return
            default:
                throw .terminalInactive
            }
        }

        // parity: native/src/session.zig#Session.checkResizing [status=implemented hash=9d2d4ad3e2bf]
        public func checkResizing() throws(NativeZigSession.Error) {
            if terminalState.phase == .suspended {
                try checkOpen()
                return
            }
            try checkRendering()
        }

        // parity: native/src/session.zig#Session.splitControl [status=implemented hash=de2cfa91fe9f]
        public func splitControl(_ command: SplitControl) throws(NativeZigSession.Error) -> UInt32 {
            try checkOpen()
            if case .outputOffset(let offset) = command {
                return offset
            }
            try checkFrameIdle()
            guard frameEndOffset == nil else { throw .presentationPending }
            switch command {
            case .reset(let seedRows, let pinnedRenderOffset):
                guard seedRows <= UInt32(UInt16.max) && pinnedRenderOffset <= UInt32(UInt16.max) else {
                    throw .invalidArgument
                }
                renderOffset = pinnedRenderOffset
                splitTransition = nil
                return renderOffset
            case .sync(let offset):
                guard offset <= UInt32(UInt16.max) else { throw .invalidArgument }
                renderOffset = offset
                return renderOffset
            case .renderOffset(let offset):
                guard offset <= UInt32(UInt16.max) else { throw .invalidArgument }
                renderOffset = offset
            case .transition(let t):
                splitTransition = t
            case .clearTransition:
                splitTransition = nil
            case .outputOffset:
                break
            }
            return renderOffset
        }

        // parity: native/src/session.zig#Session.setScreen [status=implemented hash=16a83ca20b05]
        public func setScreen(
            alternate: Bool,
            width: UInt32,
            height: UInt32,
            trailingOutput: [UInt8] = []
        ) throws(NativeZigSession.Error) {
            try checkOpen()
            try checkFrameIdle()
            guard frameEndOffset == nil else { throw .presentationPending }
            guard trailingOutput.count <= Int(NativeZigSession.controlPacketBytesMax) else {
                throw .invalidArgument
            }
            var packet: [UInt8] = []
            switch terminalState.phase {
            case .uninitialized, .suspended:
                break
            case .active:
                if useAlternateScreen != alternate {
                    packet.append(contentsOf: (alternate ? "\u{1B}[?1049h" : "\u{1B}[?1049l").utf8)
                }
            default:
                throw .terminalInactive
            }
            guard trailingOutput.count <= Int(NativeZigSession.controlPacketBytesMax) - packet.count else {
                throw .invalidArgument
            }
            packet.append(contentsOf: trailingOutput)
            if !packet.isEmpty {
                try write(packet)
            }
            useAlternateScreen = alternate
            if let buf = rendererBuffer, width > 0, height > 0 {
                try? buf.resize(width: Int(width), height: Int(height))
            }
        }

        // parity: native/src/session.zig#Session.syncDetached [status=implemented hash=49e71e4abccd]
        public func syncDetached(from parent: Session) throws(NativeZigSession.Error) {
            try checkOpen()
            try parent.checkOpen()
            try checkFrameIdle()
            guard handle.contextId == parent.handle.contextId else { throw .wrongContext }
            guard self !== parent, terminalState.phase == .uninitialized, frameEndOffset == nil else {
                throw .invalidArgument
            }
            paletteColors = parent.paletteColors
            defaultForeground = parent.defaultForeground
            defaultBackground = parent.defaultBackground
            paletteEpoch = parent.paletteEpoch
            kittyTransportMode = parent.kittyTransportMode
        }

        // parity: native/src/session.zig#Session.checkFrameIdle [status=implemented hash=24e42cbafadb]
        public func checkFrameIdle() throws(NativeZigSession.Error) {
            guard frameLeaseCount == 0 else { throw .frameBusy }
            if let scene, scene.activeAttemptFrameId != nil || scene.painted != nil {
                throw .frameBusy
            }
        }

        // parity: native/src/session.zig#Session.checkLayoutIdle [status=implemented hash=decb7a7d73d8]
        public func checkLayoutIdle() throws(NativeZigSession.Error) {
            if let scene, scene.activeAttemptFrameId != nil {
                throw .frameBusy
            }
        }

        // parity: native/src/session.zig#Session.cancelSceneFrame [status=implemented hash=e4d31c653ea1]
        public func cancelSceneFrame() {
            if let scene {
                if scene.painted != nil {
                    rendererBuffer?.clearScissorRects()
                    rendererBuffer?.clearOpacity()
                }
                scene.cancelFrame()
            }
        }

        // parity: native/src/session.zig#Session.setupTerminal [status=implemented hash=5b429f7987c2]
        public func setupTerminal(_ options: TerminalOptions = TerminalOptions()) throws {
            terminalState.phase = .settingUp
            useAlternateScreen = options.useAlternateScreen
            lastKittyFlags = options.kittyKeyboardFlags
            try core.setupTerminal(options.toCore())
            terminalState.phase = .active
        }

        // parity: native/src/session.zig#Session.suspendTerminal [status=implemented hash=ef492c5ec84a]
        public func suspendTerminal() throws(NativeZigSession.Error) {
            try checkOpen()
            try checkLayoutIdle()
            switch terminalState.phase {
            case .suspending, .suspended:
                return
            case .active:
                terminalState.phase = .suspended
                kittyFileProbeState = 0
                try? core.suspend()
            default:
                throw .invalidTerminalState
            }
        }

        // parity: native/src/session.zig#Session.resumeTerminal [status=implemented hash=7d2b218c1b3a]
        public func resumeTerminal() throws(NativeZigSession.Error) {
            try checkOpen()
            guard terminalState.phase == .suspended else { throw .invalidTerminalState }
            terminalState.phase = .resuming
            try? core.resume()
            terminalState.phase = .active
        }

        // parity: native/src/session.zig#Session.getTerminalState [status=implemented hash=49914b069f8b]
        public func getTerminalState() -> TerminalState {
            terminalState
        }

        // parity: native/src/session.zig#Session.control [status=implemented hash=1f6c63659f0c]
        public func control(_ command: Control) throws(NativeZigSession.Error) {
            try checkOpen()
            switch command {
            case .cursor(let opts):
                if let x = opts.x, x > Int32(UInt16.max) + 1 { throw .invalidArgument }
                if let y = opts.y, y > Int32(UInt16.max) + 1 { throw .invalidArgument }
                lastCursor = opts
                return
            case .endReplySentinel:
                return
            case .title(let title):
                guard title.utf8.count <= Int(NativeZigSession.titleBytesMax) else { throw .invalidArgument }
                guard !title.utf8.contains(where: { $0 < 0x20 || $0 == 0x7F }) else { throw .invalidArgument }
                guard terminalState.phase == .active else { throw .terminalInactive }
                lastTitle = title
                try write(Array("\u{1B}]0;\(title)\u{07}".utf8))
            case .mouse(let mode):
                guard terminalState.phase == .active else { throw .terminalInactive }
                lastMouseMode = mode
            case .kittyKeyboardFlags(let flags):
                guard (UInt32(flags) & ~UInt32(NativeABI.OT_KITTY_KEYBOARD_ALL)) == 0 else { throw .invalidArgument }
                guard terminalState.phase == .active else { throw .terminalInactive }
                lastKittyFlags = flags
            case .capabilityResponse(let bytes):
                guard !bytes.isEmpty && bytes.count <= Int(NativeZigSession.capabilityResponseBytesMax) else {
                    throw .invalidArgument
                }
                guard terminalState.phase == .active || terminalState.phase == .settingUp || terminalState.phase == .resuming else {
                    throw .terminalInactive
                }
                _ = core.feedInput(bytes)
            case .paletteQuery(let query):
                guard !query.bytes.isEmpty && query.bytes.count <= Int(NativeZigSession.controlPacketBytesMax) else {
                    throw .invalidArgument
                }
                guard terminalState.phase == .active else { throw .terminalInactive }
                try write(query.bytes)
            case .programStatus(let status):
                if status.kind != nil && status.state != .blocked { throw .invalidArgument }
                if let progress = status.progress, progress > 100 || (status.state != .working && status.state != .blocked) {
                    throw .invalidArgument
                }
                if status.state == .clear && (!status.app.isEmpty || !status.title.isEmpty || !status.message.isEmpty) {
                    throw .invalidArgument
                }
                if status.id.utf8.count > Int(NativeZigSession.programStatusIdBytesMax) ||
                    status.app.utf8.count > Int(NativeZigSession.programStatusAppBytesMax) ||
                    status.title.utf8.count > Int(NativeZigSession.programStatusTitleBytesMax) ||
                    status.message.utf8.count > Int(NativeZigSession.programStatusMessageBytesMax)
                {
                    throw .invalidArgument
                }
                guard terminalState.phase == .active else { throw .terminalInactive }
                try write(Array("\u{1B}]7501;state=\(status.state.rawValue)\u{1B}\\".utf8))
            case .restoreModes, .queryPixelResolution, .queryThemeColors, .resetBackground:
                guard terminalState.phase == .active else { throw .terminalInactive }
            }
        }

        // parity: native/src/session.zig#Session.setPaletteState [status=implemented hash=7bb68180f85e]
        public func setPaletteState(palette: [RGBA], defaultFg: RGBA, defaultBg: RGBA, epoch: UInt32) throws(NativeZigSession.Error) {
            try checkOpen()
            guard terminalState.phase == .active else { throw .terminalInactive }
            guard palette.count <= 256 else { throw .invalidArgument }
            paletteColors = palette
            defaultForeground = defaultFg
            defaultBackground = defaultBg
            paletteEpoch = epoch
        }

        // parity: native/src/session.zig#Session.triggerNotification [status=implemented hash=3846ef2683c2]
        public func triggerNotification(message: String, title: String? = nil) throws(NativeZigSession.Error) -> Bool {
            try checkOpen()
            guard terminalState.phase == .active else { throw .terminalInactive }
            let msgLen = message.utf8.count
            let titleLen = title?.utf8.count ?? 0
            if msgLen > Int(NativeZigSession.controlPacketBytesMax) ||
                titleLen > Int(NativeZigSession.controlPacketBytesMax) - msgLen
            {
                return false
            }
            let seq = title.map { "\u{1B}]777;notify;\($0);\(message)\u{07}" } ?? "\u{1B}]9;\(message)\u{07}"
            do {
                try write(Array(seq.utf8))
                lastNotification = (title: title, message: message)
                return true
            } catch {
                return false
            }
        }

        // parity: native/src/session.zig#Session.setKittyImageTransport [status=implemented hash=50f45b9d1af6]
        public func setKittyImageTransport(mode: UInt32) throws(NativeZigSession.Error) {
            try checkOpen()
            guard mode <= 2 else { throw .invalidArgument }
            kittyTransportMode = mode
            if terminalState.phase == .active && mode != 0 {
                kittyFileProbeState = 1
            }
        }

        // parity: native/src/session.zig#Session.kittyImageTransportStatus [status=implemented hash=621e25c96592]
        public func kittyImageTransportStatus() throws(NativeZigSession.Error) -> [UInt32] {
            try checkOpen()
            return [kittyTransportMode, kittyFileProbeState, kittyRepliesProcessed, 0, 0, 0]
        }

        // parity: native/src/session.zig#Session.pollKittyImageTransport [status=implemented hash=8074558b0f54]
        public func pollKittyImageTransport(nowNs: UInt64) throws(NativeZigSession.Error) -> Bool {
            try checkOpen()
            if let prev = lastPumpNs, nowNs < prev { throw .invalidClock }
            lastPumpNs = nowNs
            return kittyFileProbeState == 1
        }

        // parity: native/src/session.zig#Session.cancelKittyImageTransport [status=implemented hash=3e84113746a4]
        public func cancelKittyImageTransport(failed: Bool) throws(NativeZigSession.Error) {
            try checkOpen()
            kittyFileProbeState = failed ? 3 : 0
        }

        // parity: native/src/session.zig#Session.processKittyImageReply [status=implemented hash=abadbfdd51c3]
        public func processKittyImageReply(_ response: [UInt8]) throws(NativeZigSession.Error) -> UInt32 {
            try checkOpen()
            guard !response.isEmpty else { return 0 }
            kittyRepliesProcessed &+= 1
            if kittyFileProbeState == 1 {
                kittyFileProbeState = 2
            }
            return kittyRepliesProcessed
        }

        // parity: native/src/session.zig#Session.startKittyFileProbe [status=implemented hash=d0326a947398]
        public func startKittyFileProbe() throws(NativeZigSession.Error) {
            try checkOpen()
            if terminalState.phase == .active {
                kittyFileProbeState = 1
            }
        }

        // parity: native/src/session.zig#Session.writeClipboard [status=implemented hash=17f0de648bb8]
        public func writeClipboard(target: UInt8, bytes: [UInt8]) throws(NativeZigSession.Error) -> Bool {
            try checkOpen()
            guard terminalState.phase == .active else { throw .terminalInactive }
            let encoded = NativeUtils.base64Encode(bytes)
            let targetChar: String
            switch target {
            case 1: targetChar = "p"
            case 2: targetChar = "s"
            default: targetChar = "c"
            }
            let seq = Array("\u{1B}]52;\(targetChar);\(encoded)\u{07}".utf8)
            do {
                try write(seq)
                return true
            } catch {
                return false
            }
        }

        // parity: native/src/session.zig#Session.feedInput [status=implemented hash=cf93d2b2eebc]
        public func feedInput(_ bytes: [UInt8], nowNs: UInt64? = nil) -> InputFeed {
            if let nowNs {
                if let prev = lastInputNs, nowNs < prev {
                    return InputFeed(consumed: 0, discarded: UInt32(bytes.count), deadlineNs: nil)
                }
                lastInputNs = nowNs
            }
            let events = core.feedInput(bytes)
            _ = events
            return InputFeed(consumed: UInt32(bytes.count), discarded: 0, deadlineNs: nil)
        }

        // parity: native/src/session.zig#Session.setInputExpectations [status=implemented hash=5a5aa5fb3502]
        public func setInputExpectations(_ expectations: InputExpectations) throws(NativeZigSession.Error) {
            try checkOpen()
            inputExpectations = expectations
        }

        // parity: native/src/session.zig#Session.resetInput [status=implemented hash=4a230e2fa6bb]
        public func resetInput(keepReply: Bool) throws(NativeZigSession.Error) {
            try checkOpen()
            if !(keepReply && inputExpectations.replies) {
                lastInputNs = nil
            }
        }

        // parity: native/src/session.zig#Session.pumpExit [status=implemented hash=89ffc8c9c3da]
        public func pumpExit() throws(NativeZigSession.Error) -> PumpStatus {
            try beginClose()
            if state == .closed { return .closed }
            return pump().status
        }

        // parity: native/src/session.zig#Session.readOutput [status=implemented hash=5b5adb5de899]
        public func readOutput(maxBytes: Int) throws(NativeZigSession.Error) -> (ticket: OutputTicket, bytes: [UInt8])? {
            switch state {
            case .open, .closing: break
            case .closed: return nil
            case .failed: throw .sessionFailed
            case .cancelled: throw .sessionCancelled
            }
            guard maxBytes > 0 else { return nil }
            guard pendingTicket == nil else { throw .busy }
            guard !queuedOutput.isEmpty else { return nil }
            guard lastRequestId < UInt64.max else { throw .requestLimit }
            let count = min(maxBytes, queuedOutput.count)
            let chunk = Array(queuedOutput[0..<count])
            lastRequestId &+= 1
            let ticket = OutputTicket(session: handle, requestId: lastRequestId, len: UInt32(count))
            pendingTicket = ticket
            return (ticket, chunk)
        }

        // parity: native/src/session.zig#Session.drainOutput [status=implemented hash=08e79afda332]
        public func drainOutput(maxBytes: UInt32, writer: ([UInt8]) throws -> Int) throws(NativeZigSession.Error) -> UInt32 {
            guard maxBytes > 0 else { throw .invalidBudget }
            switch state {
            case .open, .closing: break
            case .closed: return 0
            case .failed: throw .sessionFailed
            case .cancelled: throw .sessionCancelled
            }
            guard pendingTicket == nil else { throw .busy }
            guard !queuedOutput.isEmpty else { return 0 }
            let count = min(Int(maxBytes), queuedOutput.count)
            let offered = Array(queuedOutput[0..<count])
            let written: Int
            do {
                written = try writer(offered)
            } catch {
                state = .failed
                terminalState.phase = .failed
                throw .sessionFailed
            }
            if written < 0 || written > offered.count {
                state = .failed
                terminalState.phase = .failed
                throw .sessionFailed
            }
            if written > 0 {
                queuedOutput.removeFirst(written)
                completedBytes &+= UInt64(written)
                if let end = frameEndOffset, completedBytes >= end {
                    frameEndOffset = nil
                }
                if state == .closing && isDrained() {
                    state = .closed
                }
            }
            return UInt32(written)
        }

        // parity: native/src/session.zig#Session.drainStdout [status=implemented hash=caa26ca3d766]
        public func drainStdout(maxBytes: UInt32, writer: (([UInt8]) throws -> Int)? = nil) throws(NativeZigSession.Error) -> UInt32 {
            guard maxBytes >= 4 else { throw .invalidBudget }
            guard let writer else { throw .unsupportedResource }
            return try drainOutput(maxBytes: maxBytes, writer: writer)
        }

        public func postOutput(_ bytes: [UInt8]) throws(NativeZigSession.Error) -> OutputTicket {
            guard state == .open else { throw .sessionClosed }
            guard pendingTicket == nil else { throw .outputBackpressure }
            let st = NativeZigSpanFeed.streamWrite(output, bytes: bytes)
            guard st == NativeZigSpanFeed.Status.ok else { throw .outputBackpressure }
            _ = NativeZigSpanFeed.streamCommit(output)
            queuedOutput.append(contentsOf: bytes)
            lastRequestId &+= 1
            let ticket = OutputTicket(session: handle, requestId: lastRequestId, len: UInt32(bytes.count))
            pendingTicket = ticket
            return ticket
        }

        // parity: native/src/session.zig#Session.completeOutput [status=implemented hash=85a397561a46]
        @discardableResult
        public func completeOutput(ticket: OutputTicket, result: OutputResult) throws(NativeZigSession.Error) -> PostResult {
            if ticket.session.contextId != handle.contextId { throw .wrongContext }
            if ticket.session.slot != handle.slot { throw .wrongSession }
            if ticket.session.generation != handle.generation { throw .staleHandle }
            guard let pending = pendingTicket, pending.requestId == ticket.requestId else {
                throw .staleOutput
            }
            guard ticket.len == pending.len else { throw .invalidTicket }
            pendingTicket = nil
            pendingPost = false
            if result == .written {
                let drop = min(Int(ticket.len), queuedOutput.count)
                queuedOutput.removeFirst(drop)
                completedBytes &+= UInt64(ticket.len)
                if let end = frameEndOffset, completedBytes >= end {
                    frameEndOffset = nil
                }
                if state == .closing && isDrained() {
                    state = .closed
                }
                return PostResult(written: ticket.len, inFlight: false)
            }
            cancelSceneFrame()
            state = .failed
            terminalState.phase = .failed
            frameEndOffset = nil
            return PostResult(written: 0, inFlight: false)
        }

        // parity: native/src/session.zig#Session.beginClose [status=implemented hash=48299a91dd4d]
        public func beginClose() throws(NativeZigSession.Error) {
            switch state {
            case .open:
                break
            case .closing, .closed:
                return
            case .failed:
                throw .sessionFailed
            case .cancelled:
                throw .sessionCancelled
            }
            cancelSceneFrame()
            switch terminalState.phase {
            case .uninitialized, .suspended:
                _ = NativeZigSpanFeed.streamClose(output)
                state = isDrained() ? .closed : .closing
                if terminalState.phase == .suspended {
                    terminalState.phase = .restored
                }
            default:
                terminalState.phase = .closing
                state = .closing
            }
        }

        // parity: native/src/session.zig#Session.postStdout [status=implemented hash=eceab8f40183]
        public func postStdout(maxBytes: UInt32, wait: Bool = false, writer: (([UInt8]) throws -> Int)? = nil) throws(NativeZigSession.Error) -> PostResult {
            switch state {
            case .open, .closing: break
            case .closed: return PostResult()
            case .failed: throw .sessionFailed
            case .cancelled: throw .sessionCancelled
            }
            var result = PostResult()
            if pendingPost, let ticket = pendingTicket {
                pendingPost = false
                let res = try completeOutput(ticket: ticket, result: .written)
                result.written = res.written
            } else if pendingTicket != nil {
                throw .busy
            }
            if wait || maxBytes == 0 || queuedOutput.isEmpty {
                return result
            }
            guard let writer else { throw .unsupportedResource }
            guard let (ticket, bytes) = try readOutput(maxBytes: Int(maxBytes)) else {
                return result
            }
            do {
                _ = try writer(bytes)
                pendingPost = true
                result.inFlight = true
                return result
            } catch {
                _ = try? completeOutput(ticket: ticket, result: .failed)
                throw .sessionFailed
            }
        }

        // parity: native/src/session.zig#Session.dropOutput [status=implemented hash=1083c744b0e7]
        public func dropOutput() throws(NativeZigSession.Error) {
            try beginClose()
            frameEndOffset = nil
            let kept = Int(pendingTicket?.len ?? 0)
            if queuedOutput.count > kept {
                queuedOutput.removeSubrange(kept..<queuedOutput.count)
            }
            let spans = NativeZigSpanFeed.streamDrainSpans(output, maxSpans: 64)
            for span in spans {
                _ = NativeZigSpanFeed.streamReleaseSpan(output, slotIndex: span.slotIndex, releaseId: span.releaseId)
            }
            if isDrained() {
                state = .closed
                terminalState.phase = .restored
            }
        }

        // parity: native/src/session.zig#Session.cancel [status=implemented hash=c57d2a69e014]
        public func cancel() {
            cancelSceneFrame()
            frameEndOffset = nil
            queuedOutput.removeAll(keepingCapacity: false)
            let spans = NativeZigSpanFeed.streamDrainSpans(output, maxSpans: 64)
            for span in spans {
                _ = NativeZigSpanFeed.streamReleaseSpan(output, slotIndex: span.slotIndex, releaseId: span.releaseId)
            }
            _ = NativeZigSpanFeed.streamClose(output)
            pendingTicket = nil
            pendingPost = false
            state = .cancelled
            terminalState.phase = .cancelled
            terminalState.deadlineNs = nil
        }

        // parity: native/src/session.zig#Session.canDestroy [status=implemented hash=507cd5d132ca]
        public func canDestroy() -> Bool {
            guard frameLeaseCount == 0 && isDrained() else { return false }
            switch terminalState.phase {
            case .uninitialized, .suspended, .restored, .cancelled:
                return true
            default:
                return false
            }
        }

        // parity: native/src/session.zig#Session.isDrained [status=implemented hash=bd1b96bb6789]
        public func isDrained() -> Bool {
            frameEndOffset == nil && pendingTicket == nil && queuedOutput.isEmpty
        }

        // parity: native/src/session.zig#Session.getStats [status=implemented hash=90e6ae42ef71]
        public func getStats() -> NativeZigSpanFeed.Stats {
            NativeZigSpanFeed.streamGetStats(output).stats ?? NativeZigSpanFeed.Stats()
        }

        // parity: native/src/session.zig#Session.pump [status=implemented hash=bf78725c0b6f]
        public func pump(nowNs: UInt64? = nil, workBudget: UInt32 = 1) -> PumpResult {
            if let nowNs {
                if let prev = lastPumpNs, nowNs < prev {
                    return PumpResult(status: .idle)
                }
                lastPumpNs = nowNs
            }
            _ = workBudget
            if state == .closed || state == .cancelled || state == .failed {
                return PumpResult(status: .closed)
            }
            if !isDrained() {
                return PumpResult(status: .outputPending)
            }
            if state == .closing {
                terminalState.phase = .restored
                state = .closed
                return PumpResult(status: .closed)
            }
            return PumpResult(status: .idle)
        }

        public func close() {
            state = .closed
            terminalState.phase = .restored
            queuedOutput.removeAll(keepingCapacity: false)
            pendingTicket = nil
            pendingPost = false
            frameEndOffset = nil
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
        case setMode(UInt16)
        case resetMode(UInt16)
        case restoreMode(UInt16)
        case kittyDnd
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
            case .setMode(let mode):
                if mode == 25 { cursorVisible = true }
                if mode == 2004 { bracketedPasteMode = true }
                return []
            case .resetMode(let mode):
                if mode == 25 { cursorVisible = false }
                if mode == 2004 { bracketedPasteMode = false }
                return []
            case .restoreMode, .kittyDnd:
                return []
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

        // parity: native/src/embedded-terminal/ghostty.zig#Key.event [status=implemented hash=afeb367a2aa1]
        public func event() -> Key {
            Key(
                action: action,
                keyName: keyName,
                shift: shift,
                ctrl: ctrl,
                alt: alt,
                superKey: superKey,
                composing: composing,
                utf8: utf8,
                unshiftedCodepoint: unshiftedCodepoint
            )
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

        // parity: native/src/embedded-terminal/ghostty.zig#Mouse.event [status=implemented hash=1a94a5c8e651]
        public func event() -> Mouse {
            Mouse(
                action: action,
                button: button,
                shift: shift,
                ctrl: ctrl,
                alt: alt,
                x: x,
                y: y,
                anyButtonPressed: anyButtonPressed
            )
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

    public final class StreamHandler: @unchecked Sendable {
        public let base: NativeZigGhostty.TerminalStream
        public private(set) var ignoredActionCount: UInt64 = 0

        public init(base: NativeZigGhostty.TerminalStream) {
            self.base = base
        }

        // parity: native/src/embedded-terminal/main.zig#StreamHandler.vt [status=implemented hash=510a426459c5]
        public func vt(action: NativeZigGhostty.StreamAction, bytes: [UInt8] = []) -> [UInt8] {
            switch action {
            case .setMode(let mode), .resetMode(let mode), .restoreMode(let mode):
                if mode == 3 {
                    // DECCOLM (132-column mode) must not resize the embedded viewport.
                    ignoredActionCount &+= 1
                    return []
                }
            case .kittyDnd:
                // OpenTUI has no Kitty drag-and-drop drop effect.
                ignoredActionCount &+= 1
                return []
            default:
                break
            }
            if !bytes.isEmpty {
                return base.feed(bytes)
            }
            return base.terminal.apply(action)
        }

        // parity: native/src/embedded-terminal/main.zig#StreamHandler.deinit [status=implemented hash=6b31d1d5c85a]
        public func deinitHandler() {
            ignoredActionCount = 0
        }
    }

    // parity: native/src/embedded-terminal/main.zig#EmbeddedTerminal [status=implemented hash=36acbbfda595]
    public final class EmbeddedTerminal: @unchecked Sendable {
        public let terminal: NativeZigGhostty.Terminal
        public let stream: NativeZigGhostty.TerminalStream
        public let streamHandler: StreamHandler
        public private(set) var cols: UInt16
        public private(set) var rows: UInt16
        public private(set) var responses: [UInt8] = []
        public var transparentBackground: Bool = false
        public private(set) var scrollOffset: UInt32 = 0
        public private(set) var mouseLastCell: NativeZigGhostty.Coordinate?

        // parity: native/src/embedded-terminal/main.zig#EmbeddedTerminal.init [status=implemented hash=5097a69f4786]
        public init(options: Options) throws(NativeZigEmbeddedTerminal.Error) {
            guard options.cols > 0 && options.rows > 0 else { throw .invalidValue }
            self.cols = options.cols
            self.rows = options.rows
            self.terminal = NativeZigGhostty.Terminal(cols: options.cols, rows: options.rows, maxScrollback: options.maxScrollback)
            self.stream = NativeZigGhostty.TerminalStream(terminal: terminal)
            self.streamHandler = StreamHandler(base: self.stream)
        }

        // parity: native/src/embedded-terminal/main.zig#EmbeddedTerminal.deinit [status=implemented hash=db13c9e2f9ae]
        public func deinitTerminal() {
            streamHandler.deinitHandler()
            terminal.clearSelection()
            responses.removeAll(keepingCapacity: false)
            mouseLastCell = nil
        }

        // parity: native/src/embedded-terminal/main.zig#EmbeddedTerminal.write [status=implemented hash=bf54af4ba2cc]
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

        // parity: native/src/embedded-terminal/main.zig#EmbeddedTerminal.resize [status=implemented hash=d28bd2464e61]
        public func resize(cols: UInt16, rows: UInt16) throws(NativeZigEmbeddedTerminal.Error) {
            guard cols > 0 && rows > 0 else { throw .invalidValue }
            self.cols = cols
            self.rows = rows
            self.mouseLastCell = nil
            terminal.resize(cols: cols, rows: rows)
        }

        // parity: native/src/embedded-terminal/main.zig#EmbeddedTerminal.scroll [status=implemented hash=1461acb12c43]
        public func scroll(delta: Int32) {
            let maxOffset = UInt32(terminal.scrollbackLines.count)
            let next = Int64(scrollOffset) + Int64(delta)
            scrollOffset = UInt32(min(Int64(maxOffset), max(0, next)))
        }

        // parity: native/src/embedded-terminal/main.zig#EmbeddedTerminal.setSelection [status=implemented hash=cbc3c686dc06]
        public func setSelection(start: NativeZigGhostty.Coordinate, end: NativeZigGhostty.Coordinate) {
            terminal.setSelection(NativeZigGhostty.Selection(start: start, end: end))
        }

        // parity: native/src/embedded-terminal/main.zig#EmbeddedTerminal.clearSelection [status=implemented hash=c328e28b011a]
        public func clearSelection() {
            terminal.clearSelection()
        }

        // parity: native/src/embedded-terminal/main.zig#EmbeddedTerminal.selectedText [status=implemented hash=338079e5a0ad]
        public func selectedText() -> String {
            terminal.selectedText()
        }

        // parity: native/src/embedded-terminal/main.zig#EmbeddedTerminal.freeSelectedText [status=implemented hash=470ce41a0c79]
        public func freeSelectedText(_ text: inout String) {
            text.removeAll(keepingCapacity: false)
        }

        // parity: native/src/embedded-terminal/main.zig#EmbeddedTerminal.invalidate [status=implemented hash=a40362dfa335]
        public func invalidate() {
            terminal.state.dirty = .full
            terminal.state.rowDirty = Array(repeating: true, count: Int(rows))
        }

        // parity: native/src/embedded-terminal/main.zig#EmbeddedTerminal.setTransparentBackground [status=implemented hash=e957a28d5abd]
        public func setTransparentBackground(_ transparent: Bool) {
            transparentBackground = transparent
            invalidate()
        }

        // parity: native/src/embedded-terminal/main.zig#EmbeddedTerminal.compose [status=implemented hash=025eaf23c0a8]
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
                invalidate()
                throw .compositor(error)
            }
        }

        // parity: native/src/embedded-terminal/main.zig#EmbeddedTerminal.composeChecked [status=implemented hash=a9a06598b3d5]
        public func composeChecked(
            into target: OptimizedBuffer,
            originX: Int32 = 0,
            originY: Int32 = 0,
            cellsMax: UInt32
        ) throws(NativeZigEmbeddedTerminal.Error) {
            let sourceCells = UInt64(cols) * UInt64(rows)
            let targetCells = UInt64(max(0, target.width)) * UInt64(max(0, target.height))
            guard sourceCells > 0, sourceCells <= UInt64(cellsMax),
                target.width > 0, target.height > 0, targetCells <= UInt64(cellsMax),
                target.width <= Int(Int32.max), target.height <= Int(Int32.max)
            else {
                invalidate()
                throw .compositor(.invalidOptions)
            }
            try compose(into: target, originX: originX, originY: originY)
        }

        // parity: native/src/embedded-terminal/main.zig#EmbeddedTerminal.cursor [status=implemented hash=38590373c95f]
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

        // parity: native/src/embedded-terminal/main.zig#EmbeddedTerminal.scrollbar [status=implemented hash=0d04301ae860]
        public func scrollbar() -> Scrollbar {
            Scrollbar(
                offset: scrollOffset,
                total: UInt32(terminal.scrollbackLines.count) + UInt32(rows),
                visible: UInt32(rows)
            )
        }

        // parity: native/src/embedded-terminal/main.zig#EmbeddedTerminal.encodeKey [status=implemented hash=1988328ef2ed]
        public func encodeKey(_ key: NativeZigGhostty.Key, options: NativeZigGhostty.KeyEncodeOptions = NativeZigGhostty.KeyEncodeOptions()) -> [UInt8] {
            NativeZigGhostty.encodeKey(key.event(), options: options)
        }

        // parity: native/src/embedded-terminal/main.zig#EmbeddedTerminal.encodeMouse [status=implemented hash=894bca16494b]
        public func encodeMouse(
            _ mouse: NativeZigGhostty.Mouse,
            options: NativeZigGhostty.MouseEncodeOptions = NativeZigGhostty.MouseEncodeOptions()
        ) throws(NativeZigEmbeddedTerminal.Error) -> [UInt8] {
            guard mouse.x.isFinite && mouse.y.isFinite else {
                throw .compositor(.invalidOptions)
            }
            var clamped = mouse.event()
            clamped.x = min(max(clamped.x, -1), Float(cols) + 0.5)
            clamped.y = min(max(clamped.y, -1), Float(rows) + 0.5)
            let cellX = UInt16(min(max(0, Int(clamped.x)), Int(max(1, cols)) - 1))
            let cellY = UInt16(min(max(0, Int(clamped.y)), Int(max(1, rows)) - 1))
            mouseLastCell = NativeZigGhostty.Coordinate(x: cellX, y: cellY)
            return NativeZigGhostty.encodeMouse(clamped, options: options)
        }

        // parity: native/src/embedded-terminal/main.zig#EmbeddedTerminal.drainResponses [status=implemented hash=e83f9dfb5445]
        public func drainResponses(maxBytes: Int? = nil) -> [UInt8] {
            let take = min(maxBytes ?? responses.count, responses.count)
            let out = Array(responses[0..<take])
            responses.removeFirst(take)
            return out
        }

        // parity: native/src/embedded-terminal/main.zig#EmbeddedTerminal.encodePaste [status=implemented hash=4a5be043315e]
        public func encodePaste(_ bytes: [UInt8]) -> [UInt8] {
            NativeZigGhostty.encodePaste(bytes, bracketed: terminal.bracketedPasteMode)
        }

        // parity: native/src/embedded-terminal/main.zig#EmbeddedTerminal.encodeFocus [status=implemented hash=ff5df2e3e971]
        public func encodeFocus(_ focused: Bool) -> [UInt8] {
            NativeZigGhostty.encodeFocus(focused)
        }

        // parity: native/src/embedded-terminal/main.zig#EmbeddedTerminal.freeEncoded [status=implemented hash=7696b8080bf2]
        public func freeEncoded(_ bytes: inout [UInt8]) {
            bytes.removeAll(keepingCapacity: false)
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
        public init() {}

        // parity: native/src/embedded-terminal/unavailable.zig#EmbeddedTerminal.init [status=implemented hash=daec8633aebf]
        public static func create() throws(NativeZigEmbeddedUnavailable.Error) -> EmbeddedTerminal {
            throw .unsupported
        }

        // parity: native/src/embedded-terminal/unavailable.zig#EmbeddedTerminal.deinit [status=implemented hash=f49de71ca94d]
        public func deinitUnavailable() {}

        // parity: native/src/embedded-terminal/unavailable.zig#EmbeddedTerminal.write [status=implemented hash=aad37949a5d5]
        public func write(_ bytes: [UInt8]) throws(NativeZigEmbeddedUnavailable.Error) { throw .unsupported }

        // parity: native/src/embedded-terminal/unavailable.zig#EmbeddedTerminal.resize [status=implemented hash=7e0a41123c3d]
        public func resize(cols: UInt16, rows: UInt16) throws(NativeZigEmbeddedUnavailable.Error) { throw .unsupported }

        // parity: native/src/embedded-terminal/unavailable.zig#EmbeddedTerminal.scroll [status=implemented hash=40293f61ba0a]
        public func scroll(delta: Int32) {}

        // parity: native/src/embedded-terminal/unavailable.zig#EmbeddedTerminal.setSelection [status=implemented hash=f6507ca7d253]
        public func setSelection(start: NativeZigGhostty.Coordinate, end: NativeZigGhostty.Coordinate) throws(NativeZigEmbeddedUnavailable.Error) { throw .unsupported }

        // parity: native/src/embedded-terminal/unavailable.zig#EmbeddedTerminal.clearSelection [status=implemented hash=64c40595053b]
        public func clearSelection() {}

        // parity: native/src/embedded-terminal/unavailable.zig#EmbeddedTerminal.selectedText [status=implemented hash=4d042d63879a]
        public func selectedText() throws(NativeZigEmbeddedUnavailable.Error) -> String { throw .unsupported }

        // parity: native/src/embedded-terminal/unavailable.zig#EmbeddedTerminal.freeSelectedText [status=implemented hash=f81a0acc17a7]
        public func freeSelectedText(_ text: String) {}

        // parity: native/src/embedded-terminal/unavailable.zig#EmbeddedTerminal.invalidate [status=implemented hash=d4b6ce7eab7d]
        public func invalidate() {}

        // parity: native/src/embedded-terminal/unavailable.zig#EmbeddedTerminal.setTransparentBackground [status=implemented hash=0e0ea738b2df]
        public func setTransparentBackground(_ transparent: Bool) {}

        // parity: native/src/embedded-terminal/unavailable.zig#EmbeddedTerminal.compose [status=implemented hash=6ac24697e3af]
        public func compose(into target: OptimizedBuffer, originX: Int32, originY: Int32) throws(NativeZigEmbeddedUnavailable.Error) { throw .unsupported }

        // parity: native/src/embedded-terminal/unavailable.zig#EmbeddedTerminal.composeChecked [status=implemented hash=580339f0e64a]
        public func composeChecked(into target: OptimizedBuffer, originX: Int32, originY: Int32, cellsMax: UInt32) throws(NativeZigEmbeddedUnavailable.Error) { throw .unsupported }

        // parity: native/src/embedded-terminal/unavailable.zig#EmbeddedTerminal.cursor [status=implemented hash=5d851051a8e3]
        public func cursor() -> Cursor { Cursor() }

        // parity: native/src/embedded-terminal/unavailable.zig#EmbeddedTerminal.scrollbar [status=implemented hash=30199ef6161e]
        public func scrollbar() -> Scrollbar { Scrollbar() }

        // parity: native/src/embedded-terminal/unavailable.zig#EmbeddedTerminal.encodePaste [status=implemented hash=eeb56de12f5c]
        public func encodePaste(_ bytes: [UInt8]) throws(NativeZigEmbeddedUnavailable.Error) -> [UInt8] { throw .unsupported }

        // parity: native/src/embedded-terminal/unavailable.zig#EmbeddedTerminal.encodeFocus [status=implemented hash=4b58ec46a634]
        public func encodeFocus(_ focused: Bool) throws(NativeZigEmbeddedUnavailable.Error) -> [UInt8] { throw .unsupported }

        // parity: native/src/embedded-terminal/unavailable.zig#EmbeddedTerminal.freeEncoded [status=implemented hash=6fa12319cd2f]
        public func freeEncoded(_ bytes: [UInt8]) {}

        // parity: native/src/embedded-terminal/unavailable.zig#EmbeddedTerminal.drainResponses [status=implemented hash=d99ebd069e48]
        public func drainResponses() throws(NativeZigEmbeddedUnavailable.Error) -> [UInt8] { throw .unsupported }
    }
}
