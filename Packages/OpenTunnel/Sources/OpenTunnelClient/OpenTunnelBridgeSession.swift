import Foundation
import Synchronization

// MARK: - Concurrency Primitives

/// Cancellation-safe one-shot async gate carrying `Result<Void, any Error>`.
internal final class OpenTunnelAsyncResultGate: Sendable {
    private struct State: Sendable {
        var result: Result<Void, any Error>? = nil
        var nextID: UInt64 = 1
        var waiters: [UInt64: CheckedContinuation<Result<Void, any Error>, Never>] = [:]
    }

    private let state = Mutex(State())

    func resolve(_ result: Result<Void, any Error>) {
        let waiters: [CheckedContinuation<Result<Void, any Error>, Never>] = state.withLock { s in
            guard s.result == nil else { return [] }
            s.result = result
            let pending = Array(s.waiters.values)
            s.waiters.removeAll()
            return pending
        }
        for w in waiters {
            w.resume(returning: result)
        }
    }

    func wait() async throws {
        if let immediate = state.withLock({ $0.result }) {
            return try immediate.get()
        }
        if Task.isCancelled { throw CancellationError() }
        let waiterID = state.withLock { s -> UInt64 in
            let id = s.nextID
            s.nextID += 1
            return id
        }
        let outcome: Result<Void, any Error> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate: Result<Void, any Error>? = state.withLock { s in
                    if let resolved = s.result { return resolved }
                    if Task.isCancelled { return .failure(CancellationError()) }
                    s.waiters[waiterID] = continuation
                    return nil
                }
                if let immediate {
                    continuation.resume(returning: immediate)
                }
            }
        } onCancel: {
            let removed = state.withLock { $0.waiters.removeValue(forKey: waiterID) }
            removed?.resume(returning: .failure(CancellationError()))
        }
        return try outcome.get()
    }
}

/// Wakeable sleep primitive used by the tunnel reconnect loop (wakes immediately on `close()` or `setRoutes()`).
internal final class OpenTunnelWakeSignal: Sendable {
    private struct State: Sendable {
        var generation: UInt64 = 0
        var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
        var nextID: UInt64 = 1
    }

    private let state = Mutex(State())

    func wake() {
        let waiters: [CheckedContinuation<Void, Never>] = state.withLock { s in
            s.generation &+= 1
            let list = Array(s.waiters.values)
            s.waiters.removeAll()
            return list
        }
        for w in waiters { w.resume() }
    }

    func sleep(milliseconds: Int) async {
        guard milliseconds > 0 else { return }
        let startGen = state.withLock { $0.generation }
        let waiterID = state.withLock { s -> UInt64 in
            let id = s.nextID
            s.nextID += 1
            return id
        }
        let timerTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(milliseconds))
            self?.resumeWaiter(id: waiterID)
        }
        defer { timerTask.cancel() }

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let shouldResumeNow = state.withLock { s -> Bool in
                    if s.generation != startGen || Task.isCancelled {
                        return true
                    }
                    s.waiters[waiterID] = continuation
                    return false
                }
                if shouldResumeNow {
                    continuation.resume()
                }
            }
        } onCancel: {
            resumeWaiter(id: waiterID)
        }
    }

    private func resumeWaiter(id: UInt64) {
        let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
        waiter?.resume()
    }
}

// MARK: - Running Tunnel Manager (`@opentunnel/client/src/effect/tunnel.ts`)

internal enum OpenTunnelSessionEnd: Sendable {
    case shutdown
    case routesChanged
    case fatal(OpenTunnelClientError)
    case retry(error: String, attached: Bool)
}

/// Manages the persistent OpenTunnel bridge lifecycle: route claiming, heartbeat/ping-pong,
/// reverse-proxy forwarding to local targets, dynamic route updates, periodic certificate
/// renewal, automatic reconnection with capped jittered backoff, and graceful shutdown.
internal final class OpenTunnelRunningTunnel: Sendable {
    private struct MutableState: Sendable {
        var identity: OpenTunnelIdentity
        var routes: [String: OpenTunnelRoute]
        var resolved: [String: OpenTunnelResolvedRoute]
        var statusState: OpenTunnelStatus.State = .connecting
        var sessionID: String? = nil
        var activeConnections: Int = 0
        var lastError: String? = nil
        var connectedAtEpochMs: Int64? = nil
        var shutdown: Bool = false
        var activeSession: OpenTunnelBridgeSession? = nil
    }

    private let apiURL: String
    private let transport: any OpenTunnelTransport
    private let tlsAdapter: (any OpenTunnelTLSAdapter)?
    private let explicitProxy: String?
    private let environment: [String: String]
    private let timing: OpenTunnelTimingConfiguration
    private let onRouteConflict: OpenTunnelRouteConflictPolicy
    private let onEvent: @Sendable (OpenTunnelClientEvent) -> Void
    private let onRenewed: (@Sendable (OpenTunnelIdentity) async -> Void)?

    private let state: Mutex<MutableState>
    private let wakeSignal = OpenTunnelWakeSignal()
    private let readyGate = OpenTunnelAsyncResultGate()
    private let closedGate = OpenTunnelAsyncResultGate()
    private let runTaskBox: Mutex<Task<Void, Never>?> = Mutex(nil)
    private let refreshTaskBox: Mutex<Task<Void, Never>?> = Mutex(nil)

