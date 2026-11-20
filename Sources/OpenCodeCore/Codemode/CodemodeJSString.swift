import Foundation

extension CodemodeLanguage {
    /// Faithful UTF-16 JavaScript string value for Code Mode.
    ///
    /// JavaScript strings are sequences of 16-bit unsigned code units (`UInt16`) that may contain
    /// unpaired (lone) UTF-16 surrogates (`0xD800...0xDFFF`), whereas Swift `String` can only
    /// represent well-formed Unicode scalar sequences.
    ///
    /// Hybrid canonical representation:
    /// - `.swift(String)` whenever the code-unit sequence is well-formed UTF-16 (the fast common path,
    ///   zero extra allocation for ASCII and valid Unicode).
    /// - `.utf16([UInt16])` if and only if the sequence contains at least one unpaired surrogate.
    ///
    /// Because the representation is canonical, well-formed and ill-formed strings are never equal,
    /// `isWellFormed` is O(1), and re-pairing halves (e.g. `"\ud83d" + "\ude00"`) automatically
    /// normalizes back to `.swift("😀")`.
    ///
    /// Equality and hashing operate on exact UTF-16 code-unit identity (matching JS `===`, unlike
    /// Swift's `String.==` which performs Unicode canonical equivalence).
    public struct JSString: Equatable, Hashable, Comparable, Sendable, ExpressibleByStringLiteral, ExpressibleByStringInterpolation, CustomStringConvertible {
        private enum Storage: Sendable {
            case swift(String)
            case utf16([UInt16])
        }

        private let storage: Storage

        public static let empty = JSString("")

        // MARK: - Initializers

        public init(_ string: String) {
            self.storage = .swift(string)
        }

        public init(stringLiteral value: String) {
            self.storage = .swift(value)
        }

        public init(utf16 units: [UInt16]) {
            if Self.isWellFormedUTF16(units) {
                self.storage = .swift(String(decoding: units, as: UTF16.self))
            } else {
                self.storage = .utf16(units)
            }
        }

        public init(utf16 units: ArraySlice<UInt16>) {
            if Self.isWellFormedUTF16(units) {
                self.storage = .swift(String(decoding: units, as: UTF16.self))
            } else {
                self.storage = .utf16(Array(units))
            }
        }

        public init(unit: UInt16) {
            if unit >= 0xD800 && unit <= 0xDFFF {
                self.storage = .utf16([unit])
            } else if let scalar = Unicode.Scalar(unit) {
                self.storage = .swift(String(scalar))
            } else {
                self.storage = .utf16([unit])
            }
        }

        public init(codePoint: UInt32) {
            if codePoint >= 0xD800 && codePoint <= 0xDFFF {
                self.storage = .utf16([UInt16(codePoint)])
            } else if let scalar = Unicode.Scalar(codePoint) {
                self.storage = .swift(String(scalar))
            } else {
                self.storage = .utf16([UInt16(truncatingIfNeeded: codePoint)])
            }
        }

        public struct StringInterpolation: StringInterpolationProtocol {
            fileprivate var units: [UInt16] = []
            fileprivate var swiftOnly = true
            fileprivate var swiftBuffer = ""

            public init(literalCapacity: Int, interpolationCount: Int) {
                swiftBuffer.reserveCapacity(literalCapacity + interpolationCount * 8)
            }

            public mutating func appendLiteral(_ literal: String) {
                if swiftOnly {
                    swiftBuffer.append(literal)
                } else {
                    units.append(contentsOf: literal.utf16)
                }
            }

            public mutating func appendInterpolation(_ value: JSString) {
                switch value.storage {
                case .swift(let s):
                    if swiftOnly {
                        swiftBuffer.append(s)
                    } else {
                        units.append(contentsOf: s.utf16)
                    }
                case .utf16(let u):
                    if swiftOnly {
                        swiftOnly = false
                        units = Array(swiftBuffer.utf16)
                        swiftBuffer = ""
                    }
                    units.append(contentsOf: u)
                }
            }

            public mutating func appendInterpolation(_ value: String) {
                appendLiteral(value)
            }

            public mutating func appendInterpolation<T>(_ value: T) {
                appendLiteral(String(describing: value))
            }
        }

