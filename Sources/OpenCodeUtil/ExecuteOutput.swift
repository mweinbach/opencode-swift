/// Formatted Code Mode `execute` output split into indented JSON (when applicable),
/// trailing Warnings/Logs sections, and combined display text.
public struct ExecuteOutputResult: Equatable, Sendable, Codable {
    public let json: String?
    public let rest: String?
    public let text: String

    public init(json: String?, rest: String?, text: String) {
        self.json = json
        self.rest = rest
        self.text = text
    }
}

/// Formats Code Mode `execute` output for display, pretty-printing leading JSON payloads
/// while preserving optional `Warnings:` and `Logs:` sections.
// parity: util/src/execute-output.ts#formatExecuteOutput [status=implemented hash=01b59dec482e]
public func formatExecuteOutput(_ output: String) -> ExecuteOutputResult {
    let end = findSectionBoundary(in: output)
    let result: String
    let rest: String?
    if let end {
        result = String(output[..<end])
        rest = trimJSWhitespace(String(output[end...]))
    } else {
        result = output
        rest = nil
    }
    let json = indentedJson(result)
    let body = json ?? result
    let text = rest == nil ? body : "\(body)\n\n\(rest!)"
    return ExecuteOutputResult(json: json, rest: rest, text: text)
}

private func findSectionBoundary(in output: String) -> String.Index? {
    let w = findSubstring("\n\nWarnings:\n", in: output)
    let l = findSubstring("\n\nLogs:\n", in: output)
    switch (w, l) {
    case let (a?, b?): return a < b ? a : b
    case let (a?, nil): return a
    case let (nil, b?): return b
    case (nil, nil): return nil
    }
}

private func findSubstring(_ needle: String, in haystack: String) -> String.Index? {
    let h = Array(haystack.utf8)
    let n = Array(needle.utf8)
    guard !n.isEmpty, h.count >= n.count else { return nil }
    let limit = h.count - n.count
    var i = 0
    while i <= limit {
        var matched = true
        for j in 0..<n.count where h[i + j] != n[j] {
            matched = false
            break
        }
        if matched {
            return haystack.utf8.index(haystack.utf8.startIndex, offsetBy: i)
        }
        i += 1
    }
    return nil
}

private func isJSWhitespace(_ scalar: Unicode.Scalar) -> Bool {
    let v = scalar.value
    return v == 0x09 || v == 0x0A || v == 0x0B || v == 0x0C || v == 0x0D || v == 0x20
        || v == 0xA0 || v == 0x1680
        || (v >= 0x2000 && v <= 0x200A)
        || v == 0x2028 || v == 0x2029 || v == 0x202F || v == 0x205F || v == 0x3000 || v == 0xFEFF
}

private func trimJSWhitespace(_ text: String) -> String {
    let scalars = text.unicodeScalars
    var start = scalars.startIndex
    var end = scalars.endIndex
    while start < end && isJSWhitespace(scalars[start]) {
        start = scalars.index(after: start)
    }
    while end > start {
        let prev = scalars.index(before: end)
        if isJSWhitespace(scalars[prev]) {
            end = prev
        } else {
            break
        }
    }
    return String(scalars[start..<end])
}

private func indentedJson(_ text: String) -> String? {
    guard text.hasPrefix("{") || text.hasPrefix("[") else { return nil }
    guard let value = PureJSON.parse(text) else { return nil }
    return PureJSON.stringifyPretty(value, indent: 2)
}

// MARK: - Pure-Swift RFC 8259 JSON Parser & JS-Exact Pretty Printer

/// Ordered JSON AST that preserves JavaScript object property order (array-index keys ascending,
/// then string keys in insertion order) and formats identically to `JSON.stringify(value, null, 2)`.
public enum PureJSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([PureJSONValue])
    case object([(String, PureJSONValue)])

    public static func == (lhs: PureJSONValue, rhs: PureJSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.number(a), .number(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)):
            guard a.count == b.count else { return false }
            for i in 0..<a.count where a[i].0 != b[i].0 || a[i].1 != b[i].1 {
                return false
            }
            return true
        default: return false
        }
    }
}