    init(
        apiURL: String,
        identity: OpenTunnelIdentity,
        routes: [String: OpenTunnelRoute],
        resolved: [String: OpenTunnelResolvedRoute],
        transport: any OpenTunnelTransport,
        tlsAdapter: (any OpenTunnelTLSAdapter)?,
        explicitProxy: String?,
        environment: [String: String],
        timing: OpenTunnelTimingConfiguration,
        onRouteConflict: OpenTunnelRouteConflictPolicy,
        onEvent: @escaping @Sendable (OpenTunnelClientEvent) -> Void,
        onRenewed: (@Sendable (OpenTunnelIdentity) async -> Void)?
    ) {
        self.apiURL = apiURL
        self.transport = transport
        self.tlsAdapter = tlsAdapter
        self.explicitProxy = explicitProxy
        self.environment = environment
        self.timing = timing
        self.onRouteConflict = onRouteConflict
        self.onEvent = onEvent
        self.onRenewed = onRenewed
        self.state = Mutex(MutableState(identity: identity, routes: routes, resolved: resolved))

        let mainTask = Task<Void, Never> { [weak self] in
            await self?.runLoop()
        }
        self.runTaskBox.withLock { $0 = mainTask }

        let certTask = Task<Void, Never> { [weak self] in
            await self?.refreshCertificateLoop()
        }
        self.refreshTaskBox.withLock { $0 = certTask }
    }

    var currentIdentity: OpenTunnelIdentity {
        state.withLock { $0.identity }
    }

    func getStatus() -> OpenTunnelStatus {
        state.withLock { s in
            OpenTunnelStatus(
                state: s.statusState,
                hostname: s.identity.hostname,
                routes: s.routes,
                session: s.sessionID,
                connections: s.activeConnections,
                lastError: s.lastError,
                connectedAtEpochMs: s.connectedAtEpochMs
            )
        }
    }

    func getURLs() -> [String: String] {
        state.withLock { s in
            OpenTunnelNames.publicURLs(routes: s.routes, hostname: s.identity.hostname)
        }
    }

    func waitReady() async throws {
        try await readyGate.wait()
    }

    func waitClosed() async throws {
        try await closedGate.wait()
    }

    func setRoutes(_ routes: [String: OpenTunnelRoute]) throws(OpenTunnelClientError) {
        let resolved = try OpenTunnelRouteValidation.validateRoutes(routes)
        let sessionToRestart: OpenTunnelBridgeSession? = state.withLock { s in
            let prevNames = s.routes.keys.sorted()
            let nextNames = routes.keys.sorted()
            s.routes = routes
            s.resolved = resolved
            return prevNames == nextNames ? nil : s.activeSession
        }
        if let sessionToRestart {
            sessionToRestart.end(.routesChanged)
        }
        wakeSignal.wake()
    }

    func close() async {
        let sessionToStop: OpenTunnelBridgeSession? = state.withLock { s in
            s.shutdown = true
            return s.activeSession
        }
        let refreshTask = refreshTaskBox.withLock { t -> Task<Void, Never>? in
            let prev = t
            t = nil
            return prev
        }
        refreshTask?.cancel()
        sessionToStop?.end(.shutdown)
        wakeSignal.wake()
        try? await closedGate.wait()
    }

    // MARK: - Main Reconnect Loop

