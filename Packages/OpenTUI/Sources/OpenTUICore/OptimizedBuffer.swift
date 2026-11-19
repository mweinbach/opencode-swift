/// Pure-Swift terminal cell framebuffer with grapheme & hyperlink pooling, Porter-Duff
/// alpha blending, scissor clip rect stack, opacity stack, hit-grid tracking, and drawing
/// primitives matching `packages/native/src/buffer.zig` and `packages/core/src/buffer.ts`.

// MARK: - Supporting Buffer Types

public let defaultSpaceChar: UInt32 = 0x20

// parity: native/src/buffer.zig#BufferError [status=implemented hash=b1e3e969c538]
public enum BufferError: Error, Equatable, Hashable, Sendable {
    case outOfMemory
    case invalidDimensions
    case invalidUnicode
    case bufferTooSmall
    case generationExhausted
}

// parity: native/src/buffer.zig#ClipRect [status=implemented hash=b2424f746999]
public struct ClipRect: Equatable, Hashable, Sendable, Codable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = max(0, width)
        self.height = max(0, height)
    }
}

// parity: native/src/buffer.zig#TextSelection [status=implemented hash=3921d72759c1]
public struct TextSelection: Equatable, Hashable, Sendable {
    public var start: Int
    public var end: Int
    public var bgColor: RGBA?
    public var fgColor: RGBA?

    public init(start: Int, end: Int, bgColor: RGBA? = nil, fgColor: RGBA? = nil) {
        self.start = start
        self.end = end
        self.bgColor = bgColor
        self.fgColor = fgColor
    }
}

// parity: native/src/buffer.zig#TextFit [status=implemented hash=80dad36887a2]
public struct TextFit: Equatable, Hashable, Sendable {
    public var maxWidth: Int
    public var ellipsis: Bool

    public init(maxWidth: Int = 0, ellipsis: Bool = false) {
        self.maxWidth = max(0, maxWidth)
        self.ellipsis = ellipsis
    }
}

// parity: native/src/buffer.zig#BorderCharIndex [status=implemented hash=54a1f8aa7684]
public enum BorderCharIndex: Int, Equatable, Hashable, Sendable {
    case topLeft = 0
    case topRight = 1
    case bottomLeft = 2
    case bottomRight = 3
    case horizontal = 4
    case vertical = 5
    case topT = 6
    case bottomT = 7
    case leftT = 8
    case rightT = 9
    case cross = 10
}

/// Alignment of top/bottom titles rendered on a box border.
public enum BoxTitleAlignment: UInt8, Equatable, Hashable, Sendable, Codable {
    case left = 0
    case center = 1
    case right = 2
}

// parity: core/src/types.ts#TargetChannel [status=implemented hash=f5443927d822]
public enum TargetChannel: UInt8, Equatable, Hashable, Sendable, Codable {
    case fg = 1
    case bg = 2
    case both = 3
}

// parity: core/src/types.ts#CapturedSpan [status=implemented hash=471f125a3629]
public struct CapturedSpan: Equatable, Hashable, Sendable, Codable {
    public var text: String
    public var fg: RGBA
    public var bg: RGBA
    public var attributes: UInt32
    public var width: Int

    public init(text: String, fg: RGBA, bg: RGBA, attributes: UInt32, width: Int) {
        self.text = text
        self.fg = fg
        self.bg = bg
        self.attributes = attributes
        self.width = width
    }
}

// parity: core/src/types.ts#CapturedLine [status=implemented hash=84c8b0fd2fbf]
public struct CapturedLine: Equatable, Hashable, Sendable, Codable {
    public var spans: [CapturedSpan]

    public init(spans: [CapturedSpan]) {
        self.spans = spans
    }
}

/// Declarative options struct for `OptimizedBuffer.drawBox(_:)`.
public struct BoxDrawOptions: Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public var borderStyle: BorderStyle
    public var customBorderChars: [UInt32]?
    public var borderSides: BorderSidesConfig
    public var borderColor: RGBA
    public var backgroundColor: RGBA
    public var titleColor: RGBA?
    public var shouldFill: Bool
    public var title: String?
    public var titleAlignment: BoxTitleAlignment
    public var bottomTitle: String?
    public var bottomTitleAlignment: BoxTitleAlignment

    public init(
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        borderStyle: BorderStyle = .single,
        customBorderChars: [UInt32]? = nil,
        borderSides: BorderSidesConfig = BorderSidesConfig(top: true, right: true, bottom: true, left: true),
        borderColor: RGBA = .defaultForeground(),
        backgroundColor: RGBA = RGBA.fromInts(0, 0, 0, 0),
        titleColor: RGBA? = nil,
        shouldFill: Bool = false,
        title: String? = nil,
        titleAlignment: BoxTitleAlignment = .left,
        bottomTitle: String? = nil,
        bottomTitleAlignment: BoxTitleAlignment = .left
    ) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.borderStyle = borderStyle
        self.customBorderChars = customBorderChars
        self.borderSides = borderSides
        self.borderColor = borderColor
        self.backgroundColor = backgroundColor
        self.titleColor = titleColor
        self.shouldFill = shouldFill
        self.title = title
        self.titleAlignment = titleAlignment
        self.bottomTitle = bottomTitle
        self.bottomTitleAlignment = bottomTitleAlignment
    }
}

/// Reports whether a cluster of `width` cells may be stored in a cell.
// parity: native/src/buffer.zig#isPrintableGlyph [status=implemented hash=b8d4bfeeec9d]
public func isPrintableGlyph(_ bytes: [UInt8], width: UInt32) -> Bool {
    guard bytes.count <= graphemeBytesMax && width <= glyphWidthMax else { return false }
    return !containsControl(bytes)
}

/// Reports whether `codepoint` is a C0, DEL, or C1 control character.
// parity: native/src/buffer.zig#isControlCodepoint [status=implemented hash=5f89b765d7a6]
@inline(__always)
public func isControlCodepoint(_ codepoint: UInt32) -> Bool {
    isControl(codepoint)
}

// MARK: - Porter-Duff Source-Over Alpha Blending

@inline(__always)
private func mulDiv255(_ a: UInt32, _ b: UInt32) -> UInt32 {
    (a * b + 127) / 255
}

@inline(__always)
private func roundDiv(_ n: UInt32, _ d: UInt32) -> UInt8 {
    UInt8((n + d / 2) / d)
}

@inline(__always)
private func colorAlphaByte(_ c: RGBA) -> UInt8 {
    UInt8(c.b3 & 0xFF)
}

@inline(__always)
private func isRGBAWithAlpha(_ c: RGBA) -> Bool {
    colorAlphaByte(c) < 255
}

@inline(__always)
private func isFullyOpaque(opacity: Double, fg: RGBA, bg: RGBA) -> Bool {
    opacity == 1.0 && !isRGBAWithAlpha(fg) && !isRGBAWithAlpha(bg)
}

@inline(__always)
private func isFullyTransparent(opacity: Double, fg: RGBA, bg: RGBA) -> Bool {
    opacity == 0.0 || (colorAlphaByte(fg) == 0 && colorAlphaByte(bg) == 0)
}

@inline(__always)
private func opacityToU8(_ opacity: Double) -> UInt8 {
    let clamped = opacity.isFinite ? max(0.0, min(1.0, opacity)) : 0.0
    return UInt8((clamped * 255.0).rounded(.toNearestOrAwayFromZero))
}

@inline(__always)
private func applyOpacity(_ color: RGBA, opacity: UInt8) -> RGBA {
    let (_, _, _, a) = color.toInts()
    let newA = UInt8(mulDiv255(UInt32(a), UInt32(opacity)))
    let b3 = (color.b3 & 0xFF00) | UInt16(newA)
    return RGBA(b0: color.b0, b1: color.b1, b2: color.b2, b3: b3)
}

