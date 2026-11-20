// Pure Swift standard-library cryptography for the machine link (`core/src/machine/{noise,identity,join,machines}.ts`).
//
// Upstream reaches these through `node:crypto`. OpenCodeCore must build on Linux, Windows, Android and WASI where
// CryptoKit does not exist, and CryptoKit's Ed25519 signatures are randomized (upstream's, like RFC 8032, are
// deterministic), so the machine subsystem carries its own implementations:
//
// - SHA-256 and SHA-512 (FIPS 180-4), HMAC-SHA256 (RFC 2104)
// - X25519 (RFC 7748)
// - Ed25519 (RFC 8032): key from seed, deterministic signing, verification
// - AES-256-GCM (FIPS 197, NIST SP 800-38D) with a 96-bit nonce and a 128-bit tag
// - Base64 and base64url (RFC 4648)
//
// Every primitive is pinned by RFC / NIST test vectors in `Tests/OpenCodeCoreTests/MachineCryptoTests.swift`.

/// Cryptographic primitives used by the machine link. Byte arrays in, byte arrays out.
public enum MachineCrypto {
    // MARK: - Random

    /// `count` bytes from the system's cryptographically secure generator.
    public static func randomBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        var out = [UInt8](repeating: 0, count: count)
        var index = 0
        while index < count {
            var word = generator.next()
            for _ in 0..<8 where index < count {
                out[index] = UInt8(truncatingIfNeeded: word)
                word >>= 8
                index += 1
            }
        }
        return out
    }

    /// Compares two byte arrays without stopping at the first difference.
    public static func constantTimeEqual(_ left: [UInt8], _ right: [UInt8]) -> Bool {
        guard left.count == right.count else { return false }
        var bits: UInt8 = 0
        for index in 0..<left.count {
            bits |= left[index] ^ right[index]
        }
        return bits == 0
    }

    // MARK: - SHA-256

    private static let sha256K: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    @inline(__always)
    private static func rotr32(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }

    /// FIPS 180-4 SHA-256.
    public static func sha256(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        var data = message
        let bitLength = UInt64(message.count) &* 8
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: data.count, by: 64) {
            for i in 0..<16 {
                let base = chunk + i * 4
                w[i] = UInt32(data[base]) << 24 | UInt32(data[base + 1]) << 16 | UInt32(data[base + 2]) << 8
                    | UInt32(data[base + 3])
            }
            for i in 16..<64 {
                let s0 = rotr32(w[i - 15], 7) ^ rotr32(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr32(w[i - 2], 17) ^ rotr32(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ sha256K[i] &+ w[i]
                let s0 = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d
            h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
        }
        var out: [UInt8] = []
        out.reserveCapacity(32)
        for word in h {
            out.append(UInt8(truncatingIfNeeded: word >> 24))
            out.append(UInt8(truncatingIfNeeded: word >> 16))
            out.append(UInt8(truncatingIfNeeded: word >> 8))
            out.append(UInt8(truncatingIfNeeded: word))
        }
        return out
    }

    /// RFC 2104 HMAC with SHA-256.
    public static func hmacSHA256(key: [UInt8], data: [UInt8]) -> [UInt8] {
        var block = key.count > 64 ? sha256(key) : key
        block += [UInt8](repeating: 0, count: 64 - block.count)
        let inner = block.map { $0 ^ 0x36 }
        let outer = block.map { $0 ^ 0x5c }
        return sha256(outer + sha256(inner + data))
    }

    // MARK: - SHA-512

    private static let sha512K: [UInt64] = [
        0x428a2f98d728ae22, 0x7137449123ef65cd, 0xb5c0fbcfec4d3b2f, 0xe9b5dba58189dbbc, 0x3956c25bf348b538,
        0x59f111f1b605d019, 0x923f82a4af194f9b, 0xab1c5ed5da6d8118, 0xd807aa98a3030242, 0x12835b0145706fbe,
        0x243185be4ee4b28c, 0x550c7dc3d5ffb4e2, 0x72be5d74f27b896f, 0x80deb1fe3b1696b1, 0x9bdc06a725c71235,
        0xc19bf174cf692694, 0xe49b69c19ef14ad2, 0xefbe4786384f25e3, 0x0fc19dc68b8cd5b5, 0x240ca1cc77ac9c65,
        0x2de92c6f592b0275, 0x4a7484aa6ea6e483, 0x5cb0a9dcbd41fbd4, 0x76f988da831153b5, 0x983e5152ee66dfab,
        0xa831c66d2db43210, 0xb00327c898fb213f, 0xbf597fc7beef0ee4, 0xc6e00bf33da88fc2, 0xd5a79147930aa725,
        0x06ca6351e003826f, 0x142929670a0e6e70, 0x27b70a8546d22ffc, 0x2e1b21385c26c926, 0x4d2c6dfc5ac42aed,
        0x53380d139d95b3df, 0x650a73548baf63de, 0x766a0abb3c77b2a8, 0x81c2c92e47edaee6, 0x92722c851482353b,
        0xa2bfe8a14cf10364, 0xa81a664bbc423001, 0xc24b8b70d0f89791, 0xc76c51a30654be30, 0xd192e819d6ef5218,
        0xd69906245565a910, 0xf40e35855771202a, 0x106aa07032bbd1b8, 0x19a4c116b8d2d0c8, 0x1e376c085141ab53,
        0x2748774cdf8eeb99, 0x34b0bcb5e19b48a8, 0x391c0cb3c5c95a63, 0x4ed8aa4ae3418acb, 0x5b9cca4f7763e373,
        0x682e6ff3d6b2b8a3, 0x748f82ee5defb2fc, 0x78a5636f43172f60, 0x84c87814a1f0ab72, 0x8cc702081a6439ec,
        0x90befffa23631e28, 0xa4506cebde82bde9, 0xbef9a3f7b2c67915, 0xc67178f2e372532b, 0xca273eceea26619c,
        0xd186b8c721c0c207, 0xeada7dd6cde0eb1e, 0xf57d4f7fee6ed178, 0x06f067aa72176fba, 0x0a637dc5a2c898a6,
        0x113f9804bef90dae, 0x1b710b35131c471b, 0x28db77f523047d84, 0x32caab7b40c72493, 0x3c9ebe0a15c9bebc,
        0x431d67c49c100d4c, 0x4cc5d4becb3e42b6, 0x597f299cfc657e2a, 0x5fcb6fab3ad6faec, 0x6c44198c4a475817,
    ]

    @inline(__always)
    private static func rotr64(_ x: UInt64, _ n: UInt64) -> UInt64 { (x >> n) | (x << (64 - n)) }

    /// FIPS 180-4 SHA-512.
    public static func sha512(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt64] = [
            0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
            0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
        ]
        var data = message
        let bitLength = UInt64(message.count) &* 8
        data.append(0x80)
        while data.count % 128 != 112 { data.append(0) }
        data += [UInt8](repeating: 0, count: 8)
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }
        var w = [UInt64](repeating: 0, count: 80)
        for chunk in stride(from: 0, to: data.count, by: 128) {
            for i in 0..<16 {
                var word: UInt64 = 0
                for b in 0..<8 { word = word << 8 | UInt64(data[chunk + i * 8 + b]) }
                w[i] = word
            }
            for i in 16..<80 {
                let s0 = rotr64(w[i - 15], 1) ^ rotr64(w[i - 15], 8) ^ (w[i - 15] >> 7)
                let s1 = rotr64(w[i - 2], 19) ^ rotr64(w[i - 2], 61) ^ (w[i - 2] >> 6)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<80 {
                let s1 = rotr64(e, 14) ^ rotr64(e, 18) ^ rotr64(e, 41)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ sha512K[i] &+ w[i]
                let s0 = rotr64(a, 28) ^ rotr64(a, 34) ^ rotr64(a, 39)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d
            h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
        }
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for word in h {
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8(truncatingIfNeeded: word >> UInt64(shift)))
            }
        }
        return out
    }

    // MARK: - Base64 (RFC 4648)

    private static let base64Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
    private static let base64URLAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

    private static func encode(_ bytes: [UInt8], alphabet: [UInt8], pad: Bool) -> String {
        var out: [UInt8] = []
        out.reserveCapacity((bytes.count + 2) / 3 * 4)
        var index = 0
        while index + 3 <= bytes.count {
            let n = UInt32(bytes[index]) << 16 | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2])
            out.append(alphabet[Int(n >> 18 & 63)])
            out.append(alphabet[Int(n >> 12 & 63)])
            out.append(alphabet[Int(n >> 6 & 63)])
            out.append(alphabet[Int(n & 63)])
            index += 3
        }
        let rest = bytes.count - index
        if rest == 1 {
            let n = UInt32(bytes[index]) << 16
            out.append(alphabet[Int(n >> 18 & 63)])
            out.append(alphabet[Int(n >> 12 & 63)])
            if pad { out += Array("==".utf8) }
        } else if rest == 2 {
            let n = UInt32(bytes[index]) << 16 | UInt32(bytes[index + 1]) << 8
            out.append(alphabet[Int(n >> 18 & 63)])
            out.append(alphabet[Int(n >> 12 & 63)])
            out.append(alphabet[Int(n >> 6 & 63)])
            if pad { out.append(UInt8(ascii: "=")) }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func sextet(_ c: UInt8, url: Bool) -> UInt32? {
        switch c {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): return UInt32(c - UInt8(ascii: "A"))
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return UInt32(c - UInt8(ascii: "a") + 26)
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return UInt32(c - UInt8(ascii: "0") + 52)
        case UInt8(ascii: "+") where !url: return 62
        case UInt8(ascii: "/") where !url: return 63
        case UInt8(ascii: "-") where url: return 62
        case UInt8(ascii: "_") where url: return 63
        default: return nil
        }
    }

    private static func decode(_ text: String, url: Bool) -> [UInt8]? {
        var chars = Array(text.utf8)
        // Padding is optional; when present it must complete the last quantum.
        if let firstPad = chars.firstIndex(of: UInt8(ascii: "=")) {
            let padding = chars[firstPad...]
            guard padding.allSatisfy({ $0 == UInt8(ascii: "=") }), padding.count <= 2, chars.count % 4 == 0 else {
                return nil
            }
            chars.removeSubrange(firstPad...)
        }
        if chars.count % 4 == 1 { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(chars.count * 3 / 4)
        var accumulator: UInt32 = 0
        var bits = 0
        for c in chars {
            guard let value = sextet(c, url: url) else { return nil }
            accumulator = accumulator << 6 | value
            bits += 6
            if bits >= 8 {
                bits -= 8
                out.append(UInt8(truncatingIfNeeded: accumulator >> UInt32(bits)))
            }
        }
        return out
    }

    /// Standard base64 with padding, as `Buffer.toString("base64")` writes it.
    public static func base64Encode(_ bytes: [UInt8]) -> String { encode(bytes, alphabet: base64Alphabet, pad: true) }

    /// Standard base64, padding optional. `nil` for any character outside the alphabet.
    public static func base64Decode(_ text: String) -> [UInt8]? { decode(text, url: false) }

    /// Base64url without padding, as `Buffer.toString("base64url")` writes it.
    public static func base64URLEncode(_ bytes: [UInt8]) -> String { encode(bytes, alphabet: base64URLAlphabet, pad: false) }

    /// Base64url, padding optional. `nil` for any character outside the alphabet.
    public static func base64URLDecode(_ text: String) -> [UInt8]? { decode(text, url: true) }
}

