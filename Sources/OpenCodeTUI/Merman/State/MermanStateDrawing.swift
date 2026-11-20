import OpenTUICore

extension Merman {
    // MARK: - State Render Grid (`state/render-grid.ts`)

    // parity: merman/src/state/render-grid.ts#StateGrid [status=implemented hash=5e865a679994]
    public typealias StateGrid = DiagramCanvas<StateCellStyle, EmptyCanvasMetadata>

    // parity: merman/src/state/render-grid.ts#renderStateGridText [status=implemented hash=98082061c8c1]
    public static func renderStateGridText(_ grid: StateGrid) -> String {
        grid.toString(DiagramCanvasTextOptions(trimTop: true, trimBottom: true))
    }

    // parity: merman/src/state/render-grid.ts#renderStateGridStyledText [status=implemented hash=6c30606dfee7]
    public static func renderStateGridStyledText(
        _ grid: StateGrid,
        colors: StateStyleColors,
        backgrounds: [StateCellStyle: RGBA]? = nil
    ) -> StyledText {
        renderDiagramGridStyledTextByStyle(
            grid,
            foregrounds: colors,
            backgrounds: backgrounds,
            options: DiagramCanvasRunOptions(trimTop: true, trimBottom: true)
        )
    }

    // MARK: - State Drawing (`state/drawing.ts`)

    public struct StateDiagramDrawingResult {
        public let grid: StateGrid
        public let diagram: StateVisibleDiagram
        public let layout: StateDiagramLayout
        public let transitionPlans: [StateTransitionRenderPlan]
    }

    private static func stateTranslateTransitionPlans(_ plans: [StateTransitionRenderPlan], dx: Int, dy: Int) -> [StateTransitionRenderPlan] {
        plans.map { plan in
            let cells = plan.cells.map { cell -> StateTransitionRenderCell in
                if let dir = cell.arrowDirection {
                    return StateTransitionRenderCell(x: cell.x + dx, y: cell.y + dy, arrowDirection: dir)
                }
                return StateTransitionRenderCell(x: cell.x + dx, y: cell.y + dy, char: cell.char ?? " ")
            }
            let path = plan.path.map { point($0.x + dx, $0.y + dy) }
            let label = plan.label.map { StateTransitionRenderLabel(x: $0.x + dx, y: $0.y + dy, lines: $0.lines) }
            return StateTransitionRenderPlan(route: plan.route, cells: cells, path: path, label: label, pathRepaired: plan.pathRepaired)
        }
    }

    private static func stateMakeGrid(width: Int, height: Int) throws -> StateGrid {
        try StateGrid(
            width: width,
            height: height,
            options: DiagramCanvasOptions(mergeCell: { existing, incoming in
                let existingIsTransition = existing.style == .transition || (existing.style?.isDepartureRamp == true)
                let incomingIsTransition = incoming.style == .transition || (incoming.style?.isDepartureRamp == true)
                let shouldMerge = incomingIsTransition && existingIsTransition
                var result = incoming
                if shouldMerge {
                    result.char = mergeDiagramLineGlyph(existing.char, incoming.char, cornerStyle: .rounded) ?? incoming.char
                }
                return result
            })
        )
    }

    private static func stateNoteConnectorGlyph(_ directions: Set<DiagramDirection>) -> String {
        let chars = BorderChars.double
        let up = directions.contains(.up)
        let down = directions.contains(.down)
        let left = directions.contains(.left)
        let right = directions.contains(.right)
        if up && down && left && right { return chars.cross }
        if up && down && right { return chars.leftT }
        if up && down && left { return chars.rightT }
        if left && right && down { return chars.topT }
        if left && right && up { return chars.bottomT }
        if up && right { return chars.bottomLeft }
        if up && left { return chars.bottomRight }
        if down && right { return chars.topLeft }
        if down && left { return chars.topRight }
        if up || down { return chars.vertical }
        return chars.horizontal
    }

    private static func stateDrawContainerFrame(
        _ grid: StateGrid,
        bounds: StateDiagramBoxBounds,
        label: String,
        chars: BorderCharacters,
        style: StateCellStyle
    ) {
        drawDiagramFrame(bounds.diagramBounds, chars: chars) { x, y, ch in grid.setCell(x, y, ch, style: style) }
        if !label.isEmpty {
            grid.setText(bounds.left + 2, bounds.top, " \(label) ", style: style)
        }
    }

