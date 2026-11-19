/// Errors thrown during QR Code encoding and rendering.
public enum QRCodeError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    case invalidVersion(Int)
    case invalidVersionRange(min: Int, max: Int)
    case invalidMask(Int)
    case invalidBitAppend(String)
    case invalidNumericInput
    case invalidAlphanumericInput
    case invalidByteValue(Int)
    case unsupportedEncoding(String)
    case unencodableCharacter(String)
    case invalidKanjiBytes(String)
    case invalidEciAssignment(Int)
    case invalidEciEscape
    case invalidStructuredAppend(String)
    case invalidFnc1Configuration(String)
    case invalidGs1AI(String)
    case invalidSegmentOrder(String)
    case dataTooLong
    case outOfBounds(x: Int, y: Int, size: Int)
    case invalidBorder(Int, minimum: Int)
    case invalidModuleSize(Int)
    case internalError(String)

    public var description: String {
        switch self {
        case .invalidVersion(let v): return "Version must be in 1..40 (got \(v))"
        case .invalidVersionRange(let min, let max): return "minVersion (\(min)) cannot exceed maxVersion (\(max))"
        case .invalidMask(let m): return "Mask must be in 0..7 (got \(m))"
        case .invalidBitAppend(let msg): return msg
        case .invalidNumericInput: return "Numeric mode accepts digits only"
        case .invalidAlphanumericInput: return "Alphanumeric mode accepts only: 0-9 A-Z space $%*+-./:"
        case .invalidByteValue(let v): return "Byte value out of range: \(v)"
        case .unsupportedEncoding(let msg): return msg
        case .unencodableCharacter(let msg): return msg
        case .invalidKanjiBytes(let msg): return msg
        case .invalidEciAssignment(let v): return "ECI assignment value must be in 0..999999 (got \(v))"
        case .invalidEciEscape: return "Single backslash in ECI text must be followed by six digits or another backslash"
        case .invalidStructuredAppend(let msg): return msg
        case .invalidFnc1Configuration(let msg): return msg
        case .invalidGs1AI(let msg): return msg
        case .invalidSegmentOrder(let msg): return msg
        case .dataTooLong: return "Data too long for requested QR Code version range and error correction level"
        case .outOfBounds(let x, let y, let size): return "Module coordinates (\(x), \(y)) out of bounds for size \(size)"
        case .invalidBorder(let b, let min): return "Border/quiet zone must be at least \(min) modules (got \(b))"
        case .invalidModuleSize(let s): return "moduleSize must be positive (got \(s))"
        case .internalError(let msg): return "Internal error: \(msg)"
        }
    }
}

// MARK: - Encoding Helpers

/// Supported byte-segment text encodings for QR Code encoding.
// parity: qrcode/src/lib/qrcode.encoding.ts#ByteEncoding [status=implemented hash=96466b3f7397]
public enum ByteEncoding: String, Equatable, Hashable, Sendable, Codable {
    case utf8 = "utf-8"
    case iso8859_1 = "iso-8859-1"
    case shiftJis = "shift-jis"
}

/// Standard ECI assignment numbers defined by ISO/IEC 18004.
// parity: qrcode/src/lib/qrcode.encoding.ts#EciAssignment [status=implemented hash=251d4f82a036]
public enum EciAssignment {
    public static let iso8859_1: Int = 3
    public static let shiftJis: Int = 20
    public static let utf8: Int = 26
}

/// Encodes `text` into bytes using the requested `ByteEncoding`.
// parity: qrcode/src/lib/qrcode.encoding.ts#encodeTextBytes [status=implemented hash=d1678e2e8bdc]
public func encodeTextBytes(_ text: String, encoding: ByteEncoding = .utf8) throws(QRCodeError) -> [UInt8] {
    switch encoding {
    case .utf8:
        return Array(text.utf8)
    case .iso8859_1:
        var result: [UInt8] = []
        result.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            guard scalar.value <= 0xFF else {
                throw .unencodableCharacter("Character \(scalar) is not encodable in ISO-8859-1")
            }
            result.append(UInt8(scalar.value))
        }
        return result
    case .shiftJis:
        var result: [UInt8] = []
        result.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            guard let code = shiftJisCodeForCharacter(scalar) else {
                throw .unencodableCharacter("Character \"\(scalar)\" is not encodable in Shift JIS")
            }
            if code <= 0xFF {
                result.append(UInt8(code))
            } else {
                result.append(UInt8((code >> 8) & 0xFF))
                result.append(UInt8(code & 0xFF))
            }
        }
        return result
    }
}

/// Returns true when a 16-bit Shift JIS value lies in the QR Code Kanji-mode ranges.
// parity: qrcode/src/lib/qrcode.encoding.ts#isKanjiModeShiftJisValue [status=implemented hash=8f800bcc9a6a]
public func isKanjiModeShiftJisValue(_ value: Int) -> Bool {
    (value >= 0x8140 && value <= 0x9FFC) || (value >= 0xE040 && value <= 0xEBBF)
}

/// Maps known ECI assignment numbers to their corresponding `ByteEncoding`.
// parity: qrcode/src/lib/qrcode.encoding.ts#encodingForKnownEci [status=implemented hash=8a7ea9151d79]
public func encodingForKnownEci(_ eci: Int) -> ByteEncoding? {
    if eci == EciAssignment.iso8859_1 { return .iso8859_1 }
    if eci == EciAssignment.shiftJis { return .shiftJis }
    if eci == EciAssignment.utf8 { return .utf8 }
    return nil
}

/// Validates that every integer in `bytes` is in `0...255` and returns `[UInt8]`.
// parity: qrcode/src/lib/qrcode.encoding.ts#validateBytes [status=implemented hash=a83938267849]
public func validateBytes(_ bytes: [Int]) throws(QRCodeError) -> [UInt8] {
    var result: [UInt8] = []
    result.reserveCapacity(bytes.count)
    for b in bytes {
        guard b >= 0 && b <= 0xFF else {
            throw .invalidByteValue(b)
        }
        result.append(UInt8(b))
    }
    return result
}

/// Converts ASCII text into its byte values.
// parity: qrcode/src/lib/qrcode.encoding.ts#asciiBytes [status=implemented hash=2af2bb12484c]
public func asciiBytes(_ text: String) -> [UInt8] {
    Array(text.utf8)
}

// MARK: - Terminal & SVG Renderers

/// Options for rendering a QR matrix to terminal text.
// parity: qrcode/src/lib/qrcode.render.ts#TerminalRenderOptions [status=implemented hash=65a8f667c8ff]
public struct TerminalRenderOptions: Equatable, Hashable, Sendable, Codable {
    public let border: Int?
    public let ansi: Bool
    public let invert: Bool

    public init(border: Int? = nil, ansi: Bool = false, invert: Bool = false) {
        self.border = border
        self.ansi = ansi
        self.invert = invert
    }
}

/// Normalized options for terminal rendering.
// parity: qrcode/src/lib/qrcode.render.ts#NormalizedTerminalRenderOptions [status=implemented hash=3b65f410fb94]
public struct NormalizedTerminalRenderOptions: Equatable, Hashable, Sendable, Codable {
    public let border: Int
    public let ansi: Bool
    public let invert: Bool

    public init(border: Int, ansi: Bool, invert: Bool) {
        self.border = border
        self.ansi = ansi
        self.invert = invert
    }
}

/// Validates and fills defaults for `TerminalRenderOptions`.
// parity: qrcode/src/lib/qrcode.render.ts#normalizeTerminalOptions [status=implemented hash=501f7bd9db10]
public func normalizeTerminalOptions(
    _ options: TerminalRenderOptions = TerminalRenderOptions(),
    defaultBorder: Int = 4,
    minimumBorder: Int = 4
) throws(QRCodeError) -> NormalizedTerminalRenderOptions {
    let border = options.border ?? defaultBorder
    guard border >= minimumBorder else {
        throw .invalidBorder(border, minimum: minimumBorder)
    }
    return NormalizedTerminalRenderOptions(border: border, ansi: options.ansi, invert: options.invert)
}