/// Porter-Duff source-over alpha blending of `src` over `dst0`, using `backdrop`
/// when `dst0` has alpha 0 (matching `native/src/buffer.zig#blendColors`).
public func blendColors(src: RGBA, dst dst0: RGBA, backdrop: RGBA? = nil) -> RGBA {
    let (sr8, sg8, sb8, sa8) = src.toInts()
    let sa = UInt32(sa8)
    if sa == 0 { return dst0 }

    let dst = colorAlphaByte(dst0) == 0 ? (backdrop ?? dst0) : dst0
    if sa == 255 {
        return RGBA.fromInts(Int(sr8), Int(sg8), Int(sb8), 255)
    }

    let (dr8, dg8, db8, da8) = dst.toInts()
    let da = UInt32(da8)
    let inv = 255 - sa
    let outA = sa + mulDiv255(da, inv)
    if outA == 0 {
        return RGBA.fromInts(0, 0, 0, 0)
    }

    let sr = UInt32(sr8)
    let sg = UInt32(sg8)
    let sb = UInt32(sb8)
    let dr = UInt32(dr8)
    let dg = UInt32(dg8)
    let db = UInt32(db8)

    if da == 255 {
        let r = (sr * sa + dr * inv + 127) / 255
        let g = (sg * sa + dg * inv + 127) / 255
        let b = (sb * sa + db * inv + 127) / 255
        return RGBA.fromInts(Int(r), Int(g), Int(b), 255)
    }

    let r = roundDiv(sr * sa + mulDiv255(dr * da, inv), outA)
    let g = roundDiv(sg * sa + mulDiv255(dg * da, inv), outA)
    let b = roundDiv(sb * sa + mulDiv255(db * da, inv), outA)
    return RGBA.fromInts(Int(r), Int(g), Int(b), Int(outA))
}

// MARK: - OptimizedBuffer

/// Pure-Swift cell framebuffer supporting grapheme clusters, OSC 8 hyperlinks, Porter-Duff
/// alpha compositing, scissor clipping, opacity stacking, box/text/styled-text drawing,
/// framebuffer composition, and hit-grid tracking.
// parity: core/src/buffer.ts#OptimizedBuffer [status=implemented hash=ab16c376bb9b]
public final class OptimizedBuffer: @unchecked Sendable {
    public let id: String
    // parity: core/src/buffer.ts#OptimizedBuffer.width [status=implemented hash=3a82f1e10187]
    public private(set) var width: Int
    // parity: core/src/buffer.ts#OptimizedBuffer.height [status=implemented hash=475847a45f65]
    public private(set) var height: Int
    // parity: core/src/buffer.ts#OptimizedBuffer.widthMethod [status=implemented hash=c14359ff4aee]
    public var widthMethod: WidthMethod
    public var respectAlpha: Bool
    public var blendBackdropColor: RGBA?
    public private(set) var isDestroyed: Bool = false

    public let graphemePool: GraphemePool
    public let linkPool: LinkPool
    public let graphemeTracker: GraphemeTracker
    public let linkTracker: LinkTracker

    /// Structure-of-Arrays cell planes matching `native/src/buffer.zig#BufferArrays`.
    public private(set) var chars: [UInt32]
    public private(set) var fg: [RGBA]
    public private(set) var bg: [RGBA]
    public private(set) var attributes: [UInt32]

    /// Parallel hit-test ID grid (`0` = no hit target).
    public private(set) var hitGrid: [UInt32]

    private var scissorStack: [ClipRect] = []
    private var opacityStack: [Double] = []

    public init(
        width: Int,
        height: Int,
        widthMethod: WidthMethod = .unicode,
        respectAlpha: Bool = false,
        blendBackdropColor: RGBA? = nil,
        id: String = "buffer",
        graphemePool: GraphemePool = GraphemePool(),
        linkPool: LinkPool = LinkPool()
    ) {
        let safeWidth = max(0, width)
        let safeHeight = max(0, height)
        let count = safeWidth * safeHeight
        self.id = id
        self.width = safeWidth
        self.height = safeHeight
        self.widthMethod = widthMethod
        self.respectAlpha = respectAlpha
        self.blendBackdropColor = blendBackdropColor
        self.graphemePool = graphemePool
        self.linkPool = linkPool
        self.graphemeTracker = GraphemeTracker(pool: graphemePool)
        self.linkTracker = LinkTracker(pool: linkPool)
        self.chars = Array(repeating: defaultSpaceChar, count: count)
        self.fg = Array(repeating: RGBA.fromInts(255, 255, 255, 255), count: count)
        self.bg = Array(repeating: RGBA.fromInts(0, 0, 0, 0), count: count)
        self.attributes = Array(repeating: TextAttributes.none, count: count)
        self.hitGrid = Array(repeating: 0, count: count)
    }

    // parity: core/src/buffer.ts#OptimizedBuffer.create [status=implemented hash=a916e3c49664]
    public static func create(
        width: Int,
        height: Int,
        widthMethod: WidthMethod = .unicode,
        respectAlpha: Bool = false,
        blendBackdropColor: RGBA? = nil,
        id: String = "buffer",
        graphemePool: GraphemePool = GraphemePool(),
        linkPool: LinkPool = LinkPool()
    ) throws(BufferError) -> OptimizedBuffer {
        guard width > 0 && height > 0 else {
            throw .invalidDimensions
        }
        return OptimizedBuffer(
            width: width,
            height: height,
            widthMethod: widthMethod,
            respectAlpha: respectAlpha,
            blendBackdropColor: blendBackdropColor,
            id: id,
            graphemePool: graphemePool,
            linkPool: linkPool
        )
    }

    // parity: core/src/buffer.ts#OptimizedBuffer.destroy [status=implemented hash=d46c3275dbf3]
    public func destroy() {
        guard !isDestroyed else { return }
        graphemeTracker.clear()
        linkTracker.clear()
        scissorStack.removeAll()
        opacityStack.removeAll()
        chars.removeAll()
        fg.removeAll()
        bg.removeAll()
        attributes.removeAll()
        hitGrid.removeAll()
        width = 0
        height = 0
        isDestroyed = true
    }

    // parity: core/src/buffer.ts#OptimizedBuffer.setRespectAlpha [status=implemented hash=eb26c8ffcf96]
    public func setRespectAlpha(_ respectAlpha: Bool) {
        self.respectAlpha = respectAlpha
    }

    // parity: core/src/buffer.ts#OptimizedBuffer.resize [status=implemented hash=b672045dfaae]
    public func resize(width newWidth: Int, height newHeight: Int) throws(BufferError) {
        guard newWidth > 0 && newHeight > 0 else {
            throw .invalidDimensions
        }
        if newWidth == width && newHeight == height { return }
        let (count, overflow) = newWidth.multipliedReportingOverflow(by: newHeight)
        guard !overflow else { throw .invalidDimensions }

        graphemeTracker.clear()
        linkTracker.clear()
        width = newWidth
        height = newHeight
        chars = Array(repeating: defaultSpaceChar, count: count)
        fg = Array(repeating: RGBA.fromInts(255, 255, 255, 255), count: count)
        bg = Array(repeating: RGBA.fromInts(0, 0, 0, 255), count: count)
        attributes = Array(repeating: TextAttributes.none, count: count)
        hitGrid = Array(repeating: 0, count: count)
    }

    /// Replaces all cells, trackers, and hit-grid IDs from a same-sized buffer sharing pools.
    public func copyFrom(_ source: OptimizedBuffer) throws(BufferError) {
        guard width == source.width && height == source.height else {
            throw .invalidDimensions
        }
        guard self !== source else { return }
        graphemeTracker.copyFrom(source.graphemeTracker)
        linkTracker.copyFrom(source.linkTracker)
        chars = source.chars
        fg = source.fg
        bg = source.bg
        attributes = source.attributes
        hitGrid = source.hitGrid
    }

    // MARK: - Scissor Clip Rect Stack

    public var currentScissorRect: ClipRect? {
        scissorStack.last
    }

    public func isPointInScissor(x: Int, y: Int) -> Bool {
        guard let scissor = scissorStack.last else { return true }
        return x >= scissor.x
            && x < scissor.x + scissor.width
            && y >= scissor.y
            && y < scissor.y + scissor.height
    }

    public func isRectInScissor(x: Int, y: Int, width: Int, height: Int) -> Bool {
        guard let scissor = scissorStack.last else { return true }
        let rectEndX = x + width
        let rectEndY = y + height
        let scissorEndX = scissor.x + scissor.width
        let scissorEndY = scissor.y + scissor.height
        return !(x >= scissorEndX || rectEndX <= scissor.x || y >= scissorEndY || rectEndY <= scissor.y)
    }

    public func clipRectToScissor(x: Int, y: Int, width: Int, height: Int) -> ClipRect? {
        guard let scissor = scissorStack.last else {
            return ClipRect(x: x, y: y, width: width, height: height)
        }
        let ix = max(x, scissor.x)
        let iy = max(y, scissor.y)
        let iEndX = min(x + width, scissor.x + scissor.width)
        let iEndY = min(y + height, scissor.y + scissor.height)
        guard ix < iEndX && iy < iEndY else { return nil }
        return ClipRect(x: ix, y: iy, width: iEndX - ix, height: iEndY - iy)
    }

