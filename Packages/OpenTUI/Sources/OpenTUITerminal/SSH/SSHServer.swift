import Synchronization

// MARK: - Runtime Resolution (`runtime.ts`)

private let sshMaxDurationMs: Int = 24 * 60 * 60 * 1_000
private let sshMaxSafeInteger: Int = 9_007_199_254_740_991

/// Resolved session concurrency bounds.
// parity: ssh/src/runtime.ts#ResolvedSessionLimits [status=implemented hash=270d9ca16b92]
public struct SSHResolvedSessionLimits: Equatable, Hashable, Sendable {
    public let perConnection: Int
    public let global: Int

    public init(perConnection: Int = 1, global: Int = 100) {
        self.perConnection = perConnection
        self.global = global
    }
}

/// Everything derived purely from `SSHServerConfig` once at startup.
// parity: ssh/src/runtime.ts#ResolvedRuntime [status=implemented hash=0205ed0b1fad]
public struct SSHResolvedRuntime: Sendable {
    public let hostKeys: [String]
    public let fingerprints: [String]
    public let authenticator: any SSHAuthenticator
    public let idleTimeoutMs: Int?
    public let maxTimeoutMs: Int?
    public let sessionLimits: SSHResolvedSessionLimits
    public let safe: SSHSafeInvoke
    /// True when `none` is the only advertised method (`listen()` warns outside loopback).
    public let noneOnly: Bool
    public let banner: SSHBannerDescriptor

    public init(
        hostKeys: [String],
        fingerprints: [String],
        authenticator: any SSHAuthenticator,
        idleTimeoutMs: Int?,
        maxTimeoutMs: Int?,
        sessionLimits: SSHResolvedSessionLimits,
        safe: SSHSafeInvoke,
        noneOnly: Bool,
        banner: SSHBannerDescriptor
    ) {
        self.hostKeys = hostKeys
        self.fingerprints = fingerprints
        self.authenticator = authenticator
        self.idleTimeoutMs = idleTimeoutMs
        self.maxTimeoutMs = maxTimeoutMs
        self.sessionLimits = sessionLimits
        self.safe = safe
        self.noneOnly = noneOnly
        self.banner = banner
    }
}

/// Parse a duration value into milliseconds (`"10m"`, `"30s"`, `"500ms"`, `"1h"`,
/// or positive integer milliseconds up to 24h). Throws `ConfigError` when malformed
/// or out of bounds.
internal func parseSSHDuration(name: String, value: SSHDuration) throws -> Int {
    let ms: Int
    switch value {
    case .milliseconds(let raw):
        ms = raw
    case .string(let raw):
        let trimmed = raw.trimmingWhitespace()
        guard !trimmed.isEmpty else {
            throw ConfigError("invalid \(name): \(raw)")
        }
        let chars = Array(trimmed)
        var idx = 0
        while idx < chars.count && chars[idx] >= "0" && chars[idx] <= "9" {
            idx += 1
        }
        guard idx > 0 else {
            throw ConfigError("invalid \(name): \(raw)")
        }
        let digitStr = String(chars[0..<idx])
        guard let number = Int(digitStr) else {
            throw ConfigError("invalid \(name): \(raw)")
        }
        while idx < chars.count && (chars[idx] == " " || chars[idx] == "\t") {
            idx += 1
        }
        let unit = String(chars[idx...])
        let multiplier: Int
        switch unit {
        case "", "ms": multiplier = 1
        case "s": multiplier = 1_000
        case "m": multiplier = 60_000
        case "h": multiplier = 3_600_000
        default:
            throw ConfigError("invalid \(name): \(raw)")
        }
        let (product, overflow) = number.multipliedReportingOverflow(by: multiplier)
        if overflow {
            throw ConfigError("invalid \(name): \(raw)")
        }
        ms = product
    }

    guard ms > 0 && ms <= sshMaxDurationMs else {
        throw ConfigError("invalid \(name): \(value)")
    }
    return ms
}

