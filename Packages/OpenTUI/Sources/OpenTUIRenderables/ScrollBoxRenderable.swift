import OpenTUICore
import OpenTUILayout

// MARK: - Supporting ScrollBox Types

/// Sticky edge for `ScrollBoxRenderable` auto-follow behavior.
public enum ScrollBoxStickyStart: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case bottom
    case top
    case left
    case right
}

/// Alignment options for `ScrollBoxRenderable.scrollChildIntoView`.
public enum ScrollBoxAlign: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case nearest
    case start
    case end
}

/// Options for `ScrollBoxRenderable.scrollChildIntoView`.
public struct ScrollIntoViewOptions: Equatable, Hashable, Sendable {
    public var align: ScrollBoxAlign
    public var inset: Int

    public init(align: ScrollBoxAlign = .nearest, inset: Int = 0) {
        self.align = align
        self.inset = inset
    }
}

/// 2D scroll coordinate / delta.
public struct ScrollOffset2D: Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double = 0, y: Double = 0) {
        self.x = x
        self.y = y
    }
}

/// Protocol representing a styled layout node backing ScrollBox parts,
/// matching `core/src/renderables/ScrollBoxParts.ts#SceneStyleNode`.
// parity: core/src/renderables/ScrollBoxParts.ts#SceneStyleNode [status=adapted hash=a691c9c34670]
public protocol SceneStyleNode: AnyObject {
    var layoutNode: FlexNode { get }
}

extension Renderable: SceneStyleNode {}

// MARK: - ScrollBoxPart Base Hierarchy

/// Lightweight event subscription token returned by `ScrollBoxPart.on(_:_:)`.
public struct ScrollBoxListenerToken: Equatable, Hashable, Sendable {
    fileprivate let id: UInt64
    fileprivate let event: String
}

internal enum ScrollBarVisibilityPolicy: Equatable {
    case auto
    case always
    case never
}

/// Base facade over `ScrollBoxRenderable`'s layout/scroll state (not a standalone `Renderable`).
open class ScrollBoxPart: @unchecked Sendable {
    private struct ListenerEntry {
        let id: UInt64
        let handler: () -> Void
    }

    internal unowned let box: ScrollBoxRenderable
    private var nextListenerId: UInt64 = 1
    private var listeners: [String: [ListenerEntry]] = [:]

    internal init(box: ScrollBoxRenderable) {
        self.box = box
    }

    internal func rect() -> LayoutRect {
        LayoutRect(x: 0, y: 0, width: 0, height: 0)
    }

    public var isDestroyed: Bool { box.isDestroyed }
    public var x: Int { rect().x }
    public var y: Int { rect().y }
    public var screenX: Int { rect().x }
    public var screenY: Int { rect().y }
    public var width: Int { rect().width }
    public var height: Int { rect().height }

    @discardableResult
    public func on(_ event: String, _ listener: @escaping () -> Void) -> ScrollBoxListenerToken {
        let id = nextListenerId
        nextListenerId &+= 1
        listeners[event, default: []].append(ListenerEntry(id: id, handler: listener))
        return ScrollBoxListenerToken(id: id, event: event)
    }

    public func off(_ token: ScrollBoxListenerToken) {
        listeners[token.event]?.removeAll { $0.id == token.id }
    }

    public func off(_ event: String) {
        listeners.removeValue(forKey: event)
    }

    public func emit(_ event: String) {
        guard let entries = listeners[event], !entries.isEmpty else { return }
        for entry in entries {
            entry.handler()
        }
    }

    internal func listenerCount(_ event: String) -> Int {
        listeners[event]?.count ?? 0
    }
}

open class ScrollBoxFilledPart: ScrollBoxPart, @unchecked Sendable {
    internal var _backgroundColor: RGBA? = nil

    public var backgroundColor: RGBA {
        get { _backgroundColor ?? RGBA.fromValues(0, 0, 0, 0) }
        set {
            _backgroundColor = newValue
            box.requestRender()
        }
    }

    public func setBackgroundColor(_ color: Color?) {
        _backgroundColor = color?.resolved()
        box.requestRender()
    }
}

open class ScrollBoxSizedPart: ScrollBoxFilledPart, @unchecked Sendable {
    public var onSizeChange: (() -> Void)? = nil

    internal func emitResize() {
        onSizeChange?()
        if !box.isDestroyed {
            emit("resize")
        }
    }
}

// MARK: - ScrollBoxWrapper

/// Inner box area excluding the vertical scrollbar gutter,
/// matching `core/src/renderables/ScrollBoxParts.ts#ScrollBoxWrapper`.
// parity: core/src/renderables/ScrollBoxParts.ts#ScrollBoxWrapper [status=implemented hash=06bf45b3f263]
public final class ScrollBoxWrapper: ScrollBoxFilledPart, @unchecked Sendable {
    internal override func rect() -> LayoutRect {
        box.wrapperRect
    }
}

// MARK: - ScrollBoxViewport

/// Viewport clipping & culling window facade with cell-level padding,
/// matching `core/src/renderables/ScrollBoxParts.ts#ScrollBoxViewport`.
// parity: core/src/renderables/ScrollBoxParts.ts#ScrollBoxViewport [status=implemented hash=68eb434fc089]
public final class ScrollBoxViewport: ScrollBoxSizedPart, @unchecked Sendable {
    private var _paddingAll: Int? = nil
    private var _paddingX: Int? = nil
    private var _paddingY: Int? = nil
    private var _paddingLeft: Int? = nil
    private var _paddingTop: Int? = nil
    private var _paddingRight: Int? = nil
    private var _paddingBottom: Int? = nil

    public var padding: Int? {
        get { _paddingAll }
        set {
            _paddingAll = newValue.map { Swift.max(0, $0) }
            box.requestRender()
        }
    }

    public var paddingX: Int? {
        get { _paddingX }
        set {
            _paddingX = newValue.map { Swift.max(0, $0) }
            box.requestRender()
        }
    }

    public var paddingY: Int? {
        get { _paddingY }
        set {
            _paddingY = newValue.map { Swift.max(0, $0) }
            box.requestRender()
        }
    }

    public var paddingLeft: Int {
        get { resolvedEdges().left }
        set {
            _paddingLeft = Swift.max(0, newValue)
            box.requestRender()
        }
    }

    public var paddingTop: Int {
        get { resolvedEdges().top }
        set {
            _paddingTop = Swift.max(0, newValue)
            box.requestRender()
        }
    }

    public var paddingRight: Int {
        get { resolvedEdges().right }
        set {
            _paddingRight = Swift.max(0, newValue)
            box.requestRender()
        }
    }

    public var paddingBottom: Int {
        get { resolvedEdges().bottom }
        set {
            _paddingBottom = Swift.max(0, newValue)
            box.requestRender()
        }
    }

    internal func resolvedEdges() -> (left: Int, top: Int, right: Int, bottom: Int) {
        let all = _paddingAll ?? 0
        let x = _paddingX ?? all
        let y = _paddingY ?? all
        return (
            left: _paddingLeft ?? x,
            top: _paddingTop ?? y,
            right: _paddingRight ?? x,
            bottom: _paddingBottom ?? y
        )
    }

    internal override func rect() -> LayoutRect {
        box.viewportRect
    }

    internal func applyOptions(_ options: BoxOptions?) {
        guard let options else { return }
        if let bg = options.backgroundColor {
            _backgroundColor = bg.resolved()
        }
        if let cb = options.renderable.onSizeChange {
            onSizeChange = cb
        }
        if case .point(let v) = options.renderable.padding { _paddingAll = Swift.max(0, Int(v)) }
        if case .point(let v) = options.renderable.paddingX { _paddingX = Swift.max(0, Int(v)) }
        if case .point(let v) = options.renderable.paddingY { _paddingY = Swift.max(0, Int(v)) }
        if case .point(let v) = options.renderable.paddingLeft { _paddingLeft = Swift.max(0, Int(v)) }
        if case .point(let v) = options.renderable.paddingTop { _paddingTop = Swift.max(0, Int(v)) }
        if case .point(let v) = options.renderable.paddingRight { _paddingRight = Swift.max(0, Int(v)) }
        if case .point(let v) = options.renderable.paddingBottom { _paddingBottom = Swift.max(0, Int(v)) }
    }
}

// MARK: - ScrollBoxContent

/// Scrollable content container facade forwarding children and layout styles to `ScrollBoxRenderable`'s
/// internal `contentLayoutNode`, matching `core/src/renderables/ScrollBoxParts.ts#ScrollBoxContent`.
// parity: core/src/renderables/ScrollBoxParts.ts#ScrollBoxContent [status=implemented hash=cb0895841f6f]
public final class ScrollBoxContent: ScrollBoxSizedPart, @unchecked Sendable {
    internal override func rect() -> LayoutRect {
        box.contentScreenRect
    }

    public var flexDirection: FlexDirection {
        get { box.contentLayoutNode.style.flexDirection }
        set {
            box.contentLayoutNode.style.flexDirection = newValue
            box.requestRender()
        }
    }

    public var flexWrap: Wrap {
        get { box.contentLayoutNode.style.flexWrap }
        set {
            box.contentLayoutNode.style.flexWrap = newValue
            box.requestRender()
        }
    }

    public var alignItems: Align {
        get { box.contentLayoutNode.style.alignItems }
        set {
            box.contentLayoutNode.style.alignItems = newValue
            box.requestRender()
        }
    }

    public var alignContent: Align {
        get { box.contentLayoutNode.style.alignContent }
        set {
            box.contentLayoutNode.style.alignContent = newValue
            box.requestRender()
        }
    }

    public var justifyContent: Justify {
        get { box.contentLayoutNode.style.justifyContent }
        set {
            box.contentLayoutNode.style.justifyContent = newValue
            box.requestRender()
        }
    }

    public var gap: FlexValue {
        get { box.contentLayoutNode.style.gap.all }
        set {
            box.contentLayoutNode.style.gap.all = newValue
            box.requestRender()
        }
    }

    public var rowGap: FlexValue {
        get { box.contentLayoutNode.style.gap.row }
        set {
            box.contentLayoutNode.style.gap.row = newValue
            box.requestRender()
        }
    }

    public var columnGap: FlexValue {
        get { box.contentLayoutNode.style.gap.column }
        set {
            box.contentLayoutNode.style.gap.column = newValue
            box.requestRender()
        }
    }

    public var padding: FlexValue {
        get { box.contentLayoutNode.style.padding.all }
        set {
            box.contentLayoutNode.style.padding.all = newValue
            box.requestRender()
        }
    }

    public var paddingX: FlexValue {
        get { box.contentLayoutNode.style.padding.horizontal }
        set {
            box.contentLayoutNode.style.padding.horizontal = newValue
            box.requestRender()
        }
    }

    public var paddingY: FlexValue {
        get { box.contentLayoutNode.style.padding.vertical }
        set {
            box.contentLayoutNode.style.padding.vertical = newValue
            box.requestRender()
        }
    }

    public var paddingTop: FlexValue {
        get { box.contentLayoutNode.style.padding.top }
        set {
            box.contentLayoutNode.style.padding.top = newValue
            box.requestRender()
        }
    }

    public var paddingRight: FlexValue {
        get { box.contentLayoutNode.style.padding.right }
        set {
            box.contentLayoutNode.style.padding.right = newValue
            box.requestRender()
        }
    }