        public init(stringInterpolation: StringInterpolation) {
            if stringInterpolation.swiftOnly {
                self.init(stringInterpolation.swiftBuffer)
            } else {
                self.init(utf16: stringInterpolation.units)
            }
        }

        // MARK: - Canonical Well-Formedness Check

        public static func isWellFormedUTF16<C: Collection>(_ units: C) -> Bool where C.Element == UInt16 {
            var i = units.startIndex
            let end = units.endIndex
            while i < end {
                let u = units[i]
                if u >= 0xD800 && u <= 0xDBFF {
                    let next = units.index(after: i)
                    guard next < end else { return false }
                    let lo = units[next]
                    guard lo >= 0xDC00 && lo <= 0xDFFF else { return false }
                    i = units.index(after: next)
                } else if u >= 0xDC00 && u <= 0xDFFF {
                    return false
                } else {
                    i = units.index(after: i)
                }
            }
            return true
        }

        // MARK: - Properties & Conversions

        public var isWellFormed: Bool {
            if case .swift = storage { return true }
            return false
        }

        public var isEmpty: Bool {
            switch storage {
            case .swift(let s): return s.isEmpty
            case .utf16(let u): return u.isEmpty
            }
        }

        public var utf16Count: Int {
            switch storage {
            case .swift(let s): return s.utf16.count
            case .utf16(let u): return u.count
            }
        }

        public var utf16Units: [UInt16] {
            switch storage {
            case .swift(let s): return Array(s.utf16)
            case .utf16(let u): return u
            }
        }

        /// Returns the underlying Swift `String` if well-formed, or `nil` if lone surrogates are present.
        public var wellFormedString: String? {
            if case .swift(let s) = storage { return s }
            return nil
        }

        /// Converts to a well-formed Swift `String`, replacing every unpaired UTF-16 surrogate
        /// with U+FFFD (Unicode Replacement Character) while preserving valid surrogate pairs.
        ///
        /// Note: preserves exact UTF-16 code-unit length and 1-to-1 code-unit indexing (each
        /// 1-unit lone surrogate maps to 1-unit `U+FFFD`).
        public func toWellFormedString() -> String {
            switch storage {
            case .swift(let s):
                return s
            case .utf16(let units):
                var scalars = String.UnicodeScalarView()
                scalars.reserveCapacity(units.count)
                var i = 0
                let count = units.count
                while i < count {
                    let u = units[i]
                    if u >= 0xD800 && u <= 0xDBFF, i + 1 < count {
                        let lo = units[i + 1]
                        if lo >= 0xDC00 && lo <= 0xDFFF {
                            let cp = 0x10000 + ((UInt32(u - 0xD800) << 10) | UInt32(lo - 0xDC00))
                            scalars.append(Unicode.Scalar(cp)!)
                            i += 2
                            continue
                        }
                    }
                    if u >= 0xD800 && u <= 0xDFFF {
                        scalars.append("\u{FFFD}")
                    } else if let sc = Unicode.Scalar(u) {
                        scalars.append(sc)
                    } else {
                        scalars.append("\u{FFFD}")
                    }
                    i += 1
                }
                return String(scalars)
            }
        }

        public func toWellFormed() -> JSString {
            JSString(toWellFormedString())
        }

        /// Host boundary conversion to Swift `String` / `JSONValue`: well-formed strings pass
        /// through directly; lone surrogates become U+FFFD so Swift `String` and `JSONValue`
        /// never crash or fail to encode.
        public func toHostString() -> String {
            toWellFormedString()
        }

        public var description: String {
            toWellFormedString()
        }

        /// UTF-8 byte sequence, replacing each unpaired UTF-16 surrogate with U+FFFD (`[0xEF, 0xBF, 0xBD]`),
        /// matching WHATWG `TextEncoder` and Node `Buffer.from(str, "utf8")`.
        public func utf8BytesReplacingSurrogates() -> [UInt8] {
            Array(toWellFormedString().utf8)
        }

        // MARK: - Equality, Hashing & UTF-16 Code-Unit Ordering

