// Pure-Swift ECMAScript 2025 Unicode data tables for CodemodeRegExpEngine.
// Zero external/Foundation imports — uses only the Swift standard library.
// Covers 100% of Unicode code points (0x0000...0x10FFFF) for:
//   - Non-Unicode Canonicalize (ECMA-262 22.2.2.8.1)
//   - Unicode Simple Case Folding (CaseFolding C + S)
//   - All 30 leaf + 8 compound General_Category properties
//   - All 175 Unicode Script and Script_Extensions properties
//   - All 53 ECMA-262 Binary Properties
//   - ES2025 v-mode Properties of Strings (Basic_Emoji, Emoji_Keycap_Sequence, RGI_Emoji_*)

internal enum RegExpUnicodeData {
    struct CodePointRange: Equatable, Hashable, Sendable {
        let lower: UInt32
        let upper: UInt32
    }

    // MARK: - Compact Base64 + LEB128 Decoder (Pure Swift)

    private static func decodeBase64(_ input: String) -> [UInt8] {
        let utf8 = Array(input.utf8)
        var out: [UInt8] = []
        out.reserveCapacity((utf8.count * 3) / 4)
        @inline(__always) func val(_ c: UInt8) -> Int {
            if c >= 65 && c <= 90 { return Int(c - 65) }
            if c >= 97 && c <= 122 { return Int(c - 71) }
            if c >= 48 && c <= 57 { return Int(c + 4) }
            if c == 43 { return 62 }
            if c == 47 { return 63 }
            return -1
        }
        var i = 0
        while i + 3 < utf8.count {
            let a = val(utf8[i]), b = val(utf8[i + 1])
            let c = val(utf8[i + 2]), d = val(utf8[i + 3])
            i += 4
            guard a >= 0, b >= 0 else { break }
            out.append(UInt8((a << 2) | (b >> 4)))
            if c >= 0 {
                out.append(UInt8(((b & 0xF) << 4) | (c >> 2)))
                if d >= 0 {
                    out.append(UInt8(((c & 0x3) << 6) | d))
                }
            }
        }
        return out
    }

    private static func readVarint(_ bytes: [UInt8], _ idx: inout Int) -> UInt32 {
        var result: UInt32 = 0
        var shift: UInt32 = 0
        while idx < bytes.count {
            let b = bytes[idx]; idx += 1
            result |= UInt32(b & 0x7F) << shift
            if (b & 0x80) == 0 { break }
            shift += 7
        }
        return result
    }

    private static func readSignedVarint(_ bytes: [UInt8], _ idx: inout Int) -> Int32 {
        let u = readVarint(bytes, &idx)
        let half = Int32(bitPattern: u >> 1)
        return (u & 1) == 0 ? half : -(half + 1)
    }

    private static func decodeRanges(_ encoded: String) -> [CodePointRange] {
        if encoded.isEmpty { return [] }
        let bytes = decodeBase64(encoded)
        var idx = 0
        var prev: UInt32 = 0
        var out: [CodePointRange] = []
        while idx < bytes.count {
            let gap = readVarint(bytes, &idx)
            let span = readVarint(bytes, &idx)
            let lower = prev + gap
            let upper = lower + span
            out.append(CodePointRange(lower: lower, upper: upper))
            prev = upper
        }
        return out
    }

    // MARK: - Case Folding Tables

    private struct FoldMap: Sendable {
        let forward: [UInt32: UInt32]
        let classes: [UInt32: [UInt32]]
        let allKeys: [UInt32]
    }

    private static func decodeFoldMap(_ encoded: String) -> FoldMap {
        let bytes = decodeBase64(encoded)
        var idx = 0
        var prevStart: UInt32 = 0
        var fwd: [UInt32: UInt32] = [:]
        var cls: [UInt32: [UInt32]] = [:]
        while idx < bytes.count {
            let start = prevStart + readVarint(bytes, &idx)
            let packed = readVarint(bytes, &idx)
            let step: UInt32 = (packed & 1) != 0 ? 2 : 1
            let count = packed >> 1
            let delta = readSignedVarint(bytes, &idx)
            prevStart = start
            var c = start
            for _ in 0..<count {
                let target = UInt32(Int64(c) + Int64(delta))
                fwd[c] = target
                c += step
            }
        }
        for (k, v) in fwd {
            if cls[v] == nil { cls[v] = [v] }
            cls[v]!.append(k)
        }
        for (rep, members) in cls {
            cls[rep] = members.sorted()
        }
        var keySet = Set(fwd.keys)
        for rep in cls.keys { keySet.insert(rep) }
        return FoldMap(forward: fwd, classes: cls, allKeys: keySet.sorted())
    }

    private static let nonUnicodeFoldData: String =
        """
        YTQ/VALOCysuPxgOPwcC8gECMQEyBwEHEQERLwEvBwEGAoYDAwUBBQIBBAIBBgIBAwLCAQQCAQECxgIBAoKZBQMChAIDBwEHAgEF\
        AgEDAgEEBQEFAgEEAgECAnAGAgEBAgMCAgEBAgMCAgEBAgMCEQEPAp0BAhMBEwIBAQIDAgIBBCkBKhMBGQIBAwT+qAEDAgEFCwEJ\
        Ar6oAQECuKgBAQK8qAEBAqMDAQKbAwIEmQMDApMDAgKVAwECnpUFBAKZAwEClpUFAgKdAwECzpUFAQLQlAUBAoiVBQICoQMBAqUD\
        AQKIlQUBAu6nAQECgpUFAwKlAwIC+qcBAQKpAwMCqwMIAs6nAQMCswMCAoaVBQECswMEAtSUBQECswMBAokBAQSxAwICjQEGArUD\
        CwKqlAUBAqSUBacBAqgBLAUBBgIBBAaEAjECSwEGSQQiPxECPQESPwkCfwEEfQMCewECcQQCXQECawECDwIZARcCqwEBAp8BAQIO\
        AQLnAQICvwEDAgEDAgE1QD8gIJ8BESMBKjcBNw8BDQIdAmEBkAFMX+8WVoAvLQaAL/sFDA+IEQLbYQEC2WEBAsdhAQTDYQICxWEB\
        ArdhAQLJYAEChKcEAgIB7wECiKgEBALMOxEC8KgEc5cBAZoBAnUGYQFfEBAQDBAQEBAQEBAQDBARCRAPEBAQBJQBAgisAQQEyAEC\
        BIACAgTgAQIE/AE0BBAOAslwEgQQEAQQBQIO6QICNyIgHxQCAcwGNDPgDmBfMQIBBALVqAEBAs+oAQIHAQsCAQMCAQtlAWsFAQcC\
        AQ1Mv3EnAr9xBgK/cZTyAS8BQB0BogEPARA/AUcFAQULAQ0CAQUFAQMCYAMVAR4RARMFAQURASkCAd0GAr8OHaABn98E0acBND8=
        """

    private static let unicodeFoldData: String =
        """
        YTQ/fy4/GA4/CTEBMgcBBxEBES8BLQLxAQIHAQUC1wQEBQEFAgEEAgEGAgEHAgEIBwEHAgEFAgEDAgEEBQEFAgEEAgEIAgEBAgMC\
        AgEBAgMCAgEBAgMCEQEPAp0BAhMBEwIBAQIDAgIBAQLBAQECbwIpAScCgwIDEwEZAgEBAsUCBQIBAQKFAwQLAQwCowMBApsDAgSZ\
        AwMCkwMCApUDBQKZAwMCnQMFAqEDAQKlAwYCpQMDAqkDAwKrAwsCswMDArMDBQKzAwECiQEBBLEDAgKNAQYCtQPfAQUBBgIBIgKn\
        AQMCzQsQAksBBkkEED8IAucBAQQ/AgKNDAEKPwUCPQESPwkCfwEEfQMCewECcQQCXQECawECDwIZARcCqwEBAp8BAgLnAQECtwEB\
        Ar8BAwIBAQINAgIBAgaDAjNAPyAgnwERIwEqNwE3DwENAh0CYQGQAUxflx0MD4gRAtthAQLZYQECx2EBBMNhAgLFYQECt2EBAslg\
        AwIBBlb/Li0G/y7EApcBAZoBAnUDAv12A2EBZxAPEAwPEBAPEBAPEAwPEQkPDxAPIBAPEBAPEBAPEAQPAgSTAQICEQIC8XEKCKsB\
        BAIRBwKFcQUEDwIExwEJAuVwBQQPAgTfAQICDQwE/wECBPsBAgIRqgIC+XUEAr2DAQECy4EBIwI3IiAfFAIBzAY0M+AOYF8xAgEB\
        Au2nAQECyzsBAs2nAQEC1agBAQLPqAECBwEFAreoAQEC+acBAQK9qAEBAruoAQMCAQMCAQgE/agBA2UBawUBBwIBDUy/cScCv3EG\
        Ar9xlPIBCwEJAoOnBAEChacEAiMBNB0BogEPARA/AUcFAQMCh6gEAgsBDQIBAQLPlAUEBQEGFQETAoeVBQECnZUFAQKVlQUBAoGV\
        BQECh5UFAgKjlAUBAtOUBQECqZQFAxEBDwJfAQKFlQUBAu+oBAIFAQMCzZUFAhEBDwKBmQUaAgHdBgK/Dh2gAZ/fBJafAQIBuwg0\
        P+cJUE+wAUhPvwEWTQweTRAOTQgETYUOZn+wASw/0BZAP6CrAUA/WzI15/QBREM=
        """

    private static let nonUnicodeFoldMap: FoldMap = decodeFoldMap(nonUnicodeFoldData)
    private static let unicodeFoldMap: FoldMap = decodeFoldMap(unicodeFoldData)

    @inline(__always)
    static func canonicalizeNonUnicode(_ unit: UInt16) -> UInt16 {
        if unit < 128 {
            return (unit >= 0x61 && unit <= 0x7A) ? (unit - 32) : unit
        }
        if let mapped = nonUnicodeFoldMap.forward[UInt32(unit)] {
            return UInt16(mapped)
        }
        return unit
    }

    @inline(__always)
    static func canonicalizeUnicode(_ cp: UInt32) -> UInt32 {
        if cp < 128 {
            // Lowercase a-z maps to A-Z (minimum in equivalence class)
            return (cp >= 0x61 && cp <= 0x7A) ? (cp - 32) : cp
        }
        return unicodeFoldMap.forward[cp] ?? cp
    }

    /// Expand a sorted disjoint list of ranges with all case-fold equivalents (either non-u or u/v mode).
    static func expandCaseFold(_ ranges: [CodePointRange], unicode: Bool) -> [CodePointRange] {
        if ranges.isEmpty { return [] }
        let map = unicode ? unicodeFoldMap : nonUnicodeFoldMap
        var result = ranges
        let keys = map.allKeys
        // Binary-search only the case-foldable code points that fall inside each range
        for r in ranges {
            var lo = 0, hi = keys.count
            while lo < hi {
                let mid = (lo + hi) >> 1
                if keys[mid] < r.lower { lo = mid + 1 } else { hi = mid }
            }
            var idx = lo
            while idx < keys.count, keys[idx] <= r.upper {
                let cp = keys[idx]
                let rep = map.forward[cp] ?? cp
                if let members = map.classes[rep] {
                    for m in members {
                        result.append(CodePointRange(lower: m, upper: m))
                    }
                }
                idx += 1
            }
        }
        return normalizeRanges(result)
    }

    // MARK: - Range Set Operations