    public var paddingBottom: FlexValue {
        get { box.contentLayoutNode.style.padding.bottom }
        set {
            box.contentLayoutNode.style.padding.bottom = newValue
            box.requestRender()
        }
    }

    public var paddingLeft: FlexValue {
        get { box.contentLayoutNode.style.padding.left }
        set {
            box.contentLayoutNode.style.padding.left = newValue
            box.requestRender()
        }
    }

    internal var isRowPrimaryAxis: Bool {
        let dir = box.contentLayoutNode.style.flexDirection
        return dir == .row || dir == .rowReverse
    }

    // parity: core/src/renderables/ScrollBoxParts.ts#ScrollBoxContent.viewportCulling [status=implemented hash=760276bb195c]
    public var viewportCulling: Bool {
        get { box.viewportCulling }
        set { box.viewportCulling = newValue }
    }

    // parity: core/src/renderables/ScrollBoxParts.ts#ScrollBoxContent.add [status=implemented hash=e980314f30cd]
    @discardableResult
    public func add(_ obj: Renderable, index: Int? = nil) -> Int {
        box.add(obj, index: index)
    }

    // parity: core/src/renderables/ScrollBoxParts.ts#ScrollBoxContent.insertBefore [status=implemented hash=6e42e3224710]
    @discardableResult
    public func insertBefore(_ obj: Renderable, anchor: Renderable?) -> Int {
        box.insertBefore(obj, anchor: anchor)
    }

    // parity: core/src/renderables/ScrollBoxParts.ts#ScrollBoxContent.remove [status=implemented hash=96e1f77abca2]
    public func remove(_ child: Renderable) {
        box.remove(child)
    }

    // parity: core/src/renderables/ScrollBoxParts.ts#ScrollBoxContent.getChildren [status=implemented hash=eac065179d1d]
    public func getChildren() -> [Renderable] {
        box.getChildren()
    }

    // parity: core/src/renderables/ScrollBoxParts.ts#ScrollBoxContent.getChildrenCount [status=implemented hash=8a184ac21fd0]
    public func getChildrenCount() -> Int {
        box.getChildrenCount()
    }

    // parity: core/src/renderables/ScrollBoxParts.ts#ScrollBoxContent.getRenderable [status=implemented hash=eb8abe925434]
    public func getRenderable(_ id: String) -> Renderable? {
        box.getRenderable(id)
    }

    // parity: core/src/renderables/ScrollBoxParts.ts#ScrollBoxContent.findDescendantById [status=implemented hash=5680c1504b56]
    public func findDescendantById(_ id: String) -> Renderable? {
        box.findDescendantById(id)
    }

    internal func applyOptions(_ options: BoxOptions?) {
        guard let options else { return }
        if let bg = options.backgroundColor {
            _backgroundColor = bg.resolved()
        }
        let r = options.renderable
        if let cb = r.onSizeChange { onSizeChange = cb }
        if let v = r.flexDirection { box.contentLayoutNode.style.flexDirection = v }
        if let v = r.flexWrap { box.contentLayoutNode.style.flexWrap = v }
        if let v = r.alignItems { box.contentLayoutNode.style.alignItems = v }
        if let v = r.alignContent { box.contentLayoutNode.style.alignContent = v }
        if let v = r.justifyContent { box.contentLayoutNode.style.justifyContent = v }
        if let v = r.alignSelf { box.contentLayoutNode.style.alignSelf = v }
        if let v = r.flexGrow { box.contentLayoutNode.style.flexGrow = v }
        if let v = r.flexShrink { box.contentLayoutNode.style.flexShrink = v }
        if let v = r.flexBasis { box.contentLayoutNode.style.flexBasis = v }
        if let v = r.width { box.contentLayoutNode.style.width = v }
        if let v = r.height { box.contentLayoutNode.style.height = v }
        if let v = r.minWidth { box.contentLayoutNode.style.minWidth = v }
        if let v = r.maxWidth { box.contentLayoutNode.style.maxWidth = v }
        if let v = r.minHeight { box.contentLayoutNode.style.minHeight = v }
        if let v = r.maxHeight { box.contentLayoutNode.style.maxHeight = v }
        if let v = r.padding { box.contentLayoutNode.style.padding.all = v }
        if let v = r.paddingX { box.contentLayoutNode.style.padding.horizontal = v }
        if let v = r.paddingY { box.contentLayoutNode.style.padding.vertical = v }
        if let v = r.paddingTop { box.contentLayoutNode.style.padding.top = v }
        if let v = r.paddingRight { box.contentLayoutNode.style.padding.right = v }
        if let v = r.paddingBottom { box.contentLayoutNode.style.padding.bottom = v }
        if let v = r.paddingLeft { box.contentLayoutNode.style.padding.left = v }
        if let v = r.margin { box.contentLayoutNode.style.margin.all = v }
        if let v = r.marginX { box.contentLayoutNode.style.margin.horizontal = v }
        if let v = r.marginY { box.contentLayoutNode.style.margin.vertical = v }
        if let v = r.marginTop { box.contentLayoutNode.style.margin.top = v }
        if let v = r.marginRight { box.contentLayoutNode.style.margin.right = v }
        if let v = r.marginBottom { box.contentLayoutNode.style.margin.bottom = v }
        if let v = r.marginLeft { box.contentLayoutNode.style.margin.left = v }
        if let v = r.gap { box.contentLayoutNode.style.gap.all = v }
        if let v = r.rowGap { box.contentLayoutNode.style.gap.row = v }
        if let v = r.columnGap { box.contentLayoutNode.style.gap.column = v }
        if let v = r.aspectRatio { box.contentLayoutNode.style.aspectRatio = v }
        box.requestRender()
    }
}

// MARK: - ScrollBoxBar

private let scrollBoxDefaultTrack = RGBA.fromHex("#252527")
private let scrollBoxDefaultThumb = RGBA.fromHex("#9a9ea3")
private let scrollBoxDefaultArrowFg = RGBA.fromValues(1, 1, 1, 1)
private let scrollBoxDefaultArrowBg = RGBA.fromValues(0, 0, 0, 0)

/// Scrollbar facade managed natively by `ScrollBoxRenderable`,
/// matching `core/src/renderables/ScrollBoxParts.ts#ScrollBoxBar`.
// parity: core/src/renderables/ScrollBoxParts.ts#ScrollBoxBar [status=implemented hash=b04a00caa68b]
public final class ScrollBoxBar: ScrollBoxPart, ScrollUnitMetrics, @unchecked Sendable {
    public let orientation: SliderOrientation
    internal let axis: Int // 0 = horizontal, 1 = vertical

    public var scrollStep: Double? = nil

    internal var policy: ScrollBarVisibilityPolicy = .auto
    internal var _showArrows: Bool = false
    internal var _arrowOptions: ScrollBarArrowStyleOptions = ScrollBarArrowStyleOptions()
    internal var trackForeground: RGBA = scrollBoxDefaultThumb
    internal var trackBackground: RGBA = scrollBoxDefaultTrack
    internal var thickness: Int = 1
    internal var gap: Int = 0
    internal var overlay: Bool = false

    internal var isVisibleCalculated: Bool = false
    internal var barRect: LayoutRect = LayoutRect(x: 0, y: 0, width: 0, height: 0)
    internal var trackRect: LayoutRect = LayoutRect(x: 0, y: 0, width: 0, height: 0)
    internal var startArrowRect: LayoutRect = LayoutRect(x: 0, y: 0, width: 0, height: 0)
    internal var endArrowRect: LayoutRect = LayoutRect(x: 0, y: 0, width: 0, height: 0)

    // parity: core/src/renderables/ScrollBoxParts.ts#ScrollBoxBar.onChange [status=implemented hash=1e96291a3c97]
    public var onChange: ((Int) -> Void)? = nil

    internal init(box: ScrollBoxRenderable, orientation: SliderOrientation) {
        self.orientation = orientation
        self.axis = orientation == .vertical ? 1 : 0
        super.init(box: box)
    }

    internal override func rect() -> LayoutRect {
        let arrows = _showArrows ? 1 : 0
        if axis == 1 {
            return LayoutRect(
                x: trackRect.x - gap,
                y: trackRect.y - arrows,
                width: trackRect.width + gap,
                height: trackRect.height + 2 * arrows
            )
        } else {
            return LayoutRect(
                x: trackRect.x - arrows,
                y: trackRect.y - gap,
                width: trackRect.width + 2 * arrows,
                height: trackRect.height + gap
            )
        }
    }

    internal var gutter: Int {
        (isVisibleCalculated && !overlay) ? (gap + thickness) : 0
    }

    internal func emitChange(_ position: Int) {
        onChange?(position)
        if !box.isDestroyed {
            emit("change")
        }
    }

    // parity: core/src/renderables/ScrollBoxParts.ts#ScrollBoxBar.visible [status=implemented hash=90608f4f75da]
    public var visible: Bool {
        get { isVisibleCalculated }
        set {
            guard !box.isDestroyed else { return }
            policy = newValue ? .always : .never
            isVisibleCalculated = newValue
            box.requestRender()
        }
    }

    // parity: core/src/renderables/ScrollBoxParts.ts#ScrollBoxBar.resetVisibilityControl [status=implemented hash=8117974c4df9]
    public func resetVisibilityControl() {
        guard !box.isDestroyed else { return }
        policy = .auto
        box.requestRender()
    }

    // parity: core/src/renderables/ScrollBoxParts.ts#ScrollBoxBar.showArrows [status=implemented hash=4f3478549f53]
    public var showArrows: Bool {
        get { _showArrows }
        set {
            guard !box.isDestroyed else { return }
            _showArrows = newValue
            box.requestRender()
        }
    }

    // parity: core/src/renderables/ScrollBoxParts.ts#ScrollBoxBar.arrowOptions [status=implemented hash=92b50fe9e233]
    public var arrowOptions: ScrollBarArrowStyleOptions {
        get { _arrowOptions }
        set {
            _arrowOptions = _arrowOptions.merged(with: newValue)
            if !box.isDestroyed {
                box.requestRender()
            }
        }
    }

    // parity: core/src/renderables/ScrollBoxParts.ts#ScrollBoxBar.trackOptions [status=implemented hash=be33458e609c]
    public var trackOptions: ScrollBarTrackStyleOptions {
        get {
            ScrollBarTrackStyleOptions(
                foregroundColor: .rgba(trackForeground),
                backgroundColor: .rgba(trackBackground)
            )
        }
        set {
            guard !box.isDestroyed else { return }
            if let fg = newValue.foregroundColor {
                trackForeground = fg.resolved()
            }
            if let bg = newValue.backgroundColor {
                trackBackground = bg.resolved()
            }
            box.requestRender()
        }
    }

    // parity: core/src/renderables/ScrollBoxParts.ts#ScrollBoxBar.paddingLeft [status=implemented hash=28f74b304819]
    public var paddingLeft: Int {
        get { axis == 1 ? gap : 0 }
        set {
            guard axis == 1, !box.isDestroyed else { return }
            gap = Swift.max(0, Swift.min(255, newValue))
            box.requestRender()
        }
    }

    // parity: core/src/renderables/ScrollBoxParts.ts#ScrollBoxBar.paddingTop [status=implemented hash=fc50bcfd2176]
    public var paddingTop: Int {
        get { axis == 0 ? gap : 0 }
        set {
            guard axis == 0, !box.isDestroyed else { return }
            gap = Swift.max(0, Swift.min(255, newValue))
            box.requestRender()
        }
    }