    private static func stateDrawBox(
        _ grid: StateGrid,
        state: StateDiagramState,
        bounds: StateDiagramBoxBounds,
        lines: [String],
        borderStyle: BorderStyle
    ) {
        if isHiddenCompositeMarker(state) { return }
        if state.kind != .state {
            grid.setCell(bounds.left, bounds.top, state.label, style: StateCellStyle.fromStateKind(state.kind))
            return
        }
        fillDiagramFrameInterior(bounds.diagramBounds) { x, y in grid.setCell(x, y, " ", style: .state) }
        drawDiagramFrame(bounds.diagramBounds, chars: BorderChars.forStyle(borderStyle)) { x, y, ch in
            grid.setCell(x, y, ch, style: .stateBorder)
        }
        for (index, line) in lines.enumerated() {
            grid.setText(bounds.left + 2, bounds.top + 1 + index, line, style: .state)
        }
    }

    private static func stateDrawNote(_ grid: StateGrid, bounds: StateDiagramNoteBounds, target: StateDiagramBoxBounds) {
        let chars = BorderChars.double
        let connector = stateDiagramNoteConnector(bounds, target: target)
        let points = orthogonalPathPoints(connector.points)
        for (index, pt) in points.enumerated() {
            var directions = Set<DiagramDirection>()
            if index > 0, let d = directionBetween(pt, points[index - 1]) { directions.insert(d) }
            if index + 1 < points.count, let d = directionBetween(pt, points[index + 1]) { directions.insert(d) }
            let distFromNote = points.count - index - 1
            let style: StateCellStyle = distFromNote < 3 ? NOTE_CONNECTOR_RAMP_STYLES[2 - distFromNote] : .noteConnector
            grid.setCell(pt.x, pt.y, stateNoteConnectorGlyph(directions), style: style)
        }
        stateDrawContainerFrame(grid, bounds: bounds.boxBounds, label: "", chars: chars, style: .noteBorder)
        grid.setCell(
            bounds.note.position == .right ? bounds.left : bounds.left + bounds.width - 1,
            connector.connectorY,
            bounds.note.position == .right ? chars.rightT : chars.leftT,
            style: .noteBorder
        )
        for (index, line) in bounds.lines.enumerated() {
            grid.setText(bounds.left + 2, bounds.top + 1 + index, line, style: .noteText)
        }
    }

    private static func stateDrawTransitionRenderPlan(
        _ grid: StateGrid,
        plan: StateTransitionRenderPlan,
        arrowHeadStyle: StateDiagramArrowHeadStyle,
        rampDeparture: Bool
    ) {
        var departure: [DiagramPoint: StateCellStyle] = [:]
        if rampDeparture {
            for (idx, pt) in plan.path.prefix(3).enumerated() {
                departure[pt] = STATE_DEPARTURE_RAMP_STYLES[idx]
            }
        }
        let headStyle: DiagramArrowHeadStyle = arrowHeadStyle == .line ? .line : .filled
        for cell in plan.cells {
            let char = cell.arrowDirection.map { diagramArrowHead($0, style: headStyle) } ?? (cell.char ?? " ")
            grid.setCell(cell.x, cell.y, char, style: departure[point(cell.x, cell.y)] ?? .transition)
        }
        if let lbl = plan.label {
            for (index, line) in lbl.lines.enumerated() {
                let y = lbl.y + index
                let leftX = lbl.x - DIAGRAM_LABEL_PADDING_X
                if grid.getCell(leftX, y)?.char == " " { grid.setCell(leftX, y, " ", style: .label) }
                grid.setText(lbl.x, y, line, style: .label)
                let rightX = lbl.x + diagramTextWidth(line) + DIAGRAM_LABEL_PADDING_X - 1
                if grid.getCell(rightX, y)?.char == " " { grid.setCell(rightX, y, " ", style: .label) }
            }
        }
    }

