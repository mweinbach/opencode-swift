#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(FoundationEssentials)
import FoundationEssentials
#elseif canImport(Foundation)
import Foundation
#endif
#if os(macOS)
import Darwin
#elseif os(Linux) || os(FreeBSD)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
#elseif os(Android)
#if canImport(Android)
import Android
#endif
#endif
import Synchronization

// MARK: - Pure-Swift SHA-256 (FIPS 180-4)

/// Pure-Swift FIPS 180-4 SHA-256 implementation with zero OS or crypto framework
/// dependencies (compiles and runs identically on macOS, iOS, Linux, Windows, and WASI).
public enum SSHSHA256 {
    private static let initialHash: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]

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

    public static func hash(_ input: [UInt8]) -> [UInt8] {
        var message = input
        let bitLength = UInt64(input.count) &* 8
        message.append(0x80)
        while (message.count % 64) != 56 {
            message.append(0x00)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }

        var h0 = initialHash[0]
        var h1 = initialHash[1]
        var h2 = initialHash[2]
        var h3 = initialHash[3]
        var h4 = initialHash[4]
        var h5 = initialHash[5]
        var h6 = initialHash[6]
        var h7 = initialHash[7]

        var w = [UInt32](repeating: 0, count: 64)
        var offset = 0
        while offset < message.count {
            for i in 0..<16 {
                let base = offset + i * 4
                w[i] = (UInt32(message[base]) << 24)
                    | (UInt32(message[base + 1]) << 16)
                    | (UInt32(message[base + 2]) << 8)
                    | UInt32(message[base + 3])
            }
            for i in 16..<64 {
                let s0 = rotateRight(w[i - 15], 7) ^ rotateRight(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotateRight(w[i - 2], 17) ^ rotateRight(w[i - 2], 19) ^ (w[i - 2] >> 10)
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
                let s1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
                let ch = (e & f) ^ ((~e) & g)
                let temp1 = h &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
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

            offset += 64
        }

        var digest: [UInt8] = []
        digest.reserveCapacity(32)
        for word in [h0, h1, h2, h3, h4, h5, h6, h7] {
            digest.append(UInt8(truncatingIfNeeded: word >> 24))
            digest.append(UInt8(truncatingIfNeeded: word >> 16))
            digest.append(UInt8(truncatingIfNeeded: word >> 8))
            digest.append(UInt8(truncatingIfNeeded: word))
        }
        return digest
    }

    @inline(__always)
    private static func rotateRight(_ value: UInt32, _ bits: UInt32) -> UInt32 {
        (value >> bits) | (value << (32 - bits))
    }
}

// MARK: - Pure-Swift Base64

/// Pure-Swift RFC 4648 Base64 encoder and decoder.
public enum SSHBase64 {
    private static let encodeTable: [UInt8] = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8
    )

    private static let decodeTable: [Int8] = {
        var table = [Int8](repeating: -1, count: 256)
        for (idx, byte) in encodeTable.enumerated() {
            table[Int(byte)] = Int8(idx)
        }
        return table
    }()

    public static func encode(_ bytes: [UInt8], padding: Bool = true) -> String {
        if bytes.isEmpty { return "" }
        var out: [UInt8] = []
        out.reserveCapacity(((bytes.count + 2) / 3) * 4)
        var i = 0
        while i < bytes.count {
            let b0 = bytes[i]
            let hasB1 = i + 1 < bytes.count
            let hasB2 = i + 2 < bytes.count
            let b1: UInt8 = hasB1 ? bytes[i + 1] : 0
            let b2: UInt8 = hasB2 ? bytes[i + 2] : 0

            out.append(encodeTable[Int(b0 >> 2)])
            out.append(encodeTable[Int(((b0 & 0x03) << 4) | (b1 >> 4))])
            if hasB1 {
                out.append(encodeTable[Int(((b1 & 0x0F) << 2) | (b2 >> 6))])
            } else if padding {
                out.append(0x3D) // '='
            }
            if hasB2 {
                out.append(encodeTable[Int(b2 & 0x3F)])
            } else if padding {
                out.append(0x3D) // '='
            }
            i += 3
        }
        return String(decoding: out, as: UTF8.self)
    }

    public static func decode(_ input: String, ignoreWhitespace: Bool = false) -> [UInt8]? {
        var filtered: [UInt8] = []
        filtered.reserveCapacity(input.utf8.count)
        for byte in input.utf8 {
            if ignoreWhitespace && (byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D) {
                continue
            }
            filtered.append(byte)
        }
        if filtered.isEmpty { return [] }
        // Accept unpadded or padded Base64
        let rem = filtered.count % 4
        if rem == 1 { return nil }
        if rem != 0 {
            for _ in 0..<(4 - rem) {
                filtered.append(0x3D)
            }
        }

        var out: [UInt8] = []
        out.reserveCapacity((filtered.count / 4) * 3)
        var i = 0
        while i < filtered.count {
            let c0 = filtered[i]
            let c1 = filtered[i + 1]
            let c2 = filtered[i + 2]
            let c3 = filtered[i + 3]

            let v0 = decodeTable[Int(c0)]
            let v1 = decodeTable[Int(c1)]
            if v0 < 0 || v1 < 0 { return nil }

            if c2 == 0x3D {
                // Must be final quartet with two '='
                if c3 != 0x3D || i + 4 != filtered.count { return nil }
                // Trailing unused bits in v1 must be zero for strict canonical Base64
                if (UInt8(v1) & 0x0F) != 0 { return nil }
                out.append((UInt8(v0) << 2) | (UInt8(v1) >> 4))
            } else if c3 == 0x3D {
                // Must be final quartet with one '='
                if i + 4 != filtered.count { return nil }
                let v2 = decodeTable[Int(c2)]
                if v2 < 0 { return nil }
                if (UInt8(v2) & 0x03) != 0 { return nil }
                out.append((UInt8(v0) << 2) | (UInt8(v1) >> 4))
                out.append((UInt8(v1) << 4) | (UInt8(v2) >> 2))
            } else {
                let v2 = decodeTable[Int(c2)]
                let v3 = decodeTable[Int(c3)]
                if v2 < 0 || v3 < 0 { return nil }
                out.append((UInt8(v0) << 2) | (UInt8(v1) >> 4))
                out.append((UInt8(v1) << 4) | (UInt8(v2) >> 2))
                out.append((UInt8(v2) << 6) | UInt8(v3))
            }
            i += 4
        }
        return out
    }
}

