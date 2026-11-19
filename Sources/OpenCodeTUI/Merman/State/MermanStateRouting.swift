import Foundation
import OpenTUICore

extension Merman {
    // MARK: - State Routing Types (`state/routing.ts`)

    public enum StateTransitionTargetApproach: String, Equatable, Hashable, Sendable, Codable {
        case top
        case bottom
    }

    public enum StateTransitionRouteKind: Equatable, Hashable, Sendable, Codable {
        case `self`(lane: Int)
        case horizontalForward(leftToRight: Bool)
        case bottomFeedback(railY: Int, approachX: Int)
        case topFeedback(railY: Int)
        case bottomParallel(railY: Int, approachX: Int)
        case verticalElbow(hasReverse: Bool, offsetConnector: Bool)
        case sideParallel(railX: Int, targetApproach: StateTransitionTargetApproach?)
        case vertical
    }

    // parity: merman/src/state/routing.ts#StateTransitionRoutePlan [status=implemented hash=861480124bf3]
    public struct StateTransitionRoutePlan: Equatable, Hashable, Sendable, Codable {
        public var transition: StateVisibleTransition
        public var from: StateDiagramBoxBounds
        public var to: StateDiagramBoxBounds
        public var targetIsChoice: Bool
        public var targetIsHiddenMarker: Bool
        public var kind: StateTransitionRouteKind

        public init(
            transition: StateVisibleTransition,
            from: StateDiagramBoxBounds,
            to: StateDiagramBoxBounds,
            targetIsChoice: Bool,
            targetIsHiddenMarker: Bool,
            kind: StateTransitionRouteKind
        ) {
            self.transition = transition
            self.from = from
            self.to = to
            self.targetIsChoice = targetIsChoice
            self.targetIsHiddenMarker = targetIsHiddenMarker
            self.kind = kind
        }
    }

    // parity: merman/src/state/routing.ts#StateTransitionPathPoint [status=implemented hash=ab09fdc76fff]
    public typealias StateTransitionPathPoint = DiagramPoint

    // parity: merman/src/state/routing.ts#StateTransitionRenderCell [status=implemented hash=33ec036fa413]
    public struct StateTransitionRenderCell: Equatable, Hashable, Sendable, Codable {
        public var x: Int
        public var y: Int
        public var char: String?
        public var arrowDirection: DiagramDirection?

        public init(x: Int, y: Int, char: String) {
            self.x = x
            self.y = y
            self.char = char
            self.arrowDirection = nil
        }

        public init(x: Int, y: Int, arrowDirection: DiagramDirection) {
            self.x = x
            self.y = y
            self.char = nil
            self.arrowDirection = arrowDirection
        }
    }

    // parity: merman/src/state/routing.ts#StateTransitionRenderLabel [status=implemented hash=f8b4a170e584]
    public struct StateTransitionRenderLabel: Equatable, Hashable, Sendable, Codable {
        public var x: Int
        public var y: Int
        public var lines: [String]

        public init(x: Int, y: Int, lines: [String]) {
            self.x = x
            self.y = y
            self.lines = lines
        }
    }

    // parity: merman/src/state/routing.ts#StateTransitionRenderPlan [status=implemented hash=991ff55b2cff]
    public struct StateTransitionRenderPlan: Equatable, Hashable, Sendable, Codable {
        public var route: StateTransitionRoutePlan
        public var cells: [StateTransitionRenderCell]
        public var path: [StateTransitionPathPoint]
        public var label: StateTransitionRenderLabel?
        public var pathRepaired: Bool?

        public init(
            route: StateTransitionRoutePlan,
            cells: [StateTransitionRenderCell],
            path: [StateTransitionPathPoint],
            label: StateTransitionRenderLabel? = nil,
            pathRepaired: Bool? = nil
        ) {
            self.route = route
            self.cells = cells
            self.path = path
            self.label = label
            self.pathRepaired = pathRepaired
        }
    }

    // parity: merman/src/state/routing.ts#StateTransitionRenderOptions [status=implemented hash=ea21a998be4f]
    public struct StateTransitionRenderOptions {
        public var feedbackTopY: Int?
        public var noteBounds: [StateDiagramNoteBounds]?
        public var repairRoutes: Bool?
        public var searchBudget: StateSearchBudget?

        public init(
            feedbackTopY: Int? = nil,
            noteBounds: [StateDiagramNoteBounds]? = nil,
            repairRoutes: Bool? = nil,
            searchBudget: StateSearchBudget? = nil
        ) {
            self.feedbackTopY = feedbackTopY
            self.noteBounds = noteBounds
            self.repairRoutes = repairRoutes
            self.searchBudget = searchBudget
        }
    }

    public enum StateTransitionJunctionKind: String, Equatable, Hashable, Sendable, Codable {
        case choice
        case hiddenCompositeMarker = "hidden-composite-marker"
    }

    // parity: merman/src/state/routing.ts#StateTransitionJunctionPlan [status=implemented hash=f0b91d32e97d]
    public struct StateTransitionJunctionPlan: Equatable, Hashable, Sendable, Codable {
        public var state: StateDiagramState
        public var bounds: StateDiagramBoxBounds
        public var connections: Set<DiagramDirection>
        public var transitions: [StateVisibleTransition]
        public var kind: StateTransitionJunctionKind

        public init(
            state: StateDiagramState,
            bounds: StateDiagramBoxBounds,
            connections: Set<DiagramDirection>,
            transitions: [StateVisibleTransition],
            kind: StateTransitionJunctionKind
        ) {
            self.state = state
            self.bounds = bounds
            self.connections = connections
            self.transitions = transitions
            self.kind = kind
        }
    }

    public struct StateLabelMetrics: Equatable, Hashable, Sendable {
        public let lines: [String]
        public let width: Int
        public let height: Int
    }

    // parity: merman/src/state/routing.ts#measureStateTransitionLabel [status=implemented hash=e2ac080e37b6]
    public static func measureStateTransitionLabel(_ label: String) -> StateLabelMetrics {
        if label.isEmpty { return StateLabelMetrics(lines: [], width: 0, height: 0) }
        let lines = splitDiagramLines(label)
        return StateLabelMetrics(lines: lines, width: lines.map(diagramTextWidth).max() ?? 0, height: lines.count)
    }

    // parity: merman/src/state/routing.ts#hasReverseTransition [status=implemented hash=e114353169be]
    public static func hasReverseTransition(_ diagram: StateDiagram, transition: StateDiagramTransition) -> Bool {
        diagram.transitions.contains { $0.from == transition.to && $0.to == transition.from }
    }

    // parity: merman/src/state/routing.ts#isStateHorizontalFeedback [status=implemented hash=c36b87676a6c]
    public static func isStateHorizontalFeedback(
        direction: StateDiagramDirection,
        from: StateDiagramBoxBounds,
        to: StateDiagramBoxBounds
    ) -> Bool {
        direction == .RL ? to.centerX > from.centerX : to.centerX < from.centerX
    }

    public static func isStateHorizontalFeedback(
        _ diagram: StateDiagram,
        from: StateDiagramBoxBounds,
        to: StateDiagramBoxBounds
    ) -> Bool {
        isStateHorizontalFeedback(direction: diagram.direction, from: from, to: to)
    }

    // MARK: - Internal Routing Helpers

    private enum StateFeedbackSide {
        case bottom
        case top
    }

    private struct StateFeedbackAllocation {
        let side: StateFeedbackSide
        let railY: Int
    }

    private struct StateFeedbackInterval {
        let index: Int
        let transition: StateVisibleTransition
        let left: Int
        let right: Int
    }

    private static func stateFeedbackIntervalsOverlap(_ lLeft: Int, _ lRight: Int, _ rLeft: Int, _ rRight: Int) -> Bool {
        lLeft <= rRight && rLeft <= lRight
    }

    private static func stateFeedbackIntervalsCross(_ lLeft: Int, _ lRight: Int, _ rLeft: Int, _ rRight: Int) -> Bool {
        (lLeft < rLeft && rLeft < lRight && lRight < rRight) || (rLeft < lLeft && lLeft < rRight && rRight < lRight)
    }

