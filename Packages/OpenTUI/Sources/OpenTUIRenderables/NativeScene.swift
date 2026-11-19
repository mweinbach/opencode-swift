// Pure-Swift retained-mode scene graph & native scene coordinator (`core/src/NativeScene.ts`).
// Zero OS / Foundation imports (Pure Tier).

import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout

// MARK: - Scene Data Models

/// Border bitmask matching `zig.ts#NativeBorder`.
public struct NativeBorderMask: OptionSet, Equatable, Hashable, Sendable, Codable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let none = NativeBorderMask([])
    public static let left = NativeBorderMask(rawValue: 1 << 0)
    public static let bottom = NativeBorderMask(rawValue: 1 << 1)
    public static let right = NativeBorderMask(rawValue: 1 << 2)
    public static let top = NativeBorderMask(rawValue: 1 << 3)
    public static let all: NativeBorderMask = [.left, .bottom, .right, .top]

    public var sidesConfig: BorderSidesConfig {
        BorderSidesConfig(
            top: contains(.top),
            right: contains(.right),
            bottom: contains(.bottom),
            left: contains(.left)
        )
    }
}

/// Visual paint state for a retained scene node matching `zig.ts#NativeScenePaint`.
public struct NativeScenePaint: Equatable, Hashable, Sendable {
    public var zIndex: Int
    public var opacity: Double
    public var translateX: Int
    public var translateY: Int
    public var border: NativeBorderMask
    public var shouldFill: Bool
    public var backgroundColor: RGBA
    public var borderColor: RGBA
    public var borderStyle: BorderStyle
    public var focusable: Bool
    public var focusedBorderColor: RGBA

    public init(
        zIndex: Int = 0,
        opacity: Double = 1.0,
        translateX: Int = 0,
        translateY: Int = 0,
        border: NativeBorderMask = .none,
        shouldFill: Bool = false,
        backgroundColor: RGBA = RGBA.fromInts(0, 0, 0, 0),
        borderColor: RGBA = .defaultForeground(),
        borderStyle: BorderStyle = .single,
        focusable: Bool = false,
        focusedBorderColor: RGBA = RGBA.fromInts(0, 170, 255, 255)
    ) {
        self.zIndex = zIndex
        self.opacity = opacity
        self.translateX = translateX
        self.translateY = translateY
        self.border = border
        self.shouldFill = shouldFill
        self.backgroundColor = backgroundColor
        self.borderColor = borderColor
        self.borderStyle = borderStyle
        self.focusable = focusable
        self.focusedBorderColor = focusedBorderColor
    }
}

/// Partial update to a node's paint properties matching `zig.ts#NativeScenePaintUpdate`.
public struct NativeScenePaintUpdate: Equatable, Hashable, Sendable {
    public var zIndex: Int?
    public var opacity: Double?
    public var translateX: Int?
    public var translateY: Int?
    public var border: NativeBorderMask?
    public var shouldFill: Bool?
    public var backgroundColor: RGBA?
    public var borderColor: RGBA?
    public var borderStyle: BorderStyle?
    public var focusable: Bool?
    public var focusedBorderColor: RGBA?
    public var resetBorderCharacters: Bool

    public init(
        zIndex: Int? = nil,
        opacity: Double? = nil,
        translateX: Int? = nil,
        translateY: Int? = nil,
        border: NativeBorderMask? = nil,
        shouldFill: Bool? = nil,
        backgroundColor: RGBA? = nil,
        borderColor: RGBA? = nil,
        borderStyle: BorderStyle? = nil,
        focusable: Bool? = nil,
        focusedBorderColor: RGBA? = nil,
        resetBorderCharacters: Bool = false
    ) {
        self.zIndex = zIndex
        self.opacity = opacity
        self.translateX = translateX
        self.translateY = translateY
        self.border = border
        self.shouldFill = shouldFill
        self.backgroundColor = backgroundColor
        self.borderColor = borderColor
        self.borderStyle = borderStyle
        self.focusable = focusable
        self.focusedBorderColor = focusedBorderColor
        self.resetBorderCharacters = resetBorderCharacters
    }
}

/// Box decoration options matching `zig.ts#NativeSceneBoxDetails`.
public struct NativeSceneBoxDetails: Equatable, Hashable, Sendable {
    public var title: String?
    public var bottomTitle: String?
    public var titleAlignment: BoxTitleAlignment
    public var bottomTitleAlignment: BoxTitleAlignment
    public var titleColor: RGBA?
    public var customBorderChars: [UInt32]?

    public init(
        title: String? = nil,
        bottomTitle: String? = nil,
        titleAlignment: BoxTitleAlignment = .left,
        bottomTitleAlignment: BoxTitleAlignment = .left,
        titleColor: RGBA? = nil,
        customBorderChars: [UInt32]? = nil
    ) {
        self.title = title
        self.bottomTitle = bottomTitle
        self.titleAlignment = titleAlignment
        self.bottomTitleAlignment = bottomTitleAlignment
        self.titleColor = titleColor
        self.customBorderChars = customBorderChars
    }
}

/// Text rendering options matching `zig.ts#NativeSceneTextOptions`.
public struct NativeSceneTextOptions: Equatable, Hashable, Sendable {
    public var fg: RGBA
    public var bg: RGBA
    public var attributes: UInt32
    public var wrapMode: TextWrapMode
    public var textAlign: TextAlign
    public var truncate: Bool
    public var scrollX: Int
    public var scrollY: Int
    public var firstLineOffset: Int
    public var tabIndicator: String?
    public var tabIndicatorColor: RGBA?

    public init(
        fg: RGBA = .defaultForeground(),
        bg: RGBA = RGBA.fromInts(0, 0, 0, 0),
        attributes: UInt32 = TextAttributes.none,
        wrapMode: TextWrapMode = .none,
        textAlign: TextAlign = .left,
        truncate: Bool = false,
        scrollX: Int = 0,
        scrollY: Int = 0,
        firstLineOffset: Int = 0,
        tabIndicator: String? = nil,
        tabIndicatorColor: RGBA? = nil
    ) {
        self.fg = fg
        self.bg = bg
        self.attributes = attributes
        self.wrapMode = wrapMode
        self.textAlign = textAlign
        self.truncate = truncate
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.firstLineOffset = firstLineOffset
        self.tabIndicator = tabIndicator
        self.tabIndicatorColor = tabIndicatorColor
    }
}

/// Scalar text metrics matching `zig.ts#NativeSceneTextMetrics`.
public struct NativeSceneTextMetrics: Equatable, Hashable, Sendable, Codable {
    public var byteLength: Int
    public var textLength: Int
    public var lineCount: Int
    public var virtualLineCount: Int
    public var widthColsMax: Int

    public init(
        byteLength: Int = 0,
        textLength: Int = 0,
        lineCount: Int = 0,
        virtualLineCount: Int = 0,
        widthColsMax: Int = 0
    ) {
        self.byteLength = byteLength
        self.textLength = textLength
        self.lineCount = lineCount
        self.virtualLineCount = virtualLineCount
        self.widthColsMax = widthColsMax
    }
}

/// Slider drawing options matching `zig.ts#NativeSceneSliderOptions`.
public struct NativeSceneSliderOptions: Equatable, Hashable, Sendable {
    public var orientation: SliderOrientation
    public var min: Double
    public var max: Double
    public var value: Double
    public var viewPortSize: Double
    public var foregroundColor: RGBA
    public var backgroundColor: RGBA

    public init(
        orientation: SliderOrientation = .horizontal,
        min: Double = 0,
        max: Double = 100,
        value: Double = 0,
        viewPortSize: Double = 10,
        foregroundColor: RGBA = RGBA.fromInts(255, 255, 255, 255),
        backgroundColor: RGBA = RGBA.fromInts(60, 60, 60, 255)
    ) {
        self.orientation = orientation
        self.min = min
        self.max = max
        self.value = value
        self.viewPortSize = viewPortSize
        self.foregroundColor = foregroundColor
        self.backgroundColor = backgroundColor
    }
}

/// Directional arrow drawing options matching `zig.ts#NativeSceneArrowOptions`.
public struct NativeSceneArrowOptions: Equatable, Hashable, Sendable {
    public var direction: ScrollDirection
    public var attributes: UInt32
    public var foregroundColor: RGBA
    public var backgroundColor: RGBA
    public var text: String?

    public init(
        direction: ScrollDirection = .up,
        attributes: UInt32 = TextAttributes.none,
        foregroundColor: RGBA = .defaultForeground(),
        backgroundColor: RGBA = RGBA.fromInts(0, 0, 0, 0),
        text: String? = nil
    ) {
        self.direction = direction
        self.attributes = attributes
        self.foregroundColor = foregroundColor
        self.backgroundColor = backgroundColor
        self.text = text
    }
}

public enum NativeSceneScrollFollow: String, Equatable, Hashable, Sendable, Codable {
    case none
    case top
    case bottom
    case left
    case right
}

public enum NativeSceneScrollBarPolicy: String, Equatable, Hashable, Sendable, Codable {
    case auto
    case always
    case never
}

public struct NativeSceneScrollBarOptions: Equatable, Hashable, Sendable {
    public var policy: NativeSceneScrollBarPolicy
    public var overlay: Bool
    public var thickness: Int
    public var gap: Int
    public var arrows: Bool
    public var foregroundColor: RGBA
    public var backgroundColor: RGBA

    public init(
        policy: NativeSceneScrollBarPolicy = .auto,
        overlay: Bool = false,
        thickness: Int = 1,
        gap: Int = 0,
        arrows: Bool = false,
        foregroundColor: RGBA = RGBA.fromInts(200, 200, 200, 255),
        backgroundColor: RGBA = RGBA.fromInts(40, 40, 40, 255)
    ) {
        self.policy = policy
        self.overlay = overlay
        self.thickness = max(0, thickness)
        self.gap = max(0, gap)
        self.arrows = arrows
        self.foregroundColor = foregroundColor
        self.backgroundColor = backgroundColor
    }
}

public struct NativeSceneScrollOptions: Equatable, Hashable, Sendable {
    public var scrollX: Bool
    public var scrollY: Bool
    public var follow: NativeSceneScrollFollow
    public var culling: Bool
    public var padding: [Int]
    public var fills: [RGBA?]
    public var bars: [NativeSceneScrollBarOptions]

