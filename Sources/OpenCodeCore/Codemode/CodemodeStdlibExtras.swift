import Foundation
import Synchronization

// Built-ins and built-in behaviors upstream psychoscript (v0.1.2, `src/stdlib/*`, `src/prelude/source.ts`) has that
// the Code Mode port lacked or got wrong, found by the differential program corpus `parity/vectors/psychoscript.json`.
// Installed over the port's own built-ins at the end of `CodemodeLanguage.globals`.
extension CodemodeLanguage {
    // MARK: - Number formatting (ECMA-262 Number.prototype.toFixed / toPrecision / toExponential / toString)

    /// The exact decimal expansion of a finite, non-negative double: its digits (no leading zeros, at least one) and
    /// the position of the decimal point within them (`digits[0..<point]` is the integer part; may be <= 0).
    static func exactDecimal(_ x: Double) -> (digits: [UInt8], point: Int) {
        // Every double has a finite decimal expansion; 1100 fractional digits cover the smallest subnormal.
        let text = String(format: "%.1100f", x)
        var digits: [UInt8] = []
        var point = 0
        var seenPoint = false
        for ch in text.utf8 {
            if ch == UInt8(ascii: ".") { seenPoint = true; continue }
            digits.append(ch - UInt8(ascii: "0"))
            if !seenPoint { point += 1 }
        }
        while digits.count > 1, digits.first == 0 { digits.removeFirst(); point -= 1 }
        while digits.count > 1, digits.last == 0 { digits.removeLast() }
        return (digits, point)
    }

    /// Rounds an exact decimal to `count` significant digits, ties away from zero ("pick the larger n").
    static func roundDigits(_ digits: [UInt8], point: Int, count: Int) -> (digits: [UInt8], point: Int) {
        if count <= 0 {
            // Everything is rounded away: 0 or 1 at the next position.
            let up = (digits.first ?? 0) >= 5
            return (up ? [1] : [0], up ? point + 1 : point)
        }
        if digits.count <= count {
            return (digits + Array(repeating: 0, count: count - digits.count), point)
        }
        var kept = Array(digits[0..<count])
        if digits[count] >= 5 {
            var i = count - 1
            while i >= 0 {
                if kept[i] == 9 { kept[i] = 0; i -= 1 } else { kept[i] += 1; break }
            }
            if i < 0 {
                kept.insert(1, at: 0)
                kept.removeLast()
                return (kept, point + 1)
            }
        }
        return (kept, point)
    }

    // Upstream: psychoscript/src/stdlib/number.ts#toFixed (implemented).
    static func numberToFixed(_ x: Double, _ fractionDigits: Int) -> String {
        if !x.isFinite { return formatJSNumber(x) }
        if abs(x) >= 1e21 { return formatJSNumber(x) }
        let negative = x < 0
        let (digits, point) = exactDecimal(abs(x))
        let (rounded, newPoint) = roundDigits(digits, point: point, count: point + fractionDigits)
        var all = rounded
        var p = newPoint
        if p <= 0 {
            all = Array(repeating: 0, count: 1 - p) + all
            p = 1
        }
        if all.count < p + fractionDigits { all += Array(repeating: 0, count: p + fractionDigits - all.count) }
        let intPart = all[0..<p].map { String($0) }.joined()
        let frac = all[p..<(p + fractionDigits)].map { String($0) }.joined()
        let body = fractionDigits > 0 ? "\(intPart).\(frac)" : intPart
        let isZero = !all.contains { $0 != 0 }
        return negative && !isZero ? "-\(body)" : (negative && x != 0 ? "-\(body)" : body)
    }

    // Upstream: psychoscript/src/stdlib/number.ts#toExponential (implemented).
    static func numberToExponential(_ x: Double, _ fractionDigits: Int?) -> String {
        if !x.isFinite { return formatJSNumber(x) }
        let negative = x < 0 || (x == 0 && x.sign == .minus && false)
        var digits: [UInt8]
        var exponent: Int
        if x == 0 {
            digits = Array(repeating: 0, count: (fractionDigits ?? 0) + 1)
            exponent = 0
        } else if let f = fractionDigits {
            let (d, point) = exactDecimal(abs(x))
            let (r, p) = roundDigits(d, point: point, count: f + 1)
            digits = r
            exponent = p - 1
        } else {
            // As many digits as needed to distinguish the value: the shortest round-trip digits.
            let (d, p) = shortestDigits(abs(x))
            digits = d
            exponent = p - 1
        }
        let mantissa = digits.count > 1 ? "\(digits[0]).\(digits[1...].map { String($0) }.joined())" : "\(digits[0])"
        return "\(negative ? "-" : "")\(mantissa)e\(exponent >= 0 ? "+" : "-")\(abs(exponent))"
    }

    // Upstream: psychoscript/src/stdlib/number.ts#toPrecision (implemented).
    static func numberToPrecision(_ x: Double, _ precision: Int) -> String {
        if !x.isFinite { return formatJSNumber(x) }
        let negative = x < 0
        var digits: [UInt8]
        var e: Int
        if x == 0 {
            digits = Array(repeating: 0, count: precision)
            e = 0
        } else {
            let (d, point) = exactDecimal(abs(x))
            let (r, p) = roundDigits(d, point: point, count: precision)
            digits = r
            e = p - 1
        }
        let sign = negative ? "-" : ""
        if e < -6 || e >= precision {
            let mantissa = digits.count > 1 ? "\(digits[0]).\(digits[1...].map { String($0) }.joined())" : "\(digits[0])"
            return "\(sign)\(mantissa)e\(e >= 0 ? "+" : "-")\(abs(e))"
        }
        if e >= 0 {
            let intPart = digits[0...e].map { String($0) }.joined()
            let frac = digits[(e + 1)...].map { String($0) }.joined()
            return frac.isEmpty ? "\(sign)\(intPart)" : "\(sign)\(intPart).\(frac)"
        }
        return "\(sign)0.\(String(repeating: "0", count: -e - 1))\(digits.map { String($0) }.joined())"
    }

