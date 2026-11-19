// Resource-limit guards for LaTeX parsing and macro expansion (`packages/latex/src/limits.ts`).

/// Default maximum accepted LaTeX source length in UTF-16 code units.
// parity: latex/src/limits.ts#DEFAULT_MAX_SOURCE_LENGTH [status=implemented hash=221e4de8967e]
public let DEFAULT_MAX_SOURCE_LENGTH: Int = 100_000

/// Default maximum structural brace/atom nesting depth.
// parity: latex/src/limits.ts#DEFAULT_MAX_NESTING_DEPTH [status=implemented hash=33c40e00edba]
public let DEFAULT_MAX_NESTING_DEPTH: Int = 256

private let latexMaxSafeInteger: Int64 = 9_007_199_254_740_991

/// Resolves an optional positive safe integer option, falling back to `fallback` when `nil`,
/// or throwing `LatexRangeError` if the value is not a positive safe integer.
// parity: latex/src/limits.ts#resolvePositiveInteger [status=implemented hash=07bcc93de384]
public func resolvePositiveInteger(_ value: Int?, fallback: Int, optionName: String) throws -> Int {
    guard let value else { return fallback }
    if value < 1 || Int64(value) > latexMaxSafeInteger {
        throw LatexRangeError("\(optionName) must be a positive safe integer")
    }
    return value
}

/// Validates that `source` does not exceed `maximum` UTF-16 code units.
// parity: latex/src/limits.ts#assertSourceLength [status=implemented hash=b3b552b880fa]
public func assertSourceLength(_ source: String, maximum: Int, label: String = "LaTeX source") throws {
    if source.utf16.count > maximum {
        throw LatexParseError("\(label) exceeds the \(maximum)-character limit", position: maximum)
    }
}

/// Scans unescaped `{` / `}` brace nesting in `source` (using UTF-16 offsets) and throws
/// `LatexParseError` if nesting exceeds `maximum` levels.
// parity: latex/src/limits.ts#assertNestingDepth [status=implemented hash=2babd576c014]
public func assertNestingDepth(_ source: String, maximum: Int) throws {
    var depth = 0
    var slashRun = 0
    var index = 0
    for unit in source.utf16 {
        if unit == 0x5C { // '\'
            slashRun += 1
            index += 1
            continue
        }
        let escaped = (slashRun % 2) == 1
        slashRun = 0
        if unit == 0x7B && !escaped { // '{'
            depth += 1
            if depth > maximum {
                throw LatexParseError("LaTeX nesting exceeds the \(maximum)-level limit", position: index)
            }
        } else if unit == 0x7D && !escaped { // '}'
            depth = max(0, depth - 1)
        }
        index += 1
    }
}
