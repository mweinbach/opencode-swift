/// Naming rules, route validation, SNI resolution, and target parsing matching `@opentunnel/protocol/names`.
public enum OpenTunnelNames {
    /// The route name for the tunnel hostname itself (`@`).
    public static let rootRoute = "@"

    /// Whether `value` is a valid lowercase DNS label (`^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$`).
    public static func isValidLabel(_ value: String) -> Bool {
        let utf8 = Array(value.utf8)
        guard !utf8.isEmpty, utf8.count <= 63 else { return false }
        guard isLowerAlphaNum(utf8.first!), isLowerAlphaNum(utf8.last!) else { return false }
        for byte in utf8 {
            if !(isLowerAlphaNum(byte) || byte == 0x2D) { // '-'
                return false
            }
        }
        return true
    }

    /// Whether `value` is a valid route name: `@` or one lowercase DNS label.
    public static func isValidRouteName(_ value: String) -> Bool {
        value == rootRoute || isValidLabel(value)
    }

    /// Whether `value` is a valid profile name: one lowercase DNS label.
    public static func isValidProfileName(_ value: String) -> Bool {
        isValidLabel(value)
    }

    /// The public hostname of a route: `<route>.<hostname>`, or `<hostname>` for `@`.
    public static func publicHostname(route: String, hostname: String) -> String {
        route == rootRoute ? hostname : "\(route).\(hostname)"
    }

    /// The public HTTPS URL of a route on a tunnel hostname.
    public static func publicURL(route: String, hostname: String) -> String {
        "https://\(publicHostname(route: route, hostname: hostname))"
    }

    /// The public HTTPS URL of each route on a tunnel hostname.
    public static func publicURLs(routes: [String: OpenTunnelRoute], hostname: String) -> [String: String] {
        var result: [String: String] = [:]
        result.reserveCapacity(routes.count)
        for name in routes.keys {
            result[name] = publicURL(route: name, hostname: hostname)
        }
        return result
    }

    /// Resolves the route name for a TLS SNI on the given tunnel hostname.
    /// Deeper multi-label subdomains never match (matching `@opentunnel/protocol/names.routeForSni`).
    public static func routeForSNI(_ sni: String, hostname: String) -> String? {
        let name = sni.lowercased()
        let host = hostname.lowercased()
        if name == host { return rootRoute }
        let suffix = ".\(host)"
        guard name.hasSuffix(suffix) else { return nil }
        let route = String(name.dropLast(suffix.count))
        return isValidLabel(route) ? route : nil
    }

    private static func isLowerAlphaNum(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x7A)
    }
}

/// Parsed local forwarding target (`host:port`, `[ipv6]:port`, or `http(s)://host:port`).
public struct OpenTunnelTarget: Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let host: String
    public let port: Int
    public let scheme: String

    public init(host: String, port: Int, scheme: String = "http") {
        self.host = host
        self.port = port
        self.scheme = scheme
    }

    public var hostPort: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    public var urlString: String {
        "\(scheme)://\(hostPort)"
    }

    public var description: String { hostPort }

    /// Parses `host:port`, `[ipv6]:port`, `http://host:port`, or `https://host:port`.
    public static func parse(_ rawValue: String) -> OpenTunnelTarget? {
        var value = rawValue.trimmingASCIIWhitespace()
        var scheme = "http"

        if let range = value.range(of: "://") {
            let parsedScheme = value[..<range.lowerBound].lowercased()
            guard parsedScheme == "http" || parsedScheme == "https" else {
                return nil
            }
            scheme = parsedScheme
            value = String(value[range.upperBound...])
            // Strip optional trailing slash only; paths are not supported in route targets.
            if value.hasSuffix("/") {
                value.removeLast()
            }
            if value.contains("/") || value.contains("?") || value.contains("#") {
                return nil
            }
        }

        guard let separator = value.lastIndex(of: ":") else { return nil }
        let portText = String(value[value.index(after: separator)...])
        guard !portText.isEmpty, portText.count <= 5,
              portText.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              let port = Int(portText),
              port >= 1 && port <= 65_535
        else { return nil }

        var host = String(value[..<separator])
        if host.hasPrefix("[") {
            guard host.hasSuffix("]") else { return nil }
            host = String(host.dropFirst().dropLast())
        }
        guard !host.isEmpty else { return nil }
        let validHost = host.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39)
                || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2E // '.'
                || byte == 0x2D // '-'
                || byte == 0x3A // ':'
                || byte == 0x5F // '_'
        }
        guard validHost else { return nil }
        return OpenTunnelTarget(host: host, port: port, scheme: scheme)
    }
}

