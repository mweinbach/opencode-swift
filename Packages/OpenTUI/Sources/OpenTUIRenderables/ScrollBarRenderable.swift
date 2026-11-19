import OpenTUICore
import OpenTUILayout

// MARK: - ScrollUnit & Unit Size

/// Unit for relative scrollbar stepping, matching `core/src/renderables/ScrollBar.ts#ScrollUnit`.
// parity: core/src/renderables/ScrollBar.ts#ScrollUnit [status=implemented hash=a8c224d41720]
public enum ScrollUnit: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case absolute
    case viewport
    case content
    case step
}

/// Protocol describing scrollbar metrics needed to resolve a `ScrollUnit`.
public protocol ScrollUnitMetrics {
    var viewportSize: Double { get }
    var scrollSize: Double { get }
    var scrollStep: Double? { get }
}

/// Cells per unit of a scrollbar's `scrollBy`, matching `core/src/renderables/ScrollBar.ts#scrollUnitSize`.
// parity: core/src/renderables/ScrollBar.ts#scrollUnitSize [status=implemented hash=eb3263aaefc2]
public func scrollUnitSize(_ bar: any ScrollUnitMetrics, unit: ScrollUnit) -> Double {
    switch unit {
    case .viewport: return bar.viewportSize
    case .content: return bar.scrollSize
    case .step: return bar.scrollStep ?? 1.0
    case .absolute: return 1.0
    }
}

public func scrollUnitSize(
    viewportSize: Double,
    scrollSize: Double,
    scrollStep: Double? = nil,
    unit: ScrollUnit
) -> Double {
    switch unit {
    case .viewport: return viewportSize
    case .content: return scrollSize
    case .step: return scrollStep ?? 1.0
    case .absolute: return 1.0
    }
}

// MARK: - ArrowChars & ArrowOptions

/// Custom glyph overrides for directional scrollbar arrows.
public struct ArrowChars: Equatable, Hashable, Sendable, Codable {
    public var up: String?
    public var down: String?
    public var left: String?
    public var right: String?

    public init(
        up: String? = nil,
        down: String? = nil,
        left: String? = nil,
        right: String? = nil
    ) {
        self.up = up
        self.down = down
        self.left = left
        self.right = right
    }

    internal func resolved(for direction: ScrollDirection) -> String {
        switch direction {
        case .up: return up ?? "▲"
        case .down: return down ?? "▼"
        case .left: return left ?? "◀"
        case .right: return right ?? "▶"
        }
    }

    internal func merged(with override: ArrowChars?) -> ArrowChars {
        guard let override else { return self }
        return ArrowChars(
            up: override.up ?? up,
            down: override.down ?? down,
            left: override.left ?? left,
            right: override.right ?? right
        )
    }
}

/// Style overrides applied to scrollbar arrow buttons (without a fixed direction).
public struct ScrollBarArrowStyleOptions: Equatable, Sendable {
    public var foregroundColor: Color?
    public var backgroundColor: Color?
    public var attributes: UInt32?
    public var arrowChars: ArrowChars?

    public init(
        foregroundColor: Color? = nil,
        backgroundColor: Color? = nil,
        attributes: UInt32? = nil,
        arrowChars: ArrowChars? = nil
    ) {
        self.foregroundColor = foregroundColor
        self.backgroundColor = backgroundColor
        self.attributes = attributes
        self.arrowChars = arrowChars
    }

    internal func merged(with override: ScrollBarArrowStyleOptions?) -> ScrollBarArrowStyleOptions {
        guard let override else { return self }
        let mergedChars: ArrowChars?
        if let base = arrowChars {
            mergedChars = base.merged(with: override.arrowChars)
        } else {
            mergedChars = override.arrowChars
        }
        return ScrollBarArrowStyleOptions(
            foregroundColor: override.foregroundColor ?? foregroundColor,
            backgroundColor: override.backgroundColor ?? backgroundColor,
            attributes: override.attributes ?? attributes,
            arrowChars: mergedChars
        )
    }
}

