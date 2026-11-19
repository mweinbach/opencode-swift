import Foundation

extension Merman {
    // MARK: - Flowchart Routing (`flowchart/routing.ts`)

    private static let fcBusClearance = 3
    private static let fcNodeClearance = 2
    private static let fcRoutingCandidateBudget = 1024

    private struct FcEdgeRecord {
        let edgeIndex: Int
        let edge: FlowchartEdge
        var sourcePort: FlowchartPoint
        var targetPort: FlowchartPoint
    }

    private enum FcPortRole {
        case source
        case target
    }

    private static func fcIsVerticalDirection(_ direction: FlowchartDirection) -> Bool {
        direction == .TB || direction == .TD || direction == .BT
    }

    private static func fcVerticalTravel(_ from: FlowchartEndpointBounds, _ to: FlowchartEndpointBounds) -> DiagramDirection {
        centerCoordinate(to.diagramBounds, axis: .y) >= centerCoordinate(from.diagramBounds, axis: .y) ? .down : .up
    }

    private static func fcIsVerticalBackEdge(_ from: FlowchartEndpointBounds, _ to: FlowchartEndpointBounds, direction: FlowchartDirection) -> Bool {
        direction == .BT
            ? centerCoordinate(to.diagramBounds, axis: .y) > centerCoordinate(from.diagramBounds, axis: .y)
            : centerCoordinate(to.diagramBounds, axis: .y) < centerCoordinate(from.diagramBounds, axis: .y)
    }

    private static func fcIsHorizontalBackEdge(_ from: FlowchartEndpointBounds, _ to: FlowchartEndpointBounds, direction: FlowchartDirection) -> Bool {
        direction == .RL
            ? centerCoordinate(to.diagramBounds, axis: .x) > centerCoordinate(from.diagramBounds, axis: .x)
            : centerCoordinate(to.diagramBounds, axis: .x) < centerCoordinate(from.diagramBounds, axis: .x)
    }

    private static func fcHorizontalTravel(_ from: FlowchartEndpointBounds, _ to: FlowchartEndpointBounds, direction: FlowchartDirection) -> DiagramDirection {
        let targetIsRight = centerCoordinate(to.diagramBounds, axis: .x) > centerCoordinate(from.diagramBounds, axis: .x)
        let targetIsSameOrRight = centerCoordinate(to.diagramBounds, axis: .x) >= centerCoordinate(from.diagramBounds, axis: .x)
        if direction == .RL {
            return targetIsRight ? .right : .left
        }
        return targetIsSameOrRight ? .right : .left
    }

    private static func fcSubgraphTitleBounds(_ bounds: FlowchartSubgraphBounds) -> DiagramBounds {
        let lines = splitDiagramLines(bounds.label)
        let left = bounds.left + 2
        let top = bounds.labelSide == .top ? bounds.top : bounds.top + bounds.height - lines.count
        let width = lines.map { diagramTextWidth(" \($0) ") }.max() ?? 0
        return diagramBoundsFromRect(left, top, width, lines.count)
    }

    private static func fcClearSubgraphTitlePort(_ bounds: FlowchartEndpointBounds, port: FlowchartPoint, role: FcPortRole) -> FlowchartPoint {
        guard role == .source, case .subgraph(let sub) = bounds, !sub.label.isEmpty else { return port }
        let connector = flowchartSourceConnector(bounds, sourcePoint: port)
        let title = fcSubgraphTitleBounds(sub)
        let overlapsTitle =
            connector.y >= title.top &&
            connector.y < title.top + title.height &&
            connector.x >= title.left &&
            connector.x < title.left + title.width
        if !overlapsTitle { return port }
        let afterTitleX = title.left + title.width
        if afterTitleX <= sub.left + sub.width - 2 { return point(afterTitleX, port.y) }
        if title.left - 1 >= sub.left + 1 { return point(title.left - 1, port.y) }
        return port
    }

    private static func fcEndpointSidePoint(_ bounds: FlowchartEndpointBounds, side: DiagramSide, role: FcPortRole) -> FlowchartPoint {
        fcClearSubgraphTitlePort(bounds, port: boundsSidePoint(bounds.diagramBounds, side: side), role: role)
    }

    private static func fcVerticalBackEdgePath(
        _ from: FlowchartEndpointBounds,
        _ to: FlowchartEndpointBounds,
        leftBoundary: Int?
    ) -> [FlowchartPoint] {
        let start = fcEndpointSidePoint(from, side: .left, role: .source)
        let end = fcEndpointSidePoint(to, side: .left, role: .target)
        let farthest = afterFarthestCoordinate([start, end], axis: .x, direction: .left, clearance: fcBusClearance)
        let busX = leftBoundary.map { min(farthest, $0 - fcBusClearance * 2) } ?? farthest
        return pathViaLane(start, lane(.x, busX), end)
    }

    private static func fcVerticalForwardEdgePath(_ from: FlowchartEndpointBounds, _ to: FlowchartEndpointBounds) -> [FlowchartPoint] {
        let travel = fcVerticalTravel(from, to)
        let startSide = sideForDirection(travel)
        let endSide = oppositeSide(startSide)
        let sourceCenter = boundsCenter(from.diagramBounds)
        let targetCenter = boundsCenter(to.diagramBounds)
        let snapped = withCoordinate(
            boundsSidePoint(from.diagramBounds, side: startSide),
            axis: .x,
            value: snapCoordinate(sourceCenter.x, targetCenter.x, tolerance: 1)
        )
        let start = fcClearSubgraphTitlePort(from, port: snapped, role: .source)
        let end = fcEndpointSidePoint(to, side: endSide, role: .target)
        return orthogonalPath(start, end, preferredAxis: .y)
    }

    private static func fcHorizontalBackEdgePath(_ from: FlowchartEndpointBounds, _ to: FlowchartEndpointBounds) -> [FlowchartPoint] {
        let start = fcEndpointSidePoint(from, side: .top, role: .source)
        let end = fcEndpointSidePoint(to, side: .top, role: .target)
        let busY = afterFarthestCoordinate([start, end], axis: .y, direction: .up, clearance: fcBusClearance)
        return pathViaLane(start, lane(.y, busY), end)
    }

    private static func fcHorizontalEdgePath(
        _ from: FlowchartEndpointBounds,
        _ to: FlowchartEndpointBounds,
        direction: FlowchartDirection
    ) -> [FlowchartPoint] {
        let overlapsHorizontally = from.left < to.left + to.width && to.left < from.left + from.width
        if overlapsHorizontally { return fcVerticalForwardEdgePath(from, to) }
        if fcIsHorizontalBackEdge(from, to, direction: direction) { return fcHorizontalBackEdgePath(from, to) }
        let travel = fcHorizontalTravel(from, to, direction: direction)
        let startSide = sideForDirection(travel)
        return orthogonalPath(
            fcEndpointSidePoint(from, side: startSide, role: .source),
            fcEndpointSidePoint(to, side: oppositeSide(startSide), role: .target),
            preferredAxis: .x
        )
    }

    private static func fcSelfEdgePath(_ bounds: FlowchartEndpointBounds, laneOffset: Int = 0) -> [FlowchartPoint] {
        let start = fcEndpointSidePoint(bounds, side: .right, role: .source)
        let end = fcEndpointSidePoint(bounds, side: .bottom, role: .target)
        let rightLaneX = bounds.left + bounds.width + fcBusClearance + laneOffset
        let bottomLaneY = bounds.top + bounds.height + 1 + laneOffset
        return [start, point(rightLaneX, start.y), point(rightLaneX, bottomLaneY), point(end.x, bottomLaneY), end]
    }

    private static func fcParallelEdgePath(
        _ from: FlowchartEndpointBounds,
        _ to: FlowchartEndpointBounds,
        axis: DiagramAxis,
        laneCoordinate: Int
    ) -> [FlowchartPoint] {
        if axis == .y {
            let start = fcEndpointSidePoint(from, side: .bottom, role: .source)
            let end = fcEndpointSidePoint(to, side: .bottom, role: .target)
            return pathViaLane(start, lane(.y, laneCoordinate), end)
        }
        let start = fcEndpointSidePoint(from, side: .right, role: .source)
        let end = fcEndpointSidePoint(to, side: .right, role: .target)
        return pathViaLane(start, lane(.x, laneCoordinate), end)
    }

    private static func fcLabelHeight(_ edge: FlowchartEdge) -> Int {
        edge.label.isEmpty ? 0 : splitDiagramLines(edge.label).count
    }