/// PROXY protocol header version that a route can prepend before forwarding traffic to its target.
public enum OpenTunnelProxyProtocol: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case v1
    case v2
}

/// A route specification: `target` (`host:port` or `http://127.0.0.1:<port>`) plus optional PROXY protocol.
public struct OpenTunnelRoute: Equatable, Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    public let target: String
    public let proxyProtocol: OpenTunnelProxyProtocol?

    public init(target: String, proxyProtocol: OpenTunnelProxyProtocol? = nil) {
        self.target = target
        self.proxyProtocol = proxyProtocol
    }

    public init(stringLiteral value: String) {
        self.target = value
        self.proxyProtocol = nil
    }
}

/// A validated route with its parsed target and optional PROXY protocol version.
public struct OpenTunnelResolvedRoute: Equatable, Hashable, Sendable {
    public let target: OpenTunnelTarget
    public let proxyProtocol: OpenTunnelProxyProtocol?

    public init(target: OpenTunnelTarget, proxyProtocol: OpenTunnelProxyProtocol? = nil) {
        self.target = target
        self.proxyProtocol = proxyProtocol
    }
}

/// Route validation helpers matching `@opentunnel/client`'s `validateRoutes` / `resolveRoute`.
public enum OpenTunnelRouteValidation {
    public static func resolveRoute(
        name: String,
        route: OpenTunnelRoute
    ) throws(OpenTunnelClientError) -> OpenTunnelResolvedRoute {
        guard OpenTunnelNames.isValidRouteName(name) else {
            throw OpenTunnelClientError(message: "Invalid route name '\(name)'")
        }
        guard let target = OpenTunnelTarget.parse(route.target) else {
            throw OpenTunnelClientError(message: "Invalid target '\(route.target)' for route '\(name)': use host:port")
        }
        return OpenTunnelResolvedRoute(target: target, proxyProtocol: route.proxyProtocol)
    }

    @discardableResult
    public static func validateRoutes(
        _ routes: [String: OpenTunnelRoute]
    ) throws(OpenTunnelClientError) -> [String: OpenTunnelResolvedRoute] {
        var resolved: [String: OpenTunnelResolvedRoute] = [:]
        resolved.reserveCapacity(routes.count)
        for (name, route) in routes {
            resolved[name] = try resolveRoute(name: name, route: route)
        }
        return resolved
    }

    @discardableResult
    public static func validateRoutes(
        _ routes: [String: String]
    ) throws(OpenTunnelClientError) -> [String: OpenTunnelResolvedRoute] {
        let mapped = routes.mapValues { OpenTunnelRoute(target: $0) }
        return try validateRoutes(mapped)
    }
}

// MARK: - PROXY Protocol v1 / v2 Header Encoder (`@opentunnel/protocol/proxy-protocol.ts`)

/// Encodes HAProxy PROXY protocol v1 and v2 headers from OpenTunnel `open` frame metadata.
public enum OpenTunnelProxyProtocolHeader {
    public static let publicPort: UInt16 = 443
    public static let v2Signature: [UInt8] = [
        0x0D, 0x0A, 0x0D, 0x0A, 0x00, 0x0D, 0x0A, 0x51, 0x55, 0x49, 0x54, 0x0A,
    ]

    public struct ParsedPeer: Equatable, Hashable, Sendable {
        public let isIPv6: Bool
        public let bytes: [UInt8]
        public let port: UInt16

