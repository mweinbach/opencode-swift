import Synchronization

/// Pure-Swift API parity completions for `OpenTUICore`:
/// - `core/src/buffer.ts` (`BufferAccess`, `NativeResourceOwner`, `ResourceContext`, `EncodedUnicode`,
///   `OptimizedBuffer` supersampling, packed cell buffers, grayscale buffers, grids, images,
///   text/editor view rendering, Unicode cluster tokens, and scoped plane access)
/// - `core/src/lib/RGBA.ts` (`ColorInput`, `NormalizedColorValue`, `RGBA.map`, `normalizeColorValue`)
/// - `core/src/lib/border.ts` (`BorderConfig`, `BoxDrawOptions` convenience initializers)
/// - `core/src/text-buffer.ts` & `core/src/edit-buffer.ts` (`loadFile`, `setSyntaxStyle`, `getSyntaxStyle`)
/// - `core/src/lib/stdin-parser-native.ts` (`NativeInputSession`)
/// - `core/src/types.ts` (`ATTRIBUTE_BASE_BITS`, `ATTRIBUTE_BASE_MASK`, `DebugOverlayCorner`,
///   `WidthMethod`, `Timeout`, `ViewportBounds`)
/// - `core/src/utils.ts` (`visualizeRenderableTree`)
///
/// Zero Foundation or OS-specific imports — compiles on every Swift 6 platform.

// MARK: - Core Types & Constants (`core/src/types.ts`)

/// Bit shift separating base 8-bit text attributes from the 24-bit hyperlink ID payload.
// parity: core/src/types.ts#ATTRIBUTE_BASE_BITS [status=implemented hash=94578ee0aa12]
public let ATTRIBUTE_BASE_BITS: UInt32 = TextAttributes.linkShift

/// Bit mask extracting the base 8-bit text attributes (`0xFF`).
// parity: core/src/types.ts#ATTRIBUTE_BASE_MASK [status=implemented hash=c1452969d86b]
public let ATTRIBUTE_BASE_MASK: UInt32 = TextAttributes.baseMask

/// Portable timer timeout handle matching `core/src/types.ts#Timeout`.
// parity: core/src/types.ts#Timeout [status=adapted hash=608b7e1712f5]
public typealias Timeout = TimerHandle?

// parity: core/src/types.ts#DebugOverlayCorner [status=implemented hash=34249ee6688b]
public extension DebugOverlayCorner {
    /// All four terminal corners supported by the debug overlay.
    static let allCorners: [DebugOverlayCorner] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
}

// parity: core/src/types.ts#WidthMethod [status=implemented hash=b6b7f38f83d3]
public extension WidthMethod {
    /// Maps this display-width method to the text engine's `TextWidthMethod`.
    var textWidthMethod: TextWidthMethod {
        switch self {
        case .wcwidth: return .wcwidth
        case .unicode, .noZWJ: return .unicode
        case .unicodeWide: return .unicodeWide
        }
    }
}

// parity: core/src/types.ts#ViewportBounds [status=implemented hash=73c3364c8cfa]
public extension ViewportBounds {
    /// Returns `true` when the viewport has non-positive width or height.
    var isEmpty: Bool {
        width <= 0 || height <= 0
    }

    /// Returns `true` if `(px, py)` lies within `[x, x + width) × [y, y + height)`.
    func contains(x px: Int, y py: Int) -> Bool {
        px >= x && px < x + width && py >= y && py < y + height
    }

    /// Returns `true` if `self` overlaps `other` with a non-empty area.
    func intersects(_ other: ViewportBounds) -> Bool {
        guard !isEmpty && !other.isEmpty else { return false }
        return x < other.x + other.width
            && x + width > other.x
            && y < other.y + other.height
            && y + height > other.y
    }
}

// MARK: - RGBA Parity Completions (`core/src/lib/RGBA.ts`)

/// Color value accepted across OpenTUI drawing and styling APIs (`String` or `RGBA`).
// parity: core/src/lib/RGBA.ts#ColorInput [status=implemented hash=5ce2e7058168]
public typealias ColorInput = Color

/// Wrapper around a parsed `RGBA` color produced by `normalizeColorValue(_:)`.
// parity: core/src/lib/RGBA.ts#NormalizedColorValue [status=implemented hash=eefdba7f943e]
public struct NormalizedColorValue: Equatable, Hashable, Sendable, Codable {
    public var rgba: RGBA

    public init(rgba: RGBA) {
        self.rgba = rgba
    }
}

public extension RGBA {
    /// Transforms the normalized `[0, 1]` `(r, g, b, a)` channels with `fn`, returning a 4-tuple.
    // parity: core/src/lib/RGBA.ts#RGBA.map [status=implemented hash=e6ffc786c982]
    func map<R>(_ fn: (Double) -> R) -> (R, R, R, R) {
        (fn(r), fn(g), fn(b), fn(a))
    }
}

/// Parses a `ColorInput` into an `RGBA`.
public func parseColor(_ color: ColorInput) -> RGBA {
    color.resolved()
}

/// Normalizes an optional `ColorInput` (`String` or `RGBA`) into a `NormalizedColorValue`,
/// returning `nil` when `value` is `nil`.
// parity: core/src/lib/RGBA.ts#normalizeColorValue [status=implemented hash=768a19f05a00]
public func normalizeColorValue(_ value: ColorInput?) -> NormalizedColorValue? {
    guard let value else { return nil }
    return NormalizedColorValue(rgba: parseColor(value))
}

/// Convenience overload accepting an optional hex/CSS color string.
public func normalizeColorValue(_ value: String?) -> NormalizedColorValue? {
    guard let value else { return nil }
    return NormalizedColorValue(rgba: parseColor(value))
}

/// Convenience overload accepting an optional `RGBA`.
public func normalizeColorValue(_ value: RGBA?) -> NormalizedColorValue? {
    guard let value else { return nil }
    return NormalizedColorValue(rgba: value)
}

// MARK: - Border Parity Completions (`core/src/lib/border.ts`)

/// Declarative border style and side configuration matching `core/src/lib/border.ts#BorderConfig`.
// parity: core/src/lib/border.ts#BorderConfig [status=implemented hash=eb22b6563dfe]
public struct BorderConfig: Equatable, Hashable, Sendable {
    public var borderStyle: BorderStyle
    public var border: BorderSpec
    public var borderColor: ColorInput?
    public var customBorderChars: BorderCharacters?

    public init(
        borderStyle: BorderStyle = .single,
        border: BorderSpec = .enabled(true),
        borderColor: ColorInput? = nil,
        customBorderChars: BorderCharacters? = nil
    ) {
        self.borderStyle = borderStyle
        self.border = border
        self.borderColor = borderColor
        self.customBorderChars = customBorderChars
    }
}

// parity: core/src/lib/border.ts#BoxDrawOptions [status=implemented hash=14f00ec6d72c]
public extension BoxDrawOptions {
    /// Upstream-compatible initializer accepting `BorderSpec`, `ColorInput`, and `BorderCharacters`.
    init(
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        borderStyle: BorderStyle = .single,
        border: BorderSpec,
        borderColor: ColorInput,
        customBorderChars: BorderCharacters? = nil,
        backgroundColor: ColorInput,
        titleColor: ColorInput? = nil,
        shouldFill: Bool = false,
        title: String? = nil,
        titleAlignment: BoxTitleAlignment = .left,
        bottomTitle: String? = nil,
        bottomTitleAlignment: BoxTitleAlignment = .left
    ) {
        self.init(
            x: x,
            y: y,
            width: width,
            height: height,
            borderStyle: borderStyle,
            customBorderChars: customBorderChars.map(borderCharsToArray),
            borderSides: getBorderSides(border),
            borderColor: borderColor.resolved(),
            backgroundColor: backgroundColor.resolved(),
            titleColor: titleColor?.resolved(),
            shouldFill: shouldFill,
            title: title,
            titleAlignment: titleAlignment,
            bottomTitle: bottomTitle,
            bottomTitleAlignment: bottomTitleAlignment
        )
    }
}

// MARK: - Resource Context & Scoped Buffer Access (`core/src/buffer.ts`)

/// Errors thrown by `ResourceContext` lifecycle checks.
public enum ResourceContextError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    case disposed

    public var description: String {
        switch self {
        case .disposed:
            return "Resource Context is destroyed"
        }
    }
}