    private static func stateCreateFeedbackAllocations(
        _ diagram: StateVisibleDiagram,
        bounds: [String: StateDiagramBoxBounds],
        feedbackLaneY: Int,
        laneGap: Int,
        feedbackTopY: Int?
    ) -> [Int: StateFeedbackAllocation] {
        guard diagram.direction == .LR || diagram.direction == .RL else { return [:] }
        var allocations: [Int: StateFeedbackAllocation] = [:]
        var bottomIntervals: [StateFeedbackInterval] = []
        var topIntervals: [StateFeedbackInterval] = []
        var canonicalSides: [String: StateFeedbackSide] = [:]
        let topLaneY = feedbackTopY ?? ((bounds.values.map(\.top).min() ?? 0) - 3)

        var intervals: [StateFeedbackInterval] = []
        for (idx, t) in diagram.transitions.enumerated() {
            guard let from = bounds[t.from], let to = bounds[t.to], t.from != t.to,
                  isStateHorizontalFeedback(diagram, from: from, to: to)
            else { continue }
            if from.centerY != to.centerY && !(from.centerY > to.centerY) { continue }
            intervals.append(StateFeedbackInterval(
                index: idx,
                transition: t,
                left: min(from.centerX, to.centerX),
                right: max(from.centerX, to.centerX)
            ))
        }

        for interval in intervals {
            let endpointKey = "\(interval.transition.from)\u{0000}\(interval.transition.to)"
            let side: StateFeedbackSide?
            if let existing = canonicalSides[endpointKey] {
                side = existing
            } else if !bottomIntervals.contains(where: { stateFeedbackIntervalsCross($0.left, $0.right, interval.left, interval.right) }) {
                side = .bottom
            } else if !topIntervals.contains(where: { stateFeedbackIntervalsCross($0.left, $0.right, interval.left, interval.right) }) {
                side = .top
            } else {
                side = nil
            }
            guard let side else { continue }
            canonicalSides[endpointKey] = side
            if side == .bottom { bottomIntervals.append(interval) } else { topIntervals.append(interval) }
        }

        for (side, list) in [(StateFeedbackSide.bottom, bottomIntervals), (StateFeedbackSide.top, topIntervals)] {
            var occupied: [(left: Int, right: Int, lane: Int)] = []
            let sorted = list.enumerated().sorted { lhs, rhs in
                let lw = lhs.element.right - lhs.element.left
                let rw = rhs.element.right - rhs.element.left
                if lw != rw { return lw < rw }
                return lhs.offset < rhs.offset
            }.map(\.element)
            for interval in sorted {
                var lane = 0
                while occupied.contains(where: { $0.lane == lane && stateFeedbackIntervalsOverlap($0.left, $0.right, interval.left, interval.right) }) {
                    lane += 1
                }
                let railY = side == .bottom ? feedbackLaneY + lane * laneGap : topLaneY - lane * laneGap
                occupied.append((interval.left, interval.right, lane))
                allocations[interval.index] = StateFeedbackAllocation(side: side, railY: railY)
            }
        }
        return allocations
    }

    private static func stateHasOpposingTopConnector(
        _ diagram: StateVisibleDiagram,
        transitionIndex: Int,
        transition: StateVisibleTransition,
        bounds: [String: StateDiagramBoxBounds]
    ) -> Bool {
        guard let from = bounds[transition.from], let to = bounds[transition.to], from.centerY != to.centerY else {
            return false
        }
        let lowerId = from.centerY > to.centerY ? transition.from : transition.to
        guard let lower = bounds[lowerId] else { return false }
        let leavesLower = transition.from == lowerId
        for (otherIdx, other) in diagram.transitions.enumerated() {
            if otherIdx == transitionIndex || (leavesLower ? other.to != lowerId : other.from != lowerId) { continue }
            guard let otherFrom = bounds[other.from], let otherTo = bounds[other.to],
                  max(otherFrom.centerY, otherTo.centerY) == lower.centerY
            else { continue }
            if other.from != lowerId { return true }
            if !((diagram.direction == .LR || diagram.direction == .RL) && isStateHorizontalFeedback(diagram, from: otherFrom, to: otherTo)) {
                return true
            }
        }
        return false
    }

    private static func stateVerticalCorridorCrossesUnrelatedState(
        _ diagram: StateVisibleDiagram,
        transition: StateVisibleTransition,
        from: StateDiagramBoxBounds,
        to: StateDiagramBoxBounds,
        bounds: [String: StateDiagramBoxBounds]
    ) -> Bool {
        let top = min(from.top + from.height, to.top + to.height)
        let bottom = max(from.top - 1, to.top - 1)
        return diagram.states.contains { state in
            if state.id == transition.from || state.id == transition.to || isHiddenCompositeMarker(state) { return false }
            guard let bound = bounds[state.id] else { return false }
            return from.centerX >= bound.left && from.centerX < bound.left + bound.width
                && top < bound.top + bound.height && bottom >= bound.top
        }
    }

    private static func stateHasVerticalCorridor(_ from: StateDiagramBoxBounds, _ to: StateDiagramBoxBounds) -> Bool {
        if from.centerY < to.centerY { return from.top + from.height <= to.top - 1 }
        return from.top - 1 >= to.top + to.height
    }

    private static func stateHorizontalCorridorCrossesUnrelatedState(
        _ diagram: StateVisibleDiagram,
        transition: StateVisibleTransition,
        from: StateDiagramBoxBounds,
        to: StateDiagramBoxBounds,
        bounds: [String: StateDiagramBoxBounds]
    ) throws -> Bool {
        let leftToRight = from.centerX <= to.centerX
        let startX = leftToRight ? from.left + from.width : from.left - 1
        let endX = leftToRight ? to.left - 1 : to.left + to.width
        var claims: [SpatialClaim] = []
        for state in diagram.states {
            if state.id == transition.from || state.id == transition.to || isHiddenCompositeMarker(state) { continue }
            if let bound = bounds[state.id] {
                claims.append(try spatialRectClaim(id: "state:\(state.id)", owner: "state:\(state.id)", role: .body, bounds: bound.diagramBounds))
            }
        }
        let space = try SpatialIndex.empty().add(claims: claims)
        let corridor = try spatialPathClaim(
            id: "corridor:\(transition.from):\(transition.to)",
            owner: "transition:\(transition.from):\(transition.to)",
            role: .route,
            points: [point(startX, from.centerY), point(endX, from.centerY)]
        )
        return !(try space.isFree(corridor))
    }

    private static func stateBottomApproachX(
        _ diagram: StateVisibleDiagram,
        transition: StateVisibleTransition,
        from: StateDiagramBoxBounds,
        to: StateDiagramBoxBounds,
        bounds: [String: StateDiagramBoxBounds],
        railY: Int
    ) -> Int {
        let targetX = to.width > 1 ? (from.centerX > to.centerX ? to.left + 1 : to.left + to.width - 2) : to.centerX
        let targetBottomY = to.top + to.height
        let top = min(targetBottomY, railY)
        let bottom = max(targetBottomY, railY)

        func isClear(_ x: Int) -> Bool {
            !diagram.states.contains { state in
                if state.id == transition.from || state.id == transition.to || isHiddenCompositeMarker(state) { return false }
                guard let bound = bounds[state.id] else { return false }
                return x >= bound.left && x < bound.left + bound.width
                    && top < bound.top + bound.height && bottom >= bound.top
            }
        }

        if isClear(targetX) { return targetX }
        let maxX = max(targetX, bounds.values.map { $0.left + $0.width }.max() ?? 0) + 1
        if maxX >= 1 {
            for distance in 1...maxX {
                let right = targetX + distance
                if isClear(right) { return right }
                let left = targetX - distance
                if left >= 0 && isClear(left) { return left }
            }
        }
        return targetX
    }

    private static func stateInnerConnectorX(_ bounds: StateDiagramBoxBounds, preferredX: Int) -> Int {
        if bounds.width <= 2 { return bounds.centerX }
        return max(bounds.left + 1, min(bounds.left + bounds.width - 2, preferredX))
    }

    private static func stateSideParallelTargetApproach(
        _ diagram: StateVisibleDiagram,
        transition: StateVisibleTransition,
        from: StateDiagramBoxBounds,
        to: StateDiagramBoxBounds,
        bounds: [String: StateDiagramBoxBounds],
        railX: Int
    ) throws -> StateTransitionTargetApproach? {
        var claims: [SpatialClaim] = []
        for state in diagram.states {
            if state.id == transition.from || state.id == transition.to || isHiddenCompositeMarker(state) { continue }
            if let bound = bounds[state.id] {
                claims.append(try spatialRectClaim(id: "state:\(state.id)", owner: "state:\(state.id)", role: .body, bounds: bound.diagramBounds))
            }
        }
        let space = try SpatialIndex.empty().add(claims: claims)
        let targetSideX = to.left + to.width
        func isPathFree(_ pts: [DiagramPoint]) throws -> Bool {
            let claim = try spatialPathClaim(id: "side-target:\(transition.from):\(transition.to)", owner: "side-target", role: .route, points: pts)
            return try space.isFree(claim)
        }
        if try isPathFree([point(railX, to.centerY), point(targetSideX, to.centerY)]) {
            return nil
        }
        let targetX = stateInnerConnectorX(to, preferredX: from.centerX)
        let preferred: StateTransitionTargetApproach = from.centerY > to.centerY ? .top : .bottom
        let order: [StateTransitionTargetApproach] = preferred == .top ? [.top, .bottom] : [.bottom, .top]
        for side in order {
            let railY = side == .top ? to.top - 2 : to.top + to.height + 1
            let targetY = side == .top ? to.top - 1 : to.top + to.height
            if try isPathFree([point(railX, railY), point(targetX, railY), point(targetX, targetY)]) {
                return side
            }
        }
        return nil
    }

