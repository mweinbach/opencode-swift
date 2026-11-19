#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
import WinSDK
#elseif canImport(WASILibc)
import WASILibc
#endif

/// Pure-Swift RFC 3339 / ISO-8601 UTC timestamp parser, formatter, and wall-clock utility.
/// Keeps public `OpenTunnelClient` models independent of `Foundation.Date` so Swift Testing
/// suites never need to import `Foundation`.
public enum OpenTunnelTimestamp {
    /// Current Unix wall-clock timestamp in whole milliseconds.
    public static func nowEpochMilliseconds() -> Int64 {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl) || canImport(WASILibc)
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return Int64(ts.tv_sec) * 1_000 + Int64(ts.tv_nsec) / 1_000_000
        #elseif canImport(WinSDK)
        var ft = FILETIME()
        GetSystemTimeAsFileTime(&ft)
        let ticks = (UInt64(ft.dwHighDateTime) << 32) | UInt64(ft.dwLowDateTime)
        let windowsToUnixEpoch100ns: UInt64 = 116_444_736_000_000_000
        guard ticks >= windowsToUnixEpoch100ns else { return 0 }
        return Int64((ticks - windowsToUnixEpoch100ns) / 10_000)
        #else
        return 0
        #endif
    }

    /// Current Unix wall-clock timestamp in seconds.
    public static func nowEpochSeconds() -> Double {
        Double(nowEpochMilliseconds()) / 1_000.0
    }

    /// Parses an RFC 3339 / ISO-8601 timestamp (e.g. `2027-01-15T12:34:56.789Z` or `+02:00`)
    /// into Unix epoch seconds. Returns `nil` for malformed input.
    public static func parseISO8601(_ value: String) -> Double? {
        let bytes = Array(value.trimmingASCIIWhitespace().utf8)
        // Minimum length: YYYY-MM-DDTHH:MM:SSZ = 20 bytes
        guard bytes.count >= 20 else { return nil }
        guard bytes[4] == 0x2D, bytes[7] == 0x2D,
              (bytes[10] == 0x54 || bytes[10] == 0x74 || bytes[10] == 0x20),
              bytes[13] == 0x3A, bytes[16] == 0x3A
        else { return nil }

        guard let year = parseDigits(bytes, 0, 4),
              let month = parseDigits(bytes, 5, 2),
              let day = parseDigits(bytes, 8, 2),
              let hour = parseDigits(bytes, 11, 2),
              let minute = parseDigits(bytes, 14, 2),
              let second = parseDigits(bytes, 17, 2)
        else { return nil }

        guard (1...12).contains(month),
              (1...31).contains(day),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...60).contains(second)
        else { return nil }

        var idx = 19
        var fractional: Double = 0
        if idx < bytes.count && bytes[idx] == 0x2E { // '.'
            idx += 1
            let fracStart = idx
            var scale = 0.1
            while idx < bytes.count, bytes[idx] >= 0x30, bytes[idx] <= 0x39 {
                fractional += Double(bytes[idx] - 0x30) * scale
                scale *= 0.1
                idx += 1
            }
            guard idx > fracStart else { return nil }
        }

        guard idx < bytes.count else { return nil }
        var offsetSeconds = 0
        if bytes[idx] == 0x5A || bytes[idx] == 0x7A { // 'Z' or 'z'
            idx += 1
            guard idx == bytes.count else { return nil }
        } else if bytes[idx] == 0x2B || bytes[idx] == 0x2D { // '+' or '-'
            let sign = bytes[idx] == 0x2B ? 1 : -1
            idx += 1
            guard idx + 5 == bytes.count,
                  bytes[idx + 2] == 0x3A,
                  let tzHour = parseDigits(bytes, idx, 2),
                  let tzMin = parseDigits(bytes, idx + 3, 2),
                  tzHour <= 23, tzMin <= 59
            else { return nil }
            offsetSeconds = sign * (tzHour * 3600 + tzMin * 60)
        } else {
            return nil
        }

        let days = daysFromCivil(year: year, month: month, day: day)
        let wholeSeconds = days * 86_400 + Int64(hour * 3600 + minute * 60 + second) - Int64(offsetSeconds)
        return Double(wholeSeconds) + fractional
    }

    /// Formats Unix epoch seconds into canonical RFC 3339 UTC string (`YYYY-MM-DDTHH:MM:SS.sssZ`).
    public static func formatISO8601(epochSeconds: Double) -> String {
        let totalMillis = Int64((epochSeconds * 1_000.0).rounded())
        var wholeSeconds = totalMillis / 1_000
        var millis = Int(totalMillis % 1_000)
        if millis < 0 {
            millis += 1_000
            wholeSeconds -= 1
        }
        var days = wholeSeconds / 86_400
        var secondsOfDay = Int(wholeSeconds % 86_400)
        if secondsOfDay < 0 {
            secondsOfDay += 86_400
            days -= 1
        }
        let (year, month, day) = civilFromDays(days)
        let hour = secondsOfDay / 3600
        let minute = (secondsOfDay % 3600) / 60
        let second = secondsOfDay % 60
        return "\(pad(year, width: 4))-\(pad(month, width: 2))-\(pad(day, width: 2))T\(pad(hour, width: 2)):\(pad(minute, width: 2)):\(pad(second, width: 2)).\(pad(millis, width: 3))Z"
    }

    // Howard Hinnant's civil-calendar algorithm (exact across Gregorian leap years).
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int64 {
        let y = Int64(year - (month <= 2 ? 1 : 0))
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let m = Int64(month)
        let d = Int64(day)
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func civilFromDays(_ zInput: Int64) -> (year: Int, month: Int, day: Int) {
        let z = zInput + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp + (mp < 10 ? 3 : -9)
        let year = y + (m <= 2 ? 1 : 0)
        return (Int(year), Int(m), Int(d))
    }

    private static func parseDigits(_ bytes: [UInt8], _ start: Int, _ count: Int) -> Int? {
        var result = 0
        for i in start..<(start + count) {
            let b = bytes[i]
            guard b >= 0x30 && b <= 0x39 else { return nil }
            result = result * 10 + Int(b - 0x30)
        }
        return result
    }

    private static func pad(_ value: Int, width: Int) -> String {
        let raw = String(value)
        if raw.count >= width { return raw }
        return String(repeating: "0", count: width - raw.count) + raw
    }
}

internal extension String {
    func trimmingASCIIWhitespace() -> String {
        var start = startIndex
        var end = endIndex
        while start < end, self[start].isASCIIWhitespace {
            start = index(after: start)
        }
        while end > start {
            let prev = index(before: end)
            if self[prev].isASCIIWhitespace {
                end = prev
            } else {
                break
            }
        }
        return String(self[start..<end])
    }
}

private extension Character {
    var isASCIIWhitespace: Bool {
        self == " " || self == "\t" || self == "\n" || self == "\r"
    }
}