    /// The shortest digits that round-trip (as `Number.prototype.toString` prints them), with the decimal point.
    static func shortestDigits(_ x: Double) -> (digits: [UInt8], point: Int) {
        // Swift's description is the shortest round-trip representation.
        let text = "\(x)"
        var mantissa = text
        var exp = 0
        if let eIndex = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = String(text[..<eIndex])
            exp = Int(text[text.index(after: eIndex)...]) ?? 0
        }
        var digits: [UInt8] = []
        var point = 0
        var seenPoint = false
        for ch in mantissa.utf8 {
            if ch == UInt8(ascii: ".") { seenPoint = true; continue }
            guard ch >= UInt8(ascii: "0"), ch <= UInt8(ascii: "9") else { continue }
            digits.append(ch - UInt8(ascii: "0"))
            if !seenPoint { point += 1 }
        }
        while digits.count > 1, digits.first == 0 { digits.removeFirst(); point -= 1 }
        while digits.count > 1, digits.last == 0 { digits.removeLast() }
        return (digits, point + exp)
    }

    /// Number.prototype.toString(radix) for a radix other than 10 (V8's DoubleToRadixCString).
    static func numberToRadixString(_ value: Double, radix: Int) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        if value == 0 { return "0" }
        let chars = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        let negative = value < 0
        let x = abs(value)
        var integer = x.rounded(.down)
        var fraction = x - integer
        // Precision of the last printed digit: half the distance to the next double.
        var delta = max(0.5 * (x.nextUp - x), Double.leastNonzeroMagnitude)
        var fracDigits: [Character] = []
        if fraction >= delta {
            repeat {
                fraction *= Double(radix)
                delta *= Double(radix)
                let digit = Int(fraction)
                fracDigits.append(chars[digit])
                fraction -= Double(digit)
                if fraction > 0.5 || (fraction == 0.5 && (digit & 1) == 1) {
                    if fraction + delta > 1 {
                        // Round up, propagating carries.
                        var i = fracDigits.count - 1
                        while true {
                            if i < 0 { integer += 1; break }
                            let d = chars.firstIndex(of: fracDigits[i])! + 1
                            if d < radix { fracDigits[i] = chars[d]; break }
                            fracDigits.removeLast()
                            i -= 1
                        }
                        break
                    }
                }
            } while fraction >= delta
        }
        var intDigits: [Character] = []
        if integer == 0 {
            intDigits = ["0"]
        } else {
            while integer > 0 {
                let r = integer.truncatingRemainder(dividingBy: Double(radix))
                intDigits.append(chars[Int(r)])
                integer = (integer - r) / Double(radix)
            }
            intDigits.reverse()
        }
        var out = String(intDigits)
        if !fracDigits.isEmpty { out += "." + String(fracDigits) }
        return negative ? "-" + out : out
    }

    /// JS StringToNumber for the decimal literal grammar (Number(" 12 "), "1e3", ".5"; not "1_0", "nan", "0x1p3").
    static func stringToNumber(_ s: JSString) -> Double {
        guard let trimmed = s.trim().wellFormedString else { return .nan }
        if trimmed.isEmpty { return 0 }
        switch trimmed {
        case "Infinity", "+Infinity": return .infinity
        case "-Infinity": return -.infinity
        default: break
        }
        let lower = trimmed.lowercased()
        for (prefix, radix) in [("0x", 16), ("0b", 2), ("0o", 8)] where lower.hasPrefix(prefix) {
            let body = trimmed.dropFirst(2)
            guard !body.isEmpty else { return .nan }
            var result = 0.0
            for ch in body {
                guard let d = ch.hexDigitValue, d < radix else { return .nan }
                result = result * Double(radix) + Double(d)
            }
            return result
        }
        var sawDigit = false
        var i = trimmed.unicodeScalars.makeIterator()
        var state = 0 // 0 sign, 1 int, 2 frac, 3 exp sign, 4 exp
        var sawExpDigit = false
        while let c = i.next() {
            switch (state, c) {
            case (0, "+"), (0, "-"): state = 1
            case (0...1, "0"..."9"): state = 1; sawDigit = true
            case (0...1, "."): state = 2
            case (2, "0"..."9"): sawDigit = true
            case (1...2, "e"), (1...2, "E"):
                guard sawDigit else { return .nan }
                state = 3
            case (3, "+"), (3, "-"): state = 4
            case (3...4, "0"..."9"): state = 4; sawExpDigit = true
            default: return .nan
            }
        }
        guard sawDigit, state < 3 || sawExpDigit else { return .nan }
        return Double(trimmed) ?? .nan
    }

    // MARK: - Install

    static func installStdlibExtras(_ builtins: Builtins, globals: inout [(String, Value)]) {
        let snapshot = globals
        func global(_ name: String) -> Obj? {
            if case .object(let o)? = snapshot.first(where: { $0.0 == name })?.1 { return o }
            return nil
        }

        // Number.prototype
        methods(builtins, builtins.Number, [
            Method("toFixed", 1) { thisVal, args, _, _ in
                let n = try thisNumber(thisVal, "Number.prototype.toFixed")
                let digits = args.first.map { $0.isUndefined ? 0 : coerceToInteger($0) } ?? 0
                guard digits >= 0 && digits <= 100 else { throw rangeError("toFixed() digits argument must be between 0 and 100") }
                return .string(JSString(numberToFixed(n, digits)))
            },
            Method("toPrecision", 1) { thisVal, args, _, _ in
                let n = try thisNumber(thisVal, "Number.prototype.toPrecision")
                guard let arg = args.first, !arg.isUndefined else { return .string(JSString(formatJSNumber(n))) }
                let p = coerceToInteger(arg)
                if !n.isFinite { return .string(JSString(formatJSNumber(n))) }
                guard p >= 1 && p <= 100 else { throw rangeError("toPrecision() argument must be between 1 and 100") }
                return .string(JSString(numberToPrecision(n, p)))
            },
            Method("toExponential", 1) { thisVal, args, _, _ in
                let n = try thisNumber(thisVal, "Number.prototype.toExponential")
                let f: Int? = args.first.flatMap { $0.isUndefined ? nil : coerceToInteger($0) }
                if !n.isFinite { return .string(JSString(formatJSNumber(n))) }
                if let f, f < 0 || f > 100 { throw rangeError("toExponential() argument must be between 0 and 100") }
                return .string(JSString(numberToExponential(n, f)))
            },
            Method("toString", 1) { thisVal, args, _, _ in
                let n = try thisNumber(thisVal, "Number.prototype.toString")
                let radix = args.first.map { $0.isUndefined ? 10 : coerceToInteger($0) } ?? 10
                guard radix >= 2 && radix <= 36 else { throw rangeError("toString() radix must be between 2 and 36") }
                if radix == 10 { return .string(JSString(formatJSNumber(n))) }
                return .string(JSString(numberToRadixString(n, radix: radix)))
            },
        ])

        // String.prototype
        methods(builtins, builtins.String, [
            Method("normalize", 0) { thisVal, args, _, _ in
                let s = coerceToString(thisVal)
                let form: JSString = args.first.map { $0.isUndefined ? "NFC" : coerceToString($0) } ?? "NFC"
                switch form {
                case "NFC": return .string(s.mapWellFormedSpans { $0.precomposedStringWithCanonicalMapping })
                case "NFD": return .string(s.mapWellFormedSpans { $0.decomposedStringWithCanonicalMapping })
                case "NFKC": return .string(s.mapWellFormedSpans { $0.precomposedStringWithCompatibilityMapping })
                case "NFKD": return .string(s.mapWellFormedSpans { $0.decomposedStringWithCompatibilityMapping })
                default: throw rangeError("String.normalize expects the form \"NFC\", \"NFD\", \"NFKC\", or \"NFKD\" (got \(jsonQuote(form))).")
                }
            },
            Method("toLocaleUpperCase", 0) { thisVal, _, _, _ in .string(coerceToString(thisVal).uppercased()) },
            Method("toLocaleLowerCase", 0) { thisVal, _, _, _ in .string(coerceToString(thisVal).lowercased()) },
            Method("trimLeft", 0) { thisVal, _, _, _ in .string(coerceToString(thisVal).trimStart()) },
            Method("trimRight", 0) { thisVal, _, _, _ in .string(coerceToString(thisVal).trimEnd()) },
            Method("substr", 2) { thisVal, args, _, _ in
                let units = coerceToString(thisVal).utf16Units
                let size = units.count
                var start = args.first.map { coerceToInteger($0) } ?? 0
                if start < 0 { start = max(size + start, 0) }
                start = min(start, size)
                let length = args.count > 1 && !args[1].isUndefined ? coerceToInteger(args[1]) : size - start
                let end = min(start + max(length, 0), size)
                guard start < end else { return .string("") }
                return .string(JSString(utf16: units[start..<end]))
            },
            Method("isWellFormed", 0) { thisVal, _, _, _ in
                .bool(coerceToString(thisVal).isWellFormed)
            },
            Method("toWellFormed", 0) { thisVal, _, _, _ in
                .string(coerceToString(thisVal).toWellFormed())
            },
            Method("matchAll", 1) { thisVal, args, site, eval in
                let s = coerceToString(thisVal)
                let arg = args.first ?? .undefined
                let rx: RegExpObj
                if case .object(let existing as RegExpObj) = arg {
                    guard existing.flags.contains("g") else {
                        throw typeError("String.matchAll requires a regular expression with the global (g) flag: write /\(existing.source)/\(existing.flags)g, or use String.match for a single match.")
                    }
                    rx = RegExpObj(proto: builtins.RegExp, pattern: existing.pattern, flags: existing.flags)
                    rx.lastIndex = existing.lastIndex
                } else {
                    rx = try constructRegExp(builtins, args: [arg.isUndefined ? .string("") : .string(coerceToString(arg)), .string("g")])
                }
                var matches: [Value] = []
                while true {
                    let m = try await invokeMethod(eval, target: .object(rx), name: "exec", args: [.string(s)], site: site)
                    guard case .object(let mObj) = m else { break }
                    matches.append(m)
                    if case .string(let whole) = get(mObj, "0"), whole.isEmpty { rx.lastIndex += 1 }
                }
                let list = matches
                let index = Mutex(0)
                let cursor = Cursor {
                    index.withLock { i in
                        guard i < list.count else { return Step(value: .undefined, done: true) }
                        defer { i += 1 }
                        return Step(value: list[i], done: false)
                    }
                }
                return .object(IteratorObj(proto: builtins.Iterator, cursor: cursor))
            },
        ])

        // Array.prototype
        methods(builtins, builtins.Array, [
            Method("toSpliced", 2) { thisVal, args, _, _ in
                let arr = try receiver(Arr.self, thisVal, "Array.prototype.toSpliced")
                var items = arr.items
                let len = items.count
                var start = args.isEmpty ? 0 : coerceToInteger(args[0])
                start = start < 0 ? max(len + start, 0) : min(start, len)
                let skip: Int
                if args.isEmpty { skip = 0 } else if args.count == 1 { skip = len - start } else { skip = min(max(coerceToInteger(args[1]), 0), len - start) }
                items.replaceSubrange(start..<(start + skip), with: args.count > 2 ? Array(args[2...]) : [])
                return .object(Arr(proto: builtins.Array, items: items))
            },
            Method("copyWithin", 2) { thisVal, args, _, _ in
                let arr = try receiver(Arr.self, thisVal, "Array.prototype.copyWithin")
                var items = arr.items
                let len = items.count
                func rel(_ v: Value?, _ dflt: Int) -> Int {
                    guard let v, !v.isUndefined else { return dflt }
                    let n = coerceToInteger(v)
                    return n < 0 ? max(len + n, 0) : min(n, len)
                }
                let to = rel(args.first, 0)
                let from = rel(args.count > 1 ? args[1] : nil, 0)
                let end = rel(args.count > 2 ? args[2] : nil, len)
                let count = min(end - from, len - to)
                if count > 0 {
                    let slice = Array(items[from..<(from + count)])
                    items.replaceSubrange(to..<(to + count), with: slice)
                    arr.items = items
                }
                return thisVal
            },
        ])

        // Object.prototype / Object
        methods(builtins, builtins.Object, [
            Method("isPrototypeOf", 1) { thisVal, args, _, _ in
                guard case .object(let proto) = thisVal, case .object(let v)? = args.first else { return .bool(false) }
                var current = v.proto
                while let c = current {
                    if c === proto { return .bool(true) }
                    current = c.proto
                }
                return .bool(false)
            },
            Method("propertyIsEnumerable", 1) { thisVal, args, _, _ in
                guard case .object(let obj) = thisVal else { return .bool(false) }
                let key = coerceToString(args.first ?? .undefined)
                if let arr = obj as? Arr, let idx = parseArrayIndex(key), idx >= 0, idx < arr.count { return .bool(true) }
                return .bool(own(obj, .string(key))?.enumerable ?? false)
            },
        ])
        if let objectCtor = global("Object") {
            methods(builtins, objectCtor, [
                Method("preventExtensions", 1) { _, args, _, _ in
                    if case .object(let obj)? = args.first { obj.extensible = false }
                    return args.first ?? .undefined
                },
                Method("isExtensible", 1) { _, args, _, _ in
                    guard case .object(let obj)? = args.first else { return .bool(false) }
                    return .bool(obj.extensible)
                },
            ])
        }

        // Map.groupBy, Map.prototype.getOrInsert / getOrInsertComputed
        if let mapCtor = global("Map") {
            methods(builtins, mapCtor, [
                Method("groupBy", 2) { _, args, _, eval in
                    let items = try await eval.collectIterable(args.first ?? .undefined)
                    let cb = try requireCallback(args.count > 1 ? args[1] : .undefined, "Map.groupBy")
                    let map = MapObj(proto: builtins.Map)
                    for (i, item) in items.enumerated() {
                        var key = try await eval.callCallable(.object(cb), thisValue: .undefined, args: [item, .number(Double(i))], site: nil)
                        if case .number(let n) = key, n == 0 { key = .number(0) }
                        if case .object(let group as Arr) = map.table.get(key), map.table.has(key) {
                            group.items = group.items + [item]
                        } else {
                            map.table.set(key, .object(Arr(proto: builtins.Array, items: [item])))
                        }
                    }
                    return .object(map)
                },
            ])
        }
        methods(builtins, builtins.Map, [
            Method("getOrInsert", 2) { thisVal, args, _, _ in
                let map = try receiver(MapObj.self, thisVal, "Map.prototype.getOrInsert")
                let key = args.first ?? .undefined
                if map.table.has(key) { return map.table.get(key) }
                let value = args.count > 1 ? args[1] : .undefined
                map.table.set(key, value)
                return value
            },
            Method("getOrInsertComputed", 2) { thisVal, args, _, eval in
                let map = try receiver(MapObj.self, thisVal, "Map.prototype.getOrInsertComputed")
                let key = args.first ?? .undefined
                let cb = try requireCallback(args.count > 1 ? args[1] : .undefined, "Map.getOrInsertComputed")
                if map.table.has(key) { return map.table.get(key) }
                let value = try await eval.callCallable(.object(cb), thisValue: .undefined, args: [key], site: nil)
                map.table.set(key, value)
                return value
            },
        ])

        // Set.prototype composition methods (ES2025)
        @Sendable func otherKeys(_ value: Value, _ eval: Evaluator) async throws -> [Value] {
            if case .object(let set as SetObj) = value { return set.table.liveKeys() }
            if case .object(let map as MapObj) = value { return map.table.liveEntries().map(\.0) }
            guard case .object(let obj) = value else { throw typeError("The 'other' argument must be set-like.") }
            let keysFn = try await eval.getValue(obj, .string("keys"))
            let iter = try await eval.callCallable(keysFn, thisValue: value, args: [], site: nil)
            return try await eval.collectIterable(iter)
        }
        @Sendable func otherHas(_ value: Value, _ key: Value, _ eval: Evaluator) async throws -> Bool {
            if case .object(let set as SetObj) = value { return set.table.has(key) }
            if case .object(let map as MapObj) = value { return map.table.has(key) }
            guard case .object(let obj) = value else { return false }
            let hasFn = try await eval.getValue(obj, .string("has"))
            return try await eval.callCallable(hasFn, thisValue: value, args: [key], site: nil).isTruthy
        }
        @Sendable func makeSet(_ keys: [Value]) -> Value {
            let set = SetObj(proto: builtins.Set)
            for k in keys { set.table.add(k) }
            return .object(set)
        }
        methods(builtins, builtins.Set, [
            Method("union", 1) { thisVal, args, _, eval in
                let me = try receiver(SetObj.self, thisVal, "Set.prototype.union")
                return makeSet(me.table.liveKeys() + (try await otherKeys(args.first ?? .undefined, eval)))
            },
            Method("intersection", 1) { thisVal, args, _, eval in
                let me = try receiver(SetObj.self, thisVal, "Set.prototype.intersection")
                var out: [Value] = []
                for k in me.table.liveKeys() where try await otherHas(args.first ?? .undefined, k, eval) { out.append(k) }
                return makeSet(out)
            },
            Method("difference", 1) { thisVal, args, _, eval in
                let me = try receiver(SetObj.self, thisVal, "Set.prototype.difference")
                var out: [Value] = []
                for k in me.table.liveKeys() where !(try await otherHas(args.first ?? .undefined, k, eval)) { out.append(k) }
                return makeSet(out)
            },
            Method("symmetricDifference", 1) { thisVal, args, _, eval in
                let me = try receiver(SetObj.self, thisVal, "Set.prototype.symmetricDifference")
                let other = try await otherKeys(args.first ?? .undefined, eval)
                let otherSet = SetObj(proto: builtins.Set)
                for k in other { otherSet.table.add(k) }
                var out = me.table.liveKeys().filter { !otherSet.table.has($0) }
                for k in other where !me.table.has(k) { out.append(k) }
                return makeSet(out)
            },
            Method("isSubsetOf", 1) { thisVal, args, _, eval in
                let me = try receiver(SetObj.self, thisVal, "Set.prototype.isSubsetOf")
                for k in me.table.liveKeys() where !(try await otherHas(args.first ?? .undefined, k, eval)) { return .bool(false) }
                return .bool(true)
            },
            Method("isSupersetOf", 1) { thisVal, args, _, eval in
                let me = try receiver(SetObj.self, thisVal, "Set.prototype.isSupersetOf")
                for k in try await otherKeys(args.first ?? .undefined, eval) where !me.table.has(k) { return .bool(false) }
                return .bool(true)
            },
            Method("isDisjointFrom", 1) { thisVal, args, _, eval in
                let me = try receiver(SetObj.self, thisVal, "Set.prototype.isDisjointFrom")
                for k in me.table.liveKeys() where try await otherHas(args.first ?? .undefined, k, eval) { return .bool(false) }
                return .bool(true)
            },
        ])

        // Math
        if let math = global("Math") {
            @Sendable func n(_ a: [Value], _ i: Int = 0) -> Double { coerceToNumber(i < a.count ? a[i] : .undefined) }
            methods(builtins, math, [
                Method("round", 1) { _, a, _, _ in
                    let x = n(a)
                    if !x.isFinite || x == 0 { return .number(x) }
                    if x > 0 && x < 0.5 { return .number(0) }
                    if x < 0 && x >= -0.5 { return .number(-0.0) }
                    let floor = x.rounded(.down)
                    return .number(x - floor >= 0.5 ? floor + 1 : floor)
                },
                Method("pow", 2) { _, a, _, _ in .number(jsPow(n(a), n(a, 1))) },
                Method("fround", 1) { _, a, _, _ in .number(Double(Float(n(a)))) },
                Method("log1p", 1) { _, a, _, _ in .number(Foundation.log1p(n(a))) },
                Method("expm1", 1) { _, a, _, _ in .number(Foundation.expm1(n(a))) },
                Method("sinh", 1) { _, a, _, _ in .number(Foundation.sinh(n(a))) },
                Method("cosh", 1) { _, a, _, _ in .number(Foundation.cosh(n(a))) },
                Method("tanh", 1) { _, a, _, _ in .number(Foundation.tanh(n(a))) },
                Method("asinh", 1) { _, a, _, _ in .number(Foundation.asinh(n(a))) },
                Method("acosh", 1) { _, a, _, _ in .number(Foundation.acosh(n(a))) },
                Method("atanh", 1) { _, a, _, _ in .number(Foundation.atanh(n(a))) },
            ])
        }

        // RegExp.escape
        if let regexpCtor = global("RegExp") {
            methods(builtins, regexpCtor, [
                Method("escape", 1) { _, args, _, _ in
                    guard case .string(let s)? = args.first else { throw typeError("RegExp.escape expects a string.") }
                    return .string(regexpEscape(s))
                },
            ])
        }

        // Date.prototype
        installDateExtras(builtins)

        // Iterator.from and the iterator helpers
        installIteratorHelpers(builtins, iteratorCtor: global("Iterator"))

        // Uint8Array and Buffer
        installBytesExtras(builtins, uint8ArrayCtor: global("Uint8Array"), bufferCtor: global("Buffer"))
    }

    static func thisNumber(_ value: Value, _ method: String) throws -> Double {
        switch value {
        case .number(let n): return n
        case .object(let obj):
            if case .number(let n) = obj.toPrimitive(hint: .number), obj.tag == "Number" { return n }
            throw typeError("\(method) requires that 'this' be a Number")
        default:
            throw typeError("\(method) requires that 'this' be a Number")
        }
    }

    /// `**` / Math.pow: like C pow, except that a base of ±1 with an infinite exponent, and NaN exponents, are NaN.
    static func jsPow(_ base: Double, _ exponent: Double) -> Double {
        if exponent.isNaN { return .nan }
        if exponent == 0 { return 1 }
        if abs(base) == 1 && exponent.isInfinite { return .nan }
        return Foundation.pow(base, exponent)
    }

    // Upstream: psychoscript/src/stdlib/regexp.ts#escape (implemented).
    /// ES2025 RegExp.escape (handles lone UTF-16 surrogates as `\udxxx` while preserving valid pairs).
    static func regexpEscape(_ s: JSString) -> JSString {
        let units = s.utf16Units
        var out = ""
        let syntax: Set<UInt16> = Set("^$\\.*+?()[]{}|/".utf16)
        let other: Set<UInt16> = Set(",-=<>#&!%:;@~'`\"".utf16)
        var i = 0
        var cpIndex = 0
        while i < units.count {
            let u = units[i]
            if u >= 0xD800 && u <= 0xDBFF, i + 1 < units.count {
                let lo = units[i + 1]
                if lo >= 0xDC00 && lo <= 0xDFFF {
                    let cp = 0x10000 + ((UInt32(u - 0xD800) << 10) | UInt32(lo - 0xDC00))
                    out.unicodeScalars.append(Unicode.Scalar(cp)!)
                    i += 2
                    cpIndex += 1
                    continue
                }
            }
            if u >= 0xD800 && u <= 0xDFFF {
                out += String(format: "\\u%04x", u)
                i += 1
                cpIndex += 1
                continue
            }
            let scalar = Unicode.Scalar(u)!
            if cpIndex == 0,
               (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A) || (u >= 0x30 && u <= 0x39) {
                out += String(format: "\\x%02x", u)
            } else if syntax.contains(u) {
                out += "\\\(Character(scalar))"
            } else if other.contains(u) || u == 0x20 {
                out += String(format: "\\x%02x", u)
            } else if u == 0x09 { out += "\\t" }
            else if u == 0x0A { out += "\\n" }
            else if u == 0x0B { out += "\\v" }
            else if u == 0x0C { out += "\\f" }
            else if u == 0x0D { out += "\\r" }
            else if JSString.isJSWhitespace(u) || scalar.properties.isWhitespace {
                out += u <= 0xFF ? String(format: "\\x%02x", u) : String(format: "\\u%04x", u)
            } else {
                out.unicodeScalars.append(scalar)
            }
            i += 1
            cpIndex += 1
        }
        return JSString(out)
    }

    // MARK: Date

    /// TimeClip: times beyond ±8.64e15 ms are invalid.
    static func timeClip(_ t: Double) -> Double {
        guard t.isFinite, abs(t) <= 8.64e15 else { return .nan }
        return t.rounded(.towardZero) + 0
    }

    static func installDateExtras(_ builtins: Builtins) {
        @Sendable func comps(_ d: DateObj) -> (year: Double, month: Double, day: Double, hour: Double, minute: Double, second: Double, millisecond: Double) {
            utcComponents(d.epochMs)
        }
        @Sendable func make(_ y: Double, _ mo: Double, _ d: Double, _ h: Double, _ mi: Double, _ s: Double, _ ms: Double) -> Double {
            guard [y, mo, d, h, mi, s, ms].allSatisfy({ $0.isFinite }) else { return .nan }
            func i(_ v: Double) -> Int { Int(v.rounded(.towardZero)) }
            return timeClip(makeUTCEpochMs(year: i(y), month: i(mo), day: i(d), hour: i(h), minute: i(mi), second: i(s), ms: i(ms)))
        }
        @Sendable func arg(_ args: [Value], _ i: Int, _ fallback: Double) -> Double {
            i < args.count ? coerceToNumber(args[i]) : fallback
        }
        // Each setter replaces fields from the given position on, as many as were passed.
        @Sendable func setter(_ name: String, _ length: Int, firstField: Int) -> Method {
            Method(name, length) { thisVal, args, _, _ in
                let d = try receiver(DateObj.self, thisVal, "Date.prototype.\(name)")
                var c = comps(d)
                if !d.epochMs.isFinite {
                    if firstField != 0 { return .number(.nan) }
                    c = utcComponents(0)
                }
                var fields = [c.year, c.month, c.day, c.hour, c.minute, c.second, c.millisecond]
                let count = min(max(args.count, 1), length)
                for k in 0..<count { fields[firstField + k] = arg(args, k, .nan) }
                let t = make(fields[0], fields[1], fields[2], fields[3], fields[4], fields[5], fields[6])
                d.epochMs = t
                return .number(t)
            }
        }
        let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        @Sendable func pad(_ v: Double, _ width: Int = 2) -> String {
            let s = String(Int(v))
            return String(repeating: "0", count: max(0, width - s.count)) + s
        }
        @Sendable func weekday(_ t: Double) -> Int {
            let days = (t / 86_400_000).rounded(.down)
            return Int(((days + 4).truncatingRemainder(dividingBy: 7) + 7).truncatingRemainder(dividingBy: 7))
        }
        methods(builtins, builtins.Date, [
            Method("getUTCDay", 0) { thisVal, _, _, _ in
                let d = try receiver(DateObj.self, thisVal, "Date.prototype.getUTCDay")
                guard d.epochMs.isFinite else { return .number(.nan) }
                return .number(Double(weekday(d.epochMs)))
            },
            Method("setTime", 1) { thisVal, args, _, _ in
                let d = try receiver(DateObj.self, thisVal, "Date.prototype.setTime")
                d.epochMs = timeClip(arg(args, 0, .nan))
                return .number(d.epochMs)
            },
            setter("setUTCFullYear", 3, firstField: 0),
            setter("setUTCMonth", 2, firstField: 1),
            setter("setUTCDate", 1, firstField: 2),
            setter("setUTCHours", 4, firstField: 3),
            setter("setUTCMinutes", 3, firstField: 4),
            setter("setUTCSeconds", 2, firstField: 5),
            setter("setUTCMilliseconds", 1, firstField: 6),
            Method("toUTCString", 0) { thisVal, _, _, _ in
                let d = try receiver(DateObj.self, thisVal, "Date.prototype.toUTCString")
                guard d.epochMs.isFinite else { return .string("Invalid Date") }
                let c = comps(d)
                let year = c.year < 0 ? "-" + pad(-c.year, 6) : pad(c.year, 4)
                return .string(JSString("\(weekdays[weekday(d.epochMs)]), \(pad(c.day)) \(months[Int(c.month)]) \(year) \(pad(c.hour)):\(pad(c.minute)):\(pad(c.second)) GMT"))
            },
        ])
    }

    // MARK: Iterator helpers (ES2025)

    static func installIteratorHelpers(_ builtins: Builtins, iteratorCtor: Obj?) {
        /// A lazy helper iterator: its body pulls from the source as `next` is called (a generator body).
        @Sendable func helper(_ eval: Evaluator, closing source: Value? = nil, _ body: @escaping @Sendable (Evaluator) async throws -> Void) -> Value {
            let gen = GeneratorObj(proto: builtins.IteratorHelper, isAsync: false) {
                do {
                    try await body(eval)
                } catch let signal as ControlSignal {
                    // `return()` on the helper closes the iterator it reads from.
                    if case .object(let src)? = source {
                        let closer = try await eval.getValue(src, .string("return"))
                        if isCallableValue(closer) { _ = try await eval.callCallable(closer, thisValue: source!, args: [], site: nil) }
                    }
                    throw signal
                }
                return .undefined
            }
            return .object(gen)
        }
        /// Steps `source` (an iterator object) with its own `next`, one value per call.
        @Sendable func stepper(_ source: Value, _ eval: Evaluator, _ method: String) async throws -> (next: @Sendable () async throws -> Value?, close: @Sendable () async throws -> Void) {
            guard case .object(let obj) = source else {
                throw typeError("\(method) called on incompatible receiver \(describeValue(source)).")
            }
            let nextFn = try await eval.getValue(obj, .string("next"))
            return ({
                let result = try await eval.callCallable(nextFn, thisValue: source, args: [], site: nil)
                let resultObj = try requireIteratorObject(result)
                if try await eval.getValue(resultObj, .string("done")).isTruthy { return nil }
                return try await eval.getValue(resultObj, .string("value"))
            }, {
                let closer = try await eval.getValue(obj, .string("return"))
                if isCallableValue(closer) { _ = try await eval.callCallable(closer, thisValue: source, args: [], site: nil) }
            })
        }
        @Sendable func count(_ v: Value?, _ method: String) throws -> Double {
            let n = coerceToNumber(v ?? .undefined)
            if n.isNaN { throw rangeError("\(method) must be passed a number.") }
            let t = n.rounded(.towardZero)
            if t < 0 { throw rangeError("\(method) must be passed a positive number.") }
            return t
        }
        methods(builtins, builtins.Iterator, [
            Method("map", 1) { thisVal, args, _, eval in
                let cb = try requireCallback(args.first ?? .undefined, "Iterator.map")
                let src = try await stepper(thisVal, eval, "Iterator.prototype.map")
                return helper(eval, closing: thisVal) { eval in
                    var i = 0.0
                    while let v = try await src.next() {
                        let mapped = try await eval.callCallable(.object(cb), thisValue: .undefined, args: [v, .number(i)], site: nil)
                        i += 1
                        _ = try await eval.yieldValue(mapped, isAsync: false)
                    }
                }
            },
            Method("filter", 1) { thisVal, args, _, eval in
                let cb = try requireCallback(args.first ?? .undefined, "Iterator.filter")
                let src = try await stepper(thisVal, eval, "Iterator.prototype.filter")
                return helper(eval, closing: thisVal) { eval in
                    var i = 0.0
                    while let v = try await src.next() {
                        let keep = try await eval.callCallable(.object(cb), thisValue: .undefined, args: [v, .number(i)], site: nil)
                        i += 1
                        if keep.isTruthy { _ = try await eval.yieldValue(v, isAsync: false) }
                    }
                }
            },
            Method("take", 1) { thisVal, args, _, eval in
                let limit = try count(args.first, "Iterator.prototype.take")
                let src = try await stepper(thisVal, eval, "Iterator.prototype.take")
                return helper(eval, closing: thisVal) { eval in
                    var remaining = limit
                    while remaining > 0 {
                        guard let v = try await src.next() else { return }
                        remaining -= 1
                        _ = try await eval.yieldValue(v, isAsync: false)
                    }
                    try await src.close()
                }
            },
            Method("drop", 1) { thisVal, args, _, eval in
                let limit = try count(args.first, "Iterator.prototype.drop")
                let src = try await stepper(thisVal, eval, "Iterator.prototype.drop")
                return helper(eval, closing: thisVal) { eval in
                    var remaining = limit
                    while remaining > 0 {
                        guard try await src.next() != nil else { return }
                        remaining -= 1
                    }
                    while let v = try await src.next() { _ = try await eval.yieldValue(v, isAsync: false) }
                }
            },
            Method("flatMap", 1) { thisVal, args, _, eval in
                let cb = try requireCallback(args.first ?? .undefined, "Iterator.flatMap")
                let src = try await stepper(thisVal, eval, "Iterator.prototype.flatMap")
                return helper(eval, closing: thisVal) { eval in
                    var i = 0.0
                    while let v = try await src.next() {
                        let inner = try await eval.callCallable(.object(cb), thisValue: .undefined, args: [v, .number(i)], site: nil)
                        i += 1
                        let iteration = try await eval.openIteration(inner)
                        while let item = try await iteration.step() { _ = try await eval.yieldValue(item, isAsync: false) }
                    }
                }
            },
            Method("reduce", 1) { thisVal, args, _, eval in
                let cb = try requireCallback(args.first ?? .undefined, "Iterator.reduce")
                let src = try await stepper(thisVal, eval, "Iterator.prototype.reduce")
                var acc: Value
                var i = 0.0
                if args.count > 1 {
                    acc = args[1]
                } else {
                    guard let first = try await src.next() else { throw typeError("Iterator.reduce of an empty iterator with no initial value.") }
                    acc = first
                    i = 1
                }
                while let v = try await src.next() {
                    acc = try await eval.callCallable(.object(cb), thisValue: .undefined, args: [acc, v, .number(i)], site: nil)
                    i += 1
                }
                return acc
            },
            Method("forEach", 1) { thisVal, args, _, eval in
                let cb = try requireCallback(args.first ?? .undefined, "Iterator.forEach")
                let src = try await stepper(thisVal, eval, "Iterator.prototype.forEach")
                var i = 0.0
                while let v = try await src.next() {
                    _ = try await eval.callCallable(.object(cb), thisValue: .undefined, args: [v, .number(i)], site: nil)
                    i += 1
                }
                return .undefined
            },
            Method("some", 1) { thisVal, args, _, eval in
                let cb = try requireCallback(args.first ?? .undefined, "Iterator.some")
                let src = try await stepper(thisVal, eval, "Iterator.prototype.some")
                var i = 0.0
                while let v = try await src.next() {
                    if try await eval.callCallable(.object(cb), thisValue: .undefined, args: [v, .number(i)], site: nil).isTruthy {
                        try await src.close()
                        return .bool(true)
                    }
                    i += 1
                }
                return .bool(false)
            },
            Method("every", 1) { thisVal, args, _, eval in
                let cb = try requireCallback(args.first ?? .undefined, "Iterator.every")
                let src = try await stepper(thisVal, eval, "Iterator.prototype.every")
                var i = 0.0
                while let v = try await src.next() {
                    if !(try await eval.callCallable(.object(cb), thisValue: .undefined, args: [v, .number(i)], site: nil).isTruthy) {
                        try await src.close()
                        return .bool(false)
                    }
                    i += 1
                }
                return .bool(true)
            },
            Method("find", 1) { thisVal, args, _, eval in
                let cb = try requireCallback(args.first ?? .undefined, "Iterator.find")
                let src = try await stepper(thisVal, eval, "Iterator.prototype.find")
                var i = 0.0
                while let v = try await src.next() {
                    if try await eval.callCallable(.object(cb), thisValue: .undefined, args: [v, .number(i)], site: nil).isTruthy {
                        try await src.close()
                        return v
                    }
                    i += 1
                }
                return .undefined
            },
            Method("toArray", 0) { thisVal, _, _, eval in
                let src = try await stepper(thisVal, eval, "Iterator.prototype.toArray")
                var items: [Value] = []
                while let v = try await src.next() {
                    items.append(v)
                    try checkArrayLength(items.count)
                }
                return .object(Arr(proto: builtins.Array, items: items))
            },
        ])
        if let iteratorCtor {
            methods(builtins, iteratorCtor, [
                Method("from", 1) { _, args, _, eval in
                    let value = args.first ?? .undefined
                    // An iterable gives its iterator; an iterator object is wrapped so it inherits the helpers.
                    if case .object(let obj) = value {
                        let method = try await eval.getValue(obj, .symbol(IteratorSymbol))
                        if isCallableValue(method) {
                            let iter = try await eval.callCallable(method, thisValue: value, args: [], site: nil)
                            if case .object(let iterObj) = iter, hasPrototype(iter, builtins.Iterator) { _ = iterObj; return iter }
                            let src = try await stepper(iter, eval, "Iterator.from")
                            return helper(eval) { eval in
                                while let v = try await src.next() { _ = try await eval.yieldValue(v, isAsync: false) }
                            }
                        }
                        let src = try await stepper(value, eval, "Iterator.from")
                        return helper(eval) { eval in
                            while let v = try await src.next() { _ = try await eval.yieldValue(v, isAsync: false) }
                        }
                    }
                    if case .string = value {
                        let iteration = try await eval.openIteration(value)
                        return helper(eval) { eval in
                            while let v = try await iteration.step() { _ = try await eval.yieldValue(v, isAsync: false) }
                        }
                    }
                    throw typeError("Iterator.from called on non-object")
                },
            ])
        }
    }
}
