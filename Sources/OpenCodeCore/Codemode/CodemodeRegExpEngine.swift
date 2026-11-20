// Pure-Swift ECMAScript 2025 (ECMA-262 §22.2 + Annex B §B.1.2) Regular Expression Engine.
// Uses only the Swift standard library (no Foundation / ICU / OS imports) and operates directly
// on UTF-16 code units (`[UInt16]`), decoding code points under `u` (unicode) and `v` (unicodeSets).

// MARK: - Public Flags, Errors & Match Results

public struct ECMAScriptRegExpFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let hasIndices  = ECMAScriptRegExpFlags(rawValue: 1 << 0) // d
    public static let global      = ECMAScriptRegExpFlags(rawValue: 1 << 1) // g
    public static let ignoreCase  = ECMAScriptRegExpFlags(rawValue: 1 << 2) // i
    public static let multiline   = ECMAScriptRegExpFlags(rawValue: 1 << 3) // m
    public static let dotAll      = ECMAScriptRegExpFlags(rawValue: 1 << 4) // s
    public static let unicode     = ECMAScriptRegExpFlags(rawValue: 1 << 5) // u
    public static let unicodeSets = ECMAScriptRegExpFlags(rawValue: 1 << 6) // v
    public static let sticky      = ECMAScriptRegExpFlags(rawValue: 1 << 7) // y

    public var isUnicodeMode: Bool {
        contains(.unicode) || contains(.unicodeSets)
    }

    /// Canonical flag string in alphabetical order (`dgimsuvy`).
    public var canonicalString: String {
        var s = ""
        if contains(.hasIndices)  { s.append("d") }
        if contains(.global)      { s.append("g") }
        if contains(.ignoreCase)  { s.append("i") }
        if contains(.multiline)   { s.append("m") }
        if contains(.dotAll)      { s.append("s") }
        if contains(.unicode)     { s.append("u") }
        if contains(.unicodeSets) { s.append("v") }
        if contains(.sticky)      { s.append("y") }
        return s
    }

    public init(parsing units: [UInt16]) throws(ECMAScriptRegExpError) {
        var result: ECMAScriptRegExpFlags = []
        for u in units {
            let bit: ECMAScriptRegExpFlags
            switch u {
            case 0x64: bit = .hasIndices  // d
            case 0x67: bit = .global      // g
            case 0x69: bit = .ignoreCase  // i
            case 0x6D: bit = .multiline   // m
            case 0x73: bit = .dotAll      // s
            case 0x75: bit = .unicode     // u
            case 0x76: bit = .unicodeSets // v
            case 0x79: bit = .sticky      // y
            default:
                throw ECMAScriptRegExpError(
                    kind: .invalidFlags,
                    reason: "Invalid flags supplied to RegExp constructor."
                )
            }
            if result.contains(bit) {
                throw ECMAScriptRegExpError(
                    kind: .invalidFlags,
                    reason: "Invalid flags supplied to RegExp constructor."
                )
            }
            result.insert(bit)
        }
        if result.contains(.unicode) && result.contains(.unicodeSets) {
            throw ECMAScriptRegExpError(
                kind: .invalidFlags,
                reason: "Invalid flags supplied to RegExp constructor."
            )
        }
        self = result
    }

    public init(parsing string: String) throws(ECMAScriptRegExpError) {
        try self.init(parsing: Array(string.utf16))
    }
}

public struct ECMAScriptRegExpError: Error, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case invalidFlags
        case invalidPattern
    }

    public let kind: Kind
    public let reason: String

    public init(kind: Kind, reason: String) {
        self.kind = kind
        self.reason = reason
    }
}

public struct ECMAScriptRegExpMatch: Sendable, Equatable {
    /// UTF-16 code unit range of the full match (`captures[0]`).
    public let range: Range<Int>
    /// Capture group UTF-16 ranges; index 0 is always non-nil (full match); 1...N are nil when unmatched.
    public let captures: [Range<Int>?]
    /// Ordered unique named capturing group names defined on the pattern.
    public let namedGroupNames: [String]
    /// Map from group name to matched UTF-16 range (or nil if unmatched).
    public let namedCaptures: [String: Range<Int>?]
    /// Whether the `d` (`hasIndices`) flag was active on the pattern.
    public let hasIndices: Bool
}

// MARK: - Compiled ECMAScript RegExp

public struct ECMAScriptRegExp: Sendable {
    public let patternUnits: [UInt16]
    public let flags: ECMAScriptRegExpFlags
    public let captureCount: Int
    public let namedGroupNames: [String]
    private let namedGroupIndices: [String: [Int]]
    private let compiled: CompiledProgram

    public init(pattern: [UInt16], flags: [UInt16]) throws(ECMAScriptRegExpError) {
        let parsedFlags = try ECMAScriptRegExpFlags(parsing: flags)
        try self.init(pattern: pattern, flags: parsedFlags)
    }

    public init(pattern: String, flags: String) throws(ECMAScriptRegExpError) {
        try self.init(pattern: Array(pattern.utf16), flags: Array(flags.utf16))
    }

    public init(pattern: [UInt16], flags: ECMAScriptRegExpFlags) throws(ECMAScriptRegExpError) {
        self.patternUnits = pattern
        self.flags = flags
        var parser = RegExpParser(units: pattern, flags: flags)
        let parsed = try parser.parse()
        self.captureCount = parsed.captureCount
        self.namedGroupNames = parsed.namedGroupNames
        self.namedGroupIndices = parsed.namedGroupIndices
        self.compiled = RegExpCompiler.compile(
            root: parsed.root,
            captureCount: parsed.captureCount,
            unicodeMode: flags.isUnicodeMode
        )
    }

    /// Normalized `RegExp.prototype.source` (ECMA-262 EscapeRegExpPattern) as UTF-16 code units.
    public var escapedSourceUnits: [UInt16] {
        Self.escapePattern(patternUnits)
    }

    /// Normalized `RegExp.prototype.source` as a Swift `String`.
    public var escapedSource: String {
        String(decoding: escapedSourceUnits, as: UTF16.self)
    }

    /// Execute pattern against UTF-16 `input` starting at `startIndex`.
    /// - Parameters:
    ///   - input: UTF-16 code unit buffer.
    ///   - startIndex: Starting UTF-16 index (clamped >= 0). If `> input.count`, returns `nil`.
    ///   - anchored: Overrides `flags.contains(.sticky)` when non-nil.
    ///   - checkInterrupt: Periodically invoked during backtracking so host timeouts/cancellation abort execution.
    public func exec(
        in input: [UInt16],
        startIndex: Int = 0,
        anchored: Bool? = nil,
        checkInterrupt: (() throws -> Void)? = nil
    ) throws -> ECMAScriptRegExpMatch? {
        let sticky = anchored ?? flags.contains(.sticky)
        let unicodeMode = flags.isUnicodeMode
        var pos = max(0, startIndex)
        let len = input.count
        if pos > len { return nil }

        // In u/v mode, if startIndex points between a surrogate pair, back up to the lead surrogate (ECMA-262).
        if unicodeMode, pos > 0, pos < len,
           Self.isLeadSurrogate(input[pos - 1]), Self.isTrailSurrogate(input[pos]) {
            pos -= 1
        }

        var vm = RegExpVM(program: compiled, input: input, checkInterrupt: checkInterrupt)
        while pos <= len {
            if let (starts, ends) = try vm.runAt(pos: pos) {
                var captures: [Range<Int>?] = []
                captures.reserveCapacity(captureCount + 1)
                captures.append(pos..<ends[0])
                for i in 1...max(1, captureCount) where i <= captureCount {
                    let s = starts[i]
                    let e = ends[i]
                    if s >= 0 && e >= 0 {
                        captures.append(s..<e)
                    } else {
                        captures.append(nil)
                    }
                }
                var named: [String: Range<Int>?] = [:]
                if !namedGroupNames.isEmpty {
                    named.reserveCapacity(namedGroupNames.count)
                    for name in namedGroupNames {
                        var found: Range<Int>? = nil
                        if let indices = namedGroupIndices[name] {
                            for idx in indices {
                                if let r = captures[idx] {
                                    found = r
                                    break
                                }
                            }
                        }
                        named[name] = found
                    }
                }
                return ECMAScriptRegExpMatch(
                    range: pos..<ends[0],
                    captures: captures,
                    namedGroupNames: namedGroupNames,
                    namedCaptures: named,
                    hasIndices: flags.contains(.hasIndices)
                )
            }
            if sticky { return nil }
            if pos == len { break }
            pos = Self.advanceIndex(in: input, from: pos, unicode: unicodeMode)
        }
        return nil
    }

    // MARK: - Static ECMAScript Utility Algorithms (UTF-16)

    @inline(__always)
    static func isLeadSurrogate(_ u: UInt16) -> Bool {
        u >= 0xD800 && u <= 0xDBFF
    }

    @inline(__always)
    static func isTrailSurrogate(_ u: UInt16) -> Bool {
        u >= 0xDC00 && u <= 0xDFFF
    }

    @inline(__always)
    static func isLineTerminator(_ cp: UInt32) -> Bool {
        cp == 0x000A || cp == 0x000D || cp == 0x2028 || cp == 0x2029
    }

    @inline(__always)
    static func isASCIIWord(_ cp: UInt32) -> Bool {
        (cp >= 0x30 && cp <= 0x39)
            || (cp >= 0x41 && cp <= 0x5A)
            || (cp >= 0x61 && cp <= 0x7A)
            || cp == 0x5F
    }

    /// ECMA-262 AdvanceStringIndex(S, index, unicode).
    public static func advanceIndex(in units: [UInt16], from index: Int, unicode: Bool) -> Int {
        guard unicode, index >= 0, index + 1 < units.count else { return index + 1 }
        if isLeadSurrogate(units[index]) && isTrailSurrogate(units[index + 1]) {
            return index + 2
        }
        return index + 1
    }

    /// ECMA-262 EscapeRegExpPattern(P, F) on UTF-16 code units.
    public static func escapePattern(_ units: [UInt16]) -> [UInt16] {
        if units.isEmpty {
            return [0x28, 0x3F, 0x3A, 0x29] // "(?:)"
        }
        var out: [UInt16] = []
        out.reserveCapacity(units.count + 4)
        var inClass = false
        var escaped = false
        for u in units {
            if escaped {
                escaped = false
                switch u {
                case 0x000A: out.append(0x6E) // \n
                case 0x000D: out.append(0x72) // \r
                case 0x2028: out.append(contentsOf: [0x75, 0x32, 0x30, 0x32, 0x38]) // \u2028
                case 0x2029: out.append(contentsOf: [0x75, 0x32, 0x30, 0x32, 0x39]) // \u2029
                default: out.append(u)
                }
                continue
            }
            switch u {
            case 0x005C: // '\'
                escaped = true
                out.append(u)
            case 0x005B: // '['
                inClass = true
                out.append(u)
            case 0x005D: // ']'
                inClass = false
                out.append(u)
            case 0x002F: // '/'
                if !inClass { out.append(0x005C) }
                out.append(u)
            case 0x000A:
                out.append(contentsOf: [0x005C, 0x006E])
            case 0x000D:
                out.append(contentsOf: [0x005C, 0x0072])
            case 0x2028:
                out.append(contentsOf: [0x005C, 0x0075, 0x0032, 0x0030, 0x0032, 0x0038])
            case 0x2029:
                out.append(contentsOf: [0x005C, 0x0075, 0x0032, 0x0030, 0x0032, 0x0039])
            default:
                out.append(u)
            }
        }
        return out
    }