        public init(isIPv6: Bool, bytes: [UInt8], port: UInt16) {
            self.isIPv6 = isIPv6
            self.bytes = bytes
            self.port = port
        }
    }

    /// Parses `ipv4:port`, `[ipv6]:port`, or a bare IPv4/IPv6 address (port 0).
    /// IPv4-mapped IPv6 addresses (`::ffff:a.b.c.d`) are normalized to IPv4.
    public static func parsePeer(_ peer: String) -> ParsedPeer? {
        if let v4 = parseIPv4(peer) {
            return normalize(bytes: v4, port: 0)
        }
        if let v6 = parseIPv6(peer) {
            return normalize(bytes: v6, port: 0)
        }
        if peer.hasPrefix("["), let close = peer.range(of: "]:") {
            let ipPart = String(peer[peer.index(after: peer.startIndex)..<close.lowerBound])
            let portPart = String(peer[close.upperBound...])
            guard let v6 = parseIPv6(ipPart), let port = parsePort(portPart) else { return nil }
            return normalize(bytes: v6, port: port)
        }
        guard let sep = peer.lastIndex(of: ":") else { return nil }
        let ipPart = String(peer[..<sep])
        let portPart = String(peer[peer.index(after: sep)...])
        guard let v4 = parseIPv4(ipPart), let port = parsePort(portPart) else { return nil }
        return normalize(bytes: v4, port: port)
    }

    /// Formats a parsed peer IP in canonical text form (RFC 5952 for IPv6).
    public static func formatAddress(_ peer: ParsedPeer) -> String {
        if !peer.isIPv6 {
            return peer.bytes.map(String.init).joined(separator: ".")
        }
        var groups: [UInt16] = []
        groups.reserveCapacity(8)
        for i in 0..<8 {
            groups.append((UInt16(peer.bytes[i * 2]) << 8) | UInt16(peer.bytes[i * 2 + 1]))
        }
        var bestStart = -1
        var bestLength = 1
        var idx = 0
        while idx < 8 {
            if groups[idx] != 0 {
                idx += 1
                continue
            }
            var end = idx
            while end < 8 && groups[end] == 0 { end += 1 }
            if end - idx > bestLength {
                bestStart = idx
                bestLength = end - idx
            }
            idx = end
        }
        func hex(_ slice: ArraySlice<UInt16>) -> String {
            slice.map { String($0, radix: 16) }.joined(separator: ":")
        }
        if bestStart == -1 {
            return hex(groups[...])
        }
        return "\(hex(groups[..<bestStart]))::\(hex(groups[(bestStart + bestLength)...]))"
    }

    /// Encodes a PROXY protocol v1 or v2 header for the given `peer` and `sni`.
    public static func encode(version: OpenTunnelProxyProtocol, peer: String, sni: String) -> [UInt8] {
        let parsed = parsePeer(peer)
        switch version {
        case .v1:
            return encodeV1(source: parsed)
        case .v2:
            return encodeV2(source: parsed, sni: sni)
        }
    }

    private static func encodeV1(source: ParsedPeer?) -> [UInt8] {
        guard let source else {
            return Array("PROXY UNKNOWN\r\n".utf8)
        }
        let proto = source.isIPv6 ? "TCP6" : "TCP4"
        let dst = source.isIPv6 ? "::" : "0.0.0.0"
        return Array("PROXY \(proto) \(formatAddress(source)) \(dst) \(source.port) \(publicPort)\r\n".utf8)
    }

