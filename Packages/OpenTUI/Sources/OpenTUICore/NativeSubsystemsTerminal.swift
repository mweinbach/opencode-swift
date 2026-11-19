// Pure-Swift native subsystem parity bridges for OpenTUICore (Workstream 3a2).
// Covers all 122 unmapped symbols across 5 upstream `packages/native` Zig modules:
// - src/ansi.zig (32)
// - src/terminal.zig (61)
// - src/buffer.zig (15)
// - src/renderer.zig (12)
// - src/renderer-output.zig (2)
// Pure Swift 6 — zero OS or Foundation imports.

import Synchronization

// MARK: - Portable Pure-Swift Byte Writer

/// Portable pure-Swift byte sink used by `NativeANSI` and `NativeTerminalState` emitters.
public protocol NativeTerminalByteSink {
    mutating func writeBytes(_ bytes: [UInt8]) throws(NativeANSI.AnsiError)
    mutating func writeByte(_ byte: UInt8) throws(NativeANSI.AnsiError)
    mutating func writeString(_ text: String) throws(NativeANSI.AnsiError)
}

extension NativeTerminalByteSink {
    public mutating func writeByte(_ byte: UInt8) throws(NativeANSI.AnsiError) {
        try writeBytes([byte])
    }

    public mutating func writeString(_ text: String) throws(NativeANSI.AnsiError) {
        try writeBytes(Array(text.utf8))
    }
}

/// In-memory pure-Swift byte buffer implementing `NativeTerminalByteSink` with optional capacity cap.
public struct NativeTerminalByteBuffer: NativeTerminalByteSink, Equatable, Hashable, Sendable {
    public var bytes: [UInt8]
    public var maxCapacity: Int?

    public init(bytes: [UInt8] = [], maxCapacity: Int? = nil) {
        self.bytes = bytes
        self.maxCapacity = maxCapacity
    }

    public var string: String {
        String(decoding: bytes, as: UTF8.self)
    }

    public mutating func clear() {
        bytes.removeAll(keepingCapacity: true)
    }

    public mutating func writeBytes(_ newBytes: [UInt8]) throws(NativeANSI.AnsiError) {
        if let maxCapacity, bytes.count + newBytes.count > maxCapacity {
            throw .writeFailed
        }
        bytes.append(contentsOf: newBytes)
    }

    public mutating func writeByte(_ byte: UInt8) throws(NativeANSI.AnsiError) {
        if let maxCapacity, bytes.count + 1 > maxCapacity {
            throw .writeFailed
        }
        bytes.append(byte)
    }

    public mutating func writeString(_ text: String) throws(NativeANSI.AnsiError) {
        let utf8 = Array(text.utf8)
        try writeBytes(utf8)
    }
}

// MARK: - Private Pure-Swift ASCII / UTF-8 / Hex Helpers

@inline(__always)
private func nativeAsciiLower(_ byte: UInt8) -> UInt8 {
    (byte >= 0x41 && byte <= 0x5A) ? (byte + 32) : byte
}

@inline(__always)
private func nativeIsAsciiDigit(_ byte: UInt8) -> Bool {
    byte >= 0x30 && byte <= 0x39
}

@inline(__always)
private func nativeIsAsciiHex(_ byte: UInt8) -> Bool {
    (byte >= 0x30 && byte <= 0x39)
        || (byte >= 0x41 && byte <= 0x46)
        || (byte >= 0x61 && byte <= 0x66)
}

@inline(__always)
private func nativeIsAsciiUpper(_ byte: UInt8) -> Bool {
    byte >= 0x41 && byte <= 0x5A
}

@inline(__always)
private func nativeIsAsciiLower(_ byte: UInt8) -> Bool {
    byte >= 0x61 && byte <= 0x7A
}

@inline(__always)
private func nativeIsAsciiAlphaNum(_ byte: UInt8) -> Bool {
    nativeIsAsciiDigit(byte) || nativeIsAsciiUpper(byte) || nativeIsAsciiLower(byte)
}

private func nativeEqlIgnoreCase(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    guard a.count == b.count else { return false }
    for i in 0..<a.count {
        if nativeAsciiLower(a[i]) != nativeAsciiLower(b[i]) { return false }
    }
    return true
}

private func nativeEqlIgnoreCase(_ a: String, _ b: String) -> Bool {
    nativeEqlIgnoreCase(Array(a.utf8), Array(b.utf8))
}

private func nativeFindBytes(_ haystack: [UInt8], _ needle: [UInt8], from start: Int = 0) -> Int? {
    guard !needle.isEmpty else { return start <= haystack.count ? start : nil }
    guard start >= 0, haystack.count >= start + needle.count else { return nil }
    let limit = haystack.count - needle.count
    var i = start
    while i <= limit {
        var matched = true
        for j in 0..<needle.count {
            if haystack[i + j] != needle[j] {
                matched = false
                break
            }
        }
        if matched { return i }
        i += 1
    }
    return nil
}

private func nativeFindIgnoreCase(_ haystack: [UInt8], _ needle: [UInt8], from start: Int = 0) -> Int? {
    guard !needle.isEmpty else { return start <= haystack.count ? start : nil }
    guard start >= 0, haystack.count >= start + needle.count else { return nil }
    let limit = haystack.count - needle.count
    var i = start
    while i <= limit {
        var matched = true
        for j in 0..<needle.count {
            if nativeAsciiLower(haystack[i + j]) != nativeAsciiLower(needle[j]) {
                matched = false
                break
            }
        }
        if matched { return i }
        i += 1
    }
    return nil
}

private func nativeFindIgnoreCase(_ haystack: String, _ needle: String) -> Int? {
    nativeFindIgnoreCase(Array(haystack.utf8), Array(needle.utf8))
}

private func nativeContainsIgnoreCase(_ haystack: String, _ needle: String) -> Bool {
    nativeFindIgnoreCase(haystack, needle) != nil
}

private func nativeParseUInt32(_ bytes: ArraySlice<UInt8>) -> UInt32? {
    guard !bytes.isEmpty else { return nil }
    var value: UInt32 = 0
    for b in bytes {
        guard nativeIsAsciiDigit(b) else { return nil }
        let digit = UInt32(b - 0x30)
        let (mul, overflow1) = value.multipliedReportingOverflow(by: 10)
        if overflow1 { return nil }
        let (sum, overflow2) = mul.addingReportingOverflow(digit)
        if overflow2 { return nil }
        value = sum
    }
    return value
}

private func nativeParseUInt16(_ bytes: ArraySlice<UInt8>) -> UInt16? {
    guard let v = nativeParseUInt32(bytes), v <= UInt32(UInt16.max) else { return nil }
    return UInt16(v)
}

private func nativeHex2Lower(_ value: UInt8) -> String {
    let digits: [UInt8] = [
        0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37,
        0x38, 0x39, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66,
    ]
    let hi = digits[Int((value >> 4) & 0xF)]
    let lo = digits[Int(value & 0xF)]
    return String(decoding: [hi, lo], as: UTF8.self)
}

/// Validates a UTF-8 byte sequence strictly (rejecting surrogates, overlongs, and truncated sequences).
private func nativeValidateUTF8(_ bytes: [UInt8]) -> Bool {
    var i = 0
    let count = bytes.count
    while i < count {
        let b0 = bytes[i]
        if b0 < 0x80 {
            i += 1
        } else if b0 >= 0xC2 && b0 <= 0xDF {
            guard i + 1 < count else { return false }
            let b1 = bytes[i + 1]
            guard (b1 & 0xC0) == 0x80 else { return false }
            i += 2
        } else if b0 >= 0xE0 && b0 <= 0xEF {
            guard i + 2 < count else { return false }
            let b1 = bytes[i + 1]
            let b2 = bytes[i + 2]
            guard (b1 & 0xC0) == 0x80, (b2 & 0xC0) == 0x80 else { return false }
            if b0 == 0xE0 && b1 < 0xA0 { return false }
            if b0 == 0xED && b1 >= 0xA0 { return false } // UTF-16 surrogates
            i += 3
        } else if b0 >= 0xF0 && b0 <= 0xF4 {
            guard i + 3 < count else { return false }
            let b1 = bytes[i + 1]
            let b2 = bytes[i + 2]
            let b3 = bytes[i + 3]
            guard (b1 & 0xC0) == 0x80, (b2 & 0xC0) == 0x80, (b3 & 0xC0) == 0x80 else { return false }
            if b0 == 0xF0 && b1 < 0x90 { return false }
            if b0 == 0xF4 && b1 > 0x8F { return false }
            i += 4
        } else {
            return false
        }
    }
    return true
}

/// Returns the expected UTF-8 sequence length for a valid leading byte, or `nil` if invalid.
@inline(__always)
private func nativeUtf8SequenceLength(_ lead: UInt8) -> Int? {
    if lead < 0x80 { return 1 }
    if lead >= 0xC2 && lead <= 0xDF { return 2 }
    if lead >= 0xE0 && lead <= 0xEF { return 3 }
    if lead >= 0xF0 && lead <= 0xF4 { return 4 }
    return nil
}

/// Decodes one valid UTF-8 sequence slice into its Unicode scalar value, or `nil` if invalid.
private func nativeUtf8Decode(_ slice: ArraySlice<UInt8>) -> UInt32? {
    guard let first = slice.first, let expected = nativeUtf8SequenceLength(first), slice.count == expected else {
        return nil
    }
    let idx = slice.startIndex
    switch expected {
    case 1:
        return UInt32(first)
    case 2:
        let b1 = slice[idx + 1]
        guard (b1 & 0xC0) == 0x80 else { return nil }
        return (UInt32(first & 0x1F) << 6) | UInt32(b1 & 0x3F)
    case 3:
        let b1 = slice[idx + 1]
        let b2 = slice[idx + 2]
        guard (b1 & 0xC0) == 0x80, (b2 & 0xC0) == 0x80 else { return nil }
        if first == 0xE0 && b1 < 0xA0 { return nil }
        if first == 0xED && b1 >= 0xA0 { return nil }
        return (UInt32(first & 0x0F) << 12) | (UInt32(b1 & 0x3F) << 6) | UInt32(b2 & 0x3F)
    case 4:
        let b1 = slice[idx + 1]
        let b2 = slice[idx + 2]
        let b3 = slice[idx + 3]
        guard (b1 & 0xC0) == 0x80, (b2 & 0xC0) == 0x80, (b3 & 0xC0) == 0x80 else { return nil }
        if first == 0xF0 && b1 < 0x90 { return nil }
        if first == 0xF4 && b1 > 0x8F { return nil }
        return (UInt32(first & 0x07) << 18)
            | (UInt32(b1 & 0x3F) << 12)
            | (UInt32(b2 & 0x3F) << 6)
            | UInt32(b3 & 0x3F)
    default:
        return nil
    }
}

/// Encodes a valid Unicode scalar value (`0...0x10FFFF`, excluding surrogates) to UTF-8 bytes.
private func nativeUtf8EncodeScalar(_ codepoint: UInt32) -> [UInt8]? {
    guard let scalar = Unicode.Scalar(codepoint) else { return nil }
    return Array(String(scalar).utf8)
}

// MARK: - 1. native/src/ansi.zig (32 unmapped symbols)

/// Pure-Swift parity bridge for `packages/native/src/ansi.zig`, bridging directly to
/// `OpenTUICore.RGBA`, `OpenTUICore.ANSI`, and `OpenTUICore.TextAttributes`.
public enum NativeANSI: Sendable {
    // parity: native/src/ansi.zig#RGBA [status=implemented hash=a87d60875cf4]
    public typealias RGBA = OpenTUICore.RGBA

    // parity: native/src/ansi.zig#ColorIntent [status=implemented hash=28d80ddecb0f]
    public enum ColorIntent: UInt8, Equatable, Hashable, Sendable, Codable, CaseIterable {
        case rgb = 0
        case indexed = 1
        case `default` = 2

        public init(core: OpenTUICore.ColorIntent) {
            switch core {
            case .rgb: self = .rgb
            case .indexed: self = .indexed
            case .default: self = .default
            }
        }

        public var coreValue: OpenTUICore.ColorIntent {
            switch self {
            case .rgb: return .rgb
            case .indexed: return .indexed
            case .default: return .default
            }
        }
    }

    // parity: native/src/ansi.zig#AnsiError [status=implemented hash=83e7e836f058]
    public enum AnsiError: Error, Equatable, Hashable, Sendable {
        case invalidFormat
        case writeFailed
    }

    // parity: native/src/ansi.zig#ANSI16_RGB [status=implemented hash=2600d51ca9e1]
    public static let ANSI16_RGB: [RGBTriplet] = [
        RGBTriplet(0x00, 0x00, 0x00),
        RGBTriplet(0x80, 0x00, 0x00),
        RGBTriplet(0x00, 0x80, 0x00),
        RGBTriplet(0x80, 0x80, 0x00),
        RGBTriplet(0x00, 0x00, 0x80),
        RGBTriplet(0x80, 0x00, 0x80),
        RGBTriplet(0x00, 0x80, 0x80),
        RGBTriplet(0xC0, 0xC0, 0xC0),
        RGBTriplet(0x80, 0x80, 0x80),
        RGBTriplet(0xFF, 0x00, 0x00),
        RGBTriplet(0x00, 0xFF, 0x00),
        RGBTriplet(0xFF, 0xFF, 0x00),
        RGBTriplet(0x00, 0x00, 0xFF),
        RGBTriplet(0xFF, 0x00, 0xFF),
        RGBTriplet(0x00, 0xFF, 0xFF),
        RGBTriplet(0xFF, 0xFF, 0xFF),
    ]

    // parity: native/src/ansi.zig#ANSI_256_CUBE_LEVELS [status=implemented hash=8c4d46556641]
    public static let ANSI_256_CUBE_LEVELS: [UInt8] = [0, 95, 135, 175, 215, 255]

    // parity: native/src/ansi.zig#rgbaComponentToU8 [status=implemented hash=3e5fd5b46d68]
    @inline(__always)
    public static func rgbaComponentToU8(_ component: Float) -> UInt8 {
        guard component.isFinite else { return 0 }
        let clamped = min(Float(1.0), max(Float(0.0), component))
        return UInt8((clamped * 255.0).rounded(.toNearestOrAwayFromZero))
    }

    // parity: native/src/ansi.zig#u8ToComponent [status=implemented hash=37153c3a06ca]
    @inline(__always)
    public static func u8ToComponent(_ component: UInt8) -> Float {
        Float(component) / 255.0
    }

    // parity: native/src/ansi.zig#packMeta [status=implemented hash=128961021a32]
    @inline(__always)
    public static func packMeta(intent: ColorIntent, slot: UInt8 = 0) -> UInt32 {
        UInt32(slot) | (UInt32(intent.rawValue) << 8)
    }

    // parity: native/src/ansi.zig#packRGBA8 [status=implemented hash=ad6f657cdcfb]
    @inline(__always)
    public static func packRGBA8(r: UInt8, g: UInt8, b: UInt8, a: UInt8, meta: UInt32) -> RGBA {
        RGBA(
            b0: UInt16(r) | (UInt16(meta & 0xFF) << 8),
            b1: UInt16(g) | (UInt16((meta >> 8) & 0xFF) << 8),
            b2: UInt16(b) | (UInt16((meta >> 16) & 0xFF) << 8),
            b3: UInt16(a) | (UInt16((meta >> 24) & 0xFF) << 8)
        )
    }

    // parity: native/src/ansi.zig#red [status=implemented hash=d1d47cc9bb4d]
    @inline(__always)
    public static func red(_ c: RGBA) -> UInt8 {
        UInt8(truncatingIfNeeded: c.b0)
    }

    // parity: native/src/ansi.zig#green [status=implemented hash=c428714d7110]
    @inline(__always)
    public static func green(_ c: RGBA) -> UInt8 {
        UInt8(truncatingIfNeeded: c.b1)
    }

    // parity: native/src/ansi.zig#blue [status=implemented hash=05ca4253696c]
    @inline(__always)
    public static func blue(_ c: RGBA) -> UInt8 {
        UInt8(truncatingIfNeeded: c.b2)
    }

    // parity: native/src/ansi.zig#alpha [status=implemented hash=7f4dc0985766]
    @inline(__always)
    public static func alpha(_ c: RGBA) -> UInt8 {
        UInt8(truncatingIfNeeded: c.b3)
    }

    // parity: native/src/ansi.zig#redF [status=implemented hash=4e36677b99b1]
    @inline(__always)
    public static func redF(_ c: RGBA) -> Float {
        u8ToComponent(red(c))
    }

    // parity: native/src/ansi.zig#greenF [status=implemented hash=a2680ba64aa1]
    @inline(__always)
    public static func greenF(_ c: RGBA) -> Float {
        u8ToComponent(green(c))
    }

    // parity: native/src/ansi.zig#blueF [status=implemented hash=520c039cb018]
    @inline(__always)
    public static func blueF(_ c: RGBA) -> Float {
        u8ToComponent(blue(c))
    }

    // parity: native/src/ansi.zig#alphaF [status=implemented hash=7427eefc5b88]
    @inline(__always)
    public static func alphaF(_ c: RGBA) -> Float {
        u8ToComponent(alpha(c))
    }

    // parity: native/src/ansi.zig#getMeta [status=implemented hash=9bb44ef29d74]
    @inline(__always)
    public static func getMeta(_ c: RGBA) -> UInt32 {
        c.meta
    }

    // parity: native/src/ansi.zig#intent [status=implemented hash=955f1d5197be]
    @inline(__always)
    public static func intent(_ c: RGBA) -> ColorIntent {
        switch UInt8(truncatingIfNeeded: getMeta(c) >> 8) {
        case ColorIntent.indexed.rawValue: return .indexed
        case ColorIntent.default.rawValue: return .default
        default: return .rgb
        }
    }

    // parity: native/src/ansi.zig#slot [status=implemented hash=f7bc11cf4b23]
    @inline(__always)
    public static func slot(_ c: RGBA) -> UInt8 {
        c.slot
    }

    // parity: native/src/ansi.zig#withMeta [status=implemented hash=31272d59f804]
    @inline(__always)
    public static func withMeta(_ c: RGBA, meta: UInt32) -> RGBA {
        packRGBA8(r: red(c), g: green(c), b: blue(c), a: alpha(c), meta: meta)
    }

    // parity: native/src/ansi.zig#rgbColor [status=implemented hash=d7656a1897c1]
    @inline(__always)
    public static func rgbColor(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) -> RGBA {
        packRGBA8(r: r, g: g, b: b, a: a, meta: packMeta(intent: .rgb, slot: 0))
    }

    // parity: native/src/ansi.zig#rgbaFromFloats [status=implemented hash=e8a90f127d74]
    @inline(__always)
    public static func rgbaFromFloats(_ r: Float, _ g: Float, _ b: Float, _ a: Float) -> RGBA {
        rgbColor(
            rgbaComponentToU8(r),
            rgbaComponentToU8(g),
            rgbaComponentToU8(b),
            rgbaComponentToU8(a)
        )
    }

    // parity: native/src/ansi.zig#indexedColor [status=implemented hash=39222c5b5c83]
    @inline(__always)
    public static func indexedColor(_ index: UInt8, _ r: UInt8, _ g: UInt8, _ b: UInt8) -> RGBA {
        packRGBA8(r: r, g: g, b: b, a: 255, meta: packMeta(intent: .indexed, slot: index))
    }

    // parity: native/src/ansi.zig#defaultColor [status=implemented hash=09a95430a4c3]
    @inline(__always)
    public static func defaultColor(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) -> RGBA {
        packRGBA8(r: r, g: g, b: b, a: a, meta: packMeta(intent: .default, slot: 0))
    }

