import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout

// MARK: - TextContent & TextOptions

/// Initial content accepted by `TextOptions`: either a plain `String` or a `StyledText`.
public enum TextContent: Equatable, Hashable, Sendable, ExpressibleByStringLiteral {
    case string(String)
    case styled(StyledText)

    public init(stringLiteral value: String) {
        self = .string(value)
    }

    public var isEmptyString: Bool {
        if case .string(let s) = self { return s.isEmpty }
        return false
    }

    public func asStyledText() -> StyledText {
        switch self {
        case .string(let s): return stringToStyledText(s)
        case .styled(let st): return st
        }
    }
}

/// Options for initializing a `TextRenderable`.
// parity: core/src/renderables/Text.ts#TextOptions [status=implemented hash=4dab7d75e382]
public struct TextOptions {
    public var bufferOptions: TextBufferOptions
    public var content: TextContent?

    public init(
        id: String? = nil,
        content: TextContent? = nil,
        width: FlexValue? = nil,
        height: FlexValue? = nil,
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
        padding: FlexValue? = nil,
        overflow: Overflow? = nil,
        zIndex: Int? = nil,
        visible: Bool? = nil,
        opacity: Double? = nil,
        buffered: Bool? = nil,
        fg: Color? = nil,
        bg: Color? = nil,
        selectionBg: Color? = nil,
        selectionFg: Color? = nil,
        selectable: Bool? = nil,
        attributes: UInt32? = nil,
        wrapMode: TextWrapMode? = nil,
        textAlign: TextAlign? = nil,
        tabIndicator: String? = nil,
        tabIndicatorColor: Color? = nil,
        truncate: Bool? = nil
    ) {
        self.bufferOptions = TextBufferOptions(
            id: id,
            width: width,
            height: height,
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
            padding: padding,
            overflow: overflow,
            zIndex: zIndex,
            visible: visible,
            opacity: opacity,
            buffered: buffered,
            fg: fg,
            bg: bg,
            selectionBg: selectionBg,
            selectionFg: selectionFg,
            selectable: selectable,
            attributes: attributes,
            wrapMode: wrapMode,
            textAlign: textAlign,
            tabIndicator: tabIndicator,
            tabIndicatorColor: tabIndicatorColor,
            truncate: truncate
        )
        self.content = content
    }

    public init(bufferOptions: TextBufferOptions, content: TextContent? = nil) {
        self.bufferOptions = bufferOptions
        self.content = content
    }
}

// MARK: - TextRenderable

/// Rich text renderable supporting plain strings, `StyledText`, and inline `TextNodeRenderable`
/// children composed via `RootTextNodeRenderable` into the backing `TextBuffer`.
// parity: core/src/renderables/Text.ts#TextRenderable [status=implemented hash=60043aa2924b]
open class TextRenderable: TextBufferRenderable, @unchecked Sendable {
    private var _text: TextContent = .string("")
    private var _hasManualStyledText: Bool = false
    internal var rootTextNode: RootTextNodeRenderable? = nil

    public init(ctx: any RenderContext, options: TextOptions = TextOptions()) {
        super.init(ctx: ctx, options: options.bufferOptions)

        let initialContent = options.content
        let resolvedContent = initialContent ?? .string("")
        applyContent(resolvedContent, markManual: initialContent != nil && !resolvedContent.isEmptyString)

        setBuiltinLifecyclePass { [weak self] in
            self?.updateTextFromNodes()
        }
    }

    private func applyContent(_ value: TextContent, markManual: Bool) {
        guard !isDestroyed && !textBuffer.isDestroyed else { return }
        _text = value
        _hasManualStyledText = markManual
        switch value {
        case .string(let s):
            textBuffer.setText(s)
        case .styled(let st):
            textBuffer.setStyledText(st)
        }
        invalidateIntrinsicSize()
        requestRender()
        refreshLocalSelection()
        emit("line-info-change")
    }

    // parity: core/src/renderables/Text.ts#TextRenderable.content [status=implemented hash=e70ddb11ed44]
    public var content: StyledText {
        get {
            updateTextFromNodes()
            switch _text {
            case .string(let s):
                let st = stringToStyledText(s)
                _text = .styled(st)
                return st
            case .styled(let st):
                return st
            }
        }
        set {
            applyContent(.styled(newValue), markManual: true)
        }
    }

    /// Sets plain-string content directly on this `TextRenderable`.
    public func setContent(_ text: String) {
        applyContent(.string(text), markManual: true)
    }

    /// Sets `StyledText` content directly on this `TextRenderable`.
    public func setContent(_ styledText: StyledText) {
        applyContent(.styled(styledText), markManual: true)
    }

    // parity: core/src/renderables/Text.ts#TextRenderable.chunks [status=implemented hash=748e57073a55]
    public var chunks: [TextChunk] {
        content.chunks
    }