    // parity: core/src/buffer.ts#OptimizedBuffer.pushScissorRect [status=implemented hash=7ec25d94b558]
    public func pushScissorRect(x: Int, y: Int, width: Int, height: Int) {
        let clampedWidth = max(0, width)
        let clampedHeight = max(0, height)
        if scissorStack.last != nil {
            if let clipped = clipRectToScissor(x: x, y: y, width: clampedWidth, height: clampedHeight) {
                scissorStack.append(clipped)
            } else {
                scissorStack.append(ClipRect(x: 0, y: 0, width: 0, height: 0))
            }
        } else {
            scissorStack.append(ClipRect(x: x, y: y, width: clampedWidth, height: clampedHeight))
        }
    }

    // parity: core/src/buffer.ts#OptimizedBuffer.popScissorRect [status=implemented hash=c5dc5f932bdf]
    public func popScissorRect() {
        _ = scissorStack.popLast()
    }

    // parity: core/src/buffer.ts#OptimizedBuffer.clearScissorRects [status=implemented hash=becd413a066d]
    public func clearScissorRects() {
        scissorStack.removeAll(keepingCapacity: true)
    }

    // MARK: - Opacity Stack

    // parity: core/src/buffer.ts#OptimizedBuffer.getCurrentOpacity [status=implemented hash=f698ede988cd]
    public func getCurrentOpacity() -> Double {
        opacityStack.last ?? 1.0
    }

    public var currentOpacity: Double {
        getCurrentOpacity()
    }

    // parity: core/src/buffer.ts#OptimizedBuffer.pushOpacity [status=implemented hash=cc6e8cffdca8]
    public func pushOpacity(_ opacity: Double) {
        let clamped = opacity.isFinite ? max(0.0, min(1.0, opacity)) : 0.0
        let effective = getCurrentOpacity() * clamped
        opacityStack.append(effective)
    }

    // parity: core/src/buffer.ts#OptimizedBuffer.popOpacity [status=implemented hash=e2aaf12f5044]
    public func popOpacity() {
        _ = opacityStack.popLast()
    }

    // parity: core/src/buffer.ts#OptimizedBuffer.clearOpacity [status=implemented hash=d1a5f4fb9375]
    public func clearOpacity() {
        opacityStack.removeAll(keepingCapacity: true)
    }

    // MARK: - Hit-Grid Tracking

    /// Assigns a hit-test ID to cell `(x, y)` if inside buffer bounds and the active scissor rect.
    public func setHitId(_ hitId: UInt32, atX x: Int, y: Int) {
        guard let idx = validIndexInScissor(x: x, y: y) else { return }
        hitGrid[idx] = hitId
    }

    /// Fills a rectangular region of the hit-test grid with `hitId`, clipped to buffer bounds and scissor.
    public func fillHitRect(x: Int, y: Int, width rectWidth: Int, height rectHeight: Int, hitId: UInt32) {
        guard rectWidth > 0 && rectHeight > 0 && width > 0 && height > 0 else { return }
        let startX = max(0, x)
        let startY = max(0, y)
        let endX = min(width, x + rectWidth)
        let endY = min(height, y + rectHeight)
        guard startX < endX && startY < endY else { return }
        guard let clipped = clipRectToScissor(x: startX, y: startY, width: endX - startX, height: endY - startY) else {
            return
        }
        let cStartX = max(startX, clipped.x)
        let cStartY = max(startY, clipped.y)
        let cEndX = min(endX, clipped.x + clipped.width)
        let cEndY = min(endY, clipped.y + clipped.height)
        guard cStartX < cEndX && cStartY < cEndY else { return }

        for row in cStartY..<cEndY {
            let rowStart = row * width + cStartX
            let rowEnd = row * width + cEndX
            for idx in rowStart..<rowEnd {
                hitGrid[idx] = hitId
            }
        }
    }

    /// Returns the hit-test ID at `(x, y)`, or `0` if out of bounds or unset.
    public func hitId(atX x: Int, y: Int) -> UInt32 {
        guard x >= 0 && x < width && y >= 0 && y < height else { return 0 }
        return hitGrid[y * width + x]
    }

    /// Clears all hit-test IDs to `0`.
    public func clearHitGrid() {
        for i in hitGrid.indices {
            hitGrid[i] = 0
        }
    }

    // MARK: - Cell Access & Clearing

    @inline(__always)
    private func coordsToIndex(x: Int, y: Int) -> Int {
        y * width + x
    }

    @inline(__always)
    private func validIndexInScissor(x: Int, y: Int) -> Int? {
        guard x >= 0 && x < width && y >= 0 && y < height else { return nil }
        guard isPointInScissor(x: x, y: y) else { return nil }
        return y * width + x
    }

    public func cell(atX x: Int, y: Int) -> TerminalCell? {
        guard x >= 0 && x < width && y >= 0 && y < height else { return nil }
        let idx = y * width + x
        return TerminalCell(
            scalar: chars[idx],
            foreground: fg[idx],
            background: bg[idx],
            attributes: attributes[idx]
        )
    }

    // parity: core/src/buffer.ts#OptimizedBuffer.clear [status=implemented hash=bb074fa310b5]
    public func clear(bg clearBg: RGBA = RGBA.fromValues(0, 0, 0, 1), char clearChar: UInt32 = defaultSpaceChar) {
        linkTracker.clear()
        graphemeTracker.clear()
        let white = RGBA.fromInts(255, 255, 255, 255)
        for i in chars.indices {
            chars[i] = clearChar
            fg[i] = white
            bg[i] = clearBg
            attributes[i] = TextAttributes.none
            hitGrid[i] = 0
        }
    }

    /// Clears rows in `[top, bottom)` releasing grapheme and link references held by those cells.
    public func clearRows(top: Int, bottom: Int, bg clearBg: RGBA, char clearChar: UInt32 = defaultSpaceChar) {
        let lo = max(0, min(top, height))
        let hi = max(lo, min(bottom, height))
        guard lo < hi else { return }
        let start = lo * width
        let end = hi * width
        let white = RGBA.fromInts(255, 255, 255, 255)
        for idx in start..<end {
            let c = chars[idx]
            if isGraphemeChar(c) {
                graphemeTracker.remove(graphemeIdFromChar(c))
            }
            let linkId = getLinkId(attributes[idx])
            if linkId != 0 {
                linkTracker.removeCellRef(linkId)
            }
            chars[idx] = clearChar
            fg[idx] = white
            bg[idx] = clearBg
            attributes[idx] = TextAttributes.none
            hitGrid[idx] = 0
        }
    }

    @inline(__always)
    private func writeCellAndLinks(index: Int, cell: TerminalCell) {
        let prevLinkId = getLinkId(attributes[index])
        let newLinkId = getLinkId(cell.attributes)

        chars[index] = cell.scalar
        fg[index] = cell.foreground
        bg[index] = cell.background
        attributes[index] = cell.attributes

        if prevLinkId != 0 && prevLinkId != newLinkId {
            linkTracker.removeCellRef(prevLinkId)
        }
        if newLinkId != 0 && newLinkId != prevLinkId {
            linkTracker.addCellRef(newLinkId)
        }
    }

    /// Writes a single cell and updates link refs, without grapheme span cleanup.
    public func setCellRaw(x: Int, y: Int, cell: TerminalCell) {
        guard let idx = validIndexInScissor(x: x, y: y) else { return }
        writeCellAndLinks(index: idx, cell: cell)
    }

    /// Syncs a cell from an authoritative source buffer (used by diff renderer without span cleanup).
    public func syncCell(x: Int, y: Int, cell: TerminalCell) {
        setCellInternal(spanCleanup: false, x: x, y: y, cell: cell)
    }

    /// Writes a cell with full grapheme span cleanup, continuation writing, and tracker maintenance.
    public func setCell(x: Int, y: Int, cell: TerminalCell) {
        setCellInternal(spanCleanup: true, x: x, y: y, cell: cell)
    }

