/// Terminal palette query generation, OSC 4 / OSC 10-19 color response parsing,
/// palette normalization, and signature hashing matching `packages/core/src/lib/terminal-palette.ts`.

// MARK: - Types

/// Callback used to emit OSC query sequences to the terminal output stream.
// parity: core/src/lib/terminal-palette.ts#WriteFunction [status=implemented hash=fa1c019cc1b5]
public typealias WriteFunction = (String) -> Bool

/// Detected terminal palette and special colors as `#rrggbb` hex strings (or `nil` when undetected).
// parity: core/src/lib/terminal-palette.ts#TerminalColors [status=implemented hash=dd82e83bda34]
public struct TerminalColors: Equatable, Hashable, Sendable, Codable {
    public var palette: [String?]
    public var defaultForeground: String?
    public var defaultBackground: String?
    public var cursorColor: String?
    public var mouseForeground: String?
    public var mouseBackground: String?
    public var tekForeground: String?
    public var tekBackground: String?
    public var highlightBackground: String?
    public var highlightForeground: String?

    public init(
        palette: [String?] = [],
        defaultForeground: String? = nil,
        defaultBackground: String? = nil,
        cursorColor: String? = nil,
        mouseForeground: String? = nil,
        mouseBackground: String? = nil,
        tekForeground: String? = nil,
        tekBackground: String? = nil,
        highlightBackground: String? = nil,
        highlightForeground: String? = nil
    ) {
        self.palette = palette
        self.defaultForeground = defaultForeground
        self.defaultBackground = defaultBackground
        self.cursorColor = cursorColor
        self.mouseForeground = mouseForeground
        self.mouseBackground = mouseBackground
        self.tekForeground = tekForeground
        self.tekBackground = tekBackground
        self.highlightBackground = highlightBackground
        self.highlightForeground = highlightForeground
    }
}

/// Options controlling terminal palette detection.
// parity: core/src/lib/terminal-palette.ts#GetPaletteOptions [status=implemented hash=bf557a90131a]
public struct GetPaletteOptions: Equatable, Hashable, Sendable, Codable {
    public var timeout: Int
    public var size: Int

    public init(timeout: Int = 5000, size: Int = 16) {
        self.timeout = timeout
        self.size = size
    }
}

/// Fully normalized 256-entry RGBA terminal palette with default foreground and background fallbacks.
// parity: core/src/lib/terminal-palette.ts#NormalizedTerminalPalette [status=implemented hash=0782990ad3d5]
public struct NormalizedTerminalPalette: Equatable, Hashable, Sendable, Codable {
    public var palette: [RGBA]
    public var defaultForeground: RGBA
    public var defaultBackground: RGBA

    public init(palette: [RGBA], defaultForeground: RGBA, defaultBackground: RGBA) {
        self.palette = palette
        self.defaultForeground = defaultForeground
        self.defaultBackground = defaultBackground
    }
}

/// Subscription source delivering incoming OSC escape sequences from the terminal input stream.
// parity: core/src/lib/terminal-palette.ts#OscSubscriptionSource [status=implemented hash=8713512caff8]
public protocol OscSubscriptionSource: AnyObject {
    func subscribeOsc(_ handler: @escaping (String) -> Void) -> () -> Void
}

/// Detector protocol for querying OSC color palette support and terminal color slots.
// parity: core/src/lib/terminal-palette.ts#TerminalPaletteDetector [status=implemented hash=79830fb58985]
public protocol TerminalPaletteDetector: AnyObject {
    func detect(options: GetPaletteOptions?) -> TerminalColors
    func detectOSCSupport(timeoutMs: Int) -> Bool
    func cleanup()
}

/// Configuration options for `TerminalPalette`.
// parity: core/src/lib/terminal-palette.ts#TerminalPaletteOptions [status=implemented hash=783f79022923]
public struct TerminalPaletteOptions {
    public var isTTY: Bool
    public var writeFn: WriteFunction
    public var isLegacyTmux: Bool
    public var isTmux: Bool
    public var oscSource: (any OscSubscriptionSource)?

    public init(
        isTTY: Bool = true,
        writeFn: @escaping WriteFunction = { _ in true },
        isLegacyTmux: Bool = false,
        isTmux: Bool? = nil,
        oscSource: (any OscSubscriptionSource)? = nil
    ) {
        self.isTTY = isTTY
        self.writeFn = writeFn
        self.isLegacyTmux = isLegacyTmux
        self.isTmux = isTmux ?? isLegacyTmux
        self.oscSource = oscSource
    }
}

