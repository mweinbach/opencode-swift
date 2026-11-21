import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout
import Synchronization

// MARK: - Renderer & Context Shared Types

/// Terminal cursor visual shape, matching `core/src/types.ts#CursorStyle`.
// parity: core/src/types.ts#CursorStyle [status=implemented hash=75520a57ae05]
public enum CursorStyle: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case block
    case line
    case underline
    case `default`

    public var renderStyle: CursorRenderStyle {
        switch self {
        case .block: return .block
        case .line: return .line
        case .underline: return .underline
        case .default: return .default
        }
    }
}

/// Terminal mouse pointer cursor shape, matching `core/src/types.ts#MousePointerStyle`.
// parity: core/src/types.ts#MousePointerStyle [status=implemented hash=ff367afca416]
public enum MousePointerStyle: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case auto
    case `default`
    case none
    case contextMenu = "context-menu"
    case help
    case pointer
    case progress
    case wait
    case cell
    case crosshair
    case text
    case verticalText = "vertical-text"
    case alias
    case copy
    case move
    case noDrop = "no-drop"
    case notAllowed = "not-allowed"
    case grab
    case grabbing
    case allScroll = "all-scroll"
    case colResize = "col-resize"
    case rowResize = "row-resize"
    case nResize = "n-resize"
    case eResize = "e-resize"
    case sResize = "s-resize"
    case wResize = "w-resize"
    case neResize = "ne-resize"
    case nwResize = "nw-resize"
    case seResize = "se-resize"
    case swResize = "sw-resize"
    case ewResize = "ew-resize"
    case nsResize = "ns-resize"
    case neswResize = "nesw-resize"
    case nwseResize = "nwse-resize"
    case zoomIn = "zoom-in"
    case zoomOut = "zoom-out"
}

/// Options for configuring terminal cursor style, blinking, color, and mouse pointer shape.
// parity: core/src/types.ts#CursorStyleOptions [status=implemented hash=baf01295400b]
public struct CursorStyleOptions: Equatable, Hashable, Sendable {
    public var style: CursorStyle?
    public var blinking: Bool?
    public var color: RGBA?
    public var cursor: MousePointerStyle?

    public init(
        style: CursorStyle? = nil,
        blinking: Bool? = nil,
        color: RGBA? = nil,
        cursor: MousePointerStyle? = nil
    ) {
        self.style = style
        self.blinking = blinking
        self.color = color
        self.cursor = cursor
    }
}

// parity: core/src/types.ts#TerminalMultiplexer [status=implemented hash=45e3c7b22309]
public enum TerminalMultiplexer: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case none
    case tmux
    case zellij
    case screen
    case unknown
}

// parity: core/src/types.ts#TerminalCapabilityState [status=implemented hash=05c2cacf590a]
public enum TerminalCapabilityState: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case unknown
    case supported
    case unsupported
}

// parity: core/src/types.ts#ImageRenderProtocol [status=implemented hash=f15bc27e4eda]
public enum ImageRenderProtocol: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case auto
    case kitty
    case sixel
    case blocks
}

// parity: core/src/types.ts#TerminalInfo [status=implemented hash=f6fd76c7526c]
public struct TerminalInfo: Equatable, Hashable, Sendable, Codable {
    public var name: String
    public var version: String
    public var fromXtversion: Bool

    public init(name: String = "", version: String = "", fromXtversion: Bool = false) {
        self.name = name
        self.version = version
        self.fromXtversion = fromXtversion
    }
}

// parity: core/src/types.ts#TerminalCapabilities [status=implemented hash=edf1dd30f8d6]
public struct TerminalCapabilities: Equatable, Hashable, Sendable, Codable {
    public var kittyKeyboard: Bool
    public var kittyGraphics: Bool
    public var rgb: Bool
    public var ansi256: Bool
    public var unicode: WidthMethod
    public var sgrPixels: Bool
    public var colorSchemeUpdates: Bool
    public var explicitWidth: Bool
    public var scaledText: Bool
    public var sixel: Bool
    public var focusTracking: Bool
    public var sync: Bool
    public var bracketedPaste: Bool
    public var hyperlinks: Bool
    public var osc52: Bool
    public var osc52Support: TerminalCapabilityState
    public var notifications: Bool
    public var explicitCursorPositioning: Bool
    public var remote: Bool
    public var programStatus: Bool
    public var multiplexer: TerminalMultiplexer
    public var imageProtocol: ImageRenderProtocol?
    public var terminal: TerminalInfo

    public init(
        kittyKeyboard: Bool = false,
        kittyGraphics: Bool = false,
        rgb: Bool = true,
        ansi256: Bool = true,
        unicode: WidthMethod = .unicode,
        sgrPixels: Bool = false,
        colorSchemeUpdates: Bool = false,
        explicitWidth: Bool = false,
        scaledText: Bool = false,
        sixel: Bool = false,
        focusTracking: Bool = false,
        sync: Bool = true,
        bracketedPaste: Bool = true,
        hyperlinks: Bool = true,
        osc52: Bool = false,
        osc52Support: TerminalCapabilityState = .unknown,
        notifications: Bool = false,
        explicitCursorPositioning: Bool = false,
        remote: Bool = false,
        programStatus: Bool = false,
        multiplexer: TerminalMultiplexer = .none,
        imageProtocol: ImageRenderProtocol? = nil,
        terminal: TerminalInfo = TerminalInfo()
    ) {
        self.kittyKeyboard = kittyKeyboard
        self.kittyGraphics = kittyGraphics
        self.rgb = rgb
        self.ansi256 = ansi256
        self.unicode = unicode
        self.sgrPixels = sgrPixels
        self.colorSchemeUpdates = colorSchemeUpdates
        self.explicitWidth = explicitWidth
        self.scaledText = scaledText
        self.sixel = sixel
        self.focusTracking = focusTracking
        self.sync = sync
        self.bracketedPaste = bracketedPaste
        self.hyperlinks = hyperlinks
        self.osc52 = osc52
        self.osc52Support = osc52Support
        self.notifications = notifications
        self.explicitCursorPositioning = explicitCursorPositioning
        self.remote = remote
        self.programStatus = programStatus
        self.multiplexer = multiplexer
        self.imageProtocol = imageProtocol
        self.terminal = terminal
    }
}

/// Captured structured frame snapshot returned by `CliRenderer.captureSpans()` and `TestRenderer.captureSpans()`.
// parity: core/src/types.ts#CapturedFrame [status=implemented hash=67b5b7b4ce25]
public struct CapturedFrame: Equatable, Hashable, Sendable, Codable {
    public var cols: Int
    public var rows: Int
    public var cursor: [Int]
    public var lines: [CapturedLine]

    public var cursorX: Int { cursor.count > 0 ? cursor[0] : 0 }
    public var cursorY: Int { cursor.count > 1 ? cursor[1] : 0 }

    public init(cols: Int, rows: Int, cursor: [Int], lines: [CapturedLine]) {
        self.cols = cols
        self.rows = rows
        self.cursor = cursor
        self.lines = lines
    }
}

// parity: core/src/types.ts#AnimationTickCallback [status=implemented hash=7075bddac891]
public typealias AnimationTickCallback = (_ deltaTime: Double, _ ticks: Int, _ time: Double) -> Void

// parity: core/src/types.ts#AnimationTickOptions [status=implemented hash=f33af92b9173]
public struct AnimationTickOptions: Equatable, Hashable, Sendable {
    public var tolerance: Double?

    public init(tolerance: Double? = nil) {
        self.tolerance = tolerance
    }
}

public typealias FrameRequestCallback = (_ deltaTime: Double) -> Void

// MARK: - RenderContext

/// Host context interface passed to every `Renderable` node, implemented by `CliRenderer`.
// parity: core/src/types.ts#RenderContext [status=adapted hash=03b893678b3c]
public protocol RenderContext: AnyObject {
    var width: Int { get }
    var height: Int { get }
    var terminalWidth: Int { get }
    var terminalHeight: Int { get }
    var resolution: PixelResolution? { get }
    var frameId: Int { get }
    var clock: any Clock { get }
    var keyInput: KeyHandler { get }
    var internalKeyInput: InternalKeyHandler { get }
    var widthMethod: WidthMethod { get }
    var capabilities: TerminalCapabilities? { get }
    var graphemePool: GraphemePool { get }
    var linkPool: LinkPool { get }
    var themeMode: ThemeMode? { get }
    var hasSelection: Bool { get }
    var selection: Selection? { get }
    var currentFocusedRenderable: Renderable? { get }

    func requestRender()
    @discardableResult
    func requestAnimationFrame(_ callback: @escaping FrameRequestCallback) -> Int
    func cancelAnimationFrame(_ handle: Int)
    func setCursorPosition(x: Int, y: Int, visible: Bool)
    func setCursorStyle(_ options: CursorStyleOptions)
    func setCursorColor(_ color: RGBA)
    func setMousePointer(_ shape: MousePointerStyle)
    func requestLive()
    func dropLive()
    @discardableResult
    func onAnimationTick(
        fps: Double,
        callback: @escaping AnimationTickCallback,
        options: AnimationTickOptions
    ) -> () -> Void

    func getSelection() -> Selection?
    func requestSelectionUpdate()
    func clearSelection()
    func startSelection(_ renderable: Renderable, x: Int, y: Int, behavior: SelectionBehavior)
    func updateSelection(_ currentRenderable: Renderable?, x: Int, y: Int, finishDragging: Bool)

    func focusRenderable(_ renderable: Renderable)
    func blurRenderable(_ renderable: Renderable)

    func addToHitGrid(x: Int, y: Int, width: Int, height: Int, id: UInt32)

    func registerLifecyclePass(_ renderable: Renderable)
    func unregisterLifecyclePass(_ renderable: Renderable)
    func getLifecyclePasses() -> [Renderable]
}

public extension RenderContext {
    @discardableResult
    func onAnimationTick(
        fps: Double,
        callback: @escaping AnimationTickCallback
    ) -> () -> Void {
        onAnimationTick(fps: fps, callback: callback, options: AnimationTickOptions())
    }

    func startSelection(_ renderable: Renderable, x: Int, y: Int) {
        startSelection(renderable, x: x, y: y, behavior: .cell)
    }

    func updateSelection(_ currentRenderable: Renderable?, x: Int, y: Int) {
        updateSelection(currentRenderable, x: x, y: y, finishDragging: false)
    }
}

// MARK: - Events & Option Types

// parity: core/src/Renderable.ts#LayoutEvents [status=implemented hash=da8a4990d7b5]
public enum LayoutEvents: String, Equatable, Hashable, Sendable {
    case layoutChanged = "layout-changed"
    case resized = "resized"
}

// parity: core/src/Renderable.ts#RenderableEvents [status=implemented hash=45ab0e17c593]
public enum RenderableEvents: String, Equatable, Hashable, Sendable {
    case focused = "focused"
    case blurred = "blurred"
    case destroyed = "destroyed"
}