    public init(
        scrollX: Bool = false,
        scrollY: Bool = true,
        follow: NativeSceneScrollFollow = .none,
        culling: Bool = true,
        padding: [Int] = [0, 0, 0, 0],
        fills: [RGBA?] = [],
        bars: [NativeSceneScrollBarOptions] = [NativeSceneScrollBarOptions(), NativeSceneScrollBarOptions()]
    ) {
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.follow = follow
        self.culling = culling
        self.padding = padding
        self.fills = fills
        self.bars = bars
    }
}

public struct NativeSceneRect: Equatable, Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public static let zero = NativeSceneRect(x: 0, y: 0, width: 0, height: 0)

    public init(x: Double = 0, y: Double = 0, width: Double = 0, height: Double = 0) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct NativeSceneScrollBarState: Equatable, Hashable, Sendable, Codable {
    public var visible: Bool
    public var track: NativeSceneRect
    public var startArrow: NativeSceneRect
    public var endArrow: NativeSceneRect
    public var thumbStart: Double
    public var thumbSize: Double

    public static let empty = NativeSceneScrollBarState()

    public init(
        visible: Bool = false,
        track: NativeSceneRect = .zero,
        startArrow: NativeSceneRect = .zero,
        endArrow: NativeSceneRect = .zero,
        thumbStart: Double = 0,
        thumbSize: Double = 0
    ) {
        self.visible = visible
        self.track = track
        self.startArrow = startArrow
        self.endArrow = endArrow
        self.thumbStart = thumbStart
        self.thumbSize = thumbSize
    }
}

public struct NativeSceneScrollState: Equatable, Hashable, Sendable, Codable {
    public var changes: UInt32
    public var offsetX: Double
    public var offsetY: Double
    public var maxX: Double
    public var maxY: Double
    public var content: NativeSceneRect
    public var viewport: NativeSceneRect
    public var horizontalBar: NativeSceneScrollBarState
    public var verticalBar: NativeSceneScrollBarState

    public static let empty = NativeSceneScrollState()

    public init(
        changes: UInt32 = 0,
        offsetX: Double = 0,
        offsetY: Double = 0,
        maxX: Double = 0,
        maxY: Double = 0,
        content: NativeSceneRect = .zero,
        viewport: NativeSceneRect = .zero,
        horizontalBar: NativeSceneScrollBarState = .empty,
        verticalBar: NativeSceneScrollBarState = .empty
    ) {
        self.changes = changes
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.maxX = maxX
        self.maxY = maxY
        self.content = content
        self.viewport = viewport
        self.horizontalBar = horizontalBar
        self.verticalBar = verticalBar
    }

    public var offset: [Double] { [offsetX, offsetY] }
    public var max: [Double] { [maxX, maxY] }
}

public enum NativeSceneScrollRequestKind: String, Equatable, Hashable, Sendable, Codable {
    case intoView = "into-view"
    case anchor
    case layout
}

public enum NativeSceneScrollAlign: String, Equatable, Hashable, Sendable, Codable {
    case nearest
    case start
    case end
}

public enum NativeSceneTextSelectionOp: String, Equatable, Hashable, Sendable, Codable {
    case set
    case update
    case reset
    case colors
}

public enum NativeSceneLayoutKind: Equatable, Hashable, Sendable {
    case computed
    case rawYoga
    case paint
    case content
}

public struct NativeSceneEditorOptions: Equatable, Hashable, Sendable {
    public var showCursor: Bool
    public var style: CursorStyle
    public var blinking: Bool
    public var color: RGBA
    public var cursor: MousePointerStyle?

    public init(
        showCursor: Bool = true,
        style: CursorStyle = .block,
        blinking: Bool = true,
        color: RGBA = RGBA.fromInts(255, 255, 255, 255),
        cursor: MousePointerStyle? = nil
    ) {
        self.showCursor = showCursor
        self.style = style
        self.blinking = blinking
        self.color = color
        self.cursor = cursor
    }
}

public struct NativeScenePaintOptions: Equatable, Sendable {
    public var background: RGBA
    public var useMouse: Bool
    public var excludedHitNum: UInt32
    public var preserveUnwritten: Bool

    public init(
        background: RGBA = RGBA.fromInts(0, 0, 0, 255),
        useMouse: Bool = true,
        excludedHitNum: UInt32 = 0,
        preserveUnwritten: Bool = false
    ) {
        self.background = background
        self.useMouse = useMouse
        self.excludedHitNum = excludedHitNum
        self.preserveUnwritten = preserveUnwritten
    }
}

/// Errors thrown by `NativeScene`.
public enum NativeSceneError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    case destroyed
    case destroying
    case layoutRequired
    case nodeNotFound
    case invalidPositionMask(Int)
    case frameAlreadyPainting
    case noPaintedFrame
    case snapshotDuringFrame
    case snapshotInvalidParent
    case lifecyclePassActive
    case custom(String)

    public var description: String {
        switch self {
        case .destroyed: return "Native scene is destroyed"
        case .destroying: return "Native scene is being destroyed"
        case .layoutRequired: return "Native scene requires Yoga layout"
        case .nodeNotFound: return "Scene node is not registered in this NativeScene"
        case .invalidPositionMask(let mask): return "Scene position mask must use four edges (got \(mask))"
        case .frameAlreadyPainting: return "Native scene is already painting a frame"
        case .noPaintedFrame: return "Native scene has no painted frame"
        case .snapshotDuringFrame: return "Cannot measure a snapshot during a native scene frame"
        case .snapshotInvalidParent: return "Snapshot root belongs to another parent"
        case .lifecyclePassActive: return "Native scene lifecycle pass is already active"
        case .custom(let msg): return msg
        }
    }
}

/// Standalone scene node token for headless `NativeScene` graphs (without requiring a `CliRenderer`).
public final class NativeSceneNode: @unchecked Sendable {
    public let handle: SceneNodeHandle
    public let num: UInt32
    public let flexNode: FlexNode

    internal init(handle: SceneNodeHandle, num: UInt32, flexNode: FlexNode = FlexNode()) {
        self.handle = handle
        self.num = num
        self.flexNode = flexNode
    }
}

// MARK: - Internal Node Record & Staged Mutations

private final class SceneNodeRecord {
    let handle: SceneNodeHandle
    let num: UInt32
    weak var renderable: Renderable?
    weak var standaloneNode: NativeSceneNode?
    let flexNode: FlexNode

    var parent: SceneNodeHandle?
    var children: [SceneNodeHandle] = []
    var viewport: SceneNodeHandle?

    var paint: NativeScenePaint = NativeScenePaint()
    var boxDetails: NativeSceneBoxDetails = NativeSceneBoxDetails()

    var textContent: String?
    var styledText: StyledText?
    var textOptions: NativeSceneTextOptions = NativeSceneTextOptions()
    var textSelection: TextSelectionRange?
    var textSelectionBg: RGBA?
    var textSelectionFg: RGBA?
    var textView: TextBufferView?
    var textViewPaintEnabled: Bool = true
    var renderedTextLines: [String] = []
    var renderedTextLineByteStarts: [Int] = []

    var editorView: EditorView?
    var editorOptions: NativeSceneEditorOptions?

    var sliderOptions: NativeSceneSliderOptions?
    var arrowOptions: NativeSceneArrowOptions?

    var scrollOptions: NativeSceneScrollOptions?
    var scrollState: NativeSceneScrollState = .empty
    var scrollArrows: [Int: NativeSceneArrowOptions] = [:]

    var image: PixelImage?
    var imageFit: ImageFit = .fit
    var imageProtocol: ImageRenderProtocol = .auto
    var imageBuffer: OptimizedBuffer?
    var videoFit: ImageFit?
    var crop: ImageExtractOptions?
    var surface: OptimizedBuffer?

    var focused: Bool = false
    var hookFlags: UInt32 = 0
    var hookGeneration: UInt64 = 0
    var paintedInLastFrame: Bool = false
    var layout: NativeSceneLayout = .zero
    var contentLayout: NativeSceneLayout = .zero
    var flexShorthand: Float = .nan

    init(
        handle: SceneNodeHandle,
        num: UInt32,
        renderable: Renderable?,
        standaloneNode: NativeSceneNode?,
        flexNode: FlexNode
    ) {
        self.handle = handle
        self.num = num
        self.renderable = renderable
        self.standaloneNode = standaloneNode
        self.flexNode = flexNode
    }
}

private enum StagedSceneMutation {
    case style(
        handle: SceneNodeHandle,
        group: YogaStyleGroup,
        kind: Int32,
        edge: Int32,
        unit: Unit,
        value: Float,
        flags: YogaStyleFlags
    )
    case paint(handle: SceneNodeHandle, update: NativeScenePaintUpdate)
    case background(handle: SceneNodeHandle, color: RGBA)
}

// MARK: - NativeScene

/// Pure-Swift retained-mode scene graph & coordinator matching `core/src/NativeScene.ts`.
// parity: core/src/NativeScene.ts#NativeScene [status=adapted hash=a7137830a8a0]
public final class NativeScene: YogaSceneStyleBridge, YogaHostScene, @unchecked Sendable {
    public let driver: NativeSession
    private weak var renderer: CliRenderer?
    private let yogaHost: YogaHost

    private var records: [SceneNodeHandle: SceneNodeRecord] = [:]
    private var handleByNum: [UInt32: SceneNodeHandle] = [:]
    private var handleByObject: [ObjectIdentifier: SceneNodeHandle] = [:]
    private var rootHandle: SceneNodeHandle?
    private var nextStandaloneNum: UInt32 = 100_000

    private var stagedMutations: [StagedSceneMutation] = []
    private var paintedFrame: NativeSceneFrameRequest?
    private var nextFrameId: UInt64 = 1
    private var layoutRevision: UInt64 = 0
    private var destroyed: Bool = false
    private var destroying: Bool = false

    // Last rendered hit grid for `hitTest(x:y:excluded:)`
    private var hitGridWidth: Int = 0
    private var hitGridHeight: Int = 0
    private var hitGrid: [UInt32] = []
    private var paintedHitStack: [(rect: ClipRect, num: UInt32)] = []

    public init(driver: NativeSession, renderer: CliRenderer? = nil) {
        self.driver = driver
        self.renderer = renderer
        self.yogaHost = driver.renderLib.getYogaHost()
    }

    // MARK: Properties

