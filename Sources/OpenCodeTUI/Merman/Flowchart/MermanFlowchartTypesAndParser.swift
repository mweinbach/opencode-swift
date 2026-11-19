import Foundation
import OpenTUICore

extension Merman {
    // MARK: - Flowchart Types (`flowchart/types.ts`)

    // parity: merman/src/flowchart/types.ts#FlowchartDirection [status=implemented hash=6daebf7b6219]
    public enum FlowchartDirection: String, Equatable, Hashable, Sendable, Codable {
        case TB
        case TD
        case BT
        case LR
        case RL
    }

    // parity: merman/src/flowchart/types.ts#FlowchartNodeShape [status=implemented hash=b9147f10b3ab]
    public enum FlowchartNodeShape: String, Equatable, Hashable, Sendable, Codable {
        case box
        case rounded
        case database
        case decision
        case subroutine
    }

    // parity: merman/src/flowchart/types.ts#FlowchartEdgeStyle [status=implemented hash=4e1477c8fe43]
    public enum FlowchartEdgeStyle: String, Equatable, Hashable, Sendable, Codable {
        case thick
        case dashed
    }

    // parity: merman/src/flowchart/types.ts#FlowchartNode [status=implemented hash=ff2d595be87c]
    public struct FlowchartNode: Equatable, Hashable, Sendable, Codable {
        public var id: String
        public var label: String
        public var shape: FlowchartNodeShape

        public init(id: String, label: String, shape: FlowchartNodeShape) {
            self.id = id
            self.label = label
            self.shape = shape
        }
    }

    // parity: merman/src/flowchart/types.ts#FlowchartEdge [status=implemented hash=b4af9397d36a]
    public struct FlowchartEdge: Equatable, Hashable, Sendable, Codable {
        public var from: String
        public var to: String
        public var label: String
        public var style: FlowchartEdgeStyle?
        public var arrowhead: Bool?
        public var sourceArrowhead: Bool?
        public var orderOnly: Bool?

        public init(
            from: String,
            to: String,
            label: String = "",
            style: FlowchartEdgeStyle? = nil,
            arrowhead: Bool? = nil,
            sourceArrowhead: Bool? = nil,
            orderOnly: Bool? = nil
        ) {
            self.from = from
            self.to = to
            self.label = label
            self.style = style
            self.arrowhead = arrowhead
            self.sourceArrowhead = sourceArrowhead
            self.orderOnly = orderOnly
        }
    }

    // parity: merman/src/flowchart/types.ts#FlowchartSubgraph [status=implemented hash=7bff08928f35]
    public struct FlowchartSubgraph: Equatable, Hashable, Sendable, Codable {
        public var id: String
        public var label: String
        public var nodeIds: [String]
        public var parentId: String?
        public var direction: FlowchartDirection?

        public init(
            id: String,
            label: String,
            nodeIds: [String] = [],
            parentId: String? = nil,
            direction: FlowchartDirection? = nil
        ) {
            self.id = id
            self.label = label
            self.nodeIds = nodeIds
            self.parentId = parentId
            self.direction = direction
        }
    }

    // parity: merman/src/flowchart/types.ts#FlowchartDiagram [status=implemented hash=1628e5f26529]
    public struct FlowchartDiagram: Equatable, Hashable, Sendable, Codable {
        public var direction: FlowchartDirection
        public var nodes: [FlowchartNode]
        public var edges: [FlowchartEdge]
        public var subgraphs: [FlowchartSubgraph]?

        public init(
            direction: FlowchartDirection,
            nodes: [FlowchartNode],
            edges: [FlowchartEdge],
            subgraphs: [FlowchartSubgraph]? = nil
        ) {
            self.direction = direction
            self.nodes = nodes
            self.edges = edges
            self.subgraphs = subgraphs
        }
    }

    // parity: merman/src/flowchart/types.ts#FlowchartNodeSize [status=implemented hash=7dfb4ea1da1b]
    public struct FlowchartNodeSize: Equatable, Hashable, Sendable, Codable {
        public var width: Int
        public var height: Int
        public var lines: [String]

        public init(width: Int, height: Int, lines: [String]) {
            self.width = width
            self.height = height
            self.lines = lines
        }
    }

    // parity: merman/src/flowchart/types.ts#FlowchartNodeBounds [status=implemented hash=05c335966463]
    public struct FlowchartNodeBounds: Equatable, Hashable, Sendable, Codable {
        public var id: String
        public var width: Int
        public var height: Int
        public var lines: [String]
        public var left: Int
        public var top: Int
        public var centerX: Int
        public var centerY: Int

        public init(
            id: String,
            width: Int,
            height: Int,
            lines: [String],
            left: Int,
            top: Int,
            centerX: Int,
            centerY: Int
        ) {
            self.id = id
            self.width = width
            self.height = height
            self.lines = lines
            self.left = left
            self.top = top
            self.centerX = centerX
            self.centerY = centerY
        }

        public var diagramBounds: DiagramBounds {
            DiagramBounds(left: left, top: top, width: width, height: height, centerX: centerX, centerY: centerY)
        }
    }

    public enum FlowchartSubgraphLabelSide: String, Equatable, Hashable, Sendable, Codable {
        case top
        case bottom
    }

    // parity: merman/src/flowchart/types.ts#FlowchartSubgraphBounds [status=implemented hash=b3b97ad69139]
    public struct FlowchartSubgraphBounds: Equatable, Hashable, Sendable, Codable {
        public var id: String
        public var label: String
        public var labelSide: FlowchartSubgraphLabelSide
        public var left: Int
        public var top: Int
        public var width: Int
        public var height: Int
        public var centerX: Int
        public var centerY: Int