    private func runLoop() async {
        var attempt = 0
        do {
            while true {
                let (isShutdown, routesSnapshot, identitySnapshot) = state.withLock { s in
                    (s.shutdown, s.routes, s.identity)
                }
                if isShutdown || Task.isCancelled {
                    break
                }
                if routesSnapshot.isEmpty {
                    state.withLock { $0.statusState = .waitingRoutes }
                    await wakeSignal.sleep(milliseconds: 60_000)
                    continue
                }

                state.withLock { $0.statusState = .connecting }
                onEvent(.connecting(attempt: attempt))

                let session = OpenTunnelBridgeSession(
                    apiURL: apiURL,
                    identity: identitySnapshot,
                    routeNames: routesSnapshot.keys.sorted(),
                    transport: transport,
                    tlsAdapter: tlsAdapter,
                    explicitProxy: explicitProxy,
                    environment: environment,
                    timing: timing,
                    onRouteConflict: onRouteConflict,
                    resolveRoute: { [weak self] name in
                        self?.state.withLock { $0.resolved[name] }
                    },
                    currentIdentity: { [weak self] in
                        self?.state.withLock { $0.identity } ?? identitySnapshot
                    },
                    onAttached: { [weak self] sessionID, attachedRoutes in
                        guard let self else { return }
                        self.state.withLock { s in
                            s.statusState = .connected
                            s.sessionID = sessionID
                            s.lastError = nil
                            s.connectedAtEpochMs = OpenTunnelTimestamp.nowEpochMilliseconds()
                        }
                        self.readyGate.resolve(.success(()))
                        self.onEvent(.connected(session: sessionID, routes: attachedRoutes))
                    },
                    onConnectionsChanged: { [weak self] count in
                        self?.state.withLock { $0.activeConnections = count }
                    },
                    onEvent: onEvent
                )
                state.withLock { $0.activeSession = session }

                let outcome = await session.run()

                state.withLock { s in
                    if s.activeSession === session {
                        s.activeSession = nil
                    }
                    s.sessionID = nil
                    s.activeConnections = 0
                }

                switch outcome {
                case .shutdown:
                    state.withLock { $0.statusState = .stopped }
                    onEvent(.stopped(error: nil))
                    readyGate.resolve(.success(()))
                    closedGate.resolve(.success(()))
                    return

                case .fatal(let fatalError):
                    throw fatalError

                case .routesChanged:
                    onEvent(.disconnected(reason: "routes changed"))
                    attempt = 0
                    continue

                case let .retry(reason, wasAttached):
                    if state.withLock({ $0.shutdown }) || Task.isCancelled {
                        break
                    }
                    if wasAttached { attempt = 0 }
                    onEvent(.disconnected(reason: reason))
                    let delay = computeReconnectBackoffMs(attempt: attempt)
                    attempt += 1
                    state.withLock { s in
                        s.statusState = .reconnecting
                        s.lastError = reason
                    }
                    onEvent(.reconnecting(attempt: attempt, delayMs: delay))
                    await wakeSignal.sleep(milliseconds: delay)
                }
            }

            state.withLock { $0.statusState = .stopped }
            onEvent(.stopped(error: nil))
            readyGate.resolve(.success(()))
            closedGate.resolve(.success(()))
        } catch let clientError as OpenTunnelClientError {
            state.withLock { s in
                s.statusState = .stopped
                s.lastError = clientError.message
            }
            onEvent(.stopped(error: clientError.message))
            readyGate.resolve(.failure(clientError))
            closedGate.resolve(.failure(clientError))
        } catch {
            let wrapped = OpenTunnelClientError(message: String(describing: error), cause: error)
            state.withLock { s in
                s.statusState = .stopped
                s.lastError = wrapped.message
            }
            onEvent(.stopped(error: wrapped.message))
            readyGate.resolve(.failure(wrapped))
            closedGate.resolve(.failure(wrapped))
        }
    }

    private func computeReconnectBackoffMs(attempt: Int) -> Int {
        let shift = min(max(attempt, 0), 16)
        let base = min(timing.reconnectBackoffMinMs * (1 << shift), timing.reconnectBackoffMaxMs)
        let half = base / 2
        if half <= 0 { return max(base, 1) }
        return half + Int.random(in: 0...half)
    }

    // MARK: - Periodic Certificate Renewal Check

    private func refreshCertificateLoop() async {
        while !Task.isCancelled {
            let (isShutdown, identity) = state.withLock { ($0.shutdown, $0.identity) }
            if isShutdown { return }

            await checkCertificateOnce(identity: identity)

            if state.withLock({ $0.shutdown }) || Task.isCancelled { return }
            let latest = state.withLock { $0.identity }
            let due = latest.needsCertificateRenewal(renewalWindowSeconds: timing.renewalWindowSeconds)
            let intervalMs = due ? timing.certificateCheckDueMs : timing.certificateCheckFreshMs
            try? await Task.sleep(for: .milliseconds(max(intervalMs, 10)))
        }
    }

    private func checkCertificateOnce(identity: OpenTunnelIdentity) async {
        guard let url = buildCertificateURL(apiURL: apiURL, tunnelID: identity.id) else { return }
        let proxy: OpenTunnelProxyConfig?
        do {
            proxy = try OpenTunnelProxyResolver.resolveProxy(
                for: url,
                explicitProxy: explicitProxy,
                environment: environment
            )
        } catch {
            return
        }
        let req = OpenTunnelHTTPRequest(
            method: "GET",
            url: url,
            headers: [
                "authorization": "Bearer \(identity.token)",
                "user-agent": OpenTunnelClientModule.userAgent,
            ],
            proxy: proxy
        )
        guard let resp = try? await transport.sendHTTP(req),
              (200..<300).contains(resp.statusCode),
              let certInfo = try? JSONDecoder().decode(OpenTunnelCertificateInfo.self, from: Data(resp.body)),
              case let .ready(certificate, chain, expiry) = certInfo.state,
              !certificate.isEmpty,
              certificate != identity.certificate
        else {
            return
        }
        let renewed = identity.withRenewedCertificate(certificate: certificate, chain: chain, expiry: expiry)
        state.withLock { $0.identity = renewed }
        if let onRenewed {
            await onRenewed(renewed)
        }
        onEvent(.certificateRenewed(expiry: expiry))
    }

    private func buildCertificateURL(apiURL: String, tunnelID: String) -> String? {
        let base = apiURL.hasSuffix("/") ? String(apiURL.dropLast()) : apiURL
        let encodedID = tunnelID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tunnelID
        return "\(base)/api/tunnel/\(encodedID)/certificate"
    }
}

// MARK: - Single Bridge WebSocket Session

