import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout

// MARK: - Internal Conversion Helpers

internal func textBufferWidthMethod(_ method: WidthMethod) -> TextWidthMethod {
    switch method {
    case .wcwidth: return .wcwidth
    case .unicode, .noZWJ: return .unicode
    case .unicodeWide: return .unicodeWide
    }
}

internal func textBufferWheelDirection(_ direction: ScrollDirection) -> WheelDirection {
    switch direction {
    case .up: return .up
    case .down: return .down
    case .left: return .left
    case .right: return .right
    }
}

// MARK: - Shared TextBufferView -> OptimizedBuffer Renderer

private struct ChunkUTF8Span {
    let utf8Start: Int
    let utf8End: Int
    let chunk: TextChunk
}

/// Renders a `TextBufferView` (wrapped virtual lines, per-chunk colors/attributes/hyperlinks,
/// alignment, horizontal scroll, tab indicators, and selection highlights) directly into `buffer`.
internal func drawTextBufferView(
    _ view: TextBufferView,
    into buffer: OptimizedBuffer,
    x: Int,
    y: Int,
    clipWidth: Int? = nil,
    clipHeight: Int? = nil
) {
    guard !view.isDestroyed && !view.textBuffer.isDestroyed else { return }

    let textBuffer = view.textBuffer
    let vp = view.viewport
    let vpX = vp?.x ?? 0
    let effectiveWidth = clipWidth ?? vp?.width ?? max(0, buffer.width - x)
    let effectiveHeight = clipHeight ?? vp?.height ?? max(0, buffer.height - y)
    guard effectiveWidth > 0 && effectiveHeight > 0 else { return }

    let defaultFg = textBuffer.defaultFg ?? RGBA.fromValues(1, 1, 1, 1)
    let defaultBg = textBuffer.defaultBg ?? RGBA.fromValues(0, 0, 0, 0)
    let defaultAttrs = textBuffer.defaultAttributes ?? TextAttributes.none

    buffer.pushScissorRect(x: x, y: y, width: effectiveWidth, height: effectiveHeight)
    defer { buffer.popScissorRect() }

    if defaultBg.a > 0 {
        buffer.fillRect(x: x, y: y, width: effectiveWidth, height: effectiveHeight, bg: defaultBg)
    }

    let visibleLines = view.visibleVirtualLines()
    guard !visibleLines.isEmpty else { return }

    // Precompute UTF-8 byte spans for styled chunks so each virtual line slice can resolve
    // per-grapheme styles in O(n) without reallocating strings.
    let chunks = textBuffer.styledChunks
    var chunkSpans: [ChunkUTF8Span] = []
    chunkSpans.reserveCapacity(chunks.count)
    var byteCursor = 0
    for chunk in chunks {
        let len = chunk.text.utf8.count
        let end = byteCursor + len
        if len > 0 {
            chunkSpans.append(ChunkUTF8Span(utf8Start: byteCursor, utf8End: end, chunk: chunk))
        }
        byteCursor = end
    }

    let selection = view.getSelection()
    let selectionBg = view.selectionBgColor
    let selectionFg = view.selectionFgColor
    let tabWidth = textBuffer.getTabWidth()
    let tabIndicator = view.tabIndicator
    let tabIndicatorColor = view.tabIndicatorColor
    let widthMethod = buffer.widthMethod
    let textAlign = view.textAlign
    let firstLineOffset = view.firstLineOffset

    var chunkSpanHint = 0

    for (rowIdx, vline) in visibleLines.enumerated() {
        if rowIdx >= effectiveHeight { break }
        let destY = y + rowIdx
        if destY < 0 || destY >= buffer.height { continue }

        let indent = (vline.sourceLine == 0 && vline.wrapIndex == 0) ? firstLineOffset : 0
        let alignPad = alignmentPadCols(
            alignment: textAlign,
            viewportWidth: effectiveWidth,
            lineWidthCols: vline.widthCols + indent
        )
        let baseX = x + alignPad + indent - vpX

        // Advance hint to first chunk that could overlap vline.utf8Range
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

        var localChunkIdx = chunkSpanHint
        var byteOffsetInDoc = lineUTF8Start
        var colInLine = 0
        var docCellOffset = vline.documentCellOffset

        for ch in vline.text {
            let chUTF8Len = ch.utf8.count

            // Resolve styled chunk owning this grapheme's starting byte offset
            while localChunkIdx < chunkSpans.count && chunkSpans[localChunkIdx].utf8End <= byteOffsetInDoc {
                localChunkIdx += 1
            }
            let activeChunk: TextChunk? = (localChunkIdx < chunkSpans.count
                && byteOffsetInDoc >= chunkSpans[localChunkIdx].utf8Start
                && byteOffsetInDoc < chunkSpans[localChunkIdx].utf8End)
                ? chunkSpans[localChunkIdx].chunk
                : nil

            let resolvedFg = activeChunk?.fg ?? defaultFg
            let resolvedBg: RGBA? = activeChunk?.bg ?? (defaultBg.a > 0 ? defaultBg : nil)
            var resolvedAttrs = activeChunk?.attributes ?? defaultAttrs

            let graphemeWidth: Int
            if ch == "\t" {
                graphemeWidth = max(1, tabWidth)
            } else {
                let bytes = Array(String(ch).utf8)
                graphemeWidth = Int(getGraphemeWidthAt(
                    bytes,
                    byteOffset: 0,
                    tabWidth: UInt8(min(255, max(1, tabWidth))),
                    controlDisplay: .hidden,
                    widthMethod: widthMethod
                ))
            }

            let isSelected: Bool
            if let sel = selection {
                let gEnd = docCellOffset + max(1, graphemeWidth)
                isSelected = docCellOffset < sel.end && gEnd > sel.start
            } else {
                isSelected = false
            }

            var cellFg = resolvedFg
            var cellBg = resolvedBg
            if isSelected {
                if let selBg = selectionBg {
                    cellBg = selBg
                    cellFg = selectionFg ?? resolvedFg
                } else {
                    let baseBg = resolvedBg ?? RGBA.fromValues(0, 0, 0, 1)
                    cellFg = baseBg.a > 0 ? baseBg : RGBA.fromValues(0, 0, 0, 1)
                    cellBg = resolvedFg
                }
            }

            var retainedLinkId: UInt32? = nil
            if let url = activeChunk?.link?.url, let linkId = try? buffer.linkPool.acquire(url) {
                retainedLinkId = linkId
                resolvedAttrs = attributesWithLink(resolvedAttrs, linkId: linkId)
            }
            defer {
                if let linkId = retainedLinkId {
                    try? buffer.linkPool.decref(linkId)
                }
            }

            let drawX = baseX + colInLine
            if graphemeWidth > 0 && drawX + graphemeWidth > x && drawX < x + effectiveWidth {
                if ch == "\t" {
                    let indicatorChar = tabIndicator.map { String($0) } ?? " "
                    let indFg = isSelected ? cellFg : (tabIndicatorColor ?? cellFg)
                    for step in 0..<graphemeWidth {
                        let cellX = drawX + step
                        guard cellX >= x && cellX < x + effectiveWidth else { continue }
                        let s = (step == 0) ? indicatorChar : " "
                        let bgToUse = cellBg ?? RGBA.fromValues(0, 0, 0, 0)
                        buffer.setCellWithAlphaBlending(
                            x: cellX,
                            y: destY,
                            char: s,
                            fg: step == 0 ? indFg : cellFg,
                            bg: bgToUse,
                            attributes: resolvedAttrs
                        )
                    }
                } else {
                    buffer.drawText(
                        String(ch),
                        x: drawX,
                        y: destY,
                        fg: cellFg,
                        bg: cellBg,
                        attributes: resolvedAttrs
                    )
                }
            }

            colInLine += graphemeWidth
            docCellOffset += graphemeWidth
            byteOffsetInDoc += chUTF8Len
        }
    }
}

