import Foundation
import OpenCodeUtil
import Synchronization

// Uint8Array and Buffer built-ins the port lacked (upstream `src/stdlib/bytes.ts`, `src/stdlib/buffer.ts`, which hand
// most Buffer work to Node's Buffer), found by the differential corpus.
extension CodemodeLanguage {
    static let bufferEncodings: Set<String> = [
        "utf8", "utf-8", "hex", "base64", "base64url", "latin1", "binary", "ascii", "ucs2", "ucs-2", "utf16le", "utf-16le",
    ]

    static func bufferEncoding(_ value: Value?, _ builtins: Builtins) throws -> String {
        guard let value, !value.isUndefined else { return "utf8" }
        let name = coerceToString(value).lowercased().toWellFormedString()
        guard bufferEncodings.contains(name) else {
            let error = createErrorValue(builtins.TypeError, message: "Unknown encoding: \(coerceToString(value))")
            define(error, "code", .string("ERR_UNKNOWN_ENCODING"))
            throw Throw(.object(error))
        }
        return name
    }

    /// Node's Buffer.from(string, encoding).
    static func encodeString(_ text: JSString, encoding: String) -> [UInt8] {
        switch encoding {
        case "hex":
            var out: [UInt8] = []
            let units = text.utf16Units
            var i = 0
            while i + 1 < units.count {
                guard units[i] <= 0x7F, units[i + 1] <= 0x7F,
                      let hi = Character(UnicodeScalar(UInt8(units[i]))).hexDigitValue,
                      let lo = Character(UnicodeScalar(UInt8(units[i + 1]))).hexDigitValue else { break }
                out.append(UInt8(hi * 16 + lo))
                i += 2
            }
            return out
        case "base64", "base64url":
            // Node decodes leniently: either alphabet, padding optional, other characters skipped.
            var sextets: [UInt8] = []
            for unit in text.utf16Units {
                switch unit {
                case 0x41...0x5A: sextets.append(UInt8(unit - 65))
                case 0x61...0x7A: sextets.append(UInt8(unit - 71))
                case 0x30...0x39: sextets.append(UInt8(unit + 4))
                case 0x2B, 0x2D: sextets.append(62)
                case 0x2F, 0x5F: sextets.append(63)
                case 0x3D: break
                default: continue
                }
                if unit == 0x3D { break }
            }
            var out: [UInt8] = []
            var i = 0
            while i + 1 < sextets.count {
                let b0 = sextets[i], b1 = sextets[i + 1]
                out.append(b0 << 2 | b1 >> 4)
                if i + 2 < sextets.count { out.append((b1 & 0x0F) << 4 | sextets[i + 2] >> 2) }
                if i + 3 < sextets.count { out.append((sextets[i + 2] & 0x03) << 6 | sextets[i + 3]) }
                i += 4
            }
            return out
        case "latin1", "binary", "ascii":
            return text.utf16Units.map { UInt8(truncatingIfNeeded: $0) }
        case "ucs2", "ucs-2", "utf16le", "utf-16le":
            return text.utf16Units.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] }
        default:
            return text.utf8BytesReplacingSurrogates()
        }
    }

    /// Node's buffer.toString(encoding).
    static func decodeBytes(_ bytes: [UInt8], encoding: String) -> JSString {
        switch encoding {
        case "hex": return JSString(bytes.map { String(format: "%02x", $0) }.joined())
        case "base64": return JSString(encodeBase64(bytes, alphabet: "base64", omitPadding: false))
        case "base64url": return JSString(encodeBase64(bytes, alphabet: "base64url", omitPadding: true))
        case "latin1", "binary": return JSString(utf16: bytes.map { UInt16($0) })
        case "ascii": return JSString(utf16: bytes.map { UInt16($0 & 0x7F) })
        case "ucs2", "ucs-2", "utf16le", "utf-16le":
            var units: [UInt16] = []
            var i = 0
            while i + 1 < bytes.count {
                units.append(UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8)
                i += 2
            }
            return JSString(utf16: units)
        default: return JSString(String(decoding: bytes, as: UTF8.self))
        }
    }

    static func installBytesExtras(_ builtins: Builtins, uint8ArrayCtor: Obj?, bufferCtor: Obj?) {
        @Sendable func clampIndex(_ value: Value?, _ length: Int, _ fallback: Int) -> Int {
            guard let value, !value.isUndefined else { return fallback }
            let n = coerceToInteger(value)
            return n < 0 ? max(length + n, 0) : min(n, length)
        }
        @Sendable func needleBytes(_ value: Value, encoding: String = "utf8") -> [UInt8]? {
            switch value {
            case .string(let s): return encodeString(s, encoding: encoding)
            case .object(let b as Bytes): return b.data
            case .number(let n): return [UInt8(truncatingIfNeeded: Int(n.rounded(.towardZero)))]
            default: return nil
            }
        }
        @Sendable func search(_ hay: [UInt8], _ needle: [UInt8], from: Int) -> Int {
            if needle.isEmpty { return min(from, hay.count) }
            var i = max(0, from)
            while i + needle.count <= hay.count {
                if Array(hay[i..<(i + needle.count)]) == needle { return i }
                i += 1
            }
            return -1
        }

        methods(builtins, builtins.Uint8Array, [
            Method("join", 1) { tv, args, _, _ in
                let b = try receiver(Bytes.self, tv, "Uint8Array.prototype.join")
                let sep: JSString = args.first.map { $0.isUndefined ? "," : coerceToString($0) } ?? ","
                return .string(b.data.map { JSString(String($0)) }.joinedJS(separator: sep))
            },
            Method("set", 2) { tv, args, _, eval in
                let b = try receiver(Bytes.self, tv, "Uint8Array.prototype.set")
                let source: [UInt8]
                if case .object(let other as Bytes) = args.first ?? .undefined {
                    source = other.data
                } else {
                    source = try await eval.collectIterable(args.first ?? .undefined).map { toUint8($0) }
                }
                let offset = args.count > 1 ? coerceToInteger(args[1]) : 0
                guard offset >= 0, offset + source.count <= b.length else { throw rangeError("offset is out of bounds") }
                for (i, byte) in source.enumerated() { b.setByte(offset + i, byte) }
                return .undefined
            },
            Method("fill", 3) { tv, args, _, _ in
                let b = try receiver(Bytes.self, tv, "Uint8Array.prototype.fill")
                let value = toUint8(args.first ?? .undefined)
                let start = clampIndex(args.count > 1 ? args[1] : nil, b.length, 0)
                let end = clampIndex(args.count > 2 ? args[2] : nil, b.length, b.length)
                if start < end { for i in start..<end { b.setByte(i, value) } }
                return tv
            },
            Method("indexOf", 1) { tv, args, _, _ in
                let b = try receiver(Bytes.self, tv, "Uint8Array.prototype.indexOf")
                if b is BufferObj, let needle = needleBytes(args.first ?? .undefined) {
                    return .number(Double(search(b.data, needle, from: clampIndex(args.count > 1 ? args[1] : nil, b.length, 0))))
                }
                guard case .number(let n) = args.first ?? .undefined else { return .number(-1) }
                let from = clampIndex(args.count > 1 ? args[1] : nil, b.length, 0)
                let data = b.data
                for i in from..<data.count where Double(data[i]) == n { return .number(Double(i)) }
                return .number(-1)
            },
            Method("includes", 1) { tv, args, _, _ in
                let b = try receiver(Bytes.self, tv, "Uint8Array.prototype.includes")
                if b is BufferObj, let needle = needleBytes(args.first ?? .undefined) {
                    return .bool(search(b.data, needle, from: clampIndex(args.count > 1 ? args[1] : nil, b.length, 0)) >= 0)
                }
                guard case .number(let n) = args.first ?? .undefined else { return .bool(false) }
                return .bool(b.data.contains { Double($0) == n })
            },
            Method("at", 1) { tv, args, _, _ in
                let b = try receiver(Bytes.self, tv, "Uint8Array.prototype.at")
                var i = coerceToInteger(args.first ?? .undefined)
                if i < 0 { i += b.length }
                guard i >= 0, i < b.length else { return .undefined }
                return .number(Double(b.data[i]))
            },
            Method("reverse", 0) { tv, _, _, _ in
                let b = try receiver(Bytes.self, tv, "Uint8Array.prototype.reverse")
                b.data = b.data.reversed()
                return tv
            },
            Method("sort", 1) { tv, args, _, eval in
                let b = try receiver(Bytes.self, tv, "Uint8Array.prototype.sort")
                if let cmp = args.first, !cmp.isUndefined {
                    let cb = try requireCallback(cmp, "Uint8Array.sort")
                    var items = b.data
                    // Insertion sort keeps the comparator calls deterministic and the order stable.
                    var i = 1
                    while i < items.count {
                        var j = i
                        while j > 0 {
                            let r = coerceToNumber(try await eval.callCallable(.object(cb), thisValue: .undefined, args: [.number(Double(items[j - 1])), .number(Double(items[j]))], site: nil))
                            if r > 0 { items.swapAt(j - 1, j); j -= 1 } else { break }
                        }
                        i += 1
                    }
                    b.data = items
                } else {
                    b.data = b.data.sorted()
                }
                return tv
            },
        ])
        if let uint8ArrayCtor {
            methods(builtins, uint8ArrayCtor, [
                Method("from", 1) { _, args, _, eval in
                    let source = args.first ?? .undefined
                    let mapper: Callable? = args.count > 1 && !args[1].isUndefined ? try requireCallback(args[1], "Uint8Array.from") : nil
                    var items: [Value]
                    if case .object(let b as Bytes) = source {
                        items = b.data.map { .number(Double($0)) }
                    } else if case .object(let obj) = source, (try? requireIteratorMethod(source)) == nil {
                        let length = coerceToInteger(get(obj, "length"))
                        items = (0..<max(0, length)).map { get(obj, JSString(String($0))) }
                    } else {
                        items = try await eval.collectIterable(source)
                    }
                    if let mapper {
                        var mapped: [Value] = []
                        for (i, v) in items.enumerated() {
                            mapped.append(try await eval.callCallable(.object(mapper), thisValue: .undefined, args: [v, .number(Double(i))], site: nil))
                        }
                        items = mapped
                    }
                    return .object(Bytes(proto: builtins.Uint8Array, data: items.map { toUint8($0) }))
                },
                Method("of", 0) { _, args, _, _ in
                    .object(Bytes(proto: builtins.Uint8Array, data: args.map { toUint8($0) }))
                },
                Method("fromHex", 1) { _, args, _, _ in
                    guard case .string(let text) = args.first ?? .undefined else {
                        throw typeError("Uint8Array.fromHex expects a string.")
                    }
                    let units = text.utf16Units
                    let isAsciiHex: (UInt16) -> Bool = { u in
                        (u >= 0x30 && u <= 0x39) || (u >= 0x41 && u <= 0x46) || (u >= 0x61 && u <= 0x66)
                    }
                    guard units.count % 2 == 0, units.allSatisfy(isAsciiHex) else {
                        throw syntaxError("Uint8Array.fromHex received an invalid hex string.")
                    }
                    return .object(Bytes(proto: builtins.Uint8Array, data: encodeString(text, encoding: "hex")))
                },
            ])
        }

        methods(builtins, builtins.Buffer, [
            Method("toString", 3) { tv, args, _, _ in
                let b = try receiver(Bytes.self, tv, "Buffer.prototype.toString")
                let encoding = try bufferEncoding(args.first, builtins)
                let start = clampIndex(args.count > 1 ? args[1] : nil, b.length, 0)
                let end = clampIndex(args.count > 2 ? args[2] : nil, b.length, b.length)
                let data = b.data
                return .string(decodeBytes(start < end ? Array(data[start..<end]) : [], encoding: encoding))
            },
            Method("equals", 1) { tv, args, _, _ in
                let b = try receiver(Bytes.self, tv, "Buffer.prototype.equals")
                guard case .object(let other as Bytes) = args.first ?? .undefined else {
                    throw typeError("The \"otherBuffer\" argument must be an instance of Buffer or Uint8Array.")
                }
                return .bool(b.data == other.data)
            },
            Method("compare", 1) { tv, args, _, _ in
                let b = try receiver(Bytes.self, tv, "Buffer.prototype.compare")
                guard case .object(let other as Bytes) = args.first ?? .undefined else {
                    throw typeError("The \"target\" argument must be an instance of Buffer or Uint8Array.")
                }
                return .number(Double(compareBytes(b.data, other.data)))
            },
            Method("toJSON", 0) { tv, _, _, _ in
                let b = try receiver(Bytes.self, tv, "Buffer.prototype.toJSON")
                return .object(record(builtins, [
                    ("type", .string("Buffer")),
                    ("data", .object(Arr(proto: builtins.Array, items: b.data.map { .number(Double($0)) }))),
                ]))
            },
            Method("readUInt8", 1) { tv, args, _, _ in
                let b = try receiver(Bytes.self, tv, "Buffer.prototype.readUInt8")
                let offset = args.first.map { $0.isUndefined ? 0 : coerceToInteger($0) } ?? 0
                guard offset >= 0, offset < b.length else {
                    throw rangeError("The value of \"offset\" is out of range. It must be >= 0 and <= \(b.length - 1). Received \(offset)")
                }
                return .number(Double(b.data[offset]))
            },
            Method("write", 4) { tv, args, _, _ in
                let b = try receiver(Bytes.self, tv, "Buffer.prototype.write")
                let text = coerceToString(args.first ?? .undefined)
                var offset = 0
                var encodingArg: Value? = nil
                if args.count > 1, case .string = args[1] { encodingArg = args[1] } else if args.count > 1 { offset = coerceToInteger(args[1]) }
                if args.count > 3 { encodingArg = args[3] } else if args.count > 2, case .string = args[2] { encodingArg = args[2] }
                let bytes = encodeString(text, encoding: try bufferEncoding(encodingArg, builtins))
                let count = min(bytes.count, max(0, b.length - offset))
                for i in 0..<count { b.setByte(offset + i, bytes[i]) }
                return .number(Double(count))
            },
        ])
        if let bufferCtor {
            let oldFrom = get(bufferCtor, "from")
            methods(builtins, bufferCtor, [
                Method("from", 3) { thisVal, args, site, eval in
                    if case .string(let text) = args.first ?? .undefined {
                        let encoding = try bufferEncoding(args.count > 1 ? args[1] : nil, builtins)
                        return .object(BufferObj(proto: builtins.Buffer, data: encodeString(text, encoding: encoding)))
                    }
                    return try await eval.callCallable(oldFrom, thisValue: thisVal, args: args, site: site)
                },
                Method("alloc", 3) { _, args, _, _ in
                    let size = coerceToNumber(args.first ?? .undefined)
                    guard size.isFinite, size >= 0, size == size.rounded(.towardZero) else {
                        throw rangeError("The argument 'size' is invalid. Received \(coerceToString(args.first ?? .undefined))")
                    }
                    var data = Array(repeating: UInt8(0), count: Int(size))
                    if args.count > 1, !args[1].isUndefined {
                        let pattern: [UInt8]
                        if case .string(let s) = args[1] {
                            pattern = encodeString(s, encoding: try bufferEncoding(args.count > 2 ? args[2] : nil, builtins))
                        } else if case .object(let b as Bytes) = args[1] {
                            pattern = b.data
                        } else {
                            pattern = [toUint8(args[1])]
                        }
                        if !pattern.isEmpty { for i in 0..<data.count { data[i] = pattern[i % pattern.count] } }
                    }
                    return .object(BufferObj(proto: builtins.Buffer, data: data))
                },
                Method("byteLength", 2) { _, args, _, _ in
                    if case .object(let b as Bytes) = args.first ?? .undefined { return .number(Double(b.length)) }
                    let encoding = try bufferEncoding(args.count > 1 ? args[1] : nil, builtins)
                    return .number(Double(encodeString(coerceToString(args.first ?? .undefined), encoding: encoding).count))
                },
                Method("compare", 2) { _, args, _, _ in
                    guard case .object(let a as Bytes) = args.first ?? .undefined, case .object(let b as Bytes) = args.count > 1 ? args[1] : .undefined else {
                        throw typeError("Buffer.compare expects two Buffers or Uint8Arrays.")
                    }
                    return .number(Double(compareBytes(a.data, b.data)))
                },
                Method("isEncoding", 1) { _, args, _, _ in
                    guard case .string(let s) = args.first ?? .undefined, let wf = s.wellFormedString else { return .bool(false) }
                    return .bool(bufferEncodings.contains(wf.lowercased()))
                },
            ])
        }
    }

    static func compareBytes(_ a: [UInt8], _ b: [UInt8]) -> Int {
        for (x, y) in zip(a, b) where x != y { return x < y ? -1 : 1 }
        return a.count == b.count ? 0 : (a.count < b.count ? -1 : 1)
    }
}