internal final class OpenTunnelBridgeSession: Sendable {
    private struct SessionState: Sendable {
        var finished = false
        var attached = false
        var lastReceivedMs: Int64 = OpenTunnelTimestamp.nowEpochMilliseconds()
        var socket: (any OpenTunnelWebSocket)? = nil
        var channels: [UInt32: OpenTunnelBridgeChannel] = [:]
        var outcome: OpenTunnelSessionEnd? = nil
        var endContinuation: CheckedContinuation<OpenTunnelSessionEnd, Never>? = nil
        var attachTimeoutTask: Task<Void, Never>? = nil
        var heartbeatTask: Task<Void, Never>? = nil
        var readTask: Task<Void, Never>? = nil
    }

    private let apiURL: String
    private let identity: OpenTunnelIdentity
    private let routeNames: [String]
    private let transport: any OpenTunnelTransport
    private let tlsAdapter: (any OpenTunnelTLSAdapter)?
    private let explicitProxy: String?
    private let environment: [String: String]
    private let timing: OpenTunnelTimingConfiguration
    private let onRouteConflict: OpenTunnelRouteConflictPolicy
    private let resolveRoute: @Sendable (String) -> OpenTunnelResolvedRoute?
    private let currentIdentity: @Sendable () -> OpenTunnelIdentity
    private let onAttached: @Sendable (String, [String]) -> Void
    private let onConnectionsChanged: @Sendable (Int) -> Void
    private let onEvent: @Sendable (OpenTunnelClientEvent) -> Void

    private let state = Mutex(SessionState())

    init(
        apiURL: String,
        identity: OpenTunnelIdentity,
        routeNames: [String],
        transport: any OpenTunnelTransport,
        tlsAdapter: (any OpenTunnelTLSAdapter)?,
        explicitProxy: String?,
        environment: [String: String],
        timing: OpenTunnelTimingConfiguration,
        onRouteConflict: OpenTunnelRouteConflictPolicy,
        resolveRoute: @escaping @Sendable (String) -> OpenTunnelResolvedRoute?,
        currentIdentity: @escaping @Sendable () -> OpenTunnelIdentity,
        onAttached: @escaping @Sendable (String, [String]) -> Void,
        onConnectionsChanged: @escaping @Sendable (Int) -> Void,
        onEvent: @escaping @Sendable (OpenTunnelClientEvent) -> Void
    ) {
        self.apiURL = apiURL
        self.identity = identity
        self.routeNames = routeNames
        self.transport = transport
        self.tlsAdapter = tlsAdapter
        self.explicitProxy = explicitProxy
        self.environment = environment
        self.timing = timing
        self.onRouteConflict = onRouteConflict
        self.resolveRoute = resolveRoute
        self.currentIdentity = currentIdentity
        self.onAttached = onAttached
        self.onConnectionsChanged = onConnectionsChanged
        self.onEvent = onEvent
    }

