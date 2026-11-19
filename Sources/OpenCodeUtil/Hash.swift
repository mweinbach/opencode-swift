/// Pure-Swift FIPS 180-4 SHA-1 and SHA-256 implementations.
/// Zero platform or third-party dependencies — works identically across macOS, iOS, Linux,
/// Windows, Android, FreeBSD, and WebAssembly/WASI.
// parity: util/src/hash.ts#Hash [status=implemented hash=a8b79ef1bfce]
public enum Hash {
    // parity: util/src/hash.ts#Hash.fast [status=implemented hash=ea481ba9656c]
    public static func fast(_ input: String) -> String {
        fast(Array(input.utf8))
    }

    public static func fast(_ input: [UInt8]) -> String {
        hexEncode(sha1Digest(input))
    }

    // parity: util/src/hash.ts#Hash.sha256 [status=implemented hash=76ab1b114b50]
    public static func sha256(_ input: String) -> String {
        sha256(Array(input.utf8))
    }

    public static func sha256(_ input: [UInt8]) -> String {
        hexEncode(sha256Digest(input))
    }
}

private let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)

private func hexEncode(_ bytes: [UInt8]) -> String {
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count * 2)
    for byte in bytes {
        out.append(hexDigits[Int(byte >> 4)])
        out.append(hexDigits[Int(byte & 0x0F)])
    }
    return String(decoding: out, as: UTF8.self)
}

@inline(__always)
private func rotl32(_ x: UInt32, _ n: UInt32) -> UInt32 {
    (x << n) | (x >> (32 - n))
}

@inline(__always)
private func rotr32(_ x: UInt32, _ n: UInt32) -> UInt32 {
    (x >> n) | (x << (32 - n))
}

private func sha1Digest(_ input: [UInt8]) -> [UInt8] {
    var message = input
    let bitLength = UInt64(input.count) &* 8
    message.append(0x80)
    while (message.count % 64) != 56 {
        message.append(0x00)
    }
    for shift in stride(from: 56, through: 0, by: -8) {
        message.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
    }

    var h0: UInt32 = 0x6745_2301
    var h1: UInt32 = 0xEFCD_AB89
    var h2: UInt32 = 0x98BA_DCFE
    var h3: UInt32 = 0x1032_5476
    var h4: UInt32 = 0xC3D2_E1F0

    var w = [UInt32](repeating: 0, count: 80)

    for chunkStart in stride(from: 0, to: message.count, by: 64) {
        for i in 0..<16 {
            let base = chunkStart + i * 4
            w[i] = (UInt32(message[base]) << 24)
                | (UInt32(message[base + 1]) << 16)
                | (UInt32(message[base + 2]) << 8)
                | UInt32(message[base + 3])
        }
        for i in 16..<80 {
            w[i] = rotl32(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1)
        }

        var a = h0
        var b = h1
        var c = h2
        var d = h3
        var e = h4

        for i in 0..<80 {
            let f: UInt32
            let k: UInt32
            if i < 20 {
                f = (b & c) | ((~b) & d)
                k = 0x5A82_7999
            } else if i < 40 {
                f = b ^ c ^ d
                k = 0x6ED9_EBA1
            } else if i < 60 {
                f = (b & c) | (b & d) | (c & d)
                k = 0x8F1B_BCDC
            } else {
                f = b ^ c ^ d
                k = 0xCA62_C1D6
            }

            let temp = rotl32(a, 5) &+ f &+ e &+ k &+ w[i]
            e = d
            d = c
            c = rotl32(b, 30)
            b = a
            a = temp
        }

        h0 = h0 &+ a
        h1 = h1 &+ b
        h2 = h2 &+ c
        h3 = h3 &+ d
        h4 = h4 &+ e
    }

    var out: [UInt8] = []
    out.reserveCapacity(20)
    for h in [h0, h1, h2, h3, h4] {
        out.append(UInt8((h >> 24) & 0xFF))
        out.append(UInt8((h >> 16) & 0xFF))
        out.append(UInt8((h >> 8) & 0xFF))
        out.append(UInt8(h & 0xFF))
    }
    return out
}