public enum PureJSON {
    public static func parse(_ text: String) -> PureJSONValue? {
        var parser = Parser(bytes: Array(text.utf8))
        parser.skipWhitespace()
        guard let value = parser.parseValue() else { return nil }
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { return nil }
        return value
    }

    public static func stringifyPretty(_ value: PureJSONValue, indent: Int = 2) -> String {
        var out = ""
        writeValue(value, indent: indent, depth: 0, into: &out)
        return out
    }

    public static func stringifyCompact(_ value: PureJSONValue) -> String {
        var out = ""
        writeValue(value, indent: 0, depth: 0, into: &out)
        return out
    }

    private static func writeValue(_ value: PureJSONValue, indent: Int, depth: Int, into out: inout String) {
        switch value {
        case .null:
            out.append("null")
        case .bool(let b):
            out.append(b ? "true" : "false")
        case .number(let n):
            out.append(formatJSNumber(n))
        case .string(let s):
            writeJSONString(s, into: &out)
        case .array(let items):
            if items.isEmpty {
                out.append("[]")
                return
            }
            if indent <= 0 {
                out.append("[")
                for (idx, item) in items.enumerated() {
                    if idx > 0 { out.append(",") }
                    writeValue(item, indent: 0, depth: 0, into: &out)
                }
                out.append("]")
                return
            }
            out.append("[\n")
            let childPad = String(repeating: " ", count: (depth + 1) * indent)
            let closePad = String(repeating: " ", count: depth * indent)
            for (idx, item) in items.enumerated() {
                if idx > 0 { out.append(",\n") }
                out.append(childPad)
                writeValue(item, indent: indent, depth: depth + 1, into: &out)
            }
            out.append("\n")
            out.append(closePad)
            out.append("]")
        case .object(let rawEntries):
            if rawEntries.isEmpty {
                out.append("{}")
                return
            }
            let entries = orderedJSKeys(rawEntries)
            if indent <= 0 {
                out.append("{")
                for (idx, entry) in entries.enumerated() {
                    if idx > 0 { out.append(",") }
                    writeJSONString(entry.0, into: &out)
                    out.append(":")
                    writeValue(entry.1, indent: 0, depth: 0, into: &out)
                }
                out.append("}")
                return
            }
            out.append("{\n")
            let childPad = String(repeating: " ", count: (depth + 1) * indent)
            let closePad = String(repeating: " ", count: depth * indent)
            for (idx, entry) in entries.enumerated() {
                if idx > 0 { out.append(",\n") }
                out.append(childPad)
                writeJSONString(entry.0, into: &out)
                out.append(": ")
                writeValue(entry.1, indent: indent, depth: depth + 1, into: &out)
            }
            out.append("\n")
            out.append(closePad)
            out.append("}")
        }
    }

    /// JavaScript OwnPropertyKeys order: canonical array indices `0..<2^32-1` sorted numerically first,
    /// followed by all remaining string keys in insertion order.
    private static func orderedJSKeys(_ entries: [(String, PureJSONValue)]) -> [(String, PureJSONValue)] {
        var indexEntries: [(UInt32, String, PureJSONValue)] = []
        var stringEntries: [(String, PureJSONValue)] = []
        for (k, v) in entries {
            if let idx = parseArrayIndex(k) {
                indexEntries.append((idx, k, v))
            } else {
                stringEntries.append((k, v))
            }
        }
        if indexEntries.isEmpty { return stringEntries }
        indexEntries.sort { $0.0 < $1.0 }
        var result: [(String, PureJSONValue)] = []
        result.reserveCapacity(entries.count)
        for (_, k, v) in indexEntries {
            result.append((k, v))
        }
        result.append(contentsOf: stringEntries)
        return result
    }

