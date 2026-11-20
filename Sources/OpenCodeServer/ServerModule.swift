#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Synchronization
import OpenCodeCore
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeUtil

/// Entry module for `OpenCodeServer` (port of `packages/server`: HTTP/SSE/WS handlers,
/// auth, CORS, event feed, pairing, and location routing).
public enum OpenCodeServerModule {
    public static let upstreamPackage = "server"
}

// MARK: - Server JSON Codec

public enum ServerCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Array(try encoder.encode(value))
    }

    public static func encodeString<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encode(value), as: UTF8.self)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from bytes: [UInt8]) throws -> T {
        try JSONDecoder().decode(type, from: Data(bytes))
    }

    public static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(text.utf8))
    }

    public static func toJSONValue<T: Encodable>(_ value: T) throws -> JSONValue {
        let bytes = try encode(value)
        return try decode(JSONValue.self, from: bytes)
    }

    public static func fromJSONValue<T: Decodable>(_ type: T.Type, _ value: JSONValue) throws -> T {
        let bytes = try encode(value)
        return try decode(type, from: bytes)
    }
}

// MARK: - Pure-Swift Server Cryptography (HMAC-SHA256, SHA-1, Base64URL, Constant-Time Compare)

public enum ServerCrypto {
    public static func sha256Bytes(_ input: [UInt8]) -> [UInt8] {
        hexDecode(Hash.sha256(input))
    }

    public static func sha1Bytes(_ input: [UInt8]) -> [UInt8] {
        hexDecode(Hash.fast(input))
    }

    /// RFC 2104 HMAC-SHA256 over arbitrary key and message bytes (pure Swift, works on all platforms incl. WASI).
    public static func hmacSHA256(key: [UInt8], message: [UInt8]) -> [UInt8] {
        let blockSize = 64
        var keyBlock: [UInt8]
        if key.count > blockSize {
            keyBlock = sha256Bytes(key)
        } else {
            keyBlock = key
        }
        if keyBlock.count < blockSize {
            keyBlock.append(contentsOf: repeatElement(UInt8(0), count: blockSize - keyBlock.count))
        }
        var oKeyPad = [UInt8](repeating: 0, count: blockSize)
        var iKeyPad = [UInt8](repeating: 0, count: blockSize)
        for i in 0..<blockSize {
            oKeyPad[i] = keyBlock[i] ^ 0x5C
            iKeyPad[i] = keyBlock[i] ^ 0x36
        }
        var inner = iKeyPad
        inner.append(contentsOf: message)
        let innerHash = sha256Bytes(inner)
        var outer = oKeyPad
        outer.append(contentsOf: innerHash)
        return sha256Bytes(outer)
    }

    public static func base64URLEncode(_ bytes: [UInt8]) -> String {
        let standard = bytesToBase64(bytes)
        var out = ""
        out.reserveCapacity(standard.utf8.count)
        for b in standard.utf8 {
            switch b {
            case UInt8(ascii: "+"): out.append("-")
            case UInt8(ascii: "/"): out.append("_")
            case UInt8(ascii: "="): continue
            default: out.append(Character(UnicodeScalar(b)))
            }
        }
        return out
    }

    public static func base64URLDecode(_ input: String) -> [UInt8]? {
        var standard = ""
        standard.reserveCapacity(input.utf8.count)
        for b in input.utf8 {
            switch b {
            case UInt8(ascii: "-"): standard.append("+")
            case UInt8(ascii: "_"): standard.append("/")
            default: standard.append(Character(UnicodeScalar(b)))
            }
        }
        return try? base64ToBytes(standard)
    }

    public static func randomBytes(_ count: Int) -> [UInt8] {
        var rng = SystemRandomNumberGenerator()
        var out = [UInt8](repeating: 0, count: count)
        var idx = 0
        while idx < count {
            var word = rng.next()
            for _ in 0..<8 where idx < count {
                out[idx] = UInt8(word & 0xFF)
                word >>= 8
                idx += 1
            }
        }
        return out
    }

    public static func timingSafeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<lhs.count {
            diff |= lhs[i] ^ rhs[i]
        }
        return diff == 0
    }

    private static func hexDecode(_ hex: String) -> [UInt8] {
        let chars = Array(hex.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i + 1 < chars.count {
            if let hi = hexNibble(chars[i]), let lo = hexNibble(chars[i + 1]) {
                out.append((hi << 4) | lo)
            }
            i += 2
        }
        return out
    }

    private static func hexNibble(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: return b - 0x30
        case 0x41...0x46: return b - 0x37
        case 0x61...0x66: return b - 0x57
        default: return nil
        }
    }
}

// MARK: - Pure-Swift URL, Query, Cookie & Header Helpers

public struct ServerParsedURL: Equatable, Hashable, Sendable {
    public let scheme: String?
    public let host: String?
    public let hostname: String?
    public let port: String?
    public let pathname: String
    public let search: String
    public let queryItems: [(name: String, value: String)]

    public init(_ rawURL: String) {
        let withoutFragment: Substring
        if let hashIdx = rawURL.firstIndex(of: "#") {
            withoutFragment = rawURL[..<hashIdx]
        } else {
            withoutFragment = rawURL[...]
        }

        let beforeQuery: Substring
        let queryPart: Substring?
        if let qIdx = withoutFragment.firstIndex(of: "?") {
            beforeQuery = withoutFragment[..<qIdx]
            queryPart = withoutFragment[withoutFragment.index(after: qIdx)...]
            self.search = String(withoutFragment[qIdx...])
        } else {
            beforeQuery = withoutFragment
            queryPart = nil
            self.search = ""
        }

        if let schemeRange = beforeQuery.range(of: "://") {
            self.scheme = String(beforeQuery[..<schemeRange.lowerBound]).lowercased()
            let afterScheme = beforeQuery[schemeRange.upperBound...]
            let authority: Substring
            if let slashIdx = afterScheme.firstIndex(of: "/") {
                authority = afterScheme[..<slashIdx]
                self.pathname = String(afterScheme[slashIdx...])
            } else {
                authority = afterScheme
                self.pathname = "/"
            }
            let rawHost = String(authority)
            self.host = rawHost.isEmpty ? nil : rawHost
            let (hn, pt) = Self.splitHostPort(rawHost)
            self.hostname = hn
            self.port = pt
        } else {
            self.scheme = nil
            self.host = nil
            self.hostname = nil
            self.port = nil
            if beforeQuery.isEmpty {
                self.pathname = "/"
            } else if beforeQuery.hasPrefix("/") {
                self.pathname = String(beforeQuery)
            } else {
                self.pathname = "/" + String(beforeQuery)
            }
        }

        if let queryPart, !queryPart.isEmpty {
            var parsed: [(name: String, value: String)] = []
            for pair in queryPart.split(separator: "&", omittingEmptySubsequences: true) {
                if let eq = pair.firstIndex(of: "=") {
                    parsed.append((
                        name: Self.decodeFormComponent(String(pair[..<eq])),
                        value: Self.decodeFormComponent(String(pair[pair.index(after: eq)...]))
                    ))
                } else {
                    parsed.append((name: Self.decodeFormComponent(String(pair)), value: ""))
                }
            }
            self.queryItems = parsed
        } else {
            self.queryItems = []
        }
    }

    public static func == (lhs: ServerParsedURL, rhs: ServerParsedURL) -> Bool {
        guard lhs.scheme == rhs.scheme,
              lhs.host == rhs.host,
              lhs.hostname == rhs.hostname,
              lhs.port == rhs.port,
              lhs.pathname == rhs.pathname,
              lhs.search == rhs.search,
              lhs.queryItems.count == rhs.queryItems.count else {
            return false
        }
        for i in 0..<lhs.queryItems.count {
            if lhs.queryItems[i].name != rhs.queryItems[i].name || lhs.queryItems[i].value != rhs.queryItems[i].value {
                return false
            }
        }
        return true
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(scheme)
        hasher.combine(host)
        hasher.combine(pathname)
        hasher.combine(search)
    }

    public func queryValue(for name: String) -> String? {
        queryItems.first(where: { $0.name == name })?.value
    }

    public func queryValues(for name: String) -> [String] {
        queryItems.filter { $0.name == name }.map(\.value)
    }

    public static func splitHostPort(_ authority: String) -> (hostname: String?, port: String?) {
        guard !authority.isEmpty else { return (nil, nil) }
        // Strip optional userinfo@
        let hostPart: Substring
        if let at = authority.lastIndex(of: "@") {
            hostPart = authority[authority.index(after: at)...]
        } else {
            hostPart = authority[...]
        }
        if hostPart.hasPrefix("[") {
            guard let close = hostPart.firstIndex(of: "]") else { return (String(hostPart), nil) }
            let hostname = String(hostPart[...close])
            let rest = hostPart[hostPart.index(after: close)...]
            if rest.hasPrefix(":") {
                let portStr = String(rest.dropFirst())
                return (hostname, portStr.isEmpty ? nil : portStr)
            }
            return (hostname, nil)
        }
        if let colon = hostPart.lastIndex(of: ":") {
            let hostname = String(hostPart[..<colon])
            let portStr = String(hostPart[hostPart.index(after: colon)...])
            if portStr.allSatisfy({ $0.isASCII && $0.isNumber }) {
                return (hostname.isEmpty ? nil : hostname, portStr.isEmpty ? nil : portStr)
            }
        }
        return (String(hostPart), nil)
    }

