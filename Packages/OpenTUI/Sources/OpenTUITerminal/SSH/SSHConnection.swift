import Synchronization

// MARK: - Middleware Onion Execution (`run-session.ts`)

/// Erased middleware-chain type for the runtime.
// parity: ssh/src/run-session.ts#RuntimeMiddleware [status=implemented hash=f297c83f1d30]
public typealias SSHRuntimeMiddleware = @Sendable (any SSHMiddlewareSession, SSHNext) async throws -> SSHHandoff

/// Run the middleware onion around the handler for one session, then ensure the
/// session is closed once the chain settles.
///
/// `dispatch(index)` invokes middleware `index`; calling `next()` advances to
/// `index + 1` after merging any context updates into `session.context`. The
/// innermost `next()` calls `bridge.enterApp(handler)`, resolving at teardown so
/// post-`next()` / `defer` blocks run as teardown. Calling `next()` more than once
/// in a single middleware throws an error routed to `safe`.
///
/// `DenyError` is swallowed (because `deny()` already wrote the reason and closed
/// the session); any other error is reported via `safe`.
// parity: ssh/src/run-session.ts#runSession [status=implemented hash=9fec3ff46c53]
@discardableResult
public func runSession(
    middlewares: [SSHRuntimeMiddleware],
    handler: @escaping SSHSessionHandler,
    bridge: any SSHSessionBridge,
    safe: SSHSafeInvoke
) -> Task<Void, Never> {
    let session = bridge.session

    @Sendable
    func dispatch(_ index: Int) async throws -> SSHHandoff {
        if index == middlewares.count {
            try await bridge.enterApp(handler)
            return SSHHandoff()
        }
        let middleware = middlewares[index]
        let calledFlag = Mutex(false)
        let next = SSHNext { applyContext in
            let alreadyCalled = calledFlag.withLock { called -> Bool in
                if called { return true }
                called = true
                return false
            }
            if alreadyCalled {
                throw SshError(
                    code: "MIDDLEWARE",
                    message: "next() called more than once in a single middleware"
                )
            }
            applyContext(session.context)
            return try await dispatch(index + 1)
        }
        return try await middleware(session, next)
    }

    return Task {
        await safe {
            defer { session.end() }
            do {
                _ = try await dispatch(0)
            } catch {
                // `deny()` already wrote the reason and closed the session; the throw
                // only unwinds the chain, so swallow it. Anything else reports to `safe`.
                if !isDeny(error) {
                    throw error
                }
            }
        }
    }
}

// MARK: - Per-Connection Lifecycle (`connection.ts`)

/// Client `env` keys permitted to describe the remote terminal.
public let sshAllowedClientEnvKeys: Set<String> = [
    "COLORTERM",
    "OPENTUI_FORCE_TRUECOLOR",
    "TERM_PROGRAM",
    "TERM_PROGRAM_VERSION",
]

/// Normalize an IPv4-mapped IPv6 address (e.g. `"::ffff:127.0.0.1"` → `"127.0.0.1"`).
public func normalizeSSHRemoteAddress(_ address: String?, port: Int? = nil) -> SSHRemoteAddress {
    guard let address, !address.isEmpty else {
        return SSHRemoteAddress(address: "unknown", port: port)
    }
    if address.hasPrefix("::ffff:") {
        return SSHRemoteAddress(address: String(address.dropFirst("::ffff:".count)), port: port)
    }
    return SSHRemoteAddress(address: address, port: port)
}

/// Dependencies required by `createConnectionHandler(_:)`.
// parity: ssh/src/connection.ts#ConnectionDependencies [status=implemented hash=92a8ed1666e1]
public struct SSHConnectionDependencies: Sendable {
    public var authenticator: any SSHAuthenticator
    public var middlewares: [SSHRuntimeMiddleware]
    public var handler: SSHSessionHandler
    public var safe: SSHSafeInvoke
    public var idleTimeoutMs: Int?
    public var maxTimeoutMs: Int?
    public var sessionLimits: SSHResolvedSessionLimits
    public var createRenderer: SSHRendererFactory?
    public var onSignal: (@Sendable (any SSHSessionCommon, String) -> Void)?