        public init(
            id: String,
            label: String,
            labelSide: FlowchartSubgraphLabelSide = .top,
            left: Int,
            top: Int,
            width: Int,
            height: Int,
            centerX: Int,
            centerY: Int
        ) {
            self.id = id
            self.label = label
            self.labelSide = labelSide
            self.left = left
            self.top = top
            self.width = width
            self.height = height
            self.centerX = centerX
            self.centerY = centerY
        }

        public var diagramBounds: DiagramBounds {
            DiagramBounds(left: left, top: top, width: width, height: height, centerX: centerX, centerY: centerY)
        }
    }

    // parity: merman/src/flowchart/types.ts#FlowchartEndpointBounds [status=implemented hash=4acfcc398694]
    public enum FlowchartEndpointBounds: Equatable, Hashable, Sendable, Codable {
        case node(FlowchartNodeBounds)
        case subgraph(FlowchartSubgraphBounds)

        public var id: String {
            switch self {
            case .node(let n): return n.id
            case .subgraph(let s): return s.id
            }
        }

        public var left: Int {
            switch self {
            case .node(let n): return n.left
            case .subgraph(let s): return s.left
            }
        }

        public var top: Int {
            switch self {
            case .node(let n): return n.top
            case .subgraph(let s): return s.top
            }
        }

        public var width: Int {
            switch self {
            case .node(let n): return n.width
            case .subgraph(let s): return s.width
            }
        }

        public var height: Int {
            switch self {
            case .node(let n): return n.height
            case .subgraph(let s): return s.height
            }
        }

        public var centerX: Int {
            switch self {
            case .node(let n): return n.centerX
            case .subgraph(let s): return s.centerX
            }
        }

        public var centerY: Int {
            switch self {
            case .node(let n): return n.centerY
            case .subgraph(let s): return s.centerY
            }
        }

        public var diagramBounds: DiagramBounds {
            DiagramBounds(left: left, top: top, width: width, height: height, centerX: centerX, centerY: centerY)
        }
    }

    // parity: merman/src/flowchart/types.ts#FlowchartPoint [status=implemented hash=13d9109a8bac]
    public typealias FlowchartPoint = DiagramPoint

    // parity: merman/src/flowchart/types.ts#FlowchartEdgeRoute [status=implemented hash=42e3a4515803]
    public struct FlowchartEdgeRoute: Equatable, Hashable, Sendable, Codable {
        public var edge: FlowchartEdge
        public var points: [FlowchartPoint]
        public var labelAxis: DiagramAxis?
        public var labelPoint: FlowchartPoint?

        public init(
            edge: FlowchartEdge,
            points: [FlowchartPoint],
            labelAxis: DiagramAxis? = nil,
            labelPoint: FlowchartPoint? = nil
        ) {
            self.edge = edge
            self.points = points
            self.labelAxis = labelAxis
            self.labelPoint = labelPoint
        }
    }

    // parity: merman/src/flowchart/types.ts#FlowchartEdgeDirection [status=implemented hash=e3cb2dfb5ab4]
    public typealias FlowchartEdgeDirection = DiagramDirection

    // MARK: - Flowchart Options (`flowchart/options.ts`)

    // parity: merman/src/flowchart/options.ts#FlowchartDiagramRenderOptions [status=implemented hash=a19fd7a649d5]
    public struct FlowchartDiagramRenderOptions: Equatable, Hashable, Sendable {
        public var compact: Bool?
        public var direction: FlowchartDirection?
        public var borderStyle: BorderStyle?
        public var minNodeGap: Int?
        public var minRankGap: Int?
        public var layoutMaxWidth: Int?

        public init(
            compact: Bool? = nil,
            direction: FlowchartDirection? = nil,
            borderStyle: BorderStyle? = nil,
            minNodeGap: Int? = nil,
            minRankGap: Int? = nil,
            layoutMaxWidth: Int? = nil
        ) {
            self.compact = compact
            self.direction = direction
            self.borderStyle = borderStyle
            self.minNodeGap = minNodeGap
            self.minRankGap = minRankGap
            self.layoutMaxWidth = layoutMaxWidth
        }
    }

    // MARK: - Flowchart Style (`flowchart/style.ts`)