private func parseSSHLimit(name: String, value: Int?, fallback: Int) throws -> Int {
    let limit = value ?? fallback
    guard limit > 0 && limit <= sshMaxSafeInteger else {
        throw ConfigError("invalid \(name): \(limit)")
    }
    return limit
}

/// Resolve an `SSHServerConfig` into validated runtime settings.
/// Throws `ConfigError` on invalid host keys, empty auth credentials, invalid
/// timeouts, or invalid session limits.
// parity: ssh/src/runtime.ts#resolveRuntime [status=implemented hash=f3d9eb907a2d]
public func resolveRuntime(_ config: SSHServerConfig) throws -> SSHResolvedRuntime {
    let hostKey = try resolveHostKey(config.hostKey, fileStore: config.keyFileStore)
    let idleTimeoutMs = try config.idleTimeout.map { try parseSSHDuration(name: "idleTimeout", value: $0) }
    let maxTimeoutMs = try config.maxTimeout.map { try parseSSHDuration(name: "maxTimeout", value: $0) }
    let sessionLimits = SSHResolvedSessionLimits(
        perConnection: try parseSSHLimit(
            name: "limits.session.perConnection",
            value: config.limits?.session?.perConnection,
            fallback: 1
        ),
        global: try parseSSHLimit(
            name: "limits.session.global",
            value: config.limits?.session?.global,
            fallback: 100
        )
    )

    let onError: @Sendable (any Error) throws -> Void = config.onError ?? { error in
        print(formatSafeError(error))
    }
    let safe = createSafeInvoke(onError: onError)

    let verifier = config.signatureVerifier ?? DefaultSSHSignatureVerifier()
    let resolvedAuth = try resolveAuth(
        config.auth,
        fileStore: config.keyFileStore,
        signatureVerifier: verifier,
        onError: { error in safe.report(error) }
    )

    let banner = SSHBannerDescriptor(
        algorithms: hostKey.algorithms,
        source: hostKey.source,
        methods: resolvedAuth.authenticator.advertisedMethods().map(\.rawValue),
        authorizedKeys: resolvedAuth.authorizedKeys
    )

    return SSHResolvedRuntime(
        hostKeys: hostKey.hostKeyPems,
        fingerprints: hostKey.fingerprints,
        authenticator: resolvedAuth.authenticator,
        idleTimeoutMs: idleTimeoutMs,
        maxTimeoutMs: maxTimeoutMs,
        sessionLimits: sessionLimits,
        safe: safe,
        noneOnly: resolvedAuth.noneOnly,
        banner: banner
    )
}

// MARK: - Server & Builder (`server.ts`)

private func isLoopbackHost(_ host: String) -> Bool {
    host == "127.0.0.1" || host == "::1" || host == "localhost"
}

/// Running or startable OpenTUI SSH server.
public final class SSHServer: SSHServerProtocol, @unchecked Sendable {
    private struct ServerState: Sendable {
        var listenInfo: SSHListenInfo? = nil
        var reportsServerErrors: Bool = false
        var bindingAttempts: Int = 0
    }

    public let runtime: SSHResolvedRuntime
    private let config: SSHServerConfig
    private let connectionHandler: SSHConnectionHandler
    private let driver: any SSHTransportDriver
    private let state = Mutex(ServerState())

    internal init(
        config: SSHServerConfig,
        runtime: SSHResolvedRuntime,
        middlewares: [SSHRuntimeMiddleware],
        handler: @escaping SSHSessionHandler,
        driver: any SSHTransportDriver
    ) {
        self.config = config
        self.runtime = runtime
        self.driver = driver
        self.connectionHandler = createConnectionHandler(SSHConnectionDependencies(
            authenticator: runtime.authenticator,
            middlewares: middlewares,
            handler: handler,
            safe: runtime.safe,
            idleTimeoutMs: runtime.idleTimeoutMs,
            maxTimeoutMs: runtime.maxTimeoutMs,
            sessionLimits: runtime.sessionLimits,
            createRenderer: config.createRenderer
        ))
    }

