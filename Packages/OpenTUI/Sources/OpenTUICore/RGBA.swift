// parity: core/src/lib/RGBA.ts#RGBTriplet [status=implemented hash=1b89f3dd373d]
public struct RGBTriplet: Equatable, Hashable, Sendable, Codable {
    public let r: UInt8
    public let g: UInt8
    public let b: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }
}

// parity: core/src/lib/RGBA.ts#ColorIntent [status=implemented hash=ffe0cf615b22]
public enum ColorIntent: String, Equatable, Hashable, Sendable, Codable {
    case rgb
    case indexed
    case `default`
}

// parity: core/src/lib/RGBA.ts#DEFAULT_FOREGROUND_RGB [status=implemented hash=b421c96e77d0]
public let defaultForegroundRGB = RGBTriplet(255, 255, 255)
// parity: core/src/lib/RGBA.ts#DEFAULT_BACKGROUND_RGB [status=implemented hash=c7eab8ddeb56]
public let defaultBackgroundRGB = RGBTriplet(0, 0, 0)

public enum ColorError: Error, Equatable, Sendable {
    case invalidIndexedColor(Int)
}

private let intentRGB: UInt32 = 0
private let intentIndexed: UInt32 = 1
private let intentDefault: UInt32 = 2

private let ansi16RGB: [RGBTriplet] = [
    RGBTriplet(0x00, 0x00, 0x00), // 0
    RGBTriplet(0x80, 0x00, 0x00), // 1
    RGBTriplet(0x00, 0x80, 0x00), // 2
    RGBTriplet(0x80, 0x80, 0x00), // 3
    RGBTriplet(0x00, 0x00, 0x80), // 4
    RGBTriplet(0x80, 0x00, 0x80), // 5
    RGBTriplet(0x00, 0x80, 0x80), // 6
    RGBTriplet(0xC0, 0xC0, 0xC0), // 7
    RGBTriplet(0x80, 0x80, 0x80), // 8
    RGBTriplet(0xFF, 0x00, 0x00), // 9
    RGBTriplet(0x00, 0xFF, 0x00), // 10
    RGBTriplet(0xFF, 0xFF, 0x00), // 11
    RGBTriplet(0x00, 0x00, 0xFF), // 12
    RGBTriplet(0xFF, 0x00, 0xFF), // 13
    RGBTriplet(0x00, 0xFF, 0xFF), // 14
    RGBTriplet(0xFF, 0xFF, 0xFF), // 15
]

private let ansi256CubeLevels: [UInt8] = [0, 95, 135, 175, 215, 255]

@inline(__always)
private func packMeta(intent: UInt32, slot: UInt32 = 0) -> UInt32 {
    (slot & 0xFF) | ((intent & 0xFF) << 8)
}

@inline(__always)
private func toU8(_ value: Double) -> UInt8 {
    let clamped = value.isFinite ? max(0.0, min(1.0, value)) : 0.0
    return UInt8(jsMathRound(clamped * 255.0))
}

@inline(__always)
private func toByte(_ value: Double) -> UInt8 {
    let clamped = value.isFinite ? max(0.0, min(255.0, value)) : 0.0
    return UInt8(jsMathRound(clamped))
}

/// Matches JS `Math.round(x)` (ties toward +infinity).
@inline(__always)
private func jsMathRound(_ x: Double) -> Int {
    Int((x + 0.5).rounded(.down))
}

// parity: core/src/lib/RGBA.ts#normalizeIndexedColorIndex [status=implemented hash=d9482b9f9399]
public func normalizeIndexedColorIndex(_ index: Int) throws(ColorError) -> Int {
    guard index >= 0 && index <= 255 else {
        throw .invalidIndexedColor(index)
    }
    return index
}

// parity: core/src/lib/RGBA.ts#ansi256IndexToRgb [status=implemented hash=6bab761c4d60]
public func ansi256IndexToRgb(_ index: Int) throws(ColorError) -> RGBTriplet {
    let normalized = try normalizeIndexedColorIndex(index)
    if normalized < ansi16RGB.count {
        return ansi16RGB[normalized]
    }
    if normalized < 232 {
        let cubeIndex = normalized - 16
        let r = cubeIndex / 36
        let g = (cubeIndex / 6) % 6
        let b = cubeIndex % 6
        return RGBTriplet(ansi256CubeLevels[r], ansi256CubeLevels[g], ansi256CubeLevels[b])
    }
    let value = UInt8(8 + (normalized - 232) * 10)
    return RGBTriplet(value, value, value)
}

