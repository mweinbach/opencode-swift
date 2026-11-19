import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout
import OpenTUIRenderables

// MARK: - Rich Content Declarative Components

/// Declarative syntax-highlighted code component backed by `CodeRenderable`.
public struct TUICode: TUIView {
    public typealias Body = Never

    public let content: String
    public let filetype: String?
    public let syntaxStyle: SyntaxStyle
    public let highlighter: (any SyntaxHighlighter)?
    public let conceal: Bool
    public let drawUnstyledText: Bool
    public let streaming: Bool
    public let wrapMode: TextWrapMode?
    public let fg: Color?
    public let bg: Color?

    public init(
        _ content: String,
        filetype: String? = nil,
        syntaxStyle: SyntaxStyle = SyntaxStyle.create(),
        highlighter: (any SyntaxHighlighter)? = nil,
        conceal: Bool = true,
        drawUnstyledText: Bool = true,
        streaming: Bool = false,
        wrapMode: TextWrapMode? = nil,
        fg: Color? = nil,
        bg: Color? = nil
    ) {
        self.content = content
        self.filetype = filetype
        self.syntaxStyle = syntaxStyle
        self.highlighter = highlighter
        self.conceal = conceal
        self.drawUnstyledText = drawUnstyledText
        self.streaming = streaming
        self.wrapMode = wrapMode
        self.fg = fg
        self.bg = bg
    }

    public func resolveNodes() -> [TUIViewNode] {
        let snapshot = self
        return [
            TUIViewNode(
                kind: "code",
                props: ["content": content, "filetype": filetype ?? ""],
                isLeaf: true,
                mount: { ctx in
                    CodeRenderable(
                        ctx: ctx,
                        options: CodeOptions(
                            content: snapshot.content,
                            filetype: snapshot.filetype,
                            syntaxStyle: snapshot.syntaxStyle,
                            highlighter: snapshot.highlighter,
                            conceal: snapshot.conceal,
                            drawUnstyledText: snapshot.drawUnstyledText,
                            streaming: snapshot.streaming,
                            fg: snapshot.fg,
                            bg: snapshot.bg,
                            wrapMode: snapshot.wrapMode
                        )
                    )
                },
                patch: { existing in
                    guard let code = existing as? CodeRenderable else { return false }
                    if code.filetype != snapshot.filetype { code.filetype = snapshot.filetype }
                    if code.conceal != snapshot.conceal { code.conceal = snapshot.conceal }
                    if code.drawUnstyledText != snapshot.drawUnstyledText {
                        code.drawUnstyledText = snapshot.drawUnstyledText
                    }
                    if code.streaming != snapshot.streaming { code.streaming = snapshot.streaming }
                    if let wrapMode = snapshot.wrapMode, code.wrapMode != wrapMode {
                        code.wrapMode = wrapMode
                    }
                    if let fg = snapshot.fg {
                        let resolved = fg.resolved()
                        if code.fg != resolved { code.fg = resolved }
                    }
                    if let bg = snapshot.bg {
                        let resolved = bg.resolved()
                        if code.bg != resolved { code.bg = resolved }
                    }
                    if code.content != snapshot.content { code.content = snapshot.content }
                    return true
                }
            )
        ]
    }
}

/// Declarative unified/split diff viewer backed by `DiffRenderable`.
public struct TUIDiff: TUIView {
    public typealias Body = Never

    public let diff: String
    public let view: DiffViewMode
    public let filetype: String?
    public let syntaxStyle: SyntaxStyle?
    public let highlighter: (any SyntaxHighlighter)?
    public let showLineNumbers: Bool
    public let wrapMode: TextWrapMode?
    public let conceal: Bool
    public let showWordDiff: Bool

    public init(
        _ diff: String,
        view: DiffViewMode = .unified,
        filetype: String? = nil,
        syntaxStyle: SyntaxStyle? = nil,
        highlighter: (any SyntaxHighlighter)? = nil,
        showLineNumbers: Bool = true,
        wrapMode: TextWrapMode? = nil,
        conceal: Bool = true,
        showWordDiff: Bool = true
    ) {
        self.diff = diff
        self.view = view
        self.filetype = filetype
        self.syntaxStyle = syntaxStyle
        self.highlighter = highlighter
        self.showLineNumbers = showLineNumbers
        self.wrapMode = wrapMode
        self.conceal = conceal
        self.showWordDiff = showWordDiff
    }