    private static func parseArrayIndex(_ key: String) -> UInt32? {
        guard !key.isEmpty else { return nil }
        if key == "0" { return 0 }
        let bytes = Array(key.utf8)
        if bytes[0] == UInt8(ascii: "0") { return nil }
        var acc: UInt64 = 0
        for b in bytes {
            guard b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") else { return nil }
            acc = acc * 10 + UInt64(b - UInt8(ascii: "0"))
            if acc >= UInt64(UInt32.max) { return nil }
        }
        return UInt32(acc)
    }

    private static func formatJSNumber(_ n: Double) -> String {
        if !n.isFinite { return "null" }
        if n == 0 { return "0" }
        let sign = n < 0 ? "-" : ""
        let absVal = abs(n)

        // Parse Swift's exact shortest-roundtrip decimal representation into (digits, decimalExp)
        // where absVal == Int(digits) * 10^(decimalPos - digits.count), then apply ECMA-262 Number::toString.
        let raw = String(absVal)
        let mantissaPart: Substring
        let explicitExp: Int
        if let eIdx = raw.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissaPart = raw[..<eIdx]
            explicitExp = Int(raw[raw.index(after: eIdx)...]) ?? 0
        } else {
            mantissaPart = raw[...]
            explicitExp = 0
        }

        var rawDigits: [Character] = []
        var dotPos: Int? = nil
        for ch in mantissaPart {
            if ch == "." {
                dotPos = rawDigits.count
            } else {
                rawDigits.append(ch)
            }
        }
        var decimalPos = (dotPos ?? rawDigits.count) + explicitExp

        // Strip leading zeros (adjusting decimalPos) and trailing zeros.
        var start = 0
        while start < rawDigits.count && rawDigits[start] == "0" {
            start += 1
            decimalPos -= 1
        }
        var end = rawDigits.count
        while end > start && rawDigits[end - 1] == "0" {
            end -= 1
        }
        guard start < end else { return "0" }

        let digits = String(rawDigits[start..<end])
        let k = digits.count
        let pos = decimalPos

