import OpenTUICore
import OpenTUILayout

// MARK: - BoxOptions

/// Declarative options for constructing a `BoxRenderable`, matching `core/src/renderables/Box.ts#BoxOptions`.
// parity: core/src/renderables/Box.ts#BoxOptions [status=implemented hash=aceede751753]
public struct BoxOptions {
    public var renderable: RenderableOptions
    public var backgroundColor: Color?
    public var borderStyle: BorderStyle?
    public var border: BorderSpec?
    public var borderColor: Color?
    public var customBorderChars: BorderCharacters?
    public var shouldFill: Bool?
    public var title: String?
    public var titleColor: Color?
    public var titleAlignment: BoxTitleAlignment?
    public var bottomTitle: String?
    public var bottomTitleAlignment: BoxTitleAlignment?
    public var focusedBorderColor: Color?

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
        layoutMode: LayoutMode? = nil,
        alignItems: Align? = nil,
        alignSelf: Align? = nil,
        alignContent: Align? = nil,
        justifyContent: Justify? = nil,
        position: PositionType? = nil,
        top: FlexValue? = nil,
        right: FlexValue? = nil,
        bottom: FlexValue? = nil,
        left: FlexValue? = nil,
        margin: FlexValue? = nil,
        marginX: FlexValue? = nil,
        marginY: FlexValue? = nil,
        marginTop: FlexValue? = nil,
        marginRight: FlexValue? = nil,
        marginBottom: FlexValue? = nil,
        marginLeft: FlexValue? = nil,
        padding: FlexValue? = nil,
        paddingX: FlexValue? = nil,
        paddingY: FlexValue? = nil,
        paddingTop: FlexValue? = nil,
        paddingRight: FlexValue? = nil,
        paddingBottom: FlexValue? = nil,
        paddingLeft: FlexValue? = nil,
        gap: FlexValue? = nil,
        rowGap: FlexValue? = nil,
        columnGap: FlexValue? = nil,
        overflow: Overflow? = nil,
        display: Display? = nil,
        aspectRatio: Float? = nil,
        zIndex: Int? = nil,
        visible: Bool? = nil,
        opacity: Double? = nil,
        live: Bool? = nil,
        animationFps: Double? = nil,
        focusable: Bool? = nil,
        selectable: Bool? = nil,
        buffered: Bool? = nil,
        renderBefore: ((OptimizedBuffer, Double) -> Void)? = nil,
        renderAfter: ((OptimizedBuffer, Double) -> Void)? = nil,
        onMouse: ((MouseEvent) -> Void)? = nil,
        onMouseDown: ((MouseEvent) -> Void)? = nil,
        onMouseUp: ((MouseEvent) -> Void)? = nil,
        onMouseMove: ((MouseEvent) -> Void)? = nil,
        onMouseDrag: ((MouseEvent) -> Void)? = nil,
        onMouseDragEnd: ((MouseEvent) -> Void)? = nil,
        onMouseDrop: ((MouseEvent) -> Void)? = nil,
        onMouseOver: ((MouseEvent) -> Void)? = nil,
        onMouseOut: ((MouseEvent) -> Void)? = nil,
        onMouseScroll: ((MouseEvent) -> Void)? = nil,
        onKeyDown: ((KeyEvent) -> Void)? = nil,
        onPaste: ((PasteEvent) -> Void)? = nil,
        onSizeChange: (() -> Void)? = nil,
        onLifecyclePass: (() -> Void)? = nil,
        backgroundColor: Color? = nil,
        borderStyle: BorderStyle? = nil,
        border: BorderSpec? = nil,
        borderColor: Color? = nil,
        customBorderChars: BorderCharacters? = nil,
        shouldFill: Bool? = nil,
        title: String? = nil,
        titleColor: Color? = nil,
        titleAlignment: BoxTitleAlignment? = nil,
        bottomTitle: String? = nil,
        bottomTitleAlignment: BoxTitleAlignment? = nil,
        focusedBorderColor: Color? = nil
    ) {
        self.renderable = RenderableOptions(
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
            layoutMode: layoutMode,
            alignItems: alignItems,
            alignSelf: alignSelf,
            alignContent: alignContent,
            justifyContent: justifyContent,
            position: position,
            top: top,
            right: right,
            bottom: bottom,
            left: left,
            margin: margin,
            marginX: marginX,
            marginY: marginY,
            marginTop: marginTop,
            marginRight: marginRight,
            marginBottom: marginBottom,
            marginLeft: marginLeft,
            padding: padding,
            paddingX: paddingX,
            paddingY: paddingY,
            paddingTop: paddingTop,
            paddingRight: paddingRight,
            paddingBottom: paddingBottom,
            paddingLeft: paddingLeft,
            gap: gap,
            rowGap: rowGap,
            columnGap: columnGap,
            overflow: overflow,
            display: display,
            aspectRatio: aspectRatio,
            zIndex: zIndex,
            visible: visible,
            opacity: opacity,
            live: live,
            animationFps: animationFps,
            focusable: focusable,
            selectable: selectable,
            buffered: buffered,
            renderBefore: renderBefore,
            renderAfter: renderAfter,
            onMouse: onMouse,
            onMouseDown: onMouseDown,
            onMouseUp: onMouseUp,
            onMouseMove: onMouseMove,
            onMouseDrag: onMouseDrag,
            onMouseDragEnd: onMouseDragEnd,
            onMouseDrop: onMouseDrop,
            onMouseOver: onMouseOver,
            onMouseOut: onMouseOut,
            onMouseScroll: onMouseScroll,
            onKeyDown: onKeyDown,
            onPaste: onPaste,
            onSizeChange: onSizeChange,
            onLifecyclePass: onLifecyclePass
        )
        self.backgroundColor = backgroundColor
        self.borderStyle = borderStyle
        self.border = border
        self.borderColor = borderColor
        self.customBorderChars = customBorderChars
        self.shouldFill = shouldFill
        self.title = title
        self.titleColor = titleColor
        self.titleAlignment = titleAlignment
        self.bottomTitle = bottomTitle
        self.bottomTitleAlignment = bottomTitleAlignment
        self.focusedBorderColor = focusedBorderColor
    }

    public init(
        renderable: RenderableOptions,
        backgroundColor: Color? = nil,
        borderStyle: BorderStyle? = nil,
        border: BorderSpec? = nil,
        borderColor: Color? = nil,
        customBorderChars: BorderCharacters? = nil,
        shouldFill: Bool? = nil,
        title: String? = nil,
        titleColor: Color? = nil,
        titleAlignment: BoxTitleAlignment? = nil,
        bottomTitle: String? = nil,
        bottomTitleAlignment: BoxTitleAlignment? = nil,
        focusedBorderColor: Color? = nil
    ) {
        self.renderable = renderable
        self.backgroundColor = backgroundColor
        self.borderStyle = borderStyle
        self.border = border
        self.borderColor = borderColor
        self.customBorderChars = customBorderChars
        self.shouldFill = shouldFill
        self.title = title
        self.titleColor = titleColor
        self.titleAlignment = titleAlignment
        self.bottomTitle = bottomTitle
        self.bottomTitleAlignment = bottomTitleAlignment
        self.focusedBorderColor = focusedBorderColor
    }
}