    /// ES2025 RegExp.escape(S) / EncodeForRegExpEscape on UTF-16 code units.
    public static func escape(_ units: [UInt16]) -> [UInt16] {
        var out: [UInt16] = []
        out.reserveCapacity(units.count * 2)

        func hexDigit(_ nibble: UInt32) -> UInt16 {
            nibble < 10 ? UInt16(0x30 + nibble) : UInt16(0x61 + nibble - 10)
        }
        func appendHex2(_ v: UInt32) {
            out.append(0x5C) // \
            out.append(0x78) // x
            out.append(hexDigit((v >> 4) & 0xF))
            out.append(hexDigit(v & 0xF))
        }
        func appendHex4(_ v: UInt32) {
            out.append(0x5C) // \
            out.append(0x75) // u
            out.append(hexDigit((v >> 12) & 0xF))
            out.append(hexDigit((v >> 8) & 0xF))
            out.append(hexDigit((v >> 4) & 0xF))
            out.append(hexDigit(v & 0xF))
        }

        var i = 0
        var isFirst = true
        while i < units.count {
            let u = units[i]
            let cp: UInt32
            let step: Int
            if isLeadSurrogate(u) && i + 1 < units.count && isTrailSurrogate(units[i + 1]) {
                cp = 0x10000 + (UInt32(u - 0xD800) << 10) + UInt32(units[i + 1] - 0xDC00)
                step = 2
            } else {
                cp = UInt32(u)
                step = 1
            }

            if isFirst {
                isFirst = false
                // First character: ASCII alphanumeric [0-9A-Za-z] is escaped as \xHH
                if (cp >= 0x30 && cp <= 0x39) || (cp >= 0x41 && cp <= 0x5A) || (cp >= 0x61 && cp <= 0x7A) {
                    appendHex2(cp)
                    i += step
                    continue
                }
            }

            switch cp {
            // SyntaxCharacter + '/'
            case 0x5E, 0x24, 0x5C, 0x2E, 0x2A, 0x2B, 0x3F, 0x28, 0x29, 0x5B, 0x5D, 0x7B, 0x7D, 0x7C, 0x2F:
                out.append(0x5C)
                out.append(UInt16(cp))
            // ControlEscape
            case 0x09: out.append(contentsOf: [0x5C, 0x74]) // \t
            case 0x0A: out.append(contentsOf: [0x5C, 0x6E]) // \n
            case 0x0B: out.append(contentsOf: [0x5C, 0x76]) // \v
            case 0x0C: out.append(contentsOf: [0x5C, 0x66]) // \f
            case 0x0D: out.append(contentsOf: [0x5C, 0x72]) // \r
            // OtherPunctuator: , - = < > # & ! % : ; @ ~ ' ` "
            case 0x2C, 0x2D, 0x3D, 0x3C, 0x3E, 0x23, 0x26, 0x21, 0x25, 0x3A, 0x3B, 0x40, 0x7E, 0x27, 0x60, 0x22:
                appendHex2(cp)
            // WhiteSpace & LineTerminator
            case 0x0020, 0x00A0:
                appendHex2(cp)
            case 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
                appendHex4(cp)
            // Lone surrogates
            case 0xD800...0xDFFF:
                appendHex4(cp)
            default:
                if step == 2 {
                    out.append(units[i])
                    out.append(units[i + 1])
                } else {
                    out.append(u)
                }
            }
            i += step
        }
        return out
    }

    public static func escape(_ string: String) -> String {
        String(decoding: escape(Array(string.utf16)), as: UTF16.self)
    }

    /// ECMA-262 GetSubstitution on UTF-16 code units: `$$`, `$&`, `` $` ``, `$'`, `$n`/`$nn`, and `$<name>`.
    public static func expandReplacement(
        template: [UInt16],
        input: [UInt16],
        matchRange: Range<Int>,
        captures: [[UInt16]?],
        namedCaptures: [String: [UInt16]?]?
    ) -> [UInt16] {
        var out: [UInt16] = []
        out.reserveCapacity(template.count)
        let pos = min(max(0, matchRange.lowerBound), input.count)
        let tailStart = min(max(pos, matchRange.upperBound), input.count)
        var i = 0
        while i < template.count {
            let c = template[i]
            guard c == 0x24, i + 1 < template.count else {
                out.append(c)
                i += 1
                continue
            }
            let n = template[i + 1]
            switch n {
            case 0x24: // $$
                out.append(0x24)
                i += 2
            case 0x26: // $&
                out.append(contentsOf: input[pos..<tailStart])
                i += 2
            case 0x60: // $`
                out.append(contentsOf: input[0..<pos])
                i += 2
            case 0x27: // $'
                out.append(contentsOf: input[tailStart..<input.count])
                i += 2
            case 0x30...0x39: // $n or $nn
                let d1 = Int(n - 0x30)
                var consumed = 2
                var index = d1
                if i + 2 < template.count, template[i + 2] >= 0x30 && template[i + 2] <= 0x39 {
                    let two = d1 * 10 + Int(template[i + 2] - 0x30)
                    if two >= 1 && two <= captures.count {
                        index = two
                        consumed = 3
                    }
                }
                if index >= 1 && index <= captures.count {
                    if let cap = captures[index - 1] {
                        out.append(contentsOf: cap)
                    }
                    i += consumed
                } else {
                    out.append(c)
                    i += 1
                }
            case 0x3C: // $<name>
                guard let named = namedCaptures else {
                    out.append(c)
                    i += 1
                    continue
                }
                var closeIdx: Int? = nil
                var j = i + 2
                while j < template.count {
                    if template[j] == 0x3E { closeIdx = j; break }
                    j += 1
                }
                guard let close = closeIdx else {
                    out.append(c)
                    i += 1
                    continue
                }
                let name = String(decoding: template[(i + 2)..<close], as: UTF16.self)
                if let entry = named[name], let cap = entry {
                    out.append(contentsOf: cap)
                }
                i = close + 1
            default:
                out.append(c)
                i += 1
            }
        }
        return out
    }
}

// MARK: - AST

private typealias CPRange = RegExpUnicodeData.CodePointRange

private indirect enum PatternNode: Sendable {
    case empty
    case sequence([PatternNode])
    case disjunction([PatternNode])
    case literal(cp: UInt32, ignoreCase: Bool)
    case dot(dotAll: Bool)
    case charClass(ranges: [CPRange], strings: [[UInt32]], ignoreCase: Bool)
    case anchorStart(multiline: Bool)
    case anchorEnd(multiline: Bool)
    case wordBoundary(negated: Bool, ignoreCase: Bool)
    case capture(index: Int, name: String?, body: PatternNode)
    case quantifier(body: PatternNode, min: Int, max: Int?, greedy: Bool, firstCapture: Int, captureCount: Int)
    case backref(indices: [Int], ignoreCase: Bool)
    case namedBackrefPlaceholder(name: String, ignoreCase: Bool)
    case lookaround(positive: Bool, behind: Bool, body: PatternNode)
}

// MARK: - Parser (ECMA-262 ES2025 + Annex B)

private struct ParsedPattern {
    let root: PatternNode
    let captureCount: Int
    let namedGroupNames: [String]
    let namedGroupIndices: [String: [Int]]
}

private struct RegExpParser {
    let units: [UInt16]
    let flags: ECMAScriptRegExpFlags
    let unicode: Bool
    let unicodeSets: Bool
    var unicodeMode: Bool { unicode || unicodeSets }

    // Lexical modifier flags (overridden by ES2025 `(?ims-ims:...)`)
    var ignoreCase: Bool
    var multiline: Bool
    var dotAll: Bool

    var pos: Int = 0
    var totalCaptures: Int = 0
    var hasNamedGroups: Bool = false
    var nextCapture: Int = 1
    var namedGroupOrder: [String] = []
    var namedGroupIndices: [String: [Int]] = [:]

    // Standard character class ranges
    private static let digitRanges: [CPRange] = [CPRange(lower: 0x30, upper: 0x39)]
    private static let wordRangesASCII: [CPRange] = [
        CPRange(lower: 0x30, upper: 0x39),
        CPRange(lower: 0x41, upper: 0x5A),
        CPRange(lower: 0x5F, upper: 0x5F),
        CPRange(lower: 0x61, upper: 0x7A),
    ]
    private static let wordRangesUnicodeIC: [CPRange] = [
        CPRange(lower: 0x30, upper: 0x39),
        CPRange(lower: 0x41, upper: 0x5A),
        CPRange(lower: 0x5F, upper: 0x5F),
        CPRange(lower: 0x61, upper: 0x7A),
        CPRange(lower: 0x017F, upper: 0x017F), // ſ
        CPRange(lower: 0x212A, upper: 0x212A), // K
    ]
    private static let whitespaceRanges: [CPRange] = [
        CPRange(lower: 0x0009, upper: 0x000D),
        CPRange(lower: 0x0020, upper: 0x0020),
        CPRange(lower: 0x00A0, upper: 0x00A0),
        CPRange(lower: 0x1680, upper: 0x1680),
        CPRange(lower: 0x2000, upper: 0x200A),
        CPRange(lower: 0x2028, upper: 0x2029),
        CPRange(lower: 0x202F, upper: 0x202F),
        CPRange(lower: 0x205F, upper: 0x205F),
        CPRange(lower: 0x3000, upper: 0x3000),
        CPRange(lower: 0xFEFF, upper: 0xFEFF),
    ]

    init(units: [UInt16], flags: ECMAScriptRegExpFlags) {
        self.units = units
        self.flags = flags
        self.unicode = flags.contains(.unicode)
        self.unicodeSets = flags.contains(.unicodeSets)
        self.ignoreCase = flags.contains(.ignoreCase)
        self.multiline = flags.contains(.multiline)
        self.dotAll = flags.contains(.dotAll)
    }

    private func error(_ reason: String) -> ECMAScriptRegExpError {
        ECMAScriptRegExpError(kind: .invalidPattern, reason: reason)
    }

    private var maxCP: UInt32 { unicodeMode ? 0x10FFFF : 0xFFFF }

    private var atEnd: Bool { pos >= units.count }

    @inline(__always)
    private func peek(_ offset: Int = 0) -> UInt16? {
        let idx = pos + offset
        return idx < units.count ? units[idx] : nil
    }

    /// Reads one code unit (non-u) or one Unicode code point (u/v) at `pos` and advances `pos`.
    private mutating func readChar() -> UInt32 {
        let u = units[pos]
        pos += 1
        if unicodeMode, ECMAScriptRegExp.isLeadSurrogate(u), pos < units.count,
           ECMAScriptRegExp.isTrailSurrogate(units[pos]) {
            let lo = units[pos]
            pos += 1
            return 0x10000 + (UInt32(u - 0xD800) << 10) + UInt32(lo - 0xDC00)
        }
        return UInt32(u)
    }

    /// Pre-scan pattern to count total capturing groups and detect whether any named groups exist.
    private mutating func prescan() {
        var i = 0
        var classDepth = 0
        var count = 0
        var named = false
        while i < units.count {
            let u = units[i]
            if u == 0x5C { // '\'
                i += 2
                continue
            }
            if classDepth > 0 {
                if u == 0x5D { // ']'
                    classDepth -= 1
                } else if unicodeSets && u == 0x5B { // nested '[' in v-mode
                    classDepth += 1
                }
                i += 1
                continue
            }
            if u == 0x5B { // '['
                classDepth = 1
                i += 1
                continue
            }
            if u == 0x28 { // '('
                if i + 1 < units.count && units[i + 1] == 0x3F { // '(?'
                    if i + 2 < units.count && units[i + 2] == 0x3C { // '(?<'
                        let next = i + 3 < units.count ? units[i + 3] : 0
                        if next != 0x3D && next != 0x21 { // not (?<= or (?<!
                            count += 1
                            named = true
                        }
                    }
                } else {
                    count += 1
                }
            }
            i += 1
        }
        totalCaptures = count
        hasNamedGroups = named
    }

    mutating func parse() throws(ECMAScriptRegExpError) -> ParsedPattern {
        prescan()
        let (rawRoot, _) = try parseDisjunction()
        if !atEnd {
            if peek() == 0x29 {
                throw error("unmatched parentheses")
            }
            throw error("unexpected token")
        }
        let resolvedRoot = try resolveNamedBackrefs(rawRoot)
        return ParsedPattern(
            root: resolvedRoot,
            captureCount: nextCapture - 1,
            namedGroupNames: namedGroupOrder,
            namedGroupIndices: namedGroupIndices
        )
    }