/// Snapshot of raw terminal cell planes matching `core/src/buffer.ts#BufferAccess`.
// parity: core/src/buffer.ts#BufferAccess [status=implemented hash=fc2e93ffc7e6]
public struct BufferAccess: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let generation: UInt64
    public let char: [UInt32]
    public let fg: [UInt16]
    public let bg: [UInt16]
    public let attributes: [UInt32]

    public init(
        width: Int,
        height: Int,
        generation: UInt64 = 1,
        char: [UInt32],
        fg: [UInt16],
        bg: [UInt16],
        attributes: [UInt32]
    ) {
        self.width = width
        self.height = height
        self.generation = generation
        self.char = char
        self.fg = fg
        self.bg = bg
        self.attributes = attributes
    }

    /// Captures a packed ABI-compatible plane view from `buffer`.
    public init(buffer: OptimizedBuffer, generation: UInt64 = 1) {
        let count = buffer.width * buffer.height
        var fgWords: [UInt16] = []
        fgWords.reserveCapacity(count * 4)
        for c in buffer.fg {
            fgWords.append(c.b0)
            fgWords.append(c.b1)
            fgWords.append(c.b2)
            fgWords.append(c.b3)
        }
        var bgWords: [UInt16] = []
        bgWords.reserveCapacity(count * 4)
        for c in buffer.bg {
            bgWords.append(c.b0)
            bgWords.append(c.b1)
            bgWords.append(c.b2)
            bgWords.append(c.b3)
        }
        self.init(
            width: buffer.width,
            height: buffer.height,
            generation: generation,
            char: buffer.chars,
            fg: fgWords,
            bg: bgWords,
            attributes: buffer.attributes
        )
    }
}

/// Protocol implemented by resource owners sharing a `ResourceContext`.
// parity: core/src/buffer.ts#NativeResourceOwner [status=implemented hash=e8d19282b8a7]
public protocol NativeResourceOwner: AnyObject, Sendable {
    var resourceContext: ResourceContext { get }
}

/// Owns checked buffer/pool resources independently of sessions and scenes.
// parity: core/src/buffer.ts#ResourceContext [status=adapted hash=be58f730fe2f]
public final class ResourceContext: NativeResourceOwner, Sendable {
    private struct State: Sendable {
        var disposed: Bool = false
    }

    private static let nextIdLock = Mutex<UInt64>(1)

    public let contextId: UInt64
    public let objectCapacity: Int
    public let renderCellsMax: Int
    public let graphemePool: GraphemePool
    public let linkPool: LinkPool
    private let state = Mutex(State())

    public init(
        objectCapacity: Int = 65_536,
        renderCellsMax: Int = 1_000_000,
        graphemePool: GraphemePool = GraphemePool(),
        linkPool: LinkPool = LinkPool()
    ) {
        self.contextId = Self.nextIdLock.withLock { current in
            let id = current
            current &+= 1
            if current == 0 { current = 1 }
            return id
        }
        self.objectCapacity = max(1, objectCapacity)
        self.renderCellsMax = max(1, renderCellsMax)
        self.graphemePool = graphemePool
        self.linkPool = linkPool
    }

    /// Returns `true` after `destroy()` has been called.
    // parity: core/src/buffer.ts#ResourceContext.disposed [status=implemented hash=8bcd778b3586]
    public var disposed: Bool {
        state.withLock { $0.disposed }
    }

    /// Conformance to `NativeResourceOwner`.
    // parity: core/src/buffer.ts#ResourceContext.resourceContext [status=implemented hash=5d8ce776b780]
    public var resourceContext: ResourceContext {
        self
    }

    /// Throws `ResourceContextError.disposed` if this context has been destroyed.
    // parity: core/src/buffer.ts#ResourceContext.assertAlive [status=implemented hash=162a02d53646]
    public func assertAlive() throws(ResourceContextError) {
        if disposed {
            throw .disposed
        }
    }

    /// Marks this resource context as disposed (idempotent).
    // parity: core/src/buffer.ts#ResourceContext.destroy [status=implemented hash=2d2fba1613a0]
    public func destroy() {
        state.withLock { $0.disposed = true }
    }
}

// MARK: - NativeInputSession (`core/src/lib/stdin-parser-native.ts`)

/// Shared session context passed to `StdinParser` when parsing through an existing session.
// parity: core/src/lib/stdin-parser-native.ts#NativeInputSession [status=adapted hash=802910307b20]
public struct NativeInputSession: @unchecked Sendable {
    public let resourceContext: ResourceContext
    public let sessionId: UInt64
    public let parser: StdinParser

    public init(
        resourceContext: ResourceContext = ResourceContext(),
        sessionId: UInt64 = 1,
        parser: StdinParser = StdinParser()
    ) {
        self.resourceContext = resourceContext
        self.sessionId = sessionId
        self.parser = parser
    }
}

// MARK: - EncodedUnicode & OptimizedBuffer Drawing Completions (`core/src/buffer.ts`)

/// Encoded display-cluster glyphs returned by `OptimizedBuffer.encodeUnicode(_:)`.
// parity: core/src/buffer.ts#EncodedUnicode [status=implemented hash=628e56a731d2]
public struct EncodedUnicode: Equatable, Hashable, Sendable {
    public struct Glyph: Equatable, Hashable, Sendable {
        public var width: Int
        public var char: UInt64

        public init(width: Int, char: UInt64) {
            self.width = width
            self.char = char
        }
    }

    public var data: [Glyph]
    internal let allocationId: UInt64

    public init(data: [Glyph]) {
        self.data = data
        self.allocationId = 0
    }

    internal init(data: [Glyph], allocationId: UInt64) {
        self.data = data
        self.allocationId = allocationId
    }
}

/// Pixel channel order for `OptimizedBuffer.drawSuperSampleBuffer(...)`.
public enum SuperSamplePixelFormat: String, Equatable, Hashable, Sendable, Codable {
    case bgra8unorm
    case rgba8unorm
}

/// Grid geometry and border styling for `OptimizedBuffer.drawGrid(_:)`.
public struct NativeBufferGrid: Equatable, Hashable, Sendable {
    public var borderChars: [UInt32]
    public var borderFg: RGBA
    public var borderBg: RGBA
    public var columnOffsets: [Int32]
    public var rowOffsets: [Int32]
    public var drawInner: Bool
    public var drawOuter: Bool

    public init(
        borderChars: [UInt32] = BorderCharArrays.single,
        borderFg: RGBA = .defaultForeground(),
        borderBg: RGBA = RGBA.fromInts(0, 0, 0, 0),
        columnOffsets: [Int32],
        rowOffsets: [Int32],
        drawInner: Bool = true,
        drawOuter: Bool = true
    ) {
        self.borderChars = borderChars
        self.borderFg = borderFg
        self.borderBg = borderBg
        self.columnOffsets = columnOffsets
        self.rowOffsets = rowOffsets
        self.drawInner = drawInner
        self.drawOuter = drawOuter
    }
}

/// Associated opaque-token registry backing `OptimizedBuffer.encodeUnicode` / `freeUnicode` / `drawChar`.
private final class BufferUnicodeRegistry: Sendable {
    struct Entry: Sendable {
        let bufferId: ObjectIdentifier
        let encodedCellChar: UInt32
        let graphemeId: UInt32
    }

    struct Allocation: Sendable {
        let bufferId: ObjectIdentifier
        let tokens: [UInt64]
        let graphemeIds: [UInt32]
    }

    struct State: Sendable {
        var nextToken: UInt64 = 0x1_0000_0000
        var nextAllocationId: UInt64 = 1
        var byToken: [UInt64: Entry] = [:]
        var byAllocation: [UInt64: Allocation] = [:]
    }

    static let shared = BufferUnicodeRegistry()
    private let state = Mutex(State())

    func allocate(
        for buffer: OptimizedBuffer,
        entries: [(encodedCellChar: UInt32, graphemeId: UInt32)]
    ) -> (allocationId: UInt64, tokens: [UInt64]) {
        let bid = ObjectIdentifier(buffer)
        return state.withLock { s in
            let allocId = s.nextAllocationId
            s.nextAllocationId &+= 1
            var tokens: [UInt64] = []
            var gids: [UInt32] = []
            tokens.reserveCapacity(entries.count)
            gids.reserveCapacity(entries.count)
            for item in entries {
                let token = s.nextToken
                s.nextToken &+= 1
                s.byToken[token] = Entry(
                    bufferId: bid,
                    encodedCellChar: item.encodedCellChar,
                    graphemeId: item.graphemeId
                )
                tokens.append(token)
                gids.append(item.graphemeId)
            }
            s.byAllocation[allocId] = Allocation(bufferId: bid, tokens: tokens, graphemeIds: gids)
            return (allocId, tokens)
        }
    }