    func run() async -> OpenTunnelSessionEnd {
        let wsURL = buildBridgeWebSocketURL(apiURL: apiURL, tunnelID: identity.id)
        let proxy: OpenTunnelProxyConfig?
        do {
            proxy = try OpenTunnelProxyResolver.resolveProxy(
                for: wsURL,
                explicitProxy: explicitProxy,
                environment: environment
            )
        } catch let proxyError {
            return .fatal(proxyError)
        }

        let socket: any OpenTunnelWebSocket
        do {
            socket = try await transport.openWebSocket(
                url: wsURL,
                protocols: [OpenTunnelBridgeProtocol.webSocketSubprotocol],
                headers: ["user-agent": OpenTunnelClientModule.userAgent],
                proxy: proxy
            )
        } catch let clientError as OpenTunnelClientError {
            if clientError.isFatal {
                return .fatal(clientError)
            }
            return .retry(error: clientError.message, attached: false)
        } catch {
            if OpenTunnelError.isFatalError(error) {
                return .fatal(OpenTunnelClientError(message: String(describing: error), cause: error))
            }
            return .retry(error: String(describing: error), attached: false)
        }

        let alreadyEnded: OpenTunnelSessionEnd? = state.withLock { s in
            if s.finished { return s.outcome }
            s.socket = socket
            return nil
        }
        if let alreadyEnded {
            await socket.close(code: 1000, reason: "")
            return alreadyEnded
        }

        let attachTimeout = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(max(self.timing.connectTimeoutMs, 10)))
            if Task.isCancelled { return }
            let isAttached = self.state.withLock { $0.attached }
            if !isAttached {
                self.end(.retry(error: "bridge attach timed out", attached: false))
            }
        }
        state.withLock { $0.attachTimeoutTask = attachTimeout }

        // Start read loop before sending attach so fast responses are never missed.
        let reader = Task<Void, Never> { [weak self] in
            await self?.readLoop(socket: socket)
        }
        state.withLock { $0.readTask = reader }

        // Send initial `attach` control frame.
        let attachMsg = OpenTunnelClientControlMessage.attach(
            token: identity.token,
            transport: "ws",
            routes: routeNames,
            client: OpenTunnelBridgeClientInfo(
                version: OpenTunnelClientModule.version,
                maxConns: timing.maxConns
            )
        )
        do {
            let encoded = try OpenTunnelBridgeProtocol.encodeClientMessage(attachMsg)
            try await socket.send(.text(encoded))
        } catch {
            end(.retry(error: "failed to send attach: \(error)", attached: false))
        }

        return await withCheckedContinuation { continuation in
            let immediate: OpenTunnelSessionEnd? = state.withLock { s in
                if let outcome = s.outcome { return outcome }
                s.endContinuation = continuation
                return nil
            }
            if let immediate {
                continuation.resume(returning: immediate)
            }
        }
    }

    func end(_ outcome: OpenTunnelSessionEnd) {
        let (continuation, socket, channels, tasks): (
            CheckedContinuation<OpenTunnelSessionEnd, Never>?,
            (any OpenTunnelWebSocket)?,
            [OpenTunnelBridgeChannel],
            [Task<Void, Never>]
        ) = state.withLock { s in
            guard !s.finished else { return (nil, nil, [], []) }
            s.finished = true
            s.outcome = outcome
            let cont = s.endContinuation
            s.endContinuation = nil
            let sock = s.socket
            s.socket = nil
            let activeChannels = Array(s.channels.values)
            s.channels.removeAll()
            var cancelList: [Task<Void, Never>] = []
            if let t = s.attachTimeoutTask { cancelList.append(t); s.attachTimeoutTask = nil }
            if let t = s.heartbeatTask { cancelList.append(t); s.heartbeatTask = nil }
            if let t = s.readTask { cancelList.append(t); s.readTask = nil }
            return (cont, sock, activeChannels, cancelList)
        }

        for t in tasks { t.cancel() }
        for channel in channels {
            channel.destroy(code: "bridge disconnected", notifyServer: false)
        }
        if let socket {
            Task { await socket.close(code: 1000, reason: "") }
        }
        continuation?.resume(returning: outcome)
    }

    func sendControl(_ message: OpenTunnelClientControlMessage) {
        guard let socket = state.withLock({ $0.finished ? nil : $0.socket }),
              let encoded = try? OpenTunnelBridgeProtocol.encodeClientMessage(message)
        else { return }
        Task {
            try? await socket.send(.text(encoded))
        }
    }

    func sendData(conn: UInt32, payload: [UInt8]) async throws {
        guard let socket = state.withLock({ $0.finished ? nil : $0.socket }) else {
            throw OpenTunnelClientError.transient("bridge closed")
        }
        var offset = 0
        while offset < payload.count {
            let endIdx = min(offset + OpenTunnelBridgeProtocol.maxDataPayloadSize, payload.count)
            let chunk = Array(payload[offset..<endIdx])
            let frame = OpenTunnelBridgeProtocol.buildDataFrame(conn: conn, payload: chunk)
            try await socket.send(.binary(frame))
            offset = endIdx
        }
    }

    func channelClosed(_ channel: OpenTunnelBridgeChannel, error: String?) {
        let remainingCount: Int? = state.withLock { s in
            guard s.channels[channel.conn] === channel else { return nil }
            s.channels.removeValue(forKey: channel.conn)
            return s.channels.count
        }
        if let remainingCount {
            onConnectionsChanged(remainingCount)
            onEvent(.connectionClosed(conn: channel.conn, route: channel.route, error: error))
        }
    }

    // MARK: - Incoming WebSocket Read Loop

    private func readLoop(socket: any OpenTunnelWebSocket) async {
        do {
            for try await frame in socket.incoming {
                if Task.isCancelled || state.withLock({ $0.finished }) { break }
                state.withLock { $0.lastReceivedMs = OpenTunnelTimestamp.nowEpochMilliseconds() }
                switch frame {
                case .text(let text):
                    handleControlText(text)
                case .binary(let bytes):
                    handleBinaryFrame(bytes)
                case let .close(code, reason):
                    let attached = state.withLock { $0.attached }
                    let detail = reason.isEmpty ? "\(code)" : "\(code) \(reason)"
                    end(.retry(error: "bridge closed: \(detail)", attached: attached))
                    return
                }
            }
            let attached = state.withLock { $0.attached }
            end(.retry(error: "bridge closed: EOF", attached: attached))
        } catch {
            let attached = state.withLock { $0.attached }
            end(.retry(error: "bridge error: \(error)", attached: attached))
        }
    }

    private func handleControlText(_ text: String) {
        guard let message = OpenTunnelBridgeProtocol.decodeServerMessage(text) else {
            return
        }
        let isAttached = state.withLock { $0.attached }
        if !isAttached {
            switch message {
            case let .attached(sessionID, routes, heartbeatMs, idleTimeoutMs):
                let effectiveHeartbeat = max(heartbeatMs, timing.minHeartbeatMs)
                let effectiveIdle = max(idleTimeoutMs, timing.minIdleTimeoutMs)
                let hbTask = Task<Void, Never> { [weak self] in
                    await self?.heartbeatLoop(heartbeatMs: effectiveHeartbeat, idleTimeoutMs: effectiveIdle)
                }
                let attachTimeout = state.withLock { s -> Task<Void, Never>? in
                    s.attached = true
                    s.heartbeatTask = hbTask
                    let t = s.attachTimeoutTask
                    s.attachTimeoutTask = nil
                    return t
                }
                attachTimeout?.cancel()
                onAttached(sessionID, routes)

            case .attachError(let code):
                let isConflict = code == OpenTunnelBridgeErrorCode.routeConflict
                if isConflict {
                    onEvent(.routeConflict(routes: routeNames))
                }
                let attachErr = OpenTunnelAttachError(code: code)
                if attachErr.isFatalAttachCode || (isConflict && onRouteConflict == .fail) {
                    end(.fatal(OpenTunnelClientError.attachFailed(attachErr, prefix: "Failed to connect tunnel")))
                } else {
                    end(.retry(error: "attach failed: \(code)", attached: false))
                }

            default:
                return
            }
            return
        }

        switch message {
        case let .open(conn, peer, sni, _):
            openChannel(conn: conn, peer: peer, sni: sni)
        case .end(let conn):
            state.withLock { $0.channels[conn] }?.endInbound()
        case let .reset(conn, code):
            state.withLock { $0.channels[conn] }?.destroy(code: code, notifyServer: false)
        case .ping(let timeSent):
            sendControl(.pong(timeSent: timeSent))
        case .pong:
            break
        case .drain(let reason):
            end(.retry(error: "server draining: \(reason)", attached: true))
        case .attached, .attachError, .unknown:
            break
        }
    }

    private func handleBinaryFrame(_ bytes: [UInt8]) {
        guard let parsed = OpenTunnelBridgeProtocol.parseDataFrame(bytes) else { return }
        state.withLock { $0.channels[parsed.conn] }?.pushInbound(parsed.payload)
    }

    private func openChannel(conn: UInt32, peer: String, sni: String) {
        let activeIdentity = currentIdentity()
        guard let route = OpenTunnelNames.routeForSNI(sni, hostname: activeIdentity.hostname),
              let resolved = resolveRoute(route)
        else {
            sendControl(.reset(conn: conn, code: OpenTunnelBridgeErrorCode.unknownRoute))
            return
        }

        let currentCount = state.withLock { $0.channels.count }
        if currentCount >= timing.maxConns {
            sendControl(.reset(conn: conn, code: OpenTunnelBridgeErrorCode.tooManyConnections))
            return
        }

        let preamble: [UInt8]? = resolved.proxyProtocol.map { version in
            OpenTunnelProxyProtocolHeader.encode(version: version, peer: peer, sni: sni)
        }

        let channel = OpenTunnelBridgeChannel(
            conn: conn,
            route: route,
            sni: sni,
            target: resolved.target,
            preamble: preamble,
            identity: activeIdentity,
            stalledChannelBytes: timing.stalledChannelBytes,
            transport: transport,
            tlsAdapter: tlsAdapter,
            session: self
        )

        let newCount: Int? = state.withLock { s in
            guard !s.finished else { return nil }
            s.channels[conn] = channel
            return s.channels.count
        }
        guard let newCount else {
            channel.destroy(code: "bridge disconnected", notifyServer: false)
            return
        }
        onConnectionsChanged(newCount)
        onEvent(.connectionOpened(conn: conn, route: route, peer: peer))
        channel.start()
    }

    private func heartbeatLoop(heartbeatMs: Int, idleTimeoutMs: Int) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(heartbeatMs))
            if Task.isCancelled || state.withLock({ $0.finished }) { return }
            let now = OpenTunnelTimestamp.nowEpochMilliseconds()
            let lastReceived = state.withLock { $0.lastReceivedMs }
            if now - lastReceived > Int64(idleTimeoutMs) {
                end(.retry(error: "bridge idle timeout", attached: true))
                return
            }
            sendControl(.ping(timeSent: now))
        }
    }

    private func buildBridgeWebSocketURL(apiURL: String, tunnelID: String) -> String {
        var base = apiURL.hasSuffix("/") ? String(apiURL.dropLast()) : apiURL
        if base.hasPrefix("https://") {
            base = "wss://" + base.dropFirst("https://".count)
        } else if base.hasPrefix("http://") {
            base = "ws://" + base.dropFirst("http://".count)
        }
        let encodedID = tunnelID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tunnelID
        return "\(base)/api/tunnel/\(encodedID)/connect"
    }
}