// parity: core/src/Renderable.ts#Position [status=implemented hash=c2102507c15e]
public struct Position: Equatable, Hashable, Sendable {
    public var top: FlexValue?
    public var right: FlexValue?
    public var bottom: FlexValue?
    public var left: FlexValue?

    public init(
        top: FlexValue? = nil,
        right: FlexValue? = nil,
        bottom: FlexValue? = nil,
        left: FlexValue? = nil
    ) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
    }
}

// parity: core/src/Renderable.ts#BaseRenderableOptions [status=implemented hash=18548dae09d6]
public struct BaseRenderableOptions: Equatable, Hashable, Sendable {
    public var id: String?

    public init(id: String? = nil) {
        self.id = id
    }
}

// parity: core/src/Renderable.ts#LayoutOptions [status=implemented hash=1358469f3b88]
public struct LayoutOptions: Equatable, Hashable, Sendable {
    public var id: String?
    public var width: FlexValue?
    public var height: FlexValue?
    public var minWidth: FlexValue?
    public var maxWidth: FlexValue?
    public var minHeight: FlexValue?
    public var maxHeight: FlexValue?
    public var flexGrow: Float?
    public var flexShrink: Float?
    public var flexBasis: FlexValue?
    public var flexDirection: FlexDirection?
    public var flexWrap: Wrap?
    public var layoutMode: LayoutMode?
    public var alignItems: Align?
    public var alignSelf: Align?
    public var alignContent: Align?
    public var justifyContent: Justify?
    public var position: PositionType?
    public var top: FlexValue?
    public var right: FlexValue?
    public var bottom: FlexValue?
    public var left: FlexValue?
    public var margin: FlexValue?
    public var marginX: FlexValue?
    public var marginY: FlexValue?
    public var marginTop: FlexValue?
    public var marginRight: FlexValue?
    public var marginBottom: FlexValue?
    public var marginLeft: FlexValue?
    public var padding: FlexValue?
    public var paddingX: FlexValue?
    public var paddingY: FlexValue?
    public var paddingTop: FlexValue?
    public var paddingRight: FlexValue?
    public var paddingBottom: FlexValue?
    public var paddingLeft: FlexValue?
    public var gap: FlexValue?
    public var rowGap: FlexValue?
    public var columnGap: FlexValue?
    public var overflow: Overflow?
    public var display: Display?
    public var aspectRatio: Float?
    public var boxSizing: BoxSizing?
    public var enableLayout: Bool?

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
        flexWrap: Wrap? = nil,
        layoutMode: LayoutMode? = nil,
        alignItems: Align? = nil,
        alignSelf: Align? = nil,
        alignContent: Align? = nil,
        justifyContent: Justify? = nil,
        position: PositionType? = nil,
        top: FlexValue? = nil,
        right: FlexValue? = nil,
        bottom: FlexValue? = nil,
        left: FlexValue? = nil,
        margin: FlexValue? = nil,
        marginX: FlexValue? = nil,
        marginY: FlexValue? = nil,
        marginTop: FlexValue? = nil,
        marginRight: FlexValue? = nil,
        marginBottom: FlexValue? = nil,
        marginLeft: FlexValue? = nil,
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
        overflow: Overflow? = nil,
        display: Display? = nil,
        aspectRatio: Float? = nil,
        boxSizing: BoxSizing? = nil,
        enableLayout: Bool? = nil
    ) {
        self.id = id
        self.width = width
        self.height = height
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        self.flexGrow = flexGrow
        self.flexShrink = flexShrink
        self.flexBasis = flexBasis
        self.flexDirection = flexDirection
        self.flexWrap = flexWrap
        self.layoutMode = layoutMode
        self.alignItems = alignItems
        self.alignSelf = alignSelf
        self.alignContent = alignContent
        self.justifyContent = justifyContent
        self.position = position
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
        self.margin = margin
        self.marginX = marginX
        self.marginY = marginY
        self.marginTop = marginTop
        self.marginRight = marginRight
        self.marginBottom = marginBottom
        self.marginLeft = marginLeft
        self.padding = padding
        self.paddingX = paddingX
        self.paddingY = paddingY
        self.paddingTop = paddingTop
        self.paddingRight = paddingRight
        self.paddingBottom = paddingBottom
        self.paddingLeft = paddingLeft
        self.gap = gap
        self.rowGap = rowGap
        self.columnGap = columnGap
        self.overflow = overflow
        self.display = display
        self.aspectRatio = aspectRatio
        self.boxSizing = boxSizing
        self.enableLayout = enableLayout
    }
}

/// Complete layout, visibility, rendering, and event-handler options for initializing a `Renderable`.
// parity: core/src/Renderable.ts#RenderableOptions [status=implemented hash=c7716d789bb9]
public struct RenderableOptions {
    public var id: String?
    public var width: FlexValue?
    public var height: FlexValue?
    public var minWidth: FlexValue?
    public var maxWidth: FlexValue?
    public var minHeight: FlexValue?
    public var maxHeight: FlexValue?
    public var flexGrow: Float?
    public var flexShrink: Float?
    public var flexBasis: FlexValue?
    public var flexDirection: FlexDirection?
    public var flexWrap: Wrap?
    public var layoutMode: LayoutMode?
    public var alignItems: Align?
    public var alignSelf: Align?
    public var alignContent: Align?
    public var justifyContent: Justify?
    public var position: PositionType?
    public var top: FlexValue?
    public var right: FlexValue?
    public var bottom: FlexValue?
    public var left: FlexValue?
    public var margin: FlexValue?
    public var marginX: FlexValue?
    public var marginY: FlexValue?
    public var marginTop: FlexValue?
    public var marginRight: FlexValue?
    public var marginBottom: FlexValue?
    public var marginLeft: FlexValue?
    public var padding: FlexValue?
    public var paddingX: FlexValue?
    public var paddingY: FlexValue?
    public var paddingTop: FlexValue?
    public var paddingRight: FlexValue?
    public var paddingBottom: FlexValue?
    public var paddingLeft: FlexValue?
    public var gap: FlexValue?
    public var rowGap: FlexValue?
    public var columnGap: FlexValue?
    public var overflow: Overflow?
    public var display: Display?
    public var aspectRatio: Float?
    public var boxSizing: BoxSizing?
    public var zIndex: Int?
    public var visible: Bool?
    public var opacity: Double?
    public var live: Bool?
    public var animationFps: Double?
    public var focusable: Bool?
    public var selectable: Bool?
    public var buffered: Bool?

    public var renderBefore: ((OptimizedBuffer, Double) -> Void)?
    public var renderAfter: ((OptimizedBuffer, Double) -> Void)?

    public var onMouse: ((MouseEvent) -> Void)?
    public var onMouseDown: ((MouseEvent) -> Void)?
    public var onMouseUp: ((MouseEvent) -> Void)?
    public var onMouseMove: ((MouseEvent) -> Void)?
    public var onMouseDrag: ((MouseEvent) -> Void)?
    public var onMouseDragEnd: ((MouseEvent) -> Void)?
    public var onMouseDrop: ((MouseEvent) -> Void)?
    public var onMouseOver: ((MouseEvent) -> Void)?
    public var onMouseOut: ((MouseEvent) -> Void)?
    public var onMouseScroll: ((MouseEvent) -> Void)?

    public var onKeyDown: ((KeyEvent) -> Void)?
    public var onPaste: ((PasteEvent) -> Void)?
    public var onSizeChange: (() -> Void)?
    public var onLifecyclePass: (() -> Void)?

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
        flexWrap: Wrap? = nil,
        layoutMode: LayoutMode? = nil,
        alignItems: Align? = nil,
        alignSelf: Align? = nil,
        alignContent: Align? = nil,
        justifyContent: Justify? = nil,
        position: PositionType? = nil,
        top: FlexValue? = nil,
        right: FlexValue? = nil,
        bottom: FlexValue? = nil,
        left: FlexValue? = nil,
        margin: FlexValue? = nil,
        marginX: FlexValue? = nil,
        marginY: FlexValue? = nil,
        marginTop: FlexValue? = nil,
        marginRight: FlexValue? = nil,
        marginBottom: FlexValue? = nil,
        marginLeft: FlexValue? = nil,
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
        overflow: Overflow? = nil,
        display: Display? = nil,
        aspectRatio: Float? = nil,
        boxSizing: BoxSizing? = nil,
        zIndex: Int? = nil,
        visible: Bool? = nil,
        opacity: Double? = nil,
        live: Bool? = nil,
        animationFps: Double? = nil,
        focusable: Bool? = nil,
        selectable: Bool? = nil,
        buffered: Bool? = nil,
        renderBefore: ((OptimizedBuffer, Double) -> Void)? = nil,
        renderAfter: ((OptimizedBuffer, Double) -> Void)? = nil,
        onMouse: ((MouseEvent) -> Void)? = nil,
        onMouseDown: ((MouseEvent) -> Void)? = nil,
        onMouseUp: ((MouseEvent) -> Void)? = nil,
        onMouseMove: ((MouseEvent) -> Void)? = nil,
        onMouseDrag: ((MouseEvent) -> Void)? = nil,
        onMouseDragEnd: ((MouseEvent) -> Void)? = nil,
        onMouseDrop: ((MouseEvent) -> Void)? = nil,
        onMouseOver: ((MouseEvent) -> Void)? = nil,
        onMouseOut: ((MouseEvent) -> Void)? = nil,
        onMouseScroll: ((MouseEvent) -> Void)? = nil,
        onKeyDown: ((KeyEvent) -> Void)? = nil,
        onPaste: ((PasteEvent) -> Void)? = nil,
        onSizeChange: (() -> Void)? = nil,
        onLifecyclePass: (() -> Void)? = nil
    ) {
        self.id = id
        self.width = width
        self.height = height
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        self.flexGrow = flexGrow
        self.flexShrink = flexShrink
        self.flexBasis = flexBasis
        self.flexDirection = flexDirection
        self.flexWrap = flexWrap
        self.layoutMode = layoutMode
        self.alignItems = alignItems
        self.alignSelf = alignSelf
        self.alignContent = alignContent
        self.justifyContent = justifyContent
        self.position = position
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
        self.margin = margin
        self.marginX = marginX
        self.marginY = marginY
        self.marginTop = marginTop
        self.marginRight = marginRight
        self.marginBottom = marginBottom
        self.marginLeft = marginLeft
        self.padding = padding
        self.paddingX = paddingX
        self.paddingY = paddingY
        self.paddingTop = paddingTop
        self.paddingRight = paddingRight
        self.paddingBottom = paddingBottom
        self.paddingLeft = paddingLeft
        self.gap = gap
        self.rowGap = rowGap
        self.columnGap = columnGap
        self.overflow = overflow
        self.display = display
        self.aspectRatio = aspectRatio
        self.boxSizing = boxSizing
        self.zIndex = zIndex
        self.visible = visible
        self.opacity = opacity
        self.live = live
        self.animationFps = animationFps
        self.focusable = focusable
        self.selectable = selectable
        self.buffered = buffered
        self.renderBefore = renderBefore
        self.renderAfter = renderAfter
        self.onMouse = onMouse
        self.onMouseDown = onMouseDown
        self.onMouseUp = onMouseUp
        self.onMouseMove = onMouseMove
        self.onMouseDrag = onMouseDrag
        self.onMouseDragEnd = onMouseDragEnd
        self.onMouseDrop = onMouseDrop
        self.onMouseOver = onMouseOver
        self.onMouseOut = onMouseOut
        self.onMouseScroll = onMouseScroll
        self.onKeyDown = onKeyDown
        self.onPaste = onPaste
        self.onSizeChange = onSizeChange
        self.onLifecyclePass = onLifecyclePass
    }
}

