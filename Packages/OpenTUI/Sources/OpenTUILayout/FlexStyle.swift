// Pure-Swift Flexbox layout style primitives (Yoga-compatible).
// Zero OS / Foundation imports (Pure Tier).

// MARK: - FlexValue

// parity: core/src/yoga.ts#Value [status=adapted hash=246e75e8d4b7]
public enum FlexValue: Equatable, Hashable, Sendable, Codable,
    ExpressibleByFloatLiteral,
    ExpressibleByIntegerLiteral
{
    case undefined
    case auto
    case point(Float)
    case percent(Float)

    public init(floatLiteral value: Double) {
        self = .point(Float(value))
    }

    public init(integerLiteral value: Int) {
        self = .point(Float(value))
    }

    public var unit: Unit {
        switch self {
        case .undefined: return .undefined
        case .auto: return .auto
        case .point: return .point
        case .percent: return .percent
        }
    }

    /// Raw numeric value matching Yoga's `Value.value` (`Float.nan` for `.undefined`/`.auto`).
    public var rawValue: Float {
        switch self {
        case .undefined, .auto: return .nan
        case .point(let v), .percent(let v): return v
        }
    }

    public var isUndefined: Bool {
        if case .undefined = self { return true }
        return false
    }

    public var isAuto: Bool {
        if case .auto = self { return true }
        return false
    }

    public var isDefined: Bool {
        switch self {
        case .point(let v), .percent(let v):
            return v.isFinite
        case .undefined, .auto:
            return false
        }
    }

    /// Resolves `.point` directly or `.percent` against `ownerSize`.
    /// Returns `nil` for `.undefined`, `.auto`, non-finite values, or `.percent` when `ownerSize` is `nil`/non-finite.
    public func resolve(against ownerSize: Float?) -> Float? {
        switch self {
        case .point(let value):
            return value.isFinite ? value : nil
        case .percent(let percent):
            guard percent.isFinite, let ownerSize, ownerSize.isFinite else { return nil }
            return ownerSize * percent / 100.0
        case .undefined, .auto:
            return nil
        }
    }

    /// Parses a string such as `"auto"`, `"50%"`, or `"12"` into a `FlexValue`.
    public static func parse(_ string: String) -> FlexValue {
        let trimmed = trimASCIIWhitespace(string)
        if trimmed.isEmpty { return .undefined }
        if trimmed.lowercased() == "auto" { return .auto }
        if trimmed.hasSuffix("%") {
            let numberPart = trimmed.dropLast()
            if let value = Float(numberPart), value.isFinite {
                return .percent(value)
            }
            return .undefined
        }
        if let value = Float(trimmed), value.isFinite {
            return .point(value)
        }
        return .undefined
    }

    /// Parses a `LayoutOptionValue` (number, `"auto"`, `"50%"`, or undefined/null) into a `FlexValue`.
    public static func parse(_ input: LayoutOptionValue) -> FlexValue {
        switch input {
        case .number(let n):
            return n.isFinite ? .point(Float(n)) : .undefined
        case .string(let s):
            return parse(s)
        case .null, .undefined:
            return .undefined
        }
    }
}

private func trimASCIIWhitespace(_ s: String) -> Substring {
    var start = s.startIndex
    var end = s.endIndex
    while start < end && isASCIIWhitespace(s[start]) {
        start = s.index(after: start)
    }
    while end > start {
        let prev = s.index(before: end)
        if !isASCIIWhitespace(s[prev]) { break }
        end = prev
    }
    return s[start..<end]
}

private func isASCIIWhitespace(_ ch: Character) -> Bool {
    ch == " " || ch == "\t" || ch == "\n" || ch == "\r"
}

// MARK: - FlexEdgeValues

/// Per-edge values supporting Yoga's full `Edge` specificity hierarchy:
/// - Horizontal physical edges: `start`/`end` -> `left`/`right` -> `horizontal` -> `all`
/// - Vertical physical edges: `top`/`bottom` -> `vertical` -> `all`
public struct FlexEdgeValues: Equatable, Hashable, Sendable, Codable {
    public var top: FlexValue
    public var right: FlexValue
    public var bottom: FlexValue
    public var left: FlexValue
    public var start: FlexValue
    public var end: FlexValue
    public var horizontal: FlexValue
    public var vertical: FlexValue
    public var all: FlexValue

    public static let undefined = FlexEdgeValues()