/// Renders a QR boolean matrix as an SVG document with horizontal run-length paths.
// parity: qrcode/src/lib/qrcode.render.ts#matrixToSvg [status=implemented hash=1b1c34ca7b32]
public func matrixToSvg(
    _ matrix: [[Bool]],
    border: Int = 4,
    minimumBorder: Int = 4,
    moduleSize: Int = 1,
    lightColor: String = "#FFFFFF",
    darkColor: String = "#000000"
) throws(QRCodeError) -> String {
    guard border >= minimumBorder else {
        throw .invalidBorder(border, minimum: minimumBorder)
    }
    guard moduleSize > 0 else {
        throw .invalidModuleSize(moduleSize)
    }
    let size = matrix.count
    let dimension = (size + border * 2) * moduleSize
    var parts: [String] = []
    parts.append(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(dimension) \(dimension)\" width=\"\(dimension)\" height=\"\(dimension)\" shape-rendering=\"crispEdges\">"
    )
    parts.append("<rect width=\"100%\" height=\"100%\" fill=\"\(escapeQRXml(lightColor))\"/>")

    var pathParts: [String] = []
    for y in 0..<size {
        var x = 0
        while x < size {
            if !matrix[y][x] {
                x += 1
                continue
            }
            let startX = x
            while x < size && matrix[y][x] { x += 1 }
            let rectX = (startX + border) * moduleSize
            let rectY = (y + border) * moduleSize
            let rectW = (x - startX) * moduleSize
            pathParts.append("M\(rectX),\(rectY)h\(rectW)v\(moduleSize)h-\(rectW)z")
        }
    }
    parts.append("<path d=\"\(pathParts.joined())\" fill=\"\(escapeQRXml(darkColor))\"/>")
    parts.append("</svg>")
    return parts.joined()
}

/// Renders a QR boolean matrix as full-block (`██` / `  `) terminal text, with optional ANSI backgrounds.
// parity: qrcode/src/lib/qrcode.render.ts#matrixToTerminal [status=implemented hash=7e5503f8062b]
public func matrixToTerminal(
    _ matrix: [[Bool]],
    options: NormalizedTerminalRenderOptions
) -> String {
    let size = matrix.count
    let darkText = options.invert ? "  " : "██"
    let lightText = options.invert ? "██" : "  "
    let darkAnsi = options.invert ? "\u{1B}[47m  " : "\u{1B}[40m  "
    let lightAnsi = options.invert ? "\u{1B}[40m  " : "\u{1B}[47m  "
    var lines: [String] = []
    lines.reserveCapacity(size + options.border * 2)

    for y in (-options.border)..<(size + options.border) {
        var line = ""
        for x in (-options.border)..<(size + options.border) {
            let dark = x >= 0 && y >= 0 && x < size && y < size && matrix[y][x]
            if options.ansi {
                line += dark ? darkAnsi : lightAnsi
            } else {
                line += dark ? darkText : lightText
            }
        }
        lines.append(options.ansi ? "\(line)\u{1B}[0m" : line)
    }
    return lines.joined(separator: "\n")
}

/// Renders a QR boolean matrix using compact Unicode half-block characters (`█`, `▀`, `▄`, ` `),
/// packing two vertical modules per terminal row (matching `QRCodeRenderable`'s block glyph mapping).
public func matrixToHalfBlockTerminal(
    _ matrix: [[Bool]],
    border: Int = 4,
    minimumBorder: Int = 4,
    invert: Bool = false
) throws(QRCodeError) -> String {
    guard border >= minimumBorder else {
        throw .invalidBorder(border, minimum: minimumBorder)
    }
    let size = matrix.count
    let total = size + border * 2
    var lines: [String] = []
    lines.reserveCapacity((total + 1) / 2)

    func isDark(_ mx: Int, _ my: Int) -> Bool {
        let raw = mx >= 0 && my >= 0 && mx < size && my < size && matrix[my][mx]
        return invert ? !raw : raw
    }

    var row = 0
    while row < total {
        let topY = row - border
        let bottomY = row + 1 - border
        let hasBottom = (row + 1) < total
        var line = ""
        line.reserveCapacity(total)
        for col in 0..<total {
            let x = col - border
            let top = isDark(x, topY)
            let bottom = hasBottom ? isDark(x, bottomY) : invert
            switch (top, bottom) {
            case (true, true): line.append("█")
            case (true, false): line.append("▀")
            case (false, true): line.append("▄")
            case (false, false): line.append(" ")
            }
        }
        lines.append(line)
        row += 2
    }

    return lines.joined(separator: "\n")
}

private func escapeQRXml(_ value: String) -> String {
    var out = ""
    out.reserveCapacity(value.count)
    for ch in value {
        switch ch {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "'": out += "&apos;"
        case "\"": out += "&quot;"
        default: out.append(ch)
        }
    }
    return out
}

// MARK: - QR Code Model 2 Types

/// QR Code error correction level.
// parity: qrcode/src/lib/qrcode.ts#ErrorCorrectionLevel [status=implemented hash=de08ddf04520]
public enum ErrorCorrectionLevel: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
    /// Recovers about 7% data damage. QR format bits: 01.
    case L
    /// Recovers about 15% data damage. QR format bits: 00.
    case M
    /// Recovers about 25% data damage. QR format bits: 11.
    case Q
    /// Recovers about 30% data damage. QR format bits: 10.
    case H

    var eclIndex: Int {
        switch self {
        case .L: return 0
        case .M: return 1
        case .Q: return 2
        case .H: return 3
        }
    }

    var formatBits: Int {
        switch self {
        case .M: return 0b00
        case .L: return 0b01
        case .H: return 0b10
        case .Q: return 0b11
        }
    }
}

/// Structured append header metadata.
// parity: qrcode/src/lib/qrcode.ts#StructuredAppendInfo [status=implemented hash=0ef9c44bc8c6]
public struct StructuredAppendInfo: Equatable, Hashable, Sendable, Codable {
    public let position: Int
    public let total: Int
    public let parity: Int

    public init(position: Int, total: Int, parity: Int) {
        self.position = position
        self.total = total
        self.parity = parity
    }
}

/// FNC1 second-position application indicator.
// parity: qrcode/src/lib/qrcode.ts#Fnc1SecondPositionInfo [status=implemented hash=3d707d1b5117]
public struct Fnc1SecondPositionInfo: Equatable, Hashable, Sendable, Codable {
    public enum Indicator: Equatable, Hashable, Sendable, Codable {
        case number(Int)
        case text(String)
    }

    public let applicationIndicator: Indicator

    public init(applicationIndicator: Int) {
        self.applicationIndicator = .number(applicationIndicator)
    }

    public init(applicationIndicator: String) {
        self.applicationIndicator = .text(applicationIndicator)
    }
}

/// Encoding options for QR Code Model 2 generation.
// parity: qrcode/src/lib/qrcode.ts#EncodeOptions [status=implemented hash=6f24aff1bc9b]
public struct EncodeOptions: Equatable, Hashable, Sendable {
    public enum EciOverride: Equatable, Hashable, Sendable {
        case automatic
        case suppress
        case assignment(Int)
    }

    public var minVersion: Int
    public var maxVersion: Int
    public var mask: Int
    public var boostEcl: Bool
    public var optimize: Bool
    public var kanji: Bool
    public var byteEncoding: ByteEncoding
    public var eciForUtf8: Bool
    public var eciOverride: EciOverride
    public var fnc1First: Bool
    public var fnc1Second: Fnc1SecondPositionInfo?
    public var structuredAppend: StructuredAppendInfo?

    public init(
        minVersion: Int = 1,
        maxVersion: Int = 40,
        mask: Int = -1,
        boostEcl: Bool = true,
        optimize: Bool = true,
        kanji: Bool = false,
        byteEncoding: ByteEncoding = .utf8,
        eciForUtf8: Bool = true,
        eciOverride: EciOverride = .automatic,
        fnc1First: Bool = false,
        fnc1Second: Fnc1SecondPositionInfo? = nil,
        structuredAppend: StructuredAppendInfo? = nil
    ) {
        self.minVersion = minVersion
        self.maxVersion = maxVersion
        self.mask = mask
        self.boostEcl = boostEcl
        self.optimize = optimize
        self.kanji = kanji
        self.byteEncoding = byteEncoding
        self.eciForUtf8 = eciForUtf8
        self.eciOverride = eciOverride
        self.fnc1First = fnc1First
        self.fnc1Second = fnc1Second
        self.structuredAppend = structuredAppend
    }
}

/// GS1 element string entry for FNC1 first-position encoding.
// parity: qrcode/src/lib/qrcode.ts#Gs1Element [status=implemented hash=7341ad091178]
public struct Gs1Element: Equatable, Hashable, Sendable, Codable {
    public let ai: String
    public let data: String
    public let separatorAfter: Bool

    public init(ai: String, data: String, separatorAfter: Bool = false) {
        self.ai = ai
        self.data = data
        self.separatorAfter = separatorAfter
    }
}

/// FNC1 indicator state reported by an encoded `QRCode`.
public enum QRFnc1Mode: String, Equatable, Hashable, Sendable, Codable {
    case none
    case first
    case second
}

/// Bit-level buffer for QR segment and data-codeword construction.
public struct QRBitBuffer: Equatable, Hashable, Sendable {
    public private(set) var bits: [UInt8] = []

    public init() {}

    public var length: Int { bits.count }

    public mutating func appendBits(_ value: Int, bitCount: Int) throws(QRCodeError) {
        guard bitCount >= 0 && bitCount <= 31 else {
            throw .invalidBitAppend("Invalid bit count: \(bitCount)")
        }
        guard value >= 0 else {
            throw .invalidBitAppend("Negative value \(value) cannot be appended")
        }
        if bitCount < 31 && (value >> bitCount) != 0 {
            throw .invalidBitAppend("Value \(value) does not fit in \(bitCount) bits")
        }
        bits.reserveCapacity(bits.count + bitCount)
        var i = bitCount - 1
        while i >= 0 {
            bits.append(UInt8((value >> i) & 1))
            i -= 1
        }
    }