    // parity: native/src/ansi.zig#u8RgbToRgba [status=implemented hash=f514f91dd905]
    @inline(__always)
    public static func u8RgbToRgba(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> RGBA {
        rgbColor(r, g, b, 255)
    }

    // parity: native/src/ansi.zig#fallbackAnsi256Color [status=implemented hash=992309fe7632]
    public static func fallbackAnsi256Color(_ index: Int) -> RGBA {
        let clampedIndex = max(0, min(255, index))
        if let rgb = try? ansi256IndexToRgb(clampedIndex) {
            return u8RgbToRgba(rgb.r, rgb.g, rgb.b)
        }
        if clampedIndex < ANSI16_RGB.count {
            let c = ANSI16_RGB[clampedIndex]
            return u8RgbToRgba(c.r, c.g, c.b)
        }
        if clampedIndex < 232 {
            let cubeIndex = clampedIndex - 16
            let r = ANSI_256_CUBE_LEVELS[(cubeIndex / 36) % 6]
            let g = ANSI_256_CUBE_LEVELS[(cubeIndex / 6) % 6]
            let b = ANSI_256_CUBE_LEVELS[cubeIndex % 6]
            return u8RgbToRgba(r, g, b)
        }
        let grayBase = Int(NativeABI.OT_COLOR_GRAY_BASE)
        let grayStep = Int(NativeABI.OT_COLOR_GRAY_STEP)
        let gray = UInt8(clamping: grayBase + (clampedIndex - 232) * grayStep)
        return u8RgbToRgba(gray, gray, gray)
    }

    // parity: native/src/ansi.zig#colorDistanceSquared [status=implemented hash=0b767d493b0d]
    @inline(__always)
    public static func colorDistanceSquared(_ a: RGBA, _ b: RGBA) -> Float {
        let dr = Float(red(a)) - Float(red(b))
        let dg = Float(green(a)) - Float(green(b))
        let db = Float(blue(a)) - Float(blue(b))
        return dr * dr + dg * dg + db * db
    }

    // parity: native/src/ansi.zig#rgbaToRgb24 [status=implemented hash=e0136d432dcb]
    @inline(__always)
    public static func rgbaToRgb24(_ rgba: RGBA) -> UInt32 {
        (UInt32(red(rgba)) << 16) | (UInt32(green(rgba)) << 8) | UInt32(blue(rgba))
    }

    // parity: native/src/ansi.zig#ANSI [status=implemented hash=c166a87b94af]
    public enum ANSI: Sendable {
        public static let reset = OpenTUICore.ANSI.reset
        public static let clear = OpenTUICore.ANSI.clearScreen
        public static let home = OpenTUICore.ANSI.home
        public static let eraseToEndOfLine = "\u{1B}[K"
        public static let hideCursor = "\u{1B}[?25l"
        public static let showCursor = "\u{1B}[?25h"
        public static let defaultCursorStyle = "\u{1B}[0 q"
        public static let queryPixelSize = "\u{1B}[14t"
        public static let nextLine = "\u{1B}[E"

        // Text attribute constants
        public static let bold = "\u{1B}[1m"
        public static let dim = "\u{1B}[2m"
        public static let italic = "\u{1B}[3m"
        public static let underline = "\u{1B}[4m"
        public static let blink = "\u{1B}[5m"
        public static let inverse = "\u{1B}[7m"
        public static let hidden = "\u{1B}[8m"
        public static let strikethrough = "\u{1B}[9m"

        // Cursor styles
        public static let cursorBlock = "\u{1B}[2 q"
        public static let cursorBlockBlink = "\u{1B}[1 q"
        public static let cursorLine = "\u{1B}[6 q"
        public static let cursorLineBlink = "\u{1B}[5 q"
        public static let cursorUnderline = "\u{1B}[4 q"
        public static let cursorUnderlineBlink = "\u{1B}[3 q"

        public static let resetCursorColor = "\u{1B}]112\u{07}"
        public static let resetCursorColorFallback = "\u{1B}]12;default\u{07}"
        public static let resetMousePointer = "\u{1B}]22;\u{1B}\\"
        public static let resetTerminalBgColor = "\u{1B}]111\u{07}"
        public static let saveCursorState = "\u{1B}[s"
        public static let restoreCursorState = "\u{1B}[u"

        public static let switchToAlternateScreen = OpenTUICore.ANSI.switchToAlternateScreen
        public static let switchToMainScreen = OpenTUICore.ANSI.switchToMainScreen

        public static let enableMouseTracking = "\u{1B}[?1000h"
        public static let disableMouseTracking = "\u{1B}[?1000l"
        public static let enableButtonEventTracking = "\u{1B}[?1002h"
        public static let disableButtonEventTracking = "\u{1B}[?1002l"
        public static let enableAnyEventTracking = "\u{1B}[?1003h"
        public static let disableAnyEventTracking = "\u{1B}[?1003l"
        public static let enableSGRMouseMode = "\u{1B}[?1006h"
        public static let disableSGRMouseMode = "\u{1B}[?1006l"
        public static let mouseSetPixels = "\u{1B}[?1002;1003;1004;1016h"

        // Terminal capability queries
        public static let primaryDeviceAttrs = "\u{1B}[c"
        public static let tertiaryDeviceAttrs = "\u{1B}[=c"
        public static let deviceStatusReport = "\u{1B}[5n"
        public static let xtversion = "\u{1B}[>0q"
        public static let decrqmFocus = "\u{1B}[?1004$p"
        public static let decrqmSgrPixels = "\u{1B}[?1016$p"
        public static let decrqmBracketedPaste = "\u{1B}[?2004$p"
        public static let decrqmSync = "\u{1B}[?2026$p"
        public static let decrqmUnicode = "\u{1B}[?2027$p"
        public static let decrqmColorScheme = "\u{1B}[?2031$p"
        public static let csiUQuery = "\u{1B}[?u"
        public static let xtgettcapMs = "\u{1B}P+q4d73\u{1B}\\"
        public static let xtgettcapTruecolor = "\u{1B}P+q524742\u{1B}\\\u{1B}P+q5463\u{1B}\\"
        public static let kittyGraphicsQuery = "\u{1B}_Gi=31337,s=1,v=1,a=q,t=d,f=24;AAAA\u{1B}\\"
        public static let notificationQueries = "\u{1B}]99;i=opentui-notifications:p=?;\u{1B}\\\u{1B}]1337;Capabilities\u{1B}\\"
        public static let programStatusQuery = "\u{1B}]7501;?\u{1B}\\"

        public static let capabilityQueriesBase =
            decrqmSgrPixels
            + decrqmUnicode
            + decrqmColorScheme
            + decrqmFocus
            + decrqmBracketedPaste
            + decrqmSync

        public static let capabilityQueries =
            capabilityQueriesBase + csiUQuery + notificationQueries + programStatusQuery
        public static let capabilityQueriesFootIsBroken = capabilityQueriesBase + csiUQuery

        // tmux / GNU Screen DCS passthrough framing
        public static let tmuxDcsStart = "\u{1B}Ptmux;"
        public static let tmuxDcsEnd = "\u{1B}\\"
        public static let screenDcsStart = "\u{1B}P"
        public static let screenDcsEnd = "\u{1B}\\"

        public static let sixelGeometryQuery = "\u{1B}[?2;1;0S"
        public static let cursorPositionRequest = "\u{1B}[6n"
        public static let explicitWidthQuery = "\u{1B}]66;w=1; \u{1B}\\"
        public static let scaledTextQuery = "\u{1B}]66;s=2; \u{1B}\\"

        // Focus tracking
        public static let focusSet = "\u{1B}[?1004h"
        public static let focusReset = "\u{1B}[?1004l"

        // Synchronized output
        public static let syncSet = "\u{1B}[?2026h"
        public static let syncReset = "\u{1B}[?2026l"

        // Unicode mode 2027
        public static let unicodeSet = "\u{1B}[?2027h"
        public static let unicodeReset = "\u{1B}[?2027l"

        // Bracketed paste
        public static let bracketedPasteSet = "\u{1B}[?2004h"
        public static let bracketedPasteReset = "\u{1B}[?2004l"

        // Color scheme
        public static let colorSchemeSet = "\u{1B}[?2031h"
        public static let colorSchemeReset = "\u{1B}[?2031l"
        public static let oscThemeQueries = "\u{1B}]10;?\u{07}\u{1B}]11;?\u{07}"

        // Key encoding
        public static let csiUPushFormat = "\u{1B}[>{d}u"
        public static let csiUPop = "\u{1B}[<u"

        // modifyOtherKeys mode
        public static let modifyOtherKeysSet = "\u{1B}[>4;1m"
        public static let modifyOtherKeysReset = "\u{1B}[>4;0m"

        // Movement and erase
        public static let reverseIndex = "\u{1B}M"
        public static let eraseBelowCursor = "\u{1B}[J"

        // OSC 0 - Set window title
        public static let setTerminalTitleFormat = "\u{1B}]0;{s}\u{07}"

        public static func csiUPushSequence(_ flags: UInt8) -> String {
            "\u{1B}[>\(flags)u"
        }

        // parity: native/src/ansi.zig#ANSI.moveToOutput [status=implemented hash=839f5d33992f]
        public static func moveToOutput<S: NativeTerminalByteSink>(
            _ writer: inout S,
            x: UInt32,
            y: UInt32
        ) throws(AnsiError) {
            try writer.writeString(OpenTUICore.ANSI.moveCursor(row: Int(y), col: Int(x)))
        }

        // parity: native/src/ansi.zig#ANSI.fgColorOutput [status=implemented hash=3e1962dbd676]
        public static func fgColorOutput<S: NativeTerminalByteSink>(
            _ writer: inout S,
            r: UInt8,
            g: UInt8,
            b: UInt8
        ) throws(AnsiError) {
            try writer.writeString("\u{1B}[38;2;\(r);\(g);\(b)m")
        }

        // parity: native/src/ansi.zig#ANSI.fgIndexedColorOutput [status=implemented hash=ac02e26a32e9]
        public static func fgIndexedColorOutput<S: NativeTerminalByteSink>(
            _ writer: inout S,
            index: UInt8
        ) throws(AnsiError) {
            try writer.writeString("\u{1B}[38;5;\(index)m")
        }

        // parity: native/src/ansi.zig#ANSI.fgDefaultOutput [status=implemented hash=6f8dc5534049]
        public static func fgDefaultOutput<S: NativeTerminalByteSink>(_ writer: inout S) throws(AnsiError) {
            try writer.writeString("\u{1B}[39m")
        }

        // parity: native/src/ansi.zig#ANSI.bgColorOutput [status=implemented hash=798093a47171]
        public static func bgColorOutput<S: NativeTerminalByteSink>(
            _ writer: inout S,
            r: UInt8,
            g: UInt8,
            b: UInt8
        ) throws(AnsiError) {
            try writer.writeString(OpenTUICore.ANSI.setRgbBackground(r: Int(r), g: Int(g), b: Int(b)))
        }

        // parity: native/src/ansi.zig#ANSI.bgIndexedColorOutput [status=implemented hash=83cfc79abc1c]
        public static func bgIndexedColorOutput<S: NativeTerminalByteSink>(
            _ writer: inout S,
            index: UInt8
        ) throws(AnsiError) {
            try writer.writeString("\u{1B}[48;5;\(index)m")
        }

        // parity: native/src/ansi.zig#ANSI.bgDefaultOutput [status=implemented hash=8e7f2b87091c]
        public static func bgDefaultOutput<S: NativeTerminalByteSink>(_ writer: inout S) throws(AnsiError) {
            try writer.writeString(OpenTUICore.ANSI.resetBackground)
        }

        // parity: native/src/ansi.zig#ANSI.cursorColorOutputWriter [status=implemented hash=7ec7a60690b0]
        public static func cursorColorOutputWriter<S: NativeTerminalByteSink>(
            _ writer: inout S,
            r: UInt8,
            g: UInt8,
            b: UInt8
        ) throws(AnsiError) {
            try writer.writeString("\u{1B}]12;#\(nativeHex2Lower(r))\(nativeHex2Lower(g))\(nativeHex2Lower(b))\u{07}")
        }

        /// OSC 66 takes w up to 7; trailing spaces fill widths beyond 7.
        // parity: native/src/ansi.zig#ANSI.explicitWidthOutput [status=implemented hash=b91d386acb34]
        public static func explicitWidthOutput<S: NativeTerminalByteSink>(
            _ writer: inout S,
            width: UInt32,
            text: [UInt8]
        ) throws(AnsiError) {
            let clamped = min(width, 7)
            try writer.writeString("\u{1B}]66;w=\(clamped);")
            try writer.writeBytes(text)
            try writer.writeString("\u{1B}\\")
            if width > 7 {
                for _ in 7..<width {
                    try writer.writeByte(0x20)
                }
            }
        }

        public static func explicitWidthOutput<S: NativeTerminalByteSink>(
            _ writer: inout S,
            width: UInt32,
            text: String
        ) throws(AnsiError) {
            try explicitWidthOutput(&writer, width: width, text: Array(text.utf8))
        }

        // parity: native/src/ansi.zig#ANSI.setTerminalBgColorOutput [status=implemented hash=0c49e10dc311]
        public static func setTerminalBgColorOutput<S: NativeTerminalByteSink>(
            _ writer: inout S,
            r: UInt8,
            g: UInt8,
            b: UInt8
        ) throws(AnsiError) {
            try writer.writeString("\u{1B}]11;rgb:\(nativeHex2Lower(r))/\(nativeHex2Lower(g))/\(nativeHex2Lower(b))\u{07}")
        }

        // parity: native/src/ansi.zig#ANSI.setMousePointerOutput [status=implemented hash=98440b2ade1c]
        public static func setMousePointerOutput<S: NativeTerminalByteSink>(
            _ writer: inout S,
            shape: String
        ) throws(AnsiError) {
            try writer.writeString("\u{1B}]22;\(shape)\u{1B}\\")
        }

        // parity: native/src/ansi.zig#ANSI.setTerminalTitleOutput [status=implemented hash=30e26b403dce]
        public static func setTerminalTitleOutput<S: NativeTerminalByteSink>(
            _ writer: inout S,
            title: String
        ) throws(AnsiError) {
            try writer.writeString("\u{1B}]0;\(title)\u{07}")
        }
    }

    // parity: native/src/ansi.zig#TextAttributes [status=implemented hash=c6303a7047b7]
    public enum TextAttributes: Sendable {
        public static let NONE: UInt8 = 0
        public static let BOLD: UInt8 = UInt8(OpenTUICore.TextAttributes.bold)
        public static let DIM: UInt8 = UInt8(OpenTUICore.TextAttributes.dim)
        public static let ITALIC: UInt8 = UInt8(OpenTUICore.TextAttributes.italic)
        public static let UNDERLINE: UInt8 = UInt8(OpenTUICore.TextAttributes.underline)
        public static let BLINK: UInt8 = UInt8(OpenTUICore.TextAttributes.blink)
        public static let INVERSE: UInt8 = UInt8(OpenTUICore.TextAttributes.inverse)
        public static let HIDDEN: UInt8 = UInt8(OpenTUICore.TextAttributes.hidden)
        public static let STRIKETHROUGH: UInt8 = UInt8(OpenTUICore.TextAttributes.strikethrough)

        public static let ATTRIBUTE_BASE_MASK: UInt32 = OpenTUICore.TextAttributes.baseMask
        public static let LINK_ID_SHIFT: UInt32 = OpenTUICore.TextAttributes.linkShift
        public static let LINK_ID_PAYLOAD_MASK: UInt32 = OpenTUICore.TextAttributes.linkMask
        public static let LINK_ID_MASK: UInt32 = LINK_ID_PAYLOAD_MASK << LINK_ID_SHIFT

        // parity: native/src/ansi.zig#TextAttributes.getBaseAttributes [status=implemented hash=c55ec7e9d476]
        @inline(__always)
        public static func getBaseAttributes(_ attr: UInt32) -> UInt8 {
            UInt8(truncatingIfNeeded: OpenTUICore.getBaseAttributes(attr))
        }

        // parity: native/src/ansi.zig#TextAttributes.getLinkId [status=implemented hash=7cd4745a7f76]
        @inline(__always)
        public static func getLinkId(_ attr: UInt32) -> UInt32 {
            OpenTUICore.getLinkId(attr)
        }

        // parity: native/src/ansi.zig#TextAttributes.setLinkId [status=implemented hash=88b98d89927a]
        @inline(__always)
        public static func setLinkId(_ attr: UInt32, linkId: UInt32) -> UInt32 {
            OpenTUICore.attributesWithLink(attr, linkId: linkId)
        }

        // parity: native/src/ansi.zig#TextAttributes.hasLink [status=implemented hash=8b62d445bd34]
        @inline(__always)
        public static func hasLink(_ attr: UInt32) -> Bool {
            getLinkId(attr) != 0
        }

        // parity: native/src/ansi.zig#TextAttributes.applyAttributesOutputWriter [status=implemented hash=aea0cd8fb483]
        public static func applyAttributesOutputWriter<S: NativeTerminalByteSink>(
            _ writer: inout S,
            attributes: UInt32
        ) throws(AnsiError) {
            let base = getBaseAttributes(attributes)
            if (base & BOLD) != 0 { try writer.writeString(ANSI.bold) }
            if (base & DIM) != 0 { try writer.writeString(ANSI.dim) }
            if (base & ITALIC) != 0 { try writer.writeString(ANSI.italic) }
            if (base & UNDERLINE) != 0 { try writer.writeString(ANSI.underline) }
            if (base & BLINK) != 0 { try writer.writeString(ANSI.blink) }
            if (base & INVERSE) != 0 { try writer.writeString(ANSI.inverse) }
            if (base & HIDDEN) != 0 { try writer.writeString(ANSI.hidden) }
            if (base & STRIKETHROUGH) != 0 { try writer.writeString(ANSI.strikethrough) }
        }
    }

    // parity: native/src/ansi.zig#hsvToRgb [status=implemented hash=ff16601f63f4]
    public static func hsvToRgb(h: Float, s: Float, v: Float) -> RGBA {
        let clampedH: Float
        if h.isFinite {
            let rem = h.truncatingRemainder(dividingBy: 360.0)
            clampedH = rem < 0 ? rem + 360.0 : rem
        } else {
            clampedH = 0.0
        }
        let clampedS = s.isFinite ? min(Float(1.0), max(Float(0.0), s)) : 0.0
        let clampedV = v.isFinite ? min(Float(1.0), max(Float(0.0), v)) : 0.0

        let scaled = clampedH / 60.0
        let floored = scaled.rounded(.down)
        let sector = Int(floored) % 6
        let fractional = scaled - floored

        let p = clampedV * (1.0 - clampedS)
        let q = clampedV * (1.0 - fractional * clampedS)
        let t = clampedV * (1.0 - (1.0 - fractional) * clampedS)

        let r: Float
        let g: Float
        let b: Float
        switch sector {
        case 0: (r, g, b) = (clampedV, t, p)
        case 1: (r, g, b) = (q, clampedV, p)
        case 2: (r, g, b) = (p, clampedV, t)
        case 3: (r, g, b) = (p, q, clampedV)
        case 4: (r, g, b) = (t, p, clampedV)
        default: (r, g, b) = (clampedV, p, q)
        }
        return rgbaFromFloats(r, g, b, 1.0)
    }
}

// MARK: - 2. native/src/terminal.zig (61 unmapped symbols)

/// Error domain for clipboard sizing / emission on `NativeTerminalState`.
public enum NativeTerminalClipboardError: Error, Equatable, Hashable, Sendable {
    case clipboardPayloadTooLarge
    case notSupported
    case overflow
}

/// Pure-Swift terminal capability detection, mode management, notification & clipboard
/// protocol state machine matching `packages/native/src/terminal.zig`.
/// Bridges directly to `OpenTUICore.TerminalCapabilityDetection`, `OpenTUICore.ThemeMode`,
/// `OpenTUICore.Clipboard`, and `OpenTUICore.AnsiDiffRenderer`.
// parity: native/src/terminal.zig#Terminal [status=implemented hash=7a5d859da330]
public final class NativeTerminalState: @unchecked Sendable {
    private static let kittyQueriesMax = 4
    private static let kittyEscapeFlags: UInt8 =
        UInt8(NativeABI.OT_KITTY_KEYBOARD_DISAMBIGUATE | NativeABI.OT_KITTY_KEYBOARD_ALL_KEYS_AS_ESCAPES)
    private static let notificationQueryId = "opentui-notifications"
    private static let osc52FramingSize = "\u{1B}]52;c;".utf8.count + "\u{1B}\\".utf8.count
    private static let screenOsc52FramingSize = "\u{1B}]52;c;".utf8.count + "\u{07}".utf8.count

    private static let flushInputHook = Mutex<(@Sendable () -> Void)?>(nil)

    /// Installs an optional host hook invoked by `flushInput()` (used by platform tiers).
    public static func setFlushInputHook(_ hook: (@Sendable () -> Void)?) {
        flushInputHook.withLock { $0 = hook }
    }

    // parity: native/src/terminal.zig#Capabilities [status=implemented hash=642b29a1bc0a]
    public struct Capabilities: Equatable, Hashable, Sendable, Codable {
        public var kittyKeyboard: Bool
        public var kittyGraphics: Bool
        public var rgb: Bool
        public var ansi256: Bool
        public var unicode: WidthMethod
        public var sgrPixels: Bool
        public var colorSchemeUpdates: Bool
        public var explicitWidth: Bool
        public var scaledText: Bool
        public var sixel: Bool
        public var focusTracking: Bool
        public var sync: Bool
        public var bracketedPaste: Bool
        public var hyperlinks: Bool
        public var osc52: Bool
        public var notifications: Bool
        public var explicitCursorPositioning: Bool
        public var remote: Bool
        public var programStatus: Bool

        public init(
            kittyKeyboard: Bool = false,
            kittyGraphics: Bool = false,
            rgb: Bool = false,
            ansi256: Bool = false,
            unicode: WidthMethod = .unicode,
            sgrPixels: Bool = false,
            colorSchemeUpdates: Bool = false,
            explicitWidth: Bool = false,
            scaledText: Bool = false,
            sixel: Bool = false,
            focusTracking: Bool = false,
            sync: Bool = false,
            bracketedPaste: Bool = false,
            hyperlinks: Bool = false,
            osc52: Bool = false,
            notifications: Bool = false,
            explicitCursorPositioning: Bool = false,
            remote: Bool = false,
            programStatus: Bool = false
        ) {
            self.kittyKeyboard = kittyKeyboard
            self.kittyGraphics = kittyGraphics
            self.rgb = rgb
            self.ansi256 = ansi256
            self.unicode = unicode
            self.sgrPixels = sgrPixels
            self.colorSchemeUpdates = colorSchemeUpdates
            self.explicitWidth = explicitWidth
            self.scaledText = scaledText
            self.sixel = sixel
            self.focusTracking = focusTracking
            self.sync = sync
            self.bracketedPaste = bracketedPaste
            self.hyperlinks = hyperlinks
            self.osc52 = osc52
            self.notifications = notifications
            self.explicitCursorPositioning = explicitCursorPositioning
            self.remote = remote
            self.programStatus = programStatus
        }

        /// Bridges directly to `OpenTUICore.RendererCapabilities` consumed by `AnsiDiffRenderer`.
        public func toRendererCapabilities(synchronizedOutput: Bool? = nil) -> RendererCapabilities {
            RendererCapabilities(
                rgb: rgb,
                ansi256: ansi256,
                hyperlinks: hyperlinks,
                synchronizedOutput: synchronizedOutput ?? sync,
                explicitWidth: explicitWidth,
                explicitCursorPositioning: explicitCursorPositioning
            )
        }
    }

    // parity: native/src/terminal.zig#NotificationProtocol [status=implemented hash=18938afb9831]
    public enum NotificationProtocol: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
        case none
        case osc9
        case osc777
        case osc99
    }

    private enum NotificationProtocolSource: UInt8, Sendable {
        case none = 0
        case heuristic = 1
        case xtversion = 2
        case query = 3
        case override = 4
    }

    // parity: native/src/terminal.zig#RemoteMode [status=implemented hash=177c2e96a0b4]
    public enum RemoteMode: UInt8, Equatable, Hashable, Sendable, Codable, CaseIterable {
        case auto = 0
        case local = 1
        case remote = 2
    }

    // parity: native/src/terminal.zig#SynchronizedOutput [status=implemented hash=9dab56c5c8a9]
    public enum SynchronizedOutput: UInt8, Equatable, Hashable, Sendable, Codable, CaseIterable {
        case auto = 0
        case always = 1
        case never = 2
    }

    // parity: native/src/terminal.zig#ImageProtocol [status=implemented hash=3434eecb340d]
    public enum ImageProtocol: UInt8, Equatable, Hashable, Sendable, Codable, CaseIterable {
        case auto = 0
        case kitty = 1
        case sixel = 2
        case blocks = 3
    }

    // parity: native/src/terminal.zig#Multiplexer [status=implemented hash=727c7d2ca4c3]
    public enum Multiplexer: UInt8, Equatable, Hashable, Sendable, Codable, CaseIterable {
        case none = 0
        case tmux = 1
        case zellij = 2
        case screen = 3
        case unknown = 4

        public var clipboardPassthrough: ClipboardPassthrough {
            switch self {
            case .tmux: return .tmux
            case .screen: return .screen
            default: return .none
            }
        }
    }

    // parity: native/src/terminal.zig#Osc52Support [status=implemented hash=9d26776e15b4]
    public enum Osc52Support: UInt8, Equatable, Hashable, Sendable, Codable, CaseIterable {
        case unknown = 0
        case supported = 1
        case unsupported = 2

        public var coreValue: OpenTUICore.Osc52Support {
            switch self {
            case .unknown: return .unknown
            case .supported: return .supported
            case .unsupported: return .unsupported
            }
        }
    }

    // parity: native/src/terminal.zig#SCREEN_PASSTHROUGH_CHUNK_SIZE [status=implemented hash=13d725bfa04a]
    public static let SCREEN_PASSTHROUGH_CHUNK_SIZE: Int = OpenTUICore.screenPassthroughChunkSize

    // parity: native/src/terminal.zig#CLIPBOARD_PAYLOAD_SIZE_MAX [status=implemented hash=eb7259c1eb1a]
    public static let CLIPBOARD_PAYLOAD_SIZE_MAX: Int = Int(UInt32.max)

    // parity: native/src/terminal.zig#MouseLevel [status=implemented hash=0134f93c7305]
    public enum MouseLevel: Equatable, Hashable, Sendable, Codable, CaseIterable {
        case none
        case basic
        case drag
        case motion
        case pixels
    }

    // parity: native/src/terminal.zig#CursorStyle [status=implemented hash=96bda106d701]
    public enum CursorStyle: UInt8, Equatable, Hashable, Sendable, Codable, CaseIterable {
        case block = 0
        case line = 1
        case underline = 2
        case `default` = 3

        public var renderStyle: CursorRenderStyle {
            switch self {
            case .block: return .block
            case .line: return .line
            case .underline: return .underline
            case .default: return .default
            }
        }

        public init(renderStyle: CursorRenderStyle) {
            switch renderStyle {
            case .block: self = .block
            case .line: self = .line
            case .underline: self = .underline
            case .default: self = .default
            }
        }
    }

    // parity: native/src/terminal.zig#MousePointerStyle [status=implemented hash=b48637c27374]
    public enum MousePointerStyle: UInt8, Equatable, Hashable, Sendable, Codable, CaseIterable {
        case auto = 0
        case `default` = 1
        case none = 2
        case contextMenu = 3
        case help = 4
        case pointer = 5
        case progress = 6
        case wait = 7
        case cell = 8
        case crosshair = 9
        case text = 10
        case verticalText = 11
        case alias = 12
        case copy = 13
        case move = 14
        case noDrop = 15
        case notAllowed = 16
        case grab = 17
        case grabbing = 18
        case allScroll = 19
        case colResize = 20
        case rowResize = 21
        case nResize = 22
        case eResize = 23
        case sResize = 24
        case wResize = 25
        case neResize = 26
        case nwResize = 27
        case seResize = 28
        case swResize = 29
        case ewResize = 30
        case nsResize = 31
        case neswResize = 32
        case nwseResize = 33
        case zoomIn = 34
        case zoomOut = 35