// MARK: - Internal Number Registry (Swift 6 Safe)

private struct WeakRenderableRef: @unchecked Sendable {
    weak var value: Renderable?
}

private final class RenderableNumberRegistry: Sendable {
    private struct State: @unchecked Sendable {
        var nextNumber: UInt32 = 1
        var byNumber: [UInt32: WeakRenderableRef] = [:]
    }

    private let state = Mutex(State())

    func allocateNumber() -> UInt32 {
        state.withLock { s in
            let num = s.nextNumber
            s.nextNumber &+= 1
            if s.nextNumber == 0 { s.nextNumber = 1 }
            return num
        }
    }

    func register(_ renderable: Renderable) {
        let num = renderable.num
        let ref = WeakRenderableRef(value: renderable)
        state.withLock { s in
            s.byNumber[num] = ref
        }
    }

    func unregister(_ num: UInt32) {
        _ = state.withLock { s in
            s.byNumber.removeValue(forKey: num)
        }
    }

    func lookup(_ num: UInt32) -> Renderable? {
        state.withLock { s in
            s.byNumber[num]?.value
        }
    }
}

private let globalRenderableRegistry = RenderableNumberRegistry()

@inline(__always)
private func clampOpacity(_ value: Double?) -> Double {
    guard let value else { return 1.0 }
    if value.isNaN { return 0.0 }
    return max(0.0, min(1.0, value))
}

/// Type check matching `core/src/Renderable.ts#isRenderable`.
// parity: core/src/Renderable.ts#isRenderable [status=implemented hash=b507d7c73b8c]
public func isRenderable(_ obj: Any?) -> Bool {
    obj is Renderable
}

// MARK: - BaseRenderable

/// Lightweight event subscription token returned by `BaseRenderable.on(_:_:)`.
public struct RenderableListenerToken: Equatable, Hashable, Sendable {
    fileprivate let id: UInt64
    fileprivate let event: String
}

/// Abstract base class for OpenTUI scene graph nodes, matching `core/src/Renderable.ts#BaseRenderable`.
// parity: core/src/Renderable.ts#BaseRenderable [status=adapted hash=d3bc9bb76c4f]
open class BaseRenderable: @unchecked Sendable {
    private struct ListenerEntry {
        let id: UInt64
        let handler: () -> Void
    }

    public let num: UInt32
    internal var _id: String
    internal var _dirty: Bool = true
    internal var _visible: Bool = true

    private var nextListenerId: UInt64 = 1
    private var listeners: [String: [ListenerEntry]] = [:]

    public init(options: BaseRenderableOptions = BaseRenderableOptions()) {
        let allocated = globalRenderableRegistry.allocateNumber()
        self.num = allocated
        self._id = options.id ?? "renderable-\(allocated)"
    }

    // parity: core/src/Renderable.ts#BaseRenderable.id [status=implemented hash=9ab61aac742a]
    open var id: String {
        get { _id }
        set { _id = newValue }
    }

    // parity: core/src/Renderable.ts#BaseRenderable.isDirty [status=implemented hash=c38e6d777262]
    public var isDirty: Bool {
        _dirty
    }

    open func markClean() {
        _dirty = false
    }

    open func markDirty() {
        _dirty = true
    }

    // parity: core/src/Renderable.ts#BaseRenderable.visible [status=implemented hash=8ce94ba955be]
    open var visible: Bool {
        get { _visible }
        set { _visible = newValue }
    }

    // parity: core/src/Renderable.ts#BaseRenderable.add [status=implemented hash=ee82ab482c01]
    @discardableResult
    open func add(_ obj: Any, index: Int? = nil) -> Int {
        _ = obj
        _ = index
        return -1
    }

    // parity: core/src/Renderable.ts#BaseRenderable.remove [status=implemented hash=0f7c8a2cab40]
    open func remove(_ child: BaseRenderable) {
        _ = child
    }

    // parity: core/src/Renderable.ts#BaseRenderable.insertBefore [status=implemented hash=70763eba7369]
    open func insertBefore(_ obj: Any, anchor: Any?) {
        _ = obj
        _ = anchor
    }

    // parity: core/src/Renderable.ts#BaseRenderable.getChildren [status=adapted hash=c200a538f8b3]
    open func getBaseChildren() -> [BaseRenderable] {
        []
    }

    // parity: core/src/Renderable.ts#BaseRenderable.getChildrenCount [status=implemented hash=69315b187469]
    open func getChildrenCount() -> Int {
        getBaseChildren().count
    }

    // parity: core/src/Renderable.ts#BaseRenderable.getRenderable [status=adapted hash=d2f3d0dc930b]
    open func getBaseRenderable(_ id: String) -> BaseRenderable? {
        getBaseChildren().first { $0.id == id }
    }

    // parity: core/src/Renderable.ts#BaseRenderable.requestRender [status=implemented hash=fb8e0191faa0]
    open func requestRender() {
        markDirty()
    }

    // parity: core/src/Renderable.ts#BaseRenderable.findDescendantById [status=adapted hash=31264de3b072]
    open func findBaseDescendantById(_ id: String) -> BaseRenderable? {
        for child in getBaseChildren() {
            if child.id == id {
                return child
            }
            if let found = child.findBaseDescendantById(id) {
                return found
            }
        }
        return nil
    }

    // parity: core/src/Renderable.ts#BaseRenderable.destroy [status=implemented hash=7d17e161de2d]
    open func destroy() {}

    // parity: core/src/Renderable.ts#BaseRenderable.destroyRecursively [status=implemented hash=f144330a36b3]
    open func destroyRecursively() {}

    @discardableResult
    public func on(_ event: String, _ listener: @escaping () -> Void) -> RenderableListenerToken {
        let id = nextListenerId
        nextListenerId &+= 1
        listeners[event, default: []].append(ListenerEntry(id: id, handler: listener))
        return RenderableListenerToken(id: id, event: event)
    }

    @discardableResult
    public func on(_ event: RenderableEvents, _ listener: @escaping () -> Void) -> RenderableListenerToken {
        on(event.rawValue, listener)
    }

    @discardableResult
    public func on(_ event: LayoutEvents, _ listener: @escaping () -> Void) -> RenderableListenerToken {
        on(event.rawValue, listener)
    }

    @discardableResult
    public func addListener(_ event: String, _ listener: @escaping () -> Void) -> RenderableListenerToken {
        on(event, listener)
    }

    @discardableResult
    public func prependListener(_ event: String, _ listener: @escaping () -> Void) -> RenderableListenerToken {
        let id = nextListenerId
        nextListenerId &+= 1
        listeners[event, default: []].insert(ListenerEntry(id: id, handler: listener), at: 0)
        return RenderableListenerToken(id: id, event: event)
    }

    public func off(_ token: RenderableListenerToken) {
        listeners[token.event]?.removeAll { $0.id == token.id }
    }

    public func removeListener(_ token: RenderableListenerToken) {
        off(token)
    }

    public func removeAllListeners(for event: String? = nil) {
        if let event {
            listeners.removeValue(forKey: event)
        } else {
            listeners.removeAll()
        }
    }

    public func emit(_ event: String) {
        guard let entries = listeners[event], !entries.isEmpty else { return }
        for entry in entries {
            entry.handler()
        }
    }

    public func emit(_ event: RenderableEvents) {
        emit(event.rawValue)
    }

    public func emit(_ event: LayoutEvents) {
        emit(event.rawValue)
    }
}

// MARK: - Renderable

/// Core layout-backed, event-handling, composable terminal UI node matching `core/src/Renderable.ts#Renderable`.
// parity: core/src/Renderable.ts#Renderable [status=adapted hash=2d7cde06f4c9]
open class Renderable: BaseRenderable, SelectableRenderable, ViewportObject, ScrollChainNode, @unchecked Sendable {
    /// Looks up a live `Renderable` by its hit-grid numeric ID.
    public static func renderable(forNumber num: UInt32) -> Renderable? {
        globalRenderableRegistry.lookup(num)
    }

    /// Underlying pure-Swift Flexbox layout node synchronized with this renderable's style and child tree.
    public let layoutNode: FlexNode

    public let ctx: any RenderContext
    public weak internal(set) var parent: Renderable?

    internal var _childrenInLayoutOrder: [Renderable] = []
    internal var _isDestroyed: Bool = false

    // Geometry & layout cache (integer terminal cells)
    internal var _localX: Int = 0
    internal var _localY: Int = 0
    internal var _screenX: Int = 0
    internal var _screenY: Int = 0
    internal var _computedWidth: Int = 0
    internal var _computedHeight: Int = 0
    internal var _hasComputedLayout: Bool = false

    internal var _translateX: Int = 0
    internal var _translateY: Int = 0
    internal var _zIndex: Int = 0
    internal var _opacity: Double = 1.0
    internal var _displayWhenVisible: Display = .flex
    internal var _layoutMode: LayoutMode = .flex
    internal var _flexShrink: Float = 1

    // Optional offscreen frame buffer for `buffered: true`
    public let buffered: Bool
    public internal(set) var frameBuffer: OptimizedBuffer? = nil

    // Focus, selection, and live-mode state
    internal var _focusable: Bool = false
    internal var _focused: Bool = false
    private var keypressToken: KeyHandlerToken? = nil
    private var pasteToken: KeyHandlerToken? = nil

    public var selectable: Bool = false

    internal var _live: Bool = false
    internal var _liveCount: Int = 0
    internal var _animationFps: Double? = nil
    private var stopAnimationTick: (() -> Void)? = nil
    private var animationDrawnFrame: Int = -1

    // Lifecycle & paint hooks
    private var _builtinLifecyclePass: (() -> Void)? = nil
    private var _onLifecyclePass: (() -> Void)? = nil

    // parity: core/src/Renderable.ts#Renderable.renderBefore [status=implemented hash=a7699b43f941]
    public var renderBefore: ((OptimizedBuffer, Double) -> Void)? = nil
    // parity: core/src/Renderable.ts#Renderable.renderAfter [status=implemented hash=e1b692cbfdba]
    public var renderAfter: ((OptimizedBuffer, Double) -> Void)? = nil