    private static func fcRightRenderExtent(_ route: FlowchartEdgeRoute) -> Int {
        var right = route.points.map(\.x).max() ?? 0
        if !route.edge.label.isEmpty {
            let label = flowchartRouteLabelLayout(route, measure: diagramTextWidth)
            right = max(right, label.point.x + label.width - 1)
        }
        return right
    }

    private static func fcParallelLaneAxis(_ from: FlowchartEndpointBounds, _ to: FlowchartEndpointBounds) -> DiagramAxis {
        abs(to.centerX - from.centerX) >= abs(to.centerY - from.centerY) ? .y : .x
    }

    private static func fcEdgePath(
        _ from: FlowchartEndpointBounds,
        _ to: FlowchartEndpointBounds,
        direction: FlowchartDirection,
        leftBoundary: Int?
    ) -> [FlowchartPoint] {
        if from.id == to.id { return fcSelfEdgePath(from) }
        if !fcIsVerticalDirection(direction) { return fcHorizontalEdgePath(from, to, direction: direction) }
        let overlapsVertically = from.top < to.top + to.height && to.top < from.top + from.height
        if overlapsVertically {
            let travel: DiagramDirection = centerCoordinate(to.diagramBounds, axis: .x) >= centerCoordinate(from.diagramBounds, axis: .x) ? .right : .left
            return orthogonalPath(
                fcEndpointSidePoint(from, side: sideForDirection(travel), role: .source),
                fcEndpointSidePoint(to, side: oppositeSide(sideForDirection(travel)), role: .target)
            )
        }
        return fcIsVerticalBackEdge(from, to, direction: direction)
            ? fcVerticalBackEdgePath(from, to, leftBoundary: leftBoundary)
            : fcVerticalForwardEdgePath(from, to)
    }

    private static func fcSourceFanOutLane(
        _ sourcePort: FlowchartPoint,
        targetPorts: [FlowchartPoint],
        axis: DiagramAxis,
        travel: DiagramDirection
    ) -> Int {
        let sourceCoord = coordinate(sourcePort, axis: axis)
        let unclamped = keepBefore(
            advanceCoordinate(sourceCoord, direction: travel, distance: fcBusClearance),
            boundary: beforeNearestCoordinate(targetPorts, axis: axis, direction: travel, clearance: fcNodeClearance),
            direction: travel
        )
        return keepAfter(unclamped, boundary: sourceCoord, direction: travel)
    }

    private static func fcReserveFanOutLane(
        _ sourcePort: FlowchartPoint,
        targetPorts: [FlowchartPoint],
        axis: DiagramAxis,
        travel: DiagramDirection,
        reserved: inout Set<Int>
    ) -> Int {
        let preferred = fcSourceFanOutLane(sourcePort, targetPorts: targetPorts, axis: axis, travel: travel)
        let boundary = beforeNearestCoordinate(targetPorts, axis: axis, direction: travel, clearance: fcNodeClearance)
        let source = coordinate(sourcePort, axis: axis)
        var available: Int?
        var checked = 0
        let forwardSpan = abs(boundary - preferred)
        for offset in 0...forwardSpan {
            if checked >= fcRoutingCandidateBudget { break }
            checked += 1
            let candidate = advanceCoordinate(preferred, direction: travel, distance: offset)
            if keepBefore(candidate, boundary: boundary, direction: travel) == candidate
                && keepAfter(candidate, boundary: source, direction: travel) == candidate
                && !reserved.contains(candidate)
            {
                available = candidate
                break
            }
        }
        if available == nil {
            let backwardSpan = abs(preferred - source)
            if backwardSpan >= 1 {
                for offset in 1...backwardSpan {
                    if checked >= fcRoutingCandidateBudget { break }
                    checked += 1
                    let candidate = advanceCoordinate(preferred, direction: travel, distance: -offset)
                    if keepBefore(candidate, boundary: boundary, direction: travel) == candidate
                        && keepAfter(candidate, boundary: source, direction: travel) == candidate
                        && !reserved.contains(candidate)
                    {
                        available = candidate
                        break
                    }
                }
            }
        }
        let routeLane = available ?? preferred
        reserved.insert(routeLane)
        return routeLane
    }

    private static func fcTargetFanInLane(
        _ sourcePorts: [FlowchartPoint],
        targetPort: FlowchartPoint,
        axis: DiagramAxis,
        travel: DiagramDirection
    ) -> Int {
        let targetCoord = coordinate(targetPort, axis: axis)
        let unclamped = keepAfter(
            advanceCoordinate(targetCoord, direction: travel, distance: -fcBusClearance),
            boundary: afterFarthestCoordinate(sourcePorts, axis: axis, direction: travel, clearance: fcNodeClearance),
            direction: travel
        )
        return keepBefore(unclamped, boundary: advanceCoordinate(targetCoord, direction: travel, distance: -1), direction: travel)
    }

    private static func fcPortForTravel(_ bounds: FlowchartEndpointBounds, travel: DiagramDirection, role: FcPortRole) -> FlowchartPoint {
        let side = role == .source ? sideForDirection(travel) : oppositeSide(sideForDirection(travel))
        return fcEndpointSidePoint(bounds, side: side, role: role)
    }

    private static func fcSubgraphContainsMember(
        _ subgraphs: [FlowchartSubgraph],
        subgraph: FlowchartSubgraph,
        endpointId: String
    ) -> Bool {
        if subgraph.nodeIds.contains(endpointId) { return true }
        return subgraphs.contains { child in
            child.parentId == subgraph.id
                && (child.id == endpointId || fcSubgraphContainsMember(subgraphs, subgraph: child, endpointId: endpointId))
        }
    }

    private static func fcOrderedGroups<T>(_ items: [T], key: (T) -> String) -> [(key: String, values: [T])] {
        var order: [String] = []
        var map: [String: [T]] = [:]
        for item in items {
            let k = key(item)
            if map[k] == nil { order.append(k) }
            map[k, default: []].append(item)
        }
        return order.map { ($0, map[$0]!) }
    }

    private static func fcHorizontalForwardRecords(
        _ indexedEdges: [(Int, FlowchartEdge)],
        endpoints: [String: FlowchartEndpointBounds],
        direction: FlowchartDirection
    ) -> [FcEdgeRecord] {
        let travel: DiagramDirection = direction == .RL ? .left : .right
        var records: [FcEdgeRecord] = []
        for (edgeIdx, edge) in indexedEdges {
            guard let source = endpoints[edge.from], let target = endpoints[edge.to] else { continue }
            let forward = direction == .RL
                ? centerCoordinate(target.diagramBounds, axis: .x) < centerCoordinate(source.diagramBounds, axis: .x)
                : centerCoordinate(target.diagramBounds, axis: .x) > centerCoordinate(source.diagramBounds, axis: .x)
            if !forward { continue }
            records.append(FcEdgeRecord(
                edgeIndex: edgeIdx,
                edge: edge,
                sourcePort: fcPortForTravel(source, travel: travel, role: .source),
                targetPort: fcPortForTravel(target, travel: travel, role: .target)
            ))
        }
        return records
    }

    private static func fcVerticalForwardRecords(
        _ indexedEdges: [(Int, FlowchartEdge)],
        endpoints: [String: FlowchartEndpointBounds],
        direction: FlowchartDirection
    ) -> [FcEdgeRecord] {
        let travel: DiagramDirection = direction == .BT ? .up : .down
        var records: [FcEdgeRecord] = []
        for (edgeIdx, edge) in indexedEdges {
            guard let source = endpoints[edge.from], let target = endpoints[edge.to] else { continue }
            let forward = direction == .BT
                ? centerCoordinate(target.diagramBounds, axis: .y) < centerCoordinate(source.diagramBounds, axis: .y)
                : centerCoordinate(target.diagramBounds, axis: .y) > centerCoordinate(source.diagramBounds, axis: .y)
            if !forward { continue }
            records.append(FcEdgeRecord(
                edgeIndex: edgeIdx,
                edge: edge,
                sourcePort: fcPortForTravel(source, travel: travel, role: .source),
                targetPort: fcPortForTravel(target, travel: travel, role: .target)
            ))
        }
        return records
    }

    private static func fcHorizontalExitSubgraph(_ diagram: FlowchartDiagram, edge: FlowchartEdge) -> FlowchartSubgraph? {
        let subgraphs = diagram.subgraphs ?? []
        for sub in subgraphs.reversed() {
            if sub.direction != .LR && sub.direction != .RL { continue }
            if sub.id == edge.from || sub.id == edge.to { continue }
            if fcSubgraphContainsMember(subgraphs, subgraph: sub, endpointId: edge.from)
                && !fcSubgraphContainsMember(subgraphs, subgraph: sub, endpointId: edge.to)
            {
                return sub
            }
        }
        return nil
    }