    private func setCellInternal(spanCleanup: Bool, x: Int, y: Int, cell: TerminalCell) {
        guard let index = validIndexInScissor(x: x, y: y) else { return }
        let prevChar = chars[index]
        if !isClusterChar(prevChar) && !isGraphemeChar(cell.scalar) {
            writeCellAndLinks(index: index, cell: cell)
            return
        }

        let newLinkId = getLinkId(cell.attributes)
        if newLinkId != 0 { linkTracker.addCellRef(newLinkId) }
        defer { if newLinkId != 0 { linkTracker.removeCellRef(newLinkId) } }

        var trackerReplaced = false
        let newStartId: UInt32?
        if isGraphemeChar(cell.scalar) && x + Int(charRightExtent(cell.scalar)) + 1 <= width {
            newStartId = graphemeIdFromChar(cell.scalar)
        } else {
            newStartId = nil
        }

        if !spanCleanup {
            let oldStartId = isGraphemeChar(prevChar) ? graphemeIdFromChar(prevChar) : nil
            if oldStartId != nil || newStartId != nil {
                graphemeTracker.replace(oldId: oldStartId, newId: newStartId)
                trackerReplaced = true
            }
        } else if isClusterChar(prevChar) && prevChar != cell.scalar {
            let rowStart = y * width
            let id = graphemeIdFromChar(prevChar)
            if let newId = newStartId {
                graphemeTracker.add(newId)
            }
            trackerReplaced = true

            let leftExtent = Int(charLeftExtent(prevChar))
            let spanStart = index - min(leftExtent, index - rowStart)
            let spanEnd = min(spanStart + Int(glyphWidthMax), rowStart + width)

            for spanI in spanStart..<spanEnd {
                let spanChar = chars[spanI]
                if !isClusterChar(spanChar) || graphemeIdFromChar(spanChar) != id { continue }
                if Int(charLeftExtent(spanChar)) != spanI - spanStart { continue }
                if isGraphemeChar(spanChar) {
                    graphemeTracker.remove(id)
                }
                let spanLinkId = getLinkId(attributes[spanI])
                if spanLinkId != 0 { linkTracker.removeCellRef(spanLinkId) }
                chars[spanI] = defaultSpaceChar
                attributes[spanI] = TextAttributes.none
            }
        }

        if isGraphemeChar(cell.scalar) {
            let right = Int(charRightExtent(cell.scalar))
            let spanWidth = 1 + right
            if x + spanWidth > width {
                let endOfLine = (y + 1) * width
                for eolI in index..<endOfLine {
                    let eolChar = chars[eolI]
                    if eolI != index && isGraphemeChar(eolChar) {
                        graphemeTracker.remove(graphemeIdFromChar(eolChar))
                    }
                    let eolLinkId = getLinkId(attributes[eolI])
                    if eolLinkId != 0 { linkTracker.removeCellRef(eolLinkId) }
                    chars[eolI] = defaultSpaceChar
                    attributes[eolI] = cell.attributes
                    fg[eolI] = cell.foreground
                    bg[eolI] = cell.background
                    if newLinkId != 0 { linkTracker.addCellRef(newLinkId) }
                }
                return
            }

            writeCellAndLinks(index: index, cell: cell)

            let gid = graphemeIdFromChar(cell.scalar)
            let isSameGraphemeStart = isGraphemeChar(prevChar) && prevChar == cell.scalar
            if !trackerReplaced && !isSameGraphemeStart {
                graphemeTracker.add(gid)
            }

            if right > 0 {
                let rowEndIndex = (y * width) + width - 1
                for contI in 1...right {
                    let contIndex = index + contI
                    let contChar = chars[contIndex]
                    if isGraphemeChar(contChar) {
                        let oldId = graphemeIdFromChar(contChar)
                        graphemeTracker.remove(oldId)
                        if spanCleanup {
                            let tailEnd = contIndex + min(Int(charRightExtent(contChar)), rowEndIndex - contIndex)
                            let tailStart = index + spanWidth
                            if tailStart <= tailEnd {
                                for tailI in tailStart...tailEnd {
                                    let tailChar = chars[tailI]
                                    if !isContinuationChar(tailChar) || graphemeIdFromChar(tailChar) != oldId { continue }
                                    if Int(charLeftExtent(tailChar)) != tailI - contIndex { continue }
                                    let tailLinkId = getLinkId(attributes[tailI])
                                    if tailLinkId != 0 { linkTracker.removeCellRef(tailLinkId) }
                                    chars[tailI] = defaultSpaceChar
                                    attributes[tailI] = TextAttributes.none
                                }
                            }
                        }
                    }
                    let contLinkId = getLinkId(attributes[contIndex])
                    if contLinkId != 0 { linkTracker.removeCellRef(contLinkId) }
                }

                for k in 1...right {
                    let contIndex = index + k
                    chars[contIndex] = packContinuation(left: UInt32(k), gid: gid)
                    fg[contIndex] = cell.foreground
                    bg[contIndex] = cell.background
                    attributes[contIndex] = cell.attributes
                    if newLinkId != 0 { linkTracker.addCellRef(newLinkId) }
                }
            }
        } else {
            writeCellAndLinks(index: index, cell: cell)
        }
    }

    private func encodeCellChar(_ str: String) -> (encoded: UInt32, retainedGid: UInt32?) {
        guard !str.isEmpty else { return (defaultSpaceChar, nil) }
        let bytes = Array(str.utf8)
        if bytes.count == 1 && bytes[0] >= 0x20 && bytes[0] < 0x7F {
            return (UInt32(bytes[0]), nil)
        }
        let clusterWidth = getGraphemeWidthAt(bytes, byteOffset: 0, tabWidth: 2, controlDisplay: .hidden, widthMethod: widthMethod)
        if clusterWidth == 0 || !isPrintableGlyph(bytes, width: clusterWidth) {
            return (defaultSpaceChar, nil)
        }
        if clusterWidth == 1 && str.unicodeScalars.count == 1, let scalar = str.unicodeScalars.first {
            return (scalar.value, nil)
        }
        if let gid = try? graphemePool.acquire(bytes) {
            return (packGraphemeStart(gid: gid, totalWidth: clusterWidth), gid)
        }
        return (defaultSpaceChar, nil)
    }

    // parity: core/src/buffer.ts#OptimizedBuffer.setCell [status=implemented hash=bbbb82cca335]
    public func setCell(
        x: Int,
        y: Int,
        char: String,
        fg: RGBA,
        bg: RGBA,
        attributes: UInt32 = TextAttributes.none
    ) {
        let (encoded, retainedGid) = encodeCellChar(char)
        defer { if let gid = retainedGid { try? graphemePool.decref(gid) } }
        setCell(x: x, y: y, cell: TerminalCell(scalar: encoded, foreground: fg, background: bg, attributes: attributes))
    }

    /// Blends `overlayCell` over `destCell` using Porter-Duff source-over compositing.
    public func blendCells(overlay overlayCell: TerminalCell, dest destCell: TerminalCell) -> TerminalCell {
        let hasBgAlpha = isRGBAWithAlpha(overlayCell.background)
        let hasFgAlpha = isRGBAWithAlpha(overlayCell.foreground)

        if hasBgAlpha || hasFgAlpha {
            let blendedBg = hasBgAlpha
                ? blendColors(src: overlayCell.background, dst: destCell.background, backdrop: blendBackdropColor)
                : overlayCell.background

            let preserveChar = overlayCell.scalar == defaultSpaceChar
                && destCell.scalar != 0
                && destCell.scalar != defaultSpaceChar
                && encodedCharWidth(destCell.scalar) == 1

            let finalChar = preserveChar ? destCell.scalar : overlayCell.scalar
            let finalFg: RGBA
            if preserveChar {
                finalFg = blendColors(src: overlayCell.background, dst: destCell.foreground, backdrop: blendBackdropColor)
            } else {
                finalFg = hasFgAlpha
                    ? blendColors(src: overlayCell.foreground, dst: blendedBg, backdrop: blendBackdropColor)
                    : overlayCell.foreground
            }

            let baseAttrs = preserveChar
                ? getBaseAttributes(destCell.attributes)
                : getBaseAttributes(overlayCell.attributes)
            let overlayLinkId = getLinkId(overlayCell.attributes)
            let finalAttributes = attributesWithLink(baseAttrs, linkId: overlayLinkId)

            return TerminalCell(
                scalar: finalChar,
                foreground: finalFg,
                background: blendedBg,
                attributes: finalAttributes
            )
        }

        return overlayCell
    }

    public func setCellWithAlphaBlending(x: Int, y: Int, cell: TerminalCell) {
        guard x >= 0 && x < width && y >= 0 && y < height else { return }
        guard isPointInScissor(x: x, y: y) else { return }

        let opacity = getCurrentOpacity()
        if isFullyTransparent(opacity: opacity, fg: cell.foreground, bg: cell.background) {
            return
        }
        if isFullyOpaque(opacity: opacity, fg: cell.foreground, bg: cell.background) {
            setCell(x: x, y: y, cell: cell)
            return
        }

        let opacityByte = opacityToU8(opacity)
        let effectiveCell = TerminalCell(
            scalar: cell.scalar,
            foreground: applyOpacity(cell.foreground, opacity: opacityByte),
            background: applyOpacity(cell.background, opacity: opacityByte),
            attributes: cell.attributes
        )

        if let dest = self.cell(atX: x, y: y) {
            let blended = blendCells(overlay: effectiveCell, dest: dest)
            setCell(x: x, y: y, cell: blended)
        } else {
            setCell(x: x, y: y, cell: effectiveCell)
        }
    }

