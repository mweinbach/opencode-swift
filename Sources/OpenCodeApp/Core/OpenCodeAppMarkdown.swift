import Foundation
import OpenCodeTUI
import OpenTUICore

/// Cross-platform Markdown block renderer bridging `OpenCodeTUI.PatchmarkStream`,
/// `OpenCodeTUI.Merman` (Mermaid diagrams), and `OpenCodeTUI.LatexPlugin` (LaTeX math).
public enum OpenCodeAppMarkdown {
    /// Pre-parsed and pre-rendered Markdown block ready for native SwiftUI presentation or testing.
    public enum RenderedBlock: Identifiable, Equatable, Hashable, Sendable {
        case heading(id: Int, level: Int, text: String)
        case paragraph(id: Int, inlines: [InlineNode])
        case code(id: Int, language: String?, source: String)
        case mermaid(id: Int, kind: String, source: String, renderedDiagram: String?)
        case math(id: Int, source: String, renderedMath: String)
        case blockquote(id: Int, text: String)
        case list(id: Int, ordered: Bool, start: Int, items: [RenderedListItem])
        case table(id: Int, headers: [String], rows: [[String]])
        case horizontalRule(id: Int)

        public var id: Int {
            switch self {
            case .heading(let id, _, _): return id
            case .paragraph(let id, _): return id
            case .code(let id, _, _): return id
            case .mermaid(let id, _, _, _): return id
            case .math(let id, _, _): return id
            case .blockquote(let id, _): return id
            case .list(let id, _, _, _): return id
            case .table(let id, _, _): return id
            case .horizontalRule(let id): return id
            }
        }
    }

    public struct RenderedListItem: Equatable, Hashable, Sendable {
        public let checked: Bool?
        public let text: String

        public init(checked: Bool?, text: String) {
            self.checked = checked
            self.text = text
        }
    }

    /// Parses Markdown text via `PatchmarkStream`, rendering Mermaid blocks with `Merman`
    /// and LaTeX blocks with `LatexPlugin` / `renderLatexToString`.
    public static func renderBlocks(
        _ markdown: String,
        palette: AppResolvedPalette = AppResolvedPalette(),
        streaming: Bool = false
    ) -> [RenderedBlock] {
        guard !markdown.isEmpty else { return [] }
        let stream = PatchmarkStream(StreamOptions(gfm: true, math: true, heal: streaming))
        let frame = stream.update(markdown, streaming: streaming)
        var out: [RenderedBlock] = []
        out.reserveCapacity(frame.blocks.count)
        var counter = 0

        for block in frame.blocks {
            appendConverted(block.kind, palette: palette, counter: &counter, into: &out)
        }
        return out
    }

    /// Renders a Mermaid diagram source to Unicode box-drawing text using `OpenCodeTUI.Merman`.
    public static func renderMermaid(
        _ source: String,
        palette: AppResolvedPalette = AppResolvedPalette(),
        maxWidth: Int = 96
    ) -> (kind: String, diagram: String?) {
        guard let kind = Merman.detectMermaidDiagram(source) else {
            return ("mermaid", nil)
        }
        let diagPalette = Merman.resolveOpenCodeDiagramPalette(
            theme: palette.resolvedTheme,
            mode: palette.effectiveMode
        )
        let opts = Merman.MermaidMarkdownRendererOptions(
            compact: true,
            layoutMaxWidth: maxWidth,
            colors: diagPalette.asColorOverrides()
        )
        if let prepared = try? Merman.prepareMermaidDiagram(
            kind: kind,
            source: source,
            options: opts,
            layoutMaxWidth: maxWidth
        ) {
            return (kind.rawValue, prepared.text.plainText)
        }
        return (kind.rawValue, nil)
    }