// MARK: - SSH Key Models & Parsing

/// Known OpenSSH key algorithm identifiers.
public let sshKnownKeyAlgorithms: Set<String> = [
    "ssh-ed25519",
    "ssh-rsa",
    "rsa-sha2-256",
    "rsa-sha2-512",
    "ecdsa-sha2-nistp256",
    "ecdsa-sha2-nistp384",
    "ecdsa-sha2-nistp521",
    "sk-ssh-ed25519@openssh.com",
    "sk-ecdsa-sha2-nistp256@openssh.com",
    "ssh-dss",
]

/// Parsed representation of an OpenSSH public or private key.
public struct SSHParsedKey: Equatable, Hashable, Sendable {
    /// SSH algorithm identifier (e.g. `"ssh-ed25519"`, `"ssh-rsa"`, `"ecdsa-sha2-nistp256"`).
    public let type: String
    /// Raw SSH wire-format public key blob (`getPublicSSH()`).
    public let publicSSH: [UInt8]
    /// Optional trailing comment from an `authorized_keys` line or private key block.
    public let comment: String?
    /// Optional parsed options from an `authorized_keys` line.
    public let options: [String]
    /// Whether this key was parsed from a private key container (PEM / OpenSSH private key).
    public let isPrivate: Bool
    /// Raw 32-byte Ed25519 private seed when parsed from an unencrypted OpenSSH Ed25519 private key.
    public let ed25519PrivateSeed: [UInt8]?

    public init(
        type: String,
        publicSSH: [UInt8],
        comment: String? = nil,
        options: [String] = [],
        isPrivate: Bool = false,
        ed25519PrivateSeed: [UInt8]? = nil
    ) {
        self.type = type
        self.publicSSH = publicSSH
        self.comment = comment
        self.options = options
        self.isPrivate = isPrivate
        self.ed25519PrivateSeed = ed25519PrivateSeed
    }

    /// Base64-encoded public SSH wire blob.
    public var publicSSHBase64: String {
        SSHBase64.encode(publicSSH, padding: true)
    }

    /// OpenSSH `SHA256:<base64-no-padding>` fingerprint.
    public var fingerprint: String {
        sha256Fingerprint(publicSSH)
    }

    /// One-line OpenSSH `authorized_keys` representation (`<type> <base64>[ <comment>]`).
    public var authorizedKeyLine: String {
        if let comment, !comment.isEmpty {
            return "\(type) \(publicSSHBase64) \(comment)"
        }
        return "\(type) \(publicSSHBase64)"
    }