    func lookup(token: UInt64, for buffer: OptimizedBuffer) -> UInt32? {
        let bid = ObjectIdentifier(buffer)
        return state.withLock { s in
            guard let entry = s.byToken[token], entry.bufferId == bid else { return nil }
            return entry.encodedCellChar
        }
    }

    func release(allocationId: UInt64, for buffer: OptimizedBuffer) -> [UInt32]? {
        let bid = ObjectIdentifier(buffer)
        return state.withLock { s in
            guard let alloc = s.byAllocation[allocationId], alloc.bufferId == bid else { return nil }
            s.byAllocation.removeValue(forKey: allocationId)
            for token in alloc.tokens {
                s.byToken.removeValue(forKey: token)
            }
            return alloc.graphemeIds
        }
    }
}

private let superSampleQuadrantChars: [UInt32] = [
    32,     // 0000
    0x2597, // 0001 BR
    0x2596, // 0010 BL
    0x2584, // 0011 Lower Half Block
    0x259D, // 0100 TR
    0x2590, // 0101 Right Half Block
    0x259E, // 0110 TR+BL
    0x259F, // 0111 TR+BL+BR
    0x2598, // 1000 TL
    0x259A, // 1001 TL+BR
    0x258C, // 1010 Left Half Block
    0x2599, // 1011 TL+BL+BR
    0x2580, // 1100 Upper Half Block
    0x259C, // 1101 TL+TR+BR
    0x259B, // 1110 TL+TR+BL
    0x2588, // 1111 Full Block
]

private let grayscaleRampASCII: [UInt8] = Array(
    " .'^\",:;Il!i><~+_-?][}{1)(|\\/tfjrxnuvczXYUJCLQ0OZmwqpdbkhao*#MW&8%B@$".utf8
)

@inline(__always)
private func ssColorDistance(_ a: RGBA, _ b: RGBA) -> Float {
    let ai = a.toInts()
    let bi = b.toInts()
    let dr = Float(ai.0) - Float(bi.0)
    let dg = Float(ai.1) - Float(bi.1)
    let db = Float(ai.2) - Float(bi.2)
    return dr * dr + dg * dg + db * db
}

@inline(__always)
private func ssLuminance(_ c: RGBA) -> Float {
    let i = c.toInts()
    return 0.2126 * (Float(i.0) / 255.0) + 0.7152 * (Float(i.1) / 255.0) + 0.0722 * (Float(i.2) / 255.0)
}

@inline(__always)
private func ssAverageRGBA(_ p0: RGBA, _ p1: RGBA, _ p2: RGBA, _ p3: RGBA) -> RGBA {
    let a = p0.toInts()
    let b = p1.toInts()
    let c = p2.toInts()
    let d = p3.toInts()
    let r = (Int(a.0) + Int(b.0) + Int(c.0) + Int(d.0) + 2) / 4
    let g = (Int(a.1) + Int(b.1) + Int(c.1) + Int(d.1) + 2) / 4
    let bl = (Int(a.2) + Int(b.2) + Int(c.2) + Int(d.2) + 2) / 4
    let al = (Int(a.3) + Int(b.3) + Int(c.3) + Int(d.3) + 2) / 4
    return RGBA.fromInts(r, g, bl, al)
}

@inline(__always)
private func ssRenderQuadrantBlock(
    _ p0: RGBA,
    _ p1: RGBA,
    _ p2: RGBA,
    _ p3: RGBA
) -> (char: UInt32, fg: RGBA, bg: RGBA) {
    let pixels = [p0, p1, p2, p3]
    var idxA = 0
    var idxB = 1
    var maxDist = ssColorDistance(pixels[0], pixels[1])
    for i in 0..<4 {
        for j in (i + 1)..<4 {
            let d = ssColorDistance(pixels[i], pixels[j])
            if d > maxDist {
                idxA = i
                idxB = j
                maxDist = d
            }
        }
    }
    let candA = pixels[idxA]
    let candB = pixels[idxB]
    let dark: RGBA
    let light: RGBA
    if ssLuminance(candA) <= ssLuminance(candB) {
        dark = candA
        light = candB
    } else {
        dark = candB
        light = candA
    }

    var bits = 0
    let bitValues = [8, 4, 2, 1]
    for i in 0..<4 {
        if ssColorDistance(pixels[i], dark) <= ssColorDistance(pixels[i], light) {
            bits |= bitValues[i]
        }
    }

    if bits == 0 {
        return (32, dark, ssAverageRGBA(p0, p1, p2, p3))
    } else if bits == 15 {
        return (superSampleQuadrantChars[15], ssAverageRGBA(p0, p1, p2, p3), light)
    } else {
        return (superSampleQuadrantChars[bits], dark, light)
    }
}

@inline(__always)
private func readLEFloat32(_ bytes: [UInt8], at offset: Int) -> Float {
    let bits = UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16)
        | (UInt32(bytes[offset + 3]) << 24)
    return Float(bitPattern: bits)
}

@inline(__always)
private func readLEUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16)
        | (UInt32(bytes[offset + 3]) << 24)
}

@inline(__always)
private func grayscaleCharForIntensity(_ intensity: Float) -> UInt32 {
    if intensity < 0.01 { return defaultSpaceChar }
    let clamped = max(Float(0.0), min(Float(1.0), intensity))
    let index = min(grayscaleRampASCII.count - 1, Int(clamped * Float(grayscaleRampASCII.count - 1)))
    return UInt32(grayscaleRampASCII[index])
}

@inline(__always)
private func scaleColorAlpha(_ color: RGBA, factor: Float) -> RGBA {
    let clamped = factor.isFinite ? max(Float(0.0), min(Float(1.0), factor)) : 0.0
    let opacityByte = UInt32((clamped * 255.0).rounded(.toNearestOrAwayFromZero))
    let (_, _, _, a) = color.toInts()
    let newA = UInt8((UInt32(a) * opacityByte + 127) / 255)
    return RGBA(b0: color.b0, b1: color.b1, b2: color.b2, b3: (color.b3 & 0xFF00) | UInt16(newA))
}

@inline(__always)
private func gridIntersectionChar(
    _ borderChars: [UInt32],
    hasUp: Bool,
    hasDown: Bool,
    hasLeft: Bool,
    hasRight: Bool
) -> UInt32 {
    if hasUp && hasDown && hasLeft && hasRight { return borderChars[BorderCharIndex.cross.rawValue] }
    if !hasUp && hasDown && !hasLeft && hasRight { return borderChars[BorderCharIndex.topLeft.rawValue] }
    if !hasUp && hasDown && hasLeft && !hasRight { return borderChars[BorderCharIndex.topRight.rawValue] }
    if hasUp && !hasDown && !hasLeft && hasRight { return borderChars[BorderCharIndex.bottomLeft.rawValue] }
    if hasUp && !hasDown && hasLeft && !hasRight { return borderChars[BorderCharIndex.bottomRight.rawValue] }
    if hasUp && hasDown && !hasLeft && hasRight { return borderChars[BorderCharIndex.leftT.rawValue] }
    if hasUp && hasDown && hasLeft && !hasRight { return borderChars[BorderCharIndex.rightT.rawValue] }
    if !hasUp && hasDown && hasLeft && hasRight { return borderChars[BorderCharIndex.topT.rawValue] }
    if hasUp && !hasDown && hasLeft && hasRight { return borderChars[BorderCharIndex.bottomT.rawValue] }
    if (hasLeft || hasRight) && !hasUp && !hasDown { return borderChars[BorderCharIndex.horizontal.rawValue] }
    if (hasUp || hasDown) && !hasLeft && !hasRight { return borderChars[BorderCharIndex.vertical.rawValue] }
    return borderChars[BorderCharIndex.cross.rawValue]
}