    // parity: core/src/buffer.ts#OptimizedBuffer.setCellWithAlphaBlending [status=implemented hash=bfe1c708ab6d]
    public func setCellWithAlphaBlending(
        x: Int,
        y: Int,
        char: String,
        fg: RGBA,
        bg: RGBA,
        attributes: UInt32 = TextAttributes.none
    ) {
        let (encoded, retainedGid) = encodeCellChar(char)
        defer { if let gid = retainedGid { try? graphemePool.decref(gid) } }
        setCellWithAlphaBlending(
            x: x,
            y: y,
            cell: TerminalCell(scalar: encoded, foreground: fg, background: bg, attributes: attributes)
        )
    }

    // parity: core/src/buffer.ts#OptimizedBuffer.drawChar [status=implemented hash=852263c0bf46]
    public func drawChar(
        _ char: UInt32,
        x: Int,
        y: Int,
        fg: RGBA,
        bg: RGBA,
        attributes: UInt32 = TextAttributes.none
    ) {
        setCellWithAlphaBlending(
            x: x,
            y: y,
            cell: TerminalCell(scalar: char, foreground: fg, background: bg, attributes: attributes)
        )
    }

    // MARK: - Fill Rect

    // parity: core/src/buffer.ts#OptimizedBuffer.fillRect [status=implemented hash=384eeb7fd767]
    public func fillRect(x: Int, y: Int, width rectWidth: Int, height rectHeight: Int, bg fillBg: RGBA) {
        guard width > 0 && height > 0 && rectWidth > 0 && rectHeight > 0 else { return }
        let startX = max(0, x)
        let startY = max(0, y)
        let endX = min(width, x + rectWidth)
        let endY = min(height, y + rectHeight)
        guard startX < endX && startY < endY else { return }

        guard let clipped = clipRectToScissor(x: startX, y: startY, width: endX - startX, height: endY - startY) else {
            return
        }
        let cStartX = max(startX, clipped.x)
        let cStartY = max(startY, clipped.y)
        let cEndX = min(endX, clipped.x + clipped.width)
        let cEndY = min(endY, clipped.y + clipped.height)
        guard cStartX < cEndX && cStartY < cEndY else { return }

        let opacity = getCurrentOpacity()
        let transparentFg = RGBA.fromInts(0, 0, 0, 0)
        if isFullyTransparent(opacity: opacity, fg: transparentFg, bg: fillBg) {
            return
        }

        let white = RGBA.fromInts(255, 255, 255, 255)
        let hasAlpha = isRGBAWithAlpha(fillBg) || opacity < 1.0
        let trackerAware = graphemeTracker.hasAny || linkTracker.hasAny

        if !hasAlpha && !trackerAware {
            for row in cStartY..<cEndY {
                let rowStart = row * width + cStartX
                let rowEnd = row * width + cEndX
                for idx in rowStart..<rowEnd {
                    chars[idx] = defaultSpaceChar
                    fg[idx] = white
                    bg[idx] = fillBg
                    attributes[idx] = TextAttributes.none
                }
            }
        } else {
            let cell = TerminalCell(
                scalar: defaultSpaceChar,
                foreground: white,
                background: fillBg,
                attributes: TextAttributes.none
            )
            for row in cStartY..<cEndY {
                for col in cStartX..<cEndX {
                    setCellWithAlphaBlending(x: col, y: row, cell: cell)
                }
            }
        }
    }

    // MARK: - Text Drawing

    private func drawRowText(
        _ text: String,
        x: Int,
        y: Int,
        fg textFg: RGBA,
        bg textBg: RGBA?,
        attributes textAttrs: UInt32,
        fit: TextFit = TextFit()
    ) {
        guard y >= 0 && y < height && !text.isEmpty else { return }
        let opacity = getCurrentOpacity()
        if isFullyTransparent(opacity: opacity, fg: textFg, bg: textBg ?? RGBA.fromInts(0, 0, 0, 0)) {
            return
        }

        let limitEnd = fit.maxWidth > 0 ? min(width, x + fit.maxWidth) : width
        guard x < limitEnd else { return }

        var bytes = Array(text.utf8)
        let tabWidth: UInt8 = 2

        // Apply fit + ellipsis truncation if requested
        if fit.maxWidth > 0 && fit.ellipsis {
            let totalWidth = calculateTextWidth(bytes, tabWidth: tabWidth, controlDisplay: .hidden, widthMethod: widthMethod)
            if Int(totalWidth) > fit.maxWidth {
                let ellipsisBytes = Array("\u{2026}".utf8)
                let ellipsisWidth = calculateTextWidth(ellipsisBytes, tabWidth: tabWidth, controlDisplay: .hidden, widthMethod: widthMethod)
                let room = fit.maxWidth > Int(ellipsisWidth) ? UInt32(fit.maxWidth) - ellipsisWidth : 0
                let cut = findWrapPosByWidthGraphemeSafe(
                    bytes,
                    maxColumns: room,
                    tabWidth: tabWidth,
                    controlDisplay: .hidden,
                    widthMethod: widthMethod
                )
                bytes = Array(bytes[0..<Int(cut.byteOffset)]) + ellipsisBytes
            }
        }

        let explicitOpaque: Bool
        if let explicitBg = textBg {
            explicitOpaque = isFullyOpaque(opacity: opacity, fg: textFg, bg: explicitBg)
        } else {
            explicitOpaque = false
        }

        // Printable ASCII fast path
        if isAsciiOnly(bytes) {
            let startOffset = x < 0 ? min(bytes.count, -x) : 0
            var col = max(x, 0)
            for i in startOffset..<bytes.count {
                if col >= limitEnd { break }
                if isPointInScissor(x: col, y: y) {
                    let resolvedBg = textBg ?? bg[coordsToIndex(x: col, y: y)]
                    let cell = TerminalCell(
                        scalar: UInt32(bytes[i]),
                        foreground: textFg,
                        background: resolvedBg,
                        attributes: textAttrs
                    )
                    if explicitOpaque {
                        setCell(x: col, y: y, cell: cell)
                    } else {
                        setCellWithAlphaBlending(x: col, y: y, cell: cell)
                    }
                }
                col += 1
            }
            return
        }

        // General Unicode grapheme cluster path
        let spans = segmentGraphemeClusters(
            bytes,
            tabWidth: tabWidth,
            controlDisplay: .hidden,
            widthMethod: widthMethod
        )
        var advanceCols = 0
        for span in spans {
            let glyphX = x + advanceCols
            if glyphX >= limitEnd { break }
            let glyphWidth = Int(span.width)
            if glyphWidth == 0 { continue }
            advanceCols += glyphWidth

            let clusterBytes = Array(bytes[span.byteStart..<span.byteEnd])
            let isBlank = !isPrintableGlyph(clusterBytes, width: span.width)

            if isBlank {
                let firstCol = max(glyphX, 0)
                let endCol = min(glyphX + glyphWidth, limitEnd)
                guard firstCol < endCol else { continue }
                for col in firstCol..<endCol {
                    guard isPointInScissor(x: col, y: y) else { continue }
                    let resolvedBg = textBg ?? bg[coordsToIndex(x: col, y: y)]
                    let cell = TerminalCell(
                        scalar: defaultSpaceChar,
                        foreground: textFg,
                        background: resolvedBg,
                        attributes: textAttrs
                    )
                    if explicitOpaque {
                        setCell(x: col, y: y, cell: cell)
                    } else {
                        setCellWithAlphaBlending(x: col, y: y, cell: cell)
                    }
                }
                continue
            }

            // A printable glyph must fit entirely inside [0, limitEnd) and the active scissor rect.
            guard glyphX >= 0 && glyphX + glyphWidth <= limitEnd else { continue }
            var allInScissor = true
            for offset in 0..<glyphWidth {
                if !isPointInScissor(x: glyphX + offset, y: y) {
                    allInScissor = false
                    break
                }
            }
            guard allInScissor else { continue }

            let resolvedBg = textBg ?? bg[coordsToIndex(x: glyphX, y: y)]
            var retainedGid: UInt32? = nil
            defer { if let gid = retainedGid { try? graphemePool.decref(gid) } }

            let encodedChar: UInt32
            if clusterBytes.count == 1 && glyphWidth == 1 {
                encodedChar = UInt32(clusterBytes[0])
            } else if glyphWidth == 1 && span.byteLen <= 4 && isValidUtf8(clusterBytes),
                      let decoded = Optional(String(decoding: clusterBytes, as: UTF8.self)),
                      decoded.unicodeScalars.count == 1,
                      let scalar = decoded.unicodeScalars.first
            {
                encodedChar = scalar.value
            } else if let gid = try? graphemePool.acquire(clusterBytes) {
                retainedGid = gid
                encodedChar = packGraphemeStart(gid: gid, totalWidth: span.width)
            } else {
                encodedChar = defaultSpaceChar
            }

            let cell = TerminalCell(
                scalar: encodedChar,
                foreground: textFg,
                background: resolvedBg,
                attributes: textAttrs
            )
            if explicitOpaque {
                setCell(x: glyphX, y: y, cell: cell)
            } else {
                setCellWithAlphaBlending(x: glyphX, y: y, cell: cell)
            }
        }
    }