    // parity: core/src/NativeScene.ts#NativeScene.resourceContext [status=implemented hash=bdc62b95bbed]
    public var resourceContext: NativeResourceContext {
        driver.resourceContext
    }

    // parity: core/src/NativeScene.ts#NativeScene.frame [status=implemented hash=28161aafe6ea]
    public var frame: NativeSceneFrameRequest? {
        paintedFrame
    }

    // parity: core/src/NativeScene.ts#NativeScene.observedLayoutRevision [status=implemented hash=a5d44297af4f]
    public var observedLayoutRevision: UInt64? {
        if yogaHost.inCallback || destroyed || driver.disposed { return nil }
        return layoutRevision
    }

    // parity: core/src/NativeScene.ts#NativeScene.hasStagedMutations [status=implemented hash=9129a29aad06]
    public var hasStagedMutations: Bool {
        !stagedMutations.isEmpty
    }

    /// Currently designated scene root handle (first created root or explicitly set).
    public var rootNodeHandle: SceneNodeHandle? {
        get { rootHandle }
        set {
            rootHandle = newValue
            changeLayout()
        }
    }

    /// Number of live nodes owned by this scene.
    public var nodeCount: Int {
        records.count
    }

    // MARK: Staging & Lifecycle

    // parity: core/src/NativeScene.ts#NativeScene.flushStaged [status=implemented hash=beb4b6bc285e]
    public func flushStaged() throws {
        if destroyed || driver.disposed {
            stagedMutations.removeAll()
            yogaHost.forgetScene(self)
            return
        }
        guard !stagedMutations.isEmpty else { return }
        let batch = stagedMutations
        stagedMutations.removeAll(keepingCapacity: true)
        yogaHost.forgetScene(self)
        for mutation in batch {
            applyStagedMutation(mutation)
        }
    }

    // parity: core/src/NativeScene.ts#NativeScene.getRenderables [status=implemented hash=f950d40d60ac]
    public func getRenderables() -> [Renderable] {
        records.values.compactMap(\.renderable)
    }

    // parity: core/src/NativeScene.ts#NativeScene.assertAlive [status=implemented hash=7bfbeb80f4b8]
    public func assertAlive() throws(NativeSceneError) {
        if destroyed || driver.disposed {
            throw .destroyed
        }
    }

    // MARK: Node CRUD & Tree Operations

    /// Registers a `Renderable` in this retained scene.
    // parity: core/src/NativeScene.ts#NativeScene.createNode [status=adapted hash=8b83c0a43977]
    @discardableResult
    public func createNode(
        _ renderable: Renderable,
        options: RenderableOptions = RenderableOptions()
    ) throws -> SceneNodeHandle {
        try yogaHost.assertMutable()
        try assertAlive()
        if destroying { throw NativeSceneError.destroying }
        let handle = resourceContext.allocateNodeHandle()
        let record = SceneNodeRecord(
            handle: handle,
            num: renderable.num,
            renderable: renderable,
            standaloneNode: nil,
            flexNode: renderable.layoutNode
        )
        record.paint.zIndex = options.zIndex ?? renderable.zIndex
        record.paint.opacity = options.opacity ?? renderable.opacity
        record.paint.focusable = options.focusable ?? renderable.focusable
        records[handle] = record
        handleByNum[renderable.num] = handle
        handleByObject[ObjectIdentifier(renderable)] = handle
        if rootHandle == nil {
            rootHandle = handle
        }
        changeLayout()
        return handle
    }

    /// Creates a standalone retained scene node without requiring a `Renderable` wrapper.
    @discardableResult
    public func createStandaloneNode(
        num: UInt32? = nil,
        style: FlexStyle = FlexStyle()
    ) throws -> NativeSceneNode {
        try yogaHost.assertMutable()
        try assertAlive()
        if destroying { throw NativeSceneError.destroying }
        let assignedNum: UInt32
        if let num {
            assignedNum = num
        } else {
            assignedNum = nextStandaloneNum
            nextStandaloneNum &+= 1
            if nextStandaloneNum == 0 { nextStandaloneNum = 100_000 }
        }
        let handle = resourceContext.allocateNodeHandle()
        let flex = FlexNode(style: style)
        let node = NativeSceneNode(handle: handle, num: assignedNum, flexNode: flex)
        let record = SceneNodeRecord(
            handle: handle,
            num: assignedNum,
            renderable: nil,
            standaloneNode: node,
            flexNode: flex
        )
        records[handle] = record
        handleByNum[assignedNum] = handle
        handleByObject[ObjectIdentifier(node)] = handle
        if rootHandle == nil {
            rootHandle = handle
        }
        changeLayout()
        return node
    }

    /// Attaches, detaches (`parent == nil`), or reorders `child` at `index`.
    // parity: core/src/NativeScene.ts#NativeScene.moveNode [status=adapted hash=598ee138ef96]
    public func moveNode(_ child: AnyObject, parent: AnyObject?, index: Int) throws {
        let childHandle = try resolveHandle(child)
        let parentHandle = try parent.map { try resolveHandle($0) }
        try moveNode(handle: childHandle, parent: parentHandle, index: index)
    }

    public func moveNode(handle childHandle: SceneNodeHandle, parent parentHandle: SceneNodeHandle?, index: Int) throws {
        try assertAlive()
        guard let childRecord = records[childHandle] else {
            throw NativeSceneError.nodeNotFound
        }
        if let oldParentHandle = childRecord.parent, let oldParent = records[oldParentHandle] {
            oldParent.children.removeAll { $0 == childHandle }
            oldParent.flexNode.removeChild(childRecord.flexNode)
        }
        childRecord.parent = parentHandle
        if let parentHandle {
            guard let parentRecord = records[parentHandle] else {
                throw NativeSceneError.nodeNotFound
            }
            let clamped = max(0, min(index, parentRecord.children.count))
            parentRecord.children.insert(childHandle, at: clamped)
            parentRecord.flexNode.insertChild(childRecord.flexNode, at: clamped)
        }
        changeLayout()
    }

    // parity: core/src/NativeScene.ts#NativeScene.setViewport [status=adapted hash=0fa0f6366a87]
    public func setViewport(_ content: AnyObject, viewport: AnyObject?) throws {
        try flushStaged()
        let contentHandle = try resolveHandle(content)
        let viewportHandle = try viewport.map { try resolveHandle($0) }
        records[contentHandle]?.viewport = viewportHandle
    }

    // parity: core/src/NativeScene.ts#NativeScene.setFocus [status=adapted hash=36a5b3e0fb57]
    public func setFocus(_ node: AnyObject, focused: Bool) throws {
        try flushStaged()
        let handle = try resolveHandle(node)
        records[handle]?.focused = focused
    }

    // parity: core/src/NativeScene.ts#NativeScene.destroyNode [status=adapted hash=8d16b640e8c3]
    public func destroyNode(_ node: AnyObject) throws {
        try yogaHost.assertMutable()
        let handle = try resolveHandle(node)
        try destroyNode(handle: handle)
    }

    public func destroyNode(handle: SceneNodeHandle) throws {
        try yogaHost.assertMutable()
        try? flushStaged()
        guard let record = records.removeValue(forKey: handle) else { return }

        if let parentHandle = record.parent, let parentRecord = records[parentHandle] {
            parentRecord.children.removeAll { $0 == handle }
            parentRecord.flexNode.removeChild(record.flexNode)
        }
        for childHandle in record.children {
            records[childHandle]?.parent = nil
            if let childFlex = records[childHandle]?.flexNode {
                record.flexNode.removeChild(childFlex)
            }
        }
        record.children.removeAll()

        stagedMutations.removeAll { mutation in
            switch mutation {
            case .style(let h, _, _, _, _, _, _),
                 .paint(let h, _),
                 .background(let h, _):
                return h == handle
            }
        }
        if stagedMutations.isEmpty {
            yogaHost.forgetScene(self)
        }

        handleByNum.removeValue(forKey: record.num)
        if let renderable = record.renderable {
            handleByObject.removeValue(forKey: ObjectIdentifier(renderable))
            renderer?.unregisterLifecyclePass(renderable)
        }
        if let standalone = record.standaloneNode {
            handleByObject.removeValue(forKey: ObjectIdentifier(standalone))
        }
        if rootHandle == handle {
            rootHandle = nil
        }
        changeLayout()
    }

    // MARK: Hooks, Style Staging & Measurement

    // parity: core/src/NativeScene.ts#NativeScene.setHooks [status=adapted hash=c466ae0e8e83]
    public func setHooks(
        _ node: AnyObject,
        flags: UInt32,
        generation: UInt64,
        initialWidth: Int = 0,
        initialHeight: Int = 0
    ) throws {
        try flushStaged()
        let handle = try resolveHandle(node)
        guard let record = records[handle] else { throw NativeSceneError.nodeNotFound }
        record.hookFlags = flags
        record.hookGeneration = generation
        if initialWidth > 0 { record.layout.width = Float(initialWidth) }
        if initialHeight > 0 { record.layout.height = Float(initialHeight) }
    }

    // parity: core/src/NativeScene.ts#NativeScene.setStyle [status=implemented hash=f7d98d302e94]
    public func setStyle(
        node: AnyObject,
        group: YogaStyleGroup,
        kind: Int32,
        edge: Int32,
        unit: Unit,
        value: Float,
        flags: YogaStyleFlags = .none
    ) throws {
        try yogaHost.assertMutable()
        let handle = try resolveHandle(node)
        stagedMutations.append(.style(
            handle: handle,
            group: group,
            kind: kind,
            edge: edge,
            unit: unit,
            value: value,
            flags: flags
        ))
        yogaHost.stageScene(self)
    }

    // parity: core/src/NativeScene.ts#NativeScene.getStyle [status=implemented hash=3f7ced88b780]
    public func getStyle(
        node: AnyObject,
        group: YogaStyleGroup,
        kind: Int32,
        edge: Int32
    ) throws -> YogaValue {
        let handle = try resolveHandle(node)
        try flushStaged()
        guard let record = records[handle] else { throw NativeSceneError.nodeNotFound }
        return readStyle(from: record, group: group, kind: kind, edge: edge)
    }

    // parity: core/src/NativeScene.ts#NativeScene.setMeasureFunc [status=implemented hash=4912f2f90738]
    public func setMeasureFunc(_ node: AnyObject, measure: FlexMeasureFunc?) throws {
        try flushStaged()
        let handle = try resolveHandle(node)
        guard let record = records[handle] else { throw NativeSceneError.nodeNotFound }
        record.flexNode.setMeasureFunc(measure)
    }

