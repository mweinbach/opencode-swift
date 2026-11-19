import OpenCodeClient
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil
import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout
import OpenTUIRenderables
import OpenTUITerminal
import OpenTUIView

/// Entry module for `OpenCodeTUI` (port of `packages/tui`, `packages/theme`, and `packages/patchmark`),
/// built directly on the cross-platform `OpenTUI` Swift package (`Packages/OpenTUI`).
public enum OpenCodeTUIModule {
    public static let upstreamPackage = "tui"

    /// Renders a minimal diagnostic banner using `OpenTUI` primitives to verify end-to-end linkage.
    public static func renderStatusBanner(width: Int = 60, height: Int = 1) -> CellBuffer {
        var buffer = CellBuffer(width: width, height: height)
        let title = StaticTextBlock(
            id: "opencode-status",
            text: "swift-opencode • OpenTUI (\(Platform.current.rawValue))",
            foreground: parseColor("#66ffff"),
            attributes: createTextAttributes(bold: true)
        )
        title.render(into: &buffer, rect: LayoutRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
