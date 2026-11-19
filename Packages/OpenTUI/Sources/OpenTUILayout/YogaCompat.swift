// Pure-Swift Yoga compatibility layer (`yoga.ts` & `yoga.internal.ts`) wrapping
// `FlexNode`, `FlexStyle`, `FlexSolver`, and `YogaOptions`.
// Zero OS / Foundation imports (Pure Tier).

import OpenTUICore

// MARK: - Yoga Enum Aliases & Flat Constants

// parity: core/src/yoga.ts#FlexDirection [status=adapted hash=fd8dd51e9724]
public typealias YogaFlexDirection = FlexDirection

public typealias YogaAlign = Align
public typealias YogaBoxSizing = BoxSizing
public typealias YogaDimension = Dimension
public typealias YogaDirection = Direction
public typealias YogaDisplay = Display
public typealias YogaEdge = Edge
public typealias YogaErrata = Errata
public typealias YogaExperimentalFeature = ExperimentalFeature
public typealias YogaGutter = Gutter
public typealias YogaJustify = Justify
public typealias YogaLogLevel = LogLevel
public typealias YogaMeasureMode = MeasureMode
public typealias YogaNodeType = NodeType
public typealias YogaOverflow = Overflow
public typealias YogaPositionType = PositionType
public typealias YogaUnit = Unit
public typealias YogaWrap = Wrap

extension FlexDirection {
    /// Constructs a `FlexDirection` from its native Yoga ABI raw integer (`0...3`).
    public static func fromYogaRawValue(_ rawValue: Int32) -> FlexDirection {
        switch rawValue {
        case 0: return .column
        case 1: return .columnReverse
        case 2: return .row
        case 3: return .rowReverse
        default: return .column
        }
    }
}

// parity: core/src/yoga.ts#ALIGN_AUTO [status=implemented hash=6d833ffa5a54]
public let ALIGN_AUTO: Align = .auto
// parity: core/src/yoga.ts#ALIGN_FLEX_START [status=implemented hash=2f797fd27458]
public let ALIGN_FLEX_START: Align = .flexStart
// parity: core/src/yoga.ts#ALIGN_CENTER [status=implemented hash=1394d95575c5]
public let ALIGN_CENTER: Align = .center
// parity: core/src/yoga.ts#ALIGN_FLEX_END [status=implemented hash=6752d400a43a]
public let ALIGN_FLEX_END: Align = .flexEnd
// parity: core/src/yoga.ts#ALIGN_STRETCH [status=implemented hash=d495fe5a1d4b]
public let ALIGN_STRETCH: Align = .stretch
// parity: core/src/yoga.ts#ALIGN_BASELINE [status=implemented hash=c830ba4a8270]
public let ALIGN_BASELINE: Align = .baseline
// parity: core/src/yoga.ts#ALIGN_SPACE_BETWEEN [status=implemented hash=31cfc3b254ea]
public let ALIGN_SPACE_BETWEEN: Align = .spaceBetween
// parity: core/src/yoga.ts#ALIGN_SPACE_AROUND [status=implemented hash=823584b3774f]
public let ALIGN_SPACE_AROUND: Align = .spaceAround
// parity: core/src/yoga.ts#ALIGN_SPACE_EVENLY [status=implemented hash=c4e40b08075b]
public let ALIGN_SPACE_EVENLY: Align = .spaceEvenly

// parity: core/src/yoga.ts#BOX_SIZING_BORDER_BOX [status=implemented hash=c4cd30a44799]
public let BOX_SIZING_BORDER_BOX: BoxSizing = .borderBox
// parity: core/src/yoga.ts#BOX_SIZING_CONTENT_BOX [status=implemented hash=1118cbe9eb14]
public let BOX_SIZING_CONTENT_BOX: BoxSizing = .contentBox

// parity: core/src/yoga.ts#DIMENSION_WIDTH [status=implemented hash=f2c75909609b]
public let DIMENSION_WIDTH: Dimension = .width
// parity: core/src/yoga.ts#DIMENSION_HEIGHT [status=implemented hash=9e54fecde7ec]
public let DIMENSION_HEIGHT: Dimension = .height

// parity: core/src/yoga.ts#DIRECTION_INHERIT [status=implemented hash=c9810a70bd11]
public let DIRECTION_INHERIT: Direction = .inherit
// parity: core/src/yoga.ts#DIRECTION_LTR [status=implemented hash=a2b60055a91d]
public let DIRECTION_LTR: Direction = .ltr
// parity: core/src/yoga.ts#DIRECTION_RTL [status=implemented hash=fb08ff02ca65]
public let DIRECTION_RTL: Direction = .rtl

// parity: core/src/yoga.ts#DISPLAY_FLEX [status=implemented hash=8f6b6c1b83c0]
public let DISPLAY_FLEX: Display = .flex
// parity: core/src/yoga.ts#DISPLAY_NONE [status=implemented hash=9cf4537fc801]
public let DISPLAY_NONE: Display = .none
// parity: core/src/yoga.ts#DISPLAY_CONTENTS [status=implemented hash=48ca41bbfbcd]
public let DISPLAY_CONTENTS: Display = .contents

// parity: core/src/yoga.ts#EDGE_LEFT [status=implemented hash=2c7d4d52f0b8]
public let EDGE_LEFT: Edge = .left
// parity: core/src/yoga.ts#EDGE_TOP [status=implemented hash=82eb30a12d17]
public let EDGE_TOP: Edge = .top
// parity: core/src/yoga.ts#EDGE_RIGHT [status=implemented hash=9659217dd305]
public let EDGE_RIGHT: Edge = .right
// parity: core/src/yoga.ts#EDGE_BOTTOM [status=implemented hash=45d12f04a42a]
public let EDGE_BOTTOM: Edge = .bottom
// parity: core/src/yoga.ts#EDGE_START [status=implemented hash=3974524fc4eb]
public let EDGE_START: Edge = .start
// parity: core/src/yoga.ts#EDGE_END [status=implemented hash=279e15aea1f8]
public let EDGE_END: Edge = .end
// parity: core/src/yoga.ts#EDGE_HORIZONTAL [status=implemented hash=7cc2eada41a8]
public let EDGE_HORIZONTAL: Edge = .horizontal
// parity: core/src/yoga.ts#EDGE_VERTICAL [status=implemented hash=8b0690205ea4]
public let EDGE_VERTICAL: Edge = .vertical
// parity: core/src/yoga.ts#EDGE_ALL [status=implemented hash=01a8b4b97d6b]
public let EDGE_ALL: Edge = .all

// parity: core/src/yoga.ts#ERRATA_NONE [status=implemented hash=7d256db7f672]
public let ERRATA_NONE: Errata = .none
// parity: core/src/yoga.ts#ERRATA_STRETCH_FLEX_BASIS [status=implemented hash=e235dadcdc88]
public let ERRATA_STRETCH_FLEX_BASIS: Errata = .stretchFlexBasis
// parity: core/src/yoga.ts#ERRATA_ABSOLUTE_POSITION_WITHOUT_INSETS_EXCLUDES_PADDING [status=implemented hash=ce90afb838ee]
public let ERRATA_ABSOLUTE_POSITION_WITHOUT_INSETS_EXCLUDES_PADDING: Errata = .absolutePositionWithoutInsetsExcludesPadding
// parity: core/src/yoga.ts#ERRATA_ABSOLUTE_PERCENT_AGAINST_INNER_SIZE [status=implemented hash=adcb2f7be2f7]
public let ERRATA_ABSOLUTE_PERCENT_AGAINST_INNER_SIZE: Errata = .absolutePercentAgainstInnerSize
// parity: core/src/yoga.ts#ERRATA_ALL [status=implemented hash=c5643863fa6f]
public let ERRATA_ALL: Errata = .all
// parity: core/src/yoga.ts#ERRATA_CLASSIC [status=implemented hash=15b4dcce9e7b]
public let ERRATA_CLASSIC: Errata = .classic

// parity: core/src/yoga.ts#EXPERIMENTAL_FEATURE_WEB_FLEX_BASIS [status=implemented hash=b234e4bc01bc]
public let EXPERIMENTAL_FEATURE_WEB_FLEX_BASIS: ExperimentalFeature = .webFlexBasis

// parity: core/src/yoga.ts#FLEX_DIRECTION_COLUMN [status=implemented hash=368a2bfa414d]
public let FLEX_DIRECTION_COLUMN: FlexDirection = .column
// parity: core/src/yoga.ts#FLEX_DIRECTION_COLUMN_REVERSE [status=implemented hash=565e8f05f4ff]
public let FLEX_DIRECTION_COLUMN_REVERSE: FlexDirection = .columnReverse
// parity: core/src/yoga.ts#FLEX_DIRECTION_ROW [status=implemented hash=2d21b3db3ea2]
public let FLEX_DIRECTION_ROW: FlexDirection = .row
// parity: core/src/yoga.ts#FLEX_DIRECTION_ROW_REVERSE [status=implemented hash=41f90e4282f2]
public let FLEX_DIRECTION_ROW_REVERSE: FlexDirection = .rowReverse

// parity: core/src/yoga.ts#GUTTER_COLUMN [status=implemented hash=e786857a7ce5]
public let GUTTER_COLUMN: Gutter = .column
// parity: core/src/yoga.ts#GUTTER_ROW [status=implemented hash=81b7cef24956]
public let GUTTER_ROW: Gutter = .row
// parity: core/src/yoga.ts#GUTTER_ALL [status=implemented hash=924ae38ced95]
public let GUTTER_ALL: Gutter = .all

// parity: core/src/yoga.ts#JUSTIFY_FLEX_START [status=implemented hash=355a8845a85a]
public let JUSTIFY_FLEX_START: Justify = .flexStart
// parity: core/src/yoga.ts#JUSTIFY_CENTER [status=implemented hash=c7fbc1f3679f]
public let JUSTIFY_CENTER: Justify = .center
// parity: core/src/yoga.ts#JUSTIFY_FLEX_END [status=implemented hash=7157b38fb784]
public let JUSTIFY_FLEX_END: Justify = .flexEnd
// parity: core/src/yoga.ts#JUSTIFY_SPACE_BETWEEN [status=implemented hash=02c6d47d2922]
public let JUSTIFY_SPACE_BETWEEN: Justify = .spaceBetween
// parity: core/src/yoga.ts#JUSTIFY_SPACE_AROUND [status=implemented hash=ce76e493a897]
public let JUSTIFY_SPACE_AROUND: Justify = .spaceAround
// parity: core/src/yoga.ts#JUSTIFY_SPACE_EVENLY [status=implemented hash=41d7f7c02ebd]
public let JUSTIFY_SPACE_EVENLY: Justify = .spaceEvenly