        // parity: native/src/terminal.zig#MousePointerStyle.toName [status=implemented hash=d28d12a8910a]
        public func toName() -> String {
            switch self {
            case .auto: return "auto"
            case .default: return "default"
            case .none: return "none"
            case .contextMenu: return "context-menu"
            case .help: return "help"
            case .pointer: return "pointer"
            case .progress: return "progress"
            case .wait: return "wait"
            case .cell: return "cell"
            case .crosshair: return "crosshair"
            case .text: return "text"
            case .verticalText: return "vertical-text"
            case .alias: return "alias"
            case .copy: return "copy"
            case .move: return "move"
            case .noDrop: return "no-drop"
            case .notAllowed: return "not-allowed"
            case .grab: return "grab"
            case .grabbing: return "grabbing"
            case .allScroll: return "all-scroll"
            case .colResize: return "col-resize"
            case .rowResize: return "row-resize"
            case .nResize: return "n-resize"
            case .eResize: return "e-resize"
            case .sResize: return "s-resize"
            case .wResize: return "w-resize"
            case .neResize: return "ne-resize"
            case .nwResize: return "nw-resize"
            case .seResize: return "se-resize"
            case .swResize: return "sw-resize"
            case .ewResize: return "ew-resize"
            case .nsResize: return "ns-resize"
            case .neswResize: return "nesw-resize"
            case .nwseResize: return "nwse-resize"
            case .zoomIn: return "zoom-in"
            case .zoomOut: return "zoom-out"
            }
        }
    }

    // parity: native/src/terminal.zig#Options [status=implemented hash=3eec256c2b53]
    public struct Options: Equatable, Hashable, Sendable {
        public var kittyKeyboardFlags: UInt8
        public var remoteMode: RemoteMode
        public var envMap: [String: String]?

        public init(
            kittyKeyboardFlags: UInt8 = UInt8(
                NativeABI.OT_KITTY_KEYBOARD_DISAMBIGUATE | NativeABI.OT_KITTY_KEYBOARD_ALTERNATE_KEYS
            ),
            remoteMode: RemoteMode = .local,
            envMap: [String: String]? = nil
        ) {
            self.kittyKeyboardFlags = kittyKeyboardFlags
            self.remoteMode = remoteMode
            self.envMap = envMap
        }
    }

    // parity: native/src/terminal.zig#TerminalInfo [status=implemented hash=5036a4fa6f93]
    public struct TerminalInfo: Equatable, Hashable, Sendable, Codable {
        public static let maxNameBytes = 64
        public static let maxVersionBytes = 32

        public var name: String
        public var version: String
        public var fromXtversion: Bool

        public init(name: String = "", version: String = "", fromXtversion: Bool = false) {
            self.name = Self.clampUTF8(name, maxBytes: Self.maxNameBytes)
            self.version = Self.clampUTF8(version, maxBytes: Self.maxVersionBytes)
            self.fromXtversion = fromXtversion
        }

        fileprivate static func clampUTF8(_ value: String, maxBytes: Int) -> String {
            let bytes = Array(value.utf8)
            guard bytes.count > maxBytes else { return value }
            return String(decoding: bytes[0..<maxBytes], as: UTF8.self)
        }
    }

    public struct CursorPosition: Equatable, Hashable, Sendable, Codable {
        public var x: UInt32
        public var y: UInt32
        public var visible: Bool

        public init(x: UInt32, y: UInt32, visible: Bool) {
            self.x = x
            self.y = y
            self.visible = visible
        }
    }

    public struct CursorStyleState: Equatable, Hashable, Sendable, Codable {
        public var style: CursorStyle
        public var blinking: Bool

        public init(style: CursorStyle, blinking: Bool) {
            self.style = style
            self.blinking = blinking
        }
    }

    public struct CursorState: Equatable, Hashable, Sendable {
        public var row: UInt16 = 0
        public var col: UInt16 = 0
        public var x: UInt32 = 1
        public var y: UInt32 = 1
        public var visible: Bool = true
        public var style: CursorStyle = .default
        public var blinking: Bool = false
        public var color: RGBA = NativeANSI.rgbColor(255, 255, 255, 255)
    }

    public struct ModeState: Equatable, Hashable, Sendable {
        public var altScreen: Bool = false
        public var kittyKeyboard: Bool = false
        public var kittyKeyboardFlags: UInt8 = 0
        public var kittyGeneration: UInt32 = 0
        public var kittyConfirmed: Bool = false
        public var kittyQueries: [UInt32] = []
        public var bracketedPaste: Bool = false
        public var mouse: Bool = false
        public var mouseMovement: Bool = true
        public var mouseWasEnabled: Bool = false
        public var pixelMouse: Bool = false
        public var colorSchemeUpdates: Bool = false
        public var themeQueriesSent: Bool = false
        public var focusTracking: Bool = false
        public var modifyOtherKeys: Bool = false
        public var unicode: Bool = false
        public var mousePointer: MousePointerStyle = .default
        public var cursor: CursorState = CursorState()
    }

    public var caps: Capabilities = Capabilities()
    public var opts: Options = Options()
    private var hostEnvMap: [String: String]? = nil
    private var envUsesHostMap: Bool = false
    public var remote: Bool = false
    public var multiplexer: Multiplexer = .none
    public var osc52Support: Osc52Support = .unknown
    public var isFoot: Bool = false
    public var skipGraphicsQuery: Bool = false
    public var graphicsEnabled: Bool = true
    public var imageProtocol: ImageProtocol = .auto
    public var kittyGraphicsQueried: Bool = false
    public var sixelQueried: Bool = false
    public var skipExplicitWidthQuery: Bool = false
    public var startupCursorQueryPending: Bool = false
    public var startupCursorQueryCaptured: Bool = false
    public var explicitWidthProbeReportsPending: UInt8 = 0
    public var explicitWidthProbeFirstColumn: UInt16 = 0
    public var explicitWidthProbed: Bool = false
    public var replySentinel: Bool = false
    public var synchronizedOutputMode: SynchronizedOutput = .auto
    public var syncReplySettled: Bool = false
    public var multiplexerOnHost: Bool = false
    public var mode2027: UInt8? = nil
    private var hostEnvHyperlinks: Bool = false
    public var hyperlinksOverride: Bool? = nil
    public var state: ModeState = ModeState()
    public var termInfo: TerminalInfo = TerminalInfo()
    public var notificationProtocol: NotificationProtocol = .none
    public var notificationProtocolAuthoritative: Bool = false
    private var notificationProtocolSource: NotificationProtocolSource = .none
    public var notificationIdCounter: UInt64 = 0
    public var isWindowsConsoleHost: Bool = false

    // parity: native/src/terminal.zig#init [status=implemented hash=237e14b90394]
    public init(options: Options = Options()) {
        self.opts = options
        checkEnvironmentOverrides()
    }

    // parity: native/src/terminal.zig#deinit [status=implemented hash=82fbcc1f02c0]
    public func deinitState() {
        hostEnvMap = nil
        envUsesHostMap = false
        opts = Options()
        caps = Capabilities()
        remote = false
        multiplexer = .none
        osc52Support = .unknown
        isFoot = false
        skipGraphicsQuery = false
        graphicsEnabled = true
        imageProtocol = .auto
        kittyGraphicsQueried = false
        sixelQueried = false
        skipExplicitWidthQuery = false
        startupCursorQueryPending = false
        startupCursorQueryCaptured = false
        explicitWidthProbeReportsPending = 0
        explicitWidthProbeFirstColumn = 0
        explicitWidthProbed = false
        replySentinel = false
        synchronizedOutputMode = .auto
        syncReplySettled = false
        multiplexerOnHost = false
        mode2027 = nil
        hostEnvHyperlinks = false
        hyperlinksOverride = nil
        state = ModeState()
        termInfo = TerminalInfo()
        notificationProtocol = .none
        notificationProtocolAuthoritative = false
        notificationProtocolSource = .none
        notificationIdCounter = 0
    }

    // parity: native/src/terminal.zig#setHostEnvVar [status=implemented hash=b8d3cfd03443]
    public func setHostEnvVar(key: String, value: String) {
        if hostEnvMap == nil {
            hostEnvMap = [:]
        }
        hostEnvMap?[key] = value
        opts.envMap = hostEnvMap
        envUsesHostMap = true
        checkEnvironmentOverrides()
    }

    // parity: native/src/terminal.zig#adoptHostEnvironment [status=implemented hash=a75826aaa69e]
    public func adoptHostEnvironment(_ environment: [String: String]) {
        hostEnvMap = environment
        opts.envMap = hostEnvMap
        envUsesHostMap = true
        checkEnvironmentOverrides()
    }

    // parity: native/src/terminal.zig#resetInputModes [status=implemented hash=6bf66feaed43]
    public func resetInputModes<S: NativeTerminalByteSink>(into tty: inout S) throws(NativeANSI.AnsiError) {
        try tty.writeString(NativeANSI.ANSI.showCursor)
        try tty.writeString(NativeANSI.ANSI.reset)
        try tty.writeString(NativeANSI.ANSI.resetMousePointer)
        state.mousePointer = .default

        if state.kittyKeyboard {
            try setKittyKeyboard(into: &tty, enable: false, flags: 0)
        }
        if state.modifyOtherKeys {
            try setModifyOtherKeys(into: &tty, enable: false)
        }
        if state.mouseWasEnabled {
            try forceDisableMouseMode(into: &tty)
        }
        if state.bracketedPaste {
            try setBracketedPaste(into: &tty, enable: false)
        }
        if state.focusTracking {
            try setFocusTracking(into: &tty, enable: false)
        }
    }

    // parity: native/src/terminal.zig#resetOutputModes [status=implemented hash=f822855bc5df]
    public func resetOutputModes<S: NativeTerminalByteSink>(into tty: inout S) throws(NativeANSI.AnsiError) {
        if state.colorSchemeUpdates {
            try setColorSchemeUpdates(into: &tty, enable: false)
        }

        let before = mode2027 == 1
        if (mode2027 ?? 0) < 3 && state.unicode != before {
            try tty.writeString(before ? NativeANSI.ANSI.unicodeSet : NativeANSI.ANSI.unicodeReset)
        }
        state.unicode = false

        try NativeANSI.ANSI.setTerminalTitleOutput(&tty, title: "")
    }

    // parity: native/src/terminal.zig#enterAltScreen [status=implemented hash=6e05241062e8]
    public func enterAltScreen<S: NativeTerminalByteSink>(into tty: inout S) throws(NativeANSI.AnsiError) {
        try tty.writeString(NativeANSI.ANSI.switchToAlternateScreen)
        state.altScreen = true
    }

    // parity: native/src/terminal.zig#exitAltScreen [status=implemented hash=0f292f1b9c66]
    public func exitAltScreen<S: NativeTerminalByteSink>(into tty: inout S) throws(NativeANSI.AnsiError) {
        try tty.writeString(NativeANSI.ANSI.switchToMainScreen)
        state.altScreen = false
    }

    // parity: native/src/terminal.zig#queryTerminalSend [status=implemented hash=e3abb1c0b376]
    public func queryTerminalSend<S: NativeTerminalByteSink>(into tty: inout S) throws(NativeANSI.AnsiError) {
        checkEnvironmentOverrides()
        startupCursorQueryPending = true
        startupCursorQueryCaptured = false

        try setColorSchemeUpdates(into: &tty, enable: true)
        try queryThemeColors(into: &tty)
        state.themeQueriesSent = true

        try tty.writeString(NativeANSI.ANSI.xtversion + NativeANSI.ANSI.hideCursor)
        try tty.writeString(NativeANSI.ANSI.cursorPositionRequest)

        if !insideScreen() {
            try tty.writeString(NativeANSI.ANSI.xtgettcapMs)
        }
        if isFoot {
            try tty.writeString(NativeANSI.ANSI.capabilityQueriesFootIsBroken)
        } else {
            try tty.writeString(NativeANSI.ANSI.capabilityQueries)
            if !caps.rgb && !consoleTruecolor() && !insideScreen() {
                try tty.writeString(NativeANSI.ANSI.xtgettcapTruecolor)
            }
        }
        state.kittyQueries.removeAll(keepingCapacity: true)
        recordKittyQuery()

        if !skipGraphicsQuery && !isInTmux() && !remoteTmuxHint() {
            try tty.writeString(NativeANSI.ANSI.kittyGraphicsQuery)
        }
        if !replySentinel {
            try tty.writeString(NativeANSI.ANSI.primaryDeviceAttrs)
        }
        explicitWidthProbeReportsPending = 0
    }

    // parity: native/src/terminal.zig#queryExplicitWidth [status=implemented hash=dd401471442e]
    public func queryExplicitWidth<S: NativeTerminalByteSink>(into tty: inout S) throws(NativeANSI.AnsiError) {
        guard !skipExplicitWidthQuery else { return }
        explicitWidthProbeReportsPending = 2
        let rowTwo = "\u{1B}[2H"
        try tty.writeString(
            NativeANSI.ANSI.saveCursorState
                + rowTwo
                + NativeANSI.ANSI.explicitWidthQuery
                + NativeANSI.ANSI.cursorPositionRequest
                + rowTwo
                + NativeANSI.ANSI.scaledTextQuery
                + NativeANSI.ANSI.cursorPositionRequest
                + NativeANSI.ANSI.restoreCursorState
        )
    }

    private func consoleTruecolor() -> Bool {
        isWindowsConsoleHost && opts.remoteMode != .remote
    }

    // parity: native/src/terminal.zig#enableDetectedFeatures [status=implemented hash=0976f084462f]
    public func enableDetectedFeatures<S: NativeTerminalByteSink>(
        into tty: inout S,
        useKittyKeyboard: Bool
    ) throws(NativeANSI.AnsiError) {
        if consoleTruecolor() { caps.rgb = true }
        checkEnvironmentOverrides()

        if !state.modifyOtherKeys && !state.kittyKeyboard {
            try setModifyOtherKeys(into: &tty, enable: true)
        }

        if caps.kittyKeyboard && useKittyKeyboard {
            if state.modifyOtherKeys {
                try setModifyOtherKeys(into: &tty, enable: false)
            }
            try setKittyKeyboard(into: &tty, enable: true, flags: opts.kittyKeyboardFlags)
        }

        let unicode = (caps.unicode == .unicode || caps.unicode == .unicodeWide) && !caps.explicitWidth
        if unicode != state.unicode {
            try tty.writeString(unicode ? NativeANSI.ANSI.unicodeSet : NativeANSI.ANSI.unicodeReset)
            state.unicode = unicode
        }

        if caps.bracketedPaste {
            try setBracketedPaste(into: &tty, enable: true)
        }

        if caps.focusTracking {
            try setFocusTracking(into: &tty, enable: true)
        }

        if !state.colorSchemeUpdates {
            try setColorSchemeUpdates(into: &tty, enable: true)
        }

        if !state.themeQueriesSent {
            try queryThemeColors(into: &tty)
            state.themeQueriesSent = true
        }
    }

    // parity: native/src/terminal.zig#queryThemeColors [status=implemented hash=f5c3bbd73fb2]
    public func queryThemeColors<S: NativeTerminalByteSink>(into tty: inout S) throws(NativeANSI.AnsiError) {
        try tty.writeString(NativeANSI.ANSI.oscThemeQueries)
    }

    // MARK: Notification Protocol Helpers

    private func clearNotificationProtocol() {
        notificationProtocol = .none
        notificationProtocolAuthoritative = false
        notificationProtocolSource = .none
        caps.notifications = false
    }

    private static func notificationProtocolPriority(_ protocol: NotificationProtocol) -> UInt8 {
        switch `protocol` {
        case .none: return 0
        case .osc9: return 1
        case .osc777: return 2
        case .osc99: return 3
        }
    }

    private func setNotificationProtocol(_ proto: NotificationProtocol, source: NotificationProtocolSource) {
        guard proto != .none else { return }
        if isInZellij() && source != .override {
            if source != .query || proto != .osc99 { return }
        }
        if source.rawValue < notificationProtocolSource.rawValue { return }
        if source.rawValue == notificationProtocolSource.rawValue
            && Self.notificationProtocolPriority(proto) < Self.notificationProtocolPriority(notificationProtocol)
        {
            return
        }
        notificationProtocol = proto
        notificationProtocolAuthoritative = source != .heuristic
        notificationProtocolSource = source
        caps.notifications = true
    }

    private func enforceNotificationProtocolForMultiplexer() {
        if !isInZellij() || notificationProtocolSource == .override { return }
        if notificationProtocolSource == .query && notificationProtocol == .osc99 { return }
        clearNotificationProtocol()
    }

    private func applyNotificationHeuristic(_ value: String) {
        if isInZellij() { return }
        if let proto = Self.detectNotificationProtocol(value) {
            setNotificationProtocol(proto, source: .heuristic)
        }
    }

    private func applyNotificationProtocolOverride(_ value: String) {
        if value == "0"
            || nativeEqlIgnoreCase(value, "false")
            || nativeEqlIgnoreCase(value, "off")
            || nativeEqlIgnoreCase(value, "none")
        {
            clearNotificationProtocol()
            notificationProtocolAuthoritative = true
            notificationProtocolSource = .override
            return
        }
        if value == "1" || nativeEqlIgnoreCase(value, "true") || nativeEqlIgnoreCase(value, "on") {
            return
        }
        if nativeEqlIgnoreCase(value, "osc99") {
            setNotificationProtocol(.osc99, source: .override)
        } else if nativeEqlIgnoreCase(value, "osc777") {
            setNotificationProtocol(.osc777, source: .override)
        } else if nativeEqlIgnoreCase(value, "osc9") {
            setNotificationProtocol(.osc9, source: .override)
        }
    }

    private static func detectNotificationProtocol(_ value: String) -> NotificationProtocol? {
        if nativeContainsIgnoreCase(value, "kitty") || nativeContainsIgnoreCase(value, "foot") {
            return .osc99
        }
        let osc777Tokens = [
            "ghostty", "wezterm", "warp", "hterm", "blink", "contour", "vte", "gnome",
            "tilix", "terminator", "xfce", "urxvt", "rxvt", "windows terminal",
            "windows_terminal", "terminology",
        ]
        for token in osc777Tokens {
            if nativeContainsIgnoreCase(value, token) { return .osc777 }
        }
        if nativeContainsIgnoreCase(value, "iterm")
            || nativeContainsIgnoreCase(value, "Apple_Terminal")
            || nativeContainsIgnoreCase(value, "Terminal.app")
        {
            return .osc9
        }
        return nil
    }

    private static func termFeaturesHasCode(_ features: [UInt8], code: [UInt8]) -> Bool {
        var i = 0
        while i < features.count {
            let c = features[i]
            if !nativeIsAsciiAlphaNum(c) { break }
            if !nativeIsAsciiUpper(c) {
                i += 1
                continue
            }
            let start = i
            i += 1
            while i < features.count && nativeIsAsciiLower(features[i]) { i += 1 }
            if Array(features[start..<i]) == code { return true }
            while i < features.count && nativeIsAsciiDigit(features[i]) { i += 1 }
        }
        return false
    }

    private static func findOscTerminator(_ bytes: [UInt8], from start: Int) -> Int {
        var i = start
        while i < bytes.count {
            if bytes[i] == 0x07 { return i }
            if bytes[i] == 0x1B && i + 1 < bytes.count && bytes[i + 1] == UInt8(ascii: "\\") {
                return i
            }
            i += 1
        }
        return bytes.count
    }

    private func parseItermCapabilities(_ response: [UInt8]) {
        let prefix = Array("\u{1B}]1337;Capabilities=".utf8)
        let codeNo = Array("No".utf8)
        var searchStart = 0
        while let pos = nativeFindBytes(response, prefix, from: searchStart) {
            let start = pos + prefix.count
            let end = Self.findOscTerminator(response, from: start)
            if Self.termFeaturesHasCode(Array(response[start..<end]), code: codeNo) {
                setNotificationProtocol(.osc9, source: .query)
                return
            }
            searchStart = end
        }
    }

    private func parseOsc99NotificationQuery(_ response: [UInt8]) {
        let prefix = Array("\u{1B}]99;".utf8)
        let idNeedle = Array(("i=" + Self.notificationQueryId).utf8)
        let queryNeedle = Array("p=?".utf8)
        let pNeedle = Array("p=".utf8)
        let titleNeedle = Array("title".utf8)
        var searchStart = 0
        while let pos = nativeFindBytes(response, prefix, from: searchStart) {
            let payloadStart = pos + prefix.count
            let end = Self.findOscTerminator(response, from: payloadStart)
            let payload = Array(response[payloadStart..<end])
            if nativeFindBytes(payload, idNeedle) != nil
                && nativeFindBytes(payload, queryNeedle) != nil
                && nativeFindBytes(payload, pNeedle) != nil
                && nativeFindBytes(payload, titleNeedle) != nil
            {
                setNotificationProtocol(.osc99, source: .query)
                return
            }
            searchStart = end
        }
    }

    private func parseProgramStatusReply(_ response: [UInt8]) {
        let prefix = Array("\u{1B}]7501;".utf8)
        guard let pos = nativeFindBytes(response, prefix) else { return }
        let start = pos + prefix.count
        let end = Self.findOscTerminator(response, from: start)
        let payload = Array(response[start..<end])
        let colonIdx = payload.firstIndex(of: UInt8(ascii: ":")) ?? payload.count
        var lo = 0
        var hi = colonIdx
        while lo < hi && payload[lo] == 0x20 { lo += 1 }
        while hi > lo && payload[hi - 1] == 0x20 { hi -= 1 }
        if hi - lo == 1 && payload[lo] == UInt8(ascii: "?") {
            caps.programStatus = true
        }
    }