    public init(
        authenticator: any SSHAuthenticator,
        middlewares: [SSHRuntimeMiddleware] = [],
        handler: @escaping SSHSessionHandler,
        safe: SSHSafeInvoke = createSafeInvoke { _ in },
        idleTimeoutMs: Int? = nil,
        maxTimeoutMs: Int? = nil,
        sessionLimits: SSHResolvedSessionLimits = SSHResolvedSessionLimits(perConnection: 1, global: 100),
        createRenderer: SSHRendererFactory? = nil,
        onSignal: (@Sendable (any SSHSessionCommon, String) -> Void)? = nil
    ) {
        self.authenticator = authenticator
        self.middlewares = middlewares
        self.handler = handler
        self.safe = safe
        self.idleTimeoutMs = idleTimeoutMs
        self.maxTimeoutMs = maxTimeoutMs
        self.sessionLimits = sessionLimits
        self.createRenderer = createRenderer
        self.onSignal = onSignal
    }
}

/// Controller returned by `createConnectionHandler(_:)`.
public final class SSHConnectionHandler: @unchecked Sendable {
    private struct TrackedBridge: Sendable {
        let clientID: ObjectIdentifier
        let bridge: any SSHSessionBridge
        let release: @Sendable () -> Void
    }

    private struct GlobalState: Sendable {
        var clients: [ObjectIdentifier: any SSHClientConnection] = [:]
        var bridges: [ObjectIdentifier: TrackedBridge] = [:]
        var activeSessions: Int = 0
        var acceptingSessions: Bool = false
    }

    private final class PerClientBox: Sendable {
        let mutex = Mutex(PerClientState())
    }

    private struct PerClientState: Sendable {
        var connected: Bool = true
        var connectionSessions: Int = 0
        var identity: SSHIdentity = .none(username: "unknown")
    }

    private struct PerSessionChannelState: Sendable {
        var pty: SSHPtyInfo = sshDefaultPty
        var env: [String: String] = [:]
        var activeBridge: (any SSHSessionBridge)? = nil
    }

    private let dependencies: SSHConnectionDependencies
    private let globalState = Mutex(GlobalState())

    internal init(dependencies: SSHConnectionDependencies) {
        self.dependencies = dependencies
    }

    /// Number of currently tracked live SSH client connections.
    public var connectionCount: Int {
        globalState.withLock { $0.clients.count }
    }

    /// Number of currently active shell sessions across all connections.
    public var activeSessionCount: Int {
        globalState.withLock { $0.activeSessions }
    }

    /// Toggle whether new shell channels are admitted.
    public func setAccepting(_ accepting: Bool) {
        globalState.withLock { $0.acceptingSessions = accepting }
    }

    /// Wire an incoming SSH client connection through authentication → session → shell.
    public func onConnection(_ client: any SSHClientConnection) {
        let clientID = ObjectIdentifier(client)
        let clientBox = PerClientBox()
        let remoteAddress = normalizeSSHRemoteAddress(client.remoteAddress.address, port: client.remoteAddress.port)

        globalState.withLock { $0.clients[clientID] = client }

        client.setAuthenticationHandler { [weak self] rawCtx in
            guard let self else { return }
            let outcome = await self.dependencies.authenticator.handle(rawCtx)
            let isConnected = clientBox.mutex.withLock { $0.connected }
            guard isConnected else { return }
            switch outcome {
            case .reject(let methods):
                rawCtx.reject(methods)
            case .acceptProbe:
                rawCtx.accept()
            case .accept(let identity):
                clientBox.mutex.withLock { $0.identity = identity }
                rawCtx.accept()
            }
        }

        client.setReadyHandler { [weak self, weak client] in
            guard let self, let client else { return }
            client.setSessionHandler { [weak self] sshSession in
                guard let self else { return }
                self.attachSessionChannel(
                    sshSession,
                    clientID: clientID,
                    clientBox: clientBox,
                    remoteAddress: remoteAddress
                )
            }
        }

        client.setCloseHandler { [weak self] in
            guard let self else { return }
            clientBox.mutex.withLock { $0.connected = false }
            let ownedBridges = self.globalState.withLock { state -> [any SSHSessionBridge] in
                state.clients.removeValue(forKey: clientID)
                return state.bridges.values
                    .filter { $0.clientID == clientID }
                    .map(\.bridge)
            }
            for bridge in ownedBridges {
                Task { await bridge.disconnect() }
            }
        }

        client.setErrorHandler { [weak self] error in
            self?.dependencies.safe.report(error)
        }

        // Disable Nagle's algorithm after close/error handlers are wired so any
        // transport failure preserves normal cleanup.
        dependencies.safe {
            try client.setNoDelay(true)
        }
    }

