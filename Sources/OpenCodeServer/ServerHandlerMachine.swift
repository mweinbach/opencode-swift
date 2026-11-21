#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodeCore
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeUtil

// MARK: - Machine Routes & WebSocket Link (`packages/server/src/handlers/machine.ts`)

/// Machine HTTP and WebSocket link handlers (`server/src/handlers/machine.ts`).
public enum ServerMachine {
    /// Handshakes in progress across the server: what strangers can hold open at once, each for at most ten seconds.
    public static let maxHandshakes = 32
    /// Noise's largest message, so nothing longer is ever a frame.
    public static let maxFrame = 65_535
    /// Noise's authentication tag, which every frame ends with, so nothing shorter is ever a frame.
    public static let minFrame = 16
    /// Maximum unread bytes allowed from a single socket pull (`Frames.MAX_MESSAGE` = 16 MiB).
    public static let maxWaiting = 16 * 1024 * 1024
    /// How long a send waits on a peer that takes none of what the socket already holds.
    public static let stallDuration: Duration = .seconds(60)
    /// How often a served link is pinged. A peer not heard from since the last ping is gone within two intervals.
    public static let pingInterval: Duration = .seconds(30)
    /// How long a machine that got past the handshake has to answer the home's close before its connection is dropped.
    public static let closingTimeout: Duration = .seconds(5)
    /// How long a stopping server gives every link at once to answer the close, so no peer can keep it from stopping.
    public static let stoppingTimeout: Duration = .seconds(1)
    /// Policy violation, the code RFC 6455 gives for hiding the reason. Every close the home makes carries it and no
    /// reason: a refused handshake, a bad frame, a removed machine and a shutdown look the same.
    public static let closeCode = 1008

    /// Events observed by `keepalive` on a WebSocket `Transport`.
    public enum TransportEvent: String, Equatable, Hashable, Sendable {
        case pong
        case ping
        case message
    }

    /// Opaque token used to remove a listener registered on `Transport`.
    public struct TransportListenerToken: Equatable, Hashable, Sendable {
        public let rawValue: UInt64
        public init(rawValue: UInt64) { self.rawValue = rawValue }
    }

    /// What the carrier and the keepalive use of a WebSocket transport.
    // parity: server/src/handlers/machine.ts#Transport [status=implemented hash=a68225fbab76]
    public protocol Transport: Sendable {
        var bufferedAmount: Int { get }
        /// Whether reading is stopped because enough already waits unread. Nothing the peer sends is seen meanwhile.
        var isPaused: Bool { get }
        /// Calls back once the socket has taken the message, or cannot.
        func send(_ message: [UInt8], taken: @escaping @Sendable () -> Void)
        func ping()
        @discardableResult
        func on(_ event: TransportEvent, _ listener: @escaping @Sendable () -> Void) -> TransportListenerToken
        func off(_ event: TransportEvent, _ token: TransportListenerToken)
        /// Drops the connection at once, sending nothing more.
        func terminate()
    }

    /// Inbound frame batch returned by a `SocketReader`, matching Effect `Socket.Reader.pull`.
    public enum SocketFrame: Equatable, Sendable {
        case binary([UInt8])
        case text(String)

        public var byteLength: Int {
            switch self {
            case .binary(let bytes): return bytes.count
            case .text(let s): return s.utf8.count
            }
        }
    }

    /// Reader interface pulled by `ServerMachine.carrier` (mirroring Effect `Socket.Reader`).
    public protocol SocketReader: Sendable {
        func pull() async throws -> [SocketFrame]
    }

    /// Tracks active WebSocket clients for the machine link endpoint, supporting test observation (`Watch`)
    /// and bounded shutdown (`stoppingTimeout`).
    public final class SocketServer: Sendable {
        private struct State {
            var nextID: UInt64 = 0
            var clients: [UInt64: WebSocketTransport] = [:]
            var closed = false
        }

        private let state = Mutex(State())

        public init() {}

        public var clientCount: Int {
            state.withLock { $0.clients.count }
        }

        public var isClosed: Bool {
            state.withLock { $0.closed }
        }

        func register(_ transport: WebSocketTransport) -> UInt64? {
            state.withLock { s in
                guard !s.closed else { return nil }
                s.nextID += 1
                let id = s.nextID
                s.clients[id] = transport
                return id
            }
        }

        func unregister(_ id: UInt64) {
            state.withLock { _ = $0.clients.removeValue(forKey: id) }
        }