/// ABI-compatible 4xUInt16 packed RGBA color matching `opentui.h` and `packages/core/src/lib/RGBA.ts`.
/// Low byte of each lane stores 8-bit R/G/B/A; high bytes pack `slot` (byte 0) and `intent` (byte 1).
// parity: core/src/lib/RGBA.ts#RGBA [status=implemented hash=696d66005477]
public struct RGBA: Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
    public var b0: UInt16
    public var b1: UInt16
    public var b2: UInt16
    public var b3: UInt16

    public var buffer: [UInt16] { [b0, b1, b2, b3] }

    public init(b0: UInt16, b1: UInt16, b2: UInt16, b3: UInt16) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.b3 = b3
    }

    // parity: core/src/lib/RGBA.ts#RGBA.fromArray [status=implemented hash=6de60351b411]
    public static func fromArray(_ array: [UInt16]) -> RGBA {
        RGBA(
            b0: array.count > 0 ? array[0] : 0,
            b1: array.count > 1 ? array[1] : 0,
            b2: array.count > 2 ? array[2] : 0,
            b3: array.count > 3 ? array[3] : 0
        )
    }

    private static func pack(r: UInt8, g: UInt8, b: UInt8, a: UInt8, meta: UInt32) -> RGBA {
        RGBA(
            b0: UInt16(r) | (UInt16((meta >> 0) & 0xFF) << 8),
            b1: UInt16(g) | (UInt16((meta >> 8) & 0xFF) << 8),
            b2: UInt16(b) | (UInt16((meta >> 16) & 0xFF) << 8),
            b3: UInt16(a) | (UInt16((meta >> 24) & 0xFF) << 8)
        )
    }

    // parity: core/src/lib/RGBA.ts#RGBA.fromValues [status=implemented hash=7e65245afc18]
    public static func fromValues(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1.0) -> RGBA {
        pack(r: toU8(r), g: toU8(g), b: toU8(b), a: toU8(a), meta: packMeta(intent: intentRGB))
    }

    // parity: core/src/lib/RGBA.ts#RGBA.clone [status=implemented hash=edf746902e89]
    public static func clone(_ rgba: RGBA) -> RGBA {
        rgba
    }

    // parity: core/src/lib/RGBA.ts#RGBA.fromInts [status=implemented hash=9da08be67b2a]
    public static func fromInts(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 255.0) -> RGBA {
        pack(r: toByte(r), g: toByte(g), b: toByte(b), a: toByte(a), meta: packMeta(intent: intentRGB))
    }

    public static func fromInts(_ r: Int, _ g: Int, _ b: Int, _ a: Int = 255) -> RGBA {
        fromInts(Double(r), Double(g), Double(b), Double(a))
    }

    // parity: core/src/lib/RGBA.ts#RGBA.fromHex [status=implemented hash=1f0e9bc52581]
    public static func fromHex(_ hex: String) -> RGBA {
        hexToRgb(hex)
    }

    // parity: core/src/lib/RGBA.ts#RGBA.fromIndex [status=implemented hash=4bcd7dcc17c0]
    public static func fromIndex(_ index: Int, snapshot: String? = nil) throws(ColorError) -> RGBA {
        let normalized = try normalizeIndexedColorIndex(index)
        let resolved: RGBA
        if let snapshot {
            resolved = parseColor(snapshot)
        } else {
            let rgb = try ansi256IndexToRgb(normalized)
            resolved = RGBA.fromInts(Int(rgb.r), Int(rgb.g), Int(rgb.b))
        }
        let ints = resolved.toInts()
        return pack(
            r: ints.0,
            g: ints.1,
            b: ints.2,
            a: ints.3,
            meta: packMeta(intent: intentIndexed, slot: UInt32(normalized))
        )
    }

    // parity: core/src/lib/RGBA.ts#RGBA.defaultForeground [status=implemented hash=c0316bab368b]
    public static func defaultForeground(snapshot: String? = nil) -> RGBA {
        let resolved = snapshot.map(parseColor)
            ?? RGBA.fromInts(Int(defaultForegroundRGB.r), Int(defaultForegroundRGB.g), Int(defaultForegroundRGB.b))
        let ints = resolved.toInts()
        return pack(r: ints.0, g: ints.1, b: ints.2, a: ints.3, meta: packMeta(intent: intentDefault))
    }

    // parity: core/src/lib/RGBA.ts#RGBA.defaultBackground [status=implemented hash=63940db852d1]
    public static func defaultBackground(snapshot: String? = nil) -> RGBA {
        let resolved = snapshot.map(parseColor)
            ?? RGBA.fromInts(Int(defaultBackgroundRGB.r), Int(defaultBackgroundRGB.g), Int(defaultBackgroundRGB.b))
        let ints = resolved.toInts()
        return pack(r: ints.0, g: ints.1, b: ints.2, a: ints.3, meta: packMeta(intent: intentDefault))
    }

    // parity: core/src/lib/RGBA.ts#RGBA.toInts [status=implemented hash=a4d5252611bc]
    public func toInts() -> (UInt8, UInt8, UInt8, UInt8) {
        (UInt8(b0 & 0xFF), UInt8(b1 & 0xFF), UInt8(b2 & 0xFF), UInt8(b3 & 0xFF))
    }

    // parity: core/src/lib/RGBA.ts#RGBA.r [status=implemented hash=23e4d6d661ec]
    public var r: Double {
        get { Double(b0 & 0xFF) / 255.0 }
        set { b0 = (b0 & 0xFF00) | UInt16(toU8(newValue)) }
    }

    // parity: core/src/lib/RGBA.ts#RGBA.g [status=implemented hash=1ebbca5f881c]
    public var g: Double {
        get { Double(b1 & 0xFF) / 255.0 }
        set { b1 = (b1 & 0xFF00) | UInt16(toU8(newValue)) }
    }

    // parity: core/src/lib/RGBA.ts#RGBA.b [status=implemented hash=a086c3009119]
    public var b: Double {
        get { Double(b2 & 0xFF) / 255.0 }
        set { b2 = (b2 & 0xFF00) | UInt16(toU8(newValue)) }
    }

    // parity: core/src/lib/RGBA.ts#RGBA.a [status=implemented hash=3502dfa1b734]
    public var a: Double {
        get { Double(b3 & 0xFF) / 255.0 }
        set { b3 = (b3 & 0xFF00) | UInt16(toU8(newValue)) }
    }

    // parity: core/src/lib/RGBA.ts#RGBA.meta [status=implemented hash=a61ceba5991e]
    public var meta: UInt32 {
        UInt32(b0 >> 8)
            | (UInt32(b1 >> 8) << 8)
            | (UInt32(b2 >> 8) << 16)
            | (UInt32(b3 >> 8) << 24)
    }

    // parity: core/src/lib/RGBA.ts#RGBA.intent [status=implemented hash=b2702164d3e6]
    public var intent: ColorIntent {
        switch (meta >> 8) & 0xFF {
        case intentIndexed: return .indexed
        case intentDefault: return .default
        default: return .rgb
        }
    }

    // parity: core/src/lib/RGBA.ts#RGBA.slot [status=implemented hash=58321907e536]
    public var slot: UInt8 {
        UInt8(meta & 0xFF)
    }

    // parity: core/src/lib/RGBA.ts#RGBA.toString [status=implemented hash=c77707a22e68]
    public var description: String {
        "rgba(\(fixed2(r)), \(fixed2(g)), \(fixed2(b)), \(fixed2(a)))"
    }

    // parity: core/src/lib/RGBA.ts#RGBA.equals [status=implemented hash=b07b58e43b83]
    public func equals(_ other: RGBA?) -> Bool {
        guard let other else { return false }
        return self == other
    }
}

