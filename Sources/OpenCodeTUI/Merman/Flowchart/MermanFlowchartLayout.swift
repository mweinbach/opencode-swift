import Foundation

extension Merman {
    // MARK: - Flowchart Layout Constants & Types (`flowchart/layout.ts`)

    // parity: merman/src/flowchart/layout.ts#DEFAULT_MIN_NODE_GAP [status=implemented hash=4a74d724df4b]
    public static let DEFAULT_MIN_NODE_GAP: Int = 5

    // parity: merman/src/flowchart/layout.ts#DEFAULT_MIN_BRANCH_LABEL_GAP [status=implemented hash=545105e39f06]
    public static let DEFAULT_MIN_BRANCH_LABEL_GAP: Int = 12

    private static let fcDefaultMaxUnlabeledRankWidth = 120

    // parity: merman/src/flowchart/layout.ts#DEFAULT_MIN_RANK_GAP [status=implemented hash=fd2c46db8e9b]
    public static let DEFAULT_MIN_RANK_GAP: Int = 7

    // parity: merman/src/flowchart/layout.ts#DEFAULT_MIN_VERTICAL_RANK_GAP [status=implemented hash=e35ebd45088a]
    public static let DEFAULT_MIN_VERTICAL_RANK_GAP: Int = 4

    // parity: merman/src/flowchart/layout.ts#COMPACT_MIN_RANK_GAP [status=implemented hash=1f58fed20154]
    public static let COMPACT_MIN_RANK_GAP: Int = 4

    // parity: merman/src/flowchart/layout.ts#COMPACT_MIN_VERTICAL_RANK_GAP [status=implemented hash=100f0754a010]
    public static let COMPACT_MIN_VERTICAL_RANK_GAP: Int = 2

    private static let fcSubgraphPaddingX = 2
    private static let fcSubgraphPaddingTop = 1
    private static let fcSubgraphPaddingBottom = 1
    private static let fcMinSubgraphVerticalEdgeGap = 3
    private static let fcMinSubgraphHorizontalEdgeGap = 4

    // parity: merman/src/flowchart/layout.ts#FlowchartLayout [status=implemented hash=dc85294b70bd]
    public struct FlowchartLayout: Equatable, Hashable, Sendable, Codable {
        public var diagram: FlowchartDiagram
        public var bounds: [String: FlowchartNodeBounds]
        public var routes: [FlowchartEdgeRoute]
        public var subgraphBounds: [String: FlowchartSubgraphBounds]
        public var width: Int
        public var height: Int

        public init(
            diagram: FlowchartDiagram,
            bounds: [String: FlowchartNodeBounds],
            routes: [FlowchartEdgeRoute],
            subgraphBounds: [String: FlowchartSubgraphBounds],
            width: Int,
            height: Int
        ) {
            self.diagram = diagram
            self.bounds = bounds
            self.routes = routes
            self.subgraphBounds = subgraphBounds
            self.width = width
            self.height = height
        }
    }

    // parity: merman/src/flowchart/layout.ts#visualLength [status=implemented hash=c9f71f392101]
    public static func visualLength(_ value: String) -> Int {
        diagramTextWidth(value)
    }

    // parity: merman/src/flowchart/layout.ts#normalizePositiveInt [status=implemented hash=9dee27583b90]
    public static func normalizePositiveInt(_ value: Int?, fallback: Int) -> Int {
        guard let value else { return fallback }
        return max(1, value)
    }

    public static func normalizePositiveInt(_ value: Double?, fallback: Int) -> Int {
        guard let value, value.isFinite else { return fallback }
        return max(1, jsTrunc(value))
    }

    private static func fcIsHorizontalDirection(_ direction: FlowchartDirection) -> Bool {
        direction == .LR || direction == .RL
    }

    private static func fcNodeSize(_ node: FlowchartNode) -> FlowchartNodeSize {
        let box = measureDiagramTextBox(node.label, paddingX: 2)
        let innerWidth = box.width - 4
        switch node.shape {
        case .decision:
            let w = innerWidth + 6
            return FlowchartNodeSize(width: w % 2 == 0 ? w + 1 : w, height: max(5, box.lines.count + 4), lines: box.lines)
        case .database:
            return FlowchartNodeSize(width: innerWidth + 4, height: box.lines.count + 4, lines: box.lines)
        case .subroutine:
            return FlowchartNodeSize(width: innerWidth + 6, height: box.lines.count + 2, lines: box.lines)
        case .box, .rounded:
            return FlowchartNodeSize(width: innerWidth + 4, height: box.lines.count + 2, lines: box.lines)
        }
    }

    private static func fcCollectDescendantSubgraphIds(_ diagram: FlowchartDiagram, subgraphId: String) -> Set<String> {
        var ids = Set<String>()
        for child in diagram.subgraphs ?? [] where child.parentId == subgraphId {
            ids.insert(child.id)
            ids.formUnion(fcCollectDescendantSubgraphIds(diagram, subgraphId: child.id))
        }
        return ids
    }

    private static func fcCollectSubgraphNodeIds(_ diagram: FlowchartDiagram, subgraphId: String) -> Set<String> {
        var nodeIds = Set<String>()
        for sub in diagram.subgraphs ?? [] {
            if sub.id != subgraphId && sub.parentId != subgraphId { continue }
            for nodeId in sub.nodeIds { nodeIds.insert(nodeId) }
            if sub.parentId == subgraphId {
                nodeIds.formUnion(fcCollectSubgraphNodeIds(diagram, subgraphId: sub.id))
            }
        }
        return nodeIds
    }

    private static func fcSubgraphContainsEndpoint(_ diagram: FlowchartDiagram, subgraph: FlowchartSubgraph, endpointId: String) -> Bool {
        fcCollectSubgraphNodeIds(diagram, subgraphId: subgraph.id).contains(endpointId)
            || fcCollectDescendantSubgraphIds(diagram, subgraphId: subgraph.id).contains(endpointId)
    }

    private static func fcEdgeDirection(_ diagram: FlowchartDiagram, edge: FlowchartEdge) -> FlowchartDirection {
        for sub in (diagram.subgraphs ?? []).reversed() {
            guard let dir = sub.direction else { continue }
            if fcSubgraphContainsEndpoint(diagram, subgraph: sub, endpointId: edge.from)
                && fcSubgraphContainsEndpoint(diagram, subgraph: sub, endpointId: edge.to)
            {
                return dir
            }
        }
        return diagram.direction
    }

    private static func fcEndpointRankSpan(
        _ diagram: FlowchartDiagram,
        edge: FlowchartEdge,
        normalizedRanks: [String: Int],
        nodeIds: Set<String>
    ) -> (startRank: Int, endRank: Int, hasSubgraphEndpoint: Bool, unsharedSubgraphs: [FlowchartSubgraph])? {
        let fromIds = nodeIds.contains(edge.from) ? [edge.from] : Array(fcCollectSubgraphNodeIds(diagram, subgraphId: edge.from))
        let toIds = nodeIds.contains(edge.to) ? [edge.to] : Array(fcCollectSubgraphNodeIds(diagram, subgraphId: edge.to))
        let fromRanks = fromIds.compactMap { normalizedRanks[$0] }
        let toRanks = toIds.compactMap { normalizedRanks[$0] }
        guard let fMax = fromRanks.max(), let fMin = fromRanks.min(),
              let tMax = toRanks.max(), let tMin = toRanks.min()
        else { return nil }
        let startRank: Int
        let endRank: Int
        if fMax < tMin {
            startRank = fMax
            endRank = tMin
        } else if tMax < fMin {
            startRank = tMax
            endRank = fMin
        } else {
            return nil
        }
        let hasSubgraphEndpoint = !nodeIds.contains(edge.from) || !nodeIds.contains(edge.to)
        let subgraphs = diagram.subgraphs ?? []
        let unshared = hasSubgraphEndpoint ? subgraphs.filter { sub in
            let containsFrom = sub.id == edge.from || fcSubgraphContainsEndpoint(diagram, subgraph: sub, endpointId: edge.from)
            let containsTo = sub.id == edge.to || fcSubgraphContainsEndpoint(diagram, subgraph: sub, endpointId: edge.to)
            return containsFrom != containsTo
        } : []
        return (startRank, endRank, hasSubgraphEndpoint, unshared)
    }