        /// Sends close code 1008 to all active links and terminates any still connected after `timeout`.
        public func closeAll(timeout: Duration = ServerMachine.stoppingTimeout) async {
            let active: [WebSocketTransport] = state.withLock { s in
                s.closed = true
                return Array(s.clients.values)
            }
            for client in active {
                client.close(code: ServerMachine.closeCode)
            }
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while ContinuousClock.now < deadline {
                if clientCount == 0 { return }
                try? await Task.sleep(for: .milliseconds(10))
            }
            let remaining: [WebSocketTransport] = state.withLock { Array($0.clients.values) }
            for client in remaining {
                client.terminate()
            }
        }
    }

    /// Only for tests, as `MachineLink.Fixed` is: called with the endpoint's socket server when it is made, so a test
    /// can count its clients and watch sockets from the home's side. Production never sets it.
    // parity: server/src/handlers/machine.ts#Watch [status=adapted hash=7d1d380ef96d]
    public enum Watch {
        public static let key = "@opencode/MachineLink/Watch"
        @TaskLocal public static var current: (@Sendable (SocketServer) -> Void)? = nil
    }

    /// Concrete `Transport` & `SocketReader` bridging a `ServerWebSocketConnection` with frame-size guards (`MIN_FRAME` /
    /// `MAX_FRAME`), buffered-amount tracking, event listeners, and graceful/forced close semantics.
    public final class WebSocketTransport: Transport, SocketReader, Sendable {
        private struct State {
            var nextToken: UInt64 = 0
            var listeners: [TransportEvent: [UInt64: @Sendable () -> Void]] = [:]
            var queue: [SocketFrame] = []
            var waiters: [(id: UInt64, continuation: CheckedContinuation<[SocketFrame], any Error>)] = []
            var nextWaiterID: UInt64 = 0
            var bufferedBytes: Int = 0
            var paused: Bool = false
            var closed: Bool = false
            var closeWaiters: [CheckedContinuation<Void, Never>] = []
        }

        private let socket: any ServerWebSocketConnection
        private let state = Mutex(State())
        private let pumpTask: Mutex<Task<Void, Never>?> = Mutex(nil)

        public init(socket: any ServerWebSocketConnection) {
            self.socket = socket
            let task = Task { [weak self] in
                for await frame in socket.incoming {
                    guard let self else { break }
                    switch frame {
                    case .binary(let bytes):
                        self.emit(.message)
                        if bytes.count < ServerMachine.minFrame || bytes.count > ServerMachine.maxFrame {
                            self.drop()
                            return
                        }
                        self.enqueue(.binary(bytes))
                    case .text(let s):
                        self.emit(.message)
                        if s.utf8.count < ServerMachine.minFrame || s.utf8.count > ServerMachine.maxFrame {
                            self.drop()
                            return
                        }
                        self.enqueue(.text(s))
                    case .close:
                        self.markClosed()
                        return
                    }
                }
                self?.markClosed()
            }
            pumpTask.withLock { $0 = task }
        }

        deinit {
            let task = pumpTask.withLock { current -> Task<Void, Never>? in
                let existing = current
                current = nil
                return existing
            }
            task?.cancel()
        }

        public var bufferedAmount: Int {
            state.withLock { $0.bufferedBytes }
        }

        public var isPaused: Bool {
            state.withLock { $0.paused }
        }

        public var isClosed: Bool {
            state.withLock { $0.closed }
        }

        public func send(_ message: [UInt8], taken: @escaping @Sendable () -> Void) {
            let alreadyClosed = state.withLock { s -> Bool in
                if s.closed { return true }
                s.bufferedBytes += message.count
                return false
            }
            if alreadyClosed {
                taken()
                return
            }
            let count = message.count
            Task { [weak self] in
                defer {
                    self?.state.withLock { s in
                        s.bufferedBytes = max(0, s.bufferedBytes - count)
                    }
                    taken()
                }
                try? await self?.socket.send(.binary(message))
            }
        }

        public func ping() {
            // In-process `ServerWebSocketConnection` does not expose RFC 6455 control ping frames separately;
            // live socket activity (`message`/`pong`) keeps the link alive via event callbacks.
        }

        /// Triggers a synthetic transport event (used by tests and control-frame handlers).
        public func emit(_ event: TransportEvent) {
            let callbacks: [@Sendable () -> Void] = state.withLock { s in
                Array((s.listeners[event] ?? [:]).values)
            }
            for cb in callbacks {
                cb()
            }
        }