        public static func == (lhs: JSString, rhs: JSString) -> Bool {
            switch (lhs.storage, rhs.storage) {
            case (.swift(let a), .swift(let b)):
                // Exact code-unit equality (UTF-8 byte sequence is a bijection on valid Unicode scalar sequences,
                // unlike Swift's `String.==` which performs Unicode canonical equivalence).
                return a.utf8.count == b.utf8.count && a.utf8.elementsEqual(b.utf8)
            case (.utf16(let a), .utf16(let b)):
                return a == b
            default:
                // Canonical invariant: .swift has no unpaired surrogates, .utf16 has at least one.
                return false
            }
        }

        public func hash(into hasher: inout Hasher) {
            switch storage {
            case .swift(let s):
                hasher.combine(UInt8(0))
                hasher.combine(s.utf8.count)
                for b in s.utf8 {
                    hasher.combine(b)
                }
            case .utf16(let u):
                hasher.combine(UInt8(1))
                hasher.combine(u)
            }
        }

        /// Lexicographical comparison by UTF-16 code units (ECMA-262 IsLessThan / CompareStrings).
        public static func compareUTF16(_ lhs: JSString, _ rhs: JSString) -> Int {
            switch (lhs.storage, rhs.storage) {
            case (.swift(let a), .swift(let b)):
                var ia = a.utf16.makeIterator()
                var ib = b.utf16.makeIterator()
                while true {
                    switch (ia.next(), ib.next()) {
                    case (let x?, let y?):
                        if x < y { return -1 }
                        if x > y { return 1 }
                    case (nil, .some): return -1
                    case (.some, nil): return 1
                    case (nil, nil): return 0
                    }
                }
            default:
                let a = lhs.utf16Units
                let b = rhs.utf16Units
                let n = min(a.count, b.count)
                for i in 0..<n {
                    if a[i] < b[i] { return -1 }
                    if a[i] > b[i] { return 1 }
                }
                if a.count < b.count { return -1 }
                if a.count > b.count { return 1 }
                return 0
            }
        }

        public static func < (lhs: JSString, rhs: JSString) -> Bool {
            compareUTF16(lhs, rhs) < 0
        }

        // MARK: - Concatenation & Joining

        public static func + (lhs: JSString, rhs: JSString) -> JSString {
            if lhs.isEmpty { return rhs }
            if rhs.isEmpty { return lhs }
            switch (lhs.storage, rhs.storage) {
            case (.swift(let a), .swift(let b)):
                return JSString(a + b)
            default:
                var combined = lhs.utf16Units
                combined.append(contentsOf: rhs.utf16Units)
                return JSString(utf16: combined)
            }
        }

        public static func += (lhs: inout JSString, rhs: JSString) {
            lhs = lhs + rhs
        }

        public static func joined(_ parts: [JSString], separator: JSString = .empty) -> JSString {
            if parts.isEmpty { return .empty }
            if parts.count == 1 { return parts[0] }
            if separator.isWellFormed, parts.allSatisfy(\.isWellFormed) {
                let sep = separator.wellFormedString ?? ""
                return JSString(parts.map { $0.wellFormedString ?? "" }.joined(separator: sep))
            }
            let sepUnits = separator.utf16Units
            var total = max(0, parts.count - 1) * sepUnits.count
            for p in parts { total += p.utf16Count }
            var out: [UInt16] = []
            out.reserveCapacity(total)
            for (i, p) in parts.enumerated() {
                if i > 0 { out.append(contentsOf: sepUnits) }
                out.append(contentsOf: p.utf16Units)
            }
            return JSString(utf16: out)
        }

        public func repeated(count: Int) -> JSString {
            if count <= 0 || isEmpty { return .empty }
            if count == 1 { return self }
            switch storage {
            case .swift(let s):
                return JSString(String(repeating: s, count: count))
            case .utf16(let units):
                var out: [UInt16] = []
                out.reserveCapacity(units.count * count)
                for _ in 0..<count {
                    out.append(contentsOf: units)
                }
                return JSString(utf16: out)
            }
        }

        // MARK: - UTF-16 Code-Unit Indexing, Slicing & Code-Point Iteration