    private func resolveNamedBackrefs(_ node: PatternNode) throws(ECMAScriptRegExpError) -> PatternNode {
        switch node {
        case .namedBackrefPlaceholder(let name, let ic):
            guard let indices = namedGroupIndices[name], !indices.isEmpty else {
                throw error("invalid named capture referenced")
            }
            return .backref(indices: indices, ignoreCase: ic)
        case .sequence(let items):
            var out: [PatternNode] = []
            out.reserveCapacity(items.count)
            for item in items { out.append(try resolveNamedBackrefs(item)) }
            return .sequence(out)
        case .disjunction(let alts):
            var out: [PatternNode] = []
            out.reserveCapacity(alts.count)
            for alt in alts { out.append(try resolveNamedBackrefs(alt)) }
            return .disjunction(out)
        case .capture(let idx, let name, let body):
            return .capture(index: idx, name: name, body: try resolveNamedBackrefs(body))
        case .quantifier(let body, let min, let max, let greedy, let firstCap, let capCount):
            return .quantifier(
                body: try resolveNamedBackrefs(body),
                min: min,
                max: max,
                greedy: greedy,
                firstCapture: firstCap,
                captureCount: capCount
            )
        case .lookaround(let positive, let behind, let body):
            return .lookaround(positive: positive, behind: behind, body: try resolveNamedBackrefs(body))
        default:
            return node
        }
    }

    private mutating func parseDisjunction() throws(ECMAScriptRegExpError) -> (PatternNode, Set<String>) {
        var alts: [PatternNode] = []
        var unionNames = Set<String>()
        while true {
            let (alt, names) = try parseAlternative()
            alts.append(alt)
            unionNames.formUnion(names)
            if peek() == 0x7C { // '|'
                pos += 1
            } else {
                break
            }
        }
        if alts.count == 1 {
            return (alts[0], unionNames)
        }
        return (.disjunction(alts), unionNames)
    }

    private mutating func parseAlternative() throws(ECMAScriptRegExpError) -> (PatternNode, Set<String>) {
        var terms: [PatternNode] = []
        var seqNames = Set<String>()
        while !atEnd {
            let u = units[pos]
            if u == 0x7C || u == 0x29 { break } // '|' or ')'
            let (term, termNames) = try parseTerm()
            for name in termNames {
                if !seqNames.insert(name).inserted {
                    throw error("duplicate capture group name")
                }
            }
            terms.append(term)
        }
        if terms.isEmpty { return (.empty, seqNames) }
        if terms.count == 1 { return (terms[0], seqNames) }
        return (.sequence(terms), seqNames)
    }

    private mutating func parseTerm() throws(ECMAScriptRegExpError) -> (PatternNode, Set<String>) {
        let u = units[pos]

        // Non-quantifiable assertions: ^, $
        if u == 0x5E { // '^'
            pos += 1
            try rejectQuantifierAfterAssertion()
            return (.anchorStart(multiline: multiline), [])
        }
        if u == 0x24 { // '$'
            pos += 1
            try rejectQuantifierAfterAssertion()
            return (.anchorEnd(multiline: multiline), [])
        }

        // Check for \b or \B assertion
        if u == 0x5C, let next = peek(1), next == 0x62 || next == 0x42 {
            pos += 2
            try rejectQuantifierAfterAssertion()
            return (.wordBoundary(negated: next == 0x42, ignoreCase: ignoreCase), [])
        }

        // Standalone quantifier characters (*, +, ?) are syntax errors
        if u == 0x2A || u == 0x2B || u == 0x3F {
            throw error("nothing to repeat")
        }

        // Standalone '{' quantifier check
        if u == 0x7B {
            if let _ = try tryParseBracedQuantifier(asStandaloneCheck: true) {
                throw error("nothing to repeat")
            }
            if unicodeMode {
                throw error("lone quantifier brackets")
            }
            // Annex B: literal '{'
            pos += 1
            return try applyOptionalQuantifier(atom: .literal(cp: 0x7B, ignoreCase: ignoreCase), names: [], capStart: nextCapture, capCount: 0)
        }

        // Standalone '}' or ']'
        if u == 0x7D || u == 0x5D {
            if unicodeMode {
                throw error(u == 0x7D ? "lone quantifier brackets" : "lone closing bracket")
            }
            pos += 1
            return try applyOptionalQuantifier(atom: .literal(cp: UInt32(u), ignoreCase: ignoreCase), names: [], capStart: nextCapture, capCount: 0)
        }

        let capBefore = nextCapture
        let (atom, atomNames, isAssertion, isLookahead) = try parseAtom()
        let capAfter = nextCapture
        let capCount = capAfter - capBefore

        if isAssertion {
            // In u/v mode, NO assertion can be quantified.
            // In non-u mode (Annex B), only positive/negative lookahead (?=...) / (?!...) is quantifiable.
            if !unicodeMode && isLookahead {
                return try applyOptionalQuantifier(atom: atom, names: atomNames, capStart: capBefore, capCount: capCount)
            }
            try rejectQuantifierAfterAssertion()
            return (atom, atomNames)
        }

        return try applyOptionalQuantifier(atom: atom, names: atomNames, capStart: capBefore, capCount: capCount)
    }

    private mutating func rejectQuantifierAfterAssertion() throws(ECMAScriptRegExpError) {
        guard let next = peek() else { return }
        if next == 0x2A || next == 0x2B || next == 0x3F {
            throw error("nothing to repeat")
        }
        if next == 0x7B {
            let saved = pos
            if let _ = try tryParseBracedQuantifier(asStandaloneCheck: true) {
                throw error("nothing to repeat")
            }
            pos = saved
        }
    }

    private mutating func applyOptionalQuantifier(
        atom: PatternNode,
        names: Set<String>,
        capStart: Int,
        capCount: Int
    ) throws(ECMAScriptRegExpError) -> (PatternNode, Set<String>) {
        guard let next = peek() else { return (atom, names) }
        var minCount = 0
        var maxCount: Int? = nil
        var matched = false

        switch next {
        case 0x2A: // '*'
            pos += 1; minCount = 0; maxCount = nil; matched = true
        case 0x2B: // '+'
            pos += 1; minCount = 1; maxCount = nil; matched = true
        case 0x3F: // '?'
            pos += 1; minCount = 0; maxCount = 1; matched = true
        case 0x7B: // '{'
            if let (lo, hi) = try tryParseBracedQuantifier(asStandaloneCheck: false) {
                minCount = lo; maxCount = hi; matched = true
            }
        default:
            break
        }

        guard matched else { return (atom, names) }

        var greedy = true
        if peek() == 0x3F { // lazy '?'
            pos += 1
            greedy = false
        }

        // Note: any immediately following *, +, ?, or valid {n,m} will be caught as "nothing to repeat" on the next term.
        return (.quantifier(body: atom, min: minCount, max: maxCount, greedy: greedy, firstCapture: capStart, captureCount: capCount), names)
    }

    /// Parses `{n}`, `{n,}`, `{n,m}` at `pos` (which points at `{`).
    /// Returns nil if not a valid quantifier syntax (restores `pos`).
    /// Throws if syntax is `{n,m}` with `n > m` (or lone `{` in u/v mode if invalid? No, caller checks lone `{`).
    private mutating func tryParseBracedQuantifier(asStandaloneCheck: Bool) throws(ECMAScriptRegExpError) -> (Int, Int?)? {
        let saved = pos
        guard peek() == 0x7B else { return nil }
        pos += 1
        guard let first = peek(), first >= 0x30 && first <= 0x39 else {
            pos = saved
            return nil
        }
        let lo = parseDecimalSaturating()
        guard let sep = peek() else {
            pos = saved
            return nil
        }
        if sep == 0x7D { // '{n}'
            pos += 1
            return (lo, lo)
        }
        if sep == 0x2C { // '{n,...}'
            pos += 1
            if peek() == 0x7D { // '{n,}'
                pos += 1
                return (lo, nil)
            }
            guard let d = peek(), d >= 0x30 && d <= 0x39 else {
                pos = saved
                return nil
            }
            let hi = parseDecimalSaturating()
            guard peek() == 0x7D else {
                pos = saved
                return nil
            }
            pos += 1
            if !asStandaloneCheck && hi < lo {
                throw error("numbers out of order in {} quantifier")
            }
            return (lo, hi)
        }
        pos = saved
        return nil
    }

    private mutating func parseDecimalSaturating() -> Int {
        var val = 0
        let limit = Int.max / 10 - 10
        while let u = peek(), u >= 0x30 && u <= 0x39 {
            pos += 1
            if val < limit {
                val = val * 10 + Int(u - 0x30)
            } else {
                val = Int.max
            }
        }
        return val
    }

    private mutating func parseAtom() throws(ECMAScriptRegExpError) -> (PatternNode, Set<String>, isAssertion: Bool, isLookahead: Bool) {
        let u = units[pos]

        // Dot '.'
        if u == 0x2E {
            pos += 1
            return (.dot(dotAll: dotAll), [], false, false)
        }

        // Character class '[...]'
        if u == 0x5B {
            let node = try parseCharacterClass()
            return (node, [], false, false)
        }

        // Parenthesized group or assertion '(...)'
        if u == 0x28 {
            return try parseGroup()
        }

        // Backslash escape
        if u == 0x5C {
            let node = try parseAtomEscape()
            return (node, [], false, false)
        }

        // Ordinary pattern character
        let cp = readChar()
        return (.literal(cp: cp, ignoreCase: ignoreCase), [], false, false)
    }

    // MARK: Groups, Assertions & ES2025 Modifiers

    private mutating func parseGroup() throws(ECMAScriptRegExpError) -> (PatternNode, Set<String>, isAssertion: Bool, isLookahead: Bool) {
        pos += 1 // consume '('
        if peek() == 0x3F { // '(?'
            pos += 1 // consume '?'
            guard let kind = peek() else {
                throw error("invalid group")
            }
            switch kind {
            case 0x3A: // '(?:...)' non-capturing
                pos += 1
                let (body, names) = try parseDisjunction()
                try expectCloseParen()
                return (body, names, false, false)

            case 0x3D: // '(?=...)' positive lookahead
                pos += 1
                let (body, names) = try parseDisjunction()
                try expectCloseParen()
                return (.lookaround(positive: true, behind: false, body: body), names, true, true)

            case 0x21: // '(?!...)' negative lookahead
                pos += 1
                let (body, names) = try parseDisjunction()
                try expectCloseParen()
                return (.lookaround(positive: false, behind: false, body: body), names, true, true)

            case 0x3C: // '(?<=...)', '(?<!...)', or '(?<name>...)'
                pos += 1
                guard let afterLt = peek() else {
                    throw error("invalid group")
                }
                if afterLt == 0x3D || afterLt == 0x21 {
                    pos += 1
                    let (body, names) = try parseDisjunction()
                    try expectCloseParen()
                    return (.lookaround(positive: afterLt == 0x3D, behind: true, body: body), names, true, false)
                }
                // Named capturing group: (?<name>...)
                let name = try parseGroupName()
                let capIdx = nextCapture
                nextCapture += 1
                if namedGroupIndices[name] == nil {
                    namedGroupOrder.append(name)
                    namedGroupIndices[name] = [capIdx]
                } else {
                    namedGroupIndices[name]!.append(capIdx)
                }
                let (body, innerNames) = try parseDisjunction()
                try expectCloseParen()
                if innerNames.contains(name) {
                    throw error("duplicate capture group name")
                }
                var allNames = innerNames
                allNames.insert(name)
                return (.capture(index: capIdx, name: name, body: body), allNames, false, false)

            case 0x69, 0x6D, 0x73, 0x2D: // ES2025 inline modifiers: (?ims-ims:...)
                let (addI, addM, addS, remI, remM, remS) = try parseModifierFlags()
                let savedI = ignoreCase, savedM = multiline, savedS = dotAll
                if addI { ignoreCase = true } else if remI { ignoreCase = false }
                if addM { multiline = true } else if remM { multiline = false }
                if addS { dotAll = true } else if remS { dotAll = false }
                let (body, names) = try parseDisjunction()
                ignoreCase = savedI; multiline = savedM; dotAll = savedS
                try expectCloseParen()
                return (body, names, false, false)

            default:
                throw error("invalid group")
            }
        }

        // Plain capturing group '(...)'
        let capIdx = nextCapture
        nextCapture += 1
        let (body, names) = try parseDisjunction()
        try expectCloseParen()
        return (.capture(index: capIdx, name: nil, body: body), names, false, false)
    }