/// Track style overrides applied to a scrollbar's inner slider.
public struct ScrollBarTrackStyleOptions: Equatable, Sendable {
    public var foregroundColor: Color?
    public var backgroundColor: Color?
    public var viewPortSize: Double?

    public init(
        foregroundColor: Color? = nil,
        backgroundColor: Color? = nil,
        viewPortSize: Double? = nil
    ) {
        self.foregroundColor = foregroundColor
        self.backgroundColor = backgroundColor
        self.viewPortSize = viewPortSize
    }

    internal func merged(with override: ScrollBarTrackStyleOptions?) -> ScrollBarTrackStyleOptions {
        guard let override else { return self }
        return ScrollBarTrackStyleOptions(
            foregroundColor: override.foregroundColor ?? foregroundColor,
            backgroundColor: override.backgroundColor ?? backgroundColor,
            viewPortSize: override.viewPortSize ?? viewPortSize
        )
    }
}

/// Options for constructing an `ArrowRenderable`, matching `core/src/renderables/ScrollBar.ts#ArrowOptions`.
// parity: core/src/renderables/ScrollBar.ts#ArrowOptions [status=implemented hash=a0803e3fbc2e]
public struct ArrowOptions {
    public var renderable: RenderableOptions
    public var direction: ScrollDirection
    public var foregroundColor: Color?
    public var backgroundColor: Color?
    public var attributes: UInt32?
    public var arrowChars: ArrowChars?

    public init(
        direction: ScrollDirection,
        id: String? = nil,
        width: FlexValue? = nil,
        height: FlexValue? = nil,
        alignSelf: Align? = nil,
        visible: Bool? = nil,
        foregroundColor: Color? = nil,
        backgroundColor: Color? = nil,
        attributes: UInt32? = nil,
        arrowChars: ArrowChars? = nil
    ) {
        self.renderable = RenderableOptions(
            id: id,
            width: width,
            height: height,
            alignSelf: alignSelf,
            visible: visible
        )
        self.direction = direction
        self.foregroundColor = foregroundColor
        self.backgroundColor = backgroundColor
        self.attributes = attributes
        self.arrowChars = arrowChars
    }

    public init(
        renderable: RenderableOptions,
        direction: ScrollDirection,
        foregroundColor: Color? = nil,
        backgroundColor: Color? = nil,
        attributes: UInt32? = nil,
        arrowChars: ArrowChars? = nil
    ) {
        self.renderable = renderable
        self.direction = direction
        self.foregroundColor = foregroundColor
        self.backgroundColor = backgroundColor
        self.attributes = attributes
        self.arrowChars = arrowChars
    }
}

// MARK: - ArrowRenderable

/// Directional glyph button rendered at the ends of a scrollbar,
/// matching `core/src/renderables/ScrollBar.ts#ArrowRenderable`.
// parity: core/src/renderables/ScrollBar.ts#ArrowRenderable [status=implemented hash=a9ea401898c7]
open class ArrowRenderable: Renderable, @unchecked Sendable {
    public static let defaultForegroundColor: RGBA = RGBA.fromValues(1, 1, 1, 1)
    public static let defaultBackgroundColor: RGBA = RGBA.fromValues(0, 0, 0, 0)

    private var _direction: ScrollDirection
    private var _foregroundColor: RGBA
    private var _backgroundColor: RGBA
    private var _attributes: UInt32
    private var _arrowChars: ArrowChars

    public init(ctx: any RenderContext, options: ArrowOptions) {
        self._direction = options.direction
        self._foregroundColor = options.foregroundColor?.resolved() ?? Self.defaultForegroundColor
        self._backgroundColor = options.backgroundColor?.resolved() ?? Self.defaultBackgroundColor
        self._attributes = options.attributes ?? TextAttributes.none
        self._arrowChars = options.arrowChars ?? ArrowChars()

        super.init(ctx: ctx, options: options.renderable)

        if options.renderable.width == nil {
            setWidth(.point(Float(glyphWidth())))
        }
    }