    // parity: native/src/terminal.zig#checkEnvironmentOverrides [status=implemented hash=33de96a31d3b]
    public func checkEnvironmentOverrides() {
        defer {
            caps.ansi256 = caps.ansi256 || caps.rgb
            caps.unicode = selectWidthMethod()
        }

        if isXtversionTmux() {
            multiplexer = .tmux
        } else if isXtversionZellij() {
            multiplexer = .zellij
        } else {
            multiplexer = .none
        }

        isFoot = termInfo.fromXtversion && nativeContainsIgnoreCase(getTerminalName(), "foot")
        skipGraphicsQuery = false
        graphicsEnabled = true
        imageProtocol = .auto
        skipExplicitWidthQuery = false
        hyperlinksOverride = nil
        caps.bracketedPaste = true

        if opts.remoteMode == .remote {
            remote = true
            caps.remote = true
        } else if opts.remoteMode == .local {
            remote = false
            caps.remote = false
        }

        guard let envMap = opts.envMap else { return }

        if opts.remoteMode == .auto {
            remote = remote || Self.isRemoteSessionEnv(envMap)
            caps.remote = remote
        }

        if let term = envMap["TERM"], nativeContainsIgnoreCase(term, "256color") {
            caps.ansi256 = true
        }
        if insideScreen() {
            caps.rgb = false
            caps.ansi256 = true
        } else if let colorterm = envMap["COLORTERM"],
                  colorterm == "truecolor" || colorterm == "24bit"
        {
            caps.rgb = true
        }

        let forceTruecolor = envMap["OPENTUI_FORCE_TRUECOLOR"] ?? ""
        if forceTruecolor == "1" || forceTruecolor == "true" {
            caps.rgb = true
        }

        let remoteEnv = identityEnv() == nil
        if !termInfo.fromXtversion {
            if !remoteEnv && envMap["TMUX"] != nil {
                multiplexer = .tmux
                caps.explicitCursorPositioning = true
            } else if !remoteEnv
                && (envMap["ZELLIJ"] != nil || envMap["ZELLIJ_SESSION_NAME"] != nil || envMap["ZELLIJ_PANE_ID"] != nil)
            {
                multiplexer = .zellij
                if termInfo.name.isEmpty {
                    termInfo.name = "Zellij"
                }
            } else if insideScreen() {
                multiplexer = .screen
                skipGraphicsQuery = true
                caps.explicitCursorPositioning = true
                caps.osc52 = true
            } else if !remoteEnv {
                let term = envMap["TERM"] ?? ""
                if term.hasPrefix("tmux") {
                    multiplexer = .tmux
                    caps.explicitCursorPositioning = true
                }
                if nativeFindBytes(Array(term.utf8), Array("alacritty".utf8)) != nil {
                    caps.explicitCursorPositioning = true
                }
            }
        }
        if remoteEnv { return }

        if let term = envMap["TERM"] {
            applyNotificationHeuristic(term)
            isFoot = isFoot || nativeContainsIgnoreCase(term, "foot")
        }

        if let features = envMap["TERM_FEATURES"],
           Self.termFeaturesHasCode(Array(features.utf8), code: Array("No".utf8))
        {
            setNotificationProtocol(.osc9, source: .heuristic)
        }

        if let val = envMap["OPENTUI_GRAPHICS"] {
            if val == "false" || val == "0" {
                skipGraphicsQuery = true
                graphicsEnabled = false
                kittyGraphicsQueried = false
                sixelQueried = false
                caps.kittyGraphics = false
                caps.sixel = false
            } else if val == "true" || val == "1" {
                skipGraphicsQuery = false
            }
        }

        if let value = envMap["OPENTUI_IMAGE_PROTOCOL"] {
            if nativeEqlIgnoreCase(value, "auto") {
                imageProtocol = .auto
            } else if nativeEqlIgnoreCase(value, "kitty") {
                imageProtocol = .kitty
            } else if nativeEqlIgnoreCase(value, "sixel") {
                imageProtocol = .sixel
            } else if nativeEqlIgnoreCase(value, "blocks") {
                imageProtocol = .blocks
            }
        }

        if !termInfo.fromXtversion {
            if let prog = envMap["TERM_PROGRAM"] {
                if !isInZellij() {
                    termInfo.name = TerminalInfo.clampUTF8(prog, maxBytes: TerminalInfo.maxNameBytes)
                }
                if !isInZellij() && prog == "tmux" {
                    multiplexer = .tmux
                    caps.explicitCursorPositioning = true
                }
                applyNotificationHeuristic(prog)
                if !isInZellij(), let ver = envMap["TERM_PROGRAM_VERSION"] {
                    termInfo.version = TerminalInfo.clampUTF8(ver, maxBytes: TerminalInfo.maxVersionBytes)
                }
                if prog == "vscode" {
                    caps.kittyKeyboard = false
                    caps.kittyGraphics = false
                } else if prog == "Alacritty" {
                    caps.explicitCursorPositioning = true
                }
            }
            if envMap["ALACRITTY_SOCKET"] != nil || envMap["ALACRITTY_LOG"] != nil {
                caps.explicitCursorPositioning = true
                if termInfo.name.isEmpty {
                    termInfo.name = "Alacritty"
                }
            }
        }

        if envMap["WT_SESSION"] != nil {
            if !insideScreen() { caps.rgb = true }
            setNotificationProtocol(.osc777, source: .heuristic)
        }

        if let proto = envMap["OPENTUI_NOTIFICATION_PROTOCOL"] {
            applyNotificationProtocolOverride(proto)
        }
        if let value = envMap["OPENTUI_NOTIFICATIONS"] {
            if value == "0" || nativeEqlIgnoreCase(value, "false") || nativeEqlIgnoreCase(value, "off") {
                applyNotificationProtocolOverride("none")
            }
        }

        enforceNotificationProtocolForMultiplexer()

        if !termInfo.fromXtversion && envMap["VHS_RECORD"] != nil {
            caps.kittyKeyboard = false
            caps.kittyGraphics = false
        }

        if let val = envMap["OPENTUI_FORCE_EXPLICIT_WIDTH"] {
            if val == "true" || val == "1" {
                caps.explicitWidth = true
            } else if val == "false" || val == "0" {
                caps.explicitWidth = false
                skipExplicitWidthQuery = true
            }
        }

        if (isFoot || hostEnvHyperlinks) && multiplexer != .none {
            caps.hyperlinks = false
            hostEnvHyperlinks = false
        }

        if !caps.hyperlinks && termInfo.fromXtversion {
            if Self.isHyperlinkTerm(getTerminalName()) {
                caps.hyperlinks = true
            }
        }

        if !caps.hyperlinks && !termInfo.fromXtversion {
            if let term = envMap["TERM"], Self.isHyperlinkTerm(term) && (!isFoot || multiplexer == .none) {
                caps.hyperlinks = true
            }
        }

        if !caps.hyperlinks && !termInfo.fromXtversion && multiplexer == .none {
            if Self.isHyperlinkHostEnv(envMap) {
                caps.hyperlinks = true
                hostEnvHyperlinks = true
            }
        }

        if let value = envMap["FORCE_HYPERLINK"] {
            hyperlinksOverride = !(value == "0" || nativeEqlIgnoreCase(value, "false") || nativeEqlIgnoreCase(value, "off"))
        }
        if let enabled = hyperlinksOverride {
            caps.hyperlinks = enabled
        }

        if !caps.osc52 && !termInfo.fromXtversion {
            if envMap["WT_SESSION"] != nil {
                caps.osc52 = true
            }
            if !caps.osc52 && (isInTmux() || envMap["STY"] != nil) {
                caps.osc52 = true
            }
            if !caps.osc52, let prog = envMap["TERM_PROGRAM"], Self.isOsc52Term(prog) {
                caps.osc52 = true
            }
            if !caps.osc52, let term = envMap["TERM"] {
                let termBytes = Array(term.utf8)
                if Self.isOsc52Term(term)
                    || nativeFindBytes(termBytes, Array("256color".utf8)) != nil
                    || nativeFindBytes(termBytes, Array("xterm".utf8)) != nil
                {
                    caps.osc52 = true
                }
            }
        }
    }

    private static func isRemoteSessionEnv(_ envMap: [String: String]) -> Bool {
        envMap["SSH_CONNECTION"] != nil
            || envMap["SSH_CLIENT"] != nil
            || envMap["SSH_TTY"] != nil
            || envMap["MOSH_CONNECTION"] != nil
    }

    private static func writeMouseDisableSequences<S: NativeTerminalByteSink>(into tty: inout S) throws(NativeANSI.AnsiError) {
        try tty.writeString(NativeANSI.ANSI.disableAnyEventTracking)
        try tty.writeString(NativeANSI.ANSI.disableButtonEventTracking)
        try tty.writeString(NativeANSI.ANSI.disableMouseTracking)
        try tty.writeString(NativeANSI.ANSI.disableSGRMouseMode)
    }

    // parity: native/src/terminal.zig#setMouseMode [status=implemented hash=bca59bd43a66]
    public func setMouseMode<S: NativeTerminalByteSink>(
        into tty: inout S,
        enable: Bool,
        enableMovement: Bool
    ) throws(NativeANSI.AnsiError) {
        if enable {
            if state.mouse && state.mouseMovement == enableMovement { return }
        } else if !state.mouse {
            return
        }

        if enable {
            state.mouse = true
            state.mouseMovement = enableMovement
            state.mouseWasEnabled = true
            if !enableMovement {
                try tty.writeString(NativeANSI.ANSI.disableAnyEventTracking)
            }
            try tty.writeString(NativeANSI.ANSI.enableMouseTracking)
            try tty.writeString(NativeANSI.ANSI.enableButtonEventTracking)
            if enableMovement {
                try tty.writeString(NativeANSI.ANSI.enableAnyEventTracking)
            }
            try tty.writeString(NativeANSI.ANSI.enableSGRMouseMode)
        } else {
            state.mouse = false
            state.pixelMouse = false
            try Self.writeMouseDisableSequences(into: &tty)
        }
    }

    // parity: native/src/terminal.zig#forceDisableMouseMode [status=implemented hash=b830a15794bc]
    public func forceDisableMouseMode<S: NativeTerminalByteSink>(into tty: inout S) throws(NativeANSI.AnsiError) {
        state.mouse = false
        state.pixelMouse = false
        try Self.writeMouseDisableSequences(into: &tty)
    }

    // parity: native/src/terminal.zig#setBracketedPaste [status=implemented hash=1965b482b6a4]
    public func setBracketedPaste<S: NativeTerminalByteSink>(
        into tty: inout S,
        enable: Bool
    ) throws(NativeANSI.AnsiError) {
        try tty.writeString(enable ? NativeANSI.ANSI.bracketedPasteSet : NativeANSI.ANSI.bracketedPasteReset)
        state.bracketedPaste = enable
    }

    // parity: native/src/terminal.zig#setFocusTracking [status=implemented hash=b4d2f1df95a0]
    public func setFocusTracking<S: NativeTerminalByteSink>(
        into tty: inout S,
        enable: Bool
    ) throws(NativeANSI.AnsiError) {
        try tty.writeString(enable ? NativeANSI.ANSI.focusSet : NativeANSI.ANSI.focusReset)
        state.focusTracking = enable
    }

    // parity: native/src/terminal.zig#setKittyKeyboard [status=implemented hash=58ca0b7aead3]
    public func setKittyKeyboard<S: NativeTerminalByteSink>(
        into tty: inout S,
        enable: Bool,
        flags: UInt8
    ) throws(NativeANSI.AnsiError) {
        if enable == state.kittyKeyboard { return }
        if enable {
            try tty.writeString(NativeANSI.ANSI.csiUPushSequence(flags))
        } else {
            try tty.writeString(NativeANSI.ANSI.csiUPop)
        }
        state.kittyKeyboard = enable
        state.kittyKeyboardFlags = enable ? flags : 0
        state.kittyGeneration &+= 1
        state.kittyConfirmed = false

        if !enable || !replySentinel || state.kittyQueries.count >= Self.kittyQueriesMax {
            return
        }
        try tty.writeString(NativeANSI.ANSI.csiUQuery)
        recordKittyQuery()
    }

    // parity: native/src/terminal.zig#kittyQueryOutstanding [status=implemented hash=1e6e08a15060]
    public func kittyQueryOutstanding() -> Bool {
        guard replySentinel, state.kittyKeyboard, let last = state.kittyQueries.last else {
            return false
        }
        return last == state.kittyGeneration
    }

    private func recordKittyQuery() {
        if state.kittyQueries.count < Self.kittyQueriesMax {
            state.kittyQueries.append(state.kittyGeneration)
        }
    }

    private func answerKittyQuery(_ flags: UInt32) {
        guard !state.kittyQueries.isEmpty else { return }
        let generation = state.kittyQueries.removeFirst()
        guard generation == state.kittyGeneration else { return }
        if (state.kittyKeyboardFlags & Self.kittyEscapeFlags) == 0
            || (flags & UInt32(Self.kittyEscapeFlags)) == 0
        {
            return
        }
        state.kittyConfirmed = true
    }

    // parity: native/src/terminal.zig#setModifyOtherKeys [status=implemented hash=275a5ba171dc]
    public func setModifyOtherKeys<S: NativeTerminalByteSink>(
        into tty: inout S,
        enable: Bool
    ) throws(NativeANSI.AnsiError) {
        try tty.writeString(enable ? NativeANSI.ANSI.modifyOtherKeysSet : NativeANSI.ANSI.modifyOtherKeysReset)
        state.modifyOtherKeys = enable
    }

    // parity: native/src/terminal.zig#setColorSchemeUpdates [status=implemented hash=e02af8c774c0]
    public func setColorSchemeUpdates<S: NativeTerminalByteSink>(
        into tty: inout S,
        enable: Bool
    ) throws(NativeANSI.AnsiError) {
        try tty.writeString(enable ? NativeANSI.ANSI.colorSchemeSet : NativeANSI.ANSI.colorSchemeReset)
        state.colorSchemeUpdates = enable
    }

    // parity: native/src/terminal.zig#restoreTerminalModes [status=implemented hash=013f29ef8ea6]
    public func restoreTerminalModes<S: NativeTerminalByteSink>(into tty: inout S) throws(NativeANSI.AnsiError) {
        if state.mouse {
            if !state.mouseMovement {
                try tty.writeString(NativeANSI.ANSI.disableAnyEventTracking)
            }
            try tty.writeString(NativeANSI.ANSI.enableMouseTracking)
            try tty.writeString(NativeANSI.ANSI.enableButtonEventTracking)
            if state.mouseMovement {
                try tty.writeString(NativeANSI.ANSI.enableAnyEventTracking)
            }
            try tty.writeString(NativeANSI.ANSI.enableSGRMouseMode)
        }

        if state.focusTracking {
            try tty.writeString(NativeANSI.ANSI.focusSet)
        }

        if state.bracketedPaste {
            try tty.writeString(NativeANSI.ANSI.bracketedPasteSet)
        }

        if state.kittyKeyboard {
            let flags = state.kittyKeyboardFlags
            try setKittyKeyboard(into: &tty, enable: false, flags: 0)
            try setKittyKeyboard(into: &tty, enable: true, flags: flags)
        }

        if state.modifyOtherKeys {
            try tty.writeString(NativeANSI.ANSI.modifyOtherKeysSet)
        }
    }

    // MARK: Capability Response Parsing

    private func parseKittyGraphicsResponse(_ response: [UInt8]) {
        guard graphicsEnabled else { return }
        let startMarker = Array("\u{1B}_G".utf8)
        let endMarker = Array("\u{1B}\\".utf8)
        let idField = Array("i=31337".utf8)
        var offset = 0
        while let start = nativeFindBytes(response, startMarker, from: offset) {
            guard let end = nativeFindBytes(response, endMarker, from: start + 3) else { return }
            let frame = Array(response[(start + 3)..<end])
            let controlEnd = frame.firstIndex(of: UInt8(ascii: ";")) ?? frame.count
            let control = frame[0..<controlEnd]
            for part in control.split(separator: UInt8(ascii: ","), omittingEmptySubsequences: false) {
                if Array(part) == idField {
                    kittyGraphicsQueried = true
                    caps.kittyGraphics = true
                    return
                }
            }
            offset = end + 2
        }
    }

    private func parseSixelDeviceAttributes(_ response: [UInt8]) -> Bool {
        let graphics = graphicsEnabled && !skipGraphicsQuery
        let prefix = Array("\u{1B}[?".utf8)
        var found = false
        var offset = 0
        while let start = nativeFindBytes(response, prefix, from: offset) {
            var end = start + 3
            while end < response.count && (nativeIsAsciiDigit(response[end]) || response[end] == UInt8(ascii: ";")) {
                end += 1
            }
            if end >= response.count { return found }
            offset = end + 1
            if response[end] != UInt8(ascii: "c") { continue }
            found = true
            if !graphics { continue }
            let body = response[(start + 3)..<end]
            for param in body.split(separator: UInt8(ascii: ";"), omittingEmptySubsequences: false) {
                if param.count == 1 && param[param.startIndex] == UInt8(ascii: "4") {
                    sixelQueried = true
                    caps.sixel = true
                }
            }
        }
        return found
    }

    private static func semanticVersionAtLeast(_ version: String, major reqMajor: UInt32, minor reqMinor: UInt32) -> Bool {
        let bytes = Array(version.utf8)
        let dashIdx = bytes.firstIndex(of: UInt8(ascii: "-"))
        let core = dashIdx.map { Array(bytes[0..<$0]) } ?? bytes
        let parts = core.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = nativeParseUInt32(parts[0]),
              let minor = nativeParseUInt32(parts[1]),
              let patch = nativeParseUInt32(parts[2])
        else { return false }

        if major > reqMajor || (major == reqMajor && minor > reqMinor) { return true }
        if major != reqMajor || minor != reqMinor { return false }
        if patch > 0 { return true }
        guard let dashIdx else { return true }
        let suffix = Array(bytes[(dashIdx + 1)...])
        let suffixParts = suffix.split(separator: UInt8(ascii: "-"), omittingEmptySubsequences: false)
        guard suffixParts.count == 2 else { return false }
        let commits = suffixParts[0]
        let revision = suffixParts[1]
        guard !commits.isEmpty, revision.count >= 2, revision[revision.startIndex] == UInt8(ascii: "g") else {
            return false
        }
        guard nativeParseUInt32(commits) != nil else { return false }
        for b in revision.dropFirst() where !nativeIsAsciiHex(b) { return false }
        return true
    }

    private static func ghosttyWideGraphemeWidths(_ version: String) -> Bool {
        if semanticVersionAtLeast(version, major: 1, minor: 3) { return true }
        let prefix = "0.0.0-"
        let bytes = Array(version.utf8)
        let prefixLen = prefix.utf8.count
        guard version.hasPrefix(prefix), bytes.count > prefixLen + 8, bytes[prefixLen + 8] == UInt8(ascii: ".") else {
            return false
        }
        let dateSlice = bytes[prefixLen..<(prefixLen + 8)]
        guard let date = nativeParseUInt32(dateSlice) else { return false }
        return date >= 20_260_224
    }

