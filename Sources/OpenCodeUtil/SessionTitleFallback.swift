public enum SessionTitleFallback {
    public struct Time: Equatable, Sendable, Codable {
        public let created: Int64

        public init(created: Int64) {
            self.created = created
        }
    }

    public struct Info: Equatable, Sendable, Codable {
        public let title: String?
        public let parentID: String?
        public let time: Time

        public init(title: String? = nil, parentID: String? = nil, time: Time) {
            self.title = title
            self.parentID = parentID
            self.time = time
        }
    }

    /// Supplies the timestamped title required by compatibility surfaces.
    // parity: util/src/session-title-fallback.ts#withTimestampedFallback [status=implemented hash=c0f847b73473]
    public static func withTimestampedFallback(_ info: Info) -> String {
        info.title ?? fallback(parentID: info.parentID, created: info.time.created)
    }

    /// Supplies a compact human label and collapses historical timestamped fallbacks.
    // parity: util/src/session-title-fallback.ts#displayLabel [status=implemented hash=fc6fde868bc8]
    public static func displayLabel(title: String?, parentID: String?) -> String {
        guard let title, !title.isEmpty else {
            return (parentID != nil && !parentID!.isEmpty) ? "Child session" : "New session"
        }
        if let prefix = matchFallbackPrefix(title) {
            return prefix
        }
        return title
    }

    /// Recognizes missing and historical root or child fallback titles.
    // parity: util/src/session-title-fallback.ts#isFallbackTitle [status=implemented hash=a6d0d7318bb4]
    public static func isFallbackTitle(_ title: String?) -> Bool {
        guard let title else { return true }
        return matchFallbackPrefix(title) != nil
    }

    /// Recognizes a missing title or the exact root fallback for this session.
    // parity: util/src/session-title-fallback.ts#isExactRootFallback [status=implemented hash=ac4913b4097c]
    public static func isExactRootFallback(title: String?, created: Int64) -> Bool {
        guard let title else { return true }
        return title == fallback(parentID: nil, created: created)
    }

    private static func fallback(parentID: String?, created: Int64) -> String {
        let prefix = (parentID != nil && !parentID!.isEmpty) ? "Child" : "New"
        return "\(prefix) session - \(formatISO8601UTC(epochMillis: created))"
    }

    /// Matches `^(New session|Child session) - \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$`.
    private static func matchFallbackPrefix(_ title: String) -> String? {
        let prefix: String
        let rest: Substring
        if title.hasPrefix("New session - ") {
            prefix = "New session"
            rest = title.dropFirst("New session - ".count)
        } else if title.hasPrefix("Child session - ") {
            prefix = "Child session"
            rest = title.dropFirst("Child session - ".count)
        } else {
            return nil
        }

        let bytes = Array(rest.utf8)
        guard bytes.count == 24 else { return nil }
        let pattern = "DDDD-DD-DDTDD:DD:DD.DDDZ"
        for (byte, expected) in zip(bytes, pattern.utf8) {
            if expected == UInt8(ascii: "D") {
                if byte < 0x30 || byte > 0x39 { return nil }
            } else if byte != expected {
                return nil
            }
        }
        return prefix
    }
}

/// Pure-Swift UTC ISO-8601 millisecond formatter matching `new Date(ms).toISOString()` for years 0000..9999.
internal func formatISO8601UTC(epochMillis: Int64) -> String {
    let millisPerDay: Int64 = 86_400_000
    var days = epochMillis / millisPerDay
    var rem = epochMillis % millisPerDay
    if rem < 0 {
        rem += millisPerDay
        days -= 1
    }

    let millis = Int(rem % 1000)
    let totalSeconds = Int(rem / 1000)
    let second = totalSeconds % 60
    let minute = (totalSeconds / 60) % 60
    let hour = totalSeconds / 3600

    // Howard Hinnant's civil-from-days algorithm (proleptic Gregorian calendar, 1970-01-01 = day 0)
    let z = days + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let doe = z - era * 146_097
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
    let y = yoe + era * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let day = Int(doy - (153 * mp + 2) / 5 + 1)
    let month = Int(mp < 10 ? mp + 3 : mp - 9)
    let year = Int(y + (month <= 2 ? 1 : 0))

    return "\(pad(year, width: 4))-\(pad(month, width: 2))-\(pad(day, width: 2))T"
        + "\(pad(hour, width: 2)):\(pad(minute, width: 2)):\(pad(second, width: 2)).\(pad(millis, width: 3))Z"
}

private func pad(_ value: Int, width: Int) -> String {
    let str = String(value)
    if str.count >= width { return str }
    return String(repeating: "0", count: width - str.count) + str
}
