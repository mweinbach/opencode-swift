// Pure-Swift port of `jsonc-parser` (v3.3.1): fault-tolerant JSONC scanner, parser, AST,
// formatter, and surgical comment-/formatting-preserving `modify` + `applyEdits`.
//
// All offsets and lengths are UTF-16 code units, matching JavaScript's `String.prototype.length`
// and `jsonc-parser`'s exact semantics across ASCII, CJK, and emoji/surrogate pairs.
// Kept pure Swift standard library (zero imports) to preserve `OpenCodeUtil` tier purity.

public enum JSONC {
    // MARK: - Types & Enums

    public enum ScanError: Int, Equatable, Hashable, Sendable {
        case none = 0
        case unexpectedEndOfComment = 1
        case unexpectedEndOfString = 2
        case unexpectedEndOfNumber = 3
        case invalidUnicode = 4
        case invalidEscapeCharacter = 5
        case invalidCharacter = 6
    }

    public enum SyntaxKind: Int, Equatable, Hashable, Sendable {
        case openBraceToken = 1
        case closeBraceToken = 2
        case openBracketToken = 3
        case closeBracketToken = 4
        case commaToken = 5
        case colonToken = 6
        case nullKeyword = 7
        case trueKeyword = 8
        case falseKeyword = 9
        case stringLiteral = 10
        case numericLiteral = 11
        case lineCommentTrivia = 12
        case blockCommentTrivia = 13
        case lineBreakTrivia = 14
        case trivia = 15
        case unknown = 16
        case eof = 17
    }

    public enum ParseErrorCode: Int, Equatable, Hashable, Sendable {
        case invalidSymbol = 1
        case invalidNumberFormat = 2
        case propertyNameExpected = 3
        case valueExpected = 4
        case colonExpected = 5
        case commaExpected = 6
        case closeBraceExpected = 7
        case closeBracketExpected = 8
        case endOfFileExpected = 9
        case invalidCommentToken = 10
        case unexpectedEndOfComment = 11
        case unexpectedEndOfString = 12
        case unexpectedEndOfNumber = 13
        case invalidUnicode = 14
        case invalidEscapeCharacter = 15
        case invalidCharacter = 16
    }

    public static func printParseErrorCode(_ code: ParseErrorCode) -> String {
        switch code {
        case .invalidSymbol: return "InvalidSymbol"
        case .invalidNumberFormat: return "InvalidNumberFormat"
        case .propertyNameExpected: return "PropertyNameExpected"
        case .valueExpected: return "ValueExpected"
        case .colonExpected: return "ColonExpected"
        case .commaExpected: return "CommaExpected"
        case .closeBraceExpected: return "CloseBraceExpected"
        case .closeBracketExpected: return "CloseBracketExpected"
        case .endOfFileExpected: return "EndOfFileExpected"
        case .invalidCommentToken: return "InvalidCommentToken"
        case .unexpectedEndOfComment: return "UnexpectedEndOfComment"
        case .unexpectedEndOfString: return "UnexpectedEndOfString"
        case .unexpectedEndOfNumber: return "UnexpectedEndOfNumber"
        case .invalidUnicode: return "InvalidUnicode"
        case .invalidEscapeCharacter: return "InvalidEscapeCharacter"
        case .invalidCharacter: return "InvalidCharacter"
        }
    }

    public struct ParseError: Equatable, Hashable, Sendable {
        public let error: ParseErrorCode
        public let offset: Int
        public let length: Int

        public init(error: ParseErrorCode, offset: Int, length: Int) {
            self.error = error
            self.offset = offset
            self.length = length
        }
    }

    public struct ParseOptions: Equatable, Hashable, Sendable {
        public var disallowComments: Bool
        public var allowTrailingComma: Bool
        public var allowEmptyContent: Bool

        public init(
            disallowComments: Bool = false,
            allowTrailingComma: Bool = false,
            allowEmptyContent: Bool = false
        ) {
            self.disallowComments = disallowComments
            self.allowTrailingComma = allowTrailingComma
            self.allowEmptyContent = allowEmptyContent
        }

        public static let `default` = ParseOptions()
    }

    public struct FormattingOptions: Equatable, Hashable, Sendable {
        public var tabSize: Int?
        public var insertSpaces: Bool?
        public var eol: String?
        public var insertFinalNewline: Bool?
        public var keepLines: Bool?

        public init(
            tabSize: Int? = nil,
            insertSpaces: Bool? = nil,
            eol: String? = nil,
            insertFinalNewline: Bool? = nil,
            keepLines: Bool? = nil
        ) {
            self.tabSize = tabSize
            self.insertSpaces = insertSpaces
            self.eol = eol
            self.insertFinalNewline = insertFinalNewline
            self.keepLines = keepLines
        }
    }

    public struct ModificationOptions: Sendable {
        public var formattingOptions: FormattingOptions?
        public var getInsertionIndex: (@Sendable ([String]) -> Int)?
        public var isArrayInsertion: Bool

        public init(
            formattingOptions: FormattingOptions? = nil,
            getInsertionIndex: (@Sendable ([String]) -> Int)? = nil,
            isArrayInsertion: Bool = false
        ) {
            self.formattingOptions = formattingOptions
            self.getInsertionIndex = getInsertionIndex
            self.isArrayInsertion = isArrayInsertion
        }
    }

    public struct Range: Equatable, Hashable, Sendable {
        public let offset: Int
        public let length: Int

        public init(offset: Int, length: Int) {
            self.offset = offset
            self.length = length
        }
    }

    public struct Edit: Equatable, Hashable, Sendable {
        public let offset: Int
        public let length: Int
        public let content: String

        public init(offset: Int, length: Int, content: String) {
            self.offset = offset
            self.length = length
            self.content = content
        }
    }

    public enum PathSegment: Equatable, Hashable, Sendable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral {
        case key(String)
        case index(Int)

        public init(stringLiteral value: String) {
            self = .key(value)
        }

        public init(integerLiteral value: Int) {
            self = .index(value)
        }
    }

    public enum EditError: Error, Equatable, Sendable, CustomStringConvertible {
        case message(String)

        public var description: String {
            switch self {
            case .message(let msg): return msg
            }
        }
    }

    public enum NodeType: String, Equatable, Hashable, Sendable {
        case object
        case array
        case property
        case string
        case number
        case boolean
        case null
    }

    /// AST node produced by `JSONC.parseTree`. All offsets and lengths are UTF-16 code units.
    /// The tree is constructed synchronously inside `parseTree` and never mutated after returning.
    public final class Node: @unchecked Sendable {
        public let type: NodeType
        public internal(set) var value: PureJSONValue?
        public let offset: Int
        public internal(set) var length: Int
        public internal(set) var colonOffset: Int?
        public internal(set) weak var parent: Node?
        public internal(set) var children: [Node]?

        internal init(
            type: NodeType,
            offset: Int,
            length: Int,
            parent: Node? = nil,
            children: [Node]? = nil,
            value: PureJSONValue? = nil,
            colonOffset: Int? = nil
        ) {
            self.type = type
            self.offset = offset
            self.length = length
            self.parent = parent
            self.children = children
            self.value = value
            self.colonOffset = colonOffset
        }

        public var stringValue: String? {
            if case .string(let s)? = value { return s }
            return nil
        }
    }

