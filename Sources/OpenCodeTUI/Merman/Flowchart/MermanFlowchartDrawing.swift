import OpenTUICore

extension Merman {
    // MARK: - Flowchart Drawing (`flowchart/drawing.ts`)

    // parity: merman/src/flowchart/drawing.ts#DEFAULT_BORDER_STYLE [status=implemented hash=1faa90db78f9]
    public static let DEFAULT_BORDER_STYLE: BorderStyle = .rounded

    private static func fcMergeCell(
        _ existing: DiagramCanvasCell<FlowchartCellStyle, FlowchartCellMetadata>,
        _ incoming: DiagramCanvasCell<FlowchartCellStyle, FlowchartCellMetadata>
    ) -> DiagramCanvasCell<FlowchartCellStyle, FlowchartCellMetadata> {
        if incoming.style != .edge { return incoming }
        if existing.style == .label { return existing }
        if incoming.char == " " { return existing }
        if existing.style != .edge || existing.char == " " { return incoming }
        if DIAGRAM_ARROW_HEADS.contains(existing.char) { return existing }
        if DIAGRAM_ARROW_HEADS.contains(incoming.char) { return incoming }
        var merged = incoming
        merged.char = mergeDiagramLineGlyph(existing.char, incoming.char, cornerStyle: .rounded) ?? incoming.char
        return merged
    }

    @discardableResult
    private static func fcSetRichText(
        _ grid: FlowchartGrid,
        x: Int,
        y: Int,
        runs: [DiagramTextRun],
        style: FlowchartCellStyle
    ) -> Int {
        var offset = 0
        for run in runs {
            let meta: DiagramCanvasTextMetadata<FlowchartCellMetadata>? = run.italic
                ? .fixed(FlowchartCellMetadata(attributes: TextAttributes.italic))
                : nil
            grid.setText(x + offset, y, run.text, style: style, metadata: meta)
            offset += visualLength(run.text)
        }
        return offset
    }

    private static func fcDrawSubroutineNode(
        _ grid: FlowchartGrid,
        bounds: FlowchartNodeBounds,
        chars: BorderCharacters,
        style: FlowchartCellStyle
    ) {
        drawDiagramFrame(bounds.diagramBounds, chars: chars) { x, y, ch in grid.setCell(x, y, ch, style: style) }
        let leftRailX = bounds.left + 2
        let rightRailX = bounds.left + bounds.width - 3
        grid.setCell(leftRailX, bounds.top, chars.topT, style: style)
        grid.setCell(rightRailX, bounds.top, chars.topT, style: style)
        grid.setCell(leftRailX, bounds.top + bounds.height - 1, chars.bottomT, style: style)
        grid.setCell(rightRailX, bounds.top + bounds.height - 1, chars.bottomT, style: style)
        if bounds.height > 2 {
            for y in (bounds.top + 1)..<(bounds.top + bounds.height - 1) {
                grid.setCell(leftRailX, y, chars.vertical, style: style)
                grid.setCell(rightRailX, y, chars.vertical, style: style)
            }
        }
    }

    private static func fcDrawDatabaseNode(
        _ grid: FlowchartGrid,
        bounds: FlowchartNodeBounds,
        chars: BorderCharacters,
        style: FlowchartCellStyle
    ) {
        drawDiagramFrame(bounds.diagramBounds, chars: chars) { x, y, ch in grid.setCell(x, y, ch, style: style) }
        let topRailY = bounds.top + 1
        let bottomRailY = bounds.top + bounds.height - 2
        for y in [topRailY, bottomRailY] {
            grid.setCell(bounds.left, y, chars.leftT, style: style)
            grid.setCell(bounds.left + bounds.width - 1, y, chars.rightT, style: style)
            if bounds.width > 2 {
                for x in (bounds.left + 1)..<(bounds.left + bounds.width - 1) {
                    grid.setCell(x, y, chars.horizontal, style: style)
                }
            }
        }
    }

    private static func fcDrawNode(
        _ grid: FlowchartGrid,
        node: FlowchartNode,
        bounds: FlowchartNodeBounds,
        borderStyle: BorderStyle
    ) {
        let chars = BorderChars.forStyle(borderStyle)
        let style: FlowchartCellStyle = node.shape == .database ? .database : .node
        let border: FlowchartCellStyle = node.shape == .database ? .databaseBorder : .nodeBorder

        switch node.shape {
        case .decision:
            drawDiagramDiamond(
                bounds.diagramBounds,
                setCell: { x, y, ch in grid.setCell(x, y, ch, style: border) },
                chars: diagramDiamondCharactersFromBorder(chars)
            )
        case .subroutine:
            fillDiagramFrameInterior(bounds.diagramBounds) { x, y in grid.setCell(x, y, " ", style: style) }
            fcDrawSubroutineNode(grid, bounds: bounds, chars: chars, style: border)
        case .database:
            fillDiagramFrameInterior(bounds.diagramBounds) { x, y in grid.setCell(x, y, " ", style: style) }
            fcDrawDatabaseNode(grid, bounds: bounds, chars: chars, style: border)
        case .box, .rounded:
            fillDiagramFrameInterior(bounds.diagramBounds) { x, y in grid.setCell(x, y, " ", style: style) }
            drawDiagramFrame(bounds.diagramBounds, chars: chars) { x, y, ch in grid.setCell(x, y, ch, style: border) }
        }

        let textTop: Int
        switch node.shape {
        case .decision: textTop = bounds.top + floorDiv(bounds.height - bounds.lines.count, 2)
        case .database: textTop = bounds.top + 2
        default: textTop = bounds.top + 1
        }
        let parsedLines = parseDiagramTextLines(node.label)
        for (index, line) in bounds.lines.enumerated() {
            let lineX = node.shape == .subroutine
                ? bounds.left + 3
                : bounds.left + max(1, floorDiv(bounds.width - visualLength(line), 2))
            if index < parsedLines.count {
                fcSetRichText(grid, x: lineX, y: textTop + index, runs: parsedLines[index].runs, style: style)
            }
        }
    }