// parity: core/src/yoga.ts#LOG_LEVEL_ERROR [status=implemented hash=8759e5f01603]
public let LOG_LEVEL_ERROR: LogLevel = .error
// parity: core/src/yoga.ts#LOG_LEVEL_WARN [status=implemented hash=a8df54f25217]
public let LOG_LEVEL_WARN: LogLevel = .warn
// parity: core/src/yoga.ts#LOG_LEVEL_INFO [status=implemented hash=2a6bc76305f3]
public let LOG_LEVEL_INFO: LogLevel = .info
// parity: core/src/yoga.ts#LOG_LEVEL_DEBUG [status=implemented hash=a8a150226b74]
public let LOG_LEVEL_DEBUG: LogLevel = .debug
// parity: core/src/yoga.ts#LOG_LEVEL_VERBOSE [status=implemented hash=a633a87982cd]
public let LOG_LEVEL_VERBOSE: LogLevel = .verbose
// parity: core/src/yoga.ts#LOG_LEVEL_FATAL [status=implemented hash=ff42b8d79eb8]
public let LOG_LEVEL_FATAL: LogLevel = .fatal

// parity: core/src/yoga.ts#MEASURE_MODE_UNDEFINED [status=implemented hash=58b7c353be7f]
public let MEASURE_MODE_UNDEFINED: MeasureMode = .undefined
// parity: core/src/yoga.ts#MEASURE_MODE_EXACTLY [status=implemented hash=8f452dcdabf2]
public let MEASURE_MODE_EXACTLY: MeasureMode = .exactly
// parity: core/src/yoga.ts#MEASURE_MODE_AT_MOST [status=implemented hash=844275b1fddb]
public let MEASURE_MODE_AT_MOST: MeasureMode = .atMost

// parity: core/src/yoga.ts#NODE_TYPE_DEFAULT [status=implemented hash=7cfafda65d9c]
public let NODE_TYPE_DEFAULT: NodeType = .default
// parity: core/src/yoga.ts#NODE_TYPE_TEXT [status=implemented hash=72840d2d3e7a]
public let NODE_TYPE_TEXT: NodeType = .text

// parity: core/src/yoga.ts#OVERFLOW_VISIBLE [status=implemented hash=e265e34bda5d]
public let OVERFLOW_VISIBLE: Overflow = .visible
// parity: core/src/yoga.ts#OVERFLOW_HIDDEN [status=implemented hash=edbcd0a4e9eb]
public let OVERFLOW_HIDDEN: Overflow = .hidden
// parity: core/src/yoga.ts#OVERFLOW_SCROLL [status=implemented hash=3ffd0a48f322]
public let OVERFLOW_SCROLL: Overflow = .scroll

// parity: core/src/yoga.ts#POSITION_TYPE_STATIC [status=implemented hash=f4a6f1aa823a]
public let POSITION_TYPE_STATIC: PositionType = .static
// parity: core/src/yoga.ts#POSITION_TYPE_RELATIVE [status=implemented hash=4d2a597306d8]
public let POSITION_TYPE_RELATIVE: PositionType = .relative
// parity: core/src/yoga.ts#POSITION_TYPE_ABSOLUTE [status=implemented hash=fa7f4c0e4682]
public let POSITION_TYPE_ABSOLUTE: PositionType = .absolute

// parity: core/src/yoga.ts#UNIT_UNDEFINED [status=implemented hash=c82c418ac5d3]
public let UNIT_UNDEFINED: Unit = .undefined
// parity: core/src/yoga.ts#UNIT_POINT [status=implemented hash=331fdd4e49e5]
public let UNIT_POINT: Unit = .point
// parity: core/src/yoga.ts#UNIT_PERCENT [status=implemented hash=104610cd29cc]
public let UNIT_PERCENT: Unit = .percent
// parity: core/src/yoga.ts#UNIT_AUTO [status=implemented hash=c71da68e5ea6]
public let UNIT_AUTO: Unit = .auto

// parity: core/src/yoga.ts#WRAP_NO_WRAP [status=implemented hash=196bf83e88ce]
public let WRAP_NO_WRAP: Wrap = .noWrap
// parity: core/src/yoga.ts#WRAP_WRAP [status=implemented hash=01a421946eb4]
public let WRAP_WRAP: Wrap = .wrap
// parity: core/src/yoga.ts#WRAP_WRAP_REVERSE [status=implemented hash=c5720853e80e]
public let WRAP_WRAP_REVERSE: Wrap = .wrapReverse

// MARK: - Yoga Value, Layout, Status & Error

/// Yoga numeric value pair `{ unit, value }` matching `yoga.ts#Value`.
public struct YogaValue: Equatable, Hashable, Sendable, Codable {
    public var unit: Unit
    public var value: Float

    public init(unit: Unit, value: Float) {
        self.unit = unit
        self.value = value
    }

    public init(flexValue: FlexValue) {
        self.unit = flexValue.unit
        self.value = flexValue.rawValue
    }

    public var flexValue: FlexValue {
        switch unit {
        case .undefined: return .undefined
        case .auto: return .auto
        case .point: return value.isFinite ? .point(value) : .undefined
        case .percent: return value.isFinite ? .percent(value) : .undefined
        }
    }

    public static func == (lhs: YogaValue, rhs: YogaValue) -> Bool {
        if lhs.unit != rhs.unit { return false }
        if lhs.value.isNaN && rhs.value.isNaN { return true }
        return lhs.value == rhs.value
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(unit)
        if value.isNaN {
            hasher.combine(UInt32(0x7FC0_0000))
        } else {
            hasher.combine(value.bitPattern)
        }
    }
}

/// Computed layout rectangle matching `yoga.ts#Layout`.
public struct YogaLayout: Equatable, Hashable, Sendable, Codable {
    public var left: Float
    public var right: Float
    public var top: Float
    public var bottom: Float
    public var width: Float
    public var height: Float

    public static let zero = YogaLayout(left: 0, right: 0, top: 0, bottom: 0, width: 0, height: 0)

    public init(left: Float, right: Float, top: Float, bottom: Float, width: Float, height: Float) {
        self.left = left
        self.right = right
        self.top = top
        self.bottom = bottom
        self.width = width
        self.height = height
    }

    public init(computed: FlexComputedLayout) {
        self.left = computed.left
        self.right = computed.right
        self.top = computed.top
        self.bottom = computed.bottom
        self.width = computed.width
        self.height = computed.height
    }
}

public typealias YogaMeasureFunction = @Sendable (Float, MeasureMode, Float, MeasureMode) -> FlexSize
public typealias YogaDirtiedFunction = @Sendable (YogaNode) -> Void

// parity: core/src/yoga.ts#YogaStatus [status=implemented hash=4c4c51045297]
public enum YogaStatus: Int32, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case ok = 0
    case invalidArgument = 1
    case outOfMemory = 2
    case exception = 3
    case poisoned = 4
    case busy = 5
    case depthLimit = 6

    public var label: String {
        switch self {
        case .ok: return "Ok"
        case .invalidArgument: return "InvalidArgument"
        case .outOfMemory: return "OutOfMemory"
        case .exception: return "Exception"
        case .poisoned: return "Poisoned"
        case .busy: return "Busy"
        case .depthLimit: return "DepthLimit"
        }
    }
}

// parity: core/src/yoga.ts#YogaError [status=implemented hash=ef5dab844c12]
public struct YogaError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let name: String = "YogaError"
    public let operation: String
    public let status: YogaStatus
    public let message: String

    public init(operation: String, status: YogaStatus, message: String? = nil) {
        self.operation = operation
        self.status = status
        self.message = message ?? "\(operation) failed: \(status.label) (status \(status.rawValue))"
    }

    public var description: String { message }
}

// MARK: - yoga.internal.ts Primitives & Scene Style Helpers

// parity: core/src/yoga.internal.ts#UNDEFINED_VALUE [status=implemented hash=5b377b55af5e]
public let UNDEFINED_VALUE = YogaValue(unit: .undefined, value: .nan)

/// Flexible input accepted by Yoga dimension/spacing setters (`number | "auto" | "${number}%" | Value | undefined`).
// parity: core/src/yoga.internal.ts#ValueInput [status=implemented hash=f6e8f31d8c95]
public enum YogaValueInput: Equatable, Hashable, Sendable,
    ExpressibleByFloatLiteral,
    ExpressibleByIntegerLiteral,
    ExpressibleByStringLiteral,
    ExpressibleByNilLiteral
{
    case undefined
    case auto
    case point(Float)
    case percent(Float)
    case value(YogaValue)
    case string(String)

    public init(floatLiteral value: Double) {
        self = .point(Float(value))
    }

    public init(integerLiteral value: Int) {
        self = .point(Float(value))
    }

    public init(stringLiteral value: String) {
        self = .string(value)
    }

    public init(nilLiteral: ()) {
        self = .undefined
    }

    public static func from(_ value: Float?) -> YogaValueInput {
        guard let value else { return .undefined }
        return .point(value)
    }

    public static func from(_ value: FlexValue) -> YogaValueInput {
        switch value {
        case .undefined: return .undefined
        case .auto: return .auto
        case .point(let v): return .point(v)
        case .percent(let v): return .percent(v)
        }
    }
}

public typealias ValueInput = YogaValueInput

// parity: core/src/yoga.internal.ts#YogaEnumKind [status=implemented hash=8b8eaeb52617]
public enum YogaEnumKind: Int32, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case direction = 0
    case flexDirection = 1
    case justifyContent = 2
    case alignContent = 3
    case alignItems = 4
    case alignSelf = 5
    case positionType = 6
    case flexWrap = 7
    case overflow = 8
    case display = 9
    case boxSizing = 10
    case layoutMode = 11
}

// parity: core/src/yoga.internal.ts#YogaFloatKind [status=implemented hash=dfa475e7aca4]
public enum YogaFloatKind: Int32, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case flex = 0
    case flexGrow = 1
    case flexShrink = 2
    case aspectRatio = 3
}

// parity: core/src/yoga.internal.ts#YogaValueKind [status=implemented hash=7244b9f37813]
public enum YogaValueKind: Int32, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case width = 0
    case height = 1
    case minWidth = 2
    case minHeight = 3
    case maxWidth = 4
    case maxHeight = 5
    case flexBasis = 6
    case margin = 7
    case padding = 8
    case position = 9
    case gap = 10
}

// parity: core/src/yoga.internal.ts#YogaEnumKindId [status=implemented hash=40dcd2475c1e]
public typealias YogaEnumKindId = YogaEnumKind

// parity: core/src/yoga.internal.ts#YogaFloatKindId [status=implemented hash=1781427693ac]
public typealias YogaFloatKindId = YogaFloatKind

// parity: core/src/yoga.internal.ts#YogaValueKindId [status=implemented hash=e1bbf2b2075e]
public typealias YogaValueKindId = YogaValueKind

/// Style group discriminator matching `OT_STYLE_*` in `native-abi.generated.ts`.
public enum YogaStyleGroup: Int32, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case `enum` = 0
    case float = 1
    case value = 2
    case border = 3
    case dimension = 4
}

/// Style flag bitmask matching `OT_STYLE_FLAGS_*` in `native-abi.generated.ts`.
public struct YogaStyleFlags: OptionSet, Equatable, Hashable, Sendable, Codable {
    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    public static let none = YogaStyleFlags([])
    public static let disableFlexShrink = YogaStyleFlags(rawValue: 1 << 0)
    public static let content = YogaStyleFlags(rawValue: 1 << 1)
}

