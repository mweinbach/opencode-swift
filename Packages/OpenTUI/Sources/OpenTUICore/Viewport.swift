public struct ViewportBounds: Equatable, Hashable, Sendable, Codable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public protocol ViewportObject: Sendable {
    var screenX: Int { get }
    var screenY: Int { get }
    var width: Int { get }
    var height: Int { get }
    var zIndex: Int { get }
}

public struct ViewportItem: ViewportObject, Equatable, Hashable, Sendable, Codable {
    public let id: String
    public let screenX: Int
    public let screenY: Int
    public let width: Int
    public let height: Int
    public let zIndex: Int

    public init(id: String, screenX: Int, screenY: Int, width: Int, height: Int, zIndex: Int) {
        self.id = id
        self.screenX = screenX
        self.screenY = screenY
        self.width = width
        self.height = height
        self.zIndex = zIndex
    }
}

public enum ViewportDirection: String, Equatable, Hashable, Sendable, Codable {
    case row
    case column
}

/// Binary-search viewport culling with 50-item gap lookbehind and stable zIndex sort,
/// matching `packages/core/src/lib/objects-in-viewport.ts`.
// parity: core/src/lib/objects-in-viewport.ts#getObjectsInViewport [status=implemented hash=cbaec86466b8]
public func getObjectsInViewport<T: ViewportObject>(
    viewport: ViewportBounds,
    objects: [T],
    direction: ViewportDirection = .column,
    padding: Int = 10,
    minTriggerSize: Int = 16
) -> [T] {
    if viewport.width <= 0 || viewport.height <= 0 {
        return []
    }
    if objects.isEmpty {
        return []
    }
    if objects.count < minTriggerSize {
        return objects
    }

    let viewportTop = viewport.y - padding
    let viewportBottom = viewport.y + viewport.height + padding
    let viewportLeft = viewport.x - padding
    let viewportRight = viewport.x + viewport.width + padding

    let isRow = direction == .row
    let total = objects.count
    let vpStart = isRow ? viewportLeft : viewportTop
    let vpEnd = isRow ? viewportRight : viewportBottom

    var lo = 0
    var hi = total - 1
    var candidate = -1

    while lo <= hi {
        let mid = (lo + hi) >> 1
        let c = objects[mid]
        let start = isRow ? c.screenX : c.screenY
        let end = isRow ? c.screenX + c.width : c.screenY + c.height

        if end < vpStart {
            lo = mid + 1
        } else if start > vpEnd {
            hi = mid - 1
        } else {
            candidate = mid
            break
        }
    }

    if candidate == -1 {
        candidate = lo > 0 ? lo - 1 : 0
    }

    let maxLookBehind = 50
    var left = candidate
    var gapCount = 0

    while left - 1 >= 0 {
        let prev = objects[left - 1]
        let prevEnd = isRow ? prev.screenX + prev.width : prev.screenY + prev.height
        if prevEnd <= vpStart {
            gapCount += 1
            if gapCount >= maxLookBehind {
                break
            }
        } else {
            gapCount = 0
        }
        left -= 1
    }

    var right = candidate + 1
    while right < total {
        let next = objects[right]
        if (isRow ? next.screenX : next.screenY) >= vpEnd {
            break
        }
        right += 1
    }

    var visible: [(index: Int, item: T)] = []
    for i in left..<right {
        let child = objects[i]
        let start = isRow ? child.screenX : child.screenY
        let end = isRow ? child.screenX + child.width : child.screenY + child.height

        if end <= vpStart { continue }
        if start >= vpEnd { break }

        if isRow {
            if child.screenY + child.height < viewportTop { continue }
            if child.screenY > viewportBottom { continue }
        } else {
            if child.screenX + child.width < viewportLeft { continue }
            if child.screenX > viewportRight { continue }
        }

        visible.append((i, child))
    }

    if visible.count > 1 {
        visible.sort { lhs, rhs in
            if lhs.item.zIndex != rhs.item.zIndex {
                return lhs.item.zIndex < rhs.item.zIndex
            }
            return lhs.index < rhs.index
        }
    }

    return visible.map(\.item)
}
