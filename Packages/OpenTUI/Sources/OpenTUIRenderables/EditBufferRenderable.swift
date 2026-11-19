import OpenTUICore
import OpenTUILayout

// MARK: - Shared Editor Types

// parity: core/src/renderables/EditBufferRenderable.ts#EditorCapture [status=implemented hash=015e74cf4734]
public enum EditorCapture: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case escape
    case navigate
    case submit
    case tab
}

// parity: core/src/renderables/EditBufferRenderable.ts#EditorTraits [status=implemented hash=6b9e3ff2129d]
public struct EditorTraits: Equatable, Hashable, Sendable, Codable {
    public var capture: [EditorCapture]?
    public var suspend: Bool?
    public var status: String?

    public init(
        capture: [EditorCapture]? = nil,
        suspend: Bool? = nil,
        status: String? = nil
    ) {
        self.capture = capture
        self.suspend = suspend
        self.status = status
    }
}

// parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderableEvents [status=implemented hash=c9e741cf19af]
public enum EditBufferRenderableEvents: String, Equatable, Hashable, Sendable {
    case traitsChanged = "traits-changed"
}

/// Type check matching `core/src/renderables/EditBufferRenderable.ts#isEditBufferRenderable`.
// parity: core/src/renderables/EditBufferRenderable.ts#isEditBufferRenderable [status=implemented hash=7977bdb84c11]
public func isEditBufferRenderable(_ obj: Any?) -> Bool {
    obj is EditBufferRenderable
}

// parity: core/src/renderables/EditBufferRenderable.ts#CursorChangeEvent [status=implemented hash=190aff0f28d8]
public struct CursorChangeEvent: Equatable, Hashable, Sendable, Codable {
    /// Zero-based logical line.
    public var line: Int
    /// Display-cell column on that logical line, not a UTF-16 index.
    public var visualColumn: Int

    public init(line: Int, visualColumn: Int) {
        self.line = line
        self.visualColumn = visualColumn
    }
}

// parity: core/src/renderables/EditBufferRenderable.ts#ContentChangeEvent [status=implemented hash=62032667f426]
public struct ContentChangeEvent: Equatable, Hashable, Sendable, Codable {
    public init() {}
}

/// Value accepted for `EditBufferRenderable.tabIndicator` (either a string or a Unicode code point).
public enum TabIndicatorValue: Equatable, Hashable, Sendable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral {
    case string(String)
    case codePoint(UInt32)

    public init(stringLiteral value: String) {
        self = .string(value)
    }

    public init(integerLiteral value: UInt32) {
        self = .codePoint(value)
    }
}

// MARK: - EditBufferOptions

// parity: core/src/renderables/EditBufferRenderable.ts#EditBufferOptions [status=implemented hash=afae3abaaf82]
public struct EditBufferOptions {
    public var renderable: RenderableOptions
    public var textColor: Color?
    public var backgroundColor: Color?
    public var focusedTextColor: Color?
    public var focusedBackgroundColor: Color?
    public var selectionBg: Color?
    public var selectionFg: Color?
    public var selectable: Bool?
    public var attributes: UInt32?
    public var wrapMode: TextWrapMode?
    public var scrollMargin: Double?
    public var scrollSpeed: Double?
    public var showCursor: Bool?
    public var cursorColor: Color?
    public var cursorStyle: CursorStyleOptions?
    public var selectionOccupancy: SelectionOccupancy?
    public var syntaxStyle: SyntaxStyle?
    public var tabIndicator: TabIndicatorValue?
    public var tabIndicatorColor: Color?
    public var onCursorChange: ((CursorChangeEvent) -> Void)?
    public var onContentChange: ((ContentChangeEvent) -> Void)?

    public init(
        renderable: RenderableOptions = RenderableOptions(),
        textColor: Color? = nil,
        backgroundColor: Color? = nil,
        focusedTextColor: Color? = nil,
        focusedBackgroundColor: Color? = nil,
        selectionBg: Color? = nil,
        selectionFg: Color? = nil,
        selectable: Bool? = nil,
        attributes: UInt32? = nil,
        wrapMode: TextWrapMode? = nil,
        scrollMargin: Double? = nil,
        scrollSpeed: Double? = nil,
        showCursor: Bool? = nil,
        cursorColor: Color? = nil,
        cursorStyle: CursorStyleOptions? = nil,
        selectionOccupancy: SelectionOccupancy? = nil,
        syntaxStyle: SyntaxStyle? = nil,
        tabIndicator: TabIndicatorValue? = nil,
        tabIndicatorColor: Color? = nil,
        onCursorChange: ((CursorChangeEvent) -> Void)? = nil,
        onContentChange: ((ContentChangeEvent) -> Void)? = nil
    ) {
        self.renderable = renderable
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.focusedTextColor = focusedTextColor
        self.focusedBackgroundColor = focusedBackgroundColor
        self.selectionBg = selectionBg
        self.selectionFg = selectionFg
        self.selectable = selectable
        self.attributes = attributes
        self.wrapMode = wrapMode
        self.scrollMargin = scrollMargin
        self.scrollSpeed = scrollSpeed
        self.showCursor = showCursor
        self.cursorColor = cursorColor
        self.cursorStyle = cursorStyle
        self.selectionOccupancy = selectionOccupancy
        self.syntaxStyle = syntaxStyle
        self.tabIndicator = tabIndicator
        self.tabIndicatorColor = tabIndicatorColor
        self.onCursorChange = onCursorChange
        self.onContentChange = onContentChange
    }

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
        position: PositionType? = nil,
        top: FlexValue? = nil,
        right: FlexValue? = nil,
        bottom: FlexValue? = nil,
        left: FlexValue? = nil,
        margin: FlexValue? = nil,
        padding: FlexValue? = nil,
        zIndex: Int? = nil,
        visible: Bool? = nil,
        opacity: Double? = nil,
        focusable: Bool? = nil,
        buffered: Bool? = nil,
        textColor: Color? = nil,
        backgroundColor: Color? = nil,
        focusedTextColor: Color? = nil,
        focusedBackgroundColor: Color? = nil,
        selectionBg: Color? = nil,
        selectionFg: Color? = nil,
        selectable: Bool? = nil,
        attributes: UInt32? = nil,
        wrapMode: TextWrapMode? = nil,
        scrollMargin: Double? = nil,
        scrollSpeed: Double? = nil,
        showCursor: Bool? = nil,
        cursorColor: Color? = nil,
        cursorStyle: CursorStyleOptions? = nil,
        selectionOccupancy: SelectionOccupancy? = nil,
        syntaxStyle: SyntaxStyle? = nil,
        tabIndicator: TabIndicatorValue? = nil,
        tabIndicatorColor: Color? = nil,
        onCursorChange: ((CursorChangeEvent) -> Void)? = nil,
        onContentChange: ((ContentChangeEvent) -> Void)? = nil,
        onKeyDown: ((KeyEvent) -> Void)? = nil,
        onPaste: ((PasteEvent) -> Void)? = nil,
        onMouse: ((MouseEvent) -> Void)? = nil,
        onMouseDown: ((MouseEvent) -> Void)? = nil,
        onMouseScroll: ((MouseEvent) -> Void)? = nil
    ) {
        self.init(
            renderable: RenderableOptions(
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
                position: position,
                top: top,
                right: right,
                bottom: bottom,
                left: left,
                margin: margin,
                padding: padding,
                zIndex: zIndex,
                visible: visible,
                opacity: opacity,
                focusable: focusable,
                selectable: selectable,
                buffered: buffered,
                onMouse: onMouse,
                onMouseDown: onMouseDown,
                onMouseScroll: onMouseScroll,
                onKeyDown: onKeyDown,
                onPaste: onPaste
            ),
            textColor: textColor,
            backgroundColor: backgroundColor,
            focusedTextColor: focusedTextColor,
            focusedBackgroundColor: focusedBackgroundColor,
            selectionBg: selectionBg,
            selectionFg: selectionFg,
            selectable: selectable,
            attributes: attributes,
            wrapMode: wrapMode,
            scrollMargin: scrollMargin,
            scrollSpeed: scrollSpeed,
            showCursor: showCursor,
            cursorColor: cursorColor,
            cursorStyle: cursorStyle,
            selectionOccupancy: selectionOccupancy,
            syntaxStyle: syntaxStyle,
            tabIndicator: tabIndicator,
            tabIndicatorColor: tabIndicatorColor,
            onCursorChange: onCursorChange,
            onContentChange: onContentChange
        )
    }
}

