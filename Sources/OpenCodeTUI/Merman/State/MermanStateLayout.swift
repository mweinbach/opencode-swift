import Foundation

extension Merman {
    // MARK: - State Layout Types (`state/layout.ts`)

    private static let stateMaxStrictNotePlacements = 24

    // parity: merman/src/state/layout.ts#StateDiagramBoxBounds [status=implemented hash=0d7434cd43ae]
    public struct StateDiagramBoxBounds: Equatable, Hashable, Sendable, Codable {
        public var id: String
        public var left: Int
        public var top: Int
        public var width: Int
        public var height: Int
        public var centerX: Int
        public var centerY: Int

        public init(id: String, left: Int, top: Int, width: Int, height: Int, centerX: Int, centerY: Int) {
            self.id = id
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

    // parity: merman/src/state/layout.ts#StateDiagramNoteBounds [status=implemented hash=4b31aa401842]
    public struct StateDiagramNoteBounds: Equatable, Hashable, Sendable, Codable {
        public var id: String
        public var left: Int
        public var top: Int
        public var width: Int
        public var height: Int
        public var centerX: Int
        public var centerY: Int
        public var note: StateDiagramNote
        public var lines: [String]
        public var connector: StateDiagramNoteConnector?

        public init(
            id: String,
            left: Int,
            top: Int,
            width: Int,
            height: Int,
            centerX: Int,
            centerY: Int,
            note: StateDiagramNote,
            lines: [String],
            connector: StateDiagramNoteConnector? = nil
        ) {
            self.id = id
            self.left = left
            self.top = top
            self.width = width
            self.height = height
            self.centerX = centerX
            self.centerY = centerY
            self.note = note
            self.lines = lines
            self.connector = connector
        }

        public var boxBounds: StateDiagramBoxBounds {
            StateDiagramBoxBounds(id: id, left: left, top: top, width: width, height: height, centerX: centerX, centerY: centerY)
        }

        public var diagramBounds: DiagramBounds {
            DiagramBounds(left: left, top: top, width: width, height: height, centerX: centerX, centerY: centerY)
        }
    }

    // parity: merman/src/state/layout.ts#StateDiagramLayout [status=implemented hash=eddd9069f0e0]
    public struct StateDiagramLayout: Equatable, Hashable, Sendable, Codable {
        public var bounds: [String: StateDiagramBoxBounds]
        public var sizes: [String: DiagramTextBoxSize]
        public var compositeBounds: [String: StateDiagramBoxBounds]
        public var noteBounds: [StateDiagramNoteBounds]

        public init(
            bounds: [String: StateDiagramBoxBounds],
            sizes: [String: DiagramTextBoxSize],
            compositeBounds: [String: StateDiagramBoxBounds] = [:],
            noteBounds: [StateDiagramNoteBounds] = []
        ) {
            self.bounds = bounds
            self.sizes = sizes
            self.compositeBounds = compositeBounds
            self.noteBounds = noteBounds
        }
    }

    // parity: merman/src/state/layout.ts#StateDiagramLayoutOptions [status=implemented hash=1b60b92e1a59]
    public struct StateDiagramLayoutOptions {
        public var minStateGap: Int
        public var searchBudget: StateSearchBudget?

        public init(minStateGap: Int = Merman.DEFAULT_STATE_DIAGRAM_MIN_STATE_GAP, searchBudget: StateSearchBudget? = nil) {
            self.minStateGap = minStateGap
            self.searchBudget = searchBudget
        }
    }

    // MARK: - Internal State Layout Helpers

    private static func stateComputeRanks(_ diagram: StateDiagram) -> [String: Int] {
        var ranks: [String: Int] = [:]
        var outgoing: [String: [String]] = [:]
        for t in diagram.transitions {
            outgoing[t.from, default: []].append(t.to)
        }
        guard let first = diagram.states.first(where: { $0.kind == .start })?.id ?? diagram.states.first?.id else {
            return ranks
        }
        ranks[first] = 0
        var queue = [first]
        var qi = 0
        while qi < queue.count {
            let id = queue[qi]
            qi += 1
            let rank = ranks[id] ?? 0
            for to in outgoing[id] ?? [] {
                let nextRank = rank + 1
                if let existing = ranks[to], existing <= nextRank { continue }
                ranks[to] = nextRank
                queue.append(to)
            }
        }
        for state in diagram.states where ranks[state.id] == nil {
            ranks[state.id] = ranks.count
        }
        return ranks
    }

    private static func stateReaches(_ outgoing: [String: [StateDiagramTransition]], from: String, target: String) -> Bool {
        var visited = Set<String>()
        var stack = [from]
        while let id = stack.popLast() {
            if id == target { return true }
            if !visited.insert(id).inserted { continue }
            for t in outgoing[id] ?? [] { stack.append(t.to) }
        }
        return false
    }

    private static func stateComputeMainPath(_ diagram: StateDiagram) -> [String] {
        var outgoing: [String: [StateDiagramTransition]] = [:]
        for t in diagram.transitions { outgoing[t.from, default: []].append(t) }
        let statesById = Dictionary(uniqueKeysWithValues: diagram.states.map { ($0.id, $0) })
        guard let start = diagram.states.first(where: { $0.kind == .start })?.id ?? diagram.states.first?.id else {
            return []
        }
        var path = [start]
        var visited: Set<String> = [start]
        var current = start
        while true {
            let candidates = (outgoing[current] ?? []).filter { !visited.contains($0.to) }
            if candidates.isEmpty { break }
            let next = candidates.first(where: { statesById[$0.to]?.kind == .end })
                ?? candidates.first(where: { !stateReaches(outgoing, from: $0.to, target: current) })
                ?? candidates.first(where: { !hasReverseTransition(diagram, transition: $0) })
                ?? candidates.first(where: { t in
                    guard let fp = statesById[current]?.parentId, let tp = statesById[t.to]?.parentId else { return false }
                    return fp != tp
                })
                ?? (candidates.count == 1 ? candidates[0] : nil)
            guard let chosen = next else { break }
            path.append(chosen.to)
            visited.insert(chosen.to)
            current = chosen.to
        }
        return path
    }

    private static func stateBoxSize(_ state: StateDiagramState) -> DiagramTextBoxSize {
        if state.kind != .state { return DiagramTextBoxSize(width: 1, height: 1, lines: [state.label]) }
        return measureDiagramTextBox(state.label, paddingX: 2, paddingY: 1)
    }

    private static func stateNoteSize(_ note: StateDiagramNote) -> DiagramTextBoxSize {
        let raw = note.lines.flatMap(splitDiagramLines).map(jsTrim)
        let lines = raw.isEmpty ? [""] : raw
        let innerWidth = max(lines.map(diagramTextWidth).max() ?? 0, 1)
        return DiagramTextBoxSize(width: innerWidth + 4, height: lines.count + 2, lines: lines)
    }

    private static func stateShiftBoxBound(_ bound: inout StateDiagramBoxBounds, dx: Int, dy: Int) {
        bound.left += dx
        bound.top += dy
        bound.centerX += dx
        bound.centerY += dy
    }

    private static func stateShiftNoteBound(_ bound: inout StateDiagramNoteBounds, dx: Int, dy: Int) {
        bound.left += dx
        bound.top += dy
        bound.centerX += dx
        bound.centerY += dy
        if let conn = bound.connector {
            bound.connector = StateDiagramNoteConnector(
                points: conn.points.map { point($0.x + dx, $0.y + dy) },
                connectorY: conn.connectorY + dy
            )
        }
    }

    // parity: merman/src/state/layout.ts#translateStateDiagramLayout [status=implemented hash=da3e4d95c858]
    public static func translateStateDiagramLayout(_ layout: inout StateDiagramLayout, dx: Int, dy: Int) {
        for key in Array(layout.bounds.keys) {
            stateShiftBoxBound(&layout.bounds[key]!, dx: dx, dy: dy)
        }
        for key in Array(layout.compositeBounds.keys) {
            stateShiftBoxBound(&layout.compositeBounds[key]!, dx: dx, dy: dy)
            // Keep shared composite entry in `layout.bounds` synced (already shifted above if present)
            if layout.bounds[key] != nil {
                layout.bounds[key] = layout.compositeBounds[key]
            }
        }
        for idx in 0..<layout.noteBounds.count {
            stateShiftNoteBound(&layout.noteBounds[idx], dx: dx, dy: dy)
        }
    }

    private static func stateNormalizeLayout(_ layout: inout StateDiagramLayout) {
        let allLefts = layout.bounds.values.map(\.left)
            + layout.compositeBounds.values.map(\.left)
            + layout.noteBounds.map(\.left)
            + layout.noteBounds.flatMap { $0.connector?.points.map(\.x) ?? [] }
        let allTops = layout.bounds.values.map(\.top)
            + layout.compositeBounds.values.map(\.top)
            + layout.noteBounds.map(\.top)
            + layout.noteBounds.flatMap { $0.connector?.points.map(\.y) ?? [] }
        if allLefts.isEmpty { return }
        let minX = min(0, allLefts.min() ?? 0)
        let minY = min(0, allTops.min() ?? 0)
        if minX == 0 && minY == 0 { return }
        translateStateDiagramLayout(&layout, dx: -minX, dy: -minY)
    }

    private static func stateAddCompositeBounds(_ diagram: StateDiagram, layout: inout StateDiagramLayout) {
        var statesByParent: [String: [String]] = [:]
        var compositesByParent: [String: [StateDiagramCompositeState]] = [:]
        for state in diagram.states {
            if let pid = state.parentId { statesByParent[pid, default: []].append(state.id) }
        }
        for comp in diagram.composites {
            if let pid = comp.parentId { compositesByParent[pid, default: []].append(comp) }
        }

        func addComposite(_ comp: StateDiagramCompositeState) {
            if layout.compositeBounds[comp.id] != nil { return }
            for child in compositesByParent[comp.id] ?? [] { addComposite(child) }
            let childIds = (statesByParent[comp.id] ?? []) + (compositesByParent[comp.id] ?? []).map(\.id)
            let childBounds = childIds.compactMap { layout.bounds[$0] }
            if childBounds.isEmpty { return }

            let left = (childBounds.map(\.left).min() ?? 0) - 2
            let top = (childBounds.map(\.top).min() ?? 0) - 2
            let right = (childBounds.map { $0.left + $0.width }.max() ?? 0) + 2
            let bottom = (childBounds.map { $0.top + $0.height }.max() ?? 0) + 2
            let width = max(right - left, diagramTextWidth(comp.label) + 5)
            let height = bottom - top
            let bound = StateDiagramBoxBounds(
                id: comp.id,
                left: left,
                top: top,
                width: width,
                height: height,
                centerX: left + floorDiv(width, 2),
                centerY: top + floorDiv(height, 2)
            )
            layout.compositeBounds[comp.id] = bound
            layout.bounds[comp.id] = bound
        }

        for comp in diagram.composites { addComposite(comp) }
    }

    private static func stateIntersects(left: Int, top: Int, width: Int, height: Int, bound: StateDiagramBoxBounds, padding: Int = 1) -> Bool {
        left < bound.left + bound.width + padding
            && left + width + padding > bound.left
            && top < bound.top + bound.height + padding
            && top + height + padding > bound.top
    }

    private static func stateBelongsToComposite(
        _ id: String,
        compositeId: String,
        statesById: [String: StateDiagramState],
        compositesById: [String: StateDiagramCompositeState]
    ) -> Bool {
        var parentId = statesById[id]?.parentId ?? compositesById[id]?.parentId
        while let pid = parentId {
            if pid == compositeId { return true }
            parentId = compositesById[pid]?.parentId
        }
        return false
    }

    private static func stateInnermostCommonCompositeId(
        _ transition: StateDiagramTransition,
        statesById: [String: StateDiagramState],
        compositesById: [String: StateDiagramCompositeState]
    ) -> String? {
        func containers(_ id: String) -> [String] {
            var ids: [String] = []
            var parentId = statesById[id]?.parentId ?? compositesById[id]?.parentId
            while let pid = parentId {
                ids.append(pid)
                parentId = compositesById[pid]?.parentId
            }
            return ids
        }
        let target = Set(containers(transition.to))
        return containers(transition.from).first { target.contains($0) }
    }

    private static func stateEnforceCompositeMargins(
        _ diagram: StateDiagram,
        compositeBounds: inout [String: StateDiagramBoxBounds],
        bounds: inout [String: StateDiagramBoxBounds]
    ) {
        var compositesByParent: [String: [StateDiagramCompositeState]] = [:]
        for comp in diagram.composites {
            if let pid = comp.parentId { compositesByParent[pid, default: []].append(comp) }
        }
        func expand(_ comp: StateDiagramCompositeState) -> StateDiagramBoxBounds? {
            guard var bound = compositeBounds[comp.id] else { return nil }
            let children = (compositesByParent[comp.id] ?? []).compactMap(expand)
            if children.isEmpty { return bound }
            let left = min(bound.left, children.map { $0.left - 2 }.min() ?? bound.left)
            let top = min(bound.top, children.map { $0.top - 2 }.min() ?? bound.top)
            let right = max(bound.left + bound.width, children.map { $0.left + $0.width + 2 }.max() ?? (bound.left + bound.width))
            let bottom = max(bound.top + bound.height, children.map { $0.top + $0.height + 2 }.max() ?? (bound.top + bound.height))
            bound.left = left
            bound.top = top
            bound.width = right - left
            bound.height = bottom - top
            bound.centerX = left + floorDiv(bound.width, 2)
            bound.centerY = top + floorDiv(bound.height, 2)
            compositeBounds[comp.id] = bound
            bounds[comp.id] = bound
            return bound
        }
        for comp in diagram.composites where comp.parentId == nil {
            _ = expand(comp)
        }
    }

    private static func stateExpandCompositeBoundsForNotes(_ diagram: StateDiagram, layout: inout StateDiagramLayout) {
        let statesById = Dictionary(uniqueKeysWithValues: diagram.states.map { ($0.id, $0) })
        let compositesById = Dictionary(uniqueKeysWithValues: diagram.composites.map { ($0.id, $0) })

        for comp in diagram.composites.reversed() {
            guard var bound = layout.compositeBounds[comp.id] else { continue }
            let descendantNotes = layout.noteBounds.filter {
                stateBelongsToComposite($0.note.target, compositeId: comp.id, statesById: statesById, compositesById: compositesById)
            }
            if descendantNotes.isEmpty { continue }
            let connPts = descendantNotes.flatMap { $0.connector?.points ?? [] }
            let left = min(bound.left, min(descendantNotes.map { $0.left - 2 }.min() ?? bound.left, connPts.map { $0.x - 1 }.min() ?? bound.left))
            let top = min(bound.top, min(descendantNotes.map { $0.top - 1 }.min() ?? bound.top, connPts.map { $0.y - 1 }.min() ?? bound.top))
            let right = max(bound.left + bound.width, max(descendantNotes.map { $0.left + $0.width + 2 }.max() ?? (bound.left + bound.width), connPts.map { $0.x + 2 }.max() ?? (bound.left + bound.width)))
            let bottom = max(bound.top + bound.height, max(descendantNotes.map { $0.top + $0.height + 1 }.max() ?? (bound.top + bound.height), connPts.map { $0.y + 2 }.max() ?? (bound.top + bound.height)))
            bound.left = left
            bound.top = top
            bound.width = max(right - left, diagramTextWidth(comp.label) + 5)
            bound.height = bottom - top
            bound.centerX = bound.left + floorDiv(bound.width, 2)
            bound.centerY = bound.top + floorDiv(bound.height, 2)
            layout.compositeBounds[comp.id] = bound
            layout.bounds[comp.id] = bound
        }
    }

    private static func stateExpandCompositeBoundsForInternalRouting(_ diagram: StateDiagram, layout: inout StateDiagramLayout) {
        if diagram.direction == .LR || diagram.direction == .RL { return }
        let statesById = Dictionary(uniqueKeysWithValues: diagram.states.map { ($0.id, $0) })
        let compositesById = Dictionary(uniqueKeysWithValues: diagram.composites.map { ($0.id, $0) })

        for comp in diagram.composites.reversed() {
            guard var bound = layout.compositeBounds[comp.id] else { continue }
            let internalTransitions = diagram.transitions.filter {
                $0.from != $0.to && stateInnermostCommonCompositeId($0, statesById: statesById, compositesById: compositesById) == comp.id
            }
            var endpointOccurrences: [String: Int] = [:]
            let hasNested = diagram.composites.contains { $0.parentId == comp.id }
            let sideRoutes = internalTransitions.filter { t in
                guard let from = layout.bounds[t.from], let to = layout.bounds[t.to] else { return false }
                let key = "\(t.from)\u{0000}\(t.to)"
                let occ = endpointOccurrences[key] ?? 0
                endpointOccurrences[key] = occ + 1
                let fp = statesById[t.from]?.parentId
                let tp = statesById[t.to]?.parentId
                return occ > 0
                    || (from.centerY > to.centerY && (!hasNested || from.left - 1 <= bound.left))
                    || (fp != tp && (from.centerX != to.centerX || statesById[t.from]?.kind != .state || statesById[t.to]?.kind != .state))
            }
            if sideRoutes.isEmpty { continue }
            var childRight = Int.min
            for state in diagram.states where stateBelongsToComposite(state.id, compositeId: comp.id, statesById: statesById, compositesById: compositesById) {
                if let b = layout.bounds[state.id] { childRight = max(childRight, b.left + b.width) }
            }
            for childComp in diagram.composites where childComp.parentId == comp.id {
                if let b = layout.compositeBounds[childComp.id] { childRight = max(childRight, b.left + b.width) }
            }
            if childRight == Int.min { continue }
            let labelWidth = sideRoutes.map { measureStateTransitionLabel($0.label).width }.max() ?? 0
            let right = childRight + labelWidth + sideRoutes.count * 3 + 6
            if right <= bound.left + bound.width { continue }
            bound.width = right - bound.left
            bound.centerX = bound.left + floorDiv(bound.width, 2)
            layout.compositeBounds[comp.id] = bound
            layout.bounds[comp.id] = bound
        }
        stateEnforceCompositeMargins(diagram, compositeBounds: &layout.compositeBounds, bounds: &layout.bounds)
    }

    // parity: merman/src/state/layout.ts#separateExternalBoundsFromComposites [status=implemented hash=94dc83fe7dc1]
    public static func separateExternalBoundsFromComposites(_ diagram: StateDiagram, layout: inout StateDiagramLayout) -> Bool {
        let statesById = Dictionary(uniqueKeysWithValues: diagram.states.map { ($0.id, $0) })
        let compositesById = Dictionary(uniqueKeysWithValues: diagram.composites.map { ($0.id, $0) })
        var shifted = false

        for comp in diagram.composites {
            guard let compBound = layout.compositeBounds[comp.id] else { continue }
            for state in diagram.states {
                if stateBelongsToComposite(state.id, compositeId: comp.id, statesById: statesById, compositesById: compositesById) { continue }
                guard let bound = layout.bounds[state.id],
                      stateIntersects(left: bound.left, top: bound.top, width: bound.width, height: bound.height, bound: compBound, padding: 0)
                else { continue }
                let dx = compBound.left + compBound.width + 4 - bound.left
                if dx <= 0 { continue }
                let leftThreshold = bound.left
                var shiftedIds = Set<String>()

                for cand in diagram.states {
                    if stateBelongsToComposite(cand.id, compositeId: comp.id, statesById: statesById, compositesById: compositesById) { continue }
                    if let cb = layout.bounds[cand.id], cb.left >= leftThreshold {
                        shiftedIds.insert(cand.id)
                    }
                }
                for cand in diagram.composites {
                    if cand.id == comp.id || stateBelongsToComposite(cand.id, compositeId: comp.id, statesById: statesById, compositesById: compositesById) { continue }
                    if let cb = layout.compositeBounds[cand.id], cb.left >= leftThreshold {
                        shiftedIds.insert(cand.id)
                    }
                }

                for id in shiftedIds {
                    if layout.bounds[id] != nil {
                        stateShiftBoxBound(&layout.bounds[id]!, dx: dx, dy: 0)
                    }
                    if layout.compositeBounds[id] != nil {
                        stateShiftBoxBound(&layout.compositeBounds[id]!, dx: dx, dy: 0)
                        if layout.bounds[id] != nil {
                            layout.bounds[id] = layout.compositeBounds[id]
                        }
                    }
                }
                for noteIdx in 0..<layout.noteBounds.count {
                    if shiftedIds.contains(layout.noteBounds[noteIdx].note.target) {
                        stateShiftNoteBound(&layout.noteBounds[noteIdx], dx: dx, dy: 0)
                    }
                }
                shifted = true
            }
        }
        return shifted
    }

    private static func stateCreateNoteBound(
        _ note: StateDiagramNote,
        index: Int,
        left: Int,
        top: Int,
        size: DiagramTextBoxSize
    ) -> StateDiagramNoteBounds {
        StateDiagramNoteBounds(
            id: "\(note.target)-note-\(index)",
            left: left,
            top: top,
            width: size.width,
            height: size.height,
            centerX: left + floorDiv(size.width, 2),
            centerY: top + floorDiv(size.height, 2),
            note: note,
            lines: size.lines
        )
    }

    private static func stateFindNoteConnector(
        search: StateSearchSpace,
        bounds: StateDiagramNoteBounds,
        target: StateDiagramBoxBounds,
        budget: StateSearchBudget
    ) -> StateDiagramNoteConnector? {
        let connectorY = max(bounds.top + 1, min(target.centerY, bounds.top + bounds.height - 2))
        let end = point(bounds.note.position == .right ? bounds.left - 1 : bounds.left + bounds.width, connectorY)
        let goal = point(end.x + (bounds.note.position == .right ? -1 : 1), end.y)
        let targetX = bounds.note.position == .right ? target.left + target.width : target.left - 1

        var starts: [DiagramPoint] = [
            point(targetX, target.centerY),
            point(targetX, target.top - 1),
            point(targetX, target.top + target.height),
        ]
        for offset in 0..<target.height { starts.append(point(target.left - 1, target.top + offset)) }
        for offset in 0..<target.height { starts.append(point(target.left + target.width, target.top + offset)) }
        for offset in 0..<target.width { starts.append(point(target.left + offset, target.top - 1)) }
        for offset in 0..<target.width { starts.append(point(target.left + offset, target.top + target.height)) }

        func isFree(_ pt: DiagramPoint) -> Bool {
            pt.x >= 0
                && !search.blocked.contains(pt)
                && !(pt.x >= bounds.left && pt.x < bounds.left + bounds.width && pt.y >= bounds.top && pt.y < bounds.top + bounds.height)
        }
        if !isFree(end) || !isFree(goal) { return nil }

        for start in starts where isFree(start) {
            let directPaths = [
                [start, point(start.x, goal.y), goal, end],
                [start, point(goal.x, start.y), goal, end],
            ]
            if let direct = directPaths.first(where: { orthogonalPathPoints($0).allSatisfy(isFree) }) {
                return StateDiagramNoteConnector(points: direct, connectorY: connectorY)
            }
        }

        let margin = 8
        let minY = min(target.top, min(bounds.top, search.minY)) - margin
        let maxX = max(target.left + target.width, max(bounds.left + bounds.width, search.maxX)) + margin
        let maxY = max(target.top + target.height, max(bounds.top + bounds.height, search.maxY)) + margin
        guard let path = findStateManhattanPath(
            starts: starts,
            goal: goal,
            space: search,
            minX: 0,
            minY: minY,
            maxX: maxX,
            maxY: maxY,
            budget: budget,
            isFree: isFree
        ) else { return nil }
        return StateDiagramNoteConnector(points: path + [end], connectorY: connectorY)
    }

    private static func stateOutsideNotePlacement(
        space: SpatialIndex,
        note: StateDiagramNote,
        index: Int,
        target: StateDiagramBoxBounds,
        size: DiagramTextBoxSize
    ) throws -> (bound: StateDiagramNoteBounds, connector: StateDiagramNoteConnector) {
        let search = createStateSearchSpace(space)
        let top = search.maxY + 4
        let owner = "note:\(index):outside"
        let positions: [StateDiagramNotePosition] = note.position == .left ? [.left, .right] : [.right, .left]
        let clear1 = SpatialCollisionPolicy(clearance: .uniform(1))

        for position in positions {
            let noteWithPos = StateDiagramNote(target: note.target, position: position, lines: note.lines)
            var aligned = stateCreateNoteBound(
                noteWithPos,
                index: index,
                left: position == .left ? search.minX - size.width - 4 : search.maxX + 4,
                top: target.centerY - floorDiv(size.height, 2),
                size: size
            )
            let alignedNoteX = position == .left ? aligned.left + aligned.width : aligned.left - 1
            let alignedConnY = max(aligned.top + 1, min(target.centerY, aligned.top + aligned.height - 2))
            let alignedTargetX = position == .left ? target.left - 1 : target.left + target.width
            let alignedConnector = StateDiagramNoteConnector(
                points: [point(alignedTargetX, target.centerY), point(alignedNoteX, alignedConnY)],
                connectorY: alignedConnY
            )
            if alignedTargetX == alignedNoteX || target.centerY == alignedConnY {
                if try space.isFree(try spatialRectClaim(id: "\(owner):body", owner: owner, role: .body, bounds: aligned.diagramBounds), policy: clear1)
                    && space.isFree(try spatialPathClaim(id: "\(owner):connector", owner: owner, role: .boundary, points: alignedConnector.points))
                {
                    aligned.connector = alignedConnector
                    return (aligned, alignedConnector)
                }
            }

            let railX = position == .left ? search.minX - 2 : search.maxX + 2
            var bound = stateCreateNoteBound(
                noteWithPos,
                index: index,
                left: position == .left ? railX - size.width - 2 : railX + 3,
                top: top,
                size: size
            )
            let noteX = position == .left ? bound.left + bound.width : bound.left - 1
            let connectorY = bound.top + 1
            let sideX = position == .left ? target.left - 1 : target.left + target.width
            let escapes: [[DiagramPoint]] = [
                [point(sideX, target.top), point(railX, target.top)],
                [point(sideX, target.centerY), point(railX, target.centerY)],
                [point(sideX, target.top + target.height - 1), point(railX, target.top + target.height - 1)],
                [point(target.centerX, target.top - 1), point(railX, target.top - 1)],
                [point(target.centerX, target.top + target.height), point(railX, target.top + target.height)],
            ]
            for escape in escapes {
                let conn = StateDiagramNoteConnector(points: escape + [point(railX, connectorY), point(noteX, connectorY)], connectorY: connectorY)
                if try space.isFree(try spatialRectClaim(id: "\(owner):body", owner: owner, role: .body, bounds: bound.diagramBounds), policy: clear1)
                    && space.isFree(try spatialPathClaim(id: "\(owner):connector", owner: owner, role: .boundary, points: conn.points))
                {
                    bound.connector = conn
                    return (bound, conn)
                }
            }
        }

        for vertical in ["below", "above"] {
            let railY = vertical == "below" ? search.maxY + 2 : search.minY - 2
            var bound = stateCreateNoteBound(
                note,
                index: index,
                left: note.position == .left ? search.minX - size.width - 4 : search.maxX + 4,
                top: vertical == "below" ? railY + 2 : railY - size.height - 2,
                size: size
            )
            let noteX = note.position == .left ? bound.left + bound.width : bound.left - 1
            let connectorY = bound.top + 1
            let targetY = vertical == "below" ? target.top + target.height : target.top - 1
            let escapes: [[DiagramPoint]] = [
                [point(target.left, targetY), point(target.left, railY)],
                [point(target.centerX, targetY), point(target.centerX, railY)],
                [point(target.left + target.width - 1, targetY), point(target.left + target.width - 1, railY)],
                [point(target.left, targetY), point(target.left - 1, targetY), point(target.left - 1, railY)],
                [point(target.left + target.width - 1, targetY), point(target.left + target.width, targetY), point(target.left + target.width, railY)],
            ]
            for escape in escapes {
                let conn = StateDiagramNoteConnector(points: escape + [point(noteX, railY), point(noteX, connectorY)], connectorY: connectorY)
                if try space.isFree(try spatialRectClaim(id: "\(owner):body", owner: owner, role: .body, bounds: bound.diagramBounds), policy: clear1)
                    && space.isFree(try spatialPathClaim(id: "\(owner):connector", owner: owner, role: .boundary, points: conn.points))
                {
                    bound.connector = conn
                    return (bound, conn)
                }
            }
        }

        // Fallback deterministic outside placement
        var fallback = stateCreateNoteBound(note, index: index, left: search.maxX + 4, top: top, size: size)
        let conn = StateDiagramNoteConnector(points: [point(target.left + target.width, target.centerY), point(fallback.left - 1, target.centerY)], connectorY: fallback.centerY)
        fallback.connector = conn
        return (fallback, conn)
    }

    private static func statePlaceNotesAroundTransitions(
        _ diagram: StateDiagram,
        layout: inout StateDiagramLayout,
        transitionPlans: [StateTransitionRenderPlan],
        budget: StateSearchBudget
    ) throws {
        if diagram.notes.isEmpty { return }
        let compositeIds = Set(diagram.composites.map(\.id))
        var stateClaims: [SpatialClaim] = []
        for bound in layout.bounds.values where !compositeIds.contains(bound.id) {
            stateClaims.append(try spatialRectClaim(id: "state:\(bound.id)", owner: "state:\(bound.id)", role: .body, bounds: bound.diagramBounds))
        }
        var noteSpace = try SpatialIndex.empty().add(claims: stateClaims)

        var terminalClaims: [SpatialClaim] = []
        var fullTransClaims: [SpatialClaim] = []
        for (planIdx, plan) in transitionPlans.enumerated() {
            terminalClaims.append(try spatialPathClaim(
                id: "transition-terminal:\(planIdx):source",
                owner: "transition-terminal:\(planIdx):source",
                role: .route,
                points: Array(plan.path.prefix(2))
            ))
            terminalClaims.append(try spatialPathClaim(
                id: "transition-terminal:\(planIdx):target",
                owner: "transition-terminal:\(planIdx):target",
                role: .route,
                points: Array(plan.path.suffix(2))
            ))
            fullTransClaims.append(try spatialPathClaim(
                id: "transition:\(planIdx)",
                owner: "transition:\(planIdx)",
                role: .route,
                points: plan.path
            ))
            if let lbl = plan.label, !lbl.lines.isEmpty {
                let w = max(1, lbl.lines.map(diagramTextWidth).max() ?? 1)
                fullTransClaims.append(try spatialRectClaim(
                    id: "transition-label:\(planIdx)",
                    owner: "transition-label:\(planIdx)",
                    role: .label,
                    left: lbl.x,
                    top: lbl.y,
                    width: w,
                    height: lbl.lines.count
                ))
            }
        }
        var reserved = try noteSpace.add(claims: terminalClaims)
        var space = try reserved.add(claims: fullTransClaims)
        var noteBounds: [StateDiagramNoteBounds] = []
        let clear1 = SpatialCollisionPolicy(clearance: .uniform(1))

        for (index, note) in diagram.notes.enumerated() {
            guard let target = layout.bounds[note.target] else { continue }
            let size = stateNoteSize(note)
            let gap = 4
            let baseLeft = note.position == .right ? target.left + target.width + gap : target.left - size.width - gap
            let baseTop = target.centerY - floorDiv(size.height, 2)
            var candidates = [baseTop, target.top - size.height - 2, target.top + target.height + 2]
            for distance in 0..<12 {
                candidates.append(baseTop - distance - 1)
                candidates.append(baseTop + distance + 1)
            }
            var candidateBounds: [StateDiagramNoteBounds] = []
            for outward in 0..<5 {
                let left = baseLeft + (note.position == .right ? 1 : -1) * outward * (size.width + 2)
                for top in candidates {
                    candidateBounds.append(stateCreateNoteBound(note, index: index, left: left, top: top, size: size))
                }
            }

            func findPlacement(_ candidateSpace: SpatialIndex, limit: Int) throws -> (bound: StateDiagramNoteBounds, connector: StateDiagramNoteConnector)? {
                let connectorSearch = createStateSearchSpace(candidateSpace) { $0 == .label ? 1 : 0 }
                for var bound in candidateBounds.prefix(limit) {
                    if bound.left < 0 { continue }
                    let owner = "note:\(index)"
                    if !(try candidateSpace.isFree(try spatialRectClaim(id: "\(owner):body", owner: owner, role: .body, bounds: bound.diagramBounds), policy: clear1)) {
                        continue
                    }
                    if let connector = stateFindNoteConnector(search: connectorSearch, bounds: bound, target: target, budget: budget) {
                        bound.connector = connector
                        return (bound, connector)
                    }
                }
                return nil
            }

            let placement: (bound: StateDiagramNoteBounds, connector: StateDiagramNoteConnector)
            if let p = try findPlacement(space, limit: 1) { placement = p }
            else if let p = try findPlacement(noteSpace, limit: 1) { placement = p }
            else if let p = try findPlacement(space, limit: stateMaxStrictNotePlacements) { placement = p }
            else if let p = try findPlacement(reserved, limit: candidateBounds.count) { placement = p }
            else { placement = try stateOutsideNotePlacement(space: noteSpace, note: note, index: index, target: target, size: size) }

            let owner = "note:\(index)"
            let claims = [
                try spatialRectClaim(id: "\(owner):body", owner: owner, role: .body, bounds: placement.bound.diagramBounds),
                try spatialPathClaim(id: "\(owner):connector", owner: owner, role: .boundary, points: placement.connector.points),
            ]
            noteBounds.append(placement.bound)
            noteSpace = try noteSpace.add(claims: claims)
            reserved = try reserved.add(claims: claims)
            space = try space.add(claims: claims)
        }
        layout.noteBounds = noteBounds
    }

    private static func stateFinalizeLayout(
        _ diagram: StateDiagram,
        layout initial: StateDiagramLayout,
        budget: StateSearchBudget
    ) throws -> StateDiagramLayout {
        if diagram.composites.isEmpty && diagram.notes.isEmpty { return initial }
        var layout = initial
        stateAddCompositeBounds(diagram, layout: &layout)
        stateNormalizeLayout(&layout)
        stateExpandCompositeBoundsForInternalRouting(diagram, layout: &layout)
        if !diagram.notes.isEmpty {
            let allBounds = Array(layout.bounds.values)
            let feedbackLaneY = (allBounds.map { $0.top + $0.height }.max() ?? 0) + 3
            let feedbackTopY = min(0, allBounds.map(\.top).min() ?? 0) - 3
            let transPlans = try createStateTransitionRenderPlans(
                diagram,
                bounds: layout.bounds,
                feedbackLaneY: feedbackLaneY,
                options: StateTransitionRenderOptions(feedbackTopY: feedbackTopY, repairRoutes: false, searchBudget: budget)
            )
            try statePlaceNotesAroundTransitions(diagram, layout: &layout, transitionPlans: transPlans, budget: budget)
        }
        stateExpandCompositeBoundsForNotes(diagram, layout: &layout)
        stateExpandCompositeBoundsForInternalRouting(diagram, layout: &layout)
        _ = separateExternalBoundsFromComposites(diagram, layout: &layout)
        stateNormalizeLayout(&layout)
        return layout
    }

    private static func stateAvailableTop(_ bounds: [StateDiagramBoxBounds], left: Int, top: Int, width: Int, height: Int) -> Int {
        var available = top
        while let collision = bounds.first(where: { stateIntersects(left: left, top: available, width: width, height: height, bound: $0, padding: 0) }) {
            available = collision.top + collision.height + 3
        }
        return available
    }

    private static func stateCreateHorizontalLayout(_ diagram: StateDiagram, options: StateDiagramLayoutOptions) -> StateDiagramLayout {
        let sizes = Dictionary(uniqueKeysWithValues: diagram.states.map { ($0.id, stateBoxSize($0)) })
        var bounds: [String: StateDiagramBoxBounds] = [:]
        var boundsOrder: [String] = []
        let statesById = Dictionary(uniqueKeysWithValues: diagram.states.map { ($0.id, $0) })
        let mainPath = stateComputeMainPath(diagram)
        let mainIds = Set(mainPath)
        let mainPathIndex = Dictionary(uniqueKeysWithValues: mainPath.enumerated().map { ($0.element, $0.offset) })
        let baselineY = max(1, diagram.transitions.map { measureStateTransitionLabel($0.label).height }.max() ?? 1)
        let defaultGap = options.minStateGap + 8
        var x = 0

        for (index, id) in mainPath.enumerated() {
            guard let state = statesById[id], let size = sizes[id] else { continue }
            let top = state.kind == .state ? baselineY - floorDiv(size.height, 2) : baselineY
            bounds[id] = StateDiagramBoxBounds(
                id: id,
                left: x,
                top: top,
                width: size.width,
                height: size.height,
                centerX: x + floorDiv(size.width, 2),
                centerY: top + floorDiv(size.height, 2)
            )
            boundsOrder.append(id)
            let nextId = (index + 1 < mainPath.count) ? mainPath[index + 1] : nil
            let adjacentLabelWidth = diagram.transitions
                .filter { $0.from == id && $0.to == nextId }
                .reduce(0) { max($0, measureStateTransitionLabel($1.label).width) }
            let crossesComposite = nextId != nil && statesById[id]?.parentId != statesById[nextId!]?.parentId
            x += size.width + max(defaultGap, adjacentLabelWidth + (crossesComposite ? 6 : 2))
        }

        var branchParentOrder: [String] = []
        var branchesByParent: [String: [String]] = [:]
        for t in diagram.transitions {
            if !mainIds.contains(t.from) || mainIds.contains(t.to) { continue }
            if branchesByParent[t.from] == nil { branchParentOrder.append(t.from) }
            if !(branchesByParent[t.from]?.contains(t.to) ?? false) {
                branchesByParent[t.from, default: []].append(t.to)
            }
        }

        for parentId in branchParentOrder {
            guard let parent = bounds[parentId], let branchIds = branchesByParent[parentId] else { continue }
            let branchGap = defaultGap
            let branchSizes = branchIds.compactMap { sizes[$0] }
            let totalWidth = branchSizes.reduce(0) { $0 + $1.width } + max(0, branchSizes.count - 1) * branchGap
            let parentIdx = mainPathIndex[parentId]
            let joinIds = branchIds.map { id -> String? in
                diagram.transitions.first { t in
                    t.from == id && mainIds.contains(t.to) && parentIdx != nil && (mainPathIndex[t.to] ?? -1) > parentIdx! + 1
                }?.to
            }
            let commonJoin: String? = (joinIds.first.flatMap { $0 } != nil && joinIds.allSatisfy { $0 == joinIds[0] }) ? joinIds[0] : nil
            let parallelLane: StateDiagramBoxBounds? = (commonJoin != nil && parentIdx != nil && parentIdx! + 1 < mainPath.count)
                ? bounds[mainPath[parentIdx! + 1]]
                : nil
            var left = (parallelLane?.centerX ?? parent.centerX) - floorDiv(totalWidth, 2)
            for branchId in branchIds {
                if bounds[branchId] != nil { continue }
                guard let size = sizes[branchId] else { continue }
                let currentBounds = boundsOrder.compactMap { bounds[$0] }
                let top = stateAvailableTop(currentBounds, left: left, top: baselineY + (parallelLane != nil ? 6 : 5), width: size.width, height: size.height)
                bounds[branchId] = StateDiagramBoxBounds(
                    id: branchId,
                    left: left,
                    top: top,
                    width: size.width,
                    height: size.height,
                    centerX: left + floorDiv(size.width, 2),
                    centerY: top + floorDiv(size.height, 2)
                )
                boundsOrder.append(branchId)
                left += size.width + branchGap
            }
        }

        let ranks = stateComputeRanks(diagram)
        let fallbackStates = diagram.states
            .enumerated()
            .filter { bounds[$0.element.id] == nil }
            .sorted { l, r in
                let lr = ranks[l.element.id] ?? 0
                let rr = ranks[r.element.id] ?? 0
                if lr != rr { return lr < rr }
                return l.offset < r.offset
            }
            .map(\.element)

        for state in fallbackStates {
            guard let size = sizes[state.id] else { continue }
            let top = baselineY + 5
            let rank = ranks[state.id] ?? bounds.count
            var left = rank * (size.width + defaultGap)
            let currentBounds = boundsOrder.compactMap { bounds[$0] }
            while let collision = currentBounds.first(where: { b in
                left < b.left + b.width + defaultGap && left + size.width + defaultGap > b.left
                    && top < b.top + b.height && top + size.height > b.top
            }) {
                left = collision.left + collision.width + defaultGap
            }
            bounds[state.id] = StateDiagramBoxBounds(
                id: state.id,
                left: left,
                top: top,
                width: size.width,
                height: size.height,
                centerX: left + floorDiv(size.width, 2),
                centerY: top + floorDiv(size.height, 2)
            )
            boundsOrder.append(state.id)
        }

        let minX = min(0, bounds.values.map(\.left).min() ?? 0)
        if minX < 0 {
            for key in Array(bounds.keys) {
                bounds[key]!.left -= minX
                bounds[key]!.centerX -= minX
            }
        }

        if diagram.direction == .RL {
            let right = max(0, bounds.values.map { $0.left + $0.width }.max() ?? 0)
            for key in Array(bounds.keys) {
                let b = bounds[key]!
                let newLeft = right - b.left - b.width
                bounds[key]!.left = newLeft
                bounds[key]!.centerX = newLeft + floorDiv(b.width, 2)
            }
            let branchLabelGutter = diagram.transitions.compactMap { t -> Int? in
                guard let from = bounds[t.from], let to = bounds[t.to], from.centerY != to.centerY else { return nil }
                return measureStateTransitionLabel(t.label).width + 2
            }.max() ?? 0
            if branchLabelGutter > 0 {
                for key in Array(bounds.keys) {
                    stateShiftBoxBound(&bounds[key]!, dx: branchLabelGutter, dy: 0)
                }
            }
        }

        return StateDiagramLayout(bounds: bounds, sizes: sizes)
    }

    // parity: merman/src/state/layout.ts#createStateDiagramLayout [status=implemented hash=0482748d2445]
    public static func createStateDiagramLayout(
        _ diagram: StateDiagram,
        options: StateDiagramLayoutOptions = StateDiagramLayoutOptions()
    ) throws -> StateDiagramLayout {
        let budget = options.searchBudget ?? createStateSearchBudget()
        if diagram.direction == .LR || diagram.direction == .RL {
            return try stateFinalizeLayout(diagram, layout: stateCreateHorizontalLayout(diagram, options: options), budget: budget)
        }

        let ranks = stateComputeRanks(diagram)
        let maxRank = max(0, ranks.values.max() ?? 0)
        var byRank: [Int: [StateDiagramState]] = [:]
        for state in diagram.states {
            let r = ranks[state.id] ?? 0
            let rank = diagram.direction == .BT ? maxRank - r : r
            byRank[rank, default: []].append(state)
        }

        let rankKeys = byRank.keys.sorted()
        let sizes = Dictionary(uniqueKeysWithValues: diagram.states.map { ($0.id, stateBoxSize($0)) })
        var bounds: [String: StateDiagramBoxBounds] = [:]
        var outgoingLabelRows: [String: Int] = [:]
        var selfTransitionCounts: [String: Int] = [:]
        for t in diagram.transitions {
            let rows = measureStateTransitionLabel(t.label).height
            outgoingLabelRows[t.from] = max(outgoingLabelRows[t.from] ?? 0, rows)
            if t.from == t.to {
                selfTransitionCounts[t.from, default: 0] += 1
            }
        }

        let singleColumnCenter = rankKeys.compactMap { rank -> Int? in
            guard let list = byRank[rank], list.count == 1, let sz = sizes[list[0].id] else { return nil }
            return floorDiv(sz.width, 2)
        }.max() ?? 0

        var y = 0
        for rank in rankKeys {
            let states = byRank[rank] ?? []
            let rowHeight = states.compactMap { sizes[$0.id]?.height }.max() ?? 0
            var x = 0
            for state in states {
                let size = sizes[state.id]!
                let top = y + floorDiv(rowHeight - size.height, 2)
                let left = states.count == 1 ? singleColumnCenter - floorDiv(size.width, 2) : x
                bounds[state.id] = StateDiagramBoxBounds(
                    id: state.id,
                    left: left,
                    top: top,
                    width: size.width,
                    height: size.height,
                    centerX: left + floorDiv(size.width, 2),
                    centerY: top + floorDiv(size.height, 2)
                )
                x += size.width + options.minStateGap + 8
            }
            let labelRows = states.reduce(0) { max($0, outgoingLabelRows[$1.id] ?? 0) }
            let selfRows = states.reduce(0) { max($0, (selfTransitionCounts[$1.id] ?? 0) * 3 + 1) }
            let pseudoClearance = states.contains { $0.kind == .choice } ? 2 : 0
            y += rowHeight + max(4, max(labelRows + 3, selfRows)) + pseudoClearance
        }

        return try stateFinalizeLayout(diagram, layout: StateDiagramLayout(bounds: bounds, sizes: sizes), budget: budget)
    }

    // parity: merman/src/state/layout.ts#expandCompositeBoundsForFeedback [status=implemented hash=5a2f1db8b66a]
    public static func expandCompositeBoundsForFeedback(
        _ diagram: StateDiagram,
        bounds: inout [String: StateDiagramBoxBounds],
        compositeBounds: inout [String: StateDiagramBoxBounds],
        feedbackLaneY: Int
    ) {
        if diagram.direction != .LR && diagram.direction != .RL { return }
        let statesById = Dictionary(uniqueKeysWithValues: diagram.states.map { ($0.id, $0) })
        let compositesById = Dictionary(uniqueKeysWithValues: diagram.composites.map { ($0.id, $0) })

        for comp in diagram.composites {
            guard var compBound = compositeBounds[comp.id] else { continue }
            let hasInternalFeedback = diagram.transitions.contains { t in
                guard stateBelongsToComposite(t.from, compositeId: comp.id, statesById: statesById, compositesById: compositesById),
                      stateBelongsToComposite(t.to, compositeId: comp.id, statesById: statesById, compositesById: compositesById),
                      let from = bounds[t.from],
                      let to = bounds[t.to]
                else { return false }
                return isStateHorizontalFeedback(diagram, from: from, to: to)
            }
            if !hasInternalFeedback { continue }
            let bottom = max(compBound.top + compBound.height, feedbackLaneY + 2)
            compBound.height = bottom - compBound.top
            compBound.centerY = compBound.top + floorDiv(compBound.height, 2)
            compositeBounds[comp.id] = compBound
            bounds[comp.id] = compBound
        }
    }

    // parity: merman/src/state/layout.ts#expandCompositeBoundsForInternalTransitions [status=implemented hash=39305adb169c]
    public static func expandCompositeBoundsForInternalTransitions(
        _ diagram: StateDiagram,
        compositeBounds: inout [String: StateDiagramBoxBounds],
        bounds: inout [String: StateDiagramBoxBounds],
        transitionPlans: [StateTransitionRenderPlan]
    ) {
        let statesById = Dictionary(uniqueKeysWithValues: diagram.states.map { ($0.id, $0) })
        let compositesById = Dictionary(uniqueKeysWithValues: diagram.composites.map { ($0.id, $0) })

        for comp in diagram.composites {
            guard var bound = compositeBounds[comp.id] else { continue }
            let internalPlans = transitionPlans.filter { plan in
                stateBelongsToComposite(plan.route.transition.from, compositeId: comp.id, statesById: statesById, compositesById: compositesById)
                    && stateBelongsToComposite(plan.route.transition.to, compositeId: comp.id, statesById: statesById, compositesById: compositesById)
            }
            var occupied: [DiagramPoint] = []
            for plan in internalPlans {
                for cell in plan.cells { occupied.append(point(cell.x, cell.y)) }
                if let lbl = plan.label {
                    for (row, line) in lbl.lines.enumerated() {
                        let w = diagramTextWidth(line)
                        for col in 0..<w { occupied.append(point(lbl.x + col, lbl.y + row)) }
                    }
                }
            }
            if occupied.isEmpty { continue }
            let left = min(bound.left, (occupied.map(\.x).min() ?? bound.left) - 1)
            let top = min(bound.top, (occupied.map(\.y).min() ?? bound.top) - 1)
            let right = max(bound.left + bound.width, (occupied.map(\.x).max() ?? 0) + 2)
            let bottom = max(bound.top + bound.height, (occupied.map(\.y).max() ?? 0) + 2)
            bound.left = left
            bound.top = top
            bound.width = right - left
            bound.height = bottom - top
            bound.centerX = bound.left + floorDiv(bound.width, 2)
            bound.centerY = bound.top + floorDiv(bound.height, 2)
            compositeBounds[comp.id] = bound
            bounds[comp.id] = bound
        }
        stateEnforceCompositeMargins(diagram, compositeBounds: &compositeBounds, bounds: &bounds)
    }
}