@inline(__always)
private func isSingleWidthGridScalar(_ cp: UInt32) -> Bool {
    if cp == 0 { return true }
    if (cp >= 32 && cp <= 126) || (cp >= 0x2500 && cp <= 0x257F) { return true }
    if cp > 0x10FFFF { return false }
    return eastAsianWidth(cp) == 1
}

private struct CoreChunkUTF8Span {
    let utf8Start: Int
    let utf8End: Int
    let chunk: TextChunk
}

public extension OptimizedBuffer {
    /// Returns the cell at `(x, y)`, or `nil` if out of bounds.
    func getCell(x: Int, y: Int) -> TerminalCell? {
        cell(atX: x, y: y)
    }

    /// Returns the foreground color at `(x, y)`, or `nil` if out of bounds.
    func getFgColor(x: Int, y: Int) -> RGBA? {
        guard x >= 0 && x < width && y >= 0 && y < height else { return nil }
        return fg[y * width + x]
    }

    /// Returns the background color at `(x, y)`, or `nil` if out of bounds.
    func getBgColor(x: Int, y: Int) -> RGBA? {
        guard x >= 0 && x < width && y >= 0 && y < height else { return nil }
        return bg[y * width + x]
    }

    /// Raw packed cell planes view matching `core/src/buffer.ts#OptimizedBuffer.buffers`.
    // parity: core/src/buffer.ts#OptimizedBuffer.buffers [status=adapted hash=b8e3d4959beb]
    var buffers: BufferAccess {
        precondition(!isDestroyed, "Buffer \(id) is destroyed")
        return BufferAccess(buffer: self, generation: 1)
    }

    /// Borrows a scoped `BufferAccess` snapshot for a synchronous callback.
    // parity: core/src/buffer.ts#OptimizedBuffer.withBuffers [status=implemented hash=b37a117ab52a]
    func withBuffers<T>(_ callback: (BufferAccess) throws -> T) throws -> T {
        guard !isDestroyed else {
            throw BufferAccessError.bufferDestroyed
        }
        let access = BufferAccess(buffer: self, generation: 1)
        return try callback(access)
    }

    /// Creates a recording-style `OptimizedBuffer` sized to `(width, height)`.
    // parity: core/src/buffer.ts#OptimizedBuffer.fromRecorder [status=adapted hash=e9797ac20b65]
    static func fromRecorder(
        width: Int,
        height: Int,
        widthMethod: WidthMethod = .unicode,
        id: String = "scene-recording",
        graphemePool: GraphemePool = GraphemePool(),
        linkPool: LinkPool = LinkPool()
    ) -> OptimizedBuffer {
        OptimizedBuffer(
            width: width,
            height: height,
            widthMethod: widthMethod,
            id: id,
            graphemePool: graphemePool,
            linkPool: linkPool
        )
    }

    /// Returns the `current` or `next` framebuffer plane owned by `session`.
    // parity: core/src/buffer.ts#OptimizedBuffer.fromSession [status=adapted hash=4e0443e48df0]
    static func fromSession(
        _ session: SessionBuffer,
        which: SessionBufferKind = .next
    ) -> OptimizedBuffer {
        session.buffer(for: which)
    }

    /// Renders a `TextBufferView` (wrapped virtual lines, styled chunks, highlights via `SyntaxStyle`,
    /// alignment, tab indicators, and selection) into `self` starting at `(x, y)`.
    // parity: core/src/buffer.ts#OptimizedBuffer.drawTextBuffer [status=implemented hash=691e6221454c]
    func drawTextBuffer(_ textBufferView: TextBufferView, x: Int, y: Int) {
        guard !isDestroyed && !textBufferView.isDestroyed && !textBufferView.textBuffer.isDestroyed else { return }

        let textBuffer = textBufferView.textBuffer
        let vp = textBufferView.viewport
        let vpX = vp?.x ?? 0
        let effectiveWidth = vp?.width ?? max(0, width - x)
        let effectiveHeight = vp?.height ?? max(0, height - y)
        guard effectiveWidth > 0 && effectiveHeight > 0 else { return }

        let defaultFg = textBuffer.defaultFg ?? RGBA.fromValues(1, 1, 1, 1)
        let defaultBg = textBuffer.defaultBg ?? RGBA.fromValues(0, 0, 0, 0)
        let defaultAttrs = textBuffer.defaultAttributes ?? TextAttributes.none
        let syntaxStyle = textBuffer.getSyntaxStyle()

        pushScissorRect(x: x, y: y, width: effectiveWidth, height: effectiveHeight)
        defer { popScissorRect() }

        if defaultBg.a > 0 {
            fillRect(x: x, y: y, width: effectiveWidth, height: effectiveHeight, bg: defaultBg)
        }

        let visibleLines = textBufferView.visibleVirtualLines()
        guard !visibleLines.isEmpty else { return }

        let chunks = textBuffer.styledChunks
        var chunkSpans: [CoreChunkUTF8Span] = []
        chunkSpans.reserveCapacity(chunks.count)
        var byteCursor = 0
        for chunk in chunks {
            let len = chunk.text.utf8.count
            let end = byteCursor + len
            if len > 0 {
                chunkSpans.append(CoreChunkUTF8Span(utf8Start: byteCursor, utf8End: end, chunk: chunk))
            }
            byteCursor = end
        }

        let selection = textBufferView.getSelection()
        let selectionBg = textBufferView.selectionBgColor
        let selectionFg = textBufferView.selectionFgColor
        let tabWidth = textBuffer.getTabWidth()
        let tabIndicator = textBufferView.tabIndicator
        let tabIndicatorColor = textBufferView.tabIndicatorColor
        let textAlign = textBufferView.textAlign
        let firstLineOffset = textBufferView.firstLineOffset

        var chunkSpanHint = 0

        for (rowIdx, vline) in visibleLines.enumerated() {
            if rowIdx >= effectiveHeight { break }
            let destY = y + rowIdx
            if destY < 0 || destY >= height { continue }

            let indent = (vline.sourceLine == 0 && vline.wrapIndex == 0) ? firstLineOffset : 0
            let alignPad = alignmentPadCols(
                alignment: textAlign,
                viewportWidth: effectiveWidth,
                lineWidthCols: vline.widthCols + indent
            )
            let baseX = x + alignPad + indent - vpX

            let lineUTF8Start = vline.utf8Range.lowerBound
            while chunkSpanHint < chunkSpans.count && chunkSpans[chunkSpanHint].utf8End <= lineUTF8Start {
                chunkSpanHint += 1
            }
            if chunkSpanHint > 0 && chunkSpanHint < chunkSpans.count && chunkSpans[chunkSpanHint].utf8Start > lineUTF8Start {
                chunkSpanHint = 0
                while chunkSpanHint < chunkSpans.count && chunkSpans[chunkSpanHint].utf8End <= lineUTF8Start {
                    chunkSpanHint += 1
                }
            }

            let lineHighlights = syntaxStyle != nil ? textBuffer.getLineHighlights(vline.sourceLine) : []
            var localChunkIdx = chunkSpanHint
            var byteOffsetInDoc = lineUTF8Start
            var colInLine = 0
            var docCellOffset = vline.documentCellOffset

            for ch in vline.text {
                let chBytes = ch.utf8.count
                while localChunkIdx < chunkSpans.count && chunkSpans[localChunkIdx].utf8End <= byteOffsetInDoc {
                    localChunkIdx += 1
                }
                let activeChunk: TextChunk? = (localChunkIdx < chunkSpans.count
                    && chunkSpans[localChunkIdx].utf8Start <= byteOffsetInDoc
                    && byteOffsetInDoc < chunkSpans[localChunkIdx].utf8End)
                    ? chunkSpans[localChunkIdx].chunk
                    : nil

                var fgColor = activeChunk?.fg ?? defaultFg
                var bgColor = activeChunk?.bg ?? defaultBg
                var attrs = activeChunk?.attributes ?? defaultAttrs

                if let syntaxStyle, !lineHighlights.isEmpty {
                    let logicalCol = vline.sourceColStart + colInLine
                    var bestPriority = Int.min
                    var matched: StyleDefinition? = nil
                    for hl in lineHighlights where logicalCol >= hl.start && logicalCol < hl.end {
                        let prio = hl.priority ?? 0
                        if prio >= bestPriority, let def = syntaxStyle.resolveById(hl.styleId) {
                            bestPriority = prio
                            matched = def
                        }
                    }
                    if let def = matched {
                        if let hFg = def.fg { fgColor = hFg }
                        if let hBg = def.bg { bgColor = hBg }
                        let hAttrs = createTextAttributes(
                            bold: def.bold ?? false,
                            italic: def.italic ?? false,
                            underline: def.underline ?? false,
                            dim: def.dim ?? false,
                            strikethrough: def.strikethrough ?? false
                        )
                        attrs |= hAttrs
                    }
                }

                var retainedLinkId: UInt32? = nil
                if let url = activeChunk?.link?.url, let linkId = try? linkPool.acquire(url) {
                    retainedLinkId = linkId
                    attrs = attributesWithLink(attrs, linkId: linkId)
                }
                defer {
                    if let lid = retainedLinkId {
                        try? linkPool.decref(lid)
                    }
                }

                let chStr = String(ch)
                let cellWidth: Int
                if ch == "\t" {
                    cellWidth = max(1, tabWidth)
                } else {
                    cellWidth = Int(
                        calculateTextWidth(
                            chStr,
                            tabWidth: UInt8(clamping: tabWidth),
                            controlDisplay: .hidden,
                            widthMethod: widthMethod
                        )
                    )
                }

                let isSelected: Bool
                if let sel = selection {
                    isSelected = docCellOffset >= sel.start && docCellOffset < sel.end
                } else {
                    isSelected = false
                }

                let finalFg: RGBA
                let finalBg: RGBA
                if isSelected {
                    if let sBg = selectionBg {
                        finalBg = sBg
                        finalFg = selectionFg ?? fgColor
                    } else {
                        finalBg = fgColor
                        finalFg = bgColor.a > 0 ? bgColor : RGBA.fromValues(0, 0, 0, 1)
                    }
                } else {
                    finalFg = fgColor
                    finalBg = bgColor
                }

                let destX = baseX + colInLine
                if ch == "\t" {
                    for t in 0..<cellWidth {
                        let cx = destX + t
                        if cx >= x && cx < x + effectiveWidth && cx >= 0 && cx < width {
                            if t == 0, let ind = tabIndicator {
                                let indFg = isSelected ? finalFg : (tabIndicatorColor ?? finalFg)
                                setCellWithAlphaBlending(
                                    x: cx,
                                    y: destY,
                                    char: String(ind),
                                    fg: indFg,
                                    bg: finalBg,
                                    attributes: attrs
                                )
                            } else {
                                setCellWithAlphaBlending(
                                    x: cx,
                                    y: destY,
                                    char: " ",
                                    fg: finalFg,
                                    bg: finalBg,
                                    attributes: attrs
                                )
                            }
                        }
                    }
                } else if cellWidth > 0 {
                    if destX >= x && destX + cellWidth <= x + effectiveWidth && destX >= 0 && destX + cellWidth <= width {
                        setCellWithAlphaBlending(
                            x: destX,
                            y: destY,
                            char: chStr,
                            fg: finalFg,
                            bg: finalBg,
                            attributes: attrs
                        )
                    }
                }

                colInLine += cellWidth
                docCellOffset += cellWidth
                byteOffsetInDoc += chBytes
            }
        }
    }