// MARK: - TextBufferOptions

/// Configuration options for `TextBufferRenderable` and its subclasses (`TextRenderable`, etc.).
// parity: core/src/renderables/TextBufferRenderable.ts#TextBufferOptions [status=implemented hash=04c609fc1b17]
public struct TextBufferOptions {
    public var base: RenderableOptions
    public var fg: Color?
    public var bg: Color?
    public var selectionBg: Color?
    public var selectionFg: Color?
    public var selectable: Bool?
    public var attributes: UInt32?
    public var wrapMode: TextWrapMode?
    public var textAlign: TextAlign?
    public var tabIndicator: String?
    public var tabIndicatorColor: Color?
    public var truncate: Bool?

    public init(
        id: String? = nil,
        width: FlexValue? = nil,
        height: FlexValue? = nil,
        minWidth: FlexValue? = nil,
        maxWidth: FlexValue? = nil,
        minHeight: FlexValue? = nil,
        maxHeight: FlexValue? = nil,
        flexGrow: Float? = nil,
        flexShrink: Float? = nil,
        flexBasis: FlexValue? = nil,
        flexDirection: FlexDirection? = nil,
        flexWrap: Wrap? = nil,
        alignItems: Align? = nil,
        alignSelf: Align? = nil,
        justifyContent: Justify? = nil,
        position: PositionType? = nil,
        top: FlexValue? = nil,
        right: FlexValue? = nil,
        bottom: FlexValue? = nil,
        left: FlexValue? = nil,
        margin: FlexValue? = nil,
        padding: FlexValue? = nil,
        overflow: Overflow? = nil,
        zIndex: Int? = nil,
        visible: Bool? = nil,
        opacity: Double? = nil,
        buffered: Bool? = nil,
        fg: Color? = nil,
        bg: Color? = nil,
        selectionBg: Color? = nil,
        selectionFg: Color? = nil,
        selectable: Bool? = nil,
        attributes: UInt32? = nil,
        wrapMode: TextWrapMode? = nil,
        textAlign: TextAlign? = nil,
        tabIndicator: String? = nil,
        tabIndicatorColor: Color? = nil,
        truncate: Bool? = nil
    ) {
        self.base = RenderableOptions(
            id: id,
            width: width,
            height: height,
            minWidth: minWidth,
            maxWidth: maxWidth,
            minHeight: minHeight,
            maxHeight: maxHeight,
            flexGrow: flexGrow,
            flexShrink: flexShrink,
            flexBasis: flexBasis,
            flexDirection: flexDirection,
            flexWrap: flexWrap,
            alignItems: alignItems,
            alignSelf: alignSelf,
            justifyContent: justifyContent,
            position: position,
            top: top,
            right: right,
            bottom: bottom,
            left: left,
            margin: margin,
            padding: padding,
            overflow: overflow,
            zIndex: zIndex,
            visible: visible,
            opacity: opacity,
            selectable: selectable,
            buffered: buffered
        )
        self.fg = fg
        self.bg = bg
        self.selectionBg = selectionBg
        self.selectionFg = selectionFg
        self.selectable = selectable
        self.attributes = attributes
        self.wrapMode = wrapMode
        self.textAlign = textAlign
        self.tabIndicator = tabIndicator
        self.tabIndicatorColor = tabIndicatorColor
        self.truncate = truncate
    }

