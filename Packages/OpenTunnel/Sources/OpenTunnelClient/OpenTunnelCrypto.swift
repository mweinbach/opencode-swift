import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Generated ECDSA P-256 private key (PKCS#8 PEM) and signed PKCS#10 CSR PEM for an OpenTunnel hostname.
public struct OpenTunnelGeneratedKeyAndCSR: Equatable, Hashable, Sendable {
    public let privateKeyPEM: String
    public let csrPEM: String

    public init(privateKeyPEM: String, csrPEM: String) {
        self.privateKeyPEM = privateKeyPEM
        self.csrPEM = csrPEM
    }
}

/// Injectable cryptographic key & PKCS#10 CSR generator for OpenTunnel provisioning.
public protocol OpenTunnelKeyProvider: Sendable {
    func generateKeyAndCSR(hostname: String) async throws -> OpenTunnelGeneratedKeyAndCSR
}

/// Default cross-platform P-256 ECDSA key + PKCS#10 CSR generator.
/// Uses Apple `CryptoKit` when available and a self-contained pure-Swift NIST P-256 + SHA-256
/// implementation on Linux, Windows, Android, FreeBSD, and WASI.
public struct DefaultOpenTunnelKeyProvider: OpenTunnelKeyProvider, Sendable {
    public static let shared = DefaultOpenTunnelKeyProvider()

    public init() {}

    public func generateKeyAndCSR(hostname: String) async throws -> OpenTunnelGeneratedKeyAndCSR {
        #if canImport(CryptoKit)
        return try generateWithCryptoKit(hostname: hostname)
        #else
        return try generatePureSwift(hostname: hostname)
        #endif
    }

    #if canImport(CryptoKit)
    internal func generateWithCryptoKit(hostname: String) throws -> OpenTunnelGeneratedKeyAndCSR {
        let key = P256.Signing.PrivateKey()
        let privateKeyPEM = key.pemRepresentation.hasSuffix("\n")
            ? key.pemRepresentation
            : key.pemRepresentation + "\n"
        let spkiDER = Array(key.publicKey.derRepresentation)
        let certReqInfo = OpenTunnelASN1.certificationRequestInfo(hostname: hostname, spkiDER: spkiDER)
        let signature = try key.signature(for: Data(certReqInfo))
        let csrDER = OpenTunnelASN1.wrapSignedCSR(infoDER: certReqInfo, ecdsaDERSignature: Array(signature.derRepresentation))
        let csrPEM = OpenTunnelASN1.encodePEM(label: "CERTIFICATE REQUEST", der: csrDER)
        return OpenTunnelGeneratedKeyAndCSR(privateKeyPEM: privateKeyPEM, csrPEM: csrPEM)
    }
    #endif

    /// Pure-Swift NIST P-256 + SHA-256 ECDSA keypair & PKCS#10 CSR generator (zero external dependencies).
    internal func generatePureSwift(hostname: String) throws -> OpenTunnelGeneratedKeyAndCSR {
        let scalar = OpenTunnelP256.randomScalar()
        return try generatePureSwift(hostname: hostname, privateScalar: scalar)
    }

    internal func generatePureSwift(hostname: String, privateScalar: [UInt8]) throws -> OpenTunnelGeneratedKeyAndCSR {
        guard let (pubX, pubY) = OpenTunnelP256.publicKey(fromPrivateScalar: privateScalar) else {
            throw OpenTunnelClientError(message: "Failed to derive P-256 public key")
        }
        let uncompressedPub: [UInt8] = [0x04] + pubX + pubY
        let spkiDER = OpenTunnelASN1.p256SubjectPublicKeyInfo(uncompressedPublicKey: uncompressedPub)
        let pkcs8DER = OpenTunnelASN1.p256PKCS8PrivateKey(scalar32: privateScalar, uncompressedPublicKey: uncompressedPub)
        let privateKeyPEM = OpenTunnelASN1.encodePEM(label: "PRIVATE KEY", der: pkcs8DER) + "\n"

        let certReqInfo = OpenTunnelASN1.certificationRequestInfo(hostname: hostname, spkiDER: spkiDER)
        let digest = OpenTunnelSHA256.hash(certReqInfo)
        guard let (r, s) = OpenTunnelP256.signDigest(digest32: digest, privateScalar32: privateScalar) else {
            throw OpenTunnelClientError(message: "Failed to sign PKCS#10 CSR with P-256")
        }
        let sigDER = OpenTunnelASN1.sequence([OpenTunnelASN1.integer(r), OpenTunnelASN1.integer(s)])
        let csrDER = OpenTunnelASN1.wrapSignedCSR(infoDER: certReqInfo, ecdsaDERSignature: sigDER)
        let csrPEM = OpenTunnelASN1.encodePEM(label: "CERTIFICATE REQUEST", der: csrDER)
        return OpenTunnelGeneratedKeyAndCSR(privateKeyPEM: privateKeyPEM, csrPEM: csrPEM)
    }
}

// MARK: - Minimal ASN.1 DER & PEM Builder (Matches `@opentunnel/client/src/effect/csr.ts`)

internal enum OpenTunnelASN1 {
    private static let oidCommonName = "2.5.4.3"
    private static let oidExtensionRequest = "1.2.840.113549.1.9.14"
    private static let oidSubjectAltName = "2.5.29.17"
    private static let oidECDSAWithSHA256 = "1.2.840.10045.4.3.2"
    private static let oidECPublicKey = "1.2.840.10045.2.1"
    private static let oidPrime256v1 = "1.2.840.10045.3.1.7"

    static func der(tag: UInt8, content: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [tag]
        let len = content.count
        if len < 0x80 {
            out.append(UInt8(len))
        } else {
            var lenBytes: [UInt8] = []
            var n = len
            while n > 0 {
                lenBytes.insert(UInt8(n & 0xFF), at: 0)
                n >>= 8
            }
            out.append(UInt8(0x80 | lenBytes.count))
            out.append(contentsOf: lenBytes)
        }
        out.append(contentsOf: content)
        return out
    }

    static func sequence(_ parts: [[UInt8]]) -> [UInt8] {
        der(tag: 0x30, content: concat(parts))
    }

    static func set(_ parts: [[UInt8]]) -> [UInt8] {
        der(tag: 0x31, content: concat(parts))
    }

    static func utf8String(_ value: String) -> [UInt8] {
        der(tag: 0x0C, content: Array(value.utf8))
    }

    static func dnsName(_ value: String) -> [UInt8] {
        der(tag: 0x82, content: Array(value.utf8))
    }

    static func octetString(_ bytes: [UInt8]) -> [UInt8] {
        der(tag: 0x04, content: bytes)
    }

    static func bitString(_ bytes: [UInt8]) -> [UInt8] {
        der(tag: 0x03, content: [0x00] + bytes)
    }

    static func integer(_ bytes: [UInt8]) -> [UInt8] {
        var start = 0
        while start < bytes.count - 1 && bytes[start] == 0 {
            start += 1
        }
        var trimmed = Array(bytes[start...])
        if let first = trimmed.first, (first & 0x80) != 0 {
            trimmed.insert(0x00, at: 0)
        }
        return der(tag: 0x02, content: trimmed)
    }

    static func oid(_ dotted: String) -> [UInt8] {
        let arcs = dotted.split(separator: ".").compactMap { UInt64($0) }
        guard arcs.count >= 2 else { return der(tag: 0x06, content: []) }
        var bytes: [UInt8] = [UInt8(arcs[0] * 40 + arcs[1])]
        for arc in arcs.dropFirst(2) {
            var encoded: [UInt8] = [UInt8(arc & 0x7F)]
            var n = arc >> 7
            while n > 0 {
                encoded.insert(UInt8((n & 0x7F) | 0x80), at: 0)
                n >>= 7
            }
            bytes.append(contentsOf: encoded)
        }
        return der(tag: 0x06, content: bytes)
    }

    static func p256SubjectPublicKeyInfo(uncompressedPublicKey: [UInt8]) -> [UInt8] {
        let algID = sequence([oid(oidECPublicKey), oid(oidPrime256v1)])
        return sequence([algID, bitString(uncompressedPublicKey)])
    }

    static func p256PKCS8PrivateKey(scalar32: [UInt8], uncompressedPublicKey: [UInt8]) -> [UInt8] {
        let ecPrivateKey = sequence([
            der(tag: 0x02, content: [0x01]),
            octetString(scalar32),
            der(tag: 0xA1, content: bitString(uncompressedPublicKey)),
        ])
        let algID = sequence([oid(oidECPublicKey), oid(oidPrime256v1)])
        return sequence([
            der(tag: 0x02, content: [0x00]),
            algID,
            octetString(ecPrivateKey),
        ])
    }

    static func certificationRequestInfo(hostname: String, spkiDER: [UInt8]) -> [UInt8] {
        let subject = sequence([set([sequence([oid(oidCommonName), utf8String(hostname)])])])
        let sanExtension = sequence([
            oid(oidSubjectAltName),
            octetString(sequence([dnsName(hostname), dnsName("*.\(hostname)")])),
        ])
        let attributes = der(
            tag: 0xA0,
            content: sequence([
                oid(oidExtensionRequest),
                set([sequence([sanExtension])]),
            ])
        )
        return sequence([
            der(tag: 0x02, content: [0x00]),
            subject,
            spkiDER,
            attributes,
        ])
    }

    static func wrapSignedCSR(infoDER: [UInt8], ecdsaDERSignature: [UInt8]) -> [UInt8] {
        sequence([
            infoDER,
            sequence([oid(oidECDSAWithSHA256)]),
            bitString(ecdsaDERSignature),
        ])
    }

    static func encodePEM(label: String, der: [UInt8]) -> String {
        let base64 = Data(der).base64EncodedString()
        var lines: [String] = ["-----BEGIN \(label)-----"]
        var idx = base64.startIndex
        while idx < base64.endIndex {
            let next = base64.index(idx, offsetBy: 64, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[idx..<next]))
            idx = next
        }
        lines.append("-----END \(label)-----")
        return lines.joined(separator: "\n")
    }

    private static func concat(_ parts: [[UInt8]]) -> [UInt8] {
        let total = parts.reduce(0) { $0 + $1.count }
        var out: [UInt8] = []
        out.reserveCapacity(total)
        for p in parts { out.append(contentsOf: p) }
        return out
    }
}