    /// Renders an `EditorView` (text content or placeholder chunks when empty) into `self` at `(x, y)`.
    // parity: core/src/buffer.ts#OptimizedBuffer.drawEditorView [status=implemented hash=b1c718ba9d9b]
    func drawEditorView(_ editorView: EditorView, x: Int, y: Int) {
        guard !isDestroyed && !editorView.isDestroyed && !editorView.editBuffer.isDestroyed else { return }

        let vp = editorView.getViewport()
        let isEmpty = editorView.editBuffer.getText().isEmpty
        if isEmpty && !editorView.placeholderChunks.isEmpty {
            let effW = vp.width > 0 ? vp.width : max(0, width - x)
            let effH = vp.height > 0 ? vp.height : max(0, height - y)
            guard effW > 0 && effH > 0 else { return }

            pushScissorRect(x: x, y: y, width: effW, height: effH)
            defer { popScissorRect() }

            if let defaultBg = editorView.editBuffer.textBuffer.defaultBg, defaultBg.a > 0 {
                fillRect(x: x, y: y, width: effW, height: effH, bg: defaultBg)
            }
            drawStyledText(
                StyledText(editorView.placeholderChunks),
                x: x,
                y: y,
                defaultFg: editorView.editBuffer.textBuffer.defaultFg ?? RGBA.fromInts(128, 128, 128, 255),
                defaultBg: editorView.editBuffer.textBuffer.defaultBg,
                maxWidth: effW
            )
            return
        }

        drawTextBuffer(editorView.textBufferView, x: x, y: y)
    }

    /// Draws 2×2 supersampled RGBA8/BGRA8 pixel data into terminal cells using Unicode quadrant blocks,
    /// matching `native/src/buffer.zig#drawSuperSampleBuffer`.
    // parity: core/src/buffer.ts#OptimizedBuffer.drawSuperSampleBuffer [status=implemented hash=95e0e6c22ab7]
    func drawSuperSampleBuffer(
        x posX: Int,
        y posY: Int,
        pixelData: [UInt8],
        pixelDataLength: Int? = nil,
        format: SuperSamplePixelFormat = .rgba8unorm,
        alignedBytesPerRow: Int
    ) {
        guard !isDestroyed else { return }
        let len = min(pixelDataLength ?? pixelData.count, pixelData.count)
        guard alignedBytesPerRow > 0, alignedBytesPerRow % 4 == 0, len > 0, len % alignedBytesPerRow == 0 else {
            return
        }

        let bytesPerPixel = 4
        let isBGRA = (format == .bgra8unorm)
        let sourceWidth = alignedBytesPerRow / bytesPerPixel
        let sourceHeight = len / alignedBytesPerRow
        let sourceCellsX = (sourceWidth + 1) / 2
        let sourceCellsY = (sourceHeight + 1) / 2

        let startX = max(0, posX)
        let startY = max(0, posY)
        let endX = min(width, posX + sourceCellsX)
        let endY = min(height, posY + sourceCellsY)
        guard startX < endX && startY < endY else { return }

        let missing = RGBA.fromInts(255, 0, 255, 0)

        @inline(__always)
        func pixelAt(_ idx: Int) -> RGBA {
            guard idx >= 0 && idx + 3 < len else { return missing }
            if isBGRA {
                return RGBA.fromInts(
                    Int(pixelData[idx + 2]),
                    Int(pixelData[idx + 1]),
                    Int(pixelData[idx]),
                    Int(pixelData[idx + 3])
                )
            } else {
                return RGBA.fromInts(
                    Int(pixelData[idx]),
                    Int(pixelData[idx + 1]),
                    Int(pixelData[idx + 2]),
                    Int(pixelData[idx + 3])
                )
            }
        }

        for yCell in startY..<endY {
            for xCell in startX..<endX {
                guard isPointInScissor(x: xCell, y: yCell) else { continue }
                let renderX = (xCell - posX) * 2
                let renderY = (yCell - posY) * 2

                let tlIndex = renderY * alignedBytesPerRow + renderX * bytesPerPixel
                let trIndex = tlIndex + bytesPerPixel
                let blIndex = (renderY + 1) * alignedBytesPerRow + renderX * bytesPerPixel
                let brIndex = blIndex + bytesPerPixel

                let p0 = pixelAt(tlIndex)
                let p1 = (renderX + 1 < sourceWidth) ? pixelAt(trIndex) : missing
                let p2 = pixelAt(blIndex)
                let p3 = (renderX + 1 < sourceWidth) ? pixelAt(brIndex) : missing

                let result = ssRenderQuadrantBlock(p0, p1, p2, p3)
                setCellWithAlphaBlending(
                    x: xCell,
                    y: yCell,
                    cell: TerminalCell(
                        scalar: result.char,
                        foreground: result.fg,
                        background: result.bg,
                        attributes: TextAttributes.none
                    )
                )
            }
        }
    }