    private static func stateCreateDrawingWithDirection(
        _ sourceDiagram: StateDiagram,
        options: StateDiagramRenderOptions,
        direction: StateDiagramDirection
    ) throws -> StateDiagramDrawingResult {
        let directed = direction == sourceDiagram.direction
            ? sourceDiagram
            : StateDiagram(
                direction: direction,
                states: sourceDiagram.states,
                transitions: sourceDiagram.transitions,
                composites: sourceDiagram.composites,
                notes: sourceDiagram.notes
            )
        let diagram = prepareVisibleStateDiagram(directed)
        let borderStyle = options.borderStyle ?? DEFAULT_STATE_BORDER_STYLE
        let arrowHeadStyle = options.arrowHeadStyle ?? DEFAULT_STATE_ARROW_HEAD_STYLE
        let minStateGap = normalizeStateMinStateGap(options.minStateGap)
        let searchBudget = createStateSearchBudget()

        var layout = try createStateDiagramLayout(diagram, options: StateDiagramLayoutOptions(minStateGap: minStateGap, searchBudget: searchBudget))
        var allBoxBounds = Array(layout.bounds.values) + layout.noteBounds.map(\.boxBounds)
        var maxY = max(0, allBoxBounds.map { $0.top + $0.height }.max() ?? 0)
        let feedbackLaneY = maxY + 3
        let feedbackTopY = min(0, allBoxBounds.map(\.top).min() ?? 0) - 3
        expandCompositeBoundsForFeedback(diagram, bounds: &layout.bounds, compositeBounds: &layout.compositeBounds, feedbackLaneY: feedbackLaneY)

        var transitionPlans: [StateTransitionRenderPlan] = []
        let separationAttempts = diagram.states.count + diagram.composites.count + 1
        for _ in 0..<separationAttempts {
            transitionPlans = try createStateTransitionRenderPlans(
                diagram,
                bounds: layout.bounds,
                feedbackLaneY: feedbackLaneY,
                options: StateTransitionRenderOptions(feedbackTopY: feedbackTopY, noteBounds: layout.noteBounds, searchBudget: searchBudget)
            )
            expandCompositeBoundsForInternalTransitions(
                diagram,
                compositeBounds: &layout.compositeBounds,
                bounds: &layout.bounds,
                transitionPlans: transitionPlans
            )
            if !separateExternalBoundsFromComposites(diagram, layout: &layout) { break }
        }

        let connectorPoints = layout.noteBounds.flatMap { $0.connector?.points ?? [] }
        let contentLeft = min(
            0,
            min(
                (Array(layout.bounds.values) + layout.noteBounds.map(\.boxBounds)).map(\.left).min() ?? 0,
                min(
                    connectorPoints.map(\.x).min() ?? 0,
                    transitionPlans.flatMap { plan -> [Int] in
                        plan.cells.map(\.x) + (plan.label.map { [$0.x - DIAGRAM_LABEL_PADDING_X] } ?? [])
                    }.min() ?? 0
                )
            )
        )
        let contentTop = min(
            0,
            min(
                (Array(layout.bounds.values) + layout.noteBounds.map(\.boxBounds)).map(\.top).min() ?? 0,
                min(
                    connectorPoints.map(\.y).min() ?? 0,
                    transitionPlans.flatMap { plan -> [Int] in
                        plan.cells.map(\.y) + (plan.label.map { [$0.y] } ?? [])
                    }.min() ?? 0
                )
            )
        )
        if contentLeft < 0 || contentTop < 0 {
            translateStateDiagramLayout(&layout, dx: -contentLeft, dy: -contentTop)
            transitionPlans = stateTranslateTransitionPlans(transitionPlans, dx: -contentLeft, dy: -contentTop)
        }

        allBoxBounds = Array(layout.bounds.values) + layout.noteBounds.map(\.boxBounds)
        let translatedConnPts = layout.noteBounds.flatMap { $0.connector?.points ?? [] }
        let maxX = max(
            0,
            max(allBoxBounds.map { $0.left + $0.width }.max() ?? 0, translatedConnPts.map { $0.x + 1 }.max() ?? 0)
        )
        maxY = max(
            0,
            max(allBoxBounds.map { $0.top + $0.height }.max() ?? 0, translatedConnPts.map { $0.y + 1 }.max() ?? 0)
        )
        let labelSizes = diagram.transitions.map { measureStateTransitionLabel($0.label) }
        let maxLabelW = labelSizes.map(\.width).max() ?? 0
        let maxLabelLines = labelSizes.map(\.height).max() ?? 0
        let transitionRight = max(
            maxX,
            transitionPlans.flatMap { plan -> [Int] in
                plan.cells.map { $0.x + 1 } + (plan.label.map { [$0.x + measureStateTransitionLabel(plan.route.transition.label).width + DIAGRAM_LABEL_PADDING_X] } ?? [])
            }.max() ?? maxX
        )
        let transitionBottom = max(
            maxY,
            transitionPlans.flatMap { plan -> [Int] in
                plan.cells.map { $0.y + 1 } + (plan.label.map { [$0.y + $0.lines.count] } ?? [])
            }.max() ?? maxY
        )

        let grid = try stateMakeGrid(
            width: max(maxX + max(24, maxLabelW + 4), transitionRight + 2),
            height: max(maxY + 8 + maxLabelLines, transitionBottom + 2)
        )

        for comp in diagram.composites {
            if let bound = layout.compositeBounds[comp.id] {
                stateDrawContainerFrame(grid, bounds: bound, label: comp.label, chars: BorderChars.forStyle(borderStyle), style: .composite)
            }
        }
        for state in diagram.states {
            if let bound = layout.bounds[state.id], let size = layout.sizes[state.id] {
                stateDrawBox(grid, state: state, bounds: bound, lines: size.lines, borderStyle: borderStyle)
            }
        }
        let statesById = Dictionary(uniqueKeysWithValues: diagram.states.map { ($0.id, $0) })
        for plan in transitionPlans {
            let source = statesById[plan.route.transition.from]
            stateDrawTransitionRenderPlan(grid, plan: plan, arrowHeadStyle: arrowHeadStyle, rampDeparture: source?.kind == .state)
        }
        for junction in createStateTransitionJunctionPlans(diagram, bounds: layout.bounds, renderPlans: transitionPlans) {
            let style: StateCellStyle = junction.kind == .choice ? .choice : .transition
            let char = junction.kind == .choice ? "◆" : diagramLineGlyph(junction.connections, cornerStyle: .rounded)
            grid.setCell(junction.bounds.left, junction.bounds.top, char, style: style)
        }
        for comp in diagram.composites {
            if let bound = layout.compositeBounds[comp.id], !comp.label.isEmpty {
                grid.setText(bound.left + 2, bound.top, " \(comp.label) ", style: .compositeLabel)
            }
        }
        for noteBound in layout.noteBounds {
            if let target = layout.bounds[noteBound.note.target] {
                stateDrawNote(grid, bounds: noteBound, target: target)
            }
        }
        return StateDiagramDrawingResult(grid: grid, diagram: diagram, layout: layout, transitionPlans: transitionPlans)
    }