private let cssColorNames: [String: String] = [
    "black": "#000000",
    "white": "#FFFFFF",
    "red": "#FF0000",
    "green": "#008000",
    "blue": "#0000FF",
    "yellow": "#FFFF00",
    "cyan": "#00FFFF",
    "magenta": "#FF00FF",
    "silver": "#C0C0C0",
    "gray": "#808080",
    "grey": "#808080",
    "maroon": "#800000",
    "olive": "#808000",
    "lime": "#00FF00",
    "aqua": "#00FFFF",
    "teal": "#008080",
    "navy": "#000080",
    "fuchsia": "#FF00FF",
    "purple": "#800080",
    "orange": "#FFA500",
    "brightblack": "#666666",
    "brightred": "#FF6666",
    "brightgreen": "#66FF66",
    "brightblue": "#6666FF",
    "brightyellow": "#FFFF66",
    "brightcyan": "#66FFFF",
    "brightmagenta": "#FF66FF",
    "brightwhite": "#FFFFFF",
]

// parity: core/src/lib/RGBA.ts#hexToRgb [status=implemented hash=d2030e00fdb7]
public func hexToRgb(_ input: String) -> RGBA {
    var raw = input
    if raw.hasPrefix("#") {
        raw.removeFirst()
    }
    let bytes = Array(raw.utf8)
    let expanded: [UInt8]
    if bytes.count == 3 {
        expanded = [bytes[0], bytes[0], bytes[1], bytes[1], bytes[2], bytes[2]]
    } else if bytes.count == 4 {
        expanded = [bytes[0], bytes[0], bytes[1], bytes[1], bytes[2], bytes[2], bytes[3], bytes[3]]
    } else {
        expanded = bytes
    }

    guard expanded.count == 6 || expanded.count == 8 else {
        return RGBA.fromValues(1, 0, 1, 1)
    }

    var nibbles: [UInt8] = []
    nibbles.reserveCapacity(expanded.count)
    for byte in expanded {
        guard let n = hexNibble(byte) else {
            return RGBA.fromValues(1, 0, 1, 1)
        }
        nibbles.append(n)
    }

    let r = Int((nibbles[0] << 4) | nibbles[1])
    let g = Int((nibbles[2] << 4) | nibbles[3])
    let b = Int((nibbles[4] << 4) | nibbles[5])
    let a = expanded.count == 8 ? Int((nibbles[6] << 4) | nibbles[7]) : 255
    return RGBA.fromInts(r, g, b, a)
}