        public func unit(at index: Int) -> UInt16? {
            guard index >= 0 else { return nil }
            switch storage {
            case .utf16(let u):
                return index < u.count ? u[index] : nil
            case .swift(let s):
                let view = s.utf16
                guard let idx = view.index(view.startIndex, offsetBy: index, limitedBy: view.endIndex),
                      idx < view.endIndex else { return nil }
                return view[idx]
            }
        }

        public func codePoint(at index: Int) -> UInt32? {
            let units = utf16Units
            guard index >= 0 && index < units.count else { return nil }
            let first = units[index]
            if first >= 0xD800 && first <= 0xDBFF, index + 1 < units.count {
                let second = units[index + 1]
                if second >= 0xDC00 && second <= 0xDFFF {
                    return 0x10000 + ((UInt32(first - 0xD800) << 10) | UInt32(second - 0xDC00))
                }
            }
            return UInt32(first)
        }

        public func sliceUTF16(from start: Int, to end: Int) -> JSString {
            let units = utf16Units
            let s = max(0, min(start, units.count))
            let e = max(s, min(end, units.count))
            if s == e { return .empty }
            if s == 0 && e == units.count { return self }
            return JSString(utf16: units[s..<e])
        }

        /// Splits into ECMAScript StringIterator chunks: valid surrogate pairs stay together as a
        /// 2-code-unit string, while BMP characters and lone surrogates are 1-code-unit strings.
        public func codePointStrings() -> [JSString] {
            let units = utf16Units
            var out: [JSString] = []
            out.reserveCapacity(units.count)
            var i = 0
            while i < units.count {
                let u = units[i]
                if u >= 0xD800 && u <= 0xDBFF, i + 1 < units.count {
                    let lo = units[i + 1]
                    if lo >= 0xDC00 && lo <= 0xDFFF {
                        let cp = 0x10000 + ((UInt32(u - 0xD800) << 10) | UInt32(lo - 0xDC00))
                        out.append(JSString(codePoint: cp))
                        i += 2
                        continue
                    }
                }
                out.append(JSString(unit: u))
                i += 1
            }
            return out
        }

        // MARK: - Search & Split (UTF-16 Code Units)

        public func indexOf(_ needle: JSString, from position: Int = 0) -> Int {
            let hay = utf16Units
            let pat = needle.utf16Units
            let pos = max(0, min(hay.count, position))
            if pat.isEmpty { return pos }
            guard pos + pat.count <= hay.count else { return -1 }
            let last = hay.count - pat.count
            for i in pos...last {
                var ok = true
                for j in 0..<pat.count where hay[i + j] != pat[j] { ok = false; break }
                if ok { return i }
            }
            return -1
        }

        public func lastIndexOf(_ needle: JSString, from position: Int?) -> Int {
            let hay = utf16Units
            let pat = needle.utf16Units
            let maxPos = hay.count - pat.count
            guard maxPos >= 0 else { return -1 }
            let rawPos = position ?? maxPos
            let start = max(0, min(maxPos, rawPos))
            if pat.isEmpty { return max(0, min(hay.count, rawPos)) }
            for i in stride(from: start, through: 0, by: -1) {
                var ok = true
                for j in 0..<pat.count where hay[i + j] != pat[j] { ok = false; break }
                if ok { return i }
            }
            return -1
        }

        public func includes(_ needle: JSString, from position: Int = 0) -> Bool {
            let hay = utf16Units
            let pat = needle.utf16Units
            let pos = max(0, min(hay.count, position))
            if pat.isEmpty { return true }
            guard pos + pat.count <= hay.count else { return false }
            let last = hay.count - pat.count
            for i in pos...last {
                var ok = true
                for j in 0..<pat.count where hay[i + j] != pat[j] { ok = false; break }
                if ok { return true }
            }
            return false
        }

        public func startsWith(_ needle: JSString, from position: Int = 0) -> Bool {
            let hay = utf16Units
            let pat = needle.utf16Units
            let pos = max(0, min(hay.count, position))
            guard pos + pat.count <= hay.count else { return false }
            for j in 0..<pat.count where hay[pos + j] != pat[j] { return false }
            return true
        }

        public func endsWith(_ needle: JSString, endPosition: Int? = nil) -> Bool {
            let hay = utf16Units
            let pat = needle.utf16Units
            let end = endPosition.map { max(0, min(hay.count, $0)) } ?? hay.count
            let start = end - pat.count
            guard start >= 0 else { return false }
            for j in 0..<pat.count where hay[start + j] != pat[j] { return false }
            return true
        }