    private static func wezTermBuildAtLeast(_ version: String, requiredDate: UInt32) -> Bool {
        let bytes = Array(version.utf8)
        var parts: [ArraySlice<UInt8>] = []
        var segStart = 0
        for i in 0..<bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "-") || b == UInt8(ascii: ".") || b == UInt8(ascii: "_") {
                parts.append(bytes[segStart..<i])
                segStart = i + 1
            }
        }
        parts.append(bytes[segStart..<bytes.count])
        guard parts.count >= 3 else { return false }
        let dateText = parts[0]
        let timeText = parts[1]
        let hashText = parts[2]
        guard dateText.count == 8, timeText.count == 6, hashText.count == 8 else { return false }
        for supplement in parts.dropFirst(3) where supplement.isEmpty { return false }
        for b in dateText where !nativeIsAsciiDigit(b) { return false }
        for b in timeText where !nativeIsAsciiDigit(b) { return false }
        for b in hashText where !nativeIsAsciiHex(b) { return false }

        let dStart = dateText.startIndex
        guard let year = nativeParseUInt32(dateText[dStart..<(dStart + 4)]),
              let month = nativeParseUInt32(dateText[(dStart + 4)..<(dStart + 6)]),
              let day = nativeParseUInt32(dateText[(dStart + 6)..<(dStart + 8)]),
              month >= 1 && month <= 12
        else { return false }
        let leap = (year % 4 == 0) && (year % 100 != 0 || year % 400 == 0)
        let days: [UInt32] = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard day >= 1 && day <= days[Int(month - 1)] else { return false }

        let tStart = timeText.startIndex
        guard let hour = nativeParseUInt32(timeText[tStart..<(tStart + 2)]),
              let minute = nativeParseUInt32(timeText[(tStart + 2)..<(tStart + 4)]),
              let second = nativeParseUInt32(timeText[(tStart + 4)..<(tStart + 6)]),
              hour <= 23 && minute <= 59 && second <= 59
        else { return false }

        guard let date = nativeParseUInt32(dateText) else { return false }
        return date >= requiredDate
    }

    private func applyKnownGraphicsIdentity() {
        guard graphicsEnabled, multiplexer == .none, termInfo.fromXtversion else { return }
        let name = getTerminalName()
        let version = getTerminalVersion()
        if nativeEqlIgnoreCase(name, "kitty") {
            caps.kittyGraphics = true
            return
        }
        if nativeEqlIgnoreCase(name, "ghostty") {
            caps.kittyGraphics = true
            return
        }
        if nativeEqlIgnoreCase(name, "foot") && Self.semanticVersionAtLeast(version, major: 1, minor: 2) {
            caps.sixel = true
            return
        }
        if nativeEqlIgnoreCase(name, "wezterm") && Self.wezTermBuildAtLeast(version, requiredDate: 20_200_620) {
            caps.sixel = true
        }
    }

    private enum WidthIdentity {
        case unknown
        case wcwidth
        case graphemes
        case ghostty
    }

    private func identityEnv() -> [String: String]? {
        guard let envMap = opts.envMap else { return nil }
        if opts.remoteMode == .auto && remote && envUsesHostMap {
            return nil
        }
        return envMap
    }

    private func remoteTmuxHint() -> Bool {
        if identityEnv() != nil { return false }
        guard let env = opts.envMap else { return false }
        if let tmux = env["TMUX"], !tmux.isEmpty { return true }
        return (env["TERM"] ?? "").hasPrefix("tmux")
    }

    private func envWidthIdentity(_ env: [String: String]) -> WidthIdentity {
        if env["TERMUX_VERSION"] != nil || env["VHS_RECORD"] != nil { return .wcwidth }
        let term = env["TERM"] ?? ""
        if term.hasPrefix("xterm-kitty") { return .graphemes }
        if term.hasPrefix("alacritty") || term.hasPrefix("rxvt") { return .wcwidth }
        if !term.isEmpty && !term.hasPrefix("xterm") { return .unknown }
        let program = env["TERM_PROGRAM"] ?? ""
        if nativeEqlIgnoreCase(program, "ghostty")
            && !remote
            && Self.ghosttyWideGraphemeWidths(env["TERM_PROGRAM_VERSION"] ?? "")
        {
            return .ghostty
        }
        if program == "vscode" || program == "Apple_Terminal" { return .wcwidth }
        if !program.isEmpty || env["KONSOLE_VERSION"] != nil { return .unknown }
        if env["VTE_VERSION"] != nil
            || env["XTERM_VERSION"] != nil
            || env["ALACRITTY_SOCKET"] != nil
            || env["ALACRITTY_LOG"] != nil
        {
            return .wcwidth
        }
        return .unknown
    }

    private static func xtversionWidthIdentity(name: String, version: String) -> WidthIdentity {
        if nativeEqlIgnoreCase(name, "libghostty")
            || (nativeEqlIgnoreCase(name, "ghostty") && ghosttyWideGraphemeWidths(version))
        {
            return .ghostty
        }
        if nativeEqlIgnoreCase(name, "kitty") || nativeEqlIgnoreCase(name, "iTerm2") {
            return .graphemes
        }
        if nativeEqlIgnoreCase(name, "XTerm")
            || nativeEqlIgnoreCase(name, "VTE")
            || nativeEqlIgnoreCase(name, "xterm.js")
        {
            return .wcwidth
        }
        return .unknown
    }

    private static func tmuxGraphemes(_ version: String) -> Bool {
        let release = version.hasPrefix("next-") ? String(version.dropFirst(5)) : version
        let bytes = Array(release.utf8)
        guard let dot = bytes.firstIndex(of: UInt8(ascii: ".")) else { return false }
        guard let major = nativeParseUInt32(bytes[0..<dot]) else { return false }
        let minorStart = dot + 1
        var minorEnd = minorStart
        while minorEnd < bytes.count && nativeIsAsciiDigit(bytes[minorEnd]) { minorEnd += 1 }
        guard let minor = nativeParseUInt32(bytes[minorStart..<minorEnd]) else { return false }
        return major > 3 || (major == 3 && minor >= 6)
    }

    private func selectWidthMethod() -> WidthMethod {
        if let env = opts.envMap {
            if env["OPENTUI_FORCE_NOZWJ"] != nil { return .noZWJ }
            if env["OPENTUI_FORCE_UNICODE"] != nil { return .unicode }
            if env["OPENTUI_FORCE_WCWIDTH"] != nil { return .wcwidth }
        }
        let envMap = identityEnv()
        let envTmuxInner = envMap.map { $0["STY"] != nil || $0["ZELLIJ"] != nil } ?? false
        switch multiplexer {
        case .none:
            break
        case .tmux:
            if termInfo.fromXtversion || mode2027 == nil {
                let graphemes = getTerminalName() == "tmux" && Self.tmuxGraphemes(getTerminalVersion())
                return (graphemes && (termInfo.fromXtversion || !envTmuxInner)) ? .unicode : .wcwidth
            }
        default:
            return .wcwidth
        }

        let identity: WidthIdentity
        if termInfo.fromXtversion {
            identity = Self.xtversionWidthIdentity(name: getTerminalName(), version: getTerminalVersion())
        } else if let envMap {
            identity = envWidthIdentity(envMap)
        } else {
            identity = .unknown
        }

        guard let mode = mode2027 else {
            switch identity {
            case .unknown, .graphemes: return .unicode
            case .wcwidth: return .wcwidth
            case .ghostty: return .unicodeWide
            }
        }
        if (mode == 0 || mode == 4) && identity != .graphemes { return .wcwidth }
        return identity == .ghostty ? .unicodeWide : .unicode
    }

    // parity: native/src/terminal.zig#processCapabilityResponse [status=implemented hash=151d78ac60d4]
    public func processCapabilityResponse(_ response: String) {
        processCapabilityResponse(Array(response.utf8))
    }

    /// Raw-byte entry point for capability response parsing (also compatible with `isCapabilityResponse(_:)`).
    public func processCapabilityResponse(_ response: [UInt8]) {
        parseOsc99NotificationQuery(response)
        parseItermCapabilities(response)
        parseProgramStatusReply(response)
        let truecolorReply = parseXtgettcap(response)
        parseKittyGraphicsResponse(response)
        let deviceAttributes = parseSixelDeviceAttributes(response)

        // DECRPM responses
        if nativeFindBytes(response, Array("1016;2$y".utf8)) != nil {
            caps.sgrPixels = true
        }
        if let start = nativeFindBytes(response, Array("?2027;".utf8)) {
            let replyStart = start + 6
            if replyStart + 2 < response.count,
               response[replyStart] >= UInt8(ascii: "0"),
               response[replyStart] <= UInt8(ascii: "4"),
               response[replyStart + 1] == UInt8(ascii: "$"),
               response[replyStart + 2] == UInt8(ascii: "y")
            {
                mode2027 = response[replyStart] - UInt8(ascii: "0")
            }
        }
        if nativeFindBytes(response, Array("2031;1$y".utf8)) != nil
            || nativeFindBytes(response, Array("2031;2$y".utf8)) != nil
        {
            caps.colorSchemeUpdates = true
        }
        if nativeFindBytes(response, Array("1004;1$y".utf8)) != nil
            || nativeFindBytes(response, Array("1004;2$y".utf8)) != nil
        {
            caps.focusTracking = true
        }
        if nativeFindBytes(response, Array("2026;1$y".utf8)) != nil
            || nativeFindBytes(response, Array("2026;2$y".utf8)) != nil
        {
            caps.sync = true
        }
        if nativeFindBytes(response, Array("2004;1$y".utf8)) != nil
            || nativeFindBytes(response, Array("2004;2$y".utf8)) != nil
        {
            caps.bracketedPaste = true
        }

        // Parse cursor position reports: ESC[row;colR
        let csiPrefix: [UInt8] = [0x1B, UInt8(ascii: "[")]
        var scanPos = 0
        while scanPos < response.count {
            guard let esc = nativeFindBytes(response, csiPrefix, from: scanPos) else { break }
            var pos = esc + 2

            let rowStart = pos
            while pos < response.count && nativeIsAsciiDigit(response[pos]) { pos += 1 }
            if pos == rowStart || pos >= response.count || response[pos] != UInt8(ascii: ";") {
                scanPos = esc + 2
                continue
            }
            guard let row = nativeParseUInt16(response[rowStart..<pos]) else {
                scanPos = pos + 1
                continue
            }

            pos += 1
            let colStart = pos
            while pos < response.count && nativeIsAsciiDigit(response[pos]) { pos += 1 }
            if pos == colStart || pos >= response.count || response[pos] != UInt8(ascii: "R") {
                scanPos = colStart
                continue
            }
            guard let col = nativeParseUInt16(response[colStart..<pos]) else {
                scanPos = pos + 1
                continue
            }

            if startupCursorQueryPending && !startupCursorQueryCaptured && row >= 1 && col >= 1 {
                setCursorPosition(x: UInt32(col), y: UInt32(row), visible: state.cursor.visible)
                startupCursorQueryCaptured = true
                startupCursorQueryPending = false
            } else if explicitWidthProbeReportsPending > 0 && row == 2 && col <= 3 {
                let probeIndex = 2 - explicitWidthProbeReportsPending
                explicitWidthProbeReportsPending -= 1
                syncReplySettled = true
                if probeIndex == 0 {
                    explicitWidthProbeFirstColumn = col
                }
                if probeIndex == 1 && explicitWidthProbeFirstColumn == 2 && col >= 2 {
                    caps.explicitWidth = true
                    caps.scaledText = col == 3
                }
            }

            scanPos = pos + 1
        }

        if deviceAttributes { syncReplySettled = true }
        if deviceAttributes && replySentinel {
            startupCursorQueryPending = false
            explicitWidthProbeReportsPending = 0
        }

        // Parse XTVERSION: ESC P > | name version ESC \
        let xtPrefix = Array("\u{1B}P>|".utf8)
        let stSuffix = Array("\u{1B}\\".utf8)
        if let pos = nativeFindBytes(response, xtPrefix) {
            let start = pos + 4
            if let end = nativeFindBytes(response, stSuffix, from: start) {
                let termStr = String(decoding: response[start..<end], as: UTF8.self)
                parseXtversion(termStr)
            }
        }

        if termInfo.fromXtversion && nativeEqlIgnoreCase(getTerminalName(), "kitty") {
            caps.kittyKeyboard = true
            caps.bracketedPaste = true
            caps.hyperlinks = true
        }

        if termInfo.fromXtversion && !skipExplicitWidthQuery && !explicitWidthProbed {
            let name = getTerminalName()
            let version = getTerminalVersion()
            let kitty = nativeEqlIgnoreCase(name, "kitty")
                && Self.semanticVersionAtLeast(version, major: 0, minor: 40)
            let foot = nativeEqlIgnoreCase(name, "foot")
                && Self.semanticVersionAtLeast(version, major: 1, minor: 21)
            if kitty || foot { caps.explicitWidth = true }
            if kitty { caps.scaledText = true }
        }

        if !insideScreen()
            && (truecolorReply || (termInfo.fromXtversion && Self.isTruecolorTerminal(getTerminalName())))
        {
            caps.rgb = true
            caps.ansi256 = true
        }

        // Kitty keyboard query response: CSI ? <flags> u
        let csiQPrefix = Array("\u{1B}[?".utf8)
        var kOffset = 0
        while let start = nativeFindBytes(response, csiQPrefix, from: kOffset) {
            let digitsStart = start + 3
            var digitsEnd = digitsStart
            while digitsEnd < response.count && nativeIsAsciiDigit(response[digitsEnd]) {
                digitsEnd += 1
            }
            if digitsEnd > digitsStart && digitsEnd < response.count && response[digitsEnd] == UInt8(ascii: "u") {
                caps.kittyKeyboard = true
                let parsed = nativeParseUInt32(response[digitsStart..<digitsEnd]) ?? UInt32.max
                answerKittyQuery(parsed)
                break
            }
            kOffset = digitsStart
        }

        if nativeFindBytes(response, Array("alacritty".utf8)) != nil {
            caps.explicitCursorPositioning = true
        }

        let responseStr = String(decoding: response, as: UTF8.self)
        if !caps.osc52 && Self.isOsc52Term(responseStr) {
            caps.osc52 = true
        }
        if !caps.hyperlinks && Self.isHyperlinkTerm(responseStr) {
            caps.hyperlinks = true
        }
        if let enabled = hyperlinksOverride {
            caps.hyperlinks = enabled
        }

        caps.unicode = selectWidthMethod()
        if isInTmux() {
            caps.explicitCursorPositioning = true
            caps.focusTracking = true
            kittyGraphicsQueried = false
            caps.kittyGraphics = false
            sixelQueried = false
            caps.sixel = false
        }
    }

    /// Convenience bridge combining `TerminalCapabilityDetection.isCapabilityResponse(_:)`
    /// with `processCapabilityResponse(_:)`.
    public func classifyAndProcessCapabilityResponse(_ sequence: String) -> Bool {
        let recognized = isCapabilityResponse(sequence) || isExplicitWidthReport(sequence)
        if recognized {
            processCapabilityResponse(sequence)
        }
        return recognized
    }

    private func parseXtgettcap(_ response: [UInt8]) -> Bool {
        let prefix = Array("\u{1B}P1+r".utf8)
        let stSuffix = Array("\u{1B}\\".utf8)
        let msName = Array("4d73".utf8)
        let rgbName = Array("524742".utf8)
        let tcName = Array("5463".utf8)

        var truecolor = false
        var scanPos = 0
        while let start = nativeFindBytes(response, prefix, from: scanPos) {
            let bodyStart = start + prefix.count
            guard let end = nativeFindBytes(response, stSuffix, from: bodyStart) else { break }
            let result = Array(response[bodyStart..<end])
            scanPos = end + 2

            let sep = result.firstIndex(of: UInt8(ascii: "="))
            let name = sep.map { Array(result[0..<$0]) } ?? result
            let value = sep.map { Array(result[($0 + 1)...]) } ?? []
            if (sep != nil && value.isEmpty) || (value.count % 2 != 0) { continue }
            var allHex = true
            for b in value where !nativeIsAsciiHex(b) {
                allHex = false
                break
            }
            guard allHex else { continue }
            if nativeEqlIgnoreCase(name, msName) && !value.isEmpty {
                osc52Support = .supported
                caps.osc52 = true
            } else if nativeEqlIgnoreCase(name, rgbName) || nativeEqlIgnoreCase(name, tcName) {
                truecolor = true
            }
        }
        return truecolor
    }

    private static func isTruecolorTerminal(_ name: String) -> Bool {
        for known in ["kitty", "ghostty", "WezTerm", "foot", "XTerm", "iTerm2", "tmux"] {
            if nativeEqlIgnoreCase(name, known) { return true }
        }
        return false
    }

    private static func isOsc52Term(_ value: String) -> Bool {
        for token in ["iterm", "kitty", "alacritty", "wezterm", "contour", "foot", "rio", "ghostty", "tmux", "screen"] {
            if nativeContainsIgnoreCase(value, token) { return true }
        }
        return false
    }

    private static func isHyperlinkTerm(_ value: String) -> Bool {
        for token in ["ghostty", "kitty", "wezterm", "alacritty", "foot", "iterm", "xterm.js", "terminology"] {
            if nativeContainsIgnoreCase(value, token) { return true }
        }
        return nativeEqlIgnoreCase(value, "rex") || nativeEqlIgnoreCase(value, "xterm-rex")
    }

    private static func isHyperlinkHostEnv(_ envMap: [String: String]) -> Bool {
        if let program = envMap["TERM_PROGRAM"],
           program == "vscode" || program == "zed" || program == "mintty"
        {
            return true
        }
        if let version = envMap["VTE_VERSION"] {
            guard let parsed = nativeParseUInt32(Array(version.utf8)[...]) else { return false }
            return parsed >= 5202
        }
        let term = envMap["TERM"] ?? ""
        return envMap["WT_SESSION"] != nil && (term.isEmpty || term.hasPrefix("xterm"))
    }

    // parity: native/src/terminal.zig#synchronizedOutput [status=implemented hash=8e3aff4e0b5c]
    public func synchronizedOutput() -> Bool {
        switch synchronizedOutputMode {
        case .always: return true
        case .never: return false
        case .auto: return !remote || !syncReplySettled || (caps.sync && !multiplexerOnHost)
        }
    }

    // parity: native/src/terminal.zig#getCapabilities [status=implemented hash=7b190a3cabec]
    public func getCapabilities() -> Capabilities {
        caps
    }

    // parity: native/src/terminal.zig#setMousePointerStyle [status=implemented hash=b71b877862a5]
    public func setMousePointerStyle(_ style: MousePointerStyle) {
        state.mousePointer = style
    }

    // parity: native/src/terminal.zig#getMousePointer [status=implemented hash=685634f4e52f]
    public func getMousePointer() -> MousePointerStyle {
        state.mousePointer
    }

    // parity: native/src/terminal.zig#setCursorPosition [status=implemented hash=d6c56984f859]
    public func setCursorPosition(x: UInt32, y: UInt32, visible: Bool) {
        let clampedX = max(1, x)
        let clampedY = max(1, y)
        state.cursor.x = clampedX
        state.cursor.y = clampedY
        state.cursor.visible = visible
        state.cursor.col = UInt16(clamping: clampedX - 1)
        state.cursor.row = UInt16(clamping: clampedY - 1)
    }

    // parity: native/src/terminal.zig#setCursorStyle [status=implemented hash=990746c15218]
    public func setCursorStyle(_ style: CursorStyle, blinking: Bool) {
        state.cursor.style = style
        state.cursor.blinking = blinking
    }

    // parity: native/src/terminal.zig#setCursorColor [status=implemented hash=1e4dae58b607]
    public func setCursorColor(_ color: RGBA) {
        state.cursor.color = color
    }

    // parity: native/src/terminal.zig#getCursorPosition [status=implemented hash=6a71845fd8a7]
    public func getCursorPosition() -> CursorPosition {
        CursorPosition(x: state.cursor.x, y: state.cursor.y, visible: state.cursor.visible)
    }

    // parity: native/src/terminal.zig#getCursorStyle [status=implemented hash=8f00f3b4c666]
    public func getCursorStyle() -> CursorStyleState {
        CursorStyleState(style: state.cursor.style, blinking: state.cursor.blinking)
    }

    // parity: native/src/terminal.zig#getCursorColor [status=implemented hash=5479a6868742]
    public func getCursorColor() -> RGBA {
        state.cursor.color
    }

    // parity: native/src/terminal.zig#setKittyKeyboardFlags [status=implemented hash=07ee09e3bfd8]
    public func setKittyKeyboardFlags(_ flags: UInt8) {
        opts.kittyKeyboardFlags = flags
    }

    // MARK: Notifications & Clipboard Sizing

    private static func oscEnd(_ multiplexer: Multiplexer) -> String {
        multiplexer == .screen ? "\u{07}" : "\u{1B}\\"
    }

    private static func sanitizeNotificationText(
        _ text: String,
        replaceSemicolon: Bool,
        asciiOnly: Bool
    ) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            let cp = scalar.value
            if isControl(cp) || (asciiOnly && cp >= 0x80) || (replaceSemicolon && cp == UInt32(UInt8(ascii: ";"))) {
                out.append(0x20)
            } else {
                out.append(contentsOf: String(scalar).utf8)
            }
        }
        return out
    }

    /// Streaming DCS passthrough encoder for tmux and GNU Screen matching `terminal.zig#PassthroughWriter`.
    public struct PassthroughWriter<S: NativeTerminalByteSink> {
        public var sink: S
        public let multiplexer: Multiplexer
        private var buffer: [UInt8] = []

        public init(sink: S, multiplexer: Multiplexer) throws(NativeANSI.AnsiError) {
            var writer = sink
            if multiplexer == .tmux {
                try writer.writeString(NativeANSI.ANSI.tmuxDcsStart)
            }
            self.sink = writer
            self.multiplexer = multiplexer
            if multiplexer == .screen {
                self.buffer.reserveCapacity(SCREEN_PASSTHROUGH_CHUNK_SIZE)
            }
        }

        // parity: native/src/terminal.zig#PassthroughWriter.writeAll [status=implemented hash=71a51de28103]
        public mutating func writeAll(_ bytes: [UInt8]) throws(NativeANSI.AnsiError) {
            switch multiplexer {
            case .tmux:
                var start = 0
                for idx in 0..<bytes.count where bytes[idx] == 0x1B {
                    if idx > start {
                        try sink.writeBytes(Array(bytes[start..<idx]))
                    }
                    try sink.writeBytes([0x1B, 0x1B])
                    start = idx + 1
                }
                if start < bytes.count {
                    try sink.writeBytes(Array(bytes[start..<bytes.count]))
                }
            case .screen:
                for byte in bytes {
                    if buffer.count == SCREEN_PASSTHROUGH_CHUNK_SIZE {
                        let endsWithEsc = buffer.last == 0x1B
                        if endsWithEsc { buffer.removeLast() }
                        try flush()
                        if endsWithEsc { buffer.append(0x1B) }
                    }
                    buffer.append(byte)
                }
            default:
                try sink.writeBytes(bytes)
            }
        }

        // parity: native/src/terminal.zig#PassthroughWriter.writeByte [status=implemented hash=4f09d620932d]
        public mutating func writeByte(_ byte: UInt8) throws(NativeANSI.AnsiError) {
            try writeAll([byte])
        }

        public mutating func finish() throws(NativeANSI.AnsiError) {
            if multiplexer == .tmux {
                try sink.writeString(NativeANSI.ANSI.tmuxDcsEnd)
            }
            try flush()
        }

        public mutating func flush() throws(NativeANSI.AnsiError) {
            guard !buffer.isEmpty else { return }
            try sink.writeString(NativeANSI.ANSI.screenDcsStart)
            try sink.writeBytes(buffer)
            try sink.writeString(NativeANSI.ANSI.screenDcsEnd)
            buffer.removeAll(keepingCapacity: true)
        }
    }

    private static func writePassthrough<S: NativeTerminalByteSink>(
        _ payload: [UInt8],
        multiplexer: Multiplexer,
        into tty: inout S
    ) throws(NativeANSI.AnsiError) {
        var writer = try PassthroughWriter(sink: tty, multiplexer: multiplexer)
        try writer.writeAll(payload)
        try writer.finish()
        tty = writer.sink
    }

    // parity: native/src/terminal.zig#writeNotification [status=implemented hash=c48759168549]
    public func writeNotification<S: NativeTerminalByteSink>(
        into tty: inout S,
        message: String,
        title: String? = nil
    ) throws(NativeANSI.AnsiError) -> Bool {
        guard caps.notifications && notificationProtocol != .none else { return false }
        let notificationTitle = title ?? ""
        notificationIdCounter &+= 1

        var payload: [UInt8] = []
        let end = Self.oscEnd(multiplexer)
        let asciiOnly = multiplexer == .screen

        switch notificationProtocol {
        case .none:
            return false
        case .osc99:
            let id = "opentui-\(notificationIdCounter)"
            if !notificationTitle.isEmpty {
                let encodedTitle = base64Encode(notificationTitle)
                payload.append(contentsOf: "\u{1B}]99;i=\(id):p=title:e=1:d=0;\(encodedTitle)\(end)".utf8)
            }
            let encodedBody = base64Encode(message)
            payload.append(contentsOf: "\u{1B}]99;i=\(id):p=body:e=1:d=1;\(encodedBody)\(end)".utf8)
        case .osc777:
            payload.append(contentsOf: "\u{1B}]777;notify;".utf8)
            if title != nil {
                payload.append(contentsOf: Self.sanitizeNotificationText(notificationTitle, replaceSemicolon: true, asciiOnly: asciiOnly))
                payload.append(UInt8(ascii: ";"))
                payload.append(contentsOf: Self.sanitizeNotificationText(message, replaceSemicolon: true, asciiOnly: asciiOnly))
            } else {
                payload.append(contentsOf: Self.sanitizeNotificationText(message, replaceSemicolon: true, asciiOnly: asciiOnly))
                payload.append(UInt8(ascii: ";"))
            }
            payload.append(contentsOf: end.utf8)
        case .osc9:
            let lead = !notificationTitle.isEmpty ? notificationTitle : message
            let startsWithDigit = lead.utf8.first.map(nativeIsAsciiDigit) ?? false
            payload.append(contentsOf: (startsWithDigit ? "\u{1B}]9; " : "\u{1B}]9;").utf8)
            if !notificationTitle.isEmpty {
                payload.append(contentsOf: Self.sanitizeNotificationText(notificationTitle, replaceSemicolon: false, asciiOnly: asciiOnly))
                payload.append(contentsOf: ": ".utf8)
            }
            payload.append(contentsOf: Self.sanitizeNotificationText(message, replaceSemicolon: false, asciiOnly: asciiOnly))
            payload.append(contentsOf: end.utf8)
        }

        try Self.writePassthrough(payload, multiplexer: multiplexer, into: &tty)
        return true
    }

    // parity: native/src/terminal.zig#clipboardSequenceSize [status=implemented hash=bd85d00d61e0]
    public func clipboardSequenceSize(payloadLen: Int) throws(NativeTerminalClipboardError) -> Int {
        guard payloadLen >= 0 && payloadLen <= Self.CLIPBOARD_PAYLOAD_SIZE_MAX else {
            throw .clipboardPayloadTooLarge
        }
        let (paddedLen, ov1) = payloadLen.addingReportingOverflow(2)
        guard !ov1 else { throw .overflow }
        let (encodedLen, ov2) = (paddedLen / 3).multipliedReportingOverflow(by: 4)
        guard !ov2 else { throw .overflow }
        let (sequenceLen, ov3) = encodedLen.addingReportingOverflow(Self.osc52FramingSize)
        guard !ov3 else { throw .overflow }

        if isInTmux() {
            let (wrappedLen, ov4) = sequenceLen.addingReportingOverflow(2)
            guard !ov4 else { throw .overflow }
            let envelope = NativeANSI.ANSI.tmuxDcsStart.utf8.count + NativeANSI.ANSI.tmuxDcsEnd.utf8.count
            let (total, ov5) = wrappedLen.addingReportingOverflow(envelope)
            guard !ov5 else { throw .overflow }
            return total
        }

        if isInScreen() {
            let (screenSeqLen, ov4) = encodedLen.addingReportingOverflow(Self.screenOsc52FramingSize)
            guard !ov4 else { throw .overflow }
            let chunkCount = ((screenSeqLen - 1) / Self.SCREEN_PASSTHROUGH_CHUNK_SIZE) + 1
            let envelopeUnit = NativeANSI.ANSI.screenDcsStart.utf8.count + NativeANSI.ANSI.screenDcsEnd.utf8.count
            let (envelopesLen, ov5) = chunkCount.multipliedReportingOverflow(by: envelopeUnit)
            guard !ov5 else { throw .overflow }
            let (total, ov6) = screenSeqLen.addingReportingOverflow(envelopesLen)
            guard !ov6 else { throw .overflow }
            return total
        }

        return sequenceLen
    }

    /// Emits an OSC 52 clipboard sequence via `OpenTUICore.encodeOsc52Sequence` with multiplexer framing.
    public func writeClipboardSequence<S: NativeTerminalByteSink>(
        into tty: inout S,
        target: ClipboardTarget,
        payloadBytes: [UInt8]
    ) throws {
        guard osc52Support != .unsupported else {
            throw NativeTerminalClipboardError.notSupported
        }
        _ = try clipboardSequenceSize(payloadLen: payloadBytes.count)
        let sequence = encodeOsc52Sequence(
            payloadBytes: payloadBytes,
            target: target,
            passthrough: multiplexer.clipboardPassthrough
        )
        try tty.writeString(sequence)
    }

    private func parseXtversion(_ termStr: String) {
        guard !termStr.isEmpty else { return }
        termInfo.name = ""
        termInfo.version = ""
        caps.kittyGraphics = kittyGraphicsQueried
        caps.sixel = sixelQueried

        let bytes = Array(termStr.utf8)
        if let parenPos = bytes.firstIndex(of: UInt8(ascii: "(")) {
            termInfo.name = TerminalInfo.clampUTF8(
                String(decoding: bytes[0..<parenPos], as: UTF8.self),
                maxBytes: TerminalInfo.maxNameBytes
            )
            if let closePos = bytes[(parenPos + 1)...].firstIndex(of: UInt8(ascii: ")")) {
                termInfo.version = TerminalInfo.clampUTF8(
                    String(decoding: bytes[(parenPos + 1)..<closePos], as: UTF8.self),
                    maxBytes: TerminalInfo.maxVersionBytes
                )
            }
        } else if let spacePos = bytes.firstIndex(of: 0x20) {
            termInfo.name = TerminalInfo.clampUTF8(
                String(decoding: bytes[0..<spacePos], as: UTF8.self),
                maxBytes: TerminalInfo.maxNameBytes
            )
            termInfo.version = TerminalInfo.clampUTF8(
                String(decoding: bytes[(spacePos + 1)...], as: UTF8.self),
                maxBytes: TerminalInfo.maxVersionBytes
            )
        } else {
            termInfo.name = TerminalInfo.clampUTF8(termStr, maxBytes: TerminalInfo.maxNameBytes)
            termInfo.version = ""
        }

        termInfo.fromXtversion = true
        isFoot = nativeContainsIgnoreCase(getTerminalName(), "foot")
        if getTerminalName() == "tmux" {
            multiplexer = .tmux
        } else if nativeEqlIgnoreCase(getTerminalName(), "Zellij") {
            multiplexer = .zellij
        } else {
            multiplexer = .none
        }

        if !isInZellij(), let proto = Self.detectNotificationProtocol(getTerminalName()) {
            setNotificationProtocol(proto, source: .xtversion)
        }

        enforceNotificationProtocolForMultiplexer()
        applyKnownGraphicsIdentity()
    }

    // parity: native/src/terminal.zig#isXtversionTmux [status=implemented hash=eb3fb474beb5]
    public func isXtversionTmux() -> Bool {
        termInfo.fromXtversion && getTerminalName() == "tmux"
    }

    // parity: native/src/terminal.zig#isXtversionZellij [status=implemented hash=2f1726d230d5]
    public func isXtversionZellij() -> Bool {
        termInfo.fromXtversion && nativeEqlIgnoreCase(getTerminalName(), "Zellij")
    }

    // parity: native/src/terminal.zig#isInTmux [status=implemented hash=72ad7326f89c]
    public func isInTmux() -> Bool {
        multiplexer == .tmux
    }

    // parity: native/src/terminal.zig#isInZellij [status=implemented hash=12ee5f7b1323]
    public func isInZellij() -> Bool {
        multiplexer == .zellij
    }

    // parity: native/src/terminal.zig#isInScreen [status=implemented hash=5ed572031bfe]
    public func isInScreen() -> Bool {
        multiplexer == .screen
    }

    private func insideScreen() -> Bool {
        if isXtversionTmux() { return false }
        guard let env = opts.envMap else { return false }
        return env["STY"] != nil || (env["TMUX"] == nil && (env["TERM"] ?? "").hasPrefix("screen"))
    }

    // parity: native/src/terminal.zig#getTerminalInfo [status=implemented hash=04a86fb28e1a]
    public func getTerminalInfo() -> TerminalInfo {
        termInfo
    }

    // parity: native/src/terminal.zig#getTerminalName [status=implemented hash=7527c23e035d]
    public func getTerminalName() -> String {
        termInfo.name
    }

    // parity: native/src/terminal.zig#refusesForcedSixel [status=implemented hash=9488f852a81a]
    public func refusesForcedSixel() -> Bool {
        if isInTmux() { return false }
        if caps.sixel { return false }
        if termInfo.fromXtversion {
            if multiplexer != .none { return true }
            return nativeEqlIgnoreCase(getTerminalName(), "kitty")
        }
        return nativeEqlIgnoreCase(getTerminalName(), "Apple_Terminal")
    }

    // parity: native/src/terminal.zig#getTerminalVersion [status=implemented hash=3b00e3372cd7]
    public func getTerminalVersion() -> String {
        termInfo.version
    }

    /// Portable pure-Swift adaptation of `tcflush` / `FlushConsoleInputBuffer`:
    /// invokes an optional platform hook registered via `setFlushInputHook(_:)`, or no-ops cleanly.
    // parity: native/src/terminal.zig#flushInput [status=adapted hash=3fe149aff2cf]
    public static func flushInput() {
        let hook = flushInputHook.withLock { $0 }
        hook?()
    }
}

