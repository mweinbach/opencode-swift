import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout

// MARK: - Markdown Supporting Types

/// Visual style preset for Markdown GFM tables.
// parity: core/src/renderables/Markdown.ts#MarkdownTableStyle [status=implemented hash=4d8d1e31b89d]
public enum MarkdownTableStyle: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case grid
    case columns
}

/// Optional parser extensions supported by `MarkdownRenderable`.
public enum MarkdownExtension: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case math
}

/// Configuration options for internally rendered Markdown GFM tables (`TextTableRenderable`).
// parity: core/src/renderables/Markdown.ts#MarkdownTableOptions [status=implemented hash=e6be02c1c836]
public struct MarkdownTableOptions: Equatable, Hashable, Sendable {
    public var style: MarkdownTableStyle?
    public var widthMode: TextTableColumnWidthMode?
    public var columnFitter: TextTableColumnFitter?
    public var wrapMode: TextWrapMode?
    public var cellPadding: Int?
    public var cellPaddingX: Int?
    public var cellPaddingY: Int?
    public var borders: Bool?
    public var outerBorder: Bool?
    public var borderStyle: BorderStyle?
    public var borderColor: Color?
    public var selectable: Bool?

    public init(
        style: MarkdownTableStyle? = nil,
        widthMode: TextTableColumnWidthMode? = nil,
        columnFitter: TextTableColumnFitter? = nil,
        wrapMode: TextWrapMode? = nil,
        cellPadding: Int? = nil,
        cellPaddingX: Int? = nil,
        cellPaddingY: Int? = nil,
        borders: Bool? = nil,
        outerBorder: Bool? = nil,
        borderStyle: BorderStyle? = nil,
        borderColor: Color? = nil,
        selectable: Bool? = nil
    ) {
        self.style = style
        self.widthMode = widthMode
        self.columnFitter = columnFitter
        self.wrapMode = wrapMode
        self.cellPadding = cellPadding
        self.cellPaddingX = cellPaddingX
        self.cellPaddingY = cellPaddingY
        self.borders = borders
        self.outerBorder = outerBorder
        self.borderStyle = borderStyle
        self.borderColor = borderColor
        self.selectable = selectable
    }
}

/// One inline span of a prose block or table cell passed to `MarkdownInlineHook`.
// parity: core/src/renderables/Markdown.ts#MarkdownInlineSpan [status=implemented hash=c7a9e2f0d40d]
public struct MarkdownInlineSpan: Equatable, Hashable, Sendable {
    public var text: String
    public var fg: RGBA?
    public var bg: RGBA?
    public var attributes: UInt32?
    public var link: TextChunkLink?
    public var code: Bool
    public var math: String?
    public var target: String?

    public init(
        text: String,
        fg: RGBA? = nil,
        bg: RGBA? = nil,
        attributes: UInt32? = nil,
        link: TextChunkLink? = nil,
        code: Bool = false,
        math: String? = nil,
        target: String? = nil
    ) {
        self.text = text
        self.fg = fg
        self.bg = bg
        self.attributes = attributes
        self.link = link
        self.code = code
        self.math = math
        self.target = target
    }
}

/// Context provided to `MarkdownInlineHook` when transforming a prose block or table cell.
// parity: core/src/renderables/Markdown.ts#MarkdownInlineContext [status=implemented hash=d4910e16d3b2]
public struct MarkdownInlineContext: Sendable {
    public var source: String
    public var conceal: Bool
    public var syntaxStyle: SyntaxStyle
    public var tableCell: Bool

    public init(source: String, conceal: Bool, syntaxStyle: SyntaxStyle, tableCell: Bool) {
        self.source = source
        self.conceal = conceal
        self.syntaxStyle = syntaxStyle
        self.tableCell = tableCell
    }
}

/// Synchronous hook for rewriting inline spans of paragraphs, headings, and table cells.
// parity: core/src/renderables/Markdown.ts#MarkdownInlineHook [status=implemented hash=c7cac927d39a]
public typealias MarkdownInlineHook = (
    _ spans: [MarkdownInlineSpan],
    _ context: MarkdownInlineContext
) -> [MarkdownInlineSpan]

/// Context passed to custom block renderers (`renderNode` / `renderBlock`).
// parity: core/src/renderables/Markdown.ts#RenderNodeContext [status=implemented hash=bd72f9a27153]
public struct MarkdownRenderNodeContext {
    public var syntaxStyle: SyntaxStyle
    public var conceal: Bool
    public var concealCode: Bool
    public var highlighter: (any SyntaxHighlighter)?
    public var defaultRender: () -> Renderable?

    public init(
        syntaxStyle: SyntaxStyle,
        conceal: Bool,
        concealCode: Bool,
        highlighter: (any SyntaxHighlighter)? = nil,
        defaultRender: @escaping () -> Renderable?
    ) {
        self.syntaxStyle = syntaxStyle
        self.conceal = conceal
        self.concealCode = concealCode
        self.highlighter = highlighter
        self.defaultRender = defaultRender
    }
}

/// Upstream name alias for `MarkdownRenderNodeContext`.
public typealias RenderNodeContext = MarkdownRenderNodeContext

/// Read-only view of a Markdown block passed to `renderNode` / `renderBlock` hooks.
/// (The underlying parsed AST enum is `MarkdownBlock` in `MarkdownParser.swift`.)
// parity: core/src/renderables/Markdown.ts#MarkdownBlock [status=adapted hash=25c42383fc10]
public struct MarkdownBlockView: Equatable, Hashable, Sendable {
    public var index: Int
    public var kind: MarkdownBlockKind
    public var block: MarkdownBlock
    public var level: Int?
    public var ordered: Bool?
    public var start: Int?
    public var checked: Bool?
    public var lang: String?
    public var info: String?
    public var closed: Bool?
    public var raw: String
    public var text: String
    public var children: [MarkdownBlockView]

    public init(
        index: Int,
        kind: MarkdownBlockKind,
        block: MarkdownBlock,
        level: Int? = nil,
        ordered: Bool? = nil,
        start: Int? = nil,
        checked: Bool? = nil,
        lang: String? = nil,
        info: String? = nil,
        closed: Bool? = nil,
        raw: String = "",
        text: String = "",
        children: [MarkdownBlockView] = []
    ) {
        self.index = index
        self.kind = kind
        self.block = block
        self.level = level
        self.ordered = ordered
        self.start = start
        self.checked = checked
        self.lang = lang
        self.info = info
        self.closed = closed
        self.raw = raw
        self.text = text
        self.children = children
    }
}

/// Specialized view of a fenced, indented, or display-math code block.
// parity: core/src/renderables/Markdown.ts#MarkdownCodeBlock [status=implemented hash=20b060228b72]
public struct MarkdownCodeBlock: Equatable, Hashable, Sendable {
    public var index: Int
    public var kind: MarkdownBlockKind { .code }
    public var lang: String
    public var info: String
    public var closed: Bool
    public var raw: String
    public var text: String
    public var isMath: Bool

    public init(
        index: Int,
        lang: String,
        info: String,
        closed: Bool,
        raw: String,
        text: String,
        isMath: Bool = false
    ) {
        self.index = index
        self.lang = lang
        self.info = info
        self.closed = closed
        self.raw = raw
        self.text = text
        self.isMath = isMath
    }
}

/// Custom renderer function for a specific fenced code block language.
// parity: core/src/renderables/Markdown.ts#MarkdownCodeBlockRenderer [status=implemented hash=8d3bf77c2b72]
public typealias MarkdownCodeBlockRenderer = (
    _ block: MarkdownCodeBlock,
    _ context: MarkdownRenderNodeContext
) -> Renderable?

/// Dictionary mapping canonical language names to custom code-block renderers.
// parity: core/src/renderables/Markdown.ts#MarkdownCodeBlockRendererMap [status=implemented hash=24a1ea3dac4a]
public typealias MarkdownCodeBlockRendererMap = [String: MarkdownCodeBlockRenderer]

/// Block renderer callback accepted by `MarkdownOptions.renderNode` / `renderBlock`.
public typealias MarkdownRenderBlockCallback = (
    _ block: MarkdownBlockView,
    _ context: MarkdownRenderNodeContext
) -> Renderable?