    public init(
        base: RenderableOptions,
        fg: Color? = nil,
        bg: Color? = nil,
        selectionBg: Color? = nil,
        selectionFg: Color? = nil,
        selectable: Bool? = nil,
        attributes: UInt32? = nil,
        wrapMode: TextWrapMode? = nil,
        textAlign: TextAlign? = nil,
        tabIndicator: String? = nil,
        tabIndicatorColor: Color? = nil,
        truncate: Bool? = nil
    ) {
        self.base = base
        self.fg = fg
        self.bg = bg
        self.selectionBg = selectionBg
        self.selectionFg = selectionFg
        self.selectable = selectable ?? base.selectable
        self.attributes = attributes
        self.wrapMode = wrapMode
        self.textAlign = textAlign
        self.tabIndicator = tabIndicator
        self.tabIndicatorColor = tabIndicatorColor
        self.truncate = truncate
    }
}

// MARK: - TextBufferRenderable

/// Base renderable wrapping `TextBuffer` and `TextBufferView` with wrapping, scrolling,
/// intrinsic flexbox measurement, and local/global text selection.
// parity: core/src/renderables/TextBufferRenderable.ts#TextBufferRenderable [status=implemented hash=22b9851d6ee0]
open class TextBufferRenderable: Renderable, LineInfoProvider, @unchecked Sendable {
    private static let defaultFgColor = RGBA.fromValues(1, 1, 1, 1)
    private static let defaultBgColor = RGBA.fromValues(0, 0, 0, 0)