// MARK: - Curve25519 field arithmetic (GF(2^255 - 19), sixteen signed 16-bit limbs)

struct MachineField: Sendable {
    var limbs: [Int64]

    init() { limbs = [Int64](repeating: 0, count: 16) }
    init(_ values: [Int64]) {
        limbs = values + [Int64](repeating: 0, count: 16 - values.count)
    }

    static let zero = MachineField()
    static let one = MachineField([1])

    init(bytes: [UInt8]) {
        var values = [Int64](repeating: 0, count: 16)
        for i in 0..<16 {
            values[i] = Int64(bytes[2 * i]) + (Int64(bytes[2 * i + 1]) << 8)
        }
        values[15] &= 0x7fff
        limbs = values
    }

    static func carry(_ o: inout [Int64]) {
        for i in 0..<16 {
            o[i] += 1 << 16
            let c = o[i] >> 16
            if i < 15 {
                o[i + 1] += c - 1
            } else {
                o[0] += 38 * (c - 1)
            }
            o[i] -= c << 16
        }
    }

    /// Swaps `p` and `q` when `bit` is 1, without a branch on it.
    static func conditionalSwap(_ p: inout MachineField, _ q: inout MachineField, _ bit: Int64) {
        let mask = ~(bit - 1)
        for i in 0..<16 {
            let t = mask & (p.limbs[i] ^ q.limbs[i])
            p.limbs[i] ^= t
            q.limbs[i] ^= t
        }
    }

