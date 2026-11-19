/// Pure-Swift double-buffered ANSI diff renderer emitting minimal cursor moves, SGR
/// attributes, truecolor/indexed/default colors (`RGBA.intent`), OSC 8 hyperlinks,
/// and synchronized output (`CSI ?2026h` / `CSI ?2026l`), matching
/// `packages/native/src/renderer.zig` and `packages/native/src/renderer-output.zig`.

// MARK: - Renderer Types

// parity: native/src/renderer-output.zig#WriteStatus [status=implemented hash=d796f4e77f64]
public enum WriteStatus: UInt8, Equatable, Hashable, Sendable, Codable {
    case ok = 0
    case skipped = 1
    case failed = 2
}

// parity: native/src/renderer.zig#RenderStatus [status=implemented hash=e47cac085f1c]
public enum RenderStatus: UInt8, Equatable, Hashable, Sendable, Codable {
    case rendered = 0
    case skipped = 1
    case failed = 2
}

// parity: native/src/renderer.zig#PresentationOutcome [status=implemented hash=5c6a63e8386c]
public enum PresentationOutcome: Equatable, Hashable, Sendable, Codable {
    case presented
    case failed
}

// parity: native/src/renderer.zig#RendererError [status=implemented hash=385a8df0b2a0]
public enum RendererError: Error, Equatable, Hashable, Sendable {
    case outOfMemory
    case invalidDimensions
    case threadingFailed
    case writeFailed
}

// parity: native/src/renderer.zig#DebugOverlayCorner [status=implemented hash=9a8f943eb0a3]
public enum DebugOverlayCorner: UInt8, Equatable, Hashable, Sendable, Codable {
    case topLeft = 0
    case topRight = 1
    case bottomLeft = 2
    case bottomRight = 3
}

/// Terminal output capabilities controlling emitted ANSI/OSC sequences.
public struct RendererCapabilities: Equatable, Hashable, Sendable, Codable {
    /// Emit 24-bit truecolor (`38;2;r;g;b` / `48;2;r;g;b`) for `.rgb` intent colors.
    public var rgb: Bool
    /// Emit 256-color indexed (`38;5;n` / `48;5;n`) for `.indexed` intent (or fallback when `!rgb`).
    public var ansi256: Bool
    /// Emit OSC 8 hyperlink open/close sequences.
    public var hyperlinks: Bool
    /// Wrap non-empty frames in DEC mode 2026 synchronized output (`CSI ?2026h` ... `CSI ?2026l`).
    public var synchronizedOutput: Bool
    /// Emit OSC 66 explicit width wrapper (`ESC ]66;w=N;... ST`) for pooled graphemes.
    public var explicitWidth: Bool
    /// Reposition cursor explicitly after drawing a pooled grapheme cluster.
    public var explicitCursorPositioning: Bool

    public init(
        rgb: Bool = true,
        ansi256: Bool = true,
        hyperlinks: Bool = true,
        synchronizedOutput: Bool = true,
        explicitWidth: Bool = false,
        explicitCursorPositioning: Bool = false
    ) {
        self.rgb = rgb
        self.ansi256 = ansi256
        self.hyperlinks = hyperlinks
        self.synchronizedOutput = synchronizedOutput
        self.explicitWidth = explicitWidth
        self.explicitCursorPositioning = explicitCursorPositioning
    }
}

/// Cursor shape for DECSCUSR escape sequences.
public enum CursorRenderStyle: UInt8, Equatable, Hashable, Sendable, Codable {
    case `default` = 0
    case block = 1
    case line = 2
    case underline = 3
}

/// Desired terminal cursor position, visibility, shape, and color.
public struct CursorRenderState: Equatable, Hashable, Sendable {
    /// 1-based terminal column.
    public var x: Int
    /// 1-based terminal row (before `renderOffset`).
    public var y: Int
    public var visible: Bool
    public var style: CursorRenderStyle
    public var blinking: Bool
    public var color: RGBA?

    public init(
        x: Int = 1,
        y: Int = 1,
        visible: Bool = false,
        style: CursorRenderStyle = .default,
        blinking: Bool = false,
        color: RGBA? = nil
    ) {
        self.x = x
        self.y = y
        self.visible = visible
        self.style = style
        self.blinking = blinking
        self.color = color
    }
}