    internal var _defaultFg: RGBA
    internal var _defaultBg: RGBA
    internal var _defaultAttributes: UInt32
    internal var _selectionBg: RGBA?
    internal var _selectionFg: RGBA?
    internal var _wrapMode: TextWrapMode
    internal var _textAlign: TextAlign
    internal var lastLocalSelection: LocalSelectionBounds? = nil
    internal var _tabIndicator: String?
    internal var _tabIndicatorColor: RGBA?
    internal var _scrollX: Int = 0
    internal var _scrollY: Int = 0
    internal var _truncate: Bool
    internal var _firstLineOffset: Int = 0

    public let textBuffer: TextBuffer
    public let textBufferView: TextBufferView

    public init(ctx: any RenderContext, options: TextBufferOptions = TextBufferOptions()) {
        self._defaultFg = options.fg?.resolved() ?? Self.defaultFgColor
        self._defaultBg = options.bg?.resolved() ?? Self.defaultBgColor
        self._defaultAttributes = options.attributes ?? TextAttributes.none
        self._selectionBg = options.selectionBg?.resolved()
        self._selectionFg = options.selectionFg?.resolved()
        self._wrapMode = options.wrapMode ?? .word
        self._textAlign = options.textAlign ?? .left
        self._tabIndicator = options.tabIndicator
        self._tabIndicatorColor = options.tabIndicatorColor?.resolved()
        self._truncate = options.truncate ?? false

        let buffer = TextBuffer.create(widthMethod: textBufferWidthMethod(ctx.widthMethod))
        self.textBuffer = buffer
        self.textBufferView = TextBufferView.create(buffer)

        var baseOptions = options.base
        baseOptions.selectable = options.selectable ?? options.base.selectable ?? true
        super.init(ctx: ctx, options: baseOptions)

        self.selectable = options.selectable ?? options.base.selectable ?? true

        self.textBuffer.setDefaultFg(self._defaultFg)
        self.textBuffer.setDefaultBg(self._defaultBg)
        self.textBuffer.setDefaultAttributes(self._defaultAttributes)

        self.textBufferView.setWrapMode(self._wrapMode)
        self.textBufferView.setTextAlign(self._textAlign)
        self.textBufferView.setFirstLineOffset(self._firstLineOffset)
        self.textBufferView.setTruncate(self._truncate)
        self.textBufferView.setSelectionColors(bgColor: self._selectionBg, fgColor: self._selectionFg)

        if let indicator = self._tabIndicator {
            self.textBufferView.setTabIndicator(indicator)
        }
        if let indColor = self._tabIndicatorColor {
            self.textBufferView.setTabIndicatorColor(indColor)
        }

        setupMeasureFunc()

        let w = self.width
        let h = self.height
        if w > 0 && h > 0 {
            updateViewportOffset()
        } else if self._wrapMode != .none && w > 0 {
            self.textBufferView.setWrapWidth(w)
        }

        updateTextInfo()
    }

    private func setupMeasureFunc() {
        setMeasureProvider { [weak self] width, widthMode, height, heightMode in
            guard let self, !self.isDestroyed, !self.textBufferView.isDestroyed else {
                return FlexSize(width: 0, height: 1)
            }
            self.prepareBeforeMeasure()

            let hasWidthConstraint = widthMode != .undefined && width.isFinite && width > 0
            let effectiveWidth = hasWidthConstraint ? max(1, Int(width.rounded(.down))) : 0
            let effectiveHeight = (heightMode != .undefined && height.isFinite && height > 0)
                ? max(1, Int(height.rounded(.down)))
                : 0

            guard let measured = self.textBufferView.measureForDimensions(
                width: effectiveWidth,
                height: effectiveHeight
            ) else {
                return FlexSize(width: 0, height: 1)
            }

            var outWidth = max(0, measured.widthColsMax)
            if widthMode == .atMost && hasWidthConstraint && self.position != .absolute {
                outWidth = min(effectiveWidth, outWidth)
            } else if widthMode == .exactly && hasWidthConstraint {
                outWidth = effectiveWidth
            }

            let outHeight = max(1, measured.lineCount)
            return FlexSize(width: Float(outWidth), height: Float(outHeight))
        }
    }

    /// Hook for subclasses (such as `TextRenderable`) to flush pending text node composition before measurement.
    open func prepareBeforeMeasure() {}

    // MARK: - Mouse & Scroll

