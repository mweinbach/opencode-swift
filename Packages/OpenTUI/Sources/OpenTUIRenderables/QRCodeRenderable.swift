import OpenTUICore
import OpenTUILayout

private let qrDefaultForeground = RGBA.fromHex("#000000")
private let qrDefaultBackground = RGBA.fromHex("#ffffff")
private let qrTransparent = RGBA.fromValues(0, 0, 0, 0)
private let qrMinimumQuietZone = 4

// MARK: - QRCodeFitMode & Options

/// Scaling/fitting mode for `QRCodeRenderable`, matching `qrcode/src/renderables/QRCode.ts#QRCodeFitMode`.
// parity: qrcode/src/renderables/QRCode.ts#QRCodeFitMode [status=implemented hash=d584fdf4cdf8]
public enum QRCodeFitMode: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case contain
    case none
}

/// Protocol abstracted over encoded QR matrices for `BaseQRCodeRenderable`.
public protocol EncodedQRMatrix {
    var version: Int { get }
    var size: Int { get }
    func toMatrix() -> [[Bool]]
}

extension QRCode: EncodedQRMatrix {}

/// Options for configuring a `QRCodeRenderable`, matching `qrcode/src/renderables/QRCode.ts#QRCodeOptions`.
// parity: qrcode/src/renderables/QRCode.ts#QRCodeOptions [status=implemented hash=e240bdb613a0]
public struct QRCodeOptions {
    public var renderable: RenderableOptions
    public var content: String?
    public var errorCorrectionLevel: ErrorCorrectionLevel?
    public var quietZone: Int?
    public var scale: Int?
    public var fit: QRCodeFitMode?
    public var foregroundColor: Color?
    public var backgroundColor: Color?
    public var invert: Bool?
    public var fallbackContent: String?
    public var fallbackColor: Color?

    public init(
        content: String? = nil,
        errorCorrectionLevel: ErrorCorrectionLevel? = nil,
        quietZone: Int? = nil,
        border: Int? = nil,
        scale: Int? = nil,
        fit: QRCodeFitMode? = nil,
        foregroundColor: Color? = nil,
        fg: Color? = nil,
        backgroundColor: Color? = nil,
        bg: Color? = nil,
        invert: Bool? = nil,
        fallbackContent: String? = nil,
        fallbackColor: Color? = nil,
        id: String? = nil,
        width: FlexValue? = nil,
        height: FlexValue? = nil,
        minWidth: FlexValue? = nil,
        maxWidth: FlexValue? = nil,
        minHeight: FlexValue? = nil,
        maxHeight: FlexValue? = nil,
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
        opacity: Double? = nil,
        buffered: Bool? = nil
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
            buffered: buffered
        )
        self.content = content
        self.errorCorrectionLevel = errorCorrectionLevel
        self.quietZone = quietZone ?? border
        self.scale = scale
        self.fit = fit
        self.foregroundColor = foregroundColor ?? fg
        self.backgroundColor = backgroundColor ?? bg
        self.invert = invert
        self.fallbackContent = fallbackContent
        self.fallbackColor = fallbackColor
    }
}

/// Alias for `QRCodeOptions`.
public typealias QRCodeRenderableOptions = QRCodeOptions

// MARK: - Helpers

private func qrDimensionsForScale(moduleCount: Int, quietZone: Int, scale: Int) -> FlexSize {
    let totalModules = (moduleCount + quietZone * 2) * scale
    let heightCells = Swift.max(1, (totalModules + 1) / 2)
    return FlexSize(width: Float(totalModules), height: Float(heightCells))
}

private func qrBlockCharacter(top: Bool, bottom: Bool) -> String {
    if top && bottom { return "█" }
    if top { return "▀" }
    return "▄"
}

private func qrFallbackWidth(content: String, width: Float, widthMode: MeasureMode) -> Int {
    let len = content.count
    if widthMode == .undefined || !width.isFinite {
        return len
    }
    return Swift.max(0, Swift.min(len, Int(width.rounded(.down))))
}

private func qrNormalizeQuietZone(_ value: Int, minimumQuietZone: Int) -> Int {
    Swift.max(minimumQuietZone, value)
}

private func qrNormalizeScale(_ value: Int) -> Int {
    Swift.max(1, value)
}

