import OpenTUICore
import OpenTUILayout

// MARK: - Slider Orientation & Shared Half-Block Geometry

public enum SliderOrientation: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case vertical
    case horizontal
}

/// Half-cell virtual thumb geometry matching `native/src/scene.zig#sliderThumb`.
public struct SliderThumb: Equatable, Hashable, Sendable {
    public var size: Double
    public var start: Double

    public init(size: Double, start: Double) {
        self.size = size
        self.start = start
    }
}

/// Computes half-cell virtual thumb size and start matching `native/src/scene.zig#sliderThumb`.
public func computeSliderThumb(
    orientation: SliderOrientation,
    min minValue: Double,
    max maxValue: Double,
    value: Double,
    viewPortSize: Double,
    width: Int,
    height: Int
) -> SliderThumb {
    guard minValue.isFinite, maxValue.isFinite, value.isFinite, viewPortSize.isFinite else {
        return SliderThumb(size: 0, start: 0)
    }
    let axisDim = Double(Swift.max(0, orientation == .horizontal ? width : height))
    let trackSize = axisDim * 2.0
    let range = maxValue - minValue
    guard range.isFinite else { return SliderThumb(size: 0, start: 0) }
    if range <= 0 {
        return SliderThumb(size: trackSize, start: 0)
    }
    let effectiveViewport = Swift.max(1.0, viewPortSize)
    let contentSize = range + effectiveViewport
    let size: Double
    if contentSize <= effectiveViewport {
        size = trackSize
    } else {
        size = Swift.max(1.0, Swift.min((trackSize * (effectiveViewport / contentSize)).rounded(.down), trackSize))
    }
    let ratio = (value - minValue) / range
    let offset = ratio * (trackSize - size)
    let lower = offset.rounded(.down)
    // Match JavaScript Math.round tie-breaking toward +infinity.
    let start = (offset - lower < 0.5) ? lower : (lower + 1.0)
    return SliderThumb(size: size, start: start)
}

/// Renders a slider track and half-block precision thumb directly into `buffer`,
/// matching `native/src/scene.zig#paintSlider`.
internal func paintSliderTrack(
    buffer: OptimizedBuffer,
    x: Int,
    y: Int,
    width: Int,
    height: Int,
    orientation: SliderOrientation,
    min minValue: Double,
    max maxValue: Double,
    value: Double,
    viewPortSize: Double,
    foreground: RGBA,
    background: RGBA
) {
    guard width > 0 && height > 0 else { return }
    let thumb = computeSliderThumb(
        orientation: orientation,
        min: minValue,
        max: maxValue,
        value: value,
        viewPortSize: viewPortSize,
        width: width,
        height: height
    )

    buffer.fillRect(x: x, y: y, width: width, height: height, bg: background)

    let thumbEnd = thumb.start + thumb.size
    let axisLength = orientation == .horizontal ? width : height
    let crossLength = orientation == .horizontal ? height : width
    let firstAlong = Swift.max(0, Int((thumb.start / 2.0).rounded(.down)))
    let endAlong = Swift.min(axisLength, Int((thumbEnd / 2.0).rounded(.up)))
    guard firstAlong < endAlong && crossLength > 0 else { return }

    for along in firstAlong..<endAlong {
        let cellStart = Double(along) * 2.0
        let start = Swift.max(thumb.start, cellStart)
        let coverage = Swift.min(thumbEnd, cellStart + 2.0) - start

        let scalar: UInt32
        if coverage >= 2.0 {
            scalar = 0x2588 // '█'
        } else if orientation == .horizontal {
            if coverage > 0 {
                scalar = (start == cellStart) ? 0x258C : 0x2590 // '▌' or '▐'
            } else {
                scalar = 0x20
            }
        } else {
            if coverage > 0 {
                scalar = (start == cellStart) ? 0x2580 : 0x2584 // '▀' or '▄'
            } else {
                scalar = 0x20
            }
        }

        let cell = TerminalCell(
            scalar: scalar,
            foreground: foreground,
            background: background,
            attributes: TextAttributes.none
        )
        for across in 0..<crossLength {
            let col = orientation == .horizontal ? along : across
            let row = orientation == .horizontal ? across : along
            buffer.setCellWithAlphaBlending(x: x + col, y: y + row, cell: cell)
        }
    }
}