    private mutating func expectCloseParen() throws(ECMAScriptRegExpError) {
        guard peek() == 0x29 else {
            throw error("missing )")
        }
        pos += 1
    }

    private mutating func parseModifierFlags() throws(ECMAScriptRegExpError) -> (Bool, Bool, Bool, Bool, Bool, Bool) {
        var addI = false, addM = false, addS = false
        var remI = false, remM = false, remS = false
        var inRemove = false
        var seenAny = false
        while let u = peek() {
            if u == 0x3A { // ':'
                pos += 1
                if !seenAny { throw error("invalid group") }
                return (addI, addM, addS, remI, remM, remS)
            }
            if u == 0x2D { // '-'
                if inRemove { throw error("invalid group") }
                inRemove = true
                pos += 1
                continue
            }
            switch u {
            case 0x69: // 'i'
                if addI || remI { throw error("repeated flag in modifier group") }
                if inRemove { remI = true } else { addI = true }
            case 0x6D: // 'm'
                if addM || remM { throw error("repeated flag in modifier group") }
                if inRemove { remM = true } else { addM = true }
            case 0x73: // 's'
                if addS || remS { throw error("repeated flag in modifier group") }
                if inRemove { remS = true } else { addS = true }
            default:
                throw error("invalid group")
            }
            seenAny = true
            pos += 1
        }
        throw error("invalid group")
    }

    /// Parses `RegExpIdentifierName>` after `<` has been consumed.
    private mutating func parseGroupName() throws(ECMAScriptRegExpError) -> String {
        var nameUnits: [UInt16] = []
        var first = true
        while !atEnd {
            let u = units[pos]
            if u == 0x3E { // '>'
                pos += 1
                if nameUnits.isEmpty {
                    throw error("invalid capture group name")
                }
                return String(decoding: nameUnits, as: UTF16.self)
            }
            let cp: UInt32
            if u == 0x5C { // '\uXXXX' or '\u{...}'
                pos += 1
                guard peek() == 0x75 else {
                    throw error("invalid capture group name")
                }
                pos += 1
                cp = try parseUnicodeEscapeValue(forceUnicodeMode: true)
            } else {
                // Group names always decode surrogate pairs as Unicode code points
                let lead = units[pos]
                pos += 1
                if ECMAScriptRegExp.isLeadSurrogate(lead), pos < units.count,
                   ECMAScriptRegExp.isTrailSurrogate(units[pos]) {
                    let lo = units[pos]
                    pos += 1
                    cp = 0x10000 + (UInt32(lead - 0xD800) << 10) + UInt32(lo - 0xDC00)
                } else {
                    cp = UInt32(lead)
                }
            }
            if first {
                guard RegExpUnicodeData.isRegExpIdentifierStart(cp) else {
                    throw error("invalid capture group name")
                }
                first = false
            } else {
                guard RegExpUnicodeData.isRegExpIdentifierPart(cp) else {
                    throw error("invalid capture group name")
                }
            }
            appendCodePointUTF16(cp, to: &nameUnits)
        }
        throw error("invalid capture group name")
    }

    private func appendCodePointUTF16(_ cp: UInt32, to out: inout [UInt16]) {
        if cp <= 0xFFFF {
            out.append(UInt16(cp))
        } else {
            let v = cp - 0x10000
            out.append(UInt16(0xD800 + (v >> 10)))
            out.append(UInt16(0xDC00 + (v & 0x3FF)))
        }
    }

    // MARK: Escapes

    private mutating func parseAtomEscape() throws(ECMAScriptRegExpError) -> PatternNode {
        pos += 1 // consume '\'
        guard let u = peek() else {
            throw error("\\ at end of pattern")
        }

        // Character class escapes: \d \D \s \S \w \W
        switch u {
        case 0x64: pos += 1; return makeBuiltinClass(.digit, negated: false)
        case 0x44: pos += 1; return makeBuiltinClass(.digit, negated: true)
        case 0x73: pos += 1; return makeBuiltinClass(.space, negated: false)
        case 0x53: pos += 1; return makeBuiltinClass(.space, negated: true)
        case 0x77: pos += 1; return makeBuiltinClass(.word, negated: false)
        case 0x57: pos += 1; return makeBuiltinClass(.word, negated: true)
        default: break
        }

        // Unicode property escapes: \p{...}, \P{...}
        if (u == 0x70 || u == 0x50) && unicodeMode {
            pos += 1
            return try parseUnicodePropertyEscape(negated: u == 0x50)
        }

        // Named backreference: \k<name>
        if u == 0x6B {
            if unicodeMode || hasNamedGroups {
                pos += 1
                guard peek() == 0x3C else {
                    throw error("invalid named capture referenced")
                }
                pos += 1
                let name = try parseGroupName()
                return .namedBackrefPlaceholder(name: name, ignoreCase: ignoreCase)
            }
            // Non-u without any named groups: identity escape 'k'
            pos += 1
            return .literal(cp: 0x6B, ignoreCase: ignoreCase)
        }

        // Decimal escapes: \0, \1..\9, legacy octals
        if u >= 0x30 && u <= 0x39 {
            return try parseDecimalEscapeOutsideClass()
        }

        // Control letter escape: \cX
        if u == 0x63 {
            pos += 1
            if let letter = peek(), (letter >= 0x41 && letter <= 0x5A) || (letter >= 0x61 && letter <= 0x7A) {
                pos += 1
                return .literal(cp: UInt32(letter % 32), ignoreCase: ignoreCase)
            }
            if unicodeMode {
                throw error("invalid escape")
            }
            // Annex B: \c not followed by ASCII letter -> literal '\' (back up before 'c')
            pos -= 1
            return .literal(cp: 0x5C, ignoreCase: ignoreCase)
        }

        // Standard character escapes (\f \n \r \t \v \x \u identity)
        let cp = try parseSimpleCharacterEscape(inClass: false)
        return .literal(cp: cp, ignoreCase: ignoreCase)
    }

    private mutating func parseDecimalEscapeOutsideClass() throws(ECMAScriptRegExpError) -> PatternNode {
        let first = units[pos]
        if first == 0x30 { // '\0'
            pos += 1
            if let next = peek(), next >= 0x30 && next <= 0x39 {
                if unicodeMode {
                    throw error("invalid decimal escape")
                }
                // Annex B legacy octal: \0 followed by octal digits, or \0 followed by 8/9 -> NUL
                if next <= 0x37 {
                    var val = Int(next - 0x30)
                    pos += 1
                    if let d2 = peek(), d2 >= 0x30 && d2 <= 0x37 {
                        val = val * 8 + Int(d2 - 0x30)
                        pos += 1
                    }
                    return .literal(cp: UInt32(val), ignoreCase: ignoreCase)
                }
                return .literal(cp: 0, ignoreCase: ignoreCase)
            }
            return .literal(cp: 0, ignoreCase: ignoreCase)
        }

        // Starts with 1..9
        let saved = pos
        let dec = parseDecimalSaturating()
        if unicodeMode {
            if dec > totalCaptures {
                throw error("invalid decimal escape")
            }
            return .backref(indices: [dec], ignoreCase: ignoreCase)
        }
        // Non-u mode (Annex B): if dec <= totalCaptures -> backreference
        if dec <= totalCaptures {
            return .backref(indices: [dec], ignoreCase: ignoreCase)
        }
        // Otherwise rewind and parse LegacyOctalEscapeSequence (if 1..7) or literal digit (8/9)
        pos = saved
        let cp = parseLegacyOctalOrDigit()
        return .literal(cp: cp, ignoreCase: ignoreCase)
    }

    /// Annex B LegacyOctalEscapeSequence: `[0-3][0-7]{0,2}` | `[4-7][0-7]{0,1}` | `[89]` literal.
    private mutating func parseLegacyOctalOrDigit() -> UInt32 {
        let d0 = units[pos]
        pos += 1
        if d0 == 0x38 || d0 == 0x39 {
            return UInt32(d0)
        }
        var val = Int(d0 - 0x30)
        if let d1 = peek(), d1 >= 0x30 && d1 <= 0x37 {
            val = val * 8 + Int(d1 - 0x30)
            pos += 1
            if d0 <= 0x33, let d2 = peek(), d2 >= 0x30 && d2 <= 0x37 {
                val = val * 8 + Int(d2 - 0x30)
                pos += 1
            }
        }
        return UInt32(val)
    }

    /// Parses `\f`, `\n`, `\r`, `\t`, `\v`, `\xHH`, `\uHHHH`, `\u{...}`, and IdentityEscape.
    /// Assumes `\` has already been consumed and `!atEnd`.
    private mutating func parseSimpleCharacterEscape(inClass: Bool) throws(ECMAScriptRegExpError) -> UInt32 {
        let u = units[pos]
        switch u {
        case 0x66: pos += 1; return 0x0C // \f
        case 0x6E: pos += 1; return 0x0A // \n
        case 0x72: pos += 1; return 0x0D // \r
        case 0x74: pos += 1; return 0x09 // \t
        case 0x76: pos += 1; return 0x0B // \v
        case 0x78: // \xHH
            pos += 1
            if let h1 = peek(0).flatMap(hexValue), let h2 = peek(1).flatMap(hexValue) {
                pos += 2
                return (h1 << 4) | h2
            }
            if unicodeMode { throw error("invalid escape") }
            return 0x78 // literal 'x'
        case 0x75: // \uHHHH or \u{H...}
            pos += 1
            if let cp = try tryParseUnicodeEscape(forceUnicodeMode: unicodeMode) {
                return cp
            }
            if unicodeMode { throw error("invalid unicode escape") }
            return 0x75 // literal 'u'
        default:
            // IdentityEscape
            if unicodeMode {
                let valid: Bool
                if unicodeSets && inClass {
                    valid = isVClassIdentityEscape(u)
                } else if inClass {
                    valid = isSyntaxChar(u) || u == 0x2F || u == 0x2D // SyntaxCharacter | '/' | '-'
                } else {
                    valid = isSyntaxChar(u) || u == 0x2F // SyntaxCharacter | '/'
                }
                if !valid {
                    throw error("invalid escape")
                }
                pos += 1
                return UInt32(u)
            }
            return readChar()
        }
    }

    private mutating func parseUnicodeEscapeValue(forceUnicodeMode: Bool) throws(ECMAScriptRegExpError) -> UInt32 {
        guard let cp = try tryParseUnicodeEscape(forceUnicodeMode: forceUnicodeMode) else {
            throw error("invalid unicode escape")
        }
        return cp
    }