    func bytes() -> [UInt8] {
        var t = limbs
        MachineField.carry(&t)
        MachineField.carry(&t)
        MachineField.carry(&t)
        var m = [Int64](repeating: 0, count: 16)
        for _ in 0..<2 {
            m[0] = t[0] - 0xffed
            for i in 1..<15 {
                m[i] = t[i] - 0xffff - ((m[i - 1] >> 16) & 1)
                m[i - 1] &= 0xffff
            }
            m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1)
            let borrow = (m[15] >> 16) & 1
            m[14] &= 0xffff
            // Keep m (t - p) when it did not borrow.
            let mask = ~((1 - borrow) - 1)
            for i in 0..<16 {
                let x = mask & (t[i] ^ m[i])
                t[i] ^= x
                m[i] ^= x
            }
        }
        var out = [UInt8](repeating: 0, count: 32)
        for i in 0..<16 {
            out[2 * i] = UInt8(truncatingIfNeeded: t[i] & 0xff)
            out[2 * i + 1] = UInt8(truncatingIfNeeded: t[i] >> 8)
        }
        return out
    }

    var isNegative: Bool { bytes()[0] & 1 == 1 }

    static func + (a: MachineField, b: MachineField) -> MachineField {
        var o = MachineField()
        for i in 0..<16 { o.limbs[i] = a.limbs[i] + b.limbs[i] }
        return o
    }

    static func - (a: MachineField, b: MachineField) -> MachineField {
        var o = MachineField()
        for i in 0..<16 { o.limbs[i] = a.limbs[i] - b.limbs[i] }
        return o
    }

    static func * (a: MachineField, b: MachineField) -> MachineField {
        var t = [Int64](repeating: 0, count: 31)
        a.limbs.withUnsafeBufferPointer { x in
            b.limbs.withUnsafeBufferPointer { y in
                for i in 0..<16 {
                    let xi = x[i]
                    for j in 0..<16 { t[i + j] &+= xi &* y[j] }
                }
            }
        }
        for i in 0..<15 { t[i] &+= 38 &* t[i + 16] }
        var o = Array(t[0..<16])
        carry(&o)
        carry(&o)
        return MachineField(o)
    }

    func squared() -> MachineField { self * self }

    /// a^(p-2), the inverse of a non-zero element.
    func inverted() -> MachineField {
        var c = self
        for a in stride(from: 253, through: 0, by: -1) {
            c = c.squared()
            if a != 2 && a != 4 { c = c * self }
        }
        return c
    }

    /// a^((p-5)/8), used for square roots.
    func pow2523() -> MachineField {
        var c = self
        for a in stride(from: 250, through: 0, by: -1) {
            c = c.squared()
            if a != 1 { c = c * self }
        }
        return c
    }

    func equals(_ other: MachineField) -> Bool {
        MachineCrypto.constantTimeEqual(bytes(), other.bytes())
    }
}

