/// Options controlling HTML rendering of Patchmark AST nodes.
// parity: patchmark/src/html.ts#HtmlRenderOptions [status=implemented hash=1a0fc38d4df2]
public struct HtmlRenderOptions: Equatable, Hashable, Sendable {
    public var gfm: Bool
    public var math: Bool

    public init(gfm: Bool = false, math: Bool = false) {
        self.gfm = gfm
        self.math = math
    }
}

private let disallowedHtmlTags: Set<String> = [
    "iframe",
    "noembed",
    "noframes",
    "plaintext",
    "script",
    "style",
    "title",
    "textarea",
    "xmp",
]

@inline(__always)
private func isDisallowedFollowByte(_ b: UInt8) -> Bool {
    b == 0x09 || b == 0x0A || b == 0x0C || b == 0x0D || b == 0x20 || b == 0x2F || b == 0x3E
}

/// Filters GFM tagfilter-disallowed raw HTML tags (`<script>`, `<iframe>`, `<style>`, etc.) by escaping `<` to `&lt;`.
// parity: patchmark/src/html.ts#filterDisallowedRawHtml [status=implemented hash=dc8d0747eda5]
public func filterDisallowedRawHtml(_ raw: String) -> String {
    let bytes = Array(raw.utf8)
    let n = bytes.count
    var hasLt = false
    for b in bytes where b == 0x3C {
        hasLt = true
        break
    }
    if !hasLt { return raw }

    var out: [UInt8] = []
    out.reserveCapacity(n)
    var i = 0
    var plainStart = 0
    while i < n {
        if bytes[i] == 0x3C /* < */ {
            var j = i + 1
            if j < n && bytes[j] == 0x2F /* / */ { j += 1 }
            let nameStart = j
            while j < n && j - nameStart < 10 {
                let b = bytes[j]
                if (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) {
                    j += 1
                } else {
                    break
                }
            }
            if j > nameStart && j < n && isDisallowedFollowByte(bytes[j]) {
                let lower = String(decoding: bytes[nameStart..<j].map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 32 : $0 }, as: UTF8.self)
                if disallowedHtmlTags.contains(lower) {
                    if i > plainStart {
                        out.append(contentsOf: bytes[plainStart..<i])
                    }
                    out.append(contentsOf: [0x26, 0x6C, 0x74, 0x3B]) // &lt;
                    out.append(contentsOf: bytes[(i + 1)..<j])
                    i = j
                    plainStart = j
                    continue
                }
            }
        }
        i += 1
    }
    if plainStart == 0 { return raw }
    if plainStart < n {
        out.append(contentsOf: bytes[plainStart..<n])
    }
    return String(decoding: out, as: UTF8.self)
}

/// Escapes HTML special characters (`&`, `<`, `>`, `"`) to named entities.
// parity: patchmark/src/html.ts#escapeHtml [status=implemented hash=37fda2788717]
public func escapeHtml(_ text: String) -> String {
    let bytes = Array(text.utf8)
    var needsEscape = false
    for b in bytes {
        if b == 0x26 || b == 0x3C || b == 0x3E || b == 0x22 {
            needsEscape = true
            break
        }
    }
    if !needsEscape { return text }

    var out: [UInt8] = []
    out.reserveCapacity(bytes.count + 16)
    for b in bytes {
        switch b {
        case 0x26: out.append(contentsOf: [0x26, 0x61, 0x6D, 0x70, 0x3B]) // &amp;
        case 0x3C: out.append(contentsOf: [0x26, 0x6C, 0x74, 0x3B]) // &lt;
        case 0x3E: out.append(contentsOf: [0x26, 0x67, 0x74, 0x3B]) // &gt;
        case 0x22: out.append(contentsOf: [0x26, 0x71, 0x75, 0x6F, 0x74, 0x3B]) // &quot;
        default: out.append(b)
        }
    }
    return String(decoding: out, as: UTF8.self)
}

