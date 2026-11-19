// MARK: - Yoga Layout Enums (ABI-exact raw values matching `native-abi.generated.ts` & `yoga.ts`)

// parity: core/src/yoga.ts#Align [status=implemented hash=1c7db59d4a60]
public enum Align: Int32, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case auto = 0
    case flexStart = 1
    case center = 2
    case flexEnd = 3
    case stretch = 4
    case baseline = 5
    case spaceBetween = 6
    case spaceAround = 7
    case spaceEvenly = 8
}

// parity: core/src/yoga.ts#BoxSizing [status=implemented hash=c4bb6d531282]
public enum BoxSizing: Int32, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case borderBox = 0
    case contentBox = 1
}

// parity: core/src/yoga.ts#Dimension [status=implemented hash=45ae25aafd1f]
public enum Dimension: Int32, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case width = 0
    case height = 1
}

// parity: core/src/yoga.ts#Direction [status=implemented hash=118d61247789]
public enum Direction: Int32, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case inherit = 0
    case ltr = 1
    case rtl = 2
}

// parity: core/src/yoga.ts#Display [status=implemented hash=53af689e9d14]
public enum Display: Int32, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case flex = 0
    case none = 1
    case contents = 2
}

// parity: core/src/yoga.ts#Edge [status=implemented hash=473381882faf]
public enum Edge: Int32, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case left = 0
    case top = 1
    case right = 2
    case bottom = 3
    case start = 4
    case end = 5
    case horizontal = 6
    case vertical = 7
    case all = 8
}

// parity: core/src/yoga.ts#Errata [status=implemented hash=859e18f62081]
public enum Errata: Int32, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case none = 0
    case stretchFlexBasis = 1
    case absolutePositionWithoutInsetsExcludesPadding = 2
    case absolutePercentAgainstInnerSize = 4
    case all = 2147483647
    case classic = 2147483646
}

// parity: core/src/yoga.ts#ExperimentalFeature [status=implemented hash=5dd491a4cf82]
public enum ExperimentalFeature: Int32, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case webFlexBasis = 0
}

extension FlexDirection {
    /// Native ABI integer value matching `OT_FLEX_DIRECTION_*` in `opentui.h` / `yoga.ts`.
    public var yogaRawValue: Int32 {
        switch self {
        case .column: return 0
        case .columnReverse: return 1
        case .row: return 2
        case .rowReverse: return 3
        }
    }
}

// parity: core/src/yoga.ts#Gutter [status=implemented hash=55e6c3efac7c]
public enum Gutter: Int32, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case column = 0
    case row = 1
    case all = 2
}

// parity: core/src/yoga.ts#Justify [status=implemented hash=223725e0766f]
public enum Justify: Int32, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case flexStart = 0
    case center = 1
    case flexEnd = 2
    case spaceBetween = 3
    case spaceAround = 4
    case spaceEvenly = 5
}

/// Native layout mode constant (`OT_LAYOUT_MODE_FLEX` = 0, `OT_LAYOUT_MODE_LIST` = 1).
public enum LayoutMode: Int32, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case flex = 0
    case list = 1
}

// parity: core/src/yoga.ts#LogLevel [status=implemented hash=eac8c510bf5a]
public enum LogLevel: Int32, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case error = 0
    case warn = 1
    case info = 2
    case debug = 3
    case verbose = 4
    case fatal = 5
}

// parity: core/src/yoga.ts#MeasureMode [status=implemented hash=4c42bcb18a66]
public enum MeasureMode: Int32, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case undefined = 0
    case exactly = 1
    case atMost = 2
}

// parity: core/src/yoga.ts#NodeType [status=implemented hash=e46fe8fabfb5]
public enum NodeType: Int32, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case `default` = 0
    case text = 1
}

// parity: core/src/yoga.ts#Overflow [status=implemented hash=5608f95ae261]
public enum Overflow: Int32, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case visible = 0
    case hidden = 1
    case scroll = 2
}

// parity: core/src/yoga.ts#PositionType [status=implemented hash=5e2afe5d3283]
public enum PositionType: Int32, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case `static` = 0
    case relative = 1
    case absolute = 2
}

// parity: core/src/yoga.ts#Unit [status=implemented hash=1b6433972516]
public enum Unit: Int32, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case undefined = 0
    case point = 1
    case percent = 2
    case auto = 3
}

// parity: core/src/yoga.ts#Wrap [status=implemented hash=0dff1d325a7d]
public enum Wrap: Int32, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case noWrap = 0
    case wrap = 1
    case wrapReverse = 2
}

// MARK: - Yoga String Option Types

// parity: core/src/lib/yoga.options.ts#AlignString [status=implemented hash=af79ea874c9b]
public enum AlignString: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case auto = "auto"
    case flexStart = "flex-start"
    case center = "center"
    case flexEnd = "flex-end"
    case stretch = "stretch"
    case baseline = "baseline"
    case spaceBetween = "space-between"
    case spaceAround = "space-around"
    case spaceEvenly = "space-evenly"
}

// parity: core/src/lib/yoga.options.ts#BoxSizingString [status=implemented hash=df8ff05ea546]
public enum BoxSizingString: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case borderBox = "border-box"
    case contentBox = "content-box"
}