        if k <= pos && pos <= 21 {
            return sign + digits + String(repeating: "0", count: pos - k)
        }
        if 0 < pos && pos <= 21 {
            let split = digits.index(digits.startIndex, offsetBy: pos)
            return sign + String(digits[..<split]) + "." + String(digits[split...])
        }
        if -6 < pos && pos <= 0 {
            return sign + "0." + String(repeating: "0", count: -pos) + digits
        }
        let exp = pos - 1
        let expSign = exp >= 0 ? "+" : "-"
        let expStr = "\(expSign)\(abs(exp))"
        if k == 1 {
            return sign + digits + "e" + expStr
        }
        let afterFirst = digits.index(after: digits.startIndex)
        return sign + String(digits[..<afterFirst]) + "." + String(digits[afterFirst...]) + "e" + expStr
    }

    private static func writeJSONString(_ s: String, into out: inout String) {
        out.append("\"")
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x22: out.append("\\\"")
            case 0x5C: out.append("\\\\")
            case 0x08: out.append("\\b")
            case 0x0C: out.append("\\f")
            case 0x0A: out.append("\\n")
            case 0x0D: out.append("\\r")
            case 0x09: out.append("\\t")
            case 0x00..<0x20:
                out.append("\\u")
                out.append(hex4(UInt16(scalar.value)))
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out.append("\"")
    }

    private static func hex4(_ value: UInt16) -> String {
        let digits: [UInt8] = Array("0123456789abcdef".utf8)
        let bytes: [UInt8] = [
            digits[Int((value >> 12) & 0xF)],
            digits[Int((value >> 8) & 0xF)],
            digits[Int((value >> 4) & 0xF)],
            digits[Int(value & 0xF)],
        ]
        return String(decoding: bytes, as: UTF8.self)
    }

    private struct Parser {
        let bytes: [UInt8]
        var index: Int = 0

        mutating func skipWhitespace() {
            while index < bytes.count {
                switch bytes[index] {
                case 0x20, 0x09, 0x0A, 0x0D:
                    index += 1
                default:
                    return
                }
            }
        }

        mutating func parseValue() -> PureJSONValue? {
            skipWhitespace()
            guard index < bytes.count else { return nil }
            switch bytes[index] {
            case 0x7B: return parseObject() // '{'
            case 0x5B: return parseArray()  // '['
            case 0x22: return parseString().map { .string($0) } // '"'
            case 0x74: return consumeLiteral("true") ? .bool(true) : nil
            case 0x66: return consumeLiteral("false") ? .bool(false) : nil
            case 0x6E: return consumeLiteral("null") ? .null : nil
            case 0x2D, 0x30...0x39: return parseNumber()
            default: return nil
            }
        }

        private mutating func consumeLiteral(_ lit: String) -> Bool {
            let expected = Array(lit.utf8)
            guard index + expected.count <= bytes.count else { return false }
            for i in 0..<expected.count where bytes[index + i] != expected[i] {
                return false
            }
            index += expected.count
            return true
        }

        private mutating func parseArray() -> PureJSONValue? {
            index += 1 // skip '['
            skipWhitespace()
            var items: [PureJSONValue] = []
            if index < bytes.count && bytes[index] == 0x5D { // ']'
                index += 1
                return .array(items)
            }
            while true {
                guard let val = parseValue() else { return nil }
                items.append(val)
                skipWhitespace()
                guard index < bytes.count else { return nil }
                if bytes[index] == 0x5D {
                    index += 1
                    return .array(items)
                }
                guard bytes[index] == 0x2C else { return nil } // ','
                index += 1
            }
        }

        private mutating func parseObject() -> PureJSONValue? {
            index += 1 // skip '{'
            skipWhitespace()
            var entries: [(String, PureJSONValue)] = []
            var positions: [String: Int] = [:]
            if index < bytes.count && bytes[index] == 0x7D { // '}'
                index += 1
                return .object(entries)
            }
            while true {
                skipWhitespace()
                guard index < bytes.count && bytes[index] == 0x22, let key = parseString() else { return nil }
                skipWhitespace()
                guard index < bytes.count && bytes[index] == 0x3A else { return nil } // ':'
                index += 1
                guard let val = parseValue() else { return nil }
                if let existing = positions[key] {
                    entries[existing] = (key, val)
                } else {
                    positions[key] = entries.count
                    entries.append((key, val))
                }
                skipWhitespace()
                guard index < bytes.count else { return nil }
                if bytes[index] == 0x7D {
                    index += 1
                    return .object(entries)
                }
                guard bytes[index] == 0x2C else { return nil }
                index += 1
            }
        }

        private mutating func parseString() -> String? {
            index += 1 // skip opening '"'
            var scalars: [Unicode.Scalar] = []
            while index < bytes.count {
                let b = bytes[index]
                if b == 0x22 { // '"'
                    index += 1
                    var result = ""
                    result.unicodeScalars.append(contentsOf: scalars)
                    return result
                }
                if b < 0x20 { return nil }
                if b == 0x5C { // '\'
                    index += 1
                    guard index < bytes.count else { return nil }
                    let esc = bytes[index]
                    index += 1
                    switch esc {
                    case 0x22: scalars.append("\"")
                    case 0x5C: scalars.append("\\")
                    case 0x2F: scalars.append("/")
                    case 0x62: scalars.append("\u{08}")
                    case 0x66: scalars.append("\u{0C}")
                    case 0x6E: scalars.append("\n")
                    case 0x72: scalars.append("\r")
                    case 0x74: scalars.append("\t")
                    case 0x75:
                        guard let u1 = parseHex4() else { return nil }
                        if u1 >= 0xD800 && u1 <= 0xDBFF {
                            if index + 6 <= bytes.count && bytes[index] == 0x5C && bytes[index + 1] == 0x75 {
                                let saved = index
                                index += 2
                                if let u2 = parseHex4(), u2 >= 0xDC00 && u2 <= 0xDFFF {
                                    let combined = 0x10000 + ((UInt32(u1 - 0xD800) << 10) | UInt32(u2 - 0xDC00))
                                    if let sc = Unicode.Scalar(combined) {
                                        scalars.append(sc)
                                        continue
                                    }
                                }
                                index = saved
                            }
                            return nil
                        }
                        guard let sc = Unicode.Scalar(u1) else { return nil }
                        scalars.append(sc)
                    default:
                        return nil
                    }
                } else if b < 0x80 {
                    scalars.append(Unicode.Scalar(b))
                    index += 1
                } else {
                    // Decode UTF-8 multi-byte scalar
                    let start = index
                    let expectedLen: Int
                    if b & 0xE0 == 0xC0 { expectedLen = 2 }
                    else if b & 0xF0 == 0xE0 { expectedLen = 3 }
                    else if b & 0xF8 == 0xF0 { expectedLen = 4 }
                    else { return nil }
                    guard start + expectedLen <= bytes.count else { return nil }
                    let slice = bytes[start..<(start + expectedLen)]
                    guard let decoded = String(bytes: slice, encoding: nil) else { return nil }
                    scalars.append(contentsOf: decoded.unicodeScalars)
                    index += expectedLen
                }
            }
            return nil
        }

        private mutating func parseHex4() -> UInt16? {
            guard index + 4 <= bytes.count else { return nil }
            var val: UInt16 = 0
            for _ in 0..<4 {
                let b = bytes[index]
                index += 1
                let digit: UInt16
                if b >= 0x30 && b <= 0x39 { digit = UInt16(b - 0x30) }
                else if b >= 0x41 && b <= 0x46 { digit = UInt16(b - 0x41 + 10) }
                else if b >= 0x61 && b <= 0x66 { digit = UInt16(b - 0x61 + 10) }
                else { return nil }
                val = (val << 4) | digit
            }
            return val
        }

        private mutating func parseNumber() -> PureJSONValue? {
            let start = index
            if bytes[index] == 0x2D { // '-'
                index += 1
                guard index < bytes.count else { return nil }
            }
            if bytes[index] == 0x30 { // '0'
                index += 1
            } else if bytes[index] >= 0x31 && bytes[index] <= 0x39 {
                index += 1
                while index < bytes.count && bytes[index] >= 0x30 && bytes[index] <= 0x39 {
                    index += 1
                }
            } else {
                return nil
            }
            if index < bytes.count && bytes[index] == 0x2E { // '.'
                index += 1
                guard index < bytes.count && bytes[index] >= 0x30 && bytes[index] <= 0x39 else { return nil }
                while index < bytes.count && bytes[index] >= 0x30 && bytes[index] <= 0x39 {
                    index += 1
                }
            }
            if index < bytes.count && (bytes[index] == 0x65 || bytes[index] == 0x45) { // 'e'/'E'
                index += 1
                if index < bytes.count && (bytes[index] == 0x2B || bytes[index] == 0x2D) {
                    index += 1
                }
                guard index < bytes.count && bytes[index] >= 0x30 && bytes[index] <= 0x39 else { return nil }
                while index < bytes.count && bytes[index] >= 0x30 && bytes[index] <= 0x39 {
                    index += 1
                }
            }
            let raw = String(decoding: bytes[start..<index], as: UTF8.self)
            guard let num = Double(raw), num.isFinite else { return nil }
            return .number(num)
        }
    }
}

private extension String {
    init?(bytes: ArraySlice<UInt8>, encoding: Void?) {
        var iter = bytes.makeIterator()
        var codec = UTF8()
        var out = ""
        while true {
            switch codec.decode(&iter) {
            case .scalarValue(let sc):
                out.unicodeScalars.append(sc)
            case .emptyInput:
                self = out
                return
            case .error:
                return nil
            }
        }
    }
}