/// Deterministic per-frame statistics recorded by `AnsiDiffRenderer`.
public struct AnsiDiffRenderStats: Equatable, Hashable, Sendable {
    public var frameCount: UInt64
    public var cellsUpdated: Int
    public var rowsCompared: Int
    public var rowsDiffed: Int
    public var bytesEmitted: Int

    public init(
        frameCount: UInt64 = 0,
        cellsUpdated: Int = 0,
        rowsCompared: Int = 0,
        rowsDiffed: Int = 0,
        bytesEmitted: Int = 0
    ) {
        self.frameCount = frameCount
        self.cellsUpdated = cellsUpdated
        self.rowsCompared = rowsCompared
        self.rowsDiffed = rowsDiffed
        self.bytesEmitted = bytesEmitted
    }
}

// MARK: - AnsiDiffRenderer

/// Double-buffered front/back terminal frame differ emitting minimal ANSI escape sequences.
// parity: native/src/renderer.zig#CliRenderer [status=adapted hash=fb455a0184cb]
public final class AnsiDiffRenderer: @unchecked Sendable {
    /// Sentinel character used to clear the front buffer so the initial frame repaints every cell.
    private static let clearCharSentinel: UInt32 = 0x0A00

    private static let syncSet = "\u{1B}[?2026h"
    private static let syncReset = "\u{1B}[?2026l"
    private static let hideCursor = "\u{1B}[?25l"
    private static let showCursor = "\u{1B}[?25h"

    public private(set) var width: Int
    public private(set) var height: Int
    public var renderOffset: Int = 0
    public var backgroundColor: RGBA
    public var capabilities: RendererCapabilities
    public var cursorState: CursorRenderState

    public let graphemePool: GraphemePool
    public let linkPool: LinkPool

    /// Front buffer representing what is currently presented on the terminal.
    public let currentBuffer: OptimizedBuffer
    /// Back buffer where the application paints the next frame.
    public let nextBuffer: OptimizedBuffer

    public private(set) var stats: AnsiDiffRenderStats = AnsiDiffRenderStats()

    private var forceFullRepaint: Bool = false
    private var paletteRGBA: [RGBA]
    private var paletteIndexCache: [UInt32: UInt8] = [:]

    // Cursor diff cache to suppress flicker on unchanged frames
    private var lastCursorStyle: CursorRenderStyle? = nil
    private var lastCursorBlinking: Bool? = nil
    private var lastCursorColorRGB: RGBTriplet? = nil
    private var lastCursorX: Int? = nil
    private var lastCursorY: Int? = nil
    private var lastCursorVisible: Bool? = nil

    public init(
        width: Int,
        height: Int,
        widthMethod: WidthMethod = .unicode,
        backgroundColor: RGBA = RGBA.fromInts(0, 0, 0, 0),
        capabilities: RendererCapabilities = RendererCapabilities(),
        cursorState: CursorRenderState = CursorRenderState(),
        graphemePool: GraphemePool = GraphemePool(),
        linkPool: LinkPool = LinkPool()
    ) {
        let safeWidth = max(1, width)
        let safeHeight = max(1, height)
        self.width = safeWidth
        self.height = safeHeight
        self.backgroundColor = backgroundColor
        self.capabilities = capabilities
        self.cursorState = cursorState
        self.graphemePool = graphemePool
        self.linkPool = linkPool

        let backdrop = Self.opaqueBackdrop(from: backgroundColor)
        self.currentBuffer = OptimizedBuffer(
            width: safeWidth,
            height: safeHeight,
            widthMethod: widthMethod,
            id: "current buffer",
            graphemePool: graphemePool,
            linkPool: linkPool
        )
        self.nextBuffer = OptimizedBuffer(
            width: safeWidth,
            height: safeHeight,
            widthMethod: widthMethod,
            blendBackdropColor: backdrop,
            id: "next buffer",
            graphemePool: graphemePool,
            linkPool: linkPool
        )
        self.paletteRGBA = Self.buildDefaultAnsi256Palette()

        self.currentBuffer.clear(bg: backgroundColor, char: Self.clearCharSentinel)
        self.nextBuffer.clear(bg: backgroundColor, char: defaultSpaceChar)
    }