// MARK: - X25519 (RFC 7748)

extension MachineCrypto {
    private static let a24 = MachineField([0xdb41, 1])

    /// RFC 7748 X25519: `scalar` times the point with u-coordinate `point`. Both are 32 bytes.
    public static func x25519(scalar: [UInt8], point: [UInt8]) -> [UInt8] {
        precondition(scalar.count == 32 && point.count == 32, "X25519 takes 32-byte inputs")
        var z = scalar
        z[31] = (z[31] & 127) | 64
        z[0] &= 248
        let x = MachineField(bytes: point)
        var a = MachineField.one
        var b = x
        var c = MachineField.zero
        var d = MachineField.one
        for i in stride(from: 254, through: 0, by: -1) {
            let bit = Int64((z[i >> 3] >> UInt8(i & 7)) & 1)
            MachineField.conditionalSwap(&a, &b, bit)
            MachineField.conditionalSwap(&c, &d, bit)
            var e = a + c
            a = a - c
            c = b + d
            b = b - d
            d = e.squared()
            let f = a.squared()
            a = c * a
            c = b * e
            e = a + c
            a = a - c
            b = a.squared()
            c = d - f
            a = c * a24
            a = a + d
            c = c * a
            a = d * f
            d = b * x
            b = e.squared()
            MachineField.conditionalSwap(&a, &b, bit)
            MachineField.conditionalSwap(&c, &d, bit)
        }
        return (a * c.inverted()).bytes()
    }