    // parity: core/src/renderables/ScrollBoxParts.ts#ScrollBoxBar.position [status=implemented hash=3792e09e44c8]
    public var position: PositionType {
        get { overlay ? .absolute : .relative }
        set {
            guard !box.isDestroyed else { return }
            overlay = (newValue == .absolute)
            box.requestRender()
        }
    }

    public func setThickness(_ cells: Int) {
        guard !box.isDestroyed else { return }
        thickness = Swift.max(1, Swift.min(255, cells))
        box.requestRender()
    }

    // parity: core/src/renderables/ScrollBoxParts.ts#ScrollBoxBar.scrollSize [status=implemented hash=78bec26891d5]
    public var scrollSize: Double {
        axis == 1 ? Double(box.scrollHeight) : Double(box.scrollWidth)
    }

    // parity: core/src/renderables/ScrollBoxParts.ts#ScrollBoxBar.viewportSize [status=implemented hash=6f333628cfb3]
    public var viewportSize: Double {
        axis == 1 ? Double(box.viewportRect.height) : Double(box.viewportRect.width)
    }

    // parity: core/src/renderables/ScrollBoxParts.ts#ScrollBoxBar.scrollPosition [status=implemented hash=917fd82b859a]
    public var scrollPosition: Int {
        get { axis == 1 ? box.scrollTop : box.scrollLeft }
        set { box.scrollAxis(axis, to: Double(newValue), relative: false) }
    }

    // parity: core/src/renderables/ScrollBoxParts.ts#ScrollBoxBar.scrollBy [status=implemented hash=d8601f0d20fe]
    public func scrollBy(_ delta: Double, unit: ScrollUnit = .absolute) {
        let amount = scrollUnitSize(self, unit: unit) * delta
        box.scrollAxis(axis, to: amount, relative: true, reapply: true)
    }

    // parity: core/src/renderables/ScrollBoxParts.ts#ScrollBoxBar.handleKeyPress [status=implemented hash=92db633f4861]
    @discardableResult
    public func handleKeyPress(_ key: KeyEvent) -> Bool {
        switch key.name {
        case "left", "h":
            guard orientation == .horizontal else { return false }
            scrollBy(-1.0 / 5.0, unit: .viewport)
            return true
        case "right", "l":
            guard orientation == .horizontal else { return false }
            scrollBy(1.0 / 5.0, unit: .viewport)
            return true
        case "up", "k":
            guard orientation == .vertical else { return false }
            scrollBy(-1.0 / 5.0, unit: .viewport)
            return true
        case "down", "j":
            guard orientation == .vertical else { return false }
            scrollBy(1.0 / 5.0, unit: .viewport)
            return true
        case "pageup":
            scrollBy(-1.0 / 2.0, unit: .viewport)
            return true
        case "pagedown":
            scrollBy(1.0 / 2.0, unit: .viewport)
            return true
        case "home":
            scrollBy(-1.0, unit: .content)
            return true
        case "end":
            scrollBy(1.0, unit: .content)
            return true
        default:
            return false
        }
    }

    internal func applyOptions(_ options: ScrollBarOptions?) {
        guard let options else { return }
        if let v = options.renderable.visible {
            visible = v
        }
        if let show = options.showArrows {
            _showArrows = show
        }
        if let arrowOpts = options.arrowOptions {
            _arrowOptions = _arrowOptions.merged(with: arrowOpts)
        }
        if let trackOpts = options.trackOptions {
            if let fg = trackOpts.foregroundColor { trackForeground = fg.resolved() }
            if let bg = trackOpts.backgroundColor { trackBackground = bg.resolved() }
        }
        if let onChange = options.onChange {
            self.onChange = onChange
        }
        if let step = options.scrollStep {
            self.scrollStep = step
        }
        if axis == 1, case .point(let w) = options.renderable.width {
            thickness = Swift.max(1, Swift.min(255, Int(w)))
        }
        if axis == 0, case .point(let h) = options.renderable.height {
            thickness = Swift.max(1, Swift.min(255, Int(h)))
        }
        if axis == 1, case .point(let p) = options.renderable.paddingLeft {
            gap = Swift.max(0, Swift.min(255, Int(p)))
        }
        if axis == 0, case .point(let p) = options.renderable.paddingTop {
            gap = Swift.max(0, Swift.min(255, Int(p)))
        }
        if let pos = options.renderable.position {
            overlay = (pos == .absolute)
        }
    }

    internal func resolvedArrowGlyphs() -> (
        startGlyph: String,
        endGlyph: String,
        fg: RGBA,
        bg: RGBA,
        attributes: UInt32
    ) {
        let chars = _arrowOptions.arrowChars ?? ArrowChars()
        let startDir: ScrollDirection = axis == 1 ? .up : .left
        let endDir: ScrollDirection = axis == 1 ? .down : .right
        let bg = _arrowOptions.backgroundColor?.resolved() ?? scrollBoxDefaultArrowBg
        let fg = _arrowOptions.foregroundColor?.resolved()
            ?? _arrowOptions.backgroundColor?.resolved()
            ?? scrollBoxDefaultArrowFg
        return (
            startGlyph: chars.resolved(for: startDir),
            endGlyph: chars.resolved(for: endDir),
            fg: fg,
            bg: bg,
            attributes: _arrowOptions.attributes ?? TextAttributes.none
        )
    }
}

// MARK: - ScrollBoxOptions

/// Options for configuring a `ScrollBoxRenderable`, matching `core/src/renderables/ScrollBox.ts#ScrollBoxOptions`.
// parity: core/src/renderables/ScrollBox.ts#ScrollBoxOptions [status=implemented hash=47c596a92831]
public struct ScrollBoxOptions {
    public var box: BoxOptions
    public var rootOptions: BoxOptions?
    public var wrapperOptions: BoxOptions?
    public var viewportOptions: BoxOptions?
    public var contentOptions: BoxOptions?
    public var scrollbarOptions: ScrollBarOptions?
    public var verticalScrollbarOptions: ScrollBarOptions?
    public var horizontalScrollbarOptions: ScrollBarOptions?
    public var stickyScroll: Bool
    public var stickyStart: ScrollBoxStickyStart?
    public var scrollX: Bool
    public var scrollY: Bool
    public var scrollAcceleration: (any ScrollAcceleration)?
    public var viewportCulling: Bool

    public init(
        id: String? = nil,
        width: FlexValue? = nil,
        height: FlexValue? = nil,
        minWidth: FlexValue? = nil,
        maxWidth: FlexValue? = nil,
        minHeight: FlexValue? = nil,
        maxHeight: FlexValue? = nil,
        flexGrow: Float? = nil,
        flexShrink: Float? = nil,
        flexBasis: FlexValue? = nil,
        flexDirection: FlexDirection? = nil,
        alignItems: Align? = nil,
        alignSelf: Align? = nil,
        justifyContent: Justify? = nil,
        position: PositionType? = nil,
        top: FlexValue? = nil,
        right: FlexValue? = nil,
        bottom: FlexValue? = nil,
        left: FlexValue? = nil,
        margin: FlexValue? = nil,
        padding: FlexValue? = nil,
        paddingX: FlexValue? = nil,
        paddingY: FlexValue? = nil,
        paddingTop: FlexValue? = nil,
        paddingRight: FlexValue? = nil,
        paddingBottom: FlexValue? = nil,
        paddingLeft: FlexValue? = nil,
        gap: FlexValue? = nil,
        rowGap: FlexValue? = nil,
        columnGap: FlexValue? = nil,
        zIndex: Int? = nil,
        visible: Bool? = nil,
        opacity: Double? = nil,
        focusable: Bool? = nil,
        backgroundColor: Color? = nil,
        borderStyle: BorderStyle? = nil,
        border: BorderSpec? = nil,
        borderColor: Color? = nil,
        customBorderChars: BorderCharacters? = nil,
        shouldFill: Bool? = nil,
        title: String? = nil,
        titleColor: Color? = nil,
        titleAlignment: BoxTitleAlignment? = nil,
        bottomTitle: String? = nil,
        bottomTitleAlignment: BoxTitleAlignment? = nil,
        focusedBorderColor: Color? = nil,
        rootOptions: BoxOptions? = nil,
        wrapperOptions: BoxOptions? = nil,
        viewportOptions: BoxOptions? = nil,
        contentOptions: BoxOptions? = nil,
        scrollbarOptions: ScrollBarOptions? = nil,
        verticalScrollbarOptions: ScrollBarOptions? = nil,
        horizontalScrollbarOptions: ScrollBarOptions? = nil,
        stickyScroll: Bool = false,
        stickyStart: ScrollBoxStickyStart? = nil,
        scrollX: Bool = false,
        scrollY: Bool = true,
        scrollAcceleration: (any ScrollAcceleration)? = nil,
        viewportCulling: Bool = true
    ) {
        self.box = BoxOptions(
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
            flexDirection: flexDirection,
            alignItems: alignItems,
            alignSelf: alignSelf,
            justifyContent: justifyContent,
            position: position,
            top: top,
            right: right,
            bottom: bottom,
            left: left,
            margin: margin,
            padding: padding,
            paddingX: paddingX,
            paddingY: paddingY,
            paddingTop: paddingTop,
            paddingRight: paddingRight,
            paddingBottom: paddingBottom,
            paddingLeft: paddingLeft,
            gap: gap,
            rowGap: rowGap,
            columnGap: columnGap,
            overflow: .hidden,
            zIndex: zIndex,
            visible: visible,
            opacity: opacity,
            focusable: focusable ?? true,
            backgroundColor: backgroundColor,
            borderStyle: borderStyle,
            border: border,
            borderColor: borderColor,
            customBorderChars: customBorderChars,
            shouldFill: shouldFill,
            title: title,
            titleColor: titleColor,
            titleAlignment: titleAlignment,
            bottomTitle: bottomTitle,
            bottomTitleAlignment: bottomTitleAlignment,
            focusedBorderColor: focusedBorderColor
        )
        self.rootOptions = rootOptions
        self.wrapperOptions = wrapperOptions
        self.viewportOptions = viewportOptions
        self.contentOptions = contentOptions
        self.scrollbarOptions = scrollbarOptions
        self.verticalScrollbarOptions = verticalScrollbarOptions
        self.horizontalScrollbarOptions = horizontalScrollbarOptions
        self.stickyScroll = stickyScroll
        self.stickyStart = stickyStart
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.scrollAcceleration = scrollAcceleration
        self.viewportCulling = viewportCulling
    }
}

// MARK: - ScrollBoxRenderable

/// Scrollable box container with viewport scissor clipping, optional viewport culling,
/// sticky-edge auto-follow, scroll acceleration, scroll-chain wheel bubbling, keyboard
/// navigation, interactive scrollbars, and drag-selection auto-scroll,
/// matching `core/src/renderables/ScrollBox.ts#ScrollBoxRenderable`.
// parity: core/src/renderables/ScrollBox.ts#ScrollBoxRenderable [status=implemented hash=a38d96e7e918]
open class ScrollBoxRenderable: BoxRenderable, @unchecked Sendable {
    private enum BarPressState {
        case thumb(axis: Int, offset: Double, lastPointer: Double)
        case arrow(axis: Int, direction: Double, timer: TimerHandle?)
    }

    private struct LayoutCallbackEntry {
        let frame: Int
        let callback: () -> Void
    }

    private struct AnchorState {
        let token: UInt64
        weak var node: Renderable?
        var viewportOffsetX: Int?
        var viewportOffsetY: Int?
    }