// MARK: - 3. native/src/buffer.zig (15 unmapped symbols)

/// Pure-Swift parity bridge for `packages/native/src/buffer.zig`, bridging directly
/// to `OpenTUICore.OptimizedBuffer`, `OpenTUICore.GraphemePool`, and `OpenTUICore.LinkPool`.
public enum NativeBufferBridge: Sendable {
    // parity: native/src/buffer.zig#text_bytes_max [status=implemented hash=61d3ea1ca136]
    public static let textBytesMax: Int = Int(NativeABI.OT_BUFFER_TEXT_BYTES_MAX)
    public static let maxUnicodeCodepoint: UInt32 = 0x10_FFFF

    // parity: native/src/buffer.zig#RGBA [status=implemented hash=4a2784ea6614]
    public typealias RGBA = OpenTUICore.RGBA

    // parity: native/src/buffer.zig#Vec3f [status=implemented hash=7d073c5c331d]
    public struct Vec3f: Equatable, Hashable, Sendable, Codable {
        public var x: Float
        public var y: Float
        public var z: Float

        public init(_ x: Float = 0, _ y: Float = 0, _ z: Float = 0) {
            self.x = x
            self.y = y
            self.z = z
        }

        public static func + (lhs: Vec3f, rhs: Vec3f) -> Vec3f {
            Vec3f(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z)
        }

        public static func - (lhs: Vec3f, rhs: Vec3f) -> Vec3f {
            Vec3f(lhs.x - rhs.x, lhs.y - rhs.y, lhs.z - rhs.z)
        }

        public static func * (lhs: Vec3f, scalar: Float) -> Vec3f {
            Vec3f(lhs.x * scalar, lhs.y * scalar, lhs.z * scalar)
        }
    }

    // parity: native/src/buffer.zig#Vec4f [status=implemented hash=fa4563af4f8f]
    public struct Vec4f: Equatable, Hashable, Sendable, Codable {
        public var x: Float
        public var y: Float
        public var z: Float
        public var w: Float

        public init(_ x: Float = 0, _ y: Float = 0, _ z: Float = 0, _ w: Float = 0) {
            self.x = x
            self.y = y
            self.z = z
            self.w = w
        }

        public static func + (lhs: Vec4f, rhs: Vec4f) -> Vec4f {
            Vec4f(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z, lhs.w + rhs.w)
        }

        public static func - (lhs: Vec4f, rhs: Vec4f) -> Vec4f {
            Vec4f(lhs.x - rhs.x, lhs.y - rhs.y, lhs.z - rhs.z, lhs.w - rhs.w)
        }

        public static func * (lhs: Vec4f, scalar: Float) -> Vec4f {
            Vec4f(lhs.x * scalar, lhs.y * scalar, lhs.z * scalar, lhs.w * scalar)
        }
    }

    public enum ColorValidationError: Error, Equatable, Hashable, Sendable {
        case invalidOptions
    }

    public enum TextValidationError: Error, Equatable, Hashable, Sendable {
        case textLimit
        case invalidUnicode
    }

    public enum LeaseError: Error, Equatable, Hashable, Sendable {
        case leaseLimit
        case leaseBytesLimit
        case outOfMemory
        case leaseReleased
        case staleLease
        case trackerLimit
    }

    // parity: native/src/buffer.zig#validateColor [status=implemented hash=fd5c85378c7a]
    public static func validateColor(_ color: RGBA) throws(ColorValidationError) {
        let colorIntent = NativeANSI.intent(color)
        let expectedSlot: UInt8 = colorIntent == .indexed ? NativeANSI.slot(color) : 0
        if NativeANSI.getMeta(color) != NativeANSI.packMeta(intent: colorIntent, slot: expectedSlot) {
            throw .invalidOptions
        }
    }

    // parity: native/src/buffer.zig#validateTextInput [status=implemented hash=7d1a1fe4a725]
    public static func validateTextInput(_ text: [UInt8]) throws(TextValidationError) {
        if text.count > textBytesMax {
            throw .textLimit
        }
        if !nativeValidateUTF8(text) {
            throw .invalidUnicode
        }
    }

    public static func validateTextInput(_ text: String) throws(TextValidationError) {
        try validateTextInput(Array(text.utf8))
    }

    // parity: native/src/buffer.zig#BorderSides [status=implemented hash=1122371a1aa5]
    public struct BorderSides: Equatable, Hashable, Sendable, Codable {
        public var top: Bool
        public var right: Bool
        public var bottom: Bool
        public var left: Bool

        public init(top: Bool = false, right: Bool = false, bottom: Bool = false, left: Bool = false) {
            self.top = top
            self.right = right
            self.bottom = bottom
            self.left = left
        }

        public init(config: BorderSidesConfig) {
            self.top = config.top
            self.right = config.right
            self.bottom = config.bottom
            self.left = config.left
        }

        public var packedBits: UInt8 {
            (top ? 1 : 0) | (right ? 2 : 0) | (bottom ? 4 : 0) | (left ? 8 : 0)
        }

        public func toBorderSidesConfig() -> BorderSidesConfig {
            BorderSidesConfig(top: top, right: right, bottom: bottom, left: left)
        }
    }

    // parity: native/src/buffer.zig#BufferArrays [status=implemented hash=392c0eeaef80]
    public struct BufferArrays: Equatable, Sendable {
        public var char: [UInt32]
        public var fg: [RGBA]
        public var bg: [RGBA]
        public var attributes: [UInt32]

        public init(char: [UInt32], fg: [RGBA], bg: [RGBA], attributes: [UInt32]) {
            self.char = char
            self.fg = fg
            self.bg = bg
            self.attributes = attributes
        }

        public init(from core: OpenTUICore.OptimizedBuffer) {
            self.char = core.chars
            self.fg = core.fg
            self.bg = core.bg
            self.attributes = core.attributes
        }
    }

    // parity: native/src/buffer.zig#BufferSnapshot [status=implemented hash=94b731d4951c]
    public struct BufferSnapshot: @unchecked Sendable {
        public let buffer: BufferArrays
        public let width: UInt32
        public let height: UInt32
        public let generation: UInt64
        public let pool: GraphemePool

        public init(
            buffer: BufferArrays,
            width: UInt32,
            height: UInt32,
            generation: UInt64,
            pool: GraphemePool
        ) {
            self.buffer = buffer
            self.width = width
            self.height = height
            self.generation = generation
            self.pool = pool
        }

        // parity: native/src/buffer.zig#BufferSnapshot.getRealCharSize [status=implemented hash=93e101d9eb0d]
        public func getRealCharSize(addLineBreaks: Bool) throws(BufferError) -> UInt32 {
            var emptyOut: [UInt8] = []
            var emptyLengths: [UInt8] = []
            return try resolveChars(
                into: &emptyOut,
                writeOutput: false,
                addLineBreaks: addLineBreaks,
                cellLengths: &emptyLengths,
                writeLengths: false
            )
        }

        // parity: native/src/buffer.zig#BufferSnapshot.writeResolvedChars [status=implemented hash=fe95df0e9b86]
        public func writeResolvedChars(
            into output: inout [UInt8],
            addLineBreaks: Bool
        ) throws(BufferError) -> UInt32 {
            var emptyLengths: [UInt8] = []
            return try resolveChars(
                into: &output,
                writeOutput: true,
                addLineBreaks: addLineBreaks,
                cellLengths: &emptyLengths,
                writeLengths: false
            )
        }

        // parity: native/src/buffer.zig#BufferSnapshot.writeResolvedCells [status=implemented hash=50b71a218f19]
        public func writeResolvedCells(
            into output: inout [UInt8],
            addLineBreaks: Bool,
            cellLengths: inout [UInt8]
        ) throws(BufferError) -> UInt32 {
            try resolveChars(
                into: &output,
                writeOutput: true,
                addLineBreaks: addLineBreaks,
                cellLengths: &cellLengths,
                writeLengths: true
            )
        }

        private func resolveChars(
            into output: inout [UInt8],
            writeOutput: Bool,
            addLineBreaks: Bool,
            cellLengths: inout [UInt8],
            writeLengths: Bool
        ) throws(BufferError) -> UInt32 {
            guard width > 0 && height > 0 else { throw .invalidDimensions }
            let expectedCells = UInt64(width) * UInt64(height)
            guard expectedCells == UInt64(buffer.char.count) else { throw .invalidDimensions }
            if writeLengths && cellLengths.count < buffer.char.count {
                throw .bufferTooSmall
            }

            var written: UInt32 = 0
            let spaceBytes: [UInt8] = [0x20]
            let w = Int(width)

            for index in 0..<buffer.char.count {
                let charCode = buffer.char[index]
                let resolvedBytes: [UInt8]
                if isContinuationChar(charCode) {
                    resolvedBytes = []
                } else if isGraphemeChar(charCode) {
                    let gid = graphemeIdFromChar(charCode)
                    resolvedBytes = (try? pool.get(gid)) ?? spaceBytes
                } else {
                    let codepoint: UInt32
                    if isImageChar(charCode) {
                        let fallback = Int(imageFallbackFromChar(charCode))
                        codepoint = NativeBufferBridge.quadrantChars[fallback]
                    } else {
                        codepoint = charCode
                    }
                    if codepoint == 0 || codepoint > NativeBufferBridge.maxUnicodeCodepoint {
                        resolvedBytes = spaceBytes
                    } else {
                        resolvedBytes = nativeUtf8EncodeScalar(codepoint) ?? spaceBytes
                    }
                }

                guard let length = UInt32(exactly: resolvedBytes.count) else { throw .invalidDimensions }
                let (end, overflow) = written.addingReportingOverflow(length)
                guard !overflow else { throw .invalidDimensions }

                if writeOutput {
                    if Int(end) > output.count { throw .bufferTooSmall }
                    for i in 0..<resolvedBytes.count {
                        output[Int(written) + i] = resolvedBytes[i]
                    }
                }
                if writeLengths {
                    cellLengths[index] = UInt8(clamping: length)
                }
                written = end

                if addLineBreaks && (index + 1) % w == 0 {
                    let (rowEnd, rowOverflow) = written.addingReportingOverflow(1)
                    guard !rowOverflow else { throw .invalidDimensions }
                    if writeOutput {
                        if Int(rowEnd) > output.count { throw .bufferTooSmall }
                        output[Int(written)] = UInt8(ascii: "\n")
                    }
                    written = rowEnd
                }
            }
            return written
        }
    }

    // parity: native/src/buffer.zig#BufferStorage [status=implemented hash=80b6e7f2a95b]
    public final class BufferStorage: @unchecked Sendable {
        public static let cellBytes: UInt64 = UInt64(2 * MemoryLayout<UInt32>.size + 2 * MemoryLayout<RGBA>.size)

        public struct LeaseBudgetState: Sendable {
            public var checkedRefCount: UInt32
        }

        public var buffer: BufferArrays
        public private(set) var width: UInt32
        public private(set) var height: UInt32
        public private(set) var generation: UInt64
        public private(set) var capacity: UInt32
        public internal(set) var refCount: UInt32 = 1
        public internal(set) var retired: Bool = false
        public internal(set) var retainedBytes: UInt64
        public internal(set) var leaseBudget: LeaseBudgetState? = nil
        public let graphemeTracker: GraphemeTracker
        public let linkTracker: LinkTracker

        public init(
            width: UInt32,
            height: UInt32,
            generation: UInt64,
            pool: GraphemePool,
            linkPool: LinkPool
        ) throws(BufferError) {
            guard width > 0 && height > 0 else { throw .invalidDimensions }
            let (size, ov) = width.multipliedReportingOverflow(by: height)
            guard !ov else { throw .invalidDimensions }
            let count = Int(size)
            self.buffer = BufferArrays(
                char: Array(repeating: defaultSpaceChar, count: count),
                fg: Array(repeating: NativeANSI.rgbColor(255, 255, 255, 255), count: count),
                bg: Array(repeating: NativeANSI.rgbColor(0, 0, 0, 0), count: count),
                attributes: Array(repeating: OpenTUICore.TextAttributes.none, count: count)
            )
            self.width = width
            self.height = height
            self.generation = generation
            self.capacity = size
            self.retainedBytes = UInt64(size) * Self.cellBytes + UInt64(MemoryLayout<BufferStorage>.stride)
            self.graphemeTracker = GraphemeTracker(pool: pool)
            self.linkTracker = LinkTracker(pool: linkPool)
        }

        public func sync(from core: OpenTUICore.OptimizedBuffer) {
            buffer = BufferArrays(from: core)
            width = UInt32(max(0, core.width))
            height = UInt32(max(0, core.height))
            let size = width * height
            if size > capacity {
                capacity = size
                retainedBytes = UInt64(capacity) * Self.cellBytes + UInt64(MemoryLayout<BufferStorage>.stride)
            }
        }

        public func retire() {
            guard !retired else { return }
            retired = true
            release()
        }

        public func snapshot() -> BufferSnapshot {
            BufferSnapshot(
                buffer: buffer,
                width: width,
                height: height,
                generation: generation,
                pool: graphemeTracker.pool
            )
        }

        public func retain() -> Bool {
            guard refCount < UInt32.max else { return false }
            refCount += 1
            return true
        }

        public func release() {
            guard refCount > 0 else { return }
            refCount -= 1
            if refCount == 0 {
                graphemeTracker.clear()
                linkTracker.clear()
            }
        }

        public func resizeExclusive(
            width newWidth: UInt32,
            height newHeight: UInt32,
            cellsMax: UInt32 = UInt32.max
        ) throws(BufferError) {
            guard newWidth > 0 && newHeight > 0 else { throw .invalidDimensions }
            let (size, ov) = newWidth.multipliedReportingOverflow(by: newHeight)
            guard !ov && size <= cellsMax else { throw .invalidDimensions }
            let (nextGen, genOv) = generation.addingReportingOverflow(1)
            guard !genOv else { throw .generationExhausted }

            let halfSize = size / 2
            let shrinkThreshold = size &+ halfSize
            if size > capacity || (shrinkThreshold >= size && capacity > shrinkThreshold) {
                let grown = min(cellsMax, max(size, capacity &+ (capacity / 2)))
                let newCap = size > capacity ? grown : size
                retainedBytes = retainedBytes
                    - UInt64(capacity) * Self.cellBytes
                    + UInt64(newCap) * Self.cellBytes
                capacity = newCap
            }
            let count = Int(size)
            buffer = BufferArrays(
                char: Array(repeating: defaultSpaceChar, count: count),
                fg: Array(repeating: NativeANSI.rgbColor(255, 255, 255, 255), count: count),
                bg: Array(repeating: NativeANSI.rgbColor(0, 0, 0, 255), count: count),
                attributes: Array(repeating: OpenTUICore.TextAttributes.none, count: count)
            )
            width = newWidth
            height = newHeight
            generation = nextGen
        }

        // parity: native/src/buffer.zig#BufferStorage.ensureTrackerCapacity [status=implemented hash=2f7f06ed3b50]
        public func ensureTrackerCapacity(graphemes: UInt64, links: UInt64) throws(LeaseError) {
            let entriesMax: UInt64 = (((UInt64(1) << 31) - 1) * 80) / 100
            if graphemes > entriesMax || links > entriesMax {
                throw .trackerLimit
            }
        }
    }

    // parity: native/src/buffer.zig#BufferLease [status=implemented hash=26c12b9d4b56]
    public struct BufferLease: @unchecked Sendable {
        public static let countMaxDefault: UInt32 = 4096
        public static let bytesMaxDefault: UInt64 = 64 * 1024 * 1024

        public internal(set) var storage: BufferStorage?

        public init(storage: BufferStorage?) {
            self.storage = storage
        }

        // parity: native/src/buffer.zig#BufferLease.acquireChecked [status=implemented hash=a51ccfae78dd]
        public static func acquireChecked(
            target: OptimizedBuffer,
            count: inout UInt32,
            countMax: UInt32 = countMaxDefault,
            bytes: inout UInt64,
            bytesMax: UInt64 = bytesMaxDefault
        ) throws(LeaseError) -> BufferLease {
            if count >= countMax { throw .leaseLimit }
            let storage = target.storage
            let alreadyLeased = storage.leaseBudget != nil
            if !alreadyLeased && storage.retainedBytes > bytesMax &- bytes {
                throw .leaseBytesLimit
            }
            let lease: BufferLease
            do {
                lease = try target.acquireLease()
            } catch {
                throw .leaseLimit
            }
            if !alreadyLeased {
                let entries = UInt64(storage.buffer.char.count) + 1
                do {
                    try storage.ensureTrackerCapacity(graphemes: entries, links: entries)
                } catch {
                    var mutableLease = lease
                    mutableLease.release()
                    throw .leaseLimit
                }
                if storage.retainedBytes > bytesMax &- bytes {
                    var mutableLease = lease
                    mutableLease.release()
                    throw .leaseBytesLimit
                }
            }
            if var budget = storage.leaseBudget {
                budget.checkedRefCount += 1
                storage.leaseBudget = budget
            } else {
                storage.leaseBudget = BufferStorage.LeaseBudgetState(checkedRefCount: 1)
                bytes += storage.retainedBytes
            }
            count += 1
            return lease
        }

        // parity: native/src/buffer.zig#BufferLease.releaseChecked [status=implemented hash=6c98953aa5de]
        public mutating func releaseChecked(count: inout UInt32, bytes: inout UInt64) {
            guard let storage else { return }
            self.storage = nil
            if var budget = storage.leaseBudget, budget.checkedRefCount > 0 {
                budget.checkedRefCount -= 1
                if budget.checkedRefCount == 0 {
                    bytes = bytes >= storage.retainedBytes ? bytes - storage.retainedBytes : 0
                    storage.leaseBudget = nil
                } else {
                    storage.leaseBudget = budget
                }
            }
            if count > 0 { count -= 1 }
            storage.release()
        }

        // parity: native/src/buffer.zig#BufferLease.isCurrent [status=implemented hash=e4e453b6713d]
        public func isCurrent() -> Bool {
            guard let storage else { return false }
            return !storage.retired
        }

        // parity: native/src/buffer.zig#BufferLease.snapshot [status=implemented hash=3d722a87f192]
        public func snapshot() throws(LeaseError) -> BufferSnapshot {
            guard let storage else { throw .leaseReleased }
            if storage.retired { throw .staleLease }
            return storage.snapshot()
        }

        // parity: native/src/buffer.zig#BufferLease.release [status=implemented hash=d63035068ab4]
        public mutating func release() {
            guard let storage else { return }
            self.storage = nil
            storage.release()
        }
    }

    // parity: native/src/buffer.zig#rgbaEqual [status=implemented hash=e2dddc85841e]
    @inline(__always)
    public static func rgbaEqual(_ a: RGBA, _ b: RGBA) -> Bool {
        a.b0 == b.b0 && a.b1 == b.b1 && a.b2 == b.b2 && a.b3 == b.b3
    }

    // parity: native/src/buffer.zig#Cell [status=implemented hash=5b3c9239058f]
    public struct Cell: Equatable, Hashable, Sendable {
        public var char: UInt32
        public var fg: RGBA
        public var bg: RGBA
        public var attributes: UInt32

        public init(
            char: UInt32 = defaultSpaceChar,
            fg: RGBA = NativeANSI.rgbColor(255, 255, 255, 255),
            bg: RGBA = NativeANSI.rgbColor(0, 0, 0, 0),
            attributes: UInt32 = OpenTUICore.TextAttributes.none
        ) {
            self.char = char
            self.fg = fg
            self.bg = bg
            self.attributes = attributes
        }

        public init(terminalCell: TerminalCell) {
            self.char = terminalCell.scalar
            self.fg = terminalCell.foreground
            self.bg = terminalCell.background
            self.attributes = terminalCell.attributes
        }

        public var terminalCell: TerminalCell {
            TerminalCell(scalar: char, foreground: fg, background: bg, attributes: attributes)
        }
    }

    // parity: native/src/buffer.zig#OptimizedBuffer [status=implemented hash=178e13c4613b]
    public final class OptimizedBuffer: @unchecked Sendable {
        public struct ImagePlacement: @unchecked Sendable {
            public var placementId: UInt32
            public var image: NativeZigImage.Image
            public var x: Int32
            public var y: Int32
            public var width: UInt32
            public var height: UInt32
            public var sourceX: UInt32
            public var sourceY: UInt32
            public var sourceWidth: UInt32
            public var sourceHeight: UInt32
            public var opacity: UInt8

            public init(
                placementId: UInt32,
                image: NativeZigImage.Image,
                x: Int32,
                y: Int32,
                width: UInt32,
                height: UInt32,
                sourceX: UInt32 = 0,
                sourceY: UInt32 = 0,
                sourceWidth: UInt32? = nil,
                sourceHeight: UInt32? = nil,
                opacity: UInt8 = 255
            ) {
                self.placementId = placementId
                self.image = image
                self.x = x
                self.y = y
                self.width = width
                self.height = height
                self.sourceX = sourceX
                self.sourceY = sourceY
                self.sourceWidth = sourceWidth ?? image.width
                self.sourceHeight = sourceHeight ?? image.height
                self.opacity = opacity
            }
        }