    // parity: core/src/NativeScene.ts#NativeScene.hasMeasureFunc [status=implemented hash=0cc877069bf0]
    public func hasMeasureFunc(_ node: AnyObject) throws -> Bool {
        try flushStaged()
        let handle = try resolveHandle(node)
        guard let record = records[handle] else { throw NativeSceneError.nodeNotFound }
        return record.flexNode.hasMeasureFunc
    }

    // parity: core/src/NativeScene.ts#NativeScene.reachesHooks [status=implemented hash=ecce10eb31d7]
    public func reachesHooks(_ node: AnyObject) throws -> Bool {
        try flushStaged()
        let handle = try resolveHandle(node)
        return subtreeHasHooks(handle)
    }

    // parity: core/src/NativeScene.ts#NativeScene.painted [status=implemented hash=dce3ec8bc447]
    public func painted(_ node: AnyObject) throws -> Bool {
        try flushStaged()
        let handle = try resolveHandle(node)
        return records[handle]?.paintedInLastFrame ?? false
    }

    // parity: core/src/NativeScene.ts#NativeScene.markDirty [status=implemented hash=1a15675a2f02]
    public func markDirty(_ node: AnyObject) throws {
        try flushStaged()
        let handle = try resolveHandle(node)
        records[handle]?.flexNode.markDirty()
    }

    // parity: core/src/NativeScene.ts#NativeScene.setPositions [status=implemented hash=97523b687cd7]
    public func setPositions(
        _ node: AnyObject,
        mask: Int,
        units: [Unit],
        values: [Float]
    ) throws {
        let edgeMaskMax = (1 << (Int(Edge.bottom.rawValue) + 1)) - 1
        guard mask >= 0 && mask <= edgeMaskMax else {
            throw NativeSceneError.invalidPositionMask(mask)
        }
        for edgeIndex in 0...Int(Edge.bottom.rawValue) {
            if (mask & (1 << edgeIndex)) == 0 { continue }
            guard edgeIndex < units.count && edgeIndex < values.count else {
                throw NativeSceneError.invalidPositionMask(mask)
            }
            try setStyle(
                node: node,
                group: .value,
                kind: YogaValueKind.position.rawValue,
                edge: Int32(edgeIndex),
                unit: units[edgeIndex],
                value: values[edgeIndex],
                flags: .none
            )
        }
    }

    // MARK: Paint, Background & Box Details

    // parity: core/src/NativeScene.ts#NativeScene.setPaint [status=implemented hash=53891f0f932e]
    public func setPaint(_ node: AnyObject, _ paint: NativeScenePaintUpdate) throws {
        try yogaHost.assertMutable()
        let handle = try resolveHandle(node)
        let current = records[handle]?.paint
        stagedMutations.append(.paint(handle: handle, update: paint))
        yogaHost.stageScene(self)
        if let current {
            let newTx = paint.translateX ?? current.translateX
            let newTy = paint.translateY ?? current.translateY
            if newTx != current.translateX || newTy != current.translateY {
                changeLayout()
            }
        }
    }

    // parity: core/src/NativeScene.ts#NativeScene.setBackground [status=implemented hash=d756907a3383]
    public func setBackground(_ node: AnyObject, color: RGBA) throws {
        try yogaHost.assertMutable()
        let handle = try resolveHandle(node)
        stagedMutations.append(.background(handle: handle, color: color))
        yogaHost.stageScene(self)
    }

    // parity: core/src/NativeScene.ts#NativeScene.setBoxDetails [status=implemented hash=ba3d4d7bd101]
    public func setBoxDetails(_ node: AnyObject, details: NativeSceneBoxDetails) throws {
        try flushStaged()
        let handle = try resolveHandle(node)
        records[handle]?.boxDetails = details
    }

    // parity: core/src/NativeScene.ts#NativeScene.setBoxBorderStyle [status=implemented hash=cca33051a3ac]
    public func setBoxBorderStyle(_ node: AnyObject, style: BorderStyle, sides: NativeBorderMask) throws {
        try setPaint(node, NativeScenePaintUpdate(border: sides, borderStyle: style, resetBorderCharacters: true))
    }

    // MARK: Text, Selection & Metrics

    // parity: core/src/NativeScene.ts#NativeScene.setText [status=implemented hash=0a2ed3038c23]
    public func setText(_ node: AnyObject, content: TextContent) throws {
        try flushStaged()
        let handle = try resolveHandle(node)
        guard let record = records[handle] else { throw NativeSceneError.nodeNotFound }
        switch content {
        case .string(let s):
            record.textContent = s
            record.styledText = nil
        case .styled(let st):
            record.styledText = st
            record.textContent = st.chunks.map(\.text).joined()
        }
        record.flexNode.markDirty()
    }

    public func setText(_ node: AnyObject, _ content: String) throws {
        try setText(node, content: .string(content))
    }

    public func setText(_ node: AnyObject, _ content: StyledText) throws {
        try setText(node, content: .styled(content))
    }

    // parity: core/src/NativeScene.ts#NativeScene.textNode [status=implemented hash=4fc8a400c53c]
    public func textNode(_ node: AnyObject) throws -> SceneNodeHandle {
        try flushStaged()
        return try resolveHandle(node)
    }

    // parity: core/src/NativeScene.ts#NativeScene.textByteAt [status=implemented hash=264653dd7b5f]
    public func textByteAt(_ node: AnyObject, x: Int, y: Int) throws -> Int? {
        let handle = try textNode(node)
        guard let record = records[handle] else { return nil }
        let localX = x - record.layout.screenX
        let localY = y - record.layout.screenY
        guard localX >= 0 && localY >= 0 && localY < record.renderedTextLines.count else { return nil }
        let line = record.renderedTextLines[localY]
        let baseByte = localY < record.renderedTextLineByteStarts.count ? record.renderedTextLineByteStarts[localY] : 0
        var col = 0
        var byteOffset = 0
        for ch in line {
            let w = max(1, Int(calculateTextWidth(String(ch), widthMethod: .unicode)))
            if localX >= col && localX < col + w {
                return baseByte + byteOffset
            }
            col += w
            byteOffset += String(ch).utf8.count
        }
        return nil
    }

    // parity: core/src/NativeScene.ts#NativeScene.setTextOptions [status=implemented hash=bfb94cd4ecd3]
    public func setTextOptions(_ node: AnyObject, options: NativeSceneTextOptions) throws {
        try flushStaged()
        let handle = try resolveHandle(node)
        records[handle]?.textOptions = options
        records[handle]?.flexNode.markDirty()
    }

    // parity: core/src/NativeScene.ts#NativeScene.getText [status=implemented hash=59af1d4f848a]
    public func getText(_ node: AnyObject) throws -> String {
        try flushStaged()
        let handle = try resolveHandle(node)
        return records[handle]?.textContent ?? ""
    }

    // parity: core/src/NativeScene.ts#NativeScene.drawBody [status=implemented hash=ae8d31c4a571]
    public func drawBody(_ node: AnyObject, buffer: OptimizedBuffer, x: Int, y: Int) throws {
        try flushStaged()
        let handle = try resolveHandle(node)
        guard let record = records[handle] else { throw NativeSceneError.nodeNotFound }
        paintRecordBody(record, into: buffer, screenX: x, screenY: y, width: Int(record.layout.width), height: Int(record.layout.height))
    }

    // parity: core/src/NativeScene.ts#NativeScene.setTextSelection [status=implemented hash=d497896c17b6]
    @discardableResult
    public func setTextSelection(
        _ node: AnyObject,
        operation: NativeSceneTextSelectionOp,
        bounds: LocalSelectionBounds?,
        bg: RGBA? = nil,
        fg: RGBA? = nil
    ) throws -> Bool {
        try flushStaged()
        let handle = try resolveHandle(node)
        guard let record = records[handle] else { throw NativeSceneError.nodeNotFound }
        switch operation {
        case .reset:
            let hadSelection = record.textSelection != nil
            record.textSelection = nil
            return hadSelection
        case .colors:
            record.textSelectionBg = bg
            record.textSelectionFg = fg
            return record.textSelection != nil
        case .set, .update:
            record.textSelectionBg = bg ?? record.textSelectionBg
            record.textSelectionFg = fg ?? record.textSelectionFg
            guard let bounds, bounds.isActive else {
                record.textSelection = nil
                return false
            }
            let text = record.textContent ?? ""
            let total = text.count
            let start = max(0, min(total, min(bounds.anchorX, bounds.focusX)))
            let end = max(start, min(total, max(bounds.anchorX, bounds.focusX) + (bounds.behavior == .cell ? 1 : 0)))
            record.textSelection = TextSelectionRange(start: start, end: end)
            return end > start
        }
    }

    // parity: core/src/NativeScene.ts#NativeScene.getTextSelection [status=implemented hash=b2b2f03e347d]
    public func getTextSelection(_ node: AnyObject) throws -> TextSelectionRange? {
        try flushStaged()
        let handle = try resolveHandle(node)
        return records[handle]?.textSelection
    }

    // parity: core/src/NativeScene.ts#NativeScene.getSelectedText [status=implemented hash=9ecf8371e6c0]
    public func getSelectedText(_ node: AnyObject) throws -> String {
        try flushStaged()
        let handle = try resolveHandle(node)
        guard let record = records[handle],
              let sel = record.textSelection,
              let text = record.textContent,
              sel.start < sel.end
        else {
            return ""
        }
        let chars = Array(text)
        let s = max(0, min(chars.count, sel.start))
        let e = max(s, min(chars.count, sel.end))
        return String(chars[s..<e])
    }

