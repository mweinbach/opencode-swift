// OpenTUI Markdown fenced code-block and inline math adapter (`packages/latex/src/markdown.ts`).

import OpenTUICore
import OpenTUILayout
import OpenTUIRenderables
import Synchronization

/// Theme color palette passed to `createLatexCodeBlockRenderer`.
// parity: latex/src/markdown.ts#LatexOptions [status=implemented hash=d723bd2b45ea]
public struct LatexOptions: Equatable, Hashable, Sendable {
    public var text: Color
    public var subdued: Color

    public init(text: Color, subdued: Color) {
        self.text = text
        self.subdued = subdued
    }
}

/// Reference-identity cached frame so replacing a streaming block distinguishes old vs. retained frames on destroy.
private final class LatexFrame: Sendable {
    let source: String
    let layout: MathLayout

    init(source: String, layout: MathLayout) {
        self.source = source
        self.layout = layout
    }
}

/// Creates a `MarkdownCodeBlockRenderer` that renders `latex`/`math`/`tex` fences into horizontally scrollable
/// 2D Unicode math formulas, retaining the last valid formula while an open fence streams and falling back
/// to the default `CodeRenderable` for invalid, unsupported, or oversized input.
// parity: latex/src/markdown.ts#createLatexCodeBlockRenderer [status=implemented hash=6ffc24491172]
public func createLatexCodeBlockRenderer(
    _ context: any RenderContext,
    options: @escaping () -> LatexOptions
) -> MarkdownCodeBlockRenderer {
    let lastGood = Mutex<[String: LatexFrame]>([:])
    return { token, render in
        let fallback = render.defaultRender()
        let key = fallback?.id
        let previous = key.flatMap { id in lastGood.withLock { $0[id] } }
        let retained: LatexFrame? = if let previous, token.text.hasPrefix(previous.source) {
            previous
        } else {
            nil
        }
        let fence = extractOpeningFence(token.raw)
        let streaming: Bool
        if let codeFallback = fallback as? CodeRenderable,
           codeFallback.streaming,
           let fence,
           !hasClosingFence(token.raw, char: fence.char, minLength: fence.length)
        {
            streaming = true
        } else {
            streaming = false
        }

        let layout = layoutLatex(token.text)
        let frame: LatexFrame?
        if let layout {
            frame = LatexFrame(source: token.text, layout: layout)
        } else if streaming, let retained {
            frame = LatexFrame(source: retained.source, layout: retained.layout)
        } else {
            frame = nil
        }

        guard let frame else {
            return fallback
        }

        let palette = options()
        let text = palette.text.resolved()
        let subdued = palette.subdued.resolved()
        let chunks = buildStyledChunks(for: frame.layout, text: text, subdued: subdued)

        let formula = TextRenderable(
            ctx: context,
            options: TextOptions(
                content: .styled(StyledText(chunks: chunks)),
                width: .percent(100),
                height: .point(Float(frame.layout.height)),
                minWidth: .point(Float(frame.layout.width)),
                flexShrink: 0,
                selectable: false,
                wrapMode: TextWrapMode.none
            )
        )

        var scrollOptions = ScrollBoxOptions(
            width: .percent(100),
            height: .point(Float(frame.layout.height)),
            flexShrink: 0,
            scrollX: true,
            scrollY: false
        )
        scrollOptions.box.renderable.marginTop = .point(1)
        scrollOptions.box.renderable.onMouseScroll = { event in
            if event.modifiers.shift || event.scroll?.direction == .left || event.scroll?.direction == .right {
                event.stopPropagation()
            }
        }
        let viewport = ScrollBoxRenderable(ctx: context, options: scrollOptions)
        // The setters opt out of automatic scrollbar visibility; constructor options do not.
        viewport.horizontalScrollBar.visible = false
        viewport.verticalScrollBar.visible = false
        viewport.add(formula)

        if let key {
            lastGood.withLock { $0[key] = frame }
            let cleaned = Mutex(false)
            _ = viewport.on(.destroyed) {
                let shouldRun = cleaned.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                guard shouldRun else { return }
                lastGood.withLock { map in
                    if map[key] === frame {
                        map.removeValue(forKey: key)
                    }
                }
            }
        }

        return viewport
    }
}