// MARK: - BoxRenderable

/// Layout container with optional borders, titles, background fill, and focus-aware border styling,
/// matching `core/src/renderables/Box.ts#BoxRenderable`.
// parity: core/src/renderables/Box.ts#BoxRenderable [status=implemented hash=0730700635bd]
open class BoxRenderable: Renderable, @unchecked Sendable {
    public static let defaultBackgroundColor: RGBA = RGBA.fromValues(0, 0, 0, 0)
    public static let defaultBorderStyle: BorderStyle = .single
    public static let defaultBorderColor: RGBA = RGBA.fromHex("#FFFFFF")
    public static let defaultFocusedBorderColor: RGBA = RGBA.fromHex("#00AAFF")
    public static let defaultShouldFill: Bool = true
    public static let defaultTitleAlignment: BoxTitleAlignment = .left
    public static let defaultBottomTitleAlignment: BoxTitleAlignment = .left

    internal var _backgroundColor: RGBA
    internal var _border: BorderSpec
    internal var _borderStyle: BorderStyle
    internal var _borderColor: RGBA
    internal var _focusedBorderColor: RGBA
    private var _customBorderCharsObj: BorderCharacters?
    internal var _customBorderChars: [UInt32]?
    public internal(set) var borderSides: BorderSidesConfig
    private var _shouldFill: Bool
    internal var _title: String?
    internal var _titleColor: RGBA?
    internal var _titleAlignment: BoxTitleAlignment
    internal var _bottomTitle: String?
    internal var _bottomTitleAlignment: BoxTitleAlignment