private let sha256K: [UInt32] = [
    0x428A_2F98, 0x7137_4491, 0xB5C0_FBCF, 0xE9B5_DBA5, 0x3956_C25B, 0x59F1_11F1, 0x923F_82A4, 0xAB1C_5ED5,
    0xD807_AA98, 0x1283_5B01, 0x2431_85BE, 0x550C_7DC3, 0x72BE_5D74, 0x80DE_B1FE, 0x9BDC_06A7, 0xC19B_F174,
    0xE49B_69C1, 0xEFBE_4786, 0x0FC1_9DC6, 0x240C_A1CC, 0x2DE9_2C6F, 0x4A74_84AA, 0x5CB0_A9DC, 0x76F9_88DA,
    0x983E_5152, 0xA831_C66D, 0xB003_27C8, 0xBF59_7FC7, 0xC6E0_0BF3, 0xD5A7_9147, 0x06CA_6351, 0x1429_2967,
    0x27B7_0A85, 0x2E1B_2138, 0x4D2C_6DFC, 0x5338_0D13, 0x650A_7354, 0x766A_0ABB, 0x81C2_C92E, 0x9272_2C85,
    0xA2BF_E8A1, 0xA81A_664B, 0xC24B_8B70, 0xC76C_51A3, 0xD192_E819, 0xD699_0624, 0xF40E_3585, 0x106A_A070,
    0x19A4_C116, 0x1E37_6C08, 0x2748_774C, 0x34B0_BCB5, 0x391C_0CB3, 0x4ED8_AA4A, 0x5B9C_CA4F, 0x682E_6FF3,
    0x748F_82EE, 0x78A5_636F, 0x84C8_7814, 0x8CC7_0208, 0x90BE_FFFA, 0xA450_6CEB, 0xBEF9_A3F7, 0xC671_78F2,
]

private func sha256Digest(_ input: [UInt8]) -> [UInt8] {
    var message = input
    let bitLength = UInt64(input.count) &* 8
    message.append(0x80)
    while (message.count % 64) != 56 {
        message.append(0x00)
    }
    for shift in stride(from: 56, through: 0, by: -8) {
        message.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
    }

    var h0: UInt32 = 0x6A09_E667
    var h1: UInt32 = 0xBB67_AE85
    var h2: UInt32 = 0x3C6E_F372
    var h3: UInt32 = 0xA54F_F53A
    var h4: UInt32 = 0x510E_527F
    var h5: UInt32 = 0x9B05_688C
    var h6: UInt32 = 0x1F83_D9AB
    var h7: UInt32 = 0x5BE0_CD19

    var w = [UInt32](repeating: 0, count: 64)

    for chunkStart in stride(from: 0, to: message.count, by: 64) {
        for i in 0..<16 {
            let base = chunkStart + i * 4
            w[i] = (UInt32(message[base]) << 24)
                | (UInt32(message[base + 1]) << 16)
                | (UInt32(message[base + 2]) << 8)
                | UInt32(message[base + 3])
        }
        for i in 16..<64 {
            let s0 = rotr32(w[i - 15], 7) ^ rotr32(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotr32(w[i - 2], 17) ^ rotr32(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }

        var a = h0
        var b = h1
        var c = h2
        var d = h3
        var e = h4
        var f = h5
        var g = h6
        var h = h7

        for i in 0..<64 {
            let s1 = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25)
            let ch = (e & f) ^ ((~e) & g)
            let temp1 = h &+ s1 &+ ch &+ sha256K[i] &+ w[i]
            let s0 = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = s0 &+ maj

            h = g
            g = f
            f = e
            e = d &+ temp1
            d = c
            c = b
            b = a
            a = temp1 &+ temp2
        }

        h0 = h0 &+ a
        h1 = h1 &+ b
        h2 = h2 &+ c
        h3 = h3 &+ d
        h4 = h4 &+ e
        h5 = h5 &+ f
        h6 = h6 &+ g
        h7 = h7 &+ h
    }

    var out: [UInt8] = []
    out.reserveCapacity(32)
    for h in [h0, h1, h2, h3, h4, h5, h6, h7] {
        out.append(UInt8((h >> 24) & 0xFF))
        out.append(UInt8((h >> 16) & 0xFF))
        out.append(UInt8((h >> 8) & 0xFF))
        out.append(UInt8(h & 0xFF))
    }
    return out
}