    private struct RevealRequest {
        weak var node: Renderable?
        let align: ScrollBoxAlign
        let inset: Int
    }

    public private(set) var wrapper: ScrollBoxWrapper!
    public private(set) var viewport: ScrollBoxViewport!
    public private(set) var content: ScrollBoxContent!
    public private(set) var horizontalScrollBar: ScrollBoxBar!
    public private(set) var verticalScrollBar: ScrollBoxBar!

    internal let contentLayoutNode: FlexNode = FlexNode()

    // Scroll geometry state
    internal var wrapperRect: LayoutRect = LayoutRect(x: 0, y: 0, width: 0, height: 0)
    internal var viewportRect: LayoutRect = LayoutRect(x: 0, y: 0, width: 0, height: 0)
    internal var contentScreenRect: LayoutRect = LayoutRect(x: 0, y: 0, width: 0, height: 0)
    private var contentOriginX: Int = 0
    private var contentOriginY: Int = 0
    private var _scrollWidth: Int = 0
    private var _scrollHeight: Int = 0
    private var _scrollLeft: Int = 0
    private var _scrollTop: Int = 0
    private var _maxScrollX: Int = 0
    private var _maxScrollY: Int = 0

    // Sticky, axes, culling, acceleration
    private var _stickyScroll: Bool
    private var _stickyStart: ScrollBoxStickyStart?
    private var _isStuck: Bool = false
    private var _scrollX: Bool
    private var _scrollY: Bool
    private var _viewportCulling: Bool
    private var _scrollAccel: any ScrollAcceleration

    // Fractional wheel accumulators
    private var scrollAccumulatorX: Double = 0
    private var scrollAccumulatorY: Double = 0

    // Pending scroll targets & callbacks
    private var pendingTargetX: Double? = nil
    private var pendingTargetY: Double? = nil
    private var pendingReveal: RevealRequest? = nil
    private var layoutCallbacks: [LayoutCallbackEntry] = []
    private var nextAnchorToken: UInt64 = 1
    private var anchorState: AnchorState? = nil

    // Scrollbar press / drag interaction
    private var barPress: BarPressState? = nil

    // Auto-scroll during drag selection
    private var isAutoScrolling: Bool = false
    private var autoScrollOwner: Selection? = nil
    private var autoScrollMouseX: Int = 0
    private var autoScrollMouseY: Int = 0
    private let autoScrollThresholdVertical: Int = 3
    private let autoScrollThresholdHorizontal: Int = 3
    private let autoScrollSpeedSlow: Double = 6
    private let autoScrollSpeedMedium: Double = 36
    private let autoScrollSpeedFast: Double = 72
    private var cachedAutoScrollSpeed: Double = 3
    private var autoScrollAccumulatorX: Double = 0
    private var autoScrollAccumulatorY: Double = 0
    private var selectionListenerToken: CliRendererListenerToken? = nil

    // Previous reported viewport/content dimensions for resize events
    private var lastReportedViewportSize: (w: Int, h: Int) = (0, 0)
    private var lastReportedContentSize: (w: Int, h: Int) = (0, 0)

    public init(ctx: any RenderContext, options: ScrollBoxOptions = ScrollBoxOptions()) {
        self._stickyScroll = options.stickyScroll
        self._stickyStart = options.stickyStart
        self._isStuck = options.stickyScroll && options.stickyStart != nil
        self._scrollX = options.scrollX
        self._scrollY = options.scrollY
        self._viewportCulling = options.viewportCulling
        self._scrollAccel = options.scrollAcceleration ?? LinearScrollAccel()

        // Root padding forwards to content; outer box keeps padding stripped.
        var rootBox = options.box
        let forwardedPadding = Self.extractPadding(from: rootBox.renderable, override: options.rootOptions?.renderable)
        Self.stripPadding(&rootBox.renderable)

        if let rootOpts = options.rootOptions {
            var sanitizedRoot = rootOpts
            Self.stripPadding(&sanitizedRoot.renderable)
            rootBox = Self.mergeRootBoxOptions(base: rootBox, override: sanitizedRoot)
        }
        if rootBox.renderable.flexDirection == nil {
            rootBox.renderable.flexDirection = .row
        }
        if rootBox.renderable.alignItems == nil {
            rootBox.renderable.alignItems = .stretch
        }
        rootBox.renderable.overflow = .hidden
        if rootBox.renderable.focusable == nil {
            rootBox.renderable.focusable = true
        }

        super.init(ctx: ctx, options: rootBox)

        self.wrapper = ScrollBoxWrapper(box: self)
        self.viewport = ScrollBoxViewport(box: self)
        self.content = ScrollBoxContent(box: self)
        self.verticalScrollBar = ScrollBoxBar(box: self, orientation: .vertical)
        self.horizontalScrollBar = ScrollBoxBar(box: self, orientation: .horizontal)

        // Apply forwarded padding to content node first, then explicit contentOptions.
        self.contentLayoutNode.style.padding = forwardedPadding
        self.contentLayoutNode.style.flexDirection = .column
        self.contentLayoutNode.style.alignItems = .stretch

        if let wrapperOpts = options.wrapperOptions {
            if let bg = wrapperOpts.backgroundColor {
                self.wrapper._backgroundColor = bg.resolved()
            }
        }
        self.viewport.applyOptions(options.viewportOptions)

        if let sharedBar = options.scrollbarOptions {
            self.verticalScrollBar.applyOptions(sharedBar)
            self.horizontalScrollBar.applyOptions(sharedBar)
        }
        self.verticalScrollBar.applyOptions(options.verticalScrollbarOptions)
        self.horizontalScrollBar.applyOptions(options.horizontalScrollbarOptions)
        self.content.applyOptions(options.contentOptions)

        setupIntrinsicMeasureFunc()
    }

    private static func extractPadding(
        from base: RenderableOptions,
        override: RenderableOptions?
    ) -> FlexEdgeValues {
        var edges = FlexEdgeValues()
        if let v = base.padding { edges.all = v }
        if let v = base.paddingX { edges.horizontal = v }
        if let v = base.paddingY { edges.vertical = v }
        if let v = base.paddingTop { edges.top = v }
        if let v = base.paddingRight { edges.right = v }
        if let v = base.paddingBottom { edges.bottom = v }
        if let v = base.paddingLeft { edges.left = v }
        if let ov = override {
            if let v = ov.padding { edges.all = v }
            if let v = ov.paddingX { edges.horizontal = v }
            if let v = ov.paddingY { edges.vertical = v }
            if let v = ov.paddingTop { edges.top = v }
            if let v = ov.paddingRight { edges.right = v }
            if let v = ov.paddingBottom { edges.bottom = v }
            if let v = ov.paddingLeft { edges.left = v }
        }
        return edges
    }

    private static func stripPadding(_ opts: inout RenderableOptions) {
        opts.padding = nil
        opts.paddingX = nil
        opts.paddingY = nil
        opts.paddingTop = nil
        opts.paddingRight = nil
        opts.paddingBottom = nil
        opts.paddingLeft = nil
    }

    private static func mergeRootBoxOptions(base: BoxOptions, override: BoxOptions) -> BoxOptions {
        var merged = base
        if let v = override.backgroundColor { merged.backgroundColor = v }
        if let v = override.borderStyle { merged.borderStyle = v }
        if let v = override.border { merged.border = v }
        if let v = override.borderColor { merged.borderColor = v }
        if let v = override.customBorderChars { merged.customBorderChars = v }
        if let v = override.shouldFill { merged.shouldFill = v }
        if let v = override.title { merged.title = v }
        if let v = override.titleColor { merged.titleColor = v }
        if let v = override.titleAlignment { merged.titleAlignment = v }
        if let v = override.bottomTitle { merged.bottomTitle = v }
        if let v = override.bottomTitleAlignment { merged.bottomTitleAlignment = v }
        if let v = override.focusedBorderColor { merged.focusedBorderColor = v }
        if let v = override.renderable.width { merged.renderable.width = v }
        if let v = override.renderable.height { merged.renderable.height = v }
        if let v = override.renderable.flexGrow { merged.renderable.flexGrow = v }
        if let v = override.renderable.flexShrink { merged.renderable.flexShrink = v }
        if let v = override.renderable.focusable { merged.renderable.focusable = v }
        return merged
    }

    private func setupIntrinsicMeasureFunc() {
        setMeasureProvider { [weak self] width, widthMode, height, heightMode in
            guard let self else { return .zero }
            let availW: Float? = (widthMode == .undefined || !width.isFinite) ? nil : Swift.max(0, width)
            let availH: Float? = (heightMode == .undefined || !height.isFinite) ? nil : Swift.max(0, height)
            FlexSolver.calculateLayout(
                root: self.contentLayoutNode,
                availableWidth: self._scrollX ? nil : availW,
                availableHeight: self._scrollY ? nil : availH,
                direction: .ltr
            )
            let contentSize = self.contentLayoutNode.computedLayout
            let measuredW = availW.map { Swift.min(contentSize.width, $0) } ?? contentSize.width
            let measuredH = availH.map { Swift.min(contentSize.height, $0) } ?? contentSize.height
            return FlexSize(width: measuredW, height: measuredH)
        }
    }

    // MARK: - Properties

    // parity: core/src/renderables/ScrollBox.ts#ScrollBoxRenderable.stickyScroll [status=implemented hash=719193c0516e]
    public var stickyScroll: Bool {
        get { _stickyScroll }
        set {
            _stickyScroll = newValue
            if newValue && _stickyStart != nil {
                updateStuckState()
            } else {
                _isStuck = false
            }
            requestRender()
        }
    }

    // parity: core/src/renderables/ScrollBox.ts#ScrollBoxRenderable.stickyStart [status=implemented hash=d24f8e1660e3]
    public var stickyStart: ScrollBoxStickyStart? {
        get { _stickyStart }
        set {
            _stickyStart = newValue
            _isStuck = _stickyScroll && newValue != nil
            requestRender()
        }
    }

    // parity: core/src/renderables/ScrollBox.ts#ScrollBoxRenderable.scrollX [status=implemented hash=2c9ebbcccdbc]
    public var scrollX: Bool {
        get { _scrollX }
        set {
            guard _scrollX != newValue else { return }
            _scrollX = newValue
            requestRender()
        }
    }

    // parity: core/src/renderables/ScrollBox.ts#ScrollBoxRenderable.scrollY [status=implemented hash=04846f3bc166]
    public var scrollY: Bool {
        get { _scrollY }
        set {
            guard _scrollY != newValue else { return }
            _scrollY = newValue
            requestRender()
        }
    }

    // parity: core/src/renderables/ScrollBox.ts#ScrollBoxRenderable.scrollTop [status=implemented hash=0eefaa59364a]
    public var scrollTop: Int {
        get { _scrollTop }
        set { scrollAxis(1, to: Double(newValue), relative: false) }
    }

    // parity: core/src/renderables/ScrollBox.ts#ScrollBoxRenderable.scrollLeft [status=implemented hash=6a6f76f27ddd]
    public var scrollLeft: Int {
        get { _scrollLeft }
        set { scrollAxis(0, to: Double(newValue), relative: false) }
    }

    // parity: core/src/renderables/ScrollBox.ts#ScrollBoxRenderable.scrollWidth [status=implemented hash=8d37bb6040cc]
    public var scrollWidth: Int {
        _scrollWidth
    }

    // parity: core/src/renderables/ScrollBox.ts#ScrollBoxRenderable.scrollHeight [status=implemented hash=31bef44067d5]
    public var scrollHeight: Int {
        _scrollHeight
    }