    private static func fcEnsureRankSpanGap(_ gaps: inout [Int], startIndex: Int, endIndex: Int, required: Int) {
        let low = min(startIndex, endIndex)
        let high = max(startIndex, endIndex)
        if low == high { return }
        if high - low == 1 {
            gaps[low] = max(gaps[low], required)
            return
        }
        let current = gaps[low..<high].reduce(0, +)
        if current < required {
            gaps[high - 1] += required - current
        }
    }

    private static func fcHorizontalRankGaps(
        _ diagram: FlowchartDiagram,
        normalizedRanks: [String: Int],
        rankKeys: [Int],
        fallback: Int
    ) -> [Int] {
        var gaps = Array(repeating: fallback, count: max(0, rankKeys.count - 1))
        let rankIndexes = Dictionary(uniqueKeysWithValues: rankKeys.enumerated().map { ($0.element, $0.offset) })
        let nodeIds = Set(diagram.nodes.map(\.id))

        for edge in diagram.edges {
            if edge.orderOnly == true { continue }
            let hasSubgraphEndpoint = !nodeIds.contains(edge.from) || !nodeIds.contains(edge.to)
            if edge.label.isEmpty && !hasSubgraphEndpoint { continue }

            if !hasSubgraphEndpoint {
                guard let fromRank = normalizedRanks[edge.from], let fromIdx = rankIndexes[fromRank],
                      let toRank = normalizedRanks[edge.to], let toIdx = rankIndexes[toRank],
                      fromIdx != toIdx
                else { continue }
                let labelGap = flowchartHorizontalLabelRankGap(flowchartLabelWidth(edge.label, measure: visualLength))
                for idx in min(fromIdx, toIdx)..<max(fromIdx, toIdx) {
                    gaps[idx] = max(gaps[idx], labelGap)
                }
                continue
            }

            guard let span = fcEndpointRankSpan(diagram, edge: edge, normalizedRanks: normalizedRanks, nodeIds: nodeIds),
                  let startIdx = rankIndexes[span.startRank],
                  let endIdx = rankIndexes[span.endRank]
            else { continue }
            let padding = span.unsharedSubgraphs.count * fcSubgraphPaddingX
            let clearance = !edge.label.isEmpty
                ? max(fcMinSubgraphHorizontalEdgeGap, flowchartHorizontalLabelRankGap(flowchartLabelWidth(edge.label, measure: visualLength)))
                : fcMinSubgraphHorizontalEdgeGap
            fcEnsureRankSpanGap(&gaps, startIndex: startIdx, endIndex: endIdx, required: padding + clearance)
        }
        return gaps
    }

    private static func fcVerticalRankGaps(
        _ diagram: FlowchartDiagram,
        normalizedRanks: [String: Int],
        rankKeys: [Int],
        fallback: Int
    ) -> [Int] {
        var gaps = Array(repeating: fallback, count: max(0, rankKeys.count - 1))
        let rankIndexes = Dictionary(uniqueKeysWithValues: rankKeys.enumerated().map { ($0.element, $0.offset) })
        let nodeIds = Set(diagram.nodes.map(\.id))

        for edge in diagram.edges {
            if edge.orderOnly == true { continue }
            let hasSubgraphEndpoint = !nodeIds.contains(edge.from) || !nodeIds.contains(edge.to)
            if edge.label.isEmpty && !hasSubgraphEndpoint { continue }

            if !hasSubgraphEndpoint {
                guard let fromRank = normalizedRanks[edge.from], let fromIdx = rankIndexes[fromRank],
                      let toRank = normalizedRanks[edge.to], let toIdx = rankIndexes[toRank],
                      fromIdx != toIdx
                else { continue }
                let labelH = splitDiagramLines(edge.label).count
                for idx in min(fromIdx, toIdx)..<max(fromIdx, toIdx) {
                    gaps[idx] = max(gaps[idx], labelH + 2)
                }
                continue
            }

            guard let span = fcEndpointRankSpan(diagram, edge: edge, normalizedRanks: normalizedRanks, nodeIds: nodeIds),
                  let startIdx = rankIndexes[span.startRank],
                  let endIdx = rankIndexes[span.endRank]
            else { continue }
            let padding = span.unsharedSubgraphs.reduce(0) { sum, sub in
                sum + max(fcSubgraphPaddingTop, splitDiagramLines(sub.label).count)
            }
            let clearance = !edge.label.isEmpty
                ? max(fcMinSubgraphVerticalEdgeGap, splitDiagramLines(edge.label).count + 2)
                : fcMinSubgraphVerticalEdgeGap
            fcEnsureRankSpanGap(&gaps, startIndex: startIdx, endIndex: endIdx, required: padding + clearance)
        }
        return gaps
    }

    private static func fcRankNodes(_ diagram: FlowchartDiagram) -> [String: Int] {
        var ranks: [String: Int] = [:]
        var outgoing: [String: [String]] = [:]
        var incoming = Set<String>()
        var incomingCounts = Dictionary(uniqueKeysWithValues: diagram.nodes.map { ($0.id, 0) })

        let nodeIds = Set(diagram.nodes.map(\.id))
        let subgraphs = diagram.subgraphs ?? []
        let subgraphById = Dictionary(uniqueKeysWithValues: subgraphs.map { ($0.id, $0) })

        func insideSubgraph(_ endpointId: String, _ subgraphId: String) -> Bool {
            guard let sub = subgraphById[subgraphId] else { return false }
            return fcSubgraphContainsEndpoint(diagram, subgraph: sub, endpointId: endpointId)
        }
        func subgraphExitNodes(_ subgraphId: String) -> [String] {
            let members = fcCollectSubgraphNodeIds(diagram, subgraphId: subgraphId)
            var hasInternalOutgoing = Set<String>()
            for edge in diagram.edges {
                if edge.from == edge.to || !insideSubgraph(edge.from, subgraphId) || !insideSubgraph(edge.to, subgraphId) { continue }
                let sources = nodeIds.contains(edge.from) ? [edge.from] : Array(fcCollectSubgraphNodeIds(diagram, subgraphId: edge.from))
                for s in sources { hasInternalOutgoing.insert(s) }
            }
            let exits = diagram.nodes.map(\.id).filter { members.contains($0) && !hasInternalOutgoing.contains($0) }
            return exits.isEmpty ? diagram.nodes.map(\.id).filter { members.contains($0) } : exits
        }
        func subgraphEntryNodes(_ subgraphId: String) -> [String] {
            let members = fcCollectSubgraphNodeIds(diagram, subgraphId: subgraphId)
            var hasInternalIncoming = Set<String>()
            for edge in diagram.edges {
                if edge.from == edge.to || !insideSubgraph(edge.from, subgraphId) || !insideSubgraph(edge.to, subgraphId) { continue }
                let targets = nodeIds.contains(edge.to) ? [edge.to] : Array(fcCollectSubgraphNodeIds(diagram, subgraphId: edge.to))
                for t in targets { hasInternalIncoming.insert(t) }
            }
            let entries = diagram.nodes.map(\.id).filter { members.contains($0) && !hasInternalIncoming.contains($0) }
            return entries.isEmpty ? diagram.nodes.map(\.id).filter { members.contains($0) } : entries
        }

        var rankEdges: [(from: String, to: String)] = []
        for edge in diagram.edges {
            if nodeIds.contains(edge.from) && nodeIds.contains(edge.to) {
                rankEdges.append((edge.from, edge.to))
            } else {
                let fromIds = nodeIds.contains(edge.from) ? [edge.from] : subgraphExitNodes(edge.from)
                let toIds = nodeIds.contains(edge.to) ? [edge.to] : subgraphEntryNodes(edge.to)
                for f in fromIds {
                    for t in toIds {
                        rankEdges.append((f, t))
                    }
                }
            }
        }

        for edge in rankEdges {
            outgoing[edge.from, default: []].append(edge.to)
            incoming.insert(edge.to)
            incomingCounts[edge.to, default: 0] += 1
        }

        var starts = diagram.nodes.filter { !incoming.contains($0.id) }
        if starts.isEmpty, let first = diagram.nodes.first {
            starts.append(first)
        }

        var queue = starts.map(\.id)
        for node in starts { ranks[node.id] = 0 }

        var idx = 0
        while idx < queue.count {
            let id = queue[idx]
            idx += 1
            let rank = ranks[id] ?? 0
            for to in outgoing[id] ?? [] {
                let nextRank = rank + 1
                if let existing = ranks[to], existing <= nextRank { continue }
                ranks[to] = nextRank
                queue.append(to)
            }
        }

        for node in diagram.nodes where ranks[node.id] == nil {
            ranks[node.id] = ranks.count
        }

        var acyclicRanks: [String: Int] = [:]
        var acyclicQueue = diagram.nodes.filter { (incomingCounts[$0.id] ?? 0) == 0 }.map(\.id)
        for id in acyclicQueue { acyclicRanks[id] = 0 }
        var aIdx = 0
        while aIdx < acyclicQueue.count {
            let id = acyclicQueue[aIdx]
            aIdx += 1
            let rank = acyclicRanks[id] ?? 0
            for to in outgoing[id] ?? [] {
                acyclicRanks[to] = max(acyclicRanks[to] ?? 0, rank + 1)
                let rem = (incomingCounts[to] ?? 0) - 1
                incomingCounts[to] = rem
                if rem == 0 { acyclicQueue.append(to) }
            }
        }
        for (id, rank) in acyclicRanks { ranks[id] = rank }
        return ranks
    }