// MARK: - Hex & Component Scaling Helpers

private let paletteHexDigits: [UInt8] = Array("0123456789abcdef".utf8)

@inline(__always)
private func paletteHexNibble(_ byte: UInt8) -> UInt64? {
    if byte >= 0x30 && byte <= 0x39 { return UInt64(byte - 0x30) }
    if byte >= 0x41 && byte <= 0x46 { return UInt64(byte - 0x41 + 10) }
    if byte >= 0x61 && byte <= 0x66 { return UInt64(byte - 0x61 + 10) }
    return nil
}

@inline(__always)
private func paletteHexByte(_ value: UInt8) -> String {
    String(decoding: [paletteHexDigits[Int(value >> 4)], paletteHexDigits[Int(value & 0x0F)]], as: UTF8.self)
}

@inline(__always)
private func paletteIsAsciiDigit(_ byte: UInt8) -> Bool {
    byte >= 0x30 && byte <= 0x39
}

@inline(__always)
private func paletteIsAsciiHex(_ byte: UInt8) -> Bool {
    (byte >= 0x30 && byte <= 0x39)
        || (byte >= 0x41 && byte <= 0x46)
        || (byte >= 0x61 && byte <= 0x66)
}

/// Scales an X11 `rgb:` hex component of 1..4+ hex digits to a 2-digit lowercase hex channel (`00`..`ff`),
/// matching `scaleComponent` in `terminal-palette.ts`.
private func scaleRgbComponent(_ bytes: ArraySlice<UInt8>) -> String {
    let count = bytes.count
    guard count > 0 else { return "00" }
    // Use up to 15 hex digits to avoid UInt64 shift overflow while preserving precision.
    let slice = count > 15 ? bytes.prefix(15) : bytes
    var val: UInt64 = 0
    for b in slice {
        guard let nibble = paletteHexNibble(b) else { return "00" }
        val = (val << 4) | nibble
    }
    let maxIn = (UInt64(1) << UInt64(4 * slice.count)) - 1
    guard maxIn > 0 else { return "00" }
    let scaled = Int(((Double(val) / Double(maxIn)) * 255.0 + 0.5).rounded(.down))
    let clamped = UInt8(max(0, min(255, scaled)))
    return paletteHexByte(clamped)
}

private func parseColorSpec(
    _ bytes: [UInt8],
    from start: Int
) -> (hex: String, nextIndex: Int)? {
    let count = bytes.count
    guard start < count else { return nil }

    // Format 1: rgb:<hex>/<hex>/<hex>(BEL|ST)
    if start + 4 <= count,
       bytes[start] == UInt8(ascii: "r"),
       bytes[start + 1] == UInt8(ascii: "g"),
       bytes[start + 2] == UInt8(ascii: "b"),
       bytes[start + 3] == UInt8(ascii: ":")
    {
        var i = start + 4
        let rStart = i
        while i < count && paletteIsAsciiHex(bytes[i]) { i += 1 }
        let rEnd = i
        guard rEnd > rStart, i < count, bytes[i] == UInt8(ascii: "/") else { return nil }
        i += 1

        let gStart = i
        while i < count && paletteIsAsciiHex(bytes[i]) { i += 1 }
        let gEnd = i
        guard gEnd > gStart, i < count, bytes[i] == UInt8(ascii: "/") else { return nil }
        i += 1

        let bStart = i
        while i < count && paletteIsAsciiHex(bytes[i]) { i += 1 }
        let bEnd = i
        guard bEnd > bStart else { return nil }

        guard let afterTerm = consumeOscTerminator(bytes, at: i) else { return nil }
        let rHex = scaleRgbComponent(bytes[rStart..<rEnd])
        let gHex = scaleRgbComponent(bytes[gStart..<gEnd])
        let bHex = scaleRgbComponent(bytes[bStart..<bEnd])
        return ("#\(rHex)\(gHex)\(bHex)", afterTerm)
    }

    // Format 2: #<6 hex digits>(BEL|ST)
    if bytes[start] == UInt8(ascii: "#"), start + 7 <= count {
        for offset in 1...6 {
            guard paletteIsAsciiHex(bytes[start + offset]) else { return nil }
        }
        guard let afterTerm = consumeOscTerminator(bytes, at: start + 7) else { return nil }
        let raw = String(decoding: bytes[(start + 1)..<(start + 7)], as: UTF8.self).lowercased()
        return ("#\(raw)", afterTerm)
    }

    return nil
}