    // parity: core/src/renderables/ScrollBox.ts#ScrollBoxRenderable.scrollAcceleration [status=implemented hash=a40f965aeb8d]
    public var scrollAcceleration: any ScrollAcceleration {
        get { _scrollAccel }
        set { _scrollAccel = newValue }
    }

    // parity: core/src/renderables/ScrollBox.ts#ScrollBoxRenderable.viewportCulling [status=implemented hash=49a62dd1af2b]
    public var viewportCulling: Bool {
        get { _viewportCulling }
        set {
            guard _viewportCulling != newValue else { return }
            _viewportCulling = newValue
            requestRender()
        }
    }

    // MARK: - Sub-Options Setters

    // parity: core/src/renderables/ScrollBox.ts#ScrollBoxRenderable.rootOptions [status=implemented hash=5964a0ba4897]
    public var rootOptions: BoxOptions? {
        get { nil }
        set {
            guard let options = newValue, !_isDestroyed else { return }
            if let bg = options.backgroundColor { backgroundColor = bg.resolved() }
            if let b = options.border { border = b }
            if let bs = options.borderStyle { borderStyle = bs }
            if let bc = options.borderColor { borderColor = bc.resolved() }
            if let fbc = options.focusedBorderColor { focusedBorderColor = fbc.resolved() }
            if let sf = options.shouldFill { shouldFill = sf }
            if let t = options.title { title = t }
            if let tc = options.titleColor { titleColor = tc.resolved() }
            if let ta = options.titleAlignment { titleAlignment = ta }
            if let bt = options.bottomTitle { bottomTitle = bt }
            if let bta = options.bottomTitleAlignment { bottomTitleAlignment = bta }
            let forwarded = Self.extractPadding(from: options.renderable, override: nil)
            if !forwarded.all.isUndefined { contentLayoutNode.style.padding.all = forwarded.all }
            if !forwarded.horizontal.isUndefined { contentLayoutNode.style.padding.horizontal = forwarded.horizontal }
            if !forwarded.vertical.isUndefined { contentLayoutNode.style.padding.vertical = forwarded.vertical }
            if !forwarded.top.isUndefined { contentLayoutNode.style.padding.top = forwarded.top }
            if !forwarded.right.isUndefined { contentLayoutNode.style.padding.right = forwarded.right }
            if !forwarded.bottom.isUndefined { contentLayoutNode.style.padding.bottom = forwarded.bottom }
            if !forwarded.left.isUndefined { contentLayoutNode.style.padding.left = forwarded.left }
            requestRender()
        }
    }

    // parity: core/src/renderables/ScrollBox.ts#ScrollBoxRenderable.wrapperOptions [status=implemented hash=47af811359be]
    public var wrapperOptions: BoxOptions? {
        get { nil }
        set {
            if let bg = newValue?.backgroundColor {
                wrapper.backgroundColor = bg.resolved()
            }
        }
    }

    // parity: core/src/renderables/ScrollBox.ts#ScrollBoxRenderable.viewportOptions [status=implemented hash=04551d4e81f0]
    public var viewportOptions: BoxOptions? {
        get { nil }
        set { viewport.applyOptions(newValue) }
    }

    // parity: core/src/renderables/ScrollBox.ts#ScrollBoxRenderable.contentOptions [status=implemented hash=f067646bb334]
    public var contentOptions: BoxOptions? {
        get { nil }
        set { content.applyOptions(newValue) }
    }

    // parity: core/src/renderables/ScrollBox.ts#ScrollBoxRenderable.scrollbarOptions [status=implemented hash=2a4fbca4bc16]
    public var scrollbarOptions: ScrollBarOptions? {
        get { nil }
        set {
            if let newValue {
                verticalScrollBar.applyOptions(newValue)
                horizontalScrollBar.applyOptions(newValue)
            } else {
                verticalScrollBar.onChange = nil
                horizontalScrollBar.onChange = nil
            }
        }
    }

    // parity: core/src/renderables/ScrollBox.ts#ScrollBoxRenderable.verticalScrollbarOptions [status=implemented hash=2c38f2b5dd7e]
    public var verticalScrollbarOptions: ScrollBarOptions? {
        get { nil }
        set {
            if let newValue {
                verticalScrollBar.applyOptions(newValue)
            } else {
                verticalScrollBar.onChange = nil
            }
        }
    }

    // parity: core/src/renderables/ScrollBox.ts#ScrollBoxRenderable.horizontalScrollbarOptions [status=implemented hash=b17569e535e2]
    public var horizontalScrollbarOptions: ScrollBarOptions? {
        get { nil }
        set {
            if let newValue {
                horizontalScrollBar.applyOptions(newValue)
            } else {
                horizontalScrollBar.onChange = nil
            }
        }
    }

    // MARK: - Tree Forwarding to Content Container

    @discardableResult
    open override func add(_ child: Renderable, index: Int? = nil) -> Int {
        let insertedIndex = super.add(child, index: index)
        if insertedIndex >= 0 {
            contentLayoutNode.insertChild(child.layoutNode, at: insertedIndex)
            layoutNode.markDirty()
        }
        return insertedIndex
    }

    @discardableResult
    open override func insertBefore(_ child: Renderable, anchor: Renderable?) -> Int {
        let insertedIndex = super.insertBefore(child, anchor: anchor)
        if insertedIndex >= 0 {
            contentLayoutNode.insertChild(child.layoutNode, at: insertedIndex)
            layoutNode.markDirty()
        }
        return insertedIndex
    }

    open override func remove(_ child: Renderable) {
        contentLayoutNode.removeChild(child.layoutNode)
        super.remove(child)
        layoutNode.markDirty()
    }

    // MARK: - Scroll Navigation API

    // parity: core/src/renderables/ScrollBox.ts#ScrollBoxRenderable.scrollTo [status=implemented hash=2f9e6b830126]
    public func scrollTo(_ position: Double) {
        scrollAxis(1, to: position, relative: false, reapply: true)
    }

    public func scrollTo(_ position: ScrollOffset2D) {
        scrollAxis(1, to: position.y, relative: false, reapply: true)
        guard !_isDestroyed else { return }
        scrollAxis(0, to: position.x, relative: false, reapply: true)
    }

    // parity: core/src/renderables/ScrollBox.ts#ScrollBoxRenderable.scrollBy [status=implemented hash=f956a33d6c46]
    public func scrollBy(_ delta: Double, unit: ScrollUnit = .absolute) {
        verticalScrollBar.scrollBy(delta, unit: unit)
    }

    public func scrollBy(_ delta: ScrollOffset2D, unit: ScrollUnit = .absolute) {
        verticalScrollBar.scrollBy(delta.y, unit: unit)
        guard !_isDestroyed else { return }
        horizontalScrollBar.scrollBy(delta.x, unit: unit)
    }

    // parity: core/src/renderables/ScrollBox.ts#ScrollBoxRenderable.scrollChildIntoView [status=implemented hash=958f94cd6264]
    public func scrollChildIntoView(_ child: Renderable, options: ScrollIntoViewOptions = ScrollIntoViewOptions()) {
        guard !_isDestroyed else { return }
        pendingTargetX = nil
        pendingTargetY = nil
        pendingReveal = RevealRequest(node: child, align: options.align, inset: Swift.max(0, options.inset))
        applyRevealIfPossible(node: child, align: options.align, inset: Swift.max(0, options.inset))
    }

    public func scrollChildIntoView(_ childId: String, options: ScrollIntoViewOptions = ScrollIntoViewOptions()) {
        guard let node = findDescendantById(childId) else { return }
        scrollChildIntoView(node, options: options)
    }

    // parity: core/src/renderables/ScrollBox.ts#ScrollBoxRenderable.afterLayout [status=implemented hash=35d023086d8a]
    public func afterLayout(_ callback: @escaping () -> Void) {
        guard !_isDestroyed else { return }
        layoutCallbacks.append(LayoutCallbackEntry(frame: ctx.frameId, callback: callback))
        requestRender()
    }

    // parity: core/src/renderables/ScrollBox.ts#ScrollBoxRenderable.anchor [status=implemented hash=9fe0afb42b60]
    public func anchor(_ node: Renderable) -> () -> Void {
        guard !_isDestroyed else { return {} }
        let token = nextAnchorToken
        nextAnchorToken &+= 1
        let rel = contentRelativeBounds(of: node)
        anchorState = AnchorState(
            token: token,
            node: node,
            viewportOffsetX: rel.map { $0.x - _scrollLeft },
            viewportOffsetY: rel.map { $0.y - _scrollTop }
        )
        return { [weak self] in
            guard let self, self.anchorState?.token == token else { return }
            self.anchorState = nil
        }
    }

    internal func scrollAxis(_ axis: Int, to value: Double, relative: Bool, reapply: Bool = false) {
        guard !_isDestroyed, !value.isNaN else { return }

        if !reapply {
            if axis == 0 { pendingTargetX = nil } else { pendingTargetY = nil }
        }
        pendingReveal = nil

        let currentPos: Double
        if axis == 0 {
            let pending = pendingTargetX ?? Double(_scrollLeft)
            let base = pending.isInfinite ? Double(_maxScrollX) : pending
            currentPos = relative ? (base + value) : value
            if reapply && !(relative && value == 0) {
                pendingTargetX = currentPos
            }
        } else {
            let pending = pendingTargetY ?? Double(_scrollTop)
            let base = pending.isInfinite ? Double(_maxScrollY) : pending
            currentPos = relative ? (base + value) : value
            if reapply && !(relative && value == 0) {
                pendingTargetY = currentPos
            }
        }

        if currentPos.isInfinite && currentPos > 0 {
            anchorState = nil
        }

        let prevX = _scrollLeft
        let prevY = _scrollTop

        if axis == 0 {
            let clamped = clampScrollValue(currentPos, maxLimit: _maxScrollX)
            _scrollLeft = clamped
        } else {
            let clamped = clampScrollValue(currentPos, maxLimit: _maxScrollY)
            _scrollTop = clamped
        }

        updateStuckState()

        let dx = _scrollLeft - prevX
        let dy = _scrollTop - prevY
        if dx != 0 || dy != 0 {
            if var anchor = anchorState {
                if let ox = anchor.viewportOffsetX { anchor.viewportOffsetX = ox - dx }
                if let oy = anchor.viewportOffsetY { anchor.viewportOffsetY = oy - dy }
                anchorState = anchor
            }
            contentScreenRect = LayoutRect(
                x: contentOriginX - _scrollLeft,
                y: contentOriginY - _scrollTop,
                width: _scrollWidth,
                height: _scrollHeight
            )
            for child in _childrenInLayoutOrder {
                offsetSubtreeScreenCoords(child, dx: -dx, dy: -dy)
            }
            requestRender()
            if dy != 0 { verticalScrollBar.emitChange(_scrollTop) }
            if !_isDestroyed && dx != 0 { horizontalScrollBar.emitChange(_scrollLeft) }
        }
    }

    private func clampScrollValue(_ value: Double, maxLimit: Int) -> Int {
        if value.isInfinite {
            return value > 0 ? maxLimit : 0
        }
        let rounded = Int((value + 0.5).rounded(.down))
        return Swift.max(0, Swift.min(maxLimit, rounded))
    }