    // parity: merman/src/state/drawing.ts#createStateDiagramDrawing [status=implemented hash=2e034c5cadbf]
    public static func createStateDiagramDrawing(
        _ sourceDiagram: StateDiagram,
        options: StateDiagramRenderOptions = StateDiagramRenderOptions()
    ) throws -> StateDiagramDrawingResult {
        let direction = options.direction ?? sourceDiagram.direction
        if direction != .LR && direction != .RL {
            return try stateCreateDrawingWithDirection(sourceDiagram, options: options, direction: direction)
        }
        guard let maxWidthRaw = options.layoutMaxWidth else {
            return try stateCreateDrawingWithDirection(sourceDiagram, options: options, direction: direction)
        }
        let fallbackDirection: StateDiagramDirection = direction == .RL ? .BT : .TB
        let maxWidth = max(1, maxWidthRaw)
        let drawing: StateDiagramDrawingResult?
        do {
            drawing = try stateCreateDrawingWithDirection(sourceDiagram, options: options, direction: direction)
        } catch is DiagramCanvasSizeError {
            drawing = nil
        }
        guard let drawing else {
            return try stateCreateDrawingWithDirection(sourceDiagram, options: options, direction: fallbackDirection)
        }
        let trimOpts = DiagramCanvasTextOptions(trimTop: true, trimBottom: true)
        if drawing.grid.getTextSize(trimOpts).width <= maxWidth {
            return drawing
        }
        let fallback = try stateCreateDrawingWithDirection(sourceDiagram, options: options, direction: fallbackDirection)
        if fallback.grid.getTextSize(trimOpts).width >= drawing.grid.getTextSize(trimOpts).width {
            return drawing
        }
        return fallback
    }

    // parity: merman/src/state/drawing.ts#drawStateDiagramGrid [status=implemented hash=200bbe52f0af]
    public static func drawStateDiagramGrid(
        _ sourceDiagram: StateDiagram,
        options: StateDiagramRenderOptions = StateDiagramRenderOptions()
    ) throws -> StateGrid {
        try createStateDiagramDrawing(sourceDiagram, options: options).grid
    }

    // MARK: - State Diagram (`state/diagram.ts`)

    // parity: merman/src/state/diagram.ts#renderStateDiagram [status=implemented hash=e44d0d379f7d]
    public static func renderStateDiagram(
        _ content: String,
        options: StateDiagramRenderOptions = StateDiagramRenderOptions()
    ) throws -> String {
        renderStateGridText(try drawStateDiagramGrid(try parseMermaidStateDiagram(content), options: options))
    }
}