    /// Current bound listen info, or `nil` before `listen()` succeeds or after `close()`.
    public var address: SSHListenInfo? {
        state.withLock { $0.listenInfo }
    }

    /// Number of currently tracked live SSH connections.
    public var connections: Int {
        connectionHandler.connectionCount
    }

    /// Number of currently active shell sessions across all connections.
    public var activeSessions: Int {
        connectionHandler.activeSessionCount
    }

    /// Bind and start accepting SSH connections. Defaults to `127.0.0.1:2222`.
    public func listen(port: Int = 2222, host: String = "127.0.0.1") async throws -> SSHListenInfo {
        guard port >= 0 && port <= 65535 else {
            throw ConfigError("invalid port: \(port)")
        }

        if runtime.noneOnly && !isLoopbackHost(host) {
            let warning = "@opentui/ssh: no authentication configured while listening on \(host). "
                + "Anyone who can reach this port, including through published container ports, tunnels, "
                + "or proxies, gets a session. Set `auth` to restrict access."
            if let sink = config.warningSink {
                sink(warning)
            } else {
                print(warning)
            }
        }

        state.withLock { $0.bindingAttempts += 1 }
        do {
            let bound = try await driver.listen(
                port: port,
                host: host,
                hostKeys: runtime.hostKeys,
                onConnection: { [connectionHandler] client in
                    connectionHandler.onConnection(client)
                },
                onError: { [weak self] error in
                    guard let self else { return }
                    let shouldReport = self.state.withLock { $0.bindingAttempts == 0 && $0.reportsServerErrors }
                    if shouldReport {
                        self.runtime.safe.report(error)
                    }
                }
            )
            let info = SSHListenInfo(
                host: bound.host,
                port: bound.port,
                fingerprints: runtime.fingerprints
            )
            state.withLock {
                $0.bindingAttempts = max(0, $0.bindingAttempts - 1)
                $0.reportsServerErrors = true
                $0.listenInfo = info
            }
            connectionHandler.setAccepting(true)

            if config.startupBanner {
                let lines = formatBanner(info: info, descriptor: runtime.banner)
                if let bannerSink = config.bannerSink {
                    bannerSink(lines)
                } else {
                    print(lines.joined(separator: "\n"))
                }
            }
            return info
        } catch {
            state.withLock { $0.bindingAttempts = max(0, $0.bindingAttempts - 1) }
            throw error
        }
    }

    /// Stop accepting new sessions, destroy live renderers, close active clients,
    /// and shut down the transport listener.
    public func close() async {
        await connectionHandler.closeAll()
        await driver.close()
        state.withLock {
            $0.reportsServerErrors = false
            $0.listenInfo = nil
        }
    }
}

/// Immutable fluent builder returned by `createSSHServer(config:driver:)`.
/// `.use(mw)` appends middleware in execution order (first = outermost);
/// `.serve(handler)` / `.handle(handler)` validates config and seals the server.
public struct SSHServerBuilder: SSHServerBuilderProtocol, Sendable {
    private let config: SSHServerConfig
    private let middlewares: [SSHRuntimeMiddleware]
    private let driver: any SSHTransportDriver

    internal init(
        config: SSHServerConfig,
        middlewares: [SSHRuntimeMiddleware],
        driver: any SSHTransportDriver
    ) {
        self.config = config
        self.middlewares = middlewares
        self.driver = driver
    }

    public func use(_ middleware: @escaping SSHMiddlewareFunction) -> SSHServerBuilder {
        SSHServerBuilder(config: config, middlewares: middlewares + [middleware], driver: driver)
    }

    public func serve(_ handler: @escaping SSHSessionHandler) throws -> SSHServer {
        let runtime = try resolveRuntime(config)
        return SSHServer(
            config: config,
            runtime: runtime,
            middlewares: middlewares,
            handler: handler,
            driver: driver
        )
    }