    /// Assumes `\u` has been consumed. Handles `\u{...}` (when `forceUnicodeMode`), `\uHHHH`,
    /// and paired `\uD800-\uDBFF\uDC00-\uDFFF` (when `forceUnicodeMode`).
    private mutating func tryParseUnicodeEscape(forceUnicodeMode: Bool) throws(ECMAScriptRegExpError) -> UInt32? {
        if forceUnicodeMode && peek() == 0x7B { // '{'
            pos += 1
            var val: UInt32 = 0
            var digits = 0
            while let u = peek(), let h = hexValue(u) {
                pos += 1
                digits += 1
                if val <= 0x10FFFF {
                    val = (val << 4) | h
                }
            }
            guard digits > 0, peek() == 0x7D, val <= 0x10FFFF else {
                throw error("invalid unicode escape")
            }
            pos += 1
            return val
        }
        guard let h1 = peek(0).flatMap(hexValue),
              let h2 = peek(1).flatMap(hexValue),
              let h3 = peek(2).flatMap(hexValue),
              let h4 = peek(3).flatMap(hexValue) else {
            return nil
        }
        pos += 4
        let codeUnit = (h1 << 12) | (h2 << 8) | (h3 << 4) | h4
        // In Unicode mode, combine \uD800-\uDBFF followed immediately by \uDC00-\uDFFF into one code point!
        if forceUnicodeMode, codeUnit >= 0xD800 && codeUnit <= 0xDBFF {
            let saved = pos
            if peek(0) == 0x5C, peek(1) == 0x75,
               let l1 = peek(2).flatMap(hexValue),
               let l2 = peek(3).flatMap(hexValue),
               let l3 = peek(4).flatMap(hexValue),
               let l4 = peek(5).flatMap(hexValue) {
                let lo = (l1 << 12) | (l2 << 8) | (l3 << 4) | l4
                if lo >= 0xDC00 && lo <= 0xDFFF {
                    pos += 6
                    return 0x10000 + ((codeUnit - 0xD800) << 10) + (lo - 0xDC00)
                }
            }
            pos = saved
        }
        return codeUnit
    }

    private func hexValue(_ u: UInt16) -> UInt32? {
        if u >= 0x30 && u <= 0x39 { return UInt32(u - 0x30) }
        if u >= 0x41 && u <= 0x46 { return UInt32(u - 0x41 + 10) }
        if u >= 0x61 && u <= 0x66 { return UInt32(u - 0x61 + 10) }
        return nil
    }

    private func isSyntaxChar(_ u: UInt16) -> Bool {
        switch u {
        case 0x5E, 0x24, 0x5C, 0x2E, 0x2A, 0x2B, 0x3F, 0x28, 0x29, 0x5B, 0x5D, 0x7B, 0x7D, 0x7C:
            return true
        default:
            return false
        }
    }

    private func isVClassIdentityEscape(_ u: UInt16) -> Bool {
        if isSyntaxChar(u) || u == 0x2F || u == 0x2D { return true }
        // ClassSetReservedPunctuator: & ! # % , : ; < = > @ ` ~
        switch u {
        case 0x26, 0x21, 0x23, 0x25, 0x2C, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x40, 0x60, 0x7E:
            return true
        default:
            return false
        }
    }

    private func isVClassSyntaxChar(_ u: UInt16) -> Bool {
        // ( ) [ ] { } / - \ |
        switch u {
        case 0x28, 0x29, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x2D, 0x5C, 0x7C:
            return true
        default:
            return false
        }
    }

    private func isVReservedDoublePunctuator(_ u: UInt16) -> Bool {
        // & ! # $ % * + , . : ; < = > ? @ ^ ` ~ -
        switch u {
        case 0x26, 0x21, 0x23, 0x24, 0x25, 0x2A, 0x2B, 0x2C, 0x2E, 0x3A, 0x3B,
             0x3C, 0x3D, 0x3E, 0x3F, 0x40, 0x5E, 0x60, 0x7E, 0x2D:
            return true
        default:
            return false
        }
    }

    // MARK: Builtin & Unicode Property Classes

    private enum BuiltinClassKind { case digit, space, word }

    private func builtinClassRanges(_ kind: BuiltinClassKind) -> [CPRange] {
        switch kind {
        case .digit: return Self.digitRanges
        case .space: return Self.whitespaceRanges
        case .word: return (unicodeMode && ignoreCase) ? Self.wordRangesUnicodeIC : Self.wordRangesASCII
        }
    }

    private func makeBuiltinClass(_ kind: BuiltinClassKind, negated: Bool) -> PatternNode {
        let base = builtinClassRanges(kind)
        // Note: For \D, \S, \W, ECMA-262 CharacterSetMatcher sets invert=true on the base set.
        // Because digit/space/word(with u+i) are closed under Canonicalize, complement(base) is already canonicalized!
        let ranges = negated ? RegExpUnicodeData.complementRanges(base, maxCodePoint: maxCP) : base
        return .charClass(ranges: ranges, strings: [], ignoreCase: false)
    }

    private mutating func parseUnicodePropertyRaw() throws(ECMAScriptRegExpError) -> RegExpUnicodeData.PropertyResolution {
        guard peek() == 0x7B else {
            throw error("invalid property expression")
        }
        pos += 1
        var namePart = ""
        var valuePart: String? = nil
        var cur = ""
        while !atEnd {
            let u = units[pos]
            pos += 1
            if u == 0x7D { // '}'
                let propName: String?
                let propVal: String
                if let _ = valuePart {
                    propName = namePart
                    propVal = cur
                } else {
                    propName = nil
                    propVal = cur
                }
                guard !propVal.isEmpty,
                      let resolved = RegExpUnicodeData.resolveProperty(name: propName, value: propVal, unicodeSets: unicodeSets) else {
                    throw error("invalid property name")
                }
                return resolved
            }
            if u == 0x3D { // '='
                if valuePart != nil { throw error("invalid property expression") }
                namePart = cur
                valuePart = ""
                cur = ""
                continue
            }
            // Only ASCII letters, digits, and '_' are valid inside \p{...}
            guard (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A) || (u >= 0x30 && u <= 0x39) || u == 0x5F else {
                throw error("invalid property expression")
            }
            cur.append(Character(Unicode.Scalar(u)!))
        }
        throw error("invalid property expression")
    }

    private mutating func parseUnicodePropertyEscape(negated: Bool) throws(ECMAScriptRegExpError) -> PatternNode {
        let prop = try parseUnicodePropertyRaw()
        if negated && prop.isPropertyOfStrings {
            throw error("invalid negated property of strings")
        }
        if unicodeSets {
            // In v-mode, case-fold BEFORE complementing (\P)
            var ranges = ignoreCase ? RegExpUnicodeData.expandCaseFold(prop.ranges, unicode: true) : prop.ranges
            if negated {
                ranges = RegExpUnicodeData.complementRanges(ranges, maxCodePoint: 0x10FFFF)
            }
            return .charClass(ranges: ranges, strings: negated ? [] : prop.strings, ignoreCase: ignoreCase)
        } else {
            // In u-mode, complement FIRST, then case-fold if /i!
            var ranges = negated ? RegExpUnicodeData.complementRanges(prop.ranges, maxCodePoint: 0x10FFFF) : prop.ranges
            if ignoreCase {
                ranges = RegExpUnicodeData.expandCaseFold(ranges, unicode: true)
            }
            return .charClass(ranges: ranges, strings: [], ignoreCase: false)
        }
    }

    // MARK: Character Classes (`[...]` — non-u, u, and v-mode unicodeSets)

    private struct ClassSetValue {
        var ranges: [CPRange]
        var strings: [[UInt32]] // strings of length 0 or >= 2 (length-1 folded into ranges)
        var mayContainStrings: Bool

        static let empty = ClassSetValue(ranges: [], strings: [], mayContainStrings: false)
    }

    private mutating func parseCharacterClass() throws(ECMAScriptRegExpError) -> PatternNode {
        if unicodeSets {
            let val = try parseVCharacterClass()
            return .charClass(ranges: val.ranges, strings: val.strings, ignoreCase: ignoreCase)
        }
        return try parseClassicCharacterClass()
    }

    private enum ClassicClassAtom {
        case single(UInt32)
        case set([CPRange])
    }

    private mutating func parseClassicCharacterClass() throws(ECMAScriptRegExpError) -> PatternNode {
        pos += 1 // consume '['
        var negated = false
        if peek() == 0x5E { // '^'
            negated = true
            pos += 1
        }
        var ranges: [CPRange] = []
        while !atEnd {
            if peek() == 0x5D { // ']'
                pos += 1
                var norm = RegExpUnicodeData.normalizeRanges(ranges)
                if ignoreCase {
                    norm = RegExpUnicodeData.expandCaseFold(norm, unicode: unicodeMode)
                }
                if negated {
                    norm = RegExpUnicodeData.complementRanges(norm, maxCodePoint: maxCP)
                }
                return .charClass(ranges: norm, strings: [], ignoreCase: false)
            }
            let first = try parseClassicClassAtom()
            // Check for range `a-b`
            if peek() == 0x2D, let afterDash = peek(1), afterDash != 0x5D {
                pos += 1 // consume '-'
                let second = try parseClassicClassAtom()
                switch (first, second) {
                case (.single(let lo), .single(let hi)):
                    if lo > hi {
                        throw error("range out of order in character class")
                    }
                    ranges.append(CPRange(lower: lo, upper: hi))
                default:
                    if unicodeMode {
                        throw error("invalid character class range")
                    }
                    // Annex B: [\d-a] treats '-' as a literal hyphen
                    appendAtom(first, to: &ranges)
                    ranges.append(CPRange(lower: 0x2D, upper: 0x2D))
                    appendAtom(second, to: &ranges)
                }
            } else {
                appendAtom(first, to: &ranges)
            }
        }
        throw error("missing terminating ] for character class")
    }

    private func appendAtom(_ atom: ClassicClassAtom, to ranges: inout [CPRange]) {
        switch atom {
        case .single(let cp): ranges.append(CPRange(lower: cp, upper: cp))
        case .set(let rs): ranges.append(contentsOf: rs)
        }
    }

    private mutating func parseClassicClassAtom() throws(ECMAScriptRegExpError) -> ClassicClassAtom {
        let u = units[pos]
        if u != 0x5C { // not '\'
            return .single(readChar())
        }
        pos += 1 // consume '\'
        guard let esc = peek() else {
            throw error("missing terminating ] for character class")
        }
        switch esc {
        case 0x64: pos += 1; return .set(builtinClassRanges(.digit))
        case 0x44: pos += 1; return .set(RegExpUnicodeData.complementRanges(builtinClassRanges(.digit), maxCodePoint: maxCP))
        case 0x73: pos += 1; return .set(builtinClassRanges(.space))
        case 0x53: pos += 1; return .set(RegExpUnicodeData.complementRanges(builtinClassRanges(.space), maxCodePoint: maxCP))
        case 0x77: pos += 1; return .set(builtinClassRanges(.word))
        case 0x57: pos += 1; return .set(RegExpUnicodeData.complementRanges(builtinClassRanges(.word), maxCodePoint: maxCP))
        case 0x62: pos += 1; return .single(0x08) // \b inside class is BACKSPACE
        case 0x70 where unicodeMode, 0x50 where unicodeMode:
            pos += 1
            let prop = try parseUnicodePropertyRaw()
            let rs = esc == 0x50 ? RegExpUnicodeData.complementRanges(prop.ranges, maxCodePoint: 0x10FFFF) : prop.ranges
            return .set(rs)
        case 0x63: // \cX inside class
            pos += 1
            if let ch = peek() {
                if (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A) {
                    pos += 1
                    return .single(UInt32(ch % 32))
                }
                if !unicodeMode && ((ch >= 0x30 && ch <= 0x39) || ch == 0x5F) {
                    // Annex B ClassControlLetter: 0-9 and _
                    pos += 1
                    return .single(UInt32(ch % 32))
                }
            }
            if unicodeMode { throw error("invalid escape") }
            // Annex B: literal '\' (back up before 'c')
            pos -= 1
            return .single(0x5C)
        case 0x30...0x39: // \0..\9 inside class
            if unicodeMode {
                if esc == 0x30 {
                    pos += 1
                    if let next = peek(), next >= 0x30 && next <= 0x39 {
                        throw error("invalid decimal escape")
                    }
                    return .single(0)
                }
                throw error("invalid decimal escape")
            }
            return .single(parseLegacyOctalOrDigit())
        case 0x2D: // \-
            pos += 1
            return .single(0x2D)
        default:
            return .single(try parseSimpleCharacterEscape(inClass: true))
        }
    }