// MARK: - BaseQRCodeRenderable

/// Abstract base renderable encoding QR matrices and rendering them with Unicode half-blocks (`█`, `▀`, `▄`, ` `),
/// matching `qrcode/src/renderables/QRCode.ts#BaseQRCodeRenderable`.
open class BaseQRCodeRenderable: Renderable, @unchecked Sendable {
    private var _content: String
    private var _errorCorrectionLevel: ErrorCorrectionLevel
    private var _quietZone: Int
    private var _scale: Int
    private var _fit: QRCodeFitMode
    private var _foregroundColor: RGBA
    private var _backgroundColor: RGBA
    private var _invert: Bool
    private var _fallbackContent: String
    private var _fallbackColor: RGBA

    private let minimumQuietZone: Int
    private let encodeContent: (String, ErrorCorrectionLevel) -> (any EncodedQRMatrix)?
    private var encoded: (any EncodedQRMatrix)?
    private var modules: [[Bool]]
    private var renderBuffer: OptimizedBuffer? = nil
    private var renderBufferDirty: Bool = true

    public init(
        ctx: any RenderContext,
        options: QRCodeOptions,
        minimumQuietZone: Int = 4,
        encodeContent: @escaping (String, ErrorCorrectionLevel) -> (any EncodedQRMatrix)?
    ) {
        let initialContent = options.content ?? ""
        let initialEcl = options.errorCorrectionLevel ?? .M
        let initialQuietZone = qrNormalizeQuietZone(options.quietZone ?? minimumQuietZone, minimumQuietZone: minimumQuietZone)
        let initialScale = qrNormalizeScale(options.scale ?? 1)
        let initialFit = options.fit ?? .contain
        let initialEncoded = encodeContent(initialContent, initialEcl)

        self.minimumQuietZone = minimumQuietZone
        self.encodeContent = encodeContent
        self._content = initialContent
        self._errorCorrectionLevel = initialEcl
        self._quietZone = initialQuietZone
        self._scale = initialScale
        self._fit = initialFit
        self._foregroundColor = options.foregroundColor?.resolved() ?? qrDefaultForeground
        self._backgroundColor = options.backgroundColor?.resolved() ?? qrDefaultBackground
        self._invert = options.invert ?? false
        self._fallbackContent = options.fallbackContent ?? ""
        self._fallbackColor = options.fallbackColor?.resolved() ?? qrDefaultBackground
        self.encoded = initialEncoded
        self.modules = initialEncoded?.toMatrix() ?? []

        super.init(ctx: ctx, options: options.renderable)

        setupMeasureFunc()
    }

    public var content: String {
        get { _content }
        set {
            guard newValue != _content else { return }
            _content = newValue
            rebuildMatrix()
        }
    }

    public var errorCorrectionLevel: ErrorCorrectionLevel {
        get { _errorCorrectionLevel }
        set {
            guard newValue != _errorCorrectionLevel else { return }
            _errorCorrectionLevel = newValue
            rebuildMatrix()
        }
    }

    public var quietZone: Int {
        get { _quietZone }
        set {
            let next = qrNormalizeQuietZone(newValue, minimumQuietZone: minimumQuietZone)
            guard next != _quietZone else { return }
            _quietZone = next
            remeasure()
        }
    }

    /// Convenience alias for `quietZone`.
    public var border: Int {
        get { quietZone }
        set { quietZone = newValue }
    }

    public var scale: Int {
        get { _scale }
        set {
            let next = qrNormalizeScale(newValue)
            guard next != _scale else { return }
            _scale = next
            remeasure()
        }
    }

    public var fit: QRCodeFitMode {
        get { _fit }
        set {
            guard newValue != _fit else { return }
            _fit = newValue
            remeasure()
        }
    }

    public var foregroundColor: RGBA {
        get { _foregroundColor }
        set {
            _foregroundColor = newValue
            invalidateRenderBuffer()
            requestRender()
        }
    }

    public var fg: RGBA {
        get { foregroundColor }
        set { foregroundColor = newValue }
    }

    public var backgroundColor: RGBA {
        get { _backgroundColor }
        set {
            _backgroundColor = newValue
            invalidateRenderBuffer()
            requestRender()
        }
    }

    public var bg: RGBA {
        get { backgroundColor }
        set { backgroundColor = newValue }
    }