    private static func fcTranslateNodeBounds(_ bounds: inout FlowchartNodeBounds, dx: Int, dy: Int) {
        bounds.left += dx
        bounds.top += dy
        bounds.centerX += dx
        bounds.centerY += dy
    }

    private static func fcTranslateSubgraphBounds(_ bounds: inout FlowchartSubgraphBounds, dx: Int, dy: Int) {
        bounds.left += dx
        bounds.top += dy
        bounds.centerX += dx
        bounds.centerY += dy
    }

    private static func fcTranslateRoutes(_ routes: inout [FlowchartEdgeRoute], dx: Int, dy: Int) {
        for rIdx in 0..<routes.count {
            for pIdx in 0..<routes[rIdx].points.count {
                routes[rIdx].points[pIdx].x += dx
                routes[rIdx].points[pIdx].y += dy
            }
            if var lp = routes[rIdx].labelPoint {
                lp.x += dx
                lp.y += dy
                routes[rIdx].labelPoint = lp
            }
        }
    }

    private static func fcFreezeRouteLabelPoints(_ routes: inout [FlowchartEdgeRoute]) {
        for idx in 0..<routes.count {
            if routes[idx].edge.label.isEmpty || routes[idx].labelPoint != nil { continue }
            routes[idx].labelPoint = flowchartEdgeLabelLayout(
                routes[idx].points,
                label: routes[idx].edge.label,
                measure: visualLength,
                preferredAxis: routes[idx].labelAxis
            ).point
        }
    }

    private static func fcSubgraphBoundFromChildren(
        id: String,
        label: String,
        children: [DiagramBounds]
    ) -> FlowchartSubgraphBounds {
        let labelLines = splitDiagramLines(label)
        let labelHeight = labelLines.count
        var left = (children.map(\.left).min() ?? 0) - fcSubgraphPaddingX
        let top = (children.map(\.top).min() ?? 0) - max(fcSubgraphPaddingTop, labelHeight)
        var right = (children.map { $0.left + $0.width }.max() ?? 0) + fcSubgraphPaddingX
        let bottom = (children.map { $0.top + $0.height }.max() ?? 0) + max(fcSubgraphPaddingBottom, labelHeight)
        let minWidth = (labelLines.map(visualLength).max() ?? 0) + 5

        if right - left < minWidth {
            let extra = minWidth - (right - left)
            left -= floorDiv(extra, 2)
            right += ceilDiv(extra, 2)
        }
        let width = right - left
        let height = max(3, bottom - top)
        return FlowchartSubgraphBounds(
            id: id,
            label: label,
            labelSide: .top,
            left: left,
            top: top,
            width: width,
            height: height,
            centerX: left + floorDiv(width, 2),
            centerY: top + floorDiv(height, 2)
        )
    }

    private static func fcSpansOverlap(_ lStart: Int, _ lEnd: Int, _ rStart: Int, _ rEnd: Int) -> Bool {
        lStart <= rEnd && rStart <= lEnd
    }

    private static func fcLabelSlot(_ bounds: FlowchartSubgraphBounds, side: FlowchartSubgraphLabelSide) -> DiagramBounds {
        let lines = splitDiagramLines(bounds.label)
        let left = bounds.left + 2
        let height = lines.count
        let top = side == .top ? bounds.top : bounds.top + bounds.height - height
        let width = lines.map { visualLength(" \($0) ") }.max() ?? 0
        return diagramBoundsFromRect(left, top, width, height)
    }

    private static func fcSegmentOverlapsSlot(_ from: DiagramPoint, _ to: DiagramPoint, slot: DiagramBounds) -> Bool {
        guard let seg = segmentBetween(from, to) else { return false }
        let slotRight = slot.left + slot.width - 1
        let slotBottom = slot.top + slot.height - 1
        let span = segmentSpan(seg)
        if seg.axis == .x {
            return seg.from.y >= slot.top && seg.from.y <= slotBottom && fcSpansOverlap(span.start, span.end, slot.left, slotRight)
        }
        return seg.from.x >= slot.left && seg.from.x <= slotRight && fcSpansOverlap(span.start, span.end, slot.top, slotBottom)
    }

    private static func fcRouteLabelBounds(_ route: FlowchartEdgeRoute) -> DiagramBounds? {
        if route.edge.label.isEmpty { return nil }
        let label = flowchartRouteLabelLayout(route, measure: visualLength)
        return diagramBoundsFromRect(label.point.x, label.point.y, label.width, label.height)
    }

    private static func fcRouteOverlapsSlot(
        _ route: FlowchartEdgeRoute,
        bounds: FlowchartSubgraphBounds,
        slot: DiagramBounds,
        nodeIds: Set<String>
    ) -> Bool {
        if route.edge.from == bounds.id && !nodeIds.contains(bounds.id), let first = route.points.first {
            let connector = flowchartSourceConnector(.subgraph(bounds), sourcePoint: first)
            if connector.x >= slot.left && connector.x < slot.left + slot.width
                && connector.y >= slot.top && connector.y < slot.top + slot.height
            {
                return true
            }
        }
        if route.points.count >= 2 {
            for index in 1..<route.points.count {
                if fcSegmentOverlapsSlot(route.points[index - 1], route.points[index], slot: slot) {
                    return true
                }
            }
        }
        guard let rlb = fcRouteLabelBounds(route) else { return false }
        if !fcSpansOverlap(rlb.top, rlb.top + rlb.height - 1, slot.top, slot.top + slot.height - 1) {
            return false
        }
        return fcSpansOverlap(rlb.left, rlb.left + rlb.width - 1, slot.left, slot.left + slot.width - 1)
    }

    private static func fcChooseSubgraphLabelSide(
        _ bounds: FlowchartSubgraphBounds,
        routes: [FlowchartEdgeRoute],
        nodeIds: Set<String>
    ) -> FlowchartSubgraphLabelSide {
        let topSlot = fcLabelSlot(bounds, side: .top)
        if !routes.contains(where: { fcRouteOverlapsSlot($0, bounds: bounds, slot: topSlot, nodeIds: nodeIds) }) {
            return .top
        }
        let bottomSlot = fcLabelSlot(bounds, side: .bottom)
        return routes.contains(where: { fcRouteOverlapsSlot($0, bounds: bounds, slot: bottomSlot, nodeIds: nodeIds) }) ? .top : .bottom
    }

    private static func fcRouteRenderBounds(_ routes: [FlowchartEdgeRoute]) -> [DiagramBounds] {
        var out: [DiagramBounds] = []
        for route in routes {
            if let pb = diagramBoundsFromPoints(route.points) { out.append(pb) }
            if let lb = fcRouteLabelBounds(route) { out.append(lb) }
        }
        return out
    }

    private static func fcSubgraphRouteBounds(_ subgraphNodeIds: Set<String>, routes: [FlowchartEdgeRoute]) -> [DiagramBounds] {
        fcRouteRenderBounds(routes.filter { subgraphNodeIds.contains($0.edge.from) && subgraphNodeIds.contains($0.edge.to) })
    }

    private struct FcCrossingLink {
        let layer: Int
        let upper: String
        let lower: String
    }

    private static func fcLayerCrossings(_ layers: [[String]], links: [FcCrossingLink]) -> Int {
        var position: [String: Int] = [:]
        for layer in layers {
            for (idx, id) in layer.enumerated() { position[id] = idx }
        }
        var total = 0
        for i in 0..<links.count {
            let link = links[i]
            guard let lu = position[link.upper], let ll = position[link.lower] else { continue }
            for j in (i + 1)..<links.count {
                let other = links[j]
                if other.layer != link.layer { continue }
                guard let ou = position[other.upper], let ol = position[other.lower] else { continue }
                if (lu - ou) * (ll - ol) < 0 { total += 1 }
            }
        }
        return total
    }

