#if os(macOS) || os(Linux) || os(Windows)
import Foundation
#elseif canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import OpenCodeSchema

// MARK: - Effect 4.1.0 Cron & Zoned DateTime Engine (`effect/Cron`, `effect/DateTime`)

extension CoreAutomation {
    /// Time zone representation matching Effect 4.1.0 `DateTime.TimeZone` (`Named` or fixed `Offset`).
    /// Uses pure-Swift civil calendar math for date stepping and queries `Foundation.TimeZone` only
    /// for IANA tzdb UTC offset lookups.
    public enum CronTimeZone: Equatable, Hashable, Sendable {
        case named(id: String, timeZone: TimeZone)
        case offset(millis: Int64)

        public static let utc: CronTimeZone = .named(
            id: "UTC",
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        /// The host system's current time zone (`DateTime.zoneMakeLocal()`).
        public static func local() -> CronTimeZone {
            let current = TimeZone.current
            let id = canonicalIdentifier(for: current.identifier)
            return .named(id: id, timeZone: current)
        }

        /// Resolves a named IANA time zone or `±HH:MM` fixed offset accepted by `Intl.DateTimeFormat`
        /// (`DateTime.zoneMakeNamed`). Returns `nil` for unknown zones or `GMT±...` offset strings.
        public static func makeNamed(_ raw: String) -> CronTimeZone? {
            guard !raw.isEmpty else { return nil }
            let upper = raw.uppercased()
            if upper == "UTC" {
                return .named(id: "UTC", timeZone: TimeZone(secondsFromGMT: 0)!)
            }
            if upper == "GMT" {
                return .named(id: "GMT", timeZone: TimeZone(secondsFromGMT: 0)!)
            }
            // Intl.DateTimeFormat rejects `GMT+HH:MM` / `GMT-HH:MM` / `UTC+...` in timeZone option.
            if upper.hasPrefix("GMT+") || upper.hasPrefix("GMT-") || upper.hasPrefix("UTC+") || upper.hasPrefix("UTC-") {
                return nil
            }
            // Intl.DateTimeFormat accepts bare fixed offsets like `+05:30` or `-04:00` (and `+0530` -> `+05:30`).
            if raw.hasPrefix("+") || raw.hasPrefix("-") {
                guard let offsetMs = parseStrictOffsetMillis(raw, allowGMTPrefix: false) else { return nil }
                let formatted = formatOffsetMillis(offsetMs)
                guard let tz = TimeZone(secondsFromGMT: Int(offsetMs / 1_000)) else { return nil }
                return .named(id: formatted, timeZone: tz)
            }
            if let tz = TimeZone(identifier: raw) {
                return .named(id: canonicalIdentifier(for: raw, resolved: tz.identifier), timeZone: tz)
            }
            // Case-insensitive lookup across known IANA identifiers (matching ICU / Intl.DateTimeFormat).
            if let matched = knownIdentifiersByLowercase[raw.lowercased()],
               let tz = TimeZone(identifier: matched)
            {
                return .named(id: matched, timeZone: tz)
            }
            return nil
        }

        /// Parses either a fixed offset (`±HH:MM`, `±HHMM`, `GMT±HH:MM`) or a named IANA time zone
        /// (`DateTime.zoneFromString`).
        public static func fromString(_ raw: String) -> CronTimeZone? {
            guard !raw.isEmpty else { return nil }
            if isOffsetZoneString(raw) {
                guard let offsetMs = parseStrictOffsetMillis(raw, allowGMTPrefix: true) else { return nil }
                return .offset(millis: offsetMs)
            }
            return makeNamed(raw)
        }

        /// String representation matching `DateTime.zoneToString`.
        public var stringValue: String {
            switch self {
            case .named(let id, _):
                return id
            case .offset(let millis):
                return Self.formatOffsetMillis(millis)
            }
        }

        /// Whether this zone is specifically named `"UTC"`.
        internal var isNamedUTC: Bool {
            if case .named(let id, _) = self { return id == "UTC" }
            return false
        }

        /// UTC offset in milliseconds at the given UTC epoch millisecond.
        internal func offsetMillis(at utcMillis: Int64) -> Int64 {
            switch self {
            case .offset(let ms):
                return ms
            case .named(_, let tz):
                let wholeSeconds = CronCalendar.floorDiv(utcMillis, 1_000)
                return Int64(tz.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(wholeSeconds)))) * 1_000
            }
        }

        private static let knownIdentifiersByLowercase: [String: String] = {
            var map: [String: String] = [:]
            for id in TimeZone.knownTimeZoneIdentifiers {
                map[id.lowercased()] = id
            }
            return map
        }()

        private static func canonicalIdentifier(for requested: String, resolved: String? = nil) -> String {
            if requested.uppercased() == "UTC" { return "UTC" }
            if requested.uppercased() == "GMT" { return "GMT" }
            if let matched = knownIdentifiersByLowercase[requested.lowercased()] {
                return matched
            }
            return resolved ?? requested
        }

        private static func isOffsetZoneString(_ raw: String) -> Bool {
            if raw.hasPrefix("+") || raw.hasPrefix("-") { return true }
            if raw.hasPrefix("GMT+") || raw.hasPrefix("GMT-") { return true }
            return false
        }

        /// Parses `[GMT][+-]HH:?MM` into milliseconds, enforcing `00 <= HH <= 23` and `00 <= MM <= 59`.
        internal static func parseStrictOffsetMillis(_ raw: String, allowGMTPrefix: Bool) -> Int64? {
            var slice = Substring(raw)
            if allowGMTPrefix && slice.hasPrefix("GMT") {
                slice = slice.dropFirst(3)
            }
            guard let signChar = slice.first, signChar == "+" || signChar == "-" else { return nil }
            let sign: Int64 = (signChar == "+") ? 1 : -1
            let rest = slice.dropFirst()
            let bytes = Array(rest.utf8)
            let hours: Int
            let minutes: Int
            if bytes.count == 5 && bytes[2] == 0x3A /* ':' */ {
                guard let h = twoDigits(bytes[0], bytes[1]),
                      let m = twoDigits(bytes[3], bytes[4])
                else { return nil }
                hours = h
                minutes = m
            } else if bytes.count == 4 {
                guard let h = twoDigits(bytes[0], bytes[1]),
                      let m = twoDigits(bytes[2], bytes[3])
                else { return nil }
                hours = h
                minutes = m
            } else {
                return nil
            }
            guard hours >= 0 && hours <= 23 && minutes >= 0 && minutes <= 59 else { return nil }
            return sign * Int64(hours * 60 + minutes) * 60_000
        }

