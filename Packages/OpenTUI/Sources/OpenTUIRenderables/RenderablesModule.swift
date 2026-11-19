import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout

/// Base protocol for OpenTUI renderable nodes (`Box`, `Text`, `Input`, `Textarea`, `ScrollBox`, `Diff`, `Markdown`, etc.).
public protocol OpenTUIRenderable: Sendable {
    var id: String { get }
    func render(into buffer: inout CellBuffer, rect: LayoutRect)
}

public struct StaticTextBlock: OpenTUIRenderable, Equatable, Sendable {
    public let id: String
    public let text: String
    public let foreground: RGBA
    public let background: RGBA
    public let attributes: UInt32

    public init(
        id: String = "text",
        text: String,
        foreground: RGBA = .defaultForeground(),
        background: RGBA = .defaultBackground(),
        attributes: UInt32 = TextAttributes.none
    ) {
        self.id = id
        self.text = text
        self.foreground = foreground
        self.background = background
        self.attributes = attributes
    }

    public func render(into buffer: inout CellBuffer, rect: LayoutRect) {
        var col = rect.x
        let row = rect.y
        guard row >= 0, row < buffer.height else { return }
        for scalar in text.unicodeScalars {
            if col >= rect.x + rect.width || col >= buffer.width { break }
            if col >= 0 {
                buffer.setCell(
                    x: col,
                    y: row,
                    cell: TerminalCell(
                        scalar: scalar.value,
                        foreground: foreground,
                        background: background,
                        attributes: attributes
                    )
                )
            }
            col += 1
        }
    }
}
