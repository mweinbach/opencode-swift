/// Parsed terminal pixel resolution from `ESC[4;height;widtht`.
public struct PixelResolution: Equatable, Hashable, Sendable, Codable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

private let escByte: UInt8 = 0x1B
private let belByte: UInt8 = 0x07
private let maxPixelDimension: Int = 0x7FFF_FFFF

private let xtgettcapTargets: [[UInt8]] = [
    Array("4d73".utf8),
    Array("524742".utf8),
    Array("5463".utf8),
]
private let kittyNotifyIdBytes: [UInt8] = Array("i=opentui-notifications".utf8)
private let kittyNotifyQueryBytes: [UInt8] = Array("p=?".utf8)
private let itermCapabilitiesPrefix: [UInt8] = Array("1337;Capabilities=".utf8)
private let osc7501Prefix: [UInt8] = Array("7501;".utf8)

@inline(__always)
private func isASCIIDigit(_ byte: UInt8) -> Bool {
    byte >= 0x30 && byte <= 0x39
}

@inline(__always)
private func asciiLowerByte(_ byte: UInt8) -> UInt8 {
    (byte >= 0x41 && byte <= 0x5A) ? (byte + 32) : byte
}

@inline(__always)
private func matchesBytes(_ bytes: [UInt8], at index: Int, pattern: [UInt8]) -> Bool {
    guard index + pattern.count <= bytes.count else { return false }
    for offset in 0..<pattern.count {
        if bytes[index + offset] != pattern[offset] {
            return false
        }
    }
    return true
}

@inline(__always)
private func matchesBytesCaseInsensitive(_ bytes: [UInt8], at index: Int, lowerPattern: [UInt8]) -> Bool {
    guard index + lowerPattern.count <= bytes.count else { return false }
    for offset in 0..<lowerPattern.count {
        if asciiLowerByte(bytes[index + offset]) != lowerPattern[offset] {
            return false
        }
    }
    return true
}

@inline(__always)
private func isST(_ bytes: [UInt8], at index: Int) -> Bool {
    index + 1 < bytes.count && bytes[index] == escByte && bytes[index + 1] == UInt8(ascii: "\\")
}

@inline(__always)
private func containsST(_ bytes: [UInt8], from start: Int) -> Bool {
    guard start + 1 < bytes.count else { return false }
    var i = start
    let limit = bytes.count - 1
    while i < limit {
        if bytes[i] == escByte && bytes[i + 1] == UInt8(ascii: "\\") {
            return true
        }
        i += 1
    }
    return false
}

@inline(__always)
private func containsBELOrST(_ bytes: [UInt8], from start: Int) -> Bool {
    var i = start
    let count = bytes.count
    while i < count {
        let b = bytes[i]
        if b == belByte {
            return true
        }
        if b == escByte && i + 1 < count && bytes[i + 1] == UInt8(ascii: "\\") {
            return true
        }
        i += 1
    }
    return false
}

/// Finds `pattern` starting at or after `start` before any `BEL` (0x07) or `ESC` (0x1B).
/// Returns the index immediately after the matched pattern, or `nil`.
private func findBeforeControl(_ bytes: [UInt8], from start: Int, pattern: [UInt8]) -> Int? {
    let count = bytes.count
    let pCount = pattern.count
    var end = start
    while end < count && bytes[end] != belByte && bytes[end] != escByte {
        end += 1
    }
    guard start + pCount <= end else { return nil }
    let lastStart = end - pCount
    var i = start
    while i <= lastStart {
        var matched = true
        for j in 0..<pCount {
            if bytes[i + j] != pattern[j] {
                matched = false
                break
            }
        }
        if matched {
            return i + pCount
        }
        i += 1
    }
    return nil
}

/// Checks DECRPM (`ESC[?digits(;digits)*$y`), Kitty keyboard (`ESC[?digits(;digits)?u`),
/// and DA1 (`ESC[?[0-9;]*c`) starting at `escIndex` (where `bytes[escIndex] == 0x1B`).
private func matchesCSICapability(_ bytes: [UInt8], at escIndex: Int) -> Bool {
    let count = bytes.count
    guard escIndex + 3 < count,
          bytes[escIndex + 1] == UInt8(ascii: "["),
          bytes[escIndex + 2] == UInt8(ascii: "?")
    else {
        return false
    }

    let bodyStart = escIndex + 3

    // 1. DECRPM: ESC[?\d+(?:;\d+)*$y
    do {
        var j = bodyStart
        if j < count && isASCIIDigit(bytes[j]) {
            while j < count && isASCIIDigit(bytes[j]) { j += 1 }
            while j < count && bytes[j] == UInt8(ascii: ";") {
                let next = j + 1
                guard next < count && isASCIIDigit(bytes[next]) else { break }
                j = next
                while j < count && isASCIIDigit(bytes[j]) { j += 1 }
            }
            if j + 1 < count && bytes[j] == UInt8(ascii: "$") && bytes[j + 1] == UInt8(ascii: "y") {
                return true
            }
        }
    }

    // 2. Kitty keyboard query response: ESC[?\d+(?:;\d+)?u
    do {
        var j = bodyStart
        if j < count && isASCIIDigit(bytes[j]) {
            while j < count && isASCIIDigit(bytes[j]) { j += 1 }
            if j < count && bytes[j] == UInt8(ascii: ";") {
                let next = j + 1
                if next < count && isASCIIDigit(bytes[next]) {
                    j = next
                    while j < count && isASCIIDigit(bytes[j]) { j += 1 }
                }
            }
            if j < count && bytes[j] == UInt8(ascii: "u") {
                return true
            }
        }
    }

    // 3. DA1: ESC[?[0-9;]*c
    do {
        var j = bodyStart
        while j < count && (isASCIIDigit(bytes[j]) || bytes[j] == UInt8(ascii: ";")) {
            j += 1
        }
        if j < count && bytes[j] == UInt8(ascii: "c") {
            return true
        }
    }

    return false
}