/// Builds a `MarkdownRenderBlockCallback` that dispatches code blocks by normalized language
/// (`infoStringToFiletype`) to language-specific renderers.
// parity: core/src/renderables/Markdown.ts#createMarkdownCodeBlockRenderer [status=implemented hash=76e5d9be3286]
public func createMarkdownCodeBlockRenderer(
    _ renderers: MarkdownCodeBlockRendererMap
) -> MarkdownRenderBlockCallback {
    return { block, context in
        guard block.kind == .code else { return nil }
        guard let language = infoStringToFiletype(block.lang ?? ""), let renderer = renderers[language] else {
            return nil
        }
        let isMath: Bool
        if case .codeBlock(_, _, _, let math) = block.block {
            isMath = math
        } else {
            isMath = false
        }
        let codeBlock = MarkdownCodeBlock(
            index: block.index,
            lang: block.lang ?? "",
            info: block.info ?? "",
            closed: block.closed ?? true,
            raw: block.raw,
            text: block.text,
            isMath: isMath
        )
        return renderer(codeBlock, context)
    }
}

// MARK: - MarkdownOptions

/// The text of a task item's box with conceal on.
// parity: core/src/renderables/Markdown.ts#MarkdownTaskMarkers [status=implemented hash=8aed4165d6a9]
public struct MarkdownTaskMarkers: Equatable, Hashable, Sendable {
    public var unchecked: String
    public var checked: String

    public init(unchecked: String, checked: String) {
        self.unchecked = unchecked
        self.checked = checked
    }

    /// `☐` and `☑`, the boxes a task item shows with conceal on unless `taskMarkers` says otherwise.
    public static let `default` = MarkdownTaskMarkers(unchecked: "☐", checked: "☑")
    /// The source's boxes, which items show with conceal off.
    static let source = MarkdownTaskMarkers(unchecked: "[ ]", checked: "[x]")
}

/// Configuration options for `MarkdownRenderable`.
// parity: core/src/renderables/Markdown.ts#MarkdownOptions [status=implemented hash=43030af279c9]
public struct MarkdownOptions {
    public var base: RenderableOptions
    public var content: String?
    public var syntaxStyle: SyntaxStyle
    public var fg: Color?
    public var bg: Color?
    /// Controls concealment for Markdown syntax markers in prose blocks (headings, emphasis, links, task boxes).
    public var conceal: Bool?
    /// Controls concealment inside fenced code blocks rendered by `CodeRenderable`.
    public var concealCode: Bool?
    /// The box a task item shows with `conceal` on: `☐` and `☑` by default. `{ unchecked: "[ ]", checked: "[x]" }`
    /// shows ASCII boxes. Without conceal, items show the source's `[ ]` or `[x]`.
    public var taskMarkers: MarkdownTaskMarkers?
    /// Syntax highlighter used for fenced code blocks (defaults to `BuiltInSyntaxHighlighter.shared`).
    public var highlighter: (any SyntaxHighlighter)?
    /// Whether content is actively streaming (enables incremental block reuse and open-fence tracking).
    public var streaming: Bool?
    /// Options for internally rendered GFM tables (`TextTableRenderable`).
    public var tableOptions: MarkdownTableOptions?
    /// Custom block renderer override hook (`renderNode` / `renderBlock`).
    public var renderNode: MarkdownRenderBlockCallback?
    /// Optional inline span rewriter for paragraphs, headings, and table cells.
    public var inlineHook: MarkdownInlineHook?
    /// Optional substring filter limiting which blocks invoke `inlineHook`.
    public var inlineHookFilter: [String]?
    /// Optional parser extensions (e.g. `[.math]`).
    public var extensions: [MarkdownExtension]?

    public init(
        id: String? = nil,
        content: String? = nil,
        syntaxStyle: SyntaxStyle = SyntaxStyle.create(),
        fg: Color? = nil,
        bg: Color? = nil,
        conceal: Bool? = nil,
        concealCode: Bool? = nil,
        taskMarkers: MarkdownTaskMarkers? = nil,
        highlighter: (any SyntaxHighlighter)? = nil,
        streaming: Bool? = nil,
        tableOptions: MarkdownTableOptions? = nil,
        renderNode: MarkdownRenderBlockCallback? = nil,
        renderBlock: MarkdownRenderBlockCallback? = nil,
        inlineHook: MarkdownInlineHook? = nil,
        inlineHookFilter: [String]? = nil,
        extensions: [MarkdownExtension]? = nil,
        width: FlexValue? = nil,
        height: FlexValue? = nil,
        minWidth: FlexValue? = nil,
        maxWidth: FlexValue? = nil,
        minHeight: FlexValue? = nil,
        maxHeight: FlexValue? = nil,
        flexGrow: Float? = nil,
        flexShrink: Float? = nil,
        position: PositionType? = nil,
        top: FlexValue? = nil,
        right: FlexValue? = nil,
        bottom: FlexValue? = nil,
        left: FlexValue? = nil,
        margin: FlexValue? = nil,
        padding: FlexValue? = nil,
        overflow: Overflow? = nil,
        zIndex: Int? = nil,
        visible: Bool? = nil,
        buffered: Bool? = nil
    ) {
        self.base = RenderableOptions(
            id: id,
            width: width,
            height: height,
            minWidth: minWidth,
            maxWidth: maxWidth,
            minHeight: minHeight,
            maxHeight: maxHeight,
            flexGrow: flexGrow,
            flexShrink: flexShrink,
            position: position,
            top: top,
            right: right,
            bottom: bottom,
            left: left,
            margin: margin,
            padding: padding,
            overflow: overflow,
            zIndex: zIndex,
            visible: visible,
            buffered: buffered
        )
        self.content = content
        self.syntaxStyle = syntaxStyle
        self.fg = fg
        self.bg = bg
        self.conceal = conceal
        self.concealCode = concealCode
        self.taskMarkers = taskMarkers
        self.highlighter = highlighter
        self.streaming = streaming
        self.tableOptions = tableOptions
        self.renderNode = renderNode ?? renderBlock
        self.inlineHook = inlineHook
        self.inlineHookFilter = inlineHookFilter
        self.extensions = extensions
    }

    public init(
        base: RenderableOptions,
        content: String? = nil,
        syntaxStyle: SyntaxStyle = SyntaxStyle.create(),
        fg: Color? = nil,
        bg: Color? = nil,
        conceal: Bool? = nil,
        concealCode: Bool? = nil,
        taskMarkers: MarkdownTaskMarkers? = nil,
        highlighter: (any SyntaxHighlighter)? = nil,
        streaming: Bool? = nil,
        tableOptions: MarkdownTableOptions? = nil,
        renderNode: MarkdownRenderBlockCallback? = nil,
        renderBlock: MarkdownRenderBlockCallback? = nil,
        inlineHook: MarkdownInlineHook? = nil,
        inlineHookFilter: [String]? = nil,
        extensions: [MarkdownExtension]? = nil
    ) {
        self.base = base
        self.content = content
        self.syntaxStyle = syntaxStyle
        self.fg = fg
        self.bg = bg
        self.conceal = conceal
        self.concealCode = concealCode
        self.taskMarkers = taskMarkers
        self.highlighter = highlighter
        self.streaming = streaming
        self.tableOptions = tableOptions
        self.renderNode = renderNode ?? renderBlock
        self.inlineHook = inlineHook
        self.inlineHookFilter = inlineHookFilter
        self.extensions = extensions
    }
}

// MARK: - Internal Style & Block Mounting Helpers

private struct ResolvedTableOptions {
    let columnWidthMode: TextTableColumnWidthMode
    let columnFitter: TextTableColumnFitter
    let wrapMode: TextWrapMode
    let cellPaddingX: Int
    let cellPaddingY: Int
    let columnGap: Int
    let border: Bool
    let outerBorder: Bool
    let showBorders: Bool
    let borderStyle: BorderStyle
    let borderColor: RGBA
    let fg: RGBA?
    let selectable: Bool
}

private struct InheritedTextStyle {
    var fg: RGBA?
    var bg: RGBA?
    var attributes: UInt32
}

private struct ClickTargetRange {
    let startByte: Int
    let endByte: Int
    let target: String
}

private struct MountedBlockSlot {
    var state: MarkdownBlockState
    var renderable: Renderable
    var defaultRenderable: Renderable?
    var isCustom: Bool
    var targets: [ClickTargetRange]
}

private func styleAttributes(_ style: StyleDefinition?) -> UInt32 {
    guard let style else { return TextAttributes.none }
    return createTextAttributes(
        bold: style.bold ?? false,
        italic: style.italic ?? false,
        underline: style.underline ?? false,
        dim: style.dim ?? false,
        strikethrough: style.strikethrough ?? false
    )
}

private func mergeInherited(_ base: InheritedTextStyle, with style: StyleDefinition?) -> InheritedTextStyle {
    guard let style else { return base }
    return InheritedTextStyle(
        fg: style.fg ?? base.fg,
        bg: style.bg ?? base.bg,
        attributes: base.attributes | styleAttributes(style)
    )
}

