public struct LineRangeSelection: Equatable, Sendable, Codable {
    public let start: Int
    public let end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

public struct ParsedPathLineSuffix: Equatable, Sendable, Codable {
    public let path: String
    public let selection: LineRangeSelection?

    public init(path: String, selection: LineRangeSelection?) {
        self.path = path
        self.selection = selection
    }
}

private let maxLineNumber = 1_000_000

// parity: util/src/path.ts#getFilename [status=implemented hash=edb8d7c47241]
public func getFilename(_ path: String?) -> String {
    guard let path, !path.isEmpty else { return "" }
    let trimmed = trimTrailingPathSeparators(path)
    let units = Array(trimmed.utf16)
    var lastSep = -1
    for i in 0..<units.count {
        if units[i] == 0x2F || units[i] == 0x5C {
            lastSep = i
        }
    }
    return utf16Slice(units, from: lastSep + 1, to: units.count)
}

// parity: util/src/path.ts#getDirectory [status=implemented hash=79b0d48bdffd]
public func getDirectory(_ path: String?) -> String {
    guard let path, !path.isEmpty else { return "" }
    let trimmed = trimTrailingPathSeparators(path)
    let parts = splitPathSeparators(trimmed)
    if parts.count <= 1 {
        return "/"
    }
    return parts.dropLast().joined(separator: "/") + "/"
}

// parity: util/src/path.ts#getFilenameTruncated [status=implemented hash=76a0ea5e3df6]
public func getFilenameTruncated(_ path: String?, maxLength: Int = 20) -> String {
    let filename = getFilename(path)
    let units = Array(filename.utf16)
    if units.count <= maxLength {
        return filename
    }
    var lastDot = -1
    for i in stride(from: units.count - 1, through: 0, by: -1) {
        if units[i] == 0x2E {
            lastDot = i
            break
        }
    }
    let extUnits: ArraySlice<UInt16> = lastDot <= 0 ? units[units.count..<units.count] : units[lastDot..<units.count]
    let available = maxLength - extUnits.count - 1
    if available <= 0 {
        let end = maxLength - 1 >= 0 ? min(units.count, maxLength - 1) : max(0, units.count + (maxLength - 1))
        return utf16Slice(units, from: 0, to: end) + "…"
    }
    return utf16Slice(units, from: 0, to: available) + "…" + String(decoding: extUnits, as: UTF16.self)
}

// parity: util/src/path.ts#truncateMiddle [status=implemented hash=9b3e9bc2f34f]
public func truncateMiddle(_ text: String, maxLength: Int = 20) -> String {
    if maxLength <= 0 { return "" }
    let units = Array(text.utf16)
    if units.count <= maxLength { return text }
    let available = maxLength - 1
    let start = (available + 1) / 2
    let end = available / 2
    if end <= 0 {
        return utf16Slice(units, from: 0, to: start) + "…"
    }
    return utf16Slice(units, from: 0, to: start) + "…" + utf16Slice(units, from: units.count - end, to: units.count)
}

// parity: util/src/path.ts#comparablePath [status=implemented hash=c32a2eb84da3]
public func comparablePath(_ path: String) -> String {
    let value = isWindowsPath(path) ? replaceBackslashes(path) : path
    let trimmed = trimTrailingForwardSlashes(value)
    if trimmed.isEmpty && value.hasPrefix("/") {
        return "/"
    }
    if isDrive(trimmed) {
        return "\(trimmed)/"
    }
    return trimmed
}

// parity: util/src/path.ts#containsDirectory [status=implemented hash=2d1040d78b3c]
public func containsDirectory(_ parent: String, _ child: String) -> Bool {
    func normalize(_ value: String) -> String {
        let key = comparablePath(value)
        if hasDriveSlashPrefix(key) || key.hasPrefix("//") {
            return key.lowercased()
        }
        return key
    }

    let root = normalize(parent)
    let target = normalize(child)
    let prefix = root.hasSuffix("/") ? root : "\(root)/"
    return target == root || target.hasPrefix(prefix)
}

// parity: util/src/path.ts#sameDirectory [status=implemented hash=8aabb2a3d470]
public func sameDirectory(_ a: String, _ b: String) -> Bool {
    containsDirectory(a, b) && containsDirectory(b, a)
}

// parity: util/src/path.ts#encodeFilePath [status=implemented hash=2abe2428bf2e]
public func encodeFilePath(_ filepath: String) -> String {
    let normalized = replaceBackslashes(filepath)
    let rooted = hasDrivePrefix(normalized) ? "/" + normalized : normalized
    let segments = rooted.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    return segments.enumerated().map { index, segment in
        if index == 1 && isDrive(segment) {
            return segment
        }
        return jsEncodeURIComponent(segment)
    }.joined(separator: "/")
}

// parity: util/src/path.ts#isLineRangeHash [status=implemented hash=6d276bb141cf]
public func isLineRangeHash(_ hash: String) -> Bool {
    parseLineRangeHashOnly(Array(hash.utf8)) != nil
}

// parity: util/src/path.ts#parsePathLineSuffix [status=implemented hash=05b60e446356]
public func parsePathLineSuffix(_ input: String) -> ParsedPathLineSuffix {
    let bytes = Array(input.utf8)

    // 1. Check `#L<first>(C<col>)?(-L?<second>(C<col>)?)?` (non-greedy prefix: first '#' whose tail matches)
    for i in 0..<bytes.count where bytes[i] == UInt8(ascii: "#") {
        if let pair = parseLineRangeHashOnly(Array(bytes[i...])) {
            let prefix = String(decoding: bytes[0..<i], as: UTF8.self)
            return ParsedPathLineSuffix(path: prefix, selection: toLineRange(pair.0, pair.1))
        }
    }

    // 2. Check `:<first>(:<col>)?(-<second>(:<col>)?)?:?` (non-greedy prefix: first ':' whose tail matches)
    for i in 0..<bytes.count where bytes[i] == UInt8(ascii: ":") {
        if let pair = parseColonLineRangeTail(Array(bytes[i...])) {
            let prefix = String(decoding: bytes[0..<i], as: UTF8.self)
            if !isSingleLetterOrDrive(prefix) {
                return ParsedPathLineSuffix(path: prefix, selection: toLineRange(pair.0, pair.1))
            }
        }
    }

    return ParsedPathLineSuffix(path: input, selection: nil)
}

// MARK: - Helpers

private func replaceBackslashes(_ value: String) -> String {
    var out: [UInt8] = []
    out.reserveCapacity(value.utf8.count)
    for byte in value.utf8 {
        out.append(byte == UInt8(ascii: "\\") ? UInt8(ascii: "/") : byte)
    }
    return String(decoding: out, as: UTF8.self)
}

private func isASCIILetter(_ byte: UInt8) -> Bool {
    (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
}

private func isASCIIDigit(_ byte: UInt8) -> Bool {
    byte >= 0x30 && byte <= 0x39
}

private func isDrive(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    return bytes.count == 2 && isASCIILetter(bytes[0]) && bytes[1] == UInt8(ascii: ":")
}

private func isSingleLetterOrDrive(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    if bytes.count == 1 {
        return isASCIILetter(bytes[0])
    }
    if bytes.count == 2 {
        return isASCIILetter(bytes[0]) && bytes[1] == UInt8(ascii: ":")
    }
    return false
}

private func hasDrivePrefix(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    return bytes.count >= 2 && isASCIILetter(bytes[0]) && bytes[1] == UInt8(ascii: ":")
}

private func hasDriveSlashPrefix(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    return bytes.count >= 3 && isASCIILetter(bytes[0]) && bytes[1] == UInt8(ascii: ":") && bytes[2] == UInt8(ascii: "/")
}

private func isWindowsPath(_ value: String) -> Bool {
    let units = Array(value.utf16)
    if units.count >= 2 && units[1] == 0x3A { return true }
    if units.count >= 2 && units[0] == 0x5C && units[1] == 0x5C { return true }
    return false
}

private func trimTrailingPathSeparators(_ value: String) -> String {
    let units = Array(value.utf16)
    var end = units.count
    while end > 0 && (units[end - 1] == 0x2F || units[end - 1] == 0x5C) {
        end -= 1
    }
    return utf16Slice(units, from: 0, to: end)
}

private func trimTrailingForwardSlashes(_ value: String) -> String {
    let units = Array(value.utf16)
    var end = units.count
    while end > 0 && units[end - 1] == 0x2F {
        end -= 1
    }
    return utf16Slice(units, from: 0, to: end)
}

private func splitPathSeparators(_ value: String) -> [String] {
    var parts: [String] = []
    var current: [UInt16] = []
    for unit in value.utf16 {
        if unit == 0x2F || unit == 0x5C {
            parts.append(String(decoding: current, as: UTF16.self))
            current.removeAll(keepingCapacity: true)
        } else {
            current.append(unit)
        }
    }
    parts.append(String(decoding: current, as: UTF16.self))
    return parts
}

private func utf16Slice(_ units: [UInt16], from start: Int, to end: Int) -> String {
    let clampedStart = max(0, min(start, units.count))
    let clampedEnd = max(clampedStart, min(end, units.count))
    return String(decoding: units[clampedStart..<clampedEnd], as: UTF16.self)
}

private let upperHex: [UInt8] = Array("0123456789ABCDEF".utf8)

/// Matches ECMA-262 `encodeURIComponent` exactly.
private func jsEncodeURIComponent(_ value: String) -> String {
    var out: [UInt8] = []
    out.reserveCapacity(value.utf8.count)
    for byte in value.utf8 {
        if isURIComponentUnescaped(byte) {
            out.append(byte)
        } else {
            out.append(UInt8(ascii: "%"))
            out.append(upperHex[Int(byte >> 4)])
            out.append(upperHex[Int(byte & 0x0F)])
        }
    }
    return String(decoding: out, as: UTF8.self)
}

private func isURIComponentUnescaped(_ byte: UInt8) -> Bool {
    if isASCIILetter(byte) || isASCIIDigit(byte) { return true }
    switch byte {
    case UInt8(ascii: "-"),
         UInt8(ascii: "_"),
         UInt8(ascii: "."),
         UInt8(ascii: "!"),
         UInt8(ascii: "~"),
         UInt8(ascii: "*"),
         UInt8(ascii: "'"),
         UInt8(ascii: "("),
         UInt8(ascii: ")"):
        return true
    default:
        return false
    }
}

private func parseDigits(_ bytes: [UInt8], index: inout Int) -> Int? {
    let start = index
    var acc: Int = 0
    var overflow = false
    while index < bytes.count && isASCIIDigit(bytes[index]) {
        let digit = Int(bytes[index] - 0x30)
        if acc > (Int.max - digit) / 10 {
            overflow = true
        } else if !overflow {
            acc = acc * 10 + digit
        }
        index += 1
    }
    if index == start { return nil }
    return overflow ? Int.max : acc
}

/// Parses `^#L(\d+)(?:C\d+)?(?:-L?(\d+)(?:C\d+)?)?$` (case-insensitive).
private func parseLineRangeHashOnly(_ bytes: [UInt8]) -> (Int, Int)? {
    var i = 0
    guard i + 2 < bytes.count else { return nil }
    guard bytes[i] == UInt8(ascii: "#") else { return nil }
    i += 1
    guard bytes[i] == UInt8(ascii: "L") || bytes[i] == UInt8(ascii: "l") else { return nil }
    i += 1
    guard let first = parseDigits(bytes, index: &i) else { return nil }

    if i < bytes.count && (bytes[i] == UInt8(ascii: "C") || bytes[i] == UInt8(ascii: "c")) {
        i += 1
        guard parseDigits(bytes, index: &i) != nil else { return nil }
    }

    var second = first
    if i < bytes.count && bytes[i] == UInt8(ascii: "-") {
        i += 1
        if i < bytes.count && (bytes[i] == UInt8(ascii: "L") || bytes[i] == UInt8(ascii: "l")) {
            i += 1
        }
        guard let parsedSecond = parseDigits(bytes, index: &i) else { return nil }
        second = parsedSecond
        if i < bytes.count && (bytes[i] == UInt8(ascii: "C") || bytes[i] == UInt8(ascii: "c")) {
            i += 1
            guard parseDigits(bytes, index: &i) != nil else { return nil }
        }
    }

    guard i == bytes.count else { return nil }
    return (first, second)
}

/// Parses `^:(\d+)(?::\d+)?(?:-(\d+)(?::\d+)?)?:?$`
private func parseColonLineRangeTail(_ bytes: [UInt8]) -> (Int, Int)? {
    var i = 0
    guard i + 1 < bytes.count, bytes[i] == UInt8(ascii: ":") else { return nil }
    i += 1
    guard let first = parseDigits(bytes, index: &i) else { return nil }

    if i < bytes.count && bytes[i] == UInt8(ascii: ":") {
        let saved = i
        i += 1
        if parseDigits(bytes, index: &i) == nil {
            i = saved
        }
    }

    var second = first
    if i < bytes.count && bytes[i] == UInt8(ascii: "-") {
        i += 1
        guard let parsedSecond = parseDigits(bytes, index: &i) else { return nil }
        second = parsedSecond
        if i < bytes.count && bytes[i] == UInt8(ascii: ":") {
            let saved = i
            i += 1
            if parseDigits(bytes, index: &i) == nil {
                i = saved
            }
        }
    }

    if i < bytes.count && bytes[i] == UInt8(ascii: ":") {
        i += 1
    }

    guard i == bytes.count else { return nil }
    return (first, second)
}

private func toLineRange(_ first: Int, _ second: Int) -> LineRangeSelection? {
    if first < 1 || second < 1 || first > maxLineNumber || second > maxLineNumber {
        return nil
    }
    return LineRangeSelection(start: min(first, second), end: max(first, second))
}