    private static func fcHorizontalEntrySubgraph(_ diagram: FlowchartDiagram, edge: FlowchartEdge) -> FlowchartSubgraph? {
        let subgraphs = diagram.subgraphs ?? []
        for sub in subgraphs.reversed() {
            if sub.direction != .LR && sub.direction != .RL { continue }
            if sub.id == edge.from || sub.id == edge.to { continue }
            if fcSubgraphContainsMember(subgraphs, subgraph: sub, endpointId: edge.to)
                && !fcSubgraphContainsMember(subgraphs, subgraph: sub, endpointId: edge.from)
            {
                return sub
            }
        }
        return nil
    }

    private static func fcHorizontalSubgraphEntryTravel(_ subgraph: FlowchartSubgraph) -> DiagramDirection {
        subgraph.direction == .RL ? .left : .right
    }

    private static func fcHorizontalSubgraphEntryLane(_ subgraph: FlowchartSubgraph, bound: FlowchartSubgraphBounds) -> Int {
        subgraph.direction == .RL
            ? bound.left + bound.width + fcBusClearance
            : bound.left - fcBusClearance
    }

    private static func fcHorizontalSubgraphJoinY(_ from: FlowchartSubgraphBounds, _ target: FlowchartSubgraphBounds) -> Int {
        if from.centerY <= target.centerY {
            let start = from.top + from.height
            let end = target.top - 1
            return start <= end ? floorDiv(start + end, 2) : start
        }
        let start = target.top + target.height
        let end = from.top - 1
        return start <= end ? floorDiv(start + end, 2) : end
    }

    private static func fcHorizontalSubgraphExitJoinY(
        _ from: FlowchartSubgraphBounds,
        targetPort: FlowchartPoint,
        targetBelow: Bool
    ) -> Int {
        if targetBelow {
            let outside = from.top + from.height
            let beforeTarget = targetPort.y - 1
            let preferred = targetPort.y - fcBusClearance
            return outside <= beforeTarget ? min(max(outside, preferred), beforeTarget) : beforeTarget
        }
        let outside = from.top - 1
        let afterTarget = targetPort.y + 1
        let preferred = targetPort.y + fcBusClearance
        return afterTarget <= outside ? max(min(outside, preferred), afterTarget) : afterTarget
    }

    private static func fcAlignClusteredVerticalSources(_ records: [FcEdgeRecord]) -> [FcEdgeRecord] {
        guard !records.isEmpty else { return [] }
        let xs = records.map(\.sourcePort.x)
        let minX = xs.min() ?? 0
        let maxX = xs.max() ?? 0
        if maxX - minX > 1 { return records }
        let avgX = jsRound(Double(xs.reduce(0, +)) / Double(xs.count))
        return records.map { rec in
            var copy = rec
            copy.sourcePort = point(avgX, rec.sourcePort.y)
            return copy
        }
    }

    private static func fcPathIntersectsBounds(
        _ points: [FlowchartPoint],
        bounds: DiagramBounds,
        allowedContact: String? = nil
    ) -> Bool {
        let right = bounds.left + bounds.width - 1
        let bottom = bounds.top + bounds.height - 1
        guard points.count >= 2 else { return false }
        let firstPt = points[0]
        let lastPt = points[points.count - 1]
        for index in 1..<points.count {
            let from = points[index - 1]
            let to = points[index]
            if from.x == to.x {
                if from.x < bounds.left || from.x > right { continue }
                let overlapTop = max(min(from.y, to.y), bounds.top)
                let overlapBottom = min(max(from.y, to.y), bottom)
                if overlapTop > overlapBottom { continue }
                let sourceContact =
                    (allowedContact == "source" || allowedContact == "both")
                    && index == 1
                    && overlapTop == overlapBottom
                    && from.x == firstPt.x
                    && overlapTop == firstPt.y
                let targetContact =
                    (allowedContact == "target" || allowedContact == "both")
                    && index == points.count - 1
                    && overlapTop == overlapBottom
                    && to.x == lastPt.x
                    && overlapTop == lastPt.y
                if !sourceContact && !targetContact { return true }
                continue
            }
            if from.y < bounds.top || from.y > bottom { continue }
            let overlapLeft = max(min(from.x, to.x), bounds.left)
            let overlapRight = min(max(from.x, to.x), right)
            if overlapLeft > overlapRight { continue }
            let sourceContact =
                (allowedContact == "source" || allowedContact == "both")
                && index == 1
                && overlapLeft == overlapRight
                && overlapLeft == firstPt.x
                && from.y == firstPt.y
            let targetContact =
                (allowedContact == "target" || allowedContact == "both")
                && index == points.count - 1
                && overlapLeft == overlapRight
                && overlapLeft == lastPt.x
                && to.y == lastPt.y
            if !sourceContact && !targetContact { return true }
        }
        return false
    }

    private static func fcLabelIntersectsBounds(_ label: FlowchartEdgeLabelLayout?, bounds: DiagramBounds) -> Bool {
        guard let label else { return false }
        return label.point.x <= bounds.left + bounds.width - 1
            && label.point.x + label.width - 1 >= bounds.left
            && label.point.y <= bounds.top + bounds.height - 1
            && label.point.y + label.height - 1 >= bounds.top
    }

    private static func fcLabelIntersectsSubgraphFrame(_ label: FlowchartEdgeLabelLayout?, bounds: FlowchartSubgraphBounds) -> Bool {
        guard let label else { return false }
        let labelRight = label.point.x + label.width - 1
        let labelBottom = label.point.y + label.height - 1
        let right = bounds.left + bounds.width - 1
        let bottom = bounds.top + bounds.height - 1
        return (label.point.x <= right && labelRight >= bounds.left &&
                ((label.point.y <= bounds.top && labelBottom >= bounds.top) || (label.point.y <= bottom && labelBottom >= bottom)))
            || (label.point.y <= bottom && labelBottom >= bounds.top &&
                ((label.point.x <= bounds.left && labelRight >= bounds.left) || (label.point.x <= right && labelRight >= right)))
    }

    private static func fcRouteLength(_ route: FlowchartEdgeRoute) -> Int {
        var length = 0
        guard route.points.count >= 2 else { return 0 }
        for index in 1..<route.points.count {
            let from = route.points[index - 1]
            let to = route.points[index]
            length += abs(to.x - from.x) + abs(to.y - from.y)
        }
        return length
    }

    private static func fcLabelIntersectsLabels(_ label: FlowchartEdgeLabelLayout?, otherLabels: [FlowchartEdgeLabelLayout]) -> Bool {
        guard let label else { return false }
        return otherLabels.contains { other in
            fcLabelIntersectsBounds(label, bounds: diagramBoundsFromRect(other.point.x, other.point.y, other.width, other.height))
        }
    }

    private static func fcLabelIntersectsRoutePaths(_ label: FlowchartEdgeLabelLayout?, routes: [FlowchartEdgeRoute]) -> Bool {
        guard let label else { return false }
        for (lineIndex, line) in label.lines.enumerated() {
            let w = diagramTextWidth(line) - 2
            if w <= 0 { continue }
            let box = diagramBoundsFromRect(label.point.x + 1, label.point.y + lineIndex, w, 1)
            if routes.contains(where: { fcPathIntersectsBounds($0.points, bounds: box) }) {
                return true
            }
        }
        return false
    }

    private static func fcRouteIntersectsLabels(_ route: FlowchartEdgeRoute, labels: [FlowchartEdgeLabelLayout]) -> Bool {
        for label in labels {
            for (lineIndex, line) in label.lines.enumerated() {
                let w = diagramTextWidth(line) - 2
                if w > 0 && fcPathIntersectsBounds(route.points, bounds: diagramBoundsFromRect(label.point.x + 1, label.point.y + lineIndex, w, 1)) {
                    return true
                }
            }
        }
        return false
    }

    private static func fcPathsIntersect(_ left: [FlowchartPoint], _ right: [FlowchartPoint]) -> Bool {
        let occupied = Set(orthogonalPathPoints(left))
        return orthogonalPathPoints(right).contains { occupied.contains($0) }
    }

    private static func fcEndpointDisjoint(_ left: FlowchartEdge, _ right: FlowchartEdge) -> Bool {
        left.from != right.from && left.from != right.to && left.to != right.from && left.to != right.to
    }