// parity: core/src/lib/RGBA.ts#rgbToHex [status=implemented hash=aca0cb6017fd]
public func rgbToHex(_ rgb: RGBA) -> String {
    let (r, g, b, a) = rgb.toInts()
    if a == 255 {
        return "#\(hexByte(r))\(hexByte(g))\(hexByte(b))"
    }
    return "#\(hexByte(r))\(hexByte(g))\(hexByte(b))\(hexByte(a))"
}

// parity: core/src/lib/RGBA.ts#hsvToRgb [status=implemented hash=15d5beedbc73]
public func hsvToRgb(_ h: Double, _ s: Double, _ v: Double) -> RGBA {
    let sector = Int((h / 60.0).rounded(.down))
    let i = ((sector % 6) + 6) % 6
    let f = h / 60.0 - (h / 60.0).rounded(.down)
    let p = v * (1.0 - s)
    let q = v * (1.0 - f * s)
    let t = v * (1.0 - (1.0 - f) * s)

    let r: Double
    let g: Double
    let b: Double
    switch i {
    case 0: (r, g, b) = (v, t, p)
    case 1: (r, g, b) = (q, v, p)
    case 2: (r, g, b) = (p, v, t)
    case 3: (r, g, b) = (p, q, v)
    case 4: (r, g, b) = (t, p, v)
    default: (r, g, b) = (v, p, q)
    }
    return RGBA.fromValues(r, g, b, 1.0)
}

// parity: core/src/lib/RGBA.ts#parseColor [status=implemented hash=5048814e1b03]
public func parseColor(_ color: String) -> RGBA {
    let lower = color.lowercased()
    if lower == "transparent" {
        return RGBA.fromValues(0, 0, 0, 0)
    }
    if let mapped = cssColorNames[lower] {
        return hexToRgb(mapped)
    }
    return hexToRgb(color)
}

private let lowerHex: [UInt8] = Array("0123456789abcdef".utf8)

private func hexByte(_ value: UInt8) -> String {
    String(decoding: [lowerHex[Int(value >> 4)], lowerHex[Int(value & 0x0F)]], as: UTF8.self)
}

private func hexNibble(_ byte: UInt8) -> UInt8? {
    if byte >= 0x30 && byte <= 0x39 { return byte - 0x30 }
    if byte >= 0x41 && byte <= 0x46 { return byte - 0x41 + 10 }
    if byte >= 0x61 && byte <= 0x66 { return byte - 0x61 + 10 }
    return nil
}

private func fixed2(_ value: Double) -> String {
    let hundredths = Int((value * 100.0).rounded(.toNearestOrAwayFromZero))
    let whole = hundredths / 100
    let frac = abs(hundredths % 100)
    let fracStr = frac < 10 ? "0\(frac)" : "\(frac)"
    return "\(whole).\(fracStr)"
}