/// Sentinel edge value used for style writes that do not address an edge or gutter (`OT_EDGE_NONE`).
public let YOGA_EDGE_NONE: Int32 = -1

/// Minimal scene interface registered with `YogaHost` for staged mutation flushing.
public protocol YogaHostScene: AnyObject {
    func flushStaged() throws
}

/// Minimal scene style bridge implemented by `NativeScene` so `OpenTUILayout` stays acyclic.
public protocol YogaSceneStyleBridge: AnyObject {
    func setStyle(
        node: AnyObject,
        group: YogaStyleGroup,
        kind: Int32,
        edge: Int32,
        unit: Unit,
        value: Float,
        flags: YogaStyleFlags
    ) throws

    func getStyle(
        node: AnyObject,
        group: YogaStyleGroup,
        kind: Int32,
        edge: Int32
    ) throws -> YogaValue
}

// parity: core/src/yoga.internal.ts#parseYogaValue [status=implemented hash=05bba9a2d4bb]
public func parseYogaValue(_ input: YogaValueInput) throws(YogaError) -> YogaValue {
    switch input {
    case .value(let v):
        return v
    case .undefined:
        return UNDEFINED_VALUE
    case .auto:
        return YogaValue(unit: .auto, value: .nan)
    case .point(let v):
        return YogaValue(unit: .point, value: v)
    case .percent(let v):
        return YogaValue(unit: .percent, value: v)
    case .string(let raw):
        if raw == "auto" {
            return YogaValue(unit: .auto, value: .nan)
        }
        guard raw.hasSuffix("%") else {
            throw YogaError(operation: "parseYogaValue", status: .invalidArgument, message: "Invalid Yoga value: \(raw)")
        }
        let numericPrefix = raw.dropLast()
        guard let parsed = Float(numericPrefix), !parsed.isNaN else {
            throw YogaError(
                operation: "parseYogaValue",
                status: .invalidArgument,
                message: "Invalid Yoga percentage value: \(raw)"
            )
        }
        return YogaValue(unit: .percent, value: parsed)
    }
}

/// Validates that a Yoga callback returned a synchronous value (rejecting thenable/async markers).
// parity: core/src/yoga.internal.ts#rejectAsyncCallback [status=adapted hash=546e8df4b072]
public func rejectAsyncCallback(_ value: Any?) throws(YogaError) {
    if value is (any YogaAsyncThenable) {
        throw YogaError(
            operation: "rejectAsyncCallback",
            status: .invalidArgument,
            message: "Yoga callbacks must be synchronous"
        )
    }
}

/// Marker protocol representing an asynchronous thenable rejected by synchronous Yoga callbacks.
public protocol YogaAsyncThenable {}

// parity: core/src/yoga.internal.ts#sceneSetEnum [status=implemented hash=583804bc505e]
public func sceneSetEnum(
    scene: any YogaSceneStyleBridge,
    node: AnyObject,
    kind: YogaEnumKindId,
    value: Int32,
    flags: YogaStyleFlags = .none
) throws {
    try scene.setStyle(
        node: node,
        group: .enum,
        kind: kind.rawValue,
        edge: YOGA_EDGE_NONE,
        unit: .undefined,
        value: Float(value),
        flags: flags
    )
}

// parity: core/src/yoga.internal.ts#sceneGetEnum [status=implemented hash=d79a29aaa1c0]
public func sceneGetEnum(
    scene: any YogaSceneStyleBridge,
    node: AnyObject,
    kind: YogaEnumKindId
) throws -> Int32 {
    let result = try scene.getStyle(node: node, group: .enum, kind: kind.rawValue, edge: YOGA_EDGE_NONE)
    return result.value.isFinite ? Int32(result.value) : 0
}

// parity: core/src/yoga.internal.ts#sceneSetFloat [status=implemented hash=b4ae0308a079]
public func sceneSetFloat(
    scene: any YogaSceneStyleBridge,
    node: AnyObject,
    kind: YogaFloatKindId,
    value: Float?,
    flags: YogaStyleFlags = .none
) throws {
    try scene.setStyle(
        node: node,
        group: .float,
        kind: kind.rawValue,
        edge: YOGA_EDGE_NONE,
        unit: .undefined,
        value: value ?? .nan,
        flags: flags
    )
}

// parity: core/src/yoga.internal.ts#sceneGetFloat [status=implemented hash=4d9057111a3e]
public func sceneGetFloat(
    scene: any YogaSceneStyleBridge,
    node: AnyObject,
    kind: YogaFloatKindId
) throws -> Float {
    try scene.getStyle(node: node, group: .float, kind: kind.rawValue, edge: YOGA_EDGE_NONE).value
}

// parity: core/src/yoga.internal.ts#sceneSetValue [status=implemented hash=0c20ff154ab4]
public func sceneSetValue(
    scene: any YogaSceneStyleBridge,
    node: AnyObject,
    kind: YogaValueKindId,
    edge: Int32,
    valueInput: YogaValueInput,
    flags: YogaStyleFlags = .none
) throws {
    let parsed = try parseYogaValue(valueInput)
    try scene.setStyle(
        node: node,
        group: .value,
        kind: kind.rawValue,
        edge: edge,
        unit: parsed.unit,
        value: parsed.value,
        flags: flags
    )
}

// parity: core/src/yoga.internal.ts#sceneGetValue [status=implemented hash=d56789bec4a1]
public func sceneGetValue(
    scene: any YogaSceneStyleBridge,
    node: AnyObject,
    kind: YogaValueKindId,
    edge: Int32
) throws -> YogaValue {
    try scene.getStyle(node: node, group: .value, kind: kind.rawValue, edge: edge)
}

// parity: core/src/yoga.internal.ts#sceneSetDimension [status=implemented hash=bcd5bb3fde11]
public func sceneSetDimension(
    scene: any YogaSceneStyleBridge,
    node: AnyObject,
    dimension: Dimension,
    input: YogaValueInput,
    disableFlexShrink: Bool = false
) throws {
    let parsed = try parseYogaValue(input)
    try scene.setStyle(
        node: node,
        group: .dimension,
        kind: dimension.rawValue,
        edge: YOGA_EDGE_NONE,
        unit: parsed.unit,
        value: parsed.value,
        flags: disableFlexShrink ? .disableFlexShrink : .none
    )
}

// MARK: - YogaHost

/// Callback and config lifecycle host matching `core/src/yoga.internal.ts#YogaHost`.
// parity: core/src/yoga.internal.ts#YogaHost [status=implemented hash=9942af05bc75]
public final class YogaHost: @unchecked Sendable {
    public static let shared = YogaHost()

    private struct WeakSceneBox {
        weak var scene: (any YogaHostScene)?
    }

    public internal(set) var configs: [UInt64: YogaConfig] = [:]
    private var nextConfigId: UInt64 = 1
    private var pendingScenes: [ObjectIdentifier: WeakSceneBox] = [:]
    private var defaultConfig: YogaConfig?
    private var callbackDepth: Int = 0
    private var mutationDepth: Int = 0
    private var callbackError: (any Error)?

    public init() {}

    internal func allocateConfigId() -> UInt64 {
        let id = nextConfigId
        nextConfigId &+= 1
        if nextConfigId == 0 { nextConfigId = 1 }
        return id
    }

    // parity: core/src/yoga.internal.ts#YogaHost.getDefaultConfig [status=implemented hash=b472ca03ae02]
    public func getDefaultConfig() -> YogaConfig {
        if let existing = defaultConfig, !existing.isFreed, configs[existing.id] === existing {
            return existing
        }
        let created = YogaConfig.create(host: self)
        defaultConfig = created
        return created
    }

    // parity: core/src/yoga.internal.ts#YogaHost.assertMutable [status=implemented hash=b0dd4a51c479]
    public func assertMutable() throws(YogaError) {
        if callbackDepth != 0 {
            throw YogaError(
                operation: "assertMutable",
                status: .busy,
                message: "Cannot mutate Yoga during a callback"
            )
        }
    }

    // parity: core/src/yoga.internal.ts#YogaHost.stageScene [status=implemented hash=087b15d17488]
    public func stageScene(_ scene: any YogaHostScene) {
        pendingScenes[ObjectIdentifier(scene)] = WeakSceneBox(scene: scene)
    }

    // parity: core/src/yoga.internal.ts#YogaHost.forgetScene [status=implemented hash=80a4a6ad74e8]
    public func forgetScene(_ scene: any YogaHostScene) {
        pendingScenes.removeValue(forKey: ObjectIdentifier(scene))
    }

    // parity: core/src/yoga.internal.ts#YogaHost.flushSceneMutations [status=implemented hash=960343523083]
    public func flushSceneMutations() throws {
        try assertMutable()
        let boxes = Array(pendingScenes.values)
        for box in boxes {
            if let scene = box.scene {
                try scene.flushStaged()
            }
        }
        pendingScenes = pendingScenes.filter { $0.value.scene != nil }
    }

    // parity: core/src/yoga.internal.ts#YogaHost.inCallback [status=implemented hash=86e3c455937f]
    public var inCallback: Bool {
        callbackDepth != 0
    }

    // parity: core/src/yoga.internal.ts#YogaHost.invokeCallback [status=implemented hash=208220f68c48]
    public func invokeCallback(_ callback: () throws -> Any?) {
        callbackDepth += 1
        defer { callbackDepth -= 1 }
        do {
            let result = try callback()
            try rejectAsyncCallback(result)
        } catch {
            if callbackError == nil {
                callbackError = error
            }
        }
    }

    // parity: core/src/yoga.internal.ts#YogaHost.runMutation [status=implemented hash=3adf4b81e1fb]
    public func runMutation<T>(_ operation: () throws -> T) throws -> T {
        try assertMutable()
        mutationDepth += 1
        var failure: (any Error)?
        var result: T?
        do {
            result = try operation()
        } catch {
            failure = error
        }
        mutationDepth -= 1
        try throwCallbackError(failure: failure)
        return result!
    }

    // parity: core/src/yoga.internal.ts#YogaHost.throwCallbackError [status=implemented hash=5d1f85c73a2e]
    public func throwCallbackError(failure: (any Error)? = nil) throws {
        if callbackDepth != 0 || mutationDepth != 0 {
            if let failure { throw failure }
            return
        }
        let cbErr = callbackError
        callbackError = nil
        if let failure, let cbErr {
            throw YogaError(
                operation: "runMutation",
                status: .exception,
                message: "Yoga operation and callback both failed: \(failure) | \(cbErr)"
            )
        }
        if let failure { throw failure }
        if let cbErr { throw cbErr }
    }

    // parity: core/src/yoga.internal.ts#YogaHost.dispose [status=implemented hash=d8e0d3d1a95e]
    public func dispose() throws {
        try assertMutable()
        let activeConfigs = Array(configs.values)
        for config in activeConfigs {
            try config.assertUnused()
        }
        for config in activeConfigs {
            try config.free()
        }
        defaultConfig = nil
        pendingScenes.removeAll()
    }
}

