import OpenTUICore
import OpenTUILayout

private let ttfdTransparent = RGBA.fromValues(0, 0, 0, 0)
private let ttfdDefaultFg = RGBA.fromHex("#AAAAAA")

/// Pure-Swift fixed-decimal formatter matching JavaScript `Number.prototype.toFixed(precision)`.
private func formatFixedDecimals(_ value: Double, precision: Int) -> String {
    guard value.isFinite else { return "0" }
    let clampedPrecision = Swift.max(0, Swift.min(precision, 12))
    let isNegative = value < 0
    let absVal = abs(value)

    if clampedPrecision == 0 {
        let rounded = Int64((absVal + 0.5).rounded(.down))
        return isNegative && rounded > 0 ? "-\(rounded)" : "\(rounded)"
    }

    var scale: Double = 1.0
    for _ in 0..<clampedPrecision {
        scale *= 10.0
    }
    let scaled = Int64((absVal * scale + 0.5).rounded(.down))
    let intScale = Int64(scale)
    let whole = scaled / intScale
    let frac = scaled % intScale

    var fracStr = String(frac)
    if fracStr.count < clampedPrecision {
        fracStr = String(repeating: "0", count: clampedPrecision - fracStr.count) + fracStr
    }
    let prefix = (isNegative && scaled > 0) ? "-" : ""
    return "\(prefix)\(whole).\(fracStr)"
}

/// Computes how many display columns `drawTextFit` keeps of `text` within `maxWidth`.
private func fittedCellWidth(buffer: OptimizedBuffer, text: String, maxWidth: Int) -> Int {
    guard maxWidth > 0 && !text.isEmpty else { return 0 }
    let bytes = Array(text.utf8)
    var asciiPrintable = true
    for byte in bytes {
        if byte < 0x20 || byte > 0x7E {
            asciiPrintable = false
            break
        }
    }
    if asciiPrintable {
        return Swift.min(bytes.count, maxWidth)
    }

    let spans = segmentGraphemeClusters(
        bytes,
        tabWidth: 2,
        controlDisplay: .hidden,
        widthMethod: buffer.widthMethod
    )
    var totalWidth = 0
    for span in spans {
        let w = Int(span.width)
        if totalWidth + w > maxWidth { break }
        totalWidth += w
    }
    return totalWidth
}

// MARK: - TimeToFirstDrawOptions

/// Options for configuring a `TimeToFirstDrawRenderable`,
/// matching `core/src/renderables/TimeToFirstDraw.ts#TimeToFirstDrawOptions`.
// parity: core/src/renderables/TimeToFirstDraw.ts#TimeToFirstDrawOptions [status=implemented hash=70c1f8f0c44c]
public struct TimeToFirstDrawOptions {
    public var renderable: RenderableOptions
    public var fg: Color?
    public var label: String?
    public var precision: Int?

    public init(
        id: String? = nil,
        width: FlexValue? = nil,
        height: FlexValue? = nil,
        flexGrow: Float? = nil,
        flexShrink: Float? = nil,
        alignSelf: Align? = nil,
        position: PositionType? = nil,
        top: FlexValue? = nil,
        right: FlexValue? = nil,
        bottom: FlexValue? = nil,
        left: FlexValue? = nil,
        zIndex: Int? = nil,
        visible: Bool? = nil,
        opacity: Double? = nil,
        fg: Color? = nil,
        label: String? = nil,
        precision: Int? = nil
    ) {
        self.renderable = RenderableOptions(
            id: id,
            width: width ?? .percent(100),
            height: height ?? .point(1),
            flexGrow: flexGrow,
            flexShrink: flexShrink ?? 0,
            alignSelf: alignSelf ?? .center,
            position: position,
            top: top,
            right: right,
            bottom: bottom,
            left: left,
            zIndex: zIndex,
            visible: visible,
            opacity: opacity
        )
        self.fg = fg
        self.label = label
        self.precision = precision
    }

    public init(
        renderable: RenderableOptions,
        fg: Color? = nil,
        label: String? = nil,
        precision: Int? = nil
    ) {
        var opts = renderable
        if opts.width == nil { opts.width = .percent(100) }
        if opts.height == nil { opts.height = .point(1) }
        if opts.flexShrink == nil { opts.flexShrink = 0 }
        if opts.alignSelf == nil { opts.alignSelf = .center }
        self.renderable = opts
        self.fg = fg
        self.label = label
        self.precision = precision
    }
}