// MARK: - Per-Connection Reverse-Proxy Forwarding Channel

internal final class OpenTunnelBridgeChannel: Sendable {
    private struct ChannelState: Sendable {
        var done = false
        weak var session: OpenTunnelBridgeSession? = nil
        var localStream: (any OpenTunnelByteStream)? = nil
        var tlsSession: (any OpenTunnelTLSSession)? = nil
        var pendingInbound: [[UInt8]] = []
        var pendingInboundBytes: Int = 0
        var inboundEnded = false
        var pumpTask: Task<Void, Never>? = nil
        var writeQueue: [[UInt8]] = []
        var drainingWrites = false
    }

    let conn: UInt32
    let route: String
    private let sni: String
    private let target: OpenTunnelTarget
    private let preamble: [UInt8]?
    private let identity: OpenTunnelIdentity
    private let stalledChannelBytes: Int
    private let transport: any OpenTunnelTransport
    private let tlsAdapter: (any OpenTunnelTLSAdapter)?
    private let state: Mutex<ChannelState>

    init(
        conn: UInt32,
        route: String,
        sni: String,
        target: OpenTunnelTarget,
        preamble: [UInt8]?,
        identity: OpenTunnelIdentity,
        stalledChannelBytes: Int,
        transport: any OpenTunnelTransport,
        tlsAdapter: (any OpenTunnelTLSAdapter)?,
        session: OpenTunnelBridgeSession
    ) {
        self.conn = conn
        self.route = route
        self.sni = sni
        self.target = target
        self.preamble = preamble
        self.identity = identity
        self.stalledChannelBytes = stalledChannelBytes
        self.transport = transport
        self.tlsAdapter = tlsAdapter
        self.state = Mutex(ChannelState(session: session))
    }