    open override func onMouseEvent(_ event: MouseEvent) {
        if event.type == .scroll {
            scrollOnce(event: event.scrollChainToken, scroller: self) {
                let prevX = self.scrollX
                let prevY = self.scrollY
                self.handleScroll(event)
                return self.scrollX != prevX || self.scrollY != prevY
            }
        }
    }

    open func handleScroll(_ event: MouseEvent) {
        guard let scroll = event.scroll else { return }
        let delta = scroll.delta
        let direction = wheelDirection(
            direction: textBufferWheelDirection(scroll.direction),
            shift: event.modifiers.shift
        )

        switch direction {
        case .up:
            self.scrollY -= delta
        case .down:
            self.scrollY += delta
        case .left:
            if _wrapMode == .none && !_truncate {
                self.scrollX -= delta
            }
        case .right:
            if _wrapMode == .none && !_truncate {
                self.scrollX += delta
            }
        case .none:
            break
        }
    }

    // MARK: - LineInfoProvider & Metrics

    // parity: core/src/renderables/TextBufferRenderable.ts#TextBufferRenderable.lineInfo [status=implemented hash=85221e40bb8d]
    open var lineInfo: LineInfo {
        guard !isDestroyed && !textBufferView.isDestroyed else { return LineInfo() }
        return textBufferView.logicalLineInfo
    }

    // parity: core/src/renderables/TextBufferRenderable.ts#TextBufferRenderable.getLineSources [status=implemented hash=698e3afeff66]
    open func getLineSources(startLine: Int, lineCount: Int) -> [Int] {
        guard !isDestroyed && !textBufferView.isDestroyed else { return [] }
        return textBufferView.getLineSources(startLine: startLine, lineCount: lineCount)
    }

    // parity: core/src/renderables/TextBufferRenderable.ts#TextBufferRenderable.lineCount [status=implemented hash=7f182e24ec66]
    open var lineCount: Int {
        guard !isDestroyed && !textBuffer.isDestroyed else { return 0 }
        return textBuffer.getLineCount()
    }

    // parity: core/src/renderables/TextBufferRenderable.ts#TextBufferRenderable.virtualLineCount [status=implemented hash=4af36fc4feb6]
    open var virtualLineCount: Int {
        guard !isDestroyed && !textBufferView.isDestroyed else { return 0 }
        return textBufferView.getVirtualLineCount()
    }

    private var textViewportSize: (width: Int, height: Int) {
        let padding = layoutNode.computedLayout.padding
        let contentW = max(0, width - Int(padding.horizontal.rounded(.toNearestOrAwayFromZero)))
        let contentH = max(0, height - Int(padding.vertical.rounded(.toNearestOrAwayFromZero)))
        return (width: contentW > 0 ? contentW : width, height: contentH > 0 ? contentH : height)
    }

    // parity: core/src/renderables/TextBufferRenderable.ts#TextBufferRenderable.scrollY [status=implemented hash=0f952c4c317b]
    open var scrollY: Int {
        get { _scrollY }
        set {
            let clamped = max(0, min(newValue, maxScrollY))
            guard _scrollY != clamped else { return }
            _scrollY = clamped
            updateViewportOffset(scrollX: _scrollX, scrollY: clamped)
            requestRender()
        }
    }

    // parity: core/src/renderables/TextBufferRenderable.ts#TextBufferRenderable.scrollX [status=implemented hash=f7f8a92359b2]
    open var scrollX: Int {
        get { _scrollX }
        set {
            let clamped = max(0, min(newValue, maxScrollX))
            guard _scrollX != clamped else { return }
            _scrollX = clamped
            updateViewportOffset(scrollX: clamped, scrollY: _scrollY)
            requestRender()
        }
    }

    // parity: core/src/renderables/TextBufferRenderable.ts#TextBufferRenderable.scrollWidth [status=implemented hash=c8225bdcf095]
    open var scrollWidth: Int {
        lineInfo.lineWidthColsMax
    }

    // parity: core/src/renderables/TextBufferRenderable.ts#TextBufferRenderable.scrollHeight [status=implemented hash=3912953ea890]
    open var scrollHeight: Int {
        virtualLineCount
    }

    // parity: core/src/renderables/TextBufferRenderable.ts#TextBufferRenderable.maxScrollY [status=implemented hash=dc8fa028dd3e]
    open var maxScrollY: Int {
        max(0, scrollHeight - textViewportSize.height)
    }