        private static func twoDigits(_ hi: UInt8, _ lo: UInt8) -> Int? {
            guard hi >= 0x30 && hi <= 0x39 && lo >= 0x30 && lo <= 0x39 else { return nil }
            return Int(hi - 0x30) * 10 + Int(lo - 0x30)
        }

        internal static func formatOffsetMillis(_ offset: Int64) -> String {
            let absMs = offset < 0 ? -offset : offset
            var hours = absMs / 3_600_000
            var minutes = ((absMs % 3_600_000) + 30_000) / 60_000
            if minutes == 60 {
                hours += 1
                minutes = 0
            }
            let sign = offset < 0 ? "-" : "+"
            let hh = hours < 10 ? "0\(hours)" : "\(hours)"
            let mm = minutes < 10 ? "0\(minutes)" : "\(minutes)"
            return "\(sign)\(hh):\(mm)"
        }
    }

    /// Disambiguation strategy for wall-clock times falling in DST gaps or folds (matching Effect `DateTime.Disambiguation`).
    public enum DSTDisambiguation: String, Equatable, Hashable, Sendable {
        case compatible
        case earlier
        case later
        case reject
    }

    /// Policy for repeated wall-clock times during a fall-back DST overlap (`Cron.onDstOverlap`).
    public enum DSTOverlapPolicy: String, Equatable, Hashable, Sendable {
        case earlier
        case later
        case both
    }

    /// Error returned by `Cron.parse` matching Effect 4.1.0 `Cron.CronParseError` messages verbatim.
    public struct CronParseError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "CronParseError"
        public let message: String
        public let input: String?

        public init(message: String, input: String? = nil) {
            self.message = message
            self.input = input
        }

        public var description: String { message }
    }

    /// Pure-Swift proleptic Gregorian calendar and Effect `DateTime` zoned wall-clock conversion.
    internal enum CronCalendar {
        static let dayMs: Int64 = 86_400_000
        static let minEpochMs: Int64 = -8_640_000_000_000_000 + 12 * 3_600_000
        static let maxEpochMs: Int64 = 8_640_000_000_000_000 - 14 * 3_600_000

        @inline(__always)
        static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
            let q = a / b
            let r = a % b
            return (r != 0 && ((r < 0) != (b < 0))) ? (q - 1) : q
        }

        @inline(__always)
        static func floorMod(_ a: Int64, _ b: Int64) -> Int64 {
            let r = a % b
            return (r != 0 && ((r < 0) != (b < 0))) ? (r + b) : r
        }

        /// Howard Hinnant's civil-to-days algorithm (days since 1970-01-01).
        /// Expects `month` in `1...12`, `day` in `1...31`.
        static func daysFromCivil(year: Int64, month: Int, day: Int) -> Int64 {
            let y = year - (month <= 2 ? 1 : 0)
            let era = (y >= 0 ? y : y - 399) / 400
            let yoe = y - era * 400
            let m = Int64(month)
            let d = Int64(day)
            let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
            let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
            return era * 146_097 + doe - 719_468
        }

        /// Howard Hinnant's days-to-civil algorithm (days since 1970-01-01 -> `(year, month 1..12, day 1..31)`).
        static func civilFromDays(_ days: Int64) -> (year: Int64, month: Int, day: Int) {
            let z = days + 719_468
            let era = (z >= 0 ? z : z - 146_096) / 146_097
            let doe = z - era * 146_097
            let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
            let y = yoe + era * 400
            let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
            let mp = (5 * doy + 2) / 153
            let d = doy - (153 * mp + 2) / 5 + 1
            let m = mp + (mp < 10 ? 3 : -9)
            return (year: y + (m <= 2 ? 1 : 0), month: Int(m), day: Int(d))
        }

        static func daysInMonth(year: Int64, month: Int) -> Int {
            let nextYear = month == 12 ? year + 1 : year
            let nextMonth = month == 12 ? 1 : month + 1
            return Int(daysFromCivil(year: nextYear, month: nextMonth, day: 1) - daysFromCivil(year: year, month: month, day: 1))
        }

        /// Equivalent to JavaScript `Date.UTC(year, month0, day, hour, minute, second, millisecond)` with overflow.
        static func makeUTCMillis(
            year: Int64,
            month0: Int64,
            day: Int64,
            hour: Int64 = 0,
            minute: Int64 = 0,
            second: Int64 = 0,
            millisecond: Int64 = 0
        ) -> Int64 {
            let normYear = year + floorDiv(month0, 12)
            let normMonth = Int(floorMod(month0, 12)) + 1
            let days = daysFromCivil(year: normYear, month: normMonth, day: 1) + (day - 1)
            return days * dayMs + hour * 3_600_000 + minute * 60_000 + second * 1_000 + millisecond
        }

        struct Parts: Equatable, Sendable {
            let year: Int64
            let month: Int      // 1...12
            let day: Int        // 1...31
            let weekDay: Int    // 0 (Sunday)...6 (Saturday)
            let hour: Int       // 0...23
            let minute: Int     // 0...59
            let second: Int     // 0...59
            let millisecond: Int // 0...999
        }

        static func partsUTC(epochMs: Int64) -> Parts {
            let days = floorDiv(epochMs, dayMs)
            let rem = floorMod(epochMs, dayMs)
            let (year, month, day) = civilFromDays(days)
            let weekDay = Int(floorMod(days + 4, 7))
            let hour = Int(rem / 3_600_000)
            let minute = Int((rem % 3_600_000) / 60_000)
            let second = Int((rem % 60_000) / 1_000)
            let millisecond = Int(rem % 1_000)
            return Parts(
                year: year,
                month: month,
                day: day,
                weekDay: weekDay,
                hour: hour,
                minute: minute,
                second: second,
                millisecond: millisecond
            )
        }

        /// Mutable UTC timestamp mirroring JavaScript `Date`'s `getUTC*` / `setUTC*` mutators exactly.
        struct MutableUTCDate: Equatable, Sendable {
            var epochMs: Int64

            init(epochMs: Int64) {
                self.epochMs = epochMs
            }

            var parts: Parts { partsUTC(epochMs: epochMs) }
            var utcFullYear: Int64 { parts.year }
            var utcMonth0: Int { parts.month - 1 }
            var utcMonth1: Int { parts.month }
            var utcDate: Int { parts.day }
            var utcDay: Int { parts.weekDay }
            var utcHours: Int { parts.hour }
            var utcMinutes: Int { parts.minute }
            var utcSeconds: Int { parts.second }
            var utcMilliseconds: Int { parts.millisecond }

            var daysInCurrentMonth: Int {
                let p = parts
                return daysInMonth(year: p.year, month: p.month)
            }

            mutating func setUTCSeconds(_ seconds: Int, milliseconds: Int? = nil) {
                let p = parts
                let ms = milliseconds ?? p.millisecond
                let base = epochMs - Int64(p.second) * 1_000 - Int64(p.millisecond)
                epochMs = base + Int64(seconds) * 1_000 + Int64(ms)
            }

            mutating func setUTCMinutes(_ minutes: Int, seconds: Int) {
                let p = parts
                let base = epochMs - Int64(p.minute) * 60_000 - Int64(p.second) * 1_000 - Int64(p.millisecond)
                epochMs = base + Int64(minutes) * 60_000 + Int64(seconds) * 1_000 + Int64(p.millisecond)
            }

            mutating func setUTCHours(_ hours: Int, minutes: Int, seconds: Int) {
                let p = parts
                let dayStart = floorDiv(epochMs, dayMs) * dayMs
                epochMs = dayStart + Int64(hours) * 3_600_000 + Int64(minutes) * 60_000 + Int64(seconds) * 1_000 + Int64(p.millisecond)
            }

            mutating func setUTCDate(_ day: Int) {
                let p = parts
                epochMs = makeUTCMillis(
                    year: p.year,
                    month0: Int64(p.month - 1),
                    day: Int64(day),
                    hour: Int64(p.hour),
                    minute: Int64(p.minute),
                    second: Int64(p.second),
                    millisecond: Int64(p.millisecond)
                )
            }

            mutating func setUTCMonth(_ month0: Int, day: Int) {
                let p = parts
                epochMs = makeUTCMillis(
                    year: p.year,
                    month0: Int64(month0),
                    day: Int64(day),
                    hour: Int64(p.hour),
                    minute: Int64(p.minute),
                    second: Int64(p.second),
                    millisecond: Int64(p.millisecond)
                )
            }

            mutating func setUTCFullYear(_ year: Int64) {
                let p = parts
                epochMs = makeUTCMillis(
                    year: year,
                    month0: Int64(p.month - 1),
                    day: Int64(p.day),
                    hour: Int64(p.hour),
                    minute: Int64(p.minute),
                    second: Int64(p.second),
                    millisecond: Int64(p.millisecond)
                )
            }
        }

        /// Converts a UTC instant to local wall-clock epoch milliseconds in `zone` (`DateTime.toDate(zoned).getTime()`).
        static func toAdjustedWallMillis(utcMillis: Int64, zone: CronTimeZone) -> Int64 {
            utcMillis + zone.offsetMillis(at: utcMillis)
        }

        /// Resolves a local wall-clock timestamp (`adjustedMillis`) in `zone` to a UTC epoch millisecond
        /// using Effect 4.1.0 `makeZonedFromAdjusted` (`effect/dist/internal/dateTime.js` lines 493-552).
        static func resolveAdjustedWallMillis(
            _ adjustedMillis: Int64,
            zone: CronTimeZone,
            disambiguation: DSTDisambiguation = .compatible
        ) -> Int64? {
            if case .offset(let offset) = zone {
                return adjustedMillis - offset
            }
            let beforeOffset = zone.offsetMillis(at: adjustedMillis - dayMs)
            let afterOffset = zone.offsetMillis(at: adjustedMillis + dayMs)
            if beforeOffset == afterOffset {
                return adjustedMillis - beforeOffset
            }
            let isForwards = beforeOffset < afterOffset
            let transitionMillis = beforeOffset - afterOffset
            if isForwards {
                let currentAfterOffset = zone.offsetMillis(at: adjustedMillis - afterOffset)
                if currentAfterOffset == afterOffset {
                    return adjustedMillis - afterOffset
                }
                let beforeEpoch = adjustedMillis - beforeOffset
                let beforeAdjustedMillis = toAdjustedWallMillis(utcMillis: beforeEpoch, zone: zone)
                if adjustedMillis != beforeAdjustedMillis {
                    switch disambiguation {
                    case .reject:
                        return nil
                    case .earlier:
                        return adjustedMillis - afterOffset
                    case .compatible, .later:
                        return beforeEpoch
                    }
                }
                return beforeEpoch
            }
            let currentBeforeOffset = zone.offsetMillis(at: adjustedMillis - beforeOffset)
            if currentBeforeOffset == beforeOffset {
                if disambiguation == .earlier || disambiguation == .compatible {
                    return adjustedMillis - beforeOffset
                }
                let laterOffset = zone.offsetMillis(at: adjustedMillis - beforeOffset + transitionMillis)
                if laterOffset == beforeOffset {
                    return adjustedMillis - beforeOffset
                }
                if disambiguation == .reject {
                    return nil
                }
            }
            return adjustedMillis - afterOffset
        }

        /// Parses a wall-clock ISO-like date/time string (without offset) into adjusted wall-clock epoch milliseconds.
        /// Supports `YYYY-MM-DD`, `YYYY-MM-DDTHH:MM`, `YYYY-MM-DD HH:MM:SS`, fractional seconds, etc.
        static func parseWallClockString(_ input: String) -> Int64? {
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let bytes = Array(trimmed.utf8)
            var idx = 0

            func readDigits(min: Int, max: Int) -> Int? {
                let start = idx
                var val = 0
                while idx < bytes.count && (idx - start) < max && bytes[idx] >= 0x30 && bytes[idx] <= 0x39 {
                    val = val * 10 + Int(bytes[idx] - 0x30)
                    idx += 1
                }
                guard (idx - start) >= min else { return nil }
                return val
            }

            guard let year = readDigits(min: 4, max: 4),
                  idx < bytes.count, bytes[idx] == 0x2D /* '-' */
            else { return nil }
            idx += 1
            guard let month = readDigits(min: 2, max: 2), (1...12).contains(month),
                  idx < bytes.count, bytes[idx] == 0x2D /* '-' */
            else { return nil }
            idx += 1
            guard let day = readDigits(min: 2, max: 2), (1...daysInMonth(year: Int64(year), month: month)).contains(day) else {
                return nil
            }

            if idx == bytes.count {
                return makeUTCMillis(year: Int64(year), month0: Int64(month - 1), day: Int64(day))
            }
            guard bytes[idx] == 0x54 /* 'T' */ || bytes[idx] == 0x74 /* 't' */ || bytes[idx] == 0x20 /* ' ' */ else {
                return nil
            }
            idx += 1

            guard let hour = readDigits(min: 2, max: 2), (0...23).contains(hour),
                  idx < bytes.count, bytes[idx] == 0x3A /* ':' */
            else { return nil }
            idx += 1
            guard let minute = readDigits(min: 2, max: 2), (0...59).contains(minute) else { return nil }

            var second = 0
            var millisecond = 0
            if idx < bytes.count && bytes[idx] == 0x3A /* ':' */ {
                idx += 1
                guard let sec = readDigits(min: 2, max: 2), (0...59).contains(sec) else { return nil }
                second = sec
                if idx < bytes.count && bytes[idx] == 0x2E /* '.' */ {
                    idx += 1
                    let fracStart = idx
                    var fracDigits: [Int] = []
                    while idx < bytes.count && bytes[idx] >= 0x30 && bytes[idx] <= 0x39 {
                        fracDigits.append(Int(bytes[idx] - 0x30))
                        idx += 1
                    }
                    guard idx > fracStart else { return nil }
                    let d0 = fracDigits.count > 0 ? fracDigits[0] : 0
                    let d1 = fracDigits.count > 1 ? fracDigits[1] : 0
                    let d2 = fracDigits.count > 2 ? fracDigits[2] : 0
                    millisecond = d0 * 100 + d1 * 10 + d2
                }
            }
            guard idx == bytes.count else { return nil }
            return makeUTCMillis(
                year: Int64(year),
                month0: Int64(month - 1),
                day: Int64(day),
                hour: Int64(hour),
                minute: Int64(minute),
                second: Int64(second),
                millisecond: Int64(millisecond)
            )
        }

        /// Parses an ISO-8601 instant with an explicit timezone offset (`Z`, `z`, `+HH:MM`, `-HHMM`, space or `T`).
        static func parseOffsetInstant(_ input: String) -> Int64? {
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.hasSuffix("Z") || trimmed.hasSuffix("z") {
                return parseWallClockString(String(trimmed.dropLast()))
            }
            // Match trailing `[+-]HH:?MM`
            let bytes = Array(trimmed.utf8)
            var splitIdx: Int?
            if bytes.count >= 6 {
                let candidate = bytes[bytes.count - 6]
                if (candidate == 0x2B || candidate == 0x2D) && bytes[bytes.count - 3] == 0x3A {
                    splitIdx = bytes.count - 6
                }
            }
            if splitIdx == nil && bytes.count >= 5 {
                let candidate = bytes[bytes.count - 5]
                if candidate == 0x2B || candidate == 0x2D {
                    splitIdx = bytes.count - 5
                }
            }
            guard let splitIdx else { return nil }
            let datePart = String(decoding: bytes[0..<splitIdx], as: UTF8.self)
            let offsetPart = String(decoding: bytes[splitIdx...], as: UTF8.self)
            guard let wall = parseWallClockString(datePart),
                  let offsetMs = CronTimeZone.parseStrictOffsetMillis(offsetPart, allowGMTPrefix: false)
            else { return nil }
            return wall - offsetMs
        }
    }

    /// Faithfully ported Effect 4.1.0 `Cron` schedule supporting 5- and 6-field expressions,
    /// ranges, steps, lists, month/weekday aliases, Vixie day/weekday OR-vs-AND semantics,
    /// time zones, and DST gap/overlap stepping.
    public struct Cron: Equatable, Hashable, Sendable {
        public let seconds: [Int]
        public let minutes: [Int]
        public let hours: [Int]
        public let days: [Int]
        public let months: [Int]
        public let weekdays: [Int]
        public let and: Bool
        public let tz: CronTimeZone?
        public let onDstOverlap: DSTOverlapPolicy

        private let secondSet: Set<Int>
        private let minuteSet: Set<Int>
        private let hourSet: Set<Int>
        private let daySet: Set<Int>
        private let monthSet: Set<Int>
        private let weekdaySet: Set<Int>

        private struct Boundary: Equatable, Hashable, Sendable {
            let second: Int
            let minute: Int
            let hour: Int
            let day: Int
            let month0: Int // 0...11
            let weekday: Int
        }

        private struct LookupTables: Equatable, Hashable, Sendable {
            let second: [Int?]
            let minute: [Int?]
            let hour: [Int?]
            let day: [Int?]
            let month: [Int?]
            let weekday: [Int?]
        }

        private let first: Boundary
        private let last: Boundary
        private let nextTable: LookupTables
        private let prevTable: LookupTables

        private struct SegmentOptions: Sendable {
            let min: Int
            let max: Int
            let normalize: @Sendable (Int) -> Int
            let aliases: [String: Int]?
        }

        private static let secondOptions = SegmentOptions(min: 0, max: 59, normalize: { $0 }, aliases: nil)
        private static let minuteOptions = SegmentOptions(min: 0, max: 59, normalize: { $0 }, aliases: nil)
        private static let hourOptions = SegmentOptions(min: 0, max: 23, normalize: { $0 }, aliases: nil)
        private static let dayOptions = SegmentOptions(min: 1, max: 31, normalize: { $0 }, aliases: nil)
        private static let monthOptions = SegmentOptions(
            min: 1,
            max: 12,
            normalize: { $0 },
            aliases: [
                "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
            ]
        )
        private static let weekdayOptions = SegmentOptions(
            min: 0,
            max: 7,
            normalize: { $0 == 7 ? 0 : $0 },
            aliases: [
                "sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6,
            ]
        )

        public init(
            seconds: [Int] = [0],
            minutes: [Int] = [],
            hours: [Int] = [],
            days: [Int] = [],
            months: [Int] = [],
            weekdays: [Int] = [],
            and: Bool = false,
            tz: CronTimeZone? = nil,
            onDstOverlap: DSTOverlapPolicy = .earlier
        ) {
            let sortedSeconds = Array(Set(seconds)).sorted()
            let sortedMinutes = Array(Set(minutes)).sorted()
            let sortedHours = Array(Set(hours)).sorted()
            let sortedDays = Array(Set(days)).sorted()
            let sortedMonths = Array(Set(months)).sorted()
            let sortedWeekdays = Array(Set(weekdays.map { $0 == 7 ? 0 : $0 })).sorted()

            self.seconds = sortedSeconds
            self.minutes = sortedMinutes
            self.hours = sortedHours
            self.days = sortedDays
            self.months = sortedMonths
            self.weekdays = sortedWeekdays
            self.and = and
            self.tz = tz
            self.onDstOverlap = onDstOverlap

            self.secondSet = Set(sortedSeconds)
            self.minuteSet = Set(sortedMinutes)
            self.hourSet = Set(sortedHours)
            self.daySet = Set(sortedDays)
            self.monthSet = Set(sortedMonths)
            self.weekdaySet = Set(sortedWeekdays)

            self.first = Boundary(
                second: sortedSeconds.first ?? 0,
                minute: sortedMinutes.first ?? 0,
                hour: sortedHours.first ?? 0,
                day: sortedDays.first ?? 1,
                month0: (sortedMonths.first ?? 1) - 1,
                weekday: sortedWeekdays.first ?? 0
            )
            self.last = Boundary(
                second: sortedSeconds.last ?? 59,
                minute: sortedMinutes.last ?? 59,
                hour: sortedHours.last ?? 23,
                day: sortedDays.last ?? 31,
                month0: (sortedMonths.last ?? 12) - 1,
                weekday: sortedWeekdays.last ?? 6
            )
            self.nextTable = LookupTables(
                second: Self.makeLookupTable(size: 60, forward: true, values: sortedSeconds),
                minute: Self.makeLookupTable(size: 60, forward: true, values: sortedMinutes),
                hour: Self.makeLookupTable(size: 24, forward: true, values: sortedHours),
                day: Self.makeLookupTable(size: 32, forward: true, values: sortedDays),
                month: Self.makeLookupTable(size: 13, forward: true, values: sortedMonths),
                weekday: Self.makeLookupTable(size: 7, forward: true, values: sortedWeekdays)
            )
            self.prevTable = LookupTables(
                second: Self.makeLookupTable(size: 60, forward: false, values: sortedSeconds),
                minute: Self.makeLookupTable(size: 60, forward: false, values: sortedMinutes),
                hour: Self.makeLookupTable(size: 24, forward: false, values: sortedHours),
                day: Self.makeLookupTable(size: 32, forward: false, values: sortedDays),
                month: Self.makeLookupTable(size: 13, forward: false, values: sortedMonths),
                weekday: Self.makeLookupTable(size: 7, forward: false, values: sortedWeekdays)
            )
        }

        private static func makeLookupTable(size: Int, forward: Bool, values: [Int]) -> [Int?] {
            var result = [Int?](repeating: nil, count: size)
            if values.isEmpty { return result }
            var current: Int? = nil
            if forward {
                var index = values.count - 1
                for i in stride(from: size - 1, through: 0, by: -1) {
                    while index >= 0 && values[index] >= i {
                        current = values[index]
                        index -= 1
                    }
                    result[i] = current
                }
            } else {
                var index = 0
                for i in 0..<size {
                    while index < values.count && values[index] <= i {
                        current = values[index]
                        index += 1
                    }
                    result[i] = current
                }
            }
            return result
        }

        /// Parses a 5- or 6-field cron expression with an optional resolved `CronTimeZone`.
        public static func parse(
            _ expression: String,
            timeZone: CronTimeZone? = nil,
            onDstOverlap: DSTOverlapPolicy = .earlier
        ) throws(CronParseError) -> Cron {
            try parseInternal(expression, tzInput: .resolved(timeZone), onDstOverlap: onDstOverlap)
        }

        /// Parses a 5- or 6-field cron expression with an optional time zone string (`Cron.parse(expr, tz)`).
        public static func parse(
            _ expression: String,
            timeZoneString: String?,
            onDstOverlap: DSTOverlapPolicy = .earlier
        ) throws(CronParseError) -> Cron {
            try parseInternal(expression, tzInput: .string(timeZoneString), onDstOverlap: onDstOverlap)
        }

        private enum TZInput {
            case resolved(CronTimeZone?)
            case string(String?)
        }

        private static func parseInternal(
            _ expression: String,
            tzInput: TZInput,
            onDstOverlap: DSTOverlapPolicy
        ) throws(CronParseError) -> Cron {
            var segments = expression
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
                .filter { !$0.isEmpty }

            guard segments.count == 5 || segments.count == 6 else {
                throw CronParseError(message: "Invalid number of segments in cron expression", input: expression)
            }
            if segments.count == 5 {
                segments.insert("0", at: 0)
            }

            let resolvedTZ: CronTimeZone?
            switch tzInput {
            case .resolved(let z):
                resolvedTZ = z
            case .string(let s):
                if let s {
                    guard let parsedZone = CronTimeZone.fromString(s) else {
                        throw CronParseError(message: "Invalid time zone in cron expression", input: s)
                    }
                    resolvedTZ = parsedZone
                } else {
                    resolvedTZ = nil
                }
            }

            let seconds = try parseSegment(segments[0], options: secondOptions)
            let minutes = try parseSegment(segments[1], options: minuteOptions)
            let hours = try parseSegment(segments[2], options: hourOptions)
            let days = try parseSegment(segments[3], options: dayOptions)
            let months = try parseSegment(segments[4], options: monthOptions)
            let weekdays = try parseSegment(segments[5], options: weekdayOptions)

            let andMode = (days.wildcard || weekdays.wildcard) && !days.values.isEmpty && !weekdays.values.isEmpty
            return Cron(
                seconds: Array(seconds.values),
                minutes: Array(minutes.values),
                hours: Array(hours.values),
                days: Array(days.values),
                months: Array(months.values),
                weekdays: Array(weekdays.values),
                and: andMode,
                tz: resolvedTZ,
                onDstOverlap: onDstOverlap
            )
        }

        private enum ParsedNumber {
            case integer(Int)
            case overflowPositive
            case notANumber
        }

        private static func parseDecimal(_ raw: String) -> ParsedNumber {
            guard !raw.isEmpty else { return .notANumber }
            for byte in raw.utf8 {
                if byte < 0x30 || byte > 0x39 { return .notANumber }
            }
            if let value = Int(raw) {
                return .integer(value)
            }
            return .overflowPositive
        }

        private static func splitStep(_ input: String) -> (raw: String, step: ParsedNumber?) {
            if let slash = input.firstIndex(of: "/") {
                let lhs = String(input[..<slash])
                let rhs = String(input[input.index(after: slash)...])
                return (lhs, parseDecimal(rhs))
            }
            return (input, nil)
        }

        private static func aliasOrValue(_ field: String, aliases: [String: Int]?) -> ParsedNumber {
            if let aliases, let mapped = aliases[field.lowercased()] {
                return .integer(mapped)
            }
            return parseDecimal(field)
        }

        private static func splitRange(_ input: String, aliases: [String: Int]?) -> (left: ParsedNumber, right: ParsedNumber?) {
            if let dash = input.firstIndex(of: "-") {
                let lhs = String(input[..<dash])
                let rhs = String(input[input.index(after: dash)...])
                return (aliasOrValue(lhs, aliases: aliases), aliasOrValue(rhs, aliases: aliases))
            }
            return (aliasOrValue(input, aliases: aliases), nil)
        }

        private static func parseSegment(
            _ input: String,
            options: SegmentOptions
        ) throws(CronParseError) -> (values: Set<Int>, wildcard: Bool) {
            var values = Set<Int>()
            let fields = input.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            let first = splitStep(fields[0])
            let wildcard = first.raw == "*"
            let firstStepIsWildcardAll: Bool
            switch first.step {
            case nil, .integer(1):
                firstStepIsWildcardAll = true
            default:
                firstStepIsWildcardAll = false
            }
            let suppressAdd = wildcard && firstStepIsWildcardAll

            func add(_ value: Int) {
                if !suppressAdd {
                    values.insert(options.normalize(value))
                }
            }

            for index in 0..<fields.count {
                let (raw, parsedStep) = (index == 0) ? first : splitStep(fields[index])
                let stepValue: Int?
                if let parsedStep {
                    switch parsedStep {
                    case .notANumber:
                        throw CronParseError(message: "Expected step value to be a positive integer", input: input)
                    case .overflowPositive:
                        throw CronParseError(message: "Expected step value to be less than or equal to \(options.max)", input: input)
                    case .integer(let step):
                        if step < 1 {
                            throw CronParseError(message: "Expected step value to be greater than 0", input: input)
                        }
                        if step > options.max {
                            throw CronParseError(message: "Expected step value to be less than or equal to \(options.max)", input: input)
                        }
                        stepValue = step
                    }
                } else {
                    stepValue = nil
                }

                if raw == "*" {
                    if index == 0 && (stepValue == nil || stepValue == 1) {
                        continue
                    }
                    let strideBy = stepValue ?? 1
                    var i = options.min
                    while i <= options.max {
                        add(i)
                        i += strideBy
                    }
                } else {
                    let (parsedLeft, parsedRight) = splitRange(raw, aliases: options.aliases)
                    let left: Int
                    switch parsedLeft {
                    case .notANumber:
                        throw CronParseError(message: "Expected a positive integer", input: input)
                    case .overflowPositive:
                        throw CronParseError(message: "Expected a value between \(options.min) and \(options.max)", input: input)
                    case .integer(let v):
                        if v < options.min || v > options.max {
                            throw CronParseError(message: "Expected a value between \(options.min) and \(options.max)", input: input)
                        }
                        left = v
                    }

                    if let parsedRight {
                        let right: Int
                        switch parsedRight {
                        case .notANumber:
                            throw CronParseError(message: "Expected a positive integer", input: input)
                        case .overflowPositive:
                            throw CronParseError(message: "Expected a value between \(options.min) and \(options.max)", input: input)
                        case .integer(let v):
                            if v < options.min || v > options.max {
                                throw CronParseError(message: "Expected a value between \(options.min) and \(options.max)", input: input)
                            }
                            right = v
                        }
                        if left > right {
                            throw CronParseError(message: "Invalid value range", input: input)
                        }
                        let strideBy = stepValue ?? 1
                        var i = left
                        while i <= right {
                            add(i)
                            i += strideBy
                        }
                    } else {
                        let upper = (stepValue == nil) ? left : options.max
                        let strideBy = stepValue ?? 1
                        var i = left
                        while i <= upper {
                            add(i)
                            i += strideBy
                        }
                    }
                }
            }

            return (values, wildcard)
        }

        /// Returns `true` when `epochMs` matches this cron schedule in its configured time zone (or local zone).
        public func matches(epochMs: Int64) -> Bool {
            let zone = tz ?? CronTimeZone.local()
            let adjusted = CronCalendar.toAdjustedWallMillis(utcMillis: epochMs, zone: zone)
            let p = CronCalendar.partsUTC(epochMs: adjusted)
            if !secondSet.isEmpty && !secondSet.contains(p.second) { return false }
            if !minuteSet.isEmpty && !minuteSet.contains(p.minute) { return false }
            if !hourSet.isEmpty && !hourSet.contains(p.hour) { return false }
            if !monthSet.isEmpty && !monthSet.contains(p.month) { return false }
            if daySet.isEmpty && weekdaySet.isEmpty { return true }
            if and {
                return (daySet.isEmpty || daySet.contains(p.day))
                    && (weekdaySet.isEmpty || weekdaySet.contains(p.weekDay))
            }
            if weekdaySet.isEmpty { return daySet.contains(p.day) }
            if daySet.isEmpty { return weekdaySet.contains(p.weekDay) }
            return daySet.contains(p.day) || weekdaySet.contains(p.weekDay)
        }

        /// Returns the next occurrence strictly after `afterEpochMs`, or `nil` if no occurrence exists
        /// within Effect's 10,000-iteration search bound (e.g. `"0 0 31 2 *"`).
        public func next(after afterEpochMs: Int64) -> Int64? {
            step(from: afterEpochMs, reverse: false)
        }

        /// Returns the previous occurrence strictly before `beforeEpochMs`, or `nil` if none exists.
        public func prev(before beforeEpochMs: Int64) -> Int64? {
            step(from: beforeEpochMs, reverse: true)
        }

        private func step(from epochMs: Int64, reverse: Bool) -> Int64? {
            if onDstOverlap != .both {
                return search(from: epochMs, reverse: reverse, overlap: onDstOverlap)
            }
            let earlier = search(from: epochMs, reverse: reverse, overlap: .earlier)
            let later = search(from: epochMs, reverse: reverse, overlap: .later)
            switch (earlier, later) {
            case (let e?, let l?):
                return reverse ? max(e, l) : min(e, l)
            case (let e?, nil):
                return e
            case (nil, let l?):
                return l
            case (nil, nil):
                return nil
            }
        }

        /// Exact port of Effect 4.1.0 `searchCron` (`effect/dist/Cron.js` lines 689-911).
        private func search(from startEpochMs: Int64, reverse: Bool, overlap: DSTOverlapPolicy) -> Int64? {
            guard startEpochMs >= CronCalendar.minEpochMs && startEpochMs <= CronCalendar.maxEpochMs else {
                return nil
            }
            // When `tz` is omitted, Effect uses the host offset at `startEpochMs` (`makeZonedUnsafe` line 215-217).
            let zone: CronTimeZone
            if let tz {
                zone = tz
            } else {
                zone = .offset(millis: CronTimeZone.local().offsetMillis(at: startEpochMs))
            }

            let tick = reverse ? -1 : 1
            let table = reverse ? prevTable : nextTable
            let boundary = reverse ? last : first
            let isUTC = tz?.isNamedUTC == true
            let disambiguation: DSTDisambiguation = (overlap == .later) ? .later : .compatible

            @inline(__always)
            func needsStep(_ candidate: Int, _ current: Int) -> Bool {
                reverse ? (candidate < current) : (candidate > current)
            }

            @inline(__always)
            func resolve(_ wallMillis: Int64) -> Int64 {
                CronCalendar.resolveAdjustedWallMillis(wallMillis, zone: zone, disambiguation: disambiguation)
                    ?? (wallMillis - zone.offsetMillis(at: wallMillis))
            }

            @inline(__always)
            func adjustDst(_ current: inout CronCalendar.MutableUTCDate) {
                if isUTC || reverse { return }
                let resolvedEpoch = CronCalendar.resolveAdjustedWallMillis(
                    current.epochMs,
                    zone: zone,
                    disambiguation: .compatible
                ) ?? current.epochMs
                let adjustedWall = CronCalendar.toAdjustedWallMillis(utcMillis: resolvedEpoch, zone: zone)
                let drift = current.epochMs - adjustedWall
                if drift > 0 {
                    current.epochMs += drift
                }
            }

            @inline(__always)
            func isOutOfRange(_ wallMillis: Int64) -> Bool {
                if isUTC { return false }
                let resolved = resolve(wallMillis)
                return reverse ? (resolved >= startEpochMs) : (resolved <= startEpochMs)
            }

            var cachedFoldSeconds: Int64? = nil
            func skipOutOfRange(_ current: inout CronCalendar.MutableUTCDate) {
                let foldSeconds: Int64
                if let cached = cachedFoldSeconds {
                    foldSeconds = cached
                } else {
                    let beforeOff = zone.offsetMillis(at: startEpochMs - CronCalendar.dayMs)
                    let afterOff = zone.offsetMillis(at: startEpochMs + CronCalendar.dayMs)
                    foldSeconds = CronCalendar.floorDiv(beforeOff - afterOff, 1_000)
                    cachedFoldSeconds = foldSeconds
                }
                func after(_ secs: Int64) -> Int64 {
                    current.epochMs + Int64(tick) * secs * 1_000
                }
                var outOfRange: Int64 = 0
                var inRange: Int64 = 1
                if foldSeconds > 0 && !isOutOfRange(after(foldSeconds)) {
                    inRange = foldSeconds
                    while inRange - outOfRange > 1 {
                        let mid = outOfRange + (inRange - outOfRange) / 2
                        if isOutOfRange(after(mid)) {
                            outOfRange = mid
                        } else {
                            inRange = mid
                        }
                    }
                }
                current.epochMs = after(inRange)
            }

            var current = CronCalendar.MutableUTCDate(
                epochMs: CronCalendar.toAdjustedWallMillis(utcMillis: startEpochMs, zone: zone)
            )
            let shift: Int64 = isUTC ? 0 : (startEpochMs - resolve(current.epochMs))
            if reverse ? (shift > 0) : (shift < 0) {
                current.epochMs += shift
            }
            let initialOffset = (reverse && current.utcMilliseconds > 0) ? 0 : tick
            current.setUTCSeconds(current.utcSeconds + initialOffset, milliseconds: 0)

            var i = 0
            while i < 10_000 {
                if !secondSet.isEmpty {
                    let currentSecond = current.utcSeconds
                    guard let nextSecond = table.second[currentSecond] else {
                        current.setUTCMinutes(current.utcMinutes + tick, seconds: boundary.second)
                        adjustDst(&current)
                        i += 1
                        continue
                    }
                    if needsStep(nextSecond, currentSecond) {
                        current.setUTCSeconds(nextSecond)
                        adjustDst(&current)
                        i += 1
                        continue
                    }
                }

                if !minuteSet.isEmpty {
                    let currentMinute = current.utcMinutes
                    guard let nextMinute = table.minute[currentMinute] else {
                        current.setUTCHours(current.utcHours + tick, minutes: boundary.minute, seconds: boundary.second)
                        adjustDst(&current)
                        i += 1
                        continue
                    }
                    if needsStep(nextMinute, currentMinute) {
                        current.setUTCMinutes(nextMinute, seconds: boundary.second)
                        adjustDst(&current)
                        i += 1
                        continue
                    }
                }

                if !hourSet.isEmpty {
                    let currentHour = current.utcHours
                    guard let nextHour = table.hour[currentHour] else {
                        current.setUTCDate(current.utcDate + tick)
                        current.setUTCHours(boundary.hour, minutes: boundary.minute, seconds: boundary.second)
                        adjustDst(&current)
                        i += 1
                        continue
                    }
                    if needsStep(nextHour, currentHour) {
                        current.setUTCHours(nextHour, minutes: boundary.minute, seconds: boundary.second)
                        adjustDst(&current)
                        i += 1
                        continue
                    }
                }

                if !weekdaySet.isEmpty || !daySet.isEmpty {
                    if and {
                        let matchesDay = daySet.isEmpty || daySet.contains(current.utcDate)
                        let matchesWeekday = weekdaySet.isEmpty || weekdaySet.contains(current.utcDay)
                        if !matchesDay || !matchesWeekday {
                            current.setUTCDate(current.utcDate + tick)
                            current.setUTCHours(boundary.hour, minutes: boundary.minute, seconds: boundary.second)
                            adjustDst(&current)
                            i += 1
                            continue
                        }
                    } else {
                        var a: Int? = nil
                        var b: Int? = nil
                        if !weekdaySet.isEmpty {
                            let currentWeekday = current.utcDay
                            if let nextWeekday = table.weekday[currentWeekday] {
                                a = nextWeekday - currentWeekday
                            } else {
                                a = reverse
                                    ? (boundary.weekday - 7 - currentWeekday)
                                    : (7 - currentWeekday + boundary.weekday)
                            }
                        }
                        if !daySet.isEmpty && a != 0 {
                            let currentDay = current.utcDate
                            let monthDays = current.daysInCurrentMonth
                            if let nextDay = table.day[currentDay] {
                                if !reverse && nextDay > monthDays {
                                    b = monthDays - currentDay + boundary.day
                                } else {
                                    b = nextDay - currentDay
                                }
                            } else {
                                if reverse {
                                    var previous = current
                                    previous.setUTCDate(0)
                                    var foundDay = table.day[previous.utcDate]
                                    if foundDay == nil {
                                        previous.setUTCDate(0)
                                        foundDay = table.day[previous.utcDate]
                                    }
                                    guard let validDay = foundDay else { return nil }
                                    previous.setUTCDate(validDay)
                                    b = Int((previous.epochMs - current.epochMs) / CronCalendar.dayMs)
                                } else {
                                    b = monthDays - currentDay + boundary.day
                                }
                            }
                        }
                        let addDays: Int
                        switch (a, b) {
                        case (let av?, let bv?):
                            addDays = reverse ? max(av, bv) : min(av, bv)
                        case (let av?, nil):
                            addDays = av
                        case (nil, let bv?):
                            addDays = bv
                        case (nil, nil):
                            addDays = 0
                        }
                        if addDays != 0 {
                            current.setUTCDate(current.utcDate + addDays)
                            current.setUTCHours(boundary.hour, minutes: boundary.minute, seconds: boundary.second)
                            adjustDst(&current)
                            i += 1
                            continue
                        }
                    }
                }

                if !monthSet.isEmpty {
                    let currentMonth = current.utcMonth1
                    let currentYear = current.utcFullYear
                    func clampBoundaryDay(_ targetMonth0: Int, year: Int64) -> Int {
                        let maxDayInMonth = CronCalendar.daysInMonth(year: year, month: targetMonth0 + 1)
                        if !daySet.isEmpty && weekdaySet.isEmpty {
                            return reverse ? (table.day[maxDayInMonth] ?? maxDayInMonth) : boundary.day
                        }
                        return reverse ? maxDayInMonth : 1
                    }
                    guard let nextMonth = table.month[currentMonth] else {
                        let nextYear = currentYear + Int64(tick)
                        current.setUTCFullYear(nextYear)
                        let effectiveYear = current.utcFullYear
                        current.setUTCMonth(boundary.month0, day: clampBoundaryDay(boundary.month0, year: effectiveYear))
                        current.setUTCHours(boundary.hour, minutes: boundary.minute, seconds: boundary.second)
                        adjustDst(&current)
                        i += 1
                        continue
                    }
                    if needsStep(nextMonth, currentMonth) {
                        let targetMonth0 = nextMonth - 1
                        current.setUTCMonth(targetMonth0, day: clampBoundaryDay(targetMonth0, year: currentYear))
                        current.setUTCHours(boundary.hour, minutes: boundary.minute, seconds: boundary.second)
                        adjustDst(&current)
                        i += 1
                        continue
                    }
                }

                if isOutOfRange(current.epochMs) {
                    skipOutOfRange(&current)
                    // Skipped fold candidates do not count against the 10,000-iteration search budget.
                    i = 0
                    continue
                }

                return resolve(current.epochMs)
            }

            return nil
        }

        /// Upstream `nextCron` wrapper (`automation.ts` lines 176-181): guarantees strictly after `now`
        /// by stepping past any repeated wall-clock occurrence already in the past.
        public func nextSlot(after now: Int64) -> Int64? {
            var from = now
            while true {
                guard let at = next(after: from) else { return nil }
                if at > now { return at }
                from = at + CoreAutomation.Service.hourMs
            }
        }
    }
}
