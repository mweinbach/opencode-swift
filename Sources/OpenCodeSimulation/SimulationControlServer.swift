#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeServer
import OpenCodeUtil

/// Scoped WebSocket JSON-RPC 2.0 control server shared by frontend and backend simulation drivers
/// (`packages/simulation/src/control-server.ts`).
public enum SimulationControlServer {
    /// Maximum per-socket pending outbound byte budget (64 MiB), matching `maxOutboundBytes`.
    public static let maxOutboundBytes = 64 * 1024 * 1024

    /// Maximum bounded inbound request queue capacity (256), matching `Queue.bounded(256)`.
    public static let maxInboundQueueCapacity = 256

    /// Control-server runtime errors.
    public struct ControlError: Error, Equatable, Sendable, CustomStringConvertible {
        public let message: String

        public init(_ message: String) {
            self.message = message
        }

        public var description: String { message }
    }

    /// Running simulation WebSocket control server handle.
    // parity: simulation/src/control-server.ts#Server [status=implemented hash=34d36a342715]
    public final class Server: Sendable {
        public let url: String
        public let host: String
        public let port: Int
        private let closeHandler: @Sendable () async -> Void
        private let attachInMemoryHandler: @Sendable (any ServerWebSocketConnection) -> Task<Void, Never>

        internal init(
            url: String,
            host: String,
            port: Int,
            closeHandler: @escaping @Sendable () async -> Void,
            attachInMemoryHandler: @escaping @Sendable (any ServerWebSocketConnection) -> Task<Void, Never>
        ) {
            self.url = url
            self.host = host
            self.port = port
            self.closeHandler = closeHandler
            self.attachInMemoryHandler = attachInMemoryHandler
        }

        /// Stops accepting connections, terminates active sockets, and awaits all socket cleanup callbacks.
        public func close() async {
            await closeHandler()
        }

        /// Attaches an in-memory WebSocket connection directly to this control server (usable on all platforms including WASI).
        @discardableResult
        public func attachConnection(_ connection: any ServerWebSocketConnection) -> Task<Void, Never> {
            attachInMemoryHandler(connection)
        }
    }

    /// Per-connection state attached to a control server WebSocket.
    // parity: simulation/src/control-server.ts#SocketData [status=implemented hash=74e9e33bbbde]
    public final class SocketData: Sendable {
        public let drive: Bool

        private struct MutableState: Sendable {
            var attachment: Task<Void, Never>?
            var closed: Bool = false
        }

        private let state = Mutex(MutableState())

        public init(drive: Bool = false) {
            self.drive = drive
        }

        public var attachment: Task<Void, Never>? {
            get { state.withLock { $0.attachment } }
            set { state.withLock { $0.attachment = newValue } }
        }

        public var closed: Bool {
            get { state.withLock { $0.closed } }
            set { state.withLock { $0.closed = newValue } }
        }
    }

    /// Control-server socket wrapping serialized, byte-bounded outbound WebSocket sends.
    // parity: simulation/src/control-server.ts#Socket [status=implemented hash=ec958a049054]
    public final class Socket: Sendable {
        public let data: SocketData

        private actor OutboundQueue {
            private let connection: any ServerWebSocketConnection
            private let data: SocketData
            private let onTerminate: @Sendable () async -> Void
            private var pendingBytes: Int = 0
            private var terminated: Bool = false

            init(
                connection: any ServerWebSocketConnection,
                data: SocketData,
                onTerminate: @escaping @Sendable () async -> Void
            ) {
                self.connection = connection
                self.data = data
                self.onTerminate = onTerminate
            }

            func send(_ message: String) async throws {
                let bytes = message.utf8.count
                if terminated || data.closed {
                    await terminateNow()
                    throw ControlError("Simulation control socket is not open")
                }
                if bytes > SimulationControlServer.maxOutboundBytes || pendingBytes + bytes > SimulationControlServer.maxOutboundBytes {
                    await terminateNow()
                    throw ControlError("Simulation outbound queue exceeds \(SimulationControlServer.maxOutboundBytes) bytes")
                }
                pendingBytes += bytes
                defer { pendingBytes -= bytes }
                if terminated || data.closed {
                    await terminateNow()
                    throw ControlError("Simulation control socket is not open")
                }
                do {
                    try await connection.send(.text(message))
                } catch {
                    await terminateNow()
                    throw ControlError(String(describing: error))
                }
            }

            func terminateNow() async {
                guard !terminated else { return }
                terminated = true
                data.closed = true
                await connection.close(code: 1000, reason: "")
                await onTerminate()
            }
        }