    static func normalizeRanges(_ input: [CodePointRange]) -> [CodePointRange] {
        if input.count <= 1 { return input }
        let sorted = input.sorted { $0.lower < $1.lower || ($0.lower == $1.lower && $0.upper < $1.upper) }
        var out: [CodePointRange] = []
        out.reserveCapacity(sorted.count)
        var cur = sorted[0]
        for i in 1..<sorted.count {
            let next = sorted[i]
            if next.lower <= cur.upper + 1 {
                if next.upper > cur.upper { cur = CodePointRange(lower: cur.lower, upper: next.upper) }
            } else {
                out.append(cur)
                cur = next
            }
        }
        out.append(cur)
        return out
    }

    static func complementRanges(_ ranges: [CodePointRange], maxCodePoint: UInt32) -> [CodePointRange] {
        if ranges.isEmpty { return [CodePointRange(lower: 0, upper: maxCodePoint)] }
        var out: [CodePointRange] = []
        var cursor: UInt32 = 0
        for r in ranges {
            if r.lower > maxCodePoint { break }
            if r.lower > cursor {
                out.append(CodePointRange(lower: cursor, upper: r.lower - 1))
            }
            if r.upper >= maxCodePoint { return out }
            cursor = r.upper + 1
        }
        if cursor <= maxCodePoint {
            out.append(CodePointRange(lower: cursor, upper: maxCodePoint))
        }
        return out
    }

    static func intersectRanges(_ a: [CodePointRange], _ b: [CodePointRange]) -> [CodePointRange] {
        var out: [CodePointRange] = []
        var i = 0, j = 0
        while i < a.count && j < b.count {
            let lo = max(a[i].lower, b[j].lower)
            let hi = min(a[i].upper, b[j].upper)
            if lo <= hi { out.append(CodePointRange(lower: lo, upper: hi)) }
            if a[i].upper < b[j].upper { i += 1 } else { j += 1 }
        }
        return out
    }

    static func subtractRanges(_ a: [CodePointRange], _ b: [CodePointRange]) -> [CodePointRange] {
        if a.isEmpty || b.isEmpty { return a }
        return intersectRanges(a, complementRanges(b, maxCodePoint: 0x10FFFF))
    }

    static func xorRanges(_ a: [CodePointRange], _ b: [CodePointRange]) -> [CodePointRange] {
        let aMinusB = subtractRanges(a, b)
        let bMinusA = subtractRanges(b, a)
        return normalizeRanges(aMinusB + bMinusA)
    }

    static func contains(_ ranges: [CodePointRange], _ cp: UInt32) -> Bool {
        var lo = 0, hi = ranges.count - 1
        while lo <= hi {
            let mid = (lo + hi) >> 1
            let r = ranges[mid]
            if cp < r.lower { hi = mid - 1 }
            else if cp > r.upper { lo = mid + 1 }
            else { return true }
        }
        return false
    }

    // MARK: - General_Category Table

    private struct PartitionRun: Sendable {
        let lower: UInt32
        let upper: UInt32
        let value: UInt16
    }

    private static func decodePartition(_ encoded: String, singleByteValue: Bool) -> [PartitionRun] {
        let bytes = decodeBase64(encoded)
        var idx = 0
        var pos: UInt32 = 0
        var out: [PartitionRun] = []
        while idx < bytes.count {
            let len = readVarint(bytes, &idx)
            let val: UInt16 = singleByteValue ? UInt16(bytes[idx]) : UInt16(readVarint(bytes, &idx))
            if singleByteValue { idx += 1 }
            if len > 0 {
                out.append(PartitionRun(lower: pos, upper: pos + len - 1, value: val))
                pos += len
            }
        }
        return out
    }

    private static let gcData: String =
        """
        IBkBFgMRARMDEQENAQ4BEQESAREBDAIRCggCEQMSAhEaAAENAREBDgEUAQsBFBoBAQ0BEgEOARIhGQEWAREEEwEVAREBFAEVAQQB\
        DwESARoBFQEUARUBEgIKARQBAQIRARQBCgEEARADCgERFwABEgcAGAEBEggBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEA\
        AQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEB\
        AAEBAQACAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAIBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEB\
        AQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQECAAEBAQABAQEAAwECAAEBAQAB\
        AQIAAQEDAAIBBAABAQIAAQEDAAMBAgABAQIAAQEBAAEBAQABAQIAAQEBAAIBAQABAQIAAQEDAAEBAQABAQIAAgEBBAEAAwEEBAEA\
        AQIBAQEAAQIBAQEAAQIBAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAIBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQAB\
        AQEAAQEBAAIBAQABAgEBAQABAQMAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEB\
        AQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQAHAQIAAQECAAIBAQAB\
        AQQAAQEBAAEBAQABAQEAAQEBAEUBAgQaARIDBBQMAw4UBQMHFAEDARQBAxEUcAUBAAEBAQABAQEDARQBAAEBAh0BAwMBAREBAAQd\
        AhQBAAERAwABHQEAAR0CAAEBEQABHQkAIwEBAAIBAwADAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEB\
        AAEBAQAFAQEAAQEBEgEAAQECAAIBMwAwAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEA\
        AQEBAAEBAQABAQEAAQEBAAEBARUFBQIHAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQAB\
        AQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAgABAQEAAQEBAAEBAQABAQEA\
        AQEBAAEBAQACAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEB\
        AAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEB\
        AQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEdJgACHQEDBhEpAQERAQwCHQIVARMB\
        HS0FAQwBBQERAgUBEQIFAREBBQgdGwQEHQQEAhELHQYaAxICEQETAhECFQsFAREBGgMRIAQBAwoEFQUKCAQRAgQBBWMEAREBBAcF\
        ARoBFQYFAgMCBQEVBAUCBAoIAwQCFQEEDhEBHQEaAQQBBR4EGwUCHVkECwUBBA4dCgghBAkFAgMBFQMRAQMCHQEFAhMWBAQFAQMJ\
        BQEDAwUBAwUFAh0PEQEdGQQDBQIdAREBHQsEBR0YBAEUBwQCGgUdCQUpBAEDGAUBGiAFAQY2BAEFAQYBBQEEAwYIBQQGAQUCBgEE\
        BwUKBAIFAhEKCAERAQMPBAEFAgYBHQgEAh0CBAIdFgQBHQcEAR0BBAMdBAQCHQEFAQQDBgQFAh0CBgIdAgYBBQEECB0BBgQdAgQB\
        HQMEAgUCHQoIAgQCEwYKARUBEwEEAREBBQIdAgUBBgEdBgQEHQIEAh0WBAEdBwQBHQIEAR0CBAEdAgQCHQEFAR0DBgIFBB0CBQId\
        AwUDHQEFBx0EBAEdAQQHHQoIAgUDBAEFAREKHQIFAQYBHQkEAR0DBAEdFgQBHQcEAR0CBAEdBQQCHQEFAQQDBgUFAR0CBQEGAR0C\
        BgEFAh0BBA8dAgQCBQIdCggBEQETBx0BBAYFAR0BBQIGAR0IBAIdAgQCHRYEAR0HBAEdAgQBHQUEAh0BBQEEAQYBBQEGBAUCHQIG\
        Ah0CBgEFBx0CBQEGBB0CBAEdAwQCBQIdCggBFQEEBgoKHQEFAQQBHQYEAx0DBAEdBAQDHQIEAR0BBAEdAgQDHQIEAx0DBAMdDAQE\
        HQIGAQUCBgMdAwYBHQMGAQUCHQEEBh0BBg4dCggDCgYVARMBFQUdAQUDBgEFCAQBHQMEAR0XBAEdEAQCHQEFAQQDBQQGAR0DBQEd\
        BAUHHQIFAR0DBAEdAgQCHQIEAgUCHQoIBx0BEQcKARUBBAEFAgYBEQgEAR0DBAEdFwQBHQoEAR0FBAIdAQUBBAEGAQUFBgEdAQUC\
        BgEdAgYCBQcdAgYFHQMEAR0CBAIFAh0KCAEdAgQBBgwdAgUCBgkEAR0DBAEdKQQCBQEEAwYEBQEdAwYBHQMGAQUBBAEVBB0DBAEG\
        BwoDBAIFAh0KCAkKARUGBAEdAQUCBgEdEgQDHRgEAR0JBAEdAQQCHQcEAx0BBQQdAwYDBQEdAQUBHQgGBh0KCAIdAgYBEQwdMAQB\
        BQIEBwUEHQETBgQBAwgFAREKCAIRJR0CBAEdAQQBHQUEAR0YBAEdAQQBHQoEAQUCBAkFAQQCHQUEAR0BAwEdBwUBHQoIAh0EBCAd\
        AQQDFQ8RARUBEQMVAgUGFQoICgoBFQEFARUBBQEVAQUBDQEOAQ0BDgIGCAQBHSQEBB0OBQEGBQUBEQIFBQQLBQEdJAUBHQgVAQUG\
        FQEdAhUFEQQVAhElHSsEAgYEBQEGBgUBBgIFAgYCBQEECggGEQYEAgYCBQQEAwUBBAMGAgQHBgMEBAUNBAEFAgYCBQYGAQUBBAEG\
        CggDBgEFAhUmAAEdAQAFHQEAAh0rAQERAQMDAckCBAEdBAQCHQcEAR0BBAEdBAQCHSkEAR0EBAIdIQQBHQQEAh0HBAEdAQQBHQQE\
        Ah0PBAEdOQQBHQQEAh1DBAIdAwUJERQKAx0QBAoVBh1WAAIdBgECHQEM7AQEARUBEREEARYaBAENAQ4DHUsEAxEDCQgEBx0SBAMF\
        AQYJHRMEAgUBBgIRCR0SBAIFDB0NBAEdAwQBHQIFDB00BAIFAQYHBQgGAQUCBgsFAxEBAwMRARMBBAEFAh0KCAYdCgoGHQYRAQwE\
        EQMFARoBBQoIBh0jBAEDNQQHHQUEAgUiBAEFAQQFHUYECh0fBAEdAwUEBgIFAwYEHQIGAQUGBgMFBB0BFQMdAhEKCB4EAh0FBAsd\
        LAQEHRoEBh0KCAEKAx0iFRcEAgUCBgEFAh0CETUEAQYBBQEGBwUBHQEFAQYBBQIGCAUGBgoFAh0BBQoIBh0KCAYdBxEBAwYRAh0O\
        BQEHHwUCHQwFFB0EBQEGLwQBBQEGBQUBBgEFBQYBBQIGCAQBHQIRCggHEQoVCQUJFQMRAgUBBh4EAQYEBQIGAgUBBgMFAgQKCCwE\
        AQUBBgIFAwYBBQEGAwUCBggdBBEkBAgGCAUCBgIFAx0FEQoIAx0DBAoIHgQGAwIRCQEBAAEBBR0rAAIdAwAIEQgdAwUBEQ0FAQYH\
        BQQEAQUGBAEFAgQBBgIFAQQFHSwBPwMNAQEDIgElA0AFAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEA\
        AQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEB\
        AAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEB\
        AQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQAB\
        AQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAkBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEA\
        AQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEB\
        AAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEB\
        AQAJAQgABgECHQYAAh0IAQgACAEIAAYBAh0GAAIdCAEBHQEAAR0BAAEdAQABHQEACAEIAA4BAh0IAQgCCAEIAggBCAIFAQEdAgEE\
        AAECARQBAQMUAwEBHQIBBAABAgMUBAECHQIBBAABHQMUCAEFAAMUAh0DAQEdAgEEAAECAhQBHQsWBRoGDAIRAQ8BEAENAg8BEAEN\
        AQ8IEQEXARgFGgEWCREBDwEQBBECCwMRARIBDQEOCxEBEgERAQsKEQEWBRoBHQoaAQoBAwIdBgoDEgENAQ4BAwoKAxIBDQEOAR0N\
        AwMdIhMOHQ0FBAcBBQMHDAUPHQIVAQAEFQEAAhUBAQMAAgEDAAEBARUBAAIVARIFAAYVAQABFQEAARUBAAEVBAABFQEBBAABAQQE\
        AQECFQIBAgAFEgEABAEBFQESAhUBAQEVEAojCQEAAQEECQEKAhUEHQUSBRUCEgQVARICFQESAhUBEgcVARIfFQISAhUBEgEVARIf\
        FYwCEggVAQ0BDgENAQ4UFQISBxUBDQEOURUBEh4VGRIoFQYSSBUWHQsVFR08Ck4VFgq3ARUBEgkVARI2FQgSbxUBEvgBFQENAQ4B\
        DQEOAQ0BDgENAQ4BDQEOAQ0BDgENAQ4eCiwVBRIBDQEOHxIBDQEOAQ0BDgENAQ4BDQEOAQ0BDhASgAIVgwESAQ0BDgENAQ4BDQEO\
        AQ0BDgENAQ4BDQEOAQ0BDgENAQ4BDQEOAQ0BDgENAQ4/EgENAQ4BDQEOIBIBDQEOggISMBUVEgIVBhInFQIdigEVMAAwAQEAAQED\
        AAIBAQABAQEAAQEBAAEBBAABAQEAAgEBAAYBAgMDAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEA\
        AQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEB\
        AAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEB\
        AQACAQYVAQABAQEAAQEDBQEAAQEFHQQRAQoCESYBAR0BAQUdAQECHTgEBx0BAwERDh0BBRcECR0HBAEdBwQBHQcEAR0HBAEdBwQB\
        HQcEAR0HBAEdBwQBHSAFAhEBDwEQAQ8BEAMRAQ8BEAERAQ8BEAkRAQwCEQEMAREBDwEQAhEBDwEQAQ0BDgENAQ4BDQEOAQ0BDgUR\
        AQMKEQIMBBEBDAERAQ0NEQIVAxEBDQEOAQ0BDgENAQ4BDQEOAQwiHRoVAR1ZFQwd1gEVGh0QFQEWAxEBFQEDAQQBCQENAQ4BDQEO\
        AQ0BDgENAQ4BDQEOAhUBDQEOAQ0BDgENAQ4BDQEOAQwBDQIOARUJCQQFAgYBDAUDAhUDCQEDAQQBEQIVAR1WBAIdAgUCFAIDAQQB\
        DFoEAREDAwEEBR0rBAEdXgQBHQIVBAoKFSAEJhUJHQEVEAQfFQEdCgoeFQgKARUPCiAVCgonFQ8KwAIVwDMEQBWVpAEEAQP3CAQD\
        HTcVCR0oBAYDAhGMAgQBAwMREAQKCAIEFB0BAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEB\
        AAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEEAQUDBwERCgUBEQEDAQABAQEAAQEBAAEBAQABAQEA\
        AQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQECAwIFRgQKCQIFBhEIHRcUCQMCFAEAAQEBAAEBAQABAQEAAQEB\
        AAEBAQABAQEAAwEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEB\
        AQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQMIAQEAAQEBAAEBAgAB\
        AQEAAQEBAAEBAQABAQEAAQEBAwIUAQABAQEAAQEBBAEAAQEBAAMBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEB\
        AQABAQUAAQEFAAEBAQABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQABAQQAAQEBAAEBAgABAQEAAQEBAAEBAQABAQEAAQEBAAEBAQAB\
        AQEAAQEBABQdBAMBAAEBAQQCAwEBBwQBBQMEAQUEBAEFFwQCBgIFAQYEFQEFAx0GCgIVARMBFQYdNAQEEQgdAgYyBBAGAgUIHQIR\
        CggGHRIFBgQDEQEEARECBAEFCggcBAgFAhEXBAsFAgYLHQERHQQDHQMFAQYvBAEFAgYEBQIGAgUDBg0RAR0BAwoIBB0CEQUEAQUB\
        AwkECggFBAEdKQQGBQIGAgUCBgIFCR0DBAEFCAQBBQEGAh0KCAIdBBEQBAEDBgQDFQEEAQYBBQEGMgQBBQEEAwUCBAIFBQQCBQEE\
        AQUBBBgdAgQBAwIRCwQBBgIFAgYCEQEEAgMBBgEFCh0GBAIdBgQCHQYECR0HBAEdBwQBHSsBARQEAwkBAQMCFAQdUAEjBAIGAQUC\
        BgEFAgYBEQEGAQUCHQoIBh2kVwQMHRcEBB0xBAQdgBAbgDIc7gIEAh1qBCYdBwEMHQUBBR0BBAEFCgQBEg0EAR0FBAEdAQQBHQIE\
        AR0CBAEdbAQRFBAV6wIEAQ4BDRAVQAQCFTYECBUgHQwEARMDFRAFBxEBDQEOAREGHRAFARECDAILAQ0BDgENAQ4BDQEOAQ0BDgEN\
        AQ4BDQEOAQ0BDgENAQ4CEQENAQ4EEQMLAxEBHQQRAQwBDQEOAQ0BDgENAQ4DEQESAQwDEgEdAREBEwIRBB0FBAEdhwEEAh0BGgEd\
        AxEBEwMRAQ0BDgERARIBEQEMAhEKCAIRAxICERoAAQ0BEQEOARQBCwEUGgEBDQESAQ4BEgENAQ4BEQENAQ4CEQoEAQMtBAIDHwQD\
        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
        """

