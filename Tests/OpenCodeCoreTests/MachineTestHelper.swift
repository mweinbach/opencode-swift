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
        let key: MachineIdentity.Key
        init(seed: [UInt8]) { key = MachineIdentity.fromSeed(seed) }
        func publicKey() async throws(MachineIdentity.InvalidKey) -> [UInt8] { key.publicKey }
        func sign(_ bytes: [UInt8]) async throws(MachineIdentity.InvalidKey) -> [UInt8] { key.sign(bytes) }
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

    /// One end of an in-memory carrier pair, recording what it sent.
    final class Pipe: MachineLink.Carrier, Sendable {
        private let inbox: Channel
        private let outbox: Channel
        private let log = Mutex<[[UInt8]]>([])

        init(inbox: Channel, outbox: Channel) {
            self.inbox = inbox
            self.outbox = outbox
        }

        var sent: [[UInt8]] { log.withLock { $0 } }

        func send(_ message: [UInt8]) async {
            log.withLock { $0.append(message) }
            outbox.put(message)
        }

        func receive() async throws -> [UInt8] {
            guard let next = await inbox.take() else { throw MachineLink.Closed() }
            return next
        }

        func close() { outbox.close() }

        static func pair() -> (Pipe, Pipe) {
            let toA = Channel()
            let toB = Channel()
            return (Pipe(inbox: toA, outbox: toB), Pipe(inbox: toB, outbox: toA))
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

        init(hello: MachineWire.Hello) {
            let (stream, continuation) = AsyncStream<MachineWire.FromWorker>.makeStream()
            self.continuation = continuation
            let received = self.received
            connection = MachineDriver.Connection(
                hello: hello,
                send: { message in received.mutate { $0.append(message) } },
                messages: stream
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

    static func hello(name: String = "gpu", instance: String = "one", processes: [MachineWire.HelloProcess] = []) -> MachineWire.Hello {
        MachineWire.Hello(name: name, os: "linux", arch: "x64", home: "/home/me", instance: MachineWire.Instance(instance), processes: processes)
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
}

/// A mutable value shared across tasks.
final class MachineMutexBox<Value: Sendable>: Sendable {
    private let state: Mutex<Value>
    init(_ value: Value) { state = Mutex(value) }
    func get() -> Value { state.withLock { $0 } }
    func set(_ value: Value) { state.withLock { $0 = value } }
    func mutate(_ body: (inout Value) -> Void) { state.withLock { body(&$0) } }
}