    // parity: merman/src/flowchart/style.ts#FlowchartBaseCellStyle [status=implemented hash=305649fd5138]
    public enum FlowchartBaseCellStyle: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case node
        case nodeBorder
        case database
        case databaseBorder
        case edge
        case label
        case group
        case groupLabel
    }

    // parity: merman/src/flowchart/style.ts#FlowchartNodeEdgeFadeStyle [status=implemented hash=ad3e0e8cf692]
    public enum FlowchartNodeEdgeFadeStyle: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case nodeEdgeFade1, nodeEdgeFade2, nodeEdgeFade3, nodeEdgeFade4, nodeEdgeFade5
    }

    // parity: merman/src/flowchart/style.ts#FlowchartDatabaseEdgeFadeStyle [status=implemented hash=d8f515dfe27d]
    public enum FlowchartDatabaseEdgeFadeStyle: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case databaseEdgeFade1, databaseEdgeFade2, databaseEdgeFade3, databaseEdgeFade4, databaseEdgeFade5
    }

    // parity: merman/src/flowchart/style.ts#FlowchartEdgeFadeStyle [status=implemented hash=4ad83caed554]
    public enum FlowchartEdgeFadeStyle: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case nodeEdgeFade1, nodeEdgeFade2, nodeEdgeFade3, nodeEdgeFade4, nodeEdgeFade5
        case databaseEdgeFade1, databaseEdgeFade2, databaseEdgeFade3, databaseEdgeFade4, databaseEdgeFade5
    }

    // parity: merman/src/flowchart/style.ts#FlowchartCellStyle [status=implemented hash=a149bbf71a50]
    public enum FlowchartCellStyle: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case node
        case nodeBorder
        case database
        case databaseBorder
        case edge
        case label
        case group
        case groupLabel
        case nodeEdgeFade1, nodeEdgeFade2, nodeEdgeFade3, nodeEdgeFade4, nodeEdgeFade5
        case databaseEdgeFade1, databaseEdgeFade2, databaseEdgeFade3, databaseEdgeFade4, databaseEdgeFade5

        static func fromFade(_ fade: FlowchartEdgeFadeStyle) -> FlowchartCellStyle {
            FlowchartCellStyle(rawValue: fade.rawValue)!
        }
    }

    // parity: merman/src/flowchart/style.ts#FlowchartCellMetadata [status=implemented hash=90099a7371c1]
    public struct FlowchartCellMetadata: Equatable, Hashable, Sendable, Codable {
        public var attributes: UInt32?

        public init(attributes: UInt32? = nil) {
            self.attributes = attributes
        }
    }

    // parity: merman/src/flowchart/style.ts#FlowchartGrid [status=implemented hash=91dcb7bf8358]
    public typealias FlowchartGrid = DiagramCanvas<FlowchartCellStyle, FlowchartCellMetadata>

    // parity: merman/src/flowchart/style.ts#FlowchartStyleColors [status=implemented hash=b0bd23f23434]
    public typealias FlowchartStyleColors = [FlowchartCellStyle: RGBA]

    // parity: merman/src/flowchart/style.ts#FlowchartStyleBackgroundColors [status=implemented hash=79effbe672a4]
    public typealias FlowchartStyleBackgroundColors = [FlowchartCellStyle: RGBA]

    // parity: merman/src/flowchart/style.ts#DEFAULT_THEME_RGB [status=implemented hash=ce4bb5a83ceb]
    public static let DEFAULT_THEME_RGB: [FlowchartBaseCellStyle: DiagramRgb] = [
        .node: (228, 239, 232),
        .nodeBorder: (141, 163, 151),
        .database: (228, 239, 232),
        .databaseBorder: (141, 163, 151),
        .edge: (134, 225, 200),
        .label: (134, 225, 200),
        .group: (76, 99, 89),
        .groupLabel: (76, 99, 89),
    ]

    // parity: merman/src/flowchart/style.ts#NODE_EDGE_FADE_STYLES [status=implemented hash=0c43bd8343c9]
    public static let NODE_EDGE_FADE_STYLES: [FlowchartCellStyle] = [
        .nodeEdgeFade1, .nodeEdgeFade2, .nodeEdgeFade3, .nodeEdgeFade4, .nodeEdgeFade5,
    ]

    // parity: merman/src/flowchart/style.ts#DATABASE_EDGE_FADE_STYLES [status=implemented hash=e928f590b444]
    public static let DATABASE_EDGE_FADE_STYLES: [FlowchartCellStyle] = [
        .databaseEdgeFade1, .databaseEdgeFade2, .databaseEdgeFade3, .databaseEdgeFade4, .databaseEdgeFade5,
    ]

    // parity: merman/src/flowchart/style.ts#resolveFlowchartStyleColors [status=implemented hash=dfba75c50f02]
    public static func resolveFlowchartStyleColors(
        _ colors: [FlowchartCellStyle: RGBA?] = [:]
    ) -> FlowchartStyleColors {
        let node = (colors[.node] ?? nil) ?? rgba(DEFAULT_THEME_RGB[.node]!)
        let nodeBorder = (colors[.nodeBorder] ?? nil) ?? rgba(DEFAULT_THEME_RGB[.nodeBorder]!)
        let database = (colors[.database] ?? nil) ?? rgba(DEFAULT_THEME_RGB[.database]!)
        let databaseBorder = (colors[.databaseBorder] ?? nil) ?? rgba(DEFAULT_THEME_RGB[.databaseBorder]!)
        let edge = (colors[.edge] ?? nil) ?? rgba(DEFAULT_THEME_RGB[.edge]!)
        var resolved: FlowchartStyleColors = [
            .node: node,
            .nodeBorder: nodeBorder,
            .database: database,
            .databaseBorder: databaseBorder,
            .edge: edge,
            .label: (colors[.label] ?? nil) ?? rgba(DEFAULT_THEME_RGB[.label]!),
            .group: (colors[.group] ?? nil) ?? rgba(DEFAULT_THEME_RGB[.group]!),
            .groupLabel: (colors[.groupLabel] ?? nil) ?? (colors[.group] ?? nil) ?? rgba(DEFAULT_THEME_RGB[.groupLabel]!),
        ]
        for (k, v) in createColorRampTheme(NODE_EDGE_FADE_STYLES, from: nodeBorder, to: edge) {
            resolved[k] = v
        }
        for (k, v) in createColorRampTheme(DATABASE_EDGE_FADE_STYLES, from: databaseBorder, to: edge) {
            resolved[k] = v
        }
        return resolved
    }

    // parity: merman/src/flowchart/style.ts#renderGridStyledText [status=implemented hash=e9507ba1f39d]
    public static func renderGridStyledText(
        _ grid: FlowchartGrid,
        colors: FlowchartStyleColors,
        backgrounds: FlowchartStyleBackgroundColors? = nil
    ) -> StyledText {
        renderDiagramGridStyledTextByStyle(
            grid,
            foregrounds: colors,
            backgrounds: backgrounds,
            options: DiagramCanvasRunOptions(
                key: { cell in
                    [AnyHashable(cell.style), AnyHashable(cell.metadata?.attributes)]
                },
                trimTop: true,
                trimBottom: true
            ),
            attributes: { run in run.cell.metadata?.attributes }
        )
    }

    // MARK: - Flowchart Labels (`flowchart/labels.ts`)

    private static let fcLabelBusClearance = 3
    private static let fcLabelNodeClearance = 2
    private static let fcLabelLineClearance = 2
    private static let fcLabelTerminalClearance = 1

    // parity: merman/src/flowchart/labels.ts#FlowchartEdgeLabelLayout [status=implemented hash=0d494b5a8596]
    public struct FlowchartEdgeLabelLayout: Equatable, Hashable, Sendable, Codable {
        public var lines: [String]
        public var point: FlowchartPoint
        public var width: Int
        public var height: Int

        public init(lines: [String], point: FlowchartPoint, width: Int, height: Int) {
            self.lines = lines
            self.point = point
            self.width = width
            self.height = height
        }
    }

    // parity: merman/src/flowchart/labels.ts#flowchartLabelText [status=implemented hash=8d326c1d1612]
    public static func flowchartLabelText(_ label: String) -> String {
        padDiagramLabelLine(label)
    }

    // parity: merman/src/flowchart/labels.ts#flowchartLabelWidth [status=implemented hash=d0bf2efdbad8]
    public static func flowchartLabelWidth(_ label: String, measure: (String) -> Int = diagramTextWidth) -> Int {
        measureDiagramLabelWidth(label, measure: measure)
    }

    private static func fcMinimumInlineLabelLength(_ labelWidth: Int) -> Int {
        labelWidth + fcLabelLineClearance * 2 - 1
    }

    // parity: merman/src/flowchart/labels.ts#flowchartHorizontalLabelRankGap [status=implemented hash=5d882b36cbae]
    public static func flowchartHorizontalLabelRankGap(_ labelWidth: Int) -> Int {
        fcMinimumInlineLabelLength(labelWidth) + fcLabelBusClearance + 1
    }

    // parity: merman/src/flowchart/labels.ts#flowchartVerticalBranchLabelGap [status=implemented hash=fbbf7ec3bae4]
    public static func flowchartVerticalBranchLabelGap(_ labelWidth: Int) -> Int {
        fcMinimumInlineLabelLength(labelWidth) + fcLabelBusClearance + fcLabelNodeClearance
    }

    private static func fcInlineLabelSlot(_ segment: DiagramSegment, labelWidth: Int) -> (x: Int, fits: Bool) {
        let slot = insetSpan(segmentSpan(segment), amount: fcLabelLineClearance)
        return (centeredSpanStart(slot, width: labelWidth), spanCapacity(slot) >= labelWidth)
    }

    private static func fcSegmentLabelPoint(_ segment: DiagramSegment, labelWidth: Int, labelHeight: Int) -> FlowchartPoint {
        if segment.axis == .x {
            let slot = fcInlineLabelSlot(segment, labelWidth: labelWidth)
            if labelHeight == 1 && slot.fits {
                return point(slot.x, segment.from.y)
            }
            if labelHeight > 1 {
                return shiftPoint(point(slot.x, segment.from.y), direction: .up, distance: labelHeight)
            }
            return clampPoint(shiftPoint(
                shiftPoint(segment.from, direction: segment.direction, distance: fcLabelLineClearance),
                direction: .up,
                distance: labelHeight
            ))
        }
        let slot = insetSpan(segmentSpan(segment), amount: fcLabelTerminalClearance)
        if spanCapacity(slot) >= labelHeight {
            return clampPoint(point(segment.from.x + 1, centeredSpanStart(slot, width: labelHeight)))
        }
        let center = shiftPoint(pointOnSegment(segment, coordinateValue: midpoint(segmentSpan(segment))), direction: .right)
        return clampPoint(shiftPoint(center, direction: .up, distance: floorDiv(labelHeight - 1, 2)))
    }

    private static func fcBestLabelSegment(
        _ points: [FlowchartPoint],
        labelWidth: Int,
        preferredAxis: DiagramAxis? = nil,
        preferredSegment: Int? = nil
    ) -> DiagramSegment? {
        var segments: [DiagramSegment] = []
        if points.count >= 2 {
            for index in 1..<points.count {
                if let seg = segmentBetween(points[index - 1], points[index]) {
                    segments.append(seg)
                }
            }
        }
        if let preferredSegment, preferredSegment >= 0, preferredSegment < segments.count {
            return segments[preferredSegment]
        }
        if let preferredAxis, let found = segments.first(where: { $0.axis == preferredAxis }) {
            return found
        }
        var roomyHorizontal: DiagramSegment?
        var verticalBus: DiagramSegment?
        var longest: DiagramSegment?
        for seg in segments {
            if roomyHorizontal == nil && seg.axis == .x && fcInlineLabelSlot(seg, labelWidth: labelWidth).fits {
                roomyHorizontal = seg
            }
            if verticalBus == nil && seg.axis == .y {
                verticalBus = seg
            }
            if longest == nil || seg.length > longest!.length {
                longest = seg
            }
        }
        return roomyHorizontal ?? verticalBus ?? longest
    }

    private static func fcLabelPoint(
        _ points: [FlowchartPoint],
        labelWidth: Int,
        labelHeight: Int,
        preferredAxis: DiagramAxis? = nil,
        preferredSegment: Int? = nil
    ) -> FlowchartPoint {
        if let seg = fcBestLabelSegment(points, labelWidth: labelWidth, preferredAxis: preferredAxis, preferredSegment: preferredSegment) {
            return fcSegmentLabelPoint(seg, labelWidth: labelWidth, labelHeight: labelHeight)
        }
        return points.first ?? point(0, 0)
    }

    // parity: merman/src/flowchart/labels.ts#flowchartEdgeLabelLayout [status=implemented hash=714d3d223ceb]
    public static func flowchartEdgeLabelLayout(
        _ points: [FlowchartPoint],
        label: String,
        measure: (String) -> Int = diagramTextWidth,
        preferredAxis: DiagramAxis? = nil,
        preferredSegment: Int? = nil
    ) -> FlowchartEdgeLabelLayout {
        let lines = splitDiagramLines(label).map(flowchartLabelText)
        let width = flowchartLabelWidth(label, measure: measure)
        let height = lines.count
        return FlowchartEdgeLabelLayout(
            lines: lines,
            point: fcLabelPoint(points, labelWidth: width, labelHeight: height, preferredAxis: preferredAxis, preferredSegment: preferredSegment),
            width: width,
            height: height
        )
    }

    // parity: merman/src/flowchart/labels.ts#flowchartRouteLabelLayout [status=implemented hash=4bd80123c7b0]
    public static func flowchartRouteLabelLayout(
        _ route: FlowchartEdgeRoute,
        measure: (String) -> Int = diagramTextWidth
    ) -> FlowchartEdgeLabelLayout {
        let lines = splitDiagramLines(route.edge.label).map(flowchartLabelText)
        let width = flowchartLabelWidth(route.edge.label, measure: measure)
        let height = lines.count
        return FlowchartEdgeLabelLayout(
            lines: lines,
            point: route.labelPoint ?? fcLabelPoint(route.points, labelWidth: width, labelHeight: height, preferredAxis: route.labelAxis),
            width: width,
            height: height
        )
    }

    // MARK: - Flowchart Parser (`flowchart/parser.ts`)

    private static let fcHeaderPattern = #"^(flowchart|graph)(?:\s+(TB|TD|BT|LR|RL))?$"#
    private static let fcIdPattern = #"[A-Za-z_][A-Za-z0-9_.-]*"#
    private static let fcSubgraphPattern = #"^subgraph\s+(.+)$"#
    private static let fcSubgraphWithLabelPattern = #"^([A-Za-z_][A-Za-z0-9_.-]*)\s*\[(.+)\]$"#
    private static let fcSubgraphDirectionPattern = #"^direction\s+(TB|TD|BT|LR|RL)$"#
    private static let fcIgnoredPresentationPattern = #"^(?:classDef|class|style|linkStyle)\b"#
    private static let fcDatabaseNodePattern = #"^([A-Za-z_][A-Za-z0-9_.-]*)\[\((.+)\)\]$"#
    private static let fcSubroutineNodePattern = #"^([A-Za-z_][A-Za-z0-9_.-]*)\[\[(.+)\]\]$"#
    private static let fcRoundedBracketNodePattern = #"^([A-Za-z_][A-Za-z0-9_.-]*)\(\[(.+)\]\)$"#
    private static let fcRoundedNodePattern = #"^([A-Za-z_][A-Za-z0-9_.-]*)\((.+)\)$"#
    private static let fcDecisionNodePattern = #"^([A-Za-z_][A-Za-z0-9_.-]*)\{(.+)\}$"#
    private static let fcBoxNodePattern = #"^([A-Za-z_][A-Za-z0-9_.-]*)\[(.+)\]$"#
    private static let fcIdOnlyPattern = #"^[A-Za-z_][A-Za-z0-9_.-]*$"#
    private static let fcExplicitShapePattern = #"^[A-Za-z_][A-Za-z0-9_.-]*(?:\[|\(|\{)"#
    private static let fcCircleNodePattern = #"^[A-Za-z_][A-Za-z0-9_.-]*\(\(.+\)\)$"#
    private static let fcEdgeOperatorPattern =
        #"(-\.(?!->)(.+?)\.(?:->|-))|(--|==|-\.)\s+(.+?)\s+(-->|==>|\.->|-\.->|\.-)|(<-->|-->|==>|-\.->|---|~~~)\s*(?:\|([^|]*)\|\s*)?"#
    private static let fcMaxLineLength = 10_000

    private static func fcNormalizeDirection(_ value: String?) -> FlowchartDirection {
        guard let upper = value?.uppercased(), let dir = FlowchartDirection(rawValue: upper) else {
            return .TD
        }
        return dir
    }

    private static func fcNormalizeSubgraphId(_ value: String, index: Int) -> String {
        let stripped = stripMermaidQuotes(value)
        return regexTest(fcIdOnlyPattern, in: stripped) ? stripped : "subgraph_\(index + 1)"
    }

    private static func fcParseSubgraphToken(_ token: String, index: Int) -> (id: String, label: String) {
        var trimmed = jsTrim(token)
        trimmed = regexReplace(#"\s*:::.*$"#, in: trimmed, with: "")
        if trimmed.hasSuffix(";") { trimmed = String(trimmed.dropLast()) }
        if let withLabel = regexFirstMatch(fcSubgraphWithLabelPattern, in: trimmed) {
            return (withLabel[1] ?? "", stripMermaidQuotes(withLabel[2] ?? ""))
        }
        return (fcNormalizeSubgraphId(trimmed, index: index), stripMermaidQuotes(trimmed))
    }

    private static func fcStripNodeToken(_ token: String) -> String {
        var s = regexReplace(#"\s*:::.*$"#, in: token, with: "")
        if s.hasSuffix(";") { s = String(s.dropLast()) }
        return jsTrim(s)
    }

    private static func fcParseNodeToken(_ token: String) -> FlowchartNode {
        var trimmed = jsTrim(token)
        if trimmed.hasSuffix(";") { trimmed = String(trimmed.dropLast()) }
        if let m = regexFirstMatch(fcDatabaseNodePattern, in: trimmed) {
            return FlowchartNode(id: m[1] ?? "", label: stripMermaidQuotes(m[2] ?? ""), shape: .database)
        }
        if let m = regexFirstMatch(fcSubroutineNodePattern, in: trimmed) {
            return FlowchartNode(id: m[1] ?? "", label: stripMermaidQuotes(m[2] ?? ""), shape: .subroutine)
        }
        if let m = regexFirstMatch(fcRoundedBracketNodePattern, in: trimmed) {
            return FlowchartNode(id: m[1] ?? "", label: stripMermaidQuotes(m[2] ?? ""), shape: .rounded)
        }
        if let m = regexFirstMatch(fcRoundedNodePattern, in: trimmed) {
            return FlowchartNode(id: m[1] ?? "", label: stripMermaidQuotes(m[2] ?? ""), shape: .rounded)
        }
        if let m = regexFirstMatch(fcDecisionNodePattern, in: trimmed) {
            return FlowchartNode(id: m[1] ?? "", label: stripMermaidQuotes(m[2] ?? ""), shape: .decision)
        }
        if let m = regexFirstMatch(fcBoxNodePattern, in: trimmed) {
            return FlowchartNode(id: m[1] ?? "", label: stripMermaidQuotes(m[2] ?? ""), shape: .box)
        }
        return FlowchartNode(id: trimmed, label: trimmed, shape: .box)
    }

    private static func fcIsSupportedNodeToken(_ token: String) -> Bool {
        let trimmed = fcStripNodeToken(token)
        if regexTest(fcCircleNodePattern, in: trimmed) { return false }
        return regexTest(fcIdOnlyPattern, in: trimmed)
            || regexTest(fcDatabaseNodePattern, in: trimmed)
            || regexTest(fcSubroutineNodePattern, in: trimmed)
            || regexTest(fcRoundedBracketNodePattern, in: trimmed)
            || regexTest(fcRoundedNodePattern, in: trimmed)
            || regexTest(fcDecisionNodePattern, in: trimmed)
            || regexTest(fcBoxNodePattern, in: trimmed)
    }

    private static func fcHasExplicitNodeShape(_ token: String) -> Bool {
        regexTest(fcExplicitShapePattern, in: jsTrim(token))
    }

    private static func fcSplitNodeGroup(_ token: String) -> [String] {
        var groups: [String] = []
        var stack: [Character] = []
        var quoted = false
        let chars = Array(token)
        var start = 0
        let closes: [Character: Character] = ["[": "]", "(": ")", "{": "}"]
        for index in 0..<chars.count {
            let ch = chars[index]
            if quoted {
                if ch == "\"" && (index == 0 || chars[index - 1] != "\\") { quoted = false }
                continue
            }
            if ch == "\"" { quoted = true; continue }
            if closes[ch] != nil { stack.append(ch); continue }
            if let top = stack.last, ch == closes[top] { stack.removeLast(); continue }
            if stack.isEmpty && ch == "&" {
                groups.append(String(chars[start..<index]))
                start = index + 1
            }
        }
        groups.append(String(chars[start...]))
        return groups
    }

    private static func fcMaskNodeLabelOperators(_ line: String) -> String {
        var chars = Array(line)
        var stack: [Character] = []
        var quoted = false
        let closes: [Character: Character] = ["[": "]", "(": ")", "{": "}"]
        let maskSet: Set<Character> = ["<", ">", "=", ".", "-"]
        for index in 0..<chars.count {
            let ch = chars[index]
            if quoted {
                if ch == "\"" && (index == 0 || chars[index - 1] != "\\") { quoted = false }
                else if maskSet.contains(ch) { chars[index] = " " }
                continue
            }
            if ch == "\"" { quoted = true; continue }
            if closes[ch] != nil { stack.append(ch); continue }
            if let top = stack.last, ch == closes[top] { stack.removeLast(); continue }
            if !stack.isEmpty && maskSet.contains(ch) { chars[index] = " " }
        }
        return String(chars)
    }

    private static func fcHasInternalStatementSeparator(_ line: String) -> Bool {
        var stack: [Character] = []
        var quoted = false
        var edgeLabel = false
        let closes: [Character: Character] = ["[": "]", "(": ")", "{": "}"]
        let trimmedEnd = trimTrailingWhitespace(line)
        let finalIndex = trimmedEnd.count - 1
        let chars = Array(line)
        for index in 0..<chars.count {
            let ch = chars[index]
            if quoted {
                if ch == "\"" && (index == 0 || chars[index - 1] != "\\") { quoted = false }
                continue
            }
            if ch == "\"" { quoted = true; continue }
            if closes[ch] != nil { stack.append(ch); continue }
            if let top = stack.last, ch == closes[top] { stack.removeLast(); continue }
            if stack.isEmpty && ch == "|" { edgeLabel.toggle(); continue }
            if ch == ";" && index < finalIndex && stack.isEmpty && !edgeLabel { return true }
        }
        return false
    }

    private struct FcParsedEdgeOperator {
        let utf16Start: Int
        let utf16End: Int
        let label: String
        let style: FlowchartEdgeStyle?
        let arrowhead: Bool
        let sourceArrowhead: Bool
        let orderOnly: Bool
    }

    private static func fcEdgeStyleFromArrow(_ arrows: String...) -> FlowchartEdgeStyle? {
        if arrows.contains(where: { $0.contains("==") }) { return .thick }
        if arrows.contains(where: { $0.contains(".") }) { return .dashed }
        return nil
    }

    private static func fcParseEdgeOperators(_ line: String) -> [FcParsedEdgeOperator] {
        let masked = fcMaskNodeLabelOperators(line)
        guard let rx = try? NSRegularExpression(pattern: fcEdgeOperatorPattern) else { return [] }
        let nsMasked = masked as NSString
        let nsLine = line as NSString
        let matches = rx.matches(in: masked, options: [], range: NSRange(location: 0, length: nsMasked.length))
        var out: [FcParsedEdgeOperator] = []
        out.reserveCapacity(matches.count)
        for match in matches {
            func group(_ i: Int) -> String? {
                guard i < match.numberOfRanges else { return nil }
                let r = match.range(at: i)
                return r.location == NSNotFound ? nil : nsMasked.substring(with: r)
            }
            let inlineDashed = group(1)
            let startArrow = inlineDashed ?? group(3) ?? group(6) ?? ""
            let endArrow = inlineDashed ?? group(5) ?? group(6) ?? ""
            let labelGroup: Int?
            if let g2 = group(2), !g2.isEmpty { labelGroup = 2 }
            else if let g4 = group(4), !g4.isEmpty { labelGroup = 4 }
            else if let g7 = group(7), !g7.isEmpty { labelGroup = 7 }
            else { labelGroup = nil }
            let rawLabel: String
            if let lg = labelGroup {
                let r = match.range(at: lg)
                rawLabel = r.location == NSNotFound ? "" : nsLine.substring(with: r)
            } else {
                rawLabel = ""
            }
            out.append(FcParsedEdgeOperator(
                utf16Start: match.range.location,
                utf16End: match.range.location + match.range.length,
                label: stripMermaidQuotes(rawLabel),
                style: fcEdgeStyleFromArrow(startArrow, endArrow),
                arrowhead: endArrow == "~~~" || endArrow.hasSuffix(">"),
                sourceArrowhead: startArrow.hasPrefix("<"),
                orderOnly: endArrow == "~~~"
            ))
        }
        return out
    }

    private static func fcResolveSubgraphEndpoints(
        nodeOrder: inout [String],
        nodesById: inout [String: FlowchartNode],
        edges: [FlowchartEdge],
        subgraphs: inout [FlowchartSubgraph],
        explicitShapeIds: Set<String>,
        referencedInOpenSubgraphs: [String: Set<String>]
    ) {
        var resolved = Set<String>()
        func descendantsOf(_ subgraphId: String) -> Set<String> {
            var ids = Set<String>()
            for child in subgraphs where child.parentId == subgraphId {
                ids.insert(child.id)
                ids.formUnion(descendantsOf(child.id))
            }
            return ids
        }
        func membersOf(_ subgraphId: String, descendants: Set<String>) -> Set<String> {
            var ids = Set<String>()
            for candidate in subgraphs where candidate.id == subgraphId || descendants.contains(candidate.id) {
                for nodeId in candidate.nodeIds {
                    if nodeId == subgraphId || descendants.contains(nodeId) || resolved.contains(nodeId) { continue }
                    ids.insert(nodeId)
                }
            }
            return ids
        }

        for idx in stride(from: subgraphs.count - 1, through: 0, by: -1) {
            subgraphs[idx].nodeIds = subgraphs[idx].nodeIds.filter { !resolved.contains($0) }
            let subId = subgraphs[idx].id
            let descendants = descendantsOf(subId)
            let members = membersOf(subId, descendants: descendants)
            let linksSelfOrDescendant = edges.contains { edge in
                (edge.from == subId && (edge.to == subId || members.contains(edge.to) || descendants.contains(edge.to)))
                    || (edge.to == subId && (members.contains(edge.from) || descendants.contains(edge.from)))
            }
            if explicitShapeIds.contains(subId)
                || (referencedInOpenSubgraphs[subId]?.contains(subId) ?? false)
                || members.isEmpty
                || linksSelfOrDescendant
            {
                continue
            }
            resolved.insert(subId)
            nodesById.removeValue(forKey: subId)
            nodeOrder.removeAll { $0 == subId }
        }

        for idx in 0..<subgraphs.count {
            subgraphs[idx].nodeIds = subgraphs[idx].nodeIds.filter { !resolved.contains($0) }
        }
    }

    // parity: merman/src/flowchart/parser.ts#isMermaidFlowchartDiagram [status=implemented hash=c90bd034cc3c]
    public static func isMermaidFlowchartDiagram(_ content: String) -> Bool {
        regexTest(fcHeaderPattern, in: firstMeaningfulMermaidLine(content) ?? "", options: [.caseInsensitive])
    }

    // parity: merman/src/flowchart/parser.ts#parseMermaidFlowchartDiagram [status=implemented hash=1f38fa4f6034]
    public static func parseMermaidFlowchartDiagram(_ content: String) throws -> FlowchartDiagram {
        var nodeOrder: [String] = []
        var nodesById: [String: FlowchartNode] = [:]
        var edges: [FlowchartEdge] = []
        var subgraphs: [FlowchartSubgraph] = []
        var subgraphStack: [(index: Int, lineNumber: Int, sourceLine: String)] = []
        var explicitShapeIds = Set<String>()
        var referencedInOpenSubgraphs: [String: Set<String>] = [:]
        var direction: FlowchartDirection = .TD

        func ensureNode(_ token: String) -> FlowchartNode {
            let parsed = fcParseNodeToken(token)
            if var existing = nodesById[parsed.id] {
                if fcHasExplicitNodeShape(token) {
                    existing.label = parsed.label
                    existing.shape = parsed.shape
                    nodesById[parsed.id] = existing
                }
                return existing
            }
            nodeOrder.append(parsed.id)
            nodesById[parsed.id] = parsed
            return parsed
        }

        func trackNodeToken(_ stripped: String) -> String {
            let node = ensureNode(stripped)
            if fcHasExplicitNodeShape(stripped) {
                explicitShapeIds.insert(node.id)
            }
            for open in subgraphStack {
                referencedInOpenSubgraphs[node.id, default: []].insert(subgraphs[open.index].id)
            }
            return node.id
        }

        func addNodeToCurrentSubgraph(_ nodeId: String) {
            guard let topIdx = subgraphStack.last?.index else { return }
            if !subgraphs[topIdx].nodeIds.contains(nodeId) {
                subgraphs[topIdx].nodeIds.append(nodeId)
            }
        }

        for source in meaningfulNumberedMermaidLines(content) {
            let line = source.text
            if line.utf16.count > fcMaxLineLength {
                throw MermaidSyntaxError(kind: .flowchart, lineNumber: source.lineNumber, sourceLine: line, reason: "Flowchart statement is too long")
            }
            if fcHasInternalStatementSeparator(line) {
                throw MermaidSyntaxError(kind: .flowchart, lineNumber: source.lineNumber, sourceLine: line)
            }
            if let header = regexFirstMatch(fcHeaderPattern, in: line, options: [.caseInsensitive]) {
                direction = fcNormalizeDirection(header[2])
                continue
            }
            if regexTest(fcIgnoredPresentationPattern, in: line, options: [.caseInsensitive]) {
                continue
            }
            if let subMatch = regexFirstMatch(fcSubgraphPattern, in: line, options: [.caseInsensitive]) {
                let parsed = fcParseSubgraphToken(subMatch[1] ?? "", index: subgraphs.count)
                let parentId = subgraphStack.last.map { subgraphs[$0.index].id }
                let sub = FlowchartSubgraph(id: parsed.id, label: parsed.label, nodeIds: [], parentId: parentId)
                let idx = subgraphs.count
                subgraphs.append(sub)
                subgraphStack.append((index: idx, lineNumber: source.lineNumber, sourceLine: line))
                continue
            }
            if regexTest(#"^end$"#, in: line, options: [.caseInsensitive]) {
                if subgraphStack.isEmpty {
                    throw MermaidSyntaxError(
                        kind: .flowchart,
                        lineNumber: source.lineNumber,
                        sourceLine: line,
                        reason: "Unexpected \"end\" without an open subgraph"
                    )
                }
                _ = subgraphStack.popLast()
                continue
            }
            if let subDir = regexFirstMatch(fcSubgraphDirectionPattern, in: line, options: [.caseInsensitive]) {
                guard let topIdx = subgraphStack.last?.index else {
                    throw MermaidSyntaxError(
                        kind: .flowchart,
                        lineNumber: source.lineNumber,
                        sourceLine: line,
                        reason: "A \"direction\" statement requires an open subgraph"
                    )
                }
                subgraphs[topIdx].direction = fcNormalizeDirection(subDir[1])
                continue
            }

            let edgeOps = fcParseEdgeOperators(line)
            if !edgeOps.isEmpty {
                let nsLine = line as NSString
                var rawGroups: [String] = [nsLine.substring(with: NSRange(location: 0, length: edgeOps[0].utf16Start))]
                for i in 0..<edgeOps.count {
                    let start = edgeOps[i].utf16End
                    let end = (i + 1 < edgeOps.count) ? edgeOps[i + 1].utf16Start : nsLine.length
                    rawGroups.append(nsLine.substring(with: NSRange(location: start, length: max(0, end - start))))
                }
                let nodeGroups = rawGroups.map { fcSplitNodeGroup($0).map(fcStripNodeToken) }
                if nodeGroups.allSatisfy({ group in group.allSatisfy { !$0.isEmpty } }) {
                    if nodeGroups.contains(where: { group in group.contains(where: { !fcIsSupportedNodeToken($0) }) }) {
                        throw MermaidSyntaxError(kind: .flowchart, lineNumber: source.lineNumber, sourceLine: line)
                    }
                    let chainNodeIds = nodeGroups.map { $0.map(trackNodeToken) }
                    for nodeId in chainNodeIds.joined() {
                        if nodesById[nodeId] != nil {
                            addNodeToCurrentSubgraph(nodeId)
                        }
                    }
                    for i in 0..<edgeOps.count {
                        let op = edgeOps[i]
                        for from in chainNodeIds[i] {
                            for to in chainNodeIds[i + 1] {
                                edges.append(FlowchartEdge(
                                    from: from,
                                    to: to,
                                    label: op.label,
                                    style: op.style,
                                    arrowhead: op.arrowhead ? nil : false,
                                    sourceArrowhead: op.sourceArrowhead ? true : nil,
                                    orderOnly: op.orderOnly ? true : nil
                                ))
                            }
                        }
                    }
                    continue
                }
            }

            let nodeGroup = fcSplitNodeGroup(line)
            if nodeGroup.allSatisfy(fcIsSupportedNodeToken) {
                for token in nodeGroup {
                    addNodeToCurrentSubgraph(trackNodeToken(fcStripNodeToken(token)))
                }
                continue
            }

            throw MermaidSyntaxError(kind: .flowchart, lineNumber: source.lineNumber, sourceLine: line)
        }

        if let unclosed = subgraphStack.last {
            throw MermaidSyntaxError(
                kind: .flowchart,
                lineNumber: unclosed.lineNumber,
                sourceLine: unclosed.sourceLine,
                reason: "Unclosed subgraph; expected \"end\""
            )
        }

        fcResolveSubgraphEndpoints(
            nodeOrder: &nodeOrder,
            nodesById: &nodesById,
            edges: edges,
            subgraphs: &subgraphs,
            explicitShapeIds: explicitShapeIds,
            referencedInOpenSubgraphs: referencedInOpenSubgraphs
        )
        let orderedNodes = nodeOrder.compactMap { nodesById[$0] }
        return FlowchartDiagram(direction: direction, nodes: orderedNodes, edges: edges, subgraphs: subgraphs)
    }
}