    private static func fcSweepLayers(_ layers: [[String]], links: [FcCrossingLink], down: Bool) -> [[String]] {
        var next = layers
        guard next.count >= 2 else { return next }
        let indices: [Int] = down ? Array(1..<next.count) : Array((0..<(next.count - 1)).reversed())
        for index in indices {
            let fixed = next[down ? index - 1 : index + 1]
            let fixedPos = Dictionary(uniqueKeysWithValues: fixed.enumerated().map { ($0.element, $0.offset) })
            var keys: [String: Double] = [:]
            var origPos: [String: Int] = [:]
            for (pos, id) in next[index].enumerated() {
                origPos[id] = pos
                var neighbors: [Int] = []
                for link in links {
                    if down && link.layer == index - 1 && link.lower == id, let p = fixedPos[link.upper] {
                        neighbors.append(p)
                    } else if !down && link.layer == index && link.upper == id, let p = fixedPos[link.lower] {
                        neighbors.append(p)
                    }
                }
                if neighbors.isEmpty {
                    keys[id] = Double(pos)
                } else {
                    keys[id] = Double(neighbors.reduce(0, +)) / Double(neighbors.count)
                }
            }
            next[index] = next[index].sorted { a, b in
                let ka = keys[a] ?? 0
                let kb = keys[b] ?? 0
                if ka != kb { return ka < kb }
                return (origPos[a] ?? 0) < (origPos[b] ?? 0)
            }
        }
        return next
    }

    private static func fcReduceRankCrossings(
        _ diagram: FlowchartDiagram,
        ranks: [String: Int],
        normalizedRanks: [String: Int],
        ranksByIndex: inout [Int: [FlowchartNode]]
    ) {
        if let subs = diagram.subgraphs, !subs.isEmpty { return }
        let rankKeys = ranksByIndex.keys.sorted()
        let layerByRank = Dictionary(uniqueKeysWithValues: rankKeys.enumerated().map { ($0.element, $0.offset) })
        var links: [FcCrossingLink] = []
        for edge in diagram.edges {
            if edge.orderOnly == true { continue }
            guard let fromRank = ranks[edge.from], let toRank = ranks[edge.to], toRank == fromRank + 1 else { continue }
            guard let from = normalizedRanks[edge.from], let to = normalizedRanks[edge.to], abs(from - to) == 1 else { continue }
            if from < to, let layer = layerByRank[from] {
                links.append(FcCrossingLink(layer: layer, upper: edge.from, lower: edge.to))
            } else if let layer = layerByRank[to] {
                links.append(FcCrossingLink(layer: layer, upper: edge.to, lower: edge.from))
            }
        }
        let original = rankKeys.map { (ranksByIndex[$0] ?? []).map(\.id) }
        let initialCrossings = fcLayerCrossings(original, links: links)
        if initialCrossings == 0 { return }

        var current = original
        var best = original
        var bestCrossings = initialCrossings
        var improved = false
        for sweep in 0..<8 {
            current = fcSweepLayers(current, links: links, down: sweep % 2 == 0)
            let c = fcLayerCrossings(current, links: links)
            if c < bestCrossings {
                bestCrossings = c
                best = current
                improved = true
            }
        }
        if !improved { return }

        let nodeById = Dictionary(uniqueKeysWithValues: diagram.nodes.map { ($0.id, $0) })
        for (idx, rank) in rankKeys.enumerated() {
            ranksByIndex[rank] = best[idx].compactMap { nodeById[$0] }
        }
    }

    private static func fcLayoutRankedNodes(
        _ diagram: FlowchartDiagram,
        direction: FlowchartDirection,
        sizes: [String: FlowchartNodeSize],
        minNodeGap: Int,
        requestedMinRankGap: Int,
        targetWidth: Int?
    ) -> (bounds: [String: FlowchartNodeBounds], wrapped: Bool) {
        let horizontal = fcIsHorizontalDirection(direction)
        let ranks = fcRankNodes(diagram)
        let maxRank = max(0, ranks.values.max() ?? 0)
        var ranksByIndex: [Int: [FlowchartNode]] = [:]
        var normalizedRanks: [String: Int] = [:]

        for node in diagram.nodes {
            let rank = ranks[node.id] ?? 0
            let normalizedRank = (direction == .RL || direction == .BT) ? maxRank - rank : rank
            normalizedRanks[node.id] = normalizedRank
            ranksByIndex[normalizedRank, default: []].append(node)
        }
        fcReduceRankCrossings(diagram, ranks: ranks, normalizedRanks: normalizedRanks, ranksByIndex: &ranksByIndex)

        let spaciousNodeGap = max(minNodeGap, DEFAULT_MIN_BRANCH_LABEL_GAP)
        let widestUnlabeledRank = ranksByIndex.values.map { nodes -> Int in
            nodes.reduce(0) { $0 + (sizes[$1.id]?.width ?? 0) } + max(0, nodes.count - 1) * spaciousNodeGap
        }.max() ?? 0

        func verticalNodeGap(_ rank: Int) -> Int {
            let widestLabel = diagram.edges
                .filter { !$0.label.isEmpty && (normalizedRanks[$0.from] == rank || normalizedRanks[$0.to] == rank) }
                .map { flowchartLabelWidth($0.label, measure: visualLength) }
                .max() ?? 0
            if widestLabel > 0 { return max(spaciousNodeGap, flowchartVerticalBranchLabelGap(widestLabel)) }
            return widestUnlabeledRank > fcDefaultMaxUnlabeledRankWidth ? minNodeGap : spaciousNodeGap
        }

        let rankKeys = ranksByIndex.keys.sorted()
        let horizontalGaps = horizontal ? fcHorizontalRankGaps(diagram, normalizedRanks: normalizedRanks, rankKeys: rankKeys, fallback: requestedMinRankGap) : []
        let verticalGaps = horizontal ? [] : fcVerticalRankGaps(diagram, normalizedRanks: normalizedRanks, rankKeys: rankKeys, fallback: requestedMinRankGap)
        var bounds: [String: FlowchartNodeBounds] = [:]
        var wrapped = false

        if horizontal {
            let columnWidths = rankKeys.map { rank in
                (ranksByIndex[rank] ?? []).map { sizes[$0.id]?.width ?? 0 }.max() ?? 0
            }
            let columnHeights = rankKeys.map { rank -> Int in
                let nodes = ranksByIndex[rank] ?? []
                return nodes.reduce(0) { $0 + (sizes[$1.id]?.height ?? 0) } + max(0, nodes.count - 1) * minNodeGap
            }
            let canvasHeight = max(1, columnHeights.max() ?? 1)
            let centerBaseline = floorDiv(canvasHeight, 2)
            var x = 0
            for rankIndex in 0..<rankKeys.count {
                let rank = rankKeys[rankIndex]
                let nodes = ranksByIndex[rank] ?? []
                let colW = columnWidths[rankIndex]
                var y = centerBaseline - floorDiv(columnHeights[rankIndex], 2)
                for node in nodes {
                    let size = sizes[node.id]!
                    let left = x + floorDiv(colW - size.width, 2)
                    bounds[node.id] = FlowchartNodeBounds(
                        id: node.id,
                        width: size.width,
                        height: size.height,
                        lines: size.lines,
                        left: left,
                        top: y,
                        centerX: left + floorDiv(size.width, 2),
                        centerY: y + floorDiv(size.height, 2)
                    )
                    y += size.height + minNodeGap
                }
                x += colW + (rankIndex < horizontalGaps.count ? horizontalGaps[rankIndex] : 0)
            }
        } else {
            struct Band {
                var nodes: [FlowchartNode]
                var width: Int
                var height: Int
            }
            var rankBands: [(bands: [Band], nodeGap: Int)] = []
            for rank in rankKeys {
                let nodes = ranksByIndex[rank] ?? []
                let roomyNodeGap = verticalNodeGap(rank)
                let naturalWidth = nodes.reduce(0) { $0 + (sizes[$1.id]?.width ?? 0) } + max(0, nodes.count - 1) * roomyNodeGap
                let labeledEdges = diagram.edges.filter {
                    !$0.label.isEmpty && (normalizedRanks[$0.from] == rank || normalizedRanks[$0.to] == rank)
                }
                let subs = diagram.subgraphs ?? []
                let needsLabelLanes = labeledEdges.count > 1 && labeledEdges.contains { edge in
                    let targets = Set(labeledEdges.filter { $0.from == edge.from }.map(\.to))
                    let sources = Set(labeledEdges.filter { $0.to == edge.to }.map(\.from))
                    func grouped(_ ids: [String]) -> Bool {
                        subs.isEmpty || subs.contains { sub in ids.allSatisfy { sub.nodeIds.contains($0) } }
                    }
                    return (targets.count > 1 && grouped([edge.from] + Array(targets)))
                        || (sources.count > 1 && grouped([edge.to] + Array(sources)))
                }
                let nodeGap = (targetWidth != nil && naturalWidth > targetWidth! && (!needsLabelLanes || subs.isEmpty))
                    ? minNodeGap
                    : roomyNodeGap
                var bands: [Band] = []
                for node in nodes {
                    let size = sizes[node.id]!
                    if let lastIdx = bands.indices.last {
                        let w = bands[lastIdx].width + nodeGap + size.width
                        if let tw = targetWidth, w > tw {
                            wrapped = true
                            bands.append(Band(nodes: [node], width: size.width, height: size.height))
                        } else {
                            bands[lastIdx].nodes.append(node)
                            bands[lastIdx].width = w
                            bands[lastIdx].height = max(bands[lastIdx].height, size.height)
                        }
                    } else {
                        bands.append(Band(nodes: [node], width: size.width, height: size.height))
                    }
                }
                rankBands.append((bands, nodeGap))
            }

            let canvasWidth = max(1, rankBands.flatMap { $0.bands.map(\.width) }.max() ?? 1)
            var y = 0
            for rankIndex in 0..<rankKeys.count {
                let rank = rankBands[rankIndex]
                for (bandIndex, band) in rank.bands.enumerated() {
                    var x = floorDiv(canvasWidth - band.width, 2)
                    for node in band.nodes {
                        let size = sizes[node.id]!
                        let top = y + floorDiv(band.height - size.height, 2)
                        bounds[node.id] = FlowchartNodeBounds(
                            id: node.id,
                            width: size.width,
                            height: size.height,
                            lines: size.lines,
                            left: x,
                            top: top,
                            centerX: x + floorDiv(size.width, 2),
                            centerY: top + floorDiv(size.height, 2)
                        )
                        x += size.width + rank.nodeGap
                    }
                    y += band.height + (bandIndex < rank.bands.count - 1 ? minNodeGap : 0)
                }
                y += rankIndex < verticalGaps.count ? verticalGaps[rankIndex] : 0
            }
        }

        return (bounds, wrapped)
    }