    public mutating func appendData(_ other: QRBitBuffer) {
        bits.append(contentsOf: other.bits)
    }

    public func getBit(_ index: Int) -> Int {
        guard index >= 0 && index < bits.count else { return 0 }
        return Int(bits[index])
    }

    public var bitString: String {
        var s = ""
        s.reserveCapacity(bits.count)
        for b in bits {
            s.append(b == 0 ? "0" : "1")
        }
        return s
    }

    public func toBytes() -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity((bits.count + 7) / 8)
        var i = 0
        while i < bits.count {
            var value: UInt8 = 0
            let remaining = min(8, bits.count - i)
            for j in 0..<remaining {
                value = (value << 1) | bits[i + j]
            }
            if remaining < 8 {
                value <<= UInt8(8 - remaining)
            }
            result.append(value)
            i += 8
        }
        return result
    }
}

/// QR Code segment mode indicator.
public enum QRSegmentMode: String, Equatable, Hashable, Sendable {
    case numeric = "NUMERIC"
    case alphanumeric = "ALPHANUMERIC"
    case byte = "BYTE"
    case kanji = "KANJI"
    case eci = "ECI"
    case structuredAppend = "STRUCTURED_APPEND"
    case fnc1First = "FNC1_FIRST"
    case fnc1Second = "FNC1_SECOND"

    public var modeBits: Int {
        switch self {
        case .numeric: return 0x1
        case .alphanumeric: return 0x2
        case .byte: return 0x4
        case .kanji: return 0x8
        case .eci: return 0x7
        case .structuredAppend: return 0x3
        case .fnc1First: return 0x5
        case .fnc1Second: return 0x9
        }
    }

    public var hasCharacterCount: Bool {
        switch self {
        case .numeric, .alphanumeric, .byte, .kanji: return true
        case .eci, .structuredAppend, .fnc1First, .fnc1Second: return false
        }
    }

    public func numCharCountBits(version: Int) throws(QRCodeError) -> Int {
        if !hasCharacterCount { return 0 }
        guard version >= 1 && version <= 40 else {
            throw .invalidVersion(version)
        }
        let rangeIndex = (version + 7) / 17
        switch self {
        case .numeric:
            return [10, 12, 14][rangeIndex]
        case .alphanumeric:
            return [9, 11, 13][rangeIndex]
        case .byte:
            return [8, 16, 16][rangeIndex]
        case .kanji:
            return [8, 10, 12][rangeIndex]
        default:
            return 0
        }
    }
}

/// GF(256) Reed-Solomon error correction arithmetic (generator polynomial 0x11D).
private enum ReedSolomon {
    static func multiply(_ x: UInt8, _ y: UInt8) -> UInt8 {
        var z: Int = 0
        let xv = Int(x)
        let yv = Int(y)
        var i = 7
        while i >= 0 {
            z = (z << 1) ^ ((z >> 7) * 0x11D)
            z ^= ((yv >> i) & 1) * xv
            i -= 1
        }
        return UInt8(z & 0xFF)
    }

    static func computeDivisor(degree: Int) -> [UInt8] {
        var result = Array<UInt8>(repeating: 0, count: degree)
        result[degree - 1] = 1
        var root: UInt8 = 1
        for _ in 0..<degree {
            for j in 0..<degree {
                result[j] = multiply(result[j], root)
                if j + 1 < degree {
                    result[j] ^= result[j + 1]
                }
            }
            root = multiply(root, 0x02)
        }
        return result
    }

    static func computeRemainder(data: [UInt8], divisor: [UInt8]) -> [UInt8] {
        var result = Array<UInt8>(repeating: 0, count: divisor.count)
        for b in data {
            let factor = b ^ result[0]
            result.removeFirst()
            result.append(0)
            for i in 0..<result.count {
                result[i] ^= multiply(divisor[i], factor)
            }
        }
        return result
    }
}

/// A single mode-tagged data segment in a QR Code payload.
// parity: qrcode/src/lib/qrcode.ts#QrSegment [status=implemented hash=34638f4e36f8]
public struct QrSegment: Equatable, Hashable, Sendable {
    private static let alphanumericCharset: [UInt8] = Array(
        "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:".utf8
    )

    public let mode: QRSegmentMode
    public let numChars: Int
    public let data: QRBitBuffer
    public let parityBytes: [UInt8]

    private init(mode: QRSegmentMode, numChars: Int, data: QRBitBuffer, parityBytes: [UInt8] = []) {
        self.mode = mode
        self.numChars = numChars
        self.data = data
        self.parityBytes = parityBytes
    }

    private static func alphanumericValue(_ byte: UInt8) -> Int? {
        for (idx, ch) in alphanumericCharset.enumerated() where ch == byte {
            return idx
        }
        return nil
    }

    // parity: qrcode/src/lib/qrcode.ts#QrSegment.isNumeric [status=implemented hash=f39d500059a6]
    public static func isNumeric(_ text: String) -> Bool {
        for b in text.utf8 {
            if b < 0x30 || b > 0x39 { return false }
        }
        return true
    }

    // parity: qrcode/src/lib/qrcode.ts#QrSegment.isAlphanumeric [status=implemented hash=a80f4c38d3b3]
    public static func isAlphanumeric(_ text: String) -> Bool {
        for b in text.utf8 {
            if alphanumericValue(b) == nil { return false }
        }
        return true
    }

    private static func isKanjiScalar(_ scalar: Unicode.Scalar) -> Bool {
        guard let sjis = shiftJisCodeForCharacter(scalar) else { return false }
        return isKanjiModeShiftJisValue(sjis)
    }

    // parity: qrcode/src/lib/qrcode.ts#QrSegment.isKanji [status=implemented hash=b6e6fe9aa240]
    public static func isKanji(_ text: String) -> Bool {
        if text.isEmpty { return true }
        for scalar in text.unicodeScalars {
            if !isKanjiScalar(scalar) { return false }
        }
        return true
    }

    // parity: qrcode/src/lib/qrcode.ts#QrSegment.makeNumeric [status=implemented hash=a88c6c069055]
    public static func makeNumeric(_ digits: String) throws(QRCodeError) -> QrSegment {
        guard isNumeric(digits) else { throw .invalidNumericInput }
        let bytes = Array(digits.utf8)
        var bb = QRBitBuffer()
        var i = 0
        while i < bytes.count {
            let n = min(bytes.count - i, 3)
            var value = 0
            for j in 0..<n {
                value = value * 10 + Int(bytes[i + j] - 0x30)
            }
            try bb.appendBits(value, bitCount: n * 3 + 1)
            i += n
        }
        return QrSegment(mode: .numeric, numChars: bytes.count, data: bb, parityBytes: bytes)
    }

    // parity: qrcode/src/lib/qrcode.ts#QrSegment.makeAlphanumeric [status=implemented hash=11b8af5faf47]
    public static func makeAlphanumeric(_ text: String) throws(QRCodeError) -> QrSegment {
        guard isAlphanumeric(text) else { throw .invalidAlphanumericInput }
        let bytes = Array(text.utf8)
        var bb = QRBitBuffer()
        var i = 0
        while i + 2 <= bytes.count {
            let v0 = alphanumericValue(bytes[i])!
            let v1 = alphanumericValue(bytes[i + 1])!
            try bb.appendBits(v0 * 45 + v1, bitCount: 11)
            i += 2
        }
        if i < bytes.count {
            let v0 = alphanumericValue(bytes[i])!
            try bb.appendBits(v0, bitCount: 6)
        }
        return QrSegment(mode: .alphanumeric, numChars: bytes.count, data: bb, parityBytes: bytes)
    }

    // parity: qrcode/src/lib/qrcode.ts#QrSegment.makeBytes [status=implemented hash=32e4eaf4baeb]
    public static func makeBytes(_ bytes: [UInt8]) throws(QRCodeError) -> QrSegment {
        var bb = QRBitBuffer()
        for b in bytes {
            try bb.appendBits(Int(b), bitCount: 8)
        }
        return QrSegment(mode: .byte, numChars: bytes.count, data: bb, parityBytes: bytes)
    }

    // parity: qrcode/src/lib/qrcode.ts#QrSegment.makeBytesFromText [status=implemented hash=ce022b46342d]
    public static func makeBytesFromText(_ text: String, encoding: ByteEncoding = .utf8) throws(QRCodeError) -> QrSegment {
        let bytes = try encodeTextBytes(text, encoding: encoding)
        return try makeBytes(bytes)
    }