    private static func fcEndpointConflictsWithRoutes(_ route: FlowchartEdgeRoute, otherRoutes: [FlowchartEdgeRoute]) -> Bool {
        guard let source = route.points.first, let target = route.points.last else { return false }
        return otherRoutes.contains { other in
            let otherSource = other.points.first
            let otherTarget = other.points.last
            return (otherSource != nil && target == otherSource!) || (otherTarget != nil && source == otherTarget!)
        }
    }

    private static func fcPathRunsAlongFrame(_ points: [FlowchartPoint], bounds: FlowchartSubgraphBounds) -> Bool {
        let right = bounds.left + bounds.width - 1
        let bottom = bounds.top + bounds.height - 1
        guard points.count >= 2 else { return false }
        for index in 1..<points.count {
            guard let seg = segmentBetween(points[index - 1], points[index]) else { continue }
            let span = segmentSpan(seg)
            if seg.axis == .x
                && (seg.from.y == bounds.top || seg.from.y == bottom)
                && min(span.end, right) > max(span.start, bounds.left)
            {
                return true
            }
            if seg.axis == .y
                && (seg.from.x == bounds.left || seg.from.x == right)
                && min(span.end, bottom) > max(span.start, bounds.top)
            {
                return true
            }
        }
        return false
    }

    private static func fcAvoidNodeObstacles(
        _ route: FlowchartEdgeRoute,
        routes: [FlowchartEdgeRoute],
        nodeBoundsOrder: [FlowchartNodeBounds],
        nodeIds: Set<String>,
        endpoints: [String: FlowchartEndpointBounds],
        subgraphBoundsOrder: [FlowchartSubgraphBounds],
        subgraphBounds: [String: FlowchartSubgraphBounds]?,
        routeIndex: Int,
        diagram: FlowchartDiagram
    ) -> FlowchartEdgeRoute {
        let subgraphs = diagram.subgraphs ?? []
        func contains(_ sub: FlowchartSubgraph, _ endpointId: String) -> Bool {
            fcSubgraphContainsMember(subgraphs, subgraph: sub, endpointId: endpointId)
        }
        let owner = subgraphs.reversed().first { sub in
            if !contains(sub, route.edge.from) || !contains(sub, route.edge.to) { return false }
            let children = subgraphs.filter { $0.parentId == sub.id }
            return children.contains { $0.id == route.edge.from || contains($0, route.edge.from) }
                && children.contains { $0.id == route.edge.to || contains($0, route.edge.to) }
                && !children.contains {
                    ($0.id == route.edge.from || contains($0, route.edge.from))
                        && ($0.id == route.edge.to || contains($0, route.edge.to))
                }
        }
        let ownerBounds = owner.flatMap { subgraphBounds?[$0.id] }
        func leavesOwner(_ candidate: FlowchartEdgeRoute) -> Bool {
            guard let ob = ownerBounds else { return false }
            return candidate.points.contains { pt in
                pt.x <= ob.left || pt.x >= ob.left + ob.width - 1 || pt.y <= ob.top || pt.y >= ob.top + ob.height - 1
            }
        }
        let otherRoutes = routes.enumerated().compactMap { $0.offset == routeIndex ? nil : $0.element }
        let otherLabels = otherRoutes.compactMap { other -> FlowchartEdgeLabelLayout? in
            other.edge.label.isEmpty ? nil : flowchartRouteLabelLayout(other, measure: diagramTextWidth)
        }
        func intersectsNode(_ candidate: FlowchartEdgeRoute) -> Bool {
            nodeBoundsOrder.contains { bound in
                let isSource = bound.id == route.edge.from
                let isTarget = bound.id == route.edge.to
                let allowed = (isSource && isTarget) ? "both" : (isSource ? "source" : (isTarget ? "target" : nil))
                return fcPathIntersectsBounds(candidate.points, bounds: bound.diagramBounds, allowedContact: allowed)
            }
        }
        let sourceSubgraph = nodeIds.contains(route.edge.from) ? nil : subgraphBounds?[route.edge.from]
        func intersectsSourceTitle(_ candidate: FlowchartEdgeRoute) -> Bool {
            guard let sub = sourceSubgraph, !sub.label.isEmpty, let first = candidate.points.first else { return false }
            let connector = flowchartSourceConnector(.subgraph(sub), sourcePoint: first)
            let title = fcSubgraphTitleBounds(sub)
            return connector.y >= title.top && connector.y < title.top + title.height
                && connector.x >= title.left && connector.x < title.left + title.width
        }
        func intersectsStructuralObstacle(_ candidate: FlowchartEdgeRoute) -> Bool {
            if intersectsNode(candidate) || intersectsSourceTitle(candidate) { return true }
            return subgraphBoundsOrder.contains { bound in
                fcPathRunsAlongFrame(candidate.points, bounds: bound)
                    || (!bound.label.isEmpty && fcPathIntersectsBounds(candidate.points, bounds: fcSubgraphTitleBounds(bound)))
            }
        }
        func intersectsRoutingObstacle(_ candidate: FlowchartEdgeRoute) -> Bool {
            if intersectsStructuralObstacle(candidate) || fcEndpointConflictsWithRoutes(candidate, otherRoutes: otherRoutes) {
                return true
            }
            return otherRoutes.contains { other in
                fcEndpointDisjoint(candidate.edge, other.edge) && fcPathsIntersect(candidate.points, other.points)
            }
        }
        func intersectsObstacle(_ candidate: FlowchartEdgeRoute) -> Bool {
            let label = candidate.edge.label.isEmpty ? nil : flowchartRouteLabelLayout(candidate, measure: diagramTextWidth)
            return leavesOwner(candidate)
                || intersectsRoutingObstacle(candidate)
                || nodeBoundsOrder.contains { fcLabelIntersectsBounds(label, bounds: $0.diagramBounds) }
                || subgraphBoundsOrder.contains { fcLabelIntersectsSubgraphFrame(label, bounds: $0) }
                || fcLabelIntersectsLabels(label, otherLabels: otherLabels)
                || fcLabelIntersectsRoutePaths(label, routes: otherRoutes)
                || fcRouteIntersectsLabels(candidate, labels: otherLabels)
        }

        if !intersectsObstacle(route) { return route }
        guard let from = endpoints[route.edge.from], let to = endpoints[route.edge.to] else { return route }
        let routingBounds: [DiagramBounds] = nodeBoundsOrder.map(\.diagramBounds) + subgraphBoundsOrder.map(\.diagramBounds)
        guard !routingBounds.isEmpty else { return route }

        let rightBusX = (routingBounds.map { $0.left + $0.width - 1 }.max() ?? 0) + fcBusClearance
        let leftBusX = (routingBounds.map(\.left).min() ?? 0) - fcBusClearance
        let topBusY = (routingBounds.map(\.top).min() ?? 0) - fcBusClearance
        let bottomBusY = (routingBounds.map { $0.top + $0.height - 1 }.max() ?? 0) + fcBusClearance

        var rightSet: Set<Int> = [rightBusX]
        if let ob = ownerBounds { rightSet.insert(ob.left + ob.width - 2) }
        for lbl in otherLabels { rightSet.insert(max(rightBusX, lbl.point.x + lbl.width - 1 + fcNodeClearance)) }
        let rightBusXs = rightSet.sorted()

        var leftSet: Set<Int> = [leftBusX]
        if let ob = ownerBounds { leftSet.insert(ob.left + 1) }
        for lbl in otherLabels { leftSet.insert(min(leftBusX, lbl.point.x - fcNodeClearance)) }
        let leftBusXs = leftSet.sorted(by: >)

        var topSet: Set<Int> = [topBusY]
        if let ob = ownerBounds { topSet.insert(ob.top + 1) }
        for lbl in otherLabels { topSet.insert(min(topBusY, lbl.point.y - fcNodeClearance)) }
        let topBusYs = topSet.sorted(by: >)

        var bottomSet: Set<Int> = [bottomBusY]
        if let ob = ownerBounds { bottomSet.insert(ob.top + ob.height - 2) }
        for lbl in otherLabels { bottomSet.insert(max(bottomBusY, lbl.point.y + lbl.height - 1 + fcNodeClearance)) }
        let bottomBusYs = bottomSet.sorted()

        let busLimit = max(1, Int(floor(sqrt(Double(fcRoutingCandidateBudget) / 4.0))))
        let candLeft = Array(leftBusXs.prefix(busLimit))
        let candRight = Array(rightBusXs.prefix(busLimit))
        let candTop = Array(topBusYs.prefix(busLimit))
        let candBottom = Array(bottomBusYs.prefix(busLimit))

        var buses: [DiagramLane] = []
        buses.append(contentsOf: candLeft.map { lane(.x, $0) })
        buses.append(contentsOf: candRight.map { lane(.x, $0) })
        buses.append(contentsOf: candTop.map { lane(.y, $0) })
        buses.append(contentsOf: candBottom.map { lane(.y, $0) })

        func routeViaBus(_ start: FlowchartPoint, targetSide: DiagramSide, bus: DiagramLane) -> FlowchartEdgeRoute {
            let end = boundsSidePoint(to.diagramBounds, side: targetSide)
            let dir: DiagramDirection
            switch targetSide {
            case .left: dir = .left
            case .right: dir = .right
            case .top: dir = .up
            case .bottom: dir = .down
            }
            let approach = shiftPoint(end, direction: dir)
            let pts: [FlowchartPoint] = bus.axis == .x
                ? pathThrough([start, point(bus.coordinate, start.y), point(bus.coordinate, approach.y), approach, end])
                : pathThrough([start, point(start.x, bus.coordinate), point(approach.x, bus.coordinate), approach, end])
            return FlowchartEdgeRoute(
                edge: route.edge,
                points: pts,
                labelAxis: route.labelAxis == nil ? nil : (bus.axis == .x ? .y : .x),
                labelPoint: route.labelPoint
            )
        }

        func shortest(_ candidates: [FlowchartEdgeRoute], accept: (FlowchartEdgeRoute) -> Bool) -> FlowchartEdgeRoute? {
            var best: FlowchartEdgeRoute?
            var bestLen = Int.max
            for cand in candidates where accept(cand) {
                let len = fcRouteLength(cand)
                if len < bestLen {
                    bestLen = len
                    best = cand
                }
            }
            return best
        }

        if from.id == to.id {
            var selfLoops: [FlowchartEdgeRoute] = []
            for busX in candRight {
                for busY in candBottom {
                    selfLoops.append(FlowchartEdgeRoute(
                        edge: route.edge,
                        points: pathThrough([
                            boundsSidePoint(from.diagramBounds, side: .right),
                            point(busX, from.centerY),
                            point(busX, busY),
                            point(from.centerX, busY),
                            boundsSidePoint(from.diagramBounds, side: .bottom),
                        ]),
                        labelAxis: route.labelAxis,
                        labelPoint: route.labelPoint
                    ))
                }
            }
            for busY in candBottom {
                for busX in candLeft {
                    selfLoops.append(FlowchartEdgeRoute(
                        edge: route.edge,
                        points: pathThrough([
                            boundsSidePoint(from.diagramBounds, side: .bottom),
                            point(from.centerX, busY),
                            point(busX, busY),
                            point(busX, from.centerY),
                            boundsSidePoint(from.diagramBounds, side: .left),
                        ]),
                        labelAxis: route.labelAxis,
                        labelPoint: route.labelPoint
                    ))
                }
            }
            for busX in candLeft {
                for busY in candTop {
                    selfLoops.append(FlowchartEdgeRoute(
                        edge: route.edge,
                        points: pathThrough([
                            boundsSidePoint(from.diagramBounds, side: .left),
                            point(busX, from.centerY),
                            point(busX, busY),
                            point(from.centerX, busY),
                            boundsSidePoint(from.diagramBounds, side: .top),
                        ]),
                        labelAxis: route.labelAxis,
                        labelPoint: route.labelPoint
                    ))
                }
            }
            for busY in candTop {
                for busX in candRight {
                    selfLoops.append(FlowchartEdgeRoute(
                        edge: route.edge,
                        points: pathThrough([
                            boundsSidePoint(from.diagramBounds, side: .top),
                            point(from.centerX, busY),
                            point(busX, busY),
                            point(busX, from.centerY),
                            boundsSidePoint(from.diagramBounds, side: .right),
                        ]),
                        labelAxis: route.labelAxis,
                        labelPoint: route.labelPoint
                    ))
                }
            }
            return shortest(selfLoops) { !intersectsObstacle($0) }
                ?? shortest(selfLoops) { !intersectsStructuralObstacle($0) }
                ?? route
        }

        let targetSides: [DiagramSide] = [.left, .right, .top, .bottom]
        guard let firstPt = route.points.first, let lastPt = route.points.last else { return route }
        let currentTargetSide = fcSideForOutsidePoint(to, sourcePoint: lastPt)
        let preservedTargets = buses.map { routeViaBus(firstPt, targetSide: currentTargetSide, bus: $0) }
        var sameSides: [FlowchartEdgeRoute] = []
        for busX in candRight {
            sameSides.append(FlowchartEdgeRoute(
                edge: route.edge,
                points: pathViaLane(fcEndpointSidePoint(from, side: .right, role: .source), lane(.x, busX), fcEndpointSidePoint(to, side: .right, role: .target)),
                labelAxis: route.labelAxis == nil ? nil : .y,
                labelPoint: route.labelPoint
            ))
        }
        for busX in candLeft {
            sameSides.append(FlowchartEdgeRoute(
                edge: route.edge,
                points: pathViaLane(fcEndpointSidePoint(from, side: .left, role: .source), lane(.x, busX), fcEndpointSidePoint(to, side: .left, role: .target)),
                labelAxis: route.labelAxis == nil ? nil : .y,
                labelPoint: route.labelPoint
            ))
        }
        for busY in candTop {
            sameSides.append(FlowchartEdgeRoute(
                edge: route.edge,
                points: pathViaLane(fcEndpointSidePoint(from, side: .top, role: .source), lane(.y, busY), fcEndpointSidePoint(to, side: .top, role: .target)),
                labelAxis: route.labelAxis == nil ? nil : .x,
                labelPoint: route.labelPoint
            ))
        }
        for busY in candBottom {
            sameSides.append(FlowchartEdgeRoute(
                edge: route.edge,
                points: pathViaLane(fcEndpointSidePoint(from, side: .bottom, role: .source), lane(.y, busY), fcEndpointSidePoint(to, side: .bottom, role: .target)),
                labelAxis: route.labelAxis == nil ? nil : .x,
                labelPoint: route.labelPoint
            ))
        }

        let preservedSources = targetSides.flatMap { targetSide in
            buses.map { routeViaBus(firstPt, targetSide: targetSide, bus: $0) }
        }
        let attachments = targetSides.flatMap { sourceSide in
            let srcPt = fcEndpointSidePoint(from, side: sourceSide, role: .source)
            return targetSides.flatMap { targetSide in
                buses.map { routeViaBus(srcPt, targetSide: targetSide, bus: $0) }
            }
        }

        if subgraphBounds != nil {
            return shortest(preservedTargets) { !intersectsObstacle($0) }
                ?? shortest(sameSides) { !intersectsObstacle($0) }
                ?? shortest(preservedSources) { !intersectsObstacle($0) }
                ?? shortest(attachments) { !intersectsObstacle($0) }
                ?? shortest(preservedSources) { !intersectsStructuralObstacle($0) }
                ?? shortest(attachments) { !intersectsStructuralObstacle($0) }
                ?? route
        }
        return sameSides.first { !intersectsObstacle($0) }
            ?? shortest(preservedTargets) { !intersectsObstacle($0) }
            ?? attachments.first { !intersectsObstacle($0) }
            ?? shortest(preservedSources) { !intersectsObstacle($0) }
            ?? shortest(attachments) { !intersectsStructuralObstacle($0) }
            ?? shortest(preservedSources) { !intersectsStructuralObstacle($0) }
            ?? route
    }