    private static func fcLayoutLocalSubgraphDirections(
        _ diagram: FlowchartDiagram,
        nodeBounds: inout [String: FlowchartNodeBounds],
        minNodeGap: Int,
        requestedMinRankGap: Int,
        targetWidth: Int?
    ) -> Bool {
        var wrapped = false
        let subgraphs = diagram.subgraphs ?? []
        let subgraphById = Dictionary(uniqueKeysWithValues: subgraphs.map { ($0.id, $0) })

        for subgraph in subgraphs.reversed() {
            var parent = subgraph.parentId.flatMap { subgraphById[$0] }
            while let p = parent, p.direction == nil {
                parent = p.parentId.flatMap { subgraphById[$0] }
            }
            let effectiveDir: FlowchartDirection?
            if let d = subgraph.direction {
                effectiveDir = d
            } else if let p = parent, subgraphs.filter({ $0.parentId == p.id }).count > 1 {
                effectiveDir = p.direction
            } else {
                effectiveDir = nil
            }
            guard let direction = effectiveDir, direction != diagram.direction else { continue }

            let childSubgraphs = subgraphs.filter { $0.parentId == subgraph.id }
            var coveredNodeIds = Set<String>()
            for child in childSubgraphs {
                coveredNodeIds.formUnion(fcCollectSubgraphNodeIds(diagram, subgraphId: child.id))
            }

            struct LocalItem {
                let id: String
                let nodeIds: [String]
                let bounds: DiagramBounds
                let childId: String?
            }

            var items: [LocalItem] = []
            for child in childSubgraphs {
                let nIds = diagram.nodes.map(\.id).filter { fcCollectSubgraphNodeIds(diagram, subgraphId: child.id).contains($0) }
                let childBounds = nIds.compactMap { nodeBounds[$0]?.diagramBounds }
                if let content = diagramBoundsFromBounds(childBounds) {
                    let sb = fcSubgraphBoundFromChildren(id: child.id, label: child.label, children: [content])
                    items.append(LocalItem(id: "subgraph:\(child.id)", nodeIds: nIds, bounds: sb.diagramBounds, childId: child.id))
                }
            }
            for id in subgraph.nodeIds {
                if coveredNodeIds.contains(id) { continue }
                if let b = nodeBounds[id] {
                    items.append(LocalItem(id: id, nodeIds: [id], bounds: b.diagramBounds, childId: nil))
                }
            }
            if items.isEmpty { continue }
            guard let currentBounds = diagramBoundsFromBounds(items.map(\.bounds)) else { continue }

            var itemByEndpoint: [String: String] = [:]
            for item in items {
                for nodeId in item.nodeIds { itemByEndpoint[nodeId] = item.id }
                if let childId = item.childId {
                    itemByEndpoint[childId] = item.id
                    for nestedId in fcCollectDescendantSubgraphIds(diagram, subgraphId: childId) {
                        itemByEndpoint[nestedId] = item.id
                    }
                }
            }

            let localNodes = items.map { FlowchartNode(id: $0.id, label: $0.id, shape: .box) }
            let localEdges = diagram.edges.compactMap { edge -> FlowchartEdge? in
                guard let from = itemByEndpoint[edge.from], let to = itemByEndpoint[edge.to], from != to else { return nil }
                var copy = edge
                copy.from = from
                copy.to = to
                return copy
            }
            let localDiagram = FlowchartDiagram(direction: direction, nodes: localNodes, edges: localEdges, subgraphs: [])
            let itemSizes = Dictionary(uniqueKeysWithValues: items.map {
                ($0.id, FlowchartNodeSize(width: $0.bounds.width, height: $0.bounds.height, lines: [$0.id]))
            })
            let localLayout = fcLayoutRankedNodes(
                localDiagram,
                direction: direction,
                sizes: itemSizes,
                minNodeGap: max(minNodeGap, fcSubgraphPaddingX * 2 + 1),
                requestedMinRankGap: requestedMinRankGap,
                targetWidth: targetWidth
            )
            if localLayout.wrapped { wrapped = true }
            guard let localExtent = diagramBoundsFromBounds(localLayout.bounds.values.map(\.diagramBounds)) else { continue }

            let targetLeft = currentBounds.left + floorDiv(currentBounds.width - localExtent.width, 2)
            let targetTop = currentBounds.top + floorDiv(currentBounds.height - localExtent.height, 2)
            let dx = targetLeft - localExtent.left
            let dy = targetTop - localExtent.top

            var translations: [String: (dx: Int, dy: Int)] = [:]
            for item in items {
                guard let bound = localLayout.bounds[item.id] else { continue }
                let itemDx = bound.left + dx - item.bounds.left
                let itemDy = bound.top + dy - item.bounds.top
                for nodeId in item.nodeIds { translations[nodeId] = (itemDx, itemDy) }
            }

            var groupOffset = point(0, 0)
            if targetWidth != nil {
                let localNodeIds = Set(translations.keys)
                let external = nodeBounds.filter { !localNodeIds.contains($0.key) }.map(\.value)
                func overlaps(_ offset: FlowchartPoint) -> Bool {
                    for (id, tr) in translations {
                        guard let bound = nodeBounds[id] else { continue }
                        let left = bound.left + tr.dx + offset.x
                        let top = bound.top + tr.dy + offset.y
                        for other in external {
                            if left < other.left + other.width + minNodeGap
                                && left + bound.width + minNodeGap > other.left
                                && top < other.top + other.height + minNodeGap
                                && top + bound.height + minNodeGap > other.top
                            {
                                return true
                            }
                        }
                    }
                    return false
                }
                if overlaps(groupOffset) {
                    let vertical = !fcIsHorizontalDirection(diagram.direction)
                    let sign = (diagram.direction == .RL || diagram.direction == .BT) ? -1 : 1
                    outer: for distance in 1..<1_000 {
                        let candidates: [FlowchartPoint] = vertical
                            ? [point(0, sign * distance), point(0, -sign * distance), point(distance, 0), point(-distance, 0)]
                            : [point(sign * distance, 0), point(-sign * distance, 0), point(0, distance), point(0, -distance)]
                        for cand in candidates {
                            if !overlaps(cand) {
                                groupOffset = cand
                                break outer
                            }
                        }
                    }
                }
            }

            for (nodeId, tr) in translations {
                if var nb = nodeBounds[nodeId] {
                    fcTranslateNodeBounds(&nb, dx: tr.dx + groupOffset.x, dy: tr.dy + groupOffset.y)
                    nodeBounds[nodeId] = nb
                }
            }
        }
        return wrapped
    }