    // parity: core/src/renderables/ScrollBar.ts#ArrowRenderable.direction [status=implemented hash=560f7f1945eb]
    public var direction: ScrollDirection {
        get { _direction }
        set {
            guard !_isDestroyed, newValue != _direction else { return }
            _direction = newValue
            requestRender()
        }
    }

    // parity: core/src/renderables/ScrollBar.ts#ArrowRenderable.foregroundColor [status=implemented hash=438ea5db8db4]
    public var foregroundColor: RGBA {
        get { _foregroundColor }
        set {
            guard !_isDestroyed else { return }
            _foregroundColor = newValue
            requestRender()
        }
    }

    // parity: core/src/renderables/ScrollBar.ts#ArrowRenderable.backgroundColor [status=implemented hash=81a56a76ea69]
    public var backgroundColor: RGBA {
        get { _backgroundColor }
        set {
            guard !_isDestroyed else { return }
            _backgroundColor = newValue
            requestRender()
        }
    }

    // parity: core/src/renderables/ScrollBar.ts#ArrowRenderable.attributes [status=implemented hash=489a0d5c37bb]
    public var attributes: UInt32 {
        get { _attributes }
        set {
            guard !_isDestroyed, newValue != _attributes else { return }
            _attributes = newValue
            requestRender()
        }
    }

    // parity: core/src/renderables/ScrollBar.ts#ArrowRenderable.arrowChars [status=implemented hash=06ec19e6ad68]
    public var arrowChars: ArrowChars {
        get { _arrowChars }
        set {
            guard !_isDestroyed else { return }
            _arrowChars = _arrowChars.merged(with: newValue)
            requestRender()
        }
    }

    public func currentGlyph() -> String {
        _arrowChars.resolved(for: _direction)
    }

    private func glyphWidth() -> Int {
        let measured = Int(
            calculateTextWidth(
                currentGlyph(),
                tabWidth: 2,
                controlDisplay: .hidden,
                widthMethod: ctx.widthMethod
            )
        )
        return Swift.max(1, measured)
    }

    open override func renderSelf(buffer: OptimizedBuffer, deltaTime: Double) {
        guard width > 0 && height > 0 else { return }
        let origin = paintOrigin(for: buffer)
        buffer.drawText(
            currentGlyph(),
            x: origin.x,
            y: origin.y,
            fg: _foregroundColor,
            bg: _backgroundColor,
            attributes: _attributes
        )
    }
}

// MARK: - ScrollBarOptions

/// Options for constructing a `ScrollBarRenderable`, matching `core/src/renderables/ScrollBar.ts#ScrollBarOptions`.
// parity: core/src/renderables/ScrollBar.ts#ScrollBarOptions [status=implemented hash=b6eb21235372]
public struct ScrollBarOptions {
    public var renderable: RenderableOptions
    public var orientation: SliderOrientation
    public var showArrows: Bool?
    public var arrowOptions: ScrollBarArrowStyleOptions?
    public var trackOptions: ScrollBarTrackStyleOptions?
    public var scrollStep: Double?
    public var onChange: ((Int) -> Void)?

    public init(
        orientation: SliderOrientation = .vertical,
        id: String? = nil,
        width: FlexValue? = nil,
        height: FlexValue? = nil,
        paddingLeft: FlexValue? = nil,
        paddingTop: FlexValue? = nil,
        position: PositionType? = nil,
        alignSelf: Align? = nil,
        alignItems: Align? = nil,
        visible: Bool? = nil,
        focusable: Bool? = nil,
        showArrows: Bool? = nil,
        arrowOptions: ScrollBarArrowStyleOptions? = nil,
        trackOptions: ScrollBarTrackStyleOptions? = nil,
        scrollStep: Double? = nil,
        onChange: ((Int) -> Void)? = nil
    ) {
        self.renderable = RenderableOptions(
            id: id,
            width: width,
            height: height,
            alignItems: alignItems,
            alignSelf: alignSelf,
            position: position,
            paddingTop: paddingTop,
            paddingLeft: paddingLeft,
            visible: visible,
            focusable: focusable
        )
        self.orientation = orientation
        self.showArrows = showArrows
        self.arrowOptions = arrowOptions
        self.trackOptions = trackOptions
        self.scrollStep = scrollStep
        self.onChange = onChange
    }