    /// Draws a `NativeImage` (or source subregion) into `self` at `(x, y, width, height)`.
    // parity: core/src/buffer.ts#OptimizedBuffer.drawImage [status=adapted hash=55049f60dc17]
    @discardableResult
    func drawImage(
        _ image: NativeImage,
        x: Int,
        y: Int,
        width destWidth: Int,
        height destHeight: Int,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        sourceX: Int = 0,
        sourceY: Int = 0,
        sourceWidth: Int? = nil,
        sourceHeight: Int? = nil,
        protocol renderProtocol: String = "auto"
    ) -> Bool {
        guard !isDestroyed && !image.isDisposed else { return false }
        guard destWidth >= 1 && destHeight >= 1 else { return false }
        guard pixelWidth >= 0 && pixelHeight >= 0 else { return false }
        let srcW = sourceWidth ?? image.width
        let srcH = sourceHeight ?? image.height
        guard sourceX >= 0 && sourceY >= 0 && srcW >= 1 && srcH >= 1 else { return false }
        guard sourceX + srcW <= image.width && sourceY + srcH <= image.height else { return false }

        _ = renderProtocol

        let targetImage: NativeImage
        let ownedCrop: Bool
        if sourceX == 0 && sourceY == 0 && srcW == image.width && srcH == image.height {
            targetImage = image
            ownedCrop = false
        } else if let cropped = try? image.extract(
            ExtractOptions(left: sourceX, top: sourceY, width: srcW, height: srcH)
        ) {
            targetImage = cropped
            ownedCrop = true
        } else {
            return false
        }
        defer {
            if ownedCrop {
                targetImage.dispose()
            }
        }

        ImageBufferRasterizer.renderHalfBlocks(
            targetImage,
            into: self,
            x: x,
            y: y,
            width: destWidth,
            height: destHeight,
            mode: .fill
        )
        return true
    }

    /// Draws pre-computed 48-byte `CellResult` records (`bg(4×f32) + fg(4×f32) + char(u32) + 12B pad`)
    /// matching `native/src/buffer.zig#drawPackedBuffer`.
    // parity: core/src/buffer.ts#OptimizedBuffer.drawPackedBuffer [status=implemented hash=23071322a727]
    func drawPackedBuffer(
        _ data: [UInt8],
        dataLen: Int? = nil,
        posX: Int,
        posY: Int,
        terminalWidthCells: Int,
        terminalHeightCells: Int
    ) {
        guard !isDestroyed else { return }
        let effectiveLen = min(dataLen ?? data.count, data.count)
        guard effectiveLen > 0 && terminalWidthCells > 0 && terminalHeightCells > 0 else { return }

        let cellResultSize = 48
        let (cellCount, mulOverflow) = terminalWidthCells.multipliedReportingOverflow(by: terminalHeightCells)
        guard !mulOverflow else { return }
        let (required, byteOverflow) = cellCount.multipliedReportingOverflow(by: cellResultSize)
        guard !byteOverflow && effectiveLen >= required && effectiveLen % cellResultSize == 0 else { return }

        let skipX = min(terminalWidthCells, max(0, -posX))
        let skipY = min(terminalHeightCells, max(0, -posY))
        let startX = max(0, posX)
        let startY = max(0, posY)
        guard startX < width && startY < height else { return }

        let drawW = min(terminalWidthCells - skipX, width - startX)
        let drawH = min(terminalHeightCells - skipY, height - startY)
        guard drawW > 0 && drawH > 0 else { return }

        let blockChar: UInt32 = 0x2588

        for y in 0..<drawH {
            for x in 0..<drawW {
                let cellX = startX + x
                let cellY = startY + y
                guard isPointInScissor(x: cellX, y: cellY) else { continue }

                let offset = ((skipY + y) * terminalWidthCells + (skipX + x)) * cellResultSize
                let bgR = readLEFloat32(data, at: offset + 0)
                let bgG = readLEFloat32(data, at: offset + 4)
                let bgB = readLEFloat32(data, at: offset + 8)
                let bgA = readLEFloat32(data, at: offset + 12)
                let fgR = readLEFloat32(data, at: offset + 16)
                let fgG = readLEFloat32(data, at: offset + 20)
                let fgB = readLEFloat32(data, at: offset + 24)
                let fgA = readLEFloat32(data, at: offset + 28)

                let bgColor = RGBA.fromValues(Double(bgR), Double(bgG), Double(bgB), Double(bgA))
                let fgColor = RGBA.fromValues(Double(fgR), Double(fgG), Double(fgB), Double(fgA))

                var ch = readLEUInt32(data, at: offset + 32)
                if !isScalar(ch) || ch == 0 {
                    ch = defaultSpaceChar
                } else if ch < 32 || (ch > 126 && ch < 0x2580) || !isSingleWidthGridScalar(ch) {
                    ch = blockChar
                }

                setCellWithAlphaBlending(
                    x: cellX,
                    y: cellY,
                    cell: TerminalCell(
                        scalar: ch,
                        foreground: fgColor,
                        background: bgColor,
                        attributes: TextAttributes.none
                    )
                )
            }
        }
    }

    private func drawGrayscaleBufferCore(
        posX: Int,
        posY: Int,
        intensities: [Float],
        srcWidth: Int,
        srcHeight: Int,
        fg: RGBA?,
        bg: RGBA?,
        supersampled: Bool
    ) {
        guard !isDestroyed && srcWidth > 0 && srcHeight > 0 else { return }
        let (totalSamples, overflow) = srcWidth.multipliedReportingOverflow(by: srcHeight)
        guard !overflow && intensities.count >= totalSamples else { return }

        let resolvedBg = bg ?? RGBA.fromInts(0, 0, 0, 0)
        let resolvedBaseFg = fg ?? RGBA.fromInts(255, 255, 255, 255)
        let scale = supersampled ? 2 : 1
        let termWidth = srcWidth / scale
        let termHeight = srcHeight / scale
        guard termWidth > 0 && termHeight > 0 else { return }
        guard posX < width && posY < height else { return }

        let startX = posX < 0 ? -posX : 0
        let startY = posY < 0 ? -posY : 0
        let destStartX = max(0, posX)
        let destStartY = max(0, posY)
        guard startX < termWidth && startY < termHeight else { return }

        let visibleWidth = min(termWidth - startX, width - destStartX)
        let visibleHeight = min(termHeight - startY, height - destStartY)
        guard visibleWidth > 0 && visibleHeight > 0 else { return }

        for y in 0..<visibleHeight {
            for x in 0..<visibleWidth {
                let destX = destStartX + x
                let destY = destStartY + y
                guard isPointInScissor(x: destX, y: destY) else { continue }

                let idx = ((startY + y) * srcWidth + (startX + x)) * scale
                let intensity: Float
                if supersampled {
                    let s0 = intensities[idx]
                    let s1 = intensities[idx + 1]
                    let s2 = intensities[idx + srcWidth]
                    let s3 = intensities[idx + srcWidth + 1]
                    guard s0.isFinite && s1.isFinite && s2.isFinite && s3.isFinite else { continue }
                    let sum = (s0 + s1 + s2 + s3) / 4.0
                    intensity = sum.isFinite ? sum : (s0 / 4.0 + s1 / 4.0 + s2 / 4.0 + s3 / 4.0)
                } else {
                    let s0 = intensities[idx]
                    guard s0.isFinite else { continue }
                    intensity = s0
                }

                if intensity < 0.01 { continue }
                let ch = grayscaleCharForIntensity(intensity)
                let gray = max(Float(0.0), min(Float(1.0), intensity))
                let cellFg = scaleColorAlpha(resolvedBaseFg, factor: gray)

                setCellWithAlphaBlending(
                    x: destX,
                    y: destY,
                    cell: TerminalCell(
                        scalar: ch,
                        foreground: cellFg,
                        background: resolvedBg,
                        attributes: TextAttributes.none
                    )
                )
            }
        }
    }

    /// Draws an ASCII grayscale intensity map (`[0, 1]`) directly into `self`,
    /// matching `native/src/buffer.zig#drawGrayscaleBuffer`.
    // parity: core/src/buffer.ts#OptimizedBuffer.drawGrayscaleBuffer [status=implemented hash=0bffdfd35dba]
    func drawGrayscaleBuffer(
        posX: Int,
        posY: Int,
        intensities: [Float],
        srcWidth: Int,
        srcHeight: Int,
        fg: RGBA? = nil,
        bg: RGBA? = nil
    ) {
        drawGrayscaleBufferCore(
            posX: posX,
            posY: posY,
            intensities: intensities,
            srcWidth: srcWidth,
            srcHeight: srcHeight,
            fg: fg,
            bg: bg,
            supersampled: false
        )
    }