@inline(__always)
private func consumeOscTerminator(_ bytes: [UInt8], at index: Int) -> Int? {
    let count = bytes.count
    guard index < count else { return nil }
    if bytes[index] == 0x07 {
        return index + 1
    }
    if bytes[index] == 0x1B && index + 1 < count && bytes[index + 1] == UInt8(ascii: "\\") {
        return index + 2
    }
    return nil
}

// MARK: - Public Query Builders & Parsers

/// Wraps an OSC escape sequence in tmux DCS passthrough (`ESC P tmux; ... ESC \`).
public func wrapOscForTmux(_ osc: String) -> String {
    var escaped = ""
    escaped.reserveCapacity(osc.count + 16)
    for scalar in osc.unicodeScalars {
        if scalar.value == 0x1B {
            escaped.append("\u{1B}\u{1B}")
        } else {
            escaped.unicodeScalars.append(scalar)
        }
    }
    return "\u{1B}Ptmux;\(escaped)\u{1B}\\"
}

/// Builds OSC 4 indexed palette queries for `indices`.
public func buildOsc4Queries(indices: [Int], wrapForLegacyTmux: Bool = false) -> String {
    let raw = indices.map { "\u{1B}]4;\($0);?\u{07}" }.joined()
    return wrapForLegacyTmux ? wrapOscForTmux(raw) : raw
}

/// Builds OSC 10..19 special color queries (`[10, 11, 12]` inside tmux, full `[10..17, 19]` otherwise).
public func buildSpecialColorQueries(inTmux: Bool = false) -> String {
    let codes = inTmux ? [10, 11, 12] : [10, 11, 12, 13, 14, 15, 16, 17, 19]
    return codes.map { "\u{1B}]\($0);?\u{07}" }.joined()
}

/// Builds a combined terminal palette query sequence for `size` indexed slots plus special colors.
public func buildPaletteQueries(
    size: Int = 16,
    includeSpecialColors: Bool = true,
    inTmux: Bool = false,
    inLegacyTmux: Bool = false
) -> String {
    let clampedSize = max(0, min(256, size))
    let indices = clampedSize > 0 ? Array(0..<clampedSize) : []
    var query = buildOsc4Queries(indices: indices, wrapForLegacyTmux: inLegacyTmux)
    if includeSpecialColors {
        query += buildSpecialColorQueries(inTmux: inTmux || inLegacyTmux)
    }
    return query
}

/// Creates a blank `TerminalColors` container with `size` unset palette slots.
// parity: core/src/lib/terminal-palette.ts#emptyTerminalColors [status=implemented hash=64185d267bad]
public func emptyTerminalColors(size: Int) -> TerminalColors {
    TerminalColors(palette: Array(repeating: nil, count: max(0, size)))
}

/// Copies all OSC 4 and OSC 10-19 color replies found in `sequence` into `colors`.
/// Returns `true` if any slot changed.
// parity: core/src/lib/terminal-palette.ts#applyPaletteReplies [status=implemented hash=f8fed6b97815]
@discardableResult
public func applyPaletteReplies(_ colors: inout TerminalColors, sequence: String) -> Bool {
    let bytes = Array(sequence.utf8)
    let count = bytes.count
    var changed = false
    var i = 0

    while i + 3 < count {
        guard bytes[i] == 0x1B && bytes[i + 1] == UInt8(ascii: "]") else {
            i += 1
            continue
        }

        // Parse OSC command number
        var j = i + 2
        let cmdStart = j
        while j < count && paletteIsAsciiDigit(bytes[j]) { j += 1 }
        guard j > cmdStart, j < count, bytes[j] == UInt8(ascii: ";") else {
            i += 1
            continue
        }

        guard let oscCode = Int(String(decoding: bytes[cmdStart..<j], as: UTF8.self)) else {
            i += 1
            continue
        }
        j += 1 // skip ';'

        if oscCode == 4 {
            // OSC 4;<index>;<color>
            let idxStart = j
            while j < count && paletteIsAsciiDigit(bytes[j]) { j += 1 }
            guard j > idxStart, j < count, bytes[j] == UInt8(ascii: ";") else {
                i += 1
                continue
            }
            guard let paletteIndex = Int(String(decoding: bytes[idxStart..<j], as: UTF8.self)) else {
                i += 1
                continue
            }
            j += 1 // skip ';'

            if let parsed = parseColorSpec(bytes, from: j) {
                if paletteIndex >= 0 && paletteIndex < colors.palette.count && colors.palette[paletteIndex] != parsed.hex {
                    colors.palette[paletteIndex] = parsed.hex
                    changed = true
                }
                i = parsed.nextIndex
                continue
            }
        } else {
            // OSC 10..19;<color>
            if let parsed = parseColorSpec(bytes, from: j) {
                switch oscCode {
                case 10:
                    if colors.defaultForeground != parsed.hex {
                        colors.defaultForeground = parsed.hex
                        changed = true
                    }
                case 11:
                    if colors.defaultBackground != parsed.hex {
                        colors.defaultBackground = parsed.hex
                        changed = true
                    }
                case 12:
                    if colors.cursorColor != parsed.hex {
                        colors.cursorColor = parsed.hex
                        changed = true
                    }
                case 13:
                    if colors.mouseForeground != parsed.hex {
                        colors.mouseForeground = parsed.hex
                        changed = true
                    }
                case 14:
                    if colors.mouseBackground != parsed.hex {
                        colors.mouseBackground = parsed.hex
                        changed = true
                    }
                case 15:
                    if colors.tekForeground != parsed.hex {
                        colors.tekForeground = parsed.hex
                        changed = true
                    }
                case 16:
                    if colors.tekBackground != parsed.hex {
                        colors.tekBackground = parsed.hex
                        changed = true
                    }
                case 17:
                    if colors.highlightBackground != parsed.hex {
                        colors.highlightBackground = parsed.hex
                        changed = true
                    }
                case 19:
                    if colors.highlightForeground != parsed.hex {
                        colors.highlightForeground = parsed.hex
                        changed = true
                    }
                default:
                    break
                }
                i = parsed.nextIndex
                continue
            }
        }

        i += 1
    }

    return changed
}