    // parity: core/src/NativeScene.ts#NativeScene.getTextLineInfo [status=implemented hash=05ad7313cd82]
    public func getTextLineInfo(
        _ node: AnyObject,
        firstLine: Int = 0,
        lineCount: Int? = nil
    ) throws -> LineInfo {
        try flushStaged()
        let handle = try resolveHandle(node)
        guard let record = records[handle] else { return LineInfo() }
        let rawLines = splitLines(record.textContent ?? "")
        let start = max(0, min(firstLine, rawLines.count))
        let count = lineCount.map { max(0, min($0, rawLines.count - start)) } ?? (rawLines.count - start)
        var starts: [Int] = []
        var widths: [Int] = []
        var sources: [Int] = []
        var wraps: [Int] = []
        var maxWidth = 0
        var colCursor = 0
        for idx in 0..<rawLines.count {
            let w = Int(calculateTextWidth(rawLines[idx], widthMethod: .unicode))
            if idx >= start && idx < start + count {
                starts.append(colCursor)
                widths.append(w)
                sources.append(idx)
                wraps.append(0)
                if w > maxWidth { maxWidth = w }
            }
            colCursor += w + 1
        }
        return LineInfo(
            lineStartCols: starts,
            lineWidthCols: widths,
            lineWidthColsMax: maxWidth,
            lineSources: sources,
            lineWraps: wraps
        )
    }

    // parity: core/src/NativeScene.ts#NativeScene.getTextMetrics [status=implemented hash=e45ff0868108]
    public func getTextMetrics(_ node: AnyObject) throws -> NativeSceneTextMetrics {
        try flushStaged()
        let handle = try resolveHandle(node)
        guard let record = records[handle] else { return NativeSceneTextMetrics() }
        let text = record.textContent ?? ""
        let lines = splitLines(text)
        var maxCols = 0
        for line in lines {
            let w = Int(calculateTextWidth(line, widthMethod: .unicode))
            if w > maxCols { maxCols = w }
        }
        return NativeSceneTextMetrics(
            byteLength: text.utf8.count,
            textLength: text.utf16.count,
            lineCount: lines.count,
            virtualLineCount: max(lines.count, record.renderedTextLines.count),
            widthColsMax: maxCols
        )
    }

    // MARK: Slider, Arrow, Image, Video & Surfaces

    // parity: core/src/NativeScene.ts#NativeScene.setSlider [status=implemented hash=a1d5b50c8180]
    public func setSlider(_ node: AnyObject, options: NativeSceneSliderOptions) throws {
        try flushStaged()
        let handle = try resolveHandle(node)
        records[handle]?.sliderOptions = options
    }

    // parity: core/src/NativeScene.ts#NativeScene.getSliderThumb [status=implemented hash=f05e1566059f]
    public func getSliderThumb(_ node: AnyObject) throws -> SliderThumb {
        try flushStaged()
        let handle = try resolveHandle(node)
        guard let record = records[handle], let slider = record.sliderOptions else {
            return SliderThumb(size: 0, start: 0)
        }
        return computeSliderThumb(
            orientation: slider.orientation,
            min: slider.min,
            max: slider.max,
            value: slider.value,
            viewPortSize: slider.viewPortSize,
            width: Int(record.layout.width),
            height: Int(record.layout.height)
        )
    }

    // parity: core/src/NativeScene.ts#NativeScene.setArrow [status=implemented hash=46310b57f37e]
    public func setArrow(_ node: AnyObject, options: NativeSceneArrowOptions) throws {
        try flushStaged()
        let handle = try resolveHandle(node)
        records[handle]?.arrowOptions = options
    }

    // parity: core/src/NativeScene.ts#NativeScene.setImage [status=implemented hash=eab609285894]
    public func setImage(
        _ node: AnyObject,
        image: PixelImage?,
        fit: ImageFit,
        protocol imageProtocol: ImageRenderProtocol,
        buffer: OptimizedBuffer?
    ) throws {
        try flushStaged()
        let handle = try resolveHandle(node)
        guard let record = records[handle] else { throw NativeSceneError.nodeNotFound }
        record.image = image
        record.imageFit = fit
        record.imageProtocol = imageProtocol
        record.imageBuffer = buffer
    }

    // parity: core/src/NativeScene.ts#NativeScene.setVideo [status=implemented hash=a39e7ac2d660]
    public func setVideo(_ node: AnyObject, fit: ImageFit, buffer: OptimizedBuffer?) throws {
        try flushStaged()
        let handle = try resolveHandle(node)
        guard let record = records[handle] else { throw NativeSceneError.nodeNotFound }
        record.videoFit = fit
        record.imageBuffer = buffer
    }

    // parity: core/src/NativeScene.ts#NativeScene.setCrop [status=implemented hash=755d849b728e]
    public func setCrop(_ node: AnyObject, crop: ImageExtractOptions?) throws {
        try flushStaged()
        let handle = try resolveHandle(node)
        records[handle]?.crop = crop
    }

    // parity: core/src/NativeScene.ts#NativeScene.videoNode [status=adapted hash=114b6995d958]
    public func videoNode(_ node: AnyObject) throws -> (context: NativeContextHandle, node: SceneNodeHandle) {
        try flushStaged()
        return (driver.context, try resolveHandle(node))
    }

    // MARK: Scroll State & Queries

    // parity: core/src/NativeScene.ts#NativeScene.setScroll [status=implemented hash=fc8526cb6f55]
    public func setScroll(_ node: AnyObject, options: NativeSceneScrollOptions) throws {
        try flushStaged()
        let handle = try resolveHandle(node)
        records[handle]?.scrollOptions = options
        if let record = records[handle] {
            recomputeScrollState(for: record)
        }
        changeLayout()
    }

    // parity: core/src/NativeScene.ts#NativeScene.setScrollArrow [status=implemented hash=6ef482899895]
    public func setScrollArrow(
        _ node: AnyObject,
        axis: Int,
        end: Int,
        options: NativeSceneArrowOptions
    ) throws {
        try flushStaged()
        let handle = try resolveHandle(node)
        records[handle]?.scrollArrows[(axis << 1) | (end & 1)] = options
    }

    // parity: core/src/NativeScene.ts#NativeScene.scrollTo [status=implemented hash=7ca89b932d77]
    @discardableResult
    public func scrollTo(
        _ node: AnyObject,
        x: Double,
        y: Double,
        relativeX: Bool = false,
        relativeY: Bool = false,
        reapply: Bool = false
    ) throws -> NativeSceneScrollState {
        try flushStaged()
        let handle = try resolveHandle(node)
        guard let record = records[handle] else { throw NativeSceneError.nodeNotFound }
        _ = reapply
        recomputeScrollState(for: record)
        let targetX = relativeX ? (record.scrollState.offsetX + x) : x
        let targetY = relativeY ? (record.scrollState.offsetY + y) : y
        let clampedX = max(0, min(record.scrollState.maxX, targetX))
        let clampedY = max(0, min(record.scrollState.maxY, targetY))
        var changes: UInt32 = 0
        if clampedX != record.scrollState.offsetX { changes |= 1 }
        if clampedY != record.scrollState.offsetY { changes |= 2 }
        record.scrollState.offsetX = clampedX
        record.scrollState.offsetY = clampedY
        record.scrollState.changes = changes
        updateScrollBarThumbs(for: record)
        changeLayout()
        return record.scrollState
    }

    // parity: core/src/NativeScene.ts#NativeScene.scrollRequest [status=implemented hash=38271162731a]
    @discardableResult
    public func scrollRequest(
        _ node: AnyObject,
        kind: NativeSceneScrollRequestKind,
        target: AnyObject? = nil,
        align: NativeSceneScrollAlign = .nearest,
        inset: Double = 0
    ) throws -> NativeSceneScrollState {
        try flushStaged()
        let handle = try resolveHandle(node)
        guard let record = records[handle] else { throw NativeSceneError.nodeNotFound }
        recomputeScrollState(for: record)

        switch kind {
        case .layout:
            break
        case .anchor:
            if let follow = record.scrollOptions?.follow {
                switch follow {
                case .top: record.scrollState.offsetY = 0
                case .bottom: record.scrollState.offsetY = record.scrollState.maxY
                case .left: record.scrollState.offsetX = 0
                case .right: record.scrollState.offsetX = record.scrollState.maxX
                case .none: break
                }
            }
        case .intoView:
            if let target,
               let targetHandle = try? resolveHandle(target),
               let targetRecord = records[targetHandle]
            {
                let itemTop = Double(targetRecord.layout.top)
                let itemBottom = Double(targetRecord.layout.top + targetRecord.layout.height)
                let viewH = record.scrollState.viewport.height
                var nextY = record.scrollState.offsetY
                switch align {
                case .start:
                    nextY = itemTop - inset
                case .end:
                    nextY = itemBottom - viewH + inset
                case .nearest:
                    if itemTop - inset < nextY {
                        nextY = itemTop - inset
                    } else if itemBottom + inset > nextY + viewH {
                        nextY = itemBottom + inset - viewH
                    }
                }
                record.scrollState.offsetY = max(0, min(record.scrollState.maxY, nextY))
            }
        }

        updateScrollBarThumbs(for: record)
        changeLayout()
        return record.scrollState
    }

    // parity: core/src/NativeScene.ts#NativeScene.getScroll [status=implemented hash=ca40ec69e3f3]
    public func getScroll(_ node: AnyObject) throws -> NativeSceneScrollState {
        try flushStaged()
        let handle = try resolveHandle(node)
        guard let record = records[handle] else { return .empty }
        recomputeScrollState(for: record)
        return record.scrollState
    }

    // MARK: Editor, TextView & Surface Attachments

    // parity: core/src/NativeScene.ts#NativeScene.setEditorView [status=adapted hash=e487e2dc5dc4]
    public func setEditorView(_ node: AnyObject, view: EditorView?) throws {
        try flushStaged()
        let handle = try resolveHandle(node)
        records[handle]?.editorView = view
    }

    // parity: core/src/NativeScene.ts#NativeScene.setSurface [status=implemented hash=c8e3d2d108dd]
    public func setSurface(_ node: AnyObject, buffer: OptimizedBuffer?) throws {
        try flushStaged()
        let handle = try resolveHandle(node)
        records[handle]?.surface = buffer
    }

    // parity: core/src/NativeScene.ts#NativeScene.setTextView [status=adapted hash=efe5dcc496ad]
    public func setTextView(_ node: AnyObject, view: TextBufferView?) throws {
        try flushStaged()
        let handle = try resolveHandle(node)
        records[handle]?.textView = view
    }

    // parity: core/src/NativeScene.ts#NativeScene.setTextViewPaint [status=implemented hash=e9f53912c170]
    public func setTextViewPaint(_ node: AnyObject, enabled: Bool) throws {
        try flushStaged()
        let handle = try resolveHandle(node)
        records[handle]?.textViewPaintEnabled = enabled
    }

