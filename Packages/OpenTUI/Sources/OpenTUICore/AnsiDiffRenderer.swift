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
// parity: native/src/renderer.zig#CliRenderer [status=adapted hash=3edebfbadba4]
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

    // Native CliRenderer parity subsystem state (`native/src/renderer.zig`)
    public var terminal: NativeTerminalState = NativeTerminalState()
    public var kittyTransport: NativeKittyTransport.Transport = NativeKittyTransport.Transport()
    public var splitScrollback: NativeSplitScrollback = NativeSplitScrollback()
    public var pendingSplitFooterTransition: NativeRendererBridge.SplitFooterTransition = NativeRendererBridge.SplitFooterTransition()
    public var backend: NativeRendererOutput.FeedBackend? = nil
    public private(set) var debugOverlayEnabled: Bool = false
    public private(set) var debugOverlayCorner: DebugOverlayCorner = .bottomRight
    public private(set) var paletteEpoch: UInt32 = 0
    public private(set) var defaultFgRGBA: RGBA = RGBA.fromInts(255, 255, 255, 255)
    public private(set) var defaultBgRGBA: RGBA = RGBA.fromInts(0, 0, 0, 255)
    public private(set) var nextSceneRetained: Bool = false
    public private(set) var retainedFrameId: UInt64 = 0
    public private(set) var retainedLost: UInt32 = 0
    public private(set) var encodeAllRows: Bool = false
    public private(set) var mousePointerStateValid: Bool = false
    public private(set) var lastFrameCostUs: UInt32 = 0
    public private(set) var pendingImageUploads: UInt32 = 0
    public private(set) var pendingPresentationActive: Bool = false
    public private(set) var presentationFailed: Bool = false
    public private(set) var terminalSuspended: Bool = false
    public private(set) var overallFrameTime: Double = 0
    public private(set) var lastFps: UInt32 = 0
    public private(set) var frameCallbackTime: Double = 0
    public private(set) var heapUsed: UInt32 = 0
    public private(set) var heapTotal: UInt32 = 0
    public private(set) var arrayBuffers: UInt32 = 0
    public private(set) var lastFrameWork: NativeRendererBridge.FrameWork = NativeRendererBridge.FrameWork()
    private var lastFrameTimeSamples: [Double] = []
    private var cellsUpdatedSamples: [UInt32] = []
    private var kittyHistoryNextImageId: UInt32 = 1
    private var committedKittyImageIds: [UInt32] = []

    public enum PresentationError: Error, Equatable, Hashable, Sendable {
        case presentationPending
        case presentationFailed
        case incompatibleOutput
        case splitRenderPending
        case noPendingPresentation
        case invalidDimensions
        case outOfMemory
    }

    public enum ResolvedImageProtocol: UInt8, Equatable, Hashable, Sendable {
        case fallback = 0
        case kitty = 1
        case sixel = 2
    }

    // parity: native/src/renderer.zig#CliRenderer.createWithOptions [status=adapted hash=ed9c50a5de4a]
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

    // parity: native/src/renderer.zig#CliRenderer.setBackgroundColor [status=implemented hash=bf64fd48e85f]
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

    // parity: native/src/renderer.zig#CliRenderer.setPaletteState [status=implemented hash=4f4b37ab6f7c]
    public func setPaletteState(
        palette: [RGBA],
        defaultFg: RGBA,
        defaultBg: RGBA,
        paletteEpoch newEpoch: UInt32
    ) {
        paletteRGBA = Self.buildDefaultAnsi256Palette()
        let copyLen = min(palette.count, 256)
        for i in 0..<copyLen {
            paletteRGBA[i] = palette[i]
        }
        defaultFgRGBA = defaultFg
        defaultBgRGBA = defaultBg
        if paletteEpoch != newEpoch {
            paletteEpoch = newEpoch
            forceFullRepaint = true
            paletteIndexCache.removeAll(keepingCapacity: true)
        }
    }

    // parity: native/src/renderer.zig#CliRenderer.invalidateTerminalState [status=implemented hash=2892a781f617]
    public func invalidate() {
        forceFullRepaint = true
        lastCursorStyle = nil
        lastCursorBlinking = nil
        lastCursorColorRGB = nil
        lastCursorX = nil
        lastCursorY = nil
        lastCursorVisible = nil
        mousePointerStateValid = false
    }

    // parity: native/src/renderer.zig#CliRenderer.resize [status=implemented hash=3282f9d54885]
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
        nextSceneRetained = false
        taint(NativeRendererBridge.FrameWork.fullPathUnretained)
        let cursor = terminal.getCursorPosition()
        terminal.setCursorPosition(
            x: min(cursor.x, UInt32(newWidth)),
            y: min(cursor.y, UInt32(newHeight)),
            visible: cursor.visible
        )
        invalidate()
    }

    // parity: native/src/renderer.zig#CliRenderer.resizeWithOutput [status=implemented hash=48b9dde8291e]
    public func resizeWithOutput(
        width newWidth: Int,
        height newHeight: Int,
        bytes: [UInt8]? = nil
    ) throws(PresentationError) {
        if pendingPresentationActive { throw .presentationPending }
        if presentationFailed { throw .presentationFailed }
        if newWidth == width && newHeight == height {
            if let packet = bytes, !packet.isEmpty {
                backend?.writeOut(packet)
            }
            return
        }
        guard newWidth > 0 && newHeight > 0 else { throw .invalidDimensions }
        do {
            try resize(width: newWidth, height: newHeight)
        } catch {
            throw .invalidDimensions
        }
        if let packet = bytes, !packet.isEmpty {
            backend?.writeOut(packet)
        }
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

    // MARK: - Native CliRenderer Parity Methods (`native/src/renderer.zig`)

    // parity: native/src/renderer.zig#CliRenderer.destroyStorage [status=implemented hash=bafdf6c4ee06]
    public func destroyStorage() {
        kittyTransport.cancel(reason: .cancelled)
        committedKittyImageIds.removeAll(keepingCapacity: false)
        backend?.deinitBackend()
        currentBuffer.destroy()
        nextBuffer.destroy()
        paletteIndexCache.removeAll(keepingCapacity: false)
        pendingPresentationActive = false
    }

    // parity: native/src/renderer.zig#CliRenderer.writeShutdownImage [status=implemented hash=da6b67449535]
    public func writeShutdownImage<S: NativeTerminalByteSink>(
        into writer: inout S,
        index: Int
    ) throws(NativeANSI.AnsiError) {
        guard index >= 0 && index < committedKittyImageIds.count else { return }
        let imageId = committedKittyImageIds[index]
        let seq = NativeZigTerminalImage.writeKittyDelete(
            id: imageId,
            placementId: nil,
            freeImage: true,
            tmux: terminal.isInTmux()
        )
        try writer.writeString(seq)
    }

    // parity: native/src/renderer.zig#CliRenderer.updateStats [status=implemented hash=efff314b4833]
    public func updateStats(time: Double, fps: UInt32, frameCallbackTime callbackTime: Double) {
        self.overallFrameTime = time
        self.lastFps = fps
        self.frameCallbackTime = callbackTime
        lastFrameTimeSamples.append(time)
        if lastFrameTimeSamples.count > 60 {
            lastFrameTimeSamples.removeFirst(lastFrameTimeSamples.count - 60)
        }
    }

    // parity: native/src/renderer.zig#CliRenderer.updateMemoryStats [status=implemented hash=1ecdb4d5b4ba]
    public func updateMemoryStats(heapUsed: UInt32, heapTotal: UInt32, arrayBuffers: UInt32) {
        self.heapUsed = heapUsed
        self.heapTotal = heapTotal
        self.arrayBuffers = arrayBuffers
    }

    // parity: native/src/renderer.zig#CliRenderer.getRenderStats [status=implemented hash=73a5fce25979]
    public func getRenderStats() -> NativeRendererBridge.RenderStatsSnapshot {
        let avgFrameTime: Double = lastFrameTimeSamples.isEmpty
            ? overallFrameTime
            : lastFrameTimeSamples.reduce(0, +) / Double(lastFrameTimeSamples.count)
        let avgCells: UInt32 = cellsUpdatedSamples.isEmpty
            ? UInt32(clamping: stats.cellsUpdated)
            : UInt32(cellsUpdatedSamples.reduce(UInt64(0)) { $0 + UInt64($1) } / UInt64(cellsUpdatedSamples.count))
        return NativeRendererBridge.RenderStatsSnapshot(
            lastFrameTime: overallFrameTime,
            averageFrameTime: avgFrameTime,
            frameCount: stats.frameCount,
            cellsUpdated: UInt32(clamping: stats.cellsUpdated),
            averageCellsUpdated: avgCells,
            renderTime: nil,
            outputWriteTime: backend?.lastWriteTimeUs,
            frameWork: lastFrameWork
        )
    }

    // parity: native/src/renderer.zig#CliRenderer.clearSkippedFrameState [status=implemented hash=d44329249d3d]
    public func clearSkippedFrameState() {
        nextBuffer.clear(bg: backgroundColor, char: defaultSpaceChar)
        nextSceneRetained = false
        taint(NativeRendererBridge.FrameWork.fullPathUnretained)
    }

    // parity: native/src/renderer.zig#CliRenderer.taint [status=implemented hash=ee032cbe0694]
    public func taint(_ reason: UInt32) {
        retainedFrameId = 0
        retainedLost |= reason
        encodeAllRows = true
    }

    // parity: native/src/renderer.zig#CliRenderer.leaveRetained [status=implemented hash=d1ec5963c5c9]
    public func leaveRetained() {
        taint(NativeRendererBridge.FrameWork.fullPathTainted)
        guard nextSceneRetained else { return }
        nextBuffer.clear(bg: backgroundColor, char: defaultSpaceChar)
        nextSceneRetained = false
    }

    // parity: native/src/renderer.zig#CliRenderer.renderDeferred [status=implemented hash=9124215dd4ff]
    public func renderDeferred(force: Bool = false) throws(PresentationError) -> RenderStatus {
        if pendingPresentationActive { throw .presentationPending }
        if presentationFailed { throw .presentationFailed }
        if pendingSplitFooterTransition.mode != .none { throw .splitRenderPending }
        if let activeBackend = backend, activeBackend.frameActive { throw .incompatibleOutput }
        if let activeBackend = backend {
            let status = NativeRendererBridge.renderFrame(renderer: self, backend: activeBackend, force: force)
            if status == .rendered {
                pendingPresentationActive = true
                cellsUpdatedSamples.append(UInt32(clamping: stats.cellsUpdated))
                if cellsUpdatedSamples.count > 60 { cellsUpdatedSamples.removeFirst() }
            }
            return status
        }
        _ = renderBytes(force: force)
        pendingPresentationActive = true
        return .rendered
    }

    // parity: native/src/renderer.zig#CliRenderer.renderSplitDeferred [status=implemented hash=82df71917d9d]
    public func renderSplitDeferred(
        split: NativeRendererBridge.SplitRender,
        force: Bool = false
    ) throws(PresentationError) -> RenderStatus {
        if pendingPresentationActive { throw .presentationPending }
        if presentationFailed { throw .presentationFailed }
        if let activeBackend = backend, activeBackend.frameActive { throw .incompatibleOutput }
        for snap in split.snapshots {
            splitScrollback.publishSnapshotRows(
                rowCount: UInt32(max(0, snap.snapshot.height)),
                rowColumns: snap.rowColumns,
                terminalWidth: UInt32(max(1, width)),
                trailingNewline: snap.trailingNewline
            )
        }
        renderOffset = Int(splitScrollback.renderOffset(surfaceOffset: split.pinnedRenderOffset))
        if split.suspended {
            return .skipped
        }
        if !split.paintFooter {
            return .rendered
        }
        return try renderDeferred(force: force)
    }

    // parity: native/src/renderer.zig#CliRenderer.completePresentation [status=implemented hash=1eba1866aacf]
    public func completePresentation(outcome: PresentationOutcome) throws(PresentationError) {
        guard pendingPresentationActive else { throw .noPendingPresentation }
        pendingPresentationActive = false
        if outcome == .failed {
            presentationFailed = true
            kittyTransport.cancel(reason: .ioError)
            invalidate()
            return
        }
        kittyTransport.finishFrame(published: true)
    }

    // parity: native/src/renderer.zig#CliRenderer.imageFrameCostUs [status=implemented hash=19dedec729c6]
    public func imageFrameCostUs() -> UInt32 {
        imageUploadsPending() != 0 ? UInt32.max : lastFrameCostUs
    }

    // parity: native/src/renderer.zig#CliRenderer.resetSplitScrollback [status=implemented hash=69ee1b052dc5]
    @discardableResult
    public func resetSplitScrollback(seedRows: UInt32, pinnedRenderOffset: UInt32) -> UInt32 {
        precondition(!pendingPresentationActive)
        splitScrollback.reset(seedRows: seedRows)
        let offset = splitScrollback.renderOffset(surfaceOffset: pinnedRenderOffset)
        renderOffset = Int(offset)
        return offset
    }

    // parity: native/src/renderer.zig#CliRenderer.syncSplitScrollback [status=implemented hash=7350272a1302]
    @discardableResult
    public func syncSplitScrollback(pinnedRenderOffset: UInt32) -> UInt32 {
        precondition(!pendingPresentationActive)
        let outputOffset = splitScrollback.renderOffset(surfaceOffset: pinnedRenderOffset)
        let clamped = min(max(UInt32(max(0, renderOffset)), outputOffset), pinnedRenderOffset)
        renderOffset = Int(clamped)
        return clamped
    }

    // parity: native/src/renderer.zig#CliRenderer.getSplitOutputOffset [status=implemented hash=1b00e1f68438]
    public func getSplitOutputOffset(surfaceOffset: UInt32) -> UInt32 {
        splitScrollback.renderOffset(surfaceOffset: surfaceOffset)
    }

    // parity: native/src/renderer.zig#CliRenderer.clearPendingSplitFooterTransition [status=implemented hash=fd6335be9db2]
    public func clearPendingSplitFooterTransition() {
        precondition(!pendingPresentationActive)
        pendingSplitFooterTransition.clear()
    }

    // parity: native/src/renderer.zig#CliRenderer.getNextBuffer [status=implemented hash=b84006572835]
    public func getNextBuffer() -> OptimizedBuffer {
        nextBuffer
    }

    // parity: native/src/renderer.zig#CliRenderer.getCurrentBuffer [status=implemented hash=73ed21814db6]
    public func getCurrentBuffer() -> OptimizedBuffer {
        currentBuffer
    }

    // parity: native/src/renderer.zig#CliRenderer.resolveImageProtocol [status=implemented hash=3ead1a4887d2]
    public func resolveImageProtocol(requested: NativeZigImage.RenderProtocol) -> ResolvedImageProtocol {
        let configured: NativeTerminalState.ImageProtocol
        switch requested {
        case .auto: configured = terminal.imageProtocol
        case .kitty: configured = .kitty
        case .sixel: configured = .sixel
        case .blocks: configured = .blocks
        }
        if configured == .sixel && terminal.refusesForcedSixel() {
            return .fallback
        }
        switch configured {
        case .kitty: return .kitty
        case .sixel: return .sixel
        case .blocks: return .fallback
        case .auto: break
        }
        if terminal.isInTmux() { return .fallback }
        let caps = terminal.getCapabilities()
        if caps.kittyGraphics { return .kitty }
        if caps.sixel { return .sixel }
        return .fallback
    }

    // parity: native/src/renderer.zig#CliRenderer.imageUploadsPending [status=implemented hash=9fd580d51583]
    public func imageUploadsPending() -> UInt32 {
        pendingImageUploads
    }

    // parity: native/src/renderer.zig#CliRenderer.prepareRenderFrameWithWriter [status=implemented hash=7bd7cfca3c0b]
    public func prepareRenderFrameWithWriter<S: NativeTerminalByteSink>(
        into writer: inout S,
        force: Bool = false,
        syncStarted: Bool = false
    ) throws(PresentationError) {
        if pendingPresentationActive { throw .presentationPending }
        if presentationFailed { throw .presentationFailed }
        let bytes = renderBytes(force: force)
        do {
            if !syncStarted && capabilities.synchronizedOutput && !bytes.isEmpty {
                try writer.writeBytes(bytes)
            } else {
                try writer.writeBytes(bytes)
            }
        } catch {
            throw .presentationFailed
        }
    }

    // parity: native/src/renderer.zig#CliRenderer.setDebugOverlay [status=implemented hash=cb858a7227e4]
    public func setDebugOverlay(enabled: Bool, corner: DebugOverlayCorner) {
        debugOverlayEnabled = enabled
        debugOverlayCorner = corner
    }

    // parity: native/src/renderer.zig#CliRenderer.setTerminalEnvVar [status=implemented hash=b0ea1150173c]
    @discardableResult
    public func setTerminalEnvVar(key: String, value: String) -> Bool {
        terminal.setHostEnvVar(key: key, value: value)
        syncWidthMethod()
        return true
    }

    // parity: native/src/renderer.zig#CliRenderer.syncWidthMethod [status=implemented hash=0340cd4aeb51]
    public func syncWidthMethod() {
        let widthMethod: WidthMethod = terminal.caps.unicode == .noZWJ ? .unicode : terminal.caps.unicode
        if widthMethod != nextBuffer.widthMethod {
            taint(NativeRendererBridge.FrameWork.fullPathUnretained)
        }
        currentBuffer.widthMethod = widthMethod
        nextBuffer.widthMethod = widthMethod
    }

    // parity: native/src/renderer.zig#CliRenderer.setKittyImageTransport [status=implemented hash=a2fa0d807714]
    @discardableResult
    public func setKittyImageTransport(mode: UInt32) -> Bool {
        guard let requested = NativeKittyTransport.Mode(rawValue: mode) else { return false }
        if kittyTransport.mode == requested { return true }
        kittyTransport.mode = requested
        forceFullRepaint = true
        return true
    }

    // parity: native/src/renderer.zig#CliRenderer.startKittyFileProbeFromSession [status=implemented hash=5375055dcaa4]
    public func startKittyFileProbeFromSession(directory: String = "/tmp", nowNs: UInt64? = nil) {
        guard !terminalSuspended && kittyTransport.mode == .file else { return }
        _ = pollKittyImageTransport(nowNs: nowNs)
        guard kittyTransport.fileState == .disabled else { return }
        let base = kittyHistoryNextImageId
        kittyHistoryNextImageId &+= 2
        if let seq = try? kittyTransport.startProbe(firstId: base &+ 1, directory: directory) {
            if let nowNs {
                kittyTransport.arm(nowNs: nowNs)
            }
            if !seq.isEmpty {
                backend?.writeOut(seq)
            }
        }
    }

    // parity: native/src/renderer.zig#CliRenderer.kittyImageTransportStatus [status=implemented hash=4075ce9176a6]
    public func kittyImageTransportStatus() -> [UInt32] {
        [
            kittyTransport.mode.rawValue,
            UInt32(kittyTransport.effective.rawValue),
            kittyTransport.fileState.rawValue,
            kittyTransport.fallback.rawValue,
            kittyTransport.pendingCount(),
            UInt32(clamping: kittyTransport.pendingBytes()),
        ]
    }

    // parity: native/src/renderer.zig#CliRenderer.cancelKittyImageTransport [status=implemented hash=39e86217bc37]
    public func cancelKittyImageTransport(failed: Bool) {
        kittyTransport.cancel(reason: failed ? .ioError : .cancelled)
        _ = pollKittyImageTransport()
    }

    // parity: native/src/renderer.zig#CliRenderer.pollKittyImageTransport [status=implemented hash=9698e729c37b]
    @discardableResult
    public func pollKittyImageTransport(nowNs: UInt64? = nil) -> Bool {
        #if os(Windows)
        kittyTransport.cancel(reason: .unsupported)
        #else
        if terminal.remote || terminal.multiplexer != .none || !terminal.graphicsEnabled {
            kittyTransport.cancel(reason: .unsupported)
        }
        #endif
        if let nowNs {
            kittyTransport.expire(nowNs: nowNs)
        }
        guard kittyTransport.retryImages else { return false }
        kittyTransport.retryImages = false
        forceFullRepaint = true
        return true
    }

    // parity: native/src/renderer.zig#CliRenderer.processKittyImageReply [status=implemented hash=41bbf5312efa]
    public func processKittyImageReply(_ response: [UInt8]) -> UInt32 {
        guard kittyTransport.handleReply(response) else { return 0 }
        return pollKittyImageTransport() ? 2 : 1
    }
}