    private static func fcDrawSubgraphLabel(_ grid: FlowchartGrid, bounds: FlowchartSubgraphBounds) {
        guard !bounds.label.isEmpty else { return }
        let lines = parseDiagramTextLines(bounds.label)
        let labelY = bounds.labelSide == .top ? bounds.top : bounds.top + bounds.height - lines.count
        for (index, line) in lines.enumerated() {
            grid.setText(bounds.left + 2, labelY + index, " ", style: .groupLabel)
            let w = fcSetRichText(grid, x: bounds.left + 3, y: labelY + index, runs: line.runs, style: .groupLabel)
            grid.setText(bounds.left + w + 3, labelY + index, " ", style: .groupLabel)
        }
    }

    private static func fcDrawEdgeLabel(_ grid: FlowchartGrid, route: FlowchartEdgeRoute, style: FlowchartCellStyle) {
        let label = flowchartRouteLabelLayout(route, measure: visualLength)
        let padding = String(repeating: " ", count: DIAGRAM_LABEL_PADDING_X)
        for (index, line) in parseDiagramTextLines(route.edge.label).enumerated() {
            grid.setText(label.point.x, label.point.y + index, padding, style: style)
            let w = fcSetRichText(grid, x: label.point.x + DIAGRAM_LABEL_PADDING_X, y: label.point.y + index, runs: line.runs, style: style)
            grid.setText(label.point.x + w + DIAGRAM_LABEL_PADDING_X, label.point.y + index, padding, style: style)
        }
    }

    private static func fcDrawRoutedEdge(_ grid: FlowchartGrid, route: FlowchartEdgeRoute) {
        let points = route.points
        guard points.count >= 2 else { return }
        drawOrthogonalPath(
            points,
            setCell: { x, y, ch in grid.setCell(x, y, ch, style: .edge) },
            cornerStyle: .rounded,
            lineStyle: route.edge.style == .thick ? .heavy : .single
        )
        let end = points[points.count - 1]
        let prev = points[points.count - 2]
        if route.edge.arrowhead != false {
            grid.setCell(end.x, end.y, diagramArrowHeadBetween(prev, end), style: .edge)
        } else if let endDir = directionBetween(prev, end) {
            grid.setCell(end.x, end.y, diagramLineGlyph([endDir]), style: .edge)
        }
        if !route.edge.label.isEmpty {
            fcDrawEdgeLabel(grid, route: route, style: .label)
        }
    }

    private static func fcRouteCellOccupancy(_ routes: [FlowchartEdgeRoute]) -> [DiagramPoint: Int] {
        var occupancy: [DiagramPoint: Int] = [:]
        for route in routes {
            var routeCells = Set<DiagramPoint>()
            if route.points.count >= 2 {
                for index in 1..<route.points.count {
                    walkOrthogonalSegment(route.points[index - 1], route.points[index], includeStart: index == 1) { pt in
                        routeCells.insert(pt)
                    }
                }
            }
            for pt in routeCells { occupancy[pt, default: 0] += 1 }
        }
        return occupancy
    }

    private static func fcFadeSourcePath(
        _ grid: FlowchartGrid,
        connector: FlowchartPoint,
        points: [FlowchartPoint],
        styles: [FlowchartCellStyle],
        occupancy: [DiagramPoint: Int]
    ) {
        guard points.count >= 2 else { return }
        var privateCells = [connector]
        let lineGlyphs: Set<String> = ["─", "━", "│", "┃"]
        walkOrthogonalSegmentWhile(points[0], points[1], includeStart: true) { pt in
            guard occupancy[pt] == 1,
                  let cell = grid.getCell(pt.x, pt.y),
                  lineGlyphs.contains(cell.char),
                  cell.style != .label
            else { return false }
            privateCells.append(pt)
            return true
        }
        for (index, pt) in privateCells.enumerated() {
            let styleIndex = min(styles.count - 1, floorDiv((index + 1) * styles.count, privateCells.count + 1))
            if let cell = grid.getCell(pt.x, pt.y) {
                grid.setCell(pt.x, pt.y, cell.char, style: styles[styleIndex])
            }
        }
    }