    // Event handler closures
    // parity: core/src/Renderable.ts#Renderable.onMouse [status=implemented hash=8e176adfb731]
    public var onMouse: ((MouseEvent) -> Void)? = nil
    // parity: core/src/Renderable.ts#Renderable.onMouseDown [status=implemented hash=a2f27893fc9e]
    public var onMouseDown: ((MouseEvent) -> Void)? = nil
    // parity: core/src/Renderable.ts#Renderable.onMouseUp [status=implemented hash=45c3c636f12c]
    public var onMouseUp: ((MouseEvent) -> Void)? = nil
    // parity: core/src/Renderable.ts#Renderable.onMouseMove [status=implemented hash=bbcb2906536b]
    public var onMouseMove: ((MouseEvent) -> Void)? = nil
    // parity: core/src/Renderable.ts#Renderable.onMouseDrag [status=implemented hash=616757cda803]
    public var onMouseDrag: ((MouseEvent) -> Void)? = nil
    // parity: core/src/Renderable.ts#Renderable.onMouseDragEnd [status=implemented hash=33533b6aa566]
    public var onMouseDragEnd: ((MouseEvent) -> Void)? = nil
    // parity: core/src/Renderable.ts#Renderable.onMouseDrop [status=implemented hash=721fcf80e5ca]
    public var onMouseDrop: ((MouseEvent) -> Void)? = nil
    // parity: core/src/Renderable.ts#Renderable.onMouseOver [status=implemented hash=cb9552f7466f]
    public var onMouseOver: ((MouseEvent) -> Void)? = nil
    // parity: core/src/Renderable.ts#Renderable.onMouseOut [status=implemented hash=a63ac722c6be]
    public var onMouseOut: ((MouseEvent) -> Void)? = nil
    // parity: core/src/Renderable.ts#Renderable.onMouseScroll [status=implemented hash=564371939a20]
    public var onMouseScroll: ((MouseEvent) -> Void)? = nil

    // parity: core/src/Renderable.ts#Renderable.onKeyDown [status=implemented hash=2aba194f153e]
    public var onKeyDown: ((KeyEvent) -> Void)? = nil
    // parity: core/src/Renderable.ts#Renderable.onPaste [status=implemented hash=1a903e533f52]
    public var onPaste: ((PasteEvent) -> Void)? = nil
    // parity: core/src/Renderable.ts#Renderable.onSizeChange [status=implemented hash=a885baa603c3]
    public var onSizeChange: (() -> Void)? = nil

    /// Whether this node populates the renderer hit-test grid during `render`.
    /// `RootRenderable` overrides this to `false` so empty canvas space hit-tests as `0`.
    open var participatesInHitGrid: Bool { true }

    public init(ctx: any RenderContext, options: RenderableOptions = RenderableOptions()) {
        self.ctx = ctx
        self.layoutNode = FlexNode()
        self.buffered = options.buffered ?? false
        super.init(options: BaseRenderableOptions(id: options.id))

        globalRenderableRegistry.register(self)

        self._zIndex = options.zIndex ?? 0
        self._visible = options.visible ?? true
        self._opacity = clampOpacity(options.opacity)
        self._live = options.live ?? false
        self._liveCount = (self._live && self._visible) ? 1 : 0
        self._focusable = options.focusable ?? false
        self.selectable = options.selectable ?? false
        self._displayWhenVisible = options.display ?? .flex
        self._layoutMode = options.layoutMode ?? .flex

        self.renderBefore = options.renderBefore
        self.renderAfter = options.renderAfter
        self.onMouse = options.onMouse
        self.onMouseDown = options.onMouseDown
        self.onMouseUp = options.onMouseUp
        self.onMouseMove = options.onMouseMove
        self.onMouseDrag = options.onMouseDrag
        self.onMouseDragEnd = options.onMouseDragEnd
        self.onMouseDrop = options.onMouseDrop
        self.onMouseOver = options.onMouseOver
        self.onMouseOut = options.onMouseOut
        self.onMouseScroll = options.onMouseScroll
        self.onKeyDown = options.onKeyDown
        self.onPaste = options.onPaste
        self.onSizeChange = options.onSizeChange
        self._onLifecyclePass = options.onLifecyclePass

        setupLayoutStyle(options)

        if self.buffered {
            createFrameBufferIfNeeded()
        }

        if let fps = options.animationFps {
            self.animationFps = fps
        }
    }

    private func setupLayoutStyle(_ options: RenderableOptions) {
        var style = FlexStyle()
        style.display = _visible ? _displayWhenVisible : .none

        if let width = options.width {
            style.width = width
        }
        if let height = options.height {
            style.height = height
        }
        if let minWidth = options.minWidth { style.minWidth = minWidth }
        if let maxWidth = options.maxWidth { style.maxWidth = maxWidth }
        if let minHeight = options.minHeight { style.minHeight = minHeight }
        if let maxHeight = options.maxHeight { style.maxHeight = maxHeight }

        style.flexGrow = options.flexGrow ?? 0
        if let shrink = options.flexShrink {
            _flexShrink = shrink
            style.flexShrink = shrink
        } else {
            let hasExplicitWidth: Bool
            if case .point = options.width { hasExplicitWidth = true } else { hasExplicitWidth = false }
            let hasExplicitHeight: Bool
            if case .point = options.height { hasExplicitHeight = true } else { hasExplicitHeight = false }
            _flexShrink = (hasExplicitWidth || hasExplicitHeight) ? 0 : 1
            style.flexShrink = _flexShrink
        }

        if let flexBasis = options.flexBasis { style.flexBasis = flexBasis }
        if let flexDirection = options.flexDirection { style.flexDirection = flexDirection }
        if let flexWrap = options.flexWrap { style.flexWrap = flexWrap }
        if let alignItems = options.alignItems { style.alignItems = alignItems }
        if let alignSelf = options.alignSelf { style.alignSelf = alignSelf }
        if let alignContent = options.alignContent { style.alignContent = alignContent }
        if let justifyContent = options.justifyContent { style.justifyContent = justifyContent }
        if let position = options.position { style.positionType = position }
        if let overflow = options.overflow { style.overflow = overflow }
        if let aspectRatio = options.aspectRatio { style.aspectRatio = aspectRatio }
        if let boxSizing = options.boxSizing { style.boxSizing = boxSizing }

        if let top = options.top { style.position.top = top }
        if let right = options.right { style.position.right = right }
        if let bottom = options.bottom { style.position.bottom = bottom }
        if let left = options.left { style.position.left = left }

        if let margin = options.margin { style.margin.all = margin }
        if let marginX = options.marginX { style.margin.horizontal = marginX }
        if let marginY = options.marginY { style.margin.vertical = marginY }
        if let marginTop = options.marginTop { style.margin.top = marginTop }
        if let marginRight = options.marginRight { style.margin.right = marginRight }
        if let marginBottom = options.marginBottom { style.margin.bottom = marginBottom }
        if let marginLeft = options.marginLeft { style.margin.left = marginLeft }

        if let padding = options.padding { style.padding.all = padding }
        if let paddingX = options.paddingX { style.padding.horizontal = paddingX }
        if let paddingY = options.paddingY { style.padding.vertical = paddingY }
        if let paddingTop = options.paddingTop { style.padding.top = paddingTop }
        if let paddingRight = options.paddingRight { style.padding.right = paddingRight }
        if let paddingBottom = options.paddingBottom { style.padding.bottom = paddingBottom }
        if let paddingLeft = options.paddingLeft { style.padding.left = paddingLeft }

        if let gap = options.gap { style.gap.all = gap }
        if let rowGap = options.rowGap { style.gap.row = rowGap }
        if let columnGap = options.columnGap { style.gap.column = columnGap }

        layoutNode.style = style
    }

    // MARK: - ScrollChainNode

    public var scrollChainParent: (any ScrollChainNode)? {
        parent
    }

    // MARK: - Status & Visibility

    // parity: core/src/Renderable.ts#Renderable.isDestroyed [status=implemented hash=13eff164cad8]
    public var isDestroyed: Bool {
        _isDestroyed
    }

    // parity: core/src/Renderable.ts#Renderable.visible [status=implemented hash=8ce94ba955be]
    open override var visible: Bool {
        get { _visible }
        set {
            guard !_isDestroyed, _visible != newValue else { return }
            let wasVisible = _visible
            _visible = newValue
            layoutNode.style.display = newValue ? _displayWhenVisible : .none
            if _live {
                if !wasVisible && newValue {
                    propagateLiveCount(1)
                } else if wasVisible && !newValue {
                    propagateLiveCount(-1)
                }
            }
            updateAnimationTick()
            if _focused && !newValue {
                blur()
            }
            requestRender()
        }
    }

    // parity: core/src/Renderable.ts#Renderable.opacity [status=implemented hash=668c85371681]
    public var opacity: Double {
        get { _opacity }
        set {
            let clamped = clampOpacity(newValue)
            guard _opacity != clamped else { return }
            _opacity = clamped
            requestRender()
        }
    }

    // parity: core/src/Renderable.ts#Renderable.zIndex [status=implemented hash=60991adae798]
    public var zIndex: Int {
        get { _zIndex }
        set {
            guard _zIndex != newValue else { return }
            _zIndex = newValue
            requestRender()
        }
    }

    // parity: core/src/Renderable.ts#Renderable.translateX [status=implemented hash=f1430b7b2ad7]
    public var translateX: Int {
        get { _translateX }
        set {
            guard _translateX != newValue else { return }
            _translateX = newValue
            updateScreenCoordinatesRecursively()
            requestRender()
        }
    }

    // parity: core/src/Renderable.ts#Renderable.translateY [status=implemented hash=72053c925bbe]
    public var translateY: Int {
        get { _translateY }
        set {
            guard _translateY != newValue else { return }
            _translateY = newValue
            updateScreenCoordinatesRecursively()
            requestRender()
        }
    }

    private func updateScreenCoordinatesRecursively() {
        _screenX = (parent?._screenX ?? 0) + _localX + _translateX
        _screenY = (parent?._screenY ?? 0) + _localY + _translateY
        for child in _childrenInLayoutOrder {
            child.updateScreenCoordinatesRecursively()
        }
    }

    // MARK: - Geometry & Layout Properties

    // parity: core/src/Renderable.ts#Renderable.screenX [status=implemented hash=96d80e45737c]
    public var screenX: Int { _screenX }

    // parity: core/src/Renderable.ts#Renderable.screenY [status=implemented hash=90e69f7ffd8d]
    public var screenY: Int { _screenY }

    // parity: core/src/Renderable.ts#Renderable.x [status=implemented hash=b5c7edfe38fb]
    public var x: Int {
        get { _screenX }
        set { left = .point(Float(newValue)) }
    }

    // parity: core/src/Renderable.ts#Renderable.y [status=implemented hash=daeb3268185b]
    public var y: Int {
        get { _screenY }
        set { top = .point(Float(newValue)) }
    }

    private func styledPointDimension(_ value: FlexValue) -> Int {
        if case .point(let v) = value, v.isFinite {
            return max(0, Int(v.rounded(.toNearestOrAwayFromZero)))
        }
        return 0
    }

    // parity: core/src/Renderable.ts#Renderable.width [status=implemented hash=558166fb0a8e]
    public var width: Int {
        get {
            if _hasComputedLayout && _computedWidth > 0 {
                return _computedWidth
            }
            return _computedWidth > 0 ? _computedWidth : styledPointDimension(layoutNode.style.width)
        }
        set {
            setWidth(.point(Float(newValue)))
        }
    }