        public func split(separator: JSString, limit: Int) -> [JSString] {
            if limit <= 0 { return [] }
            let hay = utf16Units
            let sep = separator.utf16Units
            if sep.isEmpty {
                let count = min(hay.count, limit)
                var out: [JSString] = []
                out.reserveCapacity(count)
                for i in 0..<count {
                    out.append(JSString(unit: hay[i]))
                }
                return out
            }
            var out: [JSString] = []
            var start = 0
            var i = 0
            while i + sep.count <= hay.count {
                var match = true
                for j in 0..<sep.count where hay[i + j] != sep[j] { match = false; break }
                if match {
                    out.append(JSString(utf16: hay[start..<i]))
                    if out.count >= limit { return out }
                    i += sep.count
                    start = i
                } else {
                    i += 1
                }
            }
            if out.count < limit {
                out.append(JSString(utf16: hay[start..<hay.count]))
            }
            return out
        }

        // MARK: - Trimming (ECMA-262 WhiteSpace + LineTerminator)

        public static func isJSWhitespace(_ u: UInt16) -> Bool {
            switch u {
            case 0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x0020, 0x00A0,
                 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
                return true
            default:
                return false
            }
        }

        public func trimStart() -> JSString {
            let units = utf16Units
            var start = 0
            while start < units.count && Self.isJSWhitespace(units[start]) { start += 1 }
            if start == 0 { return self }
            return JSString(utf16: units[start..<units.count])
        }

        public func trimEnd() -> JSString {
            let units = utf16Units
            var end = units.count
            while end > 0 && Self.isJSWhitespace(units[end - 1]) { end -= 1 }
            if end == units.count { return self }
            return JSString(utf16: units[0..<end])
        }

        public func trim() -> JSString {
            let units = utf16Units
            var start = 0
            while start < units.count && Self.isJSWhitespace(units[start]) { start += 1 }
            var end = units.count
            while end > start && Self.isJSWhitespace(units[end - 1]) { end -= 1 }
            if start == 0 && end == units.count { return self }
            return JSString(utf16: units[start..<end])
        }

        // MARK: - Span-Preserving Transforms (normalize, case conversion)

        /// Applies `transform` to each maximal well-formed UTF-16 span while leaving lone surrogates
        /// untouched in place. Matches ECMA-262 `normalize`, `toLowerCase`, `toUpperCase`, etc.
        public func mapWellFormedSpans(_ transform: (String) -> String) -> JSString {
            switch storage {
            case .swift(let s):
                return JSString(transform(s))
            case .utf16(let units):
                var out: [UInt16] = []
                out.reserveCapacity(units.count)
                var spanStart = 0
                var i = 0
                let count = units.count
                while i < count {
                    let u = units[i]
                    if u >= 0xD800 && u <= 0xDBFF, i + 1 < count {
                        let lo = units[i + 1]
                        if lo >= 0xDC00 && lo <= 0xDFFF {
                            i += 2
                            continue
                        }
                    }
                    if u >= 0xD800 && u <= 0xDFFF {
                        if spanStart < i {
                            let span = String(decoding: units[spanStart..<i], as: UTF16.self)
                            out.append(contentsOf: transform(span).utf16)
                        }
                        out.append(u)
                        i += 1
                        spanStart = i
                    } else {
                        i += 1
                    }
                }
                if spanStart < count {
                    let span = String(decoding: units[spanStart..<count], as: UTF16.self)
                    out.append(contentsOf: transform(span).utf16)
                }
                return JSString(utf16: out)
            }
        }

        public func lowercased() -> JSString {
            mapWellFormedSpans { $0.lowercased() }
        }

        public func uppercased() -> JSString {
            mapWellFormedSpans { $0.uppercased() }
        }

        // MARK: - JSON Quoting (QuoteJSONString, ECMA-262 §25.5.2.2)