    private static func fcAvoidLabelOverlap(
        _ route: FlowchartEdgeRoute,
        otherRoutes: [FlowchartEdgeRoute],
        nodeBoundsOrder: [FlowchartNodeBounds],
        endpoints: [String: FlowchartEndpointBounds],
        subgraphBoundsOrder: [FlowchartSubgraphBounds],
        targetWidth: Int?,
        includeLabelWidth: Bool
    ) -> FlowchartEdgeRoute {
        if route.edge.label.isEmpty { return route }
        let otherLabels = otherRoutes.compactMap { other -> FlowchartEdgeLabelLayout? in
            other.edge.label.isEmpty ? nil : flowchartRouteLabelLayout(other, measure: diagramTextWidth)
        }
        var otherConnectorBounds: [DiagramBounds] = []
        for other in otherRoutes {
            guard let source = endpoints[other.edge.from], let sourcePoint = other.points.first else { continue }
            let connector = flowchartSourceConnector(source, sourcePoint: sourcePoint)
            otherConnectorBounds.append(diagramBoundsFromRect(connector.x, connector.y, 1, 1))
            otherConnectorBounds.append(diagramBoundsFromRect(sourcePoint.x, sourcePoint.y, 1, 1))
        }
        let hasParallelRoute = otherRoutes.contains { $0.edge.from == route.edge.from && $0.edge.to == route.edge.to }

        func intersectsObstacle(_ label: FlowchartEdgeLabelLayout) -> Bool {
            if let targetWidth {
                if hasParallelRoute || !includeLabelWidth {
                    if label.point.x > targetWidth { return true }
                } else {
                    if label.point.x + label.width > targetWidth { return true }
                }
            }
            return nodeBoundsOrder.contains { fcLabelIntersectsBounds(label, bounds: $0.diagramBounds) }
                || subgraphBoundsOrder.contains { fcLabelIntersectsSubgraphFrame(label, bounds: $0) }
                || fcLabelIntersectsLabels(label, otherLabels: otherLabels)
                || fcLabelIntersectsRoutePaths(label, routes: otherRoutes)
                || otherConnectorBounds.contains { fcLabelIntersectsBounds(label, bounds: $0) }
        }

        let current = flowchartRouteLabelLayout(route, measure: diagramTextWidth)
        if !intersectsObstacle(current) { return route }

        var seen = Set<FlowchartPoint>()
        var remaining = fcRoutingCandidateBudget
        func available(_ candidate: FlowchartPoint) -> Bool {
            remaining -= 1
            if seen.contains(candidate) { return false }
            seen.insert(candidate)
            var test = current
            test.point = candidate
            return !intersectsObstacle(test)
        }

        if route.points.count >= 2 {
            for index in 1..<route.points.count {
                if remaining <= 0 { break }
                guard let seg = segmentBetween(route.points[index - 1], route.points[index]) else { continue }
                let label = flowchartEdgeLabelLayout(
                    route.points,
                    label: route.edge.label,
                    measure: diagramTextWidth,
                    preferredAxis: route.labelAxis,
                    preferredSegment: index - 1
                )
                let fixed: [FlowchartPoint] = seg.axis == .y
                    ? [label.point, point(seg.from.x - label.width, label.point.y)]
                    : [label.point, point(label.point.x, seg.from.y - label.height), point(label.point.x, seg.from.y + 1)]
                for candidate in fixed {
                    if remaining <= 0 { return route }
                    if available(candidate) {
                        var copy = route
                        copy.labelPoint = candidate
                        return copy
                    }
                }
                if seg.axis == .y {
                    let top = min(seg.from.y, seg.to.y)
                    let bottom = max(seg.from.y, seg.to.y) - label.height + 1
                    if top <= bottom {
                        for y in top...bottom {
                            if remaining <= 0 { break }
                            for x in [seg.from.x + 1, seg.from.x - label.width] {
                                let candidate = point(x, y)
                                if available(candidate) {
                                    var copy = route
                                    copy.labelPoint = candidate
                                    return copy
                                }
                                if remaining <= 0 { return route }
                            }
                        }
                    }
                    continue
                }
                let left = min(seg.from.x, seg.to.x)
                let right = max(seg.from.x, seg.to.x) - label.width + 1
                if left <= right {
                    for x in left...right {
                        if remaining <= 0 { break }
                        for y in [seg.from.y, seg.from.y - label.height, seg.from.y + 1] {
                            let candidate = point(x, y)
                            if available(candidate) {
                                var copy = route
                                copy.labelPoint = candidate
                                return copy
                            }
                            if remaining <= 0 { return route }
                        }
                    }
                }
            }
        }

        if let targetWidth, includeLabelWidth, current.point.x + current.width > targetWidth {
            let x = max(0, targetWidth - current.width)
            for distance in 0..<100 {
                let ys = distance == 0 ? [current.point.y] : [current.point.y - distance, current.point.y + distance]
                for y in ys {
                    if y < 0 { continue }
                    var test = current
                    test.point = point(x, y)
                    if !intersectsObstacle(test) {
                        var copy = route
                        copy.labelPoint = point(x, y)
                        return copy
                    }
                }
            }
        }
        return route
    }