/// Image alt text the way commonmark.js renders it: tags suppressed, text escaped, raw HTML kept.
private func renderAlt(_ nodes: [InlineNode]) -> String {
    var out = ""
    for node in nodes {
        switch node {
        case .text(let s), .code(let s):
            out.append(escapeHtml(s))
        case .strong(let children), .em(let children), .del(let children), .link(_, _, let children):
            out.append(renderAlt(children))
        case .image(_, let alt, _, let children):
            out.append(children.map(renderAlt) ?? escapeHtml(alt))
        case .math(let source, _, _):
            out.append(escapeHtml(source))
        case .br:
            out.append("\n")
        case .htmlInline(let raw):
            out.append(raw)
        }
    }
    return out
}

/// Renders an array of `InlineNode`s into an HTML fragment string.
// parity: patchmark/src/html.ts#renderInlinesToHtml [status=implemented hash=0ec17e6c424c]
public func renderInlinesToHtml(_ nodes: [InlineNode], options: HtmlRenderOptions? = nil) -> String {
    var out = ""
    let gfm = options?.gfm ?? false
    for node in nodes {
        switch node {
        case .text(let s):
            out.append(escapeHtml(s))
        case .strong(let children):
            out.append("<strong>\(renderInlinesToHtml(children, options: options))</strong>")
        case .em(let children):
            out.append("<em>\(renderInlinesToHtml(children, options: options))</em>")
        case .del(let children):
            out.append("<del>\(renderInlinesToHtml(children, options: options))</del>")
        case .code(let s):
            out.append("<code>\(escapeHtml(s))</code>")
        case .math(let source, let delimiter, let display):
            let cls = display ? "math-display" : "math-inline"
            out.append("<span class=\"\(cls)\" data-math-delimiter=\"\(delimiter.rawValue)\">\(escapeHtml(source))</span>")
        case .link(let href, let title, let children):
            let titleAttr = (title.map { !$0.isEmpty } ?? false) ? " title=\"\(escapeHtml(title!))\"" : ""
            out.append("<a href=\"\(escapeHtml(href))\"\(titleAttr)>\(renderInlinesToHtml(children, options: options))</a>")
        case .image(let src, let alt, let title, let children):
            let titleAttr = (title.map { !$0.isEmpty } ?? false) ? " title=\"\(escapeHtml(title!))\"" : ""
            let renderedAlt = children.map(renderAlt) ?? escapeHtml(alt)
            out.append("<img src=\"\(escapeHtml(src))\" alt=\"\(renderedAlt)\"\(titleAttr) />")
        case .htmlInline(let raw):
            out.append(gfm ? filterDisallowedRawHtml(raw) : raw)
        case .br:
            out.append("<br />\n")
        }
    }
    return out
}

private let checkedCheckboxHtml = "<input checked=\"\" disabled=\"\" type=\"checkbox\"> "
private let uncheckedCheckboxHtml = "<input disabled=\"\" type=\"checkbox\"> "

private final class HtmlWriter {
    private var parts: [String] = []
    private var lastOut: String = "\n"
    let options: HtmlRenderOptions?

    init(options: HtmlRenderOptions?) {
        self.options = options
    }

    var buffer: String {
        parts.joined()
    }

    func out(_ s: String) {
        parts.append(s)
        lastOut = s
    }

    func cr() {
        if lastOut != "\n" { out("\n") }
    }