private func stripSingleTrailingNewline(_ s: String) -> String {
    if s.hasSuffix("\n") {
        return String(s.dropLast())
    }
    return s
}

private func plainTextOfInlines(_ inlines: [MarkdownInline]) -> String {
    var out = ""
    for node in inlines {
        switch node {
        case .text(let s), .codeSpan(let s), .rawHTML(let s), .math(let s):
            out.append(s)
        case .softBreak:
            out.append(" ")
        case .hardBreak:
            out.append("\n")
        case .emphasis(let children), .strong(let children), .strikethrough(let children):
            out.append(plainTextOfInlines(children))
        case .link(_, _, let children):
            out.append(plainTextOfInlines(children))
        case .image(let dest, _, let alt):
            let altText = plainTextOfInlines(alt)
            out.append(altText.isEmpty ? dest : altText)
        }
    }
    return out
}

private func extractLanguageToken(from info: String?) -> String {
    guard let info else { return "" }
    let trimmed = info.drop { $0.isWhitespace }
    let firstWord = trimmed.prefix { !$0.isWhitespace }
    return String(firstWord)
}

private func isDescendant(_ inner: Renderable, of outer: Renderable) -> Bool {
    var current: Renderable? = inner
    while let node = current {
        if node === outer { return true }
        current = node.parent
    }
    return false
}

// MARK: - MarkdownRenderable

/// Full-featured CommonMark + GFM Markdown renderable backed by `StreamingMarkdownDocument`
/// and `MarkdownParser`. Composes `TextRenderable`, `BoxRenderable`, `CodeRenderable`, and
/// `TextTableRenderable` with incremental streaming block reuse, inline concealment,
/// OSC 8 hyperlinks, syntax-highlighted code fences, and custom `renderNode` overrides.
// parity: core/src/renderables/Markdown.ts#MarkdownRenderable [status=implemented hash=d461833341ef]
open class MarkdownRenderable: Renderable, @unchecked Sendable {
    /// Entry returned by `MarkdownRenderable.blocks` summarizing each mounted top-level block.
    public struct RenderedBlockEntry {
        public let kind: MarkdownBlockKind
        public let renderable: Renderable?

        public init(kind: MarkdownBlockKind, renderable: Renderable?) {
            self.kind = kind
            self.renderable = renderable
        }
    }

    private let _doc: StreamingMarkdownDocument
    private var _slots: [MountedBlockSlot] = []

    private var _syntaxStyle: SyntaxStyle
    private var _fg: RGBA?
    private var _bg: RGBA?
    private var _conceal: Bool
    private var _concealCode: Bool
    private var _taskMarkers: MarkdownTaskMarkers
    private var _highlighter: (any SyntaxHighlighter)?
    private var _streaming: Bool
    private var _tableOptions: MarkdownTableOptions?
    private var _renderNode: MarkdownRenderBlockCallback?
    private var _inlineHook: MarkdownInlineHook?
    private var _inlineHookFilter: [String]?
    private var _extensions: [MarkdownExtension]
    private var _styleDirty: Bool = false

    public init(ctx: any RenderContext, options: MarkdownOptions = MarkdownOptions()) {
        self._syntaxStyle = options.syntaxStyle
        self._fg = options.fg.map { RGBA.clone($0.resolved()) }
        self._bg = options.bg.map { RGBA.clone($0.resolved()) }
        self._conceal = options.conceal ?? true
        self._concealCode = options.concealCode ?? false
        self._taskMarkers = options.taskMarkers ?? .default
        self._highlighter = options.highlighter
        self._streaming = options.streaming ?? false
        self._tableOptions = options.tableOptions
        self._renderNode = options.renderNode
        self._inlineHook = options.inlineHook
        self._inlineHookFilter = options.inlineHookFilter
        self._extensions = options.extensions ?? []

        let parseOpts = MarkdownParseOptions(
            enableGFM: true,
            enableMath: self._extensions.contains(.math)
        )
        self._doc = StreamingMarkdownDocument(options: parseOpts)

        var baseOptions = options.base
        baseOptions.flexDirection = .column
        if baseOptions.flexShrink == nil {
            baseOptions.flexShrink = 0
        }
        if baseOptions.rowGap == nil && baseOptions.gap == nil {
            baseOptions.rowGap = .point(1)
        }
        super.init(ctx: ctx, options: baseOptions)

        setBuiltinLifecyclePass { [weak self] in
            self?.rerenderDirtyStyles()
        }

        let initialContent = options.content ?? ""
        if !initialContent.isEmpty || !self._streaming {
            let changes = self._doc.write(initialContent, streaming: self._streaming)
            apply(changes)
        }
    }

    // MARK: - Public Properties

    // parity: core/src/renderables/Markdown.ts#MarkdownRenderable.content [status=implemented hash=d3f8c7b5d2bc]
    public var content: String {
        get { _doc.content }
        set {
            guard !isDestroyed, newValue != _doc.content else { return }
            let changes = _doc.write(newValue, streaming: _streaming)
            apply(changes)
            requestRender()
        }
    }

    // parity: core/src/renderables/Markdown.ts#MarkdownRenderable.syntaxStyle [status=implemented hash=8bbbc920cf40]
    public var syntaxStyle: SyntaxStyle {
        get { _syntaxStyle }
        set {
            guard _syntaxStyle !== newValue else { return }
            _syntaxStyle = newValue
            markStyleDirty()
            restyleAll()
        }
    }

    /// Syntax highlighter used for fenced code blocks (defaults to `BuiltInSyntaxHighlighter.shared`).
    // parity: core/src/renderables/Markdown.ts#MarkdownRenderable.treeSitterClient [status=adapted hash=92ef7f9b83d2]
    public var highlighter: (any SyntaxHighlighter)? {
        get { _highlighter }
        set {
            _highlighter = newValue
            let resolved: any SyntaxHighlighter = newValue ?? BuiltInSyntaxHighlighter.shared
            for slot in _slots {
                propagateHighlighter(resolved, in: slot.renderable)
            }
            requestRender()
        }
    }

    // parity: core/src/renderables/Markdown.ts#MarkdownRenderable.fg [status=implemented hash=2bfb97aefe3c]
    public var fg: RGBA? {
        get { _fg.map(RGBA.clone) }
        set {
            let next = newValue.map(RGBA.clone)
            guard _fg != next else { return }
            _fg = next
            markStyleDirty()
            restyleAll()
        }
    }

    // parity: core/src/renderables/Markdown.ts#MarkdownRenderable.bg [status=implemented hash=668f5b6dcdd7]
    public var bg: RGBA? {
        get { _bg.map(RGBA.clone) }
        set {
            let next = newValue.map(RGBA.clone)
            guard _bg != next else { return }
            _bg = next
            markStyleDirty()
            restyleAll()
        }
    }

    // parity: core/src/renderables/Markdown.ts#MarkdownRenderable.conceal [status=implemented hash=2bc204954212]
    public var conceal: Bool {
        get { _conceal }
        set {
            guard _conceal != newValue else { return }
            _conceal = newValue
            restyleAll()
            requestRender()
        }
    }

    // parity: core/src/renderables/Markdown.ts#MarkdownRenderable.concealCode [status=implemented hash=ae0ad9c65604]
    public var concealCode: Bool {
        get { _concealCode }
        set {
            guard _concealCode != newValue else { return }
            _concealCode = newValue
            restyleAll()
            requestRender()
        }
    }

    /// The boxes task items show with conceal on; `nil` restores `☐` and `☑`. Items already on screen update, also
    /// while the document streams.
    // parity: core/src/renderables/Markdown.ts#MarkdownRenderable.taskMarkers [status=implemented hash=165e9598bfdc]
    public var taskMarkers: MarkdownTaskMarkers? {
        get { _taskMarkers }
        set {
            _taskMarkers = newValue ?? .default
            if isDestroyed { return }
            restyleAll()
            requestRender()
        }
    }

    // parity: core/src/renderables/Markdown.ts#MarkdownRenderable.streaming [status=implemented hash=a6ce28dc913c]
    public var streaming: Bool {
        get { _streaming }
        set {
            guard !isDestroyed, _streaming != newValue else { return }
            _streaming = newValue
            let changes = _doc.write(_doc.content, streaming: newValue)
            apply(changes)
            updateCodeStreamingState()
            requestRender()
        }
    }

    // parity: core/src/renderables/Markdown.ts#MarkdownRenderable.tableOptions [status=implemented hash=0edbdb0d3e35]
    public var tableOptions: MarkdownTableOptions? {
        get { _tableOptions }
        set {
            guard _tableOptions != newValue else { return }
            _tableOptions = newValue
            restyleAll()
            requestRender()
        }
    }