    /// Alias for `serve(_:)` matching idiomatic Swift builder usage.
    public func handle(_ handler: @escaping SSHSessionHandler) throws -> SSHServer {
        try serve(handler)
    }
}

/// Create an SSH server builder. Chain `.use(middleware)` and seal with
/// `.serve(handler)` / `.handle(handler)` before calling `await server.listen()`.
// parity: ssh/src/server.ts#createServer [status=implemented hash=1959a080a47b]
public func createSSHServer(
    config: SSHServerConfig = SSHServerConfig(),
    driver: any SSHTransportDriver = InMemorySSHTransportDriver()
) -> SSHServerBuilder {
    SSHServerBuilder(config: config, middlewares: [], driver: driver)
}

// MARK: - In-Memory Deterministic SSH Transport Driver (All Platforms incl. iOS & WASI)

/// Deterministic in-memory `SSHChannel` supporting backpressure (`hold()` / `release()`),
/// incoming client data injection, exit code recording, and error/close simulation.
public final class InMemorySSHChannel: SSHChannel, @unchecked Sendable {
    private struct State: Sendable {
        var held: Bool = false
        var writes: [[UInt8]] = []
        var exits: [Int] = []
        var closeCalls: Int = 0
        var pauseCalls: Int = 0
        var resumeCalls: Int = 0
        var closed: Bool = false
        var dataHandler: (@Sendable ([UInt8]) -> Void)? = nil
        var drainHandler: (@Sendable () -> Void)? = nil
        var closeHandler: (@Sendable () -> Void)? = nil
        var errorHandler: (@Sendable (any Error) -> Void)? = nil
    }

    private let state = Mutex(State())

    public init() {}

    public var writes: [[UInt8]] {
        state.withLock { $0.writes }
    }

    public var writtenBytes: [UInt8] {
        state.withLock { $0.writes.flatMap { $0 } }
    }

    public var writtenText: String {
        String(decoding: writtenBytes, as: UTF8.self)
    }

    public var exits: [Int] {
        state.withLock { $0.exits }
    }

    public var closeCalls: Int {
        state.withLock { $0.closeCalls }
    }

    public var pauseCalls: Int {
        state.withLock { $0.pauseCalls }
    }

    public var resumeCalls: Int {
        state.withLock { $0.resumeCalls }
    }

    public var isClosed: Bool {
        state.withLock { $0.closed }
    }

    /// Simulate peer TCP window saturation so subsequent `write` calls signal backpressure.
    public func hold() {
        state.withLock { $0.held = true }
    }

    /// Release backpressure and notify the bridge via `onDrain`.
    public func release() {
        let drainHandler = state.withLock { s -> (@Sendable () -> Void)? in
            s.held = false
            return s.drainHandler
        }
        drainHandler?()
    }

    /// Inject client keyboard/stdin bytes into the channel.
    public func receiveData(_ bytes: [UInt8]) {
        let handler = state.withLock { $0.closed ? nil : $0.dataHandler }
        handler?(bytes)
    }

    /// Inject UTF-8 string input from the remote client.
    public func receiveText(_ text: String) {
        receiveData(Array(text.utf8))
    }

    /// Simulate the peer closing the channel.
    public func emitClose() {
        let handler = state.withLock { s -> (@Sendable () -> Void)? in
            s.closed = true
            return s.closeHandler
        }
        handler?()
    }

    /// Simulate a channel transport error.
    public func emitError(_ error: any Error) {
        let handler = state.withLock { s -> (@Sendable (any Error) -> Void)? in
            s.closed = true
            return s.errorHandler
        }
        handler?(error)
    }

    @discardableResult
    public func write(_ bytes: [UInt8]) -> Bool {
        state.withLock { s in
            s.writes.append(bytes)
            return !s.held
        }
    }

    public func pause() {
        state.withLock { $0.pauseCalls += 1 }
    }

    public func resume() {
        state.withLock { $0.resumeCalls += 1 }
    }

    public func exit(code: Int) {
        state.withLock { $0.exits.append(code) }
    }