    // parity: qrcode/src/lib/qrcode.ts#QrSegment.makeKanji [status=implemented hash=2ebb2463d2bb]
    public static func makeKanji(_ text: String) throws(QRCodeError) -> QrSegment {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.unicodeScalars.count * 2)
        for scalar in text.unicodeScalars {
            guard let sjis = shiftJisCodeForCharacter(scalar) else {
                throw .unencodableCharacter("Character \"\(scalar)\" is not encodable in Shift JIS")
            }
            guard isKanjiModeShiftJisValue(sjis) else {
                throw .invalidKanjiBytes("Character \"\(scalar)\" is not encodable in QR Kanji mode")
            }
            bytes.append(UInt8((sjis >> 8) & 0xFF))
            bytes.append(UInt8(sjis & 0xFF))
        }
        return try makeKanjiFromShiftJis(bytes)
    }

    // parity: qrcode/src/lib/qrcode.ts#QrSegment.makeKanjiFromShiftJis [status=implemented hash=766b1c1e8a5c]
    public static func makeKanjiFromShiftJis(_ bytes: [UInt8]) throws(QRCodeError) -> QrSegment {
        guard bytes.count % 2 == 0 else {
            throw .invalidKanjiBytes("Kanji mode requires an even number of Shift JIS bytes")
        }
        var bb = QRBitBuffer()
        var i = 0
        while i < bytes.count {
            let sjis = (Int(bytes[i]) << 8) | Int(bytes[i + 1])
            let subtracted: Int
            if sjis >= 0x8140 && sjis <= 0x9FFC {
                subtracted = sjis - 0x8140
            } else if sjis >= 0xE040 && sjis <= 0xEBBF {
                subtracted = sjis - 0xC140
            } else {
                throw .invalidKanjiBytes("Shift JIS value 0x\(String(sjis, radix: 16, uppercase: true)) is outside QR Kanji-mode ranges")
            }
            let encoded = (subtracted >> 8) * 0xC0 + (subtracted & 0xFF)
            try bb.appendBits(encoded, bitCount: 13)
            i += 2
        }
        return QrSegment(mode: .kanji, numChars: bytes.count / 2, data: bb, parityBytes: bytes)
    }

    // parity: qrcode/src/lib/qrcode.ts#QrSegment.makeEci [status=implemented hash=8d81eba9fbeb]
    public static func makeEci(_ assignVal: Int) throws(QRCodeError) -> QrSegment {
        guard assignVal >= 0 && assignVal < 1_000_000 else {
            throw .invalidEciAssignment(assignVal)
        }
        var bb = QRBitBuffer()
        if assignVal < 128 {
            try bb.appendBits(assignVal, bitCount: 8)
        } else if assignVal < 16_384 {
            try bb.appendBits(0x8000 | assignVal, bitCount: 16)
        } else {
            try bb.appendBits(0xC00000 | assignVal, bitCount: 24)
        }
        return QrSegment(mode: .eci, numChars: 0, data: bb)
    }

    // parity: qrcode/src/lib/qrcode.ts#QrSegment.makeStructuredAppendHeader [status=implemented hash=79eb30957d8e]
    public static func makeStructuredAppendHeader(position: Int, total: Int, parity: Int) throws(QRCodeError) -> QrSegment {
        try validateStructuredAppend(position: position, total: total, parity: parity)
        var bb = QRBitBuffer()
        try bb.appendBits(((position - 1) << 4) | (total - 1), bitCount: 8)
        try bb.appendBits(parity, bitCount: 8)
        return QrSegment(mode: .structuredAppend, numChars: 0, data: bb)
    }

    // parity: qrcode/src/lib/qrcode.ts#QrSegment.makeFnc1FirstPosition [status=implemented hash=0e9243fb8c5e]
    public static func makeFnc1FirstPosition() -> QrSegment {
        QrSegment(mode: .fnc1First, numChars: 0, data: QRBitBuffer())
    }

    // parity: qrcode/src/lib/qrcode.ts#QrSegment.makeFnc1SecondPosition [status=implemented hash=4b002300a041]
    public static func makeFnc1SecondPosition(_ indicator: Fnc1SecondPositionInfo.Indicator) throws(QRCodeError) -> QrSegment {
        var bb = QRBitBuffer()
        try bb.appendBits(encodeFnc1SecondApplicationIndicator(indicator), bitCount: 8)
        return QrSegment(mode: .fnc1Second, numChars: 0, data: bb)
    }

    // parity: qrcode/src/lib/qrcode.ts#QrSegment.makeSegments [status=implemented hash=42d265c36ad3]
    public static func makeSegments(
        _ text: String,
        options: EncodeOptions = EncodeOptions()
    ) throws(QRCodeError) -> [QrSegment] {
        if text.isEmpty { return [] }
        if isNumeric(text) { return [try makeNumeric(text)] }
        if isAlphanumeric(text) { return [try makeAlphanumeric(text)] }
        if options.kanji && isKanji(text) { return [try makeKanji(text)] }
        let encoding = options.byteEncoding
        let segments = [try makeBytesFromText(text, encoding: encoding)]
        return try addEciIfNeeded(segments, encoding: encoding, options: options)
    }

    // parity: qrcode/src/lib/qrcode.ts#QrSegment.makeOptimizedSegments [status=implemented hash=25200bf7e34c]
    public static func makeOptimizedSegments(
        _ text: String,
        version: Int,
        options: EncodeOptions = EncodeOptions()
    ) throws(QRCodeError) -> [QrSegment] {
        try QRCode.validateVersionPublic(version)
        return try makeOptimizedSegmentsInternal(text, version: version, options: options)
    }

    // parity: qrcode/src/lib/qrcode.ts#QrSegment.makeEciSegmentsFromEscapedText [status=implemented hash=71ba0857f046]
    public static func makeEciSegmentsFromEscapedText(
        _ escapedText: String,
        defaultEncoding: ByteEncoding = .iso8859_1
    ) throws(QRCodeError) -> [QrSegment] {
        var result: [QrSegment] = []
        var currentEncoding = defaultEncoding
        var buffer = ""

        func flush() throws(QRCodeError) {
            if buffer.isEmpty { return }
            result.append(try makeBytesFromText(buffer, encoding: currentEncoding))
            buffer = ""
        }

        let scalars = Array(escapedText.unicodeScalars)
        var i = 0
        while i < scalars.count {
            if scalars[i] != "\\" {
                buffer.unicodeScalars.append(scalars[i])
                i += 1
                continue
            }
            if i + 1 < scalars.count && scalars[i + 1] == "\\" {
                buffer.append("\\")
                i += 2
                continue
            }
            if i + 6 < scalars.count {
                var val = 0
                var allDigits = true
                for k in 1...6 {
                    let s = scalars[i + k].value
                    if s >= 0x30 && s <= 0x39 {
                        val = val * 10 + Int(s - 0x30)
                    } else {
                        allDigits = false
                        break
                    }
                }
                if allDigits {
                    try flush()
                    result.append(try makeEci(val))
                    if let known = encodingForKnownEci(val) {
                        currentEncoding = known
                    }
                    i += 7
                    continue
                }
            }
            throw .invalidEciEscape
        }
        try flush()
        return result
    }

    /// Total bit count occupied by this segment in `version`, or `nil` if `numChars` overflows the character-count field.
    // parity: qrcode/src/lib/qrcode.ts#QrSegment.getTotalBits [status=implemented hash=719e66bcc152]
    public func getTotalBits(version: Int) throws(QRCodeError) -> Int? {
        if !mode.hasCharacterCount { return 4 + data.length }
        let ccbits = try mode.numCharCountBits(version: version)
        if numChars >= (1 << ccbits) { return nil }
        return 4 + ccbits + data.length
    }

    private static func resolveEciAssignment(encoding: ByteEncoding, options: EncodeOptions) -> Int? {
        switch options.eciOverride {
        case .suppress:
            return nil
        case .assignment(let value):
            return value
        case .automatic:
            switch encoding {
            case .utf8: return options.eciForUtf8 ? EciAssignment.utf8 : nil
            case .shiftJis: return EciAssignment.shiftJis
            case .iso8859_1: return nil
            }
        }
    }

    private static func addEciIfNeeded(
        _ segments: [QrSegment],
        encoding: ByteEncoding,
        options: EncodeOptions
    ) throws(QRCodeError) -> [QrSegment] {
        guard segments.contains(where: { $0.mode == .byte }) else { return segments }
        guard let assignment = resolveEciAssignment(encoding: encoding, options: options) else {
            return segments
        }
        return [try makeEci(assignment)] + segments
    }

    private static func makeOptimizedSegmentsInternal(
        _ text: String,
        version: Int,
        options: EncodeOptions
    ) throws(QRCodeError) -> [QrSegment] {
        if text.isEmpty { return [] }
        let scalars = Array(text.unicodeScalars)
        let n = scalars.count
        let encoding = options.byteEncoding
        let allowKanji = options.kanji
        let isKanjiFlags: [Bool] = allowKanji ? scalars.map(isKanjiScalar) : []

        var byteParts: [[UInt8]] = []
        byteParts.reserveCapacity(n)
        for scalar in scalars {
            byteParts.append(try encodeTextBytes(String(scalar), encoding: encoding))
        }

        let eciAssignment = resolveEciAssignment(encoding: encoding, options: options)
        let eciBits: Int
        if let assign = eciAssignment {
            eciBits = try makeEci(assign).getTotalBits(version: version) ?? 0
        } else {
            eciBits = 0
        }

        struct Prev {
            let prevIndex: Int
            let prevUsed: Int
            let mode: QRSegmentMode
        }

        let inf = Int.max / 4
        var dp: [[Int]] = [
            Array(repeating: inf, count: n + 1),
            Array(repeating: inf, count: n + 1),
        ]
        var prev: [[Prev?]] = [
            Array(repeating: nil, count: n + 1),
            Array(repeating: nil, count: n + 1),
        ]
        dp[0][0] = 0

        let numericCCBits = try QRSegmentMode.numeric.numCharCountBits(version: version)
        let alphaCCBits = try QRSegmentMode.alphanumeric.numCharCountBits(version: version)
        let kanjiCCBits = try QRSegmentMode.kanji.numCharCountBits(version: version)
        let byteCCBits = try QRSegmentMode.byte.numCharCountBits(version: version)
        let numericLimit = 1 << numericCCBits
        let alphaLimit = 1 << alphaCCBits
        let kanjiLimit = 1 << kanjiCCBits
        let byteLimit = 1 << byteCCBits

        func update(from: Int, fromUsed: Int, to: Int, toUsed: Int, mode: QRSegmentMode, cost: Int) {
            let total = dp[fromUsed][from] + cost
            if total < dp[toUsed][to] {
                dp[toUsed][to] = total
                prev[toUsed][to] = Prev(prevIndex: from, prevUsed: fromUsed, mode: mode)
            }
        }

        for i in 0..<n {
            for used in 0...1 {
                if dp[used][i] >= inf { continue }

                var count = 0
                var j = i
                while j < n && scalars[j].value >= 0x30 && scalars[j].value <= 0x39 {
                    count += 1
                    if count < numericLimit {
                        let dataBits = (count / 3) * 10 + (count % 3 == 1 ? 4 : (count % 3 == 2 ? 7 : 0))
                        update(from: i, fromUsed: used, to: j + 1, toUsed: used, mode: .numeric, cost: 4 + numericCCBits + dataBits)
                    } else {
                        break
                    }
                    j += 1
                }

                count = 0
                j = i
                while j < n && scalars[j].value <= 0x7F && alphanumericValue(UInt8(scalars[j].value)) != nil {
                    count += 1
                    if count < alphaLimit {
                        let dataBits = (count / 2) * 11 + (count % 2) * 6
                        update(from: i, fromUsed: used, to: j + 1, toUsed: used, mode: .alphanumeric, cost: 4 + alphaCCBits + dataBits)
                    } else {
                        break
                    }
                    j += 1
                }

                if allowKanji {
                    count = 0
                    j = i
                    while j < n && isKanjiFlags[j] {
                        count += 1
                        if count < kanjiLimit {
                            update(from: i, fromUsed: used, to: j + 1, toUsed: used, mode: .kanji, cost: 4 + kanjiCCBits + count * 13)
                        } else {
                            break
                        }
                        j += 1
                    }
                }

                var byteCount = 0
                j = i
                while j < n {
                    byteCount += byteParts[j].count
                    if byteCount >= byteLimit { break }
                    let eciOverhead = (used == 0 && eciAssignment != nil) ? eciBits : 0
                    update(from: i, fromUsed: used, to: j + 1, toUsed: 1, mode: .byte, cost: eciOverhead + 4 + byteCCBits + byteCount * 8)
                    j += 1
                }
            }
        }

        let finalUsed = dp[0][n] <= dp[1][n] ? 0 : 1
        guard dp[finalUsed][n] < inf else {
            throw .dataTooLong
        }

        var runs: [(start: Int, end: Int, mode: QRSegmentMode)] = []
        var idx = n
        var used = finalUsed
        while idx > 0 {
            guard let p = prev[used][idx] else {
                throw .internalError("reconstructing optimized segments")
            }
            runs.append((p.prevIndex, idx, p.mode))
            idx = p.prevIndex
            used = p.prevUsed
        }
        runs.reverse()

        var segments: [QrSegment] = []
        if finalUsed == 1, let assign = eciAssignment {
            segments.append(try makeEci(assign))
        }
        for run in runs {
            var part = ""
            for k in run.start..<run.end {
                part.unicodeScalars.append(scalars[k])
            }
            switch run.mode {
            case .numeric:
                segments.append(try makeNumeric(part))
            case .alphanumeric:
                segments.append(try makeAlphanumeric(part))
            case .kanji:
                segments.append(try makeKanji(part))
            default:
                segments.append(try makeBytesFromText(part, encoding: encoding))
            }
        }
        return segments
    }
}