    /// Draws a 2×2 supersampled grayscale intensity map into `self`,
    /// matching `native/src/buffer.zig#drawGrayscaleBufferSupersampled`.
    // parity: core/src/buffer.ts#OptimizedBuffer.drawGrayscaleBufferSupersampled [status=implemented hash=6921d84e6558]
    func drawGrayscaleBufferSupersampled(
        posX: Int,
        posY: Int,
        intensities: [Float],
        srcWidth: Int,
        srcHeight: Int,
        fg: RGBA? = nil,
        bg: RGBA? = nil
    ) {
        drawGrayscaleBufferCore(
            posX: posX,
            posY: posY,
            intensities: intensities,
            srcWidth: srcWidth,
            srcHeight: srcHeight,
            fg: fg,
            bg: bg,
            supersampled: true
        )
    }

    /// Encodes `text` into display-cluster glyphs backed by `graphemePool` with opaque `> 0xFFFFFFFF`
    /// tokens for multi-scalar / wide clusters, matching `core/src/buffer.ts#OptimizedBuffer.encodeUnicode`.
    // parity: core/src/buffer.ts#OptimizedBuffer.encodeUnicode [status=implemented hash=33338f2e06ab]
    func encodeUnicode(_ text: String) -> EncodedUnicode {
        precondition(!isDestroyed, "Buffer \(id) is destroyed")
        let bytes = Array(text.utf8)
        let spans = segmentGraphemeClusters(
            bytes,
            tabWidth: 2,
            controlDisplay: .hidden,
            widthMethod: widthMethod
        )

        var glyphs: [EncodedUnicode.Glyph] = []
        glyphs.reserveCapacity(spans.count)
        var pooledEntries: [(glyphIndex: Int, encodedCellChar: UInt32, graphemeId: UInt32)] = []

        for span in spans {
            let w = Int(span.width)
            if w == 0 { continue }
            let clusterBytes = Array(bytes[span.byteStart..<span.byteEnd])
            if !isPrintableGlyph(clusterBytes, width: span.width) {
                continue
            }

            if w == 1 && clusterBytes.count == 1 {
                glyphs.append(EncodedUnicode.Glyph(width: 1, char: UInt64(clusterBytes[0])))
            } else if w == 1 && span.byteLen <= 4 && isValidUtf8(clusterBytes),
                      let decoded = Optional(String(decoding: clusterBytes, as: UTF8.self)),
                      decoded.unicodeScalars.count == 1,
                      let scalar = decoded.unicodeScalars.first
            {
                glyphs.append(EncodedUnicode.Glyph(width: 1, char: UInt64(scalar.value)))
            } else if let gid = try? graphemePool.acquire(clusterBytes) {
                let packed = packGraphemeStart(gid: gid, totalWidth: span.width)
                let glyphIndex = glyphs.count
                glyphs.append(EncodedUnicode.Glyph(width: w, char: 0))
                pooledEntries.append((glyphIndex: glyphIndex, encodedCellChar: packed, graphemeId: gid))
            } else {
                glyphs.append(EncodedUnicode.Glyph(width: 1, char: UInt64(defaultSpaceChar)))
            }
        }

        let (allocId, tokens) = BufferUnicodeRegistry.shared.allocate(
            for: self,
            entries: pooledEntries.map { ($0.encodedCellChar, $0.graphemeId) }
        )
        for (i, item) in pooledEntries.enumerated() {
            glyphs[item.glyphIndex].char = tokens[i]
        }

        return EncodedUnicode(data: glyphs, allocationId: allocId)
    }

    /// Releases pooled grapheme tokens acquired by `encodeUnicode(_:)`.
    // parity: core/src/buffer.ts#OptimizedBuffer.freeUnicode [status=implemented hash=d579c0592594]
    func freeUnicode(_ encoded: EncodedUnicode) {
        precondition(!isDestroyed, "Buffer \(id) is destroyed")
        guard encoded.allocationId != 0,
              let gids = BufferUnicodeRegistry.shared.release(allocationId: encoded.allocationId, for: self)
        else {
            return
        }
        for gid in gids {
            try? graphemePool.decref(gid)
        }
    }

    /// Draws a single glyph returned by `encodeUnicode(_:)` (supporting both direct scalars and opaque tokens).
    func drawChar(
        _ char: UInt64,
        x: Int,
        y: Int,
        fg: RGBA,
        bg: RGBA,
        attributes: UInt32 = TextAttributes.none
    ) {
        precondition(!isDestroyed, "Buffer \(id) is destroyed")
        if char > UInt64(UInt32.max) {
            guard let packed = BufferUnicodeRegistry.shared.lookup(token: char, for: self) else {
                return
            }
            drawChar(packed, x: x, y: y, fg: fg, bg: bg, attributes: attributes)
            return
        }
        drawChar(UInt32(char), x: x, y: y, fg: fg, bg: bg, attributes: attributes)
    }

    /// Draws a complete border grid with intersections, horizontal rules, and vertical rules
    /// matching `native/src/buffer.zig#drawGrid`.
    // parity: core/src/buffer.ts#OptimizedBuffer.drawGrid [status=implemented hash=7ac9e126cf46]
    func drawGrid(_ options: NativeBufferGrid) {
        guard !isDestroyed else { return }
        guard options.borderChars.count >= 11 else { return }
        guard options.columnOffsets.count >= 2 && options.rowOffsets.count >= 2 else { return }
        guard options.drawInner || options.drawOuter else { return }

        let columnCount = options.columnOffsets.count - 1
        let rowCount = options.rowOffsets.count - 1
        let borderChars = options.borderChars
        let borderFg = options.borderFg
        let borderBg = options.borderBg
        let hChar = borderChars[BorderCharIndex.horizontal.rawValue]
        let vChar = borderChars[BorderCharIndex.vertical.rawValue]

        var firstVisibleCol = 0
        while firstVisibleCol <= columnCount && Int(options.columnOffsets[firstVisibleCol]) < 0 {
            firstVisibleCol += 1
        }

        @inline(__always)
        func writeGridCell(_ gx: Int, _ gy: Int, _ scalar: UInt32) {
            setCellWithAlphaBlending(
                x: gx,
                y: gy,
                cell: TerminalCell(
                    scalar: scalar,
                    foreground: borderFg,
                    background: borderBg,
                    attributes: TextAttributes.none
                )
            )
        }

        for rowIdx in 0...rowCount {
            let isOuterRow = (rowIdx == 0 || rowIdx == rowCount)
            let shouldDrawHorizontal = isOuterRow ? options.drawOuter : options.drawInner
            let borderY = Int(options.rowOffsets[rowIdx])
            if borderY >= height { break }

            if shouldDrawHorizontal && borderY >= 0 {
                // Draw intersections
                var colBorderIdx = firstVisibleCol
                while colBorderIdx <= columnCount {
                    let isOuterCol = (colBorderIdx == 0 || colBorderIdx == columnCount)
                    let shouldDrawVertical = isOuterCol ? options.drawOuter : options.drawInner
                    if shouldDrawVertical {
                        let bx = Int(options.columnOffsets[colBorderIdx])
                        if bx >= width { break }
                        if bx >= 0 {
                            let hasUp = rowIdx > 0 && shouldDrawVertical
                            let hasDown = rowIdx < rowCount && shouldDrawVertical
                            let hasLeft = colBorderIdx > 0
                            let hasRight = colBorderIdx < columnCount
                            let intersection = gridIntersectionChar(
                                borderChars,
                                hasUp: hasUp,
                                hasDown: hasDown,
                                hasLeft: hasLeft,
                                hasRight: hasRight
                            )
                            writeGridCell(bx, borderY, intersection)
                        }
                    }
                    colBorderIdx += 1
                }

                // Draw horizontal spans
                var colIdx = max(0, firstVisibleCol - 1)
                while colIdx < columnCount {
                    let hasBoundaryAfter = (colIdx < columnCount - 1) ? options.drawInner : options.drawOuter
                    let boundaryPadding = hasBoundaryAfter ? 0 : 1
                    let startX = Int(options.columnOffsets[colIdx]) + 1
                    let endX = Int(options.columnOffsets[colIdx + 1]) + boundaryPadding

                    if startX >= width { break }
                    if endX > 0 {
                        let clampedStart = max(0, startX)
                        let clampedEnd = min(width, endX)
                        if clampedStart < clampedEnd {
                            for x in clampedStart..<clampedEnd {
                                writeGridCell(x, borderY, hChar)
                            }
                        }
                    }
                    colIdx += 1
                }
            }

            if rowIdx >= rowCount { break }

            // Draw vertical borders for content lines of this row
            let hasRowBoundaryAfter = (rowIdx < rowCount - 1) ? options.drawInner : options.drawOuter
            let rowBoundaryPadding = hasRowBoundaryAfter ? 0 : 1
            let contentStartY = max(0, borderY + 1)
            let contentEndY = min(height, Int(options.rowOffsets[rowIdx + 1]) + rowBoundaryPadding)
            if contentStartY < contentEndY {
                for cy in contentStartY..<contentEndY {
                    var colBorderIdx = firstVisibleCol
                    while colBorderIdx <= columnCount {
                        let isOuterCol = (colBorderIdx == 0 || colBorderIdx == columnCount)
                        let shouldDrawVertical = isOuterCol ? options.drawOuter : options.drawInner
                        if shouldDrawVertical {
                            let bx = Int(options.columnOffsets[colBorderIdx])
                            if bx >= width { break }
                            if bx >= 0 {
                                writeGridCell(bx, cy, vChar)
                            }
                        }
                        colBorderIdx += 1
                    }
                }
            }
        }
    }
}