    static func stateContainingCompositeIds(_ diagram: StateVisibleDiagram, id: String) -> [String] {
        let statesById = Dictionary(uniqueKeysWithValues: diagram.states.map { ($0.id, $0) })
        let compositesById = Dictionary(uniqueKeysWithValues: diagram.composites.map { ($0.id, $0) })
        var ids: [String] = []
        var parentId = statesById[id]?.parentId ?? compositesById[id]?.parentId
        while let pid = parentId {
            ids.append(pid)
            parentId = compositesById[pid]?.parentId
        }
        return ids
    }

    private static func stateInnermostCommonComposite(_ diagram: StateVisibleDiagram, transition: StateVisibleTransition) -> String? {
        let target = Set(stateContainingCompositeIds(diagram, id: transition.to))
        return stateContainingCompositeIds(diagram, id: transition.from).first { target.contains($0) }
    }

    // parity: merman/src/state/routing.ts#createStateTransitionRoutePlans [status=implemented hash=689c4cd3f342]
    public static func createStateTransitionRoutePlans(
        _ diagram: StateVisibleDiagram,
        bounds: [String: StateDiagramBoxBounds],
        feedbackLaneY: Int,
        feedbackTopY: Int? = nil
    ) throws -> [StateTransitionRoutePlan] {
        let statesById = Dictionary(uniqueKeysWithValues: diagram.states.map { ($0.id, $0) })
        var endpointOccurrences: [String: Int] = [:]
        var selfOccurrences: [String: Int] = [:]
        let parallelLaneGap = max(3, diagram.transitions.map { measureStateTransitionLabel($0.label).height + 2 }.max() ?? 3)
        var nextSideRailX = (bounds.values.map { $0.left + $0.width }.max() ?? 0) + 3
        var sideRailLanes: [String: Int] = [:]
        let feedbackAllocations = stateCreateFeedbackAllocations(
            diagram,
            bounds: bounds,
            feedbackLaneY: feedbackLaneY,
            laneGap: parallelLaneGap,
            feedbackTopY: feedbackTopY
        )
        let maxBottomFeedback = feedbackAllocations.values
            .filter { $0.side == .bottom }
            .map(\.railY)
            .max()
        var nextBottomRailY = max(feedbackLaneY - parallelLaneGap, maxBottomFeedback ?? (feedbackLaneY - parallelLaneGap)) + parallelLaneGap

        func allocateSideRail(_ transition: StateVisibleTransition) -> Int {
            if let compositeId = stateInnermostCommonComposite(diagram, transition: transition),
               let composite = bounds[compositeId]
            {
                let lane = sideRailLanes[compositeId] ?? 0
                sideRailLanes[compositeId] = lane + 1
                var descendantRight = composite.left + 1
                for state in diagram.states {
                    if !stateContainingCompositeIds(diagram, id: state.id).contains(compositeId) { continue }
                    if let b = bounds[state.id] {
                        descendantRight = max(descendantRight, b.left + b.width)
                    }
                }
                return min(descendantRight + 2 + lane * 3, composite.left + composite.width - 2)
            }
            let railX = nextSideRailX
            nextSideRailX += 3
            return railX
        }

        func allocateBottomRail() -> Int {
            let railY = nextBottomRailY
            nextBottomRailY += parallelLaneGap
            return railY
        }

        var plans: [StateTransitionRoutePlan] = []
        for (tIndex, transition) in diagram.transitions.enumerated() {
            guard let from = bounds[transition.from], let to = bounds[transition.to] else { continue }
            let targetState = statesById[transition.to]
            let targetIsChoice = targetState?.kind == .choice
            let targetIsHiddenMarker = isHiddenCompositeMarker(targetState)

            func makePlan(_ kind: StateTransitionRouteKind) -> StateTransitionRoutePlan {
                StateTransitionRoutePlan(
                    transition: transition,
                    from: from,
                    to: to,
                    targetIsChoice: targetIsChoice,
                    targetIsHiddenMarker: targetIsHiddenMarker,
                    kind: kind
                )
            }

            func sideParallelPlan() throws -> StateTransitionRoutePlan {
                let railX = allocateSideRail(transition)
                let approach = try stateSideParallelTargetApproach(diagram, transition: transition, from: from, to: to, bounds: bounds, railX: railX)
                return makePlan(.sideParallel(railX: railX, targetApproach: approach))
            }

            if transition.from == transition.to {
                let lane = selfOccurrences[transition.from] ?? 0
                selfOccurrences[transition.from] = lane + 1
                plans.append(makePlan(.self(lane: lane)))
                continue
            }

            let endpointKey = "\(transition.from)\u{0000}\(transition.to)"
            let parallelIndex = endpointOccurrences[endpointKey] ?? 0
            endpointOccurrences[endpointKey] = parallelIndex + 1

            let feedback = (diagram.direction == .LR || diagram.direction == .RL) && isStateHorizontalFeedback(diagram, from: from, to: to)
            if let alloc = feedbackAllocations[tIndex] {
                if alloc.side == .bottom {
                    let approachX = stateBottomApproachX(diagram, transition: transition, from: from, to: to, bounds: bounds, railY: alloc.railY)
                    plans.append(makePlan(.bottomFeedback(railY: alloc.railY, approachX: approachX)))
                } else {
                    plans.append(makePlan(.topFeedback(railY: alloc.railY)))
                }
                continue
            }

            if parallelIndex > 0 {
                if from.centerY == to.centerY {
                    let railY = allocateBottomRail()
                    let approachX = stateBottomApproachX(diagram, transition: transition, from: from, to: to, bounds: bounds, railY: railY)
                    plans.append(makePlan(.bottomParallel(railY: railY, approachX: approachX)))
                } else {
                    plans.append(try sideParallelPlan())
                }
                continue
            }

            if diagram.direction != .LR && diagram.direction != .RL {
                let fromParent = statesById[transition.from]?.parentId
                let toParent = statesById[transition.to]?.parentId
                if let fp = fromParent, let tp = toParent, fp != tp {
                    plans.append(try sideParallelPlan())
                    continue
                }
                if stateVerticalCorridorCrossesUnrelatedState(diagram, transition: transition, from: from, to: to, bounds: bounds) {
                    plans.append(try sideParallelPlan())
                    continue
                }
                let verticalFeedback = diagram.direction == .BT ? from.centerY < to.centerY : from.centerY > to.centerY
                if verticalFeedback {
                    plans.append(try sideParallelPlan())
                    continue
                }
                if from.centerY == to.centerY {
                    if hasReverseTransition(diagram, transition: transition) && from.centerX > to.centerX {
                        let railY = allocateBottomRail()
                        let approachX = stateBottomApproachX(diagram, transition: transition, from: from, to: to, bounds: bounds, railY: railY)
                        plans.append(makePlan(.bottomParallel(railY: railY, approachX: approachX)))
                    } else {
                        plans.append(makePlan(.horizontalForward(leftToRight: from.centerX <= to.centerX)))
                    }
                    continue
                }
                if !stateHasVerticalCorridor(from, to) {
                    plans.append(try sideParallelPlan())
                    continue
                }
                if from.centerX != to.centerX {
                    plans.append(makePlan(.verticalElbow(hasReverse: false, offsetConnector: false)))
                } else {
                    plans.append(makePlan(.vertical))
                }
                continue
            }

            if from.centerY != to.centerY {
                if !stateHasVerticalCorridor(from, to) {
                    plans.append(try sideParallelPlan())
                    continue
                }
                if from.centerY > to.centerY && feedback {
                    let approachX = stateBottomApproachX(diagram, transition: transition, from: from, to: to, bounds: bounds, railY: feedbackLaneY)
                    plans.append(makePlan(.bottomFeedback(railY: feedbackLaneY, approachX: approachX)))
                    continue
                }
                let hasRev = hasReverseTransition(diagram, transition: transition)
                let offset = hasRev || stateHasOpposingTopConnector(diagram, transitionIndex: tIndex, transition: transition, bounds: bounds)
                plans.append(makePlan(.verticalElbow(hasReverse: hasRev, offsetConnector: offset)))
                continue
            }

            if feedback {
                let approachX = stateBottomApproachX(diagram, transition: transition, from: from, to: to, bounds: bounds, railY: feedbackLaneY)
                plans.append(makePlan(.bottomFeedback(railY: feedbackLaneY, approachX: approachX)))
                continue
            }

            if try stateHorizontalCorridorCrossesUnrelatedState(diagram, transition: transition, from: from, to: to, bounds: bounds) {
                let railY = allocateBottomRail()
                let approachX = stateBottomApproachX(diagram, transition: transition, from: from, to: to, bounds: bounds, railY: railY)
                plans.append(makePlan(.bottomParallel(railY: railY, approachX: approachX)))
                continue
            }

            plans.append(makePlan(.horizontalForward(leftToRight: from.centerX <= to.centerX)))
        }
        return plans
    }

    // MARK: - Render Plan Building

    private struct StateRenderBuilder {
        let route: StateTransitionRoutePlan
        var cells: [StateTransitionRenderCell] = []
        var path: [StateTransitionPathPoint] = []
        var label: StateTransitionRenderLabel?