    // parity: core/src/renderables/TextBufferRenderable.ts#TextBufferRenderable.maxScrollX [status=implemented hash=8cf3b0095c4c]
    open var maxScrollX: Int {
        max(0, scrollWidth - textViewportSize.width)
    }

    open func updateViewportOffset(scrollX: Int? = nil, scrollY: Int? = nil) {
        guard !isDestroyed && !textBufferView.isDestroyed else { return }
        let sx = scrollX ?? _scrollX
        let sy = scrollY ?? _scrollY
        let vp = textViewportSize
        if vp.width > 0 && vp.height > 0 {
            textBufferView.setViewport(x: sx, y: sy, width: vp.width, height: vp.height)
        }
    }

    // parity: core/src/renderables/TextBufferRenderable.ts#TextBufferRenderable.plainText [status=implemented hash=e278e65a7fc0]
    open var plainText: String {
        guard !isDestroyed && !textBuffer.isDestroyed else { return "" }
        return textBuffer.getPlainText()
    }

    // parity: core/src/renderables/TextBufferRenderable.ts#TextBufferRenderable.textLength [status=implemented hash=109d99beab90]
    open var textLength: Int {
        guard !isDestroyed && !textBuffer.isDestroyed else { return 0 }
        return textBuffer.length
    }

    // MARK: - Style & Layout Properties

    // parity: core/src/renderables/TextBufferRenderable.ts#TextBufferRenderable.fg [status=implemented hash=64fa5ad6d6bc]
    open var fg: RGBA {
        get { _defaultFg }
        set {
            guard !isDestroyed && !textBuffer.isDestroyed else { return }
            _defaultFg = newValue
            textBuffer.setDefaultFg(newValue)
            onFgChanged(newValue)
            requestRender()
        }
    }

    // parity: core/src/renderables/TextBufferRenderable.ts#TextBufferRenderable.selectionBg [status=implemented hash=731aeaaffc82]
    open var selectionBg: RGBA? {
        get { _selectionBg }
        set {
            guard !isDestroyed && !textBufferView.isDestroyed, _selectionBg != newValue else { return }
            _selectionBg = newValue
            textBufferView.setSelectionColors(bgColor: newValue, fgColor: _selectionFg)
            requestRender()
        }
    }

    // parity: core/src/renderables/TextBufferRenderable.ts#TextBufferRenderable.selectionFg [status=implemented hash=2f7609140328]
    open var selectionFg: RGBA? {
        get { _selectionFg }
        set {
            guard !isDestroyed && !textBufferView.isDestroyed, _selectionFg != newValue else { return }
            _selectionFg = newValue
            textBufferView.setSelectionColors(bgColor: _selectionBg, fgColor: newValue)
            requestRender()
        }
    }

    // parity: core/src/renderables/TextBufferRenderable.ts#TextBufferRenderable.bg [status=implemented hash=c71e643b358e]
    open var bg: RGBA {
        get { _defaultBg }
        set {
            guard !isDestroyed && !textBuffer.isDestroyed else { return }
            _defaultBg = newValue
            textBuffer.setDefaultBg(newValue)
            onBgChanged(newValue)
            requestRender()
        }
    }

    // parity: core/src/renderables/TextBufferRenderable.ts#TextBufferRenderable.attributes [status=implemented hash=0abe5cc94146]
    open var attributes: UInt32 {
        get { _defaultAttributes }
        set {
            guard !isDestroyed && !textBuffer.isDestroyed, _defaultAttributes != newValue else { return }
            _defaultAttributes = newValue
            textBuffer.setDefaultAttributes(newValue)
            onAttributesChanged(newValue)
            requestRender()
        }
    }

    // parity: core/src/renderables/TextBufferRenderable.ts#TextBufferRenderable.wrapMode [status=implemented hash=875d9d29e1ef]
    open var wrapMode: TextWrapMode {
        get { _wrapMode }
        set {
            guard !isDestroyed && !textBufferView.isDestroyed, _wrapMode != newValue else { return }
            _wrapMode = newValue
            textBufferView.setWrapMode(newValue)
            if newValue != .none {
                let w = textViewportSize.width
                if w > 0 {
                    textBufferView.setWrapWidth(w)
                }
                self.scrollX = 0
            } else {
                textBufferView.setWrapWidth(nil)
            }
            invalidateIntrinsicSize()
            requestRender()
            emit("line-info-change")
        }
    }

