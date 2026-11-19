// parity: core/src/lib/render-geometry.ts#RenderGeometryScreenMode [status=implemented hash=6b2e574b8ac5]
public enum RenderGeometryScreenMode: String, Equatable, Hashable, Sendable, Codable {
    case alternateScreen = "alternate-screen"
    case mainScreen = "main-screen"
    case splitFooter = "split-footer"
}

// parity: core/src/lib/render-geometry.ts#RenderGeometry [status=implemented hash=e1fb9d866c1d]
public struct RenderGeometry: Equatable, Hashable, Sendable, Codable {
    public let effectiveFooterHeight: Int
    public let renderOffset: Int
    public let renderWidth: Int
    public let renderHeight: Int

    public init(
        effectiveFooterHeight: Int,
        renderOffset: Int,
        renderWidth: Int,
        renderHeight: Int
    ) {
        self.effectiveFooterHeight = effectiveFooterHeight
        self.renderOffset = renderOffset
        self.renderWidth = renderWidth
        self.renderHeight = renderHeight
    }
}

// parity: core/src/lib/render-geometry.ts#calculateRenderGeometry [status=implemented hash=29823eddd5ca]
public func calculateRenderGeometry(
    screenMode: RenderGeometryScreenMode,
    terminalWidth: Int,
    terminalHeight: Int,
    footerHeight: Int
) -> RenderGeometry {
    let safeWidth = max(terminalWidth, 0)
    let safeHeight = max(terminalHeight, 0)

    guard screenMode == .splitFooter else {
        return RenderGeometry(
            effectiveFooterHeight: 0,
            renderOffset: 0,
            renderWidth: safeWidth,
            renderHeight: safeHeight
        )
    }

    let effectiveFooterHeight = min(footerHeight, safeHeight)
    return RenderGeometry(
        effectiveFooterHeight: effectiveFooterHeight,
        renderOffset: safeHeight - effectiveFooterHeight,
        renderWidth: safeWidth,
        renderHeight: effectiveFooterHeight
    )
}