// parity: core/src/lib/yoga.options.ts#DimensionString [status=implemented hash=2b244bf4d1a2]
public enum DimensionString: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case width = "width"
    case height = "height"
}

// parity: core/src/lib/yoga.options.ts#DirectionString [status=implemented hash=c0e9cf4d21dc]
public enum DirectionString: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case inherit = "inherit"
    case ltr = "ltr"
    case rtl = "rtl"
}

// parity: core/src/lib/yoga.options.ts#DisplayString [status=implemented hash=2116b2780dcc]
public enum DisplayString: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case flex = "flex"
    case none = "none"
    case contents = "contents"
}

// parity: core/src/lib/yoga.options.ts#EdgeString [status=implemented hash=9b9fd8d886e0]
public enum EdgeString: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case left = "left"
    case top = "top"
    case right = "right"
    case bottom = "bottom"
    case start = "start"
    case end = "end"
    case horizontal = "horizontal"
    case vertical = "vertical"
    case all = "all"
}

// parity: core/src/lib/yoga.options.ts#FlexDirectionString [status=implemented hash=5fb70c6c7ad7]
public typealias FlexDirectionString = FlexDirection

// parity: core/src/lib/yoga.options.ts#GutterString [status=implemented hash=51e4d1165224]
public enum GutterString: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case column = "column"
    case row = "row"
    case all = "all"
}

// parity: core/src/lib/yoga.options.ts#JustifyString [status=implemented hash=58653b8ec128]
public enum JustifyString: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case flexStart = "flex-start"
    case center = "center"
    case flexEnd = "flex-end"
    case spaceBetween = "space-between"
    case spaceAround = "space-around"
    case spaceEvenly = "space-evenly"
}

// parity: core/src/lib/yoga.options.ts#LayoutModeString [status=implemented hash=e53bd1ae7a6d]
public enum LayoutModeString: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case flex = "flex"
    case list = "list"
}

// parity: core/src/lib/yoga.options.ts#LogLevelString [status=implemented hash=fa5e770a2807]
public enum LogLevelString: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case error = "error"
    case warn = "warn"
    case info = "info"
    case debug = "debug"
    case verbose = "verbose"
    case fatal = "fatal"
}

// parity: core/src/lib/yoga.options.ts#MeasureModeString [status=implemented hash=9bd10feff09c]
public enum MeasureModeString: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case undefined = "undefined"
    case exactly = "exactly"
    case atMost = "at-most"
}

// parity: core/src/lib/yoga.options.ts#OverflowString [status=implemented hash=9d7fab171033]
public enum OverflowString: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case visible = "visible"
    case hidden = "hidden"
    case scroll = "scroll"
}

// parity: core/src/lib/yoga.options.ts#PositionTypeString [status=implemented hash=01a40d9a77d6]
public enum PositionTypeString: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case `static` = "static"
    case relative = "relative"
    case absolute = "absolute"
}

// parity: core/src/lib/yoga.options.ts#UnitString [status=implemented hash=d7baab8e054c]
public enum UnitString: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case undefined = "undefined"
    case point = "point"
    case percent = "percent"
    case auto = "auto"
}

// parity: core/src/lib/yoga.options.ts#WrapString [status=implemented hash=e7139335a899]
public enum WrapString: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case noWrap = "no-wrap"
    case wrap = "wrap"
    case wrapReverse = "wrap-reverse"
}

// MARK: - Yoga Option Parsers

private func parseAlignment(_ value: String?, fallback: Align) -> Align {
    switch value?.lowercased() {
    case "auto": return .auto
    case "flex-start": return .flexStart
    case "center": return .center
    case "flex-end": return .flexEnd
    case "stretch": return .stretch
    case "baseline": return .baseline
    case "space-between": return .spaceBetween
    case "space-around": return .spaceAround
    case "space-evenly": return .spaceEvenly
    default: return fallback
    }
}

// parity: core/src/lib/yoga.options.ts#parseAlign [status=implemented hash=517cf36aaeb3]
public func parseAlign(_ value: String?) -> Align {
    parseAlignment(value, fallback: .auto)
}

// parity: core/src/lib/yoga.options.ts#parseAlignItems [status=implemented hash=3ac656358f74]
public func parseAlignItems(_ value: String?) -> Align {
    parseAlignment(value, fallback: .stretch)
}

// parity: core/src/lib/yoga.options.ts#parseAlignContent [status=implemented hash=c5707c81c55a]
public func parseAlignContent(_ value: String?) -> Align {
    parseAlignment(value, fallback: .flexStart)
}

// parity: core/src/lib/yoga.options.ts#parseBoxSizing [status=implemented hash=1c00885a654f]
public func parseBoxSizing(_ value: String?) -> BoxSizing {
    guard let value else { return .borderBox }
    switch value.lowercased() {
    case "border-box": return .borderBox
    case "content-box": return .contentBox
    default: return .borderBox
    }
}

// parity: core/src/lib/yoga.options.ts#parseDimension [status=implemented hash=f3f38617dae0]
public func parseDimension(_ value: String?) -> Dimension {
    guard let value else { return .width }
    switch value.lowercased() {
    case "width": return .width
    case "height": return .height
    default: return .width
    }
}