    public struct Visitor {
        public var onObjectBegin: ((_ offset: Int, _ length: Int, _ startLine: Int, _ startCharacter: Int, _ pathSupplier: () -> [PathSegment]) -> Bool)?
        public var onObjectProperty: ((_ property: String, _ offset: Int, _ length: Int, _ startLine: Int, _ startCharacter: Int, _ pathSupplier: () -> [PathSegment]) -> Void)?
        public var onObjectEnd: ((_ offset: Int, _ length: Int, _ startLine: Int, _ startCharacter: Int) -> Void)?
        public var onArrayBegin: ((_ offset: Int, _ length: Int, _ startLine: Int, _ startCharacter: Int, _ pathSupplier: () -> [PathSegment]) -> Bool)?
        public var onArrayEnd: ((_ offset: Int, _ length: Int, _ startLine: Int, _ startCharacter: Int) -> Void)?
        public var onLiteralValue: ((_ value: PureJSONValue, _ offset: Int, _ length: Int, _ startLine: Int, _ startCharacter: Int, _ pathSupplier: () -> [PathSegment]) -> Void)?
        public var onSeparator: ((_ character: String, _ offset: Int, _ length: Int, _ startLine: Int, _ startCharacter: Int) -> Void)?
        public var onComment: ((_ offset: Int, _ length: Int, _ startLine: Int, _ startCharacter: Int) -> Void)?
        public var onError: ((_ error: ParseErrorCode, _ offset: Int, _ length: Int, _ startLine: Int, _ startCharacter: Int) -> Void)?

        public init(
            onObjectBegin: ((_ offset: Int, _ length: Int, _ startLine: Int, _ startCharacter: Int, _ pathSupplier: () -> [PathSegment]) -> Bool)? = nil,
            onObjectProperty: ((_ property: String, _ offset: Int, _ length: Int, _ startLine: Int, _ startCharacter: Int, _ pathSupplier: () -> [PathSegment]) -> Void)? = nil,
            onObjectEnd: ((_ offset: Int, _ length: Int, _ startLine: Int, _ startCharacter: Int) -> Void)? = nil,
            onArrayBegin: ((_ offset: Int, _ length: Int, _ startLine: Int, _ startCharacter: Int, _ pathSupplier: () -> [PathSegment]) -> Bool)? = nil,
            onArrayEnd: ((_ offset: Int, _ length: Int, _ startLine: Int, _ startCharacter: Int) -> Void)? = nil,
            onLiteralValue: ((_ value: PureJSONValue, _ offset: Int, _ length: Int, _ startLine: Int, _ startCharacter: Int, _ pathSupplier: () -> [PathSegment]) -> Void)? = nil,
            onSeparator: ((_ character: String, _ offset: Int, _ length: Int, _ startLine: Int, _ startCharacter: Int) -> Void)? = nil,
            onComment: ((_ offset: Int, _ length: Int, _ startLine: Int, _ startCharacter: Int) -> Void)? = nil,
            onError: ((_ error: ParseErrorCode, _ offset: Int, _ length: Int, _ startLine: Int, _ startCharacter: Int) -> Void)? = nil
        ) {
            self.onObjectBegin = onObjectBegin
            self.onObjectProperty = onObjectProperty
            self.onObjectEnd = onObjectEnd
            self.onArrayBegin = onArrayBegin
            self.onArrayEnd = onArrayEnd
            self.onLiteralValue = onLiteralValue
            self.onSeparator = onSeparator
            self.onComment = onComment
            self.onError = onError
        }
    }

    // MARK: - UTF-16 Helpers

    @inline(__always)
    internal static func utf16Substring(_ units: [UInt16], _ start: Int, _ end: Int) -> String {
        let len = units.count
        let a = start < 0 ? 0 : (start > len ? len : start)
        let b = end < 0 ? 0 : (end > len ? len : end)
        let lo = a < b ? a : b
        let hi = a < b ? b : a
        if lo == hi { return "" }
        return String(decoding: units[lo..<hi], as: UTF16.self)
    }

    @inline(__always)
    internal static func isWhiteSpace(_ ch: Int) -> Bool {
        ch == 32 || ch == 9
    }

    @inline(__always)
    internal static func isLineBreak(_ ch: Int) -> Bool {
        ch == 10 || ch == 13
    }

    @inline(__always)
    internal static func isDigit(_ ch: Int) -> Bool {
        ch >= 48 && ch <= 57
    }

    @inline(__always)
    internal static func isEOL(_ units: [UInt16], _ offset: Int) -> Bool {
        if offset < 0 || offset >= units.count {
            return true
        }
        let ch = units[offset]
        return ch == 13 || ch == 10
    }

    // MARK: - Scanner (`impl/scanner.js`)

    public final class Scanner {
        private let units: [UInt16]
        private let len: Int
        private let ignoreTrivia: Bool
        private var pos: Int = 0
        private var value: String = ""
        private var tokenOffset: Int = 0
        private var token: SyntaxKind = .unknown
        private var lineNumber: Int = 0
        private var lineStartOffset: Int = 0
        private var tokenLineStartOffset: Int = 0
        private var prevTokenLineStartOffset: Int = 0
        private var scanError: ScanError = .none

        internal init(units: [UInt16], ignoreTrivia: Bool) {
            self.units = units
            self.len = units.count
            self.ignoreTrivia = ignoreTrivia
        }

        public convenience init(text: String, ignoreTrivia: Bool = false) {
            self.init(units: Array(text.utf16), ignoreTrivia: ignoreTrivia)
        }

        @inline(__always)
        private func codeAt(_ index: Int) -> Int {
            index >= 0 && index < len ? Int(units[index]) : -1
        }

        public func setPosition(_ newPosition: Int) {
            pos = newPosition
            value = ""
            tokenOffset = 0
            token = .unknown
            scanError = .none
        }

        public func getPosition() -> Int { pos }
        public func getToken() -> SyntaxKind { token }
        public func getTokenValue() -> String { value }
        public func getTokenOffset() -> Int { tokenOffset }
        public func getTokenLength() -> Int { pos - tokenOffset }
        public func getTokenStartLine() -> Int { lineStartOffset }
        public func getTokenStartCharacter() -> Int { tokenOffset - prevTokenLineStartOffset }
        public func getTokenError() -> ScanError { scanError }

        @discardableResult
        public func scan() -> SyntaxKind {
            ignoreTrivia ? scanNextNonTrivia() : scanNext()
        }

        private func scanHexDigits(count: Int, exact: Bool) -> Int {
            var digits = 0
            var acc = 0
            while digits < count || !exact {
                let ch = codeAt(pos)
                if ch >= 48 && ch <= 57 {
                    acc = acc * 16 + ch - 48
                } else if ch >= 65 && ch <= 70 {
                    acc = acc * 16 + ch - 65 + 10
                } else if ch >= 97 && ch <= 102 {
                    acc = acc * 16 + ch - 97 + 10
                } else {
                    break
                }
                pos += 1
                digits += 1
            }
            if digits < count {
                acc = -1
            }
            return acc
        }

        private func scanNumber() -> String {
            let start = pos
            if codeAt(pos) == 48 { // '0'
                pos += 1
            } else {
                pos += 1
                while pos < len && isDigit(codeAt(pos)) {
                    pos += 1
                }
            }
            if pos < len && codeAt(pos) == 46 { // '.'
                pos += 1
                if pos < len && isDigit(codeAt(pos)) {
                    pos += 1
                    while pos < len && isDigit(codeAt(pos)) {
                        pos += 1
                    }
                } else {
                    scanError = .unexpectedEndOfNumber
                    return utf16Substring(units, start, pos)
                }
            }
            var end = pos
            if pos < len && (codeAt(pos) == 69 || codeAt(pos) == 101) { // 'E' or 'e'
                pos += 1
                if pos < len && (codeAt(pos) == 43 || codeAt(pos) == 45) { // '+' or '-'
                    pos += 1
                }
                if pos < len && isDigit(codeAt(pos)) {
                    pos += 1
                    while pos < len && isDigit(codeAt(pos)) {
                        pos += 1
                    }
                    end = pos
                } else {
                    scanError = .unexpectedEndOfNumber
                }
            }
            return utf16Substring(units, start, end)
        }