// MARK: - YogaConfig

/// Diagnostic logger callback attached to a `YogaConfig` via `setLogger(_:)`.
public typealias YogaNativeLogger = @Sendable (LogLevel, String) -> Void

/// Measure trampoline callback registered on a `YogaConfig` via `yogaConfigSetCallbacks`.
public typealias YogaJSMeasureTrampoline = @Sendable (YogaNode, Float, UInt32, Float, UInt32) -> Void

/// Dirtied trampoline callback registered on a `YogaConfig` via `yogaConfigSetCallbacks`.
public typealias YogaJSDirtiedTrampoline = @Sendable (YogaNode) -> Void

/// Native Yoga config callbacks matching `native/src/yoga.zig#Callbacks`.
public struct YogaBridgeCallbacks: Sendable {
    public var measure: (@Sendable (YogaNode, Float, UInt32, Float, UInt32) -> FlexSize)?
    public var dirtied: (@Sendable (YogaNode) -> Void)?

    public init(
        measure: (@Sendable (YogaNode, Float, UInt32, Float, UInt32) -> FlexSize)? = nil,
        dirtied: (@Sendable (YogaNode) -> Void)? = nil
    ) {
        self.measure = measure
        self.dirtied = dirtied
    }
}

/// Yoga layout configuration matching `core/src/yoga.ts#Config`.
// parity: core/src/yoga.ts#Config [status=implemented hash=05b741fdb293]
public final class YogaConfig: @unchecked Sendable {
    public let id: UInt64
    public let host: YogaHost
    internal let ownsConfig: Bool

    internal var nodes: [ObjectIdentifier: YogaNode] = [:]
    internal var measures: [ObjectIdentifier: YogaMeasureFunction] = [:]
    internal var dirtied: [ObjectIdentifier: YogaDirtiedFunction] = [:]
    internal var nativeCallbacks: YogaBridgeCallbacks = YogaBridgeCallbacks()
    internal var logger: YogaNativeLogger? = nil
    internal var callbackOwnerID: UInt64? = nil
    internal var jsMeasureCallback: YogaJSMeasureTrampoline? = nil
    internal var jsDirtiedCallback: YogaJSDirtiedTrampoline? = nil
    internal var measureResult: FlexSize = FlexSize(width: .nan, height: .nan)
    internal var roundsPositionsFromAbsoluteEdges: Bool = false

    private var freed: Bool = false
    private var callbacksInstalled: Bool = false
    private var _useWebDefaults: Bool = false
    private var _pointScaleFactor: Float = 1.0
    private var _errata: Errata = .none
    private var _experimentalFeatures: Set<ExperimentalFeature> = []

    public var isFreed: Bool { freed }

    private init(id: UInt64, host: YogaHost, ownsConfig: Bool, callbacks: YogaBridgeCallbacks = YogaBridgeCallbacks()) {
        self.id = id
        self.host = host
        self.ownsConfig = ownsConfig
        self.nativeCallbacks = callbacks
        self._useWebDefaults = false
        self._pointScaleFactor = 1.0
        host.configs[id] = self
    }

    /// Initializes a managed Yoga configuration with default OpenTUI settings (`useWebDefaults = false`,
    /// `pointScaleFactor = 1.0`), matching `native/src/yoga.zig#Config.init`.
    // parity: native/src/yoga.zig#Config.init [status=implemented hash=5ddbd2aecf67]
    public convenience init(
        host: YogaHost = .shared,
        callbacks: YogaBridgeCallbacks = YogaBridgeCallbacks(),
        heapOwned: Bool = true
    ) {
        self.init(id: host.allocateConfigId(), host: host, ownsConfig: heapOwned, callbacks: callbacks)
    }

    // parity: core/src/yoga.ts#Config.create [status=implemented hash=19d67d10933b]
    public static func create(host: YogaHost = .shared) -> YogaConfig {
        YogaConfig(id: host.allocateConfigId(), host: host, ownsConfig: true)
    }

    // parity: core/src/yoga.ts#Config.fromBorrowedPointer [status=adapted hash=da10483fec23]
    public static func fromBorrowedPointer(_ pointer: UInt64, host: YogaHost = .shared) -> YogaConfig {
        if let existing = host.configs[pointer] {
            return existing
        }
        return YogaConfig(id: pointer, host: host, ownsConfig: false)
    }

    // parity: core/src/yoga.ts#Config.destroy [status=implemented hash=aaa84d26af66]
    public static func destroy(_ config: YogaConfig) throws {
        try config.free()
    }

    /// Tears down this configuration once all owned nodes have been freed,
    /// matching `native/src/yoga.zig#Config.deinit`.
    // parity: native/src/yoga.zig#Config.deinit [status=implemented hash=eaed8353a07b]
    public func deinitConfig() throws(YogaError) {
        guard !freed else { return }
        if hasLiveNodes() {
            throw YogaError(
                operation: "Config.deinit",
                status: .busy,
                message: "Cannot deinit Yoga config while Yoga nodes are active"
            )
        }
        measures.removeAll()
        dirtied.removeAll()
        nativeCallbacks = YogaBridgeCallbacks()
        logger = nil
        callbackOwnerID = nil
        jsMeasureCallback = nil
        jsDirtiedCallback = nil
        measureResult = FlexSize(width: .nan, height: .nan)
        callbacksInstalled = false
        host.configs.removeValue(forKey: id)
        freed = true
    }

    /// Attaches a diagnostic logger to this configuration, matching `native/src/yoga.zig#Config.setLogger`.
    // parity: native/src/yoga.zig#Config.setLogger [status=implemented hash=30a76771ac3f]
    public func setLogger(_ logger: YogaNativeLogger?) {
        if freed { return }
        self.logger = logger
    }

    /// Emits a formatted Yoga diagnostic message to the configured logger, if present.
    public func emitLog(level: LogLevel, message: String) {
        guard !freed, let logger else { return }
        logger(level, "Yoga: \(message)")
    }

    /// Allocates and registers a new `YogaNode` owned by this configuration,
    /// matching `native/src/yoga.zig#Config.createNode`.
    // parity: native/src/yoga.zig#Config.createNode [status=implemented hash=f18385c5707e]
    public func createNode() throws(YogaError) -> YogaNode {
        try assertAlive()
        return YogaNode.createWithConfig(self)
    }

    /// Returns whether this configuration currently owns any live (unfreed) nodes,
    /// matching `native/src/yoga.zig#Config.hasLiveNodes`.
    // parity: native/src/yoga.zig#Config.hasLiveNodes [status=implemented hash=b8b37fdbee96]
    public func hasLiveNodes() -> Bool {
        !nodes.isEmpty
    }

    /// Enables or disables scene-mode absolute-edge rounding and list layout support.
    public func setRoundsPositionsFromAbsoluteEdges(_ enabled: Bool) {
        if freed { return }
        roundsPositionsFromAbsoluteEdges = enabled
    }

    internal func hasActiveLayout() -> Bool {
        for node in nodes.values {
            if node.treeRoot().activeRoot != nil {
                return true
            }
        }
        return false
    }

    // parity: core/src/yoga.ts#Config.free [status=implemented hash=303fddad7056]
    public func free() throws {
        if freed { return }
        try host.assertMutable()
        try assertUnused()
        measures.removeAll()
        dirtied.removeAll()
        nativeCallbacks = YogaBridgeCallbacks()
        logger = nil
        callbackOwnerID = nil
        jsMeasureCallback = nil
        jsDirtiedCallback = nil
        callbacksInstalled = false
        host.configs.removeValue(forKey: id)
        freed = true
    }

    // parity: core/src/yoga.ts#Config.assertUnused [status=implemented hash=f2a26d07d4fe]
    public func assertUnused() throws(YogaError) {
        if !nodes.isEmpty {
            throw YogaError(
                operation: "Config.free",
                status: .busy,
                message: "Cannot free Yoga config while Yoga nodes are active"
            )
        }
    }

    // parity: core/src/yoga.ts#Config.assertAlive [status=implemented hash=71f47c41c9c0]
    public func assertAlive() throws(YogaError) {
        if freed {
            throw YogaError(
                operation: "Config.assertAlive",
                status: .invalidArgument,
                message: "Yoga config is freed"
            )
        }
    }

    // parity: core/src/yoga.ts#Config.ensureCallbacks [status=implemented hash=2656731ba020]
    public func ensureCallbacks() throws(YogaError) {
        try assertAlive()
        try host.assertMutable()
        callbacksInstalled = true
    }

    // parity: core/src/yoga.ts#Config.setUseWebDefaults [status=implemented hash=c7142e2542dc]
    public func setUseWebDefaults(_ useWebDefaults: Bool) {
        if freed { return }
        _useWebDefaults = useWebDefaults
    }

    // parity: core/src/yoga.ts#Config.useWebDefaults [status=implemented hash=485e54e2ffef]
    public func useWebDefaults() -> Bool {
        if freed { return false }
        return _useWebDefaults
    }

    // parity: core/src/yoga.ts#Config.setPointScaleFactor [status=implemented hash=ef59c63c0f14]
    public func setPointScaleFactor(_ pointScaleFactor: Float) {
        if freed { return }
        guard pointScaleFactor.isFinite && pointScaleFactor >= 0 else { return }
        _pointScaleFactor = pointScaleFactor
        for node in nodes.values {
            node.flexNode.pointScaleFactor = pointScaleFactor
        }
    }

    // parity: core/src/yoga.ts#Config.getPointScaleFactor [status=implemented hash=075e9f135cdc]
    public func getPointScaleFactor() -> Float {
        if freed { return 0 }
        return _pointScaleFactor
    }

    // parity: core/src/yoga.ts#Config.setErrata [status=implemented hash=8df14e1b6de1]
    public func setErrata(_ errata: Errata) {
        if freed { return }
        _errata = errata
    }

    // parity: core/src/yoga.ts#Config.getErrata [status=implemented hash=5ef2e9f4ef8b]
    public func getErrata() -> Errata {
        if freed { return .none }
        return _errata
    }

    // parity: core/src/yoga.ts#Config.setExperimentalFeatureEnabled [status=implemented hash=b90898b1da93]
    public func setExperimentalFeatureEnabled(_ feature: ExperimentalFeature, _ enabled: Bool) {
        if freed { return }
        if enabled {
            _experimentalFeatures.insert(feature)
        } else {
            _experimentalFeatures.remove(feature)
        }
    }

    // parity: core/src/yoga.ts#Config.isExperimentalFeatureEnabled [status=implemented hash=6ea91a0f4dff]
    public func isExperimentalFeatureEnabled(_ feature: ExperimentalFeature) -> Bool {
        if freed { return false }
        return _experimentalFeatures.contains(feature)
    }
}

// MARK: - YogaNode

/// Full Yoga-compatible node wrapper backed by pure-Swift `FlexNode` and `FlexSolver`.
public final class YogaNode: @unchecked Sendable {
    public let flexNode: FlexNode
    public let config: YogaConfig

