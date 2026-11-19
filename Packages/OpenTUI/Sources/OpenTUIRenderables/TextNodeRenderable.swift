import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout

// MARK: - Supporting Types

/// Options for creating an inline `TextNodeRenderable`.
// parity: core/src/renderables/TextNode.ts#TextNodeOptions [status=implemented hash=04f407d6d8a8]
public struct TextNodeOptions: Equatable, Hashable, Sendable {
    public var id: String?
    public var fg: Color?
    public var bg: Color?
    public var attributes: UInt32?
    public var link: TextChunkLink?

    public init(
        id: String? = nil,
        fg: Color? = nil,
        bg: Color? = nil,
        attributes: UInt32? = nil,
        link: TextChunkLink? = nil
    ) {
        self.id = id
        self.fg = fg
        self.bg = bg
        self.attributes = attributes
        self.link = link
    }
}

/// Inherited style frame propagated down a `TextNodeRenderable` tree.
public struct TextNodeStyle: Equatable, Hashable, Sendable {
    public var fg: RGBA?
    public var bg: RGBA?
    public var attributes: UInt32
    public var link: TextChunkLink?

    public init(
        fg: RGBA? = nil,
        bg: RGBA? = nil,
        attributes: UInt32 = TextAttributes.none,
        link: TextChunkLink? = nil
    ) {
        self.fg = fg
        self.bg = bg
        self.attributes = attributes
        self.link = link
    }
}

/// A child entry inside a `TextNodeRenderable`: either a literal string or a nested `TextNodeRenderable`.
public enum TextNodeChild: ExpressibleByStringLiteral, @unchecked Sendable {
    case text(String)
    case node(TextNodeRenderable)

    public init(stringLiteral value: String) {
        self = .text(value)
    }

    public var nodeValue: TextNodeRenderable? {
        if case .node(let n) = self { return n }
        return nil
    }

    public var textValue: String? {
        if case .text(let s) = self { return s }
        return nil
    }
}

/// Type check matching `core/src/renderables/TextNode.ts#isTextNodeRenderable`.
// parity: core/src/renderables/TextNode.ts#isTextNodeRenderable [status=implemented hash=2fee00a02f90]
public func isTextNodeRenderable(_ obj: Any?) -> Bool {
    obj is TextNodeRenderable
}

private func styledTextToTextNodes(_ styledText: StyledText) -> [TextNodeRenderable] {
    styledText.chunks.map { chunk in
        let node = TextNodeRenderable(
            options: TextNodeOptions(
                fg: chunk.fg.map { .rgba($0) },
                bg: chunk.bg.map { .rgba($0) },
                attributes: chunk.attributes,
                link: chunk.link
            )
        )
        node.add(chunk.text)
        return node
    }
}

// MARK: - TextNodeRenderable

/// Inline styled text tree node supporting fg/bg/attributes/link inheritance, mixed string and
/// child node children, and dirty propagation up to an owning `TextRenderable`.
// parity: core/src/renderables/TextNode.ts#TextNodeRenderable [status=implemented hash=ae2062b545ef]
open class TextNodeRenderable: BaseRenderable, @unchecked Sendable {
    private var _fg: RGBA?
    private var _bg: RGBA?
    private var _attributes: UInt32
    private var _link: TextChunkLink?
    private var _children: [TextNodeChild] = []
    private var dirtyRevision: UInt64 = 0

    public weak var parent: TextNodeRenderable? = nil

    public init(options: TextNodeOptions = TextNodeOptions()) {
        self._fg = options.fg?.resolved()
        self._bg = options.bg?.resolved()
        self._attributes = options.attributes ?? TextAttributes.none
        self._link = options.link
        super.init(options: BaseRenderableOptions(id: options.id))
    }

    // parity: core/src/renderables/TextNode.ts#TextNodeRenderable.children [status=implemented hash=941078bdb498]
    public var children: [TextNodeChild] {
        get { _children }
        set {
            for child in _children {
                if case .node(let node) = child, node.parent === self {
                    node.parent = nil
                }
            }
            for child in newValue {
                if case .node(let node) = child {
                    if let prev = node.parent, prev !== self {
                        prev.remove(node)
                    }
                    node.parent = self
                }
            }
            _children = newValue
            requestRender()
        }
    }