    public init(
        renderable: RenderableOptions,
        orientation: SliderOrientation = .vertical,
        showArrows: Bool? = nil,
        arrowOptions: ScrollBarArrowStyleOptions? = nil,
        trackOptions: ScrollBarTrackStyleOptions? = nil,
        scrollStep: Double? = nil,
        onChange: ((Int) -> Void)? = nil
    ) {
        self.renderable = renderable
        self.orientation = orientation
        self.showArrows = showArrows
        self.arrowOptions = arrowOptions
        self.trackOptions = trackOptions
        self.scrollStep = scrollStep
        self.onChange = onChange
    }
}

// MARK: - ScrollBarRenderable

/// Composite scrollbar pairing a `SliderRenderable` track with optional start/end `ArrowRenderable` buttons,
/// matching `core/src/renderables/ScrollBar.ts#ScrollBarRenderable`.
// parity: core/src/renderables/ScrollBar.ts#ScrollBarRenderable [status=implemented hash=2b3895bd1005]
open class ScrollBarRenderable: Renderable, ScrollUnitMetrics, @unchecked Sendable {
    private final class ArrowRepeatState {
        unowned let arrow: ArrowRenderable
        var timer: TimerHandle? = nil

        init(arrow: ArrowRenderable) {
            self.arrow = arrow
        }
    }

    public let slider: SliderRenderable
    public let startArrow: ArrowRenderable
    public let endArrow: ArrowRenderable
    public let orientation: SliderOrientation

    private var _scrollSize: Double = 0
    private var _scrollPosition: Int = 0
    private var _viewportSize: Double = 0
    private var _showArrows: Bool = false
    private var _manualVisibility: Bool = false

    public var onChange: ((Int) -> Void)?
    public var scrollStep: Double? = nil

    private var arrowRepeat: ArrowRepeatState? = nil