    /// Custom block renderer override hook (alias of `renderNode`).
    // parity: core/src/renderables/Markdown.ts#MarkdownRenderable.renderBlock [status=implemented hash=e0a7e6088dae]
    public var renderBlock: MarkdownRenderBlockCallback? {
        get { _renderNode }
        set {
            guard !isDestroyed else { return }
            _renderNode = newValue
            rebuild()
        }
    }

    /// Custom block renderer override hook.
    public var renderNode: MarkdownRenderBlockCallback? {
        get { _renderNode }
        set { renderBlock = newValue }
    }

    // parity: core/src/renderables/Markdown.ts#MarkdownRenderable.inlineHook [status=implemented hash=12f008f9b396]
    public var inlineHook: MarkdownInlineHook? {
        get { _inlineHook }
        set {
            _inlineHook = newValue
            restyleAll()
            requestRender()
        }
    }

    // parity: core/src/renderables/Markdown.ts#MarkdownRenderable.inlineHookFilter [status=implemented hash=f3cda2f1e39f]
    public var inlineHookFilter: [String]? {
        get { _inlineHookFilter }
        set {
            guard _inlineHookFilter != newValue else { return }
            _inlineHookFilter = newValue
            restyleAll()
            requestRender()
        }
    }

    // parity: core/src/renderables/Markdown.ts#MarkdownRenderable.extensions [status=implemented hash=ddbe0f6f093a]
    public var extensions: [MarkdownExtension] {
        get { _extensions }
        set {
            guard _extensions != newValue else { return }
            _extensions = newValue
            let parseOpts = MarkdownParseOptions(
                enableGFM: true,
                enableMath: newValue.contains(.math)
            )
            let changes = _doc.setOptions(parseOpts)
            apply(changes)
            requestRender()
        }
    }

    /// Mounted top-level blocks in document order along with their active renderables.
    // parity: core/src/renderables/Markdown.ts#MarkdownRenderable.blocks [status=implemented hash=0fcf77d1c392]
    public var blocks: [RenderedBlockEntry] {
        _slots.map { RenderedBlockEntry(kind: $0.state.kind, renderable: $0.renderable) }
    }

    /// Number of finalized top-level blocks tracked by the underlying `StreamingMarkdownDocument`.
    // parity: core/src/renderables/Markdown.ts#MarkdownRenderable.committedBlockCount [status=implemented hash=67060c4bdeca]
    public var committedBlockCount: Int {
        _doc.committed
    }

    /// Access to the underlying incremental `StreamingMarkdownDocument`.
    public var document: StreamingMarkdownDocument {
        _doc
    }

    // MARK: - Public Methods

    /// Re-runs `inlineHook` on mounted prose blocks and tables whose source satisfies `select`.
    // parity: core/src/renderables/Markdown.ts#MarkdownRenderable.rerunInlineHook [status=implemented hash=014b88ff1a00]
    public func rerunInlineHook(_ select: (String) -> Bool) {
        guard _inlineHook != nil else { return }
        for i in _slots.indices {
            let slot = _slots[i]
            guard !slot.isCustom else { continue }
            if select(slot.state.raw) {
                refreshSlotContent(at: i)
            }
        }
        requestRender()
    }

    /// Returns the inline-hook `target` associated with screen cell `(x, y)`, if any.
    // parity: core/src/renderables/Markdown.ts#MarkdownRenderable.targetAt [status=adapted hash=6748a37b702b]
    public func targetAt(x: Int, y: Int) -> String? {
        for slot in _slots where !slot.targets.isEmpty {
            guard let textNode = slot.defaultRenderable as? TextRenderable else { continue }
            let localX = x - textNode.screenX
            let localY = y - textNode.screenY
            guard localX >= 0 && localX < textNode.width && localY >= 0 && localY < textNode.height else {
                continue
            }
            let plain = textNode.plainText
            let lines = plain.split(separator: "\n", omittingEmptySubsequences: false)
            let lineIndex = localY + textNode.scrollY
            guard lineIndex >= 0 && lineIndex < lines.count else { continue }
            var byteOffset = 0
            for idx in 0..<lineIndex {
                byteOffset += lines[idx].utf8.count + 1
            }
            var col = 0
            for ch in lines[lineIndex] {
                if col >= localX { break }
                byteOffset += ch.utf8.count
                col += 1
            }
            if let hit = slot.targets.first(where: { byteOffset >= $0.startByte && byteOffset < $0.endByte }) {
                return hit.target
            }
        }
        return nil
    }

    /// Discards cached block renderables and rebuilds the entire scene tree from the current document.
    // parity: core/src/renderables/Markdown.ts#MarkdownRenderable.clearCache [status=implemented hash=5adcb765cec7]
    public func clearCache() {
        rebuild()
    }

    /// Re-applies all styles from `syntaxStyle`, `fg`, `bg`, `conceal`, and `tableOptions`.
    // parity: core/src/renderables/Markdown.ts#MarkdownRenderable.refreshStyles [status=implemented hash=f4fa94f30d11]
    public func refreshStyles() {
        _styleDirty = false
        restyleAll()
        requestRender()
    }

    // MARK: - Lifecycle & Cleanup

    open override func destroySelf() {
        _doc.destroy()
        _slots.removeAll()
        super.destroySelf()
    }

    private func markStyleDirty() {
        _styleDirty = true
        requestRender()
    }

    private func rerenderDirtyStyles() {
        guard _styleDirty && !isDestroyed else { return }
        _styleDirty = false
        restyleAll()
    }

    // MARK: - Incremental Scene Reconciliation

    private func apply(_ changes: MarkdownChanges) {
        guard !isDestroyed else { return }

        // 1. Remove and destroy trailing slots beyond `removedFrom`.
        if let from = changes.removedFrom, from < _slots.count {
            let removed = Array(_slots[from...])
            _slots.removeSubrange(from...)
            for slot in removed.reversed() {
                if slot.renderable.parent === self {
                    super.remove(slot.renderable)
                }
                if !slot.renderable.isDestroyed {
                    slot.renderable.destroyRecursively()
                }
            }
        }

        // 2. Keep unchanged prefix metadata synchronized without touching mounted renderables.
        let keptCount = min(changes.unchangedPrefixCount, _slots.count, _doc.blocks.count)
        for i in 0..<keptCount {
            _slots[i].state = _doc.blocks[i]
        }

        // 3. Apply only changed or newly added blocks.
        for blockState in changes.changed {
            let index = blockState.index
            if index < _slots.count {
                updateExistingSlot(at: index, with: blockState)
            } else {
                let slot = createSlot(for: blockState)
                _slots.append(slot)
                super.add(slot.renderable)
                _doc.bind(index, node: slot.renderable)
            }
        }
    }

    private func updateExistingSlot(at index: Int, with state: MarkdownBlockState) {
        let existing = _slots[index]

        // When a custom renderer is active or block kind changed incompatibly, rebuild this slot in place.
        if _renderNode != nil || existing.isCustom || !canUpdateInPlace(existing: existing, newState: state) {
            let replacement = createSlot(for: state)
            let oldRenderable = existing.renderable
            let childPosition = getChildren().firstIndex(where: { $0 === oldRenderable })

            if oldRenderable.parent === self {
                super.remove(oldRenderable)
            }
            if !oldRenderable.isDestroyed {
                oldRenderable.destroyRecursively()
            }

            _slots[index] = replacement
            super.add(replacement.renderable, index: childPosition)
            _doc.bind(index, node: replacement.renderable)
            return
        }

        // Compatible default renderable: mutate in place while keeping the same Renderable instance.
        var updated = existing
        updated.state = state
        applyBlockToExistingDefault(&updated)
        _slots[index] = updated
    }

    private func canUpdateInPlace(existing: MountedBlockSlot, newState: MarkdownBlockState) -> Bool {
        guard let def = existing.defaultRenderable, def === existing.renderable, !def.isDestroyed else {
            return false
        }
        switch (existing.state.block, newState.block) {
        case (.paragraph, .paragraph),
             (.heading, .heading),
             (.paragraph, .heading),
             (.heading, .paragraph),
             (.htmlBlock, .htmlBlock):
            return def is TextRenderable
        case (.codeBlock, .codeBlock):
            return def is CodeRenderable
        case (.table, .table):
            return def is TextTableRenderable
        case (.thematicBreak, .thematicBreak):
            return def is BoxRenderable
        default:
            return false
        }
    }