// parity: core/src/lib/yoga.options.ts#parseDirection [status=implemented hash=63681e06c923]
public func parseDirection(_ value: String?) -> Direction {
    guard let value else { return .ltr }
    switch value.lowercased() {
    case "inherit": return .inherit
    case "ltr": return .ltr
    case "rtl": return .rtl
    default: return .ltr
    }
}

// parity: core/src/lib/yoga.options.ts#parseDisplay [status=implemented hash=258cecf74094]
public func parseDisplay(_ value: String?) -> Display {
    guard let value else { return .flex }
    switch value.lowercased() {
    case "flex": return .flex
    case "none": return .none
    case "contents": return .contents
    default: return .flex
    }
}

// parity: core/src/lib/yoga.options.ts#parseEdge [status=implemented hash=bb4759fe8c9f]
public func parseEdge(_ value: String?) -> Edge {
    guard let value else { return .all }
    switch value.lowercased() {
    case "left": return .left
    case "top": return .top
    case "right": return .right
    case "bottom": return .bottom
    case "start": return .start
    case "end": return .end
    case "horizontal": return .horizontal
    case "vertical": return .vertical
    case "all": return .all
    default: return .all
    }
}

// parity: core/src/lib/yoga.options.ts#parseFlexDirection [status=implemented hash=8eeacf100cb5]
public func parseFlexDirection(_ value: String?) -> FlexDirection {
    guard let value else { return .column }
    switch value.lowercased() {
    case "column": return .column
    case "column-reverse": return .columnReverse
    case "row": return .row
    case "row-reverse": return .rowReverse
    default: return .column
    }
}

// parity: core/src/lib/yoga.options.ts#parseGutter [status=implemented hash=669ed8402079]
public func parseGutter(_ value: String?) -> Gutter {
    guard let value else { return .all }
    switch value.lowercased() {
    case "column": return .column
    case "row": return .row
    case "all": return .all
    default: return .all
    }
}

// parity: core/src/lib/yoga.options.ts#parseJustify [status=implemented hash=143ee65f1f0a]
public func parseJustify(_ value: String?) -> Justify {
    guard let value else { return .flexStart }
    switch value.lowercased() {
    case "flex-start": return .flexStart
    case "center": return .center
    case "flex-end": return .flexEnd
    case "space-between": return .spaceBetween
    case "space-around": return .spaceAround
    case "space-evenly": return .spaceEvenly
    default: return .flexStart
    }
}

// parity: core/src/lib/yoga.options.ts#parseLayoutMode [status=implemented hash=28c46d95f81b]
public func parseLayoutMode(_ value: String?) -> LayoutMode {
    value?.lowercased() == "list" ? .list : .flex
}

// parity: core/src/lib/yoga.options.ts#parseLogLevel [status=implemented hash=952a1422d65d]
public func parseLogLevel(_ value: String?) -> LogLevel {
    guard let value else { return .info }
    switch value.lowercased() {
    case "error": return .error
    case "warn": return .warn
    case "info": return .info
    case "debug": return .debug
    case "verbose": return .verbose
    case "fatal": return .fatal
    default: return .info
    }
}

// parity: core/src/lib/yoga.options.ts#parseMeasureMode [status=implemented hash=649b7fe9c00a]
public func parseMeasureMode(_ value: String?) -> MeasureMode {
    guard let value else { return .undefined }
    switch value.lowercased() {
    case "undefined": return .undefined
    case "exactly": return .exactly
    case "at-most": return .atMost
    default: return .undefined
    }
}

// parity: core/src/lib/yoga.options.ts#parseOverflow [status=implemented hash=841fdcc51c7d]
public func parseOverflow(_ value: String?) -> Overflow {
    guard let value else { return .visible }
    switch value.lowercased() {
    case "visible": return .visible
    case "hidden": return .hidden
    case "scroll": return .scroll
    default: return .visible
    }
}

// parity: core/src/lib/yoga.options.ts#parsePositionType [status=implemented hash=030baf94e6ca]
public func parsePositionType(_ value: String?) -> PositionType {
    guard let value else { return .relative }
    switch value.lowercased() {
    case "static": return .static
    case "relative": return .relative
    case "absolute": return .absolute
    default: return .static
    }
}

// parity: core/src/lib/yoga.options.ts#parseUnit [status=implemented hash=f0d3b13d6fed]
public func parseUnit(_ value: String?) -> Unit {
    guard let value else { return .point }
    switch value.lowercased() {
    case "undefined": return .undefined
    case "point": return .point
    case "percent": return .percent
    case "auto": return .auto
    default: return .point
    }
}

// parity: core/src/lib/yoga.options.ts#parseWrap [status=implemented hash=7869df5a8b5d]
public func parseWrap(_ value: String?) -> Wrap {
    guard let value else { return .noWrap }
    switch value.lowercased() {
    case "no-wrap": return .noWrap
    case "wrap": return .wrap
    case "wrap-reverse": return .wrapReverse
    default: return .noWrap
    }
}