    private static func encodeV2(source: ParsedPeer?, sni: String) -> [UInt8] {
        let authority = Array(sni.utf8)
        let includeTLV = !authority.isEmpty && authority.count <= 255
        let tlvLen = includeTLV ? (3 + authority.count) : 0
        let addrLen = source == nil ? 0 : (source!.isIPv6 ? 36 : 12)
        let payloadLen = UInt16(addrLen + tlvLen)

        var out: [UInt8] = []
        out.reserveCapacity(16 + Int(payloadLen))
        out.append(contentsOf: v2Signature)
        out.append(source != nil ? 0x21 : 0x20) // V2_PROXY vs V2_LOCAL
        if let source {
            out.append(source.isIPv6 ? 0x21 : 0x11) // V2_TCP6 vs V2_TCP4
        } else {
            out.append(0x00) // V2_UNSPEC
        }
        out.append(UInt8((payloadLen >> 8) & 0xFF))
        out.append(UInt8(payloadLen & 0xFF))

        if let source {
            out.append(contentsOf: source.bytes)
            out.append(contentsOf: repeatElement(UInt8(0), count: source.bytes.count)) // destination unspecified
            out.append(UInt8((source.port >> 8) & 0xFF))
            out.append(UInt8(source.port & 0xFF))
            out.append(UInt8((publicPort >> 8) & 0xFF))
            out.append(UInt8(publicPort & 0xFF))
        }
        if includeTLV {
            out.append(0x02) // PP2_TYPE_AUTHORITY
            out.append(UInt8((authority.count >> 8) & 0xFF))
            out.append(UInt8(authority.count & 0xFF))
            out.append(contentsOf: authority)
        }
        return out
    }

    private static func normalize(bytes: [UInt8], port: UInt16) -> ParsedPeer {
        if bytes.count == 16,
           bytes[0..<10].allSatisfy({ $0 == 0 }),
           bytes[10] == 0xFF, bytes[11] == 0xFF
        {
            return ParsedPeer(isIPv6: false, bytes: Array(bytes[12..<16]), port: port)
        }
        return ParsedPeer(isIPv6: bytes.count == 16, bytes: bytes, port: port)
    }

    private static func parsePort(_ text: String) -> UInt16? {
        guard !text.isEmpty, text.count <= 5,
              text.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              let port = UInt16(text)
        else { return nil }
        return port
    }

    internal static func parseIPv4(_ value: String) -> [UInt8]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(4)
        for part in parts {
            guard !part.isEmpty, part.count <= 3 else { return nil }
            if part.count > 1 && part.hasPrefix("0") { return nil }
            guard part.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                  let octet = UInt8(part)
            else { return nil }
            bytes.append(octet)
        }
        return bytes
    }

    internal static func parseIPv6(_ value: String) -> [UInt8]? {
        let groups: [UInt16]
        if let gapRange = value.range(of: "::") {
            let afterGap = value[gapRange.upperBound...]
            if afterGap.contains("::") { return nil }
            let headText = String(value[..<gapRange.lowerBound])
            let tailText = String(afterGap)
            guard let head = parseIPv6Groups(headText, allowIPv4: false),
                  let tail = parseIPv6Groups(tailText, allowIPv4: true),
                  head.count + tail.count <= 7
            else { return nil }
            groups = head + Array(repeating: 0, count: 8 - head.count - tail.count) + tail
        } else {
            guard let parsed = parseIPv6Groups(value, allowIPv4: true), parsed.count == 8 else { return nil }
            groups = parsed
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(16)
        for g in groups {
            bytes.append(UInt8((g >> 8) & 0xFF))
            bytes.append(UInt8(g & 0xFF))
        }
        return bytes
    }

    private static func parseIPv6Groups(_ text: String, allowIPv4: Bool) -> [UInt16]? {
        if text.isEmpty { return [] }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        var groups: [UInt16] = []
        for (idx, part) in parts.enumerated() {
            if allowIPv4 && idx == parts.count - 1 && part.contains(".") {
                guard let v4 = parseIPv4(String(part)) else { return nil }
                groups.append((UInt16(v4[0]) << 8) | UInt16(v4[1]))
                groups.append((UInt16(v4[2]) << 8) | UInt16(v4[3]))
                continue
            }
            guard !part.isEmpty, part.count <= 4,
                  part.utf8.allSatisfy(isHexDigit),
                  let val = UInt16(part, radix: 16)
            else { return nil }
            groups.append(val)
        }
        return groups
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39)
            || (byte >= 0x41 && byte <= 0x46)
            || (byte >= 0x61 && byte <= 0x66)
    }
}