    private func applyBlockToExistingDefault(_ slot: inout MountedBlockSlot) {
        guard let def = slot.defaultRenderable else { return }
        let base = rootBaseStyle()
        switch slot.state.block {
        case .paragraph(let inlines):
            if let text = def as? TextRenderable {
                applyBaseTextStyle(base, to: text)
                let (styled, targets) = buildProseStyledText(
                    inlines: inlines,
                    baseStyle: base,
                    source: slot.state.raw,
                    headingLevel: nil
                )
                text.setContent(styled)
                slot.targets = targets
            }
        case .heading(let level, let inlines):
            if let text = def as? TextRenderable {
                applyBaseTextStyle(base, to: text)
                let (styled, targets) = buildProseStyledText(
                    inlines: inlines,
                    baseStyle: base,
                    source: slot.state.raw,
                    headingLevel: level
                )
                text.setContent(styled)
                slot.targets = targets
            }
        case .htmlBlock(let raw):
            if let text = def as? TextRenderable {
                applyBaseTextStyle(base, to: text)
                let style = mergeInherited(base, with: getStyle("markup.raw"))
                let chunk = TextChunk(text: raw, fg: style.fg, bg: style.bg, attributes: style.attributes)
                text.setContent(StyledText(chunks: [chunk]))
                slot.targets = []
            }
        case .codeBlock(let info, let literal, _, let isMath):
            if let code = def as? CodeRenderable {
                configureCodeRenderable(
                    code,
                    info: info,
                    literal: literal,
                    isMath: isMath,
                    isClosed: slot.state.isClosed
                )
            }
        case .table(let alignments, let header, let rows):
            if let table = def as? TextTableRenderable {
                configureTableRenderable(table, alignments: alignments, header: header, rows: rows)
            }
        case .thematicBreak:
            if let rule = def as? BoxRenderable {
                rule.borderColor = getStyle("conceal")?.fg ?? _fg ?? parseColor("#888888")
            }
        default:
            break
        }
    }

    private func rebuild() {
        for slot in _slots.reversed() {
            if slot.renderable.parent === self {
                super.remove(slot.renderable)
            }
            if !slot.renderable.isDestroyed {
                slot.renderable.destroyRecursively()
            }
        }
        _slots.removeAll()
        let allBlocks = _doc.blocks
        apply(MarkdownChanges(removedFrom: nil, changed: allBlocks, unchangedPrefixCount: 0))
        requestRender()
    }

    private func restyleAll() {
        guard !isDestroyed else { return }
        if _renderNode != nil {
            rebuild()
            return
        }
        for i in _slots.indices {
            refreshSlotContent(at: i)
        }
    }

    private func refreshSlotContent(at index: Int) {
        guard index >= 0 && index < _slots.count else { return }
        var slot = _slots[index]
        switch slot.state.block {
        case .paragraph, .heading, .htmlBlock, .codeBlock, .table, .thematicBreak:
            if !slot.isCustom {
                applyBlockToExistingDefault(&slot)
                _slots[index] = slot
                return
            }
        case .blockquote, .list:
            break
        }
        // Container blocks (quotes/lists) or custom nodes rebuild cleanly to reflect conceal/theme changes.
        updateExistingSlot(at: index, with: slot.state)
    }

    private func updateCodeStreamingState() {
        for slot in _slots {
            updateCodeStreamingRecursive(in: slot.renderable, isClosed: slot.state.isClosed)
        }
    }

    private func updateCodeStreamingRecursive(in node: Renderable, isClosed: Bool) {
        if let code = node as? CodeRenderable {
            code.streaming = _streaming
            code.drawUnstyledText = !_streaming || code.filetype == nil
            code.setStreamsDeltas(_streaming && !isClosed)
        }
        for child in node.getChildren() {
            updateCodeStreamingRecursive(in: child, isClosed: isClosed)
        }
    }

    private func propagateHighlighter(_ highlighter: any SyntaxHighlighter, in node: Renderable) {
        if let code = node as? CodeRenderable {
            code.highlighter = highlighter
        }
        for child in node.getChildren() {
            propagateHighlighter(highlighter, in: child)
        }
    }

    // MARK: - Block Construction

    private func createSlot(for state: MarkdownBlockState) -> MountedBlockSlot {
        let base = rootBaseStyle()
        var builtDefault: Renderable? = nil
        var targets: [ClickTargetRange] = []

        func buildDefaultOnce() -> Renderable? {
            if let existing = builtDefault { return existing }
            let result = buildBlockRenderable(
                block: state.block,
                idPrefix: "\(id)-block-\(state.index)",
                baseStyle: base,
                source: state.raw,
                isClosed: state.isClosed,
                blockIndex: state.index,
                allowCustomCodeOverride: false
            )
            builtDefault = result.renderable
            targets = result.targets
            return result.renderable
        }

        if let customHook = _renderNode {
            let blockView = makeBlockView(from: state)
            let context = MarkdownRenderNodeContext(
                syntaxStyle: _syntaxStyle,
                conceal: _conceal,
                concealCode: _concealCode,
                highlighter: _highlighter,
                defaultRender: { buildDefaultOnce() }
            )
            if let customRenderable = customHook(blockView, context) {
                let keptDefault: Renderable?
                if let def = builtDefault, isDescendant(def, of: customRenderable) {
                    keptDefault = def
                } else {
                    if let def = builtDefault, def.parent == nil, !def.isDestroyed {
                        def.destroyRecursively()
                    }
                    keptDefault = nil
                }
                return MountedBlockSlot(
                    state: state,
                    renderable: customRenderable,
                    defaultRenderable: keptDefault,
                    isCustom: true,
                    targets: targets
                )
            }
        }

        let def = buildDefaultOnce() ?? BoxRenderable(ctx: ctx, options: BoxOptions(id: "\(id)-block-\(state.index)-empty"))
        return MountedBlockSlot(
            state: state,
            renderable: def,
            defaultRenderable: def,
            isCustom: false,
            targets: targets
        )
    }