        mutating func addCell(_ cell: StateTransitionRenderCell) {
            cells.append(cell)
            path.append(point(cell.x, cell.y))
        }

        mutating func addPathPoint(_ x: Int, _ y: Int) {
            path.append(point(x, y))
        }

        mutating func addLabel(x: Int, y: Int, text: String) {
            let metrics = measureStateTransitionLabel(text)
            if !metrics.lines.isEmpty {
                label = StateTransitionRenderLabel(x: x, y: y, lines: metrics.lines)
            }
        }

        mutating func addHorizontalLine(fromX: Int, toX: Int, y: Int, direction: Int) {
            var x = fromX
            while direction == 1 ? (x <= toX) : (x >= toX) {
                addCell(StateTransitionRenderCell(x: x, y: y, char: "─"))
                x += direction
            }
        }

        mutating func addVerticalLine(x: Int, fromY: Int, toY: Int, direction: Int) {
            var y = fromY
            while direction == 1 ? (y <= toY) : (y >= toY) {
                addCell(StateTransitionRenderCell(x: x, y: y, char: "│"))
                y += direction
            }
        }

        mutating func addRightDeparture(_ bounds: StateDiagramBoxBounds) {
            if bounds.width <= 1 || bounds.height <= 1 { return }
            addCell(StateTransitionRenderCell(x: bounds.left + bounds.width - 1, y: bounds.centerY, char: BorderChars.rounded.leftT))
        }

        mutating func addLeftDeparture(_ bounds: StateDiagramBoxBounds) {
            if bounds.width <= 1 || bounds.height <= 1 { return }
            addCell(StateTransitionRenderCell(x: bounds.left, y: bounds.centerY, char: BorderChars.rounded.rightT))
        }

        mutating func addBottomDeparture(_ bounds: StateDiagramBoxBounds, x: Int) {
            if bounds.width <= 1 || bounds.height <= 1 { return }
            addCell(StateTransitionRenderCell(x: x, y: bounds.top + bounds.height - 1, char: BorderChars.rounded.topT))
        }

        mutating func addTopDeparture(_ bounds: StateDiagramBoxBounds, x: Int) {
            if bounds.width <= 1 || bounds.height <= 1 { return }
            addCell(StateTransitionRenderCell(x: x, y: bounds.top, char: BorderChars.rounded.bottomT))
        }
    }