// MARK: - SliderOptions

/// Options for configuring a `SliderRenderable`, matching `core/src/renderables/Slider.ts#SliderOptions`.
// parity: core/src/renderables/Slider.ts#SliderOptions [status=implemented hash=b47fa3afc23d]
public struct SliderOptions {
    public var renderable: RenderableOptions
    public var orientation: SliderOrientation
    public var value: Double?
    public var min: Double?
    public var max: Double?
    public var viewPortSize: Double?
    public var backgroundColor: Color?
    public var foregroundColor: Color?
    public var onChange: ((Double) -> Void)?

    public init(
        orientation: SliderOrientation = .horizontal,
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
        alignSelf: Align? = nil,
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
        zIndex: Int? = nil,
        visible: Bool? = nil,
        opacity: Double? = nil,
        focusable: Bool? = nil,
        value: Double? = nil,
        min: Double? = nil,
        max: Double? = nil,
        viewPortSize: Double? = nil,
        backgroundColor: Color? = nil,
        foregroundColor: Color? = nil,
        onChange: ((Double) -> Void)? = nil
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
            flexShrink: flexShrink ?? 0,
            flexBasis: flexBasis,
            alignSelf: alignSelf,
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
            zIndex: zIndex,
            visible: visible,
            opacity: opacity,
            focusable: focusable
        )
        self.orientation = orientation
        self.value = value
        self.min = min
        self.max = max
        self.viewPortSize = viewPortSize
        self.backgroundColor = backgroundColor
        self.foregroundColor = foregroundColor
        self.onChange = onChange
    }

    public init(
        renderable: RenderableOptions,
        orientation: SliderOrientation = .horizontal,
        value: Double? = nil,
        min: Double? = nil,
        max: Double? = nil,
        viewPortSize: Double? = nil,
        backgroundColor: Color? = nil,
        foregroundColor: Color? = nil,
        onChange: ((Double) -> Void)? = nil
    ) {
        var opts = renderable
        if opts.flexShrink == nil {
            opts.flexShrink = 0
        }
        self.renderable = opts
        self.orientation = orientation
        self.value = value
        self.min = min
        self.max = max
        self.viewPortSize = viewPortSize
        self.backgroundColor = backgroundColor
        self.foregroundColor = foregroundColor
        self.onChange = onChange
    }
}

// MARK: - SliderRenderable

/// Interactive half-block precision slider/track renderable matching `core/src/renderables/Slider.ts#SliderRenderable`.
// parity: core/src/renderables/Slider.ts#SliderRenderable [status=implemented hash=8377f92a8f33]
open class SliderRenderable: Renderable, @unchecked Sendable {
    public static let defaultThumbBackgroundColor: RGBA = RGBA.fromHex("#9a9ea3")
    public static let defaultTrackBackgroundColor: RGBA = RGBA.fromHex("#252527")
    public static let defaultMin: Double = 0
    public static let defaultMax: Double = 100

    private var _orientation: SliderOrientation
    private var _value: Double
    private var _min: Double
    private var _max: Double
    private var _viewPortSize: Double
    private var _backgroundColor: RGBA
    private var _foregroundColor: RGBA
    public var onChange: ((Double) -> Void)?

    // Mouse drag state
    private var isDraggingThumb: Bool = false
    private var dragOffsetVirtual: Double = 0
    private var appliedMousePos: Int = 0

    public init(ctx: any RenderContext, options: SliderOptions = SliderOptions()) {
        let initialMin = options.min ?? Self.defaultMin
        let initialMax = options.max ?? Self.defaultMax
        let initialValue = options.value ?? initialMin
        let defaultViewport = Swift.max(1.0, (initialMax - initialMin) * 0.1)

        self._orientation = options.orientation
        self._min = initialMin
        self._max = initialMax
        self._value = initialValue
        self._viewPortSize = options.viewPortSize ?? defaultViewport
        self.onChange = options.onChange
        self._backgroundColor = options.backgroundColor?.resolved() ?? Self.defaultTrackBackgroundColor
        self._foregroundColor = options.foregroundColor?.resolved() ?? Self.defaultThumbBackgroundColor

        var baseOptions = options.renderable
        if baseOptions.flexShrink == nil {
            baseOptions.flexShrink = 0
        }
        super.init(ctx: ctx, options: baseOptions)
    }