    private func attachSessionChannel(
        _ sshSession: any SSHSessionChannel,
        clientID: ObjectIdentifier,
        clientBox: PerClientBox,
        remoteAddress: SSHRemoteAddress
    ) {
        let sessionState = Mutex(PerSessionChannelState())

        sshSession.setEnvHandler { request in
            sessionState.withLock { s in
                if s.activeBridge != nil
                    || !sshAllowedClientEnvKeys.contains(request.key)
                    || !isClientEnvValue(request.value) {
                    return false
                }
                s.env[request.key] = request.value
                return true
            }
        }

        sshSession.setPtyHandler { request in
            sessionState.withLock { s in
                s.pty = SSHPtyInfo(
                    term: request.term,
                    cols: request.cols,
                    rows: request.rows,
                    hasPty: true
                )
            }
            return true
        }

        sshSession.setWindowChangeHandler { request in
            let bridge = sessionState.withLock { $0.activeBridge }
            bridge?.resize(cols: request.cols, rows: request.rows)
        }

        sshSession.setSignalHandler { [weak self] signalName in
            guard let self else { return }
            if let bridge = sessionState.withLock({ $0.activeBridge }),
               let onSignal = self.dependencies.onSignal {
                self.dependencies.safe {
                    onSignal(bridge.session, signalName)
                }
            }
        }

        sshSession.setShellHandler { [weak self] in
            guard let self else { return nil }
            let admitted = self.reserveSessionSlot(clientBox: clientBox)
            guard admitted else { return nil }

            let released = Mutex(false)
            let release: @Sendable () -> Void = { [weak self] in
                let shouldRelease = released.withLock { flag -> Bool in
                    if flag { return false }
                    flag = true
                    return true
                }
                guard shouldRelease else { return }
                if let self {
                    self.globalState.withLock { global in
                        clientBox.mutex.withLock { $0.connectionSessions = max(0, $0.connectionSessions - 1) }
                        global.activeSessions = max(0, global.activeSessions - 1)
                    }
                } else {
                    clientBox.mutex.withLock { $0.connectionSessions = max(0, $0.connectionSessions - 1) }
                }
            }

            // Note: For transports where `setShellHandler` returns a channel directly,
            // we return a proxy or accept channel via the dedicated `acceptShellChannel` helper.
            // Release immediately if called on an unsupported shell handler without a channel.
            release()
            return nil
        }

        // Support transports that invoke `acceptShell(channel:)` directly via `SSHChannelAcceptance`.
        if let directSession = sshSession as? any SSHDirectShellSessionChannel {
            directSession.setDirectShellHandler { [weak self] acceptChannel in
                guard let self else { return false }
                let admitted = self.reserveSessionSlot(clientBox: clientBox)
                guard admitted else { return false }

                let released = Mutex(false)
                let release: @Sendable () -> Void = { [weak self] in
                    let shouldRelease = released.withLock { flag -> Bool in
                        if flag { return false }
                        flag = true
                        return true
                    }
                    guard shouldRelease else { return }
                    if let self {
                        self.globalState.withLock { global in
                            clientBox.mutex.withLock { $0.connectionSessions = max(0, $0.connectionSessions - 1) }
                            global.activeSessions = max(0, global.activeSessions - 1)
                        }
                    } else {
                        clientBox.mutex.withLock { $0.connectionSessions = max(0, $0.connectionSessions - 1) }
                    }
                }

                var acceptedChannel: (any SSHChannel)? = nil
                do {
                    let channel = try acceptChannel()
                    acceptedChannel = channel
                    let (pty, env) = sessionState.withLock { ($0.pty, $0.env) }
                    let identity = clientBox.mutex.withLock { $0.identity }
                    let shellBridge = createSessionBridge(
                        channel: channel,
                        options: SSHSessionBridgeOptions(
                            pty: pty,
                            env: env,
                            identity: identity,
                            idleTimeoutMs: self.dependencies.idleTimeoutMs,
                            maxTimeoutMs: self.dependencies.maxTimeoutMs,
                            safe: self.dependencies.safe,
                            createRenderer: self.dependencies.createRenderer,
                            remoteAddress: remoteAddress
                        )
                    )
                    let bridgeID = ObjectIdentifier(shellBridge)
                    sessionState.withLock { $0.activeBridge = shellBridge }
                    self.globalState.withLock {
                        $0.bridges[bridgeID] = TrackedBridge(
                            clientID: clientID,
                            bridge: shellBridge,
                            release: release
                        )
                    }

                    sshSession.setCloseHandler {
                        Task { await shellBridge.disconnect() }
                    }

                    shellBridge.session.onClose { [weak self] in
                        Task { [weak self] in
                            await shellBridge.destroy()
                            release()
                            self?.globalState.withLock { _ = $0.bridges.removeValue(forKey: bridgeID) }
                        }
                    }

                    runSession(
                        middlewares: self.dependencies.middlewares,
                        handler: self.dependencies.handler,
                        bridge: shellBridge,
                        safe: self.dependencies.safe
                    )
                    return true
                } catch {
                    if let acceptedChannel {
                        ignoreErrors { acceptedChannel.close() }
                    }
                    release()
                    self.dependencies.safe.report(error)
                    return false
                }
            }
        }
    }