// MARK: - Pure Helpers

private func toTextWidthMethod(_ method: WidthMethod) -> TextWidthMethod {
    switch method {
    case .wcwidth: return .wcwidth
    case .unicode, .noZWJ: return .unicode
    case .unicodeWide: return .unicodeWide
    }
}

internal func scrollDirectionToWheelDirection(_ direction: ScrollDirection) -> WheelDirection {
    switch direction {
    case .up: return .up
    case .down: return .down
    case .left: return .left
    case .right: return .right
    }
}

private let hexLowerDigits: [Character] = [
    "0", "1", "2", "3", "4", "5", "6", "7",
    "8", "9", "a", "b", "c", "d", "e", "f",
]

/// Formats a single control scalar (C0 other than tab/LF, DEL, C1) into Vim notation
/// (`^@`..`^_`, `^?`, `<80>`..`<9f>`). Returns `nil` for printable scalars.
private func controlScalarNotation(_ scalar: Unicode.Scalar) -> String? {
    let v = scalar.value
    if v < 0x20 && v != 0x09 && v != 0x0A {
        if let mapped = Unicode.Scalar(v + 0x40) {
            return "^\(mapped)"
        }
    } else if v == 0x7F {
        return "^?"
    } else if v >= 0x80 && v <= 0x9F {
        let hi = hexLowerDigits[Int((v >> 4) & 0xF)]
        let lo = hexLowerDigits[Int(v & 0xF)]
        return "<\(hi)\(lo)>"
    }
    return nil
}

private func applyStyleDefinition(
    _ def: StyleDefinition,
    fg: inout RGBA,
    bg: inout RGBA,
    attributes: inout UInt32
) {
    if let styleFg = def.fg { fg = styleFg }
    if let styleBg = def.bg { bg = styleBg }
    if def.bold == true { attributes |= TextAttributes.bold }
    if def.italic == true { attributes |= TextAttributes.italic }
    if def.underline == true { attributes |= TextAttributes.underline }
    if def.dim == true { attributes |= TextAttributes.dim }
    if def.strikethrough == true { attributes |= TextAttributes.strikethrough }
}

private func emptyVisualCursor() -> VisualCursor {
    VisualCursor(visualRow: 0, visualCol: 0, logicalRow: 0, logicalCol: 0, offset: 0)
}

// MARK: - EditBufferRenderable

/// Base editable text renderable wrapping `EditBuffer` and `EditorView`,
/// providing intrinsic Flexbox measurement, cursor reporting, mouse/keyboard selection,
/// scroll wheel & auto-scroll, syntax highlights, extmarks, placeholder, and cell rendering.
// parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable [status=implemented hash=dfdfc8926ae6]
open class EditBufferRenderable: Renderable, LineInfoProvider, @unchecked Sendable {
    public static let defaultTextColor = RGBA.fromValues(1, 1, 1, 1)
    public static let defaultBackgroundColor = RGBA.fromValues(0, 0, 0, 0)
    public static let defaultWrapMode: TextWrapMode = .word
    public static let defaultScrollMargin: Double = 0.2
    public static let defaultScrollSpeed: Double = 16
    public static let defaultShowCursor: Bool = true
    public static let defaultCursorColor = RGBA.fromValues(1, 1, 1, 1)
    public static let defaultCursorStyle = CursorStyleOptions(style: .block, blinking: true)

    public let editBuffer: EditBuffer
    public let editorView: EditorView

    private var _traits: EditorTraits = EditorTraits()
    private var _traitsChangeListeners: [(id: UInt64, fn: (EditorTraits, EditorTraits) -> Void)] = []
    private var _nextTraitsListenerId: UInt64 = 1

    internal var _textColor: RGBA
    internal var _backgroundColor: RGBA
    internal var _focusedTextColor: RGBA?
    internal var _focusedBackgroundColor: RGBA?
    internal var _defaultAttributes: UInt32
    internal var _selectionBg: RGBA?
    internal var _selectionFg: RGBA?
    internal var _wrapMode: TextWrapMode
    internal var _scrollMargin: Double = EditBufferRenderable.defaultScrollMargin
    internal var _showCursor: Bool
    internal var _cursorColor: RGBA
    internal var _cursorStyle: CursorStyleOptions
    internal var lastLocalSelection: LocalSelectionBounds? = nil
    internal var _tabIndicator: TabIndicatorValue?
    internal var _tabIndicatorColor: RGBA?
    private var _syntaxStyle: SyntaxStyle? = nil
    private var _extmarksInitialized: Bool = false

    private var _cursorChangeListener: ((CursorChangeEvent) -> Void)?
    private var _contentChangeListener: ((ContentChangeEvent) -> Void)?
    private var _lastNotifiedCursor: LogicalCursor = LogicalCursor()
    private var _lastNotifiedText: String = ""

    private var _autoScrollVelocity: Double = 0
    private var _autoScrollAccumulator: Double = 0
    private var _scrollSpeed: Double
    private var _keyboardSelectionActive: Bool = false
    private var _keyboardSelectionAnchorOffset: Int? = nil
    private var _selectionNotificationSeen: Bool = false

    public init(ctx: any RenderContext, options: EditBufferOptions = EditBufferOptions()) {
        var renderableOpts = options.renderable
        if renderableOpts.focusable == nil {
            renderableOpts.focusable = true
        }
        renderableOpts.selectable = options.selectable ?? renderableOpts.selectable ?? true

        let resolvedTextColor = RGBA.clone(options.textColor?.resolved() ?? Self.defaultTextColor)
        let resolvedBgColor = RGBA.clone(options.backgroundColor?.resolved() ?? Self.defaultBackgroundColor)
        let resolvedFocusedTextColor = options.focusedTextColor.map { RGBA.clone($0.resolved()) }
        let resolvedFocusedBgColor = options.focusedBackgroundColor.map { RGBA.clone($0.resolved()) }

        self._textColor = resolvedTextColor
        self._backgroundColor = resolvedBgColor
        self._focusedTextColor = resolvedFocusedTextColor
        self._focusedBackgroundColor = resolvedFocusedBgColor
        self._defaultAttributes = options.attributes ?? 0
        self._selectionBg = options.selectionBg.map { RGBA.clone($0.resolved()) }
        self._selectionFg = options.selectionFg.map { RGBA.clone($0.resolved()) }
        self._wrapMode = options.wrapMode ?? Self.defaultWrapMode
        self._scrollSpeed = max(0, options.scrollSpeed ?? Self.defaultScrollSpeed)
        self._showCursor = options.showCursor ?? Self.defaultShowCursor
        self._cursorColor = RGBA.clone(options.cursorColor?.resolved() ?? Self.defaultCursorColor)
        var style = options.cursorStyle ?? Self.defaultCursorStyle
        if let styleColor = style.color {
            style.color = RGBA.clone(styleColor)
        }
        self._cursorStyle = style
        self._tabIndicator = options.tabIndicator
        self._tabIndicatorColor = options.tabIndicatorColor.map { RGBA.clone($0.resolved()) }
        self._syntaxStyle = options.syntaxStyle
        self._cursorChangeListener = options.onCursorChange
        self._contentChangeListener = options.onContentChange

        let eb = EditBuffer.create(widthMethod: toTextWidthMethod(ctx.widthMethod))
        self.editBuffer = eb
        let initialWidth: Int
        if case .point(let w) = renderableOpts.width, w.isFinite, w > 0 {
            initialWidth = max(1, Int(w.rounded(.towardZero)))
        } else {
            initialWidth = 80
        }
        let initialHeight: Int
        if case .point(let h) = renderableOpts.height, h.isFinite, h > 0 {
            initialHeight = max(1, Int(h.rounded(.towardZero)))
        } else {
            initialHeight = 24
        }
        self.editorView = EditorView.create(editBuffer: eb, viewportWidth: initialWidth, viewportHeight: initialHeight)

        super.init(ctx: ctx, options: renderableOpts)

        self.editorView.setWrapMode(self._wrapMode)
        let margin = options.scrollMargin ?? Self.defaultScrollMargin
        self._scrollMargin = max(0.0, min(0.5, margin))
        self.editorView.setScrollMargin(self._scrollMargin)

        if let occupancy = options.selectionOccupancy {
            self.editorView.setSelectionOccupancy(occupancy)
        }

        self.editBuffer.setDefaultFg(self._textColor)
        self.editBuffer.setDefaultBg(self._backgroundColor)
        self.editBuffer.setDefaultAttributes(self._defaultAttributes)

        if let tabInd = self._tabIndicator {
            applyTabIndicator(tabInd)
        }
        if let tabIndColor = self._tabIndicatorColor {
            self.editorView.setTabIndicatorColor(tabIndColor)
        }

        setupMeasureProvider()
        self._lastNotifiedCursor = self.editBuffer.getCursorPosition()
        self._lastNotifiedText = self.editBuffer.getText()
    }