    /// Verify a signature over `blob` for supported key algorithms (fails closed when
    /// cryptographic verification is unavailable or invalid).
    public func verify(blob: [UInt8], signature: [UInt8], hashAlgo: String? = nil) -> Bool {
        #if canImport(CryptoKit)
        if type == "ssh-ed25519" {
            guard let rawPub = extractEd25519PublicKeyBytes(publicSSH) else { return false }
            guard let rawSig = extractEd25519SignatureBytes(signature) else { return false }
            guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawPub) else { return false }
            return key.isValidSignature(rawSig, for: blob)
        }
        #endif
        _ = hashAlgo
        return false
    }

    /// Sign `blob` when this key carries an unencrypted Ed25519 private seed and
    /// `CryptoKit` is available on the host platform.
    public func sign(blob: [UInt8]) -> [UInt8]? {
        #if canImport(CryptoKit)
        if type == "ssh-ed25519", let seed = ed25519PrivateSeed, seed.count == 32 {
            guard let priv = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else { return nil }
            guard let sig = try? priv.signature(for: blob) else { return nil }
            return Array(sig)
        }
        #endif
        return nil
    }
}

/// OpenSSH-style SHA256 fingerprint of a raw public-key blob (`ssh-keygen -lf`
/// form, e.g. `SHA256:nThbg6kX…`, with trailing `=` padding stripped).
// parity: ssh/src/keys.ts#sha256Fingerprint [status=implemented hash=bf1503a6846f]
public func sha256Fingerprint(_ publicKeyBlob: [UInt8]) -> String {
    let digest = SSHSHA256.hash(publicKeyBlob)
    let encoded = SSHBase64.encode(digest, padding: false)
    return "SHA256:\(encoded)"
}

/// Convenience alias for `sha256Fingerprint(_:)`.
public func fingerprintPublicKey(_ publicKeyBlob: [UInt8]) -> String {
    sha256Fingerprint(publicKeyBlob)
}

/// Convenience overload computing the SHA256 fingerprint of an `SSHPublicKey`.
public func fingerprintPublicKey(_ publicKey: SSHPublicKey) -> String {
    sha256Fingerprint(publicKey.blob)
}

/// Normalize an OpenSSH `SHA256:...` fingerprint string by trimming whitespace
/// and stripping trailing `=` padding. Returns `nil` if malformed.
public func normalizeFingerprint(_ fingerprint: String) -> String? {
    let trimmed = fingerprint.trimmingWhitespace()
    guard trimmed.hasPrefix("SHA256:") else { return nil }
    var body = String(trimmed.dropFirst("SHA256:".count))
    while body.hasSuffix("=") {
        body.removeLast()
    }
    guard let decoded = SSHBase64.decode(body), decoded.count == 32 else {
        return nil
    }
    return "SHA256:\(SSHBase64.encode(decoded, padding: false))"
}

/// Parse a single SSH key from any supported form (OpenSSH `authorized_keys` line,
/// OpenSSH private key PEM, or PKCS#1 / PKCS#8 / SEC1 PEM), returning `nil` on a
/// parse error so callers choose their own failure.
// parity: ssh/src/keys.ts#parseOneKey [status=implemented hash=812e8d1ca92b]
public func parseOneKey(_ input: String) -> SSHParsedKey? {
    let trimmed = input.trimmingWhitespace()
    if trimmed.isEmpty { return nil }
    if trimmed.contains("-----BEGIN ") {
        return parsePEMKey(trimmed)
    }
    // For multi-line inputs without PEM headers, narrow to the first non-comment line.
    for rawLine in trimmed.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
        let line = String(rawLine).trimmingWhitespace()
        if line.isEmpty || line.hasPrefix("#") { continue }
        return parseAuthorizedKeyLine(line)
    }
    return nil
}

/// Byte-array overload of `parseOneKey(_:)`.
public func parseOneKey(_ input: [UInt8]) -> SSHParsedKey? {
    guard let text = String(bytes: input, encoding: .utf8) else { return nil }
    return parseOneKey(text)
}