        private let outbound: OutboundQueue

        internal init(
            data: SocketData,
            connection: any ServerWebSocketConnection,
            onTerminate: @escaping @Sendable () async -> Void
        ) {
            self.data = data
            self.outbound = OutboundQueue(connection: connection, data: data, onTerminate: onTerminate)
        }

        /// Sends a serialized text message over the control socket, enforcing the 64 MiB outbound bound.
        public func send(_ message: String) async throws {
            try await outbound.send(message)
        }

        /// Immediately closes the underlying socket and triggers cleanup.
        public func terminate() async {
            await outbound.terminateNow()
        }
    }

    /// Options for starting a simulation JSON-RPC WebSocket control server.
    public struct StartOptions<RequestType: Sendable>: Sendable {
        public let endpoint: String
        public let label: String
        public let data: @Sendable () -> SocketData
        public let decode: @Sendable (String) throws -> RequestType
        public let requestID: @Sendable (RequestType) -> OpenCodeProtocol.JsonRpc.ID?
        public let handle: @Sendable (Socket, RequestType) async throws -> JSONValue
        public let close: (@Sendable (Socket) async -> Void)?
        public let bindNetwork: Bool

        public init(
            endpoint: String,
            label: String,
            data: @escaping @Sendable () -> SocketData,
            decode: @escaping @Sendable (String) throws -> RequestType,
            requestID: @escaping @Sendable (RequestType) -> OpenCodeProtocol.JsonRpc.ID?,
            handle: @escaping @Sendable (Socket, RequestType) async throws -> JSONValue,
            close: (@Sendable (Socket) async -> Void)? = nil,
            bindNetwork: Bool = true
        ) {
            self.endpoint = endpoint
            self.label = label
            self.data = data
            self.decode = decode
            self.requestID = requestID
            self.handle = handle
            self.close = close
            self.bindNetwork = bindNetwork
        }
    }

    // MARK: - Bounded Inbound Request Queue

    private struct QueuedMessage: Sendable {
        let socket: Socket
        let input: String
    }

    private final class BoundedInboundQueue: Sendable {
        private struct State: Sendable {
            var buffer: [QueuedMessage] = []
            var waiter: CheckedContinuation<QueuedMessage?, Never>? = nil
            var closed: Bool = false
        }

        private let capacity: Int
        private let state = Mutex(State())

        init(capacity: Int) {
            self.capacity = capacity
        }

        func tryEnqueue(_ item: QueuedMessage) -> Bool {
            enum Action {
                case deliver(CheckedContinuation<QueuedMessage?, Never>)
                case enqueued
                case rejected
            }
            let action: Action = state.withLock { s in
                if s.closed { return .rejected }
                if let waiter = s.waiter {
                    s.waiter = nil
                    return .deliver(waiter)
                }
                if s.buffer.count >= capacity {
                    return .rejected
                }
                s.buffer.append(item)
                return .enqueued
            }
            switch action {
            case .deliver(let cont):
                cont.resume(returning: item)
                return true
            case .enqueued:
                return true
            case .rejected:
                return false
            }
        }

        func take() async -> QueuedMessage? {
            let immediate: QueuedMessage?? = state.withLock { s in
                if !s.buffer.isEmpty {
                    return .some(s.buffer.removeFirst())
                }
                if s.closed {
                    return .some(nil)
                }
                return nil
            }
            if let immediate {
                return immediate
            }
            return await withCheckedContinuation { continuation in
                let direct: QueuedMessage?? = state.withLock { s in
                    if !s.buffer.isEmpty {
                        return .some(s.buffer.removeFirst())
                    }
                    if s.closed {
                        return .some(nil)
                    }
                    s.waiter = continuation
                    return nil
                }
                if let direct {
                    continuation.resume(returning: direct)
                }
            }
        }

        func close() {
            let waiter: CheckedContinuation<QueuedMessage?, Never>? = state.withLock { s in
                s.closed = true
                let w = s.waiter
                s.waiter = nil
                return w
            }
            waiter?.resume(returning: nil)
        }
    }