        @discardableResult
        public func on(_ event: TransportEvent, _ listener: @escaping @Sendable () -> Void) -> TransportListenerToken {
            state.withLock { s in
                s.nextToken += 1
                let id = s.nextToken
                s.listeners[event, default: [:]][id] = listener
                return TransportListenerToken(rawValue: id)
            }
        }

        public func off(_ event: TransportEvent, _ token: TransportListenerToken) {
            state.withLock { s in
                _ = s.listeners[event]?.removeValue(forKey: token.rawValue)
            }
        }

        public func close(code: Int = ServerMachine.closeCode) {
            Task { [socket] in
                await socket.close(code: code, reason: "")
            }
        }

        public func drop() {
            close(code: ServerMachine.closeCode)
            terminate()
        }

        public func terminate() {
            let task = pumpTask.withLock { current -> Task<Void, Never>? in
                let existing = current
                current = nil
                return existing
            }
            task?.cancel()
            markClosed()
            Task { [socket] in
                await socket.close(code: ServerMachine.closeCode, reason: "")
            }
        }

        public func awaitClosed(timeout: Duration) async {
            if isClosed { return }
            let timedOut = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        let immediate = self.state.withLock { s -> Bool in
                            if s.closed { return true }
                            s.closeWaiters.append(cont)
                            return false
                        }
                        if immediate { cont.resume() }
                    }
                    return false
                }
                group.addTask {
                    try? await Task.sleep(for: timeout)
                    return true
                }
                let first = await group.next() ?? true
                group.cancelAll()
                return first
            }
            if timedOut {
                terminate()
            }
        }

        private func enqueue(_ frame: SocketFrame) {
            let waiter: CheckedContinuation<[SocketFrame], any Error>? = state.withLock { s in
                if s.closed { return nil }
                if !s.waiters.isEmpty {
                    return s.waiters.removeFirst().continuation
                }
                s.queue.append(frame)
                return nil
            }
            waiter?.resume(returning: [frame])
        }

        private func markClosed() {
            let (waiters, closeWaiters) = state.withLock { s -> ([CheckedContinuation<[SocketFrame], any Error>], [CheckedContinuation<Void, Never>]) in
                guard !s.closed else { return ([], []) }
                s.closed = true
                let w = s.waiters.map(\.continuation)
                let cw = s.closeWaiters
                s.waiters.removeAll()
                s.closeWaiters.removeAll()
                return (w, cw)
            }
            for waiter in waiters {
                waiter.resume(throwing: MachineLink.Closed())
            }
            for cw in closeWaiters {
                cw.resume()
            }
        }

        public func pull() async throws -> [SocketFrame] {
            let id = state.withLock { s -> UInt64 in
                s.nextWaiterID += 1
                return s.nextWaiterID
            }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[SocketFrame], any Error>) in
                    let immediate: Result<[SocketFrame], any Error>? = state.withLock { s in
                        if !s.queue.isEmpty {
                            let batch = s.queue
                            s.queue.removeAll(keepingCapacity: true)
                            return .success(batch)
                        }
                        if s.closed {
                            return .failure(MachineLink.Closed())
                        }
                        if Task.isCancelled {
                            return .failure(CancellationError())
                        }
                        s.waiters.append((id: id, continuation: continuation))
                        return nil
                    }
                    if let immediate {
                        continuation.resume(with: immediate)
                    }
                }
            } onCancel: {
                let cancelled: CheckedContinuation<[SocketFrame], any Error>? = state.withLock { s in
                    guard let idx = s.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                    return s.waiters.remove(at: idx).continuation
                }
                cancelled?.resume(throwing: CancellationError())
            }
        }
    }

    /// Whether the `machines` flag is on in the server's base configuration, where the video routes read theirs.
    // parity: server/src/handlers/machine.ts#machinesEnabled [status=implemented hash=a2fb7315dadd]
    public static func machinesEnabled(runtime: ServerAppRuntime) -> @Sendable () async -> Bool {
        {
            do {
                let configDir = runtime.global.config
                let loc: ServerLocationBundle
                if await runtime.fileSystem.exists(at: configDir) {
                    loc = try await runtime.resolveLocation(
                        LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: configDir))
                    )
                } else {
                    loc = try await runtime.resolveLocation(
                        LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: runtime.defaultDirectory))
                    )
                }
                return await loc.flag.enabled(.machines)
            } catch {
                return false
            }
        }
    }

    /// Upgrades a WebSocket request on the endpoint's socket server, enforcing `MIN_FRAME`/`MAX_FRAME`
    /// and closing with `1008` (and bounded `CLOSING` timeout) when `body` finishes.
    // parity: server/src/handlers/machine.ts#upgrade [status=adapted hash=117e6e7511de]
    public static func upgrade<R: Sendable>(
        sockets: SocketServer,
        performUpgrade: @Sendable () async throws -> any ServerWebSocketConnection,
        closingTimeout: Duration = ServerMachine.closingTimeout,
        _ body: (WebSocketTransport) async throws -> R
    ) async throws -> R {
        guard !sockets.isClosed else { throw MachineLink.Closed() }
        let socket: any ServerWebSocketConnection
        do {
            socket = try await performUpgrade()
        } catch {
            throw MachineLink.Closed()
        }
        let transport = WebSocketTransport(socket: socket)
        guard let registrationID = sockets.register(transport) else {
            transport.drop()
            throw MachineLink.Closed()
        }
        do {
            let result = try await body(transport)
            transport.close(code: ServerMachine.closeCode)
            await transport.awaitClosed(timeout: closingTimeout)
            sockets.unregister(registrationID)
            return result
        } catch {
            transport.close(code: ServerMachine.closeCode)
            await transport.awaitClosed(timeout: closingTimeout)
            sockets.unregister(registrationID)
            throw error
        }
    }

    private final class SendLatch: Sendable {
        private struct State {
            var done = false
            var waiters: [CheckedContinuation<Void, Never>] = []
        }

        private let state = Mutex(State())

        func open() {
            let waiters: [CheckedContinuation<Void, Never>] = state.withLock { s in
                guard !s.done else { return [] }
                s.done = true
                let copy = s.waiters
                s.waiters.removeAll()
                return copy
            }
            for w in waiters { w.resume() }
        }

        func awaitOpen() async {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let already = state.withLock { s -> Bool in
                    if s.done { return true }
                    s.waiters.append(cont)
                    return false
                }
                if already { cont.resume() }
            }
        }
    }

    private final class CarrierBox: MachineLink.Carrier, Sendable {
        private let reader: any SocketReader
        private let transport: any Transport
        private let stallTimeout: Duration
        private let waiting = Mutex<[SocketFrame]>([])

        var describe: (@Sendable () -> MachineDriver.ConnectionInfo)? {
            { MachineDriver.ConnectionInfo(kind: .websocket) }
        }

        init(reader: any SocketReader, transport: any Transport, stallTimeout: Duration) {
            self.reader = reader
            self.transport = transport
            self.stallTimeout = stallTimeout
        }

        func send(_ message: [UInt8]) async {
            let latch = SendLatch()
            transport.send(message) {
                latch.open()
            }

            while !Task.isCancelled {
                let held = transport.bufferedAmount
                let completed = await withTaskGroup(of: Bool.self) { group in
                    group.addTask {
                        await latch.awaitOpen()
                        return true
                    }
                    group.addTask { [stallTimeout] in
                        try? await Task.sleep(for: stallTimeout)
                        return false
                    }
                    let first = await group.next() ?? false
                    group.cancelAll()
                    return first
                }
                if completed { return }
                // A close frame would wait behind what the peer is not reading.
                if transport.bufferedAmount >= held {
                    transport.terminate()
                    return
                }
            }
        }

        func receive() async throws -> [UInt8] {
            if let next = waiting.withLock({ q -> SocketFrame? in
                q.isEmpty ? nil : q.removeFirst()
            }) {
                switch next {
                case .binary(let bytes): return bytes
                case .text: throw MachineLink.Closed()
                }
            }
            let batch: [SocketFrame]
            do {
                batch = try await reader.pull()
            } catch {
                throw MachineLink.Closed()
            }
            let totalBytes = batch.reduce(0) { $0 + $1.byteLength }
            if totalBytes > ServerMachine.maxWaiting {
                throw MachineLink.Closed()
            }
            let first: SocketFrame? = waiting.withLock { q in
                q.append(contentsOf: batch)
                return q.isEmpty ? nil : q.removeFirst()
            }
            guard let frame = first, case .binary(let bytes) = frame else {
                throw MachineLink.Closed()
            }
            return bytes
        }
    }

    /// A WebSocket transport as `MachineLink.Carrier`, read through `SocketReader`. A text message or a pull exceeding
    /// `MAX_WAITING` ends the carrier with `MachineLink.Closed`. `send` waits for socket handoff and terminates a peer
    /// that makes no progress for `stallTimeout`.
    // parity: server/src/handlers/machine.ts#carrier [status=implemented hash=c49e524b52d2]
    public static func carrier(
        reader: any SocketReader,
        transport: any Transport,
        stallTimeout: Duration = ServerMachine.stallDuration
    ) -> any MachineLink.Carrier {
        CarrierBox(reader: reader, transport: transport, stallTimeout: stallTimeout)
    }

    /// The idle limit of a served link: pings the peer every `interval` and drops the connection once a whole interval
    /// passes with nothing from it. While reading is paused none of that can be seen, so an interval is held against the
    /// peer only if reading was paused at neither end of it.
    // parity: server/src/handlers/machine.ts#keepalive [status=implemented hash=70b77ad69729]
    public static func keepalive(
        _ transport: any Transport,
        interval: Duration = ServerMachine.pingInterval
    ) async {
        let state = Mutex((heard: true, paused: false))
        let events: [TransportEvent] = [.pong, .ping, .message]
        let tokens = events.map { event in
            (event, transport.on(event) {
                state.withLock { $0.heard = true }
            })
        }
        defer {
            for (event, token) in tokens {
                transport.off(event, token)
            }
        }
        while !Task.isCancelled {
            let shouldContinue = state.withLock { s -> Bool in
                let ok = s.heard || s.paused || transport.isPaused
                if ok {
                    s.heard = false
                    s.paused = transport.isPaused
                }
                return ok
            }
            guard shouldContinue else { break }
            transport.ping()
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
        }
        if !Task.isCancelled {
            transport.terminate()
        }
    }

    /// Non-blocking permit counter matching Effect's `Semaphore.withPermitsIfAvailable(1)` for `MAX_HANDSHAKES`.
    private final class HandshakeSemaphore: Sendable {
        private let available: Mutex<Int>
        init(limit: Int) { self.available = Mutex(limit) }

        func tryAcquire() -> Bool {
            available.withLock { count in
                guard count > 0 else { return false }
                count -= 1
                return true
            }
        }

        func release() {
            available.withLock { $0 += 1 }
        }
    }

    /// `machine.link` in the `server.experimental` group: the WebSocket where a machine's link lands.
    /// Returns 404 unless the request is a WebSocket upgrade AND the `machines` flag is enabled;
    /// returns 503 when all `MAX_HANDSHAKES` slots are busy; closes quietly with 1008 on any handshake/protocol error.
    // parity: server/src/handlers/machine.ts#makeMachineLink [status=adapted hash=dfbf7f0beda0]
    public static func makeMachineLink(
        maxHandshakes: Int = ServerMachine.maxHandshakes,
        pingInterval: Duration = ServerMachine.pingInterval,
        closingTimeout: Duration = ServerMachine.closingTimeout
    ) -> @Sendable (ServerRouteContext) async throws -> ServerHTTPResponse {
        struct PerRuntime {
            let handshakes: HandshakeSemaphore
            let sockets: SocketServer
        }
        let runtimeTable = Mutex<[ObjectIdentifier: PerRuntime]>([:])

        return { ctx in
            guard isWebSocketUpgrade(method: ctx.request.method, headers: ctx.request.headers),
                  let upgradeFn = ctx.request.upgradeWebSocket,
                  await machinesEnabled(runtime: ctx.runtime)()
            else {
                return ServerHTTPResponse.empty(statusCode: 404)
            }

            let key = ObjectIdentifier(ctx.runtime)
            let entry: PerRuntime = runtimeTable.withLock { table in
                if let existing = table[key] { return existing }
                let created = PerRuntime(
                    handshakes: HandshakeSemaphore(limit: maxHandshakes),
                    sockets: SocketServer()
                )
                table[key] = created
                Watch.current?(created.sockets)
                return created
            }

            guard entry.handshakes.tryAcquire() else {
                return ServerHTTPResponse.empty(statusCode: 503)
            }
            let handshakeReleased = Mutex(false)
            let releaseHandshake: @Sendable () -> Void = {
                let shouldRelease = handshakeReleased.withLock { done -> Bool in
                    guard !done else { return false }
                    done = true
                    return true
                }
                if shouldRelease {
                    entry.handshakes.release()
                }
            }
            defer { releaseHandshake() }

            do {
                try await upgrade(
                    sockets: entry.sockets,
                    performUpgrade: upgradeFn,
                    closingTimeout: closingTimeout
                ) { transport in
                    let linkCarrier = carrier(reader: transport, transport: transport)
                    let served: MachineLink.Served
                    do {
                        // The place is held until the handshake and hello have ended.
                        defer { releaseHandshake() }
                        served = try await MachineLink.serve(
                            linkCarrier,
                            identity: ctx.runtime.machineIdentity,
                            machines: ctx.runtime.machines
                        )
                    } catch {
                        // A stranger gives up its place with its connection: the time to answer a close is for machines.
                        transport.drop()
                        throw error
                    }
                    defer { served.close() }

                    let keepaliveTask = Task {
                        await keepalive(transport, interval: pingInterval)
                    }
                    defer { keepaliveTask.cancel() }

                    try? await ctx.runtime.machines.connect(served.machine, served.connection)
                }
            } catch {
                // A WebSocket handshake refused, a refused link, and a machine removed since it: one quiet close.
            }
            return ServerHTTPResponse(statusCode: 101, webSocketUpgraded: true)
        }
    }

    public struct MachineHandlers: Sendable {
        public let list: @Sendable (ServerRouteContext) async throws -> ServerHTTPResponse
        public let add: @Sendable (ServerRouteContext) async throws -> ServerHTTPResponse
        public let remove: @Sendable (ServerRouteContext) async throws -> ServerHTTPResponse
    }

    /// `machine.*` HTTP routes in the `server.experimental` group. Every route requires the `machines` flag.
    // parity: server/src/handlers/machine.ts#makeMachine [status=implemented hash=93f6e171ee23]
    public static func makeMachine(
        irohAvailable: (@Sendable () async -> Bool)? = nil
    ) -> MachineHandlers {
        @Sendable func requireEnabled(_ runtime: ServerAppRuntime) async throws {
            guard await machinesEnabled(runtime: runtime)() else {
                throw ForbiddenError(message: "Machines are disabled; enable experimental.machines")
            }
        }

        return MachineHandlers(
            list: { ctx in
                try await requireEnabled(ctx.runtime)
                let items = await ctx.runtime.machines.list().map { info in
                    OpenCodeProtocol.MachineInfo(
                        id: info.id,
                        online: info.online,
                        paired: info.paired,
                        os: info.os,
                        arch: info.arch,
                        connection: info.connection.map { connection in
                            OpenCodeProtocol.MachineInfo.Connection(
                                kind: connection.kind == .iroh ? .iroh : .websocket,
                                path: connection.path.map { $0 == .direct ? .direct : .relayed },
                                rtt: connection.rtt
                            )
                        }
                    )
                }
                return ServerHTTPResponse.json(ServerDataWrapper(data: items))
            },
            add: { ctx in
                try await requireEnabled(ctx.runtime)
                let payload = try ctx.decodeJSONBody(MachineAddPayload.self)
                let id: String
                do {
                    id = try await ctx.runtime.machines.add(payload.name)
                } catch let existing as Machines.AlreadyExists {
                    id = existing.machine
                } catch let invalid as Machines.InvalidName {
                    throw InvalidRequestError(message: invalid.message, kind: "invalid_name", field: "name")
                }

                var joinReach = payload.reach.map { MachineJoin.Reach.url($0.url) }
                if let irohAvailable, await irohAvailable() {
                    joinReach.append(.iroh)
                }
                let join: String
                do {
                    join = try await ctx.runtime.machines.invite(
                        id,
                        options: Machines.InviteOptions(reach: joinReach, replace: payload.replace ?? false)
                    )
                } catch let paired as Machines.AlreadyPaired {
                    throw ConflictError(message: paired.message, resource: paired.machine)
                } catch let missing as Machines.NotFound {
                    throw MachineNotFoundError(machine: missing.machine, message: missing.message)
                }

                guard let decoded = MachineJoin.decode(join) else {
                    throw UnknownError(message: "Server produced an unreadable join string")
                }
                let responseReach: [MachineInvite.ReachEntry] = decoded.reach.map { entry in
                    switch entry {
                    case .url(let url): return .url(url)
                    case .iroh: return .iroh
                    }
                }
                let invite = MachineInvite(
                    name: id,
                    join: join,
                    expires: decoded.expires,
                    reach: responseReach
                )
                return ServerHTTPResponse.json(ServerDataWrapper(data: invite))
            },
            remove: { ctx in
                try await requireEnabled(ctx.runtime)
                let name = try ctx.requireParam("name")
                let removed = try await ctx.runtime.machines.removeIfPresent(name)
                if !removed {
                    let quoted = (try? ServerCodec.encodeString(name)) ?? "\"\(name)\""
                    throw MachineNotFoundError(machine: name, message: "No machine named \(quoted).")
                }
                return ServerHTTPResponse.empty(statusCode: 204)
            }
        )
    }
}
