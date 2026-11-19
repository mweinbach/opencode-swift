#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

private extension UInt16 {
    @inline(__always)
    init(ascii scalar: Unicode.Scalar) {
        self = UInt16(scalar.value)
    }
}

/// Complete pure-Swift port of `upstream/opencode/packages/core/src/shell/scan.ts`
/// covering POSIX/Bash/Zsh (`scan`) and PowerShell (`scanPowerShell`) lexical scanning,
/// compound-command tracking, heredocs, arithmetic/subscript evaluation sinks, and opaque-reason detection.
internal enum CoreShellScanEngine {
    static let maxInputLength = 64 * 1024
    static let maxSubstitutionDepth = 32

    private static let bashRedirects = ["&>>", "&>", "<<<", "<<-", "<<", "<>", "<&", ">&", ">|", ">>", ">", "<"]
    private static let bashListOperators = ["&&", "||", "|&"]
    private static let zshListOperators = ["&&", "||", "|&", "&!", "&|"]
    private static let bashCaseOperators = [";;&", ";;", ";&", ";|", "&&", "||", "|&"]
    private static let zshCaseOperators = [";;&", ";;", ";&", ";|", "&&", "||", "|&", "&!", "&|"]

    private static let bashBindingBuiltins: Set<String> = [
        "declare", "typeset", "local", "export", "readonly", "private", "unset", "read",
        "getln", "vared", "getopts", "mapfile", "readarray", "compgen", "zparseopts",
        "zregexparse", "zformat", "zstyle", "zstat", "stat",
    ]
    private static let bashArithmeticComparisons: Set<String> = ["-eq", "-ne", "-lt", "-le", "-gt", "-ge"]
    private static let bashAssignmentDeclarations: Set<String> = ["declare", "typeset", "export", "readonly", "local"]
    private static let bashDeclarations: Set<String> = [
        "declare", "typeset", "export", "readonly", "local", "unset", "unsetenv",
    ]
    private static let bashPrecommands: Set<String> = ["builtin", "command", "time", "coproc", "!"]
    private static let zshPrecommands: Set<String> = ["noglob", "nocorrect", "exec", "-"]
    private static let zshArithmeticBuiltins: Set<String> = [
        "integer", "float", "exit", "return", "shift", "break", "continue", "bye", "logout",
    ]
    private static let bashNonFunctionKeywords: Set<String> = [
        "if", "for", "select", "case", "then", "elif", "else", "fi", "do", "done", "in", "esac",
    ]
    private static let bashAnsiEscapes: [UInt16: String] = [
        UInt16(ascii: "a"): "\u{07}",
        UInt16(ascii: "b"): "\u{08}",
        UInt16(ascii: "e"): "\u{1B}",
        UInt16(ascii: "E"): "\u{1B}",
        UInt16(ascii: "f"): "\u{0C}",
        UInt16(ascii: "n"): "\n",
        UInt16(ascii: "r"): "\r",
        UInt16(ascii: "t"): "\t",
        UInt16(ascii: "v"): "\u{0B}",
        UInt16(ascii: "\\"): "\\",
        UInt16(ascii: "'"): "'",
        UInt16(ascii: "\""): "\"",
        UInt16(ascii: "?"): "?",
    ]
    private static let powerShellEscapes: [UInt16: String] = [
        UInt16(ascii: "0"): "\u{00}",
        UInt16(ascii: "a"): "\u{07}",
        UInt16(ascii: "b"): "\u{08}",
        UInt16(ascii: "e"): "\u{1B}",
        UInt16(ascii: "f"): "\u{0C}",
        UInt16(ascii: "n"): "\n",
        UInt16(ascii: "r"): "\r",
        UInt16(ascii: "t"): "\t",
        UInt16(ascii: "v"): "\u{0B}",
    ]

    // MARK: - UTF-16 Source Helper

    struct UTF16Source {
        let units: [UInt16]
        var count: Int { units.count }

        init(_ s: String) {
            self.units = Array(s.utf16)
        }

        @inline(__always)
        func unit(at i: Int) -> UInt16? {
            (i >= 0 && i < units.count) ? units[i] : nil
        }

        @inline(__always)
        func unitOrZero(at i: Int) -> UInt16 {
            (i >= 0 && i < units.count) ? units[i] : 0
        }

        func slice(_ start: Int, _ end: Int) -> String {
            let s = max(0, min(start, units.count))
            let e = max(s, min(end, units.count))
            if s == e { return "" }
            return String(decoding: units[s..<e], as: UTF16.self)
        }

        func slice(from start: Int) -> String {
            slice(start, units.count)
        }

        func startsWith(_ ascii: String, at index: Int) -> Bool {
            let bytes = Array(ascii.utf16)
            if index < 0 || index + bytes.count > units.count { return false }
            for k in 0..<bytes.count {
                if units[index + k] != bytes[k] { return false }
            }
            return true
        }

        func indexOf(_ target: UInt16, from start: Int) -> Int? {
            guard start >= 0 else { return nil }
            var i = start
            while i < units.count {
                if units[i] == target { return i }
                i += 1
            }
            return nil
        }

        func indexOf(_ ascii: String, from start: Int) -> Int? {
            let pat = Array(ascii.utf16)
            if pat.isEmpty { return start <= units.count ? start : nil }
            guard start >= 0 && start + pat.count <= units.count else { return nil }
            let limit = units.count - pat.count
            var i = start
            while i <= limit {
                var ok = true
                for k in 0..<pat.count where units[i + k] != pat[k] {
                    ok = false
                    break
                }
                if ok { return i }
                i += 1
            }
            return nil
        }

        func scalarAndLength(at index: Int) -> (Unicode.Scalar, Int)? {
            guard index >= 0 && index < units.count else { return nil }
            let u = units[index]
            if u >= 0xD800 && u <= 0xDBFF, index + 1 < units.count {
                let low = units[index + 1]
                if low >= 0xDC00 && low <= 0xDFFF {
                    let cp = 0x10000 + (UInt32(u - 0xD800) << 10) + UInt32(low - 0xDC00)
                    if let sc = Unicode.Scalar(cp) { return (sc, 2) }
                }
            }
            if let sc = Unicode.Scalar(u) { return (sc, 1) }
            return nil
        }
    }

    // MARK: - ASCII & Unicode Predicates

    private static let uSpace: UInt16 = 0x20
    private static let uTab: UInt16 = 0x09
    private static let uLF: UInt16 = 0x0A
    private static let uCR: UInt16 = 0x0D
    private static let uBackslash: UInt16 = 0x5C
    private static let uDollar: UInt16 = 0x24
    private static let uSingleQuote: UInt16 = 0x27
    private static let uDoubleQuote: UInt16 = 0x22
    private static let uBacktick: UInt16 = 0x60
    private static let uLParen: UInt16 = 0x28
    private static let uRParen: UInt16 = 0x29
    private static let uLBrace: UInt16 = 0x7B
    private static let uRBrace: UInt16 = 0x7D
    private static let uLBracket: UInt16 = 0x5B
    private static let uRBracket: UInt16 = 0x5D
    private static let uLT: UInt16 = 0x3C
    private static let uGT: UInt16 = 0x3E
    private static let uAmp: UInt16 = 0x26
    private static let uPipe: UInt16 = 0x7C
    private static let uSemi: UInt16 = 0x3B
    private static let uHash: UInt16 = 0x23
    private static let uBang: UInt16 = 0x21
    private static let uEq: UInt16 = 0x3D
    private static let uAt: UInt16 = 0x40
    private static let uStar: UInt16 = 0x2A
    private static let uQMark: UInt16 = 0x3F
    private static let uPlus: UInt16 = 0x2B
    private static let uMinus: UInt16 = 0x2D
    private static let uColon: UInt16 = 0x3A
    private static let uDot: UInt16 = 0x2E
    private static let uComma: UInt16 = 0x2C
    private static let uTilde: UInt16 = 0x7E
    private static let uCaret: UInt16 = 0x5E
    private static let uPercent: UInt16 = 0x25
    private static let uSlash: UInt16 = 0x2F
    private static let uUnderscore: UInt16 = 0x5F