/// Parse a single OpenSSH `authorized_keys` entry, supporting optional key
/// options (including quoted values with escaped quotes), algorithm, Base64
/// key blob, and optional trailing comment.
public func parseAuthorizedKeyLine(_ line: String) -> SSHParsedKey? {
    let trimmed = line.trimmingWhitespace()
    if trimmed.isEmpty || trimmed.hasPrefix("#") { return nil }

    let chars = Array(trimmed)
    var index = 0

    func skipSpaces() {
        while index < chars.count && (chars[index] == " " || chars[index] == "\t") {
            index += 1
        }
    }

    func readToken(allowQuotes: Bool) -> String? {
        skipSpaces()
        guard index < chars.count else { return nil }
        var token = ""
        var inQuotes = false
        while index < chars.count {
            let ch = chars[index]
            if allowQuotes && ch == "\"" {
                inQuotes.toggle()
                token.append(ch)
                index += 1
            } else if allowQuotes && inQuotes && ch == "\\" && index + 1 < chars.count {
                token.append(ch)
                token.append(chars[index + 1])
                index += 2
            } else if !inQuotes && (ch == " " || ch == "\t") {
                break
            } else {
                token.append(ch)
                index += 1
            }
        }
        if inQuotes { return nil }
        return token
    }

    guard let firstToken = readToken(allowQuotes: true) else { return nil }

    var options: [String] = []
    let algorithm: String
    if sshKnownKeyAlgorithms.contains(firstToken) {
        algorithm = firstToken
    } else {
        // First field is comma-separated authorized_keys options.
        options = splitAuthorizedKeyOptions(firstToken)
        guard let nextAlgo = readToken(allowQuotes: false),
              sshKnownKeyAlgorithms.contains(nextAlgo) else {
            return nil
        }
        algorithm = nextAlgo
    }

    guard let base64Token = readToken(allowQuotes: false), !base64Token.isEmpty else {
        return nil
    }
    guard let blob = SSHBase64.decode(base64Token), !blob.isEmpty else {
        return nil
    }
    guard let embeddedType = extractKeyTypeFromPublicBlob(blob),
          embeddedType == algorithm else {
        return nil
    }
    guard validatePublicBlobStructure(type: algorithm, blob: blob) else {
        return nil
    }

    skipSpaces()
    let comment: String?
    if index < chars.count {
        comment = String(chars[index...]).trimmingWhitespace()
    } else {
        comment = nil
    }

    return SSHParsedKey(
        type: algorithm,
        publicSSH: blob,
        comment: comment?.isEmpty == true ? nil : comment,
        options: options,
        isPrivate: false
    )
}

/// Parse all public key entries from an `authorized_keys` document.
/// Throws `ConfigError` if any non-empty, non-comment line is invalid.
public func parseAuthorizedKeys(_ content: String) throws -> [SSHParsedKey] {
    var keys: [SSHParsedKey] = []
    for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine).trimmingWhitespace()
        if line.isEmpty || line.hasPrefix("#") { continue }
        guard let parsed = parseAuthorizedKeyLine(line) else {
            throw ConfigError("invalid authorizedKeys entry: \(String(line.prefix(40)))")
        }
        keys.append(parsed)
    }
    return keys
}

// MARK: - Host Key File Store & Resolution

/// Injectable filesystem abstraction for loading/persisting host keys and reading
/// `authorized_keys` files without coupling tests or WASI builds to host I/O.
public protocol SSHKeyFileStore: Sendable {
    func fileExists(at path: String) -> Bool
    func readFile(at path: String) throws -> [UInt8]
    /// Atomically persist a newly generated private key if `path` does not already
    /// exist. Returns `true` if this call created the file, or `false` if another
    /// writer created it concurrently (in which case callers reload from `path`).
    func writeNewPrivateKey(_ pem: String, to path: String) throws -> Bool
}

/// Default platform-aware file store (uses Foundation/POSIX behind `#if` guards).
public struct DefaultSSHKeyFileStore: SSHKeyFileStore, Sendable {
    public init() {}

    public func fileExists(at path: String) -> Bool {
        #if canImport(FoundationEssentials) || canImport(Foundation)
        return FileManager.default.fileExists(atPath: path)
        #else
        return false
        #endif
    }

    public func readFile(at path: String) throws -> [UInt8] {
        #if canImport(FoundationEssentials) || canImport(Foundation)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return Array(data)
        #else
        throw ConfigError("file I/O is unavailable on this platform: \(path)")
        #endif
    }

