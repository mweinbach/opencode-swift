import OpenTUICore
import OpenTUILayout

// MARK: - ASCIIFontSelectionRange & ASCIIFontSelectionHelper

/// UTF-16 character range selected inside an `ASCIIFontRenderable`.
public struct ASCIIFontSelectionRange: Equatable, Hashable, Sendable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

/// Maps local cell selection coordinates onto UTF-16 character ranges in an ASCII banner font,
/// matching `core/src/lib/selection.ts#ASCIIFontSelectionHelper`.
// parity: core/src/lib/selection.ts#ASCIIFontSelectionHelper [status=implemented hash=9ae48eb17b02]
public final class ASCIIFontSelectionHelper {
    private var localSelection: ASCIIFontSelectionRange? = nil
    private let getText: () -> String
    private let getFont: () -> ASCIIFontName

    public init(getText: @escaping () -> String, getFont: @escaping () -> ASCIIFontName) {
        self.getText = getText
        self.getFont = getFont
    }

    // parity: core/src/lib/selection.ts#ASCIIFontSelectionHelper.hasSelection [status=implemented hash=635a77a73a24]
    public func hasSelection() -> Bool {
        localSelection != nil
    }

    // parity: core/src/lib/selection.ts#ASCIIFontSelectionHelper.getSelection [status=implemented hash=35496c0888a5]
    public func getSelection() -> ASCIIFontSelectionRange? {
        localSelection
    }

    // parity: core/src/lib/selection.ts#ASCIIFontSelectionHelper.shouldStartSelection [status=implemented hash=d97cdc3693c4]
    public func shouldStartSelection(localX: Int, localY: Int, width: Int, height: Int) -> Bool {
        if localX < 0 || localX >= width || localY < 0 || localY >= height {
            return false
        }

        let text = getText()
        let font = getFont()
        let charIndex = coordinateToCharacterIndex(localX, text: text, font: font)
        return charIndex >= 0 && charIndex <= text.utf16.count
    }

    // parity: core/src/lib/selection.ts#ASCIIFontSelectionHelper.onLocalSelectionChanged [status=implemented hash=9998e580d9e1]
    @discardableResult
    public func onLocalSelectionChanged(
        _ localSelection: LocalSelectionBounds?,
        width: Int,
        height: Int
    ) -> Bool {
        let previousSelection = self.localSelection

        guard let localSelection, localSelection.isActive else {
            self.localSelection = nil
            return previousSelection != nil
        }

        let text = getText()
        let textLength = text.utf16.count
        let font = getFont()
        let positions = getCharacterPositions(text, font: font)
        let minY = Swift.min(localSelection.anchorY, localSelection.focusY)
        let maxY = Swift.max(localSelection.anchorY, localSelection.focusY)

        // Completely above or below this glyph row: not selected.
        if maxY < 0 || minY > height - 1 {
            self.localSelection = nil
            return previousSelection != nil
        }

        func indexAt(x: Int, y: Int) -> Int {
            if y < 0 { return 0 }
            if y > height - 1 { return textLength }
            if x < 0 { return 0 }
            if x >= width { return textLength }
            if positions.count > 1 {
                for index in 1..<positions.count {
                    if x < positions[index] {
                        return index - 1
                    }
                }
            }
            return textLength
        }

        let anchorIndex = indexAt(x: localSelection.anchorX, y: localSelection.anchorY)
        let focusIndex = indexAt(x: localSelection.focusX, y: localSelection.focusY)
        let start = Swift.min(anchorIndex, focusIndex)
        let end = Swift.min(Swift.max(anchorIndex, focusIndex) + 1, textLength)
        let samePoint = localSelection.anchorX == localSelection.focusX
            && localSelection.anchorY == localSelection.focusY

        if samePoint || start >= end {
            self.localSelection = nil
        } else {
            self.localSelection = ASCIIFontSelectionRange(start: start, end: end)
        }

        return previousSelection != self.localSelection
    }
}

