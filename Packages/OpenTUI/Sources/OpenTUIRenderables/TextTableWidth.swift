/// Column width fitting strategy for text tables.
public enum TextTableColumnFitter: String, Equatable, Hashable, Sendable, Codable {
    case proportional
    case balanced
}

/// Computes exact 192-bit unsigned product `growth * growth * capacity` without overflow.
private func squaredCrossProduct(_ growth: Int, _ capacity: Int) -> (high: UInt64, mid: UInt64, low: UInt64) {
    let g = UInt64(max(0, growth))
    let c = UInt64(max(0, capacity))
    let sq = g.multipliedFullWidth(by: g)
    let p0 = sq.low.multipliedFullWidth(by: c)
    let p1 = sq.high.multipliedFullWidth(by: c)
    let (mid, carry) = p1.low.addingReportingOverflow(p0.high)
    let high = p1.high &+ (carry ? 1 : 0)
    return (high, mid, p0.low)
}

/// Compares `leftGrowth / sqrt(leftCapacity)` against `rightGrowth / sqrt(rightCapacity)`
/// using exact integer squared cross-products `leftGrowth^2 * rightCapacity` vs `rightGrowth^2 * leftCapacity`.
private func comparePriority(
    leftGrowth: Int,
    leftCapacity: Int,
    rightGrowth: Int,
    rightCapacity: Int
) -> Int {
    let lhs = squaredCrossProduct(leftGrowth, rightCapacity)
    let rhs = squaredCrossProduct(rightGrowth, leftCapacity)
    if lhs < rhs { return -1 }
    if lhs > rhs { return 1 }
    return 0
}

/// Exact square-root proportional column width allocator ported from `text-table-width.ts`.
///
/// Water-fills arithmetic priority sequences `g / sqrt(capacity)` in bulk, capping short columns first,
/// and resolves the remaining fractional cells by exact integer cross-product priority with
/// lower-column-index tie-breaking.
// parity: core/src/renderables/text-table-width.ts#allocateProportionalColumnWidths [status=implemented hash=a6a68f8c4997]
public func allocateProportionalColumnWidths(
    _ widths: [Int],
    targetWidth: Int,
    minWidth: Int
) -> [Int] {
    if widths.isEmpty { return [] }

    let baseWidths = widths.map { max(minWidth, $0) }
    let totalBaseWidth = baseWidths.reduce(0, +)
    let capacity = baseWidths.map { $0 - minWidth }
    var growth = Array(repeating: 0, count: baseWidths.count)
    let minTotal = minWidth * baseWidths.count
    let available = min(max(0, targetWidth - minTotal), totalBaseWidth - minTotal)

    if available == 0 {
        return Array(repeating: minWidth, count: baseWidths.count)
    }
    let totalCapacity = capacity.reduce(0, +)
    if available == totalCapacity {
        return baseWidths
    }

    struct ActiveColumn {
        let idx: Int
        let width: Int
        let weight: Double
    }

    let weights = capacity.map { Double($0).squareRoot() }
    let active = capacity.enumerated()
        .compactMap { idx, width -> ActiveColumn? in
            width > 0 ? ActiveColumn(idx: idx, width: width, weight: weights[idx]) : nil
        }
        .sorted { lhs, rhs in
            if lhs.weight != rhs.weight { return lhs.weight < rhs.weight }
            return lhs.idx < rhs.idx
        }

    if active.count == capacity.count, let firstCapacity = capacity.first,
       capacity.allSatisfy({ $0 == firstCapacity })
    {
        let sharedGrowth = available / capacity.count
        let remainder = available % capacity.count
        return (0..<growth.count).map { idx in
            minWidth + sharedGrowth + (idx < remainder ? 1 : 0)
        }
    }

    var remaining = available
    var totalWeight = active.reduce(0.0) { $0 + $1.weight }

    // Water-fill the arithmetic priority sequences in bulk, capping short columns first.
    for column in active {
        if Double(remaining) / totalWeight <= column.weight { break }
        growth[column.idx] = column.width
        remaining -= column.width
        totalWeight -= column.weight
    }

    let level = Double(remaining) / totalWeight
    for column in active {
        if growth[column.idx] == column.width { continue }
        let floored = Int((level * column.weight).rounded(.down))
        growth[column.idx] = min(column.width, max(0, floored))
    }

    var allocatedGrowth = growth.reduce(0, +)

    while allocatedGrowth > available {
        var worstIdx = -1

        for idx in 0..<baseWidths.count {
            if growth[idx] == 0 { continue }
            let comparison = worstIdx == -1
                ? 1
                : comparePriority(
                    leftGrowth: growth[idx],
                    leftCapacity: capacity[idx],
                    rightGrowth: growth[worstIdx],
                    rightCapacity: capacity[worstIdx]
                )
            if comparison > 0 || (comparison == 0 && idx > worstIdx) {
                worstIdx = idx
            }
        }

        if worstIdx == -1 { break }
        growth[worstIdx] -= 1
        allocatedGrowth -= 1
    }

    // Flooring leaves fewer than one cell per active column to resolve by exact priority.
    while allocatedGrowth < available {
        var bestIdx = -1

        for idx in 0..<baseWidths.count {
            if growth[idx] >= capacity[idx] { continue }
            let comparison = bestIdx == -1
                ? -1
                : comparePriority(
                    leftGrowth: growth[idx] + 1,
                    leftCapacity: capacity[idx],
                    rightGrowth: growth[bestIdx] + 1,
                    rightCapacity: capacity[bestIdx]
                )
            if comparison < 0 {
                bestIdx = idx
            }
        }

        if bestIdx == -1 { break }
        growth[bestIdx] += 1
        allocatedGrowth += 1
    }

    return growth.map { $0 + minWidth }
}