    public init(ctx: any RenderContext, options: BoxOptions = BoxOptions()) {
        self._backgroundColor = options.backgroundColor?.resolved() ?? Self.defaultBackgroundColor

        let initialBorder: BorderSpec
        if let explicit = options.border {
            initialBorder = explicit
        } else if options.borderStyle != nil
            || options.borderColor != nil
            || options.focusedBorderColor != nil
            || options.customBorderChars != nil
        {
            initialBorder = .enabled(true)
        } else {
            initialBorder = .enabled(false)
        }

        self._border = initialBorder
        self._borderStyle = options.borderStyle ?? Self.defaultBorderStyle
        self._borderColor = options.borderColor?.resolved() ?? Self.defaultBorderColor
        self._focusedBorderColor = options.focusedBorderColor?.resolved() ?? Self.defaultFocusedBorderColor
        self._customBorderCharsObj = options.customBorderChars
        self._customBorderChars = options.customBorderChars.map(borderCharsToArray)
        self.borderSides = getBorderSides(initialBorder)
        self._shouldFill = options.shouldFill ?? Self.defaultShouldFill
        self._title = options.title
        self._titleColor = options.titleColor?.resolved()
        self._titleAlignment = options.titleAlignment ?? Self.defaultTitleAlignment
        self._bottomTitle = options.bottomTitle
        self._bottomTitleAlignment = options.bottomTitleAlignment ?? Self.defaultBottomTitleAlignment

        super.init(ctx: ctx, options: options.renderable)

        if options.renderable.focusable == true {
            self._focusable = true
        }
        syncBorderLayoutEdges()
        requestRender()
    }

    private func initializeBorder() {
        if _border == .enabled(false) {
            _border = .enabled(true)
            borderSides = getBorderSides(_border)
            syncBorderLayoutEdges()
        }
    }

    internal func syncBorderLayoutEdges() {
        guard !_isDestroyed else { return }
        layoutNode.style.border.top = borderSides.top ? .point(1) : .point(0)
        layoutNode.style.border.right = borderSides.right ? .point(1) : .point(0)
        layoutNode.style.border.bottom = borderSides.bottom ? .point(1) : .point(0)
        layoutNode.style.border.left = borderSides.left ? .point(1) : .point(0)
    }

    // parity: core/src/renderables/Box.ts#BoxRenderable.customBorderChars [status=implemented hash=d7af1320997b]
    public var customBorderChars: BorderCharacters? {
        get { _customBorderCharsObj }
        set {
            guard !_isDestroyed else { return }
            _customBorderCharsObj = newValue
            _customBorderChars = newValue.map(borderCharsToArray)
            requestRender()
        }
    }

    // parity: core/src/renderables/Box.ts#BoxRenderable.backgroundColor [status=implemented hash=3f2fd901bcc7]
    public var backgroundColor: RGBA {
        get { _backgroundColor }
        set {
            guard !_isDestroyed else { return }
            _backgroundColor = newValue
            requestRender()
        }
    }

    public func setBackgroundColor(_ color: Color?) {
        backgroundColor = color?.resolved() ?? Self.defaultBackgroundColor
    }

    // parity: core/src/renderables/Box.ts#BoxRenderable.border [status=implemented hash=0e76100049d4]
    public var border: BorderSpec {
        get { _border }
        set {
            guard !_isDestroyed, _border != newValue else { return }
            _border = newValue
            borderSides = getBorderSides(newValue)
            syncBorderLayoutEdges()
            requestRender()
        }
    }

    // parity: core/src/renderables/Box.ts#BoxRenderable.borderStyle [status=implemented hash=89da544e8fa5]
    public var borderStyle: BorderStyle {
        get { _borderStyle }
        set {
            guard !_isDestroyed else { return }
            if _borderStyle != newValue || _border == .enabled(false) {
                _borderStyle = newValue
                _customBorderChars = nil
                _customBorderCharsObj = nil
                initializeBorder()
                requestRender()
            }
        }
    }

    // parity: core/src/renderables/Box.ts#BoxRenderable.borderColor [status=implemented hash=c0d1cecb90f6]
    public var borderColor: RGBA {
        get { _borderColor }
        set {
            guard !_isDestroyed else { return }
            _borderColor = newValue
            initializeBorder()
            requestRender()
        }
    }

    public func setBorderColor(_ color: Color?) {
        borderColor = color?.resolved() ?? Self.defaultBorderColor
    }