    private func reserveSessionSlot(clientBox: PerClientBox) -> Bool {
        globalState.withLock { global in
            guard global.acceptingSessions,
                  global.activeSessions < dependencies.sessionLimits.global else {
                return false
            }
            let admitted = clientBox.mutex.withLock { client -> Bool in
                guard client.connected,
                      client.connectionSessions < dependencies.sessionLimits.perConnection else {
                    return false
                }
                client.connectionSessions += 1
                return true
            }
            if admitted {
                global.activeSessions += 1
            }
            return admitted
        }
    }

    /// Stop admitting new shells, destroy all active bridges, release capacity,
    /// and force-close all connected clients.
    public func closeAll() async {
        let (trackedBridges, clients) = globalState.withLock {
            state -> ([TrackedBridge], [any SSHClientConnection]) in
            state.acceptingSessions = false
            return (Array(state.bridges.values), Array(state.clients.values))
        }

        await withTaskGroup(of: Void.self) { group in
            for tracked in trackedBridges {
                group.addTask {
                    await tracked.bridge.destroy()
                }
            }
        }

        for tracked in trackedBridges {
            tracked.release()
        }

        let remainingReleases = globalState.withLock { state -> [@Sendable () -> Void] in
            let releases = state.bridges.values.map(\.release)
            state.bridges.removeAll()
            state.clients.removeAll()
            return releases
        }
        for release in remainingReleases {
            release()
        }

        for client in clients {
            ignoreErrors { client.end() }
            ignoreErrors { client.forceClose() }
        }
    }
}

/// Extension protocol for `SSHSessionChannel` implementations that lazily accept
/// a shell channel only after the connection handler verifies session limits.
public protocol SSHDirectShellSessionChannel: SSHSessionChannel {
    func setDirectShellHandler(
        _ handler: (@Sendable (() throws -> any SSHChannel) -> Bool)?
    )
}

/// Build the per-connection SSH lifecycle controller (`onConnection`, `closeAll`, `setAccepting`).
// parity: ssh/src/connection.ts#createConnectionHandler [status=implemented hash=f93b325a2b5a]
public func createConnectionHandler(_ dependencies: SSHConnectionDependencies) -> SSHConnectionHandler {
    SSHConnectionHandler(dependencies: dependencies)
}