        /// Quotes this string as a JSON string literal, escaping control characters, quotes,
        /// backslashes, and unpaired UTF-16 surrogates as lowercase `\udxxx` (while leaving
        /// valid surrogate pairs intact as astral Unicode).
        public func jsonQuotedString() -> String {
            let units = utf16Units
            var out = "\""
            out.reserveCapacity(units.count + 2)
            var i = 0
            let count = units.count
            while i < count {
                let u = units[i]
                switch u {
                case 0x0022: out += "\\\""
                case 0x005C: out += "\\\\"
                case 0x0008: out += "\\b"
                case 0x000C: out += "\\f"
                case 0x000A: out += "\\n"
                case 0x000D: out += "\\r"
                case 0x0009: out += "\\t"
                case 0x0000..<0x0020:
                    out += Self.hexEscape4(u)
                case 0xD800...0xDBFF:
                    if i + 1 < count {
                        let lo = units[i + 1]
                        if lo >= 0xDC00 && lo <= 0xDFFF {
                            let cp = 0x10000 + ((UInt32(u - 0xD800) << 10) | UInt32(lo - 0xDC00))
                            out.unicodeScalars.append(Unicode.Scalar(cp)!)
                            i += 2
                            continue
                        }
                    }
                    out += Self.hexEscape4(u)
                case 0xDC00...0xDFFF:
                    out += Self.hexEscape4(u)
                default:
                    out.unicodeScalars.append(Unicode.Scalar(u)!)
                }
                i += 1
            }
            out.append("\"")
            return out
        }

        public func jsonQuoted() -> JSString {
            JSString(jsonQuotedString())
        }

        private static func hexEscape4(_ u: UInt16) -> String {
            let digits: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]
            return String([
                "\\", "u",
                digits[Int((u >> 12) & 0xF)],
                digits[Int((u >> 8) & 0xF)],
                digits[Int((u >> 4) & 0xF)],
                digits[Int(u & 0xF)],
            ])
        }

        // MARK: - Collation Proxy Helpers for localeCompare

        /// Replaces each unpaired surrogate with U+D7FF (the unassigned BMP slot immediately
        /// preceding surrogates in UCA implicit weight order), keeping valid surrogate pairs intact.
        internal func ucaPrimaryProxy() -> String {
            switch storage {
            case .swift(let s):
                return s
            case .utf16(let units):
                var scalars = String.UnicodeScalarView()
                scalars.reserveCapacity(units.count)
                var i = 0
                let count = units.count
                while i < count {
                    let u = units[i]
                    if u >= 0xD800 && u <= 0xDBFF, i + 1 < count {
                        let lo = units[i + 1]
                        if lo >= 0xDC00 && lo <= 0xDFFF {
                            let cp = 0x10000 + ((UInt32(u - 0xD800) << 10) | UInt32(lo - 0xDC00))
                            scalars.append(Unicode.Scalar(cp)!)
                            i += 2
                            continue
                        }
                    }
                    if u >= 0xD800 && u <= 0xDFFF {
                        scalars.append("\u{D7FF}")
                    } else if let sc = Unicode.Scalar(u) {
                        scalars.append(sc)
                    }
                    i += 1
                }
                return String(scalars)
            }
        }

        /// Ordered sequence of `0xD7FF` and unpaired surrogate code units (`0xD800...0xDFFF`),
        /// excluding valid surrogate pairs, used to break ties among UCA implicit weights in
        /// `0xD7FF...0xDFFF` without depending on OS-specific surrogate handling.
        internal func ucaSurrogateTieKey() -> [UInt16] {
            let units = utf16Units
            var key: [UInt16] = []
            var i = 0
            let count = units.count
            while i < count {
                let u = units[i]
                if u >= 0xD800 && u <= 0xDBFF, i + 1 < count {
                    let lo = units[i + 1]
                    if lo >= 0xDC00 && lo <= 0xDFFF {
                        i += 2
                        continue
                    }
                }
                if u >= 0xD7FF && u <= 0xDFFF {
                    key.append(u)
                }
                i += 1
            }
            return key
        }
    }
}

extension Array where Element == CodemodeLanguage.JSString {
    public func joinedJS(separator: CodemodeLanguage.JSString = .empty) -> CodemodeLanguage.JSString {
        CodemodeLanguage.JSString.joined(self, separator: separator)
    }
}
