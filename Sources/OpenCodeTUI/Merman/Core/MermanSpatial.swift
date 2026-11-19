extension Merman {
    public struct SpatialError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var description: String { message }
    }

    // parity: merman/src/core/spatial.ts#SpatialRole [status=implemented hash=3dec3e5a900b]
    public enum SpatialRole: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
        case body
        case boundary
        case terminal
        case route
        case label
    }

    // parity: merman/src/core/spatial.ts#SpatialSpan [status=implemented hash=43099be225ee]
    public struct SpatialSpan: Equatable, Hashable, Sendable, Codable {
        public let y: Int
        public let fromX: Int
        public let toX: Int

        public init(y: Int, fromX: Int, toX: Int) {
            self.y = y
            self.fromX = fromX
            self.toX = toX
        }
    }

    // parity: merman/src/core/spatial.ts#SpatialClaim [status=implemented hash=fca789ff7fd6]
    public struct SpatialClaim: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let owner: String
        public let role: SpatialRole
        public let spans: [SpatialSpan]

        public init(id: String, owner: String, role: SpatialRole, spans: [SpatialSpan]) {
            self.id = id
            self.owner = owner
            self.role = role
            self.spans = spans
        }
    }

    // parity: merman/src/core/spatial.ts#SpatialContact [status=implemented hash=b64a1ee28d9d]
    public struct SpatialContact: Equatable, Hashable, Sendable, Codable {
        public var owner: String
        public var points: [DiagramPoint]

        public init(owner: String, points: [DiagramPoint]) {
            self.owner = owner
            self.points = points
        }
    }

    // parity: merman/src/core/spatial.ts#SpatialConflict [status=implemented hash=17322d8a1da8]
    public struct SpatialConflict: Equatable, Hashable, Sendable, Codable {
        public var moving: SpatialClaim
        public var existing: SpatialClaim
        public var point: DiagramPoint

        public init(moving: SpatialClaim, existing: SpatialClaim, point: DiagramPoint) {
            self.moving = moving
            self.existing = existing
            self.point = point
        }
    }

    // parity: merman/src/core/spatial.ts#SpatialClearance [status=implemented hash=df354a9ef887]
    public struct SpatialClearance: Equatable, Hashable, Sendable, Codable {
        public var x: Int
        public var y: Int

        public init(x: Int, y: Int) {
            self.x = x
            self.y = y
        }
    }

    public enum SpatialClearanceSpec: Equatable, Hashable, Sendable {
        case uniform(Int)
        case xy(SpatialClearance)
        case byRole([SpatialRole: SpatialClearance])
    }

    // parity: merman/src/core/spatial.ts#SpatialCollisionPolicy [status=implemented hash=f5384cc514ef]
    public struct SpatialCollisionPolicy: Equatable, Hashable, Sendable {
        public var contacts: [SpatialContact]
        public var clearance: SpatialClearanceSpec?

        public init(contacts: [SpatialContact] = [], clearance: SpatialClearanceSpec? = nil) {
            self.contacts = contacts
            self.clearance = clearance
        }
    }

    private static func normalizedSpan(y: Int, fromX: Int, toX: Int) -> SpatialSpan {
        SpatialSpan(y: y, fromX: min(fromX, toX), toX: max(fromX, toX))
    }

    // parity: merman/src/core/spatial.ts#spatialRectSpans [status=implemented hash=5e75280e0854]
    public static func spatialRectSpans(left: Int, top: Int, width: Int, height: Int) throws -> [SpatialSpan] {
        guard width > 0 && height > 0 else {
            throw SpatialError("Spatial bounds must have positive dimensions")
        }
        return (0..<height).map { offset in
            normalizedSpan(y: top + offset, fromX: left, toX: left + width - 1)
        }
    }

    public static func spatialRectSpans(_ bounds: DiagramBounds) throws -> [SpatialSpan] {
        try spatialRectSpans(left: bounds.left, top: bounds.top, width: bounds.width, height: bounds.height)
    }

    // parity: merman/src/core/spatial.ts#spatialPathSpans [status=implemented hash=9ce37455fd7e]
    public static func spatialPathSpans(_ points: [DiagramPoint]) throws -> [SpatialSpan] {
        for index in 1..<points.count {
            if points[index].x != points[index - 1].x && points[index].y != points[index - 1].y {
                throw SpatialError("Spatial paths must be orthogonal")
            }
        }
        var cells: [Int: Set<Int>] = [:]
        func add(_ pt: DiagramPoint) {
            cells[pt.y, default: []].insert(pt.x)
        }
        if points.count == 1 {
            add(points[0])
        }
        for pt in orthogonalPathPoints(points) {
            add(pt)
        }

        var result: [SpatialSpan] = []
        for y in cells.keys.sorted() {
            let sorted = (cells[y] ?? []).sorted()
            guard let first = sorted.first else { continue }
            var start = first
            var end = first
            for x in sorted.dropFirst() {
                if x == end + 1 {
                    end = x
                    continue
                }
                result.append(normalizedSpan(y: y, fromX: start, toX: end))
                start = x
                end = x
            }
            result.append(normalizedSpan(y: y, fromX: start, toX: end))
        }
        return result
    }

    // parity: merman/src/core/spatial.ts#spatialRectClaim [status=implemented hash=7b077f2bde67]
    public static func spatialRectClaim(
        id: String,
        owner: String,
        role: SpatialRole,
        left: Int,
        top: Int,
        width: Int,
        height: Int
    ) throws -> SpatialClaim {
        SpatialClaim(id: id, owner: owner, role: role, spans: try spatialRectSpans(left: left, top: top, width: width, height: height))
    }

    public static func spatialRectClaim(
        id: String,
        owner: String,
        role: SpatialRole,
        bounds: DiagramBounds
    ) throws -> SpatialClaim {
        try spatialRectClaim(id: id, owner: owner, role: role, left: bounds.left, top: bounds.top, width: bounds.width, height: bounds.height)
    }

    // parity: merman/src/core/spatial.ts#spatialPathClaim [status=implemented hash=57e5ed3b9b9b]
    public static func spatialPathClaim(
        id: String,
        owner: String,
        role: SpatialRole,
        points: [DiagramPoint]
    ) throws -> SpatialClaim {
        SpatialClaim(id: id, owner: owner, role: role, spans: try spatialPathSpans(points))
    }

    private static func pointIsContact(_ pt: DiagramPoint, existing: SpatialClaim, contacts: [SpatialContact]) -> Bool {
        contacts.contains { contact in
            contact.owner == existing.owner &&
                contact.points.contains { $0.x == pt.x && $0.y == pt.y }
        }
    }

    private static func rolesMayOverlap(_ moving: SpatialClaim, _ existing: SpatialClaim) -> Bool {
        if moving.owner == existing.owner { return true }
        return moving.role == .route && existing.role == .route
    }

    private static func inflateSpan(_ span: SpatialSpan, clearance: SpatialClearance) -> SpatialSpan {
        SpatialSpan(y: span.y, fromX: span.fromX - clearance.x, toX: span.toX + clearance.x)
    }

    // parity: merman/src/core/spatial.ts#SpatialIndex [status=implemented hash=7484c0936e3e]
    public final class SpatialIndex: Sendable {
        public let claims: [SpatialClaim]

        // parity: merman/src/core/spatial.ts#SpatialIndex.empty [status=implemented hash=0dca034cf068]
        public static func empty() -> SpatialIndex {
            SpatialIndex(claims: [])
        }

        private init(claims: [SpatialClaim]) {
            self.claims = claims.map { claim in
                let sortedSpans = claim.spans.sorted { lhs, rhs in
                    if lhs.y != rhs.y { return lhs.y < rhs.y }
                    if lhs.fromX != rhs.fromX { return lhs.fromX < rhs.fromX }
                    return lhs.toX < rhs.toX
                }
                return SpatialClaim(id: claim.id, owner: claim.owner, role: claim.role, spans: sortedSpans)
            }
        }

        // parity: merman/src/core/spatial.ts#SpatialIndex.add [status=implemented hash=4e44291d85e9]
        public func add(_ newClaims: SpatialClaim...) throws -> SpatialIndex {
            try overlay(SpatialIndex(claims: newClaims))
        }

        public func add(claims newClaims: [SpatialClaim]) throws -> SpatialIndex {
            try overlay(SpatialIndex(claims: newClaims))
        }

        // parity: merman/src/core/spatial.ts#SpatialIndex.overlay [status=implemented hash=183de8193104]
        public func overlay(_ other: SpatialIndex) throws -> SpatialIndex {
            var map: [String: SpatialClaim] = [:]
            map.reserveCapacity(claims.count + other.claims.count)
            for claim in claims {
                map[claim.id] = claim
            }
            for claim in other.claims {
                if let existing = map[claim.id], existing != claim {
                    throw SpatialError("Conflicting spatial claim id: \(claim.id)")
                }
                map[claim.id] = claim
            }
            let sorted = map.values.sorted { $0.id < $1.id }
            return SpatialIndex(claims: sorted)
        }

        // parity: merman/src/core/spatial.ts#SpatialIndex.conflicts [status=implemented hash=120fdfe79a7a]
        public func conflicts(_ moving: SpatialClaim, policy: SpatialCollisionPolicy = SpatialCollisionPolicy()) throws -> [SpatialConflict] {
            let contacts = policy.contacts
            var result: [SpatialConflict] = []

            for existing in claims {
                if Merman.rolesMayOverlap(moving, existing) { continue }
                let clearance: SpatialClearance
                switch policy.clearance {
                case nil:
                    clearance = SpatialClearance(x: 0, y: 0)
                case .uniform(let v):
                    if v < 0 { throw SpatialError("Spatial clearance cannot be negative") }
                    clearance = SpatialClearance(x: v, y: v)
                case .xy(let c):
                    if c.x < 0 || c.y < 0 { throw SpatialError("Spatial clearance cannot be negative") }
                    clearance = c
                case .byRole(let map):
                    let c = map[existing.role] ?? SpatialClearance(x: 0, y: 0)
                    if c.x < 0 || c.y < 0 { throw SpatialError("Spatial clearance cannot be negative") }
                    clearance = c
                }

                for movingSpan in moving.spans {
                    for dy in (-clearance.y)...clearance.y {
                        let shifted = SpatialSpan(y: movingSpan.y + dy, fromX: movingSpan.fromX, toX: movingSpan.toX)
                        let inflated = Merman.inflateSpan(shifted, clearance: clearance)
                        for existingSpan in existing.spans {
                            if inflated.y != existingSpan.y { continue }
                            let fromX = max(inflated.fromX, existingSpan.fromX)
                            let toX = min(inflated.toX, existingSpan.toX)
                            guard fromX <= toX else { continue }
                            for x in fromX...toX {
                                let pt = DiagramPoint(x: x, y: inflated.y)
                                let movingOccupies = moving.spans.contains { span in
                                    span.y == pt.y && pt.x >= span.fromX && pt.x <= span.toX
                                }
                                if !(movingOccupies && Merman.pointIsContact(pt, existing: existing, contacts: contacts)) {
                                    result.append(SpatialConflict(moving: moving, existing: existing, point: pt))
                                }
                            }
                        }
                    }
                }
            }

            return result
        }

        // parity: merman/src/core/spatial.ts#SpatialIndex.isFree [status=implemented hash=c92c48c10abc]
        public func isFree(_ claim: SpatialClaim, policy: SpatialCollisionPolicy = SpatialCollisionPolicy()) throws -> Bool {
            try conflicts(claim, policy: policy).isEmpty
        }

        // parity: merman/src/core/spatial.ts#SpatialIndex.firstFit [status=implemented hash=f14da12d0d1b]
        public func firstFit<T>(
            _ candidates: [T],
            claim: (T) -> SpatialClaim,
            policy: SpatialCollisionPolicy = SpatialCollisionPolicy()
        ) throws -> T? {
            for candidate in candidates {
                if try isFree(claim(candidate), policy: policy) {
                    return candidate
                }
            }
            return nil
        }
    }
}