    public static func decodeFormComponent(_ value: String) -> String {
        let bytes = Array(value.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x2B { // '+'
                out.append(0x20)
                i += 1
            } else if b == 0x25, i + 2 < bytes.count,
                      let hi = hexNibble(bytes[i + 1]),
                      let lo = hexNibble(bytes[i + 2]) {
                out.append((hi << 4) | lo)
                i += 3
            } else {
                out.append(b)
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    public static func decodeURIComponentStrict(_ value: String) -> String? {
        let bytes = Array(value.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x25 {
                guard i + 2 < bytes.count,
                      let hi = hexNibble(bytes[i + 1]),
                      let lo = hexNibble(bytes[i + 2]) else {
                    return nil
                }
                out.append((hi << 4) | lo)
                i += 3
            } else {
                out.append(b)
                i += 1
            }
        }
        return String(bytes: out, encoding: .utf8)
    }

    public static func encodeURIComponent(_ value: String) -> String {
        let hex: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "A", "B", "C", "D", "E", "F"]
        var out = ""
        out.reserveCapacity(value.utf8.count)
        for b in value.utf8 {
            let unreserved = (b >= 0x41 && b <= 0x5A)
                || (b >= 0x61 && b <= 0x7A)
                || (b >= 0x30 && b <= 0x39)
                || b == 0x2D || b == 0x5F || b == 0x2E
                || b == 0x21 || b == 0x7E || b == 0x2A
                || b == 0x27 || b == 0x28 || b == 0x29
            if unreserved {
                out.append(Character(UnicodeScalar(b)))
            } else {
                out.append("%")
                out.append(hex[Int(b >> 4)])
                out.append(hex[Int(b & 0x0F)])
            }
        }
        return out
    }

    private static func hexNibble(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: return b - 0x30
        case 0x41...0x46: return b - 0x37
        case 0x61...0x66: return b - 0x57
        default: return nil
        }
    }
}

// MARK: - HTTP Header & Cookie Helpers

public enum ServerHeaders {
    public static func value(in headers: [String: String], for name: String) -> String? {
        if let exact = headers[name] { return exact }
        let target = name.lowercased()
        for (k, v) in headers where k.lowercased() == target {
            return v
        }
        return nil
    }

    public static func set(_ name: String, value: String, in headers: inout [String: String]) {
        let target = name.lowercased()
        let existingKeys = headers.keys.filter { $0.lowercased() == target }
        for key in existingKeys where key != name {
            headers.removeValue(forKey: key)
        }
        headers[name] = value
    }

    public static func merge(_ base: [String: String], _ overlay: [String: String]) -> [String: String] {
        var result = base
        for (k, v) in overlay {
            set(k, value: v, in: &result)
        }
        return result
    }

    public static func parseCookies(from headers: [String: String]) -> [String: String] {
        guard let raw = value(in: headers, for: "cookie"), !raw.isEmpty else { return [:] }
        var out: [String: String] = [:]
        for part in raw.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            let val = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                out[name] = val
            }
        }
        return out
    }
}

// MARK: - Pure-Swift RFC 9110 HTTP Date Formatter & Parser

public enum ServerHTTPDate {
    private static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// Formats epoch milliseconds as RFC 9110 IMF-fixdate (e.g. `"Thu, 01 Jan 1970 00:00:00 GMT"`).
    public static func formatUTCString(epochMs: Int64) -> String {
        let totalSeconds = epochMs >= 0 ? (epochMs / 1000) : ((epochMs - 999) / 1000)
        var days = totalSeconds / 86_400
        var rem = totalSeconds % 86_400
        if rem < 0 {
            rem += 86_400
            days -= 1
        }
        let hour = Int(rem / 3600)
        let minute = Int((rem % 3600) / 60)
        let second = Int(rem % 60)

        // 1970-01-01 was Thursday (4)
        var dow = Int((days + 4) % 7)
        if dow < 0 { dow += 7 }

        // Howard Hinnant civil-from-days algorithm
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        var y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = Int(doy - (153 * mp + 2) / 5 + 1)
        let m = Int(mp < 10 ? mp + 3 : mp - 9)
        if m <= 2 { y += 1 }

        return "\(weekdays[dow]), \(pad2(d)) \(months[m - 1]) \(pad4(Int(y))) \(pad2(hour)):\(pad2(minute)):\(pad2(second)) GMT"
    }

    /// Parses an IMF-fixdate HTTP date string to epoch milliseconds.
    public static func parseUTCString(_ raw: String) -> Int64? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 6,
              let day = Int(parts[1]),
              let monthIdx = months.firstIndex(where: { $0.caseInsensitiveCompare(String(parts[2])) == .orderedSame }),
              let year = Int(parts[3]),
              parts[5].uppercased() == "GMT" else {
            return nil
        }
        let timeParts = parts[4].split(separator: ":")
        guard timeParts.count == 3,
              let hour = Int(timeParts[0]),
              let minute = Int(timeParts[1]),
              let second = Int(timeParts[2]),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...60).contains(second),
              (1...31).contains(day) else {
            return nil
        }
        let month = monthIdx + 1
        var y = Int64(year)
        if month <= 2 { y -= 1 }
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mAdj = Int64(month > 2 ? month - 3 : month + 9)
        let doy = (153 * mAdj + 2) / 5 + Int64(day) - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        let seconds = days * 86_400 + Int64(hour) * 3600 + Int64(minute) * 60 + Int64(second)
        return seconds * 1000
    }

    private static func pad2(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    private static func pad4(_ value: Int) -> String {
        if value < 10 { return "000\(value)" }
        if value < 100 { return "00\(value)" }
        if value < 1000 { return "0\(value)" }
        return "\(value)"
    }
}

// MARK: - Host OS Identity Helpers (Guarded)

public enum ServerHostInfo {
    public static func processID() -> Int {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        return Int(getpid())
        #else
        return 0
        #endif
    }

    public static func hostname() -> String? {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return nil }
        let raw = buffer.withUnsafeBufferPointer { ptr -> String in
            let bytes = ptr.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            return String(decoding: bytes, as: UTF8.self)
        }
        return raw.isEmpty ? nil : raw
        #else
        return nil
        #endif
    }

    public static func currentWorkingDirectory() -> String {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        var buffer = [CChar](repeating: 0, count: 4096)
        guard getcwd(&buffer, buffer.count) != nil else { return "/" }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let path = String(decoding: bytes, as: UTF8.self)
        return path.isEmpty ? "/" : path
        #else
        return "/"
        #endif
    }

    /// Enumerates non-internal network interface addresses matching IPv4 or IPv6 family.
    public static func externalInterfaceAddresses(ipv6: Bool) -> [String] {
        #if canImport(Darwin) || canImport(Glibc)
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return [] }
        defer { freeifaddrs(first) }
        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let sa = current.pointee.ifa_addr else { continue }
            let family = Int32(sa.pointee.sa_family)
            let wantFamily = ipv6 ? AF_INET6 : AF_INET
            guard family == wantFamily else { continue }
            var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let saLen: socklen_t
            #if canImport(Darwin)
            saLen = socklen_t(sa.pointee.sa_len)
            #else
            saLen = socklen_t(ipv6 ? MemoryLayout<sockaddr_in6>.size : MemoryLayout<sockaddr_in>.size)
            #endif
            if getnameinfo(sa, saLen, &hostBuf, socklen_t(hostBuf.count), nil, 0, NI_NUMERICHOST) == 0 {
                let bytes = hostBuf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                let str = String(decoding: bytes, as: UTF8.self)
                // Strip IPv6 zone identifier (%en0) if present.
                let cleaned = str.split(separator: "%", maxSplits: 1).first.map(String.init) ?? str
                if !cleaned.isEmpty && !addresses.contains(cleaned) {
                    addresses.append(cleaned)
                }
            }
        }
        return addresses
        #else
        _ = ipv6
        return []
        #endif
    }
}

// MARK: - Protocol Error Response Encoding

public enum ServerErrorResponse {
    public static func encode(_ error: any Error) -> ServerHTTPResponse? {
        if let proto = error as? any ProtocolError {
            return encodeProtocolError(proto)
        }
        if let envelope = error as? ProtocolErrorEnvelope {
            return encodeEnvelope(envelope)
        }
        if let tooLarge = error as? InstructionEntrySchema.ValueTooLargeError {
            return ServerHTTPResponse.json(tooLarge, statusCode: 413)
        }
        if let coreTooLarge = error as? CoreSessionInstructionEntry.ValueTooLargeError {
            let wire = InstructionEntrySchema.ValueTooLargeError(
                actualBytes: coreTooLarge.actualBytes,
                maxBytes: coreTooLarge.maxBytes,
                message: coreTooLarge.message
            )
            return ServerHTTPResponse.json(wire, statusCode: 413)
        }
        return nil
    }

    public static func encodeProtocolError<E: ProtocolError>(_ error: E) -> ServerHTTPResponse {
        ServerHTTPResponse.json(error, statusCode: E.httpStatusCode)
    }