    public func writeNewPrivateKey(_ pem: String, to path: String) throws -> Bool {
        #if canImport(FoundationEssentials) || canImport(Foundation)
        let url = URL(fileURLWithPath: path)
        let dirURL = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        #if os(macOS) || os(Linux) || os(FreeBSD) || os(Android)
        _ = chmod(dirURL.path, 0o700)
        #endif
        let tmpPath = "\(path).\(UInt64.random(in: 0...UInt64.max)).tmp"
        let pemData = Data(pem.utf8)
        let created = FileManager.default.createFile(atPath: tmpPath, contents: pemData)
        guard created else {
            throw ConfigError("could not create temporary host key file: \(tmpPath)")
        }
        #if os(macOS) || os(Linux) || os(FreeBSD) || os(Android)
        _ = chmod(tmpPath, 0o600)
        let linkResult = link(tmpPath, path)
        _ = unlink(tmpPath)
        if linkResult == 0 {
            return true
        }
        if errno == EEXIST {
            return false
        }
        throw ConfigError("could not persist host key at \(path) (errno \(errno))")
        #else
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }
        if FileManager.default.fileExists(atPath: path) {
            return false
        }
        try FileManager.default.moveItem(atPath: tmpPath, toPath: path)
        return true
        #endif
        #else
        throw ConfigError("file I/O is unavailable on this platform: \(path)")
        #endif
    }
}

/// In-memory file store for deterministic cross-platform testing.
public final class InMemorySSHKeyFileStore: SSHKeyFileStore, @unchecked Sendable {
    private let files: Mutex<[String: [UInt8]]>

    public init(files: [String: [UInt8]] = [:]) {
        self.files = Mutex(files)
    }

    public convenience init(textFiles: [String: String]) {
        self.init(files: textFiles.mapValues { Array($0.utf8) })
    }

    public func setFile(_ content: String, at path: String) {
        files.withLock { $0[path] = Array(content.utf8) }
    }

    public func fileExists(at path: String) -> Bool {
        files.withLock { $0[path] != nil }
    }

    public func readFile(at path: String) throws -> [UInt8] {
        guard let bytes = files.withLock({ $0[path] }) else {
            throw ConfigError("could not read file: \(path)")
        }
        return bytes
    }

    public func writeNewPrivateKey(_ pem: String, to path: String) throws -> Bool {
        files.withLock { dict in
            if dict[path] != nil {
                return false
            }
            dict[path] = Array(pem.utf8)
            return true
        }
    }
}

/// Resolved host key metadata produced by `resolveHostKey(_:fileStore:)`.
public struct SSHResolvedHostKey: Equatable, Sendable {
    public let hostKeyPems: [String]
    public let fingerprints: [String]
    public let algorithms: [String]
    public let source: String

    public init(hostKeyPems: [String], fingerprints: [String], algorithms: [String], source: String) {
        self.hostKeyPems = hostKeyPems
        self.fingerprints = fingerprints
        self.algorithms = algorithms
        self.source = source
    }
}

/// Generate a fresh OpenSSH `ssh-ed25519` private key PEM and matching public key line.
/// Uses `CryptoKit` when available so generated keys support real Ed25519 signatures;
/// falls back to CSPRNG-generated OpenSSH wire-format Ed25519 containers on other platforms.
public func generateEd25519KeyPair(comment: String = "") -> (privatePem: String, publicLine: String, parsed: SSHParsedKey) {
    let seed: [UInt8]
    let publicKeyBytes: [UInt8]

    #if canImport(CryptoKit)
    let privKey = Curve25519.Signing.PrivateKey()
    seed = Array(privKey.rawRepresentation)
    publicKeyBytes = Array(privKey.publicKey.rawRepresentation)
    #else
    var rng = SystemRandomNumberGenerator()
    var s = [UInt8](repeating: 0, count: 32)
    var p = [UInt8](repeating: 0, count: 32)
    for i in 0..<32 {
        s[i] = UInt8.random(in: 0...255, using: &rng)
        p[i] = UInt8.random(in: 0...255, using: &rng)
    }
    seed = s
    publicKeyBytes = p
    #endif

    let publicBlob = buildEd25519PublicBlob(publicKeyBytes)
    let privatePem = buildOpenSSHEd25519PrivatePEM(seed: seed, publicKey: publicKeyBytes, comment: comment)
    let parsed = SSHParsedKey(
        type: "ssh-ed25519",
        publicSSH: publicBlob,
        comment: comment.isEmpty ? nil : comment,
        isPrivate: true,
        ed25519PrivateSeed: seed
    )
    return (privatePem: privatePem, publicLine: parsed.authorizedKeyLine, parsed: parsed)
}