    // parity: core/src/renderables/Text.ts#TextRenderable.textNode [status=implemented hash=315a2eb8a9e9]
    public var textNode: RootTextNodeRenderable {
        if let existing = rootTextNode {
            return existing
        }
        let created = RootTextNodeRenderable(
            ctx: ctx,
            options: TextNodeOptions(
                id: "\(id)-root",
                fg: .rgba(_defaultFg),
                bg: .rgba(_defaultBg),
                attributes: _defaultAttributes
            ),
            textParent: self
        )
        rootTextNode = created
        return created
    }

    internal func updateTextFromNodes() {
        guard !isDestroyed && !textBuffer.isDestroyed else { return }
        guard let root = rootTextNode, root.isDirty, !_hasManualStyledText else { return }

        let style = TextNodeStyle(
            fg: _defaultFg,
            bg: _defaultBg,
            attributes: _defaultAttributes,
            link: nil
        )
        let prepared = root.prepareWithInheritedStyle(style)
        let composed = StyledText(chunks: prepared.chunks)
        _text = .styled(composed)
        textBuffer.setStyledText(composed)
        prepared.acknowledge()
        invalidateIntrinsicSize()
        refreshLocalSelection()
        emit("line-info-change")
    }

    open override func prepareBeforeMeasure() {
        updateTextFromNodes()
    }

    open override var plainText: String {
        updateTextFromNodes()
        return super.plainText
    }

    open override func renderSelf(buffer: OptimizedBuffer, deltaTime: Double) {
        updateTextFromNodes()
        super.renderSelf(buffer: buffer, deltaTime: deltaTime)
    }

    // parity: core/src/renderables/Text.ts#TextRenderable.requestRender [status=implemented hash=8fd49ea875b5]
    open override func requestRender() {
        guard !isDestroyed else { return }
        if let root = rootTextNode, root.isDirty, !_hasManualStyledText {
            invalidateIntrinsicSize()
        }
        super.requestRender()
    }

    // MARK: - Inline Text Node Tree Forwarding

    // parity: core/src/renderables/Text.ts#TextRenderable.add [status=implemented hash=69c9798a52af]
    @discardableResult
    public func add(_ node: TextNodeRenderable, index: Int? = nil) -> Int {
        _hasManualStyledText = false
        return textNode.add(node, index: index)
    }

    @discardableResult
    public func add(_ text: String, index: Int? = nil) -> Int {
        _hasManualStyledText = false
        return textNode.add(text, index: index)
    }

    @discardableResult
    public func add(_ styledText: StyledText, index: Int? = nil) -> Int {
        _hasManualStyledText = false
        return textNode.add(styledText, index: index)
    }

    // parity: core/src/renderables/Text.ts#TextRenderable.remove [status=implemented hash=7c9f0763e1ab]
    open override func remove(_ child: BaseRenderable) {
        textNode.remove(child)
    }

    // parity: core/src/renderables/Text.ts#TextRenderable.insertBefore [status=implemented hash=5093688403c8]
    @discardableResult
    public func insertBefore(_ node: TextNodeRenderable, anchor: TextNodeRenderable) -> Int {
        _hasManualStyledText = false
        _ = textNode.insertBefore(node, anchor: anchor)
        return textNode.children.firstIndex(where: { $0.nodeValue === node }) ?? -1
    }

    @discardableResult
    public func insertBefore(_ text: String, anchor: TextNodeRenderable) -> Int {
        _hasManualStyledText = false
        _ = textNode.insertBefore(text, anchor: anchor)
        return textNode.children.firstIndex(where: { $0.textValue == text }) ?? -1
    }

    @discardableResult
    public func insertBefore(_ styledText: StyledText, anchor: TextNodeRenderable) -> Int {
        _hasManualStyledText = false
        let anchorIndex = textNode.children.firstIndex(where: { $0.nodeValue === anchor }) ?? -1
        _ = textNode.insertBefore(styledText, anchor: anchor)
        return anchorIndex
    }

    // parity: core/src/renderables/Text.ts#TextRenderable.getTextChildren [status=implemented hash=aa74a196c5f8]
    public func getTextChildren() -> [TextNodeRenderable] {
        rootTextNode?.getChildren() ?? []
    }

    // parity: core/src/renderables/Text.ts#TextRenderable.clear [status=implemented hash=cf2932f853d7]
    public func clear() {
        guard !isDestroyed && !textBuffer.isDestroyed else { return }
        textBuffer.setText("")
        _text = .styled(stringToStyledText(""))
        _hasManualStyledText = false
        rootTextNode?.clear()
        invalidateIntrinsicSize()
        requestRender()
        refreshLocalSelection()
        emit("line-info-change")
    }

    // MARK: - Default Style Propagation

    open override func onFgChanged(_ newColor: RGBA) {
        rootTextNode?.fg = newColor
    }

    open override func onBgChanged(_ newColor: RGBA) {
        rootTextNode?.bg = newColor
    }

    open override func onAttributesChanged(_ newAttributes: UInt32) {
        rootTextNode?.attributes = newAttributes
    }

    open override func destroySelf() {
        if let root = rootTextNode {
            for child in root.getChildren() {
                if child.parent === root {
                    child.parent = nil
                }
            }
            root.children = []
            rootTextNode = nil
        }
        super.destroySelf()
    }
}