        private func scanString() -> String {
            var resultUnits: [UInt16] = []
            var start = pos
            while true {
                if pos >= len {
                    if start < pos {
                        resultUnits.append(contentsOf: units[start..<pos])
                    }
                    scanError = .unexpectedEndOfString
                    break
                }
                let ch = Int(units[pos])
                if ch == 34 { // '"'
                    if start < pos {
                        resultUnits.append(contentsOf: units[start..<pos])
                    }
                    pos += 1
                    break
                }
                if ch == 92 { // '\'
                    if start < pos {
                        resultUnits.append(contentsOf: units[start..<pos])
                    }
                    pos += 1
                    if pos >= len {
                        scanError = .unexpectedEndOfString
                        break
                    }
                    let ch2 = Int(units[pos])
                    pos += 1
                    switch ch2 {
                    case 34: resultUnits.append(34)   // '"'
                    case 92: resultUnits.append(92)   // '\'
                    case 47: resultUnits.append(47)   // '/'
                    case 98: resultUnits.append(8)    // '\b'
                    case 102: resultUnits.append(12)  // '\f'
                    case 110: resultUnits.append(10)  // '\n'
                    case 114: resultUnits.append(13)  // '\r'
                    case 116: resultUnits.append(9)   // '\t'
                    case 117: // 'u'
                        let ch3 = scanHexDigits(count: 4, exact: true)
                        if ch3 >= 0 {
                            resultUnits.append(UInt16(ch3))
                        } else {
                            scanError = .invalidUnicode
                        }
                    default:
                        scanError = .invalidEscapeCharacter
                    }
                    start = pos
                    continue
                }
                if ch >= 0 && ch <= 0x1F {
                    if isLineBreak(ch) {
                        if start < pos {
                            resultUnits.append(contentsOf: units[start..<pos])
                        }
                        scanError = .unexpectedEndOfString
                        break
                    } else {
                        scanError = .invalidCharacter
                    }
                }
                pos += 1
            }
            return String(decoding: resultUnits, as: UTF16.self)
        }

        private func isUnknownContentCharacter(_ code: Int) -> Bool {
            if isWhiteSpace(code) || isLineBreak(code) {
                return false
            }
            switch code {
            case 125, 93, 123, 91, 34, 58, 44, 47:
                return false
            default:
                return true
            }
        }

        private func scanNext() -> SyntaxKind {
            value = ""
            scanError = .none
            tokenOffset = pos
            lineStartOffset = lineNumber
            prevTokenLineStartOffset = tokenLineStartOffset
            if pos >= len {
                tokenOffset = len
                token = .eof
                return token
            }
            var code = Int(units[pos])
            if isWhiteSpace(code) {
                repeat {
                    pos += 1
                    code = codeAt(pos)
                } while isWhiteSpace(code)
                value = utf16Substring(units, tokenOffset, pos)
                token = .trivia
                return token
            }
            if isLineBreak(code) {
                pos += 1
                if code == 13 && codeAt(pos) == 10 {
                    pos += 1
                    value = "\r\n"
                } else {
                    value = code == 13 ? "\r" : "\n"
                }
                lineNumber += 1
                tokenLineStartOffset = pos
                token = .lineBreakTrivia
                return token
            }
            switch code {
            case 123: // '{'
                pos += 1
                token = .openBraceToken
                return token
            case 125: // '}'
                pos += 1
                token = .closeBraceToken
                return token
            case 91: // '['
                pos += 1
                token = .openBracketToken
                return token
            case 93: // ']'
                pos += 1
                token = .closeBracketToken
                return token
            case 58: // ':'
                pos += 1
                token = .colonToken
                return token
            case 44: // ','
                pos += 1
                token = .commaToken
                return token
            case 34: // '"'
                pos += 1
                value = scanString()
                token = .stringLiteral
                return token
            case 47: // '/'
                let start = pos - 1
                if codeAt(pos + 1) == 47 { // '//'
                    pos += 2
                    while pos < len {
                        if isLineBreak(Int(units[pos])) {
                            break
                        }
                        pos += 1
                    }
                    value = utf16Substring(units, start, pos)
                    token = .lineCommentTrivia
                    return token
                }
                if codeAt(pos + 1) == 42 { // '/*'
                    pos += 2
                    let safeLength = len - 1
                    var commentClosed = false
                    while pos < safeLength {
                        let ch = Int(units[pos])
                        if ch == 42 && Int(units[pos + 1]) == 47 {
                            pos += 2
                            commentClosed = true
                            break
                        }
                        pos += 1
                        if isLineBreak(ch) {
                            if ch == 13 && codeAt(pos) == 10 {
                                pos += 1
                            }
                            lineNumber += 1
                            tokenLineStartOffset = pos
                        }
                    }
                    if !commentClosed {
                        pos += 1
                        scanError = .unexpectedEndOfComment
                    }
                    value = utf16Substring(units, start, pos)
                    token = .blockCommentTrivia
                    return token
                }
                value = "/"
                pos += 1
                token = .unknown
                return token
            case 45: // '-'
                value = "-"
                pos += 1
                if pos == len || !isDigit(codeAt(pos)) {
                    token = .unknown
                    return token
                }
                value += scanNumber()
                token = .numericLiteral
                return token
            case 48...57:
                value += scanNumber()
                token = .numericLiteral
                return token
            default:
                while pos < len && isUnknownContentCharacter(code) {
                    pos += 1
                    code = codeAt(pos)
                }
                if tokenOffset != pos {
                    value = utf16Substring(units, tokenOffset, pos)
                    switch value {
                    case "true":
                        token = .trueKeyword
                        return token
                    case "false":
                        token = .falseKeyword
                        return token
                    case "null":
                        token = .nullKeyword
                        return token
                    default:
                        token = .unknown
                        return token
                    }
                }
                value = utf16Substring(units, pos, pos + 1)
                pos += 1
                token = .unknown
                return token
            }
        }

        private func scanNextNonTrivia() -> SyntaxKind {
            var result: SyntaxKind
            repeat {
                result = scanNext()
            } while result.rawValue >= SyntaxKind.lineCommentTrivia.rawValue
                && result.rawValue <= SyntaxKind.trivia.rawValue
            return result
        }
    }

    public static func createScanner(_ text: String, ignoreTrivia: Bool = false) -> Scanner {
        Scanner(text: text, ignoreTrivia: ignoreTrivia)
    }

    // MARK: - Parser & Visitor (`impl/parser.js`)