    public func close() {
        state.withLock { s in
            s.closeCalls += 1
            s.closed = true
        }
    }

    public func setDataHandler(_ handler: (@Sendable ([UInt8]) -> Void)?) {
        state.withLock { $0.dataHandler = handler }
    }

    public func setDrainHandler(_ handler: (@Sendable () -> Void)?) {
        state.withLock { $0.drainHandler = handler }
    }

    public func setCloseHandler(_ handler: (@Sendable () -> Void)?) {
        state.withLock { $0.closeHandler = handler }
    }

    public func setErrorHandler(_ handler: (@Sendable (any Error) -> Void)?) {
        state.withLock { $0.errorHandler = handler }
    }
}

/// Deterministic in-memory `SSHDirectShellSessionChannel`.
public final class InMemorySSHSessionChannel: SSHDirectShellSessionChannel, @unchecked Sendable {
    private struct State: Sendable {
        var envHandler: (@Sendable (SSHEnvRequest) -> Bool)? = nil
        var ptyHandler: (@Sendable (SSHPtyRequest) -> Bool)? = nil
        var windowChangeHandler: (@Sendable (SSHWindowChangeRequest) -> Void)? = nil
        var signalHandler: (@Sendable (String) -> Void)? = nil
        var shellHandler: (@Sendable () -> (any SSHChannel)?)? = nil
        var directShellHandler: (@Sendable (() throws -> any SSHChannel) -> Bool)? = nil
        var closeHandler: (@Sendable () -> Void)? = nil
    }

    private let state = Mutex(State())

    public init() {}

    public func setEnvHandler(_ handler: (@Sendable (SSHEnvRequest) -> Bool)?) {
        state.withLock { $0.envHandler = handler }
    }

    public func setPtyHandler(_ handler: (@Sendable (SSHPtyRequest) -> Bool)?) {
        state.withLock { $0.ptyHandler = handler }
    }

    public func setWindowChangeHandler(_ handler: (@Sendable (SSHWindowChangeRequest) -> Void)?) {
        state.withLock { $0.windowChangeHandler = handler }
    }

    public func setSignalHandler(_ handler: (@Sendable (String) -> Void)?) {
        state.withLock { $0.signalHandler = handler }
    }

    public func setShellHandler(_ handler: (@Sendable () -> (any SSHChannel)?)?) {
        state.withLock { $0.shellHandler = handler }
    }

    public func setDirectShellHandler(_ handler: (@Sendable (() throws -> any SSHChannel) -> Bool)?) {
        state.withLock { $0.directShellHandler = handler }
    }

    public func setCloseHandler(_ handler: (@Sendable () -> Void)?) {
        state.withLock { $0.closeHandler = handler }
    }

    @discardableResult
    public func requestEnv(key: String, value: String) -> Bool {
        let handler = state.withLock { $0.envHandler }
        return handler?(SSHEnvRequest(key: key, value: value)) ?? false
    }

    @discardableResult
    public func requestPty(term: String = "xterm-256color", cols: Int = 80, rows: Int = 24) -> Bool {
        let handler = state.withLock { $0.ptyHandler }
        return handler?(SSHPtyRequest(term: term, cols: cols, rows: rows)) ?? false
    }

    public func sendWindowChange(cols: Int, rows: Int) {
        let handler = state.withLock { $0.windowChangeHandler }
        handler?(SSHWindowChangeRequest(cols: cols, rows: rows))
    }

    public func sendSignal(_ name: String) {
        let handler = state.withLock { $0.signalHandler }
        handler?(name)
    }

    /// Request a shell channel using the provided `InMemorySSHChannel` (or a new one).
    /// Returns the channel if admitted, or `nil` if rejected.
    @discardableResult
    public func requestShell(channel: InMemorySSHChannel = InMemorySSHChannel()) -> InMemorySSHChannel? {
        let handler = state.withLock { $0.directShellHandler }
        let accepted = handler? { channel } ?? false
        return accepted ? channel : nil
    }