    // parity: core/src/buffer.ts#OptimizedBuffer.drawText [status=implemented hash=c0ab798b1760]
    public func drawText(
        _ text: String,
        x: Int,
        y: Int,
        fg: RGBA,
        bg: RGBA? = nil,
        attributes: UInt32 = TextAttributes.none,
        selection: TextSelection? = nil
    ) {
        guard let selection else {
            drawRowText(text, x: x, y: y, fg: fg, bg: bg, attributes: attributes)
            return
        }

        let start = max(0, selection.start)
        let end = max(start, selection.end)
        let selectionBg: RGBA
        let selectionFg: RGBA
        if let selBg = selection.bgColor {
            selectionBg = selBg
            selectionFg = selection.fgColor ?? fg
        } else {
            let defaultBg = bg ?? RGBA.fromValues(0, 0, 0, 0)
            selectionFg = colorAlphaByte(defaultBg) > 0 ? defaultBg : RGBA.fromValues(0, 0, 0, 1)
            selectionBg = fg
        }

        let utf16 = Array(text.utf16)
        let clampedStart = min(start, utf16.count)
        let clampedEnd = min(end, utf16.count)

        var cursorX = x
        if clampedStart > 0 {
            let before = String(decoding: utf16[0..<clampedStart], as: UTF16.self)
            drawRowText(before, x: cursorX, y: y, fg: fg, bg: bg, attributes: attributes)
            cursorX += Int(calculateTextWidth(before, tabWidth: 2, controlDisplay: .hidden, widthMethod: widthMethod))
        }
        if clampedEnd > clampedStart {
            let selected = String(decoding: utf16[clampedStart..<clampedEnd], as: UTF16.self)
            drawRowText(selected, x: cursorX, y: y, fg: selectionFg, bg: selectionBg, attributes: attributes)
            cursorX += Int(calculateTextWidth(selected, tabWidth: 2, controlDisplay: .hidden, widthMethod: widthMethod))
        }
        if clampedEnd < utf16.count {
            let after = String(decoding: utf16[clampedEnd..<utf16.count], as: UTF16.self)
            drawRowText(after, x: cursorX, y: y, fg: fg, bg: bg, attributes: attributes)
        }
    }

    // parity: core/src/buffer.ts#OptimizedBuffer.drawTextFit [status=implemented hash=143010e39579]
    public func drawTextFit(
        _ text: String,
        x: Int,
        y: Int,
        maxWidth: Int,
        fg: RGBA,
        bg: RGBA? = nil,
        attributes: UInt32 = TextAttributes.none,
        ellipsis: Bool = false
    ) {
        guard maxWidth >= 1 else { return }
        drawRowText(
            text,
            x: x,
            y: y,
            fg: fg,
            bg: bg,
            attributes: attributes,
            fit: TextFit(maxWidth: maxWidth, ellipsis: ellipsis)
        )
    }

    /// Draws a `StyledText` sequence of `TextChunk`s starting at `(x, y)`, resolving per-chunk
    /// foreground/background colors, attributes, OSC 8 hyperlinks, and newline line breaks.
    public func drawStyledText(
        _ styledText: StyledText,
        x: Int,
        y: Int,
        defaultFg: RGBA = .defaultForeground(),
        defaultBg: RGBA? = nil,
        maxWidth: Int? = nil
    ) {
        var cursorX = x
        var cursorY = y
        let rowLimit = maxWidth.map { x + max(0, $0) } ?? width

        for chunk in styledText.chunks {
            guard !chunk.text.isEmpty else { continue }
            let chunkFg = chunk.fg ?? defaultFg
            let chunkBg = chunk.bg ?? defaultBg
            var chunkAttrs = chunk.attributes ?? TextAttributes.none

            var retainedLinkId: UInt32? = nil
            if let url = chunk.link?.url, let linkId = try? linkPool.acquire(url) {
                retainedLinkId = linkId
                chunkAttrs = attributesWithLink(chunkAttrs, linkId: linkId)
            }
            defer {
                if let linkId = retainedLinkId {
                    try? linkPool.decref(linkId)
                }
            }

            let lines = chunk.text.split(separator: "\n", omittingEmptySubsequences: false)
            for (lineIndex, segment) in lines.enumerated() {
                if lineIndex > 0 {
                    cursorY += 1
                    cursorX = x
                }
                if segment.isEmpty { continue }
                let segmentStr = String(segment)
                if cursorY >= 0 && cursorY < height && cursorX < rowLimit {
                    let remaining = rowLimit - cursorX
                    if let _ = maxWidth {
                        drawRowText(
                            segmentStr,
                            x: cursorX,
                            y: cursorY,
                            fg: chunkFg,
                            bg: chunkBg,
                            attributes: chunkAttrs,
                            fit: TextFit(maxWidth: remaining, ellipsis: false)
                        )
                    } else {
                        drawRowText(
                            segmentStr,
                            x: cursorX,
                            y: cursorY,
                            fg: chunkFg,
                            bg: chunkBg,
                            attributes: chunkAttrs
                        )
                    }
                }
                cursorX += Int(calculateTextWidth(segmentStr, tabWidth: 2, controlDisplay: .hidden, widthMethod: widthMethod))
            }
        }
    }

    // MARK: - Box Drawing

    private struct BoxTitleLayout {
        var shouldDraw: Bool = false
        var startX: Int = 0
        var endX: Int = 0
    }

    private func computeBoxTitleLayout(
        title: String?,
        borderSide: Bool,
        isAtActualSide: Bool,
        boxX: Int,
        boxWidth: Int,
        alignment: BoxTitleAlignment
    ) -> BoxTitleLayout {
        guard let title, !title.isEmpty, borderSide, isAtActualSide else {
            return BoxTitleLayout()
        }
        let titleLength = Int(calculateTextWidth(title, tabWidth: 2, controlDisplay: .hidden, widthMethod: widthMethod))
        let minTitleSpace = 4
        guard boxWidth >= titleLength + minTitleSpace else {
            return BoxTitleLayout()
        }

        let padding = 2
        let titleX: Int
        switch alignment {
        case .left:
            titleX = boxX + padding
        case .center:
            titleX = boxX + (boxWidth - titleLength) / 2
        case .right:
            titleX = boxX + boxWidth - padding - titleLength
        }
        return BoxTitleLayout(shouldDraw: true, startX: titleX, endX: titleX + titleLength - 1)
    }

    // parity: core/src/buffer.ts#OptimizedBuffer.drawBox [status=implemented hash=0ef616e0d0f7]
    public func drawBox(_ options: BoxDrawOptions) {
        drawBox(
            x: options.x,
            y: options.y,
            width: options.width,
            height: options.height,
            borderStyle: options.borderStyle,
            customBorderChars: options.customBorderChars,
            borderSides: options.borderSides,
            borderColor: options.borderColor,
            backgroundColor: options.backgroundColor,
            titleColor: options.titleColor,
            shouldFill: options.shouldFill,
            title: options.title,
            titleAlignment: options.titleAlignment,
            bottomTitle: options.bottomTitle,
            bottomTitleAlignment: options.bottomTitleAlignment
        )
    }

