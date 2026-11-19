/// Persisted device tunnel identity including control token and TLS certificate material.
public struct OpenTunnelIdentity: Equatable, Hashable, Sendable, Codable {
    public let id: String
    public let hostname: String
    public let token: String
    public let privateKey: String
    public let certificate: String
    public let chain: String
    /// RFC 3339 / ISO-8601 UTC timestamp of certificate expiration.
    public let certificateExpiry: String

    public init(
        id: String,
        hostname: String,
        token: String,
        privateKey: String,
        certificate: String,
        chain: String = "",
        certificateExpiry: String
    ) {
        self.id = id
        self.hostname = hostname
        self.token = token
        self.privateKey = privateKey
        self.certificate = certificate
        self.chain = chain
        self.certificateExpiry = certificateExpiry
    }

    /// Parsed Unix epoch seconds of `certificateExpiry`, or `nil` if invalid.
    public var certificateExpiryEpochSeconds: Double? {
        OpenTunnelTimestamp.parseISO8601(certificateExpiry)
    }

    /// Returns `true` when the certificate has expired relative to `nowEpochSeconds`.
    public func isCertificateExpired(nowEpochSeconds: Double = OpenTunnelTimestamp.nowEpochSeconds()) -> Bool {
        guard let expiry = certificateExpiryEpochSeconds else { return true }
        return expiry <= nowEpochSeconds
    }

    /// Returns `true` when the certificate is within `renewalWindowSeconds` (default 30 days) of expiry.
    public func needsCertificateRenewal(
        nowEpochSeconds: Double = OpenTunnelTimestamp.nowEpochSeconds(),
        renewalWindowSeconds: Double = 30 * 24 * 60 * 60
    ) -> Bool {
        guard let expiry = certificateExpiryEpochSeconds else { return true }
        return (expiry - nowEpochSeconds) < renewalWindowSeconds
    }

    /// Returns a copy with updated certificate material while preserving identity and private key.
    public func withRenewedCertificate(certificate: String, chain: String, expiry: String) -> OpenTunnelIdentity {
        OpenTunnelIdentity(
            id: id,
            hostname: hostname,
            token: token,
            privateKey: privateKey,
            certificate: certificate,
            chain: chain,
            certificateExpiry: expiry
        )
    }
}

/// Persisted in-progress tunnel provisioning state saved before requesting certificate issuance,
/// allowing interrupted provisioning to resume cleanly.
public struct OpenTunnelPendingIdentity: Equatable, Hashable, Sendable, Codable {
    public let id: String
    public let hostname: String
    public let token: String
    public let privateKey: String
    public let csr: String

    public init(id: String, hostname: String, token: String, privateKey: String, csr: String) {
        self.id = id
        self.hostname = hostname
        self.token = token
        self.privateKey = privateKey
        self.csr = csr
    }
}

/// Summary of an in-progress tunnel creation returned by `tunnel.pending()`.
public struct OpenTunnelPendingTunnelSummary: Equatable, Hashable, Sendable, Codable {
    public let id: String
    public let hostname: String

    public init(id: String, hostname: String) {
        self.id = id
        self.hostname = hostname
    }
}

/// Profile-tagged stored tunnel returned by `tunnel.list()`.
public struct OpenTunnelStoredTunnel: Equatable, Hashable, Sendable, Codable {
    public let profile: String
    public let tunnel: OpenTunnelIdentity

    public init(profile: String, tunnel: OpenTunnelIdentity) {
        self.profile = profile
        self.tunnel = tunnel
    }
}

/// Progress stages emitted during `create`, `resume`, and `ensure`.
public enum OpenTunnelProvisionStage: String, Equatable, Hashable, Sendable, Codable {
    case checkingCertificate = "checking-certificate"
    case creatingTunnel = "creating-tunnel"
    case generatingKey = "generating-key"
    case generatingCSR = "generating-csr"
    case resumingCertificate = "resuming-certificate"
    case requestingCertificate = "requesting-certificate"
    case waitingCertificate = "waiting-certificate"
    case savingIdentity = "saving-identity"
    case ready = "ready"
}

/// Policy when the bridge rejects `attach` with `route_conflict`.
public enum OpenTunnelRouteConflictPolicy: String, Equatable, Hashable, Sendable, Codable {
    /// Keep retrying with backoff until the competing bridge releases the route (default).
    case retry
    /// Fail immediately with an `OpenTunnelAttachError(code: "route_conflict")`.
    case fail
}

