/// Connection-lifecycle observability middleware.
/// Pure observability: emits `"connect"` on entry and `"disconnect"` (with duration)
/// on teardown. Sink failures are isolated and never affect the session.

/// Lifecycle event emitted by `sshLogging(options:)`.
// parity: ssh/src/logging.ts#LogEvent [status=implemented hash=2c100ccd3176]
public enum SSHLogEvent: Equatable, Sendable {
    case connect(
        identity: SSHIdentity,
        remoteAddress: SSHRemoteAddress,
        term: String,
        cols: Int,
        rows: Int
    )
    case disconnect(
        identity: SSHIdentity,
        remoteAddress: SSHRemoteAddress,
        term: String,
        cols: Int,
        rows: Int,
        durationMs: Int
    )

    public var type: String {
        switch self {
        case .connect: return "connect"
        case .disconnect: return "disconnect"
        }
    }

    public var identity: SSHIdentity {
        switch self {
        case .connect(let id, _, _, _, _), .disconnect(let id, _, _, _, _, _):
            return id
        }
    }

    public var remoteAddress: SSHRemoteAddress {
        switch self {
        case .connect(_, let addr, _, _, _), .disconnect(_, let addr, _, _, _, _):
            return addr
        }
    }

    public var term: String {
        switch self {
        case .connect(_, _, let term, _, _), .disconnect(_, _, let term, _, _, _):
            return term
        }
    }

    public var cols: Int {
        switch self {
        case .connect(_, _, _, let cols, _), .disconnect(_, _, _, let cols, _, _):
            return cols
        }
    }

    public var rows: Int {
        switch self {
        case .connect(_, _, _, _, let rows), .disconnect(_, _, _, _, let rows, _):
            return rows
        }
    }

    public var durationMs: Int? {
        if case .disconnect(_, _, _, _, _, let durationMs) = self {
            return durationMs
        }
        return nil
    }
}

/// Configuration for `sshLogging(options:)`.
// parity: ssh/src/logging.ts#LoggingOptions [status=implemented hash=5c86e74a748f]
public struct SSHLoggingOptions: Sendable {
    /// Optional event sink. Defaults to formatting a one-line sanitized summary
    /// and writing it to `lineSink` (which defaults to stdout `print`).
    public var log: (@Sendable (SSHLogEvent) async throws -> Void)?
    /// Optional line sink used by the default formatter (useful for capturing
    /// formatted default lines in tests without mutating global stdout).
    public var lineSink: (@Sendable (String) -> Void)?

    public init(
        log: (@Sendable (SSHLogEvent) async throws -> Void)? = nil,
        lineSink: (@Sendable (String) -> Void)? = nil
    ) {
        self.log = log
        self.lineSink = lineSink
    }
}

private func formatRemoteAddress(_ address: SSHRemoteAddress) -> String {
    if let port = address.port {
        return "\(address.address):\(port)"
    }
    return address.address
}

private func formatDurationMs(_ ms: Int) -> String {
    if ms < 1000 {
        return "\(ms)ms"
    }
    // Round to 1 decimal place in pure Swift (no Foundation String(format:)).
    let tenths = (ms + 50) / 100
    let whole = tenths / 10
    let frac = tenths % 10
    return "\(whole).\(frac)s"
}

/// Default one-line rendering matching upstream `logging.ts`:
/// `connect    alice@1.2.3.4:54321  publickey SHA256:…  xterm-256color 80×24`
/// `disconnect alice@1.2.3.4:54321  1.2s`
public func formatLogEvent(_ event: SSHLogEvent) -> String {
    let who = "\(escapeControlCharacters(event.identity.username))@\(formatRemoteAddress(event.remoteAddress))"
    switch event {
    case .connect(let identity, _, let term, let cols, let rows):
        let method: String
        if case .publicKey(_, let fingerprint, _) = identity {
            method = "publickey \(fingerprint)"
        } else {
            method = identity.method.rawValue
        }
        return "connect    \(who)  \(method)  \(escapeControlCharacters(term)) \(cols)×\(rows)"
    case .disconnect(_, _, _, _, _, let durationMs):
        return "disconnect \(who)  \(formatDurationMs(durationMs))"
    }
}

/// Lifecycle logging as a `.use(...)` middleware: a `"connect"` event on entry,
/// a `"disconnect"` (with duration) on teardown. Runs teardown even when a
/// downstream gate denies or the handler throws, without ever swallowing errors.
// parity: ssh/src/logging.ts#logging [status=implemented hash=d74b2f49b42e]
public func sshLogging(options: SSHLoggingOptions = SSHLoggingOptions()) -> SSHMiddleware {
    let lineSink: @Sendable (String) -> Void = options.lineSink ?? { print($0) }
    let sink: @Sendable (SSHLogEvent) async throws -> Void = options.log ?? { event in
        lineSink(formatLogEvent(event))
    }

    @Sendable
    func emit(_ event: SSHLogEvent) async {
        do {
            try await sink(event)
        } catch {
            // Logging sink failures are isolated and ignored so observability
            // cannot affect a session.
        }
    }

    return { session, next in
        let clock = ContinuousClock()
        let start = clock.now
        await emit(.connect(
            identity: session.identity,
            remoteAddress: session.remoteAddress,
            term: session.term,
            cols: session.cols,
            rows: session.rows
        ))
        do {
            let handoff = try await next()
            let elapsedMs = elapsedMilliseconds(from: start, to: clock.now)
            await emit(.disconnect(
                identity: session.identity,
                remoteAddress: session.remoteAddress,
                term: session.term,
                cols: session.cols,
                rows: session.rows,
                durationMs: elapsedMs
            ))
            return handoff
        } catch {
            let elapsedMs = elapsedMilliseconds(from: start, to: clock.now)
            await emit(.disconnect(
                identity: session.identity,
                remoteAddress: session.remoteAddress,
                term: session.term,
                cols: session.cols,
                rows: session.rows,
                durationMs: elapsedMs
            ))
            throw error
        }
    }
}

private func elapsedMilliseconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Int {
    let duration = start.duration(to: end)
    let (seconds, attoseconds) = duration.components
    let ms = seconds * 1_000 + attoseconds / 1_000_000_000_000_000
    return max(0, Int(ms))
}