    @inline(__always) private static func isASCIIAlpha(_ u: UInt16) -> Bool {
        (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A)
    }
    @inline(__always) private static func isASCIIDigit(_ u: UInt16) -> Bool {
        u >= 0x30 && u <= 0x39
    }
    @inline(__always) private static func isASCIIHex(_ u: UInt16) -> Bool {
        isASCIIDigit(u) || (u >= 0x41 && u <= 0x46) || (u >= 0x61 && u <= 0x66)
    }
    @inline(__always) private static func isASCIIOctal(_ u: UInt16) -> Bool {
        u >= 0x30 && u <= 0x37
    }
    @inline(__always) private static func isIdentStart(_ u: UInt16) -> Bool {
        isASCIIAlpha(u) || u == uUnderscore
    }
    @inline(__always) private static func isIdentCont(_ u: UInt16) -> Bool {
        isASCIIAlpha(u) || isASCIIDigit(u) || u == uUnderscore
    }
    @inline(__always) private static func isJSWhitespace(_ u: UInt16) -> Bool {
        switch u {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            return true
        default:
            return false
        }
    }
    @inline(__always) private static func isUnicodeLetterOrNl(_ sc: Unicode.Scalar) -> Bool {
        switch sc.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .letterNumber:
            return true
        default:
            return false
        }
    }
    @inline(__always) private static func isPSIdentChar(_ src: UTF16Source, at index: Int) -> Int? {
        guard let (sc, len) = src.scalarAndLength(at: index) else { return nil }
        if isUnicodeLetterOrNl(sc) || (sc.value >= 0x30 && sc.value <= 0x39) || sc.value == 0x5F {
            return len
        }
        return nil
    }
    @inline(__always) private static func isPSIdentOrQMark(_ src: UTF16Source, at index: Int) -> Int? {
        if src.unit(at: index) == uQMark { return 1 }
        return isPSIdentChar(src, at: index)
    }

    // MARK: - Internal Scan Result Types

    enum InternalResult {
        case scanned(commands: [CoreShell.Scan.Command], end: Int)
        case opaque(CoreShell.Scan.OpaqueReason)
    }

    enum StepOutcome {
        case index(Int)
        case opaque(CoreShell.Scan.OpaqueReason)
        case none
    }

    final class BashContext {
        var remaining: Int
        let dialect: CoreShell.Scan.Dialect
        var boundDollar = false
        var boundOpen = false
        var boundBracket = false
        var sinkBracket = false
        var variableSink = false
        var evalSink = false
        var sawCommandSubstitution = false

        init(remaining: Int, dialect: CoreShell.Scan.Dialect) {
            self.remaining = remaining
            self.dialect = dialect
        }
    }

    final class BashText {
        var word: String = ""
        var literal: String = ""
        var output: String = ""
    }

    enum BashEvaluation {
        case arithmetic
        case binding
        case deferred
    }

    final class BashHeredoc {
        let delimiter: String
        let dashDelimiter: String?
        let quoted: Bool
        let tabs: Bool
        var binding: Bool?
        var owned: Bool = false
        var commandIndex: Int?
        var start: Int?

        init(delimiter: String, dashDelimiter: String?, quoted: Bool, tabs: Bool) {
            self.delimiter = delimiter
            self.dashDelimiter = dashDelimiter
            self.quoted = quoted
            self.tabs = tabs
        }
    }

    final class BashStructure {
        enum Kind { case `if`, `while`, until, `for`, `case`, `repeat` }
        enum Phase { case header, condition, pattern, body, `do` }

        let kind: Kind
        var phase: Phase
        var count: Int = 0
        var sawElse: Bool = false
        var sawIn: Bool = false
        var patternStarted: Bool = false
        var parenthesized: Bool = false

        init(kind: Kind, phase: Phase) {
            self.kind = kind
            self.phase = phase
        }
    }

    final class BashState {
        let src: UTF16Source
        let context: BashContext
        var commands: [CoreShell.Scan.Command] = []
        var nestedCommands: [CoreShell.Scan.Command] = []
        var words: [String] = []
        var rawWords: [String] = []
        var heredocs: [BashHeredoc]
        var structures: [BashStructure] = []
        let text = BashText()
        var wordStarted = false
        var wordStart: Int
        var wordEnd: Int
        var commandStart: Int?
        var redirectWordCount: Int?
        var redirectPrefixEnd: Int?
        var ampersandRedirectWords: Int?
        var commandWordIndex: Int = -1
        var assignmentWord = false
        var assignmentHeadUnsafe = false
        var invalid: CoreShell.Scan.OpaqueReason?
        var redirectTarget = false
        var dupRedirect = false
        var hereString = false
        var hasRedirect = false
        var hasFileRedirect = false
        var compoundEnd = false
        var dangling = false
        let outer: BashText?

        init(src: UTF16Source, start: Int, context: BashContext, heredocs: [BashHeredoc], outer: BashText?) {
            self.src = src
            self.context = context
            self.heredocs = heredocs
            self.wordStart = start
            self.wordEnd = start
            self.outer = outer
        }
    }

    enum BashTextMode { case word, quoted, arithmetic }

    struct BashSpan {
        let open: UInt16?
        let close: UInt16?
        let reject: Set<UInt16>
        let mode: BashTextMode

        init(open: UInt16? = nil, close: UInt16? = nil, reject: String = "", mode: BashTextMode) {
            self.open = open
            self.close = close
            self.reject = Set(reject.utf16)
            self.mode = mode
        }
    }

    private static let spanDouble = BashSpan(close: uDoubleQuote, mode: .quoted)
    private static let spanHeredoc = BashSpan(mode: .quoted)
    private static let spanArithmetic = BashSpan(open: uLParen, close: uRParen, reject: ";#}", mode: .arithmetic)
    private static let spanForArithmetic = BashSpan(open: uLParen, close: uRParen, reject: "#}", mode: .arithmetic)
    private static let spanBracketArithmetic = BashSpan(close: uRBracket, reject: ";|&<>()[\n'\"\\#", mode: .arithmetic)
    private static let spanSubscript = BashSpan(open: uLBracket, close: uRBracket, reject: "\"}", mode: .arithmetic)
    private static let spanQuotedSubscript = BashSpan(open: uLBracket, close: uRBracket, reject: "\"", mode: .quoted)
    private static let spanAssignmentSubscript = BashSpan(
        open: uLBracket, close: uRBracket, reject: " \t\n\r\u{0B}\u{0C};&|<>()", mode: .arithmetic
    )
    private static let spanArithmeticQuote = BashSpan(close: uSingleQuote, reject: "()[];\"}", mode: .quoted)
    private static let spanArithmeticDouble = BashSpan(close: uDoubleQuote, reject: "()[];}", mode: .quoted)
    private static let spanParameterQuote = BashSpan(close: uSingleQuote, reject: "\"}[]", mode: .quoted)

    // MARK: - Public Entry Points

    static func scanDetailed(
        _ input: String,
        dialect: CoreShell.Scan.Dialect = .posix
    ) -> (result: CoreShell.Scan.Result, sawCommandSubstitution: Bool) {
        let src = UTF16Source(input)
        if src.count > maxInputLength {
            return (.opaque(reason: .invalidStructure), false)
        }
        let context = BashContext(remaining: maxInputLength * maxSubstitutionDepth, dialect: dialect)
        let res = scanBash(src, start: 0, depth: 0, context: context)
        switch res {
        case .opaque(let reason):
            return (.opaque(reason: reason), context.sawCommandSubstitution)
        case .scanned(let commands, _):
            if context.boundDollar && context.boundOpen &&
                (context.evalSink || ((context.boundBracket || context.sinkBracket) && context.variableSink))
            {
                return (.opaque(reason: .dynamicExecution), context.sawCommandSubstitution)
            }
            return (.scanned(commands: commands), context.sawCommandSubstitution)
        }
    }

    static func scan(_ input: String, dialect: CoreShell.Scan.Dialect = .posix) -> CoreShell.Scan.Result {
        scanDetailed(input, dialect: dialect).result
    }

    static func scanPowerShell(_ input: String) -> CoreShell.Scan.Result {
        let src = UTF16Source(input)
        if src.count > maxInputLength {
            return .opaque(reason: .invalidStructure)
        }
        // /[\0\u0085\u2013-\u2015\u2018-\u201e\ufeff]/
        for u in src.units {
            if u == 0 || u == 0x0085 || (u >= 0x2013 && u <= 0x2015) || (u >= 0x2018 && u <= 0x201E) || u == 0xFEFF {
                return .opaque(reason: .invalidStructure)
            }
        }
        var budget = maxInputLength * maxSubstitutionDepth
        let res = scanPowerShellList(src, start: 0, depth: 0, budget: &budget, close: nil, hash: .none, skipped: nil)
        switch res {
        case .opaque(let reason):
            return .opaque(reason: reason)
        case .scanned(let commands, _):
            return .scanned(commands: commands)
        }
    }

    // MARK: - Bash / POSIX / Zsh Pattern Matchers (UTF-16 Anchored)

    private static func skipLineContinuations(_ src: UTF16Source, from index: Int) -> Int {
        var i = index
        while src.unit(at: i) == uBackslash && src.unit(at: i + 1) == uLF {
            i += 2
        }
        return i
    }

    // /(?:\\\n)*(?:[ \t\n;&|()<>]|$)/y
    private static func matchBraceCloseAhead(_ src: UTF16Source, at index: Int) -> Bool {
        let i = skipLineContinuations(src, from: index)
        guard let u = src.unit(at: i) else { return true }
        return u == uSpace || u == uTab || u == uLF || u == uSemi || u == uAmp || u == uPipe ||
            u == uLParen || u == uRParen || u == uLT || u == uGT
    }

    // /(?:\\\n)*[ \t\n]/y
    private static func matchSpaceContinuationAhead(_ src: UTF16Source, at index: Int) -> Bool {
        let i = skipLineContinuations(src, from: index)
        guard let u = src.unit(at: i) else { return false }
        return u == uSpace || u == uTab || u == uLF
    }

    // /(?:\\\n)*[ \t\n(]/y
    private static func matchNegationAhead(_ src: UTF16Source, at index: Int) -> Bool {
        let i = skipLineContinuations(src, from: index)
        guard let u = src.unit(at: i) else { return false }
        return u == uSpace || u == uTab || u == uLF || u == uLParen
    }

    // /[A-Za-z_][A-Za-z0-9_]*(?=(?:\\\n)*(?:[ \t\n;|&()<>]|$))/y
    private static func matchToken(_ src: UTF16Source, at index: Int) -> String? {
        guard let first = src.unit(at: index), isIdentStart(first) else { return nil }
        var i = index + 1
        while let u = src.unit(at: i), isIdentCont(u) { i += 1 }
        guard matchBraceCloseAhead(src, at: i) else { return nil }
        return src.slice(index, i)
    }

    private static func isCompoundAhead(_ src: UTF16Source, at index: Int) -> Bool {
        var i = index
        // (?:!(?:[ \t]|\\\n)*)*
        while src.unit(at: i) == uBang {
            i += 1
            while true {
                if src.unit(at: i) == uSpace || src.unit(at: i) == uTab { i += 1 }
                else if src.unit(at: i) == uBackslash && src.unit(at: i + 1) == uLF { i += 2 }
                else { break }
            }
        }
        guard let u = src.unit(at: i) else { return false }
        if u == uLBrace || u == uLParen { return true }
        if u == uLBracket && src.unit(at: i + 1) == uLBracket && matchSpaceContinuationAhead(src, at: i + 2) {
            return true
        }
        for kw in ["if", "while", "until", "for", "select", "case", "repeat"] {
            if src.startsWith(kw, at: i) {
                let after = i + kw.utf16.count
                if let next = src.unit(at: after), isIdentCont(next) { continue }
                return true
            }
        }
        return false
    }

    private static func skipInlineBlanksAndCont(_ src: UTF16Source, from index: Int) -> Int {
        var i = index
        while true {
            if src.unit(at: i) == uSpace || src.unit(at: i) == uTab { i += 1 }
            else if src.unit(at: i) == uBackslash && src.unit(at: i + 1) == uLF { i += 2 }
            else { break }
        }
        return i
    }

    private static func matchCoprocAhead(_ src: UTF16Source, at index: Int) -> Int? {
        guard src.startsWith("coproc", at: index) else { return nil }
        var i = index + 6
        let after1 = skipInlineBlanksAndCont(src, from: i)
        guard after1 > i else { return nil }
        i = after1
        if src.startsWith("--", at: i) {
            let afterDash = skipInlineBlanksAndCont(src, from: i + 2)
            if afterDash > i + 2 { i = afterDash }
        }
        if isCompoundAhead(src, at: i) { return i - index }
        // optional name
        if let first = src.unit(at: i), isIdentStart(first) {
            var k = i + 1
            while let u = src.unit(at: k), isIdentCont(u) { k += 1 }
            let afterName = skipInlineBlanksAndCont(src, from: k)
            if afterName > k && isCompoundAhead(src, at: afterName) {
                return afterName - index
            }
        }
        return nil
    }

    private static func matchTimeAhead(_ src: UTF16Source, at index: Int) -> Int? {
        guard src.startsWith("time", at: index) else { return nil }
        var i = index + 4
        let after1 = skipInlineBlanksAndCont(src, from: i)
        guard after1 > i else { return nil }
        i = after1
        if src.startsWith("-p", at: i) {
            let afterP = skipInlineBlanksAndCont(src, from: i + 2)
            if afterP > i + 2 { i = afterP }
        }
        if src.startsWith("--", at: i) {
            let afterDash = skipInlineBlanksAndCont(src, from: i + 2)
            if afterDash > i + 2 { i = afterDash }
        }
        return isCompoundAhead(src, at: i) ? (i - index) : nil
    }

    private static func isFunctionNameCont(_ u: UInt16) -> Bool {
        isIdentCont(u) || u == uDot || u == uColon || u == uPlus || u == uAt || u == uPercent || u == uMinus
    }

    private static func matchFunctionBody(_ src: UTF16Source, at index: Int) -> Bool {
        guard let u = src.unit(at: index) else { return false }
        if u == uLBrace || u == uLParen { return true }
        if u == uLBracket && src.unit(at: index + 1) == uLBracket && matchSpaceContinuationAhead(src, at: index + 2) {
            return true
        }
        for kw in ["if", "while", "until", "for", "select", "case", "repeat"] {
            if src.startsWith(kw, at: index) {
                let after = skipLineContinuations(src, from: index + kw.utf16.count)
                guard let next = src.unit(at: after) else { return true }
                if next == uSpace || next == uTab || next == uLF || next == uLParen { return true }
            }
        }
        return false
    }

    private static func bashFunctionHeadLength(_ src: UTF16Source, start: Int) -> Int {
        var i = start
        var hasFuncKw = false
        if src.startsWith("function", at: i), let next = src.unit(at: i + 8), (next == uSpace || next == uTab) {
            hasFuncKw = true
            i = skipInlineBlanksAndCont(src, from: i + 9)
        }
        var name: String?
        if let first = src.unit(at: i), isIdentStart(first) {
            let nameStart = i
            i += 1
            while let u = src.unit(at: i), isFunctionNameCont(u) { i += 1 }
            name = src.slice(nameStart, i)
        }
        i = skipInlineBlanksAndCont(src, from: i)
        var hasParens = false
        if src.unit(at: i) == uLParen {
            var k = i + 1
            while src.unit(at: k) == uSpace || src.unit(at: k) == uTab { k += 1 }
            if src.unit(at: k) == uRParen {
                hasParens = true
                i = k + 1
            }
        }
        let beforeTrailing = i
        // ((?:[ \t\n]|\\\n|#[^\n]*\n)*)
        while i < src.count {
            let u = src.units[i]
            if u == uSpace || u == uTab || u == uLF {
                i += 1
            } else if u == uBackslash && src.unit(at: i + 1) == uLF {
                i += 2
            } else if u == uHash {
                if let nl = src.indexOf(uLF, from: i) {
                    i = nl + 1
                } else {
                    break
                }
            } else {
                break
            }
        }
        if hasFuncKw {
            if name == nil { return 0 }
        } else {
            if !hasParens || bashNonFunctionKeywords.contains(name ?? "") { return 0 }
        }
        return matchFunctionBody(src, at: i) ? (beforeTrailing - start) : 0
    }

    // /(?:[ \t\n;]|\\\n|#[^\n]*(?:\n|$))*(?:do(?=(?:\\\n)*(?:[ \t\n;{(]|$))|\{(?=(?:\\\n)*[ \t\n]))/y
    private static func matchDoAhead(_ src: UTF16Source, at index: Int) -> Bool {
        var i = index
        while i < src.count {
            let u = src.units[i]
            if u == uSpace || u == uTab || u == uLF || u == uSemi {
                i += 1
            } else if u == uBackslash && src.unit(at: i + 1) == uLF {
                i += 2
            } else if u == uHash {
                if let nl = src.indexOf(uLF, from: i) { i = nl + 1 } else { i = src.count }
            } else {
                break
            }
        }
        if src.startsWith("do", at: i) {
            let after = skipLineContinuations(src, from: i + 2)
            guard let u = src.unit(at: after) else { return true }
            return u == uSpace || u == uTab || u == uLF || u == uSemi || u == uLBrace || u == uLParen
        }
        if src.unit(at: i) == uLBrace {
            return matchSpaceContinuationAhead(src, at: i + 1)
        }
        return false
    }

    // /\$\{(?:\\\n)*(?:[ \t\n]|\|)/y
    private static func matchNoforkOpen(_ src: UTF16Source, at index: Int) -> Int? {
        guard src.unit(at: index) == uDollar && src.unit(at: index + 1) == uLBrace else { return nil }
        let i = skipLineContinuations(src, from: index + 2)
        guard let u = src.unit(at: i) else { return nil }
        if u == uSpace || u == uTab || u == uLF || u == uPipe {
            return (i + 1) - index
        }
        return nil
    }

    // ZSH_SAFE_FLAGS_RE = /\$\{\((?:[@AaBbCcDEfFikLMmNnOopPqStUuVvWwXZz0-]|q[+]|[js]([^({[<\\])(?:(?!\1)[^)])*\1)*\)/y
    private static let zshSafeSingleFlagChars: Set<UInt16> = Set("@AaBbCcDEfFikLMmNnOopPqStUuVvWwXZz0-".utf16)

    private static func matchZshSafeFlagsEnd(_ src: UTF16Source, at index: Int) -> Int? {
        guard src.unit(at: index) == uDollar,
              src.unit(at: index + 1) == uLBrace,
              src.unit(at: index + 2) == uLParen else { return nil }
        var i = index + 3
        while i < src.count {
            let u = src.units[i]
            if u == uRParen { return i + 1 }
            if u == UInt16(ascii: "q") && src.unit(at: i + 1) == uPlus {
                i += 2
                continue
            }
            if u == UInt16(ascii: "j") || u == UInt16(ascii: "s") {
                guard let delim = src.unit(at: i + 1) else { return nil }
                if delim == uLParen || delim == uLBrace || delim == uLBracket || delim == uLT || delim == uBackslash {
                    return nil
                }
                var k = i + 2
                var closed = false
                while k < src.count {
                    if src.units[k] == delim {
                        k += 1
                        closed = true
                        break
                    }
                    if src.units[k] == uRParen { return nil }
                    k += 1
                }
                if !closed { return nil }
                i = k
                continue
            }
            if zshSafeSingleFlagChars.contains(u) {
                i += 1
                continue
            }
            return nil
        }
        return nil
    }

    private static func zshSafeFlagsHasP(_ src: UTF16Source, start: Int, endExclusive: Int) -> Bool {
        // Check inside ${(...)} excluding j/s delimited arguments
        var i = start + 3
        let limit = endExclusive - 1
        while i < limit {
            let u = src.units[i]
            if u == UInt16(ascii: "P") { return true }
            if (u == UInt16(ascii: "j") || u == UInt16(ascii: "s")), i + 1 < limit {
                let delim = src.units[i + 1]
                var k = i + 2
                while k < limit && src.units[k] != delim { k += 1 }
                i = k + 1
                continue
            }
            i += 1
        }
        return false
    }

    // ZSH_GLOB_MODIFIER_RE = /(?:[\^=~#+]|\\\n)*~/y
    private static func matchZshGlobModifier(_ src: UTF16Source, at index: Int) -> Bool {
        var i = index
        var sawTilde = false
        while i < src.count {
            let u = src.units[i]
            if u == uTilde {
                sawTilde = true
                i += 1
            } else if u == uCaret || u == uEq || u == uHash || u == uPlus {
                i += 1
            } else if u == uBackslash && src.unit(at: i + 1) == uLF {
                i += 2
            } else {
                break
            }
        }
        return sawTilde
    }

    private static func zshEvaluates(_ src: UTF16Source, at index: Int) -> Bool {
        var at = index + 1
        if src.startsWith("{\\\n", at: at) { return true }
        if src.unit(at: at) == uLBrace && src.unit(at: at + 1) == uLParen {
            guard let end = matchZshSafeFlagsEnd(src, at: index) else { return true }
            at = end
        }
        if src.unit(at: at) == uLBrace { at += 1 }
        return matchZshGlobModifier(src, at: at)
    }

    // ZSH_GLOB_QUALIFIER_RE
    private static let zshSimpleQualifiers: Set<UInt16> = Set("/F.@=*rwxAIERWsStUG^MTNDn-".utf16)
    private static let zshOrderQualifiers: Set<UInt16> = Set("nLlamcdN".utf16)
    private static let zshTimeUnits: Set<UInt16> = Set("Mwhmsd".utf16)
    private static let zshSizeUnits: Set<UInt16> = Set("kKmMpPgGtT".utf16)

    private static func matchZshGlobQualifierEnd(_ src: UTF16Source, at index: Int) -> Int? {
        guard src.unit(at: index) == uLParen else { return nil }
        var i = index + 1
        var matchedOne = false
        while i < src.count {
            let u = src.units[i]
            if u == uRParen {
                guard matchedOne else { return nil }
                let after = skipLineContinuations(src, from: i + 1)
                guard let next = src.unit(at: after) else { return i + 1 }
                if next == uSpace || next == uTab || next == uLF || next == uSemi || next == uAmp ||
                    next == uPipe || next == uLT || next == uGT || next == uRParen
                {
                    return i + 1
                }
                return nil
            }
            if u == uComma || zshSimpleQualifiers.contains(u) {
                matchedOne = true
                i += 1
                continue
            }
            if (u == UInt16(ascii: "o") || u == UInt16(ascii: "O")),
               let next = src.unit(at: i + 1), zshOrderQualifiers.contains(next)
            {
                matchedOne = true
                i += 2
                continue
            }
            if u == UInt16(ascii: "a") || u == UInt16(ascii: "m") || u == UInt16(ascii: "c") {
                var k = i + 1
                if let next = src.unit(at: k), zshTimeUnits.contains(next) { k += 1 }
                if let sign = src.unit(at: k), (sign == uPlus || sign == uMinus) { k += 1 }
                let digitStart = k
                while let d = src.unit(at: k), isASCIIDigit(d) { k += 1 }
                if k > digitStart {
                    matchedOne = true
                    i = k
                    continue
                }
                return nil
            }
            if u == UInt16(ascii: "L") {
                var k = i + 1
                if let next = src.unit(at: k), zshSizeUnits.contains(next) { k += 1 }
                if let sign = src.unit(at: k), (sign == uPlus || sign == uMinus) { k += 1 }
                let digitStart = k
                while let d = src.unit(at: k), isASCIIDigit(d) { k += 1 }
                if k > digitStart {
                    matchedOne = true
                    i = k
                    continue
                }
                return nil
            }
            if u == UInt16(ascii: "l") || u == UInt16(ascii: "Y") {
                var k = i + 1
                if let sign = src.unit(at: k), (sign == uPlus || sign == uMinus) { k += 1 }
                let digitStart = k
                while let d = src.unit(at: k), isASCIIDigit(d) { k += 1 }
                if k > digitStart {
                    matchedOne = true
                    i = k
                    continue
                }
                return nil
            }
            if u == uLBracket {
                var k = i + 1
                if let sign = src.unit(at: k), (sign == uPlus || sign == uMinus) { k += 1 }
                let d1 = k
                while let d = src.unit(at: k), isASCIIDigit(d) { k += 1 }
                guard k > d1 else { return nil }
                if src.unit(at: k) == uComma {
                    k += 1
                    if let sign = src.unit(at: k), (sign == uPlus || sign == uMinus) { k += 1 }
                    let d2 = k
                    while let d = src.unit(at: k), isASCIIDigit(d) { k += 1 }
                    guard k > d2 else { return nil }
                }
                guard src.unit(at: k) == uRBracket else { return nil }
                matchedOne = true
                i = k + 1
                continue
            }
            return nil
        }
        return nil
    }

    // ZSH_SUBSCRIPT_RE = /\$(?:[\^=+~#]|\\\n)*(?:[A-Za-z_](?:[A-Za-z0-9_]|\\\n)*|[@*#?$!0-9-])(?:\\\n)*\[/y
    private static func matchZshSubscriptEnd(_ src: UTF16Source, at index: Int) -> Int? {
        guard src.unit(at: index) == uDollar else { return nil }
        var i = index + 1
        while i < src.count {
            let u = src.units[i]
            if u == uCaret || u == uEq || u == uPlus || u == uTilde || u == uHash { i += 1 }
            else if u == uBackslash && src.unit(at: i + 1) == uLF { i += 2 }
            else { break }
        }
        guard let first = src.unit(at: i) else { return nil }
        if isIdentStart(first) {
            i += 1
            while i < src.count {
                let u = src.units[i]
                if isIdentCont(u) { i += 1 }
                else if u == uBackslash && src.unit(at: i + 1) == uLF { i += 2 }
                else { break }
            }
        } else if first == uAt || first == uStar || first == uHash || first == uQMark ||
            first == uDollar || first == uBang || isASCIIDigit(first) || first == uMinus
        {
            i += 1
        } else {
            return nil
        }
        i = skipLineContinuations(src, from: i)
        guard src.unit(at: i) == uLBracket else { return nil }
        return i + 1
    }

    // PARAMETER_PREFIX_RE = /(?:\\\n)*(?:\([^)]*\))?(?:[!#^=+~]|\\\n)*/y
    private static func matchParameterPrefixEnd(_ src: UTF16Source, at index: Int) -> Int {
        var i = skipLineContinuations(src, from: index)
        if src.unit(at: i) == uLParen {
            if let close = src.indexOf(uRParen, from: i + 1) {
                i = close + 1
            }
        }
        while i < src.count {
            let u = src.units[i]
            if u == uBang || u == uHash || u == uCaret || u == uEq || u == uPlus || u == uTilde { i += 1 }
            else if u == uBackslash && src.unit(at: i + 1) == uLF { i += 2 }
            else { break }
        }
        return i
    }

    // PARAMETER_NAME_RE = /(?:[A-Za-z_](?:[A-Za-z0-9_]|\\\n)*|\d(?:\d|\\\n)*|[@*#?$!-])(?:\\\n)*/y
    private static func matchParameterNameEnd(_ src: UTF16Source, at index: Int) -> Int? {
        guard let first = src.unit(at: index) else { return nil }
        var i = index
        if isIdentStart(first) {
            i += 1
            while i < src.count {
                let u = src.units[i]
                if isIdentCont(u) { i += 1 }
                else if u == uBackslash && src.unit(at: i + 1) == uLF { i += 2 }
                else { break }
            }
        } else if isASCIIDigit(first) {
            i += 1
            while i < src.count {
                let u = src.units[i]
                if isASCIIDigit(u) { i += 1 }
                else if u == uBackslash && src.unit(at: i + 1) == uLF { i += 2 }
                else { break }
            }
        } else if first == uAt || first == uStar || first == uHash || first == uQMark ||
            first == uDollar || first == uBang || first == uMinus
        {
            i += 1
        } else {
            return nil
        }
        return skipLineContinuations(src, from: i)
    }

    // PARAMETER_PROMPT_RE = /@(?:\\\n)*[EP](?:\\\n)*\}/y
    private static func matchParameterPrompt(_ src: UTF16Source, at index: Int) -> Bool {
        guard src.unit(at: index) == uAt else { return false }
        var i = skipLineContinuations(src, from: index + 1)
        guard let u = src.unit(at: i), (u == UInt16(ascii: "E") || u == UInt16(ascii: "P")) else { return false }
        i = skipLineContinuations(src, from: i + 1)
        return src.unit(at: i) == uRBrace
    }

    // BASH_EXPANSION_RE = /\$(?:\\.|\\\n)*[({]|`/
    private static func hasBashExpansion(_ s: String) -> Bool {
        let u = Array(s.utf16)
        var i = 0
        while i < u.count {
            if u[i] == uBacktick { return true }
            if u[i] == uDollar {
                var k = i + 1
                while k < u.count && u[k] == uBackslash && k + 1 < u.count {
                    k += 2
                }
                if k < u.count && (u[k] == uLParen || u[k] == uLBrace) { return true }
            }
            i += 1
        }
        return false
    }

    // BASH_ESCAPE_RE = /\\(?:x[\da-fA-F]{1,2}|[0-7]{1,3}|u[\da-fA-F]{1,4}|U[\da-fA-F]{1,8})/
    private static func hasBashEscape(_ s: String) -> Bool {
        let u = Array(s.utf16)
        var i = 0
        while i + 1 < u.count {
            if u[i] == uBackslash {
                let next = u[i + 1]
                if isASCIIOctal(next) { return true }
                if (next == UInt16(ascii: "x") || next == UInt16(ascii: "u") || next == UInt16(ascii: "U")),
                   i + 2 < u.count, isASCIIHex(u[i + 2])
                {
                    return true
                }
            }
            i += 1
        }
        return false
    }

    private static func isPureIdentifier(_ s: String) -> Bool {
        let u = Array(s.utf16)
        guard let first = u.first, isIdentStart(first) else { return false }
        for ch in u.dropFirst() where !isIdentCont(ch) { return false }
        return true
    }

    private static func isPureIdentifierOptionalPlus(_ s: String) -> Bool {
        let u = Array(s.utf16)
        guard let first = u.first, isIdentStart(first) else { return false }
        let body = u.last == uPlus ? u.dropFirst().dropLast() : u.dropFirst()[...]
        for ch in body where !isIdentCont(ch) { return false }
        return true
    }

    private static func isFdPrefixWord(_ s: String) -> Bool {
        let u = Array(s.utf16)
        if u.isEmpty { return false }
        if u.allSatisfy({ isASCIIDigit($0) }) { return true }
        if u.count >= 3 && u.first == uLBrace && u.last == uRBrace {
            return isPureIdentifier(String(decoding: u[1..<(u.count - 1)], as: UTF16.self))
        }
        return false
    }

    private static func isDupFdTarget(_ s: String) -> Bool {
        let u = Array(s.utf16)
        if u == [uMinus] { return true }
        guard !u.isEmpty else { return false }
        let digits = u.last == uMinus ? u.dropLast() : u[...]
        return !digits.isEmpty && digits.allSatisfy({ isASCIIDigit($0) })
    }

    private static func isZshSpecialBindingName(_ word: String) -> Bool {
        // /^(?:-[A-Za-z]*v)?(?:(?:dis_)?(?:functions|[gs]?aliases)|options|commands)(?:\+?=|\[|$)/
        var s = word[...]
        if s.hasPrefix("-") {
            var idx = s.index(after: s.startIndex)
            while idx < s.endIndex && s[idx].isASCII && s[idx].isLetter && s[idx] != "v" {
                idx = s.index(after: idx)
            }
            if idx < s.endIndex && s[idx] == "v" {
                s = s[s.index(after: idx)...]
            }
        }
        if s.hasPrefix("dis_") {
            s = s.dropFirst(4)
        }
        let targets = ["functions", "galiases", "saliases", "aliases", "options", "commands"]
        for t in targets where s.hasPrefix(t) {
            let tail = s.dropFirst(t.count)
            if tail.isEmpty || tail.hasPrefix("=") || tail.hasPrefix("+=") || tail.hasPrefix("[") {
                return true
            }
        }
        return false
    }

    private static func matchesFlagContaining(_ word: String, prefixes: [Character], chars: String) -> Bool {
        guard let first = word.first, prefixes.contains(first) else { return false }
        for c in word.dropFirst() {
            if chars.contains(c) { return true }
        }
        return false
    }

    private static func isAlnumFlagContaining(_ word: String, prefixes: [Character], char: Character) -> Bool {
        guard let first = word.first, prefixes.contains(first) else { return false }
        var seen = false
        for c in word.dropFirst() {
            if c == char { seen = true }
            if !c.isASCII || (!c.isLetter && !c.isNumber) {
                return seen
            }
        }
        return seen
    }

    private static func isZshUnsafeOptionArg(_ word: String) -> Bool {
        // /^-[A-Za-z0-9]*m/
        if word.hasPrefix("-") {
            var ok = true
            for c in word.dropFirst() {
                if c == "m" && ok { return true }
                if !c.isASCII || (!c.isLetter && !c.isNumber) { ok = false; break }
            }
        }
        // strip /^[-+][A-Za-z0-9]*?o/i
        var stripped = word
        if let first = stripped.first, (first == "-" || first == "+") {
            let afterSign = stripped.dropFirst()
            var cur = afterSign.startIndex
            while cur < afterSign.endIndex {
                let c = afterSign[cur]
                if c == "o" || c == "O" {
                    stripped = String(afterSign[afterSign.index(after: cur)...])
                    break
                }
                if !c.isASCII || (!c.isLetter && !c.isNumber) { break }
                cur = afterSign.index(after: cur)
            }
        }
        let norm = stripped.lowercased().filter { $0 != "_" && $0 != "-" }
        let clean = norm.hasPrefix("no") ? String(norm.dropFirst(2)) : norm
        return clean == "globsubst" || clean == "kshglob" || clean == "promptsubst" ||
            clean == "promptvars" || clean == "aliases"
    }

    // MARK: - Bash Scanner Core

    private static func bashStatement(_ state: BashState) {
        state.structures.last?.count += 1
    }

    private static func bashInHeader(_ state: BashState) -> Bool {
        guard let phase = state.structures.last?.phase else { return false }
        return phase == .header || phase == .pattern || phase == .do
    }

    private static func atCommandStart(_ state: BashState) -> Bool {
        state.words.isEmpty && !state.hasRedirect && !state.compoundEnd && !bashInHeader(state)
    }

    private static func isPending(_ state: BashState) -> Bool {
        state.wordStarted || !state.words.isEmpty || state.hasRedirect || state.compoundEnd
    }

    private static func endBashList(_ state: BashState) -> Bool {
        if isPending(state) { finishBashCommand(state, boundary: false, newline: true) }
        return !state.dangling
    }

    private static func closeBashList(_ state: BashState, end: Int) -> InternalResult {
        if !endBashList(state) { return .opaque(.invalidStructure) }
        if let inv = state.invalid { return .opaque(inv) }
        if !state.structures.isEmpty { return .opaque(.compoundCommand) }
        return .scanned(commands: state.commands, end: end)
    }

    private static func bashAppend(_ text: BashText, _ value: String) {
        text.word += value
        text.literal += value
    }

    private static func bashBuiltinIndex(_ state: BashState) -> Int {
        var name = state.commandWordIndex
        while name >= 0 && name < state.words.count &&
            (bashPrecommands.contains(state.words[name]) ||
                (state.context.dialect != .bash && zshPrecommands.contains(state.words[name])))
        {
            let precommand = state.words[name]
            name += 1
            while precommand != "-", name < state.words.count, state.words[name].hasPrefix("-") {
                if precommand == "exec" {
                    let w = state.words[name]
                    if w.hasPrefix("-"), w.hasSuffix("a"),
                       w.dropFirst().dropLast().allSatisfy({ $0 == "c" || $0 == "l" })
                    {
                        name += 1
                    }
                }
                name += 1
            }
        }
        return name
    }

    private static func bashWordEvaluation(_ state: BashState) -> BashEvaluation? {
        if state.redirectTarget { return state.hereString ? .deferred : nil }
        let structure = state.structures.last
        if structure?.kind == .repeat && structure?.phase == .header { return .arithmetic }
        if structure?.kind == .for && structure?.phase == .header && structure?.sawIn == true { return .deferred }
        if state.commandWordIndex < 0 { return state.assignmentWord ? .deferred : nil }
        let name = bashBuiltinIndex(state)
        guard name >= 0 && name < state.words.count else { return nil }
        let command = state.words[name]
        if command == "let" || (state.context.dialect != .bash && zshArithmeticBuiltins.contains(command)) {
            return .arithmetic
        }
        let options = Array(state.words[(name + 1)...])
        if command == "set" {
            return options.contains(where: { isAlnumFlagContaining($0, prefixes: ["-", "+"], char: "A") })
                ? .binding : .deferred
        }
        if bashBindingBuiltins.contains(command) {
            if options.contains(where: { matchesFlagContaining($0, prefixes: ["-"], chars: "EFin") }) {
                return .arithmetic
            }
            if state.assignmentWord &&
                bashAssignmentDeclarations.contains(command) &&
                options.allSatisfy({ !$0.hasPrefix("-") }) &&
                (command == "export" || command == "readonly" || state.context.dialect == .zsh ||
                    !hasAssignOpenExpansion(state.text.word))
            {
                return .deferred
            }
            return .binding
        }
        if command == "printf" || command == "print" {
            var all = options
            all.append(state.text.word)
            if command == "print" {
                return all.contains(where: { w in
                    guard w.hasPrefix("-") else { return false }
                    for c in w.dropFirst() {
                        if c == "v" { return true }
                        if !c.isASCII || !c.isLetter { return false }
                    }
                    return false
                }) ? .binding : nil
            } else {
                return all.contains(where: { $0.hasPrefix("-v") }) ? .binding : nil
            }
        }
        if command == "wait" {
            let isWaitP: (String, Bool) -> Bool = { w, exact in
                guard w.hasPrefix("-") else { return false }
                var sawP = false
                for c in w.dropFirst() {
                    if c == "p" { sawP = true; if !exact { return true } }
                    else if c != "n" && c != "f" { return false }
                    else if sawP && exact { return false }
                }
                return sawP
            }
            if isWaitP(state.text.word, false) || isWaitP(state.words.last ?? "", true) {
                return .binding
            }
            return nil
        }
        if command == "test" || command == "[" {
            if state.words.last == "-v" { return .binding }
            if state.context.dialect != .bash && state.words.last == "-t" { return .arithmetic }
        }
        return nil
    }

    // /\+?=(?:\(|[$`])/
    private static func hasAssignOpenExpansion(_ s: String) -> Bool {
        let u = Array(s.utf16)
        for i in 0..<u.count where u[i] == uEq {
            if i + 1 < u.count {
                let next = u[i + 1]
                if next == uLParen || next == uDollar || next == uBacktick { return true }
            }
        }
        return false
    }

    @discardableResult
    private static func bashEvaluatesExpansion(
        _ text: BashText,
        evaluation: BashEvaluation,
        context: BashContext
    ) -> Bool {
        let combined = "\(text.literal) \(text.output)"
        let hasExp = hasBashExpansion(combined)
        let hasEsc = hasBashEscape(combined)
        if hasExp || hasEsc || text.literal.contains("$") || text.literal.contains("`") {
            context.boundDollar = true
        }
        if hasExp || hasEsc || text.literal.contains("(") || text.literal.contains("{") || text.literal.contains("`") {
            context.boundOpen = true
        }
        if hasExp || hasEsc || !text.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            combined.contains("[")
        {
            context.boundBracket = true
        }
        if evaluation == .deferred { return false }
        if text.word.contains("[") || combined.contains("[") {
            context.sinkBracket = true
        }
        let isVarSink: Bool
        if evaluation == .arithmetic {
            // /[A-Za-z_]|(?:\$(?![?#!-]|\$(?!\[)))/
            isVarSink = hasArithmeticVarRef(text.word)
        } else {
            isVarSink = text.word.contains("$") || combined.contains("[")
        }
        if isVarSink { context.variableSink = true }
        if evaluation == .arithmetic { return hasExp }
        return combined.contains("[") && hasExp
    }

    private static func hasArithmeticVarRef(_ s: String) -> Bool {
        let u = Array(s.utf16)
        for i in 0..<u.count {
            let ch = u[i]
            if isIdentStart(ch) { return true }
            if ch == uDollar {
                let next = (i + 1 < u.count) ? u[i + 1] : 0
                if next == uQMark || next == uHash || next == uBang || next == uMinus { continue }
                if next == uDollar {
                    let after = (i + 2 < u.count) ? u[i + 2] : 0
                    if after == uLBracket { return true }
                    continue
                }
                return true
            }
        }
        return false
    }

    private static func finishBashWord(_ state: BashState) {
        guard state.wordStarted else { return }
        if state.text.word.contains("PS4") { state.context.evalSink = true }
        let evaluation = bashWordEvaluation(state)
        if state.context.dialect != .bash &&
            (state.text.word.contains("NULLCMD") ||
                ((state.assignmentWord || evaluation == .binding) && isZshSpecialBindingName(state.text.word)))
        {
            if state.invalid == nil { state.invalid = .dynamicExecution }
        }
        if let eval = evaluation, bashEvaluatesExpansion(state.text, evaluation: eval, context: state.context) {
            if state.invalid == nil { state.invalid = .dynamicExecution }
        }
        if state.text.word != state.text.literal && state.commandWordIndex >= 0 {
            let idx = bashBuiltinIndex(state)
            if idx >= 0 && idx < state.words.count {
                let builtin = state.words[idx]
                if builtin == "declare" || builtin == "typeset" || builtin == "local" {
                    state.context.evalSink = true
                }
            }
        }
        if let outer = state.outer {
            outer.output += " \(state.text.literal) \(state.text.output)"
        }
        let structure = state.structures.last
        let repeatHeader = structure?.kind == .repeat && structure?.phase == .header
        if !state.redirectTarget && repeatHeader {
            structure?.phase = .do
        }
        if !state.redirectTarget && !repeatHeader {
            if !state.assignmentWord && state.commandWordIndex < 0 {
                state.commandWordIndex = state.words.count
            }
            if state.commandStart == nil { state.commandStart = state.wordStart }
            state.words.append(state.text.word)
            state.rawWords.append(state.src.slice(state.wordStart, state.wordEnd))
        }
        if state.redirectTarget {
            if !state.dupRedirect || !isDupFdTarget(state.src.slice(state.wordStart, state.wordEnd)) {
                state.hasFileRedirect = true
            }
            if state.redirectPrefixEnd == nil { state.redirectPrefixEnd = state.wordEnd }
        }
        state.redirectTarget = false
        state.dupRedirect = false
        state.hereString = false
        state.text.word = ""
        state.text.literal = ""
        state.text.output = ""
        state.wordStarted = false
        state.assignmentWord = false
        state.assignmentHeadUnsafe = false
    }

    private static func trimBashWhitespace(_ s: String) -> String {
        var u = Array(s.utf16)
        var start = 0
        while start < u.count && (u[start] == uSpace || u[start] == uTab || u[start] == uLF) { start += 1 }
        var end = u.count
        while end > start && (u[end - 1] == uSpace || u[end - 1] == uTab || u[end - 1] == uLF) { end -= 1 }
        if start == 0 && end == u.count { return s }
        u = Array(u[start..<end])
        return String(decoding: u, as: UTF16.self)
    }

    private static func leadingBashWhitespaceCount(_ s: String) -> Int {
        var n = 0
        for u in s.utf16 {
            if u == uSpace || u == uTab || u == uLF { n += 1 } else { break }
        }
        return n
    }

    private static func finishBashCommand(_ state: BashState, boundary: Bool = false, newline: Bool = false) {
        finishBashWord(state)
        if state.redirectTarget {
            if state.invalid == nil { state.invalid = .invalidRedirect }
        }
        state.redirectTarget = false
        if state.compoundEnd && !state.words.isEmpty {
            if state.invalid == nil { state.invalid = .invalidStructure }
        }
        let name = state.commandWordIndex
        let inHeader = bashInHeader(state)
        if name >= 0 && (name >= state.words.count || state.words[name].isEmpty) {
            if state.invalid == nil { state.invalid = .invalidStructure }
        }
        var ownerIndex: Int?
        if name >= 0 && !inHeader {
            let cmdStart = state.commandStart ?? 0
            let resource = trimBashWhitespace(state.src.slice(cmdStart, state.wordEnd))
            let isDecl = name == 0 && !state.hasRedirect &&
                !state.rawWords.isEmpty && bashDeclarations.contains(state.rawWords[0]) &&
                resource.hasPrefix(state.rawWords[0])
            let redirCount: Int? = (state.redirectWordCount != nil && state.redirectWordCount! < state.words.count)
                ? (state.redirectWordCount! - name) : nil
            let command = CoreShell.Scan.Command(
                resource: resource,
                words: Array(state.words[name...]),
                rawWords: Array(state.rawWords[name...]),
                declaration: isDecl,
                redirectWordCount: redirCount
            )
            state.commands.append(command)
            ownerIndex = state.commands.count - 1

            let builtinIdx = bashBuiltinIndex(state)
            let builtinName = (builtinIdx >= 0 && builtinIdx < state.words.count) ? state.words[builtinIdx] : nil
            let builtinArgs = (builtinIdx >= 0 && builtinIdx + 1 <= state.words.count)
                ? Array(state.words[(builtinIdx + 1)...]) : []

            if builtinName == "eval" { state.context.evalSink = true }
            if builtinName == "set" &&
                builtinArgs.contains(where: { isAlnumFlagContaining($0, prefixes: ["-"], char: "k") || $0 == "keyword" })
            {
                if state.invalid == nil { state.invalid = .dynamicExecution }
            }
            if builtinName == "alias" && builtinArgs.contains(where: { $0.contains("=") }) {
                if state.invalid == nil { state.invalid = .dynamicExecution }
            }
            if state.context.dialect != .bash {
                let zshOptTriggered = builtinName == "emulate" ||
                    ((builtinName == "setopt" || builtinName == "unsetopt" ||
                        (builtinName == "set" && builtinArgs.contains(where: { isAlnumFlagContaining($0, prefixes: ["-", "+"], char: "o") }))) &&
                        builtinArgs.contains(where: { isZshUnsafeOptionArg($0) }))
                if zshOptTriggered {
                    if state.invalid == nil { state.invalid = .dynamicExecution }
                }
            }
            if state.context.dialect != .zsh && builtinName == "compgen" &&
                builtinArgs.contains(where: { matchesFlagContaining($0, prefixes: ["-"], chars: "CF") })
            {
                if state.invalid == nil { state.invalid = .dynamicExecution }
            }
            if let bn = builtinName, bashBindingBuiltins.contains(bn) {
                for hd in state.heredocs {
                    if hd.binding == nil { hd.binding = true }
                }
            }
        } else if name < 0 && !inHeader, let cmdStart = state.commandStart,
                  (state.hasFileRedirect || (state.hasRedirect && !state.compoundEnd))
        {
            let rawSpan = state.src.slice(cmdStart, state.wordEnd)
            let leading = leadingBashWhitespaceCount(rawSpan)
            let resource = trimBashWhitespace(rawSpan)
            if !resource.isEmpty {
                let resLen = resource.utf16.count
                let prefixEnd: Int
                if let rpe = state.redirectPrefixEnd {
                    prefixEnd = max(1, min(resLen, rpe - cmdStart - leading))
                } else {
                    prefixEnd = resLen
                }
                let prefixToken = String(decoding: Array(resource.utf16)[0..<prefixEnd], as: UTF16.self)
                let command = CoreShell.Scan.Command(
                    resource: resource,
                    words: [prefixToken],
                    rawWords: [prefixToken],
                    redirectPrefixEnd: prefixEnd
                )
                state.commands.append(command)
                ownerIndex = state.commands.count - 1
            }
        }
        for hd in state.heredocs {
            if let ownerIdx = ownerIndex, newline, !hd.owned {
                hd.commandIndex = ownerIdx
                hd.start = state.commandStart
            }
            hd.owned = true
        }
        if boundary && state.words.isEmpty && !state.hasRedirect && !state.compoundEnd && !inHeader {
            if state.invalid == nil { state.invalid = .invalidStructure }
        }
        if let ampLimit = state.ampersandRedirectWords, state.words.count > ampLimit {
            if state.invalid == nil { state.invalid = .invalidRedirect }
        }
        state.commands.append(contentsOf: state.nestedCommands)
        state.nestedCommands.removeAll()
        if !inHeader && (!state.words.isEmpty || state.hasRedirect) {
            bashStatement(state)
        }
        state.words.removeAll()
        state.rawWords.removeAll()
        state.commandWordIndex = -1
        state.commandStart = nil
        state.dupRedirect = false
        state.hasRedirect = false
        state.hasFileRedirect = false
        state.redirectWordCount = nil
        state.redirectPrefixEnd = nil
        state.ampersandRedirectWords = nil
        state.compoundEnd = false
        state.dangling = false
    }

    enum CloseMode { case rparen, rbrace, nofork }

    private static func scanBash(
        _ src: UTF16Source,
        start: Int,
        depth: Int,
        context: BashContext,
        close: CloseMode? = nil,
        sharedHeredocs: [BashHeredoc]? = nil,
        outer: BashText? = nil
    ) -> InternalResult {
        if depth > maxSubstitutionDepth || context.remaining < 0 {
            return .opaque(.invalidStructure)
        }
        let state = BashState(
            src: src,
            start: start,
            context: context,
            heredocs: sharedHeredocs ?? [],
            outer: outer
        )
        var index = start
        while index < src.count {
            context.remaining -= 1
            if context.remaining < 0 { return .opaque(.invalidStructure) }
            let ch = src.units[index]
            if ch == uBackslash && src.unit(at: index + 1) == uLF {
                index += 2
                continue
            }
            if !state.wordStarted {
                state.wordStart = index
                if ch == uSpace || ch == uTab {
                    index += 1
                    continue
                }
                if ch == uRBrace && state.words.isEmpty && !state.redirectTarget &&
                    (close == .rbrace || close == .nofork) &&
                    state.structures.isEmpty &&
                    (sharedHeredocs != nil || state.heredocs.isEmpty) &&
                    (close == .nofork || matchBraceCloseAhead(src, at: index + 1))
                {
                    return closeBashList(state, end: index)
                }
                if ch == uRBrace {
                    return .opaque(state.structures.isEmpty ? .invalidStructure : .compoundCommand)
                }
                switch scanBashCommandStart(state, index: index, depth: depth, context: context) {
                case .opaque(let r): return .opaque(r)
                case .index(let nextIdx):
                    index = nextIdx + 1
                    continue
                case .none: break
                }
            }
            if ch == uBackslash && index + 1 >= src.count {
                return .opaque(.unterminatedEscape)
            }
            if !state.assignmentWord &&
                (ch == uSingleQuote || ch == uDoubleQuote || ch == uBackslash ||
                    (ch == uDollar && (src.unit(at: index + 1) == uSingleQuote || src.unit(at: index + 1) == uDoubleQuote)))
            {
                state.assignmentHeadUnsafe = true
            }
            let inCasePattern = state.structures.last?.phase == .pattern
            let isArray = (ch == uEq || ch == uLParen) &&
                state.assignmentWord &&
                state.text.word.utf16.count > 1 &&
                state.text.word.hasSuffix("=") &&
                !state.text.word.hasSuffix("==") &&
                (state.commandWordIndex < 0 ||
                    (state.commandWordIndex < state.rawWords.count &&
                        bashAssignmentDeclarations.contains(state.rawWords[state.commandWordIndex])))

            if ch == uEq && (!state.wordStarted || isArray) && src.unit(at: index + 1) == uLParen {
                switch scanBashNested(src, start: index + 2, depth: depth, context: context, commands: &state.nestedCommands, close: .rparen) {
                case .opaque(let r): return .opaque(r)
                case .index(let end):
                    state.wordStarted = true
                    state.text.word += src.slice(index, end + 1)
                    index = end + 1
                    state.wordEnd = index
                    continue
                case .none: break
                }
            }

            if ch == uBackslash || ch == uDollar || ch == uSingleQuote || ch == uDoubleQuote ||
                ch == uBacktick || ch == uLT || ch == uGT
            {
                let allowBracket = !state.assignmentWord && state.commandWordIndex >= 0 &&
                    !(state.rawWords.first.map { bashDeclarations.contains($0) } ?? false)
                switch scanBashUnit(
                    src, index: index, depth: depth, context: context,
                    commands: &state.nestedCommands, mode: .word, allowBracket: allowBracket, text: state.text
                ) {
                case .opaque(let r): return .opaque(r)
                case .index(let unitEnd):
                    state.wordStarted = true
                    index = unitEnd + 1
                    state.wordEnd = index
                    continue
                case .none: break
                }
            }

            if ch == uLBracket && !inCasePattern && !state.assignmentWord && !state.assignmentHeadUnsafe &&
                state.commandWordIndex < 0 && isPureIdentifier(state.text.word)
            {
                var subscriptCmds: [CoreShell.Scan.Command] = []
                switch scanBashSubscript(
                    src, start: index + 1, depth: depth, context: context,
                    commands: &subscriptCmds, span: spanAssignmentSubscript
                ) {
                case .opaque(let r): return .opaque(r)
                case .index(let end):
                    let op = bashOperator(src, index: end + 1, operators: ["+=", "="])
                    switch op {
                    case .opaque(let r): return .opaque(r)
                    case .matched:
                        if context.dialect == .posix {
                            let subSlice = src.slice(index + 1, end)
                            if subSlice.contains("$") || subSlice.contains("`") {
                                return .opaque(.invalidStructure)
                            }
                        }
                        state.nestedCommands.append(contentsOf: subscriptCmds)
                        state.assignmentWord = true
                        state.text.word += src.slice(index, end + 1)
                        index = end + 1
                        state.wordEnd = index
                        continue
                    case .none: break
                    }
                case .none: break
                }
            }

            if ch == uLParen &&
                (isArray || ((inCasePattern || context.dialect == .bash) && endsWithExtglobPrefix(state.text.word)))
            {
                let modeIsArray = isArray
                switch scanBashArrayOrPattern(
                    src, start: index, depth: depth + 1, context: context,
                    commands: &state.nestedCommands, isArray: modeIsArray
                ) {
                case .opaque(let r): return .opaque(r)
                case .index(let end):
                    if bashCrossesHeredoc(state, start: index, end: end) { return .opaque(.heredoc) }
                    if modeIsArray, let after = src.unit(at: end + 1),
                       !(after == uSpace || after == uTab || after == uLF || after == uSemi ||
                         after == uAmp || after == uPipe || after == uLT || after == uGT || after == uRParen)
                    {
                        return .opaque(.invalidStructure)
                    }
                    state.wordStarted = true
                    state.text.word += src.slice(index, end + 1)
                    index = end + 1
                    state.wordEnd = index
                    continue
                case .none: break
                }
            }

            if ch == uHash && !state.wordStarted {
                if let nl = src.indexOf(uLF, from: index) {
                    index = nl
                    continue
                } else {
                    break
                }
            }

            if ch == uLT || ch == uGT || ch == uAmp || ch == uPipe || ch == uSemi || ch == uLF {
                switch scanBashOperatorOrSeparator(state, index: index, depth: depth, context: context) {
                case .opaque(let r): return .opaque(r)
                case .index(let nextIdx):
                    index = nextIdx + 1
                    continue
                case .none: break
                }
            }

            if inCasePattern && ch == uRParen {
                finishBashWord(state)
                // Reprocess ')' at start of next iteration
                continue
            }

            if ch == uRParen {
                if close != .rparen || !state.structures.isEmpty || (sharedHeredocs == nil && !state.heredocs.isEmpty) {
                    return .opaque(.compoundCommand)
                }
                return closeBashList(state, end: index)
            }

            if ch == uLParen && context.dialect == .zsh && state.wordStarted && !inCasePattern,
               let qualEnd = matchZshGlobQualifierEnd(src, at: index)
            {
                bashAppend(state.text, src.slice(index, qualEnd))
                index = qualEnd
                state.wordEnd = index
                continue
            }

            if ch == uLParen {
                return .opaque(state.wordStarted ? .dynamicExecution : .compoundCommand)
            }

            if isJSWhitespace(ch) && ch != uSpace && ch != uTab && ch != uLF {
                return .opaque(.invalidStructure)
            }

            if ch == uSpace || ch == uTab {
                finishBashWord(state)
                index += 1
                continue
            }

            state.wordStarted = true
            if ch == uEq && !state.assignmentWord && !state.assignmentHeadUnsafe &&
                isPureIdentifierOptionalPlus(state.text.word)
            {
                state.assignmentWord = true
            }
            bashAppend(state.text, src.slice(index, index + 1))
            index += 1
            state.wordEnd = index
        }

        if let close {
            return .opaque(close == .rparen ? .commandSubstitution : .invalidStructure)
        }
        if !state.heredocs.isEmpty {
            return .opaque(.heredoc)
        }
        return closeBashList(state, end: src.count)
    }

    private static func endsWithExtglobPrefix(_ s: String) -> Bool {
        guard let last = s.utf16.last else { return false }
        return last == uQMark || last == uStar || last == uPlus || last == uAt || last == uBang
    }

    private static func bashCrossesHeredoc(_ state: BashState, start: Int, end: Int) -> Bool {
        guard !state.heredocs.isEmpty else { return false }
        for i in start..<min(end, state.src.count) where state.src.units[i] == uLF {
            return true
        }
        return false
    }

    private static func readBashHeredocs(
        _ state: BashState,
        index: Int,
        depth: Int,
        context: BashContext
    ) -> StepOutcome {
        var end = index
        let pendingHeredocs = state.heredocs
        state.heredocs.removeAll()
        for hd in pendingHeredocs {
            guard let body = bashHeredoc(state.src, start: end + 1, heredoc: hd) else {
                return .opaque(.heredoc)
            }
            if let cmdIdx = hd.commandIndex, let hdStart = hd.start, cmdIdx < state.commands.count {
                state.commands[cmdIdx].resource = state.src.slice(hdStart, body.end).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let text = BashText()
            if hd.quoted {
                text.word = body.source
                text.literal = body.source
            } else {
                let bodySrc = UTF16Source(body.source)
                switch scanBashSpan(
                    bodySrc, start: 0, depth: depth, context: context,
                    commands: &state.commands, span: spanHeredoc, allowBracket: true, text: text
                ) {
                case .opaque(let r): return .opaque(r)
                case .index, .none: break
                }
            }
            if hd.binding == true {
                bashEvaluatesExpansion(text, evaluation: .deferred, context: context)
            }
            end = body.end
        }
        return .index(end)
    }

    private static func scanBashOperatorOrSeparator(
        _ state: BashState,
        index: Int,
        depth: Int,
        context: BashContext
    ) -> StepOutcome {
        let src = state.src
        let ch = src.units[index]
        if ch == uLT || ch == uGT || ch == uAmp {
            switch bashOperator(src, index: index, operators: bashRedirects) {
            case .opaque(let r): return .opaque(r)
            case .matched(let redirect):
                if let caseHead = state.structures.last, caseHead.kind == .case && caseHead.phase != .body {
                    return .opaque(.invalidRedirect)
                }
                state.hasRedirect = true
                if state.commandStart == nil { state.commandStart = state.wordStart }
                if state.redirectTarget {
                    if state.invalid == nil { state.invalid = .invalidRedirect }
                }
                let fdPrefix = state.wordStarted && !state.assignmentHeadUnsafe && isFdPrefixWord(state.text.word)
                if fdPrefix {
                    state.text.word = ""
                    state.text.literal = ""
                    state.text.output = ""
                    state.wordStarted = false
                } else {
                    finishBashWord(state)
                }
                if redirect.hasPrefix("&") && context.dialect == .posix && state.ampersandRedirectWords == nil {
                    state.ampersandRedirectWords = state.words.count
                }
                if state.redirectWordCount == nil && state.commandWordIndex >= 0 {
                    state.redirectWordCount = state.words.count
                }
                let redirLen = redirect.utf16.count
                if redirect == "<<" || redirect == "<<-" {
                    guard let delim = bashHeredocDelimiter(
                        src, start: index + redirLen, tabs: redirect == "<<-", dialect: context.dialect
                    ) else {
                        return .opaque(.invalidRedirect)
                    }
                    state.hasFileRedirect = true
                    if state.redirectPrefixEnd == nil {
                        let afterOp = src.unit(at: index + redirLen)
                        state.redirectPrefixEnd = (afterOp == uSpace || afterOp == uTab) ? (index + redirLen) : (delim.end + 1)
                    }
                    state.heredocs.append(delim.heredoc)
                    state.wordEnd = delim.end + 1
                    state.redirectTarget = false
                    state.dupRedirect = false
                    return .index(delim.end)
                }
                if let afterOp = src.unit(at: index + redirLen), (afterOp == uSpace || afterOp == uTab || afterOp == uLF) {
                    if state.redirectPrefixEnd == nil { state.redirectPrefixEnd = index + redirLen }
                }
                state.redirectTarget = true
                state.dupRedirect = redirect == "<&" || redirect == ">&"
                state.hereString = redirect == "<<<"
                return .index(index + redirLen - 1)
            case .none: break
            }
        }

        if state.structures.last?.phase == .pattern && ch == uPipe {
            finishBashWord(state)
            return .index(index - 1)
        }
        let structure = state.structures.last
        let caseBody = structure?.kind == .case && structure?.phase == .body
        let ops: [String]
        if context.dialect == .zsh {
            ops = caseBody ? zshCaseOperators : zshListOperators
        } else {
            ops = caseBody ? bashCaseOperators : bashListOperators
        }
        let separator: String
        switch bashOperator(src, index: index, operators: ops) {
        case .opaque(let r): return .opaque(r)
        case .matched(let op): separator = op
        case .none: separator = src.slice(index, index + 1)
        }
        let sepLen = separator.utf16.count

        if caseBody && separator.hasPrefix(";") && sepLen > 1 {
            if !endBashList(state) { return .opaque(.invalidStructure) }
            structure?.phase = .pattern
            structure?.patternStarted = false
            return .index(index + sepLen - 1)
        }
        if structure?.kind == .case && (structure?.phase == .header || structure?.phase == .pattern) {
            if separator != "\n" { return .opaque(.compoundCommand) }
            if structure?.phase == .pattern && (state.wordStarted || !state.words.isEmpty) {
                return .opaque(.compoundCommand)
            }
            finishBashWord(state)
            return readBashHeredocs(state, index: index, depth: depth, context: context)
        }
        if (structure?.kind == .for || structure?.kind == .repeat) &&
            (structure?.phase == .header || structure?.phase == .do)
        {
            if separator != ";" && separator != "\n" { return .opaque(.compoundCommand) }
            if structure?.phase == .header && structure?.sawIn == false && !state.wordStarted && state.words.isEmpty {
                return .opaque(.compoundCommand)
            }
        }
        if separator == "\n" && !isPending(state) {
            return readBashHeredocs(state, index: index, depth: depth, context: context)
        }
        if separator == ";" && context.dialect == .zsh && !isPending(state) && !state.dangling {
            return .index(index)
        }
        finishBashCommand(state, boundary: true, newline: separator == "\n")
        if structure?.kind == .for && structure?.phase == .header {
            structure?.phase = .do
        }
        state.dangling = !(separator == ";" || separator == "\n" || (separator.hasPrefix("&") && separator != "&&"))
        if separator == "\n" && !state.heredocs.isEmpty {
            return .index(index - 1)
        }
        return .index(index + sepLen - 1)
    }

    private static func scanBashCommandStart(
        _ state: BashState,
        index: Int,
        depth: Int,
        context: BashContext
    ) -> StepOutcome {
        let src = state.src
        let ch = src.units[index]
        let structure = state.structures.last
        if structure?.phase == .pattern && structure?.patternStarted == false && state.words.isEmpty && ch == uLParen {
            structure?.patternStarted = true
            return .index(index)
        }
        if structure?.phase == .pattern && ch == uPipe {
            if state.words.isEmpty { return .opaque(.compoundCommand) }
            finishBashWord(state)
            structure?.patternStarted = true
            return .index(index)
        }
        if structure?.phase == .pattern && ch == uRParen {
            if state.words.isEmpty { return .opaque(.compoundCommand) }
            finishBashCommand(state)
            structure?.phase = .body
            structure?.count = 0
            return .index(index)
        }
        if structure?.kind == .for && structure?.phase == .header && ch == uLParen && src.unit(at: index + 1) != uLParen {
            switch scanBashArrayOrPattern(
                src, start: index, depth: depth + 1, context: context,
                commands: &state.nestedCommands, isArray: true
            ) {
            case .opaque(let r): return .opaque(r)
            case .index(let end):
                if bashCrossesHeredoc(state, start: index, end: end) { return .opaque(.heredoc) }
                finishBashCommand(state)
                structure?.phase = .do
                structure?.parenthesized = true
                if !matchDoAhead(src, at: end + 1) { _ = state.structures.popLast() }
                return .index(end)
            case .none: break
            }
        }
        if structure?.kind == .repeat && structure?.phase == .do && ch != uLF && ch != uHash && ch != uSemi {
            if matchToken(src, at: index) != "do" { _ = state.structures.popLast() }
        }
        switch scanBashKeyword(state, index: index, depth: depth, context: context) {
        case .opaque(let r): return .opaque(r)
        case .index(let end): return .index(end)
        case .none: break
        }
        if structure?.kind == .for && structure?.phase == .do && ch != uLF && ch != uHash && ch != uSemi {
            if ch != uLBrace || !matchSpaceContinuationAhead(src, at: index + 1) {
                return .opaque(.compoundCommand)
            }
            _ = state.structures.popLast()
        }
        let atStart = atCommandStart(state)
        if atStart && ch == uLParen {
            let fnHead = bashFunctionHeadLength(src, start: index)
            if fnHead > 0 { return .index(index + fnHead - 1) }
        }
        if atStart && ch == uBang && matchNegationAhead(src, at: index + 1) {
            return .index(index)
        }
        let forHeader = structure?.kind == .for && structure?.phase == .header
        if (atStart || forHeader) && (ch == uLParen || ch == uLBracket) {
            switch bashOperator(src, index: index, operators: ["((", "[["]) {
            case .opaque(let r): return .opaque(r)
            case .matched("(("):
                if forHeader && !state.words.isEmpty { return .opaque(.compoundCommand) }
                let span = forHeader ? spanForArithmetic : spanArithmetic
                switch scanBashArithmetic(src, start: index + 2, depth: depth, context: context, commands: &state.commands, span: span) {
                case .index(let end):
                    if bashCrossesHeredoc(state, start: index, end: end) { return .opaque(.heredoc) }
                    if !forHeader && context.dialect == .posix {
                        let subshells = scanBash(src, start: index + 1, depth: depth + 1, context: context, close: .rparen)
                        switch subshells {
                        case .opaque(let r): return .opaque(r)
                        case .scanned(let subCmds, let subEnd):
                            if subEnd != end { return .opaque(.compoundCommand) }
                            var seen = Set(state.commands.map { bashCommandKey($0) })
                            for c in subCmds {
                                let k = bashCommandKey(c)
                                if seen.insert(k).inserted { state.commands.append(c) }
                            }
                        }
                    }
                    if forHeader {
                        structure?.phase = .do
                        structure?.sawIn = true
                    } else {
                        bashStatement(state)
                        state.compoundEnd = true
                    }
                    return .index(end)
                case .opaque(let r): return .opaque(r)
                case .none:
                    if forHeader { return .opaque(.invalidStructure) }
                }
            case .matched("[["):
                if atStart && matchSpaceContinuationAhead(src, at: index + 2) {
                    switch scanBashConditional(src, start: index + 2, depth: depth, context: context, commands: &state.commands) {
                    case .opaque(let r): return .opaque(r)
                    case .index(let end):
                        if bashCrossesHeredoc(state, start: index, end: end) { return .opaque(.heredoc) }
                        bashStatement(state)
                        state.compoundEnd = true
                        return .index(end)
                    case .none: break
                    }
                }
            default: break
            }
        }
        if atStart && (ch == uLParen || (ch == uLBrace && matchSpaceContinuationAhead(src, at: index + 1))) {
            let group = scanBash(
                src, start: index + 1, depth: depth + 1, context: context,
                close: ch == uLBrace ? .rbrace : .rparen, sharedHeredocs: state.heredocs
            )
            switch group {
            case .opaque(let r): return .opaque(r)
            case .scanned(let cmds, let end):
                if src.slice(index + 1, end).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return .opaque(.invalidStructure)
                }
                state.commands.append(contentsOf: cmds)
                bashStatement(state)
                state.compoundEnd = true
                return .index(end)
            }
        }
        return .none
    }

    private static func bashCommandKey(_ c: CoreShell.Scan.Command) -> String {
        "\(c.resource)\u{00}\(c.words.joined(separator: "\u{01}"))"
    }

    private static func scanBashKeyword(
        _ state: BashState,
        index: Int,
        depth: Int,
        context: BashContext
    ) -> StepOutcome {
        let src = state.src
        let ch = src.units[index]
        guard isIdentStart(ch) else { return .none }
        let structure = state.structures.last
        let token = matchToken(src, at: index)
        let end = index + (token?.utf16.count ?? 0) - 1

        if structure?.kind == .case && structure?.phase == .header && token == "in" {
            if state.words.count != 1 || state.hasRedirect { return .opaque(.compoundCommand) }
            finishBashCommand(state)
            structure?.phase = .pattern
            structure?.patternStarted = false
            return .index(end)
        }
        if structure?.kind == .for &&
            (structure?.phase == .header || structure?.phase == .do) &&
            structure?.sawIn == false &&
            structure?.parenthesized == false &&
            token == "in" &&
            (structure?.phase == .do || !state.words.isEmpty)
        {
            structure?.sawIn = true
            structure?.phase = .header
            return .index(end)
        }
        if structure?.phase == .pattern && structure?.patternStarted == false && state.words.isEmpty && token == "esac" {
            _ = state.structures.popLast()
            bashStatement(state)
            state.compoundEnd = true
            return .index(end)
        }
        if structure?.kind == .for && structure?.phase == .header && structure?.sawIn == false &&
            state.words.count == 1 && !state.hasRedirect && token == "do"
        {
            finishBashCommand(state)
            structure?.phase = .do
        }
        let inHeader = bashInHeader(state)
        let closingKeywords: Set<String> = ["then", "elif", "else", "fi", "do", "done", "esac"]
        if let tok = token, closingKeywords.contains(tok),
           state.words.isEmpty && !state.redirectTarget &&
           (!inHeader || (tok == "do" && structure?.phase == .do))
        {
            if (state.hasRedirect && context.dialect != .zsh) || !endBashList(state) || structure == nil {
                return .opaque(.compoundCommand)
            }
            let st = structure!
            if tok == "then" {
                if st.kind != .if || st.phase != .condition || st.count == 0 { return .opaque(.compoundCommand) }
                st.phase = .body
                st.count = 0
                return .index(end)
            }
            if tok == "elif" || tok == "else" {
                if st.kind != .if || st.phase != .body || st.count == 0 || st.sawElse { return .opaque(.compoundCommand) }
                st.phase = tok == "elif" ? .condition : .body
                st.sawElse = tok == "else"
                st.count = 0
                return .index(end)
            }
            if tok == "do" {
                let loopKinds: [BashStructure.Kind] = [.for, .while, .until, .repeat]
                if !loopKinds.contains(st.kind) ||
                    !(st.phase == .condition || st.phase == .do) ||
                    (st.kind != .for && st.kind != .repeat && st.count == 0)
                {
                    return .opaque(.compoundCommand)
                }
                st.phase = .body
                st.count = 0
                return .index(end)
            }
            let loopKinds: [BashStructure.Kind] = [.for, .while, .until, .repeat]
            if (tok == "fi" && (st.kind != .if || st.phase != .body || st.count == 0)) ||
                (tok == "done" && (!loopKinds.contains(st.kind) || st.phase != .body || st.count == 0)) ||
                (tok == "esac" && (st.kind != .case || st.phase == .header))
            {
                return .opaque(.compoundCommand)
            }
            _ = state.structures.popLast()
            bashStatement(state)
            state.compoundEnd = true
            return .index(end)
        }

        if !atCommandStart(state) { return .none }
        let defLen = bashFunctionHeadLength(src, start: index)
        if defLen > 0 { return .index(index + defLen - 1) }

        if let tok = token {
            let kindAndPhase: (BashStructure.Kind, BashStructure.Phase)?
            switch tok {
            case "if": kindAndPhase = (.if, .condition)
            case "while": kindAndPhase = (.while, .condition)
            case "until": kindAndPhase = (.until, .condition)
            case "for", "select": kindAndPhase = (.for, .header)
            case "case": kindAndPhase = (.case, .header)
            case "repeat" where context.dialect != .bash: kindAndPhase = (.repeat, .header)
            default: kindAndPhase = nil
            }
            if let (k, p) = kindAndPhase {
                if depth + state.structures.count >= maxSubstitutionDepth { return .opaque(.compoundCommand) }
                state.structures.append(BashStructure(kind: k, phase: p))
                state.dangling = false
                return .index(end)
            }
            if tok == "coproc", let len = matchCoprocAhead(src, at: index) {
                return .index(index + len - 1)
            }
            if tok == "time", let len = matchTimeAhead(src, at: index) {
                return .index(index + len - 1)
            }
        }
        return .none
    }

    private enum OpMatch {
        case matched(String)
        case opaque(CoreShell.Scan.OpaqueReason)
        case none
    }

    private static func bashOperator(_ src: UTF16Source, index: Int, operators: [String]) -> OpMatch {
        var chars: [UInt16] = []
        var cursor = index
        while chars.count < 3 && cursor < src.count {
            if src.unit(at: cursor) == uBackslash && src.unit(at: cursor + 1) == uLF {
                cursor += 2
            } else {
                chars.append(src.units[cursor])
                cursor += 1
            }
        }
        let text = String(decoding: chars, as: UTF16.self)
        guard let op = operators.first(where: { text.hasPrefix($0) }) else { return .none }
        if !src.startsWith(op, at: index) { return .opaque(.invalidStructure) }
        return .matched(op)
    }

    private static func scanBashUnit(
        _ src: UTF16Source,
        index: Int,
        depth: Int,
        context: BashContext,
        commands: inout [CoreShell.Scan.Command],
        mode: BashTextMode,
        allowBracket: Bool,
        text: BashText?
    ) -> StepOutcome {
        let ch = src.units[index]
        let next = src.unitOrZero(at: index + 1)
        if ch == uBackslash {
            if mode == .quoted &&
                !(next == uDollar || next == uBacktick || next == uDoubleQuote || next == uBackslash || next == uLF)
            {
                return .none
            }
            if let text, next != uLF {
                bashAppend(text, src.slice(index + 1, index + 2))
            }
            return .index(index + 1)
        }
        if ch == uDollar && context.dialect != .bash && zshEvaluates(src, at: index) {
            return .opaque(.dynamicExecution)
        }
        if ch == uDollar && context.dialect != .bash && (mode == .word || mode == .quoted),
           let bracket = matchZshSubscriptEnd(src, at: index)
        {
            let subscriptText = BashText()
            let span = mode == .quoted ? spanQuotedSubscript : spanSubscript
            switch scanBashSubscript(src, start: bracket, depth: depth, context: context, commands: &commands, span: span, text: subscriptText) {
            case .opaque(let r): return .opaque(r)
            case .index(let end):
                if let text { text.word += "\(src.slice(index, bracket))\(subscriptText.word)]" }
                return .index(end)
            case .none: break
            }
        }

        let opener: String?
        if ch == uDollar {
            switch bashOperator(src, index: index, operators: ["$$", "$((", "$(", "${", "$[", "$'", "$\""]) {
            case .opaque(let r): return .opaque(r)
            case .matched(let op): opener = op
            case .none: opener = nil
            }
        } else if mode == .word && (ch == uLT || ch == uGT) {
            let candidate = ch == uLT ? "<(" : ">("
            switch bashOperator(src, index: index, operators: [candidate]) {
            case .opaque(let r): return .opaque(r)
            case .matched(let op): opener = op
            case .none: opener = nil
            }
        } else {
            opener = nil
        }

        if opener == "$$" {
            let quoteStart = skipLineContinuations(src, from: index + 2)
            if src.unit(at: quoteStart) == uSingleQuote {
                guard let nextQuote = src.indexOf(uSingleQuote, from: quoteStart + 1) else {
                    return .opaque(.unterminatedQuote)
                }
                if src.slice(quoteStart + 1, nextQuote).contains("\\") &&
                    src.indexOf(uSingleQuote, from: nextQuote + 1) != nil
                {
                    return .opaque(.unterminatedQuote)
                }
            }
            if let text { text.word += "$$" }
            return .index(index + 1)
        }

        if mode == .word && opener == "$'" {
            switch bashAnsiQuote(src, start: index + 1, dialect: context.dialect) {
            case .opaque(let r): return .opaque(r)
            case .ok(let value, let end):
                let firstQuote = src.indexOf(uSingleQuote, from: index + 2) ?? -1
                if end != firstQuote {
                    let cond1 = context.dialect != .bash && index >= 2 && src.unit(at: index - 2) == uDollar
                    var cond2 = false
                    if context.dialect == .posix && firstQuote >= 0 {
                        let secondQ = src.indexOf(uSingleQuote, from: firstQuote + 1)
                        if let sq = secondQ, sq < end { cond2 = true }
                        else {
                            let tail = src.slice(from: firstQuote + 1)
                            if tail.contains("#") || tail.contains("\"") || tail.contains("\n") || tail.contains("\\'") {
                                cond2 = true
                            }
                        }
                    }
                    if cond1 || cond2 { return .opaque(.unterminatedQuote) }
                }
                if let text { bashAppend(text, value) }
                return .index(end)
            }
        }

        if mode == .arithmetic && opener == "$'" {
            switch bashAnsiQuote(src, start: index + 1, dialect: context.dialect) {
            case .opaque: return .opaque(.invalidStructure)
            case .ok(let value, let end):
                if end != (src.indexOf(uSingleQuote, from: index + 2) ?? -1) ||
                    value.contains(where: { "()[];\"}".contains($0) })
                {
                    return .opaque(.invalidStructure)
                }
                if let text { bashAppend(text, value) }
                return scanBashSpan(
                    src, start: index + 2, depth: depth, context: context,
                    commands: &commands, span: spanArithmeticQuote, allowBracket: allowBracket, text: text
                )
            }
        }

        if mode == .word && ch == uSingleQuote {
            guard let end = src.indexOf(uSingleQuote, from: index + 1) else {
                return .opaque(.unterminatedQuote)
            }
            if let text { bashAppend(text, src.slice(index + 1, end)) }
            return .index(end)
        }

        if mode == .arithmetic && ch == uSingleQuote {
            return scanBashSpan(
                src, start: index + 1, depth: depth, context: context,
                commands: &commands, span: spanArithmeticQuote, allowBracket: allowBracket, text: text
            )
        }

        if mode == .word && opener == "$\"" {
            return scanBashSpan(
                src, start: index + 2, depth: depth, context: context,
                commands: &commands, span: spanDouble, allowBracket: allowBracket, text: text
            )
        }

        if mode != .quoted && ch == uDoubleQuote {
            let span = mode == .arithmetic ? spanArithmeticDouble : spanDouble
            return scanBashSpan(
                src, start: index + 1, depth: depth, context: context,
                commands: &commands, span: span, allowBracket: allowBracket, text: text
            )
        }

        var outcome: StepOutcome = .none
        if opener == "<(" || opener == ">(" {
            outcome = scanBashNested(src, start: index + 2, depth: depth, context: context, commands: &commands, close: .rparen)
        } else if (opener != nil && opener != "$'" && opener != "$\"") || ch == uBacktick {
            outcome = scanBashDollarOrBacktick(
                src, start: index, depth: depth, context: context,
                commands: &commands, quoted: mode != .word, allowBracket: allowBracket, text: text
            )
        }
        switch outcome {
        case .opaque(let r): return .opaque(r)
        case .index(let end):
            if let text { text.word += src.slice(index, end + 1) }
            return .index(end)
        case .none:
            if ch == uDollar &&
                (isIdentCont(next) || next == uAt || next == uStar || next == uHash ||
                    next == uQMark || next == uDollar || next == uBang || next == uMinus)
            {
                if let text { text.word += "$" }
                return .index(index)
            }
            return .none
        }
    }

    private static func scanBashSubscript(
        _ src: UTF16Source,
        start: Int,
        depth: Int,
        context: BashContext,
        commands: inout [CoreShell.Scan.Command],
        span: BashSpan = spanSubscript,
        text: BashText = BashText()
    ) -> StepOutcome {
        let res = scanBashSpan(src, start: start, depth: depth, context: context, commands: &commands, span: span, allowBracket: false, text: text)
        if case .index(let end) = res {
            context.sinkBracket = true
            if bashEvaluatesExpansion(text, evaluation: .arithmetic, context: context) {
                return .opaque(.dynamicExecution)
            }
            return .index(end)
        }
        return res
    }

    private static func scanBashSpan(
        _ src: UTF16Source,
        start: Int,
        depth: Int,
        context: BashContext,
        commands: inout [CoreShell.Scan.Command],
        span: BashSpan,
        allowBracket: Bool,
        text: BashText?
    ) -> StepOutcome {
        var nesting = 0
        var index = start
        while index < src.count {
            context.remaining -= 1
            if context.remaining < 0 { return .opaque(.invalidStructure) }
            let ch = src.units[index]
            if let close = span.close, ch == close && nesting == 0 {
                return .index(index)
            }
            if span.reject.contains(ch) {
                let prev = src.unitOrZero(at: index - 1)
                if !(ch == uHash && (isASCIIDigit(prev) || prev == uDollar)) {
                    return .opaque(.invalidStructure)
                }
            }
            if let open = span.open, ch == open {
                nesting += 1
                if nesting + depth > maxSubstitutionDepth { return .opaque(.invalidStructure) }
            }
            if let close = span.close, ch == close {
                nesting -= 1
            }
            let unit: StepOutcome
            if ch == span.open || ch == span.close {
                unit = .none
            } else {
                unit = scanBashUnit(
                    src, index: index, depth: depth, context: context,
                    commands: &commands, mode: span.mode, allowBracket: allowBracket, text: text
                )
            }
            switch unit {
            case .opaque(let r): return .opaque(r)
            case .index(let end):
                index = end + 1
            case .none:
                if ch == uBackslash, let next = src.unit(at: index + 1), (next == span.open || next == span.close) {
                    if let text { bashAppend(text, src.slice(index, index + 2)) }
                    index += 2
                } else {
                    if let text { bashAppend(text, src.slice(index, index + 1)) }
                    index += 1
                }
            }
        }
        return span.close != nil ? .opaque(.unterminatedQuote) : .index(src.count)
    }

    private static func scanBashNested(
        _ src: UTF16Source,
        start: Int,
        depth: Int,
        context: BashContext,
        commands: inout [CoreShell.Scan.Command],
        close: CloseMode,
        text: BashText? = nil
    ) -> StepOutcome {
        let nested = scanBash(src, start: start, depth: depth + 1, context: context, close: close, sharedHeredocs: nil, outer: text)
        switch nested {
        case .opaque(let r): return .opaque(r)
        case .scanned(let cmds, let end):
            commands.append(contentsOf: cmds)
            return .index(end)
        }
    }

    private static func scanBashDollarOrBacktick(
        _ src: UTF16Source,
        start: Int,
        depth: Int,
        context: BashContext,
        commands: inout [CoreShell.Scan.Command],
        quoted: Bool,
        allowBracket: Bool,
        text: BashText?
    ) -> StepOutcome {
        if depth >= maxSubstitutionDepth { return .opaque(.commandSubstitution) }
        if src.units[start] == uBacktick {
            context.sawCommandSubstitution = true
            return scanBashBacktick(src, start: start, depth: depth + 1, context: context, commands: &commands, quoted: quoted, text: text)
        }
        if src.startsWith("$((", at: start) {
            switch scanBashArithmetic(src, start: start + 3, depth: depth + 1, context: context, commands: &commands, span: spanArithmetic) {
            case .opaque(let r): return .opaque(r)
            case .index(let end): return .index(end)
            case .none: break
            }
        }
        if src.startsWith("$(", at: start) {
            context.sawCommandSubstitution = true
            return scanBashNested(src, start: start + 2, depth: depth, context: context, commands: &commands, close: .rparen, text: text)
        }
        if let noforkLen = matchNoforkOpen(src, at: start) {
            context.sawCommandSubstitution = true
            return scanBashNested(src, start: start + noforkLen, depth: depth, context: context, commands: &commands, close: .nofork, text: text)
        }
        if src.startsWith("${", at: start) {
            let parameter = BashText()
            let res = scanBashParameter(src, start: start + 2, depth: depth + 1, context: context, commands: &commands, quoted: quoted, text: parameter)
            if case .opaque = res { return res }
            let afterCont = skipLineContinuations(src, from: start + 2)
            var indirect = src.unit(at: afterCont) == uBang
            if !indirect && context.dialect != .bash && src.unit(at: start + 2) == uLParen,
               let flagsEnd = matchZshSafeFlagsEnd(src, at: start),
               zshSafeFlagsHasP(src, start: start, endExclusive: flagsEnd)
            {
                indirect = true
            }
            if indirect {
                context.variableSink = true
                if bashEvaluatesExpansion(parameter, evaluation: .binding, context: context) {
                    return .opaque(.dynamicExecution)
                }
            }
            if let text {
                text.literal += parameter.literal
                text.output += parameter.output
            }
            return res
        }
        if !allowBracket && context.dialect == .posix {
            return .opaque(.commandSubstitution)
        }
        let expression = BashText()
        let res = scanBashSpan(
            src, start: start + 2, depth: depth + 1, context: context,
            commands: &commands, span: spanBracketArithmetic, allowBracket: true, text: expression
        )
        if case .index(let end) = res {
            if bashEvaluatesExpansion(expression, evaluation: .arithmetic, context: context) {
                return .opaque(.dynamicExecution)
            }
            return .index(end)
        }
        return res
    }

    private static func scanBashArithmetic(
        _ src: UTF16Source,
        start: Int,
        depth: Int,
        context: BashContext,
        commands: inout [CoreShell.Scan.Command],
        span: BashSpan
    ) -> StepOutcome {
        var arithmetic: [CoreShell.Scan.Command] = []
        let text = BashText()
        let end: Int
        switch scanBashSpan(src, start: start, depth: depth, context: context, commands: &arithmetic, span: span, allowBracket: true, text: text) {
        case .opaque: return .opaque(.invalidStructure)
        case .index(let e): end = e
        case .none: return .opaque(.invalidStructure)
        }
        switch bashOperator(src, index: end, operators: ["))"]) {
        case .opaque(let r): return .opaque(r)
        case .none: return .none
        case .matched:
            if bashEvaluatesExpansion(text, evaluation: .arithmetic, context: context) {
                return .opaque(.dynamicExecution)
            }
            commands.append(contentsOf: arithmetic)
            return .index(end + 1)
        }
    }

    private static func scanBashBacktick(
        _ src: UTF16Source,
        start: Int,
        depth: Int,
        context: BashContext,
        commands: inout [CoreShell.Scan.Command],
        quoted: Bool,
        text: BashText?
    ) -> StepOutcome {
        var source = ""
        var index = start + 1
        while index < src.count {
            context.remaining -= 1
            if context.remaining < 0 { return .opaque(.invalidStructure) }
            if src.units[index] == uBacktick {
                let inner = scanBash(UTF16Source(source), start: 0, depth: depth, context: context, close: nil, sharedHeredocs: nil, outer: text)
                switch inner {
                case .opaque: return .opaque(.commandSubstitution)
                case .scanned(let cmds, _):
                    commands.append(contentsOf: cmds)
                    return .index(index)
                }
            }
            let next = src.unitOrZero(at: index + 1)
            if src.units[index] == uBackslash &&
                (next == uDollar || next == uBacktick || next == uBackslash || next == uLF || (quoted && next == uDoubleQuote))
            {
                if next != uLF { source += src.slice(index + 1, index + 2) }
                index += 2
                continue
            }
            source += src.slice(index, index + 1)
            index += 1
        }
        return .opaque(.commandSubstitution)
    }

    private static func scanBashParameter(
        _ src: UTF16Source,
        start: Int,
        depth: Int,
        context: BashContext,
        commands: inout [CoreShell.Scan.Command],
        quoted: Bool,
        text: BashText
    ) -> StepOutcome {
        let nameStart = matchParameterPrefixEnd(src, at: start)
        var colon = matchParameterNameEnd(src, at: nameStart) ?? -1
        let rawName = colon > nameStart ? src.slice(nameStart, colon).replacingOccurrences(of: "\\\n", with: "") : ""
        if context.dialect != .bash {
            let isNullCmd = rawName == "NULLCMD" || rawName == "READNULLCMD"
            let isZshSpecial = rawName == "functions" || rawName == "dis_functions" ||
                rawName == "aliases" || rawName == "galiases" || rawName == "saliases" ||
                rawName == "dis_aliases" || rawName == "dis_galiases" || rawName == "dis_saliases" ||
                rawName == "options" || rawName == "commands"
            let colonCh = colon >= 0 ? src.unitOrZero(at: colon) : 0
            if isNullCmd || (isZshSpecial && (colonCh == uLBracket || colonCh == uEq || colonCh == uColon)) {
                return .opaque(.dynamicExecution)
            }
        }
        if rawName == "PS4" { context.evalSink = true }
        var evaluation: BashEvaluation?
        var wordOffset = 0
        var literalOffset = 0
        var index = start
        while index < src.count {
            context.remaining -= 1
            if context.remaining < 0 { return .opaque(.invalidStructure) }
            let ch = src.units[index]
            if ch == uRBrace {
                if let evaluation {
                    let subText = BashText()
                    subText.word = String(decoding: Array(text.word.utf16)[min(wordOffset, text.word.utf16.count)...], as: UTF16.self)
                    subText.literal = String(decoding: Array(text.literal.utf16)[min(literalOffset, text.literal.utf16.count)...], as: UTF16.self)
                    subText.output = text.output
                    if bashEvaluatesExpansion(subText, evaluation: evaluation, context: context) {
                        return .opaque(.dynamicExecution)
                    }
                }
                return .index(index)
            }
            if index == colon && evaluation == nil {
                let nextCh = src.unitOrZero(at: index + 1)
                if ch == uColon && !(nextCh == uMinus || nextCh == uEq || nextCh == uQMark || nextCh == uPlus) {
                    evaluation = .arithmetic
                }
                if ch == uEq || (ch == uColon && nextCh == uEq) {
                    evaluation = .deferred
                }
                if evaluation != nil {
                    wordOffset = text.word.utf16.count
                    literalOffset = text.literal.utf16.count
                }
            }
            if ch == uAt && matchParameterPrompt(src, at: index) {
                return .opaque(.dynamicExecution)
            }
            if !quoted && context.dialect != .bash && ch == uLParen && index > start {
                return .opaque(.dynamicExecution)
            }
            if quoted && ch == uSingleQuote && src.unit(at: index - 1) == uDollar {
                switch bashAnsiQuote(src, start: index, dialect: context.dialect) {
                case .opaque(let r): return .opaque(r)
                case .ok(let value, _): text.literal += value
                }
            }
            let isSubscript = index == colon && ch == uLBracket
            let unit: StepOutcome
            if isSubscript {
                unit = scanBashSubscript(src, start: index + 1, depth: depth, context: context, commands: &commands)
            } else if quoted && ch == uSingleQuote {
                unit = scanBashSpan(src, start: index + 1, depth: depth, context: context, commands: &commands, span: spanParameterQuote, allowBracket: false, text: text)
            } else if quoted && ch == uDoubleQuote {
                unit = scanBashSpan(src, start: index + 1, depth: depth, context: context, commands: &commands, span: spanDouble, allowBracket: false, text: text)
            } else {
                unit = scanBashUnit(src, index: index, depth: depth, context: context, commands: &commands, mode: quoted ? .quoted : .word, allowBracket: false, text: text)
            }
            switch unit {
            case .opaque(let r): return .opaque(r)
            case .index(let unitEnd):
                if quoted && src.startsWith("$(", at: index) && src.slice(index, unitEnd + 1).contains("}") {
                    return .opaque(.commandSubstitution)
                }
                if isSubscript || (index == nameStart && src.startsWith("${", at: index)) {
                    colon = skipLineContinuations(src, from: unitEnd + 1)
                }
                index = unitEnd + 1
            case .none:
                bashAppend(text, src.slice(index, index + 1))
                index += 1
            }
        }
        return .opaque(.commandSubstitution)
    }

    private static func scanBashConditional(
        _ src: UTF16Source,
        start: Int,
        depth: Int,
        context: BashContext,
        commands: inout [CoreShell.Scan.Command]
    ) -> StepOutcome {
        var words: [BashText] = []
        var text = BashText()
        var wordStarted = false
        var hasWord = false
        var parenDepth = 0
        var patternParenDepth = 0

        func flushWord() {
            guard hasWord else { return }
            words.append(text)
            text = BashText()
            hasWord = false
        }

        var index = start
        while index < src.count {
            context.remaining -= 1
            if context.remaining < 0 { return .opaque(.invalidStructure) }
            let ch = src.units[index]
            if ch == uBackslash && src.unit(at: index + 1) == uLF {
                index += 2
                continue
            }
            if !wordStarted { flushWord() }
            if !wordStarted && ch == uRBracket {
                switch bashOperator(src, index: index, operators: ["]]"]) {
                case .opaque(let r): return .opaque(r)
                case .matched:
                    if matchBraceCloseAhead(src, at: index + 2) {
                        if parenDepth != 0 { return .opaque(.invalidStructure) }
                        for at in 0..<words.count {
                            let prevWord = at > 0 ? words[at - 1].word : ""
                            let nextWord = at + 1 < words.count ? words[at + 1].word : ""
                            if prevWord == "-v" && bashEvaluatesExpansion(words[at], evaluation: .binding, context: context) {
                                return .opaque(.dynamicExecution)
                            }
                            if ((context.dialect != .bash && prevWord == "-t") ||
                                bashArithmeticComparisons.contains(prevWord) ||
                                bashArithmeticComparisons.contains(nextWord)) &&
                                bashEvaluatesExpansion(words[at], evaluation: .arithmetic, context: context)
                            {
                                return .opaque(.dynamicExecution)
                            }
                        }
                        return .index(index + 1)
                    }
                case .none: break
                }
            }
            if !wordStarted && ch == uHash {
                guard let nl = src.indexOf(uLF, from: index) else { return .opaque(.invalidStructure) }
                index = nl + 1
                continue
            }
            if ch == uSpace || ch == uTab || ch == uLF {
                if patternParenDepth == 0 { wordStarted = false }
                index += 1
                continue
            }
            if ch == uSemi { return .opaque(.invalidStructure) }
            if ch == uLParen || ch == uRParen {
                if ch == uRParen && parenDepth == 0 { return .opaque(.invalidStructure) }
                let prevW = words.last?.word ?? ""
                let inPattern = patternParenDepth > 0 ||
                    (ch == uLParen && (prevW == "=" || prevW == "==" || prevW == "!=" || prevW == "=~"))
                parenDepth += ch == uLParen ? 1 : -1
                if inPattern {
                    patternParenDepth += ch == uLParen ? 1 : -1
                    wordStarted = true
                    hasWord = true
                    bashAppend(text, src.slice(index, index + 1))
                    index += 1
                    continue
                }
                flushWord()
                let t = BashText()
                t.word = src.slice(index, index + 1)
                words.append(t)
                wordStarted = false
                index += 1
                continue
            }
            let unit = scanBashUnit(src, index: index, depth: depth, context: context, commands: &commands, mode: .word, allowBracket: true, text: text)
            switch unit {
            case .opaque(let r): return .opaque(r)
            case .index(let end):
                wordStarted = true
                hasWord = true
                index = end + 1
            case .none:
                if patternParenDepth == 0 && (ch == uAmp || ch == uPipe || ch == uLT || ch == uGT) {
                    flushWord()
                    let t = BashText()
                    t.word = src.slice(index, index + 1)
                    words.append(t)
                    wordStarted = false
                    index += 1
                    continue
                }
                wordStarted = true
                hasWord = true
                bashAppend(text, src.slice(index, index + 1))
                index += 1
            }
        }
        return .opaque(.invalidStructure)
    }

    private static func scanBashArrayOrPattern(
        _ src: UTF16Source,
        start: Int,
        depth: Int,
        context: BashContext,
        commands: inout [CoreShell.Scan.Command],
        isArray: Bool
    ) -> StepOutcome {
        if depth > maxSubstitutionDepth { return .opaque(.commandSubstitution) }
        let text: BashText? = isArray ? BashText() : nil
        var wordStarted = false
        var index = start + 1
        while index < src.count {
            context.remaining -= 1
            if context.remaining < 0 { return .opaque(.invalidStructure) }
            let ch = src.units[index]
            if ch == uBackslash && src.unit(at: index + 1) == uLF {
                index += 2
                continue
            }
            if let text, (ch == uRParen || ch == uSpace || ch == uTab || ch == uLF) {
                bashEvaluatesExpansion(text, evaluation: .deferred, context: context)
                text.literal = ""
                text.output = ""
            }
            if ch == uRParen { return .index(index) }
            if isArray && !wordStarted && ch == uHash {
                guard let nl = src.indexOf(uLF, from: index) else { return .opaque(.commandSubstitution) }
                index = nl + 1
                continue
            }
            if ch == uSpace || ch == uTab || (isArray && ch == uLF) {
                wordStarted = false
                index += 1
                continue
            }
            if isArray && wordStarted && ch == uLParen && context.dialect == .zsh,
               let qualEnd = matchZshGlobQualifierEnd(src, at: index)
            {
                if let text { text.literal += src.slice(index, qualEnd) }
                index = qualEnd
                continue
            }
            if ch == uLF || ch == uSemi || ch == uAmp || (isArray && (ch == uPipe || ch == uLParen)) {
                return .opaque(.commandSubstitution)
            }
            wordStarted = true
            let unit: StepOutcome
            if isArray && ch == uEq && src.unit(at: index + 1) == uLParen {
                unit = scanBashNested(src, start: index + 2, depth: depth, context: context, commands: &commands, close: .rparen)
            } else if ch == uLParen {
                unit = scanBashArrayOrPattern(src, start: index, depth: depth + 1, context: context, commands: &commands, isArray: isArray)
            } else if ch == uLBracket {
                unit = scanBashSubscript(src, start: index + 1, depth: depth, context: context, commands: &commands)
            } else {
                unit = scanBashUnit(src, index: index, depth: depth, context: context, commands: &commands, mode: .word, allowBracket: false, text: text)
            }
            switch unit {
            case .opaque(let r): return .opaque(r)
            case .index(let end): index = end + 1
            case .none:
                if let text { text.literal += src.slice(index, index + 1) }
                index += 1
            }
        }
        return .opaque(.commandSubstitution)
    }

    private enum AnsiQuoteResult {
        case ok(value: String, end: Int)
        case opaque(CoreShell.Scan.OpaqueReason)
    }

    private static func bashAnsiQuote(
        _ src: UTF16Source,
        start: Int,
        dialect: CoreShell.Scan.Dialect,
        allowUnicode: Bool = true
    ) -> AnsiQuoteResult {
        var value = ""
        var index = start + 1
        while index < src.count {
            let ch = src.units[index]
            if ch == uSingleQuote { return .ok(value: value, end: index) }
            if ch != uBackslash {
                value += src.slice(index, index + 1)
                index += 1
                continue
            }
            index += 1
            guard index < src.count else { break }
            let escaped = src.units[index]
            if let mapped = bashAnsiEscapes[escaped] {
                value += mapped
                index += 1
                continue
            }
            var digits: String?
            var isOctal = false
            if escaped == UInt16(ascii: "x") {
                var k = index + 1
                while k < min(src.count, index + 3), isASCIIHex(src.units[k]) { k += 1 }
                if k > index + 1 { digits = src.slice(index + 1, k) }
            } else if allowUnicode && escaped == UInt16(ascii: "u") {
                var k = index + 1
                while k < min(src.count, index + 5), isASCIIHex(src.units[k]) { k += 1 }
                if k > index + 1 { digits = src.slice(index + 1, k) }
            } else if allowUnicode && escaped == UInt16(ascii: "U") {
                var k = index + 1
                while k < min(src.count, index + 9), isASCIIHex(src.units[k]) { k += 1 }
                if k > index + 1 { digits = src.slice(index + 1, k) }
            } else if isASCIIOctal(escaped) {
                isOctal = true
                var k = index
                while k < min(src.count, index + 3), isASCIIOctal(src.units[k]) { k += 1 }
                digits = src.slice(index, k)
            }
            if let digits {
                let point = UInt32(digits, radix: isOctal ? 8 : 16) ?? 0
                if point == 0 || point > 0x10FFFF || (point >= 0xD800 && point <= 0xDFFF) {
                    return .opaque(.unsupportedEscape)
                }
                if let scalar = Unicode.Scalar(point) {
                    value.unicodeScalars.append(scalar)
                }
                index += digits.utf16.count + (isOctal ? 0 : 1)
                continue
            }
            let escIsC = escaped == UInt16(ascii: "c")
            let escIsU = escaped == UInt16(ascii: "u") || escaped == UInt16(ascii: "U")
            let escIsZshSpecial = escaped == UInt16(ascii: "C") || escaped == UInt16(ascii: "M") ||
                escaped == UInt16(ascii: "x") || escIsU
            if dialect == .posix || (dialect == .bash && (escIsC || (!allowUnicode && escIsU))) ||
                (dialect == .zsh && escIsZshSpecial)
            {
                return .opaque(.unsupportedEscape)
            }
            let escStr = src.slice(index, index + 1)
            value += dialect == .bash ? "\\\(escStr)" : escStr
            index += 1
        }
        return .opaque(.unterminatedQuote)
    }

    private static func bashHeredocDelimiter(
        _ src: UTF16Source,
        start: Int,
        tabs: Bool,
        dialect: CoreShell.Scan.Dialect
    ) -> (heredoc: BashHeredoc, end: Int)? {
        var delimiter = ""
        var dashDelimiter: String?
        var quoted = false
        var quote: UInt16?
        var end = start
        var started = false
        var index = start
        while index < src.count {
            let ch = src.units[index]
            if !started && (ch == uSpace || ch == uTab) { index += 1; continue }
            if !started && ch == uHash { return nil }
            if quote == nil &&
                (ch == uSpace || ch == uTab || ch == uLF || ch == uSemi || ch == uAmp ||
                    ch == uPipe || ch == uLParen || ch == uRParen || ch == uLT || ch == uGT)
            {
                return started
                    ? (BashHeredoc(delimiter: delimiter, dashDelimiter: dashDelimiter, quoted: quoted, tabs: tabs), end)
                    : nil
            }
            if quote == nil && ch == uDollar && src.startsWith("\\\n", at: index + 1) { return nil }
            if quote == nil && src.startsWith("$'", at: index) {
                switch bashAnsiQuote(src, start: index + 1, dialect: dialect, allowUnicode: false) {
                case .opaque: return nil
                case .ok(let val, let qEnd):
                    if qEnd != (src.indexOf(uSingleQuote, from: index + 2) ?? -1) { return nil }
                    dashDelimiter = "\(dashDelimiter ?? delimiter)$\(src.slice(index + 2, qEnd))"
                    delimiter += val
                    quoted = true
                    started = true
                    index = qEnd + 1
                    end = qEnd
                    continue
                }
            }
            if quote == nil && src.startsWith("$\"", at: index) { return nil }
            if let q = quote, ch == q {
                quote = nil
                end = index
                index += 1
                continue
            }
            if ch == uBackslash && quote != uSingleQuote {
                guard let next = src.unit(at: index + 1) else { return nil }
                if next == uLF { index += 2; continue }
                if quote == nil || next == uDollar || next == uBacktick || next == uDoubleQuote || next == uBackslash {
                    quoted = true
                    started = true
                    index += 1
                    let esc = src.slice(index, index + 1)
                    if dashDelimiter != nil { dashDelimiter! += esc }
                    delimiter += esc
                    end = index
                    index += 1
                    continue
                }
            }
            if quote == nil && (ch == uSingleQuote || ch == uDoubleQuote) {
                quote = ch
                quoted = true
                started = true
                end = index
                index += 1
                continue
            }
            let s = src.slice(index, index + 1)
            if dashDelimiter != nil { dashDelimiter! += s }
            delimiter += s
            started = true
            end = index
            index += 1
        }
        if started && quote == nil {
            return (BashHeredoc(delimiter: delimiter, dashDelimiter: dashDelimiter, quoted: quoted, tabs: tabs), end)
        }
        return nil
    }

    private static func bashHeredoc(
        _ src: UTF16Source,
        start initialStart: Int,
        heredoc: BashHeredoc
    ) -> (source: String, end: Int)? {
        let bodyStart = initialStart
        var start = initialStart
        var lineStart = initialStart
        var line = ""
        var backslashes = 0
        var index = start
        while index <= src.count {
            if index < src.count && src.units[index] != uLF {
                index += 1
                continue
            }
            var text = src.slice(start, index)
            if heredoc.tabs && start == lineStart {
                while text.hasPrefix("\t") { text.removeFirst() }
            }
            let textUnits = Array(text.utf16)
            var run = 0
            while run < textUnits.count && textUnits[textUnits.count - 1 - run] == uBackslash {
                run += 1
            }
            backslashes = run == textUnits.count ? backslashes + run : run
            let continued = !heredoc.quoted && backslashes % 2 == 1 && index < src.count
            let maxLen = max(heredoc.delimiter.utf16.count, heredoc.dashDelimiter?.utf16.count ?? 0)
            if line.utf16.count <= maxLen {
                line += continued ? String(decoding: textUnits.dropLast(), as: UTF16.self) : text
            }
            if continued {
                backslashes -= 1
                start = index + 1
                index += 1
                continue
            }
            if let dd = heredoc.dashDelimiter, line == dd { return nil }
            if line == heredoc.delimiter {
                if start > lineStart && src.slice(from: index + 1).contains(heredoc.delimiter) { return nil }
                return (src.slice(bodyStart, lineStart), index)
            }
            line = ""
            backslashes = 0
            start = index + 1
            lineStart = start
            index += 1
        }
        return nil
    }

    // MARK: - PowerShell Scanner

    private enum PowerShellClause: Equatable {
        case member, block, `if`, `try`, clause, `switch`, paren, `do`
    }

    private enum PowerShellAfter: Equatable {
        case `do`, `if`, `try`
    }

    private enum PowerShellHashMode: Equatable {
        case none, hash, clause, `switch`
    }

    private enum PowerShellIndexable: Equatable {
        case none, variable, closed, member
    }

    private static let psBlockKeywords: Set<String> = [
        "if", "for", "while", "do", "switch", "function", "filter", "workflow", "parallel",
        "sequence", "configuration", "try", "begin", "process", "end", "clean", "trap",
        "class", "enum", "data", "dynamicparam", "using", "break", "continue",
    ]

    private static func isPSDelimOrEnd(_ src: UTF16Source, at index: Int, extra: String = "") -> Bool {
        guard let u = src.unit(at: index) else { return true }
        if isJSWhitespace(u) { return true }
        return extra.utf16.contains(u)
    }

    // /--%(?=$|[\s;|&(){}])/y
    private static func matchPSStopParsing(_ src: UTF16Source, at index: Int) -> Bool {
        guard src.startsWith("--%", at: index) else { return false }
        return isPSDelimOrEnd(src, at: index + 3, extra: ";|&(){}")
    }

    // /^-[\p{L}\p{Nl}_?][\p{L}\p{Nl}\d_?-]*:$/u
    private static func isPSParameterColon(_ s: String) -> Bool {
        let src = UTF16Source(s)
        guard src.count >= 3, src.unit(at: 0) == uMinus, src.unit(at: src.count - 1) == uColon else { return false }
        guard let (firstSc, firstLen) = src.scalarAndLength(at: 1),
              (isUnicodeLetterOrNl(firstSc) || firstSc.value == 0x5F || firstSc.value == 0x3F) else { return false }
        var i = 1 + firstLen
        while i < src.count - 1 {
            if src.unit(at: i) == uMinus { i += 1; continue }
            guard let len = isPSIdentOrQMark(src, at: i) else { return false }
            i += len
        }
        return true
    }

    // /\d>&/y
    private static func matchPSMergeRedirect(_ src: UTF16Source, at index: Int) -> Bool {
        guard let u = src.unit(at: index), isASCIIDigit(u) else { return false }
        return src.unit(at: index + 1) == uGT && src.unit(at: index + 2) == uAmp
    }

    // /:[A-Za-z_]\w*(?=\s*(?:while|for|foreach|do|switch)(?=$|[\s&(),;{|}]))/iy
    private static func matchPSLabelLength(_ src: UTF16Source, at index: Int) -> Int? {
        guard src.unit(at: index) == uColon,
              let first = src.unit(at: index + 1), isIdentStart(first) else { return nil }
        var i = index + 2
        while let u = src.unit(at: i), isIdentCont(u) { i += 1 }
        let labelEnd = i
        while let u = src.unit(at: i), isJSWhitespace(u) { i += 1 }
        let rest = src.slice(i, min(src.count, i + 8)).lowercased()
        for kw in ["foreach", "switch", "while", "for", "do"] {
            if rest.hasPrefix(kw) && isPSDelimOrEnd(src, at: i + kw.utf16.count, extra: "&(),;{|}") {
                return labelEnd - index
            }
        }
        return nil
    }

    // /[A-Za-z]+(?=$|[\s&(),;{|}])/y
    private static func matchPSKeyword(_ src: UTF16Source, at index: Int) -> String? {
        guard let first = src.unit(at: index), isASCIIAlpha(first) else { return nil }
        var i = index + 1
        while let u = src.unit(at: i), isASCIIAlpha(u) { i += 1 }
        guard isPSDelimOrEnd(src, at: i, extra: "&(),;{|}") else { return nil }
        return src.slice(index, i).lowercased()
    }

    private static func matchPSWordFollowedByParen(_ src: UTF16Source, at index: Int, word: String) -> Bool {
        let len = word.utf16.count
        guard src.slice(index, index + len).lowercased() == word else { return false }
        var i = index + len
        while let u = src.unit(at: i), isJSWhitespace(u) { i += 1 }
        return src.unit(at: i) == uLParen
    }

    private static func matchPSIn(_ src: UTF16Source, at index: Int) -> Bool {
        guard src.slice(index, index + 2).lowercased() == "in" else { return false }
        return isPSDelimOrEnd(src, at: index + 2, extra: "&(),;{|}")
    }

    // /[({'"\p{L}\p{Nl}\d_?]/uy
    private static func matchPSAtOpener(_ src: UTF16Source, at index: Int) -> Bool {
        guard let u = src.unit(at: index) else { return false }
        if u == uLParen || u == uLBrace || u == uSingleQuote || u == uDoubleQuote || u == uQMark { return true }
        return isPSIdentChar(src, at: index) != nil
    }

    // /(?::[\p{L}\p{Nl}\d_?]+|[\p{L}\p{Nl}\d_][\p{L}\p{Nl}\d_?]*)/uy
    private static func matchPSIndexableVar(_ src: UTF16Source, at index: Int) -> Bool {
        if src.unit(at: index) == uColon {
            return isPSIdentOrQMark(src, at: index + 1) != nil
        }
        return isPSIdentChar(src, at: index) != nil
    }

    // /@['"][^\S\r\n]*(?:\r\n|\r|\n)/y
    private static func matchPSHereHeaderLength(_ src: UTF16Source, at index: Int) -> Int? {
        guard src.unit(at: index) == uAt,
              let q = src.unit(at: index + 1), (q == uSingleQuote || q == uDoubleQuote) else { return nil }
        var i = index + 2
        while let u = src.unit(at: i), isJSWhitespace(u) && u != uCR && u != uLF { i += 1 }
        if src.unit(at: i) == uCR {
            return (src.unit(at: i + 1) == uLF ? i + 2 : i + 1) - index
        }
        if src.unit(at: i) == uLF {
            return (i + 1) - index
        }
        return nil
    }

    // POWERSHELL_EXPRESSION_RE
    private static func matchPSExpression(_ src: UTF16Source, at index: Int) -> Bool {
        guard let u = src.unit(at: index) else { return false }
        // Case 1: !*(?:++|--|[+-])?$(...)
        var i = index
        while src.unit(at: i) == uBang { i += 1 }
        var j = i
        if (src.unit(at: j) == uPlus && src.unit(at: j + 1) == uPlus) ||
            (src.unit(at: j) == uMinus && src.unit(at: j + 1) == uMinus)
        {
            j += 2
        } else if src.unit(at: j) == uPlus || src.unit(at: j) == uMinus {
            j += 1
        }
        if src.unit(at: j) == uDollar {
            let afterD = j + 1
            if let next = src.unit(at: afterD) {
                if next == uLBrace { return true }
                if (next == uQMark || next == uDollar || next == uCaret) &&
                    isPSDelimOrEnd(src, at: afterD + 1, extra: ";|&(){},#>")
                {
                    return true
                }
                if next == uColon && isPSIdentOrQMark(src, at: afterD + 1) != nil { return true }
                if let len = isPSIdentChar(src, at: afterD) {
                    _ = len
                    return true
                }
            }
        }
        // Case 2: !(?![\p{L}\p{Nl}_.\d])
        if u == uBang {
            let next = src.unit(at: index + 1)
            if next != uDot && isPSIdentChar(src, at: index + 1) == nil { return true }
        }
        // Case 3: +(?![=\p{L}\p{Nl}_.\d])
        if u == uPlus {
            let next = src.unit(at: index + 1)
            if next != uEq && next != uDot && isPSIdentChar(src, at: index + 1) == nil { return true }
        }
        // Case 4: --(?!=)
        if u == uMinus && src.unit(at: index + 1) == uMinus && src.unit(at: index + 2) != uEq {
            return true
        }
        // Case 5: -(?![=\p{L}\p{Nl}\d_?.])
        if u == uMinus {
            let next = src.unit(at: index + 1)
            if next != uEq && next != uDot && isPSIdentOrQMark(src, at: index + 1) == nil { return true }
        }
        // Case 6: ,(?!\s*$)
        if u == uComma {
            var k = index + 1
            while let ws = src.unit(at: k), isJSWhitespace(ws) { k += 1 }
            if k < src.count { return true }
        }
        // Case 7: numeric literal !*[+-]?(?:0x...|0b...|digits...)(?:suffix)?(?:kb/mb/...)?(?=$|delim)
        var n = i // already skipped !*
        if src.unit(at: n) == uPlus || src.unit(at: n) == uMinus { n += 1 }
        var numEnd: Int?
        if src.unit(at: n) == UInt16(ascii: "0"),
           let kind = src.unit(at: n + 1),
           (kind == UInt16(ascii: "x") || kind == UInt16(ascii: "X"))
        {
            var k = n + 2
            while let h = src.unit(at: k), isASCIIHex(h) { k += 1 }
            if k > n + 2 { numEnd = k }
        } else if src.unit(at: n) == UInt16(ascii: "0"),
                  let kind = src.unit(at: n + 1),
                  (kind == UInt16(ascii: "b") || kind == UInt16(ascii: "B"))
        {
            var k = n + 2
            while let b = src.unit(at: k), (b == UInt16(ascii: "0") || b == UInt16(ascii: "1")) { k += 1 }
            if k > n + 2 { numEnd = k }
        } else if let d0 = src.unit(at: n), isASCIIDigit(d0) {
            var k = n + 1
            while let d = src.unit(at: k), isASCIIDigit(d) { k += 1 }
            if src.unit(at: k) == uDot && src.unit(at: k + 1) != uDot {
                k += 1
                while let d = src.unit(at: k), isASCIIDigit(d) { k += 1 }
            }
            if let e = src.unit(at: k), (e == UInt16(ascii: "e") || e == UInt16(ascii: "E")) {
                var ek = k + 1
                if let s = src.unit(at: ek), (s == uPlus || s == uMinus) { ek += 1 }
                let dStart = ek
                while let d = src.unit(at: ek), isASCIIDigit(d) { ek += 1 }
                if ek > dStart { k = ek }
            }
            numEnd = k
        } else if src.unit(at: n) == uDot, let d1 = src.unit(at: n + 1), isASCIIDigit(d1) {
            var k = n + 2
            while let d = src.unit(at: k), isASCIIDigit(d) { k += 1 }
            if let e = src.unit(at: k), (e == UInt16(ascii: "e") || e == UInt16(ascii: "E")) {
                var ek = k + 1
                if let s = src.unit(at: ek), (s == uPlus || s == uMinus) { ek += 1 }
                let dStart = ek
                while let d = src.unit(at: ek), isASCIIDigit(d) { ek += 1 }
                if ek > dStart { k = ek }
            }
            numEnd = k
        }
        if var k = numEnd {
            // Optional type suffix: (?:[dDlLnN]|[uU][sSyYlL]?|[sSyY])?
            if let s = src.unit(at: k) {
                switch s {
                case UInt16(ascii: "d"), UInt16(ascii: "D"), UInt16(ascii: "l"), UInt16(ascii: "L"),
                     UInt16(ascii: "n"), UInt16(ascii: "N"), UInt16(ascii: "s"), UInt16(ascii: "S"),
                     UInt16(ascii: "y"), UInt16(ascii: "Y"):
                    k += 1
                case UInt16(ascii: "u"), UInt16(ascii: "U"):
                    k += 1
                    if let s2 = src.unit(at: k),
                       (s2 == UInt16(ascii: "s") || s2 == UInt16(ascii: "S") ||
                        s2 == UInt16(ascii: "y") || s2 == UInt16(ascii: "Y") ||
                        s2 == UInt16(ascii: "l") || s2 == UInt16(ascii: "L"))
                    {
                        k += 1
                    }
                default: break
                }
            }
            // Optional multiplier: (?:[kKmMgGtTpP][bB])?
            if let m1 = src.unit(at: k), let m2 = src.unit(at: k + 1),
               (m2 == UInt16(ascii: "b") || m2 == UInt16(ascii: "B")),
               (m1 == UInt16(ascii: "k") || m1 == UInt16(ascii: "K") ||
                m1 == UInt16(ascii: "m") || m1 == UInt16(ascii: "M") ||
                m1 == UInt16(ascii: "g") || m1 == UInt16(ascii: "G") ||
                m1 == UInt16(ascii: "t") || m1 == UInt16(ascii: "T") ||
                m1 == UInt16(ascii: "p") || m1 == UInt16(ascii: "P"))
            {
                k += 2
            }
            if isPSDelimOrEnd(src, at: k, extra: "!#%&()*+,-/.;<=>]|{}") {
                return true
            }
        }
        // Case 8: -(?:not|bnot|join|[ic]?split)(?![\p{L}\p{Nl}])
        if u == uMinus {
            let lower = src.slice(index + 1, min(src.count, index + 8)).lowercased()
            for op in ["isplit", "csplit", "split", "bnot", "join", "not"] {
                if lower.hasPrefix(op) {
                    let after = index + 1 + op.utf16.count
                    if let (sc, _) = src.scalarAndLength(at: after), isUnicodeLetterOrNl(sc) {
                        continue
                    }
                    return true
                }
            }
        }
        return false
    }

    private static func isPSTypeNameInBrackets(_ s: String) -> Bool {
        // /^[\p{L}\p{Nl}_][\p{L}\p{Nl}\d_.#+`\\]*$/u
        let src = UTF16Source(s)
        guard let (first, firstLen) = src.scalarAndLength(at: 0),
              (isUnicodeLetterOrNl(first) || first.value == 0x5F) else { return false }
        var i = firstLen
        while i < src.count {
            let u = src.units[i]
            if u == uDot || u == uHash || u == uPlus || u == uBacktick || u == uBackslash {
                i += 1
                continue
            }
            guard let len = isPSIdentChar(src, at: i) else { return false }
            i += len
        }
        return true
    }

    private static func powerShellEscape(
        _ src: UTF16Source,
        start: Int,
        lineContinuation: Bool = false,
        skipped: Set<Int>?
    ) -> (value: String, end: Int)? {
        var next = start + 1
        while let sk = skipped, sk.contains(next) { next += 1 }
        guard let ch = src.unit(at: next) else { return nil }
        if ch == uCR || ch == uLF {
            let crlf = lineContinuation && ch == uCR && src.unit(at: next + 1) == uLF
            return (crlf ? "\r\n" : src.slice(next, next + 1), next + (crlf ? 1 : 0))
        }
        if ch == UInt16(ascii: "u") && src.unit(at: next + 1) == uLBrace {
            var k = next + 2
            while k < min(src.count, next + 8), isASCIIHex(src.units[k]) { k += 1 }
            let digitsLen = k - (next + 2)
            guard digitsLen >= 1 && digitsLen <= 6 && src.unit(at: k) == uRBrace else { return nil }
            let hex = src.slice(next + 2, k)
            guard let cp = UInt32(hex, radix: 16), cp <= 0x10FFFF, let sc = Unicode.Scalar(cp) else { return nil }
            return (String(sc), k)
        }
        return (powerShellEscapes[ch] ?? src.slice(next, next + 1), next)
    }

    private static func powerShellBracedVariable(
        _ src: UTF16Source,
        start: Int,
        skipped: Set<Int>?
    ) -> Int? {
        var index = start + 2
        while index < src.count {
            if let sk = skipped, sk.contains(index) { index += 1; continue }
            if src.units[index] == uBacktick {
                guard let esc = powerShellEscape(src, start: index, lineContinuation: false, skipped: skipped) else {
                    return nil
                }
                index = esc.end + 1
                continue
            }
            if src.units[index] == uRBrace {
                return index > start + 2 ? index : nil
            }
            index += 1
        }
        return nil
    }

    private static func powerShellSubExpression(
        _ src: UTF16Source,
        start: Int,
        hereString: Bool,
        budget: inout Int,
        skipped: Set<Int>?
    ) -> (skipped: Set<Int>, rawEnd: Int?)? {
        var nextSkipped = skipped ?? Set<Int>()
        var depth = 1
        var rawEnd: Int?
        var index = start
        while index < src.count {
            budget -= 1
            if budget < 0 { return nil }
            if nextSkipped.contains(index) { index += 1; continue }
            let ch = src.units[index]
            if ch == uLParen {
                depth += 1
            } else if ch == uRParen {
                depth -= 1
                if depth == 0 && rawEnd == nil { rawEnd = index }
            } else if !hereString && (ch == uDoubleQuote || ch == uBacktick) {
                var next = index + 1
                while nextSkipped.contains(next) { next += 1 }
                if src.unit(at: next) == uDoubleQuote {
                    nextSkipped.insert(index)
                    index = next + 1
                    continue
                }
            }
            index += 1
        }
        return (nextSkipped, rawEnd)
    }

    private static func powerShellStopParsing(
        _ src: UTF16Source,
        start: Int,
        skipped: Set<Int>?
    ) -> Int {
        var quoted = false
        var index = start
        while index < src.count {
            if let sk = skipped, sk.contains(index) { index += 1; continue }
            let ch = src.units[index]
            if ch == uDoubleQuote { quoted.toggle() }
            if ch == uCR || ch == uLF || ((ch == uPipe || (ch == uAmp && src.unit(at: index + 1) == uAmp)) && !quoted) {
                return index
            }
            index += 1
        }
        return src.count
    }

    private enum PSHereStringResult {
        case scanned(commands: [CoreShell.Scan.Command], source: String, end: Int)
        case opaque(CoreShell.Scan.OpaqueReason)
    }

    private static func powerShellHereString(
        _ src: UTF16Source,
        start: Int,
        depth: Int,
        budget: inout Int,
        skipped: Set<Int>?
    ) -> PSHereStringResult {
        guard let headerLen = matchPSHereHeaderLength(src, at: start) else {
            return .opaque(.unterminatedQuote)
        }
        let quote = src.units[start + 1]
        let body = start + headerLen
        var commands: [CoreShell.Scan.Command] = []
        var lineStart = true
        var index = body
        while index < src.count {
            budget -= 1
            if budget < 0 { return .opaque(.invalidStructure) }
            if let sk = skipped, sk.contains(index) { index += 1; continue }
            if lineStart && src.units[index] == quote && src.unit(at: index + 1) == uAt {
                let end: Int
                if index > body && src.unit(at: index - 1) == uLF && src.unit(at: index - 2) == uCR {
                    end = index - 2
                } else if index > body {
                    end = index - 1
                } else {
                    end = index
                }
                return .scanned(commands: commands, source: src.slice(body, end), end: index + 1)
            }
            if quote == uDoubleQuote {
                if src.units[index] == uBacktick {
                    guard let esc = powerShellEscape(src, start: index, lineContinuation: false, skipped: skipped) else {
                        return .opaque(.unterminatedEscape)
                    }
                    index = esc.end + 1
                    lineStart = false
                    continue
                }
                if src.units[index] == uDollar && src.unit(at: index + 1) == uLBrace {
                    guard let end = powerShellBracedVariable(src, start: index, skipped: skipped) else {
                        return .opaque(.invalidStructure)
                    }
                    index = end + 1
                    lineStart = false
                    continue
                }
                if src.units[index] == uDollar && src.unit(at: index + 1) == uLParen {
                    guard let sub = powerShellSubExpression(src, start: index + 2, hereString: true, budget: &budget, skipped: skipped) else {
                        return .opaque(.invalidStructure)
                    }
                    let res = scanPowerShellList(src, start: index + 2, depth: depth + 1, budget: &budget, close: uRParen, hash: .none, skipped: sub.skipped)
                    switch res {
                    case .opaque(let r): return .opaque(r)
                    case .scanned(let cmds, let resEnd):
                        commands.append(contentsOf: cmds)
                        let end = (sub.rawEnd != nil && sub.rawEnd! > resEnd) ? sub.rawEnd! : resEnd
                        index = end + 1
                        lineStart = false
                        continue
                    }
                }
            }
            lineStart = src.units[index] == uCR || src.units[index] == uLF
            index += 1
        }
        return .opaque(.unterminatedQuote)
    }

    private enum PSRedirectMatch {
        case none
        case invalid
        case matched(String)
    }

    private static func powerShellRedirect(_ src: UTF16Source, index: Int) -> PSRedirectMatch {
        var cursor = index
        if src.unit(at: cursor) == uStar {
            cursor += 1
        } else {
            while let u = src.unit(at: cursor), isASCIIDigit(u) { cursor += 1 }
        }
        guard src.unit(at: cursor) == uGT else { return .none }
        cursor += 1
        if src.unit(at: cursor) == uGT { cursor += 1 }
        if src.unit(at: cursor) == uAmp {
            cursor += 1
            while let u = src.unit(at: cursor), isASCIIDigit(u) { cursor += 1 }
        }
        let redir = src.slice(index, cursor)
        // /^(?:(?:[1-6]|\*)?>>?|[2-6*]>&1)$/
        let u = Array(redir.utf16)
        if u == [uGT] || u == [uGT, uGT] { return .matched(redir) }
        if u.count == 2 && (u[0] == uStar || (u[0] >= 0x31 && u[0] <= 0x36)) && u[1] == uGT {
            return .matched(redir)
        }
        if u.count == 3 && (u[0] == uStar || (u[0] >= 0x31 && u[0] <= 0x36)) && u[1] == uGT && u[2] == uGT {
            return .matched(redir)
        }
        if u.count == 4 && (u[0] == uStar || (u[0] >= 0x32 && u[0] <= 0x36)) &&
            u[1] == uGT && u[2] == uAmp && u[3] == 0x31
        {
            return .matched(redir)
        }
        return .invalid
    }

    private static func trimEndWhitespace(_ s: String) -> String {
        var u = Array(s.utf16)
        while let last = u.last, isJSWhitespace(last) { u.removeLast() }
        return String(decoding: u, as: UTF16.self)
    }

    private static func scanPowerShellList(
        _ src: UTF16Source,
        start: Int,
        depth: Int,
        budget: inout Int,
        close: UInt16?,
        hash: PowerShellHashMode,
        skipped: Set<Int>?
    ) -> InternalResult {
        if depth >= maxSubstitutionDepth || budget < 0 { return .opaque(.invalidStructure) }
        var commands: [CoreShell.Scan.Command] = []
        var nestedCommands: [CoreShell.Scan.Command] = []
        var words: [String] = []
        var rawWords: [String] = []
        var wordEnds: [Int] = []
        let initialExpression = hash == .hash || hash == .clause
        let initialClause: PowerShellClause? = (hash == .clause || hash == .switch) ? .member : nil

        var segment = start
        var word = ""
        var started = false
        var wordStart = start
        var quote: UInt16?
        var standalone = false
        var expression = initialExpression
        var clause: PowerShellClause? = initialClause
        var after: PowerShellAfter?
        var indexable: PowerShellIndexable = .none
        var memberChainStart: Int?
        var hasMemberAccess = false
        var hasFileRedirect = false
        var stopParsing = false
        var commandEnd = start
        var statementHead = true
        var invalid = false
        var redirectTarget = false
        var dangling = false
        var invocation = false

        func previousWord() -> String {
            started ? word : (words.last ?? "")
        }

        func afterMemberOperator() -> Bool {
            guard indexable == .member, let last = previousWord().utf16.last else { return false }
            return last == uDot || last == uColon
        }

        func resetMember() {
            indexable = .none
            memberChainStart = nil
            hasMemberAccess = false
        }

        func finishWord(_ end: Int) {
            guard started else { return }
            if word == "--%" && !words.isEmpty && !expression && clause == nil && !redirectTarget,
               let ws = src.unit(at: wordStart), ws != uSingleQuote && ws != uDoubleQuote,
               !(rawWords.last?.hasSuffix(",") ?? false),
               !isPSParameterColon(rawWords.last ?? "")
            {
                stopParsing = true
            }
            if !redirectTarget {
                if words.isEmpty && !invocation { segment = wordStart }
                words.append(word)
                rawWords.append(src.slice(wordStart, end))
                wordEnds.append(end)
                dangling = false
            }
            commandEnd = end
            redirectTarget = false
            word = ""
            started = false
        }

        func finishCommand(_ end: Int, required: Bool = false) {
            finishWord(end)
            if !words.isEmpty && ((!expression && clause == nil) || hasFileRedirect) {
                commands.append(CoreShell.Scan.Command(
                    resource: trimEndWhitespace(src.slice(segment, commandEnd)),
                    words: words,
                    rawWords: rawWords,
                    wordEnds: wordEnds.map { $0 - segment },
                    statementHead: statementHead && !invocation && !expression && clause == nil
                ))
            } else if (!expression && clause == nil && invocation) ||
                (required && words.isEmpty && nestedCommands.isEmpty) ||
                (clause != nil && clause != .member)
            {
                invalid = true
            }
            if redirectTarget { invalid = true }
            commands.append(contentsOf: nestedCommands)
            nestedCommands.removeAll()
            words.removeAll()
            rawWords.removeAll()
            wordEnds.removeAll()
            redirectTarget = false
            hasFileRedirect = false
            invocation = false
            expression = initialExpression
            clause = initialClause
            after = nil
            resetMember()
            stopParsing = false
        }

        var index = start
        while index < src.count {
            budget -= 1
            if budget < 0 { return .opaque(.invalidStructure) }
            if let sk = skipped, sk.contains(index) { index += 1; continue }
            let ch = src.units[index]
            let inExpression = expression && !redirectTarget
            let atBoundary = !started || (!inExpression && word.hasSuffix(","))
            if !started { wordStart = index }

            if stopParsing {
                let stop = powerShellStopParsing(src, start: index, skipped: skipped)
                let sliceStr = src.slice(index, stop)
                let trimmed = sliceStr.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    var offset = 0
                    for u in sliceStr.utf16 {
                        if !isJSWhitespace(u) { break }
                        offset += 1
                    }
                    wordStart = index + offset
                    word = trimmed
                    started = true
                    finishWord(wordStart + trimmed.utf16.count)
                }
                stopParsing = false
                index = stop
                continue
            }

            if let q = quote {
                var nextQuote = index + 1
                while let sk = skipped, sk.contains(nextQuote) { nextQuote += 1 }
                if ch == q && src.unit(at: nextQuote) == q {
                    word += src.slice(index, index + 1)
                    index = nextQuote + 1
                } else if ch == q {
                    quote = nil
                    if standalone {
                        finishWord(index + 1)
                        indexable = .closed
                    }
                    index += 1
                } else if q == uDoubleQuote && ch == uBacktick {
                    guard let esc = powerShellEscape(src, start: index, lineContinuation: false, skipped: skipped) else {
                        return .opaque(.unterminatedEscape)
                    }
                    word += esc.value
                    index = esc.end + 1
                } else if q == uDoubleQuote && ch == uDollar && src.unit(at: index + 1) == uLBrace {
                    guard let end = powerShellBracedVariable(src, start: index, skipped: skipped) else {
                        return .opaque(.invalidStructure)
                    }
                    word += src.slice(index, end + 1)
                    index = end + 1
                } else if q == uDoubleQuote && ch == uDollar && src.unit(at: index + 1) == uLParen {
                    guard let sub = powerShellSubExpression(src, start: index + 2, hereString: false, budget: &budget, skipped: skipped) else {
                        return .opaque(.invalidStructure)
                    }
                    let res = scanPowerShellList(src, start: index + 2, depth: depth + 1, budget: &budget, close: uRParen, hash: .none, skipped: sub.skipped)
                    switch res {
                    case .opaque(let r): return .opaque(r)
                    case .scanned(let cmds, let resEnd):
                        nestedCommands.append(contentsOf: cmds)
                        let end = (sub.rawEnd != nil && sub.rawEnd! > resEnd) ? sub.rawEnd! : resEnd
                        word += src.slice(index, end + 1)
                        index = end + 1
                    }
                } else {
                    word += src.slice(index, index + 1)
                    index += 1
                }
                continue
            }

            if ch == uSingleQuote || ch == uDoubleQuote {
                if !started && words.isEmpty && !invocation { expression = true }
                quote = ch
                let dynamicMember = afterMemberOperator()
                standalone = atBoundary || (expression && !redirectTarget) || dynamicMember
                if dynamicMember {
                    hasMemberAccess = true
                } else if standalone {
                    memberChainStart = index
                    hasMemberAccess = false
                } else {
                    resetMember()
                }
                started = true
                index += 1
                continue
            }

            if ch == uBacktick {
                guard let esc = powerShellEscape(src, start: index, lineContinuation: atBoundary || inExpression, skipped: skipped) else {
                    return .opaque(.unterminatedEscape)
                }
                let rawSpace = src.unit(at: index + 1).map { isJSWhitespace($0) } ?? false
                if (inExpression || atBoundary) && started && rawSpace {
                    finishWord(index)
                } else if !atBoundary || !rawSpace {
                    started = true
                    let escSrc = UTF16Source(esc.value)
                    if !(indexable == .member && isPSIdentChar(escSrc, at: 0) != nil) {
                        resetMember()
                    }
                    word += esc.value
                }
                index = esc.end + 1
                continue
            }

            if !started && !words.isEmpty && !expression && clause == nil && !redirectTarget &&
                matchPSStopParsing(src, at: index)
            {
                word = "--%"
                started = true
                finishWord(index + 3)
                index += 3
                continue
            }

            if ch == uLT && src.unit(at: index + 1) == uHash && (atBoundary || inExpression || indexable == .member) {
                let memberOp = afterMemberOperator()
                if started { finishWord(index) }
                guard let end = src.indexOf("#>", from: index + 2) else {
                    return .opaque(.invalidStructure)
                }
                if !memberOp { resetMember() }
                index = end + 2
                continue
            }

            if ch == uHash &&
                (atBoundary || indexable == .member ||
                    (inExpression && !(close == uRBracket && isPSTypeNameInBrackets(word))))
            {
                let prev = previousWord()
                let memberOp = afterMemberOperator()
                if (clause != nil && clause != .member) || prev.hasSuffix(",") || memberOp {
                    finishWord(index)
                } else if !words.isEmpty || started || invocation {
                    finishCommand(index)
                }
                statementHead = !dangling
                let lf = src.indexOf(uLF, from: index)
                let cr = src.indexOf(uCR, from: index)
                let nl: Int?
                if let a = lf, let b = cr { nl = min(a, b) } else { nl = lf ?? cr }
                guard let nl else {
                    index = src.count
                    break
                }
                index = (src.unit(at: nl) == uCR && src.unit(at: nl + 1) == uLF) ? nl + 2 : nl + 1
                continue
            }

            if inExpression && started && (ch == uGT || (ch == uStar && src.unit(at: index + 1) == uGT)) {
                finishWord(index)
            }

            if !started &&
                (ch == uGT || ch == uStar ||
                    (isASCIIDigit(ch) && (!words.isEmpty || matchPSMergeRedirect(src, at: index))))
            {
                switch powerShellRedirect(src, index: index) {
                case .invalid: return .opaque(.invalidRedirect)
                case .matched(let redir):
                    if redirectTarget || words.isEmpty || (clause != nil && clause != .member) {
                        return .opaque(.invalidRedirect)
                    }
                    redirectTarget = !redir.contains("&")
                    if redirectTarget { hasFileRedirect = true }
                    resetMember()
                    let rLen = redir.utf16.count
                    commandEnd = index + rLen
                    index += rLen
                    continue
                case .none: break
                }
            }

            if !started && words.isEmpty && !invocation && !expression && clause == nil && ch == uColon,
               let labelLen = matchPSLabelLength(src, at: index)
            {
                index += labelLen
                continue
            }

            if !started && !invocation && clause == nil &&
                (words.isEmpty ? !expression : words.allSatisfy({ $0.hasPrefix("[") })) &&
                isASCIIAlpha(ch)
            {
                if let kw = matchPSKeyword(src, at: index) {
                    let matchedBlock: Bool
                    if !words.isEmpty {
                        matchedBlock = (kw == "param" && matchPSWordFollowedByParen(src, at: index, word: "param")) ||
                            kw == "class" || kw == "enum"
                    } else {
                        matchedBlock = (kw == "param" && matchPSWordFollowedByParen(src, at: index, word: "param")) ||
                            (kw == "foreach" && matchPSWordFollowedByParen(src, at: index, word: "foreach")) ||
                            (kw == "until" && after == .do) ||
                            ((kw == "else" || kw == "elseif") && after == .if) ||
                            ((kw == "catch" || kw == "finally") && after == .try) ||
                            psBlockKeywords.contains(kw)
                    }
                    if matchedBlock {
                        expression = kw == "class" || kw == "enum" || kw == "break" || kw == "continue"
                        if kw == "using" || kw == "break" || kw == "continue" { clause = .member }
                        else if kw == "param" || kw == "until" || (kw == "while" && after == .do) { clause = .paren }
                        else if kw == "do" { clause = .do }
                        else if kw == "if" || kw == "elseif" { clause = .if }
                        else if kw == "try" || kw == "catch" { clause = .try }
                        else if kw == "switch" { clause = .switch }
                        else if kw == "class" || kw == "enum" { clause = .clause }
                        else { clause = .block }
                        after = nil
                        index += kw.utf16.count
                        continue
                    }
                    if words.isEmpty && (kw == "return" || kw == "throw" || kw == "exit") {
                        after = nil
                        index += kw.utf16.count
                        continue
                    }
                }
            }

            let isAssign = inExpression && clause == nil &&
                (ch == uEq || ((ch == uMinus || ch == uPlus || ch == uStar || ch == uSlash || ch == uPercent) && src.unit(at: index + 1) == uEq))
            if isAssign || (inExpression && close == uRParen && !started && matchPSIn(src, at: index)) {
                if isAssign { finishWord(index) }
                words.removeAll()
                rawWords.removeAll()
                wordEnds.removeAll()
                expression = false
                hasFileRedirect = false
                resetMember()
                index += (!isAssign || ch != uEq) ? 2 : 1
                continue
            }

            if atBoundary && ch == uAt && !matchPSAtOpener(src, at: index + 1) {
                return .opaque(.invalidStructure)
            }

            if atBoundary && ch == uAt && (src.unit(at: index + 1) == uSingleQuote || src.unit(at: index + 1) == uDoubleQuote) {
                if started { finishWord(index) }
                wordStart = index
                switch powerShellHereString(src, start: index, depth: depth, budget: &budget, skipped: skipped) {
                case .opaque(let r): return .opaque(r)
                case .scanned(let cmds, let source, let end):
                    if words.isEmpty && !invocation { expression = true }
                    nestedCommands.append(contentsOf: cmds)
                    word = source
                    started = true
                    index = end
                    finishWord(index + 1)
                    memberChainStart = wordStart
                    hasMemberAccess = false
                    indexable = .closed
                    index += 1
                    continue
                }
            }

            if ch == uDollar && src.unit(at: index + 1) == uLBrace {
                guard let end = powerShellBracedVariable(src, start: index, skipped: skipped) else {
                    return .opaque(.invalidStructure)
                }
                if !started && words.isEmpty && !invocation && hash != .switch { expression = true }
                let dynamicMember = afterMemberOperator()
                if dynamicMember {
                    indexable = .closed
                    hasMemberAccess = true
                } else if atBoundary {
                    memberChainStart = index
                    hasMemberAccess = false
                    indexable = .closed
                } else {
                    resetMember()
                }
                word += src.slice(index, end + 1)
                started = true
                index = end
                if expression && !redirectTarget && src.unit(at: index + 1) != uLBracket {
                    finishWord(index + 1)
                }
                index += 1
                continue
            }

            let opener: Int?
            if (ch == uDollar || (atBoundary && ch == uAt)) && src.unit(at: index + 1) == uLParen {
                opener = index + 1
            } else if atBoundary && ch == uAt && src.unit(at: index + 1) == uLBrace {
                opener = index + 1
            } else if ch == uLParen || ch == uLBrace ||
                (ch == uLBracket && (inExpression || indexable != .none ||
                    (!started && !invocation && (words.isEmpty || clause == .block || clause == .try))))
            {
                opener = index
            } else {
                opener = nil
            }

            if let opener {
                let tokenIndex = index
                let openChar = src.units[opener]
                let dynamicMemberOpener = afterMemberOperator()
                let priorIndexable = indexable != .none
                let wordLast = word.utf16.last
                let isMethodCall = ch == uLParen && opener == tokenIndex && memberChainStart != nil &&
                    ((indexable == .member && started && wordLast != uDot && wordLast != uColon) ||
                        (indexable == .closed && !started && hasMemberAccess))
                let standaloneBlock = atBoundary || inExpression || ch == uLParen || openChar == uLBrace
                let blockClose: UInt16 = openChar == uLParen ? uRParen : (openChar == uLBracket ? uRBracket : uRBrace)
                let blockHash: PowerShellHashMode
                if openChar == uLBracket { blockHash = .hash }
                else if ch == uAt && openChar == uLBrace { blockHash = .hash }
                else if clause == .switch && openChar == uLBrace { blockHash = .switch }
                else if clause == .clause && openChar == uLBrace { blockHash = .clause }
                else if close == uRBracket && ch == uLParen && started { blockHash = .clause }
                else { blockHash = .none }

                if started && (ch == uLBrace || ch == uLParen || (ch == uAt && atBoundary)) {
                    finishWord(index)
                    if stopParsing {
                        // Reprocess at same index
                        continue
                    }
                    wordStart = index
                }
                if !started && words.isEmpty && !invocation { expression = true }
                let res = scanPowerShellList(src, start: opener + 1, depth: depth + 1, budget: &budget, close: blockClose, hash: blockHash, skipped: skipped)
                switch res {
                case .opaque(let r): return .opaque(r)
                case .scanned(let cmds, let resEnd):
                    nestedCommands.append(contentsOf: cmds)
                    started = true
                    word += src.slice(index, resEnd + 1)
                    index = resEnd
                    if isMethodCall, let mcs = memberChainStart {
                        finishWord(index + 1)
                        let callResource = src.slice(mcs, resEnd + 1)
                        let head = src.slice(mcs, opener)
                        let args = src.slice(opener, resEnd + 1)
                        nestedCommands.append(CoreShell.Scan.Command(
                            resource: callResource,
                            words: [head, args],
                            rawWords: [head, args],
                            wordEnds: [head.utf16.count, callResource.utf16.count]
                        ))
                        indexable = .closed
                        hasMemberAccess = false
                    } else if openChar == uLBracket {
                        indexable = .closed
                        if !priorIndexable { memberChainStart = tokenIndex }
                        if src.unit(at: index + 1) != uLBracket { finishWord(index + 1) }
                    } else if standaloneBlock {
                        finishWord(index + 1)
                        indexable = .closed
                        if !dynamicMemberOpener { memberChainStart = tokenIndex }
                        hasMemberAccess = dynamicMemberOpener
                    }
                    if (clause == .paren && ch == uLParen) || (clause != nil && clause != .paren && ch == uLBrace) {
                        let completed: PowerShellAfter? = clause == .do ? .do : (clause == .if ? .if : (clause == .try ? .try : nil))
                        clause = .member
                        finishCommand(index + 1)
                        after = completed
                    }
                    index += 1
                    continue
                }
            }

            if let c = close, ch == c { break }
            if ch == uRBrace || ch == uRParen || (ch == uRBracket && inExpression) {
                return .opaque(.invalidStructure)
            }

            if !started && words.isEmpty &&
                ((ch == uAmp && src.unit(at: index + 1) != uAmp) ||
                    (ch == uDot && (src.unit(at: index + 1) == nil || isPSDelimOrEnd(src, at: index + 1, extra: "\"'$(),;{|}&"))))
            {
                if invocation { return .opaque(.invalidStructure) }
                segment = index
                invocation = true
                after = nil
                index += 1
                continue
            }

            if isJSWhitespace(ch) && ch != uLF && ch != uCR {
                let memberOp = afterMemberOperator()
                finishWord(index)
                if !memberOp { resetMember() }
                index += 1
                continue
            }

            let next = src.unit(at: index + 1)
            let sep: String?
            if ch == uCR && next == uLF { sep = "\r\n" }
            else if ch == uAmp && next == uAmp { sep = "&&" }
            else if ch == uPipe && next == uPipe { sep = "||" }
            else if ch == uSemi || ch == uPipe || ch == uAmp || ch == uLF || ch == uCR { sep = src.slice(index, index + 1) }
            else { sep = nil }

            if let sep {
                let sepLen = sep.utf16.count
                if close == uRBracket && (sep == ";" || sep == "|" || sep == "||" || sep == "&&" || sep == "&") {
                    return .opaque(.invalidStructure)
                }
                if sep == "\n" || sep == "\r" || sep == "\r\n" {
                    let prev = previousWord()
                    let memberOp = afterMemberOperator()
                    if (clause != nil && clause != .member) || prev.hasSuffix(",") || memberOp {
                        finishWord(index)
                        index += sepLen
                        if !memberOp { resetMember() }
                        continue
                    }
                    if !started && words.isEmpty && !invocation {
                        index += sepLen
                        resetMember()
                        continue
                    }
                }
                let isLineSep = sep == ";" || sep == "\n" || sep == "\r" || sep == "\r\n"
                finishCommand(index, required: dangling || !isLineSep)
                dangling = !(isLineSep || sep == "&")
                statementHead = !dangling
                index += sepLen
                continue
            }

            if !started && words.isEmpty && !invocation && hash != .switch && matchPSExpression(src, at: index) {
                expression = true
            }

            if (atBoundary || afterMemberOperator()) && ch == uDollar {
                if matchPSIndexableVar(src, at: index + 1) {
                    if afterMemberOperator() {
                        hasMemberAccess = true
                    } else {
                        memberChainStart = index
                        hasMemberAccess = false
                    }
                    indexable = .variable
                } else {
                    resetMember()
                }
            } else if indexable == .closed {
                let next1 = src.unit(at: index + 1)
                let next2 = src.unit(at: index + 2)
                if (ch == uDot && next1 != uDot && (!(next1.map { isJSWhitespace($0) } ?? false) || inExpression)) ||
                    (!started && ch == uColon && next1 == uColon) ||
                    (!started && ch == uQMark && next1 == uDot && next2 != uDot && (!(next2.map { isJSWhitespace($0) } ?? false) || inExpression))
                {
                    indexable = .member
                    hasMemberAccess = true
                } else if !started && ch == uQMark && next1 == uLBracket {
                    indexable = .closed
                } else {
                    resetMember()
                }
            } else if indexable == .variable {
                let next1 = src.unit(at: index + 1)
                if (ch == uDot && next1 != uDot && (!(next1.map { isJSWhitespace($0) } ?? false) || inExpression)) ||
                    (ch == uColon && next1 == uColon)
                {
                    indexable = .member
                    hasMemberAccess = true
                } else if (ch == uDot && next1 == uDot) ||
                    !(ch == uColon || ch == uQMark || isPSIdentChar(src, at: index) != nil)
                {
                    resetMember()
                }
            } else if indexable == .member {
                let next1 = src.unit(at: index + 1)
                let next2 = src.unit(at: index + 2)
                if ch == uDot && next1 == uDot {
                    resetMember()
                } else if (ch == uDot && (!(next1.map { isJSWhitespace($0) } ?? false) || inExpression)) ||
                    (ch == uColon && (next1 == uColon || src.unit(at: index - 1) == uColon)) ||
                    (ch == uQMark && next1 == uDot && next2 != uDot) ||
                    isPSIdentChar(src, at: index) != nil
                {
                    indexable = .member
                } else {
                    resetMember()
                }
            }

            after = nil
            started = true
            dangling = false
            word += src.slice(index, index + 1)
            index += 1
        }

        if let c = close, src.unit(at: index) != c { return .opaque(.invalidStructure) }
        if quote != nil { return .opaque(.unterminatedQuote) }
        finishCommand(index)
        if redirectTarget || invalid || dangling { return .opaque(.invalidStructure) }
        if commands.contains(where: { $0.words.first?.isEmpty ?? true }) {
            return .opaque(.dynamicCommandName)
        }
        return .scanned(commands: commands, end: index)
    }
}