    private static func stateBuildRenderPlan(_ route: StateTransitionRoutePlan) -> StateTransitionRenderPlan {
        var b = StateRenderBuilder(route: route)
        let from = route.from
        let to = route.to
        let transition = route.transition

        switch route.kind {
        case .self(let lane):
            if from.width <= 1 || from.height <= 1 {
                let railX = from.left + 4 + lane * 4
                let railY = from.top + 2 + lane * 2
                b.addHorizontalLine(fromX: from.left + 1, toX: railX - 1, y: from.top, direction: 1)
                b.addCell(StateTransitionRenderCell(x: railX, y: from.top, char: "╮"))
                b.addVerticalLine(x: railX, fromY: from.top + 1, toY: railY - 1, direction: 1)
                b.addCell(StateTransitionRenderCell(x: railX, y: railY, char: "╯"))
                b.addHorizontalLine(fromX: railX - 1, toX: from.left + 1, y: railY, direction: -1)
                b.addCell(StateTransitionRenderCell(x: from.left, y: railY, char: "╰"))
                var y = railY - 1
                while y > from.top + 1 { b.addCell(StateTransitionRenderCell(x: from.left, y: y, char: "│")); y -= 1 }
                b.addCell(StateTransitionRenderCell(x: from.left, y: from.top + 1, arrowDirection: .up))
                b.addPathPoint(from.left, from.top)
                if !transition.label.isEmpty {
                    b.addLabel(x: railX + 2, y: lane == 0 ? from.top + 1 : railY - 1, text: transition.label)
                }
            } else {
                let sourceX = from.left + max(2, floorDiv(from.width, 3))
                let bottomY = from.top + from.height - 1
                let railY = bottomY + 2 + lane * 3
                let targetX = max(sourceX + 3, from.left + min(from.width - 3, ceilDiv(from.width * 2, 3))) + lane * 4
                b.addBottomDeparture(from, x: sourceX)
                b.addVerticalLine(x: sourceX, fromY: bottomY + 1, toY: railY - 1, direction: 1)
                b.addCell(StateTransitionRenderCell(x: sourceX, y: railY, char: "╰"))
                if sourceX + 1 < targetX {
                    for x in (sourceX + 1)..<targetX { b.addCell(StateTransitionRenderCell(x: x, y: railY, char: "─")) }
                }
                b.addCell(StateTransitionRenderCell(x: targetX, y: railY, char: "╯"))
                var y = railY - 1
                while y > bottomY + 1 { b.addCell(StateTransitionRenderCell(x: targetX, y: y, char: "│")); y -= 1 }
                b.addCell(StateTransitionRenderCell(x: targetX, y: bottomY + 1, arrowDirection: .up))
                if !transition.label.isEmpty {
                    b.addLabel(x: targetX + 2, y: lane == 0 ? bottomY + 1 : railY - 1, text: transition.label)
                }
            }

        case .horizontalForward(let leftToRight):
            let y = from.centerY
            if leftToRight { b.addRightDeparture(from) } else { b.addLeftDeparture(from) }
            let step = leftToRight ? 1 : -1
            let startX = leftToRight ? from.left + from.width : from.left - 1
            let endX = leftToRight ? to.left - 1 : to.left + to.width
            b.addHorizontalLine(fromX: startX, toX: endX - step, y: y, direction: step)
            if route.targetIsHiddenMarker {
                b.addCell(StateTransitionRenderCell(x: endX, y: y, char: "─"))
            } else {
                b.addCell(StateTransitionRenderCell(x: endX, y: y, arrowDirection: leftToRight ? .right : .left))
            }
            if route.targetIsChoice || route.targetIsHiddenMarker { b.addPathPoint(to.left, y) }
            if !transition.label.isEmpty {
                let metrics = measureStateTransitionLabel(transition.label)
                let labelX = min(startX, endX) + max(1, floorDiv(abs(endX - startX) - metrics.width, 2))
                b.addLabel(x: labelX, y: max(0, y - metrics.height), text: transition.label)
            }

        case .bottomFeedback(let railY, let approachX), .bottomParallel(let railY, let approachX):
            let sourceX = from.centerX
            let targetX = to.width > 1 ? (sourceX > to.centerX ? to.left + 1 : to.left + to.width - 2) : to.centerX
            let targetRailCutsSource = targetX >= from.left && targetX <= from.left + from.width - 1
            let railTargetX = targetRailCutsSource ? max(from.left + from.width, to.left + to.width) + 2 : approachX
            let sourceBottomY = from.top + from.height
            let targetBottomY = to.top + to.height
            b.addBottomDeparture(from, x: sourceX)
            b.addVerticalLine(x: sourceX, fromY: sourceBottomY, toY: railY - 1, direction: 1)
            b.addCell(StateTransitionRenderCell(x: sourceX, y: railY, char: sourceX > railTargetX ? "╯" : "╰"))
            if sourceX != railTargetX {
                let hStep = sourceX < railTargetX ? 1 : -1
                var x = sourceX + hStep
                while x != railTargetX {
                    b.addCell(StateTransitionRenderCell(x: x, y: railY, char: "─"))
                    x += hStep
                }
            }
            b.addCell(StateTransitionRenderCell(x: railTargetX, y: railY, char: sourceX > railTargetX ? "╰" : "╯"))
            var y = railY - 1
            while y > targetBottomY {
                b.addCell(StateTransitionRenderCell(x: railTargetX, y: y, char: "│"))
                y -= 1
            }
            if railTargetX != targetX {
                b.addCell(StateTransitionRenderCell(x: railTargetX, y: targetBottomY, char: railTargetX < targetX ? "╭" : "╮"))
                let hStep = railTargetX < targetX ? 1 : -1
                var x = railTargetX + hStep
                while x != targetX {
                    b.addCell(StateTransitionRenderCell(x: x, y: targetBottomY, char: "─"))
                    x += hStep
                }
            }
            if route.targetIsHiddenMarker {
                b.addCell(StateTransitionRenderCell(x: targetX, y: targetBottomY, char: "│"))
            } else {
                b.addCell(StateTransitionRenderCell(x: targetX, y: targetBottomY, arrowDirection: .up))
            }
            if route.targetIsChoice || route.targetIsHiddenMarker { b.addPathPoint(to.left, to.top) }
            if !transition.label.isEmpty {
                let metrics = measureStateTransitionLabel(transition.label)
                let horizontalRoom = abs(sourceX - railTargetX) - 2
                let labelX = metrics.width <= horizontalRoom
                    ? min(sourceX, railTargetX) + max(1, floorDiv(abs(sourceX - railTargetX) - metrics.width, 2))
                    : railTargetX + 2
                b.addLabel(x: labelX, y: max(0, railY - metrics.height), text: transition.label)
            }

        case .topFeedback(let railY):
            let sourceX = from.centerX
            let targetX = to.width > 1 ? (sourceX > to.centerX ? to.left + to.width - 2 : to.left + 1) : to.centerX
            let sourceTopY = from.top - 1
            let targetTopY = to.top - 1
            b.addTopDeparture(from, x: sourceX)
            b.addVerticalLine(x: sourceX, fromY: sourceTopY, toY: railY + 1, direction: -1)
            b.addCell(StateTransitionRenderCell(x: sourceX, y: railY, char: sourceX > targetX ? "╮" : "╭"))
            if sourceX != targetX {
                let hStep = sourceX < targetX ? 1 : -1
                var x = sourceX + hStep
                while x != targetX {
                    b.addCell(StateTransitionRenderCell(x: x, y: railY, char: "─"))
                    x += hStep
                }
            }
            b.addCell(StateTransitionRenderCell(x: targetX, y: railY, char: sourceX > targetX ? "╭" : "╮"))
            if railY + 1 < targetTopY {
                for y in (railY + 1)..<targetTopY { b.addCell(StateTransitionRenderCell(x: targetX, y: y, char: "│")) }
            }
            if route.targetIsHiddenMarker {
                b.addCell(StateTransitionRenderCell(x: targetX, y: targetTopY, char: "│"))
            } else {
                b.addCell(StateTransitionRenderCell(x: targetX, y: targetTopY, arrowDirection: .down))
            }
            if route.targetIsChoice || route.targetIsHiddenMarker { b.addPathPoint(to.left, to.top) }
            if !transition.label.isEmpty {
                let metrics = measureStateTransitionLabel(transition.label)
                let horizontalRoom = abs(sourceX - targetX) - 2
                let labelX = metrics.width <= horizontalRoom
                    ? min(sourceX, targetX) + max(1, floorDiv(abs(sourceX - targetX) - metrics.width, 2))
                    : targetX + 2
                b.addLabel(x: labelX, y: railY - metrics.height, text: transition.label)
            }

        case .sideParallel(let railX, let targetApproach):
            let startX = from.left + from.width
            let startY = from.centerY
            let endY = targetApproach == .top ? to.top - 2 : (targetApproach == .bottom ? to.top + to.height + 1 : to.centerY)
            let verticalStep = startY <= endY ? 1 : -1
            b.addRightDeparture(from)
            b.addHorizontalLine(fromX: startX, toX: railX - 1, y: startY, direction: 1)
            b.addCell(StateTransitionRenderCell(x: railX, y: startY, char: verticalStep == 1 ? "╮" : "╯"))
            var y = startY + verticalStep
            while y != endY {
                b.addCell(StateTransitionRenderCell(x: railX, y: y, char: "│"))
                y += verticalStep
            }
            b.addCell(StateTransitionRenderCell(x: railX, y: endY, char: verticalStep == 1 ? "╯" : "╮"))
            if let approach = targetApproach {
                let targetX = stateInnerConnectorX(to, preferredX: from.centerX)
                var x = railX - 1
                while x > targetX { b.addCell(StateTransitionRenderCell(x: x, y: endY, char: "─")); x -= 1 }
                b.addCell(StateTransitionRenderCell(x: targetX, y: endY, char: approach == .top ? "╭" : "╰"))
                b.addCell(StateTransitionRenderCell(
                    x: targetX,
                    y: approach == .top ? endY + 1 : endY - 1,
                    arrowDirection: approach == .top ? .down : .up
                ))
                if route.targetIsChoice || route.targetIsHiddenMarker { b.addPathPoint(to.left, to.top) }
                if !transition.label.isEmpty {
                    let metrics = measureStateTransitionLabel(transition.label)
                    b.addLabel(x: railX + 2, y: max(0, floorDiv(startY + to.centerY - metrics.height + 1, 2)), text: transition.label)
                }
            } else {
                let endX = to.left + to.width
                var x = railX - 1
                while x > endX { b.addCell(StateTransitionRenderCell(x: x, y: endY, char: "─")); x -= 1 }
                if route.targetIsHiddenMarker {
                    b.addCell(StateTransitionRenderCell(x: endX, y: endY, char: "─"))
                } else {
                    b.addCell(StateTransitionRenderCell(x: endX, y: endY, arrowDirection: .left))
                }
                if route.targetIsChoice || route.targetIsHiddenMarker { b.addPathPoint(to.left, to.top) }
                if !transition.label.isEmpty {
                    let metrics = measureStateTransitionLabel(transition.label)
                    b.addLabel(x: railX + 2, y: max(0, floorDiv(startY + endY - metrics.height + 1, 2)), text: transition.label)
                }
            }

        case .verticalElbow(let hasReverse, let offsetConnector):
            let topToBottom = from.centerY < to.centerY
            let offset = offsetConnector ? (topToBottom ? -2 : 2) : 0
            let startX = stateInnerConnectorX(from, preferredX: from.centerX + offset)
            let endX = stateInnerConnectorX(to, preferredX: to.centerX + offset)
            let startY = topToBottom ? from.top + from.height : from.top - 1
            let endY = topToBottom ? to.top - 1 : to.top + to.height
            let verticalStep = topToBottom ? 1 : -1
            if topToBottom { b.addBottomDeparture(from, x: startX) } else { b.addTopDeparture(from, x: startX) }
            let availableApproach = max(0, abs(endY - startY) - 1)
            let bendY = startX == endX ? endY : (topToBottom ? endY - verticalStep * min(2, availableApproach) : startY)
            let targetApproachLength = abs(endY - bendY)
            let hasTargetApproach = targetApproachLength > 0
            if startY != bendY { b.addVerticalLine(x: startX, fromY: startY, toY: bendY - verticalStep, direction: verticalStep) }
            if startX != endX {
                let hStep = startX < endX ? 1 : -1
                b.addCell(StateTransitionRenderCell(
                    x: startX,
                    y: bendY,
                    char: topToBottom ? (startX < endX ? "╰" : "╯") : (startX < endX ? "╭" : "╮")
                ))
                var x = startX + hStep
                while x != endX {
                    b.addCell(StateTransitionRenderCell(x: x, y: bendY, char: "─"))
                    x += hStep
                }
                if hasTargetApproach {
                    b.addCell(StateTransitionRenderCell(
                        x: endX,
                        y: bendY,
                        char: topToBottom ? (startX < endX ? "╮" : "╭") : (startX < endX ? "╯" : "╰")
                    ))
                    if targetApproachLength > 1 {
                        for distance in 1..<targetApproachLength {
                            b.addCell(StateTransitionRenderCell(x: endX, y: bendY + verticalStep * distance, char: "│"))
                        }
                    }
                }
            }
            if route.targetIsHiddenMarker {
                let targetChar: String = (hasTargetApproach || startX == endX) ? "│" : (topToBottom ? "┬" : "┴")
                b.addCell(StateTransitionRenderCell(x: endX, y: endY, char: targetChar))
            } else {
                b.addCell(StateTransitionRenderCell(x: endX, y: endY, arrowDirection: topToBottom ? .down : .up))
            }
            if route.targetIsChoice || route.targetIsHiddenMarker { b.addPathPoint(to.left, to.top) }
            if !transition.label.isEmpty {
                let metrics = measureStateTransitionLabel(transition.label)
                if topToBottom {
                    let leftLabelX = startX - metrics.width - 2
                    let labelX: Int
                    if from.width == 1 && abs(endX - startX) >= metrics.width + 2 {
                        labelX = min(startX, endX) + floorDiv(abs(endX - startX) - metrics.width, 2)
                    } else if hasReverse || endX < startX {
                        labelX = leftLabelX >= 0 ? leftLabelX : startX + 4
                    } else {
                        labelX = startX + 2
                    }
                    b.addLabel(x: labelX, y: hasTargetApproach ? max(0, bendY - metrics.height) : min(startY + 1, endY), text: transition.label)
                } else {
                    let labelX = min(startX, endX) + max(1, floorDiv(abs(endX - startX) - metrics.width, 2))
                    b.addLabel(
                        x: startX == endX ? startX + 3 : labelX,
                        y: hasTargetApproach ? max(0, bendY - metrics.height) : max(0, startY),
                        text: transition.label
                    )
                }
            }

        case .vertical:
            let topToBottom = from.centerY <= to.centerY
            let x = from.centerX
            let startY = topToBottom ? from.top + from.height : from.top - 1
            let endY = topToBottom ? to.top - 1 : to.top + to.height
            let step = topToBottom ? 1 : -1
            if topToBottom { b.addBottomDeparture(from, x: x) } else { b.addTopDeparture(from, x: x) }
            if startY != endY { b.addVerticalLine(x: x, fromY: startY, toY: endY - step, direction: step) }
            if route.targetIsHiddenMarker {
                b.addCell(StateTransitionRenderCell(x: x, y: endY, char: "│"))
            } else {
                b.addCell(StateTransitionRenderCell(x: x, y: endY, arrowDirection: topToBottom ? .down : .up))
            }
            if route.targetIsChoice || route.targetIsHiddenMarker { b.addPathPoint(to.left, to.top) }
            if !transition.label.isEmpty {
                b.addLabel(x: x + 2, y: min(startY, endY) + 1, text: transition.label)
            }
        }

        return StateTransitionRenderPlan(route: b.route, cells: b.cells, path: b.path, label: b.label)
    }