    // parity: core/src/renderables/TextNode.ts#TextNodeRenderable.requestRender [status=implemented hash=10f8f8443481]
    open func requestRender() {
        markDirty()
        parent?.requestRender()
    }

    open override func markDirty() {
        super.markDirty()
        dirtyRevision &+= 1
    }

    // parity: core/src/renderables/TextNode.ts#TextNodeRenderable.add [status=implemented hash=779b62d73530]
    @discardableResult
    public func add(_ text: String, index: Int? = nil) -> Int {
        if let index {
            let clamped = max(0, min(index, _children.count))
            _children.insert(.text(text), at: clamped)
            requestRender()
            return clamped
        }
        let insertIndex = _children.count
        _children.append(.text(text))
        requestRender()
        return insertIndex
    }

    @discardableResult
    public func add(_ node: TextNodeRenderable, index: Int? = nil) -> Int {
        let insertIndex = prepareChildInsert(node, index: index)
        _children.insert(.node(node), at: insertIndex)
        node.parent = self
        requestRender()
        return insertIndex
    }

    @discardableResult
    public func add(_ styledText: StyledText, index: Int? = nil) -> Int {
        let nodes = styledTextToTextNodes(styledText)
        let wrapped = nodes.map { TextNodeChild.node($0) }
        if let index {
            let clamped = max(0, min(index, _children.count))
            _children.insert(contentsOf: wrapped, at: clamped)
            for node in nodes { node.parent = self }
            requestRender()
            return clamped
        }
        let insertIndex = _children.count
        _children.append(contentsOf: wrapped)
        for node in nodes { node.parent = self }
        requestRender()
        return insertIndex
    }

    private func prepareChildInsert(_ child: TextNodeRenderable, index: Int?) -> Int {
        var insertIndex = index ?? _children.count
        if let prev = child.parent, prev !== self {
            prev.remove(child)
        } else if child.parent === self {
            if let currentIndex = _children.firstIndex(where: { $0.nodeValue === child }) {
                _children.remove(at: currentIndex)
                if currentIndex < insertIndex {
                    insertIndex -= 1
                }
            }
        }
        return max(0, min(insertIndex, _children.count))
    }

    // parity: core/src/renderables/TextNode.ts#TextNodeRenderable.replace [status=implemented hash=3e26674f23a8]
    public func replace(_ text: String, at index: Int) {
        guard index >= 0 && index < _children.count else { return }
        if case .node(let existing) = _children[index], existing.parent === self {
            existing.parent = nil
        }
        _children[index] = .text(text)
        requestRender()
    }

    public func replace(_ node: TextNodeRenderable, at index: Int) {
        guard index >= 0 && index < _children.count else { return }
        var targetIndex = index
        if case .node(let existing) = _children[targetIndex], existing.parent === self {
            existing.parent = nil
        }
        if let prev = node.parent, prev !== self {
            prev.remove(node)
        } else if node.parent === self {
            if let currentIndex = _children.firstIndex(where: { $0.nodeValue === node }), currentIndex != targetIndex {
                _children.remove(at: currentIndex)
                if currentIndex < targetIndex {
                    targetIndex -= 1
                }
            }
        }
        node.parent = self
        if targetIndex < _children.count {
            _children[targetIndex] = .node(node)
        } else {
            _children.append(.node(node))
        }
        requestRender()
    }

    // parity: core/src/renderables/TextNode.ts#TextNodeRenderable.insertBefore [status=implemented hash=de6e6901706f]
    @discardableResult
    public func insertBefore(_ child: TextNodeRenderable, anchor: TextNodeRenderable) -> Self {
        guard let anchorIndex = _children.firstIndex(where: { $0.nodeValue === anchor }) else {
            return self
        }
        if child === anchor {
            return self
        }
        _ = add(child, index: anchorIndex)
        return self
    }

