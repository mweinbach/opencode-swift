public struct ActivityDayInput: Equatable, Hashable, Sendable, Codable {
    public let date: String
    public let steps: Int

    public init(date: String, steps: Int) {
        self.date = date
        self.steps = steps
    }
}

public struct ActivityCalendarInput: Equatable, Sendable {
    public let activity: [ActivityDayInput]
    public let from: Int64
    public let to: Int64
    public let maxWeeks: Double

    public init(activity: [ActivityDayInput], from: Int64, to: Int64, maxWeeks: Double) {
        self.activity = activity
        self.from = from
        self.to = to
        self.maxWeeks = maxWeeks
    }

    public init(activity: [ActivityDayInput], from: Int64, to: Int64, maxWeeks: Int) {
        self.activity = activity
        self.from = from
        self.to = to
        self.maxWeeks = Double(maxWeeks)
    }
}

public struct ActivityCalendarCell: Equatable, Hashable, Sendable, Codable {
    public let date: String
    public let steps: Int
    public let level: Int

    public init(date: String, steps: Int, level: Int) {
        self.date = date
        self.steps = steps
        self.level = level
    }
}

public struct ActivityCalendarMonth: Equatable, Hashable, Sendable, Codable {
    public let week: Int
    public let label: String
    public let span: Int

    public init(week: Int, label: String, span: Int) {
        self.week = week
        self.label = label
        self.span = span
    }
}

public struct ActivityCalendarResult: Equatable, Sendable, Codable {
    public let weeks: [[ActivityCalendarCell]]
    public let months: [ActivityCalendarMonth]
    public let clipped: Bool

    public init(weeks: [[ActivityCalendarCell]], months: [ActivityCalendarMonth], clipped: Bool) {
        self.weeks = weeks
        self.months = months
        self.clipped = clipped
    }
}

private let activityShortMonths = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
]

private func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
    let q = a / b
    let r = a % b
    return (r != 0 && ((r < 0) != (b < 0))) ? q - 1 : q
}

/// Howard Hinnant's civil-from-days algorithm: converts days since 1970-01-01 to `(year, month 1..12, day 1..31)`.
private func civilFromDays(_ daysSinceEpoch: Int64) -> (year: Int64, month: Int, day: Int) {
    let z = daysSinceEpoch + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let doe = z - era * 146_097
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
    let y = yoe + era * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = mp + (mp < 10 ? 3 : -9)
    let year = y + (m <= 2 ? 1 : 0)
    return (year, Int(m), Int(d))
}

private func formatCalendarDate(_ daysSinceEpoch: Int64) -> String {
    let (year, month, day) = civilFromDays(daysSinceEpoch)
    let yStr: String
    if year < 0 {
        let absY = String(-year)
        yStr = "-" + String(repeating: "0", count: max(0, 6 - absY.count)) + absY
    } else if year > 9999 {
        let rawY = String(year)
        yStr = "+" + String(repeating: "0", count: max(0, 6 - rawY.count)) + rawY
    } else {
        let rawY = String(year)
        yStr = String(repeating: "0", count: max(0, 4 - rawY.count)) + rawY
    }
    let mStr = month < 10 ? "0\(month)" : "\(month)"
    let dStr = day < 10 ? "0\(day)" : "\(day)"
    return "\(yStr)-\(mStr)-\(dStr)"
}

/// Builds a GitHub-style Monday-aligned weekly activity calendar matching `util/src/activity-calendar.ts`.
///
/// Pass `timeZoneOffsetSeconds` to map epoch milliseconds into a caller's local civil calendar
/// (matching JavaScript's `new Date(ms).getFullYear()/getMonth()/getDate()`). Defaults to UTC (`0`).
// parity: util/src/activity-calendar.ts#activityCalendar [status=implemented hash=fa196c3016a8]
public func activityCalendar(
    _ input: ActivityCalendarInput,
    timeZoneOffsetSeconds: (Int64) -> Int = { _ in 0 }
) -> ActivityCalendarResult {
    func ordinal(_ timeMs: Int64) -> Int64 {
        let offsetMs = Int64(timeZoneOffsetSeconds(timeMs)) * 1_000
        return floorDiv(timeMs + offsetMs, 86_400_000)
    }

    let from = ordinal(input.from)
    let to = ordinal(input.to - 1)

    // 1970-01-01 (day 0) was Thursday (getUTCDay() == 4).
    let utcDay = Int(((from % 7) + 7 + 4) % 7)
    let monday = from - Int64((utcDay + 6) % 7)

    let total: Int
    if input.to <= input.from {
        total = 0
    } else {
        total = Int(floorDiv(to - monday, 7)) + 1
    }

    let maxWeeksFloor = Int(input.maxWeeks.rounded(.down))
    let count = min(total, min(53, max(1, maxWeeksFloor)))
    let start = monday + Int64(max(0, total - count)) * 7

    var values: [String: Int] = [:]
    values.reserveCapacity(input.activity.count)
    for entry in input.activity {
        values[entry.date] = entry.steps
    }

    let positiveUnique = Set(values.values.filter { $0 > 0 })
    let levels = positiveUnique.sorted()
    var levelIndexBySteps: [Int: Int] = [:]
    levelIndexBySteps.reserveCapacity(levels.count)
    for (idx, steps) in levels.enumerated() {
        levelIndexBySteps[steps] = idx
    }

    var weeks: [[ActivityCalendarCell]] = []
    weeks.reserveCapacity(count)
    for week in 0..<count {
        var row: [ActivityCalendarCell] = []
        row.reserveCapacity(7)
        for day in 0..<7 {
            let date = start + Int64(week * 7 + day)
            let key = formatCalendarDate(date)
            let steps = values[key] ?? 0
            let level: Int
            if date < from || date > to {
                level = -1
            } else if steps == 0 {
                level = 0
            } else {
                let rank = (levelIndexBySteps[steps] ?? 0) + 1
                let scaled = (Double(rank) / Double(levels.count)) * 4.0
                level = max(1, Int(scaled.rounded(.up)))
            }
            row.append(ActivityCalendarCell(date: key, steps: steps, level: level))
        }
        weeks.append(row)
    }

    var rawMonths: [(week: Int, label: String)] = []
    rawMonths.reserveCapacity(count)
    for week in 0..<count {
        let clampedDay = min(to, max(from, start + Int64(week * 7 + 3)))
        let (_, monthNumber, _) = civilFromDays(clampedDay)
        let label = activityShortMonths[monthNumber - 1]
        if rawMonths.last?.label != label {
            rawMonths.append((week: week, label: label))
        }
    }

    var months: [ActivityCalendarMonth] = []
    months.reserveCapacity(rawMonths.count)
    for index in 0..<rawMonths.count {
        let current = rawMonths[index]
        let nextWeek = index + 1 < rawMonths.count ? rawMonths[index + 1].week : count
        months.append(ActivityCalendarMonth(week: current.week, label: current.label, span: nextWeek - current.week))
    }

    return ActivityCalendarResult(weeks: weeks, months: months, clipped: count < total)
}
