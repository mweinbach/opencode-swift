import Foundation
import OpenCodeUtil

// JSON.stringify / JSON.parse as upstream psychoscript runs them (`src/stdlib/json.ts`, the `$vmJsonVisitor` /
// `$vmJsonWalk` walk and `revive` in `src/prelude`): the walk reads each value as program code (getters, `toJSON`,
// the replacer), so it runs here on the evaluator rather than as a synchronous native.
extension CodemodeLanguage {
    /// Internal JSON AST that preserves faithful UTF-16 `JSString` values and object keys
    /// (including unpaired surrogates) end-to-end through `JSON.parse` and `JSON.stringify`.
    private enum CodemodeJSONValue: Sendable {
        case null
        case bool(Bool)
        case number(Double)
        case string(JSString)
        case array([CodemodeJSONValue])
        case object([(JSString, CodemodeJSONValue)])
    }

    // Upstream: psychoscript/src/stdlib/json.ts#stringify (implemented).
    static func jsonStringify(_ args: [Value], builtins: Builtins, eval: Evaluator) async throws -> Value {
        let value = args.first ?? .undefined
        let replacerArg = args.count > 1 ? args[1] : .undefined
        let space = args.count > 2 ? args[2] : .undefined
        var properties: [JSString]? = nil
        if case .object(let arr as Arr) = replacerArg {
            var seen = Set<JSString>()
            properties = []
            for item in arr.items {
                let name: JSString
                switch item {
                case .string(let s): name = s
                case .number(let n): name = JSString(formatJSNumber(n))
                default: continue
                }
                if seen.insert(name).inserted { properties!.append(name) }
            }
        }
        let replacer: Callable? = isCallableValue(replacerArg) ? (try requireCallback(replacerArg, "JSON.stringify")) : nil
        var gap: JSString = .empty
        switch space {
        case .number(let n):
            let count = max(0, min(10, n.isFinite ? Int(n.rounded(.towardZero)) : (n > 0 ? 10 : 0)))
            gap = JSString(String(repeating: " ", count: count))
        case .string(let s):
            gap = s.sliceUTF16(from: 0, to: 10)
        default:
            break
        }
        let holder = Obj(proto: builtins.Object)
        define(holder, "", value)
        var ancestors: [ObjectIdentifier] = []
        guard let json = try await jsonVisit(holder, key: "", depth: 0, replacer: replacer, properties: properties, ancestors: &ancestors, builtins: builtins, eval: eval) else {
            return .undefined
        }
        let text = jsonSerialize(json, gap: gap, indent: .empty)
        try checkStringLength(text.utf16Count)
        return .string(text)
    }

    /// One value of the walk, holder[key]: its JSON, or nil when it is left out.
    private static func jsonVisit(
        _ holder: Obj,
        key: JSString,
        depth: Int,
        replacer: Callable?,
        properties: [JSString]?,
        ancestors: inout [ObjectIdentifier],
        builtins: Builtins,
        eval: Evaluator
    ) async throws -> CodemodeJSONValue? {
        if depth > 100 { throw rangeError("Value exceeds the maximum depth of 100.") }
        var val = try await eval.getValue(holder, .string(key), receiver: .object(holder))
        if case .object(let p) = val, p is PromiseObj {
            throw invalidData("JSON.stringify received an un-awaited Promise; await it first - e.g. `const result = await load(...)`.")
        }
        if case .object(let obj) = val {
            let toJSON = try await eval.getValue(obj, .string("toJSON"), receiver: val)
            if isCallableValue(toJSON) {
                val = try await eval.callCallable(toJSON, thisValue: val, args: [.string(key)], site: nil)
            }
        }
        if let replacer {
            val = try await eval.callCallable(.object(replacer), thisValue: .object(holder), args: [.string(key), val], site: nil)
        }
        switch val {
        case .undefined, .symbol: return nil
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .number(let n): return n.isFinite ? .number(n) : .null
        case .string(let s): return .string(s)
        case .hostNamespace: return .object([])
        case .object(let obj):
            if obj is Callable { return nil }
            if let headers = obj as? HeadersObj {
                return .object(headers.sortedEntries().map { (JSString($0.0), .string(JSString($0.1))) })
            }
            let oid = ObjectIdentifier(obj)
            if ancestors.contains(oid) { throw typeError("Converting circular structure to JSON.") }
            ancestors.append(oid)
            defer { ancestors.removeLast() }
            if let arr = obj as? Arr {
                var out: [CodemodeJSONValue] = []
                let count = arr.count
                out.reserveCapacity(count)
                for i in 0..<count {
                    let elem = try await jsonVisit(arr, key: JSString(String(i)), depth: depth + 1, replacer: replacer, properties: properties, ancestors: &ancestors, builtins: builtins, eval: eval)
                    out.append(elem ?? .null)
                }
                return .array(out)
            }
            let isError = obj is ErrorObj
            var names = keys(obj).filter { !(isError && ($0 == "name" || $0 == "message")) }
            if let properties { names = names.filter { properties.contains($0) } }
            if isError {
                let leading: [JSString] = [JSString("name"), JSString("message")].filter { properties == nil || properties!.contains($0) }
                names = leading + names
            }
            var out: [(JSString, CodemodeJSONValue)] = []
            for name in names {
                if let item = try await jsonVisit(obj, key: name, depth: depth + 1, replacer: replacer, properties: properties, ancestors: &ancestors, builtins: builtins, eval: eval) {
                    out.append((name, item))
                }
            }
            if let properties {
                // The host's own JSON.stringify writes the keys in the replacer array's order.
                out.sort { (properties.firstIndex(of: $0.0) ?? 0) < (properties.firstIndex(of: $1.0) ?? 0) }
            }
            return .object(out)
        }
    }