    private static func encodeEnvelope(_ envelope: ProtocolErrorEnvelope) -> ServerHTTPResponse {
        switch envelope {
        case .locationNotFound(let e): return encodeProtocolError(e)
        case .invalidRequest(let e): return encodeProtocolError(e)
        case .rpc(let e): return encodeProtocolError(e)
        case .rpcInternal(let e): return encodeProtocolError(e)
        case .unauthorized(let e): return encodeProtocolError(e)
        case .conflict(let e): return encodeProtocolError(e)
        case .sessionBusy(let e): return encodeProtocolError(e)
        case .serviceUnavailable(let e): return encodeProtocolError(e)
        case .unknown(let e): return encodeProtocolError(e)
        case .providerNotFound(let e): return encodeProtocolError(e)
        case .integrationNotFound(let e): return encodeProtocolError(e)
        case .integrationAttemptNotFound(let e): return encodeProtocolError(e)
        case .integrationMethodNotFound(let e): return encodeProtocolError(e)
        case .projectNotFound(let e): return encodeProtocolError(e)
        case .fileNotFound(let e): return encodeProtocolError(e)
        case .pluginNotFound(let e): return encodeProtocolError(e)
        case .agentNotFound(let e): return encodeProtocolError(e)
        case .sessionNotFound(let e): return encodeProtocolError(e)
        case .messageNotFound(let e): return encodeProtocolError(e)
        case .skillNotFound(let e): return encodeProtocolError(e)
        case .mcpServerNotFound(let e): return encodeProtocolError(e)
        case .commandNotFound(let e): return encodeProtocolError(e)
        case .commandExecution(let e): return encodeProtocolError(e)
        case .invalidCursor(let e): return encodeProtocolError(e)
        case .permissionNotFound(let e): return encodeProtocolError(e)
        case .permissionSavedNotFound(let e): return encodeProtocolError(e)
        case .formNotFound(let e): return encodeProtocolError(e)
        case .formAlreadySettled(let e): return encodeProtocolError(e)
        case .formInvalidAnswer(let e): return encodeProtocolError(e)
        case .forbidden(let e): return encodeProtocolError(e)
        case .ptyNotFound(let e): return encodeProtocolError(e)
        case .ptyFeatureUnsupported(let e): return encodeProtocolError(e)
        case .shellNotFound(let e): return encodeProtocolError(e)
        case .modelNotFound(let e): return encodeProtocolError(e)
        case .unsupportedModel(let e): return encodeProtocolError(e)
        case .providerRequest(let e): return encodeProtocolError(e)
        case .automationNotFound(let e): return encodeProtocolError(e)
        case .videoNotFound(let e): return encodeProtocolError(e)
        case .blobNotFound(let e): return encodeProtocolError(e)
        case .artifactNotFound(let e): return encodeProtocolError(e)
        case .vcsInitNotSupported(let e): return encodeProtocolError(e)
        case .worktree(let e): return encodeProtocolError(e)
        }
    }
}

// MARK: - Server Location Service Container

/// Location-scoped service container exposing every `OpenCodeCore` per-location service
/// without ever blocking handlers waiting for async plugin loading.
public final class ServerLocationBundle: Sendable {
    public let ref: LocationSchema.Ref
    public let location: CoreLocation.Location.Service
    public let lifecycle: CoreLocation.Lifecycle.Service
    public let config: any CoreConfig.Interface
    public let flag: any CoreFlag.Interface
    public let agent: any CoreAgent.Agent.Interface
    public let plugin: any CorePlugin.ServiceInterface
    public let hooks: any CorePlugin.Hooks.Interface
    public let command: any CoreSubsystems.Command.Interface
    public let skill: any CoreSkill.Interface
    public let reference: any CoreInstruction.Reference.Interface
    public let fileSystem: any CoreFilesystem.Interface
    public let fileSystemSearch: any CoreFilesystem.Search.Interface
    public let shell: any CoreShell.Interface
    public let shellSelect: any CoreShell.Select.Interface
    public let pty: any CorePty.Interface
    public let permission: any CorePermission.Interface
    public let form: any CoreIntegration.Form.Interface
    public let vcs: any CoreVcs.Vcs.Interface
    public let provider: any CoreProvider.Provider.Interface
    public let model: any CoreModel.Model.Interface
    public let integration: any CoreIntegration.Integration.Interface
    public let mcp: any CoreMCP.Registry.Interface
    public let rpc: any CoreIntegration.Rpc.Interface
    public let webSearch: any CoreIntegration.WebSearch.Interface
    public let usageLimits: any CoreProvider.UsageLimits.Interface
    public let generate: any CoreIntegration.Generate.Interface
    public let voice: any CoreIntegration.Voice.Interface
    public let artifact: any CoreArtifact.Interface
    public let snapshot: any CoreSnapshot.Interface
    public let worktreeStrategies: any CoreWorktree.Strategies.Interface
    public let tool: any CoreTool.Interface
    public let sessionRunner: (any CoreSessionRunner.Interface)?
    public let sessionTitle: (any CoreSessionTitle.Interface)?

    /// In-memory OAuth and command authentication attempt registries for integration connect flows.
    internal let integrationAttempts: IntegrationAttemptStore

    public var layerOutput: LayerNode.Output {
        var map: [String: any Sendable] = [
            "@opencode/ServerLocationBundle": self,
            CoreLocation.Location.Service.serviceKey: location,
            CoreLocation.Lifecycle.Service.serviceKey: lifecycle,
            CoreConfig.Service.serviceKey: config,
            CoreFlag.Service.serviceKey: flag,
            CoreAgent.Agent.Service.serviceKey: agent,
            CorePlugin.Service.serviceKey: plugin,
            CorePlugin.Hooks.Service.serviceKey: hooks,
            CoreSubsystems.Command.Service.serviceKey: command,
            CoreSkill.Service.serviceKey: skill,
            CoreInstruction.Reference.Service.serviceKey: reference,
            CoreFilesystem.Service.serviceKey: fileSystem,
            CoreFilesystem.Search.Service.serviceKey: fileSystemSearch,
            CoreShell.Service.serviceKey: shell,
            CoreShell.Select.Service.serviceKey: shellSelect,
            CorePty.Service.serviceKey: pty,
            CorePermission.Service.serviceKey: permission,
            CoreIntegration.Form.Service.serviceKey: form,
            CoreVcs.Vcs.Service.serviceKey: vcs,
            CoreProvider.Provider.Service.serviceKey: provider,
            CoreModel.Model.Service.serviceKey: model,
            CoreIntegration.Integration.Service.serviceKey: integration,
            CoreMCP.Registry.Service.serviceKey: mcp,
            CoreIntegration.Rpc.Service.serviceKey: rpc,
            CoreIntegration.WebSearch.Service.serviceKey: webSearch,
            CoreProvider.UsageLimits.Service.serviceKey: usageLimits,
            CoreIntegration.Generate.Service.serviceKey: generate,
            CoreIntegration.Voice.Service.serviceKey: voice,
            CoreArtifact.Service.serviceKey: artifact,
            CoreSnapshot.Service.serviceKey: snapshot,
            CoreWorktree.Strategies.Service.serviceKey: worktreeStrategies,
            CoreTool.Service.serviceKey: tool,
        ]
        if let sessionRunner {
            map[CoreSessionRunner.Service.serviceKey] = sessionRunner
        }
        if let sessionTitle {
            map[CoreSessionTitle.Service.serviceKey] = sessionTitle
        }
        return LayerNode.Output(map)
    }

    public init(
        ref: LocationSchema.Ref,
        location: CoreLocation.Location.Service,
        lifecycle: CoreLocation.Lifecycle.Service,
        config: any CoreConfig.Interface,
        flag: any CoreFlag.Interface,
        agent: any CoreAgent.Agent.Interface,
        plugin: any CorePlugin.ServiceInterface,
        hooks: any CorePlugin.Hooks.Interface,
        command: any CoreSubsystems.Command.Interface,
        skill: any CoreSkill.Interface,
        reference: any CoreInstruction.Reference.Interface,
        fileSystem: any CoreFilesystem.Interface,
        fileSystemSearch: any CoreFilesystem.Search.Interface,
        shell: any CoreShell.Interface,
        shellSelect: any CoreShell.Select.Interface,
        pty: any CorePty.Interface,
        permission: any CorePermission.Interface,
        form: any CoreIntegration.Form.Interface,
        vcs: any CoreVcs.Vcs.Interface,
        provider: any CoreProvider.Provider.Interface,
        model: any CoreModel.Model.Interface,
        integration: any CoreIntegration.Integration.Interface,
        mcp: any CoreMCP.Registry.Interface,
        rpc: any CoreIntegration.Rpc.Interface,
        webSearch: any CoreIntegration.WebSearch.Interface,
        usageLimits: any CoreProvider.UsageLimits.Interface,
        generate: any CoreIntegration.Generate.Interface,
        voice: any CoreIntegration.Voice.Interface,
        artifact: any CoreArtifact.Interface,
        snapshot: any CoreSnapshot.Interface,
        worktreeStrategies: any CoreWorktree.Strategies.Interface,
        tool: any CoreTool.Interface = CoreTool.Service(),
        sessionRunner: (any CoreSessionRunner.Interface)? = nil,
        sessionTitle: (any CoreSessionTitle.Interface)? = nil
    ) {
        self.ref = ref
        self.location = location
        self.lifecycle = lifecycle
        self.config = config
        self.flag = flag
        self.agent = agent
        self.plugin = plugin
        self.hooks = hooks
        self.command = command
        self.skill = skill
        self.reference = reference
        self.fileSystem = fileSystem
        self.fileSystemSearch = fileSystemSearch
        self.shell = shell
        self.shellSelect = shellSelect
        self.pty = pty
        self.permission = permission
        self.form = form
        self.vcs = vcs
        self.provider = provider
        self.model = model
        self.integration = integration
        self.mcp = mcp
        self.rpc = rpc
        self.webSearch = webSearch
        self.usageLimits = usageLimits
        self.generate = generate
        self.voice = voice
        self.artifact = artifact
        self.snapshot = snapshot
        self.worktreeStrategies = worktreeStrategies
        self.tool = tool
        self.sessionRunner = sessionRunner
        self.sessionTitle = sessionTitle
        self.integrationAttempts = IntegrationAttemptStore()
    }