    private func buildBlockRenderable(
        block: MarkdownBlock,
        idPrefix: String,
        baseStyle: InheritedTextStyle,
        source: String,
        isClosed: Bool,
        blockIndex: Int,
        allowCustomCodeOverride: Bool
    ) -> (renderable: Renderable, targets: [ClickTargetRange]) {
        switch block {
        case .paragraph(let inlines):
            let text = TextRenderable(
                ctx: ctx,
                options: TextOptions(
                    id: idPrefix,
                    width: .percent(100),
                    flexShrink: 0,
                    fg: baseStyle.fg.map { .rgba($0) },
                    bg: baseStyle.bg.map { .rgba($0) },
                    attributes: baseStyle.attributes,
                    wrapMode: .word
                )
            )
            let (styled, targets) = buildProseStyledText(
                inlines: inlines,
                baseStyle: baseStyle,
                source: source,
                headingLevel: nil
            )
            text.setContent(styled)
            return (text, targets)

        case .heading(let level, let inlines):
            let text = TextRenderable(
                ctx: ctx,
                options: TextOptions(
                    id: idPrefix,
                    width: .percent(100),
                    flexShrink: 0,
                    fg: baseStyle.fg.map { .rgba($0) },
                    bg: baseStyle.bg.map { .rgba($0) },
                    attributes: baseStyle.attributes,
                    wrapMode: .word
                )
            )
            let (styled, targets) = buildProseStyledText(
                inlines: inlines,
                baseStyle: baseStyle,
                source: source,
                headingLevel: level
            )
            text.setContent(styled)
            return (text, targets)

        case .codeBlock(let info, let literal, _, let isMath):
            var builtCode: CodeRenderable? = nil
            func makeDefaultCode() -> CodeRenderable {
                if let existing = builtCode { return existing }
                let code = CodeRenderable(
                    ctx: ctx,
                    options: CodeOptions(
                        id: idPrefix,
                        syntaxStyle: _syntaxStyle,
                        highlighter: _highlighter,
                        width: .percent(100),
                        flexShrink: 0,
                        wrapMode: .word
                    )
                )
                configureCodeRenderable(code, info: info, literal: literal, isMath: isMath, isClosed: isClosed)
                builtCode = code
                return code
            }

            if allowCustomCodeOverride, let customHook = _renderNode {
                let lang = isMath ? "math" : extractLanguageToken(from: info)
                let view = MarkdownBlockView(
                    index: blockIndex,
                    kind: .code,
                    block: block,
                    lang: lang,
                    info: info ?? "",
                    closed: isClosed,
                    raw: source,
                    text: stripSingleTrailingNewline(literal)
                )
                let context = MarkdownRenderNodeContext(
                    syntaxStyle: _syntaxStyle,
                    conceal: _conceal,
                    concealCode: _concealCode,
                    highlighter: _highlighter,
                    defaultRender: { makeDefaultCode() }
                )
                if let custom = customHook(view, context) {
                    if let def = builtCode, !isDescendant(def, of: custom), def.parent == nil, !def.isDestroyed {
                        def.destroyRecursively()
                    }
                    return (custom, [])
                }
            }

            return (makeDefaultCode(), [])

        case .htmlBlock(let raw):
            let style = mergeInherited(baseStyle, with: getStyle("markup.raw"))
            let text = TextRenderable(
                ctx: ctx,
                options: TextOptions(
                    id: idPrefix,
                    content: .styled(StyledText(chunks: [
                        TextChunk(text: raw, fg: style.fg, bg: style.bg, attributes: style.attributes)
                    ])),
                    width: .percent(100),
                    flexShrink: 0,
                    fg: baseStyle.fg.map { .rgba($0) },
                    bg: baseStyle.bg.map { .rgba($0) },
                    wrapMode: .word
                )
            )
            return (text, [])

        case .thematicBreak:
            let borderColor = getStyle("conceal")?.fg ?? _fg ?? parseColor("#888888")
            let rule = BoxRenderable(
                ctx: ctx,
                options: BoxOptions(
                    id: idPrefix,
                    width: .percent(100),
                    height: .point(1),
                    flexShrink: 0,
                    border: .sides([.top]),
                    borderColor: .rgba(borderColor),
                    shouldFill: false
                )
            )
            return (rule, [])

        case .blockquote(let children):
            let borderColor = getStyle("conceal")?.fg ?? getStyle("default")?.fg ?? _fg ?? parseColor("#FFFFFF")
            let quoteBox = BoxRenderable(
                ctx: ctx,
                options: BoxOptions(
                    id: idPrefix,
                    width: .percent(100),
                    minHeight: .point(1),
                    flexShrink: 0,
                    flexDirection: .column,
                    paddingLeft: .point(1),
                    rowGap: .point(1),
                    border: .sides([.left]),
                    borderColor: .rgba(borderColor),
                    shouldFill: false
                )
            )
            let quoteStyle = mergeInherited(baseStyle, with: getStyle("markup.quote"))
            for (childIdx, childBlock) in children.enumerated() {
                let built = buildBlockRenderable(
                    block: childBlock,
                    idPrefix: "\(idPrefix)-q\(childIdx)",
                    baseStyle: quoteStyle,
                    source: source,
                    isClosed: isClosed,
                    blockIndex: blockIndex,
                    allowCustomCodeOverride: true
                )
                quoteBox.add(built.renderable)
            }
            return (quoteBox, [])

        case .list(let ordered, let start, let tight, let items):
            let gap = tight ? 0 : 1
            let listBox = BoxRenderable(
                ctx: ctx,
                options: BoxOptions(
                    id: idPrefix,
                    width: .percent(100),
                    flexShrink: 0,
                    flexDirection: .column,
                    rowGap: .point(Float(gap)),
                    shouldFill: false
                )
            )

            let maxOrdinal = start + max(0, items.count - 1)
            let markerWidth = ordered ? String(maxOrdinal).count + 1 : 1
            let markerStyle = mergeInherited(baseStyle, with: getStyle("markup.list"))

            for (itemIdx, item) in items.enumerated() {
                let itemId = "\(idPrefix)-item-\(itemIdx)"
                let row = BoxRenderable(
                    ctx: ctx,
                    options: BoxOptions(
                        id: itemId,
                        width: .percent(100),
                        flexShrink: 0,
                        flexDirection: .row,
                        shouldFill: false
                    )
                )

                let box = _conceal ? _taskMarkers : MarkdownTaskMarkers.source
                let taskSuffix = item.taskChecked.map { checked in " \(checked ? box.checked : box.unchecked)" } ?? ""

                let prefixStr: String
                if ordered {
                    let rawNum = "\(start + itemIdx)."
                    let padCount = max(0, markerWidth - rawNum.count)
                    prefixStr = String(repeating: " ", count: padCount) + rawNum
                } else {
                    prefixStr = "-"
                }
                let markerLabel = prefixStr + taskSuffix + " "

                let marker = TextRenderable(
                    ctx: ctx,
                    options: TextOptions(
                        id: "\(itemId)-marker",
                        content: .styled(StyledText(chunks: [
                            TextChunk(
                                text: markerLabel,
                                fg: markerStyle.fg,
                                bg: markerStyle.bg,
                                attributes: markerStyle.attributes
                            )
                        ])),
                        flexShrink: 0,
                        wrapMode: TextWrapMode.none
                    )
                )

                let contentBox = BoxRenderable(
                    ctx: ctx,
                    options: BoxOptions(
                        id: "\(itemId)-content",
                        flexGrow: 1,
                        flexShrink: 1,
                        flexDirection: .column,
                        rowGap: .point(Float(gap)),
                        shouldFill: false
                    )
                )

                for (subIdx, subBlock) in item.blocks.enumerated() {
                    let built = buildBlockRenderable(
                        block: subBlock,
                        idPrefix: "\(itemId)-b\(subIdx)",
                        baseStyle: baseStyle,
                        source: source,
                        isClosed: isClosed,
                        blockIndex: blockIndex,
                        allowCustomCodeOverride: true
                    )
                    contentBox.add(built.renderable)
                }

                row.add(marker)
                row.add(contentBox)
                listBox.add(row)
            }

            return (listBox, [])

        case .table(let alignments, let header, let rows):
            let table = TextTableRenderable(
                ctx: ctx,
                options: TextTableOptions(
                    id: idPrefix,
                    width: .percent(100),
                    flexShrink: 0,
                    content: []
                )
            )
            configureTableRenderable(table, alignments: alignments, header: header, rows: rows)
            return (table, [])
        }
    }

    // MARK: - Code Block & Table Configuration

    private func configureCodeRenderable(
        _ code: CodeRenderable,
        info: String?,
        literal: String,
        isMath: Bool,
        isClosed: Bool
    ) {
        let langToken = extractLanguageToken(from: info)
        code.filetype = isMath ? nil : (langToken.isEmpty ? nil : infoStringToFiletype(langToken))
        code.syntaxStyle = _syntaxStyle
        if let highlighter = _highlighter {
            code.highlighter = highlighter
        }
        if let fg = _fg {
            code.fg = fg
        }
        if let bg = _bg {
            code.bg = bg
        }
        code.conceal = _concealCode
        code.drawUnstyledText = isMath || !_streaming
        code.streaming = _streaming
        code.setStreamsDeltas(_streaming && !isClosed)
        code.content = stripSingleTrailingNewline(literal)
    }

    private func resolveTableOptions() -> ResolvedTableOptions {
        let style = _tableOptions?.style ?? .grid
        let borders = _tableOptions?.borders ?? (style == .grid)
        let cellPaddingX = _tableOptions?.cellPaddingX ?? _tableOptions?.cellPadding ?? 0
        let cellPaddingY = _tableOptions?.cellPaddingY ?? _tableOptions?.cellPadding ?? 0
        let defaultBorderColor = getStyle("conceal")?.fg ?? parseColor("#888888")

        return ResolvedTableOptions(
            columnWidthMode: _tableOptions?.widthMode ?? (style == .columns ? .content : .full),
            columnFitter: _tableOptions?.columnFitter ?? .proportional,
            wrapMode: _tableOptions?.wrapMode ?? .word,
            cellPaddingX: max(0, cellPaddingX),
            cellPaddingY: max(0, cellPaddingY),
            columnGap: (style == .columns && !borders) ? 2 : 0,
            border: borders,
            outerBorder: _tableOptions?.outerBorder ?? borders,
            showBorders: borders,
            borderStyle: _tableOptions?.borderStyle ?? .single,
            borderColor: _tableOptions?.borderColor?.resolved() ?? defaultBorderColor,
            fg: _fg,
            selectable: _tableOptions?.selectable ?? true
        )
    }