// MARK: - QRCode Model 2 Encoder

/// ISO/IEC 18004:2024 QR Code Model 2 encoder (versions 1..40, ECC levels L/M/Q/H).
// parity: qrcode/src/lib/qrcode.ts#QRCode [status=implemented hash=83f671a341ce]
public struct QRCode: Equatable, Hashable, Sendable {
    public static let minVersion = 1
    public static let maxVersion = 40

    // Indexed as [eclIndex][version]. Index 0 is unused (-1).
    private static let eccCodewordsPerBlock: [[Int]] = [
        [
            -1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28,
            28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30,
        ],
        [
            -1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26,
            26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28,
        ],
        [
            -1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30,
            28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30,
        ],
        [
            -1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28,
            30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30,
        ],
    ]

    private static let numErrorCorrectionBlocks: [[Int]] = [
        [
            -1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12,
            12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25,
        ],
        [
            -1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18,
            20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49,
        ],
        [
            -1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23,
            25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68,
        ],
        [
            -1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34,
            30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81,
        ],
    ]

    private static let eclOrder: [ErrorCorrectionLevel] = [.L, .M, .Q, .H]

    public let version: Int
    public let errorCorrectionLevel: ErrorCorrectionLevel
    public let mask: Int
    public let size: Int
    public let symbologyIdentifier: String
    public let containsEci: Bool
    public let fnc1: QRFnc1Mode
    private var modules: [[Bool]]
    private var functionModules: [[Bool]]

    private struct Metadata {
        let containsEci: Bool
        let fnc1: QRFnc1Mode
    }

    private init(
        version: Int,
        errorCorrectionLevel: ErrorCorrectionLevel,
        mask: Int,
        dataCodewords: [UInt8],
        metadata: Metadata
    ) throws(QRCodeError) {
        try QRCode.validateVersion(version)
        try QRCode.validateMask(mask)
        self.version = version
        self.errorCorrectionLevel = errorCorrectionLevel
        self.mask = mask
        self.containsEci = metadata.containsEci
        self.fnc1 = metadata.fnc1
        self.symbologyIdentifier = QRCode.makeSymbologyIdentifier(metadata)
        self.size = version * 4 + 17
        self.modules = Array(repeating: Array(repeating: false, count: self.size), count: self.size)
        self.functionModules = Array(repeating: Array(repeating: false, count: self.size), count: self.size)

        drawFunctionPatterns()
        let allCodewords = try addEccAndInterleave(dataCodewords)
        try drawCodewords(allCodewords)
        try applyMask(mask)
        drawFormatBits(mask: mask)
        drawVersionBits()
    }

    // parity: qrcode/src/lib/qrcode.ts#QRCode.encodeText [status=implemented hash=598bbf1a2967]
    public static func encodeText(
        _ text: String,
        ecl: ErrorCorrectionLevel = .M,
        options: EncodeOptions = EncodeOptions()
    ) throws(QRCodeError) -> QRCode {
        if !options.optimize {
            let segments = try QrSegment.makeSegments(text, options: options)
            return try encodeSegments(segments, ecl: ecl, options: options)
        }

        let minVersion = options.minVersion
        let maxVersion = options.maxVersion
        try validateVersion(minVersion)
        try validateVersion(maxVersion)
        guard minVersion <= maxVersion else {
            throw .invalidVersionRange(min: minVersion, max: maxVersion)
        }

        var cache: [Int: [QrSegment]] = [:]
        for version in minVersion...maxVersion {
            let rangeKey = (version + 7) / 17
            let segments: [QrSegment]
            if let cached = cache[rangeKey] {
                segments = cached
            } else {
                let computed = try QrSegment.makeOptimizedSegments(text, version: version, options: options)
                cache[rangeKey] = computed
                segments = computed
            }
            let fullSegments = try applyPrefixSegments(segments, options: options)
            if let usedBits = try getTotalBits(fullSegments, version: version),
               usedBits <= (try getNumDataCodewords(version: version, ecl: ecl)) * 8
            {
                var pinned = options
                pinned.minVersion = version
                pinned.maxVersion = version
                return try encodeSegments(segments, ecl: ecl, options: pinned)
            }
        }
        throw .dataTooLong
    }