    public func drawBox(
        x: Int,
        y: Int,
        width boxWidth: Int,
        height boxHeight: Int,
        borderStyle: BorderStyle = .single,
        customBorderChars: [UInt32]? = nil,
        borderSides: BorderSidesConfig = BorderSidesConfig(top: true, right: true, bottom: true, left: true),
        borderColor: RGBA = .defaultForeground(),
        backgroundColor: RGBA = RGBA.fromInts(0, 0, 0, 0),
        titleColor: RGBA? = nil,
        shouldFill: Bool = false,
        title: String? = nil,
        titleAlignment: BoxTitleAlignment = .left,
        bottomTitle: String? = nil,
        bottomTitleAlignment: BoxTitleAlignment = .left
    ) {
        guard boxWidth > 0 && boxHeight > 0 && width > 0 && height > 0 else { return }

        let resolvedTitleColor = titleColor ?? borderColor
        let opacity = getCurrentOpacity()
        let borderBgTransparent = isFullyTransparent(opacity: opacity, fg: borderColor, bg: backgroundColor)
        let hasTitle = (title != nil) || (bottomTitle != nil)
        let titleVisible = hasTitle && !isFullyTransparent(opacity: opacity, fg: resolvedTitleColor, bg: backgroundColor)
        if borderBgTransparent && !titleVisible { return }

        let startX = max(0, x)
        let startY = max(0, y)
        let endX = min(width - 1, x + boxWidth - 1)
        let endY = min(height - 1, y + boxHeight - 1)
        guard startX <= endX && startY <= endY else { return }

        let visibleWidth = endX - startX + 1
        let visibleHeight = endY - startY + 1
        guard isRectInScissor(x: startX, y: startY, width: visibleWidth, height: visibleHeight) else { return }

        let borderChars: [UInt32]
        if let custom = customBorderChars, custom.count >= 11 {
            borderChars = custom
        } else {
            switch borderStyle {
            case .single: borderChars = BorderCharArrays.single
            case .double: borderChars = BorderCharArrays.double
            case .rounded: borderChars = BorderCharArrays.rounded
            case .heavy: borderChars = BorderCharArrays.heavy
            }
        }

        let isAtActualLeft = startX == x
        let isAtActualRight = endX == x + boxWidth - 1
        let isAtActualTop = startY == y
        let isAtActualBottom = endY == y + boxHeight - 1

        let titleLayout = computeBoxTitleLayout(
            title: title,
            borderSide: borderSides.top,
            isAtActualSide: isAtActualTop,
            boxX: x,
            boxWidth: boxWidth,
            alignment: titleAlignment
        )
        let bottomTitleLayout = computeBoxTitleLayout(
            title: bottomTitle,
            borderSide: borderSides.bottom,
            isAtActualSide: isAtActualBottom,
            boxX: x,
            boxWidth: boxWidth,
            alignment: bottomTitleAlignment
        )

        if shouldFill {
            if !borderSides.top && !borderSides.right && !borderSides.bottom && !borderSides.left {
                fillRect(x: startX, y: startY, width: visibleWidth, height: visibleHeight, bg: backgroundColor)
            } else {
                let innerStartX = startX + (borderSides.left && isAtActualLeft ? 1 : 0)
                let innerStartY = startY + (borderSides.top && isAtActualTop ? 1 : 0)
                let innerEndX = endX - (borderSides.right && isAtActualRight ? 1 : 0)
                let innerEndY = endY - (borderSides.bottom && isAtActualBottom ? 1 : 0)
                if innerEndX >= innerStartX && innerEndY >= innerStartY {
                    fillRect(
                        x: innerStartX,
                        y: innerStartY,
                        width: innerEndX - innerStartX + 1,
                        height: innerEndY - innerStartY + 1,
                        bg: backgroundColor
                    )
                }
            }
        }

        let leftBorderOnly = borderSides.left && isAtActualLeft && !borderSides.top && !borderSides.bottom
        let rightBorderOnly = borderSides.right && isAtActualRight && !borderSides.top && !borderSides.bottom
        let bottomOnlyWithVerticals = borderSides.bottom && isAtActualBottom && !borderSides.top && (borderSides.left || borderSides.right)
        let topOnlyWithVerticals = borderSides.top && isAtActualTop && !borderSides.bottom && (borderSides.left || borderSides.right)
        let extendVerticalsToTop = leftBorderOnly || rightBorderOnly || bottomOnlyWithVerticals
        let extendVerticalsToBottom = leftBorderOnly || rightBorderOnly || topOnlyWithVerticals

        let useOpaqueFastPath = isFullyOpaque(opacity: opacity, fg: borderColor, bg: backgroundColor)

        @inline(__always)
        func writeBorderCell(cx: Int, cy: Int, scalar: UInt32) {
            let cell = TerminalCell(
                scalar: scalar,
                foreground: borderColor,
                background: backgroundColor,
                attributes: TextAttributes.none
            )
            if useOpaqueFastPath {
                setCell(x: cx, y: cy, cell: cell)
            } else {
                setCellWithAlphaBlending(x: cx, y: cy, cell: cell)
            }
        }

        if borderSides.top && isAtActualTop {
            for drawX in startX...endX {
                if titleLayout.shouldDraw && drawX >= titleLayout.startX && drawX <= titleLayout.endX {
                    continue
                }
                var scalar = borderChars[BorderCharIndex.horizontal.rawValue]
                if drawX == startX && isAtActualLeft {
                    scalar = borderSides.left
                        ? borderChars[BorderCharIndex.topLeft.rawValue]
                        : borderChars[BorderCharIndex.horizontal.rawValue]
                } else if drawX == endX && isAtActualRight {
                    scalar = borderSides.right
                        ? borderChars[BorderCharIndex.topRight.rawValue]
                        : borderChars[BorderCharIndex.horizontal.rawValue]
                }
                writeBorderCell(cx: drawX, cy: startY, scalar: scalar)
            }
        }

        if borderSides.bottom && isAtActualBottom {
            for drawX in startX...endX {
                if bottomTitleLayout.shouldDraw && drawX >= bottomTitleLayout.startX && drawX <= bottomTitleLayout.endX {
                    continue
                }
                var scalar = borderChars[BorderCharIndex.horizontal.rawValue]
                if drawX == startX && isAtActualLeft {
                    scalar = borderSides.left
                        ? borderChars[BorderCharIndex.bottomLeft.rawValue]
                        : borderChars[BorderCharIndex.horizontal.rawValue]
                } else if drawX == endX && isAtActualRight {
                    scalar = borderSides.right
                        ? borderChars[BorderCharIndex.bottomRight.rawValue]
                        : borderChars[BorderCharIndex.horizontal.rawValue]
                }
                writeBorderCell(cx: drawX, cy: endY, scalar: scalar)
            }
        }

        let verticalStartY = extendVerticalsToTop ? startY : startY + (borderSides.top && isAtActualTop ? 1 : 0)
        let verticalEndY = extendVerticalsToBottom ? endY : endY - (borderSides.bottom && isAtActualBottom ? 1 : 0)

        if (borderSides.left || borderSides.right) && verticalStartY <= verticalEndY {
            let vScalar = borderChars[BorderCharIndex.vertical.rawValue]
            for drawY in verticalStartY...verticalEndY {
                if borderSides.left && isAtActualLeft {
                    writeBorderCell(cx: startX, cy: drawY, scalar: vScalar)
                }
                if borderSides.right && isAtActualRight {
                    writeBorderCell(cx: endX, cy: drawY, scalar: vScalar)
                }
            }
        }

        if titleLayout.shouldDraw, let title {
            drawRowText(
                title,
                x: titleLayout.startX,
                y: startY,
                fg: resolvedTitleColor,
                bg: backgroundColor,
                attributes: TextAttributes.none
            )
        }

        if bottomTitleLayout.shouldDraw, let bottomTitle {
            drawRowText(
                bottomTitle,
                x: bottomTitleLayout.startX,
                y: endY,
                fg: resolvedTitleColor,
                bg: backgroundColor,
                attributes: TextAttributes.none
            )
        }
    }

    // MARK: - Framebuffer Compositing