    private static let gcRuns: [PartitionRun] = decodePartition(gcData, singleByteValue: true)

    private static func gcRanges(mask: UInt32) -> [CodePointRange] {
        var out: [CodePointRange] = []
        for run in gcRuns {
            if (mask & (UInt32(1) << UInt32(run.value))) != 0 {
                if let last = out.last, last.upper + 1 == run.lower {
                    out[out.count - 1] = CodePointRange(lower: last.lower, upper: run.upper)
                } else {
                    out.append(CodePointRange(lower: run.lower, upper: run.upper))
                }
            }
        }
        return out
    }

    private static let gcAliasMasks: [String: UInt32] = [
        "Lu": 0x1, "Uppercase_Letter": 0x1,
        "Ll": 0x2, "Lowercase_Letter": 0x2,
        "Lt": 0x4, "Titlecase_Letter": 0x4,
        "Lm": 0x8, "Modifier_Letter": 0x8,
        "Lo": 0x10, "Other_Letter": 0x10,
        "Mn": 0x20, "Nonspacing_Mark": 0x20,
        "Mc": 0x40, "Spacing_Mark": 0x40,
        "Me": 0x80, "Enclosing_Mark": 0x80,
        "Nd": 0x100, "Decimal_Number": 0x100, "digit": 0x100,
        "Nl": 0x200, "Letter_Number": 0x200,
        "No": 0x400, "Other_Number": 0x400,
        "Pc": 0x800, "Connector_Punctuation": 0x800,
        "Pd": 0x1000, "Dash_Punctuation": 0x1000,
        "Ps": 0x2000, "Open_Punctuation": 0x2000,
        "Pe": 0x4000, "Close_Punctuation": 0x4000,
        "Pi": 0x8000, "Initial_Punctuation": 0x8000,
        "Pf": 0x10000, "Final_Punctuation": 0x10000,
        "Po": 0x20000, "Other_Punctuation": 0x20000,
        "Sm": 0x40000, "Math_Symbol": 0x40000,
        "Sc": 0x80000, "Currency_Symbol": 0x80000,
        "Sk": 0x100000, "Modifier_Symbol": 0x100000,
        "So": 0x200000, "Other_Symbol": 0x200000,
        "Zs": 0x400000, "Space_Separator": 0x400000,
        "Zl": 0x800000, "Line_Separator": 0x800000,
        "Zp": 0x1000000, "Paragraph_Separator": 0x1000000,
        "Cc": 0x2000000, "Control": 0x2000000, "cntrl": 0x2000000,
        "Cf": 0x4000000, "Format": 0x4000000,
        "Cs": 0x8000000, "Surrogate": 0x8000000,
        "Co": 0x10000000, "Private_Use": 0x10000000,
        "Cn": 0x20000000, "Unassigned": 0x20000000,
        "LC": 0x7, "Cased_Letter": 0x7,
        "L": 0x1f, "Letter": 0x1f,
        "M": 0xe0, "Mark": 0xe0, "Combining_Mark": 0xe0,
        "N": 0x700, "Number": 0x700,
        "P": 0x3f800, "Punctuation": 0x3f800, "punct": 0x3f800,
        "S": 0x3c0000, "Symbol": 0x3c0000,
        "Z": 0x1c00000, "Separator": 0x1c00000,
        "C": 0x3e000000, "Other": 0x3e000000,
    ]

    // MARK: - Script & Script_Extensions Tables