    public var publicInfo: LocationSchema.PublicInfo {
        LocationSchema.PublicInfo(
            directory: location.info.directory,
            project: location.info.project
        )
    }

    public var publicRef: LocationSchema.PublicRef {
        LocationSchema.PublicRef(directory: location.info.directory)
    }

    public static func from(_ output: LayerNode.Output) -> ServerLocationBundle? {
        output.get("@opencode/ServerLocationBundle", as: ServerLocationBundle.self)
    }
}

/// Process-local OAuth & command connect attempt tracker for `IntegrationHandler`.
internal final class IntegrationAttemptStore: Sendable {
    struct OAuthEntry: Sendable {
        let integrationID: IntegrationSchema.ID
        let attemptID: IntegrationSchema.AttemptID
        let methodID: IntegrationSchema.MethodID
        let label: String?
        var status: IntegrationSchema.AttemptStatus
    }

    struct CommandEntry: Sendable {
        let integrationID: IntegrationSchema.ID
        let attemptID: IntegrationSchema.AttemptID
        let methodID: IntegrationSchema.MethodID
        let label: String?
        var status: IntegrationSchema.CommandAttemptStatus
    }

    private struct State: Sendable {
        var oauth: [String: OAuthEntry] = [:]
        var command: [String: CommandEntry] = [:]
    }

    private let state = Mutex(State())

    private func key(_ integrationID: IntegrationSchema.ID, _ attemptID: IntegrationSchema.AttemptID) -> String {
        "\(integrationID.rawValue)::\(attemptID.rawValue)"
    }

    func createOAuth(
        integrationID: IntegrationSchema.ID,
        methodID: IntegrationSchema.MethodID,
        label: String?,
        url: String = "https://auth.opencode.local/authorize"
    ) -> IntegrationSchema.Attempt {
        let id = IntegrationSchema.AttemptID(rawValue: "att_\(uuid().prefix(12))")
        let k = key(integrationID, id)
        let now = Double(Flock.currentEpochMs())
        let time = IntegrationSchema.AttemptTime(created: now, expires: now + 300_000)
        let entry = OAuthEntry(
            integrationID: integrationID,
            attemptID: id,
            methodID: methodID,
            label: label,
            status: .pending(time: time)
        )
        state.withLock { $0.oauth[k] = entry }
        return IntegrationSchema.Attempt(
            attemptID: id,
            url: url,
            instructions: "Complete authorization in your browser",
            mode: .code,
            time: time
        )
    }

    func oauthStatus(
        integrationID: IntegrationSchema.ID,
        attemptID: IntegrationSchema.AttemptID
    ) -> IntegrationSchema.AttemptStatus? {
        let k = key(integrationID, attemptID)
        return state.withLock { $0.oauth[k]?.status }
    }

    func completeOAuth(
        integrationID: IntegrationSchema.ID,
        attemptID: IntegrationSchema.AttemptID,
        code: String?
    ) throws -> OAuthEntry {
        let k = key(integrationID, attemptID)
        return try state.withLock { s in
            guard var entry = s.oauth[k] else {
                throw IntegrationAttemptNotFoundError(
                    integrationID: integrationID.rawValue,
                    attemptID: attemptID.rawValue,
                    message: "OAuth attempt not found: \(attemptID.rawValue)"
                )
            }
            guard let code, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw InvalidRequestError(
                    message: "Authorization code is required",
                    kind: "integration_code_required"
                )
            }
            let now = Double(Flock.currentEpochMs())
            entry.status = .complete(time: IntegrationSchema.AttemptTime(created: now, expires: now + 300_000))
            s.oauth[k] = entry
            return entry
        }
    }

    func cancelOAuth(integrationID: IntegrationSchema.ID, attemptID: IntegrationSchema.AttemptID) {
        let k = key(integrationID, attemptID)
        state.withLock { _ = $0.oauth.removeValue(forKey: k) }
    }

    func createCommand(
        integrationID: IntegrationSchema.ID,
        methodID: IntegrationSchema.MethodID,
        label: String?
    ) -> IntegrationSchema.CommandAttempt {
        let id = IntegrationSchema.AttemptID(rawValue: "cmd_\(uuid().prefix(12))")
        let k = key(integrationID, id)
        let now = Double(Flock.currentEpochMs())
        let time = IntegrationSchema.AttemptTime(created: now, expires: now + 300_000)
        let entry = CommandEntry(
            integrationID: integrationID,
            attemptID: id,
            methodID: methodID,
            label: label,
            status: .pending(message: nil, time: time)
        )
        state.withLock { $0.command[k] = entry }
        return IntegrationSchema.CommandAttempt(attemptID: id, time: time)
    }

    func commandStatus(
        integrationID: IntegrationSchema.ID,
        attemptID: IntegrationSchema.AttemptID
    ) -> IntegrationSchema.CommandAttemptStatus? {
        let k = key(integrationID, attemptID)
        return state.withLock { $0.command[k]?.status }
    }

    func cancelCommand(integrationID: IntegrationSchema.ID, attemptID: IntegrationSchema.AttemptID) {
        let k = key(integrationID, attemptID)
        state.withLock { _ = $0.command.removeValue(forKey: k) }
    }
}

// MARK: - Process-Global Server Runtime

/// Composes the full `OpenCodeCore` process-global and per-location service graph backing `OpenCodeServer`.
public final class ServerAppRuntime: Sendable {
    public let options: ServerOptions
    public let authConfig: ServerAuth.Info
    public let corsOptions: CorsOptions
    public let global: Global.Interface
    public let fileSystem: any OpenCodeFileSystem
    public let httpTransport: any HTTPTransport
    public let db: any SQLiteDatabase
    public let databaseService: CoreDatabaseStore.Service
    public let bus: CoreBus.Service
    public let kv: CoreKV.Service
    public let sessionStore: CoreSessionStore.Service
    public let sessionInbox: CoreSessionInbox.Service
    public let sessionExecution: any CoreSessionExecution.Interface
    public let sessionEnvironment: CoreSessionEnvironment.Service
    public let session: CoreSession.Service
    public let sessionTransfer: CoreSessionTransfer.Service
    public let sessionInstructions: CoreSessionInstructionEntry.Service
    public let sessionMove: CoreSessionMove.Service
    public let sessionRestart: CoreSessionRestart.Service
    public let project: CoreProject.Project.Service
    public let worktree: CoreWorktree.Service
    public let credential: CoreProvider.Credential.Service
    public let permissionSaved: CorePermissionSaved.Service
    public let blobStore: any CoreBlobStore.Interface
    public let videoGeneration: any CoreIntegration.VideoGeneration.Interface
    public let automation: CoreAutomation.Service
    public let job: CoreJob.Service
    public let ptyTicket: CorePty.Ticket.Service
    public let persistentPty: any CorePty.Persistent.Interface
    public let fileWatch: CoreFilesystem.FileWatch.Service
    public let pluginUpdate: any CorePlugin.Update.Interface
    public let wellKnown: any CoreIntegration.WellKnown.Interface
    public let pairing: ServerPairing.Service
    public let eventFeed: EventFeed.Service
    public let locations: CoreLocation.ServiceMap.Service
    public let locationActivity: CoreLocation.Activity.Service
    public let instance: CoreLocation.Instance.Service
    public let serverInfo: ServerInfo.Service
    public let modelsDev: CoreModel.ModelsDev.Service
    public let oauthManager: ServerLiveOAuthManager
    public let allowLiveNetwork: Bool
    public let modelsDevOptions: CoreModel.ModelsDev.Options
    public let defaultDirectory: String
    public let scope: LayerNode.ResourceScope
    private let backgroundRefreshTask = Mutex<Task<Void, Never>?>(nil)
    private let isClosed = Mutex(false)