    // parity: merman/src/flowchart/routing.ts#routeFlowchartEdges [status=implemented hash=f349553df532]
    public static func routeFlowchartEdges(
        _ diagram: FlowchartDiagram,
        bounds: [String: FlowchartNodeBounds],
        directionForEdge: ((FlowchartEdge) -> FlowchartDirection)? = nil,
        subgraphBounds: [String: FlowchartSubgraphBounds]? = nil,
        targetWidth: Int? = nil,
        directionAligned: Bool = false,
        lockedRoutes: [Int: FlowchartEdgeRoute]? = nil
    ) -> [FlowchartEdgeRoute] {
        let dirFor = directionForEdge ?? { _ in diagram.direction }
        let routedEdges = diagram.edges.filter { $0.orderOnly != true }
        let routedDiagram = FlowchartDiagram(
            direction: diagram.direction,
            nodes: diagram.nodes,
            edges: routedEdges,
            subgraphs: diagram.subgraphs
        )

        var endpoints: [String: FlowchartEndpointBounds] = [:]
        if let subgraphBounds {
            for (k, v) in subgraphBounds { endpoints[k] = .subgraph(v) }
        }
        for (k, v) in bounds { endpoints[k] = .node(v) }

        let nodeBoundsOrder = diagram.nodes.compactMap { bounds[$0.id] }
        let subgraphBoundsOrder = (diagram.subgraphs ?? []).reversed().compactMap { subgraphBounds?[$0.id] }
        let nodeIds = Set(diagram.nodes.map(\.id))

        var handled = Set<Int>()
        var routes: [(edgeIndex: Int, route: FlowchartEdgeRoute)] = []
        var lockedIndices = Set<Int>()
        if let lockedRoutes {
            for idx in lockedRoutes.keys.sorted() {
                if let route = lockedRoutes[idx] {
                    routes.append((idx, route))
                    handled.insert(idx)
                    lockedIndices.insert(idx)
                }
            }
        }

        let leftBoundary: Int?
        if let subgraphBounds {
            let allLefts = nodeBoundsOrder.map(\.left) + subgraphBounds.values.map(\.left)
            leftBoundary = allLefts.min()
        } else {
            leftBoundary = nil
        }

        // 1. Parallel edges
        let indexedEdges = Array(routedEdges.enumerated())
        for (_, group) in fcOrderedGroups(indexedEdges, key: { "\($0.1.from):\($0.1.to)" }) {
            if group.count < 2 { continue }
            guard let from = endpoints[group[0].1.from], let to = endpoints[group[0].1.to] else { continue }
            if from.id == to.id {
                var laneOffset = 0
                for (edgeIdx, edge) in group {
                    if handled.contains(edgeIdx) { laneOffset += 1; continue }
                    routes.append((edgeIdx, FlowchartEdgeRoute(edge: edge, points: fcSelfEdgePath(from, laneOffset: laneOffset))))
                    handled.insert(edgeIdx)
                    laneOffset += 1
                }
                continue
            }
            let parallelAxis: DiagramAxis =
                (directionAligned && fcIsVerticalDirection(dirFor(group[0].1))) ? .x : fcParallelLaneAxis(from, to)
            var previousRoute: FlowchartEdgeRoute?
            for (edgeIdx, edge) in group {
                let h = fcLabelHeight(edge)
                let laneCoord: Int
                if parallelAxis == .x {
                    if let prev = previousRoute {
                        laneCoord = fcRightRenderExtent(prev) + fcNodeClearance
                    } else {
                        laneCoord = max(boundsSidePoint(from.diagramBounds, side: .right).x, boundsSidePoint(to.diagramBounds, side: .right).x)
                            + (directionAligned ? 1 : 0)
                    }
                } else {
                    if let prev = previousRoute {
                        laneCoord = (prev.points.map(\.y).max() ?? 0) + (h > 1 ? h + 1 : 1)
                    } else {
                        laneCoord = max(boundsSidePoint(from.diagramBounds, side: .bottom).y, boundsSidePoint(to.diagramBounds, side: .bottom).y)
                            + (h > 1 ? h : 0)
                    }
                }
                let route = FlowchartEdgeRoute(
                    edge: edge,
                    points: fcParallelEdgePath(from, to, axis: parallelAxis, laneCoordinate: laneCoord),
                    labelAxis: parallelAxis == .x ? .y : .x
                )
                if !handled.contains(edgeIdx) {
                    routes.append((edgeIdx, route))
                    handled.insert(edgeIdx)
                }
                previousRoute = route
            }
        }

        // 2. Horizontal fan-out & fan-in
        for dir in [FlowchartDirection.LR, .RL] {
            let horizEdges = indexedEdges.filter { !handled.contains($0.0) && dirFor($0.1) == dir }
            if horizEdges.isEmpty { continue }
            let records = fcHorizontalForwardRecords(horizEdges, endpoints: endpoints, direction: dir)
            let travel: DiagramDirection = dir == .RL ? .left : .right

            var reservedBusLanes = Set<Int>()
            var targetOwners: [String: String] = [:]
            for (sourceId, sourceRecords) in fcOrderedGroups(records, key: { $0.edge.from }) {
                if sourceRecords.count < 2 { continue }
                let sourcePort = sourceRecords[0].sourcePort
                let targetPorts = sourceRecords.map(\.targetPort)
                let busX = fcReserveFanOutLane(sourcePort, targetPorts: targetPorts, axis: .x, travel: travel, reserved: &reservedBusLanes)
                for rec in sourceRecords {
                    let targetOwner = targetOwners[rec.edge.to]
                    if targetOwner == nil { targetOwners[rec.edge.to] = sourceId }
                    if targetOwner == nil || targetOwner == sourceId || endpoints[rec.edge.to] == nil {
                        routes.append((rec.edgeIndex, FlowchartEdgeRoute(edge: rec.edge, points: pathViaLane(sourcePort, lane(.x, busX), rec.targetPort))))
                        handled.insert(rec.edgeIndex)
                        continue
                    }
                    let target = endpoints[rec.edge.to]!
                    let targetSide: DiagramSide = sourcePort.y < rec.targetPort.y ? .top : .bottom
                    let targetPoint = fcEndpointSidePoint(target, side: targetSide, role: .target)
                    let approach = shiftPoint(targetPoint, direction: targetSide == .top ? .up : .down)
                    routes.append((rec.edgeIndex, FlowchartEdgeRoute(
                        edge: rec.edge,
                        points: pathThrough([sourcePort, point(busX, sourcePort.y), point(busX, approach.y), approach, targetPoint])
                    )))
                    handled.insert(rec.edgeIndex)
                }
            }

            let unhandledHoriz = records.filter { !handled.contains($0.edgeIndex) }
            for (_, targetRecords) in fcOrderedGroups(unhandledHoriz, key: { $0.edge.to }) {
                if targetRecords.count < 2 { continue }
                let targetPort = targetRecords[0].targetPort
                let sourcePorts = targetRecords.map(\.sourcePort)
                let busX = fcTargetFanInLane(sourcePorts, targetPort: targetPort, axis: .x, travel: travel)
                for rec in targetRecords {
                    routes.append((rec.edgeIndex, FlowchartEdgeRoute(edge: rec.edge, points: pathViaLane(rec.sourcePort, lane(.x, busX), targetPort))))
                    handled.insert(rec.edgeIndex)
                }
            }
        }

        // 3. Horizontal subgraph exits & entries
        if let subgraphBounds {
            var exitGroupsOrder: [String] = []
            var exitGroups: [String: [(edgeIdx: Int, edge: FlowchartEdge, subgraph: FlowchartSubgraph, source: FlowchartEndpointBounds)]] = [:]
            for (edgeIdx, edge) in indexedEdges {
                if handled.contains(edgeIdx) { continue }
                guard let sub = fcHorizontalExitSubgraph(routedDiagram, edge: edge),
                      let source = endpoints[edge.from],
                      endpoints[edge.to] != nil
                else { continue }
                let key = "\(sub.id):\(edge.to)"
                if exitGroups[key] == nil { exitGroupsOrder.append(key) }
                exitGroups[key, default: []].append((edgeIdx, edge, sub, source))
            }
            for key in exitGroupsOrder {
                guard let group = exitGroups[key], let first = group.first,
                      let subBound = subgraphBounds[first.subgraph.id],
                      let target = endpoints[first.edge.to]
                else { continue }
                let travel: DiagramDirection = first.subgraph.direction == .RL ? .left : .right
                let busX = first.subgraph.direction == .RL
                    ? subBound.left - fcBusClearance
                    : subBound.left + subBound.width + fcBusClearance
                let targetSub = fcHorizontalEntrySubgraph(routedDiagram, edge: first.edge)
                let targetSubBound = targetSub.flatMap { subgraphBounds[$0.id] }
                let targetBelow = target.centerY >= subBound.centerY
                let targetPort: FlowchartPoint
                if let targetSub {
                    targetPort = fcPortForTravel(target, travel: fcHorizontalSubgraphEntryTravel(targetSub), role: .target)
                } else {
                    targetPort = fcEndpointSidePoint(target, side: targetBelow ? .top : .bottom, role: .target)
                }
                let joinY = targetSubBound.map { fcHorizontalSubgraphJoinY(subBound, $0) }
                    ?? fcHorizontalSubgraphExitJoinY(subBound, targetPort: targetPort, targetBelow: targetBelow)
                let entryX = (targetSub != nil && targetSubBound != nil)
                    ? fcHorizontalSubgraphEntryLane(targetSub!, bound: targetSubBound!)
                    : targetPort.x
                for rec in group {
                    let sourcePort = fcPortForTravel(rec.source, travel: travel, role: .source)
                    routes.append((rec.edgeIdx, FlowchartEdgeRoute(
                        edge: rec.edge,
                        points: pathThrough([
                            sourcePort,
                            point(busX, sourcePort.y),
                            point(busX, joinY),
                            point(entryX, joinY),
                            point(entryX, targetPort.y),
                            targetPort,
                        ])
                    )))
                    handled.insert(rec.edgeIdx)
                }
            }

            for (edgeIdx, edge) in indexedEdges {
                if handled.contains(edgeIdx) { continue }
                guard let sub = fcHorizontalEntrySubgraph(routedDiagram, edge: edge),
                      let subBound = subgraphBounds[sub.id],
                      let from = endpoints[edge.from],
                      let to = endpoints[edge.to]
                else { continue }
                let targetPort = fcPortForTravel(to, travel: fcHorizontalSubgraphEntryTravel(sub), role: .target)
                let entryX = fcHorizontalSubgraphEntryLane(sub, bound: subBound)
                let travel = fcVerticalTravel(from, to)
                let sourcePort = fcPortForTravel(from, travel: travel, role: .source)
                routes.append((edgeIdx, FlowchartEdgeRoute(
                    edge: edge,
                    points: pathThrough([sourcePort, point(entryX, sourcePort.y), point(entryX, targetPort.y), targetPort])
                )))
                handled.insert(edgeIdx)
            }
        }

        // 4. Vertical fan-out & fan-in
        for dir in [FlowchartDirection.TD, .TB, .BT] {
            let vertEdges = indexedEdges.filter { !handled.contains($0.0) && dirFor($0.1) == dir }
            if vertEdges.isEmpty { continue }
            let records = fcVerticalForwardRecords(vertEdges, endpoints: endpoints, direction: dir)
            let travel: DiagramDirection = dir == .BT ? .up : .down

            for (_, sourceRecords) in fcOrderedGroups(records, key: { $0.edge.from }) {
                if sourceRecords.count < 2 { continue }
                let sourcePort = sourceRecords[0].sourcePort
                let targetPorts = sourceRecords.map(\.targetPort)
                let busY = fcSourceFanOutLane(sourcePort, targetPorts: targetPorts, axis: .y, travel: travel)
                for rec in sourceRecords {
                    routes.append((rec.edgeIndex, FlowchartEdgeRoute(edge: rec.edge, points: pathViaLane(sourcePort, lane(.y, busY), rec.targetPort))))
                    handled.insert(rec.edgeIndex)
                }
            }

            let unhandledVert = records.filter { !handled.contains($0.edgeIndex) }
            for (_, unaligned) in fcOrderedGroups(unhandledVert, key: { $0.edge.to }) {
                let targetRecords = fcAlignClusteredVerticalSources(unaligned)
                if targetRecords.count < 2 { continue }
                let targetPort = targetRecords[0].targetPort
                let sourcePorts = targetRecords.map(\.sourcePort)
                let busY = fcTargetFanInLane(sourcePorts, targetPort: targetPort, axis: .y, travel: travel)
                for rec in targetRecords {
                    routes.append((rec.edgeIndex, FlowchartEdgeRoute(edge: rec.edge, points: pathViaLane(rec.sourcePort, lane(.y, busY), targetPort))))
                    handled.insert(rec.edgeIndex)
                }
            }
        }

        // 5. Remaining individual edges
        for (edgeIdx, edge) in indexedEdges {
            if handled.contains(edgeIdx) { continue }
            guard let from = endpoints[edge.from], let to = endpoints[edge.to] else { continue }
            routes.append((edgeIdx, FlowchartEdgeRoute(
                edge: edge,
                points: fcEdgePath(from, to, direction: dirFor(edge), leftBoundary: leftBoundary)
            )))
        }

        // 6. Obstacle avoidance pass (reverse order)
        var routeValues = routes.map(\.route)
        for index in stride(from: routes.count - 1, through: 0, by: -1) {
            if lockedIndices.contains(routes[index].edgeIndex) { continue }
            routeValues[index] = fcAvoidNodeObstacles(
                routeValues[index],
                routes: routeValues,
                nodeBoundsOrder: nodeBoundsOrder,
                nodeIds: nodeIds,
                endpoints: endpoints,
                subgraphBoundsOrder: subgraphBoundsOrder,
                subgraphBounds: subgraphBounds,
                routeIndex: index,
                diagram: routedDiagram
            )
        }

        // 7. Label overlap avoidance pass
        let subgraphs = diagram.subgraphs ?? []
        let subgraphById = Dictionary(uniqueKeysWithValues: subgraphs.map { ($0.id, $0) })
        func containers(_ id: String) -> Set<String> {
            var ids = Set<String>()
            var current: FlowchartSubgraph?
            if let direct = subgraphById[id] {
                current = direct.parentId.flatMap { subgraphById[$0] }
            } else {
                current = subgraphs.first { $0.nodeIds.contains(id) }
            }
            while let cur = current {
                ids.insert(cur.id)
                current = cur.parentId.flatMap { subgraphById[$0] }
            }
            return ids
        }
        func groupedLabelEdge(_ edge: FlowchartEdge) -> Bool {
            let fromContainers = containers(edge.from)
            if !containers(edge.to).contains(where: { fromContainers.contains($0) }) { return false }
            let targets = Set(routedDiagram.edges.filter { !$0.label.isEmpty && $0.from == edge.from }.map(\.to))
            let sources = Set(routedDiagram.edges.filter { !$0.label.isEmpty && $0.to == edge.to }.map(\.from))
            return targets.count > 1 || sources.count > 1
        }

        var resolved: [FlowchartEdgeRoute] = []
        resolved.reserveCapacity(routeValues.count)
        for index in 0..<routeValues.count {
            let route = routeValues[index]
            if lockedIndices.contains(routes[index].edgeIndex) {
                resolved.append(route)
                continue
            }
            let grouped = groupedLabelEdge(route.edge)
            let others = resolved + Array(routeValues[(index + 1)...])
            let effectiveTargetWidth: Int?
            if let tw = targetWidth, !subgraphs.isEmpty && grouped {
                effectiveTargetWidth = max(1, tw - 5)
            } else {
                effectiveTargetWidth = targetWidth
            }
            resolved.append(fcAvoidLabelOverlap(
                route,
                otherRoutes: others,
                nodeBoundsOrder: nodeBoundsOrder,
                endpoints: endpoints,
                subgraphBoundsOrder: subgraphBoundsOrder,
                targetWidth: effectiveTargetWidth,
                includeLabelWidth: subgraphs.isEmpty || grouped
            ))
        }
        return resolved
    }