    @discardableResult
    public static func visit(
        _ text: String,
        visitor: Visitor,
        options: ParseOptions = .default
    ) -> Bool {
        let scanner = createScanner(text, ignoreTrivia: false)
        var jsonPath: [PathSegment] = []
        var suppressedCallbacks = 0

        func emitObjectBegin() {
            guard let cb = visitor.onObjectBegin else { return }
            if suppressedCallbacks > 0 {
                suppressedCallbacks += 1
            } else {
                let keepGoing = cb(
                    scanner.getTokenOffset(),
                    scanner.getTokenLength(),
                    scanner.getTokenStartLine(),
                    scanner.getTokenStartCharacter(),
                    { jsonPath }
                )
                if !keepGoing {
                    suppressedCallbacks = 1
                }
            }
        }

        func emitObjectProperty(_ name: String) {
            guard suppressedCallbacks == 0, let cb = visitor.onObjectProperty else { return }
            cb(
                name,
                scanner.getTokenOffset(),
                scanner.getTokenLength(),
                scanner.getTokenStartLine(),
                scanner.getTokenStartCharacter(),
                { jsonPath }
            )
        }

        func emitObjectEnd() {
            guard let cb = visitor.onObjectEnd else { return }
            if suppressedCallbacks > 0 {
                suppressedCallbacks -= 1
            }
            if suppressedCallbacks == 0 {
                cb(
                    scanner.getTokenOffset(),
                    scanner.getTokenLength(),
                    scanner.getTokenStartLine(),
                    scanner.getTokenStartCharacter()
                )
            }
        }

        func emitArrayBegin() {
            guard let cb = visitor.onArrayBegin else { return }
            if suppressedCallbacks > 0 {
                suppressedCallbacks += 1
            } else {
                let keepGoing = cb(
                    scanner.getTokenOffset(),
                    scanner.getTokenLength(),
                    scanner.getTokenStartLine(),
                    scanner.getTokenStartCharacter(),
                    { jsonPath }
                )
                if !keepGoing {
                    suppressedCallbacks = 1
                }
            }
        }

        func emitArrayEnd() {
            guard let cb = visitor.onArrayEnd else { return }
            if suppressedCallbacks > 0 {
                suppressedCallbacks -= 1
            }
            if suppressedCallbacks == 0 {
                cb(
                    scanner.getTokenOffset(),
                    scanner.getTokenLength(),
                    scanner.getTokenStartLine(),
                    scanner.getTokenStartCharacter()
                )
            }
        }

        func emitLiteralValue(_ value: PureJSONValue) {
            guard suppressedCallbacks == 0, let cb = visitor.onLiteralValue else { return }
            cb(
                value,
                scanner.getTokenOffset(),
                scanner.getTokenLength(),
                scanner.getTokenStartLine(),
                scanner.getTokenStartCharacter(),
                { jsonPath }
            )
        }

        func emitSeparator(_ sep: String) {
            guard suppressedCallbacks == 0, let cb = visitor.onSeparator else { return }
            cb(
                sep,
                scanner.getTokenOffset(),
                scanner.getTokenLength(),
                scanner.getTokenStartLine(),
                scanner.getTokenStartCharacter()
            )
        }

        func emitComment() {
            guard suppressedCallbacks == 0, let cb = visitor.onComment else { return }
            cb(
                scanner.getTokenOffset(),
                scanner.getTokenLength(),
                scanner.getTokenStartLine(),
                scanner.getTokenStartCharacter()
            )
        }

        func emitError(_ err: ParseErrorCode) {
            guard suppressedCallbacks == 0, let cb = visitor.onError else { return }
            cb(
                err,
                scanner.getTokenOffset(),
                scanner.getTokenLength(),
                scanner.getTokenStartLine(),
                scanner.getTokenStartCharacter()
            )
        }

        let disallowComments = options.disallowComments
        let allowTrailingComma = options.allowTrailingComma

        @discardableResult
        func scanNext() -> SyntaxKind {
            while true {
                let token = scanner.scan()
                switch scanner.getTokenError() {
                case .invalidUnicode:
                    handleError(.invalidUnicode)
                case .invalidEscapeCharacter:
                    handleError(.invalidEscapeCharacter)
                case .unexpectedEndOfNumber:
                    handleError(.unexpectedEndOfNumber)
                case .unexpectedEndOfComment:
                    if !disallowComments {
                        handleError(.unexpectedEndOfComment)
                    }
                case .unexpectedEndOfString:
                    handleError(.unexpectedEndOfString)
                case .invalidCharacter:
                    handleError(.invalidCharacter)
                case .none:
                    break
                }
                switch token {
                case .lineCommentTrivia, .blockCommentTrivia:
                    if disallowComments {
                        handleError(.invalidCommentToken)
                    } else {
                        emitComment()
                    }
                case .unknown:
                    handleError(.invalidSymbol)
                case .trivia, .lineBreakTrivia:
                    break
                default:
                    return token
                }
            }
        }

        func handleError(
            _ error: ParseErrorCode,
            skipUntilAfter: [SyntaxKind] = [],
            skipUntil: [SyntaxKind] = []
        ) {
            emitError(error)
            if !skipUntilAfter.isEmpty || !skipUntil.isEmpty {
                var token = scanner.getToken()
                while token != .eof {
                    if skipUntilAfter.contains(token) {
                        scanNext()
                        break
                    } else if skipUntil.contains(token) {
                        break
                    }
                    token = scanNext()
                }
            }
        }

        @discardableResult
        func parseString(isValue: Bool) -> Bool {
            let value = scanner.getTokenValue()
            if isValue {
                emitLiteralValue(.string(value))
            } else {
                emitObjectProperty(value)
                jsonPath.append(.key(value))
            }
            scanNext()
            return true
        }

        func parseLiteral() -> Bool {
            switch scanner.getToken() {
            case .numericLiteral:
                let tokenValue = scanner.getTokenValue()
                let value: Double
                if let parsed = Double(tokenValue), !parsed.isNaN {
                    value = parsed
                } else {
                    handleError(.invalidNumberFormat)
                    value = 0
                }
                emitLiteralValue(.number(value))
            case .nullKeyword:
                emitLiteralValue(.null)
            case .trueKeyword:
                emitLiteralValue(.bool(true))
            case .falseKeyword:
                emitLiteralValue(.bool(false))
            default:
                return false
            }
            scanNext()
            return true
        }

        func parseProperty() -> Bool {
            if scanner.getToken() != .stringLiteral {
                handleError(.propertyNameExpected, skipUntil: [.closeBraceToken, .commaToken])
                return false
            }
            parseString(isValue: false)
            if scanner.getToken() == .colonToken {
                emitSeparator(":")
                scanNext()
                if !parseValue() {
                    handleError(.valueExpected, skipUntil: [.closeBraceToken, .commaToken])
                }
            } else {
                handleError(.colonExpected, skipUntil: [.closeBraceToken, .commaToken])
            }
            _ = jsonPath.popLast()
            return true
        }

        func parseObject() -> Bool {
            emitObjectBegin()
            scanNext()
            var needsComma = false
            while scanner.getToken() != .closeBraceToken && scanner.getToken() != .eof {
                if scanner.getToken() == .commaToken {
                    if !needsComma {
                        handleError(.valueExpected)
                    }
                    emitSeparator(",")
                    scanNext()
                    if scanner.getToken() == .closeBraceToken && allowTrailingComma {
                        break
                    }
                } else if needsComma {
                    handleError(.commaExpected)
                }
                if !parseProperty() {
                    handleError(.valueExpected, skipUntil: [.closeBraceToken, .commaToken])
                }
                needsComma = true
            }
            emitObjectEnd()
            if scanner.getToken() != .closeBraceToken {
                handleError(.closeBraceExpected, skipUntilAfter: [.closeBraceToken])
            } else {
                scanNext()
            }
            return true
        }

        func parseArray() -> Bool {
            emitArrayBegin()
            scanNext()
            var isFirstElement = true
            var needsComma = false
            while scanner.getToken() != .closeBracketToken && scanner.getToken() != .eof {
                if scanner.getToken() == .commaToken {
                    if !needsComma {
                        handleError(.valueExpected)
                    }
                    emitSeparator(",")
                    scanNext()
                    if scanner.getToken() == .closeBracketToken && allowTrailingComma {
                        break
                    }
                } else if needsComma {
                    handleError(.commaExpected)
                }
                if isFirstElement {
                    jsonPath.append(.index(0))
                    isFirstElement = false
                } else if case .index(let prev)? = jsonPath.last {
                    jsonPath[jsonPath.count - 1] = .index(prev + 1)
                }
                if !parseValue() {
                    handleError(.valueExpected, skipUntil: [.closeBracketToken, .commaToken])
                }
                needsComma = true
            }
            emitArrayEnd()
            if !isFirstElement {
                _ = jsonPath.popLast()
            }
            if scanner.getToken() != .closeBracketToken {
                handleError(.closeBracketExpected, skipUntilAfter: [.closeBracketToken])
            } else {
                scanNext()
            }
            return true
        }

        func parseValue() -> Bool {
            switch scanner.getToken() {
            case .openBracketToken:
                return parseArray()
            case .openBraceToken:
                return parseObject()
            case .stringLiteral:
                return parseString(isValue: true)
            default:
                return parseLiteral()
            }
        }

        scanNext()
        if scanner.getToken() == .eof {
            if options.allowEmptyContent {
                return true
            }
            handleError(.valueExpected)
            return false
        }
        if !parseValue() {
            handleError(.valueExpected)
            return false
        }
        if scanner.getToken() != .eof {
            handleError(.endOfFileExpected)
        }
        return true
    }