    /// Request a shell with a custom factory that may throw to test setup error paths.
    @discardableResult
    public func requestShell(factory: @escaping () throws -> any SSHChannel) -> Bool {
        let handler = state.withLock { $0.directShellHandler }
        return handler?(factory) ?? false
    }

    public func emitClose() {
        let handler = state.withLock { $0.closeHandler }
        handler?()
    }
}

/// Deterministic in-memory `SSHClientConnection`.
public final class InMemorySSHClientConnection: SSHClientConnection, @unchecked Sendable {
    private struct State: Sendable {
        var authHandler: (@Sendable (SSHRawAuthContext) async -> Void)? = nil
        var readyHandler: (@Sendable () -> Void)? = nil
        var sessionHandler: (@Sendable (any SSHSessionChannel) -> Void)? = nil
        var closeHandler: (@Sendable () -> Void)? = nil
        var errorHandler: (@Sendable (any Error) -> Void)? = nil
        var noDelayHistory: [Bool] = []
        var endCalls: Int = 0
        var forceCloseCalls: Int = 0
        var noDelayHook: (@Sendable (InMemorySSHClientConnection, Bool) throws -> Void)? = nil
    }

    public let remoteAddress: SSHRemoteAddress
    private let state = Mutex(State())

    public init(
        remoteAddress: SSHRemoteAddress = SSHRemoteAddress(address: "127.0.0.1", port: 50000),
        noDelayHook: (@Sendable (InMemorySSHClientConnection, Bool) throws -> Void)? = nil
    ) {
        self.remoteAddress = remoteAddress
        self.state.withLock { $0.noDelayHook = noDelayHook }
    }

    public var noDelayHistory: [Bool] {
        state.withLock { $0.noDelayHistory }
    }

    public var endCalls: Int {
        state.withLock { $0.endCalls }
    }

    public var forceCloseCalls: Int {
        state.withLock { $0.forceCloseCalls }
    }

    public func setNoDelay(_ enabled: Bool) throws {
        let hook = state.withLock { s -> (@Sendable (InMemorySSHClientConnection, Bool) throws -> Void)? in
            s.noDelayHistory.append(enabled)
            return s.noDelayHook
        }
        try hook?(self, enabled)
    }

    public func setAuthenticationHandler(_ handler: (@Sendable (SSHRawAuthContext) async -> Void)?) {
        state.withLock { $0.authHandler = handler }
    }

    public func setReadyHandler(_ handler: (@Sendable () -> Void)?) {
        state.withLock { $0.readyHandler = handler }
    }

    public func setSessionHandler(_ handler: (@Sendable (any SSHSessionChannel) -> Void)?) {
        state.withLock { $0.sessionHandler = handler }
    }

    public func setCloseHandler(_ handler: (@Sendable () -> Void)?) {
        state.withLock { $0.closeHandler = handler }
    }

    public func setErrorHandler(_ handler: (@Sendable (any Error) -> Void)?) {
        state.withLock { $0.errorHandler = handler }
    }

    public func end() {
        state.withLock { $0.endCalls += 1 }
    }

    public func forceClose() {
        state.withLock { $0.forceCloseCalls += 1 }
    }

    /// Result returned by `authenticate(...)` on an `InMemorySSHClientConnection`.
    public enum ClientAuthResult: Equatable, Sendable {
        case accepted
        case rejected([SSHAuthMethod])
        case ignored
    }

