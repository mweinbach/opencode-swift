import Foundation
import OpenCodeUtil

// JSON.stringify / JSON.parse as upstream psychoscript runs them (`src/stdlib/json.ts`, the `$vmJsonVisitor` /
// `$vmJsonWalk` walk and `revive` in `src/prelude`): the walk reads each value as program code (getters, `toJSON`,
// the replacer), so it runs here on the evaluator rather than as a synchronous native.
extension CodemodeLanguage {
    // Upstream: psychoscript/src/stdlib/json.ts#stringify (implemented).
    static func jsonStringify(_ args: [Value], builtins: Builtins, eval: Evaluator) async throws -> Value {
        let value = args.first ?? .undefined
        let replacerArg = args.count > 1 ? args[1] : .undefined
        let space = args.count > 2 ? args[2] : .undefined
        var properties: [String]? = nil
        if case .object(let arr as Arr) = replacerArg {
            var seen = Set<String>()
            properties = []
            for item in arr.items {
                let name: String
                switch item {
                case .string(let s): name = s
                case .number(let n): name = formatJSNumber(n)
                default: continue
                }
                if seen.insert(name).inserted { properties!.append(name) }
            }
        }
        let replacer: Callable? = isCallableValue(replacerArg) ? (try requireCallback(replacerArg, "JSON.stringify")) : nil
        var gap = ""
        switch space {
        case .number(let n):
            let count = max(0, min(10, n.isFinite ? Int(n.rounded(.towardZero)) : (n > 0 ? 10 : 0)))
            gap = String(repeating: " ", count: count)
        case .string(let s):
            gap = String(decoding: Array(s.utf16.prefix(10)), as: UTF16.self)
        default:
            break
        }
        let holder = Obj(proto: builtins.Object)
        define(holder, "", value)
        var ancestors: [ObjectIdentifier] = []
        guard let json = try await jsonVisit(holder, key: "", depth: 0, replacer: replacer, properties: properties, ancestors: &ancestors, builtins: builtins, eval: eval) else {
            return .undefined
        }
        let text = jsonSerialize(json, gap: gap, indent: "")
        try checkStringLength(text.utf16.count)
        return .string(text)
    }

    /// One value of the walk, holder[key]: its JSON, or nil when it is left out.
    private static func jsonVisit(
        _ holder: Obj,
        key: String,
        depth: Int,
        replacer: Callable?,
        properties: [String]?,
        ancestors: inout [ObjectIdentifier],
        builtins: Builtins,
        eval: Evaluator
    ) async throws -> PureJSONValue? {
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
                return .object(headers.sortedEntries().map { ($0.0, .string($0.1)) })
            }
            let oid = ObjectIdentifier(obj)
            if ancestors.contains(oid) { throw typeError("Converting circular structure to JSON.") }
            ancestors.append(oid)
            defer { ancestors.removeLast() }
            if let arr = obj as? Arr {
                var out: [PureJSONValue] = []
                let count = arr.count
                out.reserveCapacity(count)
                for i in 0..<count {
                    let elem = try await jsonVisit(arr, key: String(i), depth: depth + 1, replacer: replacer, properties: properties, ancestors: &ancestors, builtins: builtins, eval: eval)
                    out.append(elem ?? .null)
                }
                return .array(out)
            }
            let isError = obj is ErrorObj
            var names = keys(obj).filter { !(isError && ($0 == "name" || $0 == "message")) }
            if let properties { names = names.filter { properties.contains($0) } }
            if isError {
                let leading = ["name", "message"].filter { properties == nil || properties!.contains($0) }
                names = leading + names
            }
            var out: [(String, PureJSONValue)] = []
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

    /// JSON text as `JSON.stringify(value, null, gap)` writes it.
    static func jsonSerialize(_ value: PureJSONValue, gap: String, indent: String) -> String {
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return formatJSNumber(n)
        case .string(let s): return jsonQuote(s)
        case .array(let items):
            if items.isEmpty { return "[]" }
            if gap.isEmpty { return "[" + items.map { jsonSerialize($0, gap: gap, indent: indent) }.joined(separator: ",") + "]" }
            let inner = indent + gap
            return "[\n" + items.map { inner + jsonSerialize($0, gap: gap, indent: inner) }.joined(separator: ",\n") + "\n" + indent + "]"
        case .object(let pairs):
            if pairs.isEmpty { return "{}" }
            if gap.isEmpty {
                return "{" + pairs.map { jsonQuote($0.0) + ":" + jsonSerialize($0.1, gap: gap, indent: indent) }.joined(separator: ",") + "}"
            }
            let inner = indent + gap
            return "{\n" + pairs.map { inner + jsonQuote($0.0) + ": " + jsonSerialize($0.1, gap: gap, indent: inner) }.joined(separator: ",\n") + "\n" + indent + "}"
        }
    }

    /// QuoteJSONString.
    static func jsonQuote(_ s: String) -> String {
        var out = "\""
        for unit in s.unicodeScalars {
            switch unit {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if unit.value < 0x20 {
                    out += String(format: "\\u%04x", unit.value)
                } else {
                    out.unicodeScalars.append(unit)
                }
            }
        }
        return out + "\""
    }

    // Upstream: psychoscript/src/stdlib/json.ts#parse (implemented).
    static func jsonParse(_ args: [Value], builtins: Builtins, eval: Evaluator) async throws -> Value {
        let text = coerceToString(args.first ?? .undefined)
        guard let parsed = PureJSON.parse(text) else {
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
    static func jsonToProgramValue(_ value: PureJSONValue, builtins: Builtins) -> Value {
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
    private static func jsonRevive(_ holder: Obj, key: String, reviver: Callable, eval: Evaluator) async throws -> Value {
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
}

extension CodemodeLanguage {
    /// String.prototype.replace / replaceAll with a string pattern, over UTF-16 code units: the replacement is a
    /// callback `(matched, position, string)` or a template expanded by GetSubstitution.
    static func stringReplace(_ input: String, needle: String, replacement: Value, all: Bool, eval: Evaluator) async throws -> String {
        let hay = Array(input.utf16)
        let pat = Array(needle.utf16)
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
            let sub: String
            if case .object(let fn as Callable) = replacement {
                sub = coerceToString(try await eval.callCallable(.object(fn), thisValue: .undefined, args: [.string(needle), .number(Double(at)), .string(input)], site: nil))
            } else {
                sub = expandReplacement(coerceToString(replacement), matched: needle, position: at, input: input, captures: [], groups: .undefined)
            }
            out += Array(sub.utf16)
            cursor = at + pat.count
        }
        out += hay[min(cursor, hay.count)...]
        return String(decoding: out, as: UTF16.self)
    }
}

extension CodemodeLanguage {
    /// EscapeRegExpPattern: `(?:)` for the empty pattern; `/` outside a class and line terminators escaped, so the
    /// source reads back as a regular expression literal.
    static func escapeRegExpPattern(_ pattern: String) -> String {
        if pattern.isEmpty { return "(?:)" }
        var out = ""
        var inClass = false
        var escaped = false
        for ch in pattern.unicodeScalars {
            if escaped {
                out.unicodeScalars.append(ch)
                escaped = false
                continue
            }
            switch ch {
            case "\\": out += "\\"; escaped = true
            case "[": inClass = true; out += "["
            case "]": inClass = false; out += "]"
            case "/": out += inClass ? "/" : "\\/"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }
}