/// Checks XTVersion (`ESC P >| ... ST`) and XTGETTCAP (`ESC P (1+r...|0+r...) ST` case-insensitive).
private func matchesDCSCapability(_ bytes: [UInt8], at escIndex: Int) -> Bool {
    let count = bytes.count
    guard escIndex + 1 < count else { return false }
    let dcsByte = bytes[escIndex + 1]

    // XTVersion: \x1bP>\|[\s\S]*?\x1b\\
    if dcsByte == UInt8(ascii: "P"),
       escIndex + 3 < count,
       bytes[escIndex + 2] == UInt8(ascii: ">"),
       bytes[escIndex + 3] == UInt8(ascii: "|")
    {
        if containsST(bytes, from: escIndex + 4) {
            return true
        }
    }

    // XTGETTCAP: \x1bP(?:1\+r(?:4d73|524742|5463)(?:=[^\x1b]*)?|0\+r(?:4d73|524742|5463)?)\x1b\\ /i
    if asciiLowerByte(dcsByte) == UInt8(ascii: "p"),
       escIndex + 4 < count,
       bytes[escIndex + 3] == UInt8(ascii: "+"),
       asciiLowerByte(bytes[escIndex + 4]) == UInt8(ascii: "r")
    {
        let status = bytes[escIndex + 2]
        var j = escIndex + 5

        if status == UInt8(ascii: "1") {
            var matchedLen = 0
            for target in xtgettcapTargets {
                if matchesBytesCaseInsensitive(bytes, at: j, lowerPattern: target) {
                    matchedLen = target.count
                    break
                }
            }
            if matchedLen > 0 {
                j += matchedLen
                if j < count && bytes[j] == UInt8(ascii: "=") {
                    j += 1
                    while j < count && bytes[j] != escByte {
                        j += 1
                    }
                }
                if isST(bytes, at: j) {
                    return true
                }
            }
        } else if status == UInt8(ascii: "0") {
            for target in xtgettcapTargets {
                if matchesBytesCaseInsensitive(bytes, at: j, lowerPattern: target) {
                    j += target.count
                    break
                }
            }
            if isST(bytes, at: j) {
                return true
            }
        }
    }

    return false
}

/// Checks OSC 99 notification capability, iTerm2 OSC 1337 Capabilities, and OSC 7501 status query replies.
private func matchesOSCCapability(_ bytes: [UInt8], at escIndex: Int) -> Bool {
    let count = bytes.count
    guard escIndex + 2 < count, bytes[escIndex + 1] == UInt8(ascii: "]") else {
        return false
    }
    let bodyStart = escIndex + 2

    // Kitty desktop notification capability query response:
    // \x1b\]99;[^\x07\x1b]*i=opentui-notifications[^\x07\x1b]*p=\?[\s\S]*?(?:\x07|\x1b\\)
    if bodyStart + 3 <= count,
       bytes[bodyStart] == UInt8(ascii: "9"),
       bytes[bodyStart + 1] == UInt8(ascii: "9"),
       bytes[bodyStart + 2] == UInt8(ascii: ";")
    {
        if let afterId = findBeforeControl(bytes, from: bodyStart + 3, pattern: kittyNotifyIdBytes),
           let afterQuery = findBeforeControl(bytes, from: afterId, pattern: kittyNotifyQueryBytes),
           containsBELOrST(bytes, from: afterQuery)
        {
            return true
        }
    }

    // iTerm2 feature reporting response:
    // \x1b\]1337;Capabilities=[\s\S]*?(?:\x07|\x1b\\)
    if matchesBytes(bytes, at: bodyStart, pattern: itermCapabilitiesPrefix) {
        if containsBELOrST(bytes, from: bodyStart + itermCapabilitiesPrefix.count) {
            return true
        }
    }

    // OSC 7501 program status query response:
    // \x1b\]7501; *\?[^\x07\x1b]*(?:\x07|\x1b\\)
    if matchesBytes(bytes, at: bodyStart, pattern: osc7501Prefix) {
        var j = bodyStart + osc7501Prefix.count
        while j < count && bytes[j] == UInt8(ascii: " ") {
            j += 1
        }
        if j < count && bytes[j] == UInt8(ascii: "?") {
            j += 1
            while j < count && bytes[j] != belByte && bytes[j] != escByte {
                j += 1
            }
            if j < count && (bytes[j] == belByte || isST(bytes, at: j)) {
                return true
            }
        }
    }

    return false
}