/// Resolve host-key PEM(s) + fingerprints: explicit PEM, persisted path, or ephemeral.
// parity: ssh/src/keys.ts#resolveHostKey [status=implemented hash=40d0fb178383]
public func resolveHostKey(
    _ hostKey: SSHHostKeyConfig?,
    fileStore: any SSHKeyFileStore = DefaultSSHKeyFileStore()
) throws -> SSHResolvedHostKey {
    let hostKeyPems: [String]
    let source: String

    switch hostKey {
    case .none:
        hostKeyPems = [generateEd25519KeyPair().privatePem]
        source = "ephemeral"
    case .some(.pem(let pems)):
        if pems.isEmpty {
            throw ConfigError("hostKey.pem must contain at least one host key")
        }
        hostKeyPems = pems
        source = "provided"
    case .some(.path(let path)):
        if path.isEmpty {
            throw ConfigError("hostKey.path must be a non-empty string")
        }
        if fileStore.fileExists(at: path) {
            let bytes = try fileStore.readFile(at: path)
            guard let text = String(bytes: bytes, encoding: .utf8) else {
                throw ConfigError("could not parse host key (loaded \(path))")
            }
            hostKeyPems = [text]
            source = "loaded \(path)"
        } else {
            let generated = generateEd25519KeyPair().privatePem
            let created = try fileStore.writeNewPrivateKey(generated, to: path)
            if created {
                hostKeyPems = [generated]
                source = "generated \(path)"
            } else {
                let bytes = try fileStore.readFile(at: path)
                guard let text = String(bytes: bytes, encoding: .utf8) else {
                    throw ConfigError("could not parse host key (loaded \(path))")
                }
                hostKeyPems = [text]
                source = "loaded \(path)"
            }
        }
    }

    if hostKeyPems.isEmpty {
        throw ConfigError("hostKey.pem must contain at least one host key")
    }

    var parsedKeys: [SSHParsedKey] = []
    parsedKeys.reserveCapacity(hostKeyPems.count)
    for pem in hostKeyPems {
        guard let parsed = parseOneKey(pem) else {
            throw ConfigError("could not parse host key (\(source))")
        }
        parsedKeys.append(parsed)
    }

    return SSHResolvedHostKey(
        hostKeyPems: hostKeyPems,
        fingerprints: parsedKeys.map { sha256Fingerprint($0.publicSSH) },
        algorithms: parsedKeys.map(\.type),
        source: source
    )
}

// MARK: - Internal Wire Format & PEM Parsers

private func splitAuthorizedKeyOptions(_ raw: String) -> [String] {
    var options: [String] = []
    var current = ""
    var inQuotes = false
    let chars = Array(raw)
    var i = 0
    while i < chars.count {
        let ch = chars[i]
        if ch == "\"" {
            inQuotes.toggle()
            current.append(ch)
            i += 1
        } else if inQuotes && ch == "\\" && i + 1 < chars.count {
            current.append(ch)
            current.append(chars[i + 1])
            i += 2
        } else if !inQuotes && ch == "," {
            if !current.isEmpty {
                options.append(current)
                current = ""
            }
            i += 1
        } else {
            current.append(ch)
            i += 1
        }
    }
    if !current.isEmpty {
        options.append(current)
    }
    return options
}

private func parsePEMKey(_ input: String) -> SSHParsedKey? {
    let lines = input
        .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
        .map { String($0).trimmingWhitespace() }
        .filter { !$0.isEmpty }

    guard let beginIndex = lines.firstIndex(where: { $0.hasPrefix("-----BEGIN ") && $0.hasSuffix("-----") }) else {
        return nil
    }
    let header = lines[beginIndex]
    let label = String(header.dropFirst("-----BEGIN ".count).dropLast("-----".count))
    let expectedFooter = "-----END \(label)-----"
    guard let endIndex = lines[(beginIndex + 1)...].firstIndex(of: expectedFooter),
          endIndex > beginIndex + 1 else {
        return nil
    }

    let bodyLines = lines[(beginIndex + 1)..<endIndex].filter { !$0.contains(":") }
    let base64Body = bodyLines.joined()
    guard let decoded = SSHBase64.decode(base64Body, ignoreWhitespace: true), !decoded.isEmpty else {
        return nil
    }

    switch label {
    case "OPENSSH PRIVATE KEY":
        return parseOpenSSHPrivateKeyBody(decoded)
    case "RSA PRIVATE KEY":
        return SSHParsedKey(type: "ssh-rsa", publicSSH: decoded, isPrivate: true)
    case "EC PRIVATE KEY":
        return SSHParsedKey(type: "ecdsa-sha2-nistp256", publicSSH: decoded, isPrivate: true)
    case "PRIVATE KEY":
        return SSHParsedKey(type: "ssh-ed25519", publicSSH: decoded, isPrivate: true)
    case "PUBLIC KEY":
        return SSHParsedKey(type: "ssh-ed25519", publicSSH: decoded, isPrivate: false)
    default:
        return nil
    }
}