    // parity: core/src/buffer.ts#OptimizedBuffer.drawFrameBuffer [status=implemented hash=77853d2ec43d]
    public func drawFrameBuffer(
        destX: Int,
        destY: Int,
        frameBuffer: OptimizedBuffer,
        sourceX: Int? = nil,
        sourceY: Int? = nil,
        sourceWidth: Int? = nil,
        sourceHeight: Int? = nil
    ) {
        guard width > 0 && height > 0 && frameBuffer.width > 0 && frameBuffer.height > 0 else { return }

        let opacity = getCurrentOpacity()
        if opacity == 0.0 { return }

        let srcX = max(0, sourceX ?? 0)
        let srcY = max(0, sourceY ?? 0)
        let reqWidth = sourceWidth ?? frameBuffer.width
        let reqHeight = sourceHeight ?? frameBuffer.height
        guard srcX < frameBuffer.width && srcY < frameBuffer.height else { return }
        guard reqWidth > 0 && reqHeight > 0 else { return }

        let clampedSrcWidth = min(reqWidth, frameBuffer.width - srcX)
        let clampedSrcHeight = min(reqHeight, frameBuffer.height - srcY)

        let startDestX = max(0, destX)
        let startDestY = max(0, destY)
        let endDestX = min(width - 1, destX + clampedSrcWidth - 1)
        let endDestY = min(height - 1, destY + clampedSrcHeight - 1)
        guard startDestX <= endDestX && startDestY <= endDestY else { return }

        let destWidth = endDestX - startDestX + 1
        let destHeight = endDestY - startDestY + 1
        guard let clipped = clipRectToScissor(x: startDestX, y: startDestY, width: destWidth, height: destHeight) else {
            return
        }
        let clippedStartX = max(startDestX, clipped.x)
        let clippedStartY = max(startDestY, clipped.y)
        let clippedEndX = min(endDestX, clipped.x + clipped.width - 1)
        let clippedEndY = min(endDestY, clipped.y + clipped.height - 1)
        guard clippedStartX <= clippedEndX && clippedStartY <= clippedEndY else { return }

        let sameGraphemePool = graphemePool === frameBuffer.graphemePool
        let sameLinkPool = linkPool === frameBuffer.linkPool
        let graphemeAware = graphemeTracker.hasAny || frameBuffer.graphemeTracker.hasAny
        let copies = opacity == 1.0 && !frameBuffer.respectAlpha

        for dY in clippedStartY...clippedEndY {
            var lastDrawnGraphemeId: UInt32? = nil
            let sY = srcY + (dY - destY)
            guard sY >= 0 && sY < frameBuffer.height else { continue }

            for dX in clippedStartX...clippedEndX {
                let sX = srcX + (dX - destX)
                guard sX >= 0 && sX < frameBuffer.width else { continue }

                let srcIndex = frameBuffer.coordsToIndex(x: sX, y: sY)
                var srcChar = frameBuffer.chars[srcIndex]
                let srcFg = frameBuffer.fg[srcIndex]
                let srcBg = frameBuffer.bg[srcIndex]
                var srcAttr = frameBuffer.attributes[srcIndex]
                let srcHit = frameBuffer.hitGrid[srcIndex]

                if !copies && colorAlphaByte(srcBg) == 0 && colorAlphaByte(srcFg) == 0 {
                    continue
                }

                // Remap link ID if buffers use different link pools
                var tempLinkId: UInt32? = nil
                let origLinkId = getLinkId(srcAttr)
                if origLinkId != 0 && !sameLinkPool {
                    if let url = try? frameBuffer.linkPool.get(origLinkId),
                       let mapped = try? linkPool.acquire(url)
                    {
                        tempLinkId = mapped
                        srcAttr = attributesWithLink(srcAttr, linkId: mapped)
                    } else {
                        srcAttr = getBaseAttributes(srcAttr)
                    }
                }
                defer { if let id = tempLinkId { try? linkPool.decref(id) } }

                if graphemeAware {
                    if isContinuationChar(srcChar) {
                        let gid = graphemeIdFromChar(srcChar)
                        if gid != lastDrawnGraphemeId {
                            let spaceCell = TerminalCell(
                                scalar: defaultSpaceChar,
                                foreground: srcFg,
                                background: srcBg,
                                attributes: srcAttr
                            )
                            if copies {
                                setCell(x: dX, y: dY, cell: spaceCell)
                            } else {
                                setCellWithAlphaBlending(x: dX, y: dY, cell: spaceCell)
                            }
                            if srcHit != 0 { hitGrid[coordsToIndex(x: dX, y: dY)] = srcHit }
                        }
                        continue
                    }

                    var tempGid: UInt32? = nil
                    if isGraphemeChar(srcChar) {
                        let rightExtent = Int(charRightExtent(srcChar))
                        if rightExtent > clippedEndX - dX {
                            srcChar = defaultSpaceChar
                            lastDrawnGraphemeId = nil
                        } else {
                            let origGid = graphemeIdFromChar(srcChar)
                            lastDrawnGraphemeId = origGid
                            if !sameGraphemePool {
                                if let bytes = try? frameBuffer.graphemePool.get(origGid),
                                   let mapped = try? graphemePool.acquire(bytes)
                                {
                                    tempGid = mapped
                                    srcChar = packGraphemeStart(gid: mapped, totalWidth: UInt32(rightExtent + 1))
                                } else {
                                    srcChar = defaultSpaceChar
                                    lastDrawnGraphemeId = nil
                                }
                            }
                        }
                    }
                    defer { if let id = tempGid { try? graphemePool.decref(id) } }

                    let cell = TerminalCell(scalar: srcChar, foreground: srcFg, background: srcBg, attributes: srcAttr)
                    if copies {
                        setCell(x: dX, y: dY, cell: cell)
                    } else {
                        setCellWithAlphaBlending(x: dX, y: dY, cell: cell)
                    }
                    if srcHit != 0 { hitGrid[coordsToIndex(x: dX, y: dY)] = srcHit }
                    continue
                }

                let cell = TerminalCell(scalar: srcChar, foreground: srcFg, background: srcBg, attributes: srcAttr)
                if copies {
                    setCell(x: dX, y: dY, cell: cell)
                } else {
                    setCellWithAlphaBlending(x: dX, y: dY, cell: cell)
                }
                if srcHit != 0 { hitGrid[coordsToIndex(x: dX, y: dY)] = srcHit }
            }
        }
    }

    // MARK: - Text Extraction & Span Capture

    private func resolveCellString(_ charCode: UInt32) -> String {
        if isContinuationChar(charCode) { return "" }
        if isGraphemeChar(charCode) {
            return (try? graphemePool.getString(graphemeIdFromChar(charCode))) ?? " "
        }
        if isImageChar(charCode) { return " " }
        if charCode == 0 { return " " }
        if let scalar = Unicode.Scalar(charCode) {
            return String(scalar)
        }
        return " "
    }

    // parity: core/src/buffer.ts#OptimizedBuffer.getRealCharBytes [status=implemented hash=98cd7168b005]
    public func getRealCharBytes(addLineBreaks: Bool = false) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(width * height + (addLineBreaks ? height : 0))
        for y in 0..<height {
            let rowStart = y * width
            for x in 0..<width {
                let s = resolveCellString(chars[rowStart + x])
                bytes.append(contentsOf: s.utf8)
            }
            if addLineBreaks {
                bytes.append(0x0A)
            }
        }
        return bytes
    }

    /// Returns the buffer's resolved text content with lines separated by `"\n"`.
    public func getPlainText(trimTrailingSpaces: Bool = false) -> String {
        guard width > 0 && height > 0 else { return "" }
        var lines: [String] = []
        lines.reserveCapacity(height)
        for y in 0..<height {
            var line = ""
            let rowStart = y * width
            for x in 0..<width {
                line.append(resolveCellString(chars[rowStart + x]))
            }
            if trimTrailingSpaces {
                while line.last == " " {
                    line.removeLast()
                }
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // parity: core/src/buffer.ts#OptimizedBuffer.getSpanLines [status=implemented hash=cae833809e54]
    public func getSpanLines() -> [CapturedLine] {
        var lines: [CapturedLine] = []
        lines.reserveCapacity(height)

        for y in 0..<height {
            var spans: [CapturedSpan] = []
            var currentSpan: CapturedSpan? = nil
            let rowStart = y * width

            for x in 0..<width {
                let idx = rowStart + x
                let cellFg = fg[idx]
                let cellBg = bg[idx]
                let cellAttrs = getBaseAttributes(attributes[idx])
                let cellText = resolveCellString(chars[idx])

                if var existing = currentSpan,
                   existing.fg == cellFg,
                   existing.bg == cellBg,
                   existing.attributes == cellAttrs
                {
                    existing.text.append(cellText)
                    existing.width += 1
                    currentSpan = existing
                } else {
                    if let existing = currentSpan {
                        spans.append(existing)
                    }
                    currentSpan = CapturedSpan(
                        text: cellText,
                        fg: cellFg,
                        bg: cellBg,
                        attributes: cellAttrs,
                        width: 1
                    )
                }
            }
            if let existing = currentSpan {
                spans.append(existing)
            }
            lines.append(CapturedLine(spans: spans))
        }
        return lines
    }
}