    // MARK: - Connection Tracking

    private final class ConnectionRecord: Sendable {
        let id: UUID
        let socket: Socket
        private let cleanupFn: @Sendable (Socket) async -> Void
        private let onRemoved: @Sendable (UUID) -> Void
        private let cleanupTask = Mutex<Task<Void, Never>?>(nil)

        init(
            id: UUID,
            socket: Socket,
            cleanupFn: @escaping @Sendable (Socket) async -> Void,
            onRemoved: @escaping @Sendable (UUID) -> Void
        ) {
            self.id = id
            self.socket = socket
            self.cleanupFn = cleanupFn
            self.onRemoved = onRemoved
        }

        func runCleanupOnce() async {
            socket.data.closed = true
            let task: Task<Void, Never> = cleanupTask.withLock { existing in
                if let existing { return existing }
                let created = Task { [socket, cleanupFn, onRemoved, id] in
                    await cleanupFn(socket)
                    onRemoved(id)
                }
                existing = created
                return created
            }
            await task.value
        }
    }

    /// Starts a scoped WebSocket JSON-RPC 2.0 control server bound to `options.endpoint`.
    // parity: simulation/src/control-server.ts#start [status=implemented hash=a959a4ef88a6]
    public static func start<RequestType: Sendable>(
        options: StartOptions<RequestType>,
        scope: LayerNode.ResourceScope? = nil
    ) async throws -> Server {
        let parsed = try parseEndpoint(options.endpoint)
        let queue = BoundedInboundQueue(capacity: maxInboundQueueCapacity)
        let records = Mutex<[UUID: ConnectionRecord]>([:])
        let stopped = Mutex(false)

        // Worker task sequentially draining inbound messages and writing JSON-RPC responses.
        let workerTask = Task {
            while let msg = await queue.take() {
                if Task.isCancelled { break }
                let request: RequestType
                do {
                    request = try options.decode(msg.input)
                } catch {
                    let failure = OpenCodeProtocol.JsonRpc.failure(id: nil, message: formatErrorMessage(error))
                    try? await sendResponse(msg.socket, failure)
                    continue
                }
                let reqID = options.requestID(request)
                do {
                    let result = try await options.handle(msg.socket, request)
                    if let response = OpenCodeProtocol.JsonRpc.success(id: reqID, result: result) {
                        try? await sendResponse(msg.socket, response)
                    }
                } catch {
                    let failure = OpenCodeProtocol.JsonRpc.failure(id: reqID, message: formatErrorMessage(error))
                    try? await sendResponse(msg.socket, failure)
                }
            }
        }

        let serveWebSocket: @Sendable (any ServerWebSocketConnection) async -> Void = { connection in
            let id = UUID()
            let socketData = options.data()
            let recordBox = Mutex<ConnectionRecord?>(nil)
            let readTaskBox = Mutex<Task<Void, Never>?>(nil)
            let socket = Socket(
                data: socketData,
                connection: connection,
                onTerminate: {
                    readTaskBox.withLock { $0?.cancel() }
                    if let rec = recordBox.withLock({ $0 }) {
                        await rec.runCleanupOnce()
                    }
                }
            )
            let record = ConnectionRecord(
                id: id,
                socket: socket,
                cleanupFn: { sock in
                    if let closeFn = options.close {
                        await closeFn(sock)
                    }
                },
                onRemoved: { removedID in
                    records.withLock { _ = $0.removeValue(forKey: removedID) }
                }
            )
            recordBox.withLock { $0 = record }
            let alreadyStopped = stopped.withLock { isStopped -> Bool in
                if isStopped { return true }
                records.withLock { $0[id] = record }
                return false
            }
            if alreadyStopped {
                await socket.terminate()
                await record.runCleanupOnce()
                return
            }

            let readTask = Task {
                for await frame in connection.incoming {
                    if Task.isCancelled || stopped.withLock({ $0 }) || socketData.closed { break }
                    let input: String
                    switch frame {
                    case .text(let text):
                        input = text
                    case .binary(let bytes):
                        input = String(decoding: bytes, as: UTF8.self)
                    case .close:
                        return
                    }
                    if !queue.tryEnqueue(QueuedMessage(socket: socket, input: input)) {
                        let fullError = OpenCodeProtocol.JsonRpc.failure(
                            id: nil,
                            message: "Simulation control queue is full"
                        )
                        try? await sendResponse(socket, fullError)
                    }
                }
            }
            readTaskBox.withLock { $0 = readTask }
            if socketData.closed || stopped.withLock({ $0 }) {
                readTask.cancel()
            }
            await readTask.value
            await record.runCleanupOnce()
        }

        let httpServer: POSIXHTTPServer?
        let resolvedHost: String
        let resolvedPort: Int
        let resolvedURL: String

        if options.bindNetwork {
            let started = try POSIXHTTPServer.start(hostname: parsed.host, port: parsed.port) { request in
                guard let upgrade = request.upgradeWebSocket else {
                    return ServerHTTPResponse.text("Upgrade Required", statusCode: 426)
                }
                do {
                    let ws = try await upgrade()
                    await serveWebSocket(ws)
                    return ServerHTTPResponse(statusCode: 101, webSocketUpgraded: true)
                } catch {
                    return ServerHTTPResponse.text("WebSocket upgrade failed", statusCode: 400)
                }
            }
            httpServer = started
            resolvedHost = started.address.host
            resolvedPort = started.address.port
            resolvedURL = parsed.port == 0
                ? "ws://\(started.address.host):\(started.address.port)\(parsed.path)"
                : options.endpoint
        } else {
            httpServer = nil
            resolvedHost = parsed.host
            resolvedPort = parsed.port
            resolvedURL = options.endpoint
        }

        let shutdownFn: @Sendable () async -> Void = {
            let already = stopped.withLock { flag -> Bool in
                if flag { return true }
                flag = true
                return false
            }
            guard !already else { return }

            let accepted = records.withLock { Array($0.values) }
            for record in accepted {
                record.socket.data.closed = true
            }
            httpServer?.stop()
            queue.close()
            workerTask.cancel()
            await withTaskGroup(of: Void.self) { group in
                for record in accepted {
                    group.addTask {
                        await record.socket.terminate()
                        await record.runCleanupOnce()
                    }
                }
            }
        }

        if let scope {
            scope.addFinalizer(shutdownFn)
        }

        return Server(
            url: resolvedURL,
            host: resolvedHost,
            port: resolvedPort,
            closeHandler: shutdownFn,
            attachInMemoryHandler: { connection in
                Task {
                    await serveWebSocket(connection)
                }
            }
        )
    }