    // parity: core/src/renderables/Slider.ts#SliderRenderable.orientation [status=implemented hash=16524cc07cd0]
    public var orientation: SliderOrientation {
        get { _orientation }
        set {
            guard !_isDestroyed, newValue != _orientation else { return }
            _orientation = newValue
            requestRender()
        }
    }

    // parity: core/src/renderables/Slider.ts#SliderRenderable.value [status=implemented hash=2b02f0eb467c]
    public var value: Double {
        get { _value }
        set {
            let clamped = Swift.max(_min, Swift.min(_max, newValue))
            if clamped != _value {
                publishValue(clamped)
            }
        }
    }

    private func publishValue(_ value: Double) {
        guard value != _value else { return }
        _value = value
        requestRender()
        onChange?(value)
        emit("change")
    }

    // parity: core/src/renderables/Slider.ts#SliderRenderable.min [status=implemented hash=a84c5906710a]
    public var min: Double {
        get { _min }
        set {
            guard newValue != _min else { return }
            let adjustedValue = _value < newValue ? newValue : _value
            _min = newValue
            if _value < newValue {
                publishValue(adjustedValue)
            }
            requestRender()
        }
    }

    // parity: core/src/renderables/Slider.ts#SliderRenderable.max [status=implemented hash=65d3c9395c97]
    public var max: Double {
        get { _max }
        set {
            guard newValue != _max else { return }
            let adjustedValue = _value > newValue ? Swift.max(_min, newValue) : _value
            _max = newValue
            if _value > newValue {
                publishValue(adjustedValue)
            }
            requestRender()
        }
    }

    // parity: core/src/renderables/Slider.ts#SliderRenderable.viewPortSize [status=implemented hash=b4e303621681]
    public var viewPortSize: Double {
        get { _viewPortSize }
        set {
            let range = Swift.max(0.01, _max - _min)
            let clampedSize = Swift.max(0.01, Swift.min(newValue, range))
            if clampedSize != _viewPortSize {
                _viewPortSize = clampedSize
                requestRender()
            }
        }
    }

    /// Convenience alias for `viewPortSize`.
    public var viewportSize: Double {
        get { viewPortSize }
        set { viewPortSize = newValue }
    }

    // parity: core/src/renderables/Slider.ts#SliderRenderable.backgroundColor [status=implemented hash=81a56a76ea69]
    public var backgroundColor: RGBA {
        get { _backgroundColor }
        set {
            guard !_isDestroyed else { return }
            _backgroundColor = newValue
            requestRender()
        }
    }

    public func setBackgroundColor(_ color: Color?) {
        backgroundColor = color?.resolved() ?? Self.defaultTrackBackgroundColor
    }

    // parity: core/src/renderables/Slider.ts#SliderRenderable.foregroundColor [status=implemented hash=438ea5db8db4]
    public var foregroundColor: RGBA {
        get { _foregroundColor }
        set {
            guard !_isDestroyed else { return }
            _foregroundColor = newValue
            requestRender()
        }
    }

    public func setForegroundColor(_ color: Color?) {
        foregroundColor = color?.resolved() ?? Self.defaultThumbBackgroundColor
    }

    /// Computes the current virtual half-cell thumb geometry for this slider.
    public func getSliderThumb() -> SliderThumb {
        computeSliderThumb(
            orientation: _orientation,
            min: _min,
            max: _max,
            value: _value,
            viewPortSize: _viewPortSize,
            width: width,
            height: height
        )
    }

    /// Returns the integer cell hit rectangle of the thumb in screen coordinates.
    public func getThumbRect() -> LayoutRect {
        let thumb = getSliderThumb()
        let realThumbStart = Int((thumb.start / 2.0).rounded(.down))
        let realThumbSize = Int(((thumb.start + thumb.size) / 2.0).rounded(.up)) - realThumbStart

        if _orientation == .vertical {
            return LayoutRect(
                x: x,
                y: y + realThumbStart,
                width: width,
                height: Swift.max(1, realThumbSize)
            )
        } else {
            return LayoutRect(
                x: x + realThumbStart,
                y: y,
                width: Swift.max(1, realThumbSize),
                height: height
            )
        }
    }