    @discardableResult
    public func insertBefore(_ text: String, anchor: TextNodeRenderable) -> Self {
        guard let anchorIndex = _children.firstIndex(where: { $0.nodeValue === anchor }) else {
            return self
        }
        _children.insert(.text(text), at: anchorIndex)
        requestRender()
        return self
    }

    @discardableResult
    public func insertBefore(_ styledText: StyledText, anchor: TextNodeRenderable) -> Self {
        guard let anchorIndex = _children.firstIndex(where: { $0.nodeValue === anchor }) else {
            return self
        }
        let nodes = styledTextToTextNodes(styledText)
        _children.insert(contentsOf: nodes.map { .node($0) }, at: anchorIndex)
        for node in nodes { node.parent = self }
        requestRender()
        return self
    }

    // parity: core/src/renderables/TextNode.ts#TextNodeRenderable.remove [status=implemented hash=13abb5bb3480]
    public func remove(_ child: BaseRenderable) {
        guard let node = child as? TextNodeRenderable else { return }
        guard let idx = _children.firstIndex(where: { $0.nodeValue === node }) else { return }
        _children.remove(at: idx)
        node.parent = nil
        requestRender()
    }

    // parity: core/src/renderables/TextNode.ts#TextNodeRenderable.clear [status=implemented hash=2599eb4d0d06]
    public func clear() {
        for child in _children {
            if case .node(let node) = child, node.parent === self {
                node.parent = nil
            }
        }
        _children.removeAll()
        requestRender()
    }

    // parity: core/src/renderables/TextNode.ts#TextNodeRenderable.mergeStyles [status=implemented hash=e4e7293f8c91]
    public func mergeStyles(_ parentStyle: TextNodeStyle) -> TextNodeStyle {
        TextNodeStyle(
            fg: _fg ?? parentStyle.fg,
            bg: _bg ?? parentStyle.bg,
            attributes: _attributes | parentStyle.attributes,
            link: _link ?? parentStyle.link
        )
    }

    // parity: core/src/renderables/TextNode.ts#TextNodeRenderable.gatherWithInheritedStyle [status=implemented hash=53f9b76c43ae]
    public func gatherWithInheritedStyle(_ parentStyle: TextNodeStyle = TextNodeStyle()) -> [TextChunk] {
        var ignored: [(TextNodeRenderable, UInt64)]? = nil
        return gatherChunks(parentStyle, revisions: &ignored)
    }

    // parity: core/src/renderables/TextNode.ts#TextNodeRenderable.prepareWithInheritedStyle [status=implemented hash=59783afad212]
    public func prepareWithInheritedStyle(
        _ parentStyle: TextNodeStyle
    ) -> (chunks: [TextChunk], acknowledge: () -> Void) {
        var revisions: [(TextNodeRenderable, UInt64)]? = []
        let chunks = gatherChunks(parentStyle, revisions: &revisions)
        let captured = revisions ?? []
        return (
            chunks: chunks,
            acknowledge: {
                for (node, revision) in captured {
                    if node.dirtyRevision == revision {
                        node.markClean()
                    }
                }
            }
        )
    }

    private func gatherChunks(
        _ parentStyle: TextNodeStyle,
        revisions: inout [(TextNodeRenderable, UInt64)]?
    ) -> [TextChunk] {
        revisions?.append((self, dirtyRevision))
        let currentStyle = mergeStyles(parentStyle)
        var chunks: [TextChunk] = []

        for child in _children {
            switch child {
            case .text(let str):
                chunks.append(TextChunk(
                    text: str,
                    fg: currentStyle.fg,
                    bg: currentStyle.bg,
                    attributes: currentStyle.attributes,
                    link: currentStyle.link
                ))
            case .node(let node):
                if revisions != nil {
                    chunks.append(contentsOf: node.gatherChunks(currentStyle, revisions: &revisions))
                } else {
                    chunks.append(contentsOf: node.gatherWithInheritedStyle(currentStyle))
                }
            }
        }

        if revisions == nil {
            markClean()
        }
        return chunks
    }

    // parity: core/src/renderables/TextNode.ts#TextNodeRenderable.fromString [status=implemented hash=854ccafbc00e]
    public static func fromString(_ text: String, options: TextNodeOptions = TextNodeOptions()) -> TextNodeRenderable {
        let node = TextNodeRenderable(options: options)
        node.add(text)
        return node
    }