    public init(
        top: FlexValue = .undefined,
        right: FlexValue = .undefined,
        bottom: FlexValue = .undefined,
        left: FlexValue = .undefined,
        start: FlexValue = .undefined,
        end: FlexValue = .undefined,
        horizontal: FlexValue = .undefined,
        vertical: FlexValue = .undefined,
        all: FlexValue = .undefined
    ) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
        self.start = start
        self.end = end
        self.horizontal = horizontal
        self.vertical = vertical
        self.all = all
    }

    public static func all(_ value: FlexValue) -> FlexEdgeValues {
        FlexEdgeValues(all: value)
    }

    public static func symmetric(
        horizontal: FlexValue = .undefined,
        vertical: FlexValue = .undefined
    ) -> FlexEdgeValues {
        FlexEdgeValues(horizontal: horizontal, vertical: vertical)
    }

    public mutating func set(_ edge: Edge, _ value: FlexValue) {
        switch edge {
        case .left: left = value
        case .top: top = value
        case .right: right = value
        case .bottom: bottom = value
        case .start: start = value
        case .end: end = value
        case .horizontal: horizontal = value
        case .vertical: vertical = value
        case .all: all = value
        }
    }

    public func value(for edge: Edge) -> FlexValue {
        switch edge {
        case .left: return left
        case .top: return top
        case .right: return right
        case .bottom: return bottom
        case .start: return start
        case .end: return end
        case .horizontal: return horizontal
        case .vertical: return vertical
        case .all: return all
        }
    }

    public subscript(edge: Edge) -> FlexValue {
        get { value(for: edge) }
        set { set(edge, newValue) }
    }

    /// Resolves an edge according to Yoga precedence and layout direction (`.ltr` / `.rtl`).
    public func resolve(_ edge: Edge, direction: Direction = .ltr) -> FlexValue {
        let isRTL = direction == .rtl
        switch edge {
        case .left:
            let logical = isRTL ? end : start
            if !logical.isUndefined { return logical }
            if !left.isUndefined { return left }
            if !horizontal.isUndefined { return horizontal }
            return all
        case .right:
            let logical = isRTL ? start : end
            if !logical.isUndefined { return logical }
            if !right.isUndefined { return right }
            if !horizontal.isUndefined { return horizontal }
            return all
        case .top:
            if !top.isUndefined { return top }
            if !vertical.isUndefined { return vertical }
            return all
        case .bottom:
            if !bottom.isUndefined { return bottom }
            if !vertical.isUndefined { return vertical }
            return all
        case .start:
            if !start.isUndefined { return start }
            let physical = isRTL ? right : left
            if !physical.isUndefined { return physical }
            if !horizontal.isUndefined { return horizontal }
            return all
        case .end:
            if !end.isUndefined { return end }
            let physical = isRTL ? left : right
            if !physical.isUndefined { return physical }
            if !horizontal.isUndefined { return horizontal }
            return all
        case .horizontal:
            if !horizontal.isUndefined { return horizontal }
            return all
        case .vertical:
            if !vertical.isUndefined { return vertical }
            return all
        case .all:
            return all
        }
    }

    /// Resolves an edge to points against `ownerSize`, returning `defaultValue` when undefined/auto/unresolvable.
    public func resolvePoints(
        _ edge: Edge,
        ownerSize: Float?,
        direction: Direction = .ltr,
        default defaultValue: Float = 0
    ) -> Float {
        resolve(edge, direction: direction).resolve(against: ownerSize) ?? defaultValue
    }
}

// MARK: - FlexGapValues

/// Container gutter values for row, column, and all-axis gaps.
public struct FlexGapValues: Equatable, Hashable, Sendable, Codable {
    public var row: FlexValue
    public var column: FlexValue
    public var all: FlexValue

    public static let zero = FlexGapValues()

    public init(
        row: FlexValue = .undefined,
        column: FlexValue = .undefined,
        all: FlexValue = .undefined
    ) {
        self.row = row
        self.column = column
        self.all = all
    }

    public static func all(_ value: FlexValue) -> FlexGapValues {
        FlexGapValues(all: value)
    }

    public mutating func set(_ gutter: Gutter, _ value: FlexValue) {
        switch gutter {
        case .row: row = value
        case .column: column = value
        case .all: all = value
        }
    }