    private func setupMeasureProvider() {
        setMeasureProvider { [weak self] width, widthMode, height, heightMode in
            guard let self, !self.isDestroyed, !self.editorView.isDestroyed else {
                return FlexSize(width: 1, height: 1)
            }
            let effectiveWidth: Int
            if widthMode == .undefined || !width.isFinite {
                effectiveWidth = 0
            } else {
                effectiveWidth = max(1, Int(width.rounded(.down)))
            }
            let effectiveHeight: Int
            if heightMode == .undefined || !height.isFinite {
                effectiveHeight = 0
            } else {
                effectiveHeight = max(1, Int(height.rounded(.down)))
            }

            if let measured = self.editorView.measureForDimensions(width: effectiveWidth, height: effectiveHeight) {
                let measuredW = max(1, measured.widthColsMax)
                let measuredH = max(1, measured.lineCount)
                let finalW = (widthMode == .atMost && effectiveWidth > 0) ? min(measuredW, effectiveWidth) : measuredW
                let finalH = (heightMode == .atMost && effectiveHeight > 0) ? min(measuredH, effectiveHeight) : measuredH
                return FlexSize(width: Float(finalW), height: Float(finalH))
            }
            return FlexSize(width: 1, height: 1)
        }
    }

    private func applyTabIndicator(_ value: TabIndicatorValue) {
        switch value {
        case .string(let s):
            editorView.setTabIndicator(s)
        case .codePoint(let cp):
            editorView.setTabIndicator(codePoint: cp)
        }
    }

    internal func notifyEditStateChanged() {
        guard !isDestroyed && !editBuffer.isDestroyed else { return }
        let currentText = editBuffer.getText()
        let contentChanged = currentText != _lastNotifiedText
        if contentChanged {
            _lastNotifiedText = currentText
            invalidateIntrinsicSize()
            requestRender()
            emit("line-info-change")
            _contentChangeListener?(ContentChangeEvent())
        }

        guard !isDestroyed && !editBuffer.isDestroyed else { return }
        let currentCursor = editBuffer.getCursorPosition()
        if currentCursor != _lastNotifiedCursor {
            _lastNotifiedCursor = currentCursor
            _cursorChangeListener?(CursorChangeEvent(line: currentCursor.row, visualColumn: currentCursor.col))
        }
    }

    internal func syncBaselineStateWithoutNotifying() {
        guard !isDestroyed && !editBuffer.isDestroyed else { return }
        _lastNotifiedText = editBuffer.getText()
        _lastNotifiedCursor = editBuffer.getCursorPosition()
    }

    internal var effectiveTextColor: RGBA {
        (_focused ? (_focusedTextColor ?? _textColor) : _textColor)
    }

    internal var effectiveBackgroundColor: RGBA {
        (_focused ? (_focusedBackgroundColor ?? _backgroundColor) : _backgroundColor)
    }

    internal func syncDefaultBufferColors() {
        guard !isDestroyed && !editBuffer.isDestroyed else { return }
        editBuffer.setDefaultFg(effectiveTextColor)
        editBuffer.setDefaultBg(effectiveBackgroundColor)
    }

    // MARK: - LineInfoProvider

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.lineInfo [status=implemented hash=16dd85e0f58e]
    public var lineInfo: LineInfo {
        editorView.getLogicalLineInfo()
    }

