import Synchronization

// The link over Iroh (`core/src/machine/iroh.ts`): the same handshake and frames as over the WebSocket route, on one
// bidirectional QUIC stream to the home's endpoint, whose key is the home key, so its endpoint id is the `home` of
// every join string. Each message the WebSocket route carries as one binary message is a 2-byte big-endian length and
// the message here. Iroh's own keep-alive (every 5 s) and idle timeout (30 s) take the place of the route's ping: a
// dead peer is noticed within 30 s, where the route takes 30 to 60.

/// Port of `core/src/machine/iroh.ts`.
public enum MachineIroh {
    public static let alpn: [UInt8] = Array("opencode-link/1".utf8)
    /// How much one read asks the binding for: it copies every byte through a JavaScript array upstream, so reads stay
    /// this size.
    public static let chunkSize = 64 * 1024
    /// As on the WebSocket route: handshakes in progress at once, and how long a stranger may take to open its stream.
    public static let maxHandshakes = 32
    public static let deadline: Duration = .seconds(10)
    /// As on the WebSocket route: how long a send waits on a peer that reads nothing before the connection is dropped.
    public static let stall: Duration = .seconds(60)
    /// The WebSocket route's close: policy violation, no reason, for every connection the home ends.
    public static let closeCode: UInt64 = 1008

    /// Error thrown by `listen` when no native Iroh binding is available for this platform.
    public struct Unavailable: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public let message: String

        public init(_ message: String = "no Iroh build for this platform") {
            self.message = message
        }