    private func updateStuckState() {
        guard _stickyScroll, let edge = _stickyStart else {
            _isStuck = false
            return
        }
        switch edge {
        case .bottom:
            _isStuck = (_scrollTop >= _maxScrollY)
        case .top:
            _isStuck = (_scrollTop <= 0)
        case .right:
            _isStuck = (_scrollLeft >= _maxScrollX)
        case .left:
            _isStuck = (_scrollLeft <= 0)
        }
    }

    private func contentRelativeBounds(of target: Renderable) -> LayoutRect? {
        var cursor: Renderable? = target
        var accX = 0
        var accY = 0
        var found = false
        while let node = cursor {
            if node === self {
                found = true
                break
            }
            accX += node._localX
            accY += node._localY
            cursor = node.parent
        }
        guard found else { return nil }
        return LayoutRect(x: accX, y: accY, width: target.width, height: target.height)
    }

    private func applyRevealIfPossible(node: Renderable, align: ScrollBoxAlign, inset: Int) {
        guard let bounds = contentRelativeBounds(of: node), viewportRect.width > 0 || viewportRect.height > 0 else {
            return
        }

        if _scrollY && viewportRect.height > 0 {
            let targetY = computeRevealOffset(
                itemStart: bounds.y,
                itemSize: bounds.height,
                currentOffset: _scrollTop,
                viewportSize: viewportRect.height,
                align: align,
                inset: inset
            )
            scrollAxis(1, to: Double(targetY), relative: false)
        }
        if _scrollX && viewportRect.width > 0 {
            let targetX = computeRevealOffset(
                itemStart: bounds.x,
                itemSize: bounds.width,
                currentOffset: _scrollLeft,
                viewportSize: viewportRect.width,
                align: align,
                inset: inset
            )
            scrollAxis(0, to: Double(targetX), relative: false)
        }
    }

    private func computeRevealOffset(
        itemStart: Int,
        itemSize: Int,
        currentOffset: Int,
        viewportSize: Int,
        align: ScrollBoxAlign,
        inset: Int
    ) -> Int {
        switch align {
        case .start:
            return itemStart - inset
        case .end:
            return itemStart + itemSize - viewportSize + inset
        case .nearest:
            let itemEnd = itemStart + itemSize
            let viewStart = currentOffset + inset
            let viewEnd = currentOffset + viewportSize - inset
            if itemStart < viewStart {
                return itemStart - inset
            }
            if itemEnd > viewEnd {
                return itemEnd - viewportSize + inset
            }
            return currentOffset
        }
    }

    // MARK: - Layout & Geometry Resolution

    open override func updateFromLayout() {
        guard !_isDestroyed else { return }

        let rect = layoutNode.computedLayout.rect
        let prevScreenX = _screenX
        let prevScreenY = _screenY
        let prevWidth = _computedWidth
        let prevHeight = _computedHeight
        let hadLayout = _hasComputedLayout

        _localX = rect.x
        _localY = rect.y
        _screenX = (parent?._screenX ?? 0) + _localX + _translateX
        _screenY = (parent?._screenY ?? 0) + _localY + _translateY
        _computedWidth = rect.width
        _computedHeight = rect.height
        _hasComputedLayout = true
        layoutNode.markLayoutSeen()

        let sizeChanged = !hadLayout || prevWidth != _computedWidth || prevHeight != _computedHeight
        let posChanged = !hadLayout || prevScreenX != _screenX || prevScreenY != _screenY

        if _visible && sizeChanged {
            onLayoutResize(width: _computedWidth, height: _computedHeight)
        }
        if posChanged || sizeChanged {
            emit(LayoutEvents.layoutChanged)
        }

        guard _visible else { return }

        resolveScrollLayout()
    }

    private func resolveScrollLayout() {
        let bLeft = borderSides.left ? 1 : 0
        let bTop = borderSides.top ? 1 : 0
        let bRight = borderSides.right ? 1 : 0
        let bBottom = borderSides.bottom ? 1 : 0

        let innerX = _screenX + bLeft
        let innerY = _screenY + bTop
        let innerW = Swift.max(0, width - bLeft - bRight)
        let innerH = Swift.max(0, height - bTop - bBottom)

        let vpEdges = viewport.resolvedEdges()

        // Iterative convergence (max 2 passes) because scrollbar gutters affect viewport size.
        var showV = verticalScrollBar.policy == .always
        var showH = horizontalScrollBar.policy == .always
        var vpW = 0
        var vpH = 0
        var contentW = 0
        var contentH = 0

        for _ in 0..<2 {
            let vGutter = (showV && !verticalScrollBar.overlay) ? (verticalScrollBar.gap + verticalScrollBar.thickness) : 0
            let hGutter = (showH && !horizontalScrollBar.overlay) ? (horizontalScrollBar.gap + horizontalScrollBar.thickness) : 0

            let availInnerW = Swift.max(0, innerW - vGutter)
            let availInnerH = Swift.max(0, innerH - hGutter)

            vpW = Swift.max(0, availInnerW - vpEdges.left - vpEdges.right)
            vpH = Swift.max(0, availInnerH - vpEdges.top - vpEdges.bottom)

            FlexSolver.calculateLayout(
                root: contentLayoutNode,
                availableWidth: _scrollX ? nil : Float(vpW),
                availableHeight: _scrollY ? nil : Float(vpH),
                direction: .ltr
            )

            let computed = contentLayoutNode.computedLayout.rect
            contentW = computed.width
            contentH = computed.height

            let nextV: Bool
            switch verticalScrollBar.policy {
            case .always: nextV = true
            case .never: nextV = false
            case .auto: nextV = _scrollY && contentH > vpH
            }

            let nextH: Bool
            switch horizontalScrollBar.policy {
            case .always: nextH = true
            case .never: nextH = false
            case .auto: nextH = _scrollX && contentW > vpW
            }

            if nextV == showV && nextH == showH {
                showV = nextV
                showH = nextH
                break
            }
            showV = nextV
            showH = nextH
        }

        verticalScrollBar.isVisibleCalculated = showV
        horizontalScrollBar.isVisibleCalculated = showH

        let vGutter = verticalScrollBar.gutter
        let hGutter = horizontalScrollBar.gutter

        wrapperRect = LayoutRect(
            x: innerX,
            y: innerY,
            width: Swift.max(0, innerW - vGutter),
            height: innerH
        )
        viewportRect = LayoutRect(
            x: innerX + vpEdges.left,
            y: innerY + vpEdges.top,
            width: Swift.max(0, innerW - vGutter - vpEdges.left - vpEdges.right),
            height: Swift.max(0, innerH - hGutter - vpEdges.top - vpEdges.bottom)
        )

        contentOriginX = viewportRect.x
        contentOriginY = viewportRect.y
        _scrollWidth = contentW
        _scrollHeight = contentH
        _maxScrollX = _scrollX ? Swift.max(0, contentW - viewportRect.width) : 0
        _maxScrollY = _scrollY ? Swift.max(0, contentH - viewportRect.height) : 0

        // Compute scrollbar track & arrow screen rects (matching scene.zig#barRects).
        computeBarRects(innerX: innerX, innerY: innerY, innerW: innerW, innerH: innerH)

        // Apply anchor / pending targets / sticky follow / clamping.
        let prevX = _scrollLeft
        let prevY = _scrollTop

        if let targetY = pendingTargetY {
            _scrollTop = clampScrollValue(targetY, maxLimit: _maxScrollY)
            pendingTargetY = nil
        } else if _stickyScroll && _isStuck && (_stickyStart == .bottom || _stickyStart == .top) {
            _scrollTop = (_stickyStart == .bottom) ? _maxScrollY : 0
        } else {
            _scrollTop = Swift.max(0, Swift.min(_maxScrollY, _scrollTop))
        }

        if let targetX = pendingTargetX {
            _scrollLeft = clampScrollValue(targetX, maxLimit: _maxScrollX)
            pendingTargetX = nil
        } else if _stickyScroll && _isStuck && (_stickyStart == .right || _stickyStart == .left) {
            _scrollLeft = (_stickyStart == .right) ? _maxScrollX : 0
        } else {
            _scrollLeft = Swift.max(0, Swift.min(_maxScrollX, _scrollLeft))
        }

        // Update children layout & screen coordinates first so anchor/reveal have fresh geometry.
        updateChildrenScreenCoordinates()

        // Apply anchor preservation if active.
        if let anchor = anchorState, let node = anchor.node, !node.isDestroyed,
           let rel = contentRelativeBounds(of: node)
        {
            var adjusted = false
            if let expectedY = anchor.viewportOffsetY, _scrollY {
                let desiredY = Swift.max(0, Swift.min(_maxScrollY, rel.y - expectedY))
                if desiredY != _scrollTop {
                    _scrollTop = desiredY
                    adjusted = true
                }
            }
            if let expectedX = anchor.viewportOffsetX, _scrollX {
                let desiredX = Swift.max(0, Swift.min(_maxScrollX, rel.x - expectedX))
                if desiredX != _scrollLeft {
                    _scrollLeft = desiredX
                    adjusted = true
                }
            }
            if adjusted {
                updateChildrenScreenCoordinates()
            }
        }

        // Apply pending scrollChildIntoView request if present.
        if let reveal = pendingReveal {
            pendingReveal = nil
            if let node = reveal.node, !node.isDestroyed {
                applyRevealIfPossible(node: node, align: reveal.align, inset: reveal.inset)
            }
        }

        updateStuckState()

        contentScreenRect = LayoutRect(
            x: contentOriginX - _scrollLeft,
            y: contentOriginY - _scrollTop,
            width: _scrollWidth,
            height: _scrollHeight
        )

        // Emit offset & size notifications.
        if _scrollTop != prevY { verticalScrollBar.emitChange(_scrollTop) }
        if !_isDestroyed && _scrollLeft != prevX { horizontalScrollBar.emitChange(_scrollLeft) }

        if !_isDestroyed && (viewportRect.width != lastReportedViewportSize.w || viewportRect.height != lastReportedViewportSize.h) {
            lastReportedViewportSize = (viewportRect.width, viewportRect.height)
            viewport.emitResize()
        }
        if !_isDestroyed && (_scrollWidth != lastReportedContentSize.w || _scrollHeight != lastReportedContentSize.h) {
            lastReportedContentSize = (_scrollWidth, _scrollHeight)
            content.emitResize()
        }

        // Fire due afterLayout callbacks.
        if !_isDestroyed && !layoutCallbacks.isEmpty {
            let currentFrame = ctx.frameId
            let due = layoutCallbacks.filter { $0.frame < currentFrame }
            layoutCallbacks = layoutCallbacks.filter { $0.frame >= currentFrame }
            for entry in due {
                if _isDestroyed { break }
                entry.callback()
            }
        }
    }

    private func updateChildrenScreenCoordinates() {
        let dx = contentOriginX - _screenX - _scrollLeft
        let dy = contentOriginY - _screenY - _scrollTop
        for child in _childrenInLayoutOrder {
            child.updateFromLayout()
            offsetSubtreeScreenCoords(child, dx: dx, dy: dy)
        }
    }

    private func offsetSubtreeScreenCoords(_ node: Renderable, dx: Int, dy: Int) {
        guard dx != 0 || dy != 0 else { return }
        node._screenX += dx
        node._screenY += dy
        for child in node._childrenInLayoutOrder {
            offsetSubtreeScreenCoords(child, dx: dx, dy: dy)
        }
    }