    // MARK: ES2025 v-mode (`unicodeSets`) Character Class Set Expressions

    private enum VSetOp { case union, intersection, subtraction }

    private mutating func parseVCharacterClass() throws(ECMAScriptRegExpError) -> ClassSetValue {
        pos += 1 // consume '['
        var negated = false
        if peek() == 0x5E {
            negated = true
            pos += 1
        }
        if peek() == 0x5D {
            pos += 1
            if negated {
                return ClassSetValue(ranges: [CPRange(lower: 0, upper: 0x10FFFF)], strings: [], mayContainStrings: false)
            }
            return .empty
        }

        // Parse first operand (could be range if single char followed by single '-')
        var (acc, firstWasRange) = try parseVOperandOrRange()
        var op: VSetOp? = firstWasRange ? .union : nil

        while !atEnd {
            if peek() == 0x5D {
                pos += 1
                if negated {
                    if acc.mayContainStrings {
                        throw error("negated character class may contain strings")
                    }
                    let comp = RegExpUnicodeData.complementRanges(acc.ranges, maxCodePoint: 0x10FFFF)
                    return ClassSetValue(ranges: comp, strings: [], mayContainStrings: false)
                }
                return acc
            }

            if peek(0) == 0x26 && peek(1) == 0x26 { // '&&'
                if op == .union || op == .subtraction {
                    throw error("invalid set operation in character class")
                }
                op = .intersection
                pos += 2
                let rhs = try parseVOperandOnly()
                acc = intersectVSet(acc, rhs)
            } else if peek(0) == 0x2D && peek(1) == 0x2D { // '--'
                if op == .union || op == .intersection {
                    throw error("invalid set operation in character class")
                }
                op = .subtraction
                pos += 2
                let rhs = try parseVOperandOnly()
                acc = subtractVSet(acc, rhs)
            } else {
                if op == .intersection || op == .subtraction {
                    throw error("invalid set operation in character class")
                }
                op = .union
                let (rhs, _) = try parseVOperandOrRange()
                acc = unionVSet(acc, rhs)
            }
        }
        throw error("missing terminating ] for character class")
    }

    private mutating func parseVOperandOrRange() throws(ECMAScriptRegExpError) -> (ClassSetValue, Bool) {
        if peek() == 0x5B {
            return (try parseVCharacterClass(), false)
        }
        let first = try parseVAtom()
        if case .single(let lo) = first, peek(0) == 0x2D, peek(1) != 0x2D {
            pos += 1 // consume '-'
            guard !atEnd, peek() != 0x5D else {
                throw error("invalid character in character class")
            }
            let second = try parseVAtom()
            guard case .single(let hi) = second else {
                throw error("invalid character class range")
            }
            if lo > hi {
                throw error("range out of order in character class")
            }
            var rs = [CPRange(lower: lo, upper: hi)]
            if ignoreCase { rs = RegExpUnicodeData.expandCaseFold(rs, unicode: true) }
            return (ClassSetValue(ranges: rs, strings: [], mayContainStrings: false), true)
        }
        return (vAtomToSet(first), false)
    }

    private mutating func parseVOperandOnly() throws(ECMAScriptRegExpError) -> ClassSetValue {
        guard !atEnd, peek() != 0x5D else {
            throw error("invalid character in character class")
        }
        if peek() == 0x5B {
            return try parseVCharacterClass()
        }
        let atom = try parseVAtom()
        return vAtomToSet(atom)
    }

    private enum VAtom {
        case single(UInt32)
        case set(ClassSetValue)
    }

    private func vAtomToSet(_ atom: VAtom) -> ClassSetValue {
        switch atom {
        case .single(let cp):
            var rs = [CPRange(lower: cp, upper: cp)]
            if ignoreCase { rs = RegExpUnicodeData.expandCaseFold(rs, unicode: true) }
            return ClassSetValue(ranges: rs, strings: [], mayContainStrings: false)
        case .set(let s):
            return s
        }
    }

    private mutating func parseVAtom() throws(ECMAScriptRegExpError) -> VAtom {
        guard let u = peek() else {
            throw error("missing terminating ] for character class")
        }
        if u == 0x5C { // '\'
            pos += 1
            guard let esc = peek() else {
                throw error("missing terminating ] for character class")
            }
            switch esc {
            case 0x64:
                pos += 1
                return .set(ClassSetValue(ranges: Self.digitRanges, strings: [], mayContainStrings: false))
            case 0x44:
                pos += 1
                return .set(ClassSetValue(ranges: RegExpUnicodeData.complementRanges(Self.digitRanges, maxCodePoint: 0x10FFFF), strings: [], mayContainStrings: false))
            case 0x73:
                pos += 1
                return .set(ClassSetValue(ranges: Self.whitespaceRanges, strings: [], mayContainStrings: false))
            case 0x53:
                pos += 1
                return .set(ClassSetValue(ranges: RegExpUnicodeData.complementRanges(Self.whitespaceRanges, maxCodePoint: 0x10FFFF), strings: [], mayContainStrings: false))
            case 0x77:
                pos += 1
                return .set(ClassSetValue(ranges: builtinClassRanges(.word), strings: [], mayContainStrings: false))
            case 0x57:
                pos += 1
                return .set(ClassSetValue(ranges: RegExpUnicodeData.complementRanges(builtinClassRanges(.word), maxCodePoint: 0x10FFFF), strings: [], mayContainStrings: false))
            case 0x62:
                pos += 1
                return .single(0x08)
            case 0x70, 0x50: // \p{...}, \P{...}
                pos += 1
                let prop = try parseUnicodePropertyRaw()
                let neg = esc == 0x50
                if neg && prop.isPropertyOfStrings {
                    throw error("invalid negated property of strings")
                }
                var rs = ignoreCase ? RegExpUnicodeData.expandCaseFold(prop.ranges, unicode: true) : prop.ranges
                if neg {
                    rs = RegExpUnicodeData.complementRanges(rs, maxCodePoint: 0x10FFFF)
                }
                let strs = neg ? [] : prop.strings
                return .set(ClassSetValue(ranges: rs, strings: strs, mayContainStrings: !neg && prop.isPropertyOfStrings))
            case 0x71: // \q{str1|str2|...}
                pos += 1
                return .set(try parseVStringDisjunction())
            case 0x63: // \cA..\cz
                pos += 1
                guard let ch = peek(), (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A) else {
                    throw error("invalid escape")
                }
                pos += 1
                return .single(UInt32(ch % 32))
            case 0x30:
                pos += 1
                if let next = peek(), next >= 0x30 && next <= 0x39 {
                    throw error("invalid decimal escape")
                }
                return .single(0)
            case 0x31...0x39:
                throw error("invalid decimal escape")
            default:
                return .single(try parseSimpleCharacterEscape(inClass: true))
            }
        }

        // Unescaped ClassSetCharacter checks for v-mode
        if isVClassSyntaxChar(u) {
            throw error("invalid character in character class")
        }
        if isVReservedDoublePunctuator(u), peek(1) == u {
            throw error("invalid character in character class")
        }
        return .single(readChar())
    }

    private mutating func parseVStringDisjunction() throws(ECMAScriptRegExpError) -> ClassSetValue {
        guard peek() == 0x7B else {
            throw error("invalid escape")
        }
        pos += 1 // consume '{'
        var ranges: [CPRange] = []
        var strings: [[UInt32]] = []
        var cur: [UInt32] = []
        var mayContainStrings = false

        func commitCurrent() {
            if cur.count == 1 {
                let cp = cur[0]
                ranges.append(CPRange(lower: cp, upper: cp))
            } else {
                mayContainStrings = true
                strings.append(cur)
            }
            cur = []
        }

        while !atEnd {
            let u = units[pos]
            if u == 0x7D { // '}'
                pos += 1
                commitCurrent()
                var norm = RegExpUnicodeData.normalizeRanges(ranges)
                if ignoreCase {
                    norm = RegExpUnicodeData.expandCaseFold(norm, unicode: true)
                }
                return ClassSetValue(ranges: norm, strings: deduplicateStrings(strings), mayContainStrings: mayContainStrings)
            }
            if u == 0x7C { // '|'
                pos += 1
                commitCurrent()
                continue
            }
            if u == 0x5C {
                pos += 1
                guard let esc = peek() else { throw error("invalid escape") }
                if esc == 0x62 {
                    pos += 1; cur.append(0x08)
                } else if esc == 0x63 {
                    pos += 1
                    guard let ch = peek(), (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A) else {
                        throw error("invalid escape")
                    }
                    pos += 1; cur.append(UInt32(ch % 32))
                } else if esc == 0x30 {
                    pos += 1
                    if let next = peek(), next >= 0x30 && next <= 0x39 { throw error("invalid decimal escape") }
                    cur.append(0)
                } else if esc >= 0x31 && esc <= 0x39 {
                    throw error("invalid decimal escape")
                } else {
                    cur.append(try parseSimpleCharacterEscape(inClass: true))
                }
            } else {
                if isVClassSyntaxChar(u) {
                    throw error("invalid character in character class")
                }
                if isVReservedDoublePunctuator(u), peek(1) == u {
                    throw error("invalid character in character class")
                }
                cur.append(readChar())
            }
        }
        throw error("unterminated string disjunction")
    }

    private func deduplicateStrings(_ list: [[UInt32]]) -> [[UInt32]] {
        var seen = Set<[UInt32]>()
        var out: [[UInt32]] = []
        for s in list {
            if seen.insert(s).inserted { out.append(s) }
        }
        out.sort { $0.count > $1.count }
        return out
    }

    private func unionVSet(_ a: ClassSetValue, _ b: ClassSetValue) -> ClassSetValue {
        let ranges = RegExpUnicodeData.normalizeRanges(a.ranges + b.ranges)
        let strings = deduplicateStrings(a.strings + b.strings)
        return ClassSetValue(ranges: ranges, strings: strings, mayContainStrings: a.mayContainStrings || b.mayContainStrings)
    }

    private func intersectVSet(_ a: ClassSetValue, _ b: ClassSetValue) -> ClassSetValue {
        let ranges = RegExpUnicodeData.intersectRanges(a.ranges, b.ranges)
        let bSet = Set(b.strings)
        let strings = a.strings.filter { bSet.contains($0) }
        return ClassSetValue(ranges: ranges, strings: deduplicateStrings(strings), mayContainStrings: !strings.isEmpty)
    }

    private func subtractVSet(_ a: ClassSetValue, _ b: ClassSetValue) -> ClassSetValue {
        let ranges = RegExpUnicodeData.subtractRanges(a.ranges, b.ranges)
        let bSet = Set(b.strings)
        let strings = a.strings.filter { !bSet.contains($0) }
        return ClassSetValue(ranges: ranges, strings: deduplicateStrings(strings), mayContainStrings: !strings.isEmpty)
    }
}

// MARK: - Bytecode Compiler

private struct CompiledCharClass: Sendable {
    let ranges: [CPRange]
    /// Multi-codepoint strings (length >= 2), sorted by code-point length descending.
    let multiStrings: [[UInt32]]
    /// True if empty string `""` is part of this v-mode class (e.g. `[\q{}]`).
    let matchesEmpty: Bool
    let ignoreCase: Bool
}

private enum VMOp: Sendable {
    case match
    case fail
    case jump(Int)
    case split(first: Int, second: Int)
    case literal(cp: UInt32, ignoreCase: Bool, backward: Bool)
    case dot(dotAll: Bool, backward: Bool)
    case charClass(idx: Int, backward: Bool)
    case anchorStart(multiline: Bool)
    case anchorEnd(multiline: Bool)
    case wordBoundary(negated: Bool, ignoreCase: Bool)
    case captureStart(slot: Int, backward: Bool)
    case captureEnd(slot: Int, backward: Bool)
    case resetCaptures(first: Int, count: Int)
    case backref(indices: [Int], ignoreCase: Bool, backward: Bool)
    case lookaround(positive: Bool, subProgramIdx: Int)
    case loopInit(reg: Int)
    case loopBegin(reg: Int)
    case loopCheckEmptyAndInc(reg: Int, min: Int)
    case loopDispatch(reg: Int, min: Int, max: Int?, greedy: Bool, bodyPC: Int, exitPC: Int)
}