    // parity: core/src/Renderable.ts#Renderable.height [status=implemented hash=1624042e3c7d]
    public var height: Int {
        get {
            if _hasComputedLayout && _computedHeight > 0 {
                return _computedHeight
            }
            return _computedHeight > 0 ? _computedHeight : styledPointDimension(layoutNode.style.height)
        }
        set {
            setHeight(.point(Float(newValue)))
        }
    }

    public var widthStyle: FlexValue {
        get { layoutNode.style.width }
        set { setWidth(newValue) }
    }

    public var heightStyle: FlexValue {
        get { layoutNode.style.height }
        set { setHeight(newValue) }
    }

    public func setWidth(_ value: FlexValue) {
        guard !_isDestroyed, layoutNode.style.width != value else { return }
        layoutNode.style.width = value
        if case .point = value, _flexShrink == 1 {
            _flexShrink = 0
            layoutNode.style.flexShrink = 0
        }
        requestRender()
    }

    public func setHeight(_ value: FlexValue) {
        guard !_isDestroyed, layoutNode.style.height != value else { return }
        layoutNode.style.height = value
        if case .point = value, _flexShrink == 1 {
            _flexShrink = 0
            layoutNode.style.flexShrink = 0
        }
        requestRender()
    }

    // parity: core/src/Renderable.ts#Renderable.minWidth [status=implemented hash=bda625be9d8c]
    public var minWidth: FlexValue {
        get { layoutNode.style.minWidth }
        set {
            guard !_isDestroyed else { return }
            layoutNode.style.minWidth = newValue
            requestRender()
        }
    }

    // parity: core/src/Renderable.ts#Renderable.maxWidth [status=implemented hash=1871d191fd56]
    public var maxWidth: FlexValue {
        get { layoutNode.style.maxWidth }
        set {
            guard !_isDestroyed else { return }
            layoutNode.style.maxWidth = newValue
            requestRender()
        }
    }

    // parity: core/src/Renderable.ts#Renderable.minHeight [status=implemented hash=23b4a05ba311]
    public var minHeight: FlexValue {
        get { layoutNode.style.minHeight }
        set {
            guard !_isDestroyed else { return }
            layoutNode.style.minHeight = newValue
            requestRender()
        }
    }

    // parity: core/src/Renderable.ts#Renderable.maxHeight [status=implemented hash=934cd424409b]
    public var maxHeight: FlexValue {
        get { layoutNode.style.maxHeight }
        set {
            guard !_isDestroyed else { return }
            layoutNode.style.maxHeight = newValue
            requestRender()
        }
    }

    // parity: core/src/Renderable.ts#Renderable.flexGrow [status=implemented hash=21f2df9d5014]
    public var flexGrow: Float {
        get { layoutNode.style.flexGrow }
        set {
            guard !_isDestroyed else { return }
            layoutNode.style.flexGrow = newValue
            requestRender()
        }
    }

    // parity: core/src/Renderable.ts#Renderable.flexShrink [status=implemented hash=c8d3b101a36f]
    public var flexShrink: Float {
        get { layoutNode.style.flexShrink }
        set {
            guard !_isDestroyed else { return }
            _flexShrink = newValue
            layoutNode.style.flexShrink = newValue
            requestRender()
        }
    }

    // parity: core/src/Renderable.ts#Renderable.flexBasis [status=implemented hash=ce248f49e2f4]
    public var flexBasis: FlexValue {
        get { layoutNode.style.flexBasis }
        set {
            guard !_isDestroyed else { return }
            layoutNode.style.flexBasis = newValue
            requestRender()
        }
    }

    // parity: core/src/Renderable.ts#Renderable.flexDirection [status=implemented hash=22480fc7d726]
    public var flexDirection: FlexDirection {
        get { layoutNode.style.flexDirection }
        set {
            guard !_isDestroyed else { return }
            layoutNode.style.flexDirection = newValue
            requestRender()
        }
    }

    // parity: core/src/Renderable.ts#Renderable.flexWrap [status=implemented hash=c7f348dca52e]
    public var flexWrap: Wrap {
        get { layoutNode.style.flexWrap }
        set {
            guard !_isDestroyed else { return }
            layoutNode.style.flexWrap = newValue
            requestRender()
        }
    }

    // parity: core/src/Renderable.ts#Renderable.layoutMode [status=implemented hash=64cac496feea]
    public var layoutMode: LayoutMode {
        get { _layoutMode }
        set {
            guard !_isDestroyed else { return }
            _layoutMode = newValue
            requestRender()
        }
    }

    // parity: core/src/Renderable.ts#Renderable.alignItems [status=implemented hash=b9f730c4284e]
    public var alignItems: Align {
        get { layoutNode.style.alignItems }
        set {
            guard !_isDestroyed else { return }
            layoutNode.style.alignItems = newValue
            requestRender()
        }
    }

    // parity: core/src/Renderable.ts#Renderable.alignSelf [status=implemented hash=39be59c6b2c3]
    public var alignSelf: Align {
        get { layoutNode.style.alignSelf }
        set {
            guard !_isDestroyed else { return }
            layoutNode.style.alignSelf = newValue
            requestRender()
        }
    }

    // parity: core/src/Renderable.ts#Renderable.alignContent [status=implemented hash=7e9e7e11599e]
    public var alignContent: Align {
        get { layoutNode.style.alignContent }
        set {
            guard !_isDestroyed else { return }
            layoutNode.style.alignContent = newValue
            requestRender()
        }
    }

    // parity: core/src/Renderable.ts#Renderable.justifyContent [status=implemented hash=f81e72294458]
    public var justifyContent: Justify {
        get { layoutNode.style.justifyContent }
        set {
            guard !_isDestroyed else { return }
            layoutNode.style.justifyContent = newValue
            requestRender()
        }
    }

    // parity: core/src/Renderable.ts#Renderable.position [status=implemented hash=cc78995f7b3d]
    public var position: PositionType {
        get { layoutNode.style.positionType }
        set {
            guard !_isDestroyed, layoutNode.style.positionType != newValue else { return }
            layoutNode.style.positionType = newValue
            requestRender()
        }
    }

    // parity: core/src/Renderable.ts#Renderable.overflow [status=implemented hash=12a05048d539]
    open var overflow: Overflow {
        get { layoutNode.style.overflow }
        set {
            guard !_isDestroyed, layoutNode.style.overflow != newValue else { return }
            layoutNode.style.overflow = newValue
            requestRender()
        }
    }

    public var display: Display {
        get { layoutNode.style.display }
        set {
            guard !_isDestroyed else { return }
            if newValue != .none {
                _displayWhenVisible = newValue
            }
            layoutNode.style.display = _visible ? newValue : .none
            requestRender()
        }
    }

    // parity: core/src/Renderable.ts#Renderable.aspectRatio [status=implemented hash=46c5b74836eb]
    public var aspectRatio: Float? {
        get { layoutNode.style.aspectRatio }
        set {
            guard !_isDestroyed else { return }
            layoutNode.style.aspectRatio = newValue
            requestRender()
        }
    }

    // parity: core/src/Renderable.ts#Renderable.boxSizing [status=implemented hash=3a79a79392e1]
    public var boxSizing: BoxSizing {
        get { layoutNode.style.boxSizing }
        set {
            guard !_isDestroyed else { return }
            layoutNode.style.boxSizing = newValue
            requestRender()
        }
    }

    /// Parses a string or `nil` box-sizing option (`"content-box"` / `"border-box"` / `nil` -> `.borderBox`)
    /// matching `core/src/Renderable.ts#Renderable.boxSizing` setter semantics.
    public func setBoxSizing(_ value: String?) {
        boxSizing = parseBoxSizing(value)
    }

    // parity: core/src/Renderable.ts#Renderable.top [status=implemented hash=d856240b900d]
    public var top: FlexValue {
        get { layoutNode.style.position.top }
        set {
            guard !_isDestroyed else { return }
            layoutNode.style.position.top = newValue
            requestRender()
        }
    }

    // parity: core/src/Renderable.ts#Renderable.right [status=implemented hash=e7522f5c2456]
    public var right: FlexValue {
        get { layoutNode.style.position.right }
        set {
            guard !_isDestroyed else { return }
            layoutNode.style.position.right = newValue
            requestRender()
        }
    }

    // parity: core/src/Renderable.ts#Renderable.bottom [status=implemented hash=18be360a0802]
    public var bottom: FlexValue {
        get { layoutNode.style.position.bottom }
        set {
            guard !_isDestroyed else { return }
            layoutNode.style.position.bottom = newValue
            requestRender()
        }
    }

    // parity: core/src/Renderable.ts#Renderable.left [status=implemented hash=631712bb274c]
    public var left: FlexValue {
        get { layoutNode.style.position.left }
        set {
            guard !_isDestroyed else { return }
            layoutNode.style.position.left = newValue
            requestRender()
        }
    }

    // parity: core/src/Renderable.ts#Renderable.setPosition [status=implemented hash=7b08e4a26984]
    public func setPosition(_ pos: Position) {
        guard !_isDestroyed else { return }
        if let top = pos.top { layoutNode.style.position.top = top }
        if let right = pos.right { layoutNode.style.position.right = right }
        if let bottom = pos.bottom { layoutNode.style.position.bottom = bottom }
        if let left = pos.left { layoutNode.style.position.left = left }
        requestRender()
    }

    // parity: core/src/Renderable.ts#Renderable.margin [status=implemented hash=75cd8b577d24]
    public var margin: FlexValue {
        get { layoutNode.style.margin.all }
        set {
            guard !_isDestroyed else { return }
            layoutNode.style.margin.all = newValue
            requestRender()
        }
    }

    // parity: core/src/Renderable.ts#Renderable.marginX [status=implemented hash=36c417feffba]
    public var marginX: FlexValue {
        get { layoutNode.style.margin.horizontal }
        set {
            guard !_isDestroyed else { return }
            layoutNode.style.margin.horizontal = newValue
            requestRender()
        }
    }

    // parity: core/src/Renderable.ts#Renderable.marginY [status=implemented hash=baeca5d0bdd9]
    public var marginY: FlexValue {
        get { layoutNode.style.margin.vertical }
        set {
            guard !_isDestroyed else { return }
            layoutNode.style.margin.vertical = newValue
            requestRender()
        }
    }

    // parity: core/src/Renderable.ts#Renderable.marginTop [status=implemented hash=ae22dd057377]
    public var marginTop: FlexValue {
        get { layoutNode.style.margin.top }
        set {
            guard !_isDestroyed else { return }
            layoutNode.style.margin.top = newValue
            requestRender()
        }
    }

    // parity: core/src/Renderable.ts#Renderable.marginRight [status=implemented hash=dc8427ee5178]
    public var marginRight: FlexValue {
        get { layoutNode.style.margin.right }
        set {
            guard !_isDestroyed else { return }
            layoutNode.style.margin.right = newValue
            requestRender()
        }
    }