        public var description: String { message }
    }

    /// Only for tests, as `MachineLink.Fixed` is: `offline` binds on loopback with no relays and no address lookup,
    /// `load` stands in for the binding's import, and `watch` sees the endpoint once it is bound. Production never
    /// sets it.
    // parity: core/src/machine/iroh.ts#Testing [status=implemented hash=b0c0b4f83f95]
    public struct Testing: Sendable {
        public static let contextKey = "@opencode/MachineIroh/Testing"

        public let offline: Bool
        public let load: @Sendable () async throws -> (any MachineIrohBinding.Binding)?
        public let watch: @Sendable (any MachineIrohBinding.Endpoint) -> Void

        public init(
            offline: Bool = false,
            load: @escaping @Sendable () async throws -> (any MachineIrohBinding.Binding)? = MachineIrohBinding.load,
            watch: @escaping @Sendable (any MachineIrohBinding.Endpoint) -> Void = { _ in }
        ) {
            self.offline = offline
            self.load = load
            self.watch = watch
        }

        public static let defaultValue = Testing()
    }

    /// A running Iroh listener returned by `listen`: call `close()` when its scope ends.
    public final class Listener: Sendable {
        public let endpoint: any MachineIrohBinding.Endpoint
        private let acceptTask: Mutex<Task<Void, Never>?>
        private let closed = Mutex(false)

        init(endpoint: any MachineIrohBinding.Endpoint, acceptTask: Task<Void, Never>) {
            self.endpoint = endpoint
            self.acceptTask = Mutex(acceptTask)
        }

        public func close() async {
            let shouldClose = closed.withLock { flag -> Bool in
                if flag { return false }
                flag = true
                return true
            }
            guard shouldClose else { return }
            let task = acceptTask.withLock { current -> Task<Void, Never>? in
                let existing = current
                current = nil
                return existing
            }
            task?.cancel()
            await endpoint.close()
            await task?.value
        }
    }

    private final class PermitPool: Sendable {
        private let available: Mutex<Int>

        init(permits: Int) {
            self.available = Mutex(permits)
        }

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

    /// Binds the home's endpoint with the home key and serves every link that arrives on it, each as the WebSocket
    /// route serves one, until `Listener.close()` is called. `admit` is asked before each connection, as the route
    /// reads its flag on each upgrade. Fails when the binding is missing or cannot bind; links then keep coming over
    /// WebSockets only.
    // parity: core/src/machine/iroh.ts#listen [status=implemented hash=8c21b3fee3e4]
    public static func listen(
        admit: @escaping @Sendable () async -> Bool,
        identity: any MachineIdentity.Interface,
        machines: any Machines.Interface,
        testing: Testing = .defaultValue,
        deadline: Duration = MachineIroh.deadline,
        stall: Duration = MachineIroh.stall
    ) async throws -> Listener {
        guard let binding = try await testing.load() else {
            throw Unavailable("no Iroh build for this platform")
        }
        let builder = binding.makeEndpointBuilder()
        // The development default: n0's public relays and address lookup.
        if testing.offline {
            builder.applyMinimal()
            builder.bindAddr("127.0.0.1:0")
        } else {
            builder.applyN0()
        }
        builder.secretKey(try await identity.seed())
        builder.alpns([alpn])
        let endpoint = try await builder.bind()
        testing.watch(endpoint)
        let handshakes = PermitPool(permits: maxHandshakes)
        let acceptTask = Task {
            await withTaskGroup(of: Void.self) { group in
                while !Task.isCancelled {
                    guard let incoming = try? await endpoint.acceptNext() else { break }
                    group.addTask {
                        await serve(
                            incoming: incoming,
                            handshakes: handshakes,
                            admit: admit,
                            identity: identity,
                            machines: machines,
                            deadline: deadline,
                            stall: stall
                        )
                    }
                }
                group.cancelAll()
            }
        }
        return Listener(endpoint: endpoint, acceptTask: acceptTask)
    }

    /// One connection, from its QUIC handshake to the end of its link, as the WebSocket route serves an upgrade.
    private static func serve(
        incoming: any MachineIrohBinding.Incoming,
        handshakes: PermitPool,
        admit: @escaping @Sendable () async -> Bool,
        identity: any MachineIdentity.Interface,
        machines: any Machines.Interface,
        deadline: Duration,
        stall: Duration
    ) async {
        let on = await admit()
        if !on {
            await incoming.refuse()
            return
        }
        guard handshakes.tryAcquire() else {
            await incoming.refuse()
            return
        }

        let established: (connection: any MachineIrohBinding.Connection, served: MachineLink.Served)?
        do {
            defer { handshakes.release() }
            let connection = try await acceptWithDeadline(incoming: incoming, deadline: deadline)
            do {
                let stream = try await withDeadline(deadline) {
                    try await connection.acceptBi()
                }
                let linkCarrier = carrier(
                    stream,
                    drop: { connection.close(code: closeCode, reason: []) },
                    describe: {
                        if let path = connection.paths().first(where: \.isSelected) {
                            return MachineDriver.ConnectionInfo(
                                kind: .iroh,
                                path: path.isRelay ? .relayed : .direct,
                                rtt: path.rttMs
                            )
                        }
                        return MachineDriver.ConnectionInfo(kind: .iroh)
                    },
                    stall: stall
                )
                let served = try await MachineLink.serve(
                    linkCarrier,
                    identity: identity,
                    machines: machines,
                    deadline: deadline
                )
                established = (connection, served)
            } catch {
                connection.close(code: closeCode, reason: [])
                established = nil
            }
        } catch {
            established = nil
        }

        guard let established else { return }
        defer {
            established.served.close()
            established.connection.close(code: closeCode, reason: [])
        }
        try? await machines.connect(established.served.machine, established.served.connection)
    }

    private struct TimeoutError: Error {}

    private static func withDeadline<A: Sendable>(
        _ deadline: Duration,
        _ body: @escaping @Sendable () async throws -> A
    ) async throws -> A {
        try await withThrowingTaskGroup(of: A?.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: deadline)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let value = first else {
                throw TimeoutError()
            }
            return value
        }
    }

    private static func acceptWithDeadline(
        incoming: any MachineIrohBinding.Incoming,
        deadline: Duration
    ) async throws -> any MachineIrohBinding.Connection {
        let aborted = Mutex(false)
        do {
            return try await withDeadline(deadline) {
                let accepting = try await incoming.accept()
                let connection = try await accepting.connect()
                // The native handshake keeps running after cancellation/timeout abandons it.
                if aborted.withLock({ $0 }) || Task.isCancelled {
                    connection.close(code: closeCode, reason: [])
                    throw CancellationError()
                }
                return connection
            }
        } catch {
            aborted.withLock { $0 = true }
            throw error
        }
    }

    /// One bidirectional stream as the link's carrier, either side of it: each message is its 2-byte big-endian length
    /// and its bytes. What is held unread is at most one read past the message being read. `drop` ends the connection,
    /// which the reader then sees as the carrier closing.
    // parity: core/src/machine/iroh.ts#carrier [status=implemented hash=9f03c0881700]
    public static func carrier(
        _ stream: any MachineIrohBinding.BiStream,
        drop: @escaping @Sendable () -> Void,
        describe: (@Sendable () -> MachineDriver.ConnectionInfo)? = nil,
        stall: Duration = MachineIroh.stall
    ) -> any MachineLink.Carrier {
        StreamCarrier(stream: stream, drop: drop, describe: describe, stall: stall)
    }

    private actor StreamReader {
        private let recv: any MachineIrohBinding.RecvStream
        private var held: [UInt8] = []
        private var offset = 0
        private var end = 0

        init(recv: any MachineIrohBinding.RecvStream) {
            self.recv = recv
        }

        private func fill(_ length: Int) async throws {
            while end - offset < length {
                let read: [UInt8]
                do {
                    read = try await recv.read(MachineIroh.chunkSize)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw MachineLink.Closed()
                }
                if read.isEmpty { throw MachineLink.Closed() }
                if held.count - end < read.count {
                    let live = end - offset
                    let needed = max(length, live + read.count)
                    var next = [UInt8](repeating: 0, count: needed)
                    if live > 0 {
                        next.replaceSubrange(0..<live, with: held[offset..<end])
                    }
                    held = next
                    end = live
                    offset = 0
                }
                held.replaceSubrange(end..<(end + read.count), with: read)
                end += read.count
            }
        }

        func nextMessage() async throws -> [UInt8] {
            try await fill(2)
            let length = (Int(held[offset]) << 8) | Int(held[offset + 1])
            try await fill(2 + length)
            let message = Array(held[(offset + 2)..<(offset + 2 + length)])
            offset += 2 + length
            return message
        }
    }

    private final class StreamCarrier: MachineLink.Carrier, Sendable {
        private let sendStream: any MachineIrohBinding.SendStream
        private let reader: StreamReader
        private let drop: @Sendable () -> Void
        let describe: (@Sendable () -> MachineDriver.ConnectionInfo)?
        private let stall: Duration

        init(
            stream: any MachineIrohBinding.BiStream,
            drop: @escaping @Sendable () -> Void,
            describe: (@Sendable () -> MachineDriver.ConnectionInfo)?,
            stall: Duration
        ) {
            self.sendStream = stream.send
            self.reader = StreamReader(recv: stream.recv)
            self.drop = drop
            self.describe = describe
            self.stall = stall
        }

        func send(_ message: [UInt8]) async {
            guard message.count <= Int(UInt16.max) else {
                drop()
                return
            }
            var framed: [UInt8] = []
            framed.reserveCapacity(2 + message.count)
            framed.append(UInt8((message.count >> 8) & 0xff))
            framed.append(UInt8(message.count & 0xff))
            framed.append(contentsOf: message)
            let bytes = framed
            let sendStream = self.sendStream
            do {
                try await MachineIroh.withDeadline(stall) {
                    try await sendStream.writeAll(bytes)
                }
            } catch {
                drop()
            }
        }

        func receive() async throws -> [UInt8] {
            do {
                return try await reader.nextMessage()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw MachineLink.Closed()
            }
        }
    }
}