/// Optional `MarkdownInlineHook` companion that renders single-line inline math spans (`span.math != nil`)
/// into styled Unicode math spans, falling back to the original span when multi-line or invalid.
public func createLatexInlineMathHook(
    options: @escaping () -> LatexOptions
) -> MarkdownInlineHook {
    return { spans, _ in
        guard spans.contains(where: { $0.math != nil }) else { return spans }
        let palette = options()
        let text = palette.text.resolved()
        let subdued = palette.subdued.resolved()
        var out: [MarkdownInlineSpan] = []
        out.reserveCapacity(spans.count)

        for span in spans {
            guard let mathSource = span.math,
                  let layout = layoutLatexInline(mathSource),
                  layout.height == 1,
                  let row = layout.cells.first
            else {
                out.append(span)
                continue
            }
            for column in 0..<row.count {
                if column > 0, let prev = row[column - 1]?.char, TUIUtil.stringWidth(prev) > 1 {
                    continue
                }
                let cell = row[column]
                let glyph = cell?.char ?? " "
                let fg = isStructuralMathGlyph(glyph) ? subdued : text
                let attrs = createTextAttributes(
                    bold: (cell?.style?.bold ?? false) || isRelationMathGlyph(glyph),
                    italic: cell?.style?.italic ?? false,
                    dim: cell?.style?.dim ?? false
                )
                out.append(
                    MarkdownInlineSpan(
                        text: glyph,
                        fg: fg,
                        bg: span.bg,
                        attributes: attrs,
                        link: span.link,
                        code: false,
                        math: mathSource,
                        target: span.target
                    )
                )
            }
        }
        return out
    }
}

private func buildStyledChunks(for layout: MathLayout, text: RGBA, subdued: RGBA) -> [TextChunk] {
    var chunks: [TextChunk] = []
    chunks.reserveCapacity(layout.height * (layout.width + 1))

    for (rowIndex, row) in layout.cells.enumerated() {
        for column in 0..<row.count {
            // Wide glyphs already occupy the following cell; do not emit another space for it.
            if column > 0, let prev = row[column - 1]?.char, TUIUtil.stringWidth(prev) > 1 {
                continue
            }
            let cell = row[column]
            let glyph = cell?.char ?? " "
            let fg = isStructuralMathGlyph(glyph) ? subdued : text
            let attributes = createTextAttributes(
                bold: (cell?.style?.bold ?? false) || isRelationMathGlyph(glyph),
                italic: cell?.style?.italic ?? false,
                dim: cell?.style?.dim ?? false
            )
            chunks.append(TextChunk(text: glyph, fg: fg, attributes: attributes))
        }
        if rowIndex < layout.height - 1 {
            chunks.append(TextChunk(text: "\n", fg: text))
        }
    }
    return chunks
}

private func isStructuralMathGlyph(_ value: String) -> Bool {
    guard value.unicodeScalars.count == 1, let scalar = value.unicodeScalars.first else {
        return false
    }
    let v = scalar.value
    switch v {
    case 0x28, 0x29, 0x5B, 0x5D, 0x7B, 0x7D, 0x7C, // ( ) [ ] { } |
         0x221A,                                    // √
         0x239B...0x23AD,                           // tall paren/bracket/brace pieces
         0x2500...0x257F:                           // box drawing characters
        return true
    default:
        return false
    }
}

private func isRelationMathGlyph(_ value: String) -> Bool {
    guard value.unicodeScalars.count == 1, let scalar = value.unicodeScalars.first else {
        return false
    }
    let v = scalar.value
    switch v {
    case 0x3D, 0x3C, 0x3E, // = < >
         0x2260,            // ≠
         0x2261,            // ≡
         0x2264,            // ≤
         0x2265,            // ≥
         0x2248:            // ≈
        return true
    default:
        return false
    }
}

private func extractOpeningFence(_ raw: String) -> (char: Character, length: Int)? {
    var index = raw.startIndex
    var spaces = 0
    while index < raw.endIndex && raw[index] == " " && spaces < 3 {
        index = raw.index(after: index)
        spaces += 1
    }
    guard index < raw.endIndex else { return nil }
    let fenceChar = raw[index]
    guard fenceChar == "`" || fenceChar == "~" else { return nil }
    var count = 0
    while index < raw.endIndex && raw[index] == fenceChar {
        count += 1
        index = raw.index(after: index)
    }
    guard count >= 3 else { return nil }
    return (fenceChar, count)
}

private func hasClosingFence(_ raw: String, char: Character, minLength: Int) -> Bool {
    let trimmed = latexTrimEnd(raw)
    guard let newlineIndex = trimmed.lastIndex(of: "\n") else { return false }
    var index = trimmed.index(after: newlineIndex)
    var spaces = 0
    while index < trimmed.endIndex && trimmed[index] == " " && spaces < 3 {
        index = trimmed.index(after: index)
        spaces += 1
    }
    var count = 0
    while index < trimmed.endIndex && trimmed[index] == char {
        count += 1
        index = trimmed.index(after: index)
    }
    return index == trimmed.endIndex && count >= minLength
}

private func layoutLatex(_ source: String) -> MathLayout? {
    do {
        return try renderLatex(source, options: RenderLatexOptions(strict: true, displayMode: true))
    } catch is LatexParseError {
        // Preserve the exact source for incomplete math, unsupported commands, and oversized input.
        return nil
    } catch is LatexRangeError {
        return nil
    } catch {
        return nil
    }
}

private func layoutLatexInline(_ source: String) -> MathLayout? {
    do {
        return try renderLatex(source, options: RenderLatexOptions(strict: true, displayMode: false))
    } catch {
        return nil
    }
}
