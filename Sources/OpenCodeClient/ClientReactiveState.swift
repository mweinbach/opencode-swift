#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeUtil

// MARK: - Usage (packages/client/src/solid/usage.ts)

/// The assistant step whose tokens fill the context window now: the latest one after the last completed
/// compaction and before the revert boundary. Every client shows context usage from this step, so the TUI
/// and the desktop app agree on it.
// parity: client/src/solid/usage.ts#lastAssistantWithUsage [status=implemented hash=811d48db5764]
public func lastAssistantWithUsage(
    _ messages: [SessionMessageSchema.Info],
    boundary: String? = nil
) -> SessionMessageSchema.Assistant? {
    let end: Int
    if let boundary, !boundary.isEmpty {
        guard let boundaryIndex = messages.firstIndex(where: { $0.id.rawValue == boundary }) else {
            return nil
        }
        end = boundaryIndex
    } else {
        end = messages.count
    }

    var compactionIndex = -1
    if end > 0 {
        for idx in stride(from: end - 1, through: 0, by: -1) {
            if case .compaction(.completed) = messages[idx] {
                compactionIndex = idx
                break
            }
        }
    }

    if end > compactionIndex + 1 {
        for idx in stride(from: end - 1, through: max(0, compactionIndex + 1), by: -1) {
            if case .assistant(let assistant) = messages[idx], assistant.tokens != nil {
                return assistant
            }
        }
    }
    return nil
}

// MARK: - Persistent PTY Client (packages/client/src/solid/pty.ts)

/// Discriminated union of control messages pushed by a persistent PTY WebSocket endpoint.
// parity: client/src/solid/pty.ts#PersistentPtyMessage [status=implemented hash=18c89fe46ca1]
public enum PersistentPtyMessage: Equatable, Hashable, Sendable, Codable {
    public enum Role: String, Equatable, Hashable, Sendable, Codable {
        case controller
        case observer
    }

    public struct AttachedInfo: Equatable, Hashable, Sendable, Codable {
        public let size: PersistentPtySchema.Size

        public init(size: PersistentPtySchema.Size) {
            self.size = size
        }
    }

    case attached(inputProtocol: Int?, info: AttachedInfo, role: Role?)
    case replayComplete
    case resized(cols: Int, rows: Int, checkpoint: String)
    case controllerChanged(attachmentID: String?)
    case exited(exitCode: Int?)
    case titleChanged(title: String)
    case foregroundProcessChanged(process: String?)

    private enum CodingKeys: String, CodingKey {
        case type
        case inputProtocol
        case info
        case role
        case cols
        case rows
        case checkpoint
        case attachmentID
        case exitCode
        case title
        case process
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "attached":
            self = .attached(
                inputProtocol: try c.decodeIfPresent(Int.self, forKey: .inputProtocol),
                info: try c.decode(AttachedInfo.self, forKey: .info),
                role: try c.decodeIfPresent(Role.self, forKey: .role)
            )
        case "replay_complete":
            self = .replayComplete
        case "resized":
            self = .resized(
                cols: try c.decode(Int.self, forKey: .cols),
                rows: try c.decode(Int.self, forKey: .rows),
                checkpoint: try c.decode(String.self, forKey: .checkpoint)
            )
        case "controller_changed":
            let attachmentID: String?
            if c.contains(.attachmentID), try !c.decodeNil(forKey: .attachmentID) {
                attachmentID = try c.decode(String.self, forKey: .attachmentID)
            } else {
                attachmentID = nil
            }
            self = .controllerChanged(attachmentID: attachmentID)
        case "exited":
            let exitCode: Int?
            if c.contains(.exitCode), try !c.decodeNil(forKey: .exitCode) {
                exitCode = try c.decode(Int.self, forKey: .exitCode)
            } else {
                exitCode = nil
            }
            self = .exited(exitCode: exitCode)
        case "title_changed":
            self = .titleChanged(title: try c.decode(String.self, forKey: .title))
        case "foreground_process_changed":
            guard c.contains(.process) else {
                throw DecodingError.keyNotFound(
                    CodingKeys.process,
                    DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing process field")
                )
            }
            let process = try c.decode(String?.self, forKey: .process)
            self = .foregroundProcessChanged(process: process)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: c,
                debugDescription: "Unknown PersistentPtyMessage type '\(type)'"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .attached(let inputProtocol, let info, let role):
            try c.encode("attached", forKey: .type)
            try c.encodeIfPresent(inputProtocol, forKey: .inputProtocol)
            try c.encode(info, forKey: .info)
            try c.encodeIfPresent(role, forKey: .role)
        case .replayComplete:
            try c.encode("replay_complete", forKey: .type)
        case .resized(let cols, let rows, let checkpoint):
            try c.encode("resized", forKey: .type)
            try c.encode(cols, forKey: .cols)
            try c.encode(rows, forKey: .rows)
            try c.encode(checkpoint, forKey: .checkpoint)
        case .controllerChanged(let attachmentID):
            try c.encode("controller_changed", forKey: .type)
            try c.encode(attachmentID, forKey: .attachmentID)
        case .exited(let exitCode):
            try c.encode("exited", forKey: .type)
            try c.encode(exitCode, forKey: .exitCode)
        case .titleChanged(let title):
            try c.encode("title_changed", forKey: .type)
            try c.encode(title, forKey: .title)
        case .foregroundProcessChanged(let process):
            try c.encode("foreground_process_changed", forKey: .type)
            try c.encode(process, forKey: .process)
        }
    }
}

/// Decodes a JSON text frame from a persistent PTY WebSocket into `PersistentPtyMessage`, or `nil` when invalid.
// parity: client/src/solid/pty.ts#decodePersistentPtyMessage [status=implemented hash=8588454851c4]
public func decodePersistentPtyMessage(_ text: String) -> PersistentPtyMessage? {
    try? ClientCodec.decode(PersistentPtyMessage.self, from: text)
}

/// Encodes a binary persistent PTY input/resize frame:
/// `[kind (1 = data, 0 = resize), cols_hi, cols_lo, rows_hi, rows_lo, ...data]`.
// parity: client/src/solid/pty.ts#persistentPtyFrame [status=implemented hash=f3cf37d75f7a]
public func persistentPtyFrame(cols: Int, rows: Int, data: [UInt8]? = nil) -> [UInt8] {
    var frame: [UInt8] = []
    frame.reserveCapacity(5 + (data?.count ?? 0))
    frame.append(data != nil ? 1 : 0)
    let c = UInt16(truncatingIfNeeded: cols)
    let r = UInt16(truncatingIfNeeded: rows)
    frame.append(UInt8((c >> 8) & 0xFF))
    frame.append(UInt8(c & 0xFF))
    frame.append(UInt8((r >> 8) & 0xFF))
    frame.append(UInt8(r & 0xFF))
    if let data {
        frame.append(contentsOf: data)
    }
    return frame
}

/// Options for constructing a persistent PTY WebSocket client.
// parity: client/src/solid/pty.ts#PtyClientOptions [status=implemented hash=da647ce5bd8e]
public struct PtyClientOptions: Sendable {
    public let url: String
    public let webSocketFactory: any ClientWebSocketFactory

    public init(url: String, webSocketFactory: any ClientWebSocketFactory) {
        self.url = url
        self.webSocketFactory = webSocketFactory
    }
}

/// Input parameters for connecting to a persistent PTY session over WebSocket.
// parity: client/src/solid/pty.ts#PersistentPtyConnectInput [status=implemented hash=2a168e0f3616]
public struct PersistentPtyConnectInput: Equatable, Hashable, Sendable {
    public let ptyID: String
    public let cursor: Int
    public let attachmentID: String
    public let takeover: Bool?

    public init(ptyID: String, cursor: Int, attachmentID: String, takeover: Bool? = nil) {
        self.ptyID = ptyID
        self.cursor = cursor
        self.attachmentID = attachmentID
        self.takeover = takeover
    }
}

/// Persistent PTY WebSocket connector that exchanges a short-lived ticket and opens the binary WS stream.
public struct PersistentPtyClient: Sendable {
    private let api: OpenCodeClient
    private let options: PtyClientOptions

    public init(api: OpenCodeClient, options: PtyClientOptions) {
        self.api = api
        self.options = options
    }

    public func connect(_ input: PersistentPtyConnectInput) async throws -> any ClientWebSocket {
        let token = try await api.experimental.persistentPty.connectToken(
            ExperimentalPersistentPtyConnectTokenInput(
                ptyID: input.ptyID,
                xOpencodeTicket: PTY_CONNECT_TOKEN_HEADER_VALUE
            )
        )
        let path = "api/experimental/persistent-pty/\(ClientURLBuilder.encodeURIComponent(input.ptyID))/connect"
        let wsURL = ClientURLBuilder.webSocketURL(
            baseUrl: options.url,
            relativePath: path,
            query: [
                ("ticket", token.ticket),
                ("cursor", String(input.cursor)),
                ("attachment_id", input.attachmentID),
                ("takeover", (input.takeover ?? false) ? "true" : "false"),
                ("input_protocol", "1"),
            ]
        )
        return try await options.webSocketFactory.connect(url: wsURL, headers: [:])
    }
}

/// Creates a `PersistentPtyClient` bound to `api` and `options`.
// parity: client/src/solid/pty.ts#createPersistentPtyClient [status=implemented hash=9806815c3ebb]
public func createPersistentPtyClient(_ api: OpenCodeClient, options: PtyClientOptions) -> PersistentPtyClient {
    PersistentPtyClient(api: api, options: options)
}

// MARK: - Client Connection Store (packages/client/src/solid/connection.ts)

/// Live SSE connection lifecycle status.
// parity: client/src/solid/connection.ts#ClientConnectionStatus [status=implemented hash=0a49d06b61b1]
public enum ClientConnectionStatus: String, Equatable, Hashable, Sendable, Codable {
    case connected
    case connecting
    case reconnecting
}

/// Recorded connection lifecycle diagnostic event.
// parity: client/src/solid/connection.ts#ClientConnectionEvent [status=implemented hash=c13ae68b1fc8]
public struct ClientConnectionEvent: Equatable, Hashable, Sendable, Codable {
    public enum EventStatus: String, Equatable, Hashable, Sendable, Codable {
        case connecting
        case connected
        case disconnected
        case reconnecting
    }

    public struct EventData: Equatable, Hashable, Sendable, Codable {
        public let status: EventStatus
        public let attempt: Int
        public let error: String?

        public init(status: EventStatus, attempt: Int, error: String? = nil) {
            self.status = status
            self.attempt = attempt
            self.error = error
        }
    }

    public let type: String
    public let created: Int64
    public let data: EventData

    public init(created: Int64, data: EventData) {
        self.type = "client.connection"
        self.created = created
        self.data = data
    }
}

/// Optional logger hooks for `ClientConnection`.
public struct ClientConnectionLogger: Sendable {
    public let debug: (@Sendable (String, [String: JSONValue]) -> Void)?
    public let info: (@Sendable (String, [String: JSONValue]) -> Void)?

    public init(
        debug: (@Sendable (String, [String: JSONValue]) -> Void)? = nil,
        info: (@Sendable (String, [String: JSONValue]) -> Void)? = nil
    ) {
        self.debug = debug
        self.info = info
    }
}

/// Configuration for `createClientConnection`.
// parity: client/src/solid/connection.ts#ClientConnectionOptions [status=implemented hash=91139b129da7]
public struct ClientConnectionOptions: Sendable {
    public let reconnect: (@Sendable (AbortSignal) async throws -> OpenCodeClient)?
    public let onEvent: @Sendable (OpenCodeEvent) -> Void
    public let flushInterval: Int64
    public let pageLifecycle: Bool
    /// Abort and reconnect a stream that receives no bytes for this long (ms).
    public let idleTimeout: Int64
    public let connectTimeout: Int64
    public let reconnectDelay: Int64
    public let autoStart: Bool
    public let log: ClientConnectionLogger?
    public let now: @Sendable () -> Int64

    public init(
        reconnect: (@Sendable (AbortSignal) async throws -> OpenCodeClient)? = nil,
        onEvent: @escaping @Sendable (OpenCodeEvent) -> Void,
        flushInterval: Int64 = 10,
        pageLifecycle: Bool = false,
        idleTimeout: Int64 = defaultIdleTimeout,
        connectTimeout: Int64 = 2_000,
        reconnectDelay: Int64 = 1_000,
        autoStart: Bool = true,
        log: ClientConnectionLogger? = nil,
        now: @escaping @Sendable () -> Int64 = { ClientClock.nowEpochMs() }
    ) {
        self.reconnect = reconnect
        self.onEvent = onEvent
        self.flushInterval = flushInterval
        self.pageLifecycle = pageLifecycle
        self.idleTimeout = idleTimeout
        self.connectTimeout = connectTimeout
        self.reconnectDelay = reconnectDelay
        self.autoStart = autoStart
        self.log = log
        self.now = now
    }
}

/// Default stream stall watchdog timeout in milliseconds (`45_000`).
// parity: client/src/solid/connection.ts#defaultIdleTimeout [status=implemented hash=ec018f9c0cf5]
public let defaultIdleTimeout: Int64 = 45_000