    private weak var _parent: YogaNode?
    private var _children: [YogaNode] = []
    private var freed: Bool = false

    internal var isPoisoned: Bool = false
    internal var activeRoot: YogaNode? = nil
    internal var measureError: YogaStatus = .ok
    internal var layoutMode: LayoutMode = .flex

    private var _flexShorthand: Float = .nan
    private var _flexGrowExplicit: Float = .nan
    private var _flexShrinkExplicit: Float = .nan
    private var _isReferenceBaseline: Bool = false
    private var _alwaysFormsContainingBlock: Bool = false

    private init(config: YogaConfig, flexNode: FlexNode = FlexNode()) {
        self.config = config
        self.flexNode = flexNode
        self.flexNode.pointScaleFactor = config.getPointScaleFactor()
        if config.useWebDefaults() {
            self.flexNode.style.flexDirection = .row
            self.flexNode.style.alignContent = .stretch
            self.flexNode.style.flexShrink = 1
        }
        config.nodes[ObjectIdentifier(self)] = self
    }

    // MARK: Factories

    // parity: core/src/yoga.ts#Node.create [status=implemented hash=bd15eeee647b]
    public static func create(_ config: YogaConfig? = nil) -> YogaNode {
        let resolved = config ?? YogaHost.shared.getDefaultConfig()
        return YogaNode(config: resolved)
    }

    // parity: core/src/yoga.ts#Node.createForOpenTUI [status=implemented hash=7221853d3d43]
    public static func createForOpenTUI() -> YogaNode {
        let cfg = YogaHost.shared.getDefaultConfig()
        let node = YogaNode(config: cfg)
        node.flexNode.pointScaleFactor = 1.0
        return node
    }

    // parity: core/src/yoga.ts#Node.createDefault [status=implemented hash=b088ac156700]
    public static func createDefault() -> YogaNode {
        YogaNode.create()
    }

    // parity: core/src/yoga.ts#Node.createWithConfig [status=implemented hash=8d85d5dc78c3]
    public static func createWithConfig(_ config: YogaConfig) -> YogaNode {
        YogaNode.create(config)
    }

    // parity: core/src/yoga.ts#Node.destroy [status=implemented hash=e334f1cdcac2]
    public static func destroy(_ node: YogaNode) {
        node.free()
    }

    /// Wraps an existing `FlexNode` under `config` (useful for bridging renderables).
    public static func wrapping(_ flexNode: FlexNode, config: YogaConfig? = nil) -> YogaNode {
        let resolved = config ?? YogaHost.shared.getDefaultConfig()
        return YogaNode(config: resolved, flexNode: flexNode)
    }

    // MARK: Lifecycle & Mutation Guards

    // parity: core/src/yoga.ts#Node.isFreed [status=implemented hash=3fb69de5f494]
    public func isFreed() -> Bool {
        freed
    }

    // parity: core/src/yoga.ts#Node.assertMutable [status=implemented hash=986c77a7f0d4]
    public func assertMutable() throws(YogaError) {
        try config.host.assertMutable()
    }

    // parity: core/src/yoga.ts#Node.runMutation [status=implemented hash=c1dc6667913f]
    public func runMutation<T>(_ operation: () throws -> T) throws -> T {
        try config.host.runMutation(operation)
    }

    // parity: core/src/yoga.ts#Node.free [status=implemented hash=6632d2bd2e1b]
    public func free() {
        if freed { return }
        if let parent = _parent {
            parent.removeChild(self)
        }
        removeAllChildren()
        markFreed()
    }

    // parity: core/src/yoga.ts#Node.freeRecursive [status=implemented hash=a2342ac1a101]
    public func freeRecursive() {
        if freed { return }
        if let parent = _parent {
            parent.removeChild(self)
        }
        var subtree: [YogaNode] = []
        collectSubtree(&subtree)
        for node in subtree {
            node._children.removeAll()
            node._parent = nil
            node.flexNode.removeAllChildren()
            node.markFreed()
        }
    }

    public func reset() {
        if freed { return }
        for child in _children {
            child._parent = nil
        }
        _children.removeAll()
        _parent = nil
        flexNode.reset()
        flexNode.pointScaleFactor = config.getPointScaleFactor()
        if config.useWebDefaults() {
            flexNode.style.flexDirection = .row
            flexNode.style.alignContent = .stretch
            flexNode.style.flexShrink = 1
        }
        _flexShorthand = .nan
        _flexGrowExplicit = .nan
        _flexShrinkExplicit = .nan
        _isReferenceBaseline = false
        _alwaysFormsContainingBlock = false
        unregisterCallbacks()
    }

    public func copyStyle(_ node: YogaNode) {
        if freed || node.freed { return }
        flexNode.copyStyle(from: node.flexNode)
        _flexShorthand = node._flexShorthand
        _flexGrowExplicit = node._flexGrowExplicit
        _flexShrinkExplicit = node._flexShrinkExplicit
        _isReferenceBaseline = node._isReferenceBaseline
        _alwaysFormsContainingBlock = node._alwaysFormsContainingBlock
    }

    // MARK: Tree Operations

    public func insertChild(_ child: YogaNode, _ index: Int) {
        if freed || child.freed || child === self { return }
        // Guard against ancestor cycles.
        var ancestor = _parent
        while let current = ancestor {
            if current === child { return }
            ancestor = current._parent
        }
        if let oldParent = child._parent {
            oldParent.removeChild(child)
        }
        let clamped = max(0, min(index, _children.count))
        _children.insert(child, at: clamped)
        child._parent = self
        flexNode.insertChild(child.flexNode, at: clamped)
    }

    public func insertChild(_ child: YogaNode, at index: Int) {
        insertChild(child, index)
    }

    public func removeChild(_ child: YogaNode) {
        if freed { return }
        guard let idx = _children.firstIndex(where: { $0 === child }) else { return }
        _children.remove(at: idx)
        child._parent = nil
        flexNode.removeChild(child.flexNode)
    }

    public func removeAllChildren() {
        if freed { return }
        for child in _children {
            child._parent = nil
        }
        _children.removeAll()
        flexNode.removeAllChildren()
    }

    public func getChild(_ index: Int) -> YogaNode? {
        if freed || index < 0 || index >= _children.count { return nil }
        return _children[index]
    }

    public func getChildCount() -> Int {
        if freed { return 0 }
        return _children.count
    }

    public func getParent() -> YogaNode? {
        if freed { return nil }
        return _parent
    }

    // MARK: Layout & Dirty State

    public func calculateLayout(
        _ width: Float? = nil,
        _ height: Float? = nil,
        _ direction: Direction = .ltr
    ) {
        if freed { return }
        flexNode.calculateLayout(availableWidth: width, availableHeight: height, direction: direction)
    }

    public func hasNewLayout() -> Bool {
        if freed { return false }
        return flexNode.hasNewLayout
    }

    public func markLayoutSeen() {
        if freed { return }
        flexNode.markLayoutSeen()
    }

    public func markDirty() {
        if freed { return }
        flexNode.markDirty()
    }

    public func isDirty() -> Bool {
        if freed { return true }
        return flexNode.isDirty
    }

    public func getComputedLayout() -> YogaLayout {
        if freed { return .zero }
        return YogaLayout(computed: flexNode.computedLayout)
    }

    public func getComputedLeft() -> Float { getComputedLayout().left }
    public func getComputedTop() -> Float { getComputedLayout().top }
    public func getComputedRight() -> Float { getComputedLayout().right }
    public func getComputedBottom() -> Float { getComputedLayout().bottom }
    public func getComputedWidth() -> Float { getComputedLayout().width }
    public func getComputedHeight() -> Float { getComputedLayout().height }

    public func getComputedMargin(_ edge: Edge) -> Float {
        if freed { return 0 }
        return flexNode.computedMargin(edge)
    }

    public func getComputedPadding(_ edge: Edge) -> Float {
        if freed { return 0 }
        return flexNode.computedPadding(edge)
    }

    public func getComputedBorder(_ edge: Edge) -> Float {
        if freed { return 0 }
        return flexNode.computedBorder(edge)
    }

    // MARK: Enum Style Properties

    // parity: core/src/yoga.ts#Node.setDirection [status=implemented hash=3794bb22b1ea]
    public func setDirection(_ direction: Direction) {
        if freed { return }
        flexNode.style.direction = direction
    }

    // parity: core/src/yoga.ts#Node.getDirection [status=implemented hash=68453fb4f8cf]
    public func getDirection() -> Direction {
        if freed { return .inherit }
        return flexNode.style.direction
    }

    // parity: core/src/yoga.ts#Node.setFlexDirection [status=implemented hash=81d8bc167592]
    public func setFlexDirection(_ flexDirection: FlexDirection) {
        if freed { return }
        flexNode.style.flexDirection = flexDirection
    }

    // parity: core/src/yoga.ts#Node.getFlexDirection [status=implemented hash=dd254306cf01]
    public func getFlexDirection() -> FlexDirection {
        if freed { return .column }
        return flexNode.style.flexDirection
    }

    // parity: core/src/yoga.ts#Node.setJustifyContent [status=implemented hash=cde6c8a91af4]
    public func setJustifyContent(_ justifyContent: Justify) {
        if freed { return }
        flexNode.style.justifyContent = justifyContent
    }

    // parity: core/src/yoga.ts#Node.getJustifyContent [status=implemented hash=bad9e121a869]
    public func getJustifyContent() -> Justify {
        if freed { return .flexStart }
        return flexNode.style.justifyContent
    }

    // parity: core/src/yoga.ts#Node.setAlignContent [status=implemented hash=2d3c2c3fd3b2]
    public func setAlignContent(_ alignContent: Align) {
        if freed { return }
        flexNode.style.alignContent = alignContent
    }

    // parity: core/src/yoga.ts#Node.getAlignContent [status=implemented hash=9be4c9bac4dd]
    public func getAlignContent() -> Align {
        if freed { return .flexStart }
        return flexNode.style.alignContent
    }

    // parity: core/src/yoga.ts#Node.setAlignItems [status=implemented hash=b96ac4d3488a]
    public func setAlignItems(_ alignItems: Align) {
        if freed { return }
        flexNode.style.alignItems = alignItems
    }

    // parity: core/src/yoga.ts#Node.getAlignItems [status=implemented hash=cc611ecda693]
    public func getAlignItems() -> Align {
        if freed { return .stretch }
        return flexNode.style.alignItems
    }

    // parity: core/src/yoga.ts#Node.setAlignSelf [status=implemented hash=f7bce49d5373]
    public func setAlignSelf(_ alignSelf: Align) {
        if freed { return }
        flexNode.style.alignSelf = alignSelf
    }

    // parity: core/src/yoga.ts#Node.getAlignSelf [status=implemented hash=2ed73795ae4a]
    public func getAlignSelf() -> Align {
        if freed { return .auto }
        return flexNode.style.alignSelf
    }