    // parity: core/src/renderables/TextBufferRenderable.ts#TextBufferRenderable.textAlign [status=implemented hash=59bb8582e109]
    open var textAlign: TextAlign {
        get { _textAlign }
        set {
            guard !isDestroyed && !textBufferView.isDestroyed, _textAlign != newValue else { return }
            _textAlign = newValue
            textBufferView.setTextAlign(newValue)
            requestRender()
        }
    }

    // parity: core/src/renderables/TextBufferRenderable.ts#TextBufferRenderable.tabIndicator [status=implemented hash=1fe4c826b29e]
    open var tabIndicator: String? {
        get { _tabIndicator }
        set {
            guard !isDestroyed && !textBufferView.isDestroyed, _tabIndicator != newValue else { return }
            _tabIndicator = newValue
            if let value = newValue {
                textBufferView.setTabIndicator(value)
            } else {
                textBufferView.setTabIndicator(codePoint: 0)
            }
            requestRender()
        }
    }

    // parity: core/src/renderables/TextBufferRenderable.ts#TextBufferRenderable.tabIndicatorColor [status=implemented hash=035cc5d39725]
    open var tabIndicatorColor: RGBA? {
        get { _tabIndicatorColor }
        set {
            guard !isDestroyed && !textBufferView.isDestroyed, _tabIndicatorColor != newValue else { return }
            _tabIndicatorColor = newValue
            if let color = newValue {
                textBufferView.setTabIndicatorColor(color)
            }
            requestRender()
        }
    }

    // parity: core/src/renderables/TextBufferRenderable.ts#TextBufferRenderable.truncate [status=implemented hash=6096d54fd966]
    open var truncate: Bool {
        get { _truncate }
        set {
            guard !isDestroyed && !textBufferView.isDestroyed, _truncate != newValue else { return }
            _truncate = newValue
            textBufferView.setTruncate(newValue)
            if newValue {
                self.scrollX = 0
            }
            requestRender()
        }
    }

    public var firstLineOffset: Int {
        get { _firstLineOffset }
        set {
            let clamped = max(0, newValue)
            guard !isDestroyed && !textBufferView.isDestroyed, _firstLineOffset != clamped else { return }
            _firstLineOffset = clamped
            textBufferView.setFirstLineOffset(clamped)
            invalidateIntrinsicSize()
            requestRender()
            emit("line-info-change")
        }
    }

    // MARK: - Resize & Text Info

    open override func onResize(width: Int, height: Int) {
        if !isDestroyed && !textBufferView.isDestroyed {
            let vp = textViewportSize
            let effectiveW = vp.width > 0 ? vp.width : width
            let effectiveH = vp.height > 0 ? vp.height : height
            if effectiveW > 0 && effectiveH > 0 {
                textBufferView.setViewport(x: _scrollX, y: _scrollY, width: effectiveW, height: effectiveH)
                if _wrapMode != .none {
                    textBufferView.setWrapWidth(effectiveW)
                }
            }
        }
        requestRender()
        emit("line-info-change")
        super.onResize(width: width, height: height)
    }

    @discardableResult
    open func refreshLocalSelection() -> Bool {
        if let local = lastLocalSelection {
            return updateLocalSelection(local, isStart: true)
        }
        return false
    }

    @discardableResult
    private func updateLocalSelection(
        _ localSelection: LocalSelectionBounds?,
        isStart: Bool
    ) -> Bool {
        guard !isDestroyed && !textBufferView.isDestroyed else { return false }
        guard let localSelection, localSelection.isActive else {
            textBufferView.resetLocalSelection()
            return true
        }

        if isStart {
            return textBufferView.setLocalSelection(
                anchorX: localSelection.anchorX,
                anchorY: localSelection.anchorY,
                focusX: localSelection.focusX,
                focusY: localSelection.focusY,
                bgColor: _selectionBg,
                fgColor: _selectionFg,
                behavior: localSelection.behavior
            )
        } else {
            return textBufferView.updateLocalSelection(
                anchorX: localSelection.anchorX,
                anchorY: localSelection.anchorY,
                focusX: localSelection.focusX,
                focusY: localSelection.focusY,
                bgColor: _selectionBg,
                fgColor: _selectionFg,
                behavior: localSelection.behavior
            )
        }
    }