    // parity: core/src/NativeScene.ts#NativeScene.setEditorOptions [status=implemented hash=8f8e079184f5]
    public func setEditorOptions(_ node: AnyObject, options: NativeSceneEditorOptions) throws {
        try flushStaged()
        let handle = try resolveHandle(node)
        records[handle]?.editorOptions = options
    }

    // MARK: Layout Computation & Queries

    /// Computes Flexbox layout for the scene tree using `FlexSolver`.
    public func computeLayout(width: Int, height: Int, direction: Direction = .ltr) throws {
        try assertAlive()
        try flushStaged()
        guard let rootHandle, let rootRecord = records[rootHandle] else { return }

        FlexSolver.calculateLayout(
            root: rootRecord.flexNode,
            availableWidth: Float(max(0, width)),
            availableHeight: Float(max(0, height)),
            direction: direction
        )
        syncLayoutsRecursively(handle: rootHandle, parentScreenX: 0, parentScreenY: 0)
        changeLayout()
    }

    // parity: core/src/NativeScene.ts#NativeScene.getLayout [status=implemented hash=5fcfc1f24dd0]
    public func getLayout(
        _ node: AnyObject,
        kind: NativeSceneLayoutKind = .computed
    ) throws -> NativeSceneLayout {
        let handle = try resolveHandle(node)
        try flushStaged()
        guard let record = records[handle] else { throw NativeSceneError.nodeNotFound }
        switch kind {
        case .content:
            return record.contentLayout
        case .rawYoga:
            let cl = record.flexNode.computedLayout
            return NativeSceneLayout(
                left: cl.left,
                top: cl.top,
                right: cl.right,
                bottom: cl.bottom,
                width: cl.width,
                height: cl.height,
                screenX: Int(cl.left.rounded(.toNearestOrAwayFromZero)),
                screenY: Int(cl.top.rounded(.toNearestOrAwayFromZero))
            )
        case .computed, .paint:
            return record.layout
        }
    }

    // parity: core/src/NativeScene.ts#NativeScene.measureSnapshot [status=adapted hash=94650f584c7f]
    public func measureSnapshot(_ root: AnyObject, availableWidth: Float? = nil) throws -> Int {
        try yogaHost.assertMutable()
        try assertAlive()
        if paintedFrame != nil {
            throw NativeSceneError.snapshotDuringFrame
        }
        let handle = try resolveHandle(root)
        try flushStaged()
        guard let record = records[handle] else { throw NativeSceneError.nodeNotFound }
        let widthHint: Float?
        if let availableWidth {
            widthHint = availableWidth
        } else if driver.rendererState.width > 0 {
            widthHint = Float(driver.rendererState.width)
        } else {
            widthHint = nil
        }
        FlexSolver.calculateLayout(
            root: record.flexNode,
            availableWidth: widthHint,
            availableHeight: nil,
            direction: .ltr
        )
        syncLayoutsRecursively(handle: handle, parentScreenX: 0, parentScreenY: 0)
        changeLayout()
        return max(1, Int(record.flexNode.computedHeight))
    }

    // MARK: Rendering, Frame Commit & Hit Testing

    /// Renders the retained scene graph directly into `buffer` (computing layout first if `computeLayout` is true).
    public func render(
        into buffer: OptimizedBuffer,
        options: NativeScenePaintOptions = NativeScenePaintOptions(),
        performLayout: Bool = true
    ) throws {
        try assertAlive()
        try flushStaged()
        if performLayout {
            try computeLayout(width: buffer.width, height: buffer.height)
        }
        if !options.preserveUnwritten {
            buffer.clear(bg: options.background)
        }
        buffer.clearHitGrid()
        hitGridWidth = buffer.width
        hitGridHeight = buffer.height
        hitGrid = Array(repeating: 0, count: max(0, buffer.width * buffer.height))
        paintedHitStack.removeAll(keepingCapacity: true)

        for record in records.values {
            record.paintedInLastFrame = false
        }

        if let rootHandle {
            paintSubtree(
                handle: rootHandle,
                into: buffer,
                useMouse: options.useMouse,
                excludedHitNum: options.excludedHitNum
            )
        }
    }

    // parity: core/src/NativeScene.ts#NativeScene.paint [status=adapted hash=9d638f6e596f]
    public func paint(
        deltaTime: Double = 0,
        getPaintOptions: () -> NativeScenePaintOptions = { NativeScenePaintOptions() }
    ) throws {
        try yogaHost.assertMutable()
        try assertAlive()
        if paintedFrame != nil {
            throw NativeSceneError.frameAlreadyPainting
        }
        _ = deltaTime
        let opts = getPaintOptions()
        try flushStaged()

        let width = driver.diffRenderer?.width ?? max(1, driver.rendererState.width)
        let height = driver.diffRenderer?.height ?? max(1, driver.rendererState.height)

        if let targetBuffer = driver.diffRenderer?.nextBuffer {
            try render(into: targetBuffer, options: opts, performLayout: true)
        } else {
            try computeLayout(width: width, height: height)
        }

        let fid = nextFrameId
        nextFrameId &+= 1
        let root = rootHandle ?? resourceContext.allocateNodeHandle()
        paintedFrame = NativeSceneFrameRequest(
            session: driver.session,
            root: root,
            node: root,
            frameId: fid,
            requestId: fid,
            layoutEpoch: layoutRevision,
            hookGeneration: 0,
            kind: .done,
            num: records[root]?.num ?? 0,
            width: width,
            height: height,
            paintLayout: records[root]?.layout,
            publicLayout: records[root]?.layout
        )
    }

    // parity: core/src/NativeScene.ts#NativeScene.commit [status=implemented hash=d0cf09e90abc]
    @discardableResult
    public func commit(force: Bool = false) throws -> NativeSessionRenderStatus {
        guard let frame = paintedFrame else {
            throw NativeSceneError.noPaintedFrame
        }
        let result = try driver.render(force: force, frame: frame)
        paintedFrame = nullFrame()
        return result
    }

    // parity: core/src/NativeScene.ts#NativeScene.commitSplit [status=implemented hash=fa7a97c1bfb1]
    @discardableResult
    public func commitSplit(
        commits: [NativeSplitSnapshot],
        pinnedRenderOffset: Int,
        force: Bool = false
    ) throws -> (status: NativeSessionRenderStatus, bytesEmitted: Int) {
        guard let frame = paintedFrame else {
            throw NativeSceneError.noPaintedFrame
        }
        let result = try driver.renderSplit(
            frame: frame,
            commits: commits,
            pinnedRenderOffset: pinnedRenderOffset,
            force: force
        )
        paintedFrame = nullFrame()
        return result
    }

    // parity: core/src/NativeScene.ts#NativeScene.cancelFrame [status=implemented hash=a2e1f1d072b4]
    public func cancelFrame() {
        if paintedFrame != nil {
            paintedFrame = nil
            changeLayout()
        }
    }

    // parity: core/src/NativeScene.ts#NativeScene.hitTest [status=implemented hash=27a5e188f17a]
    public func hitTest(x: Int, y: Int, excluded: UInt32 = 0) throws -> UInt32 {
        try assertAlive()
        guard x >= 0 && y >= 0 && x < hitGridWidth && y < hitGridHeight else { return 0 }
        // Search painted hit stack top-down so excluded IDs fall through to lower layers.
        for entry in paintedHitStack.reversed() {
            if entry.num == excluded { continue }
            let r = entry.rect
            if x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height {
                if let handle = handleByNum[entry.num], let record = records[handle] {
                    if let renderable = record.renderable, renderable.isDestroyed { continue }
                    return entry.num
                }
            }
        }
        let idx = y * hitGridWidth + x
        let id = idx < hitGrid.count ? hitGrid[idx] : 0
        if id == 0 || id == excluded { return 0 }
        return handleByNum[id] != nil ? id : 0
    }

    // parity: core/src/NativeScene.ts#NativeScene.destroy [status=implemented hash=9e6874fcc086]
    public func destroy() {
        if destroyed || destroying { return }
        destroying = true
        stagedMutations.removeAll()
        yogaHost.forgetScene(self)
        paintedFrame = nil
        for record in records.values {
            record.children.removeAll()
            record.parent = nil
            record.flexNode.removeAllChildren()
        }
        records.removeAll()
        handleByNum.removeAll()
        handleByObject.removeAll()
        rootHandle = nil
        hitGrid.removeAll()
        paintedHitStack.removeAll()
        destroyed = true
        destroying = false
    }

    // MARK: Private Helpers

    private func nullFrame() -> NativeSceneFrameRequest? { nil }

    private func changeLayout() {
        layoutRevision = layoutRevision == UInt64.max ? 0 : (layoutRevision &+ 1)
    }

    private func resolveHandle(_ node: AnyObject) throws -> SceneNodeHandle {
        if let standalone = node as? NativeSceneNode {
            guard records[standalone.handle] != nil else { throw NativeSceneError.nodeNotFound }
            return standalone.handle
        }
        if let handle = handleByObject[ObjectIdentifier(node)] {
            return handle
        }
        if let renderable = node as? Renderable, let handle = handleByNum[renderable.num] {
            return handle
        }
        throw NativeSceneError.nodeNotFound
    }

    private func subtreeHasHooks(_ handle: SceneNodeHandle) -> Bool {
        guard let record = records[handle] else { return false }
        if record.hookFlags != 0 { return true }
        for child in record.children {
            if subtreeHasHooks(child) { return true }
        }
        return false
    }

    private func applyStagedMutation(_ mutation: StagedSceneMutation) {
        switch mutation {
        case .style(let handle, let group, let kind, let edge, let unit, let value, let flags):
            guard let record = records[handle] else { return }
            applyStyle(to: record, group: group, kind: kind, edge: edge, unit: unit, value: value, flags: flags)
        case .paint(let handle, let update):
            guard let record = records[handle] else { return }
            if let z = update.zIndex { record.paint.zIndex = z }
            if let o = update.opacity { record.paint.opacity = max(0.0, min(1.0, o)) }
            if let tx = update.translateX { record.paint.translateX = tx }
            if let ty = update.translateY { record.paint.translateY = ty }
            if let b = update.border {
                record.paint.border = b
                record.flexNode.style.border.set(.top, b.contains(.top) ? .point(1) : .point(0))
                record.flexNode.style.border.set(.right, b.contains(.right) ? .point(1) : .point(0))
                record.flexNode.style.border.set(.bottom, b.contains(.bottom) ? .point(1) : .point(0))
                record.flexNode.style.border.set(.left, b.contains(.left) ? .point(1) : .point(0))
            }
            if let sf = update.shouldFill { record.paint.shouldFill = sf }
            if let bg = update.backgroundColor { record.paint.backgroundColor = bg }
            if let bc = update.borderColor { record.paint.borderColor = bc }
            if let bs = update.borderStyle { record.paint.borderStyle = bs }
            if let f = update.focusable { record.paint.focusable = f }
            if let fbc = update.focusedBorderColor { record.paint.focusedBorderColor = fbc }
            if update.resetBorderCharacters { record.boxDetails.customBorderChars = nil }
        case .background(let handle, let color):
            records[handle]?.paint.backgroundColor = color
        }
    }