    public init(ctx: any RenderContext, options: ScrollBarOptions = ScrollBarOptions()) {
        self.orientation = options.orientation
        self._showArrows = options.showArrows ?? false
        self.onChange = options.onChange
        self.scrollStep = options.scrollStep

        var baseOptions = options.renderable
        if baseOptions.flexDirection == nil {
            baseOptions.flexDirection = options.orientation == .vertical ? .column : .row
        }
        if baseOptions.alignSelf == nil {
            baseOptions.alignSelf = .stretch
        }
        if baseOptions.alignItems == nil {
            baseOptions.alignItems = .stretch
        }
        if baseOptions.focusable == nil {
            baseOptions.focusable = true
        }
        if options.renderable.visible != nil {
            self._manualVisibility = true
        }

        let scrollRange: Double = 0
        let defaultStepSize: Double = 1
        let stepSize = options.trackOptions?.viewPortSize ?? defaultStepSize

        let initialWidth: FlexValue
        let initialHeight: FlexValue
        let initialMarginLeft: FlexValue?
        let initialMarginTop: FlexValue?
        if options.orientation == .vertical {
            let requestedWidth: Int
            if case .point(let w) = options.renderable.width {
                requestedWidth = Swift.max(1, Swift.min(2, Int(w)))
            } else {
                requestedWidth = 1
            }
            initialWidth = .point(Float(requestedWidth))
            initialHeight = .percent(100)
            initialMarginLeft = .auto
            initialMarginTop = nil
        } else {
            initialWidth = .percent(100)
            initialHeight = .point(1)
            initialMarginLeft = nil
            initialMarginTop = .auto
        }

        let slider = SliderRenderable(
            ctx: ctx,
            options: SliderOptions(
                orientation: options.orientation,
                width: initialWidth,
                height: initialHeight,
                flexGrow: 1,
                flexShrink: 1,
                marginTop: initialMarginTop,
                marginLeft: initialMarginLeft,
                value: 0,
                min: 0,
                max: scrollRange,
                viewPortSize: stepSize,
                backgroundColor: options.trackOptions?.backgroundColor,
                foregroundColor: options.trackOptions?.foregroundColor
            )
        )
        self.slider = slider

        let arrowFg = options.arrowOptions?.foregroundColor ?? options.arrowOptions?.backgroundColor
        let arrowBg = options.arrowOptions?.backgroundColor
        let arrowAttrs = options.arrowOptions?.attributes
        let arrowGlyphs = options.arrowOptions?.arrowChars

        self.startArrow = ArrowRenderable(
            ctx: ctx,
            options: ArrowOptions(
                direction: options.orientation == .vertical ? .up : .left,
                height: .point(1),
                alignSelf: .center,
                visible: self._showArrows,
                foregroundColor: arrowFg,
                backgroundColor: arrowBg,
                attributes: arrowAttrs,
                arrowChars: arrowGlyphs
            )
        )

        self.endArrow = ArrowRenderable(
            ctx: ctx,
            options: ArrowOptions(
                direction: options.orientation == .vertical ? .down : .right,
                height: .point(1),
                alignSelf: .center,
                visible: self._showArrows,
                foregroundColor: arrowFg,
                backgroundColor: arrowBg,
                attributes: arrowAttrs,
                arrowChars: arrowGlyphs
            )
        )

        super.init(ctx: ctx, options: baseOptions)

        self.slider.onChange = { [weak self] value in
            guard let self, !self._isDestroyed else { return }
            let rounded = Int((value + 0.5).rounded(.down))
            self._scrollPosition = rounded
            self.onChange?(rounded)
            if !self._isDestroyed {
                self.emit("change")
            }
        }

        updateSliderFromScrollState()

        add(startArrow)
        add(slider)
        add(endArrow)

        setupArrowInteraction(arrow: startArrow, direction: -1)
        setupArrowInteraction(arrow: endArrow, direction: 1)
    }

    private func setupArrowInteraction(arrow: ArrowRenderable, direction: Double) {
        arrow.onMouseDown = { [weak self, weak arrow] event in
            guard let self, let arrow else { return }
            event.stopPropagation()
            event.preventDefault()
            self.stopArrowRepeat()
            guard !self._isDestroyed && !arrow.isDestroyed else { return }

            let repeatState = ArrowRepeatState(arrow: arrow)
            self.arrowRepeat = repeatState
            self.scrollBy(direction * 0.5, unit: .viewport)
            guard self.arrowRepeat === repeatState && !self._isDestroyed && !arrow.isDestroyed else { return }

            repeatState.timer = self.ctx.clock.setTimeout({ [weak self, weak arrow] in
                repeatState.timer = nil
                guard let self, let arrow, self.arrowRepeat === repeatState, !self._isDestroyed, !arrow.isDestroyed else {
                    return
                }
                self.scrollBy(direction * 0.5, unit: .viewport)
                guard self.arrowRepeat === repeatState && !self._isDestroyed && !arrow.isDestroyed else { return }

                repeatState.timer = self.ctx.clock.setInterval({ [weak self, weak arrow] in
                    guard let self, self.arrowRepeat === repeatState else { return }
                    guard let arrow, !self._isDestroyed, !arrow.isDestroyed else {
                        self.stopArrowRepeat()
                        return
                    }
                    self.scrollBy(direction * 0.2, unit: .viewport)
                }, delayMs: 200)
            }, delayMs: 500)
        }

        arrow.onMouseUp = { [weak self] event in
            event.stopPropagation()
            self?.stopArrowRepeat()
        }

        _ = arrow.on(.destroyed) { [weak self, weak arrow] in
            guard let self, let arrow else { return }
            if self.arrowRepeat?.arrow === arrow {
                self.stopArrowRepeat()
            }
        }
    }