    // parity: core/src/renderables/TextNode.ts#TextNodeRenderable.fromNodes [status=implemented hash=119dbec36cea]
    public static func fromNodes(
        _ nodes: [TextNodeRenderable],
        options: TextNodeOptions = TextNodeOptions()
    ) -> TextNodeRenderable {
        let node = TextNodeRenderable(options: options)
        for childNode in nodes {
            node.add(childNode)
        }
        return node
    }

    // parity: core/src/renderables/TextNode.ts#TextNodeRenderable.toChunks [status=implemented hash=2598faba73e9]
    public func toChunks(parentStyle: TextNodeStyle = TextNodeStyle()) -> [TextChunk] {
        gatherWithInheritedStyle(parentStyle)
    }

    // parity: core/src/renderables/TextNode.ts#TextNodeRenderable.getChildren [status=implemented hash=5b1b20c7ac3e]
    public func getChildren() -> [TextNodeRenderable] {
        _children.compactMap(\.nodeValue)
    }

    // parity: core/src/renderables/TextNode.ts#TextNodeRenderable.getChildrenCount [status=implemented hash=8a7566b33e9b]
    public func getChildrenCount() -> Int {
        _children.count
    }

    // parity: core/src/renderables/TextNode.ts#TextNodeRenderable.getRenderable [status=implemented hash=b7cee78a2529]
    public func getRenderable(_ id: String) -> TextNodeRenderable? {
        for child in _children {
            if case .node(let node) = child, node.id == id {
                return node
            }
        }
        return nil
    }

    // parity: core/src/renderables/TextNode.ts#TextNodeRenderable.getRenderableIndex [status=implemented hash=8cf67ea66f3a]
    public func getRenderableIndex(_ id: String) -> Int {
        _children.firstIndex { child in
            if case .node(let node) = child {
                return node.id == id
            }
            return false
        } ?? -1
    }

    // parity: core/src/renderables/TextNode.ts#TextNodeRenderable.fg [status=implemented hash=9c25bfcc5e8d]
    public var fg: RGBA? {
        get { _fg }
        set {
            _fg = newValue
            requestRender()
        }
    }

    // parity: core/src/renderables/TextNode.ts#TextNodeRenderable.bg [status=implemented hash=6557c7c25d24]
    public var bg: RGBA? {
        get { _bg }
        set {
            _bg = newValue
            requestRender()
        }
    }

    // parity: core/src/renderables/TextNode.ts#TextNodeRenderable.attributes [status=implemented hash=b808f39fe392]
    public var attributes: UInt32 {
        get { _attributes }
        set {
            _attributes = newValue
            requestRender()
        }
    }

    // parity: core/src/renderables/TextNode.ts#TextNodeRenderable.link [status=implemented hash=c805b823a293]
    public var link: TextChunkLink? {
        get { _link }
        set {
            _link = newValue
            requestRender()
        }
    }

    // parity: core/src/renderables/TextNode.ts#TextNodeRenderable.findDescendantById [status=implemented hash=e943c9374693]
    public func findDescendantById(_ id: String) -> BaseRenderable? {
        nil
    }
}

// MARK: - RootTextNodeRenderable

/// Root inline text node owned by a `TextRenderable`, forwarding dirty notifications to its parent.
// parity: core/src/renderables/TextNode.ts#RootTextNodeRenderable [status=implemented hash=318f863fe32b]
open class RootTextNodeRenderable: TextNodeRenderable, @unchecked Sendable {
    public let ctx: any RenderContext
    public weak var textParent: TextRenderable?

    public init(
        ctx: any RenderContext,
        options: TextNodeOptions = TextNodeOptions(),
        textParent: TextRenderable
    ) {
        self.ctx = ctx
        self.textParent = textParent
        super.init(options: options)
    }

    // parity: core/src/renderables/TextNode.ts#RootTextNodeRenderable.requestRender [status=implemented hash=8cb73223ad92]
    open override func requestRender() {
        markDirty()
        textParent?.requestRender()
    }
}