    private func applyStyle(
        to record: SceneNodeRecord,
        group: YogaStyleGroup,
        kind: Int32,
        edge: Int32,
        unit: Unit,
        value: Float,
        flags: YogaStyleFlags
    ) {
        let flexValue = YogaValue(unit: unit, value: value).flexValue
        let resolvedEdge = Edge(rawValue: edge) ?? .all
        switch group {
        case .enum:
            guard let enumKind = YogaEnumKind(rawValue: kind) else { return }
            let raw = Int32(value)
            switch enumKind {
            case .direction:
                if let d = Direction(rawValue: raw) { record.flexNode.style.direction = d }
            case .flexDirection:
                record.flexNode.style.flexDirection = FlexDirection.fromYogaRawValue(raw)
            case .justifyContent:
                if let j = Justify(rawValue: raw) { record.flexNode.style.justifyContent = j }
            case .alignContent:
                if let a = Align(rawValue: raw) { record.flexNode.style.alignContent = a }
            case .alignItems:
                if let a = Align(rawValue: raw) { record.flexNode.style.alignItems = a }
            case .alignSelf:
                if let a = Align(rawValue: raw) { record.flexNode.style.alignSelf = a }
            case .positionType:
                if let p = PositionType(rawValue: raw) { record.flexNode.style.positionType = p }
            case .flexWrap:
                if let w = Wrap(rawValue: raw) { record.flexNode.style.flexWrap = w }
            case .overflow:
                if let o = Overflow(rawValue: raw) { record.flexNode.style.overflow = o }
            case .display:
                if let d = Display(rawValue: raw) { record.flexNode.style.display = d }
            case .boxSizing:
                if let b = BoxSizing(rawValue: raw) { record.flexNode.style.boxSizing = b }
            case .layoutMode:
                break
            }
        case .float:
            guard let floatKind = YogaFloatKind(rawValue: kind) else { return }
            let optValue: Float? = value.isFinite ? value : nil
            switch floatKind {
            case .flex:
                record.flexShorthand = value
                record.flexNode.style.setFlex(optValue)
            case .flexGrow:
                record.flexNode.style.flexGrow = optValue ?? 0
            case .flexShrink:
                record.flexNode.style.flexShrink = optValue ?? 0
            case .aspectRatio:
                record.flexNode.style.aspectRatio = optValue
            }
        case .value:
            guard let valueKind = YogaValueKind(rawValue: kind) else { return }
            switch valueKind {
            case .width: record.flexNode.style.width = flexValue
            case .height: record.flexNode.style.height = flexValue
            case .minWidth: record.flexNode.style.minWidth = flexValue
            case .minHeight: record.flexNode.style.minHeight = flexValue
            case .maxWidth: record.flexNode.style.maxWidth = flexValue
            case .maxHeight: record.flexNode.style.maxHeight = flexValue
            case .flexBasis: record.flexNode.style.flexBasis = flexValue
            case .margin: record.flexNode.style.margin.set(resolvedEdge, flexValue)
            case .padding: record.flexNode.style.padding.set(resolvedEdge, flexValue)
            case .position: record.flexNode.style.position.set(resolvedEdge, flexValue)
            case .gap:
                let gutter = Gutter(rawValue: edge) ?? .all
                record.flexNode.style.gap.set(gutter, flexValue)
            }
        case .border:
            record.flexNode.style.border.set(resolvedEdge, value.isFinite ? .point(value) : .undefined)
        case .dimension:
            if kind == Dimension.width.rawValue {
                record.flexNode.style.width = flexValue
            } else {
                record.flexNode.style.height = flexValue
            }
            if flags.contains(.disableFlexShrink) {
                record.flexNode.style.flexShrink = 0
            }
        }
    }

    private func readStyle(
        from record: SceneNodeRecord,
        group: YogaStyleGroup,
        kind: Int32,
        edge: Int32
    ) -> YogaValue {
        let resolvedEdge = Edge(rawValue: edge) ?? .all
        switch group {
        case .enum:
            guard let enumKind = YogaEnumKind(rawValue: kind) else { return UNDEFINED_VALUE }
            let raw: Int32
            switch enumKind {
            case .direction: raw = record.flexNode.style.direction.rawValue
            case .flexDirection: raw = record.flexNode.style.flexDirection.yogaRawValue
            case .justifyContent: raw = record.flexNode.style.justifyContent.rawValue
            case .alignContent: raw = record.flexNode.style.alignContent.rawValue
            case .alignItems: raw = record.flexNode.style.alignItems.rawValue
            case .alignSelf: raw = record.flexNode.style.alignSelf.rawValue
            case .positionType: raw = record.flexNode.style.positionType.rawValue
            case .flexWrap: raw = record.flexNode.style.flexWrap.rawValue
            case .overflow: raw = record.flexNode.style.overflow.rawValue
            case .display: raw = record.flexNode.style.display.rawValue
            case .boxSizing: raw = record.flexNode.style.boxSizing.rawValue
            case .layoutMode: raw = LayoutMode.flex.rawValue
            }
            return YogaValue(unit: .undefined, value: Float(raw))
        case .float:
            guard let floatKind = YogaFloatKind(rawValue: kind) else { return UNDEFINED_VALUE }
            let val: Float
            switch floatKind {
            case .flex: val = record.flexShorthand
            case .flexGrow: val = record.flexNode.style.flexGrow
            case .flexShrink: val = record.flexNode.style.flexShrink
            case .aspectRatio: val = record.flexNode.style.aspectRatio ?? .nan
            }
            return YogaValue(unit: .undefined, value: val)
        case .value:
            guard let valueKind = YogaValueKind(rawValue: kind) else { return UNDEFINED_VALUE }
            let fv: FlexValue
            switch valueKind {
            case .width: fv = record.flexNode.style.width
            case .height: fv = record.flexNode.style.height
            case .minWidth: fv = record.flexNode.style.minWidth
            case .minHeight: fv = record.flexNode.style.minHeight
            case .maxWidth: fv = record.flexNode.style.maxWidth
            case .maxHeight: fv = record.flexNode.style.maxHeight
            case .flexBasis: fv = record.flexNode.style.flexBasis
            case .margin: fv = record.flexNode.style.margin.value(for: resolvedEdge)
            case .padding: fv = record.flexNode.style.padding.value(for: resolvedEdge)
            case .position: fv = record.flexNode.style.position.value(for: resolvedEdge)
            case .gap: fv = record.flexNode.style.gap.value(for: Gutter(rawValue: edge) ?? .all)
            }
            return YogaValue(flexValue: fv)
        case .border:
            return YogaValue(flexValue: record.flexNode.style.border.value(for: resolvedEdge))
        case .dimension:
            let fv = kind == Dimension.width.rawValue ? record.flexNode.style.width : record.flexNode.style.height
            return YogaValue(flexValue: fv)
        }
    }

    private func syncLayoutsRecursively(
        handle: SceneNodeHandle,
        parentScreenX: Int,
        parentScreenY: Int
    ) {
        guard let record = records[handle] else { return }
        let cl = record.flexNode.computedLayout
        let localX = Int(cl.left.rounded(.toNearestOrAwayFromZero))
        let localY = Int(cl.top.rounded(.toNearestOrAwayFromZero))
        let screenX = parentScreenX + localX + record.paint.translateX
        let screenY = parentScreenY + localY + record.paint.translateY

        record.layout = NativeSceneLayout(
            left: cl.left,
            top: cl.top,
            right: cl.right,
            bottom: cl.bottom,
            width: cl.width,
            height: cl.height,
            screenX: screenX,
            screenY: screenY
        )

        let padL = cl.padding.left + cl.border.left
        let padT = cl.padding.top + cl.border.top
        let padR = cl.padding.right + cl.border.right
        let padB = cl.padding.bottom + cl.border.bottom
        let innerW = max(0, cl.width - padL - padR)
        let innerH = max(0, cl.height - padT - padB)
        record.contentLayout = NativeSceneLayout(
            left: padL,
            top: padT,
            right: padL + innerW,
            bottom: padT + innerH,
            width: innerW,
            height: innerH,
            screenX: screenX + Int(padL.rounded(.toNearestOrAwayFromZero)),
            screenY: screenY + Int(padT.rounded(.toNearestOrAwayFromZero))
        )

        let scrollOffX = record.scrollOptions != nil ? Int(record.scrollState.offsetX.rounded(.toNearestOrAwayFromZero)) : 0
        let scrollOffY = record.scrollOptions != nil ? Int(record.scrollState.offsetY.rounded(.toNearestOrAwayFromZero)) : 0

        for child in record.children {
            syncLayoutsRecursively(
                handle: child,
                parentScreenX: screenX - scrollOffX,
                parentScreenY: screenY - scrollOffY
            )
        }

        if record.scrollOptions != nil {
            recomputeScrollState(for: record)
        }
    }