    open func updateTextInfo() {
        invalidateIntrinsicSize()
        if let local = lastLocalSelection {
            _ = updateLocalSelection(local, isStart: true)
        }
        requestRender()
        emit("line-info-change")
    }

    // MARK: - Selection

    // parity: core/src/renderables/TextBufferRenderable.ts#TextBufferRenderable.shouldStartSelection [status=implemented hash=c87c8f8d1d8e]
    open override func shouldStartSelection(x: Int, y: Int) -> Bool {
        guard selectable else { return false }
        let localX = x - self.x
        let localY = y - self.y
        return localX >= 0 && localX < width && localY >= 0 && localY < height
    }

    // parity: core/src/renderables/TextBufferRenderable.ts#TextBufferRenderable.onSelectionChanged [status=implemented hash=981eda69daeb]
    @discardableResult
    open override func onSelectionChanged(_ selection: Selection?) -> Bool {
        let padding = layoutNode.computedLayout.padding
        let padLeft = Int(padding.left.rounded(.toNearestOrAwayFromZero))
        let padTop = Int(padding.top.rounded(.toNearestOrAwayFromZero))
        let localSelection = convertGlobalToLocalSelection(
            selection,
            localX: self.x + padLeft,
            localY: self.y + padTop
        )
        let changed = updateLocalSelection(localSelection, isStart: selection?.isStart ?? false)
        lastLocalSelection = localSelection
        if changed {
            requestRender()
        }
        return hasSelection()
    }

    // parity: core/src/renderables/TextBufferRenderable.ts#TextBufferRenderable.getSelectedText [status=implemented hash=efaf7dccd209]
    open override func getSelectedText() -> String {
        guard !isDestroyed && !textBufferView.isDestroyed else { return "" }
        return textBufferView.getSelectedText()
    }

    // parity: core/src/renderables/TextBufferRenderable.ts#TextBufferRenderable.hasSelection [status=implemented hash=8ce7d3c0be35]
    open override func hasSelection() -> Bool {
        guard !isDestroyed && !textBufferView.isDestroyed else { return false }
        return textBufferView.hasSelection()
    }

    // parity: core/src/renderables/TextBufferRenderable.ts#TextBufferRenderable.getSelection [status=implemented hash=35496c0888a5]
    open func getSelection() -> TextSelectionRange? {
        guard !isDestroyed && !textBufferView.isDestroyed else { return nil }
        return textBufferView.getSelection()
    }

    // MARK: - Rendering

    open override func renderSelf(buffer: OptimizedBuffer, deltaTime: Double) {
        let origin = paintOrigin(for: buffer)
        let padding = layoutNode.computedLayout.padding
        let padLeft = Int(padding.left.rounded(.toNearestOrAwayFromZero))
        let padTop = Int(padding.top.rounded(.toNearestOrAwayFromZero))
        drawToBuffer(buffer, x: origin.x + padLeft, y: origin.y + padTop)
    }

    /// Draws the current text viewport in destination-buffer coordinates without changing layout or hits.
    // parity: core/src/renderables/TextBufferRenderable.ts#TextBufferRenderable.drawToBuffer [status=implemented hash=cc59709beef9]
    public func drawToBuffer(_ buffer: OptimizedBuffer, x: Int, y: Int) {
        guard !isDestroyed && !textBufferView.isDestroyed else { return }
        let vp = textViewportSize
        if vp.width > 0 && vp.height > 0 {
            let currentVp = textBufferView.viewport
            if currentVp == nil || currentVp?.width != vp.width || currentVp?.height != vp.height {
                textBufferView.setViewport(x: _scrollX, y: _scrollY, width: vp.width, height: vp.height)
                if _wrapMode != .none {
                    textBufferView.setWrapWidth(vp.width)
                }
            }
        }
        drawTextBufferView(
            textBufferView,
            into: buffer,
            x: x,
            y: y,
            clipWidth: vp.width > 0 ? vp.width : nil,
            clipHeight: vp.height > 0 ? vp.height : nil
        )
    }

    // MARK: - Subclass Hooks & Cleanup

    open func onFgChanged(_ newColor: RGBA) {}
    open func onBgChanged(_ newColor: RGBA) {}
    open func onAttributesChanged(_ newAttributes: UInt32) {}

    open override func destroySelf() {
        textBufferView.destroy()
        textBuffer.destroy()
        super.destroySelf()
    }
}