    /// JSON text as `JSON.stringify(value, null, gap)` writes it. Preserves lone surrogates in `gap` verbatim
    /// while escaping lone surrogates in string values and object keys via `jsonQuote`.
    private static func jsonSerialize(_ value: CodemodeJSONValue, gap: JSString, indent: JSString) -> JSString {
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return JSString(formatJSNumber(n))
        case .string(let s): return s.jsonQuoted()
        case .array(let items):
            if items.isEmpty { return "[]" }
            if gap.isEmpty {
                return "[" + items.map { jsonSerialize($0, gap: gap, indent: indent) }.joinedJS(separator: ",") + "]"
            }
            let inner = indent + gap
            return "[\n" + items.map { inner + jsonSerialize($0, gap: gap, indent: inner) }.joinedJS(separator: ",\n") + "\n" + indent + "]"
        case .object(let pairs):
            if pairs.isEmpty { return "{}" }
            if gap.isEmpty {
                return "{" + pairs.map { $0.0.jsonQuoted() + ":" + jsonSerialize($0.1, gap: gap, indent: indent) }.joinedJS(separator: ",") + "}"
            }
            let inner = indent + gap
            return "{\n" + pairs.map { inner + $0.0.jsonQuoted() + ": " + jsonSerialize($0.1, gap: gap, indent: inner) }.joinedJS(separator: ",\n") + "\n" + indent + "}"
        }
    }

    /// QuoteJSONString (ECMA-262 §25.5.2.2) — escapes lone UTF-16 surrogates as lowercase `\udxxx`.
    static func jsonQuote(_ s: JSString) -> String {
        s.jsonQuotedString()
    }

    static func jsonQuote(_ s: String) -> String {
        JSString(s).jsonQuotedString()
    }

    // Upstream: psychoscript/src/stdlib/json.ts#parse (implemented).
    static func jsonParse(_ args: [Value], builtins: Builtins, eval: Evaluator) async throws -> Value {
        let text = coerceToString(args.first ?? .undefined)
        guard let parsed = parseJSONUTF16(text) else {
            // Upstream appends the host engine's own message (JavaScriptCore's under Bun).
            throw syntaxError("JSON.parse received invalid JSON: JSON Parse error: Unexpected token")
        }
        let value = jsonToProgramValue(parsed, builtins: builtins)
        let reviverArg = args.count > 1 ? args[1] : .undefined
        guard isCallableValue(reviverArg) else { return value }
        let reviver = try requireCallback(reviverArg, "JSON.parse")
        let holder = Obj(proto: builtins.Object)
        define(holder, "", value)
        return try await jsonRevive(holder, key: "", reviver: reviver, eval: eval)
    }

    /// JSON as program data, with object keys in their text order and `__proto__` an ordinary key.
    private static func jsonToProgramValue(_ value: CodemodeJSONValue, builtins: Builtins) -> Value {
        switch value {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .number(let n): return .number(n)
        case .string(let s): return .string(s)
        case .array(let items): return .object(Arr(proto: builtins.Array, items: items.map { jsonToProgramValue($0, builtins: builtins) }))
        case .object(let pairs):
            let obj = Obj(proto: builtins.Object)
            for (k, v) in pairs { define(obj, k, jsonToProgramValue(v, builtins: builtins)) }
            return .object(obj)
        }
    }

    /// The reviver walk: children first, each replaced (or removed when the reviver gives undefined); then the value.
    private static func jsonRevive(_ holder: Obj, key: JSString, reviver: Callable, eval: Evaluator) async throws -> Value {
        let value = try await eval.getValue(holder, .string(key), receiver: .object(holder))
        if case .object(let obj) = value {
            for name in keys(obj) {
                let revived = try await jsonRevive(obj, key: name, reviver: reviver, eval: eval)
                if revived.isUndefined {
                    _ = remove(obj, .string(name))
                } else {
                    try await eval.writeMember(value, .string(name), revived)
                }
            }
        }
        return try await eval.callCallable(.object(reviver), thisValue: .object(holder), args: [.string(key), value], site: nil)
    }

    // MARK: - Faithful UTF-16 JSON Parser (ECMA-262 JSON.parse)

    private struct UTF16JSONParser {
        let units: [UInt16]
        var index: Int = 0

        mutating func parseDocument() -> CodemodeJSONValue? {
            skipWhitespace()
            guard let val = parseValue(depth: 0) else { return nil }
            skipWhitespace()
            return index == units.count ? val : nil
        }

        private mutating func skipWhitespace() {
            while index < units.count {
                switch units[index] {
                case 0x20, 0x09, 0x0A, 0x0D:
                    index += 1
                default:
                    return
                }
            }
        }

        private mutating func parseValue(depth: Int) -> CodemodeJSONValue? {
            guard depth <= 512, index < units.count else { return nil }
            switch units[index] {
            case 0x7B: return parseObject(depth: depth + 1) // {
            case 0x5B: return parseArray(depth: depth + 1)  // [
            case 0x22: return parseString().map { .string($0) } // "
            case 0x74: return consumeLiteral([0x74, 0x72, 0x75, 0x65]) ? .bool(true) : nil // true
            case 0x66: return consumeLiteral([0x66, 0x61, 0x6C, 0x73, 0x65]) ? .bool(false) : nil // false
            case 0x6E: return consumeLiteral([0x6E, 0x75, 0x6C, 0x6C]) ? .null : nil // null
            case 0x2D, 0x30...0x39: return parseNumber().map { .number($0) }
            default: return nil
            }
        }

        private mutating func consumeLiteral(_ expected: [UInt16]) -> Bool {
            guard index + expected.count <= units.count else { return false }
            for i in 0..<expected.count where units[index + i] != expected[i] { return false }
            index += expected.count
            return true
        }

        private mutating func parseString() -> JSString? {
            guard index < units.count, units[index] == 0x22 else { return nil }
            index += 1
            var out: [UInt16] = []
            while index < units.count {
                let u = units[index]
                index += 1
                if u == 0x22 { // "
                    return JSString(utf16: out)
                }
                if u < 0x20 { return nil } // Unescaped control characters are invalid in JSON.
                if u == 0x5C { // \
                    guard index < units.count else { return nil }
                    let esc = units[index]
                    index += 1
                    switch esc {
                    case 0x22: out.append(0x22)
                    case 0x5C: out.append(0x5C)
                    case 0x2F: out.append(0x2F)
                    case 0x62: out.append(0x08)
                    case 0x66: out.append(0x0C)
                    case 0x6E: out.append(0x0A)
                    case 0x72: out.append(0x0D)
                    case 0x74: out.append(0x09)
                    case 0x75: // \uXXXX — emit the raw UTF-16 code unit; JSString re-pairs valid pairs and keeps lone surrogates.
                        guard index + 4 <= units.count else { return nil }
                        var val: UInt16 = 0
                        for _ in 0..<4 {
                            guard let d = hexDigit(units[index]) else { return nil }
                            val = (val << 4) | d
                            index += 1
                        }
                        out.append(val)
                    default:
                        return nil
                    }
                } else {
                    out.append(u)
                }
            }
            return nil
        }

        private func hexDigit(_ u: UInt16) -> UInt16? {
            switch u {
            case 0x30...0x39: return u - 0x30
            case 0x41...0x46: return u - 0x41 + 10
            case 0x61...0x66: return u - 0x61 + 10
            default: return nil
            }
        }

        private mutating func parseNumber() -> Double? {
            let start = index
            if index < units.count && units[index] == 0x2D { index += 1 } // -
            guard index < units.count else { return nil }
            if units[index] == 0x30 {
                index += 1
            } else if units[index] >= 0x31 && units[index] <= 0x39 {
                index += 1
                while index < units.count && units[index] >= 0x30 && units[index] <= 0x39 { index += 1 }
            } else {
                return nil
            }
            if index < units.count && units[index] == 0x2E { // .
                index += 1
                guard index < units.count && units[index] >= 0x30 && units[index] <= 0x39 else { return nil }
                while index < units.count && units[index] >= 0x30 && units[index] <= 0x39 { index += 1 }
            }
            if index < units.count && (units[index] == 0x65 || units[index] == 0x45) { // e / E
                index += 1
                if index < units.count && (units[index] == 0x2B || units[index] == 0x2D) { index += 1 }
                guard index < units.count && units[index] >= 0x30 && units[index] <= 0x39 else { return nil }
                while index < units.count && units[index] >= 0x30 && units[index] <= 0x39 { index += 1 }
            }
            let ascii = String(decoding: units[start..<index].map { UInt8($0) }, as: UTF8.self)
            return Double(ascii)
        }

        private mutating func parseArray(depth: Int) -> CodemodeJSONValue? {
            index += 1 // [
            skipWhitespace()
            if index < units.count && units[index] == 0x5D {
                index += 1
                return .array([])
            }
            var items: [CodemodeJSONValue] = []
            while true {
                skipWhitespace()
                guard let elem = parseValue(depth: depth) else { return nil }
                items.append(elem)
                skipWhitespace()
                guard index < units.count else { return nil }
                if units[index] == 0x5D { // ]
                    index += 1
                    return .array(items)
                }
                guard units[index] == 0x2C else { return nil } // ,
                index += 1
            }
        }

        private mutating func parseObject(depth: Int) -> CodemodeJSONValue? {
            index += 1 // {
            skipWhitespace()
            if index < units.count && units[index] == 0x7D {
                index += 1
                return .object([])
            }
            var pairs: [(JSString, CodemodeJSONValue)] = []
            while true {
                skipWhitespace()
                guard let key = parseString() else { return nil }
                skipWhitespace()
                guard index < units.count && units[index] == 0x3A else { return nil } // :
                index += 1
                skipWhitespace()
                guard let val = parseValue(depth: depth) else { return nil }
                pairs.append((key, val))
                skipWhitespace()
                guard index < units.count else { return nil }
                if units[index] == 0x7D { // }
                    index += 1
                    return .object(pairs)
                }
                guard units[index] == 0x2C else { return nil } // ,
                index += 1
            }
        }
    }

    private static func parseJSONUTF16(_ text: JSString) -> CodemodeJSONValue? {
        var parser = UTF16JSONParser(units: text.utf16Units)
        return parser.parseDocument()
    }
}