/// Parses all OSC 4 and OSC 10-19 color replies from `sequence` into a fresh `TerminalColors`.
public func parseOscColorResponse(_ sequence: String, size: Int = 256) -> TerminalColors {
    var colors = emptyTerminalColors(size: size)
    _ = applyPaletteReplies(&colors, sequence: sequence)
    return colors
}

/// Reports whether `sequence` contains at least one valid OSC 4 palette response.
public func containsOsc4ColorResponse(_ sequence: String) -> Bool {
    var probe = emptyTerminalColors(size: 256)
    _ = applyPaletteReplies(&probe, sequence: sequence)
    return probe.palette.contains { $0 != nil }
}

// MARK: - TerminalPalette Detector

/// Pure-Swift terminal palette detector managing OSC subscriptions and synchronous/streamed reply collection.
// parity: core/src/lib/terminal-palette.ts#TerminalPalette [status=implemented hash=e5f689f0c740]
public final class TerminalPalette: TerminalPaletteDetector {
    private let isTTY: Bool
    private let writeFn: WriteFunction
    private let inLegacyTmux: Bool
    private let inTmux: Bool
    private let oscSource: (any OscSubscriptionSource)?
    private var activeCleanups: [() -> Void] = []

    public init(options: TerminalPaletteOptions) {
        self.isTTY = options.isTTY
        self.writeFn = options.writeFn
        self.inLegacyTmux = options.isLegacyTmux
        self.inTmux = options.isTmux
        self.oscSource = options.oscSource
    }

    private func writeOsc(_ osc: String, wrapForLegacyTmux: Bool = false) -> Bool {
        let data = (wrapForLegacyTmux && inLegacyTmux) ? wrapOscForTmux(osc) : osc
        return writeFn(data)
    }

    // parity: core/src/lib/terminal-palette.ts#TerminalPalette.cleanup [status=implemented hash=ab3f82fddf7a]
    public func cleanup() {
        let pending = activeCleanups
        activeCleanups.removeAll()
        for teardown in pending {
            teardown()
        }
    }

    /// Probes OSC 4 support by sending `OSC 4;0;?` and checking any synchronously received replies.
    // parity: core/src/lib/terminal-palette.ts#TerminalPalette.detectOSCSupport [status=implemented hash=62c403f9efaf]
    public func detectOSCSupport(timeoutMs: Int = 300) -> Bool {
        _ = timeoutMs
        guard isTTY else { return false }

        var buffer = ""
        var supported = false
        var unsubscribe: (() -> Void)?

        if let oscSource {
            let unsub = oscSource.subscribeOsc { sequence in
                buffer += sequence
                if containsOsc4ColorResponse(buffer) {
                    supported = true
                }
            }
            unsubscribe = unsub
            activeCleanups.append(unsub)
        }

        _ = writeOsc("\u{1B}]4;0;?\u{07}", wrapForLegacyTmux: true)

        if let unsub = unsubscribe {
            unsub()
            activeCleanups.removeAll()
        }

        return supported
    }