    public func resolveNodes() -> [TUIViewNode] {
        let snapshot = self
        return [
            TUIViewNode(
                kind: "diff",
                props: ["diff": diff, "view": view.rawValue],
                isLeaf: true,
                mount: { ctx in
                    DiffRenderable(
                        ctx: ctx,
                        options: DiffOptions(
                            diff: snapshot.diff,
                            view: snapshot.view,
                            filetype: snapshot.filetype,
                            syntaxStyle: snapshot.syntaxStyle,
                            wrapMode: snapshot.wrapMode,
                            conceal: snapshot.conceal,
                            highlighter: snapshot.highlighter,
                            showLineNumbers: snapshot.showLineNumbers,
                            showWordDiff: snapshot.showWordDiff
                        )
                    )
                },
                patch: { existing in
                    guard let diffNode = existing as? DiffRenderable else { return false }
                    if diffNode.view != snapshot.view { diffNode.view = snapshot.view }
                    if diffNode.filetype != snapshot.filetype { diffNode.filetype = snapshot.filetype }
                    if diffNode.showLineNumbers != snapshot.showLineNumbers {
                        diffNode.showLineNumbers = snapshot.showLineNumbers
                    }
                    if diffNode.wrapMode != snapshot.wrapMode { diffNode.wrapMode = snapshot.wrapMode }
                    if diffNode.conceal != snapshot.conceal { diffNode.conceal = snapshot.conceal }
                    if diffNode.showWordDiff != snapshot.showWordDiff {
                        diffNode.showWordDiff = snapshot.showWordDiff
                    }
                    if diffNode.diff != snapshot.diff { diffNode.diff = snapshot.diff }
                    return true
                }
            )
        ]
    }
}

/// Declarative Markdown renderer backed by `MarkdownRenderable`.
public struct TUIMarkdown: TUIView {
    public typealias Body = Never

    public let content: String
    public let syntaxStyle: SyntaxStyle
    public let highlighter: (any SyntaxHighlighter)?
    public let conceal: Bool
    public let concealCode: Bool
    public let streaming: Bool
    public let tableOptions: MarkdownTableOptions?
    public let fg: Color?
    public let bg: Color?
    public let renderNodeProvider: ((any RenderContext) -> MarkdownRenderBlockCallback)?

    public init(
        _ content: String,
        syntaxStyle: SyntaxStyle = SyntaxStyle.create(),
        highlighter: (any SyntaxHighlighter)? = nil,
        conceal: Bool = true,
        concealCode: Bool = false,
        streaming: Bool = false,
        tableOptions: MarkdownTableOptions? = nil,
        fg: Color? = nil,
        bg: Color? = nil,
        renderNodeProvider: ((any RenderContext) -> MarkdownRenderBlockCallback)? = nil
    ) {
        self.content = content
        self.syntaxStyle = syntaxStyle
        self.highlighter = highlighter
        self.conceal = conceal
        self.concealCode = concealCode
        self.streaming = streaming
        self.tableOptions = tableOptions
        self.fg = fg
        self.bg = bg
        self.renderNodeProvider = renderNodeProvider
    }

    public func resolveNodes() -> [TUIViewNode] {
        let snapshot = self
        return [
            TUIViewNode(
                kind: "markdown",
                props: ["content": content, "streaming": streaming],
                isLeaf: true,
                mount: { ctx in
                    MarkdownRenderable(
                        ctx: ctx,
                        options: MarkdownOptions(
                            content: snapshot.content,
                            syntaxStyle: snapshot.syntaxStyle,
                            fg: snapshot.fg,
                            bg: snapshot.bg,
                            conceal: snapshot.conceal,
                            concealCode: snapshot.concealCode,
                            highlighter: snapshot.highlighter,
                            streaming: snapshot.streaming,
                            tableOptions: snapshot.tableOptions,
                            renderNode: snapshot.renderNodeProvider?(ctx)
                        )
                    )
                },
                patch: { existing in
                    guard let md = existing as? MarkdownRenderable else { return false }
                    if md.conceal != snapshot.conceal { md.conceal = snapshot.conceal }
                    if md.concealCode != snapshot.concealCode { md.concealCode = snapshot.concealCode }
                    if md.streaming != snapshot.streaming { md.streaming = snapshot.streaming }
                    if md.tableOptions != snapshot.tableOptions { md.tableOptions = snapshot.tableOptions }
                    if md.content != snapshot.content { md.content = snapshot.content }
                    return true
                }
            )
        ]
    }
}