    public init(
        options: ServerOptions,
        authConfig: ServerAuth.Info,
        global: Global.Interface,
        fileSystem: any OpenCodeFileSystem,
        httpTransport: any HTTPTransport,
        databaseService: CoreDatabaseStore.Service,
        bus: CoreBus.Service,
        kv: CoreKV.Service,
        sessionStore: CoreSessionStore.Service,
        sessionInbox: CoreSessionInbox.Service,
        sessionExecution: any CoreSessionExecution.Interface,
        sessionEnvironment: CoreSessionEnvironment.Service,
        session: CoreSession.Service,
        sessionTransfer: CoreSessionTransfer.Service,
        sessionInstructions: CoreSessionInstructionEntry.Service,
        sessionMove: CoreSessionMove.Service,
        sessionRestart: CoreSessionRestart.Service,
        project: CoreProject.Project.Service,
        worktree: CoreWorktree.Service,
        credential: CoreProvider.Credential.Service,
        permissionSaved: CorePermissionSaved.Service,
        blobStore: any CoreBlobStore.Interface,
        videoGeneration: any CoreIntegration.VideoGeneration.Interface,
        automation: CoreAutomation.Service,
        job: CoreJob.Service,
        ptyTicket: CorePty.Ticket.Service,
        persistentPty: any CorePty.Persistent.Interface,
        fileWatch: CoreFilesystem.FileWatch.Service,
        pluginUpdate: any CorePlugin.Update.Interface,
        wellKnown: any CoreIntegration.WellKnown.Interface,
        pairing: ServerPairing.Service,
        eventFeed: EventFeed.Service,
        locations: CoreLocation.ServiceMap.Service,
        locationActivity: CoreLocation.Activity.Service,
        instance: CoreLocation.Instance.Service,
        serverInfo: ServerInfo.Service,
        modelsDev: CoreModel.ModelsDev.Service? = nil,
        oauthManager: ServerLiveOAuthManager? = nil,
        allowLiveNetwork: Bool = false,
        modelsDevOptions: CoreModel.ModelsDev.Options? = nil,
        defaultDirectory: String,
        scope: LayerNode.ResourceScope
    ) {
        self.options = options
        self.authConfig = authConfig
        self.corsOptions = CorsOptions(cors: options.cors)
        self.global = global
        self.fileSystem = fileSystem
        self.httpTransport = httpTransport
        self.db = databaseService.db
        self.databaseService = databaseService
        self.bus = bus
        self.kv = kv
        self.sessionStore = sessionStore
        self.sessionInbox = sessionInbox
        self.sessionExecution = sessionExecution
        self.sessionEnvironment = sessionEnvironment
        self.session = session
        self.sessionTransfer = sessionTransfer
        self.sessionInstructions = sessionInstructions
        self.sessionMove = sessionMove
        self.sessionRestart = sessionRestart
        self.project = project
        self.worktree = worktree
        self.credential = credential
        self.permissionSaved = permissionSaved
        self.blobStore = blobStore
        self.videoGeneration = videoGeneration
        self.automation = automation
        self.job = job
        self.ptyTicket = ptyTicket
        self.persistentPty = persistentPty
        self.fileWatch = fileWatch
        self.pluginUpdate = pluginUpdate
        self.wellKnown = wellKnown
        self.pairing = pairing
        self.eventFeed = eventFeed
        self.locations = locations
        self.locationActivity = locationActivity
        self.instance = instance
        self.serverInfo = serverInfo
        let trimmedCacheDir = global.cache.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let defaultCachePath = "\(trimmedCacheDir.isEmpty ? "" : "/\(trimmedCacheDir)")/models.json"
        let effectiveModelsOpts = modelsDevOptions ?? options.models ?? CoreModel.ModelsDev.Options(
            file: nil,
            fetch: allowLiveNetwork
        )
        self.modelsDevOptions = effectiveModelsOpts
        self.allowLiveNetwork = allowLiveNetwork
        self.modelsDev = modelsDev ?? CoreModel.ModelsDev.Service(
            options: effectiveModelsOpts,
            http: httpTransport,
            fileSystem: fileSystem,
            kv: kv,
            bus: bus,
            cacheFilePath: effectiveModelsOpts.file ?? defaultCachePath,
            userAgent: "\(options.app?.name ?? "opencode")/\(options.app?.version ?? "2.3.2")"
        )
        self.oauthManager = oauthManager ?? ServerLiveOAuthManager(
            credential: credential,
            httpTransport: httpTransport,
            kv: kv,
            bus: bus
        )
        self.defaultDirectory = defaultDirectory
        self.scope = scope
    }

    /// Force-refreshes the live ModelsDev catalog (when live network is enabled) prior to location reload.
    public func forceRefreshCatalogs() async {
        guard allowLiveNetwork else { return }
        _ = await ServerLiveRuntime.refreshModelsDevCatalog(
            modelsDev: modelsDev,
            kv: kv,
            fileSystem: fileSystem,
            httpTransport: httpTransport,
            globalPaths: global,
            options: modelsDevOptions
        )
    }

    /// Reloads active locations when a credential affecting remote/free catalog discovery changes.
    internal func reloadCatalogsIfNeeded(for integrationID: IntegrationID) async {
        let dynamicCatalogIntegrations: Set<String> = ["opencode", "openai", "github-copilot"]
        guard dynamicCatalogIntegrations.contains(integrationID.rawValue) else { return }
        guard !locations.keys().isEmpty else { return }
        try? await CoreLocation.ServiceMap.reload(locations)
    }

    /// Schedules a non-blocking background ModelsDev catalog refresh when the cache is cold or stale.
    internal func startBackgroundModelsDevRefreshIfNeeded() {
        guard allowLiveNetwork else { return }
        let alreadyStarted = backgroundRefreshTask.withLock { $0 != nil }
        guard !alreadyStarted else { return }
        let task = Task(priority: .utility) { [self] in
            let needsRefresh = await ServerLiveRuntime.isModelsDevCacheColdOrStale(
                kv: kv,
                globalPaths: global,
                fileSystem: fileSystem,
                options: modelsDevOptions
            )
            guard needsRefresh, !Task.isCancelled, !isClosed.withLock({ $0 }) else { return }
            let changed = await ServerLiveRuntime.refreshModelsDevCatalog(
                modelsDev: modelsDev,
                kv: kv,
                fileSystem: fileSystem,
                httpTransport: httpTransport,
                globalPaths: global,
                options: modelsDevOptions
            )
            guard changed, !Task.isCancelled, !isClosed.withLock({ $0 }) else { return }
            if !locations.keys().isEmpty {
                try? await CoreLocation.ServiceMap.reload(locations)
            }
            let empty = JSONValue.object([:])
            await bus.emit(EventSchema.EphemeralDefinition<JSONValue>(type: IntegrationSchema.Event.updated.type), data: empty)
            await bus.emit(EventSchema.EphemeralDefinition<JSONValue>(type: ProviderSchema.Event.updated.type), data: empty)
            await bus.emit(EventSchema.EphemeralDefinition<JSONValue>(type: ModelSchema.Event.updated.type), data: empty)
        }
        backgroundRefreshTask.withLock { $0 = task }
    }

    /// Resolves and boots the `ServerLocationBundle` for `ref`, mapping missing directories to `LocationNotFoundError`.
    public func resolveLocation(_ ref: LocationSchema.Ref) async throws -> ServerLocationBundle {
        let canonical = CoreLocation.ServiceMap.canonical(ref)
        locationActivity.touch(canonical)
        let output: LayerNode.Output
        do {
            output = try await locations.get(canonical)
        } catch let dirNotFound as CoreFilesystem.DirectoryNotFoundError {
            throw LocationNotFoundError(
                location: OpenCodeLocation(directory: dirNotFound.directory.rawValue, workspaceID: canonical.workspaceID),
                message: "Location not found: \(dirNotFound.directory.rawValue)"
            )
        } catch let instErr as CoreLocation.Instance.Error {
            if case .directoryNotFound(let dir) = instErr {
                throw LocationNotFoundError(
                    location: OpenCodeLocation(directory: dir, workspaceID: canonical.workspaceID),
                    message: "Location not found: \(dir)"
                )
            }
            throw instErr
        }
        guard let bundle = ServerLocationBundle.from(output) else {
            throw LocationNotFoundError(
                location: OpenCodeLocation(directory: canonical.directory.rawValue, workspaceID: canonical.workspaceID),
                message: "Location not found: \(canonical.directory.rawValue)"
            )
        }
        startBackgroundModelsDevRefreshIfNeeded()
        return bundle
    }

    public func close() async {
        isClosed.withLock { $0 = true }
        backgroundRefreshTask.withLock { task in
            task?.cancel()
            task = nil
        }
        await oauthManager.close()
        let activeSessions = await sessionExecution.active()
        if let liveExec = sessionExecution as? ServerLiveRuntime.LiveSessionExecution {
            for sid in activeSessions {
                _ = await liveExec.shutdownInterrupt(sid)
            }
        } else if let liveExec = sessionExecution as? CoreSessionExecution.Service {
            for sid in activeSessions {
                _ = await liveExec.shutdownInterrupt(sid)
            }
        } else {
            for sid in activeSessions {
                _ = await sessionExecution.interrupt(sid, resume: false)
            }
        }
        for sid in activeSessions {
            await sessionExecution.awaitIdle(sid)
        }
        await locations.closeAll()
        await eventFeed.close()
        await scope.close()
    }

    /// Customizer invoked when building each per-location `ServerLocationBundle` (e.g. for tests or runtime profiles).
    public typealias LocationCustomizer = @Sendable (ServerLocationBundle) async -> Void

