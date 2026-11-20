import Foundation

extension Merman {
    // parity: merman/src/core/geometry.ts#DiagramAxis [status=implemented hash=88e818cc278e]
    public enum DiagramAxis: String, Equatable, Hashable, Sendable, Codable {
        case x
        case y
    }

    // parity: merman/src/core/geometry.ts#DiagramDirection [status=implemented hash=c1f8f1656288]
    public enum DiagramDirection: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
        case up
        case down
        case left
        case right
    }

    // parity: merman/src/core/geometry.ts#DiagramSide [status=implemented hash=b4478927fc41]
    public enum DiagramSide: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
        case left
        case right
        case top
        case bottom
    }

    public enum BoundsSurface: String, Equatable, Hashable, Sendable {
        case border
        case outside
    }

    // parity: merman/src/core/geometry.ts#DiagramPoint [status=implemented hash=b1da65aa5a6b]
    public struct DiagramPoint: Equatable, Hashable, Sendable, Codable {
        public var x: Int
        public var y: Int

        public init(x: Int, y: Int) {
            self.x = x
            self.y = y
        }
    }

    // parity: merman/src/core/geometry.ts#DiagramBounds [status=implemented hash=9b39f53292c1]
    public struct DiagramBounds: Equatable, Hashable, Sendable, Codable {
        public var left: Int
        public var top: Int
        public var width: Int
        public var height: Int
        public var centerX: Int
        public var centerY: Int

        public init(left: Int, top: Int, width: Int, height: Int, centerX: Int, centerY: Int) {
            self.left = left
            self.top = top
            self.width = width
            self.height = height
            self.centerX = centerX
            self.centerY = centerY
        }
    }

    // parity: merman/src/core/geometry.ts#DiagramSegment [status=implemented hash=b30d77903c00]
    public struct DiagramSegment: Equatable, Hashable, Sendable, Codable {
        public var from: DiagramPoint
        public var to: DiagramPoint
        public var axis: DiagramAxis
        public var direction: DiagramDirection
        public var length: Int

        public init(from: DiagramPoint, to: DiagramPoint, axis: DiagramAxis, direction: DiagramDirection, length: Int) {
            self.from = from
            self.to = to
            self.axis = axis
            self.direction = direction
            self.length = length
        }
    }

    // parity: merman/src/core/geometry.ts#DiagramLane [status=implemented hash=972cd06a9b0a]
    public struct DiagramLane: Equatable, Hashable, Sendable, Codable {
        public var axis: DiagramAxis
        public var coordinate: Int

        public init(axis: DiagramAxis, coordinate: Int) {
            self.axis = axis
            self.coordinate = coordinate
        }
    }

    // parity: merman/src/core/geometry.ts#DiagramSpan [status=implemented hash=5fc43989a5e3]
    public struct DiagramSpan: Equatable, Hashable, Sendable, Codable {
        public var start: Int
        public var end: Int

        public init(start: Int, end: Int) {
            self.start = start
            self.end = end
        }
    }

    // parity: merman/src/core/geometry.ts#point [status=implemented hash=0f714e49ab91]
    public static func point(_ x: Int, _ y: Int) -> DiagramPoint {
        DiagramPoint(x: x, y: y)
    }

    // parity: merman/src/core/geometry.ts#diagramBoundsFromRect [status=implemented hash=587d26f7f04d]
    public static func diagramBoundsFromRect(_ left: Int, _ top: Int, _ width: Int, _ height: Int) -> DiagramBounds {
        DiagramBounds(
            left: left,
            top: top,
            width: width,
            height: height,
            centerX: left + floorDiv(width, 2),
            centerY: top + floorDiv(height, 2)
        )
    }

    // parity: merman/src/core/geometry.ts#translateDiagramBounds [status=implemented hash=0bde3b44345b]
    public static func translateDiagramBounds(_ bounds: inout DiagramBounds, dx: Int, dy: Int) {
        bounds.left += dx
        bounds.top += dy
        bounds.centerX += dx
        bounds.centerY += dy
    }

    // parity: merman/src/core/geometry.ts#diagramBoundsFromBounds [status=implemented hash=1711845f8b7d]
    public static func diagramBoundsFromBounds(_ bounds: [DiagramBounds]) -> DiagramBounds? {
        guard let first = bounds.first else { return nil }
        var left = first.left
        var top = first.top
        var right = first.left + first.width
        var bottom = first.top + first.height
        for bound in bounds.dropFirst() {
            left = min(left, bound.left)
            top = min(top, bound.top)
            right = max(right, bound.left + bound.width)
            bottom = max(bottom, bound.top + bound.height)
        }
        return diagramBoundsFromRect(left, top, right - left, bottom - top)
    }

    // parity: merman/src/core/geometry.ts#diagramBoundsFromPoints [status=implemented hash=3b21ddf165f6]
    public static func diagramBoundsFromPoints(_ points: [DiagramPoint]) -> DiagramBounds? {
        guard let first = points.first else { return nil }
        var left = first.x
        var top = first.y
        var right = first.x
        var bottom = first.y
        for pt in points.dropFirst() {
            left = min(left, pt.x)
            top = min(top, pt.y)
            right = max(right, pt.x)
            bottom = max(bottom, pt.y)
        }
        return diagramBoundsFromRect(left, top, right - left + 1, bottom - top + 1)
    }

    // parity: merman/src/core/geometry.ts#coordinate [status=implemented hash=7e564497e4ca]
    public static func coordinate(_ pt: DiagramPoint, axis: DiagramAxis) -> Int {
        axis == .x ? pt.x : pt.y
    }

    // parity: merman/src/core/geometry.ts#withCoordinate [status=implemented hash=6ff1119f1796]
    public static func withCoordinate(_ pt: DiagramPoint, axis: DiagramAxis, value: Int) -> DiagramPoint {
        axis == .x ? DiagramPoint(x: value, y: pt.y) : DiagramPoint(x: pt.x, y: value)
    }

    // parity: merman/src/core/geometry.ts#shiftPoint [status=implemented hash=406be43f0742]
    public static func shiftPoint(_ pt: DiagramPoint, direction: DiagramDirection, distance: Int = 1) -> DiagramPoint {
        switch direction {
        case .left:
            return DiagramPoint(x: pt.x - distance, y: pt.y)
        case .right:
            return DiagramPoint(x: pt.x + distance, y: pt.y)
        case .up:
            return DiagramPoint(x: pt.x, y: pt.y - distance)
        case .down:
            return DiagramPoint(x: pt.x, y: pt.y + distance)
        }
    }

    // parity: merman/src/core/geometry.ts#clampPoint [status=implemented hash=166b89ea84ef]
    public static func clampPoint(_ pt: DiagramPoint, min minPoint: DiagramPoint = DiagramPoint(x: 0, y: 0)) -> DiagramPoint {
        DiagramPoint(x: max(minPoint.x, pt.x), y: max(minPoint.y, pt.y))
    }

    // parity: merman/src/core/geometry.ts#samePoint [status=implemented hash=f67f50a2189b]
    public static func samePoint(_ left: DiagramPoint, _ right: DiagramPoint) -> Bool {
        left.x == right.x && left.y == right.y
    }

    // parity: merman/src/core/geometry.ts#directionAxis [status=implemented hash=08af64ec7f27]
    public static func directionAxis(_ direction: DiagramDirection) -> DiagramAxis {
        switch direction {
        case .left, .right: return .x
        case .up, .down: return .y
        }
    }

    // parity: merman/src/core/geometry.ts#directionSign [status=implemented hash=bbd5934e3534]
    public static func directionSign(_ direction: DiagramDirection) -> Int {
        switch direction {
        case .left, .up: return -1
        case .right, .down: return 1
        }
    }

    // parity: merman/src/core/geometry.ts#sideForDirection [status=implemented hash=4c2c8f033a4e]
    public static func sideForDirection(_ direction: DiagramDirection) -> DiagramSide {
        switch direction {
        case .left: return .left
        case .right: return .right
        case .up: return .top
        case .down: return .bottom
        }
    }

    // parity: merman/src/core/geometry.ts#oppositeSide [status=implemented hash=fd04366832a2]
    public static func oppositeSide(_ side: DiagramSide) -> DiagramSide {
        switch side {
        case .left: return .right
        case .right: return .left
        case .top: return .bottom
        case .bottom: return .top
        }
    }

    // parity: merman/src/core/geometry.ts#directionBetween [status=implemented hash=fd1036c3bbe3]
    public static func directionBetween(_ from: DiagramPoint, _ to: DiagramPoint) -> DiagramDirection? {
        if from.y == to.y {
            if to.x > from.x { return .right }
            if to.x < from.x { return .left }
        }
        if from.x == to.x {
            if to.y > from.y { return .down }
            if to.y < from.y { return .up }
        }
        return nil
    }

    // parity: merman/src/core/geometry.ts#boundsCenter [status=implemented hash=521c89c013bd]
    public static func boundsCenter(_ bounds: DiagramBounds) -> DiagramPoint {
        point(bounds.centerX, bounds.centerY)
    }

    // parity: merman/src/core/geometry.ts#boundsSidePoint [status=implemented hash=ce848d00aa24]
    public static func boundsSidePoint(
        _ bounds: DiagramBounds,
        side: DiagramSide,
        surface: BoundsSurface = .outside
    ) -> DiagramPoint {
        switch side {
        case .left:
            return point(bounds.left - (surface == .outside ? 1 : 0), bounds.centerY)
        case .right:
            return point(bounds.left + bounds.width - (surface == .outside ? 0 : 1), bounds.centerY)
        case .top:
            return point(bounds.centerX, bounds.top - (surface == .outside ? 1 : 0))
        case .bottom:
            return point(bounds.centerX, bounds.top + bounds.height - (surface == .outside ? 0 : 1))
        }
    }

    // parity: merman/src/core/geometry.ts#centerCoordinate [status=implemented hash=ddcd9095ac13]
    public static func centerCoordinate(_ bounds: DiagramBounds, axis: DiagramAxis) -> Int {
        axis == .x ? bounds.centerX : bounds.centerY
    }

    // parity: merman/src/core/geometry.ts#snapCoordinate [status=implemented hash=a9ce82d7da89]
    public static func snapCoordinate(_ source: Int, _ target: Int, tolerance: Int) -> Int {
        abs(source - target) <= tolerance ? target : source
    }

    // parity: merman/src/core/geometry.ts#pathThrough [status=implemented hash=364fcecf2ee3]
    public static func pathThrough(_ points: [DiagramPoint]) -> [DiagramPoint] {
        var path: [DiagramPoint] = []
        for next in points {
            if let last = path.last, samePoint(last, next) { continue }
            path.append(point(next.x, next.y))
        }
        return path
    }

    // parity: merman/src/core/geometry.ts#lane [status=implemented hash=d7b8506ecc9a]
    public static func lane(_ axis: DiagramAxis, _ coordinate: Int) -> DiagramLane {
        DiagramLane(axis: axis, coordinate: coordinate)
    }

    // parity: merman/src/core/geometry.ts#pathViaLane [status=implemented hash=2b182d96a9b6]
    public static func pathViaLane(_ start: DiagramPoint, _ routeLane: DiagramLane, _ end: DiagramPoint) -> [DiagramPoint] {
        pathThrough([
            start,
            withCoordinate(start, axis: routeLane.axis, value: routeLane.coordinate),
            withCoordinate(end, axis: routeLane.axis, value: routeLane.coordinate),
            end,
        ])
    }

    private static func dominantAxis(_ start: DiagramPoint, _ end: DiagramPoint) -> DiagramAxis {
        abs(end.x - start.x) >= abs(end.y - start.y) ? .x : .y
    }

    private static func terminalLane(_ start: DiagramPoint, _ end: DiagramPoint, axis: DiagramAxis, terminalClearance: Int) -> Int {
        let startCoordinate = coordinate(start, axis: axis)
        let endCoordinate = coordinate(end, axis: axis)
        let delta = endCoordinate - startCoordinate
        if delta == 0 { return endCoordinate }
        let sign = delta > 0 ? 1 : -1
        return endCoordinate - sign * min(terminalClearance, max(1, abs(delta) - 1))
    }

    // parity: merman/src/core/geometry.ts#orthogonalPath [status=implemented hash=ab7ecf89d665]
    public static func orthogonalPath(
        _ start: DiagramPoint,
        _ end: DiagramPoint,
        preferredAxis: DiagramAxis? = nil,
        terminalClearance: Int = 4
    ) -> [DiagramPoint] {
        if start.x == end.x || start.y == end.y {
            return pathThrough([start, end])
        }
        let laneAxis = preferredAxis ?? dominantAxis(start, end)
        return pathViaLane(start, lane(laneAxis, terminalLane(start, end, axis: laneAxis, terminalClearance: terminalClearance)), end)
    }

    // parity: merman/src/core/geometry.ts#segmentBetween [status=implemented hash=64d0bba3e719]
    public static func segmentBetween(_ from: DiagramPoint, _ to: DiagramPoint) -> DiagramSegment? {
        guard let direction = directionBetween(from, to) else { return nil }
        let axis = directionAxis(direction)
        return DiagramSegment(
            from: from,
            to: to,
            axis: axis,
            direction: direction,
            length: abs(coordinate(to, axis: axis) - coordinate(from, axis: axis))
        )
    }

    // parity: merman/src/core/geometry.ts#walkOrthogonalSegment [status=implemented hash=bc0e8bfd94f1]
    public static func walkOrthogonalSegment(
        _ from: DiagramPoint,
        _ to: DiagramPoint,
        includeStart: Bool,
        visit: (DiagramPoint) -> Void
    ) {
        walkOrthogonalSegmentWhile(from, to, includeStart: includeStart) { pt in
            visit(pt)
            return true
        }
    }

    public static func walkOrthogonalSegmentWhile(
        _ from: DiagramPoint,
        _ to: DiagramPoint,
        includeStart: Bool,
        visit: (DiagramPoint) -> Bool
    ) {
        guard let direction = directionBetween(from, to) else { return }
        let dx = direction == .right ? 1 : (direction == .left ? -1 : 0)
        let dy = direction == .down ? 1 : (direction == .up ? -1 : 0)
        var cursor = includeStart ? from : point(from.x + dx, from.y + dy)
        while !samePoint(cursor, to) {
            if !visit(cursor) { return }
            cursor = point(cursor.x + dx, cursor.y + dy)
        }
    }

    // parity: merman/src/core/geometry.ts#orthogonalPathPoints [status=implemented hash=8b703c2e0dff]
    public static func orthogonalPathPoints(_ points: [DiagramPoint]) -> [DiagramPoint] {
        var path: [DiagramPoint] = []
        guard points.count >= 2 else { return path }
        for index in 1..<points.count {
            let from = points[index - 1]
            let to = points[index]
            guard let direction = directionBetween(from, to) else { continue }
            let dx = direction == .right ? 1 : (direction == .left ? -1 : 0)
            let dy = direction == .down ? 1 : (direction == .up ? -1 : 0)
            var cursor = path.isEmpty ? point(from.x, from.y) : point(from.x + dx, from.y + dy)
            while true {
                path.append(cursor)
                if samePoint(cursor, to) { break }
                cursor = point(cursor.x + dx, cursor.y + dy)
            }
        }
        return path
    }

    // parity: merman/src/core/geometry.ts#orderedSpan [status=implemented hash=23ac892ac2d1]
    public static func orderedSpan(_ left: Int, _ right: Int) -> DiagramSpan {
        left <= right ? DiagramSpan(start: left, end: right) : DiagramSpan(start: right, end: left)
    }

    // parity: merman/src/core/geometry.ts#segmentSpan [status=implemented hash=31fd9a32097e]
    public static func segmentSpan(_ segment: DiagramSegment) -> DiagramSpan {
        orderedSpan(coordinate(segment.from, axis: segment.axis), coordinate(segment.to, axis: segment.axis))
    }

    // parity: merman/src/core/geometry.ts#pointOnSegment [status=implemented hash=d98b9d739c03]
    public static func pointOnSegment(_ segment: DiagramSegment, coordinateValue: Int) -> DiagramPoint {
        withCoordinate(segment.from, axis: segment.axis, value: coordinateValue)
    }

    // parity: merman/src/core/geometry.ts#insetSpan [status=implemented hash=39c6635259e6]
    public static func insetSpan(_ span: DiagramSpan, amount: Int) -> DiagramSpan {
        DiagramSpan(start: span.start + amount, end: span.end - amount)
    }

    // parity: merman/src/core/geometry.ts#spanCapacity [status=implemented hash=a6450290a25a]
    public static func spanCapacity(_ span: DiagramSpan) -> Int {
        max(0, span.end - span.start + 1)
    }

    // parity: merman/src/core/geometry.ts#centeredSpanStart [status=implemented hash=d4fe8a2923ec]
    public static func centeredSpanStart(_ span: DiagramSpan, width: Int) -> Int {
        span.start + floorDiv(spanCapacity(span) - width, 2)
    }

    // parity: merman/src/core/geometry.ts#midpoint [status=implemented hash=2d3dcfc8d549]
    public static func midpoint(_ span: DiagramSpan) -> Int {
        jsRound(Double(span.start + span.end) / 2.0)
    }

    // parity: merman/src/core/geometry.ts#advanceCoordinate [status=implemented hash=d83855d8afab]
    public static func advanceCoordinate(_ origin: Int, direction: DiagramDirection, distance: Int) -> Int {
        origin + directionSign(direction) * distance
    }

    // parity: merman/src/core/geometry.ts#beforeNearestCoordinate [status=implemented hash=9ae4b14f40fc]
    public static func beforeNearestCoordinate(
        _ points: [DiagramPoint],
        axis: DiagramAxis,
        direction: DiagramDirection,
        clearance: Int
    ) -> Int {
        let coords = points.map { coordinate($0, axis: axis) }
        let nearest = directionSign(direction) > 0 ? (coords.min() ?? 0) : (coords.max() ?? 0)
        return advanceCoordinate(nearest, direction: direction, distance: -clearance)
    }

    // parity: merman/src/core/geometry.ts#afterFarthestCoordinate [status=implemented hash=9ab846d0376f]
    public static func afterFarthestCoordinate(
        _ points: [DiagramPoint],
        axis: DiagramAxis,
        direction: DiagramDirection,
        clearance: Int
    ) -> Int {
        let coords = points.map { coordinate($0, axis: axis) }
        let farthest = directionSign(direction) > 0 ? (coords.max() ?? 0) : (coords.min() ?? 0)
        return advanceCoordinate(farthest, direction: direction, distance: clearance)
    }

    // parity: merman/src/core/geometry.ts#keepBefore [status=implemented hash=c37f0b7a9138]
    public static func keepBefore(_ preferred: Int, boundary: Int, direction: DiagramDirection) -> Int {
        directionSign(direction) > 0 ? min(preferred, boundary) : max(preferred, boundary)
    }

    // parity: merman/src/core/geometry.ts#keepAfter [status=implemented hash=af5ee84414b6]
    public static func keepAfter(_ preferred: Int, boundary: Int, direction: DiagramDirection) -> Int {
        directionSign(direction) > 0 ? max(preferred, boundary) : min(preferred, boundary)
    }
}