    private final class MutableParseNode {
        enum Kind {
            case array([MutableParseNode])
            case object([(String, MutableParseNode)], [String: Int])
            case literal(PureJSONValue)
        }

        var kind: Kind

        init(_ kind: Kind) {
            self.kind = kind
        }

        func appendArrayElement(_ node: MutableParseNode) {
            if case .array(var items) = kind {
                items.append(node)
                kind = .array(items)
            }
        }

        func setProperty(_ key: String, value: MutableParseNode) {
            if case .object(var entries, var positions) = kind {
                if let idx = positions[key] {
                    entries[idx] = (key, value)
                } else {
                    positions[key] = entries.count
                    entries.append((key, value))
                }
                kind = .object(entries, positions)
            }
        }

        func toPureJSON() -> PureJSONValue {
            switch kind {
            case .literal(let v):
                return v
            case .array(let items):
                return .array(items.map { $0.toPureJSON() })
            case .object(let entries, _):
                return .object(entries.map { ($0.0, $0.1.toPureJSON()) })
            }
        }
    }

    public static func parse(
        _ text: String,
        errors: inout [ParseError],
        options: ParseOptions = .default
    ) -> PureJSONValue? {
        var currentProperty: String? = nil
        let rootContainer = MutableParseNode(.array([]))
        var currentParent = rootContainer
        var previousParents: [MutableParseNode] = []
        var collectedErrors: [ParseError] = []

        func onValue(_ value: MutableParseNode) {
            switch currentParent.kind {
            case .array:
                currentParent.appendArrayElement(value)
            case .object:
                if let prop = currentProperty {
                    currentParent.setProperty(prop, value: value)
                }
            case .literal:
                break
            }
        }

        let visitor = Visitor(
            onObjectBegin: { _, _, _, _, _ in
                let obj = MutableParseNode(.object([], [:]))
                onValue(obj)
                previousParents.append(currentParent)
                currentParent = obj
                currentProperty = nil
                return true
            },
            onObjectProperty: { name, _, _, _, _, _ in
                currentProperty = name
            },
            onObjectEnd: { _, _, _, _ in
                currentParent = previousParents.removeLast()
            },
            onArrayBegin: { _, _, _, _, _ in
                let arr = MutableParseNode(.array([]))
                onValue(arr)
                previousParents.append(currentParent)
                currentParent = arr
                currentProperty = nil
                return true
            },
            onArrayEnd: { _, _, _, _ in
                currentParent = previousParents.removeLast()
            },
            onLiteralValue: { val, _, _, _, _, _ in
                onValue(MutableParseNode(.literal(val)))
            },
            onError: { err, offset, length, _, _ in
                collectedErrors.append(ParseError(error: err, offset: offset, length: length))
            }
        )
        visit(text, visitor: visitor, options: options)
        errors.append(contentsOf: collectedErrors)
        if case .array(let items) = rootContainer.kind {
            return items.first?.toPureJSON()
        }
        return nil
    }

    public static func parse(
        _ text: String,
        options: ParseOptions = .default
    ) -> (value: PureJSONValue?, errors: [ParseError]) {
        var errors: [ParseError] = []
        let value = parse(text, errors: &errors, options: options)
        return (value, errors)
    }

    public static func parseTree(
        _ text: String,
        errors: inout [ParseError],
        options: ParseOptions = .default
    ) -> Node? {
        let artificialRoot = Node(type: .array, offset: -1, length: -1, parent: nil, children: [])
        var currentParent = artificialRoot
        var collectedErrors: [ParseError] = []

        func ensurePropertyComplete(_ endOffset: Int) {
            if currentParent.type == .property {
                currentParent.length = endOffset - currentParent.offset
                if let p = currentParent.parent {
                    currentParent = p
                }
            }
        }

        @discardableResult
        func onValue(_ valueNode: Node) -> Node {
            if currentParent.children == nil {
                currentParent.children = [valueNode]
            } else {
                currentParent.children?.append(valueNode)
            }
            return valueNode
        }

        let visitor = Visitor(
            onObjectBegin: { offset, _, _, _, _ in
                currentParent = onValue(Node(type: .object, offset: offset, length: -1, parent: currentParent, children: []))
                return true
            },
            onObjectProperty: { name, offset, length, _, _, _ in
                currentParent = onValue(Node(type: .property, offset: offset, length: -1, parent: currentParent, children: []))
                currentParent.children?.append(Node(type: .string, offset: offset, length: length, parent: currentParent, value: .string(name)))
            },
            onObjectEnd: { offset, length, _, _ in
                ensurePropertyComplete(offset + length)
                currentParent.length = offset + length - currentParent.offset
                if let p = currentParent.parent {
                    currentParent = p
                }
                ensurePropertyComplete(offset + length)
            },
            onArrayBegin: { offset, _, _, _, _ in
                currentParent = onValue(Node(type: .array, offset: offset, length: -1, parent: currentParent, children: []))
                return true
            },
            onArrayEnd: { offset, length, _, _ in
                currentParent.length = offset + length - currentParent.offset
                if let p = currentParent.parent {
                    currentParent = p
                }
                ensurePropertyComplete(offset + length)
            },
            onLiteralValue: { value, offset, length, _, _, _ in
                onValue(Node(type: nodeType(for: value), offset: offset, length: length, parent: currentParent, value: value))
                ensurePropertyComplete(offset + length)
            },
            onSeparator: { sep, offset, _, _, _ in
                if currentParent.type == .property {
                    if sep == ":" {
                        currentParent.colonOffset = offset
                    } else if sep == "," {
                        ensurePropertyComplete(offset)
                    }
                }
            },
            onError: { err, offset, length, _, _ in
                collectedErrors.append(ParseError(error: err, offset: offset, length: length))
            }
        )
        visit(text, visitor: visitor, options: options)
        errors.append(contentsOf: collectedErrors)
        let result = artificialRoot.children?.first
        result?.parent = nil
        return result
    }