    // parity: qrcode/src/lib/qrcode.ts#QRCode.encodeBytes [status=implemented hash=2bbb92c41246]
    public static func encodeBytes(
        _ bytes: [UInt8],
        ecl: ErrorCorrectionLevel = .M,
        options: EncodeOptions = EncodeOptions()
    ) throws(QRCodeError) -> QRCode {
        try encodeSegments([try QrSegment.makeBytes(bytes)], ecl: ecl, options: options)
    }

    // parity: qrcode/src/lib/qrcode.ts#QRCode.encodeEciText [status=implemented hash=56a6a21f8158]
    public static func encodeEciText(
        _ escapedText: String,
        ecl: ErrorCorrectionLevel = .M,
        options: EncodeOptions = EncodeOptions()
    ) throws(QRCodeError) -> QRCode {
        let segs = try QrSegment.makeEciSegmentsFromEscapedText(escapedText)
        return try encodeSegments(segs, ecl: ecl, options: options)
    }

    // parity: qrcode/src/lib/qrcode.ts#QRCode.encodeGs1Text [status=implemented hash=49758d80d9c9]
    public static func encodeGs1Text(
        _ gs1Data: String,
        ecl: ErrorCorrectionLevel = .M,
        options: EncodeOptions = EncodeOptions()
    ) throws(QRCodeError) -> QRCode {
        var opts = options
        opts.eciOverride = .suppress
        opts.eciForUtf8 = false
        let segments: [QrSegment]
        if !options.optimize {
            segments = try QrSegment.makeSegments(gs1Data, options: opts)
        } else {
            segments = try QrSegment.makeOptimizedSegments(gs1Data, version: options.minVersion, options: opts)
        }
        opts.fnc1First = true
        return try encodeSegments(segments, ecl: ecl, options: opts)
    }

    public static func encodeGs1Elements(
        _ elements: [Gs1Element],
        ecl: ErrorCorrectionLevel = .M,
        options: EncodeOptions = EncodeOptions()
    ) throws(QRCodeError) -> QRCode {
        let payload = try buildGs1Payload(elements)
        return try encodeGs1Text(payload, ecl: ecl, options: options)
    }

    // parity: qrcode/src/lib/qrcode.ts#QRCode.encodeStructuredAppend [status=implemented hash=0bf0344aecf3]
    public static func encodeStructuredAppend(
        _ parts: [[QrSegment]],
        ecl: ErrorCorrectionLevel = .M,
        options: EncodeOptions = EncodeOptions()
    ) throws(QRCodeError) -> [QRCode] {
        guard parts.count >= 2 && parts.count <= 16 else {
            throw .invalidStructuredAppend("Structured append requires 2..16 symbols")
        }
        let parity = computeStructuredAppendParity(parts.flatMap { $0 })
        var results: [QRCode] = []
        results.reserveCapacity(parts.count)
        for (index, part) in parts.enumerated() {
            var partOpts = options
            partOpts.structuredAppend = StructuredAppendInfo(position: index + 1, total: parts.count, parity: parity)
            results.append(try encodeSegments(part, ecl: ecl, options: partOpts))
        }
        return results
    }

    // parity: qrcode/src/lib/qrcode.ts#QRCode.computeStructuredAppendParity [status=implemented hash=20c032ccccc9]
    public static func computeStructuredAppendParity(_ segments: [QrSegment]) -> Int {
        var result: UInt8 = 0
        for seg in segments {
            for b in seg.parityBytes {
                result ^= b
            }
        }
        return Int(result)
    }

    // parity: qrcode/src/lib/qrcode.ts#QRCode.encodeSegments [status=implemented hash=2d41d6c2e846]
    public static func encodeSegments(
        _ inputSegments: [QrSegment],
        ecl inputEcl: ErrorCorrectionLevel = .M,
        options: EncodeOptions = EncodeOptions()
    ) throws(QRCodeError) -> QRCode {
        let minVersion = options.minVersion
        let maxVersion = options.maxVersion
        let mask = options.mask
        let boostEcl = options.boostEcl

        try validateVersion(minVersion)
        try validateVersion(maxVersion)
        guard minVersion <= maxVersion else {
            throw .invalidVersionRange(min: minVersion, max: maxVersion)
        }
        if mask != -1 {
            try validateMask(mask)
        }

        let segments = try applyPrefixSegments(inputSegments, options: options)
        try validateQrSegmentOrder(segments)
        let metadata = collectMetadata(segments)

        var ecl = inputEcl
        var version = minVersion
        var dataUsedBits = 0
        while true {
            let capacityBits = (try getNumDataCodewords(version: version, ecl: ecl)) * 8
            if let used = try getTotalBits(segments, version: version), used <= capacityBits {
                dataUsedBits = used
                break
            }
            if version >= maxVersion {
                throw .dataTooLong
            }
            version += 1
        }

        if boostEcl {
            for candidate in eclOrder {
                if candidate.eclIndex > ecl.eclIndex,
                   dataUsedBits <= (try getNumDataCodewords(version: version, ecl: candidate)) * 8
                {
                    ecl = candidate
                }
            }
        }

        let capacityBits = (try getNumDataCodewords(version: version, ecl: ecl)) * 8
        var bb = QRBitBuffer()
        for seg in segments {
            try bb.appendBits(seg.mode.modeBits, bitCount: 4)
            if seg.mode.hasCharacterCount {
                let ccbits = try seg.mode.numCharCountBits(version: version)
                guard seg.numChars < (1 << ccbits) else {
                    throw .dataTooLong
                }
                try bb.appendBits(seg.numChars, bitCount: ccbits)
            }
            bb.appendData(seg.data)
        }

        try bb.appendBits(0, bitCount: min(4, capacityBits - bb.length))
        try bb.appendBits(0, bitCount: (8 - (bb.length % 8)) % 8)
        var padByte = 0xEC
        while bb.length < capacityBits {
            try bb.appendBits(padByte, bitCount: 8)
            padByte ^= 0xEC ^ 0x11
        }
        guard bb.length == capacityBits else {
            throw .internalError("data bit length mismatch")
        }

        let dataCodewords = bb.toBytes()
        if mask == -1 {
            return try makeWithBestMask(version: version, ecl: ecl, dataCodewords: dataCodewords, metadata: metadata)
        }
        return try QRCode(version: version, errorCorrectionLevel: ecl, mask: mask, dataCodewords: dataCodewords, metadata: metadata)
    }

    // parity: qrcode/src/lib/qrcode.ts#QRCode.getModule [status=implemented hash=7e87ca9f7514]
    public func getModule(x: Int, y: Int) throws(QRCodeError) -> Bool {
        guard x >= 0 && y >= 0 && x < size && y < size else {
            throw .outOfBounds(x: x, y: y, size: size)
        }
        return modules[y][x]
    }

    /// Returns a copy of the QR module matrix (`true` = dark, `false` = light).
    // parity: qrcode/src/lib/qrcode.ts#QRCode.toMatrix [status=implemented hash=47b61f413ddf]
    public func toMatrix() -> [[Bool]] {
        modules
    }

    /// Renders this QR Code as an SVG document.
    // parity: qrcode/src/lib/qrcode.ts#QRCode.toSvgString [status=implemented hash=964c8ecc5c52]
    public func toSvgString(
        border: Int = 4,
        moduleSize: Int = 1,
        lightColor: String = "#FFFFFF",
        darkColor: String = "#000000"
    ) throws(QRCodeError) -> String {
        try matrixToSvg(
            modules,
            border: border,
            minimumBorder: 4,
            moduleSize: moduleSize,
            lightColor: lightColor,
            darkColor: darkColor
        )
    }

    /// Renders this QR Code as full-block (`██`/`  `) terminal text.
    // parity: qrcode/src/lib/qrcode.ts#QRCode.toTerminalString [status=implemented hash=168393936817]
    public func toTerminalString(options: TerminalRenderOptions = TerminalRenderOptions()) throws(QRCodeError) -> String {
        let normalized = try normalizeTerminalOptions(options, defaultBorder: 4, minimumBorder: 4)
        return matrixToTerminal(modules, options: normalized)
    }

    /// Renders this QR Code using Unicode half-block characters (`█`, `▀`, `▄`, ` `) for compact terminal display.
    public func toHalfBlockString(border: Int = 4, invert: Bool = false) throws(QRCodeError) -> String {
        try matrixToHalfBlockTerminal(modules, border: border, minimumBorder: 4, invert: invert)
    }

    // parity: qrcode/src/lib/qrcode.ts#QRCode.validateVersionPublic [status=implemented hash=d5eb14f1b04f]
    public static func validateVersionPublic(_ version: Int) throws(QRCodeError) {
        try validateVersion(version)
    }