    private static func fcDrawSourceConnectors(
        _ grid: FlowchartGrid,
        diagram: FlowchartDiagram,
        endpoints: [String: FlowchartEndpointBounds],
        routes: [FlowchartEdgeRoute]
    ) {
        let nodesById = Dictionary(uniqueKeysWithValues: diagram.nodes.map { ($0.id, $0) })
        let occupancy = fcRouteCellOccupancy(routes)
        var sourceJunctions: [String: (directions: Set<DiagramDirection>, heavy: Bool)] = [:]
        for route in routes {
            guard route.points.count >= 2 else { continue }
            let src = route.points[0]
            let next = route.points[1]
            let key = "\(route.edge.from):\(src.x):\(src.y)"
            var junction = sourceJunctions[key] ?? (Set<DiagramDirection>(), true)
            if let dir = directionBetween(src, next) { junction.directions.insert(dir) }
            junction.heavy = junction.heavy && (route.edge.style == .thick)
            sourceJunctions[key] = junction
        }

        for route in routes {
            guard let from = endpoints[route.edge.from], let sourcePoint = route.points.first else { continue }
            let isDb = nodesById[route.edge.from]?.shape == .database
            let styles = isDb ? DATABASE_EDGE_FADE_STYLES : NODE_EDGE_FADE_STYLES
            let connector = flowchartSourceConnector(from, sourcePoint: sourcePoint)
            grid.setCell(connector.x, connector.y, connector.char, style: .edge)
            if let connectorDir = directionBetween(sourcePoint, connector.diagramPoint),
               let cell = grid.getCell(sourcePoint.x, sourcePoint.y),
               cell.style != .label,
               !DIAGRAM_ARROW_HEADS.contains(cell.char)
            {
                let key = "\(route.edge.from):\(sourcePoint.x):\(sourcePoint.y)"
                let junction = sourceJunctions[key]
                var dirs = junction?.directions ?? Set<DiagramDirection>()
                dirs.insert(connectorDir)
                let heavy = junction?.heavy ?? (route.edge.style == .thick)
                grid.replaceCell(
                    sourcePoint.x,
                    sourcePoint.y,
                    diagramLineGlyph(dirs, cornerStyle: .rounded, lineStyle: heavy ? .heavy : .single),
                    style: .edge
                )
            }
            fcFadeSourcePath(grid, connector: connector.diagramPoint, points: route.points, styles: styles, occupancy: occupancy)
            if route.edge.sourceArrowhead == true, route.points.count >= 2 {
                grid.setCell(sourcePoint.x, sourcePoint.y, diagramArrowHeadBetween(route.points[1], sourcePoint), style: .edge)
            }
        }
    }

    // parity: merman/src/flowchart/drawing.ts#drawFlowchartDiagramGrid [status=implemented hash=dab9286b75ac]
    public static func drawFlowchartDiagramGrid(
        _ sourceDiagram: FlowchartDiagram,
        options: FlowchartDiagramRenderOptions = FlowchartDiagramRenderOptions()
    ) throws -> FlowchartGrid {
        let borderStyle = options.borderStyle ?? DEFAULT_BORDER_STYLE
        let layout = layoutFlowchartDiagram(sourceDiagram, options: options)
        let diagram = layout.diagram
        let grid = try FlowchartGrid(
            width: layout.width,
            height: layout.height,
            options: DiagramCanvasOptions(mergeCell: fcMergeCell)
        )
        let chars = BorderChars.forStyle(borderStyle)
        for subgraph in diagram.subgraphs ?? [] {
            if let bound = layout.subgraphBounds[subgraph.id] {
                drawDiagramFrame(bound.diagramBounds, chars: chars) { x, y, ch in grid.setCell(x, y, ch, style: .group) }
            }
        }
        for route in layout.routes {
            fcDrawRoutedEdge(grid, route: route)
        }
        for node in diagram.nodes {
            if let bound = layout.bounds[node.id] {
                fcDrawNode(grid, node: node, bounds: bound, borderStyle: borderStyle)
            }
        }
        var endpoints: [String: FlowchartEndpointBounds] = [:]
        for (k, v) in layout.subgraphBounds { endpoints[k] = .subgraph(v) }
        for (k, v) in layout.bounds { endpoints[k] = .node(v) }
        fcDrawSourceConnectors(grid, diagram: diagram, endpoints: endpoints, routes: layout.routes)
        for subgraph in diagram.subgraphs ?? [] {
            if let bound = layout.subgraphBounds[subgraph.id] {
                fcDrawSubgraphLabel(grid, bounds: bound)
            }
        }
        return grid
    }

    // MARK: - Flowchart Render (`flowchart/render.ts`)

    // parity: merman/src/flowchart/render.ts#renderFlowchartDiagram [status=implemented hash=bdc6f50ee476]
    public static func renderFlowchartDiagram(
        _ content: String,
        options: FlowchartDiagramRenderOptions = FlowchartDiagramRenderOptions()
    ) throws -> String {
        try drawFlowchartDiagramGrid(try parseMermaidFlowchartDiagram(content), options: options)
            .toString(DiagramCanvasTextOptions(trimTop: true, trimBottom: true))
    }
}