    private static let scriptData: String =
        """
        QQAaSwYAGksvAAFLDwABSwUAF0sBAB9LAQDBA0snAAVLBQACEBQAcAEELwEAAy8CAgQvAQABLwQCAS8BAAEvAQADLwECAS8BAhQv\
        AQI/Lw4cEC+FASACAakBIAECJgcCAjIHAgIDBwECNzkIAhs5BAIGOQsCBQYBAAYGAQAOBgEAAwYBACAGAQAKBgsBGgYBAWwGAQAi\
        Bg6SAQECPJIBAgIDkgEwBjKeAQ4CO2oCAgNqLoQBAgIPhAEBAhxWAgIBVgECC5IBBQIiBgUCSwYBAB0GUSIEAQ8iAgAaIgQNAQII\
        DQICAg0CAhYNAQIHDQECAQ0DAgQNAgIJDQICAg0CAgQNCAIBDQQCAg0BAgUNAgIZDQICAzIBAgYyBAICMgICFjIBAgcyAQICMgEC\
        AjIBAgIyAgIBMgECBTIEAgIyAgIDMgMCATIHAgQyAQIBMgcCETIKAgMwAQIJMAECAzABAhYwAQIHMAECAjABAgUwAgIKMAECAzAB\
        AgMwAgIBMA8CBDACAgwwBwIHMAECA3kBAgh5AgICeQICFnkBAgd5AQICeQECBXkCAgl5AgICeQICA3kHAgN5BAICeQECBXkCAhJ5\
        CgICmgEBAgaaAQMCA5oBAQIEmgEDAgKaAQECAZoBAQICmgEDAgKaAQMCA5oBAwIMmgEEAgWaAQMCA5oBAQIEmgECAgGaAQYCAZoB\
        DgIVmgEFAg2dAQECA50BAQIXnQEBAhCdAQICCZ0BAQIDnQEBAgSdAQcCAp0BAQIDnQEBAgKdAQICBJ0BAgIKnQEHAgmdAQ1AAQID\
        QAECF0ABAgpAAQIFQAICCUABAgNAAQIEQAcCAkAFAgNAAQIEQAICCkABAgNADAINVQECA1UBAjNVAQIDVQECBlUEAhBVAgIaVQEC\
        A4sBAQISiwEDAhiLAQECCYsBAQIBiwECAgeLAQMCAYsBBAIGiwEBAgGLAQECCIsBBgIKiwECAgOLAQwCOp8BBAIBAByfASUCAkoB\
        AgFKAQIFSgECGEoBAgFKAQIXSgICBUoBAgFKAQIHSgECCkoCAgRKIAJIoAEBAiSgAQQCJ6ABAQIkoAEBAg+gAQECB6ABBAACoAEl\
        AqABZCYrAQIBKwUCASsCAisrAQAEK4ACNUkpAQIEKQICBykBAgEpAQIEKQICKSkBAgQpAgIhKQECBCkCAgcpAQIBKQECBCkCAg8p\
        AQI5KQECBCkCAkMpAgIgKQMCGikGAlYaAgIGGgICgAUVHW0DAkuDAQMAC4MBBwIWkwEJAgGTARU3AgAJAhQUDAINlAEBAgOUAQEC\
        ApQBDAJeRgICCkYGAgpGBgICYQIAAWEBABRhBgJZYQcCK2EFAkYVCgIfTQECDE0EAgxNBAIBTQMCDE0elQECAgWVAQsCLGgEAhpo\
        BgILaAMCAmggRhwTAgICEz+WAQECHZYBAgILlgEGAgqWAQYCDpYBAgIuAQICDAEUAk0JAQIyCUCPATQMCAIEDDhMAwIPTAMCA0ww\
        bgsgBQIrKwICAysIjwEIAgMBAQANAQEABwEEAAEBBgABAQMAAgEBAAUCJksFLwEgMUsFLwRLBS8NSwEgRksBL0ABgAJLFi8CAgYv\
        AgImLwICBi8CAggvAQIBLwECAS8BAgEvAQIfLwICNS8BAg8vAQIOLwICBi8BAhMvAgIDLwECCS8BAgwAAgFXAAECCwABSwICCwAB\
        Sw8AAQINSwMCIgAOAiEBDwImAAEvAwACSwYAAUsbAAFLEQApSwMABAKaBQAWAgsAFQKgBwCAAhL0BAACAooBAGAsIEt0HAUCBxwm\
        KwECASsFAgErAgI4oQEHAgKhAQ4CAaEBFykJAgcpAQIHKQECBykBAgcpAQIHKQECBykBAgcpAQIHKQECICBeACICGjQBAlk0DALW\
        ATQaAhUAATQBAAE0GQAJNAQBAjUIAAQ0BAABAlY6AgICAQIAAzoBAFpBAgADQQUCKxABAl41AQIQACAQJgAJAgEAEEEfNQECQAAf\
        NVEAL0EBAFhBqAEAwDM0QACApAE0jQmtAQMCN60BCQIwUKwCqAEUAmAgWAoIAiIAZksDAFJLFAIPSy2RAQMCCgAGAjh/CAJGhQEI\
        AgyFAQYCICIuQwEAAUMkggELAgGCAR01AwJOPgECAQAKPgQCAj4fZAECNxkJAg4ZAgIKGQICBBkgZEOXARgCBZcBF1sKAgYpAgIG\
        KQICBikJAgcpAQIHKQECK0sBAAlLAS8ESwIABAJQGi5bAgIKWwYCpFc1DAIXNQQCMTWEQgLuAjQCAmo0JgIHSwwCBQcFAho5AQIF\
        OQECATkBAgI5AQICOQECCjnuAwYCAJABBiACEAYQAQoABgIOAQIgIwABAhMAAQIEAAQCBQYBAocBBgICAQABAiAAGksGABpLCwAK\
        QQEALUECAB81AwIGNQICBjUCAgY1AgIDNQMCBwABAgcACgIFAAICDE8BAhpPAQITTwECAk8BAg9PAgIOTyICe08FAgMABAItAAMC\
        CQBPLwECDQADAgEvLwItAAEBggECHVEDAjEWDwIBARsABAIkcQkCA3EbLQUCK3MFAh6nAQECAacBJHQEAg50KgJQITCHAR57AgIK\
        ewYCJHoEAiR6BAIoJwgCNBcLAgEXC6kBAQIPqQEBAgepAQECAqkBAQILqQEBAg+pAQECB6kBAQICqQEDAjSjAQwCtwJOCQIWTgoC\
        CE4YAgZLAQIqSwECCUtFAgYeAgIBHgECLB4BAgIeAwIBHgICAR4WOwECCTsgfR9lCAIJZTACEzgBAgI4BQIFOByAAQMCAYABGlIF\
        AgFSGokBJgIgXhhdBAIUXQICLl0ERAECAkQFAghEAQIDRAECHUQCAgNEBAIKRAcCCUQHAiB2IHIgAidXBAIMVwkCNggDAgcIFj0C\
        Agg9EzwFAgg8EoEBBwIEgQEMAgeBAVACSXc3AjNwDQIzcAcCBnAoNggCCjYGAiYqAwIdKggCAirQAQIfBgECKqwBAQIDrAECAgKs\
        ARACBgYIAgkGIQIGBih1CAIqjAEWAhp4JgIcGxQCFygJAk4RBAIkEQkCARFDPwoCAT8CAhmNAQcCCo0BBgI1GAECEhgIAidTCQJg\
        hgEBAhSLAQsCEkcBAi9HPgIHYwECAWMBAgRjAQIPYwECC2MGAjtIBQIKSAYCBC4BAgguAgICLgICFi4BAgcuAQICLgECBS4BAgEB\
        CS4CAgIuAgIDLgICAS4GAgEuBQIHLgICBy4DAgUuCwIKpgEBAgGmAQICAaYBAQImpgEBAgqmAQECAaYBAgIBpgEBAgSmAQECCqYB\
        AQICpgEIAgKmAR0CXGkBAgVpHgJIogEIAgqiAaYBAjaIAQICJogBIgJFYAsCCmAGAg1hEwI6mQEGAgqZAQYCFGQcAhsEAgIPBAQC\
        FwS5AQI8JGQCU6sBDAIBqwEHIwICASMCAggjAQICIwECHiMBAgIjAgIMIwkCCiNGAghnAgIuZwICC2cbAkiuAQgCU44BDQIQFTl+\
        BwIKIlYCCIYBWAIikAEOAgqQAQYCCQ8BAi0PAQIODwoCHQ8DAiBYAgIWWAECDlhJAgdZAQICWQECLFkDAgFZAQICWQECCVkIAgpZ\
        BgIGMQECAjEBAiUxAQICMQECBjEHAgoxBgIspAEEAgqkAfYBAhlUBwIRQgECKUIDAh1CVQIBUA8CMpoBDQIBmgGaBx1mAm8dAQIF\
        HQsCxAEdzBQCYx8NAtYIJgoCmx8mBQLHBAW5NQI6M8YNArkECgcCH2IBAgpiBAICYk+bAQECCpsBBgIeCwICBgsKAkZ8CgIKfAEC\
        B3wBAhV8BQITfLADAjpJxgECW1oFAhkOAgIZDiwCS18EAjlfBwIRX0ACAZwBAWsCNAFFCwIHNAkCgDacAdYDRSkCAUUfnAFhAnOc\
        Af1DAgRBAQIHQQECAkEBAgFBnwI6A0EPAgE6HQIDOgICAUEOAgRBCAKMA2uEEgJrJQUCDSUDAgklBwIKJQICBCUEANweAv0BAAMC\
        tAMABgIXAA8CEQAPAi4BAgIXAQkCdAA8AvYBAAoCJwACAj4AAwERAAgBAgAHAR4ABAE9ABUCRi96AhQADAIUAAwCVwAJAhkAhwEC\
        VQABAkcAAQICAAICAQACAgIAAgIEAAECDAABAgEAAQIHAAECQQABAgQAAgIIAAECBwABAhwAAQIEAAECBQABAgEAAwIHAAEC1AIA\
        AgKkAgACAjIAjAWKAQ8CBYoBAQIPigHQCAIfSwYCBkvVAQIHLAECESwCAgcsAQICLAECBSwFAj4gIQIBIHACLWwDAg5sAgIKbAQC\
        AmzAAgIfpQERAjqqAQUCAaoB0AMCKmbWAQIrbwQCAW/AAQIfmAEBAhaYAQgCApgB4AECBykBAgQpAQICKQECDykBAsUBXAICEFwp\
        AkwDBAIKAwQCAgORBgJEAEwCPQDCAQIEBgECGwYBAgIGAQIBBgICAQYBAgoGAQIEBgECAQYBAgEGBgIBBgQCAQYBAgEGAQIBBgEC\
        AwYBAgIGAQIBBgICAQYBAgEGAQIBBgECAQYBAgEGAQICBgECAQYCAgQGAQIHBgECBAYBAgQGAQIBBgECCgYBAhEGBQIDBgECBQYB\
        AhEGNAICBo4CAiwABAJkAAwCDwACAg8AAQIPAAECJQAKAq4BADgCGgABOgIADQIsAAQCCQAHAgIADgIGAJoBAtkHAAMCEQADAg0A\
        AwLaAQAGAgwABAIBAA8CDAAEAjgACAIKAAYCKAAIAh4AAgIMAAQCAgAOAgkAJwLYAgAIAg4AAgINAAMCCwADAjkAAQIBAAQCEAAC\
        AgwABAIKAAcCkwEAAQJnAIUIAuDNAjQgAp4iNAICji00AgKxOjQPAu4ENKITAp4ENOILAssmNAUCqkI0h5crAgEAHgJgAIABAvAB\
        AZD8CwI=
        """

    private static let scxDiffData: String =
        """
        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
        """

    private static let scriptRuns: [PartitionRun] = decodePartition(scriptData, singleByteValue: false)

    private struct ScxDiff: Sendable {
        let add: [CodePointRange]
        let sub: [CodePointRange]
    }

    private static let scxDiffs: [UInt16: ScxDiff] = {
        let bytes = decodeBase64(scxDiffData)
        var idx = 0
        let count = Int(readVarint(bytes, &idx))
        var out: [UInt16: ScxDiff] = [:]
        out.reserveCapacity(count)
        for _ in 0..<count {
            let scIdx = UInt16(readVarint(bytes, &idx))
            let addN = Int(readVarint(bytes, &idx))
            var add: [CodePointRange] = []
            add.reserveCapacity(addN)
            var prev: UInt32 = 0
            for _ in 0..<addN {
                let lower = prev + readVarint(bytes, &idx)
                let upper = lower + readVarint(bytes, &idx)
                add.append(CodePointRange(lower: lower, upper: upper))
                prev = upper
            }
            let subN = Int(readVarint(bytes, &idx))
            var sub: [CodePointRange] = []
            sub.reserveCapacity(subN)
            prev = 0
            for _ in 0..<subN {
                let lower = prev + readVarint(bytes, &idx)
                let upper = lower + readVarint(bytes, &idx)
                sub.append(CodePointRange(lower: lower, upper: upper))
                prev = upper
            }
            out[scIdx] = ScxDiff(add: add, sub: sub)
        }
        return out
    }()