    // parity: core/src/Renderable.ts#Renderable.marginBottom [status=implemented hash=b45d74b6d582]
    public var marginBottom: FlexValue {
        get { layoutNode.style.margin.bottom }
        set {
            guard !_isDestroyed else { return }
            layoutNode.style.margin.bottom = newValue
            requestRender()
        }
    }

    // parity: core/src/Renderable.ts#Renderable.marginLeft [status=implemented hash=170d03aac53d]
    public var marginLeft: FlexValue {
        get { layoutNode.style.margin.left }
        set {
            guard !_isDestroyed else { return }
            layoutNode.style.margin.left = newValue
            requestRender()
        }
    }

    // parity: core/src/Renderable.ts#Renderable.padding [status=implemented hash=bf1e3439e810]
    public var padding: FlexValue {
        get { layoutNode.style.padding.all }
        set {
            guard !_isDestroyed else { return }
            layoutNode.style.padding.all = newValue
            requestRender()
        }
    }

    // parity: core/src/Renderable.ts#Renderable.paddingX [status=implemented hash=2e29a0d7d5ab]
    public var paddingX: FlexValue {
        get { layoutNode.style.padding.horizontal }
        set {
            guard !_isDestroyed else { return }
            layoutNode.style.padding.horizontal = newValue
            requestRender()
        }
    }

    // parity: core/src/Renderable.ts#Renderable.paddingY [status=implemented hash=c726fcffd03f]
    public var paddingY: FlexValue {
        get { layoutNode.style.padding.vertical }
        set {
            guard !_isDestroyed else { return }
            layoutNode.style.padding.vertical = newValue
            requestRender()
        }
    }

    // parity: core/src/Renderable.ts#Renderable.paddingTop [status=implemented hash=2c308e11afa4]
    public var paddingTop: FlexValue {
        get { layoutNode.style.padding.top }
        set {
            guard !_isDestroyed else { return }
            layoutNode.style.padding.top = newValue
            requestRender()
        }
    }

    // parity: core/src/Renderable.ts#Renderable.paddingRight [status=implemented hash=40a98e3742be]
    public var paddingRight: FlexValue {
        get { layoutNode.style.padding.right }
        set {
            guard !_isDestroyed else { return }
            layoutNode.style.padding.right = newValue
            requestRender()
        }
    }

    // parity: core/src/Renderable.ts#Renderable.paddingBottom [status=implemented hash=12a0f355ecd4]
    public var paddingBottom: FlexValue {
        get { layoutNode.style.padding.bottom }
        set {
            guard !_isDestroyed else { return }
            layoutNode.style.padding.bottom = newValue
            requestRender()
        }
    }

    // parity: core/src/Renderable.ts#Renderable.paddingLeft [status=implemented hash=a7ac197f6824]
    public var paddingLeft: FlexValue {
        get { layoutNode.style.padding.left }
        set {
            guard !_isDestroyed else { return }
            layoutNode.style.padding.left = newValue
            requestRender()
        }
    }

    public var gap: FlexValue {
        get { layoutNode.style.gap.all }
        set {
            guard !_isDestroyed else { return }
            layoutNode.style.gap.all = newValue
            requestRender()
        }
    }

    public var rowGap: FlexValue {
        get { layoutNode.style.gap.row }
        set {
            guard !_isDestroyed else { return }
            layoutNode.style.gap.row = newValue
            requestRender()
        }
    }

    public var columnGap: FlexValue {
        get { layoutNode.style.gap.column }
        set {
            guard !_isDestroyed else { return }
            layoutNode.style.gap.column = newValue
            requestRender()
        }
    }

    // parity: core/src/Renderable.ts#Renderable.primaryAxis [status=implemented hash=1c95f466cc84]
    open var primaryAxis: ViewportDirection {
        if _layoutMode != .list && (flexDirection == .row || flexDirection == .rowReverse) {
            return .row
        }
        return .column
    }

    // parity: core/src/Renderable.ts#Renderable.setMeasureProvider [status=implemented hash=d46280bdaa46]
    public func setMeasureProvider(_ provider: FlexMeasureFunc?) {
        guard !_isDestroyed else { return }
        layoutNode.setMeasureFunc(provider)
        requestRender()
    }

    // parity: core/src/Renderable.ts#Renderable.invalidateIntrinsicSize [status=implemented hash=7aaeaad7f986]
    public func invalidateIntrinsicSize() {
        guard !_isDestroyed else { return }
        if layoutNode.hasMeasureFunc {
            layoutNode.markDirty()
        }
    }

    // parity: core/src/Renderable.ts#Renderable.getComputedLayout [status=implemented hash=c1d413e735fc]
    public func getComputedLayout() -> FlexComputedLayout {
        layoutNode.computedLayout
    }

    // parity: core/src/Renderable.ts#Renderable.getLayout [status=implemented hash=321968b639fe]
    public func getLayout() -> FlexComputedLayout {
        layoutNode.computedLayout
    }

    // MARK: - Focus & Keyboard/Paste

    // parity: core/src/Renderable.ts#Renderable.focusable [status=implemented hash=d09f419ab98a]
    public var focusable: Bool {
        get { _focusable }
        set {
            guard _focusable != newValue else { return }
            _focusable = newValue
            if !newValue {
                blur()
            }
            requestRender()
        }
    }

    // parity: core/src/Renderable.ts#Renderable.focused [status=implemented hash=83d9432de0a2]
    public var focused: Bool {
        _focused
    }

    // parity: core/src/Renderable.ts#Renderable.hasFocusedDescendant [status=implemented hash=e40c9d29047b]
    public var hasFocusedDescendant: Bool {
        guard let focused = ctx.currentFocusedRenderable, focused._focused, !focused._isDestroyed else {
            return false
        }
        var current = focused.parent
        while let node = current {
            if node === self { return true }
            current = node.parent
        }
        return false
    }

    // parity: core/src/Renderable.ts#Renderable.focus [status=implemented hash=0fc69e5015e7]
    open func focus() {
        guard !_isDestroyed, !_focused, _focusable else { return }
        _focused = true
        ctx.focusRenderable(self)
        requestRender()

        guard !_isDestroyed, _focused, ctx.currentFocusedRenderable === self else { return }
        if keypressToken != nil { return }

        keypressToken = ctx.internalKeyInput.onInternalKeypress { [weak self] key in
            guard let self, !self._isDestroyed, self._focused, self.ctx.currentFocusedRenderable === self else {
                return
            }
            self.onKeyDown?(key)
            if self._isDestroyed { return }
            if !key.defaultPrevented {
                _ = self.handleKeyPress(key)
            }
        }

        pasteToken = ctx.internalKeyInput.onInternalPaste { [weak self] event in
            guard let self, !self._isDestroyed, self._focused, self.ctx.currentFocusedRenderable === self else {
                return
            }
            self.onPaste?(event)
            if self._isDestroyed { return }
            if !event.defaultPrevented {
                self.handlePaste(event)
            }
        }

        propagateFocusChange(true)
        emit(RenderableEvents.focused)
    }

    // parity: core/src/Renderable.ts#Renderable.blur [status=implemented hash=d2ae60ee33d2]
    open func blur() {
        guard _focused else { return }
        _focused = false

        if let token = keypressToken {
            keypressToken = nil
            ctx.internalKeyInput.offInternal(token)
        }
        if let token = pasteToken {
            pasteToken = nil
            ctx.internalKeyInput.offInternal(token)
        }

        propagateFocusChange(false)
        if !_focused {
            ctx.blurRenderable(self)
            emit(RenderableEvents.blurred)
        }
    }

    open func propagateFocusChange(_ hasFocus: Bool) {
        var current = parent
        while let node = current {
            node.markDirty()
            current = node.parent
        }
        requestRender()
    }

    @discardableResult
    open func handleKeyPress(_ key: KeyEvent) -> Bool {
        false
    }

    open func handlePaste(_ event: PasteEvent) {}

    // MARK: - Live Mode & Animation

    // parity: core/src/Renderable.ts#Renderable.live [status=implemented hash=f908b6838caf]
    public var live: Bool {
        get { _live }
        set {
            guard _live != newValue else { return }
            _live = newValue
            if _visible {
                propagateLiveCount(newValue ? 1 : -1)
            }
        }
    }

    // parity: core/src/Renderable.ts#Renderable.liveCount [status=implemented hash=02919e76cecc]
    public var liveCount: Int {
        _liveCount
    }

    open func propagateLiveCount(_ delta: Int) {
        let previous = _liveCount
        _liveCount += delta
        onLiveCountChanged(previous: previous)
        parent?.propagateLiveCount(delta)
    }

    open func onLiveCountChanged(previous: Int) {}

    // parity: core/src/Renderable.ts#Renderable.animationFps [status=implemented hash=8b04b3311cbf]
    public var animationFps: Double? {
        get { _animationFps }
        set {
            if let value = newValue, !(value > 0 && value.isFinite) {
                return
            }
            guard _animationFps != newValue else { return }
            _animationFps = newValue
            updateAnimationTick()
        }
    }

    private func updateAnimationTick() {
        stopAnimationTick?()
        stopAnimationTick = nil
        guard let fps = _animationFps, _visible, !_isDestroyed else { return }
        stopAnimationTick = ctx.onAnimationTick(fps: fps) { [weak self] deltaTime, ticks, time in
            guard let self else { return }
            if self.animationDrawnFrame < self.ctx.frameId - 1 {
                self.stopAnimationTick?()
                self.stopAnimationTick = nil
                return
            }
            self.onAnimationTick(deltaTime: deltaTime, ticks: ticks, time: time)
        }
    }

    open func onAnimationTick(deltaTime: Double, ticks: Int, time: Double) {}

    // MARK: - Lifecycle Pass

    // parity: core/src/Renderable.ts#Renderable.onLifecyclePass [status=implemented hash=7a51335a7a60]
    public var onLifecyclePass: (() -> Void)? {
        get { _onLifecyclePass }
        set {
            _onLifecyclePass = newValue
            syncLifecyclePass()
        }
    }

    public func setBuiltinLifecyclePass(_ pass: (() -> Void)?) {
        _builtinLifecyclePass = pass
        syncLifecyclePass()
    }

    public var needsLifecyclePass: Bool {
        _onLifecyclePass != nil || _builtinLifecyclePass != nil
    }

    private func syncLifecyclePass() {
        if !needsLifecyclePass {
            ctx.unregisterLifecyclePass(self)
        } else if parent != nil || self is RootRenderable {
            ctx.registerLifecyclePass(self)
        }
    }

    public func runLifecyclePass() {
        _builtinLifecyclePass?()
        if !_isDestroyed {
            _onLifecyclePass?()
        }
    }

    // MARK: - Tree Operations