// MARK: - TextBuffer & EditBuffer Parity Completions (`core/src/text-buffer.ts`, `core/src/edit-buffer.ts`)

/// Injectable synchronous file reader closure used by `TextBuffer.loadFile(_:reader:)` in pure Swift.
public typealias RuntimeFileReader = @Sendable (String) throws -> [UInt8]

private let defaultRuntimeFileReader = Mutex<RuntimeFileReader?>(nil)

/// Configures the process-wide synchronous file reader used by `TextBuffer.loadFile(_:reader:)`.
public func setRuntimeFileReader(_ reader: RuntimeFileReader?) {
    defaultRuntimeFileReader.withLock { $0 = reader }
}

/// Errors thrown by `TextBuffer.loadFile(_:reader:)`.
public enum TextBufferLoadError: Error, Sendable, CustomStringConvertible {
    case fileReaderUnavailable(path: String)
    case failedToLoad(path: String, cause: any Error)

    public var description: String {
        switch self {
        case .fileReaderUnavailable(let path):
            return "Failed to load file: \(path) (no RuntimeFileReader configured)"
        case .failedToLoad(let path, let cause):
            return "Failed to load file: \(path): \(cause)"
        }
    }
}

private final class TextBufferSyntaxStyleStore: Sendable {
    private struct WeakEntry: @unchecked Sendable {
        weak var buffer: TextBuffer?
        var style: SyntaxStyle
    }

    static let shared = TextBufferSyntaxStyleStore()
    private let entries = Mutex<[ObjectIdentifier: WeakEntry]>([:])

    func set(_ style: SyntaxStyle?, for buffer: TextBuffer) {
        let key = ObjectIdentifier(buffer)
        entries.withLock { map in
            if map.count > 64 {
                map = map.filter { $0.value.buffer != nil }
            }
            if let style {
                map[key] = WeakEntry(buffer: buffer, style: style)
            } else {
                map.removeValue(forKey: key)
            }
        }
    }

    func get(for buffer: TextBuffer) -> SyntaxStyle? {
        let key = ObjectIdentifier(buffer)
        return entries.withLock { map in
            guard let entry = map[key], entry.buffer === buffer else { return nil }
            return entry.style
        }
    }
}

public extension TextBuffer {
    /// Loads UTF-8 text from `path` via the provided `reader` (or globally configured `RuntimeFileReader`).
    // parity: core/src/text-buffer.ts#TextBuffer.loadFile [status=adapted hash=33c3c7a8a0a5]
    func loadFile(_ path: String, reader: RuntimeFileReader? = nil) throws {
        precondition(!isDestroyed, "TextBuffer is destroyed")
        guard let effectiveReader = reader ?? defaultRuntimeFileReader.withLock({ $0 }) else {
            throw TextBufferLoadError.fileReaderUnavailable(path: path)
        }
        let bytes: [UInt8]
        do {
            bytes = try effectiveReader(path)
        } catch {
            throw TextBufferLoadError.failedToLoad(path: path, cause: error)
        }
        setText(String(decoding: bytes, as: UTF8.self))
    }

    /// Attaches or detaches a `SyntaxStyle` used to resolve highlight `styleId`s during rendering.
    // parity: core/src/text-buffer.ts#TextBuffer.setSyntaxStyle [status=implemented hash=ab77d897bfe0]
    func setSyntaxStyle(_ style: SyntaxStyle?) {
        precondition(!isDestroyed, "TextBuffer is destroyed")
        TextBufferSyntaxStyleStore.shared.set(style, for: self)
        if let style {
            syntaxStyleToken = UInt32(truncatingIfNeeded: UInt(bitPattern: ObjectIdentifier(style)))
        } else {
            syntaxStyleToken = nil
        }
    }

    /// Returns the currently attached `SyntaxStyle`, or `nil` if none is set.
    // parity: core/src/text-buffer.ts#TextBuffer.getSyntaxStyle [status=implemented hash=07770f7b1e99]
    func getSyntaxStyle() -> SyntaxStyle? {
        precondition(!isDestroyed, "TextBuffer is destroyed")
        return TextBufferSyntaxStyleStore.shared.get(for: self)
    }
}

public extension EditBuffer {
    /// Attaches or detaches a `SyntaxStyle` on this `EditBuffer`'s backing `TextBuffer`.
    // parity: core/src/edit-buffer.ts#EditBuffer.setSyntaxStyle [status=implemented hash=696aecb81d3e]
    func setSyntaxStyle(_ style: SyntaxStyle?) {
        runMutation {
            textBuffer.setSyntaxStyle(style)
        }
    }

    /// Returns the currently attached `SyntaxStyle`, or `nil` if none is set.
    // parity: core/src/edit-buffer.ts#EditBuffer.getSyntaxStyle [status=implemented hash=07770f7b1e99]
    func getSyntaxStyle() -> SyntaxStyle? {
        precondition(!isDestroyed, "EditBuffer is destroyed")
        return textBuffer.getSyntaxStyle()
    }
}

// MARK: - Renderable Tree Visualization (`core/src/utils.ts`)

/// Lightweight tree-node interface conformed to by `Renderable` for `visualizeRenderableTree`.
public protocol RenderableTreeNode: AnyObject {
    var id: String { get }
    func treeChildren() -> [any RenderableTreeNode]
}

/// Formats and optionally emits a diagnostic box-drawing tree representation of `renderable`,
/// matching `core/src/utils.ts#visualizeRenderableTree`.
// parity: core/src/utils.ts#visualizeRenderableTree [status=implemented hash=99325e3ca672]
@discardableResult
public func visualizeRenderableTree(
    _ renderable: any RenderableTreeNode,
    maxDepth: Int = 10,
    sink: ((String) -> Void)? = nil
) -> String {
    func buildTreeLines(
        _ node: any RenderableTreeNode,
        prefix: String,
        parentPrefix: String,
        isLastChild: Bool,
        depth: Int
    ) -> [String] {
        if depth >= maxDepth {
            return ["\(prefix)\(node.id) ... (max depth reached)"]
        }

        var lines: [String] = ["\(prefix)\(node.id)"]
        let children = node.treeChildren()
        if !children.isEmpty {
            let lastChildIndex = children.count - 1
            for (index, child) in children.enumerated() {
                let childIsLast = (index == lastChildIndex)
                let connector = childIsLast ? "└── " : "├── "
                let childPrefix = parentPrefix + (isLastChild ? "    " : "│   ")
                lines.append(contentsOf: buildTreeLines(
                    child,
                    prefix: childPrefix + connector,
                    parentPrefix: childPrefix,
                    isLastChild: childIsLast,
                    depth: depth + 1
                ))
            }
        }
        return lines
    }

    let output = "Renderable Tree:\n" + buildTreeLines(
        renderable,
        prefix: "",
        parentPrefix: "",
        isLastChild: true,
        depth: 0
    ).joined(separator: "\n")
    sink?(output)
    return output
}