    // parity: qrcode/src/lib/qrcode.ts#QRCode.maskCondition [status=implemented hash=fdd8eef03737]
    public static func maskCondition(mask: Int, x: Int, y: Int) throws(QRCodeError) -> Bool {
        switch mask {
        case 0: return (x + y) % 2 == 0
        case 1: return y % 2 == 0
        case 2: return x % 3 == 0
        case 3: return (x + y) % 3 == 0
        case 4: return ((y / 2) + (x / 3)) % 2 == 0
        case 5: return ((x * y) % 2) + ((x * y) % 3) == 0
        case 6: return (((x * y) % 2) + ((x * y) % 3)) % 2 == 0
        case 7: return (((x + y) % 2) + ((x * y) % 3)) % 2 == 0
        default: throw .invalidMask(mask)
        }
    }

    // MARK: - Internal Construction

    private static func applyPrefixSegments(
        _ segments: [QrSegment],
        options: EncodeOptions
    ) throws(QRCodeError) -> [QrSegment] {
        var result = segments
        var prefix: [QrSegment] = []

        if let sa = options.structuredAppend {
            if result.contains(where: { $0.mode == .structuredAppend }) {
                throw .invalidStructuredAppend("Structured append header supplied both in options and segments")
            }
            prefix.append(try QrSegment.makeStructuredAppendHeader(position: sa.position, total: sa.total, parity: sa.parity))
        }

        var insertAt = 0
        while insertAt < result.count && result[insertAt].mode == .eci {
            insertAt += 1
        }

        if options.fnc1First && options.fnc1Second != nil {
            throw .invalidFnc1Configuration("Use either FNC1 first or second position, not both")
        }
        if options.fnc1First {
            result.insert(QrSegment.makeFnc1FirstPosition(), at: insertAt)
        }
        if let fnc1Second = options.fnc1Second {
            result.insert(try QrSegment.makeFnc1SecondPosition(fnc1Second.applicationIndicator), at: insertAt)
        }
        return prefix + result
    }

    private static func validateQrSegmentOrder(_ segments: [QrSegment]) throws(QRCodeError) {
        var index = 0
        if index < segments.count && segments[index].mode == .structuredAppend { index += 1 }
        while index < segments.count && segments[index].mode == .eci { index += 1 }
        if index < segments.count && (segments[index].mode == .fnc1First || segments[index].mode == .fnc1Second) {
            index += 1
        }

        var seenStructuredAppend = false
        var seenFnc1 = false
        for (i, seg) in segments.enumerated() {
            if seg.mode == .structuredAppend {
                if seenStructuredAppend || i != 0 {
                    throw .invalidSegmentOrder("Structured append header must appear only once at the start")
                }
                seenStructuredAppend = true
            } else if seg.mode == .fnc1First || seg.mode == .fnc1Second {
                if seenFnc1 || i >= index {
                    throw .invalidSegmentOrder(
                        "FNC1 mode must appear only once before the first data segment, after structured append/ECI headers"
                    )
                }
                seenFnc1 = true
            }
        }
    }

    private static func collectMetadata(_ segments: [QrSegment]) -> Metadata {
        var containsEci = false
        var fnc1: QRFnc1Mode = .none
        for seg in segments {
            if seg.mode == .eci { containsEci = true }
            else if seg.mode == .fnc1First { fnc1 = .first }
            else if seg.mode == .fnc1Second { fnc1 = .second }
        }
        return Metadata(containsEci: containsEci, fnc1: fnc1)
    }

    private static func makeSymbologyIdentifier(_ metadata: Metadata) -> String {
        switch metadata.fnc1 {
        case .first: return metadata.containsEci ? "]Q4" : "]Q3"
        case .second: return metadata.containsEci ? "]Q6" : "]Q5"
        case .none: return metadata.containsEci ? "]Q2" : "]Q1"
        }
    }

    private static func makeWithBestMask(
        version: Int,
        ecl: ErrorCorrectionLevel,
        dataCodewords: [UInt8],
        metadata: Metadata
    ) throws(QRCodeError) -> QRCode {
        var bestQr: QRCode? = nil
        var bestPenalty = Int.max
        for mask in 0..<8 {
            let qr = try QRCode(version: version, errorCorrectionLevel: ecl, mask: mask, dataCodewords: dataCodewords, metadata: metadata)
            let penalty = qr.getPenaltyScore()
            if penalty < bestPenalty {
                bestPenalty = penalty
                bestQr = qr
            }
        }
        guard let selected = bestQr else {
            throw .internalError("no mask selected")
        }
        return selected
    }

    private mutating func drawFunctionPatterns() {
        for i in 0..<size {
            if !functionModules[6][i] { setFunctionModule(x: i, y: 6, dark: i % 2 == 0) }
            if !functionModules[i][6] { setFunctionModule(x: 6, y: i, dark: i % 2 == 0) }
        }

        drawFinderPattern(cx: 3, cy: 3)
        drawFinderPattern(cx: size - 4, cy: 3)
        drawFinderPattern(cx: 3, cy: size - 4)

        let align = getAlignmentPatternPositions()
        for y in align {
            for x in align {
                if (x == 6 && y == 6) || (x == 6 && y == size - 7) || (x == size - 7 && y == 6) {
                    continue
                }
                drawAlignmentPattern(cx: x, cy: y)
            }
        }

        drawFormatBits(mask: 0)
        drawVersionBits()
        setFunctionModule(x: 8, y: size - 8, dark: true)
    }

    private mutating func drawFinderPattern(cx: Int, cy: Int) {
        for dy in -4...4 {
            for dx in -4...4 {
                let x = cx + dx
                let y = cy + dy
                if x < 0 || y < 0 || x >= size || y >= size { continue }
                let dist = max(abs(dx), abs(dy))
                setFunctionModule(x: x, y: y, dark: dist != 2 && dist != 4)
            }
        }
    }

    private mutating func drawAlignmentPattern(cx: Int, cy: Int) {
        for dy in -2...2 {
            for dx in -2...2 {
                let dist = max(abs(dx), abs(dy))
                setFunctionModule(x: cx + dx, y: cy + dy, dark: dist == 2 || dist == 0)
            }
        }
    }

    private mutating func drawFormatBits(mask: Int) {
        let data = (errorCorrectionLevel.formatBits << 3) | mask
        let bits = computeFormatBits(data: data, xorMask: 0x5412)

        for i in 0...5 { setFunctionModule(x: 8, y: i, dark: qrGetBit(bits, i)) }
        setFunctionModule(x: 8, y: 7, dark: qrGetBit(bits, 6))
        setFunctionModule(x: 8, y: 8, dark: qrGetBit(bits, 7))
        setFunctionModule(x: 7, y: 8, dark: qrGetBit(bits, 8))
        for i in 9..<15 { setFunctionModule(x: 14 - i, y: 8, dark: qrGetBit(bits, i)) }

        for i in 0..<8 { setFunctionModule(x: size - 1 - i, y: 8, dark: qrGetBit(bits, i)) }
        for i in 8..<15 { setFunctionModule(x: 8, y: size - 15 + i, dark: qrGetBit(bits, i)) }
        setFunctionModule(x: 8, y: size - 8, dark: true)
    }

    private mutating func drawVersionBits() {
        if version < 7 { return }
        var rem = version
        for _ in 0..<12 {
            rem = (rem << 1) ^ (((rem >> 11) & 1) * 0x1F25)
        }
        let bits = (version << 12) | rem
        for i in 0..<18 {
            let bit = qrGetBit(bits, i)
            let a = size - 11 + (i % 3)
            let b = i / 3
            setFunctionModule(x: a, y: b, dark: bit)
            setFunctionModule(x: b, y: a, dark: bit)
        }
    }

    private mutating func drawCodewords(_ data: [UInt8]) throws(QRCodeError) {
        var bitIndex = 0
        var right = size - 1
        while right >= 1 {
            if right == 6 { right = 5 }
            for vert in 0..<size {
                for j in 0..<2 {
                    let x = right - j
                    let upward = ((right + 1) & 2) == 0
                    let y = upward ? size - 1 - vert : vert
                    if functionModules[y][x] { continue }
                    let dark: Bool
                    if bitIndex < data.count * 8 {
                        dark = qrGetBit(Int(data[bitIndex >> 3]), 7 - (bitIndex & 7))
                    } else {
                        dark = false
                    }
                    modules[y][x] = dark
                    bitIndex += 1
                }
            }
            right -= 2
        }
        guard bitIndex == (try QRCode.getNumRawDataModules(version: version)) else {
            throw .internalError("codeword placement mismatch")
        }
    }

    private mutating func applyMask(_ mask: Int) throws(QRCodeError) {
        try QRCode.validateMask(mask)
        for y in 0..<size {
            for x in 0..<size {
                if !functionModules[y][x] {
                    if try QRCode.maskCondition(mask: mask, x: x, y: y) {
                        modules[y][x].toggle()
                    }
                }
            }
        }
    }