/// Lifecycle and connection events emitted by an `OpenTunnelConnection`.
public enum OpenTunnelClientEvent: Equatable, Hashable, Sendable {
    case connecting(attempt: Int)
    case connected(session: String, routes: [String])
    case disconnected(reason: String)
    case reconnecting(attempt: Int, delayMs: Int)
    case routeConflict(routes: [String])
    case connectionOpened(conn: UInt32, route: String, peer: String)
    case connectionClosed(conn: UInt32, route: String, error: String?)
    case certificateRenewed(expiry: String)
    case stopped(error: String?)
}

/// Connection state snapshot exposed by `OpenTunnelConnection.status`.
public struct OpenTunnelStatus: Equatable, Hashable, Sendable {
    public enum State: String, Equatable, Hashable, Sendable, Codable {
        case waitingRoutes = "waiting-routes"
        case connecting
        case connected
        case reconnecting
        case stopped
    }

    public let state: State
    public let hostname: String
    public let routes: [String: OpenTunnelRoute]
    public let session: String?
    public let connections: Int
    public let lastError: String?
    public let connectedAtEpochMs: Int64?

    public init(
        state: State,
        hostname: String,
        routes: [String: OpenTunnelRoute],
        session: String? = nil,
        connections: Int = 0,
        lastError: String? = nil,
        connectedAtEpochMs: Int64? = nil
    ) {
        self.state = state
        self.hostname = hostname
        self.routes = routes
        self.session = session
        self.connections = connections
        self.lastError = lastError
        self.connectedAtEpochMs = connectedAtEpochMs
    }
}

/// Configurable protocol timings (with upstream OpenTunnel defaults; overridable for fast deterministic tests).
public struct OpenTunnelTimingConfiguration: Equatable, Hashable, Sendable {
    public let certificatePollIntervalMs: Int
    public let connectTimeoutMs: Int
    public let minHeartbeatMs: Int
    public let minIdleTimeoutMs: Int
    public let reconnectBackoffMinMs: Int
    public let reconnectBackoffMaxMs: Int
    public let certificateCheckFreshMs: Int
    public let certificateCheckDueMs: Int
    public let renewalWindowSeconds: Double
    public let maxConns: Int
    public let stalledChannelBytes: Int
    public let apiMaxRetries: Int
    public let apiRetryBaseMs: Int
    public let apiRetryMaxMs: Int

    public init(
        certificatePollIntervalMs: Int = 2_000,
        connectTimeoutMs: Int = 10_000,
        minHeartbeatMs: Int = 1_000,
        minIdleTimeoutMs: Int = 5_000,
        reconnectBackoffMinMs: Int = 250,
        reconnectBackoffMaxMs: Int = 30_000,
        certificateCheckFreshMs: Int = 12 * 60 * 60 * 1_000,
        certificateCheckDueMs: Int = 60_000,
        renewalWindowSeconds: Double = 30 * 24 * 60 * 60,
        maxConns: Int = 256,
        stalledChannelBytes: Int = 8 * 1024 * 1024,
        apiMaxRetries: Int = 6,
        apiRetryBaseMs: Int = 250,
        apiRetryMaxMs: Int = 8_000
    ) {
        self.certificatePollIntervalMs = certificatePollIntervalMs
        self.connectTimeoutMs = connectTimeoutMs
        self.minHeartbeatMs = minHeartbeatMs
        self.minIdleTimeoutMs = minIdleTimeoutMs
        self.reconnectBackoffMinMs = reconnectBackoffMinMs
        self.reconnectBackoffMaxMs = reconnectBackoffMaxMs
        self.certificateCheckFreshMs = certificateCheckFreshMs
        self.certificateCheckDueMs = certificateCheckDueMs
        self.renewalWindowSeconds = renewalWindowSeconds
        self.maxConns = maxConns
        self.stalledChannelBytes = stalledChannelBytes
        self.apiMaxRetries = apiMaxRetries
        self.apiRetryBaseMs = apiRetryBaseMs
        self.apiRetryMaxMs = apiRetryMaxMs
    }

    public static let `default` = OpenTunnelTimingConfiguration()
}