    // MARK: - Body-Safe Path Repair & Label Placement

    private static func statePointIsInsideBounds(_ pt: StateTransitionPathPoint, bounds: StateDiagramBoxBounds) -> Bool {
        pt.x >= bounds.left && pt.x < bounds.left + bounds.width
            && pt.y >= bounds.top && pt.y < bounds.top + bounds.height
    }

    private static func stateRouteIntersectsUnrelatedState(
        _ plan: StateTransitionRenderPlan,
        diagram: StateVisibleDiagram,
        bounds: [String: StateDiagramBoxBounds],
        noteBounds: [StateDiagramNoteBounds]
    ) throws -> Bool {
        for state in diagram.states {
            if state.id == plan.route.transition.from || state.id == plan.route.transition.to || isHiddenCompositeMarker(state) { continue }
            if let bound = bounds[state.id], plan.path.contains(where: { statePointIsInsideBounds($0, bounds: bound) }) {
                return true
            }
        }
        for noteBound in noteBounds {
            if plan.path.contains(where: { statePointIsInsideBounds($0, bounds: noteBound.boxBounds) }) {
                return true
            }
            guard let target = bounds[noteBound.note.target] else { continue }
            let connector = try spatialPathClaim(
                id: "note-connector:\(noteBound.id)",
                owner: "note-connector:\(noteBound.id)",
                role: .boundary,
                points: stateDiagramNoteConnector(noteBound, target: target).points
            )
            for pt in plan.path {
                if connector.spans.contains(where: { $0.y == pt.y && pt.x >= $0.fromX && pt.x <= $0.toX }) {
                    return true
                }
            }
        }
        return false
    }

    private static func stateConnectionDirection(_ from: StateTransitionPathPoint, _ to: StateTransitionPathPoint) -> DiagramDirection {
        let dx = to.x - from.x
        let dy = to.y - from.y
        if abs(dx) >= abs(dy) && dx != 0 { return dx > 0 ? .right : .left }
        if dy != 0 { return dy > 0 ? .down : .up }
        return .right
    }

    private static func stateFindBodySafePath(
        start: StateTransitionPathPoint,
        end: StateTransitionPathPoint,
        diagram: StateVisibleDiagram,
        bounds: [String: StateDiagramBoxBounds],
        plan: StateTransitionRenderPlan,
        search: StateSearchSpace,
        budget: StateSearchBudget
    ) -> [StateTransitionPathPoint]? {
        let margin = max(8, bounds.count * 2)
        let compositeId = stateInnermostCommonComposite(diagram, transition: plan.route.transition)
        let composite = compositeId.flatMap { bounds[$0] }
        let pathMinX = plan.path.map(\.x).min() ?? 0
        let pathMinY = plan.path.map(\.y).min() ?? 0
        let pathMaxX = plan.path.map(\.x).max() ?? 0
        let pathMaxY = plan.path.map(\.y).max() ?? 0

        let sMinX = composite.map { $0.left + 1 } ?? (search.minX - margin)
        let sMinY = composite.map { $0.top + 1 } ?? (min(search.minY, pathMinY) - margin)
        let sMaxX = composite.map { $0.left + $0.width - 2 } ?? (max(search.maxX, pathMaxX) + margin)
        let sMaxY = composite.map { $0.top + $0.height - 2 } ?? (max(search.maxY, pathMaxY) + margin)

        func isFree(_ pt: DiagramPoint) -> Bool {
            pt.x >= sMinX && pt.x <= sMaxX && pt.y >= sMinY && pt.y <= sMaxY && !search.blocked.contains(pt)
        }

        var directCandidates: [[DiagramPoint]] = [
            [start, point(start.x, end.y), end],
            [start, point(end.x, start.y), end],
        ]
        for offset in 1...4 {
            directCandidates.append([start, point(start.x, pathMinY - offset), point(end.x, pathMinY - offset), end])
            directCandidates.append([start, point(start.x, pathMaxY + offset), point(end.x, pathMaxY + offset), end])
            directCandidates.append([start, point(pathMinX - offset, start.y), point(pathMinX - offset, end.y), end])
            directCandidates.append([start, point(pathMaxX + offset, start.y), point(pathMaxX + offset, end.y), end])
        }

        var bestDirect: [DiagramPoint]?
        for cand in directCandidates {
            let expanded = orthogonalPathPoints(cand)
            if expanded.allSatisfy(isFree) {
                if bestDirect == nil || expanded.count < bestDirect!.count {
                    bestDirect = expanded
                }
            }
        }
        if let bestDirect { return bestDirect }
        return findStateManhattanPath(
            starts: [start],
            goal: end,
            space: search,
            minX: sMinX,
            minY: sMinY,
            maxX: sMaxX,
            maxY: sMaxY,
            budget: budget
        )
    }

    private static func stateRenderBodySafePlan(
        _ plan: StateTransitionRenderPlan,
        safePath: [StateTransitionPathPoint],
        prefix: [StateTransitionPathPoint],
        suffix: [StateTransitionPathPoint],
        sourceChar: String? = nil
    ) -> StateTransitionRenderPlan {
        let prefixKeys = Set(prefix)
        var cells: [StateTransitionRenderCell]
        if let sourceChar {
            cells = prefix.map { StateTransitionRenderCell(x: $0.x, y: $0.y, char: sourceChar) }
        } else {
            cells = plan.cells.filter { prefixKeys.contains(point($0.x, $0.y)) }
        }
        let fullPath = prefix + safePath + suffix
        let previous = prefix.last
        for (index, pt) in safePath.enumerated() {
            if index == safePath.count - 1 {
                let targetDir = stateConnectionDirection(pt, point(plan.route.to.centerX, plan.route.to.centerY))
                if plan.route.targetIsHiddenMarker {
                    cells.append(StateTransitionRenderCell(x: pt.x, y: pt.y, char: (targetDir == .left || targetDir == .right) ? "─" : "│"))
                } else {
                    cells.append(StateTransitionRenderCell(x: pt.x, y: pt.y, arrowDirection: targetDir))
                }
                continue
            }
            let before = index == 0 ? previous : safePath[index - 1]
            let after = safePath[index + 1]
            var connections = Set<DiagramDirection>()
            if let before { connections.insert(stateConnectionDirection(pt, before)) }
            connections.insert(stateConnectionDirection(pt, after))
            cells.append(StateTransitionRenderCell(x: pt.x, y: pt.y, char: diagramLineGlyph(connections, cornerStyle: .rounded)))
        }
        return StateTransitionRenderPlan(route: plan.route, cells: cells, path: fullPath, label: plan.label, pathRepaired: true)
    }

    private static func stateRoutePorts(_ bounds: StateDiagramBoxBounds) -> [(outside: DiagramPoint, border: DiagramPoint, char: String)] {
        [
            (point(bounds.centerX, bounds.top - 1), point(bounds.centerX, bounds.top), BorderChars.rounded.bottomT),
            (point(bounds.centerX, bounds.top + bounds.height), point(bounds.centerX, bounds.top + bounds.height - 1), BorderChars.rounded.topT),
            (point(bounds.left - 1, bounds.centerY), point(bounds.left, bounds.centerY), BorderChars.rounded.rightT),
            (point(bounds.left + bounds.width, bounds.centerY), point(bounds.left + bounds.width - 1, bounds.centerY), BorderChars.rounded.leftT),
        ].filter { $0.outside.x >= 0 }
    }

    private static func stateAlternateBodySafePlan(
        _ plan: StateTransitionRenderPlan,
        diagram: StateVisibleDiagram,
        bounds: [String: StateDiagramBoxBounds],
        noteBounds: [StateDiagramNoteBounds],
        search: StateSearchSpace,
        budget: StateSearchBudget
    ) throws -> StateTransitionRenderPlan {
        var best: StateTransitionRenderPlan?
        for source in stateRoutePorts(plan.route.from) {
            for target in stateRoutePorts(plan.route.to) {
                guard let safePath = stateFindBodySafePath(
                    start: source.outside,
                    end: target.outside,
                    diagram: diagram,
                    bounds: bounds,
                    plan: plan,
                    search: search,
                    budget: budget
                ) else { continue }
                let prefix = (plan.route.from.width > 1 && plan.route.from.height > 1) ? [source.border] : []
                let suffix = (plan.route.targetIsChoice || plan.route.targetIsHiddenMarker) ? [point(plan.route.to.left, plan.route.to.top)] : []
                let repaired = stateRenderBodySafePlan(plan, safePath: safePath, prefix: prefix, suffix: suffix, sourceChar: source.char)
                if !(try stateRouteIntersectsUnrelatedState(repaired, diagram: diagram, bounds: bounds, noteBounds: noteBounds)) {
                    if best == nil || repaired.path.count < best!.path.count {
                        best = repaired
                    }
                }
            }
        }
        return best ?? plan
    }