    // parity: core/src/yoga.ts#Node.setPositionType [status=implemented hash=cf78cc1bb023]
    public func setPositionType(_ positionType: PositionType) {
        if freed { return }
        flexNode.style.positionType = positionType
    }

    // parity: core/src/yoga.ts#Node.getPositionType [status=implemented hash=59bd8366094f]
    public func getPositionType() -> PositionType {
        if freed { return .relative }
        return flexNode.style.positionType
    }

    // parity: core/src/yoga.ts#Node.setFlexWrap [status=implemented hash=3e0f49ec2d1d]
    public func setFlexWrap(_ flexWrap: Wrap) {
        if freed { return }
        flexNode.style.flexWrap = flexWrap
    }

    // parity: core/src/yoga.ts#Node.getFlexWrap [status=implemented hash=3d55a42bd77c]
    public func getFlexWrap() -> Wrap {
        if freed { return .noWrap }
        return flexNode.style.flexWrap
    }

    // parity: core/src/yoga.ts#Node.setOverflow [status=implemented hash=32b4cc8de768]
    public func setOverflow(_ overflow: Overflow) {
        if freed { return }
        flexNode.style.overflow = overflow
    }

    // parity: core/src/yoga.ts#Node.getOverflow [status=implemented hash=9d6924e4fe5b]
    public func getOverflow() -> Overflow {
        if freed { return .visible }
        return flexNode.style.overflow
    }

    // parity: core/src/yoga.ts#Node.setDisplay [status=implemented hash=7adceac4332e]
    public func setDisplay(_ display: Display) {
        if freed { return }
        flexNode.style.display = display
    }

    // parity: core/src/yoga.ts#Node.getDisplay [status=implemented hash=e08322ba1fb9]
    public func getDisplay() -> Display {
        if freed { return .flex }
        return flexNode.style.display
    }

    // parity: core/src/yoga.ts#Node.setBoxSizing [status=implemented hash=122f858e97be]
    public func setBoxSizing(_ boxSizing: BoxSizing) {
        if freed { return }
        flexNode.style.boxSizing = boxSizing
    }

    // parity: core/src/yoga.ts#Node.getBoxSizing [status=implemented hash=15c0586b3fc2]
    public func getBoxSizing() -> BoxSizing {
        if freed { return .borderBox }
        return flexNode.style.boxSizing
    }

    // MARK: Float Style Properties

    // parity: core/src/yoga.ts#Node.setFlex [status=implemented hash=c3d9715c2985]
    public func setFlex(_ flex: Float?) {
        if freed { return }
        _flexShorthand = flex ?? .nan
        flexNode.style.setFlex(flex)
    }

    // parity: core/src/yoga.ts#Node.getFlex [status=implemented hash=0a2ade10b610]
    public func getFlex() -> Float {
        if freed { return .nan }
        return _flexShorthand
    }

    // parity: core/src/yoga.ts#Node.setFlexGrow [status=implemented hash=de2bc6320511]
    public func setFlexGrow(_ flexGrow: Float?) {
        if freed { return }
        if let flexGrow, flexGrow.isFinite {
            _flexGrowExplicit = flexGrow
            flexNode.style.flexGrow = flexGrow
        } else {
            _flexGrowExplicit = .nan
            flexNode.style.flexGrow = 0
        }
    }

    // parity: core/src/yoga.ts#Node.getFlexGrow [status=implemented hash=1d83f7313647]
    public func getFlexGrow() -> Float {
        if freed { return .nan }
        return _flexGrowExplicit.isNaN ? flexNode.style.flexGrow : _flexGrowExplicit
    }

    // parity: core/src/yoga.ts#Node.setFlexShrink [status=implemented hash=8bf5a79756dd]
    public func setFlexShrink(_ flexShrink: Float?) {
        if freed { return }
        if let flexShrink, flexShrink.isFinite {
            _flexShrinkExplicit = flexShrink
            flexNode.style.flexShrink = flexShrink
        } else {
            _flexShrinkExplicit = .nan
            flexNode.style.flexShrink = config.useWebDefaults() ? 1 : 0
        }
    }

    // parity: core/src/yoga.ts#Node.getFlexShrink [status=implemented hash=8a176ac7f6e5]
    public func getFlexShrink() -> Float {
        if freed { return .nan }
        return _flexShrinkExplicit.isNaN ? flexNode.style.flexShrink : _flexShrinkExplicit
    }

    // parity: core/src/yoga.ts#Node.setAspectRatio [status=implemented hash=ecbb2fa38330]
    public func setAspectRatio(_ aspectRatio: Float?) {
        if freed { return }
        if let aspectRatio, aspectRatio.isFinite {
            flexNode.style.aspectRatio = aspectRatio
        } else {
            flexNode.style.aspectRatio = nil
        }
    }

    // parity: core/src/yoga.ts#Node.getAspectRatio [status=implemented hash=3722d60f41f7]
    public func getAspectRatio() -> Float {
        if freed { return .nan }
        return flexNode.style.aspectRatio ?? .nan
    }

    // MARK: Value Style Properties

    private func coerceInput(_ input: YogaValueInput) -> FlexValue {
        if let parsed = try? parseYogaValue(input) {
            return parsed.flexValue
        }
        return .undefined
    }

    // parity: core/src/yoga.ts#Node.setFlexBasis [status=implemented hash=76db1541b927]
    public func setFlexBasis(_ flexBasis: YogaValueInput) {
        if freed { return }
        flexNode.style.flexBasis = coerceInput(flexBasis)
    }

    public func setFlexBasis(_ flexBasis: Float?) {
        setFlexBasis(.from(flexBasis))
    }

    // parity: core/src/yoga.ts#Node.setFlexBasisPercent [status=implemented hash=8a601f72a5c8]
    public func setFlexBasisPercent(_ flexBasis: Float?) {
        if freed { return }
        flexNode.style.flexBasis = flexBasis.flatMap { $0.isFinite ? .percent($0) : nil } ?? .undefined
    }

    // parity: core/src/yoga.ts#Node.setFlexBasisAuto [status=implemented hash=7926f00beebf]
    public func setFlexBasisAuto() {
        if freed { return }
        flexNode.style.flexBasis = .auto
    }

    // parity: core/src/yoga.ts#Node.getFlexBasis [status=implemented hash=8ab81b2fd697]
    public func getFlexBasis() -> YogaValue {
        if freed { return UNDEFINED_VALUE }
        return YogaValue(flexValue: flexNode.style.flexBasis)
    }

    // parity: core/src/yoga.ts#Node.setWidth [status=implemented hash=2c89b618e9f9]
    public func setWidth(_ width: YogaValueInput) {
        if freed { return }
        flexNode.style.width = coerceInput(width)
    }

    public func setWidth(_ width: Float?) {
        setWidth(.from(width))
    }

    // parity: core/src/yoga.ts#Node.setWidthPercent [status=implemented hash=c092833fc456]
    public func setWidthPercent(_ width: Float?) {
        if freed { return }
        flexNode.style.width = width.flatMap { $0.isFinite ? .percent($0) : nil } ?? .undefined
    }

    // parity: core/src/yoga.ts#Node.setWidthAuto [status=implemented hash=2b718bd674de]
    public func setWidthAuto() {
        if freed { return }
        flexNode.style.width = .auto
    }

    // parity: core/src/yoga.ts#Node.getWidth [status=implemented hash=9adce90027c7]
    public func getWidth() -> YogaValue {
        if freed { return UNDEFINED_VALUE }
        return YogaValue(flexValue: flexNode.style.width)
    }

    // parity: core/src/yoga.ts#Node.setHeight [status=implemented hash=31e4f31f110e]
    public func setHeight(_ height: YogaValueInput) {
        if freed { return }
        flexNode.style.height = coerceInput(height)
    }

    public func setHeight(_ height: Float?) {
        setHeight(.from(height))
    }

    // parity: core/src/yoga.ts#Node.setHeightPercent [status=implemented hash=deb2453146f2]
    public func setHeightPercent(_ height: Float?) {
        if freed { return }
        flexNode.style.height = height.flatMap { $0.isFinite ? .percent($0) : nil } ?? .undefined
    }

    // parity: core/src/yoga.ts#Node.setHeightAuto [status=implemented hash=ca847fc4ac63]
    public func setHeightAuto() {
        if freed { return }
        flexNode.style.height = .auto
    }

    // parity: core/src/yoga.ts#Node.getHeight [status=implemented hash=a2f530a9f656]
    public func getHeight() -> YogaValue {
        if freed { return UNDEFINED_VALUE }
        return YogaValue(flexValue: flexNode.style.height)
    }

    // parity: core/src/yoga.ts#Node.setMinWidth [status=implemented hash=eb22cdfdc5e2]
    public func setMinWidth(_ minWidth: YogaValueInput) {
        if freed { return }
        flexNode.style.minWidth = coerceInput(minWidth)
    }

    public func setMinWidth(_ minWidth: Float?) {
        setMinWidth(.from(minWidth))
    }

    // parity: core/src/yoga.ts#Node.setMinWidthPercent [status=implemented hash=7803e5130dff]
    public func setMinWidthPercent(_ minWidth: Float?) {
        if freed { return }
        flexNode.style.minWidth = minWidth.flatMap { $0.isFinite ? .percent($0) : nil } ?? .undefined
    }

    // parity: core/src/yoga.ts#Node.getMinWidth [status=implemented hash=4dd8e663cfbc]
    public func getMinWidth() -> YogaValue {
        if freed { return UNDEFINED_VALUE }
        return YogaValue(flexValue: flexNode.style.minWidth)
    }

    // parity: core/src/yoga.ts#Node.setMinHeight [status=implemented hash=45aae2b43cab]
    public func setMinHeight(_ minHeight: YogaValueInput) {
        if freed { return }
        flexNode.style.minHeight = coerceInput(minHeight)
    }

    public func setMinHeight(_ minHeight: Float?) {
        setMinHeight(.from(minHeight))
    }

    // parity: core/src/yoga.ts#Node.setMinHeightPercent [status=implemented hash=f0f95bc3f513]
    public func setMinHeightPercent(_ minHeight: Float?) {
        if freed { return }
        flexNode.style.minHeight = minHeight.flatMap { $0.isFinite ? .percent($0) : nil } ?? .undefined
    }

    // parity: core/src/yoga.ts#Node.getMinHeight [status=implemented hash=c029c5af3070]
    public func getMinHeight() -> YogaValue {
        if freed { return UNDEFINED_VALUE }
        return YogaValue(flexValue: flexNode.style.minHeight)
    }

    // parity: core/src/yoga.ts#Node.setMaxWidth [status=implemented hash=654103cb54a0]
    public func setMaxWidth(_ maxWidth: YogaValueInput) {
        if freed { return }
        flexNode.style.maxWidth = coerceInput(maxWidth)
    }

    public func setMaxWidth(_ maxWidth: Float?) {
        setMaxWidth(.from(maxWidth))
    }