    private func configureTableRenderable(
        _ table: TextTableRenderable,
        alignments: [MarkdownTableAlignment],
        header: [[MarkdownInline]],
        rows: [[[MarkdownInline]]]
    ) {
        let opts = resolveTableOptions()
        table.columnWidthMode = opts.columnWidthMode
        table.columnFitter = opts.columnFitter
        table.wrapMode = opts.wrapMode
        table.cellPaddingX = opts.cellPaddingX
        table.cellPaddingY = opts.cellPaddingY
        table.tableColumnGap = opts.columnGap
        table.border = opts.border
        table.outerBorder = opts.outerBorder
        table.showBorders = opts.showBorders
        table.borderStyle = opts.borderStyle
        table.borderColor = opts.borderColor
        if let fg = opts.fg {
            table.fg = fg
        }
        table.selectable = opts.selectable

        let columnCount = max(header.count, alignments.count)
        table.columnAlignments = (0..<columnCount).map { colIdx in
            let align = colIdx < alignments.count ? alignments[colIdx] : .none
            switch align {
            case .none, .left: return .left
            case .center: return .center
            case .right: return .right
            }
        }

        let base = rootBaseStyle()
        let headingStyleDef = getStyle("markup.heading") ?? getStyle("default")
        let headingAttrs: UInt32
        if let def = headingStyleDef {
            let attrs = styleAttributes(def)
            headingAttrs = attrs == TextAttributes.none ? TextAttributes.bold : attrs
        } else {
            headingAttrs = TextAttributes.bold
        }

        var tableContent: TextTableContent = []
        tableContent.reserveCapacity(1 + rows.count)

        // Header row
        var headerRow: [TextTableCellContent] = []
        headerRow.reserveCapacity(columnCount)
        for colIdx in 0..<columnCount {
            let inlines = colIdx < header.count ? header[colIdx] : []
            let cellStyle = InheritedTextStyle(
                fg: headingStyleDef?.fg ?? base.fg,
                bg: headingStyleDef?.bg ?? base.bg,
                attributes: base.attributes | headingAttrs
            )
            let chunks = buildTableCellChunks(inlines: inlines, baseStyle: cellStyle)
            headerRow.append(.chunks(chunks))
        }
        tableContent.append(headerRow)

        // Body rows
        for row in rows {
            var renderedRow: [TextTableCellContent] = []
            renderedRow.reserveCapacity(columnCount)
            for colIdx in 0..<columnCount {
                let inlines = colIdx < row.count ? row[colIdx] : []
                let chunks = buildTableCellChunks(inlines: inlines, baseStyle: base)
                renderedRow.append(.chunks(chunks))
            }
            tableContent.append(renderedRow)
        }

        table.content = tableContent
    }

    private func buildTableCellChunks(
        inlines: [MarkdownInline],
        baseStyle: InheritedTextStyle
    ) -> [TextChunk] {
        var spans: [MarkdownInlineSpan] = []
        renderInlines(inlines, style: baseStyle, activeLink: nil, into: &spans)
        let source = plainTextOfInlines(inlines)
        if shouldRunInlineHook(for: source), let hook = _inlineHook {
            let ctx = MarkdownInlineContext(
                source: source,
                conceal: _conceal,
                syntaxStyle: _syntaxStyle,
                tableCell: true
            )
            spans = hook(spans, ctx)
        }
        let chunks = spans.map { span in
            TextChunk(
                text: span.text,
                fg: span.fg,
                bg: span.bg,
                attributes: span.attributes,
                link: span.link
            )
        }
        return chunks.isEmpty ? [TextChunk(text: " ")] : chunks
    }

    // MARK: - Inline Rendering & Concealment

    private func rootBaseStyle() -> InheritedTextStyle {
        let defaultStyle = getStyle("default")
        return InheritedTextStyle(
            fg: _fg ?? defaultStyle?.fg,
            bg: _bg ?? defaultStyle?.bg,
            attributes: styleAttributes(defaultStyle)
        )
    }

    private func applyBaseTextStyle(_ base: InheritedTextStyle, to text: TextRenderable) {
        if let fg = base.fg { text.fg = fg }
        if let bg = base.bg { text.bg = bg }
        text.attributes = base.attributes
    }

    private func getStyle(_ scope: String) -> StyleDefinition? {
        guard !_syntaxStyle.isDestroyed else { return nil }
        return _syntaxStyle.getStyle(scope)
    }

    private var hyperlinksEnabled: Bool {
        ctx.capabilities?.hyperlinks ?? true
    }

    private func shouldRunInlineHook(for source: String) -> Bool {
        guard _inlineHook != nil else { return false }
        guard let filter = _inlineHookFilter else { return true }
        guard !filter.isEmpty else { return false }
        return filter.contains { source.contains($0) }
    }

    private func buildProseStyledText(
        inlines: [MarkdownInline],
        baseStyle: InheritedTextStyle,
        source: String,
        headingLevel: Int?
    ) -> (StyledText, [ClickTargetRange]) {
        var spans: [MarkdownInlineSpan] = []

        var activeBase = baseStyle
        if let level = headingLevel {
            let headingDef = getStyle("markup.heading.\(level)") ?? getStyle("markup.heading")
            if let headingDef {
                activeBase = mergeInherited(baseStyle, with: headingDef)
            } else {
                activeBase.attributes |= TextAttributes.bold
            }

            if !_conceal {
                let markerDef = getStyle("markup.heading.marker") ?? getStyle("conceal")
                let markerStyle = mergeInherited(activeBase, with: markerDef)
                spans.append(
                    MarkdownInlineSpan(
                        text: String(repeating: "#", count: max(1, min(6, level))) + " ",
                        fg: markerStyle.fg,
                        bg: markerStyle.bg,
                        attributes: markerStyle.attributes,
                        code: false
                    )
                )
            }
        }

        renderInlines(inlines, style: activeBase, activeLink: nil, into: &spans)

        if shouldRunInlineHook(for: source), let hook = _inlineHook {
            let hookCtx = MarkdownInlineContext(
                source: source,
                conceal: _conceal,
                syntaxStyle: _syntaxStyle,
                tableCell: false
            )
            spans = hook(spans, hookCtx)
        }

        var chunks: [TextChunk] = []
        chunks.reserveCapacity(spans.count)
        var targets: [ClickTargetRange] = []
        var byteOffset = 0

        for span in spans {
            let start = byteOffset
            let end = start + span.text.utf8.count
            byteOffset = end
            if let target = span.target {
                targets.append(ClickTargetRange(startByte: start, endByte: end, target: target))
            }
            chunks.append(
                TextChunk(
                    text: span.text,
                    fg: span.fg,
                    bg: span.bg,
                    attributes: span.attributes,
                    link: span.link
                )
            )
        }

        return (StyledText(chunks: chunks), targets)
    }