    // parity: core/src/Renderable.ts#Renderable.add [status=implemented hash=041800eb0d08]
    @discardableResult
    open func add(_ child: Renderable, index: Int? = nil) -> Int {
        guard !_isDestroyed, !child._isDestroyed, child !== self else { return -1 }

        if let index, index >= 0, index < _childrenInLayoutOrder.count {
            return insertBefore(child, anchor: _childrenInLayoutOrder[index])
        }
        return placeChild(child, anchor: nil)
    }

    // parity: core/src/Renderable.ts#Renderable.insertBefore [status=implemented hash=394d8c8732c8]
    @discardableResult
    open func insertBefore(_ child: Renderable, anchor: Renderable?) -> Int {
        guard let anchor else {
            return add(child)
        }
        guard !_isDestroyed, !child._isDestroyed, !anchor._isDestroyed, child !== self, child !== anchor else {
            return -1
        }
        guard _childrenInLayoutOrder.contains(where: { $0 === anchor }) else {
            return -1
        }
        return placeChild(child, anchor: anchor)
    }

    private func placeChild(_ child: Renderable, anchor: Renderable?) -> Int {
        let previous = child.parent
        let previousIndex = previous?._childrenInLayoutOrder.firstIndex(where: { $0 === child })

        let anchorIndex: Int
        if let anchor {
            guard let found = _childrenInLayoutOrder.firstIndex(where: { $0 === anchor }) else {
                return -1
            }
            anchorIndex = found
        } else {
            anchorIndex = _childrenInLayoutOrder.count
        }

        let targetIndex: Int
        if previous === self, let previousIndex, previousIndex < anchorIndex {
            targetIndex = anchorIndex - 1
        } else {
            targetIndex = anchorIndex
        }

        if let previous, let previousIndex {
            previous._childrenInLayoutOrder.remove(at: previousIndex)
            previous.layoutNode.removeChild(child.layoutNode)
            if previous !== self {
                if child._liveCount > 0 {
                    previous.propagateLiveCount(-child._liveCount)
                }
                previous.ctx.unregisterLifecyclePass(child)
            }
        }

        _childrenInLayoutOrder.insert(child, at: targetIndex)
        layoutNode.insertChild(child.layoutNode, at: targetIndex)
        child.parent = self

        if previous !== self {
            if child._liveCount > 0 {
                propagateLiveCount(child._liveCount)
            }
            if child.needsLifecyclePass {
                ctx.registerLifecyclePass(child)
            }
            if child._focused || child.hasFocusedDescendant {
                var p = previous
                while let node = p {
                    node.markDirty()
                    p = node.parent
                }
                var t: Renderable? = self
                while let node = t {
                    node.markDirty()
                    t = node.parent
                }
            }
            if let previous {
                child.onRemove()
                previous.requestRender()
            }
        }

        requestRender()
        return targetIndex
    }

    // parity: core/src/Renderable.ts#Renderable.remove [status=implemented hash=9fdc71330c0d]
    open func remove(_ child: Renderable) {
        guard let index = _childrenInLayoutOrder.firstIndex(where: { $0 === child }) else {
            return
        }
        _childrenInLayoutOrder.remove(at: index)
        layoutNode.removeChild(child.layoutNode)

        if child._focused || child.hasFocusedDescendant {
            child.propagateFocusChange(false)
        }
        if child._liveCount > 0 {
            propagateLiveCount(-child._liveCount)
        }
        ctx.unregisterLifecyclePass(child)
        child.parent = nil
        child.onRemove()
        requestRender()
    }

    open func onRemove() {}

    open override func add(_ obj: Any, index: Int? = nil) -> Int {
        guard let child = obj as? Renderable else { return -1 }
        return add(child, index: index)
    }

    open override func remove(_ child: BaseRenderable) {
        if let renderable = child as? Renderable {
            remove(renderable)
        }
    }

    open override func insertBefore(_ obj: Any, anchor: Any?) {
        guard let child = obj as? Renderable else { return }
        _ = insertBefore(child, anchor: anchor as? Renderable)
    }

    open override func getBaseChildren() -> [BaseRenderable] {
        _childrenInLayoutOrder
    }

    // parity: core/src/Renderable.ts#Renderable.getRenderable [status=implemented hash=92ecd34f967c]
    public func getRenderable(_ id: String) -> Renderable? {
        _childrenInLayoutOrder.first { $0.id == id }
    }

    open override func getBaseRenderable(_ id: String) -> BaseRenderable? {
        getRenderable(id)
    }

    // parity: core/src/Renderable.ts#Renderable.getChildren [status=implemented hash=c79ea5ac6062]
    public func getChildren() -> [Renderable] {
        _childrenInLayoutOrder
    }

    // parity: core/src/Renderable.ts#Renderable.getChildrenCount [status=implemented hash=46bbf595312a]
    open override func getChildrenCount() -> Int {
        _childrenInLayoutOrder.count
    }

    // parity: core/src/Renderable.ts#Renderable.findDescendantById [status=implemented hash=51b0bb58275c]
    public func findDescendantById(_ id: String) -> Renderable? {
        for child in _childrenInLayoutOrder {
            if child.id == id {
                return child
            }
            if let found = child.findDescendantById(id) {
                return found
            }
        }
        return nil
    }

    open override func findBaseDescendantById(_ id: String) -> BaseRenderable? {
        findDescendantById(id)
    }