    private static func fcRankGraphComponents(_ ids: [String], outgoing: [String: Set<String>]) -> [String: Int] {
        var reachable: [String: Set<String>] = [:]
        for id in ids {
            var seen = Set<String>()
            var queue = [id]
            var qi = 0
            while qi < queue.count {
                let current = queue[qi]
                qi += 1
                if seen.contains(current) { continue }
                seen.insert(current)
                for next in outgoing[current] ?? [] { queue.append(next) }
            }
            reachable[id] = seen
        }

        var componentById: [String: Int] = [:]
        var components: [[String]] = []
        for id in ids {
            if componentById[id] != nil { continue }
            let comp = ids.filter { cand in
                componentById[cand] == nil && (reachable[id]?.contains(cand) ?? false) && (reachable[cand]?.contains(id) ?? false)
            }
            let compIdx = components.count
            components.append(comp)
            for member in comp { componentById[member] = compIdx }
        }

        var compOutgoing: [Int: Set<Int>] = Dictionary(uniqueKeysWithValues: (0..<components.count).map { ($0, Set<Int>()) })
        var incoming: [Int: Int] = Dictionary(uniqueKeysWithValues: (0..<components.count).map { ($0, 0) })
        for (from, targets) in outgoing {
            guard let fc = componentById[from] else { continue }
            for to in targets {
                guard let tc = componentById[to], fc != tc else { continue }
                if compOutgoing[fc]!.insert(tc).inserted {
                    incoming[tc, default: 0] += 1
                }
            }
        }

        var compRanks: [Int: Int] = [:]
        var queue = (0..<components.count).filter { (incoming[$0] ?? 0) == 0 }
        for c in queue { compRanks[c] = 0 }
        var qi = 0
        while qi < queue.count {
            let c = queue[qi]
            qi += 1
            for to in compOutgoing[c] ?? [] {
                compRanks[to] = max(compRanks[to] ?? 0, (compRanks[c] ?? 0) + 1)
                let rem = (incoming[to] ?? 0) - 1
                incoming[to] = rem
                if rem == 0 { queue.append(to) }
            }
        }
        return Dictionary(uniqueKeysWithValues: ids.map { ($0, compRanks[componentById[$0] ?? -1] ?? 0) })
    }