        /// Owns an unpublished replacement `BufferStorage` for transactional two-phase resize.
        public struct PreparedResize: @unchecked Sendable {
            public let target: OptimizedBuffer
            public private(set) var storage: BufferStorage?

            public init(target: OptimizedBuffer, storage: BufferStorage?) {
                self.target = target
                self.storage = storage
            }

            // parity: native/src/buffer.zig#OptimizedBuffer.PreparedResize.deinit [status=implemented hash=c113c77d9401]
            public mutating func deinitResize() {
                guard let pending = storage else { return }
                storage = nil
                pending.retire()
            }

            // parity: native/src/buffer.zig#OptimizedBuffer.PreparedResize.commit [status=implemented hash=1dc6f64b5dd0]
            public mutating func commit() {
                guard let pending = storage else { return }
                let previous = target.storage
                precondition(pending.generation &- 1 == previous.generation)
                storage = nil
                try? target.core.resize(width: Int(pending.width), height: Int(pending.height))
                target.storage = pending
                target.clear(bg: NativeANSI.rgbColor(0, 0, 0, 255), char: defaultSpaceChar)
                previous.retire()
            }
        }

        public enum RetainError: Error, Equatable, Hashable, Sendable {
            case objectLimit
            case unsupportedResource
        }

        public let core: OpenTUICore.OptimizedBuffer
        public private(set) var storage: BufferStorage
        public var ownerContextId: UInt64 = 0
        public var cellsMax: UInt32 = UInt32.max
        public private(set) var refCount: UInt32 = 1
        public var imagePlacements: [ImagePlacement] = []

        public var width: UInt32 { UInt32(max(0, core.width)) }
        public var height: UInt32 { UInt32(max(0, core.height)) }
        public var generation: UInt64 { storage.generation }

        // parity: native/src/buffer.zig#OptimizedBuffer.init [status=implemented hash=9413e3e70b7d]
        public init(
            width: UInt32,
            height: UInt32,
            widthMethod: WidthMethod = .unicode,
            respectAlpha: Bool = false,
            blendBackdropColor: RGBA? = nil,
            id: String = "unnamed buffer",
            graphemePool: GraphemePool = GraphemePool(),
            linkPool: LinkPool = LinkPool()
        ) throws(BufferError) {
            let coreBuffer = try OpenTUICore.OptimizedBuffer.create(
                width: Int(width),
                height: Int(height),
                widthMethod: widthMethod,
                respectAlpha: respectAlpha,
                blendBackdropColor: blendBackdropColor,
                id: id,
                graphemePool: graphemePool,
                linkPool: linkPool
            )
            let initialStorage = try BufferStorage(
                width: width,
                height: height,
                generation: 1,
                pool: graphemePool,
                linkPool: linkPool
            )
            initialStorage.sync(from: coreBuffer)
            self.core = coreBuffer
            self.storage = initialStorage
        }

        public init(wrapping coreBuffer: OpenTUICore.OptimizedBuffer) throws(BufferError) {
            let w = UInt32(max(0, coreBuffer.width))
            let h = UInt32(max(0, coreBuffer.height))
            let initialStorage = try BufferStorage(
                width: w,
                height: h,
                generation: 1,
                pool: coreBuffer.graphemePool,
                linkPool: coreBuffer.linkPool
            )
            initialStorage.sync(from: coreBuffer)
            self.core = coreBuffer
            self.storage = initialStorage
        }

        // parity: native/src/buffer.zig#OptimizedBuffer.acquireLease [status=implemented hash=dfb68ee645ca]
        public func acquireLease() throws(LeaseError) -> BufferLease {
            storage.sync(from: core)
            guard storage.retain() else { throw .leaseLimit }
            return BufferLease(storage: storage)
        }

        // parity: native/src/buffer.zig#OptimizedBuffer.getCharPtr [status=adapted hash=6d75fe12c5b5]
        public func getCharPtr() -> [UInt32] {
            core.chars
        }

        // parity: native/src/buffer.zig#OptimizedBuffer.getFgPtr [status=adapted hash=422f899b18db]
        public func getFgPtr() -> [RGBA] {
            core.fg
        }

        // parity: native/src/buffer.zig#OptimizedBuffer.getBgPtr [status=adapted hash=e5331e768fba]
        public func getBgPtr() -> [RGBA] {
            core.bg
        }

        // parity: native/src/buffer.zig#OptimizedBuffer.getAttributesPtr [status=adapted hash=fe56a4237918]
        public func getAttributesPtr() -> [UInt32] {
            core.attributes
        }

        // parity: native/src/buffer.zig#OptimizedBuffer.retain [status=implemented hash=277c92c2b953]
        public func retain() throws(RetainError) {
            guard refCount < UInt32.max else { throw .objectLimit }
            refCount += 1
        }

        // parity: native/src/buffer.zig#OptimizedBuffer.prepareResize [status=implemented hash=5a6c4fddd6e5]
        public func prepareResize(width newWidth: UInt32, height newHeight: UInt32) throws(BufferError) -> PreparedResize {
            if newWidth == width && newHeight == height {
                return PreparedResize(target: self, storage: nil)
            }
            guard newWidth > 0 && newHeight > 0 else { throw .invalidDimensions }
            let (size, ov) = newWidth.multipliedReportingOverflow(by: newHeight)
            guard !ov && size <= cellsMax else { throw .invalidDimensions }
            let (nextGen, genOv) = storage.generation.addingReportingOverflow(1)
            guard !genOv else { throw .generationExhausted }
            let replacement = try BufferStorage(
                width: newWidth,
                height: newHeight,
                generation: nextGen,
                pool: core.graphemePool,
                linkPool: core.linkPool
            )
            return PreparedResize(target: self, storage: replacement)
        }

        public func snapshot() -> BufferSnapshot {
            storage.sync(from: core)
            return storage.snapshot()
        }

        // parity: native/src/buffer.zig#OptimizedBuffer.resize [status=implemented hash=2a0dac821502]
        public func resize(width newWidth: UInt32, height newHeight: UInt32) throws(BufferError) {
            guard newWidth > 0 && newHeight > 0 else { throw .invalidDimensions }
            let (size, ov) = newWidth.multipliedReportingOverflow(by: newHeight)
            guard !ov && size <= cellsMax else { throw .invalidDimensions }
            if storage.refCount != 1 || storage.leaseBudget != nil {
                var prepared = try prepareResize(width: newWidth, height: newHeight)
                prepared.commit()
                return
            }
            try core.resize(width: Int(newWidth), height: Int(newHeight))
            try storage.resizeExclusive(width: newWidth, height: newHeight, cellsMax: cellsMax)
            imagePlacements.removeAll(keepingCapacity: false)
            storage.sync(from: core)
        }

        // parity: native/src/buffer.zig#OptimizedBuffer.syncImagePlacements [status=implemented hash=c13947c0f429]
        public func syncImagePlacements(from source: OptimizedBuffer) throws(LeaseError) {
            try storage.ensureTrackerCapacity(graphemes: UInt64(source.imagePlacements.count), links: 0)
            imagePlacements = source.imagePlacements
        }

        // parity: native/src/buffer.zig#OptimizedBuffer.materializeImageFallback [status=implemented hash=730024831030]
        public func materializeImageFallback(placementId: UInt32) throws(ImageError) {
            guard placementId > 0 && Int(placementId) <= imagePlacements.count else { return }
            let placement = imagePlacements[Int(placementId) - 1]
            let imagePixels = try placement.image.ensurePixels()
            let imgW = Int(placement.image.width)
            let pW = max(1, Int(placement.width))
            let pH = max(1, Int(placement.height))
            for cellY in 0..<pH {
                let destY = Int(placement.y) + cellY
                for cellX in 0..<pW {
                    let destX = Int(placement.x) + cellX
                    guard let current = core.cell(atX: destX, y: destY),
                          isImageChar(current.scalar),
                          imageIdFromChar(current.scalar) >= placementId
                    else { continue }
                    let currentPlacementId = imageIdFromChar(current.scalar)
                    var quadrants: [RGBA] = []
                    quadrants.reserveCapacity(4)
                    for q in 0..<4 {
                        let sampleX = cellX * 2 + (q & 1)
                        let sampleY = cellY * 2 + (q >> 1)
                        let sx = Int(placement.sourceX) + min(
                            max(0, Int(placement.sourceWidth) - 1),
                            (sampleX * Int(placement.sourceWidth)) / (pW * 2)
                        )
                        let sy = Int(placement.sourceY) + min(
                            max(0, Int(placement.sourceHeight) - 1),
                            (sampleY * Int(placement.sourceHeight)) / (pH * 2)
                        )
                        let off = (sy * imgW + sx) * 4
                        if off + 3 < imagePixels.count {
                            quadrants.append(NativeANSI.rgbColor(
                                imagePixels[off],
                                imagePixels[off + 1],
                                imagePixels[off + 2],
                                imagePixels[off + 3]
                            ))
                        } else {
                            quadrants.append(NativeANSI.rgbColor(0, 0, 0, 0))
                        }
                    }
                    let rendered = QuadrantResult.renderQuadrantBlock(quadrants)
                    let qIdx = UInt8(NativeBufferBridge.quadrantChars.firstIndex(of: rendered.char) ?? 0)
                    let cellChar = currentPlacementId == placementId
                        ? packImageCell(id: placementId, fallback: qIdx)
                        : current.scalar
                    let cellAttrs = currentPlacementId == placementId ? OpenTUICore.TextAttributes.none : current.attributes
                    let fallbackCell = TerminalCell(
                        scalar: cellChar,
                        foreground: rendered.fg,
                        background: rendered.bg,
                        attributes: cellAttrs
                    )
                    let fgHasAlpha = NativeANSI.alpha(fallbackCell.foreground) < 255
                    let bgHasAlpha = NativeANSI.alpha(fallbackCell.background) < 255
                    if placement.opacity == 255 && !fgHasAlpha && !bgHasAlpha {
                        core.setCellRaw(x: destX, y: destY, cell: fallbackCell)
                    } else {
                        let scaleColor: (RGBA) -> RGBA = { color in
                            if placement.opacity == 255 { return color }
                            let a = UInt8((UInt32(NativeANSI.alpha(color)) * UInt32(placement.opacity) + 127) / 255)
                            return NativeANSI.rgbColor(NativeANSI.red(color), NativeANSI.green(color), NativeANSI.blue(color), a)
                        }
                        let effective = TerminalCell(
                            scalar: fallbackCell.scalar,
                            foreground: scaleColor(fallbackCell.foreground),
                            background: scaleColor(fallbackCell.background),
                            attributes: fallbackCell.attributes
                        )
                        core.setCellRaw(x: destX, y: destY, cell: core.blendCells(overlay: effective, dest: current))
                    }
                }
            }
            storage.sync(from: core)
        }

        // parity: native/src/buffer.zig#OptimizedBuffer.materializeImageFallbacks [status=implemented hash=efb95f47c9fc]
        public func materializeImageFallbacks() throws(ImageError) {
            guard !imagePlacements.isEmpty else { return }
            for placementId in 1...UInt32(imagePlacements.count) {
                try materializeImageFallback(placementId: placementId)
            }
            for y in 0..<core.height {
                for x in 0..<core.width {
                    guard let cell = core.cell(atX: x, y: y), isImageChar(cell.scalar) else { continue }
                    let qChar = NativeBufferBridge.quadrantChars[Int(imageFallbackFromChar(cell.scalar))]
                    core.setCellRaw(
                        x: x,
                        y: y,
                        cell: TerminalCell(
                            scalar: qChar,
                            foreground: cell.foreground,
                            background: cell.background,
                            attributes: cell.attributes
                        )
                    )
                }
            }
            imagePlacements.removeAll(keepingCapacity: false)
            storage.sync(from: core)
        }

        // parity: native/src/buffer.zig#OptimizedBuffer.checkImageResources [status=implemented hash=6018b61946e6]
        public func checkImageResources() throws(RetainError) {
            for placement in imagePlacements {
                if ownerContextId == 0 || placement.image.ownerContextId != ownerContextId {
                    throw .unsupportedResource
                }
            }
        }

        public func clear(bg: RGBA = NativeANSI.rgbColor(0, 0, 0, 255), char: UInt32 = defaultSpaceChar) {
            core.clear(bg: bg, char: char)
            imagePlacements.removeAll(keepingCapacity: true)
            storage.sync(from: core)
        }

        public func getCell(x: UInt32, y: UInt32) -> Cell? {
            core.cell(atX: Int(x), y: Int(y)).map(Cell.init(terminalCell:))
        }

        public func setCell(x: UInt32, y: UInt32, cell: Cell) {
            core.setCell(x: Int(x), y: Int(y), cell: cell.terminalCell)
            storage.sync(from: core)
        }

        public func drawText(
            _ text: String,
            x: Int,
            y: Int,
            fg: RGBA,
            bg: RGBA? = nil,
            attributes: UInt32 = OpenTUICore.TextAttributes.none
        ) {
            core.drawText(text, x: x, y: y, fg: fg, bg: bg, attributes: attributes)
            storage.sync(from: core)
        }

        // parity: native/src/buffer.zig#OptimizedBuffer.deinit [status=implemented hash=cd1f9581d0ef]
        public func retire() {
            if refCount > 1 {
                refCount -= 1
                return
            }
            refCount = 0
            imagePlacements.removeAll(keepingCapacity: false)
            storage.retire()
            core.destroy()
        }
    }

    // parity: native/src/buffer.zig#quadrantChars [status=implemented hash=22dbfc9e9726]
    public static let quadrantChars: [UInt32] = [
        32,      // 0000 space
        0x2597,  // 0001 BR ▗
        0x2596,  // 0010 BL ▖
        0x2584,  // 0011 Lower Half Block ▄
        0x259D,  // 0100 TR ▝
        0x2590,  // 0101 Right Half Block ▐
        0x259E,  // 0110 TR+BL ▞
        0x259F,  // 0111 TR+BL+BR ▟
        0x2598,  // 1000 TL ▘
        0x259A,  // 1001 TL+BR ▚
        0x258C,  // 1010 Left Half Block ▌
        0x2599,  // 1011 TL+BL+BR ▙
        0x2580,  // 1100 Upper Half Block ▀
        0x259C,  // 1101 TL+TR+BR ▜
        0x259B,  // 1110 TL+TR+BL ▛
        0x2588,  // 1111 Full Block █
    ]

    // parity: native/src/buffer.zig#QuadrantResult [status=implemented hash=4feecf7a5c2c]
    public struct QuadrantResult: Equatable, Hashable, Sendable {
        public var char: UInt32
        public var fg: RGBA
        public var bg: RGBA

        public init(char: UInt32, fg: RGBA, bg: RGBA) {
            self.char = char
            self.fg = fg
            self.bg = bg
        }

        /// Computes the best-fit 2x2 quadrant block character and foreground/background pair
        /// matching `renderQuadrantBlock` in `packages/native/src/buffer.zig`.
        public static func renderQuadrantBlock(_ pixels: [RGBA]) -> QuadrantResult {
            precondition(pixels.count == 4, "renderQuadrantBlock requires 4 pixels (TL, TR, BL, BR)")
            var idxA = 0
            var idxB = 1
            var maxDist = NativeANSI.colorDistanceSquared(pixels[0], pixels[1])

            for i in 0..<4 {
                for j in (i + 1)..<4 {
                    let dist = NativeANSI.colorDistanceSquared(pixels[i], pixels[j])
                    if dist > maxDist {
                        idxA = i
                        idxB = j
                        maxDist = dist
                    }
                }
            }

            let candA = pixels[idxA]
            let candB = pixels[idxB]
            let lumA = luminance(candA)
            let lumB = luminance(candB)
            let darkColor = lumA <= lumB ? candA : candB
            let lightColor = lumA <= lumB ? candB : candA

            var bits: Int = 0
            let bitValues = [8, 4, 2, 1]
            for i in 0..<4 {
                let dDark = NativeANSI.colorDistanceSquared(pixels[i], darkColor)
                let dLight = NativeANSI.colorDistanceSquared(pixels[i], lightColor)
                if dDark <= dLight {
                    bits |= bitValues[i]
                }
            }

            if bits == 0 {
                return QuadrantResult(char: 32, fg: darkColor, bg: averageColor(pixels))
            } else if bits == 15 {
                return QuadrantResult(char: NativeBufferBridge.quadrantChars[15], fg: averageColor(pixels), bg: lightColor)
            } else {
                return QuadrantResult(char: NativeBufferBridge.quadrantChars[bits], fg: darkColor, bg: lightColor)
            }
        }

        private static func luminance(_ color: RGBA) -> Float {
            0.2126 * NativeANSI.redF(color) + 0.7152 * NativeANSI.greenF(color) + 0.0722 * NativeANSI.blueF(color)
        }

        private static func averageColor(_ pixels: [RGBA]) -> RGBA {
            guard !pixels.isEmpty else { return NativeANSI.rgbColor(0, 0, 0, 0) }
            var sumR: UInt32 = 0
            var sumG: UInt32 = 0
            var sumB: UInt32 = 0
            var sumA: UInt32 = 0
            for p in pixels {
                sumR += UInt32(NativeANSI.red(p))
                sumG += UInt32(NativeANSI.green(p))
                sumB += UInt32(NativeANSI.blue(p))
                sumA += UInt32(NativeANSI.alpha(p))
            }
            let len = UInt32(pixels.count)
            return NativeANSI.rgbColor(
                UInt8((sumR + len / 2) / len),
                UInt8((sumG + len / 2) / len),
                UInt8((sumB + len / 2) / len),
                UInt8((sumA + len / 2) / len)
            )
        }
    }
}

// MARK: - 4. native/src/renderer-output.zig (2 unmapped symbols)

/// Pure-Swift output transport parity bridge for `packages/native/src/renderer-output.zig`,
/// bridging directly to `OpenTUICore.NativeSpanFeed`.
public enum NativeRendererOutput: Sendable {
    public static let utf16BufferSize: Int = 4096

    public enum OutputError: Error, Equatable, Hashable, Sendable {
        case invalidUtf8
        case writeFailed
        case bufferFull
    }

    public struct Utf16Chunk: Equatable, Hashable, Sendable {
        public let inputLen: Int
        public let outputLen: Int

        public init(inputLen: Int, outputLen: Int) {
            self.inputLen = inputLen
            self.outputLen = outputLen
        }
    }

    /// Returns the longest prefix of `data` that does not end inside an incomplete UTF-8 scalar.
    public static func completeUtf8Prefix(_ data: [UInt8]) -> [UInt8] {
        guard !data.isEmpty else { return data }
        var start = data.count - 1
        while start > 0 && (data.count - start) < 4 && (data[start] & 0xC0) == 0x80 {
            start -= 1
        }
        guard let length = nativeUtf8SequenceLength(data[start]) else { return data }
        return length > (data.count - start) ? Array(data[0..<start]) : data
    }

    /// Converts a bounded UTF-8 byte slice into UTF-16 code units without splitting surrogate pairs.
    public static func utf8ToUtf16Chunk(
        outputCapacity: Int,
        input: [UInt8]
    ) throws(OutputError) -> (units: [UInt16], chunk: Utf16Chunk) {
        precondition(outputCapacity >= 2, "UTF-16 output buffer must hold at least 2 code units")
        var units: [UInt16] = []
        units.reserveCapacity(min(outputCapacity, input.count))

        var inputIndex = 0
        while inputIndex < input.count {
            let firstByte = input[inputIndex]
            if firstByte < 0x80 {
                if units.count == outputCapacity { break }
                units.append(UInt16(firstByte))
                inputIndex += 1
                continue
            }

            guard let seqLen = nativeUtf8SequenceLength(firstByte) else {
                throw .invalidUtf8
            }
            guard input.count - inputIndex >= seqLen else {
                throw .invalidUtf8
            }
            guard let codepoint = nativeUtf8Decode(input[inputIndex..<(inputIndex + seqLen)]) else {
                throw .invalidUtf8
            }

            let outLen = codepoint < 0x1_0000 ? 1 : 2
            if outputCapacity - units.count < outLen { break }

            if outLen == 1 {
                units.append(UInt16(codepoint))
            } else {
                let value = codepoint - 0x1_0000
                units.append(UInt16(0xD800 + (value >> 10)))
                units.append(UInt16(0xDC00 + (value & 0x3FF)))
            }
            inputIndex += seqLen
        }

        return (units, Utf16Chunk(inputLen: inputIndex, outputLen: units.count))
    }

    // parity: native/src/renderer-output.zig#StdoutOutput [status=adapted hash=d366b3a2a8c3]
    public final class StdoutOutput: @unchecked Sendable {
        public typealias ByteWriteHandler = @Sendable ([UInt8]) -> Int?
        public typealias Utf16WriteHandler = @Sendable ([UInt16]) -> Bool

        public let windowsConsole: Bool
        public var directWriteSupported: Bool
        private let writeBytesHandler: ByteWriteHandler
        private let writeUtf16Handler: Utf16WriteHandler?

        public private(set) var capturedBytes: [UInt8] = []
        public private(set) var capturedUtf16Units: [UInt16] = []

        /// Creates a pure-Swift `StdoutOutput` backed by injectable byte/UTF-16 writers
        /// (defaults to in-memory capture when no custom handlers are supplied).
        // parity: native/src/renderer-output.zig#StdoutOutput.initWithIo [status=adapted hash=ffb08666a75a]
        public init(
            windowsConsole: Bool = false,
            directWriteSupported: Bool = true,
            writeBytes: ByteWriteHandler? = nil,
            writeUtf16: Utf16WriteHandler? = nil
        ) {
            self.windowsConsole = windowsConsole
            self.directWriteSupported = directWriteSupported
            self.writeBytesHandler = writeBytes ?? { bytes in bytes.count }
            self.writeUtf16Handler = writeUtf16
        }

        // parity: native/src/renderer-output.zig#StdoutOutput.writeSome [status=adapted hash=d60057d5c3d5]
        public func writeSome(_ data: [UInt8]) throws(OutputError) -> Int {
            guard !data.isEmpty else { return 0 }
            if windowsConsole {
                let bounded = data.count > NativeRendererOutput.utf16BufferSize
                    ? Array(data[0..<NativeRendererOutput.utf16BufferSize])
                    : data
                let prefix = NativeRendererOutput.completeUtf8Prefix(bounded)
                guard !prefix.isEmpty else { return 0 }
                let (units, chunk) = try NativeRendererOutput.utf8ToUtf16Chunk(
                    outputCapacity: NativeRendererOutput.utf16BufferSize,
                    input: prefix
                )
                if let handler = writeUtf16Handler {
                    guard handler(units) else { throw .writeFailed }
                }
                capturedUtf16Units.append(contentsOf: units)
                return chunk.inputLen
            }
            guard let count = writeBytesHandler(data), count > 0 else {
                throw .writeFailed
            }
            capturedBytes.append(contentsOf: data[0..<min(count, data.count)])
            return count
        }

        public func writeSome(_ text: String) throws(OutputError) -> Int {
            try writeSome(Array(text.utf8))
        }

        // parity: native/src/renderer-output.zig#StdoutOutput.supportsDirectWrite [status=implemented hash=eef226cd8eca]
        public func supportsDirectWrite() -> Bool {
            directWriteSupported
        }
    }

    /// Buffered frame writer targeting a `FeedBackend` (`renderer-output.zig#BackendWriter`).
    public struct BackendWriter: Sendable {
        public let backend: FeedBackend
        private var staged: [UInt8] = []

        public init(backend: FeedBackend) {
            self.backend = backend
        }

        // parity: native/src/renderer-output.zig#BackendWriter.write [status=implemented hash=37b6a6896a5c]
        @discardableResult
        public func write(_ data: [UInt8]) throws(OutputError) -> Int {
            try backend.frameWrite(data)
            return data.count
        }

