/// Dynamic layout option input matching JavaScript renderable option validators
/// (`number | string | undefined`).
public enum LayoutOptionValue: Equatable, Hashable, Sendable,
    ExpressibleByFloatLiteral,
    ExpressibleByIntegerLiteral,
    ExpressibleByStringLiteral,
    ExpressibleByNilLiteral
{
    case number(Double)
    case string(String)
    case null
    case undefined

    public init(_ value: Double) {
        self = .number(value)
    }

    public init(_ value: Int) {
        self = .number(Double(value))
    }

    public init(_ value: String) {
        self = .string(value)
    }

    public init(_ value: Double?) {
        if let value {
            self = .number(value)
        } else {
            self = .undefined
        }
    }

    public init(_ value: String?) {
        if let value {
            self = .string(value)
        } else {
            self = .undefined
        }
    }

    public init(floatLiteral value: Double) {
        self = .number(value)
    }

    public init(integerLiteral value: Int) {
        self = .number(Double(value))
    }

    public init(stringLiteral value: String) {
        self = .string(value)
    }

    public init(nilLiteral: ()) {
        self = .undefined
    }
}

/// Subset of renderable options validated by `validateOptions`.
public struct RenderableValidationOptions: Equatable, Hashable, Sendable {
    public var width: LayoutOptionValue?
    public var height: LayoutOptionValue?

    public init(width: LayoutOptionValue? = nil, height: LayoutOptionValue? = nil) {
        self.width = width
        self.height = height
    }
}

/// Validation errors thrown by `validateOptions`, matching upstream `TypeError` messages.
public enum RenderableValidationError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    case invalidWidth(id: String, value: Double)
    case invalidHeight(id: String, value: Double)

    public var description: String {
        switch self {
        case let .invalidWidth(id, value):
            return "Invalid width for Renderable \(id): \(formatNumber(value))"
        case let .invalidHeight(id, value):
            return "Invalid height for Renderable \(id): \(formatNumber(value))"
        }
    }

    private func formatNumber(_ value: Double) -> String {
        if value.isFinite, value.rounded(.towardZero) == value, value >= Double(Int.min), value <= Double(Int.max) {
            return String(Int(value))
        }
        return String(value)
    }
}

/// Returns `true` iff `v` is an ECMAScript `StrWhiteSpace` (`WhiteSpace | LineTerminator`) scalar.
private func isJSWhitespaceScalar(_ v: UInt32) -> Bool {
    v == 0x09 || v == 0x0A || v == 0x0B || v == 0x0C || v == 0x0D ||
    v == 0x20 || v == 0xA0 || v == 0x1680 ||
    (v >= 0x2000 && v <= 0x200A) ||
    v == 0x2028 || v == 0x2029 || v == 0x202F || v == 0x205F ||
    v == 0x3000 || v == 0xFEFF
}

/// Returns `true` iff ECMAScript `parseFloat(s)` produces a non-NaN number.
private func jsParseFloatSucceeds(_ s: Substring) -> Bool {
    let scalars = s.unicodeScalars
    var i = scalars.startIndex

    // Skip leading ECMAScript StrWhiteSpace (WhiteSpace | LineTerminator).
    while i < scalars.endIndex {
        if !isJSWhitespaceScalar(scalars[i].value) { break }
        scalars.formIndex(after: &i)
    }

    guard i < scalars.endIndex else { return false }

    // Optional leading sign.
    if scalars[i] == "+" || scalars[i] == "-" {
        scalars.formIndex(after: &i)
        guard i < scalars.endIndex else { return false }
    }

    // "Infinity"
    let remaining = s[i...]
    if remaining.hasPrefix("Infinity") {
        return true
    }

    let first = scalars[i].value
    // Digit starts a valid decimal literal.
    if first >= 0x30 && first <= 0x39 {
        return true
    }

    // Leading "." must be immediately followed by an ASCII digit.
    if first == 0x2E {
        let next = scalars.index(after: i)
        guard next < scalars.endIndex else { return false }
        let d = scalars[next].value
        return d >= 0x30 && d <= 0x39
    }

    return false
}

