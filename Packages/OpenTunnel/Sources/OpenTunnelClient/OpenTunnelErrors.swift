/// Standard OpenTunnel bridge error codes defined by `docs/protocol.md` and `@opentunnel/protocol`.
public enum OpenTunnelBridgeErrorCode {
    public static let badAttach = "bad_attach"
    public static let badToken = "bad_token"
    public static let tunnelNotBound = "tunnel_not_bound"
    public static let certNotReady = "cert_not_ready"
    public static let replaced = "replaced"
    public static let upstreamConnectFailed = "upstream_connect_failed"
    public static let upstreamIOError = "upstream_io_error"
    public static let clientIOError = "client_io_error"
    public static let idleTimeout = "idle_timeout"
    public static let routeConflict = "route_conflict"
    public static let invalidRoute = "invalid_route"
    public static let unknownRoute = "unknown_route"
    public static let tooManyConnections = "too_many_connections"
    public static let tooManyRoutes = "too_many_routes"

    /// Attach rejection codes that will not succeed on retry.
    public static let fatalAttachCodes: Set<String> = [
        badToken,
        certNotReady,
    ]
}

/// Error emitted when the OpenTunnel bridge rejects an `attach` handshake with `attach_error`.
public struct OpenTunnelAttachError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let code: String
    public let message: String

    public init(code: String) {
        self.code = code
        if code == OpenTunnelBridgeErrorCode.routeConflict {
            self.message = "Bridge attach failed: \(code) (another client holds a route)"
        } else {
            self.message = "Bridge attach failed: \(code)"
        }
    }

    public var isFatalAttachCode: Bool {
        OpenTunnelBridgeErrorCode.fatalAttachCodes.contains(code)
    }

    public var description: String { message }
}

/// Error raised when reading, writing, or removing tunnel identity profiles from storage.
public struct OpenTunnelStorageError: Error, Sendable, CustomStringConvertible {
    public let message: String
    public let underlyingError: (any Error & Sendable)?

    public init(message: String, cause: (any Error & Sendable)? = nil) {
        self.message = message
        self.underlyingError = cause
    }

    public var description: String {
        if let underlyingError {
            return "\(message): \(underlyingError)"
        }
        return message
    }
}

/// Primary client error raised by `OpenTunnelClient` operations, matching `@opentunnel/client`'s
/// `OpenTunnelClientError` tagged error and carrying fatal vs retryable classification.
public struct OpenTunnelClientError: Error, Sendable, CustomStringConvertible {
    public let message: String
    /// The bridge's `attach_error` code when attaching failed (e.g. `bad_token`, `cert_not_ready`, `route_conflict`).
    public let code: String?
    /// Typed attach error when this error wraps an `OpenTunnelAttachError`.
    public let attachError: OpenTunnelAttachError?
    /// Optional underlying cause.
    public let cause: (any Error & Sendable)?
    /// True when the error represents a transient network/EOF/5xx/429 failure that may succeed on retry.
    public let isTransient: Bool

    public init(
        message: String,
        code: String? = nil,
        attachError: OpenTunnelAttachError? = nil,
        cause: (any Error & Sendable)? = nil,
        isTransient: Bool = false
    ) {
        self.message = message
        self.code = code ?? attachError?.code
        self.attachError = attachError ?? (cause as? OpenTunnelAttachError)
        self.cause = cause ?? attachError
        self.isTransient = isTransient
    }

    /// True when this error is fatal to tunnel setup/operation and must NOT be retried by callers
    /// (matching `remote-tunnel.ts`'s `fatal` predicate).
    public var isFatal: Bool {
        if attachError != nil || cause is OpenTunnelAttachError {
            return true
        }
        if message.hasPrefix("Certificate issuance failed") {
            return true
        }
        if message.contains("unsupported proxy scheme") || message.contains("not a valid proxy URL") {
            return true
        }
        return false
    }

    public var description: String { message }

    public static func attachFailed(_ error: OpenTunnelAttachError, prefix: String? = nil) -> OpenTunnelClientError {
        let message = prefix.map { "\($0): \(error.message)" } ?? error.message
        return OpenTunnelClientError(
            message: message,
            code: error.code,
            attachError: error,
            cause: error,
            isTransient: false
        )
    }

    public static func certificateIssuanceFailed(_ reason: String) -> OpenTunnelClientError {
        OpenTunnelClientError(
            message: "Certificate issuance failed: \(reason)",
            isTransient: false
        )
    }

    public static func invalidProxyURL(source: String) -> OpenTunnelClientError {
        OpenTunnelClientError(
            message: "\(source) is not a valid proxy URL",
            isTransient: false
        )
    }

    public static func unsupportedProxyScheme(_ scheme: String, source: String) -> OpenTunnelClientError {
        OpenTunnelClientError(
            message: "\(source) uses an unsupported proxy scheme '\(scheme)': OpenTunnel connects through http:// and https:// proxies",
            isTransient: false
        )
    }

    public static func transient(_ message: String, cause: (any Error & Sendable)? = nil) -> OpenTunnelClientError {
        OpenTunnelClientError(
            message: message,
            cause: cause,
            isTransient: true
        )
    }

    public static func timedOut(_ message: String) -> OpenTunnelClientError {
        OpenTunnelClientError(
            message: message,
            isTransient: true
        )
    }
}

/// Unified OpenTunnel error type mirroring `@opentunnel/client`'s `OpenTunnelError` union.
public enum OpenTunnelError: Error, Sendable, CustomStringConvertible {
    case client(OpenTunnelClientError)
    case storage(OpenTunnelStorageError)
    case attach(OpenTunnelAttachError)

    public var message: String {
        switch self {
        case .client(let err): return err.message
        case .storage(let err): return err.message
        case .attach(let err): return err.message
        }
    }

    public var code: String? {
        switch self {
        case .client(let err): return err.code
        case .storage: return nil
        case .attach(let err): return err.code
        }
    }

    public var isFatal: Bool {
        switch self {
        case .client(let err): return err.isFatal
        case .storage: return false
        case .attach: return true
        }
    }

    public var isTransient: Bool {
        switch self {
        case .client(let err): return err.isTransient && !err.isFatal
        case .storage: return false
        case .attach: return false
        }
    }

    public var description: String {
        switch self {
        case .client(let err): return err.description
        case .storage(let err): return err.description
        case .attach(let err): return err.description
        }
    }

    /// Classifies any Swift `Error` as fatal vs retryable according to OpenTunnel / OpenCode semantics.
    public static func isFatalError(_ error: any Error) -> Bool {
        if error is OpenTunnelAttachError {
            return true
        }
        if let clientError = error as? OpenTunnelClientError {
            return clientError.isFatal
        }
        if let tunnelError = error as? OpenTunnelError {
            return tunnelError.isFatal
        }
        let message = String(describing: error)
        return message.hasPrefix("Certificate issuance failed")
            || message.contains("Certificate issuance failed:")
            || message.contains("unsupported proxy scheme")
            || message.contains("not a valid proxy URL")
    }
}