    public func value(for gutter: Gutter) -> FlexValue {
        switch gutter {
        case .row: return row
        case .column: return column
        case .all: return all
        }
    }

    public subscript(gutter: Gutter) -> FlexValue {
        get { value(for: gutter) }
        set { set(gutter, newValue) }
    }

    public func resolve(_ gutter: Gutter) -> FlexValue {
        switch gutter {
        case .row:
            return row.isUndefined ? all : row
        case .column:
            return column.isUndefined ? all : column
        case .all:
            return all
        }
    }

    public func resolvePoints(_ gutter: Gutter, ownerSize: Float?) -> Float {
        let value = resolve(gutter).resolve(against: ownerSize) ?? 0
        return value > 0 ? value : 0
    }
}

// MARK: - FlexStyle

/// Full Yoga-compatible Flexbox style descriptor for a `FlexNode`.
/// Default values match Yoga's OpenTUI configuration (`useWebDefaults = false`).
public struct FlexStyle: Equatable, Hashable, Sendable, Codable {
    public var direction: Direction
    public var flexDirection: FlexDirection
    public var flexWrap: Wrap
    public var justifyContent: Justify
    public var alignItems: Align
    public var alignSelf: Align
    public var alignContent: Align
    public var flexGrow: Float
    public var flexShrink: Float
    public var flexBasis: FlexValue
    public var width: FlexValue
    public var height: FlexValue
    public var minWidth: FlexValue
    public var minHeight: FlexValue
    public var maxWidth: FlexValue
    public var maxHeight: FlexValue
    public var margin: FlexEdgeValues
    public var padding: FlexEdgeValues
    public var border: FlexEdgeValues
    public var position: FlexEdgeValues
    public var positionType: PositionType
    public var gap: FlexGapValues
    public var display: Display
    public var overflow: Overflow
    public var boxSizing: BoxSizing
    public var aspectRatio: Float?

    public init(
        direction: Direction = .inherit,
        flexDirection: FlexDirection = .column,
        flexWrap: Wrap = .noWrap,
        justifyContent: Justify = .flexStart,
        alignItems: Align = .stretch,
        alignSelf: Align = .auto,
        alignContent: Align = .flexStart,
        flexGrow: Float = 0,
        flexShrink: Float = 0,
        flexBasis: FlexValue = .auto,
        width: FlexValue = .auto,
        height: FlexValue = .auto,
        minWidth: FlexValue = .undefined,
        minHeight: FlexValue = .undefined,
        maxWidth: FlexValue = .undefined,
        maxHeight: FlexValue = .undefined,
        margin: FlexEdgeValues = FlexEdgeValues(),
        padding: FlexEdgeValues = FlexEdgeValues(),
        border: FlexEdgeValues = FlexEdgeValues(),
        position: FlexEdgeValues = FlexEdgeValues(),
        positionType: PositionType = .relative,
        gap: FlexGapValues = FlexGapValues(),
        display: Display = .flex,
        overflow: Overflow = .visible,
        boxSizing: BoxSizing = .borderBox,
        aspectRatio: Float? = nil
    ) {
        self.direction = direction
        self.flexDirection = flexDirection
        self.flexWrap = flexWrap
        self.justifyContent = justifyContent
        self.alignItems = alignItems
        self.alignSelf = alignSelf
        self.alignContent = alignContent
        self.flexGrow = flexGrow
        self.flexShrink = flexShrink
        self.flexBasis = flexBasis
        self.width = width
        self.height = height
        self.minWidth = minWidth
        self.minHeight = minHeight
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.margin = margin
        self.padding = padding
        self.border = border
        self.position = position
        self.positionType = positionType
        self.gap = gap
        self.display = display
        self.overflow = overflow
        self.boxSizing = boxSizing
        self.aspectRatio = aspectRatio
    }

    /// Applies Yoga's `flex` shorthand (`> 0` sets grow + shrink 1 + basis 0; `0` disables grow/shrink; `< 0` sets shrink).
    public mutating func setFlex(_ value: Float?) {
        guard let value, value.isFinite else {
            flexGrow = 0
            flexShrink = 0
            flexBasis = .auto
            return
        }
        if value > 0 {
            flexGrow = value
            flexShrink = 1
            flexBasis = .point(0)
        } else if value == 0 {
            flexGrow = 0
            flexShrink = 0
        } else {
            flexGrow = 0
            flexShrink = -value
        }
    }
}