    private func getPenaltyScore() -> Int {
        var result = 0

        for y in 0..<size {
            var runColor = false
            var runLength = 0
            for x in 0..<size {
                let color = modules[y][x]
                if x == 0 || color != runColor {
                    runColor = color
                    runLength = 1
                } else {
                    runLength += 1
                    if runLength == 5 { result += 3 }
                    else if runLength > 5 { result += 1 }
                }
            }
        }
        for x in 0..<size {
            var runColor = false
            var runLength = 0
            for y in 0..<size {
                let color = modules[y][x]
                if y == 0 || color != runColor {
                    runColor = color
                    runLength = 1
                } else {
                    runLength += 1
                    if runLength == 5 { result += 3 }
                    else if runLength > 5 { result += 1 }
                }
            }
        }

        for y in 0..<(size - 1) {
            for x in 0..<(size - 1) {
                let color = modules[y][x]
                if color == modules[y][x + 1]
                    && color == modules[y + 1][x]
                    && color == modules[y + 1][x + 1]
                {
                    result += 3
                }
            }
        }

        for y in 0..<size {
            var bits = 0
            for x in 0..<size {
                bits = ((bits << 1) & 0x7FF) | (modules[y][x] ? 1 : 0)
                if x >= 10 && (bits == 0x05D || bits == 0x5D0) { result += 40 }
            }
        }
        for x in 0..<size {
            var bits = 0
            for y in 0..<size {
                bits = ((bits << 1) & 0x7FF) | (modules[y][x] ? 1 : 0)
                if y >= 10 && (bits == 0x05D || bits == 0x5D0) { result += 40 }
            }
        }

        var dark = 0
        for row in modules {
            for m in row where m { dark += 1 }
        }
        let total = size * size
        let diff = abs(dark * 20 - total * 10)
        let k = (diff + total - 1) / total - 1
        result += max(0, k) * 10
        return result
    }

    private func addEccAndInterleave(_ data: [UInt8]) throws(QRCodeError) -> [UInt8] {
        let eclIdx = errorCorrectionLevel.eclIndex
        let numBlocks = QRCode.numErrorCorrectionBlocks[eclIdx][version]
        let blockEccLen = QRCode.eccCodewordsPerBlock[eclIdx][version]
        let rawCodewords = (try QRCode.getNumRawDataModules(version: version)) / 8
        let numShortBlocks = numBlocks - (rawCodewords % numBlocks)
        let shortBlockDataLen = (rawCodewords / numBlocks) - blockEccLen

        guard data.count == (try QRCode.getNumDataCodewords(version: version, ecl: errorCorrectionLevel)) else {
            throw .internalError("unexpected number of data codewords")
        }

        let rsDivisor = ReedSolomon.computeDivisor(degree: blockEccLen)
        var blocks: [(data: [UInt8], ecc: [UInt8])] = []
        blocks.reserveCapacity(numBlocks)
        var offset = 0
        for i in 0..<numBlocks {
            let dataLen = shortBlockDataLen + (i < numShortBlocks ? 0 : 1)
            let dat = Array(data[offset..<(offset + dataLen)])
            offset += dataLen
            blocks.append((dat, ReedSolomon.computeRemainder(data: dat, divisor: rsDivisor)))
        }
        guard offset == data.count else {
            throw .internalError("data block split mismatch")
        }

        var result: [UInt8] = []
        result.reserveCapacity(rawCodewords)
        let maxDataLen = blocks.map(\.data.count).max() ?? 0
        for i in 0..<maxDataLen {
            for block in blocks where i < block.data.count {
                result.append(block.data[i])
            }
        }
        for i in 0..<blockEccLen {
            for block in blocks {
                result.append(block.ecc[i])
            }
        }
        guard result.count == rawCodewords else {
            throw .internalError("interleaved codeword count mismatch")
        }
        return result
    }

    private func getAlignmentPatternPositions() -> [Int] {
        if version == 1 { return [] }
        let numAlign = version / 7 + 2
        let step: Int
        if version == 32 {
            step = 26
        } else {
            let denom = numAlign * 2 - 2
            let numer = version * 4 + 4
            step = ((numer + denom - 1) / denom) * 2
        }
        var result = [6]
        var pos = size - 7
        while result.count < numAlign {
            result.insert(pos, at: 1)
            pos -= step
        }
        return result
    }

    private mutating func setFunctionModule(x: Int, y: Int, dark: Bool) {
        modules[y][x] = dark
        functionModules[y][x] = true
    }

    private static func getTotalBits(_ segments: [QrSegment], version: Int) throws(QRCodeError) -> Int? {
        var result = 0
        for seg in segments {
            guard let n = try seg.getTotalBits(version: version) else { return nil }
            result += n
        }
        return result
    }

    private static func getNumDataCodewords(version: Int, ecl: ErrorCorrectionLevel) throws(QRCodeError) -> Int {
        try validateVersion(version)
        let eclIdx = ecl.eclIndex
        return (try getNumRawDataModules(version: version)) / 8
            - eccCodewordsPerBlock[eclIdx][version] * numErrorCorrectionBlocks[eclIdx][version]
    }

    private static func getNumRawDataModules(version: Int) throws(QRCodeError) -> Int {
        try validateVersion(version)
        var result = (16 * version + 128) * version + 64
        if version >= 2 {
            let numAlign = version / 7 + 2
            result -= (25 * numAlign - 10) * numAlign - 55
            if version >= 7 { result -= 36 }
        }
        return result
    }

    private static func validateVersion(_ version: Int) throws(QRCodeError) {
        guard version >= minVersion && version <= maxVersion else {
            throw .invalidVersion(version)
        }
    }

    private static func validateMask(_ mask: Int) throws(QRCodeError) {
        guard mask >= 0 && mask <= 7 else {
            throw .invalidMask(mask)
        }
    }
}

/// Convenience helper encoding `text` directly to an SVG QR Code string.
// parity: qrcode/src/lib/qrcode.ts#createQrSvg [status=implemented hash=c019a180cafb]
public func createQrSvg(
    _ text: String,
    ecl: ErrorCorrectionLevel = .M,
    border: Int = 4,
    moduleSize: Int = 8,
    options: EncodeOptions = EncodeOptions()
) throws(QRCodeError) -> String {
    let qr = try QRCode.encodeText(text, ecl: ecl, options: options)
    return try qr.toSvgString(border: border, moduleSize: moduleSize)
}

// MARK: - Private Encoding Helpers

private func encodeFnc1SecondApplicationIndicator(
    _ indicator: Fnc1SecondPositionInfo.Indicator
) throws(QRCodeError) -> Int {
    switch indicator {
    case .number(let n):
        guard n >= 0 && n <= 99 else {
            throw .invalidFnc1Configuration("FNC1 second-position numeric application indicator must be 0..99")
        }
        return n
    case .text(let s):
        let bytes = Array(s.utf8)
        if bytes.count == 2,
           bytes[0] >= 0x30 && bytes[0] <= 0x39,
           bytes[1] >= 0x30 && bytes[1] <= 0x39
        {
            return Int(bytes[0] - 0x30) * 10 + Int(bytes[1] - 0x30)
        }
        if bytes.count == 1,
           (bytes[0] >= 0x41 && bytes[0] <= 0x5A) || (bytes[0] >= 0x61 && bytes[0] <= 0x7A)
        {
            return Int(bytes[0]) + 100
        }
        throw .invalidFnc1Configuration(
            "FNC1 second-position application indicator must be two digits or one Latin alphabetic character"
        )
    }
}

private func validateStructuredAppend(position: Int, total: Int, parity: Int) throws(QRCodeError) {
    guard total >= 2 && total <= 16 else {
        throw .invalidStructuredAppend("Structured append total must be in 2..16")
    }
    guard position >= 1 && position <= total else {
        throw .invalidStructuredAppend("Structured append position must be in 1..total")
    }
    guard parity >= 0 && parity <= 0xFF else {
        throw .invalidStructuredAppend("Structured append parity must be an 8-bit value")
    }
}

private func buildGs1Payload(_ elements: [Gs1Element]) throws(QRCodeError) -> String {
    var result = ""
    for (i, el) in elements.enumerated() {
        guard !el.ai.isEmpty,
              el.ai.utf8.allSatisfy({ b in
                  (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
              })
        else {
            throw .invalidGs1AI("GS1 AI should contain only letters/digits without parentheses")
        }
        result += el.ai
        for ch in el.data {
            if ch == "%" {
                result += "%%"
            } else {
                result.append(ch)
            }
        }
        if el.separatorAfter && i + 1 < elements.count {
            result += "%"
        }
    }
    return result
}

private func qrGetBit(_ x: Int, _ i: Int) -> Bool {
    ((x >> i) & 1) != 0
}

private func computeFormatBits(data: Int, xorMask: Int) -> Int {
    var rem = data
    for _ in 0..<10 {
        rem = (rem << 1) ^ (((rem >> 9) & 1) * 0x537)
    }
    return ((data << 10) | rem) ^ xorMask
}