/// Foreground silence threshold in milliseconds (`20_000`).
// parity: client/src/solid/connection.ts#foregroundIdleThreshold [status=implemented hash=3b5ce4b6d173]
public let foregroundIdleThreshold: Int64 = 20_000

/// Observable, `Sendable` event-stream connection manager with automatic reconnect,
/// idle watchdog, event batching, and connection diagnostic history.
public final class ClientConnection: Sendable {
    private static let connectionHistoryLimit = 50

    public struct Snapshot: Equatable, Hashable, Sendable {
        public let status: ClientConnectionStatus
        public let attempt: Int
        public let error: String?

        public init(status: ClientConnectionStatus, attempt: Int, error: String? = nil) {
            self.status = status
            self.attempt = attempt
            self.error = error
        }
    }

    private struct State: Sendable {
        var api: OpenCodeClient
        var status: ClientConnectionStatus = .connecting
        var attempt: Int = 0
        var error: String? = nil
        var history: [ClientConnectionEvent] = []
        var pending: [OpenCodeEvent] = []
        var flushTask: Task<Void, Never>? = nil
        var streamController: AbortController? = nil
        var currentController: AbortController? = nil
        var runTask: Task<Void, Never>? = nil
        var started: Bool = false
        var disposed: Bool = false
        var generation: Int = 0
        var lastActivity: Int64 = 0
        var forced: Bool = false
        var nextListenerID: UInt64 = 1
        var statusListeners: [UInt64: @Sendable (Snapshot) -> Void] = [:]
    }

    private let abortController = AbortController()
    private let options: ClientConnectionOptions
    private let state: Mutex<State>

    public init(initialApi: OpenCodeClient, options: ClientConnectionOptions) {
        self.options = options
        self.state = Mutex(State(api: initialApi))
        if options.autoStart {
            start()
        }
    }

    public func status() -> ClientConnectionStatus {
        state.withLock { $0.status }
    }

    public func attempt() -> Int {
        state.withLock { $0.attempt }
    }

    public func error() -> String? {
        state.withLock { $0.error }
    }

    public func snapshot() -> Snapshot {
        state.withLock { Snapshot(status: $0.status, attempt: $0.attempt, error: $0.error) }
    }

    public func history() -> [ClientConnectionEvent] {
        state.withLock { $0.history }
    }

    /// Subscribes to connection status transitions and returns an unsubscribe closure.
    @discardableResult
    public func onStatusChange(_ listener: @escaping @Sendable (Snapshot) -> Void) -> @Sendable () -> Void {
        let id = state.withLock { s -> UInt64 in
            let next = s.nextListenerID
            s.nextListenerID += 1
            s.statusListeners[next] = listener
            return next
        }
        return { [weak self] in
            self?.state.withLock { _ = $0.statusListeners.removeValue(forKey: id) }
        }
    }

    public func start() {
        let shouldLaunch: (active: Int, previous: Task<Void, Never>?)? = state.withLock { s in
            if s.started || s.disposed { return nil }
            s.started = true
            s.forced = false
            s.generation += 1
            return (s.generation, s.runTask)
        }
        guard let launch = shouldLaunch else { return }
        let active = launch.active
        let previous = launch.previous
        let task = Task<Void, Never> { [weak self] in
            if let previous { await previous.value }
            guard let self else { return }
            await self.runStream(active: active)
        }
        state.withLock { s in
            if s.generation == active {
                s.runTask = task
            }
        }
    }

    public func stop() {
        let streamCtrl: AbortController? = state.withLock { s in
            guard s.started else { return nil }
            s.started = false
            s.generation += 1
            let ctrl = s.streamController
            s.streamController = nil
            return ctrl
        }
        streamCtrl?.abort()
        setConnection(status: .connecting, attempt: 0, error: nil)
    }

    /// Drops the live request so the reconnect loop replaces it immediately without waiting for the idle watchdog.
    public func resync(_ reason: String) {
        let (shouldResync, currentCtrl, idleMs): (Bool, AbortController?, Int64) = state.withLock { s in
            guard s.started && s.status == .connected else { return (false, nil, 0) }
            s.forced = true
            return (true, s.currentController, options.now() - s.lastActivity)
        }
        guard shouldResync else { return }
        options.log?.info?("event stream resync", ["reason": .string(reason), "idle": .int(idleMs)])
        currentCtrl?.abort(reason: ServiceLifecycleError(reason))
    }

    /// Permanently stops the connection, cancels timers, and clears pending buffered events.
    public func dispose() {
        let (streamCtrl, flushTask, runTask): (AbortController?, Task<Void, Never>?, Task<Void, Never>?) = state.withLock { s in
            s.disposed = true
            s.started = false
            s.generation += 1
            s.pending.removeAll()
            let sc = s.streamController
            s.streamController = nil
            let ft = s.flushTask
            s.flushTask = nil
            let rt = s.runTask
            s.runTask = nil
            return (sc, ft, rt)
        }
        streamCtrl?.abort()
        abortController.abort()
        flushTask?.cancel()
        runTask?.cancel()
    }

    /// Immediately flushes any batched pending events synchronously (useful for deterministic testing).
    public func flushNow() {
        let events: [OpenCodeEvent] = state.withLock { s in
            s.flushTask?.cancel()
            s.flushTask = nil
            let batch = s.pending
            s.pending.removeAll()
            return batch
        }
        for event in events {
            options.onEvent(event)
        }
    }

    private func setConnection(status: ClientConnectionStatus, attempt: Int, error: String?) {
        let (snap, listeners): (Snapshot, [@Sendable (Snapshot) -> Void]) = state.withLock { s in
            s.status = status
            s.attempt = attempt
            s.error = error
            let snap = Snapshot(status: status, attempt: attempt, error: error)
            return (snap, Array(s.statusListeners.values))
        }
        for listener in listeners {
            listener(snap)
        }
    }

    private func record(_ status: ClientConnectionEvent.EventStatus, attempt: Int, error: String? = nil) {
        let event = ClientConnectionEvent(
            created: options.now(),
            data: ClientConnectionEvent.EventData(status: status, attempt: attempt, error: error)
        )
        state.withLock { s in
            s.history.append(event)
            if s.history.count > Self.connectionHistoryLimit {
                s.history.removeFirst(s.history.count - Self.connectionHistoryLimit)
            }
        }
    }

    private func publish(_ event: OpenCodeEvent) {
        if options.flushInterval <= 0 {
            options.onEvent(event)
            return
        }
        let shouldSchedule: Bool = state.withLock { s in
            if s.disposed { return false }
            s.pending.append(event)
            if s.flushTask != nil { return false }
            return true
        }
        guard shouldSchedule else { return }
        let delayMs = options.flushInterval
        let task = Task<Void, Never> { [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard let self else { return }
            let batch: [OpenCodeEvent] = self.state.withLock { s in
                s.flushTask = nil
                let items = s.pending
                s.pending.removeAll()
                return items
            }
            for item in batch {
                self.options.onEvent(item)
            }
        }
        state.withLock { s in
            if s.flushTask == nil && !s.disposed {
                s.flushTask = task
            } else {
                task.cancel()
            }
        }
    }

    private func connect(signal: AbortSignal, attempt: Int) async -> (error: (any Error)?, connectedAt: Int64?) {
        let requestController = AbortController()
        let api = state.withLock { s -> OpenCodeClient in
            s.currentController = requestController
            return s.api
        }
        let cancelCleanup = signal.onAbort {
            requestController.abort(reason: signal.reason ?? AbortError.sharedReason)
        }
        let connectTimeoutTask = Task<Void, Never> { [options] in
            if options.connectTimeout > 0 {
                try? await Task.sleep(for: .milliseconds(options.connectTimeout))
                if !Task.isCancelled {
                    requestController.abort(reason: ServiceLifecycleError("Timed out connecting to server"))
                }
            }
        }

        final class WatchdogBox: Sendable {
            struct Inner: Sendable {
                var connectedAt: Int64? = nil
                var task: Task<Void, Never>? = nil
            }
            let inner = Mutex(Inner())
        }
        let watchdogBox = WatchdogBox()

        @Sendable
        func touch() {
            let nowMs = options.now()
            state.withLock { $0.lastActivity = nowMs }
            let isConnected = watchdogBox.inner.withLock { $0.connectedAt != nil }
            guard isConnected, options.idleTimeout > 0 else { return }
            let idleMs = options.idleTimeout
            let nextTask = Task<Void, Never> {
                try? await Task.sleep(for: .milliseconds(idleMs))
                if !Task.isCancelled {
                    requestController.abort(reason: ServiceLifecycleError("Event stream stalled"))
                }
            }
            let old = watchdogBox.inner.withLock { b -> Task<Void, Never>? in
                let prev = b.task
                b.task = nextTask
                return prev
            }
            old?.cancel()
        }

        defer {
            requestController.abort()
            state.withLock { s in
                if s.currentController === requestController {
                    s.currentController = nil
                }
            }
            connectTimeoutTask.cancel()
            watchdogBox.inner.withLock {
                $0.task?.cancel()
                $0.task = nil
            }
            cancelCleanup()
        }

        record(attempt == 0 ? .connecting : .reconnecting, attempt: attempt)
        options.log?.info?("event stream connecting", ["attempt": .int(Int64(attempt))])

        do {
            let stream = api.event.subscribe(SubscribeOptions(signal: requestController.signal, onActivity: touch))
            var iterator = stream.makeAsyncIterator()
            guard let first = try await iterator.next() else {
                if signal.isAborted { return (nil, nil) }
                let reason = requestController.signal.reason ?? ServiceLifecycleError("Event stream disconnected")
                return (reason, nil)
            }
            if signal.isAborted { return (nil, nil) }
            guard first.type == "server.connected" else {
                return (ServiceLifecycleError("Event stream did not start with server.connected"), nil)
            }

            connectTimeoutTask.cancel()
            record(.connected, attempt: attempt)
            let connectedAt = options.now()
            watchdogBox.inner.withLock { $0.connectedAt = connectedAt }
            touch()
            options.log?.info?("event stream connected", [:])
            publish(first)
            setConnection(status: .connected, attempt: 0, error: nil)

            while !signal.isAborted && !Task.isCancelled {
                guard let event = try await iterator.next() else {
                    if signal.isAborted { return (nil, connectedAt) }
                    let reason = requestController.signal.reason ?? ServiceLifecycleError("Event stream disconnected")
                    return (reason, connectedAt)
                }
                if signal.isAborted { return (nil, connectedAt) }
                touch()
                publish(event)
            }
            return (nil, connectedAt)
        } catch {
            let connectedAt = watchdogBox.inner.withLock { $0.connectedAt }
            return (error, connectedAt)
        }
    }

    private func runStream(active: Int) async {
        var attempt = 0
        while !abortController.signal.isAborted && !Task.isCancelled {
            let stillActive = state.withLock { $0.started && !$0.disposed && $0.generation == active }
            if !stillActive { return }

            setConnection(status: attempt == 0 ? .connecting : .reconnecting, attempt: attempt, error: nil)
            let controller = AbortController()
            state.withLock { $0.streamController = controller }
            let cancelCleanup = abortController.signal.onAbort {
                controller.abort(reason: self.abortController.signal.reason ?? AbortError.sharedReason)
            }
            let result = await connect(signal: controller.signal, attempt: attempt)
            cancelCleanup()

            let keepGoing = state.withLock { $0.started && !$0.disposed && $0.generation == active }
            if abortController.signal.isAborted || !keepGoing { return }

            if let connectedAt = result.connectedAt, options.now() - connectedAt >= options.reconnectDelay {
                attempt = 0
            }
            attempt += 1
            let message = result.error.map { String(describing: $0) }
            record(.disconnected, attempt: attempt, error: message)
            options.log?.info?("event stream disconnected", [
                "attempt": .int(Int64(attempt)),
                "error": message.map(JSONValue.string) ?? .null,
            ])
            setConnection(status: .reconnecting, attempt: attempt, error: message)

            if let reconnect = options.reconnect {
                if let next = try? await reconnect(controller.signal) {
                    let ok = state.withLock { s -> Bool in
                        guard s.started && !s.disposed && s.generation == active && !controller.signal.isAborted else {
                            return false
                        }
                        s.api = next
                        return true
                    }
                    if !ok { return }
                    if attempt == 1 { continue }
                }
            }

            let wasForced = state.withLock { s -> Bool in
                let f = s.forced
                s.forced = false
                return f
            }
            if wasForced { continue }

            if options.reconnectDelay > 0 && !controller.signal.isAborted {
                try? await Task.sleep(for: .milliseconds(options.reconnectDelay))
            }
        }
    }
}

/// Creates and starts an observable `ClientConnection` mirroring `packages/client/src/solid/connection.ts`.
// parity: client/src/solid/connection.ts#createClientConnection [status=implemented hash=de25cd0f6164]
public func createClientConnection(
    _ initialApi: OpenCodeClient,
    options: ClientConnectionOptions
) -> ClientConnection {
    ClientConnection(initialApi: initialApi, options: options)
}

// MARK: - Session Retention (packages/client/src/solid/retention.ts)

/// Input hooks for `createSessionRetention`.
public struct SessionRetentionInput: Sendable {
    public let listSessions: @Sendable () -> [SessionSchema.Info]
    public let rootSession: @Sendable (String) -> String
    public let evictSession: @Sendable (String) -> Void
    public let messageCount: (@Sendable (String) -> Int)?
    public let current: @Sendable () -> String?
    public let keep: @Sendable () -> [String]
    public let limit: Int