    public static func parseTree(
        _ text: String,
        options: ParseOptions = .default
    ) -> (root: Node?, errors: [ParseError]) {
        var errors: [ParseError] = []
        let root = parseTree(text, errors: &errors, options: options)
        return (root, errors)
    }

    public static func findNodeAtLocation(_ root: Node?, _ path: [PathSegment]) -> Node? {
        guard var node = root else { return nil }
        for segment in path {
            switch segment {
            case .key(let key):
                guard node.type == .object, let children = node.children else {
                    return nil
                }
                var found = false
                for propertyNode in children {
                    if let propChildren = propertyNode.children,
                       propChildren.count == 2,
                       propChildren[0].stringValue == key
                    {
                        node = propChildren[1]
                        found = true
                        break
                    }
                }
                if !found { return nil }
            case .index(let index):
                guard node.type == .array,
                      index >= 0,
                      let children = node.children,
                      index < children.count
                else {
                    return nil
                }
                node = children[index]
            }
        }
        return node
    }

    public static func getNodePath(_ node: Node) -> [PathSegment] {
        guard let parent = node.parent, let siblings = parent.children else {
            return []
        }
        var path = getNodePath(parent)
        if parent.type == .property {
            if let key = siblings.first?.stringValue {
                path.append(.key(key))
            }
        } else if parent.type == .array {
            if let idx = siblings.firstIndex(where: { $0 === node }) {
                path.append(.index(idx))
            }
        }
        return path
    }

    public static func getNodeValue(_ node: Node) -> PureJSONValue? {
        switch node.type {
        case .array:
            return .array((node.children ?? []).compactMap(getNodeValue))
        case .object:
            var entries: [(String, PureJSONValue)] = []
            var positions: [String: Int] = [:]
            for prop in node.children ?? [] {
                guard let propChildren = prop.children,
                      propChildren.count >= 2,
                      let key = propChildren[0].stringValue,
                      let val = getNodeValue(propChildren[1])
                else { continue }
                if let existing = positions[key] {
                    entries[existing] = (key, val)
                } else {
                    positions[key] = entries.count
                    entries.append((key, val))
                }
            }
            return .object(entries)
        case .null, .string, .number, .boolean:
            return node.value
        case .property:
            return nil
        }
    }

    public static func findNodeAtOffset(_ node: Node, offset: Int, includeRightBound: Bool = false) -> Node? {
        let inBounds = (offset >= node.offset && offset < node.offset + node.length)
            || (includeRightBound && offset == node.offset + node.length)
        guard inBounds else { return nil }
        if let children = node.children {
            for child in children {
                if child.offset > offset { break }
                if let item = findNodeAtOffset(child, offset: offset, includeRightBound: includeRightBound) {
                    return item
                }
            }
        }
        return node
    }

    public static func stripComments(_ text: String, replaceCh: String? = nil) -> String {
        let units = Array(text.utf16)
        let scanner = Scanner(units: units, ignoreTrivia: false)
        var parts: [String] = []
        var offset = 0
        var kind: SyntaxKind
        repeat {
            let pos = scanner.getPosition()
            kind = scanner.scan()
            switch kind {
            case .lineCommentTrivia, .blockCommentTrivia, .eof:
                if offset != pos {
                    parts.append(utf16Substring(units, offset, pos))
                }
                if let replaceCh {
                    var replaced = ""
                    for unit in scanner.getTokenValue().utf16 {
                        if unit == 10 {
                            replaced.append("\n")
                        } else if unit == 13 {
                            replaced.append("\r")
                        } else {
                            replaced.append(replaceCh)
                        }
                    }
                    parts.append(replaced)
                }
                offset = scanner.getPosition()
            default:
                break
            }
        } while kind != .eof
        return parts.joined()
    }

    private static func nodeType(for value: PureJSONValue) -> NodeType {
        switch value {
        case .bool: return .boolean
        case .number: return .number
        case .string: return .string
        case .null: return .null
        case .array: return .array
        case .object: return .object
        }
    }

    // MARK: - Formatter (`impl/format.js`)

    public static func format(
        _ documentText: String,
        range: Range? = nil,
        options: FormattingOptions = FormattingOptions()
    ) -> [Edit] {
        let docUnits = Array(documentText.utf16)
        return formatUnits(docUnits, range: range, options: options)
    }