    public var invert: Bool {
        get { _invert }
        set {
            guard newValue != _invert else { return }
            _invert = newValue
            invalidateRenderBuffer()
            requestRender()
        }
    }

    public var fallbackContent: String {
        get { _fallbackContent }
        set {
            guard newValue != _fallbackContent else { return }
            _fallbackContent = newValue
            remeasure()
        }
    }

    public var fallbackColor: RGBA {
        get { _fallbackColor }
        set {
            _fallbackColor = newValue
            invalidateRenderBuffer()
            requestRender()
        }
    }

    public var version: Int {
        encoded?.version ?? 0
    }

    public var moduleCount: Int {
        encoded?.size ?? 0
    }

    open override func renderSelf(buffer: OptimizedBuffer, deltaTime: Double) {
        guard width > 0 && height > 0 else { return }

        let targetBuffer = getRenderBuffer()
        if renderBufferDirty {
            paintRenderBuffer(targetBuffer)
            renderBufferDirty = false
        }

        if buffered {
            buffer.clear(bg: qrTransparent, char: defaultSpaceChar)
            buffer.drawFrameBuffer(destX: 0, destY: 0, frameBuffer: targetBuffer)
            return
        }

        let origin = paintOrigin(for: buffer)
        buffer.drawFrameBuffer(destX: origin.x, destY: origin.y, frameBuffer: targetBuffer)
    }

    open override func onResize(width: Int, height: Int) {
        invalidateRenderBuffer()
        super.onResize(width: width, height: height)
    }

    open override func destroySelf() {
        renderBuffer?.destroy()
        renderBuffer = nil
        super.destroySelf()
    }

    private func paintRenderBuffer(_ buffer: OptimizedBuffer) {
        buffer.clear(bg: qrTransparent, char: defaultSpaceChar)

        guard let encoded else {
            paintFallback(buffer)
            return
        }

        let totalModules = encoded.size + _quietZone * 2
        let effectiveScale = resolveRenderScale(width: width, height: height)
        if effectiveScale <= 0 {
            paintFallback(buffer)
            return
        }

        let renderWidth = totalModules * effectiveScale
        let renderHeightPixels = totalModules * effectiveScale
        let xOffset = Swift.max(0, (width - renderWidth) / 2)
        let yOffsetPixels = Swift.max(0, (height * 2 - renderHeightPixels) / 2)

        for cellY in 0..<height {
            let topPixel = cellY * 2 - yOffsetPixels
            let bottomPixel = topPixel + 1
            let intersectsRenderY = bottomPixel >= 0 && topPixel < renderHeightPixels

            if intersectsRenderY {
                buffer.fillRect(x: xOffset, y: cellY, width: renderWidth, height: 1, bg: _backgroundColor)
            }

            for cellX in 0..<renderWidth {
                let top = isDarkAtScaledPixel(
                    renderPixelX: cellX,
                    renderPixelY: topPixel,
                    scale: effectiveScale,
                    renderExtent: renderHeightPixels
                )
                let bottom = isDarkAtScaledPixel(
                    renderPixelX: cellX,
                    renderPixelY: bottomPixel,
                    scale: effectiveScale,
                    renderExtent: renderHeightPixels
                )

                if !top && !bottom {
                    continue
                }

                buffer.setCell(
                    x: xOffset + cellX,
                    y: cellY,
                    char: qrBlockCharacter(top: top, bottom: bottom),
                    fg: _foregroundColor,
                    bg: _backgroundColor
                )
            }
        }
    }

    private func rebuildMatrix() {
        encoded = encodeContent(_content, _errorCorrectionLevel)
        modules = encoded?.toMatrix() ?? []
        remeasure()
    }

    private func remeasure() {
        invalidateRenderBuffer()
        invalidateIntrinsicSize()
        requestRender()
    }

    private func invalidateRenderBuffer() {
        renderBufferDirty = true
    }

    private func getRenderBuffer() -> OptimizedBuffer {
        if let existing = renderBuffer {
            if existing.width != width || existing.height != height {
                try? existing.resize(width: width, height: height)
                invalidateRenderBuffer()
            }
            return existing
        }

        let created = OptimizedBuffer(
            width: width,
            height: height,
            widthMethod: ctx.widthMethod,
            respectAlpha: true,
            id: "qrcode-renderable-\(id)",
            graphemePool: ctx.graphemePool,
            linkPool: ctx.linkPool
        )
        renderBuffer = created
        invalidateRenderBuffer()
        return created
    }