    /// The X25519 public key of a 32-byte private key: the private key times the base point 9.
    public static func x25519PublicKey(privateKey: [UInt8]) -> [UInt8] {
        var base = [UInt8](repeating: 0, count: 32)
        base[0] = 9
        return x25519(scalar: privateKey, point: base)
    }
}

// MARK: - Ed25519 (RFC 8032)

struct MachineEdPoint: Sendable {
    var x: MachineField
    var y: MachineField
    var z: MachineField
    var t: MachineField

    static let d = MachineField([
        0x78a3, 0x1359, 0x4dca, 0x75eb, 0xd8ab, 0x4141, 0x0a4d, 0x0070,
        0xe898, 0x7779, 0x4079, 0x8cc7, 0xfe73, 0x2b6f, 0x6cee, 0x5203,
    ])
    static let d2 = MachineField([
        0xf159, 0x26b2, 0x9b94, 0xebd6, 0xb156, 0x8283, 0x149a, 0x00e0,
        0xd130, 0xeef3, 0x80f2, 0x198e, 0xfce7, 0x56df, 0xd9dc, 0x2406,
    ])
    static let baseX = MachineField([
        0xd51a, 0x8f25, 0x2d60, 0xc956, 0xa7b2, 0x9525, 0xc760, 0x692c,
        0xdc5c, 0xfdd6, 0xe231, 0xc0a4, 0x53fe, 0xcd6e, 0x36d3, 0x2169,
    ])
    static let baseY = MachineField([
        0x6658, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666,
        0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666,
    ])
    /// sqrt(-1)
    static let sqrtMinusOne = MachineField([
        0xa0b0, 0x4a0e, 0x1b27, 0xc4ee, 0xe478, 0xad2f, 0x1806, 0x2f43,
        0xd7a7, 0x3dfb, 0x0099, 0x2b4d, 0xdf0b, 0x4fc1, 0x2480, 0x2b83,
    ])

    static let identity = MachineEdPoint(x: .zero, y: .one, z: .one, t: .zero)
    static let base = MachineEdPoint(x: baseX, y: baseY, z: .one, t: baseX * baseY)

    /// Extended twisted Edwards addition (complete for a = -1).
    static func + (p: MachineEdPoint, q: MachineEdPoint) -> MachineEdPoint {
        let a = (p.y - p.x) * (q.y - q.x)
        let b = (p.x + p.y) * (q.x + q.y)
        let c = p.t * q.t * d2
        var dd = p.z * q.z
        dd = dd + dd
        let e = b - a
        let f = dd - c
        let g = dd + c
        let h = b + a
        return MachineEdPoint(x: e * f, y: h * g, z: g * f, t: e * h)
    }

    static func conditionalSwap(_ p: inout MachineEdPoint, _ q: inout MachineEdPoint, _ bit: Int64) {
        MachineField.conditionalSwap(&p.x, &q.x, bit)
        MachineField.conditionalSwap(&p.y, &q.y, bit)
        MachineField.conditionalSwap(&p.z, &q.z, bit)
        MachineField.conditionalSwap(&p.t, &q.t, bit)
    }

    /// `scalar` (32 bytes, little-endian) times this point, by a fixed-sequence ladder.
    func multiplied(by scalar: [UInt8]) -> MachineEdPoint {
        var p = MachineEdPoint.identity
        var q = self
        for i in stride(from: 255, through: 0, by: -1) {
            let bit = Int64((scalar[i / 8] >> UInt8(i & 7)) & 1)
            MachineEdPoint.conditionalSwap(&p, &q, bit)
            q = q + p
            p = p + p
            MachineEdPoint.conditionalSwap(&p, &q, bit)
        }
        return p
    }

    func encoded() -> [UInt8] {
        let zi = z.inverted()
        let tx = x * zi
        let ty = y * zi
        var out = ty.bytes()
        out[31] ^= (tx.isNegative ? 1 : 0) << 7
        return out
    }