        // parity: native/src/renderer-output.zig#BackendWriter.writeAll [status=implemented hash=893a45842fcd]
        public func writeAll(_ data: [UInt8]) throws(OutputError) {
            try backend.frameWrite(data)
        }

        // parity: native/src/renderer-output.zig#BackendWriter.writeByte [status=implemented hash=a45f2811e026]
        public func writeByte(_ byte: UInt8) throws(OutputError) {
            try backend.frameWrite([byte])
        }

        // parity: native/src/renderer-output.zig#BackendWriter.print [status=adapted hash=2bf234c03006]
        public func print(_ formatted: String) throws(OutputError) {
            try backend.frameWrite(Array(formatted.utf8))
        }

        // parity: native/src/renderer-output.zig#BackendWriter.flush [status=implemented hash=3cf0bd5a2512]
        public mutating func flush() throws(OutputError) {
            guard !staged.isEmpty else { return }
            let pending = staged
            staged.removeAll(keepingCapacity: true)
            try backend.frameWrite(pending)
        }
    }

    // parity: native/src/renderer-output.zig#FeedBackend [status=implemented hash=3214131a072c]
    public final class FeedBackend: @unchecked Sendable {
        public enum UploadState: UInt8, Equatable, Hashable, Sendable, Codable {
            case kept = 0
            case deferred = 1
            case tooLarge = 2
        }

        public struct Upload: Equatable, Hashable, Sendable {
            public var start: Int
            public var end: Int
            public var placementId: UInt32
            public var waited: Bool
            public var state: UploadState

            public init(start: Int, end: Int, placementId: UInt32, waited: Bool, state: UploadState) {
                self.start = start
                self.end = end
                self.placementId = placementId
                self.waited = waited
                self.state = state
            }
        }

        private struct ActiveUpload {
            var start: Int
            var waited: Bool
            var len: Int = 0
            var cut: Bool = false
        }

        public let feed: NativeSpanFeed
        public private(set) var frameBytes: [UInt8] = []
        public private(set) var frameActive: Bool = false
        public private(set) var frameWriteCount: Int = 0
        public private(set) var frameStatus: WriteStatus = .ok
        public private(set) var oversizeBytes: Int = 0
        public private(set) var uploads: [Upload] = []
        private var activeUpload: ActiveUpload? = nil
        public private(set) var keptUploadBytes: Int = 0
        public var uploadsAlone: Bool = false
        public private(set) var lastWriteTimeUs: Double? = nil

        // parity: native/src/renderer-output.zig#FeedBackend.createWithIo [status=adapted hash=29b9fc48ab7c]
        public init(feed: NativeSpanFeed) {
            self.feed = feed
        }

        // parity: native/src/renderer-output.zig#FeedBackend.deinit [status=implemented hash=dcc9c7525ab3]
        public func deinitBackend() {
            frameBytes.removeAll()
            uploads.removeAll()
            activeUpload = nil
            frameActive = false
            keptUploadBytes = 0
            oversizeBytes = 0
        }

        private var isFeedBounded: Bool {
            feed.options.growthPolicy == .block || feed.options.maxBytes > 0
        }

        private var atomicByteLimit: UInt64 {
            if feed.options.maxBytes > 0 {
                return min(UInt64(feed.options.chunkSize), feed.options.maxBytes)
            }
            return UInt64(feed.options.chunkSize)
        }

        // parity: native/src/renderer-output.zig#FeedBackend.uploadLimit [status=implemented hash=6c763079d287]
        public func uploadLimit() -> UInt64 {
            isFeedBounded ? atomicByteLimit : UInt64.max
        }

        // parity: native/src/renderer-output.zig#FeedBackend.shouldSkipFrame [status=implemented hash=48d997aa7834]
        public func shouldSkipFrame() -> Bool {
            let stats = feed.stats
            let cap = feed.options.spanQueueCapacity
            return frameActive || (cap > 0 && stats.outstandingSpans >= cap) || feed.isClosed
        }

        // parity: native/src/renderer-output.zig#FeedBackend.prepareFrame [status=implemented hash=00605e3b6220]
        public func prepareFrame() -> WriteStatus {
            if frameActive { return .skipped }
            frameStatus = .ok
            if shouldSkipFrame() { return .skipped }
            return .ok
        }

        // parity: native/src/renderer-output.zig#FeedBackend.writer [status=implemented hash=e19bae1fadf3]
        public func writer() -> BackendWriter {
            BackendWriter(backend: self)
        }

        // parity: native/src/renderer-output.zig#FeedBackend.beginFrame [status=implemented hash=fd4551e03e82]
        public func beginFrame() {
            frameWriteCount = 0
            frameStatus = .ok
            frameActive = true
            oversizeBytes = 0
            uploads.removeAll(keepingCapacity: true)
            activeUpload = nil
            keptUploadBytes = 0
            uploadsAlone = false
            frameBytes.removeAll(keepingCapacity: true)
        }

        public func frameWrite(_ data: [UInt8]) throws(OutputError) {
            frameWriteCount += 1
            if var upload = activeUpload {
                upload.len = upload.len.addingReportingOverflow(data.count).overflow ? Int.max : upload.len + data.count
                if upload.cut || frameStatus != .ok {
                    activeUpload = upload
                    return
                }
                let totalUploadBytes = UInt64(keptUploadBytes) &+ UInt64(upload.len)
                if totalUploadBytes <= uploadLimit() {
                    activeUpload = upload
                    try stage(data)
                    return
                }
                if upload.start < frameBytes.count {
                    frameBytes.removeSubrange(upload.start..<frameBytes.count)
                }
                upload.cut = true
                activeUpload = upload
                return
            }

            if frameStatus != .ok {
                if oversizeBytes == 0 { throw .bufferFull }
                oversizeBytes = oversizeBytes.addingReportingOverflow(data.count).overflow ? Int.max : oversizeBytes + data.count
                return
            }

            let required = (frameBytes.count - keptUploadBytes) + data.count
            if isFeedBounded && UInt64(required) > atomicByteLimit {
                frameStatus = .failed
                oversizeBytes = required
                failFrame()
                return
            }
            try stage(data)
        }

        public func frameWrite(_ text: String) throws(OutputError) {
            try frameWrite(Array(text.utf8))
        }

        private func stage(_ data: [UInt8]) throws(OutputError) {
            frameBytes.append(contentsOf: data)
        }

        // parity: native/src/renderer-output.zig#FeedBackend.beginUpload [status=implemented hash=25f62368a97f]
        public func beginUpload(waited: Bool) {
            precondition(frameActive && activeUpload == nil)
            activeUpload = ActiveUpload(start: frameBytes.count, waited: waited)
        }

        // parity: native/src/renderer-output.zig#FeedBackend.endUpload [status=implemented hash=09b24b637987]
        public func endUpload(placementId: UInt32) {
            guard let upload = activeUpload else { return }
            activeUpload = nil
            if frameStatus != .ok { return }
            let state: UploadState
            if UInt64(upload.len) > uploadLimit() {
                state = .tooLarge
            } else if upload.cut {
                state = .deferred
            } else {
                state = .kept
            }
            uploads.append(
                Upload(
                    start: upload.start,
                    end: frameBytes.count,
                    placementId: placementId,
                    waited: upload.waited,
                    state: state
                )
            )
            if state == .kept {
                keptUploadBytes += upload.len
            }
        }

        // parity: native/src/renderer-output.zig#FeedBackend.deferUpload [status=implemented hash=27bb37687b90]
        public func deferUpload(placementId: UInt32) {
            if frameStatus != .ok { return }
            let end = frameBytes.count
            uploads.append(Upload(start: end, end: end, placementId: placementId, waited: false, state: .deferred))
        }

        // parity: native/src/renderer-output.zig#FeedBackend.lastUploadWaits [status=implemented hash=85ca586e9dce]
        public func lastUploadWaits() -> Bool {
            guard let last = uploads.last else { return false }
            return last.state != .kept
        }

        private func trimUploads() {
            let others = frameBytes.count - keptUploadBytes
            var index = uploads.count
            while UInt64(frameBytes.count) > uploadLimit() && index > 0 {
                index -= 1
                if uploads[index].state != .kept { continue }
                let upload = uploads[index]
                let uploadLen = upload.end - upload.start
                if upload.start < upload.end && upload.end <= frameBytes.count {
                    frameBytes.removeSubrange(upload.start..<upload.end)
                }
                let alone = upload.waited && uploadsAlone
                let combined = UInt64(others) &+ UInt64(uploadLen)
                uploads[index].state = (alone && combined > uploadLimit()) ? .tooLarge : .deferred
            }
        }

        // parity: native/src/renderer-output.zig#FeedBackend.failFrame [status=implemented hash=7d1137ebe0ae]
        public func failFrame() {
            if frameStatus == .ok { frameStatus = .failed }
            keptUploadBytes = 0
            frameBytes.removeAll(keepingCapacity: true)
        }

        // parity: native/src/renderer-output.zig#FeedBackend.endFrame [status=implemented hash=0472afae1cea]
        @discardableResult
        public func endFrame() -> WriteStatus {
            var status = frameStatus
            if status == .ok {
                trimUploads()
                if !frameBytes.isEmpty {
                    do {
                        let reservation = try feed.reserve(frameBytes.count)
                        _ = try feed.commit(reservation: reservation, bytes: frameBytes)
                    } catch NativeSpanFeedError.outOfSpace, NativeSpanFeedError.spanQueueFull {
                        if isFeedBounded && UInt64(frameBytes.count) <= atomicByteLimit {
                            status = .skipped
                        } else {
                            oversizeBytes = frameBytes.count
                            status = .failed
                        }
                    } catch {
                        status = .failed
                    }
                }
            }
            frameActive = false
            frameBytes.removeAll(keepingCapacity: true)
            lastWriteTimeUs = 0
            return status
        }

        /// Publishes a control sequence between frames atomically; rejected writes publish nothing.
        // parity: native/src/renderer-output.zig#FeedBackend.writeOut [status=implemented hash=30ca840eaf4a]
        public func writeOut(_ data: [UInt8]) {
            precondition(!frameActive)
            guard !data.isEmpty else { return }
            if let reservation = try? feed.reserve(data.count) {
                _ = try? feed.commit(reservation: reservation, bytes: data)
            }
        }

        public func writeOut(_ text: String) {
            writeOut(Array(text.utf8))
        }
    }
}

// MARK: - 5. native/src/renderer.zig (12 unmapped symbols)

/// Pure-Swift parity bridge for `packages/native/src/renderer.zig`, bridging directly
/// to `OpenTUICore.AnsiDiffRenderer`, `OpenTUICore.OptimizedBuffer`, `NativeTerminalState`,
/// and `NativeRendererOutput`.
public enum NativeRendererBridge: Sendable {
    // parity: native/src/renderer.zig#RGBA [status=implemented hash=4a2784ea6614]
    public typealias RGBA = OpenTUICore.RGBA

    // parity: native/src/renderer.zig#OptimizedBuffer [status=implemented hash=ec2239a7a7cc]
    public typealias OptimizedBuffer = OpenTUICore.OptimizedBuffer

    // parity: native/src/renderer.zig#TextAttributes [status=implemented hash=a8cf516ce20f]
    public typealias TextAttributes = NativeANSI.TextAttributes

    // parity: native/src/renderer.zig#CursorStyle [status=implemented hash=16d75e8f2485]
    public typealias CursorStyle = NativeTerminalState.CursorStyle

    // parity: native/src/renderer.zig#StdoutOutput [status=implemented hash=92abfbef1705]
    public typealias StdoutOutput = NativeRendererOutput.StdoutOutput

    // parity: native/src/renderer.zig#FeedBackend [status=implemented hash=53428ed45793]
    public typealias FeedBackend = NativeRendererOutput.FeedBackend

    // parity: native/src/renderer.zig#SplitSnapshot [status=implemented hash=6cf23f1458d0]
    public struct SplitSnapshot: @unchecked Sendable {
        public let snapshot: OptimizedBuffer
        public var rowColumns: UInt32
        public var startOnNewLine: Bool
        public var trailingNewline: Bool

        public init(
            snapshot: OptimizedBuffer,
            rowColumns: UInt32,
            startOnNewLine: Bool = false,
            trailingNewline: Bool = true
        ) {
            self.snapshot = snapshot
            self.rowColumns = rowColumns
            self.startOnNewLine = startOnNewLine
            self.trailingNewline = trailingNewline
        }
    }

    // parity: native/src/renderer.zig#SplitRender [status=implemented hash=e75943f9ddcd]
    public struct SplitRender: @unchecked Sendable {
        public var snapshots: [SplitSnapshot]
        public var pinnedRenderOffset: UInt32
        public var paintFooter: Bool
        public var suspended: Bool

        public init(
            snapshots: [SplitSnapshot] = [],
            pinnedRenderOffset: UInt32 = 0,
            paintFooter: Bool = true,
            suspended: Bool = false
        ) {
            self.snapshots = snapshots
            self.pinnedRenderOffset = pinnedRenderOffset
            self.paintFooter = paintFooter
            self.suspended = suspended
        }
    }

    // parity: native/src/renderer.zig#SplitFooterTransitionMode [status=implemented hash=2e0e8bdc8bef]
    public enum SplitFooterTransitionMode: UInt8, Equatable, Hashable, Sendable, Codable, CaseIterable {
        case none = 0
        case viewportScroll = 1
        case clearStaleRows = 2
    }

    // parity: native/src/renderer.zig#FrameWork [status=implemented hash=e0152e56f1a0]
    public struct FrameWork: Equatable, Hashable, Sendable, Codable {
        public static let fullPathForced: UInt32 = 1
        public static let fullPathScreen: UInt32 = 2
        public static let fullPathImages: UInt32 = 4
        public static let fullPathTainted: UInt32 = 8
        public static let fullPathUnretained: UInt32 = 16
        public static let fullPathOptions: UInt32 = 32
        public static let fullPathNonLocal: UInt32 = 64

        public var workFrameId: UInt64
        public var candidateVisits: UInt64
        public var paintVisits: UInt64
        public var viewPreparations: UInt64
        public var geometryReads: UInt64
        public var yogaSolves: UInt64
        public var feedbackOperations: UInt64
        public var visibilitySteps: UInt64
        public var viewportChildRefreshes: UInt64
        public var overlapTests: UInt64
        public var membersPainted: UInt64
        public var memberCells: UInt64
        public var cellsCleared: UInt64
        public var rowsCompared: UInt64
        public var rowsDiffed: UInt64
        public var fullPathReasons: UInt32
        public var hostRequests: UInt32
        public var layoutRounds: UInt32
        public var damageRows: UInt32

        public init(
            workFrameId: UInt64 = 0,
            candidateVisits: UInt64 = 0,
            paintVisits: UInt64 = 0,
            viewPreparations: UInt64 = 0,
            geometryReads: UInt64 = 0,
            yogaSolves: UInt64 = 0,
            feedbackOperations: UInt64 = 0,
            visibilitySteps: UInt64 = 0,
            viewportChildRefreshes: UInt64 = 0,
            overlapTests: UInt64 = 0,
            membersPainted: UInt64 = 0,
            memberCells: UInt64 = 0,
            cellsCleared: UInt64 = 0,
            rowsCompared: UInt64 = 0,
            rowsDiffed: UInt64 = 0,
            fullPathReasons: UInt32 = 0,
            hostRequests: UInt32 = 0,
            layoutRounds: UInt32 = 0,
            damageRows: UInt32 = 0
        ) {
            self.workFrameId = workFrameId
            self.candidateVisits = candidateVisits
            self.paintVisits = paintVisits
            self.viewPreparations = viewPreparations
            self.geometryReads = geometryReads
            self.yogaSolves = yogaSolves
            self.feedbackOperations = feedbackOperations
            self.visibilitySteps = visibilitySteps
            self.viewportChildRefreshes = viewportChildRefreshes
            self.overlapTests = overlapTests
            self.membersPainted = membersPainted
            self.memberCells = memberCells
            self.cellsCleared = cellsCleared
            self.rowsCompared = rowsCompared
            self.rowsDiffed = rowsDiffed
            self.fullPathReasons = fullPathReasons
            self.hostRequests = hostRequests
            self.layoutRounds = layoutRounds
            self.damageRows = damageRows
        }

        /// Merges encoder work counts into scene work counts (`fullPathReasons` ORed, all others summed).
        public func merge(_ encode: FrameWork) -> FrameWork {
            FrameWork(
                workFrameId: workFrameId &+ encode.workFrameId,
                candidateVisits: candidateVisits &+ encode.candidateVisits,
                paintVisits: paintVisits &+ encode.paintVisits,
                viewPreparations: viewPreparations &+ encode.viewPreparations,
                geometryReads: geometryReads &+ encode.geometryReads,
                yogaSolves: yogaSolves &+ encode.yogaSolves,
                feedbackOperations: feedbackOperations &+ encode.feedbackOperations,
                visibilitySteps: visibilitySteps &+ encode.visibilitySteps,
                viewportChildRefreshes: viewportChildRefreshes &+ encode.viewportChildRefreshes,
                overlapTests: overlapTests &+ encode.overlapTests,
                membersPainted: membersPainted &+ encode.membersPainted,
                memberCells: memberCells &+ encode.memberCells,
                cellsCleared: cellsCleared &+ encode.cellsCleared,
                rowsCompared: rowsCompared &+ encode.rowsCompared,
                rowsDiffed: rowsDiffed &+ encode.rowsDiffed,
                fullPathReasons: fullPathReasons | encode.fullPathReasons,
                hostRequests: hostRequests &+ encode.hostRequests,
                layoutRounds: layoutRounds &+ encode.layoutRounds,
                damageRows: damageRows &+ encode.damageRows
            )
        }

        public func toNativeFrameWork() -> NativeFrameWork {
            NativeFrameWork(
                workFrameId: workFrameId,
                candidateVisits: UInt32(clamping: candidateVisits),
                paintVisits: UInt32(clamping: paintVisits),
                viewPreparations: UInt32(clamping: viewPreparations),
                geometryReads: UInt32(clamping: geometryReads),
                yogaSolves: UInt32(clamping: yogaSolves),
                feedbackOperations: UInt32(clamping: feedbackOperations),
                visibilitySteps: UInt32(clamping: visibilitySteps),
                viewportChildRefreshes: UInt32(clamping: viewportChildRefreshes),
                overlapTests: UInt32(clamping: overlapTests),
                membersPainted: UInt32(clamping: membersPainted),
                memberCells: UInt32(clamping: memberCells),
                cellsCleared: UInt32(clamping: cellsCleared),
                rowsCompared: UInt32(clamping: rowsCompared),
                rowsDiffed: UInt32(clamping: rowsDiffed),
                fullPathReasons: fullPathReasons,
                hostRequests: hostRequests,
                layoutRounds: layoutRounds,
                damageRows: damageRows
            )
        }
    }

    // parity: native/src/renderer.zig#RenderStatsSnapshot [status=implemented hash=e1fc4e67f602]
    public struct RenderStatsSnapshot: Equatable, Hashable, Sendable, Codable {
        public var lastFrameTime: Double
        public var averageFrameTime: Double
        public var frameCount: UInt64
        public var cellsUpdated: UInt32
        public var averageCellsUpdated: UInt32
        public var renderTime: Double?
        public var outputWriteTime: Double?
        public var frameWork: FrameWork

        public init(
            lastFrameTime: Double = 0,
            averageFrameTime: Double = 0,
            frameCount: UInt64 = 0,
            cellsUpdated: UInt32 = 0,
            averageCellsUpdated: UInt32 = 0,
            renderTime: Double? = nil,
            outputWriteTime: Double? = nil,
            frameWork: FrameWork = FrameWork()
        ) {
            self.lastFrameTime = lastFrameTime
            self.averageFrameTime = averageFrameTime
            self.frameCount = frameCount
            self.cellsUpdated = cellsUpdated
            self.averageCellsUpdated = averageCellsUpdated
            self.renderTime = renderTime
            self.outputWriteTime = outputWriteTime
            self.frameWork = frameWork
        }

        public init(
            from stats: AnsiDiffRenderStats,
            lastFrameTime: Double = 0,
            averageFrameTime: Double = 0,
            renderTime: Double? = nil,
            outputWriteTime: Double? = nil
        ) {
            self.lastFrameTime = lastFrameTime
            self.averageFrameTime = averageFrameTime
            self.frameCount = stats.frameCount
            self.cellsUpdated = UInt32(clamping: stats.cellsUpdated)
            self.averageCellsUpdated = UInt32(clamping: stats.cellsUpdated)
            self.renderTime = renderTime
            self.outputWriteTime = outputWriteTime
            self.frameWork = FrameWork(
                workFrameId: stats.frameCount,
                rowsCompared: UInt64(max(0, stats.rowsCompared)),
                rowsDiffed: UInt64(max(0, stats.rowsDiffed)),
                damageRows: UInt32(clamping: stats.rowsDiffed)
            )
        }

        public func toNativeRenderStats() -> NativeRenderStats {
            NativeRenderStats(
                nativeLastFrameTime: lastFrameTime,
                nativeAverageFrameTime: averageFrameTime,
                nativeFrameCount: frameCount,
                cellsUpdated: cellsUpdated,
                averageCellsUpdated: Double(averageCellsUpdated),
                nativeRenderTime: renderTime,
                nativeStdoutWriteTime: outputWriteTime,
                frameWork: frameWork.toNativeFrameWork()
            )
        }
    }

    // parity: native/src/renderer.zig#SplitFooterTransition [status=implemented hash=cf0cd9a566fc]
    public struct SplitFooterTransition: Equatable, Hashable, Sendable, Codable {
        public var mode: SplitFooterTransitionMode
        public var sourceTopLine: UInt32
        public var sourceHeight: UInt32
        public var targetTopLine: UInt32
        public var targetHeight: UInt32
        public var scrollLines: UInt32

        public init(
            mode: SplitFooterTransitionMode = .none,
            sourceTopLine: UInt32 = 0,
            sourceHeight: UInt32 = 0,
            targetTopLine: UInt32 = 0,
            targetHeight: UInt32 = 0,
            scrollLines: UInt32 = 0
        ) {
            self.mode = mode
            self.sourceTopLine = sourceTopLine
            self.sourceHeight = sourceHeight
            self.targetTopLine = targetTopLine
            self.targetHeight = targetHeight
            self.scrollLines = scrollLines
        }

        public mutating func clear() {
            self = SplitFooterTransition()
        }
    }

    // MARK: Engine Bridge Helpers

    /// Applies detected capabilities and cursor state from `NativeTerminalState` onto `AnsiDiffRenderer`.
    public static func applyTerminalState(_ terminal: NativeTerminalState, to renderer: AnsiDiffRenderer) {
        renderer.capabilities = terminal.getCapabilities().toRendererCapabilities(
            synchronizedOutput: terminal.synchronizedOutput()
        )
        let pos = terminal.getCursorPosition()
        let style = terminal.getCursorStyle()
        renderer.cursorState = CursorRenderState(
            x: Int(pos.x),
            y: Int(pos.y),
            visible: pos.visible,
            style: style.style.renderStyle,
            blinking: style.blinking,
            color: terminal.getCursorColor()
        )
    }

    /// Renders one frame from `AnsiDiffRenderer` through `FeedBackend` with backpressure handling.
    @discardableResult
    public static func renderFrame(
        renderer: AnsiDiffRenderer,
        backend: FeedBackend,
        force: Bool = false,
        clearNextAfterRender: Bool = true
    ) -> RenderStatus {
        guard backend.prepareFrame() == .ok else {
            return .skipped
        }
        backend.beginFrame()
        let bytes = renderer.renderBytes(force: force, clearNextAfterRender: clearNextAfterRender)
        if !bytes.isEmpty {
            do {
                try backend.frameWrite(bytes)
            } catch {
                backend.failFrame()
            }
        }
        switch backend.endFrame() {
        case .ok:
            return .rendered
        case .skipped:
            renderer.invalidate()
            return .skipped
        case .failed:
            renderer.invalidate()
            return .failed
        }
    }
}