    private func pointerAxis(_ event: MouseEvent) -> Int {
        _orientation == .vertical ? event.y : event.x
    }

    private func calculateDragOffsetVirtual(_ event: MouseEvent) -> Double {
        let trackStart = _orientation == .vertical ? y : x
        let trackSize = _orientation == .vertical ? height : width
        let mousePos = (_orientation == .vertical ? event.y : event.x) - trackStart
        let virtualMousePos = Double(Swift.max(0, Swift.min(trackSize, mousePos))) * 2.0
        let thumbSize = getSliderThumb().size
        let maxThumbStart = Swift.max(0.0, Double(trackSize) * 2.0 - thumbSize)
        let range = _max - _min
        let ratio = range == 0 ? 0.0 : (_value - _min) / range

        return Swift.max(0.0, Swift.min(thumbSize, virtualMousePos - ratio * maxThumbStart))
    }

    private func updateValueFromMouseDirect(_ event: MouseEvent) {
        let trackStart = _orientation == .vertical ? y : x
        let trackSize = _orientation == .vertical ? height : width
        let mousePos = _orientation == .vertical ? event.y : event.x

        let relativeMousePos = mousePos - trackStart
        let clampedMousePos = Swift.max(0, Swift.min(trackSize, relativeMousePos))
        let ratio = trackSize == 0 ? 0.0 : Double(clampedMousePos) / Double(trackSize)
        let range = _max - _min
        self.value = _min + ratio * range
    }

    private func updateValueFromMouseWithOffset(_ event: MouseEvent, offsetVirtual: Double) {
        let trackStart = _orientation == .vertical ? y : x
        let trackSize = _orientation == .vertical ? height : width
        let mousePos = _orientation == .vertical ? event.y : event.x

        let virtualTrackSize = Double(trackSize) * 2.0
        let relativeMousePos = mousePos - trackStart
        let clampedMousePos = Swift.max(0, Swift.min(trackSize, relativeMousePos))
        let virtualMousePos = Double(clampedMousePos) * 2.0

        let virtualThumbSize = getSliderThumb().size
        let maxThumbStart = Swift.max(0.0, virtualTrackSize - virtualThumbSize)

        var desiredThumbStart = virtualMousePos - offsetVirtual
        desiredThumbStart = Swift.max(0.0, Swift.min(maxThumbStart, desiredThumbStart))

        let ratio = maxThumbStart == 0 ? 0.0 : desiredThumbStart / maxThumbStart
        let range = _max - _min
        self.value = _min + ratio * range
    }

    private func applyDrag(_ event: MouseEvent) {
        let mousePos = pointerAxis(event)
        guard mousePos != appliedMousePos else { return }
        appliedMousePos = mousePos
        updateValueFromMouseWithOffset(event, offsetVirtual: dragOffsetVirtual)
    }

    open override func onMouseEvent(_ event: MouseEvent) {
        switch event.type {
        case .down:
            event.stopPropagation()
            event.preventDefault()

            let thumb = getThumbRect()
            let inThumb = event.x >= thumb.x
                && event.x < thumb.x + thumb.width
                && event.y >= thumb.y
                && event.y < thumb.y + thumb.height

            if !inThumb {
                updateValueFromMouseDirect(event)
                if _isDestroyed { return }
            }
            isDraggingThumb = true
            dragOffsetVirtual = calculateDragOffsetVirtual(event)
            appliedMousePos = pointerAxis(event)

        case .drag:
            guard isDraggingThumb else { return }
            event.stopPropagation()
            applyDrag(event)

        case .up:
            if isDraggingThumb {
                applyDrag(event)
            }
            isDraggingThumb = false

        default:
            break
        }
    }

    open override func renderSelf(buffer: OptimizedBuffer, deltaTime: Double) {
        let origin = paintOrigin(for: buffer)
        paintSliderTrack(
            buffer: buffer,
            x: origin.x,
            y: origin.y,
            width: width,
            height: height,
            orientation: _orientation,
            min: _min,
            max: _max,
            value: _value,
            viewPortSize: _viewPortSize,
            foreground: _foregroundColor,
            background: _backgroundColor
        )
    }
}