    public init(
        listSessions: @escaping @Sendable () -> [SessionSchema.Info],
        rootSession: @escaping @Sendable (String) -> String,
        evictSession: @escaping @Sendable (String) -> Void,
        messageCount: (@Sendable (String) -> Int)? = nil,
        current: @escaping @Sendable () -> String?,
        keep: @escaping @Sendable () -> [String],
        limit: Int
    ) {
        self.listSessions = listSessions
        self.rootSession = rootSession
        self.evictSession = evictSession
        self.messageCount = messageCount
        self.current = current
        self.keep = keep
        self.limit = limit
    }
}

/// Manages LRU retention and eviction of heavy session message/pending caches.
public final class SessionRetentionController: Sendable {
    private struct State: Sendable {
        var previous: String? = nil
        var recent: [String] = []
        var evicted: [String: String] = [:]
    }

    private let input: SessionRetentionInput
    private let state = Mutex(State())

    public init(input: SessionRetentionInput) {
        self.input = input
    }

    /// Evaluates retention policy against the current navigation state and evicts any unretained roots.
    @discardableResult
    public func evaluate() -> Set<String> {
        let viewed = input.current()
        let currentRoot = viewed.map { input.rootSession($0) }
        let keepSet = Set(input.keep().map { input.rootSession($0) })
        let allSessions = input.listSessions()

        let rootsToEvict: Set<String> = state.withLock { s in
            var nextRecent: [String] = []
            var seen = Set<String>()
            if viewed != s.previous, let currentRoot {
                if seen.insert(currentRoot).inserted {
                    nextRecent.append(currentRoot)
                }
            }
            for id in s.recent {
                let resolved = input.rootSession(id)
                if seen.insert(resolved).inserted {
                    nextRecent.append(resolved)
                }
            }
            s.previous = viewed

            var retained = keepSet
            var remaining = max(0, input.limit)
            for id in nextRecent where !keepSet.contains(id) {
                if remaining <= 0 { break }
                retained.insert(id)
                remaining -= 1
            }
            if let currentRoot {
                retained.insert(currentRoot)
            }
            s.recent = nextRecent.filter { retained.contains($0) }

            var excluded: [String: String] = [:]
            for session in allSessions {
                let root = input.rootSession(session.id.rawValue)
                if !retained.contains(root) {
                    excluded[session.id.rawValue] = root
                }
            }

            var toEvict = Set<String>()
            var nextEvicted: [String: String] = [:]
            for (id, root) in excluded {
                let count = input.messageCount?(id) ?? 0
                let signature = "\(root):\(count)"
                if s.evicted[id] != signature {
                    toEvict.insert(root)
                }
                nextEvicted[id] = signature
            }
            s.evicted = nextEvicted
            return toEvict
        }

        for root in rootsToEvict.sorted() {
            input.evictSession(root)
        }
        return rootsToEvict
    }
}

/// Creates a `SessionRetentionController` and performs the initial retention evaluation.
// parity: client/src/solid/retention.ts#createSessionRetention [status=implemented hash=561597d4ce30]
@discardableResult
public func createSessionRetention(_ input: SessionRetentionInput) -> SessionRetentionController {
    let controller = SessionRetentionController(input: input)
    controller.evaluate()
    return controller
}

// MARK: - Reactive Client Data Store (packages/client/src/solid/data.ts)

/// Running/idle execution status for a session in `ClientDataStore`.
// parity: client/src/solid/data.ts#DataSessionStatus [status=implemented hash=b68873a934f7]
public enum DataSessionStatus: String, Equatable, Hashable, Sendable, Codable {
    case idle
    case running
}

/// Pending user prompt lifecycle status relative to the runner.
// parity: client/src/solid/data.ts#DataPendingStatus [status=implemented hash=ca31f26fab57]
public enum DataPendingStatus: String, Equatable, Hashable, Sendable, Codable {
    case starting
    case steering
    case stranded
    case queued
}

/// Trailing debounce window in milliseconds for event bursts that ask for the same refetch (`150`).
// parity: client/src/solid/data.ts#settleMs [status=implemented hash=4250249b94b1]
public let settleMs: Int64 = 150

/// Pending form paired with its owning `LocationSchema.Ref` for global MCP elicitations.
// parity: client/src/solid/data.ts#FormWithLocation [status=implemented hash=48d217e0dd19]
public struct FormWithLocation: Equatable, Hashable, Sendable, Codable {
    public let form: FormSchema.Info
    public let location: LocationSchema.Ref?

    public init(form: FormSchema.Info, location: LocationSchema.Ref? = nil) {
        self.form = form
        self.location = location
    }

    public var id: FormSchema.ID { form.id }
    public var sessionID: String { form.sessionID }
}

/// Canonical location cache key matching `JSON.stringify([location.directory, location.workspaceID])`.
// parity: client/src/solid/data.ts#locationKey [status=implemented hash=c767deed94bb]
public func locationKey(_ location: LocationSchema.Ref) -> String {
    let arr: JSONValue = .array([
        .string(location.directory.rawValue),
        location.workspaceID.map { .string($0.rawValue) } ?? .null,
    ])
    return (try? ClientCodec.encodeString(arr)) ?? "[\"\(location.directory.rawValue)\",null]"
}

/// Overload accepting `OpenCodeLocation`.
public func locationKey(_ location: OpenCodeLocation) -> String {
    locationKey(LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: location.directory), workspaceID: location.workspaceID))
}

/// Event subscription bridge passed into `createData`.
public final class ClientDataEventBus: Sendable {
    private struct State: Sendable {
        var nextID: UInt64 = 1
        var typeListeners: [String: [UInt64: @Sendable (OpenCodeEvent) -> Void]] = [:]
        var allListeners: [UInt64: @Sendable (OpenCodeEvent) -> Void] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    @discardableResult
    public func on(_ type: String, handler: @escaping @Sendable (OpenCodeEvent) -> Void) -> @Sendable () -> Void {
        let id = state.withLock { s -> UInt64 in
            let next = s.nextID
            s.nextID += 1
            s.typeListeners[type, default: [:]][next] = handler
            return next
        }
        return { [weak self] in
            self?.state.withLock { _ = $0.typeListeners[type]?.removeValue(forKey: id) }
        }
    }

    @discardableResult
    public func listen(_ handler: @escaping @Sendable (OpenCodeEvent) -> Void) -> @Sendable () -> Void {
        let id = state.withLock { s -> UInt64 in
            let next = s.nextID
            s.nextID += 1
            s.allListeners[next] = handler
            return next
        }
        return { [weak self] in
            self?.state.withLock { _ = $0.allListeners.removeValue(forKey: id) }
        }
    }

    public func emit(_ event: OpenCodeEvent) {
        let (typed, all): ([@Sendable (OpenCodeEvent) -> Void], [@Sendable (OpenCodeEvent) -> Void]) = state.withLock { s in
            (
                s.typeListeners[event.type].map { Array($0.values) } ?? [],
                Array(s.allListeners.values)
            )
        }
        for cb in typed { cb(event) }
        for cb in all { cb(event) }
    }
}

/// Configuration for `createData`.
// parity: client/src/solid/data.ts#CreateDataInput [status=implemented hash=c64e62f47756]
public struct CreateDataInput: Sendable {
    public let api: @Sendable () -> OpenCodeClient
    public let directory: String
    public let initialMessageLimit: (@Sendable () -> Int)?
    public let event: ClientDataEventBus
    public let connectionStatus: (@Sendable () -> ClientConnectionStatus)?
    public let onError: (@Sendable (any Error) -> Void)?
    public let omitToolFileData: @Sendable () -> Bool
    public let now: @Sendable () -> Int64

    public init(
        api: @escaping @Sendable () -> OpenCodeClient,
        directory: String,
        initialMessageLimit: (@Sendable () -> Int)? = nil,
        event: ClientDataEventBus = ClientDataEventBus(),
        connectionStatus: (@Sendable () -> ClientConnectionStatus)? = nil,
        onError: (@Sendable (any Error) -> Void)? = nil,
        omitToolFileData: @escaping @Sendable () -> Bool = { false },
        now: @escaping @Sendable () -> Int64 = { ClientClock.nowEpochMs() }
    ) {
        self.api = api
        self.directory = directory
        self.initialMessageLimit = initialMessageLimit
        self.event = event
        self.connectionStatus = connectionStatus
        self.onError = onError
        self.omitToolFileData = omitToolFileData
        self.now = now
    }
}

/// Shell entry cached per location.
public struct ShellWithLocation: Equatable, Hashable, Sendable, Codable {
    public let shell: ShellSchema.Info
    public let location: LocationSchema.Ref

    public init(shell: ShellSchema.Info, location: LocationSchema.Ref) {
        self.shell = shell
        self.location = location
    }
}

/// Cached per-location catalog state inside `ClientDataStore`.
public struct ClientLocationData: Equatable, Sendable {
    public var info: LocationSchema.PublicInfo?
    public var vcs: VcsSchema.Info?
    public var agent: [AgentSchema.Info]?
    public var command: [CommandSchema.Info]?
    public var config: [ConfigSchema.Entry]?
    public var integration: [IntegrationSchema.Info]?
    public var mcpServer: [McpSchema.Server]?
    public var mcpResource: [McpSchema.Resource]?
    public var model: [ModelSchema.Info]?
    public var provider: [ProviderSchema.Info]?
    public var reference: [ReferenceSchema.Info]?
    public var websearch: [WebSearchSchema.Provider]?
    public var usageLimits: SchemaPrimitive.Nullable<UsageLimitsSchema.Info>?
    public var shell: [String: ShellWithLocation]?
    public var skill: [SkillSchema.Info]?

    public init() {}
}

/// Observable, `Sendable` client data store projecting server events and caching API reads,
/// mirroring `packages/client/src/solid/data.ts`.
public final class ClientDataStore: Sendable {
    private static let messagePageLimit = 20
    private static let childPageLimit = 200
    private static let deletedSessionLimit = 512

    private struct StoreState: Sendable {
        var disposed: Bool = false
        var defaultLocation: LocationSchema.Ref
        // Session collections
        var sessionInfo: [String: SessionSchema.Info] = [:]
        var sessionMissing: Set<String> = []
        var sessionFamily: [String: [String]] = [:]
        var sessionActive: [String: DataSessionStatus] = [:]
        var sessionMessages: [String: [SessionMessageSchema.Info]] = [:]
        var sessionMessageIndex: [String: [String: Int]] = [:]
        var sessionMessageCursor: [String: String] = [:]
        var sessionMessageLoading: [String: Bool] = [:]
        var sessionPending: [String: [SessionInboxSchema.Info]] = [:]
        var sessionPermissions: [String: [PermissionSchema.Request]] = [:]
        var sessionForms: [String: [FormWithLocation]] = [:]
        // Optimistic / deletion tracking
        var outbox: Set<String> = []
        var sessionOutbox: Set<String> = []
        var creating: Set<String> = []
        var deletionEpoch: Int = 0
        var deletedOrder: [String] = []
        var deletedAt: [String: Int] = [:]
        var syncedKeys: Set<String> = []
        // Project collections
        var projectInfo: [String: ProjectSchema.Info] = [:]
        var projectPermissions: [String: [PermissionSavedSchema.Info]] = [:]
        // Location collections
        var locations: [String: ClientLocationData] = [:]
        // Running background jobs keyed by job id, for the session trees that synced them. Settled jobs are removed.
        var job: [String: JobSchema.Info] = [:]
        // Job ids the server listed for each synced tree root (it filters descendants itself), plus ids that events
        // added for owners known to be in the tree. Loaded session info only reaches direct children, so walking
        // parents alone would drop a grandchild's jobs.
        var jobTree: [String: Set<String>] = [:]
        // Job events that arrive while a tree's list is in flight, applied over its response: the latest info, or
        // nil once settled. Keyed by tree root, each map is identified by a token so a superseded sync drops out.
        var jobUpdates: [String: (token: UInt64, updates: [String: JobSchema.Info?])] = [:]
        var nextJobSyncToken: UInt64 = 1
        // Per-session send chain: prompts and the requests a caller puts in it with `sequence` must reach the
        // server in submission order. Each waits for the previous link to settle, so one failure does not block
        // the next.
        var sending: [String: Task<Void, Never>] = [:]
        // Observers
        var nextObserverID: UInt64 = 1
        var observers: [UInt64: @Sendable () -> Void] = [:]
        var eventUnsubscribe: (@Sendable () -> Void)? = nil
    }

    private let config: CreateDataInput
    private let state: Mutex<StoreState>