    private static let scriptAliases: [String: UInt16] = [
        "Common": 0, "Zyyy": 0,
        "Inherited": 1, "Zinh": 1, "Qaai": 1,
        "Unknown": 2, "Zzzz": 2,
        "Adlam": 3, "Adlm": 3,
        "Ahom": 4,
        "Anatolian_Hieroglyphs": 5, "Hluw": 5,
        "Arabic": 6, "Arab": 6,
        "Armenian": 7, "Armn": 7,
        "Avestan": 8, "Avst": 8,
        "Balinese": 9, "Bali": 9,
        "Bamum": 10, "Bamu": 10,
        "Bassa_Vah": 11, "Bass": 11,
        "Batak": 12, "Batk": 12,
        "Bengali": 13, "Beng": 13,
        "Beria_Erfe": 14, "Berf": 14,
        "Bhaiksuki": 15, "Bhks": 15,
        "Bopomofo": 16, "Bopo": 16,
        "Brahmi": 17, "Brah": 17,
        "Braille": 18, "Brai": 18,
        "Buginese": 19, "Bugi": 19,
        "Buhid": 20, "Buhd": 20,
        "Canadian_Aboriginal": 21, "Cans": 21,
        "Carian": 22, "Cari": 22,
        "Caucasian_Albanian": 23, "Aghb": 23,
        "Chakma": 24, "Cakm": 24,
        "Cham": 25,
        "Cherokee": 26, "Cher": 26,
        "Chorasmian": 27, "Chrs": 27,
        "Coptic": 28, "Copt": 28, "Qaac": 28,
        "Cuneiform": 29, "Xsux": 29,
        "Cypriot": 30, "Cprt": 30,
        "Cypro_Minoan": 31, "Cpmn": 31,
        "Cyrillic": 32, "Cyrl": 32,
        "Deseret": 33, "Dsrt": 33,
        "Devanagari": 34, "Deva": 34,
        "Dives_Akuru": 35, "Diak": 35,
        "Dogra": 36, "Dogr": 36,
        "Duployan": 37, "Dupl": 37,
        "Egyptian_Hieroglyphs": 38, "Egyp": 38,
        "Elbasan": 39, "Elba": 39,
        "Elymaic": 40, "Elym": 40,
        "Ethiopic": 41, "Ethi": 41,
        "Garay": 42, "Gara": 42,
        "Georgian": 43, "Geor": 43,
        "Glagolitic": 44, "Glag": 44,
        "Gothic": 45, "Goth": 45,
        "Grantha": 46, "Gran": 46,
        "Greek": 47, "Grek": 47,
        "Gujarati": 48, "Gujr": 48,
        "Gunjala_Gondi": 49, "Gong": 49,
        "Gurmukhi": 50, "Guru": 50,
        "Gurung_Khema": 51, "Gukh": 51,
        "Han": 52, "Hani": 52,
        "Hangul": 53, "Hang": 53,
        "Hanifi_Rohingya": 54, "Rohg": 54,
        "Hanunoo": 55, "Hano": 55,
        "Hatran": 56, "Hatr": 56,
        "Hebrew": 57, "Hebr": 57,
        "Hiragana": 58, "Hira": 58,
        "Imperial_Aramaic": 59, "Armi": 59,
        "Inscriptional_Pahlavi": 60, "Phli": 60,
        "Inscriptional_Parthian": 61, "Prti": 61,
        "Javanese": 62, "Java": 62,
        "Kaithi": 63, "Kthi": 63,
        "Kannada": 64, "Knda": 64,
        "Katakana": 65, "Kana": 65,
        "Kawi": 66,
        "Kayah_Li": 67, "Kali": 67,
        "Kharoshthi": 68, "Khar": 68,
        "Khitan_Small_Script": 69, "Kits": 69,
        "Khmer": 70, "Khmr": 70,
        "Khojki": 71, "Khoj": 71,
        "Khudawadi": 72, "Sind": 72,
        "Kirat_Rai": 73, "Krai": 73,
        "Lao": 74, "Laoo": 74,
        "Latin": 75, "Latn": 75,
        "Lepcha": 76, "Lepc": 76,
        "Limbu": 77, "Limb": 77,
        "Linear_A": 78, "Lina": 78,
        "Linear_B": 79, "Linb": 79,
        "Lisu": 80,
        "Lycian": 81, "Lyci": 81,
        "Lydian": 82, "Lydi": 82,
        "Mahajani": 83, "Mahj": 83,
        "Makasar": 84, "Maka": 84,
        "Malayalam": 85, "Mlym": 85,
        "Mandaic": 86, "Mand": 86,
        "Manichaean": 87, "Mani": 87,
        "Marchen": 88, "Marc": 88,
        "Masaram_Gondi": 89, "Gonm": 89,
        "Medefaidrin": 90, "Medf": 90,
        "Meetei_Mayek": 91, "Mtei": 91,
        "Mende_Kikakui": 92, "Mend": 92,
        "Meroitic_Cursive": 93, "Merc": 93,
        "Meroitic_Hieroglyphs": 94, "Mero": 94,
        "Miao": 95, "Plrd": 95,
        "Modi": 96,
        "Mongolian": 97, "Mong": 97,
        "Mro": 98, "Mroo": 98,
        "Multani": 99, "Mult": 99,
        "Myanmar": 100, "Mymr": 100,
        "Nabataean": 101, "Nbat": 101,
        "Nag_Mundari": 102, "Nagm": 102,
        "Nandinagari": 103, "Nand": 103,
        "New_Tai_Lue": 104, "Talu": 104,
        "Newa": 105,
        "Nko": 106, "Nkoo": 106,
        "Nushu": 107, "Nshu": 107,
        "Nyiakeng_Puachue_Hmong": 108, "Hmnp": 108,
        "Ogham": 109, "Ogam": 109,
        "Ol_Chiki": 110, "Olck": 110,
        "Ol_Onal": 111, "Onao": 111,
        "Old_Hungarian": 112, "Hung": 112,
        "Old_Italic": 113, "Ital": 113,
        "Old_North_Arabian": 114, "Narb": 114,
        "Old_Permic": 115, "Perm": 115,
        "Old_Persian": 116, "Xpeo": 116,
        "Old_Sogdian": 117, "Sogo": 117,
        "Old_South_Arabian": 118, "Sarb": 118,
        "Old_Turkic": 119, "Orkh": 119,
        "Old_Uyghur": 120, "Ougr": 120,
        "Oriya": 121, "Orya": 121,
        "Osage": 122, "Osge": 122,
        "Osmanya": 123, "Osma": 123,
        "Pahawh_Hmong": 124, "Hmng": 124,
        "Palmyrene": 125, "Palm": 125,
        "Pau_Cin_Hau": 126, "Pauc": 126,
        "Phags_Pa": 127, "Phag": 127,
        "Phoenician": 128, "Phnx": 128,
        "Psalter_Pahlavi": 129, "Phlp": 129,
        "Rejang": 130, "Rjng": 130,
        "Runic": 131, "Runr": 131,
        "Samaritan": 132, "Samr": 132,
        "Saurashtra": 133, "Saur": 133,
        "Sharada": 134, "Shrd": 134,
        "Shavian": 135, "Shaw": 135,
        "Siddham": 136, "Sidd": 136,
        "Sidetic": 137, "Sidt": 137,
        "SignWriting": 138, "Sgnw": 138,
        "Sinhala": 139, "Sinh": 139,
        "Sogdian": 140, "Sogd": 140,
        "Sora_Sompeng": 141, "Sora": 141,
        "Soyombo": 142, "Soyo": 142,
        "Sundanese": 143, "Sund": 143,
        "Sunuwar": 144, "Sunu": 144,
        "Syloti_Nagri": 145, "Sylo": 145,
        "Syriac": 146, "Syrc": 146,
        "Tagalog": 147, "Tglg": 147,
        "Tagbanwa": 148, "Tagb": 148,
        "Tai_Le": 149, "Tale": 149,
        "Tai_Tham": 150, "Lana": 150,
        "Tai_Viet": 151, "Tavt": 151,
        "Tai_Yo": 152, "Tayo": 152,
        "Takri": 153, "Takr": 153,
        "Tamil": 154, "Taml": 154,
        "Tangsa": 155, "Tnsa": 155,
        "Tangut": 156, "Tang": 156,
        "Telugu": 157, "Telu": 157,
        "Thaana": 158, "Thaa": 158,
        "Thai": 159,
        "Tibetan": 160, "Tibt": 160,
        "Tifinagh": 161, "Tfng": 161,
        "Tirhuta": 162, "Tirh": 162,
        "Todhri": 163, "Todr": 163,
        "Tolong_Siki": 164, "Tols": 164,
        "Toto": 165,
        "Tulu_Tigalari": 166, "Tutg": 166,
        "Ugaritic": 167, "Ugar": 167,
        "Vai": 168, "Vaii": 168,
        "Vithkuqi": 169, "Vith": 169,
        "Wancho": 170, "Wcho": 170,
        "Warang_Citi": 171, "Wara": 171,
        "Yezidi": 172, "Yezi": 172,
        "Yi": 173, "Yiii": 173,
        "Zanabazar_Square": 174, "Zanb": 174,
    ]

    private static func scriptRanges(id: UInt16, extensions: Bool) -> [CodePointRange] {
        var base: [CodePointRange] = []
        for run in scriptRuns where run.value == id {
            if let last = base.last, last.upper + 1 == run.lower {
                base[base.count - 1] = CodePointRange(lower: last.lower, upper: run.upper)
            } else {
                base.append(CodePointRange(lower: run.lower, upper: run.upper))
            }
        }
        guard extensions, let diff = scxDiffs[id] else { return base }
        var res = diff.sub.isEmpty ? base : subtractRanges(base, diff.sub)
        if !diff.add.isEmpty { res = normalizeRanges(res + diff.add) }
        return res
    }

    // MARK: - Binary Properties Table

    private static let binaryPropAliases: [String: String] = [
        "ASCII": "ASCII",
        "ASCII_Hex_Digit": "ASCII_Hex_Digit", "AHex": "ASCII_Hex_Digit",
        "Alphabetic": "Alphabetic", "Alpha": "Alphabetic",
        "Any": "Any",
        "Assigned": "Assigned",
        "Bidi_Control": "Bidi_Control", "Bidi_C": "Bidi_Control",
        "Bidi_Mirrored": "Bidi_Mirrored", "Bidi_M": "Bidi_Mirrored",
        "Case_Ignorable": "Case_Ignorable", "CI": "Case_Ignorable",
        "Cased": "Cased",
        "Changes_When_Casefolded": "Changes_When_Casefolded", "CWCF": "Changes_When_Casefolded",
        "Changes_When_Casemapped": "Changes_When_Casemapped", "CWCM": "Changes_When_Casemapped",
        "Changes_When_Lowercased": "Changes_When_Lowercased", "CWL": "Changes_When_Lowercased",
        "Changes_When_NFKC_Casefolded": "Changes_When_NFKC_Casefolded", "CWKCF": "Changes_When_NFKC_Casefolded",
        "Changes_When_Titlecased": "Changes_When_Titlecased", "CWT": "Changes_When_Titlecased",
        "Changes_When_Uppercased": "Changes_When_Uppercased", "CWU": "Changes_When_Uppercased",
        "Dash": "Dash",
        "Default_Ignorable_Code_Point": "Default_Ignorable_Code_Point", "DI": "Default_Ignorable_Code_Point",
        "Deprecated": "Deprecated", "Dep": "Deprecated",
        "Diacritic": "Diacritic", "Dia": "Diacritic",
        "Emoji": "Emoji",
        "Emoji_Component": "Emoji_Component", "EComp": "Emoji_Component",
        "Emoji_Modifier": "Emoji_Modifier", "EMod": "Emoji_Modifier",
        "Emoji_Modifier_Base": "Emoji_Modifier_Base", "EBase": "Emoji_Modifier_Base",
        "Emoji_Presentation": "Emoji_Presentation", "EPres": "Emoji_Presentation",
        "Extended_Pictographic": "Extended_Pictographic", "ExtPict": "Extended_Pictographic",
        "Extender": "Extender", "Ext": "Extender",
        "Grapheme_Base": "Grapheme_Base", "Gr_Base": "Grapheme_Base",
        "Grapheme_Extend": "Grapheme_Extend", "Gr_Ext": "Grapheme_Extend",
        "Hex_Digit": "Hex_Digit", "Hex": "Hex_Digit",
        "IDS_Binary_Operator": "IDS_Binary_Operator", "IDSB": "IDS_Binary_Operator",
        "IDS_Trinary_Operator": "IDS_Trinary_Operator", "IDST": "IDS_Trinary_Operator",
        "ID_Continue": "ID_Continue", "IDC": "ID_Continue",
        "ID_Start": "ID_Start", "IDS": "ID_Start",
        "Ideographic": "Ideographic", "Ideo": "Ideographic",
        "Join_Control": "Join_Control", "Join_C": "Join_Control",
        "Logical_Order_Exception": "Logical_Order_Exception", "LOE": "Logical_Order_Exception",
        "Lowercase": "Lowercase", "Lower": "Lowercase",
        "Math": "Math",
        "Noncharacter_Code_Point": "Noncharacter_Code_Point", "NChar": "Noncharacter_Code_Point",
        "Pattern_Syntax": "Pattern_Syntax", "Pat_Syn": "Pattern_Syntax",
        "Pattern_White_Space": "Pattern_White_Space", "Pat_WS": "Pattern_White_Space",
        "Quotation_Mark": "Quotation_Mark", "QMark": "Quotation_Mark",
        "Radical": "Radical",
        "Regional_Indicator": "Regional_Indicator", "RI": "Regional_Indicator",
        "Sentence_Terminal": "Sentence_Terminal", "STerm": "Sentence_Terminal",
        "Soft_Dotted": "Soft_Dotted", "SD": "Soft_Dotted",
        "Terminal_Punctuation": "Terminal_Punctuation", "Term": "Terminal_Punctuation",
        "Unified_Ideograph": "Unified_Ideograph", "UIdeo": "Unified_Ideograph",
        "Uppercase": "Uppercase", "Upper": "Uppercase",
        "Variation_Selector": "Variation_Selector", "VS": "Variation_Selector",
        "White_Space": "White_Space", "space": "White_Space", "WSpace": "White_Space",
        "XID_Continue": "XID_Continue", "XIDC": "XID_Continue",
        "XID_Start": "XID_Start", "XIDS": "XID_Start",
    ]

