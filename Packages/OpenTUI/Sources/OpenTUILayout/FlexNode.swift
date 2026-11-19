// Pure-Swift Flexbox layout node tree & computed layout results.
// Zero OS / Foundation imports (Pure Tier).

// MARK: - FlexSize

// parity: core/src/yoga.ts#Size [status=adapted hash=1af91f71a4dc]
public struct FlexSize: Equatable, Hashable, Sendable, Codable {
    public var width: Float
    public var height: Float

    public static let zero = FlexSize(width: 0, height: 0)

    public init(width: Float, height: Float) {
        self.width = width
        self.height = height
    }
}

// MARK: - FlexInsets

/// Resolved physical edge insets (in layout units) for computed margin, padding, or border.
public struct FlexInsets: Equatable, Hashable, Sendable, Codable {
    public var top: Float
    public var right: Float
    public var bottom: Float
    public var left: Float

    public static let zero = FlexInsets(top: 0, right: 0, bottom: 0, left: 0)

    public init(top: Float = 0, right: Float = 0, bottom: Float = 0, left: Float = 0) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
    }

    public var horizontal: Float { left + right }
    public var vertical: Float { top + bottom }

    public func value(for edge: Edge, direction: Direction = .ltr) -> Float {
        let isRTL = direction == .rtl
        switch edge {
        case .left: return left
        case .right: return right
        case .top: return top
        case .bottom: return bottom
        case .start: return isRTL ? right : left
        case .end: return isRTL ? left : right
        case .horizontal: return left
        case .vertical: return top
        case .all: return left
        }
    }
}

// MARK: - FlexComputedLayout

// parity: core/src/yoga.ts#Layout [status=adapted hash=1364a4179eeb]
public struct FlexComputedLayout: Equatable, Hashable, Sendable, Codable {
    public var x: Float
    public var y: Float
    public var width: Float
    public var height: Float
    public var margin: FlexInsets
    public var padding: FlexInsets
    public var border: FlexInsets
    public var direction: Direction

    public static let zero = FlexComputedLayout()

    public init(
        x: Float = 0,
        y: Float = 0,
        width: Float = 0,
        height: Float = 0,
        margin: FlexInsets = .zero,
        padding: FlexInsets = .zero,
        border: FlexInsets = .zero,
        direction: Direction = .ltr
    ) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.margin = margin
        self.padding = padding
        self.border = border
        self.direction = direction
    }

    public var left: Float { x }
    public var top: Float { y }
    public var right: Float { x + width }
    public var bottom: Float { y + height }

    /// Integer terminal cell grid rectangle for rendering.
    public var rect: LayoutRect {
        let rx = Int(x.rounded(.toNearestOrAwayFromZero))
        let ry = Int(y.rounded(.toNearestOrAwayFromZero))
        let rw = max(0, Int(width.rounded(.toNearestOrAwayFromZero)))
        let rh = max(0, Int(height.rounded(.toNearestOrAwayFromZero)))
        return LayoutRect(x: rx, y: ry, width: rw, height: rh)
    }
}

// MARK: - Callbacks

// parity: core/src/yoga.ts#MeasureFunction [status=adapted hash=3dab18ed23b6]
public typealias FlexMeasureFunc = @Sendable (Float, MeasureMode, Float, MeasureMode) -> FlexSize

// parity: core/src/yoga.ts#DirtiedFunction [status=adapted hash=31cc50d9309d]
public typealias FlexDirtiedFunc = @Sendable (FlexNode) -> Void

// MARK: - FlexNode

/// Pure-Swift Yoga-compatible Flexbox layout tree node.
/// Like upstream `Yoga.Node`, mutations and `calculateLayout` are single-owner operations.
// parity: core/src/yoga.ts#Node [status=adapted hash=6e196f262b13]
public final class FlexNode: @unchecked Sendable {
    public var style: FlexStyle {
        didSet {
            if style != oldValue {
                markDirty()
            }
        }
    }

    // parity: core/src/yoga.ts#Node.getParent [status=adapted hash=e41e44ded3f6]
    public weak internal(set) var parent: FlexNode?

    public private(set) var children: [FlexNode] = []

    public var measureFunc: FlexMeasureFunc? {
        didSet {
            markDirty()
        }
    }

    public var dirtiedFunc: FlexDirtiedFunc?

    /// Pixel/cell grid scale factor used for rounding when this node is the layout root.
    /// Defaults to `1.0` (integer terminal cell grid). Set to `0` to disable rounding.
    public var pointScaleFactor: Float = 1.0 {
        didSet {
            if pointScaleFactor != oldValue {
                markDirty()
            }
        }
    }

    // parity: core/src/yoga.ts#Node.isDirty [status=adapted hash=e0d6a18bfd3c]
    public internal(set) var isDirty: Bool = true

    // parity: core/src/yoga.ts#Node.hasNewLayout [status=adapted hash=a4359bfb1f6a]
    public internal(set) var hasNewLayout: Bool = false

    // parity: core/src/yoga.ts#Node.getComputedLayout [status=adapted hash=8f9900c67a7a]
    public internal(set) var computedLayout: FlexComputedLayout = .zero

    public init(style: FlexStyle = FlexStyle(), measureFunc: FlexMeasureFunc? = nil) {
        self.style = style
        self.measureFunc = measureFunc
    }

    // MARK: Tree Management

    // parity: core/src/yoga.ts#Node.getChildCount [status=adapted hash=5dc866ef1e92]
    public var childCount: Int {
        children.count
    }

    // parity: core/src/yoga.ts#Node.getChild [status=adapted hash=fb6391eaadb8]
    public func getChild(at index: Int) -> FlexNode? {
        guard index >= 0 && index < children.count else { return nil }
        return children[index]
    }