    /// Boots a complete `ServerAppRuntime` backed by `OpenCodeCore` services.
    public static func make(
        options: ServerOptions = ServerOptions(),
        serviceURLs: @escaping @Sendable () -> [String] = { [] },
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
        httpTransport: any HTTPTransport = URLSessionHTTPTransport.shared,
        environment: any EnvironmentProviding = SystemEnvironment.shared,
        globalOverrides: Global.Overrides? = nil,
        defaultDirectory: String? = nil,
        databaseClient: (any SQLiteDatabase)? = nil,
        customPersistentPty: (any CorePty.Persistent.Interface)? = nil,
        customBlobStore: (any CoreBlobStore.Interface)? = nil,
        customVideoGeneration: (any CoreIntegration.VideoGeneration.Interface)? = nil,
        customPluginUpdate: (any CorePlugin.Update.Interface)? = nil,
        customWellKnown: (any CoreIntegration.WellKnown.Interface)? = nil,
        workerdProfile: Bool = false,
        onLocationBoot: LocationCustomizer? = nil
    ) async throws -> ServerAppRuntime {
        let scope = LayerNode.ResourceScope()
        var effectiveGlobalOverrides = globalOverrides ?? Global.Overrides()
        if let cfgDir = options.config?.directory, effectiveGlobalOverrides.config == nil {
            effectiveGlobalOverrides.config = cfgDir
        }
        let globalPaths = Global.make(effectiveGlobalOverrides, environment: environment)
        let dbService: CoreDatabaseStore.Service
        if let databaseClient {
            dbService = try CoreDatabaseStore.bootstrap(
                client: databaseClient,
                dataDirectory: globalPaths.data,
                fileSystem: fileSystem,
                legacyCredentials: false
            )
        } else {
            let dbOpts = options.database ?? CoreDatabaseStore.Options(path: ":memory:")
            dbService = try await CoreDatabaseStore.open(
                options: dbOpts,
                dataDirectory: globalPaths.data,
                fileSystem: fileSystem,
                legacyCredentials: false
            )
        }
        let db = dbService.db

        if !workerdProfile {
            try? await CoreDatabaseMigration.importLegacyCredentials(
                tx: db,
                filepath: "\(globalPaths.data)/auth.json",
                fileSystem: fileSystem
            )
        }

        let bus = CoreBus.Service(
            db: db,
            options: CoreBus.Options(persist: options.events?.persist ?? true)
        )
        let kv = try CoreKV.Service(database: db)
        let sessionStore = CoreSessionStore.Service(db: db)
        let sessionInbox = CoreSessionInbox.Service(db: db, bus: bus)
        let sessionEnv = CoreSessionEnvironment.Service()
        let sessionTransfer = CoreSessionTransfer.Service(db: db, bus: bus, store: sessionStore)
        let sessionInstructions = CoreSessionInstructionEntry.Service(db: db)

        // Install session event projectors transactionally on the bus.
        CoreSessionProjector.register(bus: bus, db: db)

        let hostSpawner: any ProcessSpawner = (fileSystem is InMemoryFileSystem || workerdProfile)
            ? CoreLocation.Environment.UnavailableSpawner()
            : CrossSpawnSpawner.HostProcessSpawner.shared
        let gitService = CoreVcs.Git.Service(spawner: hostSpawner, fileSystem: fileSystem)
        let project = try CoreProject.Project.Service(database: db, fileSystem: fileSystem, git: gitService)
        let worktree = try CoreWorktree.Service(database: db, fileSystem: fileSystem)
        let credential = try CoreProvider.Credential.Service(database: db)
        let permissionSaved = try CorePermissionSaved.Service(database: db)
        let blobStore: any CoreBlobStore.Interface = customBlobStore ?? (
            workerdProfile
                ? ServerUnsupportedBlobStore()
                : CoreBlobStore.Service(globalPaths: globalPaths, fileSystem: fileSystem)
        )
        let videoGeneration: any CoreIntegration.VideoGeneration.Interface = customVideoGeneration ?? (
            workerdProfile
                ? ServerUnsupportedVideoGeneration()
                : CoreIntegration.VideoGeneration.Service(
                    start: { _, _ in
                        throw CoreIntegration.Generate.UnavailableError(message: "Video generation provider not configured", service: "video")
                    },
                    get: { id in
                        throw CoreIntegration.VideoGeneration.NotFoundError(id: id.rawValue)
                    }
                )
        )
        let job = try CoreJob.Service(database: db, bus: bus)
        let ptyTicket = CorePty.Ticket.make()
        let persistentPty: any CorePty.Persistent.Interface = customPersistentPty ?? CorePty.Persistent.Service(
            options: options.pty
        )
        let fileWatch = CoreFilesystem.FileWatch.Service(enabled: options.fs?.filewatcher ?? true)
        let pluginUpdate: any CorePlugin.Update.Interface = customPluginUpdate ?? ServerNoopPluginUpdateService()
        let wellKnown: any CoreIntegration.WellKnown.Interface = customWellKnown ?? CoreIntegration.WellKnown.Service(
            transport: httpTransport,
            kv: kv,
            environment: environment
        )
        let pairing = ServerPairing.Service()
        let eventFeed = EventFeed.make(observe: { subscriber in
            bus.listen(subscriber)
        })
        let serverInfo = ServerInfo.Service(
            urls: serviceURLs,
            app: options.app ?? ServerOptions.AppOptions(),
            paths: ServerInfo.Paths(tmp: globalPaths.tmp)
        )
        let authConfig = ServerAuth.Info(password: options.password, username: "opencode")
        let resolvedDefaultDir = defaultDirectory ?? ServerHostInfo.currentWorkingDirectory()

        let locationActivity = CoreLocation.Activity.Service()
        let capturedConfigOpts = options.config
        let capturedWorkerd = workerdProfile
        let capturedFs = fileSystem
        let capturedHttp = httpTransport
        let capturedEnv = environment
        let capturedGlobal = globalPaths
        let capturedOptions = options

        let allowLiveNetwork: Bool = {
            if let explicitFetch = options.models?.fetch { return explicitFetch }
            if workerdProfile || fileSystem is InMemoryFileSystem { return false }
            return true
        }()
        let explicitSyncFetch = (options.models?.fetch == true)
        let trimmedCacheDir: String = {
            var s = globalPaths.cache
            while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
            return s
        }()
        let modelsCachePath = options.models?.file ?? "\(trimmedCacheDir)/models.json"
        let effectiveModelsOptions = CoreModel.ModelsDev.Options(
            url: options.models?.url,
            file: options.models?.file,
            fetch: allowLiveNetwork,
            snapshot: options.models?.snapshot
        )
        let appName = options.app?.name ?? "opencode"
        let appVersionForUA = options.app?.version ?? "2.3.2"
        let userAgent = "\(appName)/\(appVersionForUA)"
        let modelsDev = CoreModel.ModelsDev.Service(
            options: effectiveModelsOptions,
            http: httpTransport,
            fileSystem: fileSystem,
            kv: kv,
            bus: bus,
            cacheFilePath: modelsCachePath,
            userAgent: userAgent
        )
        let oauthManager = ServerLiveOAuthManager(
            credential: credential,
            httpTransport: httpTransport,
            kv: kv,
            bus: bus,
            environment: environment,
            userAgent: userAgent,
            workerdProfile: workerdProfile
        )

        // Weak indirection box avoids retain cycles between process-global session/automation
        // services and location-scoped tool environments while letting built-in tools receive
        // real `session`, `sessionMove`, and `automation` instances directly.
        let locationsBox = LateBoundLocationMap()

        // Process-global live SessionExecution wired to Location-scoped LiveSessionRunner.
        let coreSessionExecution = CoreSessionExecution.Service(
            db: db,
            store: sessionStore,
            bus: bus,
            inbox: sessionInbox,
            runnerForLocation: { session in
                guard let locations = locationsBox.value else {
                    throw CoreSessionErrors.NotFoundError(sessionID: session.id)
                }
                let locRef = LocationSchema.Ref(
                    directory: SchemaPrimitive.AbsolutePath(rawValue: session.location.directory),
                    workspaceID: session.location.workspaceID
                )
                let canonical = CoreLocation.ServiceMap.canonical(locRef)
                let out = try await locations.get(canonical)
                guard let bundle = ServerLocationBundle.from(out),
                      let runner = bundle.sessionRunner
                else {
                    throw CoreSessionErrors.NotFoundError(sessionID: session.id)
                }
                return runner
            }
        )
        let sessionExecution: any CoreSessionExecution.Interface = ServerLiveRuntime.LiveSessionExecution(
            inner: coreSessionExecution,
            store: sessionStore,
            locationsProvider: { locationsBox.value }
        )
        let sessionMove = CoreSessionMove.Service(
            db: db,
            bus: bus,
            store: sessionStore,
            inbox: sessionInbox,
            execution: sessionExecution,
            fileSystem: fileSystem
        )
        let sessionRestart = CoreSessionRestart.Service(
            db: db,
            store: sessionStore,
            execution: sessionExecution,
            bus: bus
        )
        let appVersion = options.app?.version ?? "unknown"
        let session = CoreSession.Service(
            db: db,
            bus: bus,
            store: sessionStore,
            inbox: sessionInbox,
            execution: sessionExecution,
            environment: sessionEnv,
            fileSystem: fileSystem,
            version: appVersion
        )

        let automation = try CoreAutomation.Service(
            database: db,
            isEnabled: { dir in
                guard let locations = locationsBox.value else { return false }
                let ref = LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: dir))
                guard let out = try? await locations.get(ref),
                      let bundle = ServerLocationBundle.from(out) else {
                    return false
                }
                return await bundle.flag.enabled(.automations)
            }
        )

        let locations = CoreLocation.ServiceMap.Service { ref, locScope in
            let dirPath = ref.directory.rawValue
            // Verify directory exists on the configured filesystem (unless root "/" or workerd).
            if !capturedWorkerd && dirPath != "/" {
                let exists = await capturedFs.exists(at: dirPath)
                if !exists {
                    throw CoreFilesystem.DirectoryNotFoundError(directory: ref.directory)
                }
                if let st = try? await capturedFs.stat(at: dirPath), st.type != .directory {
                    throw CoreFilesystem.DirectoryNotFoundError(directory: ref.directory)
                }
            }

            let resolvedProject: CoreProject.Project.Resolved
            if capturedWorkerd {
                resolvedProject = CoreProject.Project.Resolved(
                    id: ProjectID.global,
                    directory: ref.directory,
                    canonical: ref.directory,
                    vcs: nil
                )
            } else {
                resolvedProject = try await project.resolve(ref.directory, options: CoreProject.Project.ResolveOptions(persist: true))
            }

            let projectRef = LocationSchema.ProjectRef(
                id: resolvedProject.id,
                directory: resolvedProject.directory,
                canonical: resolvedProject.canonical
            )
            let locInfo = LocationSchema.Info(
                directory: ref.directory,
                workspaceID: ref.workspaceID,
                project: projectRef
            )
            let locationService = CoreLocation.Location.Service(info: locInfo, vcs: resolvedProject.vcs)
            let lifecycle = CoreLocation.Lifecycle.Service()

            let configOpts = CoreConfig.Options(
                project: capturedConfigOpts?.project,
                global: true,
                claude: capturedConfigOpts?.claude,
                file: capturedConfigOpts?.file,
                content: capturedConfigOpts?.content
            )
            let configUpdatedDef = EventSchema.EphemeralDefinition<JSONValue>(type: ConfigSchema.Event.updated.type)
            let configService = await CoreConfig.Service(
                directory: dirPath,
                options: configOpts,
                globalPaths: capturedGlobal,
                fileSystem: capturedFs,
                environment: capturedEnv,
                onUpdated: {
                    await bus.emit(configUpdatedDef, data: JSONValue.object([:]))
                }
            )
            let configEntries = await configService.entries()
            let flagService = CoreFlag.Service(
                config: configService,
                channel: capturedOptions.app?.channel ?? "local",
                overrides: CoreFlag.Overrides.fromEnvironment(capturedEnv)
            )
            let agentUpdatedDef = EventSchema.EphemeralDefinition<JSONValue>(type: AgentSchema.Event.updated.type)
            let agentService = CoreAgent.Agent.Service(onUpdated: {
                await bus.emit(agentUpdatedDef, data: JSONValue.object([:]))
            })
            let hooksService = CorePlugin.Hooks.Service()
            let pluginHostEnv = CorePlugin.Host.Environment(
                app: PluginContract.App(
                    name: capturedOptions.app?.name ?? "opencode",
                    version: capturedOptions.app?.version ?? "2.0.0",
                    channel: capturedOptions.app?.channel ?? "local"
                ),
                location: locInfo,
                hooks: hooksService,
                http: capturedHttp,
                environment: capturedEnv,
                fileSystem: capturedFs,
                flags: flagService
            )
            // The environment-bound initializer runs each plugin effect inside `Host.withRuntime`, so plugins
            // see this location's transport, environment, filesystem and flags (`Host.flagEnabled`).
            let rawPluginService = CorePlugin.Service(environment: pluginHostEnv)
            let pluginService = ServerTrackedPluginService(inner: rawPluginService)
            let commandUpdatedDef = EventSchema.EphemeralDefinition<JSONValue>(type: CommandSchema.Event.updated.type)
            let commandService = CoreSubsystems.Command.Service(onUpdated: {
                await bus.emit(commandUpdatedDef, data: JSONValue.object([:]))
            })
            let skillUpdatedDef = EventSchema.EphemeralDefinition<JSONValue>(type: SkillSchema.Event.updated.type)
            let skillService = CoreSkill.Service(onUpdated: {
                await bus.emit(skillUpdatedDef, data: JSONValue.object([:]))
            })
            let referenceUpdatedDef = EventSchema.EphemeralDefinition<JSONValue>(type: ReferenceSchema.Event.updated.type)
            let referenceService = CoreInstruction.Reference.Service(onUpdated: {
                await bus.emit(referenceUpdatedDef, data: JSONValue.object([:]))
            })

            let fsService: any CoreFilesystem.Interface
            let fsSearchService: any CoreFilesystem.Search.Interface
            let ptyService: any CorePty.Interface
            let vcsService: any CoreVcs.Vcs.Interface
            let snapshotService: any CoreSnapshot.Interface

            if capturedWorkerd {
                fsService = ServerWorkerdUnavailableFileSystem()
                fsSearchService = ServerWorkerdUnavailableFileSystemSearch()
                ptyService = ServerWorkerdUnavailablePty()
                vcsService = ServerWorkerdNoopVcs()
                snapshotService = CoreSnapshot.Service(directory: dirPath, fileSystem: capturedFs, enabled: false)
            } else {
                let search = CoreFilesystem.Search.Service(directory: dirPath, fileSystem: capturedFs)
                fsSearchService = search
                fsService = CoreFilesystem.Service(directory: dirPath, fileSystem: capturedFs, search: search)
                ptyService = CorePty.Service()
                let liveVcs = CoreVcs.Vcs.Service(
                    projectDirectory: resolvedProject.directory,
                    detectedVcsType: resolvedProject.vcs?.type.rawValue,
                    fileSystem: capturedFs
                )
                await ServerLiveRuntime.registerLiveGitVcs(
                    into: liveVcs,
                    directory: ref.directory,
                    projectDirectory: resolvedProject.directory,
                    fileSystem: capturedFs,
                    spawner: hostSpawner
                )
                vcsService = liveVcs
                snapshotService = CoreSnapshot.Service(directory: dirPath, fileSystem: capturedFs, enabled: true)
                await CoreConfigPlugin.Snapshot.apply(entries: configEntries, to: snapshotService)
            }

            let shellSelectService = CoreShell.Select.Service(
                options: CoreShell.Select.Options(gitbash: capturedOptions.windows?.gitbash),
                fileSystem: capturedFs,
                env: capturedEnv
            )
            let shellService = CoreShell.Service(
                directory: dirPath,
                projectID: resolvedProject.id,
                globalPaths: capturedGlobal,
                fileSystem: capturedFs,
                shellSelect: shellSelectService
            )
            let permissionAskedDef = EventSchema.EphemeralDefinition<PermissionSchema.Request>(type: PermissionSchema.Event.asked.type)
            let permissionRepliedDef = EventSchema.EphemeralDefinition<PermissionSchema.Event.RepliedPayload>(type: PermissionSchema.Event.replied.type)
            let permissionService = CorePermission.Service(
                projectID: resolvedProject.id,
                saved: permissionSaved,
                configuredRules: { _, agentID in
                    let agentInfo: AgentSchema.Info?
                    if let agentID {
                        agentInfo = await agentService.get(agentID)
                    } else {
                        agentInfo = await agentService.resolve(nil)
                    }
                    let entries = await configService.entries()
                    return ServerLiveRuntime.effectivePermissionRuleset(agent: agentInfo, configEntries: entries)
                },
                onAsked: { req in
                    await bus.emit(permissionAskedDef, data: req)
                },
                onReplied: { payload in
                    await bus.emit(permissionRepliedDef, data: payload)
                }
            )
            let formService = CoreIntegration.Form.Service()
            let integrationService = CoreIntegration.Integration.Service(
                credentials: credential,
                environment: capturedEnv
            )
            let providerService = CoreProvider.Provider.Service(integrations: integrationService)
            let modelService = CoreModel.Model.Service(providers: providerService)
            let modelResolver = CoreModel.Resolver.Service(
                providers: providerService,
                models: modelService,
                integrations: integrationService
            )
            let mcpService = CoreMCP.Registry.Service(
                directory: dirPath,
                http: capturedHttp
            )
            let rpcService = CoreIntegration.Rpc.Service()
            let webSearchService = CoreIntegration.WebSearch.Service(kv: kv)
            let usageLimitsService = CoreProvider.UsageLimits.Service(
                integrations: integrationService,
                http: capturedHttp
            )
            let generateService = CoreIntegration.Generate.Service(resolver: modelResolver)
            let voiceService = CoreIntegration.Voice.Service(integrations: integrationService)
            let artifactService = CoreArtifact.Service(
                directory: dirPath,
                projectID: resolvedProject.id,
                globalPaths: capturedGlobal,
                fileSystem: capturedFs,
                flags: flagService,
                kv: CoreArtifact.InMemoryKVStore()
            )
            let wtPrefix = String(resolvedProject.id.rawValue.prefix(6))
            let wtRoot = SchemaPrimitive.AbsolutePath(rawValue: "\(capturedGlobal.data)/worktree/\(wtPrefix)")
            let worktreeStrategies = CoreWorktree.Strategies.Service(
                locationDirectory: ref.directory,
                defaultWorktreeRoot: wtRoot,
                gitStrategy: CoreWorktree.GitStrategy.make(fileSystem: capturedFs, git: gitService)
            )

            // Seed built-in agents, commands, skills, providers/models (with ModelsDev cache),
            // configured MCP servers, and built-in tools.
            let defaultAgentsReg = try await ServerLiveRuntime.seedDefaultAgents(
                into: agentService,
                configEntries: configEntries,
                globalPaths: capturedGlobal
            )
            _ = try await ServerLiveRuntime.seedCommands(
                into: commandService,
                directory: dirPath,
                projectDirectory: resolvedProject.directory.rawValue,
                globalPaths: capturedGlobal,
                configEntries: configEntries,
                fileSystem: capturedFs,
                sessionProvider: { session },
                agentService: agentService
            )
            _ = try await ServerLiveRuntime.seedSkills(
                into: skillService,
                directory: dirPath,
                projectDirectory: resolvedProject.directory.rawValue,
                globalPaths: capturedGlobal,
                configEntries: configEntries,
                fileSystem: capturedFs
            )
            let defaultProviderRegs = try await ServerLiveRuntime.seedProvidersAndModels(
                integrations: integrationService,
                providers: providerService,
                models: modelService,
                configEntries: configEntries,
                globalPaths: capturedGlobal,
                fileSystem: capturedFs,
                configService: configService,
                skillService: skillService,
                credentialService: credential,
                modelsDev: modelsDev,
                kv: kv,
                httpTransport: capturedHttp,
                environment: capturedEnv,
                oauthManager: oauthManager,
                modelsDevOptions: effectiveModelsOptions,
                allowLiveNetwork: allowLiveNetwork,
                syncFetchOnColdCache: explicitSyncFetch,
                forceRefresh: false,
                userAgent: userAgent
            )
            let emptyEventPayload = JSONValue.object([:])
            await bus.emit(EventSchema.EphemeralDefinition<JSONValue>(type: IntegrationSchema.Event.updated.type), data: emptyEventPayload)
            await bus.emit(EventSchema.EphemeralDefinition<JSONValue>(type: ProviderSchema.Event.updated.type), data: emptyEventPayload)
            await bus.emit(EventSchema.EphemeralDefinition<JSONValue>(type: ModelSchema.Event.updated.type), data: emptyEventPayload)
            let latestConfigEntries = await configService.entries()
            await ServerLiveRuntime.seedConfiguredMcpServers(
                into: mcpService,
                configEntries: latestConfigEntries
            )

            // Code Mode's `execute` tool, with its fetch/file globals gated by this location's permission service.
            let codeModePermission = CoreCodemode.PermissionHook.service(permissionService)
            let toolService = CoreTool.Service(codeMode: CoreTool.CodeModeHost(
                transport: capturedHttp,
                permission: codeModePermission,
                flags: flagService
            ))
            let codeModeServices = CoreCodemode.Tool.services(
                location: OpenCodeLocation(directory: dirPath, workspaceID: locInfo.workspaceID),
                fileSystem: capturedFs,
                permission: codeModePermission
            )
            let toolEnv = CoreTool.BuiltinEnvironment(
                directory: dirPath,
                fileSystem: capturedFs,
                permission: permissionService,
                shell: shellService,
                shellSelect: shellSelectService,
                httpTransport: capturedHttp,
                artifact: artifactService,
                flags: flagService,
                globalPaths: capturedGlobal,
                projectID: resolvedProject.id,
                webSearch: webSearchService,
                form: formService,
                session: session,
                sessionMove: sessionMove,
                sessionStore: sessionStore,
                skill: skillService,
                automation: automation,
                mcp: mcpService,
                worktree: worktree,
                worktreeStrategies: worktreeStrategies,
                model: modelService,
                provider: providerService,
                agent: agentService,
                generate: generateService
            )
            _ = await CoreTool.registerAllBuiltins(into: toolService, environment: toolEnv)

            let closedFlag = Mutex(false)
            let sessionRunner = ServerLiveRuntime.makeSessionRunner(
                db: db,
                bus: bus,
                sessionStore: sessionStore,
                sessionInstructions: sessionInstructions,
                agentService: agentService,
                configService: configService,
                integrationService: integrationService,
                providerService: providerService,
                modelService: modelService,
                toolService: toolService,
                httpTransport: capturedHttp,
                environment: capturedEnv,
                snapshotService: capturedWorkerd ? nil : snapshotService,
                oauthManager: oauthManager,
                webSearch: webSearchService,
                flags: flagService,
                codeModeServices: codeModeServices,
                isLocationClosed: { closedFlag.withLock { $0 } }
            )

            locScope.addFinalizer {
                closedFlag.withLock { $0 = true }
                await sessionRunner.modelTransport.closeAll()
                await permissionService.close()
                await formService.close()
                await rpcService.close()
                await pluginService.close()
            }

            let bundle = ServerLocationBundle(
                ref: ref,
                location: locationService,
                lifecycle: lifecycle,
                config: configService,
                flag: flagService,
                agent: agentService,
                plugin: pluginService,
                hooks: hooksService,
                command: commandService,
                skill: skillService,
                reference: referenceService,
                fileSystem: fsService,
                fileSystemSearch: fsSearchService,
                shell: shellService,
                shellSelect: shellSelectService,
                pty: ptyService,
                permission: permissionService,
                form: formService,
                vcs: vcsService,
                provider: providerService,
                model: modelService,
                integration: integrationService,
                mcp: mcpService,
                rpc: rpcService,
                webSearch: webSearchService,
                usageLimits: usageLimitsService,
                generate: generateService,
                voice: voiceService,
                artifact: artifactService,
                snapshot: snapshotService,
                worktreeStrategies: worktreeStrategies,
                tool: toolService,
                sessionRunner: sessionRunner,
                sessionTitle: sessionRunner.sessionTitle
            )
            if let onLocationBoot {
                await onLocationBoot(bundle)
                if pluginService.didReplaceWithCustomBackgroundPlugins {
                    await defaultAgentsReg.dispose()
                    await defaultProviderRegs.dispose()
                    await agentService.reload()
                    await integrationService.reload()
                    await providerService.reload()
                    await modelService.reload()
                }
            }
            return bundle.layerOutput
        }
        locationsBox.bind(locations)

        oauthManager.setOnCredentialActivated { _ in
            guard let activeLocations = locationsBox.value, !activeLocations.keys().isEmpty else { return }
            try? await CoreLocation.ServiceMap.reload(activeLocations)
        }

        let instance = CoreLocation.Instance.Service(locations: locations)

        let runtime = ServerAppRuntime(
            options: options,
            authConfig: authConfig,
            global: globalPaths,
            fileSystem: fileSystem,
            httpTransport: httpTransport,
            databaseService: dbService,
            bus: bus,
            kv: kv,
            sessionStore: sessionStore,
            sessionInbox: sessionInbox,
            sessionExecution: sessionExecution,
            sessionEnvironment: sessionEnv,
            session: session,
            sessionTransfer: sessionTransfer,
            sessionInstructions: sessionInstructions,
            sessionMove: sessionMove,
            sessionRestart: sessionRestart,
            project: project,
            worktree: worktree,
            credential: credential,
            permissionSaved: permissionSaved,
            blobStore: blobStore,
            videoGeneration: videoGeneration,
            automation: automation,
            job: job,
            ptyTicket: ptyTicket,
            persistentPty: persistentPty,
            fileWatch: fileWatch,
            pluginUpdate: pluginUpdate,
            wellKnown: wellKnown,
            pairing: pairing,
            eventFeed: eventFeed,
            locations: locations,
            locationActivity: locationActivity,
            instance: instance,
            serverInfo: serverInfo,
            modelsDev: modelsDev,
            oauthManager: oauthManager,
            allowLiveNetwork: allowLiveNetwork,
            modelsDevOptions: effectiveModelsOptions,
            defaultDirectory: resolvedDefaultDir,
            scope: scope
        )
        return runtime
    }
}

