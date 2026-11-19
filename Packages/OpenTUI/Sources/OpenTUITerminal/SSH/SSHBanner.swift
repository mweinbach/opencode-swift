/// Startup banner formatting and SSH banner normalization.

/// Data a startup banner is rendered from; a function of config alone.
// parity: ssh/src/banner.ts#BannerDescriptor [status=implemented hash=089cefcb83e4]
public struct SSHBannerDescriptor: Equatable, Sendable {
    /// Host-key algorithms in fingerprint order.
    public let algorithms: [String]
    /// Where the host key came from: `"provided"` / `"ephemeral"` / `"loaded …"` / `"generated …"`.
    public let source: String
    /// Advertised auth methods, in banner order.
    public let methods: [String]
    /// Base64 public-SSH blobs of the static allowlist; sampled for display.
    public let authorizedKeys: [String]?

    public init(
        algorithms: [String],
        source: String,
        methods: [String],
        authorizedKeys: [String]? = nil
    ) {
        self.algorithms = algorithms
        self.source = source
        self.methods = methods
        self.authorizedKeys = authorizedKeys
    }
}

/// Startup-summary lines for `listen()`: pure formatting over a `SSHBannerDescriptor` and bind.
// parity: ssh/src/banner.ts#formatBanner [status=implemented hash=623d5346f204]
public func formatBanner(info: SSHListenInfo, descriptor: SSHBannerDescriptor) -> [String] {
    let displayHost = (info.host == "0.0.0.0" || info.host == "::") ? "localhost" : info.host
    let urlHost = displayHost.contains(":") ? "[\(displayHost)]" : displayHost
    var lines: [String] = [
        "@opentui/ssh  ▸  ssh://\(urlHost):\(info.port)",
    ]
    for (index, fingerprint) in info.fingerprints.enumerated() {
        let algorithm = index < descriptor.algorithms.count ? descriptor.algorithms[index] : "unknown"
        lines.append("host key      \(fingerprint)  (\(algorithm), \(descriptor.source))")
    }
    lines.append("auth          \(descriptor.methods.joined(separator: ", "))")

    if let authorizedKeys = descriptor.authorizedKeys, !authorizedKeys.isEmpty {
        let sampled = authorizedKeys.prefix(3).compactMap { b64 -> String? in
            guard let blob = SSHBase64.decode(b64) else { return nil }
            return sha256Fingerprint(blob)
        }
        let more = authorizedKeys.count > sampled.count ? " …" : ""
        lines.append("authorized    \(authorizedKeys.count) keys  ·  \(sampled.joined(separator: " "))\(more)")
    }
    return lines
}

/// Normalize a user-supplied SSH pre-auth / MOTD banner string:
/// - Returns `nil` for empty or whitespace-only input.
/// - Strips unsafe C0/C1/DEL control characters (preserving `\t`, `\n`, `\r`).
/// - Normalizes all line endings (`\r\n`, `\r`, `\n`) to CRLF (`\r\n`).
/// - Ensures a single trailing CRLF.
public func normalizeBanner(_ raw: String?) -> String? {
    guard let raw else { return nil }
    if raw.trimmingWhitespace().isEmpty {
        return nil
    }

    var sanitized = ""
    sanitized.reserveCapacity(raw.count)
    for scalar in raw.unicodeScalars {
        let v = scalar.value
        if v == 0x09 || v == 0x0A || v == 0x0D {
            sanitized.unicodeScalars.append(scalar)
        } else if v <= 0x1F || (v >= 0x7F && v <= 0x9F) {
            continue
        } else {
            sanitized.unicodeScalars.append(scalar)
        }
    }

    if sanitized.trimmingWhitespace().isEmpty {
        return nil
    }

    // Normalize CR / LF / CRLF into CRLF.
    var normalized = ""
    normalized.reserveCapacity(sanitized.count + 4)
    let scalars = Array(sanitized.unicodeScalars)
    var i = 0
    while i < scalars.count {
        let s = scalars[i]
        if s.value == 0x0D {
            normalized.append("\r\n")
            if i + 1 < scalars.count && scalars[i + 1].value == 0x0A {
                i += 2
            } else {
                i += 1
            }
        } else if s.value == 0x0A {
            normalized.append("\r\n")
            i += 1
        } else {
            normalized.unicodeScalars.append(s)
            i += 1
        }
    }

    if !normalized.hasSuffix("\r\n") {
        normalized.append("\r\n")
    }
    return normalized
}