extension CodemodeLanguage {
    /// String.prototype.replace / replaceAll with a string pattern, over UTF-16 code units: the replacement is a
    /// callback `(matched, position, string)` or a template expanded by GetSubstitution.
    static func stringReplace(_ input: JSString, needle: JSString, replacement: Value, all: Bool, eval: Evaluator) async throws -> JSString {
        let hay = input.utf16Units
        let pat = needle.utf16Units
        var positions: [Int] = []
        var from = 0
        while from <= hay.count - pat.count {
            var found: Int? = nil
            var i = from
            while i + pat.count <= hay.count {
                if pat.isEmpty || Array(hay[i..<(i + pat.count)]) == pat { found = i; break }
                i += 1
            }
            guard let at = found else { break }
            positions.append(at)
            if !all { break }
            from = at + max(pat.count, 1)
            if pat.isEmpty && from > hay.count { break }
        }
        if positions.isEmpty { return input }
        var out: [UInt16] = []
        var cursor = 0
        for at in positions {
            out += hay[cursor..<at]
            let sub: JSString
            if case .object(let fn as Callable) = replacement {
                sub = coerceToString(try await eval.callCallable(.object(fn), thisValue: .undefined, args: [.string(needle), .number(Double(at)), .string(input)], site: nil))
            } else {
                sub = expandReplacement(coerceToString(replacement), matched: needle, position: at, input: input, captures: [], groups: .undefined)
            }
            out += sub.utf16Units
            cursor = at + pat.count
        }
        out += hay[min(cursor, hay.count)...]
        return JSString(utf16: out)
    }
}

extension CodemodeLanguage {
    /// EscapeRegExpPattern: `(?:)` for the empty pattern; `/` outside a class and line terminators escaped, so the
    /// source reads back as a regular expression literal.
    static func escapeRegExpPattern(_ pattern: JSString) -> JSString {
        JSString(utf16: ECMAScriptRegExp.escapePattern(pattern.utf16Units))
    }
}