// MARK: - UTF-16 Slice Helper

private func sliceUTF16(_ text: String, start: Int, end: Int) -> String {
    let units = Array(text.utf16)
    let lo = Swift.max(0, Swift.min(start, units.count))
    let hi = Swift.max(lo, Swift.min(end, units.count))
    guard lo < hi else { return "" }
    return String(decoding: units[lo..<hi], as: UTF16.self)
}

// MARK: - ASCIIFontOptions

/// Options for constructing an `ASCIIFontRenderable`, matching `core/src/renderables/ASCIIFont.ts#ASCIIFontOptions`.
// parity: core/src/renderables/ASCIIFont.ts#ASCIIFontOptions [status=implemented hash=72bdd77e07e9]
public struct ASCIIFontOptions {
    public var renderable: RenderableOptions
    public var text: String?
    public var font: ASCIIFontName?
    public var colors: [Color]?
    public var backgroundColor: Color?
    public var selectionBg: Color?
    public var selectionFg: Color?
    public var selectable: Bool?

    public init(
        text: String? = nil,
        font: ASCIIFontName? = nil,
        color: Color? = nil,
        colors: [Color]? = nil,
        backgroundColor: Color? = nil,
        selectionBg: Color? = nil,
        selectionFg: Color? = nil,
        selectable: Bool? = nil,
        id: String? = nil,
        flexGrow: Float? = nil,
        flexShrink: Float? = nil,
        alignSelf: Align? = nil,
        position: PositionType? = nil,
        top: FlexValue? = nil,
        right: FlexValue? = nil,
        bottom: FlexValue? = nil,
        left: FlexValue? = nil,
        margin: FlexValue? = nil,
        zIndex: Int? = nil,
        visible: Bool? = nil,
        opacity: Double? = nil
    ) {
        self.renderable = RenderableOptions(
            id: id,
            flexGrow: flexGrow,
            flexShrink: flexShrink ?? 0,
            alignSelf: alignSelf,
            position: position,
            top: top,
            right: right,
            bottom: bottom,
            left: left,
            margin: margin,
            zIndex: zIndex,
            visible: visible,
            opacity: opacity,
            selectable: selectable ?? true
        )
        self.text = text
        self.font = font
        if let colors, !colors.isEmpty {
            self.colors = colors
        } else if let color {
            self.colors = [color]
        } else {
            self.colors = nil
        }
        self.backgroundColor = backgroundColor
        self.selectionBg = selectionBg
        self.selectionFg = selectionFg
        self.selectable = selectable
    }
}

// MARK: - ASCIIFontRenderable

/// Selectable ASCII banner font renderable backed by a `FrameBufferRenderable`,
/// matching `core/src/renderables/ASCIIFont.ts#ASCIIFontRenderable`.
// parity: core/src/renderables/ASCIIFont.ts#ASCIIFontRenderable [status=implemented hash=e7ef03b2d33d]
open class ASCIIFontRenderable: FrameBufferRenderable, @unchecked Sendable {
    public static let defaultFont: ASCIIFontName = .tiny
    public static let defaultColor: RGBA = RGBA.fromHex("#FFFFFF")
    public static let defaultBackgroundColor: RGBA = RGBA.fromValues(0, 0, 0, 0)

    internal var _text: String
    internal var _font: ASCIIFontName
    internal var _colors: [RGBA]
    internal var _backgroundColor: RGBA
    internal var _selectionBg: RGBA?
    internal var _selectionFg: RGBA?
    internal var lastLocalSelection: LocalSelectionBounds? = nil

    private var selectionHelper: ASCIIFontSelectionHelper!