    public init(config: CreateDataInput) {
        self.config = config
        let initialLoc = LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: config.directory))
        self.state = Mutex(StoreState(defaultLocation: initialLoc))
        let unsub = config.event.listen { [weak self] event in
            self?.handleEvent(event)
        }
        state.withLock { $0.eventUnsubscribe = unsub }
    }

    public func dispose() {
        let unsub = state.withLock { s -> (@Sendable () -> Void)? in
            s.disposed = true
            let u = s.eventUnsubscribe
            s.eventUnsubscribe = nil
            s.observers.removeAll()
            return u
        }
        unsub?()
    }

    @discardableResult
    public func onChange(_ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let id = state.withLock { s -> UInt64 in
            let next = s.nextObserverID
            s.nextObserverID += 1
            s.observers[next] = listener
            return next
        }
        return { [weak self] in
            self?.state.withLock { _ = $0.observers.removeValue(forKey: id) }
        }
    }

    private func notifyObservers() {
        let callbacks = state.withLock { Array($0.observers.values) }
        for cb in callbacks { cb() }
    }

    // MARK: - Session Queries & Mutations

    public func listSessions() -> [SessionSchema.Info] {
        state.withLock { s in
            s.sessionInfo.values.sorted { $0.time.updated > $1.time.updated }
        }
    }

    public func getSession(_ sessionID: String) -> SessionSchema.Info? {
        state.withLock { $0.sessionInfo[sessionID] }
    }

    public func isSessionMissing(_ sessionID: String) -> Bool {
        state.withLock { $0.sessionMissing.contains(sessionID) }
    }

    public func forgetSession(_ sessionID: String) {
        markDeleted(sessionID)
    }

    public func isSessionCreating(_ sessionID: String) -> Bool {
        state.withLock { $0.creating.contains(sessionID) }
    }

    public func rememberSession(_ info: SessionSchema.Info) {
        state.withLock { s in
            clearDeletedLocked(&s, sessionID: info.id.rawValue)
            s.sessionInfo[info.id.rawValue] = info
            s.syncedKeys.insert("session:\(info.id.rawValue)")
            registerSessionLocked(&s, sessionID: info.id.rawValue)
        }
        notifyObservers()
    }

    public func setSessionStatus(_ sessionID: String, status: DataSessionStatus) {
        state.withLock { $0.sessionActive[sessionID] = status }
        notifyObservers()
    }

    public func sessionStatus(_ sessionID: String) -> DataSessionStatus {
        state.withLock { $0.sessionActive[sessionID] ?? .idle }
    }

    public func activeSessions() -> [String] {
        state.withLock { s in
            s.sessionActive.compactMap { $0.value == .running ? $0.key : nil }.sorted()
        }
    }

    public func rootSession(_ sessionID: String) -> String {
        state.withLock { resolveRootLocked($0, sessionID: sessionID) }
    }

    public func sessionFamily(_ sessionID: String) -> [String] {
        state.withLock { s in
            let root = resolveRootLocked(s, sessionID: sessionID)
            return s.sessionFamily[root] ?? []
        }
    }

    public func evictSession(_ sessionID: String) {
        state.withLock { s in
            let root = resolveRootLocked(s, sessionID: sessionID)
            var targets = Set([root, sessionID])
            if let members = s.sessionFamily[root] {
                targets.formUnion(members)
            }
            for id in targets {
                evictOneLocked(&s, sessionID: id)
            }
        }
        notifyObservers()
    }

    public func sessionCost(_ sessionID: String) -> Double {
        state.withLock { s in
            guard let info = s.sessionInfo[sessionID] else { return 0 }
            if info.parentID != nil { return info.cost }
            let members = s.sessionFamily[sessionID] ?? [sessionID]
            return members.reduce(0.0) { $0 + (s.sessionInfo[$1]?.cost ?? 0.0) }
        }
    }

    public func pendingList(_ sessionID: String) -> [SessionInboxSchema.Info] {
        state.withLock { $0.sessionPending[sessionID] ?? [] }
    }

    public func inputIDs(_ sessionID: String) -> [String] {
        state.withLock { s in
            (s.sessionPending[sessionID] ?? []).compactMap { item -> String? in
                if case .compaction = item { return nil }
                return item.id.rawValue
            }
        }
    }

    public func hasInput(_ sessionID: String, inboxID: String) -> Bool {
        state.withLock { s in
            (s.sessionPending[sessionID] ?? []).contains { item in
                if case .compaction = item { return false }
                return item.id.rawValue == inboxID
            }
        }
    }

    public func pendingStatus(_ sessionID: String, inboxID: String) -> DataPendingStatus? {
        state.withLock { s in
            let pending = s.sessionPending[sessionID] ?? []
            guard let found = pending.first(where: { item in
                if case .user(let u) = item, u.id.rawValue == inboxID { return true }
                return false
            }) else {
                return nil
            }
            guard case .user(let userItem) = found else { return nil }
            if userItem.delivery == .queue { return .queued }

            let messages = s.sessionMessages[sessionID] ?? []
            let boundary = messages.lastIndex {
                if case .idle = $0 { return true }
                return false
            }
            let activeStatus = s.sessionActive[sessionID] ?? .idle
            if activeStatus == .idle {
                if let boundary, case .idle(let idleMsg) = messages[boundary],
                   userItem.time.created <= idleMsg.time.created {
                    return .stranded
                }
                return .starting
            }
            let start = boundary.map { $0 + 1 } ?? 0
            let pendingIDs = Set(pending.map(\.id.rawValue))
            let hasDeliveredUserSinceIdle = messages[start...].contains { msg in
                if case .user(let u) = msg, !pendingIDs.contains(u.id.rawValue) { return true }
                return false
            }
            return hasDeliveredUserSinceIdle ? .steering : .starting
        }
    }

    public func messages(_ sessionID: String) -> [SessionMessageSchema.Info] {
        state.withLock { $0.sessionMessages[sessionID] ?? [] }
    }

    public func message(_ sessionID: String, messageID: String) -> SessionMessageSchema.Info? {
        state.withLock { s in
            guard let pos = s.sessionMessageIndex[sessionID]?[messageID],
                  let list = s.sessionMessages[sessionID],
                  pos < list.count
            else { return nil }
            return list[pos]
        }
    }

    public func hasMoreMessages(_ sessionID: String) -> Bool {
        state.withLock { $0.sessionMessageCursor[sessionID] != nil }
    }

    public func isMessagesLoading(_ sessionID: String) -> Bool {
        state.withLock { $0.sessionMessageLoading[sessionID] ?? false }
    }

    public func permissions(_ sessionID: String) -> [PermissionSchema.Request]? {
        state.withLock { $0.sessionPermissions[sessionID] }
    }

    public func forms(_ sessionID: String, location: LocationSchema.Ref? = nil) -> [FormWithLocation]? {
        state.withLock { s in
            let list = s.sessionForms[sessionID]
            guard sessionID == "global" else { return list }
            guard let location else { return nil }
            let key = locationKey(location)
            return list?.filter { $0.location.map(locationKey) == key }
        }
    }

    public func listProjects() -> [ProjectSchema.Info] {
        state.withLock { s in
            s.projectInfo.values
                .filter { $0.time.archived == nil }
                .sorted { $0.time.active.rawValue > $1.time.active.rawValue }
        }
    }

    public func getProject(_ projectID: String) -> ProjectSchema.Info? {
        state.withLock { $0.projectInfo[projectID] }
    }

    public func projectPermissions(_ projectID: String) -> [PermissionSavedSchema.Info]? {
        state.withLock { $0.projectPermissions[projectID] }
    }

    public func defaultLocation() -> LocationSchema.Ref {
        state.withLock { $0.defaultLocation }
    }

    public func locationData(_ ref: LocationSchema.Ref? = nil) -> ClientLocationData? {
        state.withLock { s in
            s.locations[locationKey(ref ?? s.defaultLocation)]
        }
    }

    public func shells(location: LocationSchema.Ref? = nil) -> [ShellWithLocation] {
        state.withLock { s in
            let key = locationKey(location ?? s.defaultLocation)
            return Array((s.locations[key]?.shell ?? [:]).values)
        }
    }

    // MARK: - Async API Sync & Optimistic Admissions

    public func syncSession(_ sessionID: String, children: Bool = false) async throws {
        let started = state.withLock { $0.deletionEpoch }
        do {
            let info = try await config.api().session.get(SessionGetInput(sessionID: sessionID))
            var fetched: [SessionSchema.Info] = [info]
            if children {
                let kids = try await listAllChildren(parentID: sessionID)
                fetched.append(contentsOf: kids)
            }
            state.withLock { s in
                for session in fetched {
                    if (s.deletedAt[session.id.rawValue] ?? 0) > started { continue }
                    clearDeletedLocked(&s, sessionID: session.id.rawValue)
                    s.sessionInfo[session.id.rawValue] = session
                    s.syncedKeys.insert("session:\(session.id.rawValue)")
                    registerSessionLocked(&s, sessionID: session.id.rawValue)
                }
            }
            notifyObservers()
        } catch {
            if let notFound = extractSessionNotFoundError(error) {
                markDeleted(notFound.sessionID)
            }
            throw error
        }
    }

    public func syncMessages(_ sessionID: String) async throws {
        let started = state.withLock { $0.deletionEpoch }
        do {
            let response = try await config.api().message.list(
                MessageListInput(
                    sessionID: sessionID,
                    limit: config.initialMessageLimit?() ?? Self.messagePageLimit,
                    order: .desc
                )
            )
            let omit = config.omitToolFileData()
            let fetched = response.data.reversed().map { omit ? Self.omitMessageFileData($0) : $0 }
            state.withLock { s in
                if (s.deletedAt[sessionID] ?? 0) > started { return }
                let fetchedIDs = Set(fetched.map(\.id.rawValue))
                let admitted = Set((s.sessionPending[sessionID] ?? []).compactMap { item -> String? in
                    switch item {
                    case .user(let u): u.id.rawValue
                    case .synthetic(let syn): syn.id.rawValue
                    default: nil
                    }
                })
                let local = (s.sessionMessages[sessionID] ?? []).filter { item in
                    !fetchedIDs.contains(item.id.rawValue)
                        && (s.outbox.contains(item.id.rawValue) || admitted.contains(item.id.rawValue))
                }
                let merged = local.isEmpty ? fetched : fetched + local
                for id in admitted where fetchedIDs.contains(id) {
                    s.outbox.remove(id)
                    removePendingLocked(&s, sessionID: sessionID, inboxID: id)
                }
                s.sessionMessages[sessionID] = merged
                s.sessionMessageIndex[sessionID] = Dictionary(
                    uniqueKeysWithValues: merged.enumerated().map { ($0.element.id.rawValue, $0.offset) }
                )
                s.sessionMessageCursor[sessionID] = response.cursor.next
                s.syncedKeys.insert("session.message:\(sessionID)")
            }
            notifyObservers()
        } catch {
            if let notFound = extractSessionNotFoundError(error) {
                markDeleted(notFound.sessionID)
            }
            throw error
        }
    }

    public func syncPending(_ sessionID: String) async throws {
        let started = state.withLock { $0.deletionEpoch }
        do {
            let snapshot = try await config.api().session.inbox.list(SessionInboxListInput(sessionID: sessionID))
            state.withLock { s in
                if (s.deletedAt[sessionID] ?? 0) > started { return }
                for item in snapshot {
                    s.outbox.remove(item.id.rawValue)
                }
                let inflight = (s.sessionPending[sessionID] ?? []).filter { s.outbox.contains($0.id.rawValue) }
                let merged = snapshot + inflight
                s.sessionPending[sessionID] = merged
                for item in merged {
                    materializeInboxLocked(&s, item: item)
                }
                s.syncedKeys.insert("session.pending:\(sessionID)")
            }
            notifyObservers()
        } catch {
            if let notFound = extractSessionNotFoundError(error) {
                markDeleted(notFound.sessionID)
            }
            throw error
        }
    }

    // MARK: - Background Jobs

    /// Running jobs owned by the session or any session below it: a synced tree's listed members, plus jobs whose
    /// owner loaded session info places below it.
    public func jobs(_ sessionID: String) -> [JobSchema.Info] {
        state.withLock { s in
            let members = s.jobTree[sessionID]
            return s.job.values
                .filter { members?.contains($0.clientJobID) == true || jobWithinLocked(s, job: $0, ancestorID: sessionID) }
                .sorted { $0.clientJobID < $1.clientJobID }
        }
    }

    /// Lists the running jobs of `sessionID`'s tree from the server and reconciles them with job events that
    /// arrived while the list was in flight.
    public func syncJobs(_ sessionID: String) async throws {
        let token = state.withLock { s -> UInt64 in
            let token = s.nextJobSyncToken
            s.nextJobSyncToken += 1
            s.jobUpdates[sessionID] = (token: token, updates: [:])
            return token
        }
        let list: [JobSchema.Info]
        do {
            list = try await config.api().experimental.job.list(ExperimentalJobListInput(
                sessionID: sessionID,
                status: .string(JobSchema.Status.running.rawValue),
                descendants: true
            ))
        } catch {
            state.withLock { s in
                if s.jobUpdates[sessionID]?.token == token { s.jobUpdates.removeValue(forKey: sessionID) }
            }
            if let notFound = extractSessionNotFoundError(error) {
                markDeleted(notFound.sessionID)
            }
            throw error
        }
        let applied = state.withLock { s -> Bool in
            guard let pending = s.jobUpdates[sessionID], pending.token == token else { return false }
            s.jobUpdates.removeValue(forKey: sessionID)
            var listed: [String: JobSchema.Info] = [:]
            for job in list { listed[job.clientJobID] = job }
            var next = listed
            for (id, info) in pending.updates {
                guard let info else {
                    next.removeValue(forKey: id)
                    continue
                }
                if listed[id] != nil || jobWithinLocked(s, job: info, ancestorID: sessionID) { next[id] = info }
            }
            let previous = s.jobTree[sessionID] ?? []
            for (id, job) in s.job where next[id] == nil {
                if previous.contains(id) || jobWithinLocked(s, job: job, ancestorID: sessionID) {
                    s.job.removeValue(forKey: id)
                }
            }
            for (id, job) in next { s.job[id] = job }
            s.jobTree[sessionID] = Set(next.keys)
            s.syncedKeys.insert("job:\(sessionID)")
            return true
        }
        if applied { notifyObservers() }
    }

    /// Marks a job tree stale so its next `syncJobs` lists it again.
    public func invalidateJobs(_ sessionID: String) {
        _ = state.withLock { $0.syncedKeys.remove("job:\(sessionID)") }
    }

    // MARK: - Send Chain

    /// How long a sequenced request that stays open holds its session's send chain once it has left: time to reach
    /// the server before the next send does.
    public static let sequenceHandoffMs: Int64 = 250

    /// Captures the session's previous link and installs this request as the next one. The chain's link is the
    /// request itself, or `link` of it for a request that stays open after the server has it.
    private func sendAdmission<Value: Sendable>(
        _ sessionID: String,
        send: @escaping @Sendable () async throws -> Value,
        link: (@Sendable (Task<Value, any Error>) async -> Void)? = nil
    ) async throws -> Value {
        let request = state.withLock { s -> Task<Value, any Error> in
            let previous = s.sending[sessionID]
            let request = Task<Value, any Error> {
                await previous?.value
                return try await send()
            }
            let next = Task<Void, Never> {
                if let link {
                    await link(request)
                } else {
                    _ = try? await request.value
                }
            }
            s.sending[sessionID] = next
            Task { [weak self] in
                await next.value
                self?.state.withLock { s in
                    if s.sending[sessionID] == next { s.sending.removeValue(forKey: sessionID) }
                }
            }
            return request
        }
        return try await request.value
    }

    /// Runs a session request this layer does not model, such as a shell or a server command, in the session's
    /// send chain: `prepare` and then `send` start once the prompts and sequenced requests made before it have
    /// left, so the server receives them in the order they were made. The chain keeps the order in which requests
    /// leave, not the work they start: such a request can stay open for as long as that work runs, as a shell
    /// command's does until its process exits. Its link therefore ends when the request settles or has had
    /// `sequenceHandoffMs` to reach the server, whichever is first.
    public func sequence<Value: Sendable>(
        _ sessionID: String,
        send: @escaping @Sendable () async throws -> Value,
        prepare: (@Sendable () async throws -> Void)? = nil
    ) async throws -> Value {
        let (left, leftContinuation) = AsyncStream<Void>.makeStream()
        let handoff = Self.sequenceHandoffMs
        return try await sendAdmission(
            sessionID,
            send: {
                defer { leftContinuation.finish() }
                try await prepare?()
                let request = Task<Value, any Error> { try await send() }
                leftContinuation.yield(())
                return try await request.value
            },
            link: { request in
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { _ = try? await request.value }
                    group.addTask {
                        var didLeave = false
                        for await _ in left {
                            didLeave = true
                            break
                        }
                        if didLeave {
                            try? await Task.sleep(for: .milliseconds(handoff))
                        } else {
                            // The request never left (its prepare failed); its settlement ends the link.
                            _ = try? await request.value
                        }
                    }
                    await group.next()
                    group.cancelAll()
                }
            }
        )
    }

    public func syncProjects() async throws {
        let projects = try await config.api().project.list()
        state.withLock { s in
            s.projectInfo = Dictionary(uniqueKeysWithValues: projects.map { ($0.id.rawValue, $0) })
            s.syncedKeys.insert("project")
        }
        notifyObservers()
    }

    public func syncLocationInfo(_ ref: LocationSchema.Ref? = nil) async throws {
        let target = ref ?? defaultLocation()
        let info = try await config.api().location.get(
            LocationGetInput(location: LocationQuery.LocationField(directory: target.directory.rawValue))
        )
        let canonicalRef = LocationSchema.Ref(directory: info.directory)
        let key = locationKey(canonicalRef)
        state.withLock { s in
            var entry = s.locations[key] ?? ClientLocationData()
            entry.info = info
            s.locations[key] = entry
            if ref == nil {
                s.defaultLocation = canonicalRef
            }
            s.syncedKeys.insert("location:\(key)")
        }
        notifyObservers()
    }

    public func syncVcs(_ ref: LocationSchema.Ref? = nil) async throws {
        let target = ref ?? defaultLocation()
        let response = try await config.api().vcs.get(
            VcsGetInput(location: LocationQuery.LocationField(directory: target.directory.rawValue))
        )
        let key = locationKey(LocationSchema.Ref(directory: response.location.directory))
        state.withLock { s in
            var entry = s.locations[key] ?? ClientLocationData()
            entry.vcs = response.data
            s.locations[key] = entry
        }
        notifyObservers()
    }

    public func syncAgents(_ ref: LocationSchema.Ref? = nil) async throws {
        let target = ref ?? defaultLocation()
        let response = try await config.api().agent.list(
            AgentListInput(location: LocationQuery.LocationField(directory: target.directory.rawValue))
        )
        let key = locationKey(LocationSchema.Ref(directory: response.location.directory))
        state.withLock { s in
            var entry = s.locations[key] ?? ClientLocationData()
            entry.agent = response.data
            s.locations[key] = entry
        }
        notifyObservers()
    }

    public func syncModels(_ ref: LocationSchema.Ref? = nil) async throws {
        let target = ref ?? defaultLocation()
        let reqKey = locationKey(target)
        let response = try await config.api().model.list(
            ModelListInput(location: LocationQuery.LocationField(directory: target.directory.rawValue))
        )
        let key = locationKey(LocationSchema.Ref(directory: response.location.directory))
        state.withLock { s in
            var entry = s.locations[key] ?? ClientLocationData()
            entry.model = response.data
            s.locations[key] = entry
            if key != reqKey {
                var aliasEntry = s.locations[reqKey] ?? ClientLocationData()
                aliasEntry.model = response.data
                s.locations[reqKey] = aliasEntry
            }
        }
        notifyObservers()
    }

    public func syncUsageLimits(_ ref: LocationSchema.Ref? = nil) async throws {
        let target = ref ?? defaultLocation()
        let response = try await config.api().experimental.usage.limits(
            ExperimentalUsageLimitsInput(location: LocationQuery.LocationField(directory: target.directory.rawValue))
        )
        let key = locationKey(LocationSchema.Ref(directory: response.location.directory))
        state.withLock { s in
            var entry = s.locations[key] ?? ClientLocationData()
            entry.usageLimits = response.data.map(SchemaPrimitive.Nullable.value) ?? .null
            s.locations[key] = entry
        }
        notifyObservers()
    }

    /// Optimistically creates a session locally under a client-minted ID, then posts to the server
    /// (rolling back only if the server never acknowledged the ID).
    public func createSession(
        id: String? = nil,
        title: String? = nil,
        agent: String? = nil,
        model: ModelSchema.Ref? = nil,
        location: LocationSchema.Ref? = nil,
        projectID: String? = nil
    ) async throws -> SessionSchema.Info {
        let resolvedID = id ?? SessionID.create().rawValue
        let loc = location ?? defaultLocation()
        let nowMs = config.now()

        let fresh: Bool = state.withLock { s in
            clearDeletedLocked(&s, sessionID: resolvedID)
            let isFresh = s.sessionInfo[resolvedID] == nil
            if isFresh, let sid = SessionID(rawValue: resolvedID) {
                s.sessionOutbox.insert(resolvedID)
                s.creating.insert(resolvedID)
                let resolvedProject = projectID
                    .flatMap(ProjectID.init(rawValue:))
                    ?? s.locations[locationKey(loc)]?.info?.project.id
                    ?? ProjectID.global
                let optimistic = SessionSchema.Info(
                    id: sid,
                    projectID: resolvedProject,
                    agent: agent,
                    model: model.map {
                        SessionSchema.ModelRef(id: $0.id.rawValue, providerID: $0.providerID.rawValue, variant: $0.variant?.rawValue)
                    },
                    cost: 0,
                    tokens: SessionSchema.TokenUsage(input: 0, output: 0, reasoning: 0, cache: .init(read: 0, write: 0)),
                    time: SessionSchema.Info.Time(created: nowMs, updated: nowMs),
                    title: title,
                    location: SessionSchema.LocationRef(directory: loc.directory.rawValue, workspaceID: loc.workspaceID)
                )
                s.sessionInfo[resolvedID] = optimistic
                registerSessionLocked(&s, sessionID: resolvedID)
            }
            return isFresh
        }
        if fresh { notifyObservers() }

        defer {
            state.withLock { _ = $0.creating.remove(resolvedID) }
        }

        do {
            let info = try await config.api().session.create(
                SessionCreateInput(
                    id: resolvedID,
                    title: title,
                    agent: agent,
                    model: model,
                    location: LocationSchema.PublicRef(directory: loc.directory)
                )
            )
            state.withLock { s in
                s.sessionOutbox.remove(resolvedID)
                clearDeletedLocked(&s, sessionID: info.id.rawValue)
                s.sessionInfo[info.id.rawValue] = info
                registerSessionLocked(&s, sessionID: info.id.rawValue)
            }
            notifyObservers()
            return info
        } catch {
            if fresh {
                let shouldRollback = state.withLock { s -> Bool in
                    guard s.sessionOutbox.remove(resolvedID) != nil else { return false }
                    removeSessionLocked(&s, sessionID: resolvedID)
                    return true
                }
                if shouldRollback { notifyObservers() }
            }
            throw error
        }
    }

    /// Optimistically admits a user prompt into `pending` & the visible transcript, then posts to the server
    /// (rolling back only if unacknowledged).
    public func prompt(_ input: SessionPromptInput) async throws -> SessionInboxSchema.User {
        let resolvedID = input.id ?? SessionMessageSchema.ID.create().rawValue
        let fresh: Bool = state.withLock { s in
            let alreadyInMessages = s.sessionMessageIndex[input.sessionID]?[resolvedID] != nil
            let alreadyInPending = (s.sessionPending[input.sessionID] ?? []).contains { $0.id.rawValue == resolvedID }
            let isFresh = !alreadyInMessages && !alreadyInPending
            if isFresh,
               let msgID = SessionMessageSchema.ID(rawValue: resolvedID),
               let sid = SessionID(rawValue: input.sessionID) {
                s.outbox.insert(resolvedID)
                let userInbox = SessionInboxSchema.User(
                    id: msgID,
                    sessionID: sid,
                    time: SessionMessageSchema.TimeCreated(created: config.now()),
                    payload: SessionInboxSchema.UserPayload(
                        text: input.text,
                        agents: input.agents,
                        metadata: input.metadata
                    ),
                    delivery: input.delivery ?? .steer
                )
                admitLocalLocked(&s, item: .user(userInbox))
            }
            return isFresh
        }
        if fresh { notifyObservers() }

        do {
            let payload = SessionPromptInput(
                sessionID: input.sessionID,
                id: resolvedID,
                text: input.text,
                files: input.files,
                agents: input.agents,
                skills: input.skills,
                metadata: input.metadata,
                delivery: input.delivery,
                resume: input.resume
            )
            let api = config.api
            return try await sendAdmission(input.sessionID) {
                try await api().session.prompt(payload)
            }
        } catch {
            if fresh {
                let rolledBack = state.withLock { s -> Bool in
                    guard s.outbox.remove(resolvedID) != nil else { return false }
                    retractLocalLocked(&s, sessionID: input.sessionID, inboxID: resolvedID)
                    return true
                }
                if rolledBack { notifyObservers() }
            }
            throw error
        }
    }

    public func replyPermission(_ input: PermissionReplyInput) async throws {
        do {
            try await config.api().permission.reply(input)
        } catch {
            if !isPermissionNotFoundError(error) { throw error }
        }
        state.withLock { s in
            removePermissionLocked(&s, sessionID: input.sessionID, requestID: input.requestID)
        }
        notifyObservers()
    }

    public func replyForm(_ input: SessionFormReplyInput, location: LocationSchema.Ref? = nil) async throws {
        let reqOpts = Self.formRequestOptions(sessionID: input.sessionID, location: location)
        do {
            try await config.api().session.form.reply(input, options: reqOpts)
        } catch {
            if let nf = extractFormNotFoundError(error), nf.id == input.formID {
                // Already gone
            } else if let settled = extractFormAlreadySettledError(error), settled.id == input.formID {
                // Already settled
            } else {
                throw error
            }
        }
        state.withLock { s in
            _ = removeFormLocked(&s, sessionID: input.sessionID, formID: input.formID, location: location)
        }
        notifyObservers()
    }

    public func cancelForm(_ input: SessionFormCancelInput, location: LocationSchema.Ref? = nil) async throws {
        let reqOpts = Self.formRequestOptions(sessionID: input.sessionID, location: location)
        do {
            try await config.api().session.form.cancel(input, options: reqOpts)
        } catch {
            if let nf = extractFormNotFoundError(error), nf.id == input.formID {
                // Already gone
            } else if let settled = extractFormAlreadySettledError(error), settled.id == input.formID {
                // Already settled
            } else {
                throw error
            }
        }
        state.withLock { s in
            _ = removeFormLocked(&s, sessionID: input.sessionID, formID: input.formID, location: location)
        }
        notifyObservers()
    }

    // MARK: - Live Event Projection

    /// Applies an incoming `OpenCodeEvent` directly to the reactive store.
    public func handleEvent(_ event: OpenCodeEvent) {
        let createdMs = Int64(event.created ?? Double(config.now()))
        let omit = config.omitToolFileData()

        var didMutate = true

        state.withLock { s in
            guard !s.disposed else { didMutate = false; return }
            switch event.type {
            case "project.updated":
                if let project = try? ClientCodec.fromJSONValue(ProjectSchema.Info.self, value: event.data) {
                    s.projectInfo[project.id.rawValue] = project
                }

            case "session.created":
                if let sid = jsonString(event.data, "sessionID") {
                    clearDeletedLocked(&s, sessionID: sid)
                    s.sessionOutbox.remove(sid)
                    s.syncedKeys.insert("session.pending:\(sid)")
                    s.syncedKeys.insert("session.message:\(sid)")
                }

            case "session.deleted":
                if let sid = jsonString(event.data, "sessionID") {
                    markDeletedLocked(&s, sessionID: sid)
                }

            case "session.usage.updated":
                if let sid = jsonString(event.data, "sessionID"),
                   let info = s.sessionInfo[sid],
                   let cost = jsonDouble(event.data, "cost"),
                   let tokensVal = jsonField(event.data, "tokens"),
                   let tokens = try? ClientCodec.fromJSONValue(SessionSchema.TokenUsage.self, value: tokensVal) {
                    s.sessionInfo[sid] = SessionSchema.Info(
                        id: info.id, parentID: info.parentID, fork: info.fork, projectID: info.projectID,
                        agent: info.agent, model: info.model, cost: cost, tokens: tokens,
                        outcome: info.outcome, time: info.time, title: info.title,
                        location: info.location, subpath: info.subpath, metadata: info.metadata,
                        permissions: info.permissions, revert: info.revert
                    )
                }

            case "session.renamed":
                if let sid = jsonString(event.data, "sessionID"),
                   let title = jsonString(event.data, "title"),
                   let info = s.sessionInfo[sid] {
                    s.sessionInfo[sid] = SessionSchema.Info(
                        id: info.id, parentID: info.parentID, fork: info.fork, projectID: info.projectID,
                        agent: info.agent, model: info.model, cost: info.cost, tokens: info.tokens,
                        outcome: info.outcome, time: info.time, title: title,
                        location: info.location, subpath: info.subpath, metadata: info.metadata,
                        permissions: info.permissions, revert: info.revert
                    )
                }

            case "session.archived":
                if let sid = jsonString(event.data, "sessionID"), let info = s.sessionInfo[sid] {
                    let nextTime = SessionSchema.Info.Time(
                        created: info.time.created, updated: info.time.updated,
                        busy: info.time.busy, idle: info.time.idle, viewed: info.time.viewed, archived: createdMs
                    )
                    s.sessionInfo[sid] = SessionSchema.Info(
                        id: info.id, parentID: info.parentID, fork: info.fork, projectID: info.projectID,
                        agent: info.agent, model: info.model, cost: info.cost, tokens: info.tokens,
                        outcome: info.outcome, time: nextTime, title: info.title,
                        location: info.location, subpath: info.subpath, metadata: info.metadata,
                        permissions: info.permissions, revert: info.revert
                    )
                }

            case "session.unarchived":
                if let sid = jsonString(event.data, "sessionID"), let info = s.sessionInfo[sid] {
                    let nextTime = SessionSchema.Info.Time(
                        created: info.time.created, updated: info.time.updated,
                        busy: info.time.busy, idle: info.time.idle, viewed: info.time.viewed, archived: nil
                    )
                    s.sessionInfo[sid] = SessionSchema.Info(
                        id: info.id, parentID: info.parentID, fork: info.fork, projectID: info.projectID,
                        agent: info.agent, model: info.model, cost: info.cost, tokens: info.tokens,
                        outcome: info.outcome, time: nextTime, title: info.title,
                        location: info.location, subpath: info.subpath, metadata: info.metadata,
                        permissions: info.permissions, revert: info.revert
                    )
                }

            case "session.agent.selected":
                if let sid = jsonString(event.data, "sessionID"),
                   let agent = jsonString(event.data, "agent") {
                    let prev = s.sessionInfo[sid]?.agent
                    if let info = s.sessionInfo[sid] {
                        s.sessionInfo[sid] = SessionSchema.Info(
                            id: info.id, parentID: info.parentID, fork: info.fork, projectID: info.projectID,
                            agent: agent, model: info.model, cost: info.cost, tokens: info.tokens,
                            outcome: info.outcome, time: info.time, title: info.title,
                            location: info.location, subpath: info.subpath, metadata: info.metadata,
                            permissions: info.permissions, revert: info.revert
                        )
                    }
                    if let msgID = try? SessionMessageSchema.ID.fromEvent(event.id) {
                        appendMessageLocked(
                            &s,
                            sessionID: sid,
                            item: .agentSelected(SessionMessageSchema.AgentSelected(
                                id: msgID,
                                time: SessionMessageSchema.TimeCreated(created: createdMs),
                                agent: agent,
                                previous: prev
                            ))
                        )
                    }
                }

            case "worktree.resolved":
                if let projectID = jsonString(event.data, "projectID"),
                   let dir = jsonString(event.data, "directory"),
                   let previous = jsonString(event.data, "previous") {
                    var adoptedList: [String]?
                    if case .array(let arr) = jsonField(event.data, "adopted") {
                        adoptedList = arr.compactMap { if case .string(let str) = $0 { return str } else { return nil } }
                    }
                    let adoptEvent = WorktreeSchema.AdoptEvent(
                        projectID: projectID,
                        directory: dir,
                        previous: previous,
                        adopted: adoptedList
                    )
                    for (sid, info) in s.sessionInfo {
                        let explicit = adoptedList?.contains(info.projectID.rawValue) ?? false
                        let resolvedDir = explicit ? s.projectInfo[info.projectID.rawValue]?.canonical.rawValue : info.location.directory
                        guard let resolvedDir else { continue }
                        let sessionCoord = WorktreeSchema.AdoptSession(
                            projectID: info.projectID.rawValue,
                            directory: resolvedDir,
                            workspaceID: info.location.workspaceID?.rawValue
                        )
                        guard let adopted = WorktreeSchema.adopt(sessionCoord, adoptEvent) else { continue }
                        let nextProjectID = ProjectID(rawValue: adopted.projectID)
                        s.sessionInfo[sid] = SessionSchema.Info(
                            id: info.id, parentID: info.parentID, fork: info.fork, projectID: nextProjectID,
                            agent: info.agent, model: info.model, cost: info.cost, tokens: info.tokens,
                            outcome: info.outcome, time: info.time, title: info.title,
                            location: info.location, subpath: adopted.subpath, metadata: info.metadata,
                            permissions: info.permissions, revert: info.revert
                        )
                    }
                }

            case "session.inbox.enqueued":
                if let sid = jsonString(event.data, "sessionID"),
                   let inboxID = jsonString(event.data, "inboxID"),
                   let itemVal = jsonField(event.data, "item"),
                   case .object(var obj) = itemVal {
                    s.outbox.remove(inboxID)
                    obj["id"] = .string(inboxID)
                    obj["sessionID"] = .string(sid)
                    obj["time"] = .object(["created": .int(createdMs)])
                    if let decoded = try? ClientCodec.fromJSONValue(SessionInboxSchema.Info.self, value: .object(obj)) {
                        admitLocalLocked(&s, item: decoded)
                    }
                }

            case "session.inbox.delivered":
                if let sid = jsonString(event.data, "sessionID"),
                   let inboxID = jsonString(event.data, "inboxID") {
                    let wasInput = (s.sessionPending[sid] ?? []).contains {
                        if case .compaction = $0 { return false }
                        return $0.id.rawValue == inboxID
                    }
                    removePendingLocked(&s, sessionID: sid, inboxID: inboxID)
                    if wasInput, let pos = s.sessionMessageIndex[sid]?[inboxID],
                       var list = s.sessionMessages[sid], pos < list.count {
                        let moved = Self.updatingMessageCreated(list.remove(at: pos), created: createdMs)
                        list.append(moved)
                        s.sessionMessages[sid] = list
                        s.sessionMessageIndex[sid] = Dictionary(
                            uniqueKeysWithValues: list.enumerated().map { ($0.element.id.rawValue, $0.offset) }
                        )
                    }
                }

            case "session.inbox.delivery.changed":
                if let sid = jsonString(event.data, "sessionID"),
                   let inboxID = jsonString(event.data, "inboxID"),
                   let deliveryRaw = jsonString(event.data, "delivery"),
                   let delivery = SessionInboxSchema.Delivery(rawValue: deliveryRaw),
                   var pending = s.sessionPending[sid],
                   let idx = pending.firstIndex(where: { $0.id.rawValue == inboxID }) {
                    pending[idx] = Self.updatingInboxDelivery(pending[idx], delivery: delivery)
                    s.sessionPending[sid] = pending
                }

            case "session.inbox.cancelled":
                if let sid = jsonString(event.data, "sessionID"),
                   let inboxID = jsonString(event.data, "inboxID") {
                    retractLocalLocked(&s, sessionID: sid, inboxID: inboxID)
                }

            case "session.execution.started":
                if let sid = jsonString(event.data, "sessionID") {
                    s.sessionActive[sid] = .running
                }

            case "session.execution.succeeded", "session.execution.failed", "session.execution.interrupted":
                if let sid = jsonString(event.data, "sessionID") {
                    s.sessionActive[sid] = .idle
                    let shutdown = event.type == "session.execution.interrupted" && jsonString(event.data, "reason") == "shutdown"
                    if !shutdown, let msgID = try? SessionMessageSchema.ID.fromEvent(event.id) {
                        let outcome: SessionSchema.Outcome = event.type == "session.execution.succeeded"
                            ? .succeeded
                            : (event.type == "session.execution.failed" ? .failed : .interrupted)
                        let err: SessionErrorSchema.Error? = event.type == "session.execution.failed"
                            ? jsonField(event.data, "error").flatMap { try? ClientCodec.fromJSONValue(SessionErrorSchema.Error.self, value: $0) }
                            : nil
                        appendMessageLocked(
                            &s,
                            sessionID: sid,
                            item: .idle(SessionMessageSchema.Idle(
                                id: msgID,
                                time: SessionMessageSchema.TimeCreated(created: createdMs),
                                outcome: outcome,
                                error: err
                            ))
                        )
                    }
                }

            case "session.step.started":
                if let sid = jsonString(event.data, "sessionID"),
                   let msgIDRaw = jsonString(event.data, "assistantMessageID"),
                   let msgID = SessionMessageSchema.ID(rawValue: msgIDRaw),
                   let agent = jsonString(event.data, "agent"),
                   let modelVal = jsonField(event.data, "model"),
                   let model = try? ClientCodec.fromJSONValue(SessionSchema.ModelRef.self, value: modelVal) {
                    let startedMs = Int64(jsonDouble(event.data, "started") ?? Double(createdMs))
                    let snap = jsonString(event.data, "snapshot")
                    let assistant = SessionMessageSchema.Assistant(
                        id: msgID,
                        metadata: event.metadata,
                        agent: agent,
                        model: model,
                        content: [],
                        snapshot: snap.map { SessionMessageSchema.Assistant.Snapshot(start: $0) },
                        time: SessionMessageSchema.Assistant.Time(created: startedMs)
                    )
                    appendMessageLocked(&s, sessionID: sid, item: .assistant(assistant))
                }

            case "session.text.started":
                if let sid = jsonString(event.data, "sessionID"),
                   let msgID = jsonString(event.data, "assistantMessageID") {
                    editAssistantLocked(&s, sessionID: sid, messageID: msgID) { assistant in
                        var content = assistant.content
                        content.append(.text(SessionMessageSchema.AssistantText(text: "")))
                        return Self.copyAssistant(assistant, content: content)
                    }
                }

            case "session.text.delta":
                if let sid = jsonString(event.data, "sessionID"),
                   let msgID = jsonString(event.data, "assistantMessageID"),
                   let delta = jsonString(event.data, "delta") {
                    editAssistantLocked(&s, sessionID: sid, messageID: msgID) { assistant in
                        var content = assistant.content
                        if let pos = content.lastIndex(where: { if case .text = $0 { return true }; return false }),
                           case .text(let t) = content[pos] {
                            content[pos] = .text(SessionMessageSchema.AssistantText(text: t.text + delta, native: t.native))
                        }
                        return Self.copyAssistant(assistant, content: content)
                    }
                }

            case "session.text.ended":
                if let sid = jsonString(event.data, "sessionID"),
                   let msgID = jsonString(event.data, "assistantMessageID"),
                   let text = jsonString(event.data, "text") {
                    editAssistantLocked(&s, sessionID: sid, messageID: msgID) { assistant in
                        var content = assistant.content
                        if let pos = content.lastIndex(where: { if case .text = $0 { return true }; return false }),
                           case .text(let t) = content[pos] {
                            content[pos] = .text(SessionMessageSchema.AssistantText(text: text, native: t.native))
                        }
                        return Self.copyAssistant(assistant, content: content)
                    }
                }

            case "session.step.ended":
                if let sid = jsonString(event.data, "sessionID"),
                   let msgID = jsonString(event.data, "assistantMessageID") {
                    let finish = jsonString(event.data, "finish").flatMap(SessionMessageSchema.FinishReason.init(rawValue:))
                    let cost = jsonDouble(event.data, "cost")
                    let tokens = jsonField(event.data, "tokens").flatMap {
                        try? ClientCodec.fromJSONValue(SessionSchema.TokenUsage.self, value: $0)
                    }
                    editAssistantLocked(&s, sessionID: sid, messageID: msgID) { assistant in
                        SessionMessageSchema.Assistant(
                            id: assistant.id, metadata: assistant.metadata, agent: assistant.agent,
                            model: assistant.model, content: assistant.content, snapshot: assistant.snapshot,
                            finish: finish ?? assistant.finish, rawFinish: jsonString(event.data, "rawFinish") ?? assistant.rawFinish,
                            native: assistant.native, cost: cost ?? assistant.cost, tokens: tokens ?? assistant.tokens,
                            error: assistant.error, retry: assistant.retry,
                            time: SessionMessageSchema.Assistant.Time(
                                created: assistant.time.created,
                                firstToken: assistant.time.firstToken,
                                streamed: assistant.time.streamed,
                                completed: createdMs
                            )
                        )
                    }
                }

            case "session.revert.committed":
                if let sid = jsonString(event.data, "sessionID"),
                   let toID = jsonString(event.data, "to") {
                    if let info = s.sessionInfo[sid] {
                        s.sessionInfo[sid] = SessionSchema.Info(
                            id: info.id, parentID: info.parentID, fork: info.fork, projectID: info.projectID,
                            agent: info.agent, model: info.model, cost: info.cost, tokens: info.tokens,
                            outcome: info.outcome, time: info.time, title: info.title,
                            location: info.location, subpath: info.subpath, metadata: info.metadata,
                            permissions: info.permissions, revert: nil
                        )
                    }
                    if let pending = s.sessionPending[sid] {
                        s.sessionPending[sid] = pending.filter { $0.id.rawValue < toID }
                    }
                    if var list = s.sessionMessages[sid], let cut = list.firstIndex(where: { $0.id.rawValue >= toID }) {
                        list.removeSubrange(cut...)
                        s.sessionMessages[sid] = list
                        s.sessionMessageIndex[sid] = Dictionary(
                            uniqueKeysWithValues: list.enumerated().map { ($0.element.id.rawValue, $0.offset) }
                        )
                    }
                }

            case "permission.asked":
                if let req = try? ClientCodec.fromJSONValue(PermissionSchema.Request.self, value: event.data) {
                    let sid = req.sessionID.rawValue
                    var list = s.sessionPermissions[sid] ?? []
                    if !list.contains(where: { $0.id == req.id }) {
                        list.append(req)
                        s.sessionPermissions[sid] = list
                    }
                }

            case "permission.replied":
                if let sid = jsonString(event.data, "sessionID"),
                   let reqID = jsonString(event.data, "requestID") {
                    removePermissionLocked(&s, sessionID: sid, requestID: reqID)
                }

            case "form.created":
                if let formVal = jsonField(event.data, "form"),
                   let form = try? ClientCodec.fromJSONValue(FormSchema.Info.self, value: formVal) {
                    var list = s.sessionForms[form.sessionID] ?? []
                    if !list.contains(where: { $0.id == form.id }) {
                        let loc = form.sessionID == "global"
                            ? event.location.map {
                                LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: $0.directory), workspaceID: $0.workspaceID)
                            }
                            : nil
                        list.append(FormWithLocation(form: form, location: loc))
                        s.sessionForms[form.sessionID] = list
                    }
                }

            case "form.replied", "form.cancelled":
                if let sid = jsonString(event.data, "sessionID"),
                   let formID = jsonString(event.data, "id") {
                    let loc = event.location.map {
                        LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: $0.directory), workspaceID: $0.workspaceID)
                    }
                    _ = removeFormLocked(&s, sessionID: sid, formID: formID, location: loc)
                }

            case "shell.created":
                if let loc = event.location,
                   let infoVal = jsonField(event.data, "info"),
                   let info = try? ClientCodec.fromJSONValue(ShellSchema.Info.self, value: infoVal) {
                    let ref = LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: loc.directory), workspaceID: loc.workspaceID)
                    let key = locationKey(ref)
                    var entry = s.locations[key] ?? ClientLocationData()
                    var shells = entry.shell ?? [:]
                    shells[info.id.rawValue] = ShellWithLocation(shell: info, location: ref)
                    entry.shell = shells
                    s.locations[key] = entry
                }

            case "shell.exited", "shell.deleted":
                if let loc = event.location, let shellID = jsonString(event.data, "id") {
                    let key = locationKey(loc)
                    if var entry = s.locations[key], var shells = entry.shell, shells.removeValue(forKey: shellID) != nil {
                        entry.shell = shells
                        s.locations[key] = entry
                    }
                }

            case "server.connected":
                // Re-list every synced job tree: events missed while disconnected never arrive.
                let roots = Array(s.jobTree.keys)
                for root in roots { s.syncedKeys.remove("job:\(root)") }
                if !roots.isEmpty {
                    Task { [weak self] in
                        for root in roots { try? await self?.syncJobs(root) }
                    }
                }
                didMutate = false

            case "experimental.job.updated":
                guard let infoVal = jsonField(event.data, "info"),
                      let info = try? ClientCodec.fromJSONValue(JobSchema.Info.self, value: infoVal) else {
                    didMutate = false
                    break
                }
                let id = info.clientJobID
                let running = info.clientJobStatus == .running
                for key in Array(s.jobUpdates.keys) {
                    s.jobUpdates[key]?.updates[id] = .some(running ? info : nil)
                }
                if !running {
                    guard s.job[id] != nil else { didMutate = false; break }
                    s.job.removeValue(forKey: id)
                    for key in Array(s.jobTree.keys) { s.jobTree[key]?.remove(id) }
                    break
                }
                s.job[id] = info
                for key in Array(s.jobTree.keys) where jobWithinLocked(s, job: info, ancestorID: key) {
                    s.jobTree[key]?.insert(id)
                }

            case "session.tool.success":
                if let sid = jsonString(event.data, "sessionID"),
                   let msgID = jsonString(event.data, "assistantMessageID"),
                   let toolID = jsonString(event.data, "id"),
                   let contentVal = jsonField(event.data, "content"),
                   let rawContent = try? ClientCodec.fromJSONValue([SessionMessageSchema.ToolContent].self, value: contentVal) {
                    let content = omit ? Self.omitToolContents(rawContent) : rawContent
                    let meta: [String: JSONValue]
                    if case .object(let m) = jsonField(event.data, "metadata") { meta = m } else { meta = [:] }
                    editAssistantLocked(&s, sessionID: sid, messageID: msgID) { assistant in
                        var parts = assistant.content
                        if let pos = parts.lastIndex(where: { if case .tool(let t) = $0, t.id == toolID { return true }; return false }),
                           case .tool(let tool) = parts[pos],
                           case .running(let running) = tool.state {
                            let completed = SessionMessageSchema.ToolStateCompleted(
                                input: running.input,
                                content: content,
                                metadata: meta
                            )
                            let updated = SessionMessageSchema.AssistantTool(
                                id: tool.id,
                                name: tool.name,
                                executed: (jsonBool(event.data, "executed") ?? false) || (tool.executed == true),
                                native: tool.native,
                                state: .completed(completed),
                                time: SessionMessageSchema.AssistantTool.Time(
                                    created: tool.time.created,
                                    ran: tool.time.ran,
                                    completed: createdMs
                                )
                            )
                            parts[pos] = .tool(updated)
                        }
                        return Self.copyAssistant(assistant, content: parts)
                    }
                }

            default:
                didMutate = false
            }
        }

        if didMutate {
            notifyObservers()
        }
    }

    // MARK: - Private Locked Helpers

    private func listAllChildren(parentID: String) async throws -> [SessionSchema.Info] {
        var collected: [SessionSchema.Info] = []
        var cursor: String? = nil
        while true {
            let page = try await config.api().session.list(
                SessionListInput(
                    limit: Self.childPageLimit,
                    order: .desc,
                    parentID: cursor == nil ? parentID : nil,
                    cursor: cursor
                )
            )
            collected.append(contentsOf: page.data)
            if page.data.count < Self.childPageLimit || page.cursor.next == nil { break }
            cursor = page.cursor.next?.rawValue
        }
        return collected
    }

    private func resolveRootLocked(_ s: StoreState, sessionID: String) -> String {
        var current = sessionID
        var parentID = s.sessionInfo[sessionID]?.parentID?.rawValue
        var seen: Set<String> = [sessionID]
        while let next = parentID {
            if seen.contains(next) { break }
            seen.insert(next)
            current = next
            parentID = s.sessionInfo[next]?.parentID?.rawValue
        }
        return current
    }

    private func registerSessionLocked(_ s: inout StoreState, sessionID: String) {
        guard s.sessionInfo[sessionID] != nil else { return }
        let rootID = resolveRootLocked(s, sessionID: sessionID)
        if sessionID != rootID, let orphaned = s.sessionFamily.removeValue(forKey: sessionID) {
            var members = s.sessionFamily[rootID] ?? []
            for id in orphaned where !members.contains(id) {
                members.append(id)
            }
            s.sessionFamily[rootID] = members
        }
        var family = s.sessionFamily[rootID] ?? []
        if !family.contains(sessionID) {
            family.append(sessionID)
        }
        s.sessionFamily[rootID] = family
    }

    private func evictOneLocked(_ s: inout StoreState, sessionID: String) {
        if s.sessionOutbox.contains(sessionID) { return }
        s.syncedKeys.remove("session.pending:\(sessionID)")
        s.syncedKeys.remove("session.message:\(sessionID)")
        let pending = (s.sessionPending[sessionID] ?? []).filter { s.outbox.contains($0.id.rawValue) }
        let messages = (s.sessionMessages[sessionID] ?? []).filter { s.outbox.contains($0.id.rawValue) }
        s.sessionMessages.removeValue(forKey: sessionID)
        s.sessionMessageIndex.removeValue(forKey: sessionID)
        s.sessionMessageCursor.removeValue(forKey: sessionID)
        s.sessionMessageLoading.removeValue(forKey: sessionID)
        s.sessionPending.removeValue(forKey: sessionID)
        if !messages.isEmpty {
            s.sessionMessages[sessionID] = messages
            s.sessionMessageIndex[sessionID] = Dictionary(
                uniqueKeysWithValues: messages.enumerated().map { ($0.element.id.rawValue, $0.offset) }
            )
        }
        if !pending.isEmpty {
            s.sessionPending[sessionID] = pending
        }
    }

    private func clearDeletedLocked(_ s: inout StoreState, sessionID: String) {
        s.deletedAt.removeValue(forKey: sessionID)
        s.deletedOrder.removeAll { $0 == sessionID }
        s.sessionMissing.remove(sessionID)
    }

    private func markDeleted(_ sessionID: String) {
        let changed = state.withLock { s -> Bool in
            if s.sessionOutbox.contains(sessionID) { return false }
            markDeletedLocked(&s, sessionID: sessionID)
            return true
        }
        if changed { notifyObservers() }
    }

    private func markDeletedLocked(_ s: inout StoreState, sessionID: String) {
        if s.sessionOutbox.contains(sessionID) { return }
        s.deletionEpoch += 1
        s.deletedAt[sessionID] = s.deletionEpoch
        s.deletedOrder.removeAll { $0 == sessionID }
        s.deletedOrder.append(sessionID)
        if s.deletedOrder.count > Self.deletedSessionLimit {
            let oldest = s.deletedOrder.removeFirst()
            s.deletedAt.removeValue(forKey: oldest)
            s.sessionMissing.remove(oldest)
        }
        s.sessionMissing.insert(sessionID)
        removeSessionLocked(&s, sessionID: sessionID)
    }

    private func removeSessionLocked(_ s: inout StoreState, sessionID: String) {
        removeJobTreeLocked(&s, rootID: sessionID)
        for item in s.sessionPending[sessionID] ?? [] {
            s.outbox.remove(item.id.rawValue)
        }
        s.sessionInfo.removeValue(forKey: sessionID)
        s.sessionActive.removeValue(forKey: sessionID)
        s.sessionMessages.removeValue(forKey: sessionID)
        s.sessionMessageIndex.removeValue(forKey: sessionID)
        s.sessionMessageCursor.removeValue(forKey: sessionID)
        s.sessionMessageLoading.removeValue(forKey: sessionID)
        s.sessionPending.removeValue(forKey: sessionID)
        s.sessionPermissions.removeValue(forKey: sessionID)
        s.sessionForms.removeValue(forKey: sessionID)
        for (rootID, members) in s.sessionFamily {
            let next = members.filter { $0 != sessionID }
            if next.isEmpty {
                s.sessionFamily.removeValue(forKey: rootID)
            } else {
                s.sessionFamily[rootID] = next
            }
        }
    }

    /// Whether a session is the ancestor or one of its descendants, by the parents in loaded session info.
    private func withinTreeLocked(_ s: StoreState, sessionID: String, ancestorID: String) -> Bool {
        var seen: Set<String> = []
        var current: String? = sessionID
        while let id = current, !seen.contains(id) {
            if id == ancestorID { return true }
            seen.insert(id)
            current = s.sessionInfo[id]?.parentID?.rawValue
        }
        return false
    }

    /// A subagent job's session is the parent of the child it runs, so either can place it in a tree.
    private func jobWithinLocked(_ s: StoreState, job: JobSchema.Info, ancestorID: String) -> Bool {
        if withinTreeLocked(s, sessionID: job.clientJobSessionID, ancestorID: ancestorID) { return true }
        if case .subagent(let subagent) = job {
            return withinTreeLocked(s, sessionID: subagent.childSessionID.rawValue, ancestorID: ancestorID)
        }
        return false
    }

    private func removeJobTreeLocked(_ s: inout StoreState, rootID: String) {
        s.jobUpdates.removeValue(forKey: rootID)
        s.syncedKeys.remove("job:\(rootID)")
        guard let members = s.jobTree.removeValue(forKey: rootID) else { return }
        for id in members { s.job.removeValue(forKey: id) }
    }

    private func admitLocalLocked(_ s: inout StoreState, item: SessionInboxSchema.Info) {
        let sid: String
        switch item {
        case .user(let u): sid = u.sessionID.rawValue
        case .synthetic(let syn): sid = syn.sessionID.rawValue
        case .compaction(let comp): sid = comp.sessionID.rawValue
        case .move(let mv): sid = mv.sessionID.rawValue
        }
        var pending = s.sessionPending[sid] ?? []
        if let idx = pending.firstIndex(where: { $0.id == item.id }) {
            pending[idx] = item
        } else {
            pending.append(item)
        }
        s.sessionPending[sid] = pending
        materializeInboxLocked(&s, item: item)
    }

    private func materializeInboxLocked(_ s: inout StoreState, item: SessionInboxSchema.Info) {
        switch item {
        case .user(let u):
            let msg = SessionMessageSchema.Info.user(
                SessionMessageSchema.User(
                    id: u.id,
                    metadata: u.payload.metadata,
                    time: u.time,
                    text: u.payload.text,
                    files: u.payload.files,
                    agents: u.payload.agents,
                    skills: u.payload.skills
                )
            )
            upsertMessageLocked(&s, sessionID: u.sessionID.rawValue, item: msg)
        case .synthetic(let syn):
            let msg = SessionMessageSchema.Info.synthetic(
                SessionMessageSchema.Synthetic(
                    id: syn.id,
                    metadata: syn.payload.metadata,
                    time: syn.time,
                    text: syn.payload.text,
                    description: syn.payload.description
                )
            )
            upsertMessageLocked(&s, sessionID: syn.sessionID.rawValue, item: msg)
        case .compaction, .move:
            break
        }
    }

    private func retractLocalLocked(_ s: inout StoreState, sessionID: String, inboxID: String) {
        removePendingLocked(&s, sessionID: sessionID, inboxID: inboxID)
        guard let pos = s.sessionMessageIndex[sessionID]?[inboxID],
              var list = s.sessionMessages[sessionID],
              pos < list.count
        else { return }
        list.remove(at: pos)
        s.sessionMessages[sessionID] = list
        s.sessionMessageIndex[sessionID] = Dictionary(
            uniqueKeysWithValues: list.enumerated().map { ($0.element.id.rawValue, $0.offset) }
        )
    }

    private func removePendingLocked(_ s: inout StoreState, sessionID: String, inboxID: String) {
        guard let pending = s.sessionPending[sessionID], pending.contains(where: { $0.id.rawValue == inboxID }) else {
            return
        }
        s.sessionPending[sessionID] = pending.filter { $0.id.rawValue != inboxID }
    }

    private func removePermissionLocked(_ s: inout StoreState, sessionID: String, requestID: String) {
        guard let reqs = s.sessionPermissions[sessionID], reqs.contains(where: { $0.id.rawValue == requestID }) else {
            return
        }
        s.sessionPermissions[sessionID] = reqs.filter { $0.id.rawValue != requestID }
    }

    private func removeFormLocked(
        _ s: inout StoreState,
        sessionID: String,
        formID: String,
        location: LocationSchema.Ref?
    ) -> Bool {
        guard let forms = s.sessionForms[sessionID] else { return false }
        let locKey = location.map(locationKey)
        let next = forms.filter { item in
            if item.id.rawValue != formID { return true }
            if sessionID != "global" || locKey == nil { return false }
            return item.location.map(locationKey) != locKey
        }
        if next.count == forms.count { return false }
        s.sessionForms[sessionID] = next
        return true
    }

    private func appendMessageLocked(_ s: inout StoreState, sessionID: String, item: SessionMessageSchema.Info) {
        if s.sessionMessageIndex[sessionID]?[item.id.rawValue] != nil { return }
        var list = s.sessionMessages[sessionID] ?? []
        var index = s.sessionMessageIndex[sessionID] ?? [:]
        index[item.id.rawValue] = list.count
        list.append(item)
        s.sessionMessages[sessionID] = list
        s.sessionMessageIndex[sessionID] = index
    }

    private func upsertMessageLocked(_ s: inout StoreState, sessionID: String, item: SessionMessageSchema.Info) {
        var list = s.sessionMessages[sessionID] ?? []
        var index = s.sessionMessageIndex[sessionID] ?? [:]
        if let pos = index[item.id.rawValue], pos < list.count {
            list[pos] = item
        } else {
            index[item.id.rawValue] = list.count
            list.append(item)
        }
        s.sessionMessages[sessionID] = list
        s.sessionMessageIndex[sessionID] = index
    }

    private func editAssistantLocked(
        _ s: inout StoreState,
        sessionID: String,
        messageID: String,
        transform: (SessionMessageSchema.Assistant) -> SessionMessageSchema.Assistant
    ) {
        guard let pos = s.sessionMessageIndex[sessionID]?[messageID],
              var list = s.sessionMessages[sessionID],
              pos < list.count,
              case .assistant(let assistant) = list[pos]
        else { return }
        list[pos] = .assistant(transform(assistant))
        s.sessionMessages[sessionID] = list
    }

    private static func copyAssistant(
        _ a: SessionMessageSchema.Assistant,
        content: [SessionMessageSchema.AssistantContent]
    ) -> SessionMessageSchema.Assistant {
        SessionMessageSchema.Assistant(
            id: a.id, metadata: a.metadata, agent: a.agent, model: a.model,
            content: content, snapshot: a.snapshot, finish: a.finish,
            rawFinish: a.rawFinish, native: a.native, cost: a.cost,
            tokens: a.tokens, error: a.error, retry: a.retry, time: a.time
        )
    }

    private static func omitToolContents(_ items: [SessionMessageSchema.ToolContent]) -> [SessionMessageSchema.ToolContent] {
        items.map { item in
            switch item {
            case .text:
                return item
            case .file(let uri, let mime, let name):
                guard uri.hasPrefix("data:") else { return item }
                return .file(uri: "data:\(mime);base64,", mime: mime, name: name)
            }
        }
    }

    private static func omitMessageFileData(_ message: SessionMessageSchema.Info) -> SessionMessageSchema.Info {
        guard case .assistant(let a) = message else { return message }
        let updatedContent: [SessionMessageSchema.AssistantContent] = a.content.map { part in
            guard case .tool(let tool) = part else { return part }
            switch tool.state {
            case .completed(let c):
                let nextState = SessionMessageSchema.ToolState.completed(
                    SessionMessageSchema.ToolStateCompleted(
                        input: c.input,
                        content: omitToolContents(c.content),
                        metadata: c.metadata
                    )
                )
                return .tool(SessionMessageSchema.AssistantTool(
                    id: tool.id, name: tool.name, executed: tool.executed,
                    native: tool.native, state: nextState, time: tool.time
                ))
            case .error(let e):
                guard let content = e.content else { return part }
                let nextState = SessionMessageSchema.ToolState.error(
                    SessionMessageSchema.ToolStateError(
                        input: e.input,
                        error: e.error,
                        content: omitToolContents(content),
                        metadata: e.metadata
                    )
                )
                return .tool(SessionMessageSchema.AssistantTool(
                    id: tool.id, name: tool.name, executed: tool.executed,
                    native: tool.native, state: nextState, time: tool.time
                ))
            case .streaming, .running:
                return part
            }
        }
        return .assistant(copyAssistant(a, content: updatedContent))
    }

    private static func formRequestOptions(sessionID: String, location: LocationSchema.Ref?) -> RequestOptions? {
        guard sessionID == "global", let location else { return nil }
        return RequestOptions(headers: [
            "x-opencode-directory": ClientURLBuilder.encodeURIComponent(location.directory.rawValue),
        ])
    }

    private static func updatingMessageCreated(
        _ message: SessionMessageSchema.Info,
        created: Int64
    ) -> SessionMessageSchema.Info {
        let nextTime = SessionMessageSchema.TimeCreated(created: created)
        switch message {
        case .user(let u):
            return .user(SessionMessageSchema.User(
                id: u.id, metadata: u.metadata, time: nextTime, text: u.text,
                files: u.files, agents: u.agents, skills: u.skills
            ))
        case .synthetic(let syn):
            return .synthetic(SessionMessageSchema.Synthetic(
                id: syn.id, metadata: syn.metadata, time: nextTime,
                text: syn.text, description: syn.description
            ))
        default:
            return message
        }
    }

    private static func updatingInboxDelivery(
        _ item: SessionInboxSchema.Info,
        delivery: SessionInboxSchema.Delivery
    ) -> SessionInboxSchema.Info {
        switch item {
        case .user(let u):
            return .user(SessionInboxSchema.User(id: u.id, sessionID: u.sessionID, time: u.time, payload: u.payload, delivery: delivery))
        case .synthetic(let syn):
            return .synthetic(SessionInboxSchema.Synthetic(id: syn.id, sessionID: syn.sessionID, time: syn.time, payload: syn.payload, delivery: delivery))
        case .compaction(let c):
            return .compaction(SessionInboxSchema.Compaction(id: c.id, sessionID: c.sessionID, time: c.time, payload: c.payload, delivery: delivery))
        case .move(let m):
            return .move(SessionInboxSchema.Move(id: m.id, sessionID: m.sessionID, time: m.time, payload: m.payload, delivery: delivery))
        }
    }
}