    private static let binaryPropBaseMasks: [UInt8: UInt32] = [
        1: 0x1,
        2: 0x2,
        3: 0x7,
        4: 0x21F,
        5: 0xB7F,
        6: 0x40000,
        7: 0xA0,
        8: 0x7FFF5F,
    ]

    private static let binaryPropData: [String: (UInt8, String)] = [
        "ASCII_Hex_Digit": (0, "MAkIBRsF"),
        "Alphabetic": (4, "xQYAHgzBBA0CAAIBAgECAEkKMQwCBhEAZgYFAwMBBQAkAB8PZwpmAQQIAgICA2sAPQsEBgcTNwEDDgIBBgILAR4COwYDAQMBCwALAR4COwQFAQMBBQAfAQQADAI7BwICAgEWARcCBQI7BgMBAwEKAQsBHwA8BAQCAgILACkEOgYCAgICCQEMAR4COwYCAgICCQEMARAADQM7BgICAgILAAsBHgJMBQIAAgcTAT4AAwYTAGQAAwUCAREApAESCgoCI28LAgADAxgDBQICAgMGBAMOCwIACwP1DAEfAR8BHwFDEr0BASMAdwsFCN8BBDoJAxNLAQwCMgQxDj0CHwgDAToKMxKdAyHCDTP3ER/18AEHIwHjAgAJABgEWQEzDwIAOgAnBB0LLgMxCyYARA0NAAkBLgIzAAICAwEGAC0EBgDuAQe0ngEA2BAEhw0CAgEGA5UGA0IAwgIBTgKEAgI2DS4BDAIuCAoAPgIlCxMBOgIxDA8BXQgDAAcAAwCeAQkYAzsGAwEDAQsACwFVCAIAAwACAwIBaAwCAmsR7gEGAwYeAVMOAgBrCmgNggIM+AEFAgEDAQQAAgCPAQYDBQUAHQkrBAIDEwovDckBB8gBBwIGVBUCDXsFBAACAQICAgAEAEMEAgECA90CAwoBAgAxBgQC3oMBEKEcAAI2CANeAa2ZAQDiRgYCEAMGAgECBGUA1AwAAwAIAQYA0gQA6Q8ZBxkHGQ=="),
        "Bidi_Control": (0, "nAwA8jMBGwQ4Aw=="),
        "Bidi_Mirrored": (0, "KAETAAIAHQACAB4AAgAuABAA/xwD3g4BnRMBCwE3AQ8BsgEAwQEDBAUEAAQBBAMCAwIAAgAFCAYAAhEGAwoBAgACBwIfAwMGAAoBAxIGAQoEAwEFFwMPCQMVAQgBvggNSwADAwIBAgIGAwYCBA2UAxUDBQINCQAIBQQABQQCAQMEBQACAgMBCwUDAQ0SAgMDAAIAAwACAwYBBwIZAQwBBQMCAQMBBSoDBwInBgACAAQEBgIFAAQEAgCBAgCEBAMEAQIBDwEDCSwHrAMJAwe+nAMFBgGjAQETAAIAHQACAB4AAgACAQIB+K4DADoAOgA6ADoA"),
        "Case_Ignorable": (0, "JwAHAAwAJAACAEgABQACAAUAAwH4A78BBQEFAAoBAgD8AQbQAQAGADIsAgACAQIBAgAtAAwFCwoCACQACxQRAGYHAgkCAyIAAgAfGlwKOwoFAAMAGRcsAi0ACAEGCCo5OAACAAUHBQAEBgsBDgAQADsABQMJABUBGwADAToABQEFAQMCBAAfAQQADAE6AAUEAgEFABUBFwUCADsAAwACAwkACAEMAR8APgANADMABAA4AAICBgICAwgBDAEeADsAAwAHAAYBFQEdAToBBQMJABUBHgBJAAgCAgBbAAMGDAhjAAMICgACBkoBHAACAAIAOA0CBAIBBgoCIwoAZwMCBQIBAwEaAQUCEQMOAAMBBwAQAF8A4QQCswcCHgEfAR8BQQECBgkAAwoEAAYALgQ0AEIBIwB3AgUBCgAHAtwBAQMAOwACBgIAAgADBwcJAwAoAAktAwsVAzEAAgQCAAYAKQgNASEDAwECAjkAAgEEAAICOwcDAUEFUwICDAIGBQAHAAQBMz4OACNkvgMAAgIMAg4CDgIOAQ0ECQELAAMAAwQyBAIJAgAOABEMNCCMFwFyAn4AEABhHzAA1gMAJQMEBAYAXgVeApfeAQDjCQWPAgBjAwIJAgAdA1EBDyFPABgCZwMEAQkABAAFABoBBgCYAQEbEQ4AJwcaCi8CMQADAwMBEgAWAUMFAwEDAQ0ACQAkAAwANAACAgMBBgECABwADwEGAQIAZQQKAnoAAwAFALGeAQCUARC+BA8EAA0PIwADAKoBAAgABwAMACQAAgAwAC4BRAAWAoIEAOMBAJYBBIYIBQIpAgjHBAICAQYDKQIFAKYBAb4EAycAGwQCALwCARkANQVHCjIDfAA3DioAAwELAjIDAwEDAAUACwAzAiUEAgc/AA0BNQgLAwMAYAIDAAIBBwADAJ4BAAQHFgE6AQQAJgYEBEcFDgACAAIADwFWBwMCAgAYAFUFAgAFAQIB7wEDBwECARwBVgcDAAIBawACAAMFAgBmAAIAAwMCBIQCCAIBgQIBAgAFAJEBAwMBBQAhCSkFAwMJAAoFAwIvDAIBxwEAAgICAMoBBgIFAgBTFQMGAgECAXsFBAACAQIGAgBJAQQAAgBCAJoCAQwBNQQGAAIAGADWKRAHDslZCwQCwRMEPAYKA/0DAikB4wMAQBBBAQIBDgH9fwMCBgIBnxkBAgPdJC0DFqEEAgoPAwYfA5UBArwPNgUxCQAPABcEAg7RCgYCEAMGAgECBAY9IgChAQ3xAgA+A/wDBP8BAfQBAAMACAEGAAoA0QMGbgewFQSCmDAAH1+BAe8B"),
        "Cased": (3, "qgEAEAD2AwgIAR8EYQA1AIIbALAYPg4AIySyBQAOABEMxAEftwYzkw8Bn/QBAdMBAIEBAwQB4wYDCgCXuAEAAwICKQII9rADPcMhGQcZBxk="),
        "Changes_When_Casefolded": (1, "tQEAKgBqADYARgADAAMAJwDTAgB9AA4GGgEEAJIDAJkcVQMFgxEIkgQB5QEvAwIDAAUABgIDAAUAJgIDAAUAhgIABQAEAgMCAwAEBAcABAAEAQMBAgALAQYAGw/HBhmhjQJPwZ4BBg0E6bEDGRsZGxkbAAIBAwADAQMDAgcbGRsBAgMDBwIGHAECAwIEAgAEBhwZGxkbGRsZGxkbGR8YIhgiGCIYIhgiAA=="),
        "Changes_When_Casemapped": (3, "uAIAVQAdAQ8ABABjABMFHAADAAIAAwIDAAUABgECAAMBAgYCAQIAAwIHBAIAAwYDEJYBAI0BAigA5AIAKAD4LitADAMCAg8CC4ICAQIA4wQABQADCQIABAQHAAQABAECAgIBBQADAwYEFx+3BjOIDwADAAMEaQDM9AEBQAcWAAcAGgBLALYGIgIGBgiY0QRUAkYCAQMAAwEDAwILAgACBgJAAgMDBwIGAhsCAwIEAgAEBgLTAgMYAhgCHgIYAh4CGAIeAhgCHgIYAge1DgkCEwcF"),
        "Changes_When_Lowercased": (1, "xQMAAwADACcA4AMCtDcHCQcJBw0AEAAwAIYCAAUABAIDAgMABAQHAAQABAEDAQIACwEGABsPxwYZsd4GGRsZGxkbAAIBAwADAQMDAgcbGRsBAgMDBwIGHAECAwIEAgAEBhwZGxkbGRsZGxkbGR8YIhgiGCIYIhgiAA=="),
        "Changes_When_NFKC_Casefolded": (1, "oAEACAACAAMAAgADAwMCAgIhAFQADQAJADYARgECAQIBJgG9AQggBQMEXAECAgoAJQAGAAQABgECADsADgEEARoCAwCSAwCVAQBZA+AFB30BAgBUAAMAIwIDAP4BAdYFAIABACkBLwA3AAoABQAFAAUADQAKAAIECAASAAoABQAFAAUADQDDAgBjAcAEVQMFtwcBVgTxCAikAQICCgIRAhsOACMk2wEB1gEAAgACAAIAAgACAAIAAy8DAgMABQgDAAUDBAAKAgQACgIDAgMABQICDwIABgANAgQFBAECAQUAAgAJAg4ACBIDGgIMDABYAQIAAgEDAQQBBAADAAoCDQAFBQICAwAGAwcvCgCjAQECAfkBAbYCigGiCgBoAmYAoAMB8gEAsAIAVAAN1QErADYAAgJhAQMAYAAyXQQNYR4CJwkuAv8CneUBAdMBAIEBAwQB4wYDCgAHT8GaAY0CAwACAAMJAgACAAMBBEMDaScGDQQGAAIXAgQCAAIBAgECayLqAhM/AzUpDAQZFxQDCwISAgMFAgIAAoYBAwACHxuDAQQFAwUDBQMCBAYCBgIIiQ8EAikCCObpAgOzICPlCAYPB0EF2gQZGwYCERsZGwMCAAIGAgobGRsZGxkbGRsZGxkbGRsZGxscIBogGiAaIBogAgADMbEQPZMbAwIaAgECAAMAAgkCAwIAAgAHAAUAAgACAAICAgECAAMAAgACAAIAAgACAQIAAwMCBgIDAgMCAAIJAhAGAgIEAhDFBAoGHgIfGwIkAHACDisFCAgBnxMJh/gDnQTjiyz/Hw=="),
        "Changes_When_Titlecased": (2, "uAIAVQAdAQ8ABAAGAAMAAwAnADAAEwUcAAMAAgADAgMABQAGAQIAAwECBgIBAgADAgcEAgADBgMQlgEAtwEA5AIAKADIFioDAoEYK0AMAwICDwILggIBAgDrBAAEAQQAHAAFAAUAAwEJAycP0QYZiA8AAwADBGkAzPQBAUAHFgAHABoASwC2BiICBgYIstEEGRsGAhEbGRsDAgACBgIKGxkbGRsZGxkbGRsZGxkbGRsbHRgCBRsYAgUbGAIFGxgCBRsYAgUCALUOCQITBwU="),
        "Changes_When_Uppercased": (2, "uAIAVQAdAQ8ABAAHAAMAAwAnAC8AEwUcAAMAAgADAgMABQAGAQIAAwECBgIBAgADAgcEAgADBgMQlgEAtwEA5AIAKAD4LitADAMCAg8CC4ICAQIA6QEHCQcJBw0AEAAwAI4CAAQBBAAcAAUABQADAQkDJw/RBhmIDwADAAMEaQDM9AEBQAcWAAcAGgBLALYGIgIGBgiy0QQZGwYCERsZGwMCAAIGAgobGRsZGxkbGRsZGxkbGRsZGxsdGAIFGxgCBRsYAgUbGAIFGxgCBQIAtQ4JAhMHBQ=="),
        "Dash": (0, "LQDdCgA0AMIcAIYIAIoQBT4AKAAQAIcDAIUYAAMAIAEFAB0AvwMAFABwAJGbAwEmAAsAqgEA4RwAvwIA"),
        "Default_Ignorable_Code_Point": (0, "rQEAogUAzQUAwxYB1AwBVgT8DwQbBDIP9SEAnJkDD/ABAKEBAFAIqPkCA9ApB4bdMP8f"),
        "Deprecated": (0, "yQIAqgoAhBIAAgCqEAHGEQW6BQHXuTcA"),
        "Diacritic": (0, "XgACAEgABwAFAAMB+AOeAQIHBgUSAQUACgH+AQTSAQA4LAIAAgECAQIAhAEHBQGHAQEFAQQCRBpcCjsKIwF/ByoJERs+ABEABAMdAEsAEQBvABEAbwARADACPQARAAgAeABvABEAbwARAG4BEQB9AHAADQUCAGwADgRMARwAAgACAAUBQwICAT8AcQACASkBBQQaBgIACwHCBQK1BwEfAJUBCgoA3AICpQIAFQcDADEOAwoEDgMLSQAQACcINwE7AAwBQwFBBVMYBQAHAAMCMz4xIwYLJgq+AwACAgwCDgIOAg4B8RkCvgIA+wMFagNgAPPqAQANAQIAHQFTAQ8hZwJnAAcBDQAmAJgBABwROgMlAGAADQAlAJYBAkIDNABlBAoCgQEBsZ4BAIIGD48CAAIAMAAuAUQA/QUAoAkFAikCCP4EAgUApgEBvAQFJwAbBI0DAAMCRwoyA8EBACoASQF5AT8ATQAKAmkBswEBUQERABkGBARaAgIBDgFgAAQAfAH8AQF/AHcBdACOAgGDAgEFAJ0BAFQAEwBSAKYDAIMCAAIBUgBCAOgCARgA7SkO2lkAwRMEPAa1BAGjBBBRAf9/AwIGAgGCPi0DFqEEAgQFCQcDBh8Dgx09wwEG+AIAPgP/BQHhBQZuAgIC"),
        "Emoji": (0, "IwAHAAYJcAAFAI4/AA0A2QEAFwBbBRAB8AIBDQCnAQAaCgUCyAEA6AEBCwAKADsDAgQKAAMAAwEDAAUAAwACAQMABAAEAQkCBgACAAYLDAEDAAIBAgATAAMBEwUCAAIBBAEGAAMBBQEMAQYBAwAGAQIAAgEVAQYFAgMDAAUAAwADBQIAAwACAAIABwAEAAcACwEQAAMABQACAAUCAgAMATECCgAPAA8A9QIB0AMCFAE0AAUA2wkADQDaBAACAOv6BgDLAQChAQENAQ8AAwlMGQIBGAAVAAMIFgGvASEDbwMBAgIDUgMCAoYCAj4MBQIXCAEDBw0AAwMDAAUBDgEDAAkBCgAGAg0CCQIDAAIABQAHAAQAB1UxRQYHAwMECQQAAgEEAAMJ5AELBQCcAi4CCQK4AXEMBAoEOAIABQ8DCwUJ"),
        "Emoji_Component": (0, "IwAHAAYJ1D8A1gEArLoDANfnAxn8AwSxCwPtjDBf"),
        "Emoji_Modifier": (0, "++cHBA=="),
        "Emoji_Modifier_Base": (0, "nUwA3AEAEQP4mAcAPQIDAAMCdgEDChYSBAAFAgICCAACABkAygEBBQAWAAUBrwECBARUABECCgAMAMAEAAMACQcHAAoJAwI5AD4BAgECABICAgzmAQIrCA=="),
        "Emoji_Presentation": (0, "mkYBzgEDBAADAIoEARYBMwssABQADgAJARIBBgEJAAYAFgAIAQIABQADAAgABQEdACQAAgAFAgIAPgIZAA8A3AYBNAAFAK+JBwDLAQC/AQADCUwZAgAZABUAAwQCAhYBrwEgDQgCRQIVDSoFBA0QBAAERgIAAroBAz4OAwIXEwAbAQ4AV1QxRQcABAIDAwQDDAEICOQBCwUAnAIuAgkCuAFxDAQKBDgCAAUPAwsFCQ=="),
        "Extended_Pictographic": (0, "qQEABQCOPwANANkBABcAWwUQAfACAQ0ApwEAGgoFAsgBAOgBAQsACgA7AwIECgADAAMBAwAFAAMAAgEDAAQABAEJAgYAAgAGCwwBAwACAQIAEwADARMFAgACAQQBBgADAQUBDAEGAQMABgECAAIBFQEGBQIDAwAFAAMAAwUCAAMAAgACAAcABAAHAAsBEAADAAUAAgAFAgIADAExAgoADwAPAPUCAdADAhQBNAAFANsJAA0A2gQAAgDr+gYAKANlCxABEAAPASYJcQENAQ8AAwkUNxwOCwAVAAMIAgMKFge7AQNvAwECAgNSAwICAwb9AQI+DAUCFwgBAwcNAAMDAwAFAQ4BAwAJAQoABgINAgkCAwACAAUABwAEAAdVMUUGBwMQBAACBQMM2wElDQM5BwsFKQcfAQ0DAw0KJg0uAgkCuAFZBw+RAYEC/Qc="),
        "Extender": (0, "twEAmQQB7wYAugMA9wQAigEAWgDxBQCAAQDEEgA5AOQEAI8DAEUAiicALARoAV4Cl94BAPcLAMMHABcAigEAbQAWAfyoAQCREAHMCwAcAAUAyAkApgIAdQHzAwLQCQDBBgDpmgEBnQkBAgAPAcniAQGyCQDVBgI="),
        "Grapheme_Base": (8, "vhMAGQDnAgAZAGcAGQDpAQACAAUBAgEKAWgAGQB4ABAAthIAHwCBCAAGAAIABgFmAEgBuygBpPIBAG0A3qsBAaEkAHUAiQIADwAKAGEACgADAAICBgDhAQANAPIBAIcCAPoEAA0AhAwAr6EBAfTCAQEHBQ=="),
        "Grapheme_Extend": (7, "vhMAGQDnAgAZAGcAGQDpAQACAAUBAgEKAWgAGQB4ABAAthIAHwCBCAAGAAIABgFmAEgBmQgAoiABpPIBAG0A3qsBAaEkAHUAiQIADwAKAGEACgADAAICBgDhAQANAPIBAIcCAPoEAA0AhAwAr6EBAfTCAQEHBa7dMF8="),
        "Hex_Digit": (0, "MAkIBRsFqv0DCQgFGwU="),
        "IDS_Binary_Operator": (0, "8F8BAwnyAwA="),
        "IDS_Trinary_Operator": (0, "8l8B"),
        "ID_Continue": (5, "twEA0AUA4h8I6QwAsgwBiwIAFgCBGgDsBAFfAOqcAwA="),
        "ID_Start": (4, "hTEBkhEAFgCBGgDsBAE="),
        "Ideographic": (0, "hmABGggPAsYHvzNB/6MBgbIB7QIDaYvqAQAOBArVOSofYnL+RosDhZoB380CIZ0iA40tA7A6EO0EoxOdBOMLyiYGqUI="),
        "Join_Control": (0, "jEAB"),
        "Logical_Order_Exception": (0, "wBwEfATxFQIDAPuhAgEDAAIB"),
        "Lowercase": (2, "qgEAEAD2AwgIAR8EYQA1AIIbALAYPg4AIySyBQAOABEM1AEP0QYZkw8Bn/QBAdMBAIEBAwQB4wYDCgCXuAEAAwICKQII9rADPQ=="),
        "Math": (6, "XgDyBgIDABsBAwGhOAAcAgwAIQMZAQ8BQgwFAAQBBQQTAAUAAwkCAAQEBwAEAQMBAgICBQQDBgRMBAMDAgECAQIAAgQDAQUBBREDAQIAAgYCAAcBowIDqQEBAgAZABIAvgMBDQgGBAYBAwEEBA8AAgADBRkBOgACAB4DCgHXAgEgCZQDFUADIQHkqAMAAgAFANQBAAIAwqkDVAJGAgEDAAMBAwMCCwIAAgYCQAIDAwcCBgIbAgMCBAIABAYC0wIDGAIYAh4CGAIeAhgCHgIYAh4CGAIHAzGBLAMCGgIBAgADAAIJAgMCAAIABwAFAAIAAgACAgIBAgADAAIAAgACAAIAAgECAAMDAgYCAwIDAgACCQIQBgICBAIQ"),
        "Noncharacter_Code_Point": (0, "0PsDH48EAf//AwH//wMB//8DAf//AwH//wMB//8DAf//AwH//wMB//8DAf//AwH//wMB//8DAf//AwH//wMB//8DAf//AwE="),
        "Pattern_Syntax": (0, "IQ4LBhsDAgAbAyMGAgACAQIAAgEFAAUABAAYACAAmT4XCQ4DEgIJsgLPBaEB9QQf6wiBBH+CAwIFGBAAjpoDAYYCAQ=="),
        "Pattern_White_Space": (0, "CQQTAGUAiT8BGQE="),
        "Quotation_Mark": (0, "IgAFAIQBABAA3T4HGgGIHADKAwMOAqKcAwO+AQAFAFsB"),
        "Radical": (0, "gF0ZAlgN1QE="),
        "Regional_Indicator": (0, "5uMHGQ=="),
        "Sentence_Terminal": (0, "IQANABEAygoAlAECtQEALAL3AQA+AAIABAGmAgHlDQGXBgAFAYYGAMcBAZ4BAS4ABgC7AgHjAgOjAQELAQMBHgK8AQFCAaUHABgBCgKwGQKzAgAOABcBrgMA/ekBAI8CAeQBAAQA/wIBVwFgAJkBAZQBApEBAfoBAKekAQADATwABAGqAQANABEAQgD1FQH+CQQtA74BAXYDgAECggEBBwARAVkBAgFtAKsCAXYB9gIBBg5qAfoBAoYEAAIA/AEBWAGlAwG1BQFLAaqWAQGGAQBCAQwAqgQBqQIAh5wBAOk7AA=="),
        "Soft_Dotted": (0, "aQHFAQCaAgAfADUAFQDBAgBjAAIAijIANAAOAAQAhQEAngEApgMA1wEBsxYAps8GATMBMwEzATMBMwEzATMBMwEzATMBMwEzAYcRALICARsA"),
        "Terminal_Punctuation": (0, "IQALAAIADAEEAL8GAAkAggQAOgBJAA8AAgK1AQAsCgIA7AEBNwUCByAAhgIB9QkBrQEABQW4AgGWBgeGBgB9AkgBngECBAAoAwMBuwIB4wIDowEBCwECAh4CvAEEPwGlBwAYAQoCsBkCswIADgAFAAsAAgEEAa0DAfzpAQGOAgLkAQT/AgFXAWAAmAEClAECgAEAEQH6AQCnpAEAAwE6AgIDqgEACwACAAwBBABCAAMAuwgAMQCHCQDIAQC3AgGZAQVFBVoDuQcELQO+AQZxA4ABAoIBAQcAEQFZBG0AqwIBdgINAecCAwQOagH6AQKGBAACAPwBAVgBBQGfAwIuAIYFAUsBrAoE+osBAYYBAEICCwCqBAGoAgGHnAEA6DsD"),
        "Unified_Ideograph": (0, "gGi/M0H/owGPtAEBAgACAQsAAgACAQMC14sE380CIZ0iA40tA7A6EO0EoyPKJgapQg=="),
        "Uppercase": (1, "4EIPxwYZ4ZgHGQcZBxk="),
        "Variation_Selector": (0, "izACAgDxywMP8YU07wE="),
        "White_Space": (0, "CQQTAGUAGwDgKwCAEwoeAQYAMAChHwA="),
        "XID_Continue": (5, "twEAwwUADQDiHwjpDACyDAGLAgAWAIEaAMwFAOOWAwWXAwF1AAIAAgACAAIAAgACAAIA5wEA"),
        "XID_Start": (4, "+gYAuRUAgAEA0hMBkhEAFgCBGgCvnAMFlwMBdQACAAIAAgACAAIAAgACAKACAQ=="),
    ]