    private static func opaqueBackdrop(from color: RGBA) -> RGBA {
        let (r, g, b, _) = color.toInts()
        return RGBA.fromInts(Int(r), Int(g), Int(b), 255)
    }

    private static func buildDefaultAnsi256Palette() -> [RGBA] {
        var palette: [RGBA] = []
        palette.reserveCapacity(256)
        for index in 0..<256 {
            if let rgb = try? ansi256IndexToRgb(index) {
                palette.append(RGBA.fromInts(Int(rgb.r), Int(rgb.g), Int(rgb.b), 255))
            } else {
                palette.append(RGBA.fromInts(0, 0, 0, 255))
            }
        }
        return palette
    }

    public func setBackgroundColor(_ color: RGBA) {
        backgroundColor = color
        nextBuffer.blendBackdropColor = Self.opaqueBackdrop(from: color)
    }

    public func setPalette(_ palette: [RGBA]) {
        paletteRGBA = Self.buildDefaultAnsi256Palette()
        let copyLen = min(palette.count, 256)
        for i in 0..<copyLen {
            paletteRGBA[i] = palette[i]
        }
        paletteIndexCache.removeAll(keepingCapacity: true)
        forceFullRepaint = true
    }

    public func invalidate() {
        forceFullRepaint = true
        lastCursorStyle = nil
        lastCursorBlinking = nil
        lastCursorColorRGB = nil
        lastCursorX = nil
        lastCursorY = nil
        lastCursorVisible = nil
    }

    public func resize(width newWidth: Int, height newHeight: Int) throws(BufferError) {
        guard newWidth > 0 && newHeight > 0 else {
            throw .invalidDimensions
        }
        if newWidth == width && newHeight == height { return }

        try currentBuffer.resize(width: newWidth, height: newHeight)
        try nextBuffer.resize(width: newWidth, height: newHeight)
        width = newWidth
        height = newHeight

        nextBuffer.blendBackdropColor = Self.opaqueBackdrop(from: backgroundColor)
        currentBuffer.clear(bg: RGBA.fromInts(0, 0, 0, 255), char: Self.clearCharSentinel)
        nextBuffer.clear(bg: backgroundColor, char: defaultSpaceChar)
        invalidate()
    }

    // MARK: - ANSI Emission Helpers