    // parity: core/src/renderables/Box.ts#BoxRenderable.focusedBorderColor [status=implemented hash=a3b1ea04a9b6]
    public var focusedBorderColor: RGBA {
        get { _focusedBorderColor }
        set {
            guard !_isDestroyed else { return }
            _focusedBorderColor = newValue
            initializeBorder()
            requestRender()
        }
    }

    public func setFocusedBorderColor(_ color: Color?) {
        focusedBorderColor = color?.resolved() ?? Self.defaultFocusedBorderColor
    }

    // parity: core/src/renderables/Box.ts#BoxRenderable.title [status=implemented hash=841f2513a263]
    public var title: String? {
        get { _title }
        set {
            guard !_isDestroyed, _title != newValue else { return }
            _title = newValue
            requestRender()
        }
    }

    // parity: core/src/renderables/Box.ts#BoxRenderable.titleColor [status=implemented hash=f655ef30b63c]
    public var titleColor: RGBA? {
        get { _titleColor }
        set {
            guard !_isDestroyed, _titleColor != newValue else { return }
            _titleColor = newValue
            requestRender()
        }
    }

    public func setTitleColor(_ color: Color?) {
        titleColor = color?.resolved()
    }

    // parity: core/src/renderables/Box.ts#BoxRenderable.titleAlignment [status=implemented hash=1ced36f94daf]
    public var titleAlignment: BoxTitleAlignment {
        get { _titleAlignment }
        set {
            guard !_isDestroyed, _titleAlignment != newValue else { return }
            _titleAlignment = newValue
            requestRender()
        }
    }

    // parity: core/src/renderables/Box.ts#BoxRenderable.bottomTitle [status=implemented hash=431ae0222f82]
    public var bottomTitle: String? {
        get { _bottomTitle }
        set {
            guard !_isDestroyed, _bottomTitle != newValue else { return }
            _bottomTitle = newValue
            requestRender()
        }
    }

    // parity: core/src/renderables/Box.ts#BoxRenderable.bottomTitleAlignment [status=implemented hash=bacee54662a0]
    public var bottomTitleAlignment: BoxTitleAlignment {
        get { _bottomTitleAlignment }
        set {
            guard !_isDestroyed, _bottomTitleAlignment != newValue else { return }
            _bottomTitleAlignment = newValue
            requestRender()
        }
    }

    // parity: core/src/renderables/Box.ts#BoxRenderable.shouldFill [status=implemented hash=ce03323b9a47]
    public var shouldFill: Bool {
        get { _shouldFill }
        set {
            guard !_isDestroyed, _shouldFill != newValue else { return }
            _shouldFill = newValue
            requestRender()
        }
    }

    /// Sets uniform gap gutter (`gap` property is inherited from `Renderable`).
    // parity: core/src/renderables/Box.ts#BoxRenderable.gap [status=implemented hash=51ee37f3df4a]
    public func setGap(_ value: FlexValue) {
        self.gap = value
    }

    /// Sets row gap gutter (`rowGap` property is inherited from `Renderable`).
    // parity: core/src/renderables/Box.ts#BoxRenderable.rowGap [status=implemented hash=f1e42c92c148]
    public func setRowGap(_ value: FlexValue) {
        self.rowGap = value
    }

    /// Sets column gap gutter (`columnGap` property is inherited from `Renderable`).
    // parity: core/src/renderables/Box.ts#BoxRenderable.columnGap [status=implemented hash=07e7c37d73d0]
    public func setColumnGap(_ value: FlexValue) {
        self.columnGap = value
    }

    internal var hasVisibleBorder: Bool {
        borderSides.top || borderSides.right || borderSides.bottom || borderSides.left
    }

    open override func renderSelf(buffer: OptimizedBuffer, deltaTime: Double) {
        guard width > 0 && height > 0 else { return }
        if !hasVisibleBorder && !(_shouldFill && _backgroundColor.a > 0) {
            return
        }

        let origin = paintOrigin(for: buffer)
        let activeBorderColor = (_focusable && _focused) ? _focusedBorderColor : _borderColor

        buffer.drawBox(
            BoxDrawOptions(
                x: origin.x,
                y: origin.y,
                width: width,
                height: height,
                borderStyle: _borderStyle,
                customBorderChars: _customBorderChars,
                borderSides: borderSides,
                borderColor: activeBorderColor,
                backgroundColor: _backgroundColor,
                titleColor: _titleColor,
                shouldFill: _shouldFill,
                title: _title,
                titleAlignment: _titleAlignment,
                bottomTitle: _bottomTitle,
                bottomTitleAlignment: _bottomTitleAlignment
            )
        )
    }
}