    private func renderInlines(
        _ inlines: [MarkdownInline],
        style: InheritedTextStyle,
        activeLink: TextChunkLink?,
        into out: inout [MarkdownInlineSpan]
    ) {
        let concealStyle = mergeInherited(style, with: getStyle("conceal"))

        for node in inlines {
            switch node {
            case .text(let s):
                guard !s.isEmpty else { continue }
                out.append(
                    MarkdownInlineSpan(
                        text: s,
                        fg: style.fg,
                        bg: style.bg,
                        attributes: style.attributes,
                        link: activeLink,
                        code: false
                    )
                )

            case .softBreak:
                out.append(
                    MarkdownInlineSpan(
                        text: " ",
                        fg: style.fg,
                        bg: style.bg,
                        attributes: style.attributes,
                        link: activeLink,
                        code: false
                    )
                )

            case .hardBreak:
                out.append(
                    MarkdownInlineSpan(
                        text: "\n",
                        fg: style.fg,
                        bg: style.bg,
                        attributes: style.attributes,
                        link: activeLink,
                        code: false
                    )
                )

            case .codeSpan(let code):
                let codeDef = getStyle("markup.raw.inline") ?? getStyle("markup.raw")
                let codeStyle = mergeInherited(style, with: codeDef)
                if _conceal {
                    out.append(
                        MarkdownInlineSpan(
                            text: code,
                            fg: codeStyle.fg,
                            bg: codeStyle.bg,
                            attributes: codeStyle.attributes,
                            link: activeLink,
                            code: true
                        )
                    )
                } else {
                    out.append(
                        MarkdownInlineSpan(
                            text: "`\(code)`",
                            fg: codeStyle.fg,
                            bg: codeStyle.bg,
                            attributes: codeStyle.attributes,
                            link: activeLink,
                            code: true
                        )
                    )
                }

            case .emphasis(let children):
                let italicDef = getStyle("markup.italic")
                var nextStyle = mergeInherited(style, with: italicDef)
                if italicDef?.italic != false {
                    nextStyle.attributes |= TextAttributes.italic
                }
                if !_conceal {
                    out.append(MarkdownInlineSpan(
                        text: "*",
                        fg: concealStyle.fg,
                        bg: concealStyle.bg,
                        attributes: concealStyle.attributes,
                        link: activeLink,
                        code: false
                    ))
                }
                renderInlines(children, style: nextStyle, activeLink: activeLink, into: &out)
                if !_conceal {
                    out.append(MarkdownInlineSpan(
                        text: "*",
                        fg: concealStyle.fg,
                        bg: concealStyle.bg,
                        attributes: concealStyle.attributes,
                        link: activeLink,
                        code: false
                    ))
                }

            case .strong(let children):
                let strongDef = getStyle("markup.strong")
                var nextStyle = mergeInherited(style, with: strongDef)
                if strongDef?.bold != false {
                    nextStyle.attributes |= TextAttributes.bold
                }
                if !_conceal {
                    out.append(MarkdownInlineSpan(
                        text: "**",
                        fg: concealStyle.fg,
                        bg: concealStyle.bg,
                        attributes: concealStyle.attributes,
                        link: activeLink,
                        code: false
                    ))
                }
                renderInlines(children, style: nextStyle, activeLink: activeLink, into: &out)
                if !_conceal {
                    out.append(MarkdownInlineSpan(
                        text: "**",
                        fg: concealStyle.fg,
                        bg: concealStyle.bg,
                        attributes: concealStyle.attributes,
                        link: activeLink,
                        code: false
                    ))
                }

            case .strikethrough(let children):
                let strikeDef = getStyle("markup.strikethrough")
                var nextStyle = mergeInherited(style, with: strikeDef)
                if strikeDef?.strikethrough != false {
                    nextStyle.attributes |= TextAttributes.strikethrough
                }
                if !_conceal {
                    out.append(MarkdownInlineSpan(
                        text: "~~",
                        fg: concealStyle.fg,
                        bg: concealStyle.bg,
                        attributes: concealStyle.attributes,
                        link: activeLink,
                        code: false
                    ))
                }
                renderInlines(children, style: nextStyle, activeLink: activeLink, into: &out)
                if !_conceal {
                    out.append(MarkdownInlineSpan(
                        text: "~~",
                        fg: concealStyle.fg,
                        bg: concealStyle.bg,
                        attributes: concealStyle.attributes,
                        link: activeLink,
                        code: false
                    ))
                }

            case .link(let destination, _, let children):
                let linkDef = getStyle("markup.link.label") ?? getStyle("markup.link")
                var linkStyle = mergeInherited(style, with: linkDef)
                if linkDef?.underline != false {
                    linkStyle.attributes |= TextAttributes.underline
                }
                let linkMeta: TextChunkLink? = (hyperlinksEnabled && !destination.isEmpty)
                    ? TextChunkLink(url: destination)
                    : nil

                if !_conceal {
                    out.append(MarkdownInlineSpan(
                        text: "[",
                        fg: concealStyle.fg,
                        bg: concealStyle.bg,
                        attributes: concealStyle.attributes,
                        link: linkMeta,
                        code: false
                    ))
                }
                renderInlines(children, style: linkStyle, activeLink: linkMeta, into: &out)
                if !_conceal {
                    let urlDef = getStyle("markup.link.url") ?? getStyle("markup.link")
                    let urlStyle = mergeInherited(style, with: urlDef)
                    out.append(MarkdownInlineSpan(
                        text: "](",
                        fg: concealStyle.fg,
                        bg: concealStyle.bg,
                        attributes: concealStyle.attributes,
                        link: linkMeta,
                        code: false
                    ))
                    out.append(MarkdownInlineSpan(
                        text: destination,
                        fg: urlStyle.fg,
                        bg: urlStyle.bg,
                        attributes: urlStyle.attributes,
                        link: linkMeta,
                        code: false
                    ))
                    out.append(MarkdownInlineSpan(
                        text: ")",
                        fg: concealStyle.fg,
                        bg: concealStyle.bg,
                        attributes: concealStyle.attributes,
                        link: linkMeta,
                        code: false
                    ))
                }

            case .image(let destination, _, let alt):
                let labelDef = getStyle("markup.link.label") ?? getStyle("markup.link")
                let labelStyle = mergeInherited(style, with: labelDef)
                if !_conceal {
                    out.append(MarkdownInlineSpan(
                        text: "![",
                        fg: concealStyle.fg,
                        bg: concealStyle.bg,
                        attributes: concealStyle.attributes,
                        link: activeLink,
                        code: false
                    ))
                    renderInlines(alt, style: labelStyle, activeLink: activeLink, into: &out)
                    let urlDef = getStyle("markup.link.url") ?? getStyle("markup.link")
                    let urlStyle = mergeInherited(style, with: urlDef)
                    out.append(MarkdownInlineSpan(
                        text: "](",
                        fg: concealStyle.fg,
                        bg: concealStyle.bg,
                        attributes: concealStyle.attributes,
                        link: activeLink,
                        code: false
                    ))
                    out.append(MarkdownInlineSpan(
                        text: destination,
                        fg: urlStyle.fg,
                        bg: urlStyle.bg,
                        attributes: urlStyle.attributes,
                        link: activeLink,
                        code: false
                    ))
                    out.append(MarkdownInlineSpan(
                        text: ")",
                        fg: concealStyle.fg,
                        bg: concealStyle.bg,
                        attributes: concealStyle.attributes,
                        link: activeLink,
                        code: false
                    ))
                } else {
                    let altText = plainTextOfInlines(alt)
                    out.append(MarkdownInlineSpan(
                        text: altText.isEmpty ? destination : altText,
                        fg: labelStyle.fg,
                        bg: labelStyle.bg,
                        attributes: labelStyle.attributes,
                        link: activeLink,
                        code: false
                    ))
                }

            case .rawHTML(let html):
                let htmlStyle = mergeInherited(style, with: getStyle("markup.raw"))
                out.append(MarkdownInlineSpan(
                    text: html,
                    fg: htmlStyle.fg,
                    bg: htmlStyle.bg,
                    attributes: htmlStyle.attributes,
                    link: activeLink,
                    code: false
                ))

            case .math(let tex):
                let mathStyle = mergeInherited(style, with: getStyle("markup.math") ?? getStyle("markup.raw"))
                let display = _conceal ? tex : "$\(tex)$"
                out.append(MarkdownInlineSpan(
                    text: display,
                    fg: mathStyle.fg,
                    bg: mathStyle.bg,
                    attributes: mathStyle.attributes,
                    link: activeLink,
                    code: false,
                    math: tex
                ))
            }
        }
    }

    // MARK: - Block View Builder

    private func makeBlockView(from state: MarkdownBlockState) -> MarkdownBlockView {
        makeBlockView(block: state.block, index: state.index, raw: state.raw, isClosed: state.isClosed)
    }

    private func makeBlockView(
        block: MarkdownBlock,
        index: Int,
        raw: String,
        isClosed: Bool
    ) -> MarkdownBlockView {
        switch block {
        case .paragraph(let inlines):
            return MarkdownBlockView(
                index: index,
                kind: .paragraph,
                block: block,
                raw: raw,
                text: plainTextOfInlines(inlines)
            )
        case .heading(let level, let inlines):
            return MarkdownBlockView(
                index: index,
                kind: .heading,
                block: block,
                level: level,
                raw: raw,
                text: plainTextOfInlines(inlines)
            )
        case .codeBlock(let info, let literal, _, let isMath):
            let lang = isMath ? "math" : extractLanguageToken(from: info)
            return MarkdownBlockView(
                index: index,
                kind: .code,
                block: block,
                lang: lang,
                info: info ?? "",
                closed: isClosed,
                raw: raw,
                text: stripSingleTrailingNewline(literal)
            )
        case .htmlBlock(let html):
            return MarkdownBlockView(index: index, kind: .html, block: block, raw: raw, text: html)
        case .thematicBreak:
            return MarkdownBlockView(index: index, kind: .rule, block: block, raw: raw, text: "")
        case .blockquote(let children):
            let childViews = children.enumerated().map { idx, child in
                makeBlockView(block: child, index: idx, raw: "", isClosed: true)
            }
            return MarkdownBlockView(index: index, kind: .quote, block: block, raw: raw, text: "", children: childViews)
        case .list(let ordered, let start, _, let items):
            let itemViews = items.enumerated().map { idx, item -> MarkdownBlockView in
                let subViews = item.blocks.enumerated().map { subIdx, sub in
                    makeBlockView(block: sub, index: subIdx, raw: "", isClosed: true)
                }
                return MarkdownBlockView(
                    index: idx,
                    kind: .item,
                    block: .paragraph([]),
                    checked: item.taskChecked,
                    raw: "",
                    text: "",
                    children: subViews
                )
            }
            return MarkdownBlockView(
                index: index,
                kind: .list,
                block: block,
                ordered: ordered,
                start: start,
                raw: raw,
                text: "",
                children: itemViews
            )
        case .table:
            return MarkdownBlockView(index: index, kind: .table, block: block, raw: raw, text: "")
        }
    }
}