    /// Queries the terminal palette and special colors, returning detected hex strings.
    // parity: core/src/lib/terminal-palette.ts#TerminalPalette.detect [status=implemented hash=4f8227ab2826]
    public func detect(options: GetPaletteOptions? = nil) -> TerminalColors {
        let opts = options ?? GetPaletteOptions()
        let size = max(0, opts.size)
        guard isTTY else { return emptyTerminalColors(size: size) }
        guard detectOSCSupport(timeoutMs: opts.timeout) else { return emptyTerminalColors(size: size) }

        var colors = emptyTerminalColors(size: size)
        var buffer = ""
        var unsubscribe: (() -> Void)?

        if let oscSource {
            let unsub = oscSource.subscribeOsc { sequence in
                buffer += sequence
                _ = applyPaletteReplies(&colors, sequence: buffer)
                if buffer.utf8.count > 8192 {
                    buffer = String(buffer.suffix(4096))
                }
            }
            unsubscribe = unsub
            activeCleanups.append(unsub)
        }

        let indices = size > 0 ? Array(0..<size) : []
        _ = writeOsc(buildOsc4Queries(indices: indices), wrapForLegacyTmux: true)
        _ = writeOsc(buildSpecialColorQueries(inTmux: inTmux), wrapForLegacyTmux: false)

        if let unsub = unsubscribe {
            unsub()
            activeCleanups.removeAll()
        }

        return colors
    }
}

/// Factory matching `createTerminalPalette` in `terminal-palette.ts`.
// parity: core/src/lib/terminal-palette.ts#createTerminalPalette [status=implemented hash=9c7ec1304733]
public func createTerminalPalette(options: TerminalPaletteOptions) -> TerminalPalette {
    TerminalPalette(options: options)
}

// MARK: - Normalization & Signature

private let defaultForegroundFallback = RGBA.fromInts(
    Int(defaultForegroundRGB.r),
    Int(defaultForegroundRGB.g),
    Int(defaultForegroundRGB.b)
)

private let defaultBackgroundFallback = RGBA.fromInts(
    Int(defaultBackgroundRGB.r),
    Int(defaultBackgroundRGB.g),
    Int(defaultBackgroundRGB.b)
)

private let fallbackAnsi256Palette: [RGBA] = (0..<256).map { index in
    if let rgb = try? ansi256IndexToRgb(index) {
        return RGBA.fromInts(Int(rgb.r), Int(rgb.g), Int(rgb.b))
    }
    return RGBA.fromInts(0, 0, 0)
}

/// Normalizes optional detected `TerminalColors` into a complete 256-color RGBA palette with fallbacks.
// parity: core/src/lib/terminal-palette.ts#normalizeTerminalPalette [status=implemented hash=f8c0dee20531]
public func normalizeTerminalPalette(_ colors: TerminalColors? = nil) -> NormalizedTerminalPalette {
    let palette: [RGBA] = (0..<256).map { index in
        if let colors, index < colors.palette.count, let detected = colors.palette[index] {
            return RGBA.fromHex(detected)
        }
        return RGBA.clone(fallbackAnsi256Palette[index])
    }

    let fg = colors?.defaultForeground.map(RGBA.fromHex) ?? RGBA.clone(defaultForegroundFallback)
    let bg = colors?.defaultBackground.map(RGBA.fromHex) ?? RGBA.clone(defaultBackgroundFallback)

    return NormalizedTerminalPalette(
        palette: palette,
        defaultForeground: fg,
        defaultBackground: bg
    )
}

/// Produces a stable deterministic signature string for a terminal palette.
// parity: core/src/lib/terminal-palette.ts#buildTerminalPaletteSignature [status=implemented hash=ff549a1dc7cf]
public func buildTerminalPaletteSignature(_ colors: TerminalColors? = nil) -> String {
    let normalized = normalizeTerminalPalette(colors)
    let paletteSignature = normalized.palette
        .map { color in
            let (r, g, b, a) = color.toInts()
            return "\(r),\(g),\(b),\(a)"
        }
        .joined(separator: ";")

    let (fr, fg, fb, fa) = normalized.defaultForeground.toInts()
    let (br, bg, bb, ba) = normalized.defaultBackground.toInts()
    return "\(paletteSignature)|\(fr),\(fg),\(fb),\(fa)|\(br),\(bg),\(bb),\(ba)"
}