    public init(ctx: any RenderContext, options: ASCIIFontOptions = ASCIIFontOptions()) {
        let resolvedFont = options.font ?? Self.defaultFont
        let resolvedText = options.text ?? ""
        let measurements = measureAsciiText(resolvedText, font: resolvedFont)
        let resolvedColors = options.colors?.map { $0.resolved() } ?? [Self.defaultColor]

        self._text = resolvedText
        self._font = resolvedFont
        self._colors = resolvedColors.isEmpty ? [Self.defaultColor] : resolvedColors
        self._backgroundColor = options.backgroundColor?.resolved() ?? Self.defaultBackgroundColor
        self._selectionBg = options.selectionBg?.resolved()
        self._selectionFg = options.selectionFg?.resolved()

        var baseOptions = options.renderable
        if baseOptions.flexShrink == nil {
            baseOptions.flexShrink = 0
        }
        baseOptions.selectable = options.selectable ?? true

        super.init(
            ctx: ctx,
            options: FrameBufferOptions(
                renderable: baseOptions,
                width: Swift.max(1, measurements.width),
                height: Swift.max(1, measurements.height),
                respectAlpha: true
            )
        )

        self.selectable = options.selectable ?? true
        self.selectionHelper = ASCIIFontSelectionHelper(
            getText: { [weak self] in self?._text ?? "" },
            getFont: { [weak self] in self?._font ?? Self.defaultFont }
        )

        renderFontToBuffer()
    }

    // parity: core/src/renderables/ASCIIFont.ts#ASCIIFontRenderable.text [status=implemented hash=083757af6e65]
    public var text: String {
        get { _text }
        set {
            _text = newValue
            updateDimensions()
            if let last = lastLocalSelection {
                _ = selectionHelper.onLocalSelectionChanged(last, width: width, height: height)
            }
            renderFontToBuffer()
            requestRender()
        }
    }

    // parity: core/src/renderables/ASCIIFont.ts#ASCIIFontRenderable.font [status=implemented hash=5dadec112e8b]
    public var font: ASCIIFontName {
        get { _font }
        set {
            _font = newValue
            updateDimensions()
            if let last = lastLocalSelection {
                _ = selectionHelper.onLocalSelectionChanged(last, width: width, height: height)
            }
            renderFontToBuffer()
            requestRender()
        }
    }

    // parity: core/src/renderables/ASCIIFont.ts#ASCIIFontRenderable.color [status=implemented hash=3b3fa19a4888]
    public var color: [RGBA] {
        get { _colors }
        set {
            _colors = newValue.isEmpty ? [Self.defaultColor] : newValue
            renderFontToBuffer()
            requestRender()
        }
    }

    public func setColor(_ color: Color) {
        self.color = [color.resolved()]
    }

    public func setColors(_ colors: [Color]) {
        self.color = colors.map { $0.resolved() }
    }

    // parity: core/src/renderables/ASCIIFont.ts#ASCIIFontRenderable.backgroundColor [status=implemented hash=1af6f6906868]
    public var backgroundColor: RGBA {
        get { _backgroundColor }
        set {
            _backgroundColor = newValue
            renderFontToBuffer()
            requestRender()
        }
    }

    public func setBackgroundColor(_ color: Color?) {
        backgroundColor = color?.resolved() ?? Self.defaultBackgroundColor
    }

    // parity: core/src/renderables/ASCIIFont.ts#ASCIIFontRenderable.selectionBg [status=implemented hash=7fc770053a2c]
    public var selectionBg: RGBA? {
        get { _selectionBg }
        set {
            _selectionBg = newValue
            repaintSelection()
        }
    }

    public func setSelectionBg(_ color: Color?) {
        selectionBg = color?.resolved()
    }

    // parity: core/src/renderables/ASCIIFont.ts#ASCIIFontRenderable.selectionFg [status=implemented hash=df8d5aa5feed]
    public var selectionFg: RGBA? {
        get { _selectionFg }
        set {
            _selectionFg = newValue
            repaintSelection()
        }
    }

    public func setSelectionFg(_ color: Color?) {
        selectionFg = color?.resolved()
    }

    private func repaintSelection() {
        if lastLocalSelection != nil {
            renderFontToBuffer()
            requestRender()
        }
    }