    private static func stateBodySafeTransitionPlan(
        _ plan: StateTransitionRenderPlan,
        diagram: StateVisibleDiagram,
        bounds: [String: StateDiagramBoxBounds],
        noteBounds: [StateDiagramNoteBounds],
        search: StateSearchSpace,
        budget: StateSearchBudget,
        forceRepair: Bool = false
    ) throws -> StateTransitionRenderPlan {
        if !forceRepair {
            if !(try stateRouteIntersectsUnrelatedState(plan, diagram: diagram, bounds: bounds, noteBounds: noteBounds)) {
                return plan
            }
        }
        guard let sourceOutsideIdx = plan.path.firstIndex(where: { !statePointIsInsideBounds($0, bounds: plan.route.from) }),
              let targetOutsideIdx = plan.path.lastIndex(where: { !statePointIsInsideBounds($0, bounds: plan.route.to) }),
              targetOutsideIdx >= sourceOutsideIdx
        else { return plan }

        guard let safePath = stateFindBodySafePath(
            start: plan.path[sourceOutsideIdx],
            end: plan.path[targetOutsideIdx],
            diagram: diagram,
            bounds: bounds,
            plan: plan,
            search: search,
            budget: budget
        ) else {
            return try stateAlternateBodySafePlan(plan, diagram: diagram, bounds: bounds, noteBounds: noteBounds, search: search, budget: budget)
        }

        let prefix = Array(plan.path[..<sourceOutsideIdx])
        let suffix = Array(plan.path[(targetOutsideIdx + 1)...])
        let repaired = stateRenderBodySafePlan(plan, safePath: safePath, prefix: prefix, suffix: suffix)
        if safePath.count <= plan.path.count + 4 { return repaired }
        let alternate = try stateAlternateBodySafePlan(plan, diagram: diagram, bounds: bounds, noteBounds: noteBounds, search: search, budget: budget)
        return (alternate != plan && alternate.path.count < repaired.path.count) ? alternate : repaired
    }

    private static func stateLabelDistanceToPath(x: Int, y: Int, width: Int, height: Int, path: [StateTransitionPathPoint]) -> Int {
        var best = Int.max
        for pt in path {
            let dx = pt.x < x ? x - pt.x : (pt.x >= x + width ? pt.x - (x + width - 1) : 0)
            let dy = pt.y < y ? y - pt.y : (pt.y >= y + height ? pt.y - (y + height - 1) : 0)
            best = min(best, dx + dy)
        }
        return best
    }