    private static func fcSeparateTopLevelItems(
        _ diagram: FlowchartDiagram,
        nodeBounds: inout [String: FlowchartNodeBounds],
        subgraphBounds: inout [String: FlowchartSubgraphBounds],
        gap: Int,
        targetWidth: Int?
    ) -> Bool {
        let subgraphs = diagram.subgraphs ?? []
        let hasLocalDirection = subgraphs.contains { $0.direction != nil && $0.direction != diagram.direction }
        let topLevelIds = Set(subgraphs.filter { $0.parentId == nil }.map(\.id))
        let subgraphById = Dictionary(uniqueKeysWithValues: subgraphs.map { ($0.id, $0) })

        func topLevelSubgraphId(_ id: String) -> String {
            var current = subgraphById[id]
            while let parentId = current?.parentId {
                current = subgraphById[parentId]
            }
            return current?.id ?? id
        }

        struct TopItem {
            let id: String
            let isSubgraph: Bool
            let nodeIds: Set<String>
            var rank: Int = 0
        }

        var coveredNodeIds = Set<String>()
        var items: [TopItem] = []
        var itemByEndpoint: [String: String] = [:]

        for sub in subgraphs where sub.parentId == nil {
            guard subgraphBounds[sub.id] != nil else { continue }
            let nIds = fcCollectSubgraphNodeIds(diagram, subgraphId: sub.id)
            if nIds.isEmpty { continue }
            items.append(TopItem(id: sub.id, isSubgraph: true, nodeIds: nIds))
            itemByEndpoint[sub.id] = sub.id
            for nid in nIds {
                coveredNodeIds.insert(nid)
                itemByEndpoint[nid] = sub.id
            }
        }
        for sub in subgraphs { itemByEndpoint[sub.id] = topLevelSubgraphId(sub.id) }
        for node in diagram.nodes {
            if coveredNodeIds.contains(node.id) || nodeBounds[node.id] == nil { continue }
            items.append(TopItem(id: node.id, isSubgraph: false, nodeIds: [node.id]))
            itemByEndpoint[node.id] = node.id
        }
        if items.count < 2 { return false }

        let horizontal = fcIsHorizontalDirection(diagram.direction)

        func boundsOf(_ item: TopItem) -> DiagramBounds {
            if item.isSubgraph, let sb = subgraphBounds[item.id] { return sb.diagramBounds }
            if let nb = nodeBounds[item.id] { return nb.diagramBounds }
            return diagramBoundsFromRect(0, 0, 0, 0)
        }

        func moveItem(_ item: TopItem, dx: Int, dy: Int) {
            for nid in item.nodeIds {
                if var nb = nodeBounds[nid] {
                    fcTranslateNodeBounds(&nb, dx: dx, dy: dy)
                    nodeBounds[nid] = nb
                }
            }
            if !topLevelIds.contains(item.id) { return }
            for sub in subgraphs where topLevelSubgraphId(sub.id) == item.id {
                if var sb = subgraphBounds[sub.id] {
                    fcTranslateSubgraphBounds(&sb, dx: dx, dy: dy)
                    subgraphBounds[sub.id] = sb
                }
            }
        }

        let nodeIds = Set(diagram.nodes.map(\.id))
        func minSubgraphEdgeGap(_ fromItemId: String, _ toItemId: String) -> Int {
            let matching = diagram.edges.filter { edge in
                edge.orderOnly != true
                    && (!nodeIds.contains(edge.from) || !nodeIds.contains(edge.to))
                    && itemByEndpoint[edge.from] == fromItemId
                    && itemByEndpoint[edge.to] == toItemId
            }
            if matching.isEmpty { return gap }
            let labelReqs = matching.map { edge -> Int in
                if edge.label.isEmpty { return 0 }
                return horizontal
                    ? flowchartHorizontalLabelRankGap(flowchartLabelWidth(edge.label, measure: visualLength))
                    : splitDiagramLines(edge.label).count + 2
            }
            return max(
                gap,
                max(horizontal ? fcMinSubgraphHorizontalEdgeGap : fcMinSubgraphVerticalEdgeGap, labelReqs.max() ?? 0)
            )
        }

        if hasLocalDirection {
            var outgoing: [String: Set<String>] = Dictionary(uniqueKeysWithValues: items.map { ($0.id, Set<String>()) })
            for edge in diagram.edges {
                if let from = itemByEndpoint[edge.from], let to = itemByEndpoint[edge.to], from != to {
                    outgoing[from, default: []].insert(to)
                }
            }
            let ranks = fcRankGraphComponents(items.map(\.id), outgoing: outgoing)
            items.sort { a, b in
                let ra = ranks[a.id] ?? 0
                let rb = ranks[b.id] ?? 0
                if ra != rb { return ra < rb }
                let ba = boundsOf(a)
                let bb = boundsOf(b)
                return horizontal ? ba.centerX < bb.centerX : ba.centerY < bb.centerY
            }
            var cursor: Int?
            var previousId: String?
            var moved = false
            for item in items {
                let b = boundsOf(item)
                let start = horizontal ? b.left : b.top
                let size = horizontal ? b.width : b.height
                if let cur = cursor {
                    let pairGap = previousId.map { max(minSubgraphEdgeGap($0, item.id), minSubgraphEdgeGap(item.id, $0)) } ?? gap
                    let shift = cur + pairGap - start
                    if shift != 0 { moved = true }
                    moveItem(item, dx: horizontal ? shift : 0, dy: horizontal ? 0 : shift)
                    cursor = start + shift + size
                    previousId = item.id
                } else {
                    cursor = start + size
                    previousId = item.id
                }
            }
            return moved
        }

        var rankedItems = items.filter { topLevelIds.contains($0.id) }
        let reversed = diagram.direction == .RL || diagram.direction == .BT
        func primaryStart(_ b: DiagramBounds) -> Int {
            let start = horizontal ? b.left : b.top
            let size = horizontal ? b.width : b.height
            return reversed ? -(start + size) : start
        }
        func primaryEnd(_ b: DiagramBounds) -> Int {
            primaryStart(b) + (horizontal ? b.width : b.height)
        }

        func ensureSubgraphEdgeItemClearance() -> Bool {
            let allItemById = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            var adjusted = false
            for edge in diagram.edges {
                if edge.orderOnly == true || (nodeIds.contains(edge.from) && nodeIds.contains(edge.to)) { continue }
                guard let fromKey = itemByEndpoint[edge.from], let fromItem = allItemById[fromKey],
                      let toKey = itemByEndpoint[edge.to], let toItem = allItemById[toKey],
                      fromItem.id != toItem.id
                else { continue }
                guard let fromBound = subgraphBounds[edge.from]?.diagramBounds ?? nodeBounds[edge.from]?.diagramBounds,
                      let toBound = subgraphBounds[edge.to]?.diagramBounds ?? nodeBounds[edge.to]?.diagramBounds
                else { continue }
                if primaryStart(toBound) <= primaryStart(fromBound) { continue }
                let required = minSubgraphEdgeGap(fromItem.id, toItem.id)
                let deficit = primaryEnd(fromBound) + required - primaryStart(toBound)
                if deficit <= 0 { continue }
                adjusted = true
                let toStart = primaryStart(boundsOf(toItem))
                let offset = reversed ? -deficit : deficit
                for candidate in items {
                    if candidate.id != toItem.id && primaryStart(boundsOf(candidate)) < toStart { continue }
                    if candidate.id == fromItem.id { continue }
                    moveItem(candidate, dx: horizontal ? offset : 0, dy: horizontal ? 0 : offset)
                }
            }
            return adjusted
        }

        if rankedItems.count < 2 { return ensureSubgraphEdgeItemClearance() }

        let rankedIds = Set(rankedItems.map(\.id))
        var outgoing: [String: Set<String>] = Dictionary(uniqueKeysWithValues: rankedItems.map { ($0.id, Set<String>()) })
        for edge in diagram.edges {
            if let from = itemByEndpoint[edge.from], let to = itemByEndpoint[edge.to],
               from != to, rankedIds.contains(from), rankedIds.contains(to)
            {
                outgoing[from, default: []].insert(to)
            }
        }
        let ranks = fcRankGraphComponents(rankedItems.map(\.id), outgoing: outgoing)
        for i in 0..<rankedItems.count { rankedItems[i].rank = ranks[rankedItems[i].id] ?? 0 }

        var itemsByRank: [Int: [TopItem]] = [:]
        for item in rankedItems { itemsByRank[item.rank, default: []].append(item) }
        let rankKeys = itemsByRank.keys.sorted()

        var previousEnd: Int?
        var previousRankItems: [TopItem] = []
        var moved = false
        for rank in rankKeys {
            let rankItems = itemsByRank[rank] ?? []
            let start = rankItems.map { primaryStart(boundsOf($0)) }.min() ?? 0
            let end = rankItems.map { primaryEnd(boundsOf($0)) }.max() ?? 0
            if let prevEnd = previousEnd {
                var rankGap = gap
                for prev in previousRankItems {
                    for curr in rankItems {
                        rankGap = max(rankGap, minSubgraphEdgeGap(prev.id, curr.id))
                    }
                }
                let shift = max(0, prevEnd + rankGap - start)
                if shift > 0 {
                    moved = true
                    let offset = reversed ? -shift : shift
                    for item in rankItems {
                        moveItem(item, dx: horizontal ? offset : 0, dy: horizontal ? 0 : offset)
                    }
                }
                previousEnd = end + shift
            } else {
                previousEnd = end
            }
            previousRankItems = rankItems
        }

        for rank in rankKeys {
            let rankItems = (itemsByRank[rank] ?? []).sorted { a, b in
                let ba = boundsOf(a)
                let bb = boundsOf(b)
                return horizontal ? ba.top < bb.top : ba.left < bb.left
            }
            var crossCursor: Int?
            for item in rankItems {
                let b = boundsOf(item)
                let start = horizontal ? b.top : b.left
                let size = horizontal ? b.height : b.width
                if let cc = crossCursor {
                    let shift = max(0, cc - start)
                    if shift > 0 {
                        moved = true
                        moveItem(item, dx: horizontal ? 0 : shift, dy: horizontal ? shift : 0)
                    }
                    crossCursor = start + shift + size + gap
                } else {
                    crossCursor = start + size + gap
                }
            }
        }

        if targetWidth != nil && !horizontal {
            func intersects(_ left: TopItem, _ right: TopItem) -> Bool {
                for lid in left.nodeIds {
                    guard let lb = nodeBounds[lid] else { continue }
                    for rid in right.nodeIds {
                        guard let rb = nodeBounds[rid] else { continue }
                        if lb.left <= rb.left + rb.width - 1 && lb.left + lb.width - 1 >= rb.left
                            && lb.top <= rb.top + rb.height - 1 && lb.top + lb.height - 1 >= rb.top
                        {
                            return true
                        }
                    }
                }
                return false
            }
            for rightIndex in 1..<items.count {
                let right = items[rightIndex]
                for leftIndex in 0..<rightIndex {
                    let left = items[leftIndex]
                    if !intersects(left, right) { continue }
                    guard let lb = diagramBoundsFromBounds(left.nodeIds.compactMap { nodeBounds[$0]?.diagramBounds }),
                          let rb = diagramBoundsFromBounds(right.nodeIds.compactMap { nodeBounds[$0]?.diagramBounds })
                    else { continue }
                    let shift = reversed
                        ? lb.top - gap - (rb.top + rb.height)
                        : lb.top + lb.height + gap - rb.top
                    if shift != 0 { moved = true }
                    moveItem(right, dx: 0, dy: shift)
                }
            }
        }

        if ensureSubgraphEdgeItemClearance() { moved = true }
        return moved
    }

    private static func fcLayoutSubgraphs(
        _ diagram: FlowchartDiagram,
        nodeBounds: [String: FlowchartNodeBounds],
        routes: [FlowchartEdgeRoute]
    ) -> [String: FlowchartSubgraphBounds] {
        var subgraphBounds: [String: FlowchartSubgraphBounds] = [:]
        let subgraphs = diagram.subgraphs ?? []
        let nodeIds = Set(diagram.nodes.map(\.id))

        for subgraph in subgraphs.reversed() {
            var children: [DiagramBounds] = []
            for nodeId in subgraph.nodeIds {
                if let b = nodeBounds[nodeId] { children.append(b.diagramBounds) }
            }
            children.append(contentsOf: fcSubgraphRouteBounds(Set(subgraph.nodeIds), routes: routes))
            for childSub in subgraphs where childSub.parentId == subgraph.id {
                if let b = subgraphBounds[childSub.id] { children.append(b.diagramBounds) }
            }
            if !children.isEmpty {
                var bound = fcSubgraphBoundFromChildren(id: subgraph.id, label: subgraph.label, children: children)
                bound.labelSide = fcChooseSubgraphLabelSide(bound, routes: routes, nodeIds: nodeIds)
                subgraphBounds[subgraph.id] = bound
            }
        }
        return subgraphBounds
    }