    private func nearestPaletteIndex(_ rgba: RGBA) -> UInt8 {
        let (r, g, b, _) = rgba.toInts()
        let key = (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
        if let cached = paletteIndexCache[key] {
            return cached
        }
        var bestIndex: UInt8 = 0
        var bestDist = Int.max
        for i in 0..<paletteRGBA.count {
            let (cr, cg, cb, _) = paletteRGBA[i].toInts()
            let dr = Int(r) - Int(cr)
            let dg = Int(g) - Int(cg)
            let db = Int(b) - Int(cb)
            let dist = dr * dr + dg * dg + db * db
            if dist < bestDist {
                bestDist = dist
                bestIndex = UInt8(i)
            }
        }
        paletteIndexCache[key] = bestIndex
        return bestIndex
    }

    private func emitColor(into out: inout String, rgba: RGBA, isBackground: Bool) {
        if rgba.intent == .default {
            out.append(isBackground ? "\u{1B}[49m" : "\u{1B}[39m")
            return
        }

        let (r, g, b, a) = rgba.toInts()
        if isBackground && a == 0 {
            out.append("\u{1B}[49m")
            return
        }

        if rgba.intent == .indexed && capabilities.ansi256 {
            let slot = rgba.slot
            out.append(isBackground ? "\u{1B}[48;5;\(slot)m" : "\u{1B}[38;5;\(slot)m")
            return
        }

        if !capabilities.rgb && capabilities.ansi256 {
            let index = nearestPaletteIndex(rgba)
            out.append(isBackground ? "\u{1B}[48;5;\(index)m" : "\u{1B}[38;5;\(index)m")
            return
        }

        if isBackground {
            out.append("\u{1B}[48;2;\(r);\(g);\(b)m")
        } else {
            out.append("\u{1B}[38;2;\(r);\(g);\(b)m")
        }
    }

    private func emitAttributes(into out: inout String, attributes: UInt32) {
        let base = getBaseAttributes(attributes)
        if (base & TextAttributes.bold) != 0 { out.append("\u{1B}[1m") }
        if (base & TextAttributes.dim) != 0 { out.append("\u{1B}[2m") }
        if (base & TextAttributes.italic) != 0 { out.append("\u{1B}[3m") }
        if (base & TextAttributes.underline) != 0 { out.append("\u{1B}[4m") }
        if (base & TextAttributes.blink) != 0 { out.append("\u{1B}[5m") }
        if (base & TextAttributes.inverse) != 0 { out.append("\u{1B}[7m") }
        if (base & TextAttributes.hidden) != 0 { out.append("\u{1B}[8m") }
        if (base & TextAttributes.strikethrough) != 0 { out.append("\u{1B}[9m") }
    }

    private func beginFrame(into out: inout String) {
        if capabilities.synchronizedOutput {
            out.append(Self.syncSet)
        }
        out.append(Self.hideCursor)
    }

    private func rowEquals(row y: Int) -> Bool {
        let rowStart = y * width
        let rowEnd = rowStart + width
        let cChars = currentBuffer.chars
        let nChars = nextBuffer.chars
        let cFg = currentBuffer.fg
        let nFg = nextBuffer.fg
        let cBg = currentBuffer.bg
        let nBg = nextBuffer.bg
        let cAttrs = currentBuffer.attributes
        let nAttrs = nextBuffer.attributes

        for idx in rowStart..<rowEnd {
            if cChars[idx] != nChars[idx]
                || cAttrs[idx] != nAttrs[idx]
                || cFg[idx] != nFg[idx]
                || cBg[idx] != nBg[idx]
            {
                return false
            }
        }
        return true
    }

    private static func cursorStyleSequence(style: CursorRenderStyle, blinking: Bool) -> String {
        switch style {
        case .block:
            return blinking ? "\u{1B}[1 q" : "\u{1B}[2 q"
        case .line:
            return blinking ? "\u{1B}[5 q" : "\u{1B}[6 q"
        case .underline:
            return blinking ? "\u{1B}[3 q" : "\u{1B}[4 q"
        case .default:
            return "\u{1B}[0 q"
        }
    }

    private static func hex2(_ byte: UInt8) -> String {
        let digits: [UInt8] = Array("0123456789abcdef".utf8)
        return String(decoding: [digits[Int(byte >> 4)], digits[Int(byte & 0xF)]], as: UTF8.self)
    }

    // MARK: - Diff & Render

    /// Diffs `nextBuffer` against `currentBuffer`, syncs updated cells into `currentBuffer`,
    /// and returns the minimal ANSI escape sequence stream for this frame (empty on no-op frames).
    ///
    /// - Parameters:
    ///   - force: When `true`, repaints every cell regardless of `currentBuffer` equality.
    ///   - clearNextAfterRender: When `true` (default), clears `nextBuffer` after diffing
    ///     just like upstream `CliRenderer`. Pass `false` for retained-mode diffing.
    public func render(force: Bool = false, clearNextAfterRender: Bool = true) -> String {
        var out = ""
        let shouldForce = force || forceFullRepaint
        var frameStarted = false

        var cellsUpdated = 0
        var rowsCompared = 0
        var rowsDiffed = 0

        var activeFg: RGBA? = nil
        var activeBg: RGBA? = nil
        var activeBaseAttrs: UInt32? = nil
        var activeLinkId: UInt32 = 0

        // Track terminal cursor position (0-based cell coords) so contiguous cells skip CUP moves.
        var cursorCol: Int = -1
        var cursorRow: Int = -1

        let hyperlinksEnabled = capabilities.hyperlinks

        for y in 0..<height {
            if !shouldForce {
                rowsCompared += 1
                if rowEquals(row: y) {
                    continue
                }
            }
            rowsDiffed += 1

            let rowStart = y * width
            for x in 0..<width {
                let idx = rowStart + x
                let nextCell = TerminalCell(
                    scalar: nextBuffer.chars[idx],
                    foreground: nextBuffer.fg[idx],
                    background: nextBuffer.bg[idx],
                    attributes: nextBuffer.attributes[idx]
                )

                if !shouldForce {
                    let same = currentBuffer.chars[idx] == nextCell.scalar
                        && currentBuffer.attributes[idx] == nextCell.attributes
                        && currentBuffer.fg[idx] == nextCell.foreground
                        && currentBuffer.bg[idx] == nextCell.background
                    if same {
                        continue
                    }
                }

                // Continuation cells emit no bytes; sync them to front buffer and move on.
                if isContinuationChar(nextCell.scalar) {
                    currentBuffer.syncCell(x: x, y: y, cell: nextCell)
                    cellsUpdated += 1
                    continue
                }

                if !frameStarted {
                    beginFrame(into: &out)
                    frameStarted = true
                }

                // Minimal cursor positioning: only emit CUP if terminal cursor is not already at (x, y).
                if cursorRow != y || cursorCol != x {
                    out.append(ANSI.moveCursor(row: y + 1 + renderOffset, col: x + 1))
                    cursorRow = y
                    cursorCol = x
                }

                // OSC 8 hyperlink transition
                let nextLinkId = hyperlinksEnabled ? getLinkId(nextCell.attributes) : 0
                if hyperlinksEnabled && nextLinkId != activeLinkId {
                    if activeLinkId != 0 {
                        out.append("\u{1B}]8;;\u{1B}\\")
                    }
                    activeLinkId = nextLinkId
                    if activeLinkId != 0 {
                        if let url = try? nextBuffer.linkPool.get(activeLinkId) {
                            out.append("\u{1B}]8;id=\(activeLinkId);\(url)\u{1B}\\")
                        } else {
                            activeLinkId = 0
                        }
                    }
                }

                // Minimal SGR style transition
                let nextBaseAttrs = getBaseAttributes(nextCell.attributes)
                let fgChanged = activeFg != nextCell.foreground
                let bgChanged = activeBg != nextCell.background
                let attrsChanged = activeBaseAttrs != nextBaseAttrs

                if fgChanged || bgChanged || attrsChanged {
                    let prevAttrs = activeBaseAttrs ?? 0
                    let needsReset = (prevAttrs & ~nextBaseAttrs) != 0
                    if needsReset {
                        out.append(ANSI.reset)
                        emitColor(into: &out, rgba: nextCell.foreground, isBackground: false)
                        emitColor(into: &out, rgba: nextCell.background, isBackground: true)
                        if nextBaseAttrs != 0 {
                            emitAttributes(into: &out, attributes: nextBaseAttrs)
                        }
                    } else {
                        if fgChanged {
                            emitColor(into: &out, rgba: nextCell.foreground, isBackground: false)
                        }
                        if bgChanged {
                            emitColor(into: &out, rgba: nextCell.background, isBackground: true)
                        }
                        let addedAttrs = nextBaseAttrs & ~prevAttrs
                        if addedAttrs != 0 {
                            emitAttributes(into: &out, attributes: addedAttrs)
                        }
                    }
                    activeFg = nextCell.foreground
                    activeBg = nextCell.background
                    activeBaseAttrs = nextBaseAttrs
                }

                // Emit glyph bytes
                let glyphAdvance: Int
                if isGraphemeChar(nextCell.scalar) {
                    let gid = graphemeIdFromChar(nextCell.scalar)
                    let graphemeWidth = Int(charRightExtent(nextCell.scalar)) + 1
                    glyphAdvance = graphemeWidth
                    if let text = try? graphemePool.getString(gid), !text.isEmpty {
                        if capabilities.explicitWidth {
                            let clampedW = min(graphemeWidth, 7)
                            out.append("\u{1B}]66;w=\(clampedW);\(text)\u{1B}\\")
                            if graphemeWidth > 7 {
                                out.append(String(repeating: " ", count: graphemeWidth - 7))
                            }
                        } else {
                            out.append(text)
                            if capabilities.explicitCursorPositioning {
                                let nextX = x + graphemeWidth
                                if nextX < width {
                                    out.append(ANSI.moveCursor(row: y + 1 + renderOffset, col: nextX + 1))
                                }
                            }
                        }
                    } else {
                        out.append(" ")
                    }
                } else if isImageChar(nextCell.scalar) {
                    out.append(" ")
                    glyphAdvance = 1
                } else {
                    if nextCell.scalar >= 32 && nextCell.scalar <= 126 {
                        out.unicodeScalars.append(Unicode.Scalar(nextCell.scalar)!)
                    } else if nextCell.scalar != 0, let scalar = Unicode.Scalar(nextCell.scalar) {
                        out.unicodeScalars.append(scalar)
                    } else {
                        out.append(" ")
                    }
                    glyphAdvance = 1
                }

                cursorCol += glyphAdvance
                currentBuffer.syncCell(x: x, y: y, cell: nextCell)
                cellsUpdated += 1
            }
        }

        if hyperlinksEnabled && activeLinkId != 0 {
            if !frameStarted {
                beginFrame(into: &out)
                frameStarted = true
            }
            out.append("\u{1B}]8;;\u{1B}\\")
        }

        if frameStarted {
            out.append(ANSI.reset)
        }

        // Cursor state diffing & restoration
        if cursorState.visible {
            let styleChanged = lastCursorStyle != cursorState.style || lastCursorBlinking != cursorState.blinking
            let targetRGB: RGBTriplet?
            if let color = cursorState.color {
                let (r, g, b, _) = color.toInts()
                targetRGB = RGBTriplet(r, g, b)
            } else {
                targetRGB = nil
            }
            let colorChanged = targetRGB != nil && lastCursorColorRGB != targetRGB
            let cursorX = cursorState.x
            let cursorY = cursorState.y + renderOffset
            let positionChanged = lastCursorX != cursorX || lastCursorY != cursorY
            let visibilityChanged = lastCursorVisible != true

            if frameStarted || styleChanged || colorChanged || positionChanged || visibilityChanged {
                if !frameStarted {
                    beginFrame(into: &out)
                    frameStarted = true
                }
                if colorChanged, let rgb = targetRGB {
                    out.append("\u{1B}]12;#\(Self.hex2(rgb.r))\(Self.hex2(rgb.g))\(Self.hex2(rgb.b))\u{07}")
                    lastCursorColorRGB = rgb
                }
                if styleChanged {
                    out.append(Self.cursorStyleSequence(style: cursorState.style, blinking: cursorState.blinking))
                    lastCursorStyle = cursorState.style
                    lastCursorBlinking = cursorState.blinking
                }
                out.append(ANSI.moveCursor(row: cursorY, col: cursorX))
                out.append(Self.showCursor)
            }

            lastCursorX = cursorX
            lastCursorY = cursorY
            lastCursorVisible = true
        } else {
            if !frameStarted && (lastCursorVisible == nil || lastCursorVisible == true) {
                beginFrame(into: &out)
                frameStarted = true
                out.append(Self.hideCursor)
            }
            lastCursorStyle = nil
            lastCursorBlinking = nil
            lastCursorColorRGB = nil
            lastCursorX = nil
            lastCursorY = nil
            lastCursorVisible = false
        }

        if frameStarted && capabilities.synchronizedOutput {
            out.append(Self.syncReset)
        }

        forceFullRepaint = false
        stats.frameCount += 1
        stats.cellsUpdated = cellsUpdated
        stats.rowsCompared = rowsCompared
        stats.rowsDiffed = rowsDiffed
        stats.bytesEmitted = out.utf8.count

        if clearNextAfterRender {
            nextBuffer.clear(bg: backgroundColor, char: defaultSpaceChar)
        }

        return out
    }

    /// Convenience wrapper returning UTF-8 bytes for `render(force:clearNextAfterRender:)`.
    public func renderBytes(force: Bool = false, clearNextAfterRender: Bool = true) -> [UInt8] {
        Array(render(force: force, clearNextAfterRender: clearNextAfterRender).utf8)
    }
}