private struct CompiledSubProgram: Sendable {
    let ops: [VMOp]
    let loopCount: Int
}

private struct CompiledProgram: Sendable {
    let main: CompiledSubProgram
    let subPrograms: [CompiledSubProgram]
    let charClasses: [CompiledCharClass]
    let captureCount: Int
    let unicodeMode: Bool
}

private struct RegExpCompiler {
    var subPrograms: [CompiledSubProgram] = []
    var charClasses: [CompiledCharClass] = []

    static func compile(root: PatternNode, captureCount: Int, unicodeMode: Bool) -> CompiledProgram {
        var compiler = RegExpCompiler()
        let main = compiler.compileSubProgram(root, backward: false)
        return CompiledProgram(
            main: main,
            subPrograms: compiler.subPrograms,
            charClasses: compiler.charClasses,
            captureCount: captureCount,
            unicodeMode: unicodeMode
        )
    }

    private mutating func compileSubProgram(_ node: PatternNode, backward: Bool) -> CompiledSubProgram {
        var ops: [VMOp] = []
        var nextLoopReg = 0
        emit(node, backward: backward, ops: &ops, nextLoopReg: &nextLoopReg)
        ops.append(.match)
        return CompiledSubProgram(ops: ops, loopCount: nextLoopReg)
    }

    private mutating func emit(_ node: PatternNode, backward: Bool, ops: inout [VMOp], nextLoopReg: inout Int) {
        switch node {
        case .empty:
            return

        case .sequence(let items):
            if backward {
                for item in items.reversed() {
                    emit(item, backward: true, ops: &ops, nextLoopReg: &nextLoopReg)
                }
            } else {
                for item in items {
                    emit(item, backward: false, ops: &ops, nextLoopReg: &nextLoopReg)
                }
            }

        case .disjunction(let alts):
            if alts.isEmpty { return }
            if alts.count == 1 {
                emit(alts[0], backward: backward, ops: &ops, nextLoopReg: &nextLoopReg)
                return
            }
            var endJumps: [Int] = []
            for i in 0..<(alts.count - 1) {
                let splitIdx = ops.count
                ops.append(.fail) // placeholder for .split
                let firstPC = ops.count
                emit(alts[i], backward: backward, ops: &ops, nextLoopReg: &nextLoopReg)
                endJumps.append(ops.count)
                ops.append(.fail) // placeholder for .jump(end)
                let secondPC = ops.count
                ops[splitIdx] = .split(first: firstPC, second: secondPC)
            }
            emit(alts[alts.count - 1], backward: backward, ops: &ops, nextLoopReg: &nextLoopReg)
            let endPC = ops.count
            for j in endJumps {
                ops[j] = .jump(endPC)
            }

        case .literal(let cp, let ic):
            ops.append(.literal(cp: cp, ignoreCase: ic, backward: backward))

        case .dot(let dotAll):
            ops.append(.dot(dotAll: dotAll, backward: backward))

        case .charClass(let ranges, let strings, let ic):
            var multi: [[UInt32]] = []
            var matchesEmpty = false
            for s in strings {
                if s.isEmpty { matchesEmpty = true }
                else if s.count >= 2 { multi.append(s) }
            }
            multi.sort { $0.count > $1.count }
            let idx = charClasses.count
            charClasses.append(CompiledCharClass(ranges: ranges, multiStrings: multi, matchesEmpty: matchesEmpty, ignoreCase: ic))
            ops.append(.charClass(idx: idx, backward: backward))

        case .anchorStart(let multiline):
            ops.append(.anchorStart(multiline: multiline))

        case .anchorEnd(let multiline):
            ops.append(.anchorEnd(multiline: multiline))

        case .wordBoundary(let negated, let ic):
            ops.append(.wordBoundary(negated: negated, ignoreCase: ic))

        case .capture(let index, _, let body):
            ops.append(.captureStart(slot: index, backward: backward))
            emit(body, backward: backward, ops: &ops, nextLoopReg: &nextLoopReg)
            ops.append(.captureEnd(slot: index, backward: backward))

        case .backref(let indices, let ic):
            ops.append(.backref(indices: indices, ignoreCase: ic, backward: backward))

        case .namedBackrefPlaceholder:
            ops.append(.fail)

        case .lookaround(let positive, let behind, let body):
            let subIdx = subPrograms.count
            // Reserve slot before compiling nested lookarounds so indices stay ordered
            subPrograms.append(CompiledSubProgram(ops: [], loopCount: 0))
            let sub = compileSubProgram(body, backward: behind)
            subPrograms[subIdx] = sub
            ops.append(.lookaround(positive: positive, subProgramIdx: subIdx))

        case .quantifier(let body, let minCount, let maxCount, let greedy, let firstCap, let capCount):
            if let mx = maxCount, mx == 0 {
                return
            }
            let reg = nextLoopReg
            nextLoopReg += 1

            ops.append(.loopInit(reg: reg))
            let jumpToDispatchIdx = ops.count
            ops.append(.fail) // placeholder for .jump(dispatchPC)

            let bodyPC = ops.count
            if capCount > 0 {
                ops.append(.resetCaptures(first: firstCap, count: capCount))
            }
            ops.append(.loopBegin(reg: reg))
            emit(body, backward: backward, ops: &ops, nextLoopReg: &nextLoopReg)
            ops.append(.loopCheckEmptyAndInc(reg: reg, min: minCount))

            let dispatchPC = ops.count
            ops[jumpToDispatchIdx] = .jump(dispatchPC)
            let dispatchIdx = ops.count
            ops.append(.fail) // placeholder for .loopDispatch

            let exitPC = ops.count
            ops[dispatchIdx] = .loopDispatch(
                reg: reg,
                min: minCount,
                max: maxCount,
                greedy: greedy,
                bodyPC: bodyPC,
                exitPC: exitPC
            )
        }
    }
}

// MARK: - Iterative Backtracking VM

private struct RegExpVM {
    enum BacktrackEntry {
        case choice(pc: Int, pos: Int)
        case undoCapture(slot: Int, oldStart: Int, oldEnd: Int)
        case undoLoop(reg: Int, oldCount: Int, oldStart: Int)
        case charClassNext(classIdx: Int, stage: UInt8, idx: Int, pos: Int, nextPC: Int, backward: Bool)
    }

    let program: CompiledProgram
    let input: [UInt16]
    let len: Int
    let unicodeMode: Bool
    let checkInterrupt: (() throws -> Void)?
    var steps: Int = 0

    init(program: CompiledProgram, input: [UInt16], checkInterrupt: (() throws -> Void)?) {
        self.program = program
        self.input = input
        self.len = input.count
        self.unicodeMode = program.unicodeMode
        self.checkInterrupt = checkInterrupt
    }

    mutating func runAt(pos startPos: Int) throws -> ([Int], [Int])? {
        let slots = program.captureCount + 1
        var capStarts = Array(repeating: -1, count: slots)
        var capEnds = Array(repeating: -1, count: slots)
        capStarts[0] = startPos
        guard let endPos = try executeSubProgram(
            program.main,
            startPos: startPos,
            capStarts: &capStarts,
            capEnds: &capEnds
        ) else {
            return nil
        }
        capEnds[0] = endPos
        return (capStarts, capEnds)
    }

    @inline(__always)
    private func readForward(_ pos: Int) -> (cp: UInt32, nextPos: Int)? {
        guard pos < len else { return nil }
        let u = input[pos]
        if unicodeMode, ECMAScriptRegExp.isLeadSurrogate(u), pos + 1 < len,
           ECMAScriptRegExp.isTrailSurrogate(input[pos + 1]) {
            let cp = 0x10000 + (UInt32(u - 0xD800) << 10) + UInt32(input[pos + 1] - 0xDC00)
            return (cp, pos + 2)
        }
        return (UInt32(u), pos + 1)
    }

    @inline(__always)
    private func readBackward(_ pos: Int) -> (cp: UInt32, nextPos: Int)? {
        guard pos > 0 else { return nil }
        let u = input[pos - 1]
        if unicodeMode, ECMAScriptRegExp.isTrailSurrogate(u), pos >= 2,
           ECMAScriptRegExp.isLeadSurrogate(input[pos - 2]) {
            let cp = 0x10000 + (UInt32(input[pos - 2] - 0xD800) << 10) + UInt32(u - 0xDC00)
            return (cp, pos - 2)
        }
        return (UInt32(u), pos - 1)
    }

    @inline(__always)
    private func canonicalize(_ cp: UInt32) -> UInt32 {
        if unicodeMode {
            return RegExpUnicodeData.canonicalizeUnicode(cp)
        }
        return UInt32(RegExpUnicodeData.canonicalizeNonUnicode(UInt16(cp & 0xFFFF)))
    }

    @inline(__always)
    private func isWordCharAt(_ pos: Int, ignoreCase: Bool) -> Bool {
        guard pos >= 0 && pos < len else { return false }
        let u = input[pos]
        if unicodeMode && ignoreCase {
            if u == 0x017F || u == 0x212A { return true }
        }
        return ECMAScriptRegExp.isASCIIWord(UInt32(u))
    }

    private func matchCodePointSequence(
        _ seq: [UInt32],
        at pos: Int,
        ignoreCase: Bool,
        backward: Bool
    ) -> Int? {
        var cur = pos
        if backward {
            for cp in seq.reversed() {
                guard let (ch, prev) = readBackward(cur) else { return nil }
                if ignoreCase {
                    if canonicalize(ch) != canonicalize(cp) { return nil }
                } else if ch != cp {
                    return nil
                }
                cur = prev
            }
        } else {
            for cp in seq {
                guard let (ch, next) = readForward(cur) else { return nil }
                if ignoreCase {
                    if canonicalize(ch) != canonicalize(cp) { return nil }
                } else if ch != cp {
                    return nil
                }
                cur = next
            }
        }
        return cur
    }

    private func matchBackrefSlice(
        capStart: Int,
        capEnd: Int,
        at pos: Int,
        ignoreCase: Bool,
        backward: Bool
    ) -> Int? {
        let capLen = capEnd - capStart
        if capLen == 0 { return pos }
        if !unicodeMode {
            if backward {
                guard pos >= capLen else { return nil }
                let start = pos - capLen
                if ignoreCase {
                    for i in 0..<capLen {
                        let a = RegExpUnicodeData.canonicalizeNonUnicode(input[capStart + i])
                        let b = RegExpUnicodeData.canonicalizeNonUnicode(input[start + i])
                        if a != b { return nil }
                    }
                } else {
                    for i in 0..<capLen {
                        if input[capStart + i] != input[start + i] { return nil }
                    }
                }
                return start
            } else {
                guard pos + capLen <= len else { return nil }
                if ignoreCase {
                    for i in 0..<capLen {
                        let a = RegExpUnicodeData.canonicalizeNonUnicode(input[capStart + i])
                        let b = RegExpUnicodeData.canonicalizeNonUnicode(input[pos + i])
                        if a != b { return nil }
                    }
                } else {
                    for i in 0..<capLen {
                        if input[capStart + i] != input[pos + i] { return nil }
                    }
                }
                return pos + capLen
            }
        }

        // Unicode mode: step by code points so surrogate pairs and astral case-folding work properly.
        if backward {
            var ci = capEnd
            var cur = pos
            while ci > capStart {
                guard let (capCP, nextCI) = readBackward(ci),
                      let (inCP, nextCur) = readBackward(cur) else { return nil }
                if nextCI < capStart { return nil }
                if ignoreCase {
                    if RegExpUnicodeData.canonicalizeUnicode(capCP) != RegExpUnicodeData.canonicalizeUnicode(inCP) {
                        return nil
                    }
                } else if capCP != inCP {
                    return nil
                }
                ci = nextCI
                cur = nextCur
            }
            return cur
        } else {
            var ci = capStart
            var cur = pos
            while ci < capEnd {
                guard let (capCP, nextCI) = readForward(ci),
                      let (inCP, nextCur) = readForward(cur) else { return nil }
                if nextCI > capEnd { return nil }
                if ignoreCase {
                    if RegExpUnicodeData.canonicalizeUnicode(capCP) != RegExpUnicodeData.canonicalizeUnicode(inCP) {
                        return nil
                    }
                } else if capCP != inCP {
                    return nil
                }
                ci = nextCI
                cur = nextCur
            }
            return cur
        }
    }