    private func setupMeasureFunc() {
        setMeasureProvider { [weak self] width, widthMode, height, heightMode in
            guard let self else { return .zero }
            let scale = self.resolveMeasuredScale(
                width: width,
                widthMode: widthMode,
                height: height,
                heightMode: heightMode
            )
            if scale > 0, let encoded = self.encoded {
                return qrDimensionsForScale(moduleCount: encoded.size, quietZone: self._quietZone, scale: scale)
            }
            if !self._fallbackContent.isEmpty {
                return FlexSize(
                    width: Float(qrFallbackWidth(content: self._fallbackContent, width: width, widthMode: widthMode)),
                    height: 1
                )
            }
            return .zero
        }
    }

    private func resolveMeasuredScale(
        width: Float,
        widthMode: MeasureMode,
        height: Float,
        heightMode: MeasureMode
    ) -> Int {
        let availableWidth: Int? = (widthMode == .undefined || !width.isFinite) ? nil : Int(width.rounded(.down))
        let availableHeight: Int? = (heightMode == .undefined || !height.isFinite) ? nil : Int(height.rounded(.down))
        return resolveScaleForBounds(availableWidth: availableWidth, availableHeight: availableHeight)
    }

    private func resolveRenderScale(width: Int, height: Int) -> Int {
        resolveScaleForBounds(availableWidth: width, availableHeight: height)
    }

    private func resolveScaleForBounds(availableWidth: Int?, availableHeight: Int?) -> Int {
        guard let encoded else { return 0 }
        if _fit == .none {
            return _scale
        }

        let totalModules = encoded.size + _quietZone * 2
        guard totalModules > 0 else { return 0 }

        var resolvedScale = _scale
        if let availableWidth {
            resolvedScale = Swift.min(resolvedScale, availableWidth / totalModules)
        }
        if let availableHeight {
            resolvedScale = Swift.min(resolvedScale, (availableHeight * 2) / totalModules)
        }
        return Swift.max(0, resolvedScale)
    }

    private func isDarkAtScaledPixel(
        renderPixelX: Int,
        renderPixelY: Int,
        scale: Int,
        renderExtent: Int
    ) -> Bool {
        if renderPixelX < 0 || renderPixelY < 0 || renderPixelX >= renderExtent || renderPixelY >= renderExtent {
            return false
        }
        guard let encoded else { return false }

        let moduleX = (renderPixelX / scale) - _quietZone
        let moduleY = (renderPixelY / scale) - _quietZone
        let rawDark: Bool
        if moduleX < 0 || moduleY < 0 || moduleX >= encoded.size || moduleY >= encoded.size {
            rawDark = false
        } else {
            rawDark = modules[moduleY][moduleX]
        }
        return _invert ? !rawDark : rawDark
    }

    private func paintFallback(_ buffer: OptimizedBuffer) {
        guard !_fallbackContent.isEmpty, width > 0, height > 0 else { return }
        let chars = Array(_fallbackContent.prefix(width))
        let xOffset = Swift.max(0, (width - chars.count) / 2)
        let yOffset = Swift.max(0, height / 2)

        for (i, ch) in chars.enumerated() {
            buffer.setCell(x: xOffset + i, y: yOffset, char: String(ch), fg: _fallbackColor, bg: qrTransparent)
        }
    }
}

// MARK: - QRCodeRenderable

/// Terminal QR Code Model 2 renderable with half-block rasterization and intrinsic layout sizing,
/// matching `qrcode/src/renderables/QRCode.ts#QRCodeRenderable`.
// parity: qrcode/src/renderables/QRCode.ts#QRCodeRenderable [status=implemented hash=543aa36f11b5]
open class QRCodeRenderable: BaseQRCodeRenderable, @unchecked Sendable {
    public init(ctx: any RenderContext, options: QRCodeOptions = QRCodeOptions()) {
        super.init(
            ctx: ctx,
            options: options,
            minimumQuietZone: qrMinimumQuietZone,
            encodeContent: { content, ecl in
                try? QRCode.encodeText(content, ecl: ecl)
            }
        )
    }
}