    private func stopArrowRepeat() {
        guard let repeatState = arrowRepeat else { return }
        arrowRepeat = nil
        if let timer = repeatState.timer {
            ctx.clock.clearTimeout(timer)
            repeatState.timer = nil
        }
    }

    // parity: core/src/renderables/ScrollBar.ts#ScrollBarRenderable.visible [status=implemented hash=15fa60f153cf]
    open override var visible: Bool {
        get { super.visible }
        set {
            _manualVisibility = true
            super.visible = newValue
        }
    }

    // parity: core/src/renderables/ScrollBar.ts#ScrollBarRenderable.resetVisibilityControl [status=implemented hash=0eb12e54ef9c]
    public func resetVisibilityControl() {
        _manualVisibility = false
        recalculateVisibility()
    }

    // parity: core/src/renderables/ScrollBar.ts#ScrollBarRenderable.scrollSize [status=implemented hash=20403f2eb538]
    public var scrollSize: Double {
        get { _scrollSize }
        set {
            guard !_isDestroyed, newValue.isFinite, (newValue - _viewportSize).isFinite else { return }
            guard newValue != _scrollSize else { return }
            _scrollSize = newValue
            recalculateVisibility()
            guard !_isDestroyed && !slider.isDestroyed else { return }
            updateSliderFromScrollState()
            guard !_isDestroyed && !slider.isDestroyed else { return }
            scrollPosition = _scrollPosition
        }
    }

    // parity: core/src/renderables/ScrollBar.ts#ScrollBarRenderable.scrollPosition [status=implemented hash=8f144dca9923]
    public var scrollPosition: Int {
        get { _scrollPosition }
        set {
            guard !_isDestroyed else { return }
            let maxPos = Swift.max(0.0, _scrollSize - _viewportSize)
            let clamped = Swift.max(0.0, Swift.min(Double(newValue), maxPos))
            let rounded = Int((clamped + 0.5).rounded(.down))
            if rounded != _scrollPosition {
                _scrollPosition = rounded
                updateSliderFromScrollState()
            }
        }
    }

    // parity: core/src/renderables/ScrollBar.ts#ScrollBarRenderable.viewportSize [status=implemented hash=fc22b9384953]
    public var viewportSize: Double {
        get { _viewportSize }
        set {
            guard !_isDestroyed, newValue.isFinite, (_scrollSize - newValue).isFinite else { return }
            guard newValue != _viewportSize else { return }
            slider.viewPortSize = Swift.max(1.0, newValue)
            _viewportSize = newValue
            recalculateVisibility()
            guard !_isDestroyed && !slider.isDestroyed else { return }
            updateSliderFromScrollState()
            guard !_isDestroyed && !slider.isDestroyed else { return }
            scrollPosition = _scrollPosition
        }
    }

    // parity: core/src/renderables/ScrollBar.ts#ScrollBarRenderable.showArrows [status=implemented hash=4f3478549f53]
    public var showArrows: Bool {
        get { _showArrows }
        set {
            guard !_isDestroyed, newValue != _showArrows else { return }
            _showArrows = newValue
            startArrow.visible = newValue
            guard !_isDestroyed && !endArrow.isDestroyed else { return }
            endArrow.visible = newValue
        }
    }