/// Default no-op plugin update service used when no npm/package updater is injected.
public final class ServerNoopPluginUpdateService: CorePlugin.Update.Interface, Sendable {
    public init() {}

    public func check(_ target: String, refresh: Bool) async -> Bool {
        _ = (target, refresh)
        return false
    }

    public func update(_ target: String) async throws {
        _ = target
    }

    /// No checks run, so no check interval ever starts.
    public func intervals() async -> AsyncStream<Int> {
        AsyncStream { _ in }
    }
}

public final class ServerUnsupportedBlobStore: CoreBlobStore.Interface, Sendable {
    public init() {}

    public func write(_ chunks: [[UInt8]]) async throws -> CoreBlobStore.Info {
        _ = chunks
        throw CoreBlobStore.UnavailableError(message: "Blob storage is unavailable on this runtime")
    }

    public func read(_ id: CoreBlobStore.ID) async throws -> CoreBlobStore.Content {
        throw CoreBlobStore.NotFoundError(id: id.rawValue)
    }

    public func remove(_ id: CoreBlobStore.ID) async {
        _ = id
    }
}

public final class ServerUnsupportedVideoGeneration: CoreIntegration.VideoGeneration.Interface, Sendable {
    public init() {}

    public func start(
        _ input: CoreIntegration.Generate.VideoInput,
        options: CoreIntegration.VideoGeneration.StartOptions?
    ) async throws -> GenerateSchema.VideoRunning {
        _ = (input, options)
        throw CoreIntegration.Generate.UnavailableError(message: "Video generation is unavailable on this runtime", service: "video")
    }