    /// Decodes a point as RFC 8032 section 5.1.3 does, or `nil` when no point has that y.
    static func decode(_ bytes: [UInt8]) -> MachineEdPoint? {
        guard bytes.count == 32 else { return nil }
        let y = MachineField(bytes: bytes)
        let y2 = y.squared()
        let u = y2 - .one
        let v = y2 * d + .one
        // x = (u / v)^((p+3)/8) computed as u v^3 (u v^7)^((p-5)/8)
        let v3 = v.squared() * v
        var x = (v3.squared() * v * u).pow2523() * v3 * u
        let vx2 = x.squared() * v
        if !vx2.equals(u) {
            guard vx2.equals(MachineField.zero - u) else { return nil }
            x = x * sqrtMinusOne
        }
        let sign = (bytes[31] >> 7) == 1
        if x.isNegative != sign {
            x = MachineField.zero - x
        }
        return MachineEdPoint(x: x, y: y, z: .one, t: x * y)
    }
}

extension MachineCrypto {
    /// The group order L, little-endian bytes.
    private static let groupOrder: [Int64] = [
        0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10,
    ]

    /// Reduces a little-endian number of up to 64 byte-sized limbs modulo L into 32 bytes.
    private static func reduceModL(_ input: [Int64]) -> [UInt8] {
        var x = input + [Int64](repeating: 0, count: 64 - input.count)
        // 16 L = 2^256 + 16 (L - 2^252): fold each byte above 2^256 down by subtracting that multiple of L.
        for i in stride(from: 63, through: 32, by: -1) {
            var carry: Int64 = 0
            var j = i - 32
            while j < i - 12 {
                x[j] += carry - 16 * x[i] * groupOrder[j - (i - 32)]
                carry = (x[j] + 128) >> 8
                x[j] -= carry << 8
                j += 1
            }
            x[j] += carry
            x[i] = 0
        }
        var carry: Int64 = 0
        for j in 0..<32 {
            x[j] += carry - (x[31] >> 4) * groupOrder[j]
            carry = x[j] >> 8
            x[j] &= 255
        }
        for j in 0..<32 { x[j] -= carry * groupOrder[j] }
        var out = [UInt8](repeating: 0, count: 32)
        for i in 0..<32 {
            if i < 31 { x[i + 1] += x[i] >> 8 }
            out[i] = UInt8(truncatingIfNeeded: x[i] & 255)
        }
        return out
    }

    private static func reduceModL(bytes: [UInt8]) -> [UInt8] {
        reduceModL(bytes.map { Int64($0) })
    }

    private static func clampedScalar(seed: [UInt8]) -> (scalar: [UInt8], prefix: [UInt8]) {
        let digest = sha512(seed)
        var scalar = Array(digest[0..<32])
        scalar[0] &= 248
        scalar[31] &= 127
        scalar[31] |= 64
        return (scalar, Array(digest[32..<64]))
    }

    /// The Ed25519 public key of a 32-byte seed (RFC 8032 section 5.1.5).
    public static func ed25519PublicKey(seed: [UInt8]) -> [UInt8] {
        precondition(seed.count == 32, "An Ed25519 seed is 32 bytes")
        return MachineEdPoint.base.multiplied(by: clampedScalar(seed: seed).scalar).encoded()
    }

    /// The deterministic Ed25519 signature of `message` under a 32-byte seed (RFC 8032 section 5.1.6).
    public static func ed25519Sign(seed: [UInt8], message: [UInt8]) -> [UInt8] {
        precondition(seed.count == 32, "An Ed25519 seed is 32 bytes")
        let (scalar, prefix) = clampedScalar(seed: seed)
        let publicKey = MachineEdPoint.base.multiplied(by: scalar).encoded()
        let r = reduceModL(bytes: sha512(prefix + message))
        let encodedR = MachineEdPoint.base.multiplied(by: r).encoded()
        let k = reduceModL(bytes: sha512(encodedR + publicKey + message))
        // S = r + k * a mod L
        var x = [Int64](repeating: 0, count: 64)
        for i in 0..<32 { x[i] = Int64(r[i]) }
        for i in 0..<32 {
            for j in 0..<32 { x[i + j] += Int64(k[i]) * Int64(scalar[j]) }
        }
        return encodedR + reduceModL(x)
    }