    public func getLineSources(startLine: Int, lineCount: Int) -> [Int] {
        editorView.textBufferView.getLineSources(startLine: startLine, lineCount: lineCount)
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.lineCount [status=implemented hash=914cbfc4ee60]
    public var lineCount: Int {
        editBuffer.getLineCount()
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.virtualLineCount [status=implemented hash=876eab63c14c]
    public var virtualLineCount: Int {
        editorView.getVirtualLineCount()
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.scrollY [status=implemented hash=b4d6d36a92f1]
    public var scrollY: Int {
        editorView.getViewport().offsetY
    }

    // MARK: - Properties

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.scrollMargin [status=implemented hash=0a7f7e4e9515]
    public var scrollMargin: Double {
        get { _scrollMargin }
        set {
            guard !isDestroyed, newValue.isFinite else { return }
            let clamped = max(0.0, min(0.5, newValue))
            editorView.setScrollMargin(clamped)
            _scrollMargin = clamped
        }
    }

    /// Buffer text with LF line breaks. Index or slice in UTF-16 code units, not display-cell offsets.
    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.plainText [status=implemented hash=df50a197a492]
    public var plainText: String {
        editBuffer.getText()
    }

    /// Logical row, display-cell column, and document cell offset (counting one per newline).
    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.logicalCursor [status=implemented hash=a0bbe7a173df]
    public var logicalCursor: LogicalCursor {
        editBuffer.getCursorPosition()
    }

    /// Viewport-relative wrapped row and display-cell column, plus logical coordinates and cell offset.
    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.visualCursor [status=implemented hash=4e5989e65c9f]
    public var visualCursor: VisualCursor {
        if editorView.isDestroyed { return emptyVisualCursor() }
        return editorView.getVisualCursor()
    }

    /// Document display-cell offset from start (counting one per newline).
    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.cursorOffset [status=implemented hash=9093c76b6ad6]
    public var cursorOffset: Int {
        get {
            editorView.isDestroyed ? 0 : editBuffer.getCursorPosition().offset
        }
        set {
            resetSelection()
            editorView.setCursorByOffset(newValue)
            notifyEditStateChanged()
            requestRender()
        }
    }

    /// Legacy under-cursor lookup with line-end adjustments.
    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.cursorCharacterOffset [status=implemented hash=a8820e6f4417]
    public var cursorCharacterOffset: Int? {
        let text = plainText
        let utf16Units = Array(text.utf16)
        let len = utf16Units.count
        guard len > 0 else { return nil }

        let cursor = logicalCursor
        let offset = cursorOffset
        if offset >= len {
            if cursor.col > 0 { return len - 1 }
            return 0
        }
        if offset >= 0 && offset < len && utf16Units[offset] == 0x0A && cursor.col > 0 {
            return offset - 1
        }
        return offset
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.textColor [status=implemented hash=c91c3c87c557]
    open var textColor: RGBA {
        get { RGBA.clone(_textColor) }
        set {
            let newColor = RGBA.clone(newValue)
            _textColor = newColor
            syncDefaultBufferColors()
            requestRender()
        }
    }

    public func setTextColor(_ color: Color?) {
        textColor = color?.resolved() ?? Self.defaultTextColor
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.backgroundColor [status=implemented hash=81a56a76ea69]
    open var backgroundColor: RGBA {
        get { RGBA.clone(_backgroundColor) }
        set {
            let newColor = RGBA.clone(newValue)
            _backgroundColor = newColor
            syncDefaultBufferColors()
            requestRender()
        }
    }

    public func setBackgroundColor(_ color: Color?) {
        backgroundColor = color?.resolved() ?? Self.defaultBackgroundColor
    }

    open var focusedTextColor: RGBA? {
        get { _focusedTextColor.map { RGBA.clone($0) } }
        set {
            _focusedTextColor = newValue.map { RGBA.clone($0) }
            syncDefaultBufferColors()
            requestRender()
        }
    }

    open var focusedBackgroundColor: RGBA? {
        get { _focusedBackgroundColor.map { RGBA.clone($0) } }
        set {
            _focusedBackgroundColor = newValue.map { RGBA.clone($0) }
            syncDefaultBufferColors()
            requestRender()
        }
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.selectionBg [status=implemented hash=731aeaaffc82]
    public var selectionBg: RGBA? {
        get { _selectionBg.map { RGBA.clone($0) } }
        set {
            let newColor = newValue.map { RGBA.clone($0) }
            if _selectionBg != newColor {
                editorView.setSelectionColors(bgColor: newColor, fgColor: _selectionFg)
                _selectionBg = newColor
                requestRender()
            }
        }
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.selectionFg [status=implemented hash=2f7609140328]
    public var selectionFg: RGBA? {
        get { _selectionFg.map { RGBA.clone($0) } }
        set {
            let newColor = newValue.map { RGBA.clone($0) }
            if _selectionFg != newColor {
                editorView.setSelectionColors(bgColor: _selectionBg, fgColor: newColor)
                _selectionFg = newColor
                requestRender()
            }
        }
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.traits [status=implemented hash=dba384cccfe3]
    public var traits: EditorTraits {
        get { _traits }
        set {
            guard _traits != newValue else { return }
            let prev = _traits
            _traits = newValue
            for entry in _traitsChangeListeners {
                entry.fn(newValue, prev)
            }
            emit(EditBufferRenderableEvents.traitsChanged.rawValue)
        }
    }

    @discardableResult
    public func onTraitsChanged(_ listener: @escaping (EditorTraits, EditorTraits) -> Void) -> UInt64 {
        let id = _nextTraitsListenerId
        _nextTraitsListenerId &+= 1
        _traitsChangeListeners.append((id: id, fn: listener))
        return id
    }

    public func offTraitsChanged(_ id: UInt64) {
        _traitsChangeListeners.removeAll { $0.id == id }
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.attributes [status=implemented hash=0abe5cc94146]
    public var attributes: UInt32 {
        get { _defaultAttributes }
        set {
            if _defaultAttributes != newValue {
                editBuffer.setDefaultAttributes(newValue)
                _defaultAttributes = newValue
                requestRender()
            }
        }
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.wrapMode [status=implemented hash=875d9d29e1ef]
    public var wrapMode: TextWrapMode {
        get { _wrapMode }
        set {
            if _wrapMode != newValue {
                editorView.setWrapMode(newValue)
                _wrapMode = newValue
                invalidateIntrinsicSize()
                requestRender()
            }
        }
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.showCursor [status=implemented hash=bc8886df97d9]
    public var showCursor: Bool {
        get { _showCursor }
        set {
            if _showCursor != newValue {
                _showCursor = newValue
                if _focused && !newValue {
                    ctx.setCursorPosition(x: 1, y: 1, visible: false)
                }
                requestRender()
            }
        }
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.cursorColor [status=implemented hash=5ad4b19a66e1]
    public var cursorColor: RGBA {
        get { RGBA.clone(_cursorColor) }
        set {
            _cursorColor = RGBA.clone(newValue)
            if _focused {
                ctx.setCursorColor(_cursorColor)
                requestRender()
            }
        }
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.cursorStyle [status=implemented hash=1fe4938e9b15]
    public var cursorStyle: CursorStyleOptions {
        get {
            var copy = _cursorStyle
            if let c = copy.color { copy.color = RGBA.clone(c) }
            return copy
        }
        set {
            var copy = newValue
            if let c = copy.color { copy.color = RGBA.clone(c) }
            if _cursorStyle != copy {
                _cursorStyle = copy
                if _focused {
                    requestRender()
                }
            }
        }
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.selectionOccupancy [status=implemented hash=46eb0fb86a56]
    public var selectionOccupancy: SelectionOccupancy {
        get { editorView.getSelectionOccupancy() }
        set {
            if editorView.getSelectionOccupancy() != newValue {
                editorView.setSelectionOccupancy(newValue)
                if lastLocalSelection != nil {
                    _ = refreshLocalSelection()
                }
                requestRender()
            }
        }
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.tabIndicator [status=implemented hash=1fe4c826b29e]
    public var tabIndicator: TabIndicatorValue? {
        get { _tabIndicator }
        set {
            if _tabIndicator != newValue {
                _tabIndicator = newValue
                if let newValue {
                    applyTabIndicator(newValue)
                } else {
                    editorView.setTabIndicator(codePoint: 0)
                }
                requestRender()
            }
        }
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.tabIndicatorColor [status=implemented hash=035cc5d39725]
    public var tabIndicatorColor: RGBA? {
        get { _tabIndicatorColor.map { RGBA.clone($0) } }
        set {
            let newColor = newValue.map { RGBA.clone($0) }
            if _tabIndicatorColor != newColor {
                if let newColor {
                    editorView.setTabIndicatorColor(newColor)
                }
                _tabIndicatorColor = newColor
                requestRender()
            }
        }
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.scrollSpeed [status=implemented hash=90fe89d43b6f]
    public var scrollSpeed: Double {
        get { _scrollSpeed }
        set { _scrollSpeed = max(0, newValue) }
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.onCursorChange [status=implemented hash=dea76855ecf6]
    public var onCursorChange: ((CursorChangeEvent) -> Void)? {
        get { _cursorChangeListener }
        set { _cursorChangeListener = newValue }
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.onContentChange [status=implemented hash=9151d320b264]
    public var onContentChange: ((ContentChangeEvent) -> Void)? {
        get { _contentChangeListener }
        set { _contentChangeListener = newValue }
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.syntaxStyle [status=implemented hash=5b7e3eaef08a]
    public var syntaxStyle: SyntaxStyle? {
        get { _syntaxStyle }
        set {
            _syntaxStyle = newValue
            requestRender()
        }
    }

    /// Lazily-created `ExtmarksController` for tracked normal and virtual extmarks.
    open var extmarks: ExtmarksController {
        _extmarksInitialized = true
        return editorView.extmarks
    }

    // MARK: - Mouse & Scroll

    open override func onMouseEvent(_ event: MouseEvent) {
        if event.type == .scroll {
            _ = scrollOnce(event: event.scrollChainToken, scroller: self) {
                let before = self.editorView.getViewport()
                self.handleScroll(event)
                let after = self.editorView.getViewport()
                self.notifyEditStateChanged()
                return after.offsetX != before.offsetX || after.offsetY != before.offsetY
            }
        }
    }

    open func handleScroll(_ event: MouseEvent) {
        guard let scroll = event.scroll else { return }
        let delta = scroll.delta
        let direction = wheelDirection(
            direction: scrollDirectionToWheelDirection(scroll.direction),
            shift: event.modifiers.shift
        )
        let viewport = editorView.getViewport()

        if direction == .up {
            let newOffsetY = max(0, viewport.offsetY - delta)
            editorView.setViewport(x: viewport.offsetX, y: newOffsetY, width: viewport.width, height: viewport.height, moveCursor: true)
            requestRender()
        } else if direction == .down {
            let totalVirtualLines = editorView.getTotalVirtualLineCount()
            let maxOffsetY = max(0, totalVirtualLines - viewport.height)
            let newOffsetY = min(viewport.offsetY + delta, maxOffsetY)
            editorView.setViewport(x: viewport.offsetX, y: newOffsetY, width: viewport.width, height: viewport.height, moveCursor: true)
            requestRender()
        }

        if _wrapMode == .none {
            if direction == .left {
                let newOffsetX = max(0, viewport.offsetX - delta)
                editorView.setViewport(x: newOffsetX, y: viewport.offsetY, width: viewport.width, height: viewport.height, moveCursor: true)
                requestRender()
            } else if direction == .right {
                let maxOffsetX = max(0, lineInfo.lineWidthColsMax - viewport.width)
                let newOffsetX = min(viewport.offsetX + delta, max(viewport.offsetX, maxOffsetX))
                editorView.setViewport(x: newOffsetX, y: viewport.offsetY, width: viewport.width, height: viewport.height, moveCursor: true)
                requestRender()
            }
        }
    }

    open override func onResize(width: Int, height: Int) {
        if !editorView.isDestroyed {
            editorView.setViewportSize(width: max(1, width), height: max(1, height))
        }
        super.onResize(width: width, height: height)
    }

    // MARK: - Selection

    @discardableResult
    open func refreshLocalSelection() -> Bool {
        if let local = lastLocalSelection {
            return updateLocalSelection(local)
        }
        return false
    }

    private func updateLocalSelection(_ localSelection: LocalSelectionBounds?) -> Bool {
        guard let localSelection, localSelection.isActive else {
            editorView.resetLocalSelection()
            return true
        }
        return editorView.setLocalSelection(
            anchorX: localSelection.anchorX,
            anchorY: localSelection.anchorY,
            focusX: localSelection.focusX,
            focusY: localSelection.focusY,
            bgColor: _selectionBg,
            fgColor: _selectionFg,
            updateCursor: false,
            followCursor: false,
            behavior: localSelection.behavior
        )
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.shouldStartSelection [status=implemented hash=c87c8f8d1d8e]
    open override func shouldStartSelection(x: Int, y: Int) -> Bool {
        guard selectable else { return false }
        let localX = x - self.x
        let localY = y - self.y
        return localX >= 0 && localX < width && localY >= 0 && localY < height
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.onSelectionChanged [status=implemented hash=0bfc64be61a1]
    @discardableResult
    open override func onSelectionChanged(_ selection: Selection?) -> Bool {
        _selectionNotificationSeen = true
        let localSelection = convertGlobalToLocalSelection(selection, localX: x, localY: y)
        lastLocalSelection = localSelection

        let updateCursor = true
        let followCursor = _keyboardSelectionActive

        let changed: Bool
        if let localSelection, localSelection.isActive {
            if selection?.isStart == true {
                changed = editorView.setLocalSelection(
                    anchorX: localSelection.anchorX,
                    anchorY: localSelection.anchorY,
                    focusX: localSelection.focusX,
                    focusY: localSelection.focusY,
                    bgColor: _selectionBg,
                    fgColor: _selectionFg,
                    updateCursor: updateCursor,
                    followCursor: followCursor,
                    behavior: localSelection.behavior
                )
            } else {
                changed = editorView.updateLocalSelection(
                    anchorX: localSelection.anchorX,
                    anchorY: localSelection.anchorY,
                    focusX: localSelection.focusX,
                    focusY: localSelection.focusY,
                    bgColor: _selectionBg,
                    fgColor: _selectionFg,
                    updateCursor: updateCursor,
                    followCursor: followCursor,
                    behavior: localSelection.behavior
                )
            }
        } else {
            _keyboardSelectionActive = false
            _keyboardSelectionAnchorOffset = nil
            editorView.resetLocalSelection()
            changed = true
        }

        if changed, let localSelection, localSelection.isActive, selection?.isDragging == true {
            let viewport = editorView.getViewport()
            let focusY = localSelection.focusY
            let marginRows = max(1, Int((Double(viewport.height) * _scrollMargin).rounded(.down)))
            if focusY < marginRows {
                _autoScrollVelocity = -_scrollSpeed
            } else if focusY >= viewport.height - marginRows {
                _autoScrollVelocity = _scrollSpeed
            } else {
                _autoScrollVelocity = 0
            }
        } else {
            _keyboardSelectionActive = false
            _autoScrollVelocity = 0
            _autoScrollAccumulator = 0
        }

        if changed {
            requestRender()
        }
        notifyEditStateChanged()

        return hasSelection()
    }

    open override func onUpdate(deltaTime: Double) {
        super.onUpdate(deltaTime: deltaTime)

        if _autoScrollVelocity != 0 && hasSelection() {
            let deltaSeconds = deltaTime / 1000.0
            _autoScrollAccumulator += _autoScrollVelocity * deltaSeconds
            let linesToScroll = Int(abs(_autoScrollAccumulator).rounded(.down))
            if linesToScroll > 0 {
                let direction = _autoScrollVelocity > 0 ? 1 : -1
                let viewport = editorView.getViewport()
                let totalVirtualLines = editorView.getTotalVirtualLineCount()
                let maxOffsetY = max(0, totalVirtualLines - viewport.height)
                let newOffsetY = max(0, min(viewport.offsetY + direction * linesToScroll, maxOffsetY))

                if newOffsetY != viewport.offsetY {
                    editorView.setViewport(
                        x: viewport.offsetX,
                        y: newOffsetY,
                        width: viewport.width,
                        height: viewport.height,
                        moveCursor: false
                    )
                    ctx.requestSelectionUpdate()
                }
                _autoScrollAccumulator -= Double(direction * linesToScroll)
            }
        }
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.getSelectedText [status=implemented hash=cc0cb2f8764d]
    open override func getSelectedText() -> String {
        editorView.getSelectedText()
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.hasSelection [status=implemented hash=9bbd2a0f1dbc]
    open override func hasSelection() -> Bool {
        editorView.hasSelection()
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.getSelection [status=implemented hash=b83799385fb0]
    public func getSelection() -> TextSelectionRange? {
        editorView.getSelection()
    }

    private func deleteSelectedText() {
        _keyboardSelectionAnchorOffset = nil
        editorView.deleteSelectedText()
        ctx.clearSelection()
        notifyEditStateChanged()
        requestRender()
    }

    internal func resetSelection() {
        lastLocalSelection = nil
        _keyboardSelectionAnchorOffset = nil
        editorView.resetLocalSelection()
        ctx.clearSelection()
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.setSelection [status=implemented hash=c54f86efc33b]
    public func setSelection(start: Int, end: Int) {
        resetSelection()
        editorView.setSelection(start: start, end: end, bgColor: _selectionBg, fgColor: _selectionFg)
        requestRender()
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.setSelectionInclusive [status=implemented hash=ef977dce3f30]
    public func setSelectionInclusive(start: Int, end: Int) {
        resetSelection()
        editorView.setSelectionInclusive(start: start, end: end, bgColor: _selectionBg, fgColor: _selectionFg)
        requestRender()
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.clearSelection [status=implemented hash=a2a8c1a4a284]
    @discardableResult
    public func clearSelection() -> Bool {
        let had = hasSelection()
        resetSelection()
        if had {
            requestRender()
        }
        return had
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.deleteSelection [status=implemented hash=d7e81fa94bc2]
    @discardableResult
    public func deleteSelection() -> Bool {
        guard hasSelection() else { return false }
        lastLocalSelection = nil
        deleteSelectedText()
        return true
    }

    // MARK: - Editing & Movement

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.setCursor [status=implemented hash=03852bee7358]
    public func setCursor(row: Int, col: Int) {
        _ = clearSelection()
        editBuffer.setCursor(line: row, col: col)
        notifyEditStateChanged()
        requestRender()
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.insertChar [status=implemented hash=60dd6919c498]
    open func insertChar(_ char: String) {
        insertOrReplaceSelection(char) {
            editBuffer.insertChar(char)
        }
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.insertText [status=implemented hash=e9de2deee402]
    open func insertText(_ text: String) {
        insertOrReplaceSelection(text) {
            editBuffer.insertText(text)
        }
    }

    private func insertOrReplaceSelection(_ text: String, insert: () -> Void) {
        let hadSel = hasSelection()
        editBuffer.runMutation {
            if hadSel {
                _keyboardSelectionAnchorOffset = nil
                editorView.replaceSelectedText(text)
                ctx.clearSelection()
            } else {
                insert()
            }
            notifyEditStateChanged()
            requestRender()
        }
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.deleteChar [status=implemented hash=bb0d1339c8ca]
    @discardableResult
    open func deleteChar() -> Bool {
        if hasSelection() {
            deleteSelectedText()
            return true
        }
        ctx.clearSelection()
        editBuffer.deleteChar()
        notifyEditStateChanged()
        requestRender()
        return true
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.deleteCharBackward [status=implemented hash=7e77191ca67a]
    @discardableResult
    open func deleteCharBackward() -> Bool {
        if hasSelection() {
            deleteSelectedText()
            return true
        }
        ctx.clearSelection()
        editBuffer.deleteCharBackward()
        notifyEditStateChanged()
        requestRender()
        return true
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.newLine [status=implemented hash=3cdd1cd93e29]
    @discardableResult
    open func newLine() -> Bool {
        if hasSelection() {
            deleteSelectedText()
        } else {
            ctx.clearSelection()
        }
        editBuffer.newLine()
        notifyEditStateChanged()
        requestRender()
        return true
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.deleteLine [status=implemented hash=20098f9ec172]
    @discardableResult
    open func deleteLine() -> Bool {
        ctx.clearSelection()
        editBuffer.deleteLine()
        notifyEditStateChanged()
        requestRender()
        return true
    }

    private enum SelectionEdge {
        case start
        case end
    }

    private func collapseSelectionToEdge(_ edge: SelectionEdge) -> Bool {
        guard let selection = getSelection() else { return false }
        let target = edge == .start ? selection.start : selection.end
        editBuffer.setCursorByOffset(target)
        resetSelection()
        notifyEditStateChanged()
        requestRender()
        return true
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.moveCursorLeft [status=implemented hash=f8a89477a110]
    @discardableResult
    open func moveCursorLeft(select: Bool = false) -> Bool {
        if !select && collapseSelectionToEdge(.start) { return true }
        updateSelectionForMovement(shiftPressed: select, isBeforeMovement: true)
        editBuffer.moveCursorLeft()
        if select { updateSelectionForMovement(shiftPressed: true, isBeforeMovement: false) }
        notifyEditStateChanged()
        requestRender()
        return true
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.moveCursorRight [status=implemented hash=ea8acab5f5ef]
    @discardableResult
    open func moveCursorRight(select: Bool = false) -> Bool {
        if !select && collapseSelectionToEdge(.end) { return true }
        updateSelectionForMovement(shiftPressed: select, isBeforeMovement: true)
        editBuffer.moveCursorRight()
        if select { updateSelectionForMovement(shiftPressed: true, isBeforeMovement: false) }
        notifyEditStateChanged()
        requestRender()
        return true
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.moveCursorUp [status=implemented hash=f66813dd03f2]
    @discardableResult
    open func moveCursorUp(select: Bool = false) -> Bool {
        updateSelectionForMovement(shiftPressed: select, isBeforeMovement: true)
        editorView.moveUpVisual()
        if select { updateSelectionForMovement(shiftPressed: true, isBeforeMovement: false) }
        notifyEditStateChanged()
        requestRender()
        return true
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.moveCursorDown [status=implemented hash=8dbd5b753110]
    @discardableResult
    open func moveCursorDown(select: Bool = false) -> Bool {
        updateSelectionForMovement(shiftPressed: select, isBeforeMovement: true)
        editorView.moveDownVisual()
        if select { updateSelectionForMovement(shiftPressed: true, isBeforeMovement: false) }
        notifyEditStateChanged()
        requestRender()
        return true
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.gotoLine [status=implemented hash=4b6e047dc481]
    public func gotoLine(_ line: Int) {
        _ = clearSelection()
        editBuffer.gotoLine(line)
        notifyEditStateChanged()
        requestRender()
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.gotoLineStart [status=implemented hash=d9e7e4762811]
    public func gotoLineStart() {
        setCursor(row: logicalCursor.row, col: 0)
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.gotoLineTextEnd [status=implemented hash=50f373768a26]
    public func gotoLineTextEnd() {
        let eol = editBuffer.getEOL()
        setCursor(row: eol.row, col: eol.col)
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.gotoLineHome [status=implemented hash=40b70ecfa9e0]
    @discardableResult
    open func gotoLineHome(select: Bool = false) -> Bool {
        if !select && collapseSelectionToEdge(.start) { return true }
        updateSelectionForMovement(shiftPressed: select, isBeforeMovement: true)
        let cursor = editorView.getCursor()
        if cursor.col == 0 && cursor.row > 0 {
            editBuffer.setCursor(line: cursor.row - 1, col: 0)
            let prevLineEol = editBuffer.getEOL()
            editBuffer.setCursor(line: prevLineEol.row, col: prevLineEol.col)
        } else {
            editBuffer.setCursor(line: cursor.row, col: 0)
        }
        updateSelectionForMovement(shiftPressed: select, isBeforeMovement: false)
        notifyEditStateChanged()
        requestRender()
        return true
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.gotoLineEnd [status=implemented hash=ffe9cd553f7a]
    @discardableResult
    open func gotoLineEnd(select: Bool = false) -> Bool {
        if !select && collapseSelectionToEdge(.end) { return true }
        updateSelectionForMovement(shiftPressed: select, isBeforeMovement: true)
        let cursor = editorView.getCursor()
        let eol = editBuffer.getEOL()
        let totalLines = editBuffer.getLineCount()
        if cursor.col == eol.col && cursor.row < totalLines - 1 {
            editBuffer.setCursor(line: cursor.row + 1, col: 0)
        } else {
            editBuffer.setCursor(line: eol.row, col: eol.col)
        }
        updateSelectionForMovement(shiftPressed: select, isBeforeMovement: false)
        notifyEditStateChanged()
        requestRender()
        return true
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.gotoVisualLineHome [status=implemented hash=2e9743234a26]
    @discardableResult
    open func gotoVisualLineHome(select: Bool = false) -> Bool {
        if !select && collapseSelectionToEdge(.start) { return true }
        updateSelectionForMovement(shiftPressed: select, isBeforeMovement: true)
        let sol = editorView.getVisualSOL()
        editBuffer.setCursor(line: sol.logicalRow, col: sol.logicalCol)
        updateSelectionForMovement(shiftPressed: select, isBeforeMovement: false)
        notifyEditStateChanged()
        requestRender()
        return true
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.gotoVisualLineEnd [status=implemented hash=549f931a60eb]
    @discardableResult
    open func gotoVisualLineEnd(select: Bool = false) -> Bool {
        if !select && collapseSelectionToEdge(.end) { return true }
        updateSelectionForMovement(shiftPressed: select, isBeforeMovement: true)
        editorView.gotoVisualLineEnd()
        updateSelectionForMovement(shiftPressed: select, isBeforeMovement: false)
        notifyEditStateChanged()
        requestRender()
        return true
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.gotoBufferHome [status=implemented hash=b37f77079ea5]
    @discardableResult
    open func gotoBufferHome(select: Bool = false) -> Bool {
        if !select && collapseSelectionToEdge(.start) { return true }
        updateSelectionForMovement(shiftPressed: select, isBeforeMovement: true)
        editBuffer.setCursor(line: 0, col: 0)
        updateSelectionForMovement(shiftPressed: select, isBeforeMovement: false)
        notifyEditStateChanged()
        requestRender()
        return true
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.gotoBufferEnd [status=implemented hash=32951c9589bd]
    @discardableResult
    open func gotoBufferEnd(select: Bool = false) -> Bool {
        if !select && collapseSelectionToEdge(.end) { return true }
        updateSelectionForMovement(shiftPressed: select, isBeforeMovement: true)
        let lastRow = max(0, editBuffer.getLineCount() - 1)
        editBuffer.gotoLine(lastRow)
        let eol = editBuffer.getEOL()
        editBuffer.setCursor(line: eol.row, col: eol.col)
        updateSelectionForMovement(shiftPressed: select, isBeforeMovement: false)
        notifyEditStateChanged()
        requestRender()
        return true
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.selectAll [status=implemented hash=a23ace6b4094]
    @discardableResult
    open func selectAll() -> Bool {
        guard !isDestroyed && !editorView.isDestroyed else { return false }
        let lastRow = max(0, editBuffer.getLineCount() - 1)
        editBuffer.gotoLine(lastRow)
        let eol = editBuffer.getEOL()
        resetSelection()
        editBuffer.setCursor(line: eol.row, col: eol.col)
        if eol.offset > 0 {
            _keyboardSelectionAnchorOffset = 0
            editorView.setSelection(start: 0, end: eol.offset, bgColor: _selectionBg, fgColor: _selectionFg)
        }
        notifyEditStateChanged()
        requestRender()
        return true
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.deleteToLineEnd [status=implemented hash=c76ae614a1a8]
    @discardableResult
    open func deleteToLineEnd() -> Bool {
        let cursor = editorView.getCursor()
        let eol = editBuffer.getEOL()
        if eol.col > cursor.col {
            editBuffer.deleteRange(startLine: cursor.row, startCol: cursor.col, endLine: eol.row, endCol: eol.col)
        }
        notifyEditStateChanged()
        requestRender()
        return true
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.deleteToLineStart [status=implemented hash=3cb9d18929e9]
    @discardableResult
    open func deleteToLineStart() -> Bool {
        let cursor = editorView.getCursor()
        if cursor.col > 0 {
            editBuffer.deleteRange(startLine: cursor.row, startCol: 0, endLine: cursor.row, endCol: cursor.col)
        } else if cursor.row > 0 {
            editBuffer.deleteCharBackward()
        }
        notifyEditStateChanged()
        requestRender()
        return true
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.undo [status=implemented hash=03b9c1a7a569]
    @discardableResult
    open func undo() -> Bool {
        ctx.clearSelection()
        _ = editBuffer.undo()
        notifyEditStateChanged()
        requestRender()
        return true
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.redo [status=implemented hash=aba68b67de68]
    @discardableResult
    open func redo() -> Bool {
        ctx.clearSelection()
        _ = editBuffer.redo()
        notifyEditStateChanged()
        requestRender()
        return true
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.moveWordForward [status=implemented hash=d6ebe2a0e817]
    @discardableResult
    open func moveWordForward(select: Bool = false) -> Bool {
        if !select && collapseSelectionToEdge(.end) { return true }
        updateSelectionForMovement(shiftPressed: select, isBeforeMovement: true)
        let nextWord = editBuffer.getNextWordBoundary()
        editBuffer.setCursorByOffset(nextWord.offset)
        if select { updateSelectionForMovement(shiftPressed: true, isBeforeMovement: false) }
        notifyEditStateChanged()
        requestRender()
        return true
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.moveWordBackward [status=implemented hash=b57f33528617]
    @discardableResult
    open func moveWordBackward(select: Bool = false) -> Bool {
        if !select && collapseSelectionToEdge(.start) { return true }
        updateSelectionForMovement(shiftPressed: select, isBeforeMovement: true)
        let prevWord = editBuffer.getPrevWordBoundary()
        editBuffer.setCursorByOffset(prevWord.offset)
        if select { updateSelectionForMovement(shiftPressed: true, isBeforeMovement: false) }
        notifyEditStateChanged()
        requestRender()
        return true
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.deleteWordForward [status=implemented hash=dce2c9df0a89]
    @discardableResult
    open func deleteWordForward() -> Bool {
        if hasSelection() {
            deleteSelectedText()
            return true
        }
        let currentCursor = editBuffer.getCursorPosition()
        let nextWord = editBuffer.getNextWordBoundary()
        if nextWord.offset > currentCursor.offset {
            editBuffer.deleteRange(
                startLine: currentCursor.row,
                startCol: currentCursor.col,
                endLine: nextWord.row,
                endCol: nextWord.col
            )
        }
        ctx.clearSelection()
        notifyEditStateChanged()
        requestRender()
        return true
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.deleteWordBackward [status=implemented hash=dc3eb7e8a59d]
    @discardableResult
    open func deleteWordBackward() -> Bool {
        if hasSelection() {
            deleteSelectedText()
            return true
        }
        let currentCursor = editBuffer.getCursorPosition()
        let prevWord = editBuffer.getPrevWordBoundary()
        if prevWord.offset < currentCursor.offset {
            editBuffer.deleteRange(
                startLine: prevWord.row,
                startCol: prevWord.col,
                endLine: currentCursor.row,
                endCol: currentCursor.col
            )
        }
        ctx.clearSelection()
        notifyEditStateChanged()
        requestRender()
        return true
    }

    // MARK: - Highlights & Text Buffer Forwarding

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.addHighlight [status=implemented hash=7a4ace4ec28b]
    public func addHighlight(lineIdx: Int, highlight: Highlight) {
        editBuffer.addHighlight(lineIdx: lineIdx, highlight: highlight)
        requestRender()
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.addHighlightByCharRange [status=implemented hash=43ccedb96afc]
    public func addHighlightByCharRange(_ highlight: Highlight) {
        editBuffer.addHighlightByCharRange(highlight)
        requestRender()
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.removeHighlightsByRef [status=implemented hash=8e9ee6691a5f]
    public func removeHighlightsByRef(_ hlRef: Int) {
        editBuffer.removeHighlightsByRef(hlRef)
        requestRender()
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.clearLineHighlights [status=implemented hash=9dfa7457b212]
    public func clearLineHighlights(_ lineIdx: Int) {
        editBuffer.clearLineHighlights(lineIdx)
        requestRender()
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.clearAllHighlights [status=implemented hash=07b462f8d24a]
    public func clearAllHighlights() {
        editBuffer.clearAllHighlights()
        requestRender()
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.getLineHighlights [status=implemented hash=aaeaa85b4b44]
    public func getLineHighlights(_ lineIdx: Int) -> [Highlight] {
        editBuffer.getLineHighlights(lineIdx)
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.setText [status=implemented hash=51fae93c3d0e]
    open func setText(_ text: String) {
        editBuffer.runMutation {
            editBuffer.setText(text)
            notifyEditStateChanged()
            requestRender()
        }
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.replaceText [status=implemented hash=38a36016f89b]
    open func replaceText(_ text: String) {
        editBuffer.runMutation {
            editBuffer.replaceText(text)
            notifyEditStateChanged()
            requestRender()
        }
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.clear [status=implemented hash=81dab1366161]
    open func clear() {
        editBuffer.clear()
        editBuffer.clearAllHighlights()
        notifyEditStateChanged()
        requestRender()
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.deleteRange [status=implemented hash=4371737113c7]
    public func deleteRange(startLine: Int, startCol: Int, endLine: Int, endCol: Int) {
        editBuffer.deleteRange(startLine: startLine, startCol: startCol, endLine: endLine, endCol: endCol)
        notifyEditStateChanged()
        requestRender()
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.getTextRange [status=implemented hash=97e9b796b4d4]
    public func getTextRange(startOffset: Int, endOffset: Int) -> String {
        editBuffer.getTextRange(startOffset: startOffset, endOffset: endOffset)
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.getTextRangeByCoords [status=implemented hash=e813b7367dd4]
    public func getTextRangeByCoords(startRow: Int, startCol: Int, endRow: Int, endCol: Int) -> String {
        editBuffer.getTextRangeByCoords(startRow: startRow, startCol: startCol, endRow: endRow, endCol: endCol)
    }

    // MARK: - Focus & Lifecycle

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.focus [status=implemented hash=df96497eb9a4]
    open override func focus() {
        super.focus()
        syncDefaultBufferColors()
        requestRender()
    }

    // parity: core/src/renderables/EditBufferRenderable.ts#EditBufferRenderable.blur [status=implemented hash=460625b447c3]
    open override func blur() {
        let wasFocused = _focused
        super.blur()
        if wasFocused && !isDestroyed {
            ctx.setCursorPosition(x: 1, y: 1, visible: false)
        }
        syncDefaultBufferColors()
        requestRender()
    }

    open override func destroySelf() {
        traits = EditorTraits()
        _traitsChangeListeners.removeAll()
        if !editorView.isDestroyed {
            editorView.destroy()
        }
        if !editBuffer.isDestroyed {
            editBuffer.destroy()
        }
    }

    // MARK: - Keyboard Selection Helper

    open func updateSelectionForMovement(shiftPressed: Bool, isBeforeMovement: Bool) {
        if !shiftPressed {
            _keyboardSelectionActive = false
            _keyboardSelectionAnchorOffset = nil
            if isBeforeMovement {
                _ = clearSelection()
            }
            return
        }

        guard selectable else { return }
        _keyboardSelectionActive = true

        let visual = editorView.getVisualCursor()
        let cursorX = x + visual.visualCol
        let cursorY = y + visual.visualRow

        if isBeforeMovement {
            if !ctx.hasSelection || !hasSelection() {
                _keyboardSelectionAnchorOffset = editBuffer.getCursorPosition().offset
                _selectionNotificationSeen = false
                ctx.startSelection(self, x: cursorX, y: cursorY, behavior: .cell)
            } else if let sel = ctx.getSelection(), sel.behavior != .cell {
                if editorView.convertSelectionToCell() {
                    sel.behavior = .cell
                }
            }
            return
        }

        _selectionNotificationSeen = false
        ctx.updateSelection(self, x: cursorX, y: cursorY, finishDragging: true)

        // Fallback when node is not yet attached/laid out in the hit/viewport tree
        if !_selectionNotificationSeen, let anchorOffset = _keyboardSelectionAnchorOffset {
            let focusOffset = editBuffer.getCursorPosition().offset
            if editorView.getSelectionOccupancy() == .boundary {
                editorView.setSelection(
                    start: anchorOffset,
                    end: focusOffset,
                    bgColor: _selectionBg,
                    fgColor: _selectionFg
                )
            } else {
                editorView.setSelectionInclusive(
                    start: anchorOffset,
                    end: focusOffset,
                    bgColor: _selectionBg,
                    fgColor: _selectionFg
                )
            }
        }
    }

    // MARK: - Rendering

    open override func renderSelf(buffer: OptimizedBuffer, deltaTime: Double) {
        guard !isDestroyed && !editorView.isDestroyed && !editBuffer.isDestroyed else { return }
        let origin = paintOrigin(for: buffer)
        let drawWidth = width
        let drawHeight = height
        guard drawWidth > 0 && drawHeight > 0 else { return }

        let currentVp = editorView.getViewport()
        if currentVp.width != drawWidth || currentVp.height != drawHeight {
            editorView.setViewportSize(width: drawWidth, height: drawHeight)
        }

        let bg = effectiveBackgroundColor
        let fg = effectiveTextColor

        buffer.pushScissorRect(x: origin.x, y: origin.y, width: drawWidth, height: drawHeight)
        defer { buffer.popScissorRect() }

        if let fb = frameBuffer, buffer === fb {
            buffer.clear(bg: bg)
        } else {
            buffer.fillRect(x: origin.x, y: origin.y, width: drawWidth, height: drawHeight, bg: bg)
        }

        let isEmptyBuffer = editBuffer.getText().isEmpty
        if isEmptyBuffer && !editorView.placeholderChunks.isEmpty {
            renderPlaceholder(into: buffer, originX: origin.x, originY: origin.y, width: drawWidth, height: drawHeight, defaultFg: fg, defaultBg: bg)
        } else {
            renderEditorLines(into: buffer, originX: origin.x, originY: origin.y, width: drawWidth, height: drawHeight, defaultFg: fg, defaultBg: bg)
        }

        if _focused {
            updateTerminalCursor(drawWidth: drawWidth, drawHeight: drawHeight)
        }
    }

    private func renderPlaceholder(
        into buffer: OptimizedBuffer,
        originX: Int,
        originY: Int,
        width: Int,
        height: Int,
        defaultFg: RGBA,
        defaultBg: RGBA
    ) {
        var col = 0
        var row = 0
        let transparentBg = RGBA.fromValues(0, 0, 0, 0)

        for chunk in editorView.placeholderChunks {
            guard row < height else { break }
            let chunkFg = chunk.fg ?? defaultFg
            let chunkBg = chunk.bg ?? transparentBg
            let chunkAttrs = chunk.attributes ?? _defaultAttributes

            for ch in chunk.text {
                if row >= height { break }
                if ch == "\n" {
                    row += 1
                    col = 0
                    continue
                }
                if ch == "\r" { continue }

                if ch.unicodeScalars.count == 1,
                   let first = ch.unicodeScalars.first,
                   let notation = controlScalarNotation(first)
                {
                    for nch in notation {
                        if col >= width {
                            if _wrapMode == .none { break }
                            row += 1
                            col = 0
                            if row >= height { break }
                        }
                        buffer.setCellWithAlphaBlending(
                            x: originX + col,
                            y: originY + row,
                            char: String(nch),
                            fg: chunkFg,
                            bg: chunkBg,
                            attributes: chunkAttrs
                        )
                        col += 1
                    }
                    continue
                }

                let chStr = String(ch)
                let glyphWidth = max(
                    1,
                    Int(calculateTextWidth(chStr, tabWidth: UInt8(clamping: editBuffer.getTabWidth()), controlDisplay: .hidden, widthMethod: ctx.widthMethod))
                )
                if col + glyphWidth > width {
                    if _wrapMode == .none { continue }
                    row += 1
                    col = 0
                    if row >= height { break }
                }
                buffer.setCellWithAlphaBlending(
                    x: originX + col,
                    y: originY + row,
                    char: chStr,
                    fg: chunkFg,
                    bg: chunkBg,
                    attributes: chunkAttrs
                )
                col += glyphWidth
            }
        }
    }

    private func renderEditorLines(
        into buffer: OptimizedBuffer,
        originX: Int,
        originY: Int,
        width: Int,
        height: Int,
        defaultFg: RGBA,
        defaultBg: RGBA
    ) {
        let vp = editorView.getViewport()
        let visibleLines = editorView.textBufferView.visibleVirtualLines()
        let selection = editorView.getSelection()
        let tabWidth = max(1, editBuffer.getTabWidth())
        let tabIndScalar = editorView.textBufferView.tabIndicator
        let tabIndColor = editorView.textBufferView.tabIndicatorColor
        let transparentBg = RGBA.fromValues(0, 0, 0, 0)

        let selBg: RGBA
        let selFg: RGBA
        if let explicitSelBg = _selectionBg {
            selBg = explicitSelBg
            selFg = _selectionFg ?? defaultFg
        } else {
            selBg = defaultFg
            selFg = defaultBg.a > 0 ? defaultBg : RGBA.fromInts(0, 0, 0, 255)
        }

        let activeExtmarks: [Extmark] = _extmarksInitialized
            ? editorView.extmarks.getAll().filter { ($0.styleId ?? 0) > 0 }
            : []

        for (rowIdx, vline) in visibleLines.enumerated() {
            if rowIdx >= height { break }
            let screenY = originY + rowIdx
            let rawHighlights = editBuffer.getLineHighlights(vline.sourceLine)
            let sortedHighlights: [Highlight]
            if rawHighlights.count > 1 {
                sortedHighlights = rawHighlights.sorted { ($0.priority ?? 0) < ($1.priority ?? 0) }
            } else {
                sortedHighlights = rawHighlights
            }

            var colInVLine = 0
            for ch in vline.text {
                let logicalCol = vline.sourceColStart + colInVLine
                let docCellOffset = vline.documentCellOffset + colInVLine
                let isSelected = selection.map { docCellOffset >= $0.start && docCellOffset < $0.end } ?? false

                var cellFg = defaultFg
                var cellBg = transparentBg
                var cellAttrs = _defaultAttributes

                if let style = _syntaxStyle, !style.isDestroyed {
                    for hl in sortedHighlights where hl.start <= logicalCol && logicalCol < hl.end {
                        if let def = style.resolveById(hl.styleId) {
                            applyStyleDefinition(def, fg: &cellFg, bg: &cellBg, attributes: &cellAttrs)
                        }
                    }
                    if !activeExtmarks.isEmpty {
                        for mark in activeExtmarks where mark.start <= docCellOffset && docCellOffset < mark.end {
                            if let sid = mark.styleId, sid > 0, let def = style.resolveById(UInt32(sid)) {
                                applyStyleDefinition(def, fg: &cellFg, bg: &cellBg, attributes: &cellAttrs)
                            }
                        }
                    }
                }

                if isSelected {
                    cellFg = selFg
                    cellBg = selBg
                }

                if ch == "\t" {
                    for t in 0..<tabWidth {
                        let screenX = originX + colInVLine + t - vp.offsetX
                        if screenX >= originX && screenX < originX + width {
                            if t == 0, let indScalar = tabIndScalar {
                                let indFg = isSelected ? selFg : (tabIndColor ?? cellFg)
                                buffer.setCellWithAlphaBlending(
                                    x: screenX,
                                    y: screenY,
                                    char: String(indScalar),
                                    fg: indFg,
                                    bg: cellBg,
                                    attributes: cellAttrs
                                )
                            } else {
                                buffer.setCellWithAlphaBlending(
                                    x: screenX,
                                    y: screenY,
                                    char: " ",
                                    fg: cellFg,
                                    bg: cellBg,
                                    attributes: cellAttrs
                                )
                            }
                        }
                    }
                    colInVLine += tabWidth
                    continue
                }

                if ch.unicodeScalars.count == 1,
                   let first = ch.unicodeScalars.first,
                   let notation = controlScalarNotation(first)
                {
                    var offset = 0
                    for nch in notation {
                        let screenX = originX + colInVLine + offset - vp.offsetX
                        if screenX >= originX && screenX < originX + width {
                            buffer.setCellWithAlphaBlending(
                                x: screenX,
                                y: screenY,
                                char: String(nch),
                                fg: cellFg,
                                bg: cellBg,
                                attributes: cellAttrs
                            )
                        }
                        offset += 1
                    }
                    colInVLine += offset
                    continue
                }

                let chStr = String(ch)
                let glyphWidth = max(
                    1,
                    Int(calculateTextWidth(chStr, tabWidth: UInt8(clamping: tabWidth), controlDisplay: .hidden, widthMethod: ctx.widthMethod))
                )
                let screenX = originX + colInVLine - vp.offsetX
                if screenX >= originX && screenX + glyphWidth <= originX + width {
                    buffer.setCellWithAlphaBlending(
                        x: screenX,
                        y: screenY,
                        char: chStr,
                        fg: cellFg,
                        bg: cellBg,
                        attributes: cellAttrs
                    )
                }
                colInVLine += glyphWidth
                if originX + colInVLine - vp.offsetX >= originX + width {
                    break
                }
            }
        }
    }

    private func updateTerminalCursor(drawWidth: Int, drawHeight: Int) {
        guard _showCursor else {
            ctx.setCursorPosition(x: 1, y: 1, visible: false)
            return
        }
        let vc = editorView.getVisualCursor()
        let inViewport = vc.visualRow >= 0 && vc.visualRow < drawHeight && vc.visualCol >= 0 && vc.visualCol < drawWidth
        if inViewport {
            let cx = max(1, min(ctx.width, _screenX + vc.visualCol + 1))
            let cy = max(1, min(ctx.height, _screenY + vc.visualRow + 1))
            var opts = _cursorStyle
            opts.color = _cursorColor
            ctx.setCursorStyle(opts)
            ctx.setCursorColor(_cursorColor)
            ctx.setCursorPosition(x: cx, y: cy, visible: true)
        } else {
            ctx.setCursorPosition(x: 1, y: 1, visible: false)
        }
    }
}