    // parity: core/src/yoga.ts#Node.setMaxWidthPercent [status=implemented hash=3b8ee63f67b6]
    public func setMaxWidthPercent(_ maxWidth: Float?) {
        if freed { return }
        flexNode.style.maxWidth = maxWidth.flatMap { $0.isFinite ? .percent($0) : nil } ?? .undefined
    }

    // parity: core/src/yoga.ts#Node.getMaxWidth [status=implemented hash=a4bf1889e0c7]
    public func getMaxWidth() -> YogaValue {
        if freed { return UNDEFINED_VALUE }
        return YogaValue(flexValue: flexNode.style.maxWidth)
    }

    // parity: core/src/yoga.ts#Node.setMaxHeight [status=implemented hash=2ac296a55ec5]
    public func setMaxHeight(_ maxHeight: YogaValueInput) {
        if freed { return }
        flexNode.style.maxHeight = coerceInput(maxHeight)
    }

    public func setMaxHeight(_ maxHeight: Float?) {
        setMaxHeight(.from(maxHeight))
    }

    // parity: core/src/yoga.ts#Node.setMaxHeightPercent [status=implemented hash=40fe350ba61e]
    public func setMaxHeightPercent(_ maxHeight: Float?) {
        if freed { return }
        flexNode.style.maxHeight = maxHeight.flatMap { $0.isFinite ? .percent($0) : nil } ?? .undefined
    }

    // parity: core/src/yoga.ts#Node.getMaxHeight [status=implemented hash=c20961eb17e6]
    public func getMaxHeight() -> YogaValue {
        if freed { return UNDEFINED_VALUE }
        return YogaValue(flexValue: flexNode.style.maxHeight)
    }

    // parity: core/src/yoga.ts#Node.setMargin [status=implemented hash=be2ec521cffa]
    public func setMargin(_ edge: Edge, _ margin: YogaValueInput) {
        if freed { return }
        flexNode.style.margin.set(edge, coerceInput(margin))
    }

    public func setMargin(_ edge: Edge, _ margin: Float?) {
        setMargin(edge, .from(margin))
    }

    // parity: core/src/yoga.ts#Node.setMarginPercent [status=implemented hash=dfc7424366e6]
    public func setMarginPercent(_ edge: Edge, _ margin: Float?) {
        if freed { return }
        flexNode.style.margin.set(edge, margin.flatMap { $0.isFinite ? .percent($0) : nil } ?? .undefined)
    }

    // parity: core/src/yoga.ts#Node.setMarginAuto [status=implemented hash=38afe55d41c9]
    public func setMarginAuto(_ edge: Edge) {
        if freed { return }
        flexNode.style.margin.set(edge, .auto)
    }

    // parity: core/src/yoga.ts#Node.getMargin [status=implemented hash=69521af77d9c]
    public func getMargin(_ edge: Edge) -> YogaValue {
        if freed { return UNDEFINED_VALUE }
        return YogaValue(flexValue: flexNode.style.margin.value(for: edge))
    }

    // parity: core/src/yoga.ts#Node.setPadding [status=implemented hash=4e190372338f]
    public func setPadding(_ edge: Edge, _ padding: YogaValueInput) {
        if freed { return }
        flexNode.style.padding.set(edge, coerceInput(padding))
    }

    public func setPadding(_ edge: Edge, _ padding: Float?) {
        setPadding(edge, .from(padding))
    }

    // parity: core/src/yoga.ts#Node.setPaddingPercent [status=implemented hash=c473eecfeab4]
    public func setPaddingPercent(_ edge: Edge, _ padding: Float?) {
        if freed { return }
        flexNode.style.padding.set(edge, padding.flatMap { $0.isFinite ? .percent($0) : nil } ?? .undefined)
    }

    // parity: core/src/yoga.ts#Node.getPadding [status=implemented hash=5af0c94b8846]
    public func getPadding(_ edge: Edge) -> YogaValue {
        if freed { return UNDEFINED_VALUE }
        return YogaValue(flexValue: flexNode.style.padding.value(for: edge))
    }

    // parity: core/src/yoga.ts#Node.setPosition [status=implemented hash=036b0b8414e0]
    public func setPosition(_ edge: Edge, _ position: YogaValueInput) {
        if freed { return }
        flexNode.style.position.set(edge, coerceInput(position))
    }

    public func setPosition(_ edge: Edge, _ position: Float?) {
        setPosition(edge, .from(position))
    }

    // parity: core/src/yoga.ts#Node.setPositionPercent [status=implemented hash=c96cf90027c6]
    public func setPositionPercent(_ edge: Edge, _ position: Float?) {
        if freed { return }
        flexNode.style.position.set(edge, position.flatMap { $0.isFinite ? .percent($0) : nil } ?? .undefined)
    }

    // parity: core/src/yoga.ts#Node.setPositionAuto [status=implemented hash=381da99bcd9b]
    public func setPositionAuto(_ edge: Edge) {
        if freed { return }
        flexNode.style.position.set(edge, .auto)
    }

    // parity: core/src/yoga.ts#Node.getPosition [status=implemented hash=fb5486f47ed8]
    public func getPosition(_ edge: Edge) -> YogaValue {
        if freed { return UNDEFINED_VALUE }
        return YogaValue(flexValue: flexNode.style.position.value(for: edge))
    }

    // parity: core/src/yoga.ts#Node.setGap [status=implemented hash=594e79f446d0]
    public func setGap(_ gutter: Gutter, _ gap: YogaValueInput) {
        if freed { return }
        flexNode.style.gap.set(gutter, coerceInput(gap))
    }

    public func setGap(_ gutter: Gutter, _ gap: Float?) {
        setGap(gutter, .from(gap))
    }

    // parity: core/src/yoga.ts#Node.setGapPercent [status=implemented hash=765aee8b834b]
    public func setGapPercent(_ gutter: Gutter, _ gap: Float?) {
        if freed { return }
        flexNode.style.gap.set(gutter, gap.flatMap { $0.isFinite ? .percent($0) : nil } ?? .undefined)
    }

    // parity: core/src/yoga.ts#Node.getGap [status=implemented hash=13ff95884005]
    public func getGap(_ gutter: Gutter) -> YogaValue {
        if freed { return UNDEFINED_VALUE }
        return YogaValue(flexValue: flexNode.style.gap.value(for: gutter))
    }

    // parity: core/src/yoga.ts#Node.setBorder [status=implemented hash=c8129b9065e9]
    public func setBorder(_ edge: Edge, _ border: Float?) {
        if freed { return }
        if let border, border.isFinite {
            flexNode.style.border.set(edge, .point(border))
        } else {
            flexNode.style.border.set(edge, .undefined)
        }
    }

    // parity: core/src/yoga.ts#Node.getBorder [status=implemented hash=f181ebd19a38]
    public func getBorder(_ edge: Edge) -> Float {
        if freed { return .nan }
        return flexNode.style.border.value(for: edge).rawValue
    }

    // parity: core/src/yoga.ts#Node.setIsReferenceBaseline [status=implemented hash=79a9ea38f593]
    public func setIsReferenceBaseline(_ isReferenceBaseline: Bool) {
        if freed { return }
        _isReferenceBaseline = isReferenceBaseline
        flexNode.markDirty()
    }

    // parity: core/src/yoga.ts#Node.isReferenceBaseline [status=implemented hash=c12349e6acc4]
    public func isReferenceBaseline() -> Bool {
        if freed { return false }
        return _isReferenceBaseline
    }

    // parity: core/src/yoga.ts#Node.setAlwaysFormsContainingBlock [status=implemented hash=318d14ff6582]
    public func setAlwaysFormsContainingBlock(_ alwaysFormsContainingBlock: Bool) {
        if freed { return }
        _alwaysFormsContainingBlock = alwaysFormsContainingBlock
        flexNode.markDirty()
    }

    // parity: core/src/yoga.ts#Node.getAlwaysFormsContainingBlock [status=implemented hash=2b3f59c2ef02]
    public func getAlwaysFormsContainingBlock() -> Bool {
        if freed { return false }
        return _alwaysFormsContainingBlock
    }

    // MARK: Measure & Dirtied Callbacks

    public func setMeasureFunc(_ measureFunc: YogaMeasureFunction?) {
        if freed { return }
        guard let measureFunc else {
            unsetMeasureFunc()
            return
        }
        try? config.ensureCallbacks()
        let key = ObjectIdentifier(self)
        config.measures[key] = measureFunc
        let host = config.host
        flexNode.setMeasureFunc { width, widthMode, height, heightMode in
            var measured = FlexSize.zero
            host.invokeCallback {
                measured = measureFunc(width, widthMode, height, heightMode)
                return nil
            }
            return measured
        }
    }

    public func unsetMeasureFunc() {
        if freed { return }
        config.measures.removeValue(forKey: ObjectIdentifier(self))
        flexNode.unsetMeasureFunc()
    }

    public func hasMeasureFunc() -> Bool {
        if freed { return false }
        return flexNode.hasMeasureFunc
    }

    // parity: core/src/yoga.ts#Node.setDirtiedFunc [status=implemented hash=f7a5e3ca773f]
    public func setDirtiedFunc(_ dirtiedFunc: YogaDirtiedFunction?) {
        if freed { return }
        guard let dirtiedFunc else {
            unsetDirtiedFunc()
            return
        }
        try? config.ensureCallbacks()
        let key = ObjectIdentifier(self)
        config.dirtied[key] = dirtiedFunc
        let host = config.host
        flexNode.dirtiedFunc = { [weak self] _ in
            guard let self else { return }
            host.invokeCallback {
                dirtiedFunc(self)
                return nil
            }
        }
    }

    // parity: core/src/yoga.ts#Node.unsetDirtiedFunc [status=implemented hash=b4aebba44db7]
    public func unsetDirtiedFunc() {
        if freed { return }
        config.dirtied.removeValue(forKey: ObjectIdentifier(self))
        flexNode.dirtiedFunc = nil
    }

    // MARK: Internal Native Bridge Helpers

    internal func treeRoot() -> YogaNode {
        var current = self
        while let parent = current._parent {
            current = parent
        }
        return current
    }

    internal func subtreeMaxDepth() -> UInt32 {
        var queue: [(node: YogaNode, depth: UInt32)] = [(self, 1)]
        var index = 0
        var maxDepth: UInt32 = 1
        while index < queue.count {
            let entry = queue[index]
            index += 1
            if entry.depth > maxDepth {
                maxDepth = entry.depth
            }
            for child in entry.node._children {
                queue.append((child, entry.depth &+ 1))
            }
        }
        return maxDepth
    }

    internal func poisonTree() {
        let top = treeRoot()
        var queue: [YogaNode] = [top]
        var index = 0
        while index < queue.count {
            let current = queue[index]
            index += 1
            current.isPoisoned = true
            queue.append(contentsOf: current._children)
        }
    }