    /// Renders a LaTeX expression to Unicode 2D math layout using `OpenCodeTUI.renderLatexToString`.
    public static func renderLatex(_ source: String, displayMode: Bool = true) -> String {
        if let rendered = try? renderLatexToString(
            source,
            options: RenderLatexOptions(strict: false, displayMode: displayMode)
        ), !rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return rendered
        }
        return LatexPlugin.renderCodeBlock(source)
    }

    /// Flattens `[InlineNode]` into clean human-readable text (with inline LaTeX rendered!).
    public static func plainText(from inlines: [InlineNode]) -> String {
        var out = ""
        for node in inlines {
            switch node {
            case .text(let s):
                out.append(s)
            case .strong(let children), .em(let children), .del(let children):
                out.append(plainText(from: children))
            case .code(let code):
                out.append("`\(code)`")
            case .math(let source, _, let display):
                out.append(renderLatex(source, displayMode: display))
            case .link(let href, _, let children):
                let label = plainText(from: children)
                out.append(label.isEmpty ? href : label)
            case .image(_, let alt, _, _):
                out.append(alt)
            case .htmlInline(let raw):
                out.append(raw)
            case .br:
                out.append("\n")
            }
        }
        return out
    }

    private static func appendConverted(
        _ kind: BlockKind,
        palette: AppResolvedPalette,
        counter: inout Int,
        into out: inout [RenderedBlock]
    ) {
        let blockID = counter
        counter += 1

        switch kind {
        case let .heading(level, inlines):
            out.append(.heading(id: blockID, level: level.rawValue, text: plainText(from: inlines)))

        case let .paragraph(inlines):
            out.append(.paragraph(id: blockID, inlines: inlines))

        case let .code(language, _, source, _, _, _, _):
            let lowerLang = language?.lowercased()
            if lowerLang == "latex" || lowerLang == "math" {
                out.append(.math(id: blockID, source: source, renderedMath: renderLatex(source, displayMode: true)))
            } else if lowerLang == "mermaid" {
                let rendered = renderMermaid(source, palette: palette)
                out.append(.mermaid(id: blockID, kind: rendered.kind, source: source, renderedDiagram: rendered.diagram))
            } else {
                out.append(.code(id: blockID, language: language, source: source))
            }

        case let .mermaid(source, _, _):
            let rendered = renderMermaid(source, palette: palette)
            out.append(.mermaid(id: blockID, kind: rendered.kind, source: source, renderedDiagram: rendered.diagram))

        case let .math(source, _, _):
            out.append(.math(id: blockID, source: source, renderedMath: renderLatex(source, displayMode: true)))

        case let .blockquote(blocks):
            let text = blocks.map(flattenBlockText).joined(separator: "\n")
            out.append(.blockquote(id: blockID, text: text))

        case let .list(ordered, _, start, _, items):
            let mapped = items.map { item in
                RenderedListItem(
                    checked: item.checked,
                    text: item.blocks.map(flattenBlockText).joined(separator: "\n")
                )
            }
            out.append(.list(id: blockID, ordered: ordered, start: start ?? 1, items: mapped))

        case let .table(_, headers, rows):
            out.append(.table(
                id: blockID,
                headers: headers.map { plainText(from: $0) },
                rows: rows.map { row in row.map { plainText(from: $0) } }
            ))

        case let .htmlBlock(raw):
            out.append(.code(id: blockID, language: "html", source: raw))

        case .hr:
            out.append(.horizontalRule(id: blockID))

        case let .group(blocks):
            for child in blocks {
                appendConverted(child, palette: palette, counter: &counter, into: &out)
            }
        }
    }

    private static func flattenBlockText(_ kind: BlockKind) -> String {
        switch kind {
        case .paragraph(let inlines), .heading(_, let inlines):
            return plainText(from: inlines)
        case .code(_, _, let source, _, _, _, _), .mermaid(let source, _, _), .math(let source, _, _):
            return source
        case .blockquote(let blocks), .group(let blocks):
            return blocks.map(flattenBlockText).joined(separator: "\n")
        case .list(_, _, _, _, let items):
            return items.map { $0.blocks.map(flattenBlockText).joined(separator: " ") }.joined(separator: "\n")
        case .table(_, let headers, let rows):
            let headerLine = headers.map { plainText(from: $0) }.joined(separator: " | ")
            let rowLines = rows.map { row in row.map { plainText(from: $0) }.joined(separator: " | ") }
            return ([headerLine] + rowLines).joined(separator: "\n")
        case .htmlBlock(let raw):
            return raw
        case .hr:
            return "---"
        }
    }
}