    /// Drive an authentication attempt through the connection handler.
    @discardableResult
    public func authenticate(
        method: String,
        username: String,
        password: String? = nil,
        prompt: (@Sendable ([SSHKeyboardQuestion], @escaping @Sendable ([String]?) -> Void) -> Void)? = nil,
        keyAlgorithm: String? = nil,
        keyData: [UInt8]? = nil,
        signature: [UInt8]? = nil,
        blob: [UInt8]? = nil,
        hashAlgo: String? = nil
    ) async -> ClientAuthResult {
        guard let handler = state.withLock({ $0.authHandler }) else {
            return .ignored
        }
        let outcome = Mutex<ClientAuthResult>(.ignored)
        let ctx = SSHRawAuthContext(
            method: method,
            username: username,
            password: password,
            prompt: prompt,
            keyAlgorithm: keyAlgorithm,
            keyData: keyData,
            signature: signature,
            blob: blob,
            hashAlgo: hashAlgo,
            accept: { outcome.withLock { $0 = .accepted } },
            reject: { methods in outcome.withLock { $0 = .rejected(methods) } }
        )
        await handler(ctx)
        return outcome.withLock { $0 }
    }

    /// Notify the connection handler that authentication completed and the client is ready.
    public func emitReady() {
        let handler = state.withLock { $0.readyHandler }
        handler?()
    }

    /// Open a new multiplexed SSH session channel on this connection.
    public func openSession() -> InMemorySSHSessionChannel {
        let session = InMemorySSHSessionChannel()
        let handler = state.withLock { $0.sessionHandler }
        handler?(session)
        return session
    }

    /// Simulate client disconnect.
    public func emitClose() {
        let handler = state.withLock { $0.closeHandler }
        handler?()
    }

    /// Simulate client transport error.
    public func emitError(_ error: any Error) {
        let handler = state.withLock { $0.errorHandler }
        handler?(error)
    }
}

/// Deterministic in-memory `SSHTransportDriver` enabling full-stack SSH server
/// testing on every Swift platform (including iOS and WASI) with zero sockets.
public final class InMemorySSHTransportDriver: SSHTransportDriver, @unchecked Sendable {
    private struct State: Sendable {
        var listening: Bool = false
        var host: String = "127.0.0.1"
        var port: Int = 0
        var nextEphemeralPort: Int = 22000
        var hostKeys: [String] = []
        var onConnection: (@Sendable (any SSHClientConnection) -> Void)? = nil
        var onError: (@Sendable (any Error) -> Void)? = nil
        var bindError: (any Error)? = nil
    }

    private let state = Mutex(State())

    public init(bindError: (any Error)? = nil) {
        self.state.withLock { $0.bindError = bindError }
    }

    public var isListening: Bool {
        state.withLock { $0.listening }
    }

    public var configuredHostKeys: [String] {
        state.withLock { $0.hostKeys }
    }

    public func listen(
        port: Int,
        host: String,
        hostKeys: [String],
        onConnection: @escaping @Sendable (any SSHClientConnection) -> Void,
        onError: @escaping @Sendable (any Error) -> Void
    ) async throws -> (host: String, port: Int) {
        let result = state.withLock { s -> Result<(String, Int), any Error> in
            if let error = s.bindError {
                return .failure(error)
            }
            let assignedPort: Int
            if port == 0 {
                assignedPort = s.nextEphemeralPort
                s.nextEphemeralPort += 1
            } else {
                assignedPort = port
            }
            s.listening = true
            s.host = host
            s.port = assignedPort
            s.hostKeys = hostKeys
            s.onConnection = onConnection
            s.onError = onError
            return .success((host, assignedPort))
        }
        return try result.get()
    }

    public func close() async {
        state.withLock { s in
            s.listening = false
            s.onConnection = nil
            s.onError = nil
        }
    }

    /// Inject a simulated client connection into the listening server.
    @discardableResult
    public func connect(
        remoteAddress: SSHRemoteAddress = SSHRemoteAddress(address: "127.0.0.1", port: 54321),
        noDelayHook: (@Sendable (InMemorySSHClientConnection, Bool) throws -> Void)? = nil
    ) -> InMemorySSHClientConnection {
        let client = InMemorySSHClientConnection(remoteAddress: remoteAddress, noDelayHook: noDelayHook)
        let listener = state.withLock { $0.onConnection }
        listener?(client)
        return client
    }

    /// Simulate a server-level transport error.
    public func emitServerError(_ error: any Error) {
        let handler = state.withLock { $0.onError }
        handler?(error)
    }
}
