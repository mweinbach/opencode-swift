#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodeCore
import OpenCodePlatform

/// Non-Testing fixtures for the machine suites (keeps Foundation out of files that `import Testing`).
enum MachineTestHelper {
    static func hex(_ text: String) -> [UInt8] {
        var out: [UInt8] = []
        var chars = Array(text.utf8)
        if chars.count % 2 == 1 { chars.insert(UInt8(ascii: "0"), at: 0) }
        var index = 0
        while index < chars.count {
            out.append(UInt8(String(decoding: chars[index..<(index + 2)], as: UTF8.self), radix: 16) ?? 0)
            index += 2
        }
        return out
    }

    static func toHex(_ bytes: [UInt8]) -> String {
        bytes.map { byte in
            let text = String(byte, radix: 16)
            return text.count == 1 ? "0" + text : text
        }.joined()
    }

    static func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }
    static func utf8(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    /// A join string with `fields` replacing upstream's test value's fields, as `encodeRaw` builds one.
    static func rawJoin(_ fields: [String: String]) -> String {
        var wire: [(String, String)] = [
            ("v", "1"),
            ("home", "\"\(MachineCrypto.base64URLEncode([UInt8](repeating: 1, count: 32)))\""),
            ("secret", "\"\(MachineCrypto.base64URLEncode([UInt8](repeating: 2, count: 32)))\""),
            ("expires", "1767225600000"),
            ("reach", "[{\"type\":\"url\",\"url\":\"https://home.example\"}]"),
        ]
        for (key, value) in fields {
            if let index = wire.firstIndex(where: { $0.0 == key }) { wire[index].1 = value } else { wire.append((key, value)) }
        }
        let json = "{" + wire.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + "}"
        return "ocjoin_" + MachineCrypto.base64URLEncode(Array(json.utf8))
    }

    /// A home identity with a fixed seed.
    struct FixedIdentity: MachineIdentity.Interface {
        let rawSeed: [UInt8]
        let key: MachineIdentity.Key
        init(seed: [UInt8]) {
            self.rawSeed = seed
            self.key = MachineIdentity.fromSeed(seed)
        }
        func publicKey() async throws(MachineIdentity.InvalidKey) -> [UInt8] { key.publicKey }
        func sign(_ bytes: [UInt8]) async throws(MachineIdentity.InvalidKey) -> [UInt8] { key.sign(bytes) }
        func seed() async throws(MachineIdentity.InvalidKey) -> [UInt8] { rawSeed }
    }

    /// A one-way queue of messages whose `take` honours cancellation.
    final class Channel: Sendable {
        private struct State {
            var buffer: [[UInt8]] = []
            var waiter: CheckedContinuation<[UInt8]?, Never>?
            var closed = false
        }

        private let state = Mutex(State())

        func put(_ message: [UInt8]) {
            let waiter = state.withLock { s -> CheckedContinuation<[UInt8]?, Never>? in
                if s.closed { return nil }
                if let waiter = s.waiter {
                    s.waiter = nil
                    return waiter
                }
                s.buffer.append(message)
                return nil
            }
            waiter?.resume(returning: message)
        }

        func close() {
            let waiter = state.withLock { s -> CheckedContinuation<[UInt8]?, Never>? in
                s.closed = true
                defer { s.waiter = nil }
                return s.waiter
            }
            waiter?.resume(returning: nil)
        }

        func take() async -> [UInt8]? {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<[UInt8]?, Never>) in
                    let ready = state.withLock { s -> [UInt8]?? in
                        if !s.buffer.isEmpty { return .some(s.buffer.removeFirst()) }
                        if s.closed || Task.isCancelled { return .some(nil) }
                        s.waiter = continuation
                        return nil
                    }
                    if let ready { continuation.resume(returning: ready) }
                }
            } onCancel: {
                let waiter = state.withLock { s -> CheckedContinuation<[UInt8]?, Never>? in
                    defer { s.waiter = nil }
                    return s.waiter
                }
                waiter?.resume(returning: nil)
            }
        }
    }

    /// Replaces a message on its way, or drops it when returning `nil`. `index` counts per direction.
    typealias Tamper = @Sendable ([UInt8], Int) -> [UInt8]?

    /// One end of an in-memory carrier pair, recording what it sent and how many reads are waiting.
    final class Pipe: MachineLink.Carrier, Sendable {
        private let inbox: Channel
        private let outbox: Channel
        private let log = Mutex<[[UInt8]]>([])
        private let waitingReads = Mutex(0)
        private let tamper: Tamper?
        let describe: (@Sendable () -> MachineDriver.ConnectionInfo)?

        init(
            inbox: Channel,
            outbox: Channel,
            tamper: Tamper? = nil,
            describe: (@Sendable () -> MachineDriver.ConnectionInfo)? = nil
        ) {
            self.inbox = inbox
            self.outbox = outbox
            self.tamper = tamper
            self.describe = describe
        }

        var sent: [[UInt8]] { log.withLock { $0 } }
        var readsWaiting: Int { waitingReads.withLock { $0 } }

        func send(_ message: [UInt8]) async {
            let index = log.withLock { s -> Int in
                let i = s.count
                s.append(message)
                return i
            }
            let delivered = tamper?(message, index) ?? (tamper == nil ? message : nil)
            if let delivered {
                outbox.put(delivered)
            }
        }

        func receive() async throws -> [UInt8] {
            waitingReads.withLock { $0 += 1 }
            defer { waitingReads.withLock { $0 -= 1 } }
            guard let next = await inbox.take() else { throw MachineLink.Closed() }
            return next
        }

        func close() {
            inbox.close()
            outbox.close()
        }

        static func pair(
            toHome: Tamper? = nil,
            toWorker: Tamper? = nil,
            homeDescribe: (@Sendable () -> MachineDriver.ConnectionInfo)? = nil
        ) -> (home: Pipe, worker: Pipe) {
            let toA = Channel()
            let toB = Channel()
            return (
                home: Pipe(inbox: toA, outbox: toB, tamper: toWorker, describe: homeDescribe),
                worker: Pipe(inbox: toB, outbox: toA, tamper: toHome)
            )
        }
    }

    /// A home's machine list on a fresh in-memory database.
    static func machines(
        seed: [UInt8] = [UInt8](repeating: 1, count: 32),
        now: @escaping @Sendable () -> Int64 = { 1_000 }
    ) throws -> (Machines.Service, FixedIdentity, any SQLiteDatabase) {
        let client = try SQLiteDatabaseFactory.open(path: ":memory:")
        let database = try CoreDatabaseStore.bootstrap(client: client)
        let identity = FixedIdentity(seed: seed)
        return (try Machines.Service(database: database.db, identity: identity, now: now), identity, database.db)
    }

    /// A worker connection the test drives: what the machine sends, and a way to send it messages.
    final class FakeWorker: Sendable {
        let connection: MachineDriver.Connection
        private let received = MachineMutexBox<[MachineWire.ToWorker]>([])
        private let continuation: AsyncStream<MachineWire.FromWorker>.Continuation

        init(
            hello: MachineWire.Hello,
            describe: (@Sendable () -> MachineDriver.ConnectionInfo)? = nil
        ) {
            let (stream, continuation) = AsyncStream<MachineWire.FromWorker>.makeStream()
            self.continuation = continuation
            let received = self.received
            connection = MachineDriver.Connection(
                hello: hello,
                send: { message in received.mutate { $0.append(message) } },
                messages: stream,
                describe: describe
            )
        }

        var messages: [MachineWire.ToWorker] { received.get() }

        func reply(_ message: MachineWire.FromWorker) { continuation.yield(message) }
        func drop() { continuation.finish() }

        /// Waits until the machine has sent a message matching `predicate`.
        func next(where predicate: @Sendable (MachineWire.ToWorker) -> Bool) async -> MachineWire.ToWorker? {
            for _ in 0..<2_000 {
                if let found = messages.first(where: predicate) { return found }
                try? await Task.sleep(for: .milliseconds(1))
            }
            return nil
        }
    }

    static func hello(instance: String = "one", processes: [MachineWire.HelloProcess] = []) -> MachineWire.Hello {
        MachineWire.Hello(os: "linux", arch: "x64", home: "/home/me", instance: MachineWire.Instance(instance), processes: processes)
    }

    /// Waits until the async `condition` holds.
    static func eventuallyAsync(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<2_000 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return await condition()
    }

    /// Waits until `condition` holds.
    static func eventually(_ condition: @Sendable () -> Bool) async -> Bool {
        for _ in 0..<2_000 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

    // MARK: - Iroh Mock Fixtures (for testing MachineIroh.carrier & MachineIroh.listen without a native binding)

    struct UnusedStreamError: Error {}

    final class ChunkedRecvStream: MachineIrohBinding.RecvStream, Sendable {
        private let chunks: Mutex<[[UInt8]]>

        init(_ chunks: [[UInt8]]) {
            self.chunks = Mutex(chunks)
        }

        func read(_ maxBytes: Int) async throws -> [UInt8] {
            chunks.withLock { list in
                list.isEmpty ? [] : list.removeFirst()
            }
        }
    }

    final class RecordingSendStream: MachineIrohBinding.SendStream, Sendable {
        private let writtenBox = Mutex<[[UInt8]]>([])
        private let failNext: Mutex<Bool>
        private let delay: Duration?

        init(fail: Bool = false, delay: Duration? = nil) {
            self.failNext = Mutex(fail)
            self.delay = delay
        }

        var written: [[UInt8]] { writtenBox.withLock { $0 } }

        func writeAll(_ bytes: [UInt8]) async throws {
            if let delay {
                try await Task.sleep(for: delay)
            }
            if failNext.withLock({ $0 }) {
                throw UnusedStreamError()
            }
            writtenBox.withLock { $0.append(bytes) }
        }
    }

    struct StaticBiStream: MachineIrohBinding.BiStream, Sendable {
        let recv: any MachineIrohBinding.RecvStream
        let send: any MachineIrohBinding.SendStream
    }

    final class InMemoryByteQueue: Sendable {
        private struct State {
            var buffer: [UInt8] = []
            var waiter: CheckedContinuation<[UInt8], Never>?
            var closed = false
        }

        private let state = Mutex(State())

        func write(_ bytes: [UInt8]) {
            guard !bytes.isEmpty else { return }
            let waiter = state.withLock { s -> CheckedContinuation<[UInt8], Never>? in
                if s.closed { return nil }
                if let waiter = s.waiter {
                    s.waiter = nil
                    return waiter
                }
                s.buffer.append(contentsOf: bytes)
                return nil
            }
            waiter?.resume(returning: bytes)
        }

        func close() {
            let waiter = state.withLock { s -> CheckedContinuation<[UInt8], Never>? in
                s.closed = true
                defer { s.waiter = nil }
                return s.waiter
            }
            waiter?.resume(returning: [])
        }

        func read(_ maxBytes: Int) async -> [UInt8] {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<[UInt8], Never>) in
                    let immediate: [UInt8]? = state.withLock { s in
                        if !s.buffer.isEmpty {
                            let count = min(maxBytes, s.buffer.count)
                            let slice = Array(s.buffer[0..<count])
                            s.buffer.removeFirst(count)
                            return slice
                        }
                        if s.closed || Task.isCancelled { return [] }
                        s.waiter = continuation
                        return nil
                    }
                    if let immediate { continuation.resume(returning: immediate) }
                }
            } onCancel: {
                let waiter = state.withLock { s -> CheckedContinuation<[UInt8], Never>? in
                    defer { s.waiter = nil }
                    return s.waiter
                }
                waiter?.resume(returning: [])
            }
        }
    }

    final class InMemoryRecvStream: MachineIrohBinding.RecvStream, Sendable {
        private let queue: InMemoryByteQueue
        init(_ queue: InMemoryByteQueue) { self.queue = queue }
        func read(_ maxBytes: Int) async throws -> [UInt8] { await queue.read(maxBytes) }
    }

    final class InMemorySendStream: MachineIrohBinding.SendStream, Sendable {
        private let queue: InMemoryByteQueue
        init(_ queue: InMemoryByteQueue) { self.queue = queue }
        func writeAll(_ bytes: [UInt8]) async throws { queue.write(bytes) }
    }

    final class MockIrohConnection: MachineIrohBinding.Connection, Sendable {
        let serverStream: StaticBiStream
        let clientStream: StaticBiStream
        private let toServer: InMemoryByteQueue
        private let toClient: InMemoryByteQueue
        private let pathInfos: Mutex<[MachineIrohBinding.PathInfo]>
        private let closedCodeBox = Mutex<UInt64?>(nil)

        init(paths: [MachineIrohBinding.PathInfo]) {
            let toServer = InMemoryByteQueue()
            let toClient = InMemoryByteQueue()
            self.toServer = toServer
            self.toClient = toClient
            self.serverStream = StaticBiStream(recv: InMemoryRecvStream(toServer), send: InMemorySendStream(toClient))
            self.clientStream = StaticBiStream(recv: InMemoryRecvStream(toClient), send: InMemorySendStream(toServer))
            self.pathInfos = Mutex(paths)
        }

        var closedCode: UInt64? { closedCodeBox.withLock { $0 } }

        func setPaths(_ paths: [MachineIrohBinding.PathInfo]) {
            pathInfos.withLock { $0 = paths }
        }

        func acceptBi() async throws -> any MachineIrohBinding.BiStream {
            serverStream
        }

        func paths() -> [MachineIrohBinding.PathInfo] {
            pathInfos.withLock { $0 }
        }

        func close(code: UInt64, reason: [UInt8]) {
            closedCodeBox.withLock { if $0 == nil { $0 = code } }
            toServer.close()
            toClient.close()
        }
    }

    final class MockIrohAccepting: MachineIrohBinding.Accepting, Sendable {
        let connection: MockIrohConnection
        init(connection: MockIrohConnection) { self.connection = connection }
        func connect() async throws -> any MachineIrohBinding.Connection { connection }
    }

    final class MockIrohIncoming: MachineIrohBinding.Incoming, Sendable {
        let connection: MockIrohConnection
        private let refusedBox = Mutex(false)

        init(paths: [MachineIrohBinding.PathInfo]) {
            self.connection = MockIrohConnection(paths: paths)
        }

        var refused: Bool { refusedBox.withLock { $0 } }

        func accept() async throws -> any MachineIrohBinding.Accepting {
            MockIrohAccepting(connection: connection)
        }

        func refuse() async {
            refusedBox.withLock { $0 = true }
            connection.close(code: 0, reason: [])
        }
    }

    final class MockIrohEndpoint: MachineIrohBinding.Endpoint, Sendable {
        private struct State {
            var queue: [MockIrohIncoming] = []
            var waiter: CheckedContinuation<(any MachineIrohBinding.Incoming)?, Never>?
            var closed = false
        }

        private let state = Mutex(State())
        let boundAddress: String

        init(boundAddress: String) {
            self.boundAddress = boundAddress
        }

        var isClosed: Bool { state.withLock { $0.closed } }

        func enqueue(_ incoming: MockIrohIncoming) {
            let waiter = state.withLock { s -> CheckedContinuation<(any MachineIrohBinding.Incoming)?, Never>? in
                if s.closed { return nil }
                if let waiter = s.waiter {
                    s.waiter = nil
                    return waiter
                }
                s.queue.append(incoming)
                return nil
            }
            waiter?.resume(returning: incoming)
        }

        func acceptNext() async throws -> (any MachineIrohBinding.Incoming)? {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<(any MachineIrohBinding.Incoming)?, Never>) in
                    let immediate: (any MachineIrohBinding.Incoming)?? = state.withLock { s in
                        if !s.queue.isEmpty { return .some(s.queue.removeFirst()) }
                        if s.closed || Task.isCancelled { return .some(nil) }
                        s.waiter = continuation
                        return nil
                    }
                    if let immediate { continuation.resume(returning: immediate) }
                }
            } onCancel: {
                let waiter = state.withLock { s -> CheckedContinuation<(any MachineIrohBinding.Incoming)?, Never>? in
                    defer { s.waiter = nil }
                    return s.waiter
                }
                waiter?.resume(returning: nil)
            }
        }

        func boundSockets() -> [String] { [boundAddress] }

        func close() async {
            let waiter = state.withLock { s -> CheckedContinuation<(any MachineIrohBinding.Incoming)?, Never>? in
                s.closed = true
                defer { s.waiter = nil }
                return s.waiter
            }
            waiter?.resume(returning: nil)
        }
    }

    final class MockIrohBuilder: MachineIrohBinding.EndpointBuilder, Sendable {
        struct Recorded: Equatable, Sendable {
            var usedMinimal = false
            var usedN0 = false
            var bindAddress: String?
            var secretKey: [UInt8]?
            var alpns: [[UInt8]] = []
        }

        private let recordedBox = Mutex(Recorded())
        private let onBind: @Sendable (MockIrohEndpoint) -> Void

        init(onBind: @escaping @Sendable (MockIrohEndpoint) -> Void) {
            self.onBind = onBind
        }

        var recorded: Recorded { recordedBox.withLock { $0 } }

        func applyMinimal() { recordedBox.withLock { $0.usedMinimal = true } }
        func applyN0() { recordedBox.withLock { $0.usedN0 = true } }
        func bindAddr(_ address: String) { recordedBox.withLock { $0.bindAddress = address } }
        func secretKey(_ key: [UInt8]) { recordedBox.withLock { $0.secretKey = key } }
        func alpns(_ alpns: [[UInt8]]) { recordedBox.withLock { $0.alpns = alpns } }

        func bind() async throws -> any MachineIrohBinding.Endpoint {
            let addr = recordedBox.withLock { $0.bindAddress ?? "0.0.0.0:4433" }
            let endpoint = MockIrohEndpoint(boundAddress: addr)
            onBind(endpoint)
            return endpoint
        }
    }

    final class MockIrohBinding: MachineIrohBinding.Binding, Sendable {
        private let latestBuilderBox = Mutex<MockIrohBuilder?>(nil)
        private let latestEndpointBox = Mutex<MockIrohEndpoint?>(nil)

        var latestBuilder: MockIrohBuilder? { latestBuilderBox.withLock { $0 } }
        var latestEndpoint: MockIrohEndpoint? { latestEndpointBox.withLock { $0 } }

        func makeEndpointBuilder() -> any MachineIrohBinding.EndpointBuilder {
            let builder = MockIrohBuilder { [self] endpoint in
                self.latestEndpointBox.withLock { $0 = endpoint }
            }
            latestBuilderBox.withLock { $0 = builder }
            return builder
        }
    }
}

/// A mutable value shared across tasks.
final class MachineMutexBox<Value: Sendable>: Sendable {
    private let state: Mutex<Value>
    init(_ value: Value) { state = Mutex(value) }
    func get() -> Value { state.withLock { $0 } }
    func set(_ value: Value) { state.withLock { $0 = value } }
    func mutate(_ body: (inout Value) -> Void) { state.withLock { body(&$0) } }
}