    private func recomputeScrollState(for record: SceneNodeRecord) {
        let viewW = Double(record.contentLayout.width)
        let viewH = Double(record.contentLayout.height)
        var maxChildRight: Double = 0
        var maxChildBottom: Double = 0
        for childHandle in record.children {
            if let child = records[childHandle] {
                let r = Double(child.layout.left + child.layout.width)
                let b = Double(child.layout.top + child.layout.height)
                if r > maxChildRight { maxChildRight = r }
                if b > maxChildBottom { maxChildBottom = b }
            }
        }
        let contentW = max(viewW, maxChildRight)
        let contentH = max(viewH, maxChildBottom)
        let allowX = record.scrollOptions?.scrollX ?? false
        let allowY = record.scrollOptions?.scrollY ?? true

        record.scrollState.viewport = NativeSceneRect(
            x: Double(record.contentLayout.screenX),
            y: Double(record.contentLayout.screenY),
            width: viewW,
            height: viewH
        )
        record.scrollState.content = NativeSceneRect(x: 0, y: 0, width: contentW, height: contentH)
        record.scrollState.maxX = allowX ? max(0, contentW - viewW) : 0
        record.scrollState.maxY = allowY ? max(0, contentH - viewH) : 0
        record.scrollState.offsetX = max(0, min(record.scrollState.maxX, record.scrollState.offsetX))
        record.scrollState.offsetY = max(0, min(record.scrollState.maxY, record.scrollState.offsetY))
        updateScrollBarThumbs(for: record)
    }

    private func updateScrollBarThumbs(for record: SceneNodeRecord) {
        let opts = record.scrollOptions ?? NativeSceneScrollOptions()
        let hOpt = opts.bars.count > 0 ? opts.bars[0] : NativeSceneScrollBarOptions()
        let vOpt = opts.bars.count > 1 ? opts.bars[1] : NativeSceneScrollBarOptions()

        let hVisible = hOpt.policy == .always || (hOpt.policy == .auto && record.scrollState.maxX > 0)
        let vVisible = vOpt.policy == .always || (vOpt.policy == .auto && record.scrollState.maxY > 0)

        let hThumb = computeSliderThumb(
            orientation: .horizontal,
            min: 0,
            max: record.scrollState.maxX,
            value: record.scrollState.offsetX,
            viewPortSize: max(1, record.scrollState.viewport.width),
            width: Int(record.scrollState.viewport.width),
            height: hOpt.thickness
        )
        let vThumb = computeSliderThumb(
            orientation: .vertical,
            min: 0,
            max: record.scrollState.maxY,
            value: record.scrollState.offsetY,
            viewPortSize: max(1, record.scrollState.viewport.height),
            width: vOpt.thickness,
            height: Int(record.scrollState.viewport.height)
        )

        record.scrollState.horizontalBar = NativeSceneScrollBarState(
            visible: hVisible,
            track: NativeSceneRect(
                x: record.scrollState.viewport.x,
                y: record.scrollState.viewport.y + record.scrollState.viewport.height - Double(hOpt.thickness),
                width: record.scrollState.viewport.width,
                height: Double(hOpt.thickness)
            ),
            thumbStart: hThumb.start,
            thumbSize: hThumb.size
        )
        record.scrollState.verticalBar = NativeSceneScrollBarState(
            visible: vVisible,
            track: NativeSceneRect(
                x: record.scrollState.viewport.x + record.scrollState.viewport.width - Double(vOpt.thickness),
                y: record.scrollState.viewport.y,
                width: Double(vOpt.thickness),
                height: record.scrollState.viewport.height
            ),
            thumbStart: vThumb.start,
            thumbSize: vThumb.size
        )
    }

    private func paintSubtree(
        handle: SceneNodeHandle,
        into buffer: OptimizedBuffer,
        useMouse: Bool,
        excludedHitNum: UInt32
    ) {
        guard let record = records[handle] else { return }
        if record.flexNode.style.display == .none { return }
        if let renderable = record.renderable, !renderable.visible || renderable.isDestroyed { return }
        if record.paint.opacity <= 0.0 { return }

        let x = record.layout.screenX
        let y = record.layout.screenY
        let w = max(0, Int(record.layout.width.rounded(.toNearestOrAwayFromZero)))
        let h = max(0, Int(record.layout.height.rounded(.toNearestOrAwayFromZero)))

        let pushedOpacity = record.paint.opacity < 1.0
        if pushedOpacity {
            buffer.pushOpacity(record.paint.opacity)
        }
        defer {
            if pushedOpacity { buffer.popOpacity() }
        }

        let shouldClip = record.flexNode.style.overflow == .hidden || record.flexNode.style.overflow == .scroll
        if shouldClip {
            buffer.pushScissorRect(x: x, y: y, width: w, height: h)
        }
        defer {
            if shouldClip { buffer.popScissorRect() }
        }

        record.paintedInLastFrame = true
        paintRecordBody(record, into: buffer, screenX: x, screenY: y, width: w, height: h)

        if useMouse && w > 0 && h > 0 && record.num != excludedHitNum {
            let clipped = buffer.clipRectToScissor(x: x, y: y, width: w, height: h)
                ?? ClipRect(x: x, y: y, width: w, height: h)
            if clipped.width > 0 && clipped.height > 0 {
                buffer.fillHitRect(
                    x: clipped.x,
                    y: clipped.y,
                    width: clipped.width,
                    height: clipped.height,
                    hitId: record.num
                )
                recordHitRect(clipped, num: record.num)
            }
        }

        // Paint children stably ordered by zIndex.
        let orderedChildren = record.children.enumerated().sorted { lhs, rhs in
            let lz = records[lhs.element]?.paint.zIndex ?? 0
            let rz = records[rhs.element]?.paint.zIndex ?? 0
            if lz != rz { return lz < rz }
            return lhs.offset < rhs.offset
        }.map(\.element)

        for child in orderedChildren {
            paintSubtree(
                handle: child,
                into: buffer,
                useMouse: useMouse,
                excludedHitNum: excludedHitNum
            )
        }
    }

    private func paintRecordBody(
        _ record: SceneNodeRecord,
        into buffer: OptimizedBuffer,
        screenX x: Int,
        screenY y: Int,
        width w: Int,
        height h: Int
    ) {
        guard w > 0 && h > 0 else { return }

        // 1. Box border or background fill.
        if !record.paint.border.isEmpty {
            let borderColor = record.focused ? record.paint.focusedBorderColor : record.paint.borderColor
            buffer.drawBox(BoxDrawOptions(
                x: x,
                y: y,
                width: w,
                height: h,
                borderStyle: record.paint.borderStyle,
                customBorderChars: record.boxDetails.customBorderChars,
                borderSides: record.paint.border.sidesConfig,
                borderColor: borderColor,
                backgroundColor: record.paint.backgroundColor,
                titleColor: record.boxDetails.titleColor,
                shouldFill: record.paint.shouldFill,
                title: record.boxDetails.title,
                titleAlignment: record.boxDetails.titleAlignment,
                bottomTitle: record.boxDetails.bottomTitle,
                bottomTitleAlignment: record.boxDetails.bottomTitleAlignment
            ))
        } else if record.paint.shouldFill || (record.paint.backgroundColor.toInts().3 > 0) {
            buffer.fillRect(x: x, y: y, width: w, height: h, bg: record.paint.backgroundColor)
        }

        // 2. Surface framebuffer blit.
        if let surface = record.surface {
            buffer.drawFrameBuffer(destX: x, destY: y, frameBuffer: surface)
        }

        // 3. Slider body.
        if let slider = record.sliderOptions {
            paintSliderTrack(
                buffer: buffer,
                x: x,
                y: y,
                width: w,
                height: h,
                orientation: slider.orientation,
                min: slider.min,
                max: slider.max,
                value: slider.value,
                viewPortSize: slider.viewPortSize,
                foreground: slider.foregroundColor,
                background: slider.backgroundColor
            )
        }

        // 4. Arrow glyph body.
        if let arrow = record.arrowOptions {
            let glyph: String
            if let custom = arrow.text {
                glyph = custom
            } else {
                switch arrow.direction {
                case .up: glyph = "▲"
                case .down: glyph = "▼"
                case .left: glyph = "◀"
                case .right: glyph = "▶"
                }
            }
            buffer.drawText(
                glyph,
                x: x,
                y: y,
                fg: arrow.foregroundColor,
                bg: arrow.backgroundColor,
                attributes: arrow.attributes
            )
        }

        // 5. Text / StyledText body.
        if let styled = record.styledText {
            buffer.drawStyledText(
                styled,
                x: x,
                y: y,
                defaultFg: record.textOptions.fg,
                defaultBg: record.textOptions.bg,
                maxWidth: w
            )
            let rawText = record.textContent ?? ""
            record.renderedTextLines = splitLines(rawText)
            record.renderedTextLineByteStarts = computeLineByteStarts(record.renderedTextLines)
        } else if let text = record.textContent {
            let lines = splitLines(text)
            record.renderedTextLines = lines
            record.renderedTextLineByteStarts = computeLineByteStarts(lines)
            let startRow = max(0, record.textOptions.scrollY)
            for rowOffset in 0..<h {
                let lineIdx = startRow + rowOffset
                if lineIdx >= lines.count { break }
                let line = lines[lineIdx]
                let lineWidth = Int(calculateTextWidth(line, widthMethod: .unicode))
                let alignOffset: Int
                switch record.textOptions.textAlign {
                case .left: alignOffset = 0
                case .center: alignOffset = max(0, (w - lineWidth) / 2)
                case .right: alignOffset = max(0, w - lineWidth)
                }
                buffer.drawTextFit(
                    line,
                    x: x + alignOffset,
                    y: y + rowOffset,
                    maxWidth: max(0, w - alignOffset),
                    fg: record.textOptions.fg,
                    bg: record.textOptions.bg,
                    attributes: record.textOptions.attributes,
                    ellipsis: record.textOptions.truncate
                )
            }
        }
    }

    private func recordHitRect(_ rect: ClipRect, num: UInt32) {
        paintedHitStack.append((rect: rect, num: num))
        let x0 = max(0, rect.x)
        let y0 = max(0, rect.y)
        let x1 = min(hitGridWidth, rect.x + rect.width)
        let y1 = min(hitGridHeight, rect.y + rect.height)
        guard x0 < x1 && y0 < y1 else { return }
        for row in y0..<y1 {
            let base = row * hitGridWidth
            for col in x0..<x1 {
                hitGrid[base + col] = num
            }
        }
    }

    private func splitLines(_ text: String) -> [String] {
        var result: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.value == 0x0A {
                result.append(String(current))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(scalar)
            }
        }
        result.append(String(current))
        return result
    }

    private func computeLineByteStarts(_ lines: [String]) -> [Int] {
        var starts: [Int] = []
        starts.reserveCapacity(lines.count)
        var offset = 0
        for line in lines {
            starts.append(offset)
            offset += line.utf8.count + 1
        }
        return starts
    }
}