    private static func stateLabelCandidates(_ plan: StateTransitionRenderPlan, width: Int, height: Int) -> [DiagramPoint] {
        var order: [DiagramPoint] = []
        var seen = Set<DiagramPoint>()
        func add(_ x: Int, _ y: Int) {
            let pt = point(x, y)
            if seen.insert(pt).inserted { order.append(pt) }
        }
        if let lbl = plan.label,
           plan.pathRepaired != true || stateLabelDistanceToPath(x: lbl.x, y: lbl.y, width: width, height: height, path: plan.path) <= 4
        {
            add(lbl.x, lbl.y)
        }
        for pt in plan.path {
            add(pt.x + 2, pt.y - floorDiv(height, 2))
            add(pt.x - width - 2, pt.y - floorDiv(height, 2))
            add(pt.x - floorDiv(width, 2), pt.y - height - 1)
            add(pt.x - floorDiv(width, 2), pt.y + 2)
        }
        let prefX = plan.label?.x ?? plan.path.first?.x ?? 0
        let prefY = plan.label?.y ?? plan.path.first?.y ?? 0
        return order.enumerated().sorted { lhs, rhs in
            let ld = abs(lhs.element.x - prefX) + abs(lhs.element.y - prefY)
            let rd = abs(rhs.element.x - prefX) + abs(rhs.element.y - prefY)
            if ld != rd { return ld < rd }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func statePlaceTransitionLabels(
        _ plans: [StateTransitionRenderPlan],
        diagram: StateVisibleDiagram,
        bounds: [String: StateDiagramBoxBounds],
        noteBounds: [StateDiagramNoteBounds]
    ) throws -> [StateTransitionRenderPlan] {
        var initialClaims: [SpatialClaim] = []
        for state in diagram.states {
            if let bound = bounds[state.id], !isHiddenCompositeMarker(state) {
                initialClaims.append(try spatialRectClaim(id: "state:\(state.id)", owner: "state:\(state.id)", role: .body, bounds: bound.diagramBounds))
            }
        }
        for (index, plan) in plans.enumerated() {
            initialClaims.append(try spatialPathClaim(id: "route:\(index)", owner: "route:\(index)", role: .route, points: plan.path))
        }
        for composite in diagram.composites {
            guard let bound = bounds[composite.id] else { continue }
            initialClaims.append(try spatialPathClaim(
                id: "composite:\(composite.id)",
                owner: "composite:\(composite.id)",
                role: .boundary,
                points: [
                    point(bound.left, bound.top),
                    point(bound.left + bound.width - 1, bound.top),
                    point(bound.left + bound.width - 1, bound.top + bound.height - 1),
                    point(bound.left, bound.top + bound.height - 1),
                    point(bound.left, bound.top),
                ]
            ))
        }
        for noteBound in noteBounds {
            initialClaims.append(try spatialRectClaim(id: "note:\(noteBound.id)", owner: "note:\(noteBound.id)", role: .body, bounds: noteBound.diagramBounds))
            if let target = bounds[noteBound.note.target] {
                initialClaims.append(try spatialPathClaim(
                    id: "note-connector:\(noteBound.id)",
                    owner: "note-connector:\(noteBound.id)",
                    role: .boundary,
                    points: stateDiagramNoteConnector(noteBound, target: target).points
                ))
            }
        }
        var space = try SpatialIndex.empty().add(claims: initialClaims)

        var placed: [Int: StateTransitionRenderPlan] = [:]
        var endpointCounts: [String: Int] = [:]
        for plan in plans {
            let key = "\(plan.route.transition.from)\u{0000}\(plan.route.transition.to)"
            endpointCounts[key, default: 0] += 1
        }
        let placementOrder = (0..<plans.count).sorted { l, r in
            let lr = plans[l].pathRepaired == true ? 1 : 0
            let rr = plans[r].pathRepaired == true ? 1 : 0
            if lr != rr { return lr < rr }
            return l < r
        }

        for planIndex in placementOrder {
            let plan = plans[planIndex]
            guard let lbl = plan.label else {
                placed[planIndex] = plan
                continue
            }
            let width = max(1, lbl.lines.map(diagramTextWidth).max() ?? 1)
            let height = lbl.lines.count
            let endpointKey = "\(plan.route.transition.from)\u{0000}\(plan.route.transition.to)"
            let needsLaneClearance = (endpointCounts[endpointKey] ?? 0) > 1
            let statePadding = (needsLaneClearance || height > 1) ? 1 : 0

            let isSelfKind: Bool
            if case .self = plan.route.kind { isSelfKind = true } else { isSelfKind = false }
            let isVerticalKind: Bool
            if case .vertical = plan.route.kind { isVerticalKind = true } else { isVerticalKind = false }
            let isSideParallelKind: Bool
            if case .sideParallel = plan.route.kind { isSideParallelKind = true } else { isSideParallelKind = false }

            let sharesLoopCorridor = plans.contains { cand in
                guard cand.route.transition.from == plan.route.transition.from else { return false }
                if isSelfKind {
                    if case .vertical = cand.route.kind { return true }
                    return false
                } else {
                    if case .self = cand.route.kind { return true }
                    return false
                }
            }
            let corridorTop: Int?
            if isSideParallelKind && plans.enumerated().contains(where: { $0.offset != planIndex && $0.element.route.transition.to == plan.route.transition.to }) {
                corridorTop = plan.path.map(\.y).min()
            } else if sharesLoopCorridor && (isSelfKind || (isVerticalKind && plan.route.from.centerY < plan.route.to.centerY)) {
                corridorTop = plan.route.from.top + plan.route.from.height
            } else {
                corridorTop = nil
            }
            let corridorBottom = corridorTop == nil ? nil : plan.path.map(\.y).max()
            let strictRoute = plan.pathRepaired == true || isSideParallelKind || needsLaneClearance || corridorTop != nil
            let routeClearance = strictRoute ? SpatialClearance(x: 1, y: 0) : SpatialClearance(x: 0, y: 0)
            let policy = SpatialCollisionPolicy(clearance: .byRole([
                .body: SpatialClearance(x: statePadding, y: statePadding),
                .label: SpatialClearance(x: 1, y: 1),
                .route: routeClearance,
            ]))

            func labelClaim(_ x: Int, _ y: Int) throws -> SpatialClaim {
                try spatialRectClaim(id: "label:\(planIndex)", owner: "label:\(planIndex)", role: .label, left: x, top: y, width: width, height: height)
            }

            func isClear(_ x: Int, _ y: Int) throws -> Bool {
                if x < 0 || y < 0 { return false }
                if let ct = corridorTop, let cb = corridorBottom, y < ct || y > cb { return false }
                return try space.isFree(try labelClaim(x, y), policy: policy)
            }

            let candidates = stateLabelCandidates(plan, width: width, height: height)
            var nearby: DiagramPoint?
            for cand in candidates {
                if strictRoute && stateLabelDistanceToPath(x: cand.x, y: cand.y, width: width, height: height, path: plan.path) < 2 {
                    continue
                }
                if try isClear(cand.x, cand.y) {
                    nearby = cand
                    break
                }
            }

            var x = nearby?.x ?? candidates.first?.x ?? lbl.x
            var y = nearby?.y ?? candidates.first?.y ?? lbl.y
            if nearby == nil {
                spiral: for distance in 1..<500 {
                    for dx in (-distance)...distance {
                        let dy = distance - abs(dx)
                        let ys = dy == 0 ? [y] : [y - dy, y + dy]
                        for candY in ys {
                            let candX = x + dx
                            let pathDist = stateLabelDistanceToPath(x: candX, y: candY, width: width, height: height, path: plan.path)
                            if pathDist < 2 || pathDist > 8 { continue }
                            if try isClear(candX, candY) {
                                x = candX
                                y = candY
                                break spiral
                            }
                        }
                    }
                }
            }
            if !(try isClear(x, y)) {
                fallback: for distance in 1..<500 {
                    for dx in (-distance)...distance {
                        let dy = distance - abs(dx)
                        let ys = dy == 0 ? [y] : [y - dy, y + dy]
                        for candY in ys {
                            let candX = x + dx
                            if try isClear(candX, candY) {
                                x = candX
                                y = candY
                                break fallback
                            }
                        }
                    }
                }
            }
            if try isClear(x, y) {
                space = try space.add(try labelClaim(x, y))
            }
            var updated = plan
            updated.label = StateTransitionRenderLabel(x: x, y: y, lines: lbl.lines)
            placed[planIndex] = updated
        }
        return (0..<plans.count).map { placed[$0] ?? plans[$0] }
    }

    private static func stateTransitionsHaveDisjointEndpoints(_ left: StateTransitionRenderPlan, _ right: StateTransitionRenderPlan) -> Bool {
        let lFrom = left.route.transition.from
        let lTo = left.route.transition.to
        let rFrom = right.route.transition.from
        let rTo = right.route.transition.to
        return rFrom != lFrom && rFrom != lTo && rTo != lFrom && rTo != lTo
    }

    private static func stateTransitionsAreReciprocal(_ left: StateTransitionRenderPlan, _ right: StateTransitionRenderPlan) -> Bool {
        left.route.transition.from == right.route.transition.to && left.route.transition.to == right.route.transition.from
    }

    private static func statePathsIntersect(_ left: [StateTransitionPathPoint], _ right: [StateTransitionPathPoint]) -> Bool {
        let occupied = Set(left)
        return right.contains { occupied.contains($0) }
    }

    private static func stateTransitionObstacles(
        _ diagram: StateVisibleDiagram,
        bounds: [String: StateDiagramBoxBounds],
        noteBounds: [StateDiagramNoteBounds]
    ) throws -> SpatialIndex {
        var claims: [SpatialClaim] = []
        for state in diagram.states {
            if let bound = bounds[state.id], !isHiddenCompositeMarker(state) {
                claims.append(try spatialRectClaim(id: "state:\(state.id)", owner: "state:\(state.id)", role: .body, bounds: bound.diagramBounds))
            }
        }
        for noteBound in noteBounds {
            claims.append(try spatialRectClaim(id: "note:\(noteBound.id)", owner: "note:\(noteBound.id)", role: .body, bounds: noteBound.diagramBounds))
            if let target = bounds[noteBound.note.target] {
                claims.append(try spatialPathClaim(
                    id: "note-connector:\(noteBound.id)",
                    owner: "note-connector:\(noteBound.id)",
                    role: .boundary,
                    points: stateDiagramNoteConnector(noteBound, target: target).points
                ))
            }
        }
        return try SpatialIndex.empty().add(claims: claims)
    }

    // parity: merman/src/state/routing.ts#createStateTransitionRenderPlans [status=implemented hash=432f385d6156]
    public static func createStateTransitionRenderPlans(
        _ diagram: StateVisibleDiagram,
        bounds: [String: StateDiagramBoxBounds],
        feedbackLaneY: Int,
        options: StateTransitionRenderOptions = StateTransitionRenderOptions()
    ) throws -> [StateTransitionRenderPlan] {
        let noteBounds = options.noteBounds ?? []
        let budget = options.searchBudget ?? createStateSearchBudget()
        let plans = try createStateTransitionRoutePlans(
            diagram,
            bounds: bounds,
            feedbackLaneY: feedbackLaneY,
            feedbackTopY: options.feedbackTopY
        ).map(stateBuildRenderPlan)
        if options.repairRoutes == false {
            return try statePlaceTransitionLabels(plans, diagram: diagram, bounds: bounds, noteBounds: noteBounds)
        }
        let baseObstacles = try stateTransitionObstacles(diagram, bounds: bounds, noteBounds: noteBounds)
        var repaired: [StateTransitionRenderPlan] = []
        repaired.reserveCapacity(plans.count)
        for (index, plan) in plans.enumerated() {
            let disjoint = repaired.filter { stateTransitionsHaveDisjointEndpoints($0, plan) }
            let routeObstacles = repaired.filter { prev in
                stateTransitionsHaveDisjointEndpoints(prev, plan) || stateTransitionsAreReciprocal(prev, plan)
            }
            var obsClaims: [SpatialClaim] = []
            for (prevIdx, prev) in routeObstacles.enumerated() {
                obsClaims.append(try spatialPathClaim(
                    id: "transition:\(index):obstacle:\(prevIdx)",
                    owner: "transition:\(index):obstacle:\(prevIdx)",
                    role: .route,
                    points: prev.path
                ))
            }
            let routeSpace = createStateSearchSpace(try baseObstacles.add(claims: obsClaims))
            let forceRepair = disjoint.contains { statePathsIntersect($0.path, plan.path) }
            repaired.append(try stateBodySafeTransitionPlan(
                plan,
                diagram: diagram,
                bounds: bounds,
                noteBounds: noteBounds,
                search: routeSpace,
                budget: budget,
                forceRepair: forceRepair
            ))
        }
        return try statePlaceTransitionLabels(repaired, diagram: diagram, bounds: bounds, noteBounds: noteBounds)
    }

    // parity: merman/src/state/routing.ts#createStateTransitionJunctionPlans [status=implemented hash=9b912fcc50ff]
    public static func createStateTransitionJunctionPlans(
        _ diagram: StateVisibleDiagram,
        bounds: [String: StateDiagramBoxBounds],
        renderPlans: [StateTransitionRenderPlan]
    ) -> [StateTransitionJunctionPlan] {
        // Match render plans in order by transition value (preserving parallel transition matching)
        var plansByTransition: [StateVisibleTransition: [StateTransitionRenderPlan]] = [:]
        for plan in renderPlans {
            plansByTransition[plan.route.transition, default: []].append(plan)
        }
        var result: [StateTransitionJunctionPlan] = []
        for state in diagram.states {
            let kind: StateTransitionJunctionKind?
            if state.kind == .choice {
                kind = .choice
            } else if isHiddenCompositeMarker(state) {
                kind = .hiddenCompositeMarker
            } else {
                kind = nil
            }
            guard let kind, let stateBounds = bounds[state.id] else { continue }
            var connections = Set<DiagramDirection>()
            var matchedTransitions: [StateVisibleTransition] = []
            var usedCount: [StateVisibleTransition: Int] = [:]
            for transition in diagram.transitions {
                let idx = usedCount[transition] ?? 0
                let list = plansByTransition[transition]
                let renderPlan = (list != nil && idx < list!.count) ? list![idx] : list?.last
                usedCount[transition] = idx + 1
                var connected = false
                if transition.to == state.id {
                    if let path = renderPlan?.path, path.count >= 2 {
                        connections.insert(stateConnectionDirection(path[path.count - 1], path[path.count - 2]))
                    }
                    connected = true
                }
                if transition.from == state.id {
                    if let neighbor = renderPlan?.path.first {
                        connections.insert(stateConnectionDirection(point(stateBounds.left, stateBounds.top), neighbor))
                    }
                    connected = true
                }
                if connected { matchedTransitions.append(transition) }
            }
            result.append(StateTransitionJunctionPlan(
                state: state,
                bounds: stateBounds,
                connections: connections,
                transitions: matchedTransitions,
                kind: kind
            ))
        }
        return result
    }
}
