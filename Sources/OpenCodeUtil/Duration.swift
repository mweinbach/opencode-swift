/// Compact elapsed time, e.g. `850ms`, `12.4s`, `3m 5s`, `2h 10m`, or `1d 4h`.
// parity: util/src/duration.ts#duration [status=implemented hash=491dfe2b70a8]
public func duration(_ input: Double) -> String {
    if input < 1000 {
        return "\(formatJSNumber(input))ms"
    }
    if input < 60_000 {
        return "\(formatToFixed1(input / 1000.0))s"
    }
    if input < 3_600_000 {
        let minutes = Int64((input / 60_000.0).rounded(.down))
        let remainder = input.truncatingRemainder(dividingBy: 60_000.0)
        let seconds = Int64((remainder / 1000.0).rounded(.down))
        return "\(minutes)m \(seconds)s"
    }
    if input < 86_400_000 {
        let hours = Int64((input / 3_600_000.0).rounded(.down))
        let remainder = input.truncatingRemainder(dividingBy: 3_600_000.0)
        let minutes = Int64((remainder / 60_000.0).rounded(.down))
        return "\(hours)h \(minutes)m"
    }
    let days = Int64((input / 86_400_000.0).rounded(.down))
    let remainder = input.truncatingRemainder(dividingBy: 86_400_000.0)
    let hours = Int64((remainder / 3_600_000.0).rounded(.down))
    return "\(days)d \(hours)h"
}

private func formatJSNumber(_ value: Double) -> String {
    if value == 0 {
        return "0"
    }
    if value.isFinite, value.rounded(.towardZero) == value, abs(value) < 9_007_199_254_740_992.0 {
        return String(Int64(value))
    }
    return String(value)
}

/// Formats a finite non-negative Double with 1 decimal digit matching JS `Number.prototype.toFixed(1)`.
private func formatToFixed1(_ value: Double) -> String {
    // JS toFixed rounds ties away from zero on exact decimal representation; adding epsilon avoids
    // binary representation artifacts like 1.25 -> 1.2 while staying pure stdlib.
    let scaled = (value * 10.0).rounded(.toNearestOrAwayFromZero)
    let tenths = Int64(scaled)
    let whole = tenths / 10
    let frac = abs(tenths % 10)
    return "\(whole).\(frac)"
}