    /// Whether `signature` is `publicKey`'s Ed25519 signature of `message` (RFC 8032 section 5.1.7, cofactorless).
    /// Refuses a non-canonical S and a key that is not a point; accepts small-order keys as OpenSSL does.
    public static func ed25519Verify(publicKey: [UInt8], message: [UInt8], signature: [UInt8]) -> Bool {
        guard publicKey.count == 32, signature.count == 64 else { return false }
        let s = Array(signature[32..<64])
        guard isCanonicalScalar(s), let a = MachineEdPoint.decode(publicKey) else { return false }
        let encodedR = Array(signature[0..<32])
        let k = reduceModL(bytes: sha512(encodedR + publicKey + message))
        let negA = MachineEdPoint(x: MachineField.zero - a.x, y: a.y, z: a.z, t: MachineField.zero - a.t)
        let check = MachineEdPoint.base.multiplied(by: s) + negA.multiplied(by: k)
        return constantTimeEqual(check.encoded(), encodedR)
    }

    /// Whether a 32-byte little-endian scalar is below L.
    private static func isCanonicalScalar(_ s: [UInt8]) -> Bool {
        for i in stride(from: 31, through: 0, by: -1) {
            let l = UInt8(groupOrder[i])
            if s[i] < l { return true }
            if s[i] > l { return false }
        }
        return false
    }
}

// MARK: - AES-256-GCM (FIPS 197, NIST SP 800-38D)

extension MachineCrypto {
    private static let sbox: [UInt8] = [
        0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
        0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
        0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
        0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
        0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
        0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
        0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
        0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
        0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
        0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
        0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
        0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
        0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
        0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
        0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
        0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
    ]

    /// FIPS 197 AES-256 with an expanded key.
    struct AES256: Sendable {
        let roundKeys: [UInt8]

        init(key: [UInt8]) {
            precondition(key.count == 32, "AES-256 takes a 32-byte key")
            var w = key
            w.reserveCapacity(240)
            var rcon: UInt8 = 1
            var i = 8
            while w.count < 240 {
                var temp = Array(w[(w.count - 4)...])
                if i % 8 == 0 {
                    temp = [temp[1], temp[2], temp[3], temp[0]].map { MachineCrypto.sbox[Int($0)] }
                    temp[0] ^= rcon
                    rcon = MachineCrypto.xtime(rcon)
                } else if i % 8 == 4 {
                    temp = temp.map { MachineCrypto.sbox[Int($0)] }
                }
                for b in 0..<4 { w.append(w[w.count - 32] ^ temp[b]) }
                i += 1
            }
            roundKeys = w
        }

        func encrypt(_ block: [UInt8]) -> [UInt8] {
            var s = block
            for b in 0..<16 { s[b] ^= roundKeys[b] }
            for round in 1...14 {
                // SubBytes
                for b in 0..<16 { s[b] = MachineCrypto.sbox[Int(s[b])] }
                // ShiftRows (column-major state)
                var shifted = s
                for column in 0..<4 {
                    for row in 0..<4 {
                        shifted[column * 4 + row] = s[((column + row) % 4) * 4 + row]
                    }
                }
                s = shifted
                // MixColumns
                if round != 14 {
                    for column in 0..<4 {
                        let a0 = s[column * 4], a1 = s[column * 4 + 1], a2 = s[column * 4 + 2], a3 = s[column * 4 + 3]
                        let all = a0 ^ a1 ^ a2 ^ a3
                        s[column * 4] = a0 ^ all ^ MachineCrypto.xtime(a0 ^ a1)
                        s[column * 4 + 1] = a1 ^ all ^ MachineCrypto.xtime(a1 ^ a2)
                        s[column * 4 + 2] = a2 ^ all ^ MachineCrypto.xtime(a2 ^ a3)
                        s[column * 4 + 3] = a3 ^ all ^ MachineCrypto.xtime(a3 ^ a0)
                    }
                }
                for b in 0..<16 { s[b] ^= roundKeys[round * 16 + b] }
            }
            return s
        }
    }

    @inline(__always)
    fileprivate static func xtime(_ x: UInt8) -> UInt8 {
        (x << 1) ^ ((x >> 7) & 1) * 0x1b
    }

    /// GF(2^128) multiplication in GCM's bit order.
    private static func gfMultiply(_ x: (UInt64, UInt64), _ y: (UInt64, UInt64)) -> (UInt64, UInt64) {
        var z: (UInt64, UInt64) = (0, 0)
        var v = y
        for i in 0..<128 {
            let word = i < 64 ? x.0 : x.1
            let bit = (word >> UInt64(63 - (i % 64))) & 1
            let mask = 0 &- bit
            z.0 ^= v.0 & mask
            z.1 ^= v.1 & mask
            let lsb = v.1 & 1
            v.1 = (v.1 >> 1) | (v.0 << 63)
            v.0 = (v.0 >> 1) ^ (0xe100000000000000 & (0 &- lsb))
        }
        return z
    }