/// Alias matching upstream `export type Data = ReturnType<typeof createData>`.
// parity: client/src/solid/data.ts#Data [status=implemented hash=cb74be101875]
public typealias ClientData = ClientDataStore

/// Creates an observable `ClientDataStore` wired to `config.event` and `config.api`.
// parity: client/src/solid/data.ts#createData [status=implemented hash=5d11b8feaefc]
public func createData(_ config: CreateDataInput) -> ClientDataStore {
    ClientDataStore(config: config)
}

// MARK: - Job Info Accessors

extension JobSchema.Info {
    fileprivate var clientJobID: String {
        switch self {
        case .shell(let v): return v.id
        case .subagent(let v): return v.id
        case .image(let v): return v.id
        case .video(let v): return v.id
        case .codemode(let v): return v.id
        }
    }

    fileprivate var clientJobSessionID: String {
        switch self {
        case .shell(let v): return v.sessionID.rawValue
        case .subagent(let v): return v.sessionID.rawValue
        case .image(let v): return v.sessionID.rawValue
        case .video(let v): return v.sessionID.rawValue
        case .codemode(let v): return v.sessionID.rawValue
        }
    }

    fileprivate var clientJobStatus: JobSchema.Status {
        switch self {
        case .shell(let v): return v.status
        case .subagent(let v): return v.status
        case .image(let v): return v.status
        case .video(let v): return v.status
        case .codemode(let v): return v.status
        }
    }
}

// MARK: - JSON Extraction Helpers

private func jsonField(_ value: JSONValue, _ key: String) -> JSONValue? {
    guard case .object(let obj) = value else { return nil }
    return obj[key]
}

private func jsonString(_ value: JSONValue, _ key: String) -> String? {
    guard case .string(let str) = jsonField(value, key) else { return nil }
    return str
}

private func jsonDouble(_ value: JSONValue, _ key: String) -> Double? {
    switch jsonField(value, key) {
    case .double(let d): d
    case .int(let i): Double(i)
    default: nil
    }
}

private func jsonBool(_ value: JSONValue, _ key: String) -> Bool? {
    guard case .bool(let b) = jsonField(value, key) else { return nil }
    return b
}