    // parity: core/src/Renderable.ts#Renderable.getChildrenSortedByPrimaryAxis [status=implemented hash=897794224d1f]
    public func getChildrenSortedByPrimaryAxis() -> [Renderable] {
        guard _childrenInLayoutOrder.count >= 2 else { return _childrenInLayoutOrder }
        let isRow = primaryAxis == .row
        return _childrenInLayoutOrder
            .enumerated()
            .sorted { lhs, rhs in
                let a = isRow ? lhs.element.screenX : lhs.element.screenY
                let b = isRow ? rhs.element.screenX : rhs.element.screenY
                if a != b { return a < b }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    // MARK: - Layout & Rendering Pipeline

    // parity: core/src/Renderable.ts#Renderable.requestRender [status=implemented hash=bd8821f36d53]
    open override func requestRender() {
        markDirty()
        ctx.requestRender()
    }

    /// Synchronizes integer terminal cell coordinates and sizes from `layoutNode.computedLayout`,
    /// firing resize/layout-change hooks and recursing to visible children.
    open func updateFromLayout() {
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

        if _visible {
            for child in _childrenInLayoutOrder {
                child.updateFromLayout()
            }
        }
    }

    open func onLayoutResize(width: Int, height: Int) {
        guard _visible else { return }
        handleFrameBufferResize(width: width, height: height)
        onResize(width: width, height: height)
    }

    open func onResize(width: Int, height: Int) {
        onSizeChange?()
        emit("resize")
    }

    private func handleFrameBufferResize(width: Int, height: Int) {
        guard buffered, width > 0, height > 0 else { return }
        if let fb = frameBuffer {
            if fb.width != width || fb.height != height {
                try? fb.resize(width: width, height: height)
            }
        } else {
            createFrameBufferIfNeeded()
        }
    }

    private func createFrameBufferIfNeeded() {
        let w = width
        let h = height
        guard w > 0, h > 0 else { return }
        frameBuffer = OptimizedBuffer(
            width: w,
            height: h,
            widthMethod: ctx.widthMethod,
            respectAlpha: true,
            id: "framebuffer-\(id)",
            graphemePool: ctx.graphemePool,
            linkPool: ctx.linkPool
        )
    }

    /// Returns `(0, 0)` when painting into this node's own offscreen `frameBuffer`,
    /// or `(screenX, screenY)` when painting directly into the destination buffer.
    public func paintOrigin(for buffer: OptimizedBuffer) -> (x: Int, y: Int) {
        if let fb = frameBuffer, buffer === fb {
            return (0, 0)
        }
        return (_screenX, _screenY)
    }

    open func onUpdate(deltaTime: Double) {}

    /// Override in subclasses to paint this renderable's content into `buffer`.
    open func renderSelf(buffer: OptimizedBuffer, deltaTime: Double) {}

    /// Full render pass for this subtree: update -> opacity -> hit-grid -> hooks -> self -> clipped z-sorted children.
    open func render(buffer: OptimizedBuffer, deltaTime: Double) {
        guard _visible && !_isDestroyed else { return }

        if _animationFps != nil {
            animationDrawnFrame = ctx.frameId
            if stopAnimationTick == nil {
                updateAnimationTick()
            }
        }

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

        if buffered && width > 0 && height > 0 {
            handleFrameBufferResize(width: width, height: height)
            if let fb = frameBuffer {
                fb.clear(bg: RGBA.fromInts(0, 0, 0, 0), char: defaultSpaceChar)
                renderBefore?(fb, deltaTime)
                guard !_isDestroyed else { return }
                renderSelf(buffer: fb, deltaTime: deltaTime)
                guard !_isDestroyed else { return }
                renderAfter?(fb, deltaTime)
                guard !_isDestroyed else { return }
                buffer.drawFrameBuffer(destX: _screenX, destY: _screenY, frameBuffer: fb)
            }
        } else {
            renderBefore?(buffer, deltaTime)
            guard !_isDestroyed else { return }
            renderSelf(buffer: buffer, deltaTime: deltaTime)
            guard !_isDestroyed else { return }
        }

        let shouldClip = overflow == .hidden || overflow == .scroll
        if shouldClip {
            buffer.pushScissorRect(x: _screenX, y: _screenY, width: width, height: height)
        }
        renderChildren(buffer: buffer, deltaTime: deltaTime)
        if shouldClip {
            buffer.popScissorRect()
        }

        if !buffered && !_isDestroyed {
            renderAfter?(buffer, deltaTime)
        }

        markClean()
    }

    open func renderChildren(buffer: OptimizedBuffer, deltaTime: Double) {
        guard !_childrenInLayoutOrder.isEmpty else { return }
        // Stable ascending zIndex sort: equal zIndex preserves insertion order so later siblings paint on top.
        let ordered: [Renderable]
        if _childrenInLayoutOrder.count == 1 {
            ordered = _childrenInLayoutOrder
        } else {
            ordered = _childrenInLayoutOrder
                .enumerated()
                .sorted { lhs, rhs in
                    if lhs.element._zIndex != rhs.element._zIndex {
                        return lhs.element._zIndex < rhs.element._zIndex
                    }
                    return lhs.offset < rhs.offset
                }
                .map(\.element)
        }

        for child in ordered {
            if !_isDestroyed && child._visible && !child._isDestroyed {
                child.render(buffer: buffer, deltaTime: deltaTime)
            }
        }
    }

    // MARK: - Mouse & Selection

    // parity: core/src/Renderable.ts#Renderable.processMouseEvent [status=implemented hash=f7d192f655fa]
    open func processMouseEvent(_ event: MouseEvent) {
        event.currentTarget = self
        onMouse?(event)
        if _isDestroyed { return }

        switch event.type {
        case .down: onMouseDown?(event)
        case .up: onMouseUp?(event)
        case .move: onMouseMove?(event)
        case .drag: onMouseDrag?(event)
        case .dragEnd: onMouseDragEnd?(event)
        case .drop: onMouseDrop?(event)
        case .over: onMouseOver?(event)
        case .out: onMouseOut?(event)
        case .scroll: onMouseScroll?(event)
        }
        if _isDestroyed { return }

        onMouseEvent(event)
        if _isDestroyed { return }

        if let parent, !event.propagationStopped {
            parent.processMouseEvent(event)
        }
    }

    open func onMouseEvent(_ event: MouseEvent) {}

    // parity: core/src/Renderable.ts#Renderable.shouldStartSelection [status=implemented hash=ca3c1a26cf04]
    open func shouldStartSelection(x: Int, y: Int) -> Bool {
        false
    }

    // parity: core/src/Renderable.ts#Renderable.onSelectionChanged [status=implemented hash=63f6ae56cd36]
    @discardableResult
    open func onSelectionChanged(_ selection: Selection?) -> Bool {
        false
    }

    // parity: core/src/Renderable.ts#Renderable.getSelectedText [status=implemented hash=15b082581bbd]
    open func getSelectedText() -> String {
        ""
    }

    // parity: core/src/Renderable.ts#Renderable.hasSelection [status=implemented hash=dac414dd607c]
    open func hasSelection() -> Bool {
        false
    }

    // MARK: - Destruction

    // parity: core/src/Renderable.ts#Renderable.destroy [status=implemented hash=51737426b589]
    open override func destroy() {
        guard !_isDestroyed else { return }
        let heldFocus = _focused || hasFocusedDescendant
        _isDestroyed = true

        stopAnimationTick?()
        stopAnimationTick = nil

        emit(RenderableEvents.destroyed)

        if heldFocus {
            propagateFocusChange(false)
        }

        if let parent {
            parent.remove(self)
        } else {
            ctx.unregisterLifecyclePass(self)
        }

        if let fb = frameBuffer {
            frameBuffer = nil
            fb.destroy()
        }

        let childrenSnapshot = _childrenInLayoutOrder
        for child in childrenSnapshot {
            remove(child)
        }
        _childrenInLayoutOrder.removeAll()
        layoutNode.reset()

        globalRenderableRegistry.unregister(num)

        blur()
        removeAllListeners()
        destroySelf()
    }

    // parity: core/src/Renderable.ts#Renderable.destroyRecursively [status=implemented hash=c344bd597320]
    open override func destroyRecursively() {
        guard !_isDestroyed else { return }
        let childrenSnapshot = _childrenInLayoutOrder
        for child in childrenSnapshot {
            child.destroyRecursively()
        }
        destroy()
    }

    open func destroySelf() {}
}

// MARK: - RootRenderable

/// Scene root container managed by `CliRenderer`, matching `core/src/Renderable.ts#RootRenderable`.
// parity: core/src/Renderable.ts#RootRenderable [status=implemented hash=f012f5a6cbe1]
public final class RootRenderable: Renderable, @unchecked Sendable {
    private var _currentRenderable: Renderable? = nil

    public override var participatesInHitGrid: Bool { false }

    public init(ctx: any RenderContext) {
        super.init(
            ctx: ctx,
            options: RenderableOptions(
                id: "__root__",
                width: .point(Float(ctx.width)),
                height: .point(Float(ctx.height)),
                zIndex: 0,
                visible: true
            )
        )
    }

    // parity: core/src/Renderable.ts#RootRenderable.currentRenderable [status=implemented hash=f211ba688875]
    public var currentRenderable: Renderable? {
        _currentRenderable
    }

    internal func setCurrentRenderable(_ renderable: Renderable?) {
        _currentRenderable = renderable
    }

    // parity: core/src/Renderable.ts#RootRenderable.takeCurrentRenderable [status=implemented hash=010b055621ab]
    public func takeCurrentRenderable() -> Renderable? {
        let current = _currentRenderable
        _currentRenderable = nil
        return current
    }

    public override func propagateLiveCount(_ delta: Int) {
        let oldCount = _liveCount
        _liveCount += delta
        onLiveCountChanged(previous: oldCount)
    }

    public override func onLiveCountChanged(previous: Int) {
        if previous == 0 && _liveCount > 0 {
            ctx.requestLive()
        } else if previous > 0 && _liveCount == 0 {
            ctx.dropLive()
        }
    }

    // parity: core/src/Renderable.ts#RootRenderable.resize [status=implemented hash=ce39a4f1e1f2]
    public func resize(width: Int, height: Int) {
        setWidth(.point(Float(max(0, width))))
        setHeight(.point(Float(max(0, height))))
        emit(LayoutEvents.resized)
    }
}

// MARK: - Dynamic Prop Application (renderables/props.ts)

private func coerceFlexValue(_ value: Any?, defaultValue: FlexValue = .undefined) -> FlexValue {
    guard let value else { return defaultValue }
    if let fv = value as? FlexValue { return fv }
    if let i = value as? Int { return .point(Float(i)) }
    if let f = value as? Float { return f.isFinite ? .point(f) : defaultValue }
    if let d = value as? Double { return d.isFinite ? .point(Float(d)) : defaultValue }
    if let s = value as? String { return FlexValue.parse(s) }
    return defaultValue
}

/// Applies one dynamic reconciler prop to a `Renderable`, matching `core/src/renderables/props.ts#setRenderableProp`.
// parity: core/src/renderables/props.ts#setRenderableProp [status=adapted hash=5dd4f94d0746]
public func setRenderableProp(_ node: Renderable, name: String, value: Any?, prev: Any? = nil) {
    switch name {
    case "focused":
        if (value as? Bool) == true {
            node.focus()
        } else {
            node.blur()
        }
    case "style":
        let next = (value as? [String: Any]) ?? [:]
        let last = (prev as? [String: Any]) ?? [:]
        for key in last.keys where next[key] == nil {
            setRenderableProp(node, name: key, value: nil, prev: last[key])
        }
        for (key, nextVal) in next {
            setRenderableProp(node, name: key, value: nextVal, prev: last[key])
        }
    case "id":
        if let id = value as? String { node.id = id }
    case "visible":
        node.visible = (value as? Bool) ?? true
    case "focusable":
        node.focusable = (value as? Bool) ?? false
    case "selectable":
        node.selectable = (value as? Bool) ?? false
    case "live":
        node.live = (value as? Bool) ?? false
    case "zIndex":
        node.zIndex = (value as? Int) ?? 0
    case "opacity":
        if let d = value as? Double {
            node.opacity = d
        } else if let f = value as? Float {
            node.opacity = Double(f)
        } else if let i = value as? Int {
            node.opacity = Double(i)
        } else {
            node.opacity = 1.0
        }
    case "width":
        node.setWidth(coerceFlexValue(value, defaultValue: .auto))
    case "height":
        node.setHeight(coerceFlexValue(value, defaultValue: .auto))
    case "minWidth":
        node.minWidth = coerceFlexValue(value)
    case "maxWidth":
        node.maxWidth = coerceFlexValue(value)
    case "minHeight":
        node.minHeight = coerceFlexValue(value)
    case "maxHeight":
        node.maxHeight = coerceFlexValue(value)
    case "flexGrow":
        if let f = value as? Float { node.flexGrow = f }
        else if let d = value as? Double { node.flexGrow = Float(d) }
        else if let i = value as? Int { node.flexGrow = Float(i) }
        else { node.flexGrow = 0 }
    case "flexShrink":
        if let f = value as? Float { node.flexShrink = f }
        else if let d = value as? Double { node.flexShrink = Float(d) }
        else if let i = value as? Int { node.flexShrink = Float(i) }
        else { node.flexShrink = 1 }
    case "flexBasis":
        if let s = value as? String {
            if isFlexBasisType(.string(s)) {
                node.flexBasis = FlexValue.parse(s)
            }
        } else {
            node.flexBasis = coerceFlexValue(value, defaultValue: .undefined)
        }
    case "boxSizing":
        if let b = value as? BoxSizing { node.boxSizing = b }
        else if let bs = value as? BoxSizingString { node.boxSizing = parseBoxSizing(bs.rawValue) }
        else if let s = value as? String { node.boxSizing = parseBoxSizing(s) }
        else { node.boxSizing = .borderBox }
    case "flexDirection":
        if let d = value as? FlexDirection { node.flexDirection = d }
        else if let s = value as? String { node.flexDirection = parseFlexDirection(s) }
        else { node.flexDirection = .column }
    case "flexWrap":
        if let w = value as? Wrap { node.flexWrap = w }
        else if let s = value as? String { node.flexWrap = parseWrap(s) }
        else { node.flexWrap = .noWrap }
    case "alignItems":
        if let a = value as? Align { node.alignItems = a }
        else if let s = value as? String { node.alignItems = parseAlignItems(s) }
        else { node.alignItems = .stretch }
    case "alignSelf":
        if let a = value as? Align { node.alignSelf = a }
        else if let s = value as? String { node.alignSelf = parseAlign(s) }
        else { node.alignSelf = .auto }
    case "alignContent":
        if let a = value as? Align { node.alignContent = a }
        else if let s = value as? String { node.alignContent = parseAlignContent(s) }
        else { node.alignContent = .flexStart }
    case "justifyContent":
        if let j = value as? Justify { node.justifyContent = j }
        else if let s = value as? String { node.justifyContent = parseJustify(s) }
        else { node.justifyContent = .flexStart }
    case "position":
        if let p = value as? PositionType { node.position = p }
        else if let s = value as? String { node.position = parsePositionType(s) }
        else { node.position = .relative }
    case "overflow":
        if let o = value as? Overflow { node.overflow = o }
        else if let s = value as? String { node.overflow = parseOverflow(s) }
        else { node.overflow = .visible }
    case "top":
        node.top = coerceFlexValue(value)
    case "right":
        node.right = coerceFlexValue(value)
    case "bottom":
        node.bottom = coerceFlexValue(value)
    case "left":
        node.left = coerceFlexValue(value)
    case "margin":
        node.margin = coerceFlexValue(value)
    case "marginX":
        node.marginX = coerceFlexValue(value)
    case "marginY":
        node.marginY = coerceFlexValue(value)
    case "marginTop":
        node.marginTop = coerceFlexValue(value)
    case "marginRight":
        node.marginRight = coerceFlexValue(value)
    case "marginBottom":
        node.marginBottom = coerceFlexValue(value)
    case "marginLeft":
        node.marginLeft = coerceFlexValue(value)
    case "padding":
        node.padding = coerceFlexValue(value)
    case "paddingX":
        node.paddingX = coerceFlexValue(value)
    case "paddingY":
        node.paddingY = coerceFlexValue(value)
    case "paddingTop":
        node.paddingTop = coerceFlexValue(value)
    case "paddingRight":
        node.paddingRight = coerceFlexValue(value)
    case "paddingBottom":
        node.paddingBottom = coerceFlexValue(value)
    case "paddingLeft":
        node.paddingLeft = coerceFlexValue(value)
    case "gap":
        node.gap = coerceFlexValue(value)
    case "rowGap":
        node.rowGap = coerceFlexValue(value)
    case "columnGap":
        node.columnGap = coerceFlexValue(value)
    default:
        break
    }
}