    func block(_ kind: BlockKind, tight: Bool, prefix: String = "") {
        let gfm = options?.gfm ?? false
        switch kind {
        case .paragraph(let inlines):
            if tight {
                out(prefix + renderInlinesToHtml(inlines, options: options))
            } else {
                cr()
                out("<p>\(prefix)\(renderInlinesToHtml(inlines, options: options))</p>")
                cr()
            }
        case .heading(let level, let inlines):
            cr()
            out("<h\(level.rawValue)>\(renderInlinesToHtml(inlines, options: options))</h\(level.rawValue)>")
            cr()
        case .code(let language, _, let source, let htmlLiteral, _, _, let complete):
            var cls = ""
            if let language, !language.isEmpty {
                let escaped = escapeHtml(language)
                let className = escaped.hasPrefix("language-") ? escaped : "language-\(escaped)"
                cls = " class=\"\(className)\""
            }
            let defaultBody = !source.isEmpty ? (source.hasSuffix("\n") && !complete ? source : "\(source)\n") : ""
            let body = htmlLiteral ?? defaultBody
            cr()
            out("<pre><code\(cls)>\(escapeHtml(body))</code></pre>")
            cr()
        case .mermaid(let source, let htmlLiteral, let complete):
            let defaultBody = !source.isEmpty ? (source.hasSuffix("\n") && !complete ? source : "\(source)\n") : ""
            let body = htmlLiteral ?? defaultBody
            cr()
            out("<pre><code class=\"language-mermaid\">\(escapeHtml(body))</code></pre>")
            cr()
        case .math(let source, let delimiter, _):
            cr()
            out("<div class=\"math-block\" data-math-delimiter=\"\(delimiter.rawValue)\">\(escapeHtml(source))</div>")
            cr()
        case .blockquote(let blocks):
            cr()
            out("<blockquote>")
            cr()
            for child in blocks { block(child, tight: false) }
            cr()
            out("</blockquote>")
            cr()
        case .list(let ordered, _, let start, let isTight, let items):
            let tag = ordered ? "ol" : "ul"
            let startAttr = (ordered && start != nil && start != 1) ? " start=\"\(start!)\"" : ""
            cr()
            out("<\(tag)\(startAttr)>")
            cr()
            for it in items { item(it, tight: isTight) }
            cr()
            out("</\(tag)>")
            cr()
        case .table(let align, let headers, let rows):
            cr()
            var tableOut = "<table>\n<thead>\n<tr>\n"
            for c in 0..<headers.count {
                let colAlign = c < align.count ? align[c] : nil
                let alignAttr = colAlign.map { " align=\"\($0.rawValue)\"" } ?? ""
                tableOut.append("<th\(alignAttr)>\(renderInlinesToHtml(headers[c], options: options))</th>\n")
            }
            tableOut.append("</tr>\n</thead>\n")
            if !rows.isEmpty {
                tableOut.append("<tbody>\n")
                for row in rows {
                    tableOut.append("<tr>\n")
                    for c in 0..<headers.count {
                        let colAlign = c < align.count ? align[c] : nil
                        let alignAttr = colAlign.map { " align=\"\($0.rawValue)\"" } ?? ""
                        let cell = c < row.count ? row[c] : []
                        tableOut.append("<td\(alignAttr)>\(renderInlinesToHtml(cell, options: options))</td>\n")
                    }
                    tableOut.append("</tr>\n")
                }
                tableOut.append("</tbody>\n")
            }
            tableOut.append("</table>")
            out(tableOut)
            cr()
        case .htmlBlock(let raw):
            cr()
            out(gfm ? filterDisallowedRawHtml(raw) : raw)
            cr()
        case .hr:
            cr()
            out("<hr />")
            cr()
        case .group(let blocks):
            for child in blocks { block(child, tight: false) }
        }
    }

    func item(_ item: ListItemNode, tight: Bool) {
        let checkbox: String
        if item.checked == true {
            checkbox = checkedCheckboxHtml
        } else if item.checked == false {
            checkbox = uncheckedCheckboxHtml
        } else {
            checkbox = ""
        }
        out("<li>")
        for i in 0..<item.blocks.count {
            block(item.blocks[i], tight: tight, prefix: i == 0 ? checkbox : "")
        }
        if item.blocks.isEmpty && !checkbox.isEmpty {
            out(String(checkbox.dropLast()))
        }
        out("</li>")
        cr()
    }
}

/// Renders a single `BlockKind` AST node into CommonMark/GFM HTML.
// parity: patchmark/src/html.ts#renderBlockKindToHtml [status=implemented hash=4ac519b54c44]
public func renderBlockKindToHtml(_ kind: BlockKind, options: HtmlRenderOptions? = nil) -> String {
    let writer = HtmlWriter(options: options)
    writer.block(kind, tight: false)
    return writer.buffer
}

/// Renders an array of emitted `MarkdownBlock`s into concatenated HTML.
// parity: patchmark/src/html.ts#renderBlocksToHtml [status=implemented hash=a2516756f258]
public func renderBlocksToHtml(_ blocks: [MarkdownBlock], options: HtmlRenderOptions? = nil) -> String {
    var out = ""
    for b in blocks {
        if let options {
            out.append(renderBlockKindToHtml(b.kind, options: options))
        } else {
            out.append(b.html ?? renderBlockKindToHtml(b.kind))
        }
    }
    return out
}