    private func updateDimensions() {
        let measurements = measureAsciiText(_text, font: _font)
        let targetWidth = Swift.max(1, measurements.width)
        let targetHeight = Swift.max(1, measurements.height)
        setWidth(.point(Float(targetWidth)))
        setHeight(.point(Float(targetHeight)))
        if let fb = frameBuffer, (fb.width != targetWidth || fb.height != targetHeight) {
            try? fb.resize(width: targetWidth, height: targetHeight)
        }
    }

    // parity: core/src/renderables/ASCIIFont.ts#ASCIIFontRenderable.shouldStartSelection [status=implemented hash=c3e6c6a6bff7]
    open override func shouldStartSelection(x: Int, y: Int) -> Bool {
        let localX = x - self.x
        let localY = y - self.y
        return selectionHelper.shouldStartSelection(localX: localX, localY: localY, width: width, height: height)
    }

    // parity: core/src/renderables/ASCIIFont.ts#ASCIIFontRenderable.onSelectionChanged [status=implemented hash=d0d8548a997d]
    @discardableResult
    open override func onSelectionChanged(_ selection: Selection?) -> Bool {
        let localSelection = convertGlobalToLocalSelection(selection, localX: self.x, localY: self.y)
        lastLocalSelection = localSelection
        let changed = selectionHelper.onLocalSelectionChanged(localSelection, width: width, height: height)
        if changed {
            renderFontToBuffer()
            requestRender()
        }
        return selectionHelper.hasSelection()
    }

    // parity: core/src/renderables/ASCIIFont.ts#ASCIIFontRenderable.getSelectedText [status=implemented hash=92d06719bdfd]
    open override func getSelectedText() -> String {
        guard let range = selectionHelper.getSelection() else { return "" }
        return sliceUTF16(_text, start: range.start, end: range.end)
    }

    // parity: core/src/renderables/ASCIIFont.ts#ASCIIFontRenderable.hasSelection [status=implemented hash=c8d21301bbe7]
    open override func hasSelection() -> Bool {
        selectionHelper.hasSelection()
    }

    /// Returns the currently selected character range, if any.
    public func getSelectionRange() -> ASCIIFontSelectionRange? {
        selectionHelper.getSelection()
    }

    open override func onResize(width: Int, height: Int) {
        super.onResize(width: width, height: height)
        renderFontToBuffer()
    }

    private func renderFontToBuffer() {
        guard !_isDestroyed, let fb = frameBuffer else { return }
        fb.clear(bg: _backgroundColor, char: defaultSpaceChar)

        _ = renderFontToFrameBuffer(
            fb,
            text: _text,
            x: 0,
            y: 0,
            colors: _colors,
            backgroundColor: _backgroundColor,
            font: _font
        )

        if let selection = selectionHelper.getSelection(),
           (_selectionBg != nil || _selectionFg != nil)
        {
            renderSelectionHighlight(selection, into: fb)
        }
    }

    private func renderSelectionHighlight(_ selection: ASCIIFontSelectionRange, into fb: OptimizedBuffer) {
        let selectedText = sliceUTF16(_text, start: selection.start, end: selection.end)
        guard !selectedText.isEmpty else { return }

        let positions = getCharacterPositions(_text, font: _font)
        let startX = selection.start < positions.count ? positions[selection.start] : 0
        let endX: Int
        if selection.end < positions.count {
            endX = positions[selection.end]
        } else {
            endX = measureAsciiText(_text, font: _font).width
        }

        if let selBg = _selectionBg {
            fb.fillRect(x: startX, y: 0, width: Swift.max(0, endX - startX), height: fb.height, bg: selBg)
        }

        let highlightColors = _selectionFg.map { [$0] } ?? _colors
        let highlightBg = _selectionBg ?? _backgroundColor
        _ = renderFontToFrameBuffer(
            fb,
            text: selectedText,
            x: startX,
            y: 0,
            colors: highlightColors,
            backgroundColor: highlightBg,
            font: _font
        )
    }
}