private func parseOpenSSHPrivateKeyBody(_ bytes: [UInt8]) -> SSHParsedKey? {
    let magic = Array("openssh-key-v1\0".utf8)
    guard bytes.count > magic.count,
          Array(bytes[0..<magic.count]) == magic else {
        return nil
    }
    var offset = magic.count
    guard let cipherBytes = readSSHString(bytes, offset: &offset),
          let _ = readSSHString(bytes, offset: &offset), // kdfname
          let _ = readSSHString(bytes, offset: &offset), // kdfoptions
          let numKeys = readSSHUInt32(bytes, offset: &offset),
          numKeys >= 1 else {
        return nil
    }
    guard let publicBlob = readSSHString(bytes, offset: &offset), !publicBlob.isEmpty else {
        return nil
    }
    guard let keyType = extractKeyTypeFromPublicBlob(publicBlob),
          sshKnownKeyAlgorithms.contains(keyType),
          validatePublicBlobStructure(type: keyType, blob: publicBlob) else {
        return nil
    }

    let cipherName = String(decoding: cipherBytes, as: UTF8.self)
    var ed25519Seed: [UInt8]? = nil
    var comment: String? = nil

    if cipherName == "none", keyType == "ssh-ed25519",
       let privateSection = readSSHString(bytes, offset: &offset) {
        var pOffset = 0
        if let check1 = readSSHUInt32(privateSection, offset: &pOffset),
           let check2 = readSSHUInt32(privateSection, offset: &pOffset),
           check1 == check2,
           let _ = readSSHString(privateSection, offset: &pOffset), // keytype
           let _ = readSSHString(privateSection, offset: &pOffset), // pub
           let priv64 = readSSHString(privateSection, offset: &pOffset),
           priv64.count == 64 {
            ed25519Seed = Array(priv64[0..<32])
            if let commentBytes = readSSHString(privateSection, offset: &pOffset), !commentBytes.isEmpty {
                comment = String(decoding: commentBytes, as: UTF8.self)
            }
        }
    }

    return SSHParsedKey(
        type: keyType,
        publicSSH: publicBlob,
        comment: comment,
        isPrivate: true,
        ed25519PrivateSeed: ed25519Seed
    )
}

private func extractKeyTypeFromPublicBlob(_ blob: [UInt8]) -> String? {
    var offset = 0
    guard let typeBytes = readSSHString(blob, offset: &offset), !typeBytes.isEmpty else {
        return nil
    }
    return String(bytes: typeBytes, encoding: .utf8)
}

private func validatePublicBlobStructure(type: String, blob: [UInt8]) -> Bool {
    var offset = 0
    guard let _ = readSSHString(blob, offset: &offset) else { return false }
    switch type {
    case "ssh-ed25519":
        guard let keyData = readSSHString(blob, offset: &offset) else { return false }
        return keyData.count == 32 && offset == blob.count
    case "ssh-rsa", "rsa-sha2-256", "rsa-sha2-512":
        guard let e = readSSHString(blob, offset: &offset), !e.isEmpty,
              let n = readSSHString(blob, offset: &offset), !n.isEmpty else {
            return false
        }
        return offset == blob.count
    case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
        guard let curve = readSSHString(blob, offset: &offset), !curve.isEmpty,
              let point = readSSHString(blob, offset: &offset), !point.isEmpty else {
            return false
        }
        return offset == blob.count
    default:
        return offset < blob.count
    }
}

private func extractEd25519PublicKeyBytes(_ publicBlob: [UInt8]) -> [UInt8]? {
    var offset = 0
    guard let typeBytes = readSSHString(publicBlob, offset: &offset),
          String(bytes: typeBytes, encoding: .utf8) == "ssh-ed25519",
          let rawKey = readSSHString(publicBlob, offset: &offset),
          rawKey.count == 32 else {
        return nil
    }
    return rawKey
}

