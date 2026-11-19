#if canImport(SwiftUI) && (os(macOS) || os(iOS) || os(visionOS))
import OpenCodeTUI
import SwiftUI

/// Rich native SwiftUI Markdown renderer powered by `OpenCodeTUI.PatchmarkStream`,
/// `OpenCodeTUI.Merman` (Mermaid diagrams), and `OpenCodeTUI.LatexPlugin` (LaTeX math).
public struct OpenCodeMarkdownView: View {
    public let markdown: String
    public let palette: AppResolvedPalette
    public let concealMarkdown: Bool
    public let streaming: Bool

    public init(
        markdown: String,
        palette: AppResolvedPalette,
        concealMarkdown: Bool = true,
        streaming: Bool = false
    ) {
        self.markdown = markdown
        self.palette = palette
        self.concealMarkdown = concealMarkdown
        self.streaming = streaming
    }

    public var body: some View {
        if !concealMarkdown {
            Text(markdown)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(palette.textPrimaryColor)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let blocks = OpenCodeAppMarkdown.renderBlocks(markdown, palette: palette, streaming: streaming)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(blocks) { block in
                    blockView(block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func blockView(_ block: OpenCodeAppMarkdown.RenderedBlock) -> some View {
        switch block {
        case let .heading(_, level, text):
            Text(text)
                .font(headingFont(level))
                .foregroundStyle(palette.markdownHeadingColor)
                .textSelection(.enabled)
                .padding(.top, level <= 2 ? 4 : 2)

        case let .paragraph(_, inlines):
            inlineText(inlines)
                .font(.body)
                .foregroundStyle(palette.textPrimaryColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case let .code(_, language, source):
            MarkdownCodeBlockCard(language: language, source: source, palette: palette)

        case let .mermaid(_, kind, source, rendered):
            MermaidDiagramCard(kind: kind, source: source, rendered: rendered, palette: palette)

        case let .math(_, source, rendered):
            LatexMathCard(source: source, rendered: rendered, palette: palette)

        case let .blockquote(_, text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(palette.markdownQuoteColor)
                    .frame(width: 3)
                Text(text)
                    .font(.body.italic())
                    .foregroundStyle(palette.textMutedColor)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 2)

        case let .list(_, ordered, start, items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .top, spacing: 8) {
                        if let checked = item.checked {
                            Image(systemName: checked ? "checkmark.square.fill" : "square")
                                .font(.callout)
                                .foregroundStyle(checked ? palette.successColor : palette.textMutedColor)
                                .padding(.top, 2)
                        } else if ordered {
                            Text("\(start + idx).")
                                .font(.body.monospacedDigit())
                                .foregroundStyle(palette.textMutedColor)
                                .frame(minWidth: 22, alignment: .trailing)
                        } else {
                            Text("•")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(palette.interactiveColor)
                                .frame(width: 14, alignment: .center)
                        }
                        Text(item.text)
                            .font(.body)
                            .foregroundStyle(palette.textPrimaryColor)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

        case let .table(_, headers, rows):
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    if !headers.isEmpty {
                        HStack(spacing: 0) {
                            ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                                Text(header)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(palette.textPrimaryColor)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .frame(minWidth: 110, alignment: .leading)
                            }
                        }
                        .background(palette.surfaceHighColor)
                    }
                    ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                        HStack(spacing: 0) {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(cell)
                                    .font(.caption)
                                    .foregroundStyle(palette.textPrimaryColor)
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .frame(minWidth: 110, alignment: .leading)
                            }
                        }
                        .background(rowIdx.isMultiple(of: 2) ? palette.surfaceRaisedColor.opacity(0.6) : Color.clear)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(palette.borderColor.opacity(0.45), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

        case .horizontalRule:
            Divider()
                .overlay(palette.borderColor.opacity(0.6))
                .padding(.vertical, 4)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2.weight(.bold)
        case 2: return .title3.weight(.semibold)
        case 3: return .headline.weight(.semibold)
        default: return .subheadline.weight(.semibold)
        }
    }

    private func inlineText(_ nodes: [InlineNode]) -> Text {
        var attributed = AttributedString()
        for node in nodes {
            attributed.append(buildAttributedInline(node))
        }
        return Text(attributed)
    }

    private func buildAttributedInline(_ node: InlineNode) -> AttributedString {
        switch node {
        case .text(let s):
            return AttributedString(s)

        case .strong(let children):
            var combined = AttributedString()
            for child in children { combined.append(buildAttributedInline(child)) }
            combined.inlinePresentationIntent = .stronglyEmphasized
            combined.foregroundColor = palette.markdownStrongColor
            return combined

        case .em(let children):
            var combined = AttributedString()
            for child in children { combined.append(buildAttributedInline(child)) }
            combined.inlinePresentationIntent = .emphasized
            combined.foregroundColor = palette.markdownEmphasisColor
            return combined

        case .del(let children):
            var combined = AttributedString()
            for child in children { combined.append(buildAttributedInline(child)) }
            combined.strikethroughStyle = .single
            combined.foregroundColor = palette.textMutedColor
            return combined

        case .code(let code):
            var s = AttributedString(" \(code) ")
            s.font = .system(.callout, design: .monospaced)
            s.foregroundColor = palette.markdownCodeColor
            s.backgroundColor = palette.surfaceHighColor.opacity(0.75)
            return s

        case let .math(source, _, display):
            let rendered = OpenCodeAppMarkdown.renderLatex(source, displayMode: display)
            var s = AttributedString(rendered)
            s.font = .system(.callout, design: .monospaced)
            s.foregroundColor = palette.accentColor
            return s

        case let .link(href, _, children):
            var combined = AttributedString()
            for child in children { combined.append(buildAttributedInline(child)) }
            if combined.characters.isEmpty {
                combined = AttributedString(href)
            }
            if let url = URL(string: href) {
                combined.link = url
            }
            combined.foregroundColor = palette.markdownLinkColor
            combined.underlineStyle = .single
            return combined

        case let .image(_, alt, _, _):
            var s = AttributedString(alt.isEmpty ? "[image]" : "[\(alt)]")
            s.foregroundColor = palette.textMutedColor
            return s

        case .htmlInline(let raw):
            return AttributedString(raw)

        case .br:
            return AttributedString("\n")
        }
    }
}

// MARK: - Code Block Card

private struct MarkdownCodeBlockCard: View {
    let language: String?
    let source: String
    let palette: AppResolvedPalette
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.caption2)
                    .foregroundStyle(palette.textMutedColor)
                Text((language?.isEmpty == false ? language! : "code").lowercased())
                    .font(.caption.monospaced().weight(.medium))
                    .foregroundStyle(palette.textMutedColor)
                Spacer()
                Button {
                    OpenCodeAppClipboard.copy(source)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(copied ? palette.successColor : palette.textMutedColor)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(palette.surfaceHighColor.opacity(0.8))

            ScrollView(.horizontal, showsIndicators: true) {
                Text(source)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(palette.textPrimaryColor)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(palette.surfaceRaisedColor)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(palette.borderColor.opacity(0.45), lineWidth: 1)
        )
    }
}

// MARK: - Merman Mermaid Diagram Card

private struct MermaidDiagramCard: View {
    let kind: String
    let source: String
    let rendered: String?
    let palette: AppResolvedPalette
    @State private var showSource = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.caption)
                    .foregroundStyle(palette.accentColor)
                Text("Mermaid • \(kind)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.textPrimaryColor)
                Spacer()
                if rendered != nil {
                    Button(showSource ? "Diagram" : "Source") {
                        showSource.toggle()
                    }
                    .font(.caption2.weight(.medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.interactiveColor)
                }
                Button {
                    OpenCodeAppClipboard.copy(showSource ? source : (rendered ?? source))
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(palette.textMutedColor)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(palette.surfaceHighColor.opacity(0.85))

            ScrollView(.horizontal, showsIndicators: true) {
                Text((!showSource ? rendered : nil) ?? source)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(palette.textPrimaryColor)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(palette.surfaceRaisedColor)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(palette.accentColor.opacity(0.35), lineWidth: 1)
        )
    }
}

// MARK: - LaTeX Math Preview Card

private struct LatexMathCard: View {
    let source: String
    let rendered: String
    let palette: AppResolvedPalette
    @State private var showSource = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "function")
                    .font(.caption)
                    .foregroundStyle(palette.infoColor)
                Text("LaTeX Math")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.textPrimaryColor)
                Spacer()
                Button(showSource ? "Preview" : "TeX") {
                    showSource.toggle()
                }
                .font(.caption2.weight(.medium))
                .buttonStyle(.plain)
                .foregroundStyle(palette.interactiveColor)
                Button {
                    OpenCodeAppClipboard.copy(source)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(palette.textMutedColor)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(palette.surfaceHighColor.opacity(0.85))

            ScrollView(.horizontal, showsIndicators: true) {
                Text(showSource ? source : rendered)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(palette.textPrimaryColor)
                    .textSelection(.enabled)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .background(palette.surfaceRaisedColor)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(palette.infoColor.opacity(0.35), lineWidth: 1)
        )
    }
}
#endif
