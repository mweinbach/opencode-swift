import Foundation

/// Validated HTTP/HTTPS proxy configuration parsed from an explicit option or environment variables.
public struct OpenTunnelProxyConfig: Equatable, Hashable, Sendable {
    public let scheme: String
    public let host: String
    public let port: Int
    public let username: String?
    public let password: String?
    public let urlString: String

    public init(
        scheme: String,
        host: String,
        port: Int,
        username: String? = nil,
        password: String? = nil,
        urlString: String
    ) {
        self.scheme = scheme
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.urlString = urlString
    }

    /// Basic `Proxy-Authorization` header value when credentials are present.
    public var basicAuthorizationHeader: String? {
        guard username != nil || password != nil else { return nil }
        let raw = "\(username ?? ""):\(password ?? "")"
        let encoded = Data(raw.utf8).base64EncodedString()
        return "Basic \(encoded)"
    }
}

/// HTTP/HTTPS proxy resolver and `NO_PROXY` matcher matching `@opentunnel/client/src/effect/proxy.ts`.
public enum OpenTunnelProxyResolver {
    private static let supportedSchemes: Set<String> = ["http", "https"]

    /// Parses a proxy URL, defaulting scheme-less values to `http://` like curl.
    /// Error messages intentionally never echo the raw URL because it may carry credentials.
    public static func parseProxy(
        _ value: String,
        source: String
    ) throws(OpenTunnelClientError) -> OpenTunnelProxyConfig {
        let trimmed = value.trimmingASCIIWhitespace()
        guard !trimmed.isEmpty else {
            throw OpenTunnelClientError.invalidProxyURL(source: source)
        }

        let candidate: String
        if hasExplicitScheme(trimmed) {
            candidate = trimmed
        } else {
            candidate = "http://\(trimmed)"
        }

        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              !scheme.isEmpty
        else {
            throw OpenTunnelClientError.invalidProxyURL(source: source)
        }

        guard supportedSchemes.contains(scheme) else {
            throw OpenTunnelClientError.unsupportedProxyScheme(scheme, source: source)
        }

        guard let host = components.host, !host.isEmpty else {
            throw OpenTunnelClientError.invalidProxyURL(source: source)
        }

        if let rawPort = components.port, rawPort < 1 || rawPort > 65_535 {
            throw OpenTunnelClientError.invalidProxyURL(source: source)
        }

        let port = components.port ?? (scheme == "https" ? 443 : 80)
        return OpenTunnelProxyConfig(
            scheme: scheme,
            host: host,
            port: port,
            username: components.user,
            password: components.password,
            urlString: components.string ?? candidate
        )
    }

    /// Whether `NO_PROXY` exempts the destination `(host, port, isSecure)`.
    /// Supports `*`, domains (with optional leading `.` or `*.`), IPv4/IPv6 addresses,
    /// CIDR subnets, and optional `:port`.
    public static func bypassesProxy(host rawHost: String, port: Int, noProxy: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }

        let tokens = noProxy.lowercased().split { ch in
            ch == "," || ch == " " || ch == "\t" || ch == "\n" || ch == "\r"
        }
        for rawToken in tokens {
            let raw = String(rawToken)
            if raw.isEmpty { continue }
            if raw == "*" { return true }

            var entry = raw
            var entryPort: Int? = nil

            if raw.hasPrefix("["), let closeBracket = raw.firstIndex(of: "]") {
                entry = String(raw[raw.index(after: raw.startIndex)..<closeBracket])
                let after = String(raw[raw.index(after: closeBracket)...])
                if after.hasPrefix("/") {
                    // Bracketed IPv6 CIDR such as `[2001:db8::]/32` or `[2001:db8::]/32:443`
                    if let colon = after.firstIndex(of: ":") {
                        let cidrPart = String(after[..<colon])
                        let portDigits = String(after[after.index(after: colon)...])
                        if let parsed = Int(portDigits), portDigits.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) {
                            entry += cidrPart
                            entryPort = parsed
                        } else {
                            continue
                        }
                    } else {
                        entry += after
                    }
                } else if after.hasPrefix(":") {
                    let portDigits = String(after.dropFirst())
                    if let parsed = Int(portDigits), portDigits.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) {
                        entryPort = parsed
                    } else {
                        continue
                    }
                } else if !after.isEmpty {
                    continue
                }
            } else {
                let colonParts = raw.split(separator: ":", omittingEmptySubsequences: false)
                if colonParts.count == 2 {
                    let portDigits = String(colonParts[1])
                    if !portDigits.isEmpty,
                       portDigits.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                       let parsed = Int(portDigits)
                    {
                        entry = String(colonParts[0])
                        entryPort = parsed
                    }
                }
            }

            if let entryPort, entryPort != port {
                continue
            }

            if matchesIPOrCIDR(entry: entry, host: host) {
                return true
            }

            var domain = entry
            if domain.hasPrefix("*.") {
                domain = String(domain.dropFirst(2))
            } else if domain.hasPrefix(".") {
                domain = String(domain.dropFirst())
            }
            if !domain.isEmpty && (host == domain || host.hasSuffix(".\(domain)")) {
                return true
            }
        }
        return false
    }

    /// Resolves the proxy for `urlString`, checking explicit `proxy` first, then environment variables
    /// (`HTTPS_PROXY`/`https_proxy`/`ALL_PROXY`/`all_proxy` for `https:`/`wss:`, or
    /// `HTTP_PROXY`/`http_proxy`/`ALL_PROXY`/`all_proxy` for `http:`/`ws:`) with `NO_PROXY` bypass.
    public static func resolveProxy(
        for urlString: String,
        explicitProxy: String? = nil,
        environment: [String: String] = [:]
    ) throws(OpenTunnelClientError) -> OpenTunnelProxyConfig? {
        if let explicitProxy {
            return try parseProxy(explicitProxy, source: "The proxy option")
        }

        guard let components = URLComponents(string: urlString),
              let scheme = components.scheme?.lowercased(),
              let host = components.host
        else {
            return nil
        }

        let isSecure = scheme == "https" || scheme == "wss"
        let port = components.port ?? (isSecure ? 443 : 80)

        let candidateNames = isSecure
            ? ["HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy"]
            : ["HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"]

        var selectedName: String? = nil
        var selectedValue: String? = nil
        for name in candidateNames {
            if let value = environment[name]?.trimmingASCIIWhitespace(), !value.isEmpty {
                selectedName = name
                selectedValue = value
                break
            }
        }

        guard let name = selectedName, let value = selectedValue else {
            return nil
        }

        let noProxy = environment["NO_PROXY"] ?? environment["no_proxy"] ?? ""
        if !noProxy.isEmpty && bypassesProxy(host: host, port: port, noProxy: noProxy) {
            return nil
        }

        return try parseProxy(value, source: name)
    }

    private static func hasExplicitScheme(_ text: String) -> Bool {
        guard let range = text.range(of: "://") else { return false }
        let scheme = text[..<range.lowerBound]
        guard let first = scheme.utf8.first,
              (first >= 0x41 && first <= 0x5A) || (first >= 0x61 && first <= 0x7A)
        else { return false }
        return scheme.utf8.allSatisfy { b in
            (b >= 0x41 && b <= 0x5A)
                || (b >= 0x61 && b <= 0x7A)
                || (b >= 0x30 && b <= 0x39)
                || b == 0x2B || b == 0x2D || b == 0x2E
        }
    }

    private static func matchesIPOrCIDR(entry: String, host: String) -> Bool {
        let parts = entry.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let address = String(parts[0])
        let bitsText: String? = parts.count == 2 ? String(parts[1]) : nil

        if let entryBytes = OpenTunnelProxyProtocolHeader.parseIPv4(address),
           let hostBytes = OpenTunnelProxyProtocolHeader.parseIPv4(host)
        {
            let prefixLen: Int
            if let bitsText {
                guard !bitsText.isEmpty,
                      bitsText.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                      let parsed = Int(bitsText), parsed >= 0, parsed <= 32
                else { return false }
                prefixLen = parsed
            } else {
                prefixLen = 32
            }
            return matchesPrefix(entryBytes, hostBytes, bits: prefixLen)
        }

        if let entryBytes = OpenTunnelProxyProtocolHeader.parseIPv6(address),
           let hostBytes = OpenTunnelProxyProtocolHeader.parseIPv6(host)
        {
            let prefixLen: Int
            if let bitsText {
                guard !bitsText.isEmpty,
                      bitsText.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                      let parsed = Int(bitsText), parsed >= 0, parsed <= 128
                else { return false }
                prefixLen = parsed
            } else {
                prefixLen = 128
            }
            return matchesPrefix(entryBytes, hostBytes, bits: prefixLen)
        }

        return false
    }

    private static func matchesPrefix(_ a: [UInt8], _ b: [UInt8], bits: Int) -> Bool {
        guard a.count == b.count else { return false }
        let fullBytes = bits / 8
        let remBits = bits % 8
        for i in 0..<fullBytes {
            if a[i] != b[i] { return false }
        }
        if remBits > 0 {
            let mask = UInt8(0xFF) << UInt8(8 - remBits)
            if (a[fullBytes] & mask) != (b[fullBytes] & mask) {
                return false
            }
        }
        return true
    }
}