    private func computeBarRects(innerX: Int, innerY: Int, innerW: Int, innerH: Int) {
        // Vertical bar (axis = 1)
        do {
            let t = verticalScrollBar.thickness
            let barX = innerX + Swift.max(0, innerW - t)
            let barW = Swift.min(innerW, t)
            let bar = LayoutRect(x: barX, y: innerY, width: barW, height: innerH)
            verticalScrollBar.barRect = bar
            if verticalScrollBar.showArrows {
                let ends = Swift.min(2, innerH)
                let arrowX = bar.x + Swift.max(0, (bar.width - 1) / 2)
                let arrowW = Swift.min(1, bar.width)
                let arrowH = Swift.min(1, bar.height)
                verticalScrollBar.startArrowRect = LayoutRect(x: arrowX, y: bar.y, width: arrowW, height: arrowH)
                verticalScrollBar.endArrowRect = LayoutRect(
                    x: arrowX,
                    y: bar.y + Swift.max(0, innerH - 1),
                    width: arrowW,
                    height: arrowH
                )
                verticalScrollBar.trackRect = LayoutRect(
                    x: bar.x,
                    y: bar.y + Swift.min(1, ends),
                    width: bar.width,
                    height: Swift.max(0, bar.height - ends)
                )
            } else {
                verticalScrollBar.startArrowRect = LayoutRect(x: 0, y: 0, width: 0, height: 0)
                verticalScrollBar.endArrowRect = LayoutRect(x: 0, y: 0, width: 0, height: 0)
                verticalScrollBar.trackRect = bar
            }
        }

        // Horizontal bar (axis = 0)
        do {
            let t = horizontalScrollBar.thickness
            let availW = Swift.max(0, innerW - verticalScrollBar.gutter)
            let barY = innerY + Swift.max(0, innerH - t)
            let barH = Swift.min(innerH, t)
            let bar = LayoutRect(x: innerX, y: barY, width: availW, height: barH)
            horizontalScrollBar.barRect = bar
            if horizontalScrollBar.showArrows {
                let ends = Swift.min(2, availW)
                let arrowY = bar.y + Swift.max(0, (bar.height - 1) / 2)
                let arrowW = Swift.min(1, bar.width)
                let arrowH = Swift.min(1, bar.height)
                horizontalScrollBar.startArrowRect = LayoutRect(x: bar.x, y: arrowY, width: arrowW, height: arrowH)
                horizontalScrollBar.endArrowRect = LayoutRect(
                    x: bar.x + Swift.max(0, availW - 1),
                    y: arrowY,
                    width: arrowW,
                    height: arrowH
                )
                horizontalScrollBar.trackRect = LayoutRect(
                    x: bar.x + Swift.min(1, ends),
                    y: bar.y,
                    width: Swift.max(0, bar.width - ends),
                    height: bar.height
                )
            } else {
                horizontalScrollBar.startArrowRect = LayoutRect(x: 0, y: 0, width: 0, height: 0)
                horizontalScrollBar.endArrowRect = LayoutRect(x: 0, y: 0, width: 0, height: 0)
                horizontalScrollBar.trackRect = bar
            }
        }
    }

    // MARK: - Rendering (Viewport Clipping, Culling & Native Scrollbars)

    open override func render(buffer: OptimizedBuffer, deltaTime: Double) {
        guard _visible && !_isDestroyed else { return }

        onUpdate(deltaTime: deltaTime)
        guard _visible && !_isDestroyed else { return }

        let pushedOpacity = _opacity < 1.0
        if pushedOpacity {
            buffer.pushOpacity(_opacity)
        }
        defer {
            if pushedOpacity {
                buffer.popOpacity()
            }
        }

        if participatesInHitGrid && width > 0 && height > 0 {
            ctx.addToHitGrid(x: _screenX, y: _screenY, width: width, height: height, id: num)
        }

        renderBefore?(buffer, deltaTime)
        guard !_isDestroyed else { return }

        // 1. Box border & background
        renderSelf(buffer: buffer, deltaTime: deltaTime)
        guard !_isDestroyed else { return }

        // 2. Wrapper, viewport, and content background fills
        paintScrollFills(buffer: buffer)

        // 3. Viewport-clipped scrolled children
        if viewportRect.width > 0 && viewportRect.height > 0 {
            buffer.pushScissorRect(
                x: viewportRect.x,
                y: viewportRect.y,
                width: viewportRect.width,
                height: viewportRect.height
            )
            renderChildren(buffer: buffer, deltaTime: deltaTime)
            buffer.popScissorRect()
        }

        // 4. Visible scrollbars painted on top of children (matching scene.zig#paintBars)
        paintScrollBars(buffer: buffer)

        if !_isDestroyed {
            renderAfter?(buffer, deltaTime)
        }

        markClean()
    }

    private func paintScrollFills(buffer: OptimizedBuffer) {
        if let fill = wrapper._backgroundColor, fill.a > 0, wrapperRect.width > 0, wrapperRect.height > 0 {
            buffer.fillRect(
                x: wrapperRect.x,
                y: wrapperRect.y,
                width: wrapperRect.width,
                height: wrapperRect.height,
                bg: fill
            )
        }
        if let fill = viewport._backgroundColor, fill.a > 0, viewportRect.width > 0, viewportRect.height > 0 {
            buffer.fillRect(
                x: viewportRect.x,
                y: viewportRect.y,
                width: viewportRect.width,
                height: viewportRect.height,
                bg: fill
            )
        }
        if let fill = content._backgroundColor, fill.a > 0, viewportRect.width > 0, viewportRect.height > 0 {
            let ix = Swift.max(viewportRect.x, contentScreenRect.x)
            let iy = Swift.max(viewportRect.y, contentScreenRect.y)
            let ix2 = Swift.min(viewportRect.x + viewportRect.width, contentScreenRect.x + contentScreenRect.width)
            let iy2 = Swift.min(viewportRect.y + viewportRect.height, contentScreenRect.y + contentScreenRect.height)
            if ix < ix2 && iy < iy2 {
                buffer.fillRect(x: ix, y: iy, width: ix2 - ix, height: iy2 - iy, bg: fill)
            }
        }
    }

    private func paintScrollBars(buffer: OptimizedBuffer) {
        for bar in [horizontalScrollBar!, verticalScrollBar!] where bar.isVisibleCalculated {
            let track = bar.trackRect
            let maxVal = bar.axis == 1 ? Double(_maxScrollY) : Double(_maxScrollX)
            let curVal = bar.axis == 1 ? Double(_scrollTop) : Double(_scrollLeft)
            let vpSize = Swift.max(1.0, bar.viewportSize)

            if track.width >= 1 && track.height >= 1 {
                paintSliderTrack(
                    buffer: buffer,
                    x: track.x,
                    y: track.y,
                    width: track.width,
                    height: track.height,
                    orientation: bar.orientation,
                    min: 0,
                    max: maxVal,
                    value: curVal,
                    viewPortSize: vpSize,
                    foreground: bar.trackForeground,
                    background: bar.trackBackground
                )
            }

            if bar.showArrows {
                let arrows = bar.resolvedArrowGlyphs()
                let sRect = bar.startArrowRect
                if sRect.width >= 1 && sRect.height >= 1 {
                    buffer.drawText(
                        arrows.startGlyph,
                        x: sRect.x,
                        y: sRect.y,
                        fg: arrows.fg,
                        bg: arrows.bg,
                        attributes: arrows.attributes
                    )
                }
                let eRect = bar.endArrowRect
                if eRect.width >= 1 && eRect.height >= 1 {
                    buffer.drawText(
                        arrows.endGlyph,
                        x: eRect.x,
                        y: eRect.y,
                        fg: arrows.fg,
                        bg: arrows.bg,
                        attributes: arrows.attributes
                    )
                }
            }

            let hitRect = bar.barRect
            if hitRect.width > 0 && hitRect.height > 0 {
                ctx.addToHitGrid(x: hitRect.x, y: hitRect.y, width: hitRect.width, height: hitRect.height, id: num)
            }
        }
    }

    open override func renderChildren(buffer: OptimizedBuffer, deltaTime: Double) {
        guard !_childrenInLayoutOrder.isEmpty else { return }

        let childrenToRender: [Renderable]
        if _viewportCulling {
            let bounds = ViewportBounds(
                x: viewportRect.x,
                y: viewportRect.y,
                width: viewportRect.width,
                height: viewportRect.height
            )
            let axis: ViewportDirection = content.isRowPrimaryAxis ? .row : .column
            let culled = getObjectsInViewport(
                viewport: bounds,
                objects: getChildrenSortedByPrimaryAxis(),
                direction: axis,
                padding: 0,
                minTriggerSize: 1
            )
            childrenToRender = culled
        } else {
            if _childrenInLayoutOrder.count == 1 {
                childrenToRender = _childrenInLayoutOrder
            } else {
                childrenToRender = _childrenInLayoutOrder
                    .enumerated()
                    .sorted { lhs, rhs in
                        if lhs.element._zIndex != rhs.element._zIndex {
                            return lhs.element._zIndex < rhs.element._zIndex
                        }
                        return lhs.offset < rhs.offset
                    }
                    .map(\.element)
            }
        }

        for child in childrenToRender {
            if !_isDestroyed && child._visible && !child._isDestroyed {
                child.render(buffer: buffer, deltaTime: deltaTime)
            }
        }
    }

    // MARK: - Mouse Wheel, Scrollbar Interaction & Keyboard

    private static func toWheelDirection(_ direction: ScrollDirection?) -> WheelDirection? {
        guard let direction else { return nil }
        switch direction {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        }
    }

    private func scrollByWheel(_ event: MouseEvent) -> Bool {
        let dir = wheelDirection(
            direction: Self.toWheelDirection(event.scroll?.direction),
            shift: event.modifiers.shift
        )
        guard let dir else { return false }

        let vertical = (dir == .up || dir == .down)
        let axis = vertical ? 1 : 0
        let sign: Double = (dir == .up || dir == .left) ? -1.0 : 1.0
        let position = axis == 1 ? _scrollTop : _scrollLeft
        let maxPos = axis == 1 ? _maxScrollY : _maxScrollX

        if sign < 0 ? (position <= 0) : (position >= maxPos) {
            return false
        }

        var remainder = vertical ? scrollAccumulatorY : scrollAccumulatorX
        if remainder * sign < 0 {
            remainder = 0
        }
        let delta = Double(event.scroll?.delta ?? 1)
        let multiplier = _scrollAccel.tick(now: ctx.clock.now())
        remainder += sign * delta * multiplier

        let step = Int(remainder.rounded(.towardZero))
        if step != 0 {
            scrollAxis(axis, to: Double(position + step), relative: false)
        }
        let newPosition = axis == 1 ? _scrollTop : _scrollLeft
        remainder = (newPosition - position == step) ? (remainder - Double(step)) : 0
        if vertical {
            scrollAccumulatorY = remainder
        } else {
            scrollAccumulatorX = remainder
        }
        return true
    }

    open override func onMouseEvent(_ event: MouseEvent) {
        if event.type == .scroll {
            _ = scrollOnce(event: event.scrollChainToken, scroller: self) {
                self.scrollByWheel(event)
            }
        }

        if handleBarMouse(event) {
            return
        }

        if event.type == .drag && event.isDragging {
            updateAutoScroll(mouseX: event.x, mouseY: event.y)
        } else if event.type == .up {
            stopAutoScroll()
        }
    }

    private func rectContains(_ rect: LayoutRect, x: Int, y: Int) -> Bool {
        x >= rect.x && x < rect.x + rect.width && y >= rect.y && y < rect.y + rect.height
    }