    internal static func formatUnits(
        _ docUnits: [UInt16],
        range: Range?,
        options: FormattingOptions
    ) -> [Edit] {
        let initialIndentLevel: Int
        let formatUnits: [UInt16]
        let formatTextStart: Int
        let rangeStart: Int
        let rangeEnd: Int

        if let range {
            rangeStart = range.offset
            rangeEnd = rangeStart + range.length
            var start = rangeStart
            while start > 0 && !isEOL(docUnits, start - 1) {
                start -= 1
            }
            var endOffset = rangeEnd
            while endOffset < docUnits.count && !isEOL(docUnits, endOffset) {
                endOffset += 1
            }
            formatTextStart = start
            let clampedStart = min(max(0, start), docUnits.count)
            let clampedEnd = min(max(clampedStart, endOffset), docUnits.count)
            formatUnits = Array(docUnits[clampedStart..<clampedEnd])
            initialIndentLevel = computeIndentLevel(formatUnits, options: options)
        } else {
            formatUnits = docUnits
            initialIndentLevel = 0
            formatTextStart = 0
            rangeStart = 0
            rangeEnd = docUnits.count
        }

        let eol = getEOL(options: options, units: docUnits)
        var numberLineBreaks = 0
        var indentLevel = 0
        let tabSize = (options.tabSize ?? 0) != 0 ? options.tabSize! : 4
        let insertSpaces = options.insertSpaces ?? false
        let keepLines = options.keepLines ?? false
        let insertFinalNewline = options.insertFinalNewline ?? false
        let indentValue = insertSpaces ? String(repeating: " ", count: max(0, tabSize)) : "\t"

        let scanner = Scanner(units: formatUnits, ignoreTrivia: false)
        var hasError = false

        func newLinesAndIndent() -> String {
            let level = max(0, initialIndentLevel + indentLevel)
            if numberLineBreaks > 1 {
                return String(repeating: eol, count: numberLineBreaks) + String(repeating: indentValue, count: level)
            }
            return eol + String(repeating: indentValue, count: level)
        }

        func scanNext() -> SyntaxKind {
            var token = scanner.scan()
            numberLineBreaks = 0
            while token == .trivia || token == .lineBreakTrivia {
                if token == .lineBreakTrivia && keepLines {
                    numberLineBreaks += 1
                } else if token == .lineBreakTrivia {
                    numberLineBreaks = 1
                }
                token = scanner.scan()
            }
            hasError = token == .unknown || scanner.getTokenError() != .none
            return token
        }

        var editOperations: [Edit] = []

        func addEdit(_ text: String, _ startOffset: Int, _ endOffset: Int) {
            if !hasError
                && (range == nil || (startOffset < rangeEnd && endOffset > rangeStart))
                && utf16Substring(docUnits, startOffset, endOffset) != text
            {
                editOperations.append(Edit(offset: startOffset, length: endOffset - startOffset, content: text))
            }
        }

        var firstToken = scanNext()
        if keepLines && numberLineBreaks > 0 {
            addEdit(String(repeating: eol, count: numberLineBreaks), 0, 0)
        }
        if firstToken != .eof {
            let firstTokenStart = scanner.getTokenOffset() + formatTextStart
            let initialIndent = String(repeating: indentValue, count: max(0, initialIndentLevel))
            addEdit(initialIndent, formatTextStart, firstTokenStart)
        }

        while firstToken != .eof {
            var firstTokenEnd = scanner.getTokenOffset() + scanner.getTokenLength() + formatTextStart
            var secondToken = scanNext()
            var replaceContent = ""
            var needsLineBreak = false

            while numberLineBreaks == 0 && (secondToken == .lineCommentTrivia || secondToken == .blockCommentTrivia) {
                let commentTokenStart = scanner.getTokenOffset() + formatTextStart
                addEdit(" ", firstTokenEnd, commentTokenStart)
                firstTokenEnd = scanner.getTokenOffset() + scanner.getTokenLength() + formatTextStart
                needsLineBreak = secondToken == .lineCommentTrivia
                replaceContent = needsLineBreak ? newLinesAndIndent() : ""
                secondToken = scanNext()
            }

            if secondToken == .closeBraceToken {
                if firstToken != .openBraceToken {
                    indentLevel -= 1
                }
                if (keepLines && numberLineBreaks > 0) || (!keepLines && firstToken != .openBraceToken) {
                    replaceContent = newLinesAndIndent()
                } else if keepLines {
                    replaceContent = " "
                }
            } else if secondToken == .closeBracketToken {
                if firstToken != .openBracketToken {
                    indentLevel -= 1
                }
                if (keepLines && numberLineBreaks > 0) || (!keepLines && firstToken != .openBracketToken) {
                    replaceContent = newLinesAndIndent()
                } else if keepLines {
                    replaceContent = " "
                }
            } else {
                switch firstToken {
                case .openBracketToken, .openBraceToken:
                    indentLevel += 1
                    if (keepLines && numberLineBreaks > 0) || !keepLines {
                        replaceContent = newLinesAndIndent()
                    } else {
                        replaceContent = " "
                    }
                case .commaToken:
                    if (keepLines && numberLineBreaks > 0) || !keepLines {
                        replaceContent = newLinesAndIndent()
                    } else {
                        replaceContent = " "
                    }
                case .lineCommentTrivia:
                    replaceContent = newLinesAndIndent()
                case .blockCommentTrivia:
                    if numberLineBreaks > 0 {
                        replaceContent = newLinesAndIndent()
                    } else if !needsLineBreak {
                        replaceContent = " "
                    }
                case .colonToken:
                    if keepLines && numberLineBreaks > 0 {
                        replaceContent = newLinesAndIndent()
                    } else if !needsLineBreak {
                        replaceContent = " "
                    }
                case .stringLiteral:
                    if keepLines && numberLineBreaks > 0 {
                        replaceContent = newLinesAndIndent()
                    } else if secondToken == .colonToken && !needsLineBreak {
                        replaceContent = ""
                    }
                case .nullKeyword, .trueKeyword, .falseKeyword, .numericLiteral, .closeBraceToken, .closeBracketToken:
                    if keepLines && numberLineBreaks > 0 {
                        replaceContent = newLinesAndIndent()
                    } else {
                        if (secondToken == .lineCommentTrivia || secondToken == .blockCommentTrivia) && !needsLineBreak {
                            replaceContent = " "
                        } else if secondToken != .commaToken && secondToken != .eof {
                            hasError = true
                        }
                    }
                case .unknown:
                    hasError = true
                default:
                    break
                }
                if numberLineBreaks > 0 && (secondToken == .lineCommentTrivia || secondToken == .blockCommentTrivia) {
                    replaceContent = newLinesAndIndent()
                }
            }

            if secondToken == .eof {
                if keepLines && numberLineBreaks > 0 {
                    replaceContent = newLinesAndIndent()
                } else {
                    replaceContent = insertFinalNewline ? eol : ""
                }
            }

            let secondTokenStart = scanner.getTokenOffset() + formatTextStart
            addEdit(replaceContent, firstTokenEnd, secondTokenStart)
            firstToken = secondToken
        }

        return editOperations
    }

    private static func computeIndentLevel(_ contentUnits: [UInt16], options: FormattingOptions) -> Int {
        var i = 0
        var nChars = 0
        let tabSize = (options.tabSize ?? 0) != 0 ? options.tabSize! : 4
        while i < contentUnits.count {
            let ch = contentUnits[i]
            if ch == 32 { // ' '
                nChars += 1
            } else if ch == 9 { // '\t'
                nChars += tabSize
            } else {
                break
            }
            i += 1
        }
        guard tabSize > 0 else { return 0 }
        return nChars / tabSize
    }

    private static func getEOL(options: FormattingOptions, units: [UInt16]) -> String {
        for i in 0..<units.count {
            let ch = units[i]
            if ch == 13 { // '\r'
                if i + 1 < units.count && units[i + 1] == 10 {
                    return "\r\n"
                }
                return "\r"
            } else if ch == 10 { // '\n'
                return "\n"
            }
        }
        if let eol = options.eol, !eol.isEmpty {
            return eol
        }
        return "\n"
    }

    // MARK: - Surgical Modification & Edit Application (`impl/edit.js` + `main.js`)