    public func get(_ id: GenerateSchema.VideoID) async throws -> GenerateSchema.VideoJob {
        throw CoreIntegration.VideoGeneration.NotFoundError(id: id.rawValue)
    }

    public func wait(_ id: GenerateSchema.VideoID) async throws -> GenerateSchema.VideoJob {
        throw CoreIntegration.VideoGeneration.NotFoundError(id: id.rawValue)
    }

    public func cancel(_ id: GenerateSchema.VideoID) async throws {
        throw CoreIntegration.VideoGeneration.NotFoundError(id: id.rawValue)
    }
}

/// Weak indirection container breaking potential ARC retain cycles between process-global
/// session/automation services and the location service map that constructs built-in tools.
private final class LateBoundLocationMap: Sendable {
    private struct WeakHolder: @unchecked Sendable {
        weak var locations: CoreLocation.ServiceMap.Service?
    }

    private let holder = Mutex(WeakHolder())

    var value: CoreLocation.ServiceMap.Service? {
        holder.withLock { $0.locations }
    }

    func bind(_ locations: CoreLocation.ServiceMap.Service) {
        holder.withLock { $0.locations = locations }
    }
}

/// Pure-Swift path resolver matching `path.resolve(base, relative)` for POSIX paths.
internal func serverResolvePath(base: String, relative: String) -> String {
    let cleanRel = relative.replacing("\\", with: "/")
    let combined: String
    if cleanRel.hasPrefix("/") {
        combined = cleanRel
    } else {
        let cleanBase = base.replacing("\\", with: "/")
        let trimmedBase = cleanBase.hasSuffix("/") ? String(cleanBase.dropLast()) : cleanBase
        combined = "\(trimmedBase)/\(cleanRel)"
    }
    var parts: [String] = []
    for seg in combined.split(separator: "/") {
        if seg.isEmpty || seg == "." { continue }
        if seg == ".." {
            if !parts.isEmpty { parts.removeLast() }
        } else {
            parts.append(String(seg))
        }
    }
    return "/" + parts.joined(separator: "/")
}