/// Checks if a sequence contains any known terminal capability response pattern.
// parity: core/src/lib/terminal-capability-detection.ts#isCapabilityResponse [status=implemented hash=12eb018b164c]
public func isCapabilityResponse(_ sequence: String) -> Bool {
    let bytes = Array(sequence.utf8)
    let count = bytes.count
    var i = 0

    while i < count {
        if bytes[i] == escByte {
            if matchesCSICapability(bytes, at: i) {
                return true
            }
            if matchesDCSCapability(bytes, at: i) {
                return true
            }
            // Kitty graphics response: \x1b_G[\s\S]*?\x1b\\
            if i + 2 < count,
               bytes[i + 1] == UInt8(ascii: "_"),
               bytes[i + 2] == UInt8(ascii: "G"),
               containsST(bytes, from: i + 3)
            {
                return true
            }
            if matchesOSCCapability(bytes, at: i) {
                return true
            }
        }
        i += 1
    }

    return false
}

/// Checks if a cursor position report answers the explicit width or scaled text probe (`ESC[2;2R` or `ESC[2;3R`).
// parity: core/src/lib/terminal-capability-detection.ts#isExplicitWidthReport [status=implemented hash=5b36af30316a]
public func isExplicitWidthReport(_ sequence: String) -> Bool {
    let bytes = Array(sequence.utf8)
    guard bytes.count >= 6 else { return false }
    let limit = bytes.count - 6
    var i = 0
    while i <= limit {
        if bytes[i] == escByte
            && bytes[i + 1] == UInt8(ascii: "[")
            && bytes[i + 2] == UInt8(ascii: "2")
            && bytes[i + 3] == UInt8(ascii: ";")
            && (bytes[i + 4] == UInt8(ascii: "2") || bytes[i + 4] == UInt8(ascii: "3"))
            && bytes[i + 5] == UInt8(ascii: "R")
        {
            return true
        }
        i += 1
    }
    return false
}

/// Finds the first match of `ESC[4;(\d+);(\d+)t` in `bytes` and returns the byte ranges of height and width digits.
private func findPixelResolutionDigitRanges(_ bytes: [UInt8]) -> (height: Range<Int>, width: Range<Int>)? {
    let count = bytes.count
    guard count >= 8 else { return nil }
    var i = 0
    while i + 4 < count {
        if bytes[i] == escByte
            && bytes[i + 1] == UInt8(ascii: "[")
            && bytes[i + 2] == UInt8(ascii: "4")
            && bytes[i + 3] == UInt8(ascii: ";")
        {
            let hStart = i + 4
            var j = hStart
            while j < count && isASCIIDigit(bytes[j]) { j += 1 }
            if j > hStart && j < count && bytes[j] == UInt8(ascii: ";") {
                let hEnd = j
                let wStart = j + 1
                j = wStart
                while j < count && isASCIIDigit(bytes[j]) { j += 1 }
                if j > wStart && j < count && bytes[j] == UInt8(ascii: "t") {
                    return (height: hStart..<hEnd, width: wStart..<j)
                }
            }
        }
        i += 1
    }
    return nil
}

private func parseBoundedDecimal(_ bytes: [UInt8], range: Range<Int>) -> Int? {
    var value = 0
    for idx in range {
        let digit = Int(bytes[idx] - 0x30)
        if value > (maxPixelDimension - digit) / 10 {
            return nil
        }
        value = value * 10 + digit
    }
    return value
}

/// Checks if a sequence contains a pixel resolution response (`ESC[4;height;widtht`).
// parity: core/src/lib/terminal-capability-detection.ts#isPixelResolutionResponse [status=implemented hash=017692b5a4af]
public func isPixelResolutionResponse(_ sequence: String) -> Bool {
    findPixelResolutionDigitRanges(Array(sequence.utf8)) != nil
}

/// Parses pixel resolution `{ width, height }` from `ESC[4;height;widtht`, returning `nil` if invalid or out of Int32 range.
// parity: core/src/lib/terminal-capability-detection.ts#parsePixelResolution [status=implemented hash=46e5fb0488e8]
public func parsePixelResolution(_ sequence: String) -> PixelResolution? {
    let bytes = Array(sequence.utf8)
    guard let ranges = findPixelResolutionDigitRanges(bytes) else {
        return nil
    }
    guard let height = parseBoundedDecimal(bytes, range: ranges.height),
          let width = parseBoundedDecimal(bytes, range: ranges.width)
    else {
        return nil
    }
    return PixelResolution(width: width, height: height)
}