    private func handleBarMouse(_ event: MouseEvent) -> Bool {
        if let press = barPress, (event.type == .drag || event.type == .up || event.type == .dragEnd) {
            if case .thumb(let axis, let offset, let lastPointer) = press, event.type != .dragEnd {
                dragThumb(axis: axis, offset: offset, lastPointer: lastPointer, event: event)
            }
            if event.type == .up {
                endBarPress()
            }
            event.stopPropagation()
            return true
        }

        guard event.type == .down, event.button == MouseButton.left.rawValue, event.target === self else {
            return false
        }

        for bar in [verticalScrollBar!, horizontalScrollBar!] where bar.isVisibleCalculated {
            let arrowDir: Double
            if bar.showArrows {
                if rectContains(bar.startArrowRect, x: event.x, y: event.y) {
                    arrowDir = -1
                } else if rectContains(bar.endArrowRect, x: event.x, y: event.y) {
                    arrowDir = 1
                } else {
                    arrowDir = 0
                }
            } else {
                arrowDir = 0
            }

            if arrowDir == 0 && !rectContains(bar.trackRect, x: event.x, y: event.y) {
                continue
            }

            event.stopPropagation()
            event.preventDefault()
            endBarPress()
            if arrowDir != 0 {
                pressArrow(axis: bar.axis, direction: arrowDir, bar: bar)
            } else {
                pressTrack(axis: bar.axis, bar: bar, event: event)
            }
            return true
        }

        return false
    }

    private func pressArrow(axis: Int, direction: Double, bar: ScrollBoxBar) {
        func scheduleStep(amount: Double, delay: Double) {
            bar.scrollBy(direction * amount, unit: .viewport)
            guard case .arrow(let activeAxis, let activeDir, _) = barPress,
                  activeAxis == axis && activeDir == direction,
                  !_isDestroyed
            else {
                return
            }
            let handle = ctx.clock.setTimeout({ [weak self, weak bar] in
                guard let self, bar != nil, !self._isDestroyed else { return }
                scheduleStep(amount: delay == 500 ? 0.5 : 0.2, delay: 200)
            }, delayMs: delay)
            barPress = .arrow(axis: axis, direction: direction, timer: handle)
        }

        barPress = .arrow(axis: axis, direction: direction, timer: nil)
        scheduleStep(amount: 0.5, delay: 500)
    }

    private func thumbPointer(axis: Int, bar: ScrollBoxBar, event: MouseEvent) -> (at: Double, length: Double, start: Double, size: Double) {
        let track = bar.trackRect
        let along = axis == 1 ? (event.y - track.y) : (event.x - track.x)
        let length = axis == 1 ? track.height : track.width
        let maxVal = axis == 1 ? Double(_maxScrollY) : Double(_maxScrollX)
        let curVal = axis == 1 ? Double(_scrollTop) : Double(_scrollLeft)
        let thumb = computeSliderThumb(
            orientation: bar.orientation,
            min: 0,
            max: maxVal,
            value: curVal,
            viewPortSize: Swift.max(1.0, bar.viewportSize),
            width: track.width,
            height: track.height
        )
        return (
            at: Double(Swift.max(0, Swift.min(length, along))) * 2.0,
            length: Double(length) * 2.0,
            start: thumb.start,
            size: thumb.size
        )
    }

    private func pressTrack(axis: Int, bar: ScrollBoxBar, event: MouseEvent) {
        var thumb = thumbPointer(axis: axis, bar: bar, event: event)
        let thumbMin = (thumb.start / 2.0).rounded(.down) * 2.0
        let thumbMax = ((thumb.start + thumb.size) / 2.0).rounded(.up) * 2.0
        let inThumb = thumb.at >= thumbMin && thumb.at < thumbMax

        if !inThumb {
            let maxVal = Double(axis == 1 ? _maxScrollY : _maxScrollX)
            let target = thumb.length == 0 ? 0.0 : (thumb.at / thumb.length) * maxVal
            scrollAxis(axis, to: target, relative: false)
            guard !_isDestroyed else { return }
            thumb = thumbPointer(axis: axis, bar: bar, event: event)
        }

        let maxVal = Double(axis == 1 ? _maxScrollY : _maxScrollX)
        let curVal = Double(axis == 1 ? _scrollTop : _scrollLeft)
        let start = maxVal == 0 ? 0.0 : (curVal / maxVal) * Swift.max(0.0, thumb.length - thumb.size)
        let offset = Swift.max(0.0, Swift.min(thumb.size, thumb.at - start))
        barPress = .thumb(axis: axis, offset: offset, lastPointer: thumb.at)
    }

    private func dragThumb(axis: Int, offset: Double, lastPointer: Double, event: MouseEvent) {
        let bar = axis == 1 ? verticalScrollBar! : horizontalScrollBar!
        let thumb = thumbPointer(axis: axis, bar: bar, event: event)
        guard thumb.at != lastPointer else { return }
        barPress = .thumb(axis: axis, offset: offset, lastPointer: thumb.at)
        let span = Swift.max(0.0, thumb.length - thumb.size)
        let start = Swift.max(0.0, Swift.min(span, thumb.at - offset))
        let maxVal = Double(axis == 1 ? _maxScrollY : _maxScrollX)
        scrollAxis(axis, to: span == 0 ? 0.0 : (start / span) * maxVal, relative: false)
    }

    private func endBarPress() {
        guard let press = barPress else { return }
        barPress = nil
        if case .arrow(_, _, let timer) = press, let timer {
            ctx.clock.clearTimeout(timer)
        }
    }

    // parity: core/src/renderables/ScrollBox.ts#ScrollBoxRenderable.handleKeyPress [status=implemented hash=caf37a5efe74]
    @discardableResult
    open override func handleKeyPress(_ key: KeyEvent) -> Bool {
        if verticalScrollBar.handleKeyPress(key) || horizontalScrollBar.handleKeyPress(key) {
            _scrollAccel.reset()
            scrollAccumulatorX = 0
            scrollAccumulatorY = 0
            return true
        }
        return false
    }

    // MARK: - Drag Selection Auto-Scroll

    open override func onUpdate(deltaTime: Double) {
        handleAutoScroll(deltaTime: deltaTime)
    }

    // parity: core/src/renderables/ScrollBox.ts#ScrollBoxRenderable.startAutoScroll [status=implemented hash=0cee6b4965df]
    public func startAutoScroll(mouseX: Int, mouseY: Int) {
        guard !_isDestroyed else { return }
        stopAutoScroll()
        autoScrollMouseX = mouseX
        autoScrollMouseY = mouseY
        cachedAutoScrollSpeed = getAutoScrollSpeed(mouseX: mouseX, mouseY: mouseY)
        autoScrollOwner = draggingSelection()
        isAutoScrolling = true
        live = true
        if let cli = ctx as? CliRenderer {
            selectionListenerToken = cli.onSelection { [weak self] _ in
                self?.stopAutoScroll()
            }
        }
    }

    // parity: core/src/renderables/ScrollBox.ts#ScrollBoxRenderable.updateAutoScroll [status=implemented hash=2fa59dba7753]
    public func updateAutoScroll(mouseX: Int, mouseY: Int) {
        autoScrollMouseX = mouseX
        autoScrollMouseY = mouseY
        cachedAutoScrollSpeed = getAutoScrollSpeed(mouseX: mouseX, mouseY: mouseY)

        let dirX = getAutoScrollDirectionX(mouseX: mouseX)
        let dirY = getAutoScrollDirectionY(mouseY: mouseY)

        if dirX == 0 && dirY == 0 {
            stopAutoScroll()
        } else if !isAutoScrolling || autoScrollOwner !== draggingSelection() {
            startAutoScroll(mouseX: mouseX, mouseY: mouseY)
        }
    }

    // parity: core/src/renderables/ScrollBox.ts#ScrollBoxRenderable.stopAutoScroll [status=implemented hash=2294cc0a460e]
    public func stopAutoScroll() {
        let wasActive = isAutoScrolling
        isAutoScrolling = false
        autoScrollOwner = nil
        autoScrollAccumulatorX = 0
        autoScrollAccumulatorY = 0
        if wasActive {
            if let token = selectionListenerToken, let cli = ctx as? CliRenderer {
                cli.off(token)
            }
            selectionListenerToken = nil
            live = false
        }
    }

    private func draggingSelection() -> Selection? {
        guard let sel = ctx.getSelection(), sel.isDragging else { return nil }
        return sel
    }

    private func handleAutoScroll(deltaTime: Double) {
        guard isAutoScrolling else { return }
        if let owner = autoScrollOwner, !owner.isDragging {
            stopAutoScroll()
            return
        }

        let dirX = getAutoScrollDirectionX(mouseX: autoScrollMouseX)
        let dirY = getAutoScrollDirectionY(mouseY: autoScrollMouseY)
        let scrollAmount = cachedAutoScrollSpeed * (deltaTime / 1000.0)
        var scrolled = false

        if dirX != 0 {
            autoScrollAccumulatorX += Double(dirX) * scrollAmount
            let stepX = Int(autoScrollAccumulatorX.rounded(.towardZero))
            if stepX != 0 {
                scrollLeft += stepX
                guard !_isDestroyed else { return }
                autoScrollAccumulatorX -= Double(stepX)
                scrolled = true
            }
        }

        if dirY != 0 {
            autoScrollAccumulatorY += Double(dirY) * scrollAmount
            let stepY = Int(autoScrollAccumulatorY.rounded(.towardZero))
            if stepY != 0 {
                scrollTop += stepY
                guard !_isDestroyed else { return }
                autoScrollAccumulatorY -= Double(stepY)
                scrolled = true
            }
        }

        if scrolled {
            ctx.requestSelectionUpdate()
        }
        if dirX == 0 && dirY == 0 {
            stopAutoScroll()
        }
    }

    private func getAutoScrollDirectionX(mouseX: Int) -> Int {
        let relativeX = mouseX - x
        let distToLeft = relativeX
        let distToRight = width - relativeX
        if distToLeft <= autoScrollThresholdHorizontal {
            return _scrollLeft > 0 ? -1 : 0
        } else if distToRight <= autoScrollThresholdHorizontal {
            return _scrollLeft < _maxScrollX ? 1 : 0
        }
        return 0
    }

    private func getAutoScrollDirectionY(mouseY: Int) -> Int {
        let relativeY = mouseY - y
        let distToTop = relativeY
        let distToBottom = height - relativeY
        if distToTop <= autoScrollThresholdVertical {
            return _scrollTop > 0 ? -1 : 0
        } else if distToBottom <= autoScrollThresholdVertical {
            return _scrollTop < _maxScrollY ? 1 : 0
        }
        return 0
    }

    private func getAutoScrollSpeed(mouseX: Int, mouseY: Int) -> Double {
        let relativeX = mouseX - x
        let relativeY = mouseY - y
        let distToLeft = relativeX
        let distToRight = width - relativeX
        let distToTop = relativeY
        let distToBottom = height - relativeY
        let minDist = Swift.min(Swift.min(distToLeft, distToRight), Swift.min(distToTop, distToBottom))
        if minDist <= 1 { return autoScrollSpeedFast }
        if minDist <= 2 { return autoScrollSpeedMedium }
        return autoScrollSpeedSlow
    }

    open override func destroySelf() {
        layoutCallbacks.removeAll()
        endBarPress()
        stopAutoScroll()
        contentLayoutNode.reset()
        super.destroySelf()
    }
}