    // MARK: - Helpers

    private static func formatErrorMessage(_ error: any Error) -> String {
        if let dispatchErr = error as? OpenCodeProtocol.Handshake.DispatchError {
            switch dispatchErr {
            case .roleMismatch(let err): return err.message
            case .unsupportedProtocol(let err): return err.message
            case .missingCapability(let err): return err.message
            }
        }
        if let protocolErr = error as? any ProtocolError {
            return protocolErr.message
        }
        return String(describing: error)
    }

    private static func sendResponse(
        _ socket: Socket,
        _ response: OpenCodeProtocol.JsonRpc.Response
    ) async throws {
        let encoded = try ServerCodec.encodeString(response)
        try await socket.send(encoded)
    }

    private struct ParsedEndpoint {
        let host: String
        let port: Int
        let path: String
    }

    private static func parseEndpoint(_ endpoint: String) throws -> ParsedEndpoint {
        guard endpoint.hasPrefix("ws://") || endpoint.hasPrefix("wss://") else {
            throw ControlError("Invalid WebSocket control server endpoint: \(endpoint)")
        }
        let schemeLen = endpoint.hasPrefix("wss://") ? 6 : 5
        let remainder = endpoint.dropFirst(schemeLen)
        let pathStart = remainder.firstIndex(of: "/") ?? remainder.endIndex
        let authority = String(remainder[..<pathStart])
        let path = pathStart == remainder.endIndex ? "" : String(remainder[pathStart...])
        guard let colon = authority.lastIndex(of: ":") else {
            throw ControlError("Control server endpoint must include an explicit port: \(endpoint)")
        }
        let host = String(authority[..<colon])
        let portStr = String(authority[authority.index(after: colon)...])
        guard !host.isEmpty, let port = Int(portStr), port >= 0, port <= 65_535 else {
            throw ControlError("Invalid host or port in control server endpoint: \(endpoint)")
        }
        return ParsedEndpoint(host: host, port: port, path: path)
    }
}