    // parity: merman/src/flowchart/routing.ts#avoidFlowchartFrameBorders [status=implemented hash=505fcbcad70b]
    public static func avoidFlowchartFrameBorders(
        _ routes: inout [FlowchartEdgeRoute],
        bounds: [String: FlowchartNodeBounds],
        subgraphBounds: [String: FlowchartSubgraphBounds],
        subgraphOrder: [String]? = nil
    ) {
        var endpoints: [String: FlowchartEndpointBounds] = [:]
        for (k, v) in subgraphBounds { endpoints[k] = .subgraph(v) }
        for (k, v) in bounds { endpoints[k] = .node(v) }

        func inside(_ node: FlowchartEndpointBounds, _ frame: FlowchartSubgraphBounds) -> Bool {
            node.id != frame.id
                && node.left >= frame.left
                && node.top >= frame.top
                && node.left + node.width <= frame.left + frame.width
                && node.top + node.height <= frame.top + frame.height
        }

        let orderedFrames: [FlowchartSubgraphBounds]
        if let subgraphOrder {
            orderedFrames = subgraphOrder.compactMap { subgraphBounds[$0] }
        } else {
            orderedFrames = Array(subgraphBounds.values)
        }

        for rIdx in 0..<routes.count {
            let source = endpoints[routes[rIdx].edge.from]
            let target = endpoints[routes[rIdx].edge.to]
            for frame in orderedFrames {
                guard let firstPt = routes[rIdx].points.first else { continue }
                let inward = (source != nil && target != nil && inside(source!, frame) && inside(target!, frame))
                let right = frame.left + frame.width - 1
                let bottom = frame.top + frame.height - 1
                var pts: [FlowchartPoint] = [firstPt]
                if routes[rIdx].points.count >= 2 {
                    for index in 1..<routes[rIdx].points.count {
                        let from = routes[rIdx].points[index - 1]
                        let to = routes[rIdx].points[index]
                        guard let seg = segmentBetween(from, to) else { continue }
                        let span = segmentSpan(seg)
                        var horizontalSide: DiagramSide?
                        if seg.axis == .x && min(span.end, right) > max(span.start, frame.left) {
                            if seg.from.y == frame.top { horizontalSide = .top }
                            else if seg.from.y == bottom { horizontalSide = .bottom }
                        }
                        var verticalSide: DiagramSide?
                        if seg.axis == .y && min(span.end, bottom) > max(span.start, frame.top) {
                            if seg.from.x == frame.left { verticalSide = .left }
                            else if seg.from.x == right { verticalSide = .right }
                        }
                        if horizontalSide == nil && verticalSide == nil {
                            pts.append(to)
                            continue
                        }
                        if let hSide = horizontalSide {
                            let offset = hSide == .top
                                ? frame.top + (inward ? 1 : -1)
                                : bottom + (inward ? -1 : 1)
                            pts.append(contentsOf: [point(from.x, offset), point(to.x, offset), to])
                        } else if let vSide = verticalSide {
                            let offset = vSide == .left
                                ? frame.left + (inward ? 1 : -1)
                                : right + (inward ? -1 : 1)
                            pts.append(contentsOf: [point(offset, from.y), point(offset, to.y), to])
                        }
                    }
                }
                routes[rIdx].points = pathThrough(pts)
            }
        }
    }