    internal func moveChildInternal(_ child: YogaNode, to finalIndex: Int) -> YogaStatus {
        let previous = child._parent
        if let previous {
            guard let prevIndex = previous._children.firstIndex(where: { $0 === child }) else {
                return .invalidArgument
            }
            if previous === self && prevIndex == finalIndex {
                return .ok
            }
            previous._children.remove(at: prevIndex)
            previous.flexNode.removeChild(child.flexNode)
        }
        let clamped = max(0, min(finalIndex, _children.count))
        _children.insert(child, at: clamped)
        child._parent = self
        flexNode.insertChild(child.flexNode, at: clamped)
        if previous != nil {
            child.flexNode.computedLayout = .zero
        }
        return .ok
    }

    internal func resetNativeState() {
        flexNode.reset()
        flexNode.pointScaleFactor = config.getPointScaleFactor()
        if config.useWebDefaults() {
            flexNode.style.flexDirection = .row
            flexNode.style.alignContent = .stretch
            flexNode.style.flexShrink = 1
        }
        _flexShorthand = .nan
        _flexGrowExplicit = .nan
        _flexShrinkExplicit = .nan
        _isReferenceBaseline = false
        _alwaysFormsContainingBlock = false
        layoutMode = .flex
        isPoisoned = false
        activeRoot = nil
        measureError = .ok
        unregisterCallbacks()
    }

    internal func setHasNewLayoutFlag(_ value: Bool) {
        if freed { return }
        flexNode.hasNewLayout = value
    }

    // MARK: Private Cleanup Helpers

    private func collectSubtree(_ result: inout [YogaNode]) {
        for child in _children {
            child.collectSubtree(&result)
        }
        result.append(self)
    }

    private func unregisterCallbacks() {
        let key = ObjectIdentifier(self)
        config.measures.removeValue(forKey: key)
        config.dirtied.removeValue(forKey: key)
        flexNode.measureFunc = nil
        flexNode.dirtiedFunc = nil
    }

    private func markFreed() {
        unregisterCallbacks()
        freed = true
        config.nodes.removeValue(forKey: ObjectIdentifier(self))
    }
}

// MARK: - Yoga Namespace Facade

/// Namespace matching the default export of `core/src/yoga.ts` (`Yoga.Node.create()`, `Yoga.Config.create()`, etc.).
// parity: core/src/yoga.ts#default [status=implemented hash=26defb10022d]
public enum Yoga {
    public typealias Config = YogaConfig
    public typealias Node = YogaNode
    public typealias Value = YogaValue
    public typealias Layout = YogaLayout
    public typealias Size = FlexSize

    public typealias Align = OpenTUILayout.Align
    public typealias BoxSizing = OpenTUILayout.BoxSizing
    public typealias Dimension = OpenTUILayout.Dimension
    public typealias Direction = OpenTUILayout.Direction
    public typealias Display = OpenTUILayout.Display
    public typealias Edge = OpenTUILayout.Edge
    public typealias Errata = OpenTUILayout.Errata
    public typealias ExperimentalFeature = OpenTUILayout.ExperimentalFeature
    public typealias FlexDirection = OpenTUILayout.FlexDirection
    public typealias Gutter = OpenTUILayout.Gutter
    public typealias Justify = OpenTUILayout.Justify
    public typealias LogLevel = OpenTUILayout.LogLevel
    public typealias MeasureMode = OpenTUILayout.MeasureMode
    public typealias NodeType = OpenTUILayout.NodeType
    public typealias Overflow = OpenTUILayout.Overflow
    public typealias PositionType = OpenTUILayout.PositionType
    public typealias Unit = OpenTUILayout.Unit
    public typealias Wrap = OpenTUILayout.Wrap

    public static let ALIGN_AUTO = OpenTUILayout.ALIGN_AUTO
    public static let ALIGN_FLEX_START = OpenTUILayout.ALIGN_FLEX_START
    public static let ALIGN_CENTER = OpenTUILayout.ALIGN_CENTER
    public static let ALIGN_FLEX_END = OpenTUILayout.ALIGN_FLEX_END
    public static let ALIGN_STRETCH = OpenTUILayout.ALIGN_STRETCH
    public static let ALIGN_BASELINE = OpenTUILayout.ALIGN_BASELINE
    public static let ALIGN_SPACE_BETWEEN = OpenTUILayout.ALIGN_SPACE_BETWEEN
    public static let ALIGN_SPACE_AROUND = OpenTUILayout.ALIGN_SPACE_AROUND
    public static let ALIGN_SPACE_EVENLY = OpenTUILayout.ALIGN_SPACE_EVENLY

    public static let BOX_SIZING_BORDER_BOX = OpenTUILayout.BOX_SIZING_BORDER_BOX
    public static let BOX_SIZING_CONTENT_BOX = OpenTUILayout.BOX_SIZING_CONTENT_BOX

    public static let DIMENSION_WIDTH = OpenTUILayout.DIMENSION_WIDTH
    public static let DIMENSION_HEIGHT = OpenTUILayout.DIMENSION_HEIGHT

    public static let DIRECTION_INHERIT = OpenTUILayout.DIRECTION_INHERIT
    public static let DIRECTION_LTR = OpenTUILayout.DIRECTION_LTR
    public static let DIRECTION_RTL = OpenTUILayout.DIRECTION_RTL

    public static let DISPLAY_FLEX = OpenTUILayout.DISPLAY_FLEX
    public static let DISPLAY_NONE = OpenTUILayout.DISPLAY_NONE
    public static let DISPLAY_CONTENTS = OpenTUILayout.DISPLAY_CONTENTS

    public static let EDGE_LEFT = OpenTUILayout.EDGE_LEFT
    public static let EDGE_TOP = OpenTUILayout.EDGE_TOP
    public static let EDGE_RIGHT = OpenTUILayout.EDGE_RIGHT
    public static let EDGE_BOTTOM = OpenTUILayout.EDGE_BOTTOM
    public static let EDGE_START = OpenTUILayout.EDGE_START
    public static let EDGE_END = OpenTUILayout.EDGE_END
    public static let EDGE_HORIZONTAL = OpenTUILayout.EDGE_HORIZONTAL
    public static let EDGE_VERTICAL = OpenTUILayout.EDGE_VERTICAL
    public static let EDGE_ALL = OpenTUILayout.EDGE_ALL

    public static let ERRATA_NONE = OpenTUILayout.ERRATA_NONE
    public static let ERRATA_STRETCH_FLEX_BASIS = OpenTUILayout.ERRATA_STRETCH_FLEX_BASIS
    public static let ERRATA_ABSOLUTE_POSITION_WITHOUT_INSETS_EXCLUDES_PADDING =
        OpenTUILayout.ERRATA_ABSOLUTE_POSITION_WITHOUT_INSETS_EXCLUDES_PADDING
    public static let ERRATA_ABSOLUTE_PERCENT_AGAINST_INNER_SIZE =
        OpenTUILayout.ERRATA_ABSOLUTE_PERCENT_AGAINST_INNER_SIZE
    public static let ERRATA_ALL = OpenTUILayout.ERRATA_ALL
    public static let ERRATA_CLASSIC = OpenTUILayout.ERRATA_CLASSIC

    public static let EXPERIMENTAL_FEATURE_WEB_FLEX_BASIS = OpenTUILayout.EXPERIMENTAL_FEATURE_WEB_FLEX_BASIS

    public static let FLEX_DIRECTION_COLUMN = OpenTUILayout.FLEX_DIRECTION_COLUMN
    public static let FLEX_DIRECTION_COLUMN_REVERSE = OpenTUILayout.FLEX_DIRECTION_COLUMN_REVERSE
    public static let FLEX_DIRECTION_ROW = OpenTUILayout.FLEX_DIRECTION_ROW
    public static let FLEX_DIRECTION_ROW_REVERSE = OpenTUILayout.FLEX_DIRECTION_ROW_REVERSE

    public static let GUTTER_COLUMN = OpenTUILayout.GUTTER_COLUMN
    public static let GUTTER_ROW = OpenTUILayout.GUTTER_ROW
    public static let GUTTER_ALL = OpenTUILayout.GUTTER_ALL

    public static let JUSTIFY_FLEX_START = OpenTUILayout.JUSTIFY_FLEX_START
    public static let JUSTIFY_CENTER = OpenTUILayout.JUSTIFY_CENTER
    public static let JUSTIFY_FLEX_END = OpenTUILayout.JUSTIFY_FLEX_END
    public static let JUSTIFY_SPACE_BETWEEN = OpenTUILayout.JUSTIFY_SPACE_BETWEEN
    public static let JUSTIFY_SPACE_AROUND = OpenTUILayout.JUSTIFY_SPACE_AROUND
    public static let JUSTIFY_SPACE_EVENLY = OpenTUILayout.JUSTIFY_SPACE_EVENLY

    public static let LOG_LEVEL_ERROR = OpenTUILayout.LOG_LEVEL_ERROR
    public static let LOG_LEVEL_WARN = OpenTUILayout.LOG_LEVEL_WARN
    public static let LOG_LEVEL_INFO = OpenTUILayout.LOG_LEVEL_INFO
    public static let LOG_LEVEL_DEBUG = OpenTUILayout.LOG_LEVEL_DEBUG
    public static let LOG_LEVEL_VERBOSE = OpenTUILayout.LOG_LEVEL_VERBOSE
    public static let LOG_LEVEL_FATAL = OpenTUILayout.LOG_LEVEL_FATAL

    public static let MEASURE_MODE_UNDEFINED = OpenTUILayout.MEASURE_MODE_UNDEFINED
    public static let MEASURE_MODE_EXACTLY = OpenTUILayout.MEASURE_MODE_EXACTLY
    public static let MEASURE_MODE_AT_MOST = OpenTUILayout.MEASURE_MODE_AT_MOST

    public static let NODE_TYPE_DEFAULT = OpenTUILayout.NODE_TYPE_DEFAULT
    public static let NODE_TYPE_TEXT = OpenTUILayout.NODE_TYPE_TEXT

    public static let OVERFLOW_VISIBLE = OpenTUILayout.OVERFLOW_VISIBLE
    public static let OVERFLOW_HIDDEN = OpenTUILayout.OVERFLOW_HIDDEN
    public static let OVERFLOW_SCROLL = OpenTUILayout.OVERFLOW_SCROLL

    public static let POSITION_TYPE_STATIC = OpenTUILayout.POSITION_TYPE_STATIC
    public static let POSITION_TYPE_RELATIVE = OpenTUILayout.POSITION_TYPE_RELATIVE
    public static let POSITION_TYPE_ABSOLUTE = OpenTUILayout.POSITION_TYPE_ABSOLUTE

    public static let UNIT_UNDEFINED = OpenTUILayout.UNIT_UNDEFINED
    public static let UNIT_POINT = OpenTUILayout.UNIT_POINT
    public static let UNIT_PERCENT = OpenTUILayout.UNIT_PERCENT
    public static let UNIT_AUTO = OpenTUILayout.UNIT_AUTO

    public static let WRAP_NO_WRAP = OpenTUILayout.WRAP_NO_WRAP
    public static let WRAP_WRAP = OpenTUILayout.WRAP_WRAP
    public static let WRAP_WRAP_REVERSE = OpenTUILayout.WRAP_WRAP_REVERSE
}