// MARK: - Pure-Swift SHA-256

internal enum OpenTunnelSHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        let bitLen = UInt64(message.count) &* 8
        var data = message
        data.append(0x80)
        while (data.count % 64) != 56 {
            data.append(0x00)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((bitLen >> shift) & 0xFF))
        }

        var w = [UInt32](repeating: 0, count: 64)
        for chunkStart in stride(from: 0, to: data.count, by: 64) {
            for i in 0..<16 {
                let off = chunkStart + i * 4
                w[i] = (UInt32(data[off]) << 24)
                    | (UInt32(data[off + 1]) << 16)
                    | (UInt32(data[off + 2]) << 8)
                    | UInt32(data[off + 3])
            }
            for i in 16..<64 {
                let s0 = ror(w[i - 15], 7) ^ ror(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = ror(w[i - 2], 17) ^ ror(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3]
            var e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = ror(e, 6) ^ ror(e, 11) ^ ror(e, 25)
                let ch = (e & f) ^ ((~e) & g)
                let temp1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = ror(a, 2) ^ ror(a, 13) ^ ror(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ temp1
                d = c; c = b; b = a; a = temp1 &+ temp2
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d
            h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
        }

        var digest: [UInt8] = []
        digest.reserveCapacity(32)
        for word in h {
            digest.append(UInt8((word >> 24) & 0xFF))
            digest.append(UInt8((word >> 16) & 0xFF))
            digest.append(UInt8((word >> 8) & 0xFF))
            digest.append(UInt8(word & 0xFF))
        }
        return digest
    }

    @inline(__always)
    private static func ror(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }
}

// MARK: - Pure-Swift NIST P-256 (secp256r1) ECDSA

internal enum OpenTunnelP256 {
    /// 256-bit unsigned integer stored as 4 little-endian `UInt64` limbs.
    struct U256: Equatable {
        var l0: UInt64
        var l1: UInt64
        var l2: UInt64
        var l3: UInt64

        static let zero = U256(l0: 0, l1: 0, l2: 0, l3: 0)
        static let one = U256(l0: 1, l1: 0, l2: 0, l3: 0)

        var isZero: Bool { (l0 | l1 | l2 | l3) == 0 }

        func bit(_ index: Int) -> Bool {
            let limb: UInt64
            switch index >> 6 {
            case 0: limb = l0
            case 1: limb = l1
            case 2: limb = l2
            case 3: limb = l3
            default: return false
            }
            return ((limb >> (index & 63)) & 1) != 0
        }

        static func fromBigEndian(_ bytes: [UInt8]) -> U256 {
            var padded = bytes
            if padded.count < 32 {
                padded = Array(repeating: 0, count: 32 - padded.count) + padded
            } else if padded.count > 32 {
                padded = Array(padded.suffix(32))
            }
            func load(_ off: Int) -> UInt64 {
                var v: UInt64 = 0
                for i in 0..<8 { v = (v << 8) | UInt64(padded[off + i]) }
                return v
            }
            return U256(l0: load(24), l1: load(16), l2: load(8), l3: load(0))
        }

        func toBigEndian() -> [UInt8] {
            var out = [UInt8](repeating: 0, count: 32)
            let limbs = [l3, l2, l1, l0]
            for (idx, limb) in limbs.enumerated() {
                for b in 0..<8 {
                    out[idx * 8 + b] = UInt8((limb >> ((7 - b) * 8)) & 0xFF)
                }
            }
            return out
        }

        static func >= (lhs: U256, rhs: U256) -> Bool {
            if lhs.l3 != rhs.l3 { return lhs.l3 > rhs.l3 }
            if lhs.l2 != rhs.l2 { return lhs.l2 > rhs.l2 }
            if lhs.l1 != rhs.l1 { return lhs.l1 > rhs.l1 }
            return lhs.l0 >= rhs.l0
        }

        static func addWithCarry(_ a: U256, _ b: U256) -> (U256, Bool) {
            let (r0, c0) = a.l0.addingReportingOverflow(b.l0)
            let (s1, c1a) = a.l1.addingReportingOverflow(b.l1)
            let (r1, c1b) = s1.addingReportingOverflow(c0 ? 1 : 0)
            let c1 = c1a || c1b
            let (s2, c2a) = a.l2.addingReportingOverflow(b.l2)
            let (r2, c2b) = s2.addingReportingOverflow(c1 ? 1 : 0)
            let c2 = c2a || c2b
            let (s3, c3a) = a.l3.addingReportingOverflow(b.l3)
            let (r3, c3b) = s3.addingReportingOverflow(c2 ? 1 : 0)
            return (U256(l0: r0, l1: r1, l2: r2, l3: r3), c3a || c3b)
        }

        static func subWithBorrow(_ a: U256, _ b: U256) -> (U256, Bool) {
            let (r0, b0) = a.l0.subtractingReportingOverflow(b.l0)
            let (d1, b1a) = a.l1.subtractingReportingOverflow(b.l1)
            let (r1, b1b) = d1.subtractingReportingOverflow(b0 ? 1 : 0)
            let b1 = b1a || b1b
            let (d2, b2a) = a.l2.subtractingReportingOverflow(b.l2)
            let (r2, b2b) = d2.subtractingReportingOverflow(b1 ? 1 : 0)
            let b2 = b2a || b2b
            let (d3, b3a) = a.l3.subtractingReportingOverflow(b.l3)
            let (r3, b3b) = d3.subtractingReportingOverflow(b2 ? 1 : 0)
            return (U256(l0: r0, l1: r1, l2: r2, l3: r3), b3a || b3b)
        }

        static func addMod(_ a: U256, _ b: U256, mod m: U256) -> U256 {
            let (sum, carry) = addWithCarry(a, b)
            if carry || sum >= m {
                return subWithBorrow(sum, m).0
            }
            return sum
        }

        static func subMod(_ a: U256, _ b: U256, mod m: U256) -> U256 {
            let (diff, borrow) = subWithBorrow(a, b)
            if borrow {
                return addWithCarry(diff, m).0
            }
            return diff
        }

        static func mulMod(_ a: U256, _ b: U256, mod m: U256) -> U256 {
            var acc = U256.zero
            for bitIdx in stride(from: 255, through: 0, by: -1) {
                acc = addMod(acc, acc, mod: m)
                if b.bit(bitIdx) {
                    acc = addMod(acc, a, mod: m)
                }
            }
            return acc
        }

        static func powMod(_ base: U256, exp: U256, mod m: U256) -> U256 {
            var result = U256.one
            var cur = base
            for bitIdx in 0..<256 {
                if exp.bit(bitIdx) {
                    result = mulMod(result, cur, mod: m)
                }
                cur = mulMod(cur, cur, mod: m)
            }
            return result
        }

        static func invMod(_ a: U256, prime m: U256) -> U256 {
            let exp = subWithBorrow(m, U256(l0: 2, l1: 0, l2: 0, l3: 0)).0
            return powMod(a, exp: exp, mod: m)
        }
    }

    // NIST P-256 curve constants
    static let p = U256(
        l0: 0xFFFFFFFFFFFFFFFF,
        l1: 0x00000000FFFFFFFF,
        l2: 0x0000000000000000,
        l3: 0xFFFFFFFF00000001
    )
    static let n = U256(
        l0: 0xF3B9CAC2FC632551,
        l1: 0xBCE6FAADA7179E84,
        l2: 0xFFFFFFFFFFFFFFFF,
        l3: 0xFFFFFFFF00000000
    )
    static let gx = U256(
        l0: 0xF4A13945D898C296,
        l1: 0x77037D812DEB33A0,
        l2: 0xF8BCE6E563A440F2,
        l3: 0x6B17D1F2E12C4247
    )
    static let gy = U256(
        l0: 0xCBB6406837BF51F5,
        l1: 0x2BCE33576B315ECE,
        l2: 0x8EE7EB4A7C0F9E16,
        l3: 0x4FE342E2FE1A7F9B
    )

    struct JacobianPoint {
        var x: U256
        var y: U256
        var z: U256

        static let infinity = JacobianPoint(x: .zero, y: .one, z: .zero)
        var isInfinity: Bool { z.isZero }
    }

    private static func pointDouble(_ pt: JacobianPoint) -> JacobianPoint {
        if pt.isInfinity || pt.y.isZero { return .infinity }
        // P-256 has a = -3 mod p: delta = z^2, gamma = y^2, beta = x*gamma, alpha = 3*(x - delta)*(x + delta)
        let delta = U256.mulMod(pt.z, pt.z, mod: p)
        let gamma = U256.mulMod(pt.y, pt.y, mod: p)
        let beta = U256.mulMod(pt.x, gamma, mod: p)
        let xMinusD = U256.subMod(pt.x, delta, mod: p)
        let xPlusD = U256.addMod(pt.x, delta, mod: p)
        let prod = U256.mulMod(xMinusD, xPlusD, mod: p)
        let alpha = U256.addMod(U256.addMod(prod, prod, mod: p), prod, mod: p)

        let beta2 = U256.addMod(beta, beta, mod: p)
        let beta4 = U256.addMod(beta2, beta2, mod: p)
        let beta8 = U256.addMod(beta4, beta4, mod: p)
        let x3 = U256.subMod(U256.mulMod(alpha, alpha, mod: p), beta8, mod: p)

        let yPlusZ = U256.addMod(pt.y, pt.z, mod: p)
        let z3 = U256.subMod(U256.subMod(U256.mulMod(yPlusZ, yPlusZ, mod: p), gamma, mod: p), delta, mod: p)

        let gammaSq = U256.mulMod(gamma, gamma, mod: p)
        let gammaSq2 = U256.addMod(gammaSq, gammaSq, mod: p)
        let gammaSq4 = U256.addMod(gammaSq2, gammaSq2, mod: p)
        let gammaSq8 = U256.addMod(gammaSq4, gammaSq4, mod: p)
        let y3 = U256.subMod(U256.mulMod(alpha, U256.subMod(beta4, x3, mod: p), mod: p), gammaSq8, mod: p)

        return JacobianPoint(x: x3, y: y3, z: z3)
    }

    private static func pointAdd(_ a: JacobianPoint, _ b: JacobianPoint) -> JacobianPoint {
        if a.isInfinity { return b }
        if b.isInfinity { return a }
        let z1z1 = U256.mulMod(a.z, a.z, mod: p)
        let z2z2 = U256.mulMod(b.z, b.z, mod: p)
        let u1 = U256.mulMod(a.x, z2z2, mod: p)
        let u2 = U256.mulMod(b.x, z1z1, mod: p)
        let s1 = U256.mulMod(a.y, U256.mulMod(b.z, z2z2, mod: p), mod: p)
        let s2 = U256.mulMod(b.y, U256.mulMod(a.z, z1z1, mod: p), mod: p)

        if u1 == u2 {
            if s1 == s2 {
                return pointDouble(a)
            }
            return .infinity
        }

        let h = U256.subMod(u2, u1, mod: p)
        let i = U256.mulMod(U256.addMod(h, h, mod: p), U256.addMod(h, h, mod: p), mod: p)
        let j = U256.mulMod(h, i, mod: p)
        let sDiff = U256.subMod(s2, s1, mod: p)
        let r = U256.addMod(sDiff, sDiff, mod: p)
        let v = U256.mulMod(u1, i, mod: p)

        let v2 = U256.addMod(v, v, mod: p)
        let x3 = U256.subMod(U256.subMod(U256.mulMod(r, r, mod: p), j, mod: p), v2, mod: p)
        let s1j = U256.mulMod(s1, j, mod: p)
        let y3 = U256.subMod(
            U256.mulMod(r, U256.subMod(v, x3, mod: p), mod: p),
            U256.addMod(s1j, s1j, mod: p),
            mod: p
        )
        let z1PlusZ2 = U256.addMod(a.z, b.z, mod: p)
        let z3 = U256.mulMod(
            U256.subMod(U256.subMod(U256.mulMod(z1PlusZ2, z1PlusZ2, mod: p), z1z1, mod: p), z2z2, mod: p),
            h,
            mod: p
        )
        return JacobianPoint(x: x3, y: y3, z: z3)
    }

    private static func scalarMulBase(_ k: U256) -> (U256, U256)? {
        let base = JacobianPoint(x: gx, y: gy, z: .one)
        var acc = JacobianPoint.infinity
        for bitIdx in stride(from: 255, through: 0, by: -1) {
            acc = pointDouble(acc)
            if k.bit(bitIdx) {
                acc = pointAdd(acc, base)
            }
        }
        guard !acc.isInfinity else { return nil }
        let zInv = U256.invMod(acc.z, prime: p)
        let zInv2 = U256.mulMod(zInv, zInv, mod: p)
        let zInv3 = U256.mulMod(zInv2, zInv, mod: p)
        let ax = U256.mulMod(acc.x, zInv2, mod: p)
        let ay = U256.mulMod(acc.y, zInv3, mod: p)
        return (ax, ay)
    }

    static func randomScalar() -> [UInt8] {
        var rng = SystemRandomNumberGenerator()
        while true {
            var bytes = [UInt8](repeating: 0, count: 32)
            for i in 0..<32 { bytes[i] = UInt8.random(in: 0...255, using: &rng) }
            let k = U256.fromBigEndian(bytes)
            if !k.isZero && !(k >= n) {
                return bytes
            }
        }
    }

    static func publicKey(fromPrivateScalar scalar32: [UInt8]) -> (x: [UInt8], y: [UInt8])? {
        let d = U256.fromBigEndian(scalar32)
        guard !d.isZero && !(d >= n), let (ax, ay) = scalarMulBase(d) else { return nil }
        return (ax.toBigEndian(), ay.toBigEndian())
    }

    static func signDigest(digest32: [UInt8], privateScalar32: [UInt8]) -> (r: [UInt8], s: [UInt8])? {
        let d = U256.fromBigEndian(privateScalar32)
        guard !d.isZero && !(d >= n) else { return nil }
        let rawZ = U256.fromBigEndian(digest32)
        let z = rawZ >= n ? U256.subWithBorrow(rawZ, n).0 : rawZ

        for _ in 0..<64 {
            let k = U256.fromBigEndian(randomScalar())
            guard let (rx, _) = scalarMulBase(k) else { continue }
            let r = rx >= n ? U256.subWithBorrow(rx, n).0 : rx
            if r.isZero { continue }
            let kInv = U256.invMod(k, prime: n)
            let rd = U256.mulMod(r, d, mod: n)
            let zPlusRd = U256.addMod(z, rd, mod: n)
            let s = U256.mulMod(kInv, zPlusRd, mod: n)
            if s.isZero { continue }
            return (r.toBigEndian(), s.toBigEndian())
        }
        return nil
    }
}