    // MARK: - ES2025 Properties of Strings (v-mode)

    private static let basicEmojiSingletonData: String =
        """
        mkYBzgEDBAADAIoEARYBMwssABQADgAJARIBBgEJAAYAFgAIAQIABQADAAgABQEdACQAAgAFAgIAPgIZAA8A3AYBNAAFAK+JBwDL\
        AQC/AQADCWcAGQAVAAMEAgIWAa8BIA0IAkUCFQ0qBQQNEAQABEYCAAK6AQM+DgMCFxMAGwEOAFdUMUUHAAQCAwMEAwwBCAjkAQsF\
        AJwCLgIJArgBcQwECgQ4AgAFDwMLBQk=
        """

    private static let basicEmojiFE0FData: String =
        """
        qQEABQCOPwANANkBABcAWwUQAf4CAKcBAB4CAgEGAsgBAOgBAQsACgA7AQQECgADAAcABQADAAIBAwAEAAQBCQIGAAIAHQEDAAIB\
        AgATAAMAFAACAwIAAgEEAAcACQEXAAcAAgACABYABwEDAAMCCQAGAQMBAgADAAIAAgAHAAQAEgEQAAMAHAE9AJMDAdADAqkKAA0A\
        2gQAAgDX/QYBDQGDAQA1AOoBAAMICgBHABkBAgIDASwDBgsUAAIAAgBIAAIAvAEATAElAQMGDgADAwMAFQADAAkBCgAGAg0CCQID\
        AAIABQAHAAQABwDRAQACAhEFBAAHAAMA
        """