    private mutating func executeSubProgram(
        _ sub: CompiledSubProgram,
        startPos: Int,
        capStarts: inout [Int],
        capEnds: inout [Int]
    ) throws -> Int? {
        let ops = sub.ops
        var loopCounts = Array(repeating: 0, count: sub.loopCount)
        var loopStarts = Array(repeating: -1, count: sub.loopCount)
        var stack: [BacktrackEntry] = []
        var choiceDepth = 0

        var pc = 0
        var pos = startPos

        @inline(__always)
        func backtrack() -> Bool {
            while let entry = stack.popLast() {
                switch entry {
                case .undoCapture(let slot, let oldS, let oldE):
                    capStarts[slot] = oldS
                    capEnds[slot] = oldE
                case .undoLoop(let reg, let oldC, let oldS):
                    loopCounts[reg] = oldC
                    loopStarts[reg] = oldS
                case .choice(let nextPC, let savedPos):
                    choiceDepth -= 1
                    pc = nextPC
                    pos = savedPos
                    return true
                case .charClassNext(let classIdx, let stage, let idx, let savedPos, let nextPC, let backward):
                    choiceDepth -= 1
                    if tryCharClassStage(
                        classIdx: classIdx,
                        stage: stage,
                        idx: idx,
                        pos: savedPos,
                        nextPC: nextPC,
                        backward: backward,
                        newPC: &pc,
                        newPos: &pos
                    ) {
                        return true
                    }
                }
            }
            return false
        }

        /// Attempts matching a v-mode/classic char class starting at `(stage, idx)`:
        /// - stage 0: multi-codepoint strings `multiStrings[idx...]`
        /// - stage 1: single code point in `ranges`
        /// - stage 2: empty string (if `matchesEmpty`)
        func tryCharClassStage(
            classIdx: Int,
            stage startStage: UInt8,
            idx startIdx: Int,
            pos curPos: Int,
            nextPC: Int,
            backward: Bool,
            newPC: inout Int,
            newPos: inout Int
        ) -> Bool {
            let cc = program.charClasses[classIdx]
            var stage = startStage
            var idx = startIdx

            if stage == 0 {
                while idx < cc.multiStrings.count {
                    let s = cc.multiStrings[idx]
                    idx += 1
                    if let matchedPos = matchCodePointSequence(s, at: curPos, ignoreCase: cc.ignoreCase, backward: backward) {
                        // Push continuation for remaining alternatives
                        if idx < cc.multiStrings.count {
                            stack.append(.charClassNext(classIdx: classIdx, stage: 0, idx: idx, pos: curPos, nextPC: nextPC, backward: backward))
                            choiceDepth += 1
                        } else if !cc.ranges.isEmpty {
                            stack.append(.charClassNext(classIdx: classIdx, stage: 1, idx: 0, pos: curPos, nextPC: nextPC, backward: backward))
                            choiceDepth += 1
                        } else if cc.matchesEmpty {
                            stack.append(.charClassNext(classIdx: classIdx, stage: 2, idx: 0, pos: curPos, nextPC: nextPC, backward: backward))
                            choiceDepth += 1
                        }
                        newPC = nextPC
                        newPos = matchedPos
                        return true
                    }
                }
                stage = 1
            }

            if stage == 1 {
                if !cc.ranges.isEmpty {
                    let read: (cp: UInt32, nextPos: Int)? = backward ? readBackward(curPos) : readForward(curPos)
                    if let (ch, afterPos) = read, RegExpUnicodeData.contains(cc.ranges, ch) {
                        if cc.matchesEmpty {
                            stack.append(.charClassNext(classIdx: classIdx, stage: 2, idx: 0, pos: curPos, nextPC: nextPC, backward: backward))
                            choiceDepth += 1
                        }
                        newPC = nextPC
                        newPos = afterPos
                        return true
                    }
                }
                stage = 2
            }

            if stage == 2 && cc.matchesEmpty {
                newPC = nextPC
                newPos = curPos
                return true
            }
            return false
        }

        while true {
            steps &+= 1
            if (steps & 0x3FF) == 0, let check = checkInterrupt {
                try check()
            }

            switch ops[pc] {
            case .match:
                return pos

            case .fail:
                if !backtrack() { return nil }

            case .jump(let target):
                pc = target

            case .split(let first, let second):
                stack.append(.choice(pc: second, pos: pos))
                choiceDepth += 1
                pc = first

            case .literal(let cp, let ic, let backward):
                let read = backward ? readBackward(pos) : readForward(pos)
                if let (ch, nextPos) = read {
                    let ok = ic ? (canonicalize(ch) == canonicalize(cp)) : (ch == cp)
                    if ok {
                        pos = nextPos
                        pc += 1
                        continue
                    }
                }
                if !backtrack() { return nil }

            case .dot(let dotAll, let backward):
                let read = backward ? readBackward(pos) : readForward(pos)
                if let (ch, nextPos) = read, dotAll || !ECMAScriptRegExp.isLineTerminator(ch) {
                    pos = nextPos
                    pc += 1
                    continue
                }
                if !backtrack() { return nil }

            case .charClass(let idx, let backward):
                let cc = program.charClasses[idx]
                // Fast path for normal classes without v-mode strings
                if cc.multiStrings.isEmpty && !cc.matchesEmpty {
                    let read = backward ? readBackward(pos) : readForward(pos)
                    if let (ch, nextPos) = read, RegExpUnicodeData.contains(cc.ranges, ch) {
                        pos = nextPos
                        pc += 1
                        continue
                    }
                    if !backtrack() { return nil }
                } else {
                    if tryCharClassStage(
                        classIdx: idx,
                        stage: 0,
                        idx: 0,
                        pos: pos,
                        nextPC: pc + 1,
                        backward: backward,
                        newPC: &pc,
                        newPos: &pos
                    ) {
                        continue
                    }
                    if !backtrack() { return nil }
                }

            case .anchorStart(let multiline):
                let ok: Bool
                if pos == 0 {
                    ok = true
                } else if multiline {
                    ok = ECMAScriptRegExp.isLineTerminator(UInt32(input[pos - 1]))
                } else {
                    ok = false
                }
                if ok { pc += 1 } else if !backtrack() { return nil }

            case .anchorEnd(let multiline):
                let ok: Bool
                if pos == len {
                    ok = true
                } else if multiline {
                    ok = ECMAScriptRegExp.isLineTerminator(UInt32(input[pos]))
                } else {
                    ok = false
                }
                if ok { pc += 1 } else if !backtrack() { return nil }

            case .wordBoundary(let negated, let ic):
                let prevWord = isWordCharAt(pos - 1, ignoreCase: ic)
                let curWord = isWordCharAt(pos, ignoreCase: ic)
                let isBoundary = prevWord != curWord
                if isBoundary != negated { pc += 1 } else if !backtrack() { return nil }

            case .captureStart(let slot, let backward):
                if choiceDepth > 0 {
                    stack.append(.undoCapture(slot: slot, oldStart: capStarts[slot], oldEnd: capEnds[slot]))
                }
                if backward {
                    capEnds[slot] = pos
                    capStarts[slot] = -1
                } else {
                    capStarts[slot] = pos
                    capEnds[slot] = -1
                }
                pc += 1

            case .captureEnd(let slot, let backward):
                if choiceDepth > 0 {
                    stack.append(.undoCapture(slot: slot, oldStart: capStarts[slot], oldEnd: capEnds[slot]))
                }
                if backward {
                    capStarts[slot] = pos
                } else {
                    capEnds[slot] = pos
                }
                pc += 1

            case .resetCaptures(let first, let count):
                for slot in first..<(first + count) {
                    if capStarts[slot] != -1 || capEnds[slot] != -1 {
                        if choiceDepth > 0 {
                            stack.append(.undoCapture(slot: slot, oldStart: capStarts[slot], oldEnd: capEnds[slot]))
                        }
                        capStarts[slot] = -1
                        capEnds[slot] = -1
                    }
                }
                pc += 1

            case .backref(let indices, let ic, let backward):
                // Find the active capture among indices (handles duplicate named groups in ES2025)
                var activeSlot: Int? = nil
                for idx in indices {
                    if capStarts[idx] >= 0 && capEnds[idx] >= 0 {
                        activeSlot = idx
                        break
                    }
                }
                guard let slot = activeSlot else {
                    // Unmatched / forward / open backreference matches empty string per ECMA-262
                    pc += 1
                    continue
                }
                if let nextPos = matchBackrefSlice(
                    capStart: capStarts[slot],
                    capEnd: capEnds[slot],
                    at: pos,
                    ignoreCase: ic,
                    backward: backward
                ) {
                    pos = nextPos
                    pc += 1
                } else if !backtrack() {
                    return nil
                }

            case .lookaround(let positive, let subIdx):
                var subStarts = capStarts
                var subEnds = capEnds
                let matched = try executeSubProgram(
                    program.subPrograms[subIdx],
                    startPos: pos,
                    capStarts: &subStarts,
                    capEnds: &subEnds
                ) != nil
                if positive {
                    if matched {
                        // Commit modified captures from lookaround into outer state (with undo trail!)
                        for slot in 1..<capStarts.count {
                            if subStarts[slot] != capStarts[slot] || subEnds[slot] != capEnds[slot] {
                                if choiceDepth > 0 {
                                    stack.append(.undoCapture(slot: slot, oldStart: capStarts[slot], oldEnd: capEnds[slot]))
                                }
                                capStarts[slot] = subStarts[slot]
                                capEnds[slot] = subEnds[slot]
                            }
                        }
                        pc += 1
                    } else if !backtrack() {
                        return nil
                    }
                } else {
                    if !matched {
                        pc += 1
                    } else if !backtrack() {
                        return nil
                    }
                }

            case .loopInit(let reg):
                if choiceDepth > 0 {
                    stack.append(.undoLoop(reg: reg, oldCount: loopCounts[reg], oldStart: loopStarts[reg]))
                }
                loopCounts[reg] = 0
                loopStarts[reg] = -1
                pc += 1

            case .loopBegin(let reg):
                if choiceDepth > 0 {
                    stack.append(.undoLoop(reg: reg, oldCount: loopCounts[reg], oldStart: loopStarts[reg]))
                }
                loopStarts[reg] = pos
                pc += 1

            case .loopCheckEmptyAndInc(let reg, let minCount):
                if loopCounts[reg] >= minCount && loopStarts[reg] == pos {
                    if !backtrack() { return nil }
                    continue
                }
                if choiceDepth > 0 {
                    stack.append(.undoLoop(reg: reg, oldCount: loopCounts[reg], oldStart: loopStarts[reg]))
                }
                loopCounts[reg] += 1
                pc += 1

            case .loopDispatch(let reg, let minCount, let maxCount, let greedy, let bodyPC, let exitPC):
                let c = loopCounts[reg]
                if c < minCount {
                    pc = bodyPC
                } else if let mx = maxCount, c >= mx {
                    pc = exitPC
                } else if greedy {
                    stack.append(.choice(pc: exitPC, pos: pos))
                    choiceDepth += 1
                    pc = bodyPC
                } else {
                    stack.append(.choice(pc: bodyPC, pos: pos))
                    choiceDepth += 1
                    pc = exitPC
                }
            }
        }
    }
}