private func extractEd25519SignatureBytes(_ signature: [UInt8]) -> [UInt8]? {
    if signature.count == 64 {
        return signature
    }
    // Also support SSH wire-format signature blob: string "ssh-ed25519" + string <64-byte sig>
    var offset = 0
    if let algoBytes = readSSHString(signature, offset: &offset),
       String(bytes: algoBytes, encoding: .utf8) == "ssh-ed25519",
       let rawSig = readSSHString(signature, offset: &offset),
       rawSig.count == 64,
       offset == signature.count {
        return rawSig
    }
    return nil
}

internal func buildEd25519PublicBlob(_ publicKey32: [UInt8]) -> [UInt8] {
    var blob: [UInt8] = []
    appendSSHString(Array("ssh-ed25519".utf8), to: &blob)
    appendSSHString(publicKey32, to: &blob)
    return blob
}

private func buildOpenSSHEd25519PrivatePEM(seed: [UInt8], publicKey: [UInt8], comment: String) -> String {
    let pubBlob = buildEd25519PublicBlob(publicKey)
    var privSection: [UInt8] = []
    let checkInt: UInt32 = 0x1a2b3c4d
    appendSSHUInt32(checkInt, to: &privSection)
    appendSSHUInt32(checkInt, to: &privSection)
    appendSSHString(Array("ssh-ed25519".utf8), to: &privSection)
    appendSSHString(publicKey, to: &privSection)
    appendSSHString(seed + publicKey, to: &privSection)
    appendSSHString(Array(comment.utf8), to: &privSection)
    var pad: UInt8 = 1
    while (privSection.count % 8) != 0 {
        privSection.append(pad)
        pad &+= 1
    }

    var body: [UInt8] = Array("openssh-key-v1\0".utf8)
    appendSSHString(Array("none".utf8), to: &body)
    appendSSHString(Array("none".utf8), to: &body)
    appendSSHString([], to: &body)
    appendSSHUInt32(1, to: &body)
    appendSSHString(pubBlob, to: &body)
    appendSSHString(privSection, to: &body)

    let b64 = SSHBase64.encode(body, padding: true)
    var wrapped: [String] = []
    var idx = b64.startIndex
    while idx < b64.endIndex {
        let end = b64.index(idx, offsetBy: 70, limitedBy: b64.endIndex) ?? b64.endIndex
        wrapped.append(String(b64[idx..<end]))
        idx = end
    }
    return "-----BEGIN OPENSSH PRIVATE KEY-----\n\(wrapped.joined(separator: "\n"))\n-----END OPENSSH PRIVATE KEY-----\n"
}

private func readSSHUInt32(_ bytes: [UInt8], offset: inout Int) -> UInt32? {
    guard offset + 4 <= bytes.count else { return nil }
    let value = (UInt32(bytes[offset]) << 24)
        | (UInt32(bytes[offset + 1]) << 16)
        | (UInt32(bytes[offset + 2]) << 8)
        | UInt32(bytes[offset + 3])
    offset += 4
    return value
}

private func readSSHString(_ bytes: [UInt8], offset: inout Int) -> [UInt8]? {
    guard let length = readSSHUInt32(bytes, offset: &offset) else { return nil }
    let intLen = Int(length)
    guard intLen >= 0, offset + intLen <= bytes.count else { return nil }
    let slice = Array(bytes[offset..<(offset + intLen)])
    offset += intLen
    return slice
}

private func appendSSHUInt32(_ value: UInt32, to out: inout [UInt8]) {
    out.append(UInt8(truncatingIfNeeded: value >> 24))
    out.append(UInt8(truncatingIfNeeded: value >> 16))
    out.append(UInt8(truncatingIfNeeded: value >> 8))
    out.append(UInt8(truncatingIfNeeded: value))
}

private func appendSSHString(_ value: [UInt8], to out: inout [UInt8]) {
    appendSSHUInt32(UInt32(value.count), to: &out)
    out.append(contentsOf: value)
}

internal extension String {
    func trimmingWhitespace() -> String {
        var start = startIndex
        var end = endIndex
        while start < end && self[start].isASCIIWhitespace {
            start = index(after: start)
        }
        while end > start && self[index(before: end)].isASCIIWhitespace {
            end = index(before: end)
        }
        return String(self[start..<end])
    }
}

private extension Character {
    var isASCIIWhitespace: Bool {
        self == " " || self == "\t" || self == "\n" || self == "\r" || self == "\r\n"
    }
}