    private static func words(_ block: [UInt8]) -> (UInt64, UInt64) {
        var hi: UInt64 = 0
        var lo: UInt64 = 0
        for i in 0..<8 { hi = hi << 8 | UInt64(block[i]) }
        for i in 8..<16 { lo = lo << 8 | UInt64(block[i]) }
        return (hi, lo)
    }

    private static func block(_ words: (UInt64, UInt64)) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 {
            out[i] = UInt8(truncatingIfNeeded: words.0 >> UInt64(56 - 8 * i))
            out[8 + i] = UInt8(truncatingIfNeeded: words.1 >> UInt64(56 - 8 * i))
        }
        return out
    }

    private static func ghash(key h: (UInt64, UInt64), aad: [UInt8], ciphertext: [UInt8]) -> [UInt8] {
        var y: (UInt64, UInt64) = (0, 0)
        func absorb(_ data: [UInt8]) {
            var offset = 0
            while offset < data.count {
                var chunk = Array(data[offset..<min(offset + 16, data.count)])
                chunk += [UInt8](repeating: 0, count: 16 - chunk.count)
                let w = words(chunk)
                y = gfMultiply((y.0 ^ w.0, y.1 ^ w.1), h)
                offset += 16
            }
        }
        absorb(aad)
        absorb(ciphertext)
        let lengths = (UInt64(aad.count) &* 8, UInt64(ciphertext.count) &* 8)
        y = gfMultiply((y.0 ^ lengths.0, y.1 ^ lengths.1), h)
        return block(y)
    }

    private static func ctr(_ aes: AES256, counterBlock: [UInt8], _ input: [UInt8]) -> [UInt8] {
        var counter = counterBlock
        var out = [UInt8](repeating: 0, count: input.count)
        var offset = 0
        while offset < input.count {
            // inc32
            var carry = 1
            for i in stride(from: 15, through: 12, by: -1) where carry != 0 {
                let sum = Int(counter[i]) + carry
                counter[i] = UInt8(truncatingIfNeeded: sum)
                carry = sum >> 8
            }
            let stream = aes.encrypt(counter)
            for i in 0..<min(16, input.count - offset) {
                out[offset + i] = input[offset + i] ^ stream[i]
            }
            offset += 16
        }
        return out
    }

    /// AES-256-GCM encryption with a 12-byte nonce: the ciphertext with the 16-byte tag appended.
    public static func aes256GCMSeal(key: [UInt8], nonce: [UInt8], aad: [UInt8], plaintext: [UInt8]) -> [UInt8] {
        precondition(nonce.count == 12, "GCM here takes a 12-byte nonce")
        let aes = AES256(key: key)
        let h = words(aes.encrypt([UInt8](repeating: 0, count: 16)))
        let j0 = nonce + [0, 0, 0, 1]
        let ciphertext = ctr(aes, counterBlock: j0, plaintext)
        let s = ghash(key: h, aad: aad, ciphertext: ciphertext)
        let mask = aes.encrypt(j0)
        return ciphertext + (0..<16).map { s[$0] ^ mask[$0] }
    }

    /// AES-256-GCM decryption of ciphertext-with-tag, or `nil` when the tag does not authenticate it.
    public static func aes256GCMOpen(key: [UInt8], nonce: [UInt8], aad: [UInt8], sealed: [UInt8]) -> [UInt8]? {
        precondition(nonce.count == 12, "GCM here takes a 12-byte nonce")
        guard sealed.count >= 16 else { return nil }
        let ciphertext = Array(sealed[0..<(sealed.count - 16)])
        let tag = Array(sealed[(sealed.count - 16)...])
        let aes = AES256(key: key)
        let h = words(aes.encrypt([UInt8](repeating: 0, count: 16)))
        let j0 = nonce + [0, 0, 0, 1]
        let s = ghash(key: h, aad: aad, ciphertext: ciphertext)
        let mask = aes.encrypt(j0)
        let expected = (0..<16).map { s[$0] ^ mask[$0] }
        guard constantTimeEqual(expected, tag) else { return nil }
        return ctr(aes, counterBlock: j0, ciphertext)
    }
}