    private var currentSession: OpenTunnelBridgeSession? {
        state.withLock { $0.session }
    }

    func start() {
        let task = Task<Void, Never> { [weak self] in
            await self?.runChannel()
        }
        state.withLock { $0.pumpTask = task }
    }

    func pushInbound(_ payload: [UInt8]) {
        enum Action {
            case ignore
            case stalled
            case writeDirect(any OpenTunnelByteStream)
            case feedTLS(any OpenTunnelTLSSession)
            case queued
        }

        let action: Action = state.withLock { s in
            if s.done { return .ignore }
            if let tls = s.tlsSession {
                return .feedTLS(tls)
            }
            if let local = s.localStream {
                if s.drainingWrites || !s.writeQueue.isEmpty {
                    s.pendingInboundBytes += payload.count
                    if s.pendingInboundBytes > stalledChannelBytes {
                        return .stalled
                    }
                    s.writeQueue.append(payload)
                    return .queued
                }
                s.drainingWrites = true
                return .writeDirect(local)
            }
            s.pendingInboundBytes += payload.count
            if s.pendingInboundBytes > stalledChannelBytes {
                return .stalled
            }
            s.pendingInbound.append(payload)
            return .queued
        }

        switch action {
        case .ignore, .queued:
            return
        case .stalled:
            destroy(code: OpenTunnelBridgeErrorCode.upstreamIOError, notifyServer: true, error: "local connection stalled")
        case .feedTLS(let tls):
            Task { [weak self] in
                do {
                    try await tls.feedEncrypted(payload)
                } catch {
                    self?.destroy(code: OpenTunnelBridgeErrorCode.upstreamIOError, notifyServer: true, error: String(describing: error))
                }
            }
        case .writeDirect(let local):
            Task { [weak self] in
                await self?.drainLocalWrites(firstChunk: payload, local: local)
            }
        }
    }

    func endInbound() {
        enum Action {
            case ignore
            case finishTLS(any OpenTunnelTLSSession)
            case finishDirect(any OpenTunnelByteStream)
            case markEnded
        }

        let action: Action = state.withLock { s in
            if s.done { return .ignore }
            s.inboundEnded = true
            if let tls = s.tlsSession {
                return .finishTLS(tls)
            }
            if let local = s.localStream, !s.drainingWrites, s.writeQueue.isEmpty {
                return .finishDirect(local)
            }
            return .markEnded
        }

        switch action {
        case .ignore, .markEnded:
            return
        case .finishTLS(let tls):
            Task { await tls.finishInbound() }
        case .finishDirect(let local):
            Task { await local.finishWriting() }
        }
    }

    func destroy(code: String, notifyServer: Bool, error: String? = nil) {
        let shouldNotify = !state.withLock { $0.done }
        if shouldNotify && notifyServer {
            currentSession?.sendControl(.reset(conn: conn, code: code))
        }
        finish(error: error ?? code)
    }

    // MARK: - Private Channel Pump