    private static func fcLayoutWithDirection(
        _ sourceDiagram: FlowchartDiagram,
        options: FlowchartDiagramRenderOptions,
        direction: FlowchartDirection,
        responsiveFallback: Bool = false
    ) -> FlowchartLayout {
        let diagram = direction == sourceDiagram.direction
            ? sourceDiagram
            : FlowchartDiagram(direction: direction, nodes: sourceDiagram.nodes, edges: sourceDiagram.edges, subgraphs: sourceDiagram.subgraphs)
        let horizontal = fcIsHorizontalDirection(direction)
        let minNodeGap = normalizePositiveInt(options.minNodeGap, fallback: DEFAULT_MIN_NODE_GAP)
        let defaultRankGap: Int
        if options.compact == true {
            defaultRankGap = horizontal ? COMPACT_MIN_RANK_GAP : COMPACT_MIN_VERTICAL_RANK_GAP
        } else {
            defaultRankGap = horizontal ? DEFAULT_MIN_RANK_GAP : DEFAULT_MIN_VERTICAL_RANK_GAP
        }
        let requestedMinRankGap = normalizePositiveInt(options.minRankGap, fallback: defaultRankGap)
        let sizes = Dictionary(uniqueKeysWithValues: diagram.nodes.map { ($0.id, fcNodeSize($0)) })
        let targetWidth: Int? = (!horizontal && options.layoutMaxWidth != nil) ? max(1, options.layoutMaxWidth!) : nil

        let ranked = fcLayoutRankedNodes(
            diagram,
            direction: direction,
            sizes: sizes,
            minNodeGap: minNodeGap,
            requestedMinRankGap: requestedMinRankGap,
            targetWidth: targetWidth
        )
        var bounds = ranked.bounds
        let responsive = fcLayoutLocalSubgraphDirections(
            diagram,
            nodeBounds: &bounds,
            minNodeGap: minNodeGap,
            requestedMinRankGap: requestedMinRankGap,
            targetWidth: targetWidth
        )
        let directionAligned = responsiveFallback || responsive || ranked.wrapped
        let nodeIds = Set(diagram.nodes.map(\.id))
        let hasSubgraphEndpoints = diagram.edges.contains { $0.orderOnly != true && (!nodeIds.contains($0.from) || !nodeIds.contains($0.to)) }
        let memberDiagram = hasSubgraphEndpoints
            ? FlowchartDiagram(
                direction: diagram.direction,
                nodes: diagram.nodes,
                edges: diagram.edges.filter { nodeIds.contains($0.from) && nodeIds.contains($0.to) },
                subgraphs: diagram.subgraphs
            )
            : diagram

        func route(
            frames: [String: FlowchartSubgraphBounds]? = nil,
            targetDiagram: FlowchartDiagram? = nil,
            lockedRoutes: [Int: FlowchartEdgeRoute]? = nil
        ) -> [FlowchartEdgeRoute] {
            routeFlowchartEdges(
                targetDiagram ?? memberDiagram,
                bounds: bounds,
                directionForEdge: { fcEdgeDirection(diagram, edge: $0) },
                subgraphBounds: frames,
                targetWidth: targetWidth,
                directionAligned: directionAligned,
                lockedRoutes: lockedRoutes
            )
        }

        let subgraphs = diagram.subgraphs ?? []
        var subgraphBounds: [String: FlowchartSubgraphBounds] = [:]
        var routes: [FlowchartEdgeRoute]

        if subgraphs.isEmpty {
            routes = route(frames: nil, targetDiagram: diagram)
        } else {
            routes = route()
            subgraphBounds = fcLayoutSubgraphs(diagram, nodeBounds: bounds, routes: routes)
            let moved = fcSeparateTopLevelItems(
                diagram,
                nodeBounds: &bounds,
                subgraphBounds: &subgraphBounds,
                gap: max(1, floorDiv(requestedMinRankGap, 2)),
                targetWidth: targetWidth
            )
            if moved {
                routes = route()
                subgraphBounds = fcLayoutSubgraphs(diagram, nodeBounds: bounds, routes: routes)
            }
            routes = route(frames: subgraphBounds)
            subgraphBounds = fcLayoutSubgraphs(diagram, nodeBounds: bounds, routes: routes)
            let expanded = fcSeparateTopLevelItems(
                diagram,
                nodeBounds: &bounds,
                subgraphBounds: &subgraphBounds,
                gap: max(1, floorDiv(requestedMinRankGap, 2)),
                targetWidth: targetWidth
            )
            if expanded {
                routes = route(frames: subgraphBounds)
            }
            if hasSubgraphEndpoints {
                // Map each routed member edge back to its index in `diagram.edges.filter { $0.orderOnly != true }`
                let fullRoutedEdges = diagram.edges.filter { $0.orderOnly != true }
                var locked: [Int: FlowchartEdgeRoute] = [:]
                var matchedFullIndices = Set<Int>()
                for memberRoute in routes {
                    if let fullIdx = fullRoutedEdges.enumerated().first(where: { !matchedFullIndices.contains($0.offset) && $0.element == memberRoute.edge })?.offset {
                        matchedFullIndices.insert(fullIdx)
                        locked[fullIdx] = memberRoute
                    }
                }
                for edge in diagram.edges {
                    if edge.orderOnly == true || nodeIds.contains(edge.from) { continue }
                    guard var sourceFrame = subgraphBounds[edge.from],
                          let targetBound = bounds[edge.to]?.diagramBounds ?? subgraphBounds[edge.to]?.diagramBounds,
                          sourceFrame.labelSide == .top
                    else { continue }
                    if !fcIsHorizontalDirection(fcEdgeDirection(diagram, edge: edge)) && targetBound.centerY < sourceFrame.centerY {
                        let bottomSlot = fcLabelSlot(sourceFrame, side: .bottom)
                        if !routes.contains(where: { fcRouteOverlapsSlot($0, bounds: sourceFrame, slot: bottomSlot, nodeIds: nodeIds) }) {
                            sourceFrame.labelSide = .bottom
                            subgraphBounds[edge.from] = sourceFrame
                        }
                    }
                }
                routes = route(frames: subgraphBounds, targetDiagram: diagram, lockedRoutes: locked)
                var labelSideChanged = false
                for key in Array(subgraphBounds.keys) {
                    guard var bound = subgraphBounds[key] else { continue }
                    let nextSide = fcChooseSubgraphLabelSide(bound, routes: routes, nodeIds: nodeIds)
                    if nextSide != bound.labelSide {
                        bound.labelSide = nextSide
                        subgraphBounds[key] = bound
                        labelSideChanged = true
                    }
                }
                if labelSideChanged {
                    routes = route(frames: subgraphBounds, targetDiagram: diagram, lockedRoutes: locked)
                }
            }
            avoidFlowchartFrameBorders(
                &routes,
                bounds: bounds,
                subgraphBounds: subgraphBounds,
                subgraphOrder: subgraphs.reversed().map(\.id)
            )
        }

        fcFreezeRouteLabelPoints(&routes)
        let preAllBounds: [DiagramBounds] = bounds.values.map(\.diagramBounds)
            + subgraphBounds.values.map(\.diagramBounds)
            + fcRouteRenderBounds(routes)
        let dx = max(0, -(preAllBounds.map(\.left).min() ?? 0))
        let dy = max(0, -(preAllBounds.map(\.top).min() ?? 0))
        if dx > 0 || dy > 0 {
            for key in Array(bounds.keys) {
                fcTranslateNodeBounds(&bounds[key]!, dx: dx, dy: dy)
            }
            for key in Array(subgraphBounds.keys) {
                fcTranslateSubgraphBounds(&subgraphBounds[key]!, dx: dx, dy: dy)
            }
            fcTranslateRoutes(&routes, dx: dx, dy: dy)
        }
        let postAllBounds: [DiagramBounds] = bounds.values.map(\.diagramBounds)
            + subgraphBounds.values.map(\.diagramBounds)
            + fcRouteRenderBounds(routes)
        let maxX = postAllBounds.map { $0.left + $0.width }.max() ?? 0
        let maxY = postAllBounds.map { $0.top + $0.height }.max() ?? 0
        return FlowchartLayout(
            diagram: diagram,
            bounds: bounds,
            routes: routes,
            subgraphBounds: subgraphBounds,
            width: maxX + 4,
            height: maxY + 4
        )
    }

    // parity: merman/src/flowchart/layout.ts#layoutFlowchartDiagram [status=implemented hash=242f722db460]
    public static func layoutFlowchartDiagram(
        _ sourceDiagram: FlowchartDiagram,
        options: FlowchartDiagramRenderOptions = FlowchartDiagramRenderOptions()
    ) -> FlowchartLayout {
        let direction = options.direction ?? sourceDiagram.direction
        let layout = fcLayoutWithDirection(sourceDiagram, options: options, direction: direction)
        guard fcIsHorizontalDirection(direction), let maxWidth = options.layoutMaxWidth else {
            return layout
        }
        if layout.width <= max(1, maxWidth) { return layout }
        return fcLayoutWithDirection(sourceDiagram, options: options, direction: direction == .RL ? .BT : .TD, responsiveFallback: true)
    }
}