    // parity: core/src/renderables/ScrollBar.ts#ScrollBarRenderable.arrowOptions [status=implemented hash=aea0ade3b0b1]
    public var arrowOptions: ScrollBarArrowStyleOptions {
        get {
            ScrollBarArrowStyleOptions(
                foregroundColor: .rgba(startArrow.foregroundColor),
                backgroundColor: .rgba(startArrow.backgroundColor),
                attributes: startArrow.attributes,
                arrowChars: startArrow.arrowChars
            )
        }
        set {
            for arrow in [startArrow, endArrow] {
                if let fg = newValue.foregroundColor {
                    arrow.foregroundColor = fg.resolved()
                }
                if let bg = newValue.backgroundColor {
                    arrow.backgroundColor = bg.resolved()
                }
                if let attrs = newValue.attributes {
                    arrow.attributes = attrs
                }
                if let chars = newValue.arrowChars {
                    arrow.arrowChars = chars
                }
            }
            if !_isDestroyed { requestRender() }
        }
    }

    // parity: core/src/renderables/ScrollBar.ts#ScrollBarRenderable.trackOptions [status=implemented hash=1b78ed84c44f]
    public var trackOptions: ScrollBarTrackStyleOptions {
        get {
            ScrollBarTrackStyleOptions(
                foregroundColor: .rgba(slider.foregroundColor),
                backgroundColor: .rgba(slider.backgroundColor),
                viewPortSize: slider.viewPortSize
            )
        }
        set {
            if let fg = newValue.foregroundColor {
                slider.foregroundColor = fg.resolved()
            }
            if let bg = newValue.backgroundColor {
                slider.backgroundColor = bg.resolved()
            }
            if let vp = newValue.viewPortSize {
                slider.viewPortSize = vp
            }
            if !_isDestroyed { requestRender() }
        }
    }

    private func updateSliderFromScrollState() {
        let scrollRange = Swift.max(0.0, _scrollSize - _viewportSize)
        slider.min = 0
        guard !_isDestroyed && !slider.isDestroyed else { return }
        slider.max = scrollRange
        guard !_isDestroyed && !slider.isDestroyed else { return }
        slider.value = Swift.min(Double(_scrollPosition), scrollRange)
    }

    // parity: core/src/renderables/ScrollBar.ts#ScrollBarRenderable.scrollBy [status=implemented hash=d889e34f42b8]
    public func scrollBy(_ delta: Double, unit: ScrollUnit = .absolute) {
        let stepDelta = scrollUnitSize(self, unit: unit) * delta
        let nextPos = Double(_scrollPosition) + stepDelta
        let maxPos = Swift.max(0.0, _scrollSize - _viewportSize)
        let clamped = Swift.max(0.0, Swift.min(nextPos, maxPos))
        scrollPosition = Int((clamped + 0.5).rounded(.down))
    }

    private func recalculateVisibility() {
        guard !_manualVisibility else { return }
        let shouldShow = _scrollSize > _viewportSize
        super.visible = shouldShow
    }

    // parity: core/src/renderables/ScrollBar.ts#ScrollBarRenderable.handleKeyPress [status=implemented hash=c3c47416c8fa]
    @discardableResult
    open override func handleKeyPress(_ key: KeyEvent) -> Bool {
        switch key.name {
        case "left", "h":
            guard orientation == .horizontal else { return false }
            scrollBy(-1.0 / 5.0, unit: .viewport)
            return true
        case "right", "l":
            guard orientation == .horizontal else { return false }
            scrollBy(1.0 / 5.0, unit: .viewport)
            return true
        case "up", "k":
            guard orientation == .vertical else { return false }
            scrollBy(-1.0 / 5.0, unit: .viewport)
            return true
        case "down", "j":
            guard orientation == .vertical else { return false }
            scrollBy(1.0 / 5.0, unit: .viewport)
            return true
        case "pageup":
            scrollBy(-1.0 / 2.0, unit: .viewport)
            return true
        case "pagedown":
            scrollBy(1.0 / 2.0, unit: .viewport)
            return true
        case "home":
            scrollBy(-1.0, unit: .content)
            return true
        case "end":
            scrollBy(1.0, unit: .content)
            return true
        default:
            return false
        }
    }

    open override func destroySelf() {
        stopArrowRepeat()
        super.destroySelf()
    }
}