    // parity: core/src/yoga.ts#Node.insertChild [status=adapted hash=4a458ea64f6c]
    public func insertChild(_ child: FlexNode, at index: Int) {
        guard child !== self else { return }
        // Guard against ancestor cycles.
        var ancestor: FlexNode? = parent
        while let current = ancestor {
            if current === child { return }
            ancestor = current.parent
        }

        if let oldParent = child.parent {
            oldParent.removeChild(child)
        }

        let clampedIndex = max(0, min(index, children.count))
        children.insert(child, at: clampedIndex)
        child.parent = self
        markDirty()
    }

    public func appendChild(_ child: FlexNode) {
        insertChild(child, at: children.count)
    }

    // parity: core/src/yoga.ts#Node.removeChild [status=adapted hash=d089cf5e0370]
    public func removeChild(_ child: FlexNode) {
        guard let idx = children.firstIndex(where: { $0 === child }) else { return }
        children.remove(at: idx)
        child.parent = nil
        markDirty()
    }

    // parity: core/src/yoga.ts#Node.removeAllChildren [status=adapted hash=e55858365091]
    public func removeAllChildren() {
        guard !children.isEmpty else { return }
        for child in children {
            child.parent = nil
        }
        children.removeAll()
        markDirty()
    }

    // MARK: Dirty & Lifecycle

    // parity: core/src/yoga.ts#Node.markDirty [status=adapted hash=38a0dc958669]
    public func markDirty() {
        if !isDirty {
            isDirty = true
            dirtiedFunc?(self)
            parent?.markDirty()
        } else {
            // Ensure ancestors are dirty even if a subtree was newly created dirty and attached.
            if let parent, !parent.isDirty {
                parent.markDirty()
            }
        }
    }

    // parity: core/src/yoga.ts#Node.markLayoutSeen [status=adapted hash=de9e311c54a3]
    public func markLayoutSeen() {
        hasNewLayout = false
    }

    // parity: core/src/yoga.ts#Node.reset [status=adapted hash=793a6da265c9]
    public func reset() {
        removeAllChildren()
        parent = nil
        style = FlexStyle()
        measureFunc = nil
        dirtiedFunc = nil
        computedLayout = .zero
        hasNewLayout = false
        isDirty = true
    }

    // parity: core/src/yoga.ts#Node.copyStyle [status=adapted hash=9f558b17b22c]
    public func copyStyle(from source: FlexNode) {
        style = source.style
    }

    // MARK: Measure Func Helpers

    // parity: core/src/yoga.ts#Node.setMeasureFunc [status=adapted hash=c4427b273f9c]
    public func setMeasureFunc(_ measureFunc: FlexMeasureFunc?) {
        self.measureFunc = measureFunc
    }

    // parity: core/src/yoga.ts#Node.unsetMeasureFunc [status=adapted hash=aad5c70d1caf]
    public func unsetMeasureFunc() {
        self.measureFunc = nil
    }

    // parity: core/src/yoga.ts#Node.hasMeasureFunc [status=adapted hash=b84ad789f8a4]
    public var hasMeasureFunc: Bool {
        measureFunc != nil
    }

    // MARK: Layout Computation

    // parity: core/src/yoga.ts#Node.calculateLayout [status=adapted hash=477b29065337]
    public func calculateLayout(
        availableWidth: Float? = nil,
        availableHeight: Float? = nil,
        direction: Direction = .ltr
    ) {
        let normalizedWidth: Float? = availableWidth.flatMap { $0.isFinite ? $0 : nil }
        let normalizedHeight: Float? = availableHeight.flatMap { $0.isFinite ? $0 : nil }
        FlexSolver.calculateLayout(
            root: self,
            availableWidth: normalizedWidth,
            availableHeight: normalizedHeight,
            direction: direction
        )
    }

    // MARK: Computed Layout Accessors

    // parity: core/src/yoga.ts#Node.getComputedLeft [status=adapted hash=edea270930c5]
    public var computedLeft: Float { computedLayout.left }

    // parity: core/src/yoga.ts#Node.getComputedTop [status=adapted hash=55e0e7fba766]
    public var computedTop: Float { computedLayout.top }

    // parity: core/src/yoga.ts#Node.getComputedRight [status=adapted hash=7b30c9624726]
    public var computedRight: Float { computedLayout.right }

    // parity: core/src/yoga.ts#Node.getComputedBottom [status=adapted hash=eea6bc457777]
    public var computedBottom: Float { computedLayout.bottom }

    // parity: core/src/yoga.ts#Node.getComputedWidth [status=adapted hash=4c3ab5b4f538]
    public var computedWidth: Float { computedLayout.width }

    // parity: core/src/yoga.ts#Node.getComputedHeight [status=adapted hash=3c3471035bac]
    public var computedHeight: Float { computedLayout.height }

    // parity: core/src/yoga.ts#Node.getComputedMargin [status=adapted hash=ac714699e8c2]
    public func computedMargin(_ edge: Edge) -> Float {
        computedLayout.margin.value(for: edge, direction: computedLayout.direction)
    }

    // parity: core/src/yoga.ts#Node.getComputedPadding [status=adapted hash=05fe4e8729b5]
    public func computedPadding(_ edge: Edge) -> Float {
        computedLayout.padding.value(for: edge, direction: computedLayout.direction)
    }

    // parity: core/src/yoga.ts#Node.getComputedBorder [status=adapted hash=0ecd21b96262]
    public func computedBorder(_ edge: Edge) -> Float {
        computedLayout.border.value(for: edge, direction: computedLayout.direction)
    }
}
