import OpenTUICore
import OpenTUILayout

// MARK: - FrameBufferOptions

/// Options for constructing a `FrameBufferRenderable`, matching `core/src/renderables/FrameBuffer.ts#FrameBufferOptions`.
// parity: core/src/renderables/FrameBuffer.ts#FrameBufferOptions [status=implemented hash=f1800681581a]
public struct FrameBufferOptions {
    public var renderable: RenderableOptions
    public var width: Int
    public var height: Int
    public var respectAlpha: Bool

    public init(
        width: Int,
        height: Int,
        respectAlpha: Bool = false,
        id: String? = nil,
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
        live: Bool? = nil,
        focusable: Bool? = nil,
        selectable: Bool? = nil,
        renderBefore: ((OptimizedBuffer, Double) -> Void)? = nil,
        renderAfter: ((OptimizedBuffer, Double) -> Void)? = nil,
        onMouse: ((MouseEvent) -> Void)? = nil,
        onMouseDown: ((MouseEvent) -> Void)? = nil,
        onMouseUp: ((MouseEvent) -> Void)? = nil,
        onSizeChange: (() -> Void)? = nil
    ) {
        self.width = width
        self.height = height
        self.respectAlpha = respectAlpha
        self.renderable = RenderableOptions(
            id: id,
            width: .point(Float(Swift.max(1, width))),
            height: .point(Float(Swift.max(1, height))),
            minWidth: minWidth,
            maxWidth: maxWidth,
            minHeight: minHeight,
            maxHeight: maxHeight,
            flexGrow: flexGrow,
            flexShrink: flexShrink,
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
            live: live,
            focusable: focusable,
            selectable: selectable,
            buffered: false,
            renderBefore: renderBefore,
            renderAfter: renderAfter,
            onMouse: onMouse,
            onMouseDown: onMouseDown,
            onMouseUp: onMouseUp,
            onSizeChange: onSizeChange
        )
    }

    public init(
        renderable: RenderableOptions,
        width: Int,
        height: Int,
        respectAlpha: Bool = false
    ) {
        var opts = renderable
        opts.width = .point(Float(Swift.max(1, width)))
        opts.height = .point(Float(Swift.max(1, height)))
        opts.buffered = false
        self.renderable = opts
        self.width = width
        self.height = height
        self.respectAlpha = respectAlpha
    }
}

// MARK: - FrameBufferRenderable

/// Renderable owning an offscreen `OptimizedBuffer` surface blitted into the scene on every paint,
/// matching `core/src/renderables/FrameBuffer.ts#FrameBufferRenderable`.
// parity: core/src/renderables/FrameBuffer.ts#FrameBufferRenderable [status=implemented hash=61f132ebda7a]
open class FrameBufferRenderable: Renderable, @unchecked Sendable {
    public private(set) var respectAlpha: Bool

    public init(ctx: any RenderContext, options: FrameBufferOptions) {
        self.respectAlpha = options.respectAlpha

        var baseOptions = options.renderable
        baseOptions.width = .point(Float(Swift.max(1, options.width)))
        baseOptions.height = .point(Float(Swift.max(1, options.height)))
        baseOptions.buffered = false

        super.init(ctx: ctx, options: baseOptions)

        let safeWidth = Swift.max(1, options.width)
        let safeHeight = Swift.max(1, options.height)
        self.frameBuffer = OptimizedBuffer(
            width: safeWidth,
            height: safeHeight,
            widthMethod: ctx.widthMethod,
            respectAlpha: self.respectAlpha,
            id: options.renderable.id ?? "framebufferrenderable-\(id)",
            graphemePool: ctx.graphemePool,
            linkPool: ctx.linkPool
        )
    }

    /// Replaces the owned offscreen framebuffer surface and schedules a re-render.
    public func setFrameBuffer(_ surface: OptimizedBuffer?) {
        guard !_isDestroyed else { return }
        if frameBuffer === surface { return }
        frameBuffer = surface
        requestRender()
    }

    /// Updates alpha compositing behavior on the owned framebuffer surface.
    public func setRespectAlpha(_ value: Bool) {
        guard !_isDestroyed else { return }
        respectAlpha = value
        frameBuffer?.setRespectAlpha(value)
        requestRender()
    }

    open override func onResize(width: Int, height: Int) {
        if width > 0 && height > 0 {
            if let fb = frameBuffer {
                if fb.width != width || fb.height != height {
                    try? fb.resize(width: width, height: height)
                }
            } else {
                frameBuffer = OptimizedBuffer(
                    width: width,
                    height: height,
                    widthMethod: ctx.widthMethod,
                    respectAlpha: respectAlpha,
                    id: "framebufferrenderable-\(id)",
                    graphemePool: ctx.graphemePool,
                    linkPool: ctx.linkPool
                )
            }
        }
        super.onResize(width: width, height: height)
        requestRender()
    }

    open override func renderSelf(buffer: OptimizedBuffer, deltaTime: Double) {
        guard _visible && !_isDestroyed, let fb = frameBuffer else { return }
        let origin = paintOrigin(for: buffer)
        buffer.drawFrameBuffer(destX: origin.x, destY: origin.y, frameBuffer: fb)
    }
}