    private func runChannel() async {
        let local: any OpenTunnelByteStream
        do {
            local = try await transport.openLocalConnection(target: target)
        } catch {
            destroy(
                code: OpenTunnelBridgeErrorCode.upstreamConnectFailed,
                notifyServer: true,
                error: String(describing: error)
            )
            return
        }

        if let preamble, !preamble.isEmpty {
            do {
                try await local.write(preamble)
            } catch {
                await local.close()
                destroy(
                    code: OpenTunnelBridgeErrorCode.upstreamIOError,
                    notifyServer: true,
                    error: String(describing: error)
                )
                return
            }
        }

        // Check if a TLS adapter is configured and should wrap the stream.
        if let tlsAdapter {
            do {
                let tlsSession = try await tlsAdapter.createServerSession(
                    identity: identity,
                    sni: sni,
                    sendEncrypted: { [weak self] encrypted in
                        guard let self, let session = self.currentSession else { return }
                        try await session.sendData(conn: self.conn, payload: encrypted)
                    },
                    onPlaintext: { plaintext in
                        try await local.write(plaintext)
                    },
                    onClosed: { [weak self] reason in
                        self?.finish(error: reason)
                    }
                )
                let (queued, ended, alreadyDone): ([[UInt8]], Bool, Bool) = state.withLock { s in
                    if s.done { return ([], false, true) }
                    s.localStream = local
                    s.tlsSession = tlsSession
                    let pending = s.pendingInbound
                    s.pendingInbound.removeAll()
                    s.pendingInboundBytes = 0
                    return (pending, s.inboundEnded, false)
                }
                if alreadyDone {
                    await tlsSession.close()
                    await local.close()
                    return
                }
                for chunk in queued {
                    try await tlsSession.feedEncrypted(chunk)
                }
                if ended {
                    await tlsSession.finishInbound()
                }
                do {
                    for try await chunk in local.incoming {
                        if Task.isCancelled || state.withLock({ $0.done }) { break }
                        try await tlsSession.writePlaintext(chunk)
                    }
                    await tlsSession.finishOutbound()
                    if !state.withLock({ $0.done }) {
                        currentSession?.sendControl(.end(conn: conn))
                        finish(error: nil)
                    }
                } catch {
                    destroy(
                        code: OpenTunnelBridgeErrorCode.upstreamIOError,
                        notifyServer: true,
                        error: String(describing: error)
                    )
                }
                return
            } catch {
                await local.close()
                destroy(
                    code: OpenTunnelBridgeErrorCode.upstreamIOError,
                    notifyServer: true,
                    error: String(describing: error)
                )
                return
            }
        }

        // Direct full-duplex reverse-proxy forwarding (HTTP/1.1, SSE, and WebSocket upgrades).
        let (queued, ended, alreadyDone): ([[UInt8]], Bool, Bool) = state.withLock { s in
            if s.done { return ([], false, true) }
            s.localStream = local
            let pending = s.pendingInbound
            s.pendingInbound.removeAll()
            s.pendingInboundBytes = 0
            if !pending.isEmpty {
                s.drainingWrites = true
            }
            return (pending, s.inboundEnded, false)
        }
        if alreadyDone {
            await local.close()
            return
        }

        if !queued.isEmpty {
            Task { [weak self] in
                await self?.drainInitialChunks(queued, local: local)
            }
        } else if ended {
            await local.finishWriting()
        }

        do {
            for try await chunk in local.incoming {
                if Task.isCancelled || state.withLock({ $0.done }) { break }
                guard let session = currentSession else { break }
                try await session.sendData(conn: conn, payload: chunk)
            }
            if !state.withLock({ $0.done }) {
                currentSession?.sendControl(.end(conn: conn))
                finish(error: nil)
            }
        } catch {
            if !state.withLock({ $0.done }) {
                destroy(
                    code: OpenTunnelBridgeErrorCode.upstreamIOError,
                    notifyServer: true,
                    error: String(describing: error)
                )
            }
        }
    }

    private func drainInitialChunks(_ initial: [[UInt8]], local: any OpenTunnelByteStream) async {
        do {
            for chunk in initial {
                if state.withLock({ $0.done }) { return }
                try await local.write(chunk)
            }
        } catch {
            destroy(code: OpenTunnelBridgeErrorCode.upstreamIOError, notifyServer: true, error: String(describing: error))
            return
        }
        await continueDrainingWrites(local: local)
    }

    private func drainLocalWrites(firstChunk: [UInt8], local: any OpenTunnelByteStream) async {
        do {
            try await local.write(firstChunk)
        } catch {
            destroy(code: OpenTunnelBridgeErrorCode.upstreamIOError, notifyServer: true, error: String(describing: error))
            return
        }
        await continueDrainingWrites(local: local)
    }

    private func continueDrainingWrites(local: any OpenTunnelByteStream) async {
        while true {
            let (nextChunk, shouldFinish): ([UInt8]?, Bool) = state.withLock { s in
                if s.done {
                    s.drainingWrites = false
                    s.writeQueue.removeAll()
                    s.pendingInboundBytes = 0
                    return (nil, false)
                }
                if !s.writeQueue.isEmpty {
                    let chunk = s.writeQueue.removeFirst()
                    s.pendingInboundBytes = max(0, s.pendingInboundBytes - chunk.count)
                    return (chunk, false)
                }
                s.drainingWrites = false
                return (nil, s.inboundEnded)
            }
            if let chunk = nextChunk {
                do {
                    try await local.write(chunk)
                } catch {
                    destroy(code: OpenTunnelBridgeErrorCode.upstreamIOError, notifyServer: true, error: String(describing: error))
                    return
                }
            } else {
                if shouldFinish {
                    await local.finishWriting()
                }
                return
            }
        }
    }

    private func finish(error: String?) {
        let (shouldFinish, sessionRef, local, tls, pumpTask): (
            Bool,
            OpenTunnelBridgeSession?,
            (any OpenTunnelByteStream)?,
            (any OpenTunnelTLSSession)?,
            Task<Void, Never>?
        ) = state.withLock { s in
            guard !s.done else { return (false, nil, nil, nil, nil) }
            s.done = true
            let sess = s.session
            let l = s.localStream
            let t = s.tlsSession
            let p = s.pumpTask
            s.session = nil
            s.localStream = nil
            s.tlsSession = nil
            s.pumpTask = nil
            s.pendingInbound.removeAll()
            s.writeQueue.removeAll()
            s.pendingInboundBytes = 0
            return (true, sess, l, t, p)
        }
        guard shouldFinish else { return }
        pumpTask?.cancel()
        if let tls {
            Task { await tls.close() }
        }
        if let local {
            Task { await local.close() }
        }
        sessionRef?.channelClosed(self, error: error)
    }
}