/// Floating-point overload matching JavaScript `Math.floor(width)` normalization.
public func allocateProportionalColumnWidths(
    _ widths: [Double],
    targetWidth: Int,
    minWidth: Int
) -> [Int] {
    allocateProportionalColumnWidths(
        widths.map { Int($0.rounded(.down)) },
        targetWidth: targetWidth,
        minWidth: minWidth
    )
}

/// Fits table column widths into `targetWidth` using either `.proportional` (square-root priority)
/// or `.balanced` column width fitting from OpenTUI's `TextTableRenderable`.
public func fitTextTableColumnWidths(
    _ widths: [Int],
    targetWidth: Int,
    minWidth: Int = 1,
    fitter: TextTableColumnFitter = .proportional
) -> [Int] {
    switch fitter {
    case .proportional:
        return allocateProportionalColumnWidths(widths, targetWidth: targetWidth, minWidth: minWidth)
    case .balanced:
        return fitBalancedColumnWidths(widths, targetWidth: targetWidth, minWidth: minWidth)
    }
}

private func fitBalancedColumnWidths(_ widths: [Int], targetWidth: Int, minWidth: Int) -> [Int] {
    let baseWidths = widths.map { max(1, $0) }
    let columns = baseWidths.count
    let totalBaseWidth = baseWidths.reduce(0, +)

    if columns == 0 || totalBaseWidth <= targetWidth {
        return baseWidths
    }

    let hardMinWidths = Array(repeating: minWidth, count: columns)
    let evenShare = max(minWidth, targetWidth / columns)
    let preferredMinWidths = baseWidths.map { min($0, evenShare) }
    let preferredMinTotal = preferredMinWidths.reduce(0, +)
    let floorWidths = preferredMinTotal <= targetWidth ? preferredMinWidths : hardMinWidths
    let floorTotal = floorWidths.reduce(0, +)
    let clampedTarget = max(floorTotal, targetWidth)

    if totalBaseWidth <= clampedTarget {
        return baseWidths
    }

    let shrinkable = zip(baseWidths, floorWidths).map { $0 - $1 }
    let totalShrinkable = shrinkable.reduce(0, +)
    if totalShrinkable <= 0 {
        return floorWidths
    }

    let targetShrink = totalBaseWidth - clampedTarget
    var shrink = Array(repeating: 0, count: columns)
    let weights = shrinkable.map { $0 > 0 ? Double($0).squareRoot() : 0.0 }
    let totalWeight = weights.reduce(0.0, +)

    if totalWeight > 0 {
        var fractions = Array(repeating: 0.0, count: columns)
        var usedShrink = 0

        for idx in 0..<columns {
            if shrinkable[idx] <= 0 || weights[idx] <= 0 { continue }
            let exact = (weights[idx] / totalWeight) * Double(targetShrink)
            let whole = min(shrinkable[idx], Int(exact.rounded(.down)))
            shrink[idx] = whole
            fractions[idx] = exact - Double(whole)
            usedShrink += whole
        }

        var remainingShrink = targetShrink - usedShrink
        while remainingShrink > 0 {
            var bestIdx = -1
            var bestFraction = -1.0

            for idx in 0..<columns {
                if shrinkable[idx] - shrink[idx] <= 0 { continue }
                if bestIdx == -1
                    || fractions[idx] > bestFraction
                    || (fractions[idx] == bestFraction && shrinkable[idx] > shrinkable[bestIdx])
                {
                    bestIdx = idx
                    bestFraction = fractions[idx]
                }
            }

            if bestIdx == -1 { break }
            shrink[bestIdx] += 1
            fractions[bestIdx] = -1.0
            remainingShrink -= 1
        }
    }

    return (0..<columns).map { idx in
        max(floorWidths[idx], baseWidths[idx] - shrink[idx])
    }
}