/// Exact ECMAScript parity for:
/// `const percent = Number(value.slice(0, -1)); return percent === Number.parseFloat(value) && Math.abs(percent) <= 3.4028234663852886e38`
private func jsFlexBasisPercentValid(_ numPart: Substring) -> Bool {
    let scalars = numPart.unicodeScalars
    var start = scalars.startIndex
    var end = scalars.endIndex

    while start < end && isJSWhitespaceScalar(scalars[start].value) {
        scalars.formIndex(after: &start)
    }
    while end > start {
        let prev = scalars.index(before: end)
        if !isJSWhitespaceScalar(scalars[prev].value) { break }
        end = prev
    }

    // Empty string before "%" has Number("") === 0 while parseFloat("%") === NaN.
    guard start < end else { return false }

    // Non-decimal unsigned JS integer literals (`0x0`, `0b0`, `0o0`) only match parseFloat (`0`) when all digits are '0'.
    if scalars[start].value == 0x30 {
        let next = scalars.index(after: start)
        if next < end {
            let prefix = scalars[next].value
            if prefix == 0x78 || prefix == 0x58 || prefix == 0x62 || prefix == 0x42 || prefix == 0x6F || prefix == 0x4F {
                let digitsStart = scalars.index(after: next)
                guard digitsStart < end else { return false }
                var cur = digitsStart
                while cur < end {
                    if scalars[cur].value != 0x30 { return false }
                    scalars.formIndex(after: &cur)
                }
                return true
            }
        }
    }

    // Validate exact ECMAScript StrDecimalLiteral (excluding Infinity, which exceeds f32 max).
    var i = start
    if scalars[i].value == 0x2B || scalars[i].value == 0x2D { // '+' or '-'
        scalars.formIndex(after: &i)
        guard i < end else { return false }
    }

    var hasDigits = false
    while i < end && scalars[i].value >= 0x30 && scalars[i].value <= 0x39 {
        hasDigits = true
        scalars.formIndex(after: &i)
    }

    if i < end && scalars[i].value == 0x2E { // '.'
        scalars.formIndex(after: &i)
        var hasFractionDigits = false
        while i < end && scalars[i].value >= 0x30 && scalars[i].value <= 0x39 {
            hasFractionDigits = true
            scalars.formIndex(after: &i)
        }
        guard hasDigits || hasFractionDigits else { return false }
    } else {
        guard hasDigits else { return false }
    }

    if i < end && (scalars[i].value == 0x65 || scalars[i].value == 0x45) { // 'e' or 'E'
        scalars.formIndex(after: &i)
        guard i < end else { return false }
        if scalars[i].value == 0x2B || scalars[i].value == 0x2D {
            scalars.formIndex(after: &i)
            guard i < end else { return false }
        }
        var hasExpDigits = false
        while i < end && scalars[i].value >= 0x30 && scalars[i].value <= 0x39 {
            hasExpDigits = true
            scalars.formIndex(after: &i)
        }
        guard hasExpDigits else { return false }
    }

    guard i == end else { return false }

    let literal = numPart[start..<end]
    guard let percent = Double(literal), percent.isFinite else {
        return false
    }
    return abs(percent) <= 3.4028234663852886e38
}

// parity: core/src/lib/renderable.validations.ts#validateOptions [status=implemented hash=1ea650758432]
public func validateOptions(
    id: String,
    options: RenderableValidationOptions
) throws(RenderableValidationError) {
    if case let .number(width) = options.width, width < 0 {
        throw .invalidWidth(id: id, value: width)
    }
    if case let .number(height) = options.height, height < 0 {
        throw .invalidHeight(id: id, value: height)
    }
}

// parity: core/src/lib/renderable.validations.ts#isValidPercentage [status=implemented hash=0040a5e3d901]
public func isValidPercentage(_ value: LayoutOptionValue) -> Bool {
    guard case let .string(str) = value, str.hasSuffix("%") else {
        return false
    }
    let numPart = str.dropLast()
    return jsParseFloatSucceeds(numPart)
}

// parity: core/src/lib/renderable.validations.ts#isMarginType [status=implemented hash=9506c09346b8]
public func isMarginType(_ value: LayoutOptionValue) -> Bool {
    switch value {
    case let .number(n):
        return !n.isNaN
    case let .string(s):
        if s == "auto" { return true }
        return isValidPercentage(value)
    case .null, .undefined:
        return false
    }
}

// parity: core/src/lib/renderable.validations.ts#isPaddingType [status=implemented hash=321193423678]
public func isPaddingType(_ value: LayoutOptionValue) -> Bool {
    switch value {
    case let .number(n):
        return !n.isNaN
    case .string:
        return isValidPercentage(value)
    case .null, .undefined:
        return false
    }
}

// parity: core/src/lib/renderable.validations.ts#isPositionType [status=implemented hash=a7f24ce52437]
public func isPositionType(_ value: LayoutOptionValue) -> Bool {
    switch value {
    case let .number(n):
        return !n.isNaN
    case let .string(s):
        if s == "auto" { return true }
        return isValidPercentage(value)
    case .null, .undefined:
        return false
    }
}

// parity: core/src/lib/renderable.validations.ts#isPositionTypeType [status=implemented hash=07f9c095dabb]
public func isPositionTypeType(_ value: LayoutOptionValue) -> Bool {
    guard case let .string(s) = value else { return false }
    return s == "relative" || s == "absolute"
}

// parity: core/src/lib/renderable.validations.ts#isOverflowType [status=implemented hash=271d52192fe5]
public func isOverflowType(_ value: LayoutOptionValue) -> Bool {
    guard case let .string(s) = value else { return false }
    return s == "visible" || s == "hidden" || s == "scroll"
}

// parity: core/src/lib/renderable.validations.ts#isDimensionType [status=implemented hash=80031f377b4c]
public func isDimensionType(_ value: LayoutOptionValue) -> Bool {
    isPositionType(value)
}

// parity: core/src/lib/renderable.validations.ts#isFlexBasisType [status=implemented hash=a7d430d45fa2]
public func isFlexBasisType(_ value: LayoutOptionValue) -> Bool {
    if case let .string(str) = value, str.hasSuffix("%") {
        return jsFlexBasisPercentValid(str.dropLast())
    }
    if case .undefined = value {
        return true
    }
    return isPositionType(value)
}

// parity: core/src/lib/renderable.validations.ts#isSizeType [status=implemented hash=9f3a2886d4f3]
public func isSizeType(_ value: LayoutOptionValue) -> Bool {
    switch value {
    case .undefined:
        return true
    case .null:
        return false
    case let .number(n):
        return !n.isNaN
    case .string:
        return isValidPercentage(value)
    }
}