    private static func fcSideForOutsidePoint(_ bounds: FlowchartEndpointBounds, sourcePoint: FlowchartPoint) -> DiagramSide {
        if sourcePoint.x < bounds.left { return .left }
        if sourcePoint.x >= bounds.left + bounds.width { return .right }
        if sourcePoint.y < bounds.top { return .top }
        return .bottom
    }

    private static func fcConnectorChar(_ side: DiagramSide) -> String {
        switch side {
        case .left: return "┤"
        case .right: return "├"
        case .top: return "┴"
        case .bottom: return "┬"
        }
    }

    public struct FlowchartSourceConnectorPoint: Equatable, Hashable, Sendable {
        public let x: Int
        public let y: Int
        public let char: String

        public init(x: Int, y: Int, char: String) {
            self.x = x
            self.y = y
            self.char = char
        }

        public var diagramPoint: DiagramPoint { DiagramPoint(x: x, y: y) }
    }

    // parity: merman/src/flowchart/routing.ts#flowchartSourceConnector [status=implemented hash=179be10b1f99]
    public static func flowchartSourceConnector(
        _ from: FlowchartEndpointBounds,
        sourcePoint: FlowchartPoint
    ) -> FlowchartSourceConnectorPoint {
        let side = fcSideForOutsidePoint(from, sourcePoint: sourcePoint)
        let connector = boundsSidePoint(from.diagramBounds, side: side, surface: .border)
        return FlowchartSourceConnectorPoint(
            x: (side == .top || side == .bottom) ? sourcePoint.x : connector.x,
            y: (side == .left || side == .right) ? sourcePoint.y : connector.y,
            char: fcConnectorChar(side)
        )
    }
}