    public static func modify(
        _ text: String,
        path originalPath: [PathSegment],
        value initialValue: PureJSONValue?,
        options: ModificationOptions = ModificationOptions()
    ) throws -> [Edit] {
        var path = originalPath
        var value = initialValue
        var errors: [ParseError] = []
        let root = parseTree(text, errors: &errors)
        return try withExtendedLifetime(root) {
            var parent: Node? = nil
            var lastSegment: PathSegment? = nil

            while !path.isEmpty {
                lastSegment = path.removeLast()
                parent = findNodeAtLocation(root, path)
                if parent == nil, let unwrappedValue = value, let seg = lastSegment {
                    switch seg {
                    case .key(let k):
                        value = .object([(k, unwrappedValue)])
                    case .index:
                        value = .array([unwrappedValue])
                    }
                } else {
                    break
                }
            }

            guard let parent else {
                // Empty document or root replacement
                guard let value else {
                    throw EditError.message("Can not delete in empty document")
                }
                let edit = Edit(
                    offset: root?.offset ?? 0,
                    length: root?.length ?? 0,
                    content: PureJSON.stringifyCompact(value)
                )
                return withFormatting(text, edit: edit, options: options)
            }

            if parent.type == .object, case .key(let key)? = lastSegment, let parentChildren = parent.children {
                if let existing = findNodeAtLocation(parent, [.key(key)]) {
                    guard let value else {
                        // Delete existing property
                        guard let propNode = existing.parent,
                              let propertyIndex = parentChildren.firstIndex(where: { $0 === propNode })
                        else {
                            throw EditError.message("Malformed AST")
                        }
                        let removeBegin: Int
                        var removeEnd = propNode.offset + propNode.length
                        if propertyIndex > 0 {
                            let previous = parentChildren[propertyIndex - 1]
                            removeBegin = previous.offset + previous.length
                        } else {
                            removeBegin = parent.offset + 1
                            if parentChildren.count > 1 {
                                let next = parentChildren[1]
                                removeEnd = next.offset
                            }
                        }
                        return withFormatting(
                            text,
                            edit: Edit(offset: removeBegin, length: removeEnd - removeBegin, content: ""),
                            options: options
                        )
                    }
                    // Replace existing property value
                    return withFormatting(
                        text,
                        edit: Edit(
                            offset: existing.offset,
                            length: existing.length,
                            content: PureJSON.stringifyCompact(value)
                        ),
                        options: options
                    )
                } else {
                    guard let value else {
                        // Property does not exist, nothing to remove
                        return []
                    }
                    let newProperty = "\(PureJSON.stringifyCompact(.string(key))): \(PureJSON.stringifyCompact(value))"
                    let index: Int
                    if let getInsertionIndex = options.getInsertionIndex {
                        let existingKeys = parentChildren.compactMap { $0.children?.first?.stringValue }
                        index = getInsertionIndex(existingKeys)
                    } else {
                        index = parentChildren.count
                    }
                    let edit: Edit
                    if index > 0 {
                        guard index - 1 < parentChildren.count else {
                            throw EditError.message("Insertion index out of bounds")
                        }
                        let previous = parentChildren[index - 1]
                        edit = Edit(offset: previous.offset + previous.length, length: 0, content: "," + newProperty)
                    } else if parentChildren.isEmpty {
                        edit = Edit(offset: parent.offset + 1, length: 0, content: newProperty)
                    } else {
                        edit = Edit(offset: parent.offset + 1, length: 0, content: newProperty + ",")
                    }
                    return withFormatting(text, edit: edit, options: options)
                }
            } else if parent.type == .array, case .index(let insertIndex)? = lastSegment, let parentChildren = parent.children {
                if insertIndex == -1 {
                    guard let value else {
                        throw EditError.message("Can not remove Array index \(insertIndex) as length is not sufficient")
                    }
                    let newProperty = PureJSON.stringifyCompact(value)
                    let edit: Edit
                    if parentChildren.isEmpty {
                        edit = Edit(offset: parent.offset + 1, length: 0, content: newProperty)
                    } else {
                        let previous = parentChildren[parentChildren.count - 1]
                        edit = Edit(offset: previous.offset + previous.length, length: 0, content: "," + newProperty)
                    }
                    return withFormatting(text, edit: edit, options: options)
                } else if value == nil {
                    let removalIndex = insertIndex
                    let edit: Edit
                    if parentChildren.count == 1 {
                        edit = Edit(offset: parent.offset + 1, length: parent.length - 2, content: "")
                    } else if parentChildren.count - 1 == removalIndex {
                        let previous = parentChildren[removalIndex - 1]
                        let offset = previous.offset + previous.length
                        let parentEndOffset = parent.offset + parent.length
                        edit = Edit(offset: offset, length: parentEndOffset - 2 - offset, content: "")
                    } else {
                        guard removalIndex >= 0, removalIndex + 1 < parentChildren.count else {
                            throw EditError.message("Can not remove Array index \(removalIndex) as length is not sufficient")
                        }
                        let toRemove = parentChildren[removalIndex]
                        edit = Edit(
                            offset: toRemove.offset,
                            length: parentChildren[removalIndex + 1].offset - toRemove.offset,
                            content: ""
                        )
                    }
                    return withFormatting(text, edit: edit, options: options)
                } else if let value {
                    let newProperty = PureJSON.stringifyCompact(value)
                    let edit: Edit
                    if !options.isArrayInsertion && parentChildren.count > insertIndex {
                        guard insertIndex >= 0 else {
                            throw EditError.message("Can not modify Array index \(insertIndex) as length is not sufficient")
                        }
                        let toModify = parentChildren[insertIndex]
                        edit = Edit(offset: toModify.offset, length: toModify.length, content: newProperty)
                    } else if parentChildren.isEmpty || insertIndex == 0 {
                        edit = Edit(
                            offset: parent.offset + 1,
                            length: 0,
                            content: parentChildren.isEmpty ? newProperty : newProperty + ","
                        )
                    } else {
                        let clampedIndex = insertIndex > parentChildren.count ? parentChildren.count : insertIndex
                        guard clampedIndex >= 1 else {
                            throw EditError.message("Can not insert Array index \(insertIndex) as length is not sufficient")
                        }
                        let previous = parentChildren[clampedIndex - 1]
                        edit = Edit(offset: previous.offset + previous.length, length: 0, content: "," + newProperty)
                    }
                    return withFormatting(text, edit: edit, options: options)
                } else {
                    let verb = value == nil ? "remove" : (options.isArrayInsertion ? "insert" : "modify")
                    throw EditError.message("Can not \(verb) Array index \(insertIndex) as length is not sufficient")
                }
            } else {
                let isIndex: Bool
                if case .index? = lastSegment { isIndex = true } else { isIndex = false }
                throw EditError.message("Can not add \(isIndex ? "property" : "index") to parent of type \(parent.type.rawValue)")
            }
        }
    }

    private static func withFormatting(
        _ text: String,
        edit: Edit,
        options: ModificationOptions
    ) -> [Edit] {
        guard var formattingOptions = options.formattingOptions else {
            return [edit]
        }
        let originalUnits = Array(text.utf16)
        var newUnits = applyEditUnits(originalUnits, edit: edit)

        var begin = edit.offset
        var end = edit.offset + edit.content.utf16.count
        if edit.length == 0 || edit.content.isEmpty {
            while begin > 0 && !isEOL(newUnits, begin - 1) {
                begin -= 1
            }
            while end < newUnits.count && !isEOL(newUnits, end) {
                end += 1
            }
        }

        formattingOptions.keepLines = false
        let edits = formatUnits(
            newUnits,
            range: Range(offset: begin, length: end - begin),
            options: formattingOptions
        )

        for i in stride(from: edits.count - 1, through: 0, by: -1) {
            let e = edits[i]
            newUnits = applyEditUnits(newUnits, edit: e)
            begin = min(begin, e.offset)
            end = max(end, e.offset + e.length)
            end += e.content.utf16.count - e.length
        }

        let editLength = originalUnits.count - (newUnits.count - end) - begin
        return [Edit(offset: begin, length: editLength, content: utf16Substring(newUnits, begin, end))]
    }

    private static func applyEditUnits(_ units: [UInt16], edit: Edit) -> [UInt16] {
        let len = units.count
        let start = min(max(0, edit.offset), len)
        let end = min(max(0, edit.offset + edit.length), len)
        let replacement = Array(edit.content.utf16)
        var out: [UInt16] = []
        out.reserveCapacity(start + replacement.count + (len - end))
        if start > 0 {
            out.append(contentsOf: units[0..<start])
        }
        out.append(contentsOf: replacement)
        if end < len {
            out.append(contentsOf: units[end..<len])
        }
        return out
    }

    public static func applyEdit(_ text: String, edit: Edit) -> String {
        let updated = applyEditUnits(Array(text.utf16), edit: edit)
        return String(decoding: updated, as: UTF16.self)
    }

    public static func applyEdits(_ text: String, edits: [Edit]) throws -> String {
        let sortedEdits = edits.sorted { a, b in
            let diff = a.offset - b.offset
            if diff == 0 {
                return a.length < b.length
            }
            return diff < 0
        }
        var units = Array(text.utf16)
        var lastModifiedOffset = units.count
        for i in stride(from: sortedEdits.count - 1, through: 0, by: -1) {
            let e = sortedEdits[i]
            if e.offset + e.length <= lastModifiedOffset {
                units = applyEditUnits(units, edit: e)
            } else {
                throw EditError.message("Overlapping edit")
            }
            lastModifiedOffset = e.offset
        }
        return String(decoding: units, as: UTF16.self)
    }
}