// MARK: - TimeToFirstDrawRenderable

/// Captures the elapsed time (in ms) on first draw and renders a centered timing banner,
/// matching `core/src/renderables/TimeToFirstDraw.ts#TimeToFirstDrawRenderable`.
// parity: core/src/renderables/TimeToFirstDraw.ts#TimeToFirstDrawRenderable [status=implemented hash=2a1536a29504]
open class TimeToFirstDrawRenderable: Renderable, @unchecked Sendable {
    private var _runtimeMs: Double? = nil
    private var _textColor: RGBA
    private var _label: String
    private var _precision: Int

    public init(ctx: any RenderContext, options: TimeToFirstDrawOptions = TimeToFirstDrawOptions()) {
        self._textColor = options.fg?.resolved() ?? ttfdDefaultFg
        self._label = options.label ?? "Time to first draw"
        self._precision = Self.normalizePrecision(options.precision ?? 2)

        var baseOptions = options.renderable
        if baseOptions.width == nil { baseOptions.width = .percent(100) }
        if baseOptions.height == nil { baseOptions.height = .point(1) }
        if baseOptions.flexShrink == nil { baseOptions.flexShrink = 0 }
        if baseOptions.alignSelf == nil { baseOptions.alignSelf = .center }

        super.init(ctx: ctx, options: baseOptions)
    }

    // parity: core/src/renderables/TimeToFirstDraw.ts#TimeToFirstDrawRenderable.runtimeMs [status=implemented hash=7f8803365c46]
    public var runtimeMs: Double? {
        _runtimeMs
    }

    // parity: core/src/renderables/TimeToFirstDraw.ts#TimeToFirstDrawRenderable.fg [status=implemented hash=00a3c1ab9ba0]
    public var fg: RGBA {
        get { _textColor }
        set {
            _textColor = newValue
            requestRender()
        }
    }

    public func setFg(_ color: Color) {
        fg = color.resolved()
    }

    // parity: core/src/renderables/TimeToFirstDraw.ts#TimeToFirstDrawRenderable.color [status=implemented hash=10f588e05289]
    public var color: RGBA {
        get { fg }
        set { fg = newValue }
    }

    // parity: core/src/renderables/TimeToFirstDraw.ts#TimeToFirstDrawRenderable.textLabel [status=implemented hash=56a8837515ce]
    public var textLabel: String {
        get { _label }
        set {
            guard newValue != _label else { return }
            _label = newValue
            requestRender()
        }
    }

    // parity: core/src/renderables/TimeToFirstDraw.ts#TimeToFirstDrawRenderable.decimals [status=implemented hash=53cdf64fa551]
    public var decimals: Int {
        get { _precision }
        set {
            let next = Self.normalizePrecision(newValue)
            guard next != _precision else { return }
            _precision = next
            requestRender()
        }
    }

    // parity: core/src/renderables/TimeToFirstDraw.ts#TimeToFirstDrawRenderable.reset [status=implemented hash=5c621d718afd]
    public func reset() {
        _runtimeMs = nil
        requestRender()
    }

    open override func renderSelf(buffer: OptimizedBuffer, deltaTime: Double) {
        if _runtimeMs == nil {
            _runtimeMs = ctx.clock.now()
        }

        let elapsed = _runtimeMs ?? 0
        let content = "\(_label): \(formatFixedDecimals(elapsed, precision: _precision))ms"
        let maxWidth = Swift.max(width, 1)
        let origin = paintOrigin(for: buffer)
        let drawWidth = fittedCellWidth(buffer: buffer, text: content, maxWidth: maxWidth)
        let centeredX = origin.x + (maxWidth - drawWidth) / 2

        buffer.drawTextFit(
            content,
            x: centeredX,
            y: origin.y,
            maxWidth: drawWidth,
            fg: _textColor,
            bg: ttfdTransparent
        )
    }

    private static func normalizePrecision(_ value: Int) -> Int {
        Swift.max(0, value)
    }
}