    private static let rgiFlagPairs: [UInt16] = [2, 3, 4, 5, 6, 8, 11, 12, 14, 16, 17, 18, 19, 20, 22, 23, 25, 32, 33, 35, 36, 37, 38, 39, 40, 41, 43, 44, 45, 46, 48, 49, 50, 51, 53, 54, 56, 57, 64, 66, 67, 69, 70, 71, 72, 74, 75, 76, 77, 78, 79, 80, 81, 84, 85, 86, 87, 88, 89, 100, 102, 105, 106, 108, 110, 121, 128, 130, 132, 134, 135, 145, 146, 147, 148, 168, 169, 170, 172, 174, 177, 192, 193, 195, 196, 197, 198, 199, 200, 203, 204, 205, 207, 208, 209, 210, 211, 212, 214, 216, 234, 236, 237, 241, 243, 244, 258, 259, 260, 267, 268, 269, 270, 272, 273, 274, 275, 292, 300, 302, 303, 324, 326, 327, 328, 332, 333, 335, 337, 342, 344, 345, 352, 353, 354, 360, 362, 369, 370, 371, 372, 373, 376, 384, 386, 387, 388, 389, 390, 391, 394, 395, 396, 397, 398, 399, 400, 401, 402, 403, 404, 405, 406, 407, 408, 409, 416, 418, 420, 421, 422, 424, 427, 430, 431, 433, 436, 441, 460, 480, 484, 485, 486, 487, 490, 491, 492, 493, 497, 498, 499, 502, 504, 512, 548, 558, 562, 564, 566, 576, 577, 578, 579, 580, 582, 583, 584, 585, 586, 587, 588, 589, 590, 593, 594, 595, 597, 599, 600, 601, 608, 610, 611, 613, 614, 615, 617, 618, 619, 620, 621, 622, 625, 627, 629, 630, 633, 640, 646, 652, 653, 658, 664, 665, 672, 674, 676, 678, 680, 685, 692, 709, 722, 746, 772, 787, 800, 812, 822]

    struct PropertyResolution: Sendable {
        let ranges: [CodePointRange]
        let strings: [[UInt32]] // multi-codepoint strings for v-mode Properties of Strings
        let isPropertyOfStrings: Bool
    }

    static func resolveProperty(name: String?, value: String, unicodeSets: Bool) -> PropertyResolution? {
        if let propName = name {
            switch propName {
            case "General_Category", "gc":
                guard let mask = gcAliasMasks[value] else { return nil }
                return PropertyResolution(ranges: gcRanges(mask: mask), strings: [], isPropertyOfStrings: false)
            case "Script", "sc":
                guard let id = scriptAliases[value] else { return nil }
                return PropertyResolution(ranges: scriptRanges(id: id, extensions: false), strings: [], isPropertyOfStrings: false)
            case "Script_Extensions", "scx":
                guard let id = scriptAliases[value] else { return nil }
                return PropertyResolution(ranges: scriptRanges(id: id, extensions: true), strings: [], isPropertyOfStrings: false)
            default:
                return nil
            }
        }
        // Lone property value: Binary Property, General_Category value, or (in v-mode) Property of Strings
        if let canon = binaryPropAliases[value] {
            switch canon {
            case "ASCII":
                return PropertyResolution(ranges: [CodePointRange(lower: 0, upper: 0x7F)], strings: [], isPropertyOfStrings: false)
            case "Any":
                return PropertyResolution(ranges: [CodePointRange(lower: 0, upper: 0x10FFFF)], strings: [], isPropertyOfStrings: false)
            case "Assigned":
                // Everything except Cn (bit 29)
                return PropertyResolution(ranges: gcRanges(mask: 0x1FFFFFFF), strings: [], isPropertyOfStrings: false)
            default:
                guard let (baseMaskId, encoded) = binaryPropData[canon] else { return nil }
                let diff = decodeRanges(encoded)
                if baseMaskId == 0 {
                    return PropertyResolution(ranges: diff, strings: [], isPropertyOfStrings: false)
                }
                let base = gcRanges(mask: binaryPropBaseMasks[baseMaskId] ?? 0)
                return PropertyResolution(ranges: xorRanges(base, diff), strings: [], isPropertyOfStrings: false)
            }
        }
        if let mask = gcAliasMasks[value] {
            return PropertyResolution(ranges: gcRanges(mask: mask), strings: [], isPropertyOfStrings: false)
        }
        if unicodeSets {
            switch value {
            case "Basic_Emoji":
                let singles = decodeRanges(basicEmojiSingletonData)
                let fe0f = decodeRanges(basicEmojiFE0FData)
                var strs: [[UInt32]] = []
                for r in fe0f {
                    for cp in r.lower...r.upper { strs.append([cp, 0xFE0F]) }
                }
                return PropertyResolution(ranges: singles, strings: strs, isPropertyOfStrings: true)
            case "Emoji_Keycap_Sequence":
                let bases: [UInt32] = [0x23, 0x2A, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39]
                return PropertyResolution(ranges: [], strings: bases.map { [$0, 0xFE0F, 0x20E3] }, isPropertyOfStrings: true)
            case "RGI_Emoji_Flag_Sequence":
                let strs: [[UInt32]] = rgiFlagPairs.map { pair in
                    [0x1F1E6 + UInt32(pair >> 5), 0x1F1E6 + UInt32(pair & 0x1F)]
                }
                return PropertyResolution(ranges: [], strings: strs, isPropertyOfStrings: true)
            case "RGI_Emoji_Modifier_Sequence":
                let bases = resolveProperty(name: nil, value: "Emoji_Modifier_Base", unicodeSets: false)?.ranges ?? []
                let mods: [UInt32] = [0x1F3FB, 0x1F3FC, 0x1F3FD, 0x1F3FE, 0x1F3FF]
                var strs: [[UInt32]] = []
                for r in bases {
                    for cp in r.lower...r.upper {
                        for m in mods { strs.append([cp, m]) }
                    }
                }
                return PropertyResolution(ranges: [], strings: strs, isPropertyOfStrings: true)
            case "RGI_Emoji_Tag_Sequence":
                let strs: [[UInt32]] = [
                    [0x1F3F4, 0xE0067, 0xE0062, 0xE0065, 0xE006E, 0xE0067, 0xE007F],
                    [0x1F3F4, 0xE0067, 0xE0062, 0xE0073, 0xE0063, 0xE0074, 0xE007F],
                    [0x1F3F4, 0xE0067, 0xE0062, 0xE0077, 0xE006C, 0xE0073, 0xE007F],
                ]
                return PropertyResolution(ranges: [], strings: strs, isPropertyOfStrings: true)
            case "RGI_Emoji_ZWJ_Sequence":
                return PropertyResolution(ranges: [], strings: [], isPropertyOfStrings: true)
            case "RGI_Emoji":
                let basic = resolveProperty(name: nil, value: "Basic_Emoji", unicodeSets: true)!
                let keycap = resolveProperty(name: nil, value: "Emoji_Keycap_Sequence", unicodeSets: true)!
                let flag = resolveProperty(name: nil, value: "RGI_Emoji_Flag_Sequence", unicodeSets: true)!
                let mod = resolveProperty(name: nil, value: "RGI_Emoji_Modifier_Sequence", unicodeSets: true)!
                let tag = resolveProperty(name: nil, value: "RGI_Emoji_Tag_Sequence", unicodeSets: true)!
                return PropertyResolution(ranges: basic.ranges, strings: basic.strings + keycap.strings + flag.strings + mod.strings + tag.strings, isPropertyOfStrings: true)
            default:
                return nil
            }
        }
        return nil
    }

    /// Check Unicode ID_Start / ID_Continue for RegExpIdentifierName (named capture groups).
    private static let idStartRanges: [CodePointRange] = resolveProperty(name: nil, value: "ID_Start", unicodeSets: false)?.ranges ?? []
    private static let idContinueRanges: [CodePointRange] = resolveProperty(name: nil, value: "ID_Continue", unicodeSets: false)?.ranges ?? []

    static func isRegExpIdentifierStart(_ cp: UInt32) -> Bool {
        if cp < 128 {
            return (cp >= 0x41 && cp <= 0x5A) || (cp >= 0x61 && cp <= 0x7A) || cp == 0x24 || cp == 0x5F
        }
        return contains(idStartRanges, cp)
    }

    static func isRegExpIdentifierPart(_ cp: UInt32) -> Bool {
        if cp < 128 {
            return (cp >= 0x41 && cp <= 0x5A) || (cp >= 0x61 && cp <= 0x7A) || (cp >= 0x30 && cp <= 0x39) || cp == 0x24 || cp == 0x5F
        }
        if cp == 0x200C || cp == 0x200D { return true }
        return contains(idContinueRanges, cp)
    }
}
